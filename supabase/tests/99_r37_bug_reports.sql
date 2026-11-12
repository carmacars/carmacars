-- 99: release 37 (migration 2340): bug reports from staff. Who may report (office staff, field staff, an Admin; not a
-- renter), the rules of a report (30 characters, a severity, screenshots only in its own folder, no query string),
-- row level security (staff insert and read their own, an Admin every one), the Admin's triage, the alert at once for
-- "blocks work" and the morning digest for the rest, the crashes of the person linked, and the connector's three tools
-- (scope, Admin only, preview then confirm, logged). Fixtures start with "r37b"; addresses are example.test.
select test.suite('99 r37 bug reports (2340)');
create temp table r37b_ps as select id, api_access_enabled e, api_calls_per_minute n from program_settings;
update program_settings set api_access_enabled = true, api_calls_per_minute = 600 where id is not null;

select test.mk_user('r37b_admin', 'admin');
select test.mk_user('r37b_cs', 'va', 'cs');
select test.mk_user('r37b_fin', 'va', 'finance');
select test.mk_user('r37b_field', 'field');
select test.mk_user('r37b_renter', 'renter');
create function pg_temp.dr(p_user text, p_call text, p_name text, p jsonb) returns jsonb language sql as
$$ select public.door(test.id(p_user), 'aal2', p_call, p_name, p) $$;
create function pg_temp.rep(p_sev text, p_extra jsonb default '{}'::jsonb) returns jsonb language sql as
$$ select jsonb_build_object('happened', 'The Save button on the booking page does nothing when I press it.', 'severity', p_sev,
     'page_path', '/staff/bookings/CC-1', 'portal', 'staff', 'context', jsonb_build_object('viewport', '1280x800', 'build', '2340'),
     'client_logs', jsonb_build_array(jsonb_build_object('kind', 'fetch', 'msg', '500', 'url', '/api/rpc', 'status', 500))) || p_extra $$;

-- ================================================================ 1. who may report, and the rules
select test.throws('a renter cannot report', $$select pg_temp.dr('r37b_renter', 'ops_do', 'bug_report_create', pg_temp.rep('annoying'))$$, 'for staff');
select test.throws('what happened needs 30 characters', $$select pg_temp.dr('r37b_cs', 'ops_do', 'bug_report_create', pg_temp.rep('annoying', '{"happened": "It broke."}'))$$, '30 characters');
select test.throws('a severity is required', $$select pg_temp.dr('r37b_cs', 'ops_do', 'bug_report_create', pg_temp.rep('urgent'))$$, 'blocks work');
select test.throws('a screenshot outside the report''s folder is refused',
  $$select pg_temp.dr('r37b_cs', 'ops_do', 'bug_report_create', pg_temp.rep('annoying', jsonb_build_object('id', gen_random_uuid(), 'screenshots', jsonb_build_array(jsonb_build_object('path', 'bug-reports/x/a.png', 'mime', 'image/png', 'bytes', 10)))))$$, 'folder');
select test.throws('a screenshot over 5 MB is refused',
  $$select pg_temp.dr('r37b_cs', 'ops_do', 'bug_report_create', pg_temp.rep('annoying', jsonb_build_object('id', '0b0e2f6a-1111-4222-8333-944455556666', 'screenshots', jsonb_build_array(jsonb_build_object('path', 'bug-reports/0b0e2f6a-1111-4222-8333-944455556666/0b0e2f6a-1111-4222-8333-944455556667.png', 'mime', 'image/png', 'bytes', 6000000)))))$$, '5 MB');

create temp table r37b_cs1 as select pg_temp.dr('r37b_cs', 'ops_do', 'bug_report_create', pg_temp.rep('annoying', jsonb_build_object('id', '0b0e2f6a-1111-4222-8333-944455556666', 'page_path', '/staff/leads?q=Someone&token=x',
  'screenshots', jsonb_build_array(jsonb_build_object('path', 'bug-reports/0b0e2f6a-1111-4222-8333-944455556666/0b0e2f6a-1111-4222-8333-944455556667.png', 'mime', 'image/png', 'bytes', 120000, 'kind', 'auto'))))) r;
select test.ok('customer service reports a bug: new, numbered BR-', (select r ->> 'status' = 'new' and r ->> 'number' like 'BR-%' and (r ->> 'screenshot_count')::int = 1 from r37b_cs1));
select test.eq('the page is kept without its query string', (select page_path from bug_reports where id = '0b0e2f6a-1111-4222-8333-944455556666'), '/staff/leads');
select test.ok('the reporter''s roles and function are attached', (select context -> 'roles' ? 'va' and context ->> 'va_function' = 'cs' and context ->> 'build' = '2340' from bug_reports where id = '0b0e2f6a-1111-4222-8333-944455556666'));
create temp table r37b_f1 as select pg_temp.dr('r37b_field', 'ops_do', 'bug_report_create', pg_temp.rep('cosmetic', '{"portal": "field", "page_path": "/staff/field"}')) r;
select test.ok('field staff report a bug too', (select r ->> 'status' = 'new' from r37b_f1));
create temp table r37b_u1 as select pg_temp.dr('r37b_fin', 'ops_do', 'bug_report_create', pg_temp.rep('blocks_work')) r;

-- ================================================================ 2. alerts
select test.ok('"blocks work" alerts the Admins at once (urgent staff alert)',
  exists (select 1 from app_events e where e.code = 'staff_alert_urgent' and e.payload ->> 'rule' = 'staff_bug_report_urgent' and e.entity_id = (select (r ->> 'id')::uuid from r37b_u1)));
select test.ok('an annoying bug waits for the Admins'' morning digest, not an alert',
  exists (select 1 from staff_digest_items d where d.role = 'admin' and d.digest_slot = 'morning' and d.entity_id = '0b0e2f6a-1111-4222-8333-944455556666')
  and not exists (select 1 from app_events e where e.payload ->> 'rule' = 'staff_bug_report_urgent' and e.entity_id = '0b0e2f6a-1111-4222-8333-944455556666'));
select test.ok('the urgent one is not also in the digest', not exists (select 1 from staff_digest_items d where d.entity_id = (select (r ->> 'id')::uuid from r37b_u1)));

-- ================================================================ 3. reading: own or Admin
select test.eq('staff list only their own reports', (select jsonb_array_length(pg_temp.dr('r37b_cs', 'ops_read', 'bug_reports', '{}') -> 'reports')), 1);
select test.throws('staff cannot open another person''s report', (select format($$select pg_temp.dr('r37b_cs', 'ops_read', 'bug_reports', jsonb_build_object('id', %L))$$, r ->> 'id') from r37b_u1), 'No such bug report');
select test.ok('staff open their own (without the server''s errors)', (select not (x ? 'server_errors') and x ->> 'happened' like 'The Save button%' from (select pg_temp.dr('r37b_cs', 'ops_read', 'bug_reports', '{"id": "0b0e2f6a-1111-4222-8333-944455556666"}') x) q));
select test.ok('an Admin lists every report', (select jsonb_array_length(pg_temp.dr('r37b_admin', 'ops_read', 'bug_reports', '{}') -> 'reports') >= 3));
-- a crash in the reporter's browser (client_errors keeps who was signed in)
select public.server_client_error(jsonb_build_object('message', 'r37b TypeError: x is undefined', 'path', '/staff/leads', 'user_id', test.id('r37b_cs')));
select test.ok('the crash is kept with the person', exists (select 1 from client_errors where message = 'r37b TypeError: x is undefined' and user_id = test.id('r37b_cs')));
select test.ok('an Admin opens a report with the person''s crashes and the page''s', (select x #>> '{server_errors,client_errors_of_reporter,0,message}' = 'r37b TypeError: x is undefined'
  and jsonb_array_length(x #> '{server_errors,client_errors_on_page}') >= 1 and jsonb_array_length(x -> 'client_logs') = 1
  from (select pg_temp.dr('r37b_admin', 'ops_read', 'bug_reports', '{"id": "0b0e2f6a-1111-4222-8333-944455556666"}') x) q));
select test.ok('an Admin opens it by its number too', (select (pg_temp.dr('r37b_admin', 'ops_read', 'bug_reports', jsonb_build_object('id', r ->> 'number')) ->> 'id') = r ->> 'id' from r37b_cs1));

-- ================================================================ 4. triage: Admin only
select test.throws('staff cannot change a report''s status', $$select pg_temp.dr('r37b_cs', 'ops_do', 'bug_report_update', '{"id": "0b0e2f6a-1111-4222-8333-944455556666", "status": "fixed"}')$$, 'An Admin');
select test.throws('an unknown status is refused', $$select pg_temp.dr('r37b_admin', 'ops_do', 'bug_report_update', '{"id": "0b0e2f6a-1111-4222-8333-944455556666", "status": "done"}')$$, 'status');
select test.ok('an Admin marks it fixed in a release with a note', (select x ->> 'status' = 'fixed' and x ->> 'fixed_in' = 'r37' and x ->> 'admin_notes' like '%Save handler fixed%'
  from (select pg_temp.dr('r37b_admin', 'ops_do', 'bug_report_update', '{"id": "0b0e2f6a-1111-4222-8333-944455556666", "status": "fixed", "note": "Save handler fixed", "fixed_in": "r37"}') x) q));
select test.eq('the reporter sees the new status on their list', (select pg_temp.dr('r37b_cs', 'ops_read', 'bug_reports', '{}') #>> '{reports,0,status}'), 'fixed');

-- ================================================================ 5. row level security for a signed-in session
select test.login(test.id('r37b_cs'));
select test.eq('RLS: staff see their own row only', test.visible('select 1 from bug_reports'), 1::bigint);
select test.eq('RLS: staff cannot update their report', test.affected($$update bug_reports set status = 'wont_fix'$$), 0::bigint);
select test.logout();
select test.login(test.id('r37b_admin'));
select test.ok('RLS: an Admin sees every row', test.visible('select 1 from bug_reports') >= 3);
select test.logout();
select test.login(test.id('r37b_renter'));
select test.eq('RLS: a renter sees none', test.visible('select 1 from bug_reports'), 0::bigint);
select test.throws('RLS: a renter cannot insert', $$insert into bug_reports (reporter_id, happened, severity, page_path) values (test.id('r37b_renter'), 'The totals on the money page are off by one cent today.', 'cosmetic', '/staff/money')$$, 'row-level security');
select test.logout();
select test.login(test.id('r37b_fin'));
select test.lives('RLS: staff insert their own report', $$insert into bug_reports (reporter_id, happened, severity, page_path) values (test.id('r37b_fin'), 'The totals on the money page are off by one cent today.', 'cosmetic', '/staff/money')$$);
select test.throws('RLS: staff cannot insert as someone else', $$insert into bug_reports (reporter_id, happened, severity, page_path) values (test.id('r37b_cs'), 'The totals on the money page are off by one cent today.', 'cosmetic', '/staff/money')$$, 'row-level security');
select test.throws('RLS: staff cannot set a status themselves', $$insert into bug_reports (reporter_id, happened, severity, page_path, status) values (test.id('r37b_fin'), 'The totals on the money page are off by one cent today.', 'cosmetic', '/staff/money', 'fixed')$$, 'row-level security');
select test.logout();

-- ================================================================ 6. the connector
create function test.r37b_h(p text) returns text language sql as $$ select encode(sha256(convert_to(p, 'UTF8')), 'hex') $$;
select app.api_key_create(test.id('r37b_admin'), test.id('r37b_admin'), 'Laptop', array['admin:read', 'admin:write'], test.r37b_h('cc_live_r37b_full'), 'cc_live_r37b');
select app.api_key_create(test.id('r37b_admin'), test.id('r37b_admin'), 'Bookings', array['bookings:read'], test.r37b_h('cc_live_r37b_book'), 'cc_live_r37k');
insert into api_keys (user_id, kind, name, prefix, key_hash, scopes, created_by)
select test.id('r37b_cs'), kind, 'Not allowed', 'cc_live_r37c', test.r37b_h('cc_live_r37b_cs'), scopes, test.id('r37b_admin') from api_keys where key_hash = test.r37b_h('cc_live_r37b_full');
create function test.r37b(p_key text, p_tool text, a jsonb) returns jsonb language sql as $$ select app.api_call(test.r37b_h(p_key), p_tool, a, 'test') $$;

select test.eq('connector: a key without admin:read is refused', test.r37b('cc_live_r37b_book', 'bug_reports_list', '{}') ->> 'status', '403');
select test.eq('connector: a staff member''s key is refused (Admins only)', test.r37b('cc_live_r37b_cs', 'bug_report_get', '{"id": "0b0e2f6a-1111-4222-8333-944455556666"}') ->> 'status', '403');
select test.ok('connector: bug_reports_list gives the open ones by default', (select (x ->> 'ok')::boolean and not exists (select 1 from jsonb_array_elements(x #> '{result,reports}') r where r ->> 'status' in ('fixed', 'wont_fix'))
  and jsonb_array_length(x #> '{result,reports}') >= 2 from (select test.r37b('cc_live_r37b_full', 'bug_reports_list', '{}') x) q));
select test.eq('connector: since filters by time', jsonb_array_length(test.r37b('cc_live_r37b_full', 'bug_reports_list', jsonb_build_object('status', 'new', 'since', now() + interval '1 hour')) #> '{result,reports}'), 0);
select test.ok('connector: bug_report_get gives the text, context, logs, screenshot paths and the server''s errors',
  (select x #>> '{result,happened}' like 'The Save button%' and x #>> '{result,screenshots,0,path}' like 'bug-reports/%' and x #> '{result,server_errors}' is not null
     and x #>> '{result,context,viewport}' = '1280x800' from (select test.r37b('cc_live_r37b_full', 'bug_report_get', '{"id": "0b0e2f6a-1111-4222-8333-944455556666"}') x) q));
select test.ok('connector: reads are logged', exists (select 1 from api_calls where tool = 'bug_report_get' and ok and user_id = test.id('r37b_admin')));
create temp table r37b_pv as select test.r37b('cc_live_r37b_full', 'bug_report_update', '{"id": "0b0e2f6a-1111-4222-8333-944455556666", "status": "triaged", "note": "Looking"}') x;
select test.ok('connector: bug_report_update previews and changes nothing', (select (x #>> '{result,preview}')::boolean from r37b_pv) and (select status from bug_reports where id = '0b0e2f6a-1111-4222-8333-944455556666') = 'fixed');
select test.eq('connector: a bad status fails at the preview', test.r37b('cc_live_r37b_full', 'bug_report_update', '{"id": "0b0e2f6a-1111-4222-8333-944455556666", "status": "gone"}') ->> 'status', '400');
select test.eq('connector: a read-only key cannot update', test.r37b('cc_live_r37b_book', 'bug_report_update', '{"id": "0b0e2f6a-1111-4222-8333-944455556666", "status": "triaged"}') ->> 'status', '403');
select test.ok('connector: confirmed, it changes the status',
  (select (x #>> '{result,done}')::boolean and x #>> '{result,status}' = 'triaged'
     from (select test.r37b('cc_live_r37b_full', 'bug_report_update', '{"id": "0b0e2f6a-1111-4222-8333-944455556666", "status": "triaged", "note": "Looking", "confirm": true}'::jsonb || jsonb_build_object('preview_id', x #>> '{result,preview_id}')) x from r37b_pv) q));
select test.ok('connector: the change is logged with before and after', exists (select 1 from api_calls where tool = 'bug_report_update' and before ->> 'status' = 'fixed' and after ->> 'status' = 'triaged'));
select test.eq('connector: a preview is used once', (select test.r37b('cc_live_r37b_full', 'bug_report_update', '{"id": "0b0e2f6a-1111-4222-8333-944455556666", "status": "triaged", "note": "Looking", "confirm": true}'::jsonb || jsonb_build_object('preview_id', x #>> '{result,preview_id}')) ->> 'error' from r37b_pv), 'This preview was already used: preview again');

select test.ok('the table is closed to anonymous visitors', not has_table_privilege('anon', 'bug_reports', 'select'));
select test.ok('the report functions are for the server only', not has_function_privilege('authenticated', 'app.bug_report_create(uuid, jsonb)', 'execute'));
update program_settings p set api_access_enabled = s.e, api_calls_per_minute = s.n from r37b_ps s where s.id = p.id;
