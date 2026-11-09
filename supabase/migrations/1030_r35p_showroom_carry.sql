-- 1030_r35p_showroom_carry.sql
-- Release 35, part P, follow-up: "Apply showroom to every car" no longer leaves cars off the site until someone opens that
-- car's listing review. A photo made again from its kept cut-out with the car where it was keeps its plate cover (0700's
-- carry-over: the database carries the boxes and the style in vehicle_photos.plate_carry and the photo is off the site until
-- the cover is drawn on the new file, which only a browser can do). That used to happen only when a listing review was open
-- (PlateCarry). Now ops_read showroom_carry_pending lists every photo of every car waiting for its carried cover, and the
-- Showroom card on the listings page (Admin and fleet) keeps the same PlateCarry running over that list while it is open,
-- so a bulk apply puts the cars back on the site by itself. A car that moved in the frame (anything else) stays queued for a
-- plate check as before. No applied migration is edited; app.door is wrapped (_pre1030).
-- SCHEMA_MARKER follows the highest migration number.

create or replace function app.showroom_carry_pending(p_by uuid, p jsonb) returns jsonb
language plpgsql stable security definer set search_path = public, app as $$
begin
  if not (app.user_is_admin(p_by) or app.user_va_has(p_by, 'fleet', 'cs')) then
    raise exception 'Fleet, customer service or an Admin edits listing photos' using errcode = '42501';
  end if;
  return jsonb_build_object('photos', coalesce((
    select jsonb_agg(jsonb_build_object('id', x.id, 'status', x.status, 'processed_path', x.processed_path, 'plate_status', x.plate_status,
                                        'plate_carry', x.plate_carry, 'variants', x.variants) order by x.vehicle_id, x.sort_order)
      from (select ph.* from vehicle_photos ph
             where ph.plate_status = 'unchecked' and ph.replaced_at is null and ph.processed_path is not null
               and ph.status in ('processed', 'approved')
               and jsonb_array_length(coalesce(ph.plate_carry -> 'boxes', '[]'::jsonb)) > 0
               and not exists (select 1 from listing_jobs j where j.vehicle_photo_id = ph.id and j.kind = 'process_photo' and j.status in ('queued', 'running'))
             order by ph.vehicle_id, ph.sort_order limit 200) x), '[]'::jsonb));
end $$;

do $$ begin
  if not exists (select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace where n.nspname = 'app' and p.proname = 'door_pre1030') then
    alter function app.door(uuid, text, text, text, jsonb) rename to door_pre1030;
  end if;
end $$;
create or replace function app.door(p_user uuid, p_aal text, p_call text, p_name text, p jsonb default '{}'::jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
begin
  if p_call = 'ops_read' and p_name = 'showroom_carry_pending' then
    if coalesce(p, '{}'::jsonb) ? '_va' then perform set_config('app.va_active', coalesce(p ->> '_va', ''), true); end if;
    perform app.door_begin(p_user, p_aal);
    return app.showroom_carry_pending(p_user, coalesce(p, '{}'::jsonb) - '_va');
  end if;
  return app.door_pre1030(p_user, p_aal, p_call, p_name, p);
end $$;

do $$
declare v_old oid := 'app.door_pre1030(uuid, text, text, text, jsonb)'::regprocedure; g text;
begin
  execute 'revoke all on function app.door(uuid, text, text, text, jsonb) from public, anon, authenticated';
  foreach g in array array['anon', 'authenticated', 'service_role'] loop
    if has_function_privilege(g, v_old, 'execute') then execute format('grant execute on function app.door(uuid, text, text, text, jsonb) to %I', g); end if;
  end loop;
end $$;
revoke all on function app.showroom_carry_pending(uuid, jsonb), app.door_pre1030(uuid, text, text, text, jsonb) from public, anon, authenticated;
grant execute on function app.showroom_carry_pending(uuid, jsonb), app.door_pre1030(uuid, text, text, text, jsonb) to service_role;
