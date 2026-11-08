-- 0760_r33_drive_import.sql
-- Release 33, part J (docs/changes/2026-11-07-r33-drive-import.md): import listing photos from a public Google Drive link.
-- The owner hands over car photos in bulk as public Drive folders (a top folder, one folder per make, then per car). Admin
-- and Fleet or customer service staff paste the link on a car's listing page (that car) or on Cars > Import photos from
-- Drive (the whole folder tree: each car folder is matched to a car on the platform, confirmed in a table, then imported).
--   * drive_imports, drive_import_folders, drive_import_files: the run, the folders it walked and the photos it found, with
--     their state (pending, done, skipped, failed and why). The Worker walks and downloads in steps of its own requests
--     (src/server/drive-import.ts, like pdf_jobs 0077), claimed here with a lock, retried with a backoff.
--   * Each photo goes through the listing upload as a staff upload does (app.record_listing_upload: the intake, the shot, the
--     process_photo jobs, studio framing, the plate check). It is idempotent: the same Drive file on the same car is not
--     taken twice (a photo still on the car), nor the same picture (content hash) twice.
--   * program_settings.google_drive_api_key: with a key the Drive API v3 lists and downloads; without, the folder page's data.
--   * The cron gate: server_jobs_due says "listing" also when an import has work (the listing route then starts it).
-- SCHEMA_MARKER 0761 (with the guides of 0761). No applied migration is edited.
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

-- ================================================================ 1. the setting
alter table program_settings add column if not exists google_drive_api_key text check (google_drive_api_key is null or google_drive_api_key ~ '^[A-Za-z0-9_-]{20,80}$');
comment on column program_settings.google_drive_api_key is 'Import photos from Google Drive (0760): a Google API key with the Drive API on. Set, the import lists and downloads through the Drive v3 API (no 50-photo page limit, no download warning page); empty, it reads the public folder page. Admin only.';

-- ================================================================ 2. the runs
create table drive_imports (
  id            uuid primary key default gen_random_uuid(),
  created_by    uuid not null references users (id),
  kind          text not null check (kind in ('car', 'bulk')),
  root_id       text not null check (root_id ~ '^[A-Za-z0-9_-]{10,100}$'),
  root_url      text,
  vehicle_id    uuid references vehicles (id),        -- kind car: every photo of the tree goes to this car
  status        text not null default 'scanning' check (status in ('scanning', 'review', 'importing', 'done', 'failed', 'cancelled')),
  options       jsonb not null default '{}'::jsonb,   -- {submit: true}: submit the listing when the photos are in
  error         text,
  totals        jsonb not null default '{}'::jsonb,
  bytes_done    bigint not null default 0,
  scanned_at    timestamptz,
  next_run_at   timestamptz not null default now(),
  locked_at     timestamptz,
  locked_by     text,
  created_at    timestamptz not null default now(),
  updated_at    timestamptz not null default now(),
  finished_at   timestamptz,
  check (kind <> 'car' or vehicle_id is not null)
);
comment on table drive_imports is 'A Google Drive photo import (0760): the link, who started it, where it stands; the Worker walks and downloads in steps (src/server/drive-import.ts)';
create index drive_imports_due on drive_imports (next_run_at) where status in ('scanning', 'importing');
create index drive_imports_vehicle on drive_imports (vehicle_id, created_at desc);
alter table drive_imports enable row level security;
create policy admin_all on drive_imports for all to authenticated using (app.is_admin()) with check (app.is_admin());
create trigger drive_imports_updated before update on drive_imports for each row execute function app.set_updated_at();
create trigger audit_drive_imports after insert or update or delete on drive_imports for each row execute function app.audit_row();

create table drive_import_folders (
  id            uuid primary key default gen_random_uuid(),
  import_id     uuid not null references drive_imports (id) on delete cascade,
  drive_id      text not null,
  parent_id     uuid references drive_import_folders (id) on delete cascade,
  name          text not null,
  path          text not null,
  depth         integer not null default 0,
  state         text not null default 'pending' check (state in ('pending', 'done', 'failed')),
  error         text,
  note          text,
  image_count   integer not null default 0,
  other_count   integer not null default 0,
  vehicle_id    uuid references vehicles (id),
  match_score   integer,
  match_note    text,
  candidates    jsonb not null default '[]'::jsonb,
  ambiguous     boolean not null default false,
  include       boolean not null default false,
  created_at    timestamptz not null default now(),
  unique (import_id, drive_id)
);
create index drive_import_folders_import on drive_import_folders (import_id, state);

create table drive_import_files (
  id            uuid primary key default gen_random_uuid(),
  import_id     uuid not null references drive_imports (id) on delete cascade,
  folder_id     uuid not null references drive_import_folders (id) on delete cascade,
  drive_id      text not null,
  name          text not null,
  mime          text,
  size_bytes    bigint,
  kind          text,
  seq           integer not null default 0,
  vehicle_id    uuid references vehicles (id),
  state         text not null default 'pending' check (state in ('pending', 'done', 'skipped', 'failed')),
  reason        text,
  attempts      integer not null default 0,
  retry_at      timestamptz,
  photo_id      uuid references vehicle_photos (id) on delete set null,
  shot_type     text,
  created_at    timestamptz not null default now(),
  done_at       timestamptz,
  unique (import_id, drive_id)
);
create index drive_import_files_run on drive_import_files (import_id, state, folder_id, seq);
create index drive_import_files_once on drive_import_files (vehicle_id, drive_id) where state = 'done';
alter table drive_import_folders enable row level security;
alter table drive_import_files enable row level security;
create policy admin_all on drive_import_folders for all to authenticated using (app.is_admin()) with check (app.is_admin());
create policy admin_all on drive_import_files for all to authenticated using (app.is_admin()) with check (app.is_admin());
revoke all on drive_imports, drive_import_folders, drive_import_files from public, anon, authenticated;
grant select, insert, update, delete on drive_imports, drive_import_folders, drive_import_files to service_role;

-- ================================================================ 3. the rules
create function app.drive_import_limits() returns jsonb language sql immutable as $$
  select jsonb_build_object('max_files', 600, 'max_folders', 400, 'max_depth', 4, 'max_total_bytes', 4294967296, 'max_file_bytes', 15728640, 'pause_ms', 400, 'tries', 3)
$$;

create function app.drive_import_arr(j jsonb) returns jsonb language sql immutable as $$ select case when jsonb_typeof(j) = 'array' then j else '[]'::jsonb end $$;

create function app.drive_import_may(p_user uuid) returns boolean language sql stable security definer set search_path = public, app as $$
  select p_user is not null and (app.user_is_admin(p_user) or app.user_va_has(p_user, 'fleet', 'cs'))
$$;

create function app.drive_import_car_label(p_vehicle uuid) returns text language sql stable security definer set search_path = public, app as $$
  select trim(concat_ws(' ', v.year::text, v.make, v.model)) || coalesce(' (' || nullif(btrim(v.plate), '') || ')', '') from vehicles v where v.id = p_vehicle
$$;

-- the cars a folder can be matched to: those that can take a listing (the same rule as starting one)
create function app.drive_import_cars() returns jsonb language sql stable security definer set search_path = public, app as $$
  select coalesce(jsonb_agg(jsonb_build_object('id', v.id, 'year', v.year, 'make', v.make, 'model', v.model, 'trim', v.trim, 'colour', v.colour, 'plate', v.plate,
           'partner', p.business_name, 'label', trim(concat_ws(' ', v.year::text, v.make, v.model)) || coalesce(' (' || nullif(btrim(v.plate), '') || ')', ''))
           order by (p.business_name ilike '%01 motors%') desc nulls last, v.make, v.model, v.year), '[]'::jsonb)
    from vehicles v left join partners p on p.id = v.partner_id
   where v.retired_at is null and v.status not in ('exited', 'total_loss', 'declined') and v.management_mode <> 'turo_only'
$$;

create function app.drive_import_cars_for(p_by uuid) returns jsonb language plpgsql stable security definer set search_path = public, app as $$
begin
  if not app.drive_import_may(p_by) then raise exception 'Fleet, customer service or an Admin imports listing photos' using errcode = '42501'; end if;
  return app.drive_import_cars();
end $$;

-- ================================================================ 4. start, confirm, cancel, retry (staff)
-- p: {root_id, root_url?, vehicle_id? (that car), submit? (default true)}
create function app.drive_import_start(p_by uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare d drive_imports; v_root text := btrim(coalesce(p ->> 'root_id', '')); v_vehicle uuid := nullif(p ->> 'vehicle_id', '')::uuid;
begin
  if not app.drive_import_may(p_by) then raise exception 'Fleet, customer service or an Admin imports listing photos' using errcode = '42501'; end if;
  if v_root !~ '^[A-Za-z0-9_-]{10,100}$' then raise exception 'That is not a Google Drive folder link' using errcode = '22023'; end if;
  if v_vehicle is not null and not exists (select 1 from vehicles where id = v_vehicle) then raise exception 'Unknown car' using errcode = 'P0002'; end if;
  -- the same link and car pressed twice: the run in progress
  select * into d from drive_imports where root_id = v_root and vehicle_id is not distinct from v_vehicle and status in ('scanning', 'review', 'importing') order by created_at desc limit 1;
  if d.id is not null then return jsonb_build_object('id', d.id, 'existing', true, 'status', d.status); end if;
  insert into drive_imports (created_by, kind, root_id, root_url, vehicle_id, options)
  values (p_by, case when v_vehicle is null then 'bulk' else 'car' end, v_root, left(nullif(btrim(p ->> 'root_url'), ''), 300), v_vehicle,
          jsonb_build_object('submit', coalesce((p ->> 'submit')::boolean, true)))
  returning * into d;
  insert into drive_import_folders (import_id, drive_id, name, path, depth) values (d.id, v_root, 'The link', '', 0);
  return jsonb_build_object('id', d.id, 'existing', false, 'status', d.status);
end $$;

-- p: {import, submit?, rows: [{folder, vehicle (uuid or null), include}]}: the table the person confirmed
create function app.drive_import_confirm(p_by uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare d drive_imports; r jsonb; v_folder uuid; v_vehicle uuid; v_n integer; v_photos integer;
begin
  if not app.drive_import_may(p_by) then raise exception 'Fleet, customer service or an Admin imports listing photos' using errcode = '42501'; end if;
  select * into d from drive_imports where id = (p ->> 'import')::uuid for update;
  if d.id is null then raise exception 'Unknown import' using errcode = 'P0002'; end if;
  if d.status <> 'review' then raise exception 'This import is % and cannot be confirmed', d.status using errcode = '23514'; end if;
  for r in select value from jsonb_array_elements(app.drive_import_arr(p -> 'rows')) loop
    v_folder := (r ->> 'folder')::uuid;
    v_vehicle := nullif(r ->> 'vehicle', '')::uuid;
    if v_vehicle is not null and not exists (select 1 from vehicles where id = v_vehicle) then raise exception 'Unknown car' using errcode = 'P0002'; end if;
    update drive_import_folders set vehicle_id = v_vehicle, include = coalesce((r ->> 'include')::boolean, true) and v_vehicle is not null and image_count > 0
     where id = v_folder and import_id = d.id;
  end loop;
  update drive_import_files f set vehicle_id = fo.vehicle_id from drive_import_folders fo
   where f.folder_id = fo.id and f.import_id = d.id and f.state = 'pending' and fo.include and fo.vehicle_id is not null;
  update drive_import_files f set state = 'skipped', reason = 'Left out: its folder was not imported', done_at = now()
    from drive_import_folders fo where f.folder_id = fo.id and f.import_id = d.id and f.state = 'pending' and not fo.include;
  select count(*) into v_photos from drive_import_files where import_id = d.id and state = 'pending';
  if v_photos = 0 then raise exception 'Choose a car for at least one folder with photos' using errcode = '22023'; end if;
  update drive_imports set status = 'importing', next_run_at = now(), options = options || jsonb_build_object('submit', coalesce((p ->> 'submit')::boolean, coalesce((options ->> 'submit')::boolean, true)))
   where id = d.id;
  select count(*) into v_n from drive_import_folders where import_id = d.id and include;
  return jsonb_build_object('id', d.id, 'folders', v_n, 'photos', v_photos);
end $$;

create function app.drive_import_cancel(p_by uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare d drive_imports;
begin
  if not app.drive_import_may(p_by) then raise exception 'Fleet, customer service or an Admin imports listing photos' using errcode = '42501'; end if;
  select * into d from drive_imports where id = (p ->> 'import')::uuid for update;
  if d.id is null then raise exception 'Unknown import' using errcode = 'P0002'; end if;
  if d.status in ('done', 'failed', 'cancelled') then return jsonb_build_object('id', d.id, 'status', d.status); end if;
  update drive_import_files set state = 'skipped', reason = 'Cancelled', done_at = now() where import_id = d.id and state = 'pending';
  update drive_imports set status = 'cancelled', finished_at = now(), locked_at = null, totals = app.drive_import_totals(d.id) where id = d.id;
  return jsonb_build_object('id', d.id, 'status', 'cancelled');
end $$;

-- the photos that failed are tried again
create function app.drive_import_retry(p_by uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare d drive_imports; n integer;
begin
  if not app.drive_import_may(p_by) then raise exception 'Fleet, customer service or an Admin imports listing photos' using errcode = '42501'; end if;
  select * into d from drive_imports where id = (p ->> 'import')::uuid for update;
  if d.id is null then raise exception 'Unknown import' using errcode = 'P0002'; end if;
  if d.status not in ('done', 'failed') or d.scanned_at is null then raise exception 'Nothing to try again' using errcode = '23514'; end if;
  update drive_import_files set state = 'pending', reason = null, attempts = 0, retry_at = null, done_at = null where import_id = d.id and state = 'failed';
  get diagnostics n = row_count;
  if n = 0 then raise exception 'No photo failed' using errcode = '23514'; end if;
  update drive_imports set status = 'importing', error = null, finished_at = null, next_run_at = now(), locked_at = null where id = d.id;
  return jsonb_build_object('id', d.id, 'retrying', n);
end $$;

-- ================================================================ 5. what the page reads
create function app.drive_import_totals(p_import uuid) returns jsonb language sql stable security definer set search_path = public, app as $$
  select jsonb_build_object(
    'imported', count(*) filter (where state = 'done'), 'skipped', count(*) filter (where state = 'skipped'), 'failed', count(*) filter (where state = 'failed'),
    'pending', count(*) filter (where state = 'pending'), 'found', count(*),
    'cars', count(distinct vehicle_id) filter (where state = 'done'), 'bytes', coalesce(sum(size_bytes) filter (where state = 'done'), 0))
    from drive_import_files where import_id = p_import
$$;

create function app.drive_import_get(p_by uuid, p jsonb) returns jsonb
language plpgsql stable security definer set search_path = public, app as $$
declare d drive_imports;
begin
  if not app.drive_import_may(p_by) then raise exception 'Fleet, customer service or an Admin imports listing photos' using errcode = '42501'; end if;
  select * into d from drive_imports where id = (p ->> 'import')::uuid;
  if d.id is null then raise exception 'Unknown import' using errcode = 'P0002'; end if;
  return jsonb_build_object(
    'import', jsonb_build_object('id', d.id, 'kind', d.kind, 'status', d.status, 'error', d.error, 'vehicle_id', d.vehicle_id,
      'vehicle', case when d.vehicle_id is null then null else app.drive_import_car_label(d.vehicle_id) end, 'options', d.options,
      'created_at', d.created_at, 'finished_at', d.finished_at, 'scanned', d.scanned_at is not null,
      'due', d.status in ('scanning', 'importing') and d.next_run_at <= now() and (d.locked_at is null or d.locked_at < now() - interval '3 minutes'),
      'started_by', (select u.full_name from users u where u.id = d.created_by), 'totals', app.drive_import_totals(d.id)),
    'folders', coalesce((select jsonb_agg(jsonb_build_object('id', fo.id, 'name', fo.name, 'path', fo.path, 'depth', fo.depth, 'state', fo.state, 'error', fo.error, 'note', fo.note,
        'images', fo.image_count, 'other', fo.other_count, 'vehicle_id', fo.vehicle_id,
        'vehicle', case when fo.vehicle_id is null then null else app.drive_import_car_label(fo.vehicle_id) end,
        'score', fo.match_score, 'match_note', fo.match_note, 'ambiguous', fo.ambiguous, 'include', fo.include, 'candidates', fo.candidates,
        'counts', (select jsonb_build_object('pending', count(*) filter (where f.state = 'pending'), 'done', count(*) filter (where f.state = 'done'),
                     'skipped', count(*) filter (where f.state = 'skipped'), 'failed', count(*) filter (where f.state = 'failed'))
                     from drive_import_files f where f.folder_id = fo.id)) order by fo.path)
      from (select * from drive_import_folders where import_id = d.id order by path limit 500) fo), '[]'::jsonb),
    'problems', coalesce((select jsonb_agg(jsonb_build_object('name', f.name, 'path', fo.path, 'state', f.state, 'reason', f.reason) order by fo.path, f.seq)
      from (select * from drive_import_files where import_id = d.id and state in ('failed', 'skipped') order by state, seq limit 200) f
      join drive_import_folders fo on fo.id = f.folder_id), '[]'::jsonb));
end $$;

create function app.drive_import_list(p_by uuid, p jsonb) returns jsonb
language plpgsql stable security definer set search_path = public, app as $$
declare v_vehicle uuid := nullif(p ->> 'vehicle', '')::uuid;
begin
  if not app.drive_import_may(p_by) then raise exception 'Fleet, customer service or an Admin imports listing photos' using errcode = '42501'; end if;
  return coalesce((select jsonb_agg(jsonb_build_object('id', x.id, 'kind', x.kind, 'status', x.status, 'created_at', x.created_at, 'error', x.error,
            'vehicle', case when x.vehicle_id is null then null else app.drive_import_car_label(x.vehicle_id) end, 'totals', app.drive_import_totals(x.id),
            'started_by', (select u.full_name from users u where u.id = x.created_by)) order by x.created_at desc)
     from (select * from drive_imports where v_vehicle is null or vehicle_id = v_vehicle order by created_at desc limit 12) x), '[]'::jsonb);
end $$;

-- ================================================================ 6. the Worker's side (service role)
-- Takes the next run that is due (a run locked for more than 3 minutes is taken as lost) and says what to do: scan folders,
-- match the folders to cars, import photos, or (when none is left) finish.
create function app.drive_import_claim(p_worker text, p_files integer default 3, p_folders integer default 4) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare d drive_imports; v_rows jsonb; v_next timestamptz;
begin
  select * into d from drive_imports
   where status in ('scanning', 'importing') and next_run_at <= now() and (locked_at is null or locked_at < now() - interval '3 minutes')
   order by created_at limit 1 for update skip locked;
  if d.id is null then return null; end if;
  update drive_imports set locked_at = now(), locked_by = left(p_worker, 60) where id = d.id;
  if d.status = 'scanning' then
    select coalesce(jsonb_agg(jsonb_build_object('id', q.id, 'drive_id', q.drive_id, 'name', q.name, 'path', q.path, 'depth', q.depth)), '[]'::jsonb) into v_rows
      from (select * from drive_import_folders where import_id = d.id and state = 'pending' order by depth, path limit greatest(1, least(coalesce(p_folders, 4), 10))) q;
    if jsonb_array_length(v_rows) > 0 then
      return jsonb_build_object('phase', 'scan', 'import', jsonb_build_object('id', d.id, 'kind', d.kind), 'folders', v_rows, 'limits', app.drive_import_limits());
    end if;
    return jsonb_build_object('phase', 'match', 'import', jsonb_build_object('id', d.id, 'kind', d.kind), 'folders', (
      select coalesce(jsonb_agg(jsonb_build_object('id', fo.id, 'name', fo.name, 'path', fo.path, 'depth', fo.depth, 'images', fo.image_count,
               'ancestors', (select coalesce(jsonb_agg(a.name order by a.depth), '[]'::jsonb) from drive_import_folders a
                              where left(fo.path, length(a.path) + 1) = a.path || '/' and a.import_id = d.id and a.depth > 0))
               order by fo.path), '[]'::jsonb)
        from drive_import_folders fo where fo.import_id = d.id and fo.state = 'done'), 'limits', app.drive_import_limits());
  end if;
  -- importing
  select coalesce(jsonb_agg(jsonb_build_object('id', q.id, 'drive_id', q.drive_id, 'name', q.name, 'mime', q.mime, 'size', q.size_bytes, 'kind', q.kind, 'vehicle_id', q.vehicle_id, 'attempts', q.attempts)), '[]'::jsonb) into v_rows
    from (select f.* from drive_import_files f join drive_import_folders fo on fo.id = f.folder_id
           where f.import_id = d.id and f.state = 'pending' and (f.retry_at is null or f.retry_at <= now())
           order by fo.path, f.seq limit greatest(1, least(coalesce(p_files, 3), 8))) q;
  if jsonb_array_length(v_rows) > 0 then
    return jsonb_build_object('phase', 'import', 'import', jsonb_build_object('id', d.id, 'kind', d.kind), 'files', v_rows, 'limits', app.drive_import_limits());
  end if;
  select min(retry_at) into v_next from drive_import_files where import_id = d.id and state = 'pending';
  if v_next is not null then
    update drive_imports set locked_at = null, next_run_at = v_next where id = d.id;
    return jsonb_build_object('phase', 'wait', 'import', jsonb_build_object('id', d.id, 'kind', d.kind));
  end if;
  return jsonb_build_object('phase', 'done', 'import', jsonb_build_object('id', d.id, 'kind', d.kind), 'finish', app.drive_import_finish(d.id));
end $$;

create function app.drive_import_release(p_import uuid, p_delay_seconds integer default 0) returns void
language sql security definer set search_path = public, app as $$
  update drive_imports set locked_at = null, next_run_at = now() + make_interval(secs => greatest(0, least(coalesce(p_delay_seconds, 0), 3600))) where id = p_import
$$;

-- the whole run stops: Google refused, or a folder is not shared
create function app.drive_import_abort(p_import uuid, p_message text) returns void
language sql security definer set search_path = public, app as $$
  update drive_imports set status = 'failed', error = left(p_message, 400), locked_at = null, finished_at = now() where id = p_import and status in ('scanning', 'importing')
$$;

-- p: {error?, folders: [{id, name}], images: [{id, name, mime, size, kind, skip?}], ignored: n}; limits from app.drive_import_limits()
create function app.drive_import_folder_result(p_folder uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  fo drive_import_folders; d drive_imports; e jsonb; v_lim jsonb := app.drive_import_limits();
  v_folders integer; v_files integer; v_note text := null; v_seq integer := 0; v_path text; v_skip text;
begin
  select * into fo from drive_import_folders where id = p_folder;
  if fo.id is null then return jsonb_build_object('ignored', true); end if;
  select * into d from drive_imports where id = fo.import_id for update;
  if d.status <> 'scanning' or fo.state <> 'pending' then return jsonb_build_object('ignored', true); end if;
  if nullif(p ->> 'error', '') is not null then
    update drive_import_folders set state = 'failed', error = left(p ->> 'error', 300) where id = fo.id;
    if fo.parent_id is null then
      update drive_imports set status = 'failed', error = left(p ->> 'error', 300), finished_at = now(), locked_at = null where id = d.id;
      return jsonb_build_object('failed', true);
    end if;
  else
    v_note := nullif(left(p ->> 'note', 200), '');
    -- the link's own folder is named from its page, so it can be matched like any other folder
    if fo.parent_id is null and nullif(btrim(p ->> 'title'), '') is not null then update drive_import_folders set name = left(btrim(p ->> 'title'), 160) where id = fo.id; end if;
    select count(*) into v_folders from drive_import_folders where import_id = d.id;
    for e in select value from jsonb_array_elements(app.drive_import_arr(p -> 'folders')) loop
      if fo.depth + 1 > (v_lim ->> 'max_depth')::integer then v_note := format('Folders more than %s levels down were not read', v_lim ->> 'max_depth'); continue; end if;
      if v_folders >= (v_lim ->> 'max_folders')::integer then v_note := format('More than %s folders: the rest were not read', v_lim ->> 'max_folders'); exit; end if;
      v_path := fo.path || '/' || left(coalesce(e ->> 'name', '?'), 120);
      insert into drive_import_folders (import_id, drive_id, parent_id, name, path, depth)
      values (d.id, e ->> 'id', fo.id, left(coalesce(e ->> 'name', '?'), 160), v_path, fo.depth + 1)
      on conflict (import_id, drive_id) do nothing;
      if found then v_folders := v_folders + 1; end if;
    end loop;
    select count(*) into v_files from drive_import_files where import_id = d.id;
    for e in select value from jsonb_array_elements(app.drive_import_arr(p -> 'images')) loop
      v_seq := v_seq + 1;
      v_skip := nullif(e ->> 'skip', '');
      if v_skip is null and v_files >= (v_lim ->> 'max_files')::integer then v_skip := format('More than %s photos in one import', v_lim ->> 'max_files'); end if;
      insert into drive_import_files (import_id, folder_id, drive_id, name, mime, size_bytes, kind, seq, state, reason, done_at)
      values (d.id, fo.id, e ->> 'id', left(coalesce(e ->> 'name', '?'), 200), e ->> 'mime', nullif(e ->> 'size', '')::bigint, e ->> 'kind', v_seq,
              case when v_skip is null then 'pending' else 'skipped' end, v_skip, case when v_skip is null then null else now() end)
      on conflict (import_id, drive_id) do nothing;
      if found then v_files := v_files + 1; end if;
    end loop;
    update drive_import_folders set state = 'done', note = v_note, other_count = coalesce(nullif(p ->> 'ignored', '')::integer, 0),
           image_count = (select count(*) from drive_import_files where folder_id = fo.id)
     where id = fo.id;
  end if;
  if not exists (select 1 from drive_import_folders where import_id = d.id and state = 'pending') then
    perform app.drive_import_scan_done(d.id);
  end if;
  return jsonb_build_object('ok', true);
end $$;

-- every folder is read: a car's run goes straight on; a bulk run waits to be matched
create function app.drive_import_scan_done(p_import uuid) returns void
language plpgsql security definer set search_path = public, app as $$
declare d drive_imports; v_pending integer;
begin
  select * into d from drive_imports where id = p_import for update;
  update drive_imports set scanned_at = now() where id = d.id;
  if d.kind = 'car' then
    update drive_import_folders set vehicle_id = d.vehicle_id, include = image_count > 0 where import_id = d.id;
    update drive_import_files set vehicle_id = d.vehicle_id where import_id = d.id and state = 'pending';
    select count(*) into v_pending from drive_import_files where import_id = d.id and state = 'pending';
    if v_pending = 0 then
      update drive_imports set status = 'failed', finished_at = now(), locked_at = null,
             error = 'No photos were found in that folder. Check that it is shared with "Anyone with the link" and holds JPG, PNG, HEIC or WebP photos.' where id = d.id;
    else
      update drive_imports set status = 'importing', next_run_at = now() where id = d.id;
    end if;
  elsif not exists (select 1 from drive_import_files where import_id = d.id) then
    update drive_imports set status = 'failed', finished_at = now(), locked_at = null,
           error = 'No photos were found under that link. Check that the folder is shared with "Anyone with the link" and holds JPG, PNG, HEIC or WebP photos.' where id = d.id;
  end if;
end $$;

-- p: [{folder, vehicle_id, score, note, candidates, ambiguous}]: the proposal for each folder with photos
create function app.drive_import_matches(p_import uuid, p jsonb) returns void
language plpgsql security definer set search_path = public, app as $$
declare r jsonb;
begin
  for r in select value from jsonb_array_elements(app.drive_import_arr(p)) loop
    update drive_import_folders set vehicle_id = nullif(r ->> 'vehicle_id', '')::uuid, match_score = nullif(r ->> 'score', '')::integer,
           match_note = left(r ->> 'note', 200), candidates = coalesce(r -> 'candidates', '[]'::jsonb), ambiguous = coalesce((r ->> 'ambiguous')::boolean, false),
           include = nullif(r ->> 'vehicle_id', '') is not null and image_count > 0
     where id = (r ->> 'folder')::uuid and import_id = p_import;
  end loop;
  update drive_imports set status = 'review', locked_at = null where id = p_import and status = 'scanning';
end $$;

-- before a photo is downloaded: is it still to do, is there a listing to put it in, which shots has the car (for the sorting)
create function app.drive_import_prepare(p_file uuid) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  f drive_import_files; d drive_imports; v_intake uuid; v_lim jsonb := app.drive_import_limits(); v_taken jsonb;
begin
  select * into f from drive_import_files where id = p_file for update;
  if f.id is null or f.state <> 'pending' or f.vehicle_id is null then return jsonb_build_object('skip', true); end if;
  select * into d from drive_imports where id = f.import_id;
  if d.status <> 'importing' then return jsonb_build_object('skip', true); end if;
  if exists (select 1 from drive_import_files x join vehicle_photos ph on ph.id = x.photo_id
              where x.vehicle_id = f.vehicle_id and x.drive_id = f.drive_id and x.state = 'done' and ph.replaced_at is null and ph.status <> 'rejected') then
    update drive_import_files set state = 'skipped', reason = 'Already imported from this Drive file', done_at = now() where id = f.id;
    return jsonb_build_object('skip', true, 'reason', 'duplicate');
  end if;
  if d.bytes_done + coalesce(f.size_bytes, 0) > (v_lim ->> 'max_total_bytes')::bigint then
    update drive_import_files set state = 'skipped', reason = 'The import reached its size limit (4 GB)', done_at = now() where id = f.id;
    return jsonb_build_object('skip', true, 'reason', 'size');
  end if;
  select id into v_intake from listing_intakes where vehicle_id = f.vehicle_id and state not in ('published', 'cancelled') order by created_at desc limit 1;
  if v_intake is null then
    begin
      v_intake := (app.start_listing_intake(d.created_by, jsonb_build_object('vehicle_id', f.vehicle_id)) ->> 'intake_id')::uuid;
    exception when others then
      update drive_import_files set state = 'failed', reason = left(regexp_replace(sqlerrm, '^.*?ERROR:\s*', ''), 240), done_at = now() where id = f.id;
      return jsonb_build_object('skip', true, 'reason', 'no_listing');
    end;
  end if;
  select coalesce(jsonb_agg(distinct shot_type), '[]'::jsonb) into v_taken from vehicle_photos
   where vehicle_id = f.vehicle_id and replaced_at is null and status <> 'rejected';
  return jsonb_build_object('skip', false, 'vehicle_id', f.vehicle_id, 'intake', v_intake, 'created_by', d.created_by, 'taken', v_taken);
end $$;

-- the photo is in storage: put it through the listing upload as a staff upload does. p: {shot_type, original_path, width, height, byte_size, mime_type, sha256}
create function app.drive_import_record(p_file uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  f drive_import_files; d drive_imports; v_intake uuid; r jsonb; v_photo uuid; v_sha text := lower(coalesce(p ->> 'sha256', ''));
begin
  select * into f from drive_import_files where id = p_file for update;
  if f.id is null or f.state <> 'pending' then return jsonb_build_object('skipped', true, 'reason', 'not pending'); end if;
  select * into d from drive_imports where id = f.import_id;
  -- two runs on the same Drive file and car at once: one goes first
  perform pg_advisory_xact_lock(hashtextextended(f.vehicle_id::text || ':' || f.drive_id, 0));
  if exists (select 1 from drive_import_files x join vehicle_photos ph on ph.id = x.photo_id
              where x.vehicle_id = f.vehicle_id and x.drive_id = f.drive_id and x.state = 'done' and x.id <> f.id and ph.replaced_at is null and ph.status <> 'rejected') then
    update drive_import_files set state = 'skipped', reason = 'Already imported from this Drive file', done_at = now() where id = f.id;
    return jsonb_build_object('skipped', true, 'reason', 'duplicate');
  end if;
  if v_sha ~ '^[0-9a-f]{64}$' and exists (select 1 from vehicle_photos ph where ph.vehicle_id = f.vehicle_id and ph.content_sha256 = v_sha and ph.replaced_at is null and ph.status <> 'rejected') then
    update drive_import_files set state = 'skipped', reason = 'The same photo is already on this car', done_at = now() where id = f.id;
    return jsonb_build_object('skipped', true, 'reason', 'same_picture');
  end if;
  select id into v_intake from listing_intakes where vehicle_id = f.vehicle_id and state not in ('published', 'cancelled') order by created_at desc limit 1;
  if v_intake is null then
    update drive_import_files set state = 'failed', reason = 'The car has no listing in progress', done_at = now() where id = f.id;
    return jsonb_build_object('failed', true);
  end if;
  begin
    r := app.record_listing_upload(d.created_by, v_intake, jsonb_strip_nulls(jsonb_build_object('shot_type', p ->> 'shot_type', 'original_path', p ->> 'original_path',
           'width', p -> 'width', 'height', p -> 'height', 'byte_size', p -> 'byte_size', 'mime_type', p ->> 'mime_type', 'sha256', nullif(v_sha, ''))));
  exception when others then
    update drive_import_files set state = 'failed', reason = left(regexp_replace(sqlerrm, '^.*?ERROR:\s*', ''), 240), done_at = now() where id = f.id;
    return jsonb_build_object('failed', true, 'reason', left(regexp_replace(sqlerrm, '^.*?ERROR:\s*', ''), 240));
  end;
  v_photo := (r ->> 'photo_id')::uuid;
  update drive_import_files set state = 'done', photo_id = v_photo, shot_type = p ->> 'shot_type', reason = null, done_at = now() where id = f.id;
  update drive_imports set bytes_done = bytes_done + coalesce(nullif(p ->> 'byte_size', '')::bigint, 0) where id = d.id;
  return jsonb_build_object('photo_id', v_photo, 'shot_type', p ->> 'shot_type', 'similar', r -> 'similar');
end $$;

-- a photo that could not be taken: retried later (a busy Drive) up to three times, else failed with the reason
create function app.drive_import_file_fail(p_file uuid, p_reason text, p_retry boolean default false) returns void
language plpgsql security definer set search_path = public, app as $$
declare f drive_import_files; v_tries integer := (app.drive_import_limits() ->> 'tries')::integer;
begin
  select * into f from drive_import_files where id = p_file for update;
  if f.id is null or f.state <> 'pending' then return; end if;
  if p_retry and f.attempts + 1 < v_tries then
    update drive_import_files set attempts = attempts + 1, reason = left(p_reason, 240), retry_at = now() + make_interval(mins => case f.attempts when 0 then 2 else 10 end) where id = f.id;
  else
    update drive_import_files set state = 'failed', attempts = attempts + 1, reason = left(p_reason, 240), done_at = now() where id = f.id;
  end if;
end $$;

create function app.drive_import_skip(p_file uuid, p_reason text) returns void
language sql security definer set search_path = public, app as $$
  update drive_import_files set state = 'skipped', reason = left(p_reason, 240), done_at = now() where id = p_file and state = 'pending'
$$;

-- nothing is left to do: the totals, and the listings whose photos are all in are submitted (default on)
create function app.drive_import_finish(p_import uuid) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  d drive_imports; r record; v_sub integer := 0; v_notes jsonb := '[]'::jsonb; v_res jsonb;
begin
  select * into d from drive_imports where id = p_import for update;
  if d.id is null or d.status <> 'importing' then return null; end if;
  if coalesce((d.options ->> 'submit')::boolean, true) then
    for r in select distinct f.vehicle_id, i.id as intake, i.submitted_at from drive_import_files f
               join listing_intakes i on i.vehicle_id = f.vehicle_id and i.state not in ('published', 'cancelled', 'approved')
              where f.import_id = d.id and f.state = 'done' loop
      if r.submitted_at is not null then continue; end if;
      begin
        perform app.submit_listing_intake(d.created_by, r.intake);
        v_sub := v_sub + 1;
      exception when others then
        v_notes := v_notes || jsonb_build_array(jsonb_build_object('vehicle', app.drive_import_car_label(r.vehicle_id), 'reason', left(regexp_replace(sqlerrm, '^.*?ERROR:\s*', ''), 200)));
      end;
    end loop;
  end if;
  v_res := app.drive_import_totals(d.id) || jsonb_build_object('submitted', v_sub, 'not_submitted', v_notes);
  update drive_imports set status = 'done', totals = v_res, finished_at = now(), locked_at = null where id = d.id;
  return v_res;
end $$;

create function app.drive_import_due() returns boolean language sql stable security definer set search_path = public, app as $$
  select exists (select 1 from drive_imports where status in ('scanning', 'importing') and next_run_at <= now() and (locked_at is null or locked_at < now() - interval '3 minutes'))
$$;

-- the Drive API key, when one is set
create function app.drive_import_key() returns text language sql stable security definer set search_path = public, app as $$
  select nullif(btrim((app.settings()).google_drive_api_key), '')
$$;

-- ================================================================ 7. the cron gate and the doors
alter function app.server_jobs_due() rename to server_jobs_due_pre0760;
create function app.server_jobs_due() returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare j jsonb := app.server_jobs_due_pre0760();
begin
  -- an import with work to do starts the listing route, which starts it (the listing route is the five-minute tick's)
  if app.drive_import_due() then j := j || jsonb_build_object('listing', true, 'drive_import', true); end if;
  return j;
end $$;
select pg_temp.copy_grants('app.server_jobs_due()'::regprocedure, 'app.server_jobs_due_pre0760()'::regprocedure);

alter function app.door(uuid, text, text, text, jsonb) rename to door_pre0760;
create function app.door(p_user uuid, p_aal text, p_call text, p_name text, p jsonb default '{}'::jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
begin
  if (p_call = 'ops_do' and p_name in ('drive_import_start', 'drive_import_confirm', 'drive_import_cancel', 'drive_import_retry'))
     or (p_call = 'ops_read' and p_name in ('drive_import_get', 'drive_import_list', 'drive_import_cars')) then
    if coalesce(p, '{}'::jsonb) ? '_va' then perform set_config('app.va_active', coalesce(p ->> '_va', ''), true); end if;
    perform app.door_begin(p_user, p_aal);
    p := coalesce(p, '{}'::jsonb) - '_va';
    return case p_name
      when 'drive_import_start' then app.drive_import_start(p_user, p)
      when 'drive_import_confirm' then app.drive_import_confirm(p_user, p)
      when 'drive_import_cancel' then app.drive_import_cancel(p_user, p)
      when 'drive_import_retry' then app.drive_import_retry(p_user, p)
      when 'drive_import_get' then app.drive_import_get(p_user, p)
      when 'drive_import_list' then app.drive_import_list(p_user, p)
      else app.drive_import_cars_for(p_user) end;
  end if;
  return app.door_pre0760(p_user, p_aal, p_call, p_name, p);
end $$;
select pg_temp.copy_grants('app.door(uuid, text, text, text, jsonb)'::regprocedure, 'app.door_pre0760(uuid, text, text, text, jsonb)'::regprocedure);

-- the server's own calls (service role)
create function public.server_drive_import_claim(p_worker text, p_files integer default 3, p_folders integer default 4) returns jsonb
language sql volatile security invoker set search_path = public, app as $$ select app.drive_import_claim(p_worker, p_files, p_folders) $$;
create function public.server_drive_import_release(p_import uuid, p_delay_seconds integer default 0) returns void
language sql volatile security invoker set search_path = public, app as $$ select app.drive_import_release(p_import, p_delay_seconds) $$;
create function public.server_drive_import_abort(p_import uuid, p_message text) returns void
language sql volatile security invoker set search_path = public, app as $$ select app.drive_import_abort(p_import, p_message) $$;
create function public.server_drive_import_folder_result(p_folder uuid, p jsonb) returns jsonb
language sql volatile security invoker set search_path = public, app as $$ select app.drive_import_folder_result(p_folder, p) $$;
create function public.server_drive_import_cars() returns jsonb
language sql stable security invoker set search_path = public, app as $$ select app.drive_import_cars() $$;
create function public.server_drive_import_matches(p_import uuid, p jsonb) returns void
language sql volatile security invoker set search_path = public, app as $$ select app.drive_import_matches(p_import, p) $$;
create function public.server_drive_import_prepare(p_file uuid) returns jsonb
language sql volatile security invoker set search_path = public, app as $$ select app.drive_import_prepare(p_file) $$;
create function public.server_drive_import_record(p_file uuid, p jsonb) returns jsonb
language sql volatile security invoker set search_path = public, app as $$ select app.drive_import_record(p_file, p) $$;
create function public.server_drive_import_file_fail(p_file uuid, p_reason text, p_retry boolean default false) returns void
language sql volatile security invoker set search_path = public, app as $$ select app.drive_import_file_fail(p_file, p_reason, p_retry) $$;
create function public.server_drive_import_skip(p_file uuid, p_reason text) returns void
language sql volatile security invoker set search_path = public, app as $$ select app.drive_import_skip(p_file, p_reason) $$;
create function public.server_drive_import_due() returns boolean
language sql stable security invoker set search_path = public, app as $$ select app.drive_import_due() $$;
create function public.server_drive_import_key() returns text
language sql stable security invoker set search_path = public, app as $$ select app.drive_import_key() $$;

-- ================================================================ 8. privileges
do $$
declare f record;
begin
  for f in
    select p.oid::regprocedure as sig from pg_proc p join pg_namespace n on n.oid = p.pronamespace
     where (n.nspname = 'app' and p.proname = any (array['drive_import_limits', 'drive_import_arr', 'drive_import_may', 'drive_import_car_label', 'drive_import_cars', 'drive_import_cars_for', 'drive_import_start',
              'drive_import_confirm', 'drive_import_cancel', 'drive_import_retry', 'drive_import_totals', 'drive_import_get', 'drive_import_list', 'drive_import_claim',
              'drive_import_release', 'drive_import_abort', 'drive_import_folder_result', 'drive_import_scan_done', 'drive_import_matches', 'drive_import_prepare',
              'drive_import_record', 'drive_import_file_fail', 'drive_import_skip', 'drive_import_finish', 'drive_import_due', 'drive_import_key',
              'server_jobs_due_pre0760', 'door_pre0760']))
        or (n.nspname = 'public' and p.proname like 'server\_drive\_import\_%')
  loop
    execute format('revoke all on function %s from public, anon, authenticated', f.sig);
    execute format('grant execute on function %s to service_role', f.sig);
  end loop;
end $$;
