-- 0130: check-out and check-in by any staff, signing on the spot, the licence at the request and the offer, address
-- autofill (docs/changes/2026-10-24-handover-signing-licence.md)
--
-- The owner's requests: "I don't see a way to do checkin and checkout photos." "Need a way for admin or field staff or
-- sales staff to collect e-signatures for rental agreements on the spot." "They should be uploading their license when
-- they either request or accept an offer." Then: both check-out and check-in record the km and the fuel or charge level,
-- the actual times, late returns against the due-back time, and the late, kilometre and fuel charges go into the return
-- settlement automatically (staff waive with a reason).
--
-- 1. Settings: the licence switch (on), the selfie with it (on), the return charges written at check-in (on), and the
--    refill price per eighth of a tank used when no pump receipt is entered ($10).
-- 2. Check-out and check-in by any staff: an Admin, Fleet, Sales or Customer service opens the field checklist of 0020
--    and 0031 from the booking page. The open handover or return job of the booking is taken (or one is made) and
--    assigned to them; the field portal's reads and steps then accept them for that one job (app.handover_as, set by
--    the door for the transaction only). The database functions that complete a handover or a return are unchanged.
--    The guided shots name the plate and the fuel gauge.
-- 3. The return settlement: when the return completes, the Check-in assessment of 0020 (app.assess_check_in) writes the
--    mileage overage, the late return days and fee (grace period of the fee defaults) and the fuel or recharging lines
--    at once; a gas car with no receipt is priced at the refill price per eighth plus the markup until the receipt is
--    entered. Staff waive a line with a reason (it stays waived when the assessment runs again). An Admin corrects
--    the actual check-out or check-in time with a reason: lateness and the lines follow.
-- 4. The photo report: one read for staff and the renter (both reports, the times, late by, km, fuel, photos, damage,
--    the return charges), the renter's "Returned" email says the lateness, kilometres over and fuel difference.
-- 5. Signing on the spot: staff collect the renter's (or an additional driver's) signature on their own device. The
--    same signature record as remote signing (app.record_signature), plus who collected it, on which device, and the
--    identity check (name confirmed, original licence seen). The signed copy's record page says so.
-- 6. The licence: front, back and the selfie are uploaded from the request (the documents step opens at "requested"),
--    reused from an earlier booking while the licence is valid past the return, and required before an offer is
--    accepted (any acceptance: the renter's, staff on the renter's word, an offer made by staff) and before payment.
--    A rental added by hand is not an offer accepted and is left alone. Additional drivers upload theirs on their link.
-- No applied migration is edited.

create function pg_temp.patch_fn(p_sig regprocedure, p_old text, p_new text) returns void
language plpgsql as $$
declare
  d text := pg_get_functiondef(p_sig);
begin
  if position(p_old in d) = 0 then
    raise exception '0130: the text to change was not found in %: %', p_sig, left(p_old, 120);
  end if;
  execute replace(d, p_old, p_new);
end $$;

-- ================================================================ 1. settings
alter table program_settings
  add column if not exists booking_licence_required boolean not null default true,
  add column if not exists booking_licence_selfie_required boolean not null default true,
  add column if not exists booking_return_auto_charges boolean not null default true,
  add column if not exists statement_fuel_cents_per_eighth integer default 1000 check (statement_fuel_cents_per_eighth is null or statement_fuel_cents_per_eighth >= 0);
comment on column program_settings.booking_licence_required is 'Driver''s licence (front and back) required before an offer is accepted and before payment; uploaded from the request (0130).';
comment on column program_settings.booking_licence_selfie_required is 'The selfie with the licence is part of the licence required before acceptance (0130).';
comment on column program_settings.booking_return_auto_charges is 'At check-in, the late return, mileage overage and fuel lines are written to the return settlement at once (0130).';
comment on column program_settings.statement_fuel_cents_per_eighth is 'Refill price per eighth of a tank when no pump receipt is entered (the fuel markup is added). Empty: wait for the receipt (0130).';

-- the booking history's kinds (the 0019 pattern: rebuilt from what is there plus the new ones)
do $$
declare
  c record;
  v_kinds text[];
begin
  select conname, pg_get_constraintdef(oid) as def into strict c from pg_constraint
   where conrelid = 'public.booking_events'::regclass and contype = 'c' and pg_get_constraintdef(oid) like '%kind%';
  select array_agg(distinct m[1]) into v_kinds from regexp_matches(c.def, '[''{,]([a-z_0-9]+)(?=[''},])', 'g') m;
  select array_agg(distinct x order by x) into v_kinds
    from unnest(v_kinds || array['signed_in_person', 'handover_time_corrected', 'check_in_waived', 'licence_reused', 'handover_taken']) x;
  execute format('alter table public.booking_events drop constraint %I', c.conname);
  execute format('alter table public.booking_events add constraint booking_events_kind_check check (kind in (%s))',
                 (select string_agg(quote_literal(x), ', ') from unnest(v_kinds) x));
end $$;

-- ================================================================ 2. check-out and check-in by any staff
-- Who may check a car out or in: an Admin, Fleet, Sales or Customer service, and field staff (on their own jobs).
create or replace function app.user_may_handover(p_user uuid) returns boolean
language sql stable security definer set search_path = public, app as $$
  select app.user_is_admin(p_user) or app.user_va_has(p_user, 'fleet', 'sales', 'cs') or app.user_is_field(p_user)
$$;

-- For one transaction the door may let a staff member work one job of their own through the field portal's functions.
create or replace function app.user_is_field(p_user uuid) returns boolean
language sql stable security definer set search_path = public, app as $$
  select exists (
    select 1 from user_roles r join users u on u.id = r.user_id
      join staff_profiles sp on sp.user_id = r.user_id and sp.staff_type = 'field' and sp.is_active
     where r.user_id = p_user and r.role = 'field' and u.status = 'active')
    or (p_user is not null and coalesce(current_setting('app.handover_as', true), '') = p_user::text)
$$;

-- The job of a check-out ("pickup") or a check-in ("return") on a booking, assigned to the staff member who does it.
-- The open job of that kind is taken (a field staff member keeps theirs; anyone else takes it over, which the booking
-- history records), or a new one is made, started now. Returns the job's id.
create or replace function app.handover_open(p_user uuid, p_booking uuid, p_kind text) returns uuid
language plpgsql security definer set search_path = public, app as $$
declare
  b bookings;
  j field_jobs;
  v_kinds text[];
  v_field boolean := app.user_is_field(p_user);
  v_name text;
begin
  if not app.user_may_handover(p_user) then
    raise exception 'Only an Admin, Fleet, Sales, Customer service or field staff check a car out or in' using errcode = '42501';
  end if;
  if p_kind not in ('pickup', 'return') then raise exception 'Check out (pickup) or check in (return)' using errcode = '22023'; end if;
  select * into b from bookings where id = p_booking for update;
  if b.id is null then raise exception 'Booking not found' using errcode = 'P0002'; end if;
  if p_kind = 'pickup' and b.status <> 'confirmed' then
    raise exception 'Booking % is %: a car is checked out on a confirmed booking', b.booking_number, replace(b.status::text, '_', ' ') using errcode = '23514';
  end if;
  if p_kind = 'return' and b.status <> 'on_rent' then
    raise exception 'Booking % is %: a car is checked in while it is on rent', b.booking_number, replace(b.status::text, '_', ' ') using errcode = '23514';
  end if;
  v_kinds := case p_kind when 'pickup' then array['handover', 'delivery'] else array['return_check_in', 'pickup_from_renter'] end;
  select * into j from field_jobs x
   where x.booking_id = p_booking and x.kind = any (v_kinds) and x.status not in ('done', 'cancelled')
   order by (x.assigned_to is not distinct from p_user) desc, x.scheduled_at limit 1 for update;
  if j.id is not null and j.assigned_to is distinct from p_user then
    if v_field and not app.user_is_admin(p_user) and not app.user_va_has(p_user, 'fleet', 'sales', 'cs') then
      raise exception 'This job is assigned to someone else: ask Fleet to give it to you' using errcode = '42501';
    end if;
    select full_name into v_name from users where id = p_user;
    update field_jobs set assigned_to = p_user,
           instructions = concat_ws(E'\n', nullif(instructions, ''), format('Taken over by %s, %s.', coalesce(v_name, 'staff'), app.fmt_at(now())))
     where id = j.id returning * into j;
    perform app.log_booking_event(p_booking, 'handover_taken', b.status::text, b.status::text, null,
      format('%s taken over by %s', case p_kind when 'pickup' then 'Check-out' else 'Check-in' end, coalesce(v_name, 'staff')), p_user, 'staff',
      jsonb_build_object('field_job_id', j.id));
  end if;
  if j.id is null then
    insert into field_jobs (kind, booking_id, vehicle_id, assigned_to, dispatched_by, scheduled_at, place, status, acknowledged_at, started_at)
    values (case p_kind when 'pickup' then 'handover' else 'return_check_in' end, b.id, b.vehicle_id, p_user, p_user, now(),
            case p_kind when 'pickup' then b.pickup_place else b.return_place end, 'in_progress', now(), now())
    returning * into j;
  elsif j.status in ('scheduled', 'acknowledged') then
    update field_jobs set status = 'in_progress', acknowledged_at = coalesce(acknowledged_at, now()), started_at = coalesce(started_at, now()),
           scheduled_at = least(scheduled_at, now())
     where id = j.id returning * into j;
  elsif j.scheduled_at > now() + interval '36 hours' then
    update field_jobs set scheduled_at = now() where id = j.id;
  end if;
  return j.id;
end $$;

-- The guided shots name the plate and the fuel gauge.
update required_shots set guide = guide || ', front plate readable' where shot = 'front' and report_kind <> 'ready' and coalesce(guide, '') !~* 'plate';
update required_shots set guide = 'Rear, the licence plate readable' where shot = 'rear' and report_kind <> 'ready' and coalesce(guide, '') !~* 'plate';
update required_shots set guide = 'Ignition on. Odometer, fuel or charge level and warning lights readable'
 where shot = 'instrument_cluster' and report_kind <> 'ready' and coalesce(guide, '') !~* 'fuel';

-- ================================================================ 3. the return settlement
create table check_in_waivers (
  id             uuid primary key default gen_random_uuid(),
  booking_id     uuid not null references bookings (id) on delete cascade,
  assessment_key text not null,
  reason         text not null check (btrim(reason) <> ''),
  waived_by      uuid not null references users (id),
  waived_at      timestamptz not null default now(),
  unique (booking_id, assessment_key)
);
alter table check_in_waivers enable row level security;
create policy admin_all on check_in_waivers for all to authenticated using (app.is_admin()) with check (app.is_admin());
create trigger audit_check_in_waivers after insert or update or delete on check_in_waivers for each row execute function app.audit_row();
comment on table check_in_waivers is 'A return charge (late return, mileage overage, fuel...) waived by staff with the reason (0130). The Check-in assessment leaves a waived line out.';

-- a waived line stays out when the assessment runs again
select pg_temp.patch_fn('app.set_assessed_line(uuid, text, text, numeric, bigint, bigint, text, jsonb, uuid, uuid, uuid)'::regprocedure,
  $o$  if li.id is not null and li.statement_id is not null then return li.id; end if;$o$,
  $n$  if li.id is not null and li.statement_id is not null then return li.id; end if;
  if exists (select 1 from check_in_waivers w where w.booking_id = p_booking and w.assessment_key = p_key) then
    if li.id is not null then
      update booking_line_items set voided_at = now(), voided_by = p_by,
             void_reason = 'waived: ' || (select w.reason from check_in_waivers w where w.booking_id = p_booking and w.assessment_key = p_key)
       where id = li.id;
    end if;
    return null;
  end if;$n$);

-- a gas car returned short with no receipt yet: the refill price per eighth (Program settings) until the receipt
select pg_temp.patch_fn('app.assess_check_in(uuid, jsonb, uuid)'::regprocedure,
  $o$    elsif v_pump is null then
      v_pending := v_pending || format('fuel: %s%% short, enter the pump cost from the receipt', v_short);$o$,
  $n$    elsif v_pump is null and (app.settings()).statement_fuel_cents_per_eighth is not null then
      v_pump := ceil(v_short / 12.5)::integer * (app.settings()).statement_fuel_cents_per_eighth;
    elsif v_pump is null then
      v_pending := v_pending || format('fuel: %s%% short, enter the pump cost from the receipt', v_short);$n$);

-- The return completes, then the settlement lines are written (never in the way of the return: a missing fee default
-- leaves the lines to Finance, as before).
alter function app.complete_return(uuid, uuid, jsonb, uuid, timestamptz) rename to complete_return_pre0130;
create or replace function app.complete_return(p_booking uuid, p_by uuid, p_report jsonb default '{}'::jsonb,
    p_job uuid default null, p_now timestamptz default now())
returns jsonb language plpgsql security definer set search_path = public, app as $$
declare
  v_out jsonb := app.complete_return_pre0130(p_booking, p_by, p_report, p_job, p_now);
begin
  perform app.return_auto_charges(p_booking);
  return v_out;
end $$;

create or replace function app.return_auto_charges(p_booking uuid) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  b bookings;
  v jsonb;
begin
  select * into b from bookings where id = p_booking;
  if b.id is null or b.booking_type = 'owner' or b.status not in ('returned', 'closed') or not coalesce((app.settings()).booking_return_auto_charges, true) then
    return null;
  end if;
  begin
    v := app.assess_check_in(p_booking, '{}'::jsonb, null);
  exception when others then
    raise warning 'return charges of % left to Finance: %', b.booking_number, sqlerrm;
    return null;
  end;
  return v;
end $$;

-- Staff waive one return charge with the reason (an Admin, Finance or Fleet).
create or replace function app.check_in_waive(p_by uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  b bookings;
  li booking_line_items;
  v_key text := nullif(btrim(coalesce(p ->> 'key', '')), '');
  v_reason text := nullif(btrim(coalesce(p ->> 'reason', '')), '');
begin
  if not (app.user_is_admin(p_by) or app.user_va_has(p_by, 'finance', 'fleet')) then
    raise exception 'An Admin, Finance or Fleet waives a return charge' using errcode = '42501';
  end if;
  select * into b from bookings where id = (p ->> 'booking')::uuid or booking_number = p ->> 'booking' limit 1;
  if b.id is null then raise exception 'Booking not found' using errcode = 'P0002'; end if;
  if v_key is null or v_key !~ '^(mileage_overage|late_return_extra_days|late_return_fee|fuel|recharging|fuel_service_fee|cleaning:[a-z]+|lost_key[a-z_:]*)$' then
    raise exception 'Choose the charge to waive' using errcode = '22023';
  end if;
  if v_reason is null or length(v_reason) < 3 then raise exception 'Say why the charge is waived' using errcode = '22023'; end if;
  select * into li from booking_line_items where booking_id = b.id and assessment_key = v_key and voided_at is null order by created_at limit 1;
  if li.statement_id is not null then
    raise exception 'This charge is already on a statement: credit it on a new statement instead' using errcode = '23514';
  end if;
  insert into check_in_waivers (booking_id, assessment_key, reason, waived_by) values (b.id, v_key, left(v_reason, 500), p_by)
  on conflict (booking_id, assessment_key) do update set reason = excluded.reason, waived_by = excluded.waived_by, waived_at = now();
  if li.id is not null then
    update booking_line_items set voided_at = now(), voided_by = p_by, void_reason = 'waived: ' || left(v_reason, 500) where id = li.id;
  end if;
  perform app.log_booking_event(b.id, 'check_in_waived', b.status::text, b.status::text, null, format('%s waived: %s', replace(v_key, '_', ' '), v_reason), p_by, 'staff',
    jsonb_build_object('assessment_key', v_key, 'line_id', li.id, 'amount_cents', li.amount_cents));
  return jsonb_build_object('waived', v_key, 'amount_cents', coalesce(li.amount_cents, 0));
end $$;

-- An Admin corrects the actual check-out or check-in time, with the reason. Lateness, the late return lines and the
-- condition report's time follow.
create or replace function app.handover_time_correct(p_by uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  b bookings;
  t record;
  l record;
  v_which text := p ->> 'which';
  v_at timestamptz := (p ->> 'at')::timestamptz;
  v_reason text := nullif(btrim(coalesce(p ->> 'reason', '')), '');
  v_old timestamptz;
  v_minutes integer;
begin
  perform app.assert_admin(p_by);
  select * into b from bookings where id = (p ->> 'booking')::uuid or booking_number = p ->> 'booking' limit 1 for update;
  if b.id is null then raise exception 'Booking not found' using errcode = 'P0002'; end if;
  if v_which not in ('out', 'in') then raise exception 'Correct the check-out or the check-in time' using errcode = '22023'; end if;
  if v_at is null or v_at > now() + interval '5 minutes' then raise exception 'Give the actual time (not in the future)' using errcode = '22023'; end if;
  if v_reason is null or length(v_reason) < 3 then raise exception 'Say why the time is corrected' using errcode = '22023'; end if;
  if v_which = 'out' then
    if b.handed_over_at is null then raise exception 'The car has not been checked out' using errcode = '23514'; end if;
    if b.checked_in_at is not null and v_at >= b.checked_in_at then raise exception 'The check-out must be before the check-in' using errcode = '22023'; end if;
    v_old := b.handed_over_at;
    update bookings set handed_over_at = v_at where id = b.id;
    update condition_reports set performed_at = v_at where booking_id = b.id and kind = 'pickup' and completed_at is not null;
  else
    if b.checked_in_at is null then raise exception 'The car has not been checked in' using errcode = '23514'; end if;
    if v_at < coalesce(b.handed_over_at, b.pickup_at) then raise exception 'The check-in cannot be before the check-out' using errcode = '22023'; end if;
    v_old := b.checked_in_at;
    v_minutes := greatest(0, floor(extract(epoch from (v_at - b.return_at)) / 60)::integer);
    select * into t from app.booking_fee_term(b.id, 'late_return_fee');
    select * into l from public.calc_late_return(v_minutes, b.daily_rate_cents, coalesce(t.amount_cents, 0), coalesce(t.percent_bps, 0), coalesce(t.grace_minutes, 0));
    update bookings set checked_in_at = v_at, minutes_late = v_minutes, extra_days = l.extra_days,
           end_reason = case when end_reason in ('late_return', 'early_return', 'normal') or end_reason is null then
                               case when l.extra_days > 0 then 'late_return'
                                    when v_at < b.return_at - make_interval(mins => (app.settings()).early_return_minutes) then 'early_return' else 'normal' end
                             else end_reason end
     where id = b.id;
    update condition_reports set performed_at = v_at where booking_id = b.id and kind = 'return' and completed_at is not null;
    perform app.return_auto_charges(b.id);
  end if;
  perform app.log_booking_event(b.id, 'handover_time_corrected', b.status::text, b.status::text, null,
    format('%s time corrected from %s to %s: %s', case v_which when 'out' then 'Check-out' else 'Check-in' end, app.fmt_at(v_old), app.fmt_at(v_at), v_reason),
    p_by, 'staff', jsonb_build_object('which', v_which, 'from', v_old, 'to', v_at, 'reason', v_reason));
  return jsonb_build_object('which', v_which, 'at', v_at, 'minutes_late', (select minutes_late from bookings where id = b.id));
end $$;

-- Today's check-outs and check-ins (and the cars overdue), for the staff Today lists.
create or replace function app.handovers_today(p_user uuid) returns jsonb
language sql stable security definer set search_path = public, app as $$
  select coalesce(jsonb_agg(x order by x ->> 'at'), '[]'::jsonb) from (
    select jsonb_build_object('booking_number', b.booking_number, 'kind', 'pickup', 'at', b.pickup_at, 'vehicle', app.vehicle_name(b.vehicle_id),
                              'renter', (select r.legal_name from renters r where r.id = b.renter_id), 'late', false) x
      from bookings b where b.status = 'confirmed' and app.local_date(b.pickup_at) <= app.today() and b.pickup_at > now() - interval '2 days'
    union all
    select jsonb_build_object('booking_number', b.booking_number, 'kind', 'return', 'at', b.return_at, 'vehicle', app.vehicle_name(b.vehicle_id),
                              'renter', (select r.legal_name from renters r where r.id = b.renter_id), 'late', b.return_at < now(),
                              'minutes_late', greatest(0, floor(extract(epoch from (now() - b.return_at)) / 60))::integer)
      from bookings b where b.status = 'on_rent' and app.local_date(b.return_at) <= app.today()) t
   where app.user_may_handover(p_user)
$$;

-- ================================================================ 4. the photo report
-- Both reports of a booking, with the times, late by, kilometres, fuel, photos (bucket and key: the server signs them),
-- damage and the return charges. For staff (any who may check a car out or in) and, through the server, the renter.
create or replace function app.handover_report(p_booking uuid) returns jsonb
language sql stable security definer set search_path = public, app as $$
  select jsonb_build_object(
    'booking_id', b.id, 'booking_number', b.booking_number, 'status', b.status, 'vehicle', app.vehicle_name(b.vehicle_id),
    'plate', (select v.plate from vehicles v where v.id = b.vehicle_id),
    'pickup_at', b.pickup_at, 'return_at', b.return_at, 'handed_over_at', b.handed_over_at, 'checked_in_at', b.checked_in_at,
    'minutes_late', case when b.checked_in_at is not null then coalesce(b.minutes_late, 0)
                         when b.status = 'on_rent' and now() > b.return_at then floor(extract(epoch from (now() - b.return_at)) / 60)::integer else 0 end,
    'overdue', b.status = 'on_rent' and now() > b.return_at,
    'grace_minutes', (select t.grace_minutes from app.booking_fee_term(b.id, 'late_return_fee') t),
    'extra_days', b.extra_days,
    'km_out', b.odometer_out_km, 'km_in', b.odometer_in_km, 'km_driven', app.booking_km_driven(b.id), 'km_allowance', b.km_allowance_total,
    'km_over', greatest(coalesce(app.booking_km_driven(b.id), 0) - coalesce(b.km_allowance_total, 0), 0),
    'overage_cents_per_km', b.overage_cents_per_km,
    'fuel_out_pct', b.fuel_out_pct, 'fuel_in_pct', b.fuel_in_pct,
    'fuel_short_pct', greatest(coalesce(b.fuel_out_pct, 0) - coalesce(b.fuel_in_pct, b.fuel_out_pct, 0), 0),
    'electric', (select v.fuel::text = 'electric' from vehicles v where v.id = b.vehicle_id),
    'reports', coalesce((select jsonb_agg(jsonb_build_object(
        'id', c.id, 'kind', c.kind, 'performed_at', c.performed_at, 'completed_at', c.completed_at,
        'performed_by_name', (select u.full_name from users u where u.id = c.performed_by), 'odometer_km', c.odometer_km, 'fuel_pct', c.fuel_pct,
        'keys_count', c.keys_count, 'cleanliness', c.cleanliness, 'notes', c.notes, 'unattended', c.unattended,
        'renter_signed_at', c.renter_signed_at, 'staff_signed_at', c.staff_signed_at, 'renter_declined_to_sign', c.renter_declined_to_sign,
        'photos', coalesce((select jsonb_agg(jsonb_build_object('seq', p.seq, 'shot', p.shot, 'bucket', p.storage_bucket, 'path', p.storage_path,
                                     'taken_at', coalesce(p.device_taken_at, p.taken_at), 'latitude', p.latitude, 'longitude', p.longitude,
                                     'damage_label', (select d.label from condition_report_damages d where d.id = p.damage_id)) order by p.seq)
                             from condition_report_photos p where p.condition_report_id = c.id and p.shot <> 'licence'), '[]'::jsonb),
        'damages', coalesce((select jsonb_agg(jsonb_build_object('label', d.label, 'location', d.location, 'description', d.description, 'kind', d.kind,
                                     'size_cm', d.size_cm, 'is_new', d.is_new, 'found_later', d.found_later, 'status_vs_pickup', d.status_vs_pickup) order by d.label)
                              from condition_report_damages d where d.condition_report_id = c.id), '[]'::jsonb))
        order by case c.kind when 'pickup' then 1 when 'swap_out' then 2 when 'swap_in' then 3 else 4 end)
       from condition_reports c where c.booking_id = b.id and c.kind in ('pickup', 'return', 'swap_out', 'swap_in') and c.completed_at is not null), '[]'::jsonb),
    'charges', coalesce((select jsonb_agg(jsonb_build_object('key', li.assessment_key, 'label', li.description, 'amount_cents', li.amount_cents,
                                 'hst_cents', li.hst_cents, 'on_statement', li.statement_id is not null) order by li.created_at)
                         from booking_line_items li where li.booking_id = b.id and li.voided_at is null and li.assessment_key is not null
                           and li.assessment_key !~ '^damage'), '[]'::jsonb),
    'waivers', coalesce((select jsonb_agg(jsonb_build_object('key', w.assessment_key, 'reason', w.reason, 'by', (select u.full_name from users u where u.id = w.waived_by),
                                 'at', w.waived_at) order by w.waived_at) from check_in_waivers w where w.booking_id = b.id), '[]'::jsonb))
    from bookings b where b.id = p_booking
$$;

create or replace function public.server_renter_handover_report(p_booking uuid, p_by uuid) returns jsonb
language plpgsql stable security definer set search_path = public, app as $$
begin
  perform app.assert_booking_renter(p_booking, p_by);
  return app.handover_report(p_booking) - 'waivers';
end $$;

-- the renter's "Returned" email: the lateness, kilometres over and the fuel difference, beside the new damage
alter function app.notification_payload(text, app_events, jsonb) rename to ntf_payload_pre0130;
create or replace function app.notification_payload(p_code text, p_event app_events, p_to jsonb) returns jsonb
language plpgsql stable security definer set search_path = public, app as $$
declare
  x jsonb := app.ntf_payload_pre0130(p_code, p_event, p_to);
  r jsonb;
  v_parts text[] := '{}';
  v_new integer;
begin
  if p_code <> 'renter_return_complete' or p_event.entity <> 'booking' then return x; end if;
  r := app.handover_report(p_event.entity_id);
  if r is null then return x; end if;
  if coalesce((r ->> 'minutes_late')::integer, 0) > 0 then
    v_parts := v_parts || format('Returned %s late', app.fmt_duration_minutes((r ->> 'minutes_late')::integer));
  end if;
  if coalesce((r ->> 'km_over')::integer, 0) > 0 then v_parts := v_parts || format('%s km over the included distance', r ->> 'km_over'); end if;
  if coalesce((r ->> 'fuel_short_pct')::integer, 0) > 0 then
    v_parts := v_parts || format('%s %s%% lower than at pickup', case when (r ->> 'electric')::boolean then 'Charge' else 'Fuel' end, r ->> 'fuel_short_pct');
  end if;
  select count(*) into v_new from condition_report_damages dm join condition_reports cr on cr.id = dm.condition_report_id
   where cr.booking_id = p_event.entity_id and cr.kind = 'return' and dm.is_new;
  if v_new > 0 then v_parts := v_parts || format('%s new damage item(s) noted at return', v_new); end if;
  return x || jsonb_build_object('return_findings', case when cardinality(v_parts) = 0 then 'Nothing to report' else array_to_string(v_parts, '. ') end);
end $$;

create or replace function app.fmt_duration_minutes(p integer) returns text
language sql immutable as $$
  select case when p is null or p <= 0 then '0 min'
              when p < 60 then p || ' min'
              when p < 1440 then (p / 60) || ' h' || case when p % 60 > 0 then ' ' || (p % 60) || ' min' else '' end
              else (p / 1440) || ' d' || case when (p % 1440) / 60 > 0 then ' ' || ((p % 1440) / 60) || ' h' else '' end end
$$;

-- ================================================================ 5. signing on the spot
alter table signature_records
  add column if not exists collected_in_person_by uuid references users (id),
  add column if not exists collected_device text,
  add column if not exists identity_check jsonb;
comment on column signature_records.collected_in_person_by is 'The staff member who handed their device to the signer (0130): signed in person.';

-- a signature record is append-only: signed in person is written with it, from the transaction's own setting
create or replace function app.signature_in_person_fill() returns trigger
language plpgsql security definer set search_path = public, app as $$
declare
  v jsonb := nullif(current_setting('app.in_person', true), '')::jsonb;
begin
  if v is not null then
    new.collected_in_person_by := (v ->> 'by')::uuid;
    new.collected_device := left(v ->> 'device', 300);
    new.identity_check := v -> 'identity';
  end if;
  return new;
end $$;
create trigger signature_records_in_person before insert on signature_records for each row execute function app.signature_in_person_fill();

-- What the hand-over screen needs: the open agreement, its SHA-256 and the second agreement's, each signer who has not
-- signed (the renter, the additional drivers), and their licence on file.
create or replace function app.in_person_signing(p_by uuid, p_booking uuid) returns jsonb
language plpgsql stable security definer set search_path = public, app as $$
declare
  b bookings;
  a rental_agreements;
begin
  if not app.user_may_handover(p_by) then raise exception 'Not permitted' using errcode = '42501'; end if;
  select * into b from bookings where id = p_booking;
  if b.id is null then raise exception 'Booking not found' using errcode = 'P0002'; end if;
  select * into a from rental_agreements where booking_id = b.id and status in ('open', 'signed', 'completed') order by opened_at desc limit 1;
  return jsonb_build_object(
    'booking_id', b.id, 'booking_number', b.booking_number, 'status', b.status, 'renter_user_id', (select r.user_id from renters r where r.id = b.renter_id),
    'renter_mobile', (select coalesce(r.mobile, u.phone) from renters r left join users u on u.id = r.user_id where r.id = b.renter_id),
    'renter_email', (select coalesce(r.email, u.email) from renters r left join users u on u.id = r.user_id where r.id = b.renter_id),
    'added', app.booking_added_live(b), 'link_due', app.booking_link_due(b),
    'agreement', case when a.id is not null then jsonb_build_object('id', a.id, 'status', a.status, 'document_id', a.document_id, 'document_sha256', a.document_sha256,
                    'agreement_number', a.agreement_number) end,
    'companion', (select jsonb_build_object('status', c.status, 'document_id', c.document_id, 'document_sha256', c.document_sha256)
                    from rental_agreement_companions c where c.rental_agreement_id = a.id and c.status <> 'superseded' limit 1),
    'signers', coalesce((select jsonb_agg(jsonb_build_object('id', g.id, 'role', g.signer_role, 'name', g.signer_name, 'signed_at', g.signed_at,
                     'driver_id', g.driver_id, 'in_person', (select s.collected_in_person_by is not null from signature_records s where s.id = g.signature_record_id),
                     'licence', app.licence_status(b.id, g.driver_id)) order by g.signer_role desc, g.signer_name)
                   from rental_agreement_signers g where g.agreement_id = a.id and g.signer_role in ('renter', 'additional_driver')), '[]'::jsonb));
end $$;

-- The signer signs on the staff member's device: the same record as remote signing (app.record_signature, the second
-- agreement's SHA-256 checked for the renter as 0127 does), then who collected it, the device and the identity check.
-- p: booking, signer, typed_name or drawn (the stored PNG's key), sha, companion_sha, consent_text, consents, device,
-- ip, user_agent, identity {name_confirmed, licence_seen}.
create or replace function app.sign_in_person(p_by uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  b bookings;
  a rental_agreements;
  g rental_agreement_signers;
  c rental_agreement_companions;
  v_rec uuid;
  v_id jsonb := coalesce(p -> 'identity', '{}'::jsonb);
  v_name text;
begin
  if not app.user_may_handover(p_by) then
    raise exception 'Only an Admin, Fleet, Sales, Customer service or field staff collect a signature in person' using errcode = '42501';
  end if;
  select * into b from bookings where id = (p ->> 'booking')::uuid;
  if b.id is null then raise exception 'Booking not found' using errcode = 'P0002'; end if;
  if app.user_is_field(p_by) and not (app.user_is_admin(p_by) or app.user_va_has(p_by, 'fleet', 'sales', 'cs'))
     and not exists (select 1 from field_jobs j where j.booking_id = b.id and j.assigned_to = p_by and j.status <> 'cancelled') then
    raise exception 'Collect a signature on a booking of one of your jobs' using errcode = '42501';
  end if;
  select * into g from rental_agreement_signers where id = (p ->> 'signer')::uuid;
  select * into a from rental_agreements where id = g.agreement_id;
  if g.id is null or a.booking_id is distinct from b.id or g.signer_role not in ('renter', 'additional_driver') then
    raise exception 'That signer is not on this booking''s agreement' using errcode = '22023';
  end if;
  if not coalesce((v_id ->> 'name_confirmed')::boolean, false) or not coalesce((v_id ->> 'licence_seen')::boolean, false) then
    raise exception 'Confirm the signer''s name and that you saw their original licence' using errcode = '23514';
  end if;
  if g.signer_role = 'renter' and a.status = 'open' then
    select * into c from rental_agreement_companions where rental_agreement_id = a.id and status = 'open' for update;
    if c.id is not null and lower(btrim(coalesce(p ->> 'companion_sha', ''))) is distinct from c.document_sha256 then
      raise exception 'The Blind Spot rental agreement changed since this page was opened. Reload the page and sign again' using errcode = '40001';
    end if;
  end if;
  perform set_config('app.in_person', jsonb_build_object('by', p_by, 'device', coalesce(nullif(btrim(p ->> 'device'), ''), p ->> 'user_agent'),
    'identity', jsonb_build_object('name_confirmed', true, 'licence_seen', true, 'licence_on_file', (app.licence_status(b.id, g.driver_id) ->> 'complete')::boolean))::text, true);
  v_rec := app.record_signature(a.signature_request_id, g.id, p ->> 'typed_name', p ->> 'drawn', nullif(p ->> 'ip', '')::inet, p ->> 'user_agent',
                                p ->> 'consent_text', p ->> 'sha', p -> 'consents');
  perform set_config('app.in_person', '', true);
  if c.id is not null then
    update rental_agreement_companions set status = 'signed', renter_signed_at = now(), renter_record_id = v_rec where id = c.id;
  end if;
  select full_name into v_name from users where id = p_by;
  perform app.log_booking_event(b.id, 'signed_in_person', b.status::text, b.status::text, null,
    format('%s signed in person, collected by %s', g.signer_name, coalesce(v_name, 'staff')), p_by, 'staff',
    jsonb_build_object('signer_id', g.id, 'signer_role', g.signer_role, 'signature_record_id', v_rec));
  return jsonb_build_object('signature_record_id', v_rec, 'signer_role', g.signer_role, 'agreement_status', (select status from rental_agreements where id = a.id));
end $$;

-- the signed copy's record page: "signed in person, collected by <staff> on <device>"
create or replace function app.signature_in_person_line(p_record uuid) returns text
language sql stable security definer set search_path = public, app as $$
  select case when s.collected_in_person_by is not null then
           format('signed in person on a CarmaCars device, collected by %s%s; identity checked (name confirmed, original licence seen)',
                  (select u.full_name from users u where u.id = s.collected_in_person_by), coalesce('; device ' || s.collected_device, '')) end
    from signature_records s where s.id = p_record
$$;

-- Staff send the renter the signing link for their own phone: by email (the "Sign your rental agreement" email of 0019,
-- again) or by text from the CarmaCars number (queued for the phone job; an opted-out number is skipped with the reason).
create or replace function app.signing_link_send(p_by uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  b bookings;
  a rental_agreements;
  g rental_agreement_signers;
  r renters;
  v_channel text := coalesce(p ->> 'channel', 'email');
  v_mobile text;
  v_link text;
  o phone_outbox;
  v_ev bigint;
begin
  if not app.user_may_handover(p_by) then raise exception 'Not permitted' using errcode = '42501'; end if;
  select * into b from bookings where id = (p ->> 'booking')::uuid;
  if b.id is null then raise exception 'Booking not found' using errcode = 'P0002'; end if;
  select * into a from rental_agreements where booking_id = b.id and status = 'open' order by opened_at desc limit 1;
  select * into g from rental_agreement_signers where agreement_id = a.id and signer_role = 'renter' and signed_at is null;
  if g.id is null then raise exception 'There is no rental agreement waiting for the renter''s signature' using errcode = '23514'; end if;
  select * into r from renters where id = b.renter_id;
  if v_channel = 'text' then
    v_mobile := coalesce(r.mobile, (select u.phone from users u where u.id = r.user_id));
    if v_mobile is null then raise exception 'The renter has no mobile number on file' using errcode = '23514'; end if;
    v_link := rtrim(coalesce((select s.site_url from site_settings s limit 1), 'https://carmacars.ca'), '/') || '/account/bookings/' || b.booking_number || '/sign';
    o := app.phone_outbox_put(v_mobile, format('CarmaCars: sign your rental agreement for booking %s here: %s', b.booking_number, v_link),
                              'staff', b.id, r.id, null, null, null, now(), 'queued', p_by);
    return jsonb_build_object('channel', 'text', 'to', v_mobile, 'status', o.status);
  end if;
  v_ev := app.emit_event('renter_agreement_ready', 'rental_agreement', a.id,
    jsonb_build_object('booking_id', b.id, 'signer_id', g.id, 'signer_role', 'renter', 'signer_name', g.signer_name, 'signer_email', g.signer_email,
                       'signer_user_id', g.user_id, 'resent_by_staff', true),
    'renter_agreement_ready:' || a.id || ':' || g.id || ':staff:' || to_char(now(), 'YYYYMMDDHH24MI'));
  return jsonb_build_object('channel', 'email', 'to', coalesce(g.signer_email, r.email), 'sent', v_ev is not null);
end $$;

-- the lines of one signature request's records signed in person, for the signed copy's record page
create or replace function public.server_in_person_lines(p_request uuid) returns jsonb
language sql stable security definer set search_path = public, app as $$
  select coalesce(jsonb_agg(jsonb_build_object('signer_role', s.signer_role, 'signer_name', s.signer_name, 'line', app.signature_in_person_line(s.id))
                            order by s.signed_at), '[]'::jsonb)
    from signature_records s where s.signature_request_id = p_request and s.collected_in_person_by is not null and s.status = 'signed'
$$;

-- ================================================================ 6. the licence
-- The licence of one driver on one booking: each image's state here, its expiry against the return, and what is missing.
create or replace function app.licence_status(p_booking uuid, p_driver uuid) returns jsonb
language plpgsql stable security definer set search_path = public, app as $$
declare
  b bookings;
  dv drivers;
  v_selfie boolean := coalesce((app.settings()).booking_licence_selfie_required, true);
  v_state jsonb := '{}'::jsonb;
  v_missing text[] := '{}';
  k text;
  s text;
  v_expiry date;
begin
  select * into b from bookings where id = p_booking;
  select * into dv from drivers where id = p_driver;
  if b.id is null or dv.id is null then return jsonb_build_object('complete', false, 'missing', jsonb_build_array('driver')); end if;
  foreach k in array array['licence_front', 'licence_back', 'selfie'] loop
    select u.status into s from verification_uploads u where u.booking_id = b.id and u.driver_id = dv.id and u.kind = k
       and u.status in ('submitted', 'approved', 'rejected') order by u.uploaded_at desc limit 1;
    v_state := v_state || jsonb_build_object(k, s);
    if (s is null or s = 'rejected') and (k <> 'selfie' or v_selfie) then
      v_missing := v_missing || case k when 'licence_front' then 'licence front' when 'licence_back' then 'licence back' else 'selfie with the licence' end;
    end if;
  end loop;
  v_expiry := coalesce((select bd.licence_expiry from booking_drivers bd where bd.booking_id = b.id and bd.driver_id = dv.id), dv.licence_expiry);
  if v_expiry is null then v_missing := v_missing || 'licence expiry date'::text;
  elsif v_expiry <= app.local_date(b.return_at) then v_missing := v_missing || 'a licence valid after the return date'::text; end if;
  return v_state || jsonb_build_object('expiry', v_expiry, 'expiry_ok', v_expiry is not null and v_expiry > app.local_date(b.return_at),
                                       'missing', to_jsonb(v_missing), 'complete', cardinality(v_missing) = 0,
                                       'verified', exists (select 1 from booking_drivers bd where bd.booking_id = b.id and bd.driver_id = dv.id and bd.identity_verified_on is not null));
end $$;

-- An earlier booking's licence images of the same driver, reused while they are kept and the licence is valid past the
-- return: the same files (their keep-until moves to this rental's), the same staff decision. Returns the images reused.
create or replace function app.licence_reuse(p_booking uuid, p_driver uuid, p_by uuid default null) returns integer
language plpgsql security definer set search_path = public, app as $$
declare
  b bookings;
  dv drivers;
  src identity_verifications;
  v_iv uuid;
  v_purge timestamptz;
  v_n integer := 0;
  u verification_uploads;
  v_all_approved boolean;
begin
  select * into b from bookings where id = p_booking;
  select * into dv from drivers where id = p_driver;
  if b.id is null or dv.id is null then return 0; end if;
  if exists (select 1 from verification_uploads x where x.booking_id = b.id and x.driver_id = dv.id and x.kind in ('licence_front', 'licence_back')
               and x.status in ('submitted', 'approved')) then
    return 0;
  end if;
  if coalesce((select bd.licence_expiry from booking_drivers bd where bd.booking_id = b.id and bd.driver_id = dv.id), dv.licence_expiry) is null
     or coalesce((select bd.licence_expiry from booking_drivers bd where bd.booking_id = b.id and bd.driver_id = dv.id), dv.licence_expiry) <= app.local_date(b.return_at) then
    return 0;
  end if;
  -- the newest earlier set with both sides, not failed, its files still kept
  select iv.* into src from identity_verifications iv
   where iv.driver_id = dv.id and iv.booking_id is distinct from b.id and iv.method = 'staff_review' and iv.purged_at is null
     and iv.status in ('verified', 'pending') and iv.id_front_document_id is not null and iv.id_back_document_id is not null
     and not exists (select 1 from documents d where d.id in (iv.id_front_document_id, iv.id_back_document_id) and d.purged_at is not null)
   order by (iv.status = 'verified') desc, iv.created_at desc limit 1;
  if src.id is null then return 0; end if;
  v_purge := greatest(b.return_at, now()) + make_interval(days => (app.settings()).retention_id_face_days);
  insert into identity_verifications (driver_id, booking_id, method, status, id_front_document_id, id_back_document_id, face_document_id,
                                      checks, verified_by, verified_at, purge_after)
  values (dv.id, b.id, 'staff_review', src.status, src.id_front_document_id, src.id_back_document_id, src.face_document_id,
          coalesce(src.checks, '{}'::jsonb) || jsonb_build_object('reused_from', src.id), src.verified_by, src.verified_at, v_purge)
  returning id into v_iv;
  for u in select x.* from verification_uploads x where x.identity_verification_id = src.id and x.status in ('submitted', 'approved')
              and x.kind in ('licence_front', 'licence_back', 'selfie') loop
    insert into verification_uploads (booking_id, driver_id, kind, document_id, status, identity_verification_id, uploaded_by, uploaded_at, reviewed_by, reviewed_at)
    values (b.id, dv.id, u.kind, u.document_id, u.status, v_iv, coalesce(p_by, u.uploaded_by), now(), u.reviewed_by, u.reviewed_at)
    on conflict do nothing;
    v_n := v_n + 1;
  end loop;
  update documents set purge_after = greatest(coalesce(purge_after, v_purge), v_purge)
   where id in (src.id_front_document_id, src.id_back_document_id, src.face_document_id);
  update identity_verifications set purge_after = greatest(coalesce(purge_after, v_purge), v_purge) where id = src.id;
  select count(distinct x.kind) = 3 and bool_and(x.status = 'approved') into v_all_approved
    from verification_uploads x where x.booking_id = b.id and x.driver_id = dv.id and x.status in ('submitted', 'approved');
  if v_all_approved and src.status = 'verified' then
    update booking_drivers set identity_verification_id = v_iv, identity_method = 'staff_review', identity_verified_on = app.today()
     where booking_id = b.id and driver_id = dv.id;
  end if;
  if v_n > 0 then
    perform app.log_booking_event(b.id, 'licence_reused', b.status::text, b.status::text, null,
      format('Licence of %s reused from an earlier booking (%s)', coalesce((select bd.full_name from booking_drivers bd where bd.booking_id = b.id and bd.driver_id = dv.id), 'the driver'),
             case src.status when 'verified' then 'verified' else 'in review' end),
      p_by, case when p_by is null then 'system' else null end, jsonb_build_object('driver_id', dv.id, 'from_verification', src.id));
  end if;
  return v_n;
end $$;

-- What is missing before an offer of this booking is accepted or paid: the renter's licence (the switch in Program
-- settings, on by default). An empty array when nothing is. Reuses an earlier booking's licence first.
create or replace function app.licence_gate(p_booking uuid) returns text[]
language plpgsql security definer set search_path = public, app as $$
declare
  b bookings;
  v_driver uuid;
begin
  select * into b from bookings where id = p_booking;
  if b.id is null or b.booking_type = 'owner' or coalesce(b.added_by_staff, false) or not coalesce((app.settings()).booking_licence_required, true) then
    return '{}';
  end if;
  select bd.driver_id into v_driver from booking_drivers bd where bd.booking_id = b.id and bd.role = 'renter' limit 1;
  if v_driver is null then return '{}'; end if;
  perform app.licence_reuse(b.id, v_driver, null);
  return array(select jsonb_array_elements_text(app.licence_status(b.id, v_driver) -> 'missing'));
end $$;

-- the documents step opens at the request: licence images while requested or offered too (the coverage proof keeps 0072's rule)
select pg_temp.patch_fn('app.register_verification_upload(uuid, uuid, text, uuid, text, text, text, jsonb, text)'::regprocedure,
  $o$  if not app.booking_docs_open(b) then
    raise exception 'Booking % is %: documents are uploaded once the offer is approved', b.booking_number, b.status using errcode = '23514';
  end if;$o$,
  $n$  if not (app.booking_docs_open(b) or (v_id_kind and b.status in ('requested', 'offered'))) then
    raise exception 'Booking % is %: documents are uploaded once the offer is approved', b.booking_number, b.status using errcode = '23514';
  end if;$n$);

-- Any acceptance of an offer (the renter, staff on the renter's word, an offer made by staff) needs the licence.
alter function app.approve_offer(uuid, integer, uuid, timestamptz) rename to approve_offer_pre0130;
create or replace function app.approve_offer(p_booking uuid, p_version integer, p_by uuid, p_now timestamptz default now())
returns void language plpgsql security definer set search_path = public, app as $$
declare
  v_missing text[] := app.licence_gate(p_booking);
begin
  if cardinality(v_missing) > 0 then
    raise exception 'Upload the driver''s licence before accepting the offer: % still needed', array_to_string(v_missing, ', ') using errcode = '23514';
  end if;
  perform app.approve_offer_pre0130(p_booking, p_version, p_by, p_now);
end $$;

-- The payment facts carry it too: no payment while the licence is missing.
alter function public.server_booking_payment_facts(uuid) rename to server_booking_payment_facts_pre0130;
alter function public.server_booking_payment_facts_pre0130(uuid) set schema app;
create or replace function public.server_booking_payment_facts(p_booking uuid) returns jsonb
language plpgsql security definer set search_path = public, app as $$
begin
  return app.server_booking_payment_facts_pre0130(p_booking) || jsonb_build_object('licence_missing', to_jsonb(app.licence_gate(p_booking)));
end $$;

-- the renter's licence status on their booking (the request, the offer and the verify pages)
create or replace function public.server_licence_state(p_booking uuid, p_by uuid) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  b bookings;
begin
  perform app.assert_booking_renter(p_booking, p_by);
  select * into b from bookings where id = p_booking;
  perform app.licence_gate(p_booking);
  return jsonb_build_object('required', coalesce((app.settings()).booking_licence_required, true) and b.booking_type <> 'owner' and not coalesce(b.added_by_staff, false),
    'selfie_required', coalesce((app.settings()).booking_licence_selfie_required, true),
    'drivers', coalesce((select jsonb_agg(jsonb_build_object('driver_id', bd.driver_id, 'role', bd.role, 'name', bd.full_name,
                                 'licence', app.licence_status(b.id, bd.driver_id)) order by bd.role desc, bd.full_name)
                         from booking_drivers bd where bd.booking_id = b.id), '[]'::jsonb));
end $$;

-- An additional driver uploads their licence on their own signing link (no account): the server checked the link.
create or replace function public.server_driver_register_upload(p_signer uuid, p_kind text, p_storage_path text, p_sha256 text, p_mime_type text) returns uuid
language plpgsql security definer set search_path = public, app as $$
declare
  g rental_agreement_signers;
  a rental_agreements;
begin
  select * into g from rental_agreement_signers where id = p_signer;
  if g.id is null or g.signer_role <> 'additional_driver' or g.driver_id is null then raise exception 'This link is for an additional driver' using errcode = '42501'; end if;
  if p_kind not in ('licence_front', 'licence_back', 'selfie') then raise exception 'Upload the licence or the selfie' using errcode = '22023'; end if;
  select * into a from rental_agreements where id = g.agreement_id;
  if not app.rate_limit('upload:signer:' || p_signer, 30, interval '1 hour') then
    raise exception 'Too many uploads in the last hour. Try again later.' using errcode = '54000';
  end if;
  return app.register_verification_upload(a.booking_id, null, p_kind, g.driver_id, p_storage_path, p_sha256, p_mime_type, null, 'identity');
end $$;

-- ... and their licence details (number, issuer, expiry), kept on their driver record and the booking's copy
create or replace function public.server_driver_save_licence(p_signer uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  g rental_agreement_signers;
  v_number text := upper(regexp_replace(coalesce(p ->> 'licence_number', ''), '\s', '', 'g'));
  v_issuer text := nullif(btrim(coalesce(p ->> 'licence_issuer', '')), '');
  v_expiry date := nullif(p ->> 'licence_expiry', '')::date;
  v_return date;
begin
  select * into g from rental_agreement_signers where id = p_signer;
  if g.id is null or g.signer_role <> 'additional_driver' or g.driver_id is null then raise exception 'This link is for an additional driver' using errcode = '42501'; end if;
  if v_issuer is null or v_expiry is null or length(v_number) not between 5 and 25 then
    raise exception 'Give the licence number, who issued it and its expiry date' using errcode = '22023';
  end if;
  if v_issuer = 'ON' and v_number !~ '^[A-Z][0-9]{4}-?[0-9]{5}-?[0-9]{5}$' then
    raise exception 'An Ontario licence number looks like A1234-12345-12345' using errcode = '22023';
  end if;
  select app.local_date(b.return_at) into v_return from rental_agreements a join bookings b on b.id = a.booking_id where a.id = g.agreement_id;
  if v_expiry <= v_return then raise exception 'The licence must be valid after the return date' using errcode = '23514'; end if;
  update drivers set licence_number = v_number, licence_issuer = v_issuer, licence_expiry = v_expiry, updated_at = now() where id = g.driver_id;
  update booking_drivers bd set licence_number = v_number, licence_issuer = v_issuer, licence_expiry = v_expiry
    from bookings b where bd.driver_id = g.driver_id and b.id = bd.booking_id and b.status in ('requested', 'offered', 'pending_payment', 'confirmed');
  return jsonb_build_object('ok', true);
end $$;

-- the additional driver's link page shows the state of their licence
create or replace function public.server_driver_licence_state(p_signer uuid) returns jsonb
language sql stable security definer set search_path = public, app as $$
  select jsonb_build_object('driver_id', g.driver_id, 'licence', app.licence_status(a.booking_id, g.driver_id),
                            'selfie_required', coalesce((app.settings()).booking_licence_selfie_required, true))
    from rental_agreement_signers g join rental_agreements a on a.id = g.agreement_id where g.id = p_signer and g.signer_role = 'additional_driver'
$$;

-- Staff take the licence photo on the spot (hand-over screen): stored by the server, registered as staff.
create or replace function app.staff_licence_register(p_by uuid, p jsonb) returns uuid
language plpgsql security definer set search_path = public, app as $$
begin
  if not app.user_may_handover(p_by) then raise exception 'Not permitted' using errcode = '42501'; end if;
  if p ->> 'kind' not in ('licence_front', 'licence_back', 'selfie') then raise exception 'Upload the licence or the selfie' using errcode = '22023'; end if;
  perform set_config('app.handover_as', p_by::text, true);
  return app.register_verification_upload((p ->> 'booking')::uuid, p_by, p ->> 'kind', (p ->> 'driver')::uuid, p ->> 'path', p ->> 'sha256', p ->> 'mime', null, 'identity');
end $$;

-- ================================================================ the door
alter function app.door(uuid, text, text, text, jsonb) rename to door_pre0130;
create or replace function app.door(p_user uuid, p_aal text, p_call text, p_name text, p jsonb default '{}'::jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  p_ jsonb := coalesce(p, '{}'::jsonb) - '_va';
  v_job uuid;
  v_b uuid;
begin
  if (p_call = 'ops_read' and p_name in ('handover_report', 'in_person_signing', 'handovers_today'))
     or (p_call = 'ops_do' and p_name in ('handover_open', 'handover_time_correct', 'check_in_waive', 'sign_in_person', 'staff_licence_register', 'signing_link_send')) then
    if coalesce(p, '{}'::jsonb) ? '_va' then perform set_config('app.va_active', coalesce(p ->> '_va', ''), true); end if;
    perform app.door_begin(p_user, p_aal);
    v_b := case when p_ ? 'booking' then coalesce((select id from bookings where id::text = p_ ->> 'booking' or booking_number = p_ ->> 'booking' limit 1),
                                                  '00000000-0000-0000-0000-000000000000'::uuid) end;
    case p_name
    when 'handover_report' then
      if not (app.user_may_handover(p_user) or app.user_va_has(p_user, 'finance')) then raise exception 'Not permitted' using errcode = '42501'; end if;
      return app.handover_report(v_b);
    when 'in_person_signing' then return app.in_person_signing(p_user, v_b);
    when 'handovers_today' then return app.handovers_today(p_user);
    when 'handover_open' then return jsonb_build_object('job', app.handover_open(p_user, v_b, p_ ->> 'kind'));
    when 'handover_time_correct' then return app.handover_time_correct(p_user, p_ || jsonb_build_object('booking', v_b));
    when 'check_in_waive' then return app.check_in_waive(p_user, p_ || jsonb_build_object('booking', v_b));
    when 'sign_in_person' then return app.sign_in_person(p_user, p_ || jsonb_build_object('booking', v_b));
    when 'signing_link_send' then return app.signing_link_send(p_user, p_ || jsonb_build_object('booking', v_b));
    else return jsonb_build_object('upload_id', app.staff_licence_register(p_user, p_ || jsonb_build_object('booking', v_b)));
    end case;
  end if;
  -- staff working one check-out or check-in job of their own through the field portal's reads and steps
  if p_call in ('field_read', 'field_do') and not app.user_is_field(p_user) and app.user_may_handover(p_user) then
    v_job := case when p_call = 'field_read' and p_name = 'job' then nullif(p_ ->> 'id', '')::uuid
                  when p_call = 'field_do' and p_name in ('save_report', 'complete_handover', 'complete_return', 'block_handover') then nullif(p_ ->> 'job', '')::uuid end;
    if v_job is not null and exists (select 1 from field_jobs j where j.id = v_job and j.assigned_to = p_user and j.status <> 'cancelled'
                                       and j.kind in ('handover', 'delivery', 'return_check_in', 'pickup_from_renter')) then
      perform set_config('app.handover_as', p_user::text, true);
    end if;
  end if;
  return app.door_pre0130(p_user, p_aal, p_call, p_name, p);
end $$;

-- Sales check cars out and in from the booking page (release 5): an assistant who may hand over opens a booking whose
-- check-out or check-in is due (the pickup or the return by tomorrow), or one they have a check-out or check-in job on.
-- Any other confirmed booking someone else made stays closed to Sales (0031, suite 31).
select pg_temp.patch_fn('app.va_booking_0031(uuid, text, jsonb)'::regprocedure,
  $o$  if p_fn = 'sales' and not (v ->> 'status' in ('requested', 'offered')) then$o$,
  $n$  if p_fn = 'sales' and not (v ->> 'status' in ('requested', 'offered')
                               or (app.user_may_handover(p_user) and (
                                     (v ->> 'status' = 'confirmed' and app.local_date((v ->> 'pickup_at')::timestamptz) <= app.today() + 1)
                                  or (v ->> 'status' = 'on_rent' and app.local_date((v ->> 'return_at')::timestamptz) <= app.today() + 1)
                                  or exists (select 1 from field_jobs j where j.booking_id = (v ->> 'id')::uuid and j.assigned_to = p_user and j.status <> 'cancelled'
                                                and j.kind in ('handover', 'delivery', 'return_check_in', 'pickup_from_renter'))))) then$n$);

-- ================================================================ privileges
do $$
declare
  f record;
  r record;
  g text;
begin
  for f in
    select p.oid::regprocedure as sig from pg_proc p join pg_namespace n on n.oid = p.pronamespace
     where (n.nspname = 'app' and p.proname = any (array['user_may_handover', 'handover_open', 'return_auto_charges', 'check_in_waive', 'handover_time_correct',
             'handover_report', 'in_person_signing', 'sign_in_person', 'signature_in_person_line', 'licence_status', 'licence_reuse', 'licence_gate',
             'staff_licence_register', 'fmt_duration_minutes', 'signature_in_person_fill', 'signing_link_send', 'handovers_today']))
        or (n.nspname = 'public' and p.proname = any (array['server_renter_handover_report', 'server_licence_state', 'server_driver_register_upload', 'server_in_person_lines',
             'server_driver_save_licence', 'server_driver_licence_state']))
  loop
    execute format('revoke all on function %s from public, anon, authenticated', f.sig);
    execute format('grant execute on function %s to service_role', f.sig);
  end loop;
  -- each renamed function keeps its privileges; the function in its place gets the same
  for r in select p.oid, n.nspname as old_schema, m.new_schema, m.new_name, oidvectortypes(p.proargtypes) as args
             from pg_proc p join pg_namespace n on n.oid = p.pronamespace
             join (values ('door_pre0130', 'app', 'door'), ('complete_return_pre0130', 'app', 'complete_return'), ('approve_offer_pre0130', 'app', 'approve_offer'),
                          ('ntf_payload_pre0130', 'app', 'notification_payload'),
                          ('server_booking_payment_facts_pre0130', 'public', 'server_booking_payment_facts')) m(old_name, new_schema, new_name) on m.old_name = p.proname
            where n.nspname = 'app' loop
    execute format('revoke all on function %s from public, anon, authenticated', format('%I.%I(%s)', r.new_schema, r.new_name, r.args)::regprocedure);
    foreach g in array array['anon', 'authenticated', 'service_role'] loop
      if has_function_privilege(g, r.oid, 'execute') then
        execute format('grant execute on function %s to %I', format('%I.%I(%s)', r.new_schema, r.new_name, r.args)::regprocedure, g);
      end if;
    end loop;
    if r.new_schema = 'public' then
      execute format('revoke all on function %s from public, anon, authenticated', format('app.%I(%s)', 'server_booking_payment_facts_pre0130', r.args)::regprocedure);
    end if;
  end loop;
end $$;
grant execute on function public.server_booking_payment_facts(uuid) to service_role;

-- GUIDES 0130 START (generated by supabase/seed/0130_gen_guides.mjs from docs/guides/content; do not edit by hand)
select app.guide_release_section('renter', 'find-a-car-and-send-a-request', 'chapter', 'start-here', 'Every booking starts as a request. A person checks the car and the price, then sends you an offer. Nothing is charged until you approve, sign and pay.

:::flow
Request | You pick a car and dates
Offer | We confirm the price
Sign | The rental agreement
Pay | Your card is authorized
Verify | Licence, selfie, coverage
Pick up | We hand over the keys
:::

## Find a car

Start on carmacars.ca. You do not need to sign in to look around.

1. Go to `carmacars.ca` and press **Find a car**.
2. Add your pickup and return dates. The list then shows the cars that are free and what the whole trip costs.
3. Narrow the list with Filters: type, seats, transmission and daily rate.
4. Open a car to see its photos, rates, what is included and its own calendar. Its car code (like CC-7F3A) is under the price: quote it when you call or chat with us, and we know the car at once.

![](/guides/img/public-02-cars-desktop-b6cd4fb8.jpg "desktop; size: 1440 880; address: carmacars.ca/cars; pins: 1 86.1 4.0, 2 11.1 56.8, 3 3.0 82.3, 4 34.0 87.5")

## Choose your dates on the car page

1. Under Dates and price, tap your pickup date, then your return date. Hatched days are already booked.
2. Choose the Pickup time and the Return time.
3. Want it brought to you? Tick **Deliver it to me** or **Pick it up from me at the end**. Open Add-ons to add a baby seat, flowers, a full tank and more.
4. Check Your estimate, then press **Request to book**. The add-ons you chose come with you.

![](/guides/img/public-03-car-page-desktop-73be4d63.jpg "desktop; size: 1120 760; address: carmacars.ca/cars/bmw-330i; pins: 1 24.4 39.7, 2 12.9 68.2, 3 3.0 76.2, 4 97.0 50.0")

> Watch out: A request does not hold the car. The car is booked only once you approve the offer, sign and pay.

## Send your request

The request has five short steps. Your answers are saved as you go, so you can come back.

1. Step 1, Dates and delivery: check the car and tap your dates in the calendar.
2. Set the Pickup time and Return time. Any time, day or night, with at least 2 hours of notice.
3. Your request, on the right, shows the estimated total as you go.

![](/guides/img/public-04-book-1-trip-desktop-63a3738b.jpg "desktop; size: 1440 1002; address: carmacars.ca/book/bmw-330i?from=2026-11-25&to=2026-11-28&tf=10:00&tt=10:00; pins: 1 9.2 67.1, 2 15.3 91.0, 3 91.1 54.7")

4. Choose where you get the car: **At our location**, **Deliver it to an address** or **At the airport**. Then choose where you return it.
5. Press **Continue to driver details**.

![](/guides/img/public-04-book-1-trip-desktop-befba4f6.jpg "desktop; size: 760 942; address: carmacars.ca/book/bmw-330i?from=2026-11-25&to=2026-11-28&tf=10:00&tt=10:00; pins: 4 5.3 26.2, 5 61.8 93.3")

6. Step 2, The driver: fill in your first and last name, email, mobile number and date of birth.
7. Someone else will drive too? Add them under Additional drivers. Each needs a G2 or G licence and signs the agreement.
8. Press **Continue to licence**.

![](/guides/img/public-05-book-2-driver-desktop-7b572499.jpg "desktop; size: 980 1032; address: carmacars.ca/book/bmw-330i?from=2026-11-25&to=2026-11-28&tf=10:00&tt=10:00; pins: 6 30.6 21.1, 7 30.6 64.8, 8 55.6 88.0")

9. Step 3: choose your Licence class, for example Ontario G2.
10. Choose how the car is covered: Option 1 (OPCF 27 on your own auto policy), Option 2 (rental coverage on your credit card) or Option 3 (the CarmaCars Protection Plan). You can change this any time before pickup.
11. Choose the Booking type: Standard, or Non-refundable for 10% off with no refund.
12. Add anything we should know in the notes, for example a flight number.
13. Press **Continue to add-ons**. Step 4, Add-ons: tick what you want (see Add-ons below), then press **Review request**.

![](/guides/img/public-06-book-3-licence-desktop-22bb144e.jpg "desktop; size: 760 1452; address: carmacars.ca/book/bmw-330i?from=2026-11-25&to=2026-11-28&tf=10:00&tt=10:00; pins: 9 61.8 11.2, 10 92.1 32.2, 11 92.1 50.4, 12 92.1 66.9, 13 71.7 97.0")

14. Step 5, Check it and send: read every line. Use Edit beside a line to change it.
15. Tick the box to confirm you are 18 or older and agree to the Terms of use and Privacy policy.
16. Press **Send request**. Nothing is charged and no card is needed.

![](/guides/img/public-07-book-4-review-desktop-005f4c0b.jpg "desktop; size: 760 492; address: carmacars.ca/book/bmw-330i?from=2026-11-25&to=2026-11-28&tf=10:00&tt=10:00; pins: 14 92.1 24.8, 15 3.9 59.3, 16 73.7 89.0")

17. The confirmation shows your request number, for example CC-10021. Keep it for any question.
18. A person checks the calendar, your dates and your place, usually within 2 hours, day or night. Your offer arrives by email and in Trips.

![](/guides/img/public-08-book-5-sent-phone-14a99ccf.jpg "phone; size: 390 755; pins: 17 32.8 12.3")

## Add-ons

Extras for your trip, such as a baby seat, a child or booster seat, flowers waiting in the car, a chauffeur, an umbrella, a phone charger or a full tank of gas.

1. On the car page (under Add-ons) or in step 4 of the request, tick an add-on or use + and − for seats. The estimate shows the price at once.
2. Each add-on shows its price: a trip, a day (with the most for a trip) or an hour. HST is added.
3. Some need notice, for example flowers need 24 hours. Seats and other items show how many are left for your dates.
4. A chauffeur is confirmed by our team in your offer.

With a full tank of gas (prepaid) you can return the car at any fuel level, with no fuel charge.

## Ask in the chat

The chat button sits in the corner of every page.

1. Press it and write your question: a car, your dates, the price, how booking works. The CarmaCars assistant answers right away with prices from our booking system.
2. Want a person? Press **Talk to a person**. When our team is away, leave your name and email or phone with **Send my details** and tick "Email me a copy of this chat".
3. Press **End chat** when you are done. If you gave your email, a copy of the chat arrives by email.

A price in the chat is for the dates you asked. Nothing is booked until you approve an offer, sign and pay.

## Carry on later

- Your name, email and mobile number are saved as you type them, so nothing is lost if you stop. We open an account for you with that email.
- Every form that saves as you type says so under it: "Saved as you type so you can pick up where you left off.", with a link to the privacy policy.
- On the same phone or computer, open `carmacars.ca/account` (or the request page again) to carry on, no password needed.
- We send you one email, "Continue your request". One tap signs you in, confirms your email and opens your request on any device. You need it before you can accept an offer, sign or pay.
- Already have an account? The form says "You have an account: we sent you a sign-in link".
', 'Find a car and send a request', 'Search the fleet, pick dates and add-ons, and send a request in five short steps.',
  'Every booking starts as a request. A person checks the car and the price, then sends you an offer. Nothing is charged until you approve, sign and pay.

:::flow
Request | You pick a car and dates
Offer | We confirm the price
Sign | The rental agreement
Pay | Your card is authorized
Verify | Licence, selfie, coverage
Pick up | We hand over the keys
:::

## Find a car

Start on carmacars.ca. You do not need to sign in to look around.

1. Go to `carmacars.ca` and press **Find a car**.
2. Add your pickup and return dates. The list then shows the cars that are free and what the whole trip costs.
3. Narrow the list with Filters: type, seats, transmission and daily rate.
4. Open a car to see its photos, rates, what is included and its own calendar. Its car code (like CC-7F3A) is under the price: quote it when you call or chat with us, and we know the car at once.

![](/guides/img/public-02-cars-desktop-b6cd4fb8.jpg "desktop; size: 1440 880; address: carmacars.ca/cars; pins: 1 86.1 4.0, 2 11.1 56.8, 3 3.0 82.3, 4 34.0 87.5")

## Choose your dates on the car page

1. Under Dates and price, tap your pickup date, then your return date. Hatched days are already booked.
2. Choose the Pickup time and the Return time.
3. Want it brought to you? Tick **Deliver it to me** or **Pick it up from me at the end**. Open Add-ons to add a baby seat, flowers, a full tank and more.
4. Check Your estimate, then press **Request to book**. The add-ons you chose come with you.

![](/guides/img/public-03-car-page-desktop-73be4d63.jpg "desktop; size: 1120 760; address: carmacars.ca/cars/bmw-330i; pins: 1 24.4 39.7, 2 12.9 68.2, 3 3.0 76.2, 4 97.0 50.0")

> Watch out: A request does not hold the car. The car is booked only once you approve the offer, sign and pay.

## Send your request

The request has five short steps. Your answers are saved as you go, so you can come back.

1. Step 1, Dates and delivery: check the car and tap your dates in the calendar.
2. Set the Pickup time and Return time. Any time, day or night, with at least 2 hours of notice.
3. Your request, on the right, shows the estimated total as you go.

![](/guides/img/public-04-book-1-trip-desktop-63a3738b.jpg "desktop; size: 1440 1002; address: carmacars.ca/book/bmw-330i?from=2026-11-25&to=2026-11-28&tf=10:00&tt=10:00; pins: 1 9.2 67.1, 2 15.3 91.0, 3 91.1 54.7")

4. Choose where you get the car: **At our location**, **Deliver it to an address** or **At the airport**. Then choose where you return it.
5. Press **Continue to driver details**.

![](/guides/img/public-04-book-1-trip-desktop-befba4f6.jpg "desktop; size: 760 942; address: carmacars.ca/book/bmw-330i?from=2026-11-25&to=2026-11-28&tf=10:00&tt=10:00; pins: 4 5.3 26.2, 5 61.8 93.3")

6. Step 2, The driver: fill in your first and last name, email, mobile number and date of birth.
7. Someone else will drive too? Add them under Additional drivers. Each needs a G2 or G licence and signs the agreement.
8. Press **Continue to licence**.

![](/guides/img/public-05-book-2-driver-desktop-7b572499.jpg "desktop; size: 980 1032; address: carmacars.ca/book/bmw-330i?from=2026-11-25&to=2026-11-28&tf=10:00&tt=10:00; pins: 6 30.6 21.1, 7 30.6 64.8, 8 55.6 88.0")

9. Step 3: choose your Licence class, for example Ontario G2.
10. Choose how the car is covered: Option 1 (OPCF 27 on your own auto policy), Option 2 (rental coverage on your credit card) or Option 3 (the CarmaCars Protection Plan). You can change this any time before pickup.
11. Choose the Booking type: Standard, or Non-refundable for 10% off with no refund.
12. Add anything we should know in the notes, for example a flight number.
13. Press **Continue to add-ons**. Step 4, Add-ons: tick what you want (see Add-ons below), then press **Review request**.

![](/guides/img/public-06-book-3-licence-desktop-22bb144e.jpg "desktop; size: 760 1452; address: carmacars.ca/book/bmw-330i?from=2026-11-25&to=2026-11-28&tf=10:00&tt=10:00; pins: 9 61.8 11.2, 10 92.1 32.2, 11 92.1 50.4, 12 92.1 66.9, 13 71.7 97.0")

14. Step 5, Check it and send: read every line. Use Edit beside a line to change it.
15. Tick the box to confirm you are 18 or older and agree to the Terms of use and Privacy policy.
16. Press **Send request**. Nothing is charged and no card is needed.

![](/guides/img/public-07-book-4-review-desktop-005f4c0b.jpg "desktop; size: 760 492; address: carmacars.ca/book/bmw-330i?from=2026-11-25&to=2026-11-28&tf=10:00&tt=10:00; pins: 14 92.1 24.8, 15 3.9 59.3, 16 73.7 89.0")

17. The confirmation shows your request number, for example CC-10021. Keep it for any question.
18. A person checks the calendar, your dates and your place, usually within 2 hours, day or night. Your offer arrives by email and in Trips.

![](/guides/img/public-08-book-5-sent-phone-14a99ccf.jpg "phone; size: 390 755; pins: 17 32.8 12.3")

## Upload your licence

Right after you send your request: the front and back of your licence and a selfie holding it.

1. On the Request sent page, press **Upload your licence** (or open your booking and press **Your licence**).
2. Take each photo with your phone, or choose it. Add the licence number and expiry date if we ask: it must be valid after your return.
3. Rented with us before? A licence on file that is still valid is used again; nothing to upload.

> Tip: You need your licence on file to accept the offer.

## Add-ons

Extras for your trip, such as a baby seat, a child or booster seat, flowers waiting in the car, a chauffeur, an umbrella, a phone charger or a full tank of gas.

1. On the car page (under Add-ons) or in step 4 of the request, tick an add-on or use + and − for seats. The estimate shows the price at once.
2. Each add-on shows its price: a trip, a day (with the most for a trip) or an hour. HST is added.
3. Some need notice, for example flowers need 24 hours. Seats and other items show how many are left for your dates.
4. A chauffeur is confirmed by our team in your offer.

With a full tank of gas (prepaid) you can return the car at any fuel level, with no fuel charge.

## Ask in the chat

The chat button sits in the corner of every page.

1. Press it and write your question: a car, your dates, the price, how booking works. The CarmaCars assistant answers right away with prices from our booking system.
2. Want a person? Press **Talk to a person**. When our team is away, leave your name and email or phone with **Send my details** and tick "Email me a copy of this chat".
3. Press **End chat** when you are done. If you gave your email, a copy of the chat arrives by email.

A price in the chat is for the dates you asked. Nothing is booked until you approve an offer, sign and pay.

## Carry on later

- Your name, email and mobile number are saved as you type them, so nothing is lost if you stop. We open an account for you with that email.
- Every form that saves as you type says so under it: "Saved as you type so you can pick up where you left off.", with a link to the privacy policy.
- On the same phone or computer, open `carmacars.ca/account` (or the request page again) to carry on, no password needed.
- We send you one email, "Continue your request". One tap signs you in, confirms your email and opens your request on any device. You need it before you can accept an offer, sign or pay.
- Already have an account? The form says "You have an account: we sent you a sign-in link".
',
  '<p class="gd-p">Every booking starts as a request. A person checks the car and the price, then sends you an offer. Nothing is charged until you approve, sign and pay.</p><ol class="gd-flow"><li><b>1</b><span>Request</span><em>You pick a car and dates</em></li><li><b>2</b><span>Offer</span><em>We confirm the price</em></li><li><b>3</b><span>Sign</span><em>The rental agreement</em></li><li><b>4</b><span>Pay</span><em>Your card is authorized</em></li><li><b>5</b><span>Verify</span><em>Licence, selfie, coverage</em></li><li><b>6</b><span>Pick up</span><em>We hand over the keys</em></li></ol><section class="gd-task" id="find-a-car-and-send-a-request-find-a-car" data-gd-task><h2 class="gd-h2">Find a car</h2><p class="gd-p">Start on carmacars.ca. You do not need to sign in to look around.</p><div class="gd-stepblock gd-stepblock--below"><div class="gd-stepcol"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">Go to <span class="gd-url">carmacars.ca</span> and press <b class="gd-ui">Find a car</b>.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Add your pickup and return dates. The list then shows the cars that are free and what the whole trip costs.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Narrow the list with Filters: type, seats, transmission and daily rate.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t">Open a car to see its photos, rates, what is included and its own calendar. Its car code (like CC-7F3A) is under the price: quote it when you call or chat with us, and we know the car at once.</div></li></ol></div><figure class="gd-fig gd-fig--desk"><div class="gd-browser"><div class="gd-bar" aria-hidden="true"><i></i><i></i><i></i><span class="gd-addr">carmacars.ca/cars</span></div><div class="gd-imgwrap" style="aspect-ratio:1440/880"><img src="/guides/img/public-02-cars-desktop-b6cd4fb8.jpg" alt="" loading="lazy" decoding="async" width="1440" height="880"><span class="gd-pin" style="left:86.1%;top:4%" aria-hidden="true">1</span><span class="gd-pin" style="left:11.1%;top:56.8%" aria-hidden="true">2</span><span class="gd-pin" style="left:3%;top:82.3%" aria-hidden="true">3</span><span class="gd-pin" style="left:34%;top:87.5%" aria-hidden="true">4</span></div></div></figure></div></section><section class="gd-task" id="find-a-car-and-send-a-request-choose-your-dates-on-the-car-page" data-gd-task><h2 class="gd-h2">Choose your dates on the car page</h2><div class="gd-stepblock gd-stepblock--below"><div class="gd-stepcol"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">Under Dates and price, tap your pickup date, then your return date. Hatched days are already booked.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Choose the Pickup time and the Return time.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Want it brought to you? Tick <b class="gd-ui">Deliver it to me</b> or <b class="gd-ui">Pick it up from me at the end</b>. Open Add-ons to add a baby seat, flowers, a full tank and more.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t">Check Your estimate, then press <b class="gd-ui">Request to book</b>. The add-ons you chose come with you.</div></li></ol></div><figure class="gd-fig gd-fig--desk"><div class="gd-browser"><div class="gd-bar" aria-hidden="true"><i></i><i></i><i></i><span class="gd-addr">carmacars.ca/cars/bmw-330i</span></div><div class="gd-imgwrap" style="aspect-ratio:1120/760"><img src="/guides/img/public-03-car-page-desktop-73be4d63.jpg" alt="" loading="lazy" decoding="async" width="1120" height="760"><span class="gd-pin" style="left:24.4%;top:39.7%" aria-hidden="true">1</span><span class="gd-pin" style="left:12.9%;top:68.2%" aria-hidden="true">2</span><span class="gd-pin" style="left:3%;top:76.2%" aria-hidden="true">3</span><span class="gd-pin" style="left:97%;top:50%" aria-hidden="true">4</span></div></div></figure></div><aside class="gd-box gd-box--warn"><span class="gd-lbl">Watch out</span><div>A request does not hold the car. The car is booked only once you approve the offer, sign and pay.</div></aside></section><section class="gd-task" id="find-a-car-and-send-a-request-send-your-request" data-gd-task><h2 class="gd-h2">Send your request</h2><p class="gd-p">The request has five short steps. Your answers are saved as you go, so you can come back.</p><div class="gd-stepblock gd-stepblock--below"><div class="gd-stepcol"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">Step 1, Dates and delivery: check the car and tap your dates in the calendar.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Set the Pickup time and Return time. Any time, day or night, with at least 2 hours of notice.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Your request, on the right, shows the estimated total as you go.</div></li></ol></div><figure class="gd-fig gd-fig--desk"><div class="gd-browser"><div class="gd-bar" aria-hidden="true"><i></i><i></i><i></i><span class="gd-addr">carmacars.ca/book/bmw-330i?from=2026-11-25&amp;to=2026-11-28&amp;tf=10:00&amp;tt=10:00</span></div><div class="gd-imgwrap" style="aspect-ratio:1440/1002"><img src="/guides/img/public-04-book-1-trip-desktop-63a3738b.jpg" alt="" loading="lazy" decoding="async" width="1440" height="1002"><span class="gd-pin" style="left:9.2%;top:67.1%" aria-hidden="true">1</span><span class="gd-pin" style="left:15.3%;top:91%" aria-hidden="true">2</span><span class="gd-pin" style="left:91.1%;top:54.7%" aria-hidden="true">3</span></div></div></figure></div><div class="gd-stepblock gd-stepblock--below"><div class="gd-stepcol"><ol class="gd-ol" start="4"><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t">Choose where you get the car: <b class="gd-ui">At our location</b>, <b class="gd-ui">Deliver it to an address</b> or <b class="gd-ui">At the airport</b>. Then choose where you return it.</div></li><li><span class="gd-n" aria-hidden="true">5</span><div class="gd-t">Press <b class="gd-ui">Continue to driver details</b>.</div></li></ol></div><figure class="gd-fig gd-fig--desk"><div class="gd-browser"><div class="gd-bar" aria-hidden="true"><i></i><i></i><i></i><span class="gd-addr">carmacars.ca/book/bmw-330i?from=2026-11-25&amp;to=2026-11-28&amp;tf=10:00&amp;tt=10:00</span></div><div class="gd-imgwrap" style="aspect-ratio:760/942"><img src="/guides/img/public-04-book-1-trip-desktop-befba4f6.jpg" alt="" loading="lazy" decoding="async" width="760" height="942"><span class="gd-pin" style="left:5.3%;top:26.2%" aria-hidden="true">4</span><span class="gd-pin" style="left:61.8%;top:93.3%" aria-hidden="true">5</span></div></div></figure></div><div class="gd-stepblock gd-stepblock--below"><div class="gd-stepcol"><ol class="gd-ol" start="6"><li><span class="gd-n" aria-hidden="true">6</span><div class="gd-t">Step 2, The driver: fill in your first and last name, email, mobile number and date of birth.</div></li><li><span class="gd-n" aria-hidden="true">7</span><div class="gd-t">Someone else will drive too? Add them under Additional drivers. Each needs a G2 or G licence and signs the agreement.</div></li><li><span class="gd-n" aria-hidden="true">8</span><div class="gd-t">Press <b class="gd-ui">Continue to licence</b>.</div></li></ol></div><figure class="gd-fig gd-fig--desk"><div class="gd-browser"><div class="gd-bar" aria-hidden="true"><i></i><i></i><i></i><span class="gd-addr">carmacars.ca/book/bmw-330i?from=2026-11-25&amp;to=2026-11-28&amp;tf=10:00&amp;tt=10:00</span></div><div class="gd-imgwrap" style="aspect-ratio:980/1032"><img src="/guides/img/public-05-book-2-driver-desktop-7b572499.jpg" alt="" loading="lazy" decoding="async" width="980" height="1032"><span class="gd-pin" style="left:30.6%;top:21.1%" aria-hidden="true">6</span><span class="gd-pin" style="left:30.6%;top:64.8%" aria-hidden="true">7</span><span class="gd-pin" style="left:55.6%;top:88%" aria-hidden="true">8</span></div></div></figure></div><div class="gd-stepblock gd-stepblock--below"><div class="gd-stepcol"><ol class="gd-ol" start="9"><li><span class="gd-n" aria-hidden="true">9</span><div class="gd-t">Step 3: choose your Licence class, for example Ontario G2.</div></li><li><span class="gd-n" aria-hidden="true">10</span><div class="gd-t">Choose how the car is covered: Option 1 (OPCF 27 on your own auto policy), Option 2 (rental coverage on your credit card) or Option 3 (the CarmaCars Protection Plan). You can change this any time before pickup.</div></li><li><span class="gd-n" aria-hidden="true">11</span><div class="gd-t">Choose the Booking type: Standard, or Non-refundable for 10% off with no refund.</div></li><li><span class="gd-n" aria-hidden="true">12</span><div class="gd-t">Add anything we should know in the notes, for example a flight number.</div></li><li><span class="gd-n" aria-hidden="true">13</span><div class="gd-t">Press <b class="gd-ui">Continue to add-ons</b>. Step 4, Add-ons: tick what you want (see Add-ons below), then press <b class="gd-ui">Review request</b>.</div></li></ol></div><figure class="gd-fig gd-fig--desk"><div class="gd-browser"><div class="gd-bar" aria-hidden="true"><i></i><i></i><i></i><span class="gd-addr">carmacars.ca/book/bmw-330i?from=2026-11-25&amp;to=2026-11-28&amp;tf=10:00&amp;tt=10:00</span></div><div class="gd-imgwrap" style="aspect-ratio:760/1452"><img src="/guides/img/public-06-book-3-licence-desktop-22bb144e.jpg" alt="" loading="lazy" decoding="async" width="760" height="1452"><span class="gd-pin" style="left:61.8%;top:11.2%" aria-hidden="true">9</span><span class="gd-pin" style="left:92.1%;top:32.2%" aria-hidden="true">10</span><span class="gd-pin" style="left:92.1%;top:50.4%" aria-hidden="true">11</span><span class="gd-pin" style="left:92.1%;top:66.9%" aria-hidden="true">12</span><span class="gd-pin" style="left:71.7%;top:97%" aria-hidden="true">13</span></div></div></figure></div><div class="gd-stepblock gd-stepblock--below"><div class="gd-stepcol"><ol class="gd-ol" start="14"><li><span class="gd-n" aria-hidden="true">14</span><div class="gd-t">Step 5, Check it and send: read every line. Use Edit beside a line to change it.</div></li><li><span class="gd-n" aria-hidden="true">15</span><div class="gd-t">Tick the box to confirm you are 18 or older and agree to the Terms of use and Privacy policy.</div></li><li><span class="gd-n" aria-hidden="true">16</span><div class="gd-t">Press <b class="gd-ui">Send request</b>. Nothing is charged and no card is needed.</div></li></ol></div><figure class="gd-fig gd-fig--desk"><div class="gd-browser"><div class="gd-bar" aria-hidden="true"><i></i><i></i><i></i><span class="gd-addr">carmacars.ca/book/bmw-330i?from=2026-11-25&amp;to=2026-11-28&amp;tf=10:00&amp;tt=10:00</span></div><div class="gd-imgwrap" style="aspect-ratio:760/492"><img src="/guides/img/public-07-book-4-review-desktop-005f4c0b.jpg" alt="" loading="lazy" decoding="async" width="760" height="492"><span class="gd-pin" style="left:92.1%;top:24.8%" aria-hidden="true">14</span><span class="gd-pin" style="left:3.9%;top:59.3%" aria-hidden="true">15</span><span class="gd-pin" style="left:73.7%;top:89%" aria-hidden="true">16</span></div></div></figure></div><div class="gd-stepblock gd-stepblock--side"><div class="gd-stepcol"><ol class="gd-ol" start="17"><li><span class="gd-n" aria-hidden="true">17</span><div class="gd-t">The confirmation shows your request number, for example CC-10021. Keep it for any question.</div></li><li><span class="gd-n" aria-hidden="true">18</span><div class="gd-t">A person checks the calendar, your dates and your place, usually within 2 hours, day or night. Your offer arrives by email and in Trips.</div></li></ol></div><figure class="gd-fig gd-fig--phone"><div class="gd-phone"><div class="gd-imgwrap" style="aspect-ratio:390/755"><img src="/guides/img/public-08-book-5-sent-phone-14a99ccf.jpg" alt="" loading="lazy" decoding="async" width="390" height="755"><span class="gd-pin" style="left:32.8%;top:12.3%" aria-hidden="true">17</span></div></div></figure></div></section><section class="gd-task" id="find-a-car-and-send-a-request-upload-your-licence" data-gd-task><h2 class="gd-h2">Upload your licence</h2><p class="gd-p">Right after you send your request: the front and back of your licence and a selfie holding it.</p><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">On the Request sent page, press <b class="gd-ui">Upload your licence</b> (or open your booking and press <b class="gd-ui">Your licence</b>).</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Take each photo with your phone, or choose it. Add the licence number and expiry date if we ask: it must be valid after your return.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Rented with us before? A licence on file that is still valid is used again; nothing to upload.</div></li></ol></div><aside class="gd-box"><span class="gd-lbl">Tip</span><div>You need your licence on file to accept the offer.</div></aside></section><section class="gd-task" id="find-a-car-and-send-a-request-add-ons" data-gd-task><h2 class="gd-h2">Add-ons</h2><p class="gd-p">Extras for your trip, such as a baby seat, a child or booster seat, flowers waiting in the car, a chauffeur, an umbrella, a phone charger or a full tank of gas.</p><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">On the car page (under Add-ons) or in step 4 of the request, tick an add-on or use + and − for seats. The estimate shows the price at once.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Each add-on shows its price: a trip, a day (with the most for a trip) or an hour. HST is added.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Some need notice, for example flowers need 24 hours. Seats and other items show how many are left for your dates.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t">A chauffeur is confirmed by our team in your offer.</div></li></ol></div><p class="gd-p">With a full tank of gas (prepaid) you can return the car at any fuel level, with no fuel charge.</p></section><section class="gd-task" id="find-a-car-and-send-a-request-ask-in-the-chat" data-gd-task><h2 class="gd-h2">Ask in the chat</h2><p class="gd-p">The chat button sits in the corner of every page.</p><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">Press it and write your question: a car, your dates, the price, how booking works. The CarmaCars assistant answers right away with prices from our booking system.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Want a person? Press <b class="gd-ui">Talk to a person</b>. When our team is away, leave your name and email or phone with <b class="gd-ui">Send my details</b> and tick &quot;Email me a copy of this chat&quot;.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Press <b class="gd-ui">End chat</b> when you are done. If you gave your email, a copy of the chat arrives by email.</div></li></ol></div><p class="gd-p">A price in the chat is for the dates you asked. Nothing is booked until you approve an offer, sign and pay.</p></section><section class="gd-task" id="find-a-car-and-send-a-request-carry-on-later" data-gd-task><h2 class="gd-h2">Carry on later</h2><ul class="gd-ul"><li>Your name, email and mobile number are saved as you type them, so nothing is lost if you stop. We open an account for you with that email.</li><li>Every form that saves as you type says so under it: &quot;Saved as you type so you can pick up where you left off.&quot;, with a link to the privacy policy.</li><li>On the same phone or computer, open <span class="gd-url">carmacars.ca/account</span> (or the request page again) to carry on, no password needed.</li><li>We send you one email, &quot;Continue your request&quot;. One tap signs you in, confirms your email and opens your request on any device. You need it before you can accept an offer, sign or pay.</li><li>Already have an account? The form says &quot;You have an account: we sent you a sign-in link&quot;.</li></ul></section>');
select app.guide_release_section('renter', 'your-offer', 'chapter', 'find-a-car-and-send-a-request', 'Our offer is the confirmed price for your car and dates, with every fee and HST. It stays open for 24 hours. You approve it, ask for a change or decline it.

## Open your offer

1. We email you when the offer is ready. Sign in at `carmacars.ca/sign-in` and open **Trips**.
2. Your next step is always at the top. Press **Review offer**.

![](/guides/img/renter-02-trips-offer-desktop-27603c14.jpg "desktop; size: 1440 760; address: carmacars.ca/account; pins: 1 4.5 27.0, 2 11.5 70.0")

## Approve, ask for a change, or decline

1. Check the price, the dates, the place and any message from our team. The black bar shows how long the offer stays open.
2. All good? Press **Approve and continue** to sign and pay.
3. Want something different? Press **Ask for a change**, write what you need, then **Send request**.
4. Not going ahead? Press **Decline offer**, then **Decline this offer**.

![](/guides/img/renter-03-offer-desktop-cae88b00.jpg "desktop; size: 1440 902; address: carmacars.ca/account/bookings/CC-10057/offer; pins: 1 86.1 12.0, 2 70.8 50.9, 3 70.8 58.1, 4 77.1 64.5")

> Watch out: This offer does not hold the car. If someone else approves, signs and pays for the same car and dates first, we tell you and offer you another car or other dates.
', 'Your offer', 'Read the confirmed price, then approve, ask for a change or decline.',
  'Our offer is the confirmed price for your car and dates, with every fee and HST. It stays open for 24 hours. You approve it, ask for a change or decline it.

## Open your offer

1. We email you when the offer is ready. Sign in at `carmacars.ca/sign-in` and open **Trips**.
2. Your next step is always at the top. Press **Review offer**.

![](/guides/img/renter-02-trips-offer-desktop-27603c14.jpg "desktop; size: 1440 760; address: carmacars.ca/account; pins: 1 4.5 27.0, 2 11.5 70.0")

## Approve, ask for a change, or decline

1. Check the price, the dates, the place and any message from our team. The black bar shows how long the offer stays open.
2. All good? Press **Approve and continue** to sign and pay. No licence on file yet? The button says **Upload your licence to accept**: upload it, then come back.
3. Want something different? Press **Ask for a change**, write what you need, then **Send request**.
4. Not going ahead? Press **Decline offer**, then **Decline this offer**.

![](/guides/img/renter-03-offer-desktop-cae88b00.jpg "desktop; size: 1440 902; address: carmacars.ca/account/bookings/CC-10057/offer; pins: 1 86.1 12.0, 2 70.8 50.9, 3 70.8 58.1, 4 77.1 64.5")

> Watch out: This offer does not hold the car. If someone else approves, signs and pays for the same car and dates first, we tell you and offer you another car or other dates.
',
  '<p class="gd-p">Our offer is the confirmed price for your car and dates, with every fee and HST. It stays open for 24 hours. You approve it, ask for a change or decline it.</p><section class="gd-task" id="your-offer-open-your-offer" data-gd-task><h2 class="gd-h2">Open your offer</h2><div class="gd-stepblock gd-stepblock--below"><div class="gd-stepcol"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">We email you when the offer is ready. Sign in at <span class="gd-url">carmacars.ca/sign-in</span> and open <b class="gd-ui">Trips</b>.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Your next step is always at the top. Press <b class="gd-ui">Review offer</b>.</div></li></ol></div><figure class="gd-fig gd-fig--desk"><div class="gd-browser"><div class="gd-bar" aria-hidden="true"><i></i><i></i><i></i><span class="gd-addr">carmacars.ca/account</span></div><div class="gd-imgwrap" style="aspect-ratio:1440/760"><img src="/guides/img/renter-02-trips-offer-desktop-27603c14.jpg" alt="" loading="lazy" decoding="async" width="1440" height="760"><span class="gd-pin" style="left:4.5%;top:27%" aria-hidden="true">1</span><span class="gd-pin" style="left:11.5%;top:70%" aria-hidden="true">2</span></div></div></figure></div></section><section class="gd-task" id="your-offer-approve-ask-for-a-change-or-decline" data-gd-task><h2 class="gd-h2">Approve, ask for a change, or decline</h2><div class="gd-stepblock gd-stepblock--below"><div class="gd-stepcol"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">Check the price, the dates, the place and any message from our team. The black bar shows how long the offer stays open.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">All good? Press <b class="gd-ui">Approve and continue</b> to sign and pay. No licence on file yet? The button says <b class="gd-ui">Upload your licence to accept</b>: upload it, then come back.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Want something different? Press <b class="gd-ui">Ask for a change</b>, write what you need, then <b class="gd-ui">Send request</b>.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t">Not going ahead? Press <b class="gd-ui">Decline offer</b>, then <b class="gd-ui">Decline this offer</b>.</div></li></ol></div><figure class="gd-fig gd-fig--desk"><div class="gd-browser"><div class="gd-bar" aria-hidden="true"><i></i><i></i><i></i><span class="gd-addr">carmacars.ca/account/bookings/CC-10057/offer</span></div><div class="gd-imgwrap" style="aspect-ratio:1440/902"><img src="/guides/img/renter-03-offer-desktop-cae88b00.jpg" alt="" loading="lazy" decoding="async" width="1440" height="902"><span class="gd-pin" style="left:86.1%;top:12%" aria-hidden="true">1</span><span class="gd-pin" style="left:70.8%;top:50.9%" aria-hidden="true">2</span><span class="gd-pin" style="left:70.8%;top:58.1%" aria-hidden="true">3</span><span class="gd-pin" style="left:77.1%;top:64.5%" aria-hidden="true">4</span></div></div></figure></div><aside class="gd-box gd-box--warn"><span class="gd-lbl">Watch out</span><div>This offer does not hold the car. If someone else approves, signs and pays for the same car and dates first, we tell you and offer you another car or other dates.</div></aside></section>');
select app.guide_release_section('renter', 'sign-and-pay', 'chapter', 'your-offer', 'After you approve, you sign the rental agreement on screen and pay. It takes a few minutes on a phone or a computer; the signing itself is three taps.

## Sign the rental agreement

1. Fill in your home address and licence details. You do this once; we keep them for next time.
2. Press **Save details**. The agreement then shows your details.

![](/guides/img/renter-04-sign-details-desktop-bd193670.jpg "desktop; size: 1440 1052; address: carmacars.ca/account/bookings/CC-10057/sign; pins: 1 44.4 25.9, 2 16.3 96.4")

3. Check the key values at the top: the car, the dates, the deposit and the deductible. Open **Read the full rental agreement** to read it word for word, or press **Download PDF** to keep a copy. Below it is the Blind Spot Car Rental agreement, filled in with the same booking: we rent under Blind Spot''s insurance, so it is part of your rental too. Press its **Download PDF** to read it.
4. Under Sign, tap **All four**: it ticks the four statements, which stay on screen to read.
5. Your full legal name is your signature. Prefer to sign with your finger or the mouse? Press **Draw instead**.
6. Press **Sign and continue to payment**. Your one signature signs both agreements; the signed copies are in Documents and in the email that confirms your booking.

![](/guides/img/renter-06-sign-ready-desktop-1eee20a4.jpg "desktop; size: 1440 1212; address: carmacars.ca/account/bookings/CC-10057/sign; pins: 3 59.0 8.9, 4 69.4 18.2, 5 90.3 78.5, 6 96.9 87.1")

## Pay to confirm

1. Check What you pay now. The refundable deposit is taken at pickup, not today.
2. Enter the Name on the card and the card details. Use a credit card in your own name.
3. Press **Pay $...** (the button shows the amount).

![](/guides/img/renter-07-pay-desktop-705896d6.jpg "desktop; size: 1440 1082; address: carmacars.ca/account/bookings/CC-10057/pay; pins: 7 70.5 21.9, 8 64.6 16.5, 9 64.6 96.4")

> Tip: Your card is authorized now and charged once the booking is confirmed. It becomes your Card on File for the deposit at pickup and any later charges you agreed to when you signed.

> Watch out: See "This car was just taken"? Someone confirmed the same car first. The authorization on your card is released, and we offer you another car or other dates.

## A rental we booked for you

Booked by phone, in person or through a partner? We add the rental and you sign it online.

1. You get an email: "Read and sign your rental agreement; your card is charged when you sign."
2. Open it. Check the car, the dates and the price, and read the agreement.
3. Press **Accept and sign**. If we have your card on file, it is charged at that moment, not before, and the agreement is countersigned by CarmaCars as soon as you sign.
', 'Sign and pay', 'Sign the rental agreement on screen and pay with your card.',
  'After you approve, you sign the rental agreement on screen and pay. It takes a few minutes on a phone or a computer; the signing itself is three taps.

## Sign the rental agreement

1. Fill in your home address and licence details. You do this once; we keep them for next time.
2. Press **Save details**. The agreement then shows your details.

![](/guides/img/renter-04-sign-details-desktop-bd193670.jpg "desktop; size: 1440 1052; address: carmacars.ca/account/bookings/CC-10057/sign; pins: 1 44.4 25.9, 2 16.3 96.4")

3. Check the key values at the top: the car, the dates, the deposit and the deductible. Open **Read the full rental agreement** to read it word for word, or press **Download PDF** to keep a copy. Below it is the Blind Spot Car Rental agreement, filled in with the same booking: we rent under Blind Spot''s insurance, so it is part of your rental too. Press its **Download PDF** to read it.
4. Under Sign, tap **All four**: it ticks the four statements, which stay on screen to read.
5. Your full legal name is your signature. Prefer to sign with your finger or the mouse? Press **Draw instead**.
6. Press **Sign and continue to payment**. Your one signature signs both agreements; the signed copies are in Documents and in the email that confirms your booking.

![](/guides/img/renter-06-sign-ready-desktop-1eee20a4.jpg "desktop; size: 1440 1212; address: carmacars.ca/account/bookings/CC-10057/sign; pins: 3 59.0 8.9, 4 69.4 18.2, 5 90.3 78.5, 6 96.9 87.1")

## Signing with our staff

At pickup or at our desk, you can sign on a CarmaCars phone or tablet.

1. Our staff member checks your name and your original licence, then hands you the device.
2. Read the agreements, tick the statements and sign with your name or your finger. Then hand the device back.
3. It is the same signature as signing online. Prefer your own phone? Ask for the signing link by email or text.

## Pay to confirm

1. Check What you pay now. The refundable deposit is taken at pickup, not today.
2. Enter the Name on the card and the card details. Use a credit card in your own name.
3. Press **Pay $...** (the button shows the amount).

![](/guides/img/renter-07-pay-desktop-705896d6.jpg "desktop; size: 1440 1082; address: carmacars.ca/account/bookings/CC-10057/pay; pins: 7 70.5 21.9, 8 64.6 16.5, 9 64.6 96.4")

> Tip: Your card is authorized now and charged once the booking is confirmed. It becomes your Card on File for the deposit at pickup and any later charges you agreed to when you signed.

> Watch out: See "This car was just taken"? Someone confirmed the same car first. The authorization on your card is released, and we offer you another car or other dates.

## A rental we booked for you

Booked by phone, in person or through a partner? We add the rental and you sign it online.

1. You get an email: "Read and sign your rental agreement; your card is charged when you sign."
2. Open it. Check the car, the dates and the price, and read the agreement.
3. Press **Accept and sign**. If we have your card on file, it is charged at that moment, not before, and the agreement is countersigned by CarmaCars as soon as you sign.
',
  '<p class="gd-p">After you approve, you sign the rental agreement on screen and pay. It takes a few minutes on a phone or a computer; the signing itself is three taps.</p><section class="gd-task" id="sign-and-pay-sign-the-rental-agreement" data-gd-task><h2 class="gd-h2">Sign the rental agreement</h2><div class="gd-stepblock gd-stepblock--below"><div class="gd-stepcol"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">Fill in your home address and licence details. You do this once; we keep them for next time.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Press <b class="gd-ui">Save details</b>. The agreement then shows your details.</div></li></ol></div><figure class="gd-fig gd-fig--desk"><div class="gd-browser"><div class="gd-bar" aria-hidden="true"><i></i><i></i><i></i><span class="gd-addr">carmacars.ca/account/bookings/CC-10057/sign</span></div><div class="gd-imgwrap" style="aspect-ratio:1440/1052"><img src="/guides/img/renter-04-sign-details-desktop-bd193670.jpg" alt="" loading="lazy" decoding="async" width="1440" height="1052"><span class="gd-pin" style="left:44.4%;top:25.9%" aria-hidden="true">1</span><span class="gd-pin" style="left:16.3%;top:96.4%" aria-hidden="true">2</span></div></div></figure></div><div class="gd-stepblock gd-stepblock--below"><div class="gd-stepcol"><ol class="gd-ol" start="3"><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Check the key values at the top: the car, the dates, the deposit and the deductible. Open <b class="gd-ui">Read the full rental agreement</b> to read it word for word, or press <b class="gd-ui">Download PDF</b> to keep a copy. Below it is the Blind Spot Car Rental agreement, filled in with the same booking: we rent under Blind Spot&#39;s insurance, so it is part of your rental too. Press its <b class="gd-ui">Download PDF</b> to read it.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t">Under Sign, tap <b class="gd-ui">All four</b>: it ticks the four statements, which stay on screen to read.</div></li><li><span class="gd-n" aria-hidden="true">5</span><div class="gd-t">Your full legal name is your signature. Prefer to sign with your finger or the mouse? Press <b class="gd-ui">Draw instead</b>.</div></li><li><span class="gd-n" aria-hidden="true">6</span><div class="gd-t">Press <b class="gd-ui">Sign and continue to payment</b>. Your one signature signs both agreements; the signed copies are in Documents and in the email that confirms your booking.</div></li></ol></div><figure class="gd-fig gd-fig--desk"><div class="gd-browser"><div class="gd-bar" aria-hidden="true"><i></i><i></i><i></i><span class="gd-addr">carmacars.ca/account/bookings/CC-10057/sign</span></div><div class="gd-imgwrap" style="aspect-ratio:1440/1212"><img src="/guides/img/renter-06-sign-ready-desktop-1eee20a4.jpg" alt="" loading="lazy" decoding="async" width="1440" height="1212"><span class="gd-pin" style="left:59%;top:8.9%" aria-hidden="true">3</span><span class="gd-pin" style="left:69.4%;top:18.2%" aria-hidden="true">4</span><span class="gd-pin" style="left:90.3%;top:78.5%" aria-hidden="true">5</span><span class="gd-pin" style="left:96.9%;top:87.1%" aria-hidden="true">6</span></div></div></figure></div></section><section class="gd-task" id="sign-and-pay-signing-with-our-staff" data-gd-task><h2 class="gd-h2">Signing with our staff</h2><p class="gd-p">At pickup or at our desk, you can sign on a CarmaCars phone or tablet.</p><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">Our staff member checks your name and your original licence, then hands you the device.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Read the agreements, tick the statements and sign with your name or your finger. Then hand the device back.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">It is the same signature as signing online. Prefer your own phone? Ask for the signing link by email or text.</div></li></ol></div></section><section class="gd-task" id="sign-and-pay-pay-to-confirm" data-gd-task><h2 class="gd-h2">Pay to confirm</h2><div class="gd-stepblock gd-stepblock--below"><div class="gd-stepcol"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">Check What you pay now. The refundable deposit is taken at pickup, not today.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Enter the Name on the card and the card details. Use a credit card in your own name.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Press <b class="gd-ui">Pay $...</b> (the button shows the amount).</div></li></ol></div><figure class="gd-fig gd-fig--desk"><div class="gd-browser"><div class="gd-bar" aria-hidden="true"><i></i><i></i><i></i><span class="gd-addr">carmacars.ca/account/bookings/CC-10057/pay</span></div><div class="gd-imgwrap" style="aspect-ratio:1440/1082"><img src="/guides/img/renter-07-pay-desktop-705896d6.jpg" alt="" loading="lazy" decoding="async" width="1440" height="1082"><span class="gd-pin" style="left:70.5%;top:21.9%" aria-hidden="true">7</span><span class="gd-pin" style="left:64.6%;top:16.5%" aria-hidden="true">8</span><span class="gd-pin" style="left:64.6%;top:96.4%" aria-hidden="true">9</span></div></div></figure></div><aside class="gd-box"><span class="gd-lbl">Tip</span><div>Your card is authorized now and charged once the booking is confirmed. It becomes your Card on File for the deposit at pickup and any later charges you agreed to when you signed.</div></aside><aside class="gd-box gd-box--warn"><span class="gd-lbl">Watch out</span><div>See &quot;This car was just taken&quot;? Someone confirmed the same car first. The authorization on your card is released, and we offer you another car or other dates.</div></aside></section><section class="gd-task" id="sign-and-pay-a-rental-we-booked-for-you" data-gd-task><h2 class="gd-h2">A rental we booked for you</h2><p class="gd-p">Booked by phone, in person or through a partner? We add the rental and you sign it online.</p><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">You get an email: &quot;Read and sign your rental agreement; your card is charged when you sign.&quot;</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Open it. Check the car, the dates and the price, and read the agreement.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Press <b class="gd-ui">Accept and sign</b>. If we have your card on file, it is charged at that moment, not before, and the agreement is countersigned by CarmaCars as soon as you sign.</div></li></ol></div></section>');
select app.guide_release_section('renter', 'after-your-trip', 'chapter', 'during-your-trip', 'We check the car with you at the return. Your deposit balance comes back, and your receipts and agreement stay in your portal.

## The return and your deposit

- At the return we check the odometer, fuel or charge, keys and cleanliness, take photos and compare with pickup. You sign on our screen.
- We release the deposit balance after you return the car. If a toll, ticket or claim is still open, we may hold back what we expect it to cost for a while.
- Your statement appears under Documents.

## Review your rental

1. Open the trip under Past trips, then press **Review your rental**.
2. Tap the stars. Add a title and a few words if you like. Both are optional.
3. Tick **Show my review on the site with my first name** only if you agree to it being shown.
4. Press **Send my review**.

![](/guides/img/renter-14-review-desktop-c6c61830.jpg "desktop; size: 1440 672; address: carmacars.ca/account/bookings/CC-10058/review; pins: 2 25.0 33.6, 3 3.5 84.5, 4 18.1 92.4")

## Documents, notifications and profile

1. **Documents**: your agreements, receipts, statements and uploads. Press **View** or **Download**.
2. **Notifications**: notices from us. Use **Mark as read** or **Mark all as read**, and choose which optional emails you get.
3. **Profile**: your contact details (**Save**), drivers, your Card on File and your marketing choice.

![](/guides/img/renter-15-documents-desktop-fd428a63.jpg "desktop; size: 1440 560; address: carmacars.ca/account/documents; pins: 1 91.8 35.7")

> Tip: Your legal name is locked once you are verified. To change it or your email, call or message us.

## Sign in with your phone number

No password needed: we text you a 6-digit code from the CarmaCars number.

1. On `carmacars.ca/sign-in`, press **Use my phone number instead**.
2. Enter your mobile number and press **Text me a code**. Codes go to Canadian mobile numbers.
3. Type the 6-digit code from the text (on most phones it fills itself in), or press **Sign in**. The code works for 5 minutes; **Send a new code** after a minute if it did not arrive.
4. To sign in by phone every time, open **Profile**, press **Add and verify my phone number**, enter the code we text you, then choose **My phone number (a code by text)** under Sign in with. The sign-in page then opens on your phone number.

> Tip: New here? On Create account, press Sign up with my phone number instead: your name, your mobile number and the code. An account made by phone has no email yet: you can send requests, accept offers and sign, and the pay page asks for your email before your first payment, for the receipts. A booking request you sent earlier with the same mobile number is added to your account once the code is checked.

## Texts or email: how we reach you

Choose Email, Text or Both. Texts are short, come from the CarmaCars number and link to the page.

1. Open **Profile**. Under **Messages**, choose **Email**, **Text** or **Both**. It is saved at once.
2. Texts go to the phone you verified with a code (Sign-in, above). Until you verify one, we email you.
3. Signed agreements, statements and receipts are always emailed when we have your email. On Text you also get a text with a link to view or download them.
4. No texts from 9 pm to 8 am, except urgent ones such as a late return. Reply STOP to any text to stop texts (we confirm with one text); text START to turn them back on.

> Tip: You can also choose in the booking request (How should we reach you?) and when you sign up with your phone number, where Text is chosen for you.
', 'After your trip', 'The return, your deposit, reviews, documents and your profile.',
  'We check the car with you at the return. Your deposit balance comes back, and your receipts and agreement stay in your portal.

## The return and your deposit

- At the return we check the odometer, fuel or charge, keys and cleanliness, take photos and compare with pickup. You sign on our screen.
- The photo report of the pickup and the return is in your email, in Documents and on your booking (**Photo report**): the times, the kilometres, the fuel, every photo and any damage. A late return, kilometres over the allowance or less fuel than at pickup are charged from these readings.
- We release the deposit balance after you return the car. If a toll, ticket or claim is still open, we may hold back what we expect it to cost for a while.
- Your statement appears under Documents.

## Review your rental

1. Open the trip under Past trips, then press **Review your rental**.
2. Tap the stars. Add a title and a few words if you like. Both are optional.
3. Tick **Show my review on the site with my first name** only if you agree to it being shown.
4. Press **Send my review**.

![](/guides/img/renter-14-review-desktop-c6c61830.jpg "desktop; size: 1440 672; address: carmacars.ca/account/bookings/CC-10058/review; pins: 2 25.0 33.6, 3 3.5 84.5, 4 18.1 92.4")

## Documents, notifications and profile

1. **Documents**: your agreements, receipts, statements and uploads. Press **View** or **Download**.
2. **Notifications**: notices from us. Use **Mark as read** or **Mark all as read**, and choose which optional emails you get.
3. **Profile**: your contact details (**Save**), drivers, your Card on File and your marketing choice.

![](/guides/img/renter-15-documents-desktop-fd428a63.jpg "desktop; size: 1440 560; address: carmacars.ca/account/documents; pins: 1 91.8 35.7")

> Tip: Your legal name is locked once you are verified. To change it or your email, call or message us.

## Sign in with your phone number

No password needed: we text you a 6-digit code from the CarmaCars number.

1. On `carmacars.ca/sign-in`, press **Use my phone number instead**.
2. Enter your mobile number and press **Text me a code**. Codes go to Canadian mobile numbers.
3. Type the 6-digit code from the text (on most phones it fills itself in), or press **Sign in**. The code works for 5 minutes; **Send a new code** after a minute if it did not arrive.
4. To sign in by phone every time, open **Profile**, press **Add and verify my phone number**, enter the code we text you, then choose **My phone number (a code by text)** under Sign in with. The sign-in page then opens on your phone number.

> Tip: New here? On Create account, press Sign up with my phone number instead: your name, your mobile number and the code. An account made by phone has no email yet: you can send requests, accept offers and sign, and the pay page asks for your email before your first payment, for the receipts. A booking request you sent earlier with the same mobile number is added to your account once the code is checked.

## Texts or email: how we reach you

Choose Email, Text or Both. Texts are short, come from the CarmaCars number and link to the page.

1. Open **Profile**. Under **Messages**, choose **Email**, **Text** or **Both**. It is saved at once.
2. Texts go to the phone you verified with a code (Sign-in, above). Until you verify one, we email you.
3. Signed agreements, statements and receipts are always emailed when we have your email. On Text you also get a text with a link to view or download them.
4. No texts from 9 pm to 8 am, except urgent ones such as a late return. Reply STOP to any text to stop texts (we confirm with one text); text START to turn them back on.

> Tip: You can also choose in the booking request (How should we reach you?) and when you sign up with your phone number, where Text is chosen for you.
',
  '<p class="gd-p">We check the car with you at the return. Your deposit balance comes back, and your receipts and agreement stay in your portal.</p><section class="gd-task" id="after-your-trip-the-return-and-your-deposit" data-gd-task><h2 class="gd-h2">The return and your deposit</h2><ul class="gd-ul"><li>At the return we check the odometer, fuel or charge, keys and cleanliness, take photos and compare with pickup. You sign on our screen.</li><li>The photo report of the pickup and the return is in your email, in Documents and on your booking (<b class="gd-ui">Photo report</b>): the times, the kilometres, the fuel, every photo and any damage. A late return, kilometres over the allowance or less fuel than at pickup are charged from these readings.</li><li>We release the deposit balance after you return the car. If a toll, ticket or claim is still open, we may hold back what we expect it to cost for a while.</li><li>Your statement appears under Documents.</li></ul></section><section class="gd-task" id="after-your-trip-review-your-rental" data-gd-task><h2 class="gd-h2">Review your rental</h2><div class="gd-stepblock gd-stepblock--below"><div class="gd-stepcol"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">Open the trip under Past trips, then press <b class="gd-ui">Review your rental</b>.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Tap the stars. Add a title and a few words if you like. Both are optional.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Tick <b class="gd-ui">Show my review on the site with my first name</b> only if you agree to it being shown.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t">Press <b class="gd-ui">Send my review</b>.</div></li></ol></div><figure class="gd-fig gd-fig--desk"><div class="gd-browser"><div class="gd-bar" aria-hidden="true"><i></i><i></i><i></i><span class="gd-addr">carmacars.ca/account/bookings/CC-10058/review</span></div><div class="gd-imgwrap" style="aspect-ratio:1440/672"><img src="/guides/img/renter-14-review-desktop-c6c61830.jpg" alt="" loading="lazy" decoding="async" width="1440" height="672"><span class="gd-pin" style="left:25%;top:33.6%" aria-hidden="true">2</span><span class="gd-pin" style="left:3.5%;top:84.5%" aria-hidden="true">3</span><span class="gd-pin" style="left:18.1%;top:92.4%" aria-hidden="true">4</span></div></div></figure></div></section><section class="gd-task" id="after-your-trip-documents-notifications-and-profile" data-gd-task><h2 class="gd-h2">Documents, notifications and profile</h2><div class="gd-stepblock gd-stepblock--below"><div class="gd-stepcol"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t"><b class="gd-ui">Documents</b>: your agreements, receipts, statements and uploads. Press <b class="gd-ui">View</b> or <b class="gd-ui">Download</b>.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t"><b class="gd-ui">Notifications</b>: notices from us. Use <b class="gd-ui">Mark as read</b> or <b class="gd-ui">Mark all as read</b>, and choose which optional emails you get.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t"><b class="gd-ui">Profile</b>: your contact details (<b class="gd-ui">Save</b>), drivers, your Card on File and your marketing choice.</div></li></ol></div><figure class="gd-fig gd-fig--desk"><div class="gd-browser"><div class="gd-bar" aria-hidden="true"><i></i><i></i><i></i><span class="gd-addr">carmacars.ca/account/documents</span></div><div class="gd-imgwrap" style="aspect-ratio:1440/560"><img src="/guides/img/renter-15-documents-desktop-fd428a63.jpg" alt="" loading="lazy" decoding="async" width="1440" height="560"><span class="gd-pin" style="left:91.8%;top:35.7%" aria-hidden="true">1</span></div></div></figure></div><aside class="gd-box"><span class="gd-lbl">Tip</span><div>Your legal name is locked once you are verified. To change it or your email, call or message us.</div></aside></section><section class="gd-task" id="after-your-trip-sign-in-with-your-phone-number" data-gd-task><h2 class="gd-h2">Sign in with your phone number</h2><p class="gd-p">No password needed: we text you a 6-digit code from the CarmaCars number.</p><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">On <span class="gd-url">carmacars.ca/sign-in</span>, press <b class="gd-ui">Use my phone number instead</b>.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Enter your mobile number and press <b class="gd-ui">Text me a code</b>. Codes go to Canadian mobile numbers.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Type the 6-digit code from the text (on most phones it fills itself in), or press <b class="gd-ui">Sign in</b>. The code works for 5 minutes; <b class="gd-ui">Send a new code</b> after a minute if it did not arrive.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t">To sign in by phone every time, open <b class="gd-ui">Profile</b>, press <b class="gd-ui">Add and verify my phone number</b>, enter the code we text you, then choose <b class="gd-ui">My phone number (a code by text)</b> under Sign in with. The sign-in page then opens on your phone number.</div></li></ol></div><aside class="gd-box"><span class="gd-lbl">Tip</span><div>New here? On Create account, press Sign up with my phone number instead: your name, your mobile number and the code. An account made by phone has no email yet: you can send requests, accept offers and sign, and the pay page asks for your email before your first payment, for the receipts. A booking request you sent earlier with the same mobile number is added to your account once the code is checked.</div></aside></section><section class="gd-task" id="after-your-trip-texts-or-email-how-we-reach-you" data-gd-task><h2 class="gd-h2">Texts or email: how we reach you</h2><p class="gd-p">Choose Email, Text or Both. Texts are short, come from the CarmaCars number and link to the page.</p><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">Open <b class="gd-ui">Profile</b>. Under <b class="gd-ui">Messages</b>, choose <b class="gd-ui">Email</b>, <b class="gd-ui">Text</b> or <b class="gd-ui">Both</b>. It is saved at once.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Texts go to the phone you verified with a code (Sign-in, above). Until you verify one, we email you.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Signed agreements, statements and receipts are always emailed when we have your email. On Text you also get a text with a link to view or download them.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t">No texts from 9 pm to 8 am, except urgent ones such as a late return. Reply STOP to any text to stop texts (we confirm with one text); text START to turn them back on.</div></li></ol></div><aside class="gd-box"><span class="gd-lbl">Tip</span><div>You can also choose in the booking request (How should we reach you?) and when you sign up with your phone number, where Text is chosen for you.</div></aside></section>');
select app.guide_release_section('admin', 'requests-offers-and-bookings', 'chapter', 'people-and-access', 'A booking starts as a request from the website, or as an offer you send yourself to a customer on the phone. You check it, adjust it and send the offer; an offer that is out is changed in place. After that, the booking page holds the money, documents, changes and history.

## The request queue

Open **Bookings** > **Requests**. The oldest waiting request is at the top.

1. Filter by New, Waiting on the renter, Pushed back, Offer out, Signing and payment, or Offer expired.
2. Waiting shows how long the renter has waited; red means past the first reply target (5 minutes, set in Program settings). Open a booking number to answer it.

![](/guides/img/admin-02-requests-desktop-6521282d.jpg "desktop; size: 1440 820; address: carmacars.ca/admin/requests; pins: 1 18.5 21.2, 2 25.3 31.7")

> Good to know: A request whose pickup time passes without an offer expires by itself, with a note in its history. The renter is not emailed unless "Email the renter when their request expires that way" is on in Program settings.

## Answer a request with an offer

1. The Review and offer tab shows the request as the renter sent it.
2. Adjust the car, the dates, the rate type, the places, the rates and fees, the deposit and extras.
3. Price on the right updates as you change things.
4. Add a message, choose how long the offer stays open, then press **Send the offer**.

![](/guides/img/admin-03-booking-review-desktop-84570463.jpg "desktop; size: 1440 1060; address: carmacars.ca/admin/bookings/CC-10056?tab=review; pins: 1 21.7 16.4, 2 20.0 45.4, 3 65.0 45.4, 4 96.5 98.8")

5. Changed fields but not ready to send? Press **Save changes**. The panel "The offer as the renter sees it" shows the result.
6. Can''t do it? Press **Decline** and fill in Reason and any alternative.
7. Need an answer first? Press **Ask the renter** to send a question.

![](/guides/img/admin-03-booking-review-desktop-1139f8f9.jpg "desktop; size: 620 810; address: carmacars.ca/admin/bookings/CC-10056?tab=review; pins: 5 91.9 33.6")

## Send an offer without a request

**Bookings** > **Send an offer**, or **Send an offer** on Bookings and on Requests. For a customer on the phone, by text or at the counter: no request needed.

1. The customer: type a name, phone or email and choose them. Not on file? Press **Add a new customer**: full legal name, mobile, email (the offer link goes there) and date of birth. A customer already on file with the same email or phone is shown with Use: one person, one record.
2. The car and the dates: type the car code, plate or name, or choose from the list; each car says Free or Not free for the dates. Then the pickup and return places (our location, delivery with the address and distance, airport).
3. The price: the Rate sheet, A total for the whole rental, or A rate per day (times the days). A price typed by hand needs its reason and can be plus tax or tax included. Set the kilometres, a promo code, the deposit, a discount and each fee (an Admin), and how damage is covered: with option 3 the Protection Plan price is the one the renter pays.
4. How it is paid: the rental by card online (the usual way), e-Transfer, cash, cheque, bank transfer, platform payout or the insurer; the deposit by card hold, cash, e-Transfer or no deposit (an Admin).
5. Who found this client, the message to the renter, how long the offer is open, and how the link goes: Email, Text, both or neither.
6. The right side is the offer as the renter will see it, priced by the database as you type. Press **Send the offer**. **Save without sending** keeps it as a request for later.

> Good to know: It makes the same request and offer the website makes: the renter approves, signs and pays (or you record the payment), and only then is the car on the calendar. No "request received" email goes to the renter for an offer you send. Staff commissions and statements count it like any other booking.

## Change an offer that is out

The renter has the offer (Offered), or approved it and has not paid (Signing and payment). Press **Edit the offer** on the booking.

1. Change anything: the car, the dates, the places, the price, fees, the deposit, add-ons, how it is paid. Each changed field is highlighted and the before and after are listed.
2. Write what changed in Message to the renter and choose how long the offer is open.
3. Press **Save and send the update**: the renter gets the new version by email or text (ticked), and the old version no longer counts. Or press **Save without telling the renter** and tell them yourself.
4. A confirmed booking is changed with **Change the booking** (Propose a change, below).

> Tip: No need to withdraw first. **Withdraw the offer** is only for taking it back for good; **Send again, later expiry** gives the renter more time, and **Renter approved by phone** records a yes given on a call.

## Payments by part: the rental, the deposit and later charges

On the booking''s Money tab, Money by part shows what is still open for the rental, the fees and later charges, the deposit and the card on file. Each part is paid its own way, in any mix: for example the deposit in cash and the rental by card.

1. **Record a payment**: choose what it is for (the rental, fees, the deposit or a later charge) and how it was paid (e-Transfer, cash, cheque, bank transfer, platform payout, the insurer). An e-Transfer, cheque or transfer needs its reference. Press **Record it**. The renter gets a receipt; **Print** prints one to hand over.
2. **Collect a card**: a payment, the deposit hold or saving the card. The renter types the card in Stripe''s secure form: on this device (**Open the card form**, then hand it over) or by a link texted or emailed to them (**Send the link**). Staff never type a card number.
3. A deposit hold lasts about 7 days and shows the days left. After the return, **Capture the hold** (all or part, with the reason) or **Release the hold**.
4. **Charge the saved card** (Finance or an Admin): extra kilometres, fuel, damage or a late return, with the reason the renter''s receipt shows. For a rental over 7 days, save the card and charge the deposit this way.
5. An offer paid another way: once the renter approved and signed and the money is recorded, the booking is confirmed (or press **Confirm the booking**).
6. A deposit taken in cash or by e-Transfer is given back the same way after the return: Finance gets a task; press **Returned** with the reference or receipt number.

> Good to know: Statements, reconciliation and the deposit settlement read each payment with its method: a cash deposit is never refunded to a card.

## A booking

Open **Bookings** > **Bookings**, then a booking number. Or type the number in the search box.

1. Tabs: Overview, Money, Changes, History, and Drivers and documents.
2. Overview shows the trip, the renter, what is still missing for the handover, and the price.
3. Open tasks for this booking, with the queue and the due time.
4. Top right: **Stop blocking the calendar**, **Cancel for the renter** and **Cancel by CarmaCars**.

![](/guides/img/admin-04-booking-desktop-b56b668a.jpg "desktop; size: 1440 960; address: carmacars.ca/admin/bookings/CC-10057; pins: 1 20.1 24.0, 2 34.7 58.3, 3 20.1 72.9, 4 90.3 18.3")

## Renter documents: licence and proof of coverage

A renter''s licence photos, selfie and proof of coverage (OPCF 27 or a credit card''s rental coverage) are checked before the handover. You check them yourself; no task is needed.

1. A booking with documents waiting is a line on To do: "Check ''s documents for booking ", marked Now when the pickup is within two days. Press **Review documents**.
2. The pop-up shows each driver''s images and the coverage: the insurer, policy number and expiry, or the card, its type and whether the name matches.
3. Tick the checks, then **Approve**. Or type the reason the renter reads and press **Reject**: they are asked for a new one.
4. The same pop-up is on the booking: the card Renter documents (**Review documents**) on Overview and on Drivers and documents.

> Tip: Each opening of a renter''s documents is logged. The links to the images last one minute.

## Propose a change to a confirmed booking

The renter gets an email and answers on their booking. The calendar moves only when they accept.

1. Open the booking''s Changes tab. Under Propose a change, set the new pickup, return or car.
2. To price it by hand, type a New rental charge before tax. Leave it empty to use the car''s rates.
3. Write the Reason, for the renter. They read it.
4. Press **Preview the price**, then **Send to the renter**.

![](/guides/img/admin-05-booking-changes-desktop-0b06af9a.jpg "desktop; size: 1230 530; address: carmacars.ca/admin/bookings/CC-10057?tab=changes; pins: 1 12.9 15.3, 2 35.0 30.6, 3 49.8 59.1, 4 30.9 73.2")

## Who a booking is credited to

Overview (and Review and offer) shows the Sales credit: the staff member the booking counts for in their sales.

1. A quote or a rental is credited to whoever created or added it. A request from the website is credited to whoever sent its first offer.
2. To give it to someone else, press **Reassign**, choose who (or Nobody), say whether they sourced the client and write the reason. The booking''s history and the audit log keep it, and the deal stays in the same week and month.
3. Sourced means the staff member chose I sourced this client when they entered it, it came with a field staff referral link, or you credited it. Only a sourced booking earns a staff commission. A website request earns none unless you credit someone.
4. Someone said they sourced a website request? The credit line shows the claim: press **Credit them** or **Not theirs**, with a reason.
5. A price typed by hand shows beside the rate-sheet price, with the reason. A price under the floor or past the discount limit is flagged: press **Mark reviewed** once you have looked at it.

> Tip: The renter has 48 hours to accept (and sign the amendment) or decline, with one reminder. Any extra is charged to their Card on File; a lower price raises a refund for your approval.
', 'Requests, offers and bookings', 'Send an offer with or without a request, change it in place, take payments by part, run a booking, propose a change.',
  'A booking starts as a request from the website, or as an offer you send yourself to a customer on the phone. You check it, adjust it and send the offer; an offer that is out is changed in place. After that, the booking page holds the money, documents, changes and history.

## The request queue

Open **Bookings** > **Requests**. The oldest waiting request is at the top.

1. Filter by New, Waiting on the renter, Pushed back, Offer out, Signing and payment, or Offer expired.
2. Waiting shows how long the renter has waited; red means past the first reply target (5 minutes, set in Program settings). Open a booking number to answer it.

![](/guides/img/admin-02-requests-desktop-6521282d.jpg "desktop; size: 1440 820; address: carmacars.ca/admin/requests; pins: 1 18.5 21.2, 2 25.3 31.7")

> Good to know: A request whose pickup time passes without an offer expires by itself, with a note in its history. The renter is not emailed unless "Email the renter when their request expires that way" is on in Program settings.

## Answer a request with an offer

1. The Review and offer tab shows the request as the renter sent it.
2. Adjust the car, the dates, the rate type, the places, the rates and fees, the deposit and extras.
3. Price on the right updates as you change things.
4. Add a message, choose how long the offer stays open, then press **Send the offer**.

![](/guides/img/admin-03-booking-review-desktop-84570463.jpg "desktop; size: 1440 1060; address: carmacars.ca/admin/bookings/CC-10056?tab=review; pins: 1 21.7 16.4, 2 20.0 45.4, 3 65.0 45.4, 4 96.5 98.8")

5. Changed fields but not ready to send? Press **Save changes**. The panel "The offer as the renter sees it" shows the result.
6. Can''t do it? Press **Decline** and fill in Reason and any alternative.
7. Need an answer first? Press **Ask the renter** to send a question.

![](/guides/img/admin-03-booking-review-desktop-1139f8f9.jpg "desktop; size: 620 810; address: carmacars.ca/admin/bookings/CC-10056?tab=review; pins: 5 91.9 33.6")

## Send an offer without a request

**Bookings** > **Send an offer**, or **Send an offer** on Bookings and on Requests. For a customer on the phone, by text or at the counter: no request needed.

1. The customer: type a name, phone or email and choose them. Not on file? Press **Add a new customer**: full legal name, mobile, email (the offer link goes there) and date of birth. A customer already on file with the same email or phone is shown with Use: one person, one record.
2. The car and the dates: type the car code, plate or name, or choose from the list; each car says Free or Not free for the dates. Then the pickup and return places (our location, delivery with the address and distance, airport).
3. The price: the Rate sheet, A total for the whole rental, or A rate per day (times the days). A price typed by hand needs its reason and can be plus tax or tax included. Set the kilometres, a promo code, the deposit, a discount and each fee (an Admin), and how damage is covered: with option 3 the Protection Plan price is the one the renter pays.
4. How it is paid: the rental by card online (the usual way), e-Transfer, cash, cheque, bank transfer, platform payout or the insurer; the deposit by card hold, cash, e-Transfer or no deposit (an Admin).
5. Who found this client, the message to the renter, how long the offer is open, and how the link goes: Email, Text, both or neither.
6. The right side is the offer as the renter will see it, priced by the database as you type. Press **Send the offer**. **Save without sending** keeps it as a request for later.

> Good to know: It makes the same request and offer the website makes: the renter approves, signs and pays (or you record the payment), and only then is the car on the calendar. No "request received" email goes to the renter for an offer you send. Staff commissions and statements count it like any other booking.

## Change an offer that is out

The renter has the offer (Offered), or approved it and has not paid (Signing and payment). Press **Edit the offer** on the booking.

1. Change anything: the car, the dates, the places, the price, fees, the deposit, add-ons, how it is paid. Each changed field is highlighted and the before and after are listed.
2. Write what changed in Message to the renter and choose how long the offer is open.
3. Press **Save and send the update**: the renter gets the new version by email or text (ticked), and the old version no longer counts. Or press **Save without telling the renter** and tell them yourself.
4. A confirmed booking is changed with **Change the booking** (Propose a change, below).

> Tip: No need to withdraw first. **Withdraw the offer** is only for taking it back for good; **Send again, later expiry** gives the renter more time, and **Renter approved by phone** records a yes given on a call.

## Payments by part: the rental, the deposit and later charges

On the booking''s Money tab, Money by part shows what is still open for the rental, the fees and later charges, the deposit and the card on file. Each part is paid its own way, in any mix: for example the deposit in cash and the rental by card.

1. **Record a payment**: choose what it is for (the rental, fees, the deposit or a later charge) and how it was paid (e-Transfer, cash, cheque, bank transfer, platform payout, the insurer). An e-Transfer, cheque or transfer needs its reference. Press **Record it**. The renter gets a receipt; **Print** prints one to hand over.
2. **Collect a card**: a payment, the deposit hold or saving the card. The renter types the card in Stripe''s secure form: on this device (**Open the card form**, then hand it over) or by a link texted or emailed to them (**Send the link**). Staff never type a card number.
3. A deposit hold lasts about 7 days and shows the days left. After the return, **Capture the hold** (all or part, with the reason) or **Release the hold**.
4. **Charge the saved card** (Finance or an Admin): extra kilometres, fuel, damage or a late return, with the reason the renter''s receipt shows. For a rental over 7 days, save the card and charge the deposit this way.
5. An offer paid another way: once the renter approved and signed and the money is recorded, the booking is confirmed (or press **Confirm the booking**).
6. A deposit taken in cash or by e-Transfer is given back the same way after the return: Finance gets a task; press **Returned** with the reference or receipt number.

> Good to know: Statements, reconciliation and the deposit settlement read each payment with its method: a cash deposit is never refunded to a card.

## A booking

Open **Bookings** > **Bookings**, then a booking number. Or type the number in the search box.

1. Tabs: Overview, Money, Changes, History, and Drivers and documents.
2. Overview shows the trip, the renter, what is still missing for the handover, and the price.
3. Open tasks for this booking, with the queue and the due time.
4. Top right: **Stop blocking the calendar**, **Cancel for the renter** and **Cancel by CarmaCars**.

![](/guides/img/admin-04-booking-desktop-b56b668a.jpg "desktop; size: 1440 960; address: carmacars.ca/admin/bookings/CC-10057; pins: 1 20.1 24.0, 2 34.7 58.3, 3 20.1 72.9, 4 90.3 18.3")

## Check a car out or in

From the booking, with your phone or a tablet: the same checklist field staff use.

1. A confirmed booking shows **Check out (pickup)** under Check-out, check-in and signing; a booking on rent shows **Check in (return)**. Today lists the check-outs and check-ins due, each with **Check out** or **Check in**.
2. The checklist opens: the ready check, the renter and their licence and card, the odometer (km) and fuel or charge, the keys, the photo set (every side, the wheels, the interior, the odometer and fuel gauge, the plate), damage marks with close-ups, then the renter and you sign.
3. Photos wait on the device without a connection and upload in the background. Each keeps its time, and the place when the device allows location.
4. A field job of the booking is taken over (the history says so); with no job, one is made for you. When done, press **See the photo report**.

> Tip: Fleet, Sales and Customer service check cars out and in the same way from their own booking page.

## The photo report, late returns and the return charges

Under Check-out, check-in and signing, press **Photo report**.

1. The report shows the due-back time, the actual check-out and check-in, Late by (or Overdue by while the car is out), the odometer and kilometres over the allowance, the fuel or charge out and in, every photo with its time and place, and the damage.
2. At check-in the late return (after the grace period of the fee defaults), the mileage overage and the fuel or recharging are written to the return charges at once. A gas car with no pump receipt is priced at the refill price per eighth (Program settings) plus the markup until the receipt is entered.
3. Not charging one? Press **Waive** beside it and give the reason: it stays waived if the charges are worked out again.
4. The time was wrong? Press **Correct the check-in time** (or the check-out time) with the reason: lateness and the late charges follow, and the history keeps both times.
5. The renter gets the same report (without these buttons) by email and in their Documents. Late by shows on the booking and in the Bookings list.

## Signatures on the spot, or by link

The renter or an additional driver signs the rental agreement on your device, or on their own phone.

1. While a signature is missing, the booking shows **Sign now on this device**, **Email the signing link** and **Text the signing link**.
2. **Sign now on this device**: confirm the name matches their licence and that you saw the original licence (photograph it if none is on file), then press **Hand the device to** and their name.
3. They read both agreements (CarmaCars'' and Blind Spot''s), tick the statements and sign. Then **Back to the staff view** for the next signer.
4. The record is the same as signing online, and says it was signed in person, collected by you, on your device. It is printed on the signed copy''s signature record page.

## The licence before an offer is accepted

Front, back and a selfie, from the request on.

1. After sending a request the renter is asked for their licence. A licence already on file from an earlier booking is used again while it is valid after the return.
2. The offer cannot be accepted (by the renter, or by you on their word) and nothing is paid until the licence and its expiry date are on file.
3. Review the images as usual with **Review documents**: the card Renter documents is on Review and offer too.
4. The switch is in **Settings** > **Program settings**, Booking requests and offers: Booking licence required (on), with the selfie (on).

## Renter documents: licence and proof of coverage

A renter''s licence photos, selfie and proof of coverage (OPCF 27 or a credit card''s rental coverage) are checked before the handover. You check them yourself; no task is needed.

1. A booking with documents waiting is a line on To do: "Check ''s documents for booking ", marked Now when the pickup is within two days. Press **Review documents**.
2. The pop-up shows each driver''s images and the coverage: the insurer, policy number and expiry, or the card, its type and whether the name matches.
3. Tick the checks, then **Approve**. Or type the reason the renter reads and press **Reject**: they are asked for a new one.
4. The same pop-up is on the booking: the card Renter documents (**Review documents**) on Overview and on Drivers and documents.

> Tip: Each opening of a renter''s documents is logged. The links to the images last one minute.

## Propose a change to a confirmed booking

The renter gets an email and answers on their booking. The calendar moves only when they accept.

1. Open the booking''s Changes tab. Under Propose a change, set the new pickup, return or car.
2. To price it by hand, type a New rental charge before tax. Leave it empty to use the car''s rates.
3. Write the Reason, for the renter. They read it.
4. Press **Preview the price**, then **Send to the renter**.

![](/guides/img/admin-05-booking-changes-desktop-0b06af9a.jpg "desktop; size: 1230 530; address: carmacars.ca/admin/bookings/CC-10057?tab=changes; pins: 1 12.9 15.3, 2 35.0 30.6, 3 49.8 59.1, 4 30.9 73.2")

## Who a booking is credited to

Overview (and Review and offer) shows the Sales credit: the staff member the booking counts for in their sales.

1. A quote or a rental is credited to whoever created or added it. A request from the website is credited to whoever sent its first offer.
2. To give it to someone else, press **Reassign**, choose who (or Nobody), say whether they sourced the client and write the reason. The booking''s history and the audit log keep it, and the deal stays in the same week and month.
3. Sourced means the staff member chose I sourced this client when they entered it, it came with a field staff referral link, or you credited it. Only a sourced booking earns a staff commission. A website request earns none unless you credit someone.
4. Someone said they sourced a website request? The credit line shows the claim: press **Credit them** or **Not theirs**, with a reason.
5. A price typed by hand shows beside the rate-sheet price, with the reason. A price under the floor or past the discount limit is flagged: press **Mark reviewed** once you have looked at it.

> Tip: The renter has 48 hours to accept (and sign the amendment) or decline, with one reminder. Any extra is charged to their Card on File; a lower price raises a refund for your approval.
',
  '<p class="gd-p">A booking starts as a request from the website, or as an offer you send yourself to a customer on the phone. You check it, adjust it and send the offer; an offer that is out is changed in place. After that, the booking page holds the money, documents, changes and history.</p><section class="gd-task" id="requests-offers-and-bookings-the-request-queue" data-gd-task><h2 class="gd-h2">The request queue</h2><p class="gd-p">Open <b class="gd-ui">Bookings</b> &gt; <b class="gd-ui">Requests</b>. The oldest waiting request is at the top.</p><div class="gd-stepblock gd-stepblock--below"><div class="gd-stepcol"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">Filter by New, Waiting on the renter, Pushed back, Offer out, Signing and payment, or Offer expired.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Waiting shows how long the renter has waited; red means past the first reply target (5 minutes, set in Program settings). Open a booking number to answer it.</div></li></ol></div><figure class="gd-fig gd-fig--desk"><div class="gd-browser"><div class="gd-bar" aria-hidden="true"><i></i><i></i><i></i><span class="gd-addr">carmacars.ca/admin/requests</span></div><div class="gd-imgwrap" style="aspect-ratio:1440/820"><img src="/guides/img/admin-02-requests-desktop-6521282d.jpg" alt="" loading="lazy" decoding="async" width="1440" height="820"><span class="gd-pin" style="left:18.5%;top:21.2%" aria-hidden="true">1</span><span class="gd-pin" style="left:25.3%;top:31.7%" aria-hidden="true">2</span></div></div></figure></div><aside class="gd-box"><span class="gd-lbl">Good to know</span><div>A request whose pickup time passes without an offer expires by itself, with a note in its history. The renter is not emailed unless &quot;Email the renter when their request expires that way&quot; is on in Program settings.</div></aside></section><section class="gd-task" id="requests-offers-and-bookings-answer-a-request-with-an-offer" data-gd-task><h2 class="gd-h2">Answer a request with an offer</h2><div class="gd-stepblock gd-stepblock--below"><div class="gd-stepcol"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">The Review and offer tab shows the request as the renter sent it.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Adjust the car, the dates, the rate type, the places, the rates and fees, the deposit and extras.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Price on the right updates as you change things.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t">Add a message, choose how long the offer stays open, then press <b class="gd-ui">Send the offer</b>.</div></li></ol></div><figure class="gd-fig gd-fig--desk"><div class="gd-browser"><div class="gd-bar" aria-hidden="true"><i></i><i></i><i></i><span class="gd-addr">carmacars.ca/admin/bookings/CC-10056?tab=review</span></div><div class="gd-imgwrap" style="aspect-ratio:1440/1060"><img src="/guides/img/admin-03-booking-review-desktop-84570463.jpg" alt="" loading="lazy" decoding="async" width="1440" height="1060"><span class="gd-pin" style="left:21.7%;top:16.4%" aria-hidden="true">1</span><span class="gd-pin" style="left:20%;top:45.4%" aria-hidden="true">2</span><span class="gd-pin" style="left:65%;top:45.4%" aria-hidden="true">3</span><span class="gd-pin" style="left:96.5%;top:98.8%" aria-hidden="true">4</span></div></div></figure></div><div class="gd-stepblock gd-stepblock--below"><div class="gd-stepcol"><ol class="gd-ol" start="5"><li><span class="gd-n" aria-hidden="true">5</span><div class="gd-t">Changed fields but not ready to send? Press <b class="gd-ui">Save changes</b>. The panel &quot;The offer as the renter sees it&quot; shows the result.</div></li><li><span class="gd-n" aria-hidden="true">6</span><div class="gd-t">Can&#39;t do it? Press <b class="gd-ui">Decline</b> and fill in Reason and any alternative.</div></li><li><span class="gd-n" aria-hidden="true">7</span><div class="gd-t">Need an answer first? Press <b class="gd-ui">Ask the renter</b> to send a question.</div></li></ol></div><figure class="gd-fig gd-fig--desk"><div class="gd-browser"><div class="gd-bar" aria-hidden="true"><i></i><i></i><i></i><span class="gd-addr">carmacars.ca/admin/bookings/CC-10056?tab=review</span></div><div class="gd-imgwrap" style="aspect-ratio:620/810"><img src="/guides/img/admin-03-booking-review-desktop-1139f8f9.jpg" alt="" loading="lazy" decoding="async" width="620" height="810"><span class="gd-pin" style="left:91.9%;top:33.6%" aria-hidden="true">5</span></div></div></figure></div></section><section class="gd-task" id="requests-offers-and-bookings-send-an-offer-without-a-request" data-gd-task><h2 class="gd-h2">Send an offer without a request</h2><p class="gd-p"><b class="gd-ui">Bookings</b> &gt; <b class="gd-ui">Send an offer</b>, or <b class="gd-ui">Send an offer</b> on Bookings and on Requests. For a customer on the phone, by text or at the counter: no request needed.</p><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">The customer: type a name, phone or email and choose them. Not on file? Press <b class="gd-ui">Add a new customer</b>: full legal name, mobile, email (the offer link goes there) and date of birth. A customer already on file with the same email or phone is shown with Use: one person, one record.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">The car and the dates: type the car code, plate or name, or choose from the list; each car says Free or Not free for the dates. Then the pickup and return places (our location, delivery with the address and distance, airport).</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">The price: the Rate sheet, A total for the whole rental, or A rate per day (times the days). A price typed by hand needs its reason and can be plus tax or tax included. Set the kilometres, a promo code, the deposit, a discount and each fee (an Admin), and how damage is covered: with option 3 the Protection Plan price is the one the renter pays.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t">How it is paid: the rental by card online (the usual way), e-Transfer, cash, cheque, bank transfer, platform payout or the insurer; the deposit by card hold, cash, e-Transfer or no deposit (an Admin).</div></li><li><span class="gd-n" aria-hidden="true">5</span><div class="gd-t">Who found this client, the message to the renter, how long the offer is open, and how the link goes: Email, Text, both or neither.</div></li><li><span class="gd-n" aria-hidden="true">6</span><div class="gd-t">The right side is the offer as the renter will see it, priced by the database as you type. Press <b class="gd-ui">Send the offer</b>. <b class="gd-ui">Save without sending</b> keeps it as a request for later.</div></li></ol></div><aside class="gd-box"><span class="gd-lbl">Good to know</span><div>It makes the same request and offer the website makes: the renter approves, signs and pays (or you record the payment), and only then is the car on the calendar. No &quot;request received&quot; email goes to the renter for an offer you send. Staff commissions and statements count it like any other booking.</div></aside></section><section class="gd-task" id="requests-offers-and-bookings-change-an-offer-that-is-out" data-gd-task><h2 class="gd-h2">Change an offer that is out</h2><p class="gd-p">The renter has the offer (Offered), or approved it and has not paid (Signing and payment). Press <b class="gd-ui">Edit the offer</b> on the booking.</p><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">Change anything: the car, the dates, the places, the price, fees, the deposit, add-ons, how it is paid. Each changed field is highlighted and the before and after are listed.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Write what changed in Message to the renter and choose how long the offer is open.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Press <b class="gd-ui">Save and send the update</b>: the renter gets the new version by email or text (ticked), and the old version no longer counts. Or press <b class="gd-ui">Save without telling the renter</b> and tell them yourself.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t">A confirmed booking is changed with <b class="gd-ui">Change the booking</b> (Propose a change, below).</div></li></ol></div><aside class="gd-box"><span class="gd-lbl">Tip</span><div>No need to withdraw first. <b class="gd-ui">Withdraw the offer</b> is only for taking it back for good; <b class="gd-ui">Send again, later expiry</b> gives the renter more time, and <b class="gd-ui">Renter approved by phone</b> records a yes given on a call.</div></aside></section><section class="gd-task" id="requests-offers-and-bookings-payments-by-part-the-rental-the-deposit-and-later-charges" data-gd-task><h2 class="gd-h2">Payments by part: the rental, the deposit and later charges</h2><p class="gd-p">On the booking&#39;s Money tab, Money by part shows what is still open for the rental, the fees and later charges, the deposit and the card on file. Each part is paid its own way, in any mix: for example the deposit in cash and the rental by card.</p><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t"><b class="gd-ui">Record a payment</b>: choose what it is for (the rental, fees, the deposit or a later charge) and how it was paid (e-Transfer, cash, cheque, bank transfer, platform payout, the insurer). An e-Transfer, cheque or transfer needs its reference. Press <b class="gd-ui">Record it</b>. The renter gets a receipt; <b class="gd-ui">Print</b> prints one to hand over.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t"><b class="gd-ui">Collect a card</b>: a payment, the deposit hold or saving the card. The renter types the card in Stripe&#39;s secure form: on this device (<b class="gd-ui">Open the card form</b>, then hand it over) or by a link texted or emailed to them (<b class="gd-ui">Send the link</b>). Staff never type a card number.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">A deposit hold lasts about 7 days and shows the days left. After the return, <b class="gd-ui">Capture the hold</b> (all or part, with the reason) or <b class="gd-ui">Release the hold</b>.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t"><b class="gd-ui">Charge the saved card</b> (Finance or an Admin): extra kilometres, fuel, damage or a late return, with the reason the renter&#39;s receipt shows. For a rental over 7 days, save the card and charge the deposit this way.</div></li><li><span class="gd-n" aria-hidden="true">5</span><div class="gd-t">An offer paid another way: once the renter approved and signed and the money is recorded, the booking is confirmed (or press <b class="gd-ui">Confirm the booking</b>).</div></li><li><span class="gd-n" aria-hidden="true">6</span><div class="gd-t">A deposit taken in cash or by e-Transfer is given back the same way after the return: Finance gets a task; press <b class="gd-ui">Returned</b> with the reference or receipt number.</div></li></ol></div><aside class="gd-box"><span class="gd-lbl">Good to know</span><div>Statements, reconciliation and the deposit settlement read each payment with its method: a cash deposit is never refunded to a card.</div></aside></section><section class="gd-task" id="requests-offers-and-bookings-a-booking" data-gd-task><h2 class="gd-h2">A booking</h2><p class="gd-p">Open <b class="gd-ui">Bookings</b> &gt; <b class="gd-ui">Bookings</b>, then a booking number. Or type the number in the search box.</p><div class="gd-stepblock gd-stepblock--below"><div class="gd-stepcol"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">Tabs: Overview, Money, Changes, History, and Drivers and documents.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Overview shows the trip, the renter, what is still missing for the handover, and the price.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Open tasks for this booking, with the queue and the due time.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t">Top right: <b class="gd-ui">Stop blocking the calendar</b>, <b class="gd-ui">Cancel for the renter</b> and <b class="gd-ui">Cancel by CarmaCars</b>.</div></li></ol></div><figure class="gd-fig gd-fig--desk"><div class="gd-browser"><div class="gd-bar" aria-hidden="true"><i></i><i></i><i></i><span class="gd-addr">carmacars.ca/admin/bookings/CC-10057</span></div><div class="gd-imgwrap" style="aspect-ratio:1440/960"><img src="/guides/img/admin-04-booking-desktop-b56b668a.jpg" alt="" loading="lazy" decoding="async" width="1440" height="960"><span class="gd-pin" style="left:20.1%;top:24%" aria-hidden="true">1</span><span class="gd-pin" style="left:34.7%;top:58.3%" aria-hidden="true">2</span><span class="gd-pin" style="left:20.1%;top:72.9%" aria-hidden="true">3</span><span class="gd-pin" style="left:90.3%;top:18.3%" aria-hidden="true">4</span></div></div></figure></div></section><section class="gd-task" id="requests-offers-and-bookings-check-a-car-out-or-in" data-gd-task><h2 class="gd-h2">Check a car out or in</h2><p class="gd-p">From the booking, with your phone or a tablet: the same checklist field staff use.</p><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">A confirmed booking shows <b class="gd-ui">Check out (pickup)</b> under Check-out, check-in and signing; a booking on rent shows <b class="gd-ui">Check in (return)</b>. Today lists the check-outs and check-ins due, each with <b class="gd-ui">Check out</b> or <b class="gd-ui">Check in</b>.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">The checklist opens: the ready check, the renter and their licence and card, the odometer (km) and fuel or charge, the keys, the photo set (every side, the wheels, the interior, the odometer and fuel gauge, the plate), damage marks with close-ups, then the renter and you sign.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Photos wait on the device without a connection and upload in the background. Each keeps its time, and the place when the device allows location.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t">A field job of the booking is taken over (the history says so); with no job, one is made for you. When done, press <b class="gd-ui">See the photo report</b>.</div></li></ol></div><aside class="gd-box"><span class="gd-lbl">Tip</span><div>Fleet, Sales and Customer service check cars out and in the same way from their own booking page.</div></aside></section><section class="gd-task" id="requests-offers-and-bookings-the-photo-report-late-returns-and-the-return-charges" data-gd-task><h2 class="gd-h2">The photo report, late returns and the return charges</h2><p class="gd-p">Under Check-out, check-in and signing, press <b class="gd-ui">Photo report</b>.</p><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">The report shows the due-back time, the actual check-out and check-in, Late by (or Overdue by while the car is out), the odometer and kilometres over the allowance, the fuel or charge out and in, every photo with its time and place, and the damage.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">At check-in the late return (after the grace period of the fee defaults), the mileage overage and the fuel or recharging are written to the return charges at once. A gas car with no pump receipt is priced at the refill price per eighth (Program settings) plus the markup until the receipt is entered.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Not charging one? Press <b class="gd-ui">Waive</b> beside it and give the reason: it stays waived if the charges are worked out again.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t">The time was wrong? Press <b class="gd-ui">Correct the check-in time</b> (or the check-out time) with the reason: lateness and the late charges follow, and the history keeps both times.</div></li><li><span class="gd-n" aria-hidden="true">5</span><div class="gd-t">The renter gets the same report (without these buttons) by email and in their Documents. Late by shows on the booking and in the Bookings list.</div></li></ol></div></section><section class="gd-task" id="requests-offers-and-bookings-signatures-on-the-spot-or-by-link" data-gd-task><h2 class="gd-h2">Signatures on the spot, or by link</h2><p class="gd-p">The renter or an additional driver signs the rental agreement on your device, or on their own phone.</p><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">While a signature is missing, the booking shows <b class="gd-ui">Sign now on this device</b>, <b class="gd-ui">Email the signing link</b> and <b class="gd-ui">Text the signing link</b>.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t"><b class="gd-ui">Sign now on this device</b>: confirm the name matches their licence and that you saw the original licence (photograph it if none is on file), then press <b class="gd-ui">Hand the device to</b> and their name.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">They read both agreements (CarmaCars&#39; and Blind Spot&#39;s), tick the statements and sign. Then <b class="gd-ui">Back to the staff view</b> for the next signer.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t">The record is the same as signing online, and says it was signed in person, collected by you, on your device. It is printed on the signed copy&#39;s signature record page.</div></li></ol></div></section><section class="gd-task" id="requests-offers-and-bookings-the-licence-before-an-offer-is-accepted" data-gd-task><h2 class="gd-h2">The licence before an offer is accepted</h2><p class="gd-p">Front, back and a selfie, from the request on.</p><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">After sending a request the renter is asked for their licence. A licence already on file from an earlier booking is used again while it is valid after the return.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">The offer cannot be accepted (by the renter, or by you on their word) and nothing is paid until the licence and its expiry date are on file.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Review the images as usual with <b class="gd-ui">Review documents</b>: the card Renter documents is on Review and offer too.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t">The switch is in <b class="gd-ui">Settings</b> &gt; <b class="gd-ui">Program settings</b>, Booking requests and offers: Booking licence required (on), with the selfie (on).</div></li></ol></div></section><section class="gd-task" id="requests-offers-and-bookings-renter-documents-licence-and-proof-of-coverage" data-gd-task><h2 class="gd-h2">Renter documents: licence and proof of coverage</h2><p class="gd-p">A renter&#39;s licence photos, selfie and proof of coverage (OPCF 27 or a credit card&#39;s rental coverage) are checked before the handover. You check them yourself; no task is needed.</p><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">A booking with documents waiting is a line on To do: &quot;Check &#39;s documents for booking &quot;, marked Now when the pickup is within two days. Press <b class="gd-ui">Review documents</b>.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">The pop-up shows each driver&#39;s images and the coverage: the insurer, policy number and expiry, or the card, its type and whether the name matches.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Tick the checks, then <b class="gd-ui">Approve</b>. Or type the reason the renter reads and press <b class="gd-ui">Reject</b>: they are asked for a new one.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t">The same pop-up is on the booking: the card Renter documents (<b class="gd-ui">Review documents</b>) on Overview and on Drivers and documents.</div></li></ol></div><aside class="gd-box"><span class="gd-lbl">Tip</span><div>Each opening of a renter&#39;s documents is logged. The links to the images last one minute.</div></aside></section><section class="gd-task" id="requests-offers-and-bookings-propose-a-change-to-a-confirmed-booking" data-gd-task><h2 class="gd-h2">Propose a change to a confirmed booking</h2><p class="gd-p">The renter gets an email and answers on their booking. The calendar moves only when they accept.</p><div class="gd-stepblock gd-stepblock--below"><div class="gd-stepcol"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">Open the booking&#39;s Changes tab. Under Propose a change, set the new pickup, return or car.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">To price it by hand, type a New rental charge before tax. Leave it empty to use the car&#39;s rates.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Write the Reason, for the renter. They read it.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t">Press <b class="gd-ui">Preview the price</b>, then <b class="gd-ui">Send to the renter</b>.</div></li></ol></div><figure class="gd-fig gd-fig--desk"><div class="gd-browser"><div class="gd-bar" aria-hidden="true"><i></i><i></i><i></i><span class="gd-addr">carmacars.ca/admin/bookings/CC-10057?tab=changes</span></div><div class="gd-imgwrap" style="aspect-ratio:1230/530"><img src="/guides/img/admin-05-booking-changes-desktop-0b06af9a.jpg" alt="" loading="lazy" decoding="async" width="1230" height="530"><span class="gd-pin" style="left:12.9%;top:15.3%" aria-hidden="true">1</span><span class="gd-pin" style="left:35%;top:30.6%" aria-hidden="true">2</span><span class="gd-pin" style="left:49.8%;top:59.1%" aria-hidden="true">3</span><span class="gd-pin" style="left:30.9%;top:73.2%" aria-hidden="true">4</span></div></div></figure></div></section><section class="gd-task" id="requests-offers-and-bookings-who-a-booking-is-credited-to" data-gd-task><h2 class="gd-h2">Who a booking is credited to</h2><p class="gd-p">Overview (and Review and offer) shows the Sales credit: the staff member the booking counts for in their sales.</p><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">A quote or a rental is credited to whoever created or added it. A request from the website is credited to whoever sent its first offer.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">To give it to someone else, press <b class="gd-ui">Reassign</b>, choose who (or Nobody), say whether they sourced the client and write the reason. The booking&#39;s history and the audit log keep it, and the deal stays in the same week and month.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Sourced means the staff member chose I sourced this client when they entered it, it came with a field staff referral link, or you credited it. Only a sourced booking earns a staff commission. A website request earns none unless you credit someone.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t">Someone said they sourced a website request? The credit line shows the claim: press <b class="gd-ui">Credit them</b> or <b class="gd-ui">Not theirs</b>, with a reason.</div></li><li><span class="gd-n" aria-hidden="true">5</span><div class="gd-t">A price typed by hand shows beside the rate-sheet price, with the reason. A price under the floor or past the discount limit is flagged: press <b class="gd-ui">Mark reviewed</b> once you have looked at it.</div></li></ol></div><aside class="gd-box"><span class="gd-lbl">Tip</span><div>The renter has 48 hours to accept (and sign the amendment) or decline, with one reminder. Any extra is charged to their Card on File; a lower price raises a refund for your approval.</div></aside></section>');
select app.guide_release_section('va', 'customer-service', 'chapter', 'your-workday', 'You answer requests with offers, quote callers, reply to renters, look renters up, and review owner forms. You are often the renter''s first person.

Your rail: Queue, Today, Requests, New quote, Renter messages, Find a renter, Calendar, Listings, Similar cars, Owners and enquiries, Owner forms and Scorecard.

## Answer a request

1. Open **Requests**. Filter by New, Waiting on the renter, Pushed back, Offer out or Offer expired.
2. Waiting shows how long the renter has waited. Open the booking number.

![](/guides/img/va-cs-03-requests-desktop-b3c66d25.jpg "desktop; size: 1440 640; address: carmacars.ca/va/requests; pins: 1 27.1 17.5, 2 52.8 32.8")

3. On the Review tab, check the request: the car is free, the renter, the places.
4. Press **Adjust the booking** to change the car, dates, places, price or extras, then **Save changes**.
5. Add a message and press **Send the offer**. Within your limit you can also use **Approve (within my limit)** or **Approve and send the pay link**.
6. Can''t do it? **Decline** with Reason and any alternative. Need to know more? **Ask the renter**.

![](/guides/img/va-cs-04-booking-review-desktop-52c68a73.jpg "desktop; size: 1440 1000; address: carmacars.ca/va/bookings/CC-10056?tab=review; pins: 3 69.4 24.0, 4 95.8 98.0")

> Tip: Reply within 5 minutes: send the offer, or ask the renter what you need. That is the "First reply in opening hours" measure on your scorecard. Requests waiting longer show in red.

## An enquiry on an example car

Some cars on the site are marked "Example car": samples that show the kind of cars we rent. A request on one is an enquiry, never a booking.

1. The task Suggest a similar real car comes to To do with the enquiry number (EQ-1001 and up), the car asked for, the dates and the contact. When a real car was free for those dates, the task names it after **Free:** (the same make and model first, else the same class and body at a similar price), and the person was told we have a similar car and will confirm it within 2 hours.
2. Check the named car is still right for them (or find a real car of the same kind and price that is free for those dates), and make a **New quote** for it.
3. Call or email the person with the car and the price, then mark the task done.

> Tip: Reply within the first reply target, as for any request. Never offer the example car itself: it does not exist.

## A request from a vehicle page

Every make, model, year and trim page (carmacars.ca/cars/toyota/rav4/2023/xle, for example) has Request it, for the exact car the person wants.

1. The request arrives as an enquiry with the car named in the message ("About the car: 2023 Toyota RAV4 XLE") and an Enquiry task in To do.
2. If we have that car, or one close to it, free for their dates, make a **New quote** for it. If not, suggest the nearest car of the same kind and price.
3. Reply by email or phone, then mark the task done.

> Tip: The pages say only what the data says: EPA fuel use, the Canadian trims and our own cars. Never promise equipment the page does not list.

## A buyer lead from a /buy page

Every vehicle page has a for-sale twin (carmacars.ca/buy/toyota/rav4/2023/xle) with "Find me this car", and twins for financing, detailing and body shop work with their own request: a name, an email or phone, and when.

1. The lead is in **Owner leads** (customer service: **Owners and enquiries**), Buyer leads (kind buyer, finance, detailing or body shop), with the car and what they asked, and a To do line for Sales: A buyer asked us to find a car, Someone asked about financing or leasing a car, A detailing request, or A body shop request.
2. If one of our cars of that kind is for sale (an Admin flags it with its price), offer it. If not, offer to rent them the car for a week first, and say what we can find. We do not lend or lease: on a financing question, say so and offer the rental. For detailing or body shop work, give a time and a price, and always offer a rental while their car is in (an insurance replacement rental when it is a claim). For mechanical work (a "Mechanical work to arrange" task: an oil change, brakes, tires, a tow and the like), CarmaCars does not do the work: book it with a trusted shop or recommend one, never promise the shop''s price or time, and offer a rental while their car is in.
3. Press **Take it**, then **Update** as you go: contacted, qualified, converted or closed with the reason.

> Tip: We mostly rent cars. Never say a car is for sale unless an Admin flagged it; the page shows it with its price when one is.

## Send an offer to a caller

Open **Send an offer** (or **Send an offer** beside a car in Find a car). No request needed: one screen, and the renter has the link.

1. Find the customer by name, phone or email, or press **Add a new customer**: full legal name, mobile, email and date of birth. Already on file with that email or phone? Use them: never a second record.
2. Choose the car (by car code, plate or name; each says Free or Not free), the dates and the places.
3. The price: the rate sheet, a total or a rate per day, with the reason for a price you type. The deposit, discounts and fees are set by an Admin; customer service sets the Protection Plan price.
4. How the rental and the deposit are paid (card online, e-Transfer, cash, platform payout, the insurer; deposit by card hold, cash or e-Transfer), who found this client, the message, how long it is open (48 hours at most) and Email, Text or both.
5. Check the offer as the renter will see it on the right, then press **Send the offer**.

> Tip: An offer that is out is changed in place: **Edit the offer**, change it, then **Save and send the update** or **Save without telling the renter**. No need to withdraw it first.

## New quote for a caller

1. Open **New quote**. Choose the Car, the Pickup and Return (at least 2 hours from now).
2. Choose how the lead came in, then the caller''s Full legal name, Email, Mobile and Date of birth.
3. Set the Licence class and Damage cover, and note places, extras and what they asked.
4. Press **Create the request**. It opens like any request; send the offer from there.

![](/guides/img/va-cs-05-new-quote-desktop-4e386b1c.jpg "desktop; size: 1220 1260; address: carmacars.ca/va/quotes/new; pins: 1 72.1 15.6, 2 72.1 41.7, 3 72.1 72.7, 4 63.9 85.5")

## Renter messages and Find a renter

1. **Renter messages** lists the latest messages with their booking. Open the booking to reply, then press **Send**.
2. **Find a renter**: search by name, email, phone or booking number.
3. To open a renter''s private details, press **Open with a reason**. The reason is kept in the access log.

![](/guides/img/va-cs-06-messages-desktop-3441fa91.jpg "desktop; size: 1440 260; address: carmacars.ca/va/messages; pins: 1 32.6 48.5")

## Add a car for an owner

Open **Owners** > **Add a car for an owner** (fleet: under Cars). You enter everything for the owner; they never fill in the application.

1. The owner: find them by name, email or phone, or choose New owner and enter the name, email, phone and address.
2. The car: type the VIN. The car is looked up at once and shown in one line with the year, make, model, trim and details (Edit if something is wrong). No VIN at hand: add it by its plate and choose the year, make and model. Tap the colour and check the class. Upload the ownership permit, the insurance slip and the lender''s information if you have them. Photos are optional.
3. Terms and first invoice: what was agreed with the owner, to the cent. An Admin checks them before anything is sent.
4. Who sourced the owner: Entered for CarmaCars, or I sourced this owner. How the owner signs: by email, or on paper.
5. Press **Add the car and send to an Admin**. The application waits in the Admin''s Applications, marked Entered by staff with your name. When the Admin approves, the owner gets one email to review and sign.

## Owner forms (Forms C and D)

1. Open **Owner forms**. Each row is a scan an owner uploaded, with the witnesses and the status.
2. Press Open to read the scan. Check every page is there and signed, with each witness''s signature and name.
3. Press **Approve**, or **Send back** with What to fix (the owner reads this).

![](/guides/img/va-cs-08-owner-forms-desktop-eceaee0b.jpg "desktop; size: 1440 300; address: carmacars.ca/va/owner-forms; pins: 2 68.6 36.7, 3 76.7 36.7")

## A rental agreement signed on paper

1. Open the booking. Under Signed on paper, press **Record paper signature**.
2. Choose the Rental agreement, or the booking change the renter signed.
3. Check Signed by and Date signed, and upload the scan of every signed page.
4. Press **Record signature**. It counts as signed, and the renter is not asked to sign again.

## Check renter documents

The renter''s licence photos, selfie and proof of coverage, before the handover.

1. Open the task "identity documents or coverage proof to review", or open the booking: **Review** shows the documents of any booking being arranged or under way, with no task needed.
2. Tick every check under a document, then press **Approve**. Or type the reason the renter reads and press **Reject**.
3. The coverage: OPCF 27 shows the insurer, policy number and expiry; credit card coverage shows the card, its type and whether the name matches. Approve or reject it as a whole.

> Tip: Each opening is logged. An Admin can do the same from Admin > To do.

## A change to a confirmed booking

On a booking''s Changes tab you can propose new dates, times or another car, as an Admin does: set the change, write the reason, press **Preview the price**, then **Send to the renter**. The renter has 48 hours to accept and sign the amendment. You also send a new signing link to an additional driver from the booking screen.

## A late return

A booking past its return time shows the late return panel. Work it in order:

| Button | When |
| --- | --- |
| **Log a call** | Record each call to the renter and what they said. |
| **Send T13** | The first late notice email. |
| **Send T14 (final notice)** | The final notice. |
| **Request disable** | Ask an Admin to approve disabling the car. |
| **Open an incident** | When the car is not coming back as planned. |
', 'Customer service', 'Requests and offers, new quotes, renter messages, find a renter, owner forms, late returns.',
  'You answer requests with offers, quote callers, reply to renters, look renters up, and review owner forms. You are often the renter''s first person.

Your rail: Queue, Today, Requests, New quote, Renter messages, Find a renter, Calendar, Listings, Similar cars, Owners and enquiries, Owner forms and Scorecard.

## Answer a request

1. Open **Requests**. Filter by New, Waiting on the renter, Pushed back, Offer out or Offer expired.
2. Waiting shows how long the renter has waited. Open the booking number.

![](/guides/img/va-cs-03-requests-desktop-b3c66d25.jpg "desktop; size: 1440 640; address: carmacars.ca/va/requests; pins: 1 27.1 17.5, 2 52.8 32.8")

3. On the Review tab, check the request: the car is free, the renter, the places.
4. Press **Adjust the booking** to change the car, dates, places, price or extras, then **Save changes**.
5. Add a message and press **Send the offer**. Within your limit you can also use **Approve (within my limit)** or **Approve and send the pay link**.
6. Can''t do it? **Decline** with Reason and any alternative. Need to know more? **Ask the renter**.

![](/guides/img/va-cs-04-booking-review-desktop-52c68a73.jpg "desktop; size: 1440 1000; address: carmacars.ca/va/bookings/CC-10056?tab=review; pins: 3 69.4 24.0, 4 95.8 98.0")

> Tip: Reply within 5 minutes: send the offer, or ask the renter what you need. That is the "First reply in opening hours" measure on your scorecard. Requests waiting longer show in red.

## An enquiry on an example car

Some cars on the site are marked "Example car": samples that show the kind of cars we rent. A request on one is an enquiry, never a booking.

1. The task Suggest a similar real car comes to To do with the enquiry number (EQ-1001 and up), the car asked for, the dates and the contact. When a real car was free for those dates, the task names it after **Free:** (the same make and model first, else the same class and body at a similar price), and the person was told we have a similar car and will confirm it within 2 hours.
2. Check the named car is still right for them (or find a real car of the same kind and price that is free for those dates), and make a **New quote** for it.
3. Call or email the person with the car and the price, then mark the task done.

> Tip: Reply within the first reply target, as for any request. Never offer the example car itself: it does not exist.

## A request from a vehicle page

Every make, model, year and trim page (carmacars.ca/cars/toyota/rav4/2023/xle, for example) has Request it, for the exact car the person wants.

1. The request arrives as an enquiry with the car named in the message ("About the car: 2023 Toyota RAV4 XLE") and an Enquiry task in To do.
2. If we have that car, or one close to it, free for their dates, make a **New quote** for it. If not, suggest the nearest car of the same kind and price.
3. Reply by email or phone, then mark the task done.

> Tip: The pages say only what the data says: EPA fuel use, the Canadian trims and our own cars. Never promise equipment the page does not list.

## A buyer lead from a /buy page

Every vehicle page has a for-sale twin (carmacars.ca/buy/toyota/rav4/2023/xle) with "Find me this car", and twins for financing, detailing and body shop work with their own request: a name, an email or phone, and when.

1. The lead is in **Owner leads** (customer service: **Owners and enquiries**), Buyer leads (kind buyer, finance, detailing or body shop), with the car and what they asked, and a To do line for Sales: A buyer asked us to find a car, Someone asked about financing or leasing a car, A detailing request, or A body shop request.
2. If one of our cars of that kind is for sale (an Admin flags it with its price), offer it. If not, offer to rent them the car for a week first, and say what we can find. We do not lend or lease: on a financing question, say so and offer the rental. For detailing or body shop work, give a time and a price, and always offer a rental while their car is in (an insurance replacement rental when it is a claim). For mechanical work (a "Mechanical work to arrange" task: an oil change, brakes, tires, a tow and the like), CarmaCars does not do the work: book it with a trusted shop or recommend one, never promise the shop''s price or time, and offer a rental while their car is in.
3. Press **Take it**, then **Update** as you go: contacted, qualified, converted or closed with the reason.

> Tip: We mostly rent cars. Never say a car is for sale unless an Admin flagged it; the page shows it with its price when one is.

## Send an offer to a caller

Open **Send an offer** (or **Send an offer** beside a car in Find a car). No request needed: one screen, and the renter has the link.

1. Find the customer by name, phone or email, or press **Add a new customer**: full legal name, mobile, email and date of birth. Already on file with that email or phone? Use them: never a second record.
2. Choose the car (by car code, plate or name; each says Free or Not free), the dates and the places.
3. The price: the rate sheet, a total or a rate per day, with the reason for a price you type. The deposit, discounts and fees are set by an Admin; customer service sets the Protection Plan price.
4. How the rental and the deposit are paid (card online, e-Transfer, cash, platform payout, the insurer; deposit by card hold, cash or e-Transfer), who found this client, the message, how long it is open (48 hours at most) and Email, Text or both.
5. Check the offer as the renter will see it on the right, then press **Send the offer**.

> Tip: An offer that is out is changed in place: **Edit the offer**, change it, then **Save and send the update** or **Save without telling the renter**. No need to withdraw it first.

## New quote for a caller

1. Open **New quote**. Choose the Car, the Pickup and Return (at least 2 hours from now).
2. Choose how the lead came in, then the caller''s Full legal name, Email, Mobile and Date of birth.
3. Set the Licence class and Damage cover, and note places, extras and what they asked.
4. Press **Create the request**. It opens like any request; send the offer from there.

![](/guides/img/va-cs-05-new-quote-desktop-4e386b1c.jpg "desktop; size: 1220 1260; address: carmacars.ca/va/quotes/new; pins: 1 72.1 15.6, 2 72.1 41.7, 3 72.1 72.7, 4 63.9 85.5")

## Renter messages and Find a renter

1. **Renter messages** lists the latest messages with their booking. Open the booking to reply, then press **Send**.
2. **Find a renter**: search by name, email, phone or booking number.
3. To open a renter''s private details, press **Open with a reason**. The reason is kept in the access log.

![](/guides/img/va-cs-06-messages-desktop-3441fa91.jpg "desktop; size: 1440 260; address: carmacars.ca/va/messages; pins: 1 32.6 48.5")

## Add a car for an owner

Open **Owners** > **Add a car for an owner** (fleet: under Cars). You enter everything for the owner; they never fill in the application.

1. The owner: find them by name, email or phone, or choose New owner and enter the name, email, phone and address.
2. The car: type the VIN. The car is looked up at once and shown in one line with the year, make, model, trim and details (Edit if something is wrong). No VIN at hand: add it by its plate and choose the year, make and model. Tap the colour and check the class. Upload the ownership permit, the insurance slip and the lender''s information if you have them. Photos are optional.
3. Terms and first invoice: what was agreed with the owner, to the cent. An Admin checks them before anything is sent.
4. Who sourced the owner: Entered for CarmaCars, or I sourced this owner. How the owner signs: by email, or on paper.
5. Press **Add the car and send to an Admin**. The application waits in the Admin''s Applications, marked Entered by staff with your name. When the Admin approves, the owner gets one email to review and sign.

## Owner forms (Forms C and D)

1. Open **Owner forms**. Each row is a scan an owner uploaded, with the witnesses and the status.
2. Press Open to read the scan. Check every page is there and signed, with each witness''s signature and name.
3. Press **Approve**, or **Send back** with What to fix (the owner reads this).

![](/guides/img/va-cs-08-owner-forms-desktop-eceaee0b.jpg "desktop; size: 1440 300; address: carmacars.ca/va/owner-forms; pins: 2 68.6 36.7, 3 76.7 36.7")

## A rental agreement signed on paper

1. Open the booking. Under Signed on paper, press **Record paper signature**.
2. Choose the Rental agreement, or the booking change the renter signed.
3. Check Signed by and Date signed, and upload the scan of every signed page.
4. Press **Record signature**. It counts as signed, and the renter is not asked to sign again.

## Signatures on the spot, or by link

A renter or an additional driver who has not signed yet.

1. On the booking, press **Sign now on this device**. Confirm the name and that you saw the original licence, then **Hand the device to** the signer.
2. Or press **Email the signing link** or **Text the signing link**: they sign on their own phone.
3. The licence comes first: the renter uploads it from the request, and the offer cannot be accepted without it.

## Check renter documents

The renter''s licence photos, selfie and proof of coverage, before the handover.

1. Open the task "identity documents or coverage proof to review", or open the booking: **Review** shows the documents of any booking being arranged or under way, with no task needed.
2. Tick every check under a document, then press **Approve**. Or type the reason the renter reads and press **Reject**.
3. The coverage: OPCF 27 shows the insurer, policy number and expiry; credit card coverage shows the card, its type and whether the name matches. Approve or reject it as a whole.

> Tip: Each opening is logged. An Admin can do the same from Admin > To do.

## A change to a confirmed booking

On a booking''s Changes tab you can propose new dates, times or another car, as an Admin does: set the change, write the reason, press **Preview the price**, then **Send to the renter**. The renter has 48 hours to accept and sign the amendment. You also send a new signing link to an additional driver from the booking screen.

## A late return

A booking past its return time shows the late return panel. Work it in order:

| Button | When |
| --- | --- |
| **Log a call** | Record each call to the renter and what they said. |
| **Send T13** | The first late notice email. |
| **Send T14 (final notice)** | The final notice. |
| **Request disable** | Ask an Admin to approve disabling the car. |
| **Open an incident** | When the car is not coming back as planned. |
',
  '<p class="gd-p">You answer requests with offers, quote callers, reply to renters, look renters up, and review owner forms. You are often the renter&#39;s first person.</p><p class="gd-p">Your rail: Queue, Today, Requests, New quote, Renter messages, Find a renter, Calendar, Listings, Similar cars, Owners and enquiries, Owner forms and Scorecard.</p><section class="gd-task" id="customer-service-answer-a-request" data-gd-task><h2 class="gd-h2">Answer a request</h2><div class="gd-stepblock gd-stepblock--below"><div class="gd-stepcol"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">Open <b class="gd-ui">Requests</b>. Filter by New, Waiting on the renter, Pushed back, Offer out or Offer expired.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Waiting shows how long the renter has waited. Open the booking number.</div></li></ol></div><figure class="gd-fig gd-fig--desk"><div class="gd-browser"><div class="gd-bar" aria-hidden="true"><i></i><i></i><i></i><span class="gd-addr">carmacars.ca/va/requests</span></div><div class="gd-imgwrap" style="aspect-ratio:1440/640"><img src="/guides/img/va-cs-03-requests-desktop-b3c66d25.jpg" alt="" loading="lazy" decoding="async" width="1440" height="640"><span class="gd-pin" style="left:27.1%;top:17.5%" aria-hidden="true">1</span><span class="gd-pin" style="left:52.8%;top:32.8%" aria-hidden="true">2</span></div></div></figure></div><div class="gd-stepblock gd-stepblock--below"><div class="gd-stepcol"><ol class="gd-ol" start="3"><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">On the Review tab, check the request: the car is free, the renter, the places.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t">Press <b class="gd-ui">Adjust the booking</b> to change the car, dates, places, price or extras, then <b class="gd-ui">Save changes</b>.</div></li><li><span class="gd-n" aria-hidden="true">5</span><div class="gd-t">Add a message and press <b class="gd-ui">Send the offer</b>. Within your limit you can also use <b class="gd-ui">Approve (within my limit)</b> or <b class="gd-ui">Approve and send the pay link</b>.</div></li><li><span class="gd-n" aria-hidden="true">6</span><div class="gd-t">Can&#39;t do it? <b class="gd-ui">Decline</b> with Reason and any alternative. Need to know more? <b class="gd-ui">Ask the renter</b>.</div></li></ol></div><figure class="gd-fig gd-fig--desk"><div class="gd-browser"><div class="gd-bar" aria-hidden="true"><i></i><i></i><i></i><span class="gd-addr">carmacars.ca/va/bookings/CC-10056?tab=review</span></div><div class="gd-imgwrap" style="aspect-ratio:1440/1000"><img src="/guides/img/va-cs-04-booking-review-desktop-52c68a73.jpg" alt="" loading="lazy" decoding="async" width="1440" height="1000"><span class="gd-pin" style="left:69.4%;top:24%" aria-hidden="true">3</span><span class="gd-pin" style="left:95.8%;top:98%" aria-hidden="true">4</span></div></div></figure></div><aside class="gd-box"><span class="gd-lbl">Tip</span><div>Reply within 5 minutes: send the offer, or ask the renter what you need. That is the &quot;First reply in opening hours&quot; measure on your scorecard. Requests waiting longer show in red.</div></aside></section><section class="gd-task" id="customer-service-an-enquiry-on-an-example-car" data-gd-task><h2 class="gd-h2">An enquiry on an example car</h2><p class="gd-p">Some cars on the site are marked &quot;Example car&quot;: samples that show the kind of cars we rent. A request on one is an enquiry, never a booking.</p><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">The task Suggest a similar real car comes to To do with the enquiry number (EQ-1001 and up), the car asked for, the dates and the contact. When a real car was free for those dates, the task names it after <b class="gd-ui">Free:</b> (the same make and model first, else the same class and body at a similar price), and the person was told we have a similar car and will confirm it within 2 hours.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Check the named car is still right for them (or find a real car of the same kind and price that is free for those dates), and make a <b class="gd-ui">New quote</b> for it.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Call or email the person with the car and the price, then mark the task done.</div></li></ol></div><aside class="gd-box"><span class="gd-lbl">Tip</span><div>Reply within the first reply target, as for any request. Never offer the example car itself: it does not exist.</div></aside></section><section class="gd-task" id="customer-service-a-request-from-a-vehicle-page" data-gd-task><h2 class="gd-h2">A request from a vehicle page</h2><p class="gd-p">Every make, model, year and trim page (carmacars.ca/cars/toyota/rav4/2023/xle, for example) has Request it, for the exact car the person wants.</p><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">The request arrives as an enquiry with the car named in the message (&quot;About the car: 2023 Toyota RAV4 XLE&quot;) and an Enquiry task in To do.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">If we have that car, or one close to it, free for their dates, make a <b class="gd-ui">New quote</b> for it. If not, suggest the nearest car of the same kind and price.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Reply by email or phone, then mark the task done.</div></li></ol></div><aside class="gd-box"><span class="gd-lbl">Tip</span><div>The pages say only what the data says: EPA fuel use, the Canadian trims and our own cars. Never promise equipment the page does not list.</div></aside></section><section class="gd-task" id="customer-service-a-buyer-lead-from-a-buy-page" data-gd-task><h2 class="gd-h2">A buyer lead from a /buy page</h2><p class="gd-p">Every vehicle page has a for-sale twin (carmacars.ca/buy/toyota/rav4/2023/xle) with &quot;Find me this car&quot;, and twins for financing, detailing and body shop work with their own request: a name, an email or phone, and when.</p><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">The lead is in <b class="gd-ui">Owner leads</b> (customer service: <b class="gd-ui">Owners and enquiries</b>), Buyer leads (kind buyer, finance, detailing or body shop), with the car and what they asked, and a To do line for Sales: A buyer asked us to find a car, Someone asked about financing or leasing a car, A detailing request, or A body shop request.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">If one of our cars of that kind is for sale (an Admin flags it with its price), offer it. If not, offer to rent them the car for a week first, and say what we can find. We do not lend or lease: on a financing question, say so and offer the rental. For detailing or body shop work, give a time and a price, and always offer a rental while their car is in (an insurance replacement rental when it is a claim). For mechanical work (a &quot;Mechanical work to arrange&quot; task: an oil change, brakes, tires, a tow and the like), CarmaCars does not do the work: book it with a trusted shop or recommend one, never promise the shop&#39;s price or time, and offer a rental while their car is in.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Press <b class="gd-ui">Take it</b>, then <b class="gd-ui">Update</b> as you go: contacted, qualified, converted or closed with the reason.</div></li></ol></div><aside class="gd-box"><span class="gd-lbl">Tip</span><div>We mostly rent cars. Never say a car is for sale unless an Admin flagged it; the page shows it with its price when one is.</div></aside></section><section class="gd-task" id="customer-service-send-an-offer-to-a-caller" data-gd-task><h2 class="gd-h2">Send an offer to a caller</h2><p class="gd-p">Open <b class="gd-ui">Send an offer</b> (or <b class="gd-ui">Send an offer</b> beside a car in Find a car). No request needed: one screen, and the renter has the link.</p><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">Find the customer by name, phone or email, or press <b class="gd-ui">Add a new customer</b>: full legal name, mobile, email and date of birth. Already on file with that email or phone? Use them: never a second record.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Choose the car (by car code, plate or name; each says Free or Not free), the dates and the places.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">The price: the rate sheet, a total or a rate per day, with the reason for a price you type. The deposit, discounts and fees are set by an Admin; customer service sets the Protection Plan price.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t">How the rental and the deposit are paid (card online, e-Transfer, cash, platform payout, the insurer; deposit by card hold, cash or e-Transfer), who found this client, the message, how long it is open (48 hours at most) and Email, Text or both.</div></li><li><span class="gd-n" aria-hidden="true">5</span><div class="gd-t">Check the offer as the renter will see it on the right, then press <b class="gd-ui">Send the offer</b>.</div></li></ol></div><aside class="gd-box"><span class="gd-lbl">Tip</span><div>An offer that is out is changed in place: <b class="gd-ui">Edit the offer</b>, change it, then <b class="gd-ui">Save and send the update</b> or <b class="gd-ui">Save without telling the renter</b>. No need to withdraw it first.</div></aside></section><section class="gd-task" id="customer-service-new-quote-for-a-caller" data-gd-task><h2 class="gd-h2">New quote for a caller</h2><div class="gd-stepblock gd-stepblock--below"><div class="gd-stepcol"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">Open <b class="gd-ui">New quote</b>. Choose the Car, the Pickup and Return (at least 2 hours from now).</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Choose how the lead came in, then the caller&#39;s Full legal name, Email, Mobile and Date of birth.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Set the Licence class and Damage cover, and note places, extras and what they asked.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t">Press <b class="gd-ui">Create the request</b>. It opens like any request; send the offer from there.</div></li></ol></div><figure class="gd-fig gd-fig--desk"><div class="gd-browser"><div class="gd-bar" aria-hidden="true"><i></i><i></i><i></i><span class="gd-addr">carmacars.ca/va/quotes/new</span></div><div class="gd-imgwrap" style="aspect-ratio:1220/1260"><img src="/guides/img/va-cs-05-new-quote-desktop-4e386b1c.jpg" alt="" loading="lazy" decoding="async" width="1220" height="1260"><span class="gd-pin" style="left:72.1%;top:15.6%" aria-hidden="true">1</span><span class="gd-pin" style="left:72.1%;top:41.7%" aria-hidden="true">2</span><span class="gd-pin" style="left:72.1%;top:72.7%" aria-hidden="true">3</span><span class="gd-pin" style="left:63.9%;top:85.5%" aria-hidden="true">4</span></div></div></figure></div></section><section class="gd-task" id="customer-service-renter-messages-and-find-a-renter" data-gd-task><h2 class="gd-h2">Renter messages and Find a renter</h2><div class="gd-stepblock gd-stepblock--below"><div class="gd-stepcol"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t"><b class="gd-ui">Renter messages</b> lists the latest messages with their booking. Open the booking to reply, then press <b class="gd-ui">Send</b>.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t"><b class="gd-ui">Find a renter</b>: search by name, email, phone or booking number.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">To open a renter&#39;s private details, press <b class="gd-ui">Open with a reason</b>. The reason is kept in the access log.</div></li></ol></div><figure class="gd-fig gd-fig--desk"><div class="gd-browser"><div class="gd-bar" aria-hidden="true"><i></i><i></i><i></i><span class="gd-addr">carmacars.ca/va/messages</span></div><div class="gd-imgwrap" style="aspect-ratio:1440/260"><img src="/guides/img/va-cs-06-messages-desktop-3441fa91.jpg" alt="" loading="lazy" decoding="async" width="1440" height="260"><span class="gd-pin" style="left:32.6%;top:48.5%" aria-hidden="true">1</span></div></div></figure></div></section><section class="gd-task" id="customer-service-add-a-car-for-an-owner" data-gd-task><h2 class="gd-h2">Add a car for an owner</h2><p class="gd-p">Open <b class="gd-ui">Owners</b> &gt; <b class="gd-ui">Add a car for an owner</b> (fleet: under Cars). You enter everything for the owner; they never fill in the application.</p><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">The owner: find them by name, email or phone, or choose New owner and enter the name, email, phone and address.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">The car: type the VIN. The car is looked up at once and shown in one line with the year, make, model, trim and details (Edit if something is wrong). No VIN at hand: add it by its plate and choose the year, make and model. Tap the colour and check the class. Upload the ownership permit, the insurance slip and the lender&#39;s information if you have them. Photos are optional.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Terms and first invoice: what was agreed with the owner, to the cent. An Admin checks them before anything is sent.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t">Who sourced the owner: Entered for CarmaCars, or I sourced this owner. How the owner signs: by email, or on paper.</div></li><li><span class="gd-n" aria-hidden="true">5</span><div class="gd-t">Press <b class="gd-ui">Add the car and send to an Admin</b>. The application waits in the Admin&#39;s Applications, marked Entered by staff with your name. When the Admin approves, the owner gets one email to review and sign.</div></li></ol></div></section><section class="gd-task" id="customer-service-owner-forms-forms-c-and-d" data-gd-task><h2 class="gd-h2">Owner forms (Forms C and D)</h2><div class="gd-stepblock gd-stepblock--below"><div class="gd-stepcol"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">Open <b class="gd-ui">Owner forms</b>. Each row is a scan an owner uploaded, with the witnesses and the status.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Press Open to read the scan. Check every page is there and signed, with each witness&#39;s signature and name.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Press <b class="gd-ui">Approve</b>, or <b class="gd-ui">Send back</b> with What to fix (the owner reads this).</div></li></ol></div><figure class="gd-fig gd-fig--desk"><div class="gd-browser"><div class="gd-bar" aria-hidden="true"><i></i><i></i><i></i><span class="gd-addr">carmacars.ca/va/owner-forms</span></div><div class="gd-imgwrap" style="aspect-ratio:1440/300"><img src="/guides/img/va-cs-08-owner-forms-desktop-eceaee0b.jpg" alt="" loading="lazy" decoding="async" width="1440" height="300"><span class="gd-pin" style="left:68.6%;top:36.7%" aria-hidden="true">2</span><span class="gd-pin" style="left:76.7%;top:36.7%" aria-hidden="true">3</span></div></div></figure></div></section><section class="gd-task" id="customer-service-a-rental-agreement-signed-on-paper" data-gd-task><h2 class="gd-h2">A rental agreement signed on paper</h2><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">Open the booking. Under Signed on paper, press <b class="gd-ui">Record paper signature</b>.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Choose the Rental agreement, or the booking change the renter signed.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Check Signed by and Date signed, and upload the scan of every signed page.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t">Press <b class="gd-ui">Record signature</b>. It counts as signed, and the renter is not asked to sign again.</div></li></ol></div></section><section class="gd-task" id="customer-service-signatures-on-the-spot-or-by-link" data-gd-task><h2 class="gd-h2">Signatures on the spot, or by link</h2><p class="gd-p">A renter or an additional driver who has not signed yet.</p><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">On the booking, press <b class="gd-ui">Sign now on this device</b>. Confirm the name and that you saw the original licence, then <b class="gd-ui">Hand the device to</b> the signer.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Or press <b class="gd-ui">Email the signing link</b> or <b class="gd-ui">Text the signing link</b>: they sign on their own phone.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">The licence comes first: the renter uploads it from the request, and the offer cannot be accepted without it.</div></li></ol></div></section><section class="gd-task" id="customer-service-check-renter-documents" data-gd-task><h2 class="gd-h2">Check renter documents</h2><p class="gd-p">The renter&#39;s licence photos, selfie and proof of coverage, before the handover.</p><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">Open the task &quot;identity documents or coverage proof to review&quot;, or open the booking: <b class="gd-ui">Review</b> shows the documents of any booking being arranged or under way, with no task needed.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Tick every check under a document, then press <b class="gd-ui">Approve</b>. Or type the reason the renter reads and press <b class="gd-ui">Reject</b>.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">The coverage: OPCF 27 shows the insurer, policy number and expiry; credit card coverage shows the card, its type and whether the name matches. Approve or reject it as a whole.</div></li></ol></div><aside class="gd-box"><span class="gd-lbl">Tip</span><div>Each opening is logged. An Admin can do the same from Admin &gt; To do.</div></aside></section><section class="gd-task" id="customer-service-a-change-to-a-confirmed-booking" data-gd-task><h2 class="gd-h2">A change to a confirmed booking</h2><p class="gd-p">On a booking&#39;s Changes tab you can propose new dates, times or another car, as an Admin does: set the change, write the reason, press <b class="gd-ui">Preview the price</b>, then <b class="gd-ui">Send to the renter</b>. The renter has 48 hours to accept and sign the amendment. You also send a new signing link to an additional driver from the booking screen.</p></section><section class="gd-task" id="customer-service-a-late-return" data-gd-task><h2 class="gd-h2">A late return</h2><p class="gd-p">A booking past its return time shows the late return panel. Work it in order:</p><div class="gd-tablewrap"><table class="gd-table"><thead><tr><th scope="col">Button</th><th scope="col">When</th></tr></thead><tbody><tr><td><b class="gd-ui">Log a call</b></td><td>Record each call to the renter and what they said.</td></tr><tr><td><b class="gd-ui">Send T13</b></td><td>The first late notice email.</td></tr><tr><td><b class="gd-ui">Send T14 (final notice)</b></td><td>The final notice.</td></tr><tr><td><b class="gd-ui">Request disable</b></td><td>Ask an Admin to approve disabling the car.</td></tr><tr><td><b class="gd-ui">Open an incident</b></td><td>When the car is not coming back as planned.</td></tr></tbody></table></div></section>');
select app.guide_release_section('va', 'fleet', 'chapter', 'finance', 'You keep the cars moving: field jobs, daily checks, photo reviews after returns, and the listing pipeline with its duplicate check and plate covering.

Your rail: Queue, Today, Field jobs, Daily checks, Photo reviews, Calendar, Listings, Similar cars, Find a renter and Scorecard.

## Schedule field jobs

1. Handovers and returns without a job are listed first. Every booking needs one.
2. Press **Schedule**: choose the kind, car, when, place, field staff and instructions.
3. Jobs, next three days: each with its field staff and whether they acknowledged it.
4. Change a job with **Assign**, **Reassign**, **Move** or **Cancel**.

![](/guides/img/va-fleet-02-field-jobs-desktop-b985927b.jpg "desktop; size: 1230 1180; address: carmacars.ca/va/fleet; pins: 1 15.4 10.4, 2 78.9 12.7, 3 11.4 68.6, 4 78.9 83.9")

## Daily checks

Twice a day: the opening check by 9:00 and the closing check by 18:00.

1. Open **Daily checks** and choose **Opening check** or **Closing check**.
2. Each line shows what was found. Tick OK, or Problem with a note.
3. Press **Save the opening check** (or **Save the closing check**). You can save it again.

![](/guides/img/va-fleet-03-daily-checks-desktop-be06d6c0.jpg "desktop; size: 1230 820; address: carmacars.ca/va/checks; pins: 1 6.5 15.4, 2 44.7 42.0, 3 64.2 94.0")

## Photo reviews after a return

After each return, the field photo set waits under **Photo reviews**. Compare it with the pickup set. Press **Review done**, or **Ask for a re-shoot** if a photo is missing or unclear.

## Similar cars

A possible duplicate never keeps a car off the site: it shows on the car''s checklist until you decide. Only Same car takes it off.

1. Each flag shows the car, what it looks like (same VIN, plate, photo or specs) and the other car.
2. Compare the permit, the plate and the photos.
3. Press **Not a duplicate** with a note when they are different cars, or **Same car** when they are.

![](/guides/img/va-fleet-06-similar-cars-desktop-562b0382.jpg "desktop; size: 1230 460; address: carmacars.ca/va/similar-cars; pins: 1 23.6 30.4, 3 94.8 30.4")

## Rates and kilometres

From a listing, press **The car and its rates**, or open the car from Field jobs.

1. Type the rates an Admin set. Only the daily rate is needed; the others follow from it when empty. The weekend rate is a price per day for each day that starts on a Friday or Saturday.
2. Keep **Use the defaults** for the kilometres, or choose **Custom for this car**.
3. Check What renters pay under the fields, then press **Save the rates**. Rates, kilometres and deposit save together.

## Listings and covering plates

1. Open **Listings**. A draft waiting shows Needs review. Open it.
2. The copy is written by itself (change a line only if you must: it is then kept). Check the photos: on each public photo, cover the plate or mark it not visible.

![](/guides/img/va-fleet-05-listings-desktop-d2672e0a.jpg "desktop; size: 1230 340; address: carmacars.ca/va/listings; pins: 1 54.5 49.1")

3. Press **Cover the plate**. Check the suggested box; **Suggest the plate** asks again.
4. Drag over a plate to draw a box; drag a box to move it, its corner to resize it.
5. Choose **A CarmaCars plate**, **Pixelation** or **Blur**, then **Save the covered photo**.
6. No plate in the shot? **No plate visible on this photo**.

![](/guides/img/admin-11-plate-editor-phone-95d5afd2.jpg "phone; size: 390 776; pins: 3 52.6 78.9, 4 50.0 43.8, 5 61.5 62.1, 6 43.1 92.3")

> Watch out: The plate check never holds a car back: a photo whose plate is not checked stays private, and goes public by itself once it is covered or marked. The covered photo replaces the public one; the original is kept privately.

## Publish now

Customer service and fleet publish a car themselves; nothing has to be finished first.

1. Open the car from Listings or Field jobs. Its listing says why it is not on the site yet; press **Publish now**. With no rates yet it uses the suggested rates (similar cars, else the class defaults).
2. What is still open (paperwork, details, photos, No VIN yet for a car added by its plate, a possible duplicate) shows as warnings after Publish now and on the car. None of them stops publishing.
3. New cars with their rates usually go on the site by themselves (Publish new cars automatically, on by default). A car taken off the site by staff waits for Publish now.

> Tip: A car not on the fleet insurance policy yet can be requested, offered and paid for, but never handed over until the insurer confirms it. Requests and offers for such a car show a warning.

## Calendar sync with Turo and other platforms

**Cars** > **Calendar sync**: a car listed on Turo or Getaround must never be booked twice.

1. Turo has no calendar link: Turo''s trip emails come in by themselves, find their car by themselves (Turo car number, plate, VIN, year, make, model, trim, colour, what earlier emails taught) and block it with the turnaround. Nothing to set up per car.
2. An email the reader cannot place waits as "Which car is this?": press **Which car is this?** and press the right car (best guesses first). It is remembered for that car''s next emails. If the dates or trip number are missing: **Add as a Turo trip** (choose the car, check the dates) or **Dismiss**. A trip whose email did not come: **Add a Turo trip** on the car.
3. Each Turo trip shows the guest''s name and phone when Turo''s email includes them. Contact a Turo guest only about their trip, never with promotions.
4. Turo cannot read our calendar: under "Block on Turo", block each CarmaCars booking on the car''s Turo calendar, then press **Done on Turo**. Dates that changed or a booking cancelled here show the dates to free on Turo.
5. Getaround, Google Calendar or another platform with a calendar (iCal) link: open **Add a calendar link**, choose the platform, paste it and press **Add the link**. Copy the car''s CarmaCars link for that platform with **Copy** and paste it into the platform''s calendar import.
6. A double booking raises an urgent task for you and an email: move, swap or cancel one trip. A link that stops working raises a task after 3 failed reads: copy it from the platform again.
', 'Fleet', 'Field jobs, daily checks, photo reviews, similar cars and listings.',
  'You keep the cars moving: field jobs, daily checks, photo reviews after returns, and the listing pipeline with its duplicate check and plate covering.

Your rail: Queue, Today, Field jobs, Daily checks, Photo reviews, Calendar, Listings, Similar cars, Find a renter and Scorecard.

## Schedule field jobs

1. Handovers and returns without a job are listed first. Every booking needs one.
2. Press **Schedule**: choose the kind, car, when, place, field staff and instructions.
3. Jobs, next three days: each with its field staff and whether they acknowledged it.
4. Change a job with **Assign**, **Reassign**, **Move** or **Cancel**.

![](/guides/img/va-fleet-02-field-jobs-desktop-b985927b.jpg "desktop; size: 1230 1180; address: carmacars.ca/va/fleet; pins: 1 15.4 10.4, 2 78.9 12.7, 3 11.4 68.6, 4 78.9 83.9")

## Daily checks

Twice a day: the opening check by 9:00 and the closing check by 18:00.

1. Open **Daily checks** and choose **Opening check** or **Closing check**.
2. Each line shows what was found. Tick OK, or Problem with a note.
3. Press **Save the opening check** (or **Save the closing check**). You can save it again.

![](/guides/img/va-fleet-03-daily-checks-desktop-be06d6c0.jpg "desktop; size: 1230 820; address: carmacars.ca/va/checks; pins: 1 6.5 15.4, 2 44.7 42.0, 3 64.2 94.0")

## Check a car out or in

Fleet, Sales and Customer service check cars out and in from the booking.

1. On a confirmed booking press **Check out (pickup)**; on a booking on rent, **Check in (return)**. Today lists the ones due, each with its button.
2. The checklist field staff use opens: readings (km and fuel or charge), the photo set with the plate and the gauges, damage close-ups and both signatures.
3. Afterwards press **Photo report**: times, Late by, kilometres, fuel, photos and the return charges. Fleet waives a charge with **Waive** and a reason.

## Photo reviews after a return

After each return, the field photo set waits under **Photo reviews**. Compare it with the pickup set. Press **Review done**, or **Ask for a re-shoot** if a photo is missing or unclear.

## Similar cars

A possible duplicate never keeps a car off the site: it shows on the car''s checklist until you decide. Only Same car takes it off.

1. Each flag shows the car, what it looks like (same VIN, plate, photo or specs) and the other car.
2. Compare the permit, the plate and the photos.
3. Press **Not a duplicate** with a note when they are different cars, or **Same car** when they are.

![](/guides/img/va-fleet-06-similar-cars-desktop-562b0382.jpg "desktop; size: 1230 460; address: carmacars.ca/va/similar-cars; pins: 1 23.6 30.4, 3 94.8 30.4")

## Rates and kilometres

From a listing, press **The car and its rates**, or open the car from Field jobs.

1. Type the rates an Admin set. Only the daily rate is needed; the others follow from it when empty. The weekend rate is a price per day for each day that starts on a Friday or Saturday.
2. Keep **Use the defaults** for the kilometres, or choose **Custom for this car**.
3. Check What renters pay under the fields, then press **Save the rates**. Rates, kilometres and deposit save together.

## Listings and covering plates

1. Open **Listings**. A draft waiting shows Needs review. Open it.
2. The copy is written by itself (change a line only if you must: it is then kept). Check the photos: on each public photo, cover the plate or mark it not visible.

![](/guides/img/va-fleet-05-listings-desktop-d2672e0a.jpg "desktop; size: 1230 340; address: carmacars.ca/va/listings; pins: 1 54.5 49.1")

3. Press **Cover the plate**. Check the suggested box; **Suggest the plate** asks again.
4. Drag over a plate to draw a box; drag a box to move it, its corner to resize it.
5. Choose **A CarmaCars plate**, **Pixelation** or **Blur**, then **Save the covered photo**.
6. No plate in the shot? **No plate visible on this photo**.

![](/guides/img/admin-11-plate-editor-phone-95d5afd2.jpg "phone; size: 390 776; pins: 3 52.6 78.9, 4 50.0 43.8, 5 61.5 62.1, 6 43.1 92.3")

> Watch out: The plate check never holds a car back: a photo whose plate is not checked stays private, and goes public by itself once it is covered or marked. The covered photo replaces the public one; the original is kept privately.

## Publish now

Customer service and fleet publish a car themselves; nothing has to be finished first.

1. Open the car from Listings or Field jobs. Its listing says why it is not on the site yet; press **Publish now**. With no rates yet it uses the suggested rates (similar cars, else the class defaults).
2. What is still open (paperwork, details, photos, No VIN yet for a car added by its plate, a possible duplicate) shows as warnings after Publish now and on the car. None of them stops publishing.
3. New cars with their rates usually go on the site by themselves (Publish new cars automatically, on by default). A car taken off the site by staff waits for Publish now.

> Tip: A car not on the fleet insurance policy yet can be requested, offered and paid for, but never handed over until the insurer confirms it. Requests and offers for such a car show a warning.

## Calendar sync with Turo and other platforms

**Cars** > **Calendar sync**: a car listed on Turo or Getaround must never be booked twice.

1. Turo has no calendar link: Turo''s trip emails come in by themselves, find their car by themselves (Turo car number, plate, VIN, year, make, model, trim, colour, what earlier emails taught) and block it with the turnaround. Nothing to set up per car.
2. An email the reader cannot place waits as "Which car is this?": press **Which car is this?** and press the right car (best guesses first). It is remembered for that car''s next emails. If the dates or trip number are missing: **Add as a Turo trip** (choose the car, check the dates) or **Dismiss**. A trip whose email did not come: **Add a Turo trip** on the car.
3. Each Turo trip shows the guest''s name and phone when Turo''s email includes them. Contact a Turo guest only about their trip, never with promotions.
4. Turo cannot read our calendar: under "Block on Turo", block each CarmaCars booking on the car''s Turo calendar, then press **Done on Turo**. Dates that changed or a booking cancelled here show the dates to free on Turo.
5. Getaround, Google Calendar or another platform with a calendar (iCal) link: open **Add a calendar link**, choose the platform, paste it and press **Add the link**. Copy the car''s CarmaCars link for that platform with **Copy** and paste it into the platform''s calendar import.
6. A double booking raises an urgent task for you and an email: move, swap or cancel one trip. A link that stops working raises a task after 3 failed reads: copy it from the platform again.
',
  '<p class="gd-p">You keep the cars moving: field jobs, daily checks, photo reviews after returns, and the listing pipeline with its duplicate check and plate covering.</p><p class="gd-p">Your rail: Queue, Today, Field jobs, Daily checks, Photo reviews, Calendar, Listings, Similar cars, Find a renter and Scorecard.</p><section class="gd-task" id="fleet-schedule-field-jobs" data-gd-task><h2 class="gd-h2">Schedule field jobs</h2><div class="gd-stepblock gd-stepblock--below"><div class="gd-stepcol"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">Handovers and returns without a job are listed first. Every booking needs one.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Press <b class="gd-ui">Schedule</b>: choose the kind, car, when, place, field staff and instructions.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Jobs, next three days: each with its field staff and whether they acknowledged it.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t">Change a job with <b class="gd-ui">Assign</b>, <b class="gd-ui">Reassign</b>, <b class="gd-ui">Move</b> or <b class="gd-ui">Cancel</b>.</div></li></ol></div><figure class="gd-fig gd-fig--desk"><div class="gd-browser"><div class="gd-bar" aria-hidden="true"><i></i><i></i><i></i><span class="gd-addr">carmacars.ca/va/fleet</span></div><div class="gd-imgwrap" style="aspect-ratio:1230/1180"><img src="/guides/img/va-fleet-02-field-jobs-desktop-b985927b.jpg" alt="" loading="lazy" decoding="async" width="1230" height="1180"><span class="gd-pin" style="left:15.4%;top:10.4%" aria-hidden="true">1</span><span class="gd-pin" style="left:78.9%;top:12.7%" aria-hidden="true">2</span><span class="gd-pin" style="left:11.4%;top:68.6%" aria-hidden="true">3</span><span class="gd-pin" style="left:78.9%;top:83.9%" aria-hidden="true">4</span></div></div></figure></div></section><section class="gd-task" id="fleet-daily-checks" data-gd-task><h2 class="gd-h2">Daily checks</h2><p class="gd-p">Twice a day: the opening check by 9:00 and the closing check by 18:00.</p><div class="gd-stepblock gd-stepblock--below"><div class="gd-stepcol"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">Open <b class="gd-ui">Daily checks</b> and choose <b class="gd-ui">Opening check</b> or <b class="gd-ui">Closing check</b>.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Each line shows what was found. Tick OK, or Problem with a note.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Press <b class="gd-ui">Save the opening check</b> (or <b class="gd-ui">Save the closing check</b>). You can save it again.</div></li></ol></div><figure class="gd-fig gd-fig--desk"><div class="gd-browser"><div class="gd-bar" aria-hidden="true"><i></i><i></i><i></i><span class="gd-addr">carmacars.ca/va/checks</span></div><div class="gd-imgwrap" style="aspect-ratio:1230/820"><img src="/guides/img/va-fleet-03-daily-checks-desktop-be06d6c0.jpg" alt="" loading="lazy" decoding="async" width="1230" height="820"><span class="gd-pin" style="left:6.5%;top:15.4%" aria-hidden="true">1</span><span class="gd-pin" style="left:44.7%;top:42%" aria-hidden="true">2</span><span class="gd-pin" style="left:64.2%;top:94%" aria-hidden="true">3</span></div></div></figure></div></section><section class="gd-task" id="fleet-check-a-car-out-or-in" data-gd-task><h2 class="gd-h2">Check a car out or in</h2><p class="gd-p">Fleet, Sales and Customer service check cars out and in from the booking.</p><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">On a confirmed booking press <b class="gd-ui">Check out (pickup)</b>; on a booking on rent, <b class="gd-ui">Check in (return)</b>. Today lists the ones due, each with its button.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">The checklist field staff use opens: readings (km and fuel or charge), the photo set with the plate and the gauges, damage close-ups and both signatures.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Afterwards press <b class="gd-ui">Photo report</b>: times, Late by, kilometres, fuel, photos and the return charges. Fleet waives a charge with <b class="gd-ui">Waive</b> and a reason.</div></li></ol></div></section><section class="gd-task" id="fleet-photo-reviews-after-a-return" data-gd-task><h2 class="gd-h2">Photo reviews after a return</h2><p class="gd-p">After each return, the field photo set waits under <b class="gd-ui">Photo reviews</b>. Compare it with the pickup set. Press <b class="gd-ui">Review done</b>, or <b class="gd-ui">Ask for a re-shoot</b> if a photo is missing or unclear.</p></section><section class="gd-task" id="fleet-similar-cars" data-gd-task><h2 class="gd-h2">Similar cars</h2><p class="gd-p">A possible duplicate never keeps a car off the site: it shows on the car&#39;s checklist until you decide. Only Same car takes it off.</p><div class="gd-stepblock gd-stepblock--below"><div class="gd-stepcol"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">Each flag shows the car, what it looks like (same VIN, plate, photo or specs) and the other car.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Compare the permit, the plate and the photos.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Press <b class="gd-ui">Not a duplicate</b> with a note when they are different cars, or <b class="gd-ui">Same car</b> when they are.</div></li></ol></div><figure class="gd-fig gd-fig--desk"><div class="gd-browser"><div class="gd-bar" aria-hidden="true"><i></i><i></i><i></i><span class="gd-addr">carmacars.ca/va/similar-cars</span></div><div class="gd-imgwrap" style="aspect-ratio:1230/460"><img src="/guides/img/va-fleet-06-similar-cars-desktop-562b0382.jpg" alt="" loading="lazy" decoding="async" width="1230" height="460"><span class="gd-pin" style="left:23.6%;top:30.4%" aria-hidden="true">1</span><span class="gd-pin" style="left:94.8%;top:30.4%" aria-hidden="true">3</span></div></div></figure></div></section><section class="gd-task" id="fleet-rates-and-kilometres" data-gd-task><h2 class="gd-h2">Rates and kilometres</h2><p class="gd-p">From a listing, press <b class="gd-ui">The car and its rates</b>, or open the car from Field jobs.</p><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">Type the rates an Admin set. Only the daily rate is needed; the others follow from it when empty. The weekend rate is a price per day for each day that starts on a Friday or Saturday.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Keep <b class="gd-ui">Use the defaults</b> for the kilometres, or choose <b class="gd-ui">Custom for this car</b>.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Check What renters pay under the fields, then press <b class="gd-ui">Save the rates</b>. Rates, kilometres and deposit save together.</div></li></ol></div></section><section class="gd-task" id="fleet-listings-and-covering-plates" data-gd-task><h2 class="gd-h2">Listings and covering plates</h2><div class="gd-stepblock gd-stepblock--below"><div class="gd-stepcol"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">Open <b class="gd-ui">Listings</b>. A draft waiting shows Needs review. Open it.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">The copy is written by itself (change a line only if you must: it is then kept). Check the photos: on each public photo, cover the plate or mark it not visible.</div></li></ol></div><figure class="gd-fig gd-fig--desk"><div class="gd-browser"><div class="gd-bar" aria-hidden="true"><i></i><i></i><i></i><span class="gd-addr">carmacars.ca/va/listings</span></div><div class="gd-imgwrap" style="aspect-ratio:1230/340"><img src="/guides/img/va-fleet-05-listings-desktop-d2672e0a.jpg" alt="" loading="lazy" decoding="async" width="1230" height="340"><span class="gd-pin" style="left:54.5%;top:49.1%" aria-hidden="true">1</span></div></div></figure></div><div class="gd-stepblock gd-stepblock--side"><div class="gd-stepcol"><ol class="gd-ol" start="3"><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Press <b class="gd-ui">Cover the plate</b>. Check the suggested box; <b class="gd-ui">Suggest the plate</b> asks again.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t">Drag over a plate to draw a box; drag a box to move it, its corner to resize it.</div></li><li><span class="gd-n" aria-hidden="true">5</span><div class="gd-t">Choose <b class="gd-ui">A CarmaCars plate</b>, <b class="gd-ui">Pixelation</b> or <b class="gd-ui">Blur</b>, then <b class="gd-ui">Save the covered photo</b>.</div></li><li><span class="gd-n" aria-hidden="true">6</span><div class="gd-t">No plate in the shot? <b class="gd-ui">No plate visible on this photo</b>.</div></li></ol></div><figure class="gd-fig gd-fig--phone"><div class="gd-phone"><div class="gd-imgwrap" style="aspect-ratio:390/776"><img src="/guides/img/admin-11-plate-editor-phone-95d5afd2.jpg" alt="" loading="lazy" decoding="async" width="390" height="776"><span class="gd-pin" style="left:52.6%;top:78.9%" aria-hidden="true">3</span><span class="gd-pin" style="left:50%;top:43.8%" aria-hidden="true">4</span><span class="gd-pin" style="left:61.5%;top:62.1%" aria-hidden="true">5</span><span class="gd-pin" style="left:43.1%;top:92.3%" aria-hidden="true">6</span></div></div></figure></div><aside class="gd-box gd-box--warn"><span class="gd-lbl">Watch out</span><div>The plate check never holds a car back: a photo whose plate is not checked stays private, and goes public by itself once it is covered or marked. The covered photo replaces the public one; the original is kept privately.</div></aside></section><section class="gd-task" id="fleet-publish-now" data-gd-task><h2 class="gd-h2">Publish now</h2><p class="gd-p">Customer service and fleet publish a car themselves; nothing has to be finished first.</p><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">Open the car from Listings or Field jobs. Its listing says why it is not on the site yet; press <b class="gd-ui">Publish now</b>. With no rates yet it uses the suggested rates (similar cars, else the class defaults).</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">What is still open (paperwork, details, photos, No VIN yet for a car added by its plate, a possible duplicate) shows as warnings after Publish now and on the car. None of them stops publishing.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">New cars with their rates usually go on the site by themselves (Publish new cars automatically, on by default). A car taken off the site by staff waits for Publish now.</div></li></ol></div><aside class="gd-box"><span class="gd-lbl">Tip</span><div>A car not on the fleet insurance policy yet can be requested, offered and paid for, but never handed over until the insurer confirms it. Requests and offers for such a car show a warning.</div></aside></section><section class="gd-task" id="fleet-calendar-sync-with-turo-and-other-platforms" data-gd-task><h2 class="gd-h2">Calendar sync with Turo and other platforms</h2><p class="gd-p"><b class="gd-ui">Cars</b> &gt; <b class="gd-ui">Calendar sync</b>: a car listed on Turo or Getaround must never be booked twice.</p><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">Turo has no calendar link: Turo&#39;s trip emails come in by themselves, find their car by themselves (Turo car number, plate, VIN, year, make, model, trim, colour, what earlier emails taught) and block it with the turnaround. Nothing to set up per car.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">An email the reader cannot place waits as &quot;Which car is this?&quot;: press <b class="gd-ui">Which car is this?</b> and press the right car (best guesses first). It is remembered for that car&#39;s next emails. If the dates or trip number are missing: <b class="gd-ui">Add as a Turo trip</b> (choose the car, check the dates) or <b class="gd-ui">Dismiss</b>. A trip whose email did not come: <b class="gd-ui">Add a Turo trip</b> on the car.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Each Turo trip shows the guest&#39;s name and phone when Turo&#39;s email includes them. Contact a Turo guest only about their trip, never with promotions.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t">Turo cannot read our calendar: under &quot;Block on Turo&quot;, block each CarmaCars booking on the car&#39;s Turo calendar, then press <b class="gd-ui">Done on Turo</b>. Dates that changed or a booking cancelled here show the dates to free on Turo.</div></li><li><span class="gd-n" aria-hidden="true">5</span><div class="gd-t">Getaround, Google Calendar or another platform with a calendar (iCal) link: open <b class="gd-ui">Add a calendar link</b>, choose the platform, paste it and press <b class="gd-ui">Add the link</b>. Copy the car&#39;s CarmaCars link for that platform with <b class="gd-ui">Copy</b> and paste it into the platform&#39;s calendar import.</div></li><li><span class="gd-n" aria-hidden="true">6</span><div class="gd-t">A double booking raises an urgent task for you and an email: move, swap or cancel one trip. A link that stops working raises a task after 3 failed reads: copy it from the platform again.</div></li></ol></div></section>');
select app.guide_release_section('field', 'my-jobs', 'chapter', 'start-here', 'Your day, in order: handovers, returns, deliveries, moves and photo shoots. Each job card has the car, the plate, the place and the time.

## Your job list

1. The menu: **My jobs**, **Report a problem**, **Add a rental**, **My sales**, **Referrals** and **Profile**. **Sign out** is top right.
2. Switch between **Today** and **Tomorrow**. Jobs are in time order.
3. Each card: the kind, the time, the status, the car and plate.
4. Press **Open the job** to start.
5. Moving a car that has no job? Use Vehicle moves (see below).

![](/guides/img/field-01-today-phone-421eca90.jpg "phone; size: 390 945; pins: 1 7.7 19.6, 2 76.9 27.5, 3 89.7 37.0, 4 88.5 46.6, 5 76.9 56.3")

> Tip: Need help on a job? Call CarmaCars at 289-312-5991. The link is at the bottom of My jobs.

## Open a job

1. The card shows the kind, the time, the car, the plate and colour.
2. The address, with **Open in maps** for directions.
3. For a handover: the booking, the renter''s name and phone, the Card on File and the licence on file.
4. Press **Acknowledge** so the office knows you have it. Then press **Start** when you are with the car.

![](/guides/img/field-02-job-phone-a0feec93.jpg "phone; size: 390 635; pins: 1 94.9 51.2, 2 94.9 64.3, 3 94.9 79.5, 4 94.9 93.9")

## Move a car

1. Under Vehicle moves, choose the Car and Why (for example Reposition).
2. Fill in From and the Odometer (km).
3. Press **Start a move**. When you arrive, press **End the move** and enter the odometer again.

![](/guides/img/field-01-today-phone-27dfe7af.jpg "phone; size: 390 450; pins: 1 87.2 22.2, 2 87.2 60.4, 3 87.2 93.3")

## Documents to sign

Your staff agreement, when CarmaCars sends it.

1. My jobs shows "You have a document to sign". Press **Read and sign**.
2. Check the key values at the top (your role, wage and start date), then press **Read the PDF** and read it.
3. Press **Sign**. Your full legal name is your signature (or press **Draw instead**).
', 'My jobs', 'Your job list, a job card, maps and car moves.',
  'Your day, in order: handovers, returns, deliveries, moves and photo shoots. Each job card has the car, the plate, the place and the time.

## Your job list

1. The menu: **My jobs**, **Report a problem**, **Add a rental**, **My sales**, **Referrals** and **Profile**. **Sign out** is top right.
2. Switch between **Today** and **Tomorrow**. Jobs are in time order.
3. Each card: the kind, the time, the status, the car and plate.
4. A handover or a return has its own button: **Check out (pickup)** or **Check in (return)**. One tap acknowledges and starts the job and opens its photo checklist. Other jobs: press **Open the job**.
5. Moving a car that has no job? Use Vehicle moves (see below).

![](/guides/img/field-01-today-phone-421eca90.jpg "phone; size: 390 945; pins: 1 7.7 19.6, 2 76.9 27.5, 3 89.7 37.0, 4 88.5 46.6, 5 76.9 56.3")

> Tip: Need help on a job? Call CarmaCars at 289-312-5991. The link is at the bottom of My jobs.

## Open a job

1. The card shows the kind, the time, the car, the plate and colour.
2. The address, with **Open in maps** for directions.
3. For a handover: the booking, the renter''s name and phone, the Card on File and the licence on file.
4. Press **Acknowledge** so the office knows you have it. Then press **Start** when you are with the car.

![](/guides/img/field-02-job-phone-a0feec93.jpg "phone; size: 390 635; pins: 1 94.9 51.2, 2 94.9 64.3, 3 94.9 79.5, 4 94.9 93.9")

## Move a car

1. Under Vehicle moves, choose the Car and Why (for example Reposition).
2. Fill in From and the Odometer (km).
3. Press **Start a move**. When you arrive, press **End the move** and enter the odometer again.

![](/guides/img/field-01-today-phone-27dfe7af.jpg "phone; size: 390 450; pins: 1 87.2 22.2, 2 87.2 60.4, 3 87.2 93.3")

## Documents to sign

Your staff agreement, when CarmaCars sends it.

1. My jobs shows "You have a document to sign". Press **Read and sign**.
2. Check the key values at the top (your role, wage and start date), then press **Read the PDF** and read it.
3. Press **Sign**. Your full legal name is your signature (or press **Draw instead**).
',
  '<p class="gd-p">Your day, in order: handovers, returns, deliveries, moves and photo shoots. Each job card has the car, the plate, the place and the time.</p><section class="gd-task" id="my-jobs-your-job-list" data-gd-task><h2 class="gd-h2">Your job list</h2><div class="gd-stepblock gd-stepblock--side"><div class="gd-stepcol"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">The menu: <b class="gd-ui">My jobs</b>, <b class="gd-ui">Report a problem</b>, <b class="gd-ui">Add a rental</b>, <b class="gd-ui">My sales</b>, <b class="gd-ui">Referrals</b> and <b class="gd-ui">Profile</b>. <b class="gd-ui">Sign out</b> is top right.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Switch between <b class="gd-ui">Today</b> and <b class="gd-ui">Tomorrow</b>. Jobs are in time order.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Each card: the kind, the time, the status, the car and plate.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t">A handover or a return has its own button: <b class="gd-ui">Check out (pickup)</b> or <b class="gd-ui">Check in (return)</b>. One tap acknowledges and starts the job and opens its photo checklist. Other jobs: press <b class="gd-ui">Open the job</b>.</div></li><li><span class="gd-n" aria-hidden="true">5</span><div class="gd-t">Moving a car that has no job? Use Vehicle moves (see below).</div></li></ol></div><figure class="gd-fig gd-fig--phone"><div class="gd-phone"><div class="gd-imgwrap" style="aspect-ratio:390/945"><img src="/guides/img/field-01-today-phone-421eca90.jpg" alt="" loading="lazy" decoding="async" width="390" height="945"><span class="gd-pin" style="left:7.7%;top:19.6%" aria-hidden="true">1</span><span class="gd-pin" style="left:76.9%;top:27.5%" aria-hidden="true">2</span><span class="gd-pin" style="left:89.7%;top:37%" aria-hidden="true">3</span><span class="gd-pin" style="left:88.5%;top:46.6%" aria-hidden="true">4</span><span class="gd-pin" style="left:76.9%;top:56.3%" aria-hidden="true">5</span></div></div></figure></div><aside class="gd-box"><span class="gd-lbl">Tip</span><div>Need help on a job? Call CarmaCars at 289-312-5991. The link is at the bottom of My jobs.</div></aside></section><section class="gd-task" id="my-jobs-open-a-job" data-gd-task><h2 class="gd-h2">Open a job</h2><div class="gd-stepblock gd-stepblock--side"><div class="gd-stepcol"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">The card shows the kind, the time, the car, the plate and colour.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">The address, with <b class="gd-ui">Open in maps</b> for directions.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">For a handover: the booking, the renter&#39;s name and phone, the Card on File and the licence on file.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t">Press <b class="gd-ui">Acknowledge</b> so the office knows you have it. Then press <b class="gd-ui">Start</b> when you are with the car.</div></li></ol></div><figure class="gd-fig gd-fig--phone"><div class="gd-phone"><div class="gd-imgwrap" style="aspect-ratio:390/635"><img src="/guides/img/field-02-job-phone-a0feec93.jpg" alt="" loading="lazy" decoding="async" width="390" height="635"><span class="gd-pin" style="left:94.9%;top:51.2%" aria-hidden="true">1</span><span class="gd-pin" style="left:94.9%;top:64.3%" aria-hidden="true">2</span><span class="gd-pin" style="left:94.9%;top:79.5%" aria-hidden="true">3</span><span class="gd-pin" style="left:94.9%;top:93.9%" aria-hidden="true">4</span></div></div></figure></div></section><section class="gd-task" id="my-jobs-move-a-car" data-gd-task><h2 class="gd-h2">Move a car</h2><div class="gd-stepblock gd-stepblock--side"><div class="gd-stepcol"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">Under Vehicle moves, choose the Car and Why (for example Reposition).</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Fill in From and the Odometer (km).</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Press <b class="gd-ui">Start a move</b>. When you arrive, press <b class="gd-ui">End the move</b> and enter the odometer again.</div></li></ol></div><figure class="gd-fig gd-fig--phone"><div class="gd-phone"><div class="gd-imgwrap" style="aspect-ratio:390/450"><img src="/guides/img/field-01-today-phone-27dfe7af.jpg" alt="" loading="lazy" decoding="async" width="390" height="450"><span class="gd-pin" style="left:87.2%;top:22.2%" aria-hidden="true">1</span><span class="gd-pin" style="left:87.2%;top:60.4%" aria-hidden="true">2</span><span class="gd-pin" style="left:87.2%;top:93.3%" aria-hidden="true">3</span></div></div></figure></div></section><section class="gd-task" id="my-jobs-documents-to-sign" data-gd-task><h2 class="gd-h2">Documents to sign</h2><p class="gd-p">Your staff agreement, when CarmaCars sends it.</p><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">My jobs shows &quot;You have a document to sign&quot;. Press <b class="gd-ui">Read and sign</b>.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Check the key values at the top (your role, wage and start date), then press <b class="gd-ui">Read the PDF</b> and read it.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Press <b class="gd-ui">Sign</b>. Your full legal name is your signature (or press <b class="gd-ui">Draw instead</b>).</div></li></ol></div></section>');
select app.guide_release_section('field', 'a-handover', 'chapter', 'my-jobs', 'You give the renter the keys only after every check passes. The steps guide you one by one: press Next after each, Back to go back.

## Before you start: the ready check

The first step lists what must be done before the car can go: signed, paid, ID checked, deposit.

1. Each line should show a green tick: identity verified, coverage confirmed, additional drivers accepted, the booking holds the calendar, deposit taken.
2. All green? Press **Next**.
3. Anything not ready? Press **Stop: do not release the car** and call the office.

![](/guides/img/field-21-handover-01-ready-phone-5ac4e7df.jpg "phone; size: 390 995; pins: 1 93.6 71.9, 2 76.9 98.0")

> Watch out: Never hand over keys if the ready check fails, the renter does not match the photo on file, or they do not have their original licence or the card on file. Stop and call us.

## The steps, one by one

:::phones
1. Car ready: fuel full or charged 80%, clean, extras in. **Yes** or **No**, with a note for Fleet. ![](/guides/img/field-22-handover-02-car-ready-phone-7fef7a1d.jpg "phone; size: 390 385")
2. Is this the renter? Compare the person with the name and photo on file. ![](/guides/img/field-23-handover-03-renter-phone-b718388d.jpg "phone; size: 390 325")
3. Original licence: name, photo and expiry match. A photo of a licence is not enough. ![](/guides/img/field-24-handover-04-licence-phone-3a13ae57.jpg "phone; size: 390 405")
4. Card on File: you have seen the physical card with the same last four digits, in the renter''s name. ![](/guides/img/field-25-handover-05-card-phone-bb24ccc4.jpg "phone; size: 390 265")
5. Odometer: type the reading in km. ![](/guides/img/field-26-handover-06-odometer-phone-9234054f.jpg "phone; size: 390 265")
6. Fuel or charge: slide to the level on the gauge. ![](/guides/img/field-27-handover-07-fuel-phone-a5dec192.jpg "phone; size: 390 275")
:::

:::phones
7. Keys: how many keys and fobs you hand over. Use **+** and **−**. ![](/guides/img/field-28-handover-08-keys-phone-8de46c31.jpg "phone; size: 390 235")
8. Photo set: 19 photos in order. **Take** each one; **Retake** if needed. ![](/guides/img/field-29-handover-09-photos-phone-4a0e3d9c.jpg "phone; size: 390 405")
9. Damage: tap the car diagram where it is, choose Where and Type, then **Add the damage**. ![](/guides/img/field-30-handover-10-damage-phone-923e28fe.jpg "phone; size: 390 605")
10. Tracker: it should say in place and reporting. **Check again** if not. ![](/guides/img/field-31-handover-11-tracker-phone-0107b84a.jpg "phone; size: 390 295")
11. Renter reviews: the renter reads the summary of odometer, fuel, keys, photos and damage. ![](/guides/img/field-32-handover-12-summary-phone-96736994.jpg "phone; size: 390 365")
12. Signatures: the renter signs, then you. **Use this signature** for each. ![](/guides/img/field-33-handover-13-signatures-phone-537ff2e3.jpg "phone; size: 390 405")
:::

13. Press **Hand over the keys**. You see "Handed over. The rental has started."

## Add-ons to put in the car

A booking may come with add-ons: a baby seat, a child or booster seat, flowers, an umbrella, a phone charger or a prepaid full tank.

1. Open the job. Under Put in the car you see each add-on, how many, and what to do (for example "Put the bouquet on the front passenger seat").
2. Put every item in the car before the handover. The Car ready step lists them again.
3. Prepaid fuel: the renter may return the car at any fuel level. Do not charge for fuel at the return.
4. A chauffeur on the booking: Fleet tells you who drives and when.

> Tip: An item missing? Write it in the note for Fleet on the Car ready step and call the office before the handover.

> Tip: The photo count shows "19 of 19 photos taken · all uploaded" when the set is complete. The first photo must show the plate. Open circles on the damage diagram were recorded before; add only what is new.
', 'A handover', 'The ready check, ID, card, odometer, photos, damage, signatures and the keys.',
  'You give the renter the keys only after every check passes. The steps guide you one by one: press Next after each, Back to go back.

## Before you start: the ready check

The first step lists what must be done before the car can go: signed, paid, ID checked, deposit.

1. Each line should show a green tick: identity verified, coverage confirmed, additional drivers accepted, the booking holds the calendar, deposit taken.
2. All green? Press **Next**.
3. Anything not ready? Press **Stop: do not release the car** and call the office.

![](/guides/img/field-21-handover-01-ready-phone-5ac4e7df.jpg "phone; size: 390 995; pins: 1 93.6 71.9, 2 76.9 98.0")

> Watch out: Never hand over keys if the ready check fails, the renter does not match the photo on file, or they do not have their original licence or the card on file. Stop and call us.

## The steps, one by one

:::phones
1. Car ready: fuel full or charged 80%, clean, extras in. **Yes** or **No**, with a note for Fleet. ![](/guides/img/field-22-handover-02-car-ready-phone-7fef7a1d.jpg "phone; size: 390 385")
2. Is this the renter? Compare the person with the name and photo on file. ![](/guides/img/field-23-handover-03-renter-phone-b718388d.jpg "phone; size: 390 325")
3. Original licence: name, photo and expiry match. A photo of a licence is not enough. ![](/guides/img/field-24-handover-04-licence-phone-3a13ae57.jpg "phone; size: 390 405")
4. Card on File: you have seen the physical card with the same last four digits, in the renter''s name. ![](/guides/img/field-25-handover-05-card-phone-bb24ccc4.jpg "phone; size: 390 265")
5. Odometer: type the reading in km. ![](/guides/img/field-26-handover-06-odometer-phone-9234054f.jpg "phone; size: 390 265")
6. Fuel or charge: slide to the level on the gauge. ![](/guides/img/field-27-handover-07-fuel-phone-a5dec192.jpg "phone; size: 390 275")
:::

:::phones
7. Keys: how many keys and fobs you hand over. Use **+** and **−**. ![](/guides/img/field-28-handover-08-keys-phone-8de46c31.jpg "phone; size: 390 235")
8. Photo set: 19 photos in order. **Take** each one; **Retake** if needed. ![](/guides/img/field-29-handover-09-photos-phone-4a0e3d9c.jpg "phone; size: 390 405")
9. Damage: tap the car diagram where it is, choose Where and Type, then **Add the damage**. ![](/guides/img/field-30-handover-10-damage-phone-923e28fe.jpg "phone; size: 390 605")
10. Tracker: it should say in place and reporting. **Check again** if not. ![](/guides/img/field-31-handover-11-tracker-phone-0107b84a.jpg "phone; size: 390 295")
11. Renter reviews: the renter reads the summary of odometer, fuel, keys, photos and damage. ![](/guides/img/field-32-handover-12-summary-phone-96736994.jpg "phone; size: 390 365")
12. Signatures: the renter signs, then you. **Use this signature** for each. ![](/guides/img/field-33-handover-13-signatures-phone-537ff2e3.jpg "phone; size: 390 405")
:::

13. Press **Hand over the keys**. You see "Checked out. The rental has started." The renter gets the photo report by email and in their Documents.

> Tip: Photos wait on the phone without a connection and upload by themselves when it returns; the count shows what is still uploading. Each photo keeps its time, and the place when your phone allows location.

## Sign now on this device

The renter (or an additional driver) has not signed the rental agreement yet? They sign on your phone.

1. On the job, press **Sign now on this device**. It shows who still has to sign and whether their licence is on file.
2. Check the person: the name matches their licence, and you saw the original licence. Tick both. No licence on file? Press **Photograph: Licence, front** (and the back and the selfie).
3. Press **Hand the device to** and their name. They read the agreements (CarmaCars'' and Blind Spot''s), tick the statements and sign with their name or their finger.
4. They hand the phone back: press **Back to the staff view**. The signature record says it was signed in person, collected by you, on your phone.

## Add-ons to put in the car

A booking may come with add-ons: a baby seat, a child or booster seat, flowers, an umbrella, a phone charger or a prepaid full tank.

1. Open the job. Under Put in the car you see each add-on, how many, and what to do (for example "Put the bouquet on the front passenger seat").
2. Put every item in the car before the handover. The Car ready step lists them again.
3. Prepaid fuel: the renter may return the car at any fuel level. Do not charge for fuel at the return.
4. A chauffeur on the booking: Fleet tells you who drives and when.

> Tip: An item missing? Write it in the note for Fleet on the Car ready step and call the office before the handover.

> Tip: The photo count shows "19 of 19 photos taken · all uploaded" when the set is complete. The first photo must show the plate. Open circles on the damage diagram were recorded before; add only what is new.
',
  '<p class="gd-p">You give the renter the keys only after every check passes. The steps guide you one by one: press Next after each, Back to go back.</p><section class="gd-task" id="a-handover-before-you-start-the-ready-check" data-gd-task><h2 class="gd-h2">Before you start: the ready check</h2><p class="gd-p">The first step lists what must be done before the car can go: signed, paid, ID checked, deposit.</p><div class="gd-stepblock gd-stepblock--side"><div class="gd-stepcol"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">Each line should show a green tick: identity verified, coverage confirmed, additional drivers accepted, the booking holds the calendar, deposit taken.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">All green? Press <b class="gd-ui">Next</b>.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Anything not ready? Press <b class="gd-ui">Stop: do not release the car</b> and call the office.</div></li></ol></div><figure class="gd-fig gd-fig--phone"><div class="gd-phone"><div class="gd-imgwrap" style="aspect-ratio:390/995"><img src="/guides/img/field-21-handover-01-ready-phone-5ac4e7df.jpg" alt="" loading="lazy" decoding="async" width="390" height="995"><span class="gd-pin" style="left:93.6%;top:71.9%" aria-hidden="true">1</span><span class="gd-pin" style="left:76.9%;top:98%" aria-hidden="true">2</span></div></div></figure></div><aside class="gd-box gd-box--warn"><span class="gd-lbl">Watch out</span><div>Never hand over keys if the ready check fails, the renter does not match the photo on file, or they do not have their original licence or the card on file. Stop and call us.</div></aside></section><section class="gd-task" id="a-handover-the-steps-one-by-one" data-gd-task><h2 class="gd-h2">The steps, one by one</h2><div class="gd-phones"><div class="gd-pcell"><div class="gd-pcap"><span class="gd-n" aria-hidden="true">1</span><div>Car ready: fuel full or charged 80%, clean, extras in. <b class="gd-ui">Yes</b> or <b class="gd-ui">No</b>, with a note for Fleet.</div></div><figure class="gd-fig gd-fig--phone"><div class="gd-phone"><div class="gd-imgwrap" style="aspect-ratio:390/385"><img src="/guides/img/field-22-handover-02-car-ready-phone-7fef7a1d.jpg" alt="" loading="lazy" decoding="async" width="390" height="385"></div></div></figure></div><div class="gd-pcell"><div class="gd-pcap"><span class="gd-n" aria-hidden="true">2</span><div>Is this the renter? Compare the person with the name and photo on file.</div></div><figure class="gd-fig gd-fig--phone"><div class="gd-phone"><div class="gd-imgwrap" style="aspect-ratio:390/325"><img src="/guides/img/field-23-handover-03-renter-phone-b718388d.jpg" alt="" loading="lazy" decoding="async" width="390" height="325"></div></div></figure></div><div class="gd-pcell"><div class="gd-pcap"><span class="gd-n" aria-hidden="true">3</span><div>Original licence: name, photo and expiry match. A photo of a licence is not enough.</div></div><figure class="gd-fig gd-fig--phone"><div class="gd-phone"><div class="gd-imgwrap" style="aspect-ratio:390/405"><img src="/guides/img/field-24-handover-04-licence-phone-3a13ae57.jpg" alt="" loading="lazy" decoding="async" width="390" height="405"></div></div></figure></div><div class="gd-pcell"><div class="gd-pcap"><span class="gd-n" aria-hidden="true">4</span><div>Card on File: you have seen the physical card with the same last four digits, in the renter&#39;s name.</div></div><figure class="gd-fig gd-fig--phone"><div class="gd-phone"><div class="gd-imgwrap" style="aspect-ratio:390/265"><img src="/guides/img/field-25-handover-05-card-phone-bb24ccc4.jpg" alt="" loading="lazy" decoding="async" width="390" height="265"></div></div></figure></div><div class="gd-pcell"><div class="gd-pcap"><span class="gd-n" aria-hidden="true">5</span><div>Odometer: type the reading in km.</div></div><figure class="gd-fig gd-fig--phone"><div class="gd-phone"><div class="gd-imgwrap" style="aspect-ratio:390/265"><img src="/guides/img/field-26-handover-06-odometer-phone-9234054f.jpg" alt="" loading="lazy" decoding="async" width="390" height="265"></div></div></figure></div><div class="gd-pcell"><div class="gd-pcap"><span class="gd-n" aria-hidden="true">6</span><div>Fuel or charge: slide to the level on the gauge.</div></div><figure class="gd-fig gd-fig--phone"><div class="gd-phone"><div class="gd-imgwrap" style="aspect-ratio:390/275"><img src="/guides/img/field-27-handover-07-fuel-phone-a5dec192.jpg" alt="" loading="lazy" decoding="async" width="390" height="275"></div></div></figure></div></div><div class="gd-phones"><div class="gd-pcell"><div class="gd-pcap"><span class="gd-n" aria-hidden="true">7</span><div>Keys: how many keys and fobs you hand over. Use <b class="gd-ui">+</b> and <b class="gd-ui">−</b>.</div></div><figure class="gd-fig gd-fig--phone"><div class="gd-phone"><div class="gd-imgwrap" style="aspect-ratio:390/235"><img src="/guides/img/field-28-handover-08-keys-phone-8de46c31.jpg" alt="" loading="lazy" decoding="async" width="390" height="235"></div></div></figure></div><div class="gd-pcell"><div class="gd-pcap"><span class="gd-n" aria-hidden="true">8</span><div>Photo set: 19 photos in order. <b class="gd-ui">Take</b> each one; <b class="gd-ui">Retake</b> if needed.</div></div><figure class="gd-fig gd-fig--phone"><div class="gd-phone"><div class="gd-imgwrap" style="aspect-ratio:390/405"><img src="/guides/img/field-29-handover-09-photos-phone-4a0e3d9c.jpg" alt="" loading="lazy" decoding="async" width="390" height="405"></div></div></figure></div><div class="gd-pcell"><div class="gd-pcap"><span class="gd-n" aria-hidden="true">9</span><div>Damage: tap the car diagram where it is, choose Where and Type, then <b class="gd-ui">Add the damage</b>.</div></div><figure class="gd-fig gd-fig--phone"><div class="gd-phone"><div class="gd-imgwrap" style="aspect-ratio:390/605"><img src="/guides/img/field-30-handover-10-damage-phone-923e28fe.jpg" alt="" loading="lazy" decoding="async" width="390" height="605"></div></div></figure></div><div class="gd-pcell"><div class="gd-pcap"><span class="gd-n" aria-hidden="true">10</span><div>Tracker: it should say in place and reporting. <b class="gd-ui">Check again</b> if not.</div></div><figure class="gd-fig gd-fig--phone"><div class="gd-phone"><div class="gd-imgwrap" style="aspect-ratio:390/295"><img src="/guides/img/field-31-handover-11-tracker-phone-0107b84a.jpg" alt="" loading="lazy" decoding="async" width="390" height="295"></div></div></figure></div><div class="gd-pcell"><div class="gd-pcap"><span class="gd-n" aria-hidden="true">11</span><div>Renter reviews: the renter reads the summary of odometer, fuel, keys, photos and damage.</div></div><figure class="gd-fig gd-fig--phone"><div class="gd-phone"><div class="gd-imgwrap" style="aspect-ratio:390/365"><img src="/guides/img/field-32-handover-12-summary-phone-96736994.jpg" alt="" loading="lazy" decoding="async" width="390" height="365"></div></div></figure></div><div class="gd-pcell"><div class="gd-pcap"><span class="gd-n" aria-hidden="true">12</span><div>Signatures: the renter signs, then you. <b class="gd-ui">Use this signature</b> for each.</div></div><figure class="gd-fig gd-fig--phone"><div class="gd-phone"><div class="gd-imgwrap" style="aspect-ratio:390/405"><img src="/guides/img/field-33-handover-13-signatures-phone-537ff2e3.jpg" alt="" loading="lazy" decoding="async" width="390" height="405"></div></div></figure></div></div><div class="gd-stepblock"><ol class="gd-ol" start="13"><li><span class="gd-n" aria-hidden="true">13</span><div class="gd-t">Press <b class="gd-ui">Hand over the keys</b>. You see &quot;Checked out. The rental has started.&quot; The renter gets the photo report by email and in their Documents.</div></li></ol></div><aside class="gd-box"><span class="gd-lbl">Tip</span><div>Photos wait on the phone without a connection and upload by themselves when it returns; the count shows what is still uploading. Each photo keeps its time, and the place when your phone allows location.</div></aside></section><section class="gd-task" id="a-handover-sign-now-on-this-device" data-gd-task><h2 class="gd-h2">Sign now on this device</h2><p class="gd-p">The renter (or an additional driver) has not signed the rental agreement yet? They sign on your phone.</p><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">On the job, press <b class="gd-ui">Sign now on this device</b>. It shows who still has to sign and whether their licence is on file.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Check the person: the name matches their licence, and you saw the original licence. Tick both. No licence on file? Press <b class="gd-ui">Photograph: Licence, front</b> (and the back and the selfie).</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Press <b class="gd-ui">Hand the device to</b> and their name. They read the agreements (CarmaCars&#39; and Blind Spot&#39;s), tick the statements and sign with their name or their finger.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t">They hand the phone back: press <b class="gd-ui">Back to the staff view</b>. The signature record says it was signed in person, collected by you, on your phone.</div></li></ol></div></section><section class="gd-task" id="a-handover-add-ons-to-put-in-the-car" data-gd-task><h2 class="gd-h2">Add-ons to put in the car</h2><p class="gd-p">A booking may come with add-ons: a baby seat, a child or booster seat, flowers, an umbrella, a phone charger or a prepaid full tank.</p><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">Open the job. Under Put in the car you see each add-on, how many, and what to do (for example &quot;Put the bouquet on the front passenger seat&quot;).</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Put every item in the car before the handover. The Car ready step lists them again.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Prepaid fuel: the renter may return the car at any fuel level. Do not charge for fuel at the return.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t">A chauffeur on the booking: Fleet tells you who drives and when.</div></li></ol></div><aside class="gd-box"><span class="gd-lbl">Tip</span><div>An item missing? Write it in the note for Fleet on the Car ready step and call the office before the handover.</div></aside><aside class="gd-box"><span class="gd-lbl">Tip</span><div>The photo count shows &quot;19 of 19 photos taken · all uploaded&quot; when the set is complete. The first photo must show the plate. Open circles on the damage diagram were recorded before; add only what is new.</div></aside></section>');
select app.guide_release_section('field', 'a-return', 'chapter', 'a-handover', 'The return mirrors the handover. You record the car as it comes back and compare it with the pickup.

## Take the car back

1. Car and keys received: confirm you have the car and its keys.
2. Odometer, then Fuel or charge, as at pickup.
3. Keys and extras: count what came back.
4. Cleanliness: inside and out.
5. Photo set: the same shots, in the same order, as at pickup.
6. Compare with pickup: for new damage, tap the diagram, fill in Where and What it is, press **Add the damage** and take a close-up photo.
7. Belongings: check the seats, the trunk, the glovebox and the door pockets.
8. Renter reviews and signs. Then you sign.
9. Press **Complete the return**.

> Watch out: New damage needs a close-up photo and a clear note. Finance uses your photos and notes to bill the renter, so take your time.
', 'A return', 'Odometer, fuel, keys, cleanliness, photos, new damage, belongings and signatures.',
  'The return mirrors the handover. You record the car as it comes back and compare it with the pickup.

## Take the car back

1. Car and keys received: confirm you have the car and its keys.
2. Odometer, then Fuel or charge, as at pickup.
3. Keys and extras: count what came back.
4. Cleanliness: inside and out.
5. Photo set: the same shots, in the same order, as at pickup.
6. Compare with pickup: for new damage, tap the diagram, fill in Where and What it is, press **Add the damage** and take a close-up photo.
7. Belongings: check the seats, the trunk, the glovebox and the door pockets.
8. Renter reviews and signs. Then you sign.
9. Press **Complete the return**. The check-in time is the moment you press it: a late return, the kilometres over the allowance and the fuel or charge used are charged from it automatically.

> Watch out: New damage needs a close-up photo and a clear note. Finance uses your photos and notes to bill the renter, so take your time.
',
  '<p class="gd-p">The return mirrors the handover. You record the car as it comes back and compare it with the pickup.</p><section class="gd-task" id="a-return-take-the-car-back" data-gd-task><h2 class="gd-h2">Take the car back</h2><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">Car and keys received: confirm you have the car and its keys.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Odometer, then Fuel or charge, as at pickup.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Keys and extras: count what came back.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t">Cleanliness: inside and out.</div></li><li><span class="gd-n" aria-hidden="true">5</span><div class="gd-t">Photo set: the same shots, in the same order, as at pickup.</div></li><li><span class="gd-n" aria-hidden="true">6</span><div class="gd-t">Compare with pickup: for new damage, tap the diagram, fill in Where and What it is, press <b class="gd-ui">Add the damage</b> and take a close-up photo.</div></li><li><span class="gd-n" aria-hidden="true">7</span><div class="gd-t">Belongings: check the seats, the trunk, the glovebox and the door pockets.</div></li><li><span class="gd-n" aria-hidden="true">8</span><div class="gd-t">Renter reviews and signs. Then you sign.</div></li><li><span class="gd-n" aria-hidden="true">9</span><div class="gd-t">Press <b class="gd-ui">Complete the return</b>. The check-in time is the moment you press it: a late return, the kilometres over the allowance and the fuel or charge used are charged from it automatically.</div></li></ol></div><aside class="gd-box gd-box--warn"><span class="gd-lbl">Watch out</span><div>New damage needs a close-up photo and a clear note. Finance uses your photos and notes to bill the renter, so take your time.</div></aside></section>');
-- GUIDES 0130 END
