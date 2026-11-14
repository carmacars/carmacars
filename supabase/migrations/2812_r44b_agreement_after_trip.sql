-- 2812 (release 44, part B): an Admin makes a signable agreement for a rental that has already ended.
-- Insurers' files need a signed agreement, also for a rental recorded after the fact. "Make the agreements again" and
-- "Sign on this device" did nothing on a returned or closed booking: no agreement is opened for a booking past its
-- pickup (app.open_rental_agreement served only an approved offer or a rental added live), and the version job only
-- re-renders an agreement that exists, so the sign-now page said nothing was waiting.
--   * bookings.agreement_after_trip_at / _by: an Admin asked for it (Make the agreements again, or Prepare the agreement
--     on Sign on this device). Only an Admin, only a returned or closed booking that is not an owner's, and never over an
--     agreement already signed.
--   * Such a booking's agreement is opened as a rental added by hand is (0072): opened by staff (the renter may have no
--     account: an insurer-billed rental often has none), the renter and the drivers sign (in person or by their link),
--     and CarmaCars countersigns at once.
--   * Its facts say after_trip: a detail not on file prints blank, never "To be given before pickup" (model.ts).
-- No applied migration is edited: function bodies are patched in place, or wrapped.

create function pg_temp.patch_fn(p_sig regprocedure, p_old text, p_new text) returns void
language plpgsql as $$
declare d text := pg_get_functiondef(p_sig);
begin
  if position(p_old in d) = 0 then raise exception '2812: the text to change was not found in %: %', p_sig, left(p_old, 160); end if;
  execute replace(d, p_old, p_new);
end $$;
create function pg_temp.copy_grants(p_new regprocedure, p_old regprocedure) returns void
language plpgsql as $$
declare g text;
begin
  execute format('revoke all on function %s from public, anon, authenticated', p_new);
  foreach g in array array['anon', 'authenticated', 'service_role'] loop
    if has_function_privilege(g, p_old, 'execute') then execute format('grant execute on function %s to %I', p_new, g); end if;
  end loop;
end $$;

alter table bookings
  add column if not exists agreement_after_trip_at timestamptz,
  add column if not exists agreement_after_trip_by uuid references users (id) on delete set null;
create index if not exists bookings_agreement_after_trip_by_idx on bookings (agreement_after_trip_by) where agreement_after_trip_by is not null;
comment on column bookings.agreement_after_trip_at is 'r44 (2812): an Admin asked for a signable agreement after the rental ended (an insurer''s file): it is opened and signed as a rental added by hand is.';

create function app.booking_after_trip(b bookings) returns boolean
language sql stable security definer set search_path = public, app as $$
  select coalesce(b.agreement_after_trip_at is not null and b.status::text in ('returned', 'closed') and b.booking_type <> 'owner', false)
$$;

-- An Admin asks for it. Returns ready (an agreement is open or signed already) or the booking to open it for.
create function app.agreement_after_trip_start(p_by uuid, p_booking uuid) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  b bookings;
  a rental_agreements;
begin
  if not app.user_is_admin(p_by) then raise exception 'An Admin makes the agreement of a rental that has ended' using errcode = '42501'; end if;
  select * into b from bookings where id = p_booking for update;
  if b.id is null then raise exception 'Booking not found' using errcode = 'P0002'; end if;
  if b.booking_type = 'owner' then raise exception 'An owner using their own car signs no rental agreement' using errcode = '23514'; end if;
  if b.status::text not in ('returned', 'closed') then
    raise exception 'Booking % is %: this is for a rental that has ended', b.booking_number, replace(b.status::text, '_', ' ') using errcode = '23514';
  end if;
  select * into a from rental_agreements where booking_id = b.id and status in ('open', 'signed', 'completed') order by opened_at desc limit 1;
  if a.status in ('signed', 'completed') then return jsonb_build_object('ready', true, 'signed', true, 'booking_id', b.id); end if;
  if b.agreement_after_trip_at is null then
    update bookings set agreement_after_trip_at = now(), agreement_after_trip_by = p_by where id = b.id;
    perform app.log_booking_event(b.id, 'adjusted', b.status::text, b.status::text, null,
      'An Admin made the rental agreement to sign after the rental (for the insurer''s file)', p_by, 'staff', jsonb_build_object('agreement_after_trip', true));
  end if;
  return jsonb_build_object('ready', a.id is not null, 'booking_id', b.id);
end $$;

-- the agreement is opened as for a rental added by hand ...
select pg_temp.patch_fn('app.open_rental_agreement(uuid, uuid, text, text, text, text)'::regprocedure,
  $o$  if b.id is null or not app.booking_added_live(b) then$o$,
  $n$  if b.id is null or not (app.booking_added_live(b) or app.booking_after_trip(b)) then$n$);
-- ... the renter's signature is recorded so, and CarmaCars countersigns at once
select pg_temp.patch_fn('app.record_signature_pre0154(uuid, uuid, text, text, inet, text, text, text, jsonb)'::regprocedure,
  $o$app.booking_added_live(b) or app.booking_paid_unsigned(b)$o$,
  $n$app.booking_added_live(b) or app.booking_paid_unsigned(b) or app.booking_after_trip(b)$n$);
select pg_temp.patch_fn('app.manual_agreement_complete_pre0074(uuid)'::regprocedure,
  $o$  if a.id is null or not (b.added_by_staff or app.booking_paid_unsigned(b)) then return null; end if;$o$,
  $n$  if a.id is null or not (b.added_by_staff or app.booking_paid_unsigned(b) or app.booking_after_trip(b)) then return null; end if;$n$);

-- Staff open it (the renter may have no account); the server renders the document as for the renter.
create function public.server_agreement_open_staff(p_booking uuid, p_by uuid, p_template_version text, p_document_sha256 text, p_storage_path text) returns uuid
language plpgsql security definer set search_path = public, app as $$
begin
  if p_by is null or not app.user_is_staff(p_by) then raise exception 'Staff only' using errcode = '42501'; end if;
  return app.open_rental_agreement(p_booking, p_by, p_template_version, p_document_sha256, p_storage_path, 'agreements');
end $$;

-- Sign on this device: an ended rental the Admin asked for is prepared too; a renter with no account no longer stops it
-- (staff make the agreement)
create or replace function public.server_sign_now_prepare(p_booking uuid, p_by uuid) returns jsonb
language plpgsql stable security definer set search_path = public, app as $$
declare
  b bookings;
  v_user uuid;
  v_after boolean;
begin
  if not (app.user_is_admin(p_by) or app.user_is_staff(p_by) or coalesce(app.user_is_field(p_by), false)) then raise exception 'Only staff collect signatures in person' using errcode = '42501'; end if;
  select * into b from bookings where id = p_booking;
  if b.id is null then raise exception 'Booking not found' using errcode = 'P0002'; end if;
  if b.booking_type = 'owner' then raise exception 'An owner using their own car signs no rental agreement' using errcode = '23514'; end if;
  v_after := b.status::text in ('returned', 'closed');
  if v_after and not app.user_is_admin(p_by) then
    raise exception 'Booking % has ended: an Admin makes its agreement to sign (for an insurer''s file)', b.booking_number using errcode = '42501';
  end if;
  if not v_after and b.status::text not in ('pending_payment', 'confirmed', 'on_rent') then
    raise exception 'Booking % is %: an agreement is signed once the offer is approved or the rental is added', b.booking_number, replace(b.status::text, '_', ' ') using errcode = '23514';
  end if;
  if exists (select 1 from rental_agreements a where a.booking_id = b.id and a.status in ('open', 'signed', 'completed')) then
    return jsonb_build_object('ready', true);
  end if;
  select r.user_id into v_user from renters r where r.id = b.renter_id;
  return jsonb_build_object('ready', false, 'renter_user_id', v_user, 'after_trip', v_after, 'as_staff', v_after or v_user is null);
end $$;

-- the facts say after_trip
alter function public.server_agreement_facts(uuid, uuid) rename to server_agreement_facts_pre2812;
create function public.server_agreement_facts(p_booking uuid, p_by uuid) returns jsonb
language plpgsql stable security definer set search_path = public, app as $$
declare
  f jsonb := public.server_agreement_facts_pre2812(p_booking, p_by);
begin
  if jsonb_typeof(f -> 'booking') <> 'object' then return f; end if;
  return jsonb_set(f, '{booking,after_trip}', to_jsonb(coalesce((select app.booking_after_trip(b) from bookings b where b.id = p_booking), false)));
end $$;
select pg_temp.copy_grants('public.server_agreement_facts(uuid, uuid)'::regprocedure, 'public.server_agreement_facts_pre2812(uuid, uuid)'::regprocedure);

revoke all on function app.booking_after_trip(bookings), app.agreement_after_trip_start(uuid, uuid), public.server_agreement_open_staff(uuid, uuid, text, text, text),
  public.server_agreement_facts_pre2812(uuid, uuid) from public, anon, authenticated;
grant execute on function app.booking_after_trip(bookings), app.agreement_after_trip_start(uuid, uuid), public.server_agreement_open_staff(uuid, uuid, text, text, text),
  public.server_agreement_facts_pre2812(uuid, uuid) to service_role;
