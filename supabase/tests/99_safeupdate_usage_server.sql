-- 99: migration 0194 (docs/changes/2026-10-30-self-hosted-usage-safeupdate.md). The production server runs pg_safeupdate
-- (an UPDATE or DELETE without a WHERE clause fails); it is not loaded here, so the functions are read instead: none
-- may update or delete without WHERE. The IndexNow sweep (claim and report, every path that writes its row) runs.
-- Settings > Usage speaks of our own server, not a Supabase plan, and the retired egress service is hidden.
select test.suite('99 safeupdate and the usage guard on our server');
select test.mk_user('safeupd194_admin', 'admin');

-- ================================================================ 1. every UPDATE and DELETE in a function says WHERE
-- comments and quoted text are left out; an "insert ... on conflict do update set" is not an UPDATE statement
select test.eq('pg_safeupdate: no function updates or deletes without a WHERE clause', (
  select coalesce(string_agg(distinct p.oid::regprocedure::text, ', '), '')
    from pg_proc p join pg_language l on l.oid = p.prolang
   cross join lateral regexp_matches(
       regexp_replace(regexp_replace(regexp_replace(p.prosrc, '--[^\n]*', '', 'g'), '/\*.*?\*/', '', 'g'), '''([^'']|'''')*''', '''''', 'g'),
       '(?:^|[;\s(])(?<!do )(update\s+(?:only\s+)?[a-z_][a-z0-9_.]*\s+(?:as\s+)?(?:[a-z_][a-z0-9_]*\s+)?set\s[^;]*|delete\s+from\s[^;]*)', 'gi') m
   where p.pronamespace in ('app'::regnamespace, 'public'::regnamespace) and l.lanname in ('plpgsql', 'sql')
     and m[1] !~* '\mwhere\M'), '');

-- ================================================================ 2. the IndexNow sweep runs
update indexnow_sweep set backoff_until = null, backoff_s = 0, file_i = 0, pos = -1, sent_today = 7, phase = 'priority', p_i = 0, p_pos = 0,
       day = (now() at time zone 'America/Toronto')::date - 1 where id;
update program_settings set indexnow_enabled = false where id = (app.settings()).id;
select test.eq('a new day: the claim resets the count, even with IndexNow off', app.server_indexnow_claim(10) ->> 'why', 'off');
select test.eq('the day and count of the new day', (select (day = (now() at time zone 'America/Toronto')::date) || '/' || sent_today from indexnow_sweep), 'true/0');
update program_settings set indexnow_enabled = true, indexnow_batch = 10000, indexnow_daily_max = 2000000 where id = (app.settings()).id;
create temp table c99 as select app.server_indexnow_claim(5) c;
select test.ok('the sweep hands out a batch with its cursor', (select jsonb_array_length(c -> 'paths') between 1 and 5 and c ? 'cursor' from c99));
select app.server_indexnow_report(jsonb_build_object('status', 200, 'count', 5, 'cursor', (select c -> 'cursor' from c99)));
select test.eq('a 2xx counts the addresses', (select sent_today from indexnow_sweep), 5);
create temp table r99 as select rounds from indexnow_sweep;
select app.server_indexnow_report(jsonb_build_object('status', 200, 'count', 1, 'files', 1, 'cursor', jsonb_build_object('phase', 'vehicles', 'file_i', 1, 'pos', 3)));
select test.eq('past the last file the next round starts', (select phase || '/' || file_i || '/' || pos || '/' || rounds from indexnow_sweep), 'priority/0/-1/' || (select rounds + 1 from r99));
select app.server_indexnow_report(jsonb_build_object('status', 500, 'error', 'down'));
select test.ok('a failure waits ten minutes', (select last_status = 500 and backoff_until between now() + interval '9 minutes' and now() + interval '11 minutes' from indexnow_sweep));
select test.eq('and the claim waits with it', app.server_indexnow_claim(5) ->> 'why', 'backing off');
update indexnow_sweep set backoff_until = null, backoff_s = 0, file_i = 0, pos = -1, sent_today = 0, phase = 'priority', p_i = 0, p_pos = 0 where id;
update program_settings set indexnow_enabled = false where id = (app.settings()).id;
drop table c99, r99;

-- ================================================================ 3. the usage guard on our server
select test.eq('the database and file storage are our server''s, no Supabase plan in any wording',
  (select string_agg(label, ' | ' order by sort) from usage_services where service in ('supabase_db', 'supabase_storage')), 'Database size (our server) | File storage (our server)');
select test.eq('no service mentions Supabase Pro or its free plan',
  (select count(*) from usage_services where concat_ws(' ', label, provider, price_text, upgrade_text, measured_by, when_used_up) ~* 'supabase pro|free (plan|database|project)' and service like 'supabase%'), 0::bigint);
select test.ok('the advice: clean up or a larger server disk', (select bool_and(upgrade_text like '%larger server disk%') from usage_services where service in ('supabase_db', 'supabase_storage')));
select test.eq('egress is retired: off', (select enabled from usage_services where service = 'supabase_egress'), false);
select test.ok('and left out of Settings > Usage', not exists (select 1 from jsonb_array_elements(app.usage_page(test.id('safeupd194_admin')) -> 'services') e where e ->> 'service' = 'supabase_egress')
  and exists (select 1 from jsonb_array_elements(app.usage_page(test.id('safeupd194_admin')) -> 'services') e where e ->> 'service' = 'supabase_db'));
update usage_services set included = 12 * 1073741824::numeric where service = 'supabase_db';
update program_settings set db_plan = 'free' where id = (app.settings()).id;
select test.eq('the import setting no longer rewrites the database allowance an Admin set', (select included from usage_services where service = 'supabase_db'), 12 * 1073741824::numeric);
update program_settings set db_plan = 'pro' where id = (app.settings()).id;
update usage_services set included = 8589934592 where service = 'supabase_db';
select test.ok('the alert email no longer names Supabase', (select trigger_text not ilike '%supabase%' from notification_catalogue where code = 'staff_usage_alert'));
