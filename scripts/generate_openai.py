#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
Параллельный генератор кадров через OpenAI (gpt-image-2) — ДЛЯ СРАВНЕНИЯ
с nano banana. Берёт ТЕ ЖЕ promt_en и ТЕ ЖЕ референсы из data/frames.json,
что и основной скрипт, и кладёт рядом вторую версию кадра.

Отдельный скрипт: scripts/generate.py он НЕ трогает. Часть логики намеренно
продублирована — так проще читать и запускать независимо.

Только стандартная библиотека Python 3 — ничего ставить не нужно.

Что делает:
  - читает data/frames.json;
  - для кадров с готовым prompt_en, у которых ещё нет версии от OpenAI,
    собирает те же референсы и отправляет запрос в OpenAI images/edits;
  - сохраняет PNG как images/s{scene}_{кадр:02d}_v{N}_openai.png;
  - ДОБАВЛЯЕТ запись в versions[] кадра с provider="openai";
  - СТАТУС кадра НЕ меняет (это параллельная версия, не новая итерация).

Запуск (примеры):
  python3 scripts/generate_openai.py --dry-run           # план без обращения к API
  python3 scripts/generate_openai.py --limit 9           # сгенерировать до 9 кадров
  python3 scripts/generate_openai.py --frame 3.3         # один кадр
"""

import argparse
import base64
import json
import os
import sys
import time
import urllib.error
import urllib.request
import uuid
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
# Модель и параметры OpenAI (сверено с developers.openai.com/api/docs)
# ---------------------------------------------------------------------------
API_URL = "https://api.openai.com/v1/images/edits"
MODEL = "gpt-image-2"
SIZE = "1536x1024"          # ближайший к 16:9 landscape
QUALITY = "high"
OUTPUT_FORMAT = "png"
PROVIDER = "openai"

# Приблизительная цена кадра (high, 1536x1024). Точная стоимость биллится по токенам —
# если ответ содержит usage, мы показываем и токены.
PRICE_PER_IMAGE_APPROX = 0.19
USD_TO_RUB = 92

REF_EXTS = (".png", ".jpg", ".jpeg", ".webp")
MIME_BY_EXT = {
    ".png": "image/png",
    ".jpg": "image/jpeg",
    ".jpeg": "image/jpeg",
    ".webp": "image/webp",
}


# ---------------------------------------------------------------------------
# Автозагрузка ключа из .env (как в generate.py)
# ---------------------------------------------------------------------------
def load_dotenv(root):
    """Строки KEY=VALUE; пустые и #-комментарии пропускаются; уже заданные в
    окружении переменные НЕ перезаписываются. Без внешних библиотек."""
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
        die(f"Не найден файл очереди кадров: {FRAMES_JSON}")
    try:
        return json.loads(FRAMES_JSON.read_text(encoding="utf-8"))
    except json.JSONDecodeError as e:
        die(f"Файл {FRAMES_JSON.name} повреждён (ошибка JSON): {e}")


def save_frames_atomic(data):
    """Атомарная запись: временный файл + переименование."""
    data["updated"] = now_iso()
    tmp = FRAMES_JSON.with_name(FRAMES_JSON.name + ".tmp")
    tmp.write_text(json.dumps(data, ensure_ascii=False, indent=2), encoding="utf-8")
    tmp.replace(FRAMES_JSON)


def die(msg):
    print("\n  ОШИБКА. " + msg + "\n", file=sys.stderr)
    sys.exit(1)


def shot_number(frame_id):
    """'3.3' -> 3, '4.20' -> 20."""
    return int(str(frame_id).split(".")[1])


def image_name(frame, version):
    """images/s3_03_v2_openai.png"""
    return f"images/s{frame['scene']}_{shot_number(frame['id']):02d}_v{version}_openai.png"


def _find_child_dir(parent, name):
    want = name.casefold()
    for p in sorted(parent.iterdir()):
        if p.is_dir() and p.name.casefold() == want:
            return p
    return None


def find_ref_file(name):
    """Ищет файл референса с поддержкой вложенных путей (как в generate.py).
    name — путь относительно «Референсы» без расширения, регистр не важен."""
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
    want = name.casefold()
    for p in sorted(REFS_DIR.rglob("*")):
        if p.is_file() and p.stem.casefold() == want and p.suffix.casefold() in REF_EXTS:
            return p
    return None


def gather_refs(frame):
    """(список Path референсов в порядке refs, список отсутствующих имён)."""
    found, missing = [], []
    for name in frame.get("refs", []):
        p = find_ref_file(name)
        if p:
            found.append(p)
        else:
            missing.append(name)
    return found, missing


def has_openai_version(frame):
    return any(v.get("provider") == PROVIDER for v in frame.get("versions", []))


# ---------------------------------------------------------------------------
# multipart/form-data вручную (stdlib) — собираем тело и boundary
# ---------------------------------------------------------------------------
def build_multipart(fields, files):
    """fields: [(name, value_str)]; files: [(name, filename, bytes, content_type)].
    Возвращает (content_type_header, body_bytes)."""
    boundary = "----EchoInMountains" + uuid.uuid4().hex
    crlf = b"\r\n"
    b = bytearray()
    for name, value in fields:
        b += b"--" + boundary.encode("ascii") + crlf
        b += ('Content-Disposition: form-data; name="%s"' % name).encode("utf-8") + crlf + crlf
        b += value.encode("utf-8") + crlf
    for name, filename, content, ctype in files:
        b += b"--" + boundary.encode("ascii") + crlf
        b += ('Content-Disposition: form-data; name="%s"; filename="%s"'
              % (name, filename)).encode("utf-8") + crlf
        b += ("Content-Type: %s" % ctype).encode("ascii") + crlf + crlf
        b += content + crlf
    b += b"--" + boundary.encode("ascii") + b"--" + crlf
    return "multipart/form-data; boundary=" + boundary, bytes(b)


# ---------------------------------------------------------------------------
# Вызов OpenAI images/edits
# ---------------------------------------------------------------------------
class ApiError(Exception):
    """Ошибка, уже описанная человеческим языком."""


def call_openai(api_key, prompt_en, ref_paths):
    # поля формы
    fields = [
        ("model", MODEL),
        ("prompt", prompt_en),
        ("size", SIZE),
        ("quality", QUALITY),
        ("output_format", OUTPUT_FORMAT),
        ("n", "1"),
    ]
    # референсы: несколько частей image[] в порядке refs (ASCII-имя, реальное расширение)
    files = []
    for i, p in enumerate(ref_paths, start=1):
        ext = p.suffix.casefold()
        mime = MIME_BY_EXT.get(ext, "image/png")
        files.append(("image[]", f"reference_{i}{ext}", p.read_bytes(), mime))

    content_type, body = build_multipart(fields, files)

    max_attempts = 3
    for attempt in range(1, max_attempts + 1):
        req = urllib.request.Request(API_URL, data=body, method="POST")
        req.add_header("Authorization", "Bearer " + api_key)
        req.add_header("Content-Type", content_type)
        try:
            with urllib.request.urlopen(req, timeout=600) as resp:
                payload = json.loads(resp.read().decode("utf-8"))
            data = payload.get("data") or []
            if not data or not data[0].get("b64_json"):
                raise ApiError("ответ без изображения (нет data[0].b64_json).")
            img = base64.b64decode(data[0]["b64_json"])
            return img, payload.get("usage")
        except urllib.error.HTTPError as e:
            detail = _read_http_error(e)
            if e.code in (429, 500, 502, 503) and attempt < max_attempts:
                pause = 15 * attempt
                print(f"      сервер занят (код {e.code}). Пауза {pause} c и повтор…")
                time.sleep(pause)
                continue
            raise ApiError(_explain_http(e.code, detail))
        except urllib.error.URLError as e:
            if attempt < max_attempts:
                pause = 10 * attempt
                print(f"      нет связи ({e.reason}). Пауза {pause} c и повтор…")
                time.sleep(pause)
                continue
            raise ApiError(f"нет связи с OpenAI API ({e.reason}). Проверьте интернет.")
        except (TimeoutError, OSError) as e:
            if attempt < max_attempts:
                pause = 15 * attempt
                print(f"      таймаут/обрыв соединения ({e}). Пауза {pause} c и повтор…")
                time.sleep(pause)
                continue
            raise ApiError(f"обрыв соединения с OpenAI API после нескольких попыток ({e}).")
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
    if code == 401 or "invalid api key" in d or "incorrect api key" in d:
        return ("ключ отклонён. Проверьте OPENAI_API_KEY в .env (скопирован ли он целиком) "
                "и что у ключа есть доступ к images.")
    if code == 429 or "rate limit" in d or "quota" in d or "billing" in d:
        return ("исчерпан лимит или не пополнен баланс OpenAI. Проверьте биллинг в "
                "аккаунте OpenAI (platform.openai.com, Billing) и повторите запуск.")
    if code == 400:
        return f"запрос отклонён (400): {detail}"
    if detail:
        return f"код {code}: {detail}"
    return f"код {code} от сервера OpenAI."


# ---------------------------------------------------------------------------
# Выбор кадров и основной цикл
# ---------------------------------------------------------------------------
def select_frames(data, args):
    frames = data.get("frames", [])
    if args.frame:
        picked = [f for f in frames if str(f.get("id")) == str(args.frame)]
        if not picked:
            die(f"Кадр {args.frame} не найден.")
        return picked
    # кадры с готовым промтом, у которых ещё НЕТ версии от OpenAI
    ready = [f for f in frames
             if (f.get("prompt_en") or "").strip() and not has_openai_version(f)]
    return ready[: args.limit]


def main():
    ap = argparse.ArgumentParser(
        description="Параллельная генерация кадров через OpenAI gpt-image-2 (для сравнения).")
    ap.add_argument("--limit", type=int, default=5,
                    help="сколько кадров обработать за запуск (по умолчанию 5)")
    ap.add_argument("--frame", default=None, help="только один кадр по id, например 3.3")
    ap.add_argument("--dry-run", action="store_true",
                    help="показать план БЕЗ обращения к API (ключ не нужен)")
    args = ap.parse_args()

    load_dotenv(ROOT)
    IMAGES_DIR.mkdir(exist_ok=True)
    data = load_frames()
    frames = select_frames(data, args)

    key_present = bool(os.environ.get("OPENAI_API_KEY", "").strip())
    print("=" * 64)
    print(f"  Проект: {data.get('project', '—')}  ·  серия: {data.get('series', '—')}")
    print(f"  СРАВНЕНИЕ через OpenAI {MODEL}  ·  {SIZE}  ·  quality={QUALITY}")
    print(f"  Кадров в работе: {len(frames)}")
    print(f"  Ключ OPENAI_API_KEY: {'задан' if key_present else 'не задан'}")
    if args.dry_run:
        print("  РЕЖИМ ПРОВЕРКИ (--dry-run): реальная генерация не выполняется.")
    print("=" * 64)

    if not frames:
        print("\n  Нет кадров для сравнения: у всех подходящих уже есть версия OpenAI,")
        print("  или ни у кого нет готового prompt_en.\n")
        return

    api_key = os.environ.get("OPENAI_API_KEY", "").strip()
    if not api_key and not args.dry_run:
        die("не задан ключ OpenAI.\n"
            "  Положите строку в файл .env:  OPENAI_API_KEY=sk-...\n"
            "  или задайте в окружении:      export OPENAI_API_KEY=sk-...\n"
            "  Проверить план без ключа:     python3 scripts/generate_openai.py --dry-run")

    generated = skipped = errors = 0
    usage_totals = {"input_tokens": 0, "output_tokens": 0, "total_tokens": 0}
    saw_usage = False

    for frame in frames:
        fid = frame.get("id")
        ref_paths, missing = gather_refs(frame)
        version = len(frame.get("versions", [])) + 1
        out_name = image_name(frame, version)

        print(f"\n— Кадр {fid}  [{frame.get('shot', '')}]  {frame.get('action', '')}")
        print(f"    референсы (image[]): {', '.join(frame.get('refs', [])) or '—'}")

        if args.dry_run:
            print(f"    -> будет сохранён файл: {out_name}")
            preview = (frame.get('prompt_en') or '')[:150].replace("\n", " ")
            print(f"    тот же промт (EN): {preview}…")
            if missing:
                print(f"    ВНИМАНИЕ: пока нет референсов: {', '.join(missing)} "
                      f"(при реальном запуске кадр пропустится)")
            continue

        if not ref_paths:
            print(f"    ПРОПУСК: нет ни одного референса ({', '.join(missing) or '—'}). "
                  f"OpenAI images/edits требует входное изображение.")
            skipped += 1
            continue
        if missing:
            print(f"    (нет части референсов: {', '.join(missing)} — генерирую по имеющимся)")

        try:
            img_bytes, usage = call_openai(api_key, frame["prompt_en"], ref_paths)
        except ApiError as e:
            print(f"    ОШИБКА: {e}")
            errors += 1
            continue

        (ROOT / out_name).write_bytes(img_bytes)
        frame.setdefault("versions", []).append({
            "v": version,
            "provider": PROVIDER,
            "file": out_name,
            "prompt_en": frame["prompt_en"],
            "generated_at": now_iso(),
        })
        # СТАТУС кадра НЕ меняем — это параллельная версия для сравнения.
        save_frames_atomic(data)
        generated += 1
        if usage:
            saw_usage = True
            for k in usage_totals:
                usage_totals[k] += int(usage.get(k, 0) or 0)
        print(f"    ГОТОВО -> {out_name}  (добавлена версия v{version}, provider=openai)")

    # ---- сводка ----
    print("\n" + "=" * 64)
    print("  ИТОГ ЗАПУСКА (OpenAI)")
    print(f"    сгенерировано: {generated}")
    print(f"    пропущено: {skipped}")
    print(f"    ошибки: {errors}")
    if not args.dry_run and generated:
        if saw_usage:
            print(f"    токены (usage из ответа): вход {usage_totals['input_tokens']}, "
                  f"выход {usage_totals['output_tokens']}, всего {usage_totals['total_tokens']}")
        cost = generated * PRICE_PER_IMAGE_APPROX
        print(f"    примерная стоимость: ~${cost:.2f} (~{round(cost * USD_TO_RUB)} ₽), "
              f"приблизительно ${PRICE_PER_IMAGE_APPROX}/кадр (high {SIZE})")
    if args.dry_run and frames:
        cost = len(frames) * PRICE_PER_IMAGE_APPROX
        print(f"    если запустить по-настоящему: ~${cost:.2f} "
              f"(приблизительно ${PRICE_PER_IMAGE_APPROX}/кадр)")
    print("=" * 64 + "\n")


if __name__ == "__main__":
    main()
