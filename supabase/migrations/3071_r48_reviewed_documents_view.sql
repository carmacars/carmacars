-- 3071 (release 48): a reviewed renter document stays viewable to the staff who review it (owner, Nov 15).
-- Until now the licence front and back, the selfie and the proof-of-coverage pages (pink slip, OPCF 27 endorsement) showed
-- their image only while waiting ('submitted'): once approved or rejected, nobody could look at them again before the
-- 90-day purge. Now:
--   1. app.doc_view(p_by, {upload}): one renter document (a verification_uploads row, any status) for one viewer. The same
--      people who review it may view it: an Admin and customer service (app.doc_review_can) every kind, Sales and field
--      staff (app.sales_licence_can, app.field_licence_can) the licence front, back and selfie. Anyone else, an owner
--      included, is refused. Each view is written to the audit log (action document_view, the document, the booking, the
--      kind) and to the data access log ('open'); the server then makes a one-minute private link (web/src/server/actions/
--      doc-view.ts). A purged document answers {removed_on} and nothing else.
--   2. The review reads (doc_review for Admin, customer service and Sales; va_read verification; field_read licence_review)
--      list the purged documents too, with purged_at and no file, so the screen says "Removed on <date>".
-- SCHEMA_MARKER 3071. docs/changes/2026-11-15-r48-reviewed-documents.md.
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

-- ================================================================ 1. who may view one document
create function app.doc_view_can(p_by uuid, p_upload uuid) returns boolean
language sql stable security definer set search_path = public, app as $$
  select exists (
    select 1 from verification_uploads u
     where u.id = p_upload and u.booking_id is not null
       and (app.doc_review_can(p_by, u.booking_id)
            or (u.kind in ('licence_front', 'licence_back', 'selfie')
                and (app.sales_licence_can(p_by, u.booking_id) or app.field_licence_can(p_by, u.booking_id)))))
$$;

-- p: {upload}. {upload, kind, status, mime_type, bucket, path} for the server to sign for one minute, or {upload, kind,
-- removed_on} when the file was purged. Logged either way.
create function app.doc_view(p_by uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  u verification_uploads;
  d documents;
  b bookings;
begin
  select * into u from verification_uploads where id = case when coalesce(p ->> 'upload', '') ~ '^[0-9a-f-]{36}$' then (p ->> 'upload')::uuid end;
  if u.id is null then raise exception 'Document not found' using errcode = 'P0002'; end if;
  if not app.doc_view_can(p_by, u.id) then
    raise exception 'Only the staff who review this booking''s documents may view them' using errcode = '42501';
  end if;
  select * into d from documents where id = u.document_id;
  select * into b from bookings where id = u.booking_id;
  insert into audit_log (actor_user_id, action, entity_table, entity_id, after)
  values (p_by, 'document_view', 'documents', d.id::text,
          jsonb_build_object('upload', u.id, 'booking', b.booking_number, 'kind', u.kind, 'status', u.status, 'purged', d.purged_at is not null));
  insert into data_access_log (user_id, action, renter_id, reason, results)
  values (p_by, 'open', b.renter_id, 'viewed ' || replace(u.kind, '_', ' ') || ' (' || u.status || '), booking ' || b.booking_number, 1);
  if d.id is null or d.purged_at is not null then
    return jsonb_build_object('upload', u.id, 'kind', u.kind, 'removed_on', app.local_date(coalesce(d.purged_at, now())));
  end if;
  return jsonb_build_object('upload', u.id, 'kind', u.kind, 'status', u.status, 'mime_type', d.mime_type, 'bucket', d.storage_bucket, 'path', d.storage_path);
end $$;

-- ================================================================ 2. the purged documents in the review reads
-- the purged documents of the booking this viewer may view (no file: purged_at only), the coverage pages left out (they are
-- listed under the coverage)
create function app.doc_removed_uploads(p_by uuid, p_booking uuid) returns jsonb
language sql stable security definer set search_path = public, app as $$
  select coalesce(jsonb_agg(jsonb_build_object('id', u.id, 'kind', u.kind, 'driver_id', u.driver_id, 'status', u.status, 'uploaded_at', u.uploaded_at,
                              'reject_reason', u.reject_reason, 'mime_type', doc.mime_type, 'purged_at', doc.purged_at) order by u.uploaded_at), '[]'::jsonb)
    from verification_uploads u join documents doc on doc.id = u.document_id
   where u.booking_id = p_booking and u.kind <> 'coverage_proof' and u.status in ('submitted', 'approved', 'rejected')
     and doc.purged_at is not null and app.doc_view_can(p_by, u.id)
$$;

create function app.doc_with_removed(p_by uuid, v jsonb) returns jsonb
language sql stable security definer set search_path = public, app as $$
  select case when v is null or jsonb_typeof(v -> 'uploads') is distinct from 'array' or coalesce(v ->> 'booking_id', '') !~ '^[0-9a-f-]{36}$' then v
              else v || jsonb_build_object('uploads', (v -> 'uploads') || app.doc_removed_uploads(p_by, (v ->> 'booking_id')::uuid)) end
$$;

-- ================================================================ the door
alter function app.door(uuid, text, text, text, jsonb) rename to door_pre3071;
create function app.door(p_user uuid, p_aal text, p_call text, p_name text, p jsonb default '{}'::jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
begin
  if p_name = 'doc_view' and p_call in ('ops_read', 'admin_read', 'va_read', 'field_read') then
    perform app.door_begin(p_user, p_aal);
    return app.doc_view(p_user, coalesce(p, '{}'::jsonb) - '_va');
  end if;
  if (p_call in ('ops_read', 'admin_read') and p_name = 'doc_review') or (p_call = 'va_read' and p_name = 'verification')
     or (p_call = 'field_read' and p_name = 'licence_review') then
    return app.doc_with_removed(p_user, app.door_pre3071(p_user, p_aal, p_call, p_name, p));
  end if;
  return app.door_pre3071(p_user, p_aal, p_call, p_name, p);
end $$;
select pg_temp.copy_grants('app.door(uuid, text, text, text, jsonb)'::regprocedure, 'app.door_pre3071(uuid, text, text, text, jsonb)'::regprocedure);

-- ================================================================ privileges
do $$
declare f record;
begin
  for f in
    select p.oid::regprocedure as sig from pg_proc p join pg_namespace n on n.oid = p.pronamespace
     where n.nspname = 'app' and p.proname = any (array['doc_view_can', 'doc_view', 'doc_removed_uploads', 'doc_with_removed', 'door_pre3071'])
  loop
    execute format('revoke all on function %s from public, anon, authenticated', f.sig);
    execute format('grant execute on function %s to service_role', f.sig);
  end loop;
end $$;
