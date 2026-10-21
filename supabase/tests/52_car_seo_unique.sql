-- 52: one search title and description per car (migration 0075). Cars of the same year, make and model get what
-- tells them apart (colour, then fleet number, then a short code); a car with no twin gets nothing. Fixtures "su".
select test.suite('52 car search text unique');

select test.mk_owner('su_own');
insert into vehicles (id, owner_id, year, make, model, trim, colour, plate, class, status, management_mode, onboarding_method, body_type, fleet_number)
values (test.id('vehicle:SU1'), test.id('owner:su_own'), 2024, 'Kia', 'K5 SU', 'LX', 'White', 'SU1AAA', 'standard', 'available', 'managed', 'transfer', 'Sedan', null),
       (test.id('vehicle:SU2'), test.id('owner:su_own'), 2024, 'Kia', 'K5 SU', 'LX', 'Black', 'SU2AAA', 'standard', 'available', 'managed', 'transfer', 'Sedan', 'SU-7'),
       (test.id('vehicle:SU3'), test.id('owner:su_own'), 2024, 'Kia', 'K5 SU', 'LX', 'Black', 'SU3AAA', 'standard', 'available', 'managed', 'transfer', 'Sedan', null),
       (test.id('vehicle:SU4'), test.id('owner:su_own'), 2023, 'Kia', 'K5 SU', 'LX', 'Black', 'SU4AAA', 'standard', 'available', 'managed', 'transfer', 'Sedan', null);
insert into vehicle_listings (vehicle_id, slug, headline, status, published_at, seats, transmission, body_style)
select v.id, app.listing_slug(v.id), 'x', 'published', now(), 5, 'Automatic', 'Sedan' from vehicles v
 where v.id in (test.id('vehicle:SU1'), test.id('vehicle:SU4'));
insert into vehicle_listings (vehicle_id, slug, headline, status, published_at, seats, transmission, body_style)
select v.id, app.listing_slug(v.id), 'x', 'published', now(), 5, 'Automatic', 'Sedan' from vehicles v where v.id = test.id('vehicle:SU2');
insert into vehicle_listings (vehicle_id, slug, headline, status, published_at, seats, transmission, body_style)
select v.id, app.listing_slug(v.id), 'x', 'published', now(), 5, 'Automatic', 'Sedan' from vehicles v where v.id = test.id('vehicle:SU3');

select test.eq('a colour no twin has', app.listing_seo_mark(test.id('vehicle:SU1')), 'white');
select test.eq('the same colour as a twin: the fleet number', app.listing_seo_mark(test.id('vehicle:SU2')), 'SU-7');
select test.eq('the same colour and no fleet number: a short code', app.listing_seo_mark(test.id('vehicle:SU3')), 'car ' || upper(left(md5(test.id('vehicle:SU3')::text), 4)));
select test.eq('another year has no twin: nothing added', app.listing_seo_mark(test.id('vehicle:SU4')), null::text);
select test.eq('the car page carries it', public.car_page((select slug from vehicle_listings where vehicle_id = test.id('vehicle:SU1'))) ->> 'seo_mark', 'white');
select test.eq('every twin has its own address', (select count(distinct slug) from vehicle_listings where vehicle_id in (test.id('vehicle:SU1'), test.id('vehicle:SU2'), test.id('vehicle:SU3'))), 3::bigint);
select test.eq('every twin has its own mark', (select count(distinct app.listing_seo_mark(id)) from vehicles where id in (test.id('vehicle:SU1'), test.id('vehicle:SU2'), test.id('vehicle:SU3'))), 3::bigint);
update vehicle_listings set status = 'unpublished' where vehicle_id in (test.id('vehicle:SU1'), test.id('vehicle:SU2'), test.id('vehicle:SU3'), test.id('vehicle:SU4'));
