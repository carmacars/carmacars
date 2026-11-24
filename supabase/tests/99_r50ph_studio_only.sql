-- 99: migration 3701 (release 50, photos): one look, enforced. The public pages show only studio renders that passed the
-- studio gate at the current standard; a car with none shows one "Photos coming soon" placeholder, never its own photos, a
-- drawn sample or a mixed set; the hero's cutouts, the emails and the feeds follow. Fixtures start with "rq50s_".
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
create or replace function test.rq50s_gate(p_pass boolean, p_spec text default 'r48.3') returns jsonb language sql as $$
  select jsonb_build_object('state', 'done', 'spec', p_spec, 'tries', 1, 'gate', jsonb_build_object('pass', p_pass, 'spec', p_spec, 'reasons', '[]'::jsonb)) $$;
create or replace function test.rq50s_g() returns jsonb language sql as $$ select app.public_listing_photos(test.id('vehicle:rq50s_a')) $$;

-- ---------------------------------------------------------------- 1. the standard
select test.eq('the standard is r48.3, as the web''s R48_SPEC', app.photo_r48_spec(), 'r48.3');
select test.eq('one plate for every outside view, none inside',
  (select string_agg(coalesce(app.photo_r48_family(s), '-'), ',') from unnest(array['front_left', 'front', 'left', 'rear_left', 'rear', 'dashboard', 'trunk']) s),
  'side,side,side,side,side,-,-');

-- ---------------------------------------------------------------- 2. an owner's photo is never public
create temp table rq50s_real as select test.rq50s_photo('front_left', false) as id;
select test.eq('a car with only its own (approved, public) photo shows one placeholder', jsonb_array_length(test.rq50s_g())::text, '1');
select test.ok('the placeholder: "Photos coming soon", the cover, marked placeholder and sample (feeds and the sitemap leave it out)',
  (select (g -> 0 ->> 'placeholder')::boolean and (g -> 0 ->> 'sample')::boolean and (g -> 0 ->> 'is_cover')::boolean and g -> 0 ->> 'label' = 'Photos coming soon'
          and (g -> 0 ->> 'path' = '/studio/coming-soon.jpg' or g -> 0 ->> 'path' like 'site/r48/plates/%') from (select test.rq50s_g() g) x));
select test.ok('the owner''s photo is not in the gallery', position((select processed_path from vehicle_photos where id = (select id from rq50s_real)) in test.rq50s_g()::text) = 0);
select test.ok('no drawn sample photo either', position('/sample-photos/' in test.rq50s_g()::text) = 0);

-- ---------------------------------------------------------------- 3. only renders that passed the gate at this standard
create temp table rq50s_r as select
  test.rq50s_photo('left', true, test.rq50s_gate(false)) as refused,
  test.rq50s_photo('front', true, test.rq50s_gate(true, 'r48.2')) as old_spec,
  test.rq50s_photo('dashboard', true, test.rq50s_gate(true)) as inside;
select test.eq('a refused render, an older standard''s render or an inside view alone: still the placeholder, never a mixed set',
  (select (g -> 0 ->> 'placeholder') || '/' || jsonb_array_length(g) from (select test.rq50s_g() g) x), 'true/1');
select test.ok('photo_render_live: the gate''s pass at the current standard',
  not (select app.photo_render_live(ph) from vehicle_photos ph where ph.id = (select refused from rq50s_r))
  and not (select app.photo_render_live(ph) from vehicle_photos ph where ph.id = (select old_spec from rq50s_r))
  and (select app.photo_render_live(ph) from vehicle_photos ph where ph.id = (select inside from rq50s_r)));

create temp table rq50s_ok as select test.rq50s_photo('left', true, test.rq50s_gate(true)) as side, test.rq50s_photo('rear', true, test.rq50s_gate(true)) as rear;
select test.eq('passed renders only, in the site''s order (the side profile first, the cover); the dashboard after the outside views',
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
update vehicle_photos set r45 = r45 || '{"gate": {"pass": false, "spec": "r48.3"}}'::jsonb where id = (select side from rq50s_ok);
select test.eq('no live render: the emails show no car picture (the name panel), never the owner''s photo',
  app.ntf_vehicle_pre0827(test.id('vehicle:rq50s_a')) ->> 'vehicle_image_url', '');
select test.ok('no live render: no cutout source', app.site_cutout_source(test.id('vehicle:rq50s_a'), 'left') is null);
select test.ok('no live render: the row''s cover is the placeholder', (app.photo_row_cover(test.id('vehicle:rq50s_a'), '{}'::jsonb) #>> '{cover,placeholder}')::boolean);
select test.ok('the channel API leaves the placeholder out, as the feeds and the sitemap do',
  position('not coalesce((e ->> ''sample'')::boolean, false)' in pg_get_functiondef('app.channel_vehicle_json(uuid, text)'::regprocedure)) > 0);

-- ---------------------------------------------------------------- 5. the gate's verdict is kept; the studio grid
select test.ok('the worker''s gate verdict is kept on the photo (3701 wraps worker_listing_result)',
  position('{output,r45,gate}' in pg_get_functiondef('app.worker_listing_result(uuid, jsonb)'::regprocedure)) > 0);
create temp table rq50s_grid as select app.photo_r48_grid(test.id('rq50s_admin'), '{"limit": 200}'::jsonb) as g;
select test.ok('the studio grid: the nine views in the site''s order, each car''s count of live views',
  (select jsonb_array_length(g -> 'order') = 9 and g ->> 'spec' = 'r48.3' from rq50s_grid));
select test.throws('only an Admin or fleet sees the studio grid', $$select app.photo_r48_grid(test.id('rq50s_cs'), '{}'::jsonb)$$, 'Admin or fleet');

-- ---------------------------------------------------------------- 6. renders made before r48.3: checked in place, not made again
create temp table rq50s_old as select test.rq50s_photo('rear_left', true, jsonb_build_object('state', 'done', 'spec', 'r48.2', 'tries', 1, 'regate', now())) as id;
select test.ok('a render waiting for its check in place stays on the site (no "Photos coming soon" while the fleet is checked)',
  (select app.photo_render_live(ph) from vehicle_photos ph where ph.id = (select id from rq50s_old)));
create temp table rq50s_q as select app.photo_r48_regate_queue(50) n;
select test.ok('the check in place is queued (bookable and trending cars first), one step with input r45.regate',
  (select n from rq50s_q) >= 1
  and exists (select 1 from listing_jobs j where j.vehicle_photo_id = (select id from rq50s_old) and j.kind = 'photo_r45' and j.status = 'queued' and (j.input #>> '{r45,regate}')::boolean));
select test.ok('queued: still on the site', (select app.photo_render_live(ph) and ph.r45 ->> 'state' = 'queued' from vehicle_photos ph where ph.id = (select id from rq50s_old)));
select test.eq('queued once only', app.photo_r48_regate_queue(50), 0);
update listing_jobs set status = 'running', locked_at = now(), locked_by = 'test' where vehicle_photo_id = (select id from rq50s_old) and kind = 'photo_r45' and status = 'queued';
select app.worker_listing_result((select id from listing_jobs where vehicle_photo_id = (select id from rq50s_old) and kind = 'photo_r45' order by created_at desc limit 1),
  jsonb_build_object('ok', true, 'output', jsonb_build_object('r45', jsonb_build_object('pass', false, 'why', 'the studio gate refused it: wall', 'regate', true,
    'gate', jsonb_build_object('pass', false, 'spec', 'r48.3', 'reasons', jsonb_build_array('wall'), 'measures', '{}'::jsonb)))));
select test.eq('refused by the gate: off the site, made again from the start',
  (select coalesce(app.photo_render_live(ph), false)::text || '/' || (ph.r45 ->> 'state') || '/' || (ph.r45 ->> 'tries') || '/' || (ph.r45 ? 'regate')::text || '/' || (ph.r45 #>> '{gate,pass}')
     from vehicle_photos ph where ph.id = (select id from rq50s_old)), 'false/redo/0/false/false');
select test.eq('the step that would check the same image again is dropped', (select count(*) from listing_jobs j where j.vehicle_photo_id = (select id from rq50s_old) and j.status = 'queued'), 0::bigint);
