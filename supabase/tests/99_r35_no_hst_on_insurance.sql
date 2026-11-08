-- 99 r35: no HST on the owner Insurance Fee (0873). Fixtures start with "nh".
select test.suite('99 r35 no HST on insurance');
select is((select column_default from information_schema.columns where table_name = 'program_settings' and column_name = 'insurance_fee_hst'), 'false', 'the default is no HST on insurance');
update program_settings set insurance_fee_hst = false, trackers_available = false;

create table test.nh (k text primary key, v uuid);
insert into test.nh values ('o', test.mk_owner('nh_o'));
insert into owner_invoices (id, owner_id, kind, status) values (test.id('nh_inv'), (select v from test.nh where k = 'o'), 'upfront', 'draft');
insert into owner_invoice_lines (owner_invoice_id, kind, description, amount_cents, hst_applies, hst_cents)
values (test.id('nh_inv'), 'first_month_insurance', 'First month', 30000, true, 3900),
       (test.id('nh_inv'), 'last_month_insurance', 'Last month', 30000, true, 3900),
       (test.id('nh_inv'), 'install_fee', 'Install', 10000, true, 1300);
select is((select hst_cents from owner_invoices where id = test.id('nh_inv')), 1300::bigint, 'insurance lines carry no HST; the install fee keeps its HST');
select is((select total_cents from owner_invoices where id = test.id('nh_inv')), 71300::bigint, 'the total is the fees plus HST on the install only');
select ok(not (select bool_or(hst_applies) from owner_invoice_lines where owner_invoice_id = test.id('nh_inv') and kind like '%insurance%'), 'insurance lines are saved as not taxable');

-- registration and lines typed by hand as the Insurance Fee or plates carry no HST either; other custom lines keep it
insert into owner_invoices (id, owner_id, kind, status) values (test.id('nh_inv3'), (select v from test.nh where k = 'o'), 'custom', 'draft');
insert into owner_invoice_lines (owner_invoice_id, kind, description, amount_cents, hst_applies, hst_cents)
values (test.id('nh_inv3'), 'custom', 'Insurance Fee, half of November 2026', 14200, true, 1846),
       (test.id('nh_inv3'), 'registration_fee', 'One-off registration fees', 29300, true, 3809),
       (test.id('nh_inv3'), 'custom', 'Plates (registration)', 5900, true, 767),
       (test.id('nh_inv3'), 'custom', 'Detailing', 10000, true, 1300);
select is((select hst_cents from owner_invoices where id = test.id('nh_inv3')), 1300::bigint, 'Insurance Fee, registration and plates typed by hand carry no HST; detailing keeps it');
select is((select total_cents from owner_invoices where id = test.id('nh_inv3')), 60700::bigint, 'the total is 142 + 293 + 59 + 100 + 13 HST');
select ok(app.owner_line_no_hst('first_month_insurance', null) and not app.owner_line_no_hst('tracker_fee', 'Tracker'), 'the no-HST rule by kind');

-- with the setting on, HST applies again (an Admin's choice)
update program_settings set insurance_fee_hst = true;
insert into owner_invoices (id, owner_id, kind, status) values (test.id('nh_inv2'), (select v from test.nh where k = 'o'), 'monthly', 'draft');
insert into owner_invoice_lines (owner_invoice_id, kind, description, amount_cents, hst_applies, hst_cents)
values (test.id('nh_inv2'), 'insurance_fee', 'Insurance', 30000, true, 3900);
select is((select hst_cents from owner_invoices where id = test.id('nh_inv2')), 3900::bigint, 'with insurance_fee_hst on, the Insurance Fee carries HST');
select ok(exists (select 1 from app.insurance_hst_charged() where owner_invoice_id = test.id('nh_inv2')), 'the list of invoices charged HST on insurance shows it');
update program_settings set insurance_fee_hst = true;
