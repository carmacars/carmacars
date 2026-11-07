-- 0700_r33_listing_photos.sql
-- Release 33, part D (docs/changes/2026-11-07-r33-photos.md), the owner's three asks on listing photos:
--   1. The model's name behind the car, as on the sample photos: the worker's preset studio_v5 letters the name behind
--      the car on the cover and on the outside views the samples letter (web/src/features/listing/lettering.ts,
--      letteringName: "CLA-Class" is lettered CLA, "C-Class" C CLASS). The job context now says whether the photo is the
--      cover. "Frame the outside photos again" makes the photos framed before studio_v5 again (on request only).
--   2. Any number of extra photos: "More outside photos" and "Other detail" take any number (1000), an extra photo is
--      ordered after the standard shots, staff drag the extras into their order (app.listing_photos_order), and the
--      capture screen counts the photos the way the database does (app.listing_capture: counted, min_photos).
--   3. The cut-out editor: the worker keeps the segmenter's cut-out (its alpha is the mask) and where it placed the car
--      (vehicle_photos.cutout). Staff move and size the car, erase or restore parts of the cut-out and save: the photo is
--      made again from the edited cut-out (app.photo_cutout_edit), the version before is kept (vehicle_photo_versions),
--      and the plate check carries over when the car did not move (else it is asked again). A photo made before the mask
--      was kept gets one from the worker on request (app.photo_cutout_mask). 0661 still applies: on a published listing an
--      edited photo goes back on the site once its plate is checked.
-- SCHEMA_MARKER 0701 (with the guides of 0701). No applied migration is edited.

-- ================================================================ columns and the versions kept
alter table vehicle_photos
  add column if not exists cutout jsonb,
  add column if not exists edit_version integer not null default 0,
  add column if not exists plate_carry jsonb;
comment on column vehicle_photos.cutout is 'The studio cut-out (0700): auto_mask (the segmenter''s PNG, private; its alpha is the mask), mask (the cut-out edited by staff, private), adjust (dx, dy as shares of the frame, scale) and place (where the worker drew the car on the 1800 x 1200 frame).';
comment on column vehicle_photos.edit_version is 'How many times staff saved the cut-out editor on this photo (0700); the file names of an edited photo carry it, so the version before is kept.';
comment on column vehicle_photos.plate_carry is 'The plate cover of the version before an edit that did not move the car (0700): the review puts it on the new file by itself.';

create table if not exists vehicle_photo_versions (
  id              uuid primary key default gen_random_uuid(),
  photo_id        uuid not null references vehicle_photos (id) on delete cascade,
  version         integer not null,
  processed_path  text,
  variants        jsonb,
  preset_version  text,
  uncovered_path  text,
  plate_status    text,
  plate_boxes     jsonb,
  plate_style     text,
  cutout          jsonb,
  reason          text not null default 'cutout_edit',
  created_by      uuid,
  created_at      timestamptz not null default now(),
  unique (photo_id, version)
);
comment on table vehicle_photo_versions is 'A listing photo as it was before staff saved the cut-out editor (0700): its files stay in storage.';
alter table vehicle_photo_versions enable row level security;
create policy admin_all on vehicle_photo_versions for all to authenticated using (app.is_admin()) with check (app.is_admin());
create trigger audit_vehicle_photo_versions after insert or update or delete on vehicle_photo_versions for each row execute function app.audit_row();
revoke all on vehicle_photo_versions from anon, authenticated;
grant select, insert, update, delete on vehicle_photo_versions to service_role;

-- ================================================================ 2. any number of extra photos
alter table listing_shot_types drop constraint if exists listing_shot_types_max_count_check;
alter table listing_shot_types add constraint listing_shot_types_max_count_check check (max_count between 1 and 1000);
update listing_shot_types set max_count = 1000 where code in ('other', 'exterior_more');
-- the extras' order: after every standard shot (seq * 100), in the order staff give them
create or replace function app.photo_is_extra(p_shot text) returns boolean language sql immutable as $$ select p_shot in ('other', 'exterior_more') $$;

do $$ begin
  if not exists (select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace where n.nspname = 'app' and p.proname = 'record_listing_upload_pre0700') then
    alter function app.record_listing_upload(uuid, uuid, jsonb) rename to record_listing_upload_pre0700;
  end if;
  if not exists (select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace where n.nspname = 'app' and p.proname = 'listing_capture_pre0700') then
    alter function app.listing_capture(uuid, uuid) rename to listing_capture_pre0700;
  end if;
  if not exists (select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace where n.nspname = 'app' and p.proname = 'listing_job_context_pre0700') then
    alter function app.listing_job_context(uuid) rename to listing_job_context_pre0700;
  end if;
  if not exists (select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace where n.nspname = 'app' and p.proname = 'worker_listing_result_pre0700') then
    alter function app.worker_listing_result(uuid, jsonb) rename to worker_listing_result_pre0700;
  end if;
  if not exists (select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace where n.nspname = 'app' and p.proname = 'door_pre0700') then
    alter function app.door(uuid, text, text, text, jsonb) rename to door_pre0700;
  end if;
end $$;

create function app.record_listing_upload(p_by uuid, p_intake uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare r jsonb; v_photo uuid; v_vehicle uuid;
begin
  r := app.record_listing_upload_pre0700(p_by, p_intake, p);
  v_photo := (r ->> 'photo_id')::uuid;
  if app.photo_is_extra(p ->> 'shot_type') then
    select vehicle_id into v_vehicle from vehicle_photos where id = v_photo;
    update vehicle_photos set sort_order = 100000 + coalesce((select max(x.sort_order) - 100000 from vehicle_photos x
                                                               where x.vehicle_id = v_vehicle and x.id <> v_photo and x.sort_order >= 100000), -10) + 10
     where id = v_photo;
  end if;
  return r;
end $$;

-- the extras already on file: after the standard shots, in the order they were taken
update vehicle_photos ph set sort_order = 100000 + 10 * q.n
  from (select x.id, row_number() over (partition by x.vehicle_id order by x.sort_order, x.created_at) - 1 as n
          from vehicle_photos x where app.photo_is_extra(x.shot_type)) q
 where ph.id = q.id and ph.sort_order < 100000;

-- the capture screen counts what the database counts (0566: public, not rejected, no mark on it)
create function app.listing_capture(p_by uuid, p_intake uuid) returns jsonb
language plpgsql stable security definer set search_path = public, app as $$
declare r jsonb := app.listing_capture_pre0700(p_by, p_intake);
begin
  return r || jsonb_build_object(
    'min_photos', (app.settings()).listing_min_photos,
    'counted', (select count(*) from vehicle_photos p join listing_shot_types s on s.code = p.shot_type
                 where p.vehicle_id = (r ->> 'vehicle_id')::uuid and p.replaced_at is null and p.status <> 'rejected' and s.is_public
                   and not coalesce(p.quality_flags ? 'watermark', false)));
end $$;

-- staff put the extra photos in order (the ids in the order given; any extra left out keeps its place after them)
create function app.listing_photos_order(p_by uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare v_vehicle uuid := (p ->> 'vehicle')::uuid; v_ids uuid[]; n integer := 0;
begin
  if not (app.user_is_admin(p_by) or app.user_va_has(p_by, 'fleet', 'cs')) then
    raise exception 'Fleet, customer service or an Admin edits listing photos' using errcode = '42501';
  end if;
  if v_vehicle is null or not exists (select 1 from vehicles where id = v_vehicle) then raise exception 'Unknown car' using errcode = 'P0002'; end if;
  if jsonb_typeof(p -> 'order') <> 'array' then raise exception 'The order is missing' using errcode = '22023'; end if;
  select array_agg(x::uuid order by o) into v_ids from jsonb_array_elements_text(p -> 'order') with ordinality t(x, o);
  if exists (select 1 from unnest(v_ids) i where not exists (select 1 from vehicle_photos ph where ph.id = i and ph.vehicle_id = v_vehicle and app.photo_is_extra(ph.shot_type))) then
    raise exception 'Only this car''s extra photos are put in order' using errcode = '22023';
  end if;
  update vehicle_photos ph set sort_order = 100000 + 10 * (q.o - 1)
    from unnest(v_ids) with ordinality q(id, o) where ph.id = q.id;
  get diagnostics n = row_count;
  update vehicle_photos ph set sort_order = 100000 + 10 * (cardinality(v_ids) + q.n)
    from (select x.id, row_number() over (order by x.sort_order, x.created_at) as n from vehicle_photos x
           where x.vehicle_id = v_vehicle and app.photo_is_extra(x.shot_type) and not (x.id = any (v_ids))) q
   where ph.id = q.id;
  return jsonb_build_object('vehicle', v_vehicle, 'ordered', n);
end $$;

-- ================================================================ 1 and 3. what the worker is told, what it answers
-- photo.is_cover (the lettering), photo.edit_version (an edited photo's files get new names: the version before is kept)
create function app.listing_job_context(p_job uuid) returns jsonb
language sql stable security definer set search_path = public, app as $$
  select case when x -> 'photo' is null or jsonb_typeof(x -> 'photo') <> 'object' then x
              else jsonb_set(jsonb_set(x, '{photo,is_cover}', to_jsonb(coalesce(ph.is_cover, false))), '{photo,file_base}',
                     to_jsonb((x -> 'photo' ->> 'file_base') || case when coalesce(ph.edit_version, 0) > 0 then '-v' || ph.edit_version else '' end)) end
    from (select app.listing_job_context_pre0700(p_job) x) q
    left join vehicle_photos ph on ph.id = (q.x -> 'photo' ->> 'id')::uuid
$$;

/** whether the car moved between two placements on the 1800 x 1200 frame (1% of the frame) */
create or replace function app.photo_place_moved(a jsonb, b jsonb) returns boolean language sql immutable as $$
  select a is null or b is null or jsonb_typeof(a) <> 'object' or jsonb_typeof(b) <> 'object'
      or abs(coalesce((a ->> 'left')::numeric, -1e6) - coalesce((b ->> 'left')::numeric, 1e6)) > 18
      or abs(coalesce((a ->> 'width')::numeric, -1e6) - coalesce((b ->> 'width')::numeric, 1e6)) > 18
      or abs(coalesce((a ->> 'bottom')::numeric, -1e6) - coalesce((b ->> 'bottom')::numeric, 1e6)) > 12
      or abs(coalesce((a ->> 'height')::numeric, -1e6) - coalesce((b ->> 'height')::numeric, 1e6)) > 12
$$;

create function app.worker_listing_result(p_job uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare j listing_jobs; v_prev vehicle_photos; r jsonb; v_ok boolean := coalesce((p ->> 'ok')::boolean, false);
        v_out jsonb := coalesce(p -> 'output', '{}'::jsonb); v_call uuid; v_edit boolean; v_moved boolean;
begin
  select * into j from listing_jobs where id = p_job;
  if j.kind <> 'process_photo' or j.vehicle_photo_id is null then return app.worker_listing_result_pre0700(p_job, p); end if;
  select * into v_prev from vehicle_photos where id = j.vehicle_photo_id;

  -- a mask asked for by the cut-out editor (a photo made before the mask was kept): the photo itself is left as it is
  if coalesce((j.input ->> 'mask_only')::boolean, false) then
    if v_ok then
      if j.status <> 'running' then return jsonb_build_object('job_id', j.id, 'status', j.status, 'repeat', true); end if;
      perform app.log_provider_call(j, nullif(p ->> 'provider', ''), true, null, coalesce((p ->> 'cost_microusd')::bigint, 0), (p ->> 'duration_ms')::integer);
      update listing_jobs set status = 'succeeded', output = v_out, provider = coalesce(nullif(p ->> 'provider', ''), provider),
             cost_microusd = cost_microusd + coalesce((p ->> 'cost_microusd')::bigint, 0), finished_at = now(), locked_at = null, error = null
       where id = j.id;
      update photo_jobs set status = 'succeeded', finished_at = now(), error = null, next_attempt_at = null where id = j.photo_job_id;
      if nullif(v_out ->> 'mask_path', '') is not null then
        update vehicle_photos set cutout = coalesce(cutout, '{}'::jsonb) || jsonb_build_object('auto_mask', v_out ->> 'mask_path') where id = j.vehicle_photo_id;
      end if;
      select id into v_call from provider_calls where listing_job_id = p_job order by created_at desc limit 1;
      if v_call is not null and p ? 'units' then
        update provider_calls set units = coalesce((p ->> 'units')::numeric, units), unit = coalesce(nullif(p ->> 'unit', ''), unit) where id = v_call;
      end if;
      return jsonb_build_object('job_id', j.id, 'status', 'succeeded');
    end if;
    r := app.fail_listing_job(p_job, coalesce(nullif(btrim(p ->> 'error'), ''), 'The provider failed'), coalesce((p ->> 'retryable')::boolean, true),
                              nullif(p ->> 'provider', ''), coalesce((p ->> 'cost_microusd')::bigint, 0));
    update vehicle_photos set status = v_prev.status, background_status = v_prev.background_status where id = j.vehicle_photo_id;
    return r;
  end if;

  r := app.worker_listing_result_pre0700(p_job, p);
  v_edit := j.input ? 'edit' and not coalesce((j.input -> 'edit' ->> 'reframe')::boolean, false);
  if not v_ok then
    -- an edit or a reframe that failed for good leaves the photo as it was (the version before is still its file)
    if v_prev.status in ('processed', 'approved') then
      update vehicle_photos set status = v_prev.status, background_status = v_prev.background_status
       where id = j.vehicle_photo_id and status = 'uploaded' and background_status = 'failed';
    end if;
    return r;
  end if;
  -- the cut-out and the placement, for the editor
  if v_out ? 'mask_path' or v_out ? 'place' or j.input ? 'edit' then
    update vehicle_photos set cutout = coalesce(cutout, '{}'::jsonb)
             || case when nullif(v_out ->> 'mask_path', '') is not null then jsonb_build_object('auto_mask', v_out ->> 'mask_path') else '{}'::jsonb end
             || case when jsonb_typeof(v_out -> 'place') = 'object' then jsonb_build_object('place', v_out -> 'place') else '{}'::jsonb end
             || case when j.input ? 'edit' then jsonb_build_object('mask', j.input -> 'edit' ->> 'cutout_path', 'adjust', coalesce(j.input -> 'edit' -> 'adjust', '{}'::jsonb))
                     else jsonb_build_object('mask', null, 'adjust', null) end
     where id = j.vehicle_photo_id;
  end if;
  if v_edit then
    v_moved := app.photo_place_moved(v_prev.cutout -> 'place', v_out -> 'place');
    if not v_moved and v_prev.plate_status = 'not_visible' then
      -- the same car in the same place: still no plate to read; back as it was (on the site when it was)
      update vehicle_photos set plate_status = 'not_visible', uncovered_path = null, plate_carry = null,
             status = case when v_prev.status = 'approved' then 'approved' else status end,
             is_public = case when v_prev.status = 'approved' then v_prev.is_public else is_public end
       where id = j.vehicle_photo_id;
    elsif not v_moved and v_prev.plate_status = 'covered' and jsonb_array_length(coalesce(v_prev.plate_boxes, '[]'::jsonb)) > 0 then
      -- the plate is where it was: its cover is put on the new file by the review (ListingReview, PlateCarry), which checks it
      update vehicle_photos set plate_status = 'unchecked', plate_boxes = '[]'::jsonb, plate_suggestion = null, uncovered_path = null, is_public = false,
             plate_carry = jsonb_build_object('boxes', v_prev.plate_boxes, 'style', coalesce(v_prev.plate_style, 'cover')),
             reframed_at = case when v_prev.status = 'approved' then now() else reframed_at end
       where id = j.vehicle_photo_id;
    else
      update vehicle_photos set plate_status = 'unchecked', plate_boxes = '[]'::jsonb, plate_suggestion = null, uncovered_path = null, is_public = false,
             plate_carry = null, reframed_at = case when v_prev.status = 'approved' then now() else reframed_at end
       where id = j.vehicle_photo_id;
    end if;
  end if;
  return r || jsonb_build_object('moved', v_moved);
end $$;

-- the carried cover is used once: a plate checked (or a new framing) drops it
create or replace function app.vehicle_photo_plate_carry_done() returns trigger
language plpgsql security definer set search_path = public, app as $$
begin
  if new.plate_carry is not null and new.plate_status <> 'unchecked' and old.plate_status = 'unchecked' then new.plate_carry := null; end if;
  return new;
end $$;
drop trigger if exists vehicle_photos_plate_carry_done on vehicle_photos;
create trigger vehicle_photos_plate_carry_done before update of plate_status on vehicle_photos
  for each row execute function app.vehicle_photo_plate_carry_done();

-- ================================================================ 1. framed again with studio_v5 (the lettering)
-- 0661's function with the new default preset, and a photo whose cut-out staff edited is made again from that edit
create or replace function app.listing_photos_reframe(p_by uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare v_vehicle uuid; v_preset text := coalesce(nullif(p ->> 'preset', ''), 'studio_v5'); v_all boolean := coalesce((p ->> 'all')::boolean, false);
        r record; n integer := 0;
begin
  if not (app.user_is_admin(p_by) or app.user_va_has(p_by, 'fleet', 'cs')) then
    raise exception 'Fleet, customer service or an Admin edits listing photos' using errcode = '42501';
  end if;
  v_vehicle := coalesce((p ->> 'vehicle')::uuid, (select i.vehicle_id from listing_intakes i where i.id = (p ->> 'intake')::uuid));
  if v_vehicle is null then raise exception 'Unknown listing' using errcode = 'P0002'; end if;
  for r in
    select ph.id, ph.intake_id, ph.cutout from vehicle_photos ph join listing_shot_types s on s.code = ph.shot_type
     where ph.vehicle_id = v_vehicle and ph.replaced_at is null and ph.status <> 'rejected' and ph.intake_id is not null
       and s.rebackground and s.is_public and (v_all or coalesce(ph.preset_version, '') <> v_preset)
       and not exists (select 1 from listing_jobs j where j.vehicle_photo_id = ph.id and j.kind = 'process_photo' and j.status in ('queued', 'running'))
  loop
    update vehicle_photos set background_status = 'pending', is_public = false, plate_status = 'unchecked', plate_boxes = '[]'::jsonb,
           plate_suggestion = null, uncovered_path = null, plate_carry = null, reframed_at = now()
     where id = r.id;
    perform app.enqueue_listing_job(r.intake_id, 'process_photo', r.id,
      case when nullif(r.cutout ->> 'mask', '') is not null
           then jsonb_build_object('edit', jsonb_build_object('cutout_path', r.cutout ->> 'mask', 'adjust', coalesce(r.cutout -> 'adjust', '{}'::jsonb), 'reframe', true))
           else '{}'::jsonb end);
    n := n + 1;
  end loop;
  return jsonb_build_object('vehicle', v_vehicle, 'queued', n);
end $$;

-- ================================================================ 3. the cut-out editor
create function app.photo_cutout_context(p_by uuid, p jsonb) returns jsonb
language plpgsql stable security definer set search_path = public, app as $$
declare ph vehicle_photos; s listing_shot_types; v vehicles;
begin
  if not (app.user_is_admin(p_by) or app.user_va_has(p_by, 'fleet', 'cs')) then
    raise exception 'Fleet, customer service or an Admin edits listing photos' using errcode = '42501';
  end if;
  select * into ph from vehicle_photos where id = (p ->> 'photo')::uuid;
  if ph.id is null then raise exception 'Unknown photo' using errcode = 'P0002'; end if;
  select * into s from listing_shot_types where code = ph.shot_type;
  select * into v from vehicles where id = ph.vehicle_id;
  return jsonb_build_object('id', ph.id, 'vehicle_id', ph.vehicle_id, 'shot_type', ph.shot_type, 'shot_label', s.label,
    'rebackground', coalesce(s.rebackground, false), 'is_cover', ph.is_cover, 'model', v.model, 'replaced', ph.replaced_at is not null,
    'original_path', ph.original_path, 'processed_path', ph.processed_path, 'status', ph.status, 'plate_status', ph.plate_status,
    'auto_mask', ph.cutout ->> 'auto_mask', 'mask', ph.cutout ->> 'mask', 'adjust', ph.cutout -> 'adjust', 'place', ph.cutout -> 'place',
    'edit_version', ph.edit_version, 'versions', (select count(*) from vehicle_photo_versions x where x.photo_id = ph.id),
    'pending', exists (select 1 from listing_jobs j where j.vehicle_photo_id = ph.id and j.kind = 'process_photo' and j.status in ('queued', 'running')),
    'mask_pending', exists (select 1 from listing_jobs j where j.vehicle_photo_id = ph.id and j.kind = 'process_photo' and j.status in ('queued', 'running')
                              and coalesce((j.input ->> 'mask_only')::boolean, false)));
end $$;

-- save: the edited cut-out (already in the private bucket) is made into the photo again; the version before is kept
create function app.photo_cutout_edit(p_by uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare ph vehicle_photos; s listing_shot_types; v_path text := nullif(btrim(p ->> 'cutout_path'), ''); v_adj jsonb := coalesce(p -> 'adjust', '{}'::jsonb);
        v_dx numeric; v_dy numeric; v_scale numeric;
begin
  if not (app.user_is_admin(p_by) or app.user_va_has(p_by, 'fleet', 'cs')) then
    raise exception 'Fleet, customer service or an Admin edits listing photos' using errcode = '42501';
  end if;
  select * into ph from vehicle_photos where id = (p ->> 'photo')::uuid for update;
  if ph.id is null then raise exception 'Unknown photo' using errcode = 'P0002'; end if;
  select * into s from listing_shot_types where code = ph.shot_type;
  if not coalesce(s.rebackground, false) or ph.replaced_at is not null or ph.status = 'rejected' or ph.intake_id is null then
    raise exception 'Only an outside photo on the studio background is edited here' using errcode = '23514';
  end if;
  if v_path is null or v_path !~ ('^vehicles/' || ph.vehicle_id::text || '/work/' || ph.id::text || '-edit-[a-z0-9]{6,12}\.png$') then
    raise exception 'The edited cut-out is missing' using errcode = '22023';
  end if;
  if exists (select 1 from listing_jobs j where j.vehicle_photo_id = ph.id and j.kind = 'process_photo' and j.status in ('queued', 'running')) then
    raise exception 'The photo is being made now. Try again in a minute.' using errcode = '23514';
  end if;
  v_dx := greatest(-0.5, least(0.5, coalesce((v_adj ->> 'dx')::numeric, 0)));
  v_dy := greatest(-0.5, least(0.5, coalesce((v_adj ->> 'dy')::numeric, 0)));
  v_scale := greatest(0.4, least(1.6, coalesce((v_adj ->> 'scale')::numeric, 1)));
  insert into vehicle_photo_versions (photo_id, version, processed_path, variants, preset_version, uncovered_path, plate_status, plate_boxes, plate_style, cutout, created_by)
  values (ph.id, ph.edit_version, ph.processed_path, ph.variants, ph.preset_version, ph.uncovered_path, ph.plate_status, ph.plate_boxes, ph.plate_style, ph.cutout, p_by)
  on conflict (photo_id, version) do nothing;
  update vehicle_photos set edit_version = edit_version + 1 where id = ph.id;
  perform app.enqueue_listing_job(ph.intake_id, 'process_photo', ph.id, jsonb_build_object('edit',
    jsonb_build_object('cutout_path', v_path, 'adjust', jsonb_build_object('dx', v_dx, 'dy', v_dy, 'scale', v_scale))));
  return jsonb_build_object('photo', ph.id, 'version', ph.edit_version + 1, 'queued', true);
end $$;

-- a photo made before the worker kept its mask: the worker makes one (the photo is left as it is)
create function app.photo_cutout_mask(p_by uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare ph vehicle_photos; s listing_shot_types;
begin
  if not (app.user_is_admin(p_by) or app.user_va_has(p_by, 'fleet', 'cs')) then
    raise exception 'Fleet, customer service or an Admin edits listing photos' using errcode = '42501';
  end if;
  select * into ph from vehicle_photos where id = (p ->> 'photo')::uuid;
  if ph.id is null then raise exception 'Unknown photo' using errcode = 'P0002'; end if;
  select * into s from listing_shot_types where code = ph.shot_type;
  if not coalesce(s.rebackground, false) or ph.intake_id is null then
    raise exception 'Only an outside photo on the studio background has a cut-out' using errcode = '23514';
  end if;
  if nullif(ph.cutout ->> 'auto_mask', '') is not null then return jsonb_build_object('photo', ph.id, 'queued', false, 'ready', true); end if;
  if exists (select 1 from listing_jobs j where j.vehicle_photo_id = ph.id and j.kind = 'process_photo' and j.status in ('queued', 'running')) then
    return jsonb_build_object('photo', ph.id, 'queued', false, 'pending', true);
  end if;
  perform app.enqueue_listing_job(ph.intake_id, 'process_photo', ph.id, jsonb_build_object('mask_only', true));
  return jsonb_build_object('photo', ph.id, 'queued', true);
end $$;

create function app.door(p_user uuid, p_aal text, p_call text, p_name text, p jsonb default '{}'::jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
begin
  if (p_call = 'ops_do' and p_name in ('listing_photos_order', 'photo_cutout_edit', 'photo_cutout_mask'))
     or (p_call = 'ops_read' and p_name = 'photo_cutout_context') then
    if coalesce(p, '{}'::jsonb) ? '_va' then perform set_config('app.va_active', coalesce(p ->> '_va', ''), true); end if;
    perform app.door_begin(p_user, p_aal);
    p := coalesce(p, '{}'::jsonb) - '_va';
    return case p_name
      when 'listing_photos_order' then app.listing_photos_order(p_user, p)
      when 'photo_cutout_edit' then app.photo_cutout_edit(p_user, p)
      when 'photo_cutout_mask' then app.photo_cutout_mask(p_user, p)
      else app.photo_cutout_context(p_user, p) end;
  end if;
  return app.door_pre0700(p_user, p_aal, p_call, p_name, p);
end $$;

-- ================================================================ privileges
-- the functions in place of renamed ones get the renamed ones' grants; the new ones are the service role's
do $$
declare r record; v_new regprocedure; g text;
begin
  for r in select p.oid, m.new_name, oidvectortypes(p.proargtypes) as args
             from pg_proc p join pg_namespace n on n.oid = p.pronamespace
             join (values ('record_listing_upload_pre0700', 'record_listing_upload'), ('listing_capture_pre0700', 'listing_capture'),
                          ('listing_job_context_pre0700', 'listing_job_context'), ('worker_listing_result_pre0700', 'worker_listing_result'),
                          ('door_pre0700', 'door')) m(old_name, new_name) on m.old_name = p.proname
            where n.nspname = 'app' loop
    v_new := format('app.%I(%s)', r.new_name, r.args)::regprocedure;
    execute format('revoke all on function %s from public, anon, authenticated', v_new);
    foreach g in array array['anon', 'authenticated', 'service_role'] loop
      if has_function_privilege(g, r.oid, 'execute') then execute format('grant execute on function %s to %I', v_new, g); end if;
    end loop;
  end loop;
end $$;
revoke all on function app.listing_photos_order(uuid, jsonb), app.photo_cutout_context(uuid, jsonb), app.photo_cutout_edit(uuid, jsonb),
  app.photo_cutout_mask(uuid, jsonb), app.listing_photos_reframe(uuid, jsonb), app.photo_place_moved(jsonb, jsonb), app.photo_is_extra(text), app.vehicle_photo_plate_carry_done() from public, anon, authenticated;
grant execute on function app.listing_photos_order(uuid, jsonb), app.photo_cutout_context(uuid, jsonb), app.photo_cutout_edit(uuid, jsonb),
  app.photo_cutout_mask(uuid, jsonb), app.listing_photos_reframe(uuid, jsonb), app.photo_place_moved(jsonb, jsonb), app.photo_is_extra(text), app.vehicle_photo_plate_carry_done() to service_role;
