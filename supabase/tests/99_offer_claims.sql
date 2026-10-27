-- 99: one answer per booking request (migration 0177, docs/changes/2026-10-27-one-offer-per-request.md).
-- Two staff answering at once (the row lock: the second is told who answered and when), a stale offer edit refused, the claim
-- (taken, renewed, released, run out and taken over, taken over by an Admin), decline racing an offer, the history rows, the
-- task going to the person answering, the lists and Admin > Today saying who answers, and the Sales wait with its task.
-- Fixtures start with "ocl".
select test.suite('99 offer claims');
grant usage on schema test to service_role;
grant execute on all functions in schema test to authenticated, anon, service_role;

select test.mk_user('ocl_admin', 'admin');
select test.mk_user('ocl_cs', 'va', 'cs');
select test.mk_user('ocl_cs2', 'va', 'cs');
select test.mk_user('ocl_sales', 'va', 'sales');
select test.mk_owner('ocl_o');
select test.mk_vehicle('OCLA', 'ocl_o');
select test.mk_vehicle('OCLB', 'ocl_o');
select test.mk_vehicle('OCLC', 'ocl_o');
select test.mk_vehicle('OCLD', 'ocl_o');
select test.mk_vehicle('OCLE', 'ocl_o');
select test.mk_vehicle('OCLF', 'ocl_o');
select test.mk_vehicle('OCLG', 'ocl_o');
select test.mk_vehicle('OCLH', 'ocl_o');
select test.mk_renter('ocl_r');
create function test.ocl_day(p_days integer) returns text language sql stable as $$
  select to_char(app.today() + p_days, 'YYYY-MM-DD') || ' 10:00' $$;
create function test.oclb(p text) returns uuid language sql stable as $$ select test.id('booking:' || p) $$;
create function test.ocl(p_user text, p_call text, p_name text, p jsonb default '{}') returns jsonb language sql as $$
  select app.door(test.id(p_user), 'aal2', p_call, p_name, p) $$;
create function test.ocl_va(p_user text, p_name text, p_booking text, p jsonb default '{}') returns jsonb language sql as $$
  select app.door(test.id(p_user), 'aal2', 'va_do', p_name, jsonb_build_object('booking', test.oclb(p_booking))
    || case when p_name = 'send_offer' then '{"sales_choice": "for_carmacars"}'::jsonb else '{}'::jsonb end || p) $$;
create function test.ocl_claim(p_user text, p_booking text, p_mode text default 'claim') returns jsonb language sql as $$
  select app.door(test.id(p_user), 'aal2', 'ops_do', 'request_claim', jsonb_build_object('booking', test.oclb(p_booking), 'mode', p_mode)) $$;
create function test.ocl_state(p_user text, p_booking text) returns jsonb language sql as $$
  select app.door(test.id(p_user), 'aal2', 'ops_do', 'request_state', jsonb_build_object('booking', test.oclb(p_booking))) $$;
create function test.ocl_status(p text) returns text language sql stable as $$ select status::text from bookings where id = test.oclb(p) $$;

-- seven requests from the website, an hour old (open to Sales), except OCL-5 (just in) and OCL-7 (entered by staff, just in)
select test.mk_booking('OCL-' || n, 'OCL' || chr(64 + n), 'ocl_r', test.ocl_day(4 + n), test.ocl_day(6 + n), 'requested') from generate_series(1, 8) n;
update bookings set requested_at = now() - interval '1 hour' where id in (select test.oclb('OCL-' || n) from generate_series(1, 8) n);
update bookings set requested_at = now() where id in (test.oclb('OCL-5'), test.oclb('OCL-7'));
insert into booking_events (booking_id, kind, from_status, to_status, actor_type, actor_user_id) values (test.oclb('OCL-7'), 'requested', null, 'requested', 'staff', test.id('ocl_cs'));
select app.raise_task('booking_request', format('New booking request %s', 'OCL-' || n), p_booking => test.oclb('OCL-' || n)) from generate_series(1, 4) n;

-- ================================================================ 1. the claim and the single answer
select test.eq('claim: customer service opens OCL-1 to answer it and holds it', (test.ocl_claim('ocl_cs', 'OCL-1') #>> '{claim,mine}'), 'true');
select test.eq('claim: the request''s task goes to them (in progress)', (select assigned_to::text || '/' || status from tasks where booking_id = test.oclb('OCL-1') and task_type = 'booking_request'),
  test.id('ocl_cs')::text || '/in_progress');
select test.ok('claim: the others see who and since when', (test.ocl_state('ocl_cs2', 'OCL-1') #>> '{claim,text}') like 'Being answered by Ocl Cs since %'
  and (test.ocl_state('ocl_cs2', 'OCL-1') #>> '{claim,mine}') = 'false');
select test.eq('claim: another person opening it does not take it', (test.ocl_claim('ocl_cs2', 'OCL-1') #>> '{claim,by}'), test.id('ocl_cs')::text);
select test.throws('claim: another person cannot send the offer meanwhile', $$select test.ocl_va('ocl_cs2', 'send_offer', 'OCL-1')$$, 'Being answered by Ocl Cs since%');
select test.throws('claim: nor decline it', $$select test.ocl_va('ocl_cs2', 'decline_request', 'OCL-1', '{"note": "No car"}')$$, 'Being answered by Ocl Cs since%');
select test.throws('claim: nor ask the renter', $$select test.ocl_va('ocl_cs2', 'ask_info', 'OCL-1', '{"question": "Which hotel?"}')$$, 'Being answered by Ocl Cs since%');
select test.throws('claim: only an Admin takes over a live claim', $$select test.ocl_claim('ocl_cs2', 'OCL-1', 'takeover')$$, '%only an Admin takes over%');
select test.throws('claim: app.send_offer itself refuses it for any caller', format($$select app.send_offer(%L, %L)$$, test.oclb('OCL-1'), test.id('ocl_cs2')), 'Being answered by Ocl Cs since%');
select test.eq('send: the person answering sends the offer (version 1)', (test.ocl_va('ocl_cs', 'send_offer', 'OCL-1') ->> 'version'), '1');
select test.ok('send: the claim ends with the answer', not exists (select 1 from request_claims where booking_id = test.oclb('OCL-1')));
select test.throws('late send: a second offer is refused with who answered and when', $$select test.ocl_va('ocl_cs2', 'send_offer', 'OCL-1')$$,
  'Already answered by Ocl Cs at %: open the offer to see it.');
select test.throws('late decline: refused too', $$select test.ocl_va('ocl_cs2', 'decline_request', 'OCL-1', '{"note": "No car"}')$$, 'Already answered by Ocl Cs at %');
select test.throws('late question: refused too', $$select test.ocl_va('ocl_cs2', 'ask_info', 'OCL-1', '{"question": "Which hotel?"}')$$, 'Already answered by Ocl Cs at %');
select test.eq('late send: still one offer', (select count(*) from booking_offers where booking_id = test.oclb('OCL-1')), 1::bigint);

-- ================================================================ 2. a stale screen cannot overwrite a newer offer
select test.eq('edit: sent again from the screen of version 1 (version 2)', (test.ocl('ocl_admin', 'admin_do', 'resend_offer', jsonb_build_object('booking', test.oclb('OCL-1'), 'expected_version', 1,
  'expires_at', now() + interval '2 days')) ->> 'version'), '2');
select test.throws('edit: a change from a screen still showing version 1 is refused', format($$select test.ocl('ocl_cs2', 'ops_do', 'offer_revise', %L::jsonb)$$,
  jsonb_build_object('booking', test.oclb('OCL-1'), 'changes', '{}'::jsonb, 'expected_version', 1)), 'Changed by Ocl Admin at % (now version 2): open the offer to see it.');
select test.throws('edit: withdraw from a stale screen is refused', $$select test.ocl_va('ocl_cs2', 'withdraw_offer', 'OCL-1', '{"expected_version": 1}')$$, 'Changed by Ocl Admin%');
select test.throws('edit: approved by phone from a stale screen is refused', format($$select test.ocl('ocl_admin', 'admin_do', 'approve_offer_by_phone', %L::jsonb)$$,
  jsonb_build_object('booking', test.oclb('OCL-1'), 'expected_version', 1)), 'Changed by Ocl Admin%');
select test.throws('edit: "send the offer" on an offer that is out, without the version, is a second answer', $$select test.ocl_va('ocl_cs2', 'send_offer', 'OCL-1')$$, 'Already answered by Ocl Admin at %');
select test.eq('edit: with the current version it goes (version 3)', (test.ocl_va('ocl_cs2', 'send_offer', 'OCL-1', '{"expected_version": 2}') ->> 'version'), '3');

-- ================================================================ 3. run out, renewed, released, taken over
select test.ocl_claim('ocl_cs', 'OCL-2');
update request_claims set claimed_at = now() - interval '25 minutes', expires_at = now() - interval '5 minutes' where booking_id = test.oclb('OCL-2');
select test.ok('expiry: a claim that ran out shows nobody', (test.ocl_state('ocl_cs2', 'OCL-2') -> 'claim') = 'null'::jsonb);
select test.lives('expiry: anyone may answer it now', format($$select app.request_answer_guard(%L, %L, 'offer')$$, test.id('ocl_cs2'), test.oclb('OCL-2')));
select test.eq('expiry: the next person opening it takes it over', (test.ocl_claim('ocl_cs2', 'OCL-2') #>> '{claim,mine}'), 'true');
select test.ok('expiry: logged on the booking history', exists (select 1 from booking_events where booking_id = test.oclb('OCL-2') and kind = 'claim_taken_over'
  and actor_user_id = test.id('ocl_cs2') and note like 'Taken over from Ocl Cs (their claim had run out at %)'));
select test.eq('expiry: the task follows', (select assigned_to from tasks where booking_id = test.oclb('OCL-2') and task_type = 'booking_request'), test.id('ocl_cs2'));

select test.ocl_claim('ocl_cs', 'OCL-3');
select test.eq('Admin: opening it does not take it from the person', (test.ocl_claim('ocl_admin', 'OCL-3') #>> '{claim,mine}'), 'false');
select test.ok('Admin: may press Take over', (test.ocl_state('ocl_admin', 'OCL-3') ->> 'admin')::boolean);
select test.eq('Admin: takes it over at any time', (test.ocl_claim('ocl_admin', 'OCL-3', 'takeover') #>> '{claim,mine}'), 'true');
select test.ok('Admin: the takeover is in the history', exists (select 1 from booking_events where booking_id = test.oclb('OCL-3') and kind = 'claim_taken_over'
  and actor_user_id = test.id('ocl_admin') and note = 'Taken over from Ocl Cs (by an Admin)'));
select test.throws('Admin: the earlier person can no longer send', $$select test.ocl_va('ocl_cs', 'send_offer', 'OCL-3')$$, 'Being answered by Ocl Admin since%');

select test.ocl_claim('ocl_cs', 'OCL-4');
update request_claims set expires_at = now() + interval '1 minute' where booking_id = test.oclb('OCL-4');
select test.ok('renew: working on it renews the claim (20 minutes)', (test.ocl_claim('ocl_cs', 'OCL-4', 'renew') #>> '{claim,until}')::timestamptz > now() + interval '19 minutes');
select test.eq('renew: someone else renewing does not take it', (test.ocl_claim('ocl_cs2', 'OCL-4', 'renew') #>> '{claim,by}'), test.id('ocl_cs')::text);
select test.ok('release: leaving the page ends the claim', (test.ocl('ocl_cs', 'ops_do', 'request_release', jsonb_build_object('booking', test.oclb('OCL-4'))) -> 'claim') = 'null'::jsonb);
select test.eq('release: the task goes back to the queue', (select coalesce(assigned_to::text, 'none') || '/' || status from tasks where booking_id = test.oclb('OCL-4') and task_type = 'booking_request'), 'none/open');
select test.ok('release: someone else''s release does nothing', (select (test.ocl_claim('ocl_cs', 'OCL-4') #>> '{claim,mine}') = 'true'
  and (test.ocl('ocl_cs2', 'ops_do', 'request_release', jsonb_build_object('booking', test.oclb('OCL-4'))) #>> '{claim,by}') = test.id('ocl_cs')::text));
update program_settings set request_claim_minutes = 30;
select test.ok('setting: request_claim_minutes sets how long', (test.ocl_claim('ocl_cs', 'OCL-4', 'renew') #>> '{claim,until}')::timestamptz > now() + interval '29 minutes');
update program_settings set request_claim_minutes = 20;
delete from request_claims where booking_id = test.oclb('OCL-4');

-- ================================================================ 4. two at the same moment (two connections, where dblink is installed)
create or replace function pg_temp.race(p_booking text, p_first text, p_second text) returns text language plpgsql as $$
declare
  c text := format('host=%s port=%s dbname=%s user=%s', split_part(current_setting('unix_socket_directories'), ',', 1), current_setting('port'), current_database(), current_user);
  a text; b text;
begin
  begin
    create extension if not exists dblink with schema test;
  exception when others then return 'skipped';
  end;
  begin
    perform test.dblink_connect('ocl1', c); perform test.dblink_connect('ocl2', c);
  exception when others then return 'skipped';
  end;
  perform test.dblink_exec('ocl1', 'begin');
  select x into a from test.dblink('ocl1', p_first) as t(x text);
  perform test.dblink_send_query('ocl2', p_second);
  perform pg_sleep(0.3);
  perform test.dblink_exec('ocl1', 'commit');
  begin
    select x into b from test.dblink_get_result('ocl2') as t(x text);
  exception when others then b := sqlerrm;
  end;
  perform test.dblink_disconnect('ocl1'); perform test.dblink_disconnect('ocl2');
  return coalesce(a, '') || ' | ' || coalesce(b, '');
end $$;
create temp table ocl_race (k text, v text);
insert into ocl_race select 'offer', pg_temp.race('OCL-6',
  format('select app.door(%L, ''aal2'', ''va_do'', ''send_offer'', %L::jsonb) ->> ''version''', test.id('ocl_cs'), jsonb_build_object('booking', test.oclb('OCL-6'), 'sales_choice', 'for_carmacars')),
  format('select app.door(%L, ''aal2'', ''va_do'', ''send_offer'', %L::jsonb) ->> ''version''', test.id('ocl_cs2'), jsonb_build_object('booking', test.oclb('OCL-6'), 'sales_choice', 'for_carmacars')));
select test.ok('race: two offers at once, the first wins and the second is told who answered (or dblink is not installed)',
  (select v = 'skipped' or (v like '1 | %Already answered by Ocl Cs at %: open the offer to see it.%') from ocl_race where k = 'offer'), (select v from ocl_race where k = 'offer'));
select test.ok('race: never two offers on one request', (select count(*) <= 1 from booking_offers where booking_id = test.oclb('OCL-6')));
insert into ocl_race select 'decline', pg_temp.race('OCL-4',
  format('select app.door(%L, ''aal2'', ''va_do'', ''decline_request'', %L::jsonb) is not null', test.id('ocl_cs'), jsonb_build_object('booking', test.oclb('OCL-4'), 'note', 'No car those days')),
  format('select app.door(%L, ''aal2'', ''va_do'', ''send_offer'', %L::jsonb) ->> ''version''', test.id('ocl_cs2'), jsonb_build_object('booking', test.oclb('OCL-4'), 'sales_choice', 'for_carmacars')));
select test.ok('race: a decline and an offer at once, the offer is refused (or dblink is not installed)',
  (select v = 'skipped' or (v like 't | %Already answered by Ocl Cs at %: open the booking to see it.%') from ocl_race where k = 'decline'), (select v from ocl_race where k = 'decline'));
select test.ok('race: the declined request has no offer', (select v = 'skipped' from ocl_race where k = 'decline')
  or (test.ocl_status('OCL-4') = 'declined' and not exists (select 1 from booking_offers where booking_id = test.oclb('OCL-4'))));
drop extension if exists dblink;

-- ================================================================ 5. the lists and Admin > Today
select test.ok('lists: the requests list says who answers it (and Assigned)', (select x #>> '{claim,name}' = 'Ocl Cs2' and x ->> 'assigned' = 'Ocl Cs2'
  from jsonb_array_elements(test.ocl('ocl_admin', 'admin_read', 'requests')) x where x ->> 'booking_number' = 'OCL-2'));
select test.ok('lists: the person answering sees it as theirs', (select (x #>> '{claim,mine}')::boolean from jsonb_array_elements(test.ocl('ocl_cs2', 'va_read', 'requests')) x where x ->> 'booking_number' = 'OCL-2'));
select test.ok('Today: the "Answer the request" line says who is answering it', (select x ->> 'why' like '%Being answered by Ocl Cs2 since %' and x #>> '{claim,name}' = 'Ocl Cs2'
  from jsonb_array_elements(app.todo_prompts(test.id('ocl_admin')) -> 'prompts') x where x ->> 'key' = 'request:' || test.oclb('OCL-2')));

-- ================================================================ 6. Sales wait for customer service first
select test.ok('Sales: a request just in waits for customer service', (test.ocl_state('ocl_sales', 'OCL-5') ->> 'sales_waits')::boolean
  and (test.ocl_state('ocl_sales', 'OCL-5') ->> 'sales_text') like 'Open to Sales at % if nobody answers');
select test.ok('Sales: the list says when it opens to them', (select (x ->> 'sales_waits')::boolean and (x ->> 'sales_opens_at')::timestamptz between now() + interval '14 minutes' and now() + interval '16 minutes'
  from jsonb_array_elements(test.ocl('ocl_sales', 'va_read', 'requests')) x where x ->> 'booking_number' = 'OCL-5'));
select test.ok('Sales: opening it does not claim it', (test.ocl_claim('ocl_sales', 'OCL-5') -> 'claim') = 'null'::jsonb);
select test.throws('Sales: cannot send the offer yet', $$select test.ocl_va('ocl_sales', 'send_offer', 'OCL-5')$$, '%it opens to Sales at % if nobody answers it.');
select test.throws('Sales: nor decline it', $$select test.ocl_va('ocl_sales', 'decline_request', 'OCL-5', '{"note": "No"}')$$, '%opens to Sales%');
select test.throws('Sales: nor take it over', $$select test.ocl_claim('ocl_sales', 'OCL-5', 'takeover')$$, '%opens to Sales%');
select test.ok('Sales: customer service sees the same note but may answer', (test.ocl_state('ocl_cs', 'OCL-5') ->> 'sales_waits') = 'false' and (test.ocl_state('ocl_cs', 'OCL-5') ->> 'sales_text') is not null);
select test.ok('Sales: a request staff entered has no wait', (test.ocl_state('ocl_sales', 'OCL-7') ->> 'sales_waits') = 'false' and (test.ocl_state('ocl_sales', 'OCL-7') -> 'sales_opens_at') = 'null'::jsonb);
select test.eq('Sales: no task before it opens', (select count(*) from tasks where booking_id = test.oclb('OCL-5') and task_type = 'request_open_to_sales'), 0::bigint);
select app.job_requests_open_to_sales(now());
select test.eq('Sales: still none before the wait is over', (select count(*) from tasks where booking_id = test.oclb('OCL-5') and task_type = 'request_open_to_sales'), 0::bigint);
-- a claim that ran out does not restart the wait
select test.ocl_claim('ocl_cs', 'OCL-5');
update request_claims set expires_at = now() - interval '1 minute' where booking_id = test.oclb('OCL-5');
update bookings set requested_at = now() - interval '16 minutes' where id = test.oclb('OCL-5');
select test.ok('Sales: once the wait is over it is open to them (the claim that ran out does not restart it)', (test.ocl_state('ocl_sales', 'OCL-5') ->> 'sales_waits') = 'false');
select app.job_requests_open_to_sales(now());
select test.ok('Sales: a task in the Sales queue tells them it is open', exists (select 1 from tasks where booking_id = test.oclb('OCL-5') and task_type = 'request_open_to_sales'
  and queue = 'sales' and status = 'open' and title like 'Answer Ocl R''s request for %: open to Sales now'));
select app.job_requests_open_to_sales(now());
select test.eq('Sales: one task, however often the job runs', (select count(*) from tasks where booking_id = test.oclb('OCL-5') and task_type = 'request_open_to_sales'), 1::bigint);
select test.eq('Sales: they take it like anyone', (test.ocl_claim('ocl_sales', 'OCL-5') #>> '{claim,mine}'), 'true');
select test.ok('Sales: the takeover of the expired claim is logged', exists (select 1 from booking_events where booking_id = test.oclb('OCL-5') and kind = 'claim_taken_over' and actor_user_id = test.id('ocl_sales')));
select test.eq('Sales: they send the offer', (test.ocl_va('ocl_sales', 'send_offer', 'OCL-5') ->> 'version'), '1');
select test.eq('Sales: the task is done with the answer', (select status from tasks where booking_id = test.oclb('OCL-5') and task_type = 'request_open_to_sales'), 'done');
select test.eq('Sales: the first offer still credits its sender (unchanged)', (select sales_staff_id from bookings where id = test.oclb('OCL-5')), test.id('ocl_sales'));
-- after the wait it is never Sales' alone: whoever claims first holds it
select test.eq('after the wait: customer service still claims an unclaimed request', (test.ocl_claim('ocl_cs', 'OCL-8') #>> '{claim,mine}'), 'true');
select test.ocl('ocl_cs', 'ops_do', 'request_release', jsonb_build_object('booking', test.oclb('OCL-8')));
select test.eq('after the wait: Sales claim it first', (test.ocl_claim('ocl_sales', 'OCL-8') #>> '{claim,mine}'), 'true');
select test.eq('after the wait: customer service cannot take a request Sales are answering', (test.ocl_claim('ocl_cs', 'OCL-8') #>> '{claim,by}'), test.id('ocl_sales')::text);
select test.throws('after the wait: nor send the offer on it', $$select test.ocl_va('ocl_cs', 'send_offer', 'OCL-8')$$, 'Being answered by Ocl Sales since%');
select test.throws('after the wait: nor take it over', $$select test.ocl_claim('ocl_cs', 'OCL-8', 'takeover')$$, '%only an Admin takes over%');
select test.eq('after the wait: an Admin can take it over', (test.ocl_claim('ocl_admin', 'OCL-8', 'takeover') #>> '{claim,mine}'), 'true');
update program_settings set request_sales_after_minutes = 0;
select test.ok('setting: 0 opens a request to Sales at once', (test.ocl_state('ocl_sales', 'OCL-2') ->> 'sales_waits') = 'false');
update program_settings set request_sales_after_minutes = 15;

-- ================================================================ 7. privileges
select test.throws('privileges: a browser session cannot claim', format($$set local role authenticated; select app.request_claim(%L, %L)$$, test.id('ocl_cs'), test.oclb('OCL-2')), 'permission denied%');
select test.throws('privileges: nor read the claims table', $$set local role authenticated; select count(*) from public.request_claims$$, 'permission denied%');
select test.throws('privileges: a renter cannot use the claim door', format($$select app.door(%L, 'aal1', 'ops_do', 'request_claim', %L::jsonb)$$, test.id('ocl_r'), jsonb_build_object('booking', test.oclb('OCL-2'))), 'Not permitted');
