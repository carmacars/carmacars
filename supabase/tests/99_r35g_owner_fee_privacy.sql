-- r35 gaps, item 1 (owner, 2624): an owner never sees the young driver fee or the Protection Plan, in any owner portal read.
select test.suite('99 r35g owner fee privacy');
grant usage on schema test to service_role;
grant execute on all functions in schema test to authenticated, anon, service_role;

select test.mk_owner('g1_olga');
select test.mk_vehicle('G1V', 'g1_olga');
select test.mk_renter('g1_ren', false);
select test.mk_booking('G1B', 'G1V', 'g1_ren', '2026-10-02 10:00', '2026-10-06 10:00', 'closed', 40000);
select test.mk_line('G1B', 'young_driver_21_25', 7000);
select test.mk_line('G1B', 'coverage_sold', 9900);
select test.mk_line('G1B', 'delivery', 7500);

-- the redactor on its own
select test.eq('redact: young driver and Protection Plan keys go, at any depth',
  app.owner_redact('{"a":1,"young_driver_cents":7000,"x":{"protection_plan_cents":9900,"rentalcover_price_cents":5,"keep":2}}'::jsonb),
  '{"a":1,"x":{"keep":2}}'::jsonb);
select test.eq('redact: a charge line of a hidden kind is dropped from a list, others stay',
  app.owner_redact('[{"charge_type":"young_driver_18_20","amount_cents":1},{"code":"coverage_sold"},{"fee_type_code":"delivery","amount_cents":3}]'::jsonb),
  '[{"fee_type_code":"delivery","amount_cents":3}]'::jsonb);
select test.eq('redact: scalars and null pass through', app.owner_redact('5'::jsonb)::text || coalesce(app.owner_redact(null)::text, '-'), '5-');

-- every owner read goes through it (enforced in the database, not the screens)
select test.ok('every owner_portal read redacts: ' || p.proname, pg_get_functiondef(p.oid) like '%app.owner_redact(%')
  from pg_proc p join pg_namespace n on n.oid = p.pronamespace
 where n.nspname = 'public' and p.proname in ('owner_portal_home', 'owner_portal_invoice', 'owner_portal_statement', 'owner_portal_bookings', 'owner_portal_month_to_date');

-- end to end: the owner's views of a booking that carried both charges
set role service_role;
select test.ok('bookings view: no young driver or Protection Plan',
  public.owner_portal_bookings(test.id('g1_olga'))::text !~* 'young|protection|coverage_sold|rentalcover');
select test.ok('bookings view: the rental itself is still there',
  jsonb_array_length(public.owner_portal_bookings(test.id('g1_olga'))) = 1);
select test.ok('month to date: no young driver or Protection Plan',
  coalesce(public.owner_portal_month_to_date(test.id('g1_olga'), date '2026-10-01')::text, '') !~* 'young|protection|coverage_sold|rentalcover');
select test.ok('home: no young driver or Protection Plan',
  coalesce(public.owner_portal_home(test.id('g1_olga'))::text, '') !~* 'young|protection|coverage_sold|rentalcover');
reset role;
select test.mk_user('g1_admin', 'admin');
select app.build_owner_statement(test.id('owner:g1_olga'), date '2026-10-01');
select app.approve_owner_statement((select id from owner_statements where owner_id = test.id('owner:g1_olga') limit 1), test.id('g1_admin'));
set role service_role;
select test.ok('statement: the approved statement is readable and has the rental',
  (select public.owner_portal_statement(test.id('g1_olga'), s.id)::text like '%G1B%' from owner_statements s where s.owner_id = test.id('owner:g1_olga') limit 1));
select test.ok('statement: no young driver or Protection Plan',
  (select public.owner_portal_statement(test.id('g1_olga'), s.id)::text !~* 'young|protection|coverage_sold|rentalcover'
     from owner_statements s where s.owner_id = test.id('owner:g1_olga') limit 1));
reset role;

-- the owner emails about that booking carry neither charge
select app.ntf_emit('owner_new_booking', 'booking', test.id('booking:G1B'), 'g1-mail', jsonb_build_object('booking_id', test.id('booking:G1B'), 'owner_id', test.id('owner:g1_olga')));
select test.ok('email: the owner booking payload has no young driver or Protection Plan',
  (select z.y::text !~* 'young|protection|coverage_sold|rentalcover' and z.y::text like '%G1B%'
     from app_events e, lateral (select app.notification_payload('owner_new_booking', e, jsonb_build_object('audience', 'owner', 'owner_id', test.id('owner:g1_olga'), 'user_id', test.id('g1_olga'))) y) z
    where e.code = 'owner_new_booking' and e.entity_id = test.id('booking:G1B') limit 1));
