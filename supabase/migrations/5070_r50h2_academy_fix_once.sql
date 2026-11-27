-- 5070 (R50 hotfix 2; docs/changes/2026-11-25-r50-hotfix2.md): the academy waits less and lets a person fix their wrong
-- answers once. The owner (Nov 25): "Academy wait time for wrong answers is too long. Reduce it." and "Give people the chance
-- to correct the wrong answers once before marking their quiz as failed."
--   1. Program settings: academy_fail_cooldown_minutes 30 -> 2 (and its default), academy_attempts_per_day 3 -> 10 (and its
--      default), so the shorter wait never runs into the daily cap.
--   2. Fix once: a learner's first submit below academy_pass_bps records no attempt. It returns which questions are wrong
--      (never the right answers) and keeps the first answers and the wrong questions on the started quiz
--      (academy_quiz_starts.fix_wrong, fix_answers, fix_at), server side. The second submit takes the first answers and
--      changes only the questions marked wrong; it is graded and recorded as the attempt (pass, or fail with the cooldown).
--      Starting the quiz again while a fix is pending hands back the same fix (no new first try), so the list of wrong
--      questions cannot be asked for twice. An Admin's reset of the section clears it (academy_reset deletes the start).
--      Admins (who preview quizzes without a start) keep the one-step submit.
-- No applied migration is edited: academy_quiz_start and academy_quiz_submit are wrapped (_pre5070).
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

-- ================================================================ 1. the waits
alter table program_settings alter column academy_fail_cooldown_minutes set default 2,
  alter column academy_attempts_per_day set default 10;
update program_settings set academy_fail_cooldown_minutes = 2 where id = (app.settings()).id and academy_fail_cooldown_minutes > 2;
update program_settings set academy_attempts_per_day = 10 where id = (app.settings()).id and academy_attempts_per_day < 10;
comment on column program_settings.academy_fail_cooldown_minutes is 'Academy (1154; 2 since 5070): minutes after a failed attempt before the same quiz can be taken again.';
comment on column program_settings.academy_attempts_per_day is 'Academy (1154; 10 since 5070): the most attempts of one quiz a person may make in a Toronto day. A fixed first try (5070) is one attempt.';

-- ================================================================ 2. fix once
alter table academy_quiz_starts
  add column if not exists fix_wrong uuid[],
  add column if not exists fix_answers jsonb,
  add column if not exists fix_at timestamptz;
comment on column academy_quiz_starts.fix_wrong is 'Fix once (5070): the questions the first submit got wrong; only these may change on the second submit. Null: no fix pending.';
comment on column academy_quiz_starts.fix_answers is 'Fix once (5070): the answers of the first submit, by question id (the index in the question''s own options).';
comment on column academy_quiz_starts.fix_at is 'Fix once (5070): when the first submit was checked.';

-- the score of a set of answers (by question id), no attempt recorded
create function app.academy_quiz_grade(p_section uuid, p_answers jsonb) returns jsonb
language sql stable security definer set search_path = public, app, pg_temp as $$
  select jsonb_build_object('total', count(*), 'correct', count(*) filter (where (p_answers ->> q.id::text) ~ '^\d+$' and (p_answers ->> q.id::text)::int = q.answer),
           'wrong', coalesce(jsonb_agg(q.id) filter (where not coalesce((p_answers ->> q.id::text) ~ '^\d+$' and (p_answers ->> q.id::text)::int = q.answer, false)), '[]'::jsonb))
    from academy_questions q where q.section_id = p_section
$$;

-- the start: a pending fix comes back as it is (same first answers, same wrong questions; the clock is not restarted)
alter function app.academy_quiz_start(uuid, jsonb) rename to academy_quiz_start_pre5070;
create function app.academy_quiz_start(p_user uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app, pg_temp as $$
declare
  v_sec uuid := app.academy_section_id(p_user, p);
  st academy_quiz_starts;
  r jsonb;
begin
  select * into st from academy_quiz_starts where user_id = p_user and section_id = v_sec;
  r := app.academy_quiz_start_pre5070(p_user, p);
  if st.fix_wrong is not null then
    update academy_quiz_starts set started_at = st.started_at where user_id = p_user and section_id = v_sec;
    r := r || jsonb_build_object('started_at', st.started_at,
      'fix', jsonb_build_object('wrong', to_jsonb(st.fix_wrong), 'given', st.fix_answers, 'at', st.fix_at));
  end if;
  return r;
end $$;
select pg_temp.copy_grants('app.academy_quiz_start(uuid, jsonb)'::regprocedure, 'app.academy_quiz_start_pre5070(uuid, jsonb)'::regprocedure);

alter function app.academy_quiz_submit(uuid, jsonb) rename to academy_quiz_submit_pre5070;
create function app.academy_quiz_submit(p_user uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app, pg_temp as $$
declare
  v_sec uuid := app.academy_section_id(p_user, p);
  v_answers jsonb := coalesce(p -> 'answers', '{}'::jsonb);
  st academy_quiz_starts;
  g jsonb;
  w jsonb;
  v_bps integer;
  v_merged jsonb;
begin
  if app.user_is_admin(p_user) then return app.academy_quiz_submit_pre5070(p_user, p); end if;
  if jsonb_typeof(v_answers) <> 'object' then raise exception 'Give the answers by question' using errcode = '22023'; end if;
  select * into st from academy_quiz_starts where user_id = p_user and section_id = v_sec for update;
  if st.user_id is null then raise exception 'Start the quiz first' using errcode = '55000'; end if;

  if st.fix_wrong is null then
    -- the first submit: the same checks as a graded one, then only a failing score is held back for the one fix
    if st.started_at < now() - interval '3 hours' then raise exception 'Start the quiz first' using errcode = '55000'; end if;
    w := app.academy_quiz_wait(p_user, v_sec);
    if not coalesce((w ->> 'ok')::boolean, false) and w ->> 'reason' <> 'reading' then raise exception '%', w ->> 'message' using errcode = '55000'; end if;
    if exists (select 1 from academy_questions where section_id = v_sec and not (v_answers ? id::text)) then raise exception 'Answer every question' using errcode = '22023'; end if;
    g := app.academy_quiz_grade(v_sec, v_answers);
    v_bps := ((g ->> 'correct')::int * 10000) / greatest((g ->> 'total')::int, 1);
    if v_bps >= coalesce((app.settings()).academy_pass_bps, 8000) then
      return app.academy_quiz_submit_pre5070(p_user, p) || jsonb_build_object('fixed', false);
    end if;
    update academy_quiz_starts set fix_wrong = array(select (x #>> '{}')::uuid from jsonb_array_elements(g -> 'wrong') x),
                                   fix_answers = (select coalesce(jsonb_object_agg(q.id::text, v_answers -> q.id::text), '{}'::jsonb) from academy_questions q where q.section_id = v_sec),
                                   fix_at = now()
     where user_id = p_user and section_id = v_sec;
    return jsonb_build_object('fix', true, 'passed', false, 'wrong', g -> 'wrong', 'correct', (g ->> 'correct')::int, 'total', (g ->> 'total')::int,
      'score_bps', v_bps, 'pass_bps', (app.settings()).academy_pass_bps,
      'message', 'Fix the ones marked wrong. You can change only those, once: the next check is graded.');
  end if;

  -- the second submit: the first answers, with only the wrong questions changed; graded and recorded (the cooldown follows a fail)
  v_merged := st.fix_answers || coalesce((select jsonb_object_agg(k, v_answers -> k) from unnest(st.fix_wrong) u, lateral (select u::text k) kk
                                            where v_answers ? k), '{}'::jsonb);
  -- the fix may take its time: the started quiz's 3-hour limit counts to the first check
  if st.started_at < now() - interval '3 hours' then
    update academy_quiz_starts set started_at = now() - interval '3 hours' + interval '1 minute' where user_id = p_user and section_id = v_sec;
  end if;
  return app.academy_quiz_submit_pre5070(p_user, jsonb_build_object('section', v_sec, 'answers', v_merged))
      || jsonb_build_object('fixed', true, 'fixable', to_jsonb(st.fix_wrong));
end $$;
select pg_temp.copy_grants('app.academy_quiz_submit(uuid, jsonb)'::regprocedure, 'app.academy_quiz_submit_pre5070(uuid, jsonb)'::regprocedure);

-- ================================================================ privileges: the server only
revoke all on function app.academy_quiz_grade(uuid, jsonb), app.academy_quiz_start_pre5070(uuid, jsonb), app.academy_quiz_submit_pre5070(uuid, jsonb)
  from public, anon, authenticated;
grant execute on function app.academy_quiz_grade(uuid, jsonb), app.academy_quiz_start_pre5070(uuid, jsonb), app.academy_quiz_submit_pre5070(uuid, jsonb)
  to service_role;
