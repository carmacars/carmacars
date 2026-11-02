-- 99: Facebook Marketplace kits, the schedule's data, the Marketplace log and "How did you hear about us?" (migration 0410).
-- Fixtures start with "mpk".
select test.suite('99 marketplace kits');
select test.mk_user('mpk_admin', 'admin');
select test.mk_user('mpk_cs', 'va', 'cs');
select test.mk_owner('mpk_own');
insert into vehicles (id, owner_id, year, make, model, trim, colour, plate, vin, class, status, management_mode, onboarding_method, body_type, supply_type, is_sample, odometer_km)
values (test.id('vehicle:MPK1'), test.id('owner:mpk_own'), 2023, 'Toyota', 'Camry', 'SE', 'Grey', 'MPK1AA', 'MPKVIN00000000001', 'standard', 'available', 'managed', 'transfer', 'Sedan', 'company', false, 41000),
       (test.id('vehicle:MPK2'), test.id('owner:mpk_own'), 2022, 'Honda', 'CR-V', null, 'White', 'MPK2AA', 'MPKVIN00000000002', 'suv', 'available', 'managed', 'transfer', 'SUV', 'program_owner', false, null);
insert into rate_cards (vehicle_id, daily_rate_cents, weekend_rate_cents, weekly_rate_cents, monthly_rate_cents, km_allowance_per_day, overage_cents_per_km, deposit_cents, delivery_fee_cents, pickup_fee_cents, effective_from)
select x.id, x.p, x.p + 1000, x.p * 6, x.p * 20, 200, 35, 50000, 7500, 7500, now() - interval '1 day'
  from (values (test.id('vehicle:MPK1'), 8900), (test.id('vehicle:MPK2'), 9900)) x(id, p);
insert into vehicle_listings (vehicle_id, slug, headline, status, published_at, seats, transmission, body_style, home_area)
select v.id, 'mpk-' || lower(v.plate), 'x', 'published', now(), 5, 'Automatic', v.body_type, case when v.plate = 'MPK2AA' then 'Mississauga' end from vehicles v where v.plate like 'MPK%'
on conflict (vehicle_id) do update set status = excluded.status, published_at = now(), slug = excluded.slug, home_area = excluded.home_area;
insert into vehicle_odometer_readings (vehicle_id, km, source) values (test.id('vehicle:MPK1'), 43210, 'manual');

-- the settings and the read
select test.ok('settings default to 4 a day, renew after 7 days, Toronto', (select marketplace_posts_per_day = 4 and marketplace_renew_days = 7 and marketplace_location = 'Toronto, Ontario' from program_settings limit 1));
create temp table mpk_r as select public.door(test.id('mpk_admin'), 'aal2', 'admin_read', 'marketplace', '{}') r;
select test.ok('the read carries every published car with its kit facts', (select count(*) from mpk_r, jsonb_array_elements(r -> 'cars') c where c ->> 'vehicle_id' in (test.id('vehicle:MPK1')::text, test.id('vehicle:MPK2')::text)) = 2);
select test.eq('the odometer is the highest reading', (select (r -> 'extra' -> test.id('vehicle:MPK1')::text ->> 'odometer_km')::int from mpk_r), 43210);
select test.eq('the car''s home area', (select r -> 'extra' -> test.id('vehicle:MPK2')::text ->> 'home_area' from mpk_r), 'Mississauga');
select test.eq('the settings come with it', (select (r -> 'settings' ->> 'posts_per_day')::int from mpk_r), 4);
select test.throws('Admins only', format($s$select public.door(%L, 'aal2', 'admin_read', 'marketplace', '{}')$s$, test.id('mpk_cs')));

-- posted, renewed, updated after a price change, taken down
select public.door(test.id('mpk_admin'), 'aal2', 'admin_do', 'marketplace_log', jsonb_build_object('kind', 'posted', 'vehicle', test.id('vehicle:MPK1'),
  'url', 'https://www.facebook.com/marketplace/item/1000000000001/', 'title', 'Rent a 2023 Toyota Camry in Toronto, from $89 a day', 'body', 'For rent by the day, week or month (not for sale).', 'on_date', app.today() - 8));
select test.ok('posted: a live Marketplace ad with its renewal date', exists (select 1 from ad_postings where vehicle_id = test.id('vehicle:MPK1') and channel = 'fb_marketplace' and status = 'live' and renewed_on = app.today() - 8));
select test.ok('and a line in the log', exists (select 1 from marketplace_log where vehicle_id = test.id('vehicle:MPK1') and kind = 'posted'));
select public.door(test.id('mpk_admin'), 'aal2', 'admin_do', 'marketplace_log', jsonb_build_object('kind', 'renewed', 'vehicle', test.id('vehicle:MPK1')));
select test.ok('renewed today', (select renewed_on = app.today() from ad_postings where vehicle_id = test.id('vehicle:MPK1') and channel = 'fb_marketplace' and status = 'live'));
select test.eq('today''s posts and renewals count against the day', (select (public.door(test.id('mpk_admin'), 'aal2', 'admin_read', 'marketplace', '{}') ->> 'done_today')::int), 1);
select test.throws('renewing a car never posted', format($s$select public.door(%L, 'aal2', 'admin_do', 'marketplace_log', %L)$s$, test.id('mpk_admin'),
  jsonb_build_object('kind', 'renewed', 'vehicle', test.id('vehicle:MPK2'))), 'record it as posted first');
select test.throws('a date ahead', format($s$select public.door(%L, 'aal2', 'admin_do', 'marketplace_log', %L)$s$, test.id('mpk_admin'),
  jsonb_build_object('kind', 'posted', 'vehicle', test.id('vehicle:MPK2'), 'on_date', app.today() + 1)), 'future');
select test.throws('a long dash in the text', format($s$select public.door(%L, 'aal2', 'admin_do', 'marketplace_log', %L)$s$, test.id('mpk_admin'),
  jsonb_build_object('kind', 'posted', 'vehicle', test.id('vehicle:MPK2'), 'body', 'Clean car ' || chr(8212) || ' great price')), 'long dash');

update rate_cards set daily_rate_cents = 12900 where vehicle_id = test.id('vehicle:MPK1');
select app.ads_check_vehicle(test.id('vehicle:MPK1'));
select test.ok('a price change marks the Marketplace ad to update, with a task', exists (select 1 from ad_postings a join tasks t on t.id = a.update_task_id
  where a.vehicle_id = test.id('vehicle:MPK1') and a.channel = 'fb_marketplace' and a.needs_update and t.task_type = 'ad_update' and t.status = 'open'));
select public.door(test.id('mpk_admin'), 'aal2', 'admin_do', 'marketplace_log', jsonb_build_object('kind', 'updated', 'vehicle', test.id('vehicle:MPK1'), 'price_line', 'From $129 a day, plus HST.'));
select test.ok('updated: the ad is current and its task done', exists (select 1 from ad_postings a join tasks t on t.related_id = a.id and t.task_type = 'ad_update'
  where a.vehicle_id = test.id('vehicle:MPK1') and a.channel = 'fb_marketplace' and not a.needs_update and t.status = 'done'));
select public.door(test.id('mpk_admin'), 'aal2', 'admin_do', 'marketplace_log', jsonb_build_object('kind', 'posted', 'vehicle', test.id('vehicle:MPK1'),
  'url', 'https://www.facebook.com/marketplace/item/1000000000002/'));
select test.ok('posted again with a new address: the old ad ends, one live ad', (select count(*) filter (where status = 'live') = 1 and count(*) filter (where status = 'removed') = 1
  from ad_postings where vehicle_id = test.id('vehicle:MPK1') and channel = 'fb_marketplace'));
select public.door(test.id('mpk_admin'), 'aal2', 'admin_do', 'marketplace_log', jsonb_build_object('kind', 'removed', 'vehicle', test.id('vehicle:MPK1'), 'note', 'Car sold'));
select test.ok('taken down', not exists (select 1 from ad_postings where vehicle_id = test.id('vehicle:MPK1') and channel = 'fb_marketplace' and status = 'live'));

-- the inbox: numbers become leads with a call-back task, the same number once
select public.door(test.id('mpk_admin'), 'aal2', 'admin_do', 'marketplace_inbox', jsonb_build_object('conversations', 12, 'replies', 14, 'note', 'Evening session',
  'leads', jsonb_build_array(jsonb_build_object('name', 'Sam Example', 'phone', '(416) 555-0142', 'vehicle', test.id('vehicle:MPK2'), 'message', 'Wants it Friday to Sunday'))));
select test.ok('a lead from Marketplace, with the car''s code', exists (select 1 from leads where source = 'fb_marketplace' and phone = '+14165550142' and kind = 'contact'
  and utm_source = 'fb_marketplace' and utm_medium = 'marketplace' and message like '%Honda CR-V%'));
select test.ok('a call-back task for customer service', exists (select 1 from tasks t join leads l on l.id = t.related_id where l.phone = '+14165550142' and t.task_type = 'marketplace_callback' and t.queue = 'cs' and t.status = 'open'));
select public.door(test.id('mpk_admin'), 'aal2', 'admin_do', 'marketplace_inbox', jsonb_build_object('conversations', 3, 'leads', jsonb_build_array(jsonb_build_object('phone', '416-555-0142'))));
select test.eq('the same number again is the same lead', (select count(*)::int from leads where phone = '+14165550142' and source = 'fb_marketplace'), 1);
select public.door(test.id('mpk_admin'), 'aal2', 'admin_do', 'marketplace_inbox', jsonb_build_object('conversations', 0,
  'numbers_text', E'Alex Sample, (647) 555-0199, ' || (select car_code from vehicles where id = test.id('vehicle:MPK2')) || E'\n\n905.555.0123 Jordan'));
select test.ok('numbers typed one per line: the phone, the name and the car code', exists (select 1 from leads where phone = '+16475550199' and name = 'Alex Sample'
  and (payload ->> 'vehicle_id')::uuid = test.id('vehicle:MPK2')) and exists (select 1 from leads where phone = '+19055550123' and name = 'Jordan'));
select test.eq('the inbox sessions are logged', (select count(*)::int from marketplace_log where kind = 'inbox'), 3);
select test.throws('not a phone number', format($s$select public.door(%L, 'aal2', 'admin_do', 'marketplace_inbox', %L)$s$, test.id('mpk_admin'),
  '{"conversations": 1, "leads": [{"phone": "12"}]}'), 'Not a phone number');
select test.throws('the count is needed', format($s$select public.door(%L, 'aal2', 'admin_do', 'marketplace_inbox', '{}')$s$, test.id('mpk_admin')), 'how many conversations');
select test.eq('the week''s numbers', (select (public.door(test.id('mpk_admin'), 'aal2', 'admin_read', 'marketplace', '{}') -> 'week' ->> 'numbers')::int), 4);

-- settings
select public.door(test.id('mpk_admin'), 'aal2', 'admin_do', 'marketplace_settings', '{"posts_per_day": 3, "renew_days": 10, "location": "Mississauga, Ontario"}');
select test.ok('settings saved', (select marketplace_posts_per_day = 3 and marketplace_renew_days = 10 and marketplace_location = 'Mississauga, Ontario' from program_settings limit 1));
select test.throws('at most 10 a day', format($s$select public.door(%L, 'aal2', 'admin_do', 'marketplace_settings', '{"posts_per_day": 40}')$s$, test.id('mpk_admin')));
update program_settings set marketplace_posts_per_day = 4, marketplace_renew_days = 7, marketplace_location = 'Toronto, Ontario' where true;

-- "How did you hear about us?" and the channel report
select test.mk_renter('mpk_renter');
select test.mk_booking('MPK-1001', 'MPK1', 'mpk_renter', (app.today() + 20)::text || ' 10:00', (app.today() + 23)::text || ' 10:00', 'confirmed');
create temp table mpk_b as select b.id, b.booking_number from bookings b where b.id = test.id('booking:MPK-1001');
update bookings set marketing_source = null, heard_about = null, created_at = now(), source = 'web' where id = (select id from mpk_b);
select test.ok('the form''s answer is taken', public.server_booking_heard_about((select booking_number from mpk_b), 'fb_marketplace'));
select test.eq('and kept on the booking', (select heard_about from bookings where id = (select id from mpk_b)), 'fb_marketplace');
select test.ok('only once', not public.server_booking_heard_about((select booking_number from mpk_b), 'google'));
select test.throws('an answer not on the list', $$select public.server_booking_heard_about('X', 'billboard')$$, 'from the list');
select test.eq('it counts for the booking when the visit says nothing', (select app.booking_channel(b, null::booking_attribution, 'last') from bookings b where b.id = (select id from mpk_b)), 'fb_marketplace');
update bookings set marketing_source = 'walk_in' where id = (select id from mpk_b);
select test.eq('staff''s source still wins', (select app.booking_channel(b, null::booking_attribution, 'last') from bookings b where b.id = (select id from mpk_b)), 'walk_in');
select test.eq('TikTok has a label', app.ad_channel_label('tiktok'), 'TikTok');
select test.throws('the form function is not for the public', $$set local role anon; select public.server_booking_heard_about('X', 'google')$$);
select test.ok('the log is Admin only (row-level security on)', (select relrowsecurity from pg_class where relname = 'marketplace_log'));
