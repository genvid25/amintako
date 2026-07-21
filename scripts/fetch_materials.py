#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
Забор материалов режиссёра из облака (Supabase Storage, бакет «materials»).

Режиссёр грузит раскадровку, сценарий и референсы через дашборд — вкладка
«Управление». Файлы ложатся в приватный бакет по пути
«series-<номер серии в базе>/<раздел>/<путь>». Этот скрипт забирает оттуда всё
новое и раскладывает по местам проекта:

    characters -> Референсы/ПЕРСОНАЖИ/<имя>
    locations  -> Референсы/ЛОКАЦИИ/<локация>/<имя>
    props      -> Референсы/ПРЕДМЕТЫ/<имя>
    storyboard -> ВХОДЯЩИЕ/РАСКАДРОВКА_<имя>.xlsx
    script     -> ВХОДЯЩИЕ/<имя>
    прочее     -> ВХОДЯЩИЕ/ПРОЧЕЕ/<путь>

Что уже забрано, помнит файл data/materials-state.json: повторный запуск не
качает то же самое второй раз. Заново скачивается только то, что режиссёр
перезалил (у объекта изменился etag или размер).

ПРО РУССКИЕ ИМЕНА — главное место скрипта.
Хранилище кириллицу в именах не принимает, отвечает «Invalid key». Поэтому
дашборд переводит имя в латиницу: «дорога к аулу.jpeg» ложится как
«doroga k aulu.jpeg». А в базе (frames.refs) и во всех промтах референсы
записаны по-русски — «ЛОКАЦИИ/Аул/дорога к аулу». Значит русское имя надо
вернуть. Три способа, по очереди:

  1) Дашборд при загрузке кладёт исходное имя и раздел в пользовательские
     метаданные объекта (заголовок x-metadata). Читаем их — это точный ответ.
  2) Метаданных нет (файл залит старым дашбордом или руками через сайт
     Supabase) — переводим в латиницу имена файлов, которые уже лежат в
     проекте, тем же правилом и ищем совпадение. Так узнаётся замена
     существующего референса: «Doroga k aulu.jpeg» найдёт «дорога к аулу.jpeg».
  3) Не нашлось — оставляем латиницу и пишем об этом в сводке отдельной
     строкой, чтобы человек переименовал файл руками.

Обратного перевода из латиницы в кириллицу не существует: «ж» и «зх» дают
одинаковое «zh», а «ъ» и «ь» пропадают совсем. Поэтому и нужны метаданные.

Ключ берётся из .env в корне проекта (SUPABASE_URL + SUPABASE_SECRET_KEY) или
из переменных окружения. В коде ключей нет и быть не должно.

Только стандартная библиотека Python 3 — ничего ставить не нужно.

Запуск:
  python3 scripts/fetch_materials.py --dry-run    # показать план, ничего не писать
  python3 scripts/fetch_materials.py              # забрать
  python3 scripts/fetch_materials.py --series 1   # только материалы одной серии
  python3 scripts/fetch_materials.py --force      # забрать заново, включая забранное
"""

import argparse
import json
import os
import re
import sys
import urllib.error
import urllib.parse
import urllib.request
from datetime import datetime, timezone
from pathlib import Path

# ---------------------------------------------------------------------------
# Пути (всё считается от корня проекта — папки на один уровень выше scripts/)
# ---------------------------------------------------------------------------
ROOT = Path(__file__).resolve().parent.parent
STATE_JSON = ROOT / "data" / "materials-state.json"
REFS_DIR = ROOT / "Референсы"
INBOX_DIR = ROOT / "ВХОДЯЩИЕ"

BUCKET = "materials"

# Раздел в бакете -> куда класть в проекте. Порядок разделов тот же, что во
# вкладке «Управление» дашборда (переменная MAT_CATS в dashboard/index.html).
CAT_DEST = {
    "characters": REFS_DIR / "ПЕРСОНАЖИ",
    "locations":  REFS_DIR / "ЛОКАЦИИ",
    "props":      REFS_DIR / "ПРЕДМЕТЫ",
    "storyboard": INBOX_DIR,
    "script":     INBOX_DIR,
}
CAT_LABEL = {
    "characters": "персонажи",
    "locations":  "локации",
    "props":      "предметы",
    "storyboard": "раскадровка",
    "script":     "сценарий",
}
OTHER_DEST = INBOX_DIR / "ПРОЧЕЕ"


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
# Перевод в латиницу — точная копия правила дашборда
#
# Держится в паре с функциями translit()/safeSeg() в dashboard/index.html.
# Меняете там — поменяйте и здесь, иначе способ 2 (поиск по уже лежащим
# файлам) начнёт промахиваться.
# ---------------------------------------------------------------------------
TRANSLIT = {
    'а': 'a', 'б': 'b', 'в': 'v', 'г': 'g', 'д': 'd', 'е': 'e', 'ё': 'e', 'ж': 'zh',
    'з': 'z', 'и': 'i', 'й': 'y', 'к': 'k', 'л': 'l', 'м': 'm', 'н': 'n', 'о': 'o',
    'п': 'p', 'р': 'r', 'с': 's', 'т': 't', 'у': 'u', 'ф': 'f', 'х': 'h', 'ц': 'c',
    'ч': 'ch', 'ш': 'sh', 'щ': 'sch', 'ъ': '', 'ы': 'y', 'ь': '', 'э': 'e',
    'ю': 'yu', 'я': 'ya',
}


def translit(s):
    """«Аул» -> «Aul», «дорога» -> «doroga». Заглавная остаётся заглавной."""
    out = []
    for ch in str(s):
        low = ch.lower()
        t = TRANSLIT.get(low)
        if t is None:
            out.append(ch)
        elif not t or ch == low:
            out.append(t)
        else:
            out.append(t[0].upper() + t[1:])
    return "".join(out)


def safe_seg(s):
    """Одно звено пути так, как его принимает хранилище."""
    s = translit(str(s))
    s = "".join(ch for ch in s if ch >= " ")      # управляющие знаки долой
    s = re.sub(r"[^\w!.*'() &$@=;:+,?-]", "_", s, flags=re.ASCII)
    s = re.sub(r"_{2,}", "_", s)
    s = re.sub(r"^[._]+", "", s)
    return s.strip()


def safe_rel(rel):
    return "/".join(x for x in (safe_seg(p) for p in str(rel).split("/")) if x)


def local_rel(rel):
    """Путь, по которому не страшно писать на диск: без «..», без корня, без
    windows-диска. Имя приходит из метаданных объекта в облаке, то есть
    снаружи, — а мы по нему создаём файлы. Проверить дешевле, чем потом чинить."""
    out = []
    for part in str(rel).replace("\\", "/").split("/"):
        part = part.strip().strip(".")
        if not part or ":" in part:
            continue
        out.append(part)
    return "/".join(out)


# ---------------------------------------------------------------------------
# Тонкий клиент Supabase Storage
# ---------------------------------------------------------------------------
class Storage:
    """Ровно то, что нужно забору: обойти бакет, спросить метаданные, скачать.
    Работает секретным ключом, поэтому политики бакета не мешают — но и
    запускать это можно только с машины, где лежит .env."""

    def __init__(self, url, key, timeout=120):
        self.base = url.rstrip("/") + "/storage/v1"
        self.key = key
        self.timeout = timeout

    def _call(self, method, path, data=None, headers=None):
        h = {"apikey": self.key, "Authorization": "Bearer " + self.key}
        if headers:
            h.update(headers)
        req = urllib.request.Request(self.base + path, data=data, headers=h, method=method)
        try:
            with urllib.request.urlopen(req, timeout=self.timeout) as resp:
                return resp.read()
        except urllib.error.HTTPError as e:
            detail = e.read().decode("utf-8", "replace")
            raise RuntimeError("%s %s -> %s %s"
                               % (method, path.split("?")[0], e.code, detail[:300])) from None
        except urllib.error.URLError as e:
            raise RuntimeError("Не достучались до хранилища: %s" % e.reason) from None

    @staticmethod
    def _quote(path):
        return "/".join(urllib.parse.quote(p, safe="") for p in str(path).split("/"))

    def _list_page(self, prefix, limit, offset):
        body = json.dumps({"prefix": prefix, "limit": limit, "offset": offset,
                           "sortBy": {"column": "name", "order": "asc"}}).encode("utf-8")
        raw = self._call("POST", "/object/list/" + BUCKET, body,
                         {"Content-Type": "application/json"})
        text = raw.decode("utf-8")
        return json.loads(text) if text.strip() else []

    def walk(self, prefix="", depth=8):
        """Хранилище отдаёт один уровень за раз — спускаемся внутрь сами.
        Строка с полем id — это файл, без него — папка."""
        files, folders = [], []
        offset, page = 0, 100
        while True:
            rows = self._list_page(prefix, page, offset)
            for r in rows:
                name = (r or {}).get("name")
                if not name:
                    continue
                if r.get("id"):
                    md = r.get("metadata") or {}
                    files.append({
                        "path": prefix + name,
                        "etag": (md.get("eTag") or "").strip('"'),
                        "size": md.get("size") or 0,
                        "at": r.get("updated_at") or r.get("created_at") or "",
                    })
                elif depth > 0:
                    folders.append(name)
            if len(rows) < page:
                break
            offset += page
        for f in folders:
            files.extend(self.walk(prefix + f + "/", depth - 1))
        return files

    def user_meta(self, path):
        """Пользовательские метаданные объекта: то, что дашборд положил при
        загрузке (исходное русское имя и раздел). Обычный список их не отдаёт —
        приходится спрашивать по одному объекту."""
        raw = self._call("GET", "/object/info/" + BUCKET + "/" + self._quote(path))
        info = json.loads(raw.decode("utf-8"))
        md = info.get("metadata")
        return md if isinstance(md, dict) else {}

    def download(self, path):
        return self._call("GET", "/object/" + BUCKET + "/" + self._quote(path))


# ---------------------------------------------------------------------------
# Учёт: что уже забрано
# ---------------------------------------------------------------------------
def load_state():
    if not STATE_JSON.exists():
        return {"version": 1, "objects": {}}
    try:
        data = json.loads(STATE_JSON.read_text(encoding="utf-8"))
    except (OSError, ValueError):
        print("  учёт       : data/materials-state.json не читается — считаю, что забрано ничего")
        return {"version": 1, "objects": {}}
    if not isinstance(data, dict):
        return {"version": 1, "objects": {}}
    data.setdefault("version", 1)
    if not isinstance(data.get("objects"), dict):
        data["objects"] = {}
    return data


def save_state(state):
    state["updated_at"] = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
    STATE_JSON.parent.mkdir(parents=True, exist_ok=True)
    STATE_JSON.write_text(
        json.dumps(state, ensure_ascii=False, indent=2, sort_keys=True) + "\n",
        encoding="utf-8")


# ---------------------------------------------------------------------------
# Куда класть файл
# ---------------------------------------------------------------------------
def split_path(obj_path):
    """«series-1/locations/Aul/doroga.jpeg» -> (1, 'locations', 'Aul/doroga.jpeg')."""
    parts = [p for p in obj_path.split("/") if p]
    series = None
    if parts and parts[0].startswith("series-"):
        tail = parts[0][len("series-"):]
        series = int(tail) if tail.isdigit() else None
        parts = parts[1:]
    cat = parts[0] if parts and parts[0] in CAT_DEST else None
    rel = "/".join(parts[1:] if cat else parts)
    return series, cat, rel


def find_by_translit(base_dir, rel_latin):
    """Способ 2: ищем среди уже лежащих файлов тот, чьё имя даёт ровно такую же
    латиницу. Возвращает его путь относительно base_dir — или None."""
    if not base_dir.exists():
        return None
    want = safe_rel(rel_latin).lower()
    if not want:
        return None
    hits = []
    for p in base_dir.rglob("*"):
        if not p.is_file() or p.name.startswith("."):
            continue
        rel = p.relative_to(base_dir).as_posix()
        if safe_rel(rel).lower() == want:
            hits.append(rel)
    return hits[0] if len(hits) == 1 else None


def storyboard_name(name):
    """Раскадровка узнаётся по имени, поэтому приводим её к одному виду."""
    stem, dot, ext = name.rpartition(".")
    if not dot:
        stem, ext = name, "xlsx"
    if stem.upper().startswith("РАСКАДРОВКА"):
        return "%s.%s" % (stem, ext)
    return "РАСКАДРОВКА_%s.%s" % (stem, ext)


def plan_one(st, obj):
    """Один объект бакета -> что с ним делать. Тут же восстанавливается имя."""
    series, cat, rel_latin = split_path(obj["path"])
    if not rel_latin:
        return None

    # --- имя: метаданные, потом поиск по проекту, потом как есть ---
    origin = "латиница как есть"
    rel = rel_latin
    try:
        meta = st.user_meta(obj["path"])
    except RuntimeError:
        meta = {}                                   # нет метаданных — не беда, идём дальше
    if not cat:
        cat = (meta.get("cat") or "").strip() or None
    meta_rel = local_rel(meta.get("orig") or "")
    if meta_rel:
        rel, origin = meta_rel, "из метаданных"
    else:
        base = CAT_DEST.get(cat)
        found = find_by_translit(base, rel_latin) if base else None
        if found:
            rel, origin = found, "по совпадению с проектом"

    # --- куда ---
    if cat in CAT_DEST:
        base = CAT_DEST[cat]
        name = rel.split("/")[-1]
        if cat == "storyboard":
            dest = base / storyboard_name(name)          # раскадровка кладётся плоско
        elif cat == "script":
            dest = base / name
        else:
            dest = base / rel
    else:
        dest = OTHER_DEST / rel

    return {
        "obj": obj, "series": series, "cat": cat or "прочее",
        "rel": rel, "origin": origin,
        "latin_left": origin == "латиница как есть" and not re.search(r"[А-Яа-яЁё]", rel),
        "dest": dest, "dest_rel": dest.relative_to(ROOT).as_posix(),
    }


# ---------------------------------------------------------------------------
# Запись на диск
# ---------------------------------------------------------------------------
def write_atomic(dest, blob):
    """Сначала во временный файл рядом, потом переименование: оборванная
    закачка не оставит после себя полуфайла, который сойдёт за референс."""
    dest.parent.mkdir(parents=True, exist_ok=True)
    tmp = dest.with_name(dest.name + ".part")
    tmp.write_bytes(blob)
    os.replace(str(tmp), str(dest))


def beside(dest):
    """Имя «рядом»: Амин.png -> Амин_new.png, при занятости _new2, _new3…"""
    stem, dot, ext = dest.name.rpartition(".")
    if not dot:
        stem, ext = dest.name, ""
    n = 1
    while True:
        suffix = "_new" if n == 1 else "_new%d" % n
        cand = dest.with_name(stem + suffix + (("." + ext) if ext else ""))
        if not cand.exists():
            return cand
        n += 1


def fmt_size(b):
    if b < 1024:
        return "%d Б" % b
    if b < 1024 * 1024:
        return "%.0f КБ" % (b / 1024.0)
    return ("%.1f МБ" % (b / 1024.0 / 1024.0)).replace(".", ",")


# ---------------------------------------------------------------------------
# Главное
# ---------------------------------------------------------------------------
def main():
    ap = argparse.ArgumentParser(
        description="Забор материалов режиссёра из облака (бакет materials)")
    ap.add_argument("--dry-run", action="store_true",
                    help="показать план, ничего не скачивать и не записывать")
    ap.add_argument("--series", type=int, metavar="N",
                    help="только материалы серии с этим id в базе (по умолчанию — все)")
    ap.add_argument("--force", action="store_true",
                    help="забрать заново даже то, что уже забиралось")
    args = ap.parse_args()

    load_dotenv(ROOT)
    url = os.environ.get("SUPABASE_URL", "").strip()
    key = os.environ.get("SUPABASE_SECRET_KEY", "").strip()
    if not url or not key:
        sys.exit("Нет доступа к облаку: в .env нужны SUPABASE_URL и SUPABASE_SECRET_KEY")
    if not key.startswith("sb_secret_") and not key.startswith("eyJ"):
        sys.exit("SUPABASE_SECRET_KEY не похож на секретный ключ — публичным ключом бакет не читается")

    st = Storage(url, key)
    state = load_state()
    known = state["objects"]

    prefix = ("series-%d/" % args.series) if args.series else ""
    print("Смотрю облако%s%s:"
          % (" (--dry-run, ничего не пишем)" if args.dry_run else "",
             (", серия %d" % args.series) if args.series else ""))
    try:
        objects = st.walk(prefix)
    except RuntimeError as e:
        sys.exit("  не получилось: %s" % e)

    if not objects:
        print("  в бакете materials пусто — режиссёр ничего не загружал.")
        return

    series_seen = sorted({s for s in (split_path(o["path"])[0] for o in objects) if s})
    print("  объектов   : %d%s"
          % (len(objects), (" (серии: %s)" % ", ".join(str(s) for s in series_seen)) if series_seen else ""))

    fresh, updated, skipped = [], [], 0
    conflicts, latin_left, missing = [], [], []
    storyboards, scripts = [], []

    for obj in sorted(objects, key=lambda o: o["path"]):
        was = known.get(obj["path"])
        same = bool(was) and was.get("etag") == obj["etag"] and was.get("size") == obj["size"]

        # Уже забирали и с тех пор не менялось — не трогаем.
        if same and not args.force:
            skipped += 1
            dest_rel = was.get("dest") or ""
            if dest_rel and not (ROOT / dest_rel).exists():
                missing.append(dest_rel)
            continue

        item = plan_one(st, obj)
        if not item:
            continue

        print("\n  %s  (%s, %s)"
              % (obj["path"], CAT_LABEL.get(item["cat"], "прочее"), fmt_size(obj["size"])))
        print("    имя      : %s — %s" % (item["rel"], item["origin"]))
        if item["latin_left"]:
            latin_left.append(item["dest_rel"])

        # В холостом прогоне не качаем: только показываем, куда бы легло.
        # Сравнить содержимое, не скачав, нельзя — поэтому там, где файл уже
        # есть, честно пишем «сравню, при отличии положу рядом».
        if args.dry_run:
            if not item["dest"].exists():
                mark = "новый"
                fresh.append(item["dest_rel"])
            elif was and was.get("dest") == item["dest_rel"]:
                mark = "перезалит режиссёром — обновлю"
                updated.append(item["dest_rel"])
            else:
                mark = "такой файл уже есть — сравню содержимое, при отличии положу рядом"
            print("    ляжет в  : %s   [%s]" % (item["dest_rel"], mark))
            continue

        try:
            blob = st.download(obj["path"])
        except RuntimeError as e:
            print("    ! не скачался: %s" % e)
            continue

        dest = item["dest"]
        if dest.exists():
            if dest.read_bytes() == blob:
                print("    уже на месте: %s" % item["dest_rel"])
                known[obj["path"]] = {"etag": obj["etag"], "size": obj["size"],
                                      "dest": item["dest_rel"],
                                      "at": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")}
                skipped += 1
                continue
            if was and was.get("dest") == item["dest_rel"]:
                write_atomic(dest, blob)                 # режиссёр перезалил — обновляем
                print("    обновлён : %s" % item["dest_rel"])
                updated.append(item["dest_rel"])
            else:
                dest = beside(dest)                      # чужой файл — не затираем молча
                write_atomic(dest, blob)
                item["dest_rel"] = dest.relative_to(ROOT).as_posix()
                print("    положил рядом: %s (такой файл уже был — нужно решение человека)"
                      % item["dest_rel"])
                conflicts.append(item["dest_rel"])
        else:
            write_atomic(dest, blob)
            print("    скачан   : %s" % item["dest_rel"])
            fresh.append(item["dest_rel"])

        if item["cat"] == "storyboard":
            storyboards.append(item["dest_rel"])
        if item["cat"] == "script":
            scripts.append(item["dest_rel"])

        known[obj["path"]] = {"etag": obj["etag"], "size": obj["size"],
                              "dest": item["dest_rel"],
                              "at": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")}

    # ---------------- сводка ----------------
    print("\nИтого:")
    print("  скачано новых            : %d" % len(fresh))
    print("  обновлено                : %d" % len(updated))
    print("  пропущено (уже забирали) : %d" % skipped)

    if conflicts:
        print("\n  Нужно решение человека — такие файлы уже были, новые легли рядом:")
        for c in conflicts:
            print("    %s" % c)
        print("  Посмотрите, какой оставить, лишний удалите.")
    if latin_left:
        print("\n  Остались с латинским именем (в облаке не было исходного имени):")
        for c in latin_left:
            print("    %s" % c)
        print("  Переименуйте по-русски — кадры ищут референс по русскому имени.")
    if missing:
        print("\n  Забирали раньше, но на диске сейчас нет:")
        for c in missing:
            print("    %s" % c)
        print("  Если файл нужен — запустите с --force.")
    if storyboards:
        print("\n  Новая раскадровка: %s" % ", ".join(storyboards))
        print("  Дальше — разобрать её и залить в базу, см. ВОРКЕР.md, шаг 1.2.")
    if scripts:
        print("\n  Новый сценарий: %s" % ", ".join(scripts))

    if args.dry_run:
        print("\nЭто был холостой прогон. Уберите --dry-run, чтобы забрать.")
        return

    save_state(state)
    print("\nГотово. Учёт: %s" % STATE_JSON.relative_to(ROOT).as_posix())


if __name__ == "__main__":
    main()
