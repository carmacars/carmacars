-- 2310_r37_insurer_no_contact.sql (release 37)
-- Owner's rule (Nov 11): "For insurer billed rentals that don't block off the calendar should not require the renter to
-- have an account or phone number or email."
--   1. app.manual_rental_contactless(p): the one case, in one place: a rental added by hand that is billed to an insurer
--      (payment method insurer, an insurer named) AND does not block the calendar (blocks_calendar false), and is not
--      collected from the renter by payment link or card (those need an email). Everything else is exactly as before.
--   2. app.manual_rental_create wraps the Add a rental of 0283: in that case alone a NEW renter needs a full legal name and
--      date of birth (the driver details the agreement needs) and no email, phone or account: the renter row is made with
--      no user (renters.user_id was always nullable) and handed on by id. An email or phone typed is kept (the email
--      must still look like one). After the rental is made it is checked once more: billed to an insurer and not on the
--      calendar, or the whole call is refused (so no renter without contact is ever left on a booking that needs one).
--   3. app.renter_is_contactless(renter): no account, no email, no phone. A renter email or text for such a renter is
--      never queued: no notification_outbox row (and no empty-address row), no phone_outbox row, no error.
-- Statements, the insurer invoice and the owner statements read the booking and the insurer, not the renter's contact.

-- ================================================================ 1. who has no way to be reached
create or replace function app.renter_is_contactless(p_renter uuid) returns boolean
language sql stable security definer set search_path = public, app as $$
  select coalesce((select r.user_id is null and nullif(btrim(coalesce(r.email, '')), '') is null and nullif(btrim(coalesce(r.mobile, '')), '') is null
                     from renters r where r.id = p_renter), false)
$$;
comment on function app.renter_is_contactless(uuid) is 'A renter with no account, no email and no phone (2310: an insurer-billed rental that does not block the calendar). Nothing is sent to them.';

-- ================================================================ 2. the one case
create or replace function app.manual_rental_contactless(p jsonb) returns boolean
language sql stable set search_path = public, app as $$
  select coalesce(p #>> '{payment,method}' = 'insurer', false)
     and jsonb_typeof(p -> 'insurance') = 'object'
     and coalesce(nullif(p ->> 'blocks_calendar', '')::boolean, true) is false
     and coalesce(nullif(p #>> '{payment,mode}', ''), 'unpaid') not in ('link', 'card')
$$;
comment on function app.manual_rental_contactless(jsonb) is 'Add a rental (2310): billed to an insurer and not blocking the calendar, so the renter needs only a name (and the date of birth the agreement needs): no account, phone or email.';

alter function app.manual_rental_create(uuid, jsonb) rename to manual_rental_create_pre2310;
create function app.manual_rental_create(p_by uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  r jsonb := coalesce(p -> 'renter', '{}'::jsonb);
  v_name text := nullif(btrim(coalesce(r ->> 'full_name', '')), '');
  v_dob date;
  v_email text := lower(nullif(btrim(coalesce(r ->> 'email', '')), ''));
  v_mobile text := nullif(btrim(coalesce(r ->> 'mobile', '')), '');
  u users;
  rn renters;
  v_out jsonb;
  b bookings;
begin
  -- everything else is exactly as before: a renter on file, or any rental that is not billed to an insurer and off the calendar
  if not app.manual_rental_contactless(p) or nullif(p ->> 'renter_id', '') is not null then
    return app.manual_rental_create_pre2310(p_by, p);
  end if;
  if app.manual_rental_role(p_by) is null then raise exception 'Only an Admin, customer service or Sales adds a rental' using errcode = '42501'; end if;
  v_dob := nullif(r ->> 'date_of_birth', '')::date;
  if v_name is null or v_dob is null then raise exception 'Enter the renter''s full legal name and date of birth' using errcode = '22023'; end if;
  if v_email is not null and v_email !~ '^[^@\s]+@[^@\s]+\.[^@\s]+$' then
    raise exception 'The email address does not look right: correct it, or leave it empty (an insurer-billed rental needs no email)' using errcode = '22023';
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
    values (u.id, v_name, v_dob, v_mobile, v_email, nullif(btrim(r ->> 'address_line1'), ''), nullif(btrim(r ->> 'city'), ''),
            nullif(btrim(r ->> 'province'), ''), upper(nullif(btrim(r ->> 'postal_code'), '')))
    returning * into rn;
  end if;
  v_out := app.manual_rental_create_pre2310(p_by, p || jsonb_build_object('renter_id', rn.id));
  -- a renter with no way to be reached stays only on a rental that is billed to an insurer and off the calendar (a past rental,
  -- already over, holds no dates)
  if app.renter_is_contactless(rn.id) and (v_out ->> 'booking_id') ~ '^[0-9a-f-]{36}$' then
    select * into b from bookings where id = (v_out ->> 'booking_id')::uuid;
    if b.bill_to is distinct from 'insurer' or (b.blocks_calendar and b.status in ('requested', 'offered', 'pending_payment', 'confirmed', 'on_rent')) then
      raise exception 'Without an email or phone the rental must be billed to an insurer and not block the calendar: enter the renter''s email and phone' using errcode = '22023';
    end if;
  end if;
  return v_out;
end $$;

-- ================================================================ 3. nothing is sent to a renter with no way to be reached
-- an email: no row at all (the event processor used to write a "skipped: no email address" row with an empty address)
create or replace function app.outbox_no_contact_renter() returns trigger
language plpgsql security definer set search_path = public, app as $$
begin
  if new.audience = 'renter' and nullif(btrim(coalesce(new.to_address, '')), '') is null and new.recipient_user_id is null
     and app.renter_is_contactless(new.renter_id) then
    return null;
  end if;
  return new;
end $$;
drop trigger if exists a_outbox_no_contact_renter on notification_outbox;
create trigger a_outbox_no_contact_renter before insert on notification_outbox for each row execute function app.outbox_no_contact_renter();

-- a text: the same (the number is empty, the renter has none)
alter function app.phone_outbox_put(text, text, text, uuid, uuid, text, uuid, text, timestamptz, text, uuid) rename to phone_outbox_put_pre2310;
create function app.phone_outbox_put(p_number text, p_body text, p_kind text, p_booking uuid default null, p_renter uuid default null, p_sms_kind text default null,
                                     p_notification uuid default null, p_dedupe text default null, p_send_after timestamptz default now(), p_status text default 'queued',
                                     p_by uuid default null) returns phone_outbox
language plpgsql security definer set search_path = public, app as $$
begin
  if nullif(btrim(coalesce(p_number, '')), '') is null and (p_renter is null or app.renter_is_contactless(p_renter)) then
    return null;
  end if;
  return app.phone_outbox_put_pre2310(p_number, p_body, p_kind, p_booking, p_renter, p_sms_kind, p_notification, p_dedupe, p_send_after, p_status, p_by);
end $$;

-- ================================================================ privileges: a wrapper keeps the grants of the function it wraps
do $$
declare
  pair text[];
  g text;
begin
  foreach pair slice 1 in array array[
      array['app.manual_rental_create(uuid, jsonb)', 'app.manual_rental_create_pre2310(uuid, jsonb)'],
      array['app.phone_outbox_put(text, text, text, uuid, uuid, text, uuid, text, timestamptz, text, uuid)', 'app.phone_outbox_put_pre2310(text, text, text, uuid, uuid, text, uuid, text, timestamptz, text, uuid)']] loop
    execute format('revoke all on function %s from public, anon, authenticated', pair[1]);
    foreach g in array array['anon', 'authenticated', 'service_role'] loop
      if has_function_privilege(g, pair[2]::regprocedure, 'execute') then execute format('grant execute on function %s to %I', pair[1], g); end if;
    end loop;
    execute format('revoke all on function %s from public, anon, authenticated', pair[2]);
    execute format('grant execute on function %s to service_role', pair[2]);
  end loop;
end $$;
revoke all on function app.renter_is_contactless(uuid), app.manual_rental_contactless(jsonb), app.outbox_no_contact_renter() from public, anon, authenticated;
grant execute on function app.renter_is_contactless(uuid), app.manual_rental_contactless(jsonb), app.outbox_no_contact_renter() to service_role;
