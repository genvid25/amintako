#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
Генератор кадров мультфильма через Gemini API (nano banana).

Что делает:
  - читает data/frames.json;
  - берёт кадры со статусом "queued" или "redo", у которых уже есть prompt_en;
  - для каждого кадра собирает референсы из папки "Референсы",
    отправляет запрос в Gemini (generateContent, соотношение 16:9),
    сохраняет PNG в папку images и переводит кадр в статус "review".

Скрипт НЕ придумывает промты. Текст промта (prompt_en) заранее пишет
Claude-агент по правилам из файла АГЕНТ.md. Здесь — только генерация.

Только стандартная библиотека Python 3 — ничего ставить не нужно.

Запуск (примеры):
  python3 scripts/generate.py --dry-run          # показать план, без обращения к API
  python3 scripts/generate.py --limit 3          # сгенерировать первые 3 кадра из очереди
  python3 scripts/generate.py --frame 7.6        # только один кадр
  python3 scripts/generate.py --model flash      # дешёвый режим
"""

import argparse
import base64
import json
import os
import sys
import time
import urllib.error
import urllib.request
from datetime import datetime, timezone
from pathlib import Path

# ---------------------------------------------------------------------------
# Пути (всё считается от корня проекта — папки на один уровень выше scripts/)
# ---------------------------------------------------------------------------
ROOT = Path(__file__).resolve().parent.parent
FRAMES_JSON = ROOT / "data" / "frames.json"
REFS_DIR = ROOT / "Референсы"
IMAGES_DIR = ROOT / "images"

# ---------------------------------------------------------------------------
# Модели и цены (данные проверены по официальной документации Gemini API)
# ---------------------------------------------------------------------------
MODELS = {
    "pro": "gemini-3-pro-image",       # nano banana Pro — до 14 референсов, макс. качество
    "flash": "gemini-3.1-flash-image",  # дешёвый режим
}
PRICE_PER_IMAGE = {
    "pro": 0.134,
    "flash": 0.067,
}
API_URL = "https://generativelanguage.googleapis.com/v1beta/models/{model}:generateContent"

REF_EXTS = (".png", ".jpg", ".jpeg", ".webp")
MIME_BY_EXT = {
    ".png": "image/png",
    ".jpg": "image/jpeg",
    ".jpeg": "image/jpeg",
    ".webp": "image/webp",
}

# Статусы, которые скрипт берёт в работу
READY_STATUSES = ("queued", "redo")

# Курс доллара к рублю — только для приблизительной оценки стоимости в сводке
USD_TO_RUB = 92


# ---------------------------------------------------------------------------
# Автозагрузка ключа из .env (без внешних библиотек)
# ---------------------------------------------------------------------------
def load_dotenv(root):
    """Подхватывает переменные из файла .env в корне проекта.
    Простой парсер: строки вида KEY=VALUE; пустые строки и комментарии (#)
    игнорируются. Уже заданные в окружении переменные НЕ перезаписываются
    (то, что задано через export, всегда важнее файла)."""
    env_path = root / ".env"
    if not env_path.exists():
        return
    try:
        lines = env_path.read_text(encoding="utf-8").splitlines()
    except OSError:
        return
    for line in lines:
        s = line.strip()
        if not s or s.startswith("#") or "=" not in s:
            continue
        if s.startswith("export "):
            s = s[len("export "):].lstrip()
        key, _, val = s.partition("=")
        key, val = key.strip(), val.strip()
        if len(val) >= 2 and val[0] == val[-1] and val[0] in ("'", '"'):
            val = val[1:-1]
        if key and key not in os.environ:
            os.environ[key] = val


# ---------------------------------------------------------------------------
# Вспомогательное
# ---------------------------------------------------------------------------
def now_iso():
    return datetime.now(timezone.utc).replace(microsecond=0).isoformat().replace("+00:00", "Z")


def load_frames():
    if not FRAMES_JSON.exists():
        die(f"Не найден файл с очередью кадров: {FRAMES_JSON}\n"
            f"Проверьте, что вы запускаете скрипт из папки проекта.")
    try:
        return json.loads(FRAMES_JSON.read_text(encoding="utf-8"))
    except json.JSONDecodeError as e:
        die(f"Файл {FRAMES_JSON.name} повреждён (ошибка JSON): {e}")


def save_frames_atomic(data):
    """Атомарная запись: сначала во временный файл, потом переименование.
    Так frames.json никогда не окажется наполовину записанным."""
    data["updated"] = now_iso()
    tmp = FRAMES_JSON.with_name(FRAMES_JSON.name + ".tmp")
    tmp.write_text(json.dumps(data, ensure_ascii=False, indent=2), encoding="utf-8")
    tmp.replace(FRAMES_JSON)


def die(msg):
    print("\n  ОШИБКА. " + msg + "\n", file=sys.stderr)
    sys.exit(1)


def shot_number(frame_id):
    """'7.5' -> 5, '7.10' -> 10. Номер кадра внутри сцены."""
    return int(str(frame_id).split(".")[1])


def image_name(frame, version):
    """images/s7_05_v1.png"""
    return f"images/s{frame['scene']}_{shot_number(frame['id']):02d}_v{version}.png"


def _find_child_dir(parent, name):
    """Ищет вложенную папку по имени без учёта регистра. Path или None."""
    want = name.casefold()
    for p in sorted(parent.iterdir()):
        if p.is_dir() and p.name.casefold() == want:
            return p
    return None


def find_ref_file(name):
    """Ищет файл референса в папке «Референсы» с поддержкой вложенных путей.
    name — путь относительно «Референсы» БЕЗ расширения, например
    «ПЕРСОНАЖИ/Дедушка Хамза» или «ЛОКАЦИИ/Пещера/вход в пещеру».
    Регистр не учитывается на каждом сегменте пути; расширения png/jpg/jpeg/webp.
    Голое имя без «/» ищется рекурсивно по всему дереву. Возвращает Path или None."""
    if not REFS_DIR.exists():
        return None
    name = name.strip().strip("/")
    if not name:
        return None
    if "/" in name:
        *dirs, stem = name.split("/")
        cur = REFS_DIR
        for d in dirs:
            cur = _find_child_dir(cur, d)
            if cur is None:
                return None
        want = stem.casefold()
        for p in sorted(cur.iterdir()):
            if p.is_file() and p.stem.casefold() == want and p.suffix.casefold() in REF_EXTS:
                return p
        return None
    # голое имя без папки — рекурсивный поиск по всему дереву
    want = name.casefold()
    for p in sorted(REFS_DIR.rglob("*")):
        if p.is_file() and p.stem.casefold() == want and p.suffix.casefold() in REF_EXTS:
            return p
    return None


def build_image_part(path):
    raw = path.read_bytes()
    mime = MIME_BY_EXT.get(path.suffix.casefold(), "image/png")
    return {"inline_data": {"mime_type": mime, "data": base64.b64encode(raw).decode("ascii")}}


def extract_image_bytes(payload):
    """Достаёт PNG из ответа Gemini. Ответ приходит в
    candidates[].content.parts[].inlineData.data (base64).
    Поддерживаем и camelCase (inlineData), и snake_case (inline_data)."""
    for cand in payload.get("candidates", []) or []:
        for part in (cand.get("content", {}) or {}).get("parts", []) or []:
            blob = part.get("inlineData") or part.get("inline_data")
            if blob and blob.get("data"):
                return base64.b64decode(blob["data"])
    return None


def block_reason(payload):
    """Если картинку не сгенерировали из-за фильтров безопасности — вернуть причину."""
    fb = payload.get("promptFeedback") or {}
    if fb.get("blockReason"):
        return f"запрос отклонён фильтром безопасности ({fb['blockReason']})"
    for cand in payload.get("candidates", []) or []:
        fr = cand.get("finishReason")
        if fr and fr not in ("STOP", "MAX_TOKENS"):
            return f"генерация остановлена (finishReason={fr})"
    return None


# ---------------------------------------------------------------------------
# Вызов API с понятной обработкой ошибок и повторами при перегрузке
# ---------------------------------------------------------------------------
class ApiError(Exception):
    """Ошибка, которую уже описали человеческим языком."""


def call_gemini(api_key, model, prompt_en, ref_parts, size):
    url = API_URL.format(model=MODELS[model])
    body = {
        "contents": [{"parts": [{"text": prompt_en}] + ref_parts}],
        "generationConfig": {
            "responseModalities": ["TEXT", "IMAGE"],
            "imageConfig": {"aspectRatio": "16:9", "imageSize": size},
        },
    }
    data = json.dumps(body).encode("utf-8")
    headers = {"x-goog-api-key": api_key, "Content-Type": "application/json"}

    max_attempts = 3
    for attempt in range(1, max_attempts + 1):
        req = urllib.request.Request(url, data=data, headers=headers, method="POST")
        try:
            with urllib.request.urlopen(req, timeout=180) as resp:
                payload = json.loads(resp.read().decode("utf-8"))
            img = extract_image_bytes(payload)
            if img:
                return img
            reason = block_reason(payload) or "модель не вернула изображение"
            raise ApiError(f"кадр не сгенерирован: {reason}")

        except urllib.error.HTTPError as e:
            detail = _read_http_error(e)
            code = e.code
            # Перегрузка / лимит запросов — подождать и повторить
            if code in (429, 500, 503) and attempt < max_attempts:
                pause = 15 * attempt
                print(f"      сервер занят (код {code}). Пауза {pause} c и повтор "
                      f"({attempt}/{max_attempts - 1})…")
                time.sleep(pause)
                continue
            raise ApiError(_explain_http(code, detail))

        except urllib.error.URLError as e:
            if attempt < max_attempts:
                pause = 10 * attempt
                print(f"      нет связи с сервером ({e.reason}). Пауза {pause} c и повтор…")
                time.sleep(pause)
                continue
            raise ApiError(f"нет связи с Gemini API ({e.reason}). Проверьте интернет.")

    raise ApiError("не удалось получить кадр после нескольких попыток.")


def _read_http_error(e):
    try:
        raw = e.read().decode("utf-8")
        obj = json.loads(raw)
        return obj.get("error", {}).get("message") or raw
    except Exception:
        return ""


def _explain_http(code, detail):
    d = (detail or "").lower()
    if code in (401, 403) and ("api key" in d or "api_key" in d or "permission" in d):
        return ("ключ отклонён. Проверьте GEMINI_API_KEY (скопирован ли он целиком) "
                "и что для ключа включён доступ к Gemini API.")
    if code == 429 or "resource_exhausted" in d or "quota" in d or "billing" in d:
        return ("исчерпана квота или не активирован биллинг. "
                "В подписке Ultra нужно активировать кредиты: зайдите на aistudio.google.com, "
                "раздел Billing/Plan, и включите оплату для проекта. Затем повторите запуск.")
    if code == 400 and "image" in d:
        return f"запрос отклонён (400): {detail}"
    if detail:
        return f"код {code}: {detail}"
    return f"код {code} от сервера Gemini."


# ---------------------------------------------------------------------------
# Основная работа
# ---------------------------------------------------------------------------
def select_frames(data, args):
    frames = data.get("frames", [])
    if args.frame:
        picked = [f for f in frames if str(f.get("id")) == str(args.frame)]
        if not picked:
            die(f"Кадр {args.frame} не найден в очереди.")
        return picked
    ready = [f for f in frames
             if f.get("status") in READY_STATUSES and (f.get("prompt_en") or "").strip()]
    return ready[: args.limit]


def gather_refs(frame):
    """Возвращает (список_частей_картинок, список_имён_отсутствующих_референсов)."""
    parts, missing = [], []
    for name in frame.get("refs", []):
        p = find_ref_file(name)
        if p:
            parts.append(build_image_part(p))
        else:
            missing.append(name)
    return parts, missing


def main():
    ap = argparse.ArgumentParser(
        description="Генерация кадров мультфильма через Gemini API (nano banana).")
    ap.add_argument("--limit", type=int, default=5,
                    help="сколько кадров из очереди взять за один запуск (по умолчанию 5)")
    ap.add_argument("--model", choices=("pro", "flash"), default="pro",
                    help="pro = nano banana Pro (качество), flash = дешевле (по умолчанию pro)")
    ap.add_argument("--size", default="2K", help="разрешение: 1K, 2K или 4K (по умолчанию 2K)")
    ap.add_argument("--frame", default=None,
                    help="сгенерировать только один кадр по id, например 7.6")
    ap.add_argument("--dry-run", action="store_true",
                    help="показать, что будет сделано, БЕЗ обращения к API (ключ не нужен)")
    args = ap.parse_args()

    load_dotenv(ROOT)  # подхватить GEMINI_API_KEY из .env, если он не задан в окружении
    IMAGES_DIR.mkdir(exist_ok=True)
    data = load_frames()
    frames = select_frames(data, args)

    price = PRICE_PER_IMAGE[args.model]
    key_present = bool(os.environ.get("GEMINI_API_KEY", "").strip())
    print("=" * 64)
    print(f"  Проект: {data.get('project', '—')}  ·  серия: {data.get('series', '—')}")
    print(f"  Модель: {MODELS[args.model]} ({args.model})  ·  размер: {args.size}  ·  16:9")
    print(f"  Кадров в работе: {len(frames)}")
    print(f"  Ключ GEMINI_API_KEY: {'задан' if key_present else 'не задан'}")
    if args.dry_run:
        print("  РЕЖИМ ПРОВЕРКИ (--dry-run): реальная генерация не выполняется.")
    print("=" * 64)

    if not frames:
        print("\n  Очередь пуста: нет кадров со статусом queued/redo с готовым промтом.")
        print("  Добавить кадры в очередь — задача Claude-агента (см. АГЕНТ.md).\n")
        return

    api_key = os.environ.get("GEMINI_API_KEY", "").strip()
    if not api_key and not args.dry_run:
        die("не задан ключ доступа к Gemini.\n"
            "  Обычно ключ лежит в файле .env в корне проекта (строка GEMINI_API_KEY=...)\n"
            "  — проверьте, что файл на месте. Либо задайте ключ командой:\n"
            "      export GEMINI_API_KEY=...\n"
            "  Ключ берётся на aistudio.google.com → Get API key.\n"
            "  Проверить план без ключа можно так:  python3 scripts/generate.py --dry-run")

    generated = skipped = errors = 0

    for frame in frames:
        fid = frame.get("id")
        ref_parts, missing = gather_refs(frame)
        version = len(frame.get("versions", [])) + 1
        out_name = image_name(frame, version)

        print(f"\n— Кадр {fid}  [{frame.get('shot', '')}]  {frame.get('action', '')}")
        print(f"    референсы: {', '.join(frame.get('refs', [])) or '—'}")

        if args.dry_run:
            print(f"    -> будет сохранён файл: {out_name}")
            preview = frame["prompt_en"][:150].replace("\n", " ")
            print(f"    промт (EN): {preview}…")
            if missing:
                print(f"    ВНИМАНИЕ: пока нет референсов: {', '.join(missing)} "
                      f"(при реальном запуске кадр пропустится — добавьте файлы в «Референсы»)")
            continue

        if missing:
            print(f"    ПРОПУСК: нет файлов референсов: {', '.join(missing)}")
            print(f"    Положите их в папку «Референсы» (например {missing[0]}.png) и повторите.")
            skipped += 1
            continue

        # переводим кадр в статус «генерируется» и фиксируем это в файле
        frame["status"] = "generating"
        save_frames_atomic(data)

        try:
            img_bytes = call_gemini(api_key, args.model, frame["prompt_en"], ref_parts, args.size)
        except ApiError as e:
            frame["status"] = "redo" if version > 1 else "queued"  # вернуть в очередь
            save_frames_atomic(data)
            print(f"    ОШИБКА: {e}")
            errors += 1
            continue

        (ROOT / out_name).write_bytes(img_bytes)
        frame.setdefault("versions", []).append({
            "v": version,
            "file": out_name,
            "prompt_en": frame["prompt_en"],
            "generated_at": now_iso(),
        })
        frame["status"] = "review"
        save_frames_atomic(data)
        generated += 1
        print(f"    ГОТОВО -> {out_name}  (статус: на проверку)")

    # ---- итоговая сводка ----
    print("\n" + "=" * 64)
    print("  ИТОГ ЗАПУСКА")
    print(f"    сгенерировано: {generated}")
    print(f"    пропущено (нет референсов): {skipped}")
    print(f"    ошибки: {errors}")
    if generated and not args.dry_run:
        cost = generated * price
        print(f"    примерная стоимость: ${cost:.2f}  (~{round(cost * USD_TO_RUB)} ₽), "
              f"${price}/кадр")
    if not args.dry_run and generated:
        print("\n  Откройте дашборд, чтобы проверить кадры:")
        print("      python3 scripts/serve.py   →   http://localhost:8787")
    print("=" * 64 + "\n")


if __name__ == "__main__":
    main()
