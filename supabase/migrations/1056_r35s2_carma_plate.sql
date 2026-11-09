-- 1056_r35s2_carma_plate.sql
-- Release 35, part S2 (docs/changes/2026-11-08-r35-showroom-v2-shift-jobs.md): the plate box cover is replaced on every
-- photo. The owner: the front plate edited out (no box, no blur patch), the rear plate the company's own CARMA Ontario
-- personalized plate in the official design, in perspective and matched to the photo (web/src/features/listing/
-- plate-photo.ts, plate-art.ts). No applied migration is edited.
--   1. The plate style "carma" (vehicle_photos.plate_style, Program settings plate_cover_style: the default now).
--   2. Every photo covered the old way is made again from its uncovered file by the worker (listing_jobs kind plate_redo):
--      the image model edits the front plate out first when it may be asked, the site's own fill otherwise; the rear plate
--      becomes CARMA. The plate check stays "covered" (no real plate readable); the new file replaces the old one only
--      while the photo is still the one the job was made for.
--   3. A cover carried over to a photo made again (0700's plate_carry, the 1054 showroom redo) is drawn the new way.
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

-- ================================================================ 1. the style
alter table vehicle_photos drop constraint if exists vehicle_photos_plate_style_check;
alter table vehicle_photos add constraint vehicle_photos_plate_style_check check (plate_style is null or plate_style in ('carma', 'cover', 'pixelate', 'blur'));
comment on column vehicle_photos.plate_style is 'How the plate was covered: carma (1056: the front plate edited out, the rear plate the company''s CARMA Ontario plate), or the older cover, pixelate, blur.';
alter table program_settings drop constraint if exists program_settings_plate_cover_style_check;
alter table program_settings add constraint program_settings_plate_cover_style_check check (plate_cover_style in ('carma', 'cover', 'pixelate', 'blur'));
alter table program_settings alter column plate_cover_style set default 'carma';
update program_settings set plate_cover_style = 'carma' where plate_cover_style <> 'carma';

alter table listing_jobs drop constraint if exists listing_jobs_kind_check;
alter table listing_jobs add constraint listing_jobs_kind_check check (kind in ('decode_vin', 'draft_copy', 'process_photo', 'resize', 'publish', 'marketing_photo', 'plate_redo'));

-- ================================================================ 3. a carried cover is drawn the new way
create function app.vehicle_photo_carry_carma() returns trigger
language plpgsql security definer set search_path = public, app as $$
begin
  if new.plate_carry is not null and jsonb_typeof(new.plate_carry) = 'object' and coalesce(new.plate_carry ->> 'style', 'cover') <> 'carma' then
    new.plate_carry := new.plate_carry || '{"style": "carma"}'::jsonb;
  end if;
  return new;
end $$;
drop trigger if exists vehicle_photos_carry_carma on vehicle_photos;
create trigger vehicle_photos_carry_carma before insert or update of plate_carry on vehicle_photos for each row execute function app.vehicle_photo_carry_carma();
update vehicle_photos set plate_carry = plate_carry where plate_carry is not null and coalesce(plate_carry ->> 'style', 'cover') <> 'carma';

-- ================================================================ 2. every photo covered the old way, made again
create function app.plate_redo_queue(p_photo uuid default null) returns integer
language plpgsql security definer set search_path = public, app as $$
declare r record; n integer := 0; v_intake uuid;
begin
  for r in
    select ph.* from vehicle_photos ph
     where (p_photo is null or ph.id = p_photo) and ph.plate_status = 'covered' and ph.replaced_at is null and ph.uncovered_path is not null
       and jsonb_typeof(ph.plate_boxes) = 'array' and jsonb_array_length(ph.plate_boxes) > 0 and coalesce(ph.plate_style, 'cover') <> 'carma'
       and not exists (select 1 from listing_jobs j where j.vehicle_photo_id = ph.id and j.kind = 'process_photo' and j.status in ('queued', 'running'))
       and not exists (select 1 from listing_jobs j where j.kind = 'plate_redo' and j.status in ('queued', 'running') and j.input #>> '{plate,photo_id}' = ph.id::text)
     order by ph.vehicle_id, ph.sort_order
  loop
    v_intake := coalesce(r.intake_id, (select i.id from listing_intakes i where i.vehicle_id = r.vehicle_id order by i.created_at desc limit 1));
    continue when v_intake is null;
    perform app.enqueue_listing_job(v_intake, 'plate_redo', null, jsonb_build_object('plate', jsonb_build_object(
      'photo_id', r.id, 'vehicle_id', r.vehicle_id, 'source', r.uncovered_path, 'prev_path', r.processed_path, 'boxes', r.plate_boxes,
      'end', case when r.shot_type like 'front%' then 'front' else 'rear' end,
      'widths', coalesce((select jsonb_agg((v ->> 'width')::integer) from jsonb_array_elements(coalesce(r.variants, '[]'::jsonb)) v where (v ->> 'width') ~ '^\d+$'), '[]'::jsonb))));
    n := n + 1;
  end loop;
  return n;
end $$;

alter function app.worker_listing_result(uuid, jsonb) rename to worker_listing_result_pre1056;
create function app.worker_listing_result(p_job uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare j listing_jobs; r jsonb; o jsonb := p #> '{output,plate}';
begin
  select * into j from listing_jobs where id = p_job;
  r := app.worker_listing_result_pre1056(p_job, p);
  if j.kind = 'plate_redo' and coalesce((p ->> 'ok')::boolean, false) and jsonb_typeof(o) = 'object'
     and (o ->> 'processed_path') ~ ('^vehicles/' || (j.input #>> '{plate,vehicle_id}') || '/') then
    -- only while the photo is still the one the job was made from (an edit or a redo since wins)
    update vehicle_photos set processed_path = o ->> 'processed_path', variants = coalesce(o -> 'variants', '[]'::jsonb), plate_style = 'carma'
     where id = (j.input #>> '{plate,photo_id}')::uuid and processed_path is not distinct from (j.input #>> '{plate,prev_path}') and plate_status = 'covered';
  end if;
  return r;
end $$;
select pg_temp.copy_grants('app.worker_listing_result(uuid, jsonb)'::regprocedure, 'app.worker_listing_result_pre1056(uuid, jsonb)'::regprocedure);

revoke all on function app.vehicle_photo_carry_carma(), app.plate_redo_queue(uuid), app.worker_listing_result_pre1056(uuid, jsonb) from public, anon, authenticated;
grant execute on function app.vehicle_photo_carry_carma(), app.plate_redo_queue(uuid), app.worker_listing_result_pre1056(uuid, jsonb) to service_role;

select app.plate_redo_queue();
