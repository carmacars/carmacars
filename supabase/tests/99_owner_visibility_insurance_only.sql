-- 99: migration 0791: only an insurance replacement can be hidden from the car's owner. Fixtures start with "ovi".
select test.suite('99 owner visibility insurance only (0791)');

create temp table ovi_prev as select owner_revenue_visibility as v, owner_hide_insurance_only as io from app.settings();
update program_settings set owner_revenue_visibility = 'statement', owner_hide_insurance_only = true where id = (select id from app.settings());

select test.mk_user('ovi_admin', 'admin');
select test.mk_owner('ovi_own');
select test.mk_renter('ovi_r');
select test.mk_vehicle('OVI1', 'ovi_own');
insert into insurers (id, name) values (test.id('insurer:ovi'), 'Ovi Example Insurance');

select test.mk_booking('OVI-1', 'OVI1', 'ovi_r', '2031-05-02 10:00', '2031-05-05 10:00', 'confirmed', 30000);
select test.eq('a new booking billed to the renter is shown, whatever the Program setting',
  (select owner_visibility from bookings where id = test.id('booking:OVI-1')), 'shown');
select test.throws('staff cannot hide a booking billed to the renter',
  $$select app.door(test.id('ovi_admin'), 'aal2', 'ops_do', 'booking_owner_visibility_set', jsonb_build_object('booking', 'OVI-1', 'visibility', 'until_statement', 'reason', 'x'))$$,
  'Only an insurance replacement can be hidden');

select test.mk_booking('OVI-2', 'OVI1', 'ovi_r', '2031-06-02 10:00', '2031-06-05 10:00', 'confirmed', 30000);
update bookings set bill_to = 'insurer', insurer_id = test.id('insurer:ovi'), owner_visibility = 'shown' where id = test.id('booking:OVI-2');
select test.lives('an insurance replacement can still be hidden until the statement',
  $$select app.door(test.id('ovi_admin'), 'aal2', 'ops_do', 'booking_owner_visibility_set', jsonb_build_object('booking', 'OVI-2', 'visibility', 'until_statement', 'reason', 'Claim'))$$);
select test.eq('it is hidden', (select owner_visibility from bookings where id = test.id('booking:OVI-2')), 'until_statement');

update program_settings set owner_hide_insurance_only = false where id = (select id from app.settings());
select test.mk_booking('OVI-3', 'OVI1', 'ovi_r', '2031-07-02 10:00', '2031-07-05 10:00', 'confirmed', 30000);
select test.eq('rule off: the Program setting decides again', (select owner_visibility from bookings where id = test.id('booking:OVI-3')), 'until_statement');

update program_settings set owner_revenue_visibility = (select v from ovi_prev), owner_hide_insurance_only = (select io from ovi_prev) where id = (select id from app.settings());

-- 0791: the hire's commission text reads whole percentages
select test.eq('commission text: 10%, 15% and 20%', app.hire_standard_pay('sales_in_person') ->> 'text' like '%tiers: 10%, 15% and 20% of%', true);
select test.eq('a fraction keeps its digits', app.pct_text(12.5), '12.5');
