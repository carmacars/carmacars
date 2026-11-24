-- 99: a card taken in the Stripe Dashboard app (Tap to Pay) has no booking in Stripe (migration 3430, CC-10607). The website
-- reads the payment at Stripe (mocked here as its answer, "verified"); the database says how it would be linked (exactly
-- the open rental and fees, the deposit, or both), refuses one it already knows, and records it as Link a Stripe payment
-- does, audited. stripe_find_payments checks its window. Fixtures start with "xt"; every address is example.test.
select test.suite('99 hotfix stripe find');
select test.mk_user('xt_admin', 'admin');
select test.mk_user('xt_fin', 'va', 'finance');
select test.mk_owner('xt_o');
select test.mk_vehicle('XTA', 'xt_o');
select test.mk_vehicle('XTB', 'xt_o');
select test.mk_vehicle('XTC', 'xt_o');
select test.mk_renter('xt_r');
-- XT-1, XT-2 and XT-3 owe a rental line ($226.00 with HST) and have their $1,000 deposit to take; XT-4 expired
select test.mk_booking('XT-1', 'XTA', 'xt_r', '2026-12-05 10:00', '2026-12-08 10:00', 'confirmed', 30000);
select test.mk_line('XT-1', 'rental_charge', 20000, false);
select test.mk_booking('XT-2', 'XTB', 'xt_r', '2026-12-05 10:00', '2026-12-08 10:00', 'confirmed', 30000);
select test.mk_line('XT-2', 'rental_charge', 20000, false);
select test.mk_booking('XT-3', 'XTC', 'xt_r', '2026-12-05 10:00', '2026-12-08 10:00', 'confirmed', 30000);
select test.mk_line('XT-3', 'rental_charge', 20000, false);
select test.mk_booking('XT-4', 'XTC', 'xt_r', '2027-01-05 10:00', '2027-01-08 10:00', 'expired', 30000);
select test.mk_line('XT-4', 'rental_charge', 20000, false);
create function test.xt_v(p_id text, p_cents bigint, p_status text default 'succeeded', p_currency text default 'cad') returns jsonb language sql immutable as $$
  select jsonb_build_object('intent_id', 'pi_' || p_id, 'charge_id', 'ch_' || p_id, 'status', p_status, 'amount_cents', p_cents, 'capturable_cents', 0,
                            'currency', p_currency, 'last4', '1111', 'brand', 'visa', 'fingerprint', null) $$;
create function test.xt_plan(p_booking text, p_id text, p_cents bigint, p_currency text default 'cad') returns jsonb language sql stable as $$
  select public.server_stripe_untied_plan(test.id('booking:' || p_booking), p_cents, p_currency, 'pi_' || p_id, 'ch_' || p_id) $$;
create function test.xt_link(p_booking text, p_v jsonb, p_user text default 'xt_admin') returns jsonb language sql as $$
  select public.server_stripe_link_untied(test.id(p_user), test.id('booking:' || p_booking), p_v) $$;

-- ================================================================ 1. the plan
select test.eq('the open amounts the tests use', app.booking_part_open(test.id('booking:XT-1'), 'balance') || '/' || (select deposit_cents from bookings where booking_number = 'XT-1'), '22600/100000');
select test.eq('exactly the rental and fees', test.xt_plan('XT-1', 'xttap0001', 22600) ->> 'as', 'rental');
select test.eq('exactly the deposit', test.xt_plan('XT-1', 'xttap0001', 100000) ->> 'as', 'deposit');
select test.eq('exactly both', (select (r ->> 'as') || '/' || (r ->> 'rental_cents') || '/' || (r ->> 'deposit_cents') from test.xt_plan('XT-1', 'xttap0001', 122600) r), 'rental_deposit/22600/100000');
select test.eq('another amount is refused with what is open',
  (select (r ->> 'ok') || '|' || (r ->> 'reason') from test.xt_plan('XT-1', 'xttap0001', 500000) r),
  'false|Stripe says $5,000.00 was paid; open on XT-1: the rental and fees $226.00, the deposit $1,000.00, both $1,226.00. An untied payment is linked only when it is exactly one of these');
select test.eq('another currency is refused', test.xt_plan('XT-1', 'xttap0001', 22600, 'usd') ->> 'ok', 'false');
select test.ok('an expired booking is refused: nothing is owed on it', (test.xt_plan('XT-4', 'xttap0004', 22600) ->> 'reason') like 'Booking XT-4 is expired%');

-- ================================================================ 2. linking
select test.throws('Admins only: Finance is refused', $$select test.xt_link('XT-1', test.xt_v('xttap0001', 22600), 'xt_fin')$$, 'Only an Admin');
select test.throws('a hold is not linked here (nothing is captured)', $$select test.xt_link('XT-1', test.xt_v('xttap0001', 22600, 'requires_capture'))$$, 'not succeeded');
select test.throws('a payment that is not the open amount', $$select test.xt_link('XT-1', test.xt_v('xttap0001', 500000))$$, 'exactly one of these');
select test.lives('the rental and fees, tapped in the Dashboard, linked', $$select test.xt_link('XT-1', test.xt_v('xttap0001', 22600))$$);
select test.eq('recorded as a card payment with its Stripe ids and the card Stripe read',
  (select p.method || '/' || p.card_last4 || '/' || p.amount_cents || '/' || x.processor_payment_id || '/' || m.stripe_verified
     from payments p join payment_processor_details x on x.payment_id = p.id join manual_payments m on m.payment_id = p.id
    where p.booking_id = test.id('booking:XT-1') and x.processor_payment_id = 'pi_xttap0001' limit 1), 'card/1111/22600/pi_xttap0001/true');
select test.eq('nothing open on XT-1 any more', app.booking_part_open(test.id('booking:XT-1'), 'balance'), 0::bigint);
select test.ok('audited: the link and the connector',
  exists (select 1 from audit_log a where a.action = 'link_stripe_payment' and a.entity_id = test.id('booking:XT-1')::text and a.after ->> 'intent_id' = 'pi_xttap0001')
  and exists (select 1 from audit_log a where a.action = 'connector_stripe_link_untied' and a.entity_id = test.id('booking:XT-1')::text and a.after ->> 'as' = 'rental'));
select test.eq('recorded elsewhere: refused, naming the booking',
  test.xt_plan('XT-2', 'xttap0001', 22600) ->> 'reason', 'This Stripe payment is already recorded on XT-1: nothing is recorded twice');
select test.throws('the same payment on another booking is refused', $$select test.xt_link('XT-2', test.xt_v('xttap0001', 22600))$$, 'already recorded on XT-1');
select test.eq('stripe_known_many says where', (app.stripe_known_many(array['pi_xttap0001', 'pi_nobody0001']) -> 'pi_xttap0001') ->> 'booking_number', 'XT-1');
select test.eq('and leaves out what it does not know', app.stripe_known_many(array['pi_nobody0001']), '{}'::jsonb);

select test.lives('the deposit alone, linked as captured', $$select test.xt_link('XT-2', test.xt_v('xttap0002', 100000))$$);
select test.eq('XT-2''s deposit is captured', (select d.method || '/' || d.status || '/' || d.captured_cents from deposits d where d.booking_id = test.id('booking:XT-2')), 'charged/captured/100000');

select test.lives('rental and deposit in one tap, linked as the two parts', $$select test.xt_link('XT-3', test.xt_v('xttap0003', 122600))$$);
select test.eq('XT-3: the rental paid, the deposit captured, both parts carry the PaymentIntent',
  app.booking_part_open(test.id('booking:XT-3'), 'balance') || '/' || (select d.status || ':' || d.captured_cents from deposits d where d.booking_id = test.id('booking:XT-3'))
  || '/' || (select count(*) from payment_processor_details x join payments p on p.id = x.payment_id where p.booking_id = test.id('booking:XT-3') and x.processor_payment_id = 'pi_xttap0003')
  || '/' || (select sum(p.amount_cents) from payments p where p.booking_id = test.id('booking:XT-3') and p.created_by = test.id('xt_admin')),
  '0/captured:100000/2/122600');
select test.ok('XT-3 is audited as both', exists (select 1 from audit_log a where a.action = 'link_stripe_payment' and a.entity_id = test.id('booking:XT-3')::text and a.after ->> 'as' = 'rental_deposit'));
select test.throws('and not twice', $$select test.xt_link('XT-3', test.xt_v('xttap0003', 122600))$$, 'already recorded');

-- ================================================================ 3. stripe_find_payments: the key and the window
select test.eq('a bad key is refused', app.api_call(repeat('0', 64), 'stripe_find_payments', '{}'::jsonb) ->> 'status', '401');
select app.api_key_create(test.id('xt_admin'), test.id('xt_admin'), 'xt key', array['admin:read'], encode(sha256('xt-key-r3430'::bytea), 'hex'), 'cc_live_xt_');
select test.eq('the default window is the last 24 hours',
  (select (r #>> '{result,run}') || '/' || round(((r #>> '{result,until}')::numeric - (r #>> '{result,since}')::numeric) / 3600)
     from app.api_call(encode(sha256('xt-key-r3430'::bytea), 'hex'), 'stripe_find_payments', '{}'::jsonb) r), 'stripe_find/24');
select test.eq('an amount filter is passed on',
  app.api_call(encode(sha256('xt-key-r3430'::bytea), 'hex'), 'stripe_find_payments', '{"hours": 48, "amount_cents": 500000}'::jsonb) #>> '{result,amount_cents}', '500000');
select test.eq('more than 30 days is refused',
  app.api_call(encode(sha256('xt-key-r3430'::bytea), 'hex'), 'stripe_find_payments', '{"hours": 721}'::jsonb) ->> 'status', '400');
select test.eq('a window from and to over 30 days is refused',
  app.api_call(encode(sha256('xt-key-r3430'::bytea), 'hex'), 'stripe_find_payments', jsonb_build_object('from', now() - interval '40 days', 'to', now() - interval '1 day')) ->> 'error',
  'The window is 30 days at most');
select test.ok('every call is logged', (select count(*) from api_calls c where c.tool = 'stripe_find_payments' and c.user_id = test.id('xt_admin')) >= 4);
select test.eq('the other tools still go through', app.api_call(encode(sha256('xt-key-r3430'::bytea), 'hex'), 'stripe_booking', '{"booking": "XT-1"}'::jsonb) #>> '{result,run}', 'stripe_booking');
