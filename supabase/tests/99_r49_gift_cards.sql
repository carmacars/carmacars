-- 99: gift cards, vouchers and gifted rentals (migration 3600; docs/changes/2026-11-23-r49-gift-cards.md): buying (the
-- amount, the payment check, the emails, a later send date), adding a code, the ledger that never lets a balance go below
-- zero, Sign and pay (the balance before the card, the part left on the card, never the deposit), a refund back to the
-- card balance, a booking that ends unpaid, Admin's vouchers and voids, Finance's read. Fixtures start with "gx".
select test.suite('99 r49 gift cards');

select test.mk_user('gcx_admin', 'admin');
select test.mk_user('gcx_fin', 'va', 'finance');
select test.mk_user('gcx_buyer', 'renter');
select test.mk_user('gcx_other', 'renter');
update staff_profiles set single_limit_cents = 500000 where user_id = test.id('gcx_fin');

create table test.gx (k text primary key, v jsonb);
grant all on test.gx to public;
create function test.gxv(p text) returns jsonb language sql stable as $$ select v from test.gx where k = p $$;
create function test.gxid(p text) returns uuid language sql stable as $$ select (test.gxv(p) ->> 'id')::uuid $$;
create function test.gxg(p text) returns gift_cards language sql stable security definer as $$ select * from public.gift_cards where id = test.gxid(p) $$;
create function test.gx_events(p text) returns text language sql stable security definer as $$
  select coalesce(string_agg(code, ',' order by id), '') from public.app_events where entity = 'gift_card' and entity_id = test.gxid(p) $$;
create function test.gx_pay(p text) returns jsonb language sql as $$
  select app.gift_order_paid(test.gxid(p), jsonb_build_object('id', 'pi_' || p, 'amount_cents', (test.gxg(p)).initial_cents, 'currency', 'cad',
    'status', 'succeeded', 'card_text', 'Visa ending 4242')) $$;

-- ================================================================ 1. buying
select test.throws('a card sold for money never expires (Ontario)',
  $$insert into gift_cards (code, kind, status, initial_cents, buyer_user_id, recipient_name, expires_at) values ('CCGC-AAAA-BBBB-CCCC', 'purchased', 'active', 1000, test.id('gcx_buyer'), 'X', now() + interval '1 year')$$,
  'gift_cards_no_expiry_when_sold');
select test.throws('an amount under the minimum is refused', $$select app.gift_order_create(test.id('gcx_buyer'), '{"amount_cents":1000,"recipient_name":"Jo","recipient_email":"jo.gx@example.test"}')$$, 'Choose an amount');
select test.throws('an amount in cents is refused', $$select app.gift_order_create(test.id('gcx_buyer'), '{"amount_cents":5050,"recipient_name":"Jo","recipient_email":"jo.gx@example.test"}')$$, 'whole dollars');
select test.throws('the recipient email is needed', $$select app.gift_order_create(test.id('gcx_buyer'), '{"amount_cents":5000,"recipient_name":"Jo","recipient_email":"jo"}')$$, 'recipient''s email');

insert into test.gx select 'g1', app.gift_order_create(test.id('gcx_buyer'), '{"amount_cents":15000,"recipient_name":"Jo Gift","recipient_email":"Jo.GX@Example.test","message":"Happy birthday","buyer_name":"Sam Buyer"}');
select test.eq('a second press is the same order', (app.gift_order_create(test.id('gcx_buyer'), '{"amount_cents":15000,"recipient_name":"Jo Gift","recipient_email":"jo.gx@example.test","message":"Happy birthday","buyer_name":"Sam Buyer"}') ->> 'id')::uuid, test.gxid('g1'));
select test.eq('an order waits for payment with no balance', (test.gxg('g1')).status || '/' || (test.gxg('g1')).balance_cents, 'pending_payment/0');
select test.ok('the code is in the stored form', (test.gxg('g1')).code ~ '^CCGC-[A-HJ-NP-Z2-9]{4}-[A-HJ-NP-Z2-9]{4}-[A-HJ-NP-Z2-9]{4}$');
select app.gift_order_intent(test.gxid('g1'), 'pi_g1');
select test.eq('another payment is refused', app.gift_order_paid(test.gxid('g1'), '{"id":"pi_other","amount_cents":15000,"currency":"cad","status":"succeeded"}') ->> 'reason', 'other_payment');
select test.eq('a different amount is refused', app.gift_order_paid(test.gxid('g1'), '{"id":"pi_g1","amount_cents":14999,"currency":"cad","status":"succeeded"}') ->> 'reason', 'amount_mismatch');
select test.eq('a payment not succeeded is refused', app.gift_order_paid(test.gxid('g1'), '{"id":"pi_g1","amount_cents":15000,"currency":"cad","status":"processing"}') ->> 'reason', 'not_paid');
insert into test.gx select 'g1paid', test.gx_pay('g1');
select test.eq('paid: active with its balance', (test.gxv('g1paid') ->> 'ok') || '/' || (test.gxg('g1')).status || '/' || (test.gxg('g1')).balance_cents, 'true/active/15000');
select test.eq('paid twice is one payment', test.gx_pay('g1') ->> 'already', 'true');
select test.eq('one issue in the ledger', (select string_agg(kind || ':' || amount_cents || ':' || balance_after_cents, ',') from gift_card_ledger where gift_card_id = test.gxid('g1')), 'issue:15000:15000');
select test.eq('the receipt, the staff notice and the gift email (sent at once)', test.gx_events('g1'), 'renter_gift_card_receipt,staff_gift_card_sold,renter_gift_card_delivered');
select test.eq('the recipient email carries the code and the printable card',
  (select (e.payload ->> 'gift_code') = (test.gxg('g1')).code and (e.payload ->> 'card_url') like '%/gift-cards/card/' || (test.gxg('g1')).view_token
     and e.payload ->> 'gift_message' = 'Happy birthday' and e.payload ->> 'to_email' = 'jo.gx@example.test' and e.payload ->> 'expiry_text' = 'Never'
     from app_events e where e.entity_id = test.gxid('g1') and e.code = 'renter_gift_card_delivered'), true);
select test.eq('the email goes to the recipient, not to a renter of the database',
  (select string_agg(r.email, ',') from app_events e join notification_catalogue c on c.code = e.code, app.notification_recipients(e, c) r
    where e.entity_id = test.gxid('g1') and e.code = 'renter_gift_card_delivered'), 'jo.gx@example.test');
select test.ok('every variable of each email is filled',
  (select bool_and(not exists (select 1 from jsonb_array_elements(c.variables) v
      where coalesce((v ->> 'global')::boolean, false) = false and v ->> 'name' <> 'unsubscribe_url'
        and not (app.notification_payload(e.code, e, '{}'::jsonb) ? (v ->> 'name'))))
     from app_events e join notification_catalogue c on c.code = e.code where e.entity_id = test.gxid('g1')));
select test.eq('the printable card opens with its token only', (public.server_gift_card_view((test.gxg('g1')).view_token) ->> 'code') = (test.gxg('g1')).code
  and public.server_gift_card_view(repeat('0', 64)) is null, true);

-- a later send date: nothing to the recipient until that day, then the gift and the buyer's notice
insert into test.gx select 'g2', app.gift_order_create(test.id('gcx_buyer'), jsonb_build_object('amount_cents', 5000, 'recipient_name', 'Lee Later',
  'recipient_email', 'lee.gx@example.test', 'send_on', ((now() at time zone 'America/Toronto')::date + 3)::text));
select app.gift_order_intent(test.gxid('g2'), 'pi_g2');
select test.gx_pay('g2');
select test.eq('scheduled: the receipt says the day, no gift yet', test.gx_events('g2'), 'renter_gift_card_receipt,staff_gift_card_sold');
select app.job_gift_cards_send(now() + interval '1 day');
select test.eq('not before the day', test.gx_events('g2'), 'renter_gift_card_receipt,staff_gift_card_sold');
select app.job_gift_cards_send(now() + interval '4 days');
select test.eq('on the day: the gift and the buyer''s notice, once', test.gx_events('g2'), 'renter_gift_card_receipt,staff_gift_card_sold,renter_gift_card_delivered,renter_gift_card_sent');
select app.job_gift_cards_send(now() + interval '5 days');
select test.eq('never twice', (select count(*)::integer from app_events where entity_id = test.gxid('g2') and code = 'renter_gift_card_delivered'), 1);

-- ================================================================ 2. the ledger
select test.throws('the balance changes only through the ledger', $$update gift_cards set balance_cents = 99999 where id = test.gxid('g1')$$, 'only through its ledger');
select test.throws('the ledger is never changed', $$update gift_card_ledger set amount_cents = 1 where gift_card_id = test.gxid('g1')$$, 'never changed');
select test.throws('the ledger is never deleted', $$delete from gift_card_ledger where gift_card_id = test.gxid('g1')$$, 'never changed');
select test.throws('no balance below zero', $$insert into gift_card_ledger (gift_card_id, kind, amount_cents) values (test.gxid('g2'), 'redeem', -5001)$$, 'not enough');
select test.throws('no balance above the card''s amount', $$insert into gift_card_ledger (gift_card_id, kind, amount_cents) values (test.gxid('g2'), 'adjust', 1)$$, 'never goes above');
select test.throws('the table refuses a negative balance too', $$update gift_cards set balance_cents = -1 where id = test.gxid('g2')$$);

-- ================================================================ 3. adding a code
select test.eq('a code as typed (lower case, spaces for dashes)', app.gift_code_norm(lower(replace((test.gxg('g1')).code, '-', ' '))), (test.gxg('g1')).code);
select test.throws('an unknown code', $$select app.gift_card_claim(test.id('gcx_buyer'), 'CCGC-ZZZZ-ZZZZ-ZZZZ')$$, 'do not know this code');

-- ================================================================ 4. Sign and pay
do $$
begin
  insert into test.gx select 'car', app.vehicle_add(test.id('gcx_admin'), jsonb_build_object('supply_type', 'company', 'vin', '1XFCXMM0000009G01',
    'plate', 'GX001', 'year', 2024, 'make', 'Kia', 'model', 'K5', 'rates', jsonb_build_object('daily', 10000, 'weekend', 10000, 'weekly', 70000, 'monthly', 300000, 'deposit', 30000)));
end $$;
create function test.gxb(p text) returns bookings language sql stable security definer as $$
  select * from public.bookings where id = coalesce((test.gxv(p) ->> 'booking_id')::uuid, (test.gxv(p) ->> 'id')::uuid) $$;
create function test.gxu(p text) returns uuid language sql stable security definer as $$ select r.user_id from public.renters r where r.id = (test.gxb(p)).renter_id $$;
create function test.gx_offer(p_email text, p_mobile text, p_from interval) returns jsonb language sql as $$
  select app.door(test.id('gcx_admin'), 'aal2', 'ops_do', 'offer_create', jsonb_build_object('vehicle_id', (test.gxv('car') ->> 'vehicle_id')::uuid,
    'pickup_at', date_trunc('hour', now()) + p_from, 'return_at', date_trunc('hour', now()) + p_from + interval '3 days',
    'renter', jsonb_build_object('full_name', 'Gia Renter', 'email', p_email, 'mobile', p_mobile, 'date_of_birth', '1990-05-06'),
    'coverage_option', 1, 'sales_choice', 'sourced', 'channels', jsonb_build_object('email', false, 'text', false), 'notify', false)) $$;
create function test.gx_ready(p text) returns void language plpgsql as $$
declare v_driver uuid := (select bd.driver_id from booking_drivers bd where bd.booking_id = (test.gxb(p)).id and bd.role = 'renter');
  k text;
begin
  foreach k in array array['licence_front', 'licence_back', 'selfie'] loop
    perform app.register_verification_upload((test.gxb(p)).id, test.gxu(p), k, v_driver, 'renters/gx/' || p || '-' || k || '-' || gen_random_uuid() || '.jpg', repeat('e', 64), 'image/jpeg', null, 'identity');
  end loop;
  perform public.renter_save_details(test.gxu(p), jsonb_build_object('licence_number', 'G1234-12345-12345', 'licence_issuer', 'ON', 'licence_class', 'G',
    'licence_expiry', (now() + interval '3 years')::date), (test.gxb(p)).id);
  perform public.renter_approve_offer((test.gxb(p)).id, (test.gxb(p)).current_offer_version, test.gxu(p));
  perform public.renter_open_agreement((test.gxb(p)).id, test.gxu(p), 'rental-test', repeat('a', 64), 'bookings/gx/' || p || '.pdf');
  perform public.renter_sign_agreement((test.gxb(p)).id, test.gxu(p), 'I agree', (select a.document_sha256 from rental_agreements a where a.booking_id = (test.gxb(p)).id and a.status = 'open'),
    '[{"code":"tracking_disabling","version":"v","text":"t"},{"code":"identity_verification","version":"v","text":"t"},{"code":"electronic_signature","version":"v","text":"t"},{"code":"card_authorization","version":"v","text":"t"}]'::jsonb, 'Gia Renter');
end $$;
create function test.gx_card_pay(p text, p_cents bigint) returns jsonb language sql as $$
  select app.record_booking_payment((test.gxb(p)).id, jsonb_build_object('processor', 'stripe', 'payment_id', 'pi_gx_' || p, 'charge_id', 'ch_gx_' || p,
    'customer_id', 'cus_gx', 'method_id', 'pm_gx_' || p, 'fingerprint', 'fp_gx_' || p), p_cents, (test.gxb(p)).offer_approved_version,
    '{"brand":"visa","last4":"4242","is_credit":true,"exp_month":12,"exp_year":2031,"cardholder_name":"Gia Renter"}'::jsonb, 'evt_gx_' || p, test.gxu(p)) $$;

insert into test.gx select 'b1', test.gx_offer('gia.gx@example.test', '(289) 555-0961', interval '12 days');
select test.gx_ready('b1');
select test.eq('the booking waits for payment', (test.gxb('b1')).status::text, 'pending_payment');
-- a purchased card (not tied to an address) belongs to whoever adds the code first: here Jo passed it to the renter
select test.eq('the renter adds the code', app.gift_card_claim(test.gxu('b1'), (test.gxg('g1')).code) ->> 'ok', 'true');
select test.throws('then it is theirs alone', $$select app.gift_card_claim(test.id('gcx_other'), (test.gxg('g1')).code)$$, 'another account');
select test.eq('my gift cards: one, with its balance', (app.my_gift_cards(test.gxu('b1')) ->> 'balance_cents')::bigint, 15000::bigint);
select test.eq('the buyer sees the gifts they sent', jsonb_array_length(app.my_gift_cards(test.id('gcx_buyer')) -> 'sent'), 2);

create temp table gx_due as select (test.gxb('b1')).renter_due_at_booking_cents due, (test.gxb('b1')).deposit_cents dep;
grant all on gx_due to public;
select test.ok('the booking owes more than the card (the test needs a part paid by card)', (select due from gx_due) > 15000);
select test.eq('Sign and pay lists the card', (app.gift_booking_state((test.gxb('b1')).id, test.gxu('b1')) #>> '{cards,0,balance_cents}')::bigint, 15000::bigint);
select test.throws('another person cannot apply it', $$select app.gift_booking_apply((test.gxb('b1')).id, test.id('gcx_other'), test.gxid('g1'))$$, 'Booking not found');
select test.eq('applied: all of the balance, the rest by card',
  (select (s ->> 'applied_cents') || '/' || (s ->> 'card_due_cents') from (select app.gift_booking_apply((test.gxb('b1')).id, test.gxu('b1'), test.gxid('g1')) s) x),
  '15000/' || ((select due from gx_due) - 15000));
select test.eq('the balance is set aside', (test.gxg('g1')).balance_cents, 0::bigint);
select test.eq('the payment facts give the card part', (public.server_booking_payment_facts((test.gxb('b1')).id) ->> 'card_due_cents')::bigint, (select due from gx_due) - 15000);
select test.eq('the full amount by card is refused (the gift card is applied)', test.gx_card_pay('b1', (select due from gx_due)) ->> 'reason', 'amount_mismatch');
select test.eq('refused: the balance is back for the renter to apply again', (test.gxg('g1')).balance_cents, 15000::bigint);
select app.gift_booking_apply((test.gxb('b1')).id, test.gxu('b1'), test.gxid('g1'));
-- the event of the refusal was claimed: a new event id for the real payment
create function test.gx_card_pay2(p text, p_cents bigint) returns jsonb language sql as $$
  select app.record_booking_payment((test.gxb(p)).id, jsonb_build_object('processor', 'stripe', 'payment_id', 'pi_gx2_' || p, 'charge_id', 'ch_gx2_' || p,
    'customer_id', 'cus_gx', 'method_id', 'pm_gx_' || p, 'fingerprint', 'fp_gx_' || p), p_cents, (test.gxb(p)).offer_approved_version,
    '{"brand":"visa","last4":"4242","is_credit":true,"exp_month":12,"exp_year":2031,"cardholder_name":"Gia Renter"}'::jsonb, 'evt_gx2_' || p, test.gxu(p)) $$;
select test.eq('the card part confirms the booking', test.gx_card_pay2('b1', (select due from gx_due) - 15000) ->> 'ok', 'true');
select test.eq('confirmed', (test.gxb('b1')).status::text, 'confirmed');
select test.eq('two payments: the card part and the gift card part',
  (select string_agg(method || ':' || amount_cents, ',' order by method) from payments where booking_id = (test.gxb('b1')).id and kind = 'charge' and status = 'succeeded'),
  'card:' || ((select due from gx_due) - 15000) || ',gift_card:15000');
select test.eq('the application is paid', (select status from gift_card_applications where booking_id = (test.gxb('b1')).id and status <> 'released'), 'paid');
select test.ok('never the deposit: what was applied is at most what is due at booking', (select sum(amount_cents) from gift_card_applications where booking_id = (test.gxb('b1')).id and status = 'paid') <= (select due from gx_due));
select test.ok('the holder is told what was used', test.gx_events('g1') like '%renter_gift_card_used%');

-- ================================================================ 5. a refund goes back to the gift card first
insert into refunds (booking_id, payment_id, reason, refund_bps, amount_cents, status, requested_by, note)
select b.id, (select p.id from payments p where p.booking_id = b.id and p.method = 'card' and p.kind = 'charge'), 'goodwill', null, 20000, 'pending_approval', test.id('gcx_admin'), 'gx goodwill'
  from bookings b where b.id = (test.gxb('b1')).id;
select test.eq('split: the gift card part and the card part',
  (select string_agg(p.method || ':' || r.amount_cents || ':' || r.status, ',' order by p.method) from refunds r join payments p on p.id = r.payment_id where r.booking_id = (test.gxb('b1')).id),
  'card:5000:pending_approval,gift_card:15000:pending_approval');
update refunds set status = 'approved', approved_by = test.id('gcx_admin') where booking_id = (test.gxb('b1')).id and gift_split_of is null;
select test.eq('approved: the gift card part is paid back to the balance at once, the card part waits for the processor',
  (select string_agg(p.method || ':' || r.status, ',' order by p.method) from refunds r join payments p on p.id = r.payment_id where r.booking_id = (test.gxb('b1')).id),
  'card:approved,gift_card:paid');
select test.eq('the balance is back', (test.gxg('g1')).balance_cents, 15000::bigint);
select test.eq('the ledger tells it all', (select string_agg(kind || ':' || amount_cents, ',' order by id) from gift_card_ledger where gift_card_id = test.gxid('g1')),
  'issue:15000,redeem:-15000,release:15000,redeem:-15000,refund:15000');
select test.ok('the holder is told', test.gx_events('g1') like '%renter_gift_card_refunded%');
select test.eq('no card-refund email for the gift card part', (select count(*)::integer from app_events e join refunds r on r.id = e.entity_id
  join payments p on p.id = r.payment_id where e.code = 'renter_refund_issued' and p.method = 'gift_card'), 0);
select test.throws('a gift card refund is never more than the gift card paid',
  $$insert into refunds (booking_id, payment_id, reason, amount_cents, status, approved_by, gift_split_of)
    select (test.gxb('b1')).id, p.id, 'goodwill', 1, 'approved', test.id('gcx_admin'), null from payments p where p.booking_id = (test.gxb('b1')).id and p.method = 'gift_card' and p.kind = 'charge'$$,
  'more than the gift cards paid');

-- ================================================================ 6. a booking that ends unpaid gives the balance back
insert into test.gx select 'b2', test.gx_offer('gia.gx@example.test', '(289) 555-0961', interval '40 days');
select test.gx_ready('b2');
select app.gift_booking_apply((test.gxb('b2')).id, test.gxu('b2'), test.gxid('g1'), 4000);
select test.eq('a part of the balance', (test.gxg('g1')).balance_cents, 11000::bigint);
select test.throws('the same card twice on one booking', $$select app.gift_booking_apply((test.gxb('b2')).id, test.gxu('b2'), test.gxid('g1'), 100)$$, 'already applied');
select test.eq('removed on Sign and pay', (app.gift_booking_remove((test.gxb('b2')).id, test.gxu('b2')) ->> 'applied_cents')::bigint, 0::bigint);
select app.gift_booking_apply((test.gxb('b2')).id, test.gxu('b2'), test.gxid('g1'), 4000);
update bookings set status = 'cancelled' where id = (test.gxb('b2')).id;
select test.eq('cancelled unpaid: the balance is back', (test.gxg('g1')).balance_cents, 15000::bigint);

-- ================================================================ 7. fully paid by gift card (a saved card stays for the deposit)
insert into test.gx select 'g3', app.gift_card_issue(test.id('gcx_admin'), jsonb_build_object('type', 'amount', 'amount_cents', 100000, 'reason', 'Service recovery after a breakdown',
  'recipient_email', 'gia.gx@example.test', 'recipient_name', 'Gia Renter', 'expires_on', ((now() at time zone 'America/Toronto')::date + 90)::text));
select test.eq('a voucher given free may end', (test.gxg('g3')).expires_at is not null and (test.gxg('g3')).kind = 'voucher', true);
select test.eq('the voucher is emailed and Finance and Admins are told', test.gx_events('g3'), 'staff_gift_card_sold,renter_gift_card_delivered');
insert into test.gx select 'b3', test.gx_offer('gia.gx@example.test', '(289) 555-0961', interval '70 days');
select test.gx_ready('b3');
update users set email_verified_at = now() where id = test.gxu('b3');
select test.eq('a voucher made for this address is listed without adding the code', (app.gift_booking_state((test.gxb('b3')).id, test.gxu('b3')) -> 'cards') @> jsonb_build_array(jsonb_build_object('id', test.gxid('g3'))), true);
select test.eq('with a saved card the whole amount can be paid by gift card',
  (select (s ->> 'card_due_cents')::bigint from (select app.gift_booking_apply((test.gxb('b3')).id, test.gxu('b3'), test.gxid('g3')) s) x), 0::bigint);
select test.eq('confirmed with no card charge', app.gift_booking_pay((test.gxb('b3')).id, test.gxu('b3')) ->> 'ok', 'true');
select test.eq('one gift card payment, no processor behind it',
  (select string_agg(p.method || ':' || (d.payment_id is null), ',') from payments p left join payment_processor_details d on d.payment_id = p.id
    where p.booking_id = (test.gxb('b3')).id and p.kind = 'charge'), 'gift_card:true');
select test.eq('the deposit is still the deposit', (test.gxb('b3')).deposit_cents > 0 and (test.gxb('b3')).status = 'confirmed', true);

-- ================================================================ 8. Admin and Finance
select test.ok('Finance reads the gift cards and the liability', (app.door(test.id('gcx_fin'), 'aal2', 'ops_read', 'gift_cards', '{}') #>> '{summary,liability_cents}')::bigint >= 20000);
select test.eq('the liability counts cards sold for money, not vouchers',
  app.gift_liability_cents() - (select coalesce(sum(balance_cents), 0) from gift_cards where status = 'active' and kind in ('purchased', 'gifted_rental')), 0::bigint);
select test.eq('search by the last four', (select count(*)::integer from jsonb_array_elements(app.door(test.id('gcx_fin'), 'aal2', 'ops_read', 'gift_cards', jsonb_build_object('q', (test.gxg('g1')).code_last4)) -> 'rows') r
  where (r ->> 'id')::uuid = test.gxid('g1')), 1);
select test.ok('the balance history', jsonb_array_length(app.door(test.id('gcx_fin'), 'aal2', 'ops_read', 'gift_card_history', jsonb_build_object('id', test.gxid('g1'))) -> 'history') >= 5);
select test.throws('Finance does not issue vouchers', $$select app.door(test.id('gcx_fin'), 'aal2', 'ops_do', 'gift_card_issue', '{"type":"amount","amount_cents":1000,"reason":"Nice"}')$$, 'Only an Admin');
select test.throws('Finance does not void', $$select app.door(test.id('gcx_fin'), 'aal2', 'ops_do', 'gift_card_void', jsonb_build_object('id', test.gxid('g2'), 'reason', 'Fraud'))$$, 'Only an Admin');
select test.throws('a renter reads nothing', $$select app.gift_cards_admin(test.id('gcx_buyer'), '{}')$$, 'Finance and Admins');
select test.throws('a void needs a reason', $$select app.gift_card_void(test.id('gcx_admin'), jsonb_build_object('id', test.gxid('g2')))$$, 'why');
insert into test.gx select 'void', app.door(test.id('gcx_admin'), 'aal2', 'admin_do', 'gift_card_void', jsonb_build_object('id', test.gxid('g2'), 'reason', 'Paid with a stolen card'));
select test.eq('voided: the balance taken off, with who and why',
  (test.gxv('void') ->> 'voided_cents') || '/' || (test.gxg('g2')).status || '/' || (test.gxg('g2')).balance_cents || '/' || (test.gxg('g2')).void_reason,
  '5000/voided/0/Paid with a stolen card');
select test.ok('Admins and Finance are told at once', test.gx_events('g2') like '%staff_gift_card_voided%');
select test.ok('the void is audited', exists (select 1 from audit_log where entity_table = 'gift_cards' and entity_id = test.gxid('g2')::text and actor_user_id = test.id('gcx_admin')));
select test.throws('a voided card is not added', $$select app.gift_card_claim(test.id('gcx_other'), (test.gxg('g2')).code)$$, 'cancelled');
insert into test.gx select 'pct', app.gift_card_issue(test.id('gcx_admin'), '{"type":"percent","percent_bps":1500,"max_uses":20,"code":"GXSPRING","reason":"Spring campaign"}');
select test.eq('a percentage voucher is a promo code with its limits',
  (select pc.percent_bps || '/' || pc.max_uses || '/' || pc.source from promo_codes pc where pc.code = test.gxv('pct') ->> 'code'), '1500/20/admin_voucher');
select test.ok('the percentage voucher is audited', exists (select 1 from audit_log where action = 'voucher_issued' and entity_table = 'promo_codes' and actor_user_id = test.id('gcx_admin')));

-- ================================================================ 9. the gifted rental is tied to its recipient
insert into test.gx select 'pub', to_jsonb(l) from (select vehicle_id, year, make, model from public_vehicle_listings order by slug limit 1) l;
insert into test.gx select 'g4', app.gift_order_create(test.id('gcx_buyer'), jsonb_build_object('kind', 'gifted_rental', 'vehicle_id', (test.gxv('pub') ->> 'vehicle_id')::uuid,
  'days', 3, 'recipient_name', 'Ray Rental', 'recipient_email', 'ray.gx@example.test'));
select test.ok('priced with the site''s own quote', (test.gxg('g4')).initial_cents = (app.gift_rental_price((test.gxv('pub') ->> 'vehicle_id')::uuid, 3) ->> 'amount_cents')::bigint
  and (test.gxg('g4')).rental_text = format('3 days in the %s %s %s', test.gxv('pub') ->> 'year', test.gxv('pub') ->> 'make', test.gxv('pub') ->> 'model'));
select test.throws('a car not on the site is not gifted', $$select app.gift_order_create(test.id('gcx_buyer'), jsonb_build_object('kind', 'gifted_rental', 'vehicle_id', (test.gxv('car') ->> 'vehicle_id')::uuid,
  'days', 3, 'recipient_name', 'Ray', 'recipient_email', 'ray.gx@example.test'))$$, 'not available to gift');
select app.gift_order_intent(test.gxid('g4'), 'pi_g4');
select test.gx_pay('g4');
select test.throws('another account cannot add a gifted rental', $$select app.gift_card_claim(test.id('gcx_other'), (test.gxg('g4')).code)$$, 'another email address');
select test.throws('more days than allowed', $$select app.gift_order_create(test.id('gcx_buyer'), jsonb_build_object('kind', 'gifted_rental', 'vehicle_id', (test.gxv('pub') ->> 'vehicle_id')::uuid,
  'days', 99, 'recipient_name', 'Ray', 'recipient_email', 'ray.gx@example.test'))$$, 'Choose 1 to');

-- ================================================================ 10. the emails go through the pipeline
select app.process_events(100000);
select test.eq('every gift card email was built, with no variable missing',
  (select string_agg(c, ',' order by c) from unnest(app.gift_notice_codes()) c
    where not exists (select 1 from notification_outbox o where o.code = c and o.missing_variables = '{}')
      and not exists (select 1 from staff_digest_items d where d.code = c)), null::text);
select test.eq('the gift email went to the recipient''s address', (select string_agg(distinct o.to_address, ',') from notification_outbox o where o.code = 'renter_gift_card_delivered' and o.payload ->> 'recipient_name' = 'Jo Gift'), 'jo.gx@example.test');

-- ================================================================ 11. the server only
select test.ok('every new function is for the server only',
  (select bool_and(not has_function_privilege('anon', p.oid, 'execute') and not has_function_privilege('authenticated', p.oid, 'execute'))
     from pg_proc p where p.proname like '%gift%'));
set role anon;
select test.eq('rls: the anonymous role reads no gift card', test.visible('select * from public.gift_cards'), -1::bigint);
reset role;
