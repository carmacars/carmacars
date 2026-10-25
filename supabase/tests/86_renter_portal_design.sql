-- 86: the renter portal's trip photos (migration 0152, docs/changes/2026-10-24-renter-portal-design.md). The photo of
-- each car the signed-in renter booked: the car's own cover, else its first approved public photo, else nothing from it;
-- only the caller's cars; anonymous visitors cannot call it. Fixtures start with "rd40" ("RD4" for cars).
select test.suite('86 renter portal design');
select test.mk_owner('rd40_owner');
select test.mk_vehicle('RD4A', 'rd40_owner');
select test.mk_vehicle('RD4B', 'rd40_owner');
select test.mk_vehicle('RD4C', 'rd40_owner');
select test.mk_renter('rd40_amy');
select test.mk_renter('rd40_ben');
select test.mk_booking('RD4-1', 'RD4A', 'rd40_amy', '2026-11-02 10:00', '2026-11-05 10:00', 'confirmed');
select test.mk_booking('RD4-2', 'RD4B', 'rd40_amy', '2026-09-02 10:00', '2026-09-04 10:00', 'closed');
select test.mk_booking('RD4-3', 'RD4C', 'rd40_ben', '2026-11-02 10:00', '2026-11-04 10:00', 'confirmed');

-- car A: a cover photo and a later one; car B: no cover, two approved public photos and one rejected; car C: Ben's
insert into vehicle_photos (vehicle_id, angle, original_path, processed_path, status, sort_order, is_cover, is_public, alt_text)
values (test.id('vehicle:RD4A'), 'front', 'o/a1.jpg', 'p/a-front.jpg', 'approved', 2, true, true, 'Car A from the front'),
       (test.id('vehicle:RD4A'), 'rear', 'o/a2.jpg', 'p/a-rear.jpg', 'approved', 1, false, true, 'Car A from the back'),
       (test.id('vehicle:RD4B'), 'left', 'o/b0.jpg', 'p/b-rejected.jpg', 'rejected', 0, true, true, 'Rejected'),
       (test.id('vehicle:RD4B'), 'front_left', 'o/b1.jpg', 'p/b-front-left.jpg', 'approved', 1, false, true, 'Car B'),
       (test.id('vehicle:RD4B'), 'rear', 'o/b2.jpg', 'p/b-rear.jpg', 'approved', 3, false, true, 'Car B rear'),
       (test.id('vehicle:RD4C'), 'front', 'o/c1.jpg', 'p/c-front.jpg', 'approved', 0, true, true, 'Car C');

select test.login((select user_id from renters where id = test.id('renter:rd40_amy')));
select test.eq('photos: the cover of a car the renter booked',
  public.my_trip_photos() #>> array[test.id('vehicle:RD4A')::text, 'path'], 'p/a-front.jpg');
select test.eq('photos: no cover, the first approved public photo (a rejected one is skipped)',
  public.my_trip_photos() #>> array[test.id('vehicle:RD4B')::text, 'path'], 'p/b-front-left.jpg');
select test.eq('photos: the alt text comes with it', public.my_trip_photos() #>> array[test.id('vehicle:RD4A')::text, 'alt'], 'Car A from the front');
select test.eq('photos: another renter''s car is not in the list', public.my_trip_photos() ? test.id('vehicle:RD4C')::text, false);
select test.logout();

select test.login((select user_id from renters where id = test.id('renter:rd40_ben')));
select test.eq('photos: each renter sees only their own cars', (select count(*) from jsonb_object_keys(public.my_trip_photos())), 1::bigint);
select test.logout();

set role anon;
select test.throws('photos: an anonymous visitor cannot call it', $$select public.my_trip_photos()$$, 'permission denied');
reset role;
select test.eq('photos: read only (stable, no write)', (select provolatile::text from pg_proc where proname = 'my_trip_photos'), 's');
