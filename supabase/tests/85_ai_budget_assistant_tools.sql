-- 85: the AI budget by feature and the assistant's offers and rentals (migration 0133). Budget: the tiers of the day (the
-- staff assistant's reserve, live features, background work), each gate asking it (the assistant, live chat, the
-- search job, vision, the Turo matcher), the release hour, Cloudflare's unmetered use counted as background, the hard
-- stop (no paid Workers AI), the Admin's shares, Settings > Usage by feature. Assistant: an offer, a rental and a
-- booking payment proposed with their details and run only on Confirm through the screens' functions, as the person,
-- with the booking event naming the staff member; role refusals as on the screens. Fixtures start with "ab".
select test.suite('85 AI budget and assistant tools');

select test.mk_user('ab_admin', 'admin');
select test.mk_user('ab_cs', 'va', 'cs');
select test.mk_user('ab_fleet', 'va', 'fleet');
select test.mk_renter('ab_rita');
update program_settings set require_staff_two_step = false;
update staff_profiles set single_limit_cents = 500000 where user_id = test.id('ab_cs');

-- a clean day for Workers AI (the earlier suites spent neurons today)
delete from provider_calls where unit = 'neurons' and created_at >= app.local_midnight(app.today()) - interval '1 day';
delete from usage_readings where service = 'workers_ai';
update usage_services set included = 10000, paid_extra = 0 where service = 'workers_ai';
update program_settings set seo_ai_writer_enabled = false, ai_background_bps = 1000;  -- 40 and 52 turn the writer on

create table test.ab (k text primary key, v jsonb);
grant select on test.ab to authenticated, service_role;
create function test.abv(p text) returns jsonb language sql stable as $$ select v from test.ab where k = p $$;
create function test.noon() returns timestamptz language sql stable as $$ select app.local_midnight(app.today()) + interval '12 hours' $$;
create function test.ai(p_purpose text, p_n integer) returns void language sql as $$
  insert into provider_calls (provider, purpose, ok, units, unit) values ('workers-ai', p_purpose, true, p_n, 'neurons') $$;

-- ================================================================ 1. the tiers of the day
select test.eq('the defaults: 70% kept for the assistant, 10% for background, the release at 9 pm',
  (select ai_assistant_reserve_bps || '/' || ai_background_bps || '/' || ai_release_hour || '/' || ai_assistant_cushion || '/' || assistant_daily_neurons from (select (app.settings()).*) s), '7000/1000/21/500/10000');
select test.eq('a fresh day: the assistant may use all of it, live features 3,000, background 1,000',
  (select (b #>> '{room,assistant}') || '/' || (b #>> '{room,live}') || '/' || (b #>> '{room,background}') from (select app.ai_budget(test.noon()) b) x), '10000/3000/1000');
select test.ai('seo_car', 900);
select test.eq('background spent 900: 100 left for it, the assistant''s reserve untouched',
  (select (b #>> '{room,assistant}') || '/' || (b #>> '{room,live}') || '/' || (b #>> '{room,background}') from (select app.ai_budget(test.noon()) b) x), '9100/2100/100');
select test.eq('a search item (about 800 neurons) does not fit: refused before the call', (app.ai_allow('seo_car', 800, test.noon()) ->> 'ok')::boolean, false);
select test.eq('its words: it waits for the release hour or tomorrow', app.ai_allow('seo_car', 800, test.noon()) ->> 'message' like 'Background AI writing waits%after 21:00%', true);
select test.eq('the website''s search copy writer is off by default: the daily Claude batch writes it', (select (c ->> 'ai_wait') like '%daily Claude batch%' from (select app.server_seo_claim('t85', 3) c) x), true);
update program_settings set seo_ai_writer_enabled = true;
select test.eq('the search job claims nothing to write and says why', (select (c ->> 'ai_wait') is not null and jsonb_array_length(coalesce(c -> 'cars', '[]')) = 0 from (select app.server_seo_claim('t85', 3) c) x), true);
update program_settings set seo_ai_writer_enabled = false;
select test.eq('live chat still answers', (app.ai_allow('chat', 150, test.noon()) ->> 'ok')::boolean, true);
select test.ai('chat', 2200);
select test.eq('live features used their share: chat waits', (app.ai_allow('chat', 150, test.noon()) ->> 'ok')::boolean, false);
select test.eq('the chat''s own gate says so', (app.chat_budget() ->> 'ok')::boolean, false);
select test.eq('the phone line too', (app.phone_ai_budget() ->> 'ok')::boolean, false);
select test.eq('the Turo matcher reads by the rules only', (app.turo_match_keys() ->> 'ai_ok')::boolean, false);
select test.eq('the toll reader waits, with the reason', (app.ai_vision_gate(test.id('ab_admin'), 'toll_read') ->> 'allowed')::boolean, false);
select test.eq('the staff assistant still has 6,900 of the day', (app.ai_budget(test.noon()) #>> '{room,assistant}')::numeric, 6900::numeric);
select test.eq('and its gate is open', (app.usage_gate('workers_ai') ->> 'ok')::boolean, true);
select test.eq('after the release hour, what is left goes to the others, less the cushion',
  (select (b #>> '{room,live}') || '/' || (b #>> '{room,background}') || '/' || (b ->> 'late') from (select app.ai_budget(app.local_midnight(app.today()) + interval '22 hours') b) x), '6400/6400/true');

-- Cloudflare counting more than the app recorded: the difference is background, never the assistant's
select app.usage_put('workers_ai', app.today(), 'cloudflare', 5000);
select test.eq('the larger figure counts; the unmetered 1,900 is background',
  (select (b ->> 'used') || '/' || (b ->> 'unmetered') || '/' || (b #>> '{tiers,background}') || '/' || (b #>> '{room,assistant}') from (select app.ai_budget(test.noon()) b) x), '5000/1900/2800/5000');
delete from usage_readings where service = 'workers_ai' and source = 'cloudflare';

-- the assistant spends the rest: used up, with when it is back
select test.ai('staff_assistant', 7000);
select test.eq('the day used up: the assistant''s gate closes', (app.usage_gate('workers_ai') ->> 'ok')::boolean, false);
select test.eq('its words: how much is used and when it is back', app.usage_gate('workers_ai') ->> 'message',
  'Today''s free AI allowance is used up (10,100 of 10,000 neurons). The assistant is back at midnight, Toronto time. Everything still works from the screens and pop-ups.');
select test.eq('the gate says when it resets', (app.usage_gate('workers_ai') ->> 'resets_at')::timestamptz, app.local_midnight(app.today() + 1));
select test.eq('the service is paused for the day', app.usage_refresh_service('workers_ai') ->> 'state', 'paused');

-- ================================================================ 2. hard stop: no paid Workers AI
select test.throws('paid Workers AI cannot be allowed', $$select app.usage_decide(test.id('ab_admin'), '{"service": "workers_ai", "decision": "allow", "until": "day", "cap_usd": 5}')$$, 'free daily allowance');
select test.throws('nor by an assistant', $$select app.usage_decide(test.id('ab_cs'), '{"service": "workers_ai", "decision": "allow", "cap_usd": 5}')$$, 'Only an Admin');
select test.lives('keep paused is still an answer', $$select app.usage_decide(test.id('ab_admin'), '{"service": "workers_ai", "decision": "keep_paused"}')$$);
select test.eq('an old allowance gives nothing', (select paid_extra from usage_services where service = 'workers_ai'), 0::numeric);
select test.eq('the state says hard stop', (app.usage_state('workers_ai') ->> 'hard_stop')::boolean, true);
select test.eq('the gates'' ceiling stays at the included neurons', (app.settings()).chat_ai_total_daily_neurons, 10000);

-- ================================================================ 3. Settings > Usage by feature, and the shares
select test.eq('Settings > Usage: Workers AI by feature, labelled, with the tier',
  (select string_agg((f ->> 'label') || ':' || (f ->> 'tier') || ':' || (f ->> 'today'), ', ' order by f ->> 'purpose')
     from jsonb_array_elements(app.usage_page(test.id('ab_admin')) #> '{ai,features}') f),
  'Visitor live chat:live:2200, Search copy: car pages:background:900, Staff assistant:assistant:7000');
select test.eq('and the days by tier', (app.usage_page(test.id('ab_admin')) #> '{ai,days}') @> jsonb_build_array(jsonb_build_object('day', app.today(), 'assistant', 7000, 'live', 2200, 'background', 900)), true);
select test.throws('an assistant does not change the shares', $$select app.door(test.id('ab_cs'), 'aal2', 'admin_do', 'ai_shares_save', '{"reserve_bps": 9000}')$$, null);
select test.throws('the reserve and the background share fit in 100%', $$select app.door(test.id('ab_admin'), 'aal2', 'admin_do', 'ai_shares_save', '{"reserve_bps": 9500, "background_bps": 1000}')$$, 'more than 100%');
select test.throws('the release hour is an hour', $$select app.ai_shares_save(test.id('ab_admin'), '{"release_hour": 25}')$$, 'from 0 to 23');
select test.eq('an Admin changes them', (select (b ->> 'reserve_bps') || '/' || (b ->> 'background_bps') || '/' || coalesce(b ->> 'release_hour', 'never')
   from (select app.door(test.id('ab_admin'), 'aal2', 'admin_do', 'ai_shares_save', '{"reserve_bps": 8000, "background_bps": 500, "release_hour": ""}') b) x), '8000/500/never');
select test.eq('and they are audited', exists (select 1 from audit_log where entity_table = 'program_settings' and after ->> 'ai_assistant_reserve_bps' = '8000'), true);
select app.ai_shares_save(test.id('ab_admin'), '{"reserve_bps": 7000, "background_bps": 1000, "release_hour": "21"}');

-- a fresh day again for the assistant's tools
delete from provider_calls where unit = 'neurons' and created_at >= app.local_midnight(app.today()) - interval '1 day';

-- ================================================================ 4. the assistant: an offer, a rental, a payment
insert into test.ab select 'car', app.vehicle_add(test.id('ab_admin'), jsonb_build_object('supply_type', 'company', 'vin', '1XFCXMM0000000085', 'plate', 'ABC085', 'year', 2024, 'make', 'Kia', 'model', 'K5',
  'rates', jsonb_build_object('daily', 10000, 'weekend', 10000, 'weekly', 70000, 'monthly', 300000, 'deposit', 30000)));
insert into test.ab select 'car2', app.vehicle_add(test.id('ab_admin'), jsonb_build_object('supply_type', 'company', 'vin', '1XFCXMM0000000086', 'plate', 'ABC086', 'year', 2024, 'make', 'Kia', 'model', 'K5',
  'rates', jsonb_build_object('daily', 10000, 'weekend', 10000, 'weekly', 70000, 'monthly', 300000, 'deposit', 30000)));
create function test.abcar(p text) returns uuid language sql stable as $$ select (test.abv(p) ->> 'vehicle_id')::uuid $$;
create function test.aboffer() returns jsonb language sql stable as $$
  select jsonb_build_object('renter', jsonb_build_object('full_name', 'Nora Assist', 'email', 'nora.assist@example.test', 'mobile', '(289) 555-0885', 'date_of_birth', '1990-04-05'),
    'vehicle_id', test.abcar('car'), 'pickup_at', date_trunc('hour', now()) + interval '4 days', 'return_at', date_trunc('hour', now()) + interval '6 days', 'source', 'phone',
    'rental_pay_method', 'e_transfer', 'deposit_pay_method', 'card', 'sales_choice', 'for_carmacars', 'notify', true, 'channels', jsonb_build_object('email', true, 'text', false)) $$;

select test.eq('the card''s preview prices the offer and keeps nothing',
  (select (x ->> 'ok') || '/' || ((x #>> '{booking,rental_charge_cents}')::bigint > 0)::text || '/' || (select count(*) from bookings where vehicle_id = test.abcar('car'))
     from (select app.door(test.id('ab_cs'), 'aal2', 'ops_read', 'offer_preview', test.aboffer()) x) q), 'true/true/0');
insert into test.ab select 'offer', app.door(test.id('ab_cs'), 'aal2', 'ops_do', 'assistant_propose', jsonb_build_object('portal', 'va', '_va', 'cs', 'tool', 'create_offer', 'name', 'offer_create', 'args', test.aboffer(),
  'summary', 'Send an offer for the 2024 Kia K5 to Nora Assist?', 'details', '[{"title": "Price", "rows": [{"label": "Due at booking", "value": "$226.00"}]}]'::jsonb));
select test.eq('an offer proposed: a card with its details, through the screen''s door; nothing made yet',
  (select call || ' ' || name || ' ' || status || ' ' || (details #>> '{0,rows,0,label}') || ' ' || (select count(*) from bookings where vehicle_id = test.abcar('car'))
     from assistant_actions where id = (test.abv('offer') ->> 'id')::uuid), 'ops_do offer_create proposed Due at booking 0');
select test.eq('the card comes back with its details', test.abv('offer') #>> '{details,0,title}', 'Price');
select test.eq('Confirm: the offer is made and sent, as customer service',
  (select (r ->> 'ok') || '/' || (r #>> '{result,status}') from (select app.door(test.id('ab_cs'), 'aal2', 'ops_do', 'assistant_confirm', jsonb_build_object('id', test.abv('offer') ->> 'id', '_va', 'cs')) r) x), 'true/offered');
select test.eq('the booking says the assistant made it, by whom',
  (select note like 'Offer made with the staff assistant by %' || (select full_name from users where id = test.id('ab_cs')) || '%' from booking_events where booking_id = (select id from bookings where vehicle_id = test.abcar('car')) and details ->> 'via' = 'assistant'), true);
select test.eq('paid by e-Transfer: staff confirm when the money is in', (select rental_pay_method from bookings where vehicle_id = test.abcar('car')), 'e_transfer');
select test.eq('the audit log: the staff member, via assistant', exists (select 1 from audit_log where action = 'assistant_action' and actor_user_id = test.id('ab_cs') and after ->> 'name' = 'offer_create' and after ->> 'note' = 'via assistant'), true);

-- Fleet sends no offer: refused at Confirm as on the screen, and nothing made
insert into test.ab select 'fleet', app.door(test.id('ab_fleet'), 'aal2', 'ops_do', 'assistant_propose', jsonb_build_object('portal', 'va', '_va', 'fleet', 'tool', 'create_offer', 'name', 'offer_create',
  'args', test.aboffer() || jsonb_build_object('vehicle_id', test.abcar('car2')), 'summary', 'Send an offer?'));
select test.eq('Fleet: refused with the screen''s reason', (select (r ->> 'ok') || ' ' || (r ->> 'error') like 'false %customer service or sales%' from (select app.assistant_confirm(test.id('ab_fleet'), 'aal2', jsonb_build_object('id', test.abv('fleet') ->> 'id')) r) x), true);
select test.eq('nothing made for Fleet', (select count(*) from bookings where vehicle_id = test.abcar('car2')), 0::bigint);
select test.throws('another action name for the tool is refused', $$select app.assistant_propose(test.id('ab_cs'), '{"portal": "va", "tool": "create_offer", "name": "usage_decide", "args": {}, "summary": "x?"}')$$, 'cannot do that here');

-- a payment by part on that booking, through the assistant
insert into test.ab select 'pay', app.door(test.id('ab_cs'), 'aal2', 'ops_do', 'assistant_propose', jsonb_build_object('portal', 'va', '_va', 'cs', 'tool', 'record_payment', 'name', 'record_booking_payment',
  'args', jsonb_build_object('booking', (select booking_number from bookings where vehicle_id = test.abcar('car')), 'covers', 'rental', 'method', 'e_transfer', 'reference', 'AB85PAY', 'received_on', app.today()),
  'summary', 'Record the rental by e-Transfer?'));
select test.eq('Confirm: the rental part recorded by e-Transfer', (app.door(test.id('ab_cs'), 'aal2', 'ops_do', 'assistant_confirm', jsonb_build_object('id', test.abv('pay') ->> 'id', '_va', 'cs')) ->> 'ok')::boolean, true);
select test.eq('the payment is on the booking, for the rental', (select method || ':' || covers from manual_payments where reference = 'AB85PAY'), 'e_transfer:rental');
select test.eq('and its history names the assistant', exists (select 1 from booking_events where booking_id = (select id from bookings where vehicle_id = test.abcar('car')) and note like 'Payment recorded with the staff assistant by %'), true);

-- a rental added by hand, through the assistant (Admin)
insert into test.ab select 'rent', app.assistant_propose(test.id('ab_admin'), jsonb_build_object('portal', 'admin', 'tool', 'add_rental', 'name', 'manual_rental_create',
  'args', jsonb_build_object('vehicle_id', test.abcar('car2'), 'pickup_at', date_trunc('hour', now()) + interval '8 days', 'return_at', date_trunc('hour', now()) + interval '10 days',
    'source', 'phone', 'coverage_option', 1, 'renter_id', test.id('renter:ab_rita'), 'sales_choice', 'for_carmacars', 'pickup_method', 'collected', 'return_method', 'returned', 'booking_type', 'standard',
    'payment', jsonb_build_object('mode', 'other_way', 'method', 'cash', 'received_on', app.today()), 'deposit', jsonb_build_object('method', 'cash')),
  'summary', 'Add a rental of the 2024 Kia K5?', 'details', '[{"title": "Payments", "rows": [{"label": "Rental", "value": "Paid by cash"}]}]'::jsonb));
select test.eq('Confirm: the rental is booked', (select (r ->> 'ok') || '/' || (r #>> '{result,status}') from (select app.assistant_confirm(test.id('ab_admin'), 'aal2', jsonb_build_object('id', test.abv('rent') ->> 'id')) r) x), 'true/confirmed');
select test.eq('its history names the assistant and the Admin', exists (select 1 from booking_events where booking_id = (select id from bookings where vehicle_id = test.abcar('car2')) and note like 'Rental added with the staff assistant by %'), true);
select test.eq('the card''s details are kept with the action', (select details #>> '{0,rows,0,value}' from assistant_actions where id = (test.abv('rent') ->> 'id')::uuid), 'Paid by cash');

-- the money of a booking, for "what does X owe"
select test.eq('booking money reads through the door for customer service',
  (select jsonb_array_length(m -> 'parts') from (select app.door(test.id('ab_cs'), 'aal2', 'ops_read', 'booking_money', jsonb_build_object('booking', (select booking_number from bookings where vehicle_id = test.abcar('car')), '_va', 'cs')) m) x), 3);

-- ================================================================ 5. search copy batches (docs/seo-batches.md)
insert into seo_pages (slug, kind, name, facts, match, copy) values
  ('ab-place', 'location', 'Ab Place', '{"highways": ["401"]}', '{}', '{"seo_title": "Car Rental in Ab Place | CarmaCars", "meta_description": "x", "h1": "Car rental in Ab Place", "intro": "Intro.", "sections": [], "faq": []}');
insert into articles (slug, title, description, body_md) values ('ab-guide', 'Ab guide title for renters', 'How to rent a car around Toronto in winter: tires, the deposit, the roads and the return, in plain steps.', 'Old body.');
select test.eq('the queue: landing pages first, then cars, then guides, each with what the writer needs',
  (select (q -> 'items' -> 0 ->> 'kind') || '/' || (q -> 'items' -> 0 ->> 'url') || '/' || (q -> 'items' -> 0 ? 'facts')::text || '/' || (q -> 'items' -> 0 ->> 'priority')
     from (select app.seo_batch_queue(500) q) x), 'page/' || (select '/car-rental/' || slug from seo_pages where is_active order by (kind = 'location') desc, coalesce(was_indexable, true) desc, status in ('pending', 'failed') desc, slug limit 1) || '/true/1');
select test.eq('the guide is in the queue with its brief and current text', (select count(*) from jsonb_array_elements(app.seo_batch_queue(5000) -> 'items') i where i ->> 'id' = 'ab-guide' and i -> 'current' ? 'body_md'), 1::bigint);
select test.eq('the limit', jsonb_array_length(app.seo_batch_queue(2) -> 'items'), 2);
select test.eq('the live facts by address or id; an unknown address is missing',
  (select string_agg(coalesce(i ->> 'kind', 'missing'), ',') from jsonb_array_elements(app.seo_batch_context('[{"url": "/car-rental/ab-place"}, {"kind": "article", "id": "ab-guide"}, {"url": "/car-rental/nowhere"}]') -> 'items') i), 'page,article,missing');
select test.eq('publish: the page and the guide as claude-batch; a broken car copy is rejected with the reason',
  (select string_agg((e ->> 'kind') || ':' || (e ->> 'status'), ',') from jsonb_array_elements(app.seo_batch_publish(jsonb_build_object('batch', 't85', 'items', jsonb_build_array(
     jsonb_build_object('kind', 'page', 'id', 'ab-place', 'copy', jsonb_build_object('seo_title', 'Car Rental in Ab Place | CarmaCars', 'h1', 'Car rental in Ab Place', 'intro', 'New intro.', 'sections', '[]'::jsonb, 'faq', '[]'::jsonb)),
     jsonb_build_object('kind', 'article', 'id', 'ab-guide', 'title', 'A new guide title for renters', 'body_md', '## New' || chr(10) || 'New body.'),
     jsonb_build_object('kind', 'car', 'id', (select vehicle_id from car_copy limit 1), 'copy', '{"intro": ""}'::jsonb)))) -> 'results') e), 'page:published,article:published,car:rejected');
select test.eq('the page''s source, its text, published', (select source || '/' || (copy ->> 'intro') || '/' || status from seo_pages where slug = 'ab-place'), 'claude-batch/New intro./published');
select test.eq('the guide''s source', (select source || '/' || title from articles where slug = 'ab-guide'), 'claude-batch/A new guide title for renters');
select test.eq('a written page leaves the queue while its facts stay the same', (select count(*) from jsonb_array_elements(app.seo_batch_queue(5000) -> 'items') i where i ->> 'id' in ('ab-place', 'ab-guide')), 0::bigint);
update seo_pages set locked = '{h1}', copy = copy || '{"h1": "Kept by a person"}' where slug = 'ab-place';
select app.seo_batch_publish('{"items": [{"kind": "page", "id": "ab-place", "copy": {"h1": "Replaced", "intro": "Again."}}]}');
select test.eq('a field a person locked is kept', (select copy ->> 'h1' from seo_pages where slug = 'ab-place'), 'Kept by a person');
select test.eq('the publish is audited', exists (select 1 from audit_log where action = 'seo_batch_publish' and after ->> 'batch' = 't85'), true);
