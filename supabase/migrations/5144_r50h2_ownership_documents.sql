-- 5144 (R50 hotfix 2, docs/changes/2026-11-27-r50-hotfix2-ops.md): ownership documents in bulk, and the door for 5142 to 5144.
-- The owner (Nov 27): upload many ownership (vehicle permit) photos or PDFs at once; each is read for the VIN and the plate,
-- matched to its car, stored on the car and shown in that owner's portal; the ones not matched are listed for a quick pick.
-- 1. permit_uploads: one uploaded file, what was read from it (by the permit reader of 0290, in the browser) and where it
--    went: filed on a car (its document, how it was matched: VIN, plate or by hand, and a note when the permit's plate is not
--    the car's), waiting for a person (unmatched), or discarded with the reason.
-- 2. app.permit_file: matches by the VIN (exact), else the plate the car has on that day (app.resolve_toll_vehicle), else
--    leaves it unmatched; a match stores the file as the car's ownership permit (documents, kind ownership_permit, on the car
--    and its owner: the owner's portal lists it under Documents), refreshes the owner's stages and tells the owner
--    (owner_permit_filed, 5145). One Fleet To do lists the files waiting for a car (permit_unmatched).
--    app.permit_assign files a waiting one on the car a person picks; app.permit_discard sets one aside with the reason.
--    app.permit_uploads_json: the waiting ones and the last filed. Admin, Fleet or customer service (as a car's documents).
--    Each file is a document from its upload (no car until it is filed), so staff open it while it waits
--    (app.ops_upload_document, which also serves a logged expense's receipt photos to those who log expenses).
-- 3. The door (app.door, wrapped): ops_read expense_context, expense_entries, permit_uploads, ops_upload_document; ops_do winter_tire_set (5142),
--    expense_log (5143), permit_file, permit_assign, permit_discard. Each function checks who may.
-- No applied migration is edited. SCHEMA_MARKER 5144.
set local check_function_bodies = off;

create table permit_uploads (
  id           uuid primary key default gen_random_uuid(),
  storage_path text not null check (storage_path ~ '^permits/\d{4}/[0-9a-f-]{36}\.(jpg|png|pdf)$'),
  mime_type    text,
  sha256       text,
  file_name    text check (file_name is null or length(file_name) <= 200),
  vin          text,
  plate        text,
  read         jsonb not null default '{}'::jsonb,
  status       text not null default 'unmatched' check (status in ('filed', 'unmatched', 'discarded')),
  vehicle_id   uuid references vehicles(id),
  document_id  uuid references documents(id),
  matched_by   text check (matched_by in ('vin', 'plate', 'hand')),
  note         text,
  created_by   uuid references users(id),
  created_at   timestamptz not null default now(),
  filed_by     uuid references users(id),
  filed_at     timestamptz,
  check ((status = 'filed') = (vehicle_id is not null))
);
comment on table permit_uploads is 'R50 hotfix 2 (5144): an ownership permit file uploaded in bulk: what was read, and the car it was filed on or why it waits.';
create index permit_uploads_vehicle_id_fk on permit_uploads (vehicle_id);
create index permit_uploads_document_id_fk on permit_uploads (document_id);
create index permit_uploads_waiting_idx on permit_uploads (created_at desc) where status = 'unmatched';
create trigger audit_permit_uploads after insert or update or delete on permit_uploads for each row execute function app.audit_row();
alter table permit_uploads enable row level security;
create policy admin_all on permit_uploads for all to authenticated using (app.is_admin()) with check (app.is_admin());
revoke all on permit_uploads from public, anon, authenticated;
grant select on permit_uploads to authenticated;
grant all on permit_uploads to service_role;

insert into task_rules (task_type, queue, title, priority, due_kind, due_amount, procedure_no, completion_rule, description) values
  ('permit_unmatched', 'fleet', 'Ownership documents need a car', 'normal', 'business_days', 1, null, null,
   'Open Ownership documents: pick the car for each file whose VIN and plate matched no car, or set it aside with the reason')
on conflict (task_type) do nothing;

create function app.permit_may_file(p_by uuid) returns boolean
language sql stable security definer set search_path = public, app, pg_temp as $$
  select coalesce(app.user_is_admin(p_by), false) or app.user_va_has(p_by, 'fleet', 'cs')
$$;

-- file one upload on a car: its document, the owner's stages, the owner told
create function app.permit_file_on(p_by uuid, p_upload uuid, p_vehicle uuid, p_how text) returns jsonb
language plpgsql security definer set search_path = public, app, pg_temp as $$
declare
  u permit_uploads;
  v vehicles;
  v_doc uuid;
  v_note text;
begin
  select * into u from permit_uploads where id = p_upload for update;
  select * into v from vehicles where id = p_vehicle;
  if v.id is null then raise exception 'Car not found' using errcode = 'P0002'; end if;
  -- the file was stored as a document when it was uploaded (5144): now it is the car's, and its owner's
  update documents set vehicle_id = v.id, owner_id = v.owner_id,
         title = left(concat_ws(', ', 'Ownership permit', app.vehicle_name(v.id), nullif(coalesce(u.plate, v.plate), '')), 200)
   where id = u.document_id
  returning id into v_doc;
  v_note := case when u.plate is not null and v.plate is not null and app.norm_plate(u.plate) <> app.norm_plate(v.plate)
                 then format('The permit''s plate %s is not the car''s plate %s: check the car''s registration', u.plate, v.plate)
                 when u.vin is not null and v.vin is not null and upper(u.vin) <> upper(v.vin)
                 then format('The permit''s VIN %s is not the car''s VIN %s: check it', u.vin, v.vin) end;
  update permit_uploads set status = 'filed', vehicle_id = v.id, document_id = v_doc, matched_by = p_how, note = v_note, filed_by = p_by, filed_at = now()
   where id = u.id;
  insert into audit_log (actor_user_id, action, entity_table, entity_id, after)
  values (p_by, 'permit_file', 'vehicles', v.id::text, jsonb_build_object('upload', u.id, 'document_id', v_doc, 'matched_by', p_how));
  begin perform app.owner_stage_refresh(v.id); exception when undefined_function then null; end;
  if v.owner_id is not null then
    perform app.ntf_emit('owner_permit_filed', 'owner', v.owner_id, 'permit:' || u.id,
      jsonb_build_object('owner_id', v.owner_id, 'vehicle_id', v.id, 'vehicle_name', app.vehicle_name(v.id), 'plate_text', coalesce(u.plate, v.plate, '')));
  end if;
  return jsonb_build_object('upload', u.id, 'status', 'filed', 'vehicle_id', v.id, 'vehicle_name', app.vehicle_name(v.id), 'matched_by', p_how, 'note', v_note, 'document_id', v_doc);
end $$;

create function app.permit_waiting_task(p_by uuid) returns void
language plpgsql security definer set search_path = public, app, pg_temp as $$
declare n integer := (select count(*) from permit_uploads where status = 'unmatched');
begin
  if n > 0 then
    perform app.raise_task(p_type => 'permit_unmatched', p_queue => 'fleet', p_title => format('%s ownership document%s need%s a car', n, case when n = 1 then '' else 's' end, case when n = 1 then 's' else '' end),
      p_detail => 'Their VIN and plate did not match a car. Open Ownership documents and pick the car for each.', p_dedupe => 'permit_unmatched', p_created_by => p_by);
    update tasks set title = format('%s ownership document%s need%s a car', n, case when n = 1 then '' else 's' end, case when n = 1 then 's' else '' end)
     where dedupe_key = 'permit_unmatched' and status in ('open', 'in_progress', 'waiting');
  else
    update tasks set status = 'done', completed_at = now(), completed_by = p_by, completion_note = 'Every ownership document is on its car'
     where dedupe_key = 'permit_unmatched' and status in ('open', 'in_progress', 'waiting');
  end if;
end $$;

-- p: path, mime, sha256, file_name, vin, plate, read (the permit reader's answer)
create function app.permit_file(p_by uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app, pg_temp as $$
declare
  v_vin text := nullif(upper(regexp_replace(coalesce(p ->> 'vin', ''), '[^A-Za-z0-9]', '', 'g')), '');
  v_plate text := app.norm_plate(nullif(p ->> 'plate', ''));
  v_id uuid;
  v_doc uuid;
  v_car uuid;
  v_how text;
  n integer;
  r jsonb;
begin
  if not app.permit_may_file(p_by) then raise exception 'An Admin, Fleet or customer service files a car''s documents' using errcode = '42501'; end if;
  if coalesce(p ->> 'path', '') !~ '^permits/\d{4}/[0-9a-f-]{36}\.(jpg|png|pdf)$' then raise exception 'Unknown permit file' using errcode = '22023'; end if;
  insert into permit_uploads (storage_path, mime_type, sha256, file_name, vin, plate, read, created_by)
  values (p ->> 'path', nullif(p ->> 'mime', ''), nullif(p ->> 'sha256', ''), left(nullif(btrim(p ->> 'file_name'), ''), 200), v_vin, v_plate, coalesce(p -> 'read', '{}'::jsonb), p_by)
  returning id into v_id;
  -- stored as a document at once (no car yet), so staff can open it while it waits for a car
  insert into documents (kind, title, storage_bucket, storage_path, mime_type, sha256, retention, uploaded_by)
  values ('ownership_permit', left(concat_ws(', ', 'Ownership permit', nullif(p ->> 'file_name', '')), 200), 'documents', p ->> 'path', nullif(p ->> 'mime', ''), nullif(p ->> 'sha256', ''), 'records_7y', p_by)
  returning id into v_doc;
  update permit_uploads set document_id = v_doc where id = v_id;
  if v_vin is not null and length(v_vin) = 17 then
    select count(*), min(v.id::text)::uuid into n, v_car from vehicles v where upper(v.vin) = v_vin and not coalesce(v.is_sample, false);
    if n = 1 then v_how := 'vin'; else v_car := null; end if;
  end if;
  if v_car is null and v_plate is not null then
    select x.vehicle_id into v_car from app.resolve_toll_vehicle(v_plate, null, app.today()) x;
    if v_car is not null then v_how := 'plate'; end if;
  end if;
  if v_car is null then
    update permit_uploads set note = case when v_vin is null and v_plate is null then 'No VIN or plate could be read: pick the car'
                                          else 'No car has this VIN or plate: pick the car' end where id = v_id;
    perform app.permit_waiting_task(p_by);
    return jsonb_build_object('upload', v_id, 'status', 'unmatched', 'vin', v_vin, 'plate', v_plate);
  end if;
  r := app.permit_file_on(p_by, v_id, v_car, v_how);
  return r || jsonb_build_object('vin', v_vin, 'plate', v_plate);
end $$;

create function app.permit_assign(p_by uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app, pg_temp as $$
declare
  u permit_uploads;
  r jsonb;
begin
  if not app.permit_may_file(p_by) then raise exception 'An Admin, Fleet or customer service files a car''s documents' using errcode = '42501'; end if;
  select * into u from permit_uploads where id::text = p ->> 'upload' for update;
  if u.id is null then raise exception 'Upload not found' using errcode = 'P0002'; end if;
  if u.status <> 'unmatched' then raise exception 'This file is already %', u.status using errcode = '23514'; end if;
  r := app.permit_file_on(p_by, u.id, nullif(p ->> 'vehicle_id', '')::uuid, 'hand');
  perform app.permit_waiting_task(p_by);
  return r;
end $$;

create function app.permit_discard(p_by uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app, pg_temp as $$
declare
  u permit_uploads;
  v_reason text := nullif(btrim(coalesce(p ->> 'reason', '')), '');
begin
  if not app.permit_may_file(p_by) then raise exception 'An Admin, Fleet or customer service files a car''s documents' using errcode = '42501'; end if;
  if v_reason is null then raise exception 'Say why the file is set aside' using errcode = '22023'; end if;
  select * into u from permit_uploads where id::text = p ->> 'upload' for update;
  if u.id is null then raise exception 'Upload not found' using errcode = 'P0002'; end if;
  if u.status <> 'unmatched' then raise exception 'This file is already %', u.status using errcode = '23514'; end if;
  update permit_uploads set status = 'discarded', note = left(v_reason, 300), filed_by = p_by, filed_at = now() where id = u.id;
  update documents set removed_at = now(), removed_by = p_by, removed_reason = left('Set aside: ' || v_reason, 300) where id = u.document_id and removed_at is null;
  perform app.permit_waiting_task(p_by);
  return jsonb_build_object('upload', u.id, 'status', 'discarded');
end $$;

create function app.permit_uploads_json(p_by uuid) returns jsonb
language plpgsql stable security definer set search_path = public, app, pg_temp as $$
begin
  if not app.permit_may_file(p_by) then raise exception 'An Admin, Fleet or customer service files a car''s documents' using errcode = '42501'; end if;
  return jsonb_build_object(
    'waiting', (select coalesce(jsonb_agg(jsonb_build_object('id', u.id, 'file_name', u.file_name, 'vin', u.vin, 'plate', u.plate, 'note', u.note, 'mime_type', u.mime_type, 'document_id', u.document_id,
                  'created_at', u.created_at) order by u.created_at), '[]'::jsonb) from permit_uploads u where u.status = 'unmatched'),
    'filed', (select coalesce(jsonb_agg(x.j order by x.at desc), '[]'::jsonb) from (
                select jsonb_build_object('id', u.id, 'file_name', u.file_name, 'vin', u.vin, 'plate', u.plate, 'vehicle_id', u.vehicle_id, 'vehicle_name', app.vehicle_name(u.vehicle_id),
                         'matched_by', u.matched_by, 'note', u.note, 'document_id', u.document_id, 'filed_at', u.filed_at) j, u.filed_at at
                  from permit_uploads u where u.status = 'filed' order by u.filed_at desc limit 50) x),
    'cars', (select coalesce(jsonb_agg(jsonb_build_object('id', v.id, 'name', app.vehicle_name(v.id), 'plate', v.plate, 'vin', v.vin,
                  'owner_name', (select coalesce(nullif(btrim(o.corporation_name), ''), o.legal_name) from owners o where o.id = v.owner_id)) order by v.make, v.model, v.plate), '[]'::jsonb)
               from vehicles v where not coalesce(v.is_sample, false) and v.status::text not in ('archived', 'removed', 'sold')));
end $$;

-- a receipt photo of a logged expense, or an uploaded permit, for the staff file route (web/src/app/staff/documents/[id])
create function app.ops_upload_document(p_by uuid, p_document uuid) returns jsonb
language sql stable security definer set search_path = public, app, pg_temp as $$
  select jsonb_build_object('bucket', d.storage_bucket, 'path', d.storage_path, 'mime_type', d.mime_type) from documents d
   where d.id = p_document and d.purged_at is null
     and ((app.expense_may_log(p_by) and exists (select 1 from expense_entry_photos ph where ph.document_id = d.id))
       or (app.permit_may_file(p_by) and exists (select 1 from permit_uploads u where u.document_id = d.id)))
$$;

-- ---------------------------------------------------------------- the door
alter function app.door(uuid, text, text, text, jsonb) rename to door_pre5144;
create function app.door(p_user uuid, p_aal text, p_call text, p_name text, p jsonb default '{}'::jsonb) returns jsonb
language plpgsql security definer set search_path = public, app, pg_temp as $$
begin
  if p_call = 'ops_read' and p_name in ('expense_context', 'expense_entries', 'permit_uploads', 'ops_upload_document') then
    perform app.door_begin(p_user, p_aal);
    if p_name = 'ops_upload_document' then return app.ops_upload_document(p_user, nullif(p ->> 'document', '')::uuid); end if;
    if p_name = 'expense_context' then return app.expense_context(p_user); end if;
    if p_name = 'expense_entries' then return app.expense_entries_json(p_user, nullif(p ->> 'limit', '')::integer); end if;
    return app.permit_uploads_json(p_user);
  elsif p_call = 'ops_do' and p_name in ('winter_tire_set', 'expense_log', 'permit_file', 'permit_assign', 'permit_discard') then
    perform app.door_begin(p_user, p_aal);
    if p_name = 'winter_tire_set' then return app.booking_winter_tire_set(p_user, p); end if;
    if p_name = 'expense_log' then return app.expense_log(p_user, p); end if;
    if p_name = 'permit_file' then return app.permit_file(p_user, p); end if;
    if p_name = 'permit_assign' then return app.permit_assign(p_user, p); end if;
    return app.permit_discard(p_user, p);
  end if;
  return app.door_pre5144(p_user, p_aal, p_call, p_name, p);
end $$;

do $$
declare
  f record;
  g text;
begin
  -- the door keeps the grants it had
  foreach g in array array['anon', 'authenticated', 'service_role'] loop
    if has_function_privilege(g, 'app.door_pre5144(uuid, text, text, text, jsonb)'::regprocedure, 'execute') then
      execute format('grant execute on function app.door(uuid, text, text, text, jsonb) to %I', g);
    end if;
  end loop;
  revoke all on function app.door(uuid, text, text, text, jsonb) from public;
  for f in select p.oid::regprocedure as sig from pg_proc p
            where p.pronamespace = 'app'::regnamespace and p.proname in ('permit_may_file', 'permit_file_on', 'permit_waiting_task', 'permit_file', 'permit_assign', 'permit_discard', 'permit_uploads_json', 'ops_upload_document', 'door_pre5144') loop
    execute format('revoke all on function %s from public, anon, authenticated', f.sig);
    execute format('grant execute on function %s to service_role', f.sig);
  end loop;
end $$;
