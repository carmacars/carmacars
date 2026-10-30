-- 99: Quo contacts that match the site, and names for live visitors (migration 0190,
-- docs/changes/2026-10-27-quo-contacts-visitor-names.md). Who a number is (the strongest record wins), the triggers that
-- mark a number when a person changes, the job's side (due, leased, Quo's list read first, done, errors and back-off, a
-- pause without a key, the cron gate), Settings > Quo contacts and Sync everyone again; a visitor named by staff (shown
-- everywhere, kept for the browser, consistent when they book or chat, the phone reaching Quo), and the privileges.
-- Fixtures start with "qct"; fictional people and 555 numbers only.
select test.suite('99 quo contacts');
grant usage on schema test to service_role;
grant execute on all functions in schema test to authenticated, anon, service_role;

-- the rows other suites left are not ours: start from a clean queue and an unread Quo list
update quo_contacts set dirty_at = null, leased_until = null;
update quo_contacts_state set scan_status = 'pending', scan_cursor = null, scan_seen = 0, scan_matched = 0, paused_until = null, pause_reason = null;

select test.mk_user('qct_admin', 'admin');
select test.mk_user('qct_cs', 'va', 'cs');
select test.mk_user('qct_fin', 'va', 'finance');
select test.mk_renter('qct_r1');
select test.mk_renter('qct_r2');
create function test.qn(p integer) returns text language sql immutable as $$ select '+1647555' || lpad((100 + p)::text, 4, '0') $$;
create function test.qrow(p integer) returns quo_contacts language sql stable as $$ select * from quo_contacts where number = test.qn(p) $$;
create function test.qdue(p integer) returns jsonb language sql as $$
  select coalesce((select r from jsonb_array_elements(app.server_quo_contacts_due(200) -> 'rows') r where r ->> 'number' = test.qn(p)), 'null'::jsonb) $$;

-- ================================================================ 1. who a number is, and the marks
update renters set mobile = '(647) 555-0171', legal_name = 'Ria  Sample Person', email = 'qct.ria@example.test' where id = test.id('renter:qct_r1');
select test.ok('mark: a renter''s new mobile marks the number', (test.qrow(71)).dirty_at is not null);
select test.eq('person: the renter, first name and the rest, email, role',
  app.quo_person(test.qn(71)) - 'ref_id', jsonb_build_object('number', test.qn(71), 'kind', 'renter', 'first_name', 'Ria', 'last_name', 'Sample Person',
    'email', 'qct.ria@example.test', 'company', null, 'role', 'Renter'));
update quo_contacts set dirty_at = null where number = test.qn(71);
update renters set city = 'Testville' where id = test.id('renter:qct_r1');
select test.ok('mark: a change Quo does not show marks nothing', (test.qrow(71)).dirty_at is null);
update renters set legal_name = 'Ria Sample' where id = test.id('renter:qct_r1');
select test.ok('mark: a new name marks the number', (test.qrow(71)).dirty_at is not null);
update renters set mobile = '647-555-0172' where id = test.id('renter:qct_r2');
update quo_contacts set dirty_at = null where number in (test.qn(71), test.qn(72));
update renters set mobile = '647-555-0172' where id = test.id('renter:qct_r1');
select test.ok('mark: a changed phone marks the new number and the old one', (test.qrow(71)).dirty_at is not null and (test.qrow(72)).dirty_at is not null);
update renters set mobile = '647-555-0171' where id = test.id('renter:qct_r1');
select test.eq('person: a number left with one renter is theirs', app.quo_person(test.qn(72)) ->> 'first_name', 'Qct');
update users set phone = '647 555 0171' where id = test.id('qct_cs');
select test.eq('person: staff win over a renter with the same number', (app.quo_person(test.qn(71)) ->> 'kind') || '/' || (app.quo_person(test.qn(71)) ->> 'company'), 'staff/CarmaCars');
update users set phone = null where id = test.id('qct_cs');
select test.eq('person: back to the renter once the staff member''s phone is gone', app.quo_person(test.qn(71)) ->> 'kind', 'renter');
insert into leads (kind, name, email, phone, business_name) values ('contact', 'Lee Lead', 'qct.lee@example.test', '647-555-0173', 'Lee Rentals Co');
select test.eq('person: a lead, with their company', (app.quo_person(test.qn(73)) ->> 'role') || '/' || (app.quo_person(test.qn(73)) ->> 'company'), 'Lead/Lee Rentals Co');
insert into leads (kind, email, phone) values ('contact', 'qct.anon@example.test', '647-555-0174');
select test.ok('person: a number nobody named is nobody', app.quo_person(test.qn(74)) is null);
update site_settings set phone = '647-555-0175';
insert into leads (kind, name, phone) values ('contact', 'Our Own Line', '647-555-0175');
select test.ok('person: the CarmaCars number itself is never a contact', app.quo_person(test.qn(75)) is null);

-- ================================================================ 2. the job: Quo's list first, then each person
select test.ok('due: the cron gate''s phone job runs for a number waiting', (app.server_jobs_due() ->> 'phone')::boolean and app.quo_contacts_due_any());
create temp table qct_due as select app.server_quo_contacts_due(200) as j;
select test.ok('due: nobody named: set aside without a call', not exists (select 1 from qct_due, jsonb_array_elements(j -> 'rows') r where r ->> 'number' = test.qn(74))
  and (test.qrow(74)).state = 'skipped' and (test.qrow(74)).dirty_at is null);
select test.ok('due: a new contact waits while Quo''s list is not read', not exists (select 1 from qct_due, jsonb_array_elements(j -> 'rows') r where r ->> 'number' = test.qn(71))
  and (test.qrow(71)).dirty_at is not null and (select (j #>> '{scan,needed}')::boolean from qct_due));
select test.eq('found: a contact Quo already has with the number becomes theirs',
  app.server_quo_contacts_found(jsonb_build_object('contacts', jsonb_build_array(jsonb_build_object('id', 'CTqct73', 'phones', jsonb_build_array('+1 (647) 555-0173', 'nope'))), 'cursor', 'p2', 'done', false)) ->> 'matched', '1');
select test.eq('found: kept with the page to read next', (select scan_cursor || '/' || scan_status from quo_contacts_state), 'p2/pending');
select test.ok('due: an update of a contact Quo has goes before the list is read', test.qdue(73) ->> 'quo_id' = 'CTqct73');
select test.eq('due: given out once', test.qdue(73), 'null'::jsonb);
select test.ok('due: leased for 10 minutes', (test.qrow(73)).leased_until > now() + interval '9 minutes');
select app.server_quo_contacts_found('{"contacts": [], "cursor": null, "done": true}');
select test.eq('found: the list is read', (select scan_status from quo_contacts_state), 'done');
create temp table qct_r71 as select test.qdue(71) as j;
select test.eq('due: the person, their hash and our external id',
  (select (j #>> '{person,first_name}') || '/' || (j ->> 'external_id') || '/' || (j ->> 'hash' = app.quo_hash(j -> 'person'))::text from qct_r71), 'Ria/cc-16475550171/true');
select app.server_quo_contact_done((select jsonb_build_object('number', test.qn(71), 'ok', true, 'quo_id', 'CTqct71', 'hash', j ->> 'hash', 'dirty_at', j ->> 'dirty_at', 'person', j -> 'person') from qct_r71));
select test.eq('done: synced, with the Quo id and what was sent', (select state || '/' || quo_id || '/' || first_name || '/' || (dirty_at is null)::text || '/' || (leased_until is null)::text from quo_contacts where number = test.qn(71)),
  'synced/CTqct71/Ria/true/true');
select app.quo_contact_mark(test.qn(71));
select test.eq('due: marked again with nothing new for Quo: not given out', test.qdue(71), 'null'::jsonb);
select test.ok('due: ... and closed without a call', (test.qrow(71)).dirty_at is null and (test.qrow(71)).state = 'synced');
update renters set email = 'qct.ria2@example.test' where id = test.id('renter:qct_r1');
truncate qct_r71; insert into qct_r71 select test.qdue(71);
update renters set legal_name = 'Ria Sample-Two' where id = test.id('renter:qct_r1');
select app.server_quo_contact_done((select jsonb_build_object('number', test.qn(71), 'ok', true, 'quo_id', 'CTqct71', 'hash', j ->> 'hash', 'dirty_at', j ->> 'dirty_at', 'person', j -> 'person') from qct_r71));
select test.ok('done: a change made while the job called Quo is sent next time', (test.qrow(71)).dirty_at is not null and (test.qrow(71)).state = 'synced');
update quo_contacts set leased_until = null, next_try_at = now() where number = test.qn(71);
select test.eq('due: with the new name and the existing id', (select (j #>> '{person,last_name}') || '/' || (j ->> 'quo_id') from (select test.qdue(71) j) x), 'Sample-Two/CTqct71');
select app.server_quo_contact_done(jsonb_build_object('number', test.qn(71), 'ok', false, 'error', 'Quo did not answer: timeout', 'permanent', false));
select test.ok('done: an error is kept, tried again later (5 minutes, then longer)', (test.qrow(71)).state = 'error' and (test.qrow(71)).attempts = 1
  and (test.qrow(71)).next_try_at between now() + interval '4 minutes' and now() + interval '6 minutes' and (test.qrow(71)).dirty_at is not null);
update quo_contacts set next_try_at = now() where number = test.qn(71);
select test.ok('due: tried again once its time comes', test.qdue(71) ->> 'number' = test.qn(71));
select app.server_quo_contact_done(jsonb_build_object('number', test.qn(71), 'ok', false, 'error', 'Quo 400: bad request', 'permanent', true));
select test.ok('done: a refusal that will not get better waits for the next change', (test.qrow(71)).state = 'error' and (test.qrow(71)).dirty_at is null and (test.qrow(71)).attempts = 2
  and (test.qrow(71)).next_try_at > now() + interval '9 minutes');

-- ================================================================ 3. pause, off, Settings > Quo contacts
select app.quo_contact_mark(test.qn(72));
select app.server_quo_contacts_run('{"ok": false, "paused_reason": "QUO_API_KEY is not set"}');
select test.ok('pause: no key: the job pauses for 6 hours and says why', (app.server_quo_contacts_due(10) ->> 'paused')::boolean and not app.quo_contacts_due_any()
  and (select paused_until > now() + interval '5 hours' and last_error = 'QUO_API_KEY is not set' from quo_contacts_state));
select test.eq('status: the Admin sees the counts, the pause and the errors',
  (select (s ->> 'pause_reason') || '/' || ((s ->> 'errors')::int >= 1)::text || '/' || ((s ->> 'waiting')::int >= 1)::text || '/' || (s -> 'recent_errors' -> 0 ->> 'number')
     from (select app.door(test.id('qct_admin'), 'aal2', 'admin_read', 'quo_contacts_status', '{}') s) x), 'QUO_API_KEY is not set/true/true/' || test.qn(71));
select test.throws('status: Admins only', $$select app.door(test.id('qct_cs'), 'aal2', 'admin_read', 'quo_contacts_status', '{}')$$, 'for Admins');
create temp table qct_resync as select app.door(test.id('qct_admin'), 'aal2', 'admin_do', 'quo_contacts_resync', '{}') as j;
select test.ok('resync: everyone again, the list read again, the pause lifted',
  (select (j ->> 'numbers')::int >= 6 from qct_resync)
  and (select scan_status = 'pending' and paused_until is null from quo_contacts_state) and (test.qrow(71)).dirty_at is not null and (test.qrow(71)).synced_hash is null
  and exists (select 1 from audit_log where action = 'quo_contacts_resync' and actor_user_id = test.id('qct_admin')));
select app.server_quo_contacts_run('{"ok": true, "created": 1}');
select test.ok('run: a good run is recorded', (select last_ok_at > now() - interval '1 minute' and paused_until is null from quo_contacts_state));
update program_settings set phone_quo_contacts = false;
select test.ok('off: the setting off stops the job', not ((app.server_quo_contacts_due(10) ->> 'enabled')::boolean) and not app.quo_contacts_due_any());
update program_settings set phone_quo_contacts = true;

-- ================================================================ 4. naming a live visitor
insert into visitor_sessions (id, visitor_id, city, device, last_seen_at) values (test.id('qct_s1'), test.id('qct_v1'), 'Toronto', 'phone', now());
insert into visitor_sessions (id, visitor_id, city, device, last_seen_at) values (test.id('qct_s2'), test.id('qct_v2'), 'Toronto', 'desktop', now());
select test.eq('visitor: before a name, "Visitor from Toronto, phone"', (select app.visitor_who(s) from visitor_sessions s where s.id = test.id('qct_s1')), 'Visitor from Toronto, phone');
select test.throws('name: finance staff cannot', $$select app.door(test.id('qct_fin'), 'aal2', 'va_do', 'live_name', jsonb_build_object('session_id', test.id('qct_s1'), 'name', 'Sam'))$$, 'customer service');
select test.throws('name: a bad phone is refused', $$select app.door(test.id('qct_cs'), 'aal2', 'va_do', 'live_name', jsonb_build_object('session_id', test.id('qct_s1'), 'name', 'Sam', 'phone', '12'))$$, 'phone number does not look right');
select test.throws('name: a name is needed', $$select app.door(test.id('qct_cs'), 'aal2', 'va_do', 'live_name', jsonb_build_object('session_id', test.id('qct_s1'), 'name', '  '))$$, 'Type the visitor');
select test.eq('name: customer service names a visitor, with a phone and a note',
  app.door(test.id('qct_cs'), 'aal2', 'va_do', 'live_name', jsonb_build_object('session_id', test.id('qct_s1'), 'name', ' Sam   Visitor ', 'phone', '(647) 555-0176', 'email', 'QCT.Sam@Example.test', 'note', 'Asked about the van')) #>> '{label,phone}',
  test.qn(76));
select test.eq('name: shown on Live visitors (the row and its label)',
  (select (r ->> 'who') || '/' || (r #>> '{label,note}') || '/' || (r #>> '{label,email}') || '/' || (r #>> '{label,by}') || '/' || (r ->> 'known') from (select app.visitor_session_row(s) r from visitor_sessions s where s.id = test.id('qct_s1')) x),
  'Sam Visitor/Asked about the van/qct.sam@example.test/Qct/true');
insert into visitor_sessions (id, visitor_id, city, device, last_seen_at) values (test.id('qct_s1b'), test.id('qct_v1'), 'Toronto', 'phone', now());
select test.eq('name: kept for the browser''s next visit', (select app.visitor_who(s) from visitor_sessions s where s.id = test.id('qct_s1b')), 'Sam Visitor');
select test.ok('name: never shown to the visitor (the session''s own name is untouched)', (select known_name is null from visitor_sessions where id = test.id('qct_s1b')));
select test.eq('name: the phone becomes a Quo contact', (app.quo_person(test.qn(76)) ->> 'first_name') || '/' || (app.quo_person(test.qn(76)) ->> 'role') || '/' || ((test.qrow(76)).dirty_at is not null)::text,
  'Sam/Website visitor/true');
select test.eq('name: a caller with that phone shows by the name (not linked to the visit: the visitor never sees the name)',
  (app.phone_match(test.qn(76)) ->> 'name') || '/' || coalesce(app.phone_match(test.qn(76)) ->> 'visitor_id', 'none'), 'Sam Visitor/none');
insert into leads (kind, name, phone) values ('contact', 'Sam Lead', '647-555-0176');
select test.eq('name: a number a record names keeps that name and gets the visit', (app.phone_match(test.qn(76)) ->> 'name') || '/' || (app.phone_match(test.qn(76)) ->> 'visitor_id'),
  'Sam Lead/' || test.id('qct_v1')::text);
delete from leads where name = 'Sam Lead';
insert into chat_conversations (session_id, visitor_id, name, email) values (test.id('qct_s1'), test.id('qct_v1'), 'S', null);
select test.eq('name: the chat shows it', (select app.visitor_chat_name(c) from chat_conversations c where c.visitor_id = test.id('qct_v1')), 'Sam Visitor');
insert into chat_conversations (session_id, visitor_id, name, email) values (test.id('qct_s2'), test.id('qct_v2'), 'Sammy', 'qct.sam@example.test');
select test.eq('consistent: a chat from another browser with the same email gets the same name',
  (select app.visitor_chat_name(c) from chat_conversations c where c.visitor_id = test.id('qct_v2')) || '/' || (select source from visitor_names where visitor_id = test.id('qct_v2')), 'Sam Visitor/match');
select test.eq('consistent: on Live visitors too', (select app.visitor_who(s) from visitor_sessions s where s.id = test.id('qct_s2')), 'Sam Visitor');
update visitor_sessions set renter_id = test.id('renter:qct_r2') where id = test.id('qct_s1b');
select test.eq('consistent: once they book (a renter), the name the site has saved', (select name || '/' || source from visitor_names where visitor_id = test.id('qct_v1')), 'Qct R2/renter');
select app.door(test.id('qct_admin'), 'aal2', 'admin_do', 'live_name', jsonb_build_object('visitor_id', test.id('qct_v2'), 'remove', true));
select test.ok('name: removed', not exists (select 1 from visitor_names where visitor_id = test.id('qct_v2'))
  and (select app.visitor_who(s) from visitor_sessions s where s.id = test.id('qct_s2')) <> 'Sam Visitor');

-- ================================================================ 5. privileges
select test.ok('privileges: the job''s calls and the tables are not for browsers',
  not has_function_privilege('anon', 'public.server_quo_contacts_due(integer)', 'execute')
  and not has_function_privilege('authenticated', 'public.server_quo_contact_done(jsonb)', 'execute')
  and not has_function_privilege('authenticated', 'app.visitor_name_set(uuid, jsonb)', 'execute')
  and not has_table_privilege('authenticated', 'quo_contacts', 'select') and not has_table_privilege('anon', 'visitor_names', 'select')
  and has_function_privilege('service_role', 'public.server_quo_contacts_due(integer)', 'execute'));
