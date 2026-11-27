-- 99: r50 hotfix2 (migrations 5110 to 5115; docs/changes/2026-11-27-r50-hotfix2.md): card payments off with e-Transfer and
-- direct deposit from Program settings, an ended booking never blocks a car, the connector's set_setting, Instant booking
-- for a complete profile (never a sample car or an owner kept off it), confirm pay later and start a rental already out,
-- and the incident card while the renter has the car. Fixtures start with "h2f"; every address is example.test.
select test.suite('99 r50 hotfix2: pay offline, ended bookings, set_setting, instant booking, pay later');
create temp table h2f_ps as select id, api_access_enabled e, api_calls_per_minute n, instant_book_repeat_enabled i, card_payments c, e_transfer_email t, cc_pay_institution_number pi, cc_pay_transit_number pt, cc_pay_account_number pa from program_settings;
update program_settings set api_access_enabled = true, api_calls_per_minute = 600, instant_book_repeat_enabled = true where id is not null;
-- as in production: cards off, and the deposit account an Admin typed in Settings (made-up numbers)
update program_settings set card_payments = false, e_transfer_email = 'rent@carmacars.ca', cc_pay_institution_number = '999', cc_pay_transit_number = '99999', cc_pay_account_number = '9999999'
 where id = (app.settings()).id;
select test.mk_user('h2f_admin', 'admin');
select test.mk_user('h2f_fin', 'va', 'finance');
select test.mk_owner('h2f');
select test.mk_owner('h2f01');
update owners set legal_name = '01 Motors', corporation_name = '01 Motors Inc.' where id = test.id('owner:h2f01');
select test.mk_vehicle('H2FA', 'h2f');
select test.mk_vehicle('H2FB', 'h2f');
select test.mk_vehicle('H2FM', 'h2f01');
select test.mk_renter('h2f_r');
select test.mk_renter('h2f_r2');
update renters set address_line1 = '1 Example Street', city = 'Toronto', postal_code = 'M5V 1A1' where id = test.id('renter:h2f_r');
create function test.h2ft(p interval) returns text language sql stable as $$ select to_char((now() + p) at time zone 'America/Toronto', 'YYYY-MM-DD HH24:MI') $$;

-- ---------------------------------------------------------------- 1. card payments off, e-Transfer and direct deposit (5110)
select test.eq('card payments are off from the Program setting, e-Transfer to rent@', (select (x ->> 'on') || ':' || (x ->> 'reason') || ':' || (x ->> 'e_transfer_email') from (select app.card_payments_state() x) z),
  'false:setting:rent@carmacars.ca');
select test.eq('direct deposit comes from the settings', (select (x #>> '{direct_deposit,institution}') || '/' || (x #>> '{direct_deposit,transit}') || '/' || (x #>> '{direct_deposit,account}') from (select app.card_payments_state() x) z),
  '999/99999/9999999');

-- ---------------------------------------------------------------- 2. an ended booking never blocks the car (5111)
select test.mk_booking('H2F-OLD', 'H2FB', 'h2f_r2', test.h2ft(interval '-6 days'), test.h2ft(interval '-2 days'), 'confirmed');
select test.eq('pickup never recorded, return passed: the car is free tonight', app.vehicle_is_available(test.id('vehicle:H2FB'), now() + interval '2 hours', now() + interval '2 days'), true);
select test.mk_booking('H2F-NEW', 'H2FB', 'h2f_r', test.h2ft(interval '3 hours'), test.h2ft(interval '2 days'), 'offered');
select test.eq('the new offer lists the ended booking as a note that does not hold it', (select (x ->> 'holds') || ':' || (x ->> 'blocks')
  from jsonb_array_elements(app.booking_date_conflicts(test.id('booking:H2F-NEW'))) x where x ->> 'kind' = 'presumed_out'), 'false:false');
select test.mk_booking('H2F-RET', 'H2FB', 'h2f_r2', test.h2ft(interval '4 days'), test.h2ft(interval '6 days'), 'returned');
select test.eq('a returned booking does not block its dates', app.vehicle_is_available(test.id('vehicle:H2FB'), now() + interval '4 days', now() + interval '5 days'), true);

-- ---------------------------------------------------------------- 3. set_setting through the connector (5112)
create function test.h2f_h(p text) returns text language sql as $$ select encode(sha256(convert_to(p, 'UTF8')), 'hex') $$;
select app.api_key_create(test.id('h2f_admin'), test.id('h2f_admin'), 'Laptop', array['admin:read', 'admin:write'], test.h2f_h('cc_live_h2f_full'), 'cc_live_h2f');
select app.api_key_create(test.id('h2f_admin'), test.id('h2f_admin'), 'Read', array['admin:read'], test.h2f_h('cc_live_h2f_read'), 'cc_live_h2r');
insert into api_keys (user_id, kind, name, prefix, key_hash, scopes, created_by)
select test.id('h2f_fin'), kind, 'Not allowed', 'cc_live_h2n', test.h2f_h('cc_live_h2f_fin'), scopes, test.id('h2f_admin') from api_keys where key_hash = test.h2f_h('cc_live_h2f_full');
create function test.h2f_api(p_key text, a jsonb) returns jsonb language sql as $$ select app.api_call(test.h2f_h(p_key), 'set_setting', a, 'test') $$;
create temp table h2f_oe as select id, offer_expiry_hours h from program_settings where id = (app.settings()).id;
update program_settings set offer_expiry_hours = 24 where id = (app.settings()).id;
select test.eq('a read key cannot change a setting', test.h2f_api('cc_live_h2f_read', '{"key": "offer_expiry_hours", "value": 30}') ->> 'status', '403');
select test.eq('a key whose person is not an Admin is refused', test.h2f_api('cc_live_h2f_fin', '{"key": "offer_expiry_hours", "value": 30}') ->> 'ok', 'false');
select test.eq('a secret key is refused', test.h2f_api('cc_live_h2f_full', '{"key": "google_drive_api_key", "value": "x"}') ->> 'status', '403');
select test.eq('a bank detail is refused', test.h2f_api('cc_live_h2f_full', '{"key": "cc_pay_account_number", "value": "1234567"}') ->> 'status', '403');
-- review: the payment settings stay screen-only for an Admin, and a refused secret or payment key is logged without its value
select test.eq('e_transfer_email, card_payments and card_provider are screen-only', (select string_agg(test.h2f_api('cc_live_h2f_full', jsonb_build_object('key', k, 'value', 'x')) ->> 'status', ',' order by k)
  from unnest(array['card_payments', 'card_provider', 'e_transfer_email']) k), '403,403,403');
select test.eq('a refused secret is logged by its key only, never the value', (select args::text from api_calls where tool = 'set_setting' and not ok and target = 'cc_pay_account_number' order by id desc limit 1), '{"key": "cc_pay_account_number"}');
-- review: an allowlist: an ordinary setting the connector does not need is refused too
select test.eq('a setting off the allowlist is refused', test.h2f_api('cc_live_h2f_full', '{"key": "api_calls_per_minute", "value": 100}') ->> 'status', '403');
select test.eq('every allowlisted key is a real Program setting', (select count(*) from unnest(app.setting_connector_keys()) k where app.setting_table(k) is distinct from 'program_settings'), 0::bigint);
select test.eq('a value the Settings page refuses is refused (not a true or false)', test.h2f_api('cc_live_h2f_full', '{"key": "instant_book_repeat_enabled", "value": "maybe"}') ->> 'ok', 'false');
create temp table h2f_pv as select test.h2f_api('cc_live_h2f_full', '{"key": "offer_expiry_hours", "value": 30}') r;
select test.eq('the preview shows before and after and changes nothing', (select (r #>> '{result,before}') || '>' || (r #>> '{result,after}') || ':' || (app.settings()).offer_expiry_hours from h2f_pv), '24>30:24');
select test.eq('a confirm with other arguments is refused', test.h2f_api('cc_live_h2f_full', jsonb_build_object('key', 'offer_expiry_hours', 'value', 31, 'confirm', true, 'preview_id', (select r #>> '{result,preview_id}' from h2f_pv))) ->> 'ok', 'false');
create temp table h2f_pv2 as select test.h2f_api('cc_live_h2f_full', '{"key": "offer_expiry_hours", "value": 30}') r;
select test.eq('the confirm changes it', (test.h2f_api('cc_live_h2f_full', jsonb_build_object('key', 'offer_expiry_hours', 'value', 30, 'confirm', true, 'preview_id', (select r #>> '{result,preview_id}' from h2f_pv2))) #>> '{result,after}') || ':' || (app.settings()).offer_expiry_hours,
  '30:30');
select test.eq('the log keeps the before and the after', (select (before ->> 'offer_expiry_hours') || '>' || (after ->> 'offer_expiry_hours') from api_calls where tool = 'set_setting' and ok order by id desc limit 1), '24>30');
select test.eq('a used preview cannot be used again', test.h2f_api('cc_live_h2f_full', jsonb_build_object('key', 'offer_expiry_hours', 'value', 30, 'confirm', true, 'preview_id', (select r #>> '{result,preview_id}' from h2f_pv2))) ->> 'ok', 'false');

-- ---------------------------------------------------------------- 4. Instant booking for a complete profile (5113)
select test.eq('a complete profile, verified licence, no rental closed: eligible, whatever the tier', app.instant_book_check(test.id('renter:h2f_r')) ->> 'eligible', 'true');
select test.eq('no home address: not eligible, and the reason says so', app.instant_book_check(test.id('renter:h2f_r2')) ->> 'reason', 'The profile is not complete (name, date of birth, home address, mobile and email)');
-- review: the owner flag is the only rule; an Admin sets it under Admin > Owners, with the reason in the audit log
select test.throws('staff cannot turn instant booking off for an owner', $$select app.door(test.id('h2f_fin'), 'aal2', 'admin_do', 'owner_instant_book_set', jsonb_build_object('owner_id', test.id('owner:h2f01'), 'off', true, 'reason', 'Partner fleet'))$$, '%Admin%');
select test.eq('an Admin turns it off for 01 Motors', app.door(test.id('h2f_admin'), 'aal2', 'admin_do', 'owner_instant_book_set', jsonb_build_object('owner_id', test.id('owner:h2f01'), 'off', 'true', 'reason', 'Partner fleet: request only')) ->> 'instant_book_off', 'true');
select test.eq('...the Admin page reads it, and the audit log has the reason', (app.door(test.id('h2f_admin'), 'aal2', 'admin_read', 'owner_instant_book', jsonb_build_object('owner_id', test.id('owner:h2f01'))) ->> 'instant_book_off')
  || ':' || (select after ->> 'reason' from audit_log where action = 'owner_instant_book_set' and entity_id = test.id('owner:h2f01')::text order by id desc limit 1), 'true:Partner fleet: request only');
select test.eq('a car of the owner: ok; of 01 Motors: no', app.vehicle_instant_ok(test.id('vehicle:H2FA')) || ':' || app.vehicle_instant_ok(test.id('vehicle:H2FM')), 'true:false');
update vehicles set is_sample = true where id = test.id('vehicle:H2FB');
select test.eq('a sample car: no', app.vehicle_instant_ok(test.id('vehicle:H2FB')), false);
update vehicles set is_sample = false where id = test.id('vehicle:H2FB');
select test.mk_booking('H2F-REQ', 'H2FM', 'h2f_r', test.h2ft(interval '5 days'), test.h2ft(interval '7 days'), 'requested');
select test.eq('Book instantly on a 01 Motors car stays a request', public.server_instant_book('H2F-REQ', test.id('h2f_r')) ->> 'reason', 'This car is booked by request');
-- every instant path reads vehicle_instant_ok: Book instantly (3900 book_choice) and the fleet and booking form reads (2430 Book now)
select test.mk_booking('H2F-RQ2', 'H2FM', 'h2f_r', test.h2ft(interval '8 days'), test.h2ft(interval '9 days'), 'requested');
select test.eq('Book instantly (book_choice) on a 01 Motors car stays a request', (public.server_book_choice('H2F-RQ2', 'instant', test.id('h2f_r')) ->> 'instant') || ':' || (select status::text from bookings where booking_number = 'H2F-RQ2'), 'false:requested');
insert into vehicle_listings (vehicle_id, slug, headline, status, home_area) values (test.id('vehicle:H2FM'), 'h2f-01-motors', 'Partner car', 'published', 'Leslieville'), (test.id('vehicle:H2FA'), 'h2f-own-car', 'Own car', 'published', 'Leslieville');
select test.eq('the booking form: the 01 Motors car is not instant, the other owner''s car is', (select string_agg(coalesce(x ->> 'instant_book', 'absent'), ':' order by x ->> 'vehicle_id' = test.id('vehicle:H2FA')::text)
  from jsonb_array_elements(app.booking_cars()) x where x ->> 'vehicle_id' in (test.id('vehicle:H2FM')::text, test.id('vehicle:H2FA')::text)), 'false:true');
select test.eq('the Rewards tiers no longer list Instant Book', (select enabled from reward_tier_perks where code = 'instant_book'), false);

-- ---------------------------------------------------------------- 5. confirm pay later, start a rental already out (5114)
select test.mk_booking('H2F-PAY', 'H2FA', 'h2f_r', test.h2ft(interval '1 day'), test.h2ft(interval '4 days'), 'pending_payment');
select test.throws('staff cannot confirm pay later', $$select app.door(test.id('h2f_fin'), 'aal2', 'admin_do', 'booking_pay_later', jsonb_build_object('booking', test.id('booking:H2F-PAY'), 'reason', 'No processor, pays tonight'))$$, '%Only an Admin%');
select test.throws('a reason is needed', $$select app.door(test.id('h2f_admin'), 'aal2', 'admin_do', 'booking_pay_later', jsonb_build_object('booking', test.id('booking:H2F-PAY'), 'reason', 'later'))$$, '%10 characters%');
select test.eq('an Admin confirms it pay later', app.door(test.id('h2f_admin'), 'aal2', 'admin_do', 'booking_pay_later', jsonb_build_object('booking', test.id('booking:H2F-PAY'), 'reason', 'No processor, pays tonight')) ->> 'status', 'confirmed');
select test.eq('...recorded on the booking, with a Finance To do to collect', (select (b.pay_later_reason) || ':' || (select t.queue from tasks t where t.dedupe_key = 'collect_pay_later:' || b.id) from bookings b where b.id = test.id('booking:H2F-PAY')),
  'No processor, pays tonight:finance');
select test.mk_booking('H2F-OUT', 'H2FB', 'h2f_r2', test.h2ft(interval '5 hours'), test.h2ft(interval '5 days'), 'pending_payment');
select test.throws('a pickup time in the future is refused', $$select app.door(test.id('h2f_admin'), 'aal2', 'admin_do', 'booking_start_pay_later', jsonb_build_object('booking', test.id('booking:H2F-OUT'), 'reason', 'Car went out last night', 'at', now() + interval '2 hours'))$$, '%future%');
select test.lives('an Admin records the car already out: confirmed pay later and picked up', $$select app.door(test.id('h2f_admin'), 'aal2', 'admin_do', 'booking_start_pay_later', jsonb_build_object('booking', test.id('booking:H2F-OUT'), 'reason', 'Car went out last night', 'at', now() - interval '10 hours'))$$);
select test.eq('...on rent from the real time, pay later kept', (select status::text || ':' || (handed_over_at is not null) || ':' || (pay_later_at is not null) || ':' || (handed_over_at <= now() - interval '9 hours') from bookings where id = test.id('booking:H2F-OUT')),
  'on_rent:true:true:true');
select test.lives('an Admin sets the coverage of the started booking to the renter''s own insurance (OPCF 27)',
  $$select app.door(test.id('h2f_admin'), 'aal2', 'admin_do', 'protection_change', jsonb_build_object('booking', test.id('booking:H2F-OUT'), 'to', 1, 'reason', 'Renter has OPCF 27 on his policy', 'notify', false, 'override', true, 'override_reason', 'Proof asked for by upload'))$$);
select test.eq('...the booking now asks for the policy and the OPCF 27', (select coverage_option from bookings where id = test.id('booking:H2F-OUT')), 1::smallint);
-- review: a booking already confirmed (not through pay later) gets the same lock, calendar check, pay_later_at and To do
select test.mk_vehicle('H2FC', 'h2f');
select test.mk_booking('H2F-CNF', 'H2FC', 'h2f_r2', test.h2ft(interval '-2 hours'), test.h2ft(interval '2 days'), 'confirmed');
select test.lives('a confirmed booking whose car is already out starts pay later', $$select app.door(test.id('h2f_admin'), 'aal2', 'admin_do', 'booking_start_pay_later', jsonb_build_object('booking', 'H2F-CNF', 'reason', 'Car went out before payment', 'at', now() - interval '1 hour'))$$);
select test.eq('...pay_later_at set, and the Finance To do to collect', (select (b.pay_later_at is not null) || ':' || (select t.queue from tasks t where t.dedupe_key = 'collect_pay_later:' || b.id) from bookings b where b.booking_number = 'H2F-CNF'), 'true:finance');
select test.mk_booking('H2F-CL2', 'H2FB', 'h2f_r2', test.h2ft(interval '31 days'), test.h2ft(interval '32 days'), 'offered');
-- a clash the calendar trigger would refuse today (made with triggers off, as old data can be)
select test.mk_booking('H2F-CL1', 'H2FB', 'h2f_r', test.h2ft(interval '40 days'), test.h2ft(interval '43 days'), 'confirmed');
set session_replication_role = replica;
update bookings set pickup_at = now() + interval '30 days', return_at = now() + interval '33 days' where booking_number = 'H2F-CL1';
set session_replication_role = origin;
select test.throws('a car that is not free for the dates is refused', $$select app.door(test.id('h2f_admin'), 'aal2', 'admin_do', 'booking_start_pay_later', jsonb_build_object('booking', 'H2F-CL2', 'reason', 'Car went out before payment', 'at', now()))$$, '%not free%');
select test.eq('the incident card is there while the renter has the car', app.booking_in_progress((select b from bookings b where b.id = test.id('booking:H2F-OUT'))), true);

-- ---------------------------------------------------------------- 5b. the connector's writes for it (5115)
select test.eq('the four tools are door actions', (select string_agg(app.api_action(t) ->> 'name', ',' order by t) from unnest(array['add_rental', 'change_coverage', 'confirm_pay_later', 'start_rental_pay_later']) t),
  'manual_rental_create,protection_change,booking_pay_later,booking_start_pay_later');
select test.mk_booking('H2F-PL2', 'H2FA', 'h2f_r', test.h2ft(interval '10 days'), test.h2ft(interval '12 days'), 'pending_payment');
select test.eq('confirm_pay_later through the connector: a preview that changes nothing', (select (r #>> '{result,preview}') || ':' || (select status::text from bookings where id = test.id('booking:H2F-PL2'))
  from (select app.api_call(test.h2f_h('cc_live_h2f_full'), 'confirm_pay_later', jsonb_build_object('booking', 'H2F-PL2', 'reason', 'No processor, pays by e-Transfer'), 'test') r) z), 'true:pending_payment');

-- ---------------------------------------------------------------- 6. the rules
select test.eq('the new functions are the server''s only', (select count(*) from pg_proc p join pg_namespace n on n.oid = p.pronamespace
  where n.nspname = 'app' and p.proname in ('booking_pay_later', 'booking_start_pay_later', 'pay_later_todo', 'owner_instant_book_set', 'setting_connector_keys', 'setting_screen_only', 'renter_profile_complete', 'vehicle_instant_ok', 'setting_table', 'setting_key_secret', 'api_call_pre5112')
    and (has_function_privilege('anon', p.oid, 'execute') or has_function_privilege('authenticated', p.oid, 'execute'))), 0::bigint);

-- the dated Program settings row the connector's confirm made goes; the row before it is restored (no setting left for other files)
-- (an earlier file may have left more than one dated row: every row of the start is kept, the rows this file made go)
delete from program_settings where id not in (select id from h2f_ps) and created_by = test.id('h2f_admin');
update program_settings s set offer_expiry_hours = o.h from h2f_oe o where s.id = o.id;
update program_settings s set api_access_enabled = p.e, api_calls_per_minute = p.n, instant_book_repeat_enabled = p.i, card_payments = p.c, e_transfer_email = p.t, cc_pay_institution_number = p.pi, cc_pay_transit_number = p.pt, cc_pay_account_number = p.pa from h2f_ps p where s.id = p.id;
