-- =====================================================================
--  РЕЖИССЁРСКИЙ РАЗДЕЛ ДАШБОРДА — ПРАВА И ТОЧКИ ВХОДА
--
--  ЧТО ЭТО. Дополнение к docs/supabase-schema.sql. Открывает режиссёру
--  (и только ему) три вещи, которых в базе ещё нет:
--    1) загрузку материалов в приватное хранилище (бакет materials);
--    2) создание серий и назначение аниматоров;
--    3) заведение сотрудников и выдачу личных ссылок.
--
--  КАК ВЫПОЛНИТЬ. Supabase → SQL Editor → New query → вставить весь файл
--  целиком → Run. Занимает пару секунд, выполняется одной транзакцией.
--  Скрипт можно запускать повторно: он сначала сносит свои объекты,
--  потом создаёт заново. Ничего чужого не трогает и данные не теряет.
--
--  ПОКА ЭТОТ ФАЙЛ НЕ ВЫПОЛНЕН: раздел «Управление» в дашборде открывается
--  и показывает серии, прогресс и ленту воркера (это читается публично),
--  но загрузка файлов и кнопки создания отвечают понятной ошибкой
--  «база ещё не знает про режиссёрский раздел». Ничего не ломается.
--
--  ПРИНЦИП ПРАВ — ТОТ ЖЕ, ЧТО В ОСНОВНОЙ СХЕМЕ. Публичный ключ
--  (sb_publishable_…) сам по себе не даёт ничего, кроме чтения. Право
--  что-то менять даёт личный токен сотрудника из ссылки ?key=…, который
--  дашборд отправляет заголовком x-review-key. Заголовок виден внутри
--  базы и в PostgREST (обычные запросы), и в Storage API: сервис хранилища
--  кладёт заголовки запроса в ту же настройку request.headers
--  (supabase/storage, src/internal/database/pg-connection.ts —
--   set_config('request.headers', …)). Поэтому политики ниже проверяют
--  токен ровно так же, как это делает member_by_key() в основной схеме.
-- =====================================================================


-- =====================================================================
--  1. БАКЕТ ДЛЯ МАТЕРИАЛОВ
--     Приватный: без личной ссылки файлы не отдаются даже по прямому URL.
--     50 МБ на файл — потолок одного объекта.
-- =====================================================================

insert into storage.buckets (id, name, public, file_size_limit)
values ('materials', 'materials', false, 52428800)
on conflict (id) do nothing;


-- =====================================================================
--  2. СНОСИМ СВОИ ПРЕЖНИЕ ОБЪЕКТЫ (чтобы файл можно было запускать снова)
--     Политики идут первыми: они зависят от функции is_director().
-- =====================================================================

drop policy if exists "materials: режиссёр читает"        on storage.objects;
drop policy if exists "materials: режиссёр загружает"     on storage.objects;
drop policy if exists "materials: режиссёр перезаписывает" on storage.objects;
drop policy if exists "materials: режиссёр удаляет"       on storage.objects;

drop function if exists public.director_team();
drop function if exists public.director_member_link(bigint);
drop function if exists public.director_member_add(text, text, bigint[]);
drop function if exists public.director_member_update(bigint, boolean, bigint[], boolean);
drop function if exists public.director_series_create(text, int, text, bigint[]);
drop function if exists public.director_series_assign(bigint, bigint[]);
drop function if exists public.director_event(bigint, text, text, jsonb);
drop function if exists public.director_only();


-- =====================================================================
--  3. КТО ПРИШЁЛ
-- =====================================================================

-- --- 3.1 is_director(): «в этом запросе токен режиссёра?» -------------
--  Единственная функция, которую видит политика хранилища. Отдаёт только
--  «да/нет» — ни имени, ни токена наружу не уходит.
--
--  Почему отдельная функция, а не проверка внутри политики: политика
--  выполняется правами того, кто пришёл (anon), а таблица members ему
--  недоступна. security definer снимает это ограничение, не открывая
--  саму таблицу.
create or replace function public.is_director()
returns boolean
language sql
stable
security definer
set search_path = public, pg_temp
as $$
  select coalesce((public.member_by_key(null::text)).role = 'director', false);
$$;

revoke all on function public.is_director() from public;
grant execute on function public.is_director() to anon, authenticated;

comment on function public.is_director is
  'Проверяет токен из заголовка x-review-key. Используется политиками бакета materials.';


-- --- 3.2 director_only(): пускать дальше только режиссёра -------------
--  Внутренний помощник для функций ниже. Наружу не выдаётся: вызвать его
--  можно только из другой security definer функции этого файла.
create or replace function public.director_only()
returns public.members
language plpgsql
stable
security definer
set search_path = public, pg_temp
as $$
declare
  m public.members;
begin
  m := public.member_by_key(null::text);
  if m.id is null then
    raise exception 'Нет доступа: ссылка недействительна или отозвана'
      using errcode = '42501';
  end if;
  if m.role <> 'director' then
    raise exception 'Этот раздел доступен только режиссёру'
      using errcode = '42501';
  end if;
  return m;
end;
$$;

revoke all on function public.director_only() from public, anon, authenticated;


-- =====================================================================
--  4. ПОЛИТИКИ ХРАНИЛИЩА
--
--  Права на саму таблицу storage.objects Supabase выдаёт публичной роли
--  по умолчанию, поэтому grant здесь не нужен: доступ отсекает RLS.
--  Проверено на этом проекте — загрузка публичным ключом без политики
--  отвечает «new row violates row-level security policy», то есть до
--  политики запрос доходит, а дальше не проходит.
--
--  Все четыре политики ограничены бакетом materials: на кадры, картинки
--  и любые другие бакеты они не влияют.
--
--  ЕСЛИ ЭТОТ БЛОК ВЫДАСТ ОШИБКУ вида «must be owner of table objects» —
--  значит, в проекте у роли postgres урезаны права на схему storage.
--  Тогда те же четыре политики заводятся руками: Storage → materials →
--  Policies → New policy → For full customization. Имя, операция (SELECT,
--  INSERT, UPDATE, DELETE), роли anon и authenticated, а в поле выражения —
--  строка из скобок using/with check ниже.
-- =====================================================================

-- Читать (список файлов и подписанные ссылки на скачивание).
-- Если позже понадобится показывать референсы и аниматорам — в этой
-- политике заменить is_director() на проверку любого активного токена.
create policy "materials: режиссёр читает"
  on storage.objects for select to anon, authenticated
  using ( bucket_id = 'materials' and public.is_director() );

-- Загружать новые файлы.
create policy "materials: режиссёр загружает"
  on storage.objects for insert to anon, authenticated
  with check ( bucket_id = 'materials' and public.is_director() );

-- Перезаписывать существующие (дашборд шлёт x-upsert: залить файл
-- с тем же именем — значит заменить старую версию).
create policy "materials: режиссёр перезаписывает"
  on storage.objects for update to anon, authenticated
  using      ( bucket_id = 'materials' and public.is_director() )
  with check ( bucket_id = 'materials' and public.is_director() );

-- Удалять.
create policy "materials: режиссёр удаляет"
  on storage.objects for delete to anon, authenticated
  using ( bucket_id = 'materials' and public.is_director() );


-- =====================================================================
--  5. КОМАНДА
-- =====================================================================

-- --- 5.1 director_team(): список сотрудников для раздела «Команда» ----
--  Токены НЕ возвращаются: за ссылкой дашборд ходит отдельно и по одной
--  (см. director_member_link) — чтобы чужие ключи не лежали в памяти
--  страницы просто так.
create or replace function public.director_team()
returns table (
  id         bigint,
  name       text,
  role       text,
  series_ids bigint[],
  active     boolean,
  created_at timestamptz,
  last_seen  timestamptz,
  reviewed   bigint
)
language plpgsql
stable
security definer
set search_path = public, pg_temp
as $$
begin
  perform public.director_only();

  return query
    select m.id, m.name, m.role, m.series_ids, m.active, m.created_at, m.last_seen,
           (select count(*)
              from public.events e
             where e.kind = 'review'
               and e.details ->> 'by' = m.name)          as reviewed
      from public.members m
     order by (m.role = 'director') desc, m.active desc, m.name;
end;
$$;

revoke all on function public.director_team() from public;
grant execute on function public.director_team() to anon, authenticated;

comment on function public.director_team is
  'Список сотрудников с прогрессом. Только для режиссёра, токены не отдаёт.';


-- --- 5.2 director_member_link(): личная ссылка сотрудника -------------
--  Отдаёт токен одного сотрудника — по кнопке «скопировать ссылку».
create or replace function public.director_member_link(p_member_id bigint)
returns text
language plpgsql
stable
security definer
set search_path = public, pg_temp
as $$
declare
  t text;
begin
  perform public.director_only();

  select m.token into t from public.members m where m.id = p_member_id;
  if t is null then
    raise exception 'Сотрудник не найден' using errcode = 'P0002';
  end if;
  return t;
end;
$$;

revoke all on function public.director_member_link(bigint) from public;
grant execute on function public.director_member_link(bigint) to anon, authenticated;


-- --- 5.3 director_member_add(): завести сотрудника --------------------
--  Токен генерируется здесь же и возвращается ровно один раз в ответе;
--  дашборд собирает из него готовую ссылку.
create or replace function public.director_member_add(
  p_name       text,
  p_role       text default 'animator',
  p_series_ids bigint[] default null          -- null = все серии
)
returns table (id bigint, name text, role text, token text)
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  m public.members;
  d public.members;
begin
  d := public.director_only();

  p_name := trim(coalesce(p_name, ''));
  if length(p_name) < 2 then
    raise exception 'Впишите имя сотрудника' using errcode = '22023';
  end if;
  if p_role not in ('director', 'animator') then
    raise exception 'Роль может быть только «director» или «animator»' using errcode = '22023';
  end if;
  if exists (select 1 from public.members x where x.active and lower(x.name) = lower(p_name)) then
    raise exception 'Сотрудник с именем «%» уже есть — возьмите другое имя, иначе перепутаются отметки о проверке', p_name
      using errcode = '23505';
  end if;

  insert into public.members (name, role, token, series_ids)
  values (p_name, p_role, replace(gen_random_uuid()::text, '-', ''),
          case when p_series_ids is null or cardinality(p_series_ids) = 0
               then null else p_series_ids end)
  returning * into m;

  insert into public.events (series_id, kind, message, details)
  values (case when m.series_ids is not null then m.series_ids[1] else null end,
          'member_added',
          d.name || ': добавлен сотрудник ' || m.name ||
          case when m.role = 'director' then ' (режиссёр)' else ' (аниматор)' end,
          jsonb_build_object('by', d.name, 'member', m.name, 'role', m.role));

  id := m.id; name := m.name; role := m.role; token := m.token;
  return next;
end;
$$;

revoke all on function public.director_member_add(text, text, bigint[]) from public;
grant execute on function public.director_member_add(text, text, bigint[]) to anon, authenticated;


-- --- 5.4 director_member_update(): отключить и переназначить серии ----
--  p_active     — null «не трогать», true/false — включить/отключить;
--  p_series_ids — null «не трогать», массив — закрепить именно эти серии;
--  p_all_series — true: снять ограничение, сотрудник видит все серии.
create or replace function public.director_member_update(
  p_member_id  bigint,
  p_active     boolean  default null,
  p_series_ids bigint[] default null,
  p_all_series boolean  default false
)
returns table (id bigint, name text, active boolean, series_ids bigint[])
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  m public.members;
  d public.members;
begin
  d := public.director_only();

  select * into m from public.members x where x.id = p_member_id;
  if m.id is null then
    raise exception 'Сотрудник не найден' using errcode = 'P0002';
  end if;

  -- Отключить самого себя — верный способ потерять доступ к разделу.
  if p_active is false and m.id = d.id then
    raise exception 'Нельзя отключить самого себя' using errcode = '22023';
  end if;

  update public.members x
     set active     = coalesce(p_active, x.active),
         series_ids = case
                        when p_all_series           then null
                        when p_series_ids is not null then p_series_ids
                        else x.series_ids
                      end
   where x.id = p_member_id
  returning * into m;

  insert into public.events (series_id, kind, message, details)
  values (null, 'member_updated',
          d.name || ': ' || m.name ||
          case when p_active is false then ' отключён'
               when p_active is true  then ' включён'
               else ' — обновлены серии' end,
          jsonb_build_object('by', d.name, 'member', m.name, 'active', m.active));

  id := m.id; name := m.name; active := m.active; series_ids := m.series_ids;
  return next;
end;
$$;

revoke all on function public.director_member_update(bigint, boolean, bigint[], boolean) from public;
grant execute on function public.director_member_update(bigint, boolean, bigint[], boolean) to anon, authenticated;


-- =====================================================================
--  6. СЕРИИ
-- =====================================================================

-- --- 6.1 director_series_create(): новая серия ------------------------
--  Кадры сюда не заводятся: их зальёт разбор раскадровки (load_storyboard).
create or replace function public.director_series_create(
  p_project    text     default null,        -- null = как у текущих серий
  p_number     int      default null,
  p_title      text     default null,
  p_member_ids bigint[] default null          -- кого сразу назначить
)
returns table (id bigint, project text, number int, title text)
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  s public.series;
  d public.members;
begin
  d := public.director_only();

  p_project := nullif(trim(coalesce(p_project, '')), '');
  if p_project is null then
    select x.project into p_project from public.series x order by x.id limit 1;
  end if;
  if p_project is null then
    raise exception 'Впишите название проекта' using errcode = '22023';
  end if;

  if p_number is null or p_number < 1 then
    raise exception 'Номер серии — целое число больше нуля' using errcode = '22023';
  end if;
  if exists (select 1 from public.series x
              where x.project = p_project and x.number = p_number) then
    raise exception 'Серия № % в проекте «%» уже заведена', p_number, p_project
      using errcode = '23505';
  end if;

  insert into public.series (project, number, title)
  values (p_project, p_number, nullif(trim(coalesce(p_title, '')), ''))
  returning * into s;

  -- назначенным аниматорам добавляем серию, «видящих всё» не трогаем
  if p_member_ids is not null and cardinality(p_member_ids) > 0 then
    update public.members x
       set series_ids = array_append(x.series_ids, s.id)
     where x.id = any (p_member_ids)
       and x.series_ids is not null
       and not (s.id = any (x.series_ids));
  end if;

  insert into public.events (series_id, kind, message, details)
  values (s.id, 'series_created',
          d.name || ': заведена серия № ' || s.number ||
          coalesce(' — ' || s.title, ''),
          jsonb_build_object('by', d.name, 'series', s.number));

  id := s.id; project := s.project; number := s.number; title := s.title;
  return next;
end;
$$;

revoke all on function public.director_series_create(text, int, text, bigint[]) from public;
grant execute on function public.director_series_create(text, int, text, bigint[]) to anon, authenticated;


-- --- 6.2 director_series_assign(): кто ведёт серию --------------------
--  Список приходит целиком: кого нет в списке — с серии снимается.
--  Сотрудников без ограничений (series_ids = null, «видит все серии»)
--  функция не трогает: иначе одно нажатие молча урезало бы им доступ.
create or replace function public.director_series_assign(
  p_series_id  bigint,
  p_member_ids bigint[] default '{}'
)
returns bigint
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  d public.members;
  n bigint := 0;
begin
  d := public.director_only();

  if not exists (select 1 from public.series x where x.id = p_series_id) then
    raise exception 'Серия не найдена' using errcode = 'P0002';
  end if;

  -- снять с тех, кого убрали из списка
  update public.members x
     set series_ids = array_remove(x.series_ids, p_series_id)
   where x.series_ids is not null
     and p_series_id = any (x.series_ids)
     and not (x.id = any (coalesce(p_member_ids, '{}')));

  -- добавить тем, кого отметили
  update public.members x
     set series_ids = array_append(x.series_ids, p_series_id)
   where x.id = any (coalesce(p_member_ids, '{}'))
     and x.series_ids is not null
     and not (p_series_id = any (x.series_ids));

  select count(*) into n
    from public.members x
   where x.active and (x.series_ids is null or p_series_id = any (x.series_ids));

  return n;
end;
$$;

revoke all on function public.director_series_assign(bigint, bigint[]) from public;
grant execute on function public.director_series_assign(bigint, bigint[]) to anon, authenticated;


-- =====================================================================
--  7. СЛЕД В ЛЕНТЕ СОБЫТИЙ
--     Дашборд отмечает здесь загрузку и удаление материалов — чтобы
--     воркер на следующем запуске увидел, что появилось новое.
-- =====================================================================

create or replace function public.director_event(
  p_series_id bigint,
  p_kind      text,
  p_message   text,
  p_details   jsonb default null
)
returns bigint
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  d public.members;
  e bigint;
begin
  d := public.director_only();

  -- Своими руками писать можно только «человеческие» события: подделать
  -- отчёт воркера (run_done и прочее) через дашборд нельзя.
  if p_kind not in ('materials_uploaded', 'materials_deleted', 'note') then
    raise exception 'Такое событие писать нельзя: %', p_kind using errcode = '22023';
  end if;

  insert into public.events (series_id, kind, message, details)
  values (p_series_id, p_kind,
          d.name || ': ' || left(coalesce(p_message, ''), 500),
          coalesce(p_details, '{}'::jsonb) || jsonb_build_object('by', d.name))
  returning id into e;

  return e;
end;
$$;

revoke all on function public.director_event(bigint, text, text, jsonb) from public;
grant execute on function public.director_event(bigint, text, text, jsonb) to anon, authenticated;

comment on function public.director_event is
  'Отметка режиссёра в ленте событий: загрузил/удалил материалы. '
  'ВНИМАНИЕ: лента читается публично — в message и details не должно быть секретов.';


-- =====================================================================
--  ГОТОВО.
--
--  Проверить, что всё встало (должно вернуться 4 строки — политики бакета):
--    select policyname from pg_policies
--     where schemaname = 'storage' and tablename = 'objects'
--       and policyname like 'materials:%';
--
--  И что функции на месте (7 строк):
--    select proname from pg_proc p
--      join pg_namespace n on n.oid = p.pronamespace
--     where n.nspname = 'public'
--       and proname in ('is_director','director_team','director_member_link',
--                       'director_member_add','director_member_update',
--                       'director_series_create','director_series_assign','director_event');
-- =====================================================================
