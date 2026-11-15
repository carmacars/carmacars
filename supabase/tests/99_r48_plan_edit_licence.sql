-- 99: release 48, the integrator's items (migrations 3010 to 3013). Fixtures "r8z"; example.test only.
--   3010 a payment plan's first instalment confirms the booking; no $0.00 instalment
--   3011 a booking waiting for payment with a payment already: its car and dates change, its price and payments stay
--   3012 the OPCF 27 pages carry one name everywhere
--   3013 the connector's licence_let_go (the Admin's Let it go for a licence from outside Ontario)
select test.suite('99 r48 plans, partly paid edits, licence let go');

select test.mk_user('r8z_admin', 'admin');
select test.mk_user('r8z_cs', 'va', 'cs');
update staff_profiles set single_limit_cents = 900000 where user_id = test.id('r8z_cs');

create table test.r8z (k text primary key, v jsonb);
grant select on test.r8z to authenticated, service_role;
create function test.r8zv(p text) returns jsonb language sql stable as $$ select v from test.r8z where k = p $$;
create function test.r8zb(p text) returns bookings language sql stable security definer as $$
  select * from public.bookings where id = coalesce((test.r8zv(p) ->> 'booking_id')::uuid, (test.r8zv(p) ->> 'id')::uuid) $$;
create function test.r8zu(p text) returns uuid language sql stable security definer as $$
  select r.user_id from public.renters r where r.id = (test.r8zb(p)).renter_id $$;
do $$
declare i integer;
begin
  for i in 1 .. 3 loop
    insert into test.r8z select 'car' || i, app.vehicle_add(test.id('r8z_admin'), jsonb_build_object('supply_type', 'company', 'vin', '1XFCXMM00000049' || lpad(i::text, 2, '0'),
      'plate', 'R8Z00' || i, 'year', 2024, 'make', 'Kia', 'model', 'K5', 'rates', jsonb_build_object('daily', 10000, 'weekend', 10000, 'weekly', 70000, 'monthly', 300000, 'deposit', 30000)));
  end loop;
end $$;
create function test.r8z_offer(p_car text, p_email text, p_mobile text, p_from interval, p_len interval) returns jsonb language sql as $$
  select app.door(test.id('r8z_cs'), 'aal2', 'ops_do', 'offer_create', jsonb_build_object('vehicle_id', (test.r8zv(p_car) ->> 'vehicle_id')::uuid,
    'pickup_at', date_trunc('hour', now()) + p_from, 'return_at', date_trunc('hour', now()) + p_from + p_len,
    'renter', jsonb_build_object('full_name', 'Pat Plan', 'email', p_email, 'mobile', p_mobile, 'date_of_birth', '1990-05-06'),
    'coverage_option', 1, 'sales_choice', 'sourced', 'channels', jsonb_build_object('email', false, 'text', false), 'notify', false)) $$;
create function test.r8z_ready(p text) returns void language plpgsql as $$
declare v_driver uuid := (select bd.driver_id from booking_drivers bd where bd.booking_id = (test.r8zb(p)).id and bd.role = 'renter');
  k text;
begin
  foreach k in array array['licence_front', 'licence_back', 'selfie'] loop
    perform app.register_verification_upload((test.r8zb(p)).id, test.r8zu(p), k, v_driver, 'renters/r8z/' || p || '-' || k || '-' || gen_random_uuid() || '.jpg', repeat('e', 64), 'image/jpeg', null, 'identity');
  end loop;
  perform public.renter_save_details(test.r8zu(p), jsonb_build_object('licence_number', 'P1234-12345-12345', 'licence_issuer', 'ON', 'licence_class', 'G',
    'licence_expiry', (now() + interval '3 years')::date), (test.r8zb(p)).id);
  perform public.renter_approve_offer((test.r8zb(p)).id, (test.r8zb(p)).current_offer_version, test.r8zu(p));
  perform public.renter_open_agreement((test.r8zb(p)).id, test.r8zu(p), 'rental-test', repeat('e', 64), 'bookings/r8z/' || p || '.pdf');
  perform public.renter_sign_agreement((test.r8zb(p)).id, test.r8zu(p), 'I agree', repeat('e', 64),
    '[{"code":"tracking_disabling","version":"v","text":"t"},{"code":"identity_verification","version":"v","text":"t"},{"code":"electronic_signature","version":"v","text":"t"},{"code":"card_authorization","version":"v","text":"t"}]'::jsonb, 'Pat Plan');
end $$;
create function test.r8z_link(p text, p_covers text, p_amount bigint) returns uuid language plpgsql as $$
declare v jsonb;
begin
  v := app.door(test.id('r8z_cs'), 'aal2', 'ops_do', 'payreq_create', jsonb_build_object('booking', (test.r8zb(p)).booking_number, 'kind', 'charge', 'covers', p_covers,
    'amount_cents', p_amount, 'channel', 'text', 'token_sha256', md5(random()::text) || md5(random()::text)));
  perform public.server_payreq_attach((v ->> 'id')::uuid, 'pi_r8z_' || (v ->> 'id'));
  return (v ->> 'id')::uuid;
end $$;
create function test.r8z_pay(p_req uuid) returns jsonb language sql as $$
  select public.server_payreq_settle(p_req, jsonb_build_object('id', 'pi_r8z_' || p_req, 'status', 'succeeded', 'amount', (select amount_cents from payment_requests where id = p_req),
    'charge_id', 'ch_r8z', 'customer_id', 'cus_r8z', 'method_id', 'pm_r8z_' || left(p_req::text, 8),
    'card', jsonb_build_object('brand', 'visa', 'last4', '4242', 'exp_month', 12, 'exp_year', 2030, 'funding', 'credit', 'name', 'Pat Plan', 'fingerprint', 'fp_r8z'))) $$;

-- ================================================================ 3010: no $0.00 instalment
-- 29 days every 2 weeks is 3 periods; a fixed amount of half the total covers it in 2: the third ($0) is folded
insert into test.r8z select 'b1', test.r8z_offer('car1', 'r8z.one@example.test', '+14165550191', interval '5 days', interval '29 days');
select test.r8z_ready('b1');
select test.eq('b1 waits for payment', (test.r8zb('b1')).status::text, 'pending_payment');
update bookings set pay_every = 'biweekly', pay_fixed_cents = (renter_due_at_booking_cents + 1) / 2 where id = (test.r8zb('b1')).id;
insert into test.r8z select 'ps1', app.booking_pay_schedule((test.r8zb('b1')).id);
select test.eq('a fixed half of the total: exactly 2 payments', (test.r8zv('ps1') ->> 'count')::integer, 2);
select test.ok('no payment of $0', not exists (select 1 from jsonb_array_elements(test.r8zv('ps1') -> 'schedule') x where (x ->> 'cents')::bigint <= 0));
select test.eq('the 2 payments make the total', (select sum((x ->> 'cents')::bigint) from jsonb_array_elements(test.r8zv('ps1') -> 'schedule') x), (test.r8zb('b1')).renter_due_at_booking_cents::numeric);
select test.eq('the last one runs to the return, numbered 2', (test.r8zv('ps1') #>> '{schedule,1,seq}') || '|' || ((test.r8zv('ps1') #>> '{schedule,1,ends_at}')::timestamptz = (test.r8zb('b1')).return_at)::text, '2|true');
-- split by the days (no fixed amount): 3 payments, none of $0
update bookings set pay_fixed_cents = null where id = (test.r8zb('b1')).id;
select test.eq('split by the days: 3 payments', (app.booking_pay_schedule((test.r8zb('b1')).id) ->> 'count')::integer, 3);
update bookings set pay_fixed_cents = (renter_due_at_booking_cents + 1) / 2 where id = (test.r8zb('b1')).id;

-- ================================================================ 3010: the first instalment confirms
select test.ok('nothing paid: not yet', not app.booking_plan_first_paid((test.r8zb('b1')).id));
insert into test.r8z select 'l1', jsonb_build_object('id', test.r8z_link('b1', 'balance', (test.r8zv('ps1') ->> 'per_cents')::bigint - 100));
select test.r8z_pay((test.r8zv('l1') ->> 'id')::uuid);
select test.eq('less than the first payment: still waiting for payment', (test.r8zb('b1')).status::text, 'pending_payment');
insert into test.r8z select 'l2', jsonb_build_object('id', test.r8z_link('b1', 'balance', 100));
insert into test.r8z select 'p2', test.r8z_pay((test.r8zv('l2') ->> 'id')::uuid);
select test.ok('the first payment is paid', app.booking_plan_first_paid((test.r8zb('b1')).id));
select test.eq('the first payment paid: confirmed', (test.r8zb('b1')).status::text, 'confirmed');
select test.ok('the rest is still owed, on the plan', app.booking_part_open((test.r8zb('b1')).id, 'rental') + app.booking_part_open((test.r8zb('b1')).id, 'fees') > 0);
select test.ok('the history says confirmed', exists (select 1 from booking_events e where e.booking_id = (test.r8zb('b1')).id and e.to_status = 'confirmed'));

-- a payment recorded by hand does the same (and a booking with no plan still waits for the whole total)
insert into test.r8z select 'b2', test.r8z_offer('car2', 'r8z.two@example.test', '+14165550192', interval '5 days', interval '29 days');
select test.r8z_ready('b2');
update bookings set pay_every = 'weekly' where id = (test.r8zb('b2')).id;
select app.door(test.id('r8z_cs'), 'aal2', 'ops_do', 'record_booking_payment', jsonb_build_object('booking', (test.r8zb('b2')).booking_number, 'covers', 'rental',
  'method', 'e_transfer', 'reference', 'R8Z-ET-1', 'amount_cents', (app.booking_pay_schedule((test.r8zb('b2')).id) ->> 'per_cents')::bigint));
select test.eq('weekly, the first week recorded by hand: confirmed', (test.r8zb('b2')).status::text, 'confirmed');

-- ================================================================ 3011: partly paid, the car and the dates change
insert into test.r8z select 'b3', test.r8z_offer('car3', 'r8z.three@example.test', '+14165550193', interval '40 days', interval '3 days');
select test.r8z_ready('b3');
select test.ok('waiting for payment, nothing paid: still changed through the offer', app.booking_edit_refusal(test.id('r8z_admin'), test.r8zb('b3')) like '%not confirmed yet%');
select app.door(test.id('r8z_cs'), 'aal2', 'ops_do', 'record_booking_payment', jsonb_build_object('booking', (test.r8zb('b3')).booking_number, 'covers', 'rental',
  'method', 'e_transfer', 'reference', 'R8Z-ET-3', 'amount_cents', 5000));
select test.eq('part of it paid: still waiting for payment', (test.r8zb('b3')).status::text, 'pending_payment');
select test.throws('reopening the offer is refused with the way', format($$select app.offer_reopen_for_edit(%L, %L, true)$$, (test.r8zb('b3')).id, test.id('r8z_admin')), 'change the car or the dates with Edit booking');
select test.ok('Edit booking is open for it', app.booking_edit_refusal(test.id('r8z_admin'), test.r8zb('b3')) is null);
insert into test.r8z select 't3', jsonb_build_object('total', (test.r8zb('b3')).total_due_at_booking_cents, 'paid', app.booking_paid_cents((test.r8zb('b3')).id));
-- car1 is out with b1 from day 5 to day 34: moving b3 there over those days is refused; car2 free on b3's own dates
select test.throws('a car that is not free: refused', format($$select app.door(%L, 'aal2', 'ops_do', 'booking_staff_edit', %L)$$, test.id('r8z_admin'),
  jsonb_build_object('booking', (test.r8zb('b3')).booking_number, 'changes', jsonb_build_object('vehicle_id', (test.r8zv('car1') ->> 'vehicle_id')::uuid,
    'pickup_at', date_trunc('hour', now()) + interval '10 days', 'return_at', date_trunc('hour', now()) + interval '13 days'), 'reason', 'Move to a free car')), 'not free');
insert into test.r8z select 'e3', app.door(test.id('r8z_admin'), 'aal2', 'ops_do', 'booking_staff_edit', jsonb_build_object('booking', (test.r8zb('b3')).booking_number,
  'changes', jsonb_build_object('vehicle_id', (test.r8zv('car1') ->> 'vehicle_id')::uuid), 'reason', 'The renter asked for another car'));
select test.eq('the car changed', (test.r8zb('b3')).vehicle_id, (test.r8zv('car1') ->> 'vehicle_id')::uuid);
select test.eq('still waiting for payment, the price and the payments kept', (test.r8zb('b3')).status::text || '|' || (test.r8zb('b3')).total_due_at_booking_cents || '|' || app.booking_paid_cents((test.r8zb('b3')).id),
  'pending_payment|' || (test.r8zv('t3') ->> 'total') || '|' || (test.r8zv('t3') ->> 'paid'));
insert into test.r8z select 'e3b', app.door(test.id('r8z_admin'), 'aal2', 'ops_do', 'booking_staff_edit', jsonb_build_object('booking', (test.r8zb('b3')).booking_number,
  'changes', jsonb_build_object('return_at', (test.r8zb('b3')).return_at + interval '1 day'), 'reason', 'One more day'));
select test.eq('the dates change too, priced at its rates', ((test.r8zb('b3')).billable_days)::text || '|' || ((test.r8zb('b3')).total_due_at_booking_cents > (test.r8zv('t3') ->> 'total')::bigint)::text, '4|true');
select test.ok('recorded as a staff edit', (select count(*) from booking_staff_edits where booking_id = (test.r8zb('b3')).id) = 2);

-- ================================================================ 3012: the page names
select test.eq('one name for the endorsement page', app.opcf27_page_label('endorsement'), 'OPCF 27 endorsement page');

-- ================================================================ 3013: licence_let_go on the connector
create temp table r8z_ps as select id, api_access_enabled e, api_calls_per_minute n from program_settings;
update program_settings set api_access_enabled = true, api_calls_per_minute = 600 where id is not null;
create function test.r8z_h(p text) returns text language sql as $$ select encode(sha256(convert_to(p, 'UTF8')), 'hex') $$;
select app.api_key_create(test.id('r8z_admin'), test.id('r8z_admin'), 'Laptop', array['admin:read', 'admin:write'], test.r8z_h('cc_live_r8z_full'), 'cc_live_r8z_');
insert into api_keys (user_id, kind, name, prefix, key_hash, scopes, created_by)
select test.id('r8z_cs'), kind, 'Not an Admin', 'cc_live_r8zc', test.r8z_h('cc_live_r8z_cs'), scopes, test.id('r8z_admin') from api_keys where key_hash = test.r8z_h('cc_live_r8z_full');
create function test.r8z_api(p_key text, a jsonb) returns jsonb language sql as $$ select app.api_call(test.r8z_h(p_key), 'licence_let_go', a, 'test') $$;
select test.eq('the connector''s change_booking takes a partly paid booking too (preview)', app.api_call(test.r8z_h('cc_live_r8z_full'), 'change_booking',
  jsonb_build_object('booking', (test.r8zb('b3')).booking_number, 'changes', jsonb_build_object('vehicle_id', (test.r8zv('car2') ->> 'vehicle_id')::uuid), 'reason', 'Connector move')) #>> '{result,preview}', 'true');
select test.ok('no swap waiting: refused', test.r8z_api('cc_live_r8z_full', jsonb_build_object('booking', (test.r8zb('b3')).booking_number, 'reason', 'Licence checked by phone')) ->> 'error' like '%nothing to let go%');
insert into booking_primary_swaps (booking_id, from_driver_id, issuer, state)
select b.id, bd.driver_id, 'United Kingdom', 'needed' from bookings b join booking_drivers bd on bd.booking_id = b.id and bd.role = 'renter' where b.id = (test.r8zb('b3')).id;
select test.eq('not an Admin: refused', test.r8z_api('cc_live_r8z_cs', jsonb_build_object('booking', (test.r8zb('b3')).booking_number, 'reason', 'Licence checked by phone')) ->> 'status', '403');
select test.ok('a reason is needed', test.r8z_api('cc_live_r8z_full', jsonb_build_object('booking', (test.r8zb('b3')).booking_number, 'reason', 'ok')) ->> 'error' like 'reason:%');
insert into test.r8z select 'pv', test.r8z_api('cc_live_r8z_full', jsonb_build_object('booking', (test.r8zb('b3')).booking_number, 'reason', 'Licence checked by phone'));
select test.eq('the preview changes nothing', (test.r8zv('pv') #>> '{result,preview}') || '|' || (select state from booking_primary_swaps where booking_id = (test.r8zb('b3')).id), 'true|needed');
select test.ok('the preview says what it does', test.r8zv('pv') #>> '{result,will_do}' like 'Let Pat Plan keep the licence from United Kingdom%');
select test.eq('confirmed with other arguments: refused', test.r8z_api('cc_live_r8z_full', jsonb_build_object('booking', (test.r8zb('b3')).booking_number, 'reason', 'Another reason here',
  'confirm', true, 'preview_id', test.r8zv('pv') #>> '{result,preview_id}')) ->> 'ok', 'false');
insert into test.r8z select 'cf', test.r8z_api('cc_live_r8z_full', jsonb_build_object('booking', (test.r8zb('b3')).booking_number, 'reason', 'Licence checked by phone',
  'confirm', true, 'preview_id', test.r8zv('pv') #>> '{result,preview_id}'));
select test.eq('confirmed: let go', (test.r8zv('cf') #>> '{result,state}') || '|' || (select state || '|' || reason from booking_primary_swaps where booking_id = (test.r8zb('b3')).id),
  'overridden|overridden|Licence checked by phone (connector)');
select test.ok('the booking history says so', exists (select 1 from booking_events e where e.booking_id = (test.r8zb('b3')).id and e.note like 'Main driver kept with a licence from outside Ontario: Licence checked by phone%'));
select test.ok('the calls are logged', (select count(*) from api_calls where tool like 'licence_let_go%') >= 5);
update program_settings p set api_access_enabled = s.e, api_calls_per_minute = s.n from r8z_ps s where s.id = p.id;
