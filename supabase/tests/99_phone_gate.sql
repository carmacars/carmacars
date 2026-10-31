-- 99: the phone number box (0280): the light defaults, the number given (transactional contact, CASL marketing consent
-- only when ticked), the capture and lead staff see, the code by text with its limits, the counts and the report, the
-- one-press switches, and what anonymous callers may not do. Fixtures start with "pg".
select test.suite('99 phone number box');
select test.mk_user('pg_admin', 'admin');
select test.mk_user('pg_cs', 'va', 'cs');
update site_settings set phone = coalesce(phone, '+14165550100');
delete from app.rate_limit_hits where key like 'phone-gate%';
create table test.pg (k text primary key, v jsonb);
create function test.pgv(p text) returns jsonb language sql stable as $$ select v from test.pg where k = p $$;
create function test.pg_do(p_key text, p_fn text, p jsonb) returns jsonb language plpgsql as $$
declare v jsonb;
begin
  execute format('select public.%I($1)', p_fn) into v using p;
  insert into test.pg values (p_key, v) on conflict (k) do update set v = excluded.v; return v;
end $$;

-- ================================================================ 1. the defaults, light
select test.eq('defaults: photos on after 6, full availability on, request off, code off, skip off',
  (select r ->> 'gallery' || '/' || (r ->> 'free_photos') || '/' || (r ->> 'dates') || '/' || (r ->> 'request') || '/' || (r ->> 'verify') || '/' || (r ->> 'allow_unverified')
     from (select app.phone_gate_rules() r) x), 'true/6/true/false/false/false');
select test.eq('the cost caps: 3 codes a number, 10 a network address, 200 the site, a day',
  (select phone_gate_texts_per_number_day || '/' || phone_gate_texts_per_ip_day || '/' || phone_gate_texts_per_day from (select (app.settings()).*) s), '3/10/200');
select test.ok('site_facts carries the box (the pages need no other call), still with the earlier facts',
  (public.site_facts() -> 'phone_gate' ->> 'gallery') = 'true' and public.site_facts() ? 'non_refundable_min_days' and public.site_facts() ? 'max_rental_days');
set role anon;
select test.ok('anyone may read site_facts (no personal data in the box rules)', (public.site_facts() -> 'phone_gate') ? 'dates');
select test.throws('anonymous callers cannot save a number straight to the database',
  $$select public.server_phone_gate_save('{"visitor_id": "0f8fad5b-d9cb-469f-a165-70867728950e", "phone": "6475550111", "gate": "dates"}')$$, 'permission denied');
select test.throws('nor read the contacts', $$select count(*) from phone_gate_contacts$$, 'permission denied');
reset role;

-- ================================================================ 2. a number given (no code: the default)
select test.pg_do('a1', 'server_phone_gate_save', jsonb_build_object('visitor_id', test.id('pg-vis-a'), 'phone', '(647) 555-0181', 'gate', 'dates', 'page', '/cars/x', 'ip_key', 'k1'));
select test.eq('saved: E.164, Canada, not verified (the code is off)', (test.pgv('a1') ->> 'ok') || '/' || (test.pgv('a1') ->> 'phone') || '/' || (test.pgv('a1') ->> 'country') || '/' || (test.pgv('a1') ->> 'verified'),
  'true/+16475550181/CA/false');
select test.eq('the transactional contact: consent source phone gate, no marketing without the tick',
  (select consent_source || '/' || transactional || '/' || marketing_opt_in || '/' || coalesce(marketing_text, 'none') || '/' || gate from phone_gate_contacts where visitor_id = test.id('pg-vis-a')),
  'phone_gate/true/false/none/dates');
select test.eq('the capture staff see (Live visitors, Renter leads): the phone number box, done at once (no follow-up To do)',
  (select form || '/' || phone || '/' || (done_at is not null) || '/' || state || '/' || app.capture_form_label(form) from contact_captures where visitor_id = test.id('pg-vis-a')),
  'phone_gate/+16475550181/true/phone_only/phone number box');
select test.eq('its lead: an unfinished form lead with the number, no marketing consent',
  (select l.source || '/' || l.phone || '/' || l.consent_marketing || '/' || (l.payload ->> 'form') from leads l join contact_captures c on c.lead_id = l.id where c.visitor_id = test.id('pg-vis-a')),
  'unfinished_form/+16475550181/false/phone_gate');
select test.eq('Live visitors show it for the visitor', app.capture_for_visitor(test.id('pg-vis-a')) ->> 'phone' || '/' || (app.capture_for_visitor(test.id('pg-vis-a')) ->> 'form'), '+16475550181/phone number box');
select test.ok('the network address is never kept', not exists (select 1 from information_schema.columns where table_name = 'phone_gate_contacts' and column_name ~ 'ip'));

-- the same device ticks "Also text me deals" the next time: consent with the words and the time; unticking never withdraws
select test.pg_do('a2', 'server_phone_gate_save', jsonb_build_object('visitor_id', test.id('pg-vis-a'), 'phone', '6475550181', 'gate', 'gallery', 'marketing', true,
  'marketing_text', 'Also text me deals from CarmaCars. Reply STOP to any text to stop them.'));
select test.eq('ticked: marketing consent with the words and the time, on the contact and the lead',
  (select g.marketing_opt_in || '/' || (g.marketing_at is not null) || '/' || left(g.marketing_text, 18) || '/' || l.consent_marketing || '/' || (l.consent_at is not null)
     from phone_gate_contacts g join leads l on l.id = g.lead_id where g.visitor_id = test.id('pg-vis-a')), 'true/true/Also text me deals/true/true');
select test.pg_do('a3', 'server_phone_gate_save', jsonb_build_object('visitor_id', test.id('pg-vis-a'), 'phone', '6475550181', 'gate', 'dates', 'marketing', false));
select test.eq('one row per device and number; an unticked box later keeps the consent',
  (select count(*) || '/' || bool_and(marketing_opt_in) from phone_gate_contacts where visitor_id = test.id('pg-vis-a')), '1/true');
select test.eq('one capture and one lead for the device', (select count(*) || '/' || count(distinct lead_id) from contact_captures where visitor_id = test.id('pg-vis-a') and form = 'phone_gate'), '1/1');
select test.throws('marketing consent needs the words shown', $$select public.server_phone_gate_save(jsonb_build_object('visitor_id', test.id('pg-vis-q'), 'phone', '6475550182', 'gate', 'dates', 'marketing', true))$$, 'words');

select test.eq('a US number is a valid number', test.pg_do('us', 'server_phone_gate_save', jsonb_build_object('visitor_id', test.id('pg-vis-u'), 'phone', '212 555 0199', 'gate', 'gallery')) ->> 'country', 'US');
select test.eq('not a number', public.server_phone_gate_save(jsonb_build_object('visitor_id', test.id('pg-vis-x'), 'phone', '647 555', 'gate', 'dates')) ->> 'reason', 'invalid');
select test.eq('outside Canada and the US', public.server_phone_gate_save(jsonb_build_object('visitor_id', test.id('pg-vis-x'), 'phone', '+44 20 7946 0958', 'gate', 'dates')) ->> 'reason', 'country');
select test.eq('a Caribbean +1 number is refused too', public.server_phone_gate_save(jsonb_build_object('visitor_id', test.id('pg-vis-x'), 'phone', '876 555 1234', 'gate', 'dates')) ->> 'reason', 'country');
select test.eq('no visitor id: refused', public.server_phone_gate_save(jsonb_build_object('phone', '6475550183', 'gate', 'dates')) ->> 'reason', 'visitor');
do $$ begin for i in 1..20 loop perform public.server_phone_gate_save(jsonb_build_object('visitor_id', test.id('pg-vis-r'), 'phone', '6475550184', 'gate', 'dates')); end loop; end $$;
select test.eq('saves are rate limited per device (20 an hour)', public.server_phone_gate_save(jsonb_build_object('visitor_id', test.id('pg-vis-r'), 'phone', '6475550184', 'gate', 'dates')) ->> 'reason', 'rate_limited');

-- ================================================================ 3. the code by text (the setting on)
update program_settings set phone_gate_verify = true;
select test.eq('code on: a number without its code is refused', public.server_phone_gate_save(jsonb_build_object('visitor_id', test.id('pg-vis-c'), 'phone', '6475550185', 'gate', 'dates')) ->> 'reason', 'code_needed');
select test.eq('code on: "Use without verifying" only when an Admin allows it',
  public.server_phone_gate_save(jsonb_build_object('visitor_id', test.id('pg-vis-c'), 'phone', '6475550185', 'gate', 'dates', 'unverified', true)) ->> 'reason', 'code_needed');
select test.pg_do('c1', 'server_phone_gate_code', jsonb_build_object('visitor_id', test.id('pg-vis-c'), 'phone', '6475550185', 'gate', 'dates', 'ip_key', 'k2', 'code_hash', encode(sha256(convert_to('pg-code-1', 'UTF8')), 'hex')));
select test.eq('a code: allowed, from the CarmaCars number, logged (never the code)', (test.pgv('c1') ->> 'ok') || '/' || (test.pgv('c1') ->> 'from' is not null)
  || '/' || (select status || '/' || purpose from app.auth_sms_log where id = (test.pgv('c1') ->> 'log_id')::uuid), 'true/true/sending/phone_gate');
select test.ok('only the hash of the code is kept', (select code_hash = encode(sha256(convert_to('pg-code-1', 'UTF8')), 'hex') from app.phone_gate_codes where phone = '+16475550185' order by id desc limit 1));
select test.eq('a wrong code', public.server_phone_gate_save(jsonb_build_object('visitor_id', test.id('pg-vis-c'), 'phone', '6475550185', 'gate', 'dates', 'code_hash', encode(sha256(convert_to('wrong', 'UTF8')), 'hex'))) ->> 'reason', 'code');
select test.eq('the right code: verified', public.server_phone_gate_save(jsonb_build_object('visitor_id', test.id('pg-vis-c'), 'phone', '6475550185', 'gate', 'dates', 'code_hash', encode(sha256(convert_to('pg-code-1', 'UTF8')), 'hex'))) ->> 'verified', 'true');
select test.ok('the contact is verified', (select verified_at is not null from phone_gate_contacts where visitor_id = test.id('pg-vis-c')));
select test.eq('a code works once', public.server_phone_gate_save(jsonb_build_object('visitor_id', test.id('pg-vis-c'), 'phone', '6475550185', 'gate', 'dates', 'code_hash', encode(sha256(convert_to('pg-code-1', 'UTF8')), 'hex'))) ->> 'reason', 'code');
select test.eq('another device cannot use this device''s code', (select public.server_phone_gate_code(jsonb_build_object('visitor_id', test.id('pg-vis-c'), 'phone', '6475550185', 'gate', 'dates', 'code_hash', encode(sha256(convert_to('pg-code-2', 'UTF8')), 'hex'))) ->> 'ok')
  || '/' || (public.server_phone_gate_save(jsonb_build_object('visitor_id', test.id('pg-vis-d'), 'phone', '6475550185', 'gate', 'dates', 'code_hash', encode(sha256(convert_to('pg-code-2', 'UTF8')), 'hex'))) ->> 'reason'), 'true/code');
-- five wrong tries end the code
do $$ begin for i in 1..5 loop perform public.server_phone_gate_save(jsonb_build_object('visitor_id', test.id('pg-vis-c'), 'phone', '6475550185', 'gate', 'dates', 'code_hash', encode(sha256(convert_to('bad' || i, 'UTF8')), 'hex'))); end loop; end $$;
select test.eq('after 5 wrong tries even the right code fails', public.server_phone_gate_save(jsonb_build_object('visitor_id', test.id('pg-vis-c'), 'phone', '6475550185', 'gate', 'dates', 'code_hash', encode(sha256(convert_to('pg-code-2', 'UTF8')), 'hex'))) ->> 'reason', 'code');
select test.eq('the number''s limit: 3 codes a day, the 4th refused',
  (public.server_phone_gate_code(jsonb_build_object('visitor_id', test.id('pg-vis-c'), 'phone', '6475550185', 'gate', 'dates', 'code_hash', encode(sha256(convert_to('pg-code-3', 'UTF8')), 'hex'))) ->> 'ok') || '/'
  || (public.server_phone_gate_code(jsonb_build_object('visitor_id', test.id('pg-vis-c'), 'phone', '6475550185', 'gate', 'dates', 'code_hash', encode(sha256(convert_to('pg-code-4', 'UTF8')), 'hex'))) ->> 'reason'), 'true/rate_limited');
select test.eq('the refused code is logged', (select count(*) from app.auth_sms_log where phone = '+16475550185' and status = 'refused' and reason = 'rate_limited' and purpose = 'phone_gate'), 1::bigint);
update program_settings set phone_gate_texts_per_ip_day = 2;
select test.eq('the network address limit (a day)', (public.server_phone_gate_code(jsonb_build_object('visitor_id', test.id('pg-vis-e'), 'phone', '6475550186', 'ip_key', 'k3', 'code_hash', encode(sha256(convert_to('e1', 'UTF8')), 'hex'))) ->> 'ok') || '/'
  || (public.server_phone_gate_code(jsonb_build_object('visitor_id', test.id('pg-vis-e'), 'phone', '6475550187', 'ip_key', 'k3', 'code_hash', encode(sha256(convert_to('e2', 'UTF8')), 'hex'))) ->> 'ok') || '/'
  || (public.server_phone_gate_code(jsonb_build_object('visitor_id', test.id('pg-vis-e'), 'phone', '6475550188', 'ip_key', 'k3', 'code_hash', encode(sha256(convert_to('e3', 'UTF8')), 'hex'))) ->> 'reason'), 'true/true/rate_limited');
update program_settings set phone_gate_texts_per_day = (select hits from app.rate_limit_hits where key = 'phone-gate-site' order by window_start desc limit 1);
select test.eq('the site''s daily cap (the cost cap)', public.server_phone_gate_code(jsonb_build_object('visitor_id', test.id('pg-vis-f'), 'phone', '6475550189', 'code_hash', encode(sha256(convert_to('f1', 'UTF8')), 'hex'))) ->> 'reason', 'rate_limited');
update program_settings set phone_gate_texts_per_day = 200, phone_gate_texts_per_ip_day = 10;
select test.eq('a US number before US texting is on: no code goes, the number is enough',
  (public.server_phone_gate_code(jsonb_build_object('visitor_id', test.id('pg-vis-g'), 'phone', '212 555 0142', 'code_hash', encode(sha256(convert_to('g1', 'UTF8')), 'hex'))) ->> 'reason') || '/'
  || (public.server_phone_gate_save(jsonb_build_object('visitor_id', test.id('pg-vis-g'), 'phone', '212 555 0142', 'gate', 'gallery')) ->> 'ok'), 'no_us_texts/true');
update program_settings set phone_gate_allow_unverified = true;
select test.eq('"Use without verifying" allowed: saved unverified', public.server_phone_gate_save(jsonb_build_object('visitor_id', test.id('pg-vis-h'), 'phone', '6475550190', 'gate', 'dates', 'unverified', true)) ->> 'verified', 'false');
update program_settings set phone_gate_verify = false, phone_gate_allow_unverified = false;
select test.eq('code off: asking for a code is refused (nothing texted)', public.server_phone_gate_code(jsonb_build_object('visitor_id', test.id('pg-vis-c'), 'phone', '6475550191', 'code_hash', encode(sha256(convert_to('x', 'UTF8')), 'hex'))) ->> 'reason', 'off');

-- ================================================================ 4. counting, the report, the switches
select public.server_phone_gate_event(jsonb_build_object('visitor_id', test.id('pg-vis-s'), 'gate', 'gallery', 'event', 'shown'));
select public.server_phone_gate_event(jsonb_build_object('visitor_id', test.id('pg-vis-s'), 'gate', 'gallery', 'event', 'closed'));
select public.server_phone_gate_event(jsonb_build_object('visitor_id', test.id('pg-vis-t'), 'gate', 'dates', 'event', 'shown'));
select test.eq('not a box or an event: ignored', public.server_phone_gate_event('{"gate": "x", "event": "shown"}') ->> 'ok', 'false');
select test.ok('counted per day: shown, closed, given (no personal data in the table)',
  (select shown = 1 and closed = 1 and given >= 2 from phone_gate_daily where day = app.today() and gate = 'gallery')
  and not exists (select 1 from information_schema.columns where table_name = 'phone_gate_daily' and column_name in ('visitor_id', 'phone')));
select test.eq('requests: from a visitor who saw the box, and from one who did not',
  (public.server_phone_gate_request(jsonb_build_object('visitor_id', test.id('pg-vis-s'))) ->> 'gated') || '/'
  || (public.server_phone_gate_request(jsonb_build_object('visitor_id', test.id('pg-vis-new'))) ->> 'gated'), 'true/false');
select test.eq('the day''s requests and those from visitors who saw a box', (select requests || '/' || requests_gated from phone_gate_daily where day = app.today() and gate = 'all'), '2/1');
create temp table pg_rep as select app.door(test.id('pg_admin'), 'aal2', 'admin_read', 'phone_gate_report', '{"days": 30}') as j;
select test.eq('the report: 30 days, today''s counts, first shown today, the rules',
  (select jsonb_array_length(j -> 'days') || '/' || (j -> 'days' -> 0 ->> 'shown') || '/' || (j -> 'days' -> 0 ->> 'requests_gated') || '/' || (j ->> 'first_shown' = app.today()::text) || '/' || (j -> 'rules' ->> 'dates') from pg_rep),
  '30/2/1/true/true');
select test.ok('the report counts the marketing ticks', (select (j ->> 'marketing_opt_ins')::int >= 1 from pg_rep));
select test.throws('the report is for Admins', $$select app.door(test.id('pg_cs'), 'aal2', 'admin_read', 'phone_gate_report', '{}')$$, 'for Admins');
select test.eq('one press turns a box off (a settings row from today)', app.door(test.id('pg_admin'), 'aal2', 'admin_do', 'phone_gate_switch', '{"gate": "gallery", "on": false}') ->> 'gallery', 'false');
select test.eq('and the pages see it', public.site_facts() -> 'phone_gate' ->> 'gallery', 'false');
select test.eq('and back on', app.door(test.id('pg_admin'), 'aal2', 'admin_do', 'phone_gate_switch', '{"gate": "gallery", "on": true}') ->> 'gallery', 'true');
select test.throws('switches are for Admins', $$select app.door(test.id('pg_cs'), 'aal2', 'admin_do', 'phone_gate_switch', '{"gate": "dates", "on": false}')$$, 'for Admins');
select test.throws('a box that does not exist', $$select app.door(test.id('pg_admin'), 'aal2', 'admin_do', 'phone_gate_switch', '{"gate": "nope", "on": false}')$$, 'which box');
select test.ok('earlier doors still answer (the chain)', (app.door(test.id('pg_admin'), 'aal2', 'admin_read', 'quo_contacts_status', '{}') ? 'enabled'));
