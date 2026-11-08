-- 0821: onboarding photos can be changed (Release 34, part P; docs/changes/2026-11-08-r34-owner-onboarding.md).
-- No applied migration is edited.
--
-- The onboarding photos are a car's ownership permit, insurance slip and lender or lessor permission (documents of
-- those kinds, from the owner portal, Add a car for an owner or a registry run). Until now one could only be added.
--   1. documents get a review state for these kinds (waiting, approved, rejected) and a soft removal (removed_at, by,
--      reason, and the newer document that replaces it). A new upload waits for review.
--   2. app.onboarding_photo_replace / _remove / _review: the owner (their own car), an Admin, customer service and
--      fleet replace or remove any onboarding photo; an Admin, customer service and fleet approve or reject one. Every
--      change is in audit_log with the before and after. A photo that was approved and is replaced or removed goes back
--      to review: the new one waits, and the ownership permit's "done" mark on the onboarding checklist is cleared.
--   3. app.onboarding_photos: the photos of a car or of every car of an owner, for the three views.
--   4. A removed photo no longer counts: the onboarding checklist, the owner's Documents and the car's documents leave
--      it out (patched in place).
set local check_function_bodies = off;

create function pg_temp.patch_fn(p_sig regprocedure, p_old text, p_new text) returns void
language plpgsql as $$
declare d text := pg_get_functiondef(p_sig);
begin
  if position(p_old in d) = 0 then raise exception '0821: the text to change was not found in %: %', p_sig, left(p_old, 120); end if;
  execute replace(d, p_old, p_new);
end $$;

-- ================================================================ 1. the review state and the removal
alter table documents
  add column review_status text check (review_status in ('waiting', 'approved', 'rejected')),
  add column reviewed_by uuid references users (id),
  add column reviewed_at timestamptz,
  add column review_note text,
  add column removed_at timestamptz,
  add column removed_by uuid references users (id),
  add column removed_reason text,
  add column replaced_by uuid references documents (id);

create function app.onboarding_photo_kind(p_kind text) returns boolean
language sql immutable as $$ select p_kind in ('ownership_permit', 'owner_insurance_proof', 'finance_party_permission') $$;

create function app.onboarding_photo_label(p_kind text) returns text
language sql immutable as $$
  select case p_kind when 'ownership_permit' then 'Ownership permit' when 'owner_insurance_proof' then 'Insurance slip'
                     when 'finance_party_permission' then 'Lender or lessor permission' else 'Photo' end $$;

-- a new onboarding photo waits for review
create function app.documents_onboarding_review() returns trigger
language plpgsql security definer set search_path = public, app as $$
begin
  if app.onboarding_photo_kind(new.kind::text) and new.vehicle_id is not null and new.review_status is null then new.review_status := 'waiting'; end if;
  return new;
end $$;
create trigger documents_onboarding_review before insert on documents for each row execute function app.documents_onboarding_review();

-- the photos on file: a car still onboarding waits for its review unless its permit was marked checked; the others were accepted
update documents d set review_status = case
    when v.status = 'onboarding' and not (d.kind = 'ownership_permit' and coalesce(ob.checklist_marks #>> '{documents,status}', '') = 'done') then 'waiting'
    else 'approved' end
  from vehicles v left join vehicle_onboardings ob on ob.vehicle_id = v.id
 where v.id = d.vehicle_id and app.onboarding_photo_kind(d.kind::text) and d.review_status is null;

-- ================================================================ 2. who may change a photo
-- 'owner' (their own car, still with us), 'staff' (an Admin, customer service, fleet), or null
create function app.onboarding_photo_who(p_by uuid, p_vehicle uuid) returns text
language sql stable security definer set search_path = public, app as $$
  select case when p_by is null then null
              when app.user_is_admin(p_by) or app.user_va_has(p_by, 'cs', 'fleet') then 'staff'
              when app.user_owns_vehicle(p_by, p_vehicle) and exists (select 1 from vehicles v where v.id = p_vehicle and v.status not in ('declined', 'exited', 'total_loss')) then 'owner'
         end $$;

-- the photo of a car that may be changed, locked
create function app.onboarding_photo_get(p_by uuid, p_document uuid) returns documents
language plpgsql security definer set search_path = public, app as $$
declare d documents;
begin
  select * into d from documents where id = p_document for update;
  if d.id is null or not app.onboarding_photo_kind(d.kind::text) or d.vehicle_id is null then raise exception 'Photo not found' using errcode = 'P0002'; end if;
  if app.onboarding_photo_who(p_by, d.vehicle_id) is null then raise exception 'Not permitted: only the car''s owner, an Admin, customer service or fleet change its photos' using errcode = '42501'; end if;
  if d.removed_at is not null then raise exception 'This photo was already replaced or removed. Reload the page' using errcode = '23514'; end if;
  return d;
end $$;

-- an approved photo replaced or removed: the permit's checklist mark goes, the car's photos are checked again
create function app.onboarding_photo_unapprove(p_by uuid, d documents) returns boolean
language plpgsql security definer set search_path = public, app as $$
declare v_marked boolean;
begin
  select coalesce(ob.checklist_marks #>> '{documents,status}', '') = 'done' into v_marked from vehicle_onboardings ob where ob.vehicle_id = d.vehicle_id;
  if d.kind = 'ownership_permit' and coalesce(v_marked, false) then
    update vehicle_onboardings set checklist_marks = checklist_marks - 'documents' where vehicle_id = d.vehicle_id;
  end if;
  if d.review_status = 'approved' or (d.kind = 'ownership_permit' and coalesce(v_marked, false)) then
    insert into audit_log (actor_user_id, action, entity_table, entity_id, after)
    values (p_by, 'onboarding_photo_back_to_review', 'documents', d.id::text, jsonb_build_object('vehicle_id', d.vehicle_id, 'kind', d.kind));
    return true;
  end if;
  return false;
end $$;

create function app.onboarding_photo_replace(p_by uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  d documents;
  v_who text;
  v_id uuid;
  v_back boolean;
begin
  d := app.onboarding_photo_get(p_by, nullif(p ->> 'document_id', '')::uuid);
  v_who := app.onboarding_photo_who(p_by, d.vehicle_id);
  if coalesce(p ->> 'mime', '') not in ('image/jpeg', 'image/png', 'application/pdf') or coalesce(lower(p ->> 'sha256'), '') !~ '^[0-9a-f]{64}$'
     or coalesce(p ->> 'path', '') !~ '^owners/' then
    raise exception 'A new photo needs its file, its type and its SHA-256' using errcode = '22023';
  end if;
  if v_who = 'owner' and (select count(*) from documents x where x.vehicle_id = d.vehicle_id and x.uploaded_by = p_by and x.created_at > now() - interval '1 hour') >= 30 then
    raise exception 'Too many uploads in the last hour. Try again later.' using errcode = '54000';
  end if;
  insert into documents (kind, title, storage_bucket, storage_path, mime_type, sha256, retention, uploaded_by, owner_id, vehicle_id, review_status)
  values (d.kind, format('%s, %s', app.onboarding_photo_label(d.kind::text), app.vehicle_name(d.vehicle_id)), 'documents', p ->> 'path', p ->> 'mime',
          lower(p ->> 'sha256'), 'records_7y', p_by, coalesce(d.owner_id, (select owner_id from vehicles where id = d.vehicle_id)), d.vehicle_id, 'waiting')
  returning id into v_id;
  v_back := app.onboarding_photo_unapprove(p_by, d);
  update documents set removed_at = now(), removed_by = p_by, removed_reason = coalesce(nullif(btrim(coalesce(p ->> 'reason', '')), ''), 'Replaced'), replaced_by = v_id
   where id = d.id;
  insert into audit_log (actor_user_id, action, entity_table, entity_id, before, after)
  values (p_by, 'onboarding_photo_replace', 'documents', d.id::text,
          jsonb_build_object('document_id', d.id, 'kind', d.kind, 'review_status', d.review_status, 'sha256', d.sha256),
          jsonb_build_object('document_id', v_id, 'vehicle_id', d.vehicle_id, 'by', v_who, 'back_to_review', v_back));
  return jsonb_build_object('document_id', v_id, 'replaced', d.id, 'back_to_review', v_back, 'review_status', 'waiting');
end $$;

create function app.onboarding_photo_remove(p_by uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  d documents;
  v_who text;
  v_reason text := nullif(btrim(coalesce(p ->> 'reason', '')), '');
  v_back boolean;
begin
  d := app.onboarding_photo_get(p_by, nullif(p ->> 'document_id', '')::uuid);
  v_who := app.onboarding_photo_who(p_by, d.vehicle_id);
  if v_who = 'staff' and coalesce(length(v_reason), 0) < 3 then raise exception 'Say why the photo is removed' using errcode = '22023'; end if;
  v_back := app.onboarding_photo_unapprove(p_by, d);
  update documents set removed_at = now(), removed_by = p_by, removed_reason = coalesce(v_reason, 'Removed by the owner') where id = d.id;
  insert into audit_log (actor_user_id, action, entity_table, entity_id, before, after)
  values (p_by, 'onboarding_photo_remove', 'documents', d.id::text,
          jsonb_build_object('document_id', d.id, 'kind', d.kind, 'review_status', d.review_status),
          jsonb_build_object('vehicle_id', d.vehicle_id, 'by', v_who, 'reason', coalesce(v_reason, 'Removed by the owner'), 'back_to_review', v_back));
  return jsonb_build_object('removed', d.id, 'back_to_review', v_back);
end $$;

create function app.onboarding_photo_review(p_by uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  d documents;
  v_decision text := p ->> 'decision';
  v_note text := nullif(btrim(coalesce(p ->> 'note', '')), '');
begin
  if not (app.user_is_admin(p_by) or app.user_va_has(p_by, 'cs', 'fleet')) then
    raise exception 'Only an Admin, customer service or fleet check onboarding photos' using errcode = '42501';
  end if;
  d := app.onboarding_photo_get(p_by, nullif(p ->> 'document_id', '')::uuid);
  if v_decision not in ('approved', 'rejected') then raise exception 'Approve or reject the photo' using errcode = '22023'; end if;
  if v_decision = 'rejected' and v_note is null then raise exception 'Tell the owner what is wrong with the photo' using errcode = '22023'; end if;
  update documents set review_status = v_decision, reviewed_by = p_by, reviewed_at = now(), review_note = v_note where id = d.id;
  -- the permit approved: the checklist's "Check the ownership permit" is done
  if v_decision = 'approved' and d.kind = 'ownership_permit' then
    perform app.mark_onboarding_item(d.vehicle_id, 'documents', 'done', p_by, 'Ownership permit approved');
  elsif v_decision = 'rejected' and d.kind = 'ownership_permit' then
    update vehicle_onboardings set checklist_marks = checklist_marks - 'documents' where vehicle_id = d.vehicle_id;
  end if;
  insert into audit_log (actor_user_id, action, entity_table, entity_id, before, after)
  values (p_by, 'onboarding_photo_review', 'documents', d.id::text, jsonb_build_object('review_status', d.review_status),
          jsonb_build_object('review_status', v_decision, 'note', v_note, 'vehicle_id', d.vehicle_id));
  return jsonb_build_object('document_id', d.id, 'review_status', v_decision);
end $$;

-- ================================================================ 3. the read
create function app.onboarding_photos(p_by uuid, p jsonb) returns jsonb
language plpgsql stable security definer set search_path = public, app as $$
declare
  v_vehicle uuid := nullif(p ->> 'vehicle_id', '')::uuid;
  v_owner uuid := nullif(p ->> 'owner_id', '')::uuid;
  v_staff boolean := app.user_is_admin(p_by) or app.user_va_has(p_by, 'cs', 'fleet');
begin
  if v_vehicle is not null then select owner_id into v_owner from vehicles where id = v_vehicle; end if;
  if v_owner is null then raise exception 'Owner not found' using errcode = 'P0002'; end if;
  if not v_staff and not app.user_is_owner_of(p_by, v_owner) then raise exception 'Not permitted' using errcode = '42501'; end if;
  return (select coalesce(jsonb_agg(jsonb_build_object('id', d.id, 'vehicle_id', d.vehicle_id, 'vehicle_name', app.vehicle_name(d.vehicle_id), 'kind', d.kind,
            'label', app.onboarding_photo_label(d.kind::text), 'mime', d.mime_type, 'created_at', d.created_at,
            'uploaded_by', case when d.uploaded_by is null then null when app.user_is_owner_of(d.uploaded_by, v_owner) then 'owner' else 'carmacars' end,
            'review_status', coalesce(d.review_status, 'waiting'), 'reviewed_at', d.reviewed_at, 'review_note', d.review_note,
            'replaces', (select x.id from documents x where x.replaced_by = d.id limit 1))
            order by d.vehicle_id, d.kind, d.created_at), '[]'::jsonb)
    from documents d join vehicles v on v.id = d.vehicle_id
   where v.owner_id = v_owner and (v_vehicle is null or d.vehicle_id = v_vehicle)
     and app.onboarding_photo_kind(d.kind::text) and d.removed_at is null and d.purged_at is null);
end $$;

-- the stored file of an onboarding photo, for the staff link (an Admin, customer service, fleet)
create function app.onboarding_photo_file(p_by uuid, p jsonb) returns jsonb
language plpgsql stable security definer set search_path = public, app as $$
declare d documents;
begin
  select * into d from documents where id = nullif(p ->> 'document', '')::uuid;
  if d.id is null or not app.onboarding_photo_kind(d.kind::text) or d.purged_at is not null then return null; end if;
  if not (app.user_is_admin(p_by) or app.user_va_has(p_by, 'cs', 'fleet')) then return null; end if;
  return jsonb_build_object('bucket', d.storage_bucket, 'path', d.storage_path, 'mime_type', d.mime_type);
end $$;

-- ================================================================ 4. a removed photo no longer counts
select pg_temp.patch_fn('app.onboarding_checklist_0022(uuid)'::regprocedure,
  'd.kind = ''ownership_permit'' and d.purged_at is null', 'd.kind = ''ownership_permit'' and d.purged_at is null and d.removed_at is null');
select pg_temp.patch_fn('app.owner_portal_documents(uuid)'::regprocedure, 'and d.purged_at is null', 'and d.purged_at is null and d.removed_at is null');
select pg_temp.patch_fn('app.vehicle_documents_read(uuid, jsonb)'::regprocedure, 'and d.purged_at is null', 'and d.purged_at is null and d.removed_at is null');
select pg_temp.patch_fn('app.admin_read_0030(uuid, text, jsonb)'::regprocedure, 'order by d.created_at desc) from documents d where d.owner_id = v_id)',
  'order by d.created_at desc) from documents d where d.owner_id = v_id and d.removed_at is null)');

do $$
declare f record;
begin
  for f in select p.oid::regprocedure as sig from pg_proc p join pg_namespace n on n.oid = p.pronamespace
            where n.nspname = 'app' and p.proname = any (array['onboarding_photo_kind', 'onboarding_photo_label', 'documents_onboarding_review', 'onboarding_photo_who',
              'onboarding_photo_get', 'onboarding_photo_unapprove', 'onboarding_photo_replace', 'onboarding_photo_remove', 'onboarding_photo_review',
              'onboarding_photos', 'onboarding_photo_file'])
  loop execute format('revoke all on function %s from public, anon, authenticated', f.sig); end loop;
end $$;
