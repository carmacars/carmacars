-- 99: the weekend rate is always above the daily rate (migration 0271). Fixtures start with "wad".
select test.suite('99 weekend above daily');
select test.mk_owner('wad_owner');
select test.mk_vehicle('wad_car', 'wad_owner');
update rate_cards set daily_rate_cents = 10000, weekend_rate_cents = 9000 where vehicle_id = test.id('vehicle:wad_car') and effective_to is null;
select test.eq('a weekend rate at or below daily is raised to daily + 15%, to the dollar',
  (select weekend_rate_cents from rate_cards where vehicle_id = test.id('vehicle:wad_car') and effective_to is null), 11500::bigint);
update rate_cards set weekend_rate_cents = 14000 where vehicle_id = test.id('vehicle:wad_car') and effective_to is null;
select test.eq('a weekend rate already higher is kept', (select weekend_rate_cents from rate_cards where vehicle_id = test.id('vehicle:wad_car') and effective_to is null), 14000::bigint);
select test.eq('no current card breaks the rule', (select count(*) from rate_cards where effective_to is null and weekend_rate_cents <= daily_rate_cents), 0::bigint);
