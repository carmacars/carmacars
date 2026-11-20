-- 3195 (release 48, part FE; docs/changes/2026-11-20-r48-fees-evidence-hiring.md): owner use of their own car.
--
-- 1. Bug (owner Karan, Nov 20): an owner could not book their own 2021 Sonata because the car was 'onboarding':
--    app.owner_book_own_vehicle (0022) allowed only available, ready_to_list, cleaning and exit_notice. Every status of a
--    car still in the program and not in repair is allowed now (onboarding, ready_to_list, available, cleaning,
--    exit_notice, on_rent: the dates are checked against the car's bookings); a car that cannot be booked says why
--    (out of service, no longer in the program, on a renter's booking on those dates).
-- 2. Owner use for someone else: app.owner_book_for (public.owner_book_for), "Who's driving?" Me or Someone else (name,
--    email, phone, date of birth). The other person is the booking's main driver (booking_drivers role renter; the
--    Ontario licence rule of the main driver applies to them), gets their own link to upload the licence and selfie and
--    to sign the rental agreement (a signer of their own, is_primary_driver), and the owner stays the account holder who
--    signs too. No price and no deposit; the owner confirms they are responsible (bookings.owner_use_ack_at): the
--    deductible ($2,500 by default) and any damage, tickets, tolls and fees during an owner-use booking are billed to the
--    owner (enrollment agreement 9.3, flat-rate 7.3), with the evidence rules of 3190. Owner bookings stay out of revenue
--    and statements and never block a renter's confirmed booking (unchanged).
-- No applied migration is edited: app.owner_book_own_vehicle is replaced with the same signature (one body, 0022).
set local check_function_bodies = off;

alter table bookings add column if not exists owner_use_for text check (owner_use_for in ('self', 'other')),
  add column if not exists owner_use_ack_at timestamptz;
comment on column bookings.owner_use_for is 'An Owner Booking (3195): self (the owner drives) or other (a family member or friend is the main driver; the owner stays responsible).';
comment on column bookings.owner_use_ack_at is 'When the owner confirmed they are responsible for the deductible and any damage, tickets, tolls and fees of this owner-use booking (3195).';

-- why an owner cannot book their car now (null: they can)
create function app.owner_booking_blocked(p_vehicle uuid, p_pickup timestamptz, p_return timestamptz) returns text
language plpgsql stable security definer set search_path = public, app as $$
declare
  v vehicles;
  x bookings;
begin
  select * into v from vehicles where id = p_vehicle;
  if v.id is null then return 'Vehicle not found'; end if;
  if v.status::text in ('exited', 'total_loss', 'declined') then return 'This car is no longer in the program, so it cannot be booked'; end if;
  if v.status::text = 'out_of_service' then return 'This car is out of service (in repair or waiting for a check): it can be booked once Fleet puts it back in service'; end if;
  select * into x from bookings b where b.vehicle_id = p_vehicle and b.booking_type::text <> 'owner'
     and b.status::text in ('confirmed', 'on_rent', 'pending_payment', 'awaiting_payment') and b.pickup_at < p_return and b.return_at > p_pickup
   order by b.pickup_at limit 1;
  if x.id is not null then
    return format('A renter has this car from %s to %s: choose other dates', to_char(x.pickup_at at time zone 'America/Toronto', 'Mon FMDD FMHH12:MI a.m.'),
                  to_char(x.return_at at time zone 'America/Toronto', 'Mon FMDD FMHH12:MI a.m.'));
  end if;
  return null;
end $$;

create or replace function app.owner_book_own_vehicle(p_by uuid, p_vehicle uuid, p_pickup timestamptz, p_return timestamptz, p_note text default null,
    p_pickup_place text default null, p_return_place text default null)
returns uuid language plpgsql security definer set search_path = public, app as $$
declare
  o owners;
  v_renter uuid;
  v_why text;
begin
  if not app.user_owns_vehicle(p_by, p_vehicle) then
    raise exception 'Not permitted: an owner books only their own vehicle' using errcode = '42501';
  end if;
  select o2.* into o from owners o2 join vehicles v on v.owner_id = o2.id where v.id = p_vehicle;
  v_why := app.owner_booking_blocked(p_vehicle, p_pickup, p_return);
  if v_why is not null then raise exception '%', v_why using errcode = '23514'; end if;
  select id into v_renter from renters where user_id = p_by;
  if v_renter is null then
    insert into renters (user_id, legal_name, mobile, email, is_owner_account)
    values (p_by, o.legal_name, o.phone, o.email, true) returning id into v_renter;
  end if;
  return app.request_booking(v_renter, p_vehicle, p_pickup, p_return, 'owner', p_note, 'owner', p_by, null, null,
                             'collected', 'returned', p_pickup_place, p_return_place);
end $$;

-- p: {vehicle, pickup, return, note, for: self | other, ack: true, driver: {full_name, email, mobile, date_of_birth}}
create function app.owner_book_for(p_by uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  v_for text := coalesce(nullif(p ->> 'for', ''), 'self');
  d jsonb := coalesce(p -> 'driver', '{}'::jsonb);
  v_name text := nullif(btrim(coalesce(d ->> 'full_name', '')), '');
  v_email text := lower(nullif(btrim(coalesce(d ->> 'email', '')), ''));
  v_phone text := left(nullif(btrim(coalesce(d ->> 'mobile', d ->> 'phone', '')), ''), 30);
  v_dob date := nullif(d ->> 'date_of_birth', '')::date;
  v_id uuid;
  b bookings;
  s program_settings;
  v_age integer;
  v_driver uuid;
begin
  if v_for not in ('self', 'other') then raise exception 'Who is driving: self or other' using errcode = '22023'; end if;
  if not coalesce((p ->> 'ack')::boolean, false) then
    raise exception 'Confirm you are responsible for the deductible and any damage, tickets, tolls and fees during this booking' using errcode = '22023';
  end if;
  if v_for = 'other' and (v_name is null or v_email is null or v_email !~ '^[^@\s]+@[^@\s]+\.[^@\s]+$' or v_phone is null or v_dob is null) then
    raise exception 'The driver''s name, email, phone and date of birth are needed' using errcode = '22023';
  end if;
  v_id := app.owner_book_own_vehicle(p_by, (p ->> 'vehicle')::uuid, (p ->> 'pickup')::timestamptz, (p ->> 'return')::timestamptz, nullif(btrim(coalesce(p ->> 'note', '')), ''));
  update bookings set owner_use_for = v_for, owner_use_ack_at = now() where id = v_id returning * into b;
  if v_for = 'other' then
    s := app.settings(app.local_date(b.pickup_at));
    v_age := app.age_on(v_dob, app.local_date(b.pickup_at));
    if v_age < s.min_renter_age then raise exception 'Every driver must be % or older at pickup', s.min_renter_age using errcode = '23514'; end if;
    insert into drivers (renter_id, full_name, date_of_birth, mobile, email) values (b.renter_id, v_name, v_dob, v_phone, v_email) returning id into v_driver;
    -- the other person is the main driver; the owner stays the account holder (and is not a driver of this booking)
    delete from booking_drivers where booking_id = v_id;
    insert into booking_drivers (booking_id, driver_id, role, full_name, date_of_birth, age_at_pickup, age_band)
    values (v_id, v_driver, 'renter', v_name, v_dob, v_age, app.age_band(v_age));
    perform app.log_booking_event(v_id, 'adjusted', b.status::text, b.status::text, null,
      format('Owner use for someone else: %s is the main driver; the owner stays responsible', v_name), p_by, 'renter', jsonb_build_object('driver_id', v_driver));
  end if;
  return jsonb_build_object('booking_id', v_id, 'booking_number', b.booking_number, 'for', v_for, 'driver_id', v_driver);
end $$;

create function public.owner_book_for(p_by uuid, p jsonb) returns jsonb
language sql set search_path = public, app as $$ select app.owner_book_for(p_by, p) $$;

-- the agreement of an owner-use booking for someone else: the owner signs as the account holder, the main driver signs
-- with their own link (the licence and selfie upload of the driver link)
create function app.owner_use_signers() returns trigger
language plpgsql security definer set search_path = public, app as $$
declare
  b bookings;
  bd booking_drivers;
  dv drivers;
  rn renters;
begin
  if new.signer_role <> 'renter' then return null; end if;
  select bk.* into b from bookings bk join rental_agreements a on a.booking_id = bk.id where a.id = new.agreement_id;
  if b.id is null or b.owner_use_for is distinct from 'other' then return null; end if;
  select * into bd from booking_drivers where booking_id = b.id and role = 'renter' limit 1;
  select * into dv from drivers where id = bd.driver_id;
  select * into rn from renters where id = b.renter_id;
  update rental_agreement_signers set booking_driver_id = null, driver_id = null, signer_name = rn.legal_name where id = new.id;
  if bd.id is not null and not exists (select 1 from rental_agreement_signers g where g.agreement_id = new.agreement_id and g.driver_id = bd.driver_id) then
    insert into rental_agreement_signers (agreement_id, signer_role, booking_driver_id, driver_id, signer_name, signer_email, is_primary_driver)
    values (new.agreement_id, 'additional_driver', bd.id, bd.driver_id, bd.full_name, dv.email, true);
  end if;
  return null;
end $$;
drop trigger if exists owner_use_signers on rental_agreement_signers;
create trigger owner_use_signers after insert on rental_agreement_signers for each row execute function app.owner_use_signers();

revoke all on function app.owner_booking_blocked(uuid, timestamptz, timestamptz), app.owner_book_for(uuid, jsonb), public.owner_book_for(uuid, jsonb), app.owner_use_signers()
  from public, anon, authenticated;
grant execute on function app.owner_booking_blocked(uuid, timestamptz, timestamptz), app.owner_book_for(uuid, jsonb), public.owner_book_for(uuid, jsonb), app.owner_use_signers() to service_role;
