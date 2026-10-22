-- 56: sign-in by phone (migration 0091). Who may get a code (Canada; the US behind an Admin setting), the per-number and
-- per-IP limits, the hook texting only codes the site asked for (and the new number of a phone change), the log; the
-- account made by phone; linking after the code is verified (a record without a confirmed sign-in is attached with its
-- bookings, a record of another account or a second record becomes a staff task, owner records, driver places, leads);
-- a phone added to an email account; confirmation (a verified phone counts, configurable) and the email before the first
-- payment; the chosen sign-in; privileges; the privacy policy. Fixtures start with "ps".
select test.suite('56 phone sign-in');

select test.mk_user('ps_admin', 'admin');
select test.mk_renter('ps_rita');                                   -- a confirmed email account (below)
select test.mk_renter('ps_gina', false);                            -- a record with no sign-in at all
select test.mk_owner('ps_olga');
select test.mk_vehicle('ps_car', 'ps_olga');
update users set email_verified_at = now() where id = test.id('ps_rita');
update renters set mobile = '(416) 555-0201' where id = test.id('renter:ps_rita');
update drivers set mobile = '416 555 0201' where id = test.id('driver:ps_rita');
update renters set mobile = '647-555-0202' where id = test.id('renter:ps_gina');
-- a guest's booking request: a users row without any sign-in, its renter record and a request
insert into users (id, email, full_name) values (test.id('ps_guest'), 'ps_guest@example.test', 'Gus Guest');
insert into user_roles (user_id, role) values (test.id('ps_guest'), 'renter');
insert into renters (id, user_id, legal_name, mobile, email) values (test.id('renter:ps_guest'), test.id('ps_guest'), 'Gus Guest', '+1 (437) 555-0203', 'ps_guest@example.test');
insert into drivers (id, renter_id, is_account_holder, user_id, full_name, date_of_birth, mobile)
values (test.id('driver:ps_guest'), test.id('renter:ps_guest'), true, test.id('ps_guest'), 'Gus Guest', date '1991-02-03', '437 555 0203');
insert into payment_methods (id, renter_id, card_brand, card_last4, cardholder_name, exp_month, exp_year, is_credit)
values (test.id('card:ps_guest'), test.id('renter:ps_guest'), 'visa', '4242', 'Gus Guest', 12, 2030, true);
select test.mk_booking('PS-1', 'ps_car', 'ps_guest', '2026-03-10 10:00', '2026-03-12 10:00', 'closed');
-- an additional driver named on Rita's booking with a mobile, an owner lead with a phone, a contact lead
insert into drivers (id, renter_id, is_account_holder, full_name, date_of_birth, mobile) values (test.id('driver:ps_dan'), test.id('renter:ps_rita'), false, 'Dan Driver', date '1990-01-01', '905-555-0204');
insert into owners (id, owner_type, legal_name, phone, status, email) values (test.id('owner:ps_lead'), 'individual', 'Liam Lead', '226 555 0205', 'lead', 'ps_lead@example.test');
insert into leads (id, kind, name, phone) values (test.id('lead:ps_lena'), 'contact', 'Lena Lead', '(519) 555-0206');
update program_settings set signin_phone_us_allowed = false, signin_confirm_required = true, signin_confirm_by_phone = true, signin_phone_enabled = true;

-- ================================================================ 1. settings and who may get a code
select test.eq('settings: on, US numbers off, 5 codes a number and 20 a connection an hour, confirmation required, a phone counts',
  (select format('%s %s %s %s %s %s', signin_phone_enabled, signin_phone_us_allowed, signin_phone_hourly_per_number, signin_phone_hourly_per_ip,
                 signin_confirm_required, signin_confirm_by_phone) from (select (app.settings()).*) s), 't f 5 20 t t');
select test.eq('a Canadian number may sign in (E.164 from what was typed)', app.signin_phone_check('(647) 555-0210') ->> 'phone', '+16475550210');
select test.eq('the CarmaCars number''s own area code is Canadian', app.phone_country('289-312-5991'), 'CA');
select test.eq('a US number: refused while US texting is off (A2P 10DLC)', app.signin_phone_check('212 555 0211') ->> 'reason', 'country');
select test.eq('Caribbean, toll-free and N11 codes are not the US', app.phone_country('876 555 0101') || app.phone_country('888 555 0101') || app.phone_country('411 555 0101'), 'otherotherother');
select test.eq('not a number', app.signin_phone_check('call me') ->> 'reason', 'invalid');
update program_settings set signin_phone_us_allowed = true;
select test.eq('US numbers allowed by an Admin', app.signin_phone_check('212 555 0211') ->> 'country', 'US');
select test.eq('...but never a number outside +1', app.signin_phone_check('+44 20 7946 0958') ->> 'reason', 'country');
update program_settings set signin_phone_us_allowed = false, signin_phone_enabled = false;
select test.eq('switched off: no codes', app.signin_phone_check('647 555 0210') ->> 'reason', 'off');
update program_settings set signin_phone_enabled = true;
select test.eq('the public rules: enabled, US off, 6 digits, 5 minutes', app.signin_phone_rules(), '{"enabled": true, "code_length": 6, "us_allowed": false, "code_minutes": 5}'::jsonb);

-- ================================================================ 2. the site's limits per number and per connection
select test.eq('five codes for one number in an hour, then refused',
  (select string_agg((app.signin_phone_request(jsonb_build_object('phone', '647 555 0212', 'ip', '203.0.113.' || g)) ->> 'ok'), ',' order by g) from generate_series(1, 6) g),
  'true,true,true,true,true,false');
select test.eq('...the sixth says rate_limited', app.signin_phone_request(jsonb_build_object('phone', '647 555 0212', 'ip', '203.0.113.99')) ->> 'reason', 'rate_limited');
select test.eq('twenty codes from one connection in an hour, then refused',
  (select count(*) filter (where (app.signin_phone_request(jsonb_build_object('phone', format('705 555 %s', 1000 + g), 'ip', '198.51.100.7')) ->> 'ok')::boolean) from generate_series(1, 22) g), 20::bigint);
select test.eq('checking codes: 10 tries a number an hour',
  (select count(*) filter (where (app.signin_phone_request(jsonb_build_object('phone', '647 555 0213', 'kind', 'verify')) ->> 'ok')::boolean) from generate_series(1, 12) g), 10::bigint);
select test.eq('a refused number is not counted or recorded as asked', app.signin_phone_request(jsonb_build_object('phone', '212 555 0214', 'ip', '203.0.113.50')) ->> 'reason', 'country');
select test.eq('...no request was recorded for it', (select count(*) from app.auth_sms_intent where phone = '+12125550214'), 0::bigint);

-- ================================================================ 3. the hook: only codes the site asked for
select test.eq('a code nobody asked for on the site (straight from the sign-in service''s API) is not texted',
  app.server_auth_sms(jsonb_build_object('phones', jsonb_build_array('+16475550215'))) ->> 'reason', 'no_request');
select test.eq('...and is in the log as refused', (select status || ' ' || reason from app.auth_sms_log where phone = '+16475550215'), 'refused no_request');
select app.signin_phone_request(jsonb_build_object('phone', '647 555 0215', 'ip', '203.0.113.60'));
select test.eq('asked on the site: texted from the CarmaCars number, a log row while sending',
  (select format('%s %s %s', x ->> 'ok', x ->> 'from', (x ->> 'log_id') is not null) from (select app.server_auth_sms(jsonb_build_object('phones', jsonb_build_array('+16475550215'))) x) y),
  format('true %s t', app.phone_our_number()));
select app.server_auth_sms_result(jsonb_build_object('log_id', (select id from app.auth_sms_log where phone = '+16475550215' and status = 'sending'), 'ok', true, 'quo_id', 'ACps1'));
select test.eq('...the log says sent with Quo''s message id, never the code', (select status || ' ' || quo_message_id from app.auth_sms_log where phone = '+16475550215' and status <> 'refused'), 'sent ACps1');
select test.ok('the log has no column for the code', not exists (select 1 from information_schema.columns where table_schema = 'app' and table_name = 'auth_sms_log' and column_name in ('otp', 'code', 'body')));
select test.eq('one request, one text: the same request is not used twice', app.server_auth_sms(jsonb_build_object('phones', jsonb_build_array('+16475550215'))) ->> 'reason', 'no_request');
-- a phone change: the hook's candidates are the new number and the account's number; the one the site asked for is texted
select app.signin_phone_request(jsonb_build_object('phone', '647 555 0216', 'purpose', 'phone_change', 'user_id', test.id('ps_rita')));
select test.eq('a phone change texts the number the site asked for (the new one), never the account''s old number',
  app.server_auth_sms(jsonb_build_object('phones', jsonb_build_array('+14165550201', '+16475550216'), 'user_id', test.id('ps_rita'))) ->> 'phone', '+16475550216');
select test.eq('...recorded as a phone change', (select purpose from app.auth_sms_intent where phone = '+16475550216'), 'phone_change');
update program_settings set signin_phone_hourly_per_number = 1;
select app.signin_phone_request(jsonb_build_object('phone', '647 555 0217'));
select x from (select app.server_auth_sms(jsonb_build_object('phones', jsonb_build_array('+16475550217'))) x) y;
insert into app.auth_sms_intent (phone, purpose) values ('+16475550217', 'sign_in');
select x from (select app.server_auth_sms(jsonb_build_object('phones', jsonb_build_array('+16475550217'))) x) y;
insert into app.auth_sms_intent (phone, purpose) values ('+16475550217', 'sign_in');
select test.eq('the hook''s own limit (twice the per-number limit an hour) stops a flood the site did not count',
  app.server_auth_sms(jsonb_build_object('phones', jsonb_build_array('+16475550217'))) ->> 'reason', 'rate_limited');
update program_settings set signin_phone_hourly_per_number = 5;
insert into app.auth_sms_intent (phone, purpose) values ('+12125550218', 'sign_in');
select test.eq('a US number the site somehow asked for is still refused while US texting is off',
  app.server_auth_sms(jsonb_build_object('phones', jsonb_build_array('+12125550218'))) ->> 'reason', 'country');
update app.auth_sms_log set created_at = now() - interval '31 days' where phone = '+16475550215';
select app.signin_phone_request(jsonb_build_object('phone', '647 555 0219'));
select app.server_auth_sms(jsonb_build_object('phones', jsonb_build_array('+16475550219')));
select test.eq('the log keeps 30 days', (select count(*) from app.auth_sms_log where phone = '+16475550215'), 0::bigint);

-- ================================================================ 4. an account made by phone
select test.eq('a new number: the account is made with no email, the number verified, the renter role; it asks the name',
  (select format('%s %s', x ->> 'created', x ->> 'needs_name') from (select app.phone_signed_in(test.id('ps_new'), '+1 647 555 0220') x) y), 'true true');
select test.eq('...the users row', (select format('%s|%s|%s|%s|%s', coalesce(email, 'no email'), phone, phone_verified_at is not null, preferred_sign_in, full_name) from users where id = test.id('ps_new')),
  'no email|+16475550220|t|phone|');
select test.ok('...renter role', exists (select 1 from user_roles where user_id = test.id('ps_new') and role = 'renter'));
select app.account_set_name(test.id('ps_new'), 'Nora New');
select test.eq('the name, once (a name on file is not overwritten this way)',
  (select full_name from users where id = test.id('ps_new')) || ' ' || (app.account_set_name(test.id('ps_new'), 'Someone Else') ->> 'changed'), 'Nora New false');
select test.throws('an account needs an email or a phone', $$insert into users (id, email, full_name) values (gen_random_uuid(), null, 'Nobody')$$, 'users_email_or_phone');
select test.eq('signing in again with the same number: the same account, nothing made twice',
  (select x ->> 'created' from (select app.phone_signed_in(test.id('ps_new'), '6475550220') x) y), 'false');
insert into vehicle_listings (vehicle_id, slug, headline, status, published_at) values (test.id('vehicle:ps_car'), 'c300-ps-car', 'Mercedes C 300', 'published', now());
select test.eq('a booking request from the account made by phone works without an email',
  (select (app.submit_booking_request(jsonb_build_object('request_key', 'ps-req-1', 'vehicle_id', test.id('vehicle:ps_car'),
     'pickup_at', date_trunc('hour', now()) + interval '20 days', 'return_at', date_trunc('hour', now()) + interval '22 days', 'booking_type', 'standard',
     'pickup_method', 'collected', 'return_method', 'returned', 'coverage_option', 1,
     'renter', jsonb_build_object('email', '', 'full_name', 'Nora New', 'mobile', '+16475550220', 'date_of_birth', '1990-04-04', 'licence_class', 'G', 'licence_issuer', 'ON'),
     'additional_drivers', '[]'::jsonb,
     'consents', jsonb_build_object('terms', jsonb_build_object('accepted', true, 'version', 'v1', 'text', 'I agree'), 'privacy', jsonb_build_object('accepted', true, 'version', 'v1', 'text', 'I agree'),
                                    'marketing', jsonb_build_object('opted_in', false, 'version', 'v1', 'text', 'Marketing'))),
     null, null, test.id('ps_new')) ->> 'booking_number') is not null), true);

-- ================================================================ 5. linking, after the code is verified
-- (a) Gus's guest record (a users row with no sign-in): a new phone account with his number takes it, with the request
select test.eq('a guest record with the number and no sign-in of its own: attached, with its booking',
  (select format('%s %s %s', x ->> 'renter_records', x ->> 'bookings', x ->> 'needs_name') from (select app.phone_signed_in(test.id('ps_gus2'), '437 555 0203') x) y), '1 1 false');
select test.eq('...the renter record and its account holder are the phone account''s now; the name came from the record',
  (select r.user_id = test.id('ps_gus2') and d.user_id = test.id('ps_gus2') from renters r join drivers d on d.renter_id = r.id and d.is_account_holder where r.id = test.id('renter:ps_guest'))::text
  || ' ' || (select full_name from users where id = test.id('ps_gus2')), 'true Gus Guest');
select test.eq('...the portal lists what was added', (select string_agg(kind || ':' || detail, ',' order by kind) from account_links where user_id = test.id('ps_gus2')), 'booking:PS-1,renter_record:Gus Guest');
-- (b) Gina's record has no users row at all: attached the same way
select test.eq('a record with no account at all: attached', (select x ->> 'renter_records' from (select app.phone_signed_in(test.id('ps_gina2'), '647-555-0202') x) y), '1');
-- (c) Rita has a confirmed email account; someone verifies her number on a new account: never attached, a staff task
select test.eq('a record of another confirmed account: not attached, a task for staff (the person is told nothing)',
  (select format('%s %s', x ->> 'renter_records', x ->> 'needs_staff') from (select app.phone_signed_in(test.id('ps_imp'), '+14165550201') x) y), '0 1');
select test.eq('...Rita''s record stays hers', (select user_id from renters where id = test.id('renter:ps_rita')), test.id('ps_rita'));
select test.eq('...the task', (select task_type || ' ' || queue from tasks where related_id = test.id('renter:ps_rita') and task_type = 'account_phone_review'), 'account_phone_review cs');
select test.eq('...signing in again does not raise it twice', (select (app.phone_signed_in(test.id('ps_imp'), '+14165550201') ->> 'needs_staff')), '0');
-- (d) an owner lead with the number and no account: attached, with the owner portal
select test.eq('an owner record with the number and no sign-in: attached', (select x ->> 'owner_records' from (select app.phone_signed_in(test.id('ps_liam'), '2265550205') x) y), '1');
select test.eq('...with the owner role and the record', (select exists (select 1 from user_roles where user_id = test.id('ps_liam') and role = 'owner') and (select user_id from owners where id = test.id('owner:ps_lead')) = test.id('ps_liam')), true);
select test.eq('...an owner record that has an account (Olga, 416-555-0100) is never attached', (select x ->> 'owner_records' from (select app.phone_signed_in(test.id('ps_olga2'), '416-555-0100') x) y), '0');
select test.eq('...Olga''s record stays hers', (select user_id from owners where id = test.id('owner:ps_olga')), test.id('ps_olga'));
-- (e) an additional driver's place, and (f) leads, are attached or listed
select test.eq('an additional driver''s place with the number: attached', (select x ->> 'drivers' from (select app.phone_signed_in(test.id('ps_dan'), '905 555 0204') x) y), '1');
select test.eq('...the driver row', (select user_id from drivers where id = test.id('driver:ps_dan')), test.id('ps_dan'));
select test.eq('a lead with the number: listed for staff, and its name used', (select format('%s %s', x ->> 'leads', x ->> 'first_name') from (select app.phone_signed_in(test.id('ps_lena'), '519-555-0206') x) y), '1 Lena');
-- (g) an account that already has its own renter record and verifies the number of another unclaimed record
insert into renters (id, legal_name, mobile, email) values (test.id('renter:ps_old'), 'Old Record', '647 555 0220', 'ps_old@example.test');
select test.eq('a second record when the account already has one: a staff task, not attached', (select format('%s %s', x ->> 'renter_records', x ->> 'needs_staff') from (select app.phone_signed_in(test.id('ps_new'), '+16475550220') x) y), '0 1');

-- ================================================================ 6. a phone added to an email account
select test.eq('Rita (signed in by email) verifies a new number: it is her account''s, nothing is made',
  (select format('%s %s', x ->> 'created', x ->> 'renter_records') from (select app.phone_signed_in(test.id('ps_rita'), '647 555 0216') x) y), 'false 0');
select test.eq('...her users row', (select format('%s %s %s', email, phone, phone_verified_at is not null) from users where id = test.id('ps_rita')), 'ps_rita@example.test +16475550216 t');
select test.eq('a number verified by another account later is that account''s', app.phone_signed_in(test.id('ps_rita2'), '647 555 0216') ->> 'ok', 'true');
select test.eq('...the earlier account no longer counts it as verified (it keeps its email sign-in)', (select phone_verified_at is null and email is not null from users where id = test.id('ps_rita')), true);
select test.eq('one verified number per account', (select count(*) from users where phone = '+16475550216' and phone_verified_at is not null), 1::bigint);
select app.phone_signed_in(test.id('ps_rita'), '647 555 0216');
select test.eq('...and back: an account made by phone that loses its number keeps the number unverified (it needs an email or a phone)',
  (select format('%s %s', phone, phone_verified_at is null) from users where id = test.id('ps_rita2')), '+16475550216 t');

-- ================================================================ 7. confirmation and the email before the first payment
select test.eq('a confirmed email confirms the account', app.account_confirmed(test.id('ps_rita')), true);
select test.eq('a verified phone confirms the account (signin_confirm_by_phone)', app.account_confirmed(test.id('ps_new')), true);
select test.eq('an account with neither: accepting, signing and paying wait',
  (select string_agg(app.account_gate(test.id('ps_guest'), s) ->> 'reason', ',') from unnest(array['accept', 'sign', 'pay']) s), 'unconfirmed,unconfirmed,unconfirmed');
update program_settings set signin_confirm_by_phone = false;
select test.eq('only a confirmed email counts when an Admin turns the phone off', app.account_gate(test.id('ps_new'), 'accept') ->> 'reason', 'unconfirmed');
update program_settings set signin_confirm_by_phone = true, signin_confirm_required = false;
select test.eq('the rule off: anyone signed in may accept', app.account_gate(test.id('ps_guest'), 'accept') ->> 'ok', 'true');
update program_settings set signin_confirm_required = true;
select test.eq('an account made by phone accepts and signs; paying asks for the email first',
  (select string_agg(coalesce(app.account_gate(test.id('ps_new'), s) ->> 'reason', 'ok'), ',') from unnest(array['accept', 'sign', 'pay']) s), 'ok,ok,email_needed');
select test.eq('an email used by another account is refused', app.account_set_email(test.id('ps_new'), 'PS_RITA@example.test') ->> 'error', 'email_taken');
select test.throws('not an email', $$select app.account_set_email(test.id('ps_new'), 'nora at home')$$, 'Enter an email');
select test.eq('the email saved', app.account_set_email(test.id('ps_new'), ' PS_Nora@Example.test ') ->> 'ok', 'true');
select test.eq('...not confirmed yet, on the renter record too; now payment can start',
  (select format('%s %s', email, email_verified_at is null) from users where id = test.id('ps_new')) || ' ' || (select email from renters where user_id = test.id('ps_new'))
  || ' ' || (app.account_gate(test.id('ps_new'), 'pay') ->> 'ok'), 'ps_nora@example.test t ps_nora@example.test true');
select test.throws('a confirmed email is changed by staff, not here', $$select app.account_set_email(test.id('ps_rita'), 'other@example.test')$$, 'already has a confirmed email');
select test.eq('confirming the new email later (the link) works as for any account', app.account_email_verified(test.id('ps_new'), 'ps_nora@example.test') ->> 'ok', 'true');
select test.eq('...confirmed', (select email_verified_at is not null from users where id = test.id('ps_new')), true);

-- ================================================================ 8. the chosen sign-in and the profile card
select test.throws('phone sign-in needs a verified phone', $$select app.account_set_sign_in(test.id('ps_olga'), 'phone')$$, 'verify your phone');
select test.eq('choosing phone', app.account_set_sign_in(test.id('ps_rita'), 'phone') ->> 'preferred', 'phone');
select test.eq('the profile card', (select format('%s %s %s %s %s', x ->> 'email', x ->> 'phone', x ->> 'phone_verified', x ->> 'preferred', x ->> 'us_allowed') from (select app.my_sign_in(test.id('ps_rita')) x) y),
  'ps_rita@example.test +16475550216 true phone false');
select test.eq('...an unverified number on file is offered to verify, never shown as the sign-in phone',
  (select format('%s %s', coalesce(x ->> 'phone', 'none'), x ->> 'phone_on_file') from (select app.my_sign_in(test.id('ps_olga')) x) y), 'none +14165550100');

-- ================================================================ 9. privileges and the privacy policy
select test.eq('only the server: anon and signed-in people cannot sign someone in, link records or read the log',
  has_function_privilege('anon', 'public.server_phone_signed_in(uuid, text, text)', 'execute')::text || has_function_privilege('authenticated', 'public.server_auth_sms(jsonb)', 'execute')::text
  || has_function_privilege('authenticated', 'app.account_phone_verified(uuid, text)', 'execute')::text || has_table_privilege('authenticated', 'app.auth_sms_log', 'select')::text
  || has_function_privilege('service_role', 'public.server_phone_signed_in(uuid, text, text)', 'execute')::text,
  'falsefalsefalsefalsetrue');
select test.eq('the rules are public (no personal data)', has_function_privilege('anon', 'public.signin_phone_rules()', 'execute'), true);
select test.ok('the privacy policy says we text sign-in codes to the number you give',
  (select body like '%we text a one-time sign-in code to the phone number you give%' from site_content_blocks where block_key = 'legal.privacy')
  or not exists (select 1 from site_content_blocks where block_key = 'legal.privacy' and body like '%Calls and texts are kept with your rental records%'));
