-- Hotfix 3650: booking and paying with no card processor. Fixtures "nc"; example.test only. One switch (Program settings
-- card_payments, and the processor's own state, alerted once), the renter pays by e-Transfer with the screenshot and
-- Finance confirms it, the deposit becomes an e-Transfer deposit, nothing waits on a card, staff card calls are refused.
select test.suite('99 hotfix card off');

select test.mk_user('cof_admin', 'admin');
select test.mk_user('cof_admin2', 'admin');
select test.mk_user('cof_fin', 'va', 'finance');
select test.mk_user('cof_sales', 'va', 'sales');
update staff_profiles set single_limit_cents = 100000000 where user_id = test.id('cof_fin');

create table test.cof (k text primary key, v jsonb);
grant select on test.cof to authenticated, service_role;
create function test.cofv(p text) returns jsonb language sql stable as $$ select v from test.cof where k = p $$;
create function test.cofb(p text) returns bookings language sql stable security definer as $$
  select * from public.bookings where id = coalesce((test.cofv(p) ->> 'booking_id')::uuid, (test.cofv(p) ->> 'id')::uuid) $$;
create function test.cofu(p text) returns uuid language sql stable security definer as $$
  select r.user_id from public.renters r where r.id = (test.cofb(p)).renter_id $$;
create function test.cof_proof(p text) returns jsonb language sql as $$
  select jsonb_build_object('path', 'etransfer/' || (test.cofb(p)).id || '/' || gen_random_uuid() || '.png', 'sha256', repeat('b', 64), 'mime', 'image/png') $$;
create function test.cof_renter_report(p_key text, p_amount bigint, p_covers text) returns jsonb language sql as $$
  select public.server_renter_etransfer_report(test.cofu(p_key), jsonb_build_object('booking', (test.cofb(p_key)).booking_number,
    'amount_cents', p_amount, 'covers', p_covers, 'sender_name', 'Nora Card', 'proof', test.cof_proof(p_key))) $$;
create function test.cof_state(p_key text) returns jsonb language sql as $$
  select public.server_renter_etransfer_state((test.cofb(p_key)).id, test.cofu(p_key)) $$;

do $$
begin
  insert into test.cof select 'car1', app.vehicle_add(test.id('cof_admin'), jsonb_build_object('supply_type', 'company', 'vin', '1XFCXCF0000000001',
    'plate', 'CFO001', 'year', 2024, 'make', 'Kia', 'model', 'K5', 'rates', jsonb_build_object('daily', 10000, 'weekend', 10000, 'weekly', 70000, 'monthly', 300000, 'deposit', 30000)));
end $$;
-- an offer paid by card (the default), approved by the renter: waiting for payment, no card saved
create function test.cof_offer(p_key text, p_email text, p_from interval) returns void language plpgsql as $$
declare v_driver uuid; k text;
begin
  insert into test.cof select p_key, app.door(test.id('cof_admin'), 'aal2', 'ops_do', 'offer_create', jsonb_build_object(
    'vehicle_id', (test.cofv('car1') ->> 'vehicle_id')::uuid, 'pickup_at', date_trunc('hour', now()) + p_from, 'return_at', date_trunc('hour', now()) + p_from + interval '3 days',
    'renter', jsonb_build_object('full_name', 'Nora Card', 'email', p_email, 'mobile', '(289) 555-08' || (10 + length(p_key))::text, 'date_of_birth', (now() - interval '30 years')::date),
    'coverage_option', 1, 'channels', jsonb_build_object('email', false, 'text', false)));
  v_driver := (select bd.driver_id from booking_drivers bd where bd.booking_id = (test.cofb(p_key)).id and bd.role = 'renter');
  foreach k in array array['licence_front', 'licence_back', 'selfie'] loop
    perform app.register_verification_upload((test.cofb(p_key)).id, test.cofu(p_key), k, v_driver, 'renters/cof/' || p_key || '-' || k || '-' || gen_random_uuid() || '.jpg', repeat('e', 64), 'image/jpeg', null, 'identity');
  end loop;
  perform public.renter_save_details(test.cofu(p_key), jsonb_build_object('licence_number', 'N1234-12345-12345', 'licence_issuer', 'ON', 'licence_class', 'G',
    'licence_expiry', (now() + interval '3 years')::date), (test.cofb(p_key)).id);
  perform public.renter_approve_offer((test.cofb(p_key)).id, (test.cofb(p_key)).current_offer_version, test.cofu(p_key));
end $$;

-- ================================================================ 1. the switch: on by default, off by the setting
select test.eq('card_payments is on and the provider stripe by default',
  (select column_default from information_schema.columns where table_name = 'program_settings' and column_name = 'card_payments') || '/'
  || (select column_default from information_schema.columns where table_name = 'program_settings' and column_name = 'card_provider'), 'true/''stripe''::text');
select test.throws('the provider is stripe or helcim', $$update program_settings set card_provider = 'square'$$, 'card_provider');
select test.eq('with the processor taking charges, card payments are on (stripe)',
  (select (s ->> 'on') || '/' || (s ->> 'provider') from (select app.card_payments_state() s) x), 'true/stripe');
update program_settings set card_payments = false;
select test.eq('the setting off: provider off, reason setting', (select (s ->> 'on') || '/' || (s ->> 'provider') || '/' || (s ->> 'reason') from (select app.card_payments_state() s) x), 'false/off/setting');
update program_settings set card_payments = true, card_provider = 'helcim';
select test.eq('helcim slots in as the provider (the seam)', app.card_payments_state() ->> 'provider', 'helcim');
update program_settings set card_provider = 'stripe';
select test.ok('the state names the e-Transfer email renters send to', coalesce(app.card_payments_state() ->> 'e_transfer_email', '') like '%@%');

-- ================================================================ 2. the processor: charges disabled turns cards off, alerted once
insert into test.cof select 'p1', public.server_card_processor_report('stripe', false, false, 'rejected.other');
select test.eq('Stripe charges_enabled false: off, reason processor, alerted', (test.cofv('p1') ->> 'on') || '/' || (test.cofv('p1') ->> 'reason') || '/' || (test.cofv('p1') ->> 'alerted'), 'false/processor/true');
select test.eq('the Admins have one notice and one urgent To do',
  (select count(*) from app_events where code = 'admin_card_payments_paused')::text || '/' || (select count(*) || ':' || max(priority) from tasks where task_type = 'card_payments_paused' and status = 'open'), '1/1:urgent');
insert into test.cof select 'p2', public.server_card_processor_report('stripe', false, false, 'rejected.other');
select test.eq('a second report of the same pause alerts no one again',
  (test.cofv('p2') ->> 'alerted') || '/' || (select count(*) from app_events where code = 'admin_card_payments_paused')::text, 'false/1');
select test.ok('the processor check is not due again within 10 minutes', not public.server_card_processor_due('stripe'));
select test.ok('the notice goes to the Admins',
  (select bool_and(x.audience = 'staff_admin') and count(*) >= 2 from app_events e, app.notification_recipients(e, (select c from notification_catalogue c where c.code = 'admin_card_payments_paused')) x
    where e.code = 'admin_card_payments_paused'));

-- ================================================================ 3. staff card calls are refused with the reason; Money carries the state
select test.cof_offer('b1', 'nora.card1@example.test', interval '6 days');
select test.cof_offer('b2', 'nora.card2@example.test', interval '20 days');
select test.eq('both wait for payment, by card, no card saved', (test.cofb('b1')).status::text || '/' || (test.cofb('b1')).deposit_pay_method || '/' || coalesce((test.cofb('b1')).card_on_file_id::text, 'none'),
  'pending_payment/card/none');
select test.throws('Collect a card (a card link) is refused: paused', $$select app.door(test.id('cof_admin'), 'aal2', 'ops_do', 'payreq_create',
  jsonb_build_object('booking', (test.cofb('b1')).booking_number, 'kind', 'hold', 'channel', 'device', 'token_sha256', repeat('c', 64)))$$, 'Card payments are paused');
select test.throws('a hold on the saved card is refused: paused', $$select app.door(test.id('cof_admin'), 'aal2', 'ops_do', 'deposit_hold_saved_begin',
  jsonb_build_object('booking', (test.cofb('b1')).booking_number))$$, 'Card payments are paused');
select test.throws('charging a saved card is refused: paused', $$select app.door(test.id('cof_fin'), 'aal2', 'ops_do', 'card_charge_begin',
  jsonb_build_object('booking', (test.cofb('b1')).booking_number, 'reason', 'x'))$$, 'Card payments are paused');
select test.eq('Money tells staff cards are paused, with the email to send to',
  (select (m #>> '{card_payments,on}') || '/' || (m #>> '{card_payments,reason}') || '/' || ((m #>> '{card_payments,e_transfer_email}') like '%@%')::text
     from (select app.door(test.id('cof_sales'), 'aal2', 'ops_read', 'booking_money', jsonb_build_object('booking', (test.cofb('b1')).booking_number)) m) x), 'false/processor/true');

-- ================================================================ 4. the renter pays by e-Transfer and uploads the screenshot
insert into test.cof select 's1', test.cof_state('b1');
select test.eq('the renter sees the rental and the e-Transfer deposit to send, and may upload',
  (select (s ->> 'rental_cents' > '0')::text || '/' || (s ->> 'deposit_method') || '/' || (s ->> 'deposit_cents') || '/' || (s ->> 'may_report') || '/' || (s ->> 'booking_number' = (test.cofb('b1')).booking_number)::text
     from (select test.cofv('s1') s) x), 'true/e_transfer/' || app.deposit_for_method(test.cofb('b1'), 'e_transfer') || '/true/true');
select test.eq('another renter sees nothing of it', public.server_renter_etransfer_state((test.cofb('b1')).id, test.cofu('b2')), null::jsonb);
select test.throws('another renter cannot report on it', $$select public.server_renter_etransfer_report(test.cofu('b2'), jsonb_build_object('booking', (test.cofb('b1')).booking_number,
  'amount_cents', 100, 'covers', 'rental', 'proof', test.cof_proof('b1')))$$, 'Booking not found');
select test.throws('the screenshot is required', $$select public.server_renter_etransfer_report(test.cofu('b1'), jsonb_build_object('booking', (test.cofb('b1')).booking_number,
  'amount_cents', 100, 'covers', 'rental'))$$, 'screenshot');
select test.throws('a screenshot filed under another booking is refused', $$select public.server_renter_etransfer_report(test.cofu('b1'), jsonb_build_object('booking', (test.cofb('b1')).booking_number,
  'amount_cents', 100, 'covers', 'rental', 'proof', test.cof_proof('b2')))$$, 'screenshot');
insert into test.cof select 'r1', test.cof_renter_report('b1', (test.cofv('s1') ->> 'rental_cents')::bigint + (test.cofv('s1') ->> 'deposit_cents')::bigint, 'both');
select test.eq('the report is open; the deposit became an e-Transfer deposit',
  (select r.status from etransfer_reports r where r.id = (test.cofv('r1') ->> 'id')::uuid) || '/' || (test.cofb('b1')).deposit_pay_method, 'open/e_transfer');
select test.eq('Finance gets the Check e-Transfer To do; the alert names the renter',
  (select count(*) from tasks t where t.task_type = 'etransfer_check' and t.related_id = (test.cofv('r1') ->> 'id')::uuid and t.queue = 'finance')::text || '/'
  || (select max(payload ->> 'reporter_name') from app_events where code = 'staff_etransfer_reported' and payload ->> 'report_id' = test.cofv('r1') ->> 'id'), '1/Nora Card (the renter)');
select test.ok('the history says the renter sent it', exists (select 1 from booking_events where booking_id = (test.cofb('b1')).id and note like 'The renter sent an e-Transfer of %waiting for Finance%'));
select test.eq('the renter sees it waiting and cannot send a second one', (test.cof_state('b1') #>> '{open,report_number}') || '/' || (test.cof_state('b1') ->> 'may_report'),
  (select report_number from etransfer_reports where id = (test.cofv('r1') ->> 'id')::uuid) || '/false');
select test.eq('an unpaid hold never lapses while the report waits', app.unpaid_hold_until(test.cofb('b1')), null::timestamptz);
select test.throws('a second report is refused', $$select test.cof_renter_report('b1', 100, 'rental')$$, 'already with our team');

-- ================================================================ 5. Finance confirms in one tap: confirmed with no saved card
insert into test.cof select 'd1', app.door(test.id('cof_fin'), 'aal2', 'ops_do', 'etransfer_decide', jsonb_build_object('id', test.cofv('r1') ->> 'id', 'decision', 'confirm'));
select test.eq('confirmed: the booking with no card on file, the deposit taken by e-Transfer',
  (test.cofb('b1')).status::text || '/' || coalesce((select d.method || ':' || d.paid_method || ':' || d.status from deposits d where d.booking_id = (test.cofb('b1')).id), 'none'),
  'confirmed/offline:e_transfer:captured');
select test.eq('the renter is told it arrived', (select count(*) || '/' || max(payload ->> 'booking_status') from app_events where code = 'renter_etransfer_confirmed' and payload ->> 'report_id' = test.cofv('r1') ->> 'id'), '1/Confirmed');
select test.ok('the renter notice goes to the renter',
  (select bool_and(x.audience = 'renter' and x.user_id = test.cofu('b1')) from app_events e, app.notification_recipients(e, (select c from notification_catalogue c where c.code = 'renter_etransfer_confirmed')) x
    where e.code = 'renter_etransfer_confirmed' and e.payload ->> 'report_id' = test.cofv('r1') ->> 'id'));
select test.eq('nothing is left to send', (select (s ->> 'rental_cents') || '/' || (s ->> 'deposit_cents') || '/' || (s ->> 'may_report') from (select test.cof_state('b1') s) x), '0/0/false');

-- ================================================================ 6. Not received: the renter is told why and may send it again
insert into test.cof select 'r2', test.cof_renter_report('b2', 12345, 'rental');
select test.throws('the renter''s own Finance-free path: Sales cannot decide it', $$select app.door(test.id('cof_sales'), 'aal2', 'ops_do', 'etransfer_decide',
  jsonb_build_object('id', test.cofv('r2') ->> 'id', 'decision', 'confirm'))$$, 'Only Finance or an Admin');
select app.door(test.id('cof_fin'), 'aal2', 'ops_do', 'etransfer_decide', jsonb_build_object('id', test.cofv('r2') ->> 'id', 'decision', 'decline', 'reason', 'Nothing from Nora in the bank yet'));
select test.eq('the renter is told why, with the email to send to',
  (select max(payload ->> 'decline_reason') || '/' || (max(payload ->> 'e_transfer_email') like '%@%')::text from app_events where code = 'renter_etransfer_declined' and payload ->> 'report_id' = test.cofv('r2') ->> 'id'),
  'Nothing from Nora in the bank yet/true');
select test.eq('the renter sees the reason and may send it again', (test.cof_state('b2') #>> '{declined,reason}') || '/' || (test.cof_state('b2') ->> 'may_report'), 'Nothing from Nora in the bank yet/true');
select test.eq('b2 still waits for payment, nothing recorded', (test.cofb('b2')).status::text || '/' || (select count(*) from manual_payments where booking_id = (test.cofb('b2')).id)::text, 'pending_payment/0');

-- ================================================================ 7. the connector's get_settings carries the state
create function test.cof_h(p text) returns text language sql as $$ select encode(sha256(convert_to(p, 'UTF8')), 'hex') $$;
create temp table cof_ps as select id, api_access_enabled e, api_calls_per_minute n from program_settings;
update program_settings set api_access_enabled = true, api_calls_per_minute = 600 where id is not null;
select app.api_key_create(test.id('cof_admin'), test.id('cof_admin'), 'Laptop', array['admin:read', 'admin:write'], test.cof_h('cc_live_cof_full'), 'cc_live_cof_');
select test.eq('get_settings: card_payments in the program row and the state beside it',
  (select (v #>> '{result,program,card_payments}') || '/' || (v #>> '{result,card_payments,provider}') || '/' || (v #>> '{result,card_payments,reason}')
     from (select app.api_call(test.cof_h('cc_live_cof_full'), 'get_settings', '{}'::jsonb, 'test') v) x), 'true/off/processor');
update program_settings p set api_access_enabled = s.e, api_calls_per_minute = s.n from cof_ps s where s.id = p.id;

-- ================================================================ 8. cards back: the pause ends, a new pause alerts again
insert into test.cof select 'p3', public.server_card_processor_report('stripe', true, true, null);
select test.eq('Stripe takes charges again: on, the To do closed',
  (test.cofv('p3') ->> 'on') || '/' || (select count(*) from tasks where task_type = 'card_payments_paused' and status = 'open')::text, 'true/0');
create function test.cof_paused_refusal() returns boolean language plpgsql as $$
begin
  perform app.door(test.id('cof_admin'), 'aal2', 'ops_do', 'payreq_create', jsonb_build_object('booking', (test.cofb('b2')).booking_number, 'kind', 'setup', 'channel', 'device', 'token_sha256', repeat('d', 64)));
  return false;
exception when others then return sqlerrm like 'Card payments are paused%';
end $$;
select test.eq('cards back: the door no longer refuses a card link as paused', test.cof_paused_refusal(), false);
select public.server_card_processor_report('stripe', false, true, 'under_review');
select test.eq('a new pause alerts the Admins again', (select count(*) from app_events where code = 'admin_card_payments_paused'), 2::bigint);
select public.server_card_processor_report('stripe', true, true, null);

-- ================================================================ 9. the notices go through the pipeline; privileges
select app.process_events(100000);
select test.eq('every new email was built, with no variable missing',
  (select string_agg(c, ',' order by c) from unnest(array['admin_card_payments_paused', 'renter_etransfer_confirmed', 'renter_etransfer_declined']) c
    where not exists (select 1 from notification_outbox o where o.code = c and o.missing_variables = '{}')
      and not exists (select 1 from staff_digest_items d where d.code = c)), null::text);
select test.ok('the renter has the answer in the app', exists (select 1 from notifications n where n.user_id = test.cofu('b2') and n.code = 'renter_etransfer_declined'));
select test.eq('the browser roles cannot run the new functions or write the state',
  has_function_privilege('authenticated', 'public.server_renter_etransfer_report(uuid, jsonb)', 'execute')::text
  || '/' || has_function_privilege('anon', 'public.server_card_processor_report(text, boolean, boolean, text)', 'execute')::text
  || '/' || has_function_privilege('authenticated', 'app.card_off_prepare(uuid)', 'execute')::text
  || '/' || has_table_privilege('authenticated', 'card_processor_state', 'update')::text, 'false/false/false/false');
select test.eq('every function of 3650 runs with pg_temp last on its search_path',
  (select count(*) from pg_proc p join pg_namespace n on n.oid = p.pronamespace
    where ((n.nspname = 'app' and p.proname in ('card_payments_state', 'card_payments_on', 'card_paused_message', 'card_processor_report', 'card_off_prepare',
             'renter_etransfer_state', 'etransfer_report_renter', 'etransfer_decide', 'door', 'api_call'))
        or (n.nspname = 'public' and p.proname like 'server_card%') or (n.nspname = 'public' and p.proname like 'server_renter_etransfer%'))
      and not exists (select 1 from unnest(p.proconfig) c where c like 'search_path=%pg_temp')), 0::bigint);
