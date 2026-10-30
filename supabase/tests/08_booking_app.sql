-- 08: the booking application (migration 0019). The quote against every worked example of the
-- renter billing specification; the public request with its checks, consents, idempotency and
-- limits; the whole path request, offer, approve, sign, pay, confirmed, with the race for one
-- car; signing again after an adjustment; bookings with nothing to pay; cancellation tiers;
-- extensions; change requests; questions to the renter; identity and coverage documents and the
-- handover guards; two-step sign-in for staff; and row-level security for every role on every
-- new table and wrapper.
select test.suite('08 booking app');
-- 0066: winter tires are an add-on offered October to April; this suite prices them on dates all year, so here every month
update addons set available_months = '{}' where code = 'winter_tire';

-- ------------------------------------------------------------------ helpers and fixture
create or replace function test.at(p_local text) returns timestamptz
language sql immutable as $$ select p_local::timestamp at time zone 'America/Toronto' $$;

-- an instant so far from the top of the current hour (pickups must be in the future)
create function test.soon(p_offset interval) returns timestamptz
language sql stable as $$ select date_trunc('hour', now()) + p_offset $$;

create function test.sha(p_text text) returns text
language sql immutable as $$ select encode(sha256(convert_to(p_text, 'UTF8')), 'hex') $$;

create table test.ba_ids (k text primary key, id uuid not null);
create table test.ba_out (k text primary key, v jsonb);
grant select on test.ba_ids, test.ba_out to authenticated, anon;

create function test.ba(p_key text) returns uuid language sql stable as $$ select id from test.ba_ids where k = p_key $$;
create function test.ba_st(p_key text) returns text language sql stable security definer as
$$ select status::text from public.bookings where id = (select id from test.ba_ids where k = p_key) $$;
create function test.ba_user(p_email text) returns uuid language sql stable security definer as
$$ select id from public.users where lower(email) = lower(p_email) $$;
-- the last result kept under a key
create function test.out(p_key text) returns jsonb language sql stable as $$ select v from test.ba_out where k = p_key $$;
create function test.keep(p_key text, p_value jsonb) returns jsonb language sql as $$
  insert into test.ba_out values (p_key, p_value) on conflict (k) do update set v = excluded.v returning v
$$;

-- the request a browser would send, for the customer with this email
create function test.ba_req(p_key text, p_email text, p_vehicle text, p_pickup timestamptz, p_return timestamptz, p_over jsonb default '{}')
returns jsonb language sql stable as $$
  select (jsonb_build_object(
      'request_key', 'ba-key-' || p_key, 'vehicle_id', test.id('vehicle:' || p_vehicle), 'pickup_at', p_pickup, 'return_at', p_return,
      'booking_type', 'standard', 'coverage_option', 2,
      'consents', jsonb_build_object(
        'terms', jsonb_build_object('accepted', true, 'version', 'terms-2026-10', 'text', 'I am 18 or older and agree to the Terms of Use.'),
        'privacy', jsonb_build_object('accepted', true, 'version', 'privacy-2026-10', 'text', 'I agree to the Privacy Policy.')))
    || (p_over - 'renter'))
    || jsonb_build_object('renter', jsonb_build_object(
         'full_name', initcap(replace(split_part(p_email, '@', 1), '.', ' ')), 'date_of_birth', '1988-04-04', 'email', p_email,
         'mobile', '416-555-0142', 'licence_class', 'G', 'licence_issuer', 'ON') || coalesce(p_over -> 'renter', '{}'::jsonb))
$$;

create function test.ba_new(p_key text, p_email text, p_vehicle text, p_pickup timestamptz, p_return timestamptz, p_over jsonb default '{}')
returns jsonb language plpgsql as $$
declare
  v jsonb;
begin
  v := app.submit_booking_request(test.ba_req(p_key, p_email, p_vehicle, p_pickup, p_return, p_over));
  if (v ->> 'ok')::boolean then
    insert into test.ba_ids values (p_key, (v ->> 'booking_id')::uuid) on conflict (k) do nothing;
  end if;
  return test.keep('new:' || p_key, v);
end $$;

-- customer service sends the offer and the renter approves it
create function test.ba_offer(p_key text) returns integer language plpgsql as $$
declare
  v integer;
begin
  v := app.send_offer(test.ba(p_key), test.id('ba_cs'));
  perform app.approve_offer(test.ba(p_key), v, (select r.user_id from bookings b join renters r on r.id = b.renter_id where b.id = test.ba(p_key)));
  return v;
end $$;

-- the server opens the agreement for the renter, with the hash of the document it rendered
create function test.ba_open(p_key text, p_doc text default null) returns uuid language sql as $$
  select app.open_rental_agreement(b.id, r.user_id, 'rental-v2-2026-10',
           test.sha(coalesce(p_doc, 'agreement of ' || p_key || ' v' || coalesce(b.offer_approved_version::text, 'owner'))),
           'bookings/' || b.id || '/agreement-' || coalesce(b.offer_approved_version::text, 'owner') || '-' || coalesce(p_doc, 'a') || '.pdf')
    from bookings b join renters r on r.id = b.renter_id where b.id = test.ba(p_key)
$$;

-- the renter signs by typing their name
create function test.ba_sign(p_key text) returns uuid language sql as $$
  select app.record_signature(b.signature_request_id, g.id, g.signer_name, null, inet '203.0.113.50', 'test browser',
           'I have read this Rental Agreement and I sign it electronically.')
    from bookings b join rental_agreements a on a.signature_request_id = b.signature_request_id
    join rental_agreement_signers g on g.agreement_id = a.id and g.signer_role = 'renter'
   where b.id = test.ba(p_key)
$$;

-- the processor reports the authorized payment
create function test.ba_pay(p_key text, p_amount bigint default null, p_version integer default null, p_event text default null) returns jsonb
language sql as $$
  select test.keep('pay:' || p_key, app.record_booking_payment(b.id,
           jsonb_build_object('processor', 'stripe', 'payment_id', 'pi_' || p_key, 'charge_id', 'ch_' || p_key, 'customer_id', 'cus_' || p_key,
                              'method_id', 'pm_' || p_key),
           coalesce(p_amount, b.renter_due_at_booking_cents), coalesce(p_version, b.offer_approved_version),
           jsonb_build_object('brand', 'visa', 'last4', '4242', 'cardholder_name', r.legal_name, 'exp_month', 12, 'exp_year', 2031, 'is_credit', true),
           p_event))
    from bookings b join renters r on r.id = b.renter_id where b.id = test.ba(p_key)
$$;

-- request, offer, approval, agreement, signature and payment in one step
create function test.ba_confirmed(p_key text, p_email text, p_vehicle text, p_pickup timestamptz, p_return timestamptz, p_over jsonb default '{}')
returns text language plpgsql as $$
begin
  perform test.ba_new(p_key, p_email, p_vehicle, p_pickup, p_return, p_over);
  perform test.ba_offer(p_key);
  perform test.ba_open(p_key);
  perform test.ba_sign(p_key);
  perform test.ba_pay(p_key);
  return test.ba_st(p_key);
end $$;
grant execute on all functions in schema test to authenticated, anon;

select test.mk_user('ba_admin', 'admin');
select test.mk_user('ba_cs', 'va', 'cs');
select test.mk_user('ba_fin', 'va', 'finance');
select test.mk_user('ba_fleet', 'va', 'fleet');
select test.mk_user('ba_sales', 'va', 'sales');
select test.mk_user('ba_field', 'field', null, 'driver');
select test.mk_owner('ba_owen');
select test.mk_owner('ba_pam');
select test.mk_vehicle(v, 'ba_owen') from unnest(array['BA1', 'BA2', 'BA3', 'BA4', 'BA5', 'BA6', 'BA7', 'BA8', 'BA9', 'BAY', 'BAU']) v;
select test.mk_vehicle('BAP', 'ba_pam', 'managed', 45000, 2500, 3000);
update vehicles set allows_18_to_20 = true where id = test.id('vehicle:BAY');
update vehicles set class = 'economy' where id = test.id('vehicle:BA9');
-- every car is on the public listing except BAU
insert into vehicle_listings (vehicle_id, slug, headline, seats, transmission, status, published_at)
select test.id('vehicle:' || v), 'ba-' || lower(v), 'Mercedes C 300 ' || v, 5, 'automatic', 'published', now()
  from unnest(array['BA1', 'BA2', 'BA3', 'BA4', 'BA5', 'BA6', 'BA7', 'BA8', 'BA9', 'BAY', 'BAP']) v;
-- the Owner as a renter of their own car
insert into renters (id, user_id, legal_name, is_owner_account) values (test.id('renter:ba_owen'), test.id('ba_owen'), 'Ba Owen', true);

-- ------------------------------------------------------------------ structure
select test.eq('S every new table has row-level security, the admin policy and an audit trigger',
  (select count(*) from pg_class c join pg_namespace n on n.oid = c.relnamespace
    where n.nspname = 'public' and c.relname in ('rental_agreements', 'rental_agreement_signers', 'webhook_events', 'booking_change_requests',
                                                 'booking_info_requests', 'verification_uploads')
      and c.relrowsecurity
      and exists (select 1 from pg_policies p where p.tablename = c.relname and p.policyname = 'admin_all')
      and exists (select 1 from pg_trigger g where g.tgrelid = c.oid and g.tgname = 'audit_' || c.relname)), 6::bigint);
select test.eq('S the rate limit counters live outside the API schema, with row-level security and no browser write',
  (select c.relrowsecurity || '/' || (select count(*) from pg_policies p where p.schemaname = 'app' and p.tablename = 'rate_limit_hits' and p.policyname = 'admin_all')
          || '/' || (select count(*) from information_schema.role_table_grants g where g.table_schema = 'app' and g.table_name = 'rate_limit_hits'
                        and g.grantee in ('anon', 'authenticated') and g.privilege_type <> 'SELECT')
     from pg_class c join pg_namespace n on n.oid = c.relnamespace where n.nspname = 'app' and c.relname = 'rate_limit_hits'), 'true/1/0');
select test.eq('S the numbers an Admin may change are program settings, with the standard values',
  (select booking_min_notice_minutes || '/' || booking_request_hourly_limit || '/' || booking_open_request_limit || '/' || public_rate_limit_per_minute
          || '/' || array_to_string(accepted_licence_classes, ',') || '/' || other_licence_for_review || '/' || max_additional_drivers || '/' || max_baby_seats
          || '/' || request_note_max_chars || '/' || info_request_reply_hours || '/' || verification_due_hours_before_pickup || '/' || verification_review_hours
          || '/' || require_staff_two_step || '/' || max_rental_days || '/' || min_renter_age || '/' || standard_min_age
     from app.settings()), '120/5/3/0/G,G2/true/4/3/500/24/24/2/false/365/18/21');
select test.eq('S an extension can now be approved between asking and paying',
  (select pg_get_constraintdef(oid) ~ 'requested.*approved.*confirmed.*declined.*lapsed' from pg_constraint
    where conrelid = 'public.booking_extensions'::regclass and conname = 'booking_extensions_status_check'), true);
select test.eq('S the consent list keeps its seven codes and gains the two of the request form (and 0025''s necessary_cookies)',
  (select count(*) || '/' || count(*) filter (where m[1] in ('terms_of_use', 'privacy_policy', 'marketing', 'tracking_disabling'))
     from regexp_matches((select pg_get_constraintdef(oid) from pg_constraint where conname = 'consents_consent_code_check'), '''([a-z_]+)''::text', 'g') m), '10/4');
select test.eq('S the booking history keeps its twelve kinds and gains this migration''s thirteen (and 0025''s two, 0046''s added_by_staff, 0057''s sales_credit, 0058''s custom_price, 0064''s request_expired, 0130''s five, 0154''s five, 0156''s three, 0177''s claim_taken_over, 0187''s staff_email, 0195''s recorded_now and recorded_now_details, 0198''s agreement_wording)',
  (select count(*) || '/' || count(*) filter (where m[1] in ('requested', 'pushed_back', 'agreement_voided', 'payment_refused'))
     from regexp_matches((select pg_get_constraintdef(oid) from pg_constraint where conname = 'booking_events_kind_check'), '''([a-z_]+)''::text', 'g') m), '49/4');
select test.eq('S nothing in the app schema that this migration added is executable from a browser session, except the quote, the search and the assurance level',
  (select string_agg(distinct p.proname, ',' order by p.proname) from pg_proc p join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'app' and (has_function_privilege('authenticated', p.oid, 'execute') or has_function_privilege('anon', p.oid, 'execute'))
      and p.proname in ('rate_limit', 'rate_limit_purge', 'request_ip', 'public_rate_check', 'session_aal', 'staff_two_step_ok', 'user_va_has',
        'fee_term', 'price_line', 'price_lines', 'booking_price_spec', 'put_price_line', 'sync_booking_price', 'reprice_booking', 'price_quote',
        'quote_booking', 'search_available', 'submit_booking_request', 'void_rental_agreements', 'open_rental_agreement', 'record_signature',
        'complete_signature_request', 'attach_signed_agreement', 'webhook_event_claim', 'webhook_event_finish', 'save_card_on_file',
        'push_back_booking', 'refuse_confirmation', 'finalize_booking', 'record_booking_payment', 'confirm_unpaid_booking',
        'booking_payment_capture_failed', 'waive_deposit', 'booking_paid_cents', 'preview_cancellation', 'cancel_booking', 'preview_extension',
        'request_extension', 'approve_extension', 'decline_extension', 'confirm_extension_payment', 'lapse_extensions', 'preview_booking_change',
        'request_booking_change', 'approve_booking_change', 'decline_booking_change', 'withdraw_booking_change', 'agree_booking_change',
        'apply_booking_change', 'ask_booking_info', 'reply_booking_info', 'close_booking_info', 'booking_readiness',
        'register_verification_upload', 'review_verification_upload', 'assert_my_booking', 'assert_booking_renter')),
  'quote_booking,search_available,session_aal');
select test.eq('S the server may run every function in the app schema',
  (select count(*) from pg_proc p join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'app' and not has_function_privilege('service_role', p.oid, 'execute')), 0::bigint);
select test.eq('S wrappers the anonymous visitor may call: the calendar, the reviews, is a car free, the quote and the search, and nothing else',
  (select string_agg(p.proname, ',' order by p.proname) from pg_proc p join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'public' and has_function_privilege('anon', p.oid, 'execute')
      and p.proname in ('public_vehicle_calendar', 'public_reviews', 'vehicle_is_available', 'quote_booking', 'search_available',
        'my_cancellation_preview', 'my_extension_preview', 'my_booking_change_preview', 'my_booking_readiness', 'my_promo_code_problem',
        'submit_booking_request', 'renter_approve_offer', 'renter_request_offer_change', 'renter_withdraw_request', 'renter_cancel_booking',
        'renter_request_extension', 'renter_request_booking_change', 'renter_agree_booking_change', 'renter_withdraw_booking_change',
        'renter_reply_booking_info')),
  'public_reviews,public_vehicle_calendar,quote_booking,search_available,vehicle_is_available');
select test.eq('S a signed-in session may also call the five read-only previews of its own bookings, and none of the wrappers that change anything',
  (select string_agg(p.proname, ',' order by p.proname) from pg_proc p join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'public' and has_function_privilege('authenticated', p.oid, 'execute') and not has_function_privilege('anon', p.oid, 'execute')
      and (p.proname like 'my\_%' or p.proname like 'renter\_%' or p.proname = 'submit_booking_request')),
  'my_booking,my_booking_change_preview,my_booking_messages,my_booking_readiness,my_bookings,my_cancellation_preview,my_document,my_documents,my_extension_preview,my_notification_preferences,my_notifications,my_profile,my_promo_code_problem,my_rewards,my_trip_photos,my_unread_count');
select test.eq('S the server may call every wrapper',
  (select count(*) from pg_proc p join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'public' and not has_function_privilege('service_role', p.oid, 'execute')
      and (p.proname like 'my\_%' or p.proname like 'renter\_%' or p.proname in ('submit_booking_request', 'quote_booking', 'search_available',
           'public_vehicle_calendar', 'public_reviews', 'vehicle_is_available'))), 0::bigint);
select test.eq('S the anonymous role still reads exactly one table or view',
  (select string_agg(table_name || ':' || privilege_type, ',') from information_schema.role_table_grants where table_schema = 'public' and grantee = 'anon'),
  'public_vehicle_listings:SELECT');
select test.eq('S the wrappers for the public are invoker functions; the own-booking previews are definer functions; the server''s wrappers are invoker functions',
  (select string_agg(p.proname || ':' || case when p.prosecdef then 'definer' else 'invoker' end, ' ' order by p.proname)
     from pg_proc p join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'public' and p.proname in ('quote_booking', 'search_available', 'public_vehicle_calendar', 'my_cancellation_preview',
                                                 'my_booking_readiness', 'submit_booking_request', 'renter_cancel_booking')),
  'my_booking_readiness:definer my_cancellation_preview:definer public_vehicle_calendar:invoker quote_booking:invoker renter_cancel_booking:invoker search_available:invoker submit_booking_request:invoker');

-- ------------------------------------------------------------------ the quote: every worked example of the renter billing specification
-- Section 2. Rates: daily $100, weekend $120, weekly $560, monthly $1,800 (the fixture's rate card).
select test.keep('q1', app.quote_booking(test.id('vehicle:BA1'), test.at('2029-05-03 10:00'), test.at('2029-05-06 10:00')));
select test.eq('Q example 1: Thursday 10:00 to Sunday 10:00 is 3 days, $100 + $120 + $120 = $340',
  (select (v ->> 'billable_days') || '/' || (v ->> 'rate_applied') || '/' || (v ->> 'daily_days') || '/' || (v ->> 'weekend_days') || '/' || (v ->> 'rental_charge_cents')
          || '/' || (v ->> 'rate_capped') || '/' || (v ->> 'rate_rule') from test.out('q1') v),
  '3/daily/1/2/' || test.money('340') || '/false/1 day at the daily rate and 2 days at the weekend rate');
select test.eq('Q example 1: one line, HST 13% on it ($44.20), total $384.20; nothing else is charged at booking',
  (select jsonb_array_length(v -> 'lines') || '/' || (v -> 'lines' -> 0 ->> 'charge_type') || '/' || (v -> 'lines' -> 0 ->> 'hst_cents') || '/' || (v ->> 'subtotal_cents')
          || '/' || (v ->> 'hst_cents') || '/' || (v ->> 'total_cents') || '/' || (v ->> 'total_due_at_booking_cents') from test.out('q1') v),
  '1/rental_charge/4420/34000/4420/38420/38420');
select test.eq('Q the quote carries the Deposit and how it is taken, the kilometre allowance and the overage rate',
  (select (v ->> 'deposit_cents') || '/' || (v ->> 'deposit_method') || '/' || (v ->> 'km_allowance_per_day') || '/' || (v ->> 'km_allowance_total')
          || '/' || (v ->> 'overage_cents_per_km') || '/' || (v ->> 'available') || '/' || (v ->> 'currency') from test.out('q1') v),
  '100000/card_hold/200/600/35/true/CAD');
select test.eq('Q the line itself says which rate applied and by which rule',
  (select (l -> 'detail' ->> 'rate_applied') || '/' || (l -> 'detail' ->> 'rate_rule') || '/' || (l ->> 'label') from test.out('q1') v, jsonb_array_elements(v -> 'lines') l),
  'daily/1 day at the daily rate and 2 days at the weekend rate/Rental charge (daily, weekend, weekly or monthly rate)');
select test.eq('Q the visitor is not shown which part of a line belongs to whom',
  (select count(*) from test.out('q1') v, jsonb_array_elements(v -> 'lines') l where l ? 'revenue_class'), 0::bigint);
select test.keep('q2', app.quote_booking(test.id('vehicle:BA1'), test.at('2029-05-07 09:00'), test.at('2029-05-13 09:00')));
select test.eq('Q example 2: Monday 09:00 to Sunday 09:00 is 6 days, 4 x $100 + 2 x $120 = $640, capped at the weekly rate: $560',
  (select (v ->> 'billable_days') || '/' || (v ->> 'daily_days') || '/' || (v ->> 'weekend_days') || '/' || (v ->> 'rental_charge_cents') || '/' || (v ->> 'rate_capped')
          || '/' || (v ->> 'rate_rule') from test.out('q2') v),
  '6/4/2/' || test.money('560') || '/true/4 days at the daily rate and 2 days at the weekend rate, capped at the weekly rate');
select test.keep('q3', app.quote_booking(test.id('vehicle:BA1'), test.at('2029-05-07 09:00'), test.at('2029-05-17 09:00')));
select test.eq('Q example 3: 10 days is $560 / 7 x 10 = $800, by the weekly rate; over 7 days the Deposit is charged, not held',
  (select (v ->> 'billable_days') || '/' || (v ->> 'rate_applied') || '/' || (v ->> 'rental_charge_cents') || '/' || (v ->> 'rate_rule') || '/' || (v ->> 'deposit_method')
     from test.out('q3') v), '10/weekly/' || test.money('800') || '/weekly rate divided by 7, times 10 days/charged');
select test.eq('Q example 4 (0132): 45 days is one booking at the monthly rate for each 30 days ($1,800 x 45 / 30 = $2,700)',
  (select (app.quote_booking(test.id('vehicle:BA1'), test.at('2029-05-07 09:00'), test.at('2029-06-21 09:00')) ->> 'rental_charge_cents')::bigint), test.money('2,700'));
select test.eq('Q example 4: 30 days at the monthly rate ($1,800), then a renewal of 15 days at $560 / 7 x 15 = $1,200: $3,000 over two transactions',
  (select (a ->> 'rate_applied') || ':' || (a ->> 'rental_charge_cents') || ' ' || (b ->> 'rate_applied') || ':' || (b ->> 'rental_charge_cents') || ' '
          || ((a ->> 'rental_charge_cents')::bigint + (b ->> 'rental_charge_cents')::bigint)
     from app.quote_booking(test.id('vehicle:BA1'), test.at('2029-05-07 09:00'), test.at('2029-06-06 09:00')) a,
          app.quote_booking(test.id('vehicle:BA1'), test.at('2029-06-06 09:00'), test.at('2029-06-21 09:00')) b),
  'monthly:' || test.money('1,800') || ' weekly:' || test.money('1,200') || ' ' || test.money('3,000'));
select test.eq('Q 7 to 29 days are capped at the monthly rate: 29 days is $2,320 by the weekly rule, charged $1,800',
  (select (v ->> 'rental_charge_cents') || '/' || (v ->> 'rate_capped') || '/' || (v ->> 'rate_rule')
     from app.quote_booking(test.id('vehicle:BA1'), test.at('2029-05-07 09:00'), test.at('2029-06-05 09:00')) v),
  test.money('1,800') || '/true/weekly rate divided by 7, times 29 days, capped at the monthly rate');
select test.eq('Q billable days round up: 3 days and one hour is 4 days',
  (select v ->> 'billable_days' from app.quote_booking(test.id('vehicle:BA1'), test.at('2029-05-07 09:00'), test.at('2029-05-10 10:00')) v), '4');

-- Section 1: the fees charged at booking, each with its cap
select test.keep('q5', app.quote_booking(test.id('vehicle:BA1'), test.at('2029-05-03 10:00'), test.at('2029-05-06 10:00'),
  '{"booking_type": "non_refundable", "pickup_method": "delivered", "return_method": "picked_up"}'));
select test.eq('Q the non-refundable discount is 10% of the rental charge only, never of the fees: $340 - $34 + $75 delivery + $75 pickup = $456 + HST $59.28',
  (select string_agg((l ->> 'charge_type') || '=' || (l ->> 'amount_cents') || '+' || (l ->> 'hst_cents'), ' ' order by o)
     from test.out('q5') v, jsonb_array_elements(v -> 'lines') with ordinality x(l, o))
  || ' ' || (select (v ->> 'subtotal_cents') || '/' || (v ->> 'hst_cents') || '/' || (v ->> 'total_cents') || '/' || (v ->> 'non_refundable_discount_cents') from test.out('q5') v),
  'rental_charge=34000+4420 non_refundable_discount=-3400+-442 delivery=7500+975 pickup=7500+975 45600/5928/51528/3400');
select test.keep('q6', app.quote_booking(test.id('vehicle:BAY'), test.at('2029-05-07 09:00'), test.at('2029-05-19 09:00'), jsonb_build_object(
  'drivers', jsonb_build_array(jsonb_build_object('age', 19, 'name', 'Yara Young'), jsonb_build_object('age', 23, 'name', 'Tom Twenty'),
                               jsonb_build_object('date_of_birth', '1980-01-01', 'name', 'Olga Older')),
  'extras', jsonb_build_object('winter_tire', true, 'baby_seats', 2))));
select test.eq('Q 12 days, every per-day fee at its cap per rental: young driver 18 to 20 $35 x 12 capped at $350; 21 to 25 $20 x 12 capped at $200; '
               || 'additional driver $10 x 12 capped at $70, per driver; winter tire $15 x 12 capped at $150; baby seat $15 x 12 capped at $75, per seat (0066)',
  (select string_agg((l ->> 'charge_type') || '=' || (l ->> 'amount_cents') || ':' || (l -> 'detail' ->> 'capped'), ' ' order by o)
     from test.out('q6') v, jsonb_array_elements(v -> 'lines') with ordinality x(l, o)),
  -- 0025: young driver fees have no maximum; the additional driver fee is 25% of the $100 daily rate a day, no maximum
  'rental_charge=96000:false young_driver_18_20=42000:false young_driver_21_25=24000:false additional_driver=30000:false additional_driver=30000:false winter_tire=15000:true baby_seat=15000:true');
select test.eq('Q each per-driver line names its driver and their age band',
  (select string_agg((l ->> 'description'), ' | ' order by o) from test.out('q6') v, jsonb_array_elements(v -> 'lines') with ordinality x(l, o)
    where l ->> 'charge_type' like 'young%'), 'Young driver, 18 to 20: Yara Young | Young driver, 21 to 25: Tom Twenty');
select test.eq('Q the total is the sum of the lines, HST per line: $2,520.00 + $327.60 (0025 fees, 0066 add-ons)',
  (select (v ->> 'subtotal_cents') || '/' || (v ->> 'hst_cents') || '/' || (v ->> 'total_cents') from test.out('q6') v), '252000/32760/284760');
select test.eq('Q the fees are per day: 3 days, a driver of 19 ($105) and one additional driver of 30 ($75: 25% of $100 a day, 0025), one baby seat ($45, 0066)',
  (select string_agg((l ->> 'charge_type') || '=' || (l ->> 'amount_cents') || ':' || (l -> 'detail' ->> 'capped'), ' ' order by o)
     from app.quote_booking(test.id('vehicle:BAY'), test.at('2029-05-07 09:00'), test.at('2029-05-10 09:00'),
            '{"drivers": [{"age": 19}, {"age": 30}], "extras": {"baby_seats": 1}}') v, jsonb_array_elements(v -> 'lines') with ordinality x(l, o)),
  'rental_charge=30000:false young_driver_18_20=10500:false additional_driver=7500:false baby_seat=4500:false');
select test.eq('Q a driver under 18 is a problem the quote names; a driver of 18 to 20 is not (0025: every car takes them)',
  (select string_agg(p ->> 'code', ',' order by p ->> 'code')
     from app.quote_booking(test.id('vehicle:BA1'), test.at('2029-05-07 09:00'), test.at('2029-05-10 09:00'), '{"drivers": [{"age": 19}, {"age": 17}]}') v,
          jsonb_array_elements(v -> 'problems') p), 'driver_under_minimum_age');
select test.eq('Q with no driver given the quote assumes one renter of 26 or over: no driver fee',
  (select (v -> 'drivers' -> 0 ->> 'assumed') || '/' || jsonb_array_length(v -> 'lines') from test.out('q1') v), 'true/1');
-- 0079 seeds a default Protection Plan price for every class and age band; this block tests the table without them
create table if not exists test.cov_0079 as select * from coverage_prices where false;
insert into test.cov_0079 select * from coverage_prices where note like 'Default of 0079%';
delete from coverage_prices where note like 'Default of 0079%';
-- coverage: a placeholder until an Admin prices it
select test.keep('q7', app.quote_booking(test.id('vehicle:BA1'), test.at('2029-05-03 10:00'), test.at('2029-05-06 10:00'), '{"coverage_option": 3}'));
select test.eq('Q (0025) coverage through CarmaCars is sold; with no default price: no line, no problem, the quote says it is priced in the offer',
  (select jsonb_array_length(v -> 'lines') || '/' || (v -> 'coverage' ->> 'option') || '/' || (v -> 'coverage' ->> 'sold_by_carmacars_available')
          || '/' || coalesce(v -> 'coverage' ->> 'sold_by_carmacars_price_cents', 'no price') || '/' || coalesce(v -> 'problems' -> 0 ->> 'code', 'no problem')
          || '/' || (v -> 'coverage' ->> 'price_note') from test.out('q7') v),
  '1/3/true/no price/no problem/Priced in your offer');
-- the 0079 defaults back for the later suites
insert into coverage_prices select * from test.cov_0079 on conflict (id) do nothing;
delete from test.cov_0079;
insert into vehicle_fee_overrides (vehicle_id, fee_type_code, amount_cents, reason, effective_from)
values (test.id('vehicle:BA2'), 'coverage_sold', 4500, 'test price', app.today()),
       (test.id('vehicle:BA2'), 'additional_driver', 1500, 'test price', app.today());
select test.eq('Q once an Admin sets a price (here per vehicle) the coverage line appears, with HST; and a per-vehicle fee replaces the default ($15 a day, cap $70)',
  (select string_agg((l ->> 'charge_type') || '=' || (l ->> 'amount_cents') || '+' || (l ->> 'hst_cents'), ' ' order by o) || ' ' || (v -> 'coverage' ->> 'sold_by_carmacars_available')
     from app.quote_booking(test.id('vehicle:BA2'), test.at('2029-05-07 09:00'), test.at('2029-05-10 09:00'),
            '{"coverage_option": 3, "drivers": [{"age": 40}, {"age": 41}]}') v, jsonb_array_elements(v -> 'lines') with ordinality x(l, o) group by v),
  'rental_charge=30000+3900 additional_driver=4500+585 coverage_sold=4500+585 true');
-- promo codes
insert into promo_codes (id, code, percent_bps, max_uses, source) values (test.id('promo:ba15'), 'BA15', 1500, 50, 'manual');
insert into promo_codes (code, percent_bps, valid_from, valid_until) values ('BAOLD', 1000, now() - interval '30 days', now() - interval '1 day');
select test.eq('Q a promo code that can be used comes off the rental charge as its own line; one that cannot is named with the reason and not applied',
  (select (a ->> 'promo_discount_cents') || '/' || (a -> 'promo' ->> 'applied') || '/' || (a ->> 'total_cents') || ' ' ||
          (b ->> 'promo_discount_cents') || '/' || (b -> 'promo' ->> 'applied') || '/' || (b -> 'promo' ->> 'problem') || '/' || (b ->> 'total_cents')
     from app.quote_booking(test.id('vehicle:BA1'), test.at('2029-05-03 10:00'), test.at('2029-05-06 10:00'), '{"promo_code": " ba15 "}') a,
          app.quote_booking(test.id('vehicle:BA1'), test.at('2029-05-03 10:00'), test.at('2029-05-06 10:00'), '{"promo_code": "BAOLD"}') b),
  '5100/true/32657 0/false/This code has expired/38420');
-- nothing is hard-coded: the tax rate and the discount come from the settings, the fees from their defaults
update program_settings set hst_bps = 1500, non_refundable_discount_bps = 2000 where effective_from = (select effective_from from app.settings());
select test.eq('Q the HST rate and the non-refundable discount are settings: at 15% and 20% the same quote follows',
  (select (v ->> 'non_refundable_discount_cents') || '/' || (v ->> 'hst_cents') || '/' || (v ->> 'total_cents')
     from app.quote_booking(test.id('vehicle:BA1'), test.at('2029-05-03 10:00'), test.at('2029-05-06 10:00'), '{"booking_type": "non_refundable"}') v),
  '6800/4080/31280');
update program_settings set hst_bps = 1300, non_refundable_discount_bps = 1000 where effective_from = (select effective_from from app.settings());
update fee_defaults set effective_to = app.today() where fee_type_code = 'young_driver_21_25' and effective_to is null;
insert into fee_defaults (fee_type_code, amount_cents, cap_cents, effective_from) values ('young_driver_21_25', 2500, 10000, app.today());
select test.eq('Q a fee default is a dated row: with a new one in force ($25 a day, cap $100) a 3-day quote and a 12-day quote follow',
  (select (select l ->> 'amount_cents' from jsonb_array_elements(a -> 'lines') l where l ->> 'charge_type' = 'young_driver_21_25') || '/' ||
          (select l ->> 'amount_cents' from jsonb_array_elements(b -> 'lines') l where l ->> 'charge_type' = 'young_driver_21_25')
     from app.quote_booking(test.id('vehicle:BA1'), test.at('2029-05-07 09:00'), test.at('2029-05-10 09:00'), '{"drivers": [{"age": 22}]}') a,
          app.quote_booking(test.id('vehicle:BA1'), test.at('2029-05-07 09:00'), test.at('2029-05-19 09:00'), '{"drivers": [{"age": 22}]}') b), '7500/10000');
delete from fee_defaults where fee_type_code = 'young_driver_21_25' and effective_from = app.today();
update fee_defaults set effective_to = null where fee_type_code = 'young_driver_21_25' and effective_to = app.today();
select test.throws('Q a quote is for a standard or a non-refundable booking',
  $$select app.quote_booking(test.id('vehicle:BA1'), test.at('2029-05-07 09:00'), test.at('2029-05-10 09:00'), '{"booking_type": "owner"}')$$, 'standard or a non-refundable');
select test.throws('Q the return must be after the pickup',
  $$select app.quote_booking(test.id('vehicle:BA1'), test.at('2029-05-07 09:00'), test.at('2029-05-07 09:00'))$$, 'after the pickup');
select test.eq('Q the server may price a car that is not on the public listing',
  (select v ->> 'rental_charge_cents' from app.quote_booking(test.id('vehicle:BAU'), test.at('2029-05-07 09:00'), test.at('2029-05-10 09:00')) v), '30000');

-- ------------------------------------------------------------------ search: listed cars that are free, with their total
select test.mk_booking('BASRCH', 'BA7', 'rita', '2029-05-08 10:00', '2029-05-09 10:00', 'confirmed');
update rate_cards set daily_rate_cents = 8000, weekend_rate_cents = 9000, weekly_rate_cents = 45000, monthly_rate_cents = 150000 where vehicle_id = test.id('vehicle:BA9');
select test.eq('SR every listed car that is free for the dates, cheapest first, each with its total for those dates ($240 + HST, then $300 + HST)',
  (select string_agg(slug || '=' || total_cents, ' ' order by total_cents, slug) from app.search_available(test.at('2029-05-07 09:00'), test.at('2029-05-10 09:00'))
    where slug like 'ba-%'),
  'ba-ba9=27120 ba-ba1=33900 ba-ba2=33900 ba-ba3=33900 ba-ba4=33900 ba-ba5=33900 ba-ba6=33900 ba-ba8=33900 ba-bap=33900 ba-bay=33900');
select test.eq('SR a car with a confirmed booking in the dates is not in the result; a car that is not listed never is',
  (select count(*) from app.search_available(test.at('2029-05-07 09:00'), test.at('2029-05-10 09:00')) where vehicle_id in (test.id('vehicle:BA7'), test.id('vehicle:BAU'))), 0::bigint);
select test.eq('SR the search total is the quote total',
  (select bool_and(s.total_cents = (app.quote_booking(s.vehicle_id, test.at('2029-05-07 09:00'), test.at('2029-05-10 09:00')) ->> 'total_cents')::bigint)
     from app.search_available(test.at('2029-05-07 09:00'), test.at('2029-05-10 09:00')) s), true);
select test.eq('SR filters: class; cars offered to drivers of 18 to 20 (0025: every car); a ceiling on the daily rate; and the quote options (a driver of 19)',
  (select string_agg(slug, ',') from app.search_available(test.at('2029-05-07 09:00'), test.at('2029-05-10 09:00'), '{"class": "economy"}') where slug like 'ba-%')
  || ' ' || (select string_agg(slug || '=' || total_cents, ',') from app.search_available(test.at('2029-05-07 09:00'), test.at('2029-05-10 09:00'),
                      '{"young": true, "options": {"drivers": [{"age": 19}]}}') where slug like 'ba-%')
  || ' ' || (select string_agg(slug, ',') from app.search_available(test.at('2029-05-07 09:00'), test.at('2029-05-10 09:00'), '{"max_daily_rate_cents": 9000}') where slug like 'ba-%'),
  'ba-ba9 ba-ba9=38985,ba-ba1=45765,ba-ba2=45765,ba-ba3=45765,ba-ba4=45765,ba-ba5=45765,ba-ba6=45765,ba-ba8=45765,ba-bap=45765,ba-bay=45765 ba-ba9');
select test.eq('SR it returns the car and the price only: no owner, plate, VIN or person',
  (select pg_get_function_result('app.search_available(timestamptz, timestamptz, jsonb)'::regprocedure) ~ '(owner|plate|vin|renter|fleet_number)'), false);
select test.throws('SR past the longest booking is refused', $$select * from app.search_available(test.at('2029-05-07 09:00'), test.at('2030-06-21 09:00'))$$, 'Shorten the dates');

-- ------------------------------------------------------------------ rate limits
select test.eq('RL a key is allowed its maximum in a window and no more; another key is not affected',
  app.rate_limit('ba:test:1', 2, interval '1 hour') || '/' || app.rate_limit('ba:test:1', 2, interval '1 hour') || '/'
  || app.rate_limit('ba:test:1', 2, interval '1 hour') || '/' || app.rate_limit('ba:test:2', 2, interval '1 hour'), 'true/true/false/true');
select test.eq('RL the counter keeps counting', (select hits from app.rate_limit_hits where key = 'ba:test:1'), 3);
select test.throws('RL a limit needs a key, a maximum and a window', $$select app.rate_limit('', 1, interval '1 hour')$$, 'needs a key');
update app.rate_limit_hits set window_start = window_start - interval '5 days' where key = 'ba:test:2';
select test.eq('RL counters nobody will read again are removed', app.rate_limit_purge(), 1);

-- ------------------------------------------------------------------ the public request
-- a date of birth that makes someone so many years (and six months) old today
create function test.dob(p_years integer) returns text
language sql stable as $$ select to_char(app.today() - make_interval(years => p_years, months => 6), 'YYYY-MM-DD') $$;
grant execute on function test.dob(integer) to authenticated, anon;

-- R1: a new customer, 10 days, delivered, one additional driver of 23, winter tires and one baby seat
select test.keep('r1', app.submit_booking_request(
  test.ba_req('r1', 'amy.adams@example.test', 'BA1', test.soon('10 days'), test.soon('20 days'), jsonb_build_object(
    'note', 'Arriving by train', 'pickup_method', 'delivered', 'pickup_place', '12 Elm St, Toronto',
    'additional_drivers', jsonb_build_array(jsonb_build_object('full_name', 'Andy Adams', 'date_of_birth', test.dob(23), 'email', 'andy.adams@example.test')),
    'extras', jsonb_build_object('winter_tire', true, 'baby_seats', 1),
    'details', jsonb_build_object('accepts_similar', true, 'landing_path', '/cars/ba-ba1'))),
  inet '203.0.113.5', 'Mozilla/5.0 (test)'));
insert into test.ba_ids values ('r1', (test.out('r1') ->> 'booking_id')::uuid);
select test.eq('R a request is accepted: a new account, a new booking in "requested", a booking number',
  (select (v ->> 'ok') || '/' || (v ->> 'created') || '/' || (v ->> 'new_account') || '/' || (v ->> 'status') || '/' || ((v ->> 'booking_number') like 'CC-%')
          || '/' || (v ->> 'conflict_at_submit') from test.out('r1') v), 'true/true/true/requested/true/false');
select test.eq('R the booking carries the trip, the note, the coverage option chosen and the request key',
  (select status || '/' || source || '/' || billable_days || '/' || pickup_method || '/' || pickup_place || '/' || request_note || '/' || coverage_option
          || '/' || request_key || '/' || (requested_at is not null) from bookings where id = test.ba('r1')),
  'requested/web/10/delivered/12 Elm St, Toronto/Arriving by train/2/ba-key-r1/true');
select test.eq('R no card and no payment are taken with a request',
  (select (select count(*) from payments where booking_id = b.id) || '/' || coalesce(b.card_on_file_id::text, 'no card')
          || '/' || (select count(*) from payment_methods pm where pm.renter_id = b.renter_id) from bookings b where b.id = test.ba('r1')), '0/no card/0');
select test.eq('R the user, the renter role, the renter and the renter as a driver are created and linked',
  (select u.full_name || '/' || u.email || '/' || u.status || '/' || (select string_agg(role::text, ',') from user_roles where user_id = u.id)
          || '/' || r.legal_name || '/' || r.mobile || '/' || d.full_name || '/' || d.is_account_holder || '/' || d.licence_class || '/' || (d.user_id = u.id)
     from bookings b join renters r on r.id = b.renter_id join users u on u.id = r.user_id join drivers d on d.renter_id = r.id and d.is_account_holder
    where b.id = test.ba('r1')), 'Amy Adams/amy.adams@example.test/active/renter/Amy Adams/416-555-0142/Amy Adams/true/G/true');
select test.eq('R the drivers are on the booking with their age band at pickup',
  (select string_agg(role || ':' || full_name || ':' || age_band || ':' || age_at_pickup, ' ' order by role desc) from booking_drivers where booking_id = test.ba('r1')),
  'renter:Amy Adams:26_plus:38 additional:Andy Adams:21_to_25:23');
select test.eq('R every line of the price is created with the request: rental (weekly rule, $800), delivery, the young driver and additional driver fees, winter tires, the baby seat',
  (select string_agg(charge_type || '=' || amount_cents || '+' || hst_cents, ' ' order by f.sort_order)
     from booking_line_items li join fee_types f on f.code = li.charge_type where li.booking_id = test.ba('r1') and li.voided_at is null),
  'rental_charge=80000+10400 delivery=7500+975 young_driver_21_25=20000+2600 additional_driver=25000+3250 winter_tire=15000+1950 baby_seat=7500+975');
select test.eq('R the per-driver lines carry their driver',
  (select count(*) filter (where li.driver_id is not null) || '/' || count(*) from booking_line_items li
    where li.booking_id = test.ba('r1') and li.charge_type in ('young_driver_21_25', 'additional_driver')), '2/2');
select test.eq('R the totals are the sum of the lines: $1,545.00 + HST $200.85 (0025 fees)',
  (select subtotal_at_booking_cents || '/' || hst_at_booking_cents || '/' || total_due_at_booking_cents || '/' || renter_due_at_booking_cents
     from bookings where id = test.ba('r1')), '155000/20150/175150/175150');
select test.eq('R the quote for the same choices and the booking agree, line by line and in total',
  (select (q ->> 'total_cents')::bigint = b.total_due_at_booking_cents
          and (select string_agg((l ->> 'charge_type') || '=' || (l ->> 'amount_cents') || '+' || (l ->> 'hst_cents'), ' ' order by o)
                 from jsonb_array_elements(q -> 'lines') with ordinality x(l, o))
            = (select string_agg(charge_type || '=' || amount_cents || '+' || hst_cents, ' ' order by f.sort_order)
                 from booking_line_items li join fee_types f on f.code = li.charge_type where li.booking_id = b.id and li.voided_at is null)
     from bookings b,
          app.quote_booking(b.vehicle_id, b.pickup_at, b.return_at, jsonb_build_object('pickup_method', 'delivered',
            'drivers', jsonb_build_array(jsonb_build_object('date_of_birth', '1988-04-04'), jsonb_build_object('date_of_birth', test.dob(23))),
            'extras', jsonb_build_object('winter_tire', true, 'baby_seats', 1))) q
    where b.id = test.ba('r1')), true);
select test.eq('R the fee terms of the booking are snapshotted with where each came from',
  (select count(*) || '/' || string_agg(fee_type_code || '=' || coalesce(amount_cents::text, 'not priced') || ':' || coalesce(cap_cents::text, '-') || ':' || source, ' ' order by fee_type_code)
     from booking_fee_terms where booking_id = test.ba('r1')),
  '6/additional_driver=not priced:-:default baby_seat=1500:7500:default coverage_sold=not priced:-:default winter_tire=1500:15000:default young_driver_18_20=3500:-:default young_driver_21_25=2000:-:default');
select test.eq('R the request as sent is kept on the booking: extras, what else the customer said, the consent versions, the flags',
  (select (d -> 'extras' ->> 'winter_tire') || '/' || (d -> 'extras' ->> 'baby_seats') || '/' || (d ->> 'accepts_similar') || '/' || (d ->> 'landing_path')
          || '/' || (d ->> 'terms_version') || '/' || (d ->> 'privacy_version') || '/' || (d ->> 'marketing_opt_in') || '/' || (d ->> 'conflict_at_submit')
          || '/' || (d ->> 'licence_needs_review') || '/' || (d ->> 'coverage_option') || '/' || jsonb_array_length(d -> 'drivers') || '/' || ((d ->> 'terms_accepted_at') is not null)
     from bookings b, lateral (select b.request_details as d) x where b.id = test.ba('r1')),
  'true/1/true//cars/ba-ba1/terms-2026-10/privacy-2026-10/false/false/false/2/2/true');
select test.eq('R dates of birth, licence details and contact details are not copied into the request snapshot (fewer staff may read the driver records)',
  (select request_details::text ~ '(date_of_birth|@|416-555|licence_class)' from bookings where id = test.ba('r1')), false);
select test.eq('R the Terms and the Privacy Policy are each recorded: wording, version, when, network address and browser',
  (select string_agg(consent_code || ':' || text_version || ':' || (text_shown like 'I %') || ':' || host(ip_address) || ':' || user_agent || ':' || (given_at is not null), ' ' order by consent_code)
     from consents where booking_id = test.ba('r1')),
  'privacy_policy:privacy-2026-10:true:203.0.113.5:Mozilla/5.0 (test):true terms_of_use:terms-2026-10:true:203.0.113.5:Mozilla/5.0 (test):true');
select test.eq('R no marketing consent is recorded when the box was left unticked',
  (select u.marketing_opt_in || '/' || coalesce(u.marketing_opt_in_at::text, 'never') || '/' || (select count(*) from consents c where c.user_id = u.id and c.consent_code = 'marketing')
     from users u where u.id = test.ba_user('amy.adams@example.test')), 'false/never/0');
select test.eq('R the request is in the history as the renter''s act, and customer service has its task',
  (select string_agg(kind || ':' || actor_type, ',') from booking_events where booking_id = test.ba('r1'))
  || ' ' || (select count(*) || ':' || min(queue) from tasks where booking_id = test.ba('r1') and task_type = 'booking_request'), 'requested:renter 1:cs');

-- idempotency
select test.keep('r1b', app.submit_booking_request(test.ba_req('r1', 'someone.else@example.test', 'BA2', test.soon('12 days'), test.soon('15 days'))));
select test.eq('R a second submit with the same request key creates nothing and returns the first booking',
  (select (v ->> 'ok') || '/' || (v ->> 'created') || '/' || ((v ->> 'booking_id')::uuid = test.ba('r1')) from test.out('r1b') v)
  || '/' || (select count(*) from bookings where request_key = 'ba-key-r1') || '/' || (select count(*) from users where email = 'someone.else@example.test')
  || '/' || (select count(*) from consents where booking_id = test.ba('r1')), 'true/false/true/1/0/2');
select test.throws('R the request key is unique in the table itself',
  $$update bookings set request_key = 'ba-key-r1' where id = (select id from bookings where request_key is null limit 1)$$, 'bookings_request_key_key');
select test.throws('R a request without its key is refused',
  $$select app.submit_booking_request(test.ba_req('x', 'x.y@example.test', 'BA1', test.soon('10 days'), test.soon('12 days')) - 'request_key')$$, 'request key');

-- the marketing opt-in: separate, optional, with its own wording version and time
select test.ba_new('r2', 'ben.brown@example.test', 'BA1', test.soon('10 days'), test.soon('17 days'), jsonb_build_object('consents', jsonb_build_object(
  'terms', jsonb_build_object('accepted', true, 'version', 'terms-2026-10', 'text', 'I am 18 or older and agree to the Terms of Use.'),
  'privacy', jsonb_build_object('accepted', true, 'version', 'privacy-2026-10', 'text', 'I agree to the Privacy Policy.'),
  'marketing', jsonb_build_object('opted_in', true, 'version', 'marketing-2026-10', 'text', 'Send me CarmaCars offers and news. I can unsubscribe at any time.'))));
select test.eq('R a marketing opt-in is its own consent row with its wording version and time, and sets the account''s opt-in',
  (select c.consent_code || '/' || c.text_version || '/' || (c.text_shown like 'Send me CarmaCars%') || '/' || (c.given_at is not null) || '/' || u.marketing_opt_in || '/' || (u.marketing_opt_in_at is not null)
     from consents c join users u on u.id = c.user_id where c.booking_id = test.ba('r2') and c.consent_code = 'marketing'),
  'marketing/marketing-2026-10/true/true/true/true');
select test.eq('R three consent rows on that request: terms, privacy, marketing', (select count(*) from consents where booking_id = test.ba('r2')), 3::bigint);
select test.throws('R an opt-in without the wording shown is refused',
  $$select app.submit_booking_request(test.ba_req('x1', 'x.one@example.test', 'BA1', test.soon('10 days'), test.soon('12 days'),
      '{"consents": {"terms": {"accepted": true, "version": "t", "text": "t"}, "privacy": {"accepted": true, "version": "p", "text": "p"}, "marketing": {"opted_in": true}}}'))$$,
  'marketing opt-in is recorded with the version');

-- validation
select test.throws('R the Terms of Use must be accepted',
  $$select app.submit_booking_request(test.ba_req('x2', 'x.two@example.test', 'BA1', test.soon('10 days'), test.soon('12 days'),
      '{"consents": {"terms": {"accepted": false, "version": "t", "text": "t"}, "privacy": {"accepted": true, "version": "p", "text": "p"}}}'))$$, 'Terms of Use must be accepted');
select test.throws('R and the Privacy Policy',
  $$select app.submit_booking_request(test.ba_req('x3', 'x.three@example.test', 'BA1', test.soon('10 days'), test.soon('12 days'),
      '{"consents": {"terms": {"accepted": true, "version": "t", "text": "t"}}}'))$$, 'Privacy Policy must be accepted');
select test.throws('R minimum notice: a pickup an hour from now is refused (2 hours by default)',
  $$select app.submit_booking_request(test.ba_req('x4', 'x.four@example.test', 'BA1', now() + interval '1 hour', now() + interval '2 days'))$$, 'at least 120 minutes from now');
update program_settings set booking_min_notice_minutes = 2880 where effective_from = (select effective_from from app.settings());
select test.throws('R the notice is a setting: at 48 hours a pickup tomorrow is refused',
  $$select app.submit_booking_request(test.ba_req('x5', 'x.five@example.test', 'BA1', now() + interval '1 day', now() + interval '3 days'))$$, 'at least 2880 minutes from now');
update program_settings set booking_min_notice_minutes = 120 where effective_from = (select effective_from from app.settings());
select test.throws('R the return must be after the pickup',
  $$select app.submit_booking_request(test.ba_req('x6', 'x.six@example.test', 'BA1', test.soon('10 days'), test.soon('10 days')))$$, 'after the pickup');
select test.throws('R the maximum length is a setting (365 days): 400 days is refused',
  $$select app.submit_booking_request(test.ba_req('x7', 'x.seven@example.test', 'BA1', test.soon('10 days'), test.soon('410 days')))$$, '1 to 365 days');
update program_settings set max_rental_days = 14 where effective_from = (select effective_from from app.settings());
select test.throws('R with the maximum set to 14 days, 15 days is refused',
  $$select app.submit_booking_request(test.ba_req('x8', 'x.eight@example.test', 'BA1', test.soon('10 days'), test.soon('25 days')))$$, '1 to 14 days');
update program_settings set max_rental_days = 30 where effective_from = (select effective_from from app.settings());
select test.throws('R a renter under 18 at pickup is refused',
  $$select app.submit_booking_request(test.ba_req('x9', 'x.nine@example.test', 'BAY', test.soon('10 days'), test.soon('12 days'),
      jsonb_build_object('renter', jsonb_build_object('date_of_birth', test.dob(17)))))$$, '18 or older at pickup');
select test.lives('R (0025) a renter of 18 to 20 is accepted on any car',
  $$select app.submit_booking_request(test.ba_req('x10', 'x.ten@example.test', 'BA1', test.soon('10 days'), test.soon('12 days'),
      jsonb_build_object('renter', jsonb_build_object('date_of_birth', test.dob(19)))))$$);
select test.lives('R (0025) so is an additional driver of 18 to 20',
  $$select app.submit_booking_request(test.ba_req('x11', 'x.eleven@example.test', 'BA1', test.soon('10 days'), test.soon('12 days'),
      jsonb_build_object('additional_drivers', jsonb_build_array(jsonb_build_object('full_name', 'Kid K', 'date_of_birth', test.dob(19), 'email', 'kid@example.test')))))$$);
select test.throws('R a G1 licence is refused: class G or G2',
  $$select app.submit_booking_request(test.ba_req('x12', 'x.twelve@example.test', 'BA1', test.soon('10 days'), test.soon('12 days'),
      '{"renter": {"licence_class": "G1"}}'))$$, 'class G or G2 licence is needed');
select test.throws('R a licence from elsewhere needs its issuer',
  $$select app.submit_booking_request(test.ba_req('x13', 'x.thirteen@example.test', 'BA1', test.soon('10 days'), test.soon('12 days'),
      '{"renter": {"licence_class": "other", "licence_issuer": ""}}'))$$, 'class G or G2 licence is needed');
select test.throws('R the licence class is required',
  $$select app.submit_booking_request(test.ba_req('x14', 'x.fourteen@example.test', 'BA1', test.soon('10 days'), test.soon('12 days'),
      '{"renter": {"licence_class": ""}}'))$$, 'licence class is needed');
select test.throws('R a car that is not on the public listing cannot be requested',
  $$select app.submit_booking_request(test.ba_req('x15', 'x.fifteen@example.test', 'BAU', test.soon('10 days'), test.soon('12 days')))$$, 'not available to book');
select test.throws('R at most 4 additional drivers',
  $$select app.submit_booking_request(test.ba_req('x16', 'x.sixteen@example.test', 'BA1', test.soon('10 days'), test.soon('12 days'),
      jsonb_build_object('additional_drivers', (select jsonb_agg(jsonb_build_object('full_name', 'Driver ' || i, 'date_of_birth', '1980-01-0' || i, 'email', 'd' || i || '@example.test')) from generate_series(1, 5) i))))$$,
  'up to 4 additional drivers');
select test.throws('R the same driver cannot be named twice',
  $$select app.submit_booking_request(test.ba_req('x17', 'x.seventeen@example.test', 'BA1', test.soon('10 days'), test.soon('12 days'),
      '{"additional_drivers": [{"full_name": "Dee Dee", "date_of_birth": "1980-01-01", "email": "dee@example.test"}, {"full_name": "dee  dee", "date_of_birth": "1980-01-01", "email": "dee2@example.test"}]}'))$$,
  'named twice');
select test.throws('R an additional driver needs a name, a date of birth and an email address',
  $$select app.submit_booking_request(test.ba_req('x18', 'x.eighteen@example.test', 'BA1', test.soon('10 days'), test.soon('12 days'),
      '{"additional_drivers": [{"full_name": "Dee Dee", "date_of_birth": "1980-01-01"}]}'))$$, 'full name, a date of birth and an email');
select test.throws('R a coverage option must be chosen',
  $$select app.submit_booking_request(test.ba_req('x19', 'x.nineteen@example.test', 'BA1', test.soon('10 days'), test.soon('12 days')) - 'coverage_option')$$, 'option 1, 2 or 3');
select test.lives('R (0025) coverage through CarmaCars may be chosen before it has a price: it is priced in the offer',
  $$select app.submit_booking_request(test.ba_req('x20', 'x.twenty@example.test', 'BA1', test.soon('10 days'), test.soon('12 days'), '{"coverage_option": 3}'))$$);
select test.throws('R a delivery needs its address',
  $$select app.submit_booking_request(test.ba_req('x21', 'x.twentyone@example.test', 'BA1', test.soon('10 days'), test.soon('12 days'), '{"pickup_method": "delivered"}'))$$, 'needs its address');
select test.throws('R the note has a maximum length (500 characters, a setting)',
  $$select app.submit_booking_request(test.ba_req('x22', 'x.twentytwo@example.test', 'BA1', test.soon('10 days'), test.soon('12 days'), jsonb_build_object('note', repeat('x', 501))))$$,
  'at most 500 characters');
select test.throws('R at most 3 baby seats',
  $$select app.submit_booking_request(test.ba_req('x23', 'x.twentythree@example.test', 'BA1', test.soon('10 days'), test.soon('12 days'), '{"extras": {"baby_seats": 4}}'))$$, 'up to 3 baby seats');
select test.throws('R a valid email address is needed',
  $$select app.submit_booking_request(test.ba_req('x24', 'not-an-email', 'BA1', test.soon('10 days'), test.soon('12 days')))$$, 'valid email');
select test.eq('R a refused request leaves nothing behind: no user, no booking',
  (select count(*) from users where email like 'x.%@example.test' and email not in ('x.ten@example.test', 'x.eleven@example.test', 'x.twenty@example.test'))
  + (select count(*) from bookings b join renters r on r.id = b.renter_id join users u on u.id = r.user_id
      where b.request_key like 'ba-key-x%' and u.email not in ('x.ten@example.test', 'x.eleven@example.test', 'x.twenty@example.test')), 0::bigint);

-- a licence from elsewhere, a young driver, and coverage once priced
select test.ba_new('r3', 'cat.clark@example.test', 'BAY', test.soon('10 days'), test.soon('13 days'),
  jsonb_build_object('renter', jsonb_build_object('date_of_birth', test.dob(19), 'licence_class', 'other', 'licence_issuer', 'Quebec')));
select test.eq('R a licence from another province is accepted with its issuer and flagged for staff to confirm',
  (select (v ->> 'ok') || '/' || (v ->> 'licence_needs_review') from test.out('new:r3') v)
  || '/' || (select (request_details ->> 'licence_needs_review') from bookings where id = test.ba('r3'))
  || '/' || (select d.licence_class || ':' || d.licence_issuer from drivers d join bookings b on b.renter_id = d.renter_id where b.id = test.ba('r3')), 'true/true/true/OTHER:Quebec');
select test.eq('R a renter of 19 on a car offered to them: the young driver fee for 18 to 20 is on the booking ($35 x 3 days)',
  (select string_agg(charge_type || '=' || amount_cents, ' ' order by amount_cents desc) from booking_line_items
    where booking_id = test.ba('r3') and voided_at is null and charge_type <> 'rental_charge')
  || '/' || (select age_band from booking_drivers where booking_id = test.ba('r3')), 'young_driver_18_20=10500/18_to_20');
select test.ba_new('r4', 'dan.drake@example.test', 'BA2', test.soon('10 days'), test.soon('17 days'), '{"coverage_option": 3, "booking_type": "non_refundable"}');
select test.eq('R coverage through CarmaCars, once priced for the car, is a line of the request; a non-refundable request carries its 10% discount',
  (select string_agg(charge_type || '=' || amount_cents, ' ' order by f.sort_order) from booking_line_items li join fee_types f on f.code = li.charge_type
    where li.booking_id = test.ba('r4') and li.voided_at is null)
  || '/' || (select booking_type || ':' || coverage_option || ':' || total_due_at_booking_cents from bookings where id = test.ba('r4')),
  'rental_charge=56000 non_refundable_discount=-5600 coverage_sold=4500/non_refundable:3:62037');

-- an existing account
select test.ba_new('r5', 'AMY.ADAMS@example.test', 'BA3', test.soon('30 days'), test.soon('33 days'),
  '{"renter": {"full_name": "Amy Impostor", "date_of_birth": "1970-01-01", "mobile": "999-999-9999"}}');
select test.eq('R a request with the email of an existing account is attached to it, and does not create a second account',
  (select (v ->> 'ok') || '/' || (v ->> 'new_account') || '/' || ((v ->> 'renter_id')::uuid = (select renter_id from bookings where id = test.ba('r1'))) from test.out('new:r5') v)
  || '/' || (select count(*) from users where lower(email) = 'amy.adams@example.test'), 'true/false/true/1');
select test.eq('R what an unsigned-in visitor typed does not overwrite the record: name, date of birth and mobile stay; the difference is flagged for staff',
  (select r.legal_name || '/' || r.mobile || '/' || d.full_name || '/' || d.date_of_birth || '/' || (b.request_details ->> 'details_differ_from_record')
     from bookings b join renters r on r.id = b.renter_id join booking_drivers d on d.booking_id = b.id and d.role = 'renter' where b.id = test.ba('r5')),
  'Amy Adams/416-555-0142/Amy Adams/1988-04-04/true');
select test.keep('r6', app.submit_booking_request(
  test.ba_req('r6', 'whatever@example.test', 'BA4', test.soon('40 days'), test.soon('43 days'), '{"renter": {"mobile": "647-555-0111"}}'),
  null, null, test.ba_user('amy.adams@example.test')));
insert into test.ba_ids values ('r6', (test.out('r6') ->> 'booking_id')::uuid);
select test.eq('R a signed-in customer''s request uses their own record whatever the form says, and may update their mobile number',
  (select ((v ->> 'renter_id')::uuid = (select renter_id from bookings where id = test.ba('r1'))) || '/' || (v ->> 'new_account') from test.out('r6') v)
  || '/' || (select r.mobile from renters r join bookings b on b.renter_id = r.id where b.id = test.ba('r6'))
  || '/' || (select count(*) from users where email = 'whatever@example.test'), 'true/false/647-555-0111/0');

-- limits
select test.keep('r7', app.submit_booking_request(test.ba_req('r7', 'amy.adams@example.test', 'BA5', test.soon('50 days'), test.soon('53 days'))));
select test.eq('R one customer may have 3 requests open: the fourth is refused with a result, and nothing is written',
  (select (v ->> 'ok') || '/' || (v ->> 'error') from test.out('r7') v) || '/' || (select count(*) from bookings where request_key = 'ba-key-r7'), 'false/too_many_open_requests/0');
update program_settings set booking_open_request_limit = 4 where effective_from = (select effective_from from app.settings());
select test.eq('R the limit is a setting: at 4 the same request is accepted',
  (select v ->> 'ok' from app.submit_booking_request(test.ba_req('r7', 'amy.adams@example.test', 'BA5', test.soon('50 days'), test.soon('53 days'))) v), 'true');
update program_settings set booking_open_request_limit = 3 where effective_from = (select effective_from from app.settings());
select test.eq('R five requests an hour are accepted from one network address',
  (select string_agg(app.submit_booking_request(test.ba_req('ip' || i, 'ip' || i || '.user@example.test', 'BA6', test.soon('10 days'), test.soon('12 days')),
                                                inet '198.51.100.7', 'bot') ->> 'ok', ',' order by i) from generate_series(1, 5) i), 'true,true,true,true,true');
select test.keep('ip6', app.submit_booking_request(test.ba_req('ip6', 'ip6.user@example.test', 'BA6', test.soon('10 days'), test.soon('12 days')), inet '198.51.100.7', 'bot'));
select test.eq('R the sixth is refused with a result (so the count is kept), and nothing else is written',
  (select (v ->> 'ok') || '/' || (v ->> 'error') from test.out('ip6') v) || '/' || (select count(*) from bookings where request_key = 'ba-key-ip6')
  || '/' || (select count(*) from users where email = 'ip6.user@example.test') || '/' || (select hits from app.rate_limit_hits where key = 'booking_request:ip:198.51.100.7'),
  'false/rate_limited/0/0/6');
select test.eq('R another network address is not affected, and a repeat of an accepted request is not counted',
  (select v ->> 'ok' from app.submit_booking_request(test.ba_req('ip6', 'ip6.user@example.test', 'BA6', test.soon('10 days'), test.soon('12 days')), inet '198.51.100.8', 'ok') v)
  || '/' || (select v ->> 'created' from app.submit_booking_request(test.ba_req('ip1', 'ip1.user@example.test', 'BA6', test.soon('10 days'), test.soon('12 days')), inet '198.51.100.7', 'bot') v)
  || '/' || (select hits from app.rate_limit_hits where key = 'booking_request:ip:198.51.100.7'), 'true/false/6');

-- promo codes, a blocked customer, a conflict at submit
select test.ba_new('r8', 'eve.evans@example.test', 'BA3', test.soon('10 days'), test.soon('20 days'), '{"promo_code": "BAOLD"}');
select test.ba_new('r9', 'eve.evans@example.test', 'BA3', test.soon('22 days'), test.soon('32 days'), '{"promo_code": "ba15", "referred_by_code": "NOBODY"}');
select test.eq('R a promo code that cannot be used does not stop the request: the reason is returned and kept; a good one is applied (15% of $800)',
  (select (a ->> 'ok') || '/' || (a ->> 'promo_problem') || '/' || (select promo_discount_cents || ':' || (request_details ->> 'promo_problem') from bookings where id = test.ba('r8'))
          || ' ' || (b ->> 'ok') || '/' || coalesce(b ->> 'promo_problem', 'applied') || '/' || (select promo_discount_cents || ':' || total_due_at_booking_cents || ':' || referred_by_code from bookings where id = test.ba('r9'))
     from test.out('new:r8') a, test.out('new:r9') b),
  'true/This code has expired/0:This code has expired true/applied/12000:76840:NOBODY');
update renters set is_blocked = true, blocked_reason = 'test' where user_id = test.ba_user('eve.evans@example.test');
select test.ba_new('r10', 'eve.evans@example.test', 'BA3', test.soon('60 days'), test.soon('63 days'));
select test.eq('R a blocked customer sees the normal result; an Admin gets the task',
  (select v ->> 'ok' from test.out('new:r10') v) || '/' || (select count(*) || ':' || min(queue) || ':' || min(priority) from tasks where booking_id = test.ba('r10') and task_type = 'blocked_renter_request'),
  'true/1:admin:high');
update renters set is_blocked = false, blocked_reason = null where user_id = test.ba_user('eve.evans@example.test');
select test.ba_new('r11', 'fay.fox@example.test', 'BA7', test.at('2029-05-08 12:00'), test.at('2029-05-11 12:00'));
select test.eq('R dates that another booking has confirmed are still accepted as a request, flagged for staff',
  (select (v ->> 'ok') || '/' || (v ->> 'conflict_at_submit') from test.out('new:r11') v) || '/' || (select request_details ->> 'conflict_at_submit' from bookings where id = test.ba('r11')),
  'true/true/true');

-- ------------------------------------------------------------------ request, offer, approve, sign, pay, confirmed
-- F1: 7 days ($560) with one additional driver (0025: 25% of $100 = $25 x 7 = $175): $735 + HST $95.55 = $830.55
select test.ba_new('f1', 'gus.green@example.test', 'BA8', test.soon('10 days'), test.soon('17 days'),
  '{"additional_drivers": [{"full_name": "Gina Green", "date_of_birth": "1985-02-02", "email": "gina.green@example.test"}]}');
select test.eq('F the request is priced: $830.55 due at booking', (select total_due_at_booking_cents from bookings where id = test.ba('f1')), 83055::bigint);
select test.throws('F an agreement cannot be opened on a request', $$select test.ba_open('f1')$$, 'opened once the offer is approved');
select test.eq('F customer service sends the offer: version 1', app.send_offer(test.ba('f1'), test.id('ba_cs'), 'Hello Gus, here is your offer.'), 1);
select test.throws('F nor while the offer is still with the renter', $$select test.ba_open('f1')$$, 'opened once the offer is approved');
select app.approve_offer(test.ba('f1'), 1, test.ba_user('gus.green@example.test'));
select test.eq('F a payment before there is an agreement is refused, with the instruction to void the authorization',
  (select (v ->> 'ok') || '/' || (v ->> 'reason') || '/' || (v ->> 'action') from test.ba_pay('f1') v) || '/' || test.ba_st('f1')
  || '/' || (select count(*) from payments where booking_id = test.ba('f1')), 'false/agreement_not_signed/void_authorization/pending_payment/0');
select test.throws('F an agreement needs the hash of the rendered document',
  $$select app.open_rental_agreement(test.ba('f1'), test.ba_user('gus.green@example.test'), 'rental-v2-2026-10', 'not-a-hash', 'bookings/f1/a.pdf')$$, 'SHA-256');
select test.throws('F and only the renter or staff open it',
  $$select app.open_rental_agreement(test.ba('f1'), test.ba_user('amy.adams@example.test'), 'rental-v2-2026-10', test.sha('x'), 'bookings/f1/a.pdf')$$, 'Only the renter of this booking, or staff');
insert into test.ba_ids values ('f1:ag', test.ba_open('f1'));
select test.eq('F the agreement is open for the approved offer version, with its number, the exact text version and the hash of the rendered document',
  (select a.status || '/' || a.offer_version || '/' || (a.agreement_number like 'RA-%') || '/' || a.template_version || '/' || (a.document_sha256 = test.sha('agreement of f1 v1'))
          || '/' || (b.agreement_number = a.agreement_number) || '/' || (b.signature_request_id = a.signature_request_id) || '/' || (b.agreement_document_id = a.document_id)
     from rental_agreements a join bookings b on b.id = a.booking_id where a.id = test.ba('f1:ag')), 'open/1/true/rental-v2-2026-10/true/true/true/true');
select test.eq('F it is a signature request of the built-in signing, on a rental agreement document with the same hash',
  (select s.provider || '/' || s.status || '/' || d.kind || '/' || d.storage_bucket || '/' || (d.sha256 = a.document_sha256) || '/' || d.template_version || '/' || d.retention
     from rental_agreements a join signature_requests s on s.id = a.signature_request_id join documents d on d.id = a.document_id where a.id = test.ba('f1:ag')),
  'builtin/sent/rental_agreement/agreements/true/rental-v2-2026-10/records_7y');
select test.eq('F every driver who must sign has a signer row, and so has CarmaCars, in the name of the staff member who sent the offer',
  (select string_agg(signer_role || ':' || signer_name || ':' || required_before_payment || ':' || (signed_at is null), ' '
                     order by case signer_role when 'renter' then 1 when 'additional_driver' then 2 else 3 end)
     from rental_agreement_signers where agreement_id = test.ba('f1:ag')),
  'renter:Gus Green:true:true additional_driver:Gina Green:false:true carmacars:Ba Cs:false:true');
select test.eq('F the countersigner is the staff member who sent the offer',
  (select (countersigner_user_id = test.id('ba_cs')) || '/' || countersigner_name from rental_agreements where id = test.ba('f1:ag')), 'true/Ba Cs');
select test.eq('F opening it again with the same document returns the same agreement',
  (test.ba_open('f1') = test.ba('f1:ag')) || '/' || (select count(*) from rental_agreements where booking_id = test.ba('f1')), 'true/1');
select test.eq('F the additional driver is told their agreement is ready (the renter is in the middle of checkout and is not)',
  (select string_agg((payload ->> 'signer_role') || ':' || (payload ->> 'signer_email') || ':' || (dedupe_key like 'renter_agreement_ready:' || entity_id || ':%'), ',')
     from app_events where code = 'renter_agreement_ready' and entity_id = test.ba('f1:ag')), 'additional_driver:gina.green@example.test:true');
select test.eq('F still no payment while the agreement is not signed',
  (select (v ->> 'reason') || '/' || (v ->> 'action') from test.ba_pay('f1') v), 'agreement_not_signed/void_authorization');

-- signing
create function test.ba_signer(p_key text, p_role text) returns uuid language sql stable as $$
  select g.id from rental_agreement_signers g join rental_agreements a on a.id = g.agreement_id
   where a.booking_id = test.ba(p_key) and a.status <> 'voided' and g.signer_role = p_role order by g.created_at limit 1
$$;
create function test.ba_sigreq(p_key text) returns uuid language sql stable as $$
  select a.signature_request_id from rental_agreements a where a.booking_id = test.ba(p_key) and a.status <> 'voided'
$$;
grant execute on function test.ba_signer(text, text), test.ba_sigreq(text) to authenticated, anon;
select test.throws('SG a typed name must be the signer''s own',
  $$select app.record_signature(test.ba_sigreq('f1'), test.ba_signer('f1', 'renter'), 'Somebody Else', null, '203.0.113.50', 'ua', 'I sign.')$$, 'must be the signer''s full legal name');
select test.throws('SG a signature is a drawing or a typed name',
  $$select app.record_signature(test.ba_sigreq('f1'), test.ba_signer('f1', 'renter'), ' ', null, '203.0.113.50', 'ua', 'I sign.')$$, 'drawing a signature or by typing');
select test.throws('SG the statement agreed to is part of the record',
  $$select app.record_signature(test.ba_sigreq('f1'), test.ba_signer('f1', 'renter'), 'Gus Green', null, '203.0.113.50', 'ua', '  ')$$, 'statement the signer agreed to');
select test.throws('SG signing a document other than the one on record is refused',
  $$select app.record_signature(test.ba_sigreq('f1'), test.ba_signer('f1', 'renter'), 'Gus Green', null, '203.0.113.50', 'ua', 'I sign.', test.sha('another document'))$$,
  'document changed');
select test.throws('SG nobody signs for CarmaCars by hand', 
  $$select app.record_signature(test.ba_sigreq('f1'), test.ba_signer('f1', 'carmacars'), 'Ba Cs', null, '203.0.113.50', 'ua', 'I sign.')$$, 'applied when the booking is confirmed');
select test.throws('SG a signer of another agreement cannot sign this one',
  $$select app.record_signature(test.ba_sigreq('f1'), gen_random_uuid(), 'Gus Green', null, '203.0.113.50', 'ua', 'I sign.')$$, 'not on this agreement');
insert into test.ba_ids values ('f1:sig', app.record_signature(test.ba_sigreq('f1'), test.ba_signer('f1', 'renter'), '  gus   GREEN ', null,
  inet '203.0.113.50', 'Mozilla/5.0 (phone)', 'I have read this Rental Agreement and I sign it electronically.', test.sha('agreement of f1 v1'),
  '[{"code": "tracking_disabling", "version": "consents-2026-10", "text": "I consent to GPS tracking of the Vehicle."},
    {"code": "identity_verification", "version": "consents-2026-10", "text": "I consent to CarmaCars verifying my identity."},
    {"code": "electronic_signature", "version": "consents-2026-10", "text": "I agree to sign electronically."},
    {"code": "card_authorization", "version": "consents-2026-10", "text": "I authorize charges to my Card on File."}]'));
select test.eq('SG the signature is a record of who, when, how, from where, the statement agreed to and the hash of the document signed',
  (select signer_role || '/' || signer_name || '/' || status || '/' || method || '/' || typed_name || '/' || host(ip_address) || '/' || user_agent
          || '/' || consent_text || '/' || (document_sha256 = test.sha('agreement of f1 v1')) || '/' || (signed_at is not null) || '/' || (signer_user_id = test.ba_user('gus.green@example.test'))
     from signature_records where id = test.ba('f1:sig')),
  'renter/Gus Green/signed/typed/gus   GREEN/203.0.113.50/Mozilla/5.0 (phone)/I have read this Rental Agreement and I sign it electronically./true/true/true');
select test.eq('SG the agreement is signed by the renter; the request is partly signed',
  (select a.status || '/' || (a.renter_signed_at is not null) || '/' || s.status from rental_agreements a join signature_requests s on s.id = a.signature_request_id
    where a.id = test.ba('f1:ag')), 'signed/true/partially_signed');
select test.eq('SG the four booking consents ticked at signing are recorded, each with its wording and version, against the booking and the driver',
  (select count(*) || '/' || count(distinct consent_code) || '/' || bool_and(driver_id is not null and text_version = 'consents-2026-10' and ip_address = inet '203.0.113.50')
     from consents where booking_id = test.ba('f1') and consent_code in ('tracking_disabling', 'identity_verification', 'electronic_signature', 'card_authorization')), '4/4/true');
select test.throws('SG nobody signs twice',
  $$select app.record_signature(test.ba_sigreq('f1'), test.ba_signer('f1', 'renter'), 'Gus Green', null, '203.0.113.50', 'ua', 'I sign.')$$, 'already signed');
select test.throws('SG a signature record is append-only: it cannot be changed',
  format($$update signature_records set signer_name = 'X' where id = %L$$, test.ba('f1:sig')), 'append-only');
select test.throws('SG nor removed', format($$delete from signature_records where id = %L$$, test.ba('f1:sig')), 'append-only');

-- payment
select test.eq('P an amount other than what the renter owes at booking is refused, saying what is owed',
  (select (v ->> 'ok') || '/' || (v ->> 'reason') || '/' || (v ->> 'action') || '/' || (v ->> 'expected_cents') || '/' || (v ->> 'received_cents') from test.ba_pay('f1', 71100) v),
  'false/amount_mismatch/void_authorization/83055/71100');
select test.eq('P a payment for an offer version that is not the approved one is refused',
  (select (v ->> 'reason') || '/' || (v ->> 'action') from test.ba_pay('f1', null, 2) v), 'offer_changed/void_authorization');
select test.eq('P nothing was recorded by those attempts, each is in the history, and the booking still waits',
  (select count(*) from payments where booking_id = test.ba('f1')) || '/' || (select count(*) from booking_events where booking_id = test.ba('f1') and kind = 'payment_refused')
  || '/' || test.ba_st('f1') || '/' || app.vehicle_is_available(test.id('vehicle:BA8'), test.soon('10 days'), test.soon('17 days')), '0/4/pending_payment/true');
select test.keep('f1:paid', test.ba_pay('f1', null, null, 'evt_f1'));
select test.eq('P signed, the right amount, the car free: the payment is recorded and the booking confirmed in one step; the server may capture',
  (select (v ->> 'ok') || '/' || (v ->> 'status') || '/' || (v ->> 'action') || '/' || (v ->> 'amount_cents') from test.out('f1:paid') v) || '/' || test.ba_st('f1'),
  'true/confirmed/capture/83055/confirmed');
select test.eq('P the payment: the booking total, a card charge, succeeded, with the card shown as brand and last four',
  (select p.purpose || '/' || p.kind || '/' || p.method || '/' || p.status || '/' || p.amount_cents || '/' || p.card_brand || '/' || p.card_last4 || '/' || (p.processed_at is not null)
          || '/' || d.processor || '/' || d.processor_payment_id || '/' || d.processor_charge_id
     from payments p join payment_processor_details d on d.payment_id = p.id where p.booking_id = test.ba('f1')),
  'booking_total/charge/card/succeeded/83055/visa/4242/true/stripe/pi_f1/ch_f1');
select test.eq('P the card becomes the Card on File; the processor''s ids are in the admin-only table',
  (select pm.card_brand || '/' || pm.card_last4 || '/' || pm.is_credit || '/' || pm.cardholder_name || '/' || s.processor_method_id || '/' || s.processor_customer_id
     from bookings b join payment_methods pm on pm.id = b.card_on_file_id join payment_method_secrets s on s.payment_method_id = pm.id where b.id = test.ba('f1')),
  'visa/4242/true/Gus Green/pm_f1/cus_f1');
select test.eq('P every charge line of the booking is tied to the payment',
  (select count(*) || '/' || count(*) filter (where li.payment_id = (select id from payments where booking_id = test.ba('f1')))
     from booking_line_items li where li.booking_id = test.ba('f1') and li.voided_at is null), '2/2');
select test.eq('P CarmaCars countersigned automatically by the signing officer (0053), as its own signature record',
  (select string_agg(signer_role || ':' || signer_name || ':' || method || ':' || coalesce(signer_title, '-'), ' ' order by signed_at, signer_role desc)
     from signature_records where signature_request_id = test.ba_sigreq('f1')),
  'renter:Gus Green:typed:- carmacars:' || (select coalesce(signing_officer_name, 'CarmaCars') || ':automatic:' || coalesce(signing_officer_title, 'for CarmaCars') from app.settings()));
select test.eq('P the countersignature has the approved wording and the hash of the same document; the staff member who sent the offer is only "Proposed by"',
  (select (consent_text = app.corporate_signature_text())
          || '/' || (document_sha256 = test.sha('agreement of f1 v1')) || '/' || coalesce(staff_attribution, '-') || '/' || (attributed_user_id = test.id('ba_cs'))
     from signature_records where signature_request_id = test.ba_sigreq('f1') and signer_role = 'carmacars'), 'true/true/Proposed by: Ba Cs/true');
select test.eq('P the signature request and the agreement are completed',
  (select s.status || '/' || (s.completed_at is not null) || '/' || a.status || '/' || (a.completed_at is not null)
     from rental_agreements a join signature_requests s on s.id = a.signature_request_id where a.id = test.ba('f1:ag')), 'completed/true/completed/true');
select test.eq('P the completed agreement is announced once, with who signed',
  (select count(*) || '/' || min(payload ->> 'countersigned_by') || '/' || min(jsonb_array_length(payload -> 'signers')) || '/' || bool_and(dedupe_key = 'renter_agreement_signed:' || entity_id || ':completed')
     from app_events where code = 'renter_agreement_signed' and entity_id = test.ba('f1:ag')), '1/Ba Cs/2/true');
select test.eq('P only now is the car taken',
  app.vehicle_is_available(test.id('vehicle:BA8'), test.soon('10 days'), test.soon('17 days')), false);
select test.eq('P the whole path is in the status history and in the booking''s own history',
  (select string_agg(to_status, ' > ' order by id) from status_history where entity = 'booking' and entity_id = test.ba('f1'))
  || ' | ' || (select string_agg(kind, ' ' order by id) from booking_events where booking_id = test.ba('f1') and kind <> 'payment_refused'),
  'requested > offered > pending_payment > confirmed | requested offer_sent offer_approved agreement_opened agreement_signed agreement_completed confirmed');
select test.eq('P the processor event is on record once, handled, with its result and no card data',
  (select count(*) || '/' || min(provider) || '/' || min(event_type) || '/' || bool_and(processed_at is not null) || '/' || min(result ->> 'ok') || '/' || min(summary ->> 'payment_id')
          || '/' || bool_and(summary::text !~ '4242')
     from webhook_events where event_id = 'evt_f1'), '1/stripe/booking_payment/true/true/pi_f1/true');
select test.eq('P the same event delivered again changes nothing and returns the first result',
  (select (v ->> 'ok') || '/' || (v ->> 'replayed') || '/' || (v ->> 'action') from test.ba_pay('f1', null, null, 'evt_f1') v)
  || '/' || (select count(*) from payments where booking_id = test.ba('f1')) || '/' || (select count(*) from webhook_events where event_id = 'evt_f1'), 'true/true/capture/1/1');
select test.eq('P the same payment reported under another event is recognised: already confirmed, nothing new',
  (select (v ->> 'ok') || '/' || (v ->> 'already_confirmed') from test.ba_pay('f1', null, null, 'evt_f1_again') v) || '/' || (select count(*) from payments where booking_id = test.ba('f1')),
  'true/true/1');
select test.eq('P a second, different payment on a confirmed booking is refused: void it',
  (select (v ->> 'ok') || '/' || (v ->> 'reason') || '/' || (v ->> 'action')
     from app.record_booking_payment(test.ba('f1'), '{"payment_id": "pi_f1_second"}', 71190, 1) v), 'false/already_confirmed/void_authorization');
select test.eq('P an event is claimed once', (app.webhook_event_claim('stripe', 'evt_other', 'x') ->> 'first') || '/' || (app.webhook_event_claim('stripe', 'evt_other', 'x') ->> 'first'), 'true/false');
select test.throws('P the provider''s event id is unique in the table', $$insert into webhook_events (provider, event_id) values ('stripe', 'evt_f1')$$, 'webhook_events_provider_event_id_key');
-- the additional driver accepts afterwards; the signed copy is stored once
insert into test.ba_ids values ('f1:sig2', app.record_signature(test.ba_sigreq('f1'), test.ba_signer('f1', 'additional_driver'), null,
  'agreements/bookings/f1/signatures/gina.png', inet '203.0.113.60', 'Mozilla/5.0 (tablet)', 'I accept this Rental Agreement as an additional driver.'));
select test.eq('SG the additional driver accepts with a drawn signature, after the renter and before handover',
  (select r.method || '/' || r.provider_signature || '/' || r.signer_role || '/' || (d.accepted_at is not null) || '/' || (d.signature_record_id = r.id)
     from signature_records r join booking_drivers d on d.booking_id = test.ba('f1') and d.role = 'additional' where r.id = test.ba('f1:sig2')),
  'drawn/agreements/bookings/f1/signatures/gina.png/additional_driver/true/true');
select test.throws('SG the signed copy needs its hash', $$select app.attach_signed_agreement(test.ba_sigreq('f1'), 'bookings/f1/signed.pdf', 'nope')$$, 'SHA-256');
select app.attach_signed_agreement(test.ba_sigreq('f1'), 'agreements/bookings/f1/signed.pdf', test.sha('signed f1'));
select test.eq('SG the signed copy is stored with its hash and becomes the booking''s agreement document',
  (select d.kind || '/' || (d.sha256 = test.sha('signed f1')) || '/' || (b.agreement_document_id = d.id) || '/' || (d.title like 'Rental agreement RA-%, signed')
     from signature_requests s join documents d on d.id = s.signed_document_id join bookings b on b.id = test.ba('f1') where s.id = test.ba_sigreq('f1')),
  'rental_agreement/true/true/true');
select test.throws('SG a signed copy is never replaced',
  $$select app.attach_signed_agreement(test.ba_sigreq('f1'), 'agreements/bookings/f1/signed-2.pdf', test.sha('signed f1 again'))$$, 'never replaced');

-- ------------------------------------------------------------------ the race: two renters, one car, the same dates
select test.ba_new('b1', 'hal.hill@example.test', 'BA5', test.soon('20 days'), test.soon('27 days'));
select test.ba_new('b2', 'ivy.ince@example.test', 'BA5', test.soon('22 days'), test.soon('29 days'));
select test.ba_offer('b1'); select test.ba_offer('b2');
select test.ba_open('b1'); select test.ba_open('b2');
select test.ba_sign('b1'); select test.ba_sign('b2');
insert into test.ba_ids select 'b2:ag', id from rental_agreements where booking_id = test.ba('b2');
select test.eq('RACE both renters have approved and signed for the same car and overlapping dates; neither blocks it yet',
  test.ba_st('b1') || ' ' || test.ba_st('b2') || ' ' || app.vehicle_is_available(test.id('vehicle:BA5'), test.soon('20 days'), test.soon('29 days')),
  'pending_payment pending_payment true');
select test.ba_pay('b1');
select test.eq('RACE the first to pay is confirmed', (select (v ->> 'ok') || '/' || (v ->> 'action') from test.out('pay:b1') v) || '/' || test.ba_st('b1'), 'true/capture/confirmed');
select test.eq('RACE the other went back to staff at that moment, and its signed but unpaid agreement was voided',
  test.ba_st('b2') || '/' || (select a.status || ':' || (a.void_reason like 'The booking went back to staff%') || ':' || s.status
                                from rental_agreements a join signature_requests s on s.id = a.signature_request_id where a.id = test.ba('b2:ag'))
  || '/' || (select coalesce(signature_request_id::text, 'no agreement') from bookings where id = test.ba('b2')), 'requested/voided:true:voided/no agreement');
select test.keep('b2:paid', test.ba_pay('b2', 63280, 1));
select test.eq('RACE the second renter''s authorized payment is refused: the server is told to void the authorization, and nothing is charged or recorded',
  (select (v ->> 'ok') || '/' || (v ->> 'reason') || '/' || (v ->> 'action') || '/' || (v ->> 'status') from test.out('b2:paid') v)
  || '/' || (select count(*) from payments where booking_id = test.ba('b2')) || '/' || test.ba_st('b2')
  || '/' || coalesce((select card_on_file_id::text from bookings where id = test.ba('b2')), 'no card'),
  'false/not_awaiting_payment/void_authorization/requested/0/requested/no card');
select test.eq('RACE customer service has the task to offer the second renter another car',
  (select count(*) || ':' || min(queue) from tasks where booking_id = test.ba('b2') and task_type = 'reoffer_booking'), '1:cs');
select test.eq('RACE the signature the second renter gave is still on record, untouched',
  (select count(*) || '/' || min(r.status) from signature_records r join rental_agreements a on a.signature_request_id = r.signature_request_id where a.id = test.ba('b2:ag')), '1/signed');
-- the car is blocked (not booked) after the renter signed: the confirmation itself finds out
select test.ba_new('b3', 'jon.jay@example.test', 'BA4', test.soon('20 days'), test.soon('27 days'));
select test.ba_offer('b3'); select test.ba_open('b3'); select test.ba_sign('b3');
insert into vehicle_calendar_blocks (vehicle_id, reason, starts_at, ends_at, note, created_by)
values (test.id('vehicle:BA4'), 'repair', test.soon('21 days'), test.soon('23 days'), 'body shop', test.id('ba_fleet'));
select test.keep('b3:paid', test.ba_pay('b3'));
select test.eq('RACE a car that became unavailable after signing: the payment is refused, the booking goes back to staff, the offer is withdrawn, the agreement voided',
  (select (v ->> 'ok') || '/' || (v ->> 'reason') || '/' || (v ->> 'action') from test.out('b3:paid') v) || '/' || test.ba_st('b3')
  || '/' || (select status from booking_offers where booking_id = test.ba('b3'))
  || '/' || (select status from rental_agreements where booking_id = test.ba('b3'))
  || '/' || (select count(*) from payments where booking_id = test.ba('b3')), 'false/vehicle_taken/void_authorization/requested/withdrawn/voided/0');
select test.eq('RACE with an urgent task for customer service and a system note in the history',
  (select count(*) || ':' || min(priority) from tasks where booking_id = test.ba('b3') and task_type = 'reoffer_booking')
  || '/' || (select count(*) from booking_events where booking_id = test.ba('b3') and kind = 'pushed_back' and actor_type = 'system'), '1:urgent/1');

-- ------------------------------------------------------------------ an adjustment after signing: sign again
select test.ba_new('g1', 'kim.king@example.test', 'BA6', test.soon('30 days'), test.soon('37 days'));
select test.ba_offer('g1'); select test.ba_open('g1'); select test.ba_sign('g1');
insert into test.ba_ids select 'g1:ag1', id from rental_agreements where booking_id = test.ba('g1');
insert into test.ba_ids select 'g1:req1', signature_request_id from rental_agreements where booking_id = test.ba('g1');
insert into test.ba_ids select 'g1:signer1', id from rental_agreement_signers where agreement_id = test.ba('g1:ag1') and signer_role = 'renter';
select app.withdraw_offer(test.ba('g1'), test.id('ba_cs'), 'deposit lowered by agreement');
select test.eq('RS staff withdraw the offer to adjust it: the signed but unpaid agreement is voided, with the reason, and the booking no longer points at it',
  test.ba_st('g1') || '/' || (select a.status || ':' || (a.voided_at is not null) || ':' || a.void_reason from rental_agreements a where a.id = test.ba('g1:ag1'))
  || '/' || (select status from signature_requests where id = test.ba('g1:req1'))
  || '/' || (select coalesce(signature_request_id::text, 'none') || ':' || coalesce(agreement_document_id::text, 'none') || ':' || (agreement_number like 'RA-%') from bookings where id = test.ba('g1')),
  'requested/voided:true:The booking went back to staff after this agreement was opened: the next offer is approved and signed again/voided/none:none:true');
select test.eq('RS the signature given on the voided agreement stays on record',
  (select count(*) from signature_records where signature_request_id = test.ba('g1:req1') and status = 'signed'), 1::bigint);
select app.adjust_booking(test.ba('g1'), test.id('ba_cs'), '{"deposit_cents": 50000, "pickup_method": "delivered", "pickup_place": "5 Oak Ave"}');
select test.eq('RS the adjusted request is offered again: version 2, a new price ($560 + $75 delivery + HST)',
  app.send_offer(test.ba('g1'), test.id('ba_cs')) || '/' || (select total_due_at_booking_cents from bookings where id = test.ba('g1')), '2/71755');
select app.approve_offer(test.ba('g1'), 2, test.ba_user('kim.king@example.test'));
select test.eq('RS a payment for the earlier version is refused',
  (select (v ->> 'reason') from test.ba_pay('g1', null, 1) v), 'offer_changed');
select test.eq('RS a payment of the new amount is refused too: the agreement for version 2 is not signed',
  (select (v ->> 'reason') || '/' || (v ->> 'action') from test.ba_pay('g1') v), 'agreement_not_signed/void_authorization');
select test.throws('RS a voided agreement cannot be opened for signing again',
  $$select app.record_signature(test.ba('g1:req1'), test.ba('g1:signer1'), 'Kim King', null, '203.0.113.50', 'ua', 'I sign.')$$, 'was replaced');
insert into test.ba_ids values ('g1:ag2', test.ba_open('g1'));
select test.eq('RS a new agreement is opened for version 2, under the same agreement number; the renter is told it is ready because it was reissued',
  (select (a2.id <> a1.id) || '/' || a2.offer_version || '/' || a2.status || '/' || (a2.agreement_number = a1.agreement_number) || '/' || (a2.document_sha256 <> a1.document_sha256)
     from rental_agreements a1, rental_agreements a2 where a1.id = test.ba('g1:ag1') and a2.id = test.ba('g1:ag2'))
  || '/' || (select string_agg((payload ->> 'signer_role') || ':' || (payload ->> 'reissued'), ',') from app_events where code = 'renter_agreement_ready' and entity_id = test.ba('g1:ag2')),
  'true/2/open/true/true/renter:true');
select test.ba_sign('g1');
select test.ba_pay('g1');
select test.eq('RS signed again and paid: confirmed', (select (v ->> 'ok') || '/' || (v ->> 'amount_cents') from test.out('pay:g1') v) || '/' || test.ba_st('g1'), 'true/71755/confirmed');
select test.eq('RS the booking has one voided and one completed agreement, and one live at most (the table refuses two)',
  (select string_agg(offer_version || ':' || status, ' ' order by opened_at) from rental_agreements where booking_id = test.ba('g1')), '1:voided 2:completed');
select test.throws('RS a completed agreement is not opened again', $$select test.ba_open('g1')$$, 'opened once the offer is approved');
-- reissued while open, and after signing; then the renter asks for a change
select test.ba_new('h1', 'lea.long@example.test', 'BA6', test.soon('40 days'), test.soon('47 days'));
select test.ba_offer('h1');
insert into test.ba_ids values ('h1:ag1', test.ba_open('h1'));
insert into test.ba_ids values ('h1:ag2', test.ba_open('h1', 'licence number added'));
select test.eq('RS the document changed before signing (the renter added their details): the first agreement is voided and a new one is open',
  (select string_agg(status || ':' || coalesce(void_reason, '-'), ' ' order by opened_at, status desc) from rental_agreements where booking_id = test.ba('h1')),
  'voided:A new version of the agreement was issued open:-');
select test.ba_sign('h1');
insert into test.ba_ids values ('h1:ag3', test.ba_open('h1', 'address corrected'));
select test.eq('RS the document changed after signing: the signed agreement is voided and must be signed again before payment',
  (select status from rental_agreements where id = test.ba('h1:ag2')) || '/' || (select status from rental_agreements where id = test.ba('h1:ag3'))
  || '/' || (select v ->> 'reason' from test.ba_pay('h1') v), 'voided/open/agreement_not_signed');
select app.request_offer_change(test.ba('h1'), test.ba_user('lea.long@example.test'), 'Can I pick up a day later?');
select test.eq('RS the renter asks for a change before paying: back to staff, and the unsigned agreement is voided as well',
  test.ba_st('h1') || '/' || (select string_agg(status, ',') from rental_agreements where booking_id = test.ba('h1')), 'requested/voided,voided,voided');
select test.throws('RS the table itself refuses two live agreements on one booking',
  format($$with s as (insert into signature_requests (document_id, provider, status) select document_id, 'builtin', 'draft' from rental_agreements where id = %L returning id)
           insert into rental_agreements (booking_id, offer_version, agreement_number, template_version, document_id, document_sha256, signature_request_id, countersigner_name)
           select booking_id, offer_version, agreement_number, template_version, document_id, document_sha256, (select id from s), countersigner_name from rental_agreements where id = %L$$,
         test.ba('g1:ag2'), test.ba('g1:ag2')), 'rental_agreements_one_live');

-- ------------------------------------------------------------------ nothing to pay at booking: an Owner Booking, and an insurer's booking
insert into test.ba_ids values ('ob', app.request_booking(test.id('renter:ba_owen'), test.id('vehicle:BA9'), test.soon('15 days'), test.soon('17 days'),
  'owner', null, 'owner', test.id('ba_owen')));
update bookings set status = 'pending_payment' where id = test.ba('ob');
insert into test.ba_ids values ('ob:ag', app.open_rental_agreement(test.ba('ob'), test.id('ba_cs'), 'rental-v2-2026-10', test.sha('owner agreement'), 'bookings/ob/agreement.pdf'));
select test.eq('N an Owner Booking goes to signing without an offer: the agreement names the Owner and the staff member who opened it',
  (select a.status || '/' || coalesce(a.offer_version::text, 'no offer') || '/' || a.countersigner_name || '/' ||
          (select string_agg(signer_role || ':' || signer_name, ' ' order by signer_role desc) from rental_agreement_signers where agreement_id = a.id)
     from rental_agreements a where a.id = test.ba('ob:ag')), 'open/no offer/Ba Cs/renter:Ba Owen carmacars:Ba Cs');
select test.eq('N a card payment is not taken on it',
  (select (v ->> 'reason') from app.record_booking_payment(test.ba('ob'), '{"payment_id": "pi_ob"}', 100, null) v), 'nothing_to_pay');
select test.eq('N and it is not confirmed before the Owner signs',
  (select (v ->> 'ok') || '/' || (v ->> 'reason') || '/' || (v ->> 'action') from app.confirm_unpaid_booking(test.ba('ob'), test.id('ba_owen')) v), 'false/agreement_not_signed/none');
select test.ba_sign('ob');
select test.throws('N only the renter of the booking or staff confirm it', $$select app.confirm_unpaid_booking(test.ba('ob'), test.ba_user('gus.green@example.test'))$$, 'Only the renter of this booking, or staff');
select test.keep('ob:c', app.confirm_unpaid_booking(test.ba('ob'), test.id('ba_owen')));
select test.eq('N signed: confirmed with no payment and no card, countersigned for CarmaCars, and it blocks the car',
  (select (v ->> 'ok') || '/' || (v ->> 'action') from test.out('ob:c') v) || '/' || test.ba_st('ob')
  || '/' || (select count(*) from payments where booking_id = test.ba('ob')) || '/' || (select coalesce(card_on_file_id::text, 'no card') from bookings where id = test.ba('ob'))
  || '/' || (select string_agg(signer_role, ',' order by signed_at, signer_role desc) from signature_records where signature_request_id = test.ba_sigreq('ob'))
  || '/' || app.vehicle_is_available(test.id('vehicle:BA9'), test.soon('15 days'), test.soon('17 days')), 'true/none/confirmed/0/no card/renter,carmacars/false');
select test.eq('N confirming it a second time changes nothing',
  (select (v ->> 'ok') || '/' || (v ->> 'already_confirmed') from app.confirm_unpaid_booking(test.ba('ob'), test.id('ba_owen')) v), 'true/true');
-- an insurer pays the whole bill at booking
insert into insurers (id, name, billing_email) values (test.id('ins:ba'), 'Ba Test Insurer', 'payables@ba-insurer.example.test');
select test.ba_new('n1', 'max.moss@example.test', 'BA9', test.soon('60 days'), test.soon('67 days'));
select app.adjust_booking(test.ba('n1'), test.id('ba_cs'), jsonb_build_object('bill_to', 'insurer', 'insurer_id', test.id('ins:ba'), 'insurer_claim_number', 'CLM-BA-1'));
select app.send_offer(test.ba('n1'), test.id('ba_cs'));
select app.approve_offer(test.ba('n1'), 1, test.id('ba_cs'));
insert into test.ba_ids values ('n1:ag', app.open_rental_agreement(test.ba('n1'), test.id('ba_cs'), 'rental-v2-2026-10', test.sha('insurer agreement'), 'bookings/n1/agreement.pdf'));
select test.eq('N a booking billed to an insurer: the renter owes nothing at booking; the agreement, opened by staff, is announced to the renter',
  (select renter_due_at_booking_cents || '/' || (insurer_share_cents + insurer_hst_cents) from bookings where id = test.ba('n1'))
  || '/' || (select string_agg(payload ->> 'signer_role', ',') from app_events where code = 'renter_agreement_ready' and entity_id = test.ba('n1:ag')), '0/50850/renter');
select test.ba_sign('n1');
select test.eq('N a card payment is refused on it (nothing to pay), and so is a confirmation without a saved card',
  (select v ->> 'reason' from test.ba_pay('n1', 50850) v) || '/' || (select v ->> 'reason' from app.confirm_unpaid_booking(test.ba('n1'), test.ba_user('max.moss@example.test')) v),
  'nothing_to_pay/no_card');
select test.eq('N a debit card is refused as Card on File',
  (select v ->> 'reason' from app.confirm_unpaid_booking(test.ba('n1'), test.ba_user('max.moss@example.test'), '{"brand": "visa", "last4": "1111", "is_credit": false}', '{"method_id": "pm_n1_debit"}') v),
  'card_not_credit');
select test.keep('n1:c', app.confirm_unpaid_booking(test.ba('n1'), test.ba_user('max.moss@example.test'),
            '{"brand": "mastercard", "last4": "5454", "cardholder_name": "Max Moss", "exp_month": 6, "exp_year": 2030, "is_credit": true}',
            '{"method_id": "pm_n1", "customer_id": "cus_n1"}'));
select test.eq('N with the card saved (no charge), it is confirmed on the signature; the rental lines wait for the insurer''s payment',
  (select (v ->> 'ok') || '/' || (v ->> 'action') || '/' || (v ->> 'amount_cents') from test.out('n1:c') v)
  || '/' || test.ba_st('n1') || '/' || (select count(*) from payments where booking_id = test.ba('n1'))
  || '/' || (select pm.card_brand || ':' || pm.card_last4 from bookings b join payment_methods pm on pm.id = b.card_on_file_id where b.id = test.ba('n1'))
  || '/' || (select count(*) filter (where payment_id is not null) from booking_line_items where booking_id = test.ba('n1'))
  || '/' || (select status from rental_agreements where id = test.ba('n1:ag')), 'true/none/0/confirmed/0/mastercard:5454/0/completed');
-- a booking with an amount due is not confirmed that way; a failed capture after confirmation
select test.ba_new('p1', 'ned.nash@example.test', 'BA3', test.soon('70 days'), test.soon('77 days'));
select test.ba_offer('p1'); select test.ba_open('p1'); select test.ba_sign('p1');
select test.eq('N a booking on which the renter owes an amount is confirmed by its payment only',
  (select (v ->> 'reason') || '/' || (v ->> 'expected_cents') from app.confirm_unpaid_booking(test.ba('p1'), test.id('ba_cs')) v), 'payment_required/63280');
select test.eq('P a debit card is refused for the payment as well',
  (select (v ->> 'reason') || '/' || (v ->> 'action') from app.record_booking_payment(test.ba('p1'), '{"payment_id": "pi_p1_debit", "method_id": "pm_p1_debit"}', 63280, 1,
            '{"brand": "visa", "last4": "1111", "is_credit": false}') v), 'card_not_credit/void_authorization');
select test.ba_pay('p1');
select app.booking_payment_capture_failed(test.ba('p1'), '{"payment_id": "pi_p1"}', 'card_declined on capture');
select test.eq('P if the capture fails after confirmation the payment is marked failed and an Admin gets an urgent task',
  (select status || ':' || last_decline_code from payments where booking_id = test.ba('p1'))
  || '/' || (select count(*) || ':' || min(queue) || ':' || min(priority) from tasks where booking_id = test.ba('p1') and task_type = 'capture_failed'),
  'failed:card_declined on capture/1:admin:urgent');

-- ------------------------------------------------------------------ cancellation: the tiers of the specification, through the new functions
-- Section 5 examples: rental charge $600 + HST $78 = $678 paid. (An Admin sets the rental charge by hand.)
create function test.ba_600(p_key text, p_email text, p_vehicle text, p_pickup timestamptz, p_return timestamptz, p_over jsonb default '{}') returns text
language plpgsql as $$
begin
  perform test.ba_new(p_key, p_email, p_vehicle, p_pickup, p_return, p_over);
  perform app.adjust_booking(test.ba(p_key), test.id('ba_admin'), '{"rental_charge_cents": 60000}');
  perform test.ba_offer(p_key);
  perform test.ba_open(p_key);
  perform test.ba_sign(p_key);
  perform test.ba_pay(p_key);
  return test.ba_st(p_key);
end $$;
create function test.cx(p_key text, p_at timestamptz, p_reason text default 'renter_request') returns text language sql stable as $$
  select (v ->> 'tier') || ':' || (v ->> 'refund_bps') || ':' || (v ->> 'refund_cents') || ':' || (v ->> 'retained_cents')
    from app.preview_cancellation(test.ba(p_key), p_at, p_reason) v
$$;
grant execute on all functions in schema test to authenticated, anon;
select test.ba_600('c1', 'oli.owen@example.test', 'BA2', test.soon('10 days'), test.soon('13 days'));
select test.eq('C a booking of $600 + HST is confirmed and paid: $678.00', test.ba_st('c1')
  || '/' || app.booking_paid_cents(test.ba('c1')), 'confirmed/67800');
select test.eq('C example 1: booked 10 days ahead, cancelled 5 hours after booking: 95%, refund $644.10, kept $33.90',
  (select test.cx('c1', confirmed_at + interval '5 hours') from bookings where id = test.ba('c1')), 'within_24h_of_booking:9500:64410:3390');
select test.eq('C example 2: cancelled 3 days before start: 75%, refund $508.50, kept $169.50',
  (select test.cx('c1', pickup_at - interval '3 days') from bookings where id = test.ba('c1')), 'notice_48h_plus:7500:50850:16950');
select test.eq('C 24 hours or more, but less than 48, before start: 50%',
  (select test.cx('c1', pickup_at - interval '30 hours') from bookings where id = test.ba('c1')), 'notice_24_to_48h:5000:33900:33900');
select test.eq('C less than 24 hours before start, after start, and a no-show: nothing',
  (select test.cx('c1', pickup_at - interval '2 hours') || ' ' || test.cx('c1', pickup_at + interval '1 hour') || ' ' || test.cx('c1', pickup_at - interval '5 days', 'no_show')
     from bookings where id = test.ba('c1')),
  'under_24h_or_after_start:0:0:67800 under_24h_or_after_start:0:0:67800 under_24h_or_after_start:0:0:67800');
select test.eq('C CarmaCars cancels, or a driver cannot be verified: 100%, at any time',
  (select test.cx('c1', pickup_at - interval '2 hours', 'carmacars_no_vehicle') || ' ' || test.cx('c1', pickup_at - interval '2 hours', 'driver_not_verifiable')
     from bookings where id = test.ba('c1')), 'carmacars_cancelled:10000:67800:0 carmacars_cancelled:10000:67800:0');
select test.eq('C the preview also says when the booking was made (confirmed), when the refund is due, and that the booking can be cancelled',
  (select ((v ->> 'booking_made_at')::timestamptz = b.confirmed_at) || '/' || (v ->> 'can_cancel') || '/' || (v ->> 'total_paid_cents') || '/'
          || ((v ->> 'refund_due_by')::date = app.add_business_days(app.today(), 10)) || '/' || (v ->> 'deposit_returned_cents')
     from bookings b, app.preview_cancellation(b.id) v where b.id = test.ba('c1')), 'true/true/67800/true/0');
select test.throws('C a refund outside the table is not previewed here', $$select app.preview_cancellation(test.ba('c1'), now(), 'pricing_error')$$, 'set by an Admin');
select test.throws('C another renter cannot cancel the booking',
  $$select app.cancel_booking(test.ba('c1'), test.ba_user('gus.green@example.test'))$$, 'Only the renter of this booking, customer service or an Admin');
select test.throws('C a sales assistant cannot cancel it', $$select app.cancel_booking(test.ba('c1'), test.id('ba_sales'))$$, 'Only the renter of this booking, customer service or an Admin');
select test.throws('C a renter cannot cancel in CarmaCars'' name',
  $$select app.cancel_booking(test.ba('c1'), test.ba_user('oli.owen@example.test'), 'carmacars_no_vehicle')$$, 'A renter cancels their own booking');
select test.throws('C a request is not cancelled (it is withdrawn or declined)',
  $$select app.cancel_booking(test.ba('r2'), test.ba_user('ben.brown@example.test'))$$, 'only a confirmed booking is cancelled');
select test.keep('c1:x', app.cancel_booking(test.ba('c1'), test.ba_user('oli.owen@example.test'), 'renter_request', 'Plans changed'));
select test.eq('C the renter cancels right after booking, 10 days ahead: cancelled, 95%',
  (select (v ->> 'cancelled') || '/' || (v ->> 'status') || '/' || (v ->> 'tier') || '/' || (v ->> 'refund_cents') || '/' || (v ->> 'retained_cents') from test.out('c1:x') v)
  || '/' || test.ba_st('c1'), 'true/cancelled/within_24h_of_booking/64410/3390/cancelled');
select test.eq('C the cancellation is logged with the three times, who cancelled, how, the tier and the amounts',
  (select channel || '/' || cancelled_by || '/' || reason || '/' || tier || '/' || refund_bps || '/' || total_paid_cents || '/' || refund_cents || '/' || retained_cents
          || '/' || (booked_at = (select confirmed_at from bookings where id = test.ba('c1'))) || '/' || (start_at = (select pickup_at from bookings where id = test.ba('c1')))
          || '/' || (logged_by = test.ba_user('oli.owen@example.test')) || '/' || (refund_id is not null)
     from booking_cancellations where booking_id = test.ba('c1')), 'portal/renter/renter_request/within_24h_of_booking/9500/67800/64410/3390/true/true/true/true');
select test.eq('C the refund waits for approval, against the payment, due within 10 business days, and is spread over the booking''s lines',
  (select r.status || '/' || r.reason || '/' || r.refund_bps || '/' || r.amount_cents || '/' || (r.payment_id = (select id from payments where booking_id = test.ba('c1')))
          || '/' || (r.due_by = app.add_business_days(app.today(), 10)) || '/' || (select sum(amount_cents + hst_cents) from refund_allocations where refund_id = r.id)
     from refunds r where r.booking_id = test.ba('c1')), 'pending_approval/cancellation/9500/64410/true/true/64410');
select test.eq('C Finance has the task, the history has the cancellation, and the car is free again',
  (select count(*) || ':' || min(queue) from tasks where booking_id = test.ba('c1') and task_type = 'refund_cancellation')
  || '/' || (select actor_type || ':' || (details ->> 'tier') from booking_events where booking_id = test.ba('c1') and kind = 'cancelled')
  || '/' || app.vehicle_is_available(test.id('vehicle:BA2'), test.soon('10 days'), test.soon('13 days')), '1:finance/renter:within_24h_of_booking/true');
select test.throws('C a cancelled booking is not cancelled again', $$select app.cancel_booking(test.ba('c1'), test.id('ba_cs'))$$, 'only a confirmed booking is cancelled');
-- example 3, logged by customer service from an email
select test.ba_600('c2', 'pia.park@example.test', 'BA2', test.soon('31 hours'), test.soon('103 hours'));
select test.keep('c2:x', app.cancel_booking(test.ba('c2'), test.id('ba_cs'), 'renter_request', 'Cancelled by email', 'email',
  (select confirmed_at + interval '1 hour' from bookings where id = test.ba('c2'))));
select test.eq('C example 3: booked about 30 hours before start, cancelled 1 hour later: 50%, refund $339.00, kept $339.00',
  (select (v ->> 'tier') || '/' || (v ->> 'refund_cents') || '/' || (v ->> 'retained_cents') from test.out('c2:x') v)
  || '/' || (select channel || ':' || cancelled_by || ':' || (logged_by = test.id('ba_cs')) from booking_cancellations where booking_id = test.ba('c2')),
  'notice_24_to_48h/33900/33900/email:renter:true');
-- a non-refundable booking
select test.ba_600('c3', 'quin.quest@example.test', 'BA2', test.soon('20 days'), test.soon('23 days'), '{"booking_type": "non_refundable"}');
select test.eq('C a non-refundable booking ($600 - $60 + HST = $610.20) is never refunded to a renter who cancels',
  app.booking_paid_cents(test.ba('c3')) || '/' || (select test.cx('c3', confirmed_at + interval '1 hour') from bookings where id = test.ba('c3')), '61020/non_refundable:0:0:61020');
select test.keep('c3:x', app.cancel_booking(test.ba('c3'), test.id('ba_cs'), 'carmacars_no_vehicle', 'The car is in the body shop', 'email'));
select test.eq('C but when CarmaCars cancels it is refunded in full, and the refund says so',
  (select (v ->> 'tier') || '/' || (v ->> 'refund_cents') from test.out('c3:x') v)
  || '/' || (select cancelled_by from booking_cancellations where booking_id = test.ba('c3'))
  || '/' || (select reason || ':' || amount_cents || ':' || status from refunds where booking_id = test.ba('c3')), 'carmacars_cancelled/61020/carmacars/carmacars_cancelled:61020:pending_approval');
-- a no-show
select test.ba_600('c4', 'ray.rush@example.test', 'BA2', test.soon('5 days'), test.soon('8 days'));
select test.throws('C a no-show is logged after the pickup time', $$select app.cancel_booking(test.ba('c4'), test.id('ba_cs'), 'no_show')$$, 'after the pickup time');
select test.keep('c4:x', app.cancel_booking(test.ba('c4'), test.id('ba_cs'), 'no_show', 'Did not come', 'system', (select pickup_at + interval '2 hours' from bookings where id = test.ba('c4'))));
select test.eq('C a no-show: no refund, no refund row, the booking ends as a no-show',
  (select (v ->> 'refund_cents') || '/' || (v ->> 'status') from test.out('c4:x') v) || '/' || test.ba_st('c4') || '/' || (select count(*) from refunds where booking_id = test.ba('c4')),
  '0/no_show/no_show/0');

-- ------------------------------------------------------------------ extensions: ask, preview, approve, pay, confirm
-- E1: 7 days ($560) for a renter of 23 (young driver $20 x 7 = $140): $700 + HST $91 = $791
select test.ba_confirmed('e1', 'sam.stone@example.test', 'BA1', test.soon('3 days'), test.soon('10 days'), jsonb_build_object('renter', jsonb_build_object('date_of_birth', test.dob(23))));
select test.eq('E a 7-day booking for a renter of 23 is confirmed and paid: $791.00',
  test.ba_st('e1') || '/' || app.booking_paid_cents(test.ba('e1')), 'confirmed/79100');
select test.keep('e1:pv', app.preview_extension(test.ba('e1'), test.soon('13 days')));
select test.eq('E extending to 10 days reprices the whole booking at its stored rates: rental $560 to $800 (+$240); the young driver fee $140 to its $200 cap (+$60); HST $39; $339.00 to pay',
  (select (v ->> 'ok') || '/' || (v ->> 'previous_days') || '>' || (v ->> 'new_days') || '/' || (v ->> 'previous_rental_charge_cents') || '>' || (v ->> 'new_rental_charge_cents')
          || '/' || (v ->> 'rental_difference_cents') || '/' || (v ->> 'fees_difference_cents') || '/' || (v ->> 'hst_cents') || '/' || (v ->> 'total_cents')
          || '/' || (v ->> 'km_allowance_total') || '/' || (v ->> 'available') || '/' || (v ->> 'deposit_hold_capture_needed') from test.out('e1:pv') v),
  'true/7>10/56000>80000/24000/6000/3900/33900/2000/true/false');
select test.eq('E line by line',
  (select string_agg((l ->> 'charge_type') || '=' || (l ->> 'amount_cents') || '+' || (l ->> 'hst_cents'), ' ' order by o)
     from test.out('e1:pv') v, jsonb_array_elements(v -> 'lines') with ordinality x(l, o)), 'rental_charge=24000+3120 young_driver_21_25=6000+780');
select test.eq('E the rental difference is the one public.calc_extension() gives',
  (select rental_difference_cents from public.calc_extension(test.soon('3 days'), 7, 10, 10000, 12000, 56000, 180000)), 24000::bigint);
select test.eq('E to 12 days: rental $960 (+$400), young driver fee +$100 (0025: no maximum)',
  (select (v ->> 'rental_difference_cents') || '/' || (v ->> 'fees_difference_cents') || '/' || (v ->> 'total_cents') from app.preview_extension(test.ba('e1'), test.soon('15 days')) v),
  '40000/10000/56500');
select test.eq('E what cannot be done is said: not later than the current return; over 30 days in total; asked after the return time; a booking that is not live',
  (select v -> 'problems' -> 0 ->> 'code' from app.preview_extension(test.ba('e1'), test.soon('9 days')) v) || ' '
  || (select v -> 'problems' -> 0 ->> 'code' from app.preview_extension(test.ba('e1'), test.soon('40 days')) v) || ' '
  || (select v -> 'problems' -> 0 ->> 'code' from app.preview_extension(test.ba('e1'), test.soon('13 days'), test.soon('10 days 1 hour')) v) || ' '
  || (select v -> 'problems' -> 0 ->> 'code' from app.preview_extension(test.ba('r2'), test.soon('18 days')) v),
  'not_later over_maximum_length too_late not_extendable');
select test.throws('E another renter cannot ask to extend this booking',
  $$select app.request_extension(test.ba('e1'), test.ba_user('gus.green@example.test'), test.soon('13 days'))$$, 'Only the renter of this booking, or staff');
select test.throws('E an extension that cannot go ahead is refused when asked for',
  $$select app.request_extension(test.ba('e1'), test.ba_user('sam.stone@example.test'), test.soon('40 days'))$$, 'total length stays at 30 days or less');
insert into test.ba_ids values ('e1:x', app.request_extension(test.ba('e1'), test.ba_user('sam.stone@example.test'), test.soon('13 days'), 'One more weekend'));
select test.eq('E the renter asks: the request is on record, priced, with who asked',
  (select status || '/' || seq || '/' || previous_days || '>' || new_days || '/' || rental_difference_cents || '/' || fees_difference_cents || '/' || hst_cents || '/' || total_cents
          || '/' || note || '/' || (requested_by = test.ba_user('sam.stone@example.test')) || '/' || jsonb_array_length(lines) || '/' || (previous_return_at = test.soon('10 days'))
     from booking_extensions where id = test.ba('e1:x')), 'requested/1/7>10/24000/6000/3900/33900/One more weekend/true/2/true');
select test.eq('E the renter gets an acknowledgement and customer service is told at once; the task is due by the current return time',
  (select string_agg(code || ':' || (dedupe_key = code || ':' || entity_id || ':requested'), ' ' order by code) from app_events where entity = 'booking_extension' and entity_id = test.ba('e1:x'))
  || '/' || (select count(*) || ':' || min(priority) || ':' || bool_and(due_at = test.soon('10 days')) from tasks where related_id = test.ba('e1:x')),
  'renter_extension_requested:true staff_extension_requested:true/1:urgent:true');
select test.eq('E asking does not move the return time', (select return_at = test.soon('10 days') and billable_days = 7 from bookings where id = test.ba('e1')), true);
select test.throws('E one extension request at a time',
  $$select app.request_extension(test.ba('e1'), test.ba_user('sam.stone@example.test'), test.soon('14 days'))$$, 'already open');
select test.eq('E a payment before approval is refused: refund it',
  (select (v ->> 'ok') || '/' || (v ->> 'reason') || '/' || (v ->> 'action') from app.confirm_extension_payment(test.ba('e1:x'), '{"payment_id": "pi_e1x"}', 33900) v),
  'false/not_approved/refund_payment');
select test.throws('E the renter cannot approve their own extension', $$select app.approve_extension(test.ba('e1:x'), test.ba_user('sam.stone@example.test'))$$, 'Only customer service, fleet or an Admin');
select test.throws('E nor can a sales assistant', $$select app.approve_extension(test.ba('e1:x'), test.id('ba_sales'))$$, 'Only customer service, fleet or an Admin');
select test.keep('e1:ap', app.approve_extension(test.ba('e1:x'), test.id('ba_cs')));
select test.eq('E customer service approves: the new state "approved", who and when, and the renter is told what to pay and by when',
  (select status || '/' || (approved_by = test.id('ba_cs')) || '/' || (approved_at is not null) || '/' || total_cents from booking_extensions where id = test.ba('e1:x'))
  || '/' || (select (payload ->> 'total_cents') || ':' || ((payload ->> 'pay_before')::timestamptz = test.soon('10 days')) from app_events where code = 'renter_extension_approved' and entity_id = test.ba('e1:x')),
  'approved/true/true/33900/33900:true');
select test.eq('E approval alone still does not move the return time', (select return_at = test.soon('10 days') from bookings where id = test.ba('e1')), true);
select test.eq('E the wrong amount is refused',
  (select (v ->> 'reason') || '/' || (v ->> 'action') || '/' || (v ->> 'expected_cents') from app.confirm_extension_payment(test.ba('e1:x'), '{"payment_id": "pi_e1x"}', 30000) v),
  'amount_mismatch/refund_payment/33900');
select test.keep('e1:paid', app.confirm_extension_payment(test.ba('e1:x'), '{"payment_id": "pi_e1x", "charge_id": "ch_e1x"}', 33900));
select test.eq('E paid before the return time: the extension is confirmed in writing and the booking''s return time, days, rental charge and mileage allowance move',
  (select (v ->> 'ok') || '/' || (v ->> 'billable_days') from test.out('e1:paid') v)
  || '/' || (select (return_at = test.soon('13 days')) || ':' || billable_days || ':' || rental_charge_cents || ':' || km_allowance_total || ':' || rate_applied
                    || ':' || (original_return_at = test.soon('10 days')) from bookings where id = test.ba('e1'))
  || '/' || (select status || ':' || (paid_at is not null) || ':' || (confirmed_in_writing_at is not null) || ':' || (payment_id is not null) from booking_extensions where id = test.ba('e1:x')),
  'true/10/true:10:80000:2000:weekly:true/confirmed:true:true:true');
select test.eq('E the extension''s charges are lines of their own, tied to its payment; the payment is an extension payment',
  (select string_agg(charge_type || '=' || amount_cents || '+' || hst_cents || ':' || stage || ':' || (extension_id = test.ba('e1:x')) || ':' || (payment_id is not null), ' ' order by amount_cents desc)
     from booking_line_items where booking_id = test.ba('e1') and stage = 'extension')
  || '/' || (select purpose || ':' || amount_cents || ':' || status from payments where booking_id = test.ba('e1') and purpose = 'extension')
  || '/' || app.booking_paid_cents(test.ba('e1')),
  'rental_charge=24000+3120:extension:true:true young_driver_21_25=6000+780:extension:true:true/extension:33900:succeeded/113000');
select test.eq('E the written confirmation is announced once, and the car is now taken to the new return time',
  (select count(*) from app_events where code = 'renter_extension_confirmed' and entity_id = test.ba('e1:x'))
  || '/' || app.vehicle_is_available(test.id('vehicle:BA1'), test.soon('11 days'), test.soon('12 days')), '1/false');
select test.eq('E the same payment reported again changes nothing',
  (select (v ->> 'ok') || '/' || (v ->> 'already_confirmed') from app.confirm_extension_payment(test.ba('e1:x'), '{"payment_id": "pi_e1x"}', 33900) v)
  || '/' || (select count(*) from payments where booking_id = test.ba('e1')), 'true/true/2');
-- declined, withdrawn, not available, lapsed
select test.ba_confirmed('e2', 'tia.tate@example.test', 'BAP', test.soon('3 days'), test.soon('10 days'));
insert into test.ba_ids values ('e2:x1', app.request_extension(test.ba('e2'), test.ba_user('tia.tate@example.test'), test.soon('12 days')));
select test.throws('E declining needs a reason', $$select app.decline_extension(test.ba('e2:x1'), test.id('ba_cs'))$$, 'needs a reason');
select app.decline_extension(test.ba('e2:x1'), test.id('ba_cs'), 'The car is promised to another customer');
select test.eq('E declined by staff with the reason, and the renter is told',
  (select status || '/' || decline_reason || '/' || (declined_by = test.id('ba_cs')) from booking_extensions where id = test.ba('e2:x1'))
  || '/' || (select payload ->> 'decline_reason' from app_events where code = 'renter_extension_declined' and entity_id = test.ba('e2:x1')),
  'declined/The car is promised to another customer/true/The car is promised to another customer');
insert into test.ba_ids values ('e2:x2', app.request_extension(test.ba('e2'), test.ba_user('tia.tate@example.test'), test.soon('12 days')));
select app.decline_extension(test.ba('e2:x2'), test.ba_user('tia.tate@example.test'));
select test.eq('E the renter withdraws their own request (no email for that)',
  (select status || '/' || decline_reason from booking_extensions where id = test.ba('e2:x2'))
  || '/' || (select count(*) from app_events where code = 'renter_extension_declined' and entity_id = test.ba('e2:x2')), 'declined/Withdrawn by the renter/0');
select test.ba_confirmed('e3', 'uma.underhill@example.test', 'BAP', test.soon('11 days'), test.soon('14 days'));
select test.eq('E when the car is booked right after, the preview says so and the request is refused',
  (select (v ->> 'ok') || '/' || (v ->> 'available') || '/' || (v -> 'problems' -> 0 ->> 'code') from app.preview_extension(test.ba('e2'), test.soon('12 days')) v), 'false/false/not_available');
select test.throws('E and asking for it is refused',
  $$select app.request_extension(test.ba('e2'), test.ba_user('tia.tate@example.test'), test.soon('12 days'))$$, 'booked or blocked for part of the added time');
insert into test.ba_ids values ('e2:x3', app.request_extension(test.ba('e2'), test.ba_user('tia.tate@example.test'), test.soon('10 days 12 hours')));
select app.approve_extension(test.ba('e2:x3'), test.id('ba_fleet'));
select test.keep('e2:x3:c', app.confirm_extension_payment(test.ba('e2:x3'), '{"payment_id": "pi_e2x3"}', (select total_cents from booking_extensions where id = test.ba('e2:x3')), test.soon('10 days 1 hour')));
select test.eq('E an approved extension paid after the return time is refused and lapses: refund it',
  (select (v ->> 'reason') || '/' || (v ->> 'action') from test.out('e2:x3:c') v)
  || '/' || (select status from booking_extensions where id = test.ba('e2:x3')) || '/' || (select return_at = test.soon('10 days') from bookings where id = test.ba('e2')),
  'lapsed/refund_payment/lapsed/true');
insert into test.ba_ids values ('e2:x4', app.request_extension(test.ba('e2'), test.ba_user('tia.tate@example.test'), test.soon('10 days 12 hours')));
select test.keep('lapse1', to_jsonb(app.lapse_extensions(test.soon('10 days 1 minute'))));
select test.keep('lapse2', to_jsonb(app.lapse_extensions(test.soon('10 days 1 minute'))));
select test.eq('E requests still open at their return time lapse when the check runs, once',
  (test.out('lapse1') #>> '{}') || '/' || (test.out('lapse2') #>> '{}') || '/' || (select status from booking_extensions where id = test.ba('e2:x4')), '1/0/lapsed');
-- over 7 days in total: the card hold is captured first
select test.ba_confirmed('e4', 'vic.vance@example.test', 'BA3', test.soon('3 days'), test.soon('8 days'));
insert into deposits (booking_id, amount_cents, method, status, taken_at, hold_expires_at) values (test.ba('e4'), 100000, 'card_hold', 'held', now(), now() + interval '7 days');
insert into test.ba_ids values ('e4:x', app.request_extension(test.ba('e4'), test.id('ba_cs'), test.soon('11 days'), 'asked by phone'));
select app.approve_extension(test.ba('e4:x'), test.id('ba_cs'));
select test.eq('E an extension past 7 days in total with a card hold: the preview says the hold must be captured, and the payment is refused until it is',
  (select v ->> 'deposit_hold_capture_needed' from app.preview_extension(test.ba('e4'), test.soon('11 days')) v)
  || '/' || (select v ->> 'reason' from app.confirm_extension_payment(test.ba('e4:x'), '{"payment_id": "pi_e4x"}', (select total_cents from booking_extensions where id = test.ba('e4:x'))) v),
  'true/capture_deposit_first');
update deposits set status = 'captured', captured_cents = 100000 where booking_id = test.ba('e4');
select test.keep('e4:c', app.confirm_extension_payment(test.ba('e4:x'), '{"payment_id": "pi_e4x"}', (select total_cents from booking_extensions where id = test.ba('e4:x'))));
select test.eq('E once the hold is captured as a charged Deposit the extension is confirmed, and says so',
  (select v ->> 'ok' from test.out('e4:c') v)
  || '/' || (select status || ':' || deposit_hold_captured || ':' || (confirmed_by is null) from booking_extensions where id = test.ba('e4:x'))
  || '/' || (select billable_days from bookings where id = test.ba('e4')), 'true/confirmed:true:true/8');

-- ------------------------------------------------------------------ change requests on a confirmed booking
select test.ba_confirmed('ch', 'wes.west@example.test', 'BA8', test.soon('50 days'), test.soon('57 days'));
select test.eq('CH the same dates and car are not a change; a request, an unknown change',
  (select v -> 'problems' -> 0 ->> 'code' from app.preview_booking_change(test.ba('ch'), jsonb_build_object('pickup_at', test.soon('50 days'))) v)
  || '/' || (select v -> 'problems' -> 0 ->> 'code' from app.preview_booking_change(test.ba('r2'), jsonb_build_object('return_at', test.soon('19 days'))) v), 'nothing_changes/not_confirmed');
select test.throws('CH only the dates or the car may change', $$select app.preview_booking_change(test.ba('ch'), '{"deposit_cents": 0}')$$, 'Unknown change');
select test.keep('ch:pv', app.preview_booking_change(test.ba('ch'), jsonb_build_object('pickup_at', test.soon('51 days'), 'return_at', test.soon('58 days'))));
select test.eq('CH moving a 7-day booking by a day costs nothing: before and after, and the difference',
  (select (v ->> 'ok') || '/' || (v -> 'before' ->> 'total_cents') || '/' || (v -> 'after' ->> 'total_cents') || '/' || (v ->> 'total_difference_cents') || '/' || (v ->> 'available')
          || '/' || (v -> 'after' ->> 'billable_days') from test.out('ch:pv') v), 'true/63280/63280/0/true/7');
select test.throws('CH another renter cannot ask for the change',
  $$select app.request_booking_change(test.ba('ch'), test.ba_user('gus.green@example.test'), jsonb_build_object('pickup_at', test.soon('51 days'), 'return_at', test.soon('58 days')))$$,
  'Only the renter of this booking, or staff');
insert into test.ba_ids values ('ch:1', app.request_booking_change(test.ba('ch'), test.ba_user('wes.west@example.test'),
  jsonb_build_object('pickup_at', test.soon('51 days'), 'return_at', test.soon('58 days')), 'My flight moved by a day'));
select test.eq('CH the renter asks: a change request "requested", priced, with what was asked and the booking before and after',
  (select status || '/' || requested_by_role || '/' || note || '/' || total_difference_cents || '/' || ((changes ->> 'pickup_at')::timestamptz = test.soon('51 days'))
          || '/' || ((before ->> 'pickup_at')::timestamptz = test.soon('50 days')) || '/' || ((after ->> 'return_at')::timestamptz = test.soon('58 days')) || '/' || (priced_at is not null)
     from booking_change_requests where id = test.ba('ch:1')), 'requested/renter/My flight moved by a day/0/true/true/true/true');
select test.eq('CH the renter gets an acknowledgement, customer service is told and has a task; nothing has moved',
  (select string_agg(code || ':' || (dedupe_key = code || ':' || entity_id || ':requested'), ' ' order by code) from app_events where entity = 'booking_change_request' and entity_id = test.ba('ch:1'))
  || '/' || (select count(*) from tasks where related_id = test.ba('ch:1') and queue = 'cs') || '/' || (select pickup_at = test.soon('50 days') from bookings where id = test.ba('ch')),
  'renter_change_request_received:true staff_change_request_received:true/1/true');
select test.throws('CH one change request at a time',
  $$select app.request_booking_change(test.ba('ch'), test.ba_user('wes.west@example.test'), jsonb_build_object('return_at', test.soon('59 days')))$$, 'already open');
select test.throws('CH it cannot be applied before staff approve it', $$select app.apply_booking_change(test.ba('ch:1'), test.id('ba_cs'))$$, 'applied once approved');
select test.throws('CH the renter cannot approve their own request', $$select app.approve_booking_change(test.ba('ch:1'), test.ba_user('wes.west@example.test'))$$, 'Only customer service, fleet or an Admin');
select test.keep('ch:1:ap', app.approve_booking_change(test.ba('ch:1'), test.id('ba_cs')));
select test.eq('CH staff approve: a change the renter asked for that costs nothing more needs no further agreement; the renter is told',
  (select status || '/' || (decided_by = test.id('ba_cs')) || '/' || (renter_agreed_at is not null) || '/' || (agreed_by = test.ba_user('wes.west@example.test'))
     from booking_change_requests where id = test.ba('ch:1'))
  || '/' || (select count(*) from app_events where code = 'renter_change_request_approved' and entity_id = test.ba('ch:1')), 'approved/true/true/true/1');
select test.keep('ch:1:done', app.apply_booking_change(test.ba('ch:1'), test.id('ba_cs')));
select test.eq('CH applied: the booking has the new dates, the same price, and the calendar follows (0025: the day before the new pickup ends inside its 2-hour turnaround)',
  (select (v ->> 'ok') || '/' || (v ->> 'status') from test.out('ch:1:done') v)
  || '/' || (select (pickup_at = test.soon('51 days')) || ':' || (return_at = test.soon('58 days')) || ':' || (original_return_at = test.soon('58 days')) || ':' || total_due_at_booking_cents || ':' || status
               from bookings where id = test.ba('ch'))
  || '/' || app.vehicle_is_available(test.id('vehicle:BA8'), test.soon('50 days'), test.soon('51 days')) || '/' || app.vehicle_is_available(test.id('vehicle:BA8'), test.soon('57 days'), test.soon('58 days'))
  || '/' || (select status || ':' || (applied_by = test.id('ba_cs')) || ':' || (applied_at is not null) from booking_change_requests where id = test.ba('ch:1')),
  'true/applied/true:true:true:63280:confirmed/false/false/applied:true:true');
-- a change that costs more: the renter agrees and pays the difference
insert into test.ba_ids values ('ch:2', app.request_booking_change(test.ba('ch'), test.ba_user('wes.west@example.test'), jsonb_build_object('return_at', test.soon('61 days'))));
select app.approve_booking_change(test.ba('ch:2'), test.id('ba_fleet'));
select test.eq('CH three more days: $560 to $800, a difference of $240 + HST $31.20; approved, waiting for the renter to agree',
  (select status || '/' || difference_cents || '/' || hst_cents || '/' || total_difference_cents || '/' || coalesce(renter_agreed_at::text, 'not agreed')
     from booking_change_requests where id = test.ba('ch:2')), 'approved/24000/3120/27120/not agreed');
select test.throws('CH not applied until the renter agrees', $$select app.apply_booking_change(test.ba('ch:2'), test.id('ba_cs'))$$, 'has not agreed');
select test.throws('CH an agreement by phone is for an Admin, and only when nothing more is owed',
  $$select app.agree_booking_change(test.ba('ch:2'), test.id('ba_admin'), null, null, 'agreed on the phone')$$, 'agreed by the renter online');
select test.throws('CH nobody else agrees for the renter', $$select app.agree_booking_change(test.ba('ch:2'), test.id('ba_cs'))$$, 'Only the renter of this booking agrees');
select app.agree_booking_change(test.ba('ch:2'), test.ba_user('wes.west@example.test'), inet '203.0.113.77', 'Mozilla/5.0 (phone)');
select test.eq('CH the renter agrees: when, who and from where are kept',
  (select (renter_agreed_at is not null) || '/' || (agreed_by = test.ba_user('wes.west@example.test')) || '/' || host(agreed_ip) || '/' || agreed_user_agent || '/' || agreed_by_phone
     from booking_change_requests where id = test.ba('ch:2')), 'true/true/203.0.113.77/Mozilla/5.0 (phone)/false');
select test.throws('CH a change that costs more is applied with its payment', $$select app.apply_booking_change(test.ba('ch:2'), test.id('ba_cs'))$$, 'needs a payment of exactly 27120 cents');
select test.throws('CH of exactly the difference',
  $$select app.apply_booking_change(test.ba('ch:2'), test.id('ba_cs'), '{"payment_id": "pi_ch2"}', 27000)$$, 'needs a payment of exactly 27120 cents');
select test.keep('ch:2:done', app.apply_booking_change(test.ba('ch:2'), test.ba_user('wes.west@example.test'), '{"payment_id": "pi_ch2", "charge_id": "ch_ch2"}', 27120));
select test.eq('CH paid and applied: 10 days, rental $800, total $904.00; the difference is its own payment; the rental line follows',
  (select billable_days || ':' || rental_charge_cents || ':' || total_due_at_booking_cents || ':' || km_allowance_total || ':' || rate_applied from bookings where id = test.ba('ch'))
  || '/' || (select purpose || ':' || amount_cents || ':' || status from payments where booking_id = test.ba('ch') and purpose = 'extension')
  || '/' || (select amount_cents || '+' || hst_cents from booking_line_items where booking_id = test.ba('ch') and charge_type = 'rental_charge' and voided_at is null)
  || '/' || app.booking_paid_cents(test.ba('ch'))
  || '/' || (select status || ':' || (payment_id is not null) from booking_change_requests where id = test.ba('ch:2')),
  '10:80000:90400:2000:weekly/extension:27120:succeeded/80000+10400/90400/applied:true');
-- a change that costs less: a refund for approval
insert into test.ba_ids values ('ch:3', app.request_booking_change(test.ba('ch'), test.ba_user('wes.west@example.test'), jsonb_build_object('return_at', test.soon('58 days'))));
select app.approve_booking_change(test.ba('ch:3'), test.id('ba_cs'));
select test.keep('ch:3:done', app.apply_booking_change(test.ba('ch:3'), test.id('ba_cs')));
select test.eq('CH back to 7 days: $271.20 less. Applied at once (the renter asked and owes nothing more), with a refund waiting for approval and a task for Finance',
  (select (v ->> 'total_difference_cents') || '/' || ((v ->> 'refund_id') is not null) from test.out('ch:3:done') v)
  || '/' || (select billable_days || ':' || total_due_at_booking_cents from bookings where id = test.ba('ch'))
  || '/' || (select reason || ':' || amount_cents || ':' || status from refunds where booking_id = test.ba('ch'))
  || '/' || (select count(*) from tasks where booking_id = test.ba('ch') and task_type = 'change_refund' and queue = 'finance'), '-27120/true/7:63280/other:27120:pending_approval/1');
-- declined, withdrawn
insert into test.ba_ids values ('ch:4', app.request_booking_change(test.ba('ch'), test.ba_user('wes.west@example.test'), jsonb_build_object('pickup_at', test.soon('52 days'), 'return_at', test.soon('59 days'))));
select test.throws('CH declining needs a reason', $$select app.decline_booking_change(test.ba('ch:4'), test.id('ba_cs'), ' ')$$, 'needs a reason');
select app.decline_booking_change(test.ba('ch:4'), test.id('ba_cs'), 'The car is due for service that day');
select test.eq('CH declined with the reason, and the renter is told; nothing moved',
  (select status || '/' || decline_reason from booking_change_requests where id = test.ba('ch:4'))
  || '/' || (select payload ->> 'decline_reason' from app_events where code = 'renter_change_request_declined' and entity_id = test.ba('ch:4'))
  || '/' || (select pickup_at = test.soon('51 days') from bookings where id = test.ba('ch')),
  'declined/The car is due for service that day/The car is due for service that day/true');
insert into test.ba_ids values ('ch:5', app.request_booking_change(test.ba('ch'), test.ba_user('wes.west@example.test'), jsonb_build_object('return_at', test.soon('59 days'))));
select app.withdraw_booking_change(test.ba('ch:5'), test.ba_user('wes.west@example.test'));
select test.eq('CH the renter withdraws a request', (select status from booking_change_requests where id = test.ba('ch:5')), 'cancelled');
-- another car
select test.eq('CH (0025) another Owner''s car is possible on a confirmed booking once the renter agrees; the preview raises no Owner problem',
  (select coalesce((select string_agg(p ->> 'code', ',') from jsonb_array_elements(v -> 'problems') p where p ->> 'code' = 'other_owner_vehicle'), 'none')
     from app.preview_booking_change(test.ba('ch'), jsonb_build_object('vehicle_id', test.id('vehicle:BAP'))) v),
  'none');
select test.eq('CH dates on which the car is not free are refused in the preview',
  (select (v ->> 'available') || '/' || (v -> 'problems' -> 0 ->> 'code')
     from app.preview_booking_change(test.ba('ch'), jsonb_build_object('pickup_at', test.soon('12 days'), 'return_at', test.soon('19 days'))) v), 'false/not_available');
insert into test.ba_ids values ('ch:6', app.request_booking_change(test.ba('ch'), test.id('ba_cs'), jsonb_build_object('vehicle_id', test.id('vehicle:BA4')), 'BA8 is going in for service'));
select test.eq('CH staff propose another car of the same Owner, at the booking''s own rates: "proposed", for the renter to agree to',
  (select status || '/' || requested_by_role || '/' || total_difference_cents || '/' || coalesce(renter_agreed_at::text, 'not agreed') from booking_change_requests where id = test.ba('ch:6'))
  || '/' || (select count(*) from app_events where entity_id = test.ba('ch:6')), 'proposed/staff/0/not agreed/1');
select test.throws('CH a proposal is not applied before the renter agrees', $$select app.apply_booking_change(test.ba('ch:6'), test.id('ba_cs'))$$, 'applied once approved');
select app.agree_booking_change(test.ba('ch:6'), test.ba_user('wes.west@example.test'));
select app.apply_booking_change(test.ba('ch:6'), test.id('ba_cs'));
select test.eq('CH agreed and applied: the booking is on the other car, the first car is free, the swap is on record',
  (select (vehicle_id = test.id('vehicle:BA4')) || ':' || (owner_id = test.id('owner:ba_owen')) || ':' || total_due_at_booking_cents from bookings where id = test.ba('ch'))
  || '/' || app.vehicle_is_available(test.id('vehicle:BA8'), test.soon('51 days'), test.soon('58 days')) || '/' || app.vehicle_is_available(test.id('vehicle:BA4'), test.soon('51 days'), test.soon('58 days'))
  || '/' || (select count(*) from booking_vehicle_swaps where booking_id = test.ba('ch') and to_vehicle_id = test.id('vehicle:BA4')), 'true:true:63280/true/false/1');
select test.eq('CH every step of every change is in the booking''s history',
  (select string_agg(details ->> 'step', ' ' order by id) from booking_events where booking_id = test.ba('ch') and kind = 'booking_change'),
  'requested approved applied requested approved agreed applied requested approved applied requested declined requested withdrawn proposed agreed applied');
insert into test.ba_ids values ('ch:7', app.request_booking_change(test.ba('ch'), test.ba_user('wes.west@example.test'), jsonb_build_object('return_at', test.soon('59 days'))));
select app.cancel_booking(test.ba('ch'), test.ba_user('wes.west@example.test'));
select test.eq('CH cancelling the booking closes its open change request', (select status from booking_change_requests where id = test.ba('ch:7')), 'cancelled');

-- ------------------------------------------------------------------ "more information needed" on a request, and the renter's reply
select test.throws('I only staff ask', $$select app.ask_booking_info(test.ba('r2'), test.ba_user('ben.brown@example.test'), 'What time?')$$, 'Only staff');
select test.throws('I a question needs its words', $$select app.ask_booking_info(test.ba('r2'), test.id('ba_cs'), '  ')$$, 'Write the question');
select test.throws('I it is asked on a request, not on a confirmed booking', $$select app.ask_booking_info(test.ba('f1'), test.id('ba_cs'), 'What time?')$$, 'asked on a request');
select test.throws('I the time to answer by is in the future', $$select app.ask_booking_info(test.ba('r2'), test.id('ba_cs'), 'What time?', now() - interval '1 hour')$$, 'in the future');
insert into test.ba_ids values ('i1', app.ask_booking_info(test.ba('r2'), test.id('ba_sales'), 'Will you need the car before 9 am on the first day?'));
select test.eq('I staff ask a question: it is open, with who asked and an answer-by time 24 hours on (a setting); the booking stays a request and shows it is waiting on the renter',
  (select i.status || '/' || (i.asked_by = test.id('ba_sales')) || '/' || (i.reply_by - i.asked_at = interval '24 hours') || '/' || b.status || '/' || (b.awaiting_renter_since is not null)
     from booking_info_requests i join bookings b on b.id = i.booking_id where i.id = test.ba('i1')), 'open/true/true/requested/true');
select test.eq('I the renter is told, with the question and the time to answer by; the question is in the booking''s messages and history',
  (select (payload ->> 'info_request') || '/' || ((payload ->> 'reply_by') is not null) || '/' || (dedupe_key = 'renter_request_needs_info:' || entity_id || ':asked')
     from app_events where code = 'renter_request_needs_info' and entity_id = test.ba('i1'))
  || '/' || (select direction || ':' || channel || ':' || status from messages where related_id = test.ba('i1'))
  || '/' || (select count(*) from booking_events where booking_id = test.ba('r2') and kind = 'info_requested'),
  'Will you need the car before 9 am on the first day?/true/true/outbound:portal:sent/1');
select test.throws('I another renter cannot answer', $$select app.reply_booking_info(test.ba('i1'), test.ba_user('gus.green@example.test'), 'Yes')$$, 'Only the renter of this booking');
select test.throws('I an answer needs its words', $$select app.reply_booking_info(test.ba('i1'), test.ba_user('ben.brown@example.test'), '')$$, 'Write the answer');
select app.reply_booking_info(test.ba('i1'), test.ba_user('ben.brown@example.test'), 'Yes, at 8 am please.');
select test.eq('I the renter answers: answered, with the reply, who and when; the booking no longer waits on the renter; customer service has a task',
  (select i.status || '/' || i.reply || '/' || (i.replied_by = test.ba_user('ben.brown@example.test')) || '/' || (i.replied_at is not null) || '/' || coalesce(b.awaiting_renter_since::text, 'not waiting')
     from booking_info_requests i join bookings b on b.id = i.booking_id where i.id = test.ba('i1'))
  || '/' || (select count(*) || ':' || min(queue) || ':' || min(priority) from tasks where related_id = test.ba('i1') and task_type = 'info_reply_received')
  || '/' || (select count(*) from messages where related_id = test.ba('i1') and direction = 'inbound'),
  'answered/Yes, at 8 am please./true/true/not waiting/1:cs:high/1');
select test.throws('I a question is answered once', $$select app.reply_booking_info(test.ba('i1'), test.ba_user('ben.brown@example.test'), 'Again')$$, 'no longer waits for an answer');
update program_settings set info_request_reply_hours = 6 where effective_from = (select effective_from from app.settings());
insert into test.ba_ids values ('i2', app.ask_booking_info(test.ba('r2'), test.id('ba_cs'), 'Which terminal?'));
insert into test.ba_ids values ('i3', app.ask_booking_info(test.ba('r2'), test.id('ba_cs'), 'Do you need a child seat?', now() + interval '3 hours'));
update program_settings set info_request_reply_hours = 24 where effective_from = (select effective_from from app.settings());
select test.eq('I the answer-by time follows the setting (6 hours), or is given with the question (3 hours)',
  (select string_agg(extract(hour from reply_by - asked_at)::text, ',' order by asked_at, question desc) from booking_info_requests where id in (test.ba('i2'), test.ba('i3'))), '6,3');
select app.close_booking_info(test.ba('i3'), test.id('ba_cs'), 'Asked by phone instead');
select test.eq('I staff close a question that no longer needs an answer; the booking still waits on the other one',
  (select status || ':' || closed_reason from booking_info_requests where id = test.ba('i3')) || '/' || (select awaiting_renter_since is not null from bookings where id = test.ba('r2')),
  'closed:Asked by phone instead/true');
select app.adjust_booking(test.ba('r2'), test.id('ba_cs'), jsonb_build_object('vehicle_id', test.id('vehicle:BA6')));
select app.send_offer(test.ba('r2'), test.id('ba_cs'));
select test.eq('I when the request moves on (an offer is sent) an unanswered question is closed and the waiting flag cleared',
  (select status || ':' || closed_reason from booking_info_requests where id = test.ba('i2')) || '/' || (select coalesce(awaiting_renter_since::text, 'not waiting') from bookings where id = test.ba('r2')),
  'closed:The request moved on before an answer came/not waiting');

-- ------------------------------------------------------------------ identity and coverage documents, and what a handover needs
create function test.ba_driver(p_key text, p_role text) returns uuid language sql stable security definer as $$
  select driver_id from public.booking_drivers where booking_id = (select id from test.ba_ids where k = p_key) and role = p_role order by full_name limit 1
$$;
create function test.ba_up(p_key text, p_role text, p_kind text, p_by uuid, p_tag text default 'a') returns uuid language sql as $$
  select app.register_verification_upload(test.ba(p_key), p_by, p_kind, test.ba_driver(p_key, p_role),
           'renters/' || p_key || '/' || p_role || '/' || p_kind || '-' || p_tag || '.jpg', test.sha(p_key || p_role || p_kind || p_tag), 'image/jpeg')
$$;
create function test.ba_upload(p_key text, p_role text, p_kind text) returns uuid language sql stable security definer as $$
  select u.id from public.verification_uploads u
   where u.booking_id = (select id from test.ba_ids where k = p_key) and u.kind = p_kind
     and u.driver_id is not distinct from (case when p_role is null then null else test.ba_driver(p_key, p_role) end) and u.status = 'submitted'
$$;
create function test.go(p_key text) returns text language plpgsql as $$
begin
  update bookings set status = 'on_rent' where id = test.ba(p_key);
  return 'handed over';
exception when others then
  return sqlerrm;
end $$;
grant execute on all functions in schema test to authenticated, anon;

select test.ba_confirmed('v1', 'xan.xu@example.test', 'BA7', test.soon('3 days'), test.soon('5 days'),
  '{"additional_drivers": [{"full_name": "Yul Xu", "date_of_birth": "1990-03-03", "email": "yul.xu@example.test"}]}');
select test.eq('V a confirmed booking is not ready for handover: nothing is verified yet',
  (select (v ->> 'ready_for_handover') || '/' || (v ->> 'all_drivers_verified') || '/' || (v ->> 'coverage_confirmed') || '/' || (v ->> 'additional_drivers_accepted')
          || '/' || (v ->> 'deposit_ok') || '/' || (v ->> 'agreement_completed') || '/' || (v ->> 'missing')
     from app.booking_readiness(test.ba('v1')) v),
  'false/false/false/false/false/true/["identity", "coverage", "additional_driver_acceptance", "deposit", "pickup_condition_report"]');
select test.eq('V handover is refused: every driver''s identity first', test.go('v1'), 'No car is released until every driver''s identity is verified');
select test.throws('V the coverage proof is not uploaded on a request (the licence is, from 0130)', $$select test.ba_up('r5', 'renter', 'coverage_proof', test.ba_user('amy.adams@example.test'))$$, 'uploaded once the offer is approved');
select test.throws('V an unknown kind of upload is refused', $$select test.ba_up('v1', 'renter', 'passport', test.ba_user('xan.xu@example.test'))$$, 'Unknown kind of upload');
select test.throws('V a stranger cannot register an upload on the booking', $$select test.ba_up('v1', 'renter', 'licence_front', test.ba_user('gus.green@example.test'))$$, 'Not permitted');
select test.throws('V a licence image is for a driver on the booking',
  $$select app.register_verification_upload(test.ba('v1'), test.ba_user('xan.xu@example.test'), 'licence_front', test.ba_driver('f1', 'renter'), 'renters/x/front.jpg')$$, 'not on this booking');
select test.throws('V the proof of coverage belongs to the booking',
  $$select app.register_verification_upload(test.ba('v1'), test.ba_user('xan.xu@example.test'), 'coverage_proof', test.ba_driver('v1', 'renter'), 'bookings/v1/coverage.pdf')$$, 'belongs to the booking');
select test.ba_up('v1', 'renter', 'licence_front', test.ba_user('xan.xu@example.test'));
select test.ba_up('v1', 'renter', 'licence_back', test.ba_user('xan.xu@example.test'));
select test.eq('V two of the three images are in: staff are not asked to review yet',
  (select count(*) from app_events where code = 'staff_identity_review' and entity_id = test.ba('v1')), 0::bigint);
select test.ba_up('v1', 'renter', 'selfie', test.ba_user('xan.xu@example.test'));
select test.eq('V the renter registers licence front, back and selfie: three uploads waiting, one identity check pending with the three files, and staff are asked once',
  (select count(*) || ':' || string_agg(status, ',' order by kind) from verification_uploads where booking_id = test.ba('v1'))
  || '/' || (select method || ':' || status || ':' || (id_front_document_id is not null and id_back_document_id is not null and face_document_id is not null)
               from identity_verifications where booking_id = test.ba('v1') and driver_id = test.ba_driver('v1', 'renter'))
  || '/' || (select count(*) || ':' || min(payload ->> 'kind') from app_events where code = 'staff_identity_review' and entity_id = test.ba('v1'))
  || '/' || (select count(*) || ':' || min(queue) from tasks where booking_id = test.ba('v1') and task_type = 'verify_renter'),
  '3:submitted,submitted,submitted/staff_review:pending:true/1:identity/1:cs');
select test.eq('V each file is a document in private storage: only its key is kept, with the 90-day retention class and a purge date 90 days after the rental ends',
  (select string_agg(d.kind || ':' || d.storage_bucket || ':' || d.retention || ':' || (d.purge_after = b.return_at + interval '90 days') || ':' || (d.sha256 is not null)
                     || ':' || (d.renter_id = b.renter_id), ' ' order by d.kind)
     from verification_uploads u join documents d on d.id = u.document_id join bookings b on b.id = u.booking_id where u.booking_id = test.ba('v1')),
  'id_front:identity:id_face_90d:true:true:true id_back:identity:id_face_90d:true:true:true face_photo:identity:id_face_90d:true:true:true');
select test.eq('V the identity check carries the same purge date',
  (select iv.purge_after = b.return_at + interval '90 days' from identity_verifications iv join bookings b on b.id = iv.booking_id where iv.booking_id = test.ba('v1')), true);
-- review
select test.throws('V a fleet assistant does not review identity documents',
  $$select app.review_verification_upload(test.ba_upload('v1', 'renter', 'selfie'), test.id('ba_fleet'), true)$$, 'Only customer service or an Admin');
select test.throws('V nor does the renter', $$select app.review_verification_upload(test.ba_upload('v1', 'renter', 'selfie'), test.ba_user('xan.xu@example.test'), true)$$, 'Only customer service or an Admin');
select test.throws('V a rejection needs a reason', $$select app.review_verification_upload(test.ba_upload('v1', 'renter', 'selfie'), test.id('ba_cs'), false)$$, 'needs a reason');
insert into test.ba_ids values ('v1:selfie1', test.ba_upload('v1', 'renter', 'selfie'));
select app.review_verification_upload(test.ba('v1:selfie1'), test.id('ba_cs'), false, 'The licence is not readable in the photo');
select test.eq('V a rejected selfie: the upload carries the reason and who decided, the identity check fails, and the renter is told what to fix',
  (select status || '/' || reject_reason || '/' || (reviewed_by = test.id('ba_cs')) from verification_uploads where id = test.ba('v1:selfie1'))
  || '/' || (select status || ':' || failure_reason from identity_verifications where booking_id = test.ba('v1') and driver_id = test.ba_driver('v1', 'renter'))
  || '/' || (select (payload ->> 'kind') || ':' || (payload ->> 'reject_reason') || ':' || (payload ->> 'driver_name') from app_events where code = 'renter_identity_rejected' and entity_id = test.ba('v1')),
  'rejected/The licence is not readable in the photo/true/failed:The licence is not readable in the photo/selfie:The licence is not readable in the photo:Xan Xu');
select test.throws('V a decided upload is not decided again', $$select app.review_verification_upload(test.ba('v1:selfie1'), test.id('ba_cs'), true)$$, 'not waiting for review');
select test.ba_up('v1', 'renter', 'selfie', test.ba_user('xan.xu@example.test'), 'b');
select test.eq('V the renter uploads the selfie again: the rejected one is kept, the new one waits, and the check is pending again',
  (select string_agg(status, ',' order by uploaded_at, status) from verification_uploads where booking_id = test.ba('v1') and kind = 'selfie')
  || '/' || (select status from identity_verifications where booking_id = test.ba('v1') and driver_id = test.ba_driver('v1', 'renter')), 'rejected,submitted/pending');
select app.review_verification_upload(test.ba_upload('v1', 'renter', 'licence_front'), test.id('ba_cs'), true);
select app.review_verification_upload(test.ba_upload('v1', 'renter', 'licence_back'), test.id('ba_cs'), true);
select test.eq('V two of three approved: the driver is not verified yet',
  (select coalesce(identity_verified_on::text, 'not verified') from booking_drivers where booking_id = test.ba('v1') and role = 'renter'), 'not verified');
select app.review_verification_upload(test.ba_upload('v1', 'renter', 'selfie'), test.id('ba_admin'), true);
select test.eq('V all three approved: the identity check is verified by a named person, and the driver''s row on the booking has the method and the date',
  (select iv.status || '/' || (iv.verified_by = test.id('ba_admin')) || '/' || (iv.verified_at is not null) || '/' || d.identity_method || '/' || (d.identity_verified_on = app.today())
          || '/' || (d.identity_verification_id = iv.id) || '/' || dr.identity_status || '/' || r.identity_status
     from identity_verifications iv join booking_drivers d on d.booking_id = iv.booking_id and d.driver_id = iv.driver_id
     join drivers dr on dr.id = d.driver_id join renters r on r.id = dr.renter_id
    where iv.booking_id = test.ba('v1') and d.role = 'renter'), 'verified/true/true/staff_review/true/true/verified/verified');
select test.eq('V handover is still refused: the additional driver is not verified', test.go('v1'), 'No car is released until every driver''s identity is verified');
-- the additional driver, through their own link (the server vouches for them: no user)
select test.ba_up('v1', 'additional', 'licence_front', null); select test.ba_up('v1', 'additional', 'licence_back', null); select test.ba_up('v1', 'additional', 'selfie', null);
select app.review_verification_upload(test.ba_upload('v1', 'additional', 'licence_front'), test.id('ba_cs'), true);
select app.review_verification_upload(test.ba_upload('v1', 'additional', 'licence_back'), test.id('ba_cs'), true);
select test.keep('v1:ready1', app.review_verification_upload(test.ba_upload('v1', 'additional', 'selfie'), test.id('ba_cs'), true));
select test.eq('V every driver verified; coverage still to confirm, so the renter is not yet told "all set"',
  (select (v ->> 'all_drivers_verified') || '/' || (v ->> 'coverage_confirmed') || '/' || (v ->> 'identity_and_coverage_confirmed') from test.out('v1:ready1') v)
  || '/' || (select count(*) from app_events where code = 'renter_identity_approved' and entity_id = test.ba('v1')), 'true/false/false/0');
select test.eq('V handover is refused: a Coverage Option first', test.go('v1'), 'No car is released until a Coverage Option is confirmed');
-- coverage (0070: option 2 is the Card on File, a credit card in the renter's name, after the renter's tick; the
-- card's benefit document is optional; suite 49 covers the rest)
select test.throws('V credit card coverage: the benefit document follows the renter''s confirmation',
  $$select app.register_verification_upload(test.ba('v1'), test.ba_user('xan.xu@example.test'), 'coverage_proof', null, 'bookings/v1/coverage.pdf', null, 'application/pdf',
      '{"coverage_option": 2}')$$, 'Confirm that your card includes rental car coverage first');
select test.throws('V a proof is for the booking''s own option',
  $$select app.register_verification_upload(test.ba('v1'), test.ba_user('xan.xu@example.test'), 'coverage_proof', null, 'bookings/v1/coverage.pdf', null, 'application/pdf',
      jsonb_build_object('coverage_option', 1, 'insurer_name', 'A Test Mutual', 'policy_number', 'P-1', 'policy_expiry', app.today() + 400))$$, 'Change the option first');
select test.throws('V the renter ticks the confirmation', $$select app.submit_card_coverage(test.ba('v1'), test.ba_user('xan.xu@example.test'), false)$$, 'Tick that your card');
select app.submit_card_coverage(test.ba('v1'), test.ba_user('xan.xu@example.test'), true);
select app.register_verification_upload(test.ba('v1'), test.ba_user('xan.xu@example.test'), 'coverage_proof', null, 'bookings/v1/coverage.pdf', test.sha('cov1'), 'application/pdf',
  '{"coverage_option": 2, "card_issuer": "Big Bank", "card_last4": "9999"}');
select test.eq('V the proof of coverage is registered against the booking: a coverage proof "submitted" with the Card on File (not what was typed), its file kept 7 years after the return, and staff are asked to review once',
  (select c.coverage_option || '/' || c.status || '/' || c.card_issuer || '/' || c.card_last4 || '/' || c.card_funding || '/' || d.kind || '/' || d.retention || '/' || (d.purge_after = b.return_at + interval '7 years')
     from coverage_proofs c join documents d on d.id = c.proof_document_id join bookings b on b.id = c.booking_id where c.booking_id = test.ba('v1') and c.status = 'submitted')
  || '/' || (select string_agg(status, ',' order by uploaded_at) from verification_uploads where booking_id = test.ba('v1') and kind = 'coverage_proof')
  || '/' || (select count(*) from app_events where code = 'staff_identity_review' and entity_id = test.ba('v1') and payload ->> 'kind' = 'coverage'),
  '2/submitted/Visa/4242/credit/coverage_proof/records_7y/true/submitted/1');
select test.keep('v1:ready2', app.review_verification_upload(test.ba_upload('v1', null, 'coverage_proof'), test.id('ba_cs'), true));
select test.eq('V approved: the Coverage Option is confirmed on the booking, and now that identity and coverage are both confirmed the renter is told, once',
  (select (v ->> 'identity_and_coverage_confirmed') || '/' || (v ->> 'missing') from test.out('v1:ready2') v)
  || '/' || (select c.status || ':' || (c.confirmed_by = test.id('ba_cs')) from coverage_proofs c where c.booking_id = test.ba('v1') and c.status = 'confirmed')
  || '/' || (select coverage_option || ':' || (coverage_confirmed_at is not null) from bookings where id = test.ba('v1'))
  || '/' || (select count(*) || ':' || bool_and(dedupe_key = 'renter_identity_approved:' || entity_id || ':verified') from app_events where code = 'renter_identity_approved' and entity_id = test.ba('v1')),
  'true/["additional_driver_acceptance", "deposit", "pickup_condition_report"]/confirmed:true/2:true/1:true');
-- the Deposit: taken, or waived by an Admin with a reason
select test.eq('V handover is refused: the Deposit first', test.go('v1'), 'The Deposit is taken at pickup, before handover');
select test.throws('V only an Admin waives the Deposit', $$select app.waive_deposit(test.ba('v1'), test.id('ba_cs'), 'long-standing customer')$$, 'Only an Admin waives the Deposit');
select test.throws('V and with a reason', $$select app.waive_deposit(test.ba('v1'), test.id('ba_admin'), '  ')$$, 'needs a reason');
select test.throws('V and on a confirmed booking, not on a request', $$select app.waive_deposit(test.ba('r5'), test.id('ba_admin'), 'x')$$, 'waived on a confirmed booking');
select app.waive_deposit(test.ba('v1'), test.id('ba_admin'), 'Long-standing customer, approved by Abbas');
select test.eq('V an Admin waives the Deposit with a reason: who, when, why and the amount waived are kept, and it is in the history',
  (select deposit_cents || '/' || deposit_waived_cents || '/' || (deposit_waived_by = test.id('ba_admin')) || '/' || (deposit_waived_at is not null) || '/' || deposit_waived_reason
     from bookings where id = test.ba('v1'))
  || '/' || (select actor_type || ':' || (details ->> 'deposit_waived_cents') from booking_events where booking_id = test.ba('v1') and kind = 'deposit_waived'),
  '0/100000/true/true/Long-standing customer, approved by Abbas/staff:100000');
select test.throws('V a waiver is given once', $$select app.waive_deposit(test.ba('v1'), test.id('ba_admin'), 'again')$$, 'given once');
select test.eq('V handover is refused: the pickup Condition Report', test.go('v1'), 'Handover needs the pickup Condition Report');
insert into condition_reports (vehicle_id, booking_id, kind, odometer_km, fuel_pct, tracker_reporting, licence_seen, card_seen)
values (test.id('vehicle:BA7'), test.ba('v1'), 'pickup', 12000, 100, true, true, true);
select app.set_blocks_calendar(test.ba('v1'), false, test.id('ba_cs'), 'testing the switch');
select test.eq('V handover is refused while the booking does not block the calendar',
  test.go('v1'), 'A booking that does not block the calendar cannot be handed over: turn the calendar switch on first');
select app.set_blocks_calendar(test.ba('v1'), true, test.id('ba_cs'), 'switch back on');
select test.eq('V handover is refused until the additional driver has accepted the agreement',
  test.go('v1'), 'No car is released until every additional driver has accepted the rental agreement');
select app.record_signature(test.ba_sigreq('v1'), test.ba_signer('v1', 'additional_driver'), 'Yul Xu', null, inet '203.0.113.61', 'ua', 'I accept this Rental Agreement as an additional driver.');
select test.eq('V everything is in place: the roll-up says ready',
  (select (v ->> 'ready_for_handover') || '/' || (v ->> 'missing') || '/' || (v ->> 'deposit_taken') || '/' || (v ->> 'deposit_waived') from app.booking_readiness(test.ba('v1')) v),
  'true/[]/false/true');
select test.keep('go:v1', to_jsonb(test.go('v1')));
select test.eq('V and the car is handed over', (test.out('go:v1') #>> '{}') || '/' || test.ba_st('v1') || '/' || (select status::text from vehicles where id = test.id('vehicle:BA7')), 'handed over/on_rent/on_rent');
-- retention follows the end of the rental
insert into condition_reports (vehicle_id, booking_id, kind, odometer_km, fuel_pct) values (test.id('vehicle:BA7'), test.ba('v1'), 'return', 12300, 100);
update bookings set status = 'returned' where id = test.ba('v1');
select test.eq('V at Check-in the purge date of the licence images and face photos becomes 90 days after the rental ended; other documents are not touched (the proof of coverage keeps its 7 years)',
  (select bool_and(d.purge_after = b.checked_in_at + interval '90 days') filter (where d.retention = 'id_face_90d') || '/' || count(*) filter (where d.retention = 'id_face_90d')
          || '/' || count(*) filter (where d.retention <> 'id_face_90d' and d.purge_after is not null)
     from documents d join bookings b on b.id = d.booking_id where b.id = test.ba('v1'))
  || '/' || (select bool_and(iv.purge_after = b.checked_in_at + interval '90 days') from identity_verifications iv join bookings b on b.id = iv.booking_id where b.id = test.ba('v1')),
  'true/7/1/true');
update program_settings set retention_id_face_days = 30 where effective_from = (select effective_from from app.settings());
select test.ba_confirmed('v2', 'zed.zane@example.test', 'BA7', test.soon('20 days'), test.soon('22 days'));
select test.ba_up('v2', 'renter', 'licence_front', test.id('ba_field'));
select test.eq('V the retention period is a setting (here 30 days); field staff may register a licence photo taken at the door',
  (select (d.purge_after = b.return_at + interval '30 days') || '/' || (d.uploaded_by = test.id('ba_field'))
     from verification_uploads u join documents d on d.id = u.document_id join bookings b on b.id = u.booking_id where u.booking_id = test.ba('v2')), 'true/true');
update program_settings set retention_id_face_days = 90 where effective_from = (select effective_from from app.settings());
-- a booking offered with no Deposit still needs an Admin's waiver to be handed over
select test.ba_new('v3', 'abe.ames@example.test', 'BA7', test.soon('30 days'), test.soon('32 days'));
select app.adjust_booking(test.ba('v3'), test.id('ba_cs'), '{"deposit_cents": 0}');
select test.ba_offer('v3'); select test.ba_open('v3'); select test.ba_sign('v3'); select test.ba_pay('v3');
update booking_drivers set identity_method = 'staff_review', identity_verified_on = app.today() where booking_id = test.ba('v3');
insert into coverage_proofs (booking_id, coverage_option, status, card_issuer, card_last4, confirmed_at) values (test.ba('v3'), 2, 'confirmed', 'Bank', '4242', now());
update bookings set coverage_option = 2, coverage_confirmed_at = now() where id = test.ba('v3');
insert into condition_reports (vehicle_id, booking_id, kind, odometer_km, fuel_pct) values (test.id('vehicle:BA7'), test.ba('v3'), 'pickup', 12300, 100);
update vehicles set status = 'available' where id = test.id('vehicle:BA7');
select test.eq('V a booking with no Deposit on it is not handed over without an Admin''s waiver either',
  test.go('v3'), 'No car is released without the Deposit: it is taken at pickup, or waived by an Admin with a reason');
select app.waive_deposit(test.ba('v3'), test.id('ba_admin'), 'Offered without a Deposit: corporate account');
select test.keep('go:v3', to_jsonb(test.go('v3')));
select test.eq('V with the waiver it is', (test.out('go:v3') #>> '{}') || '/' || test.ba_st('v3'), 'handed over/on_rent');

-- ------------------------------------------------------------------ two-step sign-in for staff
select test.eq('AAL with no token there is no assurance level', coalesce(app.session_aal(), 'none'), 'none');
select set_config('request.jwt.claims', '{"aal": "aal1"}', false);
select test.eq('AAL the level is read from the token claims', app.session_aal(), 'aal1');
select test.login(test.id('ba_admin'));
select test.eq('AAL with the switch off (the default) a staff session without a second factor works as before',
  app.is_admin() || '/' || (test.visible('select * from bookings') > 0), 'true/true');
select test.logout();
update program_settings set require_staff_two_step = true where effective_from = (select effective_from from app.settings());
select test.login(test.id('ba_admin'));
select test.eq('AAL with the switch on, an admin session without the second factor is not an admin and reads nothing',
  app.is_admin() || '/' || test.visible('select * from bookings') || '/' || test.visible('select * from rental_agreements') || '/' || test.visible('select * from webhook_events'), 'false/0/0/0');
select test.eq('AAL and changes nothing', test.affected($$update program_settings set require_staff_two_step = false$$), 0::bigint);
select set_config('request.jwt.claims', '{"aal": "aal2"}', false);
select test.eq('AAL with the second factor the same admin reads everything again',
  app.is_admin() || '/' || (test.visible('select * from bookings') > 0) || '/' || (test.visible('select * from webhook_events') > 0), 'true/true/true');
select test.logout();
select set_config('request.jwt.claims', '{"aal": "aal1"}', false);
select test.login(test.id('ba_cs'));
select test.eq('AAL a virtual assistant without the second factor reads nothing either',
  app.is_va() || '/' || app.va_has('cs') || '/' || test.visible('select * from bookings') || '/' || test.visible('select * from booking_info_requests'), 'false/false/0/0');
select test.logout();
select test.login(test.id('ba_field'));
select test.eq('AAL nor is a field staff session field staff', app.is_field(), false);
select set_config('request.jwt.claims', '{"aal": "aal2"}', false);
select test.eq('AAL until the second factor is given', app.is_field(), true);
select test.logout();
select set_config('request.jwt.claims', '{"aal": "aal1"}', false);
select test.login(test.ba_user('gus.green@example.test'));
select test.eq('AAL a customer is not affected: a renter without a second factor still sees their own booking',
  (select count(*) from renter_bookings), 1::bigint);
select test.logout();
update program_settings set require_staff_two_step = false where effective_from = (select effective_from from app.settings());
select set_config('request.jwt.claims', '', false);

-- ------------------------------------------------------------------ row-level security: RENTER
select test.login(test.ba_user('gus.green@example.test'));
select test.eq('renter: reads the agreement of his own booking and no one else''s',
  (select count(*) || '/' || bool_and(booking_id = test.ba('f1')) || '/' || min(status) from rental_agreements), '1/true/completed');
select test.eq('renter: and who signed it (himself, his additional driver, CarmaCars)',
  (select count(*) || '/' || bool_and(agreement_id = test.ba('f1:ag')) from rental_agreement_signers), '3/true');
select test.eq('renter: no processor events, and nothing of other renters'' change requests, questions or uploads',
  test.visible('select * from webhook_events') + test.visible('select * from booking_change_requests') + test.visible('select * from booking_info_requests')
  + test.visible('select * from verification_uploads'), 0::bigint);
select test.eq('renter: no rate limit counters', test.visible('select * from app.rate_limit_hits'), 0::bigint);
select test.throws('renter: cannot write an agreement', $$update rental_agreements set status = 'completed'$$, 'permission denied');
select test.throws('renter: cannot write a signer row', $$update rental_agreement_signers set signed_at = now()$$, 'permission denied');
select test.throws('renter: cannot add a signature by hand',
  format($$insert into signature_records (signature_request_id, signer_role, signer_name, status, signed_at) values (%L, 'renter', 'Gus Green', 'signed', now())$$, test.ba_sigreq('f1')),
  'row-level security');
select test.throws('renter: cannot write a change request', $$insert into booking_change_requests (booking_id, requested_by_role, changes) values (gen_random_uuid(), 'renter', '{}')$$, 'permission denied');
select test.throws('renter: cannot write an upload record', $$update verification_uploads set status = 'approved'$$, 'permission denied');
select test.eq('renter: previews the cancellation of his own booking through the wrapper',
  (select (v ->> 'can_cancel') || '/' || (v ->> 'total_paid_cents') || '/' || ((v ->> 'tier') is not null) from public.my_cancellation_preview(test.ba('f1')) v), 'true/83055/true');
select test.eq('renter: and an extension, a change of dates, the readiness roll-up and a promo code, each for his own booking',
  (select (v ->> 'new_days') || ':' || (v ->> 'total_cents') || ':' || ((v -> 'lines' -> 0) ? 'revenue_class') from public.my_extension_preview(test.ba('f1'), test.soon('20 days')) v)
  || '/' || (select v ->> 'total_difference_cents' from public.my_booking_change_preview(test.ba('f1'), jsonb_build_object('pickup_at', test.soon('11 days'), 'return_at', test.soon('18 days'))) v)
  || '/' || (select v ->> 'agreement_completed' from public.my_booking_readiness(test.ba('f1')) v)
  || '/' || public.my_promo_code_problem('NOPE', test.ba('f1')), '10:35595:false/0/true/This code is not known');
select test.throws('renter: the cancellation preview of someone else''s booking is refused', $$select public.my_cancellation_preview(test.ba('g1'))$$, 'not your booking');
select test.throws('renter: so is the extension preview', $$select public.my_extension_preview(test.ba('g1'), test.soon('40 days'))$$, 'not your booking');
select test.throws('renter: the change preview', $$select public.my_booking_change_preview(test.ba('g1'), '{}')$$, 'not your booking');
select test.throws('renter: the readiness roll-up', $$select public.my_booking_readiness(test.ba('g1'))$$, 'not your booking');
select test.throws('renter: and the promo code check', $$select public.my_promo_code_problem('BA15', test.ba('g1'))$$, 'not your booking');
select test.eq('renter: may ask for a quote and search like any visitor',
  (select v ->> 'total_cents' from public.quote_booking(test.id('vehicle:BA1'), test.at('2029-05-03 10:00'), test.at('2029-05-06 10:00')) v)
  || '/' || (select count(*) > 0 from public.search_available(test.at('2029-05-07 09:00'), test.at('2029-05-10 09:00'))), '38420/true');
select test.throws('renter: cannot price a car that is not on the public listing',
  $$select public.quote_booking(test.id('vehicle:BAU'), test.at('2029-05-03 10:00'), test.at('2029-05-06 10:00'))$$, 'not available to book');
select test.throws('renter: cannot cancel from the browser (the server does it for him)', $$select public.renter_cancel_booking(test.ba('f1'), test.ba_user('gus.green@example.test'))$$, 'permission denied');
select test.throws('renter: nor through the app schema', $$select app.cancel_booking(test.ba('f1'), test.ba_user('gus.green@example.test'))$$, 'permission denied');
select test.throws('renter: cannot submit a request straight to the database', $$select public.submit_booking_request('{}'::jsonb)$$, 'permission denied');
select test.throws('renter: cannot record a signature or a payment',
  $$select app.record_signature(test.ba_sigreq('f1'), test.ba_signer('f1', 'renter'), 'Gus Green', null, null, null, 'x')$$, 'permission denied');
select test.throws('renter: cannot confirm a booking', $$select app.record_booking_payment(test.ba('f1'), '{}', 1, 1)$$, 'permission denied');
select test.throws('renter: cannot register or review an upload', $$select app.review_verification_upload(gen_random_uuid(), test.ba_user('gus.green@example.test'), true)$$, 'permission denied');
select test.throws('renter: cannot waive his own Deposit', $$select app.waive_deposit(test.ba('f1'), test.ba_user('gus.green@example.test'), 'please')$$, 'permission denied');
select test.throws('renter: cannot use the rate limiter', $$select app.rate_limit('x', 1, interval '1 hour')$$, 'permission denied');
select test.logout();
select test.login(test.ba_user('wes.west@example.test'));
select test.eq('renter 2: reads his own change requests, all of them, and only his',
  (select count(*) || '/' || bool_and(booking_id = test.ba('ch')) from booking_change_requests), '7/true');
select test.logout();
select test.login(test.ba_user('ben.brown@example.test'));
select test.eq('renter 3: reads the questions asked on his own request, with his answer',
  (select count(*) || '/' || bool_and(booking_id = test.ba('r2')) || '/' || max(reply) from booking_info_requests), '3/true/Yes, at 8 am please.');
select test.logout();
select test.login(test.ba_user('xan.xu@example.test'));
select test.eq('renter 4: reads the uploads on his own booking (his and his additional driver''s) with the decision on each, and the files behind them',
  (select count(*) || '/' || bool_and(booking_id = test.ba('v1')) || '/' || count(*) filter (where status = 'rejected') from verification_uploads)
  || '/' || (select count(*) from documents where kind in ('id_front', 'id_back', 'face_photo', 'coverage_proof')), '8/true/1/8');
select test.logout();

-- ------------------------------------------------------------------ OWNER
select test.login(test.id('ba_pam'));
select test.eq('owner: none of the new tables, even for a booking on her own car',
  test.visible('select * from rental_agreements') + test.visible('select * from rental_agreement_signers') + test.visible('select * from webhook_events')
  + test.visible('select * from booking_change_requests') + test.visible('select * from booking_info_requests') + test.visible('select * from verification_uploads')
  + test.visible('select * from app.rate_limit_hits'), 0::bigint);
select test.throws('owner: the own-booking previews refuse her', $$select public.my_booking_readiness(test.ba('e2'))$$, 'not your booking');
select test.throws('owner: cannot call the server''s wrappers', $$select public.renter_request_extension(test.ba('e2'), test.id('ba_pam'), now())$$, 'permission denied');
select test.eq('owner: may ask for a quote like any visitor',
  (select v ->> 'rental_charge_cents' from public.quote_booking(test.id('vehicle:BAP'), test.at('2029-05-03 10:00'), test.at('2029-05-06 10:00')) v), '34000');
select test.logout();
select test.login(test.id('ba_owen'));
select test.eq('owner 2: of his own Owner Booking he sees only his own signer row; the agreement itself is read through the server',
  test.visible('select * from rental_agreements') || '/' || (select count(*) || ':' || min(signer_role) from rental_agreement_signers), '0/1:renter');
select test.logout();

-- ------------------------------------------------------------------ VA: customer service
select test.login(test.id('ba_cs'));
select test.eq('cs: reads agreements, signers, change requests, questions and the uploads of customers in their working window; no processor events',
  (test.visible('select * from rental_agreements') > 10) || '/' || (test.visible('select * from rental_agreement_signers') > 20) || '/' || test.visible('select * from booking_change_requests')
  || '/' || test.visible('select * from booking_info_requests') || '/' || test.visible('select * from verification_uploads') || '/' || test.visible('select * from webhook_events'),
  'true/true/7/3/9/0');
select test.throws('cs: cannot write an agreement by hand', $$update rental_agreements set status = 'completed'$$, 'permission denied');
select test.throws('cs: cannot approve an upload by editing it (the server''s function does, with its checks)', $$update verification_uploads set status = 'approved'$$, 'permission denied');
select test.throws('cs: cannot write a change request or a question by hand',
  format($$insert into booking_info_requests (booking_id, question, asked_by, reply_by) values (%L, 'x', %L, now() + interval '1 day')$$, test.ba('r5'), test.id('ba_cs')), 'permission denied');
select test.throws('cs: cannot change the request snapshot on a booking', format($$update bookings set request_details = '{}' where id = %L$$, test.ba('r5')), 'Only an Admin changes request_details');
select test.throws('cs: cannot waive a Deposit by editing the booking',
  format($$update bookings set deposit_waived_at = now(), deposit_waived_by = %L, deposit_waived_reason = 'x' where id = %L$$, test.id('ba_cs'), test.ba('g1')), 'Only an Admin changes deposit_waived_at');
select test.eq('cs: cannot alter a signature', test.affected(format($$update signature_records set signer_name = 'X' where id = %L$$, test.ba('f1:sig'))), 0::bigint);
select test.throws('cs: cannot call the server''s functions', $$select app.approve_extension(gen_random_uuid(), test.id('ba_cs'))$$, 'permission denied');
select test.throws('cs: nor the own-booking previews for a customer', $$select public.my_cancellation_preview(test.ba('f1'))$$, 'not your booking');
select test.logout();

-- ------------------------------------------------------------------ VA: finance, fleet, sales
select test.login(test.id('ba_fin'));
select test.eq('finance: reads agreements, change requests and questions; no signers, no identity uploads, no processor events',
  (test.visible('select * from rental_agreements') > 10) || '/' || test.visible('select * from booking_change_requests') || '/' || test.visible('select * from booking_info_requests')
  || '/' || test.visible('select * from rental_agreement_signers') + test.visible('select * from verification_uploads') + test.visible('select * from webhook_events'), 'true/7/3/0');
select test.throws('finance: cannot write any of them', $$update booking_change_requests set status = 'applied'$$, 'permission denied');
select test.logout();
select test.login(test.id('ba_fleet'));
select test.eq('fleet: reads agreements, change requests and questions; no signers, no identity uploads, no processor events',
  (test.visible('select * from rental_agreements') > 10) || '/' || test.visible('select * from booking_change_requests') || '/' || test.visible('select * from booking_info_requests')
  || '/' || test.visible('select * from rental_agreement_signers') + test.visible('select * from verification_uploads') + test.visible('select * from webhook_events'), 'true/7/3/0');
select test.logout();
select test.login(test.id('ba_sales'));
select test.eq('sales: reads the questions on requests; no agreements, signers, change requests, uploads or processor events',
  test.visible('select * from booking_info_requests') || '/' || test.visible('select * from rental_agreements') + test.visible('select * from rental_agreement_signers')
  + test.visible('select * from booking_change_requests') + test.visible('select * from verification_uploads') + test.visible('select * from webhook_events'), '3/0');
select test.throws('sales: cannot answer for the renter by editing the row', $$update booking_info_requests set status = 'answered', reply = 'x', replied_at = now()$$, 'permission denied');
select test.logout();

-- ------------------------------------------------------------------ FIELD STAFF
select test.login(test.id('ba_field'));
select test.eq('field: none of the new tables',
  test.visible('select * from rental_agreements') + test.visible('select * from rental_agreement_signers') + test.visible('select * from webhook_events')
  + test.visible('select * from booking_change_requests') + test.visible('select * from booking_info_requests') + test.visible('select * from verification_uploads'), 0::bigint);
select test.throws('field: cannot register an upload from the browser (the server does, after checking the file)',
  $$select app.register_verification_upload(test.ba('v2'), test.id('ba_field'), 'licence_back', test.ba_driver('v2', 'renter'), 'x.jpg')$$, 'permission denied');
select test.logout();

-- ------------------------------------------------------------------ ANONYMOUS (the public site)
set role anon;
select test.eq('anon: the price of a listed car, line by line',
  (select (v ->> 'total_cents') || '/' || jsonb_array_length(v -> 'lines') from public.quote_booking(test.id('vehicle:BA1'), test.at('2029-05-03 10:00'), test.at('2029-05-06 10:00')) v), '38420/1');
select test.throws('anon: not the price of a car that is not listed',
  $$select public.quote_booking(test.id('vehicle:BAU'), test.at('2029-05-03 10:00'), test.at('2029-05-06 10:00'))$$, 'not available to book');
select test.eq('anon: listed cars free for the dates with their totals; the public calendar; the published reviews; is a car free',
  (select count(*) > 5 from public.search_available(test.at('2029-05-07 09:00'), test.at('2029-05-10 09:00')))
  || '/' || (select count(*) from public.public_vehicle_calendar(test.id('vehicle:BA7'), date '2029-05-01', date '2029-05-31'))
  || '/' || (select count(*) >= 0 from public.public_reviews())
  || '/' || public.vehicle_is_available(test.id('vehicle:BA7'), test.at('2029-05-08 10:00'), test.at('2029-05-09 10:00')), 'true/1/true/false');
select test.eq('anon: no privilege at all on any new table',
  test.visible('select * from rental_agreements') + test.visible('select * from rental_agreement_signers') + test.visible('select * from webhook_events')
  + test.visible('select * from booking_change_requests') + test.visible('select * from booking_info_requests') + test.visible('select * from verification_uploads')
  + test.visible('select * from app.rate_limit_hits'), -7::bigint);
select test.throws('anon: cannot submit a request straight to the database (the server does, after the bot check)', $$select public.submit_booking_request('{}'::jsonb)$$, 'permission denied');
select test.throws('anon: nor through the app schema', $$select app.submit_booking_request('{}'::jsonb)$$, 'permission denied');
select test.throws('anon: cannot call an own-booking preview', $$select public.my_cancellation_preview(test.ba('f1'))$$, 'permission denied');
select test.throws('anon: cannot call the server''s wrappers', $$select public.renter_approve_offer(test.ba('f1'), 1, test.ba_user('gus.green@example.test'))$$, 'permission denied');
select test.throws('anon: cannot reach the pricing internals', $$select app.price_quote(test.id('vehicle:BAU'), now(), now() + interval '1 day')$$, 'permission denied');
select test.throws('anon: cannot use or reset the rate limiter', $$select app.rate_limit_purge()$$, 'permission denied');
reset role;
-- the optional limit on quotes and searches asked for straight from a browser
update program_settings set public_rate_limit_per_minute = 2 where effective_from = (select effective_from from app.settings());
select set_config('request.headers', '{"cf-connecting-ip": "192.0.2.44", "user-agent": "curl"}', false);
set role anon;
select test.lives('anon: with the limit set to 2 a minute, two quotes from one network address are served',
  $$select public.quote_booking(test.id('vehicle:BA1'), test.at('2029-05-03 10:00'), test.at('2029-05-06 10:00'));
    select public.quote_booking(test.id('vehicle:BA1'), test.at('2029-05-03 10:00'), test.at('2029-05-06 10:00'))$$);
select test.throws('anon: the third is refused',
  $$select public.quote_booking(test.id('vehicle:BA1'), test.at('2029-05-03 10:00'), test.at('2029-05-06 10:00'))$$, 'Too many requests');
select test.eq('anon: searches are counted on their own',
  (select count(*) > 0 from public.search_available(test.at('2029-05-07 09:00'), test.at('2029-05-10 09:00'))), true);
reset role;
select test.lives('anon: the server is never limited',
  $$select app.quote_booking(test.id('vehicle:BA1'), test.at('2029-05-03 10:00'), test.at('2029-05-06 10:00'));
    select app.quote_booking(test.id('vehicle:BA1'), test.at('2029-05-03 10:00'), test.at('2029-05-06 10:00'));
    select app.quote_booking(test.id('vehicle:BA1'), test.at('2029-05-03 10:00'), test.at('2029-05-06 10:00'))$$);
update program_settings set public_rate_limit_per_minute = 0 where effective_from = (select effective_from from app.settings());
select set_config('request.headers', '', false);
select test.eq('anon: still reads exactly one table or view',
  (select string_agg(table_name || ':' || privilege_type, ',') from information_schema.role_table_grants where table_schema = 'public' and grantee = 'anon'),
  'public_vehicle_listings:SELECT');

-- ------------------------------------------------------------------ ADMIN
select test.login(test.id('ba_admin'));
select test.eq('admin: reads every new table, the processor events and the rate limit counters included',
  (test.visible('select * from rental_agreements') > 10) and (test.visible('select * from rental_agreement_signers') > 20) and test.visible('select * from webhook_events') >= 3
  and test.visible('select * from booking_change_requests') = 7 and test.visible('select * from booking_info_requests') = 3
  and test.visible('select * from verification_uploads') = 9 and test.visible('select * from app.rate_limit_hits') > 0, true);
select test.throws('admin: even an admin does not write an agreement from the browser', $$update rental_agreements set status = 'voided'$$, 'permission denied');
select test.throws('admin: nor change a signature', format($$update signature_records set signer_name = 'X' where id = %L$$, test.ba('f1:sig')), 'append-only');
select test.throws('admin: nor delete anything', 'delete from verification_uploads', 'permission denied');
select test.throws('admin: a Deposit waiver from the portal is signed with the admin''s own name',
  format($$update bookings set deposit_waived_at = now(), deposit_waived_by = %L, deposit_waived_reason = 'x' where id = %L$$, test.id('admin_abbas'), test.ba('g1')), 'your own approval');
select test.eq('admin: waives a Deposit from the portal, with a reason',
  test.affected(format($$update bookings set deposit_waived_at = now(), deposit_waived_by = %L, deposit_waived_reason = 'Returning customer' where id = %L$$, test.id('ba_admin'), test.ba('g1'))), 1::bigint);
select test.eq('admin: changes a setting of this migration from the portal',
  test.affected($$update program_settings set booking_min_notice_minutes = 180 where effective_from = (select effective_from from app.settings())$$), 1::bigint);
select test.logout();
update program_settings set booking_min_notice_minutes = 120 where effective_from = (select effective_from from app.settings());
select test.eq('admin: the portal waiver set the Deposit to nil and kept the amount', (select deposit_cents || '/' || deposit_waived_cents from bookings where id = test.ba('g1')), '0/50000');

-- ------------------------------------------------------------------ the events this migration emits
select test.eq('EV every event code this migration emits was emitted by the flows above, each under its dedupe key "code:entity:what"',
  (select string_agg(distinct code, ',' order by code) || '/' || bool_and(dedupe_key like code || ':%:%')
     from app_events
    where code in ('renter_agreement_ready', 'renter_agreement_signed', 'renter_request_needs_info', 'renter_change_request_received', 'staff_change_request_received',
                   'renter_change_request_approved', 'renter_change_request_declined', 'renter_extension_requested', 'staff_extension_requested',
                   'renter_extension_approved', 'renter_extension_declined', 'renter_extension_confirmed', 'staff_identity_review',
                   'renter_identity_approved', 'renter_identity_rejected')
      and entity in ('rental_agreement', 'booking_info_request', 'booking_change_request', 'booking_extension', 'booking')
      and dedupe_key is not null),
  'renter_agreement_ready,renter_agreement_signed,renter_change_request_approved,renter_change_request_declined,renter_change_request_received,renter_extension_approved,'
  || 'renter_extension_confirmed,renter_extension_declined,renter_extension_requested,renter_identity_approved,renter_identity_rejected,renter_request_needs_info,'
  || 'staff_change_request_received,staff_extension_requested,staff_identity_review/true');
