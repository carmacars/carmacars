-- Release 43 (2680): the owner's hiring rules for the AI interview.
--  1. Instant hire is for Sales only (va_function sales, not field). A passed AI interview of any other role invites the
--     applicant to book an interview date (hiring_field_to_call: status invited, applicant_invited with the booking link);
--     townhall_field_slots opens slots for every non-Sales role, not only the field roles. (2672 already limited
--     server_hire_auto_due and k_jobs_due to Sales.)
--  2. Video answers only, nothing typed: the server refuses mode typed (an unanswered timeout stays none); the written
--     English question is a spoken answer too.
--  3. Each answer is scored out of 10 (result.answers: seq, score 1 to 10, a one-line reason of 200 characters at most),
--     kept with the interview beside the topic scores, the 0 to 100 score and the bar of 80.
--  4. Redo the interview (Admin, admin_do hiring_ai_redo): ends staff access if still active (admin_do staff_end, the
--     staff page's End access), keeps the old interview and its answers as history (ai_interview_history), puts the
--     application back to Invited with a fresh 7 day video interview link by email. It never hires by itself later unless
--     the role is Sales (the same rule as every other pass).
-- No applied migration is edited: app.hiring_ai_auto_decide, app.hiring_field_to_call, public.server_ai_interview_answer,
-- app.ai_interview_questions text, app.ai_interview_topics and app.ai_interview_consent_text are patched;
-- app.townhall_field_slots is replaced; public.server_ai_interview_scored, public.server_ai_interviews_due,
-- public.server_ai_audio_purged, public.server_ai_video_purged, app.job_hiring and app.door are wrapped.
-- SCHEMA_MARKER 2680.
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
create function pg_temp.patch_fn(p_sig regprocedure, p_old text, p_new text) returns void
language plpgsql as $$
declare d text := pg_get_functiondef(p_sig);
begin
  if position(p_old in d) = 0 then raise exception '2680: the text to change was not found in %: %', p_sig, left(p_old, 160); end if;
  execute replace(d, p_old, p_new);
end $$;

-- ================================================================ 1. instant hire is for Sales only
select pg_temp.patch_fn('app.hiring_ai_auto_decide(timestamptz)'::regprocedure,
  $o$v_out := case when r.staff_kind = 'field' then 'live_call' else 'hire' end;$o$,
  $n$v_out := case when r.va_function = 'sales' and r.staff_kind is distinct from 'field' then 'hire' else 'live_call' end;$n$);
select pg_temp.patch_fn('app.hiring_ai_auto_decide(timestamptz)'::regprocedure,
  'invited to book a live call. You get an alert when it is booked.',
  'invited to book an interview date. You get an alert when it is booked.');

-- every role that is not Sales (field, and the remote assistants) who passed the bar is invited to book a date
select pg_temp.patch_fn('app.hiring_field_to_call(timestamptz)'::regprocedure,
  $o$where r.staff_kind = 'field' and i.state = 'scored'$o$,
  $n$where (r.staff_kind = 'field' or r.va_function is distinct from 'sales') and i.state = 'scored'$n$);
select pg_temp.patch_fn('app.hiring_field_to_call(timestamptz)'::regprocedure,
  $o$'applicant_invited:' || a.id || ':field_call')$o$,
  $n$'applicant_invited:' || a.id || ':field_call' || coalesce((select ':' || x.links_sent from ai_interviews x where x.application_id = a.id and x.links_sent > 1), ''))$n$);

-- the booking slots in the hour before the townhall: every role that is not Sales (an existing day gets the full list)
create or replace function app.townhall_field_slots(p_now timestamptz default now()) returns integer
language plpgsql security definer set search_path = public, app as $$
declare
  v_at timestamptz := app.townhall_next(p_now);
  v_day date;
  v_start time;
  v_id uuid;
  v_roles uuid[] := array(select r.id from hiring_roles r where r.staff_kind = 'field' or r.va_function is distinct from 'sales' order by r.id);
  v_note constant text := 'Field calls in the hour before the weekly townhall (1068)';
begin
  if v_at is null or v_at <= p_now + interval '2 hours' or cardinality(v_roles) = 0 then return 0; end if;
  v_day := app.local_date(v_at);
  v_start := ((v_at at time zone 'America/Toronto') - interval '1 hour')::time;
  select id into v_id from interview_days where day = v_day and start_time = v_start and note = v_note order by id limit 1;
  if v_id is null then
    insert into interview_days (day, start_time, end_time, slot_minutes, buffer_minutes, capacity, mode, role_ids, note, active)
    values (v_day, v_start, (v_at at time zone 'America/Toronto')::time, 10, 0, 1, 'video', v_roles, v_note, true)
    returning id into v_id;
    return app.hiring_day_slots(v_id);
  end if;
  update interview_days set role_ids = v_roles where id = v_id and role_ids is distinct from v_roles;
  return 0;
end $$;

-- an outcome "hire" kept for a role that is not Sales (2590 hired every remote role) now waits as the interview date
update hiring_ai_outcomes o set outcome = 'live_call'
 where o.outcome = 'hire' and not exists (select 1 from hiring_auto_hires h where h.application_id = o.application_id)
   and exists (select 1 from job_applications a join hiring_roles r on r.id = a.role_id
                where a.id = o.application_id and a.hired_user_id is null and not (r.va_function = 'sales' and r.staff_kind is distinct from 'field'));

comment on column program_settings.hiring_ai_auto_decide is 'Hiring (2590, 2680): a scored AI interview is decided by itself: at or over hiring_auto_hire_mark with no knock-out, a Sales applicant is hired (instant hire is for Sales only) and every other role is invited to book an interview date; under it, the decline or Sales referral email. Admins are told, never asked.';
comment on column program_settings.hiring_auto_hire_mark is 'Hiring (1060, 2590, 2680): the bar of the AI interview (0 to 100, 80): at or over it with no knock-out the applicant passes (Sales: hired by itself; every other role: invited to book an interview date); under it, declined or referred to Sales.';
comment on table hiring_ai_outcomes is 'Hiring (2590, 2680): what a scored AI interview decided by itself, once per application: hire (Sales only; one-step Hire follows), live_call (every other role: the interview date to book), sales or decline (the email sent once), failed (an Admin To-do).';
update staff_alert_rules set hint = 'The score, the bar and what happened by itself: Sales hired, any other role invited to book an interview date, referred to Sales or declined (2680).' where rule = 'interview_finished';
update staff_alert_rules set hint = 'The AI interview score met the auto-hire mark: instant hire is for Sales only (1060, 2680).' where rule = 'hire_auto';

-- the interview days already open before this migration
select app.townhall_field_slots(now());

-- ================================================================ 2. video answers only
select pg_temp.patch_fn('public.server_ai_interview_answer(text, jsonb)'::regprocedure,
  E'begin\n  select i.id into v_iv',
  E'begin\n  if p ->> ''mode'' = ''typed'' then return jsonb_build_object(''ok'', false, ''error'', ''video_only''); end if;\n  select i.id into v_iv');
select pg_temp.patch_fn('app.ai_interview_questions(uuid)'::regprocedure,
  'Please type this answer instead of speaking it: write the exact message you would send a customer whose car will be 30 minutes late for pickup.',
  'Say out loud, to the camera, the exact message you would send a customer whose car will be 30 minutes late for pickup: polite, short, and what happens next.');
select pg_temp.patch_fn('app.ai_interview_topics()'::regprocedure,
  'The typed customer message is correct, polite, short and says exactly what happens next',
  'The customer message, said out loud as it would be written, is correct, polite, short and says exactly what happens next');
select pg_temp.patch_fn('app.ai_interview_consent_text()'::regprocedure,
  ' (your camera and your voice) or the text you type,',
  ' (your camera and your voice),');

-- ================================================================ 3. each answer scored out of 10
alter function public.server_ai_interview_scored(jsonb) rename to server_ai_interview_scored_pre2680;
create function public.server_ai_interview_scored(p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare v jsonb := public.server_ai_interview_scored_pre2680(p);
begin
  if coalesce((v ->> 'scored')::boolean, false) then
    update ai_interviews i set result = coalesce(i.result, '{}'::jsonb) || jsonb_build_object('answers', coalesce((
        select jsonb_agg(jsonb_build_object('seq', x.seq, 'score', x.score, 'reason', x.reason) order by x.seq)
          from (select distinct on (s) s as seq, sc as score, rs as reason
                  from (select (e ->> 'seq')::int s, (e ->> 'score')::numeric::int sc, left(btrim(coalesce(e ->> 'reason', '')), 200) rs, o
                          from jsonb_array_elements(case when jsonb_typeof(p #> '{result,answers}') = 'array' then p #> '{result,answers}' else '[]'::jsonb end) with ordinality t(e, o)
                         where jsonb_typeof(e) = 'object' and (e ->> 'seq') ~ '^[0-9]{1,4}$' and (e ->> 'score') ~ '^([1-9]|10)(\.0+)?$'
                           and exists (select 1 from ai_interview_answers w where w.interview_id = i.id and w.seq = (e ->> 'seq')::int)) q
                 order by s, o) x), '[]'::jsonb))
     where i.id = (p ->> 'interview_id')::uuid;
  end if;
  return v;
end $$;
select pg_temp.copy_grants('public.server_ai_interview_scored(jsonb)'::regprocedure, 'public.server_ai_interview_scored_pre2680(jsonb)'::regprocedure);

-- ================================================================ 4. redo the interview: the old one is kept as history
create table if not exists ai_interview_history (
  id               uuid primary key default gen_random_uuid(),
  application_id   uuid not null references job_applications (id) on delete cascade,
  archived_at      timestamptz not null default now(),
  archived_by      uuid references users (id) on delete set null,
  previous_user_id uuid,
  interview        jsonb not null,
  answers          jsonb not null default '[]'::jsonb
);
create index if not exists ai_interview_history_application_idx on ai_interview_history (application_id);
create index if not exists ai_interview_history_archived_by_idx on ai_interview_history (archived_by) where archived_by is not null;
comment on table ai_interview_history is 'Hiring (2680): an AI interview that an Admin had redone (hiring_ai_redo): the old interview row and its answers (transcripts, scores, media keys) as they were. The media follow the same retention as a live interview; everything is scrubbed 12 months after the decision.';
alter table ai_interview_history enable row level security;
revoke all on ai_interview_history from anon, authenticated;
grant all on ai_interview_history to service_role;
drop policy if exists admin_all on ai_interview_history;
create policy admin_all on ai_interview_history for select to authenticated using (app.is_admin());
drop trigger if exists audit_ai_interview_history on ai_interview_history;
create trigger audit_ai_interview_history after insert or update or delete on ai_interview_history for each row execute function app.audit_row('redact');

create function app.hiring_ai_redo(p_by uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  a job_applications := app.hiring_lock(p_by, (p ->> 'id')::uuid);
  iv ai_interviews;
  n ai_interviews;
  v_user uuid := a.hired_user_id;
  v_n integer;
begin
  select * into iv from ai_interviews where application_id = a.id;
  if not (a.status = 'hired' or v_user is not null or iv.state in ('submitted', 'scored')) then
    raise exception 'The AI interview can be redone for a hired candidate or one who finished it' using errcode = '23514';
  end if;
  if nullif(btrim(coalesce(a.email, '')), '') is null then raise exception 'This candidate has no email address' using errcode = '23514'; end if;
  -- staff access ends first, the way the staff page's End access does (never an Admin's)
  if v_user is not null and exists (select 1 from users u where u.id = v_user and u.status = 'active') then
    if exists (select 1 from user_roles ur where ur.user_id = v_user and ur.role::text = 'admin') then
      raise exception 'That person is an Admin: end their access in Settings first' using errcode = '23514';
    end if;
    perform app.admin_do(p_by, 'staff_end', jsonb_build_object('user', v_user));
  end if;
  -- the old interview and its answers stay as history
  if iv.id is not null then
    insert into ai_interview_history (application_id, archived_by, previous_user_id, interview, answers)
    values (a.id, p_by, v_user, to_jsonb(iv), coalesce((select jsonb_agg(to_jsonb(w) order by w.seq) from ai_interview_answers w where w.interview_id = iv.id), '[]'::jsonb));
    delete from ai_interviews where id = iv.id;
  end if;
  select count(*) + 1 into v_n from ai_interview_history where application_id = a.id;
  -- the new interview decides afresh: Sales may hire by itself, every other role books an interview date
  delete from hiring_ai_outcomes where application_id = a.id;
  delete from hiring_auto_hires where application_id = a.id;
  delete from hiring_decisions where application_id = a.id and sent_at is null;
  update job_applications set status = 'invited', hired_user_id = null, invited_at = now(), interviewed_at = null, decided_at = null, decided_by = null,
         waiting_for_day = false, no_slots_since = null, updated_at = now()
   where id = a.id returning * into a;
  insert into ai_interviews (application_id, role_id, questions, expires_at, links_sent)
  values (a.id, a.role_id, app.ai_interview_questions(a.role_id), now() + make_interval(days => (app.settings()).hiring_ai_interview_days), coalesce(iv.links_sent, 0) + 1)
  returning * into n;
  perform app.hiring_emit_pre0211('applicant_ai_interview', a, app.ai_interview_vars(a, n) || jsonb_build_object('redo', '1'), 'applicant_ai_interview:' || a.id || ':redo:' || v_n);
  insert into audit_log (actor_user_id, action, entity_table, entity_id, after) values (p_by, 'hiring_ai_redo', 'job_applications', a.id::text, '{}'::jsonb);
  return app.hiring_app_row(a);
end $$;

alter function app.door(uuid, text, text, text, jsonb) rename to door_pre2680;
create function app.door(p_user uuid, p_aal text, p_call text, p_name text, p jsonb default '{}'::jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
begin
  if p_call = 'admin_do' and p_name = 'hiring_ai_redo' then
    perform app.door_begin(p_user, p_aal);
    return app.hiring_ai_redo(p_user, coalesce(p, '{}'::jsonb));
  end if;
  return app.door_pre2680(p_user, p_aal, p_call, p_name, p);
end $$;
select pg_temp.copy_grants('app.door(uuid, text, text, text, jsonb)'::regprocedure, 'app.door_pre2680(uuid, text, text, text, jsonb)'::regprocedure);

-- the history's media are removed like a live interview's, and its words are scrubbed with the application's data
alter function public.server_ai_interviews_due(integer) rename to server_ai_interviews_due_pre2680;
create function public.server_ai_interviews_due(p_limit integer default 5) returns jsonb
language sql stable security definer set search_path = public, app as $$
  select x.v || jsonb_build_object(
    'purge', coalesce(x.v -> 'purge', '[]'::jsonb) || coalesce((select jsonb_agg(jsonb_build_object('answer_id', e ->> 'id', 'audio_key', e ->> 'audio_key'))
        from ai_interview_history h join job_applications j on j.id = h.application_id, jsonb_array_elements(h.answers) e
       where j.purged_at is not null and e ->> 'audio_key' is not null), '[]'::jsonb),
    'videos', coalesce(x.v -> 'videos', '[]'::jsonb) || coalesce((select jsonb_agg(jsonb_build_object('answer_id', e ->> 'id', 'video_key', e ->> 'video_key'))
        from ai_interview_history h join job_applications j on j.id = h.application_id, jsonb_array_elements(h.answers) e
       where e ->> 'video_key' is not null and (j.purged_at is not null or (e ->> 'created_at')::timestamptz < now() - make_interval(days => (app.settings()).hiring_ai_video_days))), '[]'::jsonb))
  from (select public.server_ai_interviews_due_pre2680(p_limit) v) x
$$;
select pg_temp.copy_grants('public.server_ai_interviews_due(integer)'::regprocedure, 'public.server_ai_interviews_due_pre2680(integer)'::regprocedure);

alter function public.server_ai_audio_purged(uuid[]) rename to server_ai_audio_purged_pre2680;
create function public.server_ai_audio_purged(p_ids uuid[]) returns integer
language sql security definer set search_path = public, app as $$
  with h as (update ai_interview_history x set answers = (select jsonb_agg(case when (e ->> 'id')::uuid = any (p_ids) then e || '{"audio_key": null}'::jsonb else e end) from jsonb_array_elements(x.answers) e)
              where exists (select 1 from jsonb_array_elements(x.answers) e where (e ->> 'id')::uuid = any (p_ids) and e ->> 'audio_key' is not null) returning 1)
  select public.server_ai_audio_purged_pre2680(p_ids) + (select count(*)::int from h)
$$;
select pg_temp.copy_grants('public.server_ai_audio_purged(uuid[])'::regprocedure, 'public.server_ai_audio_purged_pre2680(uuid[])'::regprocedure);
alter function public.server_ai_video_purged(uuid[]) rename to server_ai_video_purged_pre2680;
create function public.server_ai_video_purged(p_ids uuid[]) returns integer
language sql security definer set search_path = public, app as $$
  with h as (update ai_interview_history x set answers = (select jsonb_agg(case when (e ->> 'id')::uuid = any (p_ids) then e || '{"video_key": null}'::jsonb else e end) from jsonb_array_elements(x.answers) e)
              where exists (select 1 from jsonb_array_elements(x.answers) e where (e ->> 'id')::uuid = any (p_ids) and e ->> 'video_key' is not null) returning 1)
  select public.server_ai_video_purged_pre2680(p_ids) + (select count(*)::int from h)
$$;
select pg_temp.copy_grants('public.server_ai_video_purged(uuid[])'::regprocedure, 'public.server_ai_video_purged_pre2680(uuid[])'::regprocedure);

alter function app.job_hiring(timestamptz) rename to job_hiring_pre2680;
create function app.job_hiring(p_now timestamptz default now()) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare v jsonb := app.job_hiring_pre2680(p_now);
begin
  update ai_interview_history h
     set interview = jsonb_build_object('id', h.interview -> 'id', 'state', h.interview -> 'state', 'purged', true),
         answers = coalesce((select jsonb_agg(jsonb_build_object('id', e -> 'id', 'audio_key', e -> 'audio_key', 'video_key', e -> 'video_key', 'created_at', e -> 'created_at'))
                               from jsonb_array_elements(h.answers) e), '[]'::jsonb)
    from job_applications j
   where j.id = h.application_id and j.purged_at is not null and not (h.interview ? 'purged');
  return v;
end $$;
select pg_temp.copy_grants('app.job_hiring(timestamptz)'::regprocedure, 'app.job_hiring_pre2680(timestamptz)'::regprocedure);

do $$
declare f record;
begin
  for f in select p.oid::regprocedure as sig from pg_proc p join pg_namespace n on n.oid = p.pronamespace
            where (n.nspname = 'app' and p.proname = any (array['hiring_ai_redo', 'door_pre2680', 'job_hiring_pre2680', 'townhall_field_slots']))
               or (n.nspname = 'public' and p.proname = any (array['server_ai_interview_scored_pre2680', 'server_ai_interviews_due_pre2680', 'server_ai_audio_purged_pre2680', 'server_ai_video_purged_pre2680']))
  loop
    execute format('revoke all on function %s from public, anon, authenticated', f.sig);
    execute format('grant execute on function %s to service_role', f.sig);
  end loop;
end $$;
