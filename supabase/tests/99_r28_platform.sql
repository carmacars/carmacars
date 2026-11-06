-- 99: release 28, platform (migrations 0560 to 0562): the VIN photo reader's gate and the check digit, the site search
-- as each role (no row of another role leaks), and API access (keys hashed, scopes, the Admin role, the rate limit and
-- the audit of every call with before and after). Fixtures start with "rqz"; example.test addresses only; synthetic VINs.
select test.suite('99 r28 platform: VIN reader, search, API access');
select test.mk_user('rqz_admin', 'admin');
select test.mk_user('rqz_admin2', 'admin');
select test.mk_user('rqz_cs', 'va', 'cs');
select test.mk_user('rqz_sales', 'va', 'sales');
select test.mk_user('rqz_field', 'field');
select test.mk_owner('rqz_owna');
select test.mk_owner('rqz_ownb');
select test.mk_vehicle('RQZA', 'rqz_owna');
select test.mk_vehicle('RQZB', 'rqz_ownb');
select test.mk_renter('rqz_zelda');
select test.mk_renter('rqz_quill');
select test.mk_renter('rqz_oldie');
-- a request (Zelda), a confirmed booking (Quill), and a booking that ended long ago (Oldie: outside the customer window)
select test.mk_booking('RQZ-101', 'RQZA', 'rqz_zelda', to_char((now() + interval '20 days') at time zone 'America/Toronto', 'YYYY-MM-DD 10:00'), to_char((now() + interval '23 days') at time zone 'America/Toronto', 'YYYY-MM-DD 10:00'), 'requested', 30000);
select test.mk_booking('RQZ-102', 'RQZB', 'rqz_quill', to_char((now() + interval '30 days') at time zone 'America/Toronto', 'YYYY-MM-DD 10:00'), to_char((now() + interval '33 days') at time zone 'America/Toronto', 'YYYY-MM-DD 10:00'), 'confirmed', 30000);
select test.mk_booking('RQZ-103', 'RQZB', 'rqz_oldie', '2024-01-10 10:00', '2024-01-12 10:00', 'closed', 20000);
create temp table rqz_ps as select id, require_staff_two_step t from program_settings;
update program_settings set require_staff_two_step = false where id is not null;

-- ================================================================ 1. the VIN check digit and the photo reader's gate
select test.ok('the check digit of a published VIN adds up', app.vin_check_ok('1HGCM82633A004352'));
select test.ok('one digit off: it does not', not app.vin_check_ok('1HGCM82643A004352'));
select test.ok('a remainder of ten is X', app.vin_check_ok('WDDZF4KBXHA123456'));
create function test.rqz_now() returns timestamptz language sql as $$ select timestamp '2031-07-08 12:00' at time zone 'America/Toronto' $$;
create temp table rqz_vis as select id, ai_vision_enabled v, ai_vision_vin_enabled vv from program_settings;
update program_settings set ai_vision_enabled = true, ai_vision_vin_enabled = true where id is not null;
create temp table rqz_us as select service, enabled, included from usage_services where service = 'workers_ai';
update usage_services set enabled = true, included = greatest(coalesce(included, 0), 10000) where service = 'workers_ai';
select test.eq('a visitor (not signed in) may have a photo read', app.vin_read_gate(null, 'aaaaaaaaaaaaaaaa', test.rqz_now()) ->> 'allowed', 'true');
select test.eq('staff may, as staff', (select (g ->> 'allowed') || '/' || (g ->> 'staff') from (select app.vin_read_gate(test.id('rqz_cs'), 'bbbbbbbbbbbbbbbb', test.rqz_now()) g) x), 'true/true');
insert into vin_reads (client_hash, ok, created_at) select 'aaaaaaaaaaaaaaaa', true, test.rqz_now() - interval '1 hour' from generate_series(1, 5);
select test.eq('a visitor past five reads today: refused, with the way out', (select (g ->> 'allowed') || ' ' || (g ->> 'reason') from (select app.vin_read_gate(null, 'aaaaaaaaaaaaaaaa', test.rqz_now()) g) x) like 'false %Scan the barcode%', true);
select test.eq('another visitor still may', app.vin_read_gate(null, 'cccccccccccccccc', test.rqz_now()) ->> 'allowed', 'true');
select test.throws('a client key is required', $$select app.vin_read_gate(null, 'not-a-hash')$$, '%client key%');
select app.vin_read_record(null, 'cccccccccccccccc', jsonb_build_object('model', 'fake-vision-v1', 'ok', true, 'neurons', 90, 'check_ok', true, 'corrected', true));
select test.ok('a read is recorded without the VIN', exists (select 1 from vin_reads where client_hash = 'cccccccccccccccc' and ok and check_ok and corrected)
  and not exists (select 1 from information_schema.columns where table_name = 'vin_reads' and column_name in ('vin', 'image', 'photo')));
select test.ok('its neurons count as the vin_read purpose, a live reader', exists (select 1 from provider_calls where purpose = 'vin_read' and units = 90) and app.ai_tier('vin_read') = 'live');
update program_settings p set ai_vision_enabled = x.v, ai_vision_vin_enabled = x.vv from rqz_vis x where p.id = x.id;
update usage_services u set enabled = x.enabled, included = x.included from rqz_us x where u.service = x.service;
select test.ok('the gate and the record are for the server only', not has_function_privilege('anon', 'public.server_vin_read_gate(text, uuid)', 'execute')
  and not has_function_privilege('authenticated', 'public.server_vin_read_record(text, jsonb, uuid)', 'execute'));

-- ================================================================ 2. the site search, as each role
create function test.rqz_find(p_who text, p_q text) returns text language sql as $$
  select coalesce(string_agg((g ->> 'key') || ':' || (r ->> 'title'), ' ' order by g ->> 'key', r ->> 'title'), '')
    from jsonb_array_elements(app.search_mine(test.id(p_who), 'aal2', p_q) -> 'groups') g, jsonb_array_elements(g -> 'rows') r
$$;
select test.ok('Admin finds a booking by its number', test.rqz_find('rqz_admin', 'RQZ-102') like '%bookings:RQZ-102%');
select test.ok('Admin finds a request and the renter by name', test.rqz_find('rqz_admin', 'rqz zelda') like '%requests:RQZ-101%' and test.rqz_find('rqz_admin', 'rqz zelda') like '%renters:Rqz Zelda%');
select test.ok('Admin finds an owner by email', test.rqz_find('rqz_admin', 'rqz_owna@example') like '%owners:Rqz Owna%');
select test.ok('customer service finds the confirmed booking by the renter''s name', test.rqz_find('rqz_cs', 'rqz quill') like '%bookings:RQZ-102%');
select test.eq('customer service: a renter outside the window is not found, nor through their booking', test.rqz_find('rqz_cs', 'rqz oldie'), '');
select test.ok('customer service still finds that booking by its number', test.rqz_find('rqz_cs', 'RQZ-103') like '%bookings:RQZ-103%');
select test.ok('sales finds the request', test.rqz_find('rqz_sales', 'RQZ-101') like '%requests:RQZ-101%');
select test.eq('sales: never a confirmed booking or an owner', test.rqz_find('rqz_sales', 'RQZ-102') || test.rqz_find('rqz_sales', 'rqz_owna@example'), '');
select test.ok('an owner finds their own car and its booking', test.rqz_find('rqz_ownb', 'RQZ-102') like '%own_bookings:RQZ-102%');
select test.eq('an owner never finds another owner''s booking or renters', test.rqz_find('rqz_owna', 'RQZ-102') || test.rqz_find('rqz_owna', 'rqz quill'), '');
select test.ok('a renter finds their own booking', test.rqz_find('rqz_quill', 'RQZ-102') like '%my_bookings:RQZ-102%');
select test.eq('a renter never finds another renter''s booking', test.rqz_find('rqz_quill', 'RQZ-101') || test.rqz_find('rqz_zelda', 'RQZ-102'), '');
select test.eq('field staff with no job find nothing', test.rqz_find('rqz_field', 'RQZ-10'), '');
select test.eq('one character: no search', test.rqz_find('rqz_admin', 'R'), '');
select test.throws('nobody signed in: refused', $$select app.search_mine(null, '', 'RQZ-101')$$, '%Sign in%');
select test.ok('the search is for the server only', not has_function_privilege('authenticated', 'public.server_search_mine(uuid, text, text)', 'execute')
  and not has_function_privilege('anon', 'public.server_search_mine(uuid, text, text)', 'execute'));

-- ================================================================ 3. API access
create function test.rqz_h(p text) returns text language sql as $$ select encode(sha256(convert_to(p, 'UTF8')), 'hex') $$;
select app.api_key_create(test.id('rqz_admin'), test.id('rqz_admin2'), 'Claude Code', array['bookings:read', 'bookings:write', 'owners:read'], test.rqz_h('cc_live_rqz_one'), 'cc_live_rqz_o');
select test.ok('a key is kept as its SHA-256 only', exists (select 1 from api_keys where key_hash = test.rqz_h('cc_live_rqz_one') and prefix = 'cc_live_rqz_o')
  and not exists (select 1 from api_keys k where k.key_hash = 'cc_live_rqz_one' or k.prefix = 'cc_live_rqz_one'));
select test.throws('only an Admin makes keys', $$select app.api_key_create(test.id('rqz_cs'), test.id('rqz_admin2'), 'x', array['bookings:read'], test.rqz_h('cc_live_rqz_x'), 'cc_live_rqz_x')$$, '%Only an Admin%');
select test.throws('only an Admin holds a key', $$select app.api_key_create(test.id('rqz_admin'), test.id('rqz_cs'), 'x', array['bookings:read'], test.rqz_h('cc_live_rqz_y'), 'cc_live_rqz_y')$$, '%Admins only%');
select test.throws('an unknown scope is refused', $$select app.api_key_create(test.id('rqz_admin'), test.id('rqz_admin2'), 'x', array['payments:write'], test.rqz_h('cc_live_rqz_z'), 'cc_live_rqz_z')$$, '%');
select test.eq('a read with the scope works', app.api_call(test.rqz_h('cc_live_rqz_one'), 'get_booking', '{"booking_number": "RQZ-102"}') #>> '{result,renter}', 'Rqz Quill');
select test.eq('an unknown key: 401', app.api_call(test.rqz_h('cc_live_nope'), 'get_booking', '{"booking_number": "RQZ-102"}') ->> 'status', '401');
select test.eq('a tool outside the scopes: 403, and logged', app.api_call(test.rqz_h('cc_live_rqz_one'), 'update_owner', jsonb_build_object('owner_id', test.id('owner:rqz_owna'), 'changes', '{"phone": "416-555-0111"}')) ->> 'status', '403');
select test.ok('the refusal is in the call log', exists (select 1 from api_calls where tool = 'update_owner' and not ok and error like 'scope owners:write%'));
select test.eq('a change of a listed field works', app.api_call(test.rqz_h('cc_live_rqz_one'), 'update_booking', '{"booking_number": "RQZ-102", "changes": {"notes": "Bring a child seat", "pickup_place": "Union Station"}}') ->> 'ok', 'true');
select test.eq('the booking changed', (select notes || ' / ' || pickup_place from bookings where booking_number = 'RQZ-102'), 'Bring a child seat / Union Station');
select test.eq('the call log has who, what, before and after', (select (c.user_id = test.id('rqz_admin2'))::text || ' ' || c.target || ' ' || coalesce(c.before ->> 'notes', 'null') || ' -> ' || (c.after ->> 'notes')
  from api_calls c where c.tool = 'update_booking' and c.ok order by c.id desc limit 1), 'true booking RQZ-102 null -> Bring a child seat');
select test.ok('the audit log names the key''s person as the one who changed the booking', exists (select 1 from audit_log a where a.entity_table = 'bookings' and a.entity_id::text = test.id('booking:RQZ-102')::text
  and a.actor_user_id = test.id('rqz_admin2') and a.after ->> 'notes' = 'Bring a child seat'));
select test.eq('a field not listed (the status) is refused and nothing changes', (select (app.api_call(test.rqz_h('cc_live_rqz_one'), 'update_booking', '{"booking_number": "RQZ-102", "changes": {"status": "cancelled", "notes": "x"}}') ->> 'status')
  || ' ' || (select status::text || '/' || notes from bookings where booking_number = 'RQZ-102')), '400 confirmed/Bring a child seat');
select test.eq('a missing booking: 404', app.api_call(test.rqz_h('cc_live_rqz_one'), 'get_booking', '{"booking_number": "RQZ-999"}') ->> 'status', '404');
select test.throws('the call log cannot be edited', $$update api_calls set ok = true$$, '%append-only%');
-- the Admin role is checked at every call
update user_roles set role = 'renter' where user_id = test.id('rqz_admin2') and role = 'admin';
select test.eq('the person stops being an Admin: the key stops', app.api_call(test.rqz_h('cc_live_rqz_one'), 'get_booking', '{"booking_number": "RQZ-102"}') ->> 'status', '403');
update user_roles set role = 'admin' where user_id = test.id('rqz_admin2') and role = 'renter';
-- revoked
select app.api_key_revoke(test.id('rqz_admin'), (select id from api_keys where key_hash = test.rqz_h('cc_live_rqz_one')));
select test.eq('a revoked key stops at once', app.api_call(test.rqz_h('cc_live_rqz_one'), 'whoami', '{}') ->> 'status', '401');
-- the rate limit
select app.api_key_create(test.id('rqz_admin'), test.id('rqz_admin'), 'Busy', array['bookings:read'], test.rqz_h('cc_live_rqz_busy'), 'cc_live_rqz_b');
insert into api_calls (key_id, user_id, tool, ok) select (select id from api_keys where key_hash = test.rqz_h('cc_live_rqz_busy')), test.id('rqz_admin'), 'list_bookings', true from generate_series(1, (app.settings()).api_calls_per_minute);
select test.eq('over the calls a minute: 429', app.api_call(test.rqz_h('cc_live_rqz_busy'), 'list_bookings', '{}') ->> 'status', '429');
-- a request: only its listed fields, and only before an offer
select app.api_key_create(test.id('rqz_admin'), test.id('rqz_admin'), 'Requests', array['requests:read', 'requests:write'], test.rqz_h('cc_live_rqz_req'), 'cc_live_rqz_r');
select test.eq('a request''s note changes', app.api_call(test.rqz_h('cc_live_rqz_req'), 'update_request', '{"booking_number": "RQZ-101", "changes": {"request_note": "Two child seats"}}') ->> 'ok', 'true');
select test.eq('a confirmed booking is not a request', app.api_call(test.rqz_h('cc_live_rqz_req'), 'update_request', '{"booking_number": "RQZ-102", "changes": {"request_note": "x"}}') ->> 'status', '400');
select test.ok('list_requests lists the request, not the booking', (select bool_or(x ->> 'booking_number' = 'RQZ-101') and not bool_or(x ->> 'booking_number' = 'RQZ-102')
  from jsonb_array_elements(app.api_call(test.rqz_h('cc_live_rqz_req'), 'list_requests', '{"query": "RQZ-10"}') -> 'result') x));
-- OAuth: a code becomes a token once, with PKCE
select app.api_oauth_register('ccc_rqz_client_000000000001', 'Claude', array['https://claude.ai/api/mcp/auth_callback']);
select test.throws('a client may return only to Claude or a loopback address', $$select app.api_oauth_register('ccc_rqz_client_000000000002', 'Evil', array['https://evil.example.test/cb'])$$, '%not allowed%');
select app.api_oauth_approve(test.id('rqz_admin'), 'ccc_rqz_client_000000000001', 'https://claude.ai/api/mcp/auth_callback', repeat('A', 43), array['owners:read'], test.rqz_h('ccx_rqz_code'));
select test.eq('a wrong PKCE verifier: refused', app.api_oauth_token(jsonb_build_object('grant_type', 'authorization_code', 'client_id', 'ccc_rqz_client_000000000001', 'code_hash', test.rqz_h('ccx_rqz_code'),
  'redirect_uri', 'https://claude.ai/api/mcp/auth_callback', 'challenge', repeat('B', 43), 'access_hash', test.rqz_h('cca_rqz_1'), 'refresh_hash', test.rqz_h('ccr_rqz_1'), 'prefix', 'cca_rqz_1')) ->> 'error', 'invalid_grant');
select test.eq('the code was spent by that try: a second try is refused too', app.api_oauth_token(jsonb_build_object('grant_type', 'authorization_code', 'client_id', 'ccc_rqz_client_000000000001', 'code_hash', test.rqz_h('ccx_rqz_code'),
  'redirect_uri', 'https://claude.ai/api/mcp/auth_callback', 'challenge', repeat('A', 43), 'access_hash', test.rqz_h('cca_rqz_1'), 'refresh_hash', test.rqz_h('ccr_rqz_1'), 'prefix', 'cca_rqz_1')) ->> 'error', 'invalid_grant');
select app.api_oauth_approve(test.id('rqz_admin'), 'ccc_rqz_client_000000000001', 'https://claude.ai/api/mcp/auth_callback', repeat('A', 43), array['owners:read'], test.rqz_h('ccx_rqz_code2'));
select test.eq('the right verifier: an access token with the approved scope', app.api_oauth_token(jsonb_build_object('grant_type', 'authorization_code', 'client_id', 'ccc_rqz_client_000000000001', 'code_hash', test.rqz_h('ccx_rqz_code2'),
  'redirect_uri', 'https://claude.ai/api/mcp/auth_callback', 'challenge', repeat('A', 43), 'access_hash', test.rqz_h('cca_rqz_2'), 'refresh_hash', test.rqz_h('ccr_rqz_2'), 'prefix', 'cca_rqz_2')) ->> 'scopes', '["owners:read"]');
select test.eq('the token reads owners', app.api_call(test.rqz_h('cca_rqz_2'), 'get_owner', jsonb_build_object('owner_id', test.id('owner:rqz_owna'))) #>> '{result,legal_name}', 'Rqz Owna');
select test.eq('and nothing else', app.api_call(test.rqz_h('cca_rqz_2'), 'list_bookings', '{}') ->> 'status', '403');
select test.eq('a refresh rotates both tokens', app.api_oauth_token(jsonb_build_object('grant_type', 'refresh_token', 'client_id', 'ccc_rqz_client_000000000001', 'old_refresh_hash', test.rqz_h('ccr_rqz_2'),
  'access_hash', test.rqz_h('cca_rqz_3'), 'refresh_hash', test.rqz_h('ccr_rqz_3'), 'prefix', 'cca_rqz_3')) ->> 'ok', 'true');
select test.eq('the old access token stops', app.api_call(test.rqz_h('cca_rqz_2'), 'whoami', '{}') ->> 'status', '401');
select test.eq('the old refresh token stops', app.api_oauth_token(jsonb_build_object('grant_type', 'refresh_token', 'client_id', 'ccc_rqz_client_000000000001', 'old_refresh_hash', test.rqz_h('ccr_rqz_2'),
  'access_hash', test.rqz_h('cca_rqz_4'), 'refresh_hash', test.rqz_h('ccr_rqz_4'), 'prefix', 'cca_rqz_4')) ->> 'error', 'invalid_grant');
select test.ok('every API function is for the server only', not exists (select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
  where n.nspname = 'public' and p.proname like 'server_api_%' and (has_function_privilege('anon', p.oid, 'execute') or has_function_privilege('authenticated', p.oid, 'execute'))));

update program_settings p set require_staff_two_step = x.t from rqz_ps x where p.id = x.id;
