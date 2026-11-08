-- 99: release 34 part O (migration 0810, docs/changes/2026-11-08-r34-book-now-connector.md): Book it now from Claude's connector
-- (create_offer and send_offer take book_now; book_offer_now books an offer already out; every write is previewed, then confirmed),
-- the same door action for the assistant, and the chain of a request replaced by a newer one (booking_chain).
-- Fixtures start with "rx"; every address is example.test.
select test.suite('99 r34o book now connector');
update program_settings set api_access_enabled = true where id is not null;

select test.mk_user('rxo_admin', 'admin');
select test.mk_user('rxo_cs', 'va', 'cs');
select test.mk_user('rxo_fin', 'va', 'finance');
select test.mk_user('rxo_plain', 'owner');
select test.mk_owner('rxo_o');
select test.mk_vehicle('RXOV', 'rxo_o');
select test.mk_renter('rxo_r');
do $$
begin
  insert into test.rq_ids select 'rxcar', (app.vehicle_add(test.id('rxo_admin'), jsonb_build_object('supply_type', 'company', 'vin', '1XFCXMM0000009891',
    'plate', 'RX891', 'year', 2024, 'make', 'Kia', 'model', 'K5', 'rates', jsonb_build_object('daily', 10000, 'weekend', 10000, 'weekly', 70000, 'monthly', 300000, 'deposit', 30000))) ->> 'vehicle_id')::uuid;
end $$;
create function test.rxo_h(p text) returns text language sql as $$ select encode(sha256(convert_to(p, 'UTF8')), 'hex') $$;
select app.api_key_create(test.id('rxo_admin'), test.id('rxo_admin'), 'Claude', array['bookings:read', 'admin:read', 'admin:write'], test.rxo_h('cc_live_rx_full'), 'cc_live_rx__');
select app.api_key_create(test.id('rxo_admin'), test.id('rxo_admin'), 'Read only', array['bookings:read'], test.rxo_h('cc_live_rx_ro'), 'cc_live_rxr_');
create function test.rxo_args(p_email text, p_from interval, p_extra jsonb default '{}'::jsonb) returns jsonb language sql as $$
  select jsonb_build_object('vehicle_id', test.b('rxcar'),
    'pickup_at', date_trunc('hour', now()) + p_from, 'return_at', date_trunc('hour', now()) + p_from + interval '3 days',
    'renter', jsonb_build_object('full_name', 'Rex Book', 'email', p_email, 'mobile', '(289) 555-0' || (800 + extract(day from p_from)::int), 'date_of_birth', '1990-05-06'),
    'coverage_option', 1, 'sales_choice', 'sourced', 'channels', jsonb_build_object('email', true, 'text', false), 'notify', true) || p_extra $$;
create function test.rxo_call(p_tool text, p jsonb) returns jsonb language sql as $$ select app.api_call(test.rxo_h('cc_live_rx_full'), p_tool, p) $$;

-- ================================================================ 1. the connector: an offer made and booked now (preview, then confirm)
create temp table rxo_p1 as select test.rxo_call('create_offer', test.rxo_args('rex.one@example.test', interval '6 days', '{"book_now": true, "book_now_reason": "The renter agreed by phone"}')) r;
select test.ok('create_offer: the preview is a preview (it is not refused)', (select (r -> 'result' ->> 'preview')::boolean from rxo_p1), (select r::text from rxo_p1));
select test.eq('create_offer: the preview says the offer would be booked now (approved by the Admin)', (select r #>> '{result,would_return,book_now,status}' from rxo_p1), 'approved');
select test.eq('create_offer: the preview changes nothing', (select count(*) from bookings b join users u on u.id = b.renter_id where u.email = 'rex.one@example.test'), 0::bigint);
select test.eq('create_offer: confirm without a preview is refused', test.rxo_call('create_offer', test.rxo_args('rex.one@example.test', interval '6 days', '{"book_now": true, "book_now_reason": "The renter agreed by phone", "confirm": true}')) ->> 'error',
  'Preview first: call without confirm, then confirm with its preview_id');
create temp table rxo_c1 as select test.rxo_call('create_offer', test.rxo_args('rex.one@example.test', interval '6 days',
  jsonb_build_object('book_now', true, 'book_now_reason', 'The renter agreed by phone', 'confirm', true, 'preview_id', (select r #>> '{result,preview_id}' from rxo_p1)))) r;
select test.eq('create_offer: confirmed, the booking waits for payment as an approved offer; the history says it was booked now',
  (select r #>> '{result,result,book_now,status}' from rxo_c1) || '/' || (select b.status::text || ':' || (b.offer_approved_version = b.current_offer_version) from bookings b where b.id = (select (r #>> '{result,result,booking_id}')::uuid from rxo_c1))
  || '/' || (select count(*) from booking_events where booking_id = (select (r #>> '{result,result,booking_id}')::uuid from rxo_c1) and kind = 'offer_booked_now'),
  'approved/pending_payment:true/1');
select test.ok('create_offer: the renter''s user comes back, for the agreement the web layer makes', (select r #>> '{result,result,book_now,renter_user_id}' from rxo_c1) is not null);

-- ================================================================ 2. the connector: book an offer that is already out
create temp table rxo_o2 as select public.door(test.id('rxo_cs'), 'aal2', 'ops_do', 'offer_create', test.rxo_args('rex.two@example.test', interval '20 days')) r;
select test.eq('an offer sent without the flag is offered', (select status::text from bookings where id = (select (r ->> 'booking_id')::uuid from rxo_o2)), 'offered');
create temp table rxo_p2 as select test.rxo_call('book_offer_now', jsonb_build_object('booking', (select r ->> 'booking_number' from rxo_o2), 'reason', 'The renter agreed by phone')) r;
select test.eq('book_offer_now: the preview shows the booking going to waiting for payment', (select r #>> '{result,will_change,status,after}' from rxo_p2), 'pending_payment');
select test.eq('book_offer_now: the preview changes nothing', (select status::text from bookings where id = (select (r ->> 'booking_id')::uuid from rxo_o2)), 'offered');
create temp table rxo_c2 as select test.rxo_call('book_offer_now', jsonb_build_object('booking', (select r ->> 'booking_number' from rxo_o2), 'reason', 'The renter agreed by phone',
  'confirm', true, 'preview_id', (select r #>> '{result,preview_id}' from rxo_p2))) r;
select test.eq('book_offer_now: confirmed, approved at once by the Admin',
  (select r #>> '{result,result,status}' from rxo_c2) || '/' || (select status::text from bookings where id = (select (r ->> 'booking_id')::uuid from rxo_o2)), 'approved/pending_payment');
select test.ok('book_offer_now: the booking id and the renter''s user come back for the agreement',
  (select r #>> '{result,result,booking_id}' from rxo_c2) is not null and (select r #>> '{result,result,renter_user_id}' from rxo_c2) is not null, (select r::text from rxo_c2));
select test.ok('book_offer_now: a second try is refused (no open offer)', (test.rxo_call('book_offer_now', jsonb_build_object('booking', (select r ->> 'booking_number' from rxo_o2))) ->> 'error') like 'It would be refused: Booking % is pending payment%');
select test.ok('book_offer_now: an unknown booking is refused', (test.rxo_call('book_offer_now', '{"booking": "ZZ-0"}') ->> 'error') like '%not found%');
select test.eq('book_offer_now: a key without admin:write cannot', (select app.api_call(test.rxo_h('cc_live_rx_ro'), 'book_offer_now', '{"booking": "X"}') ->> 'status'), '403');

-- ================================================================ 3. the assistant and staff: the same door action; staff wait for an Admin
create temp table rxo_o3 as select public.door(test.id('rxo_cs'), 'aal2', 'ops_do', 'offer_create', test.rxo_args('rex.three@example.test', interval '40 days')) r;
create temp table rxo_s3 as select public.door(test.id('rxo_cs'), 'aal2', 'ops_do', 'offer_book_now', jsonb_build_object('booking', (select r ->> 'booking_number' from rxo_o3), 'reason', 'The customer agreed on the phone')) r;
select test.eq('staff: booking an offer now is a request; the booking stays offered; a To do for an Admin',
  (select r ->> 'status' from rxo_s3) || '/' || (select status::text from bookings where id = (select (r ->> 'booking_id')::uuid from rxo_o3))
  || '/' || (select count(*) from tasks where task_type = 'override_approve' and booking_id = (select (r ->> 'booking_id')::uuid from rxo_o3) and status = 'open'), 'requested/offered/1');
select test.eq('the assistant''s tool maps to the door for Admin and staff, and not for the field',
  app.assistant_action_door('book_offer_now', 'admin', 'offer_book_now') || '/' || app.assistant_action_door('book_offer_now', 'va', 'offer_book_now') || '/' || coalesce(app.assistant_action_door('book_offer_now', 'field', 'offer_book_now'), '-'), 'ops_do/ops_do/-');
select test.throws('Finance does not book offers', format($$select public.door(%L, 'aal2', 'ops_do', 'offer_book_now', %L)$$, test.id('rxo_fin'), jsonb_build_object('booking', (select r ->> 'booking_number' from rxo_o3))), 'books an offer');
create temp table rxo_a3 as select public.door(test.id('rxo_admin'), 'aal2', 'ops_do', 'override_decide', jsonb_build_object('id', (select r ->> 'id' from rxo_s3), 'decision', 'approve')) r;
select test.eq('the Admin''s one-tap approval books it', (select r ->> 'status' from rxo_a3) || '/' || (select status::text from bookings where id = (select (r ->> 'booking_id')::uuid from rxo_o3)), 'approved/pending_payment');

-- ================================================================ 4. the chain of a replaced request
select test.mk_booking('RXO-1', 'RXOV', 'rxo_r', to_char((now() + interval '60 days') at time zone 'America/Toronto', 'YYYY-MM-DD 10:00'), to_char((now() + interval '62 days') at time zone 'America/Toronto', 'YYYY-MM-DD 10:00'), 'confirmed', 30000);
select test.mk_booking('RXO-2', 'RXOV', 'rxo_r', to_char((now() + interval '60 days') at time zone 'America/Toronto', 'YYYY-MM-DD 10:00'), to_char((now() + interval '62 days') at time zone 'America/Toronto', 'YYYY-MM-DD 10:00'), 'expired', 30000);
update bookings set superseded_by = test.id('booking:RXO-1') where booking_number = 'RXO-2';
select test.eq('the old booking says it was replaced by the new one',
  (select (v #>> '{replaced_by,number}') || '/' || jsonb_array_length(v -> 'replaces') from (select public.door(test.id('rxo_admin'), 'aal2', 'ops_read', 'booking_chain', jsonb_build_object('booking', test.id('booking:RXO-2'))) v) x), 'RXO-1/0');
select test.eq('the new booking says what it replaces (customer service reads it too, by number)',
  (select coalesce(v #>> '{replaced_by,number}', '-') || '/' || (v #>> '{replaces,0,number}') from (select public.door(test.id('rxo_cs'), 'aal2', 'ops_read', 'booking_chain', jsonb_build_object('booking', 'RXO-1')) v) x), '-/RXO-2');
select test.eq('a booking that replaced nothing has an empty chain', (select (v -> 'replaced_by')::text || '/' || jsonb_array_length(v -> 'replaces') from (select public.door(test.id('rxo_admin'), 'aal2', 'ops_read', 'booking_chain', jsonb_build_object('booking', (select r ->> 'booking_number' from rxo_o3))) v) x), 'null/0');
select test.throws('only staff read the chain', format($$select public.door(%L, 'aal2', 'ops_read', 'booking_chain', %L)$$, test.id('rxo_plain'), jsonb_build_object('booking', 'RXO-1')), '');

-- ================================================================ 5. self-service profile (0812)
select test.mk_user('rxo_sp', 'va', 'cs');
select test.mk_renter('rxo_rn');
create function test.rxo_d(p_user text, p_call text, p_name text, p jsonb default '{}'::jsonb) returns jsonb language sql as $$ select public.door(test.id(p_user), 'aal2', p_call, p_name, p) $$;
select test.eq('display name: saved at once and trimmed', test.rxo_d('rxo_sp', 'ops_do', 'display_name_save', '{"display_name": "  Sam S.  "}') ->> 'display_name', 'Sam S.');
select test.eq('display name: the profile read has it; the legal name is untouched', (select (v ->> 'display_name') || '/' || (v ->> 'legal_name') from (select test.rxo_d('rxo_sp', 'ops_read', 'self_profile') v) x), 'Sam S./Rxo Sp');
select test.throws('legal name: needs a reason', $$select test.rxo_d('rxo_sp', 'ops_do', 'name_change_request', '{"requested_name": "Samira Sp"}')$$, 'Say why');
select test.throws('legal name: the same name is refused', $$select test.rxo_d('rxo_sp', 'ops_do', 'name_change_request', '{"requested_name": "rxo sp", "reason": "no change at all"}')$$, 'already your name');
create temp table rxo_n1 as select test.rxo_d('rxo_sp', 'ops_do', 'name_change_request', '{"requested_name": "Samira Sp", "reason": "Legal name change"}') r;
select test.eq('legal name: a request waits and the name is unchanged', (select (r ->> 'status') from rxo_n1) || '/' || (select full_name from users where id = test.id('rxo_sp')), 'requested/Rxo Sp');
select test.eq('legal name: an Admin task is raised', (select count(*) from tasks where task_type = 'name_change_approve' and related_id = (select (r ->> 'id')::uuid from rxo_n1) and status = 'open'), 1::bigint);
select test.throws('legal name: the person cannot approve their own', format($$select test.rxo_d('rxo_sp', 'ops_do', 'name_change_decide', %L)$$, jsonb_build_object('id', (select r ->> 'id' from rxo_n1))), 'An Admin approves');
select test.eq('legal name: the Admin sees it on the person''s list', jsonb_array_length(test.rxo_d('rxo_admin', 'ops_read', 'name_change_pending', jsonb_build_object('user_id', test.id('rxo_sp')))), 1);
select test.throws('legal name: only an Admin lists them', $$select test.rxo_d('rxo_sp', 'ops_read', 'name_change_pending')$$, 'Admin only');
create temp table rxo_d1 as select test.rxo_d('rxo_admin', 'ops_do', 'name_change_decide', jsonb_build_object('id', (select r ->> 'id' from rxo_n1), 'decision', 'approve')) r;
select test.eq('legal name: approved changes the account name and closes the task',
  (select r ->> 'status' from rxo_d1) || '/' || (select full_name from users where id = test.id('rxo_sp')) || '/' || (select status from tasks where task_type = 'name_change_approve' and related_id = (select (r ->> 'id')::uuid from rxo_n1)), 'approved/Samira Sp/done');
create temp table rxo_n2 as select public.door(test.id('rxo_rn'), 'aal2', 'ops_do', 'name_change_request', '{"requested_name": "Renata Renter", "reason": "Married in June"}') r;
create temp table rxo_d2 as select test.rxo_d('rxo_admin', 'ops_do', 'name_change_decide', jsonb_build_object('id', (select r ->> 'id' from rxo_n2), 'decision', 'approve')) r;
select test.ok('renter: the request is made too; approval changes the renter record',
  (select r ->> 'status' from rxo_d2) = 'approved' and (select legal_name from renters where user_id = test.id('rxo_rn')) = 'Renata Renter');
select test.eq('renter: the Admin finds it by the renter record too', jsonb_array_length(test.rxo_d('rxo_admin', 'ops_read', 'name_change_pending', jsonb_build_object('renter_id', (select id from renters where user_id = test.id('rxo_rn'))))), 0);

-- ================================================================ 6. the incident card (0813)
select test.mk_user('rxo_fleet', 'va', 'fleet');
select test.throws('incident cards: customer service is refused', $$select test.rxo_d('rxo_cs', 'ops_read', 'incident_cards')$$, 'Admin or Fleet');
select test.eq('incident cards: with no policy the card has none', (test.rxo_d('rxo_fleet', 'ops_read', 'incident_cards') -> 'policy')::text, 'null');
select test.ok('incident cards: Fleet lists the cars with plate and VIN', (select count(*) from jsonb_array_elements(test.rxo_d('rxo_fleet', 'ops_read', 'incident_cards') -> 'cars') c where c ->> 'plate' = 'RX891' and c ->> 'vin' is not null) = 1);
select test.throws('policy: only an Admin saves it', $$select test.rxo_d('rxo_fleet', 'ops_do', 'fleet_policy_save', '{"insurer_name": "Example Mutual", "policy_number": "P-1", "effective_on": "2026-01-01", "expires_on": "2027-01-01"}')$$, 'Admin');
select test.throws('policy: a premium is refused, never stored', $$select test.rxo_d('rxo_admin', 'ops_do', 'fleet_policy_save', '{"insurer_name": "Example Mutual", "policy_number": "P-1", "effective_on": "2026-01-01", "expires_on": "2027-01-01", "premium_cents": 100}')$$, 'never shows a premium');
select test.throws('policy: the dates must run forward', $$select test.rxo_d('rxo_admin', 'ops_do', 'fleet_policy_save', '{"insurer_name": "Example Mutual", "policy_number": "P-1", "effective_on": "2027-01-01", "expires_on": "2026-01-01"}')$$, '');
select test.rxo_d('rxo_admin', 'ops_do', 'fleet_policy_save', '{"insurer_name": "Example Mutual", "policy_number": "P-100", "effective_on": "2026-01-01", "expires_on": "2099-01-01", "roadside_phone": "1-800-555-0100"}');
create temp table rxo_cards as select test.rxo_d('rxo_fleet', 'ops_read', 'incident_cards', jsonb_build_object('vehicle_id', test.id('vehicle:RXOV'))) r;
select test.eq('incident cards: one car, the policy, the named insured (the company), the roadside number',
  (select jsonb_array_length(r -> 'cars') || '/' || (r #>> '{policy,policy_number}') || '/' || (r #>> '{policy,named_insured}') || '/' || (r #>> '{company,roadside_phone}') from rxo_cards), '1/P-100/18122211 Canada Inc./1-800-555-0100');
select test.ok('incident cards: no amount anywhere on it', (select r::text !~* 'premium|cents|deductible' from rxo_cards));
select test.rxo_d('rxo_admin', 'ops_do', 'fleet_policy_save', '{"insurer_name": "Example Mutual", "policy_number": "P-200", "effective_on": "2026-06-01", "expires_on": "2099-06-01"}');
select test.eq('policy: a new policy number replaces the current one; the old row is kept', (select count(*) filter (where is_current) || '/' || count(*) from fleet_insurance_policies), '1/2');

-- ================================================================ 7. a signal that alerts on its own (0814)
update visitor_signal_config set notify_hot = false;
select test.eq('signal alert: same_car_return is on by default, other signals are not', (select alert_on_own::text from visitor_signal_rules where code = 'same_car_return') || '/' || (select count(*) from visitor_signal_rules where alert_on_own)::text, 'true/1');
insert into visitor_sessions (id, visitor_id, consent, known_name, city, score) values
  (test.id('rxo_s1'), test.id('rxo_v1'), 'analytics', 'Wren Return', 'Toronto', 20), (test.id('rxo_s2'), test.id('rxo_v2'), 'essential', null, 'Toronto', 20),
  (test.id('rxo_s3'), test.id('rxo_v3'), 'analytics', 'Pia Price', 'Toronto', 20);
insert into visitor_live_signals (session_id, kind, visitor_id, why) values
  (test.id('rxo_s1'), 'same_car_return', test.id('rxo_v1'), 'Looked at the Kia K5 on an earlier day'),
  (test.id('rxo_s2'), 'same_car_return', test.id('rxo_v2'), 'Looked at the Kia K5 on an earlier day'),
  (test.id('rxo_s3'), 'price_seen', test.id('rxo_v3'), 'Saw $240');
select test.eq('signal alert: one alert for the visitor who came back, with the reason',
  (select count(*) from app_events where payload ->> 'rule' = 'visitor_signal' and entity_id = test.id('rxo_v1'))::text || '/' || (select payload ->> 'alert_title' from app_events where payload ->> 'rule' = 'visitor_signal' and entity_id = test.id('rxo_v1')), '1/Came back for the same car: Wren Return');
select test.eq('signal alert: none without analytics consent, none for a signal that does not alert on its own', (select count(*) from app_events where payload ->> 'rule' = 'visitor_signal' and entity_id in (test.id('rxo_v2'), test.id('rxo_v3'))), 0::bigint);
update visitor_live_signals set active = false where session_id = test.id('rxo_s1');
update visitor_live_signals set active = true where session_id = test.id('rxo_s1');
select test.eq('signal alert: coming on again the same day alerts once', (select count(*) from app_events where payload ->> 'rule' = 'visitor_signal' and entity_id = test.id('rxo_v1')), 1::bigint);
update visitor_signal_rules set alert_on_own = false where code = 'same_car_return';
insert into visitor_sessions (id, visitor_id, consent, known_name, score) values (test.id('rxo_s4'), test.id('rxo_v4'), 'analytics', 'Off Switch', 20);
insert into visitor_live_signals (session_id, kind, visitor_id, why) values (test.id('rxo_s4'), 'same_car_return', test.id('rxo_v4'), 'x');
select test.eq('signal alert: the Admin''s switch off stops it', (select count(*) from app_events where payload ->> 'rule' = 'visitor_signal' and entity_id = test.id('rxo_v4')), 0::bigint);
select test.eq('signal alert: the Admin saves the switch through the door', test.rxo_d('rxo_admin', 'ops_do', 'live_signal_alert_save', '{"code": "same_car_return", "alert_on_own": true}') ->> 'ok', 'true');
select test.throws('signal alert: staff cannot change it', $$select test.rxo_d('rxo_cs', 'ops_do', 'live_signal_alert_save', '{"code": "same_car_return", "alert_on_own": false}')$$, '');
