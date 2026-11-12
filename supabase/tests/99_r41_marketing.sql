-- 99: migration 2520 (release 41): marketing emails to everyone who gave us their email on the site, unless they unsubscribed;
-- the weekly email and one email per new car, queued at the marketing priority within the day's allowance.
-- Fixtures: "zm". Test data only (example.test addresses, 555 numbers).
select test.suite('99 r41 marketing emails to everyone, weekly and new car campaigns (2520)');

select test.mk_user('zm_admin', 'admin');
select test.mk_user('zm_sales', 'va', 'sales');
select test.mk_user('zm_staff', 'va', 'cs');
select test.mk_owner('zm_owner');
select test.mk_renter('zm_r');
select test.mk_renter('zm_r2');
-- a renter lead from the site, a Turo guest, a lead staff typed in, an owner lead
insert into leads (id, kind, name, email, source) values
  (test.id('lead:zm_web'), 'contact', 'Wendy Web', 'zm_lead@example.test', 'web'),
  (test.id('lead:zm_turo'), 'turo_guest', 'Tara Turo', 'zm_turo@example.test', 'turo'),
  (test.id('lead:zm_manual'), 'contact', 'Manny Manual', 'zm_manual@example.test', 'manual'),
  (test.id('lead:zm_owner'), 'owner_program', 'Owen Owner', 'zm_ownerlead@example.test', 'web');
-- forms left unfinished: a booking request typed and never sent counts; the owner application does not
insert into contact_captures (visitor_id, form, name, email) values
  (test.id('vis:zm1'), 'booking_request', 'Cara Capture', 'zm_cap@example.test'),
  (test.id('vis:zm2'), 'owner_application', 'Olga Apply', 'zm_ownerapp@example.test');

-- ---------------------------------------------------------------- settings and consent
select test.eq('settings: every switch is on by default',
  (select marketing_everyone_enabled and marketing_weekly_enabled and marketing_new_vehicle_enabled and marketing_auto_volume from app.settings()), true);
select test.eq('consent: an account that never ticked the box may get marketing (provided on site)',
  app.has_marketing_consent(test.id('zm_r'), 'express'), true);
select test.eq('consent: an address without an account may too', app.has_marketing_consent(null, 'express'), true);

-- ---------------------------------------------------------------- the audience
select app.marketing_audience_refresh(now());
select test.eq('audience: the renter, the site lead and the unfinished booking form are in, with the basis and the source',
  (select string_agg(email || ':' || first_source || ':' || consent_basis, ',' order by email) from marketing_contacts
    where email in ('zm_cap@example.test', 'zm_lead@example.test', 'zm_r@example.test')),
  'zm_cap@example.test:unfinished_form:provided_on_site,zm_lead@example.test:lead:provided_on_site,zm_r@example.test:renter:provided_on_site');
select test.eq('audience: never staff, owners, Turo guests, leads staff typed in, owner leads or owner applications',
  (select count(*) from marketing_contacts where email in ('zm_staff@example.test', 'zm_owner@example.test', 'zm_turo@example.test',
     'zm_manual@example.test', 'zm_ownerlead@example.test', 'zm_ownerapp@example.test')), 0::bigint);
select test.eq('audience: the renter with an account is one address with both sources',
  (select sources from marketing_contacts where email = 'zm_r@example.test'), array['account', 'renter']);
select test.eq('audience: everyone in it may be emailed now', app.marketing_can_email('zm_cap@example.test'), true);

-- the everyone switch off: only the express consent counts again
update program_settings set marketing_everyone_enabled = false;
select test.eq('switch off: an account without the tick may not get marketing', app.marketing_can_email('zm_r@example.test'), false);
select test.eq('switch off: nor an address without an account', app.marketing_can_email('zm_cap@example.test'), false);
update program_settings set marketing_everyone_enabled = true;

-- ---------------------------------------------------------------- more marketing automatically, within the free budgets
select test.ok('allowance: at least the old daily maximum, and the free capacity less the reserve',
  app.marketing_daily_max(now()) >= (select notify_marketing_daily_max from app.settings())
  and app.marketing_daily_max(now()) >= least(app.email_day_cap(now()) - 60, app.marketing_daily_max(now())));
update program_settings set marketing_auto_volume = false;
select test.eq('allowance: switched off it is the old daily maximum', app.marketing_daily_max(now()), (select notify_marketing_daily_max from app.settings()));
update program_settings set marketing_auto_volume = true;
select test.eq('claim: no version of the claim still holds marketing at the fixed maximum',
  (select count(*) from pg_proc where proname like 'outbox_claim%' and prosrc like '%s.notify_marketing_daily_max%'), 0::bigint);

-- ---------------------------------------------------------------- a new car: once per car, never a sample
select test.mk_vehicle('zm_car', 'zm_owner');
select test.mk_vehicle('zm_sample', 'zm_owner');
update vehicles set bookings_enabled = true where id in (test.id('vehicle:zm_car'), test.id('vehicle:zm_sample'));
update vehicles set is_sample = true where id = test.id('vehicle:zm_sample');
insert into vehicle_listings (vehicle_id, slug, status, published_at, seats, transmission) values
  (test.id('vehicle:zm_car'), 'zm-test-car', 'published', now(), 5, 'automatic'),
  (test.id('vehicle:zm_sample'), 'zm-sample-car', 'published', now(), 5, 'automatic');
-- a Thursday at 11:00, Toronto time: the weekly email's day and hour, inside the marketing hours
create function pg_temp.at(p text) returns timestamptz language sql as $$ select (p::timestamp) at time zone 'America/Toronto' $$;
update program_settings set marketing_weekly_dow = extract(isodow from pg_temp.at('2031-01-16 11:00'))::smallint, marketing_weekly_hour = 10;
select app.job_marketing(pg_temp.at('2031-01-16 11:00'));
select test.eq('new car: one campaign for the car', (select count(*) from marketing_campaigns where vehicle_id = test.id('vehicle:zm_car')), 1::bigint);
select test.eq('new car: never for a sample car', (select count(*) from marketing_campaigns where vehicle_id = test.id('vehicle:zm_sample')), 0::bigint);
select test.eq('new car: the renter, the lead and the unfinished form are on it',
  (select count(*) from marketing_campaign_sends s join marketing_campaigns m on m.id = s.campaign_id
    where m.vehicle_id = test.id('vehicle:zm_car') and s.email in ('zm_cap@example.test', 'zm_lead@example.test', 'zm_r@example.test')), 3::bigint);
select test.eq('new car: its email names the car and links to it',
  (select payload ->> 'car_url' from marketing_campaigns where vehicle_id = test.id('vehicle:zm_car')), 'https://carmacars.ca/cars/zm-test-car');
select test.eq('weekly: one campaign for the week', (select count(*) from marketing_campaigns where kind = 'weekly' and week_of = date '2031-01-13'), 1::bigint);
select test.ok('weekly: the cars come from the live listings',
  (select payload -> 'cars' @> jsonb_build_array(jsonb_build_object('url', 'https://carmacars.ca/cars/zm-test-car')) or jsonb_array_length(payload -> 'cars') = 6
     from marketing_campaigns where kind = 'weekly' and week_of = date '2031-01-13'));
select test.ok('weekly: never a sample car',
  not (select payload -> 'cars' @> jsonb_build_array(jsonb_build_object('url', 'https://carmacars.ca/cars/zm-sample-car'))
         from marketing_campaigns where kind = 'weekly' and week_of = date '2031-01-13'));

-- the test's own people go next (everyone else in the shared test database is set aside)
update marketing_campaign_sends set status = 'skipped', reason = 'test' where status = 'waiting'
   and email not in ('zm_cap@example.test', 'zm_lead@example.test', 'zm_r@example.test', 'zm_r2@example.test');
update marketing_campaign_sends set status = 'skipped', reason = 'test' where status = 'queued'
   and email not in ('zm_cap@example.test', 'zm_lead@example.test', 'zm_r@example.test', 'zm_r2@example.test');
-- the cars the earlier suites listed have their own new-car campaigns to the same people: set aside too
update marketing_campaign_sends s set status = 'skipped', reason = 'test' from marketing_campaigns m
 where m.id = s.campaign_id and s.status = 'waiting' and m.kind = 'new_vehicle' and m.vehicle_id is distinct from test.id('vehicle:zm_car');
select app.job_marketing(pg_temp.at('2031-01-16 13:00'));
select test.eq('queue: each of them gets the new car email first',
  (select count(*) from marketing_campaign_sends s join marketing_campaigns m on m.id = s.campaign_id
    where m.vehicle_id = test.id('vehicle:zm_car') and s.status = 'queued' and s.event_id is not null
      and s.email in ('zm_cap@example.test', 'zm_lead@example.test', 'zm_r@example.test')), 3::bigint);
select test.eq('queue: at most one campaign email a person a day (the weekly email waits for tomorrow)',
  (select s.status from marketing_campaign_sends s join marketing_campaigns m on m.id = s.campaign_id
    where m.kind = 'weekly' and m.week_of = date '2031-01-13' and s.email = 'zm_r@example.test'), 'waiting');
select app.process_events(null, pg_temp.at('2031-01-16 13:01'));
select test.eq('outbox: a marketing email at the lowest priority, with its unsubscribe link and nothing missing',
  (select category || ':' || priority || ':' || (payload ->> 'unsubscribe_url' like 'https://carmacars.ca/%unsubscribe?token=%') || ':' || cardinality(missing_variables)
     from notification_outbox where code = 'marketing_new_vehicle' and to_address = 'zm_r@example.test'), 'marketing:5:true:0');
select test.eq('outbox: addressed by first name', (select payload ->> 'first_name' from notification_outbox where code = 'marketing_new_vehicle' and to_address = 'zm_r@example.test'), 'Zm');
select test.eq('outbox: no portal notice for a campaign email',
  (select count(*) from notifications where code like 'marketing_%' and user_id = test.id('zm_r')), 0::bigint);
select app.job_marketing(pg_temp.at('2031-01-16 13:30'));
select test.eq('once per car: running again starts nothing new for it', (select count(*) from marketing_campaigns where vehicle_id = test.id('vehicle:zm_car')), 1::bigint);
select test.eq('once per person: nobody is on a campaign twice',
  (select count(*) from (select campaign_id, email from marketing_campaign_sends group by 1, 2 having count(*) > 1) z), 0::bigint);

-- ---------------------------------------------------------------- unsubscribe: honoured at once, for every marketing email
select app.unsubscribe((select unsubscribe_token from notification_outbox where code = 'marketing_new_vehicle' and to_address = 'zm_r@example.test'));
select test.eq('unsubscribe: the address is suppressed for marketing', app.email_suppressed('zm_r@example.test', true), true);
select test.eq('unsubscribe: the account with that address is unsubscribed too',
  (select marketing_unsubscribed_at is not null from users where id = test.id('zm_r')), true);
select test.eq('unsubscribe: the waiting weekly email is not sent', (select s.status || ':' || s.reason from marketing_campaign_sends s join marketing_campaigns m on m.id = s.campaign_id
    where m.kind = 'weekly' and m.week_of = date '2031-01-13' and s.email = 'zm_r@example.test'), 'skipped:unsubscribed');
select test.eq('unsubscribe: no marketing email may go to them', app.marketing_can_email('zm_r@example.test'), false);
select test.eq('unsubscribe: nor any marketing email of the event queue', app.has_marketing_consent(test.id('zm_r'), 'implied'), false);
-- the account's own box (renter_set_marketing false) unsubscribes the same way
select public.renter_set_marketing(test.id('zm_r2'), false);
select test.eq('account box off: no marketing email', app.marketing_can_email('zm_r2@example.test'), false);
select app.job_marketing(pg_temp.at('2031-01-17 11:00'));
select test.eq('account box off: their waiting weekly email is skipped, not queued',
  (select s.status from marketing_campaign_sends s join marketing_campaigns m on m.id = s.campaign_id
    where m.kind = 'weekly' and m.week_of = date '2031-01-13' and s.email = 'zm_r2@example.test'), 'skipped');

-- a car that stops being listed: the people still waiting for its email do not get it
select test.mk_vehicle('zm_car2', 'zm_owner');
update vehicles set bookings_enabled = true where id = test.id('vehicle:zm_car2');
insert into vehicle_listings (vehicle_id, slug, status, published_at) values (test.id('vehicle:zm_car2'), 'zm-test-car2', 'published', now());
select app.job_marketing(pg_temp.at('2031-01-18 09:00'));
update marketing_campaign_sends s set status = 'skipped', reason = 'test' from marketing_campaigns m
 where m.id = s.campaign_id and m.vehicle_id = test.id('vehicle:zm_car2') and s.status = 'waiting' and s.email <> 'zm_lead@example.test';
update vehicle_listings set status = 'unpublished' where vehicle_id = test.id('vehicle:zm_car2');
select app.job_marketing(pg_temp.at('2031-01-18 12:00'));
select test.eq('car no longer listed: its email is not sent',
  (select s.status || ':' || s.reason from marketing_campaign_sends s join marketing_campaigns m on m.id = s.campaign_id
    where m.vehicle_id = test.id('vehicle:zm_car2') and s.email = 'zm_lead@example.test'), 'skipped:the car is no longer listed');

-- ---------------------------------------------------------------- the page: Admin edits, Sales reads, nobody else
select test.eq('page: the Admin sees the audience and may edit', (public.server_marketing_emails(test.id('zm_admin')) ->> 'can_edit')::boolean, true);
select test.ok('page: the audience, the campaigns and the unsubscribed are counted',
  (select (x ->> 'audience')::int > 0 and jsonb_array_length(x -> 'campaigns') > 0 and (x ->> 'unsubscribed')::int >= 1
     from (select public.server_marketing_emails(test.id('zm_admin')) x) z));
select test.eq('page: Sales reads it only', (public.server_marketing_emails(test.id('zm_sales')) ->> 'can_edit')::boolean, false);
select test.throws('page: a renter may not', $$select public.server_marketing_emails(test.id('zm_r'))$$, '%Admin or Sales only%');

-- ---------------------------------------------------------------- the emails and the grants
select test.eq('catalogue: both campaign emails are marketing at the lowest priority',
  (select string_agg(code || ':' || category || ':' || priority, ',' order by code) from notification_catalogue where code in ('marketing_new_vehicle', 'marketing_weekly')),
  'marketing_new_vehicle:marketing:5,marketing_weekly:marketing:5');
select test.eq('grants: the browser roles run none of the new functions',
  (select count(*) from pg_proc p join pg_namespace n on n.oid = p.pronamespace
    where p.proname in ('marketing_new_vehicle_since', 'marketing_can_email', 'marketing_audience_refresh', 'marketing_daily_max', 'marketing_price',
                        'marketing_listed_cars', 'marketing_weekly_payload', 'marketing_new_vehicle_payload', 'marketing_campaign_start', 'job_marketing', 'server_marketing_emails')
      and (has_function_privilege('anon', p.oid, 'execute') or has_function_privilege('authenticated', p.oid, 'execute'))), 0::bigint);
set role authenticated;
select set_config('request.jwt.claims', json_build_object('sub', test.id('zm_r2'), 'role', 'authenticated')::text, false);
select test.ok('browser: a renter''s session reads nothing of the audience or the campaigns',
  test.visible($q$select 1 from marketing_contacts$q$) <= 0 and test.visible($q$select 1 from marketing_campaign_sends$q$) <= 0
  and test.visible($q$select 1 from marketing_campaigns$q$) <= 0);
reset role;
select set_config('request.jwt.claims', '', false);

-- restore what other suites read
update program_settings set marketing_weekly_dow = 4, marketing_weekly_hour = 10;
