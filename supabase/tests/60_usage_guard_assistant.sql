-- 60: the usage guard and the staff assistant (migration 0080). Usage: the ledger and its sources, the 80% and 100%
-- alerts once per service and period, the alert email (address, quiet hours, daily maximum, values), the gates paused by
-- default at the included allowance, paid usage allowed up to a cap (and kept paused), services that are never paused,
-- Admin-only pages and answers. Assistant: reads scoped to the person's portal and function, changes stored as a card
-- and run only on Confirm through the same door as the screens, as the person; refusals for actions their role may not
-- do; the audit actor and "via assistant". Fixtures start with "ug".
select test.suite('60 usage guard and assistant');

select test.mk_user('ug_admin', 'admin');
select test.mk_user('ug_admin2', 'admin');
select test.mk_user('ug_fin', 'va', 'finance');
select test.mk_user('ug_cs', 'va', 'cs');
select test.mk_user('ug_fleet', 'va', 'fleet');
select test.mk_user('ug_field', 'field');
select test.mk_owner('ug_own');
select test.mk_vehicle('UGV1', 'ug_own');
select test.mk_renter('ug_rita');
update vehicles set make = 'Toyota', model = 'Corolla', year = 2023, plate = 'UGCAR1' where id = test.id('vehicle:UGV1');
update program_settings set require_staff_two_step = false;

-- ================================================================ 1. the services and the ledger
select test.eq('every metered service is in the ledger, in order',
  (select string_agg(service, ',' order by sort) from usage_services),
  'workers_ai,workers_requests,workers_cpu,images,resend_day,resend_month,supabase_db,supabase_storage,supabase_egress,r2_storage,github_actions,claude');
select test.eq('the included defaults of the plans', (select string_agg(service || '=' || included::bigint, ',' order by sort) from usage_services where service in ('workers_ai', 'workers_requests', 'workers_cpu', 'images', 'resend_day', 'resend_month')),
  'workers_ai=10000,workers_requests=10000000,workers_cpu=30000000,images=5000,resend_day=100,resend_month=3000');
select test.eq('what pauses, holds or only alerts', (select string_agg(service || ':' || pause_mode, ',' order by sort) from usage_services where service in ('workers_ai', 'workers_requests', 'images', 'resend_day', 'supabase_db', 'claude')),
  'workers_ai:pause,workers_requests:alert,images:pause,resend_day:hold,supabase_db:alert,claude:pause');
select test.eq('GitHub Actions: free while the repository is public', (app.usage_state('github_actions') ->> 'state'), 'free');
select test.eq('the Claude assistant: an included budget of US$0, so it asks before spending', (select included from usage_services where service = 'claude'), 0::numeric);

delete from provider_calls;
insert into provider_calls (provider, purpose, ok, units, unit) values ('workers-ai', 'chat', true, 7000, 'neurons');
select test.eq('Workers AI: the app''s own record of the day', (app.usage_refresh_service('workers_ai') ->> 'used')::numeric, 7000::numeric);
select test.lives('Cloudflare''s figure is recorded beside it', $$select app.usage_record_external(('{"source": "cloudflare", "days": [{"day": "' || app.today() || '", "values": {"workers_ai": 7600, "workers_requests": 120000, "workers_cpu": 900000}}]}')::jsonb)$$);
select test.eq('where two sources report a day, the larger counts', app.usage_used('workers_ai'), 7600::numeric);
select test.throws('an unknown service is refused', $$select app.usage_record_external(('{"source": "cloudflare", "days": [{"day": "' || app.today() || '", "values": {"nope": 1}}]}')::jsonb)$$, 'Unknown service');
select test.throws('a figure that is not a number is refused', $$select app.usage_record_external(('{"source": "cloudflare", "days": [{"day": "' || app.today() || '", "values": {"workers_cpu": "-5"}}]}')::jsonb)$$, 'Not a number');
select test.lives('a monthly figure on an earlier day of the month', $$select app.usage_put('workers_requests', date_trunc('month', app.today())::date, 'cloudflare', 50000) where date_trunc('month', app.today())::date < app.today()$$);
select test.eq('a monthly service adds up its days', app.usage_used('workers_requests'),
  (case when date_trunc('month', app.today())::date < app.today() then 170000 else 120000 end)::numeric);
select test.eq('the database size is measured', (app.usage_refresh_service('supabase_db') ->> 'used')::numeric > 0, true);

-- ================================================================ 2. alerts: 80% once, 100% once, per period
delete from usage_alerts;
select test.eq('76%: within the allowance', app.usage_refresh_service('workers_ai') ->> 'state', 'ok');
insert into provider_calls (provider, purpose, ok, units, unit) values ('workers-ai', 'seo_car', true, 1200, 'neurons');
select test.eq('82%: near it', app.usage_refresh_service('workers_ai') ->> 'state', 'warn');
select app.usage_refresh_service('workers_ai');
select test.eq('one 80% alert for the day, however often it is refreshed', (select count(*) from usage_alerts where service = 'workers_ai' and level = 80), 1::bigint);
insert into provider_calls (provider, purpose, ok, units, unit) values ('workers-ai', 'chat', true, 2000, 'neurons');
select test.eq('used up and no paid usage allowed: paused', app.usage_refresh_service('workers_ai') ->> 'state', 'paused');
select app.job_usage_refresh();
select test.eq('one 100% alert for the day', (select count(*) from usage_alerts where service = 'workers_ai' and level = 100 and period_start = app.today()), 1::bigint);
select test.eq('the 80% email is not sent once the 100% one goes', (select email_note from usage_alerts where service = 'workers_ai' and level = 80), 'covered by the 100% alert');

-- ================================================================ 3. paused by default: the existing gates stop at the included neurons
select test.eq('the gates'' ceiling is the included allowance', (app.settings()).chat_ai_total_daily_neurons, 10000);
select test.eq('live chat: the AI stops (the visitor reads that the assistant rests; the chat goes to a person)', (app.chat_budget() ->> 'ok')::boolean, false);
select test.eq('search copy waits for tomorrow', ((app.seo_neurons_today() ->> 'all')::numeric < (app.settings()).chat_ai_total_daily_neurons), false);
select test.eq('the staff assistant''s gate is closed', (app.usage_gate('workers_ai') ->> 'ok')::boolean, false);
update usage_services set included = 20000 where service = 'workers_ai';
select test.eq('an Admin raising the allowance raises the gates, never above Program settings', (app.settings()).chat_ai_total_daily_neurons, 10000);
update usage_services set included = 5000 where service = 'workers_ai';
select test.eq('and lowering it lowers them', (app.settings()).chat_ai_total_daily_neurons, 5000);
update usage_services set included = 10000 where service = 'workers_ai';
select test.eq('the stored Program settings are untouched', (select chat_ai_total_daily_neurons from program_settings where id = (app.settings()).id), 10000);

-- the Admin's card and question
select test.eq('Admin > To do: the used-up card', (app.usage_cards(test.id('ug_admin')) -> 'cards' -> 0 ->> 'title'), 'Included Workers AI used up for today');
select test.throws('an assistant does not get the Admin''s usage cards', $$select app.usage_cards(test.id('ug_fin'))$$, 'Only an Admin');
select test.throws('nor the usage page', $$select app.door(test.id('ug_fin'), '', 'admin_read', 'usage', '{}')$$, null);
select test.throws('nor may answer the question', $$select app.usage_decide(test.id('ug_cs'), '{"service": "workers_ai", "decision": "allow", "cap_usd": 5}')$$, 'Only an Admin');
select test.throws('a cap is needed to allow paid usage', $$select app.usage_decide(test.id('ug_admin'), '{"service": "workers_ai", "decision": "allow"}')$$, 'most it may cost');
select test.throws('and no more than US$1,000', $$select app.usage_decide(test.id('ug_admin'), '{"service": "workers_ai", "decision": "allow", "cap_usd": 5000}')$$, 'US$1,000');

-- ================================================================ 4. allow paid usage up to a cap, keep paused
select test.eq('allowed until the end of today, up to US$1', app.usage_decide(test.id('ug_admin'), '{"service": "workers_ai", "decision": "allow", "until": "day", "cap_usd": 1}') ->> 'state', 'paid');
select test.eq('the gates open by what US$1 buys (90,909 neurons at US$0.011 per 1,000)', (app.settings()).chat_ai_total_daily_neurons, 10000 + 90909);
select test.eq('live chat answers again', (app.chat_budget() ->> 'ok')::boolean, true);
select test.eq('the decision is the Admin''s, and audited', exists (select 1 from usage_decisions where decided_by = test.id('ug_admin'))
  and exists (select 1 from audit_log where entity_table = 'usage_decisions' and action = 'INSERT'), true);
insert into provider_calls (provider, purpose, ok, units, unit) values ('workers-ai', 'chat', true, 100000, 'neurons');
select test.eq('past the cap: paused again', app.usage_refresh_service('workers_ai') ->> 'state', 'paused');
select test.eq('the spending is counted at the paid rate', round((app.usage_state('workers_ai') #>> '{decision,spent_usd}')::numeric, 2), 1.10::numeric);
select test.eq('kept paused: the gates are back at the allowance', app.usage_decide(test.id('ug_admin'), '{"service": "workers_ai", "decision": "keep_paused"}') ->> 'state', 'paused');
select test.eq('and the ceiling with them', (app.settings()).chat_ai_total_daily_neurons, 10000);
select test.eq('a month''s decision on a monthly service', app.usage_decide(test.id('ug_admin'), '{"service": "images", "decision": "allow", "until": "day", "cap_usd": 3}') #>> '{decision,until}', 'month');
select test.throws('emails cannot be paid on the free plan: upgrade', $$select app.usage_decide(test.id('ug_admin'), '{"service": "resend_day", "decision": "allow", "cap_usd": 5}')$$, 'cannot pay for more on the free plan');
select test.throws('the website is never paused, so there is nothing to allow', $$select app.usage_decide(test.id('ug_admin'), '{"service": "workers_requests", "decision": "allow", "cap_usd": 5}')$$, 'never paused');

-- the website and the database: alert only, with the estimated cost
select app.usage_put('workers_requests', app.today(), 'cloudflare', 12000000);
select test.eq('website requests over the allowance: never paused', app.usage_refresh_service('workers_requests') ->> 'state', 'over');
select test.eq('the estimated overage cost', (app.usage_state('workers_requests') ->> 'overage_usd')::numeric >= 0.6, true);
select test.eq('its card says so', (app.usage_cards(test.id('ug_admin')) -> 'cards') @> '[{"service": "workers_requests", "level": 100}]', true);
update usage_services set included = 524288000 where service = 'supabase_db';   -- the Free plan's 500 MB (0104: it follows Admin's database plan)
select app.usage_put('supabase_db', app.today(), 'supabase', 450 * 1048576);
select test.eq('the database at 86%: an alert, writes never blocked', app.usage_refresh_service('supabase_db') ->> 'state', 'warn');
select test.eq('emails: held, never paid', (select pause_mode from usage_services where service = 'resend_day'), 'hold');
update usage_services set included = 50 where service = 'resend_day';
select test.eq('the email cap never exceeds the included emails', (app.settings()).notify_daily_cap, 50);
update usage_services set included = 100 where service = 'resend_day';

-- ================================================================ 5. the alert email: address, quiet hours, daily maximum, values
delete from notification_outbox where code = 'staff_usage_alert';
delete from notifications where code = 'staff_usage_alert';
delete from app_events where code = 'staff_usage_alert';
update usage_alerts set emailed_at = null, email_note = null where email_note is distinct from 'covered by the 100% alert';
select test.eq('never at night: 3 am in Toronto sends nothing', app.usage_send_alerts(app.local_midnight(app.today()) + interval '3 hours'), 0);
update program_settings set usage_alert_max_emails = 2;
select test.eq('in the day: at most the daily maximum', app.usage_send_alerts(app.local_midnight(app.today()) + interval '10 hours'), 2);
select test.eq('the rest are shown on Admin > To do and say why', (select count(*) from usage_alerts where email_note like 'not emailed%'), 1::bigint);
select test.eq('one event per alert email', (select count(*) from app_events where code = 'staff_usage_alert'), 2::bigint);
update program_settings set usage_alert_max_emails = 4;
select test.eq('to the alert address of Program settings',
  (select r.email from app_events e, notification_catalogue c, app.notification_recipients(e, c) r where e.code = 'staff_usage_alert' and c.code = 'staff_usage_alert' limit 1),
  lower((app.settings()).uptime_alert_email));
select test.ok('with the values the email needs',
  (select app.notification_payload('staff_usage_alert', e, '{"audience": "staff_admin"}') ?& array['usage_title', 'usage_used', 'usage_included', 'usage_share', 'usage_effect', 'usage_cost', 'usage_advice', 'usage_resets']
     from app_events e where e.code = 'staff_usage_alert' order by e.id limit 1));
select test.eq('the catalogue entry exists with its email', (select has_email from notification_catalogue where code = 'staff_usage_alert'), true);

-- ================================================================ 6. Admin edits and figures
select test.eq('an Admin changes an allowance (sizes in MB)', (app.usage_service_save(test.id('ug_admin'), '{"service": "supabase_db", "included_mb": 8192}') ->> 'included')::numeric, 8192 * 1048576::numeric);
select test.throws('an assistant may not', $$select app.usage_service_save(test.id('ug_fin'), '{"service": "supabase_db", "included": 1}')$$, 'Only an Admin');
select test.throws('the early warning stays between 10% and 99%', $$select app.usage_service_save(test.id('ug_admin'), '{"service": "workers_ai", "warn_bps": 500}')$$, 'between 10%');
select test.eq('a figure typed from Supabase''s dashboard (egress)', (app.usage_reading_save(test.id('ug_admin'), jsonb_build_object('service', 'supabase_egress', 'day', app.today(), 'used_mb', 1024)) ->> 'used')::numeric >= 1073741824, true);
select test.eq('the usage page: every service with its history', jsonb_array_length(app.usage_page(test.id('ug_admin')) -> 'services'), 12);

-- ================================================================ 7. the assistant: reads within the person's portal and function
select test.eq('an Admin finds a car', (app.assistant_find(test.id('ug_admin'), '{"portal": "admin", "kind": "car", "q": "ugcar1"}') -> 'rows' -> 0 ->> 'plate'), 'UGCAR1');
-- release 2: the car code (0079) finds the car, and Mark a car insured (0078) is one of the assistant's actions
select test.eq('an Admin finds a car by its car code', (app.assistant_find(test.id('ug_admin'), jsonb_build_object('portal', 'admin', 'kind', 'car', 'q',
  (select lower(car_code) from vehicles where plate = 'UGCAR1'))) -> 'rows' -> 0 ->> 'plate'), 'UGCAR1');
select test.eq('Mark a car insured goes through the same door as Insurer confirmed', app.assistant_action_door('mark_insured', 'va', 'insurer_confirm'), 'ops_do');
select test.eq('field staff do not mark cars insured', app.assistant_action_door('mark_insured', 'field', 'insurer_confirm'), null::text);
select test.throws('an assistant cannot use the Admin''s assistant', $$select app.assistant_find(test.id('ug_fin'), '{"portal": "admin", "kind": "car", "q": "x"}')$$, 'Only an Admin');
select test.throws('field staff see bookings through their jobs only', $$select app.assistant_find(test.id('ug_field'), '{"portal": "field", "kind": "booking", "q": "x"}')$$, 'through their jobs');
select test.throws('invoices and owner balances are Finance work', $$select app.assistant_find(test.id('ug_fleet'), '{"portal": "va", "kind": "invoice", "q": "INV"}')$$, 'Finance work');
select test.lives('Finance finds owner balances', $$select app.assistant_find(test.id('ug_fin'), '{"portal": "va", "kind": "owner_balance", "q": "ug own"}')$$);
select test.throws('renters are not Fleet''s', $$select app.assistant_find(test.id('ug_fleet'), '{"portal": "va", "kind": "renter", "q": "rita"}')$$, 'Renters are found');
select test.eq('who has a car: field staff see it too', (app.assistant_find(test.id('ug_field'), '{"portal": "field", "kind": "car_now", "q": "UGCAR1"}') ->> 'count')::integer, 1);
select test.lives('through the door, as the person', $$select app.door(test.id('ug_field'), '', 'ops_read', 'assistant_find', '{"portal": "field", "kind": "car", "q": "corolla"}')$$);
select test.eq('the assistant''s gate tells the panel whether it is on', (app.door(test.id('ug_cs'), '', 'ops_read', 'usage_gate', '{"portal": "va", "service": "workers_ai"}') ? 'assistant_enabled'), true);

-- ================================================================ 8. changes: a card first, Confirm runs it through the same door as the screen
create temp table ug_a (k text primary key, id uuid);
grant all on ug_a to public;
insert into ug_a select 'task', (app.assistant_propose(test.id('ug_admin'), '{"portal": "admin", "tool": "create_task", "name": "task_create", "args": {"title": "Call Rita back about the deposit", "queue": "cs", "priority": "high"}, "summary": "Add the task \"Call Rita back about the deposit\" to the cs queue, high priority?"}') ->> 'id')::uuid;
select test.eq('a proposed change is a card: nothing has run', (select count(*) from tasks where title = 'Call Rita back about the deposit'), 0::bigint);
select test.eq('stored with the door and function the screen uses', (select call || ' ' || name || ' ' || status from assistant_actions where id = (select id from ug_a where k = 'task')), 'ops_do task_create proposed');
select test.throws('only the person who asked can confirm it', $$select app.assistant_confirm(test.id('ug_admin2'), '', jsonb_build_object('id', (select id from ug_a where k = 'task')))$$, 'not found');
select test.eq('Confirm: it runs', (app.door(test.id('ug_admin'), '', 'ops_do', 'assistant_confirm', jsonb_build_object('id', (select id from ug_a where k = 'task'))) ->> 'ok')::boolean, true);
select test.eq('the task is in the cs queue, created by the Admin', (select queue || ' ' || priority || ' ' || (created_by = test.id('ug_admin'))::text from tasks where title = 'Call Rita back about the deposit'), 'cs high true');
select test.eq('the audit log: the staff member as actor, "via assistant"',
  (select actor_user_id = test.id('ug_admin') and after ->> 'note' = 'via assistant' and after ->> 'tool' = 'create_task' from audit_log where action = 'assistant_action' and entity_id = (select id::text from ug_a where k = 'task')), true);
select test.eq('every audit row written by the action is marked "via assistant"',
  (select count(*) from audit_log where entity_table = 'assistant_actions' and entity_id = (select id::text from ug_a where k = 'task') and action = 'UPDATE' and request_id = 'via assistant'), 1::bigint);
select test.eq('and nothing outside it is', (select count(*) from audit_log where request_id = 'via assistant' and at < (select created_at from assistant_actions where id = (select id from ug_a where k = 'task'))), 0::bigint);
select test.throws('a card runs once', $$select app.assistant_confirm(test.id('ug_admin'), '', jsonb_build_object('id', (select id from ug_a where k = 'task')))$$, 'already done');

-- a VA cannot do an Admin's action through the assistant
select test.throws('an assistant proposing in the Admin portal is refused', $$select app.assistant_propose(test.id('ug_cs'), '{"portal": "admin", "tool": "publish_car", "name": "listing_publish_now", "args": {}, "summary": "Publish?"}')$$, 'Only an Admin');
select test.throws('an action that is not one of the assistant''s is refused (no Admin settings through it)', $$select app.assistant_propose(test.id('ug_cs'), '{"portal": "va", "tool": "publish_car", "name": "usage_decide", "args": {}, "summary": "Allow paid usage?"}')$$, 'cannot do that here');
select test.throws('field staff cannot create tasks or publish through it', $$select app.assistant_propose(test.id('ug_field'), '{"portal": "field", "tool": "publish_car", "name": "listing_publish_now", "args": {}, "summary": "Publish?"}')$$, 'cannot do that here');
insert into ug_a select 'toll', (app.assistant_propose(test.id('ug_cs'), '{"portal": "va", "tool": "confirm_toll", "name": "toll_confirm", "args": {"id": "00000000-0000-0000-0000-000000000000"}, "summary": "Confirm the match of notice N1?"}') ->> 'id')::uuid;
select test.eq('it goes through the assistant''s door (va_do), with the function', (select call || ' ' || (args ->> '_va') from assistant_actions where id = (select id from ug_a where k = 'toll')), 'va_do cs');
select test.eq('Confirm: the database refuses what customer service may not do, as on the screen', (app.assistant_confirm(test.id('ug_cs'), '', jsonb_build_object('id', (select id from ug_a where k = 'toll'))) ->> 'ok')::boolean, false);
select test.eq('the card is marked failed with the reason, and audited', (select status from assistant_actions where id = (select id from ug_a where k = 'toll')) || ' ' ||
  (select count(*) from audit_log where action = 'assistant_action_failed' and actor_user_id = test.id('ug_cs'))::text, 'failed 1');
select test.throws('an assistant files a task in their own queue or the Admins'' only', $$select app.task_create(test.id('ug_cs'), '{"title": "Check the books", "queue": "finance"}')$$, 'own queue');
select test.lives('their own queue is fine', $$select app.task_create(test.id('ug_cs'), '{"title": "Call back", "queue": "cs"}')$$);
select test.throws('field staff do not file tasks this way', $$select app.task_create(test.id('ug_field'), '{"title": "Check tires", "queue": "fleet"}')$$, 'Admin or an assistant');

-- Cancel, and an old card
insert into ug_a select 'cancel', (app.assistant_propose(test.id('ug_admin'), '{"portal": "admin", "tool": "create_task", "name": "task_create", "args": {"title": "Never made"}, "summary": "Add the task?"}') ->> 'id')::uuid;
select test.lives('Cancel', $$select app.assistant_cancel(test.id('ug_admin'), jsonb_build_object('id', (select id from ug_a where k = 'cancel')))$$);
select test.throws('a cancelled card does not run', $$select app.assistant_confirm(test.id('ug_admin'), '', jsonb_build_object('id', (select id from ug_a where k = 'cancel')))$$, 'already cancelled');
insert into ug_a select 'old', (app.assistant_propose(test.id('ug_admin'), '{"portal": "admin", "tool": "create_task", "name": "task_create", "args": {"title": "Too old"}, "summary": "Add the task?"}') ->> 'id')::uuid;
update assistant_actions set created_at = now() - interval '2 hours' where id = (select id from ug_a where k = 'old');
select test.eq('a card older than 30 minutes is not run', (app.assistant_confirm(test.id('ug_admin'), '', jsonb_build_object('id', (select id from ug_a where k = 'old'))) ->> 'ok')::boolean, false);
select test.eq('nothing ran', (select count(*) from tasks where title in ('Never made', 'Too old')), 0::bigint);

-- ================================================================ 9. Claude: US$0 included, asks before spending
select test.eq('Claude before any key: not shown as used up', app.usage_state('claude') ->> 'state', 'ok');
select test.eq('the first call: its gate is closed until an Admin allows a budget', (app.usage_gate('claude') ->> 'ok')::boolean, false);
select test.eq('and the Admin is asked at once', exists (select 1 from usage_alerts where service = 'claude' and level = 100), true);
select test.eq('allowed up to US$2 today', app.usage_decide(test.id('ug_admin'), '{"service": "claude", "decision": "allow", "until": "day", "cap_usd": 2}') ->> 'state', 'paid');
select test.eq('the gate opens', (app.usage_gate('claude') ->> 'ok')::boolean, true);
select test.lives('a Claude call is recorded in micro-dollars', $$select app.usage_call_record('{"provider": "anthropic:claude-haiku-4-5", "units": 2500000, "unit": "microusd"}')$$);
select test.eq('US$2.50 spent: past the cap, paused', app.usage_gate('claude') ->> 'state', 'paused');
select test.eq('Claude''s cost never spends the photo budget', (app.listing_budget() ->> 'photo_spent_microusd')::bigint, 0::bigint);

-- ================================================================ 10. the photo retry once transformations may be used
select test.eq('nothing to retry while paused or without fallbacks', app.usage_retry_photos(), 0);
select test.eq('the hourly job reports every state', (select count(*) from jsonb_object_keys(app.job_usage_refresh() -> 'states')), 12::bigint);
