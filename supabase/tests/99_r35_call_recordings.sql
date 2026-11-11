-- 99: release 35 gap fix (migration 1880): calls from the site's Twilio Call button are recorded, copied to our storage,
-- transcribed within the background share of the free AI allowance (or the next day), and land on the renter's, lead's and
-- booking's history like Quo's calls (transcript, summary due, intent). Fixtures start with "crx"; every address is example.test.
select test.suite('99 r35 call recordings');
update app_events set processed_at = now() where processed_at is null;
create temp table crx_ps as select id, require_staff_two_step t, phone_twilio_delete_recording d, phone_ai_summaries s from program_settings;
update program_settings set require_staff_two_step = false, phone_ai_summaries = true where id is not null;

select test.mk_user('crx_admin', 'admin');
select test.mk_user('crx_cs', 'va', 'cs');
select test.mk_user('crx_sales', 'va', 'sales');
select test.mk_user('crx_field', 'field');
update users set phone = '+16475550261' where id = test.id('crx_sales');
select test.mk_owner('crx_own');
select test.mk_vehicle('CRXA', 'crx_own');
select test.mk_renter('crx_rita');
update renters set mobile = '(647) 555-0299', legal_name = 'Crx Rita' where id = test.id('renter:crx_rita');
select test.mk_booking('CRX-1', 'CRXA', 'crx_rita', '2027-03-01 10:00', '2027-03-04 10:00', 'confirmed');

create temp table crx_call as select (app.server_twilio_call_start(jsonb_build_object('user_id', test.id('crx_sales'), 'number', '+16475550299', 'booking_number', 'CRX-1')) ->> 'id')::uuid id;
select app.server_twilio_call_event(jsonb_build_object('id', id, 'kind', 'started', 'call_sid', 'CA' || repeat('2', 32))) from crx_call;
select test.eq('the voice webhook records by default', (select app.server_twilio_call_get(id) ->> 'record' from crx_call), 'true');
select app.server_twilio_call_event(jsonb_build_object('id', id, 'kind', 'staff_answered')) from crx_call;
select app.server_twilio_call_event(jsonb_build_object('id', id, 'kind', 'dial', 'status', 'completed', 'duration', '95')) from crx_call;

-- ================================================================ storing
select test.throws('only our own key form is kept', $$select app.server_twilio_recording(jsonb_build_object('id', (select id from crx_call), 'key', 'identity/x.jpg'))$$, '%Not a call recording key%');
create temp table crx_rec as select app.server_twilio_recording(jsonb_build_object('id', id, 'recording_sid', 'RE' || repeat('a', 32), 'key', 'calls/twilio/' || id || '.mp3', 'seconds', '90')) r from crx_call;
select test.eq('stored: the key on the call, and Twilio''s copy is deleted by default',
  (select r ->> 'delete' from crx_rec)
  || '/' || (select c.recording_state || ':' || (c.recording_key = 'calls/twilio/' || c.id || '.mp3')::text || ':' || (c.transcribe_due_at <= now())::text from outbound_calls c join crx_call x using (id)),
  'true/stored:true:true');
select test.eq('linked: Play recording on the call''s history entry (renter and booking)',
  (select a.recordings -> 0 ->> 'url' || '|' || (a.recordings -> 0 ->> 'source') || '|' || (a.renter_id = test.id('renter:crx_rita'))::text || '|' || (a.booking_id = test.id('booking:CRX-1'))::text
     from outbound_calls c join crx_call x using (id) join phone_activity a on a.id = c.activity_id),
  (select '/api/staff/phone/recording?id=' || c.activity_id || '|site|true|true' from outbound_calls c join crx_call x using (id)));
select test.eq('the history entry carries it to staff (phone_item)',
  (select app.phone_item(a) -> 'recordings' -> 0 ->> 'source' from outbound_calls c join crx_call x using (id) join phone_activity a on a.id = c.activity_id), 'site');
update program_settings set phone_twilio_delete_recording = false;
select test.eq('the setting keeps Twilio''s copy', (select app.server_twilio_recording(jsonb_build_object('id', id, 'key', 'calls/twilio/' || id || '.mp3')) ->> 'delete' from crx_call), 'false');
update program_settings set phone_twilio_delete_recording = true;

-- a recording that arrives before the customer leg's end still reaches the history entry
create temp table crx_call2 as select (app.server_twilio_call_start(jsonb_build_object('user_id', test.id('crx_sales'), 'number', '+16475550299')) ->> 'id')::uuid id;
select app.server_twilio_recording(jsonb_build_object('id', id, 'key', 'calls/twilio/' || id || '.mp3', 'seconds', '20')) from crx_call2;
select app.server_twilio_call_event(jsonb_build_object('id', id, 'kind', 'dial', 'status', 'completed', 'duration', '22')) from crx_call2;
select test.eq('recording first, history entry after: linked',
  (select jsonb_array_length(a.recordings) from outbound_calls c join crx_call2 x using (id) join phone_activity a on a.id = c.activity_id), 1);

-- ================================================================ the allowance: background tier, free share only
select test.eq('speech to text of calls is background work', app.ai_tier('call_transcribe'), 'background');
create temp table crx_burn as select gen_random_uuid() id;
insert into provider_calls (id, provider, purpose, ok, units, unit) select id, 'workers-ai', 'seo_page', true, 100000000, 'neurons' from crx_burn;
create temp table crx_due as select app.server_twilio_transcribe_due(5) d;
select test.eq('the share used: nothing now, the calls wait for the next day',
  (select (d ->> 'waiting') || '/' || jsonb_array_length(d -> 'items') from crx_due)
  || '/' || (select bool_and(c.transcribe_due_at > now() + interval '1 minute' and c.transcribe_due_at = app.next_ai_day()) from outbound_calls c where c.id in (select id from crx_call union select id from crx_call2))::text,
  'true/0/true');
delete from provider_calls where id in (select id from crx_burn);
update outbound_calls set transcribe_due_at = now() - interval '1 minute' where id in (select id from crx_call union select id from crx_call2);
select test.ok('with room: due, with its key and length',
  (select bool_or(e ->> 'id' = (select id::text from crx_call) and e ->> 'key' like 'calls/twilio/%' and (e ->> 'seconds')::int = 90)
     from jsonb_array_elements(app.server_twilio_transcribe_due(5) -> 'items') e));
select test.eq('not picked twice while it runs', (select jsonb_array_length(app.server_twilio_transcribe_due(5) -> 'items')), 0);

-- ================================================================ transcript, summary, intent
select app.server_twilio_transcript(jsonb_build_object('id', id, 'ok', true, 'text', 'Hi, I need an SUV for 14 days,  delivered downtown.', 'neurons', 70, 'duration_ms', 900)) from crx_call;
select test.eq('the transcript on the history entry, as Quo''s, and its summary due',
  (select (a.transcript -> 0 ->> 'who') || '|' || (a.transcript -> 0 ->> 'text') || '|' || (a.summary_due_at is not null)::text
     from outbound_calls c join crx_call x using (id) join phone_activity a on a.id = c.activity_id),
  'call|Hi, I need an SUV for 14 days, delivered downtown.|true');
select test.ok('the neurons count in the day''s budget', exists (select 1 from provider_calls where purpose = 'call_transcribe' and units = 70));
select test.eq('lead intent reads the call at once (renter)',
  (select signals ->> 'car_class' from intent_scores where subject_kind = 'renter' and subject_id = test.id('renter:crx_rita')), 'suv');
select test.ok('the summary job picks it up', exists (select 1 from jsonb_array_elements(app.server_phone_due(20) -> 'summaries') s
  where s ->> 'id' = (select c.activity_id::text from outbound_calls c join crx_call x using (id))));

-- a lead's call: the lead's intent
insert into leads (id, kind, name, email, phone) values (test.id('lead:crx'), 'contact', 'Crx Lead', 'crx.lead@example.test', '(647) 555-0288');
create temp table crx_call3 as select (app.server_twilio_call_start(jsonb_build_object('user_id', test.id('crx_sales'), 'number', '+16475550288')) ->> 'id')::uuid id;
select test.eq('the lead''s call knows the lead', (select (c.lead_id = test.id('lead:crx'))::text from outbound_calls c join crx_call3 x using (id)), 'true');
select app.server_twilio_call_event(jsonb_build_object('id', id, 'kind', 'dial', 'status', 'completed', 'duration', '40')) from crx_call3;
select app.server_twilio_recording(jsonb_build_object('id', id, 'key', 'calls/twilio/' || id || '.mp3', 'seconds', '40')) from crx_call3;
select app.server_twilio_transcript(jsonb_build_object('id', id, 'ok', true, 'text', 'Looking for an SUV next weekend.', 'neurons', 30)) from crx_call3;
select test.eq('lead intent reads the call at once (lead)', (select signals ->> 'car_class' from intent_scores where subject_kind = 'lead' and subject_id = test.id('lead:crx')), 'suv');

-- failures: quota waits for tomorrow; three failures stop
select app.server_twilio_transcript(jsonb_build_object('id', id, 'ok', false, 'reason', 'quota', 'error', 'share used')) from crx_call2;
select test.eq('quota: tomorrow', (select (c.transcribe_due_at = app.next_ai_day())::text || '/' || c.recording_state from outbound_calls c join crx_call2 x using (id)), 'true/stored');
select app.server_twilio_transcript(jsonb_build_object('id', id, 'ok', false, 'reason', 'unavailable', 'error', 'x')) from crx_call2, generate_series(1, 3);
select test.eq('three failures: failed, no longer due', (select c.recording_state || '/' || (c.transcribe_due_at is null)::text from outbound_calls c join crx_call2 x using (id)), 'failed/true');

-- ================================================================ who may hear it
select test.eq('Admins, customer service and Sales may play it',
  (select (app.server_phone_recording(test.id('crx_admin'), c.activity_id) = c.recording_key)::text || '/' || (app.server_phone_recording(test.id('crx_cs'), c.activity_id) = c.recording_key)::text
          || '/' || (app.server_phone_recording(test.id('crx_sales'), c.activity_id) = c.recording_key)::text from outbound_calls c join crx_call x using (id)),
  'true/true/true');
select test.throws('field staff may not', format($$select app.server_phone_recording(%L, %L)$$, test.id('crx_field'), (select c.activity_id from outbound_calls c join crx_call x using (id))), '%Admins, customer service and Sales%');
select test.throws('nobody signed in may not', format($$select app.server_phone_recording(null, %L)$$, (select c.activity_id from outbound_calls c join crx_call x using (id))), '%Admins, customer service and Sales%');
select test.ok('the server''s functions are the server''s only',
  not has_function_privilege('authenticated', 'public.server_phone_recording(uuid, uuid)', 'execute')
  and not has_function_privilege('anon', 'public.server_twilio_recording(jsonb)', 'execute')
  and not has_function_privilege('authenticated', 'public.server_twilio_transcript(jsonb)', 'execute')
  and has_function_privilege('service_role', 'public.server_twilio_transcribe_due(integer)', 'execute'));
update program_settings set phone_twilio_record = false;
select test.eq('recording switched off in Program settings', (select app.server_twilio_call_get(id) ->> 'record' from crx_call3), 'false');
update program_settings set phone_twilio_record = true;

update program_settings s set require_staff_two_step = x.t, phone_twilio_delete_recording = x.d, phone_ai_summaries = x.s from crx_ps x where s.id = x.id;
