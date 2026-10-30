-- 99: the charges CarmaCars bills an insurer (migration 0191, docs/changes/2026-10-27-insurer-extra-fees.md): VLF, LDW,
-- T&LDW, PAP/PEC and Waiver Saver. A rate a day typed on each insurer booking (no default price), the line rate x days
-- with HST; insurer bookings only (refused for a renter's, in words, wherever it comes from); Add a rental's check and
-- the rental itself; changed from the booking (the door) and the review screen; the insurer pays them (billed wholly or
-- for the rental only) and its invoice lists each one.
-- Fixtures start with "xf".
select test.suite('99 insurer extra fees');

select test.mk_user('xf_admin', 'admin');
select test.mk_user('xf_cs', 'va', 'cs');
create table test.xf (k text primary key, v jsonb);
grant select on test.xf to authenticated, service_role;
create function test.xfv(p text) returns jsonb language sql stable as $$ select v from test.xf where k = p $$;
insert into insurers (name, billing_email) values ('Xf Example Mutual', 'claims.xf@example.test');
create function test.xfins() returns uuid language sql stable as $$ select id from insurers where name = 'Xf Example Mutual' $$;
insert into test.xf select 'car', app.vehicle_add(test.id('xf_admin'), jsonb_build_object('supply_type', 'company', 'vin', '3VWCX7BU0RM000180',
  'plate', 'XFJ179', 'year', 2024, 'make', 'Volkswagen', 'model', 'Jetta', 'rates', jsonb_build_object('daily', 10000, 'weekend', 10000, 'weekly', 70000, 'monthly', 300000, 'deposit', 30000)));
create function test.xfcar() returns uuid language sql stable as $$ select (test.xfv('car') ->> 'vehicle_id')::uuid $$;
-- Add a rental, 3 days, an insurance replacement unless p says otherwise
create function test.xfmr(p jsonb, p_start integer default 2) returns jsonb language sql stable as $$
  select jsonb_build_object('vehicle_id', test.xfcar(), 'pickup_at', date_trunc('hour', now()) + make_interval(days => p_start), 'return_at', date_trunc('hour', now()) + make_interval(days => p_start + 3),
    'coverage_option', 1, 'source', 'insurer', 'sales_choice', 'for_carmacars', 'agreement', 'paper', 'blocks_calendar', false, 'blocks_calendar_reason', 'Insurance replacement test',
    'renter', jsonb_build_object('full_name', 'Xavi Feeson', 'email', 'xavi.feeson.' || md5(p::text) || '@example.test', 'mobile', '4165550180', 'date_of_birth', '1980-01-01', 'licence_number', 'X1234-12345-12345'),
    'payment', jsonb_build_object('mode', 'unpaid', 'method', 'insurer'), 'deposit', jsonb_build_object('method', 'cash')) || p $$;
create function test.xfb(p text) returns bookings language sql stable security definer as $$ select * from bookings where id = (test.xfv(p) ->> 'booking_id')::uuid $$;
create function test.xfline(p text, p_code text) returns booking_line_items language sql stable security definer as $$
  select * from booking_line_items where booking_id = (test.xfv(p) ->> 'booking_id')::uuid and charge_type = p_code and stage = 'booking' and voided_at is null $$;
create function test.xffees() returns jsonb language sql immutable as $$ select '{"vlf": 500, "ldw": 1500, "tldw": 0, "pap_pec": 700, "waiver_saver": 300}'::jsonb $$;

-- ================================================================ 1. the charges
select test.eq('five charges a day, company revenue, HST, priced at booking',
  (select string_agg(format('%s:%s:%s:%s:%s:%s', code, family, unit, revenue_class, hst_applies, stage), ' ' order by sort_order) from fee_types where code = any (app.insurer_fee_codes())),
  'vlf:fee:per_day:company_only:t:booking ldw:fee:per_day:company_only:t:booking tldw:fee:per_day:company_only:t:booking pap_pec:fee:per_day:company_only:t:booking waiver_saver:fee:per_day:company_only:t:booking');
select test.ok('no default price: typed on each booking', (select bool_and(amount_cents is null) and count(*) = 5 from fee_defaults where fee_type_code = any (app.insurer_fee_codes())));
select test.eq('the labels', (select label from fee_types where code = 'tldw'), 'T&LDW (theft and loss damage waiver)');

-- ================================================================ 2. Add a rental: the check and the rental
insert into test.xf select 'q', app.door(test.id('xf_cs'), 'aal2', 'ops_read', 'manual_rental_quote', test.xfmr(jsonb_build_object('insurer_fees', test.xffees(), 'bill_to_insurer', true)));
select test.eq('the check prices each charge typed (rate x 3 days); none for a rate of 0',
  (select string_agg(format('%s=%s', l ->> 'charge_type', l ->> 'amount_cents'), ' ' order by l ->> 'charge_type') from jsonb_array_elements(test.xfv('q') #> '{quote,lines}') l where l ->> 'charge_type' = any (app.insurer_fee_codes())),
  'ldw=4500 pap_pec=2100 vlf=1500 waiver_saver=900');
insert into test.xf select 'q0', app.door(test.id('xf_cs'), 'aal2', 'ops_read', 'manual_rental_quote', test.xfmr('{}'::jsonb));
select test.eq('the check: the total takes them with their HST', (test.xfv('q') #>> '{quote,total_due_at_booking_cents}')::bigint - (test.xfv('q0') #>> '{quote,total_due_at_booking_cents}')::bigint,
  9000 + public.calc_hst(1500, (app.settings()).hst_bps) + public.calc_hst(4500, (app.settings()).hst_bps) + public.calc_hst(2100, (app.settings()).hst_bps) + public.calc_hst(900, (app.settings()).hst_bps));
select test.throws('the check of a rental paid by the renter refuses them', $$ select app.door(test.id('xf_cs'), 'aal2', 'ops_read', 'manual_rental_quote',
  test.xfmr(jsonb_build_object('insurer_fees', jsonb_build_object('vlf', 500)))) $$, '%charged to an insurer only%');
select test.throws('a charge that is not one of them', $$ select app.door(test.id('xf_cs'), 'aal2', 'ops_read', 'manual_rental_quote',
  test.xfmr(jsonb_build_object('insurer_fees', jsonb_build_object('delivery', 500), 'bill_to_insurer', true))) $$, '%Not a charge to the insurer%');

insert into test.xf select 'b1', app.door(test.id('xf_admin'), 'aal2', 'ops_do', 'manual_rental_create', test.xfmr(jsonb_build_object('insurer_fees', test.xffees(),
  'insurance', jsonb_build_object('insurer_id', test.xfins(), 'claim_number', 'XF-1', 'authorized_daily_rate_cents', 9000, 'pays', 'insurer', 'dates_provisional', true))));
select test.eq('the rental bills the insurer', ((test.xfb('b1')).bill_to, (test.xfb('b1')).insurer_id = test.xfins())::text, '(insurer,t)');
select test.eq('the rates a day are kept', (select string_agg(format('%s=%s', fee_type_code, rate_cents), ' ' order by fee_type_code) from booking_insurer_fees where booking_id = (test.xfb('b1')).id),
  'ldw=1500 pap_pec=700 vlf=500 waiver_saver=300');
select test.eq('VLF: 3 days at $5.00 = $15.00, with HST', ((test.xfline('b1', 'vlf')).quantity, (test.xfline('b1', 'vlf')).unit_amount_cents, (test.xfline('b1', 'vlf')).amount_cents,
  (test.xfline('b1', 'vlf')).hst_cents = public.calc_hst(1500, (test.xfb('b1')).hst_bps))::text, '(3.000,500,1500,t)');
select test.eq('its words carry the days and the rate', (test.xfline('b1', 'vlf')).description, 'VLF (vehicle licence fee): 3 days at $5.00 a day');
select test.eq('no line for a rate of 0', (test.xfline('b1', 'tldw')).id, null::uuid);
select test.eq('the booking''s total holds every line', (test.xfb('b1')).subtotal_at_booking_cents,
  (select sum(amount_cents) from booking_line_items where booking_id = (test.xfb('b1')).id and stage = 'booking' and voided_at is null and charged_to_renter));
select test.eq('the insurer pays them (billed wholly: with the fees)', (select x.fees_share_cents >= 9000 from app.booking_insurer_share((test.xfb('b1')).id) x), true);
select test.eq('each one is recorded with who set it', (select count(*) from booking_fee_changes where booking_id = (test.xfb('b1')).id and line_key = any (app.insurer_fee_codes()) and changed_by = test.id('xf_admin')), 4::bigint);

select test.throws('a rental the renter pays: refused', $$ select app.door(test.id('xf_admin'), 'aal2', 'ops_do', 'manual_rental_create',
  test.xfmr(jsonb_build_object('insurer_fees', jsonb_build_object('vlf', 500), 'payment', jsonb_build_object('mode', 'other_way', 'method', 'cash')), 10)) $$, '%charged to an insurer only%');

-- ================================================================ 3. insurer bookings only, wherever it comes from
insert into test.xf select 'r1', app.door(test.id('xf_admin'), 'aal2', 'ops_do', 'manual_rental_create',
  test.xfmr(jsonb_build_object('payment', jsonb_build_object('mode', 'unpaid'), 'source', 'phone'), 10));
select test.eq('a renter''s booking', (test.xfb('r1')).bill_to, 'renter');
select test.throws('the door refuses them on a renter''s booking, naming it', format($$ select app.door(test.id('xf_cs'), 'aal2', 'ops_do', 'insurer_fees_set',
  jsonb_build_object('booking', %L, 'fees', jsonb_build_object('vlf', 500))) $$, (test.xfb('r1')).booking_number), '%booking ' || (test.xfb('r1')).booking_number || ' is paid by the renter%');
select test.throws('the table refuses a rate for it', format($$ insert into booking_insurer_fees (booking_id, fee_type_code, rate_cents) values (%L, 'ldw', 1000) $$, (test.xfb('r1')).id), '%charged to an insurer only%');
select test.throws('and a price line of them', format($$ insert into booking_line_items (booking_id, charge_type, quantity, unit_amount_cents, amount_cents, hst_applies, hst_cents, revenue_class, stage)
  values (%L, 'waiver_saver', 1, 500, 500, true, 65, 'company_only', 'booking') $$, (test.xfb('r1')).id), '%charged to an insurer only%');
select test.throws('a fee set by hand is never one of them (a rate a day)', format($$ select app.booking_fees_change(test.id('xf_admin'), jsonb_build_object('booking', %L, 'lines', jsonb_build_object('vlf', 1500))) $$,
  (test.xfb('b1')).booking_number), '%rate a day%');
select test.throws('the review screen refuses them on a renter''s booking', format($$ select app.admin_apply_booking_edit(test.id('xf_admin'), %L, jsonb_build_object('changes', '{}'::jsonb, 'insurer_fees', jsonb_build_object('pap_pec', 900))) $$,
  (test.xfb('r1')).id), '%charged to an insurer only%');
select test.throws('an insurer booking with them cannot go back to the renter', format($$ update bookings set bill_to = 'renter', insurer_id = null where id = %L $$, (test.xfb('b1')).id), '%remove them before%');
select test.eq('a rental the renter pays has none', (select count(*) from booking_line_items where booking_id = (test.xfb('r1')).id and charge_type = any (app.insurer_fee_codes())), 0::bigint);

-- ================================================================ 4. changed on the booking: the rate, the days, a charge removed
insert into test.xf select 'set', app.door(test.id('xf_cs'), 'aal2', 'ops_do', 'insurer_fees_set', jsonb_build_object('booking', (test.xfb('b1')).booking_number,
  'fees', jsonb_build_object('vlf', 600, 'ldw', null, 'tldw', 1000), 'reason', 'Adjuster''s authorization'));
select test.eq('VLF at $6.00: $18.00', (test.xfline('b1', 'vlf')).amount_cents, 1800::bigint);
select test.eq('LDW removed: its line is voided', (test.xfline('b1', 'ldw')).id, null::uuid);
select test.eq('T&LDW added', (test.xfline('b1', 'tldw')).amount_cents, 3000::bigint);
select test.eq('the screens'' list says each rate and amount', (select format('%s %s %s', x ->> 'rate_cents', x ->> 'days', x ->> 'amount_cents') from jsonb_array_elements(test.xfv('set') -> 'fees') x where x ->> 'code' = 'vlf'), '600 3 1800');
select test.ok('the booking''s history says it', exists (select 1 from booking_events where booking_id = (test.xfb('b1')).id and note like 'Charges to the insurer: VLF $15.00 to $18.00%Adjuster''s authorization%'));
select test.throws('a rate below zero', format($$ select app.door(test.id('xf_cs'), 'aal2', 'ops_do', 'insurer_fees_set', jsonb_build_object('booking', %L, 'fees', jsonb_build_object('vlf', -5))) $$,
  (test.xfb('b1')).booking_number), '%rate a day of VLF%');
-- the dates move: rate x the new days
select app.admin_apply_booking_edit(test.id('xf_admin'), (test.xfb('b1')).id, jsonb_build_object('changes', jsonb_build_object('return_at', (test.xfb('b1')).return_at + interval '1 day')));
select test.eq('a day more: 4 days at $6.00', ((test.xfline('b1', 'vlf')).amount_cents, (test.xfline('b1', 'vlf')).description)::text, '(2400,"VLF (vehicle licence fee): 4 days at $6.00 a day")');

-- the review screen (Save, Send offer, Edit offer, its preview): set, and removed in the same save that bills the renter
select app.admin_apply_booking_edit(test.id('xf_admin'), (test.xfb('b1')).id, jsonb_build_object('changes', '{}'::jsonb, 'insurer_fees', jsonb_build_object('ldw', 1200)));
select test.eq('the review screen sets a rate', (test.xfline('b1', 'ldw')).amount_cents, 4800::bigint);
-- an offer (Send an offer, then the review screen): billed to the insurer with its charges in one save, and back
insert into test.xf select 'o1', app.staff_offer_create(test.id('xf_admin'), jsonb_build_object('vehicle_id', test.xfcar(), 'pickup_at', date_trunc('hour', now()) + interval '40 days',
  'return_at', date_trunc('hour', now()) + interval '42 days', 'coverage_option', 1, 'draft', true, 'rental_pay_method', 'insurer', 'deposit_pay_method', 'cash',
  'renter', jsonb_build_object('full_name', 'Xena Offered', 'email', 'xena.offered@example.test', 'mobile', '4165550180', 'date_of_birth', '1981-02-02')));
insert into test.xf select 'pv1', app.admin_booking_preview(test.id('xf_admin'), (test.xfv('o1') ->> 'booking_id')::uuid,
  jsonb_build_object('changes', jsonb_build_object('bill_to', 'insurer', 'insurer_id', test.xfins()), 'insurer_fees', jsonb_build_object('vlf', 500, 'waiver_saver', 250)));
select test.eq('the review screen''s preview: billed to the insurer, its charges priced (2 days)', (test.xfv('pv1') ->> 'ok', test.xfv('pv1') #>> '{booking,bill_to}',
  (select string_agg(format('%s=%s', l ->> 'charge_type', l ->> 'amount_cents'), ' ' order by l ->> 'charge_type') from jsonb_array_elements(test.xfv('pv1') #> '{booking,lines}') l
    where l ->> 'charge_type' = any (app.insurer_fee_codes()) and (l ->> 'voided_at') is null))::text, '(true,insurer,"vlf=1000 waiver_saver=500")');
select test.eq('a preview changes nothing', (select count(*) from booking_insurer_fees where booking_id = (test.xfv('o1') ->> 'booking_id')::uuid), 0::bigint);
select app.admin_apply_booking_edit(test.id('xf_admin'), (test.xfv('o1') ->> 'booking_id')::uuid,
  jsonb_build_object('changes', jsonb_build_object('bill_to', 'insurer', 'insurer_id', test.xfins()), 'insurer_fees', jsonb_build_object('vlf', 500, 'waiver_saver', 250)));
select test.eq('saved', (select count(*) from booking_line_items where booking_id = (test.xfv('o1') ->> 'booking_id')::uuid and charge_type = any (app.insurer_fee_codes()) and voided_at is null), 2::bigint);
insert into test.xf select 'pv', app.admin_booking_preview(test.id('xf_admin'), (test.xfv('o1') ->> 'booking_id')::uuid,
  jsonb_build_object('changes', jsonb_build_object('bill_to', 'renter', 'insurer_id', null), 'insurer_fees', (select jsonb_object_agg(c, null) from unnest(app.insurer_fee_codes()) c)));
select test.eq('back to the renter, its charges removed in the same save', (test.xfv('pv') ->> 'ok', test.xfv('pv') #>> '{booking,bill_to}', test.xfv('pv') ->> 'error')::text, '(true,renter,)');
select test.eq('no charge in its price',
  (select count(*) from jsonb_array_elements(test.xfv('pv') #> '{booking,lines}') l where l ->> 'charge_type' = any (app.insurer_fee_codes()) and (l ->> 'voided_at') is null), 0::bigint);
select test.throws('back to the renter with them kept: refused', format($$ select app.admin_apply_booking_edit(test.id('xf_admin'), %L, jsonb_build_object('changes', jsonb_build_object('bill_to', 'renter', 'insurer_id', null))) $$,
  test.xfv('o1') ->> 'booking_id'), '%has charges to the insurer%remove them before%');
select test.eq('the booking read gives the rates a day', (app.admin_booking_json((test.xfb('b1')).id) -> 'insurer_fees' ->> 'ldw')::bigint, 1200::bigint);

-- ================================================================ 5. the insurer's invoice lists each one
update bookings set status = 'confirmed' where id = (test.xfb('b1')).id and status not in ('confirmed', 'on_rent');
insert into test.xf select 'inv', to_jsonb(app.draft_insurer_invoice((test.xfb('b1')).id, test.id('xf_admin')));
create function test.xfinv() returns insurer_invoices language sql stable security definer as $$ select * from insurer_invoices where id = (test.xfv('inv') #>> '{}')::uuid $$;
select test.ok('a line for VLF with its days and rate', exists (select 1 from jsonb_array_elements((test.xfinv()).lines) l where l ->> 'description' = 'VLF (vehicle licence fee): 4 days at $6.00 a day' and (l ->> 'amount_cents')::bigint = 2400));
select test.eq('a line for each charge on the booking', (select count(*) from jsonb_array_elements((test.xfinv()).lines) l where l ->> 'description' ~ '^(VLF|LDW|T&LDW|PAP/PEC|Waiver Saver)'), 5::bigint);
select test.eq('the lines add up to the invoice', (select sum((l ->> 'amount_cents')::bigint) from jsonb_array_elements((test.xfinv()).lines) l), (test.xfinv()).amount_cents);
select test.eq('the invoice is the insurer''s share', (test.xfinv()).amount_cents, (select x.share_cents from app.booking_insurer_share((test.xfb('b1')).id) x));
select test.ok('the card on the booking lists them', (select count(*) = 5 and bool_or(x ->> 'code' = 'vlf' and (x ->> 'rate_cents')::bigint = 600)
  from jsonb_array_elements(app.door(test.id('xf_admin'), 'aal2', 'admin_read', 'booking_insurer', jsonb_build_object('booking', (test.xfb('b1')).booking_number)) -> 'extra_fees') x));

-- the insurer pays the rental only (split): it still pays these, never the renter
insert into test.xf select 'b2', app.door(test.id('xf_admin'), 'aal2', 'ops_do', 'manual_rental_create', test.xfmr(jsonb_build_object('insurer_fees', jsonb_build_object('pap_pec', 1000),
  'insurance', jsonb_build_object('insurer_id', test.xfins(), 'claim_number', 'XF-2', 'authorized_daily_rate_cents', 9000, 'pays', 'split', 'dates_provisional', true)), 20));
select test.eq('split: the insurer''s fees are these charges (3 days at $10.00)', (select x.fees_share_cents from app.booking_insurer_share((test.xfb('b2')).id) x), 3000::bigint);
select test.eq('split: with their HST', (select x.hst_cents from app.booking_insurer_share((test.xfb('b2')).id) x) >= public.calc_hst(3000, (test.xfb('b2')).hst_bps), true);
select test.eq('split: the renter owes none of them', (test.xfb('b2')).renter_due_at_booking_cents,
  (test.xfb('b2')).total_due_at_booking_cents - (test.xfb('b2')).insurer_share_cents - (test.xfb('b2')).insurer_hst_cents);
update bookings set status = 'confirmed' where id = (test.xfb('b2')).id and status not in ('confirmed', 'on_rent');
insert into test.xf select 'inv2', to_jsonb(app.draft_insurer_invoice((test.xfb('b2')).id, test.id('xf_admin')));
select test.ok('split: the invoice lists PAP/PEC', exists (select 1 from jsonb_array_elements((select lines from insurer_invoices where id = (test.xfv('inv2') #>> '{}')::uuid)) l
  where l ->> 'description' like 'PAP/PEC%' and (l ->> 'amount_cents')::bigint = 3000));

-- ================================================================ 6. the table itself
select test.eq('row level security is on', (select relrowsecurity from pg_class where oid = 'public.booking_insurer_fees'::regclass), true);
select test.eq('a renter''s session cannot set them', has_function_privilege('authenticated', 'app.booking_insurer_fees_set(uuid,uuid,jsonb,text)', 'execute'), false);
