-- 99: a higher deposit on a debit or prepaid card (migration 0262). Fixtures start with "dd".
select test.suite('99 debit deposit');
select test.mk_user('dd_admin', 'admin');
select test.mk_user('dd_cs', 'va', 'cs');
select test.mk_owner('dd_o');
select test.mk_vehicle('DDA', 'dd_o');
select test.mk_renter('dd_r');
insert into payment_method_secrets (payment_method_id, processor, processor_customer_id, processor_method_id, fingerprint)
values (test.id('card:dd_r'), 'stripe', 'cus_dd', 'pm_dd', 'fp_dd');
update payment_methods set funding = 'debit', is_credit = false where id = test.id('card:dd_r');
create or replace function test.dd_at(p_hours int) returns text language sql as $$
  select to_char((now() + make_interval(hours => p_hours)) at time zone 'America/Toronto', 'YYYY-MM-DD HH24:MI') $$;
select test.mk_booking('CC-DD1', 'DDA', 'dd_r', test.dd_at(30), test.dd_at(80), 'confirmed');
update bookings set deposit_pay_method = 'card', deposit_cents = 30000 where booking_number = 'CC-DD1';
create function test.dd_b() returns bookings language sql as $$ select * from bookings where booking_number = 'CC-DD1' $$;

select test.eq('the setting: 2 times by default', (select debit_deposit_multiplier from program_settings where id = (app.settings()).id), 2.00::numeric);
select test.eq('$300 becomes $600 on a debit or prepaid card', app.debit_deposit_cents(test.dd_b()), 60000::bigint);
select test.eq('a credit card: the deposit', app.deposit_hold_amount(test.dd_b(), 'credit'), 30000::bigint);
select test.eq('a debit card on a booking that needs credit: no higher amount (the card is refused anyway)', app.deposit_hold_amount(test.dd_b(), 'debit'), 30000::bigint);
select test.ok('not said to the renter before the override', public.server_booking_debit_deposit((test.dd_b()).id) is null);
select test.lives('an Admin allows a debit card', $$select app.door(test.id('dd_admin'), 'aal2', 'admin_do', 'booking_allow_debit', '{"booking": "CC-DD1", "allow": true, "reason": "Renter has only a debit card"}')$$);
select test.eq('with the override: $600 on debit', app.deposit_hold_amount(test.dd_b(), 'debit'), 60000::bigint);
select test.eq('and on prepaid', app.deposit_hold_amount(test.dd_b(), 'prepaid'), 60000::bigint);
select test.eq('the offer and the booking summary say it', public.server_booking_debit_deposit((test.dd_b()).id), 60000::bigint);
select test.eq('the Money tab: Debit deposit 2x ($600)', (select (m #>> '{debit_deposit,multiplier}') || '/' || (m #>> '{debit_deposit,cents}') || '/' || (m #>> '{debit_deposit,takes}')
  from (select app.booking_money(test.id('dd_admin'), '{"booking": "CC-DD1"}') m) x), '2.00/60000/true');

-- the pickup-day hold on the saved debit card is the debit deposit
update program_settings set deposit_auto_hour = 0 where id = (app.settings()).id;
update bookings b set pickup_at = x.at, return_at = x.at + (b.return_at - b.pickup_at), original_return_at = x.at + (b.return_at - b.pickup_at)
  from (select case when (now() + interval '20 minutes') at time zone 'America/Toronto' < date_trunc('day', now() at time zone 'America/Toronto') + interval '1 day'
                    then now() + interval '20 minutes' else now() - interval '1 minute' end as at) x where b.booking_number = 'CC-DD1';
select test.eq('the automatic hold: $600 on the debit card', public.server_deposit_auto_begin((test.dd_b()).id, md5('dd1') || md5('dd2')) ->> 'amount_cents', '60000');
update program_settings set deposit_auto_hour = 8 where id = (app.settings()).id;

-- staff's hold link: asked again for the right amount when the card is another kind
create temp table dd_q as select (app.door(test.id('dd_cs'), 'aal2', 'ops_do', 'payreq_create', jsonb_build_object('booking', 'CC-DD1', 'kind', 'hold', 'channel', 'text', 'token_sha256', md5('dd3') || md5('dd4'))) ->> 'id')::uuid as id;
select test.eq('a link for the deposit', (select amount_cents from payment_requests where id = (select id from dd_q)), 30000::bigint);
select test.eq('the pay page says the debit amount before the card', public.server_payreq_debit_deposit((select id from dd_q)), 60000::bigint);
select test.eq('a debit card on it needs $600', public.server_payreq_hold_required((select id from dd_q), '{"funding": "debit"}'), 60000::bigint);
select test.eq('a credit card needs $300', public.server_payreq_hold_required((select id from dd_q), '{"funding": "credit"}'), 30000::bigint);
select public.server_payreq_hold_reset((select id from dd_q), 'pi_dd_again', 60000);
select test.eq('asked again: the new amount and authorization on the same link', (select amount_cents || '/' || processor_intent_id || '/' || status from payment_requests where id = (select id from dd_q)), '60000/pi_dd_again/open');

-- staff set another amount for the booking
select test.throws('only an Admin', $$select app.door(test.id('dd_cs'), 'aal2', 'admin_do', 'booking_debit_deposit', '{"booking": "CC-DD1", "amount_cents": 45000, "reason": "x"}')$$, null);
select test.throws('with a reason', $$select app.door(test.id('dd_admin'), 'aal2', 'admin_do', 'booking_debit_deposit', '{"booking": "CC-DD1", "amount_cents": 45000}')$$, 'reason');
select test.throws('not below the deposit', $$select app.door(test.id('dd_admin'), 'aal2', 'admin_do', 'booking_debit_deposit', '{"booking": "CC-DD1", "amount_cents": 20000, "reason": "Long-time renter"}')$$, 'at least the deposit');
select test.eq('an Admin sets $450 for this booking', app.door(test.id('dd_admin'), 'aal2', 'admin_do', 'booking_debit_deposit', '{"booking": "CC-DD1", "amount_cents": 45000, "reason": "Long-time renter"}') ->> 'debit_deposit_cents', '45000');
select test.ok('the Money tab says it was set, audited', (app.booking_money(test.id('dd_admin'), '{"booking": "CC-DD1"}') #>> '{debit_deposit,set_by_staff}')::boolean
  and exists (select 1 from audit_log where action = 'booking_debit_deposit' and entity_id = (test.dd_b()).id::text));
select test.eq('empty: back to the multiple', app.door(test.id('dd_admin'), 'aal2', 'admin_do', 'booking_debit_deposit', '{"booking": "CC-DD1", "reason": "Back to standard"}') ->> 'debit_deposit_cents', '60000');
update program_settings set debit_deposit_multiplier = 1.5 where id = (app.settings()).id;
select test.eq('the setting changed: 1.5 times', app.debit_deposit_cents(test.dd_b()), 45000::bigint);
update program_settings set debit_deposit_multiplier = 2 where id = (app.settings()).id;
