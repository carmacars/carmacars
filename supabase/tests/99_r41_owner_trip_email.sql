-- 99: migration 2620 (release 41): owners are not emailed when a booking comes in; they are emailed when a trip is complete and the
-- car is back (owner_trip_completed) and every Monday (owner_weekly_summary). Fixtures: "zo". Test data only (example.test).
select test.suite('99 r41 owner trip email and the Monday summary (2620)');
grant usage on schema test to service_role;
grant execute on all functions in schema test to authenticated, anon, service_role;

select test.mk_owner('zo_o');
select test.mk_vehicle('ZOA', 'zo_o');
select test.mk_owner('zo_idle');
select test.mk_vehicle('ZOI', 'zo_idle');
select test.mk_renter('zo_r');
create function test.zol(p_days integer, p_hour text default '10:00') returns text language sql stable as $$
  select to_char((now() at time zone 'America/Toronto')::date + p_days, 'YYYY-MM-DD') || ' ' || p_hour $$;
create function test.zob(p text) returns uuid language sql stable as $$ select test.id('booking:' || p) $$;
create function test.zoflush() returns void language plpgsql as $$
begin
  perform app.process_events(100000);
  perform app.process_events(100000);
end $$;

-- ================================================================ 1. the booking-time emails are off
select test.eq('catalogue: the three booking-time owner emails are off, the two new ones on',
  (select string_agg(code || '=' || is_enabled, ',' order by code) from notification_catalogue
    where code in ('owner_new_booking', 'owner_booking_confirmed', 'owner_booking_changed', 'owner_trip_completed', 'owner_weekly_summary')),
  'owner_booking_changed=false,owner_booking_confirmed=false,owner_new_booking=false,owner_trip_completed=true,owner_weekly_summary=true');
select test.eq('setting: the Monday email is on by default', (select owner_weekly_summary_enabled from app.settings()), true);

select test.mk_booking('ZO-0', 'ZOA', 'zo_r', test.zol(10), test.zol(12), 'confirmed');
select app.ntf_emit('owner_new_booking', 'booking', test.zob('ZO-0'), 'zo', jsonb_build_object('booking_id', test.zob('ZO-0'), 'owner_id', test.id('owner:zo_o')));
select app.ntf_emit('owner_booking_confirmed', 'booking', test.zob('ZO-0'), 'zo', jsonb_build_object('booking_id', test.zob('ZO-0'), 'owner_id', test.id('owner:zo_o')));
select app.ntf_emit('owner_booking_changed', 'booking', test.zob('ZO-0'), 'zo', jsonb_build_object('booking_id', test.zob('ZO-0'), 'owner_id', test.id('owner:zo_o'), 'owner_side', 'same'));
select test.zoflush();
select test.eq('a confirmed booking, an Owner Booking confirmed and a change: recorded, processed at once, nothing sent to the owner',
  (select count(*) from notification_outbox where entity_id = test.zob('ZO-0') and code like 'owner_%') || '/'
  || (select string_agg(distinct process_note, ',') from app_events where entity_id = test.zob('ZO-0') and code like 'owner_%'), '0/code disabled');
select test.eq('no in-app notice either',
  (select count(*) from notifications where code in ('owner_new_booking', 'owner_booking_confirmed', 'owner_booking_changed') and user_id = test.id('zo_o')), 0::bigint);

-- ================================================================ 2. a trip is complete and the car is back
select test.mk_booking('ZO-1', 'ZOA', 'zo_r', test.zol(-20, '09:00'), test.zol(-18, '09:00'), 'on_rent', 30000);
select test.mk_booking('ZO-2', 'ZOA', 'zo_r', test.zol(-17, '09:00'), test.zol(-15, '09:00'), 'on_rent', 30000);
select test.mk_booking('ZO-3', 'ZOA', 'zo_r', test.zol(-14, '09:00'), test.zol(-12, '09:00'), 'on_rent', 30000);
select test.mk_booking('ZO-4', 'ZOA', 'zo_r', test.zol(-11, '09:00'), test.zol(-9, '09:00'), 'on_rent', 30000);
select test.mk_booking('ZO-5', 'ZOA', 'zo_r', test.zol(-8, '09:00'), test.zol(-6, '09:00'), 'on_rent', 30000);
select test.mk_booking('ZO-OWN', 'ZOA', 'zo_r', test.zol(-5, '09:00'), test.zol(-3, '09:00'), 'on_rent', null, 'owner');
update bookings set odometer_out_km = 10000, odometer_in_km = 10412 where id = test.zob('ZO-1');
update bookings set source = 'turo' where id = test.zob('ZO-3');
update bookings set owner_visibility = 'until_statement' where id = test.zob('ZO-4');
update bookings set owner_revenue_excluded = true where id = test.zob('ZO-5');
-- the return Condition Report comes first: check-in needs it (0011)
insert into condition_reports (vehicle_id, booking_id, kind, performed_by_role)
select vehicle_id, id, 'return', 'staff' from bookings where booking_number in ('ZO-1', 'ZO-2', 'ZO-3', 'ZO-4', 'ZO-5', 'ZO-OWN');
update bookings set status = 'returned', checked_in_at = return_at where booking_number in ('ZO-1', 'ZO-2', 'ZO-3', 'ZO-4', 'ZO-5', 'ZO-OWN');
select app.compute_booking_split(test.zob('ZO-1'));
select app.compute_booking_split(test.zob('ZO-4'));
select test.zoflush();
select test.eq('one email for a standard trip returned; none for an Owner Booking, a Turo trip, or a revenue-excluded booking',
  (select string_agg(b.booking_number, ',' order by b.booking_number) from bookings b join notification_outbox o on o.entity_id = b.id and o.code = 'owner_trip_completed'
    where b.booking_number like 'ZO-%'), 'ZO-1,ZO-2,ZO-4');
select test.eq('it goes to the owner', (select min(to_address) from notification_outbox where entity_id = test.zob('ZO-1') and code = 'owner_trip_completed'), 'zo_o@example.test');
select test.eq('car, dates, days, distance and the owner''s share',
  (select (payload ->> 'vehicle_name' is not null) || '/' || (payload ->> 'booking_number') || '/' || (payload ->> 'pickup_date') || '/' || (payload ->> 'billable_days')
          || '/' || (payload ->> 'has_km') || '/' || (payload ->> 'km_driven') || '/' || (payload ->> 'show_amounts') || '/' || ((payload ->> 'owner_share') like '$%')
     from notification_outbox where entity_id = test.zob('ZO-1') and code = 'owner_trip_completed'),
  'true/ZO-1/' || app.fmt_date((select pickup_at from bookings where id = test.zob('ZO-1'))) || '/' || (select billable_days from bookings where id = test.zob('ZO-1'))
  || '/true/412 km/true/true');
select test.eq('no odometer, no distance line', (select (payload ->> 'has_km') || '/' || (payload ->> 'km_driven') from notification_outbox where entity_id = test.zob('ZO-2') and code = 'owner_trip_completed'), 'false/');
select test.eq('revenue hidden until the statement: the amount is left out',
  (select (payload ->> 'show_amounts') || '/' || (payload ->> 'owner_share') from notification_outbox where entity_id = test.zob('ZO-4') and code = 'owner_trip_completed'), 'false/');
select test.eq('no variable is missing', (select count(*) from notification_outbox where code = 'owner_trip_completed' and missing_variables <> '{}'), 0::bigint);
select test.eq('an in-app notice too', (select count(*) from notifications where code = 'owner_trip_completed' and user_id = test.id('zo_o')), 3::bigint);
update bookings set status = 'closed' where id = test.zob('ZO-1');
select test.zoflush();
select test.eq('closing the booking later does not send it again', test.ev('owner_trip_completed', test.zob('ZO-1')) || '/' || (select count(*) from notification_outbox where entity_id = test.zob('ZO-1') and code = 'owner_trip_completed'), '1/1');

-- ================================================================ 3. the Monday email
create function test.zomon() returns date language sql stable as $$
  select app.today() - (extract(isodow from app.today())::integer - 1) $$;
create function test.zoat(p_days integer, p_time text) returns timestamptz language sql stable as $$
  select ((test.zomon() + p_days)::timestamp + p_time::time) at time zone 'America/Toronto' $$;
select test.mk_owner('zo_w');
select test.mk_vehicle('ZOW', 'zo_w');
select test.mk_vehicle('ZOX', 'zo_w');
-- last week: a trip returned (counts), a Turo trip (does not); the next days: a confirmed booking (counts) and an Owner Booking (does not)
select test.mk_booking('ZW-1', 'ZOW', 'zo_r', to_char(test.zomon() - 6, 'YYYY-MM-DD') || ' 09:00', to_char(test.zomon() - 4, 'YYYY-MM-DD') || ' 09:00', 'returned', 30000);
select test.mk_booking('ZW-2', 'ZOW', 'zo_r', to_char(test.zomon() - 3, 'YYYY-MM-DD') || ' 09:00', to_char(test.zomon() - 2, 'YYYY-MM-DD') || ' 09:00', 'returned', 20000);
select test.mk_booking('ZW-3', 'ZOW', 'zo_r', to_char(test.zomon() + 3, 'YYYY-MM-DD') || ' 09:00', to_char(test.zomon() + 5, 'YYYY-MM-DD') || ' 09:00', 'confirmed');
select test.mk_booking('ZW-4', 'ZOW', 'zo_r', to_char(test.zomon() + 6, 'YYYY-MM-DD') || ' 09:00', to_char(test.zomon() + 7, 'YYYY-MM-DD') || ' 09:00', 'confirmed', null, 'owner');
select test.mk_booking('ZW-5', 'ZOW', 'zo_r', to_char(test.zomon() + 20, 'YYYY-MM-DD') || ' 09:00', to_char(test.zomon() + 22, 'YYYY-MM-DD') || ' 09:00', 'confirmed');
update bookings set source = 'turo' where id = test.zob('ZW-2');
select app.compute_booking_split(test.zob('ZW-1'));
select test.eq('the Monday payload: one car with last week''s trip, the next 14 days (dates only), none of the excluded bookings',
  (select jsonb_array_length(p -> 'cars') || '/' || (p -> 'cars' -> 0 ->> 'has_trips') || '/' || jsonb_array_length(p -> 'cars' -> 0 -> 'trips') || '/'
          || (p -> 'cars' -> 0 ->> 'has_upcoming') || '/' || jsonb_array_length(p -> 'cars' -> 0 -> 'upcoming') || '/' || (p -> 'cars' -> 0 -> 'upcoming' -> 0 ?& array['dates'])
          || '/' || (select count(*) from jsonb_object_keys(p -> 'cars' -> 0 -> 'upcoming' -> 0))
     from (select app.owner_weekly_payload(test.id('owner:zo_w'), test.zoat(0, '09:30')) p) x),
  '1/true/1/true/1/true/1');
select test.eq('the trip lists its dates and the owner''s share',
  (select (p -> 'cars' -> 0 -> 'trips' -> 0 ->> 'share') like '$%' and (p -> 'cars' -> 0 -> 'trips' -> 0 ->> 'dates') like '% to %'
     from (select app.owner_weekly_payload(test.id('owner:zo_w'), test.zoat(0, '09:30')) p) x), true);
select test.eq('the week label is last week, Monday to Sunday',
  (select p ->> 'week_label' from (select app.owner_weekly_payload(test.id('owner:zo_w'), test.zoat(0, '09:30')) p) x),
  to_char(test.zomon() - 7, 'Dy, Mon FMDD') || ' to ' || to_char(test.zomon() - 1, 'Dy, Mon FMDD, YYYY'));
select test.eq('an owner with nothing to report gets no payload', app.owner_weekly_payload(test.id('owner:zo_idle'), test.zoat(0, '09:30')) is null, true);

select test.eq('Tuesday, or Monday before 9:00: the job does nothing', app.job_owner_weekly(test.zoat(1, '09:30')) || '/' || app.job_owner_weekly(test.zoat(0, '08:45')), '0/0');
select test.ok('Monday 9:30: the owner with activity is emailed', app.job_owner_weekly(test.zoat(0, '09:30')) >= 1);
select test.eq('once a week: the next run sends nothing more', app.job_owner_weekly(test.zoat(0, '09:45')), 0);
select test.eq('one event for the owner, none for the idle one',
  (select count(*) from app_events where code = 'owner_weekly_summary' and entity_id = test.id('owner:zo_w')) || '/'
  || (select count(*) from app_events where code = 'owner_weekly_summary' and entity_id = test.id('owner:zo_idle')) || '/'
  || (select count(*) from owner_weekly_summaries where owner_id = test.id('owner:zo_idle') and event_id is null), '1/0/1');
select test.zoflush();
select test.eq('the email is queued with every variable', (select count(*) from notification_outbox where code = 'owner_weekly_summary' and entity_id = test.id('owner:zo_w') and missing_variables = '{}'), 1::bigint);
select test.eq('the email carries the cars list and the week',
  (select jsonb_typeof(payload -> 'cars') || '/' || (payload ->> 'week_label' is not null) from notification_outbox where code = 'owner_weekly_summary' and entity_id = test.id('owner:zo_w')), 'array/true');

update program_settings set owner_weekly_summary_enabled = false where id = (select id from app.settings());
select test.eq('with the switch off the job sends nothing', app.job_owner_weekly(test.zoat(7, '09:30')), 0);
update program_settings set owner_weekly_summary_enabled = true where id = (select id from app.settings());
