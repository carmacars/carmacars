-- 99: R51 staff lines (migration 5301, REQ-132; docs/changes/2026-11-27-r51-staff.md). Each staff member's extension and own
-- Twilio line: the number is kept where no browser role reads it, an Admin sees the last 4 digits, a call to it rings only
-- that person, a missed call alerts them. No number is bought here: the purchase is recorded as the server would after an
-- Admin confirmed the price (server_staff_line_bought with a made-up number). Fixtures "sl51".
select test.suite('99 r51 staff lines: extensions, the hidden number, ringing one person, missed calls');

select test.mk_user('sl51_admin', 'admin');
select test.mk_user('sl51_fleet', 'va', 'fleet');     -- fleet: business calls do not ring them by default (2790)
select test.mk_user('sl51_cs', 'va', 'cs');
select test.mk_user('sl51_renter', 'renter');
create function pg_temp.dr(p_user text, p_call text, p_name text, p jsonb default '{}'::jsonb) returns jsonb language sql as
$$ select public.door(test.id(p_user), 'aal2', p_call, p_name, p) $$;
update program_settings set phone_browser_calls = true where id = (app.settings()).id;

-- ================================================================ 1. the extension
select test.eq('no extension yet: no line', pg_temp.dr('sl51_fleet', 'ops_read', 'my_line') ->> 'active', 'false');
select test.ok('Admin sets an extension (the next free from 1 when empty)',
  (pg_temp.dr('sl51_admin', 'admin_do', 'staff_line_set', jsonb_build_object('user_id', test.id('sl51_fleet'))) ->> 'extension') ~ '^[0-9]{1,4}$');
select test.eq('Admin sets a chosen extension', pg_temp.dr('sl51_admin', 'admin_do', 'staff_line_set', jsonb_build_object('user_id', test.id('sl51_fleet'), 'extension', '7051')) ->> 'extension', '7051');
select test.throws('an extension is someone else''s', $$select pg_temp.dr('sl51_admin', 'admin_do', 'staff_line_set', jsonb_build_object('user_id', test.id('sl51_cs'), 'extension', '7051'))$$, '%someone else%');
select test.throws('an extension is 1 to 4 digits', $$select pg_temp.dr('sl51_admin', 'admin_do', 'staff_line_set', jsonb_build_object('user_id', test.id('sl51_cs'), 'extension', '12a'))$$, '%1 to 4 digits%');
select test.throws('only staff get a line', $$select pg_temp.dr('sl51_admin', 'admin_do', 'staff_line_set', jsonb_build_object('user_id', test.id('sl51_renter')))$$, '%active staff%');
select test.throws('staff cannot set extensions', $$select app.staff_line_set(test.id('sl51_cs'), jsonb_build_object('user_id', test.id('sl51_cs')))$$);

-- ================================================================ 2. the purchase (recorded as the server does after the Admin confirmed)
select test.eq('the server checks before Twilio: an Admin, an extension, no live line',
  (select (x ->> 'extension') || '/' || (x ->> 'area_code') from (select public.server_staff_line_check(test.id('sl51_admin'), test.id('sl51_fleet')) x) q), '7051/647');
select test.throws('only an Admin buys', $$select public.server_staff_line_check(test.id('sl51_cs'), test.id('sl51_fleet'))$$);
select test.throws('no extension, no purchase', $$select public.server_staff_line_check(test.id('sl51_admin'), test.id('sl51_cs'))$$, '%extension first%');
select test.eq('recorded', public.server_staff_line_bought(jsonb_build_object('by', test.id('sl51_admin'), 'user_id', test.id('sl51_fleet'), 'number', '+16475550771',
  'sid', 'PN' || repeat('a', 32), 'monthly_cents', 115, 'currency', 'USD')) ->> 'line', 'Ext 7051, number ending 0771');
select test.throws('one line a person', $$select public.server_staff_line_check(test.id('sl51_admin'), test.id('sl51_fleet'))$$, '%already has a line%');
select test.eq('the person sees their extension, never the number',
  (select (x ->> 'extension') || '/' || (x ->> 'active') || '/' || (x::text like '%0771%') from (select pg_temp.dr('sl51_fleet', 'ops_read', 'my_line') x) q), '7051/true/false');
select test.eq('Admin sees the last 4 digits only, with the cost',
  (select (x -> test.id('sl51_fleet')::text ->> 'words') || '/' || (x -> test.id('sl51_fleet')::text ->> 'monthly_cents') || '/' || (x::text like '%6475550771%')
     from (select pg_temp.dr('sl51_admin', 'admin_read', 'staff_lines') x) q), 'Ext 7051, number ending 0771/115/false');
select test.eq('no browser role reads the number', has_table_privilege('authenticated', 'staff_phone_line_secrets', 'select'), false);
select test.eq('row-level security is on for the number', (select relrowsecurity from pg_class where oid = 'staff_phone_line_secrets'::regclass), true);
select test.eq('the person is told their line is ready',
  (select payload ->> 'assigned_to' from app_events where payload ->> 'rule' = 'staff_line_ready' and entity_id = test.id('sl51_fleet') order by id desc limit 1), test.id('sl51_fleet')::text);
select test.ok('the purchase is in the audit log, without the number',
  exists (select 1 from audit_log where action = 'staff_line_bought' and entity_id = test.id('sl51_fleet')::text and after::text not like '%6475550771%'));

-- ================================================================ 3. ringing
-- fleet is not in phone_inbound_ring: before 5301 their phone did not take incoming calls; with a line it does
select test.eq('a person with a line: their phone takes incoming calls', (public.server_voice_presence(test.id('sl51_fleet'), '{"online": true}') ->> 'ring')::boolean, true);
select public.server_voice_presence(test.id('sl51_cs'), '{"online": true}');
select test.eq('a call to the line rings only that person, named as their line',
  (select string_agg(x ->> 'identity', ',') || '|' || bool_and(x ->> 'who' like '%(your line, ext 7051)')
     from jsonb_array_elements(public.server_voice_ring('{"from": "+16475550199", "to": "+16475550771"}') -> 'ring') x),
  'staff_' || replace(test.id('sl51_fleet')::text, '-', '') || '|true');
select test.eq('the line''s answer says it is a line and has no forward', (select (x ->> 'line') || '/' || coalesce(x ->> 'forward_to', 'none') from (select public.server_voice_ring('{"to": "+16475550771"}') x) q), 'true/none');
select test.ok('a call to the business number does not ring the fleet line holder',
  not exists (select 1 from jsonb_array_elements(public.server_voice_ring('{"from": "+16475550199"}') -> 'ring') x where x ->> 'identity' = 'staff_' || replace(test.id('sl51_fleet')::text, '-', '')));
update voice_presence set seen_at = now() - interval '10 minutes' where user_id = test.id('sl51_fleet');
select test.eq('not online: nobody rings (the line''s message follows)', jsonb_array_length(public.server_voice_ring('{"to": "+16475550771"}') -> 'ring'), 0);

-- ================================================================ 4. a missed call
select test.eq('missed: the line answers with its message', public.server_staff_line_missed('{"to": "+16475550771", "from": "+16475550199", "call_sid": "CA0001"}') ->> 'line', 'true');
select test.eq('missed: the person gets the urgent alert, the caller''s number masked or named as they may see it',
  (select code || '/' || (payload ->> 'assigned_to') || '/' || (payload ->> 'alert_title') from app_events where payload ->> 'rule' = 'staff_line_missed' order by id desc limit 1),
  'staff_alert_urgent/' || test.id('sl51_fleet') || '/Missed call on your line (ext 7051)');
select test.eq('the business number is not a line', public.server_staff_line_missed('{"to": "+16475550000"}') ->> 'line', 'false');

-- ================================================================ 5. release
select test.eq('the server gets Twilio''s id to release (never the number)', public.server_staff_line_sid(test.id('sl51_admin'), test.id('sl51_fleet')), 'PN' || repeat('a', 32));
select test.eq('released', public.server_staff_line_released(jsonb_build_object('by', test.id('sl51_admin'), 'user_id', test.id('sl51_fleet'))) ->> 'line', 'Ext 7051, number released');
select test.eq('released: the number is gone from the database', (select count(*) from staff_phone_line_secrets where user_id = test.id('sl51_fleet')), 0::bigint);
select test.eq('released: calls to it ring nobody', public.server_voice_ring('{"to": "+16475550771"}') ->> 'line', null::text);
select test.eq('Quo step: recorded', pg_temp.dr('sl51_admin', 'admin_do', 'staff_line_quo_done', jsonb_build_object('user_id', test.id('sl51_fleet'))) ->> 'quo_added', 'true');
select test.eq('the browser roles cannot call the server functions',
  has_function_privilege('authenticated', 'public.server_staff_line_bought(jsonb)', 'execute') or has_function_privilege('anon', 'public.server_staff_line_missed(jsonb)', 'execute'), false);

-- this file's browsers go offline (a 99_ file leaves nothing another one counts)
delete from voice_presence where user_id in (test.id('sl51_fleet'), test.id('sl51_cs'));
