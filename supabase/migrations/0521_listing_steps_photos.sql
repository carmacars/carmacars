-- 0521: the listing page's plain steps and the photos around them (docs/changes/2026-11-07-r27-leftovers.md, section 3).
-- Builds on 0432 (submit with the photos you have, "More outside photos" and "Other detail" up to 20 each).
--
-- 1. A photo filed under the wrong shot can be taken off: ops_do listing_photo_remove {photo}. The photo is marked
--    replaced (kept privately, never deleted: the review and the audit still see it), its cover flag goes, and the
--    shot is free for the right photo. Whoever may list the car (its owner, the field staff of its job, Fleet, an
--    Admin) or review it may do it, while the listing is not published; a published car's photos change in the
--    review (Reject). Every removal is in the audit log (listing_photo_remove).
-- 2. Two-seaters: a car with 2 seats or fewer (vehicle_listings.seats) has no rear seats, so "Rear seats" is not required for it (the missing
--    shots, the capture screen's required count, the photo problems before publishing). app.shot_required decides.
-- 3. listing_steps (ops_read, {intake}): the four steps of the listing page, "1 Photos (n of 14) > 2 Cover plates >
--    3 Review > 4 Live on the site", each with done, what is needed and the one next thing to press; the screens
--    (admin, staff, field, owner) show them instead of 0032's "Pipeline" numbers.
-- No applied migration is edited.

-- ================================================================ 2. two-seaters
create or replace function app.shot_required(p_vehicle uuid, p_code text) returns boolean
language sql stable security definer set search_path = public, app as $$
  select coalesce(s.required, false)
     and not (s.code = 'rear_seats' and coalesce((select l.seats from vehicle_listings l where l.vehicle_id = p_vehicle), 5) <= 2)
    from listing_shot_types s where s.code = p_code
$$;

create or replace function app.listing_missing_shots(p_vehicle uuid) returns text[]
language sql stable security definer set search_path = public, app as $$
  select coalesce(array_agg(s.label order by s.seq), '{}')
    from listing_shot_types s
   where s.is_active and app.shot_required(p_vehicle, s.code)
     and not exists (select 1 from vehicle_photos p where p.vehicle_id = p_vehicle and p.shot_type = s.code
                        and p.replaced_at is null and p.status <> 'rejected')
$$;

alter function app.listing_photo_problems(uuid) rename to listing_photo_problems_pre0521;
create function app.listing_photo_problems(p_vehicle uuid) returns text[]
language sql stable security definer set search_path = public, app as $$
  select coalesce(array_agg(x order by o), '{}')
    from unnest(app.listing_photo_problems_pre0521(p_vehicle)) with ordinality u(x, o)
   where not (not app.shot_required(p_vehicle, 'rear_seats')
              and x = (select s.label from listing_shot_types s where s.code = 'rear_seats') || ' photo is not processed and approved')
$$;

-- the capture screen (0032's read): the same, with each shot's required for this car and the photos' paths
create or replace function app.listing_capture(p_by uuid, p_intake uuid) returns jsonb
language plpgsql stable security definer set search_path = public, app as $$
declare
  i listing_intakes;
begin
  select * into i from listing_intakes where id = p_intake;
  if i.id is null then raise exception 'Listing intake not found' using errcode = 'P0002'; end if;
  if p_by is null or not (app.user_may_list(p_by, i.vehicle_id, 'start') or app.user_may_list(p_by, i.vehicle_id, 'review')) then
    raise exception 'Not permitted' using errcode = '42501';
  end if;
  return jsonb_build_object('intake_id', i.id, 'vehicle_id', i.vehicle_id, 'vehicle_name', app.vehicle_name(i.vehicle_id), 'state', i.state,
    'submitted', i.submitted_at is not null, 'reason', i.reason, 'review_required', i.review_required,
    'may_upload', i.state not in ('published', 'cancelled', 'approved'),
    'may_remove', i.state not in ('published', 'cancelled'),
    'missing', to_jsonb(app.listing_missing_shots(i.vehicle_id)),
    'shots', (select coalesce(jsonb_agg(jsonb_build_object('code', s.code, 'label', s.label, 'seq', s.seq, 'required', app.shot_required(i.vehicle_id, s.code),
                'max_count', s.max_count, 'guide', s.guide, 'rebackground', s.rebackground,
                'photos', (select coalesce(jsonb_agg(jsonb_build_object('id', ph.id, 'status', ph.status, 'background_status', ph.background_status,
                              'original_path', ph.original_path, 'processed_path', ph.processed_path) order by ph.sort_order), '[]'::jsonb)
                             from vehicle_photos ph where ph.vehicle_id = i.vehicle_id and ph.shot_type = s.code and ph.replaced_at is null and ph.status <> 'rejected'))
                order by s.seq), '[]'::jsonb)
                from listing_shot_types s where s.is_active),
    'progress', app.listing_progress(i.id));
end $$;

-- ================================================================ 1. take a wrongly filed photo off
create or replace function app.listing_photo_remove(p_by uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  ph vehicle_photos;
  v_state text;
begin
  select * into ph from vehicle_photos where id = (p ->> 'photo')::uuid;
  if ph.id is null then raise exception 'Photo not found' using errcode = 'P0002'; end if;
  if p_by is null or not (app.user_may_list(p_by, ph.vehicle_id, 'start') or app.user_may_list(p_by, ph.vehicle_id, 'review')) then
    raise exception 'Not permitted' using errcode = '42501';
  end if;
  if ph.replaced_at is not null then raise exception 'This photo was already taken off' using errcode = '23514'; end if;
  select l.status into v_state from vehicle_listings l where l.vehicle_id = ph.vehicle_id;
  if v_state = 'published' then
    raise exception 'The listing is live: reject the photo in the review instead' using errcode = '23514';
  end if;
  update vehicle_photos set replaced_at = now(), is_cover = false where id = ph.id;
  insert into audit_log (actor_user_id, action, entity_table, entity_id, before, after)
  values (p_by, 'listing_photo_remove', 'vehicle_photos', ph.id::text, jsonb_build_object('shot_type', ph.shot_type, 'status', ph.status, 'is_cover', ph.is_cover),
          jsonb_build_object('replaced_at', now(), 'note', 'Taken off the shot it was filed under (0521); the file is kept'));
  return jsonb_build_object('photo_id', ph.id, 'shot', ph.shot_type, 'missing', to_jsonb(app.listing_missing_shots(ph.vehicle_id)));
end $$;

-- ================================================================ 3. the four steps
create or replace function app.listing_steps(p_by uuid, p_intake uuid) returns jsonb
language plpgsql stable security definer set search_path = public, app as $$
declare
  i listing_intakes;
  v_req integer;
  v_have integer;
  v_missing text[];
  v_plates text[];
  v_plate_req boolean := coalesce((app.settings()).listing_plate_check_required, false);
  v_status text;
  v_slug text;
  v_problems integer;
  v_cur integer;
begin
  select * into i from listing_intakes where id = p_intake;
  if i.id is null then raise exception 'Listing intake not found' using errcode = 'P0002'; end if;
  if p_by is null or not (app.user_may_list(p_by, i.vehicle_id, 'start') or app.user_may_list(p_by, i.vehicle_id, 'review')) then
    raise exception 'Not permitted' using errcode = '42501';
  end if;
  select count(*) filter (where app.shot_required(i.vehicle_id, s.code)),
         count(*) filter (where app.shot_required(i.vehicle_id, s.code) and exists (select 1 from vehicle_photos p where p.vehicle_id = i.vehicle_id
                            and p.shot_type = s.code and p.replaced_at is null and p.status <> 'rejected'))
    into v_req, v_have from listing_shot_types s where s.is_active;
  v_missing := app.listing_missing_shots(i.vehicle_id);
  v_plates := app.listing_plate_problems(i.vehicle_id);
  select l.status, l.slug into v_status, v_slug from vehicle_listings l where l.vehicle_id = i.vehicle_id;
  v_problems := cardinality(app.listing_photo_problems(i.vehicle_id));
  v_cur := case when i.state = 'published' or v_status = 'published' then 5
                when i.submitted_at is null then 1
                when cardinality(v_plates) > 0 then 2
                else 3 end;
  -- a listing submitted with photos still missing stays on step 1's line as "can be added later", the review is next
  return jsonb_build_object(
    'intake_id', i.id, 'current', least(v_cur, 4), 'live', v_cur = 5, 'slug', v_slug, 'state', i.state,
    'steps', jsonb_build_array(
      jsonb_build_object('n', 1, 'key', 'photos', 'title', format('Photos (%s of %s)', v_have, v_req), 'done', i.submitted_at is not null and v_have >= v_req,
        'have', v_have, 'of', v_req,
        'need', case when i.submitted_at is null and v_have = 0 then 'Take the photos on the shot list, or submit to start with sample photos.'
                     when i.submitted_at is null then 'Add what is missing, then press Submit for listing.' || case when cardinality(v_missing) > 0 then ' Missing: ' || array_to_string(v_missing, ', ') || '.' else '' end
                     when cardinality(v_missing) > 0 then 'Submitted. Can be added later: ' || array_to_string(v_missing, ', ') || '.'
                     else 'Every required photo is in.' end),
      jsonb_build_object('n', 2, 'key', 'plates', 'title', 'Cover plates', 'done', i.submitted_at is not null and cardinality(v_plates) = 0,
        'left', cardinality(v_plates),
        'need', case when i.submitted_at is null then 'After the photos are submitted and edited.'
                     when cardinality(v_plates) > 0 then format('%s photo%s to check: cover the plate, or mark "No plate visible"%s.', cardinality(v_plates),
                            case when cardinality(v_plates) > 1 then 's' else '' end, case when v_plate_req then ' (needed before it goes live)' else '' end)
                     else 'Every outside photo is checked.' end),
      jsonb_build_object('n', 3, 'key', 'review', 'title', 'Review', 'done', i.state in ('approved', 'published') or v_status = 'published',
        'problems', v_problems,
        'need', case when i.state in ('approved', 'published') or v_status = 'published' then 'Approved.'
                     when i.state = 'needs_review' then case when v_problems > 0 then format('Ready for review: %s thing%s to look at.', v_problems, case when v_problems > 1 then 's' else '' end) else 'Ready for review: approve it.' end
                     when i.state in ('failed') then 'A step stopped: retry it below.'
                     else 'The photos and the copy are being prepared.' end),
      jsonb_build_object('n', 4, 'key', 'live', 'title', 'Live on the site', 'done', v_status = 'published',
        'need', case when v_status = 'published' then 'On the site.' when i.state = 'approved' then 'Approved: publish it.' else 'After the review.' end)));
end $$;

-- ================================================================ the door
alter function app.door(uuid, text, text, text, jsonb) rename to door_pre0521;
create function app.door(p_user uuid, p_aal text, p_call text, p_name text, p jsonb default '{}'::jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
begin
  if p_call = 'ops_do' and p_name = 'listing_photo_remove' then
    perform app.door_begin(p_user, p_aal);
    return app.listing_photo_remove(p_user, coalesce(p, '{}'::jsonb) - '_va');
  end if;
  if p_call = 'ops_read' and p_name = 'listing_steps' then
    perform app.door_begin(p_user, p_aal);
    return app.listing_steps(p_user, (p ->> 'intake')::uuid);
  end if;
  return app.door_pre0521(p_user, p_aal, p_call, p_name, p);
end $$;
do $$
declare g text;
begin
  execute 'revoke all on function app.door(uuid, text, text, text, jsonb) from public, anon, authenticated';
  foreach g in array array['anon', 'authenticated', 'service_role'] loop
    if has_function_privilege(g, 'app.door_pre0521(uuid, text, text, text, jsonb)'::regprocedure, 'execute') then
      execute format('grant execute on function app.door(uuid, text, text, text, jsonb) to %I', g);
    end if;
  end loop;
end $$;

-- ================================================================ privileges
do $$
declare g text;
begin
  execute 'revoke all on function app.listing_photo_problems(uuid) from public, anon, authenticated';
  foreach g in array array['anon', 'authenticated', 'service_role'] loop
    if has_function_privilege(g, 'app.listing_photo_problems_pre0521(uuid)'::regprocedure, 'execute') then
      execute format('grant execute on function app.listing_photo_problems(uuid) to %I', g);
    end if;
  end loop;
end $$;
do $$
declare f record;
begin
  for f in select p.oid::regprocedure as sig from pg_proc p join pg_namespace n on n.oid = p.pronamespace
            where n.nspname = 'app' and p.proname in ('shot_required', 'listing_photo_problems_pre0521', 'listing_photo_remove', 'listing_steps', 'door_pre0521') loop
    execute format('revoke all on function %s from public, anon, authenticated', f.sig);
    execute format('grant execute on function %s to service_role', f.sig);
  end loop;
end $$;
