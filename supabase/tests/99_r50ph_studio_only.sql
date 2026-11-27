-- 99: migration 3701 (release 50, photos): one look, enforced. The public pages show only studio renders that passed the
-- studio gate at the current standard; since 5064 (R50 hotfix) a car with none shows its photos as before release 50 (the
-- placeholder only when it has no photo at all), never a mixed set; the hero's cutouts, the emails and the feeds follow. Fixtures start with "rq50s_".
select test.suite('99 r50 studio only (3701)');

select test.mk_user('rq50s_admin', 'admin');
select test.mk_user('rq50s_cs', 'va', 'cs');
select test.mk_owner('rq50s_olive');
select test.mk_vehicle('rq50s_a', 'rq50s_olive');

create or replace function test.rq50s_photo(p_shot text, p_r48 boolean, p_r45 jsonb default null) returns uuid language sql as $$
  insert into vehicle_photos (vehicle_id, angle, shot_type, original_path, processed_path, status, is_public, background_status, ai_generated, r48, sort_order, r45, width, height, plate_status)
  values (test.id('vehicle:rq50s_a'), p_shot, p_shot, 'vehicles/original/rq50s/' || p_shot || '-' || md5(random()::text) || '.jpg',
          'vehicles/rq50s/' || p_shot || '-' || md5(random()::text) || '.jpg', 'approved', true, 'done', p_r48, p_r48, 0, p_r45, 1800, 1200, 'not_visible')
  returning id $$;
create or replace function test.rq50s_gate(p_pass boolean, p_spec text default null) returns jsonb language sql as $$
  select jsonb_build_object('state', 'done', 'spec', coalesce(p_spec, app.photo_r48_spec()), 'tries', 1, 'gate', jsonb_build_object('pass', p_pass, 'spec', coalesce(p_spec, app.photo_r48_spec()), 'reasons', '[]'::jsonb)) $$;
create or replace function test.rq50s_g() returns jsonb language sql as $$ select app.public_listing_photos(test.id('vehicle:rq50s_a')) $$;

-- ---------------------------------------------------------------- 1. the standard
select test.eq('the standard is r48.4 (5080), as the web''s R48_SPEC', app.photo_r48_spec(), 'r48.4');
select test.eq('one plate for every outside view, none inside',
  (select string_agg(coalesce(app.photo_r48_family(s), '-'), ',') from unnest(array['front_left', 'front', 'left', 'rear_left', 'rear', 'dashboard', 'trunk']) s),
  'side,side,side,side,side,-,-');

-- ---------------------------------------------------------------- 2. no live render: the photos as before release 50 (5064)
create temp table rq50s_real as select test.rq50s_photo('front_left', false) as id;
select test.ok('5064: a car with only its own photo shows it (as before release 50), never the empty plate',
  position((select processed_path from vehicle_photos where id = (select id from rq50s_real)) in test.rq50s_g()::text) > 0
  and not coalesce((test.rq50s_g() -> 0 ->> 'placeholder')::boolean, false));
select test.eq('5064: and its gallery is the one before release 50', test.rq50s_g(), app.photo_fallback_gallery(test.id('vehicle:rq50s_a')));
select test.eq('5064: no live render', app.photo_has_live_render(test.id('vehicle:rq50s_a')), false);

-- ---------------------------------------------------------------- 3. only renders that passed the gate at this standard
create temp table rq50s_r as select
  test.rq50s_photo('left', true, test.rq50s_gate(false)) as refused,
  test.rq50s_photo('front', true, test.rq50s_gate(true, 'r48.2')) as old_spec,
  test.rq50s_photo('dashboard', true, test.rq50s_gate(true)) as inside;
select test.ok('5064: a refused render, an older standard''s render or an inside view alone: the photos as before release 50, never the empty plate',
  test.rq50s_g() = app.photo_fallback_gallery(test.id('vehicle:rq50s_a')) and not coalesce((test.rq50s_g() -> 0 ->> 'placeholder')::boolean, false)
  and position((select processed_path from vehicle_photos where id = (select id from rq50s_real)) in test.rq50s_g()::text) > 0);
select test.ok('5064: a refused render is never in the fallback gallery',
  position((select processed_path from vehicle_photos where id = (select refused from rq50s_r)) in test.rq50s_g()::text) = 0);
select test.ok('5064: nor an older standard''s render', position((select processed_path from vehicle_photos where id = (select old_spec from rq50s_r)) in test.rq50s_g()::text) = 0);
select test.ok('5064: nor the row''s cover, even when the row before release 50 had it as its cover',
  app.photo_row_cover(test.id('vehicle:rq50s_a'), jsonb_build_object('cover', jsonb_build_object('path', (select processed_path from vehicle_photos where id = (select refused from rq50s_r)), 'sample', false))) #>> '{cover,path}'
    is distinct from (select processed_path from vehicle_photos where id = (select refused from rq50s_r)));
select test.ok('5064: the inside render that is live is never the only photo (no outside render: the fallback)',
  not app.photo_has_live_render(test.id('vehicle:rq50s_a')));
select test.ok('photo_render_live: the gate''s pass at the current standard',
  not (select app.photo_render_live(ph) from vehicle_photos ph where ph.id = (select refused from rq50s_r))
  and not (select app.photo_render_live(ph) from vehicle_photos ph where ph.id = (select old_spec from rq50s_r))
  and (select app.photo_render_live(ph) from vehicle_photos ph where ph.id = (select inside from rq50s_r)));

create temp table rq50s_ok as select test.rq50s_photo('left', true, test.rq50s_gate(true)) as side, test.rq50s_photo('rear', true, test.rq50s_gate(true)) as rear;
select test.eq('passed renders only, in the site''s order (5080: the sample order; here the side profile first of those live, the cover); the dashboard after the outside views',
  (select string_agg((e ->> 'shot') || ':' || (e ->> 'is_cover'), ',' order by n) from jsonb_array_elements(test.rq50s_g()) with ordinality t(e, n)), 'left:true,rear:false,dashboard:false');
select test.ok('every public photo is a render (generated), none the owner''s, no placeholder',
  (select bool_and(coalesce((e ->> 'generated')::boolean, false)) and not bool_or(coalesce((e ->> 'placeholder')::boolean, false)) from jsonb_array_elements(test.rq50s_g()) e)
  and position((select processed_path from vehicle_photos where id = (select id from rq50s_real)) in test.rq50s_g()::text) = 0);
update vehicle_photos set is_public = false where id = (select rear from rq50s_ok);
select test.eq('a render taken off the site is gone from the gallery', (select count(*)::text from jsonb_array_elements(test.rq50s_g()) e where e ->> 'shot' = 'rear'), '0');
update vehicle_photos set r45 = r45 || '{"state": "flagged"}'::jsonb, is_public = true where id = (select rear from rq50s_ok);
select test.eq('a flagged render is never public', (select count(*)::text from jsonb_array_elements(test.rq50s_g()) e where e ->> 'shot' = 'rear'), '0');

-- ---------------------------------------------------------------- 4. the listing row, the hero, the emails, the feeds
select test.ok('the row''s cover is the gallery''s first photo (the side render), not a sample',
  (select r #>> '{cover,path}' = (select processed_path from vehicle_photos where id = (select side from rq50s_ok))
          and not (r ->> 'sample_photos')::boolean and (r #>> '{cover,generated}')::boolean
     from (select app.photo_row_cover(test.id('vehicle:rq50s_a'), '{}'::jsonb) r) x));
select test.eq('the hero''s cutout source is the live side render only (never an owner''s, a check-in or a stock photo)',
  app.site_cutout_source(test.id('vehicle:rq50s_a'), 'left') ->> 'path', (select processed_path from vehicle_photos where id = (select side from rq50s_ok)));
select test.ok('the studio cover (the hero''s turns) is the live side render', (app.photo_r48_cover(test.id('vehicle:rq50s_a'))).id = (select side from rq50s_ok));
select test.ok('the emails'' car picture is the live render',
  app.ntf_vehicle_pre0827(test.id('vehicle:rq50s_a')) ->> 'vehicle_image_url' like '%' || (select processed_path from vehicle_photos where id = (select side from rq50s_ok)));
update vehicle_photos set r45 = r45 || '{"gate": {"pass": false, "spec": "r48.4"}}'::jsonb where id = (select side from rq50s_ok);
select test.eq('no live render: the emails show no car picture (the name panel), never the owner''s photo',
  app.ntf_vehicle_pre0827(test.id('vehicle:rq50s_a')) ->> 'vehicle_image_url', '');
select test.ok('no live render: no cutout source', app.site_cutout_source(test.id('vehicle:rq50s_a'), 'left') is null);
select test.eq('5064: no live render: the row keeps its cover from before release 50',
  app.photo_row_cover(test.id('vehicle:rq50s_a'), '{"cover": {"path": "vehicles/rq50s/before.jpg", "sample": false}}'::jsonb) #>> '{cover,path}', 'vehicles/rq50s/before.jpg');
select test.ok('5064: no live render and no cover at all: the placeholder, never an empty card',
  (app.photo_row_cover(test.id('vehicle:rq50s_a'), '{}'::jsonb) #>> '{cover,path}') is not null);
select test.ok('the channel API leaves the placeholder out, as the feeds and the sitemap do',
  position('not coalesce((e ->> ''sample'')::boolean, false)' in pg_get_functiondef('app.channel_vehicle_json(uuid, text)'::regprocedure)) > 0);

-- ---------------------------------------------------------------- 5. the gate's verdict is kept; the studio grid
select test.ok('the worker''s gate verdict is kept on the photo (3701 wraps worker_listing_result; 5080 wraps it again)',
  position('{output,r45,gate}' in pg_get_functiondef(to_regprocedure('app.worker_listing_result_pre5080(uuid, jsonb)'))) > 0);
create temp table rq50s_grid as select app.photo_r48_grid(test.id('rq50s_admin'), '{"limit": 200}'::jsonb) as g;
select test.ok('the studio grid: the eight views in the sample photos'' order (5080 / REQ-001), each car''s count of live views',
  (select jsonb_array_length(g -> 'order') = 8 and g ->> 'spec' = app.photo_r48_spec() from rq50s_grid));
select test.throws('only an Admin or fleet sees the studio grid', $$select app.photo_r48_grid(test.id('rq50s_cs'), '{}'::jsonb)$$, 'Admin or fleet');

-- ---------------------------------------------------------------- 6. renders made before r48.4: made again (5080; 3701 checked them in place)
create temp table rq50s_old as select test.rq50s_photo('rear_left', true, jsonb_build_object('state', 'done', 'spec', 'r48.2', 'tries', 1, 'regate', now())) as id;
select test.ok('5080: a render of an older standard is never on the site, even marked for the check in place',
  not (select app.photo_render_live(ph) from vehicle_photos ph where ph.id = (select id from rq50s_old)));
select test.eq('5080: no check in place is queued', app.photo_r48_regate_queue(50), 0);
