-- 99: R50 hotfix 2 (5092). The SES and Cloudflare reports of send-outbox are read the same when bound as a JSON string
-- (the server's old build), so SES is marked seen and tried. The call screen's contacts: Sales see only their own leads,
-- masked, and the call finds the number by the record; customer service also finds renters, with the full number.
-- Fixtures start with "zrc5"; every address is example.test.
select test.suite('99 r50 hotfix 2: SES reports as JSON strings, the call screen contacts (5092)');

create temp table zrc5_eps as select ses_seen_at, ses_failed_at, ses_ok_at from email_provider_state limit 1;
insert into email_provider_state default values on conflict do nothing;
update email_provider_state set ses_seen_at = null, ses_failed_at = null where id;

-- ================================================================ 1. a report bound as a JSON string
select public.server_ses_email_result(to_jsonb('{"seen": true}'::text));
select test.eq('a {seen} report sent as a JSON string marks SES seen and records no refusal',
  (select (ses_seen_at > now() - interval '1 minute') || '/' || (ses_failed_at is null)::text from email_provider_state limit 1), 'true/true');
select public.server_ses_email_result('{"ok": true}'::jsonb);
select test.eq('the object form still works', (select (ses_ok_at > now() - interval '1 minute')::text from email_provider_state limit 1), 'true');
select test.eq('a plain string that is not JSON is passed on unchanged', app.jsonb_arg(to_jsonb('not json'::text)), to_jsonb('not json'::text));
select test.eq('the Cloudflare report reads the JSON string too',
  public.server_cf_email_result(to_jsonb('{"ok": true}'::text)) is not null, true);

update email_provider_state e set ses_seen_at = z.ses_seen_at, ses_failed_at = z.ses_failed_at, ses_ok_at = z.ses_ok_at from zrc5_eps z where e.id;

-- ================================================================ 2. contacts for the call screen
select test.mk_user('zrc5_sales', 'va', 'sales');
select test.mk_user('zrc5_sales2', 'va', 'sales');
select test.mk_user('zrc5_cs', 'va', 'cs');
select test.mk_renter('zrc5_renter');
update renters set legal_name = 'Zrcfive Renter', mobile = '+14165550271' where id = test.id('renter:zrc5_renter');
insert into leads (id, kind, name, phone, source, assigned_to) values
  (test.id('zrc5_lead_mine'), 'contact', 'Zrcfive Mine', '(416) 555-0281', 'web', test.id('zrc5_sales')),
  (test.id('zrc5_lead_other'), 'contact', 'Zrcfive Other', '(416) 555-0282', 'web', test.id('zrc5_sales2'));
-- test staff are not onboarded, so the assignee is cleared: Sales's own lead here is the one they claimed
select set_config('app.lead_admin_move', 'on', false);   -- the fixture holds more claims than a new salesperson's cap (the cap depends on settings other files change)
insert into lead_claims (lead_id, claimed_by, expires_at, cap_at) values (test.id('zrc5_lead_mine'), test.id('zrc5_sales'), now() + interval '10 minutes', now() + interval '1 hour');
select set_config('app.lead_admin_move', '', false);

select test.eq('Sales find only their own lead, by name',
  (select string_agg(c ->> 'name', ',') from jsonb_array_elements(public.server_voice_contacts(test.id('zrc5_sales'), '{"q": "zrcfive"}')) c), 'Zrcfive Mine');
select test.eq('Sales see the number masked, with the lead to call it by',
  (select (c ->> 'number') || '|' || (c ->> 'lead') from jsonb_array_elements(public.server_voice_contacts(test.id('zrc5_sales'), '{"q": "zrcfive"}')) c),
  '(416) ' || repeat(chr(8226), 3) || '-' || repeat(chr(8226), 2) || '81|' || test.id('zrc5_lead_mine'));
select test.eq('the masked number shown is kept for the server to find (0970)',
  exists (select 1 from phone_masks m where m.user_id = test.id('zrc5_sales') and m.number = '+14165550281'), true);
select test.eq('the call goes by the record: the server finds the full number',
  public.server_phone_unmask(test.id('zrc5_sales'), jsonb_build_object('masked', '(416) ' || repeat(chr(8226), 3) || '-' || repeat(chr(8226), 2) || '81', 'lead', test.id('zrc5_lead_mine'))),
  '+14165550281');
select test.eq('customer service find renters and leads with the full number',
  (select string_agg((c ->> 'name') || '=' || (c ->> 'number'), ',' order by c ->> 'name') from jsonb_array_elements(public.server_voice_contacts(test.id('zrc5_cs'), '{"q": "zrcfive"}')) c),
  'Zrcfive Mine=+14165550281,Zrcfive Other=+14165550282,Zrcfive Renter=+14165550271');
select test.eq('a search by digits finds the renter',
  (select string_agg(c ->> 'name', ',') from jsonb_array_elements(public.server_voice_contacts(test.id('zrc5_cs'), '{"q": "555-0271"}')) c), 'Zrcfive Renter');
select test.eq('one letter finds nothing yet', public.server_voice_contacts(test.id('zrc5_cs'), '{"q": "z"}'), '[]'::jsonb);
insert into outbound_calls (staff_user_id, to_number, staff_number, lead_id, via, started_at)
values (test.id('zrc5_sales'), '+14165550281', 'browser', test.id('zrc5_lead_mine'), 'browser', now());
select test.eq('with no search, the people called last',
  (select string_agg(c ->> 'name', ',') from jsonb_array_elements(public.server_voice_contacts(test.id('zrc5_sales'), '{}')) c), 'Zrcfive Mine');
select test.throws('a renter has no contacts', $$select public.server_voice_contacts(test.id('zrc5_renter'), '{}')$$, '%Texts and calls%');
-- review fix: only the phone staff (Admins, customer service, Sales and Fleet; 0970) may search, as phone_renter_search
select test.mk_user('zrc5_fin', 'va', 'finance');
select test.mk_user('zrc5_field', 'field');
select test.throws('a finance VA (no phone function) cannot search the contacts', $$select public.server_voice_contacts(test.id('zrc5_fin'), '{"q": "zrcfive"}')$$, '%Texts and calls%');
select test.throws('a field user cannot search the contacts', $$select public.server_voice_contacts(test.id('zrc5_field'), '{"q": "zrcfive"}')$$, '%Texts and calls%');
-- review fix: %, _ and \ in a search are plain characters, not wildcards
select test.eq('a search of %% finds nobody', public.server_voice_contacts(test.id('zrc5_cs'), '{"q": "%%"}'), '[]'::jsonb);
select test.eq('a search of __ finds nobody', public.server_voice_contacts(test.id('zrc5_cs'), '{"q": "__"}'), '[]'::jsonb);
select test.eq('a search of \\ finds nobody', public.server_voice_contacts(test.id('zrc5_cs'), jsonb_build_object('q', 'Zrcfive' || chr(92))), '[]'::jsonb);
-- review fix: a name that holds a number is masked for Sales too
insert into leads (id, kind, name, phone, source) values (test.id('zrc5_lead_digits'), 'contact', 'Zrcdigits 416-555-0291', '(416) 555-0283', 'web');
select set_config('app.lead_admin_move', 'on', false);   -- the fixture holds more claims than a new salesperson's cap (the cap depends on settings other files change)
insert into lead_claims (lead_id, claimed_by, expires_at, cap_at) values (test.id('zrc5_lead_digits'), test.id('zrc5_sales'), now() + interval '10 minutes', now() + interval '1 hour');
select set_config('app.lead_admin_move', '', false);
select test.eq('Sales see a number inside a name masked',
  (select (position('0291' in (c ->> 'name')) = 0 and (c ->> 'name') like 'Zrcdigits %' and (c ->> 'number') not like '%0283')::text
     from jsonb_array_elements(public.server_voice_contacts(test.id('zrc5_sales'), '{"q": "zrcdigits"}')) c), 'true');
select test.eq('customer service see the name as it is',
  (select string_agg(c ->> 'name', ',') from jsonb_array_elements(public.server_voice_contacts(test.id('zrc5_cs'), '{"q": "zrcdigits"}')) c), 'Zrcdigits 416-555-0291');
select test.eq('only the server calls it',
  (select count(*) from pg_proc p join pg_namespace n on n.oid = p.pronamespace
    where n.nspname in ('public', 'app') and p.proname in ('server_voice_contacts', 'voice_contacts', 'jsonb_arg')
      and (has_function_privilege('anon', p.oid, 'execute') or has_function_privilege('authenticated', p.oid, 'execute'))), 0::bigint);

