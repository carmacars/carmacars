-- 99: migration 2995 (release 48): calls through the site open the caller pop-up (incoming and outgoing, Admin and every
-- office role whose browser rings), a call to the business number keeps who answered and its recording, transcript and
-- summary, the history carries them, the pop-up's live topic bumps, and the 60-day backfill looks each call up once.
-- Fixtures start with "zsc"; every address is example.test.
select test.suite('99 r48 site calls (2995)');
update app_events set processed_at = now() where processed_at is null;
create temp table zsc_ps as select id, require_staff_two_step t, phone_ai_summaries s, phone_inbound_ring r, phone_enabled e from program_settings;
update program_settings set require_staff_two_step = false, phone_ai_summaries = true, phone_inbound_ring = 'cs, sales', phone_enabled = true where id is not null;

select test.mk_user('zsc_admin', 'admin');
select test.mk_user('zsc_cs', 'va', 'cs');
select test.mk_user('zsc_sales', 'va', 'sales');
select test.mk_user('zsc_fin', 'va', 'finance');
select test.mk_user('zsc_field', 'field');
select test.mk_owner('zsc_own');
select test.mk_vehicle('ZSCA', 'zsc_own');
select test.mk_renter('zsc_rita');
update renters set mobile = '(647) 555-0381', legal_name = 'Zsc Rita' where id = test.id('renter:zsc_rita');
select test.mk_booking('ZSC-1', 'ZSCA', 'zsc_rita', '2027-03-01 10:00', '2027-03-04 10:00', 'confirmed');

create function test.zsc_live(p_user text, p_call text default 'va_read') returns jsonb language sql as $$
  select app.door(test.id(p_user), 'aal2', p_call, 'caller_live', '{}'::jsonb) $$;
create function test.zsc_has(p_user text, p_id uuid, p_call text default 'va_read') returns boolean language sql as $$
  select exists (select 1 from jsonb_array_elements(test.zsc_live(p_user, p_call) -> 'calls') x where x ->> 'id' = p_id::text) $$;

-- ================================================================ 1. a call placed from the site (the browser phone)
create temp table zsc_out as select (app.server_twilio_browser_call_start(jsonb_build_object('user_id', test.id('zsc_cs'), 'number', '+16475550381', 'booking_number', 'ZSC-1')) ->> 'id')::uuid id;
select test.eq('outgoing: the caller''s own pop-up opens at once, live, matched to the renter',
  (select x ->> 'direction' || '/' || (x ->> 'live') || '/' || (x ->> 'kind') || '/' || (x #>> '{renter,name}')
     from jsonb_array_elements(test.zsc_live('zsc_cs') -> 'calls') x where x ->> 'id' = (select id::text from zsc_out)), 'out/true/renter/Zsc Rita');
select test.eq('outgoing: nobody else gets that call (Admins and Sales neither)',
  (select test.zsc_has('zsc_admin', id, 'admin_read')::text || '/' || test.zsc_has('zsc_sales', id)::text from zsc_out), 'false/false');
select app.server_twilio_call_event(jsonb_build_object('id', id, 'kind', 'staff_answered', 'call_sid', 'CA' || repeat('3', 32))) from zsc_out;
select app.server_twilio_call_event(jsonb_build_object('id', id, 'kind', 'dial', 'status', 'completed', 'duration', '75')) from zsc_out;
select test.eq('outgoing: ended, the call stays for the note (not live)',
  (select x ->> 'live' from jsonb_array_elements(test.zsc_live('zsc_cs') -> 'calls') x where x ->> 'id' = (select id::text from zsc_out)), 'false');
select test.ok('outgoing: the renter''s page opens from that call (logged as every pop-up open)',
  (select app.door(test.id('zsc_cs'), 'aal2', 'va_do', 'caller_open', jsonb_build_object('call_id', id)) ->> 'renter_id' = test.id('renter:zsc_rita')::text from zsc_out));
-- Sales see the number masked in their own call
create temp table zsc_out2 as select (app.server_twilio_browser_call_start(jsonb_build_object('user_id', test.id('zsc_sales'), 'number', '+16475550382')) ->> 'id')::uuid id;
select test.eq('outgoing: a Sales rep''s pop-up masks the number',
  (select (x ->> 'number' like '%•%')::text || '/' || (x ->> 'display' like '%•%')::text from jsonb_array_elements(test.zsc_live('zsc_sales') -> 'calls') x where x ->> 'id' = (select id::text from zsc_out2)), 'true/true');
-- a call that never connected leaves the pop-up after two minutes
update outbound_calls set started_at = now() - interval '5 minutes' where id = (select id from zsc_out2);
select test.eq('outgoing: a call that never started is not live for ever', (select test.zsc_has('zsc_sales', id)::text from zsc_out2), 'false');

-- ================================================================ 2. who gets the pop-up
select test.lives('pop-up: Finance staff too (every office role)', $$ select test.zsc_live('zsc_fin') $$);
select test.throws('pop-up: not field staff (no office portal)', format($$ select app.caller_live(%L, '{}') $$, test.id('zsc_field')), '%Admins and office staff%');
select test.lives('call helper: Sales read it', format($$ select app.call_helper(%L, '{}') $$, test.id('zsc_sales')));

-- ================================================================ 3. a call to the business number (the browsers ring)
select app.server_phone_event(jsonb_build_object('event_id', 'twilio:CA' || repeat('4', 32) || ':call.ringing', 'type', 'call.ringing', 'call_id', 'CA' || repeat('4', 32),
  'quo_id', 'CA' || repeat('4', 32), 'direction', 'in', 'their_number', '+16475550381', 'status', 'ringing', 'at', now()));
create temp table zsc_in as select id from phone_activity where quo_id = 'CA' || repeat('4', 32);
select test.eq('incoming: Sales (whose browser rings) and customer service and Admins see it ringing; Finance does not',
  (select test.zsc_has('zsc_sales', id)::text || '/' || test.zsc_has('zsc_cs', id)::text || '/' || test.zsc_has('zsc_admin', id, 'admin_read')::text || '/' || test.zsc_has('zsc_fin', id)::text from zsc_in),
  'true/true/true/false');
select test.eq('incoming: the activity id by its CallSid', (select app.server_twilio_inbound_id('CA' || repeat('4', 32)) = id from zsc_in), true);
select app.server_twilio_inbound(jsonb_build_object('kind', 'answered', 'call_sid', 'CA' || repeat('4', 32), 'user_id', test.id('zsc_sales')));
select test.eq('answered: on the phone now, by the Sales rep who took it',
  (select (a.answered_at is not null)::text || '/' || (a.sent_by = test.id('zsc_sales'))::text from phone_activity a join zsc_in using (id)), 'true/true');
select test.eq('answered: the pop-up says so', (select x ->> 'answered_at' is not null from jsonb_array_elements(test.zsc_live('zsc_sales') -> 'calls') x where x ->> 'id' = (select id::text from zsc_in)), true);
select test.throws('recording: only this call''s key', format($$ select app.server_twilio_inbound(jsonb_build_object('kind', 'recording', 'call_sid', %L, 'key', 'calls/twilio/%s.mp3')) $$,
  'CA' || repeat('4', 32), gen_random_uuid()), '%Not this call%');
select app.server_twilio_inbound(jsonb_build_object('kind', 'recording', 'call_sid', 'CA' || repeat('4', 32), 'recording_sid', 'RE' || repeat('b', 32), 'key', 'calls/twilio/' || id || '.mp3', 'seconds', '64')) from zsc_in;
select test.eq('recording: Play recording on the call''s history entry',
  (select a.recordings -> 0 ->> 'url' || '|' || (a.recordings -> 0 ->> 'source') from phone_activity a join zsc_in using (id)),
  (select '/api/staff/phone/recording?id=' || id || '|site' from zsc_in));
select test.eq('recording: customer service may play it (our private copy)', (select app.server_phone_recording(test.id('zsc_cs'), id) from zsc_in), (select 'calls/twilio/' || id || '.mp3' from zsc_in));
select test.ok('speech to text: the incoming call is due', (select app.server_twilio_transcribe_due(5) -> 'items' @> jsonb_build_array(jsonb_build_object('id', id)) from zsc_in));
select app.server_twilio_transcript(jsonb_build_object('id', id, 'ok', true, 'text', 'Hi, I want to   extend my booking.', 'neurons', 30)) from zsc_in;
select test.eq('transcript: on the call, and our summary is due',
  (select (a.transcript -> 0 ->> 'text') || '/' || (a.summary_due_at is not null)::text from phone_activity a join zsc_in using (id)), 'Hi, I want to extend my booking./true');
update phone_activity set ai_summary = 'The renter wants to extend.', ended_at = now(), duration_seconds = 64 where id = (select id from zsc_in);

-- ================================================================ 4. the renter's history carries it
create temp table zsc_act as select app.renter_activity(test.id('zsc_admin'), jsonb_build_object('renter_id', test.id('renter:zsc_rita'), 'type', 'call')) j;
select test.eq('history: the call with its recording, transcript and summary',
  (select (x #>> '{extra,recordings,0,source}') || '/' || (x #>> '{extra,transcript,0,text}') || '/' || (x #>> '{extra,summary}')
     from zsc_act, jsonb_array_elements(j -> 'items') x where x ->> 'k' = 'call:' || (select id from zsc_in)), 'site/Hi, I want to extend my booking./The renter wants to extend.');

-- ================================================================ 5. live: the pop-up's topic
select test.ok('live: office staff and Admins get the calls topic', (select app.server_live_topics(test.id('zsc_cs'), array['staff:calls']) ? 'staff:calls'
  and app.server_live_topics(test.id('zsc_admin'), array['staff:calls']) ? 'staff:calls'));
create temp table zsc_v as select coalesce((public.live_poll(array[app.live_topic('staff:calls')]) ->> app.live_topic('staff:calls')), '') v;
update phone_activity set status = 'completed' where id = (select id from zsc_in);
select test.ok('live: a call that changes bumps the topic', (select coalesce((public.live_poll(array[app.live_topic('staff:calls')]) ->> app.live_topic('staff:calls')), '') <> v from zsc_v));

-- ================================================================ 6. the backfill: the last 60 days, once each
create temp table zsc_old as select (app.server_twilio_browser_call_start(jsonb_build_object('user_id', test.id('zsc_cs'), 'number', '+16475550381')) ->> 'id')::uuid id;
update outbound_calls set call_sid = 'CA' || repeat('5', 32), status = 'completed', duration_seconds = 40, ended_at = now() - interval '2 days', started_at = now() - interval '2 days'
 where id = (select id from zsc_old);
insert into phone_activity (thread_id, kind, direction, quo_id, started_at, ended_at, duration_seconds, renter_id)
select t.id, 'call', 'in', 'ACZSC1', now() - interval '3 days', now() - interval '3 days', 120, t.renter_id from phone_threads t where t.number = '+16475550381';
create temp table zsc_due as select app.server_call_backfill_due(20) d;
select test.ok('backfill: the site call without its copy is looked up at Twilio', (select d -> 'twilio' @> jsonb_build_array(jsonb_build_object('kind', 'out', 'id', id)) from zsc_due, zsc_old));
select test.ok('backfill: the Quo call missing its media is looked up at Quo', (select d -> 'quo' @> '[{"call_id": "ACZSC1", "recording": true, "transcript": true, "summary": true}]' from zsc_due));
select app.server_call_backfill_done(jsonb_build_object('ref', 'out:' || id, 'result', 'no recording at twilio')) from zsc_old;
select app.server_call_backfill_done(jsonb_build_object('ref', 'quo:' || (select id from phone_activity where quo_id = 'ACZSC1'), 'result', 'found at quo',
  'quo', jsonb_build_object('recordings', '[{"id": "RC1", "url": "https://files.example.test/r.mp3", "duration": 118}]'::jsonb,
                            'transcript', '[{"who": "them", "text": "Is the car ready?"}]'::jsonb, 'summary', '[]'::jsonb, 'next_steps', '[]'::jsonb)));
select test.eq('backfill: Quo''s finds kept on the call; no Quo summary, so ours is due',
  (select (a.recordings -> 0 ->> 'url') || '/' || (a.transcript -> 0 ->> 'text') || '/' || (a.summary_due_at is not null)::text from phone_activity a where a.quo_id = 'ACZSC1'),
  'https://files.example.test/r.mp3/Is the car ready?/true');
create temp table zsc_due2 as select app.server_call_backfill_due(20) d;
select test.eq('backfill: each call is looked up once',
  (select (d -> 'twilio' @> jsonb_build_array(jsonb_build_object('id', (select id from zsc_old))))::text || '/' || (d -> 'quo' @> '[{"call_id": "ACZSC1"}]')::text from zsc_due2), 'false/false');
select test.throws('backfill: only our own references', $$ select app.server_call_backfill_done('{"ref": "x:1"}') $$, '%Not a call reference%');
select test.ok('the server doors are for the server only',
  not has_function_privilege('authenticated', 'public.server_twilio_inbound(jsonb)', 'execute') and not has_function_privilege('anon', 'public.server_call_backfill_due(integer)', 'execute')
  and has_function_privilege('service_role', 'public.server_call_backfill_done(jsonb)', 'execute'));

update program_settings s set require_staff_two_step = x.t, phone_ai_summaries = x.s, phone_inbound_ring = x.r, phone_enabled = x.e from zsc_ps x where s.id = x.id;
