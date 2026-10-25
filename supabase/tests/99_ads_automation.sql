-- 99: advertising automation (migration 0167, docs/changes/2026-10-25-advertising-automation.md).
-- Posted ads and the rate change tasks; the first and last touch kept with a request and the bookings per channel report;
-- the Facebook Page and Instagram drafts and the Meta publishing switch (off until a token is entered); owner recruitment:
-- the consent log, calls, and messages that go only when the log allows them. Fixtures start with "ads".
select test.suite('99 advertising automation');

select test.mk_user('ads_admin', 'admin');
select test.mk_user('ads_sales', 'va', 'sales');
select test.mk_owner('ads_olive');
select test.mk_vehicle('ads_car', 'ads_olive');
select test.mk_vehicle('ads_car2', 'ads_olive');
select test.mk_renter('ads_rita');
insert into vehicle_listings (vehicle_id, slug, headline, seats, transmission, status, published_at)
values (test.id('vehicle:ads_car'), 'c300-ads-car', 'Mercedes C 300', 5, 'automatic', 'published', now()),
       (test.id('vehicle:ads_car2'), 'c300-ads-car2', 'Mercedes C 300', 5, 'automatic', 'published', now());
update vehicles set car_code = 'CC-AD51' where id = test.id('vehicle:ads_car');

create temp table s99a as select null::text as k, null::jsonb as v limit 0;
create or replace function test.s99a(p_k text) returns jsonb language sql stable as $$ select v from pg_temp.s99a where k = p_k $$;
create or replace function test.s99post(p_k text) returns ad_postings language sql stable as $$ select * from ad_postings where id = (test.s99a(p_k) ->> 'id')::uuid $$;
create or replace function test.s99task(p_k text) returns tasks language sql stable as $$ select * from tasks where id = (test.s99post(p_k)).update_task_id $$;
-- a rate change as the Rates screen makes it (the old card closed and the new one opened in one statement)
create or replace function test.s99rates(p_car text, p_daily bigint, p_weekly bigint default 56000) returns void language sql as $$
  select app.set_rate_card(test.id('vehicle:' || p_car), p_daily, 12000, p_weekly, 180000, now(), test.id('ads_admin'),
    jsonb_build_object('deposit_cents', 100000, 'delivery_fee_cents', 7500, 'pickup_fee_cents', 7500, 'km_allowance_per_day', 200, 'overage_cents_per_km', 35)) $$;

-- ================================================================ 1. words
select test.eq('channel of a visit: the campaign source wins', app.ad_channel_of('Kijiji', 'www.google.com'), 'kijiji');
select test.eq('channel of a visit: our own codes', app.ad_channel_of('fb_marketplace', null) || '/' || app.ad_channel_of('google_business', null) || '/' || app.ad_channel_of('ig', null), 'fb_marketplace/google_business/instagram');
select test.eq('channel of a visit: the referring site', app.ad_channel_of(null, 'l.facebook.com') || '/' || app.ad_channel_of('', 'www.google.ca') || '/' || app.ad_channel_of(null, 'blog.example.com') || '/' || app.ad_channel_of(null, null),
  'facebook/google/other_site/direct');
select test.eq('price line: day, week, 30 days, plus HST', app.ad_price_line('{"daily": 7500, "weekly": 45000, "monthly": 160000}'::jsonb), 'From $75 a day, $450 a week, $1,600 for 30 days, plus HST.');
select test.eq('price line: cents when there are cents, nothing without a daily rate', app.ad_price_line('{"daily": 7250}'::jsonb) || '/' || coalesce(app.ad_price_line('{"weekly": 100}'::jsonb), 'none'), 'From $72.50 a day, plus HST./none');
select test.ok('text: a long dash is refused', app.ads_text_problem('Fast ' || chr(8212) || ' and cheap') is not null and app.ads_text_problem('A to B ' || chr(8211) || ' C') is not null);
select test.ok('text: the numbered company name is refused, CarmaCars is fine', app.ads_text_problem('By 18122211 Canada Inc.') is not null and app.ads_text_problem('By CarmaCars, Toronto') is null);
select test.eq('rate change: under 3% is not material', coalesce(app.ad_change_reason('{"taking": true, "daily": 10000}'::jsonb, '{"taking": true, "daily": 10200}'::jsonb, 300), 'none'), 'none');
select test.eq('rate change: 3% or more is', app.ad_change_reason('{"taking": true, "daily": 10000}'::jsonb, '{"taking": true, "daily": 11000}'::jsonb, 300), 'Daily rate $100 to $110.');
select test.eq('rate change: any deposit change is', app.ad_change_reason('{"taking": true, "deposit": 100000}'::jsonb, '{"taking": true, "deposit": 50000}'::jsonb, 300), 'Deposit $1,000 to $500.');
select test.ok('rate change: the car stopped taking requests', app.ad_change_reason('{"taking": true}'::jsonb, '{"taking": false}'::jsonb, 300) like 'The car stopped taking requests%');

-- ================================================================ 2. posted ads and the rate change tasks
select test.eq('snapshot: what an ad would say now', (select (s ->> 'taking') || '/' || (s ->> 'daily') || '/' || (s ->> 'deposit') from (select app.ad_snapshot(test.id('vehicle:ads_car')) s) x), 'true/10000/100000');
select test.throws('posting: an Admin''s', format($$select app.door(%L, 'aal2', 'admin_do', 'ad_posting_save', jsonb_build_object('vehicle', %L, 'channel', 'kijiji'))$$, test.id('ads_sales'), test.id('vehicle:ads_car')), 'admin');
select test.throws('posting: a known channel', format($$select app.ad_posting_save(%L, jsonb_build_object('vehicle', %L, 'channel', 'myspace'))$$, test.id('ads_admin'), test.id('vehicle:ads_car')), 'channel');
select test.throws('posting: the address starts with https://', format($$select app.ad_posting_save(%L, jsonb_build_object('vehicle', %L, 'channel', 'kijiji', 'url', 'kijiji.ca/x'))$$, test.id('ads_admin'), test.id('vehicle:ads_car')), 'https');
select test.throws('posting: no long dash in what was posted', format($$select app.ad_posting_save(%L, jsonb_build_object('vehicle', %L, 'channel', 'kijiji', 'body', 'Rent it ' || chr(8212) || ' now'))$$, test.id('ads_admin'), test.id('vehicle:ads_car')), 'dash');
insert into s99a select 'kj', app.door(test.id('ads_admin'), 'aal2', 'admin_do', 'ad_posting_save', jsonb_build_object('vehicle', test.id('vehicle:ads_car'), 'channel', 'kijiji',
  'url', 'https://www.kijiji.ca/v-cars/test/1', 'posted_on', app.today() - 3, 'title', 'Rent a 2023 Mercedes-Benz C 300 in Toronto', 'body', 'From $100 a day.'));
insert into s99a select 'cl', app.ad_posting_save(test.id('ads_admin'), jsonb_build_object('vehicle', test.id('vehicle:ads_car'), 'channel', 'craigslist', 'url', 'https://toronto.craigslist.org/x/1'));
select test.eq('posting: live, with the figures it says and the price line', (select status || '/' || (snapshot ->> 'daily') || '/' || price_line || '/' || needs_update from test.s99post('kj')),
  'live/10000/From $100 a day, $560 a week, $1,800 for 30 days, plus HST./false');
select test.eq('posting: one live ad per car and channel (posting again is the same ad)', (select (app.ad_posting_save(test.id('ads_admin'), jsonb_build_object('vehicle', test.id('vehicle:ads_car'), 'channel', 'kijiji')) ->> 'id') = test.s99a('kj') ->> 'id'), true);
select test.s99rates('ads_car', 10200);
select test.eq('a rate change under 3%: no task', (select needs_update::text || '/' || coalesce(update_task_id::text, 'none') from test.s99post('kj')), 'false/none');
select test.s99rates('ads_car', 11500);
select test.eq('a rate change of 3% or more: each live ad needs updating, a task for the sales assistants',
  (select a.needs_update || '/' || t.queue || '/' || t.task_type || '/' || t.status || '/' || (t.related_id = a.id) from ad_postings a join tasks t on t.id = a.update_task_id where a.id = (test.s99post('kj')).id), 'true/sales/ad_update/open/true');
select test.ok('the task: the channel and the car in its title, the change, the new price line, the ad and the new text in its detail',
  (select t.title like 'Update the Kijiji ad:%' and t.detail like 'Daily rate $100 to $115.%' and t.detail like '%New price line: From $115 a day%' and t.detail like '%https://www.kijiji.ca/v-cars/test/1%'
          and t.detail like '%/admin/marketing/listings?car=' || test.id('vehicle:ads_car') || '&channel=kijiji%' from test.s99task('kj') t));
select test.eq('every live ad of the car has its own task', (select count(distinct update_task_id) from ad_postings where vehicle_id = test.id('vehicle:ads_car') and needs_update), 2::bigint);
select test.eq('the other car''s ads are not touched', (select count(*) from tasks where task_type = 'ad_update' and vehicle_id = test.id('vehicle:ads_car2')), 0::bigint);
select test.s99rates('ads_car', 12000);
select test.eq('a second change: the same task, its detail brought up to date', (select count(*) || '/' || bool_and(detail like 'Daily rate $100 to $120.%') from tasks where task_type = 'ad_update' and related_id = (test.s99post('kj')).id), '1/true');
select app.ad_posting_save(test.id('ads_admin'), jsonb_build_object('vehicle', test.id('vehicle:ads_car'), 'channel', 'kijiji', 'body', 'From $120 a day.'));
select test.eq('marked updated: the ad says the new figures, the task is done', (select (snapshot ->> 'daily') || '/' || needs_update || '/' || updated_on from test.s99post('kj')) || '/'
  || (select status from tasks where task_type = 'ad_update' and related_id = (test.s99post('kj')).id), '12000/false/' || app.today() || '/done');
update tasks set status = 'done', completed_at = now(), completed_by = test.id('ads_sales') where id = (test.s99post('cl')).update_task_id;
select test.eq('the task closed by hand in Staff tasks counts as the ad updated', (select (snapshot ->> 'daily') || '/' || needs_update from test.s99post('cl')), '12000/false');
-- availability: the car stops taking requests, then takes them again at the rates the ad says
update vehicle_listings set status = 'paused' where vehicle_id = test.id('vehicle:ads_car');
select test.ok('the car stops taking requests: a task to take the ad down', (select needs_update and update_reason like 'The car stopped taking requests%' from test.s99post('kj')));
update vehicle_listings set status = 'published' where vehicle_id = test.id('vehicle:ads_car');
select test.eq('back on the site at the same rates: the task is cancelled, the ad matches again', (select needs_update::text from test.s99post('kj')) || '/'
  || (select status from tasks where task_type = 'ad_update' and related_id = (test.s99post('kj')).id order by created_at desc limit 1), 'false/cancelled');
-- the ads job checks every live ad again (whatever a trigger could not see, such as a rate card dated in the future)
update ad_postings set snapshot = snapshot || '{"daily": 9000}'::jsonb where status = 'live' and vehicle_id = test.id('vehicle:ads_car');
select test.eq('the ads job: every live ad that no longer matches is found', public.server_ads_job() ->> 'ads_to_update', '2');
select test.eq('the ads job: they need updating', (test.s99post('kj')).needs_update and (test.s99post('cl')).needs_update, true);
select test.eq('the ads job: due again in 6 hours', app.ads_job_due(), false);
select app.door(test.id('ads_admin'), 'aal2', 'admin_do', 'ad_posting_remove', jsonb_build_object('id', (test.s99post('cl')).id, 'reason', 'Craigslist removed it'));
select test.eq('taken down: removed with the reason, its task done', (select status || '/' || removed_reason || '/' || needs_update from test.s99post('cl')) || '/'
  || (select status from tasks where task_type = 'ad_update' and related_id = (test.s99post('cl')).id order by created_at desc limit 1), 'removed/Craigslist removed it/false/done');
select test.eq('the postings read: live, to update, removed', (select (r #>> '{counts,live}') || '/' || (r #>> '{counts,needs_update}') || '/' || (r #>> '{counts,removed}')
  from (select app.door(test.id('ads_admin'), 'aal2', 'admin_read', 'ads_postings', '{}'::jsonb) r) x), '1/1/1');
select test.ok('the listings read: the car''s facts, its photos and rules for the text', (select (r #>> '{rules,min_age}') is not null and exists (select 1 from jsonb_array_elements(r -> 'cars') c
   where c ->> 'vehicle_id' = test.id('vehicle:ads_car')::text and c ->> 'car_code' = 'CC-AD51' and c ->> 'slug' = 'c300-ads-car' and (c ->> 'taking')::boolean and jsonb_typeof(c -> 'photos') = 'array')
  from (select app.door(test.id('ads_admin'), 'aal2', 'admin_read', 'ads_listings', '{}'::jsonb) r) x));

-- ================================================================ 3. bookings per channel
insert into visitor_sessions (id, visitor_id, renter_id, consent, started_at, last_seen_at, referrer, utm, landing_path)
values (test.id('ads_visit1'), test.id('ads_browser'), null, 'analytics', now() - interval '3 days', now() - interval '3 days', null, '{"source": "kijiji", "medium": "classified", "campaign": "CC-AD51"}', '/cars/c300-ads-car'),
       (test.id('ads_visit2'), test.id('ads_browser'), test.id('renter:ads_rita'), 'analytics', now() - interval '1 hour', now(), 'www.google.com', '{}', '/');
insert into s99a select 'req', jsonb_build_object('id', app.request_booking(test.id('renter:ads_rita'), test.id('vehicle:ads_car2'), date_trunc('hour', now()) + interval '30 days',
  date_trunc('hour', now()) + interval '33 days', 'standard', null, 'web', test.id('ads_rita'), null));
insert into visitor_events (session_id, kind, path, booking_id) values (test.id('ads_visit2'), 'request_submitted', '/book/sent', (test.s99a('req') ->> 'id')::uuid);
select test.eq('request sent: first touch Kijiji (the campaign), last touch Google (the referring site)',
  (select first_channel || '/' || first_campaign || '/' || last_channel || '/' || (visitor_id = test.id('ads_browser')) from booking_attribution where booking_id = (test.s99a('req') ->> 'id')::uuid), 'kijiji/CC-AD51/google/true');
insert into s99a select 'rep_last', app.door(test.id('ads_admin'), 'aal2', 'admin_read', 'ads_report', jsonb_build_object('from', app.today() - 30, 'to', app.today()));
insert into s99a select 'rep_first', app.ads_report(test.id('ads_admin'), jsonb_build_object('from', app.today() - 30, 'to', app.today(), 'model', 'first'));
select test.ok('report, last touch: the request under Google search', exists (select 1 from jsonb_array_elements(test.s99a('rep_last') -> 'channels') c where c ->> 'channel' = 'google' and (c ->> 'requests')::integer >= 1));
select test.ok('report, first touch: the request under Kijiji', exists (select 1 from jsonb_array_elements(test.s99a('rep_first') -> 'channels') c where c ->> 'channel' = 'kijiji' and (c ->> 'requests')::integer >= 1 and c ->> 'label' = 'Kijiji'));
select test.eq('report: the channels add up to the total (every request counted once)', (select sum((c ->> 'requests')::integer) from jsonb_array_elements(test.s99a('rep_first') -> 'channels') c)::text,
  test.s99a('rep_first') #>> '{totals,requests}');
select test.eq('report: the months add up to the total too', (select sum((c ->> 'requests')::integer) from jsonb_array_elements(test.s99a('rep_first') -> 'months') c)::text, test.s99a('rep_first') #>> '{totals,requests}');
select test.eq('a request is not a booking: no revenue yet', (select (c ->> 'bookings') || '/' || (c ->> 'revenue_cents') from jsonb_array_elements(test.s99a('rep_first') -> 'channels') c where c ->> 'channel' = 'kijiji'), '0/0');
set session_replication_role = replica;
update bookings set status = 'confirmed' where id = (test.s99a('req') ->> 'id')::uuid;
set session_replication_role = origin;
select test.eq('confirmed: a booking with its rental charge after discounts, 100% conversion',
  (select (c ->> 'bookings') || '/' || ((c ->> 'revenue_cents')::bigint = (select app.booking_revenue_cents(b) from bookings b where b.id = (test.s99a('req') ->> 'id')::uuid)) || '/' || (c ->> 'conversion_bps')
     from jsonb_array_elements(app.ads_report(test.id('ads_admin'), jsonb_build_object('from', app.today() - 30, 'to', app.today(), 'model', 'first')) -> 'channels') c where c ->> 'channel' = 'kijiji'), '1/true/10000');
select test.throws('staff source: from the list', format($$select app.booking_marketing_source(%L, jsonb_build_object('booking', %L, 'source', 'tiktok_live'))$$, test.id('ads_admin'), (select booking_number from bookings where id = (test.s99a('req') ->> 'id')::uuid)), 'list');
select app.door(test.id('ads_admin'), 'aal2', 'admin_do', 'booking_marketing_source', jsonb_build_object('booking', (select booking_number from bookings where id = (test.s99a('req') ->> 'id')::uuid), 'source', 'fb_marketplace', 'note', 'Said so on the phone'));
select test.eq('staff source wins over the visit, in both models', (select app.booking_channel(b, a, 'last') || '/' || app.booking_channel(b, a, 'first')
  from bookings b left join booking_attribution a on a.booking_id = b.id where b.id = (test.s99a('req') ->> 'id')::uuid), 'fb_marketplace/fb_marketplace');
select test.throws('report: an Admin''s', format($$select app.door(%L, 'aal2', 'admin_read', 'ads_report', '{}'::jsonb)$$, test.id('ads_sales')), 'admin');
select test.eq('channel order: staff, visit unless direct, referral, how it reached us, direct, not known',
  app.booking_channel(null::bookings, null::booking_attribution, 'last'), 'unknown');

-- ================================================================ 4. Facebook Page and Instagram drafts, and the Meta switch
select test.eq('drafts: stored from the generator', (app.door(test.id('ads_admin'), 'aal2', 'admin_do', 'social_drafts_put', jsonb_build_object('drafts', jsonb_build_array(
  jsonb_build_object('slot_date', app.today(), 'kind', 'featured_car', 'vehicle_id', test.id('vehicle:ads_car'), 'caption', '2023 Mercedes-Benz C 300, from $120 a day. Book at the link in bio.',
    'link', 'https://carmacars.ca/cars/c300-ads-car?utm_source=instagram', 'photos', jsonb_build_array('cars/a.jpg')),
  jsonb_build_object('slot_date', app.today(), 'kind', 'owner_program', 'channels', jsonb_build_array('facebook_page'), 'caption', 'Own a car? CarmaCars rents it out for you.')))) ->> 'added'), '2');
select test.eq('drafts: the same day and kind again is left alone', public.server_social_drafts_put(jsonb_build_object('drafts', jsonb_build_array(
  jsonb_build_object('slot_date', app.today(), 'kind', 'featured_car', 'caption', 'Another text')))), 0);
select test.throws('drafts: no long dash', format($$select app.social_drafts_store(jsonb_build_object('drafts', jsonb_build_array(jsonb_build_object('slot_date', %L, 'kind', 'seasonal', 'caption', 'Go ' || chr(8212) || ' now'))))$$, app.today()), 'dash');
insert into s99a select 'feat', app.social_draft_row((select x from social_drafts x where x.kind = 'featured_car' and x.slot_date = app.today()));
select test.eq('the week read: the drafts, publishing off', (select jsonb_array_length(r -> 'drafts') || '/' || (r #>> '{meta,usable}') from (select app.door(test.id('ads_admin'), 'aal2', 'admin_read', 'social_drafts', '{}'::jsonb) r) x), '2/false');
select test.throws('posted: only once approved', format($$select app.social_draft_posted(%L, jsonb_build_object('id', %L, 'channel', 'instagram'))$$, test.id('ads_admin'), test.s99a('feat') ->> 'id'), 'Approve');
select app.door(test.id('ads_admin'), 'aal2', 'admin_do', 'social_draft_decide', jsonb_build_object('id', test.s99a('feat') ->> 'id', 'action', 'approve'));
select app.social_draft_save(test.id('ads_admin'), jsonb_build_object('id', test.s99a('feat') ->> 'id', 'caption', 'Edited: 2023 Mercedes-Benz C 300, from $120 a day.'));
select test.eq('an edit after approval sends it back to draft', (select status || '/' || edited from social_drafts where id = (test.s99a('feat') ->> 'id')::uuid), 'draft/true');
select app.social_draft_decide(test.id('ads_admin'), jsonb_build_object('id', test.s99a('feat') ->> 'id', 'action', 'approve'));
select app.door(test.id('ads_admin'), 'aal2', 'admin_do', 'social_draft_posted', jsonb_build_object('id', test.s99a('feat') ->> 'id', 'channel', 'instagram', 'url', 'https://www.instagram.com/p/test1/'));
select test.eq('copied and posted on Instagram: still waiting for the Facebook Page', (select status || '/' || (posted #>> '{instagram,how}') from social_drafts where id = (test.s99a('feat') ->> 'id')::uuid), 'approved/hand');
select app.social_draft_posted(test.id('ads_admin'), jsonb_build_object('id', test.s99a('feat') ->> 'id', 'channel', 'facebook_page'));
select test.eq('posted on both: posted', (select status from social_drafts where id = (test.s99a('feat') ->> 'id')::uuid), 'posted');
select test.throws('posted: not editable here any more', format($$select app.social_draft_save(%L, jsonb_build_object('id', %L, 'caption', 'x'))$$, test.id('ads_admin'), test.s99a('feat') ->> 'id'), 'already published');
select test.eq('Meta: off, no token, the job gets no token and nothing to publish', (select (r #>> '{meta,usable}') || '/' || coalesce(r #>> '{meta,token}', 'none') || '/' || jsonb_array_length(r -> 'due') from (select public.server_ads_job() r) x), 'false/none/0');
select test.throws('Meta: on needs the Page id and the token', format($$select app.meta_publishing_save(%L, jsonb_build_object('enabled', true))$$, test.id('ads_admin')), 'Page id');
select test.throws('Meta: an Admin''s', format($$select app.door(%L, 'aal2', 'admin_do', 'meta_publishing_save', jsonb_build_object('page_id', '1234567'))$$, test.id('ads_sales')), 'admin');
select test.throws('Meta: the whole token', format($$select app.meta_publishing_save(%L, jsonb_build_object('token', 'short'))$$, test.id('ads_admin')), 'whole Page access token');
select app.door(test.id('ads_admin'), 'aal2', 'admin_do', 'meta_publishing_save', jsonb_build_object('page_id', '100000000000001', 'ig_user_id', '17800000000000001', 'token', 'EAAtesttokenvalue0000000000000001'));
select test.eq('Meta: the token stored away (the row keeps its last four characters), still off until switched on',
  (select (r ->> 'has_token') || '/' || (r ->> 'token_hint') || '/' || (r ->> 'usable') from (select app.meta_publishing_read(test.id('ads_admin'), '{}'::jsonb) r) x), 'true/0001/false');
select test.ok('Meta: the read never shows the token', app.meta_publishing_read(test.id('ads_admin'), '{}'::jsonb)::text !~ 'EAAtest');
select app.meta_publishing_save(test.id('ads_admin'), jsonb_build_object('enabled', true));
select app.social_draft_decide(test.id('ads_admin'), jsonb_build_object('id', (select id from social_drafts where kind = 'owner_program'), 'action', 'approve'));
set session_replication_role = replica;
update social_drafts set slot_date = app.today(), updated_at = now() - interval '10 minutes' where kind = 'owner_program';
set session_replication_role = origin;
select test.eq('Meta on: the job is due for the approved post and gets the token', app.ads_job_due()::text || '/' || (select (r #>> '{meta,token}') || '/' || jsonb_array_length(r -> 'due') from (select public.server_ads_job() r) x),
  'true/EAAtesttokenvalue0000000000000001/1');
select public.server_social_published(jsonb_build_object('id', (select id from social_drafts where kind = 'owner_program'), 'channel', 'facebook_page', 'ok', false, 'error', 'Invalid OAuth access token'));
select test.eq('a refusal is kept on the draft and the switch', (select publish_error || '/' || publish_attempts from social_drafts where kind = 'owner_program') || '/' || (select last_error from meta_publishing), 'Invalid OAuth access token/1/Invalid OAuth access token');
select public.server_social_published(jsonb_build_object('id', (select id from social_drafts where kind = 'owner_program'), 'channel', 'facebook_page', 'ok', true, 'post_id', '100_200', 'url', 'https://www.facebook.com/100_200'));
select test.eq('published through the API: posted, logged with its post link', (select status || '/' || (posted #>> '{facebook_page,how}') || '/' || (posted #>> '{facebook_page,url}') || '/' || coalesce(publish_error, 'none') from social_drafts where kind = 'owner_program'),
  'posted/api/https://www.facebook.com/100_200/none');
select app.meta_publishing_save(test.id('ads_admin'), jsonb_build_object('token', '-', 'enabled', false));
select test.eq('Meta: the token removed', (select (token_ref is null) || '/' || enabled from meta_publishing), 'true/false');
select test.ok('server functions: the server only', not has_function_privilege('authenticated', 'public.server_ads_job()', 'execute') and not has_function_privilege('anon', 'public.server_social_published(jsonb)', 'execute'));

-- ================================================================ 5. owner recruitment: the consent log
insert into s99a select 'seller', app.door(test.id('ads_admin'), 'aal2', 'admin_do', 'recruit_lead_save', jsonb_build_object('listing_url', 'https://www.kijiji.ca/v-cars/toronto/test-civic/1', 'name', 'Sam Seller',
  'phone', '416-555-0177', 'email', 'Sam.Seller@Example.com', 'vehicle_text', '2021 Honda Civic'));
select test.eq('lead: a private seller from a Kijiji ad, kind owner_recruit, email lowercased', (select kind || '/' || listing_site || '/' || contact_kind || '/' || email || '/' || status from leads where id = (test.s99a('seller') ->> 'id')::uuid),
  'owner_recruit/kijiji/private_seller/sam.seller@example.com/new');
select test.throws('lead: a phone or an email', format($$select app.recruit_lead_save(%L, jsonb_build_object('name', 'No Contact'))$$, test.id('ads_admin')), 'phone number or an email');
select test.eq('no consent: no email, no text, and why', (select (test.s99a('seller') #>> '{email_state,allowed}') || '/' || (test.s99a('seller') #>> '{email_state,reason}')), 'false/No consent yet: phone them and record their yes first');
select test.throws('send without consent: refused, nothing queued', format($$select app.recruit_send(%L, jsonb_build_object('lead', %L, 'channel', 'email', 'subject', 'Hi', 'body', 'CarmaCars owner program'))$$, test.id('ads_admin'), test.s99a('seller') ->> 'id'), 'No consent yet');
select test.throws('a private seller''s ad does not imply consent', format($$select app.recruit_consent_add(%L, jsonb_build_object('lead', %L, 'basis', 'implied_published', 'source', 'Their Kijiji ad', 'evidence', 'https://www.kijiji.ca/x'))$$, test.id('ads_admin'), test.s99a('seller') ->> 'id'), 'private seller');
select test.throws('express consent needs its proof', format($$select app.recruit_consent_add(%L, jsonb_build_object('lead', %L, 'basis', 'express', 'source', 'Phone call'))$$, test.id('ads_admin'), test.s99a('seller') ->> 'id'), 'proof');
select test.throws('a call: a yes needs their words', format($$select app.recruit_call_log(%L, jsonb_build_object('lead', %L, 'outcome', 'yes_text'))$$, test.id('ads_admin'), test.s99a('seller') ->> 'id'), 'their words');
select app.door(test.id('ads_admin'), 'aal2', 'admin_do', 'recruit_call_log', jsonb_build_object('lead', test.s99a('seller') ->> 'id', 'outcome', 'yes_text', 'note', 'Yes, text me the details'));
select test.eq('a yes on the phone: express consent for texts (oral, with their words), not for email', (select basis || '/' || channel || '/' || method || '/' || evidence from recruit_consents where lead_id = (test.s99a('seller') ->> 'id')::uuid)
  || '/' || (app.recruit_consent_state((test.s99a('seller') ->> 'id')::uuid, 'text') ->> 'allowed') || '/' || (app.recruit_consent_state((test.s99a('seller') ->> 'id')::uuid, 'email') ->> 'allowed'), 'express/text/oral/Yes, text me the details/true/false');
select test.throws('a text names CarmaCars', format($$select app.recruit_send(%L, jsonb_build_object('lead', %L, 'channel', 'text', 'body', 'Hi Sam, here is the owner program'))$$, test.id('ads_admin'), test.s99a('seller') ->> 'id'), 'CarmaCars');
insert into s99a select 'txt', app.door(test.id('ads_admin'), 'aal2', 'admin_do', 'recruit_send', jsonb_build_object('lead', test.s99a('seller') ->> 'id', 'channel', 'text', 'template', 'text_after_call',
  'body', 'Sam, as agreed on our call, here is the CarmaCars owner program: https://carmacars.ca/list-your-car'));
select test.eq('text sent: queued with the STOP line, logged with the consent it relied on', (select o.kind || '/' || o.sms_kind || '/' || (o.body like '% Reply STOP to opt out.') || '/' || m.basis || '/' || (m.consent_id is not null)
  from recruit_messages m join phone_outbox o on o.id = m.phone_outbox_id where m.id = (test.s99a('txt') ->> 'id')::uuid), 'staff/recruit/true/express/true');
select test.eq('the lead is contacted', (select status from leads where id = (test.s99a('seller') ->> 'id')::uuid), 'contacted');
update phone_threads set opted_out_at = now(), opt_out_source = 'stop' where number = app.phone_e164('416-555-0177');
select test.eq('a STOP reply: written into the log, texts refused', (select basis || '/' || method from recruit_consents where lead_id = (test.s99a('seller') ->> 'id')::uuid order by created_at desc limit 1)
  || '/' || (app.recruit_consent_state((test.s99a('seller') ->> 'id')::uuid, 'text') ->> 'reason'), 'withdrawn/stop_reply/They replied STOP');
select test.throws('the log is never edited', format($$update recruit_consents set basis = 'express' where lead_id = %L$$, test.s99a('seller') ->> 'id'), 'never edited');
-- a dealer that published its address: implied consent for email, the unsubscribe link honoured
insert into s99a select 'dealer', app.recruit_lead_save(test.id('ads_admin'), jsonb_build_object('listing_url', 'https://www.autotrader.ca/a/test/2', 'business_name', 'Test Auto Sales', 'name', 'Dana Dealer',
  'contact_kind', 'dealer', 'email', 'sales@testauto.example.com'));
select test.throws('published address: the page it is on', format($$select app.recruit_consent_add(%L, jsonb_build_object('lead', %L, 'channel', 'email', 'basis', 'implied_published', 'source', 'Their website'))$$, test.id('ads_admin'), test.s99a('dealer') ->> 'id'), 'Paste the page');
select app.door(test.id('ads_admin'), 'aal2', 'admin_do', 'recruit_consent_add', jsonb_build_object('lead', test.s99a('dealer') ->> 'id', 'channel', 'email', 'basis', 'implied_published', 'method', 'published',
  'source', 'Contact page of their website, no "no solicitation" note', 'evidence', 'https://testauto.example.com/contact'));
insert into s99a select 'mail', app.recruit_send(test.id('ads_admin'), jsonb_build_object('lead', test.s99a('dealer') ->> 'id', 'channel', 'email', 'template', 'dealer_intro',
  'subject', 'Your cars on the CarmaCars fleet', 'body', 'Hello Dana, CarmaCars rents cars in Toronto for their owners.'));
select test.eq('email sent: a marketing email in the outbox with its unsubscribe link, the reason for the email and the message',
  (select o.code || '/' || o.category || '/' || o.status || '/' || (o.unsubscribe_token is not null) || '/' || (o.payload ->> 'unsubscribe_url' like '%/unsubscribe?token=' || o.unsubscribe_token) || '/'
          || (o.payload ->> 'consent_reason') || '/' || (o.payload ->> 'subject_line') || '/' || (o.payload ->> 'first_name')
     from recruit_messages m join notification_outbox o on o.id = m.outbox_id where m.id = (test.s99a('mail') ->> 'id')::uuid),
  'owner_recruit_outreach/marketing/queued/true/true/your business published this address/Your cars on the CarmaCars fleet/Dana');
select test.ok('the outreach email exists in the catalogue as marketing, never a text', exists (select 1 from notification_catalogue where code = 'owner_recruit_outreach' and category = 'marketing' and no_text));
select app.unsubscribe((select o.unsubscribe_token from recruit_messages m join notification_outbox o on o.id = m.outbox_id where m.id = (test.s99a('mail') ->> 'id')::uuid));
select test.eq('unsubscribed: written into the log, email refused', (select basis || '/' || method from recruit_consents where lead_id = (test.s99a('dealer') ->> 'id')::uuid order by created_at desc limit 1)
  || '/' || (app.recruit_consent_state((test.s99a('dealer') ->> 'id')::uuid, 'email') ->> 'reason'), 'withdrawn/unsubscribe_link/They unsubscribed');
-- a referral: one message
insert into s99a select 'ref', app.recruit_lead_save(test.id('ads_admin'), jsonb_build_object('name', 'Robin Referred', 'email', 'robin@example.com'));
select test.throws('referral: the referrer is named', format($$select app.recruit_consent_add(%L, jsonb_build_object('lead', %L, 'channel', 'email', 'basis', 'referral', 'source', 'An owner told us'))$$, test.id('ads_admin'), test.s99a('ref') ->> 'id'), 'Name the person');
select app.recruit_consent_add(test.id('ads_admin'), jsonb_build_object('lead', test.s99a('ref') ->> 'id', 'channel', 'email', 'basis', 'referral', 'method', 'referral', 'source', 'Olive, an owner, gave us the address', 'referrer_name', 'Olive'));
select app.recruit_send(test.id('ads_admin'), jsonb_build_object('lead', test.s99a('ref') ->> 'id', 'channel', 'email', 'subject', 'Olive suggested we write', 'body', 'Hello Robin, Olive thought the CarmaCars owner program might suit you.'));
select test.eq('referral: one message sent, the next refused', app.recruit_consent_state((test.s99a('ref') ->> 'id')::uuid, 'email') ->> 'reason', 'A referral allows one message, and it was sent');
-- implied consent from an inquiry ends after 6 months; a do-not-contact ends everything
insert into s99a select 'asked', app.recruit_lead_save(test.id('ads_admin'), jsonb_build_object('name', 'Ari Asked', 'email', 'ari@example.com', 'phone', '647-555-0199'));
select app.recruit_consent_add(test.id('ads_admin'), jsonb_build_object('lead', test.s99a('asked') ->> 'id', 'channel', 'any', 'basis', 'implied_inquiry', 'method', 'form', 'source', 'Asked about the owner program on the site', 'obtained_on', app.today() - 200));
select test.eq('an inquiry 200 days ago: implied consent ended', (select (r ->> 'allowed') || '/' || (r ->> 'reason' like 'Implied consent ended on%') from (select app.recruit_consent_state((test.s99a('asked') ->> 'id')::uuid, 'email') r) x), 'false/true');
select app.recruit_consent_add(test.id('ads_admin'), jsonb_build_object('lead', test.s99a('asked') ->> 'id', 'channel', 'any', 'basis', 'implied_inquiry', 'method', 'reply', 'source', 'Wrote to us again', 'obtained_on', app.today() - 10));
select test.eq('a new inquiry: allowed for 6 months from it', (select (r ->> 'allowed') || '/' || (r ->> 'expires_on') from (select app.recruit_consent_state((test.s99a('asked') ->> 'id')::uuid, 'text') r) x), 'true/' || ((app.today() - 10) + interval '6 months')::date);
select app.door(test.id('ads_admin'), 'aal2', 'admin_do', 'recruit_do_not_contact', jsonb_build_object('lead', test.s99a('asked') ->> 'id', 'reason', 'Asked us to stop'));
select test.eq('do not contact: nothing allowed, the lead closed', (select status || '/' || (do_not_contact_at is not null) from leads where id = (test.s99a('asked') ->> 'id')::uuid) || '/'
  || (app.recruit_consent_state((test.s99a('asked') ->> 'id')::uuid, 'text') ->> 'allowed'), 'closed/true/false');
select test.eq('the leads read: consent per channel and the counts', (select (r #>> '{counts,all}') || '/' || (r #>> '{counts,do_not_contact}') from (select app.door(test.id('ads_admin'), 'aal2', 'admin_read', 'recruit_leads', '{}'::jsonb) r) x),
  (select count(*) || '/' || count(*) filter (where do_not_contact_at is not null) from leads where kind = 'owner_recruit'));
select test.eq('the lead read: the log, the calls and the messages', (select jsonb_array_length(r -> 'consents') || '/' || jsonb_array_length(r -> 'calls') || '/' || jsonb_array_length(r -> 'messages')
  from (select app.door(test.id('ads_admin'), 'aal2', 'admin_read', 'recruit_lead', jsonb_build_object('id', test.s99a('seller') ->> 'id')) r) x), '2/1/1');
select test.throws('recruitment: an Admin''s', format($$select app.door(%L, 'aal2', 'admin_read', 'recruit_leads', '{}'::jsonb)$$, test.id('ads_sales')), 'admin');
update program_settings set recruit_outreach_enabled = false;
select test.throws('switched off in Program settings: nothing sends', format($$select app.recruit_send(%L, jsonb_build_object('lead', %L, 'channel', 'email', 'subject', 'x', 'body', 'CarmaCars'))$$, test.id('ads_admin'), test.s99a('dealer') ->> 'id'), 'off in Program settings');
update program_settings set recruit_outreach_enabled = true;

-- ================================================================ 6. privileges
select test.ok('the new tables are Admin only (row security)', (select bool_and(c.relrowsecurity) from pg_class c where c.relname in ('ad_postings', 'booking_attribution', 'social_drafts', 'meta_publishing', 'recruit_consents', 'recruit_calls', 'recruit_messages')));
select test.ok('the functions are not for browser sessions', not has_function_privilege('authenticated', 'app.recruit_send(uuid, jsonb)', 'execute') and not has_function_privilege('anon', 'app.ads_check_vehicle(uuid)', 'execute'));
select test.ok('the jobs list has the ads job', app.server_jobs_due() ? 'ads');
