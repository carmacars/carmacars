-- 99: release 37 (migration 2330): customer service, Fleet and Finance get no sales credit or commission, by any path; Sales still
-- can; their help is recorded as "Helped by" and counted on their KPIs. Fixtures "ncs".
select test.suite('99 r37 no credit for support (2330)');

select test.mk_user('ncs_admin', 'admin');
select test.mk_user('ncs_sales', 'va', 'sales');
select test.mk_user('ncs_cs', 'va', 'cs');
select test.mk_user('ncs_fleet', 'va', 'fleet');
select test.mk_user('ncs_fin', 'va', 'finance');
select test.mk_user('ncs_mix', 'va', 'sales');
update staff_profiles set functions = array['sales', 'cs'] where user_id = test.id('ncs_mix');
select test.mk_user('ncs_field', 'field', null, null, 'NCSFIELD');
select test.mk_renter('ncs_rita');
update staff_profiles set single_limit_cents = 500000 where user_id in (test.id('ncs_cs'), test.id('ncs_fin'), test.id('ncs_fleet'), test.id('ncs_sales'), test.id('ncs_mix'));

create temp table ncs as select null::text as k, null::jsonb as v limit 0;
create or replace function test.ncs(p_k text) returns jsonb language sql stable as $$ select v from pg_temp.ncs where k = p_k $$;
create or replace function test.ncsb(p_k text) returns bookings language sql stable as $$
  select * from bookings where id = coalesce((test.ncs(p_k) ->> 'booking_id')::uuid, (test.ncs(p_k) ->> 'id')::uuid) $$;
insert into ncs select 'car', app.vehicle_add(test.id('ncs_admin'), '{"supply_type": "company", "vin": "1NCSSALES00000001", "plate": "NCS0001",
  "year": 2024, "make": "Kia", "model": "K5", "rates": {"daily": 10000, "weekend": 10000, "weekly": 70000, "monthly": 300000, "deposit": 30000}}');
create or replace function test.ncsrental(p_days integer, p_choice text) returns jsonb language sql as $$
  select jsonb_build_object('vehicle_id', (test.ncs('car') ->> 'vehicle_id')::uuid, 'pickup_at', date_trunc('hour', now()) + make_interval(days => p_days),
    'return_at', date_trunc('hour', now()) + make_interval(days => p_days + 2), 'source', 'phone', 'coverage_option', 1,
    'renter_id', test.id('renter:ncs_rita'), 'payment', jsonb_build_object('mode', 'link'), 'sales_choice', p_choice) $$;

-- ================================================================ 1. the rule
select test.eq('blocked: customer service, Fleet and Finance only',
  app.credit_blocked(test.id('ncs_cs')) || '/' || app.credit_blocked(test.id('ncs_fleet')) || '/' || app.credit_blocked(test.id('ncs_fin')), 'true/true/true');
select test.eq('not blocked: Sales, Sales and customer service, field staff, an Admin, a renter',
  app.credit_blocked(test.id('ncs_sales')) || '/' || app.credit_blocked(test.id('ncs_mix')) || '/' || app.credit_blocked(test.id('ncs_field')) || '/'
  || app.credit_blocked(test.id('ncs_admin')) || '/' || app.credit_blocked(test.id('renter:ncs_rita')), 'false/false/false/false/false');

-- a rental added by hand: "I sourced this client" by customer service or Finance credits nobody and pays nothing
insert into ncs select 'cs1', app.door(test.id('ncs_cs'), 'aal2', 'ops_do', 'manual_rental_create', test.ncsrental(3, 'sourced'));
select test.eq('customer service adds a rental and says sourced: no credit, not sourced, no commission',
  (select coalesce(sales_staff_id::text, 'none') || '/' || sales_sourced || '/' || coalesce(sales_choice, 'none') from test.ncsb('cs1')) || '/'
  || (select count(*) from staff_commissions where booking_id = (test.ncsb('cs1')).id), 'none/false/none/0');
insert into ncs select 'fin1', app.door(test.id('ncs_fin'), 'aal2', 'ops_do', 'manual_rental_create', test.ncsrental(8, 'for_carmacars'));
select test.eq('Finance entered for CarmaCars: no credit either (the tracking credit went too)',
  (select coalesce(sales_staff_id::text, 'none') from test.ncsb('fin1')), 'none');
-- Sales still can
insert into ncs select 'sales1', app.door(test.id('ncs_sales'), 'aal2', 'ops_do', 'manual_rental_create', test.ncsrental(13, 'sourced'));
select test.eq('Sales adds a rental and says sourced: credited, sourced, a commission accruing',
  (select (sales_staff_id = test.id('ncs_sales')) || '/' || sales_sourced from test.ncsb('sales1')) || '/'
  || (select count(*) from staff_commissions where booking_id = (test.ncsb('sales1')).id and staff_id = test.id('ncs_sales')), 'true/true/1');
-- a person with Sales and customer service keeps credit for work as Sales; the window of customer service work credits nobody
insert into ncs select 'mix1', app.door(test.id('ncs_mix'), 'aal2', 'ops_do', 'manual_rental_create', test.ncsrental(18, 'sourced'));
select test.eq('Sales and customer service together: credited as Sales', (select (sales_staff_id = test.id('ncs_mix')) || '/' || sales_sourced from test.ncsb('mix1')), 'true/true');
select test.ok('working as customer service: blocked', (select app.credit_blocked(test.id('ncs_mix')) from (select set_config('app.sales_as_cs', test.id('ncs_mix')::text, true)) x));
select test.ok('back to Sales work: not blocked', (select not app.credit_blocked(test.id('ncs_mix')) from (select set_config('app.sales_as_cs', '', true)) x));

-- a website request: the first offer by customer service credits nobody; the next one, by Sales, does
insert into ncs select 'web1', jsonb_build_object('id', app.request_booking(test.id('renter:ncs_rita'), (test.ncs('car') ->> 'vehicle_id')::uuid,
  date_trunc('hour', now()) + interval '40 days', date_trunc('hour', now()) + interval '43 days', 'standard', null, 'web', test.id('ncs_rita')));
select app.send_offer((test.ncsb('web1')).id, test.id('ncs_cs'));
select test.ok('the first offer by customer service credits nobody', (test.ncsb('web1')).sales_staff_id is null and (test.ncsb('web1')).sales_source is null);
select test.eq('...and Helped by names them', (select string_agg(h ->> 'name' || ': ' || (h -> 'what' ->> 0), ', ') from jsonb_array_elements(app.helped_by((test.ncsb('web1')).id, null)) h), 'Ncs Cs: sent the offer');
select app.withdraw_offer((test.ncsb('web1')).id, test.id('ncs_admin'), 'Ncs edit');
select app.send_offer((test.ncsb('web1')).id, test.id('ncs_sales'));
select test.eq('the next offer, by Sales, credits Sales', (select sales_staff_id::text || ' ' || sales_source from test.ncsb('web1')), test.id('ncs_sales')::text || ' offer');

-- the database rule itself, whoever writes
update bookings set sales_staff_id = test.id('ncs_cs'), sales_source = 'admin', sales_attributed_at = now(), sales_sourced = true where id = (test.ncsb('sales1')).id;
select test.ok('a booking cannot be given to customer service by a plain update', (select sales_staff_id is distinct from test.id('ncs_cs') from test.ncsb('sales1')));
select test.eq('the commission calculation ran after: Sales commission closed, customer service has none',
  (select count(*) from staff_commissions where booking_id = (test.ncsb('sales1')).id and staff_id = test.id('ncs_cs')), 0::bigint);
insert into staff_commissions (booking_id, staff_id, kind, month, status)
values ((test.ncsb('sales1')).id, test.id('ncs_cs'), 'commission', app.month_start(app.today()), 'accruing');
select test.eq('a commission row for customer service is never made', (select count(*) from staff_commissions where staff_id = test.id('ncs_cs')), 0::bigint);
select test.eq('...and none for Finance or Fleet either', (select count(*) from staff_commissions where staff_id in (test.id('ncs_fin'), test.id('ncs_fleet'), test.id('ncs_cs'))), 0::bigint);

-- the Admin's pickers say no
insert into ncs select 'adm1', app.door(test.id('ncs_admin'), 'aal2', 'ops_do', 'manual_rental_create', test.ncsrental(23, 'for_carmacars'));
select test.throws('Reassign to customer service is refused', format($$select app.sales_reassign(%L, jsonb_build_object('booking', %L, 'staff', %L, 'sourced', true, 'reason', 'x'))$$,
  test.id('ncs_admin'), (test.ncsb('adm1')).id, test.id('ncs_cs')), 'no sales credit or commission');
select test.throws('Reassign to Finance is refused', format($$select app.sales_reassign(%L, jsonb_build_object('booking', %L, 'staff', %L, 'sourced', false, 'reason', 'x'))$$,
  test.id('ncs_admin'), (test.ncsb('adm1')).id, test.id('ncs_fin')), 'no sales credit or commission');
select test.lives('Reassign to Sales is fine', format($$select app.sales_reassign(%L, jsonb_build_object('booking', %L, 'staff', %L, 'sourced', true, 'reason', 'Test'))$$,
  test.id('ncs_admin'), (test.ncsb('adm1')).id, test.id('ncs_sales')));
select test.ok('the picker lists Sales, the Admin and field staff, never customer service, Fleet or Finance',
  (select not exists (select 1 from jsonb_array_elements(app.sales_staff_options(test.id('ncs_admin'))) o where (o ->> 'id')::uuid in (test.id('ncs_cs'), test.id('ncs_fleet'), test.id('ncs_fin')))
      and exists (select 1 from jsonb_array_elements(app.sales_staff_options(test.id('ncs_admin'))) o where (o ->> 'id')::uuid = test.id('ncs_sales'))));
select test.throws('a commission rate for customer service is refused', format($$select app.staff_commission_rate_set(%L, jsonb_build_object('staff', %L, 'bps', 500, 'reason', 'x'))$$,
  test.id('ncs_admin'), test.id('ncs_cs')), 'no sales credit or commission');
-- a claim ("I sourced this client") by customer service is dropped; an Admin cannot accept one
update bookings set sales_claim_by = test.id('ncs_cs'), sales_claim_at = now() where id = (test.ncsb('adm1')).id;
select test.ok('a claim by customer service is dropped', (select sales_claim_by is null from test.ncsb('adm1')));

-- leads, owners, applications, owner commission requests, Sales claims
insert into leads (id, kind, name, email, source, sourced_by) values (test.id('lead:ncs1'), 'contact', 'Ncs One', 'ncs1@example.test', 'web', test.id('ncs_cs'));
select test.ok('a lead cannot be sourced by customer service', (select sourced_by is null from leads where id = test.id('lead:ncs1')));
insert into leads (id, kind, name, email, source, sourced_by) values (test.id('lead:ncs2'), 'contact', 'Ncs Two', 'ncs2@example.test', 'web', test.id('ncs_sales'));
select test.ok('a lead sourced by Sales keeps it', (select sourced_by = test.id('ncs_sales') from leads where id = test.id('lead:ncs2')));
select test.mk_owner('ncs_olive');
update owners set recruited_by = test.id('ncs_fleet'), recruited_at = now(), recruited_via = 'admin' where id = test.id('owner:ncs_olive');
select test.ok('an owner cannot be recruited by Fleet', (select recruited_by is null and recruited_via is null from owners where id = test.id('owner:ncs_olive')));
select test.throws('an owner commission request for Finance is refused',
  format($$insert into owner_recruit_requests (owner_id, staff_id, kind, amount_cents) values (%L, %L, 'flat', 5000)$$, test.id('owner:ncs_olive'), test.id('ncs_fin')), 'no sales credit or commission');
select test.throws('a Sales lead claim by customer service is refused',
  format($$insert into lead_claims (lead_id, claimed_by, expires_at, cap_at) values (%L, %L, now() + interval '1 hour', now() + interval '2 hours')$$, test.id('lead:ncs1'), test.id('ncs_cs')), 'no sales credit or commission');
select test.lives('a Sales lead claim by Sales is fine',
  format($$insert into lead_claims (lead_id, claimed_by, expires_at, cap_at) values (%L, %L, now() + interval '1 hour', now() + interval '2 hours')$$, test.id('lead:ncs1'), test.id('ncs_sales')));

-- ================================================================ 2. Helped by
-- customer service checked the licence, Finance did a task and Fleet held the call; Sales is credited
insert into tasks (task_type, queue, title, status, booking_id, completed_by, completed_at, priority)
values ('verify_renter', 'cs', 'Verify the renter', 'done', (test.ncsb('sales1')).id, test.id('ncs_fin'), now(), 'normal');
select app.log_booking_event((test.ncsb('sales1')).id, 'verification', null, null, null, 'Licence checked', test.id('ncs_cs'), 'staff');
select app.log_booking_event((test.ncsb('sales1')).id, 'verification', null, null, null, 'Licence checked again', test.id('ncs_cs'), 'staff');
select app.log_booking_event((test.ncsb('sales1')).id, 'info_replied', null, null, null, 'Answered', test.id('ncs_sales'), 'staff');
select test.eq('Helped by: customer service and Finance, once each, not the credited Sales person',
  (select string_agg(h ->> 'name', ', ' order by h ->> 'name') from jsonb_array_elements(app.helped_by((test.ncsb('sales1')).id, null)) h), 'Ncs Cs, Ncs Fin');
select test.eq('Helped by: what they did, each once', (select h -> 'what' ->> 0 from jsonb_array_elements(app.helped_by((test.ncsb('sales1')).id, null)) h where h ->> 'name' = 'Ncs Cs'), 'checked the licence');
select test.ok('Helped by: customer service''s own line says only that',
  (select jsonb_array_length(h -> 'what') = 1 from jsonb_array_elements(app.helped_by((test.ncsb('sales1')).id, null)) h where h ->> 'name' = 'Ncs Cs'));
-- the booking page reads it through the door, for an Admin and for every staff function
select test.eq('door: an Admin reads Helped by', (select jsonb_array_length(app.door(test.id('ncs_admin'), 'aal2', 'ops_read', 'booking_helped', jsonb_build_object('booking', (test.ncsb('sales1')).booking_number)) -> 'helped_by')), 2);
select test.eq('door: customer service, Fleet, Finance and Sales read it too',
  (select string_agg(jsonb_array_length(app.door(u, 'aal2', 'ops_read', 'booking_helped', jsonb_build_object('booking', (test.ncsb('sales1')).id)) -> 'helped_by')::text, ',')
     from unnest(array[test.id('ncs_cs'), test.id('ncs_fleet'), test.id('ncs_fin'), test.id('ncs_sales')]) u), '2,2,2,2');
select test.throws('door: a renter does not', format($$select app.door(%L, 'aal2', 'ops_read', 'booking_helped', jsonb_build_object('booking', %L))$$, test.id('ncs_rita'), (test.ncsb('sales1')).id), '');
-- a lead: customer service logged a contact; Sales holds it
insert into lead_contacts (lead_id, by_user, channel, note) values (test.id('lead:ncs1'), test.id('ncs_cs'), 'call', 'Answered the call');
insert into lead_contacts (lead_id, by_user, channel, note) values (test.id('lead:ncs1'), test.id('ncs_sales'), 'text', 'Followed up');
select test.eq('lead: Helped by lists customer service, not the Sales holder',
  (select string_agg(h ->> 'name', ', ') from jsonb_array_elements(app.sales_lead(test.id('ncs_admin'), jsonb_build_object('id', test.id('lead:ncs1'))) -> 'helped_by') h), 'Ncs Cs');
-- the KPIs: a Helped count, no money
select test.eq('KPIs: customer service helped on 3 bookings (its own rental, the licence, an offer) and 1 lead this week (no target)',
  (select (k ->> 'value') || '/' || coalesce(k ->> 'target', 'none') from jsonb_array_elements(app.role_kpis(test.id('ncs_cs'), date_trunc('week', app.today()::timestamp)::date)) k where k ->> 'key' = 'helped'), '4/none');
select test.eq('KPIs: Finance helped on 2 bookings',
  (select (k ->> 'value') from jsonb_array_elements(app.role_kpis(test.id('ncs_fin'), date_trunc('week', app.today()::timestamp)::date)) k where k ->> 'key' = 'helped'), '2');
select test.ok('KPIs: the team board carries it for customer service',
  exists (select 1 from jsonb_array_elements(app.kpi_board(test.id('ncs_admin'), '{}'::jsonb) -> 'people') p, jsonb_array_elements(p -> 'items') k
           where p ->> 'user_id' = test.id('ncs_cs')::text and k ->> 'key' = 'helped'));
select test.ok('KPIs: the scorecard carries it', exists (select 1 from jsonb_array_elements(app.staff_scorecard(test.id('ncs_cs'), 1) #> '{kpis,0,items}') k where k ->> 'key' = 'helped'));
select test.ok('KPIs: field staff have no Helped line', not exists (select 1 from jsonb_array_elements(app.role_kpis(test.id('ncs_field'), date_trunc('week', app.today()::timestamp)::date)) k where k ->> 'key' = 'helped'));
-- the credit on file was reported
select test.ok('the migration reported what was on file', exists (select 1 from audit_log where action = 'credit_rule_2330_report'));
select test.ok('the helpers are server only', not has_function_privilege('anon', 'app.credit_blocked(uuid)', 'execute') and not has_function_privilege('authenticated', 'app.helped_by(uuid, uuid)', 'execute'));
