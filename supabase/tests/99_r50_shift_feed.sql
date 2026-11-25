-- 99: field shifts in Google Calendar by subscription (migration 5050, docs/changes/2026-11-25-r50-shift-feed.md): who
-- gets which feed, the token (64 random hex characters, revocable, regenerable), the calendar text (Toronto time with
-- VTIMEZONE, who claimed it or Open, the tasks, the link, 14 days back to 60 ahead), a field person's own feed, the door.
-- Fixtures "sfd_".
select test.suite('99 r50 shift feed: private iCal of field shifts for Admin, Fleet and field staff');
select test.mk_user('sfd_admin', 'admin');
select test.mk_user('sfd_fleet', 'va', 'fleet');
select test.mk_user('sfd_sales', 'va', 'sales');
select test.mk_user('sfd_field', 'field');
select test.mk_user('sfd_field2', 'field');
update staff_profiles set functions = array['fleet'] where user_id = test.id('sfd_fleet') and not ('fleet' = any (coalesce(functions, '{}')));
update staff_profiles set functions = array['sales'] where user_id = test.id('sfd_sales') and not ('sales' = any (coalesce(functions, '{}')));

-- ================================================================ who may have which feed
select test.eq('an Admin gets every shift', app.shift_feed_scopes(test.id('sfd_admin')), array['all']);
select test.eq('Fleet gets every shift', app.shift_feed_scopes(test.id('sfd_fleet')), array['all']);
select test.eq('a field person gets their own', app.shift_feed_scopes(test.id('sfd_field')), array['mine']);
select test.eq('Sales gets none', cardinality(app.shift_feed_scopes(test.id('sfd_sales'))), 0);
select test.throws('Sales cannot read a feed', $$select app.shift_feed_state(test.id('sfd_sales'))$$, '%Only Admins, Fleet and field staff%');
select test.throws('a field person cannot make the all-shifts feed', $$select app.shift_feed_set(test.id('sfd_field'), '{"scope":"all","action":"create"}')$$, '%not yours%');
select test.throws('an unknown action is refused', $$select app.shift_feed_set(test.id('sfd_admin'), '{"scope":"all","action":"delete"}')$$, '%Create, regenerate%');

-- ================================================================ the token
select test.eq('no link until it is made', (app.shift_feed_state(test.id('sfd_admin')) #>> '{feeds,0,token}'), null::text);
select app.shift_feed_set(test.id('sfd_admin'), '{"scope":"all","action":"create"}');
create temp table sfd_t as select (app.shift_feed_state(test.id('sfd_admin')) #>> '{feeds,0,token}') as tok;
select test.ok('the token is 64 hex characters', (select tok from sfd_t) ~ '^[0-9a-f]{64}$');
select app.shift_feed_set(test.id('sfd_admin'), '{"scope":"all","action":"create"}');
select test.eq('making it again keeps the same link', (app.shift_feed_state(test.id('sfd_admin')) #>> '{feeds,0,token}'), (select tok from sfd_t));
select test.ok('the token is kept out of the audit log', not exists (select 1 from audit_log a where a.entity_table = 'shift_feeds' and (coalesce(a.after::text, '') || coalesce(a.before::text, '')) like '%' || (select tok from sfd_t) || '%'));

-- ================================================================ the shifts
-- tomorrow 10:00 to 14:00 Toronto, two places, one claimed; an open one the day after; one cancelled; one 70 days ahead
create temp table sfd_s as select
  ((app.today() + 1)::timestamp + time '10:00') at time zone 'America/Toronto' as a1,
  ((app.today() + 2)::timestamp + time '08:30') at time zone 'America/Toronto' as a2,
  ((app.today() + 70)::timestamp + time '09:00') at time zone 'America/Toronto' as a3;
insert into field_shift_slots (id, starts_at, ends_at, capacity, note) values
  (test.id('sfd_slot1'), (select a1 from sfd_s), (select a1 from sfd_s) + interval '4 hours', 2, 'Airport run'),
  (test.id('sfd_slot2'), (select a2 from sfd_s), (select a2 from sfd_s) + interval '3 hours', 1, null),
  (test.id('sfd_slot3'), (select a3 from sfd_s), (select a3 from sfd_s) + interval '3 hours', 1, null);
insert into field_shift_slots (id, starts_at, ends_at, capacity, cancelled_at, cancelled_by) values
  (test.id('sfd_slot4'), (select a1 from sfd_s) + interval '5 hours', (select a1 from sfd_s) + interval '7 hours', 1, now(), test.id('sfd_admin'));
insert into field_shift_plans (id, slot_id, staff_id, starts_at, ends_at)
select test.id('sfd_plan1'), id, test.id('sfd_field'), starts_at, ends_at from field_shift_slots where id = test.id('sfd_slot1');
insert into field_jobs (kind, vehicle_id, scheduled_at, shift_slot_id, assigned_to, shift_pinned)
select 'detail', (select v.id from vehicles v order by v.created_at limit 1), (select a1 from sfd_s) + interval '1 hour', test.id('sfd_slot1'), test.id('sfd_field'), true;

create temp table sfd_ics as select public.server_shift_feed((select tok from sfd_t)) as t;
select test.ok('a calendar answers', (select t from sfd_ics) like E'BEGIN:VCALENDAR\r\n%' and (select t from sfd_ics) like E'%END:VCALENDAR\r\n');
select test.ok('METHOD:PUBLISH with its name', (select t from sfd_ics) like '%METHOD:PUBLISH%X-WR-CALNAME:CarmaCars field shifts%');
select test.ok('Toronto time with its zone', (select t from sfd_ics) like '%BEGIN:VTIMEZONE%TZID:America/Toronto%'
  and (select t from sfd_ics) like '%DTSTART;TZID=America/Toronto:' || app.ics_local((select a1 from sfd_s)) || '%');
select test.ok('the local start is 10:00', app.ics_local((select a1 from sfd_s)) like '%T100000');
select test.ok('the end in Toronto time', (select t from sfd_ics) like '%DTEND;TZID=America/Toronto:' || app.ics_local((select a1 from sfd_s) + interval '4 hours') || '%');
select test.ok('who claimed it, with the place still open', (select t from sfd_ics) like '%SUMMARY:Field shift: Sfd Field (1 open)%');
select test.ok('an unclaimed shift says Open', (select t from sfd_ics) like '%SUMMARY:Field shift: Open%');
select test.ok('the tasks count', (select t from sfd_ics) like '%Tasks: ' || (select count(*) from field_jobs j where j.shift_slot_id = test.id('sfd_slot1') and j.status <> 'cancelled') || '%');
select test.ok('at least the one task made here', (select count(*) from field_jobs j where j.shift_slot_id = test.id('sfd_slot1') and j.status <> 'cancelled') >= 1);
select test.ok('a link to the shift in the admin portal', replace((select t from sfd_ics), E'\r\n ', '') like '%URL:https://carmacars.ca/admin/field-jobs?slot=' || test.id('sfd_slot1') || '%');
select test.ok('one UID per shift', (select t from sfd_ics) like '%UID:shift-' || test.id('sfd_slot1') || '@carmacars.ca%');
select test.ok('a cancelled shift is left out', (select t from sfd_ics) not like '%' || test.id('sfd_slot4') || '%');
select test.ok('a shift 70 days ahead is left out', (select t from sfd_ics) not like '%' || test.id('sfd_slot3') || '%');
select test.ok('no line is longer than 75 characters', not exists (select 1 from regexp_split_to_table((select t from sfd_ics), E'\r\n') l where length(l) > 75));

-- Fleet's link opens the shift on Fleet's board
select app.shift_feed_set(test.id('sfd_fleet'), '{"scope":"all","action":"create"}');
select test.ok('Fleet''s link is the staff board', replace(public.server_shift_feed(app.shift_feed_state(test.id('sfd_fleet')) #>> '{feeds,0,token}'), E'\r\n ', '') like '%URL:https://carmacars.ca/staff/fleet?slot=' || test.id('sfd_slot1') || '%');

-- ================================================================ a field person's own
select app.shift_feed_set(test.id('sfd_field'), '{"scope":"mine","action":"create"}');
create temp table sfd_mine as select public.server_shift_feed(app.shift_feed_state(test.id('sfd_field')) #>> '{feeds,0,token}') as t;
select test.ok('their claimed shift is in it', (select t from sfd_mine) like '%UID:shift-' || test.id('sfd_plan1') || '@carmacars.ca%');
select test.ok('the open shift is not', (select t from sfd_mine) not like '%Field shift: Open%' and (select count(*) from regexp_matches((select t from sfd_mine), 'BEGIN:VEVENT', 'g')) = 1);
select test.ok('the tasks given to them', (select t from sfd_mine) like '%Tasks given to you: 1%');
select test.ok('the link is My shifts', replace((select t from sfd_mine), E'\r\n ', '') like '%URL:https://carmacars.ca/staff/field/shifts%');
select app.shift_feed_set(test.id('sfd_field2'), '{"scope":"mine","action":"create"}');
select test.ok('someone else''s feed has no event', public.server_shift_feed(app.shift_feed_state(test.id('sfd_field2')) #>> '{feeds,0,token}') not like '%BEGIN:VEVENT%');

-- ================================================================ regenerate and revoke
select app.shift_feed_set(test.id('sfd_admin'), '{"scope":"all","action":"regenerate"}');
select test.ok('a new token', (app.shift_feed_state(test.id('sfd_admin')) #>> '{feeds,0,token}') <> (select tok from sfd_t));
select test.eq('the old link answers nothing', public.server_shift_feed((select tok from sfd_t)), null::text);
select test.ok('the new link answers', public.server_shift_feed(app.shift_feed_state(test.id('sfd_admin')) #>> '{feeds,0,token}') like 'BEGIN:VCALENDAR%');
update sfd_t set tok = (app.shift_feed_state(test.id('sfd_admin')) #>> '{feeds,0,token}') where true;
select app.shift_feed_set(test.id('sfd_admin'), '{"scope":"all","action":"revoke"}');
select test.eq('turned off: no link', (app.shift_feed_state(test.id('sfd_admin')) #>> '{feeds,0,token}'), null::text);
select test.eq('turned off: the link answers nothing', public.server_shift_feed((select tok from sfd_t)), null::text);
select test.eq('a malformed token answers nothing', public.server_shift_feed('nope'), null::text);
-- a person who leaves: their link stops
update users set status = 'suspended' where id = test.id('sfd_fleet');
select test.eq('an inactive person''s link answers nothing', public.server_shift_feed((select f.token from shift_feeds f where f.user_id = test.id('sfd_fleet') and f.revoked_at is null)), null::text);

-- ================================================================ the door and the grants
select test.ok('the door reads it for an Admin', (app.door(test.id('sfd_admin'), 'aal1', 'admin_read', 'shift_feed', '{}') ->> 'scopes') = '["all"]');
select test.ok('and for a field person', (app.door(test.id('sfd_field'), 'aal1', 'field_read', 'shift_feed', '{}') ->> 'scopes') = '["mine"]');
select test.ok('the server role only calls the feed', not has_function_privilege('anon', 'public.server_shift_feed(text)', 'execute')
  and not has_function_privilege('authenticated', 'public.server_shift_feed(text)', 'execute') and has_function_privilege('service_role', 'public.server_shift_feed(text)', 'execute'));
select test.ok('browser roles cannot read the feeds table', not has_table_privilege('authenticated', 'shift_feeds', 'select') and not has_table_privilege('anon', 'shift_feeds', 'select'));
