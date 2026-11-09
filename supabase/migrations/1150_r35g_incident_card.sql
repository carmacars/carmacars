-- 1150_r35g_incident_card.sql
-- Release 35, part G (helper G), task A: the incident card. The owner: "a printable incident card to put in every single
-- vehicle that has instructions on what to show (each of the 3 coverage options), our insurance slip, and a scannable QR code
-- that takes you to the renter portal that shows the digital incident card (the valid coverage of that booking, the booking
-- details and the rental contract)". Then: ONE generic printed card, the same for every car (no car, plate, VIN, renter or
-- booking on it), with ONE QR code to the fixed page /incident.
--   1. The printed card (app.incident_cards, 0813) is unchanged in the database: the page now prints the one generic card
--      (steps, the three coverage options with what to show, the fleet slip, the numbers, the QR to /incident).
--   2. The digital card (/incident, sign-in first): app.incident_digital lists the signed-in person's bookings in progress
--      where they are the renter or a driver named on the booking (booking_drivers -> drivers.user_id), and for the chosen
--      one (or the only one) the booking's accident card (0910: the valid coverage option and its proof), the car, plate,
--      dates, booking number, the drivers, and the rental agreement document. Nobody else's booking is ever returned; with
--      no booking in progress the page shows the generic steps and numbers only (company block, no booking data).
--   3. public.server_incident_document: the agreement or the coverage proof of such a booking, for a driver of it (the
--      renter's /account/documents link only serves the account holder; an additional driver reads it here).
--   4. Report a problem from the digital card: an additional driver named on the booking may report the accident and add
--      photos as the renter does (0912 accepted the account holder only).
-- In progress: on rent, or confirmed with the pickup within 12 hours and the return not passed.
-- No applied migration is edited; 0912's three functions are patched in place (pg_temp.patch_fn).
set local check_function_bodies = off;

create function pg_temp.patch_fn(p_sig regprocedure, p_old text, p_new text) returns void
language plpgsql as $$
declare d text := pg_get_functiondef(p_sig);
begin
  if position(p_old in d) = 0 then raise exception '1150: the text to change was not found in %: %', p_sig, left(p_old, 120); end if;
  execute replace(d, p_old, p_new);
end $$;

-- the account holder of the booking, or a driver named on it with this login
create function app.is_booking_party(p_booking uuid, p_user uuid) returns boolean
language sql stable security definer set search_path = public, app as $$
  select p_user is not null and (app.is_booking_renter(p_booking, p_user)
    or exists (select 1 from booking_drivers bd join drivers d on d.id = bd.driver_id where bd.booking_id = p_booking and d.user_id = p_user))
$$;
comment on function app.is_booking_party(uuid, uuid) is 'The renter (account holder) of the booking or a driver named on it whose driver record has this login (1150).';

create function app.booking_in_progress(b bookings, p_now timestamptz default now()) returns boolean
language sql stable set search_path = public, app as $$
  select b.status::text = 'on_rent' or (b.status::text = 'confirmed' and b.pickup_at <= p_now + interval '12 hours' and b.return_at > p_now)
$$;

-- the rental agreement of a booking: the signed copy first, else the newest
create function app.booking_contract_document(p_booking uuid) returns uuid
language sql stable security definer set search_path = public, app as $$
  select coalesce(
    (select d.id from documents d where d.booking_id = p_booking and d.kind = 'rental_agreement' and d.purged_at is null and d.storage_path is not null
      order by (coalesce(d.title, '') ilike 'signed%') desc, d.created_at desc limit 1),
    (select d.id from bookings b join documents d on d.id = b.agreement_document_id where b.id = p_booking and d.purged_at is null and d.storage_path is not null))
$$;

-- p {booking?}: the person's bookings in progress, and the digital card of the chosen one (or of the only one)
create function app.incident_digital(p_by uuid, p jsonb default '{}'::jsonb) returns jsonb
language plpgsql stable security definer set search_path = public, app as $$
declare
  s program_settings := app.settings();
  ss site_settings;
  v_list jsonb;
  v_pick text := upper(btrim(coalesce(p ->> 'booking', '')));
  b bookings;
  v_card jsonb;
  v_contract uuid;
begin
  if p_by is null then raise exception 'Sign in first' using errcode = '42501'; end if;
  select * into ss from site_settings limit 1;
  select coalesce(jsonb_agg(jsonb_build_object('booking_number', x.booking_number, 'pickup_at', x.pickup_at, 'return_at', x.return_at, 'status', x.status,
           'car', app.vehicle_name(x.vehicle_id), 'plate', (select v.plate from vehicles v where v.id = x.vehicle_id),
           'role', case when app.is_booking_renter(x.id, p_by) then 'renter' else 'driver' end) order by x.pickup_at), '[]'::jsonb)
    into v_list
    from bookings x where app.booking_in_progress(x) and coalesce(x.booking_type::text, '') <> 'owner' and app.is_booking_party(x.id, p_by);
  if jsonb_array_length(v_list) = 1 and v_pick = '' then v_pick := v_list -> 0 ->> 'booking_number'; end if;
  if v_pick <> '' then
    select * into b from bookings x where x.booking_number = v_pick and app.booking_in_progress(x) and coalesce(x.booking_type::text, '') <> 'owner' and app.is_booking_party(x.id, p_by);
  end if;
  if b.id is not null then
    v_contract := app.booking_contract_document(b.id);
    v_card := app.accident_card(b.id) || jsonb_build_object(
      'status', b.status, 'role', case when app.is_booking_renter(b.id, p_by) then 'renter' else 'driver' end,
      'drivers', coalesce((select jsonb_agg(jsonb_build_object('name', bd.full_name, 'role', bd.role) order by (bd.role = 'renter') desc, bd.full_name)
                             from booking_drivers bd where bd.booking_id = b.id), '[]'::jsonb),
      'contract', case when v_contract is null then null else (select jsonb_build_object('document_id', d.id, 'title', coalesce(d.title, 'Rental agreement'), 'created_at', d.created_at)
                                                                 from documents d where d.id = v_contract) end,
      'proof', (select jsonb_build_object('document_id', d.id, 'mime', d.mime_type) from documents d
                 where d.id = nullif(app.accident_card(b.id) -> 'coverage' ->> 'proof_document_id', '')::uuid and d.purged_at is null and d.storage_path is not null));
  end if;
  return jsonb_build_object(
    'company', jsonb_build_object('trade_name', s.company_trade_name, 'support_phone', coalesce(ss.phone_display, s.company_phone),
                'roadside_phone', coalesce(ss.roadside_phone_display, s.incident_line_phone), 'incident_line', coalesce(ss.roadside_phone_display, s.incident_line_phone)),
    'bookings', v_list,
    'card', v_card);
end $$;
comment on function app.incident_digital(uuid, jsonb) is 'The digital incident card (/incident, 1150): the signed-in person''s bookings in progress as renter or named driver, and the card of the chosen one. Never another person''s booking.';

create function public.server_incident_digital(p_by uuid, p jsonb default '{}'::jsonb) returns jsonb
language sql stable security definer set search_path = public, app as $$ select app.incident_digital(p_by, p) $$;

-- the agreement or the coverage proof of a booking in progress, for its renter or a named driver; null otherwise
create function public.server_incident_document(p_by uuid, p_document uuid) returns jsonb
language plpgsql stable security definer set search_path = public, app as $$
declare
  d documents;
  b bookings;
begin
  if p_by is null or p_document is null then return null; end if;
  select * into d from documents where id = p_document and purged_at is null and storage_path is not null;
  if d.id is null then return null; end if;
  for b in select x.* from bookings x where app.booking_in_progress(x) and app.is_booking_party(x.id, p_by) loop
    if d.id = app.booking_contract_document(b.id)
       or d.id = nullif(app.accident_card(b.id) -> 'coverage' ->> 'proof_document_id', '')::uuid then
      return jsonb_build_object('bucket', d.storage_bucket, 'path', d.storage_path, 'title', coalesce(d.title, d.kind::text), 'kind', d.kind, 'mime_type', d.mime_type);
    end if;
  end loop;
  return null;
end $$;

-- ================================================================ 4. a named driver reports the accident too
select pg_temp.patch_fn('app.renter_accident_report(uuid, jsonb)'::regprocedure,
  'not app.is_booking_renter(b.id, p_by)', 'not app.is_booking_party(b.id, p_by)');
select pg_temp.patch_fn('app.renter_accident_media(uuid, jsonb)'::regprocedure,
  'not app.is_booking_renter(i.booking_id, p_by)', 'not app.is_booking_party(i.booking_id, p_by)');
select pg_temp.patch_fn('public.server_renter_accidents(uuid, uuid)'::regprocedure,
  'perform app.assert_booking_renter(p_booking, p_by);',
  'if not app.is_booking_party(p_booking, p_by) then raise exception ''Not permitted'' using errcode = ''42501''; end if;');

-- ================================================================ privileges: the server only
do $$
declare f record;
begin
  for f in select p.oid::regprocedure as sig from pg_proc p join pg_namespace n on n.oid = p.pronamespace
            where (n.nspname = 'app' and p.proname = any (array['is_booking_party', 'booking_in_progress', 'booking_contract_document', 'incident_digital',
                     'renter_accident_report', 'renter_accident_media']))
               or (n.nspname = 'public' and p.proname = any (array['server_incident_digital', 'server_incident_document', 'server_renter_accidents']))
  loop
    execute format('revoke all on function %s from public, anon, authenticated', f.sig);
    execute format('grant execute on function %s to service_role', f.sig);
  end loop;
end $$;
