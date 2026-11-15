-- 99: a pay link for the booking's money asks for what is owed, never more (migration 2921). Fixtures "r8p"; example.test only.
select test.suite('99 r48 pay links');


select test.mk_user('r8p_admin', 'admin');
select test.mk_user('r8p_cs', 'va', 'cs');
update staff_profiles set single_limit_cents = 500000 where user_id = test.id('r8p_cs');

create table test.r8p (k text primary key, v jsonb);
grant select on test.r8p to authenticated, service_role;
create function test.r8pv(p text) returns jsonb language sql stable as $$ select v from test.r8p where k = p $$;
create function test.r8pb(p text) returns bookings language sql stable security definer as $$
  select * from public.bookings where id = coalesce((test.r8pv(p) ->> 'booking_id')::uuid, (test.r8pv(p) ->> 'id')::uuid) $$;
create function test.r8pu(p text) returns uuid language sql stable security definer as $$
  select r.user_id from public.renters r where r.id = (test.r8pb(p)).renter_id $$;
do $$
declare i integer;
begin
  for i in 1 .. 2 loop
    insert into test.r8p select 'car' || i, app.vehicle_add(test.id('r8p_admin'), jsonb_build_object('supply_type', 'company', 'vin', '1XFCXMM00000048' || lpad(i::text, 2, '0'),
      'plate', 'R8P00' || i, 'year', 2024, 'make', 'Kia', 'model', 'K5', 'rates', jsonb_build_object('daily', 10000, 'weekend', 10000, 'weekly', 70000, 'monthly', 300000, 'deposit', 30000)));
  end loop;
end $$;
create function test.r8p_offer(p_car text, p_email text, p_mobile text, p_from interval) returns jsonb language sql as $$
  select app.door(test.id('r8p_cs'), 'aal2', 'ops_do', 'offer_create', jsonb_build_object('vehicle_id', (test.r8pv(p_car) ->> 'vehicle_id')::uuid,
    'pickup_at', date_trunc('hour', now()) + p_from, 'return_at', date_trunc('hour', now()) + p_from + interval '3 days',
    'renter', jsonb_build_object('full_name', 'Pat Owed', 'email', p_email, 'mobile', p_mobile, 'date_of_birth', '1990-05-06'),
    'coverage_option', 1, 'sales_choice', 'sourced', 'channels', jsonb_build_object('email', false, 'text', false), 'notify', false)) $$;
create function test.r8p_ready(p text) returns void language plpgsql as $$
declare v_driver uuid := (select bd.driver_id from booking_drivers bd where bd.booking_id = (test.r8pb(p)).id and bd.role = 'renter');
  k text;
begin
  foreach k in array array['licence_front', 'licence_back', 'selfie'] loop
    perform app.register_verification_upload((test.r8pb(p)).id, test.r8pu(p), k, v_driver, 'renters/r8p/' || p || '-' || k || '-' || gen_random_uuid() || '.jpg', repeat('e', 64), 'image/jpeg', null, 'identity');
  end loop;
  perform public.renter_save_details(test.r8pu(p), jsonb_build_object('licence_number', 'P1234-12345-12345', 'licence_issuer', 'ON', 'licence_class', 'G',
    'licence_expiry', (now() + interval '3 years')::date), (test.r8pb(p)).id);
  perform public.renter_approve_offer((test.r8pb(p)).id, (test.r8pb(p)).current_offer_version, test.r8pu(p));
  perform public.renter_open_agreement((test.r8pb(p)).id, test.r8pu(p), 'rental-test', repeat('e', 64), 'bookings/r8p/' || p || '.pdf');
  perform public.renter_sign_agreement((test.r8pb(p)).id, test.r8pu(p), 'I agree', repeat('e', 64),
    '[{"code":"tracking_disabling","version":"v","text":"t"},{"code":"identity_verification","version":"v","text":"t"},{"code":"electronic_signature","version":"v","text":"t"},{"code":"card_authorization","version":"v","text":"t"}]'::jsonb, 'Pat Owed');
end $$;
create function test.r8p_link(p text, p_covers text, p_amount bigint default null) returns uuid language plpgsql as $$
declare v jsonb;
begin
  v := app.door(test.id('r8p_cs'), 'aal2', 'ops_do', 'payreq_create', jsonb_build_object('booking', (test.r8pb(p)).booking_number, 'kind', 'charge', 'covers', p_covers,
    'amount_cents', p_amount, 'channel', 'text', 'token_sha256', md5(random()::text) || md5(random()::text)));
  perform public.server_payreq_attach((v ->> 'id')::uuid, 'pi_r8p_' || (v ->> 'id'));
  return (v ->> 'id')::uuid;
end $$;
create function test.r8p_pay(p_req uuid) returns jsonb language sql as $$
  select public.server_payreq_settle(p_req, jsonb_build_object('id', 'pi_r8p_' || p_req, 'status', 'succeeded', 'amount', (select amount_cents from payment_requests where id = p_req),
    'charge_id', 'ch_r8p', 'customer_id', 'cus_r8p', 'method_id', 'pm_r8p_' || left(p_req::text, 8),
    'card', jsonb_build_object('brand', 'visa', 'last4', '4242', 'exp_month', 12, 'exp_year', 2030, 'funding', 'credit', 'name', 'Pat Owed', 'fingerprint', 'fp_r8p'))) $$;

create function test.r8p_web(p text) returns jsonb language sql as $$
  select public.server_record_booking_payment((test.r8pb(p)).id, jsonb_build_object('processor', 'stripe', 'payment_id', 'pi_r8p_web_' || p, 'charge_id', 'ch_r8p', 'customer_id', 'cus_r8p', 'method_id', 'pm_r8p', 'fingerprint', 'fp_r8p'),
    (test.r8pb(p)).total_due_at_booking_cents, (test.r8pb(p)).current_offer_version,
    '{"brand": "visa", "last4": "4242", "cardholder_name": "Pat Owed", "exp_month": 12, "exp_year": 2030, "is_credit": true, "funding": "credit"}'::jsonb, 'ev_r8p_' || p, test.r8pu(p)) $$;
create function test.r8p_admin_link(p text, p_covers text, p_amount bigint default null) returns jsonb language sql as $$
  select app.door(test.id('r8p_admin'), 'aal2', 'ops_do', 'payreq_create', jsonb_build_object('booking', (test.r8pb(p)).booking_number, 'kind', 'charge', 'covers', p_covers,
    'amount_cents', p_amount, 'channel', 'text', 'token_sha256', md5(random()::text) || md5(random()::text))) $$;

-- ================================================================ paid in full on the website: no balance link
insert into test.r8p select 'b1', test.r8p_offer('car1', 'pat.owed@example.test', '(289) 555-0848', interval '5 days');
select test.r8p_ready('b1');
select test.r8p_web('b1');
select test.eq('paid on the website: confirmed, nothing owed', (test.r8pb('b1')).status::text || '/' || app.booking_amount_owed((test.r8pb('b1')).id), 'confirmed/0');
select test.throws('nothing owed: customer service gets no balance link', $$select test.r8p_link('b1', 'balance')$$, '%Nothing is owed on booking%paid in full%');
select test.throws('nothing owed: nor an Admin, even with an amount typed', format($$select test.r8p_admin_link('b1', 'balance', %s)$$, (test.r8pb('b1')).total_due_at_booking_cents), '%Nothing is owed%');
select test.throws('nor a rental link', $$select test.r8p_admin_link('b1', 'rental')$$, '%Nothing is owed%');
select test.lives('a later charge (with its reason) is still possible', $$select app.door(test.id('r8p_admin'), 'aal2', 'ops_do', 'payreq_create', jsonb_build_object('booking', (test.r8pb('b1')).booking_number,
  'kind', 'charge', 'covers', 'later', 'amount_cents', 2500, 'reason', 'Fuel', 'channel', 'text', 'token_sha256', md5(random()::text) || md5(random()::text)))$$);

-- ================================================================ the total changes after the payment: the link is for the difference
insert into test.r8p select 'tot0', jsonb_build_object('v', (test.r8pb('b1')).total_due_at_booking_cents);
select app.door(test.id('r8p_admin'), 'aal2', 'ops_do', 'booking_custom_fee', jsonb_build_object('booking', (test.r8pb('b1')).booking_number, 'label', 'Child seat', 'amount_cents', 5000, 'hst', true, 'reason', 'Asked at the counter'));
select test.eq('owed is the difference only', app.booking_amount_owed((test.r8pb('b1')).id), (test.r8pb('b1')).total_due_at_booking_cents - (test.r8pv('tot0') ->> 'v')::bigint);
insert into test.r8p select 'd1', test.r8p_admin_link('b1', 'balance');
select test.eq('the link defaults to the difference', (test.r8pv('d1') ->> 'amount_cents')::bigint, 5650::bigint);
select test.throws('the whole new total is refused, even for an Admin', format($$select test.r8p_admin_link('b1', 'balance', %s)$$, (test.r8pb('b1')).total_due_at_booking_cents), '%more than is owed on booking%');
select test.eq('the refused link changed nothing: the difference link stays open', (select status from payment_requests where id = (test.r8pv('d1') ->> 'id')::uuid), 'open');

-- a second link replaces the first (a rental link and a balance link are never both open)
insert into test.r8p select 'd2', test.r8p_admin_link('b1', 'fees');
select test.eq('the older balance link is cancelled by the new fees link', (select status from payment_requests where id = (test.r8pv('d1') ->> 'id')::uuid), 'cancelled');
select test.eq('one open link for the booking''s money', (select count(*) from payment_requests where booking_id = (test.r8pb('b1')).id and status = 'open' and covers in ('rental', 'fees', 'balance')), 1::bigint);

-- ================================================================ a payment lands: links for more than is owed are cancelled
insert into test.r8p select 'b2', test.r8p_offer('car2', 'pat.owed2@example.test', '(289) 555-0849', interval '7 days');
select test.r8p_ready('b2');
insert into test.r8p select 'l2', jsonb_build_object('id', test.r8p_link('b2', 'balance'));
select test.eq('waiting for payment: the link is for everything owed', (select amount_cents from payment_requests where id = (test.r8pv('l2') ->> 'id')::uuid), app.booking_amount_owed((test.r8pb('b2')).id));
select test.r8p_web('b2');
select test.eq('the renter paid on the website: the open link is cancelled by itself', (select status from payment_requests where id = (test.r8pv('l2') ->> 'id')::uuid), 'cancelled');
select test.ok('it says why', (select last_error like 'Cancelled by itself: a payment landed%' from payment_requests where id = (test.r8pv('l2') ->> 'id')::uuid));
select test.eq('the pay page refuses it before charging', public.server_payreq_still_owed((test.r8pv('l2') ->> 'id')::uuid) ->> 'ok', 'false');
select test.ok('the booking history says so', exists (select 1 from booking_events e where e.booking_id = (test.r8pb('b2')).id and e.note like '%cancelled by itself%'));

-- a link paid through the link itself is not cancelled by its own payment
insert into test.r8p select 'b3', test.r8p_offer('car1', 'pat.owed3@example.test', '(289) 555-0850', interval '20 days');
select test.r8p_ready('b3');
insert into test.r8p select 'l3', jsonb_build_object('id', test.r8p_link('b3', 'balance'));
select test.r8p_pay((test.r8pv('l3') ->> 'id')::uuid);
select test.eq('paid by its own link: paid, nothing owed', (select status from payment_requests where id = (test.r8pv('l3') ->> 'id')::uuid) || '/' || app.booking_amount_owed((test.r8pb('b3')).id), 'paid/0');
select test.throws('then no balance link', $$select test.r8p_link('b3', 'balance')$$, '%Nothing is owed%');

-- a link that grew too large while open (the total went down) is refused at the pay page
insert into test.r8p select 'b4', test.r8p_offer('car2', 'pat.owed4@example.test', '(289) 555-0851', interval '25 days');
select test.r8p_ready('b4');
insert into test.r8p select 'l4', jsonb_build_object('id', test.r8p_link('b4', 'balance'));
update payment_requests set amount_cents = amount_cents + 10000 where id = (test.r8pv('l4') ->> 'id')::uuid;
select test.eq('more than is owed: the pay page refuses it', public.server_payreq_still_owed((test.r8pv('l4') ->> 'id')::uuid) ->> 'ok', 'false');
select public.server_payreq_void_overpaying((test.r8pv('l4') ->> 'id')::uuid);
select test.eq('and it is cancelled', (select status from payment_requests where id = (test.r8pv('l4') ->> 'id')::uuid), 'cancelled');

-- refunds count back: a refund of part of the payment is owed again
select test.eq('owed counts refunds back', (select app.booking_amount_owed((test.r8pb('b3')).id) from (select 1) z), 0::bigint);
insert into payments (booking_id, renter_id, purpose, kind, method, amount_cents, status, parent_payment_id, processed_at)
select (test.r8pb('b3')).id, (test.r8pb('b3')).renter_id, 'booking_total', 'refund', 'card', 1000, 'succeeded', q.payment_id, now()
  from payment_requests q where q.id = (test.r8pv('l3') ->> 'id')::uuid;
select test.eq('a $10 refund: $10 owed again', app.booking_amount_owed((test.r8pb('b3')).id), 1000::bigint);

-- ================================================================ 2923: the sweep of links already out
-- the live example: a booking paid in full by card with an open staff balance link for another amount (made before 2921)
insert into test.r8p select 'b5', test.r8p_offer('car1', 'pat.owed5@example.test', '(289) 555-0852', interval '30 days');
select test.r8p_ready('b5');
select test.r8p_web('b5');
insert into payment_requests (booking_id, renter_id, kind, covers, amount_cents, reason, token_sha256, channel, expires_at, created_by, processor_intent_id)
select b.id, b.renter_id, 'charge', 'balance', 12345, 'the balance', md5('r8p5a') || md5('r8p5b'), 'text', now() + interval '3 days', test.id('r8p_admin'), 'pi_r8p_old_balance'
  from bookings b where b.id = (test.r8pb('b5')).id;
insert into payment_requests (booking_id, renter_id, kind, covers, amount_cents, reason, token_sha256, channel, expires_at, created_by, processor_intent_id)
select b.id, b.renter_id, 'hold', 'deposit', b.deposit_cents, 'deposit', md5('r8p5c') || md5('r8p5d'), 'text', now() + interval '3 days', test.id('r8p_admin'), 'pi_r8p_old_hold'
  from bookings b where b.id = (test.r8pb('b5')).id and b.deposit_cents > 0;
select test.ok('the sweep cancels at least that link', app.payreq_sweep_overpaying() >= 1);
select test.eq('the balance link on the paid booking is cancelled, with why', (select status || '|' || (last_error like 'Cancelled by release 48: nothing is owed%')::text from payment_requests where processor_intent_id = 'pi_r8p_old_balance'), 'cancelled|true');
select test.ok('a deposit hold link is left alone', not exists (select 1 from payment_requests where processor_intent_id = 'pi_r8p_old_hold' and status <> 'open'));
select test.ok('logged on the booking', exists (select 1 from booking_events e where e.booking_id = (test.r8pb('b5')).id and e.note like 'Pay link for $123.45 cancelled: nothing is owed%'));
select test.ok('and in the audit log', exists (select 1 from audit_log where action = 'pay_links_swept'));
select test.eq('a second sweep finds nothing', app.payreq_sweep_overpaying(), 0);

-- ================================================================ 2923: cancel_pay_link on the connector
create temp table r8p_ps as select id, api_access_enabled e, api_calls_per_minute n from program_settings;
update program_settings set api_access_enabled = true, api_calls_per_minute = 600 where id is not null;
create function test.r8p_h(p text) returns text language sql as $$ select encode(sha256(convert_to(p, 'UTF8')), 'hex') $$;
select app.api_key_create(test.id('r8p_admin'), test.id('r8p_admin'), 'Laptop', array['admin:read', 'admin:write'], test.r8p_h('cc_live_r8p_full'), 'cc_live_r8p_');
insert into api_keys (user_id, kind, name, prefix, key_hash, scopes, created_by)
select test.id('r8p_cs'), kind, 'Not an Admin', 'cc_live_r8pc', test.r8p_h('cc_live_r8p_cs'), scopes, test.id('r8p_admin') from api_keys where key_hash = test.r8p_h('cc_live_r8p_full');
create function test.r8p_api(p_key text, a jsonb) returns jsonb language sql as $$ select app.api_call(test.r8p_h(p_key), 'cancel_pay_link', a, 'test') $$;
-- an open later-charge link on b1 with an intent
insert into test.r8p select 'l6', app.door(test.id('r8p_admin'), 'aal2', 'ops_do', 'payreq_create', jsonb_build_object('booking', (test.r8pb('b1')).booking_number,
  'kind', 'charge', 'covers', 'later', 'amount_cents', 1500, 'reason', 'Fuel', 'channel', 'text', 'token_sha256', md5(random()::text) || md5(random()::text)));
update payment_requests set processor_intent_id = 'pi_r8p_cancel_me' where id = (test.r8pv('l6') ->> 'id')::uuid;
select test.eq('not an Admin: refused', test.r8p_api('cc_live_r8p_cs', '{"payment_intent": "pi_r8p_cancel_me"}') ->> 'status', '403');
insert into test.r8p select 'pv6', test.r8p_api('cc_live_r8p_full', '{"payment_intent": "pi_r8p_cancel_me"}');
select test.eq('the preview changes nothing', (test.r8pv('pv6') #>> '{result,preview}') || '|' || (select status from payment_requests where id = (test.r8pv('l6') ->> 'id')::uuid), 'true|open');
select test.ok('the preview shows the link', test.r8pv('pv6') #>> '{result,link,amount_cents}' = '1500');
select test.eq('confirmed with other arguments: refused', test.r8p_api('cc_live_r8p_full', jsonb_build_object('payment_intent', 'pi_r8p_old_hold', 'confirm', true, 'preview_id', test.r8pv('pv6') #>> '{result,preview_id}')) ->> 'ok', 'false');
insert into test.r8p select 'c6', test.r8p_api('cc_live_r8p_full', jsonb_build_object('payment_intent', 'pi_r8p_cancel_me', 'confirm', true, 'preview_id', test.r8pv('pv6') #>> '{result,preview_id}'));
select test.eq('confirmed: cancelled, nothing charged, the web layer told to cancel the intent', (test.r8pv('c6') #>> '{result,run}') || '|' || (test.r8pv('c6') #>> '{result,charged}') || '|' || (select status from payment_requests where id = (test.r8pv('l6') ->> 'id')::uuid), 'pay_link_cancel|false|cancelled');
select test.eq('the preview is used once', test.r8p_api('cc_live_r8p_full', jsonb_build_object('payment_intent', 'pi_r8p_cancel_me', 'confirm', true, 'preview_id', test.r8pv('pv6') #>> '{result,preview_id}')) ->> 'ok', 'false');
select test.ok('already cancelled: refused', test.r8p_api('cc_live_r8p_full', '{"payment_intent": "pi_r8p_cancel_me"}') ->> 'error' like '%already cancelled%');
select test.ok('a paid link: refused (that is a refund)', test.r8p_api('cc_live_r8p_full', jsonb_build_object('payment_intent', 'pi_r8p_' || (test.r8pv('l3') ->> 'id'))) ->> 'error' like '%is paid: nothing to cancel%');
select test.eq('an unknown intent: not found', test.r8p_api('cc_live_r8p_full', '{"payment_intent": "pi_r8p_nobody"}') ->> 'status', '404');
select test.ok('the calls are logged', (select count(*) from api_calls where tool like 'cancel_pay_link%') >= 5);
update program_settings p set api_access_enabled = s.e, api_calls_per_minute = s.n from r8p_ps s where s.id = p.id;
