-- 99 r40 partner Sourced by (migration 2424): an in-person Sales person (an active staff member with the Sales function whom
-- app.user_is_sales_staff does not know) is listed, can be saved as Sourced by, and earns sourced_by_bps of a completed
-- referred rental. Fixtures start with "r40p".
select test.suite('99 r40 partner sourced by');
select test.mk_user('r40p_admin', 'admin');
select test.mk_user('r40p_inperson', 'va', 'sales');
select test.mk_user('r40p_cs', 'va', 'cs');
select test.mk_renter('r40p_rita');
-- in person, and still in onboarding: the Sales function, which the old check (the onboarding gate included) does not recognise
update staff_profiles set sales_work_mode = 'in_person', onboarding_exempt = false, onboarding_done = false where user_id = test.id('r40p_inperson');
select test.ok('setup: the old check does not know this person', not app.user_is_sales_staff(test.id('r40p_inperson')));

select test.ok('list: the Sourced by dropdown shows the in-person Sales person',
  exists (select 1 from jsonb_array_elements(app.referral_partners_read(test.id('r40p_admin'), '{}') -> 'settings' -> 'sales_staff') e where e ->> 0 = test.id('r40p_inperson')::text));
select test.throws('save: customer service is still refused', format('select app.referral_partner_save(%L, %L::jsonb)', test.id('r40p_admin'),
  jsonb_build_object('kind', 'insurer_rentals', 'business_name', 'R40p Broker', 'sourced_by', test.id('r40p_cs'), 'sourced_by_bps', 1000)), 'pick a Sales person');
select test.throws('save: someone who is not staff is still refused', format('select app.referral_partner_save(%L, %L::jsonb)', test.id('r40p_admin'),
  jsonb_build_object('kind', 'insurer_rentals', 'business_name', 'R40p Broker', 'sourced_by', test.id('renter:r40p_rita'), 'sourced_by_bps', 1000)), 'pick a Sales person');

create temp table r40p as select null::text as k, null::jsonb as v limit 0;
insert into r40p select 'car', app.vehicle_add(test.id('r40p_admin'), jsonb_build_object('supply_type', 'company', 'vin', '1R40PMM0000000001', 'plate', 'R40P01', 'year', 2024,
  'make', 'Kia', 'model', 'K5', 'rates', jsonb_build_object('daily', 10000, 'weekend', 10000, 'weekly', 70000, 'monthly', 300000, 'deposit', 30000)));
insert into r40p select 'p', app.door(test.id('r40p_admin'), 'aal2', 'admin_do', 'referral_partner_save', jsonb_build_object('kind', 'insurer_rentals', 'business_name', 'R40p Broker',
  'rate_kind', 'percent', 'rate_bps', 6000, 'sourced_by', test.id('r40p_inperson'), 'sourced_by_bps', 1000));
select test.eq('save: the in-person Sales person is saved as the sourcer',
  (select sourced_by::text || '/' || sourced_by_bps from referral_partners where id = ((select v from r40p where k = 'p') ->> 'id')::uuid), test.id('r40p_inperson')::text || '/1000');
insert into r40p select 'b', app.manual_rental_create(test.id('r40p_admin'), jsonb_build_object('vehicle_id', ((select v from r40p where k = 'car') ->> 'vehicle_id')::uuid,
  'pickup_at', app.local_midnight(app.today() - 10) + interval '10 hours', 'return_at', app.local_midnight(app.today() - 7) + interval '10 hours', 'source', 'phone',
  'coverage_option', 1, 'past', true, 'renter_id', test.id('renter:r40p_rita'), 'payment', jsonb_build_object('mode', 'other_way', 'method', 'cash'),
  'referral_code', (select referral_code from referral_partners where id = ((select v from r40p where k = 'p') ->> 'id')::uuid)));
create function pg_temp.r40pb() returns uuid language sql as $$ select coalesce((v ->> 'booking_id')::uuid, (v ->> 'id')::uuid) from r40p where k = 'b' $$;
select test.ok('commission: the in-person Sales person earns sourced_by_bps (10%) of the referred rental, on their commissions',
  (select c.amount_cents = round(e.base_cents * 0.1) and c.amount_cents > 0 and c.base_cents = e.base_cents
     from staff_commissions c join referral_partner_earnings e on e.booking_id = c.booking_id and e.kind = 'earning'
    where c.booking_id = pg_temp.r40pb() and c.kind = 'partner_sourced' and c.staff_id = test.id('r40p_inperson')));

-- ================================================================ B. View as (Field work) for a field person still in onboarding (2425)
select test.mk_user('r40p_field', 'field');
update staff_profiles set onboarding_exempt = false, onboarding_done = false where user_id = test.id('r40p_field');
select test.ok('B setup: the gate holds the field person out of their own field role', not app.is_field_person(test.id('r40p_field')));
select test.ok('B Portals lists them as field', exists (select 1 from jsonb_array_elements(app.admin_portal_people(test.id('r40p_admin'), 'r40p_field') -> 'people') x
  where x ->> 'id' = test.id('r40p_field')::text and (x -> 'portals' ->> 'field')::boolean));
select test.eq('B View as (Field work) starts', public.server_view_as_start(test.id('r40p_admin'), test.id('r40p_field'), 'field') ->> 'portal', 'field');
select test.ok('B and their own field role is still refused by the gate', not app.is_field_person(test.id('r40p_field')) and not app.user_is_field(test.id('r40p_field')));
