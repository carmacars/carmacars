-- 99: link a payment taken outside the platform, and the nightly list of Stripe payments no booking knows (migration 1081,
-- docs/changes/2026-11-08-r35-live-map-speed-stripe-link.md). The website reads the payment at Stripe (mocked here as its
-- answer, "verified"); the database checks the currency, the amount, that nothing has it yet, and records it as a rental
-- payment or as the deposit (held or captured, per its status). Fixtures start with "xs"; every address is example.test.
select test.suite('99 r35l stripe link');
select test.mk_user('xs_admin', 'admin');
select test.mk_user('xs_fin', 'va', 'finance');
select test.mk_owner('xs_o');
select test.mk_vehicle('XSA', 'xs_o');
select test.mk_vehicle('XSB', 'xs_o');
select test.mk_vehicle('XSC', 'xs_o');
select test.mk_renter('xs_r');
select test.mk_renter('xs_q');
-- XS-1 and XS-5 owe a rental line ($226.00 with HST); XS-2, XS-3 and XS-6 have their $1,000 deposit to take
select test.mk_booking('XS-1', 'XSA', 'xs_r', '2026-12-05 10:00', '2026-12-08 10:00', 'confirmed', 30000);
select test.mk_line('XS-1', 'rental_charge', 20000, false);
select test.mk_booking('XS-2', 'XSA', 'xs_q', '2026-12-15 10:00', '2026-12-18 10:00', 'confirmed', 30000);
select test.mk_booking('XS-3', 'XSB', 'xs_q', '2026-12-05 10:00', '2026-12-08 10:00', 'confirmed', 30000);
-- XS-5's pickup is in 5 days (the amount guess looks 30 days around the payment)
select test.mk_booking('XS-5', 'XSC', 'xs_q', to_char((now() + interval '5 days') at time zone 'America/Toronto', 'YYYY-MM-DD HH24:00'),
  to_char((now() + interval '8 days') at time zone 'America/Toronto', 'YYYY-MM-DD HH24:00'), 'confirmed', 30000);
select test.mk_line('XS-5', 'rental_charge', 20111, false);   -- an amount no other suite's booking has open
select test.mk_booking('XS-6', 'XSB', 'xs_q', '2027-01-05 10:00', '2027-01-08 10:00', 'confirmed', 30000);
create function test.xs_link(p_booking text, p_as text, p_verified jsonb, p_user text default 'xs_admin') returns jsonb language sql as $$
  select app.door(test.id(p_user), 'aal2', 'admin_do', 'link_stripe_payment', jsonb_build_object('booking', p_booking, 'as', p_as, 'verified', p_verified)) $$;
create function test.xs_v(p_id text, p_status text, p_cents bigint, p_currency text default 'cad', p_last4 text default '4242') returns jsonb language sql immutable as $$
  select jsonb_build_object('intent_id', 'pi_' || p_id, 'charge_id', 'ch_' || p_id, 'status', p_status, 'amount_cents', p_cents,
                            'capturable_cents', case when p_status = 'requires_capture' then p_cents else 0 end, 'currency', p_currency, 'last4', p_last4, 'brand', 'visa') $$;

-- ================================================================ 1. the checks
select test.eq('the open amount the tests use', app.booking_part_open(test.id('booking:XS-1'), 'balance'), 22600::bigint);
select test.throws('Admins only: Finance is refused', $$select test.xs_link('XS-1', 'rental', test.xs_v('xsrent0001', 'succeeded', 22600), 'xs_fin')$$, 'Only an Admin');
select test.throws('read at Stripe first', $$select test.xs_link('XS-1', 'rental', null)$$, 'read at Stripe first');
select test.throws('Canadian dollars only', $$select test.xs_link('XS-1', 'rental', test.xs_v('xsrent0001', 'succeeded', 22600, 'usd'))$$, 'USD, not Canadian dollars');
select test.throws('a hold is not a rental payment', $$select test.xs_link('XS-1', 'rental', test.xs_v('xsrent0001', 'requires_capture', 22600))$$, 'link it as the deposit');
select test.throws('a payment that did not go through', $$select test.xs_link('XS-1', 'rental', test.xs_v('xsrent0001', 'requires_payment_method', 22600))$$, 'not paid');
select test.throws('no more than is open for the rental and fees', $$select test.xs_link('XS-1', 'rental', test.xs_v('xsrent0001', 'succeeded', 30000))$$, 'more than the $226.00 open');
select test.throws('a payment with no card', $$select test.xs_link('XS-1', 'rental', test.xs_v('xsrent0001', 'succeeded', 22600, 'cad', null))$$, 'no card');

-- ================================================================ 2. a rental payment
select test.lives('a charge taken in the Stripe Dashboard, linked as a rental payment', $$select test.xs_link('XS-1', 'rental', test.xs_v('xsrent0001', 'succeeded', 22600))$$);
select test.eq('recorded as a card payment with its Stripe ids and the card Stripe read',
  (select p.method || '/' || p.card_last4 || '/' || p.amount_cents || '/' || p.status || '/' || x.processor || '/' || x.processor_payment_id || '/' || x.processor_charge_id || '/' || m.stripe_verified
     from payments p join payment_processor_details x on x.payment_id = p.id join manual_payments m on m.payment_id = p.id
    where p.booking_id = test.id('booking:XS-1') and x.processor_payment_id = 'pi_xsrent0001'), 'card/4242/22600/succeeded/stripe/pi_xsrent0001/ch_xsrent0001/true');
select test.eq('nothing is open on XS-1 any more', app.booking_part_open(test.id('booking:XS-1'), 'balance'), 0::bigint);
select test.eq('the link is audited', (select a.after ->> 'as' || '/' || (a.after ->> 'intent_id') from audit_log a where a.action = 'link_stripe_payment' and a.entity_id = test.id('booking:XS-1')::text), 'rental/pi_xsrent0001');
select test.throws('the same Stripe payment twice is refused', $$select test.xs_link('XS-5', 'rental', test.xs_v('xsrent0001', 'succeeded', 22600))$$, 'already linked');
select test.throws('its charge id alone is known too',
  $$select test.xs_link('XS-5', 'rental', test.xs_v('xsrent0001', 'succeeded', 22600) || '{"intent_id": "pi_xsother0001"}')$$, 'already linked');
select test.throws('nothing open: a later charge is recorded another way', $$select test.xs_link('XS-1', 'rental', test.xs_v('xsrent0002', 'succeeded', 1000))$$, 'Nothing is open');

-- ================================================================ 3. the deposit
select test.lives('a deposit hold taken in the Dashboard, linked as the deposit', $$select test.xs_link('XS-2', 'deposit', test.xs_v('xsdep0002', 'requires_capture', 100000))$$);
select test.eq('kept as held: released or captured from Settle the deposit',
  (select d.method || '/' || d.status || '/' || d.amount_cents || '/' || p.kind || '/' || p.status from deposits d join payments p on p.id = d.hold_payment_id
    where d.booking_id = test.id('booking:XS-2')), 'card_hold/held/100000/hold/authorized');
select test.lives('a deposit charged through a payment link, linked as the deposit', $$select test.xs_link('XS-3', 'deposit', test.xs_v('xsdep0003', 'succeeded', 100000))$$);
select test.eq('kept as captured',
  (select d.method || '/' || d.status || '/' || d.captured_cents || '/' || p.purpose || '/' || p.kind || '/' || p.status || '/' || x.processor_payment_id
     from deposits d join payments p on p.id = d.hold_payment_id join payment_processor_details x on x.payment_id = p.id
    where d.booking_id = test.id('booking:XS-3')), 'charged/captured/100000/deposit/charge/succeeded/pi_xsdep0003');
select test.ok('the deposit link is audited and on the booking''s history',
  exists (select 1 from audit_log a where a.action = 'link_stripe_payment' and a.entity_id = test.id('booking:XS-3')::text and a.after ->> 'as' = 'deposit')
  and exists (select 1 from deposit_events e join deposits d on d.id = e.deposit_id where d.booking_id = test.id('booking:XS-3') and e.kind = 'taken'));
select test.throws('a deposit already taken', $$select test.xs_link('XS-3', 'deposit', test.xs_v('xsdep0004', 'succeeded', 100000))$$, 'already been taken');
select test.throws('the whole deposit', $$select test.xs_link('XS-6', 'deposit', test.xs_v('xsdep0006', 'succeeded', 50000))$$, 'the deposit on XS-6 is $1,000.00');
select test.throws('a deposit refunded or cancelled at Stripe', $$select test.xs_link('XS-6', 'deposit', test.xs_v('xsdep0006', 'canceled', 100000))$$, 'only a paid payment or a hold');

-- ================================================================ 4. the nightly list of unlinked Stripe payments
create function test.xs_c(p_id text, p_cents bigint, p_email text, p_days integer default 1, p_extra jsonb default '{}') returns jsonb language sql stable as $$
  select jsonb_build_object('id', 'ch_' || p_id, 'intent_id', 'pi_' || p_id, 'amount_cents', p_cents, 'refunded_cents', 0, 'currency', 'cad',
                            'created', extract(epoch from now() - make_interval(days => p_days))::bigint, 'email', p_email, 'name', 'Example Payer',
                            'last4', '4242', 'brand', 'visa') || p_extra $$;
select test.eq('the check keeps the payments no booking knows, with a guess',
  public.server_stripe_unlinked_save(jsonb_build_object('ok', true, 'charges', jsonb_build_array(
    test.xs_c('xsrent0001', 22600, null),                                       -- linked above: left out
    test.xs_c('xsmail0001', 4500, 'XS_R@example.test', 2),                      -- the renter's email
    test.xs_c('xsamt00001', app.booking_part_open(test.id('booking:XS-5'), 'balance'), null, 3),   -- XS-5 has that much open
    test.xs_c('xsbn000001', 7700, null, 4, '{"booking_number": "xs-6"}'),       -- the booking number a payment link kept
    test.xs_c('xsnone0001', 1234, null, 5),                                     -- no guess
    test.xs_c('xsref00001', 5000, null, 2, '{"refunded_cents": 5000}'),         -- refunded in full: left out
    test.xs_c('xsold00001', 5000, null, 70)))) ->> 'unlinked', '4');            -- older than 60 days: left out
select test.eq('the guesses',
  (select string_agg(u.charge_id || '=' || coalesce(b.booking_number, '-') || ':' || coalesce(u.guess_reason, '-'), ' ' order by u.charge_id)
     from stripe_unlinked u left join bookings b on b.id = u.guess_booking_id where u.charge_id like 'ch_xs%'),
  'ch_xsamt00001=XS-5:amount ch_xsbn000001=XS-6:booking number in Stripe ch_xsmail0001=XS-1:email ch_xsnone0001=-:-');
select test.eq('Finance reads the list on Money',
  (app.door(test.id('xs_fin'), 'aal2', 'ops_read', 'stripe_unlinked', '{"_va": "finance"}') ->> 'open')::integer >= 4, true);
select test.throws('a renter does not', $$select app.door(test.id('xs_r'), 'aal2', 'ops_read', 'stripe_unlinked', '{}')$$, 'Only an Admin or Finance');
select test.throws('put aside with a reason only', $$select app.door(test.id('xs_fin'), 'aal2', 'ops_do', 'stripe_unlinked_dismiss', '{"charge_id": "ch_xsnone0001", "_va": "finance"}')$$, 'Say why');
select test.lives('put aside: not a booking''s payment',
  $$select app.door(test.id('xs_fin'), 'aal2', 'ops_do', 'stripe_unlinked_dismiss', '{"charge_id": "ch_xsnone0001", "note": "An owner fee", "_va": "finance"}')$$);
select test.ok('a payment put aside leaves the list, and shows with the ones put aside',
  not exists (select 1 from jsonb_array_elements(app.stripe_unlinked_read(test.id('xs_admin')) -> 'rows') r where r ->> 'charge_id' = 'ch_xsnone0001')
  and exists (select 1 from jsonb_array_elements(app.stripe_unlinked_read(test.id('xs_admin'), '{"dismissed": true}') -> 'rows') r where r ->> 'charge_id' = 'ch_xsnone0001'));
select test.lives('linking one from the list', $$select test.xs_link('XS-5', 'rental', test.xs_v('xsamt00001', 'succeeded', app.booking_part_open(test.id('booking:XS-5'), 'balance')))$$);
select test.ok('a linked payment leaves the list at once', not exists (select 1 from stripe_unlinked where charge_id = 'ch_xsamt00001'));
select test.eq('the next check: what is linked is left out',
  public.server_stripe_unlinked_save(jsonb_build_object('ok', true, 'charges', jsonb_build_array(test.xs_c('xsamt00001', 22600, null, 3), test.xs_c('xsnone0001', 1234, null, 5)))) ->> 'unlinked', '1');
select test.eq('it keeps what is put aside, and drops what Stripe no longer lists',
  (select count(*) || ' ' || bool_and(dismissed_at is not null) from stripe_unlinked), '1 true');
select public.server_stripe_unlinked_save('{"ok": false, "error": "Stripe is down"}');
select test.eq('a failed check is recorded with its reason',
  (select c.ok::text || ' ' || c.error from stripe_unlinked_checks c order by c.ran_at desc, c.id limit 1), 'false Stripe is down');
select test.eq('a check is not due again within the hour', app.stripe_unlinked_due(), false);
delete from stripe_unlinked_checks;
select test.eq('due from 3 a.m. Toronto, once a night', app.stripe_unlinked_due(), now() >= app.local_midnight(app.today()) + interval '3 hours');
select test.eq('the cron gate runs the deposit guard''s job when it is due',
  coalesce((app.server_jobs_due() ->> 'stripe_unlinked')::boolean, false), app.stripe_unlinked_due());
select test.ok('the tables and the website''s calls are the service role''s',
  not has_table_privilege('authenticated', 'stripe_unlinked', 'select') and not has_table_privilege('anon', 'stripe_unlinked_checks', 'select')
  and not has_function_privilege('authenticated', 'public.server_stripe_unlinked_save(jsonb)', 'execute')
  and not has_function_privilege('anon', 'app.link_stripe_payment(uuid, jsonb)', 'execute')
  and has_function_privilege('service_role', 'public.server_stripe_unlinked_save(jsonb)', 'execute'));
