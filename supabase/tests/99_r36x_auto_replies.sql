-- 99: release 36 helper X (migration 2110): the AI auto-replies. Settings on by default per channel, the gate (channel off,
-- the daily cap per sender, a person already talking, opted out, the free Workers AI allowance), the record (a text held for
-- the quiet hours 1 to 5, a sure answer sent, an unsure one handed to staff with a To do), the neurons in the AI budget, and
-- who may read the log. Fixtures start with "rxa"; numbers are 555 test numbers, addresses example.test.
select test.suite('99 r36x auto replies (2110)');

select test.mk_user('rxa_admin', 'admin');
select test.mk_user('rxa_cs', 'va', 'cs');
select test.mk_user('rxa_fin', 'va', 'finance');
update program_settings set phone_enabled = true where id = (select id from app.settings());

select test.eq('every channel on by default; quiet hours 1 to 5; 5 a day; 70%',
  (select string_agg(column_name || '=' || column_default, ',' order by column_name) from information_schema.columns where table_name = 'program_settings'
    and column_name in ('auto_reply_sms', 'auto_reply_email', 'auto_reply_chat', 'auto_reply_whatsapp', 'auto_reply_messenger', 'auto_reply_instagram',
                        'auto_reply_quiet_from_hour', 'auto_reply_quiet_until_hour', 'auto_reply_per_sender_day', 'auto_reply_min_confidence_bps')),
  'auto_reply_chat=true,auto_reply_email=true,auto_reply_instagram=true,auto_reply_messenger=true,auto_reply_min_confidence_bps=7000,auto_reply_per_sender_day=5,auto_reply_quiet_from_hour=1,auto_reply_quiet_until_hour=5,auto_reply_sms=true,auto_reply_whatsapp=true');
select test.eq('faq_reply is a live feature of the AI budget', app.ai_tier('faq_reply'), 'live');
select test.eq('the other features keep their tier', app.ai_tier('staff_assistant'), 'assistant');

-- the quiet hours: 2 am Toronto waits until 5 am; noon goes now
select test.eq('2 am: held until 5 am', app.auto_reply_quiet_end('2026-11-11 07:00:00+00'), '2026-11-11 10:00:00+00'::timestamptz);
select test.eq('noon: now', app.auto_reply_quiet_end('2026-11-11 17:00:00+00'), '2026-11-11 17:00:00+00'::timestamptz);
select test.eq('just before 1 am: now', app.auto_reply_quiet_end('2026-11-11 05:59:00+00'), '2026-11-11 05:59:00+00'::timestamptz);

-- the gate (a large free allowance here, so only the rules decide; a number no other suite texts, so no staff text of theirs counts)
update usage_services set included = 1000000, enabled = true where service = 'workers_ai';
select test.ok('a question by text may be answered', (public.server_auto_reply_gate('{"channel": "sms", "sender": "+14165550178"}') ->> 'allowed')::boolean);
select test.ok('WhatsApp needs its number id', not (public.server_auto_reply_gate('{"channel": "whatsapp", "sender": "14165550178"}') ->> 'allowed')::boolean);
update program_settings set auto_reply_sms = false where id = (select id from app.settings());
select test.eq('a channel switched off', public.server_auto_reply_gate('{"channel": "sms", "sender": "+14165550178"}') ->> 'reason', 'off in Program settings');
update program_settings set auto_reply_sms = true where id = (select id from app.settings());
select app.phone_outbox_put('+14165550102', 'Hi, this is Ana from CarmaCars', 'staff');
select test.eq('a person already talking with them', public.server_auto_reply_gate('{"channel": "sms", "sender": "+14165550102"}') ->> 'reason', 'a person is talking with them');
update usage_services set included = 0 where service = 'workers_ai';
select test.eq('the free allowance used: no automatic answer', public.server_auto_reply_gate('{"channel": "email", "sender": "ana@example.test"}') ->> 'reason', 'the free Workers AI allowance of the day is used');
update usage_services set included = 1000000 where service = 'workers_ai';

-- the record: a sure answer by text (outside the quiet hours here: sent now, through the outbox as auto_reply)
create temp table rxa1 as select public.server_auto_reply_record(jsonb_build_object('channel', 'sms', 'sender', '+14165550103', 'question', 'Do you deliver to Pearson?',
  'answer', 'Yes, we deliver to Pearson airport for a fee.', 'confident', true, 'confidence', 0.9, 'model', '@cf/meta/llama-3.1-8b-instruct-fp8-fast', 'neurons', 40, 'faq', '["faq.x#1"]')) r;
select test.ok('a sure answer: sent now or held for the quiet hours', (select r ->> 'status' in ('sent', 'queued') from rxa1));
select test.eq('in the phone outbox as an automatic answer', (select kind from phone_outbox where to_number = '+14165550103'), 'auto_reply');
select test.eq('the neurons count in the AI budget (provider_calls, faq_reply)', (select sum(units)::int from provider_calls where purpose = 'faq_reply'), 40);
select test.eq('not sure (60% under the 70%): handed off, nothing sent',
  public.server_auto_reply_record(jsonb_build_object('channel', 'sms', 'sender', '+14165550104', 'question', 'Can I return it late?', 'answer', 'Maybe.', 'confident', true, 'confidence', 0.6)) ->> 'status', 'handoff');
select test.ok('no text to that number', not exists (select 1 from phone_outbox where to_number = '+14165550104'));
create temp table rxa2 as select public.server_auto_reply_record(jsonb_build_object('channel', 'email', 'sender', 'ana@example.test', 'question', 'My card was charged twice', 'answer', '', 'confident', false)) r;
select test.eq('an email the FAQ does not answer: a To do for customer service', (select count(*)::int from tasks where task_type = 'auto_reply_handoff' and title like 'Answer Email:%'), 1);
select public.server_auto_reply_record(jsonb_build_object('channel', 'email', 'sender', 'ana@example.test', 'question', 'And another thing', 'answer', '', 'confident', false));
select test.eq('one To do a sender a day', (select count(*)::int from tasks where task_type = 'auto_reply_handoff'), 1);

-- the daily cap per sender
update program_settings set auto_reply_per_sender_day = 1 where id = (select id from app.settings());
select test.eq('one answer a day here: the next goes to staff', public.server_auto_reply_gate('{"channel": "sms", "sender": "+14165550103"}') ->> 'reason', 'the sender''s automatic answers of the day are used');
update program_settings set auto_reply_per_sender_day = 5 where id = (select id from app.settings());

-- the quiet hours on the outbox: a text answered at 2 am waits until 5 am
select test.ok('the held answer waits for the end of the quiet hours',
  (select (o.send_after at time zone 'America/Toronto')::time >= time '05:00' or o.send_after <= now() from phone_outbox o where o.to_number = '+14165550103'));

select test.eq('the email inboxes answered', public.server_auto_reply_inboxes(), '["help"]'::jsonb);
update program_settings set auto_reply_email = false where id = (select id from app.settings());
select test.eq('email off: no inbox is answered', public.server_auto_reply_inboxes(), '[]'::jsonb);
update program_settings set auto_reply_email = true where id = (select id from app.settings());
select test.ok('the Meta side has a verify token', length(public.server_meta_messaging() ->> 'verify_token') >= 16);

-- who reads the log
select test.ok('customer service reads the answers', jsonb_array_length(public.door(test.id('rxa_cs'), 'aal2', 'va_read', 'auto_replies', '{}') -> 'rows') >= 3);
select test.throws('Finance does not', format($$select public.door(%L, 'aal2', 'va_read', 'auto_replies', '{}')$$, test.id('rxa_fin')), 'Not permitted');
select test.ok('the server functions are the server''s only', not has_function_privilege('anon', 'public.server_auto_reply_record(jsonb)', 'execute')
  and not has_function_privilege('authenticated', 'public.server_auto_reply_gate(jsonb)', 'execute')
  and not has_function_privilege('authenticated', 'public.server_meta_messaging()', 'execute'));
