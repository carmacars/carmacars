-- 99: migrations 0950 and 0955 (release 35, part Y). One Sales lead list with claims (hold, extend, unclaim, expire, the most
-- a person holds, reassign, Next lead), outcomes and the Sales dashboard numbers; every lead alert links its lead; a live
-- chat lead says "Live chat" and shows its phone; missed calls become leads. Renter records of one person merge by
-- themselves on a strong match only, the other email signs in to the kept account, and an Admin can undo the merge.
-- Fixtures start with "zly"; every address is example.test.
select test.suite('99 r35y sales leads and account merge (0950, 0955)');
grant usage on schema test to service_role;

select test.mk_user('zly_admin', 'admin');
select test.mk_user('zly_s1', 'va', 'sales');
select test.mk_user('zly_s2', 'va', 'sales');
select test.mk_user('zly_s3', 'va', 'sales');
select test.mk_user('zly_cs', 'va', 'cs');
select test.mk_user('zly_fleet', 'va', 'fleet');

create function test.zly(p_user text, p_call text, p_name text, p jsonb default '{}'::jsonb) returns jsonb language sql as $$
  select app.door(test.id(p_user), 'aal2', p_call, p_name, p) $$;
create function test.zly_lead(p_label text, p_kind text, p_source text, p_name text, p_email text, p_phone text, p_payload jsonb default '{}'::jsonb, p_ago interval default '5 minutes') returns uuid
language plpgsql as $$
begin
  insert into leads (id, kind, source, name, email, phone, message, payload, status, created_at)
  values (test.id('lead:' || p_label), p_kind, p_source, p_name, p_email, p_phone, 'Hello from ' || p_label, p_payload, 'new', now() - p_ago);
  return test.id('lead:' || p_label);
end $$;

select test.zly_lead('chat', 'chat', 'chat', 'Zly Chat', 'zly.chat@example.test', null, '{"chat": 9901}'::jsonb);
insert into chat_conversations (id, number, status, name, phone, lead_id, created_at)
values (test.id('chat:zly'), 9901, 'human', 'Zly Chat', '+14165550142', test.id('lead:chat'), now() - interval '6 minutes');
select test.zly_lead('form', 'contact', 'web', 'Zly Form', 'zly.form@example.test', '+14165550143');
select test.zly_lead('owner', 'owner_program', 'web', 'Zly Owner', 'zly.owner@example.test', '+14165550144');
select test.zly_lead('partner', 'insurer', 'web', 'Zly Insurer', 'zly.ins@example.test', null);
select test.zly_lead('capchat', 'other', 'unfinished_form', 'Zly Capture', 'zly.cap@example.test', null, '{"form": "chat"}'::jsonb);
select test.zly_lead('old', 'contact', 'expired_offer', 'Zly Old', 'zly.old@example.test', '+14165550145', '{}'::jsonb, '20 days');

-- ================================================================ 1. words, phone, links
select test.eq('source: a live chat lead says Live chat', app.sl_source((select l from leads l where id = test.id('lead:chat'))), 'Live chat');
select test.eq('source: a chat typed and not sent says Live chat too (the alert''s words)', app.lead_alert_source((select l from leads l where id = test.id('lead:capchat'))), 'Live chat');
select test.eq('source: the contact form', app.sl_source((select l from leads l where id = test.id('lead:form'))), 'Contact form');
select test.eq('phone: the chat lead shows the phone of its chat', app.sl_phone((select l from leads l where id = test.id('lead:chat'))), '+14165550142');
select test.eq('type: renter, owner, partner', (select string_agg(app.sl_type(l), ',' order by l.name) from leads l where l.id in (test.id('lead:form'), test.id('lead:owner'), test.id('lead:partner'))),
  'renter,partner,owner');
insert into app_events (code, entity, entity_id, payload, dedupe_key) values ('staff_lead_new', 'lead', test.id('lead:form'), jsonb_build_object('lead_id', test.id('lead:form')), 'zly-ev-1');
select test.ok('link: the alert to an Admin opens that lead', (select app.notification_payload('staff_lead_new', e, '{"audience": "staff_admin"}'::jsonb) ->> '_url' from app_events e where dedupe_key = 'zly-ev-1')
  like '%/admin/sales-leads/' || test.id('lead:form'));
select test.ok('link: the alert to staff opens that lead on the staff portal', (select app.notification_payload('staff_lead_new', e, '{"audience": "staff_va_sales"}'::jsonb) ->> '_url' from app_events e where dedupe_key = 'zly-ev-1')
  like '%/staff/sales-leads/' || test.id('lead:form'));
select test.ok('link: an owner lead alert opens that lead', (select app.notification_payload('staff_owner_lead_new', e, '{"audience": "staff_admin"}'::jsonb) ->> '_url' from app_events e where dedupe_key = 'zly-ev-1')
  like '%/admin/sales-leads/' || test.id('lead:form'));

-- ================================================================ 2. the list
create table test.zly_list as select test.zly('zly_s1', 'va_read', 'sales_leads', '{"q": "zly", "status": "all", "limit": 200}'::jsonb) j;
select test.ok('list: Sales see renter, owner and partner leads in one list', (select count(*) from test.zly_list, jsonb_array_elements(j -> 'rows') x where x ->> 'id' in
  (test.id('lead:chat')::text, test.id('lead:owner')::text, test.id('lead:partner')::text)) = 3);
select test.eq('list: the chat lead row shows its phone and Live chat', (select (x ->> 'phone') || '/' || (x ->> 'source') from test.zly_list, jsonb_array_elements(j -> 'rows') x where x ->> 'id' = test.id('lead:chat')::text),
  '+14165550142/Live chat');
select test.ok('list: new leads first (the old expired offer is last)', (select x ->> 'id' from test.zly_list, jsonb_array_elements(j -> 'rows') with ordinality y(x, o) order by o desc limit 1) = test.id('lead:old')::text);
select test.eq('list: the type filter', (select string_agg(distinct x ->> 'type', ',') from jsonb_array_elements(test.zly('zly_admin', 'admin_read', 'sales_leads', '{"q": "zly", "type": "owner"}'::jsonb) -> 'rows') x), 'owner');
select test.eq('list: search by phone digits', (select string_agg(x ->> 'name', ',') from jsonb_array_elements(test.zly('zly_cs', 'va_read', 'sales_leads', '{"q": "555-0143"}'::jsonb) -> 'rows') x), 'Zly Form');
select test.throws('list: Fleet do not read leads', $$ select test.zly('zly_fleet', 'va_read', 'sales_leads') $$, '%Leads are for%');

-- ================================================================ 3. claims
create table test.zly_c1 as select test.zly('zly_s1', 'va_do', 'lead_claim', jsonb_build_object('lead', test.id('lead:form'))) j;
select test.eq('claim: holds 15 minutes by default', (select round(extract(epoch from (expires_at - claimed_at)) / 60)::integer from lead_claims where lead_id = test.id('lead:form')), 15);
select test.ok('claim: the row says it is mine', (select (j #>> '{claim,mine}')::boolean from test.zly_c1));
select test.throws('claim: someone else cannot claim it meanwhile', format($$ select test.zly('zly_s2', 'va_do', 'lead_claim', jsonb_build_object('lead', %L)) $$, test.id('lead:form')), '%working on this lead%');
select test.zly('zly_s1', 'va_do', 'lead_contact', jsonb_build_object('lead', test.id('lead:form'), 'channel', 'call'));
select test.eq('extend: a logged call extends the claim by the window', (select round(extract(epoch from (expires_at - claimed_at)) / 60)::integer from lead_claims where lead_id = test.id('lead:form')), 30);
select test.ok('extend: the call is the first contact and the lead is contacted', (select first_contact_at is not null and status = 'contacted' from leads where id = test.id('lead:form')));
select test.zly('zly_s1', 'va_do', 'lead_contact', jsonb_build_object('lead', test.id('lead:form'), 'channel', 'text'));
select test.zly('zly_s1', 'va_do', 'lead_contact', jsonb_build_object('lead', test.id('lead:form'), 'channel', 'email'));
select test.zly('zly_s1', 'va_do', 'lead_contact', jsonb_build_object('lead', test.id('lead:form'), 'channel', 'note', 'note', 'Wants a convertible'));
select test.eq('extend: never past the most (60 minutes from the claim)', (select round(extract(epoch from (expires_at - claimed_at)) / 60)::integer from lead_claims where lead_id = test.id('lead:form')), 60);
select test.throws('contact: a note needs its text', format($$ select test.zly('zly_s1', 'va_do', 'lead_contact', jsonb_build_object('lead', %L, 'channel', 'note')) $$, test.id('lead:form')), '%Write the note%');
select test.zly('zly_s1', 'va_do', 'lead_unclaim', jsonb_build_object('lead', test.id('lead:form')));
select test.eq('unclaim: back to the pool at once', (select count(*) from lead_claims where lead_id = test.id('lead:form')), 0::bigint);
select test.zly('zly_s2', 'va_do', 'lead_claim', jsonb_build_object('lead', test.id('lead:form')));
update lead_claims set expires_at = now() - interval '1 minute' where lead_id = test.id('lead:form');
select test.ok('expire: the job finds the claim that ran out', app.sl_expire() >= 1);
select test.eq('expire: it returns to the pool', (select count(*) from lead_claims where lead_id = test.id('lead:form')), 0::bigint);
select test.eq('expire: logged as expired for that person', (select count(*) from lead_claim_log where lead_id = test.id('lead:form') and user_id = test.id('zly_s2') and action = 'expire'), 1::bigint);
update sales_lead_settings set max_active = 2 where id;
select test.zly('zly_s2', 'va_do', 'lead_claim', jsonb_build_object('lead', test.id('lead:chat')));
select test.zly('zly_s2', 'va_do', 'lead_claim', jsonb_build_object('lead', test.id('lead:owner')));
select test.throws('max: no more than the most live claims a person', format($$ select test.zly('zly_s2', 'va_do', 'lead_claim', jsonb_build_object('lead', %L)) $$, test.id('lead:partner')), '%the most is 2%');
update sales_lead_settings set max_active = 25 where id;
select test.throws('reassign: Admins only', format($$ select test.zly('zly_s1', 'va_do', 'lead_reassign', jsonb_build_object('lead', %L, 'to', %L)) $$, test.id('lead:chat'), test.id('zly_s1')), '%');
select test.zly('zly_admin', 'admin_do', 'lead_reassign', jsonb_build_object('lead', test.id('lead:chat'), 'to', test.id('zly_s1')));
select test.eq('reassign: the Admin gives the lead to another person', (select claimed_by from lead_claims where lead_id = test.id('lead:chat')), test.id('zly_s1'));
select test.eq('reassign: and it is assigned to them', (select assigned_to from leads where id = test.id('lead:chat')), test.id('zly_s1'));
select test.zly('zly_admin', 'admin_do', 'lead_unclaim', jsonb_build_object('lead', test.id('lead:owner')));
select test.eq('release: an Admin releases someone''s claim', (select action from lead_claim_log where lead_id = test.id('lead:owner') order by id desc limit 1), 'release');
create table test.zly_next as select test.zly('zly_s1', 'va_do', 'lead_next', '{}'::jsonb) j;
select test.ok('next: Next lead claims an open lead nobody held', (select (j ->> 'lead') is not null and (j #>> '{claim,mine}')::boolean from test.zly_next));
select test.throws('outcome: lost needs a reason', format($$ select test.zly('zly_s1', 'va_do', 'lead_outcome', jsonb_build_object('lead', %L, 'outcome', 'lost')) $$, test.id('lead:chat')), '%why%');

-- ================================================================ 4. the dashboard
select test.zly_lead('d1', 'contact', 'web', 'Zly D One', 'zly.d1@example.test', '+14165550151');
select test.zly_lead('d2', 'contact', 'web', 'Zly D Two', 'zly.d2@example.test', '+14165550152');
select test.zly_lead('d3', 'contact', 'web', 'Zly D Three', 'zly.d3@example.test', '+14165550153');
select test.zly('zly_s3', 'va_do', 'lead_claim', jsonb_build_object('lead', test.id('lead:d1')));
select test.zly('zly_s3', 'va_do', 'lead_claim', jsonb_build_object('lead', test.id('lead:d2')));
select test.zly('zly_s3', 'va_do', 'lead_contact', jsonb_build_object('lead', test.id('lead:d1'), 'channel', 'call'));
select test.zly('zly_s3', 'va_do', 'lead_outcome', jsonb_build_object('lead', test.id('lead:d1'), 'outcome', 'won'));
select test.zly('zly_s3', 'va_do', 'lead_claim', jsonb_build_object('lead', test.id('lead:d3')));
update lead_claims set expires_at = now() - interval '1 second' where lead_id = test.id('lead:d3');
create table test.zly_dash as select test.zly('zly_s3', 'va_read', 'sales_dashboard') j;
select test.eq('dashboard: claimed, won, close rate, contacted %, expired today', (select concat_ws('/', j #>> '{today,claimed}', j #>> '{today,won}', j #>> '{today,close_rate}', j #>> '{today,contacted_pct}', j #>> '{today,expired}') from test.zly_dash),
  '3/1/33/33/1');
select test.ok('dashboard: time to first contact in minutes', (select (j #>> '{today,first_contact_minutes}')::integer between 0 and 1 from test.zly_dash));
select test.ok('dashboard: the month counts what today counts', (select (j #>> '{month,claimed}')::integer >= 3 from test.zly_dash));
select test.eq('dashboard: won closes the lead and ends the claim', (select status || '/' || (select count(*) from lead_claims c where c.lead_id = l.id) from leads l where l.id = test.id('lead:d1')), 'converted/0');
create table test.zly_team as select test.zly('zly_admin', 'admin_read', 'sales_dashboard', '{"period": "today"}'::jsonb) j;
select test.eq('dashboard: the Admin''s leaderboard puts the one who won first', (select x ->> 'name' from test.zly_team, jsonb_array_elements(j -> 'team') x where x ->> 'name' like 'Zly%' order by (x ->> 'rank')::integer limit 1), 'Zly S3');
select test.eq('dashboard: staff get no team', (select j -> 'team' from test.zly_dash), 'null'::jsonb);

-- ================================================================ 5. settings
select test.zly('zly_admin', 'admin_do', 'sales_lead_settings_save', '{"owner_minutes": 10, "max_active": 30}'::jsonb);
select test.eq('settings: per lead type and the most claims', (select (claim_minutes ->> 'owner') || '/' || (claim_minutes ->> 'renter') || '/' || max_active from sales_lead_settings), '10/15/30');
select test.throws('settings: Admins only', $$ select test.zly('zly_s1', 'va_do', 'sales_lead_settings_save', '{"max_active": 99}'::jsonb) $$, '%');
update sales_lead_settings set claim_minutes = '{"renter": 15, "owner": 15, "partner": 15}'::jsonb, max_active = 25 where id;

-- ================================================================ 6. a missed call becomes a lead
insert into phone_threads (id, number, match_kind) values (test.id('thread:zly'), '+14165550160', 'unknown');
insert into phone_activity (id, thread_id, kind, direction, missed, started_at) values (test.id('call:zly'), test.id('thread:zly'), 'call', 'in', true, now() - interval '3 minutes');
select app.sales_leads_sync(now());
select test.eq('missed call: one lead with the number, in plain words', (select app.sl_source(l) || '/' || l.phone from leads l where l.source = 'missed_call' and l.payload ->> 'call_id' = test.id('call:zly')::text), 'Missed call/+14165550160');
select app.sales_leads_sync(now());
select test.eq('missed call: once', (select count(*) from leads l where l.source = 'missed_call' and l.payload ->> 'call_id' = test.id('call:zly')::text), 1::bigint);

-- ================================================================ 7. account merge
select test.mk_owner('zly_o');
select test.mk_vehicle('ZLYV', 'zly_o');
select test.mk_renter('zly_a');
select test.mk_renter('zly_b');
update renters set mobile = '(416) 555-0170', legal_name = 'Zly Person' where id = test.id('renter:zly_a');
update renters set mobile = '416 555 0170', legal_name = 'Zly P.', date_of_birth = date '1991-01-01' where id = test.id('renter:zly_b');
update users set phone = '+14165550170', phone_verified_at = now() where id = test.id('zly_b');
select test.mk_booking('ZLY-1', 'ZLYV', 'zly_a', '2026-03-01 10:00', '2026-03-03 10:00', 'closed');
-- weak: the same name only
select test.mk_renter('zly_w1');
select test.mk_renter('zly_w2');
update renters set legal_name = 'Zly Weak', mobile = '416-555-0181' where id = test.id('renter:zly_w1');
update renters set legal_name = 'Zly Weak', mobile = '416-555-0182', date_of_birth = date '1980-02-02' where id = test.id('renter:zly_w2');
-- strong: the same name, date of birth and phone (no verified phone)
select test.mk_renter('zly_n1', false);
select test.mk_renter('zly_n2', false);
update renters set legal_name = 'Zly Same', mobile = '905-555-0190' where id in (test.id('renter:zly_n1'), test.id('renter:zly_n2'));

select test.eq('match: a verified phone on one record and the same phone on the other is strong',
  app.rm_strength((select r from renters r where id = test.id('renter:zly_a')), (select r from renters r where id = test.id('renter:zly_b'))), 'strong');
select test.eq('match: the same name alone is weak', app.rm_strength((select r from renters r where id = test.id('renter:zly_w1')), (select r from renters r where id = test.id('renter:zly_w2'))), 'weak');
select test.eq('match: the same name, date of birth and phone is strong', app.rm_strength((select r from renters r where id = test.id('renter:zly_n1')), (select r from renters r where id = test.id('renter:zly_n2'))), 'strong');
select app.renter_auto_merge(now(), 1000);
select test.eq('auto: merged into the record with more history (the one with the booking)', (select merged_into from renters where id = test.id('renter:zly_b')), test.id('renter:zly_a'));
select test.eq('auto: the weak match stays two records', (select count(*) from renters where id in (test.id('renter:zly_w1'), test.id('renter:zly_w2')) and merged_into is null), 2::bigint);
select test.eq('auto: the name, date of birth and phone match merged too', (select count(*) from renters where id in (test.id('renter:zly_n1'), test.id('renter:zly_n2')) and merged_into is not null), 1::bigint);
select test.eq('auto: the other card moved to the kept record', (select renter_id from payment_methods where id = test.id('card:zly_b')), test.id('renter:zly_a'));
select test.eq('alias: the other email signs in to the kept account (any case)', public.server_sign_in_alias('ZLY_B@example.test') ->> 'user_id', test.id('zly_a')::text);
select test.eq('alias: the merged sign-in points at the kept account', public.server_sign_in_alias(null, test.id('zly_b')) ->> 'email', 'zly_a@example.test');
select test.eq('alias: the verified phone moved to the kept account (sign-in by code)', (select phone || '/' || (phone_verified_at is not null) from users where id = test.id('zly_a')), '+14165550170/true');
select test.eq('alias: an unknown email is nobody''s alias', public.server_sign_in_alias('nobody@example.test'), null::jsonb);
select test.ok('audit: the merge is recorded, automatic', (select auto and strength = 'strong' from renter_merges where merged_id = test.id('renter:zly_b')));
select test.eq('note: one "your accounts are now one" note to the renter', (select count(*) from app_events where code = 'renter_accounts_merged' and entity_id = test.id('renter:zly_a')), 1::bigint);
select test.ok('note: it names both sign-in emails', (select payload ->> 'sign_in_emails' from app_events where code = 'renter_accounts_merged' and entity_id = test.id('renter:zly_a')) like '%zly_a@example.test%zly_b@example.test%');
select test.eq('read: staff see the merge on the renter', (select jsonb_array_length(test.zly('zly_cs', 'ops_read', 'renter_merges', jsonb_build_object('renter', test.id('renter:zly_a'))) -> 'rows')), 1);

-- undo
select test.throws('undo: Admins only', format($$ select test.zly('zly_cs', 'ops_do', 'renter_merge_undo', jsonb_build_object('merge', %L)) $$, (select id from renter_merges where merged_id = test.id('renter:zly_b'))), '%');
select test.zly('zly_admin', 'admin_do', 'renter_merge_undo', jsonb_build_object('merge', (select id from renter_merges where merged_id = test.id('renter:zly_b')), 'reason', 'Two people after all'));
select test.eq('undo: the record is separate again', (select merged_into is null and not is_blocked from renters where id = test.id('renter:zly_b')), true);
select test.eq('undo: its card is back', (select renter_id from payment_methods where id = test.id('card:zly_b')), test.id('renter:zly_b'));
select test.eq('undo: its account holder driver is back', (select count(*) from drivers where renter_id = test.id('renter:zly_b') and is_account_holder), 1::bigint);
select test.eq('undo: the alias is gone', public.server_sign_in_alias('zly_b@example.test'), null::jsonb);
select test.eq('undo: the phone is back on the other sign-in', (select phone_verified_at is not null from users where id = test.id('zly_b')), true);
select test.ok('undo: in both change histories', (select count(*) = 2 from renter_edits where renter_id in (test.id('renter:zly_a'), test.id('renter:zly_b')) and after ? 'merge_undone'));

-- the staff path keeps working, recorded the same way
select test.ok('staff: Merge into this record still merges, and is recorded', (select test.zly('zly_cs', 'ops_do', 'renter_merge', jsonb_build_object('keep', test.id('renter:zly_w1'), 'merge', test.id('renter:zly_w2'))) ? 'merge_id'));
select test.ok('staff: not automatic', (select not auto from renter_merges where merged_id = test.id('renter:zly_w2')));

select app.process_events(1000) >= 0 as processed;
