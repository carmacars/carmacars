-- 0195: record a pickup or return now with the photos later, renters complete the agreement's missing details
-- themselves, and the VLF on insurer-billed rentals (the owner, October 30). SCHEMA_MARKER 0195.
-- Record: docs/changes/2026-10-30-record-now-renter-details-vlf.md.
--   1. "Record the return now (details later)" and "Record the pickup now (details later)" on the booking page (an
--      Admin, and staff who may hand over): the actual time (now, or earlier), km and fuel if known, a reason. The
--      booking moves (on rent to returned, or confirmed to on rent); its check-in or check-out report is kept open with
--      "details to complete", and Fleet gets the task "Add the photos and readings for CC-...". The task closes when the
--      report is completed through the usual checklist (handover_open gives the job again; complete_handover and
--      complete_return finish the report without moving the booking). Late return charges follow the actual time as
--      usual. The money guards stay: a pickup without the deposit taken needs an Admin's waiver with a reason, without
--      the renter's signature an Admin's override with a reason, and the agreement's claim check is unchanged. A return
--      recorded this way can be put on its statement and its deposit settled; releasing the deposit before the photos
--      are in is a blocker an Admin passes with a reason (the existing deposit guard).
--   2. app.agreement_renter_missing: the blanks of app.agreement_missing the renter fills in (date of birth, address,
--      mobile, their licence number, issuer and expiry, the coverage's insurer, policy and expiry or card issuer and last
--      four). public.renter_agreement_missing and public.renter_agreement_fill (the renter's own booking only, blanks
--      only). The staff Agreement card reads the list (agreement_state.renter_missing). No email or text.
--   3. VLF (vehicle licensing fee) a day on insurer-billed bookings: program_settings.vlf_daily_cents (0 by default) is
--      put on a booking (0191's booking_insurer_fees) when it is first billed to an insurer; 0191 prices it, bills it to
--      the insurer and prints it.
-- No earlier migration is edited. Functions it changes are wrapped (renamed _pre0195) or patched in place.
set local check_function_bodies = off;

create function pg_temp.copy_grants(p_new regprocedure, p_old regprocedure) returns void
language plpgsql as $$
declare g text;
begin
  execute format('revoke all on function %s from public, anon, authenticated', p_new);
  foreach g in array array['anon', 'authenticated', 'service_role'] loop
    if has_function_privilege(g, p_old, 'execute') then execute format('grant execute on function %s to %I', p_new, g); end if;
  end loop;
end $$;

create function pg_temp.patch_fn(p_sig regprocedure, p_old text, p_new text) returns void
language plpgsql as $$
declare
  d text := pg_get_functiondef(p_sig);
begin
  if position(p_old in d) = 0 then
    raise exception '0195: the text to change was not found in %: %', p_sig, left(p_old, 120);
  end if;
  execute replace(d, p_old, p_new);
end $$;

-- ================================================================ 0. settings, columns, catalogue
alter table program_settings
  add column vlf_daily_cents integer not null default 0 check (vlf_daily_cents >= 0);
comment on column program_settings.vlf_daily_cents is 'VLF (vehicle licensing fee) a day put on a booking when it is first billed to an insurer (0195), as its charge to the insurer (0191, booking_insurer_fees). 0: none.';

alter table condition_reports
  add column details_pending boolean not null default false,
  add column recorded_now jsonb;
comment on column condition_reports.details_pending is 'The pickup or return was recorded now with the photos and readings later (0195): the report is completed through the checklist later, without moving the booking.';
comment on column condition_reports.recorded_now is 'Who recorded the pickup or return now, when, why, and any Admin override (deposit waived, renter signature) (0195).';

insert into task_rules (task_type, queue, title, priority, due_kind, due_amount, procedure_no, completion_rule, description) values
  ('handover_details', 'fleet', 'Add the photos and readings', 'high', 'business_days', 1, null, 'report_details_added',
   'A pickup or return was recorded now with the details later. Open the check-out or check-in from the booking, take the photos, the readings and the signature: the task closes when the report is complete.')
on conflict (task_type) do nothing;

do $$
declare
  c record;
  v_kinds text[];
begin
  select conname, pg_get_constraintdef(oid) as def into strict c from pg_constraint
   where conrelid = 'public.booking_events'::regclass and contype = 'c' and pg_get_constraintdef(oid) like '%kind%';
  select array_agg(distinct m[1]) into v_kinds from regexp_matches(c.def, '[''{,]([a-z_0-9]+)(?=[''},])', 'g') m;
  select array_agg(distinct x order by x) into v_kinds from unnest(v_kinds || array['recorded_now', 'recorded_now_details']) x;
  execute format('alter table public.booking_events drop constraint %I', c.conname);
  execute format('alter table public.booking_events add constraint booking_events_kind_check check (kind in (%s))',
                 (select string_agg(quote_literal(x), ', ') from unnest(v_kinds) x));
end $$;

-- ================================================================ 1. record the pickup or the return now
-- p: booking, kind ('pickup' or 'return'), at (the actual time; now when empty), odometer_km, fuel_pct, reason,
-- deposit_waiver_reason (an Admin, a pickup without the deposit), signature_override_reason (an Admin, a pickup without
-- the renter's signature on the check-out report).
create or replace function app.handover_record_now(p_by uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  b bookings;
  c condition_reports;
  j field_jobs;
  t record;
  l record;
  v_kind text := p ->> 'kind';
  v_admin boolean := app.user_is_admin(p_by);
  v_reason text := nullif(btrim(coalesce(p ->> 'reason', '')), '');
  v_dep_reason text := nullif(btrim(coalesce(p ->> 'deposit_waiver_reason', '')), '');
  v_sig_reason text := nullif(btrim(coalesce(p ->> 'signature_override_reason', '')), '');
  v_at timestamptz;
  v_km integer := nullif(p ->> 'odometer_km', '')::numeric::integer;
  v_fuel integer := nullif(p ->> 'fuel_pct', '')::numeric::integer;
  v_minutes integer := 0;
  v_extra integer := 0;
  v_missing jsonb;
  v_keys text[];
  v_name text := (select full_name from users where id = p_by);
  v_rec jsonb;
  v_task uuid;
  v_from text;
begin
  if not app.user_may_handover(p_by) then
    raise exception 'Only an Admin, Fleet, Sales, Customer service or field staff record a check-out or check-in' using errcode = '42501';
  end if;
  if v_kind is null or v_kind not in ('pickup', 'return') then raise exception 'Record the pickup or the return' using errcode = '22023'; end if;
  select * into b from bookings where id::text = p ->> 'booking' or booking_number = upper(btrim(coalesce(p ->> 'booking', ''))) for update;
  if b.id is null then raise exception 'Booking not found' using errcode = 'P0002'; end if;
  if v_reason is null or length(v_reason) < 5 then raise exception 'Say why the details come later (at least 5 characters)' using errcode = '22023'; end if;
  v_at := coalesce(nullif(p ->> 'at', '')::timestamptz, now());
  if v_at > now() + interval '5 minutes' then raise exception 'Give the actual time (not in the future)' using errcode = '22023'; end if;
  v_at := least(v_at, now());
  if v_km is not null and v_km < 0 then raise exception 'The odometer is 0 km or more' using errcode = '22023'; end if;
  if v_fuel is not null and v_fuel not between 0 and 100 then raise exception 'The fuel or charge level is 0 to 100%%' using errcode = '22023'; end if;
  v_from := b.status::text;
  select * into c from condition_reports r where r.booking_id = b.id and r.kind = v_kind;
  if c.completed_at is not null then raise exception 'The % is already recorded with its report', case v_kind when 'pickup' then 'check-out' else 'check-in' end using errcode = '23514'; end if;

  if v_kind = 'return' then
    if b.status <> 'on_rent' then
      raise exception 'Booking % is %: a return is recorded while the car is on rent', b.booking_number, replace(b.status::text, '_', ' ') using errcode = '23514';
    end if;
    if v_at < coalesce(b.handed_over_at, b.pickup_at) then raise exception 'The return cannot be before the check-out' using errcode = '22023'; end if;
    if v_km is not null and b.odometer_out_km is not null and v_km < b.odometer_out_km
       and not exists (select 1 from booking_vehicle_swaps s where s.booking_id = b.id) then
      raise exception 'The odometer reading (%) is lower than at pickup (%)', v_km, b.odometer_out_km using errcode = '23514';
    end if;
  else
    if b.status <> 'confirmed' then
      raise exception 'Booking % is %: a pickup is recorded on a confirmed booking', b.booking_number, replace(b.status::text, '_', ' ') using errcode = '23514';
    end if;
    -- the deposit: taken, or waived by an Admin with the reason
    if b.booking_type <> 'owner' and b.deposit_waived_at is null and b.deposit_cents > 0
       and not exists (select 1 from deposits d where d.booking_id = b.id and d.status in ('held', 'captured')) then
      if not v_admin or v_dep_reason is null or length(v_dep_reason) < 5 then
        raise exception 'The deposit is not taken: take it first, or an Admin waives it with the reason' using errcode = '23514';
      end if;
      perform app.waive_deposit(b.id, p_by, v_dep_reason);
    end if;
    -- the renter's signature on the check-out report: on file already, or an Admin's override with the reason
    if b.booking_type <> 'owner' and c.renter_signature_ref is null and not coalesce(b.unattended_handover, false) then
      if not v_admin or v_sig_reason is null or length(v_sig_reason) < 5 then
        raise exception 'The renter has not signed the check-out report: an Admin records the pickup without it, with the reason' using errcode = '23514';
      end if;
    end if;
    -- the agreement's claim check (0154): the same as a check-out
    if b.booking_type <> 'owner' and coalesce((app.settings()).agreement_claim_check, true) then
      select coalesce(jsonb_agg(x), '[]'::jsonb), array_agg(x ->> 'key') into v_missing, v_keys
        from jsonb_array_elements(app.agreement_missing(b.id)) x where (x ->> 'required')::boolean;
      if jsonb_array_length(v_missing) > 0 and not exists (
           select 1 from agreement_overrides o where o.booking_id = b.id and (select bool_and(o.missing ? k) from unnest(v_keys) k)) then
        raise exception 'The rental agreement is missing what a claim needs: %. Fill them on the booking (Agreement card), or an Admin overrides with a reason',
          (select string_agg(x ->> 'label', '; ') from jsonb_array_elements(v_missing) x) using errcode = '23514';
      end if;
    end if;
    if not v_admin and not coalesce((app.tracker_reading(b.vehicle_id) ->> 'reporting')::boolean, false) then
      raise exception 'Do not release the car: the Tracker is not in place and reporting' using errcode = '23514';
    end if;
  end if;

  v_rec := jsonb_strip_nulls(jsonb_build_object('by', p_by, 'by_name', v_name, 'at', now(), 'actual_at', v_at, 'reason', v_reason,
             'deposit_waived', case when v_kind = 'pickup' and v_dep_reason is not null and (select deposit_waived_at from bookings where id = b.id) is not null then v_dep_reason end,
             'signature_override', case when v_kind = 'pickup' and c.renter_signature_ref is null then v_sig_reason end));
  if c.id is null then
    insert into condition_reports (vehicle_id, booking_id, kind, performed_by, performed_by_role, performed_at)
    values (b.vehicle_id, b.id, v_kind, p_by, 'staff', v_at) returning * into c;
  end if;
  select * into j from field_jobs x
   where x.booking_id = b.id and x.kind = any (case v_kind when 'pickup' then array['handover', 'delivery'] else array['return_check_in', 'pickup_from_renter'] end)
     and x.status not in ('done', 'cancelled')
   order by (x.id = c.field_job_id) desc nulls last, x.scheduled_at limit 1;
  update condition_reports
     set odometer_km = coalesce(v_km, odometer_km), fuel_pct = coalesce(v_fuel, fuel_pct)::smallint, performed_at = v_at,
         details_pending = true, recorded_now = v_rec, field_job_id = coalesce(j.id, field_job_id),
         renter_present = case when v_kind = 'pickup' and renter_signature_ref is null then false else renter_present end
   where id = c.id returning * into c;

  if v_kind = 'pickup' then
    update bookings set status = 'on_rent', handed_over_at = v_at, odometer_out_km = c.odometer_km, fuel_out_pct = c.fuel_pct where id = b.id;
    -- the owner's tracker access is blocked from the actual pickup, not from the moment it was recorded
    update tracker_access_blocks set starts_at = least(starts_at, v_at) where booking_id = b.id and ends_at is null;
  else
    update tracker_access_blocks set starts_at = least(starts_at, v_at) where booking_id = b.id and ends_at is null;
    v_minutes := greatest(0, floor(extract(epoch from (v_at - b.return_at)) / 60)::integer);
    select * into t from app.booking_fee_term(b.id, 'late_return_fee');
    select * into l from public.calc_late_return(v_minutes, b.daily_rate_cents, coalesce(t.amount_cents, 0), coalesce(t.percent_bps, 0), coalesce(t.grace_minutes, 0));
    v_extra := coalesce(l.extra_days, 0);
    update bookings
       set status = 'returned', checked_in_at = v_at, odometer_in_km = c.odometer_km, fuel_in_pct = c.fuel_pct,
           minutes_late = v_minutes, extra_days = v_extra,
           end_reason = coalesce(end_reason, case when v_extra > 0 then 'late_return'
                                                  when v_at < b.return_at - make_interval(mins => (app.settings()).early_return_minutes) then 'early_return'
                                                  else 'normal' end)
     where id = b.id;
  end if;
  if c.odometer_km is not null then
    update vehicles set odometer_km = c.odometer_km where id = b.vehicle_id and coalesce(odometer_km, 0) <= c.odometer_km;
  end if;
  if v_kind = 'return' then perform app.return_auto_charges(b.id); end if;

  v_task := app.raise_task(p_type => 'handover_details', p_title => format('Add the photos and readings for %s', b.booking_number),
      p_detail => format('%s recorded the %s at %s with the details later: %s', coalesce(v_name, 'Staff'), case v_kind when 'pickup' then 'pickup' else 'return' end,
                         app.fmt_at(v_at), v_reason),
      p_booking => b.id, p_vehicle => b.vehicle_id, p_renter => b.renter_id, p_related_table => 'condition_reports', p_related_id => c.id,
      p_dedupe => 'handover_details:' || c.id, p_created_by => p_by);
  perform app.log_booking_event(b.id, 'recorded_now', v_from, case v_kind when 'pickup' then 'on_rent' else 'returned' end, null,
    format('%s recorded now, details later (%s): %s', case v_kind when 'pickup' then 'Pickup' else 'Return' end, app.fmt_at(v_at), v_reason)
      || coalesce('. Deposit waived: ' || (v_rec ->> 'deposit_waived'), '') || coalesce('. Without the renter''s signature: ' || (v_rec ->> 'signature_override'), ''),
    p_by, 'staff', v_rec || jsonb_build_object('kind', v_kind, 'condition_report_id', c.id, 'task_id', v_task));
  return jsonb_build_object('report_id', c.id, 'task_id', v_task, 'booking_status', (select status from bookings where id = b.id),
                            'minutes_late', v_minutes, 'extra_days', v_extra);
end $$;

-- The details of a pickup or return recorded now: the report completed through the checklist, with the same checks as
-- the field flow (readings, keys, cleanliness at a return, the photo set, the staff signature; the renter's signature
-- is no longer asked), the booking's readings follow, new damage opens an incident, the return charges are written
-- again, the task closes.
create or replace function app.handover_details_complete(p_booking uuid, p_kind text, p_by uuid, p_report jsonb default '{}'::jsonb,
    p_job uuid default null, p_now timestamptz default now())
returns jsonb language plpgsql security definer set search_path = public, app as $$
declare
  d jsonb := coalesce(p_report, '{}'::jsonb) - 'checked_in_at' - 'deposit_payment_id' - 'deposit_waiver' - 'odometer_confirmed' - 'fuel_or_charge_ok';
  b bookings;
  c condition_reports;
  v_role text;
  v_id uuid;
  v_problems text[];
  v_new_damage text;
  v_incident uuid;
  v_findings jsonb;
begin
  select * into b from bookings where id = p_booking for update;
  if b.id is null then raise exception 'Booking % not found', p_booking; end if;
  select * into c from condition_reports where booking_id = p_booking and kind = p_kind and details_pending for update;
  if c.id is null then raise exception 'No % report of booking % waits for its details', p_kind, b.booking_number using errcode = '23514'; end if;
  v_role := app.condition_report_actor(p_booking, b.vehicle_id, p_by, p_job);
  if v_role = 'renter' then raise exception 'CarmaCars staff add the photos and readings' using errcode = '42501'; end if;
  v_id := app.save_condition_report(p_booking, p_kind, p_by, d, p_job);
  select * into c from condition_reports where id = v_id;
  if c.odometer_km is null or c.fuel_pct is null then
    raise exception 'The odometer and the fuel or charge level are required' using errcode = '23514';
  end if;
  if p_kind = 'return' and b.odometer_out_km is not null and c.odometer_km < b.odometer_out_km
     and not exists (select 1 from booking_vehicle_swaps s where s.booking_id = p_booking) then
    raise exception 'The odometer reading (%) is lower than at pickup (%)', c.odometer_km, b.odometer_out_km using errcode = '23514';
  end if;
  if c.keys_count is null or (p_kind = 'pickup' and c.keys_count < 1) then
    raise exception 'Record the number of keys' using errcode = '23514';
  end if;
  if p_kind = 'return' and c.cleanliness is null then raise exception 'Record the cleanliness of the car' using errcode = '23514'; end if;
  if c.staff_signature_ref is null then raise exception 'Your signature on the report is missing' using errcode = '23514'; end if;
  v_problems := app.condition_report_problems(v_id);
  if cardinality(v_problems) > 0 then
    raise exception 'The photo set is not complete: %', array_to_string(v_problems, '; ') using errcode = '23514';
  end if;

  update condition_reports
     set completed_at = p_now, completed_by = p_by, details_pending = false,
         staff_signed_at = coalesce(staff_signed_at, p_now),
         renter_signed_at = case when renter_signature_ref is not null then coalesce(renter_signed_at, p_now) else renter_signed_at end
   where id = v_id;
  if p_kind = 'pickup' then
    update bookings set odometer_out_km = c.odometer_km, fuel_out_pct = c.fuel_pct where id = p_booking;
  else
    update bookings set odometer_in_km = c.odometer_km, fuel_in_pct = c.fuel_pct where id = p_booking;
  end if;
  update vehicles set odometer_km = c.odometer_km where id = b.vehicle_id and coalesce(odometer_km, 0) <= c.odometer_km;
  update field_jobs set status = 'done', completed_at = p_now, started_at = coalesce(started_at, p_now)
   where id = coalesce(p_job, c.field_job_id) and status not in ('done', 'cancelled');

  if p_kind = 'return' then
    select string_agg(dm.label || ': ' || dm.location || ', ' || dm.description, '; ' order by dm.label) into v_new_damage
      from condition_report_damages dm where dm.condition_report_id = v_id and dm.is_new;
    if v_new_damage is not null then
      v_incident := app.open_incident('damage_at_return', b.vehicle_id, p_by,
          jsonb_build_object('description', 'New damage recorded at return: ' || v_new_damage, 'occurred_at', c.performed_at, 'place', b.return_place),
          p_booking, case when v_role = 'field' then 'field' else 'staff' end, p_now);
      update condition_report_damages set incident_id = v_incident, status_vs_pickup = coalesce(status_vs_pickup, 'new')
       where condition_report_id = v_id and is_new and incident_id is null;
    end if;
    if nullif(btrim(coalesce(c.belongings_found, '')), '') is not null then
      perform app.raise_task(p_type => 'lost_property', p_title => format('Booking %s: belongings found in the car', b.booking_number),
          p_detail => c.belongings_found, p_booking => p_booking, p_vehicle => b.vehicle_id, p_renter => b.renter_id,
          p_dedupe => 'lost_property:' || p_booking, p_created_by => p_by);
    end if;
    v_findings := app.return_findings(p_booking);
    update condition_reports set findings = v_findings where id = v_id;
    perform app.return_auto_charges(p_booking);
  end if;
  update tasks set status = 'done', completed_at = now(), completed_by = p_by, completion_note = 'Photos and readings added'
   where dedupe_key = 'handover_details:' || v_id and status in ('open', 'in_progress', 'waiting');
  perform app.log_booking_event(p_booking, 'recorded_now_details', b.status::text, b.status::text, null,
    format('%s photos and readings added', case p_kind when 'pickup' then 'Check-out' else 'Check-in' end), p_by, 'staff',
    jsonb_build_object('condition_report_id', v_id, 'incident_id', v_incident));
  return coalesce(v_findings, '{}'::jsonb) || jsonb_build_object('report_id', v_id, 'condition_report_id', v_id, 'incident_id', v_incident, 'details_added', true);
end $$;

-- the checklist's completion, for a report waiting for its details: completed without moving the booking
alter function app.complete_handover(uuid, uuid, jsonb, uuid, timestamptz) rename to complete_handover_pre0195;
create function app.complete_handover(p_booking uuid, p_by uuid, p_report jsonb default '{}'::jsonb,
    p_job uuid default null, p_now timestamptz default now())
returns uuid language plpgsql security definer set search_path = public, app as $$
begin
  if exists (select 1 from condition_reports c join bookings b on b.id = c.booking_id
              where c.booking_id = p_booking and c.kind = 'pickup' and c.details_pending and b.status <> 'confirmed') then
    return (app.handover_details_complete(p_booking, 'pickup', p_by, p_report, p_job, p_now) ->> 'report_id')::uuid;
  end if;
  return app.complete_handover_pre0195(p_booking, p_by, p_report, p_job, p_now);
end $$;
select pg_temp.copy_grants('app.complete_handover(uuid, uuid, jsonb, uuid, timestamptz)'::regprocedure, 'app.complete_handover_pre0195(uuid, uuid, jsonb, uuid, timestamptz)'::regprocedure);

alter function app.complete_return(uuid, uuid, jsonb, uuid, timestamptz) rename to complete_return_pre0195;
create function app.complete_return(p_booking uuid, p_by uuid, p_report jsonb default '{}'::jsonb,
    p_job uuid default null, p_now timestamptz default now())
returns jsonb language plpgsql security definer set search_path = public, app as $$
begin
  if exists (select 1 from condition_reports c join bookings b on b.id = c.booking_id
              where c.booking_id = p_booking and c.kind = 'return' and c.details_pending and b.status in ('returned', 'closed')) then
    return app.handover_details_complete(p_booking, 'return', p_by, p_report, p_job, p_now);
  end if;
  return app.complete_return_pre0195(p_booking, p_by, p_report, p_job, p_now);
end $$;
select pg_temp.copy_grants('app.complete_return(uuid, uuid, jsonb, uuid, timestamptz)'::regprocedure, 'app.complete_return_pre0195(uuid, uuid, jsonb, uuid, timestamptz)'::regprocedure);

-- "Add the photos and readings": the check-out or check-in job of a report waiting for its details, taken by whoever opens it
alter function app.handover_open(uuid, uuid, text) rename to handover_open_pre0195;
create function app.handover_open(p_user uuid, p_booking uuid, p_kind text) returns uuid
language plpgsql security definer set search_path = public, app as $$
declare
  b bookings;
  c condition_reports;
  j field_jobs;
  v_name text;
begin
  select * into c from condition_reports where booking_id = p_booking and kind = p_kind and details_pending;
  select * into b from bookings where id = p_booking;
  if c.id is null or (p_kind = 'pickup' and b.status = 'confirmed') or (p_kind = 'return' and b.status = 'on_rent') then
    return app.handover_open_pre0195(p_user, p_booking, p_kind);
  end if;
  if not app.user_may_handover(p_user) then
    raise exception 'Only an Admin, Fleet, Sales, Customer service or field staff check a car out or in' using errcode = '42501';
  end if;
  select * into j from field_jobs x
   where x.booking_id = p_booking and x.status not in ('done', 'cancelled')
     and x.kind = any (case p_kind when 'pickup' then array['handover', 'delivery'] else array['return_check_in', 'pickup_from_renter'] end)
   order by (x.id = c.field_job_id) desc nulls last, (x.assigned_to is not distinct from p_user) desc, x.scheduled_at limit 1 for update;
  if j.id is not null and j.assigned_to is distinct from p_user then
    if app.user_is_field(p_user) and not app.user_is_admin(p_user) and not app.user_va_has(p_user, 'fleet', 'sales', 'cs') then
      raise exception 'This job is assigned to someone else: ask Fleet to give it to you' using errcode = '42501';
    end if;
    select full_name into v_name from users where id = p_user;
    update field_jobs set assigned_to = p_user,
           instructions = concat_ws(E'\n', nullif(instructions, ''), format('Taken over by %s, %s.', coalesce(v_name, 'staff'), app.fmt_at(now())))
     where id = j.id returning * into j;
  end if;
  if j.id is null then
    insert into field_jobs (kind, booking_id, vehicle_id, assigned_to, dispatched_by, scheduled_at, place, status, acknowledged_at, started_at, instructions)
    values (case p_kind when 'pickup' then 'handover' else 'return_check_in' end, b.id, b.vehicle_id, p_user, p_user, now(),
            case p_kind when 'pickup' then b.pickup_place else b.return_place end, 'in_progress', now(), now(),
            'Add the photos and readings of a ' || p_kind || ' recorded with the details later.')
    returning * into j;
  elsif j.status in ('scheduled', 'acknowledged') or j.scheduled_at > now() + interval '36 hours' then
    update field_jobs set status = 'in_progress', acknowledged_at = coalesce(acknowledged_at, now()), started_at = coalesce(started_at, now()),
           scheduled_at = least(scheduled_at, now())
     where id = j.id returning * into j;
  end if;
  update condition_reports set field_job_id = j.id where id = c.id;
  return j.id;
end $$;
select pg_temp.copy_grants('app.handover_open(uuid, uuid, text)'::regprocedure, 'app.handover_open_pre0195(uuid, uuid, text)'::regprocedure);

-- the task closes only with the report (or a report no longer waiting)
alter function app.task_completion_problem(uuid) rename to task_completion_problem_pre0195;
create function app.task_completion_problem(p_task uuid) returns text
language plpgsql stable security definer set search_path = public, app as $$
declare
  t tasks;
begin
  select * into t from tasks where id = p_task;
  if t.completion_rule = 'report_details_added' and t.related_table = 'condition_reports'
     and exists (select 1 from condition_reports c where c.id = t.related_id and c.details_pending) then
    return 'Add the photos and readings first: open the check-out or check-in from the booking';
  end if;
  return app.task_completion_problem_pre0195(p_task);
end $$;
select pg_temp.copy_grants('app.task_completion_problem(uuid)'::regprocedure, 'app.task_completion_problem_pre0195(uuid)'::regprocedure);

-- the statement: a return recorded with the details later may be issued before the photos are reviewed
select pg_temp.patch_fn('app.issue_booking_statement(uuid, uuid, timestamptz)'::regprocedure,
  $o$c.kind = 'return' and c.reviewed_at is not null) then$o$,
  $n$c.kind = 'return' and (c.reviewed_at is not null or c.details_pending)) then$n$);

-- the deposit: releasing it before the return's photos are in is a blocker (an Admin passes it with the reason)
alter function app.deposit_blockers(uuid) rename to deposit_blockers_pre0195;
create function app.deposit_blockers(p_booking uuid) returns jsonb
language sql stable security definer set search_path = public, app as $$
  select app.deposit_blockers_pre0195(p_booking)
    || case when exists (select 1 from condition_reports c where c.booking_id = p_booking and c.kind = 'return' and c.details_pending)
            then jsonb_build_array(jsonb_build_object('kind', 'details', 'label', 'The return''s photos and readings are not added yet (recorded with the details later)'))
            else '[]'::jsonb end
$$;
select pg_temp.copy_grants('app.deposit_blockers(uuid)'::regprocedure, 'app.deposit_blockers_pre0195(uuid)'::regprocedure);

-- ================================================================ 2. the renter completes the agreement's blanks
create or replace function app.agreement_renter_missing(p_booking uuid) returns jsonb
language sql stable security definer set search_path = public, app as $$
  select coalesce(jsonb_agg(x || jsonb_build_object('field', case when x ->> 'key' like 'drivers.%' then split_part(x ->> 'key', '.', 3) else split_part(x ->> 'key', '.', 2) end)), '[]'::jsonb)
    from jsonb_array_elements(app.agreement_missing(p_booking)) x
   where x ->> 'key' in ('renter.date_of_birth', 'renter.address', 'renter.mobile', 'coverage.insurer_name', 'coverage.policy_number', 'coverage.policy_expiry',
                         'coverage.card_issuer', 'coverage.card_last4')
      or x ->> 'key' in (select 'drivers.' || bd.driver_id || '.' || f from booking_drivers bd cross join unnest(array['licence_number', 'licence_issuer', 'licence_expiry']) f
                          where bd.booking_id = p_booking and bd.role = 'renter')
$$;

create or replace function public.renter_agreement_missing(p_booking uuid, p_by uuid) returns jsonb
language plpgsql stable security definer set search_path = public, app as $$
begin
  perform app.assert_booking_renter(p_booking, p_by);
  return app.agreement_renter_missing(p_booking);
end $$;

-- p: date_of_birth, address_line1, address_line2, city, province, postal_code, country, mobile, licence_number,
-- licence_issuer, licence_expiry, insurer_name, policy_number, policy_expiry, card_issuer, card_last4. Only blanks are
-- filled (a value on file is changed by staff, or under Your details).
create or replace function public.renter_agreement_fill(p_by uuid, p_booking uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  b bookings;
  r renters;
  x jsonb := jsonb_strip_nulls(coalesce(p, '{}'::jsonb));
  k text;
  v_driver uuid;
  v_dob date;
  v_mobile text;
  v_postal text;
  v_expiry date;
  v_cp coverage_proofs;
  v_opt smallint;
  n integer := 0;
begin
  perform app.assert_booking_renter(p_booking, p_by);
  select * into b from bookings where id = p_booking for update;
  if b.status not in ('pending_payment', 'confirmed', 'on_rent') or b.booking_type = 'owner' then
    raise exception 'This booking''s agreement is not waiting for your details' using errcode = '23514';
  end if;
  for k in select y from jsonb_object_keys(x) y loop
    if k not in ('date_of_birth', 'address_line1', 'address_line2', 'city', 'province', 'postal_code', 'country', 'mobile', 'licence_number', 'licence_issuer',
                 'licence_expiry', 'insurer_name', 'policy_number', 'policy_expiry', 'card_issuer', 'card_last4') then
      raise exception 'Only your own details are saved here' using errcode = '22023';
    end if;
  end loop;
  select * into r from renters where id = b.renter_id for update;

  if nullif(x ->> 'date_of_birth', '') is not null then
    begin v_dob := (x ->> 'date_of_birth')::date; exception when others then raise exception 'Give your date of birth' using errcode = '22023'; end;
    if v_dob >= current_date - interval '16 years' or v_dob < date '1900-01-01' then raise exception 'Give your date of birth' using errcode = '22023'; end if;
    update renters set date_of_birth = coalesce(date_of_birth, v_dob), updated_at = now() where id = r.id;
    update booking_drivers set date_of_birth = coalesce(date_of_birth, v_dob) where booking_id = b.id and role = 'renter';
    n := n + 1;
  end if;
  if nullif(btrim(coalesce(x ->> 'address_line1', '')), '') is not null then
    if nullif(btrim(coalesce(x ->> 'city', '')), '') is null or nullif(btrim(coalesce(x ->> 'province', '')), '') is null
       or nullif(btrim(coalesce(x ->> 'postal_code', '')), '') is null then
      raise exception 'Give the full home address: street, city, province and postal code' using errcode = '22023';
    end if;
    v_postal := regexp_replace(upper(regexp_replace(x ->> 'postal_code', '\s', '', 'g')), '^([A-Z][0-9][A-Z])([0-9][A-Z][0-9])$', '\1 \2');
    if nullif(btrim(coalesce(r.address_line1, '')), '') is null or nullif(btrim(coalesce(r.city, '')), '') is null
       or nullif(btrim(coalesce(r.province, '')), '') is null or nullif(btrim(coalesce(r.postal_code, '')), '') is null then
      update renters set address_line1 = left(btrim(x ->> 'address_line1'), 200), address_line2 = nullif(left(btrim(coalesce(x ->> 'address_line2', '')), 200), ''),
             city = left(btrim(x ->> 'city'), 100), province = upper(left(btrim(x ->> 'province'), 40)), postal_code = left(v_postal, 20),
             country = coalesce(nullif(btrim(coalesce(x ->> 'country', '')), ''), country, 'Canada'), updated_at = now()
       where id = r.id;
    end if;
    n := n + 1;
  end if;
  if nullif(btrim(coalesce(x ->> 'mobile', '')), '') is not null then
    v_mobile := regexp_replace(x ->> 'mobile', '[^0-9+]', '', 'g');
    if v_mobile ~ '^[0-9]{10}$' then v_mobile := '+1' || v_mobile; elsif v_mobile ~ '^1[0-9]{10}$' then v_mobile := '+' || v_mobile; end if;
    if v_mobile !~ '^\+[1-9][0-9]{7,14}$' then raise exception 'Give your mobile number, with the country code outside Canada and the US' using errcode = '22023'; end if;
    update renters set mobile = coalesce(nullif(btrim(mobile), ''), v_mobile), updated_at = now() where id = r.id;
    n := n + 1;
  end if;
  if coalesce(nullif(btrim(coalesce(x ->> 'licence_number', '')), ''), nullif(btrim(coalesce(x ->> 'licence_issuer', '')), ''), nullif(x ->> 'licence_expiry', '')) is not null then
    select driver_id into v_driver from booking_drivers where booking_id = b.id and role = 'renter' limit 1;
    if v_driver is null then raise exception 'Your driver record is not on this booking yet: message us' using errcode = 'P0002'; end if;
    if nullif(x ->> 'licence_expiry', '') is not null then
      begin v_expiry := (x ->> 'licence_expiry')::date; exception when others then raise exception 'Give the licence expiry date' using errcode = '22023'; end;
      if v_expiry < app.local_date(b.return_at) then raise exception 'The licence must be valid until the return date' using errcode = '23514'; end if;
    end if;
    if nullif(btrim(coalesce(x ->> 'licence_number', '')), '') is not null and length(regexp_replace(x ->> 'licence_number', '\s', '', 'g')) not between 5 and 25 then
      raise exception 'The licence number should be 5 to 25 characters' using errcode = '22023';
    end if;
    update drivers set
      licence_number = coalesce(nullif(btrim(licence_number), ''), nullif(upper(regexp_replace(coalesce(x ->> 'licence_number', ''), '\s', '', 'g')), '')),
      licence_issuer = coalesce(nullif(btrim(licence_issuer), ''), nullif(upper(btrim(coalesce(x ->> 'licence_issuer', ''))), '')),
      licence_expiry = coalesce(licence_expiry, v_expiry), updated_at = now()
     where id = v_driver;
    update booking_drivers set
      licence_number = coalesce(nullif(btrim(licence_number), ''), nullif(upper(regexp_replace(coalesce(x ->> 'licence_number', ''), '\s', '', 'g')), '')),
      licence_issuer = coalesce(nullif(btrim(licence_issuer), ''), nullif(upper(btrim(coalesce(x ->> 'licence_issuer', ''))), '')),
      licence_expiry = coalesce(licence_expiry, v_expiry)
     where booking_id = b.id and driver_id = v_driver;
    n := n + 1;
  end if;
  if coalesce(nullif(btrim(coalesce(x ->> 'insurer_name', '')), ''), nullif(btrim(coalesce(x ->> 'policy_number', '')), ''), nullif(x ->> 'policy_expiry', ''),
              nullif(btrim(coalesce(x ->> 'card_issuer', '')), ''), nullif(btrim(coalesce(x ->> 'card_last4', '')), '')) is not null then
    if nullif(btrim(coalesce(x ->> 'card_last4', '')), '') is not null and btrim(x ->> 'card_last4') !~ '^[0-9]{4}$' then
      raise exception 'The last four digits of the card' using errcode = '22023';
    end if;
    if nullif(x ->> 'policy_expiry', '') is not null then
      begin perform (x ->> 'policy_expiry')::date; exception when others then raise exception 'Give the policy expiry date' using errcode = '22023'; end;
    end if;
    select * into v_cp from coverage_proofs where booking_id = b.id order by created_at desc limit 1;
    if v_cp.id is null then
      v_opt := coalesce(b.coverage_option, case when nullif(btrim(coalesce(x ->> 'card_issuer', x ->> 'card_last4', '')), '') is not null then 2 else 1 end);
      insert into coverage_proofs (booking_id, coverage_option, status) values (b.id, v_opt, 'submitted') returning * into v_cp;
    end if;
    update coverage_proofs set
      insurer_name = coalesce(nullif(btrim(insurer_name), ''), nullif(left(btrim(coalesce(x ->> 'insurer_name', '')), 120), '')),
      policy_number = coalesce(nullif(btrim(policy_number), ''), nullif(left(btrim(coalesce(x ->> 'policy_number', '')), 60), '')),
      policy_expiry = coalesce(policy_expiry, nullif(x ->> 'policy_expiry', '')::date),
      card_issuer = coalesce(nullif(btrim(card_issuer), ''), nullif(left(btrim(coalesce(x ->> 'card_issuer', '')), 80), '')),
      card_last4 = coalesce(nullif(btrim(card_last4), ''), nullif(btrim(coalesce(x ->> 'card_last4', '')), ''))
     where id = v_cp.id;
    n := n + 1;
  end if;
  if n = 0 then raise exception 'Fill in the details asked for' using errcode = '22023'; end if;
  perform app.log_booking_event(b.id, 'agreement_fields_filled', b.status::text, b.status::text, null, 'The renter completed the agreement''s details', p_by, 'renter',
    jsonb_build_object('fields', (select jsonb_agg(y) from jsonb_object_keys(x) y)));
  return jsonb_build_object('updated', n, 'missing', app.agreement_renter_missing(b.id));
end $$;

-- the staff Agreement card: what waits for the renter
alter function app.agreement_state(uuid, uuid) rename to agreement_state_pre0195;
create function app.agreement_state(p_by uuid, p_booking uuid) returns jsonb
language sql stable security definer set search_path = public, app as $$
  select app.agreement_state_pre0195(p_by, p_booking) || jsonb_build_object('renter_missing', app.agreement_renter_missing(p_booking))
$$;
select pg_temp.copy_grants('app.agreement_state(uuid, uuid)'::regprocedure, 'app.agreement_state_pre0195(uuid, uuid)'::regprocedure);

-- ================================================================ 3. the VLF on insurer-billed rentals
-- Release 20's 0191 already prices the VLF a day of each insurer-billed booking (booking_insurer_fees, "Charges to the
-- insurer": rate x days with HST, paid by the insurer also when it pays the rental only, its own insurer invoice line,
-- Blind Spot's box 43). 0195 adds the default: when a booking is first billed to an insurer (made so, or switched) and
-- has no VLF yet, the program setting's VLF a day is put on it. Staff change or remove it there; the price picks it up
-- the next time the booking is priced (every path that bills an insurer prices the booking again).
create or replace function app.booking_vlf_default_trg() returns trigger
language plpgsql security definer set search_path = public, app as $$
declare
  v_daily integer := coalesce((app.settings()).vlf_daily_cents, 0);
begin
  if v_daily <= 0 or not app.booking_bills_insurer(new) then return null; end if;
  if tg_op = 'UPDATE' and app.booking_bills_insurer(old) then return null; end if;
  if new.status in ('cancelled', 'declined', 'expired', 'no_show', 'closed') then return null; end if;
  insert into booking_insurer_fees (booking_id, fee_type_code, rate_cents)
  values (new.id, 'vlf', v_daily)
  on conflict (booking_id, fee_type_code) do nothing;
  return null;
end $$;
drop trigger if exists bookings_vlf_default on bookings;
create trigger bookings_vlf_default after insert or update of bill_to, insurer_id, booking_type on bookings
  for each row execute function app.booking_vlf_default_trg();

-- ================================================================ 4. the door
alter function app.door(uuid, text, text, text, jsonb) rename to door_pre0195;
create function app.door(p_user uuid, p_aal text, p_call text, p_name text, p jsonb default '{}'::jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  p_ jsonb := coalesce(p, '{}'::jsonb) - '_va';
  x jsonb;
begin
  if p_call = 'ops_do' and p_name = 'handover_record_now' then
    if coalesce(p, '{}'::jsonb) ? '_va' then perform set_config('app.va_active', coalesce(p ->> '_va', ''), true); end if;
    perform app.door_begin(p_user, p_aal);
    return app.handover_record_now(p_user, p_);
  end if;
  x := app.door_pre0195(p_user, p_aal, p_call, p_name, p);
  -- the checklist of a report waiting for its details says so (no ready check, no renter signature)
  if p_call = 'field_read' and p_name = 'job' and x is not null and (x #>> '{booking,id}') is not null and x ->> 'report_kind' in ('pickup', 'return') then
    x := x || jsonb_build_object('details_later', exists (select 1 from condition_reports c where c.booking_id = (x #>> '{booking,id}')::uuid
                                                            and c.kind = x ->> 'report_kind' and c.details_pending));
  end if;
  -- the booking's card offers "Add the photos and readings" for these
  if p_call = 'ops_read' and p_name = 'handover_report' and jsonb_typeof(x) = 'object' and x ? 'booking_id' then
    x := x || jsonb_build_object('details_pending', coalesce((select jsonb_agg(c.kind order by c.kind) from condition_reports c
                                                               where c.booking_id = (x ->> 'booking_id')::uuid and c.details_pending), '[]'::jsonb));
  end if;
  return x;
end $$;
select pg_temp.copy_grants('app.door(uuid, text, text, text, jsonb)'::regprocedure, 'app.door_pre0195(uuid, text, text, text, jsonb)'::regprocedure);

-- ================================================================ 5. privileges
do $$
declare
  f record;
begin
  for f in
    select p.oid::regprocedure as sig from pg_proc p join pg_namespace n on n.oid = p.pronamespace
     where n.nspname = 'app' and p.proname = any (array['handover_record_now', 'handover_details_complete', 'complete_handover_pre0195', 'complete_return_pre0195',
             'handover_open_pre0195', 'task_completion_problem_pre0195', 'deposit_blockers_pre0195', 'agreement_renter_missing', 'agreement_state_pre0195',
             'booking_vlf_default_trg', 'door_pre0195'])
  loop
    execute format('revoke all on function %s from public, anon, authenticated', f.sig);
    execute format('grant execute on function %s to service_role', f.sig);
  end loop;
end $$;
revoke all on function public.renter_agreement_missing(uuid, uuid) from public, anon, authenticated;
revoke all on function public.renter_agreement_fill(uuid, uuid, jsonb) from public, anon, authenticated;
grant execute on function public.renter_agreement_missing(uuid, uuid) to service_role;
grant execute on function public.renter_agreement_fill(uuid, uuid, jsonb) to service_role;
