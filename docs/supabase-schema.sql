-- =====================================================================
--  «ЭХО В ГОРАХ» — облачный бэкенд конвейера кадров (Supabase / PostgreSQL)
--  Файл: docs/supabase-schema.sql
--
--  ЧТО ДЕЛАТЬ С ЭТИМ ФАЙЛОМ
--  1. Откройте свой проект на supabase.com
--  2. Слева в меню: SQL Editor  ->  кнопка «New query»
--  3. Скопируйте СЮДА ВЕСЬ текст этого файла и нажмите «Run» (или Cmd+Enter)
--  4. Внизу должна появиться таблица со ссылками для сотрудников — пришлите её мне
--
--  Скрипт безопасно запускать повторно: он не ломает уже созданные данные
--  (везде «create ... if not exists» и «create or replace»).
--
--  СОДЕРЖАНИЕ
--    1. Таблицы (series, scenes, frames, versions, events, members)
--    2. Индексы
--    3. Триггеры: updated_at, правило «мастер-кадра», счётчик версий
--    4. Служебные функции
--    5. Где лежат картинки (объяснение — команд нет, бакет не нужен)
--    6. Безопасность: RLS — читать могут все, писать — никто (кроме воркера)
--    7. Точки входа для дашборда: whoami() и review_frame()
--    8. Витрина прогресса
--    9. Первичное наполнение: серия 2 + три участника
-- =====================================================================


-- =====================================================================
--  1. ТАБЛИЦЫ
-- =====================================================================

-- ---------------------------------------------------------------------
--  series — проект и серия. Одна строка = одна серия мультфильма.
-- ---------------------------------------------------------------------
create table if not exists public.series (
  id          bigint generated always as identity primary key,
  project     text        not null,                    -- 'ЭХО В ГОРАХ'
  number      int         not null,                    -- 2
  title       text        not null,                    -- 'Привяжи верблюда'
  assignee    text,                                    -- аниматор по умолчанию на всю серию
  status      text        not null default 'active',   -- active | done | archived
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now(),
  constraint series_number_uniq  unique (project, number),
  constraint series_status_chk   check (status in ('active','done','archived'))
);

comment on table  public.series is 'Серии мультфильма. Аниматор назначается на серию целиком.';
comment on column public.series.assignee is 'Кто ведёт серию. Может переопределяться на уровне сцены.';


-- ---------------------------------------------------------------------
--  scenes — сцены серии. ЗДЕСЬ ЖИВЁТ ПРАВИЛО «МАСТЕР-КАДРА»:
--  пока мастер-кадр сцены не одобрен, остальные кадры сцены не генерируются.
-- ---------------------------------------------------------------------
create table if not exists public.scenes (
  id              bigint generated always as identity primary key,
  series_id       bigint  not null references public.series(id) on delete cascade,
  n               int     not null,                    -- номер сцены: 1..11
  header          text,                                -- 'СЦЕНА 1 — НАТ. АУЛ — ДВОР ДОМА ХАМЗЫ — ДЕНЬ'
  location        text,                                -- 'НАТ. АУЛ — ДВОР ДОМА ХАМЗЫ'
  time_of_day     text,                                -- 'ДЕНЬ'
  assignee        text,                                -- переопределяет series.assignee, если задан

  -- --- мастер-кадр сцены ---
  anchor_frame_id bigint,                              -- ссылка на кадр-эталон (ставится триггером)
  anchor_image    text,                                -- путь одобренной картинки в хранилище
  anchor_status   text    not null default 'pending',  -- pending | approved

  created_at      timestamptz not null default now(),
  updated_at      timestamptz not null default now(),
  constraint scenes_n_uniq       unique (series_id, n),
  constraint scenes_anchor_chk   check (anchor_status in ('pending','approved'))
);

comment on column public.scenes.anchor_image is
  'Путь к одобренному мастер-кадру в репозитории («images/s01_01_v1.webp»). Воркер '
  'подкладывает эту картинку референсом ко всем остальным кадрам сцены — так сцена '
  'держит единый стиль и свет. Заполняется триггером в момент одобрения.';


-- ---------------------------------------------------------------------
--  frames — очередь кадров. Главная таблица, её читает дашборд.
--  Соответствует полям кадра из data/frames.json.
-- ---------------------------------------------------------------------
create table if not exists public.frames (
  id            bigint generated always as identity primary key,
  series_id     bigint  not null references public.series(id) on delete cascade,
  scene_id      bigint           references public.scenes(id) on delete cascade,

  code          text    not null,                  -- '1.3' — как в раскадровке
  scene_n       int     not null,                  -- 1  (дубль для быстрых фильтров)
  seq           int     not null,                  -- 3  порядковый номер кадра внутри сцены

  -- --- содержание кадра (из раскадровки) ---
  shot          text,                              -- 'СРЕДНИЙ ПО ГРУДЬ'
  action        text,                              -- что происходит
  dialogue      text,                              -- реплика (нужна только для эмоции)
  sound         text,
  chron         text,                              -- хронометраж, '5 СЕК.'
  refs          text[]  not null default '{}',     -- пути референсов внутри «Референсы/»

  -- --- работа агента ---
  prompt_en     text,                              -- текущий/следующий промт для генератора
  status        text    not null default 'queued',
  feedback      text    not null default '',       -- правка сотрудника, по-русски
  assignee      text,                              -- кто отвечает за кадр

  -- --- мастер-кадр ---
  is_anchor     boolean not null default false,    -- true у первого кадра сцены

  -- --- финальное одобрение режиссёра (см. review_frame) ---
  final_ok      boolean not null default false,
  approved_by   text,

  version_count int     not null default 0,        -- поддерживается триггером
  updated_at    timestamptz not null default now(),
  updated_by    text,                              -- 'Амин' / 'воркер' / 'система'

  constraint frames_code_uniq unique (series_id, code),
  constraint frames_status_chk check (
    status in ('queued','generating','review','approved','redo','waiting_anchor')
  )
);

comment on column public.frames.status is
  'queued — ждёт генерации; generating — генерируется прямо сейчас; review — ждёт проверки '
  'сотрудником; approved — одобрен; redo — на переделке (см. feedback); '
  'waiting_anchor — ждёт, пока одобрят мастер-кадр своей сцены.';
comment on column public.frames.final_ok is
  'true — кадр одобрен режиссёром (финально). Одобрение аниматора ставит только status=approved.';


-- ---------------------------------------------------------------------
--  versions — версии картинки кадра. Переделка добавляет новую версию,
--  старые НИКОГДА не переписываются: это история.
-- ---------------------------------------------------------------------
--  ВАЖНО: сами картинки в базе НЕ хранятся. Они лежат файлами в репозитории
--  genvid25/amintako и раздаются через GitHub Pages. База держит только пути.
create table if not exists public.versions (
  id           bigint generated always as identity primary key,
  frame_id     bigint  not null references public.frames(id) on delete cascade,
  v            int     not null,                   -- 1, 2, 3...
  provider     text,                               -- 'gemini' | 'openai'
  full_url     text,                               -- 'images/s01_03_v1.webp'    — 2K, по клику и на скачивание
  preview_url  text,                               -- 'previews/s01_03_v1.webp'  — 800px, для сетки дашборда
  original_png text,                               -- 'D:\amintako\png\s01_03_v1.png' — исходник на машине воркера
  prompt_en    text,                               -- что реально видел генератор
  bytes        bigint,                             -- размер полного WebP
  generated_at timestamptz not null default now(),
  constraint versions_v_positive  check (v > 0),
  constraint versions_frame_v_uniq unique (frame_id, v)
);

comment on column public.versions.full_url is
  'Путь ОТНОСИТЕЛЬНО корня репозитория, без домена: «images/s01_03_v1.webp». '
  'Полный адрес дашборд собирает сам от своего расположения — так одни и те же '
  'данные работают и на GitHub Pages, и локально через serve.py.';
comment on column public.versions.original_png is
  'Где лежит исходный PNG на машине воркера. В репозиторий PNG НЕ попадают '
  '(они в 6 раз тяжелее WebP), но остаются под рукой, если понадобится мастер-копия.';
comment on column public.versions.prompt_en is
  'Исторический факт. Задним числом не переписывается — при переделке пишется новая версия.';


-- ---------------------------------------------------------------------
--  events — лента событий воркера: что и когда он сделал, где упал.
-- ---------------------------------------------------------------------
create table if not exists public.events (
  id            bigint generated always as identity primary key,
  at            timestamptz not null default now(),
  series_id     bigint references public.series(id) on delete set null,
  kind          text not null,                     -- run_start | run_done | generated | review | error
  message       text,                              -- по-русски, показывается в дашборде
  frames_ok     int  not null default 0,
  frames_failed int  not null default 0,
  details       jsonb                              -- произвольные подробности
);

comment on table public.events is
  'Лента запусков воркера. ВНИМАНИЕ: таблица читается публично — '
  'НИКОГДА не пишите в message/details ключи API и тексты с секретами.';


-- ---------------------------------------------------------------------
--  members — сотрудники и их секретные ссылки.
--  ЭТА ТАБЛИЦА ЗАКРЫТА: её не видно ни дашборду, ни постороннему с anon-ключом.
--  Токен проверяется только внутри функции review_frame().
-- ---------------------------------------------------------------------
create table if not exists public.members (
  id         bigint generated always as identity primary key,
  name       text    not null,                     -- 'Амин'
  role       text    not null,                     -- director | animator
  token      text    not null unique,              -- секрет из ссылки ?key=...
  series_ids bigint[],                             -- NULL = доступ ко всем сериям
  active     boolean not null default true,
  created_at timestamptz not null default now(),
  last_seen  timestamptz,
  constraint members_role_chk check (role in ('director','animator'))
);

comment on table public.members is
  'Сотрудники и их персональные токены. Токен = «ключ от двери»: у каждого свой, '
  'чтобы можно было отозвать доступ одному, не трогая остальных (active = false).';


-- =====================================================================
--  2. ИНДЕКСЫ
-- =====================================================================

create index if not exists frames_order_idx    on public.frames (series_id, scene_n, seq);
create index if not exists frames_status_idx   on public.frames (status);
create index if not exists frames_assignee_idx on public.frames (assignee);
create index if not exists frames_scene_idx    on public.frames (scene_id);
create index if not exists versions_frame_idx  on public.versions (frame_id, v desc);
create index if not exists events_at_idx       on public.events  (at desc);
create index if not exists scenes_series_idx   on public.scenes  (series_id, n);


-- =====================================================================
--  3. ТРИГГЕРЫ
-- =====================================================================

-- --- 3.1 автоматическое обновление updated_at ------------------------
create or replace function public.tf_touch_updated_at()
returns trigger
language plpgsql
as $$
begin
  new.updated_at := now();
  return new;
end;
$$;

drop trigger if exists series_touch on public.series;
create trigger series_touch before update on public.series
  for each row execute function public.tf_touch_updated_at();

drop trigger if exists scenes_touch on public.scenes;
create trigger scenes_touch before update on public.scenes
  for each row execute function public.tf_touch_updated_at();

drop trigger if exists frames_touch on public.frames;
create trigger frames_touch before update on public.frames
  for each row execute function public.tf_touch_updated_at();


-- --- 3.2 новый кадр в запертой сцене сразу уходит в ожидание ---------
--  Если мастер-кадр сцены ещё не одобрен, обычный кадр не встаёт в очередь,
--  а получает статус waiting_anchor. Мастер-кадр (is_anchor) идёт в работу сразу.
create or replace function public.tf_frames_hold_until_anchor()
returns trigger
language plpgsql
as $$
begin
  if new.is_anchor then
    return new;                         -- мастер-кадр генерится первым, его никто не держит
  end if;

  if new.status = 'queued'
     and exists (select 1 from public.scenes s
                  where s.id = new.scene_id and s.anchor_status <> 'approved')
  then
    new.status := 'waiting_anchor';
  end if;

  return new;
end;
$$;

drop trigger if exists frames_hold_until_anchor on public.frames;
create trigger frames_hold_until_anchor before insert on public.frames
  for each row execute function public.tf_frames_hold_until_anchor();


-- --- 3.3 ГЛАВНОЕ ПРАВИЛО: одобрили мастер-кадр -> сцена открыта ------
--  Одобрение мастер-кадра:
--    * записывает его картинку в scenes.anchor_image (станет референсом сцены);
--    * переводит все waiting_anchor кадры этой сцены в queued.
--  Обратное движение (мастер-кадр отправили на переделку) снова запирает сцену,
--  но НЕ трогает кадры, которые уже успели сгенерироваться.
create or replace function public.tf_frames_anchor_gate()
returns trigger
language plpgsql
as $$
declare
  v_path text;
begin
  if new.is_anchor is not true or new.scene_id is null then
    return null;
  end if;

  -- мастер-кадр одобрен -> открываем сцену
  if new.status = 'approved' and coalesce(old.status, '') <> 'approved' then

    select v.full_url into v_path
      from public.versions v
     where v.frame_id = new.id
     order by v.v desc
     limit 1;

    update public.scenes
       set anchor_status   = 'approved',
           anchor_frame_id = new.id,
           anchor_image    = v_path
     where id = new.scene_id;

    update public.frames
       set status     = 'queued',
           updated_by = 'система: мастер-кадр одобрен'
     where scene_id = new.scene_id
       and id <> new.id
       and status = 'waiting_anchor';

  -- мастер-кадр перестал быть одобренным -> снова запираем сцену
  elsif coalesce(old.status, '') = 'approved' and new.status <> 'approved' then

    update public.scenes
       set anchor_status = 'pending',
           anchor_image  = null
     where id = new.scene_id;

    update public.frames f
       set status     = 'waiting_anchor',
           updated_by = 'система: мастер-кадр отправлен на переделку'
     where f.scene_id = new.scene_id
       and f.id <> new.id
       and f.status = 'queued'
       and f.version_count = 0;      -- уже отрисованные кадры не откатываем

  end if;

  return null;
end;
$$;

drop trigger if exists frames_anchor_gate on public.frames;
create trigger frames_anchor_gate after update of status on public.frames
  for each row execute function public.tf_frames_anchor_gate();


-- --- 3.4 счётчик версий кадра ---------------------------------------
create or replace function public.tf_versions_count()
returns trigger
language plpgsql
as $$
declare
  v_frame_id bigint;
begin
  -- при удалении строки NEW не существует, при вставке — не существует OLD
  if tg_op = 'DELETE' then
    v_frame_id := old.frame_id;
  else
    v_frame_id := new.frame_id;
  end if;

  update public.frames f
     set version_count = (select count(*) from public.versions v where v.frame_id = f.id)
   where f.id = v_frame_id;

  return null;
end;
$$;

drop trigger if exists versions_count on public.versions;
create trigger versions_count after insert or delete on public.versions
  for each row execute function public.tf_versions_count();


-- =====================================================================
--  4. СЛУЖЕБНЫЕ ФУНКЦИИ (для воркера, не для дашборда)
-- =====================================================================

-- Пометить мастер-кадры: в каждой сцене серии мастер-кадром становится
-- кадр с наименьшим seq. Воркер зовёт это после загрузки раскадровки.
create or replace function public.mark_anchors(p_series_id bigint)
returns int
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_count int;
begin
  update public.frames set is_anchor = false where series_id = p_series_id;

  with first_frames as (
    select distinct on (scene_id) id
      from public.frames
     where series_id = p_series_id and scene_id is not null
     order by scene_id, seq, code
  )
  update public.frames f
     set is_anchor = true
    from first_frames ff
   where f.id = ff.id;

  get diagnostics v_count = row_count;

  -- кадры незапертых сцен, застрявшие в ожидании, вернуть в очередь
  update public.frames f
     set status = 'queued'
    from public.scenes s
   where f.scene_id = s.id
     and f.series_id = p_series_id
     and f.status = 'waiting_anchor'
     and (s.anchor_status = 'approved' or f.is_anchor);

  return v_count;
end;
$$;

revoke all on function public.mark_anchors(bigint) from public, anon, authenticated;

comment on function public.mark_anchors is
  'Для воркера (service_role). Назначает мастер-кадром первый кадр каждой сцены.';


-- =====================================================================
--  5. ГДЕ ЛЕЖАТ КАРТИНКИ  (здесь нет ни одной команды — только объяснение)
--
--  Картинки в Supabase НЕ хранятся, и бакет создавать НЕ НУЖНО.
--
--  Почему: на бесплатном тарифе хранилище Supabase — 1 ГБ на всю организацию,
--  а исходящий трафик 5 ГБ в месяц, причём общий на все сервисы. Одна серия
--  кадров съела бы заметную часть, а сетка превью в дашборде пробила бы трафик.
--
--  Поэтому картинки лежат файлами в самом репозитории genvid25/amintako и
--  раздаются через GitHub Pages — там лимит 1 ГБ на сайт и 100 ГБ трафика
--  в месяц, то есть в 20 раз просторнее по трафику и бесплатно.
--
--      images/s01_03_v1.webp      — 2K WebP q90, ~400 КБ, по клику и на скачивание
--      previews/s01_03_v1.webp    — 800px WebP q80, ~50 КБ, для сетки дашборда
--
--  Исходные PNG (~2.4 МБ) в репозиторий не попадают — остаются на машине
--  воркера, путь к ним пишется в versions.original_png.
--
--  База хранит только пути (versions.full_url / preview_url). Это килобайты,
--  и в бесплатные 500 МБ базы они помещаются с многократным запасом.
-- =====================================================================

-- Политик на INSERT/UPDATE/DELETE НЕТ и быть не должно:
-- значит, посторонний с публичным ключом ничего не зальёт и не удалит.
-- Воркер работает секретным ключом service_role, который RLS не проверяет.


-- =====================================================================
--  6. БЕЗОПАСНОСТЬ (RLS)
--
--  Модель простая и жёсткая:
--    ЧИТАТЬ  — может кто угодно (дашборд лежит на публичном GitHub Pages).
--    ПИСАТЬ  — напрямую НЕ МОЖЕТ НИКТО с публичным ключом.
--              Сотрудник меняет статус только через функцию review_frame(),
--              которая проверяет его личный токен и разрешает ровно две вещи:
--              «одобрить» и «отправить на переделку».
--              Воркер пишет ключом service_role — он обходит RLS.
--
--  Почему так, а не «политика на UPDATE»: при прямом UPDATE любой человек,
--  подобрав ссылку, смог бы переписать промты или снести кадры. Через функцию
--  он физически не может тронуть ничего, кроме status и feedback.
-- =====================================================================

alter table public.series   enable row level security;
alter table public.scenes   enable row level security;
alter table public.frames   enable row level security;
alter table public.versions enable row level security;
alter table public.events   enable row level security;
alter table public.members  enable row level security;

-- Отбираем у публичной роли ВСЕ права и возвращаем только чтение.
-- (Supabase по умолчанию выдаёт anon права на запись в public-схему,
--  поэтому одной RLS мало — снимаем и сами гранты.)
--
-- Права на чтение ниже выдаются ЯВНО и намеренно: Supabase постепенно убирает
-- автоматические гранты для anon/authenticated на новые таблицы, доступ
-- становится «по запросу». Явный grant делает скрипт независимым от того,
-- какое поведение включено в вашем проекте.
revoke all on public.series, public.scenes, public.frames,
              public.versions, public.events, public.members
  from anon, authenticated;

grant select on public.series, public.scenes, public.frames,
                public.versions, public.events
  to anon, authenticated;

-- members не выдаём никому: токены не должны утечь ни при каких запросах.

-- --- политики чтения ---
drop policy if exists "series: читают все"   on public.series;
create policy "series: читают все"   on public.series   for select to anon, authenticated using (true);

drop policy if exists "scenes: читают все"   on public.scenes;
create policy "scenes: читают все"   on public.scenes   for select to anon, authenticated using (true);

drop policy if exists "frames: читают все"   on public.frames;
create policy "frames: читают все"   on public.frames   for select to anon, authenticated using (true);

drop policy if exists "versions: читают все" on public.versions;
create policy "versions: читают все" on public.versions for select to anon, authenticated using (true);

drop policy if exists "events: читают все"   on public.events;
create policy "events: читают все"   on public.events   for select to anon, authenticated using (true);

-- Для members политик нет вообще => таблица невидима для публичного ключа.


-- =====================================================================
--  7. ТОЧКИ ВХОДА ДЛЯ ДАШБОРДА
--
--  Дашборд ходит ровно в две функции. Токен сотрудника берётся из ссылки
--  (?key=...) и передаётся либо заголовком «x-review-key», либо параметром.
-- =====================================================================

-- --- 7.1 приватный помощник: найти сотрудника по токену --------------
create or replace function public.member_by_key(p_key text)
returns public.members
language sql
stable
security definer
set search_path = public, pg_temp
as $$
  select m.*
    from public.members m
   where m.active
     and m.token = nullif(trim(coalesce(
           -- сначала пробуем заголовок запроса, потом явный параметр функции
           nullif(nullif(current_setting('request.headers', true), '')::json ->> 'x-review-key', ''),
           p_key)), '')
   limit 1;
$$;

revoke all on function public.member_by_key(text) from public, anon, authenticated;


-- --- 7.2 whoami: «кто я и что мне можно» -----------------------------
--  Дашборд зовёт это при загрузке: если вернулась строка — показываем кнопки,
--  если пусто — режим просмотра. Токен обратно НЕ возвращается.
create or replace function public.whoami(p_key text default null)
returns table (name text, role text, series_ids bigint[])
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  m public.members;
begin
  m := public.member_by_key(p_key);
  if m.id is null then
    return;                              -- пусто = гость, только просмотр
  end if;

  update public.members set last_seen = now() where id = m.id;

  name       := m.name;
  role       := m.role;
  series_ids := m.series_ids;
  return next;
end;
$$;

revoke all on function public.whoami(text) from public;
grant execute on function public.whoami(text) to anon, authenticated;


-- --- 7.3 review_frame: одобрить кадр или отправить на переделку ------
--  ЕДИНСТВЕННЫЙ способ для сотрудника что-то изменить.
--  Проверяет: токен жив, серия «его», статус допустимый, правка не пустая.
create or replace function public.review_frame(
  p_frame_id bigint,
  p_status   text,                        -- 'approved' | 'redo'
  p_feedback text default '',
  p_key      text default null
)
returns table (id bigint, status text, feedback text, final_ok boolean, updated_by text)
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  m public.members;
  f public.frames;
begin
  -- 1. кто пришёл
  m := public.member_by_key(p_key);
  if m.id is null then
    raise exception 'Нет доступа: ссылка недействительна или отозвана'
      using errcode = '42501';
  end if;

  -- 2. что можно ставить: только одобрение или переделка
  if p_status not in ('approved', 'redo') then
    raise exception 'Можно только «approved» или «redo», получено: %', p_status
      using errcode = '22023';
  end if;

  -- 3. переделка без объяснения бессмысленна — агенту нечего будет читать
  if p_status = 'redo' and length(trim(coalesce(p_feedback, ''))) < 3 then
    raise exception 'Для переделки нужен комментарий: что именно поправить'
      using errcode = '22023';
  end if;

  -- 4. существует ли кадр и «его» ли это серия
  select * into f from public.frames fr where fr.id = p_frame_id;
  if f.id is null then
    raise exception 'Кадр % не найден', p_frame_id using errcode = 'P0002';
  end if;

  if m.series_ids is not null and not (f.series_id = any (m.series_ids)) then
    raise exception 'Нет доступа: эта серия закреплена не за вами'
      using errcode = '42501';
  end if;

  -- 5. нечего одобрять, пока картинки нет
  if p_status = 'approved' and f.version_count = 0 then
    raise exception 'Кадр ещё не сгенерирован — одобрять нечего'
      using errcode = '22023';
  end if;

  -- 6. собственно правка. Больше НИЧЕГО изменить нельзя.
  update public.frames fr
     set status      = p_status,
         feedback    = case when p_status = 'redo' then trim(p_feedback) else '' end,
         final_ok    = case when p_status = 'approved' and m.role = 'director' then true
                            else false end,
         approved_by = case when p_status = 'approved' then m.name else null end,
         updated_by  = m.name
   where fr.id = p_frame_id;

  -- 7. след в ленте — чтобы было видно, кто и когда решил
  insert into public.events (series_id, kind, message, details)
  values (f.series_id, 'review',
          m.name || ': кадр ' || f.code ||
          case when p_status = 'approved' then ' одобрен' else ' на переделку' end,
          jsonb_build_object('frame', f.code, 'status', p_status,
                             'by', m.name, 'role', m.role));

  return query
    select fr.id, fr.status, fr.feedback, fr.final_ok, fr.updated_by
      from public.frames fr where fr.id = p_frame_id;
end;
$$;

revoke all on function public.review_frame(bigint, text, text, text) from public;
grant execute on function public.review_frame(bigint, text, text, text) to anon, authenticated;

comment on function public.review_frame is
  'Единственная разрешённая сотруднику операция. Меняет только status и feedback, '
  'проверяет персональный токен и закреплённые серии, пишет запись в ленту событий.';


-- =====================================================================
--  8. ВИТРИНА ПРОГРЕССА (для счётчиков в шапке дашборда)
-- =====================================================================

create or replace view public.progress
with (security_invoker = true) as
select f.series_id,
       s.project,
       s.number as series_number,
       s.title  as series_title,
       count(*)                                              as total,
       count(*) filter (where f.status = 'queued')           as queued,
       count(*) filter (where f.status = 'generating')       as generating,
       count(*) filter (where f.status = 'review')           as review,
       count(*) filter (where f.status = 'approved')         as approved,
       count(*) filter (where f.status = 'redo')             as redo,
       count(*) filter (where f.status = 'waiting_anchor')   as waiting_anchor,
       max(f.updated_at)                                     as updated_at
  from public.frames f
  join public.series s on s.id = f.series_id
 group by f.series_id, s.project, s.number, s.title;

grant select on public.progress to anon, authenticated;


-- =====================================================================
--  9. ПЕРВИЧНОЕ НАПОЛНЕНИЕ
--     Заводим текущую серию и трёх участников со случайными токенами.
--     Кадры зальёт воркер — вручную ничего вносить не нужно.
-- =====================================================================

insert into public.series (project, number, title, assignee)
values ('ЭХО В ГОРАХ', 2, 'Привяжи верблюда', 'Амин')
on conflict (project, number) do nothing;

-- Токены генерируются случайно и ровно один раз: повторный запуск скрипта
-- НЕ поменяет уже выданные ссылки (защита — «where not exists» по имени).
with s2 as (
  select id from public.series where project = 'ЭХО В ГОРАХ' and number = 2
),
newcomers (name, role, scope) as (
  values ('Иса',   'director', 'all'),      -- режиссёр видит и решает всё
         ('Амин',  'animator', 'series-2'), -- аниматоры пока оба на серии 2
         ('Тимур', 'animator', 'series-2')
)
insert into public.members (name, role, token, series_ids)
select n.name,
       n.role,
       replace(gen_random_uuid()::text, '-', ''),
       case when n.scope = 'all' then null::bigint[]
            else (select array_agg(s2.id) from s2) end
  from newcomers n
 where not exists (select 1 from public.members m where m.name = n.name);


-- =====================================================================
--  ГОТОВО. Ниже — ссылки для сотрудников.
--  Скопируйте таблицу целиком и пришлите её мне (или раздайте сами:
--  каждому — ТОЛЬКО его строку, ссылки личные).
-- =====================================================================

select m.name                          as "Кто",
       case m.role when 'director' then 'режиссёр (видит всё)'
                   else 'аниматор' end as "Роль",
       'https://genvid25.github.io/amintako/dashboard/?key=' || m.token
                                       as "Личная ссылка на дашборд"
  from public.members m
 where m.active
 order by m.role desc, m.name;
