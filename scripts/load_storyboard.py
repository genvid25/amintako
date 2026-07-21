#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
Заливка раскадровки серии в облачную базу (Supabase).

Что делает:
  - читает data/storyboard.json  -> сцены и кадры серии;
  - читает data/frames.json      -> промты и готовые картинки тех кадров,
                                    которые уже сгенерированы;
  - создаёт в базе серию, сцены, кадры и версии картинок;
  - зовёт функцию базы mark_anchors() — она сама помечает мастер-кадром
    первый кадр каждой сцены и открывает ему очередь. Руками статусы
    не расставляем: правило мастер-кадра живёт в схеме, а не здесь.

Запускать можно сколько угодно раз — дубликатов не будет:
  - серия ищется по (проект, номер), сцена по (серия, номер),
    кадр по (серия, код «1.3»), версия по (кадр, номер версии);
  - повторный запуск обновляет ТОЛЬКО содержание кадра из раскадровки
    (крупность, действие, реплика, звук, хронометраж, референсы).
    Статус, правку сотрудника, промт и исполнителя он не трогает —
    иначе перезаливка стёрла бы работу людей (см. docs/supabase-план.md §5.8).

Ключ берётся из .env в корне проекта (SUPABASE_URL + SUPABASE_SECRET_KEY)
или из переменных окружения. В коде ключей нет и быть не должно.

Только стандартная библиотека Python 3 — ничего ставить не нужно.

Запуск:
  python3 scripts/load_storyboard.py --dry-run     # показать план, ничего не писать
  python3 scripts/load_storyboard.py               # залить текущую серию

Новая серия (раскадровку сначала разобрать в свой storyboard.json):
  python3 scripts/load_storyboard.py --number 3 --title "Название" \
          --storyboard data/storyboard-s3.json --no-frames --dry-run

По умолчанию скрипт работает с серией, которая уже заведена в проекте
(константы ниже) — так его и запускают изо дня в день.
"""

import argparse
import json
import os
import sys
import urllib.error
import urllib.parse
import urllib.request
from pathlib import Path

# ---------------------------------------------------------------------------
# Пути (всё считается от корня проекта — папки на один уровень выше scripts/)
# ---------------------------------------------------------------------------
ROOT = Path(__file__).resolve().parent.parent
STORYBOARD_JSON = ROOT / "data" / "storyboard.json"
FRAMES_JSON = ROOT / "data" / "frames.json"

PROJECT = "ЭХО В ГОРАХ"
SERIES_NUMBER = 2
SERIES_TITLE = "Привяжи верблюда"
SERIES_ASSIGNEE = "Амин"

# Версия без пометки провайдера — это nano banana (Gemini), с ней начинали.
DEFAULT_PROVIDER = "gemini"


def load_dotenv(root):
    """Подхватывает переменные из файла .env в корне проекта.
    Простой парсер: строки KEY=VALUE; пустые строки и комментарии (#)
    игнорируются. Уже заданные в окружении переменные НЕ перезаписываются."""
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
# Тонкий клиент Supabase REST
# ---------------------------------------------------------------------------
class Supabase:
    """Ровно то, что нужно заливке: select, insert, upsert, patch и вызов функции.
    Работает секретным ключом, поэтому RLS не мешает — но и запускать это
    можно только с машины, где лежит .env."""

    def __init__(self, url, key, timeout=60):
        self.url = url.rstrip("/")
        self.key = key
        self.timeout = timeout

    def _call(self, method, path, body=None, prefer=None):
        headers = {
            "apikey": self.key,
            "Authorization": "Bearer " + self.key,
            "Accept": "application/json",
        }
        if body is not None:
            headers["Content-Type"] = "application/json"
        if prefer:
            headers["Prefer"] = prefer
        data = json.dumps(body, ensure_ascii=False).encode("utf-8") if body is not None else None
        req = urllib.request.Request(self.url + path, data=data, headers=headers, method=method)
        try:
            with urllib.request.urlopen(req, timeout=self.timeout) as resp:
                text = resp.read().decode("utf-8")
        except urllib.error.HTTPError as e:
            detail = e.read().decode("utf-8", "replace")
            raise RuntimeError("%s %s -> %s %s" % (method, path.split("?")[0], e.code, detail[:500])) from None
        except urllib.error.URLError as e:
            raise RuntimeError("Не достучались до базы: %s" % e.reason) from None
        return json.loads(text) if text.strip() else []

    def select(self, path):
        return self._call("GET", "/rest/v1/" + path)

    def insert(self, table, rows, on_conflict=None, ignore_duplicates=False):
        """Вставка пачкой. ignore_duplicates — «уже есть, и хорошо»."""
        if not rows:
            return []
        path = "/rest/v1/" + table
        prefer = ["return=representation"]
        if ignore_duplicates:
            prefer.append("resolution=ignore-duplicates")
            path += "?on_conflict=" + on_conflict
        return self._call("POST", path, rows, ", ".join(prefer))

    def upsert(self, table, rows, on_conflict):
        """Вставка-или-обновление по уникальному ключу.
        ВАЖНО: обновляются ровно те колонки, что есть в payload, — поэтому
        сюда попадает только содержание из раскадровки, без статусов и правок."""
        if not rows:
            return []
        path = "/rest/v1/%s?on_conflict=%s" % (table, on_conflict)
        return self._call("POST", path, rows, "return=representation, resolution=merge-duplicates")

    def patch(self, table, filt, body):
        return self._call("PATCH", "/rest/v1/%s?%s" % (table, filt), body, "return=representation")

    def rpc(self, fn, body=None):
        return self._call("POST", "/rest/v1/rpc/" + fn, body or {})


# ---------------------------------------------------------------------------
# Чтение исходных файлов
# ---------------------------------------------------------------------------
def clean(value):
    """Прочерк в таблице означает «ничего нет» — в базе это пустая строка."""
    s = (value or "").strip()
    return "" if s == "—" else s


def merge_orphan_row(prev, row):
    """Строка без номера — это не кадр, а продолжение предыдущего.
    В Excel так оформляют вторую реплику того же кадра: номер не ставят,
    крупность и хронометраж оставляют пустыми. Если завести под неё
    отдельный кадр, получится кадр без крупности, звука и длительности,
    а реплика потеряет свою картинку. Поэтому приклеиваем к предыдущему."""
    who = clean(row.get("action"))
    line = clean(row.get("dialogue"))
    text = ("%s: %s" % (who, line)) if who and line else (who or line)
    if not text:
        return None
    prev["dialogue"] = (prev["dialogue"] + "\n" + text) if prev["dialogue"] else text
    return text


def read_storyboard(path=None):
    """Раскадровка -> список сцен, у каждой список кадров с номерами.
    Возвращает ещё и список приклеенных строк — чтобы показать их в отчёте."""
    raw = json.loads((path or STORYBOARD_JSON).read_text(encoding="utf-8"))
    scenes, merged = [], []

    for sc in raw.get("scenes", []):
        frames = []
        for row in sc.get("frames", []):
            code = (row.get("id") or "").strip()

            if not code:
                if frames:
                    text = merge_orphan_row(frames[-1], row)
                    if text:
                        merged.append((sc["n"], frames[-1]["code"], text))
                else:
                    merged.append((sc["n"], None, "строка без номера в начале сцены — пропущена"))
                continue

            scene_n, _, seq = code.partition(".")
            if not seq.isdigit() or not scene_n.isdigit():
                merged.append((sc["n"], None, "непонятный номер кадра %r — пропущен" % code))
                continue

            frames.append({
                "code": code,
                "scene_n": int(scene_n),
                "seq": int(seq),
                "shot": clean(row.get("shot")),
                "action": clean(row.get("action")),
                "dialogue": clean(row.get("dialogue")),
                "sound": clean(row.get("sound")),
                "chron": clean(row.get("chron")),
            })

        scenes.append({
            "n": sc["n"],
            "header": sc.get("header") or "",
            "location": sc.get("location") or "",
            "time_of_day": sc.get("time") or "",
            "frames": frames,
        })

    return scenes, merged


def read_generated(path=None):
    """Кадры, которые уже сгенерированы: промт, исполнитель, версии картинок.
    Ключ — код кадра («1.3»), как в раскадровке.
    У новой серии готовых кадров нет — тогда сюда приходит None."""
    if path is None:
        return {}
    if not path.exists():
        return {}
    raw = json.loads(path.read_text(encoding="utf-8"))
    out = {}
    for f in raw.get("frames", []):
        code = (f.get("id") or "").strip()
        if not code:
            continue
        out[code] = {
            "prompt_en": f.get("prompt_en") or "",
            "status": f.get("status") or "review",
            "assignee": f.get("assignee") or "",
            "refs": f.get("refs") or [],
            "versions": f.get("versions") or [],
        }
    return out


def file_size(rel_path):
    """Размер картинки в байтах — база хранит его, чтобы не считать заново."""
    try:
        return (ROOT / rel_path).stat().st_size
    except OSError:
        return None


# ---------------------------------------------------------------------------
# Заливка
# ---------------------------------------------------------------------------
def ensure_series(sb, dry, project, number, title, assignee):
    rows = sb.select("series?select=id,project,number,title&project=eq.%s&number=eq.%d"
                     % (urllib.parse.quote(project), number))
    if rows:
        print("  серия      : уже есть, id=%s" % rows[0]["id"])
        return rows[0]["id"]
    if dry:
        print("  серия      : будет создана «%s», серия %d" % (project, number))
        return None
    created = sb.insert("series", [{
        "project": project, "number": number,
        "title": title, "assignee": assignee,
    }])
    print("  серия      : создана, id=%s" % created[0]["id"])
    return created[0]["id"]


def ensure_scenes(sb, series_id, scenes, dry):
    """Сцены заводим до кадров: триггер запирающий кадр без мастер-кадра
    заглядывает в scenes, поэтому сцена должна уже существовать."""
    existing = {} if dry and series_id is None else {
        r["n"]: r["id"] for r in sb.select("scenes?select=id,n&series_id=eq.%d" % series_id)
    }
    payload = [{
        "series_id": series_id, "n": s["n"], "header": s["header"],
        "location": s["location"], "time_of_day": s["time_of_day"],
    } for s in scenes]

    new = [p for p in payload if p["n"] not in existing]
    if dry:
        print("  сцены      : %d всего — новых %d, уже есть %d" % (len(payload), len(new), len(existing)))
        return existing, len(new)
    sb.upsert("scenes", payload, "series_id,n")
    after = {r["n"]: r["id"] for r in sb.select("scenes?select=id,n&series_id=eq.%d" % series_id)}
    print("  сцены      : %d всего — создано %d, обновлено %d" % (len(after), len(new), len(payload) - len(new)))
    return after, len(new)


def ensure_frames(sb, series_id, scenes, scene_ids, generated, dry):
    """Два прохода, и разделение между ними — самое важное место скрипта.

    1) содержание из раскадровки — обновляем всегда, у всех кадров;
    2) промт, статус и исполнитель — ставим ТОЛЬКО новым кадрам.
       У существующих это работа людей и агента: перезаливка её не трогает."""
    existing = {} if series_id is None else {
        r["code"]: r for r in sb.select("frames?select=id,code,status&series_id=eq.%d" % series_id)
    }

    content = []
    for sc in scenes:
        for f in sc["frames"]:
            content.append({
                "series_id": series_id,
                "scene_id": scene_ids.get(sc["n"]),
                "code": f["code"],
                "scene_n": f["scene_n"],
                "seq": f["seq"],
                "shot": f["shot"],
                "action": f["action"],
                "dialogue": f["dialogue"],
                "sound": f["sound"],
                "chron": f["chron"],
                "refs": generated.get(f["code"], {}).get("refs", []),
            })

    fresh = [c for c in content if c["code"] not in existing]
    if dry:
        print("  кадры      : %d всего — новых %d, уже есть %d" % (len(content), len(fresh), len(existing)))
        print("               новым проставим промт и статус: %d"
              % len([c for c in fresh if c["code"] in generated]))
        return {}, len(fresh)

    sb.upsert("frames", content, "series_id,code")

    # Промты и статус «review» — только тем, кого мы завели прямо сейчас.
    work = [{
        "code": c["code"],
        "prompt_en": generated[c["code"]]["prompt_en"],
        "status": generated[c["code"]]["status"],
        "assignee": generated[c["code"]]["assignee"],
    } for c in fresh if c["code"] in generated]

    for w in work:
        sb.patch("frames", "series_id=eq.%d&code=eq.%s" % (series_id, urllib.parse.quote(w["code"])),
                 {"prompt_en": w["prompt_en"], "status": w["status"],
                  "assignee": w["assignee"], "updated_by": "заливка раскадровки"})

    after = {r["code"]: r["id"] for r in sb.select("frames?select=id,code&series_id=eq.%d" % series_id)}
    print("  кадры      : %d всего — создано %d, обновлено содержание у %d"
          % (len(after), len(fresh), len(content) - len(fresh)))
    print("               промт и статус «review» проставлены: %d" % len(work))
    return after, len(fresh)


def ensure_versions(sb, frame_ids, generated, dry):
    """Версии — это история: существующие не трогаем вообще, только дописываем."""
    codes = [c for c in generated if c in frame_ids] if frame_ids else list(generated)
    ids = [frame_ids[c] for c in codes] if frame_ids else []

    existing = set()
    if ids:
        got = sb.select("versions?select=frame_id,v&frame_id=in.(%s)" % ",".join(str(i) for i in ids))
        existing = {(r["frame_id"], r["v"]) for r in got}

    rows, skipped = [], 0
    for code in codes:
        frame_id = frame_ids.get(code)
        for v in generated[code]["versions"]:
            key = (frame_id, v.get("v"))
            if key in existing:
                skipped += 1
                continue
            rows.append({
                "frame_id": frame_id,
                "v": v.get("v"),
                "provider": v.get("provider") or DEFAULT_PROVIDER,
                # Путь относительно корня репозитория: дашборд сам добавит «../».
                "full_url": v.get("file"),
                "preview_url": None,          # превью появятся, когда воркер начнёт жать в WebP
                "prompt_en": v.get("prompt_en") or "",
                "bytes": file_size(v.get("file") or ""),
                "generated_at": v.get("generated_at"),
            })

    total = sum(len(generated[c]["versions"]) for c in codes)
    if dry:
        print("  версии     : %d всего — новых %d, уже есть %d" % (total, len(rows), skipped))
        return len(rows)
    sb.insert("versions", rows, on_conflict="frame_id,v", ignore_duplicates=True)
    print("  версии     : %d всего — добавлено %d, уже было %d" % (total, len(rows), skipped))
    return len(rows)


def report_statuses(sb, series_id):
    rows = sb.select("progress?select=total,queued,generating,review,approved,redo,waiting_anchor"
                     "&series_id=eq.%d" % series_id)
    if not rows:
        return
    p = rows[0]
    print("\nСтатусы кадров в базе:")
    for key, label in (("queued", "в очереди (мастер-кадры)"), ("waiting_anchor", "ждут мастер-кадр"),
                       ("review", "на проверке"), ("generating", "генерируются"),
                       ("approved", "одобрены"), ("redo", "на переделке")):
        if p.get(key):
            print("  %-24s %d" % (label, p[key]))
    print("  %-24s %d" % ("ВСЕГО", p["total"]))


def main():
    ap = argparse.ArgumentParser(description="Заливка раскадровки серии в Supabase")
    ap.add_argument("--dry-run", action="store_true", help="показать план, ничего не записывать")
    # Ниже — всё для НОВОЙ серии. Без этих ключей скрипт работает как раньше,
    # с серией из констант вверху файла.
    ap.add_argument("--project", default=PROJECT, help="название проекта")
    ap.add_argument("--number", type=int, default=SERIES_NUMBER, help="номер серии")
    ap.add_argument("--title", default=None, help="название серии")
    ap.add_argument("--assignee", default=None, help="кто ведёт серию")
    ap.add_argument("--storyboard", default=None, metavar="ФАЙЛ",
                    help="разобранная раскадровка (по умолчанию data/storyboard.json)")
    ap.add_argument("--no-frames", action="store_true",
                    help="не читать data/frames.json — у новой серии готовых кадров нет")
    args = ap.parse_args()

    # Название и исполнителя подставляем из констант только для «своей» серии:
    # у новой серии чужое название было бы неправдой.
    same_series = args.project == PROJECT and args.number == SERIES_NUMBER
    title = args.title if args.title is not None else (SERIES_TITLE if same_series else "")
    assignee = args.assignee if args.assignee is not None else (SERIES_ASSIGNEE if same_series else "")

    storyboard_path = Path(args.storyboard) if args.storyboard else STORYBOARD_JSON
    if not storyboard_path.is_absolute():
        storyboard_path = ROOT / storyboard_path
    if not storyboard_path.exists():
        sys.exit("Не нашёл разобранную раскадровку: %s" % storyboard_path)
    frames_path = None if (args.no_frames or not same_series) else FRAMES_JSON

    load_dotenv(ROOT)
    url = os.environ.get("SUPABASE_URL", "").strip()
    key = os.environ.get("SUPABASE_SECRET_KEY", "").strip()
    if not url or not key:
        sys.exit("Нет доступа к базе: в .env нужны SUPABASE_URL и SUPABASE_SECRET_KEY")
    if not key.startswith("sb_secret_") and not key.startswith("eyJ"):
        sys.exit("SUPABASE_SECRET_KEY не похож на секретный ключ — публичным ключом залить нельзя")

    scenes, merged = read_storyboard(storyboard_path)
    generated = read_generated(frames_path)
    frame_count = sum(len(s["frames"]) for s in scenes)

    print("Серия: «%s» № %d%s" % (args.project, args.number, (" — " + title) if title else ""))
    print("Раскадровка: %d сцен, %d кадров (%s)"
          % (len(scenes), frame_count, storyboard_path.relative_to(ROOT).as_posix()))
    print("Уже сгенерировано: %d кадров, %d версий картинок"
          % (len(generated), sum(len(g["versions"]) for g in generated.values())))
    for scene_n, code, text in merged:
        where = "к кадру %s" % code if code else "в сцене %d" % scene_n
        print("  строка без номера %s: «%s»" % (where, text.replace("\n", " ")))
    print()

    sb = Supabase(url, key)
    print("Заливка%s:" % (" (--dry-run, ничего не записываем)" if args.dry_run else ""))

    series_id = ensure_series(sb, args.dry_run, args.project, args.number, title, assignee)
    if args.dry_run and series_id is None:
        print("  дальше нечего показывать: серии ещё нет")
        return

    scene_ids, new_scenes = ensure_scenes(sb, series_id, scenes, args.dry_run)
    frame_ids, new_frames = ensure_frames(sb, series_id, scenes, scene_ids, generated, args.dry_run)
    new_versions = ensure_versions(sb, frame_ids, generated, args.dry_run)

    if args.dry_run:
        print("\nЭто был холостой прогон. Уберите --dry-run, чтобы залить.")
        return

    # Правило мастер-кадра живёт в базе: она сама пометит первый кадр каждой
    # сцены и откроет ему очередь, остальные оставит ждать.
    marked = sb.rpc("mark_anchors", {"p_series_id": series_id})
    print("  мастер-кадры: помечено %s (первый кадр каждой сцены)" % marked)

    # Запись в ленту — только когда что-то действительно появилось. Иначе
    # повторный запуск засорял бы ленту одинаковыми строками «залита раскадровка».
    # frames_ok намеренно не заполняем: это счётчик НАРИСОВАННЫХ кадров, а заливка
    # ничего не рисует — иначе панель воркера отрапортует «кадров сделано: 165».
    if new_scenes or new_frames or new_versions:
        sb.insert("events", [{
            "series_id": series_id, "kind": "import",
            "message": "Залита раскадровка: сцен %d, кадров %d, версий картинок %d"
                       % (new_scenes, new_frames, new_versions),
        }])

    report_statuses(sb, series_id)
    print("\nГотово.")


if __name__ == "__main__":
    main()
