-- 99: release 48, SEO (migrations 3230 to 3232; docs/changes/2026-11-20-r48-seo.md): where a lead or a request came from
-- (the channel, the landing page, the search terms), duplicate leads (one-click merge, the auto-merge rule), the tracker's
-- volume pricing and waitlist with its confirmation email, the services facts and the new landing pages.
-- Fixtures start with "x60"; addresses are example.test.
select test.suite('99 r48 seo: lead source, duplicates, trackers');
select test.mk_user('x60_admin', 'admin');
select test.mk_user('x60_sales', 'va', 'sales');

-- ---------------------------------------------------------------- the channel of a visit
select test.eq('ChatGPT by its campaign tag', app.traffic_channel('chatgpt.com', null, null, null), 'chatgpt');
select test.eq('ChatGPT by the referring site', app.traffic_channel(null, null, 'https://chatgpt.com/c/1', null), 'chatgpt');
select test.eq('Perplexity', app.traffic_channel(null, null, 'www.perplexity.ai/search/x', null), 'perplexity');
select test.eq('Gemini is not Google search', app.traffic_channel(null, null, 'gemini.google.com/app', null), 'gemini');
select test.eq('Copilot', app.traffic_channel(null, null, 'copilot.microsoft.com/', null), 'copilot');
select test.eq('Claude', app.traffic_channel(null, null, 'claude.ai/chat/1', null), 'claude');
select test.eq('Google search', app.traffic_channel(null, null, 'www.google.ca/', null), 'google');
select test.eq('a Google Ads click id wins over the referrer', app.traffic_channel(null, null, 'www.google.com/', 'gclid'), 'google_ads');
select test.eq('a paid Google campaign', app.traffic_channel('google', 'cpc', null, null), 'google_ads');
select test.eq('Bing', app.traffic_channel(null, null, 'www.bing.com/search', null), 'bing');
select test.eq('DuckDuckGo', app.traffic_channel(null, null, 'duckduckgo.com/', null), 'duckduckgo');
select test.eq('no referrer and no tag is direct', app.traffic_channel(null, null, null, null), 'direct');
select test.eq('the advertising channels of 0167 still answer', app.traffic_channel('kijiji', null, null, null), 'kijiji');
select test.eq('another site', app.traffic_channel(null, null, 'blog.example.test/post', null), 'other_site');
select test.eq('the labels', app.ad_channel_label('chatgpt') || '|' || app.ad_channel_label('google_ads') || '|' || app.ad_channel_label('google') || '|' || app.ad_channel_label('kijiji'),
  'ChatGPT|Google Ads|Google search|Kijiji');
select test.eq('the words searched are read from a referring search page', app.src_query('duckduckgo.com/?q=kill%20switch%20for%20car'), 'kill switch for car');
select test.ok('Google carries no words', app.src_query('www.google.com/') is null);

-- ---------------------------------------------------------------- the source is kept with the lead
create temp table x60 (k text primary key, id uuid);
grant all on x60 to public;
insert into x60 select 'a', (submit_lead('{"kind":"contact","name":"Ana Source","email":"x60_ana@example.test","message":"A question"}'::jsonb, null) ->> 'lead_id')::uuid;
select test.ok('stored for a lead', public.server_contact_source_set(p_lead => (select id from x60 where k = 'a'),
  p => '{"vid":"60000000-0000-4000-8000-000000000001","first":{"ref":"chatgpt.com/c/1","landing":"/trackers/kill-switch-for-car?x=1","at":"2026-11-20T15:00:00Z","utm":{"source":"chatgpt.com","term":"kill switch"}},"last":{"landing":"/contact"}}'::jsonb) is not null);
select test.eq('the channel, the landing page without its query, the terms from the campaign tag',
  (select channel || '|' || first_landing || '|' || search_terms || '|' || last_landing from contact_sources where lead_id = (select id from x60 where k = 'a')),
  'chatgpt|/trackers/kill-switch-for-car|kill switch|/contact');
select test.eq('the lead''s empty campaign columns are filled', (select utm_source || '|' || referrer from leads where id = (select id from x60 where k = 'a')), 'chatgpt.com|chatgpt.com/c/1');
select test.ok('the first write stays', public.server_contact_source_set(p_lead => (select id from x60 where k = 'a'), p => '{"first":{"ref":"www.google.com/","landing":"/"}}'::jsonb) is null
  and (select channel from contact_sources where lead_id = (select id from x60 where k = 'a')) = 'chatgpt');
select test.eq('the lead list shows it', app.sl_row((select l from leads l where l.id = (select id from x60 where k = 'a')), test.id('x60_admin')) -> 'traffic' ->> 'label', 'ChatGPT');
select test.eq('and says where the terms come from', app.sl_row((select l from leads l where l.id = (select id from x60 where k = 'a')), test.id('x60_admin')) -> 'traffic' ->> 'terms_from', 'campaign');
select test.ok('nothing kept is no source, not an error', app.contact_source_json(gen_random_uuid(), null) is null);
select test.ok('junk is refused quietly', public.server_contact_source_set(p_lead => (select id from x60 where k = 'a'), p => '"x"'::jsonb) is null
  and public.server_contact_source_set(p => '{"first":{"landing":"/"}}'::jsonb) is null);

-- a Google visit carries no words: the landing page's top Search Console queries are shown instead
insert into app.gsc_page_queries (page, query, clicks, impressions, window_start, window_end) values
  ('/car-rental/x60-page', 'x60 car rental mississauga', 9, 120, current_date - 28, current_date - 1),
  ('/car-rental/x60-page', 'x60 rent a car', 3, 80, current_date - 28, current_date - 1),
  ('/car-rental/x60-other', 'x60 other', 50, 500, current_date - 28, current_date - 1);
insert into x60 select 'g', (submit_lead('{"kind":"contact","name":"Gus Google","email":"x60_gus@example.test","message":"Hello"}'::jsonb, null) ->> 'lead_id')::uuid;
select public.server_contact_source_set(p_lead => (select id from x60 where k = 'g'), p => '{"first":{"ref":"www.google.com/","landing":"/car-rental/x60-page"}}'::jsonb);
select test.eq('Google search, with the landing page''s queries, best first',
  (select (j ->> 'label') || '|' || (j -> 'queries' -> 0 ->> 'query') || '|' || jsonb_array_length(j -> 'queries') from (select app.contact_source_json((select id from x60 where k = 'g'), null) j) q),
  'Google search|x60 car rental mississauga|2');

-- a request to book keeps its source too
select test.mk_owner('x60_o');
select test.mk_vehicle('X60A', 'x60_o');
select test.mk_renter('x60_r');
select test.mk_booking('CC-X601', 'X60A', 'x60_r', to_char(now() at time zone 'America/Toronto' + interval '20 days', 'YYYY-MM-DD 10:00'),
  to_char(now() at time zone 'America/Toronto' + interval '22 days', 'YYYY-MM-DD 10:00'), 'requested', 10000);
select test.ok('stored for a request by its number', public.server_contact_source_set(p_booking_number => 'CC-X601', p => '{"first":{"ref":"www.perplexity.ai/search/x","landing":"/cars"}}'::jsonb) is not null);
select test.eq('read for the booking', app.contact_source_json(null, (select id from bookings where booking_number = 'CC-X601')) ->> 'label', 'Perplexity');

-- ---------------------------------------------------------------- duplicates: the auto-merge rule
insert into x60 select 'd1', (submit_lead('{"kind":"contact","name":"Dee Dup","email":"x60_dee@example.test","phone":"226-555-6001","message":"first message"}'::jsonb, null) ->> 'lead_id')::uuid;
insert into x60 select 'd2', (submit_lead('{"kind":"contact","name":"Dee Dup","email":"X60_DEE@example.test","message":"second message"}'::jsonb, null) ->> 'lead_id')::uuid;
select test.eq('a second form from the same email joins the open lead by itself', (select merged_into from leads where id = (select id from x60 where k = 'd2')), (select id from x60 where k = 'd1'));
select test.eq('the merged lead is closed and says why', (select status || '|' || (closed_reason like 'Duplicate: merged%')::text from leads where id = (select id from x60 where k = 'd2')), 'closed|true');
select test.eq('the kept lead keeps the second message', (select payload -> 'merged' -> 0 ->> 'message' from leads where id = (select id from x60 where k = 'd1')), 'second message');
select test.ok('a merged lead is listed nowhere', not app.sl_listed((select l from leads l where l.id = (select id from x60 where k = 'd2'))));
select test.eq('the lead page of the kept lead shows what else they wrote', jsonb_array_length(app.sales_lead(test.id('x60_admin'), jsonb_build_object('id', (select id from x60 where k = 'd1'))) -> 'merged'), 1);
select test.eq('the merged lead points to the kept one', app.sales_lead(test.id('x60_admin'), jsonb_build_object('id', (select id from x60 where k = 'd2'))) ->> 'merged_into', (select id::text from x60 where k = 'd1'));
select test.ok('the merge is in the audit log', exists (select 1 from audit_log where action = 'lead_auto_merge' and entity_id = (select id::text from x60 where k = 'd1')));
-- the same phone written differently
insert into x60 select 'd3', (submit_lead('{"kind":"contact","name":"D. Dup","phone":"+1 (226) 555 6001","message":"third, by phone"}'::jsonb, null) ->> 'lead_id')::uuid;
select test.eq('the same phone written another way joins too', (select merged_into from leads where id = (select id from x60 where k = 'd3')), (select id from x60 where k = 'd1'));
-- an owner enquiry from the same person is another kind of customer
insert into x60 select 'o1', (submit_lead('{"kind":"owner_program","name":"Dee Dup","email":"x60_dee@example.test","message":"List my car","payload":{"vehicle":"2020 Honda Civic"}}'::jsonb, null) ->> 'lead_id')::uuid;
select test.ok('an owner lead and a renter lead of one person stay apart', (select merged_into is null and status = 'new' from leads where id = (select id from x60 where k = 'o1')));
-- a handled lead is not reopened by a new form: the new one stays its own lead, offered for a merge
update leads set handled_at = now(), handled_by = test.id('x60_admin') where id = (select id from x60 where k = 'd1');
insert into x60 select 'd4', (submit_lead('{"kind":"contact","name":"Dee Dup","email":"x60_dee@example.test","message":"back again"}'::jsonb, null) ->> 'lead_id')::uuid;
select test.ok('a new form after the lead was handled is a new lead', (select merged_into is null from leads where id = (select id from x60 where k = 'd4')));
select test.eq('and the two are offered for a merge, with the reason', (select d ->> 'why' from jsonb_array_elements(app.sales_lead(test.id('x60_admin'), jsonb_build_object('id', (select id from x60 where k = 'd4'))) -> 'duplicates') d
  where d ->> 'id' = (select id::text from x60 where k = 'd1')), 'same email');
select test.eq('the lead card counts it', (app.sl_row((select l from leads l where l.id = (select id from x60 where k = 'd4')), test.id('x60_admin')) ->> 'dups')::integer, 1);

-- ---------------------------------------------------------------- duplicates: the one-click merge
select test.lives('an Admin merges with one call', format($q$ select app.door(%L, 'aal2', 'ops_do', 'lead_merge', jsonb_build_object('lead', %L, 'other', %L)) $q$,
  test.id('x60_admin'), (select id from x60 where k = 'd4'), (select id from x60 where k = 'd1')));
select test.eq('the older lead is kept, whichever one the button was on', (select merged_into from leads where id = (select id from x60 where k = 'd4')), (select id from x60 where k = 'd1'));
select test.eq('everything the person wrote is under the kept lead', (select jsonb_array_length(payload -> 'merged') from leads where id = (select id from x60 where k = 'd1')), 3);
select test.throws('a lead cannot be merged twice', format($q$ select app.lead_merge(%L, %L, %L) $q$, test.id('x60_admin'), (select id from x60 where k = 'd1'), (select id from x60 where k = 'd4')), 'already merged');
select test.throws('different kinds of customer are refused', format($q$ select app.lead_merge(%L, %L, %L) $q$, test.id('x60_admin'), (select id from x60 where k = 'd1'), (select id from x60 where k = 'o1')), 'different kinds');
select test.throws('two leads with nothing in common are refused by the door', format($q$ select app.door(%L, 'aal2', 'ops_do', 'lead_merge', jsonb_build_object('lead', %L, 'other', %L)) $q$,
  test.id('x60_admin'), (select id from x60 where k = 'a'), (select id from x60 where k = 'g')), 'do not share');
-- contacts logged on a duplicate move with it
update program_settings set lead_auto_merge = false;
insert into x60 select 'm1', (submit_lead('{"kind":"contact","name":"Mo Merge","email":"x60_mo@example.test","message":"one"}'::jsonb, null) ->> 'lead_id')::uuid;
insert into x60 select 'm2', (submit_lead('{"kind":"contact","name":"Mo Merge","email":"x60_mo@example.test","phone":"226-555-6002","message":"two"}'::jsonb, null) ->> 'lead_id')::uuid;
insert into x60 select 'm3', (submit_lead('{"kind":"contact","name":"Mo M","phone":"2265556002","message":"three"}'::jsonb, null) ->> 'lead_id')::uuid;
select test.ok('with the rule off, a second form is its own lead', (select merged_into is null from leads where id = (select id from x60 where k = 'm2')));
insert into lead_contacts (lead_id, by_user, channel, note) values ((select id from x60 where k = 'm2'), test.id('x60_sales'), 'call', 'x60 called them');
select test.eq('m3 shares only the phone with m2, and m1 only the email: all three are one person on the lead page of m2',
  jsonb_array_length(app.sales_lead(test.id('x60_admin'), jsonb_build_object('id', (select id from x60 where k = 'm2'))) -> 'duplicates'), 2);
select test.lives('merge all into the oldest', format($q$ select app.door(%L, 'aal2', 'ops_do', 'lead_merge_all', jsonb_build_object('lead', %L)) $q$, test.id('x60_admin'), (select id from x60 where k = 'm2')));
select test.eq('both went into the oldest', (select count(*)::integer from leads where merged_into = (select id from x60 where k = 'm1')), 2);
select test.ok('the call logged on the duplicate is on the kept lead', exists (select 1 from lead_contacts where lead_id = (select id from x60 where k = 'm1') and note = 'x60 called them'));
select test.eq('the kept lead took the phone it lacked', (select phone from leads where id = (select id from x60 where k = 'm1')), '226-555-6002');
-- different person
insert into x60 select 'n1', (submit_lead('{"kind":"contact","name":"Nia One","email":"x60_shared@example.test","message":"one"}'::jsonb, null) ->> 'lead_id')::uuid;
insert into x60 select 'n2', (submit_lead('{"kind":"contact","name":"Noor Two","email":"x60_shared@example.test","message":"two"}'::jsonb, null) ->> 'lead_id')::uuid;
select test.lives('marked as different people', format($q$ select app.door(%L, 'aal2', 'ops_do', 'lead_not_duplicate', jsonb_build_object('lead', %L, 'other', %L)) $q$,
  test.id('x60_admin'), (select id from x60 where k = 'n1'), (select id from x60 where k = 'n2')));
select test.eq('they are not offered again, from either side', (select count(*)::integer from app.lead_duplicates((select l from leads l where l.id = (select id from x60 where k = 'n2')))), 0);
select test.throws('a renter cannot merge leads', format($q$ select app.lead_merge_do(%L, 'lead_merge', jsonb_build_object('lead', %L, 'other', %L)) $q$,
  (select user_id from renters where id = test.id('x60_r')), (select id from x60 where k = 'n1'), (select id from x60 where k = 'n2')), 'Leads are for');
update program_settings set lead_auto_merge = true;

-- ---------------------------------------------------------------- the tracker: volume pricing, the waitlist, the email
select test.eq('1 or 2 cars', app.tracker_monthly_cents(1) || '|' || app.tracker_monthly_cents(2), '2500|2500');
select test.eq('3 to 9 cars', app.tracker_monthly_cents(3) || '|' || app.tracker_monthly_cents(9), '2000|2000');
select test.eq('10 cars or more', app.tracker_monthly_cents(10) || '|' || app.tracker_monthly_cents(250), '1500|1500');
select test.eq('the install is $150 once', (public.tracker_product() ->> 'install_cents')::integer, 15000);
select test.eq('the page reads the tiers with their ranges', (select string_agg((t ->> 'from_cars') || '-' || coalesce(t ->> 'to_cars', 'up') || ':' || (t ->> 'monthly_cents'), ' ' order by (t ->> 'from_cars')::integer)
  from jsonb_array_elements(public.tracker_product() -> 'tiers') t), '1-2:2500 3-9:2000 10-up:1500');
select test.eq('from the lowest price', (public.tracker_product() ->> 'monthly_cents')::integer, 1500);
select test.ok('trackers are not in hand: the pages show the waitlist', not (public.tracker_product() ->> 'available')::boolean);
select test.ok('what it does names the kill switch and the tolls', public.tracker_product() ->> 'features' ~* 'kill switch' and public.tracker_product() ->> 'features' ~* 'toll');
select test.throws('tiers without a price for one car are refused', $q$ update program_settings set tracker_product_tiers = '[{"from_cars": 3, "monthly_cents": 2000}]' $q$);
insert into x60 select 'w', (public.submit_tracker_waitlist('{"name":"Tara Host","email":"x60_tara@example.test","cars":"4","vehicle":"2021 Honda Civic","city":"Mississauga","want":"preorder"}'::jsonb, null) ->> 'lead_id')::uuid;
select test.eq('a lead for Sales, named for what it is', app.sl_source((select l from leads l where l.id = (select id from x60 where k = 'w'))), 'GPS tracker pre-order');
select test.eq('with the price quoted for that many cars', (select (payload ->> 'cars') || '|' || (payload ->> 'quoted_monthly_cents') || '|' || (payload ->> 'quoted_install_cents') || '|' || (payload ->> 'trackers_available')
  from leads where id = (select id from x60 where k = 'w')), '4|2000|15000|false');
select test.ok('it has its To do like every website lead', exists (select 1 from tasks where related_table = 'leads' and related_id = (select id from x60 where k = 'w')));
select test.throws('an email is needed to write back', $q$ select public.submit_tracker_waitlist('{"name":"No Email","cars":"1"}'::jsonb, null) $q$, 'email');
select app.process_events();
select test.eq('the confirmation email is queued to the address given, with its price', (select to_address || '|' || status || '|' || (payload ->> 'monthly_price') || '|' || (payload ->> 'install_price') || '|' || (payload ->> 'cars_count')
  from notification_outbox where code = 'tracker_waitlist_joined' and entity_id = (select id from x60 where k = 'w')), 'x60_tara@example.test|queued|$20 a month|$150|4');
select test.ok('nothing is missing from the email', (select missing_variables = '{}' from notification_outbox where code = 'tracker_waitlist_joined' and entity_id = (select id from x60 where k = 'w')));
update program_settings set tracker_product_enabled = false;
select test.ok('switched off: no product', public.tracker_product() is null);
select test.throws('and no sign-ups', $q$ select public.submit_tracker_waitlist('{"email":"x60_off@example.test","cars":"1"}'::jsonb, null) $q$, 'not offered');
select test.ok('and not in the sitemap', not exists (select 1 from jsonb_array_elements(public.sitemap_families()) r where r ->> 'path' = '/trackers'));
update program_settings set tracker_product_enabled = true;
select test.ok('the sitemap lists /trackers and no longer /gps-tracker', exists (select 1 from jsonb_array_elements(public.sitemap_families()) r where r ->> 'path' = '/trackers')
  and not exists (select 1 from jsonb_array_elements(public.sitemap_families()) r where r ->> 'path' = '/gps-tracker'));

-- ---------------------------------------------------------------- the services facts and the new landing pages
select test.ok('the services facts carry the tracker, the add-ons and the landing pages', public.service_facts() ? 'tracker' and jsonb_typeof(public.service_facts() -> 'addons') = 'array'
  and public.service_facts() -> 'landing' @> '["rideshare", "g2-licence", "with-a-charger", "with-flowers", "with-child-seat"]'::jsonb);
select test.eq('five landing pages, published', (select count(*)::integer from seo_pages where slug in ('rideshare', 'g2-licence', 'with-a-charger', 'with-flowers', 'with-child-seat') and is_active and status = 'published'), 5);
select test.ok('no price is typed into their copy', not exists (select 1 from seo_pages where slug in ('rideshare', 'g2-licence', 'with-a-charger', 'with-flowers', 'with-child-seat') and copy::text ~ '\$[0-9]'));
select test.ok('the visitor cannot call the server-only reads', not has_function_privilege('anon', 'public.service_facts()', 'execute') and not has_function_privilege('anon', 'public.tracker_install_places(integer)', 'execute')
  and not has_function_privilege('anon', 'public.submit_tracker_waitlist(jsonb, text)', 'execute') and not has_function_privilege('authenticated', 'public.server_contact_source_set(uuid, text, text, jsonb)', 'execute'));
