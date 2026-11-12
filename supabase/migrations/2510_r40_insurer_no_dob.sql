-- 2510_r40_insurer_no_dob.sql (release 40)
-- Owner, Nov 12: an insurer-billed rental (an insurance replacement referred by a partner) is often added with only the renter's
-- name, the policy/claim and the licence number: no date of birth. Add a rental refused it ("Enter the renter's full legal name
-- and date of birth"). Now, when the rent is billed to an insurer (payment method insurer, an insurer named), the date of birth
-- is optional; the name is still required. Every other rental still needs it.
--   1. drivers.date_of_birth and booking_drivers.date_of_birth / age_at_pickup / age_band may be empty (renters.date_of_birth
--      already could). With no date of birth there is no age: no age band, so no young driver fee and no age rule to check.
--      The 18+ rule still applies whenever a date of birth is given. Additional drivers still need a date of birth.
--   2. app.manual_rental_insurer_billed(p): the one case, in one place.
--   3. app.manual_rental_create wraps the current Add a rental (2371): for an insurer-billed rental with no date of birth typed for a NEW
--      renter, the existing path is run with a stand-in date (1900-01-01) that is removed again in the same transaction (renter,
--      driver and the booking's driver line are emptied), so the whole chain of checks (calendar, contact, fees, split) is
--      exactly the one already tested. For any other rental, a driver line left without an age refuses the call as before.
-- The agreement prints "Date of birth: -" (features/agreement/model.ts reads it as optional); the insurer invoice and the owner
-- statements read the booking and the insurer, not the date of birth. Renters can be edited later to add one (RenterEdit).
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

-- ================================================================ 1. a driver may have no known date of birth
alter table drivers alter column date_of_birth drop not null;
alter table booking_drivers alter column date_of_birth drop not null;
alter table booking_drivers alter column age_at_pickup drop not null;
alter table booking_drivers alter column age_band drop not null;
-- the age and its band go together (the 18+ and band checks of 0005 hold whenever an age is given)
alter table booking_drivers add constraint booking_drivers_age_band_known check ((age_at_pickup is null) = (age_band is null));

-- ================================================================ 2. the one case
create function app.manual_rental_insurer_billed(p jsonb) returns boolean
language sql stable set search_path = public, app as $$
  select coalesce(p #>> '{payment,method}' = 'insurer', false) and jsonb_typeof(p -> 'insurance') = 'object'
$$;
comment on function app.manual_rental_insurer_billed(jsonb) is 'Add a rental (2510): the rent is billed to an insurer, so the renter''s date of birth is optional (the name is not).';

-- ================================================================ 3. the door of Add a rental
alter function app.manual_rental_create(uuid, jsonb) rename to manual_rental_create_pre2510;
create function app.manual_rental_create(p_by uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  c_stand_in constant date := date '1900-01-01';
  r jsonb := coalesce(p -> 'renter', '{}'::jsonb);
  v_stand boolean := false;
  v_out jsonb;
  b bookings;
begin
  if app.manual_rental_insurer_billed(p) and nullif(p ->> 'renter_id', '') is null and nullif(r ->> 'date_of_birth', '') is null then
    if nullif(btrim(coalesce(r ->> 'full_name', '')), '') is null then
      raise exception 'Enter the renter''s full legal name' using errcode = '22023';
    end if;
    v_stand := true;
    p := jsonb_set(p, '{renter}', r || jsonb_build_object('date_of_birth', c_stand_in::text));
  end if;
  v_out := app.manual_rental_create_pre2510(p_by, p);
  if (v_out ->> 'booking_id') ~ '^[0-9a-f-]{36}$' then
    select * into b from bookings where id = (v_out ->> 'booking_id')::uuid;
    if v_stand then
      update booking_drivers set date_of_birth = null, age_at_pickup = null, age_band = null where booking_id = b.id and date_of_birth = c_stand_in;
      update drivers set date_of_birth = null where renter_id = b.renter_id and date_of_birth = c_stand_in;
      update renters set date_of_birth = null where id = b.renter_id and date_of_birth = c_stand_in;
    end if;
    if not app.manual_rental_insurer_billed(p) and exists (select 1 from booking_drivers d where d.booking_id = b.id and d.age_at_pickup is null) then
      raise exception 'Enter the renter''s full legal name and date of birth (only an insurer-billed rental may go without one)' using errcode = '22023';
    end if;
  end if;
  return v_out;
end $$;
select pg_temp.copy_grants('app.manual_rental_create(uuid, jsonb)'::regprocedure, 'app.manual_rental_create_pre2510(uuid, jsonb)'::regprocedure);

revoke all on function app.manual_rental_create_pre2510(uuid, jsonb) from public, anon, authenticated;
grant execute on function app.manual_rental_create_pre2510(uuid, jsonb) to service_role;
revoke all on function app.manual_rental_insurer_billed(jsonb) from public, anon, authenticated;
grant execute on function app.manual_rental_insurer_billed(jsonb) to service_role;
