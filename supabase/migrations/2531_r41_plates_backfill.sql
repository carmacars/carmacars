-- 2531_r41_plates_backfill.sql (release 41, docs/changes/2026-11-12-r41-plates-auto.md)
-- Once, after 2530:
--   1. The Lamborghini Urus listing (review d7fb3388-5c28-40bb-a716-582f499a67b4): its front-left photo, plate visible, was
--      marked "No plate visible" by hand on Nov 12 by mistake. That one photo is "Plate not checked" again (it leaves the
--      site until its plate is covered, 0070), so the automatic check covers it. The photo: the current front-left shot of
--      that listing's car, else the car's cover photo, else its first outside photo by sort order; only while it is still
--      "No plate visible" by a person since Nov 12 (a decision made since, a cover, is kept). Audited.
--   2. Every photo whose plate is not checked is queued for the automatic check (plate_auto, after every other step; the
--      day's AI share is kept: a job the model cannot be asked for waits an hour). Queuing again changes nothing: an open job
--      is kept, an answer already given for the same file is not asked again.
do $$
declare
  v_intake uuid := 'd7fb3388-5c28-40bb-a716-582f499a67b4';
  v_vehicle uuid;
  ph vehicle_photos;
  n integer;
begin
  select vehicle_id into v_vehicle from listing_intakes where id = v_intake;
  if v_vehicle is not null then
    select x.* into ph from vehicle_photos x join listing_shot_types st on st.code = x.shot_type
     where x.vehicle_id = v_vehicle and x.replaced_at is null and x.status <> 'rejected' and st.is_public
       and (x.shot_type = 'front_left' or x.is_cover or st.rebackground)
     order by (x.shot_type = 'front_left') desc, (x.intake_id = v_intake) desc, x.is_cover desc, x.sort_order, x.created_at
     limit 1;
    if ph.id is not null and ph.plate_status = 'not_visible' and ph.plate_checked_by is not null and ph.plate_checked_at >= '2026-11-12'::date then
      update vehicle_photos set plate_status = 'unchecked', plate_checked_by = null, plate_checked_at = null, plate_auto = null where id = ph.id;
      insert into audit_log (actor_user_id, action, entity_table, entity_id, before, after)
      values (null, 'photo_plate_reset', 'vehicle_photos', ph.id,
              jsonb_build_object('plate_status', ph.plate_status, 'plate_checked_by', ph.plate_checked_by, 'plate_checked_at', ph.plate_checked_at),
              jsonb_build_object('plate_status', 'unchecked', 'by', 'migration 2531', 'why', 'front-left photo with a visible plate marked "No plate visible" by mistake'));
      raise notice '2531: photo % (%, sort order %) of the Urus is "Plate not checked" again', ph.id, ph.shot_type, ph.sort_order;
    else
      raise notice '2531: the Urus photo was not reset (photo %, plate %)', ph.id, ph.plate_status;
    end if;
  end if;
  n := app.plate_auto_queue();
  insert into audit_log (actor_user_id, action, entity_table, entity_id, after)
  values (null, 'plate_auto_queue', 'listing_jobs', null, jsonb_build_object('queued', n, 'by', 'migration 2531'));
  raise notice '2531: % photos queued for the automatic plate check', n;
end $$;
