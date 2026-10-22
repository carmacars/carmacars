-- 65: release 3 (migration 0094), the sample cars back on the site. Live, every sample listing had been unpublished by
-- "Hide sample cars"; app.sample_cars_restore_0094 publishes them all again and makes the listing of a catalogue car
-- that has none (the catalogue's text, its 8 studio photos), still noindex and out of the sitemap. A database without
-- sample cars is left alone. Fixtures start with "r3".
select test.suite('65 release 3 sample cars');

select test.mk_user('r3_admin', 'admin');
select test.mk_user('r3_cs', 'va', 'cs');

-- ---------------------------------------------------------------- 1. a database without sample cars: nothing made
create temp table r3_had as select id from vehicles where is_sample;
update vehicles set is_sample = false where id in (select id from r3_had);
select test.eq('no sample cars: nothing to restore', app.sample_cars_restore_0094() ->> 'skipped', 'no sample cars');
select test.eq('no sample cars: none made', (select count(*) from vehicles where is_sample), 0::bigint);
update vehicles set is_sample = true where id in (select id from r3_had);

-- ---------------------------------------------------------------- 2. the live state: every sample car hidden, a listing missing
select app.door(test.id('r3_admin'), '', 'ops_do', 'sample_cars_show', '{}');
select app.door(test.id('r3_admin'), '', 'ops_do', 'sample_cars_hide', '{}');
select test.eq('hidden: none on the site', (app.sample_cars_state() ->> 'public')::int, 0);
delete from vehicle_photos where vehicle_id = (select vehicle_id from vehicle_listings where slug = 'toyota-corolla');
delete from vehicle_listings where slug = 'toyota-corolla';
select test.ok('a catalogue car without its listing', exists (select 1 from vehicles where is_sample and vin = 'SAMPLE06XXXXXXXXX')
  and not exists (select 1 from vehicle_listings l join vehicles v on v.id = l.vehicle_id where v.vin = 'SAMPLE06XXXXXXXXX'));

-- ---------------------------------------------------------------- 3. the restore
create temp table r3_res as select app.sample_cars_restore_0094() r;
select test.ok('restore: every catalogue car published', (select count(*) from vehicle_listings l join vehicles v on v.id = l.vehicle_id
  join sample_car_catalogue c on c.slug = l.slug where v.is_sample and l.status = 'published' and l.unpublished_reason is null) = 20);
select test.ok('restore: the state counts them on the site', (app.sample_cars_state() ->> 'public')::int >= 20);
select test.eq('restore: the missing listing made from the catalogue', (select headline from vehicle_listings where slug = 'toyota-corolla'),
  (select data ->> 'headline' from sample_car_catalogue where slug = 'toyota-corolla'));
set role anon;
select test.eq('restore: the car page is not indexable', public.car_page('toyota-corolla') ->> 'indexable', 'false');
select test.ok('restore: on the fleet page, marked as a sample', exists (select 1 from public.fleet() f where f ->> 'slug' = 'mercedes-benz-c300' and f ->> 'is_sample' = 'true'));
create temp table r3_map as select path from public.sitemap_rows();
reset role;
select test.ok('restore: no sample car in the sitemap',
  not exists (select 1 from r3_map s join vehicle_listings l on '/cars/' || l.slug = s.path join vehicles v on v.id = l.vehicle_id where v.is_sample));
select test.ok('restore: in the audit log as the migration (no person)', exists (select 1 from audit_log where action = 'sample_cars_show' and actor_user_id is null and after ->> 'shown' is not null));
select test.eq('restore twice: nothing more to show', (app.sample_cars_restore_0094() ->> 'shown')::int, 0);
select test.ok('the restore is the service role''s only', not has_function_privilege('anon', 'app.sample_cars_restore_0094()', 'execute')
  and not has_function_privilege('authenticated', 'app.sample_cars_restore_0094()', 'execute'));

-- ---------------------------------------------------------------- 4. only an Admin hides them
select test.throws('hide: only an Admin', $$select app.door(test.id('r3_cs'), '', 'ops_do', 'sample_cars_hide', '{}')$$, 'Admin');
select test.eq('hide refused: still on the site', (app.sample_cars_state() ->> 'public')::int >= 20, true);
