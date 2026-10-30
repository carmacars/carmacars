-- 99: the owner pipeline and its follow-ups (migration 0215). Fixtures start with "opl".
select test.suite('99 owner pipeline');
select test.mk_user('opl_admin', 'admin');
select test.mk_user('opl_sales', 'va', 'sales');
select test.mk_user('opl_fin', 'va', 'finance');
select test.mk_owner('opl_ref', 'OPLREF1');

-- the website's owner form, with an owner's referral code
insert into leads (kind, name, email, phone, source, payload) values ('owner_program', 'Olga Prospect', 'olga.opl@example.test', '4165550101', 'web', '{"referral_code": "oplref1", "vehicle": "2022 Audi Q5"}');
create temp table opl as select id from leads where email = 'olga.opl@example.test';
select test.ok('a website lead is new, from the website, referred by the owner, with its day-0 follow-up due',
  exists (select 1 from leads l, opl where l.id = opl.id and l.pipeline_stage = 'new' and l.pipeline_source = 'referral' and l.referred_by_owner_id = test.id('owner:opl_ref') and l.followup_next_at <= now()));
select app.job_owner_pipeline();
select test.ok('day 0: the follow-up email is queued, low priority (marketing class)', exists (select 1 from notification_outbox o, opl where o.entity_id = opl.id and o.code = 'owner_recruit_outreach'
  and o.category = 'marketing' and o.priority >= 4 and o.payload ->> 'message_body' like '%fleet insurance policy%' and o.unsubscribe_token is not null));
select test.ok('the next one is day 2', (select followup_step = 1 and followup_next_at::date = (created_at + interval '2 days')::date from leads l, opl where l.id = opl.id));
select app.job_owner_pipeline();
select test.eq('nothing more before it is due', (select count(*)::int from notification_outbox o, opl where o.entity_id = opl.id), 1);
update leads set followup_next_at = now() - interval '1 minute' where id = (select id from opl);
select app.job_owner_pipeline();
select test.eq('day 2 sent', (select count(*)::int from notification_outbox o, opl where o.entity_id = opl.id), 2);

-- a reply by text stops it
insert into phone_threads (id, number, match_kind, lead_id) values (test.id('thread:opl'), '+14165550101', 'lead', (select id from opl));
insert into phone_activity (thread_id, kind, direction, body, lead_id) values (test.id('thread:opl'), 'text', 'in', 'Interested, call me', (select id from opl));
update leads set followup_next_at = now() - interval '1 minute' where id = (select id from opl);
select app.job_owner_pipeline();
select test.ok('a reply stops the follow-ups', exists (select 1 from leads l, opl where l.id = opl.id and l.followup_stop_reason = 'They replied' and l.replied_at is not null)
  and (select count(*) from notification_outbox o, opl where o.entity_id = opl.id) = 2);

-- a stage change stops them too; Sales moves a lead; Finance cannot
insert into leads (kind, name, email, source) values ('owner_program', 'Pat Prospect', 'pat.opl@example.test', 'web');
select public.door(test.id('opl_sales'), 'aal2', 'va_do', 'owner_pipeline_save', jsonb_build_object('id', (select id from leads where email = 'pat.opl@example.test'), 'stage', 'call_booked', '_va', 'sales'));
select test.ok('Sales moves a lead: the follow-ups stop', exists (select 1 from leads where email = 'pat.opl@example.test' and pipeline_stage = 'call_booked' and followup_stopped_at is not null and status = 'contacted'));
select test.throws('Finance does not see the pipeline', format($s$select public.door(%L, 'aal2', 'va_read', 'owner_pipeline', '{"_va": "finance"}')$s$, test.id('opl_fin')));
select test.ok('Sales reads the board', jsonb_array_length(public.door(test.id('opl_sales'), 'aal2', 'va_read', 'owner_pipeline', '{"_va": "sales"}') -> 'leads') >= 2);

-- a classified lead with no consent gets nothing
insert into leads (kind, name, email, source, contact_kind) values ('owner_recruit', 'Kim Seller', 'kim.opl@example.test', 'classified', 'private_seller');
select app.job_owner_pipeline();
select test.ok('a classified lead without consent: no email, and why', not exists (select 1 from notification_outbox where to_address = 'kim.opl@example.test')
  and exists (select 1 from leads where email = 'kim.opl@example.test' and pipeline_source = 'classified' and followup_stop_reason like 'Not sent:%'));

-- a referral typed by staff: one message only
select public.door(test.id('opl_admin'), 'aal2', 'admin_do', 'owner_pipeline_add', '{"name": "Rae Friend", "email": "rae.opl@example.test", "source": "referral", "referral_code": "OPLREF1"}');
select app.job_owner_pipeline();
select test.ok('a staff-typed referral: one message, then stop', (select count(*) from notification_outbox where to_address = 'rae.opl@example.test') = 1
  and exists (select 1 from leads where email = 'rae.opl@example.test' and followup_stopped_at is not null and followup_stop_reason = 'A referral allows one message'));

-- the owner's records move the stage; the referral credit follows the kickback rule
select test.mk_owner('opl_new');
update leads set owner_id = test.id('owner:opl_new') where id = (select id from opl);
select app.owner_pipeline_advance();
select test.eq('a signed owner agreement: signed', (select pipeline_stage from leads l, opl where l.id = opl.id), 'signed');
select test.mk_vehicle('opl_car', 'opl_new');
select test.mk_renter('opl_rita');
select test.mk_booking('OPL-1', 'opl_car', 'opl_rita', '2026-09-01 10:00', '2026-09-05 10:00', 'closed', 40000);
select app.owner_pipeline_advance();
select test.ok('the referral credit is due: the Kickback Rate of the first rental charge', exists (select 1 from owner_referral_credits c, opl where c.lead_id = opl.id and c.status = 'due'
  and c.amount_cents = public.calc_bps(40000, (app.settings()).kickback_bps) and c.referrer_owner_id = test.id('owner:opl_ref')));
select test.throws('only an Admin marks it paid', format($s$select public.door(%L, 'aal2', 'va_do', 'owner_referral_credit_paid', '{"id": "%s", "_va": "sales"}')$s$, test.id('opl_sales'), (select c.id from owner_referral_credits c, opl where c.lead_id = opl.id)));
select public.door(test.id('opl_admin'), 'aal2', 'admin_do', 'owner_referral_credit_paid', jsonb_build_object('id', (select c.id from owner_referral_credits c, opl where c.lead_id = opl.id)));
select test.ok('paid', exists (select 1 from owner_referral_credits c, opl where c.lead_id = opl.id and c.status = 'paid'));
select test.ok('every active owner has a referral code', not exists (select 1 from owners where status = 'active' and referral_code is null));
