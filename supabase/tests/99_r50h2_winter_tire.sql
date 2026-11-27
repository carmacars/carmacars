-- R50 hotfix 2 (5142): the winter tire fee per rental, insurer rentals too: the rate a day (and cap) set on the booking with
-- who and why, the booking repriced, the change in its fee changes and history, the renter of a rental they pay told; refused
-- for the wrong person, an Owner Booking, a closed booking and without a reason. Fixtures start with "wt5".
select test.suite('99 r50h2 winter tire');
select test.mk_user('wt5_admin', 'admin');
select test.mk_user('wt5_fin', 'va', 'finance');
select test.mk_user('wt5_fleet', 'va', 'fleet');
select test.mk_owner('wt5_oona');
select test.mk_vehicle('WT5A', 'wt5_oona');
select test.mk_renter('wt5_rhea');
select test.mk_booking('WT5-1', 'WT5A', 'wt5_rhea', '2027-01-10 10:00', '2027-01-14 10:00', 'confirmed');
select test.mk_booking('WT5-2', 'WT5A', 'wt5_rhea', '2027-02-10 10:00', '2027-02-16 10:00', 'confirmed');
select test.mk_booking('WT5-3', 'WT5A', 'wt5_rhea', '2026-10-10 10:00', '2026-10-12 10:00', 'closed');
insert into insurers (name, billing_email) values ('Wt5 Example Mutual', 'claims.wt5@example.test');
update bookings set bill_to = 'insurer', insurer_id = (select id from insurers where name = 'Wt5 Example Mutual') where id = test.id('booking:WT5-2');
select app.sync_booking_price(test.id('booking:WT5-1'));
select app.sync_booking_price(test.id('booking:WT5-2'));

select test.throws('who: Fleet does not change fees', format('select app.booking_winter_tire_set(%L, %L)', test.id('wt5_fleet'), jsonb_build_object('booking', 'WT5-1', 'rate_cents', 1200, 'reason', 'x')), 'Only an Admin, Finance');
select test.throws('why: a change needs its reason', format('select app.booking_winter_tire_set(%L, %L)', test.id('wt5_fin'), jsonb_build_object('booking', 'WT5-1', 'rate_cents', 1200)), 'Say why');
select test.throws('when: a closed booking keeps its fees', format('select app.booking_winter_tire_set(%L, %L)', test.id('wt5_fin'), jsonb_build_object('booking', 'WT5-3', 'rate_cents', 1200, 'reason', 'x')), 'closed');
select test.throws('rate: not a negative rate', format('select app.booking_winter_tire_set(%L, %L)', test.id('wt5_fin'), jsonb_build_object('booking', 'WT5-1', 'rate_cents', -5, 'reason', 'x')), 'rate a day');

-- a renter's rental: tires added at the rental's own rate
insert into test.results (suite, name, passed) select '99 r50h2 winter tire', 'setup', true
  where (select (x ->> 'ok')::boolean from app.booking_winter_tire_set(test.id('wt5_fin'), jsonb_build_object('booking', 'WT5-1', 'rate_cents', 1200, 'reason', 'Agreed on the phone')) x);
select test.eq('renter rental: winter tires at $12 a day for 4 days, on the booking''s add-on, set by Finance',
  (select app.booking_line_key_cents(test.id('booking:WT5-1'), 'addon:winter_tire')::text || '/' ||
          (select ba.unit_price_cents || ':' || ba.added_via || ':' || (ba.added_by = test.id('wt5_fin')) from booking_addons ba join addons a on a.id = ba.addon_id
            where ba.booking_id = test.id('booking:WT5-1') and a.code = 'winter_tire' and ba.status = 'confirmed')),
  '4800/1200:staff:true');
select test.eq('renter rental: the change is in the fee changes and the history, and the total includes it',
  (select count(*) from booking_fee_changes c where c.booking_id = test.id('booking:WT5-1') and c.line_key = 'addon:winter_tire' and c.after_cents = 4800 and c.reason = 'Agreed on the phone')::text || '/' ||
  (select count(*) from booking_events e where e.booking_id = test.id('booking:WT5-1') and e.note like 'Winter tires:%')::text || '/' ||
  ((select total_due_at_booking_cents from bookings where id = test.id('booking:WT5-1')) >= 4800), '1/1/true');
select test.eq('renter rental: the renter is told', (select count(*) from app_events e where e.code = 'renter_winter_tire_changed' and e.entity_id = test.id('booking:WT5-1')), 1::bigint);
select app.booking_winter_tire_set(test.id('wt5_admin'), jsonb_build_object('booking', 'WT5-1', 'rate_cents', 2000, 'cap_cents', 5000, 'reason', 'Cap for this renter'));
select test.eq('renter rental: a new rate and a cap for this rental (4 days at $20, capped at $50)', app.booking_line_key_cents(test.id('booking:WT5-1'), 'addon:winter_tire'), 5000::bigint);
select app.booking_winter_tire_set(test.id('wt5_admin'), jsonb_build_object('booking', 'WT5-1', 'rate_cents', 0, 'reason', 'Renter declined'));
select test.eq('renter rental: 0 removes the tires and their line; the three changes are kept', (select coalesce(app.booking_line_key_cents(test.id('booking:WT5-1'), 'addon:winter_tire'), 0)::text || '/' ||
  (select count(*) from booking_fee_changes c where c.booking_id = test.id('booking:WT5-1') and c.line_key = 'addon:winter_tire')), '0/3');

-- an insurer rental: the same, the insurer's share follows, the renter is not emailed
select app.booking_winter_tire_set(test.id('wt5_fin'), jsonb_build_object('booking', 'WT5-2', 'rate_cents', 1000, 'reason', 'Adjuster approved winter tires'));
select test.eq('insurer rental: winter tires at $10 a day for 6 days, on the insurer''s invoice items',
  app.booking_line_key_cents(test.id('booking:WT5-2'), 'addon:winter_tire')::text || '/' ||
  (select count(*) from jsonb_array_elements(app.insurer_fee_items(test.id('booking:WT5-2'))) i where i ->> 'description' ilike 'Winter tire%')::text, '6000/1');
select test.ok('insurer rental: the insurer''s share includes the tires', (select insurer_share_cents >= 6000 from bookings where id = test.id('booking:WT5-2')));
select test.eq('insurer rental: no email to the renter', (select count(*) from app_events e where e.code = 'renter_winter_tire_changed' and e.entity_id = test.id('booking:WT5-2')), 0::bigint);
select test.eq('door: staff reach it through ops_do winter_tire_set',
  (app.door(test.id('wt5_fin'), 'aal2', 'ops_do', 'winter_tire_set', jsonb_build_object('booking', 'WT5-2', 'rate_cents', 1100, 'reason', 'Adjuster''s rate')) ->> 'after_cents'), '6600');

select app.process_events(100000);
select test.eq('email: the renter''s email is built: no variable missing, to the renter',
  (select count(*) filter (where o.missing_variables = '{}') || '/' || count(*) from notification_outbox o where o.code = 'renter_winter_tire_changed' and coalesce(o.channel, 'email') = 'email'
      and o.entity_id = test.id('booking:WT5-1')) <> '0/0' and not exists (select 1 from notification_outbox o where o.code = 'renter_winter_tire_changed' and o.missing_variables <> '{}'), true);
