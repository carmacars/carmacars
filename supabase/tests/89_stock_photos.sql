-- 89: licensed stock photos for the vehicle pages (migration 0149, docs/changes/2026-10-24-seo-photos.md). The
-- licence guard, the page's read (the generation of that model year only, the newest on a model page, the most
-- popular model on a make page, nothing when off), the pipeline's targets, save and pending requests, the generic
-- photos, coverage, and Admin's hide, show, replace and pick again through the door. Fixtures start with "sp37".
select test.suite('89 stock photos');
select test.mk_user('sp37_admin', 'admin');
select test.mk_user('sp37_cs', 'va', 'cs');

insert into vehicle_catalog_makes (slug, name) values ('sp37make', 'Sp37make');
insert into vehicle_catalog_models (make_slug, slug, name, key) values ('sp37make', 'alpha', 'Alpha', 'alpha'), ('sp37make', 'beta', 'Beta', 'beta');
insert into vehicle_catalog_years (make_slug, model_slug, year) select 'sp37make', 'alpha', y from generate_series(2012, 2024) y;
insert into vehicle_catalog_years (make_slug, model_slug, year) select 'sp37make', 'beta', y from generate_series(2020, 2024) y;
insert into vehicle_catalog_popular (make_slug, model_slug, sort) values ('sp37make', 'beta', -100);

-- ---------------------------------------------------------------- 1. the table's guards
select test.throws('licence: non-commercial is refused by the table',
  $$insert into vehicle_stock_photos (make, model, file_title, source_url, author, licence, status) values ('sp37make', 'alpha', 'File:x.jpg', 'https://commons.wikimedia.org/wiki/File:x.jpg', 'A', 'CC BY-NC 2.0', 'failed')$$, null);
select test.throws('source: an https address',
  $$insert into vehicle_stock_photos (make, model, file_title, source_url, author, licence, status) values ('sp37make', 'alpha', 'File:x.jpg', 'http://example.com/x.jpg', 'A', 'CC BY 2.0', 'failed')$$, null);
select test.throws('active: only once stored (path, widths, size)',
  $$insert into vehicle_stock_photos (make, model, file_title, source_url, author, licence) values ('sp37make', 'alpha', 'File:x.jpg', 'https://commons.wikimedia.org/wiki/File:x.jpg', 'A', 'CC BY 2.0')$$, null);

-- ---------------------------------------------------------------- 2. the pipeline saves a model
create table test.sp37 (k text primary key, v jsonb);
insert into test.sp37 select 'targets', app.stock_photo_targets('{"limit": 5000}');
select test.ok('targets: both fixture models, the popular one first',
  (select min(ord) filter (where x ->> 'model' = 'beta') < min(ord) filter (where x ->> 'model' = 'alpha')
     from jsonb_array_elements((select v from test.sp37 where k = 'targets')) with ordinality t(x, ord) where x ->> 'make' = 'sp37make'));
select test.eq('targets: the catalog years of the model',
  (select x ->> 'first_year' || '-' || (x ->> 'last_year') from jsonb_array_elements((select v from test.sp37 where k = 'targets')) x where x ->> 'make' = 'sp37make' and x ->> 'model' = 'alpha'), '2012-2024');

select test.eq('save: two generations, nothing old to delete',
  app.stock_photo_save('{"make":"sp37make","model":"alpha","wikidata":"Q1","note":"2 generations","rows":[
    {"year_from":2012,"year_to":2017,"generation":"Alpha (A1)","wikidata":"Q11","category":"Alpha (A1)","file_title":"File:Alpha A1 front.jpg","source_url":"https://commons.wikimedia.org/wiki/File:Alpha_A1_front.jpg","author":"Ann","licence":"CC BY-SA 4.0","licence_url":"https://creativecommons.org/licenses/by-sa/4.0/","path":"seo-photos/sp37make/alpha/2012-2017-aaaa","sizes":[640,1280],"width":1280,"height":853,"score":80},
    {"year_from":2018,"year_to":2024,"generation":"Alpha (A2)","wikidata":"Q12","category":"Alpha (A2)","file_title":"File:Alpha A2 front.jpg","source_url":"https://commons.wikimedia.org/wiki/File:Alpha_A2_front.jpg","author":"Bob","licence":"CC BY 2.0","licence_url":"https://creativecommons.org/licenses/by/2.0/","path":"seo-photos/sp37make/alpha/2018-2024-bbbb","sizes":[640,1280],"width":1280,"height":720,"score":90}]}'),
  '[]'::jsonb);
select app.stock_photo_save('{"make":"sp37make","model":"beta","wikidata":"Q2","rows":[{"year_from":null,"year_to":null,"generation":"Beta","file_title":"File:Beta.jpg","source_url":"https://commons.wikimedia.org/wiki/File:Beta.jpg","author":"Cy","licence":"Public domain","path":"seo-photos/sp37make/beta/model-cccc","sizes":[640,1280],"width":1280,"height":800}]}');
select test.eq('save: the model is checked with its photo count', (select photos from vehicle_stock_photo_checks where make = 'sp37make' and model = 'alpha'), 2);
select test.eq('targets: a checked model is not asked for again', (select count(*) from jsonb_array_elements(app.stock_photo_targets('{"limit": 5000}')) x where x ->> 'make' = 'sp37make'), 0::bigint);
select test.eq('targets: unless named', (select count(*) from jsonb_array_elements(app.stock_photo_targets('{"models": ["sp37make/alpha"]}')) x), 1::bigint);

-- ---------------------------------------------------------------- 3. the page's read
set role anon;
select test.eq('anon: a year page gets its own generation (exact)', public.vehicle_stock_photo('sp37make', 'alpha', 2015) ->> 'path' || ' ' || (public.vehicle_stock_photo('sp37make', 'alpha', 2015) ->> 'match'),
  'seo-photos/sp37make/alpha/2012-2017-aaaa exact');
select test.eq('anon: a model year off a generation gets that generation (near)', public.vehicle_stock_photo('sp37make', 'alpha', 2011) ->> 'year_from' || ' ' || (public.vehicle_stock_photo('sp37make', 'alpha', 2011) ->> 'match'), '2012 near');
select test.eq('anon: the credit names the source', public.vehicle_stock_photo('sp37make', 'alpha', 2015) ->> 'source_name', 'Wikimedia Commons');
select test.eq('anon: the credit fields', public.vehicle_stock_photo('sp37make', 'alpha', 2019) ->> 'author' || ', ' || (public.vehicle_stock_photo('sp37make', 'alpha', 2019) ->> 'licence'), 'Bob, CC BY 2.0');
select test.eq('anon: the names for the alt text', public.vehicle_stock_photo('sp37make', 'alpha', 2019) ->> 'make_name' || ' ' || (public.vehicle_stock_photo('sp37make', 'alpha', 2019) ->> 'model_name'), 'Sp37make Alpha');
select test.eq('anon: a year no generation covers gets the nearest photo of the model, marked model', public.vehicle_stock_photo('sp37make', 'alpha', 2008) ->> 'year_from' || ' ' || (public.vehicle_stock_photo('sp37make', 'alpha', 2008) ->> 'match'), '2012 model');
select test.eq('anon: a model page gets the newest generation', public.vehicle_stock_photo('sp37make', 'alpha') ->> 'year_from', '2018');
select test.eq('anon: a year page gets a photo of the model in general, marked model', public.vehicle_stock_photo('sp37make', 'beta', 2021) ->> 'match', 'model');
select test.eq('anon: a model page''s photo needs no year note', public.vehicle_stock_photo('sp37make', 'alpha') ->> 'match', 'exact');
select test.eq('anon: a make page gets its most popular model', public.vehicle_stock_photo('sp37make') ->> 'model', 'beta');
select test.eq('anon: no privilege on the table itself', test.visible('select * from vehicle_stock_photos'), -1::bigint);
select test.throws('anon: cannot call the pipeline', $$select app.stock_photo_targets('{}')$$, null);
select test.throws('anon: cannot reach the door', $$select app.door(null, 'aal1', 'admin_read', 'stock_photos', '{}')$$, null);
reset role;

-- the setting turns every photo off at once
update program_settings set vpage_stock_photos = false where effective_from = (select effective_from from program_settings where effective_from <= app.today() order by effective_from desc limit 1);
select test.eq('setting off: no photo', public.vehicle_stock_photo('sp37make', 'alpha', 2019), null);
update program_settings set vpage_stock_photos = true;

-- ---------------------------------------------------------------- 4. saving again
select test.eq('save again: a new file replaces the old, which is returned for deletion',
  app.stock_photo_save('{"make":"sp37make","model":"alpha","rows":[{"year_from":2018,"year_to":2024,"generation":"Alpha (A2)","file_title":"File:Alpha A2 better.jpg","source_url":"https://commons.wikimedia.org/wiki/File:Alpha_A2_better.jpg","author":"Dee","licence":"CC0","path":"seo-photos/sp37make/alpha/2018-2024-dddd","sizes":[640,1280],"width":1280,"height":720}]}')
    -> 0 ->> 'path', 'seo-photos/sp37make/alpha/2018-2024-bbbb');
select test.eq('save again: the generation not found this time stays', (select count(*) from vehicle_stock_photos where make = 'sp37make' and model = 'alpha' and status = 'active'), 2::bigint);

select app.stock_photo_save('{"make":"sp37make","model":"beta","rows":[{"year_from":2020,"year_to":2024,"file_title":"2021 Beta front [openverse x1]","source_url":"https://www.flickr.com/photos/x/1","source_name":"Flickr via Openverse","author":"Gus","licence":"CC BY-SA 2.0","path":"seo-photos/sp37make/beta/2020-2024-gggg","sizes":[640,1280],"width":1280,"height":720}]}');
select test.eq('save: a photo from Openverse keeps its source for the credit',
  (public.vehicle_stock_photo('sp37make', 'beta', 2021) ->> 'source_name') || ' ' || (public.vehicle_stock_photo('sp37make', 'beta', 2021) ->> 'match'), 'Flickr via Openverse exact');

-- ---------------------------------------------------------------- 5. Admin
insert into test.sp37 select 'list', app.door(test.id('sp37_admin'), 'aal2', 'admin_read', 'stock_photos', '{}');
select test.ok('Admin: the list and the coverage',
  (select jsonb_array_length(v -> 'photos') >= 3 and (v #>> '{coverage,models}')::int >= 2 from test.sp37 where k = 'list'));
select test.throws('customer service cannot read the list', $$select app.door(test.id('sp37_cs'), 'aal2', 'admin_read', 'stock_photos', '{}')$$, null);
select test.throws('customer service cannot hide a photo',
  format($$select app.door(test.id('sp37_cs'), 'aal2', 'admin_do', 'stock_photo', '{"id":"%s","op":"hide"}')$$, (select id from vehicle_stock_photos where make = 'sp37make' and year_from = 2012)), null);

select app.door(test.id('sp37_admin'), 'aal2', 'admin_do', 'stock_photo', jsonb_build_object('id', (select id from vehicle_stock_photos where make = 'sp37make' and year_from = 2012), 'op', 'hide'));
select test.eq('hide: the hidden photo is never shown (the page takes another photo of the model, marked model)',
  public.vehicle_stock_photo('sp37make', 'alpha', 2014) ->> 'author' || ' ' || (public.vehicle_stock_photo('sp37make', 'alpha', 2014) ->> 'match'), 'Dee model');
select test.eq('hide: the file is never picked again', (select rejected_files from vehicle_stock_photos where make = 'sp37make' and year_from = 2012), array['File:Alpha A1 front.jpg']);
select test.eq('hide: the pipeline leaves a hidden photo alone',
  app.stock_photo_save('{"make":"sp37make","model":"alpha","rows":[{"year_from":2012,"year_to":2017,"file_title":"File:Other.jpg","source_url":"https://commons.wikimedia.org/wiki/File:Other.jpg","author":"E","licence":"CC0","path":"seo-photos/sp37make/alpha/2012-2017-eeee","sizes":[640],"width":640,"height":400}]}'),
  '[]'::jsonb);
select test.eq('hide: still hidden', (select status || ' ' || file_title from vehicle_stock_photos where make = 'sp37make' and year_from = 2012), 'hidden File:Alpha A1 front.jpg');
select app.door(test.id('sp37_admin'), 'aal2', 'admin_do', 'stock_photo', jsonb_build_object('id', (select id from vehicle_stock_photos where make = 'sp37make' and year_from = 2012), 'op', 'show'));
select test.eq('show: back on the page', public.vehicle_stock_photo('sp37make', 'alpha', 2014) ->> 'author', 'Ann');

select test.throws('replace: needs a Commons file',
  format($$select app.door(test.id('sp37_admin'), 'aal2', 'admin_do', 'stock_photo', '{"id":"%s","op":"replace","file":"https://example.com/x.jpg"}')$$, (select id from vehicle_stock_photos where make = 'sp37make' and year_from = 2012)), 'Give a Wikimedia Commons file%');
select app.door(test.id('sp37_admin'), 'aal2', 'admin_do', 'stock_photo', jsonb_build_object('id', (select id from vehicle_stock_photos where make = 'sp37make' and year_from = 2012), 'op', 'replace',
  'file', 'https://commons.wikimedia.org/wiki/File:Alpha_A1_chosen.jpg'));
select test.eq('replace: pending, off the page until the next run', public.vehicle_stock_photo('sp37make', 'alpha', 2014) ->> 'author', 'Dee');
select test.eq('replace: the pipeline sees the request', (select x ->> 'want_file' from jsonb_array_elements(app.stock_photo_pending()) x where x ->> 'make' = 'sp37make'), 'https://commons.wikimedia.org/wiki/File:Alpha_A1_chosen.jpg');
select test.eq('replace: the stored file is returned for deletion',
  app.stock_photo_resolve(jsonb_build_object('id', (select id from vehicle_stock_photos where make = 'sp37make' and year_from = 2012), 'row', '{"file_title":"File:Alpha A1 chosen.jpg","source_url":"https://commons.wikimedia.org/wiki/File:Alpha_A1_chosen.jpg","author":"Fay","licence":"CC BY-SA 3.0","path":"seo-photos/sp37make/alpha/2012-2017-ffff","sizes":[640,1280],"width":1280,"height":853}'::jsonb))
    -> 0 ->> 'path', 'seo-photos/sp37make/alpha/2012-2017-aaaa');
select test.eq('replace: active, an Admin''s choice the pipeline keeps', (select status || ' ' || picked_by || ' ' || author from vehicle_stock_photos where make = 'sp37make' and year_from = 2012), 'active admin Fay');

select app.door(test.id('sp37_admin'), 'aal2', 'admin_do', 'stock_photo', jsonb_build_object('id', (select id from vehicle_stock_photos where make = 'sp37make' and year_from = 2018), 'op', 'repick'));
select app.stock_photo_resolve(jsonb_build_object('id', (select id from vehicle_stock_photos where make = 'sp37make' and year_from = 2018), 'row', null, 'note', 'No other licensed photo found'));
select test.eq('pick again with nothing found: failed with the reason, off the page',
  (select status || ': ' || note from vehicle_stock_photos where make = 'sp37make' and year_from = 2018) || ' / ' || coalesce(public.vehicle_stock_photo('sp37make', 'alpha', 2020) ->> 'author', 'none'),
  'failed: No other licensed photo found / Fay');

-- ---------------------------------------------------------------- 6. generic photos and coverage
select app.stock_photo_save_generic('{"slot":"sp37slot","rows":[{"file_title":"File:Road one.jpg","source_url":"https://commons.wikimedia.org/wiki/File:Road_one.jpg","author":"G","licence":"CC BY-SA 4.0","alt":"A road","path":"seo-photos/generic/sp37slot/model-1111","sizes":[640,1280],"width":1280,"height":720,"score":30},
  {"file_title":"File:Road two.jpg","source_url":"https://commons.wikimedia.org/wiki/File:Road_two.jpg","author":"H","licence":"CC0","alt":"A road","path":"seo-photos/generic/sp37slot/model-2222","sizes":[640,1280],"width":1280,"height":720,"score":10}]}');
select test.eq('generic: the slot''s photos, best first', (select string_agg(x ->> 'author', ',') from jsonb_array_elements(public.stock_photos_generic('sp37slot')) x), 'G,H');
select test.eq('generic: a new set replaces the old one, whose files are returned',
  app.stock_photo_save_generic('{"slot":"sp37slot","rows":[{"file_title":"File:Road one.jpg","source_url":"https://commons.wikimedia.org/wiki/File:Road_one.jpg","author":"G","licence":"CC BY-SA 4.0","path":"seo-photos/generic/sp37slot/model-1111","sizes":[640,1280],"width":1280,"height":720}]}')
    -> 0 ->> 'path', 'seo-photos/generic/sp37slot/model-2222');
select test.eq('coverage: model years with a photo of their generation (2012 to 2017 of Alpha, 2020 to 2024 of Beta)',
  (select count(*) from vehicle_catalog_years y where y.make_slug = 'sp37make' and exists (select 1 from vehicle_stock_photos ph where ph.status = 'active' and ph.make = y.make_slug and ph.model = y.model_slug and y.year between ph.year_from and ph.year_to)), 11::bigint);
select test.ok('coverage: counts and the popular models without a photo', (app.stock_photo_coverage() ? 'popular_missing') and (app.stock_photo_coverage() ->> 'model_years_with_photo')::int >= 6);

delete from vehicle_stock_photos where make = 'sp37make' or slot = 'sp37slot';
delete from vehicle_stock_photo_checks where make = 'sp37make';
delete from vehicle_catalog_makes where slug = 'sp37make';
