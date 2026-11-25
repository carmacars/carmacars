-- 5020: staff resign themselves in their portal (release 50; docs/changes/2026-11-25-r50-resign.md). SCHEMA_MARKER 5022.
-- No applied migration is edited.
--   1. staff_resignations: who resigned, on which day, their last day, the reason, who recorded it and when; withdrawn
--      (by them or an Admin, until the last day) or ended (the access closed). One pending resignation a person.
--      program_settings.staff_notice_days (7, the notice both staff agreements ask for: VA 7.1, Field 9.1).
--   2. Resign (door ops_do / field_do staff_resign; an Admin may record one for someone, user_id): the last day is from
--      tomorrow (today for someone still in onboarding or in the VA trial period), by default today + the notice days.
--      Their future field jobs, shift plans and open shift offers after the last day go back to the queue; one
--      offboarding To do for the Admins (final pay up to the last day, keys and equipment, jobs and shifts to reassign,
--      leads, chats, To dos and claims to hand back); a confirmation email to the person (CarmaCars branding: final pay
--      timing from their agreement or pay settings, what to return, how to withdraw); an alert to the Admins and Finance.
--      A last day of today (onboarding, trial, or an Admin) ends the access at once.
--   3. Withdraw (staff_resign_withdraw): until the last day; the To do is cancelled, the Admins and Finance are told.
--   4. The Admin side: staff_resign_last_day (earlier or later, from today), End access (admin_do staff_end) closes a
--      pending resignation as ended; admin_read staff_resignations for Staff and roles; list_staff shows the resignation.
--   5. The job (app.job_staff_resignations, every 15 minutes): after the last day the access ends through
--      app.staff_access_end, the same function admin_do staff_end (the connector's end_staff_access) now runs. The person
--      stays in Staff and roles, Resigned with the dates. Their open To dos and chats go back to the queues and their
--      lead and request claims are released; their standing shifts end.
--   6. While a resignation is pending, nobody books them a shift or assigns them a job after their last day.
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

-- ================================================================ 1. the record and the setting
alter table program_settings add column if not exists staff_notice_days integer not null default 7 check (staff_notice_days between 0 and 60);
comment on column program_settings.staff_notice_days is 'Resign (5020): the notice a staff member gives, in days (7: the Virtual Assistant Contractor Agreement 7.1 and the Field Staff Agreement 9.1). The Resign form''s last day is today plus this by default.';

create table if not exists staff_resignations (
  id                  uuid primary key default gen_random_uuid(),
  user_id             uuid not null references users (id) on delete cascade,
  status              text not null default 'pending' check (status in ('pending', 'withdrawn', 'ended')),
  resigned_on         date not null,
  last_day            date not null check (last_day >= resigned_on),
  reason              text check (reason is null or length(reason) <= 1000),
  notice_days         integer not null check (notice_days >= 0),
  in_onboarding       boolean not null default false,
  in_trial            boolean not null default false,
  created_by          uuid not null references users (id),
  created_at          timestamptz not null default now(),
  last_day_changed_at timestamptz,
  last_day_changed_by uuid references users (id),
  withdrawn_at        timestamptz,
  withdrawn_by        uuid references users (id),
  ended_at            timestamptz,
  ended_by            uuid references users (id),
  task_id             uuid references tasks (id) on delete set null,
  released            jsonb not null default '{}'::jsonb,
  check ((status = 'withdrawn') = (withdrawn_at is not null)),
  check ((status = 'ended') = (ended_at is not null))
);
create unique index if not exists staff_resignations_one_pending on staff_resignations (user_id) where status = 'pending';
create index if not exists staff_resignations_user on staff_resignations (user_id, created_at desc);
create index if not exists staff_resignations_task on staff_resignations (task_id);
create index if not exists staff_resignations_due on staff_resignations (last_day) where status = 'pending';
comment on table staff_resignations is 'Resign (5020): a staff member''s resignation from their portal (or recorded by an Admin): the day given, the last day, the reason, who and when; withdrawn until the last day, or ended when the access closed. released: what went back to the queues.';
alter table staff_resignations enable row level security;
revoke all on staff_resignations from public, anon, authenticated;
grant all on staff_resignations to service_role;
drop policy if exists admin_all on staff_resignations;
create policy admin_all on staff_resignations for all to authenticated using (app.is_admin()) with check (app.is_admin());
drop trigger if exists audit_staff_resignations on staff_resignations;
create trigger audit_staff_resignations after insert or update or delete on staff_resignations for each row execute function app.audit_row();

insert into task_rules (task_type, queue, title, priority, description) values
  ('staff_offboarding', 'admin', 'Offboarding', 'high', 'Resign (5020): a staff member resigned. Final pay up to the last day (Finance), keys, cards and equipment back, their field jobs and shifts reassigned, their leads, chats, To dos and claims handed back. Their access ends by itself after the last day.')
on conflict (task_type) do nothing;

-- ================================================================ 2. the facts the form and the emails use
create function app.staff_resign_name(p_user uuid) returns text
language sql stable security definer set search_path = public, app, pg_temp as $$
  select coalesce(nullif(btrim(u.full_name), ''), u.email, 'Staff member') from users u where u.id = p_user
$$;

create function app.staff_resign_first(p_user uuid) returns text
language sql stable security definer set search_path = public, app, pg_temp as $$
  select coalesce(nullif(btrim(u.greeting_name), ''), nullif(split_part(btrim(coalesce(u.full_name, '')), ' ', 1), ''), 'there') from users u where u.id = p_user
$$;

create function app.staff_resign_role(sp staff_profiles) returns text
language sql stable set search_path = public, app, pg_temp as $$
  select case when sp.staff_type = 'field' then 'Field staff'
    else coalesce(nullif(array_to_string(array(select case f when 'cs' then 'Customer service' when 'fleet' then 'Fleet' when 'finance' then 'Finance' when 'sales' then 'Sales' when 'field' then 'Field' else initcap(f) end
                                         from unnest(case when cardinality(sp.functions) > 0 then sp.functions else array[sp.va_function::text] end) f where f is not null), ', '), ''), 'Staff') end
$$;

-- the last day of the field pay period that holds the day (two-week periods from Program settings' field_pay_anchor)
create function app.staff_resign_period_end(p_day date) returns date
language sql stable security definer set search_path = public, app, pg_temp as $$
  select a + 14 * (floor((p_day - a) / 14.0)::int + 1) - 1 from (select (app.settings()).field_pay_anchor as a) s
$$;

-- final pay, what to return, from the person's agreement and pay settings
create function app.staff_resign_words(p_user uuid, p_last date) returns jsonb
language plpgsql stable security definer set search_path = public, app, pg_temp as $$
declare
  sp staff_profiles;
  s program_settings := app.settings();
  v_timing text;
begin
  select * into sp from staff_profiles where user_id = p_user;
  if sp.staff_type = 'field' then
    v_timing := coalesce(nullif(s.staff_agreement_defaults #>> '{field,pay_dates}', ''), 'every two weeks');
    return jsonb_build_object(
      'final_pay_text', format('Every hour you work up to %s, with your vacation pay and any commission earned, is paid on the pay date of the pay period that ends %s (you are paid %s), within the time Ontario''s Employment Standards Act requires (Field Staff Agreement 9.4).',
                               app.fmt_day(p_last), app.fmt_day(app.staff_resign_period_end(p_last)), v_timing),
      'return_text', 'Return every key, fob, fuel or company card and item of equipment you have on or before your last day, and within 7 days return or delete any CarmaCars information on your own devices.',
      'pay_timing', v_timing, 'period_end', app.staff_resign_period_end(p_last));
  end if;
  v_timing := coalesce(nullif(s.staff_agreement_defaults #>> '{va,pay_timing}', ''), 'every two weeks');
  return jsonb_build_object(
    'final_pay_text', format('Your approved time and the commissions you earned up to %s are paid with the regular pay run after your last day (you are paid %s), by your usual payment method (agreement 7.4).',
                             app.fmt_day(p_last), v_timing),
    'return_text', 'On your last day hand over every password and account you used for CarmaCars, and within 7 days return or permanently delete every copy of CarmaCars information on your devices and confirm it in writing (agreement 7.4 and 7.5).',
    'pay_timing', v_timing, 'period_end', null);
end $$;

-- what the person holds now (for the To do and the Admin's alert)
create function app.staff_resign_holds(p_user uuid, p_last date) returns jsonb
language sql stable security definer set search_path = public, app, pg_temp as $$
  select jsonb_build_object(
    'jobs_open', (select count(*) from field_jobs j where j.assigned_to = p_user and j.status in ('scheduled', 'acknowledged', 'in_progress')),
    'jobs_list', coalesce((select string_agg(format('%s %s', replace(j.kind, '_', ' '), coalesce(app.fmt_date(j.scheduled_at), 'unscheduled')), '; ' order by j.scheduled_at nulls last)
                             from (select * from field_jobs j where j.assigned_to = p_user and j.status in ('scheduled', 'acknowledged', 'in_progress') order by j.scheduled_at nulls last limit 6) j), ''),
    'shifts_left', (select count(*) from field_shift_plans x where x.staff_id = p_user and x.cancelled_at is null and x.starts_at > now()),
    'standing', (select count(*) from field_standing_shifts st where st.staff_id = p_user and st.ended_at is null),
    'leads', (select count(*) from leads l where l.assigned_to = p_user and l.closed_reason is null),
    'chats', (select count(*) from chat_conversations c where c.assigned_to = p_user and c.closed_at is null),
    'tasks', (select count(*) from tasks t where t.assigned_to = p_user and t.status in ('open', 'in_progress', 'waiting')),
    'claims', (select count(*) from lead_claims c where c.claimed_by = p_user and c.expires_at > now()) + (select count(*) from request_claims c where c.claimed_by = p_user and c.expires_at > now()),
    'owners', (select count(*) from owners o where o.recruited_by = p_user))
$$;

-- p_user's resignation facts: the form's dates, whether today is allowed, the pending resignation
create function app.staff_resign_facts(p_user uuid) returns jsonb
language plpgsql stable security definer set search_path = public, app, pg_temp as $$
declare
  sp staff_profiles;
  u users;
  s program_settings := app.settings();
  r staff_resignations;
  v_onb boolean;
  v_trial boolean;
  v_trial_days integer;
  v_today date := app.today();
  v_default date;
begin
  select * into sp from staff_profiles where user_id = p_user;
  select * into u from users where id = p_user;
  if sp.user_id is null or app.user_is_admin(p_user) then return jsonb_build_object('staff', false); end if;
  v_onb := not sp.onboarding_exempt and not coalesce((app.staff_onboarding_state(p_user) ->> 'done')::boolean, true);
  v_trial_days := coalesce(nullif(s.staff_agreement_defaults #>> '{va,trial_days}', '')::int, 30);
  v_trial := sp.staff_type = 'va' and sp.started_on is not null and v_today < sp.started_on + v_trial_days;
  v_default := v_today + s.staff_notice_days;
  select * into r from staff_resignations x where x.user_id = p_user order by (x.status = 'pending') desc, x.created_at desc limit 1;
  return jsonb_build_object('staff', true, 'active', sp.is_active and u.status = 'active', 'portal', case when sp.staff_type = 'field' then 'field' else 'va' end,
    'name', app.staff_resign_name(p_user), 'role', app.staff_resign_role(sp), 'today', v_today, 'notice_days', s.staff_notice_days,
    'in_onboarding', v_onb, 'in_trial', v_trial, 'trial_days', v_trial_days, 'can_today', v_onb or v_trial,
    'earliest', case when v_onb or v_trial then v_today else v_today + 1 end, 'latest', v_today + 120, 'default_last_day', v_default,
    'words', app.staff_resign_words(p_user, coalesce(case when r.status = 'pending' then r.last_day end, v_default)),
    'resignation', case when r.id is not null then jsonb_build_object('id', r.id, 'status', r.status, 'resigned_on', r.resigned_on, 'last_day', r.last_day, 'reason', r.reason,
      'created_at', r.created_at, 'by_self', r.created_by = r.user_id, 'withdrawn_at', r.withdrawn_at, 'ended_at', r.ended_at,
      'can_withdraw', r.status = 'pending' and v_today <= r.last_day) end);
end $$;

-- ================================================================ 3. what resigning does
-- the person's jobs, shift plans and open shift offers after the last day go back to the queue
create function app.staff_resign_release(p_id uuid, p_by uuid) returns jsonb
language plpgsql security definer set search_path = public, app, pg_temp as $$
declare
  r staff_resignations;
  v_cut timestamptz;
  n_jobs integer;
  n_plans integer;
  n_offers integer;
begin
  select * into r from staff_resignations where id = p_id;
  -- from the start of the day after the last day, Toronto time
  v_cut := ((r.last_day + 1)::timestamp at time zone 'America/Toronto');
  update field_jobs set assigned_to = null, status = case when status = 'acknowledged' then 'scheduled' else status end, acknowledged_at = null
   where assigned_to = r.user_id and status in ('scheduled', 'acknowledged') and scheduled_at >= v_cut;
  get diagnostics n_jobs = row_count;
  update field_shift_plans set cancelled_at = now(), cancelled_by = p_by, cancel_reason = left('Resigned: last day ' || app.fmt_day(r.last_day), 300)
   where staff_id = r.user_id and cancelled_at is null and starts_at >= v_cut;
  get diagnostics n_plans = row_count;
  update field_shift_offers set status = 'withdrawn' where from_staff = r.user_id and status = 'open' and starts_at >= v_cut;
  get diagnostics n_offers = row_count;
  update staff_resignations set released = jsonb_build_object('jobs', coalesce((released ->> 'jobs')::int, 0) + n_jobs, 'shifts', coalesce((released ->> 'shifts')::int, 0) + n_plans,
    'offers', coalesce((released ->> 'offers')::int, 0) + n_offers) where id = p_id;
  return jsonb_build_object('jobs', n_jobs, 'shifts', n_plans, 'offers', n_offers);
end $$;

-- the one offboarding To do of a resignation (raised once; its words follow a new last day)
create function app.staff_resign_task(p_id uuid) returns uuid
language plpgsql security definer set search_path = public, app, pg_temp as $$
declare
  r staff_resignations;
  h jsonb;
  w jsonb;
  v_name text;
  v_title text;
  v_detail text;
  v_task uuid;
begin
  select * into r from staff_resignations where id = p_id;
  h := app.staff_resign_holds(r.user_id, r.last_day);
  w := app.staff_resign_words(r.user_id, r.last_day);
  v_name := app.staff_resign_name(r.user_id);
  v_title := format('Offboarding: %s, last day %s', v_name, app.fmt_day(r.last_day));
  v_detail := concat_ws(E'\n',
    format('Final pay (Finance): everything earned up to %s. %s', app.fmt_day(r.last_day), w ->> 'final_pay_text'),
    'Keys, cards and equipment: not tracked in the system. Collect every key, fob, fuel or company card and item of equipment they have.',
    format('Field jobs to reassign: %s open%s. Shifts still theirs: %s; standing shifts: %s.', h ->> 'jobs_open',
           case when coalesce(h ->> 'jobs_list', '') <> '' then ' (' || (h ->> 'jobs_list') || ')' else '' end, h ->> 'shifts_left', h ->> 'standing'),
    format('Went back to the queue (after the last day): %s jobs, %s shifts, %s shift offers.', coalesce(r.released ->> 'jobs', '0'), coalesce(r.released ->> 'shifts', '0'), coalesce(r.released ->> 'offers', '0')),
    format('To hand back: %s leads, %s chats, %s To dos, %s claims assigned to them; %s owners they brought in.', h ->> 'leads', h ->> 'chats', h ->> 'tasks', h ->> 'claims', h ->> 'owners'),
    'Their access ends by itself after the last day (Staff and roles shows them as Resigned). Change the last day or end access now on Staff and roles.',
    case when r.reason is not null then 'Reason given: ' || r.reason end);
  v_task := app.raise_task(p_type => 'staff_offboarding', p_title => v_title, p_detail => v_detail, p_related_table => 'staff_resignations', p_related_id => r.id,
    p_due_at => ((r.last_day + 1)::timestamp at time zone 'America/Toronto'), p_priority => 'high', p_queue => 'admin', p_dedupe => 'staff_offboarding:' || r.id);
  -- raised before: the words follow
  update tasks set title = v_title, detail = v_detail, due_at = ((r.last_day + 1)::timestamp at time zone 'America/Toronto') where id = v_task;
  update staff_resignations set task_id = v_task where id = r.id and task_id is distinct from v_task;
  return v_task;
end $$;

-- the emails: the person's confirmation (again, as an update, when an Admin changes the last day) and the Admins' alert
create function app.staff_resign_notify(p_id uuid, p_kind text) returns void
language plpgsql security definer set search_path = public, app, pg_temp as $$
declare
  r staff_resignations;
  sp staff_profiles;
  w jsonb;
  h jsonb;
  v_base text := rtrim((app.settings()).notify_base_url, '/');
  v_now_ended boolean;
begin
  select * into r from staff_resignations where id = p_id;
  select * into sp from staff_profiles where user_id = r.user_id;
  w := app.staff_resign_words(r.user_id, r.last_day);
  v_now_ended := r.last_day <= app.today();
  if p_kind in ('resigned', 'changed') then
    perform app.emit_event('staff_resignation_confirmed', 'user', r.user_id, jsonb_build_object('recipient_user_id', r.user_id, 'first_name', app.staff_resign_first(r.user_id),
      'last_day', app.fmt_day(r.last_day), 'resigned_on', app.fmt_day(r.resigned_on), 'is_update', p_kind = 'changed', 'ends_now', v_now_ended and r.status = 'ended',
      'access_ends', case when r.status = 'ended' then 'Now: your access has ended' else 'At the end of ' || app.fmt_day(r.last_day) end,
      'final_pay_text', w ->> 'final_pay_text', 'return_text', w ->> 'return_text',
      'withdraw_text', case when r.status = 'ended' then 'Your access has already ended. To come back, reply to this email and an Admin can restore it.'
                            else format('Changed your mind? Open your profile and press Withdraw my resignation, any time up to %s.', app.fmt_day(r.last_day)) end,
      'can_withdraw', r.status = 'pending',
      'profile_url', v_base || case when sp.staff_type = 'field' then '/staff/field/profile#resign' else '/staff/profile#resign' end),
      'staff_resignation_confirmed:' || r.id || ':' || p_kind || ':' || to_char(clock_timestamp(), 'YYYYMMDDHH24MISSUS'));
  end if;
  if p_kind = 'resigned' then
    h := app.staff_resign_holds(r.user_id, r.last_day);
    perform app.emit_event('staff_resignation_received', 'user', r.user_id, jsonb_build_object('user_id', r.user_id,
      'staff_name', app.staff_resign_name(r.user_id), 'role_label', app.staff_resign_role(sp), 'last_day', app.fmt_day(r.last_day), 'resigned_on', app.fmt_day(r.resigned_on),
      'reason', coalesce(r.reason, 'None given'), 'recorded_by', case when r.created_by = r.user_id then 'Themselves, in their portal' else app.staff_resign_name(r.created_by) end,
      'notice_text', case when r.status = 'ended' then 'None: their access ended at once (' || case when r.in_onboarding then 'onboarding' when r.in_trial then 'trial period' else 'last day today' end || ')'
                          else (r.last_day - r.resigned_on) || ' days (' || r.notice_days || ' asked)' end,
      'handover_text', format('Went back to the queue after the last day: %s field jobs and %s shifts. Still theirs: %s open jobs, %s leads, %s chats, %s To dos.',
                              coalesce(r.released ->> 'jobs', '0'), coalesce(r.released ->> 'shifts', '0'), h ->> 'jobs_open', h ->> 'leads', h ->> 'chats', h ->> 'tasks'),
      'final_pay_text', w ->> 'final_pay_text',
      'admin_url', v_base || '/admin/settings/staff#resign-' || r.user_id),
      'staff_resignation_received:' || r.id);
  elsif p_kind = 'withdrawn' then
    perform app.emit_event('staff_resignation_withdrawn', 'user', r.user_id, jsonb_build_object('user_id', r.user_id,
      'staff_name', app.staff_resign_name(r.user_id), 'role_label', app.staff_resign_role(sp), 'last_day', app.fmt_day(r.last_day),
      'withdrawn_by', case when r.withdrawn_by = r.user_id then 'Themselves, in their portal' else app.staff_resign_name(r.withdrawn_by) end,
      'admin_url', v_base || '/admin/settings/staff#resign-' || r.user_id),
      'staff_resignation_withdrawn:' || r.id);
  end if;
end $$;

-- ends the access of a staff member: the one function behind admin_do staff_end (End access, the connector's
-- end_staff_access) and the resignation job
create function app.staff_access_end(p_user uuid, p_on date default null) returns void
language plpgsql security definer set search_path = public, app, pg_temp as $$
begin
  update staff_profiles set is_active = false, ended_on = coalesce(p_on, app.today()) where user_id = p_user;
  update users set status = 'suspended' where id = p_user;
  if not found then raise exception 'That person is not on file' using errcode = 'P0002'; end if;
end $$;

-- a resignation ends: the access closes (on the last day, or today if earlier), what they still hold goes back
create function app.staff_resign_end(p_id uuid, p_by uuid) returns jsonb
language plpgsql security definer set search_path = public, app, pg_temp as $$
declare
  r staff_resignations;
  v_day date;
  n_tasks integer;
  n_chats integer;
  n_claims integer;
  n_more jsonb;
begin
  select * into r from staff_resignations where id = p_id for update;
  if r.id is null or r.status <> 'pending' then return null; end if;
  v_day := least(r.last_day, app.today());
  update staff_resignations set last_day = v_day where id = r.id and last_day > v_day;
  perform app.staff_access_end(r.user_id, v_day);
  -- from now on: anything left goes back to the queue
  update field_jobs set assigned_to = null, status = case when status = 'acknowledged' then 'scheduled' else status end, acknowledged_at = null
   where assigned_to = r.user_id and status in ('scheduled', 'acknowledged') and coalesce(scheduled_at, now()) >= now();
  update field_shift_plans set cancelled_at = now(), cancelled_by = coalesce(p_by, r.created_by), cancel_reason = 'Resigned: access ended'
   where staff_id = r.user_id and cancelled_at is null and starts_at >= now();
  update field_standing_shifts set ended_at = now(), ended_by = coalesce(p_by, r.created_by) where staff_id = r.user_id and ended_at is null;
  update tasks set assigned_to = null where assigned_to = r.user_id and status in ('open', 'in_progress', 'waiting');
  get diagnostics n_tasks = row_count;
  update chat_conversations set assigned_to = null where assigned_to = r.user_id and closed_at is null;
  get diagnostics n_chats = row_count;
  delete from lead_claims where claimed_by = r.user_id;
  get diagnostics n_claims = row_count;
  delete from request_claims where claimed_by = r.user_id;
  n_more := jsonb_build_object('tasks', n_tasks, 'chats', n_chats, 'claims', n_claims);
  update staff_resignations set status = 'ended', ended_at = now(), ended_by = p_by, released = released || jsonb_build_object('on_end', n_more) where id = r.id;
  insert into audit_log (actor_user_id, action, entity_table, entity_id, after)
  values (p_by, 'staff_resign_end', 'staff_resignations', r.id::text, jsonb_build_object('user_id', r.user_id, 'last_day', v_day, 'handed_back', n_more));
  return jsonb_build_object('id', r.id, 'ended', true, 'last_day', v_day);
end $$;

-- p: {last_day, reason, user_id (an Admin, for someone else)}
create function app.staff_resign(p_by uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app, pg_temp as $$
declare
  v_user uuid := coalesce(nullif(p ->> 'user_id', '')::uuid, p_by);
  v_admin boolean := app.user_is_admin(p_by);
  f jsonb;
  v_last date;
  v_earliest date;
  v_reason text := nullif(btrim(coalesce(p ->> 'reason', '')), '');
  r staff_resignations;
  v_rel jsonb;
  v_ended boolean := false;
begin
  if v_user <> p_by and not v_admin then raise exception 'Only the person themselves or an Admin can do this' using errcode = '42501'; end if;
  if v_user = p_by and v_admin then raise exception 'An Admin''s own access is not ended here' using errcode = '23514'; end if;
  f := app.staff_resign_facts(v_user);
  if not coalesce((f ->> 'staff')::boolean, false) then raise exception 'Staff only' using errcode = '42501'; end if;
  if not (f ->> 'active')::boolean then raise exception 'This access has already ended' using errcode = '23514'; end if;
  if exists (select 1 from staff_resignations x where x.user_id = v_user and x.status = 'pending') then
    raise exception 'A resignation is already in: withdraw it first, or an Admin changes its last day' using errcode = '23505';
  end if;
  begin
    v_last := coalesce(nullif(p ->> 'last_day', '')::date, (f ->> 'default_last_day')::date);
  exception when others then
    raise exception 'Choose your last day' using errcode = '22023';
  end;
  v_earliest := case when v_admin and v_user <> p_by then (f ->> 'today')::date else (f ->> 'earliest')::date end;
  if v_last < v_earliest then
    raise exception 'Your last day can be % at the earliest', app.fmt_day(v_earliest) using errcode = '22023';
  end if;
  if v_last > (f ->> 'latest')::date then raise exception 'Choose a last day within 120 days' using errcode = '22023'; end if;
  if length(coalesce(v_reason, '')) > 1000 then raise exception 'Keep the reason under 1,000 characters' using errcode = '22023'; end if;
  insert into staff_resignations (user_id, resigned_on, last_day, reason, notice_days, in_onboarding, in_trial, created_by)
  values (v_user, app.today(), v_last, v_reason, (f ->> 'notice_days')::int, (f ->> 'in_onboarding')::boolean, (f ->> 'in_trial')::boolean, p_by)
  returning * into r;
  v_rel := app.staff_resign_release(r.id, p_by);
  insert into audit_log (actor_user_id, action, entity_table, entity_id, after)
  values (p_by, 'staff_resign', 'staff_resignations', r.id::text, jsonb_build_object('user_id', v_user, 'last_day', v_last, 'reason', v_reason, 'released', v_rel));
  -- a last day of today (onboarding, the trial period, or an Admin): the access ends now, after the confirmation
  if v_last <= app.today() then
    perform app.staff_resign_end(r.id, p_by);
    v_ended := true;
  end if;
  perform app.staff_resign_task(r.id);
  perform app.staff_resign_notify(r.id, 'resigned');
  select * into r from staff_resignations where id = r.id;
  return jsonb_build_object('id', r.id, 'user_id', v_user, 'status', r.status, 'last_day', r.last_day, 'resigned_on', r.resigned_on, 'ended', v_ended,
    'released', v_rel, 'task_id', r.task_id);
end $$;

-- p: {user_id (an Admin, for someone else)}: until the last day
create function app.staff_resign_withdraw(p_by uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app, pg_temp as $$
declare
  v_user uuid := coalesce(nullif(p ->> 'user_id', ''), nullif(p ->> 'user', ''))::uuid;
  r staff_resignations;
begin
  v_user := coalesce(v_user, p_by);
  if v_user <> p_by and not app.user_is_admin(p_by) then raise exception 'Only the person themselves or an Admin can do this' using errcode = '42501'; end if;
  select * into r from staff_resignations where user_id = v_user and status = 'pending' for update;
  if r.id is null then raise exception 'There is no resignation to withdraw' using errcode = 'P0002'; end if;
  if app.today() > r.last_day then raise exception 'The last day has passed: ask an Admin' using errcode = '23514'; end if;
  update staff_resignations set status = 'withdrawn', withdrawn_at = now(), withdrawn_by = p_by where id = r.id returning * into r;
  update tasks set status = 'cancelled', completed_at = now(), completed_by = p_by, completion_note = 'Closed by itself: the resignation was withdrawn'
   where id = r.task_id and status in ('open', 'in_progress', 'waiting');
  insert into audit_log (actor_user_id, action, entity_table, entity_id, after)
  values (p_by, 'staff_resign_withdraw', 'staff_resignations', r.id::text, jsonb_build_object('user_id', v_user));
  perform app.staff_resign_notify(r.id, 'withdrawn');
  return jsonb_build_object('id', r.id, 'status', r.status);
end $$;

-- Admin: p {user, last_day}: earlier or later, from today
create function app.staff_resign_last_day(p_by uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app, pg_temp as $$
declare
  v_user uuid := coalesce(nullif(p ->> 'user', ''), nullif(p ->> 'user_id', ''))::uuid;
  v_last date;
  r staff_resignations;
  v_old date;
begin
  perform app.assert_admin(p_by);
  select * into r from staff_resignations where user_id = v_user and status = 'pending' for update;
  if r.id is null then raise exception 'There is no resignation in for this person' using errcode = 'P0002'; end if;
  begin v_last := (p ->> 'last_day')::date; exception when others then v_last := null; end;
  if v_last is null then raise exception 'Choose the last day' using errcode = '22023'; end if;
  if v_last < app.today() then raise exception 'The last day can be today at the earliest; End access ends it now' using errcode = '22023'; end if;
  if v_last > app.today() + 120 then raise exception 'Choose a last day within 120 days' using errcode = '22023'; end if;
  v_old := r.last_day;
  if v_last = v_old then return jsonb_build_object('id', r.id, 'last_day', v_last, 'changed', false); end if;
  update staff_resignations set last_day = v_last, last_day_changed_at = now(), last_day_changed_by = p_by where id = r.id;
  perform app.staff_resign_release(r.id, p_by);
  perform app.staff_resign_task(r.id);
  insert into audit_log (actor_user_id, action, entity_table, entity_id, before, after)
  values (p_by, 'staff_resign_last_day', 'staff_resignations', r.id::text, jsonb_build_object('last_day', v_old), jsonb_build_object('last_day', v_last));
  perform app.staff_resign_notify(r.id, 'changed');
  return jsonb_build_object('id', r.id, 'last_day', v_last, 'changed', true);
end $$;

-- Admin: every staff member's latest resignation, by user (Staff and roles)
create function app.staff_resignations_read(p_by uuid, p jsonb) returns jsonb
language plpgsql stable security definer set search_path = public, app, pg_temp as $$
begin
  perform app.assert_admin(p_by);
  return coalesce((select jsonb_object_agg(x.user_id, jsonb_build_object('id', x.id, 'status', x.status, 'resigned_on', x.resigned_on, 'last_day', x.last_day, 'reason', x.reason,
      'created_at', x.created_at, 'by_self', x.created_by = x.user_id, 'recorded_by', app.staff_resign_name(x.created_by), 'withdrawn_at', x.withdrawn_at, 'ended_at', x.ended_at,
      'task_id', x.task_id, 'task_open', exists (select 1 from tasks t where t.id = x.task_id and t.status in ('open', 'in_progress', 'waiting')),
      'started_on', (select sp.started_on from staff_profiles sp where sp.user_id = x.user_id), 'released', x.released))
    from (select distinct on (r.user_id) r.* from staff_resignations r order by r.user_id, (r.status = 'pending') desc, r.created_at desc) x), '{}'::jsonb);
end $$;

-- the connector's list_staff shows the resignation
alter function app.api_staff_row(uuid) rename to api_staff_row_pre5020;
create function app.api_staff_row(p_id uuid) returns jsonb
language sql stable security definer set search_path = public, app, pg_temp as $$
  select app.api_staff_row_pre5020(p_id) || jsonb_build_object('resignation',
    (select jsonb_build_object('status', case r.status when 'pending' then 'resigning' when 'ended' then 'resigned' else 'withdrawn' end,
       'resigned_on', r.resigned_on, 'last_day', r.last_day, 'reason', r.reason, 'recorded_by', app.staff_resign_name(r.created_by),
       'withdrawn_at', r.withdrawn_at, 'ended_at', r.ended_at, 'todo_id', r.task_id)
       from staff_resignations r where r.user_id = p_id order by (r.status = 'pending') desc, r.created_at desc limit 1))
$$;
select pg_temp.copy_grants('app.api_staff_row(uuid)'::regprocedure, 'app.api_staff_row_pre5020(uuid)'::regprocedure);

-- ================================================================ 4. End access: one function, and a pending resignation ends with it
alter function app.admin_do(uuid, text, jsonb) rename to admin_do_pre5020;
create function app.admin_do(p_admin uuid, p_action text, p jsonb default '{}'::jsonb) returns jsonb
language plpgsql security definer set search_path = public, app, pg_temp as $$
declare
  v_user uuid;
  r staff_resignations;
begin
  if p_action = 'staff_end' then
    perform app.admin_begin(p_admin);
    v_user := (p ->> 'user')::uuid;
    if v_user = p_admin then raise exception 'You cannot end your own access' using errcode = '23514'; end if;
    select * into r from staff_resignations where user_id = v_user and status = 'pending';
    if r.id is not null then
      perform app.staff_resign_end(r.id, p_admin);
    else
      perform app.staff_access_end(v_user);
    end if;
    return jsonb_build_object('ok', true);
  end if;
  return app.admin_do_pre5020(p_admin, p_action, p);
end $$;
select pg_temp.copy_grants('app.admin_do(uuid, text, jsonb)'::regprocedure, 'app.admin_do_pre5020(uuid, text, jsonb)'::regprocedure);

-- ================================================================ 5. nothing after the last day: no new shift, no job
alter function app.field_shift_book(uuid, uuid, uuid) rename to field_shift_book_pre5020;
create function app.field_shift_book(p_staff uuid, p_slot uuid, p_by uuid) returns jsonb
language plpgsql security definer set search_path = public, app, pg_temp as $$
begin
  if exists (select 1 from staff_resignations r join field_shift_slots s on s.id = p_slot
              where r.user_id = p_staff and r.status = 'pending' and s.starts_at >= ((r.last_day + 1)::timestamp at time zone 'America/Toronto')) then
    raise exception 'That shift is after % last day', case when p_staff = p_by then 'your' else 'their' end using errcode = '23514';
  end if;
  return app.field_shift_book_pre5020(p_staff, p_slot, p_by);
end $$;
select pg_temp.copy_grants('app.field_shift_book(uuid, uuid, uuid)'::regprocedure, 'app.field_shift_book_pre5020(uuid, uuid, uuid)'::regprocedure);

alter function app.assign_field_job(uuid, uuid, uuid) rename to assign_field_job_pre5020;
create function app.assign_field_job(p_job uuid, p_assignee uuid, p_by uuid) returns void
language plpgsql security definer set search_path = public, app, pg_temp as $$
begin
  if p_assignee is not null and exists (select 1 from staff_resignations r join field_jobs j on j.id = p_job
              where r.user_id = p_assignee and r.status = 'pending' and j.scheduled_at >= ((r.last_day + 1)::timestamp at time zone 'America/Toronto')) then
    raise exception 'That job is after their last day (they resigned)' using errcode = '23514';
  end if;
  perform app.assign_field_job_pre5020(p_job, p_assignee, p_by);
end $$;
select pg_temp.copy_grants('app.assign_field_job(uuid, uuid, uuid)'::regprocedure, 'app.assign_field_job_pre5020(uuid, uuid, uuid)'::regprocedure);

-- ================================================================ 6. the job: after the last day, the access ends
create function app.job_staff_resignations(p_now timestamptz default now()) returns integer
language plpgsql security definer set search_path = public, app, pg_temp as $$
declare
  r record;
  n integer := 0;
begin
  for r in select x.id from staff_resignations x where x.status = 'pending' and x.last_day < app.local_date(p_now) order by x.last_day loop
    begin
      perform app.staff_resign_end(r.id, null);
      n := n + 1;
    exception when others then
      insert into audit_log (action, entity_table, entity_id, after) values ('staff_resign_end_failed', 'staff_resignations', r.id::text, jsonb_build_object('error', left(sqlerrm, 300)));
    end;
  end loop;
  return n;
end $$;

do $$
begin
  if not exists (select 1 from pg_available_extensions where name = 'pg_cron') then
    raise notice 'pg_cron is not available here: the resignations job is not scheduled';
    return;
  end if;
  begin
    create extension if not exists pg_cron;
  exception when others then
    raise warning 'pg_cron could not be created in this database (%): the resignations job is not scheduled', sqlerrm;
    return;
  end;
  perform cron.schedule('carmacars-r50-resignations', '4,19,34,49 * * * *', $q$select app.job_staff_resignations()$q$);
end $$;

-- ================================================================ 7. the door
alter function app.door(uuid, text, text, text, jsonb) rename to door_pre5020;
create function app.door(p_user uuid, p_aal text, p_call text, p_name text, p jsonb default '{}'::jsonb) returns jsonb
language plpgsql security definer set search_path = public, app, pg_temp as $$
declare
  p_ jsonb := coalesce(p, '{}'::jsonb) - '_va';
  v_user uuid;
begin
  if (p_call in ('ops_read', 'field_read', 'admin_read') and p_name in ('staff_resign_facts', 'staff_resignations'))
     or (p_call in ('ops_do', 'field_do', 'admin_do') and p_name in ('staff_resign', 'staff_resign_withdraw', 'staff_resign_last_day')) then
    perform app.door_begin(p_user, p_aal);
    if p_name = 'staff_resign_facts' then
      v_user := coalesce(nullif(p_ ->> 'user_id', '')::uuid, p_user);
      if v_user <> p_user then perform app.assert_admin(p_user); end if;
      return app.staff_resign_facts(v_user);
    end if;
    return case p_name when 'staff_resignations' then app.staff_resignations_read(p_user, p_)
                       when 'staff_resign' then app.staff_resign(p_user, p_)
                       when 'staff_resign_withdraw' then app.staff_resign_withdraw(p_user, p_)
                       else app.staff_resign_last_day(p_user, p_) end;
  end if;
  return app.door_pre5020(p_user, p_aal, p_call, p_name, p);
end $$;
select pg_temp.copy_grants('app.door(uuid, text, text, text, jsonb)'::regprocedure, 'app.door_pre5020(uuid, text, text, text, jsonb)'::regprocedure);

-- ================================================================ privileges: the server only
do $$
declare f record;
begin
  for f in select p.oid::regprocedure as sig from pg_proc p join pg_namespace n on n.oid = p.pronamespace
            where n.nspname = 'app' and p.proname = any (array['staff_resign_name', 'staff_resign_first', 'staff_resign_role', 'staff_resign_period_end', 'staff_resign_words',
                    'staff_resign_holds', 'staff_resign_facts', 'staff_resign_release', 'staff_resign_task', 'staff_resign_notify', 'staff_access_end', 'staff_resign_end',
                    'staff_resign', 'staff_resign_withdraw', 'staff_resign_last_day', 'staff_resignations_read', 'api_staff_row_pre5020', 'admin_do_pre5020',
                    'field_shift_book_pre5020', 'assign_field_job_pre5020', 'job_staff_resignations', 'door_pre5020']) loop
    execute format('revoke all on function %s from public, anon, authenticated', f.sig);
    execute format('grant execute on function %s to service_role', f.sig);
  end loop;
end $$;
