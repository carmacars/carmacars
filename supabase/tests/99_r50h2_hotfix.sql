-- 99: r50 hotfix2 (migrations 5110 to 5114; docs/changes/2026-11-27-r50-hotfix2.md): card payments off with e-Transfer and
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
select test.eq('a read key cannot change a setting', test.h2f_api('cc_live_h2f_read', '{"key": "offer_hours", "value": 30}') ->> 'status', '403');
select test.eq('a key whose person is not an Admin is refused', test.h2f_api('cc_live_h2f_fin', '{"key": "e_transfer_email", "value": "pay@example.test"}') ->> 'ok', 'false');
select test.eq('a secret key is refused', test.h2f_api('cc_live_h2f_full', '{"key": "google_drive_api_key", "value": "x"}') ->> 'status', '403');
select test.eq('a bank detail is refused', test.h2f_api('cc_live_h2f_full', '{"key": "cc_pay_account_number", "value": "1234567"}') ->> 'status', '403');
select test.eq('a key that is not a setting is refused', test.h2f_api('cc_live_h2f_full', '{"key": "no_such_setting", "value": 1}') ->> 'error', 'Not a setting: no_such_setting');
select test.eq('a value the Settings page refuses is refused (not a true or false)', test.h2f_api('cc_live_h2f_full', '{"key": "card_payments", "value": "maybe"}') ->> 'ok', 'false');
create temp table h2f_pv as select test.h2f_api('cc_live_h2f_full', '{"key": "e_transfer_email", "value": "pay@example.test"}') r;
select test.eq('the preview shows before and after and changes nothing', (select (r #>> '{result,before}') || '>' || (r #>> '{result,after}') || ':' || (app.settings()).e_transfer_email from h2f_pv),
  'rent@carmacars.ca>pay@example.test:rent@carmacars.ca');
select test.eq('a confirm with other arguments is refused', test.h2f_api('cc_live_h2f_full', jsonb_build_object('key', 'e_transfer_email', 'value', 'other@example.test', 'confirm', true, 'preview_id', (select r #>> '{result,preview_id}' from h2f_pv))) ->> 'ok', 'false');
create temp table h2f_pv2 as select test.h2f_api('cc_live_h2f_full', '{"key": "e_transfer_email", "value": "pay@example.test"}') r;
select test.eq('the confirm changes it', (test.h2f_api('cc_live_h2f_full', jsonb_build_object('key', 'e_transfer_email', 'value', 'pay@example.test', 'confirm', true, 'preview_id', (select r #>> '{result,preview_id}' from h2f_pv2))) #>> '{result,after}') || ':' || (app.settings()).e_transfer_email,
  'pay@example.test:pay@example.test');
select test.eq('the log keeps the before and the after', (select (before ->> 'e_transfer_email') || '>' || (after ->> 'e_transfer_email') from api_calls where tool = 'set_setting' and ok order by id desc limit 1), 'rent@carmacars.ca>pay@example.test');
select test.eq('a used preview cannot be used again', test.h2f_api('cc_live_h2f_full', jsonb_build_object('key', 'e_transfer_email', 'value', 'pay@example.test', 'confirm', true, 'preview_id', (select r #>> '{result,preview_id}' from h2f_pv2))) ->> 'ok', 'false');

-- ---------------------------------------------------------------- 4. Instant booking for a complete profile (5113)
select test.eq('a complete profile, verified licence, no rental closed: eligible, whatever the tier', app.instant_book_check(test.id('renter:h2f_r')) ->> 'eligible', 'true');
select test.eq('no home address: not eligible, and the reason says so', app.instant_book_check(test.id('renter:h2f_r2')) ->> 'reason', 'The profile is not complete (name, date of birth, home address, mobile and email)');
select test.eq('the migration keeps 01 Motors off it (its owner matched by name)', (select count(*) from owners where instant_book_off and legal_name ~* '^0?1 motors\M') = (select count(*) from owners where legal_name ~* '^0?1 motors\M' and id <> test.id('owner:h2f01')), true);
update owners set instant_book_off = true where id = test.id('owner:h2f01');
select test.eq('a car of the owner: ok; of 01 Motors: no', app.vehicle_instant_ok(test.id('vehicle:H2FA')) || ':' || app.vehicle_instant_ok(test.id('vehicle:H2FM')), 'true:false');
update vehicles set is_sample = true where id = test.id('vehicle:H2FB');
select test.eq('a sample car: no', app.vehicle_instant_ok(test.id('vehicle:H2FB')), false);
update vehicles set is_sample = false where id = test.id('vehicle:H2FB');
select test.mk_booking('H2F-REQ', 'H2FM', 'h2f_r', test.h2ft(interval '5 days'), test.h2ft(interval '7 days'), 'requested');
select test.eq('Book instantly on a 01 Motors car stays a request', public.server_instant_book('H2F-REQ', test.id('h2f_r')) ->> 'reason', 'This car is booked by request');
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
select test.eq('the incident card is there while the renter has the car', app.booking_in_progress((select b from bookings b where b.id = test.id('booking:H2F-OUT'))), true);

-- ---------------------------------------------------------------- 6. the rules
select test.eq('the new functions are the server''s only', (select count(*) from pg_proc p join pg_namespace n on n.oid = p.pronamespace
  where n.nspname = 'app' and p.proname in ('booking_pay_later', 'booking_start_pay_later', 'renter_profile_complete', 'vehicle_instant_ok', 'setting_table', 'setting_key_secret', 'api_call_pre5112')
    and (has_function_privilege('anon', p.oid, 'execute') or has_function_privilege('authenticated', p.oid, 'execute'))), 0::bigint);

update program_settings s set api_access_enabled = p.e, api_calls_per_minute = p.n, instant_book_repeat_enabled = p.i, card_payments = p.c, e_transfer_email = p.t, cc_pay_institution_number = p.pi, cc_pay_transit_number = p.pt, cc_pay_account_number = p.pa from h2f_ps p where s.id = p.id;
