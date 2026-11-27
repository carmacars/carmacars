-- 5102 (R50 hotfix 2, the owner on Nov 26: "alerts and To do's keep piling up: a permanent fix"). From the live list of
-- Nov 27 (200+ open To do's; one booking, CC-10593, had five: pickup not recorded, presumed out past its return, 120
-- minutes overdue, past trip open and a job nobody took) and Admin > Self-healing (176 incidents in 7 days, all
-- "Jobs locked and left behind", each escalated with "It came back 129 times": a To do, a bug report and an alert each).
-- SCHEMA_MARKER is not changed.
--
-- 1. To do's close themselves when what they ask for is done (the pickup or the return recorded, the deposit taken,
--    released or lapsed, the field job taken, the trip closed, the self-healing incident cleared); To do's about the same
--    booking's one problem (the pickup never recorded, the car late or past its return) merge into one; follow-ups
--    nobody needs any more expire after 7 days (a missed call, an unfinished form, a visitor), each with its reason in
--    the To do's note and the audit log. Self-healing runs the sweep every hour (app.job_todo_sweep, pg_cron).
-- 2. Noise: Verify and test accounts are never warned or suspended for inactivity (and those suspended are unlocked);
--    "Jobs locked and left behind" judged a photo by the time its job first started, so every retry of a photo looked
--    stuck an hour later and was put back in the queue (the claim keeps the first start time): it now looks at the
--    worker's current lock; an incident that was already escalated in the last 24 hours is not escalated again (no
--    second To do, bug report or alert).
-- 3. Decided from the data, logged: a card hold past its expiry with no processor to renew it is recorded as lapsed (it
--    holds nothing; no money moves); a toll statement read whose every line passed its checks (confidence at or above
--    Program settings toll_read_min_confidence, plate, date, amount, issuer) is confirmed as Finance would.
-- 4. Return time: Admin and Fleet are told 30 minutes before a car is due back and at the return time (before, the
--    first Admin word was the "120 minutes overdue" To do).
-- 5. A new request tells Admin, Sales and customer service at once (before, only customer service by email, then
--    "waiting 2 hours").
-- Money out (refunds, deposit releases, payouts, charges) is never done here: still a prepared action, as before.

create function pg_temp.copy_grants(p_new regprocedure, p_old regprocedure) returns void
language plpgsql as $$
declare g text;
begin
  execute format('revoke all on function %s from public, anon, authenticated', p_new);
  foreach g in array array['anon', 'authenticated', 'service_role'] loop
    if has_function_privilege(g, p_old, 'execute') then execute format('grant execute on function %s to %I', p_new, g); end if;
  end loop;
end $$;

-- ================================================================ 1. To do's that close, merge and expire
alter function app.dh_resolved_tasks() rename to dh_resolved_tasks_pre5102;
create function app.dh_resolved_tasks() returns table (task_id uuid, why text)
language sql stable security definer set search_path = public, app, pg_temp as $$
  select * from app.dh_resolved_tasks_pre5102()
  union all
  select t.id, 'The pickup is recorded (the booking is ' || replace(b.status::text, '_', ' ') || ')'
    from tasks t join bookings b on b.id = t.booking_id
   where t.status in ('open', 'in_progress', 'waiting') and t.task_type in ('pickup_unrecorded', 'pickup_unrecorded_admin', 'schedule_handover', 'take_deposit', 'deposit_not_taken')
     and (b.handed_over_at is not null or b.status::text <> 'confirmed')
  union all
  select t.id, 'The deposit is taken or waived'
    from tasks t join bookings b on b.id = t.booking_id
   where t.status in ('open', 'in_progress', 'waiting') and t.task_type in ('take_deposit', 'deposit_not_taken') and b.status::text = 'confirmed'
     and (b.deposit_waived_at is not null or exists (select 1 from deposits d where d.booking_id = b.id and d.status in ('held', 'captured')))
  union all
  select t.id, 'The trip is closed (the booking is ' || replace(b.status::text, '_', ' ') || ')'
    from tasks t join bookings b on b.id = t.booking_id
   where t.status in ('open', 'in_progress', 'waiting') and t.task_type = 'past_trip_open'
     and b.status::text in ('returned', 'closed', 'cancelled', 'expired', 'declined', 'no_show')
  union all
  select t.id, 'No deposit is held any more'
    from tasks t join bookings b on b.id = t.booking_id
   where t.status in ('open', 'in_progress', 'waiting') and t.task_type = 'renew_deposit_hold'
     and not exists (select 1 from deposits d where d.booking_id = b.id and d.status = 'held')
  union all
  -- a deposit to release or review: closed only once nothing of it is left to give back (a release is money out: a person does it)
  select t.id, 'Nothing of the deposit is left to give back'
    from tasks t join bookings b on b.id = t.booking_id
   where t.status in ('open', 'in_progress', 'waiting') and t.task_type in ('release_deposit', 'deposit_review_fleet')
     and not exists (select 1 from deposits d where d.booking_id = b.id and d.status in ('held', 'captured')
                       and d.amount_cents - d.applied_cents - d.released_cents > 0)
  union all
  select t.id, 'The field job is taken, done or cancelled'
    from tasks t join field_jobs j on j.id = t.related_id
   where t.status in ('open', 'in_progress', 'waiting') and t.related_table = 'field_jobs' and t.task_type = 'job_unacknowledged'
     and (j.status in ('done', 'cancelled') or (j.assigned_to is not null and j.acknowledged_at is not null))
  union all
  select t.id, 'Self-healing cleared the problem'
    from tasks t join heal_incidents i on i.id = t.related_id
   where t.status in ('open', 'in_progress', 'waiting') and t.task_type = 'self_heal' and t.related_table = 'heal_incidents' and i.status = 'healed'
$$;

-- one problem of one booking, one To do: the first of these ranks stays, the others are merged into it. A booking still
-- confirmed after its pickup time is a pickup never recorded (the car is presumed out; "overdue" is the same gap); a car
-- on rent past its return is late, and only its two late To do's merge (closing the trip is another decision).
create function app.todo_family_rank(p_type text, p_status text) returns integer
language sql immutable set search_path = public, app, pg_temp as $$
  select case when p_status = 'confirmed' then array_position(array['past_trip_open', 'pickup_unrecorded_admin', 'late_return_admin', 'pickup_unrecorded', 'late_return'], p_type)
              when p_status = 'on_rent' then array_position(array['late_return_admin', 'late_return'], p_type) end
$$;

-- follow-ups that lose their point after a week (their subject is a person who did not come back, or a moment passed)
create function app.todo_expires_after(p_type text) returns interval
language sql immutable set search_path = public, app, pg_temp as $$
  select case
    when p_type in ('capture_follow_up', 'visitor_follow_up', 'chat_contact', 'phone_missed_call', 'expired_offer_lead', 'owner_unfinished_application', 'chat_request')
      then interval '7 days'
    -- a slot, a shift or a job whose time has passed a day ago
    when p_type in ('field_slot_unclaimed', 'field_shift_unclaimed', 'job_unacknowledged') then interval '1 day'
  end
$$;

create function app.job_todo_sweep(p_now timestamptz default now()) returns jsonb
language plpgsql security definer set search_path = public, app, pg_temp as $$
declare
  n_res integer := 0; n_dup integer := 0; n_merge integer := 0; n_old integer := 0;
begin
  if not pg_try_advisory_xact_lock(hashtext('carmacars-todo-sweep')) then return jsonb_build_object('skipped', 'already running'); end if;
  -- done: what the To do asked for happened
  update tasks t set status = 'cancelled', completed_at = p_now, wake_at = null, completion_note = coalesce(t.completion_note, r.why || ': closed by itself')
    from (select distinct on (task_id) * from app.dh_resolved_tasks()) r where r.task_id = t.id;
  get diagnostics n_res = row_count;
  -- the same To do twice
  update tasks t set status = 'cancelled', completed_at = p_now, wake_at = null, completion_note = coalesce(t.completion_note, 'Duplicate: closed by itself')
    from app.dh_duplicate_tasks_extra() d where d.task_id = t.id;
  get diagnostics n_dup = row_count;
  -- one booking's one problem: merged into the To do that ranks first
  with fam as (
    select t.id, first_value(t.id) over w keep_id, first_value(t.title) over w keep_title
      from tasks t join bookings b on b.id = t.booking_id
     where t.status in ('open', 'in_progress', 'waiting') and app.todo_family_rank(t.task_type, b.status::text) is not null
    window w as (partition by t.booking_id order by app.todo_family_rank(t.task_type, b.status::text), t.created_at))
  update tasks t set status = 'cancelled', completed_at = p_now, wake_at = null,
         completion_note = coalesce(t.completion_note, left('Merged into "' || f.keep_title || '"', 500))
    from fam f where f.id = t.id and f.id <> f.keep_id;
  get diagnostics n_merge = row_count;
  -- stale follow-ups
  update tasks t set status = 'cancelled', completed_at = p_now, wake_at = null,
         completion_note = coalesce(t.completion_note, 'Expired: nobody needed it after ' || app.todo_expires_after(t.task_type)::text)
   where t.status in ('open', 'waiting') and app.todo_expires_after(t.task_type) is not null
     and coalesce(t.due_at, t.created_at) < p_now - app.todo_expires_after(t.task_type);
  get diagnostics n_old = row_count;
  if n_res + n_dup + n_merge + n_old > 0 then
    perform app.heal_audit('todo_sweep', 'tasks', 'sweep', jsonb_build_object('done', n_res, 'duplicates', n_dup, 'merged', n_merge, 'expired', n_old));
  end if;
  return jsonb_strip_nulls(jsonb_build_object('done', nullif(n_res, 0), 'duplicates', nullif(n_dup, 0), 'merged', nullif(n_merge, 0), 'expired', nullif(n_old, 0)));
end $$;

insert into heal_actions (key, label, kind, description, sort) values
  ('todo_sweep', 'Sweep the To do''s', 'db', 'Every hour: To do''s whose subject is settled close, duplicates and one booking''s one problem merge, week-old follow-ups expire; each with its reason.', 45)
on conflict (key) do nothing;

-- ================================================================ 2. noise
-- Verify and test accounts are never warned or suspended for inactivity
create or replace function app.job_staff_inactivity(p_now timestamptz default now()) returns text
language plpgsql security definer set search_path = public, app, pg_temp as $$
declare
  s program_settings := app.settings();
  r record;
  n_warn integer := 0;
  n_lock integer := 0;
begin
  for r in select sp.user_id, greatest(app.staff_last_active(sp), coalesce(s.staff_inactive_grace_from, '-infinity')) last_at, sp.inactive_warned_at,
                  coalesce(u.full_name, u.email) name,
                  coalesce(nullif(btrim(u.greeting_name), ''), split_part(btrim(coalesce(u.full_name, '')), ' ', 1)) first_name
             from staff_profiles sp join users u on u.id = sp.user_id
            where sp.inactive_locked_at is null and app.staff_is_member(sp.user_id) and not app.user_is_admin(sp.user_id)
              and not coalesce(u.is_test, false) and not app.staff_is_test(sp.user_id) loop
    if r.last_at < p_now - make_interval(days => s.staff_inactive_lock_days) then
      update staff_profiles set inactive_locked_at = p_now, lock_reason = 'inactivity' where user_id = r.user_id;
      insert into audit_log (actor_user_id, action, entity_table, entity_id, after)
      values (null, 'staff_inactive_locked', 'staff_profiles', r.user_id::text, jsonb_build_object('last_active', r.last_at, 'days', s.staff_inactive_lock_days));
      perform app.staff_alert('staff_inactive_locked', 'user', r.user_id, 'locked:' || to_char(p_now, 'YYYYMMDD'),
        left(format('%s was suspended for inactivity', r.name), 140), format('No use of the portal since %s. They can ask for access back; Unlock on Staff restores them.', app.fmt_at(r.last_at)),
        jsonb_build_object('path_admin', '/admin/staff'));
      n_lock := n_lock + 1;
    elsif r.last_at < p_now - make_interval(days => s.staff_inactive_warn_days) and (r.inactive_warned_at is null or r.inactive_warned_at < r.last_at) then
      perform app.emit_event('staff_inactivity_warning', 'user', r.user_id, jsonb_build_object('recipient_user_id', r.user_id, 'first_name', coalesce(nullif(r.first_name, ''), 'there'),
        'days_idle', s.staff_inactive_warn_days::text, 'lock_days', s.staff_inactive_lock_days::text,
        'lock_on', to_char((r.last_at + make_interval(days => s.staff_inactive_lock_days)) at time zone 'America/Toronto', 'FMDay, FMMonth FMDD'),
        'sign_in_url', rtrim(s.notify_base_url, '/') || '/sign-in?next=/staff'), 'staff_inactivity_warning:' || r.user_id || ':' || to_char(r.last_at, 'YYYYMMDDHH24'));
      update staff_profiles set inactive_warned_at = p_now where user_id = r.user_id;
      n_warn := n_warn + 1;
    end if;
  end loop;
  return format('%s warned, %s suspended for inactivity', n_warn, n_lock);
end $$;

update staff_profiles sp set inactive_locked_at = null, lock_reason = null
  from users u
 where u.id = sp.user_id and sp.inactive_locked_at is not null and sp.lock_reason = 'inactivity'
   and (coalesce(u.is_test, false) or app.staff_is_test(sp.user_id));

-- a photo is stuck only when no worker holds its job now (the claim keeps the photo's first start time, so a retry
-- looked stuck an hour after the first try and was put back in the queue under the worker)
create function app.photo_job_stuck(p photo_jobs, p_now timestamptz) returns boolean
language sql stable set search_path = public, app, pg_temp as $$
  select p.status = 'processing' and p.started_at < p_now - interval '60 minutes'
     and not exists (select 1 from listing_jobs l where l.photo_job_id = p.id
                      and (l.status = 'queued' or (l.status = 'running' and l.locked_at >= p_now - interval '60 minutes')))
$$;

alter function app.heal_signals(timestamptz) rename to heal_signals_pre5102;
create function app.heal_signals(p_now timestamptz default now())
returns table (source text, key text, fingerprint text, title text, detail text, state text, path text, evidence jsonb)
language plpgsql stable security definer set search_path = public, app, pg_temp as $$
begin
  return query select * from app.heal_signals_pre5102(p_now) x where not (x.source = 'queue' and x.key = 'job_locks');
  -- the detail names each queue with its rows (5104: the bug reports said only "N rows")
  return query
    select 'queue'::text, 'job_locks'::text, 'queue:job_locks'::text, 'Jobs locked and left behind'::text,
           format('%s, the oldest since %s. Admin > Self-healing: /admin/self-healing',
                  string_agg(format('%s: %s', q.tbl, q.n), ', ' order by q.tbl), to_char(min(q.oldest) at time zone 'America/Toronto', 'Mon DD HH24:MI')),
           'stuck'::text, '/admin/self-healing'::text,
           jsonb_build_object('count', sum(q.n), 'oldest', min(q.oldest), 'queues', jsonb_object_agg(q.tbl, q.n))
      from (select l.tbl, count(*) n, min(l.t0) oldest from (
              select 'job_runs (scheduled jobs running over 2 hours)' tbl, started_at t0 from job_runs where status = 'running' and started_at < p_now - interval '2 hours'
              union all select 'pdf_jobs (documents)', locked_at from pdf_jobs where status = 'running' and locked_at < p_now - interval '15 minutes'
              union all select 'agreement_jobs (rental agreements)', locked_at from agreement_jobs where locked_at < p_now - interval '15 minutes'
              union all select 'photo_jobs (listing photos)', p.started_at from photo_jobs p where app.photo_job_stuck(p, p_now)) l group by l.tbl) q
    having count(*) > 0;
end $$;
select pg_temp.copy_grants('app.heal_signals(timestamptz)'::regprocedure, 'app.heal_signals_pre5102(timestamptz)'::regprocedure);

alter function app.heal_run_action(text, jsonb, heal_incidents, timestamptz) rename to heal_run_action_pre5102;
create function app.heal_run_action(p_action text, p_params jsonb, i heal_incidents, p_now timestamptz default now()) returns jsonb
language plpgsql security definer set search_path = public, app, pg_temp as $$
declare v_n integer; v_m integer; v_k integer; v_j integer;
begin
  if p_action = 'todo_sweep' then return app.job_todo_sweep(p_now); end if;
  if p_action <> 'release_locks' then return app.heal_run_action_pre5102(p_action, p_params, i, p_now); end if;
  -- 4800's release, with the photos judged by the worker's lock (a photo a worker holds now is never put back)
  update job_runs set status = 'failed', finished_at = p_now, error = coalesce(error, 'Left running over 2 hours: released by self-healing')
   where status = 'running' and started_at < p_now - interval '2 hours';
  get diagnostics v_n = row_count;
  update pdf_jobs set status = case when attempts >= max_attempts then 'failed' else 'queued' end, locked_at = null, locked_by = null, next_attempt_at = p_now,
         last_error = coalesce(last_error, 'Lock released by self-healing')
   where status = 'running' and locked_at < p_now - interval '15 minutes';
  get diagnostics v_m = row_count;
  update agreement_jobs set locked_at = null, locked_seq = null where locked_at < p_now - interval '15 minutes';
  get diagnostics v_k = row_count;
  update photo_jobs p set status = case when p.attempts >= 3 then 'failed' else 'queued' end, next_attempt_at = p_now,
         error = case when p.attempts >= 3 then coalesce(p.error, 'Stuck processing: released by self-healing') else p.error end
   where app.photo_job_stuck(p, p_now);
  get diagnostics v_j = row_count;
  delete from request_claims where expires_at < p_now - interval '1 hour';
  return jsonb_build_object('job_runs', v_n, 'pdf_jobs', v_m, 'agreement_jobs', v_k, 'photo_jobs', v_j);
end $$;
select pg_temp.copy_grants('app.heal_run_action(text, jsonb, heal_incidents, timestamptz)'::regprocedure, 'app.heal_run_action_pre5102(text, jsonb, heal_incidents, timestamptz)'::regprocedure);

-- an incident already escalated in the last 24 hours is not escalated again: no second To do, bug report or alert
alter function app.heal_escalate(uuid, text, timestamptz) rename to heal_escalate_pre5102;
create function app.heal_escalate(p_incident uuid, p_reason text, p_now timestamptz default now()) returns void
language plpgsql security definer set search_path = public, app, pg_temp as $$
declare
  i heal_incidents;
  e heal_incidents;
begin
  select * into i from heal_incidents where id = p_incident;
  if i.id is null or i.escalated_at is not null or i.status = 'healed' then return; end if;
  select * into e from heal_incidents h where h.fingerprint = i.fingerprint and h.id <> i.id and h.escalated_at > p_now - interval '24 hours'
   order by h.escalated_at desc limit 1;
  if e.id is not null then
    update heal_incidents set status = 'escalated', escalated_at = p_now, updated_at = p_now, todo_id = e.todo_id, bug_report_id = e.bug_report_id,
           escalation_reason = left(p_reason || format(' Already escalated as incident #%s: no new To do or alert.', e.number), 500)
     where id = i.id;
    perform app.heal_audit('heal_escalated_again', 'heal_incidents', i.id::text, jsonb_build_object('reason', p_reason, 'same_as', e.id));
    return;
  end if;
  perform app.heal_escalate_pre5102(p_incident, p_reason, p_now);
end $$;
select pg_temp.copy_grants('app.heal_escalate(uuid, text, timestamptz)'::regprocedure, 'app.heal_escalate_pre5102(uuid, text, timestamptz)'::regprocedure);

-- the photo retries the earlier rule released under their worker: put back the To do's and bug reports it filed
update tasks t set status = 'cancelled', completed_at = now(), wake_at = null,
       completion_note = coalesce(t.completion_note, 'Self-healing''s "Jobs locked" alarm was a retried photo, not a stuck job (5102): closed')
  from heal_incidents i
 where i.id = t.related_id and t.related_table = 'heal_incidents' and t.task_type = 'self_heal' and i.key = 'job_locks'
   and t.status in ('open', 'in_progress', 'waiting');

-- ================================================================ 3. decided from the data
-- a card hold past its expiry, with no processor to renew it: recorded as lapsed (it holds nothing; no money moves)
create function app.lapse_expired_holds(p_now timestamptz default now()) returns integer
language plpgsql security definer set search_path = public, app, pg_temp as $$
declare d record; n integer := 0;
begin
  for d in select x.id from deposits x where x.method = 'card_hold' and x.status = 'held' and x.hold_expires_at < p_now - interval '1 day' loop
    perform app.deposit_hold_lapsed(d.id, 'The card hold passed its expiry and no card processor renews it: recorded by the hourly sweep (5102)');
    perform app.heal_audit('deposit_hold_lapsed_auto', 'deposits', d.id::text, jsonb_build_object('at', p_now));
    n := n + 1;
  end loop;
  return n;
end $$;

-- a toll statement read whose every line passed its checks: confirmed as Finance would (Program settings
-- toll_read_min_confidence; toll_read_auto_charge decides the renters' charges, as for a person's confirm)
create function app.toll_reads_auto_confirm(p_now timestamptz default now()) returns integer
language plpgsql security definer set search_path = public, app, pg_temp as $$
declare r record; v_by uuid; n integer := 0;
begin
  for r in select x.id, x.created_by from toll_notice_reads x
            where x.status = 'in_review' and x.created_at < p_now - interval '30 minutes' and cardinality(coalesce(x.problems, '{}')) = 0 loop
    perform app.toll_read_line_refresh(l.id) from toll_notice_read_lines l where l.read_id = r.id and l.status in ('pending', 'checked');
    continue when exists (select 1 from toll_notice_read_lines l where l.read_id = r.id and l.status <> 'excluded'
                            and (cardinality(coalesce(l.problems, '{}')) > 0 or l.vehicle_id is null));
    continue when not exists (select 1 from toll_notice_read_lines l where l.read_id = r.id and l.status <> 'excluded');
    v_by := case when r.created_by is not null and app.user_runs_finance(r.created_by) then r.created_by else app.heal_reporter() end;
    continue when v_by is null;
    begin
      perform app.toll_read_confirm(v_by, jsonb_build_object('read', r.id));
      perform app.heal_audit('toll_read_auto_confirmed', 'toll_notice_reads', r.id::text, jsonb_build_object('as', v_by));
      n := n + 1;
    exception when others then
      raise warning 'toll read % not confirmed automatically: %', r.id, sqlerrm;
    end;
  end loop;
  return n;
end $$;

-- the hourly sweep runs both
create or replace function app.job_todo_sweep_all(p_now timestamptz default now()) returns jsonb
language plpgsql security definer set search_path = public, app, pg_temp as $$
begin
  return jsonb_strip_nulls(jsonb_build_object('holds_lapsed', nullif(app.lapse_expired_holds(p_now), 0), 'tolls_confirmed', nullif(app.toll_reads_auto_confirm(p_now), 0)))
         || app.job_todo_sweep(p_now);
end $$;

-- ================================================================ 4. return time and 5. new requests: told at once
insert into staff_alert_rules (rule, label, grp, who, tier, topic, wired, fixed, hint, sort, pref_type) values
  ('booking_return_soon', 'A car is due back in 30 minutes', 'Bookings', '{admin,on_duty:fleet}', 'normal', 'bookings', true, false,
   '5102: 30 minutes before the return time of a car that is out.', 56, 'staff_bookings'),
  ('booking_return_due', 'A car is due back now', 'Bookings', '{admin,on_duty:fleet}', 'urgent', 'bookings', true, false,
   '5102: at the return time of a car that is not back yet.', 56, 'staff_bookings'),
  ('booking_requested', 'New request to book', 'Bookings', '{admin,on_duty:cs,fn:sales}', 'urgent', 'bookings', true, false,
   '5102: the moment a request to book comes in (customer service answers first; Sales and Admin know at once).', 49, 'staff_bookings')
on conflict (rule) do nothing;

create function app.return_due_alerts(p_now timestamptz default now()) returns integer
language plpgsql security definer set search_path = public, app, pg_temp as $$
declare r record; n integer := 0; v_due boolean;
begin
  for r in select b.id, b.booking_number, b.return_at, app.vehicle_name(b.vehicle_id) car, rn.legal_name, rn.mobile
             from bookings b left join renters rn on rn.id = b.renter_id
            where b.status in ('on_rent', 'confirmed') and b.booking_type <> 'owner' and not coalesce(b.is_placeholder, false)
              and app.booking_is_out(b, p_now) and b.checked_in_at is null
              and b.return_at between p_now - interval '15 minutes' and p_now + interval '30 minutes'
              and not app.booking_is_test(b.id) loop
    v_due := r.return_at <= p_now;
    if app.staff_alert(case when v_due then 'booking_return_due' else 'booking_return_soon' end, 'booking', r.id,
         case when v_due then 'due:' else 'soon:' end || extract(epoch from r.return_at)::bigint,
         left(format('%s %s %s', r.booking_number, case when v_due then 'is due back now:' else 'is due back at' end, app.fmt_time(r.return_at)), 140),
         left(concat_ws('. ', r.car, nullif(btrim(coalesce(r.legal_name, '')), ''), case when nullif(btrim(coalesce(r.mobile, '')), '') is not null then 'call ' || r.mobile end), 240),
         jsonb_build_object('booking_id', r.id, 'path_admin', '/admin/bookings/' || r.booking_number, 'path_staff', '/staff/bookings/' || r.booking_number)) is not null then
      n := n + 1;
    end if;
  end loop;
  return n;
end $$;

alter function app.notify_booking_staff(timestamptz) rename to notify_booking_staff_pre5102;
create function app.notify_booking_staff(p_now timestamptz default now()) returns integer
language plpgsql security definer set search_path = public, app, pg_temp as $$
begin
  return app.notify_booking_staff_pre5102(p_now) + app.return_due_alerts(p_now);
end $$;
select pg_temp.copy_grants('app.notify_booking_staff(timestamptz)'::regprocedure, 'app.notify_booking_staff_pre5102(timestamptz)'::regprocedure);

create function app.booking_requested_alert() returns trigger
language plpgsql security definer set search_path = public, app, pg_temp as $$
begin
  if new.status::text <> 'requested' or coalesce(new.is_placeholder, false) then return null; end if;
  if tg_op = 'UPDATE' and old.status::text = 'requested' then return null; end if;
  if app.booking_is_test(new.id) then return null; end if;
  begin
    perform app.staff_alert('booking_requested', 'booking', new.id, 'requested',
      left(format('New request %s: %s, %s', new.booking_number, app.vehicle_name(new.vehicle_id), app.fmt_time(new.pickup_at)), 140),
      left(coalesce((select legal_name from renters where id = new.renter_id), ''), 240),
      jsonb_build_object('booking_id', new.id, 'path_admin', '/admin/bookings/' || new.booking_number, 'path_staff', '/staff/bookings/' || new.booking_number));
  exception when others then raise warning 'request alert not sent for %: %', new.booking_number, sqlerrm;
  end;
  return null;
end $$;
create trigger bookings_requested_alert after insert or update of status on bookings
  for each row execute function app.booking_requested_alert();

-- ================================================================ grants and the schedule
do $$
declare f record;
begin
  for f in select p.oid::regprocedure as sig from pg_proc p join pg_namespace n on n.oid = p.pronamespace
            where n.nspname = 'app' and p.proname = any (array['dh_resolved_tasks', 'dh_resolved_tasks_pre5102', 'todo_family_rank', 'todo_expires_after', 'job_todo_sweep',
              'job_todo_sweep_all', 'job_staff_inactivity', 'photo_job_stuck', 'heal_signals', 'heal_signals_pre5102', 'heal_run_action', 'heal_run_action_pre5102',
              'heal_escalate', 'heal_escalate_pre5102', 'lapse_expired_holds', 'toll_reads_auto_confirm', 'return_due_alerts', 'notify_booking_staff',
              'notify_booking_staff_pre5102', 'booking_requested_alert']) loop
    execute format('revoke all on function %s from public, anon, authenticated', f.sig);
    execute format('grant execute on function %s to service_role', f.sig);
  end loop;
end $$;

do $$
begin
  if not exists (select 1 from pg_available_extensions where name = 'pg_cron') then
    raise notice 'pg_cron is not available here: the To do sweep is not scheduled';
    return;
  end if;
  begin
    create extension if not exists pg_cron;
  exception when others then
    raise warning 'pg_cron could not be created in this database (%): the To do sweep is not scheduled', sqlerrm;
    return;
  end;
  perform cron.schedule('carmacars-todo-sweep', '17 * * * *', $q$select app.job_todo_sweep_all()$q$);
end $$;
