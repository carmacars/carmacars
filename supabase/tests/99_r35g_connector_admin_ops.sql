-- 99: release 35 part G (migration 1156): the connector's Admin operations. Every tool's role checks (the Admin, the scope),
-- the lists' cursor and test filter, the one-record reads, the writes previewed then confirmed (a confirm without its
-- preview refused), money out prepared only, the photo upload, and whose Claude made the change. Fixtures start with "cxo".
select test.suite('99 r35g connector admin ops');
create temp table cxo_ps as select id, api_access_enabled e, api_calls_per_minute n from program_settings;
update program_settings set api_access_enabled = true, api_calls_per_minute = 600 where id is not null;

select test.mk_user('cxo_admin', 'admin');
select test.mk_user('cxo_fleet', 'va', 'fleet');
select test.mk_user('cxo_hire', 'va', 'cs');
select test.mk_owner('cxo_own');
select test.mk_vehicle('CXO1', 'cxo_own');
select test.mk_renter('cxo_rita');
select test.mk_booking('CXO-1', 'CXO1', 'cxo_rita', '2026-10-01 10:00', '2026-10-04 10:00', 'closed', 30000);

create function test.cxo_h(p text) returns text language sql as $$ select encode(sha256(convert_to(p, 'UTF8')), 'hex') $$;
select app.api_key_create(test.id('cxo_admin'), test.id('cxo_admin'), 'Laptop', array['bookings:read', 'owners:read', 'requests:read', 'admin:read', 'admin:write'], test.cxo_h('cc_live_cxo_full'), 'cc_live_cxo_');
select app.api_key_create(test.id('cxo_admin'), test.id('cxo_admin'), 'Bookings only', array['bookings:read'], test.cxo_h('cc_live_cxo_read'), 'cc_live_cxr_');
-- a key whose person is not an Admin (an Admin who lost the role)
insert into api_keys (user_id, kind, name, prefix, key_hash, scopes, created_by)
select test.id('cxo_fleet'), kind, 'Not an Admin', 'cc_live_cxn_', test.cxo_h('cc_live_cxo_none'), scopes, test.id('cxo_admin') from api_keys where key_hash = test.cxo_h('cc_live_cxo_full');
create function test.cxo(p_key text, p_tool text, a jsonb default '{}'::jsonb) returns jsonb language sql as $$ select app.api_call(test.cxo_h(p_key), p_tool, a, 'test') $$;
create function test.cxo_do(p_tool text, a jsonb) returns jsonb language plpgsql as $$
declare pv jsonb := test.cxo('cc_live_cxo_full', p_tool, a);
begin
  if not (pv ->> 'ok')::boolean then return pv; end if;
  return test.cxo('cc_live_cxo_full', p_tool, a || jsonb_build_object('confirm', true, 'preview_id', pv #>> '{result,preview_id}'));
end $$;

-- ================================================================ 1. role checks on every new tool
create temp table cxo_tools (tool text, kind text);
insert into cxo_tools select unnest(app.api_list_tools()), 'list';
insert into cxo_tools select unnest(app.api_one_reads()), 'read';
insert into cxo_tools values ('resend_agreement', 'write'), ('update_claim', 'write'), ('add_expense', 'write'), ('set_invoice_collect_by', 'write'), ('set_invoice_deduct_from', 'write'),
  ('match_toll', 'write'), ('complete_todo', 'write'), ('assign_field_job', 'write'), ('approve_onboarding', 'write'), ('reject_onboarding', 'write'),
  ('restore_staff_access', 'write'), ('record_past_trip', 'write'), ('prepare_money_action', 'write'), ('upload_booking_photo', 'write');
select test.eq('not an Admin: every tool refused (403)', (select count(*)::int from cxo_tools where test.cxo('cc_live_cxo_none', tool) ->> 'status' <> '403'), 0);
select test.eq('without the scope: every Admin read and write refused (403)',
  (select string_agg(tool, ',') from cxo_tools where tool not in ('list_bookings') and test.cxo('cc_live_cxo_read', tool) ->> 'status' <> '403'), null);
select test.eq('an unknown key: 401', test.cxo('cc_live_cxo_nope', 'list_leads') ->> 'status', '401');
select test.eq('every list answers with items and the test filter on',
  (select string_agg(tool, ',') from cxo_tools where kind = 'list' and tool <> 'list_booking_photos'
     and not (select (r ->> 'ok')::boolean and jsonb_typeof(r #> '{result,items}') = 'array' and (r #>> '{result,test_hidden}')::boolean from (select test.cxo('cc_live_cxo_full', tool) r) x)), null);

-- ================================================================ 2. paging and the test filter
insert into leads (id, kind, name, email, source, created_at) values
  (test.id('cxo_l1'), 'contact', 'Lead One', 'cxo1@example.test', 'web', now() - interval '3 minutes'),
  (test.id('cxo_l2'), 'contact', 'Lead Two', 'cxo2@example.test', 'web', now() - interval '2 minutes'),
  (test.id('cxo_l3'), 'contact', 'Lead Three', 'cxo3@example.test', 'web', now() - interval '1 minute'),
  (test.id('cxo_lt'), 'contact', 'Lead Test', 'verify-cxo@carmacars.ca', 'web', now());
create temp table cxo_p1 as select test.cxo('cc_live_cxo_full', 'list_leads', '{"query": "lead ", "limit": 2}') r;
select test.eq('page 1: two, newest first, the test lead hidden', (select string_agg(x ->> 'name', ',') from cxo_p1, jsonb_array_elements(r #> '{result,items}') x), 'Lead Three,Lead Two');
select test.ok('page 1: a cursor for more', (select r #>> '{result,next_cursor}' from cxo_p1) is not null);
select test.eq('page 2: the rest, no cursor', (select (y #>> '{result,items,0,name}') || '/' || coalesce(y #>> '{result,next_cursor}', 'end') from cxo_p1,
  lateral (select test.cxo('cc_live_cxo_full', 'list_leads', jsonb_build_object('query', 'lead ', 'limit', 2, 'cursor', r #>> '{result,next_cursor}')) y) z), 'Lead One/end');
select test.eq('include_test shows the test lead', (select x ->> 'name' from jsonb_array_elements(test.cxo('cc_live_cxo_full', 'list_leads', '{"query": "lead ", "include_test": true}') #> '{result,items}') x limit 1), 'Lead Test');
select test.ok('a limit above 50 is kept (up to 200)', (test.cxo('cc_live_cxo_full', 'list_leads', '{"limit": 150}') #>> '{result,count}')::int >= 3);
select test.eq('a bad cursor is refused', test.cxo('cc_live_cxo_full', 'list_leads', '{"cursor": "nope"}') ->> 'error', 'Not a cursor from this list: start again without one');
select test.ok('the earlier lists page too: bookings', (test.cxo('cc_live_cxo_full', 'list_bookings', '{"query": "CXO-1"}') #>> '{result,items,0,booking_number}') = 'CXO-1');

-- ================================================================ 3. one-record reads
select test.eq('agreement: none on file, not signed', (select (r #>> '{result,signed}') || '/' || jsonb_array_length(r #> '{result,agreements}') from (select test.cxo('cc_live_cxo_full', 'get_agreement', '{"booking": "CXO-1"}') r) x), 'false/0');
select test.eq('claim: unknown is a 404', test.cxo('cc_live_cxo_full', 'get_claim', '{"claim": "NOPE"}') ->> 'status', '404');
select test.ok('the car calendar lists its booking', (test.cxo('cc_live_cxo_full', 'car_calendar', jsonb_build_object('vehicle_id', test.id('vehicle:CXO1'), 'from', '2026-09-01T00:00:00Z', 'to', '2026-11-01T00:00:00Z'))
  #>> '{result,bookings,0,booking_number}') = 'CXO-1');
select test.ok('rep summary: a list', jsonb_typeof(test.cxo('cc_live_cxo_full', 'rep_summary') -> 'result') = 'array');

-- ================================================================ 4. writes: previewed, then confirmed
-- the onboarding approval
update staff_profiles set onboarding_exempt = false where user_id = test.id('cxo_hire');
insert into academy_waivers (user_id, waived_by, reason) values (test.id('cxo_hire'), test.id('cxo_admin'), 'Passed elsewhere');
update staff_profiles set agreement_waived_at = now(), agreement_waived_by = test.id('cxo_admin'), agreement_waived_reason = 'Signed on paper', whatsapp_joined = array['team'] where user_id = test.id('cxo_hire');
select test.eq('onboarding status: the hire waits for approval',
  (select x ->> 'name' from jsonb_array_elements(test.cxo('cc_live_cxo_full', 'staff_onboarding_status') #> '{result,waiting_for_approval}') x where x ->> 'user_id' = test.id('cxo_hire')::text), 'Cxo Hire');
create temp table cxo_pv as select test.cxo('cc_live_cxo_full', 'approve_onboarding', jsonb_build_object('user', test.id('cxo_hire'))) r;
select test.eq('approve: the preview changes nothing', (select (r #>> '{result,preview}') || '/' || app.staff_fully_onboarded(test.id('cxo_hire')) from cxo_pv), 'true/false');
select test.eq('approve: the preview shows the step change', (select r #>> '{result,will_change,step,after}' from cxo_pv), 'done');
select test.eq('approve: a confirm without its preview is refused',
  test.cxo('cc_live_cxo_full', 'approve_onboarding', jsonb_build_object('user', test.id('cxo_hire'), 'confirm', true)) ->> 'error', 'Preview first: call without confirm, then confirm with its preview_id');
select test.eq('approve: confirmed', (select (test.cxo('cc_live_cxo_full', 'approve_onboarding', jsonb_build_object('user', test.id('cxo_hire'), 'confirm', true, 'preview_id', r #>> '{result,preview_id}')) #>> '{result,done}') from cxo_pv), 'true');
select test.eq('approve: onboarded, approved by the key''s Admin', (select app.staff_fully_onboarded(test.id('cxo_hire')) || '/' || (onboarding_approved_by = test.id('cxo_admin')) from staff_profiles where user_id = test.id('cxo_hire')), 'true/true');
select test.ok('whose Claude: the person and the key name', app.api_via((select k from api_keys k where key_hash = test.cxo_h('cc_live_cxo_full'))) = 'via Claude: Cxo Admin (key Laptop)');
select test.eq('the log keeps the preview and the confirm, as that Admin', (select string_agg(tool, ',' order by created_at) from api_calls where user_id = test.id('cxo_admin') and tool like 'approve_onboarding%' and ok),
  'approve_onboarding:preview,approve_onboarding');

-- a To do completed
insert into tasks (id, queue, task_type, title) values (test.id('cxo_task'), 'admin', 'follow_up', 'Call the renter back');
select test.eq('complete a To do', (test.cxo_do('complete_todo', jsonb_build_object('id', test.id('cxo_task'), 'note', 'Called')) #>> '{result,done}'), 'true');
select test.ok('the To do is done', (select status from tasks where id = test.id('cxo_task')) not in ('open', 'in_progress', 'waiting'));
-- an invoice: how it is paid and from which payout
insert into owner_invoices (id, invoice_number, owner_id, vehicle_id, kind, period_month, billing_date, payment_method, status, fees_cents, hst_cents)
values (test.id('cxo_inv'), 'CXO-INV-1', test.id('owner:cxo_own'), test.id('vehicle:CXO1'), 'monthly', date '2026-10-01', date '2026-10-15', 'pre_authorized_debit', 'issued', 10000, 1300);
select test.cxo_do('set_invoice_collect_by', jsonb_build_object('id', test.id('cxo_inv'), 'collect_by', 'payout'));
select test.cxo_do('set_invoice_deduct_from', jsonb_build_object('id', test.id('cxo_inv'), 'date', '2026-12-10'));
select test.eq('invoice: deducted from payouts, starting December 10', (select collect_by || '/' || deduct_from_payout_on from owner_invoices where id = test.id('cxo_inv')), 'payout/2026-12-10');
select test.eq('invoice list: how it is paid, the date, unpaid', (select (x ->> 'how_paid') || '/' || (x ->> 'deduct_from_payout_on') || '/' || (x ->> 'paid')
  from jsonb_array_elements(test.cxo('cc_live_cxo_full', 'list_owner_invoices', jsonb_build_object('owner_id', test.id('owner:cxo_own'), 'unpaid', true)) #> '{result,items}') x), 'deducted from payouts/2026-12-10/false');
-- an expense
select test.eq('an expense: an unknown category is refused at the preview', left(test.cxo('cc_live_cxo_full', 'add_expense', '{"category": "nope", "amount_cents": 500, "description": "Car wash"}') ->> 'error', 19), 'It would be refused');
select test.cxo_do('add_expense', jsonb_build_object('category', (select code from company_expense_categories where is_active limit 1), 'amount_cents', 2500, 'description', 'Car wash CXO1', 'vehicle_id', test.id('vehicle:CXO1')));
select test.eq('an expense: added, listed', (select x ->> 'amount_cents' from jsonb_array_elements(test.cxo('cc_live_cxo_full', 'list_expenses') #> '{result,items}') x where x ->> 'description' = 'Car wash CXO1'), '2500');
-- restore access
select test.cxo_do('end_staff_access', jsonb_build_object('user', test.id('cxo_fleet')));
select test.eq('end access, then restore', (test.cxo_do('restore_staff_access', jsonb_build_object('user', test.id('cxo_fleet'))) #>> '{result,done}'), 'true');
-- record a past trip: the screen's past-trip form (the arguments it needs are checked there)
select test.ok('record a past trip reaches the past-trip form', (select r ->> 'ok' = 'true' or r ->> 'error' like 'It would be refused%' from (select test.cxo('cc_live_cxo_full', 'record_past_trip', '{"booking": "CXO-1"}') r) x));

-- ================================================================ 5. money out: prepared only
create temp table cxo_refunds as select count(*) n from refunds;
select test.eq('prepare: needs a reason', test.cxo('cc_live_cxo_full', 'prepare_money_action', '{"kind": "refund", "booking": "CXO-1", "amount_cents": 5000}') ->> 'error', 'Say why (at least 5 characters)');
create temp table cxo_money as select test.cxo_do('prepare_money_action', '{"kind": "refund", "booking": "CXO-1", "amount_cents": 5000, "reason": "Late pickup, agreed by phone"}') r;
select test.eq('prepare: confirmed, no money moved', (select (r #>> '{result,prepared}') || '/' || (r #>> '{result,money_moved}') from cxo_money), 'true/false');
select test.eq('prepare: an Admin To do with its link', (select queue || ':' || task_type || ':' || (booking_id = test.id('booking:CXO-1')) from tasks where id = (select (r #>> '{result,task_id}')::uuid from cxo_money)), 'admin:api_prepared_money:true');
select test.ok('prepare: the To do says whose Claude', (select detail like '%via Claude: Cxo Admin (key Laptop)%' from tasks where id = (select (r #>> '{result,task_id}')::uuid from cxo_money)));
select test.eq('prepare: no refund was made', (select count(*) from refunds), (select n from cxo_refunds));

-- ================================================================ 6. a booking photo
select test.eq('photo: a stage with no condition report yet is refused', test.cxo('cc_live_cxo_full', 'upload_booking_photo', '{"booking": "CXO-1", "stage": "return", "image_base64": "/9j/4AAQ"}') ->> 'error',
  'This booking has no return condition report yet: record the return first');
insert into condition_reports (id, vehicle_id, booking_id, kind, performed_by, performed_by_role, performed_at) values (test.id('cxo_cr'), test.id('vehicle:CXO1'), test.id('booking:CXO-1'), 'return', test.id('cxo_admin'), 'staff', now());
create temp table cxo_ph as select test.cxo_do('upload_booking_photo', '{"booking": "CXO-1", "stage": "return", "shot": "rear", "image_base64": "/9j/4AAQ"}') r;
select test.eq('photo: the confirm hands the bytes to the web layer', (select (r #>> '{result,run}') || '/' || (r #>> '{result,params,condition_report_id}') from cxo_ph), 'photo/' || test.id('cxo_cr'));
select test.ok('photo: the bytes are not logged', not exists (select 1 from api_calls where tool like 'upload_booking_photo%' and args ? 'image_base64'));
select test.eq('photo: recorded once stored', (app.api_photo_record(test.cxo_h('cc_live_cxo_full'), (select id from api_previews where tool = 'upload_booking_photo' order by created_at desc limit 1),
  'bookings/' || test.id('booking:CXO-1') || '/claude/' || gen_random_uuid() || '.jpg', 800, 600) ->> 'stage'), 'return');
select test.eq('photo: listed on the booking', (select x ->> 'shot' from jsonb_array_elements(test.cxo('cc_live_cxo_full', 'list_booking_photos', '{"booking": "CXO-1"}') #> '{result,items}') x), 'rear');
select test.throws('photo: recorded once only', format($$select app.api_photo_record(%L, %L, %L, 1, 1)$$, test.cxo_h('cc_live_cxo_full'), (select id from api_previews where tool = 'upload_booking_photo' order by created_at desc limit 1),
  'bookings/' || test.id('booking:CXO-1') || '/claude/' || gen_random_uuid() || '.jpg'), 'Already stored');

update program_settings p set api_access_enabled = x.e, api_calls_per_minute = x.n from cxo_ps x where x.id = p.id;
