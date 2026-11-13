-- 2740_r43_owner_km.sql (release 43)
-- A. The owner sees each car's current kilometres (the latest odometer reading of the maintenance tracker, 0089) with its date,
--    and the next service (item, km left or date, status) on the owner dashboard and the car page. Read only: the existing owner
--    read (ops_read maint_owner, own cars only) carries two more keys: km, km_on, next. No new table or read.
-- B. Add a rental by hand: the renter's email is optional when the rental already ended, is billed to an insurer, or "Do not
--    email the renter" is ticked. Upcoming and not billed to an insurer still needs a phone or an email. A new renter without an
--    email is kept without an account; a payment link still needs the email; the agreement is e-signed in the portal, so a task
--    asks staff to add the email (nothing is sent until then).
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
  if position(p_old in d) = 0 then raise exception '2740: the text to change was not found in %: %', p_sig, left(p_old, 160); end if;
  execute replace(d, p_old, p_new);
end $$;

-- ================================================================ A. the owner's kilometres and next service
select pg_temp.patch_fn('app.maint_owner_history(uuid)'::regprocedure,
$old$  return jsonb_build_object(
    'items',$old$,
$new$  return jsonb_build_object(
    'km', app.maint_current_km(p_vehicle),
    'km_on', (select app.local_date(x.read_at) from vehicle_odometer_readings x
               where x.vehicle_id = p_vehicle and x.voided_at is null and x.km = app.maint_current_km(p_vehicle) order by x.read_at desc limit 1),
    'next', (select jsonb_build_object('label', i.label, 'status', vi.status,
                    'km_left', case when vi.next_due_km is not null then vi.next_due_km - coalesce(app.maint_current_km(p_vehicle), 0) end,
                    'due_on', coalesce(vi.next_due_on, vi.projected_due_on))
               from vehicle_service_items vi join service_items i on i.code = vi.item_code
              where vi.vehicle_id = p_vehicle and vi.status in ('ok', 'due_soon', 'overdue') and (vi.next_due_km is not null or vi.next_due_on is not null)
              order by app.maint_status_rank(vi.status), coalesce(vi.projected_due_on, vi.next_due_on) nulls last,
                       vi.next_due_km - coalesce(app.maint_current_km(p_vehicle), 0) nulls last, i.sort_order
              limit 1),
    'items',$new$);

-- ================================================================ B. Add a rental: the renter's email is optional
create function app.manual_rental_email_optional(p jsonb) returns boolean
language sql stable set search_path = public, app as $$
  select app.manual_rental_insurer_billed(p)
      or coalesce(nullif(p ->> 'do_not_email', '')::boolean, false)
      or app.manual_rental_phase((p ->> 'pickup_at')::timestamptz, (p ->> 'return_at')::timestamptz) = 'past'
$$;
comment on function app.manual_rental_email_optional(jsonb) is 'Add a rental (2740): the renter''s email is optional when the rental already ended, is billed to an insurer, or "Do not email the renter" is ticked.';

alter function app.manual_rental_create(uuid, jsonb) rename to manual_rental_create_pre2740;
create function app.manual_rental_create(p_by uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  c_stand_in constant date := date '1900-01-01';
  r jsonb := coalesce(p -> 'renter', '{}'::jsonb);
  v_name text := nullif(btrim(coalesce(r ->> 'full_name', '')), '');
  v_email text := lower(nullif(btrim(coalesce(r ->> 'email', '')), ''));
  v_mobile text := nullif(btrim(coalesce(r ->> 'mobile', '')), '');
  v_dob date := nullif(r ->> 'date_of_birth', '')::date;
  v_phase text := app.manual_rental_phase((p ->> 'pickup_at')::timestamptz, (p ->> 'return_at')::timestamptz);
  v_mode text := coalesce(nullif(p #>> '{payment,mode}', ''), 'unpaid');
  v_ins boolean := app.manual_rental_insurer_billed(p);
  u users;
  rn renters;
  v_out jsonb;
  v_id uuid;
  b bookings;
begin
  if nullif(p ->> 'renter_id', '') is not null then
    -- a renter on file: a payment link still goes by email
    if v_mode = 'link' and not exists (select 1 from renters x left join users us on us.id = x.user_id
                                        where x.id = (p ->> 'renter_id')::uuid and nullif(btrim(coalesce(x.email, us.email, '')), '') is not null) then
      raise exception 'A payment link is sent by email: add the renter''s email address first, or record the payment another way' using errcode = '22023';
    end if;
    v_out := app.manual_rental_create_pre2740(p_by, p);
  elsif not app.manual_rental_email_optional(p) or (v_email is not null and v_mobile is not null) then
    return app.manual_rental_create_pre2740(p_by, p);
  else
    if app.manual_rental_role(p_by) is null then raise exception 'Only an Admin, customer service or Sales adds a rental' using errcode = '42501'; end if;
    if v_name is null then raise exception 'Enter the renter''s full legal name' using errcode = '22023'; end if;
    if v_dob is null and not v_ins then raise exception 'Enter the renter''s full legal name and date of birth' using errcode = '22023'; end if;
    if v_email is not null and v_email !~ '^[^@\s]+@[^@\s]+\.[^@\s]+$' then
      raise exception 'The email address does not look right: correct it, or leave it empty' using errcode = '22023';
    end if;
    if v_email is null and v_mobile is null and not v_ins and v_phase is distinct from 'past' then
      raise exception 'Enter the renter''s email address or phone number (one of the two is needed for a rental that is coming up)' using errcode = '22023';
    end if;
    if v_email is null and v_mode in ('link', 'card') then
      raise exception 'A payment link is sent by email: enter the renter''s email address, or record the payment another way' using errcode = '22023';
    end if;
    if v_email is not null then
      select * into u from users where lower(email) = v_email;
      if u.id is null then
        insert into users (email, phone, full_name) values (v_email, v_mobile, v_name) returning * into u;
      end if;
      insert into user_roles (user_id, role) values (u.id, 'renter') on conflict do nothing;
      select * into rn from renters where user_id = u.id;
    end if;
    if rn.id is null then
      insert into renters (user_id, legal_name, date_of_birth, mobile, email, address_line1, city, province, postal_code)
      values (u.id, v_name, coalesce(v_dob, c_stand_in), v_mobile, v_email, nullif(btrim(r ->> 'address_line1'), ''), nullif(btrim(r ->> 'city'), ''),
              nullif(btrim(r ->> 'province'), ''), upper(nullif(btrim(r ->> 'postal_code'), '')))
      returning * into rn;
    end if;
    v_out := app.manual_rental_create_pre2740(p_by, p || jsonb_build_object('renter_id', rn.id));
    if v_dob is null and rn.date_of_birth = c_stand_in then
      v_id := nullif(v_out ->> 'booking_id', '')::uuid;
      update booking_drivers set date_of_birth = null, age_at_pickup = null, age_band = null where booking_id = v_id and date_of_birth = c_stand_in;
      update drivers set date_of_birth = null where renter_id = rn.id and date_of_birth = c_stand_in;
      update renters set date_of_birth = null where id = rn.id and date_of_birth = c_stand_in;
    end if;
  end if;
  -- a renter without an email, on a rental not yet over: the agreement (e-signed in the portal) waits until an email is added
  if (v_out ->> 'booking_id') ~ '^[0-9a-f-]{36}$' and v_phase is distinct from 'past' then
    select * into b from bookings where id = (v_out ->> 'booking_id')::uuid;
    if b.id is not null and not app.renter_is_contactless(b.renter_id)
       and not exists (select 1 from renters x left join users us on us.id = x.user_id where x.id = b.renter_id and nullif(btrim(coalesce(x.email, us.email, '')), '') is not null) then
      perform app.raise_task(p_type => 'renter_email_needed', p_queue => 'cs', p_priority => 'normal',
        p_title => format('Add the renter''s email so the agreement can be sent: %s', b.booking_number),
        p_detail => 'The rental was added without an email address. The agreement is signed online, so nothing is sent until the renter''s email is added (Renters, the renter).',
        p_booking => b.id, p_vehicle => b.vehicle_id, p_renter => b.renter_id, p_created_by => p_by, p_dedupe => 'renter_email_needed:' || b.id);
    end if;
  end if;
  return v_out;
end $$;
select pg_temp.copy_grants('app.manual_rental_create(uuid, jsonb)'::regprocedure, 'app.manual_rental_create_pre2740(uuid, jsonb)'::regprocedure);

revoke all on function app.manual_rental_create_pre2740(uuid, jsonb) from public, anon, authenticated;
grant execute on function app.manual_rental_create_pre2740(uuid, jsonb) to service_role;
revoke all on function app.manual_rental_email_optional(jsonb) from public, anon, authenticated;
grant execute on function app.manual_rental_email_optional(jsonb) to service_role;
