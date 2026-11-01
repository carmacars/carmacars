-- 99: no published car without an address, and customer service can open the review its queue links to (0310).
-- docs/changes/2026-11-05-listing-slug-verify-link.md. Fixtures start with "ls" and use example.test only.
select test.suite('99 listing slug and the review link');

select test.mk_user('ls_cs', 'va', 'cs');
select test.mk_owner('ls_olive');
select test.mk_vehicle('ls_car', 'ls_olive');
select test.mk_renter('ls_rita');

-- ================================================================ 1. a listing published without a slug gets one
select app.ensure_listing(test.id('vehicle:ls_car'));
update vehicle_listings set slug = null, status = 'draft' where vehicle_id = test.id('vehicle:ls_car');
update vehicle_listings set status = 'published', published_at = now(), first_published_at = now() where vehicle_id = test.id('vehicle:ls_car');
select test.ok('published without a slug: it gets the publish screens'' slug',
  (select l.slug is not null and l.slug = app.listing_slug(l.vehicle_id) from vehicle_listings l where l.vehicle_id = test.id('vehicle:ls_car')));
select test.ok('the fleet has no car without an address',
  not exists (select 1 from app.public_fleet('{}') r where r ->> 'slug' is null or r ->> 'path' = '/cars/'));
select test.ok('the car is in the fleet at its address',
  exists (select 1 from app.public_fleet('{}') r where r ->> 'path' = '/cars/' || (select slug from vehicle_listings where vehicle_id = test.id('vehicle:ls_car'))));
select test.mk_vehicle('ls_draft', 'ls_olive');
select app.ensure_listing(test.id('vehicle:ls_draft'));
update vehicle_listings set slug = null, status = 'draft' where vehicle_id = test.id('vehicle:ls_draft');
select test.ok('a draft is left without a slug', (select slug is null from vehicle_listings where vehicle_id = test.id('vehicle:ls_draft')));

-- ================================================================ 2. the review page opens for the task in customer service's queue
select test.mk_booking('LS-REQ', 'ls_car', 'ls_rita', to_char(now() at time zone 'America/Toronto' + interval '30 days', 'YYYY-MM-DD 10:00'),
  to_char(now() at time zone 'America/Toronto' + interval '33 days', 'YYYY-MM-DD 10:00'), 'requested');
select test.ok('a request with nothing waiting: customer service cannot open its review', not app.doc_review_can(test.id('ls_cs'), test.id('booking:LS-REQ')));
insert into tasks (queue, task_type, title, booking_id) values ('cs', 'verify_renter', 'Check the renter', test.id('booking:LS-REQ'));
select test.ok('with the review task open in the queue: customer service can', app.doc_review_can(test.id('ls_cs'), test.id('booking:LS-REQ')));
select test.ok('and the page reads', app.doc_review_read(test.id('ls_cs'), jsonb_build_object('booking', 'LS-REQ')) ->> 'booking_number' = 'LS-REQ');
update tasks set status = 'done', completed_at = now() where booking_id = test.id('booking:LS-REQ') and task_type = 'verify_renter';
select test.ok('the task done: back to the usual rule', not app.doc_review_can(test.id('ls_cs'), test.id('booking:LS-REQ')));
