-- 99: release 38's fixes (migration 2360): the WhatsApp confirmation as its own fact, what each person is waiting on, the
-- Admin's confirm-and-approve, and the offer of a person who is never credited. Fixtures start with "r38"; example.test.
select test.suite('99 r38 release fixes');

select test.mk_user('r38_admin', 'admin');
select test.mk_user('r38_fleet', 'va', 'fleet');
select test.mk_user('r38_hire', 'va', 'sales');
select test.mk_user('r38_cs', 'va', 'cs');
update staff_profiles set onboarding_exempt = false where user_id in (test.id('r38_hire'), test.id('r38_cs'));

create function pg_temp.dr(p_user text, p_call text, p_name text, p jsonb default '{}'::jsonb) returns jsonb language sql as
$$ select public.door(test.id(p_user), 'aal2', p_call, p_name, p) $$;
create function pg_temp.st(p_user text) returns jsonb language sql as $$ select app.staff_onboarding_state(test.id(p_user)) $$;
create function pg_temp.asked(p_user text) returns bigint language sql as
$$ select count(*) from tasks where task_type = 'approve_onboarding' and related_id = test.id(p_user) $$;

-- ---------------------------------------------------------------- A. WhatsApp marked at step 1 changes nothing else
select pg_temp.dr('r38_admin', 'ops_do', 'staff_whatsapp_mark', jsonb_build_object('user', test.id('r38_hire'), 'joined', true));
select test.eq('A marked at step 1: the WhatsApp step is done', (pg_temp.st('r38_hire') ->> 'whatsapp')::boolean, true);
select test.eq('A marked at step 1: the academy and the agreement are unchanged',
  (pg_temp.st('r38_hire') ->> 'academy') || '/' || (pg_temp.st('r38_hire') ->> 'agreement') || '/' || (pg_temp.st('r38_hire') ->> 'step'), 'false/false/academy');
select test.eq('A marked at step 1: still held', app.staff_fully_onboarded(test.id('r38_hire')), false);
select test.eq('A marked at step 1: no approval asked', pg_temp.asked('r38_hire'), 0::bigint);
select test.ok('A waiting on: the academy and the agreement, not WhatsApp',
  (select bool_and(x not like 'WhatsApp%') and bool_or(x like 'Academy%') and bool_or(x = 'Staff agreement signature')
     from jsonb_array_elements_text(pg_temp.st('r38_hire') -> 'waiting_on') x));
select test.throws('A confirm and approve: refused before the agreement, saying what is missing',
  format('select pg_temp.dr(%L, %L, %L, %L::jsonb)', 'r38_admin', 'ops_do', 'staff_whatsapp_approve', jsonb_build_object('user', test.id('r38_hire'))), 'Waiting on');

insert into academy_waivers (user_id, waived_by, reason) values (test.id('r38_hire'), test.id('r38_admin'), 'Passed elsewhere');
select test.eq('A after the academy: the agreement next', pg_temp.st('r38_hire') ->> 'step', 'agreement');
select test.eq('A after the academy: still no approval asked', pg_temp.asked('r38_hire'), 0::bigint);
update staff_profiles set agreement_waived_at = now(), agreement_waived_by = test.id('r38_admin'), agreement_waived_reason = 'Signed on paper' where user_id = test.id('r38_hire');
select test.eq('A after the agreement: the early WhatsApp counts, waiting for approval', pg_temp.st('r38_hire') ->> 'step', 'approval');
select test.eq('A after the agreement: the approval is asked once', pg_temp.asked('r38_hire'), 1::bigint);
select test.eq('A waiting on: the approval', pg_temp.st('r38_hire') -> 'waiting_on', '["Approval by an Admin or a Fleet VA"]'::jsonb);
select test.ok('A Fleet sees the person with what is missing',
  exists (select 1 from jsonb_array_elements(pg_temp.dr('r38_fleet', 'va_read', 'staff_onboarding_approvals')) x
           where x ->> 'user_id' = test.id('r38_hire')::text and x ->> 'step' = 'approval' and x -> 'waiting_on' ? 'Approval by an Admin or a Fleet VA'));

-- taken back at the approval step: back to the WhatsApp step, the earlier steps kept
select pg_temp.dr('r38_admin', 'ops_do', 'staff_whatsapp_mark', jsonb_build_object('user', test.id('r38_hire'), 'joined', false));
select test.eq('A taken back: the WhatsApp step, academy and agreement kept', (pg_temp.st('r38_hire') ->> 'step') || '/' || (pg_temp.st('r38_hire') ->> 'academy') || '/' || (pg_temp.st('r38_hire') ->> 'agreement'), 'whatsapp/true/true');
select test.ok('A taken back: listed for Fleet, waiting on the WhatsApp groups',
  exists (select 1 from jsonb_array_elements(pg_temp.dr('r38_fleet', 'va_read', 'staff_onboarding_approvals')) x
           where x ->> 'user_id' = test.id('r38_hire')::text and x ->> 'step' = 'whatsapp' and x -> 'waiting_on' ? 'WhatsApp CarmaCars Team group confirmation'));

-- ---------------------------------------------------------------- B. an Admin confirms the groups and approves in one step
select test.throws('B Fleet cannot confirm and approve', format('select pg_temp.dr(%L, %L, %L, %L::jsonb)', 'r38_fleet', 'ops_do', 'staff_whatsapp_approve', jsonb_build_object('user', test.id('r38_hire'))), 'Admin');
select pg_temp.dr('r38_admin', 'ops_do', 'staff_whatsapp_approve', jsonb_build_object('user', test.id('r38_hire')));
select test.eq('B onboarded', app.staff_fully_onboarded(test.id('r38_hire')), true);
select test.ok('B audited', exists (select 1 from audit_log where action = 'staff_whatsapp_confirmed_and_approved' and entity_id = test.id('r38_hire')::text and actor_user_id = test.id('r38_admin')));
select test.eq('B nothing missing', pg_temp.st('r38_hire') -> 'waiting_on', '[]'::jsonb);

-- ---------------------------------------------------------------- C. the r37 tables follow the rules
select test.ok('C channel bookings are audited', exists (select 1 from pg_trigger where tgname = 'audit_channel_bookings'));
select test.eq('C no browser session deletes a bug report', has_table_privilege('authenticated', 'public.bug_reports', 'delete'), false);

-- ---------------------------------------------------------------- D. a person never credited is not asked who found the client
select test.eq('D customer service is never credited', app.credit_blocked(test.id('r38_cs')), true);

-- ---------------------------------------------------------------- E. a partner who sends insurer rentals: 60%, sourced by 10% (2361)
select test.mk_user('r38_sales', 'va', 'sales');
select test.mk_renter('r38_rita');
create temp table r38 as select null::text as k, null::jsonb as v limit 0;
insert into r38 select 'car', app.vehicle_add(test.id('r38_admin'), jsonb_build_object('supply_type', 'company', 'vin', '1R38XMM0000000001', 'plate', 'R38001', 'year', 2024,
  'make', 'Kia', 'model', 'K5', 'rates', jsonb_build_object('daily', 10000, 'weekend', 10000, 'weekly', 70000, 'monthly', 300000, 'deposit', 30000)));
select test.throws('E customer service cannot be Sourced by', format('select app.referral_partner_save(%L, %L::jsonb)', test.id('r38_admin'),
  jsonb_build_object('kind', 'insurer_rentals', 'business_name', 'R38 Broker', 'sourced_by', test.id('r38_cs'), 'sourced_by_bps', 1000)), 'pick a Sales person');
insert into r38 select 'p', app.door(test.id('r38_admin'), 'aal2', 'admin_do', 'referral_partner_save', jsonb_build_object('kind', 'insurer_rentals', 'business_name', 'R38 Broker',
  'rate_kind', 'percent', 'rate_bps', 6000, 'sourced_by', test.id('r38_sales'), 'sourced_by_bps', 1000));
select test.eq('E 60% of the rental, insurer rentals, no HST, sourced by 10%',
  (select kind || '/' || rate_bps || '/' || commission_hst || '/' || sourced_by_bps from referral_partners where id = ((select v from r38 where k = 'p') ->> 'id')::uuid), 'insurer_rentals/6000/false/1000');
insert into r38 select 'b', app.manual_rental_create(test.id('r38_admin'), jsonb_build_object('vehicle_id', ((select v from r38 where k = 'car') ->> 'vehicle_id')::uuid,
  'pickup_at', app.local_midnight(app.today() - 10) + interval '10 hours', 'return_at', app.local_midnight(app.today() - 7) + interval '10 hours', 'source', 'phone',
  'coverage_option', 1, 'past', true, 'renter_id', test.id('renter:r38_rita'), 'payment', jsonb_build_object('mode', 'other_way', 'method', 'cash'),
  'referral_code', (select referral_code from referral_partners where id = ((select v from r38 where k = 'p') ->> 'id')::uuid)));
create function pg_temp.r38b() returns uuid language sql as $$ select coalesce((v ->> 'booking_id')::uuid, (v ->> 'id')::uuid) from r38 where k = 'b' $$;
select test.ok('E the base is the rental before tax', (select e.base_cents = app.commission_base_cents(pg_temp.r38b()) and e.base_cents > 0
  and e.base_cents < (select total_due_at_booking_cents from bookings where id = pg_temp.r38b()) from referral_partner_earnings e where e.booking_id = pg_temp.r38b() and e.kind = 'earning'));
select test.ok('E the partner earns 60% of it, no HST', (select e.amount_cents = round(e.base_cents * 0.6) and (app.referral_earning_row(e) ->> 'hst_cents')::int = 0
  from referral_partner_earnings e where e.booking_id = pg_temp.r38b() and e.kind = 'earning'));
select test.ok('E the Sales person earns 10% of it, no HST, on their commissions', (select c.amount_cents = round(e.base_cents * 0.1) and c.base_cents = e.base_cents and c.status = e.status
  from staff_commissions c join referral_partner_earnings e on e.booking_id = c.booking_id and e.kind = 'earning'
  where c.booking_id = pg_temp.r38b() and c.kind = 'partner_sourced' and c.staff_id = test.id('r38_sales')));
select app.referral_partner_save(test.id('r38_admin'), jsonb_build_object('id', ((select v from r38 where k = 'p') ->> 'id')::uuid, 'commission_hst', true));
select test.ok('E HST on: 13% on top on the partner''s statement', (select (app.referral_earning_row(e) ->> 'hst_cents')::bigint = round(e.amount_cents * 0.13)
  from referral_partner_earnings e where e.booking_id = pg_temp.r38b() and e.kind = 'earning'));
