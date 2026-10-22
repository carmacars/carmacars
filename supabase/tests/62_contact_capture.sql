-- 62: contact capture from every form (0090): capture as typed, the account at once, the browser-bound unverified
-- session only for a brand-new address, the existing account rule, no confirmation without the link, the gate on
-- accept, sign, pay, uploads and extensions, the link confirms and ends every unverified session, the follow-up, closing
-- after 30 days. Fixtures start with "cap".
select test.suite('62 contact capture');
create table test.cap (k text primary key, v jsonb);
create function test.capv(p text) returns jsonb language sql stable as $$ select v from test.cap where k = p $$;
create function test.cap_do(p_key text, p jsonb) returns jsonb language plpgsql as $$
declare v jsonb := public.server_capture_contact(p);
begin insert into test.cap values (p_key, v) on conflict (k) do update set v = excluded.v; return v; end $$;
select test.mk_user('cap_admin', 'admin');
update program_settings set recovery_send_from_hour = 0, recovery_send_until_hour = 24, uptime_quiet_from_hour = 0, uptime_quiet_until_hour = 0;

-- ================================================================ 1. phone only, then the name, then the email
select test.cap_do('p1', jsonb_build_object('visitor_id', test.id('cap-vis-a'), 'form', 'booking_request', 'phone', '(647) 555-0142', 'browser', true));
select test.eq('phone only: saved, a lead linked to the visitor, no account', (test.capv('p1') ->> 'state') || '/'
  || (select count(*) from leads l where l.phone = '+16475550142' and l.payload ->> 'visitor_id' = test.id('cap-vis-a')::text and not l.consent_marketing and l.source = 'unfinished_form')
  || '/' || (select count(*) from users where phone = '+16475550142'), 'phone_only/1/0');
select test.eq('only what was typed: an invalid email or a one-letter name saves nothing',
  (public.server_capture_contact(jsonb_build_object('visitor_id', test.id('cap-vis-z'), 'form', 'contact', 'email', 'not-an-email', 'name', 'x', 'browser', true)) ->> 'saved'), 'false');
select test.cap_do('p2', jsonb_build_object('visitor_id', test.id('cap-vis-a'), 'form', 'booking_request', 'name', ' Maya   Chen ', 'browser', true));
select test.cap_do('new', jsonb_build_object('visitor_id', test.id('cap-vis-a'), 'form', 'booking_request', 'email', 'Maya.Capture@Example.test', 'browser', true, 'page', '/book/x'));
select test.eq('a brand-new email: account, renter record and a browser session', (test.capv('new') ->> 'state') || '/' || (test.capv('new') ->> 'make_sign_in')
  || '/' || (length(test.capv('new') ->> 'session_token') = 64)::text, 'new/true/true');
select test.eq('the users row, the renter role and the renter record with what was typed',
  (select u.email || '|' || u.full_name || '|' || coalesce(u.phone, '') || '|' || r.legal_name || '|' || r.mobile || '|' || (u.email_verified_at is null)::text
     from users u join renters r on r.user_id = u.id where u.id = (test.capv('new') ->> 'user_id')::uuid), 'maya.capture@example.test|Maya Chen|+16475550142|Maya Chen|+16475550142|true');
select test.eq('one capture row and one lead for the visitor and form', (select count(*) || '/' || count(lead_id) from contact_captures where visitor_id = test.id('cap-vis-a')), '1/1');
select test.eq('the session token is kept only as its hash', (select count(*) from capture_sessions where token_hash = app.token_hash(test.capv('new') ->> 'session_token')
  and token_hash <> test.capv('new') ->> 'session_token'), 1::bigint);
select test.eq('no confirmation without the link: the account stays unconfirmed', (select email_verified_at is null from users where id = (test.capv('new') ->> 'user_id')::uuid), true);
select public.server_capture_sign_in_made((test.capv('new') ->> 'user_id')::uuid);
select test.eq('the app made the sign-in: recorded', (select sign_in_made from capture_accounts where user_id = (test.capv('new') ->> 'user_id')::uuid), true);

-- the same browser again: its own account, no second account or session
select test.cap_do('again', jsonb_build_object('visitor_id', test.id('cap-vis-a'), 'form', 'booking_request', 'email', 'maya.capture@example.test',
  'session_token', test.capv('new') ->> 'session_token', 'browser', true));
select test.eq('this browser again: this_device, no new session', (test.capv('again') ->> 'state') || '/' || coalesce(test.capv('again') ->> 'session_token', 'none')
  || '/' || (select count(*) from capture_sessions where user_id = (test.capv('new') ->> 'user_id')::uuid), 'this_device/none/1');

-- ================================================================ 2. another browser, same email: existing, never a session
select test.cap_do('other', jsonb_build_object('visitor_id', test.id('cap-vis-b'), 'form', 'contact', 'name', 'Someone Else', 'email', 'maya.capture@example.test', 'browser', true));
select test.eq('another browser: existing, no session, the sign-in link sent once', (test.capv('other') ->> 'state') || '/' || coalesce(test.capv('other') ->> 'session_token', 'none')
  || '/' || (test.capv('other') ->> 'link_sent'), 'existing/none/true');
select test.eq('the other browser changed nothing on the account (name stays)', (select full_name from users where id = (test.capv('new') ->> 'user_id')::uuid), 'Maya Chen');
select test.eq('the link: one email queued, the account''s continue link kept as a hash only',
  (select count(*) from app_events where code = 'renter_continue_request' and entity_id = (test.capv('new') ->> 'user_id')::uuid) || '/'
  || (select (continue_link_hash is not null and continue_sent_at is not null)::text from capture_accounts where user_id = (test.capv('new') ->> 'user_id')::uuid), '1/true');
select test.cap_do('other2', jsonb_build_object('visitor_id', test.id('cap-vis-c'), 'form', 'owner_lead', 'email', 'maya.capture@example.test', 'browser', true));
select test.eq('once, not repeated: a third browser sends nothing more', (test.capv('other2') ->> 'link_sent') || '/' || (test.capv('other2') ->> 'link_sent_before') || '/'
  || (select count(*) from app_events where code = 'renter_continue_request' and entity_id = (test.capv('new') ->> 'user_id')::uuid), 'false/true/1');
select test.eq('a session token from another browser does not join: its visitor id differs',
  public.server_capture_contact(jsonb_build_object('visitor_id', test.id('cap-vis-b'), 'form', 'contact', 'email', 'maya.capture@example.test',
    'session_token', test.capv('new') ->> 'session_token', 'browser', true)) ->> 'state', 'existing');
select test.eq('the session read refuses another visitor id', public.server_capture_session_read(test.capv('new') ->> 'session_token', test.id('cap-vis-b')) ->> 'ok', 'false');

-- ================================================================ 3. what the unverified session sees: only its own
insert into users (id, email, full_name) values (test.id('cap-other-user'), 'cap.other@example.test', 'Cap Other');
insert into form_drafts (id, form_code, token_hashes, data, step, expires_at) values
  (test.id('cap-draft-a'), 'booking_request', array[app.token_hash('cap-token-a')], '{"car":"cap-car"}', '2', now() + interval '30 days'),
  (test.id('cap-draft-b'), 'booking_request', array[app.token_hash('cap-token-b')], '{"car":"cap-car"}', '2', now() + interval '30 days');
select test.cap_do('draft', jsonb_build_object('visitor_id', test.id('cap-vis-a'), 'form', 'booking_request', 'ref', test.id('cap-draft-a')::text, 'draft_token', 'cap-token-a',
  'email', 'maya.capture@example.test', 'session_token', test.capv('new') ->> 'session_token', 'browser', true));
select test.cap_do('draftb', jsonb_build_object('visitor_id', test.id('cap-vis-b'), 'form', 'booking_request', 'ref', test.id('cap-draft-b')::text, 'draft_token', 'cap-token-b',
  'email', 'maya.capture@example.test', 'browser', true));
select test.cap_do('wrongtok', jsonb_build_object('visitor_id', test.id('cap-vis-d'), 'form', 'booking_request',
  'ref', test.id('cap-draft-a')::text, 'draft_token', 'wrong', 'phone', '4165550100', 'browser', true));
select test.eq('a draft is linked only with its own token', (test.capv('wrongtok') ->> 'saved') || '/'
  || (select count(*) from contact_captures where visitor_id = test.id('cap-vis-d') and draft_id is null), 'true/1');
select test.eq('the session sees its own draft only, not the one typed in another browser',
  (select string_agg(x ->> 'id', ',') from jsonb_array_elements(public.server_capture_session_read(test.capv('new') ->> 'session_token', test.id('cap-vis-a')) -> 'drafts') x),
  test.id('cap-draft-a')::text);
select test.eq('a booking of someone else is never added to the session', public.server_capture_session_add_booking(test.capv('new') ->> 'session_token', 'CC-NOPE'), false);

-- ================================================================ 4. the gate: unconfirmed accounts cannot accept, sign, pay or upload
select test.mk_owner('cap_owner');
select test.mk_vehicle('cap_car', 'cap_owner');
select test.mk_renter('cap_renter');
select test.mk_booking('CAP-1', 'cap_car', 'cap_renter', '2026-12-01 10:00', '2026-12-04 10:00', 'offered');
insert into capture_accounts (user_id, opened_by_capture, sign_in_made) values (test.id('cap_renter'), true, true);
update users set email_verified_at = null where id = test.id('cap_renter');
select test.eq('unconfirmed: the gate says so', public.server_capture_unconfirmed(test.id('cap_renter')), true);
select test.throws('unconfirmed cannot accept an offer', $$select public.renter_approve_offer(test.id('booking:CAP-1'), 1, test.id('cap_renter'))$$, '%Confirm your email first%accept the offer%');
select test.throws('unconfirmed cannot sign the agreement', $$select public.renter_sign_agreement(test.id('booking:CAP-1'), test.id('cap_renter'), 'I agree', repeat('a', 64), '{}'::jsonb, 'Cap Renter')$$, '%Confirm your email first%sign%');
select test.throws('unconfirmed cannot sign an amendment', $$select public.renter_sign_amendment(gen_random_uuid(), test.id('cap_renter'), 'I agree', repeat('a', 64), 'Cap Renter')$$, '%Confirm your email first%sign%');
select test.throws('unconfirmed cannot pay', $$select public.server_record_booking_payment(test.id('booking:CAP-1'), '{}'::jsonb, 100, 1, null, null, test.id('cap_renter'))$$, '%Confirm your email first%pay%');
select test.throws('unconfirmed cannot pay an extension', $$select public.server_confirm_extension_payment(gen_random_uuid(), '{}'::jsonb, 100, test.id('cap_renter'))$$, '%Confirm your email first%pay%');
select test.throws('unconfirmed cannot upload ID or licence documents', $$select public.renter_register_upload(test.id('booking:CAP-1'), test.id('cap_renter'), 'id_front', 'x/y.jpg', repeat('a', 64), 'image/jpeg', 'private')$$, '%Confirm your email first%upload%');
select test.eq('an account capture never touched is not gated', public.server_capture_unconfirmed(test.id('cap_admin')), false);

-- ================================================================ 5. the link confirms; every unverified session ends
select test.eq('the continue link opens the account and its landing', (select (public.server_capture_continue_open(x.t) ->> 'email') || '|' || (public.server_capture_continue_open(x.t) ->> 'ok')
  from (select app.capture_new_link((test.capv('new') ->> 'user_id')::uuid, '/book/cap-car') as t) x), 'maya.capture@example.test|true');
insert into test.cap select 'link', to_jsonb(app.capture_new_link((test.capv('new') ->> 'user_id')::uuid, '/book/cap-car'));
select test.eq('a wrong or expired link opens nothing', (public.server_capture_continue_open('nope') ->> 'error'), 'expired');
-- a second unverified session for the account (as if made before), then confirmation through the link
insert into capture_sessions (user_id, token_hash, visitor_id, expires_at) values ((test.capv('new') ->> 'user_id')::uuid, app.token_hash('cap-second'), test.id('cap-vis-x'), now() + interval '30 days');
select public.server_account_email_verified((test.capv('new') ->> 'user_id')::uuid, 'maya.capture@example.test');
select test.eq('the link confirms: every unverified session of the account is revoked',
  (select count(*) from capture_sessions where user_id = (test.capv('new') ->> 'user_id')::uuid and revoked_at is null) || '/'
  || (public.server_capture_session_read(test.capv('new') ->> 'session_token', test.id('cap-vis-a')) ->> 'ok') || '/'
  || (select (confirmed_at is not null)::text from capture_accounts where user_id = (test.capv('new') ->> 'user_id')::uuid), '0/false/true');
select test.eq('the draft of this browser becomes the account''s own; the one typed elsewhere joins only if no other is open',
  (select count(*) from form_drafts where user_id = (test.capv('new') ->> 'user_id')::uuid and form_code = 'booking_request'), 1::bigint);
select test.eq('confirmed: the gate lets the account through', public.server_capture_unconfirmed((test.capv('new') ->> 'user_id')::uuid), false);
update users set email_verified_at = now() - interval '2 hours' where id = (test.capv('new') ->> 'user_id')::uuid;
select test.eq('the link stops an hour after the email was confirmed', public.server_capture_continue_open(test.capv('link') #>> '{}') ->> 'error', 'used');
update users set email_verified_at = now() where id = test.id('cap_renter');
do $$ begin
  perform public.renter_approve_offer(test.id('booking:CAP-1'), 99, test.id('cap_renter'));
exception when others then
  perform test.ok('confirmed: the refusal is no longer the email gate', sqlerrm not like 'Confirm your email first%', sqlerrm);
end $$;

-- ================================================================ 6. an address with any record never gets a session
select test.mk_renter('cap_known', false);
select test.cap_do('known', jsonb_build_object('visitor_id', test.id('cap-vis-e'), 'form', 'booking_request', 'name', 'Cap Known', 'email', 'cap_known@example.test', 'browser', true));
select test.eq('a renter record without sign-in: existing, an account opened, no session, the link sent', (test.capv('known') ->> 'state') || '/'
  || coalesce(test.capv('known') ->> 'session_token', 'none') || '/' || (test.capv('known') ->> 'link_sent') || '/' || (test.capv('known') ->> 'make_sign_in'), 'existing/none/true/true');
select test.eq('the renter record is left as it was (attached when the email is confirmed)',
  (select (user_id is null)::text || '|' || legal_name from renters where id = test.id('renter:cap_known')), 'true|Cap Known');
select test.cap_do('signed', jsonb_build_object('visitor_id', test.id('cap-vis-f'), 'form', 'contact', 'email', 'cap_admin@example.test', 'signed_in', test.id('cap_admin'), 'browser', true));
select test.eq('signed in: linked to the account, nothing opened or sent', (test.capv('signed') ->> 'state') || '/'
  || (select count(*) from app_events where code = 'renter_continue_request' and entity_id = test.id('cap_admin')), 'signed_in/0');

-- an address that only the sign-in service holds (an account with a password): existing, never a session
create table auth.users (id uuid primary key, email text, email_confirmed_at timestamptz, last_sign_in_at timestamptz);
insert into auth.users values (gen_random_uuid(), 'has.signin@example.test', now(), now());
select test.cap_do('authonly', jsonb_build_object('visitor_id', test.id('cap-vis-k'), 'form', 'booking_request', 'email', 'has.signin@example.test', 'browser', true));
select test.eq('a sign-in account: existing, no session, "we sent you a sign-in link"', (test.capv('authonly') ->> 'state') || '/'
  || coalesce(test.capv('authonly') ->> 'session_token', 'none') || '/' || (test.capv('authonly') ->> 'link_sent'), 'existing/none/true');

-- a mistyped address corrected in the same form: the account it opened goes again
select test.cap_do('typo', jsonb_build_object('visitor_id', test.id('cap-vis-g'), 'form', 'contact', 'name', 'Typo Person', 'email', 'typo.person@exmaple.test', 'browser', true));
select test.cap_do('fixed', jsonb_build_object('visitor_id', test.id('cap-vis-g'), 'form', 'contact', 'email', 'typo.person@example.test',
  'session_token', test.capv('typo') ->> 'session_token', 'browser', true));
select test.eq('the corrected address: the mistyped account is removed, the new one opened', (test.capv('fixed') ->> 'discard_user' = test.capv('typo') ->> 'user_id')::text || '/'
  || (select count(*) from users where email = 'typo.person@exmaple.test') || '/' || (test.capv('fixed') ->> 'state'), 'true/0/new');

-- ================================================================ 7. rate limit
update program_settings set capture_rate_per_minute = 5;
select test.eq('rate limited per browser', (select count(*) from generate_series(1, 8) g
  where public.server_capture_contact(jsonb_build_object('visitor_id', test.id('cap-vis-r'), 'form', 'contact', 'phone', '4165550111', 'browser', true)) ->> 'error' = 'rate_limited'), 3::bigint);
update program_settings set capture_rate_per_minute = 30;

-- ================================================================ 8. sent forms, the follow-up, the job
select public.server_capture_done(jsonb_build_object('visitor_id', test.id('cap-vis-b'), 'form', 'contact'));
select test.eq('a sent contact form closes its capture and its lead', (select (c.done_at is not null)::text || '|' || l.status from contact_captures c join leads l on l.id = c.lead_id
  where c.visitor_id = test.id('cap-vis-b') and c.form = 'contact'), 'true|closed');
update form_drafts set submitted_at = now() where id = test.id('cap-draft-a');
select test.eq('a submitted draft closes its capture', (select done_at is not null from contact_captures where draft_id = test.id('cap-draft-a')), true);
update contact_captures set last_at = now() - interval '45 minutes', first_at = now() - interval '50 minutes' where done_at is null;
select test.ok('the job runs', app.job_capture() like 'emails %');
select test.eq('the Admin To do for an unfinished form, once, with the name',
  (select count(*) || '|' || min(t.title) || '|' || min(t.queue) from tasks t join contact_captures c on c.task_id = t.id where c.visitor_id = test.id('cap-vis-g')), '1|Unfinished request from Typo Person: follow up|admin');
select test.eq('Admin To do counts them', (select (i ->> 'count')::int > 0 from jsonb_array_elements(app.admin_todo(test.id('cap_admin')) -> 'items') i where i ->> 'key' = 'capture_follow_up'), true);
select test.eq('the new account of the unfinished form gets its one email', (select count(*) from app_events where code = 'renter_continue_request' and entity_id = (test.capv('fixed') ->> 'user_id')::uuid), 1::bigint);
select app.job_capture();
select test.eq('never repeated by the next run', (select count(*) from app_events where code = 'renter_continue_request' and entity_id = (test.capv('fixed') ->> 'user_id')::uuid)
  || '/' || (select count(*) from tasks t join contact_captures c on c.task_id = t.id where c.visitor_id = test.id('cap-vis-g')), '1/1');
update app_events set processed_at = now() where processed_at is null and code <> 'renter_continue_request';
select app.process_events(100000);
select test.eq('the email renders: recipient and values', (select o.to_address || '|' || (o.payload ->> 'started_what') || '|' || (o.payload ->> 'continue_url' like '%/continue?t=%')::text
  from notification_outbox o where o.code = 'renter_continue_request' and o.to_address = 'typo.person@example.test'), 'typo.person@example.test|a message to us|true');
-- quiet hours: no new to-do
update program_settings set uptime_quiet_from_hour = 0, uptime_quiet_until_hour = 23;
select test.cap_do('quiet', jsonb_build_object('visitor_id', test.id('cap-vis-q'), 'form', 'contact', 'phone', '4165550122', 'browser', true));
update contact_captures set last_at = now() - interval '45 minutes' where visitor_id = test.id('cap-vis-q');
select app.job_capture((app.local_date(now()) + time '03:00') at time zone 'America/Toronto');
select test.eq('quiet hours of the site alerts: no to-do raised', (select task_id is null from contact_captures where visitor_id = test.id('cap-vis-q')), true);
update program_settings set uptime_quiet_from_hour = 0, uptime_quiet_until_hour = 0;
-- the form sent: the to-do closes by itself
select public.server_capture_done(jsonb_build_object('visitor_id', test.id('cap-vis-g'), 'form', 'contact'));
select test.eq('sending the form closes the to-do', (select t.status from tasks t join contact_captures c on c.task_id = t.id where c.visitor_id = test.id('cap-vis-g')), 'done');

-- ================================================================ 9. staff reads
select test.eq('the renter page says email not confirmed', (select (public.door(test.id('cap_admin'), null, 'admin_read', 'renter_live',
  jsonb_build_object('renter_id', r.id)) ->> 'email_confirmed') from renters r where r.user_id = (test.capv('fixed') ->> 'user_id')::uuid), 'false');
select test.eq('Leads lists the captured contacts', (select (x ->> 'name') from jsonb_array_elements(public.door(test.id('cap_admin'), null, 'admin_read', 'captured_contacts', '{}') -> 'rows') x
  where x ->> 'email' = 'typo.person@example.test'), 'Typo Person');
select test.mk_user('cap_fleet', 'va', 'fleet');
select test.throws('Leads are not for Fleet', $$select public.door(test.id('cap_fleet'), null, 'va_read', 'captured_contacts', '{}')$$, '%Leads are for%');
select test.eq('Live visitors shows what a visitor typed', (app.capture_for_visitor(test.id('cap-vis-g')) ->> 'name'), 'Typo Person');

-- ================================================================ 10. game claim and chat
select test.cap_do('chatcap', jsonb_build_object('visitor_id', test.id('cap-vis-h'), 'form', 'game', 'name', 'Gamer Gail', 'email', 'gail.capture@example.test', 'browser', true));
insert into chat_conversations (id, visitor_id) values (test.id('cap-chat'), test.id('cap-vis-i'));
update chat_conversations set name = 'Chat Chad', email = 'chad.capture@example.test' where id = test.id('cap-chat');
select test.eq('contact given in the chat: captured, done, the chat linked to the new account (no session)',
  (select c.state || '|' || (c.done_at is not null)::text || '|' || (ch.user_id = c.user_id)::text from contact_captures c join chat_conversations ch on ch.id = c.chat_id
    where c.chat_id = test.id('cap-chat')) || '|' || (select count(*) from capture_sessions s join users u on u.id = s.user_id where u.email = 'chad.capture@example.test'), 'new|true|true|0');

select test.cap_do('signup', jsonb_build_object('visitor_id', test.id('cap-vis-j'), 'form', 'signup', 'name', 'Sign Sam', 'email', 'sam.capture@example.test', 'browser', true));
select test.eq('the sign-up form left unfinished: captured, a brand-new account and this browser''s session',
  (test.capv('signup') ->> 'state') || '|' || (length(test.capv('signup') ->> 'session_token') = 64)::text || '|' || app.capture_form_label('signup'), 'new|true|sign-up form');
select test.eq('the sign-up sent closes its capture', public.server_capture_done(jsonb_build_object('visitor_id', test.id('cap-vis-j'), 'form', 'signup')), 1);
select test.eq('and its lead', (select l.status from leads l join contact_captures c on c.lead_id = l.id where c.visitor_id = test.id('cap-vis-j')), 'closed');

-- ================================================================ 11. never confirmed: the sign-in closes after 30 days, the lead stays
update capture_accounts set opened_at = now() - interval '31 days' where user_id = (test.capv('fixed') ->> 'user_id')::uuid;
insert into auth.users values ((test.capv('fixed') ->> 'user_id')::uuid, 'typo.person@example.test', null, null);
select app.job_capture();
select test.eq('not confirmed in 30 days: sessions revoked, link stopped, sign-in closed, the lead kept',
  (select (closed_at is not null)::text || '|' || (continue_link_hash is null)::text || '|' || sign_in_made::text from capture_accounts where user_id = (test.capv('fixed') ->> 'user_id')::uuid)
  || '|' || (select count(*) from capture_sessions where user_id = (test.capv('fixed') ->> 'user_id')::uuid and revoked_at is null)
  || '|' || (select count(*) from leads where email = 'typo.person@example.test'), 'true|true|false|0|1');
select test.eq('its sign-in account without a password, never used, is removed', (select count(*) from auth.users where email = 'typo.person@example.test'), 0::bigint);
drop table auth.users;
select test.eq('a closed account opens no session', public.server_capture_session_read(test.capv('fixed') ->> 'session_token', test.id('cap-vis-g')) ->> 'ok', 'false');
update contact_captures set last_at = now() - interval '25 months' where user_id = (test.capv('fixed') ->> 'user_id')::uuid or email = 'typo.person@example.test';
select app.job_capture();
select test.eq('24 months after the last thing typed, not a customer: the capture, its lead and the unconfirmed account are gone',
  (select count(*) from contact_captures where email = 'typo.person@example.test') || '|' || (select count(*) from leads where email = 'typo.person@example.test')
  || '|' || (select count(*) from users where email = 'typo.person@example.test'), '0|0|0');
select test.eq('captures typed more recently are kept', (select count(*) from contact_captures where user_id = (test.capv('new') ->> 'user_id')::uuid) > 0, true);

-- ================================================================ 12. privileges
select test.eq('the privacy policy has the row for forms you start and its retention', coalesce((select (body like '%| Forms you start:%' and body like '%| Contact details typed into a form you did not send | 24 months%')::text
  from site_content_blocks where block_key = 'legal.privacy' and body like '%| Discount games:%'), 'true'), 'true');
select test.ok('the server calls are the service role''s only', not has_function_privilege('anon', 'public.server_capture_contact(jsonb)', 'execute')
  and not has_function_privilege('authenticated', 'public.server_capture_contact(jsonb)', 'execute') and has_function_privilege('service_role', 'public.server_capture_contact(jsonb)', 'execute'));
select test.ok('the tables are not readable by visitors', not has_table_privilege('anon', 'contact_captures', 'select') and not has_table_privilege('authenticated', 'capture_sessions', 'select'));
update program_settings set recovery_send_from_hour = 9, recovery_send_until_hour = 21, uptime_quiet_from_hour = 23, uptime_quiet_until_hour = 7;
