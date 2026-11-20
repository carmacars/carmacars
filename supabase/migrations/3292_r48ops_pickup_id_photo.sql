-- 3292 (release 48, operations screens): the photos of the pickup identity check.
-- The owner (Nov 20): at the pickup, confirm that the person taking the car is the renter. Field staff (the handover
-- checklist) photograph the licence the person in front of them is holding; the renter at a self check-in photographs
-- their licence and takes a selfie at that moment. Always offered, never required, never stops the check-in.
-- This migration keeps the photos; 3293 keeps the check made with them and raises the flag.
--
-- Why not the usual licence upload: app.register_verification_upload replaces the approved image, sets the identity check
-- back to pending and clears booking_drivers.identity_verified_on, which would stop the very handover it is taken at. So:
--   1. Three more kinds of verification_uploads, licence_front_pickup, licence_back_pickup and selfie_pickup, and one
--      more status, at_pickup: a photo taken at the pickup, kept as evidence. Nothing that decides identity reads them:
--      every existing rule names the kinds (licence_front, licence_back, selfie) and the statuses (submitted, approved)
--      it works on. Not waiting for review, not counted as waiting, not approved by "Approve all".
--   2. app.checkin_id_photo_register(p_by, {booking, driver?, side: front|back|selfie, path, sha256, mime}): the staff who
--      may hand the car over, or the booking's own renter; the booking confirmed or on rent; the driver on the booking
--      (the renter when none is named). The document is kept as the other ID images are (id_face_90d, purged with them).
--      An earlier pickup photo of the same side is marked replaced. The identity check on file, the readiness and the
--      handover are untouched. public.server_checkin_id_photo: the same, for the server (service role only).
--   3. Where staff review IDs (doc_review for Admin, customer service and Sales; va_read verification; field_read
--      licence_review): the pickup photos are listed with the other uploads, opened with View (app.doc_view, logged),
--      so they sit side by side with the licence and selfie on file.
--   4. The dispute pack's licence images include them (server_dispute_evidence).
-- SCHEMA_MARKER 3292. docs/changes/2026-11-20-r48-ops-screens.md.
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

-- ================================================================ 1. the kinds and the status
alter table verification_uploads drop constraint verification_uploads_kind_check;
alter table verification_uploads add constraint verification_uploads_kind_check
  check (kind in ('licence_front', 'licence_back', 'selfie', 'coverage_proof', 'licence_front_pickup', 'licence_back_pickup', 'selfie_pickup'));
alter table verification_uploads drop constraint verification_uploads_status_check;
alter table verification_uploads add constraint verification_uploads_status_check
  check (status in ('submitted', 'approved', 'rejected', 'replaced', 'at_pickup'));
-- a pickup photo only ever has the pickup status, and the pickup status is only ever on a pickup photo
alter table verification_uploads add constraint verification_uploads_pickup_status
  check ((kind in ('licence_front_pickup', 'licence_back_pickup', 'selfie_pickup')) = (status = 'at_pickup') or status = 'replaced');

-- ================================================================ 2. keeping the photo
create function app.checkin_id_photo_register(p_by uuid, p jsonb) returns uuid
language plpgsql security definer set search_path = public, app as $$
declare
  b bookings;
  v_side text := p ->> 'side';
  v_kind text;
  v_driver uuid := case when coalesce(p ->> 'driver', '') ~ '^[0-9a-f-]{36}$' then (p ->> 'driver')::uuid end;
  v_name text;
  v_staff boolean;
  v_doc uuid;
  v_id uuid;
begin
  select * into b from bookings where id = case when coalesce(p ->> 'booking', '') ~ '^[0-9a-f-]{36}$' then (p ->> 'booking')::uuid end;
  if b.id is null then raise exception 'Booking not found' using errcode = 'P0002'; end if;
  v_staff := app.user_may_handover(p_by);
  if p_by is null or not (v_staff or app.is_booking_renter(b.id, p_by)) then
    raise exception 'Only the staff handing the car over, or the renter of this booking, add the ID photo' using errcode = '42501';
  end if;
  if v_side is null or v_side not in ('front', 'back', 'selfie') then raise exception 'The photo is of the front or the back of the licence, or a selfie' using errcode = '22023'; end if;
  if b.status not in ('confirmed', 'on_rent') then
    raise exception 'The ID photo is taken at the pickup: booking % is %', b.booking_number, b.status using errcode = '23514';
  end if;
  if nullif(btrim(coalesce(p ->> 'path', '')), '') is null then raise exception 'A photo needs the key of its file in private storage' using errcode = '22023'; end if;
  -- the driver: the one named, else the renter of the booking; a renter adds their own only
  if v_driver is null or not v_staff then
    select x.driver_id into v_driver from booking_drivers x where x.booking_id = b.id and x.role = 'renter' order by x.driver_id limit 1;
  end if;
  select x.full_name into v_name from booking_drivers x where x.booking_id = b.id and x.driver_id = v_driver;
  if v_name is null then raise exception 'That driver is not on this booking' using errcode = '23514'; end if;
  v_kind := case v_side when 'selfie' then 'selfie_pickup' else 'licence_' || v_side || '_pickup' end;

  insert into documents (kind, title, storage_bucket, storage_path, mime_type, sha256, retention, purge_after, uploaded_by, renter_id, booking_id)
  values (case v_side when 'front' then 'id_front' when 'back' then 'id_back' else 'face_photo' end::document_kind,
          case v_side when 'selfie' then 'Selfie at pickup: ' else 'Licence at pickup, ' || v_side || ': ' end || v_name, 'identity', p ->> 'path', p ->> 'mime',
          lower(nullif(btrim(coalesce(p ->> 'sha256', '')), '')), 'id_face_90d'::retention_class,
          greatest(b.return_at, now()) + make_interval(days => (app.settings()).retention_id_face_days), p_by, b.renter_id, b.id)
  returning id into v_doc;
  update verification_uploads set status = 'replaced' where booking_id = b.id and driver_id = v_driver and kind = v_kind and status = 'at_pickup';
  insert into verification_uploads (booking_id, driver_id, kind, document_id, status, uploaded_by)
  values (b.id, v_driver, v_kind, v_doc, 'at_pickup', p_by)
  returning id into v_id;
  return v_id;
end $$;

create function public.server_checkin_id_photo(p_by uuid, p jsonb) returns uuid
language sql security definer set search_path = public, app as $$ select app.checkin_id_photo_register(p_by, p) $$;

-- ================================================================ 3. where staff review IDs
-- the staff who may view a booking's licence images may view its pickup photos (3071's rule, with the two new kinds)
create or replace function app.doc_view_can(p_by uuid, p_upload uuid) returns boolean
language sql stable security definer set search_path = public, app as $$
  select exists (
    select 1 from verification_uploads u
     where u.id = p_upload and u.booking_id is not null
       and (app.doc_review_can(p_by, u.booking_id)
            or (u.kind in ('licence_front', 'licence_back', 'selfie', 'licence_front_pickup', 'licence_back_pickup', 'selfie_pickup')
                and (app.sales_licence_can(p_by, u.booking_id) or app.field_licence_can(p_by, u.booking_id)))))
$$;

create function app.doc_pickup_uploads(p_by uuid, p_booking uuid) returns jsonb
language sql stable security definer set search_path = public, app as $$
  select coalesce(jsonb_agg(jsonb_build_object('id', u.id, 'kind', u.kind, 'driver_id', u.driver_id, 'status', u.status, 'uploaded_at', u.uploaded_at,
                              'reject_reason', null, 'mime_type', doc.mime_type, 'purged_at', doc.purged_at) order by u.uploaded_at), '[]'::jsonb)
    from verification_uploads u join documents doc on doc.id = u.document_id
   where u.booking_id = p_booking and u.status = 'at_pickup' and app.doc_view_can(p_by, u.id)
$$;
create function app.doc_with_pickup(p_by uuid, v jsonb) returns jsonb
language sql stable security definer set search_path = public, app as $$
  select case when v is null or jsonb_typeof(v -> 'uploads') is distinct from 'array' or coalesce(v ->> 'booking_id', '') !~ '^[0-9a-f-]{36}$' then v
              else v || jsonb_build_object('uploads', (v -> 'uploads') || app.doc_pickup_uploads(p_by, (v ->> 'booking_id')::uuid)) end
$$;

alter function app.door(uuid, text, text, text, jsonb) rename to door_pre3292;
create function app.door(p_user uuid, p_aal text, p_call text, p_name text, p jsonb default '{}'::jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
begin
  if (p_call in ('ops_read', 'admin_read') and p_name = 'doc_review') or (p_call = 'va_read' and p_name = 'verification')
     or (p_call = 'field_read' and p_name = 'licence_review') then
    return app.doc_with_pickup(p_user, app.door_pre3292(p_user, p_aal, p_call, p_name, p));
  end if;
  return app.door_pre3292(p_user, p_aal, p_call, p_name, p);
end $$;
select pg_temp.copy_grants('app.door(uuid, text, text, text, jsonb)'::regprocedure, 'app.door_pre3292(uuid, text, text, text, jsonb)'::regprocedure);

-- ================================================================ 4. the dispute pack
alter function public.server_dispute_evidence(uuid) rename to server_dispute_evidence_pre3292;
create function public.server_dispute_evidence(p_pack uuid) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  v jsonb := public.server_dispute_evidence_pre3292(p_pack);
  v_more jsonb;
begin
  if v is null or jsonb_typeof(v -> 'licence') is distinct from 'array' then return v; end if;
  select coalesce(jsonb_agg(jsonb_build_object('kind', u.kind, 'status', 'taken at pickup', 'driver', (select dv.full_name from drivers dv where dv.id = u.driver_id),
                             'bucket', d.storage_bucket, 'path', d.storage_path, 'mime', d.mime_type, 'uploaded_at', u.uploaded_at) order by u.uploaded_at), '[]'::jsonb)
    into v_more
    from dispute_packs k
    join verification_uploads u on u.booking_id = k.booking_id
    join documents d on d.id = u.document_id
   where k.id = p_pack and u.status = 'at_pickup' and d.storage_path is not null and d.purged_at is null;
  return v || jsonb_build_object('licence', (v -> 'licence') || v_more);
end $$;
select pg_temp.copy_grants('public.server_dispute_evidence(uuid)'::regprocedure, 'public.server_dispute_evidence_pre3292(uuid)'::regprocedure);

-- ================================================================ privileges
do $$
declare f record;
begin
  for f in
    select p.oid::regprocedure as sig from pg_proc p join pg_namespace n on n.oid = p.pronamespace
     where (n.nspname = 'app' and p.proname = any (array['checkin_id_photo_register', 'doc_view_can', 'doc_pickup_uploads', 'doc_with_pickup', 'door_pre3292']))
        or (n.nspname = 'public' and p.proname = any (array['server_checkin_id_photo', 'server_dispute_evidence_pre3292']))
  loop
    execute format('revoke all on function %s from public, anon, authenticated', f.sig);
    execute format('grant execute on function %s to service_role', f.sig);
  end loop;
end $$;
