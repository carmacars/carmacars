-- 99: card payments on Helcim (migration 3710, release 50; docs/changes/2026-11-24-r50-helcim.md). The adapter's payments
-- (helcim_intents) and its money calls by key (helcim_calls), server only; the hold plan (a rental longer than the 7-day hold
-- window has its deposit charged instead); the provider of each payment (an hc_ id is Helcim's, the history Stripe's); a
-- deposit charged instead never shows a hold expiry; an untied Helcim payment links like Stripe's; the connector's three
-- tools check the key, the scope, the window and the preview. Fixtures start with "xh"; every address is example.test.
select test.suite('99 r50 helcim');
select test.mk_user('xh_admin', 'admin');
select test.mk_user('xh_fin', 'va', 'finance');
select test.mk_owner('xh_o');
select test.mk_vehicle('XHA', 'xh_o');
select test.mk_vehicle('XHB', 'xh_o');
select test.mk_renter('xh_r');
select test.mk_booking('XH-1', 'XHA', 'xh_r', '2026-12-05 10:00', '2026-12-08 10:00', 'confirmed', 30000);
select test.mk_line('XH-1', 'rental_charge', 20000, false);
select test.mk_booking('XH-2', 'XHB', 'xh_r', '2026-12-05 10:00', '2026-12-19 10:00', 'confirmed', 30000);
create function test.xh_row(p_id text, p_key text, p_status text, p_booking text default null, p_tx bigint default null, p_charge boolean default false) returns jsonb language sql stable as $$
  select jsonb_build_object('id', p_id, 'key', p_key, 'kind', 'staff', 'capture', 'manual', 'status', p_status, 'amountCents', 100000, 'capturableCents', 0, 'capturedCents', 0,
    'refundedCents', 0, 'metadata', jsonb_strip_nulls(jsonb_build_object('booking_id', test.id('booking:' || p_booking), 'purpose', 'staff_request', 'covers', 'deposit')),
    'customerCode', 'CCXH', 'description', 'x', 'checkoutToken', 'ct_' || p_key, 'secretToken', 'st_secret_' || p_key, 'tokenAt', 0, 'transactionId', p_tx,
    'captureTransactionId', null, 'cardToken', null, 'card', null, 'lastError', null, 'heldAsCharge', p_charge, 'placedAt', null, 'createdAt', 0) $$;

-- ================================================================ 1. the adapter's store: the server only
select test.lives('a payment is kept', $$select public.server_helcim_intent_put(test.xh_row('hc_xh00000001', 'payreq:xh1', 'requires_payment_method', 'XH-1'))$$);
select test.eq('read back whole, with its booking and purpose as columns',
  (select (public.server_helcim_intent_get('hc_xh00000001') ->> 'status') || '/' || (booking_id = test.id('booking:XH-1'))::text || '/' || purpose from helcim_intents where id = 'hc_xh00000001'),
  'requires_payment_method/true/staff_request');
select test.eq('found by its key and by its checkout session', (public.server_helcim_intent_find('{"key": "payreq:xh1"}') ->> 'id') || '/' || (public.server_helcim_intent_find('{"checkout_token": "ct_payreq:xh1"}') ->> 'id'), 'hc_xh00000001/hc_xh00000001');
select test.lives('an update keeps one row', $$select public.server_helcim_intent_put(test.xh_row('hc_xh00000001', 'payreq:xh1', 'requires_capture', 'XH-1', 25000001))$$);
select test.eq('found by its transaction', public.server_helcim_intent_find('{"transaction_id": 25000001}') ->> 'status', 'requires_capture');
select test.eq('one row', (select count(*) from helcim_intents where id = 'hc_xh00000001'), 1::bigint);
select test.throws('an id that is not Helcim''s is refused', $$select public.server_helcim_intent_put(test.xh_row('pi_xh00000001', 'k', 'succeeded'))$$, 'Not a Helcim payment id');
select test.throws('a transaction is on one payment only', $$select public.server_helcim_intent_put(test.xh_row('hc_xh00000009', 'other', 'succeeded', null, 25000001))$$, 'helcim_intents_one_tx');
select test.lives('a money call is kept by its key', $$select public.server_helcim_call_put('capture:hc_xh00000001', '{"status": "succeeded"}')$$);
select test.lives('and never overwritten', $$select public.server_helcim_call_put('capture:hc_xh00000001', '{"status": "other"}')$$);
select test.eq('the first result stays', public.server_helcim_call_get('capture:hc_xh00000001') #>> '{result,status}', 'succeeded');
select test.eq('open sessions of a customer and amount', jsonb_array_length(public.server_helcim_intent_open('CCXH', 100000, now() - interval '1 hour')), 0);
select test.ok('anon and authenticated cannot run the store', not has_function_privilege('authenticated', 'public.server_helcim_intent_get(text)', 'execute')
  and not has_function_privilege('anon', 'public.server_helcim_intent_put(jsonb)', 'execute') and has_function_privilege('service_role', 'public.server_helcim_intent_put(jsonb)', 'execute'));
select test.ok('the tables are the server''s only', not has_table_privilege('authenticated', 'helcim_intents', 'select') and not has_table_privilege('anon', 'helcim_calls', 'select'));
select test.ok('every new function ends its search_path with pg_temp',
  not exists (select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
               where p.proname in ('server_helcim_intent_put', 'server_helcim_intent_get', 'server_helcim_intent_find', 'server_helcim_intent_open', 'server_helcim_call_get',
                                   'server_helcim_call_put', 'server_helcim_hold_plan', 'server_helcim_known', 'helcim_hold_plan', 'processor_details_provider', 'processor_details_after')
                 and not exists (select 1 from unnest(p.proconfig) c where c like 'search_path=%pg_temp')));

-- ================================================================ 2. the hold plan
select test.eq('a 3-day rental: a hold', public.server_helcim_hold_plan(test.id('booking:XH-1'), 7), 'hold');
select test.eq('a 14-day rental: charged and refunded at release', public.server_helcim_hold_plan(test.id('booking:XH-2'), 7), 'charge');
select test.eq('an unknown booking: a hold', public.server_helcim_hold_plan(gen_random_uuid(), 7), 'hold');

-- ================================================================ 3. the provider of each payment, and a deposit charged instead
insert into payments (booking_id, renter_id, purpose, kind, method, amount_cents, status) values (test.id('booking:XH-2'), test.id('renter:xh_r'), 'deposit', 'hold', 'card', 30000, 'authorized');
select public.server_helcim_intent_put(test.xh_row('hc_xh00000002', 'payreq:xh2', 'requires_capture', 'XH-2', 25000002, true));
insert into deposits (booking_id, amount_cents, method, status, hold_payment_id, hold_expires_at)
select test.id('booking:XH-2'), 30000, 'card_hold', 'held', p.id, now() + interval '7 days' from payments p where p.booking_id = test.id('booking:XH-2') and p.purpose = 'deposit'
on conflict (booking_id) do update set hold_payment_id = excluded.hold_payment_id, status = 'held', method = 'card_hold', hold_expires_at = excluded.hold_expires_at;
insert into payment_processor_details (payment_id, processor, processor_payment_id) select p.id, 'stripe', 'hc_xh00000002' from payments p where p.booking_id = test.id('booking:XH-2') and p.purpose = 'deposit';
select test.eq('details written "stripe" for an hc_ id say helcim, and the payment follows',
  (select d.processor || '/' || p.provider from payment_processor_details d join payments p on p.id = d.payment_id where d.processor_payment_id = 'hc_xh00000002'), 'helcim/helcim');
select test.eq('the deposit is marked charged instead, with no hold expiry',
  (select d.held_as_charge::text || '/' || coalesce(d.hold_expires_at::text, 'none') from deposits d where d.booking_id = test.id('booking:XH-2')), 'true/none');
insert into payments (booking_id, renter_id, purpose, kind, method, amount_cents, status) values (test.id('booking:XH-1'), test.id('renter:xh_r'), 'booking_total', 'charge', 'card', 22600, 'succeeded');
insert into payment_processor_details (payment_id, processor_payment_id) select p.id, 'pi_xhstripe01' from payments p where p.booking_id = test.id('booking:XH-1') and p.purpose = 'booking_total';
select test.eq('a Stripe payment stays Stripe''s', (select p.provider from payments p join payment_processor_details d on d.payment_id = p.id where d.processor_payment_id = 'pi_xhstripe01'), 'stripe');
select test.ok('the history is backfilled: no card payment with processor details lacks its provider',
  not exists (select 1 from payments p join payment_processor_details d on d.payment_id = p.id where d.processor in ('stripe', 'helcim') and p.provider is null));
select test.eq('known: the transaction, its payment and booking', public.server_helcim_known(array[25000002, 99]::bigint[]) #>> '{25000002,booking_number}', 'XH-2');

-- ================================================================ 4. an untied Helcim payment links like Stripe's
select test.eq('an hc_ id is planned', public.server_stripe_untied_plan(test.id('booking:XH-1'), 22600, 'cad', 'hc_xhuntied01', null) ->> 'as', 'rental');
select test.eq('another id is still refused', public.server_stripe_untied_plan(test.id('booking:XH-1'), 22600, 'cad', 'zz_xhuntied01', null) ->> 'ok', 'false');

-- ================================================================ 5. the connector
select app.api_key_create(test.id('xh_admin'), test.id('xh_admin'), 'xh key', array['admin:read', 'admin:write'], encode(sha256('xh-key-r50'::bytea), 'hex'), 'cc_live_xh_');
create function test.xh_call(p_tool text, p jsonb) returns jsonb language sql as $$ select app.api_call(encode(sha256('xh-key-r50'::bytea), 'hex'), p_tool, p) $$;
select test.eq('a bad key is refused', app.api_call(repeat('0', 64), 'helcim_account', '{}'::jsonb) ->> 'status', '401');
select test.eq('helcim_account runs in the web layer', test.xh_call('helcim_account', '{}') #>> '{result,run}', 'helcim_account');
select test.eq('helcim_find_payments: the window', test.xh_call('helcim_find_payments', '{"hours": 48, "amount_cents": 22600}') #>> '{result,run}', 'helcim_find');
select test.eq('helcim_find_payments: 30 days at most', test.xh_call('helcim_find_payments', jsonb_build_object('from', now() - interval '40 days', 'to', now())) ->> 'error', 'The window is 30 days at most');
select test.eq('helcim_record_paid: the transaction id is digits', test.xh_call('helcim_record_paid', '{"booking": "XH-1", "transaction_id": "pi_1"}') ->> 'error',
  'transaction_id: the Helcim transaction id (digits) that helcim_find_payments lists');
create temp table xh_pv as select test.xh_call('helcim_record_paid', '{"booking": "XH-1", "transaction_id": "25009999"}') -> 'result' as r;
select test.eq('helcim_record_paid: previewed first, nothing changed', (select (r ->> 'run') || '/' || (r ->> 'booking_number') from xh_pv), 'helcim_record_preview/XH-1');
select test.eq('confirmed with its preview: run in the web layer as the key''s Admin',
  test.xh_call('helcim_record_paid', jsonb_build_object('booking', 'XH-1', 'transaction_id', '25009999', 'confirm', true, 'preview_id', (select r ->> 'preview_id' from xh_pv))) #>> '{result,params,transaction_id}', '25009999');
select test.eq('a transaction already recorded is refused', test.xh_call('helcim_record_paid', '{"booking": "XH-2", "transaction_id": "25000002"}') ->> 'error', 'Helcim transaction 25000002 is already recorded');
select test.eq('the other tools still go through', test.xh_call('stripe_account', '{}') #>> '{result,run}', 'stripe_account');
