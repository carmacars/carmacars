-- 22: what the launch audit changed in the database (migration 0035): sample cars kept out of search, a review
-- published only with the renter's consent, marketing emails waiting for the mailing address. Every fixture
-- label starts with "la" (and "LA" for cars).
select test.suite('22 launch audit');

select test.mk_owner('la_o');
select test.mk_user('la_admin', 'admin');
select test.mk_vehicle('LA1', 'la_o');
select test.mk_vehicle('LA2', 'la_o');
select test.mk_vehicle('LA3', 'la_o');
-- LA1 and LA2 share a model; LA3 is alone on its model page
update vehicles set model = 'Corolla LA', make = 'Toyota' where id in (test.id('vehicle:LA1'), test.id('vehicle:LA2'));
update vehicles set model = 'Civic LA', make = 'Honda' where id = test.id('vehicle:LA3');
insert into vehicle_listings (vehicle_id, slug, headline, status, published_at)
values (test.id('vehicle:LA1'), 'toyota-corolla-la1', 'Toyota Corolla', 'published', now()),
       (test.id('vehicle:LA2'), 'toyota-corolla-la2', 'Toyota Corolla', 'published', now()),
       (test.id('vehicle:LA3'), 'honda-civic-la3', 'Honda Civic', 'published', now());

-- ---------------------------------------------------------------- 1. sample cars
select test.ok('sample: a car is not a sample unless marked', not (select is_sample from vehicles where id = test.id('vehicle:LA1')));
update vehicles set is_sample = true where id in (test.id('vehicle:LA1'), test.id('vehicle:LA3'));

set role anon;
select test.eq('sample: the car page of a sample is not indexable', public.car_page('toyota-corolla-la1') ->> 'indexable', 'false');
select test.eq('sample: the public row says it is a sample', public.car_page('toyota-corolla-la1') ->> 'is_sample', 'true');
select test.eq('sample: a real car stays indexable', public.car_page('toyota-corolla-la2') ->> 'indexable', 'true');
select test.ok('sample: a sample car is still on the fleet page (it takes requests)',
  exists (select 1 from public.fleet() f where f ->> 'slug' = 'toyota-corolla-la1'));
select test.ok('sample: the sample car is not in the sitemap', not exists (select 1 from public.sitemap_rows() where path = '/cars/toyota-corolla-la1'));
select test.ok('sample: the real car is in the sitemap', exists (select 1 from public.sitemap_rows() where path = '/cars/toyota-corolla-la2'));
select test.ok('sample: a model page with one real car stays in the sitemap', exists (select 1 from public.sitemap_rows() where path = '/cars/toyota/corolla-la'));
select test.eq('sample: and is indexable', public.model_hub('toyota-corolla-la') ->> 'indexable', 'true');
select test.ok('sample: a model page of samples only is left out of the sitemap', not exists (select 1 from public.sitemap_rows() where path = '/cars/honda/civic-la'));
select test.eq('sample: and is not indexable', public.model_hub('honda-civic-la') ->> 'indexable', 'false');
reset role;

select test.ok('sample: Admin > Today lists the sample cars as a setup item',
  exists (select 1 from jsonb_array_elements(app.site_setup_problems()) p where p ->> 'field' = 'sample_cars' and p ->> 'message' like '% sample cars are on the website%'));

set role service_role;
select test.eq('sample: an Admin clears the flag',
  public.admin_do(test.id('la_admin'), 'vehicle_sample', jsonb_build_object('vehicle', test.id('vehicle:LA3'), 'is_sample', false)) ->> 'is_sample', 'false');
reset role;
select test.ok('sample: the car is now in the sitemap', exists (select 1 from public.sitemap_rows() where path = '/cars/honda-civic-la3'));
select test.ok('sample: with its model page', exists (select 1 from public.sitemap_rows() where path = '/cars/honda/civic-la'));
select test.ok('sample: the change is in the audit log',
  exists (select 1 from audit_log where action = 'set_sample_car' and entity_id = test.id('vehicle:LA3')::text and after ->> 'is_sample' = 'false'));
select test.mk_user('la_va', 'va', 'fleet');
set role service_role;
select test.throws('sample: only an Admin changes the flag',
  format('select public.admin_do(%L, %L, %L::jsonb)', test.id('la_va'), 'vehicle_sample', jsonb_build_object('vehicle', test.id('vehicle:LA1'), 'is_sample', false)), null);
reset role;
set role authenticated;
select test.throws('sample: a browser cannot call the admin actions',
  format('select public.admin_do(%L, %L, %L::jsonb)', test.id('la_admin'), 'vehicle_sample', '{}'), 'permission denied');
reset role;
-- the other admin actions still go through
set role service_role;
select public.admin_do(test.id('la_admin'), 'vehicle_save', jsonb_build_object('vehicle', test.id('vehicle:LA2'), 'values', jsonb_build_object('colour', 'Blue')));
reset role;
select test.eq('sample: the actions of 0030 still work behind the new ones', (select colour from vehicles where id = test.id('vehicle:LA2')), 'Blue');
update vehicles set is_sample = false where id = test.id('vehicle:LA1');

-- ---------------------------------------------------------------- 2. a review is published only with consent
select test.mk_renter('la_r');
select test.mk_booking('LA-1', 'LA2', 'la_r', to_char(now() - interval '12 days', 'YYYY-MM-DD 10:00'), to_char(now() - interval '9 days', 'YYYY-MM-DD 10:00'), 'closed');
select test.mk_booking('LA-2', 'LA2', 'la_r', to_char(now() - interval '8 days', 'YYYY-MM-DD 10:00'), to_char(now() - interval '6 days', 'YYYY-MM-DD 10:00'), 'closed');
set role service_role;
select public.renter_submit_review(test.id('booking:LA-1'), test.id('la_r'), 5, 'Good', 'Clean car.', false);
select public.renter_submit_review(test.id('booking:LA-2'), test.id('la_r'), 4, 'Fine', 'On time.', true);
select test.throws('review: without the consent to publish an Admin cannot publish it',
  format('select public.admin_do(%L, %L, %L::jsonb)', test.id('la_admin'), 'review_publish',
         jsonb_build_object('id', (select id from reviews where booking_id = test.id('booking:LA-1')))), 'did not agree');
select test.ok('review: with the consent it is published',
  (public.admin_do(test.id('la_admin'), 'review_publish', jsonb_build_object('id', (select id from reviews where booking_id = test.id('booking:LA-2')))) ->> 'slug') = 'toyota-corolla-la2');
reset role;
select test.eq('review: statuses', (select string_agg(status::text, ',' order by booking_id = test.id('booking:LA-2')) from reviews where booking_id in (test.id('booking:LA-1'), test.id('booking:LA-2'))),
  'pending,published');

-- ---------------------------------------------------------------- 3. marketing waits for the mailing address
create table test.la_site as select id, mailing_address from site_settings;
update site_settings set mailing_address = null, mailing_address_required = true;
-- this file runs last: rows other files left waiting are set aside so the caps count only these two
update notification_outbox set status = 'skipped' where status in ('queued', 'delayed', 'sending');
insert into notification_outbox (code, category, priority, audience, to_address, payload, dedupe_key, send_after) values
  ('renter_comeback_1w', 'marketing', 5, 'renter', 'la_m@example.test', '{}', 'la:mkt', test.at('2031-10-06 11:00')),
  ('renter_offer_ready', 'transactional', 1, 'renter', 'la_t@example.test', '{}', 'la:txn', test.at('2031-10-06 11:00'));
select test.eq('marketing: without the mailing address only the transactional email is claimed',
  (select string_agg(left(to_address, 4), ',') from app.outbox_claim(100, test.at('2031-10-06 12:00'))), 'la_t');
select test.eq('marketing: the marketing email waits an hour and says why',
  (select status || '/' || status_reason || '/' || (send_after = test.at('2031-10-06 13:00'))::text from notification_outbox where dedupe_key = 'la:mkt'),
  'delayed/waiting for the mailing address (Admin > Settings > Site)/true');
update site_settings set mailing_address = '100 Sample Street, Toronto, Ontario';
select app.outbox_mark_sent(id, 'la-prov', null, test.at('2031-10-06 12:01')) from notification_outbox where dedupe_key = 'la:txn';
select test.eq('marketing: once the address is entered it goes out',
  (select string_agg(left(to_address, 4), ',') from app.outbox_claim(100, test.at('2031-10-06 13:00'))), 'la_m');
update site_settings s set mailing_address = o.mailing_address from test.la_site o where o.id = s.id;
update notification_outbox set status = 'skipped' where dedupe_key in ('la:mkt', 'la:txn');
set role authenticated;
select test.throws('marketing: a browser cannot run the sender', $$select * from app.outbox_claim()$$, 'permission denied');
reset role;

-- ---------------------------------------------------------------- 4. the registry visit email waits for its date
insert into vehicle_onboardings (id, vehicle_id, status) values (test.id('onb:LA'), test.id('vehicle:LA3'), 'registry_booked');
select test.eq('registry visit: no email while the visit has no date',
  (select count(*) from app_events where code = 'owner_registry_visit' and entity_id = test.id('onb:LA')), 0::bigint);
update vehicle_onboardings set registry_visit_at = now() + interval '3 days', registry_place = 'ServiceOntario, 777 Bay St' where id = test.id('onb:LA');
select test.eq('registry visit: the email goes once the date is entered',
  (select count(*) from app_events where code = 'owner_registry_visit' and entity_id = test.id('onb:LA')), 1::bigint);
