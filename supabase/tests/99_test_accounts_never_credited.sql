-- 99: verification and test accounts never get real leads, owners or tasks (migration 0343). A new owner lead goes to the
-- least busy real Sales person (or nobody), never a verification account; no test account is "sourced by" on a real lead,
-- owner or application, nor assigned a task about one; the clean-up of what is on file; the leads on file before the
-- automatic follow-ups get an Admin "Follow up now". Fixtures start with "tac".
select test.suite('99 test accounts never credited');

-- the verification accounts: an address verify-...@carmacars.ca, and the invitation check's address at the test inbox
insert into users (id, email, full_name) values (test.id('tac_vsales'), 'verify-tac-sales@carmacars.ca', 'Verify Sales'),
                                                (test.id('tac_vinvite'), 'delivered+verify-tac-invite-1@resend.dev', 'Verify Invitation');
insert into user_roles (user_id, role) values (test.id('tac_vsales'), 'va'), (test.id('tac_vinvite'), 'va');
insert into staff_profiles (user_id, staff_type, va_function) values (test.id('tac_vsales'), 'va', 'sales'), (test.id('tac_vinvite'), 'va', 'sales');
select test.mk_user('tac_admin', 'admin');
select test.eq('test accounts: both are recognized, a real one is not',
  app.staff_is_test(test.id('tac_vsales')) || '/' || app.staff_is_test(test.id('tac_vinvite')) || '/' || app.staff_is_test(test.id('tac_admin')), 'true/true/false');

-- 1. with only test accounts in Sales, a new owner lead stays unassigned (they are the least busy: nobody else has a lead)
update leads set assigned_to = null where assigned_to in (select user_id from staff_profiles where va_function = 'sales');
create temp table tac_off as select user_id from staff_profiles where va_function = 'sales' and is_active and user_id not in (test.id('tac_vsales'), test.id('tac_vinvite'));
update staff_profiles set is_active = false where user_id in (select user_id from tac_off);
insert into leads (kind, name, email, source, assigned_to) values ('owner_program', 'Olive Web', 'tac_olive@example.test', 'web', test.id('tac_vsales'));
select test.eq('a lead given to a test account goes to nobody when no real Sales person is on', (select assigned_to from leads where email = 'tac_olive@example.test'), null::uuid);
-- 2. a real Sales person: the lead goes to them
select test.mk_user('tac_real', 'va', 'sales');
insert into leads (kind, name, email, source, assigned_to) values ('owner_program', 'Pat Web', 'tac_pat@example.test', 'web', test.id('tac_vinvite'));
select test.eq('a lead given to a test account goes to the least busy real Sales person', (select assigned_to from leads where email = 'tac_pat@example.test'), test.id('tac_real'));
select test.eq('the least busy real Sales person never a test account', app.lead_real_assignee(), test.id('tac_real'));
update leads set sourced_by = test.id('tac_vsales') where email = 'tac_olive@example.test';
select test.eq('a test account cannot be made "sourced by" of a real lead', (select sourced_by from leads where email = 'tac_olive@example.test'), null::uuid);
-- a test lead keeps its test account (the verification's own data)
insert into leads (kind, name, email, source, assigned_to) values ('owner_program', 'Verify Lead', 'verify-lead@carmacars.ca', 'web', test.id('tac_vsales'));
select test.eq('a test lead keeps its test account', (select assigned_to from leads where email = 'verify-lead@carmacars.ca'), test.id('tac_vsales'));

-- owners, applications and tasks
select test.mk_owner('tac_own');
update owners set recruited_by = test.id('tac_vsales') where id = test.id('owner:tac_own');
select test.eq('a real owner is never sourced by a test account', (select recruited_by from owners where id = test.id('owner:tac_own')), null::uuid);
insert into owner_applications (id, owner_id, source, sourced_by) values (test.id('app:tac_own'), test.id('owner:tac_own'), 'web', test.id('tac_vsales'));
select test.eq('nor its application', (select sourced_by from owner_applications where id = test.id('app:tac_own')), null::uuid);
select test.eq('the invitation credit refuses a test account', public.server_owner_sales_credit(test.id('app:tac_own'), test.id('tac_vinvite')) ->> 'credited', 'false');
insert into tasks (queue, task_type, title, owner_id, assigned_to) values ('sales', 'owner_lead', 'tac task', test.id('owner:tac_own'), test.id('tac_vsales'));
select test.eq('a task about a real owner is never given to a test account', (select assigned_to from tasks where title = 'tac task'), null::uuid);

-- 3. the clean-up of what is on file (written past the triggers, as before this release)
-- (the fences of 0440 also keep such rows from being written: off for these statements too)
alter table leads disable trigger z_fence_test_accounts;
alter table tasks disable trigger a_fence_test_accounts;
alter table leads disable trigger leads_no_test_staff;
alter table owners disable trigger owners_no_test_staff;
alter table tasks disable trigger tasks_no_test_staff;
update leads set assigned_to = test.id('tac_vinvite'), sourced_by = test.id('tac_vsales') where email = 'tac_pat@example.test';
update owners set recruited_by = test.id('tac_vsales') where id = test.id('owner:tac_own');
update tasks set assigned_to = test.id('tac_vsales') where title = 'tac task';
alter table leads enable trigger leads_no_test_staff;
alter table owners enable trigger owners_no_test_staff;
alter table tasks enable trigger tasks_no_test_staff;
alter table leads enable trigger z_fence_test_accounts;
alter table tasks enable trigger a_fence_test_accounts;
select test.ok('clean-up: counted', (app.clear_test_account_credit() ->> 'leads')::int >= 1);
select test.eq('clean-up: the real lead, owner and task are unassigned; the test lead keeps its account',
  (select coalesce(assigned_to::text, 'none') || '/' || coalesce(sourced_by::text, 'none') from leads where email = 'tac_pat@example.test') || '/'
  || coalesce((select recruited_by::text from owners where id = test.id('owner:tac_own')), 'none') || '/'
  || coalesce((select assigned_to::text from tasks where title = 'tac task'), 'none') || '/'
  || ((select assigned_to from leads where email = 'verify-lead@carmacars.ca') = test.id('tac_vsales')), 'none/none/none/none/true');

-- 4. the leads on file before the automatic follow-ups: an Admin "Follow up now"
insert into leads (kind, name, email, source, pipeline_stage, followup_stopped_at, followup_stop_reason, created_at)
values ('owner_program', 'Quinn Early', 'tac_quinn@example.test', 'web', 'new', now(), 'On file before the automatic follow-ups', now() - interval '6 days'),
       ('owner_program', 'Rae Moved', 'tac_rae@example.test', 'web', 'contacted', now(), 'On file before the automatic follow-ups', now() - interval '6 days');
select test.eq('follow up now: one Admin task for the lead nobody moved', app.owner_leads_follow_up_now(), 1);
select test.eq('follow up now: in the Admin queue, high, with the lead; the lead says so',
  (select t.queue || '/' || t.priority || '/' || (t.title = 'Follow up now: Quinn Early') from tasks t where t.related_table = 'leads' and t.related_id = (select id from leads where email = 'tac_quinn@example.test'))
  || '/' || (select followup_stop_reason from leads where email = 'tac_quinn@example.test'), 'admin/high/true/On file before the automatic follow-ups: an Admin follows up (To do)');
select test.eq('follow up now: once', app.owner_leads_follow_up_now(), 0);
update staff_profiles set is_active = true where user_id in (select user_id from tac_off);
