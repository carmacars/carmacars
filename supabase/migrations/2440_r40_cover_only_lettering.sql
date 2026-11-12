-- 2440_r40_cover_only_lettering.sql
-- Release 40 (the owner, Nov 12: "Only the first photo out of the car photos should have the name of the car, and the model
-- of the vehicle being too long is still not fixed"). The code now letters the model's name behind the cover (first) photo
-- only, and as a short display name (web/src/features/car/studio.ts letteringName). Photos already made are made again once,
-- from their kept cut-outs (0990's photo_scene_queue: the version before is kept, the plate check carries over when the
-- car stays where it was): (1) every outside photo that is not the cover and was made in the old studio, which lettered the
-- named views; (2) every cover, so its name is the short one. Photos of the sample cars are drawn files, not touched here.
-- No applied migration is edited.
do $$
declare r record;
begin
  for r in
    select x.id from vehicle_photos x join listing_shot_types s on s.code = x.shot_type join vehicles c on c.id = x.vehicle_id
     where not coalesce(c.is_sample, false) and x.replaced_at is null and x.status <> 'rejected' and x.intake_id is not null
       and s.rebackground and s.is_public and x.processed_path is not null
       and ((x.is_cover and coalesce(x.scene, 'studio') = 'showroom')
            or (not x.is_cover and coalesce(x.preset_version, '') not like '%showroom%'))
       and not exists (select 1 from listing_jobs j where j.vehicle_photo_id = x.id and j.kind = 'process_photo' and j.status in ('queued', 'running'))
     order by x.vehicle_id, x.sort_order
  loop
    perform app.photo_scene_queue(null, r.id, 'showroom', 'showroom');
  end loop;
end $$;
