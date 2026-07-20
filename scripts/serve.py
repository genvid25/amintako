#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
Локальный сервер дашборда кадров.

Запуск:
  python3 scripts/serve.py
Затем откройте в браузере:  http://localhost:8787

Что отдаёт:
  GET  /                     -> dashboard/index.html
  GET  /data/frames.json     -> очередь кадров
  GET  /images/...           -> готовые PNG
  GET  /Референсы/...        -> файлы референсов
  POST /api/frame            -> обновляет кадр (тело: {"id", "status", "feedback"})
  POST /api/prompt           -> сохраняет промт, отредактированный руками
                                (тело: {"id", "promptEn", "by"})

Только стандартная библиотека Python 3 — ничего ставить не нужно.
"""

import json
import os
import sys
from datetime import datetime, timezone
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import unquote, urlparse

ROOT = Path(__file__).resolve().parent.parent
FRAMES_JSON = ROOT / "data" / "frames.json"
INDEX_HTML = ROOT / "dashboard" / "index.html"
PORT = 8787

# Папки, которые разрешено отдавать наружу
ALLOWED_DIRS = ("data", "images", "Референсы", "dashboard")
# waiting_anchor — кадр ждёт, пока одобрят мастер-кадр своей сцены (как в облачной схеме)
ALLOWED_STATUSES = ("queued", "generating", "review", "approved", "redo", "waiting_anchor")

CONTENT_TYPES = {
    ".html": "text/html; charset=utf-8",
    ".css": "text/css; charset=utf-8",
    ".js": "text/javascript; charset=utf-8",
    ".json": "application/json; charset=utf-8",
    ".png": "image/png",
    ".jpg": "image/jpeg",
    ".jpeg": "image/jpeg",
    ".webp": "image/webp",
    ".txt": "text/plain; charset=utf-8",
    ".svg": "image/svg+xml",
}


def now_iso():
    return datetime.now(timezone.utc).replace(microsecond=0).isoformat().replace("+00:00", "Z")


def save_frames_atomic(data):
    data["updated"] = now_iso()
    tmp = FRAMES_JSON.with_name(FRAMES_JSON.name + ".tmp")
    tmp.write_text(json.dumps(data, ensure_ascii=False, indent=2), encoding="utf-8")
    tmp.replace(FRAMES_JSON)


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


def safe_path(url_path):
    """Превращает URL-путь в файл внутри проекта.
    Защита от выхода за пределы папки проекта (path traversal)."""
    rel = unquote(url_path).lstrip("/")
    target = (ROOT / rel).resolve()
    try:
        target.relative_to(ROOT)
    except ValueError:
        return None
    if not target.is_file():
        return None
    top = rel.split("/", 1)[0]
    if top not in ALLOWED_DIRS:
        return None
    return target


class Handler(BaseHTTPRequestHandler):
    # тихий лог: одна строка на запрос
    def log_message(self, fmt, *args):
        sys.stderr.write("  %s - %s\n" % (self.address_string(), fmt % args))

    # ---- отправка ответов ----
    def _send(self, code, body, ctype="application/json; charset=utf-8"):
        if isinstance(body, str):
            body = body.encode("utf-8")
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        if self.command != "HEAD":
            self.wfile.write(body)

    def _send_file(self, path):
        ctype = CONTENT_TYPES.get(path.suffix.lower(), "application/octet-stream")
        self._send(200, path.read_bytes(), ctype)

    def _json_error(self, code, message):
        self._send(code, json.dumps({"ok": False, "error": message}, ensure_ascii=False))

    # ---- GET ----
    def do_GET(self):
        path = urlparse(self.path).path
        if path in ("/", "/index.html"):
            if INDEX_HTML.is_file():
                self._send_file(INDEX_HTML)
            else:
                self._json_error(404, "dashboard/index.html не найден")
            return
        target = safe_path(path)
        if target:
            self._send_file(target)
        else:
            self._json_error(404, "не найдено: " + path)

    def do_HEAD(self):
        self.do_GET()

    # ---- POST ----
    def do_POST(self):
        path = urlparse(self.path).path
        if path == "/api/frame":
            self._api_frame()
        elif path == "/api/prompt":
            self._api_prompt()
        else:
            self._json_error(404, "неизвестный адрес: " + path)

    def _read_json(self):
        """Читает тело запроса. Возвращает None и сам отвечает ошибкой, если JSON битый."""
        try:
            length = int(self.headers.get("Content-Length", 0))
            return json.loads(self.rfile.read(length).decode("utf-8"))
        except (ValueError, json.JSONDecodeError):
            self._json_error(400, "тело запроса — не корректный JSON")
            return None

    def _find_frame(self, data, fid):
        return next((f for f in data.get("frames", []) if str(f.get("id")) == fid), None)

    # ---- POST /api/frame — одобрить кадр или отправить на переделку ----
    def _api_frame(self):
        payload = self._read_json()
        if payload is None:
            return

        fid = str(payload.get("id", "")).strip()
        status = str(payload.get("status", "")).strip()
        feedback = payload.get("feedback", "")

        if not fid:
            self._json_error(400, "не указан id кадра")
            return
        if status not in ALLOWED_STATUSES:
            self._json_error(400, "недопустимый статус: " + status)
            return

        data = json.loads(FRAMES_JSON.read_text(encoding="utf-8"))
        frame = self._find_frame(data, fid)
        if frame is None:
            self._json_error(404, "кадр не найден: " + fid)
            return

        frame["status"] = status
        # комментарий сотрудника сохраняем при отправке на переделку;
        # при одобрении — очищаем
        if status == "redo":
            frame["feedback"] = feedback or ""
        elif status == "approved":
            frame["feedback"] = ""
        save_frames_atomic(data)
        self._send(200, json.dumps({"ok": True, "frame": frame}, ensure_ascii=False))

    # ---- POST /api/prompt — сохранить промт, отредактированный руками ----
    #  Статус кадра НЕ трогаем: «отправить на перегенерацию» — отдельное решение
    #  сотрудника, которое уходит обычным POST /api/frame со статусом redo.
    def _api_prompt(self):
        payload = self._read_json()
        if payload is None:
            return

        fid = str(payload.get("id", "")).strip()
        prompt = str(payload.get("promptEn", "") or "").strip()
        by = str(payload.get("by", "") or "").strip()

        if not fid:
            self._json_error(400, "не указан id кадра")
            return
        if not prompt:
            self._json_error(400, "промт не может быть пустым")
            return

        data = json.loads(FRAMES_JSON.read_text(encoding="utf-8"))
        frame = self._find_frame(data, fid)
        if frame is None:
            self._json_error(404, "кадр не найден: " + fid)
            return

        frame["prompt_en"] = prompt
        # промт, который правил человек, агент дальше не переписывает
        frame["prompt_locked"] = True
        frame["prompt_updated_by"] = by
        frame["prompt_updated_at"] = now_iso()
        save_frames_atomic(data)
        self._send(200, json.dumps({"ok": True, "frame": frame}, ensure_ascii=False))


def main():
    load_dotenv(ROOT)  # подхватить ключ из .env (для единообразия со скриптом генерации)
    if not INDEX_HTML.is_file():
        print(f"  Внимание: не найден {INDEX_HTML}", file=sys.stderr)
    server = ThreadingHTTPServer(("127.0.0.1", PORT), Handler)
    print("=" * 60)
    print("  Дашборд кадров запущен.")
    print(f"  Откройте в браузере:   http://localhost:{PORT}")
    print("  Остановить сервер:     Ctrl+C")
    print("=" * 60)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        print("\n  Сервер остановлен.")
        server.shutdown()


if __name__ == "__main__":
    main()
