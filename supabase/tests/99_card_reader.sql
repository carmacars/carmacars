-- 99: the card reader, a Stripe Terminal S700 (migration 0202, docs/changes/2026-10-31-card-reader.md). Fixtures "cr".
select test.suite('99 card reader');
select test.mk_user('cr_admin', 'admin');
select test.mk_user('cr_cs', 'va', 'cs');
select test.mk_owner('cr_o');
select test.mk_vehicle('CRA', 'cr_o');
select test.mk_renter('cr_r');
select test.mk_booking('CR-1', 'CRA', 'cr_r', '2026-12-05 10:00', '2026-12-08 10:00', 'confirmed', 30000);
create function test.cr(p_user text, p_call text, p_name text, p jsonb default '{}') returns jsonb language sql as $$ select app.door(test.id(p_user), 'aal2', p_call, p_name, p) $$;

select test.throws('no reader yet: the reason says who pairs it',
  $$select test.cr('cr_admin', 'ops_do', 'payreq_create', jsonb_build_object('booking', 'CR-1', 'kind', 'hold', 'channel', 'reader', 'token_sha256', repeat('a', 64)))$$, 'No card reader is paired');
select test.throws('only an Admin pairs a reader', $$select test.cr('cr_cs', 'admin_do', 'terminal_reader_save', '{"stripe_reader_id": "tmr_abc", "label": "Front desk"}')$$, null);
select test.lives('the location from the mailing address', $$select test.cr('cr_admin', 'admin_do', 'terminal_location_save', '{"stripe_location_id": "tml_test1", "display_name": "CarmaCars", "address": "1 Test St, Toronto, ON M5V 1A1"}')$$);
select test.lives('an Admin pairs the S700', $$select test.cr('cr_admin', 'admin_do', 'terminal_reader_save', '{"stripe_reader_id": "tmr_test1", "label": "Front desk", "device_type": "stripe_s700", "stripe_location_id": "tml_test1"}')$$);
select test.eq('Settings shows it', (test.cr('cr_admin', 'ops_read', 'terminal_state') #>> '{readers,0,label}') || '/' || (test.cr('cr_admin', 'ops_read', 'terminal_state') #>> '{location,stripe_location_id}'), 'Front desk/tml_test1');
select test.eq('staff who take cards see the reader', test.cr('cr_cs', 'ops_read', 'terminal_readers') #>> '{0,label}', 'Front desk');
create table test.crq as select test.cr('cr_admin', 'ops_do', 'payreq_create', jsonb_build_object('booking', 'CR-1', 'kind', 'hold', 'channel', 'reader', 'token_sha256', repeat('b', 64))) as r;
select test.eq('a hold on the reader: a payment request of channel reader, for the deposit',
  (select q.channel || '/' || q.kind || '/' || q.amount_cents || '/' || (q.reader_id is not null) || '/' || (q.expires_at < now() + interval '31 minutes') from payment_requests q where q.id = (select (r ->> 'id')::uuid from test.crq)),
  'reader/hold/100000/true/true');
select test.eq('the reader goes back to the website', (select r #>> '{reader,stripe_reader_id}' from test.crq), 'tmr_test1');
select public.server_payreq_attach((select (r ->> 'id')::uuid from test.crq), 'pi_reader_hold_1');
select test.eq('the poll reads the request', public.server_payreq_reader((select (r ->> 'id')::uuid from test.crq)) ->> 'intent_id', 'pi_reader_hold_1');
select test.lives('the card is presented: the hold settles',
  $$select public.server_payreq_settle((select (r ->> 'id')::uuid from test.crq), '{"id": "pi_reader_hold_1", "status": "requires_capture", "amount": 100000, "amount_capturable": 100000,
      "charge_id": "ch_reader_hold_1", "method_id": "pm_card_present_1", "card": {"brand": "visa", "last4": "4242", "funding": "credit", "fingerprint": "fp_1"}}')$$);
select test.eq('held for 2 days on the card, the card not saved as the Card on File',
  (select d.status || '/' || (d.hold_expires_at < now() + interval '49 hours') || '/' || (p.payment_method_id is null) || '/' || p.card_last4
     from deposits d join payments p on p.id = d.hold_payment_id where d.booking_id = test.id('booking:CR-1')), 'held/true/true/4242');
create table test.crq2 as select test.cr('cr_admin', 'ops_do', 'payreq_create', jsonb_build_object('booking', 'CR-1', 'kind', 'charge', 'covers', 'later', 'amount_cents', 2500, 'reason', 'Fuel', 'channel', 'reader', 'token_sha256', repeat('c', 64))) as r;
select public.server_payreq_reader_fail((select (r ->> 'id')::uuid from test.crq2), 'The renter cancelled on the reader');
select test.eq('a request that did not go through keeps the reason', (select status || '/' || last_error from payment_requests where id = (select (r ->> 'id')::uuid from test.crq2)), 'failed/The renter cancelled on the reader');
select test.lives('a reader is removed', format($$select test.cr('cr_admin', 'admin_do', 'terminal_reader_remove', '{"id": "%s"}')$$, (select id from terminal_readers where stripe_reader_id = 'tmr_test1')));
select test.eq('and is no longer offered', jsonb_array_length(test.cr('cr_cs', 'ops_read', 'terminal_readers')), 0);
