-- 99 r35: no HST on the owner Insurance Fee (0873). Fixtures start with "nh".
select test.suite('99 r35 no HST on insurance');
select test.eq('the default is no HST on insurance', (select column_default from test.shipped_defaults where column_name = 'insurance_fee_hst'), 'false');
update program_settings set insurance_fee_hst = false, trackers_available = false;

create table test.nh (k text primary key, v uuid);
insert into test.nh values ('o', test.mk_owner('nh_o'));
select test.mk_vehicle('NHO', 'nh_o', 'managed', 30000, 0, 3000) is not null as made;
insert into owner_invoices (id, owner_id, vehicle_id, kind, status, billing_date) values (test.id('nh_inv'), (select v from test.nh where k = 'o'), test.id('vehicle:NHO'), 'upfront', 'draft', date '2031-01-01');
insert into owner_invoice_lines (owner_invoice_id, kind, description, amount_cents, hst_applies, hst_cents)
values (test.id('nh_inv'), 'first_month_insurance', 'First month', 30000, true, 3900),
       (test.id('nh_inv'), 'last_month_insurance', 'Last month', 30000, true, 3900),
       (test.id('nh_inv'), 'install_fee', 'Install', 10000, true, 1300);
select test.eq('insurance lines carry no HST; the install fee keeps its HST', (select hst_cents from owner_invoices where id = test.id('nh_inv')), 1300::bigint);
select test.eq('the total is the fees plus HST on the install only', (select total_cents from owner_invoices where id = test.id('nh_inv')), 71300::bigint);
select test.ok('insurance lines are saved as not taxable', not (select bool_or(hst_applies) from owner_invoice_lines where owner_invoice_id = test.id('nh_inv') and kind like '%insurance%'));

-- registration and lines typed by hand as the Insurance Fee or plates carry no HST either; other custom lines keep it
insert into owner_invoices (id, owner_id, vehicle_id, kind, status, billing_date) values (test.id('nh_inv3'), (select v from test.nh where k = 'o'), test.id('vehicle:NHO'), 'custom', 'draft', date '2031-01-01');
insert into owner_invoice_lines (owner_invoice_id, kind, description, amount_cents, hst_applies, hst_cents)
values (test.id('nh_inv3'), 'custom', 'Insurance Fee, half of November 2026', 14200, true, 1846),
       (test.id('nh_inv3'), 'registration_fee', 'One-off registration fees', 29300, true, 3809),
       (test.id('nh_inv3'), 'custom', 'Plates (registration)', 5900, true, 767),
       (test.id('nh_inv3'), 'custom', 'Detailing', 10000, true, 1300);
select test.eq('Insurance Fee, registration and plates typed by hand carry no HST; detailing keeps it', (select hst_cents from owner_invoices where id = test.id('nh_inv3')), 1300::bigint);
select test.eq('the total is 142 + 293 + 59 + 100 + 13 HST', (select total_cents from owner_invoices where id = test.id('nh_inv3')), 60700::bigint);
select test.ok('the no-HST rule by kind', app.owner_line_no_hst('first_month_insurance', null) and not app.owner_line_no_hst('tracker_fee', 'Tracker'));

-- with the setting on, HST applies again (an Admin's choice)
update program_settings set insurance_fee_hst = true;
insert into owner_invoices (id, owner_id, vehicle_id, kind, status, billing_date, period_month) values (test.id('nh_inv2'), (select v from test.nh where k = 'o'), test.id('vehicle:NHO'), 'monthly', 'draft', date '2031-01-01', date '2031-01-01');
insert into owner_invoice_lines (owner_invoice_id, kind, description, amount_cents, hst_applies, hst_cents)
values (test.id('nh_inv2'), 'insurance_fee', 'Insurance', 30000, true, 3900);
select test.eq('with insurance_fee_hst on, the Insurance Fee carries HST', (select hst_cents from owner_invoices where id = test.id('nh_inv2')), 3900::bigint);
select test.ok('the list of invoices charged HST on insurance shows it', exists (select 1 from app.insurance_hst_charged() where owner_invoice_id = test.id('nh_inv2')));
update program_settings set insurance_fee_hst = true;

-- the one-time corrections (0873, 0874) on invoices made and paid outside the platform with HST, as they were entered:
-- first and last at 284 each with HST, and a half month at 142 with HST beside 293 of registration
update program_settings set insurance_fee_hst = true;
select test.mk_user('nh_admin', 'admin');
select test.mk_owner('nh_k');
select test.mk_vehicle('NHK', 'nh_k', 'managed', 28400, 0, 3000) is not null as made;
select app.owner_invoice_draft_save(test.id('nh_admin'), jsonb_build_object('vehicle_id', test.id('vehicle:NHK'), 'kind', 'upfront', 'title', 'NH first and last',
  'lines', '[{"kind": "first_month_insurance", "description": "First month''s Insurance Fee", "quantity": 1, "unit_amount_cents": 28400, "hst": true},
             {"kind": "last_month_insurance", "description": "Last month''s Insurance Fee", "quantity": 1, "unit_amount_cents": 28400, "hst": true}]'::jsonb)) is not null as made;
select app.owner_invoice_draft_save(test.id('nh_admin'), jsonb_build_object('vehicle_id', test.id('vehicle:NHK'), 'kind', 'custom', 'title', 'NH half and plates',
  'lines', '[{"kind": "insurance_fee", "description": "Insurance Fee, half of November 2026", "quantity": 1, "unit_amount_cents": 14200, "hst": true},
             {"kind": "registration_fee", "description": "One-off registration fees", "quantity": 1, "unit_amount_cents": 29300, "hst": false}]'::jsonb)) is not null as made;
create table test.nh_i as select title, id from owner_invoices where title in ('NH first and last', 'NH half and plates');
select app.owner_invoice_issue(test.id('nh_admin'), jsonb_build_object('id', id, 'quiet', true)) is not null from test.nh_i;
select app.record_manual_payment(test.id('nh_admin'), jsonb_build_object('invoice', id::text, 'method', 'e_transfer', 'reference', 'NH-REF', 'receipt', false, 'received_on', app.today())) is not null from test.nh_i;
select test.eq('as entered: 641.84 and 453.46, both paid',
  (select string_agg(i.total_cents || '/' || i.paid_cents || '/' || i.status, ' ' order by t.title) from test.nh_i t join owner_invoices i on i.id = t.id),
  '64184/64184/paid 45346/45346/paid');

update program_settings set insurance_fee_hst = false;
select test.ok('0873: both invoices corrected', app.r35_remove_owner_hst(test.id('owner:nh_k')) >= 2);
select test.eq('0873: no HST; each payment is what was paid (568 and 435), still paid',
  (select string_agg(i.total_cents || '/' || i.paid_cents || '/' || i.status || '/' || i.hst_cents, ' ' order by t.title) from test.nh_i t join owner_invoices i on i.id = t.id),
  '56800/56800/paid/0 43500/43500/paid/0');
select test.eq('0873: the hand-recorded payments match',
  (select string_agg(mp.amount_cents::text, ' ' order by t.title) from test.nh_i t join manual_payments mp on mp.owner_invoice_id = t.id), '56800 43500');
select test.eq('0873: the prepaid months carry no HST', (select coalesce(sum(hst_cents), 0) from vehicle_prepaids where vehicle_id = test.id('vehicle:NHK')), 0::numeric);

select test.ok('0874: the half month is moved', app.r35_last_month_one_and_half(test.id('owner:nh_k')) >= 1);
select test.eq('0874: first month 284, last month 1.5 months (426); the other invoice is the registration only; both paid',
  (select string_agg(i.total_cents || '/' || i.paid_cents || '/' || i.status, ' ' order by t.title) from test.nh_i t join owner_invoices i on i.id = t.id),
  '71000/71000/paid 29300/29300/paid');
select test.eq('0874: the last month line is 1.5 months',
  (select quantity || '/' || amount_cents from owner_invoice_lines where owner_invoice_id = (select id from test.nh_i where title = 'NH first and last') and kind = 'last_month_insurance'),
  '1.50/42600');
select test.eq('0874: the prepaid last month is 426', (select amount_cents from vehicle_prepaids where vehicle_id = test.id('vehicle:NHK') and kind = 'last_month_insurance'), 42600::bigint);
select test.eq('0874: the owner paid the same in all (710 + 293)',
  (select sum(mp.amount_cents) from test.nh_i t join manual_payments mp on mp.owner_invoice_id = t.id and mp.voided_at is null), 100300::numeric);
select test.eq('0874: running it again changes nothing', app.r35_last_month_one_and_half(test.id('owner:nh_k')), 0);
select test.throws('issued invoices are still never edited after the correction',
  $$update owner_invoice_lines set description = 'x' where owner_invoice_id = (select id from test.nh_i where title = 'NH first and last')$$, '%lines cannot change%');
update program_settings set insurance_fee_hst = true;
