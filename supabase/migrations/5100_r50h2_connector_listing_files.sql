-- 5100 (R50 hotfix 2): the connector's photo_standard answered "syntax error at or near )" (POST /api/mcp, 5 times on
-- Nov 25 from 17:13 UTC). app.comms_listing_files (3870) had one closing parenthesis too many; 3870 ran with
-- check_function_bodies off, so the body was first parsed at the first call. The same body with the parentheses balanced.
-- 99_r50h2_errors.sql now re-validates every SQL and PL/pgSQL function body, so a body like this fails the DB suite.

create or replace function app.comms_listing_files(v jsonb) returns jsonb
language sql stable security definer set search_path = public, app, pg_temp as $$
  select case when jsonb_typeof(v -> 'cars') <> 'array' or jsonb_array_length(v -> 'cars') <> 1 then v else v || jsonb_build_object('cars', jsonb_build_array((v -> 'cars' -> 0) || jsonb_build_object('images', (
    select coalesce(jsonb_agg(jsonb_build_object('photo_id', ph.id, 'shot', ph.shot_type, 'public', ph.is_public, 'cover', ph.is_cover, 'status', ph.status, 'ai_generated', ph.ai_generated,
             'image', app.comms_file('vehicle-originals', ph.original_path, coalesce(ph.shot_type, 'photo') || '-' || ph.sort_order || '.jpg'))
             order by ph.sort_order, ph.id), '[]'::jsonb)
      from vehicle_photos ph where ph.vehicle_id = ((v -> 'cars' -> 0) ->> 'vehicle_id')::uuid and ph.replaced_at is null and ph.status <> 'rejected')))) end
$$;

revoke all on function app.comms_listing_files(jsonb) from public, anon, authenticated;
grant execute on function app.comms_listing_files(jsonb) to service_role;
