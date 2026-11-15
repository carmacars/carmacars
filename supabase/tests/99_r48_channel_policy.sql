-- 99: fewer texts, more email: a channel for each message type (migration 2971, docs/changes/2026-11-14-r48-channel-policy.md).
-- Fixtures start with "cp48"; addresses are example.test, numbers 555.
select test.suite('99 r48 channel policy');
update program_settings set notify_merge_window_minutes = 0, notify_repeat_window_minutes = 0, phone_enabled = true, sms_alerts_enabled = true,
  email_production_ready = false where id = (app.settings()).id;
select test.mk_user('cp48_admin', 'admin');
select test.mk_user('cp48_fleet', 'va', 'fleet');
select test.mk_owner('cp48_o');
select test.mk_vehicle('CP48A', 'cp48_o');
select test.mk_renter('cp48_r');
update users set phone = '+16475550142', phone_verified_at = now(), notify_channel = 'both' where id = test.id('cp48_r');
select test.mk_booking('CC-CP4801', 'CP48A', 'cp48_r', to_char((now() + interval '30 hours') at time zone 'America/Toronto', 'YYYY-MM-DD HH24:MI'),
  to_char((now() + interval '80 hours') at time zone 'America/Toronto', 'YYYY-MM-DD HH24:MI'), 'confirmed');
create function test.cp48_put(p_code text, p_key text, p_status text default 'queued') returns notification_outbox language sql as $$
  insert into notification_outbox (code, category, priority, audience, to_address, to_name, booking_id, renter_id, payload, dedupe_key, status, status_reason)
  values (p_code, 'transactional', 1, 'renter', 'cp48_r@example.test', 'Cp48', test.id('booking:CC-CP4801'), test.id('renter:cp48_r'),
          jsonb_build_object('booking_id', test.id('booking:CC-CP4801')), 'cp48:' || p_key, p_status, case when p_status = 'suppressed' then 'address suppressed' end)
  returning * $$;
create function test.cp48_row(p_key text) returns text language sql as $$
  select n.status || ':' || n.sms_planned::text || ':' || exists (select 1 from phone_outbox o where o.notification_id = n.id)::text from notification_outbox n where n.dedupe_key = 'cp48:' || p_key $$;

-- ---------------------------------------------------------------- 1. off (the SES sandbox): as before
select test.ok('off by default', not (app.settings()).email_production_ready);
select test.ok('off: no channel in force', app.channel_policy_for('renter_booking_confirmed') is null);
select test.cp48_put('renter_booking_confirmed', 'off');
select test.eq('off: the person chose both, so the email and the text', test.cp48_row('off'), 'queued:true:true');

-- ---------------------------------------------------------------- 2. on: urgent types keep the text, the rest email only
update program_settings set email_production_ready = true where id = (app.settings()).id;
select test.eq('the defaults', app.channel_policy_for('renter_booking_confirmed') || '/' || app.channel_policy_for('renter_pickup_details') || '/' || app.channel_policy_for('renter_late_return_first')
  || '/' || app.channel_policy_for('renter_payment_failed'), 'email/both/both/both');
select test.cp48_put('renter_booking_confirmed', 'on');
select test.eq('on: a confirmation by email only', test.cp48_row('on') || ':' || (select channel from notification_outbox where dedupe_key = 'cp48:on'), 'queued:false:false:email');
select test.cp48_put('renter_pickup_details', 'urgent');
select test.eq('on: the pickup details keep the text', test.cp48_row('urgent'), 'queued:true:true');
select test.cp48_put('renter_booking_confirmed', 'supp', 'suppressed');
select test.eq('on: the address is suppressed, so the text goes instead', test.cp48_row('supp'), 'suppressed:true:true');

-- ---------------------------------------------------------------- 3. the Admin's choice
select test.throws('only an Admin sets it', $$select public.door(test.id('cp48_fleet'), null, 'admin_do', 'channel_policy_set', '{"code": "renter_booking_confirmed", "channel": "text"}'::jsonb)$$, null);
select test.throws('a type that can go by text', $$select public.door(test.id('cp48_admin'), null, 'admin_do', 'channel_policy_set', '{"code": "no_such_type", "channel": "text"}'::jsonb)$$, 'can go by text');
select test.throws('text, email or both', $$select public.door(test.id('cp48_admin'), null, 'admin_do', 'channel_policy_set', '{"code": "renter_booking_confirmed", "channel": "fax"}'::jsonb)$$, 'text, email or both');
select test.eq('set to text', public.door(test.id('cp48_admin'), null, 'admin_do', 'channel_policy_set', '{"code": "renter_return_soon", "channel": "text"}'::jsonb) ->> 'channel', 'text');
select test.cp48_put('renter_return_soon', 'text');
select test.eq('text: the email is skipped, the text goes', test.cp48_row('text'), 'skipped:true:true');
select test.eq('logged', (select count(*)::int from audit_log where action = 'channel_policy_set' and entity_id = 'renter_return_soon'), 1);
select public.door(test.id('cp48_admin'), null, 'admin_do', 'channel_policy_set', '{"code": "renter_pickup_details", "channel": "email"}'::jsonb);
select test.cp48_put('renter_pickup_details', 'urgent_email');
select test.eq('an urgent type set to email: email only', test.cp48_row('urgent_email'), 'queued:false:false');
select test.eq('back to the default', public.door(test.id('cp48_admin'), null, 'admin_do', 'channel_policy_set', '{"code": "renter_pickup_details", "channel": null}'::jsonb) ->> 'chosen', 'false');
select test.eq('back to the default removes the row', (select count(*)::int from message_channel_policy where code = 'renter_pickup_details'), 0);

-- ---------------------------------------------------------------- 4. the list with the counts
update phone_outbox set status = 'sent', sent_at = now() where notification_id in (select id from notification_outbox where dedupe_key like 'cp48:%');
create temp table cp48_l as select public.door(test.id('cp48_admin'), null, 'admin_read', 'channel_policy', '{}'::jsonb) v;
select test.throws('only an Admin reads it', $$select public.door(test.id('cp48_fleet'), null, 'admin_read', 'channel_policy', '{}'::jsonb)$$, null);
select test.eq('the list: on, the counts of the last 30 days, the chosen channel, urgent flagged',
  (select (v ->> 'production_ready') from cp48_l) || '/' ||
  (select (x ->> 'texts_30d') || ':' || (x ->> 'channel') || ':' || (x ->> 'chosen') from cp48_l, jsonb_array_elements(v -> 'types') x where x ->> 'code' = 'renter_return_soon') || '/' ||
  (select (x ->> 'texts_30d') || ':' || (x ->> 'channel') from cp48_l, jsonb_array_elements(v -> 'types') x where x ->> 'code' = 'renter_booking_confirmed') || '/' ||
  (select (x ->> 'texts_30d') || ':' || (x ->> 'urgent') || ':' || (x ->> 'channel') from cp48_l, jsonb_array_elements(v -> 'types') x where x ->> 'code' = 'renter_pickup_details'),
  'true/1:text:true/2:email/1:true:both');

-- ---------------------------------------------------------------- 5. an email-only message that bounced: the text instead
select test.cp48_put('renter_booking_confirmed', 'bounce');
update notification_outbox set status = 'sent', provider_id = 'cp48-provider-1', sent_at = now() where dedupe_key = 'cp48:bounce';
select test.eq('before the bounce: email only', test.cp48_row('bounce'), 'sent:false:false');
select app.outbox_record_bounce('cp48-provider-1', 'bounce', 'mailbox unknown');
select test.eq('after the bounce: by text', test.cp48_row('bounce'), 'failed:true:true');
delete from email_suppressions where email = 'cp48_r@example.test';
update program_settings set email_production_ready = false where id = (app.settings()).id;
