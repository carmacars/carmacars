-- 99: a card payment taken outside the site (migration 0201, docs/changes/2026-10-31-card-payment-outside.md). Fixtures "co".
select test.suite('99 card payment outside');
select test.mk_user('co_admin', 'admin');
select test.mk_user('co_fin', 'va', 'finance');
select test.mk_owner('co_o');
select test.mk_vehicle('COA', 'co_o');
select test.mk_renter('co_r');
select test.mk_booking('CO-1', 'COA', 'co_r', '2026-12-05 10:00', '2026-12-08 10:00', 'confirmed', 30000);
select test.mk_booking('CO-2', 'COA', 'co_r', '2026-12-15 10:00', '2026-12-18 10:00', 'confirmed', 30000);
create function test.co(p_user text, p jsonb) returns jsonb language sql as $$ select app.door(test.id(p_user), 'aal2', 'ops_do', 'record_card_payment', p) $$;

select test.throws('the last 4 digits are asked', $$select test.co('co_admin', '{"booking": "CO-1", "covers": "later", "amount_cents": 5000}')$$, 'last 4 digits');
select test.throws('a Stripe id must be looked up', $$select test.co('co_admin', '{"booking": "CO-1", "covers": "later", "amount_cents": 5000, "last4": "4242", "stripe_id": "pi_abc123456"}')$$, 'Look up');
select test.throws('Stripe''s last 4 digits must match',
  $$select test.co('co_admin', '{"booking": "CO-1", "covers": "later", "amount_cents": 5000, "last4": "4242", "stripe_id": "pi_abc123456",
     "verified": {"intent_id": "pi_abc123456", "status": "succeeded", "amount_cents": 5000, "last4": "1111"}}')$$, 'ends 1111');
select test.throws('Stripe''s amount must match',
  $$select test.co('co_admin', '{"booking": "CO-1", "covers": "later", "amount_cents": 4000, "last4": "4242", "stripe_id": "pi_abc123456",
     "verified": {"intent_id": "pi_abc123456", "status": "succeeded", "amount_cents": 5000, "last4": "4242"}}')$$, 'Stripe says $50.00 was paid');
select test.lives('a later charge taken in the Dashboard, verified',
  $$select test.co('co_admin', '{"booking": "CO-1", "covers": "later", "last4": "4242", "brand": "visa", "stripe_id": "pi_abc123456",
     "verified": {"intent_id": "pi_abc123456", "charge_id": "ch_abc123456", "status": "succeeded", "amount_cents": 5000, "last4": "4242", "brand": "visa"}}')$$);
select test.eq('recorded as a card payment with its Stripe ids',
  (select p.method || '/' || p.card_last4 || '/' || p.amount_cents || '/' || x.processor || '/' || x.processor_payment_id || '/' || m.card_source || '/' || m.stripe_verified
     from payments p join payment_processor_details x on x.payment_id = p.id join manual_payments m on m.payment_id = p.id
    where p.booking_id = test.id('booking:CO-1') and p.purpose = 'post_rental'), 'card/4242/5000/stripe/pi_abc123456/dashboard/true');
select test.throws('the same Stripe payment twice is refused',
  $$select test.co('co_admin', '{"booking": "CO-1", "covers": "later", "last4": "4242", "stripe_id": "ch_abc123456",
     "verified": {"intent_id": "pi_abc123456", "charge_id": "ch_abc123456", "status": "succeeded", "amount_cents": 5000, "last4": "4242"}}')$$, 'already recorded');
select test.lives('a rental payment on a reader, no Stripe id',
  $$select test.co('co_admin', '{"booking": "CO-2", "covers": "rental", "amount_cents": 10000, "last4": "4242", "source": "reader"}')$$);
select test.eq('kept as an outside card payment',
  (select x.processor || '/' || m.card_source || '/' || m.stripe_verified from payments p join payment_processor_details x on x.payment_id = p.id join manual_payments m on m.payment_id = p.id
    where p.booking_id = test.id('booking:CO-2') and p.amount_cents = 10000), 'outside_card/reader/false');
-- the deposit hold
select test.throws('a deposit hold needs the Stripe id', $$select test.co('co_admin', '{"booking": "CO-2", "covers": "deposit", "last4": "4242"}')$$, 'needs its Stripe payment id');
select test.throws('a deposit must be a hold waiting to be captured',
  $$select test.co('co_admin', '{"booking": "CO-2", "covers": "deposit", "last4": "4242", "stripe_id": "pi_dep1234567",
     "verified": {"intent_id": "pi_dep1234567", "status": "succeeded", "amount_cents": 100000, "capturable_cents": 0, "last4": "4242"}}')$$, 'not a hold');
select test.lives('a deposit hold placed on a reader',
  $$select test.co('co_admin', '{"booking": "CO-2", "covers": "deposit", "last4": "4242", "source": "reader", "stripe_id": "pi_dep1234567",
     "verified": {"intent_id": "pi_dep1234567", "status": "requires_capture", "amount_cents": 100000, "capturable_cents": 100000, "last4": "4242", "brand": "visa"}}')$$);
select test.eq('the deposit is held on the card, lapsing in 2 days (card present)',
  (select d.method || '/' || d.status || '/' || d.amount_cents || '/' || (d.hold_expires_at between now() + interval '47 hours' and now() + interval '49 hours') || '/' || p.kind || '/' || p.status
     from deposits d join payments p on p.id = d.hold_payment_id where d.booking_id = test.id('booking:CO-2')), 'card_hold/held/100000/true/hold/authorized');
select test.eq('the hold can be captured or released at Stripe from the booking (hold_action_begin finds the intent)',
  app.door(test.id('co_admin'), 'aal2', 'ops_do', 'hold_action_begin', '{"booking": "CO-2", "action": "release", "reason": "Recorded hold, released for the test"}') ->> 'intent_id', 'pi_dep1234567');
select test.throws('a renter cannot record a card payment', $$select test.co('co_r', '{"booking": "CO-1", "covers": "later", "amount_cents": 100, "last4": "4242"}')$$, 'Only an Admin');
select test.throws('Finance within the limits of Program settings', $$select test.co('co_fin', '{"booking": "CO-1", "covers": "later", "amount_cents": 5000, "last4": "4242"}')$$, 'single limit');
