-- 99: R50 hotfix 2 UX (5150; docs/changes/2026-11-27-r50h2-ux.md). The weekly Admin call: Sunday 7 pm Toronto by default,
-- the weekly invite (.ics) to every Admin and its update when the time changes, the deck built by the job with its 14
-- sections, Approve and Deny in place (a shift claim taken off, a To do closed, a money action approved but never done),
-- once per item, Admins only, the call room for Admins only, the alert an hour before. Fixtures "r5ac".
select test.suite('99 r50 hotfix 2 UX: the weekly Admin call');
select test.mk_user('r5ac_admin', 'admin');
select test.mk_user('r5ac_boss', 'admin');
select test.mk_user('r5ac_field', 'field');
select test.mk_user('r5ac_cs', 'va', 'cs');
create function test.r5ac(p_user text, p_call text, p_name text, p jsonb) returns jsonb language sql as $$ select app.door(test.id(p_user), 'aal2', p_call, p_name, p) $$;
update app_events set processed_at = now(), process_note = 'test: left by an earlier file' where processed_at is null;

-- ================================================================ 1. when: Sunday 7 pm Toronto
select test.eq('the default day is Sunday', (app.settings()).admin_call_weekday, 7);
select test.eq('at 19:00', (app.settings()).admin_call_time, '19:00');
select test.eq('the next call is on a Sunday', extract(isodow from app.admin_call_next(now()) at time zone 'America/Toronto')::int, 7);
select test.eq('at 7 pm Toronto time', to_char(app.admin_call_next(now()) at time zone 'America/Toronto', 'HH24:MI'), '19:00');

-- ================================================================ 2. the weekly invite
select app.admin_call_invites_sweep(now());
select test.eq('each Admin has the weekly invite', (select count(distinct user_id) from calendar_invites where kind = 'admin_call' and method = 'REQUEST' and user_id in (test.id('r5ac_admin'), test.id('r5ac_boss'))), 2::bigint);
select test.eq('staff do not', (select count(*) from calendar_invites where kind = 'admin_call' and user_id in (test.id('r5ac_field'), test.id('r5ac_cs'))), 0::bigint);
select test.ok('it repeats every Sunday', (select rrule from calendar_invites where kind = 'admin_call' and user_id = test.id('r5ac_admin') order by seq desc limit 1) = 'FREQ=WEEKLY;BYDAY=SU');
select test.eq('a second sweep sends nothing new', app.admin_call_invites_sweep(now()), 0);
select app.process_events();
select test.ok('the email carries the .ics under its own name',
  (select app.outbox_inline_files(o.id) #>> '{0,filename}' from notification_outbox o where o.code = 'admin_call_invite' and o.recipient_user_id = test.id('r5ac_admin') order by o.created_at desc limit 1) = 'carmacars-admin-call.ics'
  and (select app.outbox_inline_files(o.id) #>> '{0,content}' from notification_outbox o where o.code = 'admin_call_invite' and o.recipient_user_id = test.id('r5ac_admin') order by o.created_at desc limit 1) like 'BEGIN:VCALENDAR%METHOD:REQUEST%UID:admin-call@carmacars.ca%');
select test.ok('the Add to calendar file is the same event', (test.r5ac('r5ac_admin', 'admin_read', 'admin_call_ics', '{}') ->> 'ics') like '%METHOD:PUBLISH%UID:admin-call@carmacars.ca%');

-- the day and time change in Settings: the invite is updated at once
select test.r5ac('r5ac_admin', 'admin_do', 'admin_call_schedule', '{"weekday":"1","time":"18:30","minutes":"45"}');
select test.eq('Monday now', (select rrule from calendar_invites where kind = 'admin_call' and user_id = test.id('r5ac_boss') order by seq desc limit 1), 'FREQ=WEEKLY;BYDAY=MO');
select test.eq('as an update (SEQUENCE 1)', (select max(seq) from calendar_invites where kind = 'admin_call' and user_id = test.id('r5ac_boss')), 1);
select test.throws('a time that is not HH:MM is refused', $$select test.r5ac('r5ac_admin', 'admin_do', 'admin_call_schedule', '{"weekday":"1","time":"7pm"}')$$, '%HH:MM%');
select test.throws('staff cannot change it', $$select test.r5ac('r5ac_cs', 'admin_do', 'admin_call_schedule', '{"weekday":"2","time":"10:00"}')$$);
select test.r5ac('r5ac_admin', 'admin_do', 'admin_call_schedule', '{"weekday":"7","time":"19:00","minutes":"60"}');

-- no longer an Admin: the series is cancelled
delete from user_roles where user_id = test.id('r5ac_boss') and role = 'admin';
select app.admin_call_invites_sweep(now());
select test.eq('a former Admin gets the cancellation', (select method from calendar_invites where kind = 'admin_call' and user_id = test.id('r5ac_boss') order by seq desc limit 1), 'CANCEL');
select app.process_events();
select test.ok('and the cancellation email (07 leaves it to this file)', exists (select 1 from notification_outbox o where o.code = 'admin_call_cancelled' and o.recipient_user_id = test.id('r5ac_boss')));
insert into user_roles (user_id, role) values (test.id('r5ac_boss'), 'admin');

-- ================================================================ 3. the deck
create temp table r5ac_at as select app.admin_call_next(now()) at;
insert into field_shift_slots (id, starts_at, ends_at, capacity) select test.id('r5ac_slot'), at + interval '2 days', at + interval '2 days 8 hours', 2 from r5ac_at;
insert into field_shift_plans (id, slot_id, staff_id, starts_at, ends_at) select test.id('r5ac_plan'), test.id('r5ac_slot'), test.id('r5ac_field'), at + interval '2 days', at + interval '2 days 8 hours' from r5ac_at;
-- the deck lists the 20 most urgent Admin To dos: those another file left open must not crowd out this file's (REQ-117)
update tasks set status = 'done', completed_at = now(), completion_note = 'closed by a test file' where queue = 'admin' and status in ('open', 'in_progress', 'waiting');
select app.raise_task(p_type => 'r5ac_decision', p_title => 'R5ac: choose the new insurer', p_dedupe => 'r5ac:todo', p_queue => 'admin', p_priority => 'high');
select app.raise_task(p_type => 'api_prepared_money', p_title => 'R5ac: refund of $40.00', p_dedupe => 'r5ac:money', p_queue => 'admin', p_priority => 'high');
select app.raise_task(p_type => 'r5ac_other', p_title => 'R5ac: second decision', p_dedupe => 'r5ac:todo2', p_queue => 'admin');

-- the job builds it in the day before, then alerts an hour before
select app.job_admin_call((select at from r5ac_at) - interval '20 hours');
select test.eq('the job built this week''s deck', (select count(*) from admin_call_decks where week_of = app.admin_call_week((select at from r5ac_at))), 1::bigint);
select test.eq('with the 14 sections', (select array_agg(x ->> 'key' order by o) from admin_call_decks d, jsonb_array_elements(d.slides) with ordinality t(x, o) where d.week_of = app.admin_call_week((select at from r5ac_at))),
  array['shifts', 'hours', 'academy', 'hiring', 'social', 'numbers', 'owners', 'deposits', 'insurance', 'claims', 'money', 'tolls', 'fleet', 'todos']);
create temp table r5ac_deck as select * from admin_call_decks where week_of = app.admin_call_week((select at from r5ac_at));
create function test.r5ac_items(p_kind text) returns setof jsonb language sql as $$
  select i from r5ac_deck d, jsonb_array_elements(d.slides) x, jsonb_array_elements(coalesce(x -> 'items', '[]'::jsonb)) i where i ->> 'kind' = p_kind $$;
select test.ok('the shift claim is on it, with its person', exists (select 1 from test.r5ac_items('shift') i where i ->> 'key' = 'shift:' || test.id('r5ac_plan') and i ->> 'label' = 'R5ac Field'));
select test.ok('the To do needing a decision', exists (select 1 from test.r5ac_items('todo') i where i ->> 'label' = 'R5ac: choose the new insurer'));
select test.ok('the prepared money action, not in the To dos', exists (select 1 from test.r5ac_items('money') i where i ->> 'label' = 'R5ac: refund of $40.00')
  and not exists (select 1 from test.r5ac_items('todo') i where i ->> 'label' = 'R5ac: refund of $40.00'));
select test.eq('not rebuilt early again', (select app.job_admin_call((select at from r5ac_at) - interval '10 hours')) like '%built f%', true);
select app.job_admin_call((select at from r5ac_at) - interval '2 hours');
select test.ok('built again in the three hours before', (select built_at from admin_call_decks where id = (select id from r5ac_deck)) > (select built_at from r5ac_deck));
select app.job_admin_call((select at from r5ac_at) - interval '45 minutes');
select test.ok('the Admins are alerted an hour before', (select reminded_at is not null from admin_call_decks where id = (select id from r5ac_deck)));

-- ================================================================ 4. Approve and Deny in place
select test.throws('staff cannot read the deck', $$select test.r5ac('r5ac_cs', 'admin_read', 'admin_call', '{}')$$);
select test.throws('staff cannot decide', format($$select test.r5ac('r5ac_cs', 'admin_do', 'admin_call_decide', '{"deck":"%s","key":"todo:%s","decision":"deny"}')$$,
  (select id from r5ac_deck), (select id from tasks where dedupe_key = 'r5ac:todo')));
select test.r5ac('r5ac_admin', 'admin_do', 'admin_call_decide', jsonb_build_object('deck', (select id from r5ac_deck), 'key', 'todo:' || (select id from tasks where dedupe_key = 'r5ac:todo'), 'decision', 'deny', 'note', 'Keep the one we have'));
select test.eq('a To do denied is closed', (select status from tasks where dedupe_key = 'r5ac:todo'), 'done');
select test.ok('with the reason', (select completion_note from tasks where dedupe_key = 'r5ac:todo') = 'Declined in the Admin call: Keep the one we have');
select test.r5ac('r5ac_boss', 'admin_do', 'admin_call_decide', jsonb_build_object('deck', (select id from r5ac_deck), 'key', 'money:' || (select id from tasks where dedupe_key = 'r5ac:money'), 'decision', 'approve'));
select test.eq('a money action approved stays open: no money moves here', (select status from tasks where dedupe_key = 'r5ac:money'), 'open');
select test.ok('marked approved and urgent', (select priority = 'urgent' and detail like '%Approved in the Admin call%no money moved yet%' from tasks where dedupe_key = 'r5ac:money'));
select test.r5ac('r5ac_admin', 'admin_do', 'admin_call_decide', jsonb_build_object('deck', (select id from r5ac_deck), 'key', 'shift:' || test.id('r5ac_plan'), 'decision', 'deny'));
select test.ok('a shift claim denied is taken off the shift', (select cancelled_at is not null and cancel_reason = 'Taken off in the Admin call' from field_shift_plans where id = test.id('r5ac_plan')));
select test.throws('each item is decided once', format($$select test.r5ac('r5ac_boss', 'admin_do', 'admin_call_decide', '{"deck":"%s","key":"shift:%s","decision":"approve"}')$$,
  (select id from r5ac_deck), test.id('r5ac_plan')), '%Already decided%');
select test.throws('only an item of the deck', format($$select test.r5ac('r5ac_admin', 'admin_do', 'admin_call_decide', '{"deck":"%s","key":"todo:%s","decision":"approve"}')$$,
  (select id from r5ac_deck), gen_random_uuid()), '%not on this deck%');
select test.ok('the page shows each decision with who took it',
  (select i ->> 'decision' = 'deny' and i ->> 'decided_by' = 'R5ac Admin' from jsonb_array_elements(test.r5ac('r5ac_admin', 'admin_read', 'admin_call', '{}') #> '{deck,slides}') x,
     jsonb_array_elements(x -> 'items') i where i ->> 'key' = 'shift:' || test.id('r5ac_plan')));
select test.r5ac('r5ac_admin', 'admin_do', 'admin_call_note', jsonb_build_object('deck', (select id from r5ac_deck), 'key', 'numbers', 'note', 'Push the airport page'));
select test.eq('a note on a slide', (select x ->> 'note' from jsonb_array_elements(test.r5ac('r5ac_admin', 'admin_read', 'admin_call', '{}') #> '{deck,slides}') x where x ->> 'key' = 'numbers'), 'Push the airport page');

-- ================================================================ 5. the call room: Admins only
select test.eq('an Admin joins the Admin call as presenter', test.r5ac('r5ac_admin', 'admin_read', 'call_join', '{"room":"admin_call"}') ->> 'role', 'presenter');
select test.ok('in its own room', (test.r5ac('r5ac_admin', 'admin_read', 'call_join', '{"room":"admin_call"}') ->> 'room') like 'admin-call-%');
select test.throws('staff cannot join it', $$select test.r5ac('r5ac_field', 'ops_read', 'call_join', '{"room":"admin_call"}')$$, '%Admins%');
select test.ok('the townhall room is unchanged', test.r5ac('r5ac_admin', 'admin_read', 'call_join', '{"room":"townhall"}') ->> 'kind' = 'townhall');
