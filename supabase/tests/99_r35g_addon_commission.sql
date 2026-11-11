-- r35 gaps, item 2 (owner, 1011 and 3811): the add-ons "phone charger" and "full tank (prepaid fuel)" exist with Program-settings
-- prices; commissions and kickbacks are collected on the daily rate minus discounts only. The one extra the owner chose later
-- (November 9: "sales people should get the same commission rates on the add-ons too") is the staff commission on add-ons,
-- prepaid fuel aside (1109). Delivery, extra km, the young driver fee, the Protection Plan and every other fee are never in
-- a commission or kickback base. Fixtures start with "g2".
select test.suite('99 r35g add-ons and the commission base');
grant usage on schema test to service_role;
grant execute on all functions in schema test to authenticated, anon, service_role;

select test.eq('add-ons: phone charger and full tank (prepaid fuel) exist, active, priced from the catalogue',
  (select string_agg(code || ':' || price_cents || ':' || prepaid_fuel || ':' || active, ' ' order by code) from addons where code in ('phone_charger', 'full_tank')),
  'full_tank:8500:true:true phone_charger:500:false:true');
select test.ok('add-ons: both have a charge type in the fee catalogue', (select count(*) = 2 from addons a join fee_types f on f.code = a.fee_type_code where a.code in ('phone_charger', 'full_tank')));

select test.mk_owner('g2_olga');
select test.mk_vehicle('G2V', 'g2_olga');
select test.mk_renter('g2_ren', false);
-- 5 days at 40000, a Non-refundable booking: 10% off (4000), so the daily rate minus discounts is 36000
select test.mk_booking('G2B', 'G2V', 'g2_ren', '2026-10-02 10:00', '2026-10-07 10:00', 'closed', 40000, 'non_refundable');
select test.mk_line('G2B', 'delivery', 7500);
select test.mk_line('G2B', 'young_driver_21_25', 7000);
select test.mk_line('G2B', 'coverage_sold', 9900);
select test.mk_line('G2B', 'mileage_overage', 3000);
-- two add-ons: flowers ($150) and the prepaid full tank ($85)
insert into booking_addons (booking_id, addon_id, name, fee_type_code, quantity, pricing_unit, unit_price_cents, hst_applies, status, added_via, line_item_id)
select test.id('booking:G2B'), a.id, a.name, a.fee_type_code, 1, a.pricing_unit, a.price_cents, a.hst_applies, 'confirmed', 'staff',
       test.mk_line('G2B', a.fee_type_code, a.price_cents)
  from addons a where a.code in ('flowers', 'full_tank');
select app.compute_booking_split(test.id('booking:G2B'));

select test.eq('staff commission base: the daily rate minus discounts, plus the flowers (the owner''s November 9 choice); no delivery, extra km, young driver, Protection Plan or prepaid fuel',
  app.commission_base_cents(test.id('booking:G2B')), 36000 + 15000::bigint);
select test.eq('the pre-add-on base is the daily rate minus discounts only', app.commission_base_cents_pre1109(test.id('booking:G2B')), 36000::bigint);
select test.eq('the add-on part is the flowers alone (prepaid fuel is a pass-through)', app.commission_addon_cents(test.id('booking:G2B')), 15000::bigint);
select test.ok('kickback: worked out on the rental charge only (no add-on, delivery, extra km or fee in it)',
  (select s.kickback_base_cents <= 36000 and s.kickback_cents <= public.calc_bps(36000, (app.settings()).kickback_bps) from booking_splits s where s.booking_id = test.id('booking:G2B')));
select test.eq('owner revenue: the rental and the extra km; no add-on, delivery or fee',
  (select s.owner_revenue_cents + s.kickback_cents from booking_splits s where s.booking_id = test.id('booking:G2B')), 36000 + 3000::bigint);
