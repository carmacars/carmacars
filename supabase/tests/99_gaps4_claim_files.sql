-- 99: claim photos and repair estimates attached by the connector (migration 1873): the role of the key's person, the scope, preview then
-- confirm (a confirm without its preview, other arguments, a second use refused), a closed claim refused, the estimate entered as an
-- incident cost, the stored file recorded once on the claim's incident, the bytes never logged. Fixtures start with "cf4".
select test.suite('99 gaps4 claim files');
create temp table cf4_ps as select id, api_access_enabled e, api_calls_per_minute n from program_settings;
update program_settings set api_access_enabled = true, api_calls_per_minute = 600 where id is not null;
select test.mk_user('cf4_admin', 'admin');
select test.mk_user('cf4_fin', 'va', 'finance');
select test.mk_user('cf4_cs', 'va', 'cs');
select test.mk_owner('cf4_own');
select test.mk_vehicle('CF4A', 'cf4_own');
insert into incidents (id, kind, vehicle_id, occurred_at) values (test.id('inc:cf4'), 'accident', test.id('vehicle:CF4A'), now() - interval '5 days'),
  (test.id('inc:cf4c'), 'accident', test.id('vehicle:CF4A'), now() - interval '50 days');
insert into claims (id, incident_id, vehicle_id, owner_id, path, claim_number) values (test.id('claim:cf4'), test.id('inc:cf4'), test.id('vehicle:CF4A'), test.id('owner:cf4_own'), 'fleet_policy', 'CF4-CLM-1');
insert into claims (id, incident_id, vehicle_id, owner_id, path, claim_number, status) values (test.id('claim:cf4c'), test.id('inc:cf4c'), test.id('vehicle:CF4A'), test.id('owner:cf4_own'), 'fleet_policy', 'CF4-CLM-2', 'closed');
create function test.cf4_h(p text) returns text language sql as $$ select encode(sha256(convert_to(p, 'UTF8')), 'hex') $$;
select app.api_key_create(test.id('cf4_admin'), test.id('cf4_admin'), 'Laptop', array['bookings:read', 'admin:read', 'admin:write'], test.cf4_h('cc_live_cf4_full'), 'cc_live_cf4_');
select app.api_key_create(test.id('cf4_admin'), test.id('cf4_admin'), 'Read', array['admin:read'], test.cf4_h('cc_live_cf4_read'), 'cc_live_cf4r');
-- keys whose person is Finance (allowed) and CS (not allowed): the same scopes, but not an Admin by role
insert into api_keys (user_id, kind, name, prefix, key_hash, scopes, created_by)
select test.id('cf4_cs'), kind, 'Not allowed', 'cc_live_cf4c', test.cf4_h('cc_live_cf4_cs'), scopes, test.id('cf4_admin') from api_keys where key_hash = test.cf4_h('cc_live_cf4_full');
create function test.cf4(p_key text, p_tool text, a jsonb) returns jsonb language sql as $$ select app.api_call(test.cf4_h(p_key), p_tool, a, 'test') $$;
create function test.cf4_do(p_key text, p_tool text, a jsonb) returns jsonb language plpgsql as $$
declare pv jsonb := test.cf4(p_key, p_tool, a);
begin
  if not (pv ->> 'ok')::boolean then return pv; end if;
  return test.cf4(p_key, p_tool, a || jsonb_build_object('confirm', true, 'preview_id', pv #>> '{result,preview_id}'));
end $$;

-- ================================================================ 1. who may
select test.eq('a key without admin:write: refused (403), for both tools',
  test.cf4('cc_live_cf4_read', 'attach_claim_photo', '{"claim": "CF4-CLM-1", "file_base64": "/9j/4AAQ"}') ->> 'status' || test.cf4('cc_live_cf4_read', 'attach_claim_estimate', '{"claim": "CF4-CLM-1"}') ->> 'status', '403403');
select test.eq('a CS key (not Admin, Finance or Fleet): refused (403)',
  test.cf4('cc_live_cf4_cs', 'attach_claim_photo', '{"claim": "CF4-CLM-1", "file_base64": "/9j/4AAQ"}') ->> 'status', '403');
select test.eq('an unknown key: 401', test.cf4('cc_live_cf4_nope', 'attach_claim_photo', '{"claim": "CF4-CLM-1"}') ->> 'status', '401');
select test.eq('an unknown claim: 404', test.cf4('cc_live_cf4_full', 'attach_claim_photo', '{"claim": "CF4-NOPE", "file_base64": "/9j/4AAQ"}') ->> 'status', '404');
select test.eq('a closed claim takes no file', test.cf4('cc_live_cf4_full', 'attach_claim_estimate', '{"claim": "CF4-CLM-2", "amount_cents": 100000, "shop_name": "Test Shop", "approved_shop": true}') ->> 'error',
  'Claim CF4-CLM-2 is closed and takes no more files');

-- ================================================================ 2. the arguments
select test.eq('photo: a file is needed', test.cf4('cc_live_cf4_full', 'attach_claim_photo', '{"claim": "CF4-CLM-1"}') ->> 'error', 'file_base64: the photo (JPEG or PNG), base64');
select test.eq('estimate: an amount above zero', test.cf4('cc_live_cf4_full', 'attach_claim_estimate', '{"claim": "CF4-CLM-1", "amount_cents": 0, "shop_name": "Test Shop", "approved_shop": true}') ->> 'error',
  'amount_cents: the estimate in cents, above zero');
select test.eq('estimate: a shop', test.cf4('cc_live_cf4_full', 'attach_claim_estimate', '{"claim": "CF4-CLM-1", "amount_cents": 5000, "approved_shop": true}') ->> 'error', 'shop_name: the shop that made the estimate');
select test.eq('estimate: approved or not must be said', test.cf4('cc_live_cf4_full', 'attach_claim_estimate', '{"claim": "CF4-CLM-1", "amount_cents": 5000, "shop_name": "Test Shop"}') ->> 'error',
  'approved_shop: true or false, whether it is an approved shop');

-- ================================================================ 3. preview, then confirm
create temp table cf4_pv as select test.cf4('cc_live_cf4_full', 'attach_claim_estimate', '{"claim": "CF4-CLM-1", "amount_cents": 184500, "hst_cents": 21225, "shop_name": "Test Body Shop", "approved_shop": true, "description": "Rear bumper and quarter panel"}') r;
select test.eq('estimate: the preview changes nothing and says what it will do',
  (select (r #>> '{result,preview}') || ' ' || (r #>> '{result,will_do}') from cf4_pv) || ' ' || (select count(*) from incident_costs where incident_id = test.id('inc:cf4')),
  'true Add a repair estimate of $1,845.00 from Test Body Shop (an approved shop) to claim CF4-CLM-1. 0');
select test.eq('estimate: a confirm without a preview is refused',
  test.cf4('cc_live_cf4_full', 'attach_claim_estimate', '{"claim": "CF4-CLM-1", "amount_cents": 184500, "shop_name": "Test Body Shop", "approved_shop": true, "confirm": true}') ->> 'error',
  'Preview first: call without confirm, then confirm with its preview_id');
select test.eq('estimate: other arguments than the preview''s are refused',
  test.cf4('cc_live_cf4_full', 'attach_claim_estimate', jsonb_build_object('claim', 'CF4-CLM-1', 'amount_cents', 999900, 'hst_cents', 21225, 'shop_name', 'Test Body Shop', 'approved_shop', true,
    'description', 'Rear bumper and quarter panel', 'confirm', true, 'preview_id', (select r #>> '{result,preview_id}' from cf4_pv))) ->> 'error', 'The arguments differ from the preview: preview again with these');
create temp table cf4_ok as select test.cf4('cc_live_cf4_full', 'attach_claim_estimate', jsonb_build_object('claim', 'CF4-CLM-1', 'amount_cents', 184500, 'hst_cents', 21225,
  'shop_name', 'Test Body Shop', 'approved_shop', true, 'description', 'Rear bumper and quarter panel', 'confirm', true, 'preview_id', (select r #>> '{result,preview_id}' from cf4_pv))) r;
select test.eq('estimate: confirmed, it is an incident cost of the claim by that person',
  (select format('%s %s %s %s %s', amount_cents, hst_cents, shop_name, approved_shop, created_by = test.id('cf4_admin')) from incident_costs where incident_id = test.id('inc:cf4') and kind = 'repair_estimate'),
  '184500 21225 Test Body Shop true true');
select test.eq('estimate: it counts in the claim''s damage cost', app.incident_damage_cost(test.id('inc:cf4')), 184500::bigint);
select test.eq('estimate: a preview is used once', test.cf4('cc_live_cf4_full', 'attach_claim_estimate', jsonb_build_object('claim', 'CF4-CLM-1', 'amount_cents', 184500, 'hst_cents', 21225,
  'shop_name', 'Test Body Shop', 'approved_shop', true, 'description', 'Rear bumper and quarter panel', 'confirm', true, 'preview_id', (select r #>> '{result,preview_id}' from cf4_pv))) ->> 'error',
  'This preview was already used: preview again');
select test.eq('estimate: the log has the preview and the confirm', (select string_agg(tool, ',' order by created_at) from api_calls where target = 'CF4-CLM-1' and ok), 'attach_claim_estimate:preview,attach_claim_estimate');
insert into api_keys (user_id, kind, name, prefix, key_hash, scopes, created_by)
select test.id('cf4_fin'), kind, 'Finance', 'cc_live_cf4f', test.cf4_h('cc_live_cf4_fin'), scopes, test.id('cf4_admin') from api_keys where key_hash = test.cf4_h('cc_live_cf4_full');
select test.eq('estimate: a Finance person''s key may preview too', test.cf4('cc_live_cf4_fin', 'attach_claim_estimate', '{"claim": "CF4-CLM-1", "amount_cents": 1000, "shop_name": "Test Shop", "approved_shop": true}') #>> '{result,preview}', 'true');

-- ================================================================ 4. a file: stored by the web layer, recorded once
create temp table cf4_ph as select test.cf4_do('cc_live_cf4_full', 'attach_claim_photo', '{"claim": "CF4-CLM-1", "file_base64": "/9j/4AAQ", "caption": "Rear bumper"}') r;
select test.eq('photo: confirmed, the web layer is asked to store it (the fingerprint, not the bytes)',
  (select (r #>> '{result,run}') || ' ' || (r #>> '{result,params,file_sha256}' = test.cf4_h('/9j/4AAQ'))::text || ' ' || (r #> '{result,params}' ? 'file_base64')::text from cf4_ph), 'claim_file true false');
select test.ok('photo: the bytes are not logged', not exists (select 1 from api_calls where tool like 'attach_claim%' and args ? 'file_base64'));
select test.eq('photo: recorded once stored on the claim''s incident, under legal hold',
  (app.api_claim_file_record(test.cf4_h('cc_live_cf4_full'), (select id from api_previews where tool = 'attach_claim_photo' order by created_at desc limit 1),
     'claims/' || test.id('claim:cf4') || '/claude/' || gen_random_uuid() || '.jpg', 'image/jpeg', 'abc', 'test') ->> 'done'), 'true');
select test.eq('photo: the document', (select format('%s %s %s %s', kind, title, legal_hold, storage_bucket) from documents where incident_id = test.id('inc:cf4') and kind = 'other'), 'other Rear bumper true documents');
select test.throws('photo: recorded once only', format($$select app.api_claim_file_record(%L, %L, %L, 'image/jpeg', 'abc', 'test')$$, test.cf4_h('cc_live_cf4_full'),
  (select id from api_previews where tool = 'attach_claim_photo' order by created_at desc limit 1), 'claims/' || test.id('claim:cf4') || '/claude/' || gen_random_uuid() || '.jpg'), 'Already stored');
select test.throws('photo: a path outside the claim is refused', format($$select app.api_claim_file_record(%L, %L, %L, 'image/jpeg', 'abc', 'test')$$, test.cf4_h('cc_live_cf4_full'),
  (select id from api_previews where tool = 'attach_claim_photo' order by created_at desc limit 1), 'claims/' || gen_random_uuid() || '/claude/' || gen_random_uuid() || '.jpg'), 'Unexpected path|Already stored');
create temp table cf4_es as select test.cf4_do('cc_live_cf4_full', 'attach_claim_estimate', '{"claim": "CF4-CLM-1", "amount_cents": 50000, "shop_name": "Test Paint", "approved_shop": false, "file_base64": "JVBERi0x"}') r;
select test.eq('estimate with a file: the web layer is asked to store it first', (select r #>> '{result,run}' from cf4_es) || ' ' || (select count(*) from incident_costs where incident_id = test.id('inc:cf4')), 'claim_file 1');
select test.eq('estimate with a file: recorded as a repair_estimate document and cost',
  (app.api_claim_file_record(test.cf4_h('cc_live_cf4_full'), (select id from api_previews where tool = 'attach_claim_estimate' order by created_at desc limit 1),
     'claims/' || test.id('claim:cf4') || '/claude/' || gen_random_uuid() || '.pdf', 'application/pdf', 'def', 'test') ->> 'done') || ' '
  || (select count(*) from incident_costs where incident_id = test.id('inc:cf4') and document_id is not null and shop_name = 'Test Paint' and not approved_shop) || ' '
  || (select count(*) from documents where incident_id = test.id('inc:cf4') and kind = 'repair_estimate'), 'true 1 1');
select test.throws('record: a PDF is not a photo', format($$select app.api_claim_file_record(%L, %L, %L, 'application/pdf', 'x', 'test')$$, test.cf4_h('cc_live_cf4_full'),
  (select id from api_previews where tool = 'attach_claim_photo' order by created_at desc limit 1), 'claims/' || test.id('claim:cf4') || '/claude/' || gen_random_uuid() || '.pdf'), 'Already stored|Unexpected file type');
select test.ok('the functions are for the server only', not has_function_privilege('authenticated', 'app.api_claim_file_record(text, uuid, text, text, text, text)', 'execute')
  and not has_function_privilege('anon', 'public.server_api_claim_file_record(text, uuid, text, text, text, text)', 'execute'));
update program_settings p set api_access_enabled = s.e, api_calls_per_minute = s.n from cf4_ps s where p.id = s.id;
