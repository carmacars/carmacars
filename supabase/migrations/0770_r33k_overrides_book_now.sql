-- 0770_r33k_overrides_book_now.sql
-- Release 33 part K (docs/changes/2026-11-07-r33-overrides-book-now.md). SCHEMA_MARKER 0770. The owner, November 7:
-- "manually entering the vehicle pickups/returns still doesn't let staff/admin override stuff when we absolutely need
-- the trip to start" and "send an offer and it becomes a booking right away instead of waiting for a renter's approval".
--   1. An Admin override on a pickup or a return. Every check that refuses a pickup (on rent) or a return recorded by
--      hand (the deposit, the signatures, the licence and identity, the coverage, payment due, the calendar switch, the
--      additional drivers, the car's status, maintenance, the Ontario licence, the fleet insurance policy rule when it is
--      on, the agreement's claim details, the tracker; at a return the odometer) can be passed by one scoped, one-shot
--      override: a row of booking_overrides (the booking, the action, the list of checks, the reason). While it is
--      applied (status applying, inside the one transaction that records the pickup or the return) the guards that
--      list its checks let it through (app.override_skips); nothing else is passed, and never another booking. An Admin
--      overrides and records at once; staff (Fleet, customer service, Sales, field) ask, and an Admin approves in one
--      tap from the alert or the To do: the pickup or the return is then recorded with the times the staff entered.
--      Recorded in the booking's history and the audit log; Admins get an alert.
--   2. Record a past trip: a booking whose pickup and return both happened, in one step with both times (km and fuel
--      optional, the photos later), overrides as above: the booking lands in Returned so the deposit can be settled.
--      The car's current status is left as it is, and the "your rental started" email of a trip long over is skipped.
--   3. Book it now (no renter approval) when an offer is sent (with a request, or without one): an Admin's offer becomes
--      the approved version at once (the booking waits for payment and holds the car as an approved offer does; the
--      renter gets the Sign and pay link); staff's waits for an Admin's one-tap approval (alert and To do).
-- No applied migration is edited. Guards are patched in place around their refusals (pg_temp.wrap_raise); the door is
-- wrapped (door_pre0770).
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
declare d text := pg_get_functiondef(p_sig);
begin
  if position(p_old in d) = 0 then raise exception '0770: the text to change was not found in %: %', p_sig, left(p_old, 120); end if;
  execute replace(d, p_old, p_new);
end $$;

-- one refusal (from "raise exception '<start>" to the end of its statement) runs only when the override does not list
-- the check: if not app.override_skips(<booking>, '<code>') then raise ...; end if;
create function pg_temp.wrap_raise(p_sig regprocedure, p_start text, p_code text, p_booking text default 'new.id') returns void
language plpgsql as $$
declare
  d text := pg_get_functiondef(p_sig);
  a integer := position(('raise exception ''' || p_start) in d);
  u integer;
  e integer;
  s text;
begin
  if a = 0 then raise exception '0770: the refusal "%" was not found in %', p_start, p_sig; end if;
  if position(('raise exception ''' || p_start) in substr(d, a + 1)) > 0 then raise exception '0770: the refusal "%" is not unique in %', p_start, p_sig; end if;
  u := a + position('using errcode' in substr(d, a)) - 1;
  e := u + position(';' in substr(d, u)) - 1;
  s := substr(d, a, e - a + 1);
  execute replace(d, s, format('if not app.override_skips(%s, %L) then %s end if;', p_booking, p_code, s));
end $$;

-- ================================================================ 1. the overrides
create table booking_overrides (
  id uuid primary key default gen_random_uuid(),
  booking_id uuid not null references bookings(id) on delete cascade,
  action text not null check (action in ('pickup', 'return', 'past_trip', 'book_now')),
  checks text[] not null default '{}',
  reason text not null check (length(btrim(reason)) >= 5),
  payload jsonb not null default '{}'::jsonb,
  status text not null default 'requested' check (status in ('requested', 'applying', 'used', 'declined', 'cancelled')),
  requested_by uuid references users(id),
  requested_at timestamptz not null default now(),
  decided_by uuid references users(id),
  decided_at timestamptz,
  decision_note text,
  used_at timestamptz,
  result jsonb
);
comment on table booking_overrides is 'One-shot Admin overrides of the checks that refuse a pickup or return recorded by hand, a past trip, or an offer booked without the renter''s approval (0770). Requested by staff, approved by an Admin, or made and used at once by an Admin. While applied (status applying) app.override_skips lets the listed checks of this booking through, in that transaction only.';
create unique index booking_overrides_one_open on booking_overrides (booking_id, action) where status in ('requested', 'applying');
create index booking_overrides_booking on booking_overrides (booking_id, requested_at desc);
alter table booking_overrides enable row level security;
create policy admin_all on booking_overrides for all to authenticated using (app.is_admin()) with check (app.is_admin());
grant select, insert, update, delete on booking_overrides to service_role;
create trigger audit_booking_overrides after insert or update or delete on booking_overrides for each row execute function app.audit_row();

do $$
declare
  c record;
  v_kinds text[];
begin
  select conname, pg_get_constraintdef(oid) as def into strict c from pg_constraint
   where conrelid = 'public.booking_events'::regclass and contype = 'c' and pg_get_constraintdef(oid) like '%kind%';
  select array_agg(distinct m[1]) into v_kinds from regexp_matches(c.def, '[''{,]([a-z_0-9]+)(?=[''},])', 'g') m;
  select array_agg(distinct x order by x) into v_kinds from unnest(v_kinds || array['handover_override', 'offer_booked_now']) x;
  execute format('alter table public.booking_events drop constraint %I', c.conname);
  execute format('alter table public.booking_events add constraint booking_events_kind_check check (kind in (%s))',
                 (select string_agg(quote_literal(x), ', ') from unnest(v_kinds) x));
end $$;

insert into staff_alert_rules (rule, label, grp, who, tier, topic, wired, fixed, hint, sort) values
  ('override_requested', 'Override asked for: approve or decline', 'Bookings', '{admin}', 'urgent', 'alerts', true, false,
   'Staff asked an Admin to override the checks of a pickup or a return, to record a past trip, or to book an offer without the renter''s approval (0770). Approve in one tap from the alert or the To do.', 45),
  ('override_used', 'Override used', 'Bookings', '{admin}', 'normal', 'alerts', true, false,
   'A pickup, a return or a past trip was recorded with an Admin override of its checks, or an offer was booked without the renter''s approval (0770).', 46)
on conflict (rule) do nothing;

insert into task_rules (task_type, queue, title, priority, due_kind, due_amount, procedure_no, completion_rule, description) values
  ('override_approve', 'admin', 'Approve an override', 'high', 'none', null, null, null,
   'Staff asked to record a pickup, a return or a past trip past its checks, or to book an offer without the renter''s approval. Approve: it is recorded with what they entered. Decline: nothing changes.')
on conflict (task_type) do nothing;

-- the plain words of each check
create or replace function app.override_label(p_code text) returns text
language sql immutable as $$
  select case p_code
    when 'payment' then 'Not confirmed yet: the payment (or the signature) is still due'
    when 'agreement' then 'The rental agreement is not signed'
    when 'deposit' then 'The deposit is not taken'
    when 'report_signature' then 'No renter signature on the check-in report'
    when 'agreement_details' then 'The agreement is missing what a claim needs'
    when 'tracker' then 'The tracker is not reporting'
    when 'identity' then 'A driver''s licence or identity is not verified'
    when 'coverage' then 'The coverage is not confirmed'
    when 'drivers' then 'An additional driver has not accepted the agreement'
    when 'calendar' then 'The booking does not block the calendar'
    when 'vehicle_status' then 'The car is not marked available'
    when 'maintenance' then 'Maintenance is overdue on the car'
    when 'fleet_policy' then 'The car is not on the fleet insurance policy yet'
    when 'ontario_licence' then 'Primary driver: an Ontario licence is needed'
    when 'odometer' then 'The odometer is lower than at pickup'
    when 'renter_approval' then 'The renter has not approved the offer'
    else replace(coalesce(p_code, ''), '_', ' ') end
$$;

-- the override applied now lists this check for this booking
create or replace function app.override_skips(p_booking uuid, p_code text) returns boolean
language plpgsql stable security definer set search_path = public, app as $$
declare v text := coalesce(current_setting('app.booking_override', true), '');
begin
  if v !~ '^[0-9a-f-]{36}$' or p_booking is null then return false; end if;
  return exists (select 1 from booking_overrides o where o.id = v::uuid and o.booking_id = p_booking and o.status = 'applying' and p_code = any (o.checks));
end $$;

-- what stops recording the pickup (p_kind pickup), the return (return) or both (past_trip) now: [{code, label}].
-- p: odometer_km (return) or odometer_out_km and odometer_in_km (past trip). A refusal no override passes is raised.
create or replace function app.handover_blockers(p_by uuid, p_booking uuid, p_kind text, p jsonb default '{}'::jsonb) returns jsonb
language plpgsql stable security definer set search_path = public, app as $$
declare
  b bookings;
  c condition_reports;
  v_codes text[] := '{}';
  v_status vehicle_status;
  v_keys text[];
  v_out integer;
  v_in integer;
begin
  select * into b from bookings where id = p_booking;
  if b.id is null then raise exception 'Booking not found' using errcode = 'P0002'; end if;
  if p_kind not in ('pickup', 'return', 'past_trip') then raise exception 'Choose the pickup, the return or the past trip' using errcode = '22023'; end if;
  if coalesce(b.is_placeholder, false) then raise exception 'Booking % is a placeholder: it is never handed over', b.booking_number using errcode = '23514'; end if;
  if p_kind in ('pickup', 'past_trip') then
    if b.status not in ('pending_payment', 'confirmed') then
      raise exception 'Booking % is %: a pickup is recorded on a confirmed booking (or one waiting for payment, with an override)', b.booking_number, replace(b.status::text, '_', ' ') using errcode = '23514';
    end if;
    if b.status = 'pending_payment' then
      if b.offer_approved_version is distinct from b.current_offer_version then
        raise exception 'The current offer is not approved yet: book it first (Book it now), then record the pickup' using errcode = '23514';
      end if;
      v_codes := v_codes || 'payment'::text;
    end if;
    if b.booking_type <> 'owner' and not exists (select 1 from signature_requests s where s.id = b.signature_request_id and s.status = 'completed') then
      v_codes := v_codes || 'agreement'::text;
    end if;
    if b.booking_type <> 'owner' and b.deposit_waived_at is null and b.deposit_cents > 0
       and not exists (select 1 from deposits d where d.booking_id = b.id and d.status in ('held', 'captured')) then
      v_codes := v_codes || 'deposit'::text;
    end if;
    select * into c from condition_reports r where r.booking_id = b.id and r.kind = 'pickup';
    if b.booking_type <> 'owner' and c.renter_signature_ref is null and not coalesce(b.unattended_handover, false) then
      v_codes := v_codes || 'report_signature'::text;
    end if;
    if b.booking_type <> 'owner' and coalesce((app.settings()).agreement_claim_check, true) then
      select array_agg(x ->> 'key') into v_keys from jsonb_array_elements(app.agreement_missing(b.id)) x where (x ->> 'required')::boolean;
      if cardinality(v_keys) > 0 and not exists (
           select 1 from agreement_overrides o where o.booking_id = b.id and (select bool_and(o.missing ? k) from unnest(v_keys) k)) then
        v_codes := v_codes || 'agreement_details'::text;
      end if;
    end if;
    if not app.user_is_admin(p_by) and not coalesce((app.tracker_reading(b.vehicle_id) ->> 'reporting')::boolean, false) then
      v_codes := v_codes || 'tracker'::text;
    end if;
    if exists (select 1 from booking_drivers d where d.booking_id = b.id and d.identity_verified_on is null)
       or not exists (select 1 from booking_drivers d where d.booking_id = b.id and d.role = 'renter') then
      v_codes := v_codes || 'identity'::text;
    end if;
    if b.booking_type <> 'owner' and (b.coverage_confirmed_at is null or not exists (
         select 1 from coverage_proofs cp where cp.booking_id = b.id and cp.status = 'confirmed')) then
      v_codes := v_codes || 'coverage'::text;
    end if;
    if exists (select 1 from booking_drivers d where d.booking_id = b.id and d.role = 'additional' and d.accepted_at is null) then
      v_codes := v_codes || 'drivers'::text;
    end if;
    if not b.blocks_calendar then v_codes := v_codes || 'calendar'::text; end if;
    select status into v_status from vehicles where id = b.vehicle_id;
    if v_status not in ('available', 'exit_notice', 'ready_to_list') then v_codes := v_codes || 'vehicle_status'::text; end if;
    if b.booking_type <> 'owner' and app.maint_handover_block(b.vehicle_id) is not null then v_codes := v_codes || 'maintenance'::text; end if;
    -- the fleet insurance policy rule: always on before the Program setting of the hotfix, its setting after
    if not app.vehicle_on_policy(b.vehicle_id)
       and coalesce((to_jsonb(app.settings()) ->> 'field_handover_requires_fleet_policy')::boolean, true) then
      v_codes := v_codes || 'fleet_policy'::text;
    end if;
    if app.primary_ontario_needed(b.id) then v_codes := v_codes || 'ontario_licence'::text; end if;
    if p_kind = 'past_trip' then
      v_out := nullif(p ->> 'odometer_out_km', '')::numeric::integer;
      v_in := nullif(p ->> 'odometer_in_km', '')::numeric::integer;
      if v_out is not null and v_in is not null and v_in < v_out then v_codes := v_codes || 'odometer'::text; end if;
    end if;
  else
    if b.status <> 'on_rent' then
      raise exception 'Booking % is %: a return is recorded while the car is on rent', b.booking_number, replace(b.status::text, '_', ' ') using errcode = '23514';
    end if;
    v_in := nullif(p ->> 'odometer_km', '')::numeric::integer;
    if v_in is not null and b.odometer_out_km is not null and v_in < b.odometer_out_km
       and not exists (select 1 from booking_vehicle_swaps s where s.booking_id = b.id) then
      v_codes := v_codes || 'odometer'::text;
    end if;
  end if;
  return coalesce((select jsonb_agg(jsonb_build_object('code', x, 'label', app.override_label(x)) order by o) from unnest(v_codes) with ordinality t(x, o)), '[]'::jsonb);
end $$;

-- the car of the booking whose override is applied moves to on rent (or back to where it was, after a past trip) from
-- any status, when the override lists the car's status or records a past trip
create or replace function app.override_moves_vehicle(p_vehicle uuid) returns boolean
language plpgsql stable security definer set search_path = public, app as $$
declare v text := coalesce(current_setting('app.booking_override', true), '');
begin
  if v !~ '^[0-9a-f-]{36}$' or p_vehicle is null then return false; end if;
  return exists (select 1 from booking_overrides o join bookings b on b.id = o.booking_id
                  where o.id = v::uuid and o.status = 'applying' and b.vehicle_id = p_vehicle
                    and (o.action = 'past_trip' or 'vehicle_status' = any (o.checks)));
end $$;

-- the booking page's view: what blocks the pickup or the return now, and the requests waiting
create or replace function app.override_view(p_by uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  b bookings;
  v_kind text;
  v_blockers jsonb := '[]'::jsonb;
  v_err text;
begin
  if not app.user_may_handover(p_by) then raise exception 'Only an Admin, Fleet, Sales, Customer service or field staff record a check-in or check-out' using errcode = '42501'; end if;
  select * into b from bookings where id::text = p ->> 'booking' or booking_number = upper(btrim(coalesce(p ->> 'booking', '')));
  if b.id is null then raise exception 'Booking not found' using errcode = 'P0002'; end if;
  v_kind := case when b.status = 'on_rent' then 'return' when b.status in ('pending_payment', 'confirmed') then 'pickup' end;
  if v_kind is not null and not coalesce(b.is_placeholder, false) then
    begin
      v_blockers := app.handover_blockers(p_by, b.id, v_kind, '{}'::jsonb);
    exception when others then v_err := sqlerrm; end;
  end if;
  return jsonb_build_object('booking_id', b.id, 'booking_number', b.booking_number, 'status', b.status, 'kind', v_kind,
    'admin', app.user_is_admin(p_by), 'blockers', v_blockers, 'problem', v_err,
    -- a past trip: both times in the past, nothing recorded yet
    'past_trip', v_kind = 'pickup' and v_err is null and b.pickup_at < now()
                 and not exists (select 1 from condition_reports c where c.booking_id = b.id and c.kind = 'pickup' and c.completed_at is not null),
    'pickup_at', b.pickup_at, 'return_at', b.return_at,
    'requests', coalesce((select jsonb_agg(jsonb_build_object('id', o.id, 'action', o.action, 'status', o.status, 'reason', o.reason, 'requested_at', o.requested_at,
                     'requested_by', (select u.full_name from users u where u.id = o.requested_by), 'mine', o.requested_by = p_by, 'payload', o.payload,
                     'checks', (select jsonb_agg(jsonb_build_object('code', x, 'label', app.override_label(x))) from unnest(o.checks) x)) order by o.requested_at desc)
                   from booking_overrides o where o.booking_id = b.id and o.status = 'requested'), '[]'::jsonb));
end $$;

-- the times and readings staff entered, checked once (they are used when the override is applied)
create or replace function app.override_payload(b bookings, p_action text, p jsonb) returns jsonb
language plpgsql stable set search_path = public, app as $$
declare
  v_at timestamptz;
  v_pick timestamptz;
  v_ret timestamptz;
begin
  if p_action in ('pickup', 'return') then
    v_at := coalesce(nullif(p ->> 'at', '')::timestamptz, now());
    if v_at > now() + interval '5 minutes' then raise exception 'Give the actual time (not in the future)' using errcode = '22023'; end if;
    return jsonb_strip_nulls(jsonb_build_object('at', least(v_at, now()), 'odometer_km', nullif(p ->> 'odometer_km', '')::numeric::integer, 'fuel_pct', nullif(p ->> 'fuel_pct', '')::numeric::integer));
  end if;
  v_pick := nullif(p ->> 'pickup_at', '')::timestamptz;
  v_ret := nullif(p ->> 'return_at', '')::timestamptz;
  if v_pick is null or v_ret is null then raise exception 'Give the actual pickup and return times' using errcode = '22023'; end if;
  if v_ret <= v_pick then raise exception 'The return is after the pickup' using errcode = '22023'; end if;
  if v_ret > now() + interval '5 minutes' then raise exception 'A past trip has both times in the past: record the pickup only while the car is still out' using errcode = '22023'; end if;
  return jsonb_strip_nulls(jsonb_build_object('pickup_at', v_pick, 'return_at', least(v_ret, now()),
    'odometer_out_km', nullif(p ->> 'odometer_out_km', '')::numeric::integer, 'fuel_out_pct', nullif(p ->> 'fuel_out_pct', '')::numeric::integer,
    'odometer_in_km', nullif(p ->> 'odometer_in_km', '')::numeric::integer, 'fuel_in_pct', nullif(p ->> 'fuel_in_pct', '')::numeric::integer));
end $$;

-- an override applied: in this transaction only, as the person who entered it, then used
create or replace function app.override_apply(p_id uuid, p_admin uuid) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  o booking_overrides;
  b bookings;
  v_actor uuid;
  v_status vehicle_status;
  r1 jsonb;
  r2 jsonb;
  v_res jsonb;
  v_note text;
  v_who text;
begin
  select * into o from booking_overrides where id = p_id for update;
  if o.id is null or o.status <> 'requested' then raise exception 'This override is no longer waiting' using errcode = '23514'; end if;
  select * into b from bookings where id = o.booking_id for update;
  v_actor := coalesce(o.requested_by, p_admin);
  v_who := coalesce((select full_name from users where id = p_admin), 'An Admin');

  if o.action = 'book_now' then
    if b.status = 'offered' then
      update booking_overrides set status = 'applying', checks = array['renter_approval'] where id = o.id;
      perform set_config('app.booking_override', o.id::text, true);
      -- the renter's approval given by CarmaCars: the offer's own checks stand (expiry, charges, the car still free); the
      -- licence is asked on the Sign and pay page before payment
      perform app.approve_offer_pre0130(b.id, b.current_offer_version, p_admin);
      perform set_config('app.booking_override', '', true);
      v_res := jsonb_build_object('status', 'approved', 'booking_id', b.id, 'booking_number', b.booking_number,
                                  'renter_user_id', (select r.user_id from renters r where r.id = b.renter_id));
      v_note := format('Booked now by %s without the renter''s approval (offer version %s): waiting for the renter to sign and pay. %s', v_who, b.current_offer_version, o.reason);
      perform app.log_booking_event(b.id, 'offer_booked_now', 'offered', 'pending_payment', b.current_offer_version, v_note, p_admin, 'staff',
        jsonb_build_object('override_id', o.id, 'requested_by', o.requested_by));
    elsif b.status = 'pending_payment' and b.offer_approved_version = b.current_offer_version then
      v_res := jsonb_build_object('status', 'already', 'booking_id', b.id, 'booking_number', b.booking_number);
      v_note := 'The renter had already approved the offer';
    else
      raise exception 'Booking % is %: there is no open offer to book', b.booking_number, replace(b.status::text, '_', ' ') using errcode = '23514';
    end if;
  else
    -- the checks as they stand now (they may have changed since the request)
    update booking_overrides set status = 'applying',
           checks = coalesce((select array_agg(x ->> 'code') from jsonb_array_elements(app.handover_blockers(v_actor, b.id, o.action, o.payload)) x), '{}')
     where id = o.id returning * into o;
    perform set_config('app.booking_override', o.id::text, true);
    select status into v_status from vehicles where id = b.vehicle_id;
    if b.status = 'pending_payment' then
      perform set_config('app.confirm_offline', b.id::text, true);
      update bookings set status = 'confirmed' where id = b.id;
      perform set_config('app.confirm_offline', '', true);
      perform app.log_booking_event(b.id, 'confirmed', 'pending_payment', 'confirmed', b.offer_approved_version,
        'Confirmed by an Admin override to start the trip: the payment is still due', p_admin, 'staff',
        jsonb_build_object('mode', 'override', 'override_id', o.id, 'awaiting_signature', 'agreement' = any (o.checks)));
    end if;
    if o.action in ('pickup', 'past_trip') then
      r1 := app.handover_record_now(v_actor, jsonb_strip_nulls(jsonb_build_object('booking', b.id, 'kind', 'pickup',
              'at', coalesce(o.payload ->> 'at', o.payload ->> 'pickup_at'),
              'odometer_km', coalesce(o.payload ->> 'odometer_km', o.payload ->> 'odometer_out_km'),
              'fuel_pct', coalesce(o.payload ->> 'fuel_pct', o.payload ->> 'fuel_out_pct'),
              'reason', 'Admin override: ' || o.reason)));
    end if;
    if o.action in ('return', 'past_trip') then
      r2 := app.handover_record_now(v_actor, jsonb_strip_nulls(jsonb_build_object('booking', b.id, 'kind', 'return',
              'at', coalesce(o.payload ->> 'at', o.payload ->> 'return_at'),
              'odometer_km', coalesce(case when o.action = 'return' then o.payload ->> 'odometer_km' end, o.payload ->> 'odometer_in_km'),
              'fuel_pct', coalesce(case when o.action = 'return' then o.payload ->> 'fuel_pct' end, o.payload ->> 'fuel_in_pct'),
              'reason', 'Admin override: ' || o.reason)));
    end if;
    if o.action = 'past_trip' then
      -- a trip long over: the car is where it is now, and its "rental started" email is not sent
      update vehicles set status = v_status where id = b.vehicle_id and status is distinct from v_status;
      update notification_outbox set status = 'skipped', status_reason = 'Past trip recorded later (0770)'
       where booking_id = b.id and code = 'renter_rental_started' and status in ('queued', 'delayed');
    end if;
    perform set_config('app.booking_override', '', true);
    v_res := jsonb_build_object('status', 'recorded', 'booking_id', b.id, 'booking_number', b.booking_number,
                                'booking_status', (select status from bookings where id = b.id), 'pickup', r1, 'return', r2);
    v_note := format('%s recorded with an Admin override (%s)%s: %s. Overridden: %s',
      case o.action when 'pickup' then 'Pickup' when 'return' then 'Return' else 'Past trip' end, v_who,
      case when o.requested_by is not null and o.requested_by <> p_admin then ', asked by ' || coalesce((select full_name from users where id = o.requested_by), 'staff') else '' end,
      o.reason, coalesce(nullif((select string_agg(app.override_label(x), '; ') from unnest(o.checks) x), ''), 'nothing was blocking'));
    perform app.log_booking_event(b.id, 'handover_override', b.status::text, (select status::text from bookings where id = b.id), null, v_note, p_admin, 'staff',
      jsonb_build_object('override_id', o.id, 'action', o.action, 'checks', to_jsonb(o.checks), 'payload', o.payload, 'requested_by', o.requested_by));
  end if;

  update booking_overrides set status = 'used', used_at = now(), result = v_res,
         decided_by = coalesce(decided_by, p_admin), decided_at = coalesce(decided_at, now()) where id = o.id;
  insert into audit_log (actor_user_id, action, entity_table, entity_id, before, after)
  values (p_admin, 'booking_override_used', 'bookings', b.id::text, jsonb_build_object('status', b.status),
          jsonb_build_object('override_id', o.id, 'action', o.action, 'checks', to_jsonb(o.checks), 'reason', o.reason, 'requested_by', o.requested_by, 'result', v_res));
  update tasks set status = 'done', completed_at = now(), completed_by = p_admin, completion_note = 'Approved'
   where task_type = 'override_approve' and related_table = 'booking_overrides' and related_id = o.id and status in ('open', 'in_progress', 'waiting');
  perform app.staff_alert('override_used', 'booking_override', o.id, 'used',
    left(format('Override used: %s', b.booking_number), 200), left(v_note, 1000),
    jsonb_build_object('path_admin', '/admin/bookings/' || b.booking_number, 'path_staff', '/staff/bookings/' || b.booking_number));
  return v_res;
end $$;

-- staff ask (or an Admin does it now): p booking, kind (pickup, return, past_trip), the times and readings, reason
create or replace function app.handover_override(p_by uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  b bookings;
  v_kind text := p ->> 'kind';
  v_reason text := nullif(btrim(coalesce(p ->> 'reason', '')), '');
  v_payload jsonb;
  v_checks text[];
  o booking_overrides;
  v_task uuid;
  v_who text := coalesce((select full_name from users where id = p_by), 'Staff');
begin
  if not app.user_may_handover(p_by) then raise exception 'Only an Admin, Fleet, Sales, Customer service or field staff record a check-in or check-out' using errcode = '42501'; end if;
  if v_kind is null or v_kind not in ('pickup', 'return', 'past_trip') then raise exception 'Choose the pickup, the return or the past trip' using errcode = '22023'; end if;
  if v_reason is null or length(v_reason) < 5 then raise exception 'Say why the trip must go ahead (at least 5 characters)' using errcode = '22023'; end if;
  select * into b from bookings where id::text = p ->> 'booking' or booking_number = upper(btrim(coalesce(p ->> 'booking', ''))) for update;
  if b.id is null then raise exception 'Booking not found' using errcode = 'P0002'; end if;
  v_payload := app.override_payload(b, v_kind, p);
  if v_kind = 'pickup' and (v_payload ->> 'at')::timestamptz < b.booked_at - interval '30 days' then
    raise exception 'Check the pickup time: it is long before the booking was made' using errcode = '22023';
  end if;
  select array_agg(x ->> 'code') into v_checks from jsonb_array_elements(app.handover_blockers(p_by, b.id, v_kind, v_payload)) x;
  if exists (select 1 from booking_overrides x where x.booking_id = b.id and x.action = v_kind and x.status = 'requested') then
    update booking_overrides set status = 'cancelled', decision_note = 'Replaced by a new request', decided_by = p_by, decided_at = now()
     where booking_id = b.id and action = v_kind and status = 'requested';
    update tasks set status = 'done', completed_at = now(), completed_by = p_by, completion_note = 'Replaced by a new request'
     where task_type = 'override_approve' and related_table = 'booking_overrides' and status in ('open', 'in_progress', 'waiting')
       and related_id in (select id from booking_overrides where booking_id = b.id and action = v_kind and status = 'cancelled');
  end if;
  insert into booking_overrides (booking_id, action, checks, reason, payload, requested_by)
  values (b.id, v_kind, coalesce(v_checks, '{}'), v_reason, v_payload, p_by) returning * into o;
  if app.user_is_admin(p_by) then
    update booking_overrides set decided_by = p_by, decided_at = now() where id = o.id;
    return app.override_apply(o.id, p_by);
  end if;
  v_task := app.raise_task(p_type => 'override_approve', p_queue => 'admin', p_priority => 'high',
    p_title => left(format('%s: approve the override (%s)', b.booking_number, case v_kind when 'pickup' then 'pickup' when 'return' then 'return' else 'past trip' end), 200),
    p_detail => left(format('%s asks to record the %s past: %s. Reason: %s', v_who,
                  case v_kind when 'pickup' then 'pickup at ' || app.fmt_at((v_payload ->> 'at')::timestamptz)
                              when 'return' then 'return at ' || app.fmt_at((v_payload ->> 'at')::timestamptz)
                              else 'trip from ' || app.fmt_at((v_payload ->> 'pickup_at')::timestamptz) || ' to ' || app.fmt_at((v_payload ->> 'return_at')::timestamptz) end,
                  coalesce(nullif((select string_agg(app.override_label(x), '; ') from unnest(o.checks) x), ''), 'nothing is blocking now'), v_reason), 2000),
    p_booking => b.id, p_vehicle => b.vehicle_id, p_renter => b.renter_id, p_related_table => 'booking_overrides', p_related_id => o.id,
    p_dedupe => 'override_approve:' || o.id, p_created_by => p_by);
  perform app.staff_alert('override_requested', 'booking_override', o.id, 'requested',
    left(format('Override asked for: %s (%s)', b.booking_number, case v_kind when 'pickup' then 'pickup' when 'return' then 'return' else 'past trip' end), 200),
    left(format('%s: %s. Overrides: %s. Approve in one tap on the booking or the To do.', v_who, v_reason,
         coalesce(nullif((select string_agg(app.override_label(x), '; ') from unnest(o.checks) x), ''), 'nothing is blocking now')), 1000),
    jsonb_build_object('path_admin', '/admin/bookings/' || b.booking_number, 'path_staff', '/staff/bookings/' || b.booking_number));
  perform app.log_booking_event(b.id, 'handover_override', b.status::text, b.status::text, null,
    format('%s asked an Admin to override the %s: %s', v_who, case v_kind when 'pickup' then 'pickup' when 'return' then 'return' else 'past trip' end, v_reason),
    p_by, 'staff', jsonb_build_object('override_id', o.id, 'action', v_kind, 'checks', to_jsonb(o.checks), 'payload', v_payload, 'requested', true));
  return jsonb_build_object('status', 'requested', 'id', o.id, 'booking_number', b.booking_number, 'checks', to_jsonb(o.checks));
end $$;

-- Book it now: an Admin books the offer at once; staff ask an Admin
create or replace function app.offer_book_now(p_by uuid, p_booking uuid, p_reason text default null) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  b bookings;
  o booking_overrides;
  v_reason text := coalesce(nullif(btrim(coalesce(p_reason, '')), ''), 'Book it now: the renter agreed to the offer');
  v_who text := coalesce((select full_name from users where id = p_by), 'Staff');
  v_res jsonb;
begin
  if app.offer_role(p_by) is null then raise exception 'Customer service, sales or an Admin books an offer' using errcode = '42501'; end if;
  select * into b from bookings where id = p_booking for update;
  if b.id is null then raise exception 'Booking not found' using errcode = 'P0002'; end if;
  if b.status <> 'offered' then raise exception 'Booking % is %: there is no open offer to book', b.booking_number, replace(b.status::text, '_', ' ') using errcode = '23514'; end if;
  update booking_overrides set status = 'cancelled', decision_note = 'Replaced by a new request', decided_by = p_by, decided_at = now()
   where booking_id = b.id and action = 'book_now' and status = 'requested';
  insert into booking_overrides (booking_id, action, checks, reason, payload, requested_by)
  values (b.id, 'book_now', array['renter_approval'], v_reason, jsonb_build_object('offer_version', b.current_offer_version), p_by) returning * into o;
  if app.user_is_admin(p_by) then
    update booking_overrides set decided_by = p_by, decided_at = now() where id = o.id;
    v_res := app.override_apply(o.id, p_by);
    -- the renter's one link is the Sign and pay page (the agreement's email): the "approve your offer" email is not needed
    update notification_outbox set status = 'skipped', status_reason = 'Booked now: the renter gets the Sign and pay link (0770)'
     where booking_id = b.id and code = 'renter_offer_ready' and status in ('queued', 'delayed');
    return v_res;
  end if;
  perform app.raise_task(p_type => 'override_approve', p_queue => 'admin', p_priority => 'high',
    p_title => left(format('%s: approve booking the offer now (no renter approval)', b.booking_number), 200),
    p_detail => left(format('%s sent the offer and asks to book it at once: %s. Approve: the booking waits for the renter to sign and pay, and holds the car.', v_who, v_reason), 2000),
    p_booking => b.id, p_vehicle => b.vehicle_id, p_renter => b.renter_id, p_related_table => 'booking_overrides', p_related_id => o.id,
    p_dedupe => 'override_approve:' || o.id, p_created_by => p_by);
  perform app.staff_alert('override_requested', 'booking_override', o.id, 'requested',
    left(format('Book it now asked for: %s', b.booking_number), 200),
    left(format('%s sent the offer and asks to book it without the renter''s approval: %s. Approve in one tap on the booking or the To do.', v_who, v_reason), 1000),
    jsonb_build_object('path_admin', '/admin/bookings/' || b.booking_number, 'path_staff', '/staff/bookings/' || b.booking_number));
  perform app.log_booking_event(b.id, 'offer_booked_now', b.status::text, b.status::text, b.current_offer_version,
    format('%s asked an Admin to book the offer now, without the renter''s approval: %s', v_who, v_reason), p_by, 'staff',
    jsonb_build_object('override_id', o.id, 'requested', true));
  return jsonb_build_object('status', 'requested', 'id', o.id, 'booking_id', b.id, 'booking_number', b.booking_number);
end $$;

-- an Admin approves or declines; the requester (or an Admin) cancels
create or replace function app.override_decide(p_by uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  o booking_overrides;
  v_decision text := coalesce(p ->> 'decision', 'approve');
  v_note text := nullif(btrim(coalesce(p ->> 'note', '')), '');
begin
  select * into o from booking_overrides where id::text = p ->> 'id' for update;
  if o.id is null then raise exception 'Override not found' using errcode = 'P0002'; end if;
  if o.status <> 'requested' then raise exception 'This override was already %', o.status using errcode = '23514'; end if;
  if v_decision = 'cancel' then
    if o.requested_by is distinct from p_by and not app.user_is_admin(p_by) then raise exception 'Only who asked, or an Admin, cancels it' using errcode = '42501'; end if;
  elsif not app.user_is_admin(p_by) then
    raise exception 'An Admin approves or declines an override' using errcode = '42501';
  end if;
  if v_decision = 'approve' then
    update booking_overrides set decided_by = p_by, decided_at = now(), decision_note = v_note where id = o.id;
    return app.override_apply(o.id, p_by);
  elsif v_decision not in ('decline', 'cancel') then
    raise exception 'Approve, decline or cancel' using errcode = '22023';
  end if;
  update booking_overrides set status = case v_decision when 'decline' then 'declined' else 'cancelled' end,
         decided_by = p_by, decided_at = now(), decision_note = v_note where id = o.id;
  update tasks set status = 'done', completed_at = now(), completed_by = p_by, completion_note = initcap(v_decision) || 'd' || coalesce(': ' || v_note, '')
   where task_type = 'override_approve' and related_table = 'booking_overrides' and related_id = o.id and status in ('open', 'in_progress', 'waiting');
  perform app.log_booking_event(o.booking_id, case o.action when 'book_now' then 'offer_booked_now' else 'handover_override' end,
    (select status::text from bookings where id = o.booking_id), (select status::text from bookings where id = o.booking_id), null,
    format('Override %s by %s%s', case v_decision when 'decline' then 'declined' else 'cancelled' end, coalesce((select full_name from users where id = p_by), 'staff'), coalesce(': ' || v_note, '')),
    p_by, 'staff', jsonb_build_object('override_id', o.id, 'decision', v_decision));
  return jsonb_build_object('status', case v_decision when 'decline' then 'declined' else 'cancelled' end, 'id', o.id);
end $$;

-- ================================================================ 2. the guards pass what the override lists
-- booking_before_write: payment due (the confirmation without payment), identity, coverage, deposit
select pg_temp.wrap_raise('app.booking_before_write()'::regprocedure, 'A booking is confirmed only when payment succeeds', 'payment');
select pg_temp.wrap_raise('app.booking_before_write()'::regprocedure, 'No car is released until every driver''''s identity is verified', 'identity');
select pg_temp.wrap_raise('app.booking_before_write()'::regprocedure, 'No car is released until a Coverage Option is confirmed', 'coverage');
select pg_temp.wrap_raise('app.booking_before_write()'::regprocedure, 'The Deposit is taken at pickup, before handover', 'deposit');
-- booking_app_before: the calendar switch, the additional drivers, the deposit
select pg_temp.wrap_raise('app.booking_app_before()'::regprocedure, 'A booking that does not block the calendar cannot be handed over', 'calendar');
select pg_temp.wrap_raise('app.booking_app_before()'::regprocedure, 'No car is released until every additional driver has accepted', 'drivers');
select pg_temp.wrap_raise('app.booking_app_before()'::regprocedure, 'No car is released without the Deposit', 'deposit');
-- the signed agreement
select pg_temp.wrap_raise('app.booking_signature_guard()'::regprocedure, 'Do not release the car: the renter has not signed the rental agreement yet (in the portal', 'agreement');
select pg_temp.wrap_raise('app.booking_signature_guard()'::regprocedure, 'Do not release the car: the renter has not signed the rental agreement yet (Sign now', 'agreement');
-- maintenance, the Ontario licence, the car's status
select pg_temp.wrap_raise('app.maint_bookings_before()'::regprocedure, 'Do not release the car: %. Renew it', 'maintenance');
select pg_temp.wrap_raise('app.booking_primary_ontario_guard()'::regprocedure, 'Do not release the car: Primary driver: Ontario licence needed', 'ontario_licence');
select pg_temp.wrap_raise('app.booking_after_status()'::regprocedure, 'Vehicle is % and cannot be handed over', 'vehicle_status');
select pg_temp.patch_fn('app.enforce_status_flow()'::regprocedure,
  $o$raise exception '% cannot go from % to %', v_entity, v_old, v_new using errcode = '23514';$o$,
  $n$if not (v_entity = 'vehicle' and app.override_moves_vehicle((to_jsonb(new) ->> 'id')::uuid)) then
        raise exception '% cannot go from % to %', v_entity, v_old, v_new using errcode = '23514';
      end if;$n$);
-- the fleet insurance policy rule (its Program setting, when the hotfix is in, decides whether it applies at all)
select pg_temp.patch_fn('app.booking_handover_on_policy()'::regprocedure, E'AS $function$\nbegin\n',
  E'AS $function$\nbegin\n  if app.override_skips(new.id, ''fleet_policy'') then return new; end if;\n');
-- recording the pickup or the return by hand
select pg_temp.wrap_raise('app.handover_record_now(uuid, jsonb)'::regprocedure, 'The deposit is not taken: take it first', 'deposit', 'b.id');
select pg_temp.patch_fn('app.handover_record_now(uuid, jsonb)'::regprocedure, 'perform app.waive_deposit(b.id, p_by, v_dep_reason);',
  'if v_admin and v_dep_reason is not null and length(v_dep_reason) >= 5 then perform app.waive_deposit(b.id, p_by, v_dep_reason); end if;');
select pg_temp.wrap_raise('app.handover_record_now(uuid, jsonb)'::regprocedure, 'The renter has not signed the check-', 'report_signature', 'b.id');
select pg_temp.wrap_raise('app.handover_record_now(uuid, jsonb)'::regprocedure, 'The rental agreement is missing what a claim needs', 'agreement_details', 'b.id');
select pg_temp.wrap_raise('app.handover_record_now(uuid, jsonb)'::regprocedure, 'Do not release the car: the Tracker is not in place', 'tracker', 'b.id');
select pg_temp.wrap_raise('app.handover_record_now(uuid, jsonb)'::regprocedure, 'The odometer reading (%) is lower than at pickup', 'odometer', 'b.id');

-- ================================================================ 3. the door
alter function app.door(uuid, text, text, text, jsonb) rename to door_pre0770;
create function app.door(p_user uuid, p_aal text, p_call text, p_name text, p jsonb default '{}'::jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  x jsonb;
  v_book boolean := coalesce((p ->> 'book_now')::boolean, false);
  v_booking uuid;
begin
  if (p_call = 'ops_do' and p_name in ('handover_override', 'override_decide')) or (p_call = 'ops_read' and p_name = 'handover_blockers') then
    if coalesce(p, '{}'::jsonb) ? '_va' then perform set_config('app.va_active', coalesce(p ->> '_va', ''), true); end if;
    perform app.door_begin(p_user, p_aal);
    p := coalesce(p, '{}'::jsonb) - '_va';
    return case p_name
      when 'handover_override' then app.handover_override(p_user, p)
      when 'override_decide' then app.override_decide(p_user, p)
      else app.override_view(p_user, p) end;
  end if;
  -- Book it now, with the offer: sent (or made) and booked in the same transaction
  if p_name in ('send_offer', 'offer_create') and coalesce(p, '{}'::jsonb) ? 'book_now' then
    x := app.door_pre0770(p_user, p_aal, p_call, p_name, p - 'book_now' - 'book_now_reason');
    if not v_book or coalesce((p ->> 'draft')::boolean, false) then return x; end if;
    v_booking := coalesce((x ->> 'booking_id')::uuid,
      (select id from bookings where id::text = p ->> 'booking' or booking_number = upper(btrim(coalesce(p ->> 'booking', ''))) limit 1),
      (select id from bookings where booking_number = x ->> 'booking_number'));
    return case when jsonb_typeof(x) = 'object' then x else jsonb_build_object('result', x) end
           || jsonb_build_object('book_now', app.offer_book_now(p_user, v_booking, p ->> 'book_now_reason'));
  end if;
  return app.door_pre0770(p_user, p_aal, p_call, p_name, p);
end $$;
select pg_temp.copy_grants('app.door(uuid, text, text, text, jsonb)'::regprocedure, 'app.door_pre0770(uuid, text, text, text, jsonb)'::regprocedure);

-- ================================================================ 4. privileges
do $$
declare f record;
begin
  for f in
    select p.oid::regprocedure as sig from pg_proc p join pg_namespace n on n.oid = p.pronamespace
     where n.nspname = 'app' and p.proname = any (array['override_label', 'override_skips', 'override_moves_vehicle', 'handover_blockers', 'override_view', 'override_payload', 'override_apply',
             'handover_override', 'offer_book_now', 'override_decide', 'door_pre0770'])
  loop
    execute format('revoke all on function %s from public, anon, authenticated', f.sig);
    execute format('grant execute on function %s to service_role', f.sig);
  end loop;
end $$;
-- the guards call it inside triggers fired by any role
grant execute on function app.override_skips(uuid, text), app.override_moves_vehicle(uuid) to authenticated;
