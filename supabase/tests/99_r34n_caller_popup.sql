-- 99: migration 0800 (release 34, part N): the caller pop-up and renter notes. An incoming call to the CarmaCars number is
-- matched to the renter on the E.164 number and shown live to Admins and customer service with the booking, balance,
-- deposit, open requests and the last notes; an unknown number shows as unknown; notes are added by staff, removed only by
-- an Admin with a reason, never edited, and audited. Fixtures start with "zcp"; every address is example.test.
select test.suite('99 r34n caller pop-up and renter notes (0800)');
grant usage on schema test to service_role;

select test.mk_user('zcp_admin', 'admin');
select test.mk_user('zcp_cs', 'va', 'cs');
select test.mk_user('zcp_fleet', 'va', 'fleet');
select test.mk_user('zcp_sales', 'va', 'sales');
select test.mk_owner('zcp_o');
select test.mk_vehicle('ZCPA', 'zcp_o');
select test.mk_renter('zcp_r');
select test.mk_renter('zcp_old');
update renters set mobile = '(289) 555-0871' where id = test.id('renter:zcp_r');
update renters set mobile = '289 555 0872' where id = test.id('renter:zcp_old');
create function test.zcpd(p_days integer, p_hour text default '10:00') returns text language sql stable as $$
  select to_char((now() at time zone 'America/Toronto')::date + p_days, 'YYYY-MM-DD') || ' ' || p_hour $$;
select test.mk_booking('ZCP-1', 'ZCPA', 'zcp_r', test.zcpd(-1), test.zcpd(3), 'on_rent');
-- the old renter's only booking ended long ago: outside the staff window
select test.mk_booking('ZCP-OLD', 'ZCPA', 'zcp_old', '2025-01-05 10:00', '2025-01-07 10:00', 'closed');
update bookings set checked_in_at = return_at where booking_number = 'ZCP-OLD';
insert into deposits (booking_id, amount_cents, method, status, taken_at) values (test.id('booking:ZCP-1'), 100000, 'card_hold', 'held', now() - interval '1 day');
insert into booking_info_requests (booking_id, question, asked_by, reply_by) values (test.id('booking:ZCP-1'), 'Send a photo of the fuel gauge', test.id('zcp_admin'), now() + interval '1 day');

create function test.zcp_call(p_id text, p_number text, p_type text default 'call.ringing', p_extra jsonb default '{}'::jsonb) returns jsonb language sql as $$
  select app.server_phone_event(jsonb_build_object('type', p_type, 'event_id', 'EV' || p_id || p_type, 'call_id', p_id, 'quo_id', p_id, 'direction', 'in',
    'their_number', p_number, 'at', now(), 'status', null) || p_extra) $$;
create function test.zcp_live(p_user text, p_call text default 'va_read') returns jsonb language sql as $$
  select app.door(test.id(p_user), 'aal2', p_call, 'caller_live', '{}'::jsonb) $$;

-- ================================================================ 1. the pop-up
select test.zcp_call('ACRN1', '+1 289-555-0871');
create table test.zcp_l as select jsonb_build_object('calls', jsonb_build_array(x)) as j from jsonb_array_elements(test.zcp_live('zcp_cs') -> 'calls') x where x ->> 'number' = '+12895550871';
select test.eq('pop-up: customer service sees the ringing call, matched to the renter on the E.164 number',
  (select (j #>> '{calls,0,kind}') || '/' || (j #>> '{calls,0,number}') || '/' || (j #>> '{calls,0,live}') || '/' || (j #>> '{calls,0,renter,name}') from test.zcp_l
     where j -> 'calls' @> jsonb_build_array(jsonb_build_object('number', '+12895550871'))), 'renter/+12895550871/true/Zcp R');
select test.eq('pop-up: the active booking with its car', (select (j #>> '{calls,0,renter,booking,number}') || '/' || (j #>> '{calls,0,renter,booking,active}') from test.zcp_l), 'ZCP-1/true');
select test.eq('pop-up: the deposit held', (select (j #>> '{calls,0,renter,deposit,state}') || '/' || (j #>> '{calls,0,renter,deposit,held_cents}') from test.zcp_l), 'held/100000');
select test.ok('pop-up: the balance owed is a number of cents', (select (j #>> '{calls,0,renter,balance,owed_cents}')::bigint >= 0 from test.zcp_l));
select test.ok('pop-up: the open question to the renter is listed', (select j #> '{calls,0,renter,requests}' @> '[{"kind": "question", "booking_number": "ZCP-1"}]' from test.zcp_l));
select test.eq('pop-up: notes start empty', (select jsonb_array_length(j #> '{calls,0,renter,notes}') from test.zcp_l), 0);
select test.eq('pop-up: an Admin sees it too', (select jsonb_array_length(test.zcp_live('zcp_admin', 'admin_read') -> 'calls') >= 1), true);
select test.lives('pop-up: Fleet staff get it too (0970, the Fleet lane)', $$ select test.zcp_live('zcp_fleet') $$);
select test.throws('pop-up: Sales do not get it', $$ select test.zcp_live('zcp_sales') $$, '%Admins, customer service and Fleet%');

-- an unknown number
select test.zcp_call('ACRN2', '+12895550873');
select test.eq('pop-up: an unknown number is an unknown caller, with its thread for Create lead', (
  select (x ->> 'kind') || '/' || (x ->> 'renter' is null)::text || '/' || (x ->> 'thread_id' is not null)::text
    from jsonb_array_elements(test.zcp_live('zcp_cs') -> 'calls') x where x ->> 'number' = '+12895550873'), 'unknown/true/true');
select test.eq('pop-up: Create lead from the pop-up (0085 phone_create_lead) makes it a lead',
  (select app.door(test.id('zcp_cs'), 'aal2', 'va_do', 'phone_create_lead', jsonb_build_object('id', (select id from phone_threads where number = '+12895550873'), 'name', 'Una Known')) ->> 'ok'), 'true');
select test.eq('pop-up: the next read names the lead', (select (x ->> 'kind') || '/' || (x ->> 'who') from jsonb_array_elements(test.zcp_live('zcp_cs') -> 'calls') x where x ->> 'number' = '+12895550873'), 'lead/Una Known');

-- the call ends: kept for 3 minutes (live false), then gone
select test.zcp_call('ACRN1', '+12895550871', 'call.completed', jsonb_build_object('status', 'completed', 'answered_at', now(), 'completed_at', now(), 'duration', 40));
select test.eq('pop-up: an ended call stays for the note, not live', (select x ->> 'live' from jsonb_array_elements(test.zcp_live('zcp_cs') -> 'calls') x where x ->> 'number' = '+12895550871'), 'false');
update phone_activity set ended_at = now() - interval '5 minutes', updated_at = now() - interval '5 minutes' where quo_id = 'ACRN1';
select test.eq('pop-up: 3 minutes after the end it is gone', (select count(*) from jsonb_array_elements(test.zcp_live('zcp_cs') -> 'calls') x where x ->> 'number' = '+12895550871'), 0::bigint);
update phone_activity set started_at = now() - interval '40 minutes' where quo_id = 'ACRN2';
select test.eq('pop-up: a call Quo never closed drops after 30 minutes', (select count(*) from jsonb_array_elements(test.zcp_live('zcp_cs') -> 'calls') x where x ->> 'number' = '+12895550873'), 0::bigint);
update program_settings set phone_enabled = false;
select test.zcp_call('ACRN3', '+12895550871');
select test.eq('pop-up: with the phone line off, nothing', (select jsonb_array_length(test.zcp_live('zcp_cs') -> 'calls')), 0);
update program_settings set phone_enabled = true;

-- ================================================================ 2. notes
create table test.zcp_n as select app.door(test.id('zcp_cs'), 'aal2', 'va_do', 'renter_note_add',
  jsonb_build_object('renter_id', test.id('renter:zcp_r'), 'body', '  Asked to return a day early; told them to call Fleet.  ', 'call_id', (select id from phone_activity where quo_id = 'ACRN1'))) as j;
select test.eq('notes: customer service adds one, stamped with their name and role, trimmed, tied to the booking of the call',
  (select (j #>> '{note,author}') || '/' || (j #>> '{note,role}') || '/' || (j #>> '{note,body}') || '/' || (j #>> '{note,booking_number}') || '/' || (j #>> '{note,from_call}') from test.zcp_n),
  'Zcp Cs/cs/Asked to return a day early; told them to call Fleet./ZCP-1/true');
select test.ok('notes: timestamped', (select (j #>> '{note,at}')::timestamptz > now() - interval '1 minute' from test.zcp_n));
select app.door(test.id('zcp_admin'), 'aal2', 'admin_do', 'renter_note_add', jsonb_build_object('renter_id', test.id('renter:zcp_r'), 'body', 'Second note', 'booking_number', 'zcp-1'));
select test.eq('notes: the list is newest first, with the Admin''s role', (select string_agg((x ->> 'body') || ':' || (x ->> 'role'), '|') from jsonb_array_elements(
  app.door(test.id('zcp_cs'), 'aal2', 'va_read', 'renter_notes', jsonb_build_object('renter_id', test.id('renter:zcp_r'))) -> 'notes') x), 'Second note:admin|Asked to return a day early; told them to call Fleet.:cs');
select test.eq('notes: the pop-up shows the last ones', (select jsonb_array_length(app.caller_renter(test.id('renter:zcp_r')) -> 'notes')), 2);
select test.eq('notes: staff cannot remove', (select app.door(test.id('zcp_cs'), 'aal2', 'va_read', 'renter_notes', jsonb_build_object('renter_id', test.id('renter:zcp_r'))) ->> 'can_remove'), 'false');
select test.throws('notes: an empty note is refused', format($$ select app.door(%L, 'aal2', 'va_do', 'renter_note_add', jsonb_build_object('renter_id', %L, 'body', '   ')) $$, test.id('zcp_cs'), test.id('renter:zcp_r')), '%Write the note%');
select test.throws('notes: staff cannot remove one', format($$ select app.door(%L, 'aal2', 'va_do', 'renter_note_remove', jsonb_build_object('id', %L, 'reason', 'typo')) $$,
  test.id('zcp_cs'), (select j #>> '{note,id}' from test.zcp_n)), '%Only an Admin%');
select test.throws('notes: a note is never edited, even by the database owner', format($$ update renter_notes set body = 'changed' where id = %L $$, (select j #>> '{note,id}' from test.zcp_n)), '%cannot be changed%');
select test.throws('notes: an Admin gives a reason', format($$ select app.door(%L, 'aal2', 'admin_do', 'renter_note_remove', jsonb_build_object('id', %L)) $$,
  test.id('zcp_admin'), (select j #>> '{note,id}' from test.zcp_n)), '%reason%');
select app.door(test.id('zcp_admin'), 'aal2', 'admin_do', 'renter_note_remove', jsonb_build_object('id', (select j #>> '{note,id}' from test.zcp_n), 'reason', 'Wrong renter'));
select test.eq('notes: an Admin removes one; it is kept, marked, and no longer listed',
  (select (removed_at is not null)::text || '/' || removed_reason from renter_notes where id = (select (j #>> '{note,id}')::uuid from test.zcp_n)) || '/'
  || (select jsonb_array_length(app.renter_notes_list(test.id('renter:zcp_r')))), 'true/Wrong renter/1');
select test.eq('notes: every change is in the audit log (two added, one removed), with who did it',
  (select count(*) filter (where action = 'INSERT') || '/' || count(*) filter (where action = 'UPDATE' and after ->> 'removed_reason' = 'Wrong renter') || '/'
          || bool_and(actor_user_id is not null)
     from audit_log where entity_table = 'renter_notes' and entity_id in (select id::text from renter_notes where renter_id = test.id('renter:zcp_r'))), '2/1/true');
select test.eq('notes: no browser role reads or writes the table', has_table_privilege('authenticated', 'renter_notes', 'insert') or has_table_privilege('anon', 'renter_notes', 'select'), false);

-- ================================================================ 3. who sees whose notes
select test.throws('notes: Fleet outside the renter''s window cannot read them', format($$ select app.door(%L, 'aal2', 'va_read', 'renter_notes', jsonb_build_object('renter_id', %L)) $$,
  test.id('zcp_fleet'), test.id('renter:zcp_old')), '%Open this renter%');
select test.throws('notes: customer service outside the window, with no call, cannot either', format($$ select app.door(%L, 'aal2', 'va_read', 'renter_notes', jsonb_build_object('renter_id', %L)) $$,
  test.id('zcp_cs'), test.id('renter:zcp_old')), '%Open this renter%');
select test.zcp_call('ACRN4', '2895550872');
select test.eq('notes: a call from the renter opens their notes to customer service (the pop-up)',
  (select jsonb_typeof(app.door(test.id('zcp_cs'), 'aal2', 'va_read', 'renter_notes', jsonb_build_object('renter_id', test.id('renter:zcp_old'))) -> 'notes')), 'array');
select test.throws('notes: but not to Fleet', format($$ select app.door(%L, 'aal2', 'va_read', 'renter_notes', jsonb_build_object('renter_id', %L)) $$,
  test.id('zcp_fleet'), test.id('renter:zcp_old')), '%Open this renter%');
select app.door(test.id('zcp_cs'), 'aal2', 'va_do', 'caller_open', jsonb_build_object('call_id', (select id from phone_activity where quo_id = 'ACRN4')));
select test.eq('open from the pop-up: logged for 24 hours with the reason', (select count(*) from data_access_log where user_id = test.id('zcp_cs') and renter_id = test.id('renter:zcp_old')
  and reason like 'Incoming call%' and granted_until > now() + interval '23 hours'), 1::bigint);
select test.eq('open from the pop-up: the renter record opens for them', (select app.door(test.id('zcp_cs'), 'aal2', 'va_read', 'renter', jsonb_build_object('id', test.id('renter:zcp_old'))) ->> 'legal_name'), 'Zcp Old');
select test.throws('open from the pop-up: only for a call from a renter', format($$ select app.door(%L, 'aal2', 'va_do', 'caller_open', jsonb_build_object('call_id', %L)) $$,
  test.id('zcp_cs'), (select id from phone_activity where quo_id = 'ACRN2')), '%not one from a renter%');
select test.throws('open from the pop-up: not for Sales', format($$ select app.door(%L, 'aal2', 'va_do', 'caller_open', jsonb_build_object('call_id', %L)) $$,
  test.id('zcp_sales'), (select id from phone_activity where quo_id = 'ACRN4')), '%Admins, customer service and Fleet%');
select test.eq('the door still answers what it did before', (select app.door(test.id('zcp_cs'), 'aal2', 'va_read', 'phone_inbox', '{}'::jsonb) ? 'threads'), true);

-- leave no unprocessed events for the suites after this one (99_staff_alerts counts the Admin digest)
select app.process_events(1000) >= 0 as processed;
