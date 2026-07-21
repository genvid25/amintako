-- =====================================================================
--  ДОПОЛНЕНИЕ К СХЕМЕ: режиссёр решает по всем сериям
--  Файл: docs/supabase-роль-режиссёра.sql
--
--  ЗАЧЕМ. В members есть список закреплённых серий (series_ids), и обе
--  функции правки — review_frame() и set_prompt() — проверяли его одинаково
--  для всех. Для аниматора это правильно: он работает только со своими
--  сериями. Для режиссёра — нет: стоит назначить его на конкретную серию
--  через раздел «Управление», и он молча теряет право одобрять кадры во всех
--  остальных. При этом видеть и открывать он их продолжает: в «Управлении»
--  доступ решает роль, а не список серий. Получается перекос — кнопки в
--  дашборде есть, а база на них отвечает «Нет доступа».
--
--  ЧТО МЕНЯЕТСЯ. Ровно одно условие в каждой из двух функций: проверка
--  закреплённых серий больше не применяется к роли director. Всё остальное
--  в них — проверка токена, допустимые статусы, обязательный комментарий к
--  переделке, запись в ленту событий — слово в слово как было.
--
--  ЧТО НЕ МЕНЯЕТСЯ. Аниматор по-прежнему правит только закреплённые за ним
--  серии. Гость без токена по-прежнему не может ничего.
--
--  ЧТО ДЕЛАТЬ С ЭТИМ ФАЙЛОМ
--  1. Сначала должны быть выполнены docs/supabase-schema.sql и
--     docs/supabase-правка-промтов.sql — этот файл только переиздаёт
--     две функции из них, таблиц и колонок не создаёт.
--  2. Откройте свой проект на supabase.com
--  3. Слева в меню: SQL Editor -> кнопка «New query»
--  4. Скопируйте СЮДА ВЕСЬ текст этого файла и нажмите «Run» (или Cmd+Enter)
--  5. Внизу должна появиться табличка с двумя строками — это проверка,
--     что обе функции переизданы.
--
--  Скрипт безопасно запускать повторно: обе функции идут через
--  «create or replace», данные он не трогает.
-- =====================================================================


-- =====================================================================
--  1. review_frame — одобрить кадр или отправить на переделку
--     ЕДИНСТВЕННЫЙ способ для сотрудника изменить статус кадра.
-- =====================================================================

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

  -- ИЗМЕНЕНО ЭТИМ ФАЙЛОМ: режиссёра список серий не ограничивает — решать по
  -- всем сериям это его роль, а привязка к одной серии всегда была ошибкой
  -- данных, а не задумкой. Для аниматора проверка осталась строгой.
  if m.role <> 'director'
     and m.series_ids is not null
     and not (f.series_id = any (m.series_ids)) then
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
  'проверяет персональный токен и закреплённые серии (режиссёра они не ограничивают), '
  'пишет запись в ленту событий.';


-- =====================================================================
--  2. set_prompt — правка промта кадра руками
--     Статус кадра не трогает: «сохранить промт» и «отправить на
--     перегенерацию» — два разных решения сотрудника.
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

  -- ИЗМЕНЕНО ЭТИМ ФАЙЛОМ: то же правило, что и в review_frame выше —
  -- режиссёру список серий не мешает, аниматору мешает.
  if m.role <> 'director'
     and m.series_ids is not null
     and not (f.series_id = any (m.series_ids)) then
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
  'правке; статус кадра остаётся прежним. Проверяет личный токен и закреплённые серии '
  '(режиссёра они не ограничивают).';


-- =====================================================================
--  ГОТОВО. Ниже — проверка, что обе функции на месте и переизданы.
--  Должно быть две строки со словом «есть».
-- =====================================================================

select p.proname                                        as "Функция",
       case when pg_get_functiondef(p.oid) like '%m.role <> ''director''%'
            then 'есть' else 'НЕТ — запустите файл ещё раз' end
                                                        as "Правило про режиссёра"
  from pg_proc p
  join pg_namespace n on n.oid = p.pronamespace
 where n.nspname = 'public'
   and p.proname in ('review_frame', 'set_prompt')
 order by p.proname;
