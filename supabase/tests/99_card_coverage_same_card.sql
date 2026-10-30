-- 99: a card-coverage rental is paid on the same card (migration 0203, docs/changes/2026-10-31-card-coverage-same-card.md). Fixtures "sc".
select test.suite('99 card coverage same card');
select test.mk_user('q21sc_admin', 'admin');
select test.mk_owner('q21sc_o');
select test.mk_vehicle('SCA', 'q21sc_o');
select test.mk_renter('q21sc_r');
select test.mk_booking('QSC-1', 'SCA', 'q21sc_r', '2026-12-05 10:00', '2026-12-08 10:00', 'confirmed', 30000);
select test.mk_booking('QSC-2', 'SCA', 'q21sc_r', '2026-12-15 10:00', '2026-12-18 10:00', 'confirmed', 30000);
update bookings set coverage_option = 2 where id in (test.id('booking:QSC-1'), test.id('booking:QSC-2'));
insert into payment_method_secrets (payment_method_id, processor, processor_customer_id, processor_method_id, fingerprint)
values (test.id('card:q21sc_r'), 'stripe', 'cus_sc', 'pm_sc', 'fp_same');
create function test.r21sc(p jsonb) returns jsonb language sql as $$ select app.door(test.id('q21sc_admin'), 'aal2', 'ops_do', 'record_card_payment', p) $$;

select test.eq('the rule: Visa ending 4242 (the Card on File)', (select r ->> 'required' || '/' || (r ->> 'last4') from (select app.card_coverage_ref(test.id('booking:QSC-1')) r) x), 'true/4242');
select test.throws('e-Transfer for the rental is refused',
  $$select app.door(test.id('q21sc_admin'), 'aal2', 'ops_do', 'record_booking_payment', '{"booking": "QSC-1", "covers": "rental", "method": "e_transfer", "amount_cents": 1000, "reference": "ABC123"}')$$, 'paid on that card (Visa ending 4242), not by e-Transfer');
select test.throws('another card typed by hand is refused',
  $$select test.r21sc('{"booking": "QSC-1", "covers": "rental", "amount_cents": 1000, "last4": "1111", "same_card": true}')$$, 'This card ends 1111');
select test.throws('the same card must be confirmed',
  $$select test.r21sc('{"booking": "QSC-1", "covers": "rental", "amount_cents": 1000, "last4": "4242"}')$$, 'confirm this is the same card');
select test.lives('the same card, confirmed',
  $$select test.r21sc('{"booking": "QSC-1", "covers": "rental", "amount_cents": 1000, "last4": "4242", "same_card": true}')$$);
select test.lives('a later charge on any card', $$select test.r21sc('{"booking": "QSC-1", "covers": "later", "amount_cents": 1000, "last4": "1111"}')$$);
select test.eq('the reader: the same fingerprint passes', (select public.server_payreq_card_check(q.id, '{"fingerprint": "fp_same", "last4": "4242"}') ->> 'ok' from
  (select (app.door(test.id('q21sc_admin'), 'aal2', 'ops_do', 'payreq_create', jsonb_build_object('booking', 'QSC-2', 'kind', 'charge', 'covers', 'later', 'amount_cents', 500, 'reason', 'Fuel',
     'channel', 'device', 'token_sha256', md5(random()::text) || md5(random()::text))) ->> 'id')::uuid as id) q), 'true');
create table test.r21scq as select (app.door(test.id('q21sc_admin'), 'aal2', 'ops_do', 'payreq_create', jsonb_build_object('booking', 'QSC-2', 'kind', 'charge', 'covers', 'rental', 'amount_cents', 500,
     'channel', 'device', 'token_sha256', md5(random()::text) || md5(random()::text))) ->> 'id')::uuid as id;
select test.eq('the reader: another card is refused before capture', public.server_payreq_card_check((select id from test.r21scq), '{"fingerprint": "fp_other", "last4": "4242"}') ->> 'ok', 'false');
select public.server_payreq_attach((select id from test.r21scq), 'pi_sc_other');
select test.eq('the pay page: another card is refused and given back',
  (select r ->> 'ok' || '/' || (r ->> 'refund') from (select public.server_payreq_settle((select id from test.r21scq),
     '{"id": "pi_sc_other", "status": "succeeded", "amount": 500, "card": {"brand": "visa", "last4": "1881", "fingerprint": "fp_other"}}') r) x), 'false/true');
select test.eq('nothing recorded, the request failed with the reason',
  (select status || '/' || (last_error like 'This rental''s coverage%') from payment_requests where id = (select id from test.r21scq)) || '/' ||
  (select count(*) from payments where booking_id = test.id('booking:QSC-2') and card_last4 = '1881'), 'failed/true/0');
select test.throws('the override needs a reason', $$select app.door(test.id('q21sc_admin'), 'aal2', 'ops_do', 'card_coverage_override', '{"booking": "QSC-2", "reason": "short"}')$$, 'reason');
select test.lives('an Admin allows another card, with the reason',
  $$select app.door(test.id('q21sc_admin'), 'aal2', 'ops_do', 'card_coverage_override', '{"booking": "QSC-2", "reason": "Renter''s card replaced by the bank, same account"}')$$);
select test.lives('then another card is accepted', $$select test.r21sc('{"booking": "QSC-2", "covers": "rental", "amount_cents": 1000, "last4": "1111"}')$$);
select test.eq('the booking''s money shows the rule', app.booking_money(test.id('q21sc_admin'), '{"booking": "QSC-2"}') #>> '{card_rule,overridden}', 'true');
