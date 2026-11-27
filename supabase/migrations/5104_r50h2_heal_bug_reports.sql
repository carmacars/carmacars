-- 5104 (R50 hotfix 2, the owner on Nov 27: "lots of bug reports"). 172 of the 175 open bug reports were filed by
-- self-healing for one problem, "Jobs locked and left behind" (the queue source, about one every 15 minutes from Nov 25
-- 16:43): a retried listing photo that looked stuck (the cause is fixed in 5102, app.photo_job_stuck). Each new incident
-- of the same problem filed its own report and never closed it. SCHEMA_MARKER is not changed.
-- 1. One open report for each distinct problem (the incident's fingerprint): a new incident of the same problem joins it,
--    and the report counts the times and keeps the last time seen, with no new To do or alert.
-- 2. A report self-healing filed closes by itself (fixed) once none of its incidents is open or escalated for an hour.
-- 3. The open duplicates are closed now (wont_fix, "Duplicate of BR-n"), one kept for each problem; each change is in
--    the audit log.

create function pg_temp.copy_grants(p_new regprocedure, p_old regprocedure) returns void
language plpgsql as $$
declare g text;
begin
  execute format('revoke all on function %s from public, anon, authenticated', p_new);
  foreach g in array array['anon', 'authenticated', 'service_role'] loop
    if has_function_privilege(g, p_old, 'execute') then execute format('grant execute on function %s to %I', p_new, g); end if;
  end loop;
end $$;

-- the open report self-healing filed for this problem, if any
create function app.heal_open_report(p_fingerprint text) returns bug_reports
language sql stable security definer set search_path = public, app, pg_temp as $$
  select r.* from bug_reports r join heal_incidents h on h.bug_report_id = r.id
   where h.fingerprint = p_fingerprint and r.status in ('new', 'triaged') and r.context ->> 'filed_by' = 'self-healing'
   order by r.created_at desc limit 1
$$;

alter function app.heal_escalate(uuid, text, timestamptz) rename to heal_escalate_pre5104;
create function app.heal_escalate(p_incident uuid, p_reason text, p_now timestamptz default now()) returns void
language plpgsql security definer set search_path = public, app, pg_temp as $$
declare
  i heal_incidents;
  r bug_reports;
begin
  select * into i from heal_incidents where id = p_incident;
  if i.id is null or i.escalated_at is not null or i.status = 'healed' then return; end if;
  r := app.heal_open_report(i.fingerprint);
  if r.id is null then perform app.heal_escalate_pre5104(p_incident, p_reason, p_now); return; end if;
  -- the same problem again: the open report counts it; no second report, To do or alert
  update bug_reports set context = context || jsonb_build_object('times', coalesce((context ->> 'times')::integer, 1) + 1, 'last_seen', p_now, 'last_incident', i.number),
         updated_at = p_now
   where id = r.id;
  update heal_incidents set status = 'escalated', escalated_at = p_now, updated_at = p_now, bug_report_id = r.id,
         todo_id = (select h.todo_id from heal_incidents h where h.bug_report_id = r.id and h.todo_id is not null order by h.escalated_at limit 1),
         escalation_reason = left(p_reason || format(' Counted on the open bug report BR-%s.', r.number), 500)
   where id = i.id;
  perform app.heal_audit('heal_escalated_counted', 'heal_incidents', i.id::text, jsonb_build_object('reason', p_reason, 'bug_report', r.id));
end $$;
select pg_temp.copy_grants('app.heal_escalate(uuid, text, timestamptz)'::regprocedure, 'app.heal_escalate_pre5104(uuid, text, timestamptz)'::regprocedure);

-- a report self-healing filed closes once its problem has been gone an hour
create function app.heal_close_reports(p_now timestamptz default now()) returns integer
language plpgsql security definer set search_path = public, app, pg_temp as $$
declare n integer;
begin
  with done as (
    update bug_reports r set status = 'fixed', status_changed_at = p_now, fixed_in = 'self-healing',
           admin_notes = left(concat_ws(E'\n', nullif(r.admin_notes, ''), format('Closed by itself on %s: the problem has been gone an hour.', to_char(p_now at time zone 'America/Toronto', 'Mon DD HH24:MI'))), 8000)
     where r.status in ('new', 'triaged') and r.context ->> 'filed_by' = 'self-healing'
       and exists (select 1 from heal_incidents h where h.bug_report_id = r.id)
       and not exists (select 1 from heal_incidents h where h.bug_report_id = r.id and (h.status in ('open', 'healing', 'escalated') or h.last_seen > p_now - interval '1 hour'))
    returning r.id)
  select count(*) into n from done;
  if n > 0 then perform app.heal_audit('heal_reports_closed', 'bug_reports', 'sweep', jsonb_build_object('closed', n)); end if;
  return n;
end $$;

-- the hourly sweep (5102) closes them too
create or replace function app.job_todo_sweep_all(p_now timestamptz default now()) returns jsonb
language plpgsql security definer set search_path = public, app, pg_temp as $$
begin
  return jsonb_strip_nulls(jsonb_build_object('holds_lapsed', nullif(app.lapse_expired_holds(p_now), 0), 'tolls_confirmed', nullif(app.toll_reads_auto_confirm(p_now), 0),
                                              'reports_closed', nullif(app.heal_close_reports(p_now), 0)))
         || app.job_todo_sweep(p_now);
end $$;

-- the open duplicates now: one report kept for each problem (the newest), the rest closed and logged
with filed as (
  select r.id, r.number, coalesce(r.context ->> 'source', '') || ':' || coalesce(r.context ->> 'key', '') problem, r.created_at
    from bug_reports r
   where r.status in ('new', 'triaged') and r.context ->> 'filed_by' = 'self-healing'),
ranked as (
  select f.*, first_value(f.id) over w keep_id, first_value(f.number) over w keep_number, count(*) over (partition by f.problem) times
    from filed f window w as (partition by f.problem order by f.created_at desc)),
kept as (
  update bug_reports r set context = r.context || jsonb_build_object('times', k.times), updated_at = now()
    from ranked k where k.id = r.id and k.id = k.keep_id and k.times > 1
  returning r.id),
closed as (
  update bug_reports r set status = 'wont_fix', status_changed_at = now(),
         admin_notes = left(concat_ws(E'\n', nullif(r.admin_notes, ''), format('Duplicate of BR-%s (the same self-healing problem): closed by 5104.', k.keep_number)), 8000)
    from ranked k where k.id = r.id and k.id <> k.keep_id
  returning r.id, k.keep_id)
insert into audit_log (action, entity_table, entity_id, after)
select 'bug_report_duplicate_closed', 'bug_reports', c.id::text, jsonb_build_object('kept', c.keep_id, 'by', '5104') from closed c;

-- the kept job-locks report closes on the next sweep once the problem stays gone (5102 fixed its cause)
select app.heal_close_reports(now());

do $$
declare f record;
begin
  for f in select p.oid::regprocedure as sig from pg_proc p join pg_namespace n on n.oid = p.pronamespace
            where n.nspname = 'app' and p.proname = any (array['heal_open_report', 'heal_escalate', 'heal_escalate_pre5104', 'heal_close_reports', 'job_todo_sweep_all']) loop
    execute format('revoke all on function %s from public, anon, authenticated', f.sig);
    execute format('grant execute on function %s to service_role', f.sig);
  end loop;
end $$;
