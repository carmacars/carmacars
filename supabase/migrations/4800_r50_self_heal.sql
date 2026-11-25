-- 4800_r50_self_heal.sql
-- Release 50 (docs/changes/2026-11-25-r50-self-heal.md): the site heals itself. The owner, November 25: "Not just find problems
-- but also create a database of all fixes and find the relevant fixes and apply them automatically. Self healing. The site does it
-- itself, not Claude on a schedule."
--   1. The fix library: heal_playbooks (a signature: the source, a rule on the key, the message and the state; one action of
--      the fixed whitelist heal_actions with its params; max attempts, cooldown, the wait before the check, enabled, the running
--      success and failure counts). heal_incidents (one open problem by its fingerprint: first and last seen, open, healing,
--      healed or escalated), heal_attempts (each playbook run: when, the result, whether the check after it found the problem
--      gone, the details). Every change is written to audit_log.
--   2. The engine: app.job_heal() every minute (pg_cron 'carmacars-heal'). It opens and updates incidents from the failing site
--      checks, the data health checks the database fixes itself, error spikes in client_errors, Search Console errors, failed
--      pg_cron runs, stuck outboxes and job locks, failing calendar feeds and what the server's heal agent reports. It runs the
--      matching playbook with the best success rate, checks on a later tick that the problem cleared, tries the next playbook
--      when it did not, and after the attempts escalates once: one Admin alert, one To do and one staff bug report with the
--      evidence. A playbook that keeps failing switches itself off and escalates (the circuit breaker).
--   3. The actions are idempotent and reversible only. Money (payments, deposits, payouts, refunds, statements, invoices,
--      charges, a booking's money fields) is never touched: an incident about money is escalated at once, with no attempt.
--      The site cannot rewrite its own code: for a code bug it mitigates (a retry, a restart, the previous build, a redirect)
--      and files the bug report with the evidence.
--   4. Server actions (restart the site, Caddy or the media server, renew certificates, free disk space, end idle database
--      connections, go back to the previous build) are queued in heal_requests for the heal agent on the server
--      (infra/vps/bin/heal-agent, a systemd timer), which reads them as the narrow role heal_agent and writes the result back.
--   5. Admin > Self-healing (door: admin_read heal_status; ops_do heal_playbook_toggle, heal_resolve, heal_save_fix) and the
--      connector's read tool heal_status (admin:read, wrapped: api_call_pre4800).
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

-- ================================================================ 1. the tables
create table heal_settings (
  id                         boolean primary key default true check (id),
  enabled                    boolean not null default true,
  error_spike_count          integer not null default 12 check (error_spike_count between 2 and 10000),
  error_window_minutes       integer not null default 15 check (error_window_minutes between 5 and 240),
  max_attempts_per_incident  integer not null default 4 check (max_attempts_per_incident between 1 and 20),
  breaker_failures           integer not null default 4 check (breaker_failures between 2 and 50),
  rollback_window_minutes    integer not null default 30 check (rollback_window_minutes between 5 and 240),
  agent_answer_minutes       integer not null default 10 check (agent_answer_minutes between 2 and 120),
  max_new_per_tick           integer not null default 20 check (max_new_per_tick between 1 and 200),
  updated_at                 timestamptz not null default now()
);
insert into heal_settings default values;
comment on table heal_settings is 'Self-healing (4800): the engine''s switches and limits (one row).';

-- the whitelist: every action the engine may run. kind db runs in app.heal_run_action; kind server is queued for the agent.
create table heal_actions (
  key          text primary key check (key ~ '^[a-z][a-z0-9_]{2,40}$'),
  label        text not null,
  kind         text not null check (kind in ('db', 'server')),
  description  text not null,
  sort         integer not null default 100
);
insert into heal_actions (key, label, kind, description, sort) values
  ('rerun_cron', 'Run the failed scheduled job again', 'db', 'Runs the failed pg_cron job''s own command again, once (only a "select app.job_...()" command; never a money job).', 10),
  ('requeue_outbox', 'Send stuck messages again', 'db', 'Emails, texts and push notices stuck "sending" over 15 minutes go back to the queue, at most 5 attempts each; past that they are marked failed with the reason.', 20),
  ('release_locks', 'Release stale locks', 'db', 'Job runs left "running" over 2 hours are marked failed; document, agreement and photo jobs locked over 15 minutes (photos: 60) go back to their queue within their retry limit; request claims expired over an hour are removed.', 30),
  ('data_health_autofix', 'Run the data health fixes', 'db', 'The fixes Data health makes without asking (test accounts off real work, duplicate and settled tasks), then a fresh check.', 40),
  ('booking_recovery', 'Run the booking recovery job', 'db', 'The booking recovery job (stopped reminders, reminders due), as its schedule runs it.', 50),
  ('calendar_resync', 'Sync the calendar feed again', 'db', 'The failing calendar feeds are read again on the next sync, without waiting for their interval.', 60),
  ('uptime_recheck', 'Check the site again', 'db', 'The site check runs again at once (a single failed check is often a passing hiccup).', 70),
  ('resync_sequences', 'Repair id counters', 'db', 'A table''s id counter left behind its highest id (after a restore or a copy every insert failed with a duplicate key) is moved past it. Never lowers a counter.', 80),
  ('gsc_redirect', 'Redirect a missing car page', 'db', 'A /cars/ page Google reports as 404 or soft 404 gets a 301 to the closest live car (else /cars), and the page is sent to the search engines again (IndexNow) and inspected again.', 90),
  ('restart_web', 'Restart the website', 'server', 'The heal agent restarts the website container and waits for it to be healthy.', 110),
  ('restart_caddy', 'Restart Caddy', 'server', 'The heal agent reloads Caddy (the web server in front), and restarts it if the reload fails.', 120),
  ('restart_livekit', 'Restart the media server', 'server', 'The heal agent restarts the media server of the calls in the site.', 130),
  ('renew_certs', 'Renew certificates', 'server', 'The heal agent asks Caddy to load and renew its certificates, and refreshes the media server''s.', 140),
  ('free_disk', 'Free disk space', 'server', 'The heal agent trims the system journal, old Docker images and build cache and rotated logs. Never the database, backups or uploaded files.', 150),
  ('reset_db_connections', 'End idle database connections', 'server', 'The heal agent ends database connections idle in a transaction over 10 minutes (never an active query).', 160),
  ('rollback_web', 'Go back to the previous build', 'server', 'The heal agent starts the build that ran before the last deploy (kept on the server). Always escalated after, so the bad build is looked at.', 170);
comment on table heal_actions is 'Self-healing (4800): the whitelist of actions. Nothing outside it ever runs; none touches money.';

create table heal_playbooks (
  id                    uuid primary key default gen_random_uuid(),
  key                   text not null unique check (key ~ '^[a-z0-9][a-z0-9_.-]{2,80}$'),
  title                 text not null check (char_length(title) between 3 and 200),
  source                text not null check (source in ('uptime', 'data_health', 'site_error', 'gsc', 'cron', 'queue', 'server')),
  match_key             text check (match_key is null or char_length(match_key) <= 300),
  match_pattern         text check (match_pattern is null or char_length(match_pattern) <= 300),
  match_state           text check (match_state is null or char_length(match_state) <= 100),
  action                text not null references heal_actions (key),
  params                jsonb not null default '{}'::jsonb check (jsonb_typeof(params) = 'object'),
  priority              integer not null default 100,
  max_attempts          integer not null default 1 check (max_attempts between 1 and 10),
  cooldown_minutes      integer not null default 10 check (cooldown_minutes between 0 and 1440),
  verify_minutes        integer not null default 2 check (verify_minutes between 1 and 240),
  enabled               boolean not null default true,
  successes             integer not null default 0,
  failures              integer not null default 0,
  consecutive_failures  integer not null default 0,
  last_run_at           timestamptz,
  disabled_at           timestamptz,
  disabled_reason       text,
  builtin               boolean not null default false,
  learned_from          text,
  created_by            uuid references users (id) on delete set null,
  from_incident         uuid,
  created_at            timestamptz not null default now(),
  updated_at            timestamptz not null default now()
);
comment on table heal_playbooks is 'Self-healing (4800): the fix library. A signature (source, match_key and match_pattern as regular expressions, match_state exact) and one whitelisted action.';

create table heal_incidents (
  id                uuid primary key default gen_random_uuid(),
  number            bigint generated always as identity unique,
  fingerprint       text not null check (char_length(fingerprint) <= 400),
  source            text not null check (source in ('uptime', 'data_health', 'site_error', 'gsc', 'cron', 'queue', 'server')),
  key               text not null,
  title             text not null,
  detail            text,
  state             text,
  path              text,
  evidence          jsonb not null default '{}'::jsonb,
  money             boolean not null default false,
  status            text not null default 'open' check (status in ('open', 'healing', 'healed', 'escalated')),
  first_seen        timestamptz not null default now(),
  last_seen         timestamptz not null default now(),
  seen_count        integer not null default 1,
  attempts          integer not null default 0,
  next_try_at       timestamptz not null default now(),
  healed_at         timestamptz,
  healed_by         text check (healed_by is null or healed_by in ('playbook', 'itself', 'staff')),
  escalated_at      timestamptz,
  escalation_reason text,
  todo_id           uuid,
  bug_report_id     uuid,
  resolved_by       uuid references users (id) on delete set null,
  resolution_note   text,
  saved_playbook_id uuid references heal_playbooks (id) on delete set null,
  keep_open         boolean not null default false,
  updated_at        timestamptz not null default now(),
  check ((status = 'healed') = (healed_at is not null)),
  check (status <> 'escalated' or escalated_at is not null)
);
-- one unresolved incident per fingerprint
create unique index heal_incidents_open_uq on heal_incidents (fingerprint) where status <> 'healed';
create index heal_incidents_status_idx on heal_incidents (status, last_seen desc);
create index heal_incidents_fp_idx on heal_incidents (fingerprint, healed_at desc);
comment on table heal_incidents is 'Self-healing (4800): one problem the engine saw, from first to last seen, until healed (by a playbook, by itself or by staff) or escalated.';

create table heal_attempts (
  id            uuid primary key default gen_random_uuid(),
  incident_id   uuid not null references heal_incidents (id) on delete cascade,
  playbook_id   uuid references heal_playbooks (id) on delete set null,
  action        text not null references heal_actions (key),
  params        jsonb not null default '{}'::jsonb,
  started_at    timestamptz not null default now(),
  result        text not null check (result in ('ok', 'error', 'queued', 'refused')),
  verified      boolean,
  verified_at   timestamptz,
  check_after   timestamptz,
  details       jsonb not null default '{}'::jsonb
);
create index heal_attempts_incident_idx on heal_attempts (incident_id, started_at desc);
create index heal_attempts_pending_idx on heal_attempts (check_after) where verified is null;
comment on table heal_attempts is 'Self-healing (4800): each playbook run on an incident, its result and whether the check after it found the problem gone.';

-- the heal agent's queue (server actions)
create table heal_requests (
  id           bigint generated always as identity primary key,
  attempt_id   uuid references heal_attempts (id) on delete set null,
  action       text not null references heal_actions (key),
  params       jsonb not null default '{}'::jsonb,
  status       text not null default 'pending' check (status in ('pending', 'claimed', 'done', 'failed', 'expired')),
  created_at   timestamptz not null default now(),
  claimed_at   timestamptz,
  finished_at  timestamptz,
  ok           boolean,
  result       text
);
create index heal_requests_pending_idx on heal_requests (status, created_at) where status in ('pending', 'claimed');
comment on table heal_requests is 'Self-healing (4800): server actions waiting for the heal agent (infra/vps/bin/heal-agent) and what it answered.';

-- what the heal agent last reported about the server
create table heal_server_state (
  id             boolean primary key default true check (id),
  reported_at    timestamptz,
  web_tag        text,
  previous_tag   text,
  deployed_at    timestamptz,
  web_health     text,
  disk_pct       integer,
  cert_days      integer,
  problems       jsonb not null default '[]'::jsonb,
  local_actions  jsonb not null default '[]'::jsonb
);
insert into heal_server_state default values;
-- every foreign key has its index (99_r35sec)
create index heal_playbooks_action_idx on heal_playbooks (action);
create index heal_playbooks_created_by_idx on heal_playbooks (created_by);
create index heal_incidents_resolved_by_idx on heal_incidents (resolved_by);
create index heal_incidents_saved_playbook_idx on heal_incidents (saved_playbook_id);
create index heal_attempts_playbook_idx on heal_attempts (playbook_id);
create index heal_attempts_action_idx on heal_attempts (action);
create index heal_requests_attempt_idx on heal_requests (attempt_id);
create index heal_requests_action_idx on heal_requests (action);
comment on table heal_server_state is 'Self-healing (4800): the server as the heal agent last saw it (the build, the last deploy, health, disk, certificates).';

do $$
declare t text;
begin
  foreach t in array array['heal_settings', 'heal_actions', 'heal_playbooks', 'heal_incidents', 'heal_attempts', 'heal_requests', 'heal_server_state'] loop
    execute format('alter table %I enable row level security', t);
    -- Admins read; every write goes through the functions below (only select is granted)
    execute format('create policy admin_all on %I for all to authenticated using (app.is_admin()) with check (app.is_admin())', t);
    execute format('revoke all on %I from anon, authenticated', t);
    execute format('grant select on %I to authenticated', t);
    execute format('grant all on %I to service_role', t);
  end loop;
  -- the library and the switches are audited row by row; incidents, attempts and the agent's queue change every minute and
  -- are written to audit_log by the functions at each step (app.heal_audit), the agent's last report is not (state only)
  foreach t in array array['heal_settings', 'heal_actions', 'heal_playbooks'] loop
    execute format('create trigger audit_%s after insert or update or delete on %I for each row execute function app.audit_row()', t, t);
  end loop;
end $$;

-- ================================================================ 2. the alert rules (the staff alert framework, 0462)
insert into staff_alert_rules (rule, label, grp, who, tier, topic, wired, fixed, hint, sort) values
  ('self_heal_escalated', 'The site could not fix a problem by itself', 'System', '{admin}', 'urgent', 'alerts', true, false,
   'Self-healing (4800): an incident its playbooks did not clear, or one about money. One alert per incident, with a To do and a bug report.', 168),
  ('self_heal_breaker', 'A self-healing fix keeps failing and switched itself off', 'System', '{admin}', 'urgent', 'alerts', true, false,
   'Self-healing (4800): the circuit breaker turned a playbook off after it failed several times in a row.', 169)
on conflict (rule) do nothing;

-- the two notices open Admin > Self-healing (a list, path_admin in the notice), not one record's page (99_r48_alert_targets)
alter function app.alert_entity_kind(text) rename to alert_entity_kind_pre4800;
create function app.alert_entity_kind(p_entity text) returns text
language sql immutable set search_path = public, app, pg_temp as $$
  select case when p_entity in ('heal_incident', 'heal_playbook') then 'list' else app.alert_entity_kind_pre4800(p_entity) end
$$;
select pg_temp.copy_grants('app.alert_entity_kind(text)'::regprocedure, 'app.alert_entity_kind_pre4800(text)'::regprocedure);

-- ================================================================ 3. helpers
-- money is never fixed automatically: payments, deposits, payouts, refunds, statements, invoices, charges, commissions
create function app.heal_is_money(p_source text, p_key text, p_detail text) returns boolean
language sql immutable set search_path = public, app, pg_temp as $$
  select (p_source = 'uptime' and p_key = 'stripe')
      or (p_source = 'data_health' and p_key in ('dead_with_money', 'deposit_without_money', 'deposits_overdue', 'unmatched_payments', 'owners_terms', 'never_closed', 'pickup_not_recorded'))
      or coalesce(p_key, '') ~* '(payment|deposit|payout|refund|charge|capture|stripe|helcim|invoice|statement|commission|reconcil|accrue|debit|bank|gift.?card|finance|money|payroll|reimburs|reward|perk|toll|etransfer)'
      or (p_source = 'cron' and coalesce(p_detail, '') ~* '(payment|deposit|payout|refund|charge|capture|invoice|statement|commission|reconcil)')
$$;

create function app.heal_audit(p_action text, p_table text, p_id text, p_after jsonb, p_by uuid default null) returns void
language sql security definer set search_path = public, app, pg_temp as $$
  insert into audit_log (actor_user_id, action, entity_table, entity_id, after) values (p_by, p_action, p_table, p_id, p_after)
$$;

-- the first active Admin (not a test account): the reporter of the bug reports the engine files
create function app.heal_reporter() returns uuid
language sql stable security definer set search_path = public, app, pg_temp as $$
  select u.id from users u join user_roles r on r.user_id = u.id and r.role = 'admin'
   where u.status = 'active' and not coalesce(u.is_test, false) order by u.created_at limit 1
$$;

-- ================================================================ 4. the signals: every problem now, one row each
create function app.heal_signals(p_now timestamptz default now())
returns table (source text, key text, fingerprint text, title text, detail text, state text, path text, evidence jsonb)
language plpgsql security definer set search_path = public, app, pg_temp as $$
#variable_conflict use_column
declare
  s heal_settings;
  ss heal_server_state;
  r record;
  v_page text;
begin
  select * into s from heal_settings;
  select * into ss from heal_server_state;
  -- uptime: a page or service failing two checks in a row (emails, jobs and texts come from the queue and cron sources)
  return query
    select 'uptime'::text, c.key, 'uptime:' || c.key, 'Site check failing: ' || c.label, left(app.redact_text(c.last_detail), 500), 'failing'::text, c.path,
           jsonb_build_object('http', c.last_http, 'ms', c.last_ms, 'since', c.failing_since, 'failures', c.consecutive_failures, 'advice', c.advice)
      from uptime_checks c
     where c.enabled and c.status = 'failing' and coalesce(c.consecutive_failures, 0) >= 2 and c.key not in ('jobs', 'email', 'sms_signin', 'email_cap');
  -- data health: the checks the database fixes by itself, still not clear in the last run (the others are people's work,
  -- on the Data health card)
  return query
    select 'data_health'::text, c ->> 'key', 'data_health:' || (c ->> 'key'), 'Data health: ' || coalesce(c ->> 'title', c ->> 'key'),
           left(app.redact_text(c ->> 'line'), 500), 'open'::text, c ->> 'href', jsonb_build_object('count', (c ->> 'count')::integer, 'run_at', d.ran_at)
      from (select * from data_health_runs order by ran_at desc limit 1) d, jsonb_array_elements(coalesce(d.checks, '[]'::jsonb)) c
     where coalesce((c ->> 'count')::integer, 0) > 0 and c ->> 'key' in ('test_accounts', 'duplicate_tasks', 'resolved_tasks');
  -- error spikes: real errors (the server's, and crashes in the browser) on one page in the window
  return query
    with e as (
      select regexp_replace(split_part(x.path, '?', 1), '/([0-9a-fA-F-]{36}|[A-Za-z]{1,4}-[0-9]{3,}|[0-9]{3,}|[A-Za-z0-9_-]{20,})(?=/|$)', '/:id', 'g') pg,
             x.kind, x.message, x.digest, x.created_at
        from client_errors x where x.created_at > p_now - make_interval(mins => s.error_window_minutes) and x.kind in ('server', 'crash'))
    select 'site_error'::text, e.pg, 'site_error:' || e.pg, format('Error spike on %s', e.pg),
           left(app.redact_text((array_agg(e.message order by e.created_at desc))[1]), 500),
           case when bool_or(e.kind = 'server') then 'server' else 'crash' end, e.pg,
           jsonb_build_object('count', count(*), 'window_minutes', s.error_window_minutes, 'kinds', to_jsonb(array_agg(distinct e.kind)),
             'messages', (select jsonb_agg(m) from (select distinct left(app.redact_text(y.message), 200) m from e y where y.pg = e.pg limit 5) mm),
             'digest', (array_agg(e.digest order by e.created_at desc) filter (where e.digest is not null))[1])
      from e group by e.pg having count(*) >= s.error_spike_count;
  -- right after a deploy: server errors well above the hour before it (the agent goes back to the previous build)
  if ss.deployed_at is not null and ss.deployed_at > p_now - make_interval(mins => s.rollback_window_minutes) and ss.previous_tag is not null then
    return query
      select 'server'::text, 'deploy_errors'::text, 'server:deploy_errors:' || coalesce(ss.web_tag, '?'), format('Errors after the deploy of %s', coalesce(ss.web_tag, 'the new build')),
             format('%s server errors since the deploy at %s (%s in the hour before)', n_after, to_char(ss.deployed_at at time zone 'America/Toronto', 'HH24:MI'), n_before),
             'spike'::text, null::text, jsonb_build_object('after', n_after, 'before', n_before, 'tag', ss.web_tag, 'previous', ss.previous_tag)
        from (select count(*) filter (where x.created_at >= ss.deployed_at) n_after,
                     count(*) filter (where x.created_at < ss.deployed_at and x.created_at >= ss.deployed_at - interval '1 hour') n_before
                from client_errors x where x.kind = 'server' and x.created_at >= ss.deployed_at - interval '1 hour') q
       where n_after >= s.error_spike_count and n_after > 3 * n_before;
  end if;
  -- Search Console: pages Google reports missing that have no redirect yet, one incident for car pages, one for the others
  return query
    select 'gsc'::text, g.k, 'gsc:' || g.k || ':' || g.st,
           format('Google reports %s (%s)', g.st, case g.k when 'car_page' then 'car pages' else 'other pages' end),
           format('%s pages, for example %s', count(*), min(g.path)), g.st, min(g.path),
           jsonb_build_object('count', count(*), 'paths', (array_agg(g.path order by g.inspected_at desc))[1:50])
      from (select case when x.path like '/cars/%' then 'car_page' else 'other_page' end k, lower(x.state) st, x.path, x.inspected_at
              from app.gsc_url_inspection x
             where x.state ~* '(not found|404|soft 404)' and x.inspected_at > p_now - interval '30 days'
               and not exists (select 1 from listing_redirects lr where lr.from_path = lower(rtrim(x.path, '/')))) g
     group by g.k, g.st;
  return query
    select 'gsc'::text, 'server_error', 'gsc:server_error', 'Google reports server errors (5xx)', format('%s pages, for example %s', count(*), min(g.path)),
           '5xx'::text, min(g.path), jsonb_build_object('count', count(*), 'paths', (array_agg(g.path order by g.inspected_at desc))[1:50])
      from app.gsc_url_inspection g
     where g.state ~* '(5xx|server error)' and g.inspected_at > p_now - interval '3 days' having count(*) > 0;
  -- pg_cron: a job whose latest run failed (a start-up timeout followed by a good run is not one)
  if to_regclass('cron.job_run_details') is not null and to_regclass('cron.job') is not null then
    begin
      for r in execute $q$
        select j.jobname, j.command, d.return_message, d.start_time,
               (select count(*) from cron.job_run_details f where f.jobid = j.jobid and f.status = 'failed' and f.start_time > $1 - interval '24 hours') fails
          from cron.job j
          join lateral (select * from cron.job_run_details x where x.jobid = j.jobid and x.status in ('succeeded', 'failed') order by x.start_time desc limit 1) d on true
         where d.status = 'failed' and d.start_time > $1 - interval '2 hours' and j.jobname is not null and j.jobname <> 'carmacars-heal'
           and coalesce(d.return_message, '') !~* 'startup timeout'$q$ using p_now loop
        source := 'cron'; key := r.jobname; fingerprint := 'cron:' || r.jobname; title := 'Scheduled job failed: ' || r.jobname;
        detail := left(app.redact_text(r.return_message), 500); state := 'failed'; path := null;
        evidence := jsonb_build_object('command', left(r.command, 300), 'at', r.start_time, 'failures_24h', r.fails);
        return next;
      end loop;
    exception when others then null;
    end;
  end if;
  -- queues: messages stuck "sending", messages queued an hour past due, job locks left behind
  return query
    select 'queue'::text, q.k, 'queue:' || q.k, q.t, format('%s rows, the oldest since %s', q.n, to_char(q.oldest at time zone 'America/Toronto', 'Mon DD HH24:MI')),
           q.st, null::text, jsonb_build_object('count', q.n, 'oldest', q.oldest)
      from (
        select 'notification_outbox' k, 'Emails stuck sending' t, 'stuck' st, count(*) n, min(locked_at) oldest from notification_outbox where status = 'sending' and locked_at < p_now - interval '15 minutes'
        union all select 'phone_outbox', 'Texts stuck sending', 'stuck', count(*), min(locked_at) from phone_outbox where status = 'sending' and locked_at < p_now - interval '15 minutes'
        union all select 'push_outbox', 'Push notices stuck sending', 'stuck', count(*), min(locked_at) from push_outbox where status = 'sending' and locked_at < p_now - interval '15 minutes'
        union all select 'notification_outbox_backlog', 'Emails not going out', 'backlog', count(*), min(send_after) from notification_outbox
                   where status = 'queued' and send_after < p_now - interval '60 minutes' and created_at > p_now - interval '2 days'
        union all select 'phone_outbox_backlog', 'Texts not going out', 'backlog', count(*), min(send_after) from phone_outbox
                   where status = 'queued' and send_after < p_now - interval '60 minutes' and created_at > p_now - interval '2 days'
        union all select 'job_locks', 'Jobs locked and left behind', 'stuck', count(*), min(t0) from (
                   select started_at t0 from job_runs where status = 'running' and started_at < p_now - interval '2 hours'
                   union all select locked_at from pdf_jobs where status = 'running' and locked_at < p_now - interval '15 minutes'
                   union all select locked_at from agreement_jobs where locked_at < p_now - interval '15 minutes'
                   union all select started_at from photo_jobs where status = 'processing' and started_at < p_now - interval '60 minutes') l
        union all select 'webhooks', 'Incoming webhooks failing', 'failed', count(*), min(received_at) from webhook_events
                   where processed_at is null and error is not null and received_at > p_now - interval '24 hours' and received_at < p_now - interval '30 minutes'
      ) q where q.n >= case when q.st = 'backlog' then 5 else 1 end;
  -- calendar feeds failing three times in a row
  return query
    select 'queue'::text, 'calendar_feed', 'queue:calendar_feed:' || f.id, 'Calendar feed failing: ' || coalesce(f.label, f.platform),
           left(app.redact_text(f.last_error), 500), 'failing'::text, null::text,
           jsonb_build_object('feed', f.id, 'failures', f.consecutive_failures, 'since', f.failing_since, 'platform', f.platform)
      from calendar_feeds f where f.enabled and f.kind = 'ical' and coalesce(f.consecutive_failures, 0) >= 3;
  -- the server, as the heal agent reported it in the last 10 minutes
  if ss.reported_at > p_now - interval '10 minutes' then
    return query
      select 'server'::text, p ->> 'key', 'server:' || (p ->> 'key'), coalesce(p ->> 'title', p ->> 'key'), left(p ->> 'detail', 500), coalesce(p ->> 'state', 'problem'),
             null::text, p
        from jsonb_array_elements(ss.problems) p where p ->> 'key' ~ '^[a-z_]{2,40}$';
  end if;
end $$;

-- ================================================================ 5. the actions (the whitelist; every one idempotent)
create function app.heal_run_action(p_action text, p_params jsonb, i heal_incidents, p_now timestamptz default now()) returns jsonb
language plpgsql security definer set search_path = public, app, pg_temp as $$
declare
  a heal_actions;
  v_n integer := 0; v_m integer := 0; v_k integer := 0; v_j integer := 0;
  v_cmd text;
  v_job text := coalesce(nullif(p_params ->> 'job', ''), i.key);
  v_out jsonb;
  r record;
  v_to text;
  v_slug text;
begin
  select * into a from heal_actions where key = p_action;
  if a.key is null then raise exception 'Not a whitelisted action: %', p_action using errcode = '42501'; end if;
  if i.money or app.heal_is_money(i.source, i.key, i.detail) then raise exception 'Money is never fixed automatically' using errcode = '42501'; end if;
  case p_action
  when 'rerun_cron' then
    if to_regclass('cron.job') is null then raise exception 'pg_cron is not on this database' using errcode = 'P0002'; end if;
    execute 'select command from cron.job where jobname = $1' into v_cmd using v_job;
    if v_cmd is null then raise exception 'No scheduled job named %', v_job using errcode = 'P0002'; end if;
    if v_cmd !~* '^\s*select\s+app\.job_[a-z0-9_]+\s*\([^;]*\)\s*;?\s*$' then raise exception 'Only a "select app.job_...()" command is run again' using errcode = '42501'; end if;
    if app.heal_is_money('cron', v_job, v_cmd) then raise exception 'Money is never fixed automatically' using errcode = '42501'; end if;
    execute regexp_replace(v_cmd, ';\s*$', '') into v_cmd;
    return jsonb_build_object('job', v_job, 'ran', true, 'answer', left(v_cmd, 300));
  when 'requeue_outbox' then
    update notification_outbox set status = case when attempts >= 5 then 'failed' else 'queued' end, locked_at = null, send_after = p_now,
           last_error = case when attempts >= 5 then coalesce(last_error, '') || ' (stuck sending; retry limit reached, self-healing)' else last_error end
     where status = 'sending' and locked_at < p_now - interval '15 minutes';
    get diagnostics v_n = row_count;
    update phone_outbox set status = case when attempts >= 5 then 'failed' else 'queued' end, locked_at = null, send_after = p_now,
           last_error = case when attempts >= 5 then coalesce(last_error, '') || ' (stuck sending; retry limit reached, self-healing)' else last_error end
     where status = 'sending' and locked_at < p_now - interval '15 minutes';
    get diagnostics v_m = row_count;
    update push_outbox set status = case when attempts >= 5 then 'failed' else 'queued' end, locked_at = null, send_after = p_now
     where status = 'sending' and locked_at < p_now - interval '15 minutes';
    get diagnostics v_k = row_count;
    return jsonb_build_object('emails', v_n, 'texts', v_m, 'push', v_k);
  when 'release_locks' then
    update job_runs set status = 'failed', finished_at = p_now, error = coalesce(error, 'Left running over 2 hours: released by self-healing')
     where status = 'running' and started_at < p_now - interval '2 hours';
    get diagnostics v_n = row_count;
    update pdf_jobs set status = case when attempts >= max_attempts then 'failed' else 'queued' end, locked_at = null, locked_by = null, next_attempt_at = p_now,
           last_error = coalesce(last_error, 'Lock released by self-healing')
     where status = 'running' and locked_at < p_now - interval '15 minutes';
    get diagnostics v_m = row_count;
    update agreement_jobs set locked_at = null, locked_seq = null where locked_at < p_now - interval '15 minutes';
    get diagnostics v_k = row_count;
    update photo_jobs set status = case when attempts >= 3 then 'failed' else 'queued' end, next_attempt_at = p_now,
           error = case when attempts >= 3 then coalesce(error, 'Stuck processing: released by self-healing') else error end
     where status = 'processing' and started_at < p_now - interval '60 minutes';
    get diagnostics v_j = row_count;
    delete from request_claims where expires_at < p_now - interval '1 hour';
    return jsonb_build_object('job_runs', v_n, 'pdf_jobs', v_m, 'agreement_jobs', v_k, 'photo_jobs', v_j);
  when 'data_health_autofix' then
    v_out := app.data_health_autofix(p_now);
    perform app.data_health_store(p_now, v_out, null);
    return jsonb_build_object('fixed', v_out);
  when 'booking_recovery' then
    return jsonb_build_object('answer', app.job_booking_recovery(p_now));
  when 'calendar_resync' then
    update calendar_feeds set last_attempt_at = null
     where enabled and kind = 'ical' and coalesce(consecutive_failures, 0) > 0 and (i.evidence ->> 'feed' is null or id = (i.evidence ->> 'feed')::uuid);
    get diagnostics v_n = row_count;
    return jsonb_build_object('feeds', v_n);
  when 'uptime_recheck' then
    update uptime_checks set last_checked_at = null where kind = 'internal' and enabled;
    return jsonb_build_object('answer', app.job_uptime(p_now));
  when 'resync_sequences' then
    for r in select s.oid::regclass seq, t.oid::regclass tbl, c.attname col
               from pg_class s join pg_depend d on d.objid = s.oid and d.deptype in ('a', 'i')
               join pg_class t on t.oid = d.refobjid join pg_attribute c on c.attrelid = t.oid and c.attnum = d.refobjsubid
               join pg_namespace n on n.oid = t.relnamespace
              where s.relkind = 'S' and n.nspname = 'public' loop
      execute format('select coalesce(max(%I), 0) from %s', r.col, r.tbl) into v_n;
      execute format('select last_value from %s', r.seq) into v_m;
      if v_n > v_m then execute format('select setval(%L, %s)', r.seq, v_n); v_k := v_k + 1; end if;
    end loop;
    return jsonb_build_object('counters_moved', v_k);
  when 'gsc_redirect' then
    for r in select distinct lower(rtrim(p, '/')) p from jsonb_array_elements_text(coalesce(i.evidence -> 'paths', '[]'::jsonb)) p
              where lower(rtrim(p, '/')) ~ '^/cars/[a-z0-9][a-z0-9-]*$' loop
      v_slug := substr(r.p, 7);
      -- a live page answers there: nothing to redirect
      continue when exists (select 1 from vehicle_listings l where l.slug = v_slug and l.status = 'published');
      continue when exists (select 1 from listing_redirects lr where lr.from_path = r.p);
      select '/cars/' || l.slug into v_to from vehicle_listings l
       where l.status = 'published' and l.slug is not null and similarity(l.slug, v_slug) >= 0.3
       order by similarity(l.slug, v_slug) desc, l.published_at desc nulls last limit 1;
      v_to := coalesce(v_to, '/cars');
      insert into listing_redirects (from_path, to_path, status_code, reason) values (r.p, v_to, 301, 'Self-healing: Google reported the page missing') on conflict do nothing;
      get diagnostics v_m = row_count;
      if v_m > 0 then
        v_n := v_n + 1;
        perform app.indexnow_queue_path(r.p, 'self-healing redirect');
        update app.gsc_url_inspection set next_ping_at = p_now where path = r.p or path = r.p || '/';
      end if;
    end loop;
    return jsonb_build_object('redirects', v_n, 'note', 'Pages outside /cars/ have no redirect mechanism: they are escalated');
  else
    -- a server action: queued for the heal agent
    if a.kind <> 'server' then raise exception 'No runner for %', p_action using errcode = '42501'; end if;
    return jsonb_build_object('queued', true);
  end case;
end $$;

-- ================================================================ 6. escalation (once per incident)
create function app.heal_escalate(p_incident uuid, p_reason text, p_now timestamptz default now()) returns void
language plpgsql security definer set search_path = public, app, pg_temp as $$
declare
  i heal_incidents;
  v_task uuid;
  v_bug uuid;
  v_rep uuid := app.heal_reporter();
  v_tried text;
begin
  select * into i from heal_incidents where id = p_incident for update;
  if i.id is null or i.escalated_at is not null or i.status = 'healed' then return; end if;
  select string_agg(format('%s: %s%s', to_char(t.started_at at time zone 'America/Toronto', 'Mon DD HH24:MI'), coalesce(p.title, t.action),
                           case when t.verified then ' (cleared)' when t.verified is false then ' (did not clear)' else ' (' || t.result || ')' end), '; ' order by t.started_at)
    into v_tried from heal_attempts t left join heal_playbooks p on p.id = t.playbook_id where t.incident_id = i.id;
  -- the To do
  insert into tasks (queue, task_type, title, detail, priority, status, related_table, related_id, dedupe_key)
  values ('admin', 'self_heal', left('Self-healing could not fix: ' || i.title, 200),
          left(format('%s. %s Tried: %s. Open Admin > Self-healing (/admin/self-healing), fix it, then Resolve it or Save as fix.',
                      coalesce(i.detail, i.title), p_reason, coalesce(v_tried, 'nothing (no safe fix)')), 2000),
          'high', 'open', 'heal_incidents', i.id, 'self_heal:' || i.id)
  on conflict do nothing
  returning id into v_task;
  -- the bug report with the evidence (as the first Admin; the context says the site filed it)
  if v_rep is not null then
    insert into bug_reports (reporter_id, portal, happened, expected, steps, severity, page_path, context, client_logs)
    values (v_rep, 'admin',
            left(format('Self-healing incident #%s (%s): %s. %s', i.number, i.source, coalesce(i.detail, i.title), p_reason), 4000),
            'The site fixes this by itself, or it does not happen.',
            left('Tried: ' || coalesce(v_tried, 'nothing (no safe fix)') || '. Seen ' || i.seen_count || ' times from ' || i.first_seen || ' to ' || i.last_seen || '.', 4000),
            case when i.source in ('uptime', 'server') or i.money then 'blocks_work' else 'annoying' end,
            left(coalesce(nullif(split_part(i.path, '?', 1), ''), '/admin/self-healing'), 500),
            jsonb_build_object('filed_by', 'self-healing', 'incident', i.id, 'number', i.number, 'source', i.source, 'key', i.key, 'state', i.state,
                               'evidence', case when pg_column_size(i.evidence) < 12000 then i.evidence else jsonb_build_object('truncated', true) end),
            '[]'::jsonb)
    returning id into v_bug;
  end if;
  update heal_incidents set status = 'escalated', escalated_at = p_now, escalation_reason = left(p_reason, 500), todo_id = v_task, bug_report_id = v_bug, updated_at = p_now
   where id = i.id;
  -- the one Admin alert
  perform app.staff_alert('self_heal_escalated', 'heal_incident', i.id, 'escalated', left('Needs you: ' || i.title, 140),
    left(p_reason || ' ' || coalesce(i.detail, ''), 240), jsonb_build_object('path_admin', '/admin/self-healing#incident-' || i.number));
  perform app.heal_audit('heal_escalated', 'heal_incidents', i.id::text, jsonb_build_object('reason', p_reason, 'todo', v_task, 'bug_report', v_bug));
end $$;

-- the circuit breaker: a playbook failing breaker_failures times in a row switches itself off and escalates once
create function app.heal_breaker(p_playbook uuid, p_now timestamptz default now()) returns boolean
language plpgsql security definer set search_path = public, app, pg_temp as $$
declare
  p heal_playbooks;
  s heal_settings;
  v_task uuid;
begin
  select * into s from heal_settings;
  select * into p from heal_playbooks where id = p_playbook for update;
  if p.id is null or not p.enabled or p.consecutive_failures < s.breaker_failures then return false; end if;
  update heal_playbooks set enabled = false, disabled_at = p_now, updated_at = p_now,
         disabled_reason = format('Failed %s times in a row: switched off by the circuit breaker', p.consecutive_failures)
   where id = p.id;
  insert into tasks (queue, task_type, title, detail, priority, status, related_table, related_id, dedupe_key)
  values ('admin', 'self_heal', left('A self-healing fix switched itself off: ' || p.title, 200),
          format('It failed %s times in a row (%s fixed, %s failed in all). Look at what it was fixing in Admin > Self-healing, then switch it on again or leave it off.',
                 p.consecutive_failures, p.successes, p.failures), 'high', 'open', 'heal_playbooks', p.id,
          'self_heal_breaker:' || p.id || ':' || floor(extract(epoch from p_now))::bigint)
  on conflict do nothing returning id into v_task;
  perform app.staff_alert('self_heal_breaker', 'heal_playbook', p.id, 'off:' || floor(extract(epoch from p_now))::bigint,
    left('Fix switched off: ' || p.title, 140), format('It failed %s times in a row. Self-healing no longer runs it until you switch it on.', p.consecutive_failures),
    jsonb_build_object('path_admin', '/admin/self-healing#playbooks'));
  perform app.heal_audit('heal_breaker', 'heal_playbooks', p.id::text, jsonb_build_object('consecutive_failures', p.consecutive_failures, 'todo', v_task));
  return true;
end $$;

-- one attempt finished: the playbook's counts and the incident
create function app.heal_settle(p_attempt uuid, p_ok boolean, p_note text, p_now timestamptz default now()) returns void
language plpgsql security definer set search_path = public, app, pg_temp as $$
declare
  t heal_attempts;
  i heal_incidents;
begin
  update heal_attempts set verified = p_ok, verified_at = p_now, details = details || jsonb_build_object('check', p_note)
   where id = p_attempt and verified is null returning * into t;
  if t.id is null then return; end if;
  if t.playbook_id is not null then
    update heal_playbooks set successes = successes + case when p_ok then 1 else 0 end, failures = failures + case when p_ok then 0 else 1 end,
           consecutive_failures = case when p_ok then 0 else consecutive_failures + 1 end, updated_at = p_now
     where id = t.playbook_id;
  end if;
  select * into i from heal_incidents where id = t.incident_id;
  if p_ok then
    update heal_incidents set status = 'healed', healed_at = p_now, healed_by = 'playbook', updated_at = p_now where id = i.id and status <> 'healed';
    -- a healed incident is a quiet log line; a rollback is escalated after it all the same (the bad build is looked at)
    if t.action = 'rollback_web' then
      update heal_incidents set status = 'open', healed_at = null, healed_by = null, keep_open = true where id = i.id;
      perform app.heal_escalate(i.id, 'The site went back to the previous build after the deploy. Look at the new build before deploying it again.', p_now);
    end if;
  else
    update heal_incidents set status = case when status = 'healing' then 'open' else status end, next_try_at = p_now, updated_at = p_now where id = i.id;
    if t.playbook_id is not null then perform app.heal_breaker(t.playbook_id, p_now); end if;
  end if;
  perform app.heal_audit(case when p_ok then 'heal_attempt_cleared' else 'heal_attempt_failed' end, 'heal_attempts', t.id::text,
                         jsonb_build_object('incident', t.incident_id, 'playbook', t.playbook_id, 'action', t.action, 'note', p_note));
end $$;

-- ================================================================ 7. the engine
create function app.job_heal(p_now timestamptz default now()) returns jsonb
language plpgsql security definer set search_path = public, app, pg_temp as $$
declare
  s heal_settings;
  sig record;
  i heal_incidents;
  t heal_attempts;
  p heal_playbooks;
  q heal_requests;
  v_present text[];
  v_new integer := 0; v_ran integer := 0; v_healed integer := 0; v_esc integer := 0;
  v_res jsonb;
  v_err text;
  v_kind text;
  v_back integer;
begin
  if not pg_try_advisory_xact_lock(hashtext('carmacars-heal')) then return jsonb_build_object('skipped', 'already running'); end if;
  select * into s from heal_settings;
  if not s.enabled then return jsonb_build_object('enabled', false); end if;

  -- 1. the problems now: open or update their incidents
  create temp table if not exists heal_now (source text, key text, fingerprint text primary key, title text, detail text, state text, path text, evidence jsonb) on commit drop;
  truncate heal_now;
  insert into heal_now select distinct on (x.fingerprint) x.* from app.heal_signals(p_now) x where x.fingerprint is not null;
  select coalesce(array_agg(fingerprint), '{}') into v_present from heal_now;
  for sig in select * from heal_now order by source, fingerprint loop
    select * into i from heal_incidents where fingerprint = sig.fingerprint and status <> 'healed';
    if i.id is not null then
      update heal_incidents set last_seen = p_now, seen_count = seen_count + 1, detail = sig.detail, evidence = coalesce(sig.evidence, '{}'::jsonb),
             state = sig.state, updated_at = p_now where id = i.id;
      continue;
    end if;
    continue when v_new >= s.max_new_per_tick;
    insert into heal_incidents (fingerprint, source, key, title, detail, state, path, evidence, money, first_seen, last_seen, next_try_at)
    values (sig.fingerprint, sig.source, sig.key, sig.title, sig.detail, sig.state, sig.path, coalesce(sig.evidence, '{}'::jsonb),
            app.heal_is_money(sig.source, sig.key, coalesce(sig.detail, '') || ' ' || coalesce(sig.evidence ->> 'command', '')), p_now, p_now, p_now)
    returning * into i;
    v_new := v_new + 1;
    perform app.heal_audit('heal_incident_opened', 'heal_incidents', i.id::text, jsonb_build_object('fingerprint', i.fingerprint, 'title', i.title, 'money', i.money));
    if i.money then
      perform app.heal_escalate(i.id, 'It is about money: self-healing never changes payments, deposits, payouts, refunds, statements or charges.', p_now);
      v_esc := v_esc + 1;
    else
      -- the same problem healed three times in a day keeps coming back: a person looks at it
      select count(*) into v_back from heal_incidents where fingerprint = i.fingerprint and status = 'healed' and healed_at > p_now - interval '24 hours';
      if v_back >= 3 then
        perform app.heal_escalate(i.id, format('It came back %s times in 24 hours after being fixed.', v_back), p_now);
        v_esc := v_esc + 1;
      end if;
    end if;
  end loop;

  -- 2. server actions the agent finished (or never picked up): their attempts
  for q in select * from heal_requests where status in ('pending', 'claimed') and created_at < p_now - make_interval(mins => s.agent_answer_minutes) loop
    update heal_requests set status = 'expired', finished_at = p_now, ok = false, result = 'The heal agent did not answer in time' where id = q.id;
    if q.attempt_id is not null then
      update heal_attempts set result = 'error', details = details || jsonb_build_object('agent', 'no answer') where id = q.attempt_id and verified is null;
      perform app.heal_settle(q.attempt_id, false, 'The heal agent on the server did not answer', p_now);
    end if;
  end loop;

  -- 3. the checks after the attempts: cleared or not
  for t in select a.* from heal_attempts a where a.verified is null and a.check_after is not null and a.check_after <= p_now order by a.started_at loop
    select * into i from heal_incidents where id = t.incident_id;
    if t.result = 'queued' then
      select * into q from heal_requests where attempt_id = t.id order by id desc limit 1;
      if q.status in ('pending', 'claimed') then continue; end if;
      if q.status = 'done' and q.ok then
        -- the agent did it: the check comes verify_minutes after it finished
        update heal_attempts set result = 'ok', details = details || jsonb_build_object('agent', q.result),
               check_after = q.finished_at + make_interval(mins => coalesce((select verify_minutes from heal_playbooks where id = t.playbook_id), 2))
         where id = t.id;
        continue;
      end if;
      perform app.heal_settle(t.id, false, coalesce(q.result, 'The server action failed'), p_now);
      continue;
    end if;
    if i.fingerprint = any (v_present) then
      perform app.heal_settle(t.id, false, 'Still there after the fix', p_now);
    else
      perform app.heal_settle(t.id, true, 'Gone after the fix', p_now);
      v_healed := v_healed + 1;
    end if;
  end loop;

  -- 4. incidents whose problem is gone with nothing pending: healed by itself
  for i in select * from heal_incidents h where h.status in ('open', 'escalated') and not h.keep_open and not (h.fingerprint = any (v_present))
              and not exists (select 1 from heal_attempts a where a.incident_id = h.id and a.verified is null) loop
    update heal_incidents set status = 'healed', healed_at = p_now, healed_by = case when i.status = 'escalated' then 'itself' else coalesce(healed_by, 'itself') end, updated_at = p_now
     where id = i.id;
    if i.todo_id is not null then
      update tasks set status = 'done', completed_at = p_now, completion_note = 'The problem cleared: self-healing saw it gone' where id = i.todo_id and status not in ('done', 'cancelled');
    end if;
    perform app.heal_audit('heal_incident_cleared', 'heal_incidents', i.id::text, jsonb_build_object('after_escalation', i.status = 'escalated'));
    v_healed := v_healed + 1;
  end loop;

  -- 5. the open incidents due a try: the matching playbook with the best success rate
  for i in select * from heal_incidents h where h.status = 'open' and h.next_try_at <= p_now and h.fingerprint = any (v_present)
              and not exists (select 1 from heal_attempts a where a.incident_id = h.id and a.verified is null)
            order by h.first_seen limit 50 loop
    if i.money then perform app.heal_escalate(i.id, 'It is about money: self-healing never changes it.', p_now); v_esc := v_esc + 1; continue; end if;
    if i.attempts >= s.max_attempts_per_incident then
      perform app.heal_escalate(i.id, format('%s fixes were tried and the problem is still there.', i.attempts), p_now); v_esc := v_esc + 1; continue;
    end if;
    select pb.* into p from heal_playbooks pb
     where pb.enabled and pb.source = i.source
       and (pb.match_key is null or i.key ~ pb.match_key)
       and (pb.match_pattern is null or coalesce(i.detail, '') || ' ' || coalesce(i.evidence::text, '') ~* pb.match_pattern)
       and (pb.match_state is null or pb.match_state = i.state)
       and (select count(*) from heal_attempts a where a.incident_id = i.id and a.playbook_id = pb.id) < pb.max_attempts
     order by (pb.successes + 1)::numeric / (pb.successes + pb.failures + 2) desc, pb.priority, pb.created_at
     limit 1;
    if p.id is null then
      perform app.heal_escalate(i.id, case when i.attempts = 0 then 'No safe fix is known for it.' else format('Every known fix was tried (%s) and the problem is still there.', i.attempts) end, p_now);
      v_esc := v_esc + 1; continue;
    end if;
    -- the cooldown: the same playbook ran a moment ago (here or for another incident): wait
    if p.last_run_at is not null and p.last_run_at > p_now - make_interval(mins => p.cooldown_minutes) then
      update heal_incidents set next_try_at = p.last_run_at + make_interval(mins => p.cooldown_minutes) where id = i.id;
      continue;
    end if;
    select kind into v_kind from heal_actions where key = p.action;
    v_err := null; v_res := null;
    begin
      v_res := app.heal_run_action(p.action, p.params, i, p_now);
    exception when others then
      get stacked diagnostics v_err = message_text;
    end;
    insert into heal_attempts (incident_id, playbook_id, action, params, started_at, result, check_after, details)
    values (i.id, p.id, p.action, p.params, p_now,
            case when v_err is not null then 'error' when v_kind = 'server' then 'queued' else 'ok' end,
            case when v_err is not null then null when v_kind = 'server' then p_now else p_now + make_interval(mins => p.verify_minutes) end,
            coalesce(v_res, '{}'::jsonb) || case when v_err is not null then jsonb_build_object('error', left(v_err, 500)) else '{}'::jsonb end)
    returning * into t;
    if v_kind = 'server' and v_err is null then
      insert into heal_requests (attempt_id, action, params) values (t.id, p.action, p.params || jsonb_build_object('incident', i.number));
    end if;
    update heal_playbooks set last_run_at = p_now, updated_at = p_now where id = p.id;
    update heal_incidents set attempts = attempts + 1, status = case when v_err is null then 'healing' else 'open' end, updated_at = p_now,
           next_try_at = p_now where id = i.id;
    perform app.heal_audit('heal_attempt', 'heal_attempts', t.id::text, jsonb_build_object('incident', i.id, 'playbook', p.key, 'action', p.action, 'result', t.result, 'error', v_err));
    if v_err is not null then perform app.heal_settle(t.id, false, 'The fix could not run: ' || left(v_err, 200), p_now); end if;
    v_ran := v_ran + 1;
  end loop;

  delete from heal_requests where finished_at < p_now - interval '30 days';
  return jsonb_build_object('problems', cardinality(v_present), 'opened', v_new, 'ran', v_ran, 'healed', v_healed, 'escalated', v_esc);
end $$;

-- ================================================================ 8. the Admin's side
create function app.heal_status(p_by uuid, p jsonb default '{}') returns jsonb
language plpgsql stable security definer set search_path = public, app, pg_temp as $$
declare
  v_limit integer := least(greatest(coalesce(nullif(p ->> 'limit', '')::integer, 40), 1), 200);
begin
  if not app.user_is_admin(p_by) then raise exception 'Only an Admin reads self-healing' using errcode = '42501'; end if;
  return jsonb_build_object(
    'enabled', (select enabled from heal_settings),
    'settings', (select to_jsonb(s) - 'id' from heal_settings s),
    'counts', jsonb_build_object(
      'open', (select count(*) from heal_incidents where status in ('open', 'healing')),
      'escalated', (select count(*) from heal_incidents where status = 'escalated'),
      'healed_7d', (select count(*) from heal_incidents where status = 'healed' and healed_at > now() - interval '7 days'),
      'healed_by_playbook_7d', (select count(*) from heal_incidents where status = 'healed' and healed_by = 'playbook' and healed_at > now() - interval '7 days'),
      'attempts_7d', (select count(*) from heal_attempts where started_at > now() - interval '7 days')),
    'incidents', coalesce((select jsonb_agg(q.x order by q.ord, q.last_seen desc) from (
        select case h.status when 'escalated' then 0 when 'healing' then 1 when 'open' then 2 else 3 end ord, h.last_seen,
               jsonb_build_object('id', h.id, 'number', h.number, 'source', h.source, 'key', h.key, 'title', h.title, 'detail', app.redact_text(h.detail),
                 'state', h.state, 'path', h.path, 'status', h.status, 'money', h.money, 'first_seen', h.first_seen, 'last_seen', h.last_seen,
                 'seen_count', h.seen_count, 'attempts', h.attempts, 'healed_at', h.healed_at, 'healed_by', h.healed_by, 'escalated_at', h.escalated_at,
                 'escalation_reason', h.escalation_reason, 'saved_playbook_id', h.saved_playbook_id, 'todo_id', h.todo_id, 'bug_report_id', h.bug_report_id, 'resolution_note', h.resolution_note,
                 'evidence', case when pg_column_size(h.evidence) < 4000 then h.evidence else jsonb_build_object('truncated', true) end,
                 'tried', coalesce((select jsonb_agg(jsonb_build_object('at', a.started_at, 'action', a.action, 'playbook', pb.title, 'result', a.result,
                                      'verified', a.verified, 'details', a.details) order by a.started_at)
                                    from heal_attempts a left join heal_playbooks pb on pb.id = a.playbook_id where a.incident_id = h.id), '[]'::jsonb)) x
          from heal_incidents h
         where h.status <> 'healed' or h.healed_at > now() - interval '7 days'
         order by case h.status when 'escalated' then 0 when 'healing' then 1 when 'open' then 2 else 3 end, h.last_seen desc limit v_limit) q(ord, last_seen, x)), '[]'::jsonb),
    'playbooks', coalesce((select jsonb_agg(jsonb_build_object('id', pb.id, 'key', pb.key, 'title', pb.title, 'source', pb.source, 'match_key', pb.match_key,
                  'match_pattern', pb.match_pattern, 'match_state', pb.match_state, 'action', pb.action, 'action_label', ha.label, 'action_kind', ha.kind,
                  'params', pb.params, 'max_attempts', pb.max_attempts, 'cooldown_minutes', pb.cooldown_minutes, 'verify_minutes', pb.verify_minutes,
                  'enabled', pb.enabled, 'successes', pb.successes, 'failures', pb.failures, 'consecutive_failures', pb.consecutive_failures,
                  'last_run_at', pb.last_run_at, 'disabled_reason', pb.disabled_reason, 'builtin', pb.builtin, 'learned_from', pb.learned_from)
                  order by pb.source, pb.priority, pb.title) from heal_playbooks pb join heal_actions ha on ha.key = pb.action), '[]'::jsonb),
    'actions', coalesce((select jsonb_agg(jsonb_build_object('key', a.key, 'label', a.label, 'kind', a.kind, 'description', a.description) order by a.sort) from heal_actions a), '[]'::jsonb),
    'server', (select jsonb_build_object('reported_at', reported_at, 'web_tag', web_tag, 'previous_tag', previous_tag, 'deployed_at', deployed_at,
                 'web_health', web_health, 'disk_pct', disk_pct, 'cert_days', cert_days, 'problems', problems, 'local_actions', local_actions) from heal_server_state),
    'requests', coalesce((select jsonb_agg(jsonb_build_object('id', r.id, 'action', r.action, 'status', r.status, 'created_at', r.created_at, 'finished_at', r.finished_at,
                 'ok', r.ok, 'result', r.result) order by r.id desc) from (select * from heal_requests order by id desc limit 20) r), '[]'::jsonb),
    'note', 'The site fixes what a whitelisted, reversible action can fix (a retry, a restart, the previous build, a redirect). It cannot rewrite its own code: a code bug is mitigated and filed as a bug report with the evidence. Money is never fixed automatically.');
end $$;

create function app.heal_playbook_toggle(p_by uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app, pg_temp as $$
declare
  v_id uuid := case when coalesce(p ->> 'id', '') ~* '^[0-9a-f-]{36}$' then (p ->> 'id')::uuid end;
  v_on boolean := coalesce((p ->> 'enabled')::boolean, true);
  b heal_playbooks;
begin
  if not app.user_is_admin(p_by) then raise exception 'Only an Admin changes self-healing' using errcode = '42501'; end if;
  select * into b from heal_playbooks where id = v_id;
  if b.id is null then raise exception 'That fix is not in the library' using errcode = 'P0002'; end if;
  update heal_playbooks set enabled = v_on, updated_at = now(),
         consecutive_failures = case when v_on then 0 else consecutive_failures end,
         disabled_at = case when v_on then null else now() end,
         disabled_reason = case when v_on then null else 'Switched off by an Admin' end
   where id = b.id;
  perform app.heal_audit('heal_playbook_toggle', 'heal_playbooks', b.id::text, jsonb_build_object('enabled', v_on, 'was', b.enabled), p_by);
  return jsonb_build_object('id', b.id, 'enabled', v_on);
end $$;

-- an Admin resolves an escalated (or open) incident by hand
create function app.heal_resolve(p_by uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app, pg_temp as $$
declare
  v_id uuid := case when coalesce(p ->> 'incident', p ->> 'id', '') ~* '^[0-9a-f-]{36}$' then coalesce(p ->> 'incident', p ->> 'id')::uuid end;
  v_note text := nullif(btrim(coalesce(p ->> 'note', '')), '');
  i heal_incidents;
begin
  if not app.user_is_admin(p_by) then raise exception 'Only an Admin resolves self-healing incidents' using errcode = '42501'; end if;
  select * into i from heal_incidents where id = v_id for update;
  if i.id is null then raise exception 'That incident is not there' using errcode = 'P0002'; end if;
  if i.status = 'healed' then return jsonb_build_object('id', i.id, 'status', 'healed'); end if;
  if v_note is null then raise exception 'Say what fixed it (a line for the next person)' using errcode = '22023'; end if;
  update heal_attempts set verified = false, verified_at = now(), details = details || jsonb_build_object('check', 'Resolved by an Admin first')
   where incident_id = i.id and verified is null;
  update heal_incidents set status = 'healed', healed_at = now(), healed_by = 'staff', resolved_by = p_by, resolution_note = left(v_note, 1000), updated_at = now() where id = i.id;
  if i.todo_id is not null then
    update tasks set status = 'done', completed_at = now(), completed_by = p_by, completion_note = left('Resolved: ' || v_note, 500) where id = i.todo_id and status not in ('done', 'cancelled');
  end if;
  perform app.heal_audit('heal_resolve', 'heal_incidents', i.id::text, jsonb_build_object('note', v_note), p_by);
  return jsonb_build_object('id', i.id, 'status', 'healed');
end $$;

-- "Save as fix": what fixed an incident becomes a playbook (a whitelisted action only), and the incident is resolved
create function app.heal_save_fix(p_by uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app, pg_temp as $$
declare
  v_id uuid := case when coalesce(p ->> 'incident', '') ~* '^[0-9a-f-]{36}$' then (p ->> 'incident')::uuid end;
  v_action text := btrim(coalesce(p ->> 'action', ''));
  v_title text := nullif(btrim(coalesce(p ->> 'title', '')), '');
  v_pattern text := nullif(btrim(coalesce(p ->> 'match_pattern', '')), '');
  v_params jsonb := case when jsonb_typeof(p -> 'params') = 'object' then p -> 'params' else '{}'::jsonb end;
  i heal_incidents;
  b heal_playbooks;
begin
  if not app.user_is_admin(p_by) then raise exception 'Only an Admin adds fixes to the library' using errcode = '42501'; end if;
  select * into i from heal_incidents where id = v_id;
  if i.id is null then raise exception 'That incident is not there' using errcode = 'P0002'; end if;
  if not exists (select 1 from heal_actions where key = v_action) then raise exception 'Choose one of the listed actions' using errcode = '22023'; end if;
  if i.money or app.heal_is_money(i.source, i.key, i.detail) then
    raise exception 'A problem about money is never fixed automatically: resolve it instead' using errcode = '42501';
  end if;
  if v_pattern is not null then
    begin perform '' ~ v_pattern; exception when others then raise exception 'The message pattern is not a valid pattern' using errcode = '22023'; end;
  end if;
  insert into heal_playbooks (key, title, source, match_key, match_pattern, match_state, action, params, priority, max_attempts, cooldown_minutes, verify_minutes,
                              learned_from, created_by, from_incident)
  values (left('learned-' || i.source || '-' || regexp_replace(lower(i.key), '[^a-z0-9]+', '-', 'g'), 70) || '-' || substr(md5(gen_random_uuid()::text), 1, 6),
          coalesce(left(v_title, 200), left((select label from heal_actions where key = v_action) || ' for ' || i.title, 200)),
          i.source, '^' || regexp_replace(i.key, '([.^$*+?()\[\]{}|\\])', '\\\1', 'g') || '$', v_pattern, i.state, v_action, v_params, 50,
          least(greatest(coalesce(nullif(p ->> 'max_attempts', '')::integer, 1), 1), 10), 10,
          least(greatest(coalesce(nullif(p ->> 'verify_minutes', '')::integer, case when i.source = 'site_error' then (select error_window_minutes from heal_settings) else 2 end), 1), 240),
          format('Incident #%s, saved by an Admin', i.number), p_by, i.id)
  returning * into b;
  perform app.heal_audit('heal_save_fix', 'heal_playbooks', b.id::text, jsonb_build_object('incident', i.id, 'action', v_action, 'source', i.source, 'key', i.key), p_by);
  if i.status <> 'healed' then
    perform app.heal_resolve(p_by, jsonb_build_object('incident', i.id, 'note', coalesce(nullif(btrim(coalesce(p ->> 'note', '')), ''), 'Fixed with: ' || b.title)));
  end if;
  update heal_incidents set saved_playbook_id = b.id where id = i.id;
  return jsonb_build_object('playbook', b.id, 'key', b.key, 'title', b.title);
end $$;

-- ================================================================ 9. the door and the connector
alter function app.door(uuid, text, text, text, jsonb) rename to door_pre4800;
create function app.door(p_user uuid, p_aal text, p_call text, p_name text, p jsonb default '{}'::jsonb) returns jsonb
language plpgsql security definer set search_path = public, app, pg_temp as $$
declare
  p_ jsonb := coalesce(p, '{}'::jsonb) - '_va';
begin
  if (p_call = 'admin_read' and p_name = 'heal_status')
     or (p_call in ('admin_do', 'ops_do') and p_name in ('heal_playbook_toggle', 'heal_resolve', 'heal_save_fix')) then
    perform app.door_begin(p_user, p_aal);
    return case p_name when 'heal_status' then app.heal_status(p_user, p_)
                       when 'heal_playbook_toggle' then app.heal_playbook_toggle(p_user, p_)
                       when 'heal_resolve' then app.heal_resolve(p_user, p_)
                       else app.heal_save_fix(p_user, p_) end;
  end if;
  return app.door_pre4800(p_user, p_aal, p_call, p_name, p);
end $$;
select pg_temp.copy_grants('app.door(uuid, text, text, text, jsonb)'::regprocedure, 'app.door_pre4800(uuid, text, text, text, jsonb)'::regprocedure);

alter function app.api_call(text, text, jsonb, text) rename to api_call_pre4800;
create function app.api_call(p_hash text, p_tool text, p_args jsonb, p_client text default null) returns jsonb
language plpgsql security definer set search_path = public, app, pg_temp as $$
declare
  a jsonb := case when jsonb_typeof(p_args) = 'object' then p_args else '{}'::jsonb end;
  chk jsonb;
  k api_keys;
  v_result jsonb;
begin
  if p_tool <> 'heal_status' then return app.api_call_pre4800(p_hash, p_tool, p_args, p_client); end if;
  chk := app.api_key_check(p_hash, 'admin:read', p_tool, a, p_client);
  if not (chk ->> 'ok')::boolean then return chk; end if;
  k := jsonb_populate_record(null::api_keys, chk -> 'key');
  perform app.door_begin(k.user_id, 'aal2');
  begin
    v_result := app.heal_status(k.user_id, a);
  exception when others then
    insert into api_calls (key_id, user_id, tool, target, args, ok, error, client) values (k.id, k.user_id, p_tool, p_tool, a, false, left(sqlerrm, 500), left(p_client, 64));
    return jsonb_build_object('ok', false, 'status', case sqlstate when 'P0002' then 404 when '42501' then 403 else 400 end, 'error', regexp_replace(sqlerrm, '^.*?ERROR:\s*', ''));
  end;
  insert into api_calls (key_id, user_id, tool, target, args, ok, client) values (k.id, k.user_id, p_tool, p_tool, a, true, left(p_client, 64));
  return jsonb_build_object('ok', true, 'result', v_result);
end $$;
select pg_temp.copy_grants('app.api_call(text, text, jsonb, text)'::regprocedure, 'app.api_call_pre4800(text, text, jsonb, text)'::regprocedure);

-- ================================================================ 10. the heal agent on the server (a narrow role)
-- The agent (infra/vps/bin/heal-agent) connects inside the database container and switches to heal_agent before its two calls:
-- heal_agent_tick reports the server's state and claims the pending server actions; heal_agent_done writes each result back.
do $$
begin
  if not exists (select 1 from pg_roles where rolname = 'heal_agent') then
    begin
      create role heal_agent nologin;
    exception when insufficient_privilege then raise notice 'heal_agent role not created (no CREATEROLE here)';
    end;
  end if;
end $$;

create function app.heal_agent_tick(p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app, pg_temp as $$
declare
  v_claimed jsonb;
  v_known text[] := array['restart_web', 'restart_caddy', 'restart_livekit', 'renew_certs', 'free_disk', 'reset_db_connections', 'rollback_web'];
begin
  update heal_server_state set
    reported_at = now(),
    web_tag = left(nullif(p ->> 'web_tag', ''), 40),
    previous_tag = left(nullif(p ->> 'previous_tag', ''), 40),
    deployed_at = case when coalesce(p ->> 'deployed_at', '') ~ '^[0-9]{4}-[0-9]{2}-[0-9]{2}T' then (p ->> 'deployed_at')::timestamptz else deployed_at end,
    web_health = left(nullif(p ->> 'web_health', ''), 40),
    disk_pct = case when coalesce(p ->> 'disk_pct', '') ~ '^[0-9]{1,3}$' then (p ->> 'disk_pct')::integer end,
    cert_days = case when coalesce(p ->> 'cert_days', '') ~ '^-?[0-9]{1,5}$' then (p ->> 'cert_days')::integer end,
    problems = case when jsonb_typeof(p -> 'problems') = 'array' and jsonb_array_length(p -> 'problems') <= 20 then p -> 'problems' else '[]'::jsonb end,
    local_actions = case when jsonb_typeof(p -> 'local_actions') = 'array' and jsonb_array_length(p -> 'local_actions') > 0
                         then (select coalesce(jsonb_agg(x), '[]'::jsonb) from (select x from jsonb_array_elements((p -> 'local_actions') || local_actions) x limit 20) y)
                         else local_actions end
   where id;
  with c as (
    update heal_requests r set status = 'claimed', claimed_at = now()
     where r.id in (select id from heal_requests where status = 'pending' and action = any (v_known) order by id limit 5 for update skip locked)
    returning r.id, r.action, r.params)
  select coalesce(jsonb_agg(jsonb_build_object('id', id, 'action', action, 'params', params) order by id), '[]'::jsonb) into v_claimed from c;
  return jsonb_build_object('actions', v_claimed);
end $$;

create function app.heal_agent_done(p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app, pg_temp as $$
declare
  v_id bigint := case when coalesce(p ->> 'id', '') ~ '^[0-9]{1,18}$' then (p ->> 'id')::bigint end;
  r heal_requests;
begin
  update heal_requests set status = case when coalesce((p ->> 'ok')::boolean, false) then 'done' else 'failed' end,
         ok = coalesce((p ->> 'ok')::boolean, false), finished_at = now(), result = left(coalesce(p ->> 'result', ''), 1000)
   where id = v_id and status = 'claimed' returning * into r;
  if r.id is null then return jsonb_build_object('ok', false); end if;
  perform app.heal_audit('heal_agent_done', 'heal_requests', r.id::text, jsonb_build_object('action', r.action, 'ok', r.ok, 'result', r.result));
  return jsonb_build_object('ok', true);
end $$;

-- ================================================================ 11. the fix library, seeded
-- From the data health autofixes (0441), the recovery jobs (0062), and the incidents in docs/changes: the Error 1102 and site
-- outages (0062, 0530), the email backlog of November 6 (0530), the sequence left at 1 on the cutover day (0970), the closed
-- database socket on a missing car page (4701), the stuck photo renders (r50 photo loops), failing calendar feeds (0062).
insert into heal_playbooks (key, title, source, match_key, match_pattern, match_state, action, params, priority, max_attempts, cooldown_minutes, verify_minutes, builtin, learned_from) values
  ('uptime.recheck', 'Check a failing page again (a passing hiccup, as with the single Error 1102s)', 'uptime', '^(home|car_page|sign_in|health)$', null, null, 'uptime_recheck', '{}', 10, 1, 5, 6, true, '0062, 0075: short problems such as a single Error 1102'),
  ('uptime.restart-web', 'Restart the website when its pages keep failing', 'uptime', '^(home|car_page|sign_in|health)$', null, null, 'restart_web', '{}', 20, 1, 30, 6, true, 'Hotfix of November 6 (0530): the site slow or down'),
  ('uptime.restart-caddy', 'Restart Caddy when the pages still fail after the site restarted', 'uptime', '^(home|car_page|sign_in|health)$', null, null, 'restart_caddy', '{}', 30, 1, 30, 6, true, 'The VPS cutover (r42, r48): certificates and Caddy''s site file'),
  ('data-health.autofix', 'Run the data health fixes again', 'data_health', '^(test_accounts|duplicate_tasks|resolved_tasks)$', null, null, 'data_health_autofix', '{}', 10, 2, 30, 1, true, '0441: the fixes Data health makes without asking'),
  ('site-error.socket', 'End idle database connections when pages fail with closed sockets or no free connection', 'site_error', null, '(socket has been closed|too many clients|remaining connection slots|connection terminated|ECONNRESET|Connection terminated)', null, 'reset_db_connections', '{}', 10, 1, 30, 15, true, '4701: "This socket has been closed" on a missing car page'),
  ('site-error.restart-web', 'Restart the website on a spike of server errors', 'site_error', null, null, 'server', 'restart_web', '{}', 50, 1, 60, 15, true, 'Hotfix of November 6 (0530): Worker CPU over its limit, the site down'),
  ('server.deploy-rollback', 'Go back to the previous build when errors spike right after a deploy', 'server', '^deploy_errors$', null, null, 'rollback_web', '{}', 10, 1, 60, 5, true, 'r50: the automatic rollback after a deploy'),
  ('server.web-unhealthy', 'Restart the website when its container is unhealthy', 'server', '^web_unhealthy$', null, null, 'restart_web', '{}', 10, 2, 10, 3, true, 'deploy-vps (r42): the container health check'),
  ('server.web-rollback', 'Go back to the previous build when the site stays unhealthy after a deploy', 'server', '^web_unhealthy$', '"recent_deploy": true', null, 'rollback_web', '{}', 20, 1, 60, 5, true, 'r50: the automatic rollback after a deploy'),
  ('server.disk', 'Free disk space when the disk is nearly full', 'server', '^disk_full$', null, null, 'free_disk', '{}', 10, 2, 60, 2, true, 'vps-health (0970): disk over 85%'),
  ('server.certs', 'Renew certificates that expire soon', 'server', '^cert_expiring$', null, null, 'renew_certs', '{}', 10, 2, 360, 10, true, 'r48 (3070) and r50 (5010): Origin CA and TURN certificates'),
  ('server.caddy', 'Restart Caddy when it is down', 'server', '^caddy_down$', null, null, 'restart_caddy', '{}', 10, 2, 10, 2, true, 'The VPS cutover (r42)'),
  ('server.livekit', 'Restart the media server when it is down', 'server', '^livekit_down$', null, null, 'restart_livekit', '{}', 10, 2, 10, 2, true, 'r50 (5010): the calls in the site'),
  ('server.db-connections', 'End idle database connections when they pile up', 'server', '^db_connections$', null, null, 'reset_db_connections', '{}', 10, 2, 15, 2, true, 'vps-health: connections near the limit'),
  ('cron.sequences', 'Repair id counters when a job fails with a duplicate key', 'cron', null, 'duplicate key value violates unique constraint', null, 'resync_sequences', '{}', 10, 1, 60, 2, true, 'The cutover day (0970): a sequence left at 1 made every audited write fail'),
  ('cron.rerun', 'Run a failed scheduled job again', 'cron', '^carmacars-', null, null, 'rerun_cron', '{}', 50, 2, 5, 2, true, '0075: a pg_cron run that could not start or failed once'),
  ('cron.booking-recovery', 'Run the booking recovery job when it failed', 'cron', '^carmacars-booking-recovery$', null, null, 'booking_recovery', '{}', 20, 1, 15, 2, true, '0062: the booking recovery job'),
  ('cron.release-locks', 'Release stale locks when a job fails on a lock', 'cron', null, '(lock|timeout|canceling statement)', null, 'release_locks', '{}', 30, 1, 30, 2, true, 'r50 photo loops: a step that kept failing blocked the others'),
  ('queue.outbox', 'Send stuck emails, texts and push notices again', 'queue', '^(notification_outbox|phone_outbox|push_outbox)$', null, 'stuck', 'requeue_outbox', '{}', 10, 2, 15, 3, true, 'Hotfix of November 6 (0530): the email backlog'),
  ('queue.backlog-restart', 'Restart the website when messages stop going out (it runs the senders)', 'queue', '^(notification_outbox_backlog|phone_outbox_backlog)$', null, null, 'restart_web', '{}', 20, 1, 60, 15, true, 'Hotfix of November 6 (0530): hiring emails were not going out'),
  ('queue.locks', 'Release job locks left behind', 'queue', '^job_locks$', null, null, 'release_locks', '{}', 10, 2, 15, 2, true, 'r50 photo loops (studio renders that never finished)'),
  ('queue.calendar', 'Read a failing calendar feed again', 'queue', '^calendar_feed$', null, null, 'calendar_resync', '{}', 10, 2, 60, 20, true, '0062: calendar sync recovery'),
  ('gsc.car-redirect', 'Redirect a missing car page to the closest live car', 'gsc', '^car_page$', null, null, 'gsc_redirect', '{}', 10, 2, 60, 2, true, '1860, 2420: Search Console 404s on old car pages'),
  ('gsc.server-errors', 'Restart the website when Google sees server errors', 'gsc', '^server_error$', null, null, 'restart_web', '{}', 50, 1, 360, 60, true, '4701: Google''s 5xx on car pages')
on conflict (key) do nothing;

-- ================================================================ 12. every minute
do $$
begin
  if to_regclass('cron.job') is not null then
    perform cron.schedule('carmacars-heal', '* * * * *', $q$select app.job_heal()$q$);
  end if;
end $$;

-- ================================================================ 13. grants
do $$
declare f record;
begin
  for f in select p.oid::regprocedure as sig from pg_proc p join pg_namespace n on n.oid = p.pronamespace
            where n.nspname = 'app' and p.proname = any (array['heal_is_money', 'heal_audit', 'heal_reporter', 'heal_signals', 'heal_run_action', 'heal_escalate',
              'heal_breaker', 'heal_settle', 'job_heal', 'heal_status', 'heal_playbook_toggle', 'heal_resolve', 'heal_save_fix', 'door_pre4800', 'api_call_pre4800',
              'heal_agent_tick', 'heal_agent_done', 'alert_entity_kind_pre4800']) loop
    execute format('revoke all on function %s from public, anon, authenticated', f.sig);
    execute format('grant execute on function %s to service_role', f.sig);
  end loop;
  if exists (select 1 from pg_roles where rolname = 'heal_agent') then
    grant usage on schema app to heal_agent;
    grant execute on function app.heal_agent_tick(jsonb) to heal_agent;
    grant execute on function app.heal_agent_done(jsonb) to heal_agent;
  end if;
end $$;
