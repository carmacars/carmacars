-- 5199 (R51 staff, REQ-130; docs/changes/2026-11-27-r51-staff.md): the academy is answered by the person, not by an AI.
-- The owner (Nov 27 17:29): "put it on the academy on each question as a disclaimer somewhere that computer use is not
-- allowed and carmacars will sue u and make sure that it just makes sure that they cant use ai and claude chrome to
-- complete the tests".
--   1. The quiz page sends what it saw with each submit (integrity): automation signals (navigator.webdriver, markers that
--      drivers inject, a devtools protocol probe), events not made by a person (isTrusted false), a mouse that pressed
--      without moving there (pointer jumps), paste and copy attempts (both blocked), times the page lost focus or was
--      hidden, and the gap between the first picks of each question. app.academy_integrity_reasons turns it into reasons;
--      the floor per answer and the focus losses allowed are Program settings.
--   2. A submit with a reason is voided (academy_integrity_void, on by default): no grading, an attempt kept with voided,
--      its reasons and what the page saw, the started quiz ended (the cooldown and the tries a day count it), and the
--      Admins get the alert academy_integrity. With the setting off the attempt is graded and the reasons are kept and
--      alerted only. A submit with no report (not from the page: the API, the tests) is graded as before: a script that
--      can call the API can also send a clean report, so its absence proves nothing.
--   3. Admin reads the voided attempts of a person (door admin_read academy_voided) on Admin > Academy > the person.
-- No web page can stop an AI agent that controls the browser: these checks make it detectable and void the attempt.
-- No applied migration is edited: academy_quiz_submit is wrapped (_pre5199); the door is wrapped (_pre5199).
set local check_function_bodies = off;

create function pg_temp.copy_grants(p_new regprocedure, p_old regprocedure) returns void
language plpgsql as $$
declare g text;
begin
  execute format('revoke all on function %s from public, anon, authenticated', p_new);
  foreach g in array array['anon', 'authenticated', 'service_role'] loop
    if has_function_privilege(g, p_old, 'execute') then execute format('grant execute on function %s to %I', p_new, g); end if;
  end loop;
end $$;

-- ================================================================ 1. settings and the attempt's record
alter table program_settings
  add column if not exists academy_integrity_void boolean not null default true,
  add column if not exists academy_focus_loss_max integer not null default 2 check (academy_focus_loss_max between 0 and 50),
  add column if not exists academy_answer_floor_seconds integer not null default 2 check (academy_answer_floor_seconds between 0 and 30);
comment on column program_settings.academy_integrity_void is 'Academy (5199): a quiz submit with an automation or cheating signal is voided (not graded, kept with its reasons, Admin alerted). Off: graded, the reasons kept and alerted only.';
comment on column program_settings.academy_focus_loss_max is 'Academy (5199): how many times the quiz page may lose focus or be hidden (another tab or app) before the attempt is flagged.';
comment on column program_settings.academy_answer_floor_seconds is 'Academy (5199): a first answer picked faster than this after the one before counts as too fast; half the questions (at least 3) too fast flags the attempt. 0 for off.';

alter table academy_attempts
  add column if not exists voided boolean not null default false,
  add column if not exists void_reasons text[] not null default '{}',
  add column if not exists integrity jsonb;
comment on column academy_attempts.voided is 'Academy (5199): voided for an automation or cheating signal; never a pass.';
comment on column academy_attempts.void_reasons is 'Academy (5199): the reasons the page''s report gave (automation, synthetic_events, pointer_jumps, paste, copy, focus_lost, too_fast). Also kept when the setting only flags.';
comment on column academy_attempts.integrity is 'Academy (5199): what the quiz page saw (counts and flags only, no answers or text).';
alter table academy_attempts add constraint academy_attempts_voided_not_passed check (not (voided and passed));

-- ================================================================ 2. the reasons
-- j: {webdriver, cdp: bool, markers: [text], untrusted, jumps, pastes, copies, leaves: int, gaps_ms: [int]}; n: the questions
create function app.academy_integrity_reasons(j jsonb, n integer) returns text[]
language sql stable security definer set search_path = public, app, pg_temp as $$
  with s as (select (app.settings()).academy_focus_loss_max fl, (app.settings()).academy_answer_floor_seconds fs),
  x as (select coalesce(j, 'null'::jsonb) j),
  v as (select x.j,
          case when jsonb_typeof(x.j) = 'object' then x.j else '{}'::jsonb end o from x),
  i as (select v.j, v.o,
          (case when jsonb_typeof(v.o -> 'gaps_ms') = 'array' then (select count(*) from jsonb_array_elements(v.o -> 'gaps_ms') g
              where jsonb_typeof(g) = 'number' and (g #>> '{}')::numeric < (select fs from s) * 1000) else 0 end)::int fast,
          least(greatest(coalesce(case when jsonb_typeof(v.o -> 'untrusted') = 'number' then (v.o ->> 'untrusted')::numeric end, 0), 0), 100000)::int untrusted,
          coalesce(case when jsonb_typeof(v.o -> 'jumps') = 'number' then (v.o ->> 'jumps')::numeric end, 0)::int jumps,
          coalesce(case when jsonb_typeof(v.o -> 'pastes') = 'number' then (v.o ->> 'pastes')::numeric end, 0)::int pastes,
          coalesce(case when jsonb_typeof(v.o -> 'copies') = 'number' then (v.o ->> 'copies')::numeric end, 0)::int copies,
          coalesce(case when jsonb_typeof(v.o -> 'leaves') = 'number' then (v.o ->> 'leaves')::numeric end, 0)::int leaves
        from v)
  select array_remove(array[
      case when (i.o ->> 'webdriver') = 'true' or (i.o ->> 'cdp') = 'true'
             or (jsonb_typeof(i.o -> 'markers') = 'array' and jsonb_array_length(i.o -> 'markers') > 0) then 'automation' end,
      case when i.untrusted > 0 then 'synthetic_events' end,
      case when i.jumps >= 2 then 'pointer_jumps' end,
      case when i.pastes > 0 then 'paste' end,
      case when i.copies > 0 then 'copy' end,
      case when i.leaves > (select fl from s) then 'focus_lost' end,
      case when (select fs from s) > 0 and i.fast >= greatest(3, ceil(greatest(n, 1) / 2.0)::int) then 'too_fast' end], null)
    from i
$$;
comment on function app.academy_integrity_reasons(jsonb, integer) is 'Academy (5199): the cheating or automation reasons in the quiz page''s report; empty when none.';

-- the words of the reasons, for the alert and the page
create function app.academy_integrity_words(p text[]) returns text
language sql immutable set search_path = public, app, pg_temp as $$
  select coalesce(string_agg(case r when 'automation' then 'browser automation detected'
                                     when 'synthetic_events' then 'clicks or answers not made by a person'
                                     when 'pointer_jumps' then 'the pointer pressed without moving there'
                                     when 'paste' then 'paste attempted'
                                     when 'copy' then 'copying the questions attempted'
                                     when 'focus_lost' then 'left the quiz page too often'
                                     when 'too_fast' then 'answers picked faster than reading allows'
                                     else r end, '; ' order by o), '')
    from unnest(p) with ordinality u(r, o)
$$;

-- ================================================================ 3. the submit
alter function app.academy_quiz_submit(uuid, jsonb) rename to academy_quiz_submit_pre5199;
create function app.academy_quiz_submit(p_user uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app, pg_temp as $$
declare
  s program_settings := app.settings();
  v_sec uuid;
  v_n integer;
  v_reasons text[];
  v_integrity jsonb := case when jsonb_typeof(p -> 'integrity') = 'object' then p -> 'integrity' end;
  st academy_quiz_starts;
  v_att uuid;
  r jsonb;
begin
  -- Admins preview quizzes without a start: as before
  if app.user_is_admin(p_user) then return app.academy_quiz_submit_pre5199(p_user, p - 'integrity'); end if;
  v_sec := app.academy_section_id(p_user, p);
  select count(*) into v_n from academy_questions where section_id = v_sec;
  v_reasons := app.academy_integrity_reasons(p -> 'integrity', v_n);
  -- only what the page counted is kept (no answers, no text): numbers, flags and the marker names
  v_integrity := case when v_integrity is null then null else jsonb_strip_nulls(jsonb_build_object(
      'webdriver', v_integrity -> 'webdriver', 'cdp', v_integrity -> 'cdp',
      'markers', case when jsonb_typeof(v_integrity -> 'markers') = 'array' then (select jsonb_agg(left(m #>> '{}', 40)) from (select m from jsonb_array_elements(v_integrity -> 'markers') m limit 10) q) end,
      'untrusted', v_integrity -> 'untrusted', 'jumps', v_integrity -> 'jumps', 'pastes', v_integrity -> 'pastes', 'copies', v_integrity -> 'copies',
      'leaves', v_integrity -> 'leaves',
      'fast', (select count(*) from jsonb_array_elements(case when jsonb_typeof(v_integrity -> 'gaps_ms') = 'array' then v_integrity -> 'gaps_ms' else '[]'::jsonb end) g
                where jsonb_typeof(g) = 'number' and (g #>> '{}')::numeric < s.academy_answer_floor_seconds * 1000))) end;

  if cardinality(v_reasons) > 0 and s.academy_integrity_void then
    select * into st from academy_quiz_starts where user_id = p_user and section_id = v_sec for update;
    if st.user_id is null then raise exception 'Start the quiz first' using errcode = '55000'; end if;
    insert into academy_attempts (user_id, section_id, correct, total, score_bps, passed, answers, flagged, seconds, voided, void_reasons, integrity)
    values (p_user, v_sec, 0, greatest(v_n, 1), 0, false, coalesce(p -> 'answers', '{}'::jsonb), true,
            greatest(0, floor(extract(epoch from now() - st.started_at)))::integer, true, v_reasons, v_integrity)
    returning id into v_att;
    delete from academy_quiz_starts where user_id = p_user and section_id = v_sec;
    perform app.academy_integrity_alert(p_user, v_sec, v_att, v_reasons, true);
    return jsonb_build_object('voided', true, 'passed', false, 'correct', 0, 'total', greatest(v_n, 1), 'score_bps', 0, 'pass_bps', s.academy_pass_bps,
      'reasons', to_jsonb(v_reasons), 'reason_words', app.academy_integrity_words(v_reasons), 'results', '[]'::jsonb,
      'message', 'This attempt was voided: ' || app.academy_integrity_words(v_reasons) || '. Answer yourself, on this page. An Admin was told.',
      'quiz', app.academy_quiz_wait(p_user, v_sec));
  end if;

  r := app.academy_quiz_submit_pre5199(p_user, p - 'integrity');
  -- a graded attempt (not the fix step): keep what the page saw, and the reasons when the setting only flags
  if not coalesce((r ->> 'fix')::boolean, false) then
    select id into v_att from academy_attempts where user_id = p_user and section_id = v_sec and created_at > now() - interval '1 minute' order by created_at desc limit 1;
    if v_att is not null then
      update academy_attempts set integrity = v_integrity, void_reasons = coalesce(v_reasons, '{}'),
                                  flagged = flagged or cardinality(v_reasons) > 0 where id = v_att;
      if cardinality(v_reasons) > 0 then perform app.academy_integrity_alert(p_user, v_sec, v_att, v_reasons, false); end if;
    end if;
  end if;
  return r || case when cardinality(v_reasons) > 0 then jsonb_build_object('flags', to_jsonb(v_reasons)) else '{}'::jsonb end;
end $$;
select pg_temp.copy_grants('app.academy_quiz_submit(uuid, jsonb)'::regprocedure, 'app.academy_quiz_submit_pre5199(uuid, jsonb)'::regprocedure);

create function app.academy_integrity_alert(p_user uuid, p_sec uuid, p_att uuid, p_reasons text[], p_voided boolean) returns void
language plpgsql security definer set search_path = public, app, pg_temp as $$
begin
  perform app.staff_alert('academy_integrity', 'academy_attempt', p_att, case when p_voided then 'void' else 'flag' end,
    format('Academy: %s %s', app.staff_display_name(p_user), case when p_voided then 'attempt voided' else 'attempt flagged' end),
    format('"%s": %s.', (select title from academy_sections where id = p_sec), app.academy_integrity_words(p_reasons)),
    jsonb_build_object('path_admin', '/admin/academy/staff/' || p_user));
exception when others then raise warning 'academy integrity alert not made: %', sqlerrm;
end $$;

insert into staff_alert_rules (rule, label, grp, who, tier, topic, enabled, wired, hint, sort) values
  ('academy_integrity', 'Academy attempt voided (AI or automation)', 'Staff', '{admin}', 'normal', 'alerts', true, true,
   'A quiz submit showed browser automation, clicks not made by a person, paste or copy, the page left too often, or answers too fast. The attempt is voided.', 126)
on conflict (rule) do nothing;

-- ================================================================ 4. Admin reads the voided attempts of a person
create function app.academy_voided_read(p_by uuid, p jsonb) returns jsonb
language plpgsql stable security definer set search_path = public, app, pg_temp as $$
declare v_user uuid := nullif(p ->> 'user_id', '')::uuid;
begin
  perform app.assert_admin(p_by);
  return coalesce((select jsonb_agg(jsonb_build_object('id', a.id, 'section', s.title, 'at', a.created_at, 'voided', a.voided, 'reasons', to_jsonb(a.void_reasons),
                                                       'words', app.academy_integrity_words(a.void_reasons), 'seconds', a.seconds, 'integrity', a.integrity) order by a.created_at desc)
                     from academy_attempts a join academy_sections s on s.id = a.section_id
                    where a.user_id = v_user and cardinality(a.void_reasons) > 0), '[]'::jsonb);
end $$;

alter function app.door(uuid, text, text, text, jsonb) rename to door_pre5199;
create function app.door(p_user uuid, p_aal text, p_call text, p_name text, p jsonb default '{}'::jsonb) returns jsonb
language plpgsql security definer set search_path = public, app, pg_temp as $$
begin
  if p_call = 'admin_read' and p_name = 'academy_voided' then
    perform app.door_begin(p_user, p_aal);
    return app.academy_voided_read(p_user, coalesce(p, '{}'::jsonb) - '_va');
  end if;
  return app.door_pre5199(p_user, p_aal, p_call, p_name, p);
end $$;
select pg_temp.copy_grants('app.door(uuid, text, text, text, jsonb)'::regprocedure, 'app.door_pre5199(uuid, text, text, text, jsonb)'::regprocedure);

-- ================================================================ privileges: the server only
revoke all on function app.academy_integrity_reasons(jsonb, integer), app.academy_integrity_words(text[]), app.academy_quiz_submit_pre5199(uuid, jsonb),
  app.academy_integrity_alert(uuid, uuid, uuid, text[], boolean), app.academy_voided_read(uuid, jsonb), app.door_pre5199(uuid, text, text, text, jsonb) from public, anon, authenticated;
grant execute on function app.academy_integrity_reasons(jsonb, integer), app.academy_integrity_words(text[]), app.academy_quiz_submit_pre5199(uuid, jsonb),
  app.academy_integrity_alert(uuid, uuid, uuid, text[], boolean), app.academy_voided_read(uuid, jsonb), app.door_pre5199(uuid, text, text, text, jsonb) to service_role;
