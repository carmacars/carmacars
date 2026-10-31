-- 99: when the email limit is hit, booking and pickup messages still reach renters by text (migration 0212). Fixtures start
-- with "elt"; the numbers are 555 test numbers.
select test.suite('99 email limit texts');
select test.mk_user('elt_admin', 'admin');
select test.mk_user('elt_cs', 'va', 'cs');
create temp table elt_phone as select (app.settings()).phone_enabled v;
update program_settings set phone_enabled = true where id = (app.settings()).id;
insert into renters (id, legal_name, email, mobile) values
  (test.id('renter:elt_a'), 'Elta Renter', 'elt.a@example.test', '416-555-0181'),
  (test.id('renter:elt_b'), 'Eltb Renter', 'elt.b@example.test', null),
  (test.id('renter:elt_c'), 'Eltc Renter', 'elt.c@example.test', '416-555-0183');
create or replace function test.elt_put(p_key text, p_code text, p_renter text) returns uuid language sql as $$
  insert into notification_outbox (code, category, priority, audience, to_address, renter_id, payload, dedupe_key, status, send_after)
  values (p_code, 'transactional', 1, 'renter', (select email from renters where id = test.id(p_renter)), test.id(p_renter),
          jsonb_build_object('booking_number', 'CC-E' || p_key, 'pickup_time', '10:00 am', 'pickup_place', 'our Toronto location', 'first_name', 'Elt'),
          'elt:' || p_key, 'queued', now())
  returning id
$$;
select test.ok('on by default, with the booking and pickup codes', (select email_limit_texts and 'renter_pickup_details' = any (email_limit_text_codes) and 'document_signing_code' = any (email_limit_text_codes) from site_settings where singleton));

-- the provider's daily limit holds the pickup details: the text goes at once, once
create temp table elt as select 'a'::text k, test.elt_put('a', 'renter_pickup_details', 'renter:elt_a') id;
update notification_outbox set status = 'sending' where id = (select id from elt where k = 'a');
select app.outbox_defer((select id from elt where k = 'a'), 'the email provider''s daily limit', now() + interval '6 hours');
select test.ok('held for the provider''s limit: texted to the renter''s mobile, with the key line and the portal link',
  exists (select 1 from notification_outbox n join phone_outbox p on p.id = n.limit_text_id where n.id = (select id from elt where k = 'a')
           and n.status = 'delayed' and n.limit_texted_at is not null and p.to_number = '+14165550181' and p.status = 'queued' and p.urgent
           and p.body like '%pickup today at 10:00 am%' and p.body like '%/account/bookings/CC-Ea/pickup?m=' || n.id || '%'));
select test.ok('the email itself still waits for the limit to lift', (select status = 'delayed' and send_after > now() from notification_outbox where id = (select id from elt where k = 'a')));
update notification_outbox set status = 'sending' where id = (select id from elt where k = 'a');
select app.outbox_defer((select id from elt where k = 'a'), 'the email provider''s daily limit', now() + interval '6 hours');
select test.eq('held again: no second text', (select count(*) from phone_outbox where notification_id = (select id from elt where k = 'a')), 1::bigint);
select test.ok('the text is in the audit log', exists (select 1 from audit_log where action = 'email_texted_instead' and entity_id = (select id::text from elt where k = 'a')));

-- our own daily limit (app.outbox_claim) holds a confirmation the same way
insert into elt select 'c', test.elt_put('c', 'renter_booking_confirmed', 'renter:elt_c');
update notification_outbox set status = 'delayed', status_reason = 'daily email limit', send_after = now() + interval '6 hours' where id = (select id from elt where k = 'c');
select test.ok('held for our daily limit: texted', (select limit_text_id is not null from notification_outbox where id = (select id from elt where k = 'c')));

-- not every email: a receipt waits as before; no mobile, no text; the switch off, no text
insert into elt select 'r', test.elt_put('r', 'renter_payment_receipt', 'renter:elt_a');
update notification_outbox set status = 'delayed', status_reason = 'daily email limit' where id = (select id from elt where k = 'r');
select test.ok('a receipt is not texted', (select limit_text_id is null from notification_outbox where id = (select id from elt where k = 'r')));
insert into elt select 'b', test.elt_put('b', 'renter_pickup_details', 'renter:elt_b');
update notification_outbox set status = 'delayed', status_reason = 'daily email limit' where id = (select id from elt where k = 'b');
select test.ok('no mobile on file: no text', (select limit_text_id is null from notification_outbox where id = (select id from elt where k = 'b')));
update site_settings set email_limit_texts = false where singleton;
insert into elt select 'o', test.elt_put('o', 'renter_pickup_details', 'renter:elt_c');
update notification_outbox set status = 'delayed', status_reason = 'daily email limit' where id = (select id from elt where k = 'o');
select test.ok('the switch off: no text', (select limit_text_id is null from notification_outbox where id = (select id from elt where k = 'o')));
update site_settings set email_limit_texts = true where singleton;
update notification_outbox set status_reason = 'held by the email provider''s rate limit' where id = (select id from elt where k = 'o');
select test.ok('a rate-limit hold (a minute) is not the email limit: no text', (select app.outbox_text((select id from elt where k = 'o'), null) ->> 'reason') = 'not held for the limit');

-- Admin > Email: Text it instead
select test.throws('Admins only', format($s$select public.door(%L, 'aal2', 'admin_do', 'outbox_text', '{"id": "%s"}')$s$, test.id('elt_cs'), (select id from elt where k = 'r')));
select test.eq('an Admin texts a held receipt instead', (public.door(test.id('elt_admin'), 'aal2', 'admin_do', 'outbox_text', jsonb_build_object('id', (select id from elt where k = 'r'))) ->> 'status'), 'queued');
select test.throws('once per email', format($s$select public.door(%L, 'aal2', 'admin_do', 'outbox_text', '{"id": "%s"}')$s$, test.id('elt_admin'), (select id from elt where k = 'r')), 'Already texted');
select test.throws('no mobile: said so', format($s$select public.door(%L, 'aal2', 'admin_do', 'outbox_text', '{"id": "%s"}')$s$, test.id('elt_admin'), (select id from elt where k = 'b')), 'No mobile');

-- the signing code by text: the code itself
insert into elt select 's', test.elt_put('s', 'renter_signing_code', 'renter:elt_c');
update notification_outbox set payload = payload || '{"code": "482913", "minutes": "10"}' where id = (select id from elt where k = 's');
update notification_outbox set status = 'delayed', status_reason = 'the email provider''s monthly limit' where id = (select id from elt where k = 's');
select test.ok('a signing code held: the code by text', exists (select 1 from notification_outbox n join phone_outbox p on p.id = n.limit_text_id
  where n.id = (select id from elt where k = 's') and p.body like 'CarmaCars: your signing code is 482913. It is valid 10 minutes.%'));

-- capped: sign-in opens on the phone, the signing code is offered by text
select test.ok('capped while the provider holds emails', app.email_capped(now()));
select test.ok('the sign-in page is told', (public.server_email_capped() ->> 'capped')::boolean);
update notification_outbox set status = 'skipped', status_reason = 'test' where id in (select id from elt);
select test.ok('not capped once nothing is held and the count is under the cap', not app.email_capped(now()) or (app.email_usage(now()) ->> 'total')::int >= (app.email_usage(now()) ->> 'cap')::int);

update program_settings set phone_enabled = (select v from elt_phone) where id = (app.settings()).id;
delete from phone_outbox where notification_id in (select id from elt);
