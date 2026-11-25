-- 99: calls in the site (migration 5010, docs/changes/2026-11-24-r50-in-site-calls.md): who may join the townhall call,
-- the attendance recorded by itself from joins and leaves (missed counts keep working), Admin's live list, the interview
-- room per slot and the candidate's single-use link, the fallback switch. Fixtures "cl50".
select test.suite('99 r50 in-site calls: townhall join and attendance, live list, interview rooms, single-use guest link, fallback');
select test.mk_user('cl50_admin', 'admin');
select test.mk_user('cl50_cs', 'va', 'cs');
select test.mk_user('cl50_field', 'field');
create function test.cl50(p_user text, p_call text, p_name text, p jsonb) returns jsonb language sql as $$ select app.door(test.id(p_user), 'aal2', p_call, p_name, p) $$;

-- ================================================================ 1. joining the townhall
-- the townhall is now: today, starting 5 minutes ago (Toronto)
update program_settings set townhall_weekday = extract(isodow from now() at time zone 'America/Toronto')::int,
       townhall_time = to_char((now() - interval '5 minutes') at time zone 'America/Toronto', 'HH24:MI'), townhall_minutes = 45, calls_mode = 'in_site'
 where id = (app.settings()).id;
create temp table cl50_j as select test.cl50('cl50_cs', 'ops_read', 'call_join', '{"room":"townhall"}') j;
select test.ok('a staff member may join the townhall call', (select j ->> 'room' from cl50_j) like 'townhall-%');
select test.eq('as a member, with their own identity', (select j ->> 'role' || ' ' || (j ->> 'identity') from cl50_j), 'member u-' || test.id('cl50_cs'));
select test.eq('the Admin presents', test.cl50('cl50_admin', 'admin_read', 'call_join', '{"room":"townhall"}') ->> 'role', 'presenter');
select test.ok('the townhall reads say the call is in the site', (test.cl50('cl50_cs', 'ops_read', 'townhall_link', '{}') ->> 'in_site')::boolean);
select test.throws('a renter may not join', $$select app.call_join(test.mk_renter('cl50_renter'), '{"room":"townhall"}')$$, '%Staff only%');

-- ================================================================ 2. attendance by itself
select public.server_call_event(jsonb_build_object('room', (select j ->> 'room' from cl50_j), 'identity', 'u-' || test.id('cl50_cs'), 'event', 'joined', 'at', now() - interval '4 minutes'));
select test.ok('joining records the attendance, confirmed', app.townhall_attended(app.townhall_next(now()), test.id('cl50_cs')));
select test.eq('method call, with the join time', (select method || ' ' || (joined_at is not null)::text from townhall_attendance where user_id = test.id('cl50_cs') and meeting_at = app.townhall_next(now())), 'call true');
select test.eq('the Admin sees them in the call', (select jsonb_array_length(test.cl50('cl50_admin', 'admin_read', 'call_live', '{"room":"townhall"}') -> 'in')), 1);
select test.ok('and who has not joined', test.cl50('cl50_admin', 'admin_read', 'call_live', '{"room":"townhall"}') -> 'not_joined' @> jsonb_build_array(jsonb_build_object('user_id', test.id('cl50_field'))));
select public.server_call_event(jsonb_build_object('room', (select j ->> 'room' from cl50_j), 'identity', 'u-' || test.id('cl50_cs'), 'event', 'left', 'at', now() - interval '1 minute'));
select test.eq('leaving records the leave time and the minutes', (select (left_at is not null)::text || ' ' || seconds from townhall_attendance where user_id = test.id('cl50_cs') and meeting_at = app.townhall_next(now())), 'true 180');
select public.server_call_event(jsonb_build_object('room', (select j ->> 'room' from cl50_j), 'identity', 'u-' || test.id('cl50_cs'), 'event', 'joined'));
select test.eq('back in: a second visit, still in', (select joins::text || ' ' || (left_at is null)::text from call_participants where identity = 'u-' || test.id('cl50_cs')), '2 true');
select test.throws('an unknown identity is refused', $$select public.server_call_event('{"room":"x","identity":"robert","event":"joined"}')$$, '%Unknown participant%');
select test.throws('a staff member cannot read the live list', $$select test.cl50('cl50_cs', 'admin_read', 'call_live', '{"room":"townhall"}')$$);

-- the meeting is closed with the absences: the one in the call is not absent, the one who never joined is
insert into townhall_meetings (meeting_at, absent) values (app.townhall_next(now()), array[test.id('cl50_field'), test.id('cl50_cs')]);
select public.server_call_event(jsonb_build_object('room', (select j ->> 'room' from cl50_j), 'identity', 'u-' || test.id('cl50_cs'), 'event', 'seen'));
select test.ok('a closed meeting is corrected for someone in the call', not exists (select 1 from townhall_meetings where meeting_at = app.townhall_next(now()) and test.id('cl50_cs') = any (absent)));
select test.ok('the missed count still counts who never joined', exists (select 1 from townhall_meetings where meeting_at = app.townhall_next(now()) and test.id('cl50_field') = any (absent)));

-- ================================================================ 3. too early, cancelled
update program_settings set townhall_time = to_char((now() + interval '3 hours') at time zone 'America/Toronto', 'HH24:MI') where id = (app.settings()).id;
select test.throws('staff cannot join hours before', $$select test.cl50('cl50_cs', 'ops_read', 'call_join', '{"room":"townhall"}')$$, '%opens 15 minutes before%');
select test.ok('the Admin can open it early to set up', test.cl50('cl50_admin', 'admin_read', 'call_join', '{"room":"townhall"}') ->> 'room' like 'townhall-%');

-- ================================================================ 4. the fallback
select test.throws('the outside link cannot be the fallback while it is empty', $$select test.cl50('cl50_admin', 'admin_do', 'calls_mode', '{"mode":"link"}')$$, '%outside call link%');
update program_settings set townhall_call_url = 'https://meet.example.test/carmacars' where id = (app.settings()).id;
select test.eq('the Admin switches to the outside link', test.cl50('cl50_admin', 'admin_do', 'calls_mode', '{"mode":"link"}') ->> 'calls_mode', 'link');
select test.ok('the townhall reads say so', not (test.cl50('cl50_cs', 'ops_read', 'townhall', '{}') ->> 'in_site')::boolean);
select test.throws('staff cannot switch it', $$select test.cl50('cl50_cs', 'admin_do', 'calls_mode', '{"mode":"in_site"}')$$);
select test.eq('and back to the site', test.cl50('cl50_admin', 'admin_do', 'calls_mode', '{"mode":"in_site"}') ->> 'calls_mode', 'in_site');

-- ================================================================ 5. interview calls: a room per slot, the single-use link
insert into interview_days (day, start_time, end_time, mode, note) values (app.local_date(now()), '00:00', '23:59', 'video', 'cl50 day');
insert into interview_slots (day_id, starts_at, ends_at) select d.id, now() + interval '31 minutes', now() + interval '46 minutes' from interview_days d where d.note = 'cl50 day';
insert into job_applications (role_id, status, full_name, email, phone) select id, 'invited', 'Cl Fifty', 'cand@cl50.example.test', '+14165550122' from hiring_roles where slug = 'va-fleet-operations';
create function test.cl50_app() returns job_applications language sql stable as $$ select * from job_applications where email = 'cand@cl50.example.test' $$;
select app.hiring_book((test.cl50_app()).token, (select s.id from interview_slots s join interview_days d on d.id = s.day_id where d.note = 'cl50 day'));
select test.ok('the booked call''s link is in the site, not Jitsi', (test.cl50_app()).meet_url like 'https://carmacars.ca/call/i/%');
select test.eq('only its hash is kept', (select count(*) from call_guest_links where application_id = (test.cl50_app()).id and revoked_at is null and token_hash = app.call_token_hash(substr((test.cl50_app()).meet_url, length('https://carmacars.ca/call/i/') + 1))), 1::bigint);
select test.ok('no Google Meet sync for it', (test.cl50_app()).meet_sync is null);
create temp table cl50_t as select substr((test.cl50_app()).meet_url, length('https://carmacars.ca/call/i/') + 1) t;
-- 31 minutes ahead: too early to open (and a look does not use it)
select test.eq('too early: the page says when it opens', public.server_call_guest_peek((select t from cl50_t)) ->> 'state', 'early');
select test.eq('too early: not used', public.server_call_guest_open((select t from cl50_t), 'nonce-aaaaaaaaaaaaaaaaaaaa') ->> 'error', 'early');
update interview_slots set starts_at = now() + interval '5 minutes', ends_at = now() + interval '20 minutes' where id = (test.cl50_app()).slot_id;
select test.ok('a look (an email scanner) does not use the link', not (public.server_call_guest_peek((select t from cl50_t)) ->> 'used')::boolean);
create temp table cl50_o as select public.server_call_guest_open((select t from cl50_t), 'nonce-aaaaaaaaaaaaaaaaaaaa') o;
select test.ok('the first open from a browser works', ((select o from cl50_o) ->> 'ok')::boolean);
select test.ok('the same browser may open it again', (public.server_call_guest_open((select t from cl50_t), 'nonce-aaaaaaaaaaaaaaaaaaaa') ->> 'ok')::boolean);
select test.eq('another browser is refused: single use', public.server_call_guest_open((select t from cl50_t), 'nonce-bbbbbbbbbbbbbbbbbbbb') ->> 'error', 'used');
select test.eq('a made-up token is not found', public.server_call_guest_open('nope', 'nonce-bbbbbbbbbbbbbbbbbbbb') ->> 'error', 'not_found');
create temp table cl50_s as select public.server_call_guest_session(((select o from cl50_o) ->> 'link_id')::uuid, 'nonce-aaaaaaaaaaaaaaaaaaaa') s;
select test.eq('the session gives the slot''s private room', (select s ->> 'room' from cl50_s), 'iv-' || (test.cl50_app()).slot_id);
select test.eq('as a guest without a staff account', (select s ->> 'identity' || ' ' || (s ->> 'role') from cl50_s), 'g-' || (test.cl50_app()).id || ' guest');
select test.eq('a forged session nonce is refused', public.server_call_guest_session(((select o from cl50_o) ->> 'link_id')::uuid, 'nonce-cccccccccccccccccccc') ->> 'error', 'used');
select test.eq('the interviewer joins the same room', test.cl50('cl50_admin', 'admin_read', 'call_join', jsonb_build_object('room', 'interview', 'application_id', (test.cl50_app()).id)) ->> 'room', 'iv-' || (test.cl50_app()).slot_id);
select test.throws('staff cannot join an interview', format($$select test.cl50('cl50_cs', 'ops_read', 'call_join', '{"room":"interview","application_id":"%s"}')$$, (test.cl50_app()).id), '%Only an Admin%');
select public.server_call_event(jsonb_build_object('room', 'iv-' || (test.cl50_app()).slot_id, 'identity', 'g-' || (test.cl50_app()).id, 'event', 'joined'));
select test.eq('the candidate shows in the room', (select role from call_participants c join call_rooms r on r.id = c.room_id where r.name = 'iv-' || (test.cl50_app()).slot_id and c.identity = 'g-' || (test.cl50_app()).id), 'guest');
select test.eq('another candidate''s identity is refused in this room', public.server_call_event(jsonb_build_object('room', 'iv-' || (test.cl50_app()).slot_id, 'identity', 'g-' || gen_random_uuid(), 'event', 'joined')) ->> 'error', 'not_this_room');
-- cancelled: the link stops working
select app.hiring_cancel((test.cl50_app()).token);
select test.eq('a cancelled call''s link no longer opens', public.server_call_guest_open((select t from cl50_t), 'nonce-aaaaaaaaaaaaaaaaaaaa') ->> 'error', 'replaced');
