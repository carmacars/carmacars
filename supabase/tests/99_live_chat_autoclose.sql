-- 99: live chat fix (migration 0370). The AI budget's live share, live chat's gate and its reason, the counts (chats that
-- need a reply), one alert per visitor message waiting for staff (to the person on the chat when there is one, cleared
-- by a reply), staff notes the visitor never sees, auto-close of a visitor who left without contact, the follow-up of
-- one who left a phone or email, and the chat reopening when the visitor comes back. Fixtures start with "lc7".
select test.suite('99 live chat ai, counts, alerts, auto-close');

select test.mk_user('lc7_admin', 'admin');
select test.mk_user('lc7_cs', 'va', 'cs');
select test.mk_user('lc7_fin', 'va', 'finance');

create temp table s370 as select null::text as k, null::jsonb as v limit 0;
grant all on s370 to public;
create or replace function test.s370(p_k text) returns jsonb language sql stable as $$ select v from pg_temp.s370 where k = p_k $$;
create or replace function test.lc7_vid(p text) returns uuid language sql immutable as $$ select md5('lc7-vid:' || p)::uuid $$;
create or replace function test.lc7_sid(p text) returns uuid language sql immutable as $$ select md5('lc7-sid:' || p)::uuid $$;
create or replace function test.lc7_open(p text) returns text language sql as $$
  select app.server_chat_open(jsonb_build_object('vid', test.lc7_vid(p), 'sid', test.lc7_sid(p), 'page', '/cars')) ->> 'token' $$;
create or replace function test.lc7_conv(p_token text) returns chat_conversations language sql stable as $$ select * from chat_conversations where token = p_token $$;
create or replace function test.lc7_waiting() returns integer language sql stable as $$ select (app.chat_counts_now(null) ->> 'waiting')::integer $$;
create or replace function test.lc7_alerts(p_token text) returns bigint language sql stable as $$
  select count(*) from app_events e where e.code = 'staff_chat_message' and e.entity_id = (test.lc7_conv(p_token)).id $$;
-- a visitor gone for 20 minutes: nothing seen of them since
create or replace function test.lc7_age(p_token text) returns void language sql as $$
  update chat_messages set at = at - interval '20 minutes' where conversation_id = (test.lc7_conv(p_token)).id;
  update visitor_sessions set last_seen_at = now() - interval '20 minutes', started_at = now() - interval '25 minutes'
   where visitor_id = (test.lc7_conv(p_token)).visitor_id;
  update chat_conversations set created_at = now() - interval '25 minutes', last_message_at = now() - interval '20 minutes',
         last_visitor_at = now() - interval '20 minutes', visitor_seen_at = null, reopened_at = null, human_requested_at = now() - interval '20 minutes'
   where token = p_token;
$$;

-- ================================================================ 1. settings and the AI budget
select test.eq('defaults: AI replies on, the small model, visitor gone after 10 minutes; the assistant keeps 30%, live 50%, background 10%',
  (select format('%s %s %s %s/%s/%s', chat_ai_enabled, chat_ai_model, chat_auto_close_minutes, ai_assistant_reserve_bps, ai_live_bps, ai_background_bps) from (select (app.settings()).*) s),
  't @cf/meta/llama-3.1-8b-instruct-fp8-fast 10 3000/5000/1000');
-- a quiet day far away: nothing recorded on it
select test.eq('a fresh day: the assistant all of it, live 5,000, background 1,000',
  (select (b #>> '{room,assistant}') || '/' || (b #>> '{room,live}') || '/' || (b #>> '{room,background}') from (select app.ai_budget('2031-03-04 17:00Z') b) x), '10000/5000/1000');
insert into provider_calls (provider, purpose, ok, units, unit, created_at) values ('workers-ai', 'guide_rewrite', true, 900, 'neurons', '2031-03-04 15:00Z');
select test.eq('background spent 900: live keeps its 5,000 (it was what the 70% reserve and background left)',
  (select (b #>> '{room,live}') || '/' || (b #>> '{room,background}') from (select app.ai_budget('2031-03-04 17:00Z') b) x), '5000/100');
insert into provider_calls (provider, purpose, ok, units, unit, created_at) values ('workers-ai', 'chat', true, 4900, 'neurons', '2031-03-04 16:00Z');
select test.eq('live used 4,900 of its 5,000: 100 left; background never had it', (app.ai_budget('2031-03-04 17:00Z') #>> '{room,live}'), '100');
select test.eq('a chat reply (about 60 neurons) still fits', (app.ai_allow('chat', 60, '2031-03-04 17:00Z') ->> 'ok')::boolean, true);
select test.throws('the three shares fit in 100%', $$select app.ai_shares_save(test.id('lc7_admin'), '{"reserve_bps": 3000, "live_bps": 6000, "background_bps": 2000}')$$, 'more than 100%');
select test.eq('an Admin sets the live share; empty is "what is not reserved"',
  (select coalesce(b ->> 'live_bps', 'none') from (select app.ai_shares_save(test.id('lc7_admin'), '{"live_bps": ""}') b) x)
  || '/' || (select b ->> 'live_bps' from (select app.ai_shares_save(test.id('lc7_admin'), '{"live_bps": 5000}') b) x), 'none/5000');

-- ================================================================ 2. the chat's gate says why
select test.lc7_open('off') as t \gset off_
update program_settings set chat_ai_enabled = false;
select test.eq('AI off: the message is not for the assistant, and the reason says so',
  (select (r ->> 'ai') || ' ' || (r ->> 'ai_reason') || ' ' || (r ->> 'reason' like '%turned off%')::text from (select app.server_chat_visitor_message(:'off_t', 'Hi there') r) x), 'false budget true');
select test.eq('Live chat says "AI replies paused" with the reason', (app.chat_ai_status() ->> 'on') || ' ' || (app.chat_ai_status() ->> 'reason' like '%turned off%')::text, 'false true');
update program_settings set chat_ai_enabled = true;
select test.eq('on again', (app.chat_budget() ->> 'ai_enabled'), 'true');
-- a failed reply pauses the line until a good one
select app.server_chat_ai_reply(:'off_t', '{"body": null, "neurons": 0, "model": "@cf/meta/llama-3.1-8b-instruct-fp8-fast", "ok": false, "error": "unavailable: 5007 no such model"}');
select test.eq('a failed reply: "AI replies paused: the last reply failed: ..."',
  (select (s ->> 'on') || ' ' || (s ->> 'reason' like 'the last reply failed: unavailable: 5007%')::text from (select app.chat_ai_status() s) x), 'false true');
select app.server_chat_ai_reply(:'off_t', '{"body": null, "neurons": 0, "model": "faq", "ok": true}');
select test.eq('the next good reply turns it back on', case when (app.chat_budget() ->> 'ok')::boolean then app.chat_ai_status() ->> 'on' else 'true' end, 'true');

-- ================================================================ 3. staff notes
select app.server_chat_staff_note(:'off_t', 'The assistant could not reply. Please answer the visitor.');
select test.eq('a staff note: staff read it in the thread', exists (select 1 from jsonb_array_elements(app.chat_messages_json((test.lc7_conv(:'off_t')).id, 0, true)) m
  where m ->> 'body' like 'The assistant could not reply%' and (m #>> '{meta,staff_only}') = 'true'), true);
select test.eq('the visitor never sees it', exists (select 1 from jsonb_array_elements(public.chat_poll(:'off_t', 0) -> 'messages') m where m ->> 'body' like 'The assistant could not reply%'), false);
select app.server_chat_end(:'off_t');

-- ================================================================ 4. the counts and the alerts
insert into pg_temp.s370 values ('w0', to_jsonb(test.lc7_waiting()));
select test.lc7_open('a') as t \gset a_
select app.server_chat_visitor_message(:'a_t', 'Is the Corolla free this weekend?');
select test.eq('the assistant has it: no reply needed from staff, no alert', format('%s %s', test.lc7_waiting() - (test.s370('w0'))::integer, test.lc7_alerts(:'a_t')), '0 0');
select app.server_chat_handoff(:'a_t', 'asked for a person');
select test.eq('handed to a person: one chat needs a reply, one alert (on shift or not)', format('%s %s', test.lc7_waiting() - (test.s370('w0'))::integer, test.lc7_alerts(:'a_t')), '1 1');
select app.server_chat_handoff(:'a_t', 'asked for a person');
select test.eq('asking again does not alert again', test.lc7_alerts(:'a_t'), 1::bigint);
select app.server_chat_visitor_message(:'a_t', 'Hello? Anyone there?');
select test.eq('a new message while it waits: one more alert, still one chat', format('%s %s', test.lc7_waiting() - (test.s370('w0'))::integer, test.lc7_alerts(:'a_t')), '1 2');
select test.eq('the menu''s badge (door chat_counts) is the inbox''s count',
  (app.door(test.id('lc7_admin'), 'aal2', 'admin_read', 'chat_counts') ->> 'waiting') = (app.chat_inbox(test.id('lc7_admin')) ->> 'waiting'), true);
select test.eq('and both are the chats that need a reply', (app.door(test.id('lc7_admin'), 'aal2', 'admin_read', 'chat_counts') ->> 'waiting')::integer, test.lc7_waiting());
select app.process_events();
select test.eq('in-app alerts: customer service and the Admin, not finance',
  (select string_agg(distinct n.user_id::text, ',' order by n.user_id::text) from notifications n where n.code = 'staff_chat_message' and n.entity_id = (test.lc7_conv(:'a_t')).id
     and n.user_id in (test.id('lc7_admin'), test.id('lc7_cs'), test.id('lc7_fin'))),
  (select string_agg(x::text, ',' order by x::text) from unnest(array[test.id('lc7_admin'), test.id('lc7_cs')]) x));
select test.eq('the alert names the chat and quotes the message',
  (select n.title like 'Live chat LC-%' and n.body = 'Hello? Anyone there?' from notifications n join app_events e on e.id = n.event_id
    where n.code = 'staff_chat_message' and n.user_id = test.id('lc7_cs')
      and e.payload ->> 'message_id' = (select max(m.id)::text from chat_messages m where m.conversation_id = (test.lc7_conv(:'a_t')).id and m.sender = 'visitor')), true);
select app.chat_staff_do(test.id('lc7_cs'), 'chat_reply', jsonb_build_object('id', (test.lc7_conv(:'a_t')).id, 'body', 'Hi, I can help.'));
select test.eq('a reply: nothing needs a reply, the alerts are read (no late push)',
  format('%s %s', test.lc7_waiting() - (test.s370('w0'))::integer,
         (select count(*) from notifications n where n.code = 'staff_chat_message' and n.entity_id = (test.lc7_conv(:'a_t')).id and n.read_at is null)), '0 0');
select app.server_chat_visitor_message(:'a_t', 'Great, the weekend please');
select test.eq('the visitor writes back to the person: it needs a reply again, one alert', format('%s %s', test.lc7_waiting() - (test.s370('w0'))::integer, test.lc7_alerts(:'a_t')), '1 3');
select app.process_events();
select test.eq('the person on the chat gets it, nobody else',
  (select string_agg(n.user_id::text, ',') from notifications n join app_events e on e.id = n.event_id
    where n.code = 'staff_chat_message' and e.payload ->> 'message_id' = (select max(m.id)::text from chat_messages m where m.conversation_id = (test.lc7_conv(:'a_t')).id and m.sender = 'visitor')
      and n.user_id in (test.id('lc7_admin'), test.id('lc7_cs'), test.id('lc7_fin'))), test.id('lc7_cs')::text);
select test.eq('the inbox row says it needs a reply', (select (r ->> 'needs_reply')::boolean from jsonb_array_elements(app.chat_inbox(test.id('lc7_cs')) -> 'open') r where r ->> 'id' = (test.lc7_conv(:'a_t')).id::text), true);

-- ================================================================ 5. the visitor left without contact: closed
select test.lc7_open('gone') as t \gset g_
select app.server_chat_visitor_message(:'g_t', 'how much for a week');
select app.server_chat_handoff(:'g_t', 'asked for a person');
select app.job_chat_auto_close();
select test.eq('still here (seen now): the job leaves it', (test.lc7_conv(:'g_t')).status, 'waiting');
-- counted after that first run, which also closes any chat an earlier file left behind
insert into pg_temp.s370 values ('w1', to_jsonb(test.lc7_waiting()));
select test.lc7_age(:'g_t');
select app.job_chat_auto_close();
select test.eq('gone 20 minutes, no phone or email: closed, "Visitor left, no contact"',
  (select format('%s %s %s', c.status, c.closed_reason, c.status_before_close) from chat_conversations c where c.token = :'g_t'), 'closed visitor_left waiting');
select test.eq('out of the count', test.lc7_waiting(), (test.s370('w1'))::integer - 1);
select test.eq('its task is cancelled', (select t.status from tasks t where t.id = (test.lc7_conv(:'g_t')).task_id), 'cancelled');
select test.eq('staff see why in the chat', exists (select 1 from chat_messages m where m.conversation_id = (test.lc7_conv(:'g_t')).id and m.body like 'Visitor left, no contact%' and (m.meta ->> 'staff_only') = 'true'), true);
-- the visitor comes back: their browser polls the chat
select test.eq('back on the site: the chat opens again, waiting for a person', (public.chat_poll(:'g_t', 0) ->> 'status'), 'waiting');
select test.eq('reopened, counted again', format('%s %s', ((test.lc7_conv(:'g_t')).closed_reason is null)::text, (test.lc7_waiting() = (test.s370('w1'))::integer)::text), 'true true');
-- an assistant chat that was never handed over reopens with the assistant
select test.lc7_open('gone_ai') as t \gset ga_
select app.server_chat_visitor_message(:'ga_t', 'hi');
select test.lc7_age(:'ga_t');
select app.job_chat_auto_close();
select test.eq('an assistant chat closes too', (test.lc7_conv(:'ga_t')).status, 'closed');
select app.server_chat_open(jsonb_build_object('vid', test.lc7_vid('gone_ai'), 'sid', test.lc7_sid('gone_ai'), 'page', '/')) ->> 'token' as t \gset ga2_
select test.eq('and reopens with the assistant when the visitor opens the chat again (a new tab, no token): the same chat',
  (test.lc7_conv(:'ga_t')).status || ' ' || ((test.lc7_conv(:'ga_t')).reopened_at is not null)::text || ' ' || (:'ga2_t' = :'ga_t')::text, 'ai true true');

-- ================================================================ 6. the visitor left a phone or email: follow-up
select test.lc7_open('lead') as t \gset l_
select app.server_chat_visitor_message(:'l_t', 'Can someone call me back? lc7.maya@example.test 416-555-0142');
select test.eq('contact typed in the message is kept on the chat', (select c.email || ' ' || c.phone from chat_conversations c where c.token = :'l_t'), 'lc7.maya@example.test 4165550142');
select app.server_chat_handoff(:'l_t', 'asked for a person');
insert into pg_temp.s370 values ('w2', to_jsonb(test.lc7_waiting()));
insert into pg_temp.s370 values ('f2', app.chat_counts_now(null) -> 'followup');
select test.lc7_age(:'l_t');
select app.job_chat_auto_close();
select test.eq('gone with an email and a phone: still open, a follow-up', (select format('%s %s', c.status, (c.followup_at is not null)::text) from chat_conversations c where c.token = :'l_t'), 'waiting true');
select test.eq('out of the reply count, in the follow-ups', format('%s %s', (test.lc7_waiting() = (test.s370('w2'))::integer - 1)::text,
  ((app.chat_counts_now(null) ->> 'followup')::integer = (test.s370('f2'))::integer + 1)::text), 'true true');
select test.eq('customer service''s task "Follow up by text/email"',
  (select format('%s|%s|%s', t.task_type, t.queue, (t.title like 'Follow up by text/email:%')::text) from tasks t where t.id = (test.lc7_conv(:'l_t')).followup_task_id), 'chat_contact|cs|true');
select test.eq('the inbox row shows the follow-up and does not need a reply',
  (select (r ->> 'followup_at' is not null)::text || ' ' || (r ->> 'needs_reply') from jsonb_array_elements(app.chat_inbox(test.id('lc7_cs')) -> 'open') r where r ->> 'id' = (test.lc7_conv(:'l_t')).id::text), 'true false');
select test.eq('a follow-up raises no alert', app.chat_alert((test.lc7_conv(:'l_t')).id, 999999999), false);
select app.job_chat_auto_close();
select test.eq('the job leaves a follow-up alone (one task)', (select count(*) from tasks t where t.related_id = (test.lc7_conv(:'l_t')).id and t.task_type = 'chat_contact' and t.title like 'Follow up%'), 1::bigint);
select public.chat_poll(:'l_t', 0);
select test.eq('they come back: a live chat again, counted', format('%s %s', ((test.lc7_conv(:'l_t')).followup_at is null)::text, (test.lc7_waiting() = (test.s370('w2'))::integer)::text), 'true true');

-- ================================================================ 7. privileges
select test.eq('anon polls the chat; the new server functions are the server''s only',
  has_function_privilege('anon', 'public.chat_poll(text, bigint)', 'execute')::text || has_function_privilege('anon', 'public.server_chat_staff_note(text, text)', 'execute')::text
  || has_function_privilege('authenticated', 'app.job_chat_auto_close(timestamptz)', 'execute')::text, 'truefalsefalse');

select app.ai_shares_save(test.id('lc7_admin'), '{"reserve_bps": 3000, "live_bps": 5000, "background_bps": 1000}');

-- leave nothing waiting for the suites after this one: alerts processed, these chats closed, their notices read
select app.process_events();
select app.chat_close(c.id, null) from chat_conversations c where c.visitor_id in (select test.lc7_vid(x) from unnest(array['off', 'a', 'gone', 'gone_ai', 'lead']) x) and c.status <> 'closed';
update notifications set read_at = now() where code = 'staff_chat_message' and read_at is null;
