-- 99: Sales staff bring in car owners and ask for a commission on each (migration 0340). Attribution (an invitation, the
-- signed link, Start it; the first credit stands; only an Admin reassigns), the commission request (flat or percent, the
-- base and the duration, revised while pending, approved as asked, changed or declined; nothing before approval), the flat
-- amount at the owner's first paid rental (one per owner), the percent on each paid rental in the window, the remote mode
-- recorded, no commission on company or shareholder cars, a company expense (never before Owner Revenue), Admin approval,
-- a cancelled rental reversed, and privileges (a salesperson sees only their own). Fixtures start with "sor".
select test.suite('99 sales owner recruitment');

select test.mk_user('sor_admin', 'admin');
select test.mk_user('sor_ana', 'va', 'sales');
select test.mk_user('sor_ben', 'va', 'sales');
select test.mk_user('sor_cs', 'va', 'cs');
update staff_profiles set sales_work_mode = 'remote' where user_id = test.id('sor_ben');
select test.mk_renter('sor_rita');
create function test.sor_do(p_who text, p_name text, p jsonb) returns jsonb language sql as $$ select app.door(test.id(p_who), 'aal2', 'va_do', p_name, p || '{"_va": "sales"}') $$;
create function test.sor_admin(p_name text, p jsonb) returns jsonb language sql as $$ select app.door(test.id('sor_admin'), 'aal2', 'admin_do', p_name, p) $$;
create function test.sor_req(p_owner text) returns owner_recruit_requests language sql stable as $$ select * from owner_recruit_requests where owner_id = test.id('owner:' || p_owner) $$;
create function test.sor_rows(p_owner text) returns text language sql stable as $$
  select coalesce(string_agg(b.booking_number || ':' || c.scheme || ':' || c.amount_cents || ':' || c.status, ' ' order by b.booking_number, c.created_at), '-')
    from staff_commissions c join bookings b on b.id = c.booking_id join owner_recruit_requests r on r.id = c.owner_recruit_request_id
   where r.owner_id = test.id('owner:' || p_owner) and c.kind = 'owner_recruit' $$;

-- ================================================================ 1. invite and attribution
select test.throws('invite: only to an owner who asked', $$select test.sor_do('sor_ana', 'sales_owner_invite', '{"name": "Ivy Owner", "email": "sor_ivy@example.test"}')$$, '%asked%');
select test.throws('invite: Sales only', $$select app.door(test.id('sor_cs'), 'aal2', 'va_do', 'sales_owner_invite', '{"name": "Ivy Owner", "email": "sor_ivy@example.test", "asked": true}')$$, '%Sales staff only%');
select test.ok('invite: the lead comes back', (test.sor_do('sor_ana', 'sales_owner_invite', '{"name": "Ivy Owner", "email": "sor_ivy@example.test", "phone": "416-555-0101", "asked": true}') ->> 'lead_id') is not null);
select test.ok('invite: a lead credited to Ana, without automatic follow-ups',
  exists (select 1 from leads where email = 'sor_ivy@example.test' and sourced_by = test.id('sor_ana') and followup_next_at is null and followup_stopped_at is not null));
select test.throws('invite: another salesperson cannot take an owner already invited', $$select test.sor_do('sor_ben', 'sales_owner_invite', '{"name": "Ivy", "email": "SOR_IVY@example.test", "asked": true}')$$, '%Another salesperson%');

-- the invited owner applies: the application, the owner and the lead are Ana's
select test.mk_owner('sor_ivy');
update owners set recruited_by = null where id = test.id('owner:sor_ivy');
insert into owner_applications (id, owner_id, source) values (test.id('app:sor_ivy'), test.id('owner:sor_ivy'), 'web');
select test.eq('attribution: an application from the invited address is Ana''s (owner, application, how)',
  (select o.recruited_by = test.id('sor_ana') and a.sourced_by = test.id('sor_ana') and o.recruited_via = 'invite' from owners o, owner_applications a
    where o.id = test.id('owner:sor_ivy') and a.id = test.id('app:sor_ivy')), true);
select test.throws('invite: an owner on file cannot be invited', $$select test.sor_do('sor_ben', 'sales_owner_invite', '{"name": "Ivy", "email": "sor_ivy@example.test", "asked": true}')$$, '%on file already%');

-- Ben's personal link (the website checks the signature, then credits)
select test.mk_owner('sor_tom');
insert into owner_applications (id, owner_id, source) values (test.id('app:sor_tom'), test.id('owner:sor_tom'), 'web');
select test.eq('attribution: the personal link credits Ben', public.server_owner_sales_credit(test.id('app:sor_tom'), test.id('sor_ben')) ->> 'owner_credited', 'true');
select test.eq('attribution: the first credit stands', (public.server_owner_sales_credit(test.id('app:sor_ivy'), test.id('sor_ben')) ->> 'credited')
  || '/' || ((select recruited_by from owners where id = test.id('owner:sor_ivy')) = test.id('sor_ana')), 'false/true');
select test.eq('attribution: a person who is not Sales is not credited', public.server_owner_sales_credit(test.id('app:sor_tom'), test.id('sor_cs')) ->> 'credited', 'false');

-- Start it: Ana enters a new owner and car; the application waits for an Admin; terms are not hers to set
create temp table sor_start as select test.sor_do('sor_ana', 'staff_add_owner_car', jsonb_build_object('as_sales', true, 'signing', 'email', 'sourced', false,
     'owner', jsonb_build_object('owner_type', 'individual', 'legal_name', 'Flo Starter', 'first_name', 'Flo', 'email', 'sor_flo@example.test', 'phone', '416-555-0102'),
     'vehicle', jsonb_build_object('vin', '3FAKESRA5RT000001', 'year', 2024, 'make', 'Toyota', 'model', 'Corolla', 'title_status', 'owned_outright', 'management_mode', 'managed'),
     'plan', jsonb_build_object('terms', jsonb_build_object('revenue_share_bps', 100)), 'approve', true)) r;
select test.ok('start it: an application for an Admin, sourced by Ana, no terms kept', (select (r ->> 'approved')::boolean = false from sor_start)
  and exists (select 1 from owner_applications a join owners o on o.id = a.owner_id where o.email = 'sor_flo@example.test' and a.status = 'new' and a.plan is null
                and a.sourced_by = test.id('sor_ana') and o.recruited_by = test.id('sor_ana') and o.recruited_via = 'started'));
select test.throws('start it: not for an owner someone else brought in', format($$select test.sor_do('sor_ana', 'staff_add_owner_car', jsonb_build_object('as_sales', true, 'owner_id', %L,
     'vehicle', jsonb_build_object('plate', 'SOR0002', 'year', 2022, 'make', 'Honda', 'model', 'Civic', 'title_status', 'owned_outright', 'management_mode', 'managed')))$$, test.id('owner:sor_tom')), '%you brought in%');
-- customer service adding a car for an owner on file no longer makes them its sourcer
select test.mk_owner('sor_old');
select app.staff_add_owner_car(test.id('sor_cs'), jsonb_build_object('owner_id', test.id('owner:sor_old'), 'sourced', true,
  'vehicle', jsonb_build_object('plate', 'SOR0003', 'year', 2022, 'make', 'Honda', 'model', 'Civic', 'title_status', 'owned_outright', 'management_mode', 'managed')));
select test.eq('attribution: not self-assigned after the fact by adding a car', (select recruited_by from owners where id = test.id('owner:sor_old')), null::uuid);

-- ================================================================ 2. the request
select test.throws('request: only for an owner you brought in', format($$select test.sor_do('sor_ana', 'sales_owner_commission_request', jsonb_build_object('owner_id', %L, 'kind', 'flat', 'amount_cents', 10000))$$, test.id('owner:sor_tom')), '%you brought in%');
select test.throws('request: a percent needs its duration', format($$select test.sor_do('sor_ana', 'sales_owner_commission_request', jsonb_build_object('owner_id', %L, 'kind', 'percent', 'rate_bps', 1000))$$, test.id('owner:sor_ivy')), '%how long%');
select test.eq('request: no amount is set for them', (select count(*)::int from owner_recruit_requests), 0);
select test.sor_do('sor_ana', 'sales_owner_commission_request', jsonb_build_object('owner_id', test.id('owner:sor_ivy'), 'kind', 'flat', 'amount_cents', 15000));
select test.eq('request: revised while pending; the "of what" defaults to the company''s share',
  test.sor_do('sor_ana', 'sales_owner_commission_request', jsonb_build_object('owner_id', test.id('owner:sor_ivy'), 'kind', 'percent', 'rate_bps', 1000, 'months', 3, 'note', 'Two cars coming')) ->> 'asked',
  '10% of the company''s share for 3 months');
select test.eq('request: one per owner, revised in place, an Admin task raised',
  (select count(*)::int || '/' || max(revisions) from owner_recruit_requests where owner_id = test.id('owner:sor_ivy')) || '/'
  || (select count(*) from tasks where related_table = 'owner_recruit_requests' and status = 'open'), '1/1/1');

-- the cars and the rentals
select test.mk_vehicle('sor_ivy_a', 'sor_ivy');
select test.mk_vehicle('sor_ivy_sh', 'sor_ivy', p_shareholder => true);
select test.mk_booking('SOR-0', 'sor_ivy_a', 'sor_rita', '2026-08-02 10:00', '2026-08-05 10:00', 'closed', 30000);
select test.eq('nothing accrues before approval', test.sor_rows('sor_ivy'), '-');
select test.throws('only an Admin decides', format($$select app.door(%L, 'aal2', 'va_do', 'owner_recruit_decide', jsonb_build_object('id', %L, 'decision', 'approve'))$$, test.id('sor_ana'), (test.sor_req('sor_ivy')).id));
-- the Admin approves changed terms: 10% of the rental revenue for 2 months (approval dated September 1 for the fixture)
select test.eq('approve: changed terms', test.sor_admin('owner_recruit_decide', jsonb_build_object('id', (test.sor_req('sor_ivy')).id, 'decision', 'approve',
  'kind', 'percent', 'rate_bps', 1000, 'base', 'car_revenue', 'months', 2, 'note', 'Revenue, 2 months')) ->> 'approved', '10% of the cars'' rental revenue for 2 months');
select test.eq('approve: marked changed, the task done', (select (r.changed)::text from owner_recruit_requests r where r.owner_id = test.id('owner:sor_ivy'))
  || '/' || (select count(*) from tasks where related_table = 'owner_recruit_requests' and status = 'open'), 'true/0');
update owner_recruit_requests set decided_at = '2026-09-01 00:00 America/Toronto', starts_month = null where owner_id = test.id('owner:sor_ivy');
select test.mk_booking('SOR-1', 'sor_ivy_a', 'sor_rita', '2026-09-02 10:00', '2026-09-06 10:00', 'closed', 40000);
select test.mk_booking('SOR-2', 'sor_ivy_a', 'sor_rita', '2026-10-02 10:00', '2026-10-04 10:00', 'closed', 20000);
select test.mk_booking('SOR-3', 'sor_ivy_a', 'sor_rita', '2026-11-02 10:00', '2026-11-04 10:00', 'closed', 20000);
select test.mk_booking('SOR-SH', 'sor_ivy_sh', 'sor_rita', '2026-09-10 10:00', '2026-09-12 10:00', 'closed', 20000);
select test.eq('percent: each paid rental in the window (September and October), none before approval, after it ends or on a shareholder''s car',
  test.sor_rows('sor_ivy'), 'SOR-1:recruit_percent:' || public.calc_bps(app.commission_base_cents(test.id('booking:SOR-1')), 1000) || ':pending_approval '
  || 'SOR-2:recruit_percent:' || public.calc_bps(app.commission_base_cents(test.id('booking:SOR-2')), 1000) || ':pending_approval');
select test.eq('percent: the window starts in the month of the first rental after approval', (test.sor_req('sor_ivy')).starts_month, date '2026-09-01');
select test.eq('a company expense: nothing is deducted before Owner Revenue', app.booking_staff_commission_cents(test.id('booking:SOR-1')), 0::bigint);
select test.eq('Admin''s list: paid from a CarmaCars expense, with the owner',
  (select string_agg(distinct (e ->> 'paid_from') || '|' || (e ->> 'owner'), ',') from jsonb_array_elements(app.commission_admin(test.id('sor_admin'), jsonb_build_object('staff', test.id('sor_ana'))) -> 'rows') e
    where e ->> 'kind' = 'owner_recruit'), 'carmacars_expense|Sor Ivy');

-- Admin approval in the usual flow; a cancelled rental is reversed
select test.throws('commission approval: Admins only', format($$select app.door(%L, 'aal2', 'va_do', 'commission_approve', jsonb_build_object('ids', jsonb_build_array(%L)))$$,
  test.id('sor_ana'), (select c.id from staff_commissions c where c.booking_id = test.id('booking:SOR-1') and c.kind = 'owner_recruit')));
select test.sor_admin('commission_approve', jsonb_build_object('ids', jsonb_build_array((select c.id from staff_commissions c where c.booking_id = test.id('booking:SOR-1') and c.kind = 'owner_recruit'))));
select test.eq('commission approval: approved by an Admin', (select status from staff_commissions c where c.booking_id = test.id('booking:SOR-1') and c.kind = 'owner_recruit'), 'approved');
insert into disputes (payment_id, booking_id, amount_cents, status) values (test.id('payment:SOR-2'), test.id('booking:SOR-2'), 22600, 'lost');
select test.eq('a charged-back rental: its commission is reversed', (select status from staff_commissions c where c.booking_id = test.id('booking:SOR-2') and c.kind = 'owner_recruit'), 'reversed');

-- ================================================================ 3. flat: once, at the first paid rental; the remote mode kept
select test.sor_do('sor_ben', 'sales_owner_commission_request', jsonb_build_object('owner_id', test.id('owner:sor_tom'), 'kind', 'flat', 'amount_cents', 12500));
select test.sor_admin('owner_recruit_decide', jsonb_build_object('id', (test.sor_req('sor_tom')).id, 'decision', 'approve'));
select test.eq('flat: approved as asked', (select a_kind || '/' || a_amount_cents || '/' || changed from owner_recruit_requests where owner_id = test.id('owner:sor_tom')), 'flat/12500/false');
select test.eq('flat: nothing before the first paid rental', test.sor_rows('sor_tom'), '-');
select test.mk_vehicle('sor_tom_a', 'sor_tom');
select test.mk_booking('SOR-T1', 'sor_tom_a', 'sor_rita', '2026-10-10 10:00', '2026-10-12 10:00', 'closed', 20000);
select test.mk_booking('SOR-T2', 'sor_tom_a', 'sor_rita', '2026-10-20 10:00', '2026-10-22 10:00', 'closed', 20000);
select app.job_owner_recruit();
select test.eq('flat: one commission, on the first paid rental, never again', test.sor_rows('sor_tom'), 'SOR-T1:recruit_flat:12500:pending_approval');
select test.eq('remote: the commission keeps the mode', (select work_mode from staff_commissions where kind = 'owner_recruit' and staff_id = test.id('sor_ben')), 'remote');

-- ================================================================ 4. no commission on company or shareholder owners
select test.mk_owner('sor_sh', p_shareholder => true);
select test.sor_admin('owner_sourced_set', jsonb_build_object('owner_id', test.id('owner:sor_sh'), 'staff_id', test.id('sor_ana'), 'reason', 'Test: brought in by Ana'));
select test.throws('a shareholder owner: no request', format($$select test.sor_do('sor_ana', 'sales_owner_commission_request', jsonb_build_object('owner_id', %L, 'kind', 'flat', 'amount_cents', 10000))$$, test.id('owner:sor_sh')), '%shareholder%');
select app.company_owner_id();
select test.eq('the company''s own cars: no owner commission', app.owner_recruit_block(app.company_owner_id(), test.id('sor_ana')), 'CarmaCars-owned cars earn no owner commission');
select test.eq('a partner''s cars: no owner commission', (select app.owner_recruit_block(id, null) from owners where kind = 'partner' limit 1),
  (select 'A partner''s cars earn no owner commission' from owners where kind = 'partner' limit 1));

-- ================================================================ 5. decline; reassign by an Admin only
select app.door(test.id('sor_admin'), 'aal2', 'admin_do', 'owner_sourced_set', jsonb_build_object('owner_id', test.id('owner:sor_old'), 'staff_id', test.id('sor_ana'), 'reason', 'Test'));
select test.sor_do('sor_ana', 'sales_owner_commission_request', jsonb_build_object('owner_id', test.id('owner:sor_old'), 'kind', 'flat', 'amount_cents', 50000));
select test.sor_admin('owner_recruit_decide', jsonb_build_object('id', (test.sor_req('sor_old')).id, 'decision', 'decline', 'note', 'Came to us directly'));
select test.throws('declined: the salesperson cannot ask again', format($$select test.sor_do('sor_ana', 'sales_owner_commission_request', jsonb_build_object('owner_id', %L, 'kind', 'flat', 'amount_cents', 100))$$, test.id('owner:sor_old')), '%decided%');
select test.throws('reassign: Admins only', format($$select app.door(%L, 'aal2', 'admin_do', 'owner_sourced_set', jsonb_build_object('owner_id', %L, 'staff_id', %L, 'reason', 'mine'))$$,
  test.id('sor_ana'), test.id('owner:sor_tom'), test.id('sor_ana')));
select test.throws('reassign: a reason is needed', format($$select test.sor_admin('owner_sourced_set', jsonb_build_object('owner_id', %L, 'staff_id', %L))$$, test.id('owner:sor_tom'), test.id('sor_ana')), '%why%');
select test.sor_admin('owner_sourced_set', jsonb_build_object('owner_id', test.id('owner:sor_tom'), 'staff_id', test.id('sor_ana'), 'reason', 'Test: Ana met them first'));
select test.eq('reassign: the owner, the approved request and its unpaid commission move to Ana',
  (select (o.recruited_by = test.id('sor_ana')) || '/' || (r.staff_id = test.id('sor_ana')) || '/' || (select count(*) from staff_commissions c where c.owner_recruit_request_id = r.id and c.staff_id = test.id('sor_ana'))
     from owners o join owner_recruit_requests r on r.owner_id = o.id where o.id = test.id('owner:sor_tom')), 'true/true/1');
select test.sor_admin('owner_sourced_set', jsonb_build_object('owner_id', test.id('owner:sor_tom'), 'staff_id', test.id('sor_ben'), 'reason', 'Test: back to Ben'));

-- ================================================================ 6. privileges: a salesperson sees only their own
select test.eq('Ana''s owners: hers only, with the stage', (select string_agg(e ->> 'name' || ':' || (e ->> 'stage'), ',' order by e ->> 'name')
  from jsonb_array_elements(app.door(test.id('sor_ana'), 'aal2', 'va_read', 'sales_owners', '{"_va": "sales"}') -> 'owners') e),
  'Flo Starter:applied,Sor Ivy:first_paid_rental,Sor Old:applied,Sor Sh:applied');
select test.ok('Ana''s owners: no contact details, terms or revenue of the owner', not exists (select 1 from jsonb_array_elements(app.door(test.id('sor_ana'), 'aal2', 'va_read', 'sales_owners', '{}') -> 'owners') e
  where e ? 'email' or e ? 'phone' or e ? 'revenue_share_bps' or e ? 'owner_revenue_cents'));
select test.eq('Ana''s pipeline counts', (select (c ->> 'invited') || '/' || (c ->> 'applied') || '/' || (c ->> 'first_paid_rental')
  from (select app.door(test.id('sor_ana'), 'aal2', 'va_read', 'sales_owners', '{}') -> 'counts' c) x), '4/4/1');
select test.throws('another person''s pipeline: Admins only', format($$select app.door(%L, 'aal2', 'admin_read', 'sales_owners', jsonb_build_object('staff', %L))$$, test.id('sor_ana'), test.id('sor_ben')), '%admin%');
select test.eq('Admin reads Ben''s pipeline', (select string_agg(e ->> 'name', ',') from jsonb_array_elements(app.door(test.id('sor_admin'), 'aal2', 'admin_read', 'sales_owners', jsonb_build_object('staff', test.id('sor_ben'))) -> 'owners') e), 'Sor Tom');
select test.throws('customer service has no Sales owner list', format($$select app.door(%L, 'aal2', 'va_read', 'sales_owners', '{}')$$, test.id('sor_cs')), '%Sales staff only%');
-- ================================================================ 7. owner leads: Sales see only their own (0342); customer service the whole pipeline
insert into leads (kind, name, email, source) values ('owner_program', 'Wes Website', 'sor_web@example.test', 'web');
insert into leads (kind, name, email, source, contact_kind) values ('owner_recruit', 'Cal Classified', 'sor_cal@example.test', 'classified', 'private_seller');
insert into leads (kind, name, email, source, payload) values ('owner_program', 'Ada Added', 'sor_added@example.test', 'manual', jsonb_build_object('added_by', test.id('sor_ana')));
insert into leads (kind, name, email, source) values ('buyer', 'Bo Buyer', 'sor_buyer@example.test', 'web');
select test.throws('the owner pipeline: not for Sales', format($$select app.door(%L, 'aal2', 'va_read', 'owner_pipeline', '{"_va": "sales"}')$$, test.id('sor_ana')), '%Customer service%');
select test.throws('the owner pipeline: Sales cannot add to it', format($$select app.door(%L, 'aal2', 'va_do', 'owner_pipeline_add', '{"name": "X", "email": "sor_x@example.test", "_va": "sales"}')$$, test.id('sor_ana')), '%Customer service%');
select test.ok('the owner pipeline: customer service keeps every lead', (select count(*) from jsonb_array_elements(app.door(test.id('sor_cs'), 'aal2', 'va_read', 'owner_pipeline', '{"_va": "cs"}') -> 'leads') e
  where e ->> 'email' in ('sor_web@example.test', 'sor_cal@example.test')) = 2);
select test.eq('Owner leads (va_read): Sales get only their own leads', (select string_agg(e ->> 'email', ',' order by e ->> 'email')
  from jsonb_array_elements(app.door(test.id('sor_ana'), 'aal2', 'va_read', 'owner_leads', '{"_va": "sales"}') -> 'leads') e), 'sor_added@example.test');
select test.ok('Owner leads (va_read): only the applications of owners they brought in', not exists (select 1 from jsonb_array_elements(app.door(test.id('sor_ana'), 'aal2', 'va_read', 'owner_leads', '{"_va": "sales"}') -> 'applications') e
  where e ->> 'owner_name' not in (select legal_name from owners where recruited_by = test.id('sor_ana'))));
select test.ok('Owner leads (va_read): customer service sees them all', (select count(*) from jsonb_array_elements(app.door(test.id('sor_cs'), 'aal2', 'va_read', 'owner_leads', '{"_va": "cs"}') -> 'leads') e
  where e ->> 'email' = 'sor_web@example.test') = 1);
select test.eq('Leads list (va_list): no owner lead for Sales, buyers still listed', (select count(*) filter (where r ->> 'kind' in ('owner_program', 'owner_recruit')) || '/' || count(*) filter (where r ->> 'email' = 'sor_buyer@example.test')
  from jsonb_array_elements(app.door(test.id('sor_ana'), 'aal2', 'va_list', 'leads', '{"_va": "sales", "limit": 500}') -> 'rows') r), '0/1');
select test.eq('Leads list (va_list): asking for owner leads gives none', (app.door(test.id('sor_ana'), 'aal2', 'va_list', 'leads', '{"_va": "sales", "eq": {"kind": ["owner_program"]}}') ->> 'count')::int, 0);
select test.throws('lead update: Sales cannot touch another owner lead', format($$select app.door(%L, 'aal2', 'va_do', 'lead_update', jsonb_build_object('id', (select id from leads where email = 'sor_web@example.test'), 'take', true, '_va', 'sales'))$$, test.id('sor_ana')), '%not found%');
select test.ok('lead update: Sales update their own', (app.door(test.id('sor_ana'), 'aal2', 'va_do', 'lead_update', jsonb_build_object('id', (select id from leads where email = 'sor_added@example.test'), 'status', 'contacted', '_va', 'sales')) ->> 'id') is not null);
select test.eq('My sales: the lead they added is there', (select string_agg(e ->> 'name' || ':' || (e ->> 'stage'), ',') from jsonb_array_elements(app.door(test.id('sor_ana'), 'aal2', 'va_read', 'sales_owners', '{}') -> 'invites') e), 'Ada Added:lead');
select set_config('request.jwt.claim.sub', test.id('sor_ana')::text, false);
set role authenticated;
select test.eq('row security: Ana reads her own requests and commissions only, and no owner records',
  (select count(*) from owner_recruit_requests where staff_id <> test.id('sor_ana')) || '/' || (select count(*) from staff_commissions where staff_id <> test.id('sor_ana'))
  || '/' || ((select count(*) from owner_recruit_requests) > 0) || '/' || test.visible($$select 1 from owners where id = '$$ || test.id('owner:sor_tom') || $$'$$) , '0/0/true/' || '0');
select test.eq('row security: Sales read the owner leads they invited or added, no other owner lead; other leads as before',
  (select count(*) from leads where kind in ('owner_program', 'owner_recruit')) || '/' || (select count(*) from leads where email = 'sor_buyer@example.test'), '2/1');
select test.eq('row security: Sales cannot update another owner lead', test.affected($$update leads set status = 'contacted' where email = 'sor_web@example.test'$$), 0::bigint);
select test.throws('row security: a browser session writes no request', $$insert into owner_recruit_requests (owner_id, staff_id, kind, amount_cents) values ((select id from owners limit 1), app.uid(), 'flat', 100)$$);
reset role;
select set_config('request.jwt.claim.sub', '', false);
select test.ok('new functions: not callable from a browser', not has_function_privilege('authenticated', 'app.owner_recruit_decide(uuid, jsonb)', 'execute')
  and not has_function_privilege('authenticated', 'public.server_owner_sales_credit(uuid, uuid, uuid)', 'execute')
  and not has_function_privilege('anon', 'app.sales_owner_invite(uuid, jsonb)', 'execute'));
