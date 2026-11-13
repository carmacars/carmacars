-- 99: release 44, part A (migration 2790). Calls in the browser: who may call, who rings for a call to the business
-- number and how they are shown the caller, a browser call kept for its staff member only; the hiring defaults; and a
-- person who works in Sales only reads, from their own session, only their own leads.
select test.suite('99 r44 calls a');

select test.mk_user('r44a_admin', 'admin');
select test.mk_user('r44a_cs', 'va', 'cs');
select test.mk_user('r44a_sales', 'va', 'sales');
select test.mk_user('r44a_sales2', 'va', 'sales');
select test.mk_user('r44a_fleet', 'va', 'fleet');
select test.mk_user('r44a_field', 'field');
select test.mk_renter('r44a_renter');

-- ================================================================ settings
select test.eq('calls in the browser are on, the own-mobile way is off, no forward number, cs and sales ring',
  (select phone_browser_calls::text || '/' || phone_call_own_mobile || '/' || phone_inbound_forward_number || '/' || phone_inbound_ring from program_settings limit 1),
  'true/false//cs, sales');
select test.eq('the AI interview decides by itself', (select bool_and(hiring_ai_auto_decide) from program_settings), true);
select test.throws('a forward number must be E.164', $$update program_settings set phone_inbound_forward_number = '647-555-0100'$$);
select test.throws('whose browser rings: only known roles', $$update program_settings set phone_inbound_ring = 'everyone'$$);

-- ================================================================ presence and ringing
select test.eq('Sales rings and is marked online', (public.server_voice_presence(test.id('r44a_sales'), '{"online": true}') ->> 'ring')::boolean, true);
select test.eq('customer service rings', (public.server_voice_presence(test.id('r44a_cs'), '{}') ->> 'ring')::boolean, true);
select test.eq('fleet may call but does not ring by default', public.server_voice_presence(test.id('r44a_fleet'), '{}') ->> 'ring', 'false');
select test.eq('field staff may call (a token), and do not ring', public.server_voice_presence(test.id('r44a_field'), '{}') ->> 'calls', 'true');
select test.throws('a renter has no phone', $$select public.server_voice_presence(test.id('r44a_renter'), '{}')$$, '%staff%');
select test.eq('only the people who ring are kept online', (select count(*) from voice_presence where user_id in (test.id('r44a_fleet'), test.id('r44a_field'))), 0::bigint);

select test.eq('a call to the business number rings Sales and customer service, the browsers online',
  (select string_agg(x ->> 'identity', ',' order by x ->> 'identity') from jsonb_array_elements(public.server_voice_ring('{"from": "+16475550144"}') -> 'ring') x),
  (select string_agg(i, ',' order by i) from unnest(array['staff_' || replace(test.id('r44a_sales')::text, '-', ''), 'staff_' || replace(test.id('r44a_cs')::text, '-', '')]) i));
select test.eq('Sales is shown the caller''s number masked; customer service in full',
  (select string_agg(x ->> 'who', '|' order by x ->> 'who') from jsonb_array_elements(public.server_voice_ring('{"from": "+16475550144"}') -> 'ring') x),
  '(647) ' || repeat(chr(8226), 3) || '-' || repeat(chr(8226), 2) || '44|647-555-0144');
update voice_presence set seen_at = now() - interval '3 minutes' where user_id = test.id('r44a_cs');
select test.eq('a browser not seen for 2 minutes does not ring', jsonb_array_length(public.server_voice_ring('{"from": "+16475550144"}') -> 'ring'), 1);
select public.server_voice_presence(test.id('r44a_sales'), '{"online": false}');
select test.eq('a closed page does not ring; nobody online is said (the no-answer way)',
  (public.server_voice_ring('{"from": "+16475550144"}') -> 'ring')::text || '/' || (public.server_voice_ring('{}') ->> 'enabled'), '[]/true');

-- ================================================================ a call placed in the browser
create temporary table r44a_call as select (public.server_twilio_browser_call_start(jsonb_build_object('user_id', test.id('r44a_field'), 'number', '(416) 555-0187')) ->> 'id')::uuid as id;
select test.eq('field staff place a call in the browser with no mobile of their own on file',
  (select c.via || '/' || c.staff_number || '/' || c.status from outbound_calls c join r44a_call x on x.id = c.id), 'browser/browser/starting');
select test.eq('the client webhook gets the number only for the staff member who started the call',
  (select (public.server_twilio_browser_call_get(c.id, test.id('r44a_field')) ->> 'to') || '/' || coalesce(public.server_twilio_browser_call_get(c.id, test.id('r44a_sales'))::text, 'none')
     from outbound_calls c join r44a_call x on x.id = c.id),
  '+14165550187/none');
select test.eq('Sales is told who they call masked, never the number',
  public.server_twilio_browser_call_start(jsonb_build_object('user_id', test.id('r44a_sales'), 'number', '+14165550188')) ->> 'who',
  '(416) ' || repeat(chr(8226), 3) || '-' || repeat(chr(8226), 2) || '88');
select test.throws('a renter cannot place a call', $$select public.server_twilio_browser_call_start(jsonb_build_object('user_id', test.id('r44a_renter'), 'number', '+14165550189'))$$, '%staff%');
update program_settings set phone_browser_calls = false;
select test.throws('calls in the browser off: refused', $$select public.server_twilio_browser_call_start(jsonb_build_object('user_id', test.id('r44a_cs'), 'number', '+14165550189'))$$, '%off%');
select test.eq('calls in the browser off: no token either', public.server_voice_presence(test.id('r44a_cs'), '{}') ->> 'calls', 'false');
update program_settings set phone_browser_calls = true;
select test.eq('the browser functions are the server''s only',
  (select count(*) from pg_proc p join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'public' and p.proname in ('server_voice_settings', 'server_voice_presence', 'server_twilio_browser_call_start', 'server_twilio_browser_call_get', 'server_voice_ring')
      and (has_function_privilege('anon', p.oid, 'execute') or has_function_privilege('authenticated', p.oid, 'execute'))), 0::bigint);

-- ================================================================ the hire welcome
select test.eq('the welcome note gives no start date; it asks for the team chat and the member tag',
  (select position('Your start date is' in d) = 0 and position('"Name - Position"' in d) > 0 and position('Claim your shifts online' in d) > 0
     from (select pg_get_functiondef('app.hire_onboard_pre1067(uuid, jsonb)'::regprocedure) d) x), true);

-- ================================================================ Sales reads only their own leads
insert into leads (id, kind, name, phone, source, assigned_to) values
  (test.id('r44a_lead_mine'), 'contact', 'Lead Mine', '(416) 555-0191', 'web', test.id('r44a_sales')),
  (test.id('r44a_lead_other'), 'contact', 'Lead Other', '(416) 555-0192', 'web', test.id('r44a_sales2')),
  (test.id('r44a_lead_free'), 'contact', 'Lead Free', '(416) 555-0193', 'web', null);
insert into lead_claims (lead_id, claimed_by, expires_at, cap_at) values (test.id('r44a_lead_free'), test.id('r44a_sales'), now() + interval '10 minutes', now() + interval '1 hour');

select test.login(test.id('r44a_sales'));
select test.eq('Sales only: reads its assigned and claimed leads, no other',
  test.visible($$select * from leads where id in (test.id('r44a_lead_mine'), test.id('r44a_lead_other'), test.id('r44a_lead_free'))$$), 2::bigint);
select test.eq('Sales only: another person''s lead is not changed', test.affected($$update leads set name = 'x' where id = test.id('r44a_lead_other')$$), 0::bigint);
select test.logout();

select test.login(test.id('r44a_cs'));
select test.eq('customer service reads every lead as before',
  test.visible($$select * from leads where id in (test.id('r44a_lead_mine'), test.id('r44a_lead_other'), test.id('r44a_lead_free'))$$), 3::bigint);
select test.logout();

select test.eq('the rule is a restrictive policy on leads, for reads and changes',
  (select string_agg(policyname || ':' || cmd, ',' order by policyname) from pg_policies where tablename = 'leads' and permissive = 'RESTRICTIVE'),
  'sales_own_only:SELECT,sales_own_only_update:UPDATE');
