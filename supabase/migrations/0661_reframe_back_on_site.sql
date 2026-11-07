-- 0661_reframe_back_on_site.sql
-- Hotfix of 0660 (docs/changes/2026-11-07-reframe-back-on-site.md). "Frame the outside photos again" on a published
-- listing took the outside photos off the site until approved again, but a published listing shows no review controls
-- (they show only while a listing is under review): the photos stayed off the site. Now a photo made again by that
-- button (vehicle_photos.reframed_at) goes back on the site by itself once its plate is checked (covered or marked not
-- visible) while its listing is published or paused, the way an approved photo does (0070's plate rule). The photos
-- made again and checked before this fix are put back here.
-- SCHEMA_MARKER 0661. No applied migration is edited.

alter table vehicle_photos add column if not exists reframed_at timestamptz;
comment on column vehicle_photos.reframed_at is 'When staff asked to frame this approved outside photo again (0660, 0661): it goes back on the site by itself once its plate is checked on the new file, while the listing is published or paused.';

-- 1. the button marks the photos it sends to be made again (0660's function, one line added)
create or replace function app.listing_photos_reframe(p_by uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare v_vehicle uuid; v_preset text := coalesce(nullif(p ->> 'preset', ''), 'studio_v4'); v_all boolean := coalesce((p ->> 'all')::boolean, false);
        r record; n integer := 0;
begin
  if not (app.user_is_admin(p_by) or app.user_va_has(p_by, 'fleet', 'cs')) then
    raise exception 'Fleet, customer service or an Admin edits listing photos' using errcode = '42501';
  end if;
  v_vehicle := coalesce((p ->> 'vehicle')::uuid, (select i.vehicle_id from listing_intakes i where i.id = (p ->> 'intake')::uuid));
  if v_vehicle is null then raise exception 'Unknown listing' using errcode = 'P0002'; end if;
  for r in
    select ph.id, ph.intake_id from vehicle_photos ph join listing_shot_types s on s.code = ph.shot_type
     where ph.vehicle_id = v_vehicle and ph.replaced_at is null and ph.status <> 'rejected' and ph.intake_id is not null
       and s.rebackground and s.is_public and (v_all or coalesce(ph.preset_version, '') <> v_preset)
       and not exists (select 1 from listing_jobs j where j.vehicle_photo_id = ph.id and j.kind = 'process_photo' and j.status in ('queued', 'running'))
  loop
    update vehicle_photos set background_status = 'pending', is_public = false, plate_status = 'unchecked', plate_boxes = '[]'::jsonb,
           plate_suggestion = null, uncovered_path = null, reframed_at = now()
     where id = r.id;
    perform app.enqueue_listing_job(r.intake_id, 'process_photo', r.id);
    n := n + 1;
  end loop;
  return jsonb_build_object('vehicle', v_vehicle, 'queued', n);
end $$;

-- 2. 0070's plate rule, plus: a photo made again goes back on the site (approved) once its plate is checked
create or replace function app.vehicle_photo_plate_public() returns trigger
language plpgsql security definer set search_path = public, app as $$
begin
  if not (app.settings()).listing_plate_check_required then return new; end if;
  -- an example car's photos are the static sample pictures (0065): no plate to check
  if exists (select 1 from vehicles v where v.id = new.vehicle_id and v.is_sample) then return new; end if;
  if new.plate_status = 'unchecked' and new.is_public then
    new.is_public := false;
  elsif tg_op = 'UPDATE' and old.plate_status = 'unchecked' and new.plate_status in ('covered', 'not_visible')
        and (new.status = 'approved' or (new.status = 'processed' and new.reframed_at is not null))
        and new.replaced_at is null and not new.is_public
        and exists (select 1 from vehicle_listings l where l.vehicle_id = new.vehicle_id and l.status in ('published', 'paused')) then
    new.status := 'approved';
    new.is_public := coalesce((select st.is_public from listing_shot_types st where st.code = new.shot_type), false);
  end if;
  return new;
end $$;

-- 3. the photos made again by 0660's button and checked already: back on the site (the same rule, once)
update vehicle_photos ph set reframed_at = coalesce(ph.reframed_at, now())
 where ph.reframed_at is null and ph.status = 'processed' and ph.replaced_at is null and ph.preset_version = 'studio_v4'
   and exists (select 1 from listing_jobs j where j.vehicle_photo_id = ph.id and j.kind = 'process_photo' and j.status = 'succeeded'
                and j.finished_at >= timestamptz '2026-11-07 00:00 America/Toronto')
   and exists (select 1 from vehicle_listings l where l.vehicle_id = ph.vehicle_id and l.status in ('published', 'paused'));
update vehicle_photos ph set status = 'approved',
       is_public = coalesce((select st.is_public from listing_shot_types st where st.code = ph.shot_type), false)
 where ph.reframed_at is not null and ph.status = 'processed' and ph.replaced_at is null
   and ph.plate_status in ('covered', 'not_visible') and not ph.is_public
   and exists (select 1 from vehicle_listings l where l.vehicle_id = ph.vehicle_id and l.status in ('published', 'paused'));
