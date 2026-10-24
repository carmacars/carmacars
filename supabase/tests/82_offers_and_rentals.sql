-- 82: offers and rentals made easy (migration 0129): an offer sent without a request (the customer found or made, no
-- "request received" email, email or text or neither, the preview rolled back), an offer edited in place (sent again in
-- one step, or saved quietly; approved and unpaid too), payments by part and method (the rental by e-Transfer and the
-- deposit in cash, confirmed by staff once signed and paid; the cash deposit given back as cash), a rental added by hand
-- with the deposit method, a platform payout, paper and the calendar switch, card requests (hold, charge) and the
-- Protection Plan wording. Fixtures start with "of".
select test.suite('82 offers and rentals');

select test.mk_user('of_admin', 'admin');
select test.mk_user('of_cs', 'va', 'cs');
select test.mk_user('of_sales', 'va', 'sales');
select test.mk_user('of_fin', 'va', 'finance');
select test.mk_user('of_fleet', 'va', 'fleet');
select test.mk_renter('of_rita');
update staff_profiles set single_limit_cents = 500000 where user_id in (test.id('of_cs'), test.id('of_fin'), test.id('of_sales'));

create table test.of (k text primary key, v jsonb);
grant select on test.of to authenticated, service_role;
create function test.ofv(p text) returns jsonb language sql stable as $$ select v from test.of where k = p $$;
create function test.ofb(p text) returns bookings language sql stable security definer as $$
  select * from public.bookings where id = coalesce((test.ofv(p) ->> 'booking_id')::uuid, (test.ofv(p) ->> 'id')::uuid) $$;
create function test.ofu(p text) returns uuid language sql stable security definer as $$
  select r.user_id from public.renters r where r.id = (test.ofb(p)).renter_id $$;
do $$
declare i integer;
begin
  for i in 1 .. 6 loop
    insert into test.of select 'car' || i, app.vehicle_add(test.id('of_admin'), jsonb_build_object('supply_type', 'company', 'vin', '1XFCXMM00000000' || lpad(i::text, 2, '0'),
      'plate', 'OFC00' || i, 'year', 2024, 'make', 'Kia', 'model', 'K5', 'rates', jsonb_build_object('daily', 10000, 'weekend', 10000, 'weekly', 70000, 'monthly', 300000, 'deposit', 30000)));
  end loop;
end $$;
create function test.ofcar(p text) returns uuid language sql stable as $$ select (test.ofv(p) ->> 'vehicle_id')::uuid $$;
create function test.ofreq(p_car text, p_from interval, p_to interval, p jsonb default '{}'::jsonb) returns jsonb language sql stable as $$
  select jsonb_build_object('vehicle_id', test.ofcar(p_car), 'pickup_at', date_trunc('hour', now()) + p_from, 'return_at', date_trunc('hour', now()) + p_to,
    'renter', jsonb_build_object('full_name', 'Nora Offer', 'email', 'nora.offer@example.test', 'mobile', '(289) 555-0817', 'date_of_birth', '1991-02-03'),
    'coverage_option', 1, 'sales_choice', 'sourced', 'channels', jsonb_build_object('email', true, 'text', false)) || p $$;
-- the licence the renter uploads before accepting (0130's gate)
create function test.of_licence(p text) returns void language plpgsql as $$
declare v_driver uuid := (select bd.driver_id from booking_drivers bd where bd.booking_id = (test.ofb(p)).id and bd.role = 'renter');
  k text;
begin
  foreach k in array array['licence_front', 'licence_back', 'selfie'] loop
    perform app.register_verification_upload((test.ofb(p)).id, test.ofu(p), k, v_driver, 'renters/of/' || p || '-' || k || '-' || gen_random_uuid() || '.jpg', repeat('e', 64), 'image/jpeg', null, 'identity');
  end loop;
  perform public.renter_save_details(test.ofu(p), jsonb_build_object('licence_number', 'N1234-12345-12345', 'licence_issuer', 'ON', 'licence_class', 'G',
    'licence_expiry', (now() + interval '3 years')::date), (test.ofb(p)).id);
end $$;
create function test.of_consents() returns jsonb language sql immutable as $$
  select '[{"code":"tracking_disabling","version":"v","text":"t"},{"code":"identity_verification","version":"v","text":"t"},{"code":"electronic_signature","version":"v","text":"t"},{"code":"card_authorization","version":"v","text":"t"}]'::jsonb $$;

-- ================================================================ 1. an offer without a request
select test.throws('who: fleet sends no offer', $$select app.door(test.id('of_fleet'), 'aal2', 'ops_do', 'offer_create', test.ofreq('car1', interval '3 days', interval '6 days'))$$, 'customer service or sales');
select test.throws('a new customer needs a date of birth', $$select app.door(test.id('of_cs'), 'aal2', 'ops_do', 'offer_create',
  test.ofreq('car1', interval '3 days', interval '6 days', '{"renter": {"full_name": "No Birthday", "email": "nob@example.test", "mobile": "4165550100"}}'))$$, 'date of birth');
select test.throws('an assistant does not change the deposit', $$select app.door(test.id('of_cs'), 'aal2', 'ops_do', 'offer_create',
  test.ofreq('car1', interval '3 days', interval '6 days', '{"deposit_cents": 10000}'))$$, 'Only an Admin');

select test.eq('the preview: priced, the renter view, and nothing kept',
  (select (x ->> 'ok') || '/' || (x #>> '{booking,status}') || '/' || (x #>> '{booking,rental_charge_cents}') || '/' || (select count(*) from bookings where vehicle_id = test.ofcar('car1'))
     from (select app.door(test.id('of_cs'), 'aal2', 'ops_read', 'offer_preview', test.ofreq('car1', interval '3 days', interval '6 days')) x) q),
  'true/requested/30000/0');
select test.eq('the preview: nobody was made either', (select count(*) from renters where lower(email) = 'nora.offer@example.test'), 0::bigint);

insert into test.of select 'o1', app.door(test.id('of_cs'), 'aal2', 'ops_do', 'offer_create',
  test.ofreq('car1', interval '3 days', interval '6 days', '{"message": "As discussed on the phone", "rental_charge_cents": 25000, "price_reason": "Phone deal", "rental_pay_method": "e_transfer", "deposit_pay_method": "cash"}'));
select test.eq('sent at once: offered, version 1, the price typed, the payment plan',
  (select status || '/' || current_offer_version || '/' || rental_charge_cents || '/' || rental_pay_method || '/' || deposit_pay_method from test.ofb('o1')), 'offered/1/25000/e_transfer/cash');
select test.eq('the same records as a request: a request event, then the offer', (select string_agg(kind, ',' order by created_at, id) filter (where kind in ('requested', 'offer_sent')) from booking_events where booking_id = (test.ofb('o1')).id), 'requested,offer_sent');
select test.eq('no "request received" to the renter, no new-request alert to staff; the offer email is queued',
  (select string_agg(distinct code, ',' order by code) from app_events where entity_id = (test.ofb('o1')).id and code in ('renter_request_received', 'staff_booking_request_new', 'renter_offer_ready')), 'renter_offer_ready');
select test.eq('the customer was made once, with the sales choice (sourced by the assistant)',
  (select count(*) || '/' || (select sales_sourced from test.ofb('o1')) from renters where lower(email) = 'nora.offer@example.test'), '1/true');

-- the same person again, by mobile only: found, not made twice
insert into test.of select 'o2', app.door(test.id('of_sales'), 'aal2', 'ops_do', 'offer_create',
  test.ofreq('car2', interval '10 days', interval '12 days', '{"renter": {"full_name": "N. Offer", "email": "", "mobile": "289 555 0817"}, "notify": false}'));
select test.eq('found by mobile: the same customer', (test.ofb('o2')).renter_id, (test.ofb('o1')).renter_id);
select test.eq('not notified: no offer email for this one', (select count(*) from app_events where entity_id = (test.ofb('o2')).id and code = 'renter_offer_ready'), 0::bigint);
select test.eq('the customer search finds her by phone digits', (select count(*) from jsonb_array_elements(app.door(test.id('of_cs'), 'aal2', 'ops_read', 'find_customers', '{"q": "5550817"}'))), 1::bigint);

-- an Admin: the deposit and a fee, text only
insert into test.of select 'o3', app.door(test.id('of_admin'), 'aal2', 'ops_do', 'offer_create',
  test.ofreq('car3', interval '4 days', interval '6 days', jsonb_build_object('renter_id', test.id('renter:of_rita'), 'deposit_cents', 50000, 'channels', jsonb_build_object('email', false, 'text', true))));
select test.eq('an Admin sets the deposit', (test.ofb('o3')).deposit_cents, 50000::bigint);
select test.eq('text only: no offer email; the text is queued to the renter''s mobile (as staff)',
  (select count(*) from app_events where entity_id = (test.ofb('o3')).id and code = 'renter_offer_ready') || '/' || (select count(*) || ':' || min(kind) from phone_outbox where booking_id = (test.ofb('o3')).id),
  '0/1:staff');
select test.eq('the text names the booking and the offer link', (select body like '%' || (test.ofb('o3')).booking_number || '%' and body like '%/account/bookings/' || (test.ofb('o3')).booking_number || '/offer%' from phone_outbox where booking_id = (test.ofb('o3')).id), true);

-- ================================================================ 2. an offer edited in place
insert into test.of select 'r1', app.door(test.id('of_cs'), 'aal2', 'admin_do', 'offer_revise', jsonb_build_object('booking', (test.ofb('o1')).booking_number,
  'changes', jsonb_build_object('rental_charge_cents', 27000, 'price_reason', 'One more day of cleaning', 'return_at', (test.ofb('o1')).return_at + interval '1 day'),
  'message', 'One more day, as you asked', 'expires_at', now() + interval '24 hours'));
select test.eq('edited and sent again in one step: version 2, offered, the new price and return',
  (select status || '/' || current_offer_version || '/' || rental_charge_cents from test.ofb('o1')) || '/' || ((test.ofv('r1') ->> 'was')), 'offered/2/27000/offered');
select test.eq('the old version is superseded, not withdrawn', (select string_agg(version || ':' || status, ',' order by version) from booking_offers where booking_id = (test.ofb('o1')).id), '1:superseded,2:sent');
select test.eq('the renter gets the revised offer, not a "withdrawn" email', (select string_agg(code, ',' order by id) from app_events where entity_id = (test.ofb('o1')).id and code like 'renter_offer%'), 'renter_offer_ready,renter_offer_ready');
select test.eq('the diff: the total before and after', (test.ofv('r1') #>> '{before,total_cents}')::bigint < (test.ofv('r1') #>> '{after,total_cents}')::bigint, true);
select test.throws('an assistant still does not change fees in place', $$select app.door(test.id('of_cs'), 'aal2', 'va_do', 'offer_revise', jsonb_build_object('booking', (test.ofb('o1')).booking_number, 'fee_terms', '[]'::jsonb))$$, 'Only an Admin');

insert into test.of select 'r2', app.door(test.id('of_admin'), 'aal2', 'admin_do', 'offer_revise', jsonb_build_object('booking', (test.ofb('o1')).booking_number,
  'changes', jsonb_build_object('deposit_cents', 40000), 'notify', false));
select test.eq('saved quietly: version 3, no third offer email', (select current_offer_version || '/' || deposit_cents from test.ofb('o1')) || '/' ||
  (select count(*) from app_events where entity_id = (test.ofb('o1')).id and code = 'renter_offer_ready'), '3/40000/2');

-- approved, not paid: still edited in place
select test.of_licence('o1');
select public.renter_approve_offer((test.ofb('o1')).id, 3, test.ofu('o1'));
select test.eq('approved: waiting for signature and payment', (test.ofb('o1')).status::text, 'pending_payment');
insert into test.of select 'r3', app.door(test.id('of_admin'), 'aal2', 'admin_do', 'offer_revise', jsonb_build_object('booking', (test.ofb('o1')).booking_number,
  'changes', jsonb_build_object('deposit_cents', 30000), 'notify', false));
select test.eq('an approved offer edited: back to offered as version 4 (the renter approves the new one)', (select status || '/' || current_offer_version || '/' || coalesce(offer_approved_version::text, '-') from test.ofb('o1')), 'offered/4/-');

select test.eq('the review screen previews an offer that is out (as if open), and keeps it as it was',
  (select (x ->> 'ok') || '/' || (x #>> '{booking,deposit_cents}') from (select app.admin_booking_preview(test.id('of_admin'), (test.ofb('o1')).id, '{"changes": {"deposit_cents": 12300}}') x) q)
  || '/' || (test.ofb('o1')).status || '/' || (test.ofb('o1')).deposit_cents, 'true/12300/offered/30000');

-- ================================================================ 3. payments by part and method
select public.renter_approve_offer((test.ofb('o1')).id, 4, test.ofu('o1'));
select test.throws('sales does not edit an approved offer', $$select app.offer_revise(test.id('of_sales'), jsonb_build_object('booking', (test.ofb('o1')).booking_number))$$, 'requests and offers only');
select test.eq('the renter approved: customer service has a task to record the e-Transfer and confirm',
  (select count(*) from tasks where booking_id = (test.ofb('o1')).id and task_type = 'confirm_offline_booking' and status = 'open'), 1::bigint);
insert into test.of select 'money1', app.door(test.id('of_cs'), 'aal2', 'ops_read', 'booking_money', jsonb_build_object('booking', (test.ofb('o1')).booking_number));
select test.eq('what is open: the rental (with its tax); no fees on this booking, nothing later', (select string_agg(x ->> 'covers' || ':' || ((x ->> 'open_cents')::bigint > 0), ',') from jsonb_array_elements(test.ofv('money1') -> 'parts') x),
  'rental:true,fees:false,later:false');
select test.eq('the rental part is the rental charge with its HST', (test.ofv('money1') -> 'parts' -> 0 ->> 'open_cents')::bigint, 30510::bigint);
select test.throws('a card is not "received another way"', $$select app.door(test.id('of_cs'), 'aal2', 'ops_do', 'record_booking_payment', jsonb_build_object('booking', (test.ofb('o1')).booking_number, 'covers', 'rental', 'method', 'card'))$$, 'Collect a card');
select test.throws('an e-Transfer needs its reference', $$select app.door(test.id('of_cs'), 'aal2', 'ops_do', 'record_booking_payment', jsonb_build_object('booking', (test.ofb('o1')).booking_number, 'covers', 'rental', 'method', 'e_transfer'))$$, 'reference');
select test.throws('fleet records no payment', $$select app.door(test.id('of_fleet'), 'aal2', 'ops_do', 'record_booking_payment', jsonb_build_object('booking', (test.ofb('o1')).booking_number, 'covers', 'rental', 'method', 'cash'))$$, null);
insert into test.of select 'p1', app.door(test.id('of_cs'), 'aal2', 'ops_do', 'record_booking_payment', jsonb_build_object('booking', (test.ofb('o1')).booking_number, 'covers', 'rental', 'method', 'e_transfer', 'reference', 'CA1234XYZ'));
select test.eq('the rental by e-Transfer: paid in full, nothing open for it; not confirmed (not signed)',
  (test.ofv('p1') ->> 'open_cents') || '/' || (test.ofv('p1') ->> 'confirmed') || '/' || (test.ofb('o1')).status, '0/false/pending_payment');
select test.eq('the same reference twice is the same payment', (app.door(test.id('of_cs'), 'aal2', 'ops_do', 'record_booking_payment', jsonb_build_object('booking', (test.ofb('o1')).booking_number, 'covers', 'rental', 'method', 'e_transfer', 'reference', 'ca1234xyz')) ->> 'repeat'), 'true');
select test.eq('the rental lines carry the payment; the fee lines wait for theirs',
  (select bool_and(payment_id is not null) filter (where charge_type = 'rental_charge') || '/' || coalesce(bool_and(payment_id is null) filter (where charge_type <> 'rental_charge'), true)
     from booking_line_items where booking_id = (test.ofb('o1')).id and stage = 'booking' and voided_at is null and charged_to_renter), 'true/true');
select test.eq('not confirmed: the agreement is not signed', (test.ofv('p1') -> 'confirm' ->> 'reason') like '%not signed%', true);
select test.throws('nothing open for the fees: nothing to record', $$select app.door(test.id('of_cs'), 'aal2', 'ops_do', 'record_booking_payment', jsonb_build_object('booking', (test.ofb('o1')).booking_number, 'covers', 'fees', 'method', 'cash'))$$, 'nothing is open');
select test.throws('confirm by hand: refused with the reason', $$select app.door(test.id('of_cs'), 'aal2', 'ops_do', 'confirm_offline_booking', jsonb_build_object('booking', (test.ofb('o1')).booking_number))$$, 'not signed');
select public.renter_open_agreement((test.ofb('o1')).id, test.ofu('o1'), 'rental-test', repeat('e', 64), 'bookings/o1/x.pdf');
select public.renter_sign_agreement((test.ofb('o1')).id, test.ofu('o1'), 'I agree', repeat('e', 64), test.of_consents(), 'Nora Offer');
select test.eq('signed and paid: staff confirm', app.door(test.id('of_cs'), 'aal2', 'ops_do', 'confirm_offline_booking', jsonb_build_object('booking', (test.ofb('o1')).booking_number)) ->> 'status', 'confirmed');
select test.eq('confirmed, with no card on file (the deposit is cash): the agreement completed', (select b.status || '/' || (b.card_on_file_id is null) || '/' || s.status from test.ofb('o1') b join signature_requests s on s.id = b.signature_request_id), 'confirmed/true/completed');
select test.eq('the confirmation task is done', (select count(*) from tasks where booking_id = (test.ofb('o1')).id and task_type = 'confirm_offline_booking' and status = 'open'), 0::bigint);

-- the deposit in cash
select test.throws('a deposit in full only', $$select app.door(test.id('of_cs'), 'aal2', 'ops_do', 'record_booking_payment', jsonb_build_object('booking', (test.ofb('o1')).booking_number, 'covers', 'deposit', 'method', 'cash', 'amount_cents', 100))$$, 'in full');
insert into test.of select 'd1', app.door(test.id('of_cs'), 'aal2', 'ops_do', 'record_booking_payment', jsonb_build_object('booking', (test.ofb('o1')).booking_number, 'covers', 'deposit', 'method', 'cash'));
select test.eq('the cash deposit: a deposit row (offline, cash, captured) and a deposit payment in cash',
  (select method || '/' || paid_method || '/' || status || '/' || captured_cents from deposits where booking_id = (test.ofb('o1')).id) || '/' ||
  (select method || ':' || kind from payments where id = (test.ofv('d1') ->> 'payment_id')::uuid), 'offline/cash/captured/30000/cash:charge');
select test.throws('a second deposit is refused', $$select app.door(test.id('of_admin'), 'aal2', 'ops_do', 'record_booking_payment', jsonb_build_object('booking', (test.ofb('o1')).booking_number, 'covers', 'deposit', 'method', 'cash'))$$, 'already been taken');
select test.eq('receipts: one per payment received another way (rental, deposit)', (select count(*) from app_events where code = 'renter_payment_receipt' and (payload ->> 'booking_id')::uuid = (test.ofb('o1')).id), 2::bigint);

-- settled after the return: what is released is given back in cash, never to a card
set session_replication_role = replica;  -- the trip itself is not this test's: straight to returned
update bookings set status = 'returned', handed_over_at = pickup_at, checked_in_at = now() where id = (test.ofb('o1')).id;
reset session_replication_role;
insert into booking_statements (booking_id, kind, statement_number, issued_at) values ((test.ofb('o1')).id, 'check_in', 'S-OF1', now());
insert into test.of select 's1', app.settle_deposit((test.ofb('o1')).id, test.id('of_admin'));
select test.eq('settled: nothing for the server to refund to a card; a cash return', jsonb_array_length(test.ofv('s1') -> 'server_actions') || '/' || (test.ofv('s1') ->> 'offline_return'), '0/cash');
select test.eq('the return: a deposit refund payment in cash, waiting; a task for Finance',
  (select string_agg(method || ':' || kind || ':' || status, ',') from payments where booking_id = (test.ofb('o1')).id and purpose = 'deposit' and kind = 'refund') || '/' ||
  (select count(*) from tasks where booking_id = (test.ofb('o1')).id and task_type = 'return_deposit_offline' and status = 'open'), 'cash:refund:pending/1');
select test.eq('given back: recorded', app.door(test.id('of_fin'), 'aal2', 'ops_do', 'deposit_return_offline',
  jsonb_build_object('payment', (select id from payments where booking_id = (test.ofb('o1')).id and purpose = 'deposit' and kind = 'refund'), 'reference', 'Receipt 22')) ->> 'ok', 'true');
select test.eq('given back: the payment succeeds, the task is done', (select status from payments where booking_id = (test.ofb('o1')).id and purpose = 'deposit' and kind = 'refund') || '/' ||
  (select count(*) from tasks where booking_id = (test.ofb('o1')).id and task_type = 'return_deposit_offline' and status = 'open'), 'succeeded/0');

-- ================================================================ 4. a rental added by hand: deposit, platform payout, calendar, paper
insert into test.of select 'm1', app.door(test.id('of_admin'), 'aal2', 'ops_do', 'manual_rental_create', jsonb_build_object('vehicle_id', test.ofcar('car4'),
  'pickup_at', date_trunc('hour', now()) + interval '2 days', 'return_at', date_trunc('hour', now()) + interval '5 days', 'source', 'turo', 'coverage_option', 1,
  'renter_id', test.id('renter:of_rita'), 'sales_choice', 'for_carmacars', 'payment', jsonb_build_object('mode', 'other_way', 'method', 'platform_payout', 'reference', 'TURO-998'),
  'deposit', jsonb_build_object('method', 'e_transfer', 'reference', 'DEP-55'), 'agreement', 'paper', 'blocks_calendar', false, 'blocks_calendar_reason', 'Turo trip, Turo calendar holds it'));
select test.eq('Turo: confirmed, paid by platform payout, deposit by e-Transfer, on paper, not blocking',
  (select status || '/' || rental_pay_method || '/' || deposit_pay_method || '/' || agreement_on_paper || '/' || blocks_calendar from test.ofb('m1')), 'confirmed/platform_payout/e_transfer/true/false');
select test.eq('the payout is recorded for the rental; the deposit as offline e-Transfer',
  (select string_agg(method || ':' || purpose, ',' order by purpose) from payments where booking_id = (test.ofb('m1')).id), 'platform_payout:booking_total,e_transfer:deposit');
select test.eq('paper: a task to upload the scan', (select count(*) from tasks where booking_id = (test.ofb('m1')).id and task_type = 'paper_agreement_scan'), 1::bigint);
select test.throws('not blocking needs its reason', $$select app.door(test.id('of_admin'), 'aal2', 'ops_do', 'manual_rental_create', jsonb_build_object('vehicle_id', test.ofcar('car5'),
  'pickup_at', date_trunc('hour', now()) + interval '2 days', 'return_at', date_trunc('hour', now()) + interval '5 days', 'renter_id', test.id('renter:of_rita'), 'payment', jsonb_build_object('mode', 'unpaid'),
  'blocks_calendar', false))$$, 'why it does not block');
select test.throws('an assistant takes no "no deposit"', $$select app.door(test.id('of_cs'), 'aal2', 'ops_do', 'manual_rental_create', jsonb_build_object('vehicle_id', test.ofcar('car5'),
  'pickup_at', date_trunc('hour', now()) + interval '2 days', 'return_at', date_trunc('hour', now()) + interval '5 days', 'renter_id', test.id('renter:of_rita'), 'sales_choice', 'for_carmacars',
  'payment', jsonb_build_object('mode', 'link'), 'deposit', jsonb_build_object('method', 'none')))$$, 'Only an Admin');

-- ================================================================ 5. card requests
select test.throws('fleet starts no card payment', $$select app.door(test.id('of_fleet'), 'aal2', 'ops_do', 'payreq_create', jsonb_build_object('booking', (test.ofb('o3')).booking_number, 'kind', 'setup', 'token_sha256', repeat('a', 64)))$$, null);
select test.throws('a hold waits for the approval of the offer', $$select app.door(test.id('of_cs'), 'aal2', 'ops_do', 'payreq_create', jsonb_build_object('booking', (test.ofb('o3')).booking_number, 'kind', 'hold', 'token_sha256', repeat('a', 64)))$$, 'approved');
insert into test.of select 'q1', app.door(test.id('of_cs'), 'aal2', 'ops_do', 'payreq_create', jsonb_build_object('booking', (test.ofb('m1')).booking_number, 'kind', 'charge', 'covers', 'later',
  'amount_cents', 4500, 'reason', 'Fuel', 'channel', 'text', 'token_sha256', repeat('b', 64)));
select test.eq('a pay link: the amount and the part', (test.ofv('q1') ->> 'amount_cents') || '/' || (test.ofv('q1') ->> 'covers'), '4500/later');
select test.eq('the pay page reads it by the token''s hash only', (public.server_payreq_facts(repeat('b', 64)) ->> 'amount_cents') || '/' || coalesce(public.server_payreq_facts(repeat('c', 64)) ->> 'id', 'none'), '4500/none');
select public.server_payreq_attach((test.ofv('q1') ->> 'id')::uuid, 'pi_test_q1');
insert into test.of select 'q1s', public.server_payreq_settle((test.ofv('q1') ->> 'id')::uuid, jsonb_build_object('id', 'pi_test_q1', 'status', 'succeeded', 'amount', 4500, 'charge_id', 'ch_1',
  'customer_id', 'cus_1', 'method_id', 'pm_1', 'card', jsonb_build_object('brand', 'visa', 'last4', '4242', 'exp_month', 12, 'exp_year', 2031, 'funding', 'credit', 'name', 'Rita', 'fingerprint', 'fp1')));
select test.eq('paid by card: a post-rental card payment, the request paid, the card saved on the booking',
  (select method || ':' || purpose || ':' || status from payments where id = (test.ofv('q1s') ->> 'payment_id')::uuid) || '/' ||
  (select status from payment_requests where id = (test.ofv('q1') ->> 'id')::uuid) || '/' || ((test.ofb('m1')).card_on_file_id is not null), 'card:post_rental:succeeded/paid/true');
select test.eq('settled twice: the same payment', public.server_payreq_settle((test.ofv('q1') ->> 'id')::uuid, jsonb_build_object('id', 'pi_test_q1', 'status', 'succeeded', 'amount', 4500)) ->> 'repeat', 'true');
select test.throws('a hold on a booking that has its deposit already', $$select app.door(test.id('of_cs'), 'aal2', 'ops_do', 'payreq_create', jsonb_build_object('booking', (test.ofb('m1')).booking_number, 'kind', 'hold', 'token_sha256', repeat('d', 64)))$$, 'already taken');

-- a hold on a short rental, captured in part
insert into test.of select 'm2', app.door(test.id('of_admin'), 'aal2', 'ops_do', 'manual_rental_create', jsonb_build_object('vehicle_id', test.ofcar('car5'),
  'pickup_at', date_trunc('hour', now()) + interval '2 days', 'return_at', date_trunc('hour', now()) + interval '4 days', 'source', 'phone', 'coverage_option', 1,
  'renter_id', test.id('renter:of_rita'), 'payment', jsonb_build_object('mode', 'other_way', 'method', 'cash')));
insert into test.of select 'q2', app.door(test.id('of_cs'), 'aal2', 'ops_do', 'payreq_create', jsonb_build_object('booking', (test.ofb('m2')).booking_number, 'kind', 'hold', 'channel', 'device', 'token_sha256', repeat('e', 64)));
select public.server_payreq_attach((test.ofv('q2') ->> 'id')::uuid, 'pi_test_q2');
select public.server_payreq_settle((test.ofv('q2') ->> 'id')::uuid, jsonb_build_object('id', 'pi_test_q2', 'status', 'requires_capture', 'amount', 30000, 'customer_id', 'cus_1', 'method_id', 'pm_2',
  'card', jsonb_build_object('brand', 'visa', 'last4', '1111', 'exp_month', 1, 'exp_year', 2032, 'funding', 'credit', 'name', 'Rita', 'fingerprint', 'fp2')));
select test.eq('the hold: a card hold deposit, held, expiring in about 7 days', (select method || '/' || status || '/' || (hold_expires_at between now() + interval '6 days' and now() + interval '8 days') from deposits where booking_id = (test.ofb('m2')).id), 'card_hold/held/true');
select test.throws('capture needs a reason', $$select app.door(test.id('of_fin'), 'aal2', 'ops_do', 'hold_action_begin', jsonb_build_object('booking', (test.ofb('m2')).booking_number, 'action', 'capture', 'amount_cents', 5000))$$, 'Say why');
insert into test.of select 'h1', app.door(test.id('of_fin'), 'aal2', 'ops_do', 'hold_action_begin', jsonb_build_object('booking', (test.ofb('m2')).booking_number, 'action', 'capture', 'amount_cents', 5000, 'reason', 'Fuel'));
select test.eq('capture: Stripe''s intent and the amount', (test.ofv('h1') ->> 'intent_id') || '/' || (test.ofv('h1') ->> 'amount_cents'), 'pi_test_q2/5000');
select app.door(test.id('of_fin'), 'aal2', 'ops_do', 'hold_action_finish', jsonb_build_object('deposit', test.ofv('h1') ->> 'deposit_id', 'action', 'capture', 'amount_cents', 5000, 'ok', true, 'reason', 'Fuel'));
select test.eq('captured in part: $50 captured, the rest released with it', (select status || '/' || captured_cents || '/' || released_cents from deposits where booking_id = (test.ofb('m2')).id), 'captured/5000/25000');

-- the saved card, charged for a later charge
select test.throws('a charge needs its reason', $$select app.door(test.id('of_fin'), 'aal2', 'ops_do', 'card_charge_begin', jsonb_build_object('booking', (test.ofb('m2')).booking_number, 'amount_cents', 2000))$$, 'Say what');
select test.throws('customer service does not charge a saved card', $$select app.door(test.id('of_cs'), 'aal2', 'ops_do', 'card_charge_begin', jsonb_build_object('booking', (test.ofb('m2')).booking_number, 'amount_cents', 2000, 'reason', 'Km'))$$, 'Finance or an Admin');
insert into test.of select 'c1', app.door(test.id('of_fin'), 'aal2', 'ops_do', 'card_charge_begin', jsonb_build_object('booking', (test.ofb('m2')).booking_number, 'amount_cents', 2000, 'reason', 'Extra km'));
select test.eq('the charge: the saved card''s Stripe ids', (test.ofv('c1') ->> 'method_id') || '/' || (test.ofv('c1') ->> 'customer_id'), 'pm_2/cus_1');
select app.door(test.id('of_fin'), 'aal2', 'ops_do', 'card_charge_finish', jsonb_build_object('payment', test.ofv('c1') ->> 'payment_id', 'ok', true, 'intent_id', 'pi_c1', 'reason', 'Extra km'));
select test.eq('charged: a post-rental payment, and its receipt to the renter', (select status from payments where id = (test.ofv('c1') ->> 'payment_id')::uuid) || '/' ||
  (select count(*) from app_events where code = 'renter_payment_receipt' and entity_id = (test.ofv('c1') ->> 'payment_id')::uuid), 'succeeded/1');

-- ================================================================ 6. wording
select test.eq('the Protection Plan: one name for staff', (select label from fee_types where code = 'coverage_sold'), 'Protection Plan');
select test.throws('sales: "the Protection Plan price", not "coverage"', $$select app.va_guard_booking_edit('sales', '{"coverage_cents": 100}')$$, 'Protection Plan price');
select test.eq('the new ways of payment have their words', app.payment_method_label('platform_payout') || ' / ' || app.payment_method_label('insurer'), 'platform payout / the insurer');


-- ================================================================ 7. release 5: Sales open a booking whose check-out is due (0130)
insert into test.of select 'm3', app.door(test.id('of_admin'), 'aal2', 'ops_do', 'manual_rental_create', jsonb_build_object('vehicle_id', test.ofcar('car6'),
  'pickup_at', date_trunc('hour', now()) + interval '3 hours', 'return_at', date_trunc('hour', now()) + interval '2 days', 'source', 'phone', 'coverage_option', 1,
  'renter_id', test.id('renter:of_rita'), 'payment', jsonb_build_object('mode', 'other_way', 'method', 'cash')));
select test.eq('Sales open a confirmed booking whose check-out is due (to check the car out)',
  app.door(test.id('of_sales'), 'aal2', 'va_read', 'booking', jsonb_build_object('number', (test.ofb('m3')).booking_number)) ->> 'status', 'confirmed');
select test.throws('Sales do not open a confirmed booking whose check-out is days away',
  $$select app.door(test.id('of_sales'), 'aal2', 'va_read', 'booking', jsonb_build_object('number', (test.ofb('m1')).booking_number))$$, 'requests and offers only');
