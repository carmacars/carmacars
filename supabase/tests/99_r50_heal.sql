-- 99_r50_heal: the self-healing engine (4800). Fixtures start with "heal". Each scenario has its own signal (an error spike on
-- its own page, the stripe site check, the heal agent's report) and its own test playbooks, so what the earlier files left
-- does not decide the results. The engine is driven with explicit times (app.job_heal(p_now)).
select test.suite('99 r50 self-healing');
select test.mk_user('heal_admin', 'admin');
select test.mk_user('heal_sales', 'va', 'sales');

create or replace function test.heal_errors(p_path text, p_n integer, p_kind text default 'crash', p_msg text default 'heal test boom') returns void
language sql as $$
  insert into client_errors (path, message, kind, ua, created_at) select p_path, p_msg, p_kind, 'heal-test', now() from generate_series(1, p_n)
$$;
create or replace function test.heal_inc(p_fp text) returns heal_incidents
language sql stable as $$ select * from heal_incidents where fingerprint = p_fp order by first_seen desc limit 1 $$;
create or replace function test.heal_book(p_key text, p_match text, p_action text, p_successes integer default 0, p_failures integer default 0) returns uuid
language sql as $$
  insert into heal_playbooks (key, title, source, match_key, action, successes, failures, max_attempts, cooldown_minutes, verify_minutes)
  values (p_key, 'Test ' || p_key, 'site_error', p_match, p_action, p_successes, p_failures, 1, 0, 2) returning id
$$;

-- ================================================================ the library and the whitelist
select test.ok('the library is seeded from the data health fixes, the recovery jobs and the past incidents',
  (select count(*) >= 20 and bool_and(builtin) and count(distinct source) = 7 from heal_playbooks where builtin));
select test.eq('every seeded fix uses a whitelisted action, and none is about money',
  (select count(*) from heal_playbooks p where not exists (select 1 from heal_actions a where a.key = p.action) or app.heal_is_money(p.source, p.key, p.title)), 0::bigint);
select test.throws('an action outside the whitelist cannot be saved in a playbook',
  $$insert into heal_playbooks (key, title, source, action) values ('test.bad', 'Bad', 'cron', 'refund_everyone')$$, 'foreign key');

-- ================================================================ 1. an incident opens, its playbook runs, the check heals it
select test.heal_book('test.heal-a', '^/heal-a$', 'resync_sequences', 5, 0);
select test.heal_errors('/heal-a', 15);
select app.job_heal(now());
select test.eq('1 an error spike opens one incident, and the matching fix runs',
  (select format('%s|%s|%s', i.status, i.attempts, (select p.key from heal_attempts a join heal_playbooks p on p.id = a.playbook_id where a.incident_id = i.id))
     from heal_incidents i where i.fingerprint = 'site_error:/heal-a'), 'healing|1|test.heal-a');
select app.job_heal(now() + interval '1 minute');
select test.eq('1 the check waits for the playbook''s time before it decides',
  (select count(*) from heal_attempts a join heal_incidents i on i.id = a.incident_id where i.fingerprint = 'site_error:/heal-a' and a.verified is null), 1::bigint);
delete from client_errors where path = '/heal-a';
select app.job_heal(now() + interval '3 minutes');
select test.eq('1 the problem is gone at the check: healed by the playbook, the attempt verified',
  (select format('%s|%s|%s', i.status, i.healed_by, (select a.verified from heal_attempts a where a.incident_id = i.id)) from heal_incidents i where i.fingerprint = 'site_error:/heal-a'),
  'healed|playbook|t');
select test.eq('1 the playbook counts the success', (select format('%s/%s', successes, consecutive_failures) from heal_playbooks where key = 'test.heal-a'), '6/0');
select test.eq('1 a healed incident is quiet: no To do, no bug report, no alert',
  (select format('%s|%s|%s', (select count(*) from tasks t where t.related_id = i.id), (select count(*) from bug_reports b where b.context ->> 'incident' = i.id::text),
                 (select count(*) from app_events e where e.entity_id = i.id))
     from heal_incidents i where i.fingerprint = 'site_error:/heal-a'), '0|0|0');
select test.ok('1 every step is in the audit log',
  (select count(distinct a.action) = 3 from audit_log a where a.action in ('heal_incident_opened', 'heal_attempt', 'heal_attempt_cleared')
     and (a.entity_id = (test.heal_inc('site_error:/heal-a')).id::text or a.after ->> 'incident' = (test.heal_inc('site_error:/heal-a')).id::text)));

-- ================================================================ 2. a failing fix moves to the next one, then escalates exactly once
select test.heal_book('test.heal-b1', '^/heal-b$', 'resync_sequences', 3, 0);
select test.heal_book('test.heal-b2', '^/heal-b$', 'resync_sequences', 1, 0);
select test.heal_errors('/heal-b', 15);
select app.job_heal(now());
select test.eq('2 the fix with the best success rate goes first',
  (select string_agg(p.key, ',' order by a.started_at) from heal_attempts a join heal_playbooks p on p.id = a.playbook_id where a.incident_id = (test.heal_inc('site_error:/heal-b')).id),
  'test.heal-b1');
select app.job_heal(now() + interval '3 minutes');
select test.eq('2 still there at the check: the next fix runs',
  (select string_agg(p.key || ':' || coalesce(a.verified::text, 'pending'), ',' order by a.started_at) from heal_attempts a join heal_playbooks p on p.id = a.playbook_id
    where a.incident_id = (test.heal_inc('site_error:/heal-b')).id), 'test.heal-b1:false,test.heal-b2:pending');
select app.job_heal(now() + interval '6 minutes');
select test.eq('2 every fix tried: escalated',
  (select format('%s|%s|%s', status, attempts, escalation_reason is not null) from heal_incidents where fingerprint = 'site_error:/heal-b'), 'escalated|2|t');
select app.job_heal(now() + interval '9 minutes');
select app.job_heal(now() + interval '12 minutes');
select test.eq('2 one escalation only: one To do, one bug report with the evidence, one Admin alert, however many ticks',
  (select format('%s|%s|%s', (select count(*) from tasks t where t.related_table = 'heal_incidents' and t.related_id = i.id),
                 (select count(*) from bug_reports b where b.context ->> 'incident' = i.id::text and b.context -> 'evidence' ->> 'count' = '15'),
                 (select count(*) from app_events e where e.entity_id = i.id and e.payload ->> 'rule' = 'self_heal_escalated'))
     from heal_incidents i where i.fingerprint = 'site_error:/heal-b'), '1|1|1');
select test.eq('2 the To do and the bug report point at the incident',
  (select (t.queue = 'admin' and t.priority = 'high' and t.id = i.todo_id) and b.id = i.bug_report_id and b.happened like 'Self-healing incident #%'
     from heal_incidents i join tasks t on t.id = i.todo_id join bug_reports b on b.id = i.bug_report_id where i.fingerprint = 'site_error:/heal-b'), true);
select test.eq('2 the failing fix counts its failure', (select format('%s/%s', failures, consecutive_failures) from heal_playbooks where key = 'test.heal-b1'), '1/1');

-- the Admin resolves it with "Save as fix": a new playbook from a whitelisted action, the incident healed by staff, the To do done
select test.throws('2 Save as fix takes only a whitelisted action',
  format($$select app.heal_save_fix(%L, jsonb_build_object('incident', %L, 'action', 'drop_database'))$$, test.id('heal_admin'), (test.heal_inc('site_error:/heal-b')).id), 'listed actions');
select app.heal_save_fix(test.id('heal_admin'), jsonb_build_object('incident', (test.heal_inc('site_error:/heal-b')).id, 'action', 'release_locks', 'title', 'Release locks on heal-b', 'note', 'Released the locks by hand'));
select test.eq('2 the fix is in the library with the incident''s signature',
  (select format('%s|%s|%s|%s', source, match_key, action, created_by = test.id('heal_admin')) from heal_playbooks where title = 'Release locks on heal-b'),
  'site_error|^/heal-b$|release_locks|t');
select test.eq('2 the incident is resolved by staff and its To do is done',
  (select format('%s|%s|%s', i.status, i.healed_by, t.status) from heal_incidents i join tasks t on t.id = i.todo_id where i.fingerprint = 'site_error:/heal-b'), 'healed|staff|done');
delete from client_errors where path = '/heal-b';

-- ================================================================ 3. the circuit breaker
select test.heal_book('test.heal-c', '^/heal-c$', 'resync_sequences', 0, 3);
update heal_playbooks set consecutive_failures = 3 where key = 'test.heal-c';
select test.heal_errors('/heal-c', 15);
select app.job_heal(now());
select app.job_heal(now() + interval '3 minutes');
select test.eq('3 a fix failing four times in a row switches itself off',
  (select format('%s|%s|%s', enabled, consecutive_failures, disabled_reason like '%circuit breaker%') from heal_playbooks where key = 'test.heal-c'), 'f|4|t');
select test.eq('3 ...and escalates once: one alert and one To do for the fix',
  (select format('%s|%s', (select count(*) from app_events e where e.entity_id = p.id and e.payload ->> 'rule' = 'self_heal_breaker'),
                 (select count(*) from tasks t where t.related_table = 'heal_playbooks' and t.related_id = p.id)) from heal_playbooks p where p.key = 'test.heal-c'), '1|1');
select test.eq('3 the incident it was fixing has no fix left: escalated',
  (test.heal_inc('site_error:/heal-c')).status, 'escalated');
select app.job_heal(now() + interval '6 minutes');
select test.eq('3 a switched-off fix never runs again', (select count(*) from heal_attempts a join heal_playbooks p on p.id = a.playbook_id where p.key = 'test.heal-c'), 1::bigint);
select app.heal_playbook_toggle(test.id('heal_admin'), jsonb_build_object('id', (select id from heal_playbooks where key = 'test.heal-c'), 'enabled', true));
select test.eq('3 an Admin switches it on again with a clean count',
  (select format('%s|%s|%s', enabled, consecutive_failures, disabled_reason is null) from heal_playbooks where key = 'test.heal-c'), 't|0|t');
delete from client_errors where path = '/heal-c';

-- ================================================================ 4. money is never fixed automatically
insert into heal_playbooks (key, title, source, match_key, action, successes) values ('test.heal-money', 'Recheck Stripe', 'uptime', '^stripe$', 'uptime_recheck', 50);
create temp table heal_stripe as select status, consecutive_failures from uptime_checks where key = 'stripe';
update uptime_checks set status = 'failing', consecutive_failures = 3, enabled = true, last_detail = 'Stripe webhooks failing' where key = 'stripe';
select app.job_heal(now());
select test.eq('4 a money problem is escalated at once, with no attempt, even with a matching fix',
  (select format('%s|%s|%s', status, money, attempts) from heal_incidents where fingerprint = 'uptime:stripe'), 'escalated|t|0');
select test.eq('4 the matching fix never ran', (select count(*) from heal_attempts a join heal_playbooks p on p.id = a.playbook_id where p.key = 'test.heal-money'), 0::bigint);
select test.throws('4 no action runs on a money incident',
  $$select app.heal_run_action('resync_sequences', '{}', test.heal_inc('uptime:stripe'))$$, 'Money is never fixed automatically');
select test.ok('4 money jobs and checks are recognised',
  app.heal_is_money('cron', 'carmacars-deposits-due', null) and app.heal_is_money('cron', 'carmacars-owner-invoices', null) and app.heal_is_money('uptime', 'stripe', null)
  and app.heal_is_money('data_health', 'unmatched_payments', null) and not app.heal_is_money('cron', 'carmacars-uptime', 'select app.job_uptime()'));
select test.throws('4 Save as fix refuses a money incident',
  format($$select app.heal_save_fix(%L, jsonb_build_object('incident', %L, 'action', 'uptime_recheck'))$$, test.id('heal_admin'), (test.heal_inc('uptime:stripe')).id), 'money');
update uptime_checks u set status = s.status, consecutive_failures = s.consecutive_failures from heal_stripe s where u.key = 'stripe';
select app.job_heal(now() + interval '1 minute');
select test.eq('4 cleared on its own: closed, with its To do', (select format('%s|%s', i.status, t.status) from heal_incidents i join tasks t on t.id = i.todo_id where i.fingerprint = 'uptime:stripe'), 'healed|done');

-- ================================================================ 5. the server: the heal agent's report, a queued action, its answer
select app.heal_agent_tick('{"web_tag": "abc1234", "previous_tag": "abc0001", "web_health": "healthy", "disk_pct": "93", "problems": [{"key": "disk_full", "title": "The disk is 93% full", "detail": "93%", "state": "full"}]}');
select app.job_heal(now());
select test.eq('5 the report opens a server incident and queues the whitelisted server action',
  (select format('%s|%s|%s', i.status, r.action, r.status) from heal_incidents i join heal_attempts a on a.incident_id = i.id join heal_requests r on r.attempt_id = a.id
    where i.fingerprint = 'server:disk_full'), 'healing|free_disk|pending');
select test.eq('5 the agent claims it on its next report',
  (select count(*) filter (where x ->> 'action' = 'free_disk') from jsonb_array_elements(app.heal_agent_tick('{"web_tag": "abc1234", "disk_pct": "93", "problems": [{"key": "disk_full", "state": "full"}]}') -> 'actions') x), 1::bigint);
select app.heal_agent_done(jsonb_build_object('id', (select r.id from heal_requests r where r.action = 'free_disk' and r.status = 'claimed' order by r.id desc limit 1), 'ok', true, 'result', 'disk 93% -> 61%'));
select app.heal_agent_tick('{"web_tag": "abc1234", "disk_pct": "61", "problems": []}');
select app.job_heal(now());
select app.job_heal(now() + interval '3 minutes');
select test.eq('5 the agent''s answer and the check after it heal the incident',
  (select format('%s|%s|%s', i.status, a.result, a.verified) from heal_incidents i join heal_attempts a on a.incident_id = i.id where i.fingerprint = 'server:disk_full'), 'healed|ok|t');
select test.ok('5 the agent''s role may report and answer, and nothing else',
  has_function_privilege('heal_agent', 'app.heal_agent_tick(jsonb)', 'execute') and has_function_privilege('heal_agent', 'app.heal_agent_done(jsonb)', 'execute')
  and not has_function_privilege('heal_agent', 'app.job_heal(timestamptz)', 'execute') and not has_function_privilege('heal_agent', 'app.heal_run_action(text, jsonb, heal_incidents, timestamptz)', 'execute')
  and not has_table_privilege('heal_agent', 'heal_incidents', 'select') and not has_table_privilege('heal_agent', 'bookings', 'select'));
select test.eq('5 an action the agent does not know is never handed out',
  (select count(*) from heal_actions where kind = 'server' and key not in ('restart_web', 'restart_caddy', 'restart_livekit', 'renew_certs', 'free_disk', 'reset_db_connections', 'rollback_web')), 0::bigint);
select app.heal_agent_tick('{"problems": []}');

-- ================================================================ 6. who may see and change it
select test.ok('6 the Admin reads incidents, the library and the server',
  (select jsonb_array_length(s -> 'playbooks') > 20 and jsonb_typeof(s -> 'incidents') = 'array' and s ? 'server' and s -> 'counts' ? 'escalated'
     from (select app.heal_status(test.id('heal_admin'), '{}') s) x));
select test.ok('6 an incident shows what was tried', (select bool_or(jsonb_array_length(i -> 'tried') = 2) from jsonb_array_elements(app.heal_status(test.id('heal_admin'), '{"limit": 200}') -> 'incidents') i));
select test.throws('6 a non-Admin cannot read it', format($$select app.heal_status(%L, '{}')$$, test.id('heal_sales')), 'Only an Admin');
select test.throws('6 ...nor through the door', format($$select app.door(%L, 'aal2', 'admin_read', 'heal_status', '{}')$$, test.id('heal_sales')), null);
select test.throws('6 a non-Admin cannot switch a fix', format($$select app.heal_playbook_toggle(%L, jsonb_build_object('id', %L, 'enabled', false))$$, test.id('heal_sales'),
  (select id from heal_playbooks where key = 'test.heal-a')), 'Only an Admin');
select test.throws('6 ...nor save one', format($$select app.heal_save_fix(%L, jsonb_build_object('incident', %L, 'action', 'release_locks'))$$, test.id('heal_sales'),
  (test.heal_inc('site_error:/heal-c')).id), 'Only an Admin');
select test.throws('6 ...nor resolve an incident', format($$select app.heal_resolve(%L, jsonb_build_object('incident', %L, 'note', 'x'))$$, test.id('heal_sales'),
  (test.heal_inc('site_error:/heal-c')).id), 'Only an Admin');
select test.eq('6 the door hands the Admin the read', (select app.door(test.id('heal_admin'), 'aal2', 'admin_read', 'heal_status', '{}') ? 'playbooks'), true);
select test.ok('6 browsers never call the engine or read the tables directly',
  not has_function_privilege('authenticated', 'app.job_heal(timestamptz)', 'execute') and not has_function_privilege('anon', 'app.heal_status(uuid, jsonb)', 'execute')
  and not has_table_privilege('anon', 'heal_incidents', 'select') and not has_table_privilege('authenticated', 'heal_playbooks', 'update'));
select test.lives('6 the Admin resolves what is left', format($$select app.heal_resolve(%L, jsonb_build_object('incident', %L, 'note', 'Test done'))$$, test.id('heal_admin'),
  (test.heal_inc('site_error:/heal-c')).id));

-- the test playbooks leave the library (their attempts keep their history)
delete from heal_playbooks where key like 'test.heal-%' or created_by = test.id('heal_admin');
