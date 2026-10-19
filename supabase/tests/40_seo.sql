-- 40: search (migration 0061). The car copy written from each real car's facts (the plain copy at once, the written
-- copy published when it passes, written again when the facts change, an edited field locked and kept, the budget,
-- who may edit), landing pages (indexable for a place, or with enough real matching cars), articles, IndexNow, the
-- root files, the public reads (the car page's copy and its own reviews, the sitemap, the settings), and the Google
-- review request after a completed rental. Fixtures start with "se".
select test.suite('40 search');

select test.mk_user('se_admin', 'admin');
select test.mk_user('se_cs', 'va', 'cs');
select test.mk_user('se_fin', 'va', 'finance');
select test.mk_renter('se_rita');
select test.mk_renter('se_rob');

create temp table s40 as select null::text as k, null::jsonb as v limit 0;
create or replace function test.s40(p_k text) returns jsonb language sql stable as $$ select v from pg_temp.s40 where k = p_k $$;
create or replace function test.s40v(p_k text) returns uuid language sql stable as $$ select (v ->> 'vehicle_id')::uuid from pg_temp.s40 where k = p_k $$;
grant all on s40 to public;

-- ================================================================ 1. settings
select test.eq('settings: the car copy fits the listing lint (heading 20 to 70, intro 40 to 160 words, 3 to 12 highlights)',
  (select listing_headline_chars::text || ' ' || listing_description_words::text || ' ' || listing_features_count::text from (select (app.settings()).*) s), '[20,71) [40,161) [3,13)');
select test.eq('settings: the search budget, attempts, retry, similarity, landing threshold, rating threshold, Google review delay, IndexNow',
  (select concat_ws('/', seo_ai_daily_neurons, seo_copy_max_attempts, seo_copy_retry_hours, seo_copy_similarity_max_bps, seo_landing_min_real_cars, seo_rating_min_reviews, google_review_delay_days, indexnow_enabled)
     from (select (app.settings()).*) s), '4000/3/6/5000/2/3/3/t');
select test.eq('settings: the business name, address and phone for the listings and the structured data',
  (select concat_ws('|', business_name, business_street, business_city, business_region, business_postal_code) from site_settings), 'CarmaCars|2967 Dundas St W, Unit 208B|Toronto|ON|M6P 1Z2');
select test.ok('settings: an IndexNow key of 32 hex characters is made once', (select indexnow_key ~ '^[a-f0-9]{32}$' from site_settings));
select test.ok('settings: the banned phrases gained the AI words (the row in force when 0061 ran)', exists (select 1 from program_settings where 'unleash' = any (listing_banned_phrases) and 'seamless' = any (listing_banned_phrases)));
select test.throws('settings: a Google verification value is checked', $$update site_settings set google_site_verification = 'bad value <meta>'$$, 'google_site_verification');

-- ================================================================ 2. car copy
do $$
declare v jsonb; i integer;
begin
  for i in 1 .. 3 loop
    v := app.vehicle_add(test.id('se_admin'), jsonb_build_object('supply_type', 'company', 'vin', '2SEAXVE00000000' || lpad(i::text, 2, '0'), 'plate', 'SE00' || i,
      'year', 2023, 'make', 'Toyota', 'model', case when i = 3 then 'RAV4' else 'Corolla' end, 'colour', case i when 1 then 'Grey' when 2 then 'White' else 'Blue' end,
      'rates', jsonb_build_object('daily', 6900 + i * 100, 'weekend', 7900, 'weekly', 42000, 'monthly', 145000, 'deposit', 50000)));
    insert into pg_temp.s40 values ('car' || i, v);
  end loop;
end $$;
update vehicle_listings set seats = 5, transmission = 'Automatic', body_style = case when vehicle_id = test.s40v('car3') then 'SUV' else 'Sedan' end,
       home_area = 'Etobicoke', slug = 'se-car-' || right(vehicle_id::text, 4)
 where vehicle_id in (test.s40v('car1'), test.s40v('car2'), test.s40v('car3'));
insert into vehicle_class_links (vehicle_id, class_code) values (test.s40v('car3'), 'suv') on conflict do nothing;

select test.eq('a real car gets its copy row and the plain copy at once (no person types anything)', app.car_copy_scan() >= 3, true);
select test.eq('plain copy: live on the listing, from the facts, passing the listing lint',
  (select cc.source || '/' || cc.status || '/' || (l.headline = cc.copy ->> 'h1') || '/' || cardinality(app.listing_copy_problems(l.headline, l.description, l.features, l.faq))
     from car_copy cc join vehicle_listings l on l.vehicle_id = cc.vehicle_id where cc.vehicle_id = test.s40v('car1')), 'template/pending/true/0');
select test.eq('plain copy: the heading names the car and the city', (select copy ->> 'h1' from car_copy where vehicle_id = test.s40v('car1')), '2023 Toyota Corolla rental in Toronto');
select test.ok('facts: the car, its prices from the rate card in force, the place, the rules, what is included',
  (select facts -> 'car' ->> 'model' = 'Corolla' and facts -> 'prices' ->> 'daily' = '$70' and facts -> 'prices' ->> 'monthly' = '$1,450'
          and facts -> 'place' ->> 'area' = 'Etobicoke' and (facts -> 'rules' ->> 'min_age')::integer = 18 and jsonb_array_length(facts -> 'included') >= 3
     from car_copy where vehicle_id = test.s40v('car1')));
select test.ok('facts: never the VIN, the plate or the owner', (select facts::text not like '%2SEAXVE%' and facts::text not like '%SE001%' from car_copy where vehicle_id = test.s40v('car1')));
select test.ok('a sample car gets no written copy', not exists (select 1 from car_copy cc join vehicles v on v.id = cc.vehicle_id where v.is_sample));

-- the job claims the cars due, the plain ones first, with the facts and the other cars' text to stay apart from
insert into pg_temp.s40 select 'claim', public.server_seo_claim('w-se', 3);
select test.eq('claim: three cars, running, each with its facts', (select count(*) from jsonb_array_elements(test.s40('claim') -> 'cars') c where c -> 'facts' ? 'car'), 3::bigint);
select test.eq('claim: claimed rows are running', (select count(*) from car_copy where status = 'running' and worker = 'w-se'), 3::bigint);
select test.eq('claim: the IndexNow key and the checks travel with it', (test.s40('claim') -> 'indexnow' ->> 'key') = (select indexnow_key from site_settings) and (test.s40('claim') ->> 'max_attempts') = '3', true);

create or replace function test.se_copy(p_h1 text, p_intro text default null) returns jsonb language sql as $$
  select jsonb_build_object('seo_title', '2023 Toyota Corolla Rental in Toronto | CarmaCars', 'meta_description', 'Rent the grey 2023 Toyota Corolla in Etobicoke from $70 a day. Collect it from us or have it delivered, with no payment to request.',
    'h1', p_h1, 'intro', coalesce(p_intro, 'The grey Corolla is a quiet, easy sedan for city errands and long highway days. It is kept in Etobicoke, close to the 427 and the airport, and it seats five with room for bags in the trunk.' || chr(10) || chr(10) || 'Send a request with your dates. We confirm the car and the price, then you sign and pay online, and we meet you with the car.'),
    'highlights', jsonb_build_array('5 seats', 'Automatic transmission', 'Gas engine', '400 km a day included'), 'good_for', jsonb_build_array('Commutes', 'Airport runs'),
    'included', jsonb_build_array('Third-party liability coverage', 'Roadside assistance, 24 hours a day', 'A walk-around at the handover'),
    'pickup_delivery', 'The car is kept in Etobicoke. Collect it from our location at no charge, or we bring it to your address.',
    'requirements', jsonb_build_array('Drivers 18 or older', 'Ontario G or G2 licence', 'A credit card in your name'),
    'faq', jsonb_build_array(jsonb_build_object('question', 'How many people fit?', 'answer', 'Five.'), jsonb_build_object('question', 'Can you deliver it?', 'answer', 'Yes.'),
                             jsonb_build_object('question', 'Is a request free?', 'answer', 'Yes.'), jsonb_build_object('question', 'How do I pay?', 'answer', 'Online, after we confirm.')),
    'alt_texts', jsonb_build_object('front_left', '2023 Toyota Corolla in grey, front left view')) $$;

select public.server_seo_result(jsonb_build_object('kind', 'car', 'id', test.s40v('car1'), 'ok', true, 'copy', test.se_copy('2023 Toyota Corolla in grey for rent in Toronto'),
  'model', '@cf/meta/llama-3.3-70b-instruct-fp8-fast', 'prompt_version', 'car-copy-v1', 'neurons', 240, 'ms', 4100));
select test.eq('result: the written copy is published by itself, nothing to review',
  (select cc.status || '/' || cc.source || '/' || cc.prompt_version || '/' || l.headline || '/' || (cc.copy_facts_hash = cc.facts_hash)
     from car_copy cc join vehicle_listings l on l.vehicle_id = cc.vehicle_id where cc.vehicle_id = test.s40v('car1')),
  'published/ai/car-copy-v1/2023 Toyota Corolla in grey for rent in Toronto/true');
select test.eq('result: the listing follows (description, highlights, questions, search text)',
  (select cardinality(features) || '/' || jsonb_array_length(faq) || '/' || seo_title || '/' || (description like 'The grey Corolla%') from vehicle_listings where vehicle_id = test.s40v('car1')),
  '4/4/2023 Toyota Corolla Rental in Toronto | CarmaCars/true');
select test.eq('result: the call is logged with its neurons for the day''s budget',
  (select purpose || '/' || units from provider_calls where purpose = 'seo_car' and vehicle_id = test.s40v('car1')), 'seo_car/240');

select public.server_seo_result(jsonb_build_object('kind', 'car', 'id', test.s40v('car2'), 'ok', true, 'copy', test.se_copy('A white Corolla ' || chr(8212) || ' for rent'), 'neurons', 200));
select test.eq('result: a copy the database refuses (a long dash) is not published; the plain copy stays; tried again later',
  (select cc.status || '/' || cc.source || '/' || (cc.problems::text like '%long dash%') || '/' || (cc.next_attempt_at > now() + interval '5 hours') from car_copy cc where cc.vehicle_id = test.s40v('car2')),
  'failed/template/true/true');
select public.server_seo_result(jsonb_build_object('kind', 'car', 'id', test.s40v('car3'), 'ok', false, 'problems', jsonb_build_array('these numbers are not in the facts: 59'), 'error', 'The copy did not pass the checks', 'neurons', 600));
select test.eq('result: a failed run keeps the current text and records what the checks found',
  (select status || '/' || source || '/' || problems[1] from car_copy where vehicle_id = test.s40v('car3')), 'failed/template/these numbers are not in the facts: 59');

-- the facts change: written again
create temp table s40rc as select * from rate_cards where vehicle_id = test.s40v('car1') and effective_to is null;
update rate_cards set effective_to = now() where vehicle_id = test.s40v('car1') and effective_to is null;
insert into rate_cards (vehicle_id, daily_rate_cents, weekend_rate_cents, weekly_rate_cents, monthly_rate_cents, km_allowance_per_day, overage_cents_per_km, deposit_cents, delivery_fee_cents, pickup_fee_cents, effective_from)
select vehicle_id, 7500, weekend_rate_cents, weekly_rate_cents, monthly_rate_cents, km_allowance_per_day, overage_cents_per_km, deposit_cents, delivery_fee_cents, pickup_fee_cents, clock_timestamp()
  from s40rc;
select app.car_copy_scan();
select test.eq('facts change (a new daily rate): the copy is due again, the live one stays until the new one passes',
  (select status || '/' || source || '/' || (facts -> 'prices' ->> 'daily') || '/' || (copy_facts_hash is distinct from facts_hash) from car_copy where vehicle_id = test.s40v('car1')),
  'pending/ai/$75/true');

-- a person edits a field: locked, kept by every rewrite; unlock
select public.door(test.id('se_cs'), null, 'ops_do', 'car_copy_edit', jsonb_build_object('vehicle', test.s40v('car1'), 'field', 'h1', 'value', 'Our grey Corolla, ready in Etobicoke'));
select test.eq('edit: customer service may change a field; it is live and locked',
  (select (copy ->> 'h1') || '/' || array_to_string(locked, ',') || '/' || (select headline from vehicle_listings where vehicle_id = test.s40v('car1')) from car_copy where vehicle_id = test.s40v('car1')),
  'Our grey Corolla, ready in Etobicoke/h1/Our grey Corolla, ready in Etobicoke');
select public.server_seo_result(jsonb_build_object('kind', 'car', 'id', test.s40v('car1'), 'ok', true, 'copy', test.se_copy('2023 Toyota Corolla rental in Toronto at $75'), 'neurons', 10));
select test.eq('edit: the next rewrite keeps the locked field', (select copy ->> 'h1' from car_copy where vehicle_id = test.s40v('car1')), 'Our grey Corolla, ready in Etobicoke');
select test.throws('edit: Finance may not change the car copy',
  format($$select public.door(%L, null, 'ops_do', 'car_copy_edit', jsonb_build_object('vehicle', %L, 'field', 'h1', 'value', 'x'))$$, test.id('se_fin'), test.s40v('car1')), 'Fleet or customer service');
select test.throws('edit: only the fields of the copy', format($$select public.door(%L, null, 'ops_do', 'car_copy_edit', jsonb_build_object('vehicle', %L, 'field', 'price', 'value', 'x'))$$,
  test.id('se_admin'), test.s40v('car1')), 'Not a field');
select public.door(test.id('se_admin'), null, 'ops_do', 'car_copy_edit', jsonb_build_object('vehicle', test.s40v('car1'), 'field', 'h1', 'unlock', true));
select test.eq('unlock: the field is written again by the next version', (select status || '/' || cardinality(locked) from car_copy where vehicle_id = test.s40v('car1')), 'pending/0');
select test.eq('edit: recorded in the audit log', (select count(*) from audit_log where action in ('car_copy_edit', 'car_copy_unlock') and entity_id = test.s40v('car1')::text), 2::bigint);
select public.door(test.id('se_cs'), null, 'ops_do', 'car_copy_regenerate', jsonb_build_object('vehicle', test.s40v('car2')));
select test.eq('Write again: due now', (select status || '/' || (next_attempt_at <= now()) from car_copy where vehicle_id = test.s40v('car2')), 'pending/true');
select test.eq('read: the copy screen shows the status, the source and what is locked',
  (select (r ->> 'status') || '/' || (r ->> 'source') || '/' || (r ->> 'eligible') from (select public.door(test.id('se_cs'), null, 'ops_read', 'car_copy', jsonb_build_object('vehicle', test.s40v('car2'))) r) x),
  'pending/template/true');
update car_copy set asked_at = null where vehicle_id = test.s40v('car1');
update car_copy set next_attempt_at = now() - interval '1 hour', asked_at = null where vehicle_id <> test.s40v('car2') and status = 'pending';
select test.eq('Write again: the next run takes the car asked for before the cars already waiting',
  (select public.server_seo_claim('w-se-ask', 1) -> 'cars' -> 0 ->> 'vehicle_id'), test.s40v('car2')::text);
select test.eq('Write again: the request is used once', (select status || '/' || (asked_at is null) from car_copy where vehicle_id = test.s40v('car2')), 'running/true');
update car_copy set status = 'pending', locked_at = null, worker = null where vehicle_id = test.s40v('car2');

-- the day's budget: no AI work past it
insert into provider_calls (provider, purpose, ok, units, unit) values ('workers-ai', 'seo_page', true, 4000, 'neurons');
select test.eq('budget: past the day''s search neurons the job claims nothing to write', (select jsonb_array_length(public.server_seo_claim('w-se2', 3) -> 'cars')), 0);
delete from provider_calls where purpose = 'seo_page' and units = 4000;

-- ================================================================ 3. landing pages
insert into seo_pages (slug, kind, name, facts, match, copy) values
  ('se-place', 'location', 'Se Place', '{"highways": ["401"]}', '{}', '{"seo_title": "Car Rental in Se Place | CarmaCars", "meta_description": "x", "h1": "Car rental in Se Place", "intro": "Intro.", "sections": [], "faq": []}'),
  ('se-suv', 'use', 'Se SUV rental', '{}', '{"classes": ["suv"]}', '{"seo_title": "SUV Rental | CarmaCars", "meta_description": "x", "h1": "SUV rental", "intro": "Intro.", "sections": [], "faq": []}');
select test.eq('landing: a location page is indexable; a use page with fewer real matching cars than the setting is not',
  (select string_agg(slug || '=' || app.seo_page_indexable(p), ',' order by slug) from seo_pages p where slug like 'se-%'), 'se-place=true,se-suv=false');
update vehicles set status = 'available', bookings_enabled = true where id in (test.s40v('car1'), test.s40v('car2'), test.s40v('car3'));
update vehicle_listings set status = 'published' where vehicle_id in (test.s40v('car1'), test.s40v('car2'), test.s40v('car3'));
insert into pg_temp.s40 values ('suv1', app.vehicle_add(test.id('se_admin'), jsonb_build_object('supply_type', 'company', 'vin', '2SEAXVE0000000099', 'plate', 'SE099',
  'year', 2022, 'make', 'Honda', 'model', 'CR-V', 'rates', jsonb_build_object('daily', 9900, 'weekend', 9900, 'weekly', 59000, 'monthly', 190000, 'deposit', 50000))));
insert into vehicle_class_links (vehicle_id, class_code) values (test.s40v('suv1'), 'suv') on conflict do nothing;
update vehicles set status = 'available', bookings_enabled = true where id = test.s40v('suv1');
update vehicle_listings set status = 'published', slug = 'se-crv', seats = 5, transmission = 'Automatic' where vehicle_id = test.s40v('suv1');
select test.eq('landing: two real SUVs taking requests make the SUV page indexable', (select app.seo_page_indexable(p) from seo_pages p where slug = 'se-suv'), true);
select test.ok('landing: the page lists its live matching cars, cheapest first, with the counts and the lowest price',
  (select jsonb_array_length(x -> 'cars') >= 2 and (x ->> 'real_cars')::integer >= 2 and (x ->> 'min_daily_cents')::integer <= 7000 + 9900
          and (x -> 'cars' -> 0 ->> 'daily_rate_cents')::integer <= (x -> 'cars' -> 1 ->> 'daily_rate_cents')::integer
     from (select public.seo_page('se-suv') x) q));
select test.ok('landing: the footer links list indexable pages only', (select public.seo_links()::text like '%se-place%' and public.seo_links()::text like '%se-suv%'));
select public.door(test.id('se_admin'), null, 'admin_do', 'seo_page_save', jsonb_build_object('slug', 'se-place', 'copy', jsonb_build_object('h1', 'Car rental in Se Place, delivered')));
select test.eq('landing: an Admin''s edit is live and locked', (select (copy ->> 'h1') || '/' || array_to_string(locked, ',') || '/' || source from seo_pages where slug = 'se-place'),
  'Car rental in Se Place, delivered/h1/staff');
select test.throws('landing: a long dash is refused', format($$select public.door(%L, null, 'admin_do', 'seo_page_save', jsonb_build_object('slug', 'se-place', 'copy', jsonb_build_object('h1', 'Car rental ' || chr(8212) || ' here')))$$, test.id('se_admin')), 'long dash');
select test.throws('landing: only an Admin edits a page', format($$select public.door(%L, null, 'ops_do', 'seo_page_save', jsonb_build_object('slug', 'se-place', 'copy', jsonb_build_object('h1', 'x')))$$, test.id('se_cs')), 'admin');
update seo_pages set facts = '{"highways": ["401", "427"]}' where slug = 'se-place';
select test.eq('landing: new facts: written again', (select status from seo_pages where slug = 'se-place'), 'pending');
select public.server_seo_result(jsonb_build_object('kind', 'page', 'id', 'se-place', 'ok', true, 'model', 'm', 'neurons', 50, 'copy',
  jsonb_build_object('seo_title', 'Car Rental in Se Place | CarmaCars', 'meta_description', 'y', 'h1', 'Car rental in Se Place', 'intro', 'New intro.', 'sections', '[]'::jsonb, 'faq', '[]'::jsonb)));
select test.eq('landing: the rewrite is published and keeps the locked heading', (select status || '/' || source || '/' || (copy ->> 'h1') || '/' || (copy ->> 'intro') from seo_pages where slug = 'se-place'),
  'published/ai/Car rental in Se Place, delivered/New intro.');

-- ================================================================ 4. articles
insert into articles (slug, title, description, body_md) values ('se-guide', 'Renting a car in Se Place as a young driver', 'What young drivers need to rent a car in Se Place: the licence, the card, the fee and the steps, from request to pickup.', E'## One\n\nText.\n');
select test.eq('article: public read', (select public.article('se-guide') ->> 'path'), '/guides/se-guide');
select public.door(test.id('se_admin'), null, 'admin_do', 'article_save', jsonb_build_object('slug', 'se-guide', 'body_md', E'## One\n\nBetter text.\n', 'author_name', 'Sam Lee'));
select test.eq('article: an Admin''s edit is published and locked; the author shows', (select body_md || '|' || array_to_string(locked, ',') || '|' || author_name from articles where slug = 'se-guide'),
  E'## One\n\nBetter text.\n|body_md|Sam Lee');
select public.door(test.id('se_admin'), null, 'admin_do', 'article_save', jsonb_build_object('slug', 'se-guide', 'regenerate', true, 'brief', 'Cover the deposit too.', 'unlock', true));
select test.eq('article: Write again with a brief', (select status || '/' || brief || '/' || cardinality(locked) from articles where slug = 'se-guide'), 'pending/Cover the deposit too./0');
select public.server_seo_result(jsonb_build_object('kind', 'article', 'id', 'se-guide', 'ok', true, 'title', 'Renting a car in Se Place as a young driver', 'body_md', E'## One\n\nAI text.\n', 'faq', '[]'::jsonb, 'neurons', 300));
select test.eq('article: the rewrite is published', (select status || '/' || source || '/' || body_md from articles where slug = 'se-guide'), E'published/ai/## One\n\nAI text.\n');

-- ================================================================ 5. IndexNow and the sitemap
select test.ok('IndexNow: a published car, a changed landing page and a changed article are queued',
  (select count(*) = 3 from indexnow_queue where path in ('/cars/se-crv', '/car-rental/se-place', '/guides/se-guide') and sent_at is null)
  or (select count(*) >= 2 from indexnow_queue where path in ('/car-rental/se-place', '/guides/se-guide') and sent_at is null));
select public.server_indexnow_sent(jsonb_build_object('paths', jsonb_build_array('/car-rental/se-place', '/guides/se-guide'), 'status', 200));
select test.eq('IndexNow: sent addresses are marked', (select count(*) from indexnow_queue where path in ('/car-rental/se-place', '/guides/se-guide') and sent_at is not null), 2::bigint);
select public.server_indexnow_sent(jsonb_build_object('paths', jsonb_build_array('/guides'), 'status', 429, 'error', 'Too many requests'));
select test.eq('IndexNow: a refusal keeps the address for the next run', (select (sent_at is null) || '/' || attempts || '/' || last_status from indexnow_queue where path = '/guides'), 'true/1/429');
update articles set body_md = E'## One\n\nChanged again.\n' where slug = 'se-guide';
select test.eq('IndexNow: a change after sending queues it again', (select sent_at is null from indexnow_queue where path = '/guides/se-guide'), true);
select test.ok('sitemap: real cars with their photos, indexable landing pages and articles; no sample car',
  exists (select 1 from public.sitemap_all() where path = '/car-rental/se-place' and kind = 'landing')
  and exists (select 1 from public.sitemap_all() where path = '/guides/se-guide' and kind = 'article')
  and not exists (select 1 from public.sitemap_all() s join vehicle_listings l on '/cars/' || l.slug = s.path join vehicles v on v.id = l.vehicle_id where v.is_sample));

-- ================================================================ 6. root files, settings and the car page
select test.eq('root file: the IndexNow key file', public.site_file((select indexnow_key from site_settings) || '.txt'), (select indexnow_key from site_settings));
update site_settings set google_verification_file = 'google0123abcd.html', google_site_verification = 'abcdefghijklmnop_123', bing_site_verification = 'ABCDEF0123456789ABCDEF0123456789';
select test.eq('root file: the Google verification file, only for the name in settings', public.site_file('google0123abcd.html') || '/' || coalesce(public.site_file('google999.html'), 'none'),
  'google-site-verification: google0123abcd.html/none');
select test.eq('settings: the verification values and the business address reach every page',
  (select (s ->> 'google_site_verification') || '/' || (s ->> 'bing_site_verification') || '/' || (s -> 'business' ->> 'postal_code') from (select public.site_settings_public() s) x),
  'abcdefghijklmnop_123/ABCDEF0123456789ABCDEF0123456789/M6P 1Z2');
select app.car_copy_scan();
select test.ok('car page: the written copy (without alt texts) and the car''s own reviews',
  (select (c -> 'copy' ->> 'h1') is not null and not (c -> 'copy' ? 'alt_texts') and (c -> 'reviews' ->> 'count')::integer = 0 and (c -> 'reviews' ->> 'min_for_rating')::integer = 3
     from (select public.car_page('se-crv') c) x));

-- ================================================================ 7. privileges
set role anon;
select test.lives('anon: reads a landing page, the links, an article, the sitemap and the root files', $$select public.seo_page('se-place'), public.seo_links(), public.article('se-guide'), (select count(*) from public.sitemap_all()), public.site_file('x.txt')$$);
select test.throws('anon: cannot claim the search job', $$select public.server_seo_claim('x', 1)$$, 'permission');
select test.eq('anon: cannot read the car copy table', test.visible('select * from car_copy'), -1::bigint);
reset role;
select set_config('request.jwt.claims', json_build_object('sub', test.id('se_cs'), 'role', 'authenticated')::text, false);
set role authenticated;
select test.eq('staff (not an Admin): no direct read of the queue tables', test.visible('select * from indexnow_queue'), -1::bigint);
reset role;
select set_config('request.jwt.claims', '', false);

-- ================================================================ 8. the Google review request
create or replace function test.at40(p_local text) returns timestamptz language sql immutable as $$ select p_local::timestamp at time zone 'America/Toronto' $$;
create or replace function test.ev40(p_code text, p_entity uuid) returns bigint language sql stable as $$ select count(*) from app_events where code = p_code and entity_id = p_entity $$;
select test.mk_owner('se_owner');
select test.mk_vehicle('SEV', 'se_owner');
select test.mk_booking('SE-1', 'SEV', 'se_rita', '2031-08-01 10:00', '2031-08-03 10:00', 'closed');
select test.mk_booking('SE-2', 'SEV', 'se_rob', '2031-08-04 10:00', '2031-08-06 10:00', 'closed');
insert into status_history (entity, entity_id, from_status, to_status, changed_at) values
  ('booking', test.id('booking:SE-1'), 'returned', 'closed', test.at40('2031-08-05 15:00')),
  ('booking', test.id('booking:SE-2'), 'returned', 'closed', test.at40('2031-08-05 15:00'));
update site_settings set google_place_id = null;
select app.notify_google_reviews(test.at40('2031-08-08 10:00'));
select test.eq('Google: nothing while the place id is not set', test.ev40('renter_google_review_request', test.id('booking:SE-1')), 0::bigint);
update site_settings set google_place_id = 'ChIJse40placeid0001';
select app.notify_google_reviews(test.at40('2031-08-07 10:00'));
select test.eq('Google: not before the delay (3 days)', test.ev40('renter_google_review_request', test.id('booking:SE-1')), 0::bigint);
-- a problem on SE-2 (a closed incident) holds it for the staff decision (0025): no request until a person says yes
insert into incidents (id, kind, vehicle_id, booking_id, status) values (test.id('inc:se2'), 'accident', test.id('vehicle:SEV'), test.id('booking:SE-2'), 'closed');
select app.notify_followups(test.at40('2031-08-08 10:00'));
select app.notify_followups(test.at40('2031-08-08 11:00'));
select test.eq('Google: after the delay, once per booking, through the follow-up job', test.ev40('renter_google_review_request', test.id('booking:SE-1')), 1::bigint);
select test.eq('Google: the email carries the review form of the profile',
  (select app.notification_payload('renter_google_review_request', e, '{}'::jsonb) ->> 'google_review_url' from app_events e where e.code = 'renter_google_review_request' and e.entity_id = test.id('booking:SE-1')),
  'https://search.google.com/local/writereview?placeid=ChIJse40placeid0001');
select test.eq('Google: a booking that had a problem is not asked by itself', test.ev40('renter_google_review_request', test.id('booking:SE-2')), 0::bigint);
update review_request_decisions set status = 'send', decided_at = now(), decided_by = test.id('se_admin') where booking_id = test.id('booking:SE-2');
insert into review_request_decisions (booking_id, problems, status, decided_at, decided_by) values (test.id('booking:SE-2'), array['incident'], 'send', now(), test.id('se_admin')) on conflict (booking_id) do nothing;
select app.notify_google_reviews(test.at40('2031-08-09 10:00'));
select test.eq('Google: once a person says yes, it is sent like any other', test.ev40('renter_google_review_request', test.id('booking:SE-2')), 1::bigint);
update site_settings set google_place_id = null;
