-- 0023_notification_wiring.sql
-- Wiring of the notification layer (0018) to everything built after it (0019 to 0022), run last.
--   1. settings this file adds
--   2. merge payload helpers and the full app.notification_payload() (replaces 0018's base one)
--   3. triggers that emit, through app.emit_event(), every catalogue code that no function of
--      0019 to 0022 emits already (docs/changes/0018_notifications.md has the full table)
--   4. time-based jobs: reminders, late returns, follow-ups and come-back offers, daily checks,
--      digests, field job lists and the weekly summary (pg_cron, the 0015 pattern)
-- Triggers only emit; nothing here can fail the business write that fires it (an emit is an insert
-- with a dedupe key). All the reading and formatting happens later, in app.process_events().

-- ================================================================ 1. settings
alter table program_settings
  add column notify_photo_base_url text not null default 'https://carmacars.ca/media' check (notify_photo_base_url ~ '^https://');

-- ================================================================ 2. merge payload
-- Contact details for every email: 0022's site_settings first, program settings as the fallback.
-- The numbered company name is never read here.
create or replace function app.ntf_contact() returns jsonb
language sql stable security definer set search_path = public, app as $$
  select jsonb_build_object(
    'company_address', coalesce(nullif(ss.mailing_address, ''), nullif(ps.company_address, ''), ''),
    'support_phone',   coalesce(nullif(ss.phone, ''), nullif(ps.company_phone, ''), ''),
    'roadside_phone',  coalesce(nullif(ss.roadside_phone, ''), nullif(ps.incident_line_phone, ''), nullif(ss.phone, ''), nullif(ps.company_phone, ''), ''))
    from (select 1) one
    left join lateral (select * from site_settings order by created_at limit 1) ss on true
    left join lateral (select * from app.settings()) ps on true
$$;

-- A link from emails/src/links.mjs: base URL setting plus the path, its {{variables}} filled.
create or replace function app.ntf_link(p_key text, p_vars jsonb default '{}'::jsonb) returns text
language sql stable security definer set search_path = public, app as $$
  select (app.settings()).notify_base_url || app.render_text(l.path, p_vars) from notification_link_paths l where l.key = p_key
$$;

create or replace function app.ntf_fuel(p_pct integer) returns text
language sql immutable as $$
  select case when p_pct is null then 'Not recorded' when p_pct >= 100 then 'Full' else p_pct || '%' end
$$;

-- Vehicle values: name, plate, VIN, id, public cover photo.
create or replace function app.ntf_vehicle(p_vehicle uuid) returns jsonb
language sql stable security definer set search_path = public, app as $$
  select jsonb_build_object(
    'vehicle_name', app.vehicle_name(v.id),
    'vehicle_plate', coalesce(v.plate, 'Not registered yet'),
    'vehicle_vin', v.vin,
    'vehicle_id', v.id::text,
    'enrollment_date', coalesce(app.fmt_day(v.enrollment_date), 'Not set yet'),
    'vehicle_image_url', coalesce((select (app.settings()).notify_photo_base_url || '/' || ph.processed_path
                                     from vehicle_photos ph
                                    where ph.vehicle_id = v.id and ph.is_public and ph.status = 'approved' and ph.replaced_at is null
                                      and ph.processed_path is not null
                                    order by ph.is_cover desc, ph.sort_order limit 1), ''))
    from vehicles v where v.id = p_vehicle
$$;

-- Lines of a booking as {label, amount}, HST last.
create or replace function app.ntf_lines(p_booking uuid, p_stage text default null, p_statement uuid default null,
                                         p_payment uuid default null, p_extension uuid default null) returns jsonb
language sql stable security definer set search_path = public, app as $$
  with l as (
    select li.*, coalesce(nullif(li.description, ''), f.label, initcap(replace(li.charge_type, '_', ' '))) as label
      from booking_line_items li left join fee_types f on f.code = li.charge_type
     where li.booking_id = p_booking and li.voided_at is null and li.charged_to_renter
       and (p_stage is null or li.stage::text = p_stage)
       and (p_statement is null or li.statement_id = p_statement)
       and (p_payment is null or li.payment_id = p_payment)
       and (p_extension is null or li.extension_id = p_extension))
  select coalesce(jsonb_agg(x.item order by x.ord, x.created_at), '[]'::jsonb)
    from (select jsonb_build_object('label', l.label, 'amount', app.fmt_money(l.amount_cents)) as item, 0 as ord, l.created_at from l
          union all
          select jsonb_build_object('label', 'HST (' || app.fmt_pct((select b.hst_bps from bookings b where b.id = p_booking)) || ')',
                                    'amount', app.fmt_money(sum(l.hst_cents))), 1, max(l.created_at)
            from l having sum(l.hst_cents) <> 0) x
$$;

-- What is still missing before pickup, in words ('' when nothing).
create or replace function app.ntf_missing_items(p_booking uuid) returns text
language sql stable security definer set search_path = public, app as $$
  select coalesce(string_agg(x, ', ' order by o), '')
    from (select 'identity check for ' || d.full_name as x, 1 as o from booking_drivers d
           where d.booking_id = p_booking and d.identity_verified_on is null
          union all
          select 'proof of coverage', 2 from bookings b
           where b.id = p_booking and b.booking_type <> 'owner' and b.coverage_confirmed_at is null) s
$$;

-- The latest tracker reading of a vehicle, in words.
create or replace function app.ntf_tracker_summary(p_vehicle uuid) returns text
language sql stable security definer set search_path = public, app as $$
  select coalesce((
    select case when s.speed_kmh > 0 then 'Moving at ' || round(s.speed_kmh) || ' km/h'
                when s.ignition_on then 'Stopped, ignition on' else 'Parked, ignition off' end
           || ', last report ' || app.fmt_at(s.reported_at)
      from tracker_devices d join tracker_status s on s.tracker_device_id = d.id
     where d.vehicle_id = p_vehicle and d.status = 'installed'
     order by s.reported_at desc limit 1), 'No tracker reading')
$$;

-- Everything a booking email may show. Codes add or override their own values.
create or replace function app.ntf_booking(p_booking uuid) returns jsonb
language plpgsql stable security definer set search_path = public, app as $$
declare
  b bookings;
  r renters;
  pm payment_methods;
  s program_settings := app.settings();
  v_paid bigint;
  v_late bigint;
  pj field_jobs;
  rj field_jobs;
  v_missing text;
  v_next bookings;
  v_deposit deposits;
  v_link jsonb;
begin
  select * into b from bookings where id = p_booking;
  if b.id is null then return '{}'::jsonb; end if;
  select * into r from renters where id = b.renter_id;
  select * into pm from payment_methods where id = b.card_on_file_id;
  if pm.id is null then
    select * into pm from payment_methods where renter_id = b.renter_id and status = 'active' order by created_at desc limit 1;
  end if;
  select coalesce(sum(case when p.kind in ('charge', 'capture') then p.amount_cents else 0 end), 0) into v_paid
    from payments p where p.booking_id = b.id and p.status = 'succeeded' and p.purpose <> 'deposit';
  v_paid := v_paid - coalesce((select sum(f.amount_cents) from refunds f where f.booking_id = b.id and f.status = 'paid'), 0);
  begin
    select t.amount_cents into v_late from app.booking_fee_term(b.id, 'late_return_fee') t;
  exception when others then v_late := null;
  end;
  select * into pj from field_jobs where booking_id = b.id and kind in ('handover', 'delivery') and status <> 'cancelled'
   order by scheduled_at desc limit 1;
  select * into rj from field_jobs where booking_id = b.id and kind in ('return_check_in', 'pickup_from_renter') and status <> 'cancelled'
   order by scheduled_at desc limit 1;
  select * into v_deposit from deposits where booking_id = b.id order by created_at desc limit 1;
  select * into v_next from bookings x
   where x.vehicle_id = b.vehicle_id and x.id <> b.id and x.status in ('confirmed', 'pending_payment') and x.pickup_at > b.pickup_at
   order by x.pickup_at limit 1;
  v_missing := app.ntf_missing_items(b.id);
  v_link := jsonb_build_object('booking_number', b.booking_number);
  return coalesce(app.ntf_vehicle(b.vehicle_id), '{}'::jsonb) || jsonb_build_object(
    'booking_number', b.booking_number,
    'booking_status', replace(b.status::text, '_', ' '),
    'renter_name', r.legal_name,
    'renter_phone', coalesce(r.mobile, ''),
    'customer_first_name', split_part(btrim(r.legal_name), ' ', 1),
    'pickup_date', app.fmt_date(b.pickup_at), 'pickup_time', app.fmt_time(b.pickup_at),
    'pickup_place', coalesce(nullif(b.pickup_place, ''), 'To be confirmed'),
    'return_date', app.fmt_date(b.return_at), 'return_time', app.fmt_time(b.return_at),
    'return_place', coalesce(nullif(b.return_place, ''), nullif(b.pickup_place, ''), 'To be confirmed'),
    'billable_days', b.billable_days::text,
    'rental_charge', app.fmt_money(b.rental_charge_cents),
    'deposit_amount', app.fmt_money(b.deposit_cents),
    'km_allowance', app.fmt_km(b.km_allowance_total),
    'overage_rate', app.fmt_money(b.overage_cents_per_km),
    'late_fee_hourly', coalesce(app.fmt_money(v_late), 'the late fee in your agreement'),
    'card_brand', coalesce(initcap(pm.card_brand), 'Card'),
    'card_last4', coalesce(pm.card_last4, '----'),
    'total_amount', app.fmt_money(coalesce(b.renter_due_at_booking_cents, b.total_due_at_booking_cents)),
    'estimate_amount', app.fmt_money(coalesce(b.renter_due_at_booking_cents, b.total_due_at_booking_cents)),
    'amount_paid', app.fmt_money(greatest(v_paid, 0)),
    'has_amount_paid', v_paid > 0,
    'offer_expires_at', coalesce(app.fmt_at(b.offer_expires_at), ''),
    'is_non_refundable', b.booking_type = 'non_refundable',
    'is_self_managed', b.management_mode = 'self_managed',
    'needs_verification', v_missing <> '',
    'verification_pending', v_missing <> '',
    'missing_items', v_missing,
    'verify_by', app.fmt_at(b.pickup_at - make_interval(hours => coalesce(s.verification_due_hours_before_pickup, 24))),
    'coverage_for_sale', false,
    'renter_note', coalesce(nullif(b.request_note, ''), 'None'),
    'fuel_out', app.ntf_fuel(b.fuel_out_pct), 'fuel_in', app.ntf_fuel(b.fuel_in_pct),
    'odometer_out', coalesce(app.fmt_km(b.odometer_out_km), 'Not recorded'),
    'odometer_in', coalesce(app.fmt_km(b.odometer_in_km), 'Not recorded'),
    'km_driven', coalesce(app.fmt_km(b.odometer_in_km - b.odometer_out_km), 'Not recorded'),
    'checkin_date', coalesce(app.fmt_date(b.checked_in_at), ''), 'checkin_time', coalesce(app.fmt_time(b.checked_in_at), ''),
    'minutes_late', greatest(coalesce(b.minutes_late, (extract(epoch from (now() - b.return_at)) / 60)::integer), 0)::text,
    'field_staff_name', coalesce((select split_part(u.full_name, ' ', 1) from users u where u.id = pj.assigned_to), 'our team'),
    'meeting_note', coalesce(nullif(pj.instructions, ''), 'We will call you when we arrive.'),
    'deposit_method', case v_deposit.method when 'card_hold' then 'held' when 'charged' then 'charged' when 'carried_over' then 'carried over'
                           else 'not taken yet' end,
    'deposit_status', case when v_deposit.id is null then 'Not taken yet' else initcap(replace(v_deposit.status, '_', ' ')) end,
    'line_items', app.ntf_lines(b.id, 'booking'),
    'tracker_summary', app.ntf_tracker_summary(b.vehicle_id),
    'next_booking', coalesce(app.fmt_at(v_next.pickup_at), 'None booked'),
    'booked_at', app.fmt_datetime(b.booked_at),
    '_url', app.ntf_link('booking', v_link));
end $$;

-- The full merge payload of one email. Starts from the shared values (contact, booking or vehicle),
-- adds the event's own values, then each code's values; keeps only the catalogue's variables
-- (and keys starting with _, which steer the digest and are dropped before the outbox).
create or replace function app.notification_payload(p_code text, p_event app_events, p_to jsonb) returns jsonb
language plpgsql stable security definer set search_path = public, app as $$
declare
  s program_settings := app.settings();
  p jsonb := coalesce(p_event.payload, '{}'::jsonb);
  v jsonb;
  x jsonb := '{}'::jsonb;
  c notification_catalogue;
  v_booking uuid;
  v_vehicle uuid;
  v_owner uuid;
  b bookings;
  o owners;
  t toll_tickets;
  i incidents;
  inv owner_invoices;
  st owner_statements;
  bs booking_statements;
  bc booking_cancellations;
  ext booking_extensions;
  cr booking_change_requests;
  ob vehicle_onboardings;
  pay payments;
  rf refunds;
  dep deposits;
  po payouts;
  ir investment_returns;
  rv reviews;
  dp disputes;
  fj field_jobs;
  cl claims;
  ii insurer_invoices;
  sched vehicle_schedules;
  v_first text;
  v_n integer;
  v_cents bigint;
  v_text text;
begin
  select * into c from notification_catalogue where code = p_code;
  v_booking := coalesce((p ->> 'booking_id')::uuid, case when p_event.entity = 'booking' then p_event.entity_id end);
  v_vehicle := coalesce((p ->> 'vehicle_id')::uuid, case when p_event.entity = 'vehicle' then p_event.entity_id end);
  v_owner := coalesce((p ->> 'owner_id')::uuid, (p_to ->> 'owner_id')::uuid, case when p_event.entity = 'owner' then p_event.entity_id end);
  v := app.ntf_contact();
  if v_booking is not null then
    select * into b from bookings where id = v_booking;
    v := v || app.ntf_booking(v_booking);
    v_vehicle := coalesce(v_vehicle, b.vehicle_id);
    if p_to ->> 'audience' = 'owner' then v_owner := coalesce(v_owner, b.owner_id); end if;
  elsif v_vehicle is not null then
    v := v || coalesce(app.ntf_vehicle(v_vehicle), '{}'::jsonb);
  end if;
  if v_owner is null and v_vehicle is not null and p_to ->> 'audience' = 'owner' then
    select owner_id into v_owner from vehicles where id = v_vehicle;
  end if;
  if v_owner is not null then
    select * into o from owners where id = v_owner;
    v := v || jsonb_build_object('owner_name', o.legal_name,
                                 'owner_contact', concat_ws(', ', nullif(o.email, ''), nullif(o.phone, '')),
                                 'owner_type', initcap(o.owner_type::text),
                                 'bank_last4', coalesce((select pm.last4 from owner_payment_methods pm
                                                          where pm.owner_id = o.id and pm.status = 'active' order by pm.is_default desc, pm.created_at desc limit 1),
                                                        (select a.account_last4 from owner_payout_accounts a where a.owner_id = o.id and a.is_current limit 1), '----'));
  end if;

  -- the emitter's own values (already in the template's form unless a code below says otherwise)
  v := v || p;
  v_first := split_part(btrim(coalesce(p_to ->> 'name', '')), ' ', 1);
  if p_to ->> 'audience' = 'owner' and o.id is not null then v_first := coalesce(nullif(o.first_name, ''), split_part(o.legal_name, ' ', 1)); end if;

  case p_code
  -- ------------------------------------------------------------ renter
  when 'renter_account_created', 'owner_account_created' then
    x := jsonb_build_object('link_expiry', '24 hours');
  when 'renter_request_received', 'staff_booking_request_new' then
    x := jsonb_build_object(
      'drivers_summary', (select count(*) || ' driver' || case when count(*) <> 1 then 's' else '' end || ', '
                                 || string_agg(d.licence_class || ' licence, age ' || d.age_at_pickup, '; ')
                            from booking_drivers d where d.booking_id = v_booking),
      'identity_summary', case when v ->> 'missing_items' = '' then 'Verified' else 'Missing: ' || (v ->> 'missing_items') end,
      'renter_history', (select case when count(*) = 0 then 'new renter' else count(*) || ' earlier rental' || case when count(*) > 1 then 's' else '' end end
                           from bookings x2 where x2.renter_id = b.renter_id and x2.id <> b.id and x2.status in ('returned', 'closed')),
      '_url', app.ntf_link(case when p_code like 'staff_%' then 'va_cs_booking' else 'booking_request' end, v));
    x := x || jsonb_build_object('drivers_summary', coalesce(x ->> 'drivers_summary', 'No drivers yet'));
  when 'renter_request_declined' then
    x := jsonb_build_object('decline_reason', coalesce(nullif(p ->> 'note', ''), 'The car is not available for these dates.'));
  when 'renter_request_needs_info' then
    x := jsonb_build_object('info_request', coalesce(p ->> 'info_request', ''), 'reply_by', coalesce(app.fmt_at((p ->> 'reply_by')::timestamptz), ''));
  when 'renter_offer_ready' then
    x := (select jsonb_build_object(
            'is_revised', o2.version > 1,
            'line_items', coalesce((select jsonb_agg(jsonb_build_object('label', coalesce(l ->> 'label', l ->> 'description', initcap(replace(l ->> 'charge_type', '_', ' '))),
                                                                        'amount', coalesce(l ->> 'amount', app.fmt_money((l ->> 'amount_cents')::bigint))))
                                      from jsonb_array_elements(case when jsonb_typeof(o2.line_items) = 'array' then o2.line_items else '[]'::jsonb end) l),
                                   '[]'::jsonb)
                          || jsonb_build_array(jsonb_build_object('label', 'HST (' || app.fmt_pct(b.hst_bps) || ')', 'amount', app.fmt_money(o2.hst_cents))),
            'total_amount', app.fmt_money(o2.renter_due_cents),
            'deposit_amount', app.fmt_money(o2.deposit_cents),
            'offer_expires_at', app.fmt_at(o2.expires_at),
            'offer_note', coalesce(nullif(o2.message, ''), ''),
            'pickup_date', app.fmt_date(o2.pickup_at), 'pickup_time', app.fmt_time(o2.pickup_at),
            'return_date', app.fmt_date(o2.return_at), 'return_time', app.fmt_time(o2.return_at),
            'adjustments', coalesce((select jsonb_agg(a) from (
                 select jsonb_build_object('label', 'Pickup', 'before', app.fmt_at((b.request_details ->> 'pickup_at')::timestamptz), 'after', app.fmt_at(o2.pickup_at)) a
                  where b.request_details ? 'pickup_at' and (b.request_details ->> 'pickup_at')::timestamptz <> o2.pickup_at
                 union all
                 select jsonb_build_object('label', 'Return', 'before', app.fmt_at((b.request_details ->> 'return_at')::timestamptz), 'after', app.fmt_at(o2.return_at))
                  where b.request_details ? 'return_at' and (b.request_details ->> 'return_at')::timestamptz <> o2.return_at) q), '[]'::jsonb))
           from booking_offers o2 where o2.booking_id = v_booking and o2.version = coalesce((p ->> 'offer_version')::integer, b.current_offer_version));
    x := coalesce(x, '{}'::jsonb);
    x := x || jsonb_build_object('has_adjustments', jsonb_array_length(coalesce(x -> 'adjustments', '[]'::jsonb)) > 0,
                                 'adjustments', coalesce(x -> 'adjustments', '[]'::jsonb), 'is_revised', coalesce((x ->> 'is_revised')::boolean, false),
                                 'offer_note', coalesce(x ->> 'offer_note', ''), '_url', app.ntf_link('booking_offer', v));
  when 'renter_offer_reminder' then
    x := jsonb_build_object('time_left', coalesce(p ->> 'time_left',
           greatest(round(extract(epoch from (b.offer_expires_at - now())) / 3600), 1) || ' hours'));
  when 'renter_offer_expired' then
    x := jsonb_build_object('offer_expires_at', coalesce(app.fmt_at((select o2.expires_at from booking_offers o2 where o2.booking_id = v_booking
                                                                       and o2.version = (p ->> 'offer_version')::integer)), v ->> 'offer_expires_at', ''));
  when 'renter_offer_withdrawn' then
    x := jsonb_build_object('withdraw_reason', coalesce(nullif(p ->> 'note', ''),
           case when p ->> 'kind' = 'pushed_back' then 'Another renter confirmed this car for overlapping dates before your offer was approved.'
                else 'We had to take this offer back.' end));
  when 'renter_booking_confirmed' then
    select * into pay from payments where booking_id = v_booking and purpose = 'booking_total' and kind in ('charge', 'capture')
       and status = 'succeeded' order by processed_at desc nulls last, created_at desc limit 1;
    x := jsonb_build_object('receipt_number', 'R-' || upper(left(coalesce(pay.id, v_booking)::text, 8)),
                            'card_brand', coalesce(initcap(pay.card_brand), v ->> 'card_brand'), 'card_last4', coalesce(pay.card_last4, v ->> 'card_last4'),
                            '_url', app.ntf_link('booking', v));
  when 'renter_identity_needed', 'renter_identity_approved', 'renter_booking_reminder' then
    x := jsonb_build_object('_url', app.ntf_link('booking_verify', v));
  when 'renter_identity_rejected' then
    x := jsonb_build_object('driver_name', coalesce(p ->> 'driver_name', v ->> 'renter_name'),
                            'reject_reason', coalesce(nullif(p ->> 'reason', ''), nullif(p ->> 'reject_reason', ''), 'The image could not be read.'),
                            'rejected_item', case p ->> 'kind' when 'licence_front' then 'licence (front)' when 'licence_back' then 'licence (back)'
                                                  when 'selfie' then 'selfie' when 'coverage_proof' then 'proof of coverage'
                                                  else coalesce(replace(p ->> 'kind', '_', ' '), 'document') end);
  when 'renter_agreement_ready' then
    x := jsonb_build_object('signer_role', case p ->> 'signer_role' when 'additional_driver' then 'additional driver' else 'renter' end,
                            'sign_by', case when p ->> 'signer_role' = 'additional_driver' then app.fmt_at(b.pickup_at)
                                            else coalesce(v ->> 'offer_expires_at', app.fmt_at(b.pickup_at)) end,
                            '_url', app.ntf_link('booking_agreement', v));
  when 'renter_agreement_signed' then
    x := jsonb_build_object('signed_at', app.fmt_datetime(coalesce((select a.completed_at from rental_agreements a where a.id = p_event.entity_id), p_event.created_at)),
                            'signers', coalesce((select string_agg(g ->> 'signer_name', ', ') from jsonb_array_elements(p -> 'signers') g), '')
                                       || ', CarmaCars');
  when 'renter_change_request_received', 'staff_change_request_received', 'renter_change_request_approved', 'renter_change_request_declined' then
    select * into cr from booking_change_requests where id = p_event.entity_id;
    x := jsonb_build_object(
      'current_state', case when b.status = 'offered' then 'open offer' else replace(b.status::text, '_', ' ') || ' booking' end,
      'requested_changes', coalesce((select jsonb_agg(jsonb_build_object('label', initcap(replace(k, '_', ' ')),
                                         'before', coalesce(app.fmt_at((cr.before ->> k)::timestamptz), cr.before ->> k, ''),
                                         'after', coalesce(app.fmt_at((cr.after ->> k)::timestamptz), cr.after ->> k, '')))
                                       from jsonb_object_keys(case when jsonb_typeof(cr.after) = 'object' then cr.after else '{}'::jsonb end) k
                                      where (cr.after ->> k) is distinct from (cr.before ->> k) and k like '%\_at'), '[]'::jsonb),
      'change_summary', coalesce(nullif(cr.note, ''), 'Change of dates or car'),
      'decline_reason', coalesce(nullif(cr.decline_reason, ''), nullif(p ->> 'decline_reason', ''), 'We cannot make this change.'),
      'difference_amount', app.fmt_money(abs(coalesce(cr.total_difference_cents, 0))),
      'difference_label', case when coalesce(cr.total_difference_cents, 0) > 0 then 'To pay' when coalesce(cr.total_difference_cents, 0) < 0 then 'To refund' else 'No difference' end,
      'has_difference', coalesce(cr.total_difference_cents, 0) <> 0,
      'accept_by', app.fmt_at(least(b.pickup_at, now() + interval '24 hours')),
      'total_amount', app.fmt_money(coalesce(b.renter_due_at_booking_cents, b.total_due_at_booking_cents) + coalesce(cr.total_difference_cents, 0)));
    x := x || jsonb_build_object('approved_changes', x -> 'requested_changes');
  when 'renter_extension_requested', 'staff_extension_requested', 'renter_extension_approved', 'renter_extension_confirmed', 'renter_extension_declined' then
    select * into ext from booking_extensions where id = p_event.entity_id;
    x := jsonb_build_object(
      'requested_return_date', app.fmt_date(ext.new_return_at), 'requested_return_time', app.fmt_time(ext.new_return_at),
      'new_return_date', app.fmt_date(ext.new_return_at), 'new_return_time', app.fmt_time(ext.new_return_at),
      'return_date', app.fmt_date(ext.previous_return_at), 'return_time', app.fmt_time(ext.previous_return_at),
      'extension_amount', app.fmt_money(ext.total_cents),
      'extension_lines', app.ntf_lines(v_booking, null, null, null, ext.id),
      'new_total_amount', app.fmt_money(coalesce(b.renter_due_at_booking_cents, b.total_due_at_booking_cents) + coalesce(ext.total_cents, 0)),
      'new_length', ext.new_days || ' days',
      'coverage_valid_to', coalesce((select app.fmt_day(cp.policy_expiry) from coverage_proofs cp where cp.booking_id = v_booking and cp.status = 'confirmed'
                                      order by cp.created_at desc limit 1), 'Not on file'),
      'unpaid_charges', app.fmt_money(coalesce((select sum(p2.amount_cents) from payments p2 where p2.booking_id = v_booking and p2.status = 'failed'
                                                   and not exists (select 1 from payments p3 where p3.parent_payment_id = p2.id and p3.status = 'succeeded')), 0)),
      'deposit_note', case when ext.deposit_hold_captured then 'Your deposit stays in place for the new return time.' else 'Your deposit stays as it is.' end,
      'decline_reason', coalesce(nullif(p ->> 'decline_reason', ''), 'The car is booked after your current return time.'));
  when 'renter_payment_failed', 'staff_payment_failed' then
    select * into pay from payments where id = p_event.entity_id;
    x := jsonb_build_object(
      'amount', app.fmt_money(pay.amount_cents), 'amount_due', app.fmt_money(pay.amount_cents),
      'is_booking_payment', pay.purpose = 'booking_total',
      'card_brand', coalesce(initcap(pay.card_brand), v ->> 'card_brand'), 'card_last4', coalesce(pay.card_last4, v ->> 'card_last4'),
      'declined_fee', case when pay.purpose = 'booking_total' then app.fmt_money(0)
                           else coalesce((select app.fmt_money(t2.amount_cents) from app.booking_fee_term(v_booking, 'declined_payment') t2), app.fmt_money(0)) end,
      'interest_rate', coalesce((select app.fmt_pct(t2.percent_bps) from app.booking_fee_term(v_booking, 'interest') t2), 'the rate in your agreement'),
      'next_retry_date', coalesce(to_char(pay.next_retry_at at time zone 'America/Toronto', 'Dy, Mon FMDD'), 'No retry scheduled'),
      'pay_by', app.fmt_at(coalesce(pay.next_retry_at, case when pay.purpose = 'booking_total' then b.offer_expires_at end, now() + interval '1 day')),
      'payment_reason', initcap(replace(pay.purpose, '_', ' ')),
      'next_step_short', case when pay.purpose = 'booking_total' then 'Try another card to confirm your booking.' else 'Pay by another card to avoid a retry.' end,
      'attempt_number', (pay.decline_count + 1)::text,
      '_url', app.ntf_link(case when p_code like 'staff_%' then 'va_finance_booking' else 'booking_pay' end, v));
  when 'renter_payment_receipt' then
    select * into pay from payments where id = p_event.entity_id;
    x := jsonb_build_object('amount', app.fmt_money(pay.amount_cents), 'payment_date', app.fmt_date(coalesce(pay.processed_at, pay.updated_at)),
                            'payment_reason', initcap(replace(pay.purpose, '_', ' ')),
                            'receipt_number', 'R-' || upper(left(pay.id::text, 8)),
                            'receipt_lines', case when jsonb_array_length(app.ntf_lines(v_booking, null, null, pay.id)) > 0 then app.ntf_lines(v_booking, null, null, pay.id)
                                                  else jsonb_build_array(jsonb_build_object('label', initcap(replace(pay.purpose, '_', ' ')), 'amount', app.fmt_money(pay.amount_cents))) end,
                            'card_brand', coalesce(initcap(pay.card_brand), v ->> 'card_brand'), 'card_last4', coalesce(pay.card_last4, v ->> 'card_last4'));
  when 'renter_refund_issued' then
    select * into rf from refunds where id = p_event.entity_id;
    x := jsonb_build_object('refund_amount', app.fmt_money(rf.amount_cents), 'payment_date', app.fmt_date(coalesce(rf.paid_at, now())),
                            'refund_reason', case rf.reason when 'breakdown_unused_days' then 'Unused days after a breakdown'
                                                  when 'pricing_error' then 'A price correction' when 'duplicate' then 'A duplicate charge'
                                                  when 'goodwill' then 'A goodwill refund' else initcap(replace(rf.reason, '_', ' ')) end);
  when 'renter_booking_cancelled', 'renter_booking_cancelled_by_us', 'staff_cancellation_received' then
    select * into bc from booking_cancellations where booking_id = v_booking;
    x := jsonb_build_object(
      'amount_paid', app.fmt_money(bc.total_paid_cents), 'refund_amount', app.fmt_money(bc.refund_cents),
      'has_refund', coalesce(bc.refund_cents, 0) > 0, 'refund_percent', app.fmt_pct(bc.refund_bps),
      'refund_tier', coalesce(replace(bc.tier, '_', ' '), ''), 'cancellation_received_at', app.fmt_datetime(bc.received_at),
      'booked_at', app.fmt_datetime(bc.booked_at),
      'cancel_reason', case bc.reason when 'carmacars_no_vehicle' then 'The car is no longer available for your dates and we could not offer a substitute you accepted.'
                                      when 'driver_not_verifiable' then 'We could not verify a driver on the booking.'
                                      when 'pricing_error' then 'The booking was priced in error.'
                                      else coalesce(nullif(p ->> 'note', ''), 'We had to cancel the booking.') end,
      '_url', app.ntf_link(case when p_code like 'staff_%' then 'va_finance_booking' else 'booking' end, v));
  when 'renter_rental_started' then
    x := jsonb_build_object('_url', app.ntf_link('booking', v));
  when 'renter_return_complete' then
    x := jsonb_build_object('return_findings', coalesce((select case when count(*) = 0 then 'Nothing to report' else count(*) || ' new damage item(s) noted at return' end
                                                           from condition_report_damages dm join condition_reports cr2 on cr2.id = dm.condition_report_id
                                                          where cr2.booking_id = v_booking and cr2.kind = 'return' and dm.is_new), 'Nothing to report'));
  when 'renter_final_statement' then
    select * into bs from booking_statements where id = p_event.entity_id;
    select * into dep from deposits where booking_id = v_booking order by created_at desc limit 1;
    x := jsonb_build_object(
      'statement_lines', app.ntf_lines(v_booking, null, bs.id),
      'charges_total', app.fmt_money(bs.charges_cents + bs.hst_cents), 'has_charges', bs.charges_cents + bs.hst_cents > 0,
      'deposit_applied', app.fmt_money(bs.deposit_applied_cents), 'deposit_held_back', app.fmt_money(bs.held_back_cents),
      'has_holdback', bs.held_back_cents > 0, 'holdback_reason', coalesce(dep.held_back_reason, ''),
      'deposit_returned', app.fmt_money(bs.deposit_returned_cents),
      'deposit_return_note', case when dep.method = 'card_hold' then 'The hold on your card is released; your bank may take a few days to show it.'
                                  else 'The refund goes back to the card you paid with.' end,
      'card_charged', app.fmt_money(bs.charged_to_card_cents), 'has_card_charge', bs.charged_to_card_cents > 0,
      '_url', app.ntf_link('booking_statement', v));
  when 'renter_balance_overdue' then
    select * into bs from booking_statements where id = p_event.entity_id;
    v_cents := bs.charges_cents + bs.hst_cents - bs.deposit_applied_cents - bs.charged_to_card_cents;
    x := jsonb_build_object('amount_due', app.fmt_money(v_cents), 'statement_date', app.fmt_date(bs.issued_at),
                            'interest_rate', coalesce((select app.fmt_pct(t2.percent_bps) from app.booking_fee_term(v_booking, 'interest') t2), 'the rate in your agreement'),
                            'interest_to_date', app.fmt_money(coalesce((select sum(li.amount_cents) from booking_line_items li
                                                                         where li.booking_id = v_booking and li.charge_type = 'interest' and li.voided_at is null), 0)),
                            '_url', app.ntf_link('booking_pay', v));
  when 'renter_damage_found' then
    x := jsonb_build_object('inspection_date', app.fmt_date(coalesce((p ->> 'inspection_at')::timestamptz, p_event.created_at)));
  when 'renter_deposit_declined' then
    x := jsonb_build_object('deposit_amount', app.fmt_money(coalesce((p ->> 'deposit_amount_cents')::bigint, b.deposit_cents)),
                            'card_brand', coalesce(initcap(p ->> 'card_brand'), v ->> 'card_brand'),
                            'deposit_method_text', case when p ->> 'deposit_method' = 'charged' then 'a charge to your card (refunded after the rental)'
                                                        else 'a hold on your card' end);
  when 'renter_deposit_released' then
    x := jsonb_build_object('deposit_held_back', app.fmt_money((p ->> 'deposit_held_back_cents')::bigint),
                            'holdback_applied', app.fmt_money((p ->> 'holdback_applied_cents')::bigint),
                            'release_amount', app.fmt_money((p ->> 'release_amount_cents')::bigint),
                            'holdback_reason', coalesce(p ->> 'holdback_reason', ''));
  when 'renter_extra_charge' then
    select * into bs from booking_statements where id = p_event.entity_id;
    x := jsonb_build_object(
      'charge_type', case p ->> 'charge_kind' when 'damage' then 'Damage' when 'toll' then 'Toll' when 'ticket' then 'Ticket' else initcap(coalesce(p ->> 'charge_kind', 'Charge')) end,
      'charge_lines', app.ntf_lines(v_booking, null, bs.id),
      'charge_total', app.fmt_money(bs.charges_cents + bs.hst_cents),
      'charge_reference', bs.statement_number,
      'charge_summary', initcap(coalesce(p ->> 'charge_kind', 'charge')) || ' charged after your rental',
      'charge_event_date', app.fmt_date(bs.issued_at),
      'charged_to', case p ->> 'charged_from' when 'deposit' then 'your deposit' else 'your card on file' end,
      'payment_date', app.fmt_date(bs.issued_at));
  when 'renter_named_to_authority', 'owner_toll_ticket', 'staff_toll_ticket_logged', 'staff_toll_ticket_unmatched' then
    select * into t from toll_tickets where id = p_event.entity_id;
    v_text := case t.kind when 'toll_invoice' then 'Toll invoice' when 'ticket' then 'Ticket' when 'camera_offence' then 'Camera notice'
                          when 'parking' then 'Parking ticket' when 'fine' then 'Fine' when 'tow' then 'Tow charge' when 'impound' then 'Impound charge'
                          else 'Notice' end;
    x := jsonb_build_object(
      'notice_type', v_text, 'notice_type_lower', lower(v_text),
      'notice_number', coalesce(t.notice_number, 'not shown'),
      'notice_description', concat_ws(', ', coalesce(t.authority, v_text), nullif(t.place, '')),
      'notice_event_date', app.fmt_datetime(t.occurred_at), 'notice_amount', app.fmt_money(t.amount_cents),
      'notice_due_date', coalesce(app.fmt_day(t.due_on), 'Not shown'),
      'authority_name', coalesce(t.authority, 'the issuing authority'),
      'vehicle_plate', t.plate, 'toll_ticket_id', t.id::text,
      'is_forwarded', coalesce((p ->> 'is_forwarded')::boolean, false),
      'notice_action_short', case when coalesce((p ->> 'is_forwarded')::boolean, false) then 'Please pay the authority directly by ' || coalesce(app.fmt_day(t.due_on), 'the due date') || '.'
                                  else 'We paid it. ' || app.fmt_money(t.amount_cents) || ' comes off your next payout, at cost.' end,
      'match_summary', coalesce(nullif(p ->> 'match_summary', ''), replace(t.matched_to, '_', ' ')),
      'logged_at', app.fmt_datetime(t.created_at),
      'nearest_records', coalesce(nullif(t.match_evidence ->> 'nearest', ''), 'No booking or trip covers the time'),
      '_url', case when p_code like 'staff_%' then app.ntf_link('va_finance_toll', jsonb_build_object('toll_ticket_id', t.id)) end);
    if v_booking is null and t.vehicle_id is not null then x := coalesce(app.ntf_vehicle(t.vehicle_id), '{}'::jsonb) || x; end if;
    x := x || jsonb_build_object('vehicle_name', coalesce(v ->> 'vehicle_name', app.vehicle_name(t.vehicle_id), 'Vehicle ' || t.plate));
  when 'renter_late_return_first', 'renter_late_return_final', 'staff_late_return_alert' then
    x := jsonb_build_object('final_deadline', app.fmt_time(now() + make_interval(mins => s.notify_late_final_deadline_minutes)) || ' today',
                            '_url', app.ntf_link(case when p_code like 'staff_%' then 'va_fleet_booking' else 'booking_return' end, v));
  when 'renter_accident_instructions' then
    select * into i from incidents where id = p_event.entity_id;
    x := jsonb_build_object('incident_number', i.incident_number,
                            'report_due', coalesce(app.fmt_at(i.renter_report_due_at), app.fmt_at(i.reported_at + make_interval(hours => coalesce(s.incident_report_hours, 48)))),
                            '_url', app.ntf_link('booking_incident', v));
  when 'renter_breakdown_help' then
    select * into i from incidents where id = p_event.entity_id;
    x := jsonb_build_object('breakdown_location', coalesce(i.place, 'the location you gave us'), 'eta_minutes', coalesce(p ->> 'eta_minutes', 'about 60'));
  when 'renter_vehicle_disabled' then
    null;
  when 'renter_review_request' then
    x := jsonb_build_object('_url', app.ntf_link('booking_review', v));
  when 'renter_comeback_1w', 'renter_comeback_1m' then
    x := jsonb_build_object('last_vehicle_name', v ->> 'vehicle_name', '_url', app.ntf_link('cars'));
  -- ------------------------------------------------------------ owner
  when 'owner_application_received' then
    x := jsonb_build_object('vehicle_name', coalesce(p ->> 'vehicle_name', v ->> 'vehicle_name', 'your vehicle'),
                            'vehicle_plate', coalesce(p ->> 'vehicle_plate', v ->> 'vehicle_plate', 'Not given'),
                            'vehicle_vin', coalesce(p ->> 'vehicle_vin', v ->> 'vehicle_vin', 'Not given'),
                            'ownership_summary', coalesce(p ->> 'ownership_summary', 'As described in your application'));
  when 'owner_agreement_ready', 'owner_agreement_signed', 'owner_onboarding_steps', 'owner_registry_visit', 'owner_vehicle_enrolled', 'owner_application_declined' then
    select * into ob from vehicle_onboardings where id = p_event.entity_id;
    select * into sched from vehicle_schedules where vehicle_id = ob.vehicle_id and superseded_at is null order by created_at desc limit 1;
    v_n := (select count(*) from vehicles v2 where v2.owner_id = o.id and v2.id <> ob.vehicle_id and v2.status not in ('declined', 'onboarding'));
    x := jsonb_build_object(
      'management_mode', initcap(replace(coalesce(sched.management_mode, ob.proposed_management_mode, (select v2.management_mode from vehicles v2 where v2.id = ob.vehicle_id))::text, '_', '-')),
      'onboarding_method', initcap(replace(coalesce(sched.onboarding_method, ob.proposed_onboarding_method, (select v2.onboarding_method from vehicles v2 where v2.id = ob.vehicle_id))::text, '_', ' ')),
      'insurance_fee', coalesce(app.fmt_money(sched.insurance_fee_cents), 'As agreed'),
      'tracker_fee', coalesce(app.fmt_money(sched.tracker_fee_cents), 'As agreed'),
      'revenue_share', coalesce(app.fmt_pct(sched.revenue_share_bps), 'As agreed'),
      'documents_to_sign', case when v_n = 0 then jsonb_build_array(jsonb_build_object('name', 'Enrollment Agreement', 'note', 'Your terms with CarmaCars'),
                                                                     jsonb_build_object('name', 'Title Agreement', 'note', 'How the vehicle is held during the program'),
                                                                     jsonb_build_object('name', 'Vehicle Schedule', 'note', 'The fees and terms for this vehicle'))
                                else jsonb_build_array(jsonb_build_object('name', 'Additional Vehicle Schedule', 'note', 'The fees and terms for this vehicle')) end,
      'has_paper_forms', cardinality(coalesce(ob.government_forms, '{}')) > 0,
      'paper_forms', coalesce(nullif(array_to_string(ob.government_forms, ', '), ''), 'None'),
      'government_forms', coalesce(nullif(array_to_string(ob.government_forms, ', '), ''), 'None for this vehicle'),
      'sign_by', app.fmt_day(app.local_date(coalesce(ob.documents_sent_at, now())) + 7),
      'agreement_number', coalesce((select a.agreement_number from owner_agreements a where a.owner_id = o.id and a.kind = 'enrollment'
                                     order by a.created_at desc limit 1), 'Pending'),
      'document_count', (case when v_n = 0 then 3 else 1 end)::text,
      'signed_at', app.fmt_datetime(coalesce(ob.documents_signed_at, now())),
      'next_step', case when (select v2.is_shareholder_owned from vehicles v2 where v2.id = ob.vehicle_id) then 'We will send the onboarding steps for the vehicle.'
                        else 'Your upfront invoice follows: the install fee and the first and last month of the insurance fee.' end,
      'next_step_short', case when (select v2.is_shareholder_owned from vehicles v2 where v2.id = ob.vehicle_id) then 'Onboarding steps next.' else 'Upfront invoice next.' end,
      'documents_needed', jsonb_build_array(jsonb_build_object('name', 'Ownership permit', 'status', 'Needed'),
                                            jsonb_build_object('name', 'Safety standards certificate', 'status',
                                                               case when ob.safety_certificate_on is not null then 'Received' else 'Needed' end)),
      'owner_to_obtain', case when ob.safety_certificate_on is null then 'A safety standards certificate' else 'Nothing more' end,
      'onboarding_estimate', coalesce(app.fmt_money(coalesce(ob.estimate_cents, sched.onboarding_estimate_cents)), 'To be confirmed'),
      'visit_date', coalesce(app.fmt_date(ob.registry_visit_at), 'To be booked'), 'visit_time', coalesce(app.fmt_time(ob.registry_visit_at), ''),
      'visit_place', coalesce(ob.registry_place, 'To be confirmed'),
      'visit_items', jsonb_build_array(jsonb_build_object('name', 'Your driver''s licence'), jsonb_build_object('name', 'The ownership permit'),
                                       jsonb_build_object('name', 'The signed forms we sent you')),
      'decline_reason', coalesce(nullif(ob.decline_reason, ''), 'The vehicle does not meet the program requirements.'),
      'amount_paid', app.fmt_money(coalesce((select sum(p2.amount_cents) from payments p2 join owner_invoices oi on oi.id = p2.owner_invoice_id
                                               where oi.vehicle_id = ob.vehicle_id and p2.status = 'succeeded'), 0)),
      'has_amount_paid', exists (select 1 from payments p2 join owner_invoices oi on oi.id = p2.owner_invoice_id
                                  where oi.vehicle_id = ob.vehicle_id and p2.status = 'succeeded'),
      'enrollment_date', coalesce(app.fmt_day((select v2.enrollment_date from vehicles v2 where v2.id = ob.vehicle_id)), app.fmt_date(coalesce(ob.enrolled_confirmed_at, now()))),
      '_url', app.ntf_link('owner_vehicle_onboarding', v));
  when 'owner_upfront_invoice', 'owner_fee_invoice', 'owner_payment_received', 'owner_payment_failed', 'owner_in_arrears', 'staff_owner_invoice_failed' then
    select * into inv from owner_invoices where id = p_event.entity_id;
    x := jsonb_build_object(
      'invoice_number', inv.invoice_number,
      'invoice_total', app.fmt_money(inv.total_cents), 'amount', app.fmt_money(inv.total_cents),
      'invoice_lines', coalesce((select jsonb_agg(jsonb_build_object('label', coalesce(l.description, initcap(replace(l.kind, '_', ' '))), 'amount', app.fmt_money(l.amount_cents)) order by l.created_at)
                                   from owner_invoice_lines l where l.owner_invoice_id = inv.id), '[]'::jsonb)
                       || jsonb_build_array(jsonb_build_object('label', 'HST', 'amount', app.fmt_money(inv.hst_cents))),
      'invoice_month', coalesce(to_char(inv.period_month, 'FMMonth'), to_char(inv.billing_date, 'FMMonth')),
      'invoice_period', coalesce(to_char(inv.period_month, 'FMMonth YYYY'), app.fmt_day(inv.billing_date)),
      'payment_date', app.fmt_date(coalesce(inv.paid_at, now())),
      'payment_method', case inv.payment_method when 'pre_authorized_debit' then 'Pre-authorized debit' when 'card' then 'Card' else 'e-Transfer' end,
      'late_fee', app.fmt_money(coalesce(nullif(inv.late_fee_cents, 0), s.owner_late_fee_cents)),
      'retry_amount', app.fmt_money(coalesce(inv.total_cents, 0) + case when inv.late_fee_cents = 0 then s.owner_late_fee_cents else 0 end),
      'retry_date', coalesce(app.fmt_day(inv.retry_on), 'the retry date'),
      'arrears_amount', app.fmt_money(coalesce(inv.balance_cents, inv.total_cents)),
      'removal_date', coalesce(app.fmt_day(inv.removal_allowed_on), 'Not set'),
      'next_payout_date', app.fmt_day(make_date(extract(year from (app.today() + 20))::integer, extract(month from (app.today() + 20))::integer, s.payout_day)),
      'is_self_managed', (select v2.management_mode = 'self_managed' from vehicles v2 where v2.id = inv.vehicle_id),
      'bank_reason', coalesce(nullif(p ->> 'bank_reason', ''), 'Returned by the bank'),
      'failure_stage', case inv.status when 'in_arrears' then 'retry failed, in arrears' else 'first failure' end,
      'failure_next_step', case inv.status when 'in_arrears' then 'The vehicle is in arrears; the amount comes off the next payout.'
                                else 'Retry on ' || coalesce(app.fmt_day(inv.retry_on), 'the retry date') || '.' end,
      '_url', app.ntf_link(case when p_code like 'staff_%' then 'va_finance_invoice' else 'owner_invoice' end, jsonb_build_object('invoice_number', inv.invoice_number)));
    x := x || coalesce(app.ntf_vehicle(inv.vehicle_id), '{}'::jsonb);
  when 'owner_new_booking', 'owner_booking_confirmed' then
    x := jsonb_build_object('renter_name', case when b.management_mode = 'self_managed' then v ->> 'renter_name' else '' end,
                            'renter_phone', case when b.management_mode = 'self_managed' then v ->> 'renter_phone' else '' end,
                            '_url', app.ntf_link('owner_booking', v));
  when 'owner_payout_sent' then
    select * into po from payouts where id = p_event.entity_id;
    select * into st from owner_statements where id = po.owner_statement_id;
    x := jsonb_build_object('payout_amount', app.fmt_money(po.amount_cents + po.hst_cents), 'payment_date', app.fmt_date(coalesce(po.paid_at, now())),
                            'payout_reference', coalesce(po.reference, ''), 'statement_month', coalesce(to_char(st.statement_month, 'FMMonth'), ''),
                            'statement_number', coalesce(st.statement_number, ''));
  when 'owner_statement_ready' then
    select * into st from owner_statements where id = p_event.entity_id;
    x := jsonb_build_object(
      'statement_month', to_char(st.statement_month, 'FMMonth'), 'statement_number', st.statement_number,
      'rentals_total', app.fmt_money(st.owner_revenue_cents), 'owner_revenue_total', app.fmt_money(st.owner_revenue_cents),
      'revenue_share_total', app.fmt_money(st.revenue_share_cents), 'deductions_total', app.fmt_money(st.deductions_cents),
      'kickbacks_earned', app.fmt_money(st.kickbacks_earned_cents), 'kickbacks_deducted', app.fmt_money(0),
      'balance_forward', app.fmt_money(st.balance_brought_forward_cents), 'has_balance_forward', st.balance_brought_forward_cents <> 0,
      'payout_hst', app.fmt_money(st.hst_on_payout_cents), 'has_payout_hst', st.hst_on_payout_cents > 0,
      'payout_amount', app.fmt_money(greatest(st.payout_cents, 0)),
      'payout_label', case when st.payout_cents > 0 then 'Payout on ' || app.fmt_day(st.payout_date) else 'Balance carried forward' end,
      'payout_summary', case when st.payout_cents > 0 then app.fmt_money(st.payout_cents) || ' is paid to your account on ' || app.fmt_day(st.payout_date) || '.'
                             else 'No payout this month: ' || app.fmt_money(-st.balance_carried_forward_cents) || ' is carried forward.' end,
      'statement_vehicles', coalesce((select jsonb_agg(jsonb_build_object('name', app.vehicle_name(sv.vehicle_id), 'owner_revenue', app.fmt_money(sv.owner_revenue_cents),
                                                                          'payable', app.fmt_money(sv.payable_cents)))
                                        from owner_statement_vehicles sv where sv.owner_statement_id = st.id), '[]'::jsonb),
      '_url', app.ntf_link('owner_statement', jsonb_build_object('statement_number', st.statement_number)));
  when 'owner_incident_opened', 'owner_incident_update', 'staff_incident_reported', 'staff_breakdown_reported' then
    select * into i from incidents where id = p_event.entity_id;
    select * into cl from claims where incident_id = i.id order by created_at desc limit 1;
    x := jsonb_build_object(
      'incident_number', i.incident_number, 'incident_date', app.fmt_date(coalesce(i.occurred_at, i.reported_at)),
      'incident_type', initcap(replace(i.kind, '_', ' ')),
      'incident_summary', coalesce(nullif(i.description, ''), initcap(replace(i.kind, '_', ' ')) || ' reported'),
      'incident_place', coalesce(i.place, 'Not recorded'), 'breakdown_location', coalesce(i.place, 'Not recorded'),
      'breakdown_symptom', coalesce(replace(i.breakdown_cause, '_', ' '), coalesce(nullif(i.description, ''), 'Not recorded')),
      'vehicle_location', coalesce(i.place, 'With CarmaCars'),
      'drivable', case i.drivable when true then 'Yes' when false then 'No' else 'Not known' end,
      'injuries', case i.anyone_hurt when true then 'Yes, reported' when false then 'None reported' else 'Not known' end,
      'police_report', coalesce(i.police_report_number, 'None given'),
      'requested_at', app.fmt_at(i.reported_at), 'requested_by', coalesce((select u.full_name from users u where u.id = i.opened_by), 'The renter'),
      'incident_status', initcap(replace(coalesce(cl.status, i.status), '_', ' ')),
      'incident_update', coalesce(nullif(p ->> 'update_text', ''), 'The claim is now ' || replace(coalesce(cl.status, i.status), '_', ' ') || '.'),
      'incident_update_short', 'Claim ' || replace(coalesce(cl.status, i.status), '_', ' '),
      'update_date', app.fmt_date(now()), 'expected_back', 'We will confirm the date when repairs are booked',
      'owner_action', 'Nothing for now. We will tell you if we need anything.',
      '_url', app.ntf_link(case when p_code like 'owner_%' then 'owner_claim' else 'admin_incident' end, jsonb_build_object('incident_number', i.incident_number)));
    x := x || jsonb_build_object('owner_name', coalesce((select o2.legal_name from owners o2 join vehicles v2 on v2.owner_id = o2.id where v2.id = i.vehicle_id), ''),
                                 'booking_number', coalesce(v ->> 'booking_number', 'No booking'), 'renter_name', coalesce(v ->> 'renter_name', 'No renter'),
                                 'renter_phone', coalesce(v ->> 'renter_phone', ''));
  when 'staff_monthly_statements_ready' then
    x := (select jsonb_build_object(
            'statement_month', to_char(cs.statement_month, 'FMMonth YYYY'),
            'company_statement_status', case when cs.ties_ok then 'Final, ties out' else 'Final, check the ties' end,
            'owner_statement_count', (select count(*) from owner_statements os where os.statement_month = cs.statement_month and os.status <> 'void')::text,
            'draft_count', (select count(*) from owner_statements os where os.statement_month = cs.statement_month and os.status = 'draft')::text,
            'owner_revenue_total', app.fmt_money(coalesce((select sum(os.owner_revenue_cents) from owner_statements os where os.statement_month = cs.statement_month and os.status <> 'void'), 0)),
            'revenue_share_total', app.fmt_money(coalesce((select sum(os.revenue_share_cents) from owner_statements os where os.statement_month = cs.statement_month and os.status <> 'void'), 0)),
            'payout_total', app.fmt_money(coalesce((select sum(greatest(os.payout_cents, 0)) from owner_statements os where os.statement_month = cs.statement_month and os.status <> 'void'), 0)),
            'payout_date', app.fmt_day(coalesce((select min(os.payout_date) from owner_statements os where os.statement_month = cs.statement_month and os.status <> 'void'),
                                                make_date(extract(year from cs.statement_month + interval '1 month')::integer,
                                                          extract(month from cs.statement_month + interval '1 month')::integer, s.payout_day))),
            '_url', app.ntf_link('admin_statements'))
            from company_statements cs where cs.id = p_event.entity_id);
    x := coalesce(x, '{}'::jsonb);
  when 'staff_dispute_opened' then
    select * into dp from disputes where id = p_event.entity_id;
    select * into pay from payments where id = dp.payment_id;
    x := jsonb_build_object('dispute_id', dp.id::text, 'amount', app.fmt_money(dp.amount_cents), 'dispute_reason', coalesce(dp.reason, 'Not given'),
                            'evidence_due', coalesce(app.fmt_at(dp.evidence_due_at), 'Not given'), 'owner_revenue_in_dispute', app.fmt_money(dp.owner_revenue_withheld_cents),
                            'payment_date', app.fmt_date(coalesce(pay.processed_at, pay.created_at)), 'payment_reason', initcap(replace(pay.purpose, '_', ' ')),
                            'booking_number', coalesce(v ->> 'booking_number', 'none'), 'renter_name', coalesce(v ->> 'renter_name', ''),
                            'vehicle_name', coalesce(v ->> 'vehicle_name', ''),
                            '_url', app.ntf_link('admin_dispute', jsonb_build_object('dispute_id', dp.id)));
  when 'staff_review_received' then
    select * into rv from reviews where id = p_event.entity_id;
    x := jsonb_build_object('review_rating', rv.rating::text, 'review_title', coalesce(rv.title, ''), 'review_text', coalesce(rv.body, ''),
                            '_url', app.ntf_link('va_cs_reviews'), '_digest_meta', rv.rating || ' stars');
  when 'staff_offer_approved_paid' then
    x := jsonb_build_object('coverage_summary', case when b.coverage_confirmed_at is not null then 'Confirmed' else 'No proof yet' end,
                            'identity_summary', case when v ->> 'missing_items' = '' then 'Verified' else 'Missing: ' || (v ->> 'missing_items') end,
                            '_url', app.ntf_link('va_cs_booking', v));
  when 'staff_identity_review' then
    x := jsonb_build_object('driver_name', coalesce(p ->> 'driver_name', v ->> 'renter_name'),
                            'driver_role', coalesce(replace(p ->> 'driver_role', '_', ' '), 'renter'),
                            'documents_summary', coalesce(p ->> 'kind', 'identity') || ' documents uploaded',
                            '_url', app.ntf_link('va_cs_identity', v));
  when 'staff_return_findings' then
    x := jsonb_build_object('deposit_amount', app.fmt_money(coalesce((p ->> 'deposit_amount_cents')::bigint, b.deposit_cents)),
                            'deposit_release_due', coalesce(app.fmt_day((p ->> 'deposit_release_due')::date), 'Not set'),
                            'findings_headline', case when coalesce((p ->> 'has_damage')::boolean, false) then 'New damage found at return' else 'No new damage' end,
                            'damage_summary', coalesce(p ->> 'damage_summary', case when coalesce((p ->> 'has_damage')::boolean, false) then 'See the return report' else 'None' end),
                            'cleaning_grade', coalesce(p ->> 'cleaning_grade', 'standard'), 'keys_summary', coalesce(p ->> 'keys_summary', 'Not recorded'),
                            '_url', app.ntf_link('va_finance_booking', v));
  when 'staff_disable_approval_needed' then
    x := jsonb_build_object('disable_ground', replace(coalesce(p ->> 'disable_ground', ''), '_', ' '),
                            'final_notice_at', coalesce(app.fmt_at((p ->> 'final_notice_at')::timestamptz), 'Not sent'),
                            'requested_at', app.fmt_at(coalesce((p ->> 'requested_at')::timestamptz, p_event.created_at)),
                            'requested_by', coalesce((select u.full_name from users u where u.id = (p ->> 'requested_by')::uuid), 'Staff'),
                            'tracker_summary', app.ntf_tracker_summary(v_vehicle),
                            '_url', app.ntf_link('admin_approvals'));
  when 'staff_approval_needed' then
    x := jsonb_build_object('approval_type', initcap(replace(coalesce(p ->> 'approval_type', 'approval'), '_', ' ')),
                            'approval_subject', coalesce(p ->> 'approval_subject', ''), 'approval_reason', coalesce(p ->> 'approval_reason', ''),
                            'approval_summary', concat_ws(': ', p ->> 'approval_subject', p ->> 'approval_reason'),
                            'approval_due', coalesce(to_char(coalesce((p ->> 'approval_due')::timestamptz, now()) at time zone 'America/Toronto', 'Dy, Mon FMDD'), ''),
                            'amount', coalesce(app.fmt_money((p ->> 'amount_cents')::bigint), 'None'),
                            'requested_at', app.fmt_at(coalesce((p ->> 'requested_at')::timestamptz, p_event.created_at)),
                            'requested_by', coalesce((select u.full_name from users u where u.id = (p ->> 'requested_by')::uuid), 'The system'),
                            '_url', app.ntf_link('admin_approvals'));
  when 'staff_owner_application_received' then
    x := jsonb_build_object('application_id', coalesce((select a.application_number from owner_applications a where a.owner_id = v_owner order by a.created_at desc limit 1),
                                                        p_event.entity_id::text),
                            'owner_name', coalesce(p ->> 'owner_name', v ->> 'owner_name', ''),
                            'owner_contact', coalesce(nullif(concat_ws(', ', nullif(p ->> 'email', ''), nullif(p ->> 'phone', '')), ''), v ->> 'owner_contact', ''),
                            'owner_type', coalesce(v ->> 'owner_type', 'Not given'),
                            'management_mode', initcap(replace(coalesce(p ->> 'management_mode', 'not chosen yet'), '_', '-')),
                            'ownership_summary', coalesce(p ->> 'ownership_summary', p ->> 'situation', 'See the application'),
                            'current_insurer', coalesce((select ob2.current_insurer from vehicle_onboardings ob2 where ob2.id = p_event.entity_id), 'Not given'),
                            'lender', coalesce((select ob2.finance_party_name from vehicle_onboardings ob2 where ob2.id = p_event.entity_id), 'None'),
                            'referred_by', 'Not given', 'vehicle_km', coalesce(app.fmt_km((select v2.odometer_km from vehicles v2 where v2.id = v_vehicle)), 'Not given'),
                            'vehicle_name', coalesce(p ->> 'vehicle_name', v ->> 'vehicle_name', 'Not given'),
                            'vehicle_plate', coalesce(v ->> 'vehicle_plate', 'Not given'), 'vehicle_vin', coalesce(v ->> 'vehicle_vin', 'Not given'),
                            '_url', app.ntf_link('va_sales'));
  when 'staff_expiry_watch' then
    x := jsonb_build_object(
      'expiry_count', coalesce(p ->> 'expiry_count', '0'),
      'expiry_items', coalesce((select jsonb_agg(jsonb_build_object('vehicle', coalesce(it ->> 'label', app.vehicle_name((it ->> 'vehicle_id')::uuid)),
                                                                    'item', initcap(replace(coalesce(it ->> 'kind', 'document'), '_', ' ')),
                                                                    'expires', app.fmt_day((it ->> 'expires_on')::date)) order by it ->> 'expires_on')
                                  from jsonb_array_elements(case when jsonb_typeof(p -> 'expiry_items') = 'array' then p -> 'expiry_items' else '[]'::jsonb end) it), '[]'::jsonb),
      'expiry_urgent_count', (select count(*) from jsonb_array_elements(case when jsonb_typeof(p -> 'expiry_items') = 'array' then p -> 'expiry_items' else '[]'::jsonb end) it
                               where (it ->> 'expires_on')::date <= app.local_date(p_event.created_at) + 7)::text,
      '_url', app.ntf_link('va_fleet_expiries'));
  when 'staff_listing_ready_for_review' then
    x := jsonb_build_object('listing_due', app.fmt_date(p_event.created_at + interval '1 day'),
                            'listing_flags', concat_ws(', ', case when (p ->> 'decode_failed')::boolean then 'VIN decode failed' end,
                                                             case when (p ->> 'draft_failed')::boolean then 'draft failed' end,
                                                             case when (p ->> 'needs_rewrite')::boolean then 'needs a rewrite' end),
                            'photo_count', (select count(*) from vehicle_photos ph where ph.vehicle_id = v_vehicle and ph.replaced_at is null)::text,
                            'rates_status', case when exists (select 1 from rate_cards rc where rc.vehicle_id = v_vehicle) then 'Rates set' else 'No rates yet' end,
                            'owner_name', coalesce((select o2.legal_name from owners o2 join vehicles v2 on v2.owner_id = o2.id where v2.id = v_vehicle), ''),
                            '_url', app.ntf_link('va_fleet_listing', v));
    x := x || jsonb_build_object('listing_flags', coalesce(nullif(x ->> 'listing_flags', ''), 'None'));
  when 'staff_exit_notice_received', 'owner_exit_notice_received', 'owner_exit_completed' then
    x := jsonb_build_object(
      'exit_date', app.fmt_day((p ->> 'exit_date')::date),
      'notice_date', app.fmt_date((select e.notice_received_at from vehicle_exits e where e.id = p_event.entity_id)),
      'exit_date_basis', 'The notice period in your Enrollment Agreement',
      'retransfer_fee_note', case p ->> 'retransfer_fees_paid_by' when 'carmacars' then 'CarmaCars pays the retransfer fees.' else 'The retransfer fees are yours to pay.' end,
      'retransfer_summary', case p ->> 'retransfer_fees_paid_by' when 'carmacars' then 'CarmaCars paid the retransfer fees.' else 'The retransfer fees were yours.' end,
      'final_payout_date', app.fmt_day(make_date(extract(year from ((p ->> 'exit_date')::date + 31))::integer, extract(month from ((p ->> 'exit_date')::date + 31))::integer, s.payout_day)),
      'owner_name', coalesce(p ->> 'owner_name', v ->> 'owner_name', ''),
      'bookings_before_exit', (select count(*) from bookings b2 where b2.vehicle_id = v_vehicle and b2.status in ('confirmed', 'pending_payment')
                                  and b2.pickup_at < app.local_midnight((p ->> 'exit_date')::date))::text,
      'fleet_count_after', app.fleet_count(app.today(), true)::text,
      '_url', app.ntf_link(case when p_code like 'staff_%' then 'va_fleet_vehicle' else 'owner_vehicle_exit' end, v));
  when 'owner_fee_change_notice' then
    x := jsonb_build_object(
      'effective_date', app.fmt_day((p ->> 'effective_from')::date),
      'fee_change_reason', coalesce(p ->> 'reason', ''),
      'fee_changes', jsonb_build_array(
         jsonb_build_object('label', 'Insurance Fee', 'before', app.fmt_money((p ->> 'old_insurance_fee_cents')::bigint), 'after', app.fmt_money((p ->> 'new_insurance_fee_cents')::bigint)),
         jsonb_build_object('label', 'Tracker Fee', 'before', app.fmt_money((p ->> 'old_tracker_fee_cents')::bigint), 'after', app.fmt_money((p ->> 'new_tracker_fee_cents')::bigint))),
      'fee_change_summary', 'Insurance Fee ' || coalesce(app.fmt_money((p ->> 'new_insurance_fee_cents')::bigint), 'unchanged')
                            || ', Tracker Fee ' || coalesce(app.fmt_money((p ->> 'new_tracker_fee_cents')::bigint), 'unchanged') || ' a month',
      'is_share_change', false,
      'notice_days', coalesce((p ->> 'effective_from')::date - app.local_date(p_event.created_at), 30)::text);
  when 'owner_bank_details_changed' then
    x := jsonb_build_object('changed_at', app.fmt_datetime(coalesce((p ->> 'changed_at')::timestamptz, p_event.created_at)),
                            'details_on_file', 'Account ending ' || (v ->> 'bank_last4'));
  when 'owner_document_due' then
    x := jsonb_build_object('document_type', case when p ? 'insurance_expires_on' and (p ->> 'insurance_expires_on') = (p ->> 'expires_on') then 'Proof of insurance'
                                                  when (p ->> 'plate_expires_on') = (p ->> 'expires_on') then 'Plate sticker renewal' else 'Document' end,
                            'due_date', app.fmt_day((p ->> 'expires_on')::date),
                            'document_action', 'Upload the renewed document in your owner portal before it expires.',
                            'document_action_short', 'Upload it before ' || app.fmt_day((p ->> 'expires_on')::date) || '.',
                            'document_consequence', 'Without it the vehicle cannot be booked after that date.',
                            '_url', app.ntf_link('owner_documents'));
  when 'owner_vehicle_listed' then
    x := (select jsonb_build_object('daily_rate', app.fmt_money(rc.daily_rate_cents), 'weekend_rate', app.fmt_money(rc.weekend_rate_cents),
                                    'weekly_rate', app.fmt_money(rc.weekly_rate_cents), 'monthly_rate', app.fmt_money(rc.monthly_rate_cents),
                                    'km_per_day', rc.km_allowance_per_day || ' km', 'deposit_amount', app.fmt_money(rc.deposit_cents))
            from rate_cards rc where rc.vehicle_id = v_vehicle order by rc.effective_from desc limit 1);
    x := coalesce(x, '{}'::jsonb) || jsonb_build_object('_url', (s.notify_base_url || coalesce(p ->> 'listing_path', '/cars')));
  -- ------------------------------------------------------------ investor
  when 'investor_return_paid', 'investor_statement_ready' then
    select * into ir from investment_returns where id = p_event.entity_id;
    x := jsonb_build_object('return_amount', app.fmt_money(ir.return_cents), 'statement_month', to_char(ir.return_month, 'FMMonth YYYY'),
                            'statement_number', 'IS-' || to_char(ir.return_month, 'YYYYMM') || '-' || upper(left(ir.investment_id::text, 6)),
                            'payment_date', app.fmt_day(ir.payment_date),
                            'payout_reference', coalesce((select po2.reference from payouts po2 where po2.id = ir.payout_id), ''),
                            'invested_amount', app.fmt_money(coalesce(ir.closing_invested_cents, ir.opening_invested_cents)),
                            'return_treatment', case ir.disposition when 'reinvest' then 'Reinvested' else 'Paid to your bank account' end,
                            'bank_last4', coalesce((select a.account_last4 from investor_bank_accounts a join investments iv on iv.investor_id = a.investor_id
                                                     where iv.id = ir.investment_id and a.is_current limit 1), '----'));
  when 'investor_notice_received' then
    x := jsonb_build_object('notice_date', app.fmt_day(coalesce((p ->> 'notice_date')::date, app.local_date(p_event.created_at))),
                            'notice_effective', coalesce(p ->> 'notice_effective', ''), 'notice_subject', coalesce(p ->> 'notice_subject', 'Your notice'));
  -- ------------------------------------------------------------ staff, built by their jobs (values already in the payload)
  when 'staff_field_job_assigned', 'staff_field_job_changed' then
    select * into fj from field_jobs where id = p_event.entity_id;
    x := jsonb_build_object('job_id', fj.id::text, 'job_type', initcap(replace(fj.kind, '_', ' ')), 'job_date', app.fmt_date(fj.scheduled_at),
                            'job_time', app.fmt_time(fj.scheduled_at), 'job_place', coalesce(fj.place, 'See the job'),
                            'job_note', coalesce(nullif(fj.instructions, ''), 'None'),
                            'job_cancelled', coalesce((p ->> 'job_cancelled')::boolean, fj.status = 'cancelled'),
                            'job_change_headline', case when coalesce((p ->> 'job_cancelled')::boolean, false) then 'This job is cancelled' else 'This job has changed' end,
                            'job_change_summary', coalesce(p ->> 'change_summary', 'See the changes below.'),
                            'job_changes', coalesce(p -> 'changes', '[]'::jsonb),
                            'customer_first_name', coalesce(p ->> 'customer_first_name', v ->> 'customer_first_name', ''),
                            'vehicle_plate', coalesce(p ->> 'vehicle_plate', v ->> 'vehicle_plate', ''),
                            '_url', app.ntf_link('field_job', jsonb_build_object('job_id', fj.id)));
  else
    null;
  end case;

  v := v || x;
  v := v || jsonb_build_object('first_name', coalesce(nullif(v_first, ''), nullif(p ->> 'first_name', ''), 'there'));
  -- keep only what the template uses, plus the digest steering keys
  return (select coalesce(jsonb_object_agg(k, v -> k), '{}'::jsonb)
            from jsonb_object_keys(v) k
           where k like '\_%' or exists (select 1 from jsonb_array_elements(c.variables) cv where cv ->> 'name' = k));
end $$;

-- ================================================================ 3. wiring: triggers that emit
-- Helper: emit with the code:entity_id:discriminator key.
create or replace function app.ntf_emit(p_code text, p_entity text, p_id uuid, p_disc text, p_payload jsonb default '{}'::jsonb) returns bigint
language sql security definer set search_path = public, app as $$
  select app.emit_event(p_code, p_entity, p_id, coalesce(p_payload, '{}'::jsonb), p_code || ':' || coalesce(p_id::text, '-') || ':' || p_disc)
$$;

-- Booking history rows (0016): request, offer sent, expired, withdrawn, pushed back, declined.
create or replace function app.ntf_booking_events_after() returns trigger
language plpgsql security definer set search_path = public, app as $$
begin
  if new.kind = 'requested' then
    perform app.ntf_emit('renter_request_received', 'booking', new.booking_id, 'requested', jsonb_build_object('booking_id', new.booking_id));
    perform app.ntf_emit('staff_booking_request_new', 'booking', new.booking_id, 'requested', jsonb_build_object('booking_id', new.booking_id));
  elsif new.kind = 'offer_sent' then
    perform app.ntf_emit('renter_offer_ready', 'booking', new.booking_id, 'v' || coalesce(new.offer_version, 0),
                         jsonb_build_object('booking_id', new.booking_id, 'offer_version', new.offer_version));
  elsif new.kind = 'offer_expired' then
    perform app.ntf_emit('renter_offer_expired', 'booking', new.booking_id, 'v' || coalesce(new.offer_version, 0),
                         jsonb_build_object('booking_id', new.booking_id, 'offer_version', new.offer_version));
  elsif new.kind in ('offer_withdrawn', 'pushed_back') then
    perform app.ntf_emit('renter_offer_withdrawn', 'booking', new.booking_id, new.kind || ':v' || coalesce(new.offer_version, 0),
                         jsonb_build_object('booking_id', new.booking_id, 'kind', new.kind, 'note', new.note));
  elsif new.kind = 'declined' and new.from_status = 'requested' and new.actor_type <> 'renter' then
    perform app.ntf_emit('renter_request_declined', 'booking', new.booking_id, 'declined',
                         jsonb_build_object('booking_id', new.booking_id, 'note', new.note));
  end if;
  return null;
end $$;
create trigger booking_events_notify after insert on booking_events for each row execute function app.ntf_booking_events_after();

-- Booking status: confirmed, on rent, returned.
create or replace function app.ntf_bookings_status_after() returns trigger
language plpgsql security definer set search_path = public, app as $$
declare
  s program_settings := app.settings();
  pl jsonb := jsonb_build_object('booking_id', new.id);
begin
  if new.status is not distinct from old.status then return null; end if;
  if new.status = 'confirmed' then
    if new.booking_type = 'owner' then
      perform app.ntf_emit('owner_booking_confirmed', 'booking', new.id, 'confirmed', pl);
    else
      perform app.ntf_emit('renter_booking_confirmed', 'booking', new.id, 'confirmed', pl);
      perform app.ntf_emit('owner_new_booking', 'booking', new.id, 'confirmed', pl);
      perform app.ntf_emit('staff_offer_approved_paid', 'booking', new.id, 'confirmed',
        pl || jsonb_build_object('_immediate', new.pickup_at <= now() + make_interval(hours => s.notify_offer_paid_immediate_hours)));
    end if;
  elsif new.status = 'on_rent' and new.booking_type <> 'owner' then
    perform app.ntf_emit('renter_rental_started', 'booking', new.id, 'on_rent', pl);
  elsif new.status = 'returned' and new.booking_type <> 'owner' then
    perform app.ntf_emit('renter_return_complete', 'booking', new.id, 'returned', pl);
  end if;
  return null;
end $$;
create trigger bookings_notify_status after update of status on bookings for each row execute function app.ntf_bookings_status_after();

-- Cancellation and no-show (the cancellation row holds the tier and the refund).
create or replace function app.ntf_booking_cancellations_after() returns trigger
language plpgsql security definer set search_path = public, app as $$
declare
  s program_settings := app.settings();
  pl jsonb := jsonb_build_object('booking_id', new.booking_id);
  v_by_us boolean := new.cancelled_by = 'carmacars' or new.reason in ('carmacars_no_vehicle', 'driver_not_verifiable', 'pricing_error');
  v_admin boolean;
begin
  perform app.ntf_emit(case when v_by_us then 'renter_booking_cancelled_by_us' else 'renter_booking_cancelled' end,
                       'booking', new.booking_id, 'cancelled', pl);
  v_admin := new.refund_cents > s.notify_cancellation_admin_cents
             or exists (select 1 from refunds r where r.id = new.refund_id and r.status = 'pending_approval');
  perform app.ntf_emit('staff_cancellation_received', 'booking', new.booking_id, 'cancelled',
    pl || case when v_admin then jsonb_build_object('_roles', jsonb_build_array('staff_admin'), '_immediate', true) else '{}'::jsonb end);
  return null;
end $$;
create trigger booking_cancellations_notify after insert on booking_cancellations for each row execute function app.ntf_booking_cancellations_after();

-- Renter payments: receipt (not the payment that confirms a booking: that email carries it) and
-- declines (a deposit decline is 0020's renter_deposit_declined).
create or replace function app.ntf_payments_after() returns trigger
language plpgsql security definer set search_path = public, app as $$
declare
  pl jsonb := jsonb_build_object('booking_id', new.booking_id, 'renter_id', new.renter_id);
begin
  if tg_op = 'UPDATE' and new.status is not distinct from old.status and new.decline_count = old.decline_count then return null; end if;
  if new.renter_id is null or new.owner_invoice_id is not null or new.booking_id is null then return null; end if;
  if new.status = 'succeeded' and new.kind in ('charge', 'capture') and new.purpose not in ('booking_total', 'deposit') then
    perform app.ntf_emit('renter_payment_receipt', 'payment', new.id, 'succeeded', pl);
  elsif new.status = 'failed' and new.purpose <> 'deposit' and new.kind in ('charge', 'capture') then
    perform app.ntf_emit('renter_payment_failed', 'payment', new.id, 'failed' || new.decline_count, pl);
    if new.purpose <> 'booking_total' then
      perform app.ntf_emit('staff_payment_failed', 'payment', new.id, 'failed' || new.decline_count, pl);
    end if;
  end if;
  return null;
end $$;
create trigger payments_notify after insert or update of status, decline_count on payments for each row execute function app.ntf_payments_after();

-- Refunds paid, unless a cancellation email reported it within the hour.
create or replace function app.ntf_refunds_after() returns trigger
language plpgsql security definer set search_path = public, app as $$
begin
  if new.status = 'paid' and (tg_op = 'INSERT' or old.status is distinct from 'paid')
     and not exists (select 1 from booking_cancellations c where c.refund_id = new.id and c.created_at > now() - interval '1 hour') then
    perform app.ntf_emit('renter_refund_issued', 'refund', new.id, 'paid', jsonb_build_object('booking_id', new.booking_id));
  end if;
  return null;
end $$;
create trigger refunds_notify after insert or update of status on refunds for each row execute function app.ntf_refunds_after();

-- The final statement, when Finance sends it.
create or replace function app.ntf_booking_statements_after() returns trigger
language plpgsql security definer set search_path = public, app as $$
begin
  if new.kind = 'check_in' and new.sent_at is not null and (tg_op = 'INSERT' or old.sent_at is null) then
    perform app.ntf_emit('renter_final_statement', 'booking_statement', new.id, 'sent', jsonb_build_object('booking_id', new.booking_id));
  end if;
  return null;
end $$;
create trigger booking_statements_notify after insert or update of sent_at on booking_statements for each row execute function app.ntf_booking_statements_after();

-- A new renter or owner account (the verify link comes from the sign-in service).
create or replace function app.ntf_user_roles_after() returns trigger
language plpgsql security definer set search_path = public, app as $$
begin
  if new.role = 'renter' then
    perform app.ntf_emit('renter_account_created', 'user', new.user_id, 'created',
                         jsonb_build_object('renter_id', (select r.id from renters r where r.user_id = new.user_id)));
  elsif new.role = 'owner' then
    perform app.ntf_emit('owner_account_created', 'user', new.user_id, 'created',
                         jsonb_build_object('owner_id', (select o.id from owners o where o.user_id = new.user_id order by o.created_at limit 1),
                                            'email', (select u.email from users u where u.id = new.user_id),
                                            'first_name', (select split_part(u.full_name, ' ', 1) from users u where u.id = new.user_id)));
  end if;
  return null;
end $$;
create trigger user_roles_notify after insert on user_roles for each row execute function app.ntf_user_roles_after();

-- The renter row may be written after the role: the account email waits for an address.
-- (Recipients are read when the event is processed, so either order works.)

-- Owner onboarding statuses.
create or replace function app.ntf_onboardings_after() returns trigger
language plpgsql security definer set search_path = public, app as $$
declare
  pl jsonb := jsonb_build_object('vehicle_id', new.vehicle_id, 'owner_id', (select v.owner_id from vehicles v where v.id = new.vehicle_id));
  v_share boolean := (select v.is_shareholder_owned from vehicles v where v.id = new.vehicle_id);
begin
  if tg_op = 'UPDATE' and new.status is not distinct from old.status then
    if new.status = 'registry_booked' and (new.registry_visit_at, new.registry_place) is distinct from (old.registry_visit_at, old.registry_place) then
      perform app.ntf_emit('owner_registry_visit', 'vehicle_onboarding', new.id, md5(coalesce(new.registry_visit_at::text, '') || coalesce(new.registry_place, '')), pl);
    end if;
    return null;
  end if;
  case new.status
    when 'documents_sent' then perform app.ntf_emit('owner_agreement_ready', 'vehicle_onboarding', new.id, 'documents_sent', pl);
    when 'documents_signed' then
      perform app.ntf_emit('owner_agreement_signed', 'vehicle_onboarding', new.id, 'documents_signed', pl);
      if v_share then perform app.ntf_emit('owner_onboarding_steps', 'vehicle_onboarding', new.id, 'steps', pl); end if;
    when 'upfront_paid' then perform app.ntf_emit('owner_onboarding_steps', 'vehicle_onboarding', new.id, 'steps', pl);
    when 'registry_booked' then
      perform app.ntf_emit('owner_registry_visit', 'vehicle_onboarding', new.id, md5(coalesce(new.registry_visit_at::text, '') || coalesce(new.registry_place, '')), pl);
    when 'enrolled' then perform app.ntf_emit('owner_vehicle_enrolled', 'vehicle_onboarding', new.id, 'enrolled', pl);
    when 'declined' then perform app.ntf_emit('owner_application_declined', 'vehicle_onboarding', new.id, 'declined', pl);
    else null;
  end case;
  return null;
end $$;
create trigger vehicle_onboardings_notify after insert or update of status, registry_visit_at, registry_place on vehicle_onboardings
  for each row execute function app.ntf_onboardings_after();

-- Owner invoices: issued (upfront or monthly), paid, failed, in arrears.
create or replace function app.ntf_owner_invoices_after() returns trigger
language plpgsql security definer set search_path = public, app as $$
declare
  pl jsonb := jsonb_build_object('owner_id', new.owner_id, 'vehicle_id', new.vehicle_id);
begin
  if tg_op = 'UPDATE' and new.status is not distinct from old.status then return null; end if;
  if new.status = 'issued' and new.kind = 'upfront' then
    perform app.ntf_emit('owner_upfront_invoice', 'owner_invoice', new.id, 'issued', pl);
  elsif new.status = 'issued' and new.kind = 'monthly' then
    perform app.ntf_emit('owner_fee_invoice', 'owner_invoice', new.id, 'issued', pl);
  elsif new.status = 'paid' then
    perform app.ntf_emit('owner_payment_received', 'owner_invoice', new.id, 'paid', pl);
  elsif new.status = 'failed' then
    perform app.ntf_emit('owner_payment_failed', 'owner_invoice', new.id, 'failed', pl);
    perform app.ntf_emit('staff_owner_invoice_failed', 'owner_invoice', new.id, 'failed', pl);
  elsif new.status = 'in_arrears' then
    perform app.ntf_emit('owner_in_arrears', 'owner_invoice', new.id, 'in_arrears', pl);
    perform app.ntf_emit('staff_owner_invoice_failed', 'owner_invoice', new.id, 'in_arrears',
                         pl || jsonb_build_object('_immediate_roles', jsonb_build_array('staff_admin')));
  end if;
  return null;
end $$;
create trigger owner_invoices_notify after insert or update of status on owner_invoices for each row execute function app.ntf_owner_invoices_after();

-- Owner payouts paid (not when the statement shows a balance owing: no payout row is paid then).
create or replace function app.ntf_payouts_after() returns trigger
language plpgsql security definer set search_path = public, app as $$
begin
  if new.status = 'paid' and old.status is distinct from 'paid' and new.payee_type = 'owner' and new.amount_cents > 0 then
    perform app.ntf_emit('owner_payout_sent', 'payout', new.id, 'paid', jsonb_build_object('owner_id', new.owner_id));
  end if;
  return null;
end $$;
create trigger payouts_notify after update of status on payouts for each row execute function app.ntf_payouts_after();

-- Investor returns: paid (not a reinvested return) and the monthly statement.
create or replace function app.ntf_investment_returns_after() returns trigger
language plpgsql security definer set search_path = public, app as $$
declare
  pl jsonb := jsonb_build_object('investor_id', (select i.investor_id from investments i where i.id = new.investment_id));
begin
  if new.status = 'paid' and old.status is distinct from 'paid' and new.disposition = 'pay' then
    perform app.ntf_emit('investor_return_paid', 'investment_return', new.id, 'paid', pl);
  end if;
  if new.statement_sent_at is not null and old.statement_sent_at is null then
    perform app.ntf_emit('investor_statement_ready', 'investment_return', new.id, 'statement', pl);
  end if;
  return null;
end $$;
create trigger investment_returns_notify after update of status, statement_sent_at on investment_returns
  for each row execute function app.ntf_investment_returns_after();

-- A written notice from an investor: a change of the pay or reinvest election, or a request to
-- buy back an investment.
create or replace function app.ntf_investor_notice_after() returns trigger
language plpgsql security definer set search_path = public, app as $$
begin
  if tg_table_name = 'investment_elections' then
    if new.is_initial then return null; end if;
    perform app.ntf_emit('investor_notice_received', 'investment_election', new.id, 'received', jsonb_build_object(
      'investor_id', (select a.investor_id from investment_agreements a where a.id = new.agreement_id),
      'notice_date', new.received_on, 'notice_effective', app.fmt_day(new.effective_month),
      'notice_subject', 'Change of election: ' || case new.mode when 'pay' then 'returns paid monthly' else 'returns reinvested' end));
  elsif tg_table_name = 'investment_redemptions' then
    if new.kind <> 'purchase_on_request' then return null; end if;
    perform app.ntf_emit('investor_notice_received', 'investment_redemption', new.id, 'received', jsonb_build_object(
      'investor_id', (select i.investor_id from investments i where i.id = new.investment_id),
      'notice_date', new.notice_date, 'notice_effective', app.fmt_day(new.redemption_date),
      'notice_subject', 'Request to buy back your investment'));
  end if;
  return null;
end $$;
create trigger investment_elections_notify after insert on investment_elections for each row execute function app.ntf_investor_notice_after();
create trigger investment_redemptions_notify after insert on investment_redemptions for each row execute function app.ntf_investor_notice_after();

-- Incidents opened.
create or replace function app.ntf_incidents_after() returns trigger
language plpgsql security definer set search_path = public, app as $$
declare
  pl jsonb := jsonb_build_object('booking_id', new.booking_id, 'vehicle_id', new.vehicle_id);
  v_third boolean := exists (select 1 from vehicles v join owners o on o.id = v.owner_id where v.id = new.vehicle_id and not o.is_shareholder);
begin
  if new.kind in ('accident', 'theft', 'vandalism', 'damage_at_return', 'damage_found_later') then
    perform app.ntf_emit('staff_incident_reported', 'incident', new.id, 'opened', pl);
  elsif new.kind = 'breakdown' then
    perform app.ntf_emit('staff_breakdown_reported', 'incident', new.id, 'opened', pl);
  end if;
  if new.kind in ('accident', 'theft', 'vandalism') and new.booking_id is not null
     and exists (select 1 from bookings b where b.id = new.booking_id and b.status = 'on_rent') then
    perform app.ntf_emit('renter_accident_instructions', 'incident', new.id, 'opened', pl);
  end if;
  if new.kind in ('accident', 'theft', 'vandalism', 'damage_at_return') and v_third then
    perform app.ntf_emit('owner_incident_opened', 'incident', new.id, 'opened', pl);
  end if;
  return null;
end $$;
create trigger incidents_notify after insert on incidents for each row execute function app.ntf_incidents_after();

-- Claims: opened (one owner notice per incident) and status changes the owner hears about.
create or replace function app.ntf_claims_after() returns trigger
language plpgsql security definer set search_path = public, app as $$
declare
  pl jsonb := jsonb_build_object('vehicle_id', new.vehicle_id, 'owner_id', new.owner_id, 'booking_id', new.booking_id);
begin
  if new.is_shareholder_vehicle or exists (select 1 from owners o where o.id = new.owner_id and o.is_shareholder) then return null; end if;
  if tg_op = 'INSERT' then
    perform app.ntf_emit('owner_incident_opened', 'incident', new.incident_id, 'opened', pl);
  elsif new.status is distinct from old.status and new.status in ('submitted', 'accepted', 'in_repair', 'repaired', 'settling', 'closed') then
    perform app.ntf_emit('owner_incident_update', 'incident', new.incident_id, 'claim:' || new.id || ':' || new.status, pl);
  end if;
  return null;
end $$;
create trigger claims_notify after insert or update of status on claims for each row execute function app.ntf_claims_after();

-- Roadside dispatched for a breakdown: Fleet logs it with the arrival estimate, and the renter is told.
create or replace function app.dispatch_roadside(p_incident uuid, p_eta_minutes integer, p_by uuid, p_note text default null) returns uuid
language plpgsql security definer set search_path = public, app as $$
declare
  i incidents;
  v_id uuid;
begin
  if not (app.user_is_staff(p_by)) then raise exception 'Not permitted' using errcode = '42501'; end if;
  select * into i from incidents where id = p_incident;
  if i.id is null or i.kind <> 'breakdown' then raise exception 'Incident % is not a breakdown', p_incident using errcode = '23514'; end if;
  if p_eta_minutes is null or p_eta_minutes <= 0 then raise exception 'Give the arrival estimate in minutes' using errcode = '22023'; end if;
  insert into incident_events (incident_id, occurred_at, kind, detail, actor_user_id)
  values (p_incident, now(), 'roadside', coalesce(p_note, format('Roadside dispatched, about %s minutes', p_eta_minutes)), p_by)
  returning id into v_id;
  if i.booking_id is not null then
    perform app.ntf_emit('renter_breakdown_help', 'incident', p_incident, 'dispatch:' || v_id,
                         jsonb_build_object('booking_id', i.booking_id, 'eta_minutes', p_eta_minutes::text));
  end if;
  return v_id;
end $$;

-- Reviews, disputes, a confirmed engine disable.
create or replace function app.ntf_reviews_after() returns trigger
language plpgsql security definer set search_path = public, app as $$
declare
  s program_settings := app.settings();
begin
  perform app.ntf_emit('staff_review_received', 'review', new.id, 'received',
    jsonb_build_object('booking_id', new.booking_id)
    || case when new.rating <= s.notify_review_alert_max_rating
            then jsonb_build_object('_roles', jsonb_build_array('staff_va_cs', 'staff_admin'), '_immediate', true) else '{}'::jsonb end);
  return null;
end $$;
create trigger reviews_notify after insert on reviews for each row execute function app.ntf_reviews_after();

create or replace function app.ntf_disputes_after() returns trigger
language plpgsql security definer set search_path = public, app as $$
begin
  perform app.ntf_emit('staff_dispute_opened', 'dispute', new.id, 'opened', jsonb_build_object('booking_id', new.booking_id));
  return null;
end $$;
create trigger disputes_notify after insert on disputes for each row execute function app.ntf_disputes_after();

create or replace function app.ntf_tracker_commands_after() returns trigger
language plpgsql security definer set search_path = public, app as $$
begin
  if new.command = 'engine_disable' and new.status = 'confirmed' and old.status is distinct from 'confirmed' and new.booking_id is not null then
    perform app.ntf_emit('renter_vehicle_disabled', 'tracker_command', new.id, 'confirmed', jsonb_build_object('booking_id', new.booking_id));
  end if;
  return null;
end $$;
create trigger tracker_commands_notify after update of status on tracker_commands for each row execute function app.ntf_tracker_commands_after();

-- Fleet count: the Monday recount at the warning level, or an exit notice that takes it there.
create or replace function app.ntf_fleet_payload(p_count integer, p_next_exit date) returns jsonb
language sql stable security definer set search_path = public, app as $$
  select jsonb_build_object(
    'fleet_count', app.fleet_count(app.today(), false)::text,
    'fleet_count_after', p_count::text,
    'fleet_exiting', (select count(*) from vehicle_exits e where e.status = 'notice')::text,
    'fleet_onboarding', (select count(*) || ' vehicle' || case when count(*) <> 1 then 's' else '' end from vehicle_onboardings o
                          where o.status not in ('enrolled', 'declined', 'withdrawn'))::text,
    'next_exit_date', coalesce(app.fmt_day(coalesce(p_next_exit, (select min(e.exit_date) from vehicle_exits e where e.status = 'notice'))), 'None'),
    '_url', app.ntf_link('admin_fleet'))
$$;

create or replace function app.ntf_fleet_counts_after() returns trigger
language plpgsql security definer set search_path = public, app as $$
begin
  if new.warned_admin and (tg_op = 'INSERT' or not old.warned_admin) then
    perform app.ntf_emit('staff_fleet_count_warning', 'fleet_count', new.id, new.counted_on::text, app.ntf_fleet_payload(new.less_exit_notice, null));
  end if;
  return null;
end $$;
create trigger fleet_counts_notify after insert or update of warned_admin on fleet_counts for each row execute function app.ntf_fleet_counts_after();

create or replace function app.ntf_vehicle_exits_after() returns trigger
language plpgsql security definer set search_path = public, app as $$
declare
  v_after integer := app.fleet_count(app.today(), true);
begin
  if new.status = 'notice' and v_after <= (app.settings()).fleet_warning_count
     and exists (select 1 from vehicles v where v.id = new.vehicle_id and v.management_mode <> 'turo_only') then
    perform app.ntf_emit('staff_fleet_count_warning', 'vehicle_exit', new.id, 'notice', app.ntf_fleet_payload(v_after, new.exit_date));
  end if;
  return null;
end $$;
create trigger vehicle_exits_notify after insert on vehicle_exits for each row execute function app.ntf_vehicle_exits_after();

-- A scheduled job failed: once per run and Toronto day.
create or replace function app.ntf_job_runs_after() returns trigger
language plpgsql security definer set search_path = public, app as $$
begin
  if new.status = 'failed' and old.status is distinct from 'failed' then
    perform app.ntf_emit('staff_job_failed', 'job_run', new.id, app.today()::text, jsonb_build_object(
      'job_name', new.job_name, 'job_error', left(coalesce(new.error, 'No error text'), 500),
      'job_run_date', app.fmt_datetime(coalesce(new.finished_at, now())),
      'job_effect', format('The %s run for %s did not complete. It runs again on its next schedule, or an admin can run it now.', new.job_name, new.run_key),
      '_url', app.ntf_link('admin_jobs')));
  end if;
  return null;
end $$;
create trigger job_runs_notify after update of status on job_runs for each row execute function app.ntf_job_runs_after();

-- The owner statements of the month are drafted (0015's statements-draft raises the approval task).
create or replace function app.ntf_statements_payload(p_month date) returns jsonb
language sql stable security definer set search_path = public, app as $$
  select jsonb_build_object(
    'statement_month', to_char(p_month, 'FMMonth'),
    'statement_count', count(*)::text,
    'payout_total', app.fmt_money(coalesce(sum(greatest(s.payout_cents, 0)), 0)),
    'owner_revenue_total', app.fmt_money(coalesce(sum(s.owner_revenue_cents), 0)),
    'revenue_share_total', app.fmt_money(coalesce(sum(s.revenue_share_cents), 0)),
    'deductions_total', app.fmt_money(coalesce(sum(s.deductions_cents), 0)),
    'kickbacks_earned', app.fmt_money(coalesce(sum(s.kickbacks_earned_cents), 0)),
    'staff_kickbacks', app.fmt_money(coalesce((select sum(p.amount_cents) from payouts p where p.kind = 'kickback_payroll'
                                                 and p.scheduled_for >= p_month + interval '1 month' and p.scheduled_for < p_month + interval '2 months'), 0)),
    'negative_balances', count(*) filter (where s.payout_cents <= 0 and s.balance_carried_forward_cents < 0)::text,
    'statement_flags', coalesce(nullif(concat_ws(', ',
        case when (select count(*) from disputes d where d.status in ('open', 'evidence_submitted')) > 0
             then (select count(*) from disputes d where d.status in ('open', 'evidence_submitted')) || ' dispute(s) open' end,
        case when (select count(*) from owner_invoices i where i.status in ('failed', 'in_arrears')) > 0
             then (select count(*) from owner_invoices i where i.status in ('failed', 'in_arrears')) || ' invoice(s) unpaid' end), ''), 'None'),
    '_url', app.ntf_link('admin_statements'))
    from owner_statements s where s.statement_month = p_month and s.status <> 'void'
$$;

create or replace function app.ntf_tasks_after() returns trigger
language plpgsql security definer set search_path = public, app as $$
declare
  v_month date;
begin
  if new.task_type = 'approve_owner_statements' and new.related_table = 'job_runs' then
    v_month := (select to_date(j.run_key, 'YYYY-MM') from job_runs j where j.id = new.related_id);
    perform app.ntf_emit('staff_statements_ready_for_approval', 'job_run', new.related_id, 'drafted',
                         app.ntf_statements_payload(v_month) || jsonb_build_object('task_id', new.id, 'month', v_month));
  end if;
  return null;
end $$;
create trigger tasks_notify after insert on tasks for each row execute function app.ntf_tasks_after();

-- Pickup and return details from the field job: sent at once when the job is assigned or changed
-- inside the window before the pickup or return; the reminders job sends them when the window opens.
-- The discriminator is the place, time and staff member, so a change sends again and nothing else does.
create or replace function app.ntf_field_job_details(j field_jobs, p_now timestamptz default now()) returns void
language plpgsql security definer set search_path = public, app as $$
declare
  s program_settings := app.settings(app.local_date(p_now));
  b bookings;
  v_disc text := md5(coalesce(j.place, '') || '|' || j.scheduled_at::text || '|' || coalesce(j.assigned_to::text, ''));
begin
  if j.booking_id is null or j.assigned_to is null or j.status in ('cancelled', 'done') then return; end if;
  select * into b from bookings where id = j.booking_id;
  if j.kind in ('handover', 'delivery') and b.status = 'confirmed' and b.booking_type <> 'owner'
     and b.pickup_at > p_now and b.pickup_at <= p_now + make_interval(hours => s.notify_pickup_details_hours) then
    perform app.ntf_emit('renter_pickup_details', 'booking', b.id, v_disc, jsonb_build_object('booking_id', b.id));
  elsif j.kind in ('return_check_in', 'pickup_from_renter') and b.status = 'on_rent' and b.booking_type <> 'owner'
     and b.return_at > p_now and b.return_at <= p_now + make_interval(hours => s.notify_return_reminder_hours)
     and exists (select 1 from app_events e where e.code = 'renter_return_reminder' and e.entity_id = b.id) then
    perform app.ntf_emit('renter_return_details', 'booking', b.id, v_disc, jsonb_build_object('booking_id', b.id));
  end if;
end $$;

create or replace function app.ntf_field_jobs_after() returns trigger
language plpgsql security definer set search_path = public, app as $$
begin
  if tg_op = 'UPDATE' and (new.place, new.scheduled_at, new.assigned_to) is not distinct from (old.place, old.scheduled_at, old.assigned_to) then
    return null;
  end if;
  perform app.ntf_field_job_details(new);
  return null;
end $$;
create trigger field_jobs_notify after insert or update of place, scheduled_at, assigned_to on field_jobs
  for each row execute function app.ntf_field_jobs_after();

-- ================================================================ 4. time-based jobs
-- 4a. Every 5 minutes: reminders, late returns, offers, identity, unsigned agreements, waiting
-- requests, unpaid charges during a rental. Each emit has a dedupe key, so a run repeated or
-- overlapping sends nothing twice. Returns the number of new events.
create or replace function app.notify_reminders(p_now timestamptz default now()) returns integer
language plpgsql security definer set search_path = public, app as $$
declare
  s program_settings := app.settings(app.local_date(p_now));
  r record;
  v_n integer := 0;
  v_id bigint;
  v_m integer;
  v_lead interval;
begin
  -- booking reminder, once per pickup time
  for r in select b.id, b.pickup_at from bookings b
            where b.status = 'confirmed' and b.booking_type <> 'owner' and b.pickup_at > p_now
              and b.pickup_at <= p_now + make_interval(hours => s.notify_booking_reminder_hours) loop
    v_id := app.ntf_emit('renter_booking_reminder', 'booking', r.id, 'pickup:' || extract(epoch from r.pickup_at)::bigint, jsonb_build_object('booking_id', r.id));
    v_n := v_n + (v_id is not null)::integer;
  end loop;
  -- pickup details when the window opens (the field job trigger covers later changes)
  for r in select j.id from field_jobs j join bookings b on b.id = j.booking_id
            where j.kind in ('handover', 'delivery') and j.status not in ('cancelled', 'done') and j.assigned_to is not null
              and b.status = 'confirmed' and b.pickup_at > p_now and b.pickup_at <= p_now + make_interval(hours => s.notify_pickup_details_hours) loop
    perform app.ntf_field_job_details((select fj from field_jobs fj where fj.id = r.id), p_now);
  end loop;
  -- return reminder, once per return time (so again after an extension moves it)
  for r in select b.id, b.return_at from bookings b
            where b.status = 'on_rent' and b.booking_type <> 'owner' and b.return_at > p_now
              and b.return_at <= p_now + make_interval(hours => s.notify_return_reminder_hours) loop
    v_id := app.ntf_emit('renter_return_reminder', 'booking', r.id, 'return:' || extract(epoch from r.return_at)::bigint, jsonb_build_object('booking_id', r.id));
    v_n := v_n + (v_id is not null)::integer;
  end loop;
  -- late returns: renter at 0 minutes and at the final stage; Fleet at each staff stage; admins too at the final stage
  for r in select b.id, b.return_at, b.booking_type from bookings b where b.status = 'on_rent' and b.return_at <= p_now loop
    if r.booking_type <> 'owner' then
      v_id := app.ntf_emit('renter_late_return_first', 'booking', r.id, 'r' || extract(epoch from r.return_at)::bigint, jsonb_build_object('booking_id', r.id));
      v_n := v_n + (v_id is not null)::integer;
    end if;
    foreach v_m in array s.notify_late_staff_minutes loop
      if p_now >= r.return_at + make_interval(mins => v_m) and v_m < s.late_admin_minutes then
        v_id := app.ntf_emit('staff_late_return_alert', 'booking', r.id, v_m || 'm:' || extract(epoch from r.return_at)::bigint,
          jsonb_build_object('booking_id', r.id, '_roles', jsonb_build_array('staff_va_fleet'),
                             'late_stage', case when v_m = 0 then 'Return time passed' else v_m || ' minutes late' end,
                             'late_action', 'Call the renter, check the tracker and offer a paid extension.',
                             'late_action_short', 'Call the renter and check the tracker.'));
        v_n := v_n + (v_id is not null)::integer;
      end if;
    end loop;
    if p_now >= r.return_at + make_interval(mins => s.late_admin_minutes) then
      if r.booking_type <> 'owner' then
        v_id := app.ntf_emit('renter_late_return_final', 'booking', r.id, 'r' || extract(epoch from r.return_at)::bigint, jsonb_build_object('booking_id', r.id));
        v_n := v_n + (v_id is not null)::integer;
      end if;
      v_id := app.ntf_emit('staff_late_return_alert', 'booking', r.id, 'final:' || extract(epoch from r.return_at)::bigint,
        jsonb_build_object('booking_id', r.id, '_roles', jsonb_build_array('staff_va_fleet', 'staff_admin'),
                           'late_stage', (s.late_admin_minutes / 60.0)::numeric(6, 1)::text || ' hours, final notice due',
                           'late_action', 'Call twice. Send the final notice. Tell an admin now.',
                           'late_action_short', 'Call twice and send the final notice.'));
      v_n := v_n + (v_id is not null)::integer;
    end if;
  end loop;
  -- offer reminder: the set hours before expiry, or halfway for a short window
  for r in select b.id, b.current_offer_version, o.sent_at, o.expires_at from bookings b
             join booking_offers o on o.booking_id = b.id and o.version = b.current_offer_version and o.status = 'sent'
            where b.status = 'offered' and o.expires_at > p_now loop
    v_lead := case when r.expires_at - r.sent_at < make_interval(hours => s.notify_offer_halfway_below_hours) then (r.expires_at - r.sent_at) / 2
                   else make_interval(hours => s.notify_offer_reminder_hours) end;
    if p_now >= r.expires_at - v_lead then
      v_id := app.ntf_emit('renter_offer_reminder', 'booking', r.id, 'v' || r.current_offer_version,
        jsonb_build_object('booking_id', r.id, 'time_left', case when r.expires_at - p_now >= interval '2 hours'
                                                                  then floor(extract(epoch from (r.expires_at - p_now)) / 3600)::integer || ' hours'
                                                                  else greatest(ceil(extract(epoch from (r.expires_at - p_now)) / 60), 1)::integer || ' minutes' end));
      v_n := v_n + (v_id is not null)::integer;
    end if;
  end loop;
  -- identity and coverage chase before pickup
  for r in select b.id from bookings b
            where b.status = 'confirmed' and b.booking_type <> 'owner' and b.pickup_at > p_now
              and b.pickup_at <= p_now + make_interval(hours => s.notify_identity_chase_hours)
              and app.ntf_missing_items(b.id) <> '' loop
    v_id := app.ntf_emit('renter_identity_needed', 'booking', r.id, 'chase', jsonb_build_object('booking_id', r.id));
    v_n := v_n + (v_id is not null)::integer;
  end loop;
  -- the renter left the agreement unsigned while paying (same key as 0019's, so never twice)
  for r in select a.id as agreement_id, a.booking_id, g.id as signer_id, g.signer_name, g.signer_email, g.user_id
             from rental_agreements a join bookings b on b.id = a.booking_id
             join rental_agreement_signers g on g.agreement_id = a.id and g.signer_role = 'renter' and g.signed_at is null
            where a.status = 'open' and b.status = 'pending_payment'
              and a.opened_at <= p_now - make_interval(mins => s.notify_agreement_unsigned_minutes) loop
    v_id := app.emit_event('renter_agreement_ready', 'rental_agreement', r.agreement_id,
      jsonb_build_object('booking_id', r.booking_id, 'signer_id', r.signer_id, 'signer_role', 'renter', 'signer_name', r.signer_name,
                         'signer_email', r.signer_email, 'signer_user_id', r.user_id, 'reminder', true),
      'renter_agreement_ready:' || r.agreement_id || ':' || r.signer_id);
    v_n := v_n + (v_id is not null)::integer;
  end loop;
  -- a request unanswered past the waiting time (not one sent back from an offer)
  for r in select b.id, b.requested_at from bookings b
            where b.status = 'requested' and b.current_offer_version is null
              and b.requested_at <= p_now - make_interval(mins => s.notify_request_waiting_minutes)
              and not exists (select 1 from booking_info_requests q where q.booking_id = b.id) loop
    v_id := app.ntf_emit('staff_request_waiting', 'booking', r.id, 'waiting', jsonb_build_object('booking_id', r.id,
      'request_received_at', app.fmt_at(r.requested_at),
      'waiting_time', floor(extract(epoch from (p_now - r.requested_at)) / 3600)::integer || ' hours '
                      || (floor(extract(epoch from (p_now - r.requested_at)) / 60)::integer % 60) || ' minutes',
      'assigned_to', coalesce((select u.full_name from tasks t join users u on u.id = t.assigned_to
                                where t.booking_id = r.id and t.status in ('open', 'in_progress') order by t.created_at limit 1), 'Nobody yet')));
    v_n := v_n + (v_id is not null)::integer;
  end loop;
  -- a Card on File charge still unpaid 24 hours into a rental: now to Finance and the admins
  for r in select p.id, p.booking_id from payments p join bookings b on b.id = p.booking_id
            where p.status = 'failed' and p.purpose not in ('booking_total', 'deposit') and b.status = 'on_rent'
              and p.created_at <= p_now - make_interval(hours => s.notify_payment_failed_alert_hours)
              and not exists (select 1 from payments q where q.parent_payment_id = p.id and q.status = 'succeeded') loop
    v_id := app.ntf_emit('staff_payment_failed', 'payment', r.id, 'unpaid24',
      jsonb_build_object('booking_id', r.booking_id, '_roles', jsonb_build_array('staff_va_finance', 'staff_admin'), '_immediate', true));
    v_n := v_n + (v_id is not null)::integer;
  end loop;
  return v_n;
end $$;

create or replace function app.job_notify_reminders(p_now timestamptz default now()) returns text
language plpgsql security definer set search_path = public, app as $$
declare
  v_n integer;
  v_run uuid;
begin
  v_n := app.notify_reminders(p_now);
  if v_n = 0 then return 'not_due'; end if;
  v_run := app.job_claim('notify-reminders', to_char(p_now at time zone 'UTC', 'YYYY-MM-DD"T"HH24:MI"Z"'));
  if v_run is not null then perform app.job_succeed(v_run, jsonb_build_object('events', v_n)); end if;
  return 'succeeded';
end $$;

-- 4b. Follow-ups after a booking closes (review request, come-back offers).
create or replace function app.ntf_closed_at(p_booking uuid) returns timestamptz
language sql stable security definer set search_path = public, app as $$
  select max(changed_at) from status_history where entity = 'booking' and entity_id = p_booking and to_status = 'closed'
$$;

-- Balance still owed on a booking (statements sent and not paid).
create or replace function app.ntf_booking_balance(p_booking uuid) returns bigint
language sql stable security definer set search_path = public, app as $$
  select coalesce(sum(greatest(s.charges_cents + s.hst_cents - s.deposit_applied_cents - s.charged_to_card_cents, 0)), 0)
    from booking_statements s where s.booking_id = p_booking and s.sent_at is not null and s.paid_at is null
$$;

create or replace function app.ntf_renter_clear(p_booking uuid, p_renter uuid) returns boolean
language sql stable security definer set search_path = public, app as $$
  select not exists (select 1 from renters r where r.id = p_renter and r.is_blocked)
     and not exists (select 1 from incidents i where i.booking_id = p_booking and i.status <> 'closed')
     and not exists (select 1 from disputes d where d.booking_id = p_booking and d.status in ('open', 'evidence_submitted'))
     and not exists (select 1 from bookings b where b.renter_id = p_renter and app.ntf_booking_balance(b.id) > 0)
$$;

create or replace function app.notify_followups(p_now timestamptz default now()) returns integer
language plpgsql security definer set search_path = public, app as $$
declare
  s program_settings := app.settings(app.local_date(p_now));
  v_today date := app.local_date(p_now);
  r record;
  v_n integer := 0;
  v_promo uuid;
  v_code text;
  v_bps integer;
  v_kind text;
  v_days integer;
  v_closed date;
begin
  for r in select b.id, b.renter_id, b.vehicle_id, rn.user_id, app.local_date(app.ntf_closed_at(b.id)) as closed_on
             from bookings b join renters rn on rn.id = b.renter_id
            where b.status = 'closed' and b.booking_type <> 'owner'
              and app.local_date(app.ntf_closed_at(b.id)) between v_today - greatest(s.notify_comeback_1m_days, s.notify_comeback_1w_days, s.notify_review_request_days) - 3 and v_today loop
    -- review request (implied consent: not unsubscribed), no review yet
    if r.closed_on <= v_today - s.notify_review_request_days and r.closed_on > v_today - s.notify_review_request_days - 3
       and not exists (select 1 from reviews x where x.booking_id = r.id) and app.ntf_renter_clear(r.id, r.renter_id)
       and app.has_marketing_consent(r.user_id, 'implied') then
      insert into marketing_sends (code, booking_id, renter_id, user_id) values ('renter_review_request', r.id, r.renter_id, r.user_id)
      on conflict (code, booking_id) do nothing;
      if found then
        perform app.ntf_emit('renter_review_request', 'booking', r.id, 'closed', jsonb_build_object('booking_id', r.id));
        v_n := v_n + 1;
      end if;
    end if;
    -- come-back offers (express consent), with a single-use code for this renter
    foreach v_kind in array array['renter_comeback_1w', 'renter_comeback_1m'] loop
      v_days := case v_kind when 'renter_comeback_1w' then s.notify_comeback_1w_days else s.notify_comeback_1m_days end;
      v_bps := case v_kind when 'renter_comeback_1w' then s.notify_comeback_1w_bps else s.notify_comeback_1m_bps end;
      continue when not (r.closed_on <= v_today - v_days and r.closed_on > v_today - v_days - 3);
      continue when not app.has_marketing_consent(r.user_id, 'express');
      continue when not app.ntf_renter_clear(r.id, r.renter_id);
      continue when exists (select 1 from bookings f where f.renter_id = r.renter_id and f.id <> r.id
                              and (f.status in ('requested', 'offered', 'tentative', 'pending_payment', 'confirmed', 'on_rent')
                                   or (v_kind = 'renter_comeback_1m' and f.created_at > app.ntf_closed_at(r.id))));
      continue when exists (select 1 from marketing_sends m where m.code = v_kind and m.booking_id = r.id);
      v_code := 'BACK' || upper(substr(md5(r.id::text || v_kind || clock_timestamp()::text), 1, 6));
      insert into promo_codes (code, description, percent_bps, valid_from, valid_until, max_uses, once_per_renter, renter_id, source)
      values (v_code, format('Come-back offer after booking %s', (select booking_number from bookings where id = r.id)), v_bps,
              p_now, app.local_midnight(v_today + s.notify_comeback_valid_days + 1), 1, true, r.renter_id,
              case v_kind when 'renter_comeback_1w' then 'followup_7d' else 'followup_30d' end)
      returning id into v_promo;
      insert into marketing_sends (code, booking_id, renter_id, user_id, promo_code_id,
                                   consent_id)
      values (v_kind, r.id, r.renter_id, r.user_id, v_promo,
              (select c.id from consents c where c.user_id = r.user_id and c.consent_code = 'marketing' and c.withdrawn_at is null order by c.given_at desc limit 1));
      perform app.ntf_emit(v_kind, 'booking', r.id, 'closed', jsonb_build_object('booking_id', r.id,
        'discount_code', v_code, 'discount_percent', (v_bps / 100.0)::numeric(6, 2)::float8::text,
        'discount_expires', app.fmt_day(v_today + s.notify_comeback_valid_days), 'discount_applies_to', 'the rental charge'));
      v_n := v_n + 1;
    end loop;
  end loop;
  return v_n;
end $$;

-- 4c. Daily checks: balance overdue, insurer invoices outstanding, statements reminder, payouts due.
create or replace function app.notify_daily_checks(p_now timestamptz default now()) returns integer
language plpgsql security definer set search_path = public, app as $$
declare
  s program_settings := app.settings(app.local_date(p_now));
  v_today date := app.local_date(p_now);
  r record;
  v_n integer := 0;
  v_id bigint;
  v_days integer;
begin
  -- renter balance overdue: once at the set days, then on each 1st while a balance remains
  for r in select bs.id, bs.booking_id, bs.sent_at from booking_statements bs
            where bs.sent_at is not null and bs.paid_at is null
              and bs.charges_cents + bs.hst_cents - bs.deposit_applied_cents - bs.charged_to_card_cents > 0
              and app.local_date(bs.sent_at) <= v_today - s.notify_balance_overdue_days loop
    v_id := app.ntf_emit('renter_balance_overdue', 'booking_statement', r.id, 'first', jsonb_build_object('booking_id', r.booking_id));
    v_n := v_n + (v_id is not null)::integer;
    if extract(day from v_today) = 1 and app.local_date(r.sent_at) < v_today - s.notify_balance_overdue_days then
      v_id := app.ntf_emit('renter_balance_overdue', 'booking_statement', r.id, to_char(v_today, 'YYYY-MM'), jsonb_build_object('booking_id', r.booking_id));
      v_n := v_n + (v_id is not null)::integer;
    end if;
  end loop;
  -- insurer invoices outstanding: at the set days, then every repeat days; admins too from the admin days
  for r in select ii.*, ins.name as insurer from insurer_invoices ii join insurers ins on ins.id = ii.insurer_id
            where ii.status in ('sent', 'part_paid') and coalesce(ii.balance_cents, 0) > 0 loop
    v_days := v_today - app.local_date(r.sent_at);
    if v_days >= s.notify_insurer_due_days and (v_days - s.notify_insurer_due_days) % s.notify_insurer_repeat_days = 0 then
      v_id := app.ntf_emit('staff_insurer_invoice_due', 'insurer_invoice', r.id, v_days::text, jsonb_build_object(
        'booking_id', r.booking_id,
        '_roles', case when v_days >= s.notify_insurer_admin_days then jsonb_build_array('staff_va_finance', 'staff_admin') else jsonb_build_array('staff_va_finance') end,
        'insurer_name', r.insurer, 'invoice_number', r.invoice_number, 'claim_number', coalesce(r.claim_number, 'None'),
        'invoice_total', app.fmt_money(r.total_cents), 'amount_paid', app.fmt_money(r.paid_cents), 'balance_due', app.fmt_money(r.balance_cents),
        'invoice_sent_at', app.fmt_date(r.sent_at), 'days_outstanding', v_days::text,
        'last_contact', coalesce(app.fmt_date((select max(m.occurred_at) from messages m where m.booking_id = r.booking_id and m.direction = 'outbound'
                                                 and m.related_table = 'insurer_invoices')), 'None logged'),
        'adjuster_contact', 'On the booking',
        '_url', app.ntf_link('va_finance_insurer_invoice', jsonb_build_object('invoice_number', r.invoice_number)),
        '_digest_line', format('Insurer invoice %s unpaid, %s days', r.invoice_number, v_days)));
      v_n := v_n + (v_id is not null)::integer;
    end if;
  end loop;
  return v_n;
end $$;

create or replace function app.notify_statements_reminder(p_now timestamptz default now()) returns integer
language plpgsql security definer set search_path = public, app as $$
declare
  t tasks;
  v_month date;
begin
  select * into t from tasks where task_type = 'approve_owner_statements' and status in ('open', 'in_progress', 'waiting')
   order by created_at desc limit 1;
  if t.id is null then return 0; end if;
  v_month := (select to_date(j.run_key, 'YYYY-MM') from job_runs j where j.id = t.related_id);
  return (app.ntf_emit('staff_statements_ready_for_approval', 'job_run', t.related_id, 'reminder',
                       app.ntf_statements_payload(v_month)) is not null)::integer;
end $$;

create or replace function app.notify_payouts_due(p_now timestamptz default now()) returns integer
language plpgsql security definer set search_path = public, app as $$
declare
  s program_settings := app.settings(app.local_date(p_now));
  v_today date := app.local_date(p_now);
  v_kind text;
  v_n integer := 0;
  pl jsonb;
begin
  foreach v_kind in array array['owner', 'investor'] loop
    continue when (v_kind = 'owner' and extract(day from v_today) <> s.payout_day)
               or (v_kind = 'investor' and extract(day from v_today) <> s.investor_payment_day);
    select jsonb_build_object(
             'payout_count', count(*)::text, 'payout_total', app.fmt_money(coalesce(sum(p.amount_cents + p.hst_cents), 0)),
             'run_approved', bool_and(p.status in ('approved', 'sent', 'paid')),
             'payout_run_name', case v_kind when 'owner' then 'Owner payouts for ' else 'Investor returns for ' end || to_char(v_today - 15, 'FMMonth'),
             'payout_run_status', case when bool_and(p.status in ('approved', 'sent', 'paid')) then 'Approved and ready to send.'
                                       else 'Not approved yet: approve the run before sending.' end,
             'payout_rows', (select coalesce(jsonb_agg(jsonb_build_object('name', q.name, 'amount', q.amount)), '[]'::jsonb) from (
                               select coalesce(o.legal_name, i.legal_name, 'Payee') as name, app.fmt_money(p2.amount_cents + p2.hst_cents) as amount
                                 from payouts p2 left join owners o on o.id = p2.owner_id left join investors i on i.id = p2.investor_id
                                where p2.scheduled_for = v_today and p2.payee_type = v_kind and p2.status not in ('cancelled', 'failed', 'paid')
                                order by p2.amount_cents desc limit 10) q),
             '_url', app.ntf_link('admin_payouts'))
      into pl
      from payouts p
     where p.scheduled_for = v_today and p.payee_type = v_kind and p.status not in ('cancelled', 'failed', 'paid');
    continue when (pl ->> 'payout_count')::integer = 0;
    v_n := v_n + (app.ntf_emit('staff_payouts_due', 'payout_run', null, v_kind || ':' || v_today, pl) is not null)::integer;
  end loop;
  return v_n;
end $$;

-- 4d. Digests. One email per role and slot to each active staff member of the role; the queued
-- notices plus the standing lists of the role. The morning digest is always sent; the end-of-day
-- one only when it has something.
create or replace function app.ntf_item(p_line text, p_meta text, p_url text) returns jsonb
language sql immutable as $$ select jsonb_build_object('line', p_line, 'meta', coalesce(p_meta, ''), 'url', coalesce(p_url, '')) $$;

create or replace function app.ntf_standing_lists(p_role text, p_slot text, p_now timestamptz) returns jsonb
language plpgsql stable security definer set search_path = public, app as $$
declare
  s program_settings := app.settings(app.local_date(p_now));
  v_today date := app.local_date(p_now);
  v jsonb := '[]'::jsonb;
  items jsonb;
begin
  if p_role = 'admin' then
    select coalesce(jsonb_agg(app.ntf_item(t.title, 'Due ' || coalesce(app.fmt_at(t.due_at), 'not set'), app.ntf_link('admin_approvals')) order by t.due_at nulls last), '[]')
      into items from (select * from tasks where queue = 'admin' and status in ('open', 'in_progress', 'waiting') order by due_at nulls last limit 15) t;
    v := v || jsonb_build_array(jsonb_build_object('title', case p_slot when 'morning' then 'Approvals waiting' else 'Approvals still open' end, 'items', items));
    select coalesce(jsonb_agg(app.ntf_item('Booking ' || b.booking_number || ' is late', app.fmt_at(b.return_at), app.ntf_link('va_fleet_booking', jsonb_build_object('booking_number', b.booking_number)))), '[]')
      into items from bookings b where b.status = 'on_rent' and b.return_at < p_now;
    v := v || jsonb_build_array(jsonb_build_object('title', 'Late returns', 'items', items));
    if p_slot = 'morning' then
      select coalesce(jsonb_agg(app.ntf_item('Incident ' || i.incident_number || ': ' || replace(i.kind, '_', ' '), initcap(i.status), app.ntf_link('admin_incident', jsonb_build_object('incident_number', i.incident_number)))), '[]')
        into items from incidents i where i.status <> 'closed';
      v := v || jsonb_build_array(jsonb_build_object('title', 'Open incidents and claims', 'items', items));
      select coalesce(jsonb_agg(app.ntf_item('Dispute ' || app.fmt_money(d.amount_cents), 'Evidence due ' || coalesce(app.fmt_at(d.evidence_due_at), 'not set'), app.ntf_link('admin_dispute', jsonb_build_object('dispute_id', d.id)))), '[]')
        into items from disputes d where d.status in ('open', 'evidence_submitted');
      v := v || jsonb_build_array(jsonb_build_object('title', 'Open disputes', 'items', items));
      select coalesce(jsonb_agg(app.ntf_item('Job ' || j.job_name || ' failed', j.run_key, app.ntf_link('admin_jobs'))), '[]')
        into items from job_runs j where j.status = 'failed' and j.started_at > p_now - interval '2 days';
      v := v || jsonb_build_array(jsonb_build_object('title', 'Failed jobs', 'items', items));
      select coalesce(jsonb_agg(app.ntf_item(o.legal_name || ': invoice ' || i.invoice_number || ' in arrears', app.fmt_money(i.balance_cents), app.ntf_link('va_finance_invoice', jsonb_build_object('invoice_number', i.invoice_number)))), '[]')
        into items from owner_invoices i join owners o on o.id = i.owner_id where i.status = 'in_arrears';
      v := v || jsonb_build_array(jsonb_build_object('title', 'Owners in arrears', 'items', items));
    else
      select coalesce(jsonb_agg(app.ntf_item('Booking ' || b.booking_number || ' confirmed', app.vehicle_name(b.vehicle_id), app.ntf_link('va_cs_booking', jsonb_build_object('booking_number', b.booking_number)))), '[]')
        into items from bookings b where app.local_date(b.confirmed_at) = v_today;
      v := v || jsonb_build_array(jsonb_build_object('title', 'Bookings confirmed today', 'items', items));
      select coalesce(jsonb_agg(app.ntf_item(case when app.local_date(b.pickup_at) = v_today + 1 then 'Pickup ' else 'Return ' end || b.booking_number,
                                             app.fmt_time(case when app.local_date(b.pickup_at) = v_today + 1 then b.pickup_at else b.return_at end),
                                             app.ntf_link('va_fleet_booking', jsonb_build_object('booking_number', b.booking_number)))), '[]')
        into items from bookings b where (b.status = 'confirmed' and app.local_date(b.pickup_at) = v_today + 1) or (b.status = 'on_rent' and app.local_date(b.return_at) = v_today + 1);
      v := v || jsonb_build_array(jsonb_build_object('title', 'Tomorrow''s pickups and returns', 'items', items));
    end if;
  elsif p_role = 'va_finance' then
    select coalesce(jsonb_agg(app.ntf_item('Booking ' || b.booking_number || ' returned, no statement yet', app.fmt_date(b.checked_in_at), app.ntf_link('va_finance_booking', jsonb_build_object('booking_number', b.booking_number)))), '[]')
      into items from bookings b where b.status = 'returned' and not exists (select 1 from booking_statements x where x.booking_id = b.id and x.kind = 'check_in');
    v := v || jsonb_build_array(jsonb_build_object('title', 'Returns waiting for a statement', 'items', items));
    select coalesce(jsonb_agg(app.ntf_item('Refund ' || app.fmt_money(f.amount_cents) || ' on ' || b.booking_number, replace(f.status, '_', ' '), app.ntf_link('va_finance_booking', jsonb_build_object('booking_number', b.booking_number)))), '[]')
      into items from refunds f join bookings b on b.id = f.booking_id where f.status in ('pending_approval', 'approved', 'processing');
    v := v || jsonb_build_array(jsonb_build_object('title', 'Refunds to process', 'items', items));
    select coalesce(jsonb_agg(app.ntf_item('Payment ' || app.fmt_money(p.amount_cents) || ' declined', coalesce('Retry ' || app.fmt_at(p.next_retry_at), 'No retry set'), app.ntf_link('va_finance'))), '[]')
      into items from payments p where p.status = 'failed' and p.renter_id is not null
                                   and (case p_slot when 'morning' then app.local_date(p.next_retry_at) = v_today else app.local_date(p.updated_at) = v_today end);
    v := v || jsonb_build_array(jsonb_build_object('title', case p_slot when 'morning' then 'Card retries due today' else 'Payments that failed today' end, 'items', items));
    if p_slot = 'morning' then
      select coalesce(jsonb_agg(app.ntf_item(initcap(replace(t.kind, '_', ' ')) || ' ' || coalesce(t.notice_number, ''), app.fmt_money(t.amount_cents), app.ntf_link('va_finance_toll', jsonb_build_object('toll_ticket_id', t.id)))), '[]')
        into items from toll_tickets t where t.status in ('logged', 'matched');
      v := v || jsonb_build_array(jsonb_build_object('title', 'Tolls and tickets to match and charge', 'items', items));
      select coalesce(jsonb_agg(app.ntf_item('Owner invoice ' || i.invoice_number || ' ' || replace(i.status, '_', ' '), app.fmt_money(i.total_cents), app.ntf_link('va_finance_invoice', jsonb_build_object('invoice_number', i.invoice_number)))), '[]')
        into items from owner_invoices i where i.status in ('failed', 'in_arrears');
      v := v || jsonb_build_array(jsonb_build_object('title', 'Owner invoices failed', 'items', items));
    else
      select coalesce(jsonb_agg(app.ntf_item('Booking ' || b.booking_number || ' cancelled', app.fmt_money(c.refund_cents) || ' to refund', app.ntf_link('va_finance_booking', jsonb_build_object('booking_number', b.booking_number)))), '[]')
        into items from booking_cancellations c join bookings b on b.id = c.booking_id where app.local_date(c.created_at) = v_today;
      v := v || jsonb_build_array(jsonb_build_object('title', 'Cancellations received today', 'items', items));
    end if;
  elsif p_role = 'va_fleet' then
    select coalesce(jsonb_agg(app.ntf_item(initcap(replace(j.kind, '_', ' ')) || ', ' || app.vehicle_name(j.vehicle_id), app.fmt_time(j.scheduled_at) || ', '
                                           || coalesce((select u.full_name from users u where u.id = j.assigned_to), 'nobody assigned')
                                           || case when j.acknowledged_at is null then ', not acknowledged' else '' end,
                                           app.ntf_link('field_job', jsonb_build_object('job_id', j.id))) order by j.scheduled_at), '[]')
      into items from field_jobs j where j.status not in ('cancelled', 'done')
                                     and app.local_date(j.scheduled_at) = case p_slot when 'morning' then v_today else v_today + 1 end;
    v := v || jsonb_build_array(jsonb_build_object('title', case p_slot when 'morning' then 'Today''s jobs' else 'Tomorrow''s jobs' end, 'items', items));
    select coalesce(jsonb_agg(app.ntf_item('Booking ' || b.booking_number || ' is late', app.fmt_at(b.return_at), app.ntf_link('va_fleet_booking', jsonb_build_object('booking_number', b.booking_number)))), '[]')
      into items from bookings b where b.status = 'on_rent' and b.return_at < p_now;
    v := v || jsonb_build_array(jsonb_build_object('title', 'Late returns', 'items', items));
    if p_slot = 'morning' then
      select coalesce(jsonb_agg(app.ntf_item(app.vehicle_name(l.vehicle_id), 'Waiting since ' || app.fmt_at(l.updated_at), app.ntf_link('va_fleet_listing', jsonb_build_object('vehicle_id', l.vehicle_id)))), '[]')
        into items from listing_intakes l where l.state = 'needs_review';
      v := v || jsonb_build_array(jsonb_build_object('title', 'Listings to review', 'items', items));
    else
      select coalesce(jsonb_agg(app.ntf_item('Incident ' || i.incident_number, initcap(i.status), app.ntf_link('admin_incident', jsonb_build_object('incident_number', i.incident_number)))), '[]')
        into items from incidents i where app.local_date(i.updated_at) = v_today;
      v := v || jsonb_build_array(jsonb_build_object('title', 'Incidents updated today', 'items', items));
    end if;
  elsif p_role = 'va_cs' then
    select coalesce(jsonb_agg(app.ntf_item('Request ' || b.booking_number || ', ' || app.vehicle_name(b.vehicle_id), 'Received ' || app.fmt_at(b.requested_at), app.ntf_link('va_cs_booking', jsonb_build_object('booking_number', b.booking_number))) order by b.requested_at), '[]')
      into items from bookings b where b.status = 'requested';
    v := v || jsonb_build_array(jsonb_build_object('title', case p_slot when 'morning' then 'Requests waiting for an offer' else 'Requests still unanswered' end, 'items', items));
    select coalesce(jsonb_agg(app.ntf_item('Offer ' || b.booking_number, 'Expires ' || app.fmt_at(b.offer_expires_at), app.ntf_link('va_cs_booking', jsonb_build_object('booking_number', b.booking_number))) order by b.offer_expires_at), '[]')
      into items from bookings b where b.status = 'offered' and (p_slot = 'morning' or exists (select 1 from booking_offers o where o.booking_id = b.id and app.local_date(o.sent_at) = v_today));
    v := v || jsonb_build_array(jsonb_build_object('title', case p_slot when 'morning' then 'Offers open' else 'Offers sent today and still open' end, 'items', items));
    select coalesce(jsonb_agg(app.ntf_item('Booking ' || b.booking_number || ': ' || replace(u.kind, '_', ' '), 'Uploaded ' || app.fmt_at(u.uploaded_at), app.ntf_link('va_cs_identity', jsonb_build_object('booking_number', b.booking_number)))), '[]')
      into items from verification_uploads u join bookings b on b.id = u.booking_id where u.status = 'submitted';
    v := v || jsonb_build_array(jsonb_build_object('title', 'Documents to review', 'items', items));
    select coalesce(jsonb_agg(app.ntf_item('Review ' || r.rating || ' stars, booking ' || b.booking_number, coalesce(r.title, ''), app.ntf_link('va_cs_reviews'))), '[]')
      into items from reviews r join bookings b on b.id = r.booking_id where r.status = 'pending' and (p_slot = 'morning' or app.local_date(r.created_at) = v_today);
    v := v || jsonb_build_array(jsonb_build_object('title', case p_slot when 'morning' then 'Reviews to moderate' else 'Reviews received today' end, 'items', items));
  elsif p_role = 'va_sales' then
    select coalesce(jsonb_agg(app.ntf_item(coalesce(l.name, 'Enquiry'), 'Received ' || app.fmt_at(l.created_at), app.ntf_link('va_sales'))), '[]')
      into items from leads l where l.kind = 'owner_program' and (case p_slot when 'morning' then l.status = 'new' else app.local_date(l.created_at) = v_today end);
    v := v || jsonb_build_array(jsonb_build_object('title', case p_slot when 'morning' then 'Owner applications not answered' else 'Applications received today' end, 'items', items));
    if p_slot = 'morning' then
      select coalesce(jsonb_agg(app.ntf_item(app.vehicle_name(o.vehicle_id), 'Documents sent ' || coalesce(app.fmt_date(o.documents_sent_at), ''), app.ntf_link('va_sales'))), '[]')
        into items from vehicle_onboardings o where o.status = 'documents_sent';
      v := v || jsonb_build_array(jsonb_build_object('title', 'Documents sent but not signed', 'items', items));
      select coalesce(jsonb_agg(app.ntf_item('Upfront invoice ' || i.invoice_number, app.fmt_money(i.total_cents), app.ntf_link('va_sales'))), '[]')
        into items from owner_invoices i where i.kind = 'upfront' and i.status in ('issued', 'processing', 'failed');
      v := v || jsonb_build_array(jsonb_build_object('title', 'Upfront invoices unpaid', 'items', items));
    end if;
  end if;
  -- counts, and drop empty lists
  return (select coalesce(jsonb_agg(x || jsonb_build_object('count', jsonb_array_length(x -> 'items'))), '[]'::jsonb)
            from jsonb_array_elements(v) x where jsonb_array_length(x -> 'items') > 0);
end $$;

create or replace function app.notify_digests(p_slot text, p_run uuid, p_now timestamptz default now()) returns integer
language plpgsql security definer set search_path = public, app as $$
declare
  v_today date := app.local_date(p_now);
  v_role text;
  v_items jsonb;
  v_lists jsonb;
  v_sections jsonb;
  v_queued integer;
  v_standing integer;
  v_n integer := 0;
  v_code text;
begin
  if p_slot not in ('morning', 'eod') then raise exception 'Slot must be morning or eod' using errcode = '22023'; end if;
  foreach v_role in array array['admin', 'va_finance', 'va_fleet', 'va_cs', 'va_sales'] loop
    v_code := 'staff_digest_' || p_slot || '_' || v_role;
    select coalesce(jsonb_agg(app.ntf_item(d.line, coalesce(d.meta, app.fmt_at(d.created_at)), d.url) order by d.created_at), '[]'::jsonb), count(*)
      into v_items, v_queued
      from staff_digest_items d
     where d.role = v_role and d.digested_at is null and d.created_at <= p_now and (d.digest_slot = 'next' or p_slot = 'morning');
    v_lists := app.ntf_standing_lists(v_role, p_slot, p_now);
    v_standing := coalesce((select sum((x ->> 'count')::integer) from jsonb_array_elements(v_lists) x), 0);
    v_sections := case when v_queued > 0 then jsonb_build_array(jsonb_build_object('title', 'New since the last digest', 'items', v_items, 'count', v_queued)) else '[]'::jsonb end
                  || v_lists;
    continue when p_slot = 'eod' and v_queued + v_standing = 0;
    perform app.ntf_emit(v_code, 'job_run', p_run, v_role, jsonb_build_object(
      'digest_date', to_char(p_now at time zone 'America/Toronto', 'Dy, Mon FMDD'),
      'digest_count', (v_queued + v_standing)::text,
      'digest_summary', case when v_queued + v_standing = 0 then 'Nothing is waiting.'
                             else v_queued || ' new notice' || case when v_queued <> 1 then 's' else '' end || ' and '
                                  || v_standing || ' item' || case when v_standing <> 1 then 's' else '' end || ' on the standing lists.' end,
      'has_items', v_queued + v_standing > 0,
      'sections', v_sections,
      'stat_1', v_queued || ' new', 'stat_2', v_standing || ' open',
      '_url', app.ntf_link(case v_role when 'admin' then 'admin' when 'va_finance' then 'va_finance' when 'va_fleet' then 'va_fleet'
                                       when 'va_cs' then 'va_cs' else 'va_sales' end)));
    update staff_digest_items set digested_at = p_now, digest_code = v_code, digest_run_key = p_run::text
     where role = v_role and digested_at is null and created_at <= p_now and (digest_slot = 'next' or p_slot = 'morning');
    v_n := v_n + 1;
  end loop;
  return v_n;
end $$;

-- Field staff job lists (today in the morning, tomorrow in the evening), one per person with jobs.
create or replace function app.notify_field_lists(p_which text, p_now timestamptz default now()) returns integer
language plpgsql security definer set search_path = public, app as $$
declare
  v_day date := app.local_date(p_now) + case p_which when 'tomorrow' then 1 else 0 end;
  r record;
  v_n integer := 0;
begin
  for r in select j.assigned_to,
                  jsonb_agg(jsonb_build_object('time', app.fmt_time(j.scheduled_at), 'type', initcap(replace(j.kind, '_', ' ')),
                                               'vehicle', app.vehicle_name(j.vehicle_id) || coalesce(' (' || v.plate || ')', ''),
                                               'place', coalesce(j.place, 'See the job'),
                                               'note', coalesce(nullif(j.instructions, ''), ''),
                                               'url', app.ntf_link('field_job', jsonb_build_object('job_id', j.id))) order by j.scheduled_at) as jobs,
                  count(*) as n, min(j.scheduled_at) as first_at,
                  count(*) filter (where j.kind in ('handover', 'delivery')) as pickups,
                  count(*) filter (where j.kind in ('return_check_in', 'pickup_from_renter')) as returns
             from field_jobs j join vehicles v on v.id = j.vehicle_id
            where j.assigned_to is not null and j.status in ('scheduled', 'acknowledged') and app.local_date(j.scheduled_at) = v_day
            group by j.assigned_to loop
    perform app.ntf_emit('staff_field_jobs_' || p_which, 'user', r.assigned_to, v_day::text, jsonb_build_object(
      'recipient_user_id', r.assigned_to, 'digest_date', to_char(v_day, 'Dy, Mon FMDD'), 'jobs', r.jobs,
      'job_count', r.n::text, 'first_job_time', app.fmt_time(r.first_at),
      'jobs_summary', concat_ws(' and ', case when r.pickups > 0 then r.pickups || ' pickup' || case when r.pickups > 1 then 's' else '' end end,
                                         case when r.returns > 0 then r.returns || ' return' || case when r.returns > 1 then 's' else '' end end,
                                         case when r.n - r.pickups - r.returns > 0 then (r.n - r.pickups - r.returns) || ' other job' || case when r.n - r.pickups - r.returns > 1 then 's' else '' end end)
                      || '. Please acknowledge each one.',
      '_url', app.ntf_link('field')));
    v_n := v_n + 1;
  end loop;
  return v_n;
end $$;

-- The weekly summary for the admins (week Monday to Sunday that just ended).
create or replace function app.notify_weekly_summary(p_run uuid, p_now timestamptz default now()) returns integer
language plpgsql security definer set search_path = public, app as $$
declare
  v_end date := app.local_date(p_now) - extract(isodow from app.local_date(p_now))::integer + 1;   -- this Monday
  v_start date := v_end - 7;
  a timestamptz := app.local_midnight(v_end - 7);
  z timestamptz := app.local_midnight(v_end);
  pa timestamptz := app.local_midnight(v_end - 14);
  m record;
  pm record;
  v_fleet integer := greatest(app.fleet_count(v_end - 1, false), 1);
  v_util numeric;
  v_putil numeric;
  v_overdue jsonb;
begin
  select (select count(*) from booking_events e where e.kind = 'requested' and e.created_at >= a and e.created_at < z) as req,
         (select count(*) from booking_events e where e.kind = 'offer_sent' and e.created_at >= a and e.created_at < z) as offers,
         (select count(*) from bookings b where b.confirmed_at >= a and b.confirmed_at < z) as confirmed,
         (select count(*) from booking_events e where e.kind = 'offer_expired' and e.created_at >= a and e.created_at < z) as expired,
         (select coalesce(sum(p.amount_cents), 0) from payments p where p.status = 'succeeded' and p.kind in ('charge', 'capture') and p.renter_id is not null
            and coalesce(p.processed_at, p.updated_at) >= a and coalesce(p.processed_at, p.updated_at) < z) as revenue,
         (select coalesce(sum(extract(epoch from (least(b.return_at, z) - greatest(b.pickup_at, a)))), 0) from bookings b
           where b.status in ('on_rent', 'returned', 'closed') and b.pickup_at < z and b.return_at > a) as secs
    into m;
  select (select count(*) from bookings b where b.confirmed_at >= pa and b.confirmed_at < a) as confirmed,
         (select count(*) from booking_events e where e.kind = 'requested' and e.created_at >= pa and e.created_at < a) as req,
         (select count(*) from booking_events e where e.kind = 'offer_sent' and e.created_at >= pa and e.created_at < a) as offers,
         (select count(*) from booking_events e where e.kind = 'offer_expired' and e.created_at >= pa and e.created_at < a) as expired,
         (select coalesce(sum(p.amount_cents), 0) from payments p where p.status = 'succeeded' and p.kind in ('charge', 'capture') and p.renter_id is not null
            and coalesce(p.processed_at, p.updated_at) >= pa and coalesce(p.processed_at, p.updated_at) < a) as revenue,
         (select coalesce(sum(extract(epoch from (least(b.return_at, a) - greatest(b.pickup_at, pa)))), 0) from bookings b
           where b.status in ('on_rent', 'returned', 'closed') and b.pickup_at < a and b.return_at > pa) as secs
    into pm;
  v_util := round(100 * m.secs / (v_fleet * 7 * 86400.0));
  v_putil := round(100 * pm.secs / (v_fleet * 7 * 86400.0));
  select coalesce(jsonb_agg(x), '[]'::jsonb) into v_overdue from (
    select app.ntf_item('Late return: booking ' || b.booking_number, 'Due back ' || app.fmt_at(b.return_at), app.ntf_link('va_fleet_booking', jsonb_build_object('booking_number', b.booking_number))) x
      from bookings b where b.status = 'on_rent' and b.return_at < p_now
    union all
    select app.ntf_item('Charge unpaid: booking ' || b.booking_number || ', ' || app.fmt_money(app.ntf_booking_balance(b.id)), 'Statement sent', app.ntf_link('va_finance_booking', jsonb_build_object('booking_number', b.booking_number)))
      from bookings b where app.ntf_booking_balance(b.id) > 0
    union all
    select app.ntf_item('Deposit not released: booking ' || b.booking_number, 'Due ' || app.fmt_day(d.release_due_on), app.ntf_link('va_finance_booking', jsonb_build_object('booking_number', b.booking_number)))
      from deposits d join bookings b on b.id = d.booking_id where d.status in ('held', 'captured') and d.release_due_on < app.local_date(p_now)) q;
  return (app.ntf_emit('staff_weekly_summary', 'job_run', p_run, 'week', jsonb_build_object(
    'week_label', to_char(v_start, 'Mon FMDD') || ' to ' || to_char(v_end - 1, case when extract(month from v_start) = extract(month from v_end - 1) then 'FMDD' else 'Mon FMDD' end),
    'bookings_confirmed', m.confirmed::text,
    'bookings_change', case when m.confirmed > pm.confirmed then 'Up ' || (m.confirmed - pm.confirmed) when m.confirmed < pm.confirmed then 'Down ' || (pm.confirmed - m.confirmed) else 'Same as last week' end,
    'revenue_collected', app.fmt_money(m.revenue),
    'revenue_change', case when m.revenue >= pm.revenue then 'Up ' else 'Down ' end || app.fmt_money(abs(m.revenue - pm.revenue)),
    'utilization', v_util || '%',
    'utilization_change', case when v_util >= v_putil then 'Up ' else 'Down ' end || abs(v_util - v_putil) || ' points',
    'weekly_metrics', jsonb_build_array(
        jsonb_build_object('label', 'Requests received', 'value', m.req::text, 'previous', pm.req::text),
        jsonb_build_object('label', 'Offers sent', 'value', m.offers::text, 'previous', pm.offers::text),
        jsonb_build_object('label', 'Offers approved and paid', 'value', m.confirmed::text, 'previous', pm.confirmed::text),
        jsonb_build_object('label', 'Offers expired', 'value', m.expired::text, 'previous', pm.expired::text)),
    'overdue_count', jsonb_array_length(v_overdue)::text, 'overdue_items', v_overdue,
    'upcoming_1', (select count(*) filter (where b.status = 'confirmed' and b.pickup_at >= z and b.pickup_at < z + interval '7 days') || ' pickups and '
                          || count(*) filter (where b.status in ('confirmed', 'on_rent') and b.return_at >= z and b.return_at < z + interval '7 days') || ' returns booked.'
                     from bookings b),
    'upcoming_2', (select count(*) || ' owner statement' || case when count(*) <> 1 then 's' else '' end || ' in draft.' from owner_statements s where s.status = 'draft'),
    'upcoming_3', (select count(*) || ' vehicle' || case when count(*) <> 1 then 's' else '' end || ' under exit notice.' from vehicle_exits e where e.status = 'notice'),
    '_url', app.ntf_link('admin_weekly'))) is not null)::integer;
end $$;

-- 4e. The scheduled wrapper (every 5 minutes): each part runs once on its Toronto day, from its
-- time, claimed in job_runs (job_name, run_key) so a retry or an overlapping run does nothing.
create or replace function app.job_notify_scheduled(p_now timestamptz default now()) returns text
language plpgsql security definer set search_path = public, app as $$
declare
  s program_settings := app.settings(app.local_date(p_now));
  v_day date := app.local_date(p_now);
  v_local time := (p_now at time zone 'America/Toronto')::time;
  v_done text[] := '{}';
  v_failed boolean := false;
  r record;
  v_run uuid;
  v_n integer;
begin
  for r in select * from (values
      ('notify-digest-morning', v_day::text, s.notify_digest_morning, true),
      ('notify-digest-eod', v_day::text, s.notify_digest_eod, true),
      ('notify-field-today', v_day::text, s.notify_field_today, true),
      ('notify-field-tomorrow', v_day::text, s.notify_field_tomorrow, true),
      ('notify-followups', v_day::text, s.notify_followup_time, true),
      ('notify-daily-checks', v_day::text, s.notify_daily_checks_time, true),
      ('notify-payouts-due', v_day::text, s.notify_payouts_due_time,
         extract(day from v_day) in (s.payout_day, s.investor_payment_day)),
      ('notify-statements-reminder', to_char(v_day, 'YYYY-MM'), s.notify_statements_reminder_time,
         extract(day from v_day) = s.notify_statements_reminder_day),
      ('notify-weekly-summary', to_char(v_day, 'IYYY-"W"IW'), s.notify_weekly_time, extract(isodow from v_day) = s.notify_weekly_dow)
    ) t(job, run_key, at_time, today) loop
    continue when not r.today or v_local < r.at_time;
    -- the evening digest and tomorrow's list belong to the evening only
    v_run := app.job_claim(r.job, r.run_key);
    continue when v_run is null;
    begin
      v_n := case r.job
        when 'notify-digest-morning' then app.notify_digests('morning', v_run, p_now)
        when 'notify-digest-eod' then app.notify_digests('eod', v_run, p_now)
        when 'notify-field-today' then app.notify_field_lists('today', p_now)
        when 'notify-field-tomorrow' then app.notify_field_lists('tomorrow', p_now)
        when 'notify-followups' then app.notify_followups(p_now)
        when 'notify-daily-checks' then app.notify_daily_checks(p_now)
        when 'notify-payouts-due' then app.notify_payouts_due(p_now)
        when 'notify-statements-reminder' then app.notify_statements_reminder(p_now)
        when 'notify-weekly-summary' then app.notify_weekly_summary(v_run, p_now)
      end;
      perform app.job_succeed(v_run, jsonb_build_object('emitted', v_n));
      v_done := v_done || r.job;
    exception when others then
      perform app.job_fail(v_run, sqlerrm);
      v_failed := true;
    end;
  end loop;
  return case when v_failed then 'failed' when cardinality(v_done) = 0 then 'not_due' else 'succeeded' end;
end $$;

-- ================================================================ 5. catalogue documentation: who emits each code
update notification_catalogue set emitted_by = x.by from (values
  ('renter_agreement_ready', 'app.open_rental_agreement (0019); unsigned-for-an-hour reminder, app.notify_reminders (0023)'),
  ('renter_agreement_signed', 'app.complete_signature_request (0019)'),
  ('renter_request_needs_info', 'app.ask_booking_info (0019)'),
  ('renter_change_request_received', '0019 change requests'), ('staff_change_request_received', '0019 change requests'),
  ('renter_change_request_approved', '0019 change requests'), ('renter_change_request_declined', '0019 change requests'),
  ('renter_extension_requested', 'app.request_extension (0019)'), ('staff_extension_requested', 'app.request_extension (0019)'),
  ('renter_extension_approved', '0019 extensions'), ('renter_extension_declined', '0019 extensions'), ('renter_extension_confirmed', '0019 extensions'),
  ('staff_identity_review', '0019 verification uploads'), ('renter_identity_approved', '0019 verification'), ('renter_identity_rejected', '0019 verification'),
  ('staff_field_job_assigned', 'field_jobs trigger (0020)'), ('staff_field_job_changed', 'field_jobs trigger (0020)'),
  ('renter_deposit_declined', 'app.record_deposit_declined (0020)'), ('staff_return_findings', 'condition report reviewed (0020)'),
  ('renter_damage_found', 'app.report_damage_to_renter (0020)'), ('renter_deposit_released', 'app.settle_deposit (0020)'),
  ('staff_approval_needed', 'app.settle_deposit, task escalation (0020)'), ('staff_disable_approval_needed', 'app.request_tracker_disable (0020)'),
  ('owner_document_due', 'expiry-watch (0020)'), ('staff_expiry_watch', 'expiry-watch (0020)'),
  ('staff_toll_ticket_logged', 'app.log_toll_ticket (0021)'), ('staff_toll_ticket_unmatched', 'toll-watch (0021)'),
  ('renter_extra_charge', 'charge_toll_ticket, bill_damage (0021)'), ('owner_toll_ticket', 'app.bill_toll_to_owner (0021)'),
  ('renter_named_to_authority', 'app.name_renter_to_authority (0021)'), ('owner_statement_ready', 'app.issue_owner_statement (0021)'),
  ('staff_monthly_statements_ready', 'app.finalize_company_statement (0021)'),
  ('owner_application_received', 'app.submit_lead, owner vehicle intake (0022)'), ('staff_owner_application_received', 'app.submit_lead, owner vehicle intake (0022)'),
  ('staff_listing_ready_for_review', 'listing pipeline (0022)'), ('owner_vehicle_listed', 'app.publish_listing (0022)'),
  ('owner_exit_notice_received', 'app.give_exit_notice (0022)'), ('staff_exit_notice_received', 'app.give_exit_notice (0022)'),
  ('owner_exit_completed', 'app.complete_exit (0022)'), ('owner_fee_change_notice', 'app.give_fee_change_notice (0022)'),
  ('owner_bank_details_changed', 'payout details and payment method functions (0022)'),
  ('renter_request_received', 'booking_events_notify (0023)'), ('staff_booking_request_new', 'booking_events_notify (0023)'),
  ('renter_offer_ready', 'booking_events_notify (0023)'), ('renter_offer_expired', 'booking_events_notify (0023)'),
  ('renter_offer_withdrawn', 'booking_events_notify (0023)'), ('renter_request_declined', 'booking_events_notify (0023)'),
  ('renter_booking_confirmed', 'bookings_notify_status (0023)'), ('owner_new_booking', 'bookings_notify_status (0023)'),
  ('owner_booking_confirmed', 'bookings_notify_status (0023)'), ('staff_offer_approved_paid', 'bookings_notify_status (0023)'),
  ('renter_rental_started', 'bookings_notify_status (0023)'), ('renter_return_complete', 'bookings_notify_status (0023)'),
  ('renter_booking_cancelled', 'booking_cancellations_notify (0023)'), ('renter_booking_cancelled_by_us', 'booking_cancellations_notify (0023)'),
  ('staff_cancellation_received', 'booking_cancellations_notify (0023)'),
  ('renter_payment_receipt', 'payments_notify (0023)'), ('renter_payment_failed', 'payments_notify (0023)'),
  ('staff_payment_failed', 'payments_notify; 24-hour alert in app.notify_reminders (0023)'),
  ('renter_refund_issued', 'refunds_notify (0023)'), ('renter_final_statement', 'booking_statements_notify (0023)'),
  ('renter_account_created', 'user_roles_notify (0023)'), ('owner_account_created', 'user_roles_notify (0023)'),
  ('owner_agreement_ready', 'vehicle_onboardings_notify (0023)'), ('owner_agreement_signed', 'vehicle_onboardings_notify (0023)'),
  ('owner_onboarding_steps', 'vehicle_onboardings_notify (0023)'), ('owner_registry_visit', 'vehicle_onboardings_notify (0023)'),
  ('owner_vehicle_enrolled', 'vehicle_onboardings_notify (0023)'), ('owner_application_declined', 'vehicle_onboardings_notify (0023)'),
  ('owner_upfront_invoice', 'owner_invoices_notify (0023)'), ('owner_fee_invoice', 'owner_invoices_notify (0023)'),
  ('owner_payment_received', 'owner_invoices_notify (0023)'), ('owner_payment_failed', 'owner_invoices_notify (0023)'),
  ('owner_in_arrears', 'owner_invoices_notify (0023)'), ('staff_owner_invoice_failed', 'owner_invoices_notify (0023)'),
  ('owner_payout_sent', 'payouts_notify (0023)'),
  ('investor_return_paid', 'investment_returns_notify (0023)'), ('investor_statement_ready', 'investment_returns_notify (0023)'),
  ('investor_notice_received', 'investment_elections_notify, investment_redemptions_notify (0023)'),
  ('staff_incident_reported', 'incidents_notify (0023)'), ('staff_breakdown_reported', 'incidents_notify (0023)'),
  ('renter_accident_instructions', 'incidents_notify (0023)'), ('owner_incident_opened', 'incidents_notify, claims_notify (0023)'),
  ('owner_incident_update', 'claims_notify (0023)'), ('renter_breakdown_help', 'app.dispatch_roadside (0023)'),
  ('staff_review_received', 'reviews_notify (0023)'), ('staff_dispute_opened', 'disputes_notify (0023)'),
  ('renter_vehicle_disabled', 'tracker_commands_notify (0023)'),
  ('staff_fleet_count_warning', 'fleet_counts_notify, vehicle_exits_notify (0023)'), ('staff_job_failed', 'job_runs_notify (0023)'),
  ('staff_statements_ready_for_approval', 'tasks_notify; reminder in app.job_notify_scheduled (0023)'),
  ('renter_pickup_details', 'field_jobs_notify; app.notify_reminders (0023)'), ('renter_return_details', 'field_jobs_notify (0023)'),
  ('renter_booking_reminder', 'app.notify_reminders (0023)'), ('renter_return_reminder', 'app.notify_reminders (0023)'),
  ('renter_late_return_first', 'app.notify_reminders (0023)'), ('renter_late_return_final', 'app.notify_reminders (0023)'),
  ('staff_late_return_alert', 'app.notify_reminders (0023)'), ('renter_offer_reminder', 'app.notify_reminders (0023)'),
  ('renter_identity_needed', 'app.notify_reminders (0023)'), ('staff_request_waiting', 'app.notify_reminders (0023)'),
  ('renter_review_request', 'app.notify_followups (0023)'), ('renter_comeback_1w', 'app.notify_followups (0023)'),
  ('renter_comeback_1m', 'app.notify_followups (0023)'), ('renter_balance_overdue', 'app.notify_daily_checks (0023)'),
  ('staff_insurer_invoice_due', 'app.notify_daily_checks (0023)'), ('staff_payouts_due', 'app.notify_payouts_due (0023)'),
  ('staff_field_jobs_today', 'app.notify_field_lists (0023)'), ('staff_field_jobs_tomorrow', 'app.notify_field_lists (0023)'),
  ('staff_weekly_summary', 'app.notify_weekly_summary (0023)'),
  ('account_sign_in_link', 'not emitted: sent by the sign-in service through its own email settings'),
  ('account_password_reset', 'not emitted: sent by the sign-in service through its own email settings'),
  ('account_security_notice', 'not emitted: sent by the sign-in service (its events are not in the database)')
) x(code, by) where notification_catalogue.code = x.code;
update notification_catalogue set emitted_by = 'app.notify_digests (0023)' where code like 'staff_digest_%';

-- ================================================================ 6. privileges
do $$
declare f record;
begin
  for f in select p.oid::regprocedure as sig from pg_proc p join pg_namespace n on n.oid = p.pronamespace
            where n.nspname = 'app' and (p.proname like 'ntf\_%' or p.proname like 'notify\_%' or p.proname in
                  ('notification_payload', 'dispatch_roadside', 'job_notify_reminders', 'job_notify_scheduled'))
  loop
    execute format('revoke all on function %s from public, anon, authenticated', f.sig);
  end loop;
end $$;
grant execute on all functions in schema app to service_role;

-- ================================================================ 7. schedule (pg_cron, 0015 pattern)
do $$
begin
  if not exists (select 1 from pg_available_extensions where name = 'pg_cron') then
    raise notice 'pg_cron is not available here: no jobs scheduled';
    return;
  end if;
  begin
    create extension if not exists pg_cron;
  exception when others then
    raise warning 'pg_cron could not be created in this database (%): no jobs scheduled', sqlerrm;
    return;
  end;
  perform cron.schedule('carmacars-notify-reminders', '*/5 * * * *', 'select app.job_notify_reminders()');
  perform cron.schedule('carmacars-notify-scheduled', '1-59/5 * * * *', 'select app.job_notify_scheduled()');
end $$;

-- ================================================================ 8. audit
do $$ begin perform app.attach_audit(); end $$;
