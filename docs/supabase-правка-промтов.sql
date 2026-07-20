-- =====================================================================
--  ДОПОЛНЕНИЕ К СХЕМЕ: правка промта руками
--  Файл: docs/supabase-правка-промтов.sql
--
--  ЗАЧЕМ. В дашборде появилась возможность отредактировать промт кадра.
--  В основной схеме (docs/supabase-schema.sql) такого пути нет:
--    * у кадра нет пометки «промт правил человек» — агенту нечем понять,
--      что этот текст переписывать нельзя;
--    * функция review_frame() умеет ровно две вещи — одобрить и вернуть на
--      переделку, промт она не трогает и трогать не должна;
--    * прямой UPDATE публичным ключом запрещён (и это правильно).
--  Значит, нужна отдельная точка входа — она ниже.
--
--  ЧТО ДЕЛАТЬ С ЭТИМ ФАЙЛОМ
--  1. Сначала выполните основной файл docs/supabase-schema.sql
--  2. SQL Editor -> New query -> вставьте весь этот текст -> Run
--  Скрипт безопасно запускать повторно.
--
--  ПОКА ЭТОТ ФАЙЛ НЕ ВЫПОЛНЕН дашборд не ломается: кадры читаются без новых
--  колонок, а на попытку сохранить промт он честно пишет, что база этого
--  ещё не умеет.
-- =====================================================================


-- =====================================================================
--  1. КОЛОНКИ: кто и когда правил промт руками
-- =====================================================================

alter table public.frames
  add column if not exists prompt_locked     boolean not null default false,
  add column if not exists prompt_updated_by text,
  add column if not exists prompt_updated_at timestamptz;

comment on column public.frames.prompt_locked is
  'true — промт отредактирован человеком. ВОРКЕР И АГЕНТ ЭТОТ ПРОМТ НЕ ПЕРЕПИСЫВАЮТ: '
  'правка сотрудника уходит в feedback, а prompt_en остаётся таким, как его оставил человек. '
  'Снимается только вручную: update frames set prompt_locked = false where id = ...;';
comment on column public.frames.prompt_updated_by is 'Имя сотрудника из members — показывается в карточке кадра.';
comment on column public.frames.prompt_updated_at is 'Когда промт правили руками — показывается в карточке кадра.';


-- =====================================================================
--  2. ФУНКЦИЯ set_prompt — единственный способ изменить промт из дашборда
--
--  Правила те же, что у review_frame(): проверяем личный токен, проверяем,
--  что серия закреплена за этим человеком, и меняем РОВНО три поля.
--  Статус кадра функция НЕ трогает: «сохранить промт» и «отправить на
--  перегенерацию» — два разных решения сотрудника. Второе идёт обычным
--  review_frame(..., 'redo', ...).
-- =====================================================================

create or replace function public.set_prompt(
  p_frame_id  bigint,
  p_prompt_en text,
  p_key       text default null
)
returns table (id bigint, prompt_en text, prompt_locked boolean,
               prompt_updated_by text, prompt_updated_at timestamptz)
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  m public.members;
  f public.frames;
  v_text text := trim(coalesce(p_prompt_en, ''));
begin
  -- 1. кто пришёл
  m := public.member_by_key(p_key);
  if m.id is null then
    raise exception 'Нет доступа: ссылка недействительна или отозвана'
      using errcode = '42501';
  end if;

  -- 2. пустой промт генератору отдавать нечего
  if length(v_text) < 10 then
    raise exception 'Промт слишком короткий — генератору нечего рисовать'
      using errcode = '22023';
  end if;

  -- 3. существует ли кадр и «его» ли это серия
  select * into f from public.frames fr where fr.id = p_frame_id;
  if f.id is null then
    raise exception 'Кадр % не найден', p_frame_id using errcode = 'P0002';
  end if;

  if m.series_ids is not null and not (f.series_id = any (m.series_ids)) then
    raise exception 'Нет доступа: эта серия закреплена не за вами'
      using errcode = '42501';
  end if;

  -- 4. собственно правка. Статус, feedback и версии не трогаем.
  update public.frames fr
     set prompt_en         = v_text,
         prompt_locked     = true,
         prompt_updated_by = m.name,
         prompt_updated_at = now(),
         updated_by        = m.name
   where fr.id = p_frame_id;

  -- 5. след в ленте — видно, кто и когда переписал промт
  insert into public.events (series_id, kind, message, details)
  values (f.series_id, 'review',
          m.name || ': промт кадра ' || f.code || ' изменён вручную',
          jsonb_build_object('frame', f.code, 'by', m.name, 'role', m.role,
                             'action', 'set_prompt'));

  return query
    select fr.id, fr.prompt_en, fr.prompt_locked, fr.prompt_updated_by, fr.prompt_updated_at
      from public.frames fr where fr.id = p_frame_id;
end;
$$;

revoke all on function public.set_prompt(bigint, text, text) from public;
grant execute on function public.set_prompt(bigint, text, text) to anon, authenticated;

comment on function public.set_prompt is
  'Правка промта сотрудником из дашборда. Меняет только prompt_en и пометки о ручной '
  'правке; статус кадра остаётся прежним. Проверяет личный токен и закреплённые серии.';


-- =====================================================================
--  3. ЕСЛИ ПРАВИТЬ ПРОМТЫ ДОЛЖЕН ТОЛЬКО РЕЖИССЁР
--     По умолчанию промт правит любой, у кого есть доступ к серии —
--     так же, как он может одобрить кадр. Чтобы оставить это право одному
--     режиссёру, добавьте в функцию после проверки токена (пункт 1):
--
--        if m.role <> 'director' then
--          raise exception 'Промты правит только режиссёр' using errcode = '42501';
--        end if;
-- =====================================================================


-- =====================================================================
--  4. ЧТО ДОЛЖЕН УЧЕСТЬ ВОРКЕР
--
--  Забирая кадры на перегенерацию, промт у кадра с prompt_locked = true
--  НЕ переписывать — брать frames.prompt_en как есть:
--
--      select id, code, prompt_en, feedback, prompt_locked
--        from frames
--       where status = 'redo' and series_id = ...;
--
--      если prompt_locked -> генерировать по prompt_en без переписывания
--      иначе               -> отдать feedback агенту, получить новый prompt_en
--
--  Пометка снимается только вручную — человек, который взял промт в свои
--  руки, отдаёт его обратно агенту осознанно, а не молча при первой правке.
-- =====================================================================
