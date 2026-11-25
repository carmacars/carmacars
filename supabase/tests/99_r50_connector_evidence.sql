-- 99: the Admin connector reads a dispute's evidence (migration 3870, release 50): list_comms (calls, texts, chats, emails
-- of a renter, oldest first, paged, card and ID numbers taken out), get_call_recording (the transcript and the recording as
-- a file for the web layer to sign, audited), get_id_check (audited), get_booking_invoice, list_chats with a conversation.
-- Read only, admin:read. Fixtures "q87".
select test.suite('99 r50 connector evidence');
select test.mk_user('q87_admin', 'admin');
select test.mk_owner('q87_o');
select test.mk_vehicle('q87_v', 'q87_o');
select test.mk_renter('q87_r');
update renters set mobile = '+16475558701' where id = test.id('renter:q87_r');
select test.mk_booking('CC-87001', 'q87_v', 'q87_r', '2026-10-01 10:00', '2026-10-05 10:00', 'closed');
create function test.q87call(p_key text, p_tool text, p jsonb) returns jsonb language sql as $$ select app.api_call(encode(sha256(p_key::bytea), 'hex'), p_tool, p) $$;
select app.api_key_create(test.id('q87_admin'), test.id('q87_admin'), 'q87 read', array['admin:read'], encode(sha256('q87-r'::bytea), 'hex'), 'cc_live_q8r_');
select app.api_key_create(test.id('q87_admin'), test.id('q87_admin'), 'q87 bookings', array['bookings:read'], encode(sha256('q87-b'::bytea), 'hex'), 'cc_live_q8b_');

insert into phone_threads (id, number, match_kind, renter_id) values (test.id('q87_th'), '+16475558701', 'renter', test.id('renter:q87_r'));
insert into phone_activity (id, thread_id, kind, direction, started_at, duration_seconds, transcript, renter_id)
values (test.id('q87_c1'), test.id('q87_th'), 'call', 'in', '2026-10-02 09:00-04', 120,
        '[{"who": "renter", "text": "my card is 4242 4242 4242 4242 and licence A1234-56789-01234"}]', test.id('renter:q87_r'));
insert into phone_activity (id, thread_id, kind, direction, started_at, body, renter_id, sent_by)
values (test.id('q87_t1'), test.id('q87_th'), 'text', 'out', '2026-10-02 10:00-04', 'Your car is ready', test.id('renter:q87_r'), test.id('q87_admin'));
insert into phone_activity (id, thread_id, kind, direction, started_at, duration_seconds)
values (test.id('q87_c2'), test.id('q87_th'), 'call', 'out', '2026-10-06 11:00-04', 60);
insert into outbound_calls (staff_user_id, to_number, staff_number, status, outcome, activity_id, recording_key, recording_seconds, transcript_text, started_at)
values (test.id('q87_admin'), '+16475558701', '+14165550100', 'completed', 'answered', test.id('q87_c2'), 'calls/twilio/' || test.id('q87_rec') || '.mp3', 58,
        'Staff: about the damage on return', '2026-10-06 11:00-04');
insert into messages (direction, channel, subject, body, to_address, renter_id, booking_id, template_code, status, occurred_at)
values ('outbound', 'email', 'Your check-out statement', 'The statement is attached.', 'q87_r@example.test', test.id('renter:q87_r'), test.id('booking:CC-87001'), null, 'delivered', '2026-10-06 12:00-04');
insert into chat_conversations (id, visitor_id, name, email, renter_id) values (test.id('q87_chat'), test.id('q87_chatv'), 'Q87', 'q87_r@example.test', test.id('renter:q87_r'));
insert into chat_messages (conversation_id, sender, body, at) select test.id('q87_chat'), case when i % 2 = 0 then 'staff' else 'visitor' end, 'message ' || i, timestamptz '2026-10-03 08:00-04' + i * interval '1 minute'
  from generate_series(1, 6) i;

-- ================================================================ 1. the rules
select test.eq('a key without admin:read is refused', test.q87call('q87-b', 'list_comms', '{"booking": "CC-87001"}') ->> 'status', '403');
select test.eq('booking or renter is required', test.q87call('q87-r', 'list_comms', '{}') ->> 'error', 'booking (CC-...) or renter (their id, user id, email or phone) is required');
select test.eq('an unknown booking', test.q87call('q87-r', 'list_comms', '{"booking": "CC-0000"}') ->> 'status', '404');
select test.eq('a wrong kind', test.q87call('q87-r', 'list_comms', '{"booking": "CC-87001", "kinds": ["fax"]}') ->> 'status', '400');

-- ================================================================ 2. list_comms
create temp table q87_all as select test.q87call('q87-r', 'list_comms', '{"booking": "CC-87001"}') -> 'result' as r;
select test.eq('every call, text, chat and email of the renter', (select (r ->> 'count')::integer from q87_all), 10);
select test.eq('oldest first: the incoming call', (select r #>> '{items,0,kind}' || '/' || (r #>> '{items,0,direction}') || '/' || (r #>> '{items,0,from}') from q87_all), 'call/in/+16475558701');
select test.ok('card and licence numbers are taken out of the transcript',
  (select r #>> '{items,0,transcript_text}' from q87_all) like '%[card number removed]%[ID number removed]%' and (select r::text from q87_all) not like '%4242%');
select test.eq('the site call: its staff member, outcome, transcript and a recording',
  (select x ->> 'staff' || '/' || (x ->> 'outcome') || '/' || (x ->> 'transcript_text') || '/' || (x ->> 'has_recording')
     from q87_all, jsonb_array_elements(r -> 'items') x where x ->> 'id' = test.id('q87_c2')::text), 'Q87 Admin/answered/Staff: about the damage on return/true');
select test.eq('a text with its sender', (select x ->> 'sender' || '/' || (x ->> 'body') from q87_all, jsonb_array_elements(r -> 'items') x where x ->> 'kind' = 'sms'), 'Q87 Admin/Your car is ready');
select test.eq('the email with its subject and status', (select x ->> 'subject' || '/' || (x ->> 'status') from q87_all, jsonb_array_elements(r -> 'items') x where x ->> 'kind' = 'email'), 'Your check-out statement/delivered');
select test.eq('found by the renter''s phone as well', test.q87call('q87-r', 'list_comms', '{"renter": "647 555 8701", "kinds": ["call"]}') #>> '{result,count}', '2');
select test.eq('found by the renter''s email, emails only', test.q87call('q87-r', 'list_comms', '{"renter": "Q87_R@example.test", "kinds": "email"}') #>> '{result,count}', '1');
select test.eq('from and to narrow it', test.q87call('q87-r', 'list_comms', '{"booking": "CC-87001", "from": "2026-10-06T00:00:00-04:00"}') #>> '{result,count}', '2');
create temp table q87_p1 as select test.q87call('q87-r', 'list_comms', '{"booking": "CC-87001", "limit": 4}') -> 'result' as r;
create temp table q87_p2 as select test.q87call('q87-r', 'list_comms', jsonb_build_object('booking', 'CC-87001', 'limit', 4, 'cursor', (select r ->> 'next_cursor' from q87_p1))) -> 'result' as r;
create temp table q87_p3 as select test.q87call('q87-r', 'list_comms', jsonb_build_object('booking', 'CC-87001', 'limit', 4, 'cursor', (select r ->> 'next_cursor' from q87_p2))) -> 'result' as r;
select test.eq('pages of 4, 4 and 2, the last without a cursor',
  (select r ->> 'count' from q87_p1) || ',' || (select r ->> 'count' from q87_p2) || ',' || (select r ->> 'count' from q87_p3) || ',' || coalesce((select r ->> 'next_cursor' from q87_p3), 'none'), '4,4,2,none');
select test.eq('no item twice across the pages', (select count(distinct x ->> 'id') from (select r from q87_p1 union all select r from q87_p2 union all select r from q87_p3) p, jsonb_array_elements(p.r -> 'items') x), 10::bigint);
select test.ok('logged in api_calls', exists (select 1 from api_calls c where c.tool = 'list_comms' and c.ok and c.target = 'CC-87001'));

-- ================================================================ 3. get_call_recording
create temp table q87_rec as select test.q87call('q87-r', 'get_call_recording', jsonb_build_object('call', test.id('q87_c2'))) -> 'result' as r;
select test.eq('the recording is a file for the web layer to sign', (select r #>> '{recording,_file,bucket}' || '/' || (r #>> '{recording,_file,key}') from q87_rec), 'documents/calls/twilio/' || test.id('q87_rec') || '.mp3');
select test.eq('with the full transcript', (select r ->> 'transcript_text' from q87_rec), 'Staff: about the damage on return');
select test.ok('the access is in the audit log', exists (select 1 from audit_log l where l.action = 'call_recording_access' and l.entity_id = test.id('q87_c2')::text and l.actor_user_id = test.id('q87_admin')));
select test.eq('a Quo call without a copy: the transcript, no file', (select (r ->> 'recording') is null and (r ->> 'transcript_text') like 'renter: my card is [card number removed]%'
  from (select test.q87call('q87-r', 'get_call_recording', jsonb_build_object('call', test.id('q87_c1'))) -> 'result' r) x), true);
select test.eq('an unknown call', test.q87call('q87-r', 'get_call_recording', jsonb_build_object('call', test.id('q87_none'))) ->> 'status', '404');

-- ================================================================ 4. the other reads
select test.eq('get_id_check answers for the booking', test.q87call('q87-r', 'get_id_check', '{"booking": "CC-87001"}') #>> '{result,booking}', 'CC-87001');
select test.ok('ID image access is in the audit log', exists (select 1 from audit_log l where l.action = 'id_images_access' and l.entity_id = test.id('booking:CC-87001')::text));
create temp table q87_inv as select test.q87call('q87-r', 'get_booking_invoice', '{"booking": "CC-87001"}') -> 'result' as r;
select test.ok('the invoice: the base rate and the HST split', (select (r #>> '{totals,base_rate_cents}')::bigint > 0
  and (r #>> '{totals,total_cents}')::bigint = (r #>> '{totals,subtotal_cents}')::bigint + (r #>> '{totals,hst_cents}')::bigint and r #>> '{lines,0,category}' = 'base_rate' from q87_inv));
select test.eq('list_chats with a conversation: every message', test.q87call('q87-r', 'list_chats', jsonb_build_object('conversation', test.id('q87_chat'))) #>> '{result,conversations,0,messages,5,body}', 'message 6');
select test.eq('list_chats with a renter', test.q87call('q87-r', 'list_chats', '{"renter": "q87_r@example.test"}') #>> '{result,count}', '1');
select test.ok('list_chats without them is the list as before', test.q87call('q87-r', 'list_chats', '{"limit": 1}') #> '{result,items}' is not null);
select test.ok('get_agreement still answers', (test.q87call('q87-r', 'get_agreement', '{"booking": "CC-87001"}') ->> 'ok')::boolean);
select test.eq('the redaction keeps phone numbers and amounts', app.comms_redact('call 647-555-0199 about $1200.00'), 'call 647-555-0199 about $1200.00');

-- ================================================================ 5. the Stripe payer (3871): matched by email, phone or card fingerprint
insert into payment_method_secrets (payment_method_id, processor, fingerprint) values (test.id('card:q87_r'), 'stripe', 'fpQ87xyz');
create temp table q87_pm as select public.server_stripe_payer_match(jsonb_build_array(
  jsonb_build_object('id', 'pi_mail', 'at', '2026-10-01T12:00:00Z', 'emails', jsonb_build_array('Q87_R@EXAMPLE.TEST'), 'phones', '[]'::jsonb),
  jsonb_build_object('id', 'pi_fp', 'at', extract(epoch from timestamptz '2026-10-02 12:00Z'), 'emails', '[]'::jsonb, 'phones', '[]'::jsonb, 'fingerprint', 'fpQ87xyz'),
  jsonb_build_object('id', 'pi_tel', 'emails', '[]'::jsonb, 'phones', jsonb_build_array('(647) 555-8701')),
  jsonb_build_object('id', 'pi_none', 'emails', jsonb_build_array('nobody@example.test')))) as r;
select test.eq('matched by email, with the booking around the payment and its open amounts',
  (select (r #>> '{pi_mail,renters,0,matched_by,0}') || '/' || (r #>> '{pi_mail,bookings,0,booking_number}') || '/' || ((r #> '{pi_mail,bookings,0,open}') ? 'balance_cents')::text from q87_pm), 'email/CC-87001/true');
select test.eq('matched by the card fingerprint', (select r #>> '{pi_fp,renters,0,matched_by,0}' from q87_pm), 'card_fingerprint');
select test.eq('matched by the phone', (select r #>> '{pi_tel,renters,0,matched_by,0}' from q87_pm), 'phone');
select test.eq('no match', (select (r #>> '{pi_none,matched}') || '/' || jsonb_array_length(r #> '{pi_none,renters}') from q87_pm), 'false/0');
select test.ok('only the server may ask', not has_function_privilege('authenticated', 'public.server_stripe_payer_match(jsonb)', 'execute'));
