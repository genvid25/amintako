/*
  dashboard/config.js — подключение дашборда к общей базе (Supabase).

  Откуда дашборд берёт данные и куда пишет (определяется автоматически, без сборки):
    1) если ниже заданы supabaseUrl и supabaseKey  -> читаем кадры из базы,
       пишем через функции базы (работает и на GitHub Pages);
    2) иначе, если дашборд открыт локально через serve.py (localhost) -> читаем
       data/frames.json, пишем POST /api/frame и POST /api/prompt;
    3) иначе (GitHub Pages без базы) -> РЕЖИМ ПРОСМОТРА: кадры можно смотреть и
       скачивать, править нельзя.

  Пока это заглушка (значения null) — на Pages дашборд работает в режиме просмотра.

  ПРАВО ПРАВИТЬ ДАЁТ НЕ ЭТОТ ФАЙЛ, А ЛИЧНАЯ ССЫЛКА СОТРУДНИКА:
    https://genvid25.github.io/amintako/dashboard/?key=<токен из таблицы members>
  Без ?key= дашборд открывается на просмотр, даже когда ключи ниже заданы.
  Токен уходит в базу заголовком x-review-key и проверяется внутри функций
  whoami() / review_frame() / set_prompt().

  supabaseKey — ПУБЛИЧНЫЙ ключ (sb_publishable_… или старый anon). Его можно
  держать во фронтенде: записи он не даёт, RLS разрешает публичному ключу
  только чтение. Секретный ключ (sb_secret_… / service_role) сюда класть
  НЕЛЬЗЯ — файл лежит в публичном репозитории.
*/
window.BACKEND_CONFIG = {
  supabaseUrl: null,   // напр. "https://abcdefgh.supabase.co"
  supabaseKey: null,   // публичный ключ проекта Supabase
  seriesId: null       // id серии из таблицы series; null — взять первую по номеру
};
