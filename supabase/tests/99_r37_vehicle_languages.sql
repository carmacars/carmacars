-- 99: release 37 (migration 2302): the vehicle multipliers in every language exist only where a real car backs them:
-- the trim, the trim in the top places, in the real car's colour, and the per-car service pages (detailing; DUI and
-- suspension rentals the terms serve). A sample car or an unlisted car backs nothing. Fixtures "r37l".
select test.suite('99 r37 vehicle language pages (2302)');

\ir ../seed/vehicle_catalog_fixture.sql

select test.mk_owner('r37l_own');
insert into vehicles (id, owner_id, year, make, model, trim, colour, plate, class, status, management_mode, onboarding_method, body_type)
values (test.id('vehicle:R37L1'), test.id('owner:r37l_own'), 2020, 'Volkswagen', 'Jetta', 'Sportline', 'Grey', 'R37LAAA', 'standard', 'available', 'managed', 'transfer', 'Sedan');
insert into vehicle_listings (vehicle_id, slug, headline, status, published_at, seats, transmission, body_style)
values (test.id('vehicle:R37L1'), app.listing_slug(test.id('vehicle:R37L1')), 'x', 'published', now(), 5, 'Automatic', 'Sedan');
insert into seo_pages (slug, kind, name, is_active, facts) values ('r37l-town', 'location', 'R37L Town', true, '{"population": "999999999"}')
on conflict (slug) do update set is_active = true, facts = excluded.facts;
insert into place_terms (slug, vertical, phrase, title, served, sort_order, is_active) values ('r37l-licence-suspended-rental', 'rental', 'licence suspended rental', 'Licence suspended rental', 'yes', 999, true)
on conflict (slug) do nothing;
create temp table r37p as select path from app.vehicle_language_paths();

select test.ok('the real car''s trim has a language page', exists (select 1 from r37p where path = '/cars/volkswagen/jetta/2020/sportline'));
select test.ok('the trim in the largest place', exists (select 1 from r37p where path = '/cars/volkswagen/jetta/2020/sportline/r37l-town'));
select test.ok('in the real car''s colour only (grey, never red)', exists (select 1 from r37p where path = '/cars/volkswagen/jetta/2020/sportline/r37l-town/grey')
  and not exists (select 1 from r37p where path like '/cars/volkswagen/jetta/2020/sportline/%/red'));
select test.ok('a per-car detailing page', exists (select 1 from r37p p join place_terms t on p.path = '/t/' || t.slug || '/volkswagen/jetta/2020/sportline' where t.vertical = 'detailing'));
select test.ok('a per-car suspension rental page (a served term)', exists (select 1 from r37p where path = '/t/r37l-licence-suspended-rental/volkswagen/jetta/2020/sportline'));
select test.ok('no page for a trim without a real car', not exists (select 1 from r37p where path like '/cars/volkswagen/jetta/2020/gli%' or path like '%/jetta/2020/gli%'));
-- other suites leave published cars too: the 2020 Jetta pages are this car's trim only
select test.ok('every page belongs to a real car''s trim', not exists (select 1 from r37p where path like '%/volkswagen/jetta/2020/%' and path not like '%/volkswagen/jetta/2020/sportline%'));
select test.eq('the page check agrees', (public.vehicle_language_ok('/cars/volkswagen/jetta/2020/sportline/r37l-town/grey'), public.vehicle_language_ok('/cars/volkswagen/jetta/2020/gli')), (true, false));
update program_settings set seo_i18n_vehicle_places = 0 where id = (app.settings()).id;
select test.ok('places set to 0: the trim pages only', not exists (select 1 from app.vehicle_language_paths() where path like '%/r37l-town%'));
update program_settings set seo_i18n_vehicle_places = 12 where id = (app.settings()).id;
update vehicle_listings set status = 'unpublished' where vehicle_id = test.id('vehicle:R37L1');
select test.eq('an unlisted car backs nothing', (select count(*)::int from app.vehicle_language_paths() where path like '%/volkswagen/jetta/2020/%'), 0);
select test.ok('the list itself is server only', not has_function_privilege('anon', 'app.vehicle_language_paths()', 'execute'));
