-- 99: the cars in the rows of the revamped pages show their cover photo (migration 0430). Fixtures start with "rcp".
select test.suite('99 row car photos');
select test.mk_owner('rcp_owner');
select test.mk_vehicle('rcp_a', 'rcp_owner');
select test.mk_vehicle('rcp_b', 'rcp_owner');
insert into vehicle_photos (vehicle_id, angle, original_path, processed_path, status, is_cover, variants, content_sha256)
values (test.id('vehicle:rcp_a'), 'front', 'vehicles/rcp/a.jpg', 'vehicles/rcp/a-cover.jpg', 'approved', true, '[{"width": 160, "path": "vehicles/rcp/a-160.webp"}]', repeat('1', 64)),
       (test.id('vehicle:rcp_b'), 'front', 'vehicles/rcp/b.jpg', 'vehicles/rcp/b-cover.jpg', 'uploaded', true, null, repeat('2', 64));
select test.eq('a car with an approved cover gives its path and sizes',
  public.server_row_car_photos(array[test.id('vehicle:rcp_a'), test.id('vehicle:rcp_b')]) -> test.id('vehicle:rcp_a')::text ->> 'path', 'vehicles/rcp/a-cover.jpg');
select test.ok('a car whose cover is not approved gives nothing (the row shows its letter)',
  not (public.server_row_car_photos(array[test.id('vehicle:rcp_b')]) ? test.id('vehicle:rcp_b')::text));
select test.eq('no cars: an empty map', public.server_row_car_photos(null)::text, '{}');
select test.ok('only the server may ask', not has_function_privilege('authenticated', 'public.server_row_car_photos(uuid[])', 'execute')
  and not has_function_privilege('anon', 'public.server_row_car_photos(uuid[])', 'execute'));
