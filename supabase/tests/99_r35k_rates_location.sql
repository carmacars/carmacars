-- 99: release 35 part K, second batch (migrations 1066 to 1068): the same rate when a booking gets longer, a fixed amount per
-- plan payment, the location of in-person applicants and hires, field calls before the townhall, the townhall's day,
-- attendance and per-person tiles, and the live map's celebrations. Fixtures "r35m"; example.test only.
select test.suite('99 r35k rates, plans, location, townhall');
grant usage on schema test to service_role;

select test.mk_user('r35m_admin', 'admin');
select test.mk_user('r35m_fleet', 'va', 'fleet');
select test.mk_user('r35m_cs', 'va', 'cs');
select test.mk_user('r35m_sales', 'va', 'sales');
select test.mk_owner('r35m_o');
select test.mk_vehicle('R35MA', 'r35m_o', 'managed', 45000, 2500, 3500, date '2026-08-01');
select test.mk_renter('r35m_r');
create function test.r35m(p_who text, p_call text, p_name text, p jsonb default '{}') returns jsonb language sql as $$ select public.door(test.id(p_who), null, p_call, p_name, p) $$;

-- ================================================================ 1. the same rate (item 10)
-- a week at $525.45 with a $70 Protection Plan for the trip, confirmed
select test.mk_booking('CC-R35M1', 'R35MA', 'r35m_r', to_char(now() at time zone 'America/Toronto' + interval '10 days', 'YYYY-MM-DD 10:00'),
  to_char(now() at time zone 'America/Toronto' + interval '17 days', 'YYYY-MM-DD 10:00'), 'confirmed', 52545);
update booking_line_items set payment_id = null where booking_id = test.id('booking:CC-R35M1');
select test.mk_line('CC-R35M1', 'coverage_sold', 7000, false);
update booking_line_items set payment_id = null where booking_id = test.id('booking:CC-R35M1');
select test.mk_line('CC-R35M1', 'delivery', 5000, false);
update booking_line_items set payment_id = null where booking_id = test.id('booking:CC-R35M1');
select test.eq('the per-trip fees that scale: the Protection Plan, never delivery', (select string_agg(charge_type || '=' || amount_cents, ',') from app.booking_per_trip_fees(test.id('booking:CC-R35M1'))), 'coverage_sold=7000');
select test.eq('the booked rental per day', round(app.booking_rental_per_day(test.id('booking:CC-R35M1'))), 7506::numeric);
select test.ok('an extension of 7 days: the rental at the booked rate (the offer''s 5% off it) and the Protection Plan scaled',
  (select (v ->> 'same_rate')::boolean and (v ->> 'regular_rental_cents')::bigint = 52545
          and (v ->> 'rental_difference_cents')::bigint = case when (v ->> 'discount_bps')::int > 0 then round(52545 * (10000 - (v ->> 'discount_bps')::int) / 10000.0)::bigint else 52545 end and (v ->> 'fees_difference_cents')::bigint = 7000
     from app.preview_extension(test.id('booking:CC-R35M1'), (select return_at + interval '7 days' from bookings where booking_number = 'CC-R35M1')) v));
select test.ok('delivery is never added again on an extension',
  not exists (select 1 from jsonb_array_elements(app.preview_extension(test.id('booking:CC-R35M1'), (select return_at + interval '7 days' from bookings where booking_number = 'CC-R35M1')) -> 'lines') l
               where l ->> 'charge_type' = 'delivery'));

-- Edit dates: a week made two weeks keeps the week's rate, the Protection Plan doubled
select test.mk_booking('CC-R35M3', 'R35MA', 'r35m_r', to_char(now() at time zone 'America/Toronto' + interval '120 days', 'YYYY-MM-DD 10:00'),
  to_char(now() at time zone 'America/Toronto' + interval '127 days', 'YYYY-MM-DD 10:00'), 'confirmed', 52545);
-- a booking made from a request with the Protection Plan priced for the trip ($70), so its pricing owns the line
update bookings set request_details = '{}'::jsonb, coverage_option = 3, coverage_confirmed_at = now() where id = test.id('booking:CC-R35M3');
insert into booking_fee_terms (booking_id, fee_type_code, amount_cents, source, override_by, override_reason) values (test.id('booking:CC-R35M3'), 'coverage_sold', 7000, 'booking', test.id('r35m_admin'), 'Priced on the offer');
select app.sync_booking_price(test.id('booking:CC-R35M3'));
select test.r35m('r35m_admin', 'ops_do', 'booking_staff_edit', jsonb_build_object('booking', 'CC-R35M3', 'changes', jsonb_build_object('return_at',
  (select return_at + interval '7 days' from bookings where booking_number = 'CC-R35M3'))));
select test.eq('Edit dates: $525.45 a week stays $525.45 for the added week; the per-trip Protection Plan scales',
  (select rental_charge_cents from bookings where id = test.id('booking:CC-R35M3')) || '/' || (select sum(amount_cents) from booking_line_items where booking_id = test.id('booking:CC-R35M3') and charge_type = 'coverage_sold' and voided_at is null),
  '105090/14000');
select test.ok('the booking history says so', exists (select 1 from booking_events where booking_id = test.id('booking:CC-R35M3') and note like '%Same rate as the booked period (7 to 14 days)%'));

-- ================================================================ 2. a fixed amount per plan payment (item 13)
select test.mk_booking('CC-R35M2', 'R35MA', 'r35m_r', to_char(now() at time zone 'America/Toronto' + interval '40 days', 'YYYY-MM-DD 10:00'),
  to_char(now() at time zone 'America/Toronto' + interval '96 days', 'YYYY-MM-DD 10:00'), 'confirmed', 548496);
create temp table r35m_tot as select total_due_at_booking_cents t from bookings where id = test.id('booking:CC-R35M2');
grant select on r35m_tot to public;
select test.throws('only an Admin sets a fixed amount', format($$select test.r35m('r35m_cs', 'ops_do', 'booking_pay_every', %L)$$,
  jsonb_build_object('booking', test.id('booking:CC-R35M2'), 'pay_every', 'biweekly', 'fixed_cents', 155000)), 'Only an Admin');
select test.r35m('r35m_admin', 'ops_do', 'booking_pay_every', jsonb_build_object('booking', test.id('booking:CC-R35M2'), 'pay_every', 'biweekly', 'fixed_cents', 155000));
select test.eq('every 2 weeks at exactly $1,550.00, the last the remainder; the total unchanged',
  (select string_agg(x ->> 'cents', ',' order by (x ->> 'seq')::int) || '/' || max((x ->> 'through_cents')::bigint) from jsonb_array_elements(app.booking_pay_schedule(test.id('booking:CC-R35M2')) -> 'schedule') x),
  '155000,155000,155000,' || ((select t from r35m_tot) - 465000) || '/' || (select t from r35m_tot));
select test.eq('the total never changes', (select total_due_at_booking_cents from bookings where id = test.id('booking:CC-R35M2')), (select t from r35m_tot));

-- ================================================================ 3. the location of in-person applicants (item 14)
select test.eq('abroad: told in person needs the Toronto area, sent to Remote Sales',
  public.server_hiring_apply(jsonb_build_object('role', 'sales-in-person', 'full_name', 'R35m Abroad', 'email', 'r35m_abroad@example.test', 'phone', '+639171234567',
    'location_city', 'Manila', 'location_country', 'PH'), null) ->> 'remote_slug', 'sales-remote');
select test.ok('and no in-person application is taken', not exists (select 1 from job_applications where email = 'r35m_abroad@example.test'));
select test.eq('a Canadian city the site cannot place: taken and flagged unknown', app.in_person_area('Vancouver', 'CA'), 'unknown');
select test.eq('any country but Canada: outside', app.in_person_area('Buffalo', 'US'), 'outside');
select test.eq('a GTA city: inside', app.in_person_area('Mississauga', 'CA'), 'inside');
select test.eq('no city: asked for', public.server_hiring_apply(jsonb_build_object('role', 'sales-in-person', 'full_name', 'R35m Nocity', 'email', 'r35m_nocity@example.test', 'phone', '4165550100', 'location_city', '', 'location_country', 'CA'), null) ->> 'error', 'invalid');
insert into job_applications (id, role_id, full_name, email, phone, status, location_city, location_country, ip_country, phone_country)
values (test.id('r35m_app_flag'), (select id from hiring_roles where slug = 'sales-in-person'), 'R35m Flagged', 'r35m_flag@example.test', '+639171234568', 'interviewed', 'Toronto', 'CA', 'PH', 'PH');
select test.eq('Admin sees the mismatch and Move to Remote Sales', (select (r ->> 'location_mismatch') || '/' || (r ->> 'move_remote') from app.hiring_app_row((select a from job_applications a where id = test.id('r35m_app_flag'))) r), 'true/true');
select test.eq('the Hire form chooses Sales remote for them', test.r35m('r35m_admin', 'admin_read', 'hire_preview', jsonb_build_object('id', test.id('r35m_app_flag'))) ->> 'function', 'sales_remote');
select test.eq('Move to Remote Sales: referred with the email', test.r35m('r35m_admin', 'admin_do', 'hiring_move_remote', jsonb_build_object('id', test.id('r35m_app_flag'))) ->> 'status', 'referred');
select test.eq('a Sales hire abroad works remote', test.r35m('r35m_sales', 'ops_do', 'staff_location_save', '{"city": "Cebu", "country": "PH"}') ->> 'sales_work_mode', 'remote');
select test.eq('a Sales hire in the GTA keeps the mode they were hired in', test.r35m('r35m_sales', 'ops_do', 'staff_location_save', '{"city": "Brampton", "country": "CA"}') ->> 'sales_work_mode', 'remote');
select test.ok('Welcome asks where they live', (select s ? 'location' from jsonb_array_elements(app.staff_welcome(test.id('r35m_sales')) -> 'steps') s where s ->> 'key' = 'profile'));

-- ================================================================ 4. field calls before the townhall (item 15)
update program_settings set townhall_weekday = extract(isodow from app.today() + 3)::int, townhall_next_weekday = null, townhall_next_from = null;
select app.townhall_field_slots(now());
select test.eq('six 10-minute slots in the hour before the townhall', (select count(*) || '/' || min(extract(epoch from s.ends_at - s.starts_at) / 60)::int || '/' || (max(s.ends_at) = app.townhall_next(now()))
  from interview_slots s join interview_days d on d.id = s.day_id where d.note like 'Field calls in the hour before the weekly townhall%' and d.day = app.local_date(app.townhall_next(now()))), '6/10/true');
select test.ok('Fleet sees them', jsonb_array_length(test.r35m('r35m_fleet', 'ops_read', 'field_call_slots')) >= 6);
select test.throws('customer service does not', $$select test.r35m('r35m_cs', 'ops_read', 'field_call_slots')$$);
insert into job_applications (id, role_id, full_name, email, phone, status, knockouts) values (test.id('r35m_app_field'), (select id from hiring_roles where slug = 'field-staff'), 'R35m Driver', 'r35m_driver@example.test', '4165550101', 'interviewed', '{}');
insert into ai_interviews (application_id, role_id, questions, state, expires_at, interview_score, recommendation, scored_at)
values (test.id('r35m_app_field'), (select id from hiring_roles where slug = 'field-staff'), '[]', 'scored', now() + interval '7 days', 70, 'live_call', now());
select app.hiring_field_to_call(now());
select test.eq('a field applicant who passed the AI interview is invited to the live call with the booking link',
  (select status from job_applications where id = test.id('r35m_app_field')) || '/' || exists (select 1 from app_events where code = 'applicant_invited' and payload ->> 'application_id' = test.id('r35m_app_field')::text), 'invited/true');

-- ================================================================ 5. the townhall (item 16)
select test.ok('the least busy day is Monday to Saturday', app.townhall_pick_day() between 1 and 6);
select test.r35m('r35m_cs', 'ops_do', 'townhall_attend', '{"method": "join"}') is null or true;
select test.ok('the deck has a tile for every staff member, with the week''s numbers',
  (select bool_and(jsonb_typeof(p -> 'points') in ('array', 'null')) and count(*) >= 3 from jsonb_array_elements((select s -> 'people' from jsonb_array_elements(app.townhall_slides(date_trunc('week', now())::date)) s where s ->> 'key' = 'people')) p
    where p ->> 'name' ilike 'r35m%'));
select app.townhall_build(null, test.id('r35m_admin'));
select test.lives('an Admin writes a shout-out', format($$select test.r35m('r35m_admin', 'admin_do', 'townhall_note', %L)$$, jsonb_build_object('deck', (select id from townhall_decks order by week_of desc limit 1), 'key', 'p_' || test.id('r35m_cs'), 'note', 'Fastest replies of the week')));
select test.eq('the shout-out is on the tile', (select p ->> 'shoutout' from jsonb_array_elements((select s -> 'people' from jsonb_array_elements(test.r35m('r35m_cs', 'ops_read', 'townhall') #> '{deck,slides}') s where s ->> 'key' = 'people')) p
  where p ->> 'user_id' = test.id('r35m_cs')::text), 'Fastest replies of the week');
-- a meeting over: the absences recorded, the Admins alerted
update program_settings set townhall_weekday = extract(isodow from app.today() - 1)::int, townhall_minutes = 45;
insert into townhall_attendance (meeting_at, user_id, method) select app.townhall_next(now() - interval '2 days'), test.id('r35m_cs'), 'checkin';
select app.job_townhall(now());
select test.ok('the meeting is closed with who missed it (not who checked in)', exists (select 1 from townhall_meetings m where test.id('r35m_fleet') = any (m.absent) and not test.id('r35m_cs') = any (m.absent)));
select test.ok('the Admins are alerted to the no-shows', exists (select 1 from app_events where code like 'staff_alert_%' and payload ->> 'rule' = 'townhall_absent'));
select test.ok('the staff list counts the townhalls missed', (test.r35m('r35m_admin', 'admin_read', 'staff_access_facts') -> test.id('r35m_fleet')::text ->> 'townhalls_missed')::int >= 1);

-- ================================================================ 6. the live map's celebrations
update bookings set confirmed_at = now(), sales_staff_id = test.id('r35m_sales'), sales_source = 'offer', sales_attributed_at = now() where id = test.id('booking:CC-R35M1');
select test.eq('a booking confirmed now is celebrated with the car and the Sales credit',
  (select c ->> 'sales' from jsonb_array_elements(app.live_map_pre0470(test.id('r35m_admin'), '{"part": "kpi"}') -> 'celebrations') c where c ->> 'booking_number' = 'CC-R35M1'), 'R35m');
