-- 99: migrations 3080 and 3081 (release 48, part O). The cutouts of real cars for the decorative sections (where each
-- car's photo comes from, the worker's list, a saved cutout and a failure, the public read) and the owner's occupancy
-- forecast (the seasonal curve, the blend with the car's own months once it has 3, the bookings hidden from the owner left
-- out, the statement's line, who may read it). Fixtures start with "fo48_"; no real names or plates.
select test.suite('99 r48 O cutouts and forecast (3080, 3081)');

select test.mk_user('fo48_admin', 'admin');
select test.mk_owner('fo48_olive');
select test.mk_owner('fo48_other');
select test.mk_renter('fo48_rita');
select test.mk_vehicle('fo48_a', 'fo48_olive', p_enrolled => date '2026-01-10');
select test.mk_vehicle('fo48_b', 'fo48_olive', p_enrolled => date '2026-06-05');
select test.mk_vehicle('fo48_c', 'fo48_other', p_enrolled => date '2026-01-10');

-- ================================================================ 3080: the cutouts
insert into vehicle_listings (vehicle_id, status) select test.id('vehicle:' || x), 'published' from unnest(array['fo48_a', 'fo48_b', 'fo48_c']) x;
-- car a: a studio side view (3030) and a listing side view; car b: a listing view of the other side only; car c: nothing
insert into vehicle_photos (vehicle_id, angle, shot_type, original_path, processed_path, status, is_public, r48, background_status, plate_status)
values (test.id('vehicle:fo48_a'), 'left', 'left', 'vehicles/original/fo48/a-left-r48.jpg', 'vehicles/fo48/a-left-r48.jpg', 'approved', true, true, 'done', 'not_visible'),
       (test.id('vehicle:fo48_a'), 'left', 'left', 'vehicles/original/fo48/a-left.jpg', 'vehicles/fo48/a-left.jpg', 'approved', true, false, 'done', 'not_visible'),
       (test.id('vehicle:fo48_b'), 'right', 'right', 'vehicles/original/fo48/b-right.jpg', 'vehicles/fo48/b-right.jpg', 'approved', true, false, 'done', 'not_visible');

select test.eq('the R48 studio side view comes first',
  app.site_cutout_source(test.id('vehicle:fo48_a')) ->> 'kind' || ' ' || (app.site_cutout_source(test.id('vehicle:fo48_a')) ->> 'path'), 'studio vehicles/fo48/a-left-r48.jpg');
select test.eq('no studio view: the listing photo of the other side, facing right (shown mirrored)',
  array[app.site_cutout_source(test.id('vehicle:fo48_b')) ->> 'kind', app.site_cutout_source(test.id('vehicle:fo48_b')) ->> 'facing'], array['listing', 'right']);
select test.ok('no photo of the angle (and no stock photo free of a credit line): no source, the sample stays',
  app.site_cutout_source(test.id('vehicle:fo48_c')) is null);
update vehicle_photos set is_public = false where vehicle_id = test.id('vehicle:fo48_a') and r48;
select test.eq('a studio view taken off the site is not used: the listing photo is', app.site_cutout_source(test.id('vehicle:fo48_a')) ->> 'kind', 'listing');
update vehicle_photos set is_public = true where vehicle_id = test.id('vehicle:fo48_a') and r48;

create temp table fo48_due as select e from jsonb_array_elements(app.site_cutouts_due(20)) e
 where (e ->> 'vehicle_id')::uuid in (test.id('vehicle:fo48_a'), test.id('vehicle:fo48_b'), test.id('vehicle:fo48_c'));
select test.eq('the worker gets the cars with a source and no cutout', (select count(*) from fo48_due)::integer, 2);

select app.site_cutout_save(test.id('vehicle:fo48_a'), 'left', jsonb_build_object('source', app.site_cutout_source(test.id('vehicle:fo48_a')),
  'path', 'site/cutouts/fo48-a/left-aaaa.webp', 'width', 1600, 'height', 620));
select app.site_cutout_save(test.id('vehicle:fo48_b'), 'left', jsonb_build_object('source', app.site_cutout_source(test.id('vehicle:fo48_b')), 'error', 'no car found'));
select test.ok('a saved cutout leaves the list; a failure waits its turn',
  not exists (select 1 from jsonb_array_elements(app.site_cutouts_due(20)) e where (e ->> 'vehicle_id')::uuid in (test.id('vehicle:fo48_a'), test.id('vehicle:fo48_b'))));
select test.eq('the failure is kept with its try and next time', (select array[tries::text, (next_try_at > now())::text, error] from site_cutouts where vehicle_id = test.id('vehicle:fo48_b')),
  array['1', 'true', 'no car found']);
select test.ok('the site reads the saved cutout (public path, size, facing), not the failed one',
  exists (select 1 from jsonb_array_elements(public.site_cutouts('left', 24)) e where (e ->> 'vehicle_id')::uuid = test.id('vehicle:fo48_a')
           and e ->> 'path' = 'site/cutouts/fo48-a/left-aaaa.webp' and (e ->> 'width')::integer = 1600 and e ->> 'facing' = 'left')
  and not exists (select 1 from jsonb_array_elements(public.site_cutouts('left', 24)) e where (e ->> 'vehicle_id')::uuid = test.id('vehicle:fo48_b')));
-- a new studio view: the cutout is made again, the old one stays on the site until then
update vehicle_photos set processed_path = 'vehicles/fo48/a-left-r48-v2.jpg' where vehicle_id = test.id('vehicle:fo48_a') and r48;
select test.ok('a new source photo puts the car back on the list',
  exists (select 1 from jsonb_array_elements(app.site_cutouts_due(20)) e where (e ->> 'vehicle_id')::uuid = test.id('vehicle:fo48_a')));
select app.site_cutout_save(test.id('vehicle:fo48_a'), 'left', jsonb_build_object('source', app.site_cutout_source(test.id('vehicle:fo48_a')), 'error', 'timeout'));
select test.eq('a failed remake keeps the cutout on the site', (select path from site_cutouts where vehicle_id = test.id('vehicle:fo48_a')), 'site/cutouts/fo48-a/left-aaaa.webp');
update vehicle_listings set status = 'draft' where vehicle_id = test.id('vehicle:fo48_a');
select test.ok('a car not on the site is never listed',
  not exists (select 1 from jsonb_array_elements(app.site_cutouts('left', 24)) e where (e ->> 'vehicle_id')::uuid = test.id('vehicle:fo48_a')));
update vehicle_listings set status = 'published' where vehicle_id = test.id('vehicle:fo48_a');
select test.ok('visitors read the cutouts; the worker''s list and save are the server''s only',
  has_function_privilege('anon', 'public.site_cutouts(text, integer)', 'execute')
  and not has_function_privilege('anon', 'public.site_cutouts_due(integer, text)', 'execute')
  and not has_function_privilege('authenticated', 'public.site_cutout_save(uuid, text, jsonb)', 'execute')
  and not has_table_privilege('anon', 'site_cutouts', 'select'));

-- ================================================================ 3081: the forecast
-- car a: from February to July 2026, a booking of the 1st to the 16th each month (15 days) the owner sees; in March, a
-- second booking from the 16th to the 31st hidden from the owner (never shown): it does not count
do $$
declare m date;
begin
  for m in select g::date from generate_series(date '2026-02-01', date '2026-07-01', interval '1 month') g loop
    perform test.mk_booking('FO48-' || to_char(m, 'MM'), 'fo48_a', 'fo48_rita', to_char(m, 'YYYY-MM-DD') || ' 10:00', to_char(m + 15, 'YYYY-MM-DD') || ' 10:00', 'closed');
  end loop;
end $$;
select test.mk_booking('FO48-H', 'fo48_a', 'fo48_rita', '2026-03-16 10:00', '2026-03-31 10:00', 'closed');
update bookings set owner_visibility = 'never' where id = test.id('booking:FO48-H');
-- car b: one month of history (July)
select test.mk_booking('FO48-B7', 'fo48_b', 'fo48_rita', '2026-07-01 10:00', '2026-07-21 10:00', 'closed');

select test.ok('a booking hidden from the owner is left out of the actuals (15 of 31 days, not 30)',
  abs(app.car_month_occupancy_bps(test.id('vehicle:fo48_a'), date '2026-03-01') - round(10000 * 15.0 / 31)) <= 20);
update bookings set owner_visibility = 'shown' where id = test.id('booking:FO48-H');
select test.ok('shown again, it counts', app.car_month_occupancy_bps(test.id('vehicle:fo48_a'), date '2026-03-01') > 9000);
update bookings set owner_visibility = 'never' where id = test.id('booking:FO48-H');

create temp table fo48_f as select
  app.car_occupancy_forecast(test.id('vehicle:fo48_a'), date '2026-08-01', 12) as a6,
  app.car_occupancy_forecast(test.id('vehicle:fo48_a'), date '2026-05-01', 3) as a3,
  app.car_occupancy_forecast(test.id('vehicle:fo48_a'), date '2026-04-01', 3) as a2,
  app.car_occupancy_forecast(test.id('vehicle:fo48_b'), date '2026-08-01', 3) as b1;
select test.eq('history: the full months on the program before the forecast (February to July)', (select (a6 ->> 'history_months')::integer from fo48_f), 6);
select test.eq('12 months forecast, from August', (select array[jsonb_array_length(a6 -> 'months')::text, a6 -> 'months' -> 0 ->> 'month', a6 -> 'months' -> 11 ->> 'month'] from fo48_f),
  array['12', '2026-08-01', '2027-07-01']);
select test.ok('fewer than 3 months: the curve alone (car b, and car a with 2 months)',
  (select (b1 ->> 'own_weight')::numeric = 0 and (b1 -> 'months' -> 0 ->> 'occupancy_bps')::integer = (b1 -> 'months' -> 0 ->> 'curve_bps')::integer
          and (a2 ->> 'history_months')::integer = 2 and (a2 -> 'months' -> 0 ->> 'occupancy_bps')::integer = (a2 -> 'months' -> 0 ->> 'curve_bps')::integer from fo48_f));
select test.ok('from 3 months: blended, the car''s own months weighing more as they accrue (3: half, 6: two thirds)',
  (select (a3 ->> 'own_weight')::numeric = 0.5 and (a6 ->> 'own_weight')::numeric = 0.667 from fo48_f));
select test.ok('the blend: the curve and the car''s own level times the month''s factor, by the weight',
  (select bool_and(abs((m ->> 'occupancy_bps')::integer - round((m ->> 'curve_bps')::integer / 3.0 + 2 * (m ->> 'own_bps')::integer / 3.0)) <= 1)
     from fo48_f, jsonb_array_elements(a6 -> 'months') m));
select test.ok('the season stays in the blend: July above January',
  (select (a6 -> 'months' -> 11 ->> 'occupancy_bps')::integer > (a6 -> 'months' -> 5 ->> 'occupancy_bps')::integer from fo48_f));
select test.ok('the car''s own level leaves the hidden booking out (about half the month booked, not more)',
  (select (a6 ->> 'own_level_bps')::integer between 4000 and 6500 from fo48_f));
select test.ok('projected owner revenue = occupancy x days x the owner revenue of a booked day',
  (select bool_and((m ->> 'revenue_cents')::bigint = round((m ->> 'occupancy_bps')::integer / 10000.0 * (m ->> 'days')::integer * (a6 ->> 'day_cents')::bigint))
     and bool_and((a6 ->> 'day_cents')::bigint > 0) from fo48_f, jsonb_array_elements(a6 -> 'months') m));

-- the curve is Admin's: 12 factors, each 0.1 to 2.5
select test.throws('a curve without its 12 months is refused',
  $$update program_settings set occupancy_season = '{"jan": 1}'::jsonb where id = (select id from app.settings())$$, 'occupancy_season');
update program_settings set occupancy_season = occupancy_season || '{"aug": 2.0}'::jsonb where id = (select id from app.settings());
select test.ok('an edited factor moves the curve', app.occupancy_curve_bps(date '2026-08-01') = least(10000, (app.settings()).occupancy_base_pct * 200));
update program_settings set occupancy_season = occupancy_season || '{"aug": 1.25}'::jsonb where id = (select id from app.settings());

-- the statement's line: next month against the statement's month, why (the season)
insert into owner_statements (owner_id, statement_month, statement_number, status, payout_date)
select test.id('owner:fo48_olive'), date '2026-11-01', 'OS-FO48-11', 'draft', date '2026-12-15';
create temp table fo48_s as select app.owner_statement_forecast((select id from owner_statements where statement_number = 'OS-FO48-11')) as f;
select test.eq('December against November: higher, for the season', (select array[f ->> 'direction', f ->> 'next_month', f ->> 'reason'] from fo48_s),
  array['higher', '2026-12-01', 'holiday travel and visiting family']);
select test.ok('the line says by how much and why', (select f ->> 'text' ~ '^Forecast: next month \(December\) is projected higher than November: about \d+% occupancy against \d+% \(\d+ more points?\), about \$[\d,]+ more in owner revenue\. Why: the season; December is busier in the GTA' from fo48_s));
select test.ok('the owner''s statement and the Admin''s (and the PDF) carry it',
  app.owner_statement_breakdown((select id from owner_statements where statement_number = 'OS-FO48-11'), test.id('fo48_admin')) -> 'forecast' ->> 'direction' = 'higher');

-- who reads the forecast
select test.ok('the owner reads their own cars, 12 months each',
  (select jsonb_array_length(x -> 'cars') = 2 and jsonb_array_length(x -> 'cars' -> 0 -> 'months') = 12
     from (select app.door(test.id('fo48_olive'), 'aal1', 'ops_read', 'owner_forecast', jsonb_build_object('owner_id', test.id('owner:fo48_olive'))) x) y));
select test.ok('an Admin reads any owner''s', jsonb_array_length(app.door(test.id('fo48_admin'), 'aal2', 'ops_read', 'owner_forecast',
  jsonb_build_object('owner_id', test.id('owner:fo48_other'))) -> 'cars') = 1);
select test.throws('another owner cannot', format($$select app.door(%L, 'aal1', 'ops_read', 'owner_forecast', %L::jsonb)$$, test.id('fo48_other'),
  jsonb_build_object('owner_id', test.id('owner:fo48_olive'))), 'Not permitted');
select test.ok('the forecast functions are the server''s only',
  not has_function_privilege('authenticated', 'app.owner_occupancy_forecast(uuid, date, integer)', 'execute')
  and not has_function_privilege('anon', 'app.car_occupancy_forecast(uuid, date, integer)', 'execute'));
