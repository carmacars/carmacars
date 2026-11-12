-- 99: release 35 part G (migration 1151): the staff onboarding gate. In order: the academy, the staff agreement, then the
-- WhatsApp groups confirmed (Sales: the Sales and the Team group; everyone else the Team group). Until all three, the role
-- checks say no, the door refuses everything but the onboarding screens, and leads never go to the person; the leads they
-- hold go back to the salesperson who brought or had them, else to the pool. Test and verify accounts stay exempt. Fixtures
-- start with "go".
select test.suite('99 r35g staff onboarding');

select test.mk_user('go_admin', 'admin');
select test.mk_user('go_syed', 'va', 'sales');      -- onboarded (exempt as every test person)
select test.mk_user('go_harman', 'va', 'sales');    -- the new hire
select test.mk_user('go_cs', 'va', 'cs');
select test.mk_user('go_verify', 'va', 'sales');
select test.mk_user('go_ret', 'va', 'sales');      -- 2330: a lead claim is Sales credit, so the person it is handed to in the return test is Sales
update staff_profiles set onboarding_exempt = false where user_id in (test.id('go_harman'), test.id('go_cs'), test.id('go_verify'));
update users set email = 'verify-go@carmacars.ca' where id = test.id('go_verify');

create function pg_temp.dr(p_user text, p_call text, p_name text, p jsonb default '{}'::jsonb) returns jsonb language sql as
$$ select public.door(test.id(p_user), 'aal2', p_call, p_name, p) $$;
create function pg_temp.st(p_user text) returns text language sql as $$ select app.staff_onboarding_state(test.id(p_user)) ->> 'step' $$;
-- the academy is passed by a waiver here (the sections and quizzes have suites of their own)
create function pg_temp.academy_ok(p_user text) returns void language sql as
$$ insert into academy_waivers (user_id, waived_by, reason) values (test.id(p_user), test.id('go_admin'), 'Passed elsewhere') $$;
create function pg_temp.agreement_ok(p_user text) returns void language sql as
$$ update staff_profiles set agreement_waived_at = now(), agreement_waived_by = test.id('go_admin'), agreement_waived_reason = 'Signed on paper' where user_id = test.id(p_user) $$;

-- ---------------------------------------------------------------- 1. a new hire is held, at step 1
select test.eq('new hire: not fully onboarded', app.staff_fully_onboarded(test.id('go_harman')), false);
select test.eq('new hire: no Sales role for any check', app.user_va_has(test.id('go_harman'), 'sales'), false);
select test.eq('new hire: not staff for any check', app.user_is_staff(test.id('go_harman')), false);
select test.throws('new hire: the door refuses the leads', $$select pg_temp.dr('go_harman', 'ops_read', 'sales_leads')$$, 'Finish your onboarding first');
select test.throws('new hire: the door refuses a booking read', $$select pg_temp.dr('go_harman', 'ops_read', 'accident_card', '{"booking": "X-1"}')$$, 'Finish your onboarding first');
select test.lives('new hire: Welcome opens', $$select pg_temp.dr('go_harman', 'ops_read', 'staff_welcome')$$);
select test.eq('new hire: Welcome is locked', (pg_temp.dr('go_harman', 'ops_read', 'staff_welcome') ->> 'locked')::boolean, true);
select test.eq('new hire: my_roles keeps the portal (Sales) and says locked at the academy',
  (select (r ->> 'va') || ':' || (r ->> 'onboarding_locked') || ':' || (r ->> 'onboarding_step') from (select app.my_roles(test.id('go_harman')) r) x), 'sales:true:academy');
select test.ok('new hire: my_roles leaves no pass behind', coalesce(current_setting('app.onboarding_pass', true), '') = '');
-- the policies (as the signed-in person)
select test.login(test.id('go_harman'));
select test.eq('new hire: app.is_va() is false for the policies', app.is_va(), false);
select test.logout();
select test.login(test.id('go_syed'));
select test.eq('onboarded: app.is_va() is true', app.is_va(), true);
select test.logout();

-- ---------------------------------------------------------------- 2. in order: the WhatsApp step opens last
-- 2360: the WhatsApp confirmation is its own fact, at any step; the gate's order stays (it counts when the person gets there)
select test.lives('order: the Team group confirmed before the academy', $$select pg_temp.dr('go_harman', 'ops_do', 'staff_whatsapp_confirm', '{"team": true}')$$);
select test.eq('order: still at the academy', pg_temp.st('go_harman'), 'academy');
select pg_temp.dr('go_admin', 'ops_do', 'staff_whatsapp_mark', jsonb_build_object('user', test.id('go_harman'), 'joined', false));
select pg_temp.academy_ok('go_harman');
select test.eq('order: the agreement next', pg_temp.st('go_harman'), 'agreement');
select pg_temp.agreement_ok('go_harman');
select test.eq('order: then the WhatsApp groups', pg_temp.st('go_harman'), 'whatsapp');
select test.eq('Sales: the Sales group and the Team group', (select string_agg(g ->> 'key', ',' order by g ->> 'key') from jsonb_array_elements(app.staff_group_list(test.id('go_harman'))) g), 'sales,team');
select test.eq('Welcome: the WhatsApp step is open with both groups',
  (select jsonb_array_length(s -> 'groups') from jsonb_array_elements(pg_temp.dr('go_harman', 'ops_read', 'staff_welcome') -> 'steps') s where s ->> 'key' = 'team'), 2);
select pg_temp.dr('go_harman', 'ops_do', 'staff_whatsapp_confirm', '{"team": true}');
select test.eq('one group of two: still held', app.staff_fully_onboarded(test.id('go_harman')), false);
select test.eq('one group of two: Team confirmed', (select whatsapp_joined from staff_profiles where user_id = test.id('go_harman')), array['team']);
select pg_temp.dr('go_harman', 'ops_do', 'staff_whatsapp_confirm', '{"sales": true}');
-- 1154: step 4, an Admin or a Fleet VA approves
select test.eq('both groups: waiting for approval', pg_temp.st('go_harman'), 'approval');
select test.eq('both groups: not yet onboarded', app.staff_fully_onboarded(test.id('go_harman')), false);
select pg_temp.dr('go_admin', 'ops_do', 'staff_onboarding_approve', jsonb_build_object('user', test.id('go_harman')));
select test.eq('both groups: fully onboarded', app.staff_fully_onboarded(test.id('go_harman')), true);
select test.eq('both groups: Sales for every check', app.user_va_has(test.id('go_harman'), 'sales'), true);
select test.lives('both groups: the door opens the leads', $$select pg_temp.dr('go_harman', 'ops_read', 'sales_leads')$$);
select test.eq('customer service: the Team group only', (select string_agg(g ->> 'key', ',') from jsonb_array_elements(app.staff_group_list(test.id('go_cs'))) g), 'team');

-- ---------------------------------------------------------------- 3. test and verify accounts are never held
select test.eq('verify account: exempt', app.staff_fully_onboarded(test.id('go_verify')), true);
select test.eq('verify account: Sales for every check', app.user_va_has(test.id('go_verify'), 'sales'), true);

-- ---------------------------------------------------------------- 4. the leads
-- a lead Syed brought, given to Harman: when Harman stops being onboarded, it goes back to Syed (a lead event)
insert into leads (id, kind, name, email, source, sourced_by) values (test.id('lead:go1'), 'contact', 'Lead One', 'lead.go1@example.test', 'web', test.id('go_syed'));
select pg_temp.dr('go_admin', 'ops_do', 'lead_reassign', jsonb_build_object('lead', test.id('lead:go1'), 'to', test.id('go_harman')));
select test.eq('lead: Harman holds it', (select claimed_by from lead_claims where lead_id = test.id('lead:go1')), test.id('go_harman'));
select pg_temp.dr('go_admin', 'ops_do', 'staff_whatsapp_mark', jsonb_build_object('user', test.id('go_harman'), 'joined', false));
select test.eq('take back: Harman is held again', app.staff_fully_onboarded(test.id('go_harman')), false);
select test.eq('take back: the lead is Syed''s again (claim)', (select claimed_by from lead_claims where lead_id = test.id('lead:go1')), test.id('go_syed'));
select test.eq('take back: assigned to Syed', (select assigned_to from leads where id = test.id('lead:go1')), test.id('go_syed'));
select test.eq('take back: logged as a return to Syed', (select count(*) from lead_claim_log where lead_id = test.id('lead:go1') and action = 'return' and user_id = test.id('go_syed'))::int, 1);
select test.eq('take back: and a release from Harman', (select count(*) from lead_claim_log where lead_id = test.id('lead:go1') and action = 'release' and user_id = test.id('go_harman'))::int, 1);
-- never to a person not onboarded
select test.throws('reassign: not to someone not onboarded', format($$select pg_temp.dr('go_admin', 'ops_do', 'lead_reassign', jsonb_build_object('lead', %L, 'to', %L))$$, test.id('lead:go1'), test.id('go_harman')), 'has not finished onboarding');
select test.throws('claim: not by someone not onboarded (the door)', format($$select pg_temp.dr('go_harman', 'ops_do', 'lead_claim', jsonb_build_object('lead', %L))$$, test.id('lead:go1')), 'Finish your onboarding first');
select test.throws('claim: not by someone not onboarded (the table)', format($$insert into lead_claims (lead_id, claimed_by, expires_at, cap_at) values (%L, %L, now() + interval '1 hour', now() + interval '1 hour')$$, test.id('lead:go1'), test.id('go_harman')), 'has not finished onboarding');
insert into leads (id, kind, name, email, source, assigned_to) values (test.id('lead:go2'), 'contact', 'Lead Two', 'lead.go2@example.test', 'web', test.id('go_harman'));
select test.ok('routing: a new lead given to someone not onboarded goes to the pool', (select assigned_to from leads where id = test.id('lead:go2')) is null);
update leads set assigned_to = test.id('go_harman') where id = test.id('lead:go1');
select test.eq('routing: an assignment to someone not onboarded goes to the previous salesperson', (select assigned_to from leads where id = test.id('lead:go1')), test.id('go_syed'));
-- the sweep: a lead held by someone not onboarded (as at deploy) goes back; with nobody before them, to the pool
select set_config('app.lead_return', 'on', false);
update leads set assigned_to = test.id('go_harman') where id = test.id('lead:go2');
select set_config('app.lead_return', '', false);
select test.eq('sweep: one lead moved', app.leads_return_unonboarded(null, null), 1);
select test.ok('sweep: no salesperson before: the pool', (select assigned_to from leads where id = test.id('lead:go2')) is null);
select test.eq('sweep: logged as a release from Harman', (select count(*) from lead_claim_log where lead_id = test.id('lead:go2') and action = 'release' and user_id = test.id('go_harman'))::int, 1);

-- Admin: Return lead to previous owner (Syed had it; Admin gave it to another Sales person; customer service cannot hold a Sales claim, 2330)
select pg_temp.academy_ok('go_cs'); select pg_temp.agreement_ok('go_cs');
select pg_temp.dr('go_cs', 'ops_do', 'staff_whatsapp_confirm', '{"team": true}');
select pg_temp.dr('go_admin', 'ops_do', 'staff_onboarding_approve', jsonb_build_object('user', test.id('go_cs')));
select test.eq('cs: onboarded with the Team group', app.staff_fully_onboarded(test.id('go_cs')), true);
select pg_temp.dr('go_admin', 'ops_do', 'lead_reassign', jsonb_build_object('lead', test.id('lead:go1'), 'to', test.id('go_ret')));
select test.eq('return: back to Syed', pg_temp.dr('go_admin', 'ops_do', 'lead_return', jsonb_build_object('lead', test.id('lead:go1'))) ->> 'to', test.id('go_syed')::text);
select test.eq('return: Syed holds it', (select claimed_by from lead_claims where lead_id = test.id('lead:go1')), test.id('go_syed'));
select test.throws('return: an Admin''s action', format($$select pg_temp.dr('go_syed', 'ops_do', 'lead_return', jsonb_build_object('lead', %L))$$, test.id('lead:go1')), 'Admin');
select test.throws('return: a lead in the pool has nobody to return from', format($$select pg_temp.dr('go_admin', 'ops_do', 'lead_return', jsonb_build_object('lead', %L))$$, test.id('lead:go2')), 'in the pool');

-- ---------------------------------------------------------------- 5. the Admin's list and the bulk Mark joined
select test.ok('list: Harman is held at the WhatsApp step',
  (select (x ->> 'onboarded')::boolean = false and x -> 'state' ->> 'step' = 'whatsapp' from jsonb_array_elements(pg_temp.dr('go_admin', 'ops_read', 'staff_onboarding_list')) x where x ->> 'user_id' = test.id('go_harman')::text));
select test.ok('bulk: marks every signed person not confirmed', (pg_temp.dr('go_admin', 'ops_do', 'staff_whatsapp_mark_all') ->> 'marked')::int >= 1);
select test.ok('bulk: then approved in one press', (pg_temp.dr('go_admin', 'ops_do', 'staff_onboarding_approve_all') ->> 'approved')::int >= 1);
select test.eq('bulk: Harman onboarded again', app.staff_fully_onboarded(test.id('go_harman')), true);
select test.eq('bulk: marked by the Admin', (select whatsapp_marked_by from staff_profiles where user_id = test.id('go_harman')), test.id('go_admin'));
select test.throws('bulk: an Admin''s action', $$select pg_temp.dr('go_syed', 'ops_do', 'staff_whatsapp_mark_all')$$, 'Admin');
-- the agreement taken back holds them again
update staff_profiles set agreement_waived_at = null where user_id = test.id('go_harman');
select test.eq('agreement taken back: held at the agreement', pg_temp.st('go_harman'), 'agreement');
select test.eq('agreement taken back: not onboarded', app.staff_fully_onboarded(test.id('go_harman')), false);
-- the gate switched off in Program settings
update program_settings set staff_onboarding_gate = false;
select test.eq('gate off: nobody is held', app.staff_fully_onboarded(test.id('go_harman')), true);
update program_settings set staff_onboarding_gate = true;
