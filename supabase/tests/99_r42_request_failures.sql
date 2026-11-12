-- 99: migration 2670 (release 42): every refusal of a request to book has a code, a field and a plain message; a refused or
-- failed request is kept once per person, car and day with a Sales To-do; a request that goes through closes it; the Admin
-- reads the count. Fixtures start with "rq42"; addresses are example.test and numbers are 555.
select test.suite('99 r42 requests that did not go through (2670)');

select test.mk_user('rq42_admin', 'admin');
select test.mk_user('rq42_sales', 'va', 'sales');
select test.mk_owner('rq42_owner');
select test.mk_vehicle('rq42_car', 'rq42_owner');
select test.mk_renter('rq42_rita');
update renters set email = 'rf.rita@example.test' where id = test.id('renter:rq42_rita');

create function pg_temp.r(p_message text, p_code text default null, p_request jsonb default null) returns text language sql as
$$ select (v ->> 'code') || '/' || coalesce(v ->> 'field', '-') from app.request_refusal(p_code, p_message, p_request) v $$;
create function pg_temp.fail(p_email text, p_message text, p_code text default null, p_ip text default null) returns jsonb language sql as $$
  select public.server_booking_request_failed(jsonb_build_object('code', p_code, 'message', p_message, 'ip', p_ip, 'request', jsonb_build_object(
    'vehicle_id', test.id('vehicle:rq42_car'), 'pickup_at', '2031-05-02T14:00:00Z', 'return_at', '2031-05-05T14:00:00Z',
    'renter', jsonb_build_object('email', p_email, 'full_name', 'Rita Fixture', 'mobile', '416-555-0171')))) $$;

-- ---------------------------------------------------------------- every refusal names its field
select test.eq('the dates: order, notice, too long, the car leaving, taken',
  pg_temp.r('The return must be after the pickup') || ' ' || pg_temp.r('The pickup must be at least 120 minutes from now') || ' '
  || pg_temp.r('A booking is 1 to 365 days; these dates make 400. Shorten the dates.') || ' ' || pg_temp.r('The booking would run past the vehicle''s Exit Date')
  || ' ' || pg_temp.r('The vehicle is not available for these dates: a confirmed booking or a calendar block overlaps'),
  'dates_order/dates notice/dates too_long/dates car_leaves/dates dates_taken/dates');
select test.eq('the car', pg_temp.r('This car is not available to book') || ' ' || pg_temp.r('Vehicle is not open for new bookings') || ' ' || pg_temp.r('This vehicle has no rates set'),
  'car_unavailable/car car_unavailable/car car_unavailable/car');
select test.eq('the places',
  pg_temp.r('A delivery needs its address', null, '{"pickup_location": {"kind": "delivery"}}') || ' ' || pg_temp.r('A pickup at the end of the rental needs its address') || ' '
  || pg_temp.r('A delivery needs its address', null, '{"pickup_location": {"kind": "airport"}, "return_location": {"kind": "our_location"}}') || ' '
  || pg_temp.r('Choose an airport from the list', null, '{"pickup_location": {"kind": "our_location"}, "return_location": {"kind": "airport"}, "pickup_place": "x"}') || ' '
  || pg_temp.r('This car is not handed over at its Owner''s location', null, '{"pickup_location": {"kind": "owner_location"}}'),
  'delivery_address/pickupAddress return_address/returnAddress airport/pickupAirport airport/returnAirport owner_location/pickupAt');
select test.eq('the driver',
  pg_temp.r('A valid email address is needed') || ' ' || pg_temp.r('A mobile number is needed') || ' ' || pg_temp.r('Every driver must be 18 or older at pickup') || ' '
  || pg_temp.r('This car is for drivers 21 and over') || ' ' || pg_temp.r('The renter''s full legal name and date of birth are needed') || ' '
  || pg_temp.r('The same driver is named twice') || ' ' || pg_temp.r('A booking may name up to 4 additional drivers') || ' '
  || pg_temp.r('Each additional driver needs a full name, a date of birth and an email address'),
  'email/email phone/phone too_young/dob car_age/dob driver_details/dob driver_twice/drivers drivers_max/drivers driver_missing/drivers');
select test.eq('the licence, the coverage, the booking type, the note, the add-ons, the consent',
  pg_temp.r('The licence class is needed') || ' ' || pg_temp.r('A class G or G2 licence is needed, or an equivalent from another province or country with its issuer') || ' '
  || pg_temp.r('Choose how damage to the car will be covered (option 1, 2 or 3)') || ' ' || pg_temp.r('Pick your credit card from the list to check its rental car coverage first') || ' '
  || pg_temp.r('That card stops at $65,000. Credit card coverage needs a card on our list that covers this car: choose OPCF 27 on your own auto policy, or the Protection Plan.') || ' '
  || pg_temp.r('Tick that you will pay for the rental with this card: its coverage counts only on the card that paid') || ' '
  || pg_temp.r('Tick that you will upload your auto policy with the OPCF 27 endorsement (the pink slip and the endorsement page)') || ' '
  || pg_temp.r('The non-refundable discount is only for bookings made at least 7 days before pickup. Choose a standard booking.') || ' '
  || pg_temp.r('The note is too long (at most 500 characters)') || ' ' || pg_temp.r('Baby seat could be added until May 1. Call us and we will see what we can do.') || ' '
  || pg_temp.r('The Terms of Use must be accepted, with the version and wording shown'),
  'licence_class/licClass licence_class/licClass coverage/coverage coverage_card/coverageCard coverage_card_not_covered/coverageCard coverage_card_ack/coverageCardAck opcf_ack/opcfAck non_refundable_notice/bookingType note_long/notes addon/addons agree/agree');
select test.eq('the replies without an error: the limits and the security check',
  pg_temp.r(null, 'rate_limited') || ' ' || pg_temp.r(null, 'too_many_open_requests') || ' ' || pg_temp.r(null, 'security_check'),
  'rate_limited/- too_many_open_requests/- security_check/-');
select test.ok('an error nobody planned for is unexpected: we kept the request and will contact them, and the database''s words are not shown',
  (select (v ->> 'unexpected')::boolean and v ->> 'code' = 'unexpected' and v ->> 'message' ~ 'We kept your request' and v ->> 'message' !~ 'duplicate key'
     from app.request_refusal(null, 'duplicate key value violates unique constraint "users_email_key"') v));
select test.ok('no message tells the person to call us', not exists (
  select 1 from unnest(array['The return must be after the pickup', 'This car is not available to book', 'A mobile number is needed', 'Baby seat could be added until May 1. Call us and we will see what we can do.', 'boom']) m
   where app.request_refusal(null, m) ->> 'message' ~* 'call us')
  and app.request_refusal('rate_limited', null) ->> 'message' !~* 'call us' and app.request_refusal('too_many_open_requests', null) ->> 'message' !~* 'call us');

-- ---------------------------------------------------------------- kept once per person, car and day, with one Sales To-do
select test.eq('a refused request is kept with the reason and its field', (select (v ->> 'logged') || '/' || (v ->> 'code') || '/' || (v ->> 'field') || '/' || (v ->> 'tries')
  from pg_temp.fail('rf.rita@example.test', 'The pickup must be at least 120 minutes from now') v), 'true/notice/dates/1');
select test.eq('a second try the same day adds to the same row, with the newest reason',
  (select (v ->> 'tries') || '/' || (v ->> 'code') from pg_temp.fail('RF.Rita@example.test', 'A mobile number is needed') v)
  || '/' || (select count(*) from booking_request_failures where email = 'rf.rita@example.test'), '2/phone/1');
select test.eq('one open Sales To-do with the contact, the car, the dates and the reason',
  (select count(*) || '/' || min(queue) || '/' || min(priority) || '/' || bool_and(detail ~ 'rf.rita@example.test' and detail ~ '416-555-0171' and detail ~ 'May 2' and vehicle_id = test.id('vehicle:rq42_car'))
     from tasks where task_type = 'request_not_sent' and dedupe_key like 'request-not-sent:%' and detail ~ 'rf.rita@example.test' and status = 'open'), '1/sales/high/true');
select test.eq('an unexpected error is kept',
  (select (v ->> 'code') || '/' || (v ->> 'logged') from pg_temp.fail('rf.uma@example.test', 'null value in column "x" violates not-null constraint') v), 'unexpected/true');
select test.eq('its To-do is urgent and keeps the database''s words for staff only',
  (select priority || '/' || (detail ~ 'The system said: null value') from tasks where task_type = 'request_not_sent' and detail ~ 'rf.uma@example.test'), 'urgent/true');
select test.eq('nobody to contact: the reason is returned and nothing is kept',
  (select (v ->> 'logged') || '/' || (v ->> 'code') from public.server_booking_request_failed('{"code": "security_check"}'::jsonb) v), 'false/security_check');
select test.eq('a flood from one network address is not kept after 30 an hour',
  (select count(*) filter (where (pg_temp.fail('rf.flood' || i || '@example.test', 'boom', null, '198.51.100.77') ->> 'logged')::boolean) from generate_series(1, 32) i), 30::bigint);

-- ---------------------------------------------------------------- the Admin's count; a request that goes through closes it
select test.eq('the Admin reads the count, the reasons and the rows', (select (v ->> 'count') || '/' || (v #>> '{reasons,0,code}') || '/' || (v #>> '{reasons,0,n}') || '/' || jsonb_array_length(v -> 'rows')
  from public.server_request_failures(test.id('rq42_admin')) v), '32/unexpected/31/30');
select test.throws('staff do not', format($$select public.server_request_failures(%L)$$, test.id('rq42_sales')));
select test.mk_booking('RF-1', 'rq42_car', 'rq42_rita', '2031-05-02 10:00', '2031-05-05 10:00', 'requested');
select test.eq('her request went through: the row is closed and the To-do is done',
  (select (resolved_at is not null) || '/' || (resolved_booking_id = test.id('booking:RF-1')) from booking_request_failures where email = 'rf.rita@example.test')
  || '/' || (select status || '/' || (completion_note ~ 'RF-1') from tasks where task_type = 'request_not_sent' and detail ~ 'rf.rita@example.test'), 'true/true/done/true');
select test.eq('and it leaves the Admin''s count', (public.server_request_failures(test.id('rq42_admin')) ->> 'count'), '31');
select test.eq('a later failure the same day adds to the row', (select (v ->> 'tries') from pg_temp.fail('rf.rita@example.test', 'boom') v), '3');
select test.eq('and opens it again with a new To-do', (select (resolved_at is null)::text from booking_request_failures where email = 'rf.rita@example.test')
  || '/' || (select count(*) from tasks where task_type = 'request_not_sent' and detail ~ 'rf.rita@example.test' and status = 'open'), 'true/1');

-- ---------------------------------------------------------------- server only; the loosened limit
select test.ok('the table and the functions are for the server only',
  (select relrowsecurity from pg_class where oid = 'public.booking_request_failures'::regclass)
  and not has_table_privilege('authenticated', 'public.booking_request_failures', 'select') and not has_table_privilege('anon', 'public.booking_request_failures', 'select')
  and not has_function_privilege('anon', 'public.server_booking_request_failed(jsonb)', 'execute') and not has_function_privilege('authenticated', 'public.server_booking_request_failed(jsonb)', 'execute')
  and not has_function_privilege('authenticated', 'public.server_request_failures(uuid)', 'execute') and has_function_privilege('service_role', 'public.server_booking_request_failed(jsonb)', 'execute')
  and has_function_privilege('service_role', 'public.server_request_failures(uuid)', 'execute'));
select test.eq('30 requests an hour from one network address (people share an address)', (select booking_request_hourly_limit from app.settings()), 30);
