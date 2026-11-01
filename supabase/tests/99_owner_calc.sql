-- 99: the earnings calculator's numbers (migration 0354): the classes with their starting rates, the class rules in the
-- order the database reads them, the fees empty until an Admin sets them, readable by anyone.
select test.suite('99 owner calculator');
select test.ok('the parts: classes, models, rules, fees, year', (select app.owner_calc_data() ?& array['classes', 'models', 'rules', 'fees', 'year']));
select test.eq('every class has its starting rate from Program settings',
  (select count(*) from jsonb_array_elements(app.owner_calc_data() -> 'classes') c
    where (c ->> 'card_cents') is distinct from ((app.settings()).listing_default_daily_rate_cents ->> (c ->> 'code'))), 0::bigint);
select test.eq('the rules: every active one, the exotic makes first', (select jsonb_array_length(app.owner_calc_data() -> 'rules')), (select count(*)::integer from vehicle_class_rules where is_active));
select test.eq('the fees: none made up while they are not set', app.owner_calc_data() -> 'fees', '{"insurance_cents": null, "tracker_cents": null}'::jsonb);
update program_settings set owner_calc_insurance_fee = 24900, owner_calc_tracker_fee = 2500;
select test.eq('the fees once set', app.owner_calc_data() -> 'fees', '{"insurance_cents": 24900, "tracker_cents": 2500}'::jsonb);
update program_settings set owner_calc_insurance_fee = null, owner_calc_tracker_fee = null;
select test.throws('a negative fee is refused', $$update program_settings set owner_calc_tracker_fee = -1$$, 'check');
set role anon;
select test.ok('anyone reads it (the page and the application)', (select public.owner_calc_data() ? 'classes'));
reset role;
