-- 1302_r35a_secondary_contact.sql
-- Release 35, part A (helper A), task 6 (docs/changes/2026-11-11-r35a-request-offers.md). The owner: the renter may give an
-- optional secondary contact (name, phone and/or email, relationship) in their profile and on a booking; staff see it on the
-- booking and use it when the primary cannot be reached.
--   1. renters.secondary_contact (the profile's) and bookings.secondary_contact (one booking's own, when it differs). Each is
--      {name, phone, email, relationship, updated_at}: a name, a relationship and a phone or an email.
--   2. public.server_secondary_contact (read) and public.server_secondary_contact_save (the renter's own: the profile, a
--      booking of theirs, or both; an empty name removes it). Saving on a booking is logged on it.
--   3. app.booking_secondary_contact (ops_read secondary_contact, every staff function and an Admin): the booking's own, else
--      the profile's, with where it comes from.
-- No applied migration is edited.
set local check_function_bodies = off;

alter table renters add column secondary_contact jsonb;
alter table bookings add column secondary_contact jsonb;
comment on column renters.secondary_contact is 'The renter''s optional secondary contact (1302): {name, phone, email, relationship, updated_at}; staff use it when the renter cannot be reached.';
comment on column bookings.secondary_contact is 'A secondary contact for this booking only (1302), when it differs from the renter''s profile: {name, phone, email, relationship, updated_at}.';

create function app.secondary_contact_ok(p jsonb) returns boolean language sql immutable as $$
  select p is null or (jsonb_typeof(p) = 'object'
    and length(btrim(coalesce(p ->> 'name', ''))) between 2 and 120
    and length(btrim(coalesce(p ->> 'relationship', ''))) between 2 and 60
    and (coalesce(p ->> 'phone', '') ~ '^\+?[0-9 ().-]{7,24}$' or coalesce(p ->> 'email', '') ~* '^[^@\s]+@[^@\s]+\.[^@\s]+$')
    and (coalesce(p ->> 'phone', '') = '' or coalesce(p ->> 'phone', '') ~ '^\+?[0-9 ().-]{7,24}$')
    and (coalesce(p ->> 'email', '') = '' or coalesce(p ->> 'email', '') ~* '^[^@\s]+@[^@\s]+\.[^@\s]+$'))
$$;
alter table renters add constraint renters_secondary_contact_ok check (app.secondary_contact_ok(secondary_contact));
alter table bookings add constraint bookings_secondary_contact_ok check (app.secondary_contact_ok(secondary_contact));

-- the contact as typed, cleaned: null when the name is empty
create function app.secondary_contact_clean(p jsonb) returns jsonb language plpgsql immutable as $$
declare
  v_name text := btrim(coalesce(p ->> 'name', ''));
  v_rel text := btrim(coalesce(p ->> 'relationship', ''));
  v_phone text := nullif(btrim(coalesce(p ->> 'phone', '')), '');
  v_email text := nullif(lower(btrim(coalesce(p ->> 'email', ''))), '');
begin
  if v_name = '' then return null; end if;
  if length(v_name) < 2 then raise exception 'Type the secondary contact''s name' using errcode = '22023'; end if;
  if length(v_rel) < 2 then raise exception 'Say how they are related to you (for example spouse, parent, friend)' using errcode = '22023'; end if;
  if v_phone is null and v_email is null then raise exception 'Give a phone number or an email for your secondary contact' using errcode = '22023'; end if;
  if v_phone is not null and v_phone !~ '^\+?[0-9 ().-]{7,24}$' then raise exception 'That phone number does not look right' using errcode = '22023'; end if;
  if v_email is not null and v_email !~* '^[^@\s]+@[^@\s]+\.[^@\s]+$' then raise exception 'That email does not look right' using errcode = '22023'; end if;
  return jsonb_build_object('name', left(v_name, 120), 'relationship', left(v_rel, 60), 'phone', v_phone, 'email', v_email, 'updated_at', now());
end $$;

-- the booking's own, else the renter's profile's
create function app.booking_secondary_contact_of(p_booking uuid) returns jsonb
language sql stable security definer set search_path = public, app as $$
  select case when b.secondary_contact is not null then b.secondary_contact || jsonb_build_object('source', 'booking')
              when r.secondary_contact is not null then r.secondary_contact || jsonb_build_object('source', 'profile') end
    from bookings b left join renters r on r.id = b.renter_id where b.id = p_booking
$$;

-- staff: p {booking: id or number}
create function app.booking_secondary_contact(p_by uuid, p jsonb) returns jsonb
language plpgsql stable security definer set search_path = public, app as $$
declare v_id uuid;
begin
  if not app.user_is_staff(p_by) then raise exception 'Staff only' using errcode = '42501'; end if;
  select id into v_id from bookings where id::text = p ->> 'booking' or booking_number = upper(btrim(coalesce(p ->> 'booking', '')));
  if v_id is null then raise exception 'Booking not found' using errcode = 'P0002'; end if;
  return app.booking_secondary_contact_of(v_id);
end $$;

-- the renter: {profile, booking?}
create function public.server_secondary_contact(p_by uuid, p_booking uuid default null) returns jsonb
language plpgsql stable security definer set search_path = public, app as $$
begin
  if p_by is null then raise exception 'Sign in first' using errcode = '42501'; end if;
  if p_booking is not null and not app.is_booking_renter(p_booking, p_by) then raise exception 'Not permitted' using errcode = '42501'; end if;
  return jsonb_build_object('profile', (select r.secondary_contact from renters r where r.user_id = p_by order by r.created_at limit 1),
    'booking', case when p_booking is not null then (select b.secondary_contact from bookings b where b.id = p_booking) end);
end $$;

-- the renter saves: p {name, phone, email, relationship, booking?, scope: profile | booking | both}
create function public.server_secondary_contact_save(p_by uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  v_scope text := coalesce(nullif(p ->> 'scope', ''), case when nullif(p ->> 'booking', '') is null then 'profile' else 'booking' end);
  v_c jsonb := app.secondary_contact_clean(p);
  v_renter uuid;
  b bookings;
begin
  if p_by is null then raise exception 'Sign in first' using errcode = '42501'; end if;
  if v_scope not in ('profile', 'booking', 'both') then raise exception 'Save it on your profile, this booking or both' using errcode = '22023'; end if;
  select id into v_renter from renters where user_id = p_by order by created_at limit 1;
  if v_renter is null then raise exception 'Your profile is made with your first booking request' using errcode = 'P0002'; end if;
  if v_scope in ('booking', 'both') then
    select * into b from bookings where id::text = p ->> 'booking' or booking_number = upper(btrim(coalesce(p ->> 'booking', '')));
    if b.id is null or not app.is_booking_renter(b.id, p_by) then raise exception 'Not permitted' using errcode = '42501'; end if;
    if b.status::text in ('closed', 'cancelled', 'declined', 'expired') then raise exception 'This booking is %: nothing to change', replace(b.status::text, '_', ' ') using errcode = '23514'; end if;
    update bookings set secondary_contact = v_c where id = b.id;
    perform app.log_booking_event(b.id, 'secondary_contact', b.status::text, b.status::text, null,
      case when v_c is null then 'Secondary contact removed by the renter' else format('Secondary contact set by the renter: %s (%s)', v_c ->> 'name', v_c ->> 'relationship') end,
      p_by, 'renter', jsonb_build_object('secondary_contact', v_c));
  end if;
  if v_scope in ('profile', 'both') then
    update renters set secondary_contact = v_c where id = v_renter;
  end if;
  return jsonb_build_object('ok', true, 'scope', v_scope, 'contact', v_c);
end $$;

-- the booking's event kinds: + secondary_contact (and rideshare_docs, 1303)
do $$
declare
  v_name text;
  v_def text;
begin
  select conname, pg_get_constraintdef(oid) into v_name, v_def from pg_constraint
   where conrelid = 'booking_events'::regclass and contype = 'c' and pg_get_constraintdef(oid) like '%kind = ANY%';
  if v_def not like '%''secondary_contact''%' then
    v_def := regexp_replace(v_def, '\]\)+$', '');
    v_def := v_def || ', ''secondary_contact''::text, ''rideshare_docs''::text])))';
    execute format('alter table booking_events drop constraint %I', v_name);
    execute format('alter table booking_events add constraint %I %s', v_name, v_def);
  end if;
end $$;

do $$
declare f record;
begin
  for f in
    select p.oid::regprocedure as sig from pg_proc p join pg_namespace n on n.oid = p.pronamespace
     where (n.nspname = 'app' and p.proname = any (array['booking_secondary_contact_of', 'booking_secondary_contact']))
        or (n.nspname = 'public' and p.proname = any (array['server_secondary_contact', 'server_secondary_contact_save']))
  loop
    execute format('revoke all on function %s from public, anon, authenticated', f.sig);
    execute format('grant execute on function %s to service_role', f.sig);
  end loop;
end $$;
grant execute on function app.secondary_contact_ok(jsonb), app.secondary_contact_clean(jsonb) to authenticated, service_role;
