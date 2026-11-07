-- 99: kickbacks and repair costs in the profit numbers (migration 0581): invoices tied to a car and a claim by themselves
-- or picked, repair costs per car, the rollups by car, owner and business, who may read and write them, and the owner
-- seeing their own lines only when staff turn it on. Fixtures start with "kr"; every address is example.test.
select test.suite('99 kickbacks and repair costs');

select test.mk_user('kr_admin', 'admin');
select test.mk_user('kr_fin', 'va', 'finance');
select test.mk_user('kr_fleet', 'va', 'fleet');
select test.mk_user('kr_sales', 'va', 'sales');
select test.mk_owner('kr_olga');
select test.mk_owner('kr_omar');
select test.mk_vehicle('KRA', 'kr_olga');
select test.mk_vehicle('KRB', 'kr_olga');
select test.mk_vehicle('KRC', 'kr_omar');
insert into incidents (id, kind, vehicle_id, occurred_at) values (test.id('inc:kr'), 'accident', test.id('vehicle:KRA'), now() - interval '20 days');
insert into claims (id, incident_id, vehicle_id, owner_id, path, claim_number) values (test.id('claim:kr'), test.id('inc:kr'), test.id('vehicle:KRA'), test.id('owner:kr_olga'), 'fleet_policy', 'KR-CLM-1');
insert into referral_partners (id, kind, status, business_name, contact_name, email, referral_code, rate_kind, flat_cents, default_kickback_bps) values
  (test.id('rp:kr_shop'), 'body_shop', 'active', 'KR Collision', 'Kim Shop', 'kr.shop@example.test', 'KRSHOP1', 'flat', 2500, 1000),
  (test.id('rp:kr_tow'), 'tow_truck', 'active', 'KR Towing', 'Ted Tow', 'kr.tow@example.test', 'KRTOW1', 'flat', 2500, 1500);

create temp table kr_inv (k text primary key, id uuid);
create or replace function test.kr_invoice(p_k text, p_partner text, p_kind text, p_claim text, p_amount bigint, p_paid bigint) returns uuid language plpgsql as $$
declare v uuid;
begin
  v := (app.door(test.id('kr_fin'), 'aal2', 'ops_do', 'partner_invoice_save', jsonb_build_object('partner_id', test.id(p_partner), 'kind', p_kind, 'claim_number', p_claim,
        'lines', jsonb_build_array(jsonb_build_object('description', 'Kickback', 'unit_cents', p_amount, 'hst', true)))) ->> 'id')::uuid;
  perform app.door(test.id('kr_fin'), 'aal2', 'ops_do', 'partner_invoice_send', jsonb_build_object('id', v));
  if p_paid > 0 then
    perform app.door(test.id('kr_fin'), 'aal2', 'ops_do', 'partner_invoice_pay', jsonb_build_object('id', v, 'method', 'e_transfer', 'amount_cents', p_paid, 'reference', 'KR-' || p_k));
  end if;
  insert into kr_inv values (p_k, v);
  return v;
end $$;
-- a body shop invoice on the claim (its car by itself), paid in full: $1,000 + HST = $1,130 received, $1,000 kickback
select test.kr_invoice('shop', 'rp:kr_shop', 'repair', 'KR-CLM-1', 100000, 113000);
-- a tow invoice with no claim and no car, half paid: $500 + HST, $282.50 received, $250 kickback
select test.kr_invoice('tow', 'rp:kr_tow', 'towing', null, 50000, 28250);
-- a storage invoice on car C, unpaid: no kickback yet
select test.kr_invoice('store', 'rp:kr_tow', 'storage', null, 20000, 0);

select test.eq('an invoice on a claim gets the claim and its car by itself',
  (select (claim_id = test.id('claim:kr'))::text || ':' || (vehicle_id = test.id('vehicle:KRA'))::text from partner_invoices where id = (select id from kr_inv where k = 'shop')), 'true:true');
select test.ok('an invoice with nothing to go on has no car', (select vehicle_id is null from partner_invoices where id = (select id from kr_inv where k = 'tow')));
select test.throws('fleet does not tie invoices to cars', format($$select app.door(%L, 'aal2', 'ops_do', 'partner_invoice_car', %L)$$, test.id('kr_fleet'),
  jsonb_build_object('id', (select id from kr_inv where k = 'tow'), 'vehicle_id', test.id('vehicle:KRB'))), 'Finance or an Admin');
select app.door(test.id('kr_fin'), 'aal2', 'ops_do', 'partner_invoice_car', jsonb_build_object('id', (select id from kr_inv where k = 'tow'), 'vehicle_id', test.id('vehicle:KRB')));
select app.door(test.id('kr_admin'), 'aal2', 'ops_do', 'partner_invoice_car', jsonb_build_object('id', (select id from kr_inv where k = 'store'), 'vehicle_id', test.id('vehicle:KRC')));
select test.ok('the car picker ties a sent invoice to a car', (select vehicle_id = test.id('vehicle:KRB') from partner_invoices where id = (select id from kr_inv where k = 'tow')));

-- repair costs: from the claim (its car), by Fleet; on car C by an Admin, paid by the owner; one voided
select test.throws('Sales record no repair costs', format($$select app.door(%L, 'aal2', 'ops_do', 'repair_cost_save', %L)$$, test.id('kr_sales'),
  jsonb_build_object('vehicle_id', test.id('vehicle:KRA'), 'vendor_name', 'X', 'description', 'Y', 'amount_cents', 100, 'paid_by', 'company')), 'Fleet, Finance or an Admin');
create temp table kr_rc as select (app.door(test.id('kr_fleet'), 'aal2', 'ops_do', 'repair_cost_save', jsonb_build_object('claim_id', test.id('claim:kr'),
  'vendor_partner_id', test.id('rp:kr_shop'), 'description', 'Front bumper and paint', 'amount_cents', 40000, 'tax_cents', 5200, 'paid_by', 'company', 'spent_on', app.today() - 5)) ->> 'id')::uuid as a;
select test.eq('from a claim: its car', (select vehicle_id from vehicle_repair_costs where id = (select a from kr_rc)), test.id('vehicle:KRA'));
select app.door(test.id('kr_admin'), 'aal2', 'ops_do', 'repair_cost_save', jsonb_build_object('vehicle_id', test.id('vehicle:KRC'), 'vendor_name', 'Corner Garage',
  'description', 'Windshield', 'amount_cents', 30000, 'paid_by', 'owner', 'spent_on', app.today() - 3));
insert into kr_rc select (app.door(test.id('kr_admin'), 'aal2', 'ops_do', 'repair_cost_save', jsonb_build_object('vehicle_id', test.id('vehicle:KRB'), 'vendor_name', 'Oops',
  'description', 'Entered twice', 'amount_cents', 99900, 'paid_by', 'company', 'spent_on', app.today() - 2)) ->> 'id')::uuid;
select app.door(test.id('kr_fin'), 'aal2', 'ops_do', 'repair_cost_void', jsonb_build_object('id', (select a from kr_rc where a <> (select a from kr_rc limit 1) limit 1), 'reason', 'twice'));
select test.throws('a repair cost needs who paid', format($$select app.door(%L, 'aal2', 'ops_do', 'repair_cost_save', %L)$$, test.id('kr_fleet'),
  jsonb_build_object('vehicle_id', test.id('vehicle:KRA'), 'vendor_name', 'X', 'description', 'Y', 'amount_cents', 100)), 'Paid by');

-- ================================================================ the rollups
create or replace function test.kr_read(p_user text, p_level text, p_id uuid) returns jsonb language sql as $$
  select app.door(test.id(p_user), 'aal2', 'ops_read', 'profit_extras', jsonb_build_object('level', p_level, 'id', p_id, 'from', app.today() - 30, 'to', app.today())) $$;
create or replace function test.kr_lines(j jsonb) returns text language sql as $$
  select string_agg((l ->> 'line') || '=' || (l ->> 'cents'), ',') from jsonb_array_elements(j -> 'lines') l where (l ->> 'cents')::bigint <> 0 $$;
select test.eq('business: kickbacks before HST on the day received, repair costs paid by CarmaCars, the owner''s apart; the voided one left out',
  test.kr_lines(test.kr_read('kr_admin', 'business', null)), 'Body shop kickback=100000,Tow kickback=25000,Repair costs=40000,Repairs paid by the owner=30000');
select test.eq('business net', (test.kr_read('kr_fin', 'business', null) ->> 'net_cents')::bigint, 85000::bigint);
select test.eq('business by owner', (select string_agg((o ->> 'name') || ':' || (o ->> 'kickback_cents') || ':' || (o ->> 'repair_cents'), ',' order by o ->> 'name')
  from jsonb_array_elements(test.kr_read('kr_admin', 'business', null) -> 'by_owner') o), 'Kr Olga:125000:40000,Kr Omar:0:0');
select test.eq('owner level: only that owner''s cars', test.kr_lines(test.kr_read('kr_fin', 'owner', test.id('owner:kr_omar'))), 'Repairs paid by the owner=30000');
select test.eq('car level, by Fleet', test.kr_lines(test.kr_read('kr_fleet', 'vehicle', test.id('vehicle:KRA'))), 'Body shop kickback=100000,Repair costs=40000');
select test.eq('the period filters by the day received', test.kr_lines(app.door(test.id('kr_admin'), 'aal2', 'ops_read', 'profit_extras',
  jsonb_build_object('level', 'business', 'from', app.today() - 100, 'to', app.today() - 40))), null::text);
select test.throws('Fleet does not read the business level', format($$select test.kr_read('kr_fleet', 'business', null)$$), 'Not permitted');
select test.throws('Sales read nothing', format($$select test.kr_read('kr_sales', 'vehicle', %L)$$, test.id('vehicle:KRA')), 'Not permitted');

-- ================================================================ the owner's view: off by default, own cars only
select test.eq('off by default: the owner sees nothing', (app.door(test.id('kr_olga'), 'aal2', 'ops_read', 'profit_extras_mine', '{}') ->> 'visible'), 'false');
select test.throws('an owner cannot turn it on', format($$select app.door(%L, 'aal2', 'ops_do', 'owner_profit_extras_visibility', %L)$$, test.id('kr_olga'),
  jsonb_build_object('owner', test.id('owner:kr_olga'), 'on', true)), 'Finance or an Admin');
select test.throws('an owner cannot read the staff view', format($$select test.kr_read('kr_olga', 'owner', %L)$$, test.id('owner:kr_olga')), 'Not permitted');
select app.door(test.id('kr_fin'), 'aal2', 'ops_do', 'owner_profit_extras_visibility', jsonb_build_object('owner', test.id('owner:kr_olga'), 'on', true));
create temp table kr_mine as select app.door(test.id('kr_olga'), 'aal2', 'ops_read', 'profit_extras_mine', jsonb_build_object('from', app.today() - 30, 'to', app.today())) j;
select test.eq('on: the owner sees their own cars'' lines', (select test.kr_lines(j) from kr_mine), 'Body shop kickback=100000,Tow kickback=25000,Repair costs=40000');
select test.ok('never another owner''s car, the partner who paid, an invoice or a receipt (the repair shop is shown: it is the owner''s repair)',
  (select not (j::text ~* 'KRC|KR Towing|invoice|receipt|by_owner|partner') from kr_mine));
select test.eq('the other owner still sees nothing', (app.door(test.id('kr_omar'), 'aal2', 'ops_read', 'profit_extras_mine', '{}') ->> 'visible'), 'false');
select test.ok('signed-in users reach it only through the admin policy (no other policy)', (select count(*) = 1 from pg_policies where tablename = 'vehicle_repair_costs'));
