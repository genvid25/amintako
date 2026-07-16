/*
  dashboard/config.js — конфигурация бэкенда для записи правок (одобрить / переделать).

  Как дашборд выбирает, куда писать правки (определяется автоматически, без сборки):
    1) если ниже заданы supabaseUrl и supabaseKey  -> пишем в Supabase REST (работает и на GitHub Pages);
    2) иначе, если дашборд открыт локально через serve.py (localhost) -> пишем в data/frames.json (POST /api/frame);
    3) иначе (GitHub Pages без Supabase) -> РЕЖИМ ПРОСМОТРА: кадры можно смотреть и скачивать, править нельзя.

  Пока это заглушка (значения null) — на Pages дашборд работает в режиме просмотра.
  Чтобы включить запись правок прямо со статичного хостинга, заполните поля своими значениями Supabase.

  Таблица в Supabase ожидается с колонками: id (text, первичный ключ), status (text), feedback (text).
  supabaseKey — это ПУБЛИЧНЫЙ anon-ключ (его можно держать во фронтенде при включённом RLS),
  а НЕ service_role. Никаких секретов в этот файл не кладём — он публичный.
*/
window.BACKEND_CONFIG = {
  supabaseUrl: null,   // напр. "https://abcdefgh.supabase.co"
  supabaseKey: null,   // публичный anon-ключ проекта Supabase
  table: "frames"      // имя таблицы с кадрами
};
