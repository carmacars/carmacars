-- 99: owner price limits (migration 1205). An owner (every car, or one car) and an Admin set a daily minimum and maximum;
-- lead-time pricing, promo codes, staff discounts and prices typed by staff never take the rental a day outside them
-- unless an Admin allows it on the booking (logged). Empty is no limit. Fixtures start with "pl".
select test.suite('99 r35h price limits');

select test.mk_user('pl_admin', 'admin');
select test.mk_user('pl_cs', 'va', 'cs');
select test.mk_owner('pl_olga');
select test.mk_owner('pl_omar');
select test.mk_vehicle('pl_a', 'pl_olga');
select test.mk_vehicle('pl_b', 'pl_olga');
select test.mk_vehicle('pl_c', 'pl_omar');
select test.mk_renter('pl_rita');

-- the rental a day of a quote or a booking's lines: every rental line (rental charge, lead-time pricing, discounts, promo
-- code, the limit's own line) over the days
create or replace function test.pl_rental(p jsonb) returns bigint language sql immutable as $$
  select coalesce(sum((x ->> 'amount_cents')::bigint), 0) from jsonb_array_elements(coalesce(p -> 'lines', '[]'::jsonb)) x
   where x ->> 'charge_type' in ('rental_charge', 'lead_time', 'non_refundable_discount', 'staff_discount', 'promo_discount', 'price_limit') $$;
create or replace function test.pl_line(p jsonb) returns bigint language sql immutable as $$
  select (x ->> 'amount_cents')::bigint from jsonb_array_elements(coalesce(p -> 'lines', '[]'::jsonb)) x where x ->> 'charge_type' = 'price_limit' limit 1 $$;
create or replace function test.pl_bline(p_number text) returns bigint language sql stable as $$
  select sum(amount_cents)::bigint from booking_line_items where booking_id = test.id('booking:' || p_number) and charge_type = 'price_limit' and voided_at is null $$;
create or replace function test.pl_brental(p_number text) returns bigint language sql stable as $$
  select sum(amount_cents)::bigint from booking_line_items where booking_id = test.id('booking:' || p_number) and voided_at is null and stage = 'booking'
     and charge_type in ('rental_charge', 'lead_time', 'non_refundable_discount', 'staff_discount', 'promo_discount', 'price_limit') $$;

-- ================================================================ empty is no limit
select test.eq('PL no limits set: none in force, and a quote has no limit line',
  app.price_limits_for(test.id('vehicle:pl_a')) || jsonb_build_object('line', test.pl_line(app.price_quote(test.id('vehicle:pl_a'), test.base(2), test.base(2) + interval '2 days', '{}'))),
  '{"line": null, "max_from": null, "min_from": null, "max_daily_cents": null, "min_daily_cents": null}'::jsonb);

-- ================================================================ who sets them
select public.server_owner_price_limits_save(test.id('pl_olga'), '{"scope": "owner", "min_daily_cents": 9000, "max_daily_cents": 15000}');
select test.eq('PL the owner sets limits for every car: both cars follow, from the owner',
  (select string_agg((app.price_limits_for(v) ->> 'min_daily_cents') || '-' || (app.price_limits_for(v) ->> 'max_daily_cents') || ' ' || (app.price_limits_for(v) ->> 'min_from'), ', ')
     from unnest(array[test.id('vehicle:pl_a'), test.id('vehicle:pl_b')]) v), '9000-15000 owner, 9000-15000 owner');
select public.server_owner_price_limits_save(test.id('pl_olga'), jsonb_build_object('scope', 'car', 'vehicle_id', test.id('vehicle:pl_a'), 'min_daily_cents', 9500));
select test.eq('PL a car''s own minimum comes first, its empty maximum is the owner''s',
  app.price_limits_for(test.id('vehicle:pl_a')), '{"max_from": "owner", "min_from": "car", "max_daily_cents": 15000, "min_daily_cents": 9500}'::jsonb);
select test.eq('PL the owner portal reads both levels',
  (select (r #>> '{owner,min_daily_cents}') || '/' || jsonb_array_length(r -> 'cars') || '/' || (select c #>> '{car,min_daily_cents}' from jsonb_array_elements(r -> 'cars') c where c ->> 'vehicle_id' = test.id('vehicle:pl_a')::text)
     from (select public.server_owner_price_limits(test.id('pl_olga')) r) x), '9000/2/9500');
select test.throws('PL an owner never sets another owner''s car',
  format($$select public.server_owner_price_limits_save(%L, %L)$$, test.id('pl_omar'), jsonb_build_object('scope', 'car', 'vehicle_id', test.id('vehicle:pl_a'), 'min_daily_cents', 1000)), 'Only the car''s owner');
select public.server_owner_price_limits_save(test.id('pl_omar'), jsonb_build_object('scope', 'owner', 'owner_id', test.id('owner:pl_olga'), 'min_daily_cents', 100, 'max_daily_cents', 200));
select test.eq('PL an owner never sets another owner''s limits for every car: an owner_id passed is ignored and their own are set',
  (select string_agg(price_min_daily_cents::text, ',' order by legal_name) from owners where id in (test.id('owner:pl_olga'), test.id('owner:pl_omar'))), '9000,100');
select test.throws('PL a renter or staff member is not an owner', format($$select public.server_owner_price_limits_save(%L, '{"scope": "owner", "min_daily_cents": 100}')$$, test.id('pl_cs')), 'Not an owner');
select test.throws('PL a minimum above the maximum is refused', format($$select public.server_owner_price_limits_save(%L, '{"scope": "owner", "min_daily_cents": 20000, "max_daily_cents": 10000}')$$, test.id('pl_olga')), 'above the maximum');
select test.throws('PL a zero or negative limit is refused', format($$select public.server_owner_price_limits_save(%L, '{"scope": "owner", "min_daily_cents": 0}')$$, test.id('pl_olga')), 'above $0');
select test.throws('PL a car''s minimum above its owner''s maximum is refused',
  format($$select public.server_owner_price_limits_save(%L, %L)$$, test.id('pl_olga'), jsonb_build_object('scope', 'car', 'vehicle_id', test.id('vehicle:pl_b'), 'min_daily_cents', 16000)), 'above the maximum on this car');
select test.throws('PL an owner''s maximum below a car''s own minimum is refused, naming the car',
  format($$select public.server_owner_price_limits_save(%L, '{"scope": "owner", "min_daily_cents": 5000, "max_daily_cents": 9000}')$$, test.id('pl_olga')), 'change that car''s own limits first');
select test.throws('PL the table refuses a minimum above the maximum too', $$update vehicles set price_min_daily_cents = 500, price_max_daily_cents = 400 where id = test.id('vehicle:pl_c')$$, 'price_limits_order');
select test.eq('PL each change is in the audit log with who and before',
  (select count(*) || '/' || bool_and(actor_user_id = test.id('pl_olga')) || '/' || count(*) filter (where entity_table = 'vehicles' and (after ->> 'by') = 'owner')
     from audit_log where action = 'price_limits' and entity_id in (test.id('owner:pl_olga')::text, test.id('vehicle:pl_a')::text)), '2/true/1');

-- an Admin sets anyone's; staff read them on the car, only an Admin changes them
select app.door(test.id('pl_admin'), 'aal2', 'admin_do', 'price_limits', jsonb_build_object('scope', 'car', 'vehicle_id', test.id('vehicle:pl_c'), 'min_daily_cents', 8000, 'max_daily_cents', 11000));
select test.eq('PL an Admin sets a car''s limits (Omar''s car), logged as an Admin',
  app.price_limits_for(test.id('vehicle:pl_c')) || jsonb_build_object('by', (select after ->> 'by' from audit_log where action = 'price_limits' and entity_id = test.id('vehicle:pl_c')::text order by id desc limit 1)),
  '{"by": "admin", "max_from": "car", "min_from": "car", "max_daily_cents": 11000, "min_daily_cents": 8000}'::jsonb);
select app.door(test.id('pl_admin'), 'aal2', 'admin_do', 'price_limits', jsonb_build_object('scope', 'owner', 'owner_id', test.id('owner:pl_omar'), 'min_daily_cents', null, 'max_daily_cents', null));
select test.eq('PL an Admin clears an owner''s limits (empty is no limit)', (select coalesce(price_min_daily_cents::text, 'none') from owners where id = test.id('owner:pl_omar')), 'none');
select test.eq('PL staff read a car''s limits (own, owner''s, in force)',
  (select (r #>> '{car,min_daily_cents}') || '/' || (r #>> '{owner,max_daily_cents}') || '/' || (r #>> '{effective,max_daily_cents}')
     from (select app.door(test.id('pl_cs'), 'aal2', 'ops_read', 'price_limits', jsonb_build_object('vehicle_id', test.id('vehicle:pl_a'))) r) x), '9500/15000/15000');
select test.throws('PL staff never change them', format($$select app.door(%L, 'aal2', 'admin_do', 'price_limits', %L)$$, test.id('pl_cs'), jsonb_build_object('scope', 'car', 'vehicle_id', test.id('vehicle:pl_a'), 'min_daily_cents', 100)));
select test.throws('PL an owner does not read them through the staff door', format($$select app.price_limits_read(%L, %L)$$, test.id('pl_olga'), test.id('vehicle:pl_a')), 'Staff read');

-- ================================================================ the money: lead-time pricing (car A: $95 to $150 a day; daily $100, weekend $120)
update program_settings set lead_time_enabled = true;
select test.eq('PL booked ahead: 5% off a $100 day would be $95 a day, at the minimum: no line',
  test.pl_line(app.price_quote(test.id('vehicle:pl_a'), test.base(2) + interval '14 days', test.base(2) + interval '15 days', '{}')), null::bigint);
update vehicles set price_min_daily_cents = 9800 where id = test.id('vehicle:pl_a');
select test.eq('PL booked ahead below the minimum ($98): +$3 brings it back, a line of its own, taxed like the rental',
  (select test.pl_line(q) || '/' || test.pl_rental(q) || '/' || (select x ->> 'description' from jsonb_array_elements(q -> 'lines') x where x ->> 'charge_type' = 'price_limit')
          || '/' || (select (x ->> 'hst_cents') from jsonb_array_elements(q -> 'lines') x where x ->> 'charge_type' = 'price_limit')
     from (select app.price_quote(test.id('vehicle:pl_a'), test.base(2) + interval '14 days', test.base(2) + interval '15 days', '{}') q) x), '300/9800/Minimum daily rate for this car/39');
update vehicles set price_max_daily_cents = 11000 where id = test.id('vehicle:pl_a');
select test.eq('PL short notice above the maximum ($110 a day): the premium is cut back to the maximum, over 2 days',
  (select test.pl_rental(q) || '/' || (test.pl_line(q) < 0) from (select app.price_quote(test.id('vehicle:pl_a'), now() + interval '3 hours', now() + interval '2 days 3 hours', '{}') q) x), '22000/true');
select test.ok('PL the cars list adds the line to the rental for the dates (search_available)',
  pg_get_functiondef('app.search_available(timestamptz, timestamptz, jsonb)'::regprocedure) like '%price_limit_cents%');
update program_settings set lead_time_enabled = false;

-- a price typed by staff: held at the minimum too
select set_config('app.staff_pricing', 'on', false);
select test.eq('PL a price typed by staff below the minimum ($50 for one day) is brought back to $98',
  (select test.pl_rental(q) || '/' || test.pl_line(q) from (select app.price_quote(test.id('vehicle:pl_a'), test.base(2) + interval '14 days', test.base(2) + interval '15 days', '{"staff_rental_charge_cents": 5000}') q) x), '9800/4800');
select set_config('app.staff_pricing', '', false);

-- ================================================================ a request: promo code, owner booking, the Admin override
select test.mk_booking('PL-1', 'pl_a', 'pl_rita', '2029-11-06 10:00', '2029-11-08 10:00', 'requested');
select app.sync_booking_price(test.id('booking:PL-1'));
select test.eq('PL a request within the limits ($100 a day, Tuesday to Thursday): no line', test.pl_bline('PL-1'), null::bigint);
insert into promo_codes (id, code, percent_bps, once_per_renter) values (test.id('promo:pl50'), 'PLHALF', 5000, false);
select app.apply_promo_code(test.id('booking:PL-1'), 'PLHALF', test.id('pl_rita'));
select test.eq('PL a 50% promo code: the rental stays at the minimum ($98 x 2), the promo line kept and the limit line beside it',
  test.pl_brental('PL-1') || '/' || (select -sum(amount_cents) from booking_line_items where booking_id = test.id('booking:PL-1') and charge_type = 'promo_discount' and voided_at is null) || '/' || test.pl_bline('PL-1'),
  '19600/10000/9600');
select test.eq('PL the booking''s total follows its lines', (select total_due_at_booking_cents = (select sum(amount_cents + hst_cents) from booking_line_items l where l.booking_id = b.id and l.voided_at is null and l.stage = 'booking') from bookings b where b.id = test.id('booking:PL-1')), true);
select test.ok('PL the line counts with the rental charge (owner revenue, commissions)', 'price_limit' = any (app.commission_line_types()));

select test.throws('PL staff never allow a price outside the limits', format($$select app.door(%L, 'aal2', 'admin_do', 'booking_price_limit', %L)$$, test.id('pl_cs'), jsonb_build_object('booking_id', test.id('booking:PL-1'), 'on', true, 'reason', 'x')));
select test.throws('PL an Admin says why', format($$select app.booking_price_limit_override(%L, %L, true, '  ')$$, test.id('pl_admin'), test.id('booking:PL-1')), 'Say why');
select app.door(test.id('pl_admin'), 'aal2', 'admin_do', 'booking_price_limit', jsonb_build_object('booking_id', test.id('booking:PL-1'), 'on', true, 'reason', 'Returning customer, agreed with the owner'));
select test.eq('PL an Admin allows it: the limit line goes, the promo applies in full ($100 for 2 days), logged on the booking and in the audit log',
  coalesce(test.pl_bline('PL-1'), 0) || '/' || test.pl_brental('PL-1')
  || '/' || (select count(*) from booking_events where booking_id = test.id('booking:PL-1') and note like 'Price limits: an Admin allowed%Returning customer%')
  || '/' || (select count(*) from audit_log where action = 'booking_price_limit_override' and entity_id = test.id('booking:PL-1')::text and actor_user_id = test.id('pl_admin')),
  '0/10000/1/1');
select app.admin_apply_booking_edit(test.id('pl_admin'), test.id('booking:PL-1'), '{"price_limit_override": {"on": false}}');
select test.eq('PL off again (the review screen): the limits apply at once', test.pl_brental('PL-1') || '/' || (select price_limit_override from bookings where id = test.id('booking:PL-1')), '19600/false');
select test.mk_booking('PL-2', 'pl_a', 'pl_rita', '2029-12-04 10:00', '2029-12-06 10:00', 'confirmed');
select test.throws('PL a booking with its price settled keeps it', format($$select app.booking_price_limit_override(%L, %L, true, 'late')$$,
  test.id('pl_admin'), test.id('booking:PL-2')), 'its price is settled');

-- the spec of PL-1 (50% promo, under the minimum): never on an Owner Booking or a booking billed to an insurer
select test.eq('PL never on an Owner Booking or a booking billed to an insurer; on the same booking otherwise',
  coalesce(test.pl_line(app.price_lines(app.booking_price_spec(test.id('booking:PL-1')) || '{"booking_type": "owner"}')), 0)
  || '/' || coalesce(test.pl_line(app.price_lines(app.booking_price_spec(test.id('booking:PL-1')) || '{"insurer_billed": true}')), 0)
  || '/' || coalesce(test.pl_line(app.price_lines(app.booking_price_spec(test.id('booking:PL-1')))), 0), '0/0/9600');

select test.eq('PL privileges: the functions are the server''s only',
  (select string_agg(p.proname, ', ') from pg_proc p join pg_namespace n on n.oid = p.pronamespace
    where n.nspname in ('app', 'public') and p.proname in ('price_limits_for', 'price_limits_save', 'price_limits_read', 'owner_price_limits', 'booking_price_limit_override',
                                                           'server_owner_price_limits', 'server_owner_price_limits_save')
      and (has_function_privilege('anon', p.oid, 'execute') or has_function_privilege('authenticated', p.oid, 'execute'))), null::text);

