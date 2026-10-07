-- 0011_status_flows.sql
-- Allowed status changes for bookings, vehicles, owner onboarding, claims and owner invoices,
-- enforced by one trigger that reads the status_transitions table; a history of every change;
-- and the conditions a booking must meet before it is confirmed, handed over or returned.
-- The flows are drawn in docs/data-model.md.

create table status_transitions (
  entity      text not null check (entity in ('booking', 'vehicle', 'vehicle_onboarding', 'claim', 'owner_invoice')),
  from_status text not null,
  to_status   text not null,
  note        text,
  primary key (entity, from_status, to_status)
);
comment on table status_transitions is 'The only status changes the database accepts. A row inserted directly (data import) may start in any status.';

create table status_history (
  id          bigint generated always as identity primary key,
  entity      text not null,
  entity_id   uuid not null,
  from_status text,
  to_status   text not null,
  changed_at  timestamptz not null default now(),
  changed_by  uuid
);
create index status_history_entity_idx on status_history (entity, entity_id, changed_at);
create trigger status_history_append_only before update or delete on status_history
  for each row execute function app.forbid_change();

-- Runs twice per change: BEFORE (first of all triggers) to refuse a change the table does not
-- list, and AFTER to write the history once the change has passed every other check.
create or replace function app.enforce_status_flow() returns trigger
language plpgsql security definer set search_path = public, app as $$
declare
  v_entity text := tg_argv[0];
  v_old text := case when tg_op = 'UPDATE' then to_jsonb(old) ->> 'status' end;
  v_new text := to_jsonb(new) ->> 'status';
begin
  if tg_when = 'BEFORE' then
    if v_old is distinct from v_new and not exists (
         select 1 from status_transitions t where t.entity = v_entity and t.from_status = v_old and t.to_status = v_new) then
      raise exception '% cannot go from % to %', v_entity, v_old, v_new using errcode = '23514';
    end if;
    return new;
  end if;
  if tg_op = 'INSERT' or v_old is distinct from v_new then
    insert into status_history (entity, entity_id, from_status, to_status, changed_by)
    values (v_entity, (to_jsonb(new) ->> 'id')::uuid, v_old, v_new, app.uid());
  end if;
  return null;
end $$;

-- (BEFORE triggers fire in name order; "a0_" puts the flow check ahead of every other guard)
do $$
declare
  r record;
begin
  for r in select * from (values ('bookings', 'booking'), ('vehicles', 'vehicle'), ('vehicle_onboardings', 'vehicle_onboarding'),
                                 ('claims', 'claim'), ('owner_invoices', 'owner_invoice')) v(tbl, entity)
  loop
    execute format('create trigger a0_status_flow before update of status on public.%I for each row execute function app.enforce_status_flow(%L)', r.tbl, r.entity);
    execute format('create trigger status_history_log after insert or update of status on public.%I for each row execute function app.enforce_status_flow(%L)', r.tbl, r.entity);
  end loop;
end $$;

insert into status_transitions (entity, from_status, to_status, note) values
  -- booking
  ('booking', 'tentative', 'pending_payment', 'agreement sent for signature, checkout link sent'),
  ('booking', 'tentative', 'confirmed', 'Owner Booking: signed, nothing to pay'),
  ('booking', 'tentative', 'expired', 'the 2-hour hold lapsed'),
  ('booking', 'tentative', 'cancelled', null),
  ('booking', 'tentative', 'declined', 'CarmaCars refuses the booking'),
  ('booking', 'pending_payment', 'confirmed', 'signed and paid'),
  ('booking', 'pending_payment', 'expired', 'payment failed or never made: not confirmed, no fee'),
  ('booking', 'pending_payment', 'cancelled', null),
  ('booking', 'pending_payment', 'declined', null),
  ('booking', 'confirmed', 'on_rent', 'identity and coverage confirmed, deposit taken, handed over'),
  ('booking', 'confirmed', 'cancelled', 'by the renter (tiers) or by CarmaCars (100%)'),
  ('booking', 'confirmed', 'no_show', 'no refund'),
  ('booking', 'on_rent', 'returned', 'Check-in'),
  ('booking', 'returned', 'closed', 'statement issued, deposit settled'),
  -- vehicle
  ('vehicle', 'onboarding', 'ready_to_list', 'Enrollment Date confirmed (T22) or Turo-Only documents complete'),
  ('vehicle', 'onboarding', 'declined', 'branded title, insurer declines, or the Owner withdraws'),
  ('vehicle', 'ready_to_list', 'available', 'rates set, listing published'),
  ('vehicle', 'ready_to_list', 'out_of_service', null),
  ('vehicle', 'ready_to_list', 'exit_notice', null),
  ('vehicle', 'available', 'on_rent', 'handover'),
  ('vehicle', 'available', 'cleaning', null),
  ('vehicle', 'available', 'out_of_service', 'service, repair or breakdown'),
  ('vehicle', 'available', 'exit_notice', '30 days'' notice'),
  ('vehicle', 'available', 'total_loss', null),
  ('vehicle', 'on_rent', 'cleaning', 'Check-in'),
  ('vehicle', 'on_rent', 'out_of_service', 'accident or breakdown during a rental'),
  ('vehicle', 'on_rent', 'exit_notice', 'returned while under exit notice'),
  ('vehicle', 'on_rent', 'total_loss', null),
  ('vehicle', 'cleaning', 'available', 'detailed to the standard'),
  ('vehicle', 'cleaning', 'out_of_service', 'damage or a warning light found'),
  ('vehicle', 'cleaning', 'exit_notice', null),
  ('vehicle', 'out_of_service', 'cleaning', 'the shop releases the car'),
  ('vehicle', 'out_of_service', 'available', null),
  ('vehicle', 'out_of_service', 'exit_notice', null),
  ('vehicle', 'out_of_service', 'total_loss', 'the Insurer''s decision'),
  ('vehicle', 'exit_notice', 'on_rent', 'a booking inside the notice period'),
  ('vehicle', 'exit_notice', 'available', 'notice withdrawn'),
  ('vehicle', 'exit_notice', 'exited', 'the Exit Date'),
  ('vehicle', 'exit_notice', 'total_loss', null),
  ('vehicle', 'available', 'exited', 'immediate removal: insurer cancels cover, or Owner default'),
  ('vehicle', 'cleaning', 'exited', 'immediate removal'),
  ('vehicle', 'out_of_service', 'exited', 'immediate removal'),
  ('vehicle', 'ready_to_list', 'exited', 'immediate removal'),
  -- owner onboarding, per vehicle (procedure 12; 13 for Turo-Only)
  ('vehicle_onboarding', 'intake', 'terms_set', 'Admin sets Fees, Revenue Share and Management Mode'),
  ('vehicle_onboarding', 'intake', 'declined', 'rebuilt, salvage or irreparable brand'),
  ('vehicle_onboarding', 'terms_set', 'documents_sent', null),
  ('vehicle_onboarding', 'documents_sent', 'documents_signed', null),
  ('vehicle_onboarding', 'documents_signed', 'upfront_paid', 'Install Fee and first and last month''s Insurance Fee'),
  ('vehicle_onboarding', 'documents_signed', 'registry_booked', 'shareholder-owned vehicle only: no upfront charges'),
  ('vehicle_onboarding', 'documents_signed', 'enrolled', 'Turo-Only only: live on Turo'),
  ('vehicle_onboarding', 'upfront_paid', 'registry_booked', null),
  ('vehicle_onboarding', 'registry_booked', 'registered', 'new permit filed, Title Schedule completed'),
  ('vehicle_onboarding', 'registered', 'tracker_installed', 'installed and tested while parked'),
  ('vehicle_onboarding', 'tracker_installed', 'on_fleet_policy', 'insurer''s confirmation filed'),
  ('vehicle_onboarding', 'on_fleet_policy', 'enrolled', 'T22 sent: that date is the Enrollment Date'),
  ('vehicle_onboarding', 'terms_set', 'declined', 'insurer declines'),
  ('vehicle_onboarding', 'documents_sent', 'declined', null),
  ('vehicle_onboarding', 'documents_signed', 'declined', null),
  ('vehicle_onboarding', 'upfront_paid', 'declined', null),
  ('vehicle_onboarding', 'registry_booked', 'declined', null),
  ('vehicle_onboarding', 'registered', 'declined', 'insurer declines after registration'),
  ('vehicle_onboarding', 'tracker_installed', 'declined', 'insurer declines after registration'),
  ('vehicle_onboarding', 'intake', 'withdrawn', 'the Owner does not proceed'),
  ('vehicle_onboarding', 'terms_set', 'withdrawn', null),
  ('vehicle_onboarding', 'documents_sent', 'withdrawn', null),
  ('vehicle_onboarding', 'documents_signed', 'withdrawn', null),
  ('vehicle_onboarding', 'upfront_paid', 'withdrawn', null),
  ('vehicle_onboarding', 'registry_booked', 'withdrawn', null),
  -- claim
  ('claim', 'opened', 'submitted', 'fleet policy: the broker is notified'),
  ('claim', 'opened', 'in_repair', 'under $2,500: no insurer, repair at cost'),
  ('claim', 'opened', 'total_loss', 'total loss or unrecovered theft'),
  ('claim', 'opened', 'withdrawn', null),
  ('claim', 'opened', 'closed', 'Turo''s terms govern; nothing to settle here'),
  ('claim', 'submitted', 'accepted', null),
  ('claim', 'submitted', 'denied', 'for the renter''s breach: Admin bills the full cost'),
  ('claim', 'submitted', 'total_loss', 'the Insurer''s decision'),
  ('claim', 'submitted', 'withdrawn', null),
  ('claim', 'accepted', 'in_repair', 'approved shop'),
  ('claim', 'accepted', 'total_loss', null),
  ('claim', 'in_repair', 'repaired', 'the shop releases the car'),
  ('claim', 'in_repair', 'total_loss', null),
  ('claim', 'repaired', 'settling', 'waiting for all money in'),
  ('claim', 'settling', 'closed', 'result calculated and paid'),
  ('claim', 'denied', 'in_repair', 'repaired at the renter''s or Owner''s cost'),
  ('claim', 'denied', 'closed', null),
  ('claim', 'total_loss', 'settlement_received', 'cleared funds'),
  ('claim', 'settlement_received', 'distributed', 'lender, then CarmaCars, then the Owner'),
  ('claim', 'distributed', 'closed', null),
  -- owner invoice
  ('owner_invoice', 'draft', 'issued', 'the 15th (upfront: when sent)'),
  ('owner_invoice', 'draft', 'void', null),
  ('owner_invoice', 'issued', 'processing', 'debit submitted'),
  ('owner_invoice', 'issued', 'paid', 'card or e-Transfer'),
  ('owner_invoice', 'issued', 'failed', 'the charge fails: $50 Late Fee'),
  ('owner_invoice', 'issued', 'void', null),
  ('owner_invoice', 'processing', 'paid', null),
  ('owner_invoice', 'processing', 'failed', 'the debit fails: $50 Late Fee'),
  ('owner_invoice', 'failed', 'retry_processing', 'the 18th: retry Fees plus Late Fee'),
  ('owner_invoice', 'failed', 'paid', 'the Owner pays another way before the retry'),
  ('owner_invoice', 'failed', 'in_arrears', 'retry not possible (authorization revoked)'),
  ('owner_invoice', 'retry_processing', 'paid', null),
  ('owner_invoice', 'retry_processing', 'in_arrears', 'the retry fails'),
  ('owner_invoice', 'in_arrears', 'paid', 'the Owner pays'),
  ('owner_invoice', 'in_arrears', 'partially_deducted', 'next 10th: part taken from revenue'),
  ('owner_invoice', 'in_arrears', 'deducted', 'next 10th: taken from revenue'),
  ('owner_invoice', 'partially_deducted', 'deducted', null),
  ('owner_invoice', 'partially_deducted', 'paid', null),
  -- a debit can still come back as failed after it showed paid (results take up to 5 business days)
  ('owner_invoice', 'paid', 'failed', 'debit returned after settlement');

-- ---------------------------------------------------------------- bookings: fill the snapshot, check the vehicle
-- May this vehicle take a new renter booking?
create or replace function app.vehicle_bookable(p_vehicle uuid) returns boolean
language sql stable security definer set search_path = public, app as $$
  select v.bookings_enabled
     and v.management_mode <> 'turo_only'
     and v.status in ('available', 'on_rent', 'cleaning', 'out_of_service', 'exit_notice')
     -- a Self-Managed vehicle in arrears is not enabled for new bookings
     and not (v.management_mode = 'self_managed' and v.in_arrears)
    from vehicles v where v.id = p_vehicle
$$;

create or replace function app.booking_before_write() returns trigger
language plpgsql security definer set search_path = public, app as $$
declare
  v vehicles;
  v_set program_settings;
  prev bookings;
begin
  v_set := app.settings(app.local_date(coalesce(new.booked_at, now())));
  -- the non-refundable discount is fixed: 10% off the rental charge only, never off fees
  if new.booking_type = 'non_refundable'
     and new.discount_cents <> public.calc_bps(new.rental_charge_cents, v_set.non_refundable_discount_bps) then
    raise exception 'The non-refundable discount is fixed at % basis points of the rental charge', v_set.non_refundable_discount_bps
      using errcode = '23514';
  end if;
  if tg_op = 'INSERT' then
    select * into v from vehicles where id = new.vehicle_id;
    -- snapshot of who owns the vehicle and how it is managed
    new.owner_id := coalesce(new.owner_id, v.owner_id);
    new.management_mode := coalesce(new.management_mode, v.management_mode);
    new.is_shareholder_vehicle := v.is_shareholder_owned;
    if new.company_share_bps is null then
      new.company_share_bps := case
        when new.booking_type = 'owner' then 0
        when v.is_shareholder_owned then v_set.shareholder_company_share_bps
        when v.management_mode = 'self_managed' then 0
        else coalesce((app.vehicle_terms(v.id, app.local_date(coalesce(new.booked_at, now())))).revenue_share_bps,
                      (select s.revenue_share_bps from vehicle_schedules s where s.vehicle_id = v.id and s.superseded_by is null)) end;
    end if;
    if new.booking_type = 'owner' then
      -- only the vehicle's Owner makes an Owner Booking
      if not exists (select 1 from renters r join owners o on o.user_id = r.user_id
                      where r.id = new.renter_id and o.id = v.owner_id) and new.status in ('tentative', 'pending_payment', 'confirmed') then
        raise exception 'An Owner Booking is made by the vehicle''s own Owner' using errcode = '23514';
      end if;
    elsif new.status in ('tentative', 'pending_payment', 'confirmed') then
      if not coalesce(app.vehicle_bookable(new.vehicle_id), false) then
        raise exception 'Vehicle is not open for new bookings' using errcode = '23514';
      end if;
      if v.exit_date is not null and app.local_date(new.return_at) > v.exit_date then
        raise exception 'The booking would run past the vehicle''s Exit Date' using errcode = '23514';
      end if;
    end if;
    -- a renewal: same renter, made before the current rental ends
    if new.renews_booking_id is not null then
      select * into prev from bookings where id = new.renews_booking_id;
      if prev.renter_id <> new.renter_id then
        raise exception 'A renewal belongs to the same renter as the booking it renews' using errcode = '23514';
      end if;
      if new.status in ('tentative', 'pending_payment', 'confirmed') and new.booked_at > coalesce(prev.checked_in_at, prev.return_at) then
        raise exception 'A renewal is made before the current rental ends' using errcode = '23514';
      end if;
    end if;
    return new;
  end if;

  -- UPDATE
  -- an extension past 7 days in total: the card hold must be captured first
  if new.billable_days > old.billable_days
     and new.billable_days > (app.settings()).deposit_hold_max_days
     and exists (select 1 from deposits d where d.booking_id = new.id and d.method = 'card_hold' and d.status = 'held') then
    raise exception 'Total length is now over 7 days: capture the card hold as a charged Deposit first' using errcode = '23514';
  end if;
  -- a booking always uses the rates stored on it
  if old.status not in ('tentative', 'pending_payment')
     and (new.daily_rate_cents, new.weekend_rate_cents, new.weekly_rate_cents, new.monthly_rate_cents,
          new.km_allowance_per_day, new.overage_cents_per_km, new.company_share_bps, new.owner_id, new.management_mode)
         is distinct from
         (old.daily_rate_cents, old.weekend_rate_cents, old.weekly_rate_cents, old.monthly_rate_cents,
          old.km_allowance_per_day, old.overage_cents_per_km, old.company_share_bps, old.owner_id, old.management_mode) then
    raise exception 'The rates and split terms stored on a confirmed booking cannot change' using errcode = '23514';
  end if;

  if new.status is distinct from old.status then
    if new.status = 'confirmed' then
      if not exists (select 1 from signature_requests s where s.id = new.signature_request_id and s.status = 'completed') then
        raise exception 'A booking is confirmed only when the agreement is signed' using errcode = '23514';
      end if;
      if new.booking_type <> 'owner' and not exists (
           select 1 from payments p where p.booking_id = new.id and p.purpose = 'booking_total'
              and p.kind = 'charge' and p.status = 'succeeded') then
        raise exception 'A booking is confirmed only when payment succeeds' using errcode = '23514';
      end if;
      if new.booking_type <> 'owner' and new.card_on_file_id is null then
        raise exception 'No saved card, no confirmed booking' using errcode = '23514';
      end if;
      new.confirmed_at := coalesce(new.confirmed_at, now());
    elsif new.status = 'on_rent' then
      if exists (select 1 from booking_drivers d where d.booking_id = new.id and d.identity_verified_on is null)
         or not exists (select 1 from booking_drivers d where d.booking_id = new.id and d.role = 'renter') then
        raise exception 'No car is released until every driver''s identity is verified' using errcode = '23514';
      end if;
      if new.booking_type <> 'owner' then
        if new.coverage_confirmed_at is null or not exists (
             select 1 from coverage_proofs c where c.booking_id = new.id and c.status = 'confirmed') then
          raise exception 'No car is released until a Coverage Option is confirmed' using errcode = '23514';
        end if;
        if new.deposit_cents > 0 and not exists (
             select 1 from deposits d where d.booking_id = new.id and d.status in ('held', 'captured')) then
          raise exception 'The Deposit is taken at pickup, before handover' using errcode = '23514';
        end if;
      end if;
      if not exists (select 1 from condition_reports c where c.booking_id = new.id and c.kind = 'pickup') then
        raise exception 'Handover needs the pickup Condition Report' using errcode = '23514';
      end if;
      new.handed_over_at := coalesce(new.handed_over_at, now());
    elsif new.status = 'returned' then
      if not exists (select 1 from condition_reports c where c.booking_id = new.id and c.kind = 'return') then
        raise exception 'Check-in needs the return Condition Report' using errcode = '23514';
      end if;
      new.checked_in_at := coalesce(new.checked_in_at, now());
    elsif new.status in ('cancelled', 'no_show') and old.status = 'confirmed' then
      if not exists (select 1 from booking_cancellations c where c.booking_id = new.id) then
        raise exception 'Log the cancellation (booking made, cancellation received, start) before cancelling' using errcode = '23514';
      end if;
    end if;
  end if;
  return new;
end $$;
create trigger bookings_before_write before insert or update on bookings
  for each row execute function app.booking_before_write();

create or replace function app.booking_after_status() returns trigger
language plpgsql security definer set search_path = public, app as $$
declare
  v_status vehicle_status;
begin
  if new.status = old.status then return null; end if;

  if new.status = 'on_rent' then
    select status into v_status from vehicles where id = new.vehicle_id;
    if v_status not in ('available', 'exit_notice') then
      raise exception 'Vehicle is % and cannot be handed over', v_status using errcode = '23514';
    end if;
    update vehicles set status = 'on_rent' where id = new.vehicle_id;
    -- during a rental CarmaCars manages, the Owner's lock, alarm and shut-off are blocked (live location stays)
    if new.booking_type <> 'owner' and new.management_mode = 'managed' then
      insert into tracker_access_blocks (vehicle_id, booking_id, reason, starts_at)
      values (new.vehicle_id, new.id, 'managed_rental', coalesce(new.handed_over_at, now()))
      on conflict do nothing;
    end if;
  elsif new.status = 'returned' then
    -- Fleet restores the Owner's controls
    update tracker_access_blocks set ends_at = coalesce(new.checked_in_at, now())
     where booking_id = new.id and ends_at is null;
    -- the Deposit balance is due back within 7 business days of Check-in; a hold-back may run 30 days
    update deposits d
       set release_due_on = app.add_business_days(app.local_date(new.checked_in_at), (app.settings()).deposit_release_business_days),
           held_back_until = case when d.held_back_cents > 0
                                  then app.local_date(new.checked_in_at) + (app.settings()).deposit_holdback_days end
     where d.booking_id = new.id and d.release_due_on is null;
    update vehicles v
       set status = case when exists (select 1 from vehicle_exits e where e.vehicle_id = v.id and e.status = 'notice')
                         then 'exit_notice'::vehicle_status else 'cleaning'::vehicle_status end
     where v.id = new.vehicle_id and v.status = 'on_rent';
    -- the renter's first completed booking drives "first rental only"
    if new.booking_type <> 'owner' then
      update renters set first_completed_booking_id = new.id where id = new.renter_id and first_completed_booking_id is null;
    end if;
    perform app.compute_booking_split(new.id);
  elsif new.status in ('closed', 'cancelled', 'no_show') then
    perform app.compute_booking_split(new.id);
  end if;
  return null;
end $$;
create trigger bookings_after_status after update of status on bookings
  for each row execute function app.booking_after_status();

-- ---------------------------------------------------------------- cancellations: the tier is computed, never typed
create or replace function app.booking_cancellation_fill() returns trigger
language plpgsql security definer set search_path = public, app as $$
declare
  b bookings;
  r record;
begin
  select * into b from bookings where id = new.booking_id;
  new.booked_at := coalesce(new.booked_at, b.booked_at);
  new.start_at := coalesce(new.start_at, b.pickup_at);
  new.total_paid_cents := coalesce(new.total_paid_cents, b.total_due_at_booking_cents);
  -- false documents, or no coverage at pickup, is a cancellation by the renter at that time;
  -- a no-show is a cancellation after the start
  if new.reason in ('renter_request', 'no_show', 'false_documents', 'no_coverage_at_pickup',
                    'carmacars_no_vehicle', 'driver_not_verifiable') then
    select * into r from public.calc_cancellation(new.booked_at,
        case when new.reason = 'no_show' then greatest(new.received_at, new.start_at) else new.received_at end,
        new.start_at, b.booking_type = 'non_refundable', new.total_paid_cents,
        new.reason in ('carmacars_no_vehicle', 'driver_not_verifiable'));
    new.tier := r.tier; new.refund_bps := r.refund_bps; new.refund_cents := r.refund_cents; new.retained_cents := r.retained_cents;
  elsif new.tier is null or new.refund_bps is null or new.refund_cents is null then
    raise exception 'A cancellation outside the table needs its refund set by an Admin' using errcode = '23514';
  end if;
  -- any Deposit already taken is returned in full
  new.deposit_returned_cents := coalesce((select d.captured_cents from deposits d where d.booking_id = new.booking_id), 0);
  return new;
end $$;
create trigger booking_cancellations_fill before insert on booking_cancellations
  for each row execute function app.booking_cancellation_fill();

-- ---------------------------------------------------------------- drivers and deposits
create or replace function app.guard_booking_driver() returns trigger
language plpgsql security definer set search_path = public, app as $$
declare
  v_allows boolean;
begin
  select v.allows_18_to_20 into v_allows from bookings b join vehicles v on v.id = b.vehicle_id where b.id = new.booking_id;
  if new.age_band = '18_to_20' and not coalesce(v_allows, false) then
    raise exception 'Drivers aged 18 to 20 may only take vehicles flagged "18 to 20"' using errcode = '23514';
  end if;
  return new;
end $$;
create trigger booking_drivers_guard before insert or update on booking_drivers
  for each row execute function app.guard_booking_driver();

create or replace function app.guard_deposit() returns trigger
language plpgsql security definer set search_path = public, app as $$
declare
  b bookings;
begin
  select * into b from bookings where id = new.booking_id;
  if b.booking_type = 'owner' and new.amount_cents > 0 then
    raise exception 'An Owner Booking has no Deposit' using errcode = '23514';
  end if;
  -- card hold for 7 days or less; charged, then refunded, for longer
  if tg_op = 'INSERT' and new.method = 'card_hold'
     and public.calc_deposit_method(b.billable_days, (app.settings()).deposit_hold_max_days) <> 'card_hold' then
    raise exception 'A rental over 7 days takes a charged Deposit, not a card hold' using errcode = '23514';
  end if;
  return new;
end $$;
create trigger deposits_guard before insert or update on deposits
  for each row execute function app.guard_deposit();

-- ---------------------------------------------------------------- owner onboarding: what each step needs
create or replace function app.vehicle_onboarding_before_status() returns trigger
language plpgsql security definer set search_path = public, app as $$
declare
  v vehicles;
begin
  if new.status = old.status then return new; end if;
  select * into v from vehicles where id = new.vehicle_id;

  if new.status = 'terms_set' then
    new.terms_set_at := coalesce(new.terms_set_at, now());
  elsif new.status = 'documents_sent' then
    new.documents_sent_at := coalesce(new.documents_sent_at, now());
  elsif new.status = 'documents_signed' then
    if not v.is_shareholder_owned and not exists (
         select 1 from vehicle_schedules s where s.vehicle_id = v.id and s.superseded_by is null and s.signed_at is not null) then
      raise exception 'The vehicle''s Vehicle Schedule is not signed' using errcode = '23514';
    end if;
    new.documents_signed_at := coalesce(new.documents_signed_at, now());
  elsif new.status = 'upfront_paid' then
    if not exists (select 1 from owner_invoices i where i.id = new.upfront_invoice_id and i.status = 'paid') then
      raise exception 'The Install Fee and first and last month''s Insurance Fee are not paid' using errcode = '23514';
    end if;
    new.upfront_paid_at := coalesce(new.upfront_paid_at, now());
  elsif new.status = 'registry_booked' then
    if old.status = 'documents_signed' and not v.is_shareholder_owned then
      raise exception 'Only a shareholder-owned vehicle skips the upfront charges' using errcode = '23514';
    end if;
  elsif new.status = 'tracker_installed' then
    if not exists (select 1 from tracker_devices t where t.vehicle_id = v.id and t.status = 'installed' and t.tested_at is not null) then
      raise exception 'A Tracker must be installed and tested before the vehicle joins the Fleet Policy' using errcode = '23514';
    end if;
    new.tracker_installed_at := coalesce(new.tracker_installed_at, now());
  elsif new.status = 'on_fleet_policy' then
    new.on_fleet_policy_at := coalesce(new.on_fleet_policy_at, now());
  elsif new.status = 'enrolled' then
    if old.status = 'documents_signed' and v.management_mode <> 'turo_only' then
      raise exception 'Only a Turo-Only vehicle is enrolled straight after signature' using errcode = '23514';
    end if;
    new.enrolled_confirmed_at := coalesce(new.enrolled_confirmed_at, now());
  end if;
  return new;
end $$;
create trigger vehicle_onboardings_before_status before update of status on vehicle_onboardings
  for each row execute function app.vehicle_onboarding_before_status();

create or replace function app.vehicle_onboarding_after_status() returns trigger
language plpgsql security definer set search_path = public, app as $$
declare
  v vehicles;
  s vehicle_schedules;
  v_on date;
begin
  if new.status = old.status then return null; end if;
  select * into v from vehicles where id = new.vehicle_id;

  if new.status = 'on_fleet_policy' then
    update vehicles set on_fleet_policy = true, fleet_policy_added_on = app.local_date(new.on_fleet_policy_at)
     where id = v.id;
  elsif new.status = 'enrolled' then
    -- the date of the written confirmation is the Enrollment Date
    v_on := app.local_date(new.enrolled_confirmed_at);
    update vehicles set enrollment_date = v_on, status = 'ready_to_list' where id = v.id;
    select * into s from vehicle_schedules where vehicle_id = v.id and superseded_by is null;
    if s.id is not null then
      update vehicle_schedules set enrollment_date = v_on where id = s.id and enrollment_date is null;
    end if;
    -- open the fee terms that billing and the split read
    if not exists (select 1 from vehicle_fee_history h where h.vehicle_id = v.id) then
      if v.is_shareholder_owned then
        insert into vehicle_fee_history (vehicle_id, source, insurance_fee_cents, tracker_fee_cents, revenue_share_bps, effective_from)
        values (v.id, 'shareholder', 0, 0, (app.settings(v_on)).shareholder_company_share_bps, v_on);
      elsif s.id is not null then
        insert into vehicle_fee_history (vehicle_id, vehicle_schedule_id, source, insurance_fee_cents, tracker_fee_cents, revenue_share_bps, effective_from)
        values (v.id, s.id, 'signed_schedule', s.insurance_fee_cents, s.tracker_fee_cents, s.revenue_share_bps, v_on);
      end if;
    end if;
  elsif new.status in ('declined', 'withdrawn') then
    update vehicles set status = 'declined' where id = v.id and status = 'onboarding';
  end if;
  return null;
end $$;
create trigger vehicle_onboardings_after_status after update of status on vehicle_onboardings
  for each row execute function app.vehicle_onboarding_after_status();

-- ---------------------------------------------------------------- claims: what each step needs
create or replace function app.claim_before_status() returns trigger
language plpgsql security definer set search_path = public, app as $$
begin
  if new.status = old.status then return new; end if;
  if new.status in ('submitted', 'accepted') and new.path not in ('fleet_policy', 'total_loss') then
    raise exception 'Only a fleet policy claim is submitted to the insurer' using errcode = '23514';
  end if;
  if new.status = 'submitted' then
    new.broker_notified_at := coalesce(new.broker_notified_at, now());
  elsif new.status = 'total_loss' then
    new.path := 'total_loss';
  elsif new.status = 'settlement_received' and new.settlement_cents is null then
    raise exception 'Record the settlement before marking it received' using errcode = '23514';
  elsif new.status = 'closed' and new.path in ('at_cost', 'fleet_policy') and new.result_cents is null and old.status <> 'denied' then
    raise exception 'Settle the claim (all money in, costs known) before closing it' using errcode = '23514';
  end if;
  return new;
end $$;
create trigger claims_before_status before update of status on claims
  for each row execute function app.claim_before_status();
