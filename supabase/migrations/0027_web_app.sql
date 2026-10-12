-- 0027: what the public website needs that 0016 to 0026 did not give it.
--
-- 1. public.site_facts(): the policy numbers and the public fee catalogue the website prints
--    (age, notice, deposit tiers, kilometre choices, airports, the fee table, the cancellation tiers,
--    the receiving email aliases), read from program_settings, fee_defaults, deposit_tiers,
--    km_allowance_choices, airports and email_aliases.
--    The cancellation tiers are read back from public.calc_refund_bps, so the page and the rule cannot differ.
-- 2. public.handover_places(vehicle): whether a listed car may be handed over at its Owner's location,
--    and the neighbourhood (never the address).
-- 3. Server wrappers in the public schema for the form drafts of 0022 (save, load, submit), because the
--    app schema is not exposed through the API. service_role only.
-- 4. public.register_account(): the server makes the users row (and the renter role) for a new sign-in
--    account, with the account's own id, as 0001 says (users.id equals auth.users.id). service_role only.
-- 5. public.delivery_origin(): the coordinates delivery distance is measured from. service_role only.

-- ---------------------------------------------------------------- 1. site facts
create or replace function app.public_site_facts() returns jsonb
language plpgsql stable security definer set search_path = public, app as $$
declare
  s program_settings := app.settings();
  v_t0 timestamptz := timestamptz '2026-01-05 12:00 UTC';   -- any instant: the tiers depend on elapsed hours only
  v_grace_bps integer; v_early_bps integer; v_mid_bps integer; v_late_bps integer;
  v_grace_h integer; v_early_h integer; v_late_h integer;
begin
  -- booked long ago, cancelled at t0, pickup h hours later
  v_early_bps := public.calc_refund_bps(v_t0 - interval '30 days', v_t0, v_t0 + interval '30 days', false, false);
  select min(h) into v_early_h from generate_series(1, 24 * 30) h
   where public.calc_refund_bps(v_t0 - interval '30 days', v_t0, v_t0 + make_interval(hours => h), false, false) = v_early_bps;
  v_mid_bps := public.calc_refund_bps(v_t0 - interval '30 days', v_t0, v_t0 + make_interval(hours => greatest(v_early_h - 1, 1)), false, false);
  select min(h) into v_late_h from generate_series(1, 24 * 30) h
   where public.calc_refund_bps(v_t0 - interval '30 days', v_t0, v_t0 + make_interval(hours => h), false, false) = v_mid_bps;
  v_late_bps := public.calc_refund_bps(v_t0 - interval '30 days', v_t0, v_t0 + make_interval(hours => greatest(v_late_h - 1, 0)), false, false);
  -- cancelled soon after booking, well before pickup
  v_grace_bps := public.calc_refund_bps(v_t0 - interval '1 minute', v_t0, v_t0 + interval '30 days', false, false);
  select max(h) into v_grace_h from generate_series(1, 24 * 30) h
   where public.calc_refund_bps(v_t0 - make_interval(hours => h) + interval '1 minute', v_t0, v_t0 + interval '30 days', false, false) = v_grace_bps;

  return jsonb_build_object(
    'hst_bps', s.hst_bps,
    'max_rental_days', s.max_rental_days,
    -- the first length at which the weekly rate applies (renter billing section 2), read back from the rule
    'weekly_from_days', (select min(d) from generate_series(1, s.max_rental_days) d
                          where (select r.rate_applied from public.calc_rental_charge(v_t0, d, 10000, 12000, 56000, 180000) r) like 'weekly%'),
    'min_renter_age', s.min_renter_age,
    'standard_min_age', s.standard_min_age,
    'booking_min_notice_minutes', s.booking_min_notice_minutes,
    'turnaround_buffer_minutes', s.turnaround_buffer_minutes,
    'take_deposit_lead_minutes', s.take_deposit_lead_minutes,
    'deposit_hold_max_days', s.deposit_hold_max_days,
    'deposit_release_business_days', s.deposit_release_business_days,
    'deposit_holdback_days', s.deposit_holdback_days,
    'refund_business_days', s.refund_business_days,
    'offer_expiry_hours', s.offer_expiry_hours,
    'verification_due_hours_before_pickup', s.verification_due_hours_before_pickup,
    'accepted_licence_classes', to_jsonb(s.accepted_licence_classes),
    'other_licence_for_review', s.other_licence_for_review,
    'max_additional_drivers', s.max_additional_drivers,
    'max_baby_seats', s.max_baby_seats,
    'request_note_max_chars', s.request_note_max_chars,
    'deductible_cents', s.deductible_cents,
    'non_refundable_discount_bps', s.non_refundable_discount_bps,
    'damage_late_report_hours', s.damage_late_report_hours,
    'incident_report_hours', s.incident_report_hours,
    'payout_day', s.payout_day,
    'billing_day', s.billing_day,
    'notice_period_days', s.notice_period_days,
    'kickback_bps', s.kickback_bps,
    'install_fee_cents', s.install_fee_cents,
    'delivery_per_km_cents', s.delivery_per_km_cents,
    'delivery_min_cents', s.delivery_min_cents,
    'delivery_max_cents', s.delivery_max_cents,
    'privacy_officer_name', s.privacy_officer_name,
    'privacy_officer_email', s.privacy_officer_email,
    'company_email', s.company_email,
    'incident_line_phone', s.incident_line_phone,
    'young_driver_bands', (
      select coalesce(jsonb_agg(jsonb_build_object('code', f.code,
               'from_age', (regexp_match(f.code, '(\d+)_(\d+)$'))[1]::int,
               'to_age', (regexp_match(f.code, '(\d+)_(\d+)$'))[2]::int) order by f.code), '[]'::jsonb)
        from fee_types f where f.code ~ '^young_driver_\d+_\d+$'),
    'fees', (
      select coalesce(jsonb_object_agg(f.code, jsonb_build_object(
               'label', f.label, 'unit', f.unit, 'amount_cents', d.amount_cents, 'cap_cents', d.cap_cents,
               'percent_bps', d.percent_bps, 'grace_minutes', d.grace_minutes)), '{}'::jsonb)
        from fee_types f
        left join lateral (select * from fee_defaults x
                            where x.fee_type_code = f.code and x.vehicle_class is null
                              and x.effective_from <= current_date and (x.effective_to is null or x.effective_to > current_date)
                            order by x.effective_from desc limit 1) d on true
       where f.code not in ('rental_charge', 'staff_discount', 'promo_discount', 'late_return_extra_days', 'referral_kickback')),
    'deposit_tiers_cents', (select coalesce(jsonb_agg(t.amount_cents order by t.amount_cents), '[]'::jsonb)
                              from deposit_tiers t where t.is_active),
    'km_choices', (select coalesce(jsonb_agg(k.km_per_day order by k.km_per_day desc), '[]'::jsonb)
                     from km_allowance_choices k where k.is_active),
    'email_aliases', (select coalesce(jsonb_object_agg(split_part(e.address, '@', 1), e.address), '{}'::jsonb)
                        from email_aliases e where e.is_active),
    'airports', (select coalesce(jsonb_agg(jsonb_build_object('code', a.code, 'name', a.name, 'surcharge_cents', a.surcharge_cents)
                                           order by a.code desc), '[]'::jsonb)
                   from airports a where a.is_active),
    'cancellation', jsonb_build_object(
      'grace_hours', v_grace_h, 'grace_bps', v_grace_bps,
      'early_hours', v_early_h, 'early_bps', v_early_bps,
      'late_hours', v_late_h, 'mid_bps', v_mid_bps, 'late_bps', v_late_bps));
end $$;

create or replace function public.site_facts() returns jsonb
language sql stable set search_path = public, app as $$ select app.public_site_facts() $$;

-- ---------------------------------------------------------------- 2. handover places
create or replace function app.public_handover_places(p_vehicle uuid) returns jsonb
language sql stable security definer set search_path = public, app as $$
  select jsonb_build_object(
           'vehicle_id', v.id,
           'owner_location', v.management_mode = 'self_managed' or v.owner_pickup_address is not null,
           'area', l.home_area,
           'delivery', true)
    from public_vehicle_listings p join vehicles v on v.id = p.vehicle_id
    join vehicle_listings l on l.vehicle_id = v.id
   where p.vehicle_id = p_vehicle
$$;

create or replace function public.handover_places(p_vehicle uuid) returns jsonb
language sql stable set search_path = public, app as $$ select app.public_handover_places(p_vehicle) $$;

-- ---------------------------------------------------------------- 3. form draft wrappers (server only)
create or replace function public.save_form_draft(p_form_code text, p_data jsonb, p_step text default null,
    p_schema_version integer default 1, p_user uuid default null, p_token text default null,
    p_entity_table text default null, p_entity_id uuid default null, p_device_label text default null)
returns jsonb language sql volatile set search_path = public, app as $$
  select app.save_form_draft(p_form_code, p_data, p_step, p_schema_version, p_user, p_token, p_entity_table, p_entity_id, p_device_label)
$$;

create or replace function public.load_form_draft(p_form_code text, p_user uuid default null, p_token text default null,
    p_entity_table text default null, p_entity_id uuid default null)
returns jsonb language sql volatile set search_path = public, app as $$
  select app.load_form_draft(p_form_code, p_user, p_token, p_entity_table, p_entity_id)
$$;

create or replace function public.submit_form_draft(p_draft uuid, p_result jsonb default '{}'::jsonb)
returns jsonb language sql volatile set search_path = public, app as $$
  select app.submit_form_draft(p_draft, p_result)
$$;

-- ---------------------------------------------------------------- 4. a new sign-in account
create or replace function app.register_account(p_user uuid, p_email text, p_full_name text, p_phone text default null)
returns jsonb language plpgsql security definer set search_path = public, app as $$
declare
  v_email text := lower(btrim(coalesce(p_email, '')));
  v_name text := nullif(btrim(coalesce(p_full_name, '')), '');
  u users;
begin
  if p_user is null then raise exception 'The sign-in account id is needed' using errcode = '22023'; end if;
  if v_email !~ '^[^@\s]+@[^@\s]+\.[^@\s]+$' then
    raise exception 'Enter a full email address, for example name@example.com' using errcode = '22023';
  end if;
  if v_name is null or length(v_name) > 120 then
    raise exception 'Your full name is needed (at most 120 characters)' using errcode = '22023';
  end if;
  select * into u from users where id = p_user;
  if u.id is not null then
    return jsonb_build_object('ok', true, 'created', false, 'user_id', u.id);
  end if;
  select * into u from users where lower(email) = v_email;
  if u.id is not null then
    -- A record made by an earlier request (with its own id). Linking it to the new sign-in account
    -- is done by staff, who can confirm it is the same person.
    return jsonb_build_object('ok', false, 'error', 'email_on_record',
      'message', 'We already have a booking request with this email. Contact us and we will link it to your account.');
  end if;
  insert into users (id, email, phone, full_name, status) values (p_user, v_email, nullif(btrim(coalesce(p_phone, '')), ''), v_name, 'active');
  insert into user_roles (user_id, role) values (p_user, 'renter') on conflict do nothing;
  return jsonb_build_object('ok', true, 'created', true, 'user_id', p_user);
end $$;

create or replace function public.register_account(p_user uuid, p_email text, p_full_name text, p_phone text default null)
returns jsonb language sql volatile set search_path = public, app as $$
  select app.register_account(p_user, p_email, p_full_name, p_phone)
$$;

-- ---------------------------------------------------------------- 5. where delivery distance is measured from (server only)
-- The company's coordinates are not public (CarmaCars is a service-area business); the server reads
-- them to ask the maps service for a driving distance, which it passes to submit_booking_request.
create or replace function app.delivery_origin() returns jsonb
language sql stable security definer set search_path = public, app as $$
  select case when s.company_latitude is not null and s.company_longitude is not null
              then jsonb_build_object('lat', s.company_latitude, 'lng', s.company_longitude) end
    from (select (app.settings()).*) s
$$;
create or replace function public.delivery_origin() returns jsonb
language sql stable set search_path = public, app as $$ select app.delivery_origin() $$;

-- ---------------------------------------------------------------- privileges
do $$
declare f text;
begin
  foreach f in array array[
    'app.public_site_facts()', 'public.site_facts()',
    'app.public_handover_places(uuid)', 'public.handover_places(uuid)',
    'public.save_form_draft(text, jsonb, text, integer, uuid, text, text, uuid, text)',
    'public.load_form_draft(text, uuid, text, text, uuid)',
    'public.submit_form_draft(uuid, jsonb)',
    'app.register_account(uuid, text, text, text)', 'public.register_account(uuid, text, text, text)',
    'app.delivery_origin()', 'public.delivery_origin()']
  loop
    execute format('revoke all on function %s from public, anon, authenticated', f);
    execute format('grant execute on function %s to service_role', f);
  end loop;
  foreach f in array array['app.public_site_facts()', 'public.site_facts()',
                           'app.public_handover_places(uuid)', 'public.handover_places(uuid)']
  loop
    execute format('grant execute on function %s to anon, authenticated', f);
  end loop;
end $$;
