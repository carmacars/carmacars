-- 1054_r35s2_showroom_everywhere.sql
-- Release 35, part S2 (docs/changes/2026-11-08-r35-showroom-v2-shift-jobs.md): the owner: every car photo on the site in
-- the showroom v2, nothing on the old studio or a plain background. The sample cars' and the body types' images are
-- files of the site (web/public/sample-photos, drawn by src/features/car/studio.ts); here, every real car's outside photo
-- still on the black studio (or on the first showroom) is made again in the showroom v2, from its kept cut-out (0990's
-- photo_scene_queue: the version before is kept, the plate check carries over when the car stays where it was), and a
-- car's photos not made yet take the showroom too. No applied migration is edited.
do $$
declare r record;
begin
  for r in
    select x.id from vehicle_photos x join listing_shot_types s on s.code = x.shot_type join vehicles c on c.id = x.vehicle_id
     where not coalesce(c.is_sample, false) and x.replaced_at is null and x.status <> 'rejected' and x.intake_id is not null
       and s.rebackground and s.is_public and x.processed_path is not null
       and (coalesce(x.scene, 'studio') <> 'showroom' or coalesce(x.preset_version, '') <> 'studio_showroom_v2')
       and not exists (select 1 from listing_jobs j where j.vehicle_photo_id = x.id and j.kind = 'process_photo' and j.status in ('queued', 'running'))
     order by x.vehicle_id, x.sort_order
  loop
    perform app.photo_scene_queue(null, r.id, 'showroom', 'showroom');
  end loop;
  update vehicle_photos x set scene = 'showroom'
   where coalesce(x.scene, 'studio') <> 'showroom' and x.replaced_at is null
     and not exists (select 1 from vehicles c where c.id = x.vehicle_id and coalesce(c.is_sample, false));
end $$;
