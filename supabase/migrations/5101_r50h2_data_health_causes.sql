-- 5101 (R50 hotfix 2): the causes behind the Data health counts of Nov 25 (pickup not recorded 4, never closed 12,
-- assigned to someone gone 8, leads not followed up 247), and the daily notice that repeated itself.
-- SCHEMA_MARKER is not changed (no web code reads anything new).
--
-- 1. Data health "Mark picked up" and "Close" (and Bookings > Now "Close") recorded the pickup through the gated
--    handover (app.handover_record_now): a car already out with no deposit held, no signed check-in report, missing
--    agreement details or no tracker reading was refused, so staff could not record the pickup or the return of exactly
--    the bookings the card lists. They now record the pickup at the booked time the way 4730 does for staff
--    (app.pickup_record_booked_time: an audited override, Admin and Fleet told, what is still owed becomes To dos).
--    No payment, deposit or charge is written by the pickup. The return of "Close" is the same as before.
-- 2. Ending a person's access (app.staff_access_end, a resignation, an Admin) left their open tasks, leads, field jobs,
--    chats, visitors and request claims on them. A trigger now sends that work back to its queue the moment the person is
--    gone; the Data health fixes do the same for anything left (and the self-healing playbook data-health.autofix now
--    matches "Assigned to someone gone").
-- 3. "Leads not followed up" counted owner leads whose follow-up ended as designed (all follow-ups sent, they replied,
--    one message for a referral, no consent, a later stage). It now counts a stop only for another reason, and an owner
--    lead with an email whose follow-up never started is started by the Data health fixes (the owner_followup_enabled
--    switch was the only reason it would not have started).
-- 4. The daily Data health notice: sent only when the problems changed since the run before, one line and one link per
--    problem.

create function pg_temp.copy_grants(p_new regprocedure, p_old regprocedure) returns void
language plpgsql as $$
declare g text;
begin
  execute format('revoke all on function %s from public, anon, authenticated', p_new);
  foreach g in array array['anon', 'authenticated', 'service_role'] loop
    if has_function_privilege(g, p_old, 'execute') then execute format('grant execute on function %s to %I', p_new, g); end if;
  end loop;
end $$;

-- ================================================================ 1. pickups and returns of cars already out
alter function app.booking_close_ended(uuid, jsonb) rename to booking_close_ended_pre5101;
create function app.booking_close_ended(p_by uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app, pg_temp as $$
declare
  b bookings;
  v_reason text := coalesce(nullif(btrim(coalesce(p ->> 'reason', '')), ''), 'Ended, never closed: recorded from Bookings > Now');
begin
  select * into b from bookings where id::text = p ->> 'booking' or booking_number = upper(btrim(coalesce(p ->> 'booking', '')));
  if b.id is null then raise exception 'Booking not found' using errcode = 'P0002'; end if;
  if b.status::text <> 'confirmed' or b.handed_over_at is not null or b.return_at >= now() then
    raise exception 'Booking % has not ended without a check-in (it is %)', b.booking_number, replace(b.status::text, '_', ' ') using errcode = '23514';
  end if;
  -- the pickup at the booked time, as 4730's one tap (the car went out: the checks become To dos, never a refusal)
  perform app.pickup_record_booked_time(p_by, b.id, 'staff');
  perform app.handover_record_now(p_by, jsonb_build_object('booking', b.id, 'kind', 'return', 'at', b.return_at, 'reason', v_reason));
  return jsonb_build_object('ok', true, 'booking_status', (select status from bookings where id = b.id));
end $$;
select pg_temp.copy_grants('app.booking_close_ended(uuid, jsonb)'::regprocedure, 'app.booking_close_ended_pre5101(uuid, jsonb)'::regprocedure);

-- the record leaves the last run, so the card and the next notice show the result at once (as data_health_fix did)
create function app.dh_drop_item(p_id uuid) returns void
language plpgsql security definer set search_path = public, app, pg_temp as $$
begin
  update data_health_runs h set checks = (
           select coalesce(jsonb_agg(case when exists (select 1 from jsonb_array_elements(c -> 'items') i where i ->> 'id' = p_id::text)
                                          then c || jsonb_build_object('count', greatest((c ->> 'count')::integer - 1, 0),
                                                                       'items', coalesce((select jsonb_agg(i) from jsonb_array_elements(c -> 'items') i where i ->> 'id' is distinct from p_id::text), '[]'::jsonb))
                                          else c end order by o), '[]'::jsonb)
             from jsonb_array_elements(h.checks) with ordinality e(c, o))
   where h.id = (select id from data_health_runs order by ran_at desc limit 1);
  update data_health_runs h set issues = (select coalesce(sum((c ->> 'count')::integer), 0) from jsonb_array_elements(h.checks) c)
   where h.id = (select id from data_health_runs order by ran_at desc limit 1);
end $$;

alter function app.data_health_fix(uuid, jsonb) rename to data_health_fix_pre5101;
create function app.data_health_fix(p_by uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app, pg_temp as $$
declare
  v_id uuid;
  b bookings;
begin
  if coalesce(p ->> 'action', '') <> 'mark_picked_up' then return app.data_health_fix_pre5101(p_by, p); end if;
  perform app.assert_admin(p_by);
  v_id := nullif(p ->> 'id', '')::uuid;
  if v_id is null then raise exception 'Choose the record to fix' using errcode = '22023'; end if;
  select * into b from bookings where id = v_id;
  if b.id is null or b.status::text <> 'confirmed' or b.handed_over_at is not null or b.pickup_at > now() then
    raise exception 'This booking is not waiting for its pickup to be recorded' using errcode = '23514';
  end if;
  perform app.pickup_record_booked_time(p_by, b.id, 'staff');
  insert into audit_log (actor_user_id, action, entity_table, entity_id, after) values (p_by, 'data_health_fix', 'data_health_runs', v_id::text, p);
  perform app.dh_drop_item(v_id);
  return jsonb_build_object('ok', true, 'changed', 1);
end $$;
select pg_temp.copy_grants('app.data_health_fix(uuid, jsonb)'::regprocedure, 'app.data_health_fix_pre5101(uuid, jsonb)'::regprocedure);

-- ================================================================ 2. a person who leaves hands their open work back
create function app.staff_release_work(p_user uuid) returns jsonb
language plpgsql security definer set search_path = public, app, pg_temp as $$
declare n_tasks integer; n_leads integer; n_jobs integer; n_chats integer; n_visits integer; n_claims integer;
begin
  if p_user is null then return '{}'::jsonb; end if;
  update tasks set assigned_to = null, status = case when status = 'in_progress' then 'open' else status end
   where assigned_to = p_user and status in ('open', 'in_progress', 'waiting');
  get diagnostics n_tasks = row_count;
  update leads set assigned_to = null where assigned_to = p_user and status in ('new', 'contacted', 'qualified');
  get diagnostics n_leads = row_count;
  update field_jobs set assigned_to = null, status = case when status = 'acknowledged' then 'scheduled' else status end, acknowledged_at = null
   where assigned_to = p_user and status in ('scheduled', 'acknowledged');
  get diagnostics n_jobs = row_count;
  update chat_conversations set assigned_to = null where assigned_to = p_user and status <> 'closed';
  get diagnostics n_chats = row_count;
  update visitor_sessions set assigned_to = null, assigned_at = null where assigned_to = p_user;
  get diagnostics n_visits = row_count;
  delete from request_claims where claimed_by = p_user;
  get diagnostics n_claims = row_count;
  return jsonb_strip_nulls(jsonb_build_object('gone_tasks', nullif(n_tasks, 0), 'gone_leads', nullif(n_leads, 0), 'gone_field_jobs', nullif(n_jobs, 0),
    'gone_chats', nullif(n_chats, 0), 'gone_visitors', nullif(n_visits, 0), 'gone_claims', nullif(n_claims, 0)));
end $$;

create function app.staff_gone_release() returns trigger
language plpgsql security definer set search_path = public, app, pg_temp as $$
declare v_user uuid := (to_jsonb(new) ->> case when tg_table_name = 'users' then 'id' else 'user_id' end)::uuid;
begin
  if app.dh_gone(v_user) then perform app.staff_release_work(v_user); end if;
  return null;
end $$;
create trigger staff_profiles_gone_release after update of is_active on staff_profiles
  for each row when (old.is_active and not new.is_active) execute function app.staff_gone_release();
create trigger users_gone_release after update of status on users
  for each row when (old.status = 'active' and new.status is distinct from 'active') execute function app.staff_gone_release();

-- the Data health fixes: anything still on someone gone goes back to its queue; an owner lead whose follow-up never
-- started (it has an email) starts now
alter function app.data_health_autofix(timestamptz) rename to data_health_autofix_pre5101;
create function app.data_health_autofix(p_now timestamptz default now()) returns jsonb
language plpgsql security definer set search_path = public, app, pg_temp as $$
declare
  v jsonb := app.data_health_autofix_pre5101(p_now);
  u uuid;
  x jsonb;
  n_gone integer := 0;
  n_follow integer := 0;
begin
  for u in select distinct a from (
             select t.assigned_to a from tasks t where t.status in ('open', 'in_progress', 'waiting') and t.assigned_to is not null
             union select l.assigned_to from leads l where l.status in ('new', 'contacted', 'qualified') and l.assigned_to is not null) q
           where app.dh_gone(a) loop
    x := app.staff_release_work(u);
    n_gone := n_gone + coalesce((x ->> 'gone_tasks')::integer, 0) + coalesce((x ->> 'gone_leads')::integer, 0);
  end loop;
  if coalesce((app.settings()).owner_followup_enabled, false) then
    update leads l set followup_next_at = p_now
     where l.kind in ('owner_program', 'owner_recruit') and l.status in ('new', 'contacted', 'qualified') and coalesce(l.pipeline_stage, 'new') = 'new'
       and l.email is not null and l.replied_at is null and l.do_not_contact_at is null and not app.is_test_email(l.email)
       and l.followup_stopped_at is null and l.followup_next_at is null and l.followup_step = 0 and l.created_at < p_now - interval '1 hour';
    get diagnostics n_follow = row_count;
  end if;
  return v || jsonb_strip_nulls(jsonb_build_object('gone_assignees', nullif(n_gone, 0), 'followups_started', nullif(n_follow, 0)));
end $$;
select pg_temp.copy_grants('app.data_health_autofix(timestamptz)'::regprocedure, 'app.data_health_autofix_pre5101(timestamptz)'::regprocedure);

-- self-healing (4800): "Assigned to someone gone" is now an incident the Data health fixes clear by themselves
alter function app.heal_signals(timestamptz) rename to heal_signals_pre5101;
create function app.heal_signals(p_now timestamptz default now())
returns table (source text, key text, fingerprint text, title text, detail text, state text, path text, evidence jsonb)
language plpgsql stable security definer set search_path = public, app, pg_temp as $$
begin
  return query select * from app.heal_signals_pre5101(p_now);
  return query
    select 'data_health'::text, c ->> 'key', 'data_health:' || (c ->> 'key'), 'Data health: ' || coalesce(c ->> 'title', c ->> 'key'),
           left(app.redact_text(c ->> 'line'), 500), 'open'::text, c ->> 'href', jsonb_build_object('count', (c ->> 'count')::integer, 'run_at', d.ran_at)
      from (select * from data_health_runs order by ran_at desc limit 1) d, jsonb_array_elements(coalesce(d.checks, '[]'::jsonb)) c
     where coalesce((c ->> 'count')::integer, 0) > 0 and c ->> 'key' = 'inactive_assignee';
end $$;
select pg_temp.copy_grants('app.heal_signals(timestamptz)'::regprocedure, 'app.heal_signals_pre5101(timestamptz)'::regprocedure);

update heal_playbooks set match_key = '^(test_accounts|duplicate_tasks|resolved_tasks|inactive_assignee)$',
       learned_from = '0441: the fixes Data health makes without asking; 5101: work left on someone gone'
 where key = 'data-health.autofix';

-- ================================================================ 3. leads not followed up: only real gaps
alter function app.data_health(timestamptz) rename to data_health_pre5101;
create function app.data_health(p_now timestamptz default now()) returns jsonb
language plpgsql stable security definer set search_path = public, app, pg_temp as $$
declare
  r jsonb := app.data_health_pre5101(p_now);
  x jsonb;
  c jsonb;
  v_old integer;
begin
  select coalesce(jsonb_agg(i order by i ->> 'text'), '[]'::jsonb) into x from (
    select app.dh_item(l.id,
             format('%s (%s owner lead): %s', coalesce(l.name, l.email, l.phone), app.fmt_day(app.local_date(l.created_at)),
                    case when l.followup_stopped_at is not null then 'follow-up stopped (' || coalesce(l.followup_stop_reason, 'no reason') || ')'
                         when l.email is null then 'no email: call them' else 'no follow-up planned' end),
             '/admin/leads', case when l.email is not null then 'restart_followup' end, 'Restart follow-up') i
      from leads l
     where l.kind in ('owner_program', 'owner_recruit') and l.status in ('new', 'contacted', 'qualified')
       and coalesce(l.pipeline_stage, 'new') in ('new', 'contacted') and l.replied_at is null and l.do_not_contact_at is null
       and not app.is_test_email(l.email) and l.created_at < p_now - interval '1 hour'
       and ((l.followup_stopped_at is null and l.followup_next_at is null)
            or (l.followup_stopped_at is not null and coalesce(l.followup_stop_reason, '') not in ('All follow-ups sent', 'They replied', 'A referral allows one message')
                and coalesce(l.followup_stop_reason, '') not like 'Not sent:%' and coalesce(l.followup_stop_reason, '') not like 'Stage is%'))
       and not exists (select 1 from owners o where o.id = l.owner_id and o.status = 'active')
    union all
    select app.dh_item(l.id, format('%s (%s, %s): still new, nobody has replied', coalesce(l.name, l.email, l.phone), replace(l.kind, '_', ' '), app.fmt_day(app.local_date(l.created_at))),
                       '/admin/leads')
      from leads l
     where l.kind not in ('owner_program', 'owner_recruit', 'turo_guest', 'launch_notice', 'sample_car') and l.status = 'new'
       and l.created_at < p_now - interval '2 days' and l.created_at > p_now - interval '60 days' and not app.is_test_email(l.email)) q;
  c := app.dh_check('lead_followup', 'Leads not followed up', 'Real leads with their follow-up stopped or never started', x, '/admin/leads');
  select (e ->> 'count')::integer into v_old from jsonb_array_elements(r -> 'checks') e where e ->> 'key' = 'lead_followup';
  return jsonb_set(jsonb_set(r, '{checks}', coalesce((select jsonb_agg(case when e ->> 'key' = 'lead_followup' then c else e end order by o)
                                                        from jsonb_array_elements(r -> 'checks') with ordinality t(e, o)), '[]'::jsonb)),
                   '{issues}', to_jsonb((r ->> 'issues')::integer - coalesce(v_old, 0) + case when v_old is null then 0 else (c ->> 'count')::integer end));
end $$;
select pg_temp.copy_grants('app.data_health(timestamptz)'::regprocedure, 'app.data_health_pre5101(timestamptz)'::regprocedure);

-- ================================================================ 4. the daily notice: only when something changed
-- what a run found, as "key:count" pairs (the problems with a count), for comparing two runs
create function app.dh_fingerprint(p_checks jsonb) returns text
language sql immutable set search_path = public, app, pg_temp as $$
  select coalesce(string_agg((c ->> 'key') || ':' || (c ->> 'count'), ',' order by c ->> 'key'), '')
    from jsonb_array_elements(coalesce(p_checks, '[]'::jsonb)) c where coalesce((c ->> 'count')::integer, 0) > 0
$$;

create or replace function app.job_data_health(p_now timestamptz default now()) returns jsonb
language plpgsql security definer set search_path = public, app, pg_temp as $$
declare
  v_fixed jsonb := app.data_health_autofix(p_now);
  r jsonb := app.data_health_store(p_now, v_fixed, null);
  v_issues integer := (r ->> 'issues')::integer;
  v_day text := to_char(app.local_date(p_now), 'YYYY-MM-DD');
  v_base text := rtrim(coalesce((app.settings()).notify_base_url, 'https://carmacars.ca'), '/');
  v_prev text := (select app.dh_fingerprint(h.checks) from data_health_runs h where h.id <> (r ->> 'id')::uuid order by h.ran_at desc limit 1);
  v_sent integer := 0;
begin
  -- one in-app notice to each Admin (not the verification's), only when something needs them and it changed since the
  -- run before; one line and one link for each problem. Never an email.
  if v_issues > 0 and app.dh_fingerprint(r -> 'checks') is distinct from v_prev then
    insert into notifications (user_id, code, title, body, url, entity, dedupe_key)
    select u.id, 'staff_data_health', format('Data health: %s to look at', v_issues),
           (select string_agg(format('%s %s: %s', c ->> 'count', lower(c ->> 'title'), v_base || coalesce(c ->> 'href', '/admin#data-health')),
                              E'\n' order by (c ->> 'count')::integer desc)
              from jsonb_array_elements(r -> 'checks') c where (c ->> 'count')::integer > 0),
           '/admin#data-health', 'data_health', 'data_health:' || v_day || ':' || md5(app.dh_fingerprint(r -> 'checks')) || '|' || u.id
      from users u join user_roles ur on ur.user_id = u.id and ur.role = 'admin'
     where u.status = 'active' and not u.is_test
    on conflict (dedupe_key) do nothing;
    get diagnostics v_sent = row_count;
  end if;
  return jsonb_build_object('issues', v_issues, 'fixed', v_fixed, 'notices', v_sent);
end $$;

do $$
declare f record;
begin
  for f in select p.oid::regprocedure as sig from pg_proc p join pg_namespace n on n.oid = p.pronamespace
            where n.nspname = 'app' and p.proname = any (array['booking_close_ended', 'booking_close_ended_pre5101', 'dh_drop_item', 'data_health_fix', 'data_health_fix_pre5101',
              'staff_release_work', 'staff_gone_release', 'data_health_autofix', 'data_health_autofix_pre5101', 'heal_signals', 'heal_signals_pre5101',
              'data_health', 'data_health_pre5101', 'dh_fingerprint', 'job_data_health']) loop
    execute format('revoke all on function %s from public, anon, authenticated', f.sig);
    execute format('grant execute on function %s to service_role', f.sig);
  end loop;
end $$;
