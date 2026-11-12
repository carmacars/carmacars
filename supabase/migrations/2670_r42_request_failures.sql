-- 2670_r42_request_failures.sql
-- Release 42 (docs/changes/2026-11-12-r42-request-failures.md). A request to book that is refused or fails no longer ends in
-- "We could not send the request. Please try again or call us.":
--   1. app.request_refusal turns every refusal of public.submit_booking_request (its raised errors and its ok:false replies)
--      into a code, the form field to change and a plain message. An error nobody planned for is "unexpected": the person is
--      told we kept the request and will contact them, and staff see the database's own words.
--   2. public.server_booking_request_failed (server only) keeps the refused request (booking_request_failures: who, the car,
--      the dates, the reason; one row per person, car and day) and raises one Sales To-do for it, so nobody is lost.
--   3. A request that later goes through closes the row and its To-do.
--   4. public.server_request_failures: the Admin's "Requests that did not go through" count and reasons on Leads.
--   5. Loosened: the hourly limit of requests from one network address goes from 5 to 30 (people on the same mobile network
--      or office Wi-Fi share an address).
-- public.submit_booking_request itself is unchanged.

create table public.booking_request_failures (
  id uuid primary key default gen_random_uuid(),
  dedupe_key text not null unique,
  day date not null,
  email text,
  phone text,
  full_name text,
  user_id uuid references users (id) on delete set null,
  vehicle_id uuid references vehicles (id) on delete set null,
  pickup_at timestamptz,
  return_at timestamptz,
  code text not null,
  field text,
  reason text not null,
  raw text,
  unexpected boolean not null default false,
  tries integer not null default 1,
  task_id uuid,
  resolved_at timestamptz,
  resolved_booking_id uuid,
  created_at timestamptz not null default now(),
  last_at timestamptz not null default now()
);
comment on table public.booking_request_failures is 'A request to book that was refused or failed (2670): who asked, the car, the dates and the reason, one row per person, car and day. Closed when a request from the same person goes through. Kept 90 days.';
create index booking_request_failures_open_idx on public.booking_request_failures (last_at desc) where resolved_at is null;
create index booking_request_failures_email_idx on public.booking_request_failures (email) where resolved_at is null;
alter table public.booking_request_failures enable row level security;
revoke all on table public.booking_request_failures from public, anon, authenticated;
grant select, insert, update, delete on table public.booking_request_failures to service_role;
-- Admins may read it (every table carries the admin policy); the request path writes it as the service role
create policy admin_all on public.booking_request_failures for select to authenticated using (app.is_admin());

-- ================================================================ 1. every refusal, in plain words, with its field
create function app.request_refusal(p_code text, p_message text, p_request jsonb default null) returns jsonb
language plpgsql stable security definer set search_path = public, app as $$
declare
  m text := btrim(coalesce(p_message, ''));
  c text := lower(btrim(coalesce(p_code, '')));
  v_set program_settings := app.settings();
  v_code text; v_field text; v_msg text;
  v_pick text := coalesce(p_request #>> '{pickup_location,kind}', '');
  v_ret text := coalesce(p_request #>> '{return_location,kind}', '');
  v_n text;
begin
  if c = 'rate_limited' then
    v_code := 'rate_limited';
    v_msg := 'Too many requests came from your internet connection in the last hour. Wait an hour and press Send request again. Your answers are saved.';
  elsif c = 'too_many_open_requests' then
    v_code := 'too_many_open_requests';
    v_msg := format('You already have %s requests open. Sign in, open My bookings and withdraw one you no longer need, then press Send request again. Your answers are saved.', v_set.booking_open_request_limit);
  elsif c = 'security_check' then
    v_code := 'security_check';
    v_msg := 'Our security check did not go through. Press Send request again; if it keeps happening, try another browser. Your answers are saved.';
  elsif c = 'invalid' then
    v_code := 'invalid'; v_msg := coalesce(nullif(m, ''), 'Check the highlighted fields.');
  elsif m ~* 'request key' then
    v_code := 'reload'; v_msg := 'Reload the page and press Send request again. Your answers are saved.';
  elsif m ~* 'not handed over at its Owner' then
    v_code := 'owner_location'; v_field := case when v_pick = 'owner_location' then 'pickupAt' else 'returnAt' end;
    v_msg := 'This car is not handed over at its owner''s location. Choose another place for the pickup and the return.';
  elsif m ~* 'Exit Date' then
    v_code := 'car_leaves'; v_field := 'dates';
    v_msg := 'This car leaves our fleet before your return date. Choose an earlier return date, or another car.';
  elsif m ~* 'not available for these dates' then
    v_code := 'dates_taken'; v_field := 'dates';
    v_msg := 'This car is already booked for part of these dates. Choose other dates, or another car.';
  elsif m ~* '(not available to book|not open for new bookings|example car|no rates set|VIN or plate needed|overdue service)' then
    v_code := 'car_unavailable'; v_field := 'car';
    v_msg := 'This car cannot be booked online right now. Choose another car; everything else you typed stays.';
  elsif m ~* 'return must be after the pickup' then
    v_code := 'dates_order'; v_field := 'dates'; v_msg := 'The return is before the pickup. Choose a later return date or time.';
  elsif m ~* 'pickup must be at least' then
    v_code := 'notice'; v_field := 'dates';
    v_n := case when v_set.booking_min_notice_minutes % 60 = 0 then (v_set.booking_min_notice_minutes / 60) || ' hours' else v_set.booking_min_notice_minutes || ' minutes' end;
    v_msg := format('Pickup needs at least %s of notice from now. Choose a later pickup time.', v_n);
  elsif m ~* '^A (booking|rental transaction) is 1 to' then
    v_code := 'too_long'; v_field := 'dates';
    v_msg := format('One booking covers up to %s days. Choose an earlier return date.', app.max_rental_days_now());
  elsif m ~* 'non-refundable discount is only for' then
    v_code := 'non_refundable_notice'; v_field := 'bookingType';
    v_msg := 'The non-refundable discount is only for a pickup further ahead. Choose the standard booking type.';
  elsif m ~* 'standard or a non-refundable' then
    v_code := 'booking_type'; v_field := 'bookingType'; v_msg := 'Choose the standard or the non-refundable booking type.';
  elsif m ~* 'Choose an airport' or (m ~* 'needs its address' and (v_pick = 'airport' or v_ret = 'airport') and v_pick <> 'delivery' and v_ret <> 'delivery') then
    v_code := 'airport'; v_field := case when v_pick = 'airport' and nullif(p_request ->> 'pickup_place', '') is null then 'pickupAirport' when v_ret = 'airport' then 'returnAirport' else 'pickupAirport' end;
    v_msg := 'Choose the airport from the list again.';
  elsif m ~* 'pickup at the end of the rental needs its address' then
    v_code := 'return_address'; v_field := 'returnAddress'; v_msg := 'Add the address where we pick the car up at the end.';
  elsif m ~* 'delivery needs its address' then
    v_code := 'delivery_address'; v_field := case when v_pick = 'delivery' and nullif(p_request ->> 'pickup_place', '') is null then 'pickupAddress' when v_ret = 'delivery' then 'returnAddress' else 'pickupAddress' end;
    v_msg := 'Add the delivery address: start typing and choose it from the list.';
  elsif m ~* 'note is too long' then
    v_code := 'note_long'; v_field := 'notes'; v_msg := format('Keep the note under %s characters.', v_set.request_note_max_chars);
  elsif m ~* 'baby seats' then
    v_code := 'baby_seats'; v_field := 'addons'; v_msg := format('A booking may ask for up to %s baby seats. Lower the number.', v_set.max_baby_seats);
  elsif m ~* '(could be added until|add-on)' then
    v_code := 'addon'; v_field := 'addons';
    v_msg := 'One of the add-ons cannot be added online for these dates. Take it off and send the request; tell us in the note and we will see what we can do.';
  elsif m ~* '^Pick your credit card' then
    v_code := 'coverage_card'; v_field := 'coverageCard'; v_msg := 'Pick your credit card from the list so we can check its rental car coverage.';
  elsif m ~* 'Credit card coverage needs a card on our list' then
    v_code := 'coverage_card_not_covered'; v_field := 'coverageCard'; v_msg := m;
  elsif m ~* '^Tick that you will pay' then
    v_code := 'coverage_card_ack'; v_field := 'coverageCardAck'; v_msg := 'Tick that you will pay for the rental with this card.';
  elsif m ~* '^Tick that you will upload' then
    v_code := 'opcf_ack'; v_field := 'opcfAck'; v_msg := 'Tick that you will upload your auto policy with the OPCF 27 endorsement.';
  elsif m ~* 'how damage to the car will be covered' then
    v_code := 'coverage'; v_field := 'coverage'; v_msg := 'Choose how the car will be covered. You can change it before pickup.';
  elsif m ~* '(Terms of Use|Privacy Policy) must be accepted' then
    v_code := 'agree'; v_field := 'agree'; v_msg := 'Tick the box that you agree to the Terms of use and the Privacy policy.';
  elsif m ~* 'valid email address' then
    v_code := 'email'; v_field := 'email'; v_msg := 'Enter an email address like name@example.com.';
  elsif m ~* 'mobile number is needed' then
    v_code := 'phone'; v_field := 'phone'; v_msg := 'Enter a mobile number we can reach you on.';
  elsif m ~* 'full legal name and date of birth' then
    v_code := 'driver_details'; v_field := 'dob'; v_msg := 'Enter your full name and your full date of birth.';
  elsif m ~* 'Every driver must be' then
    v_code := 'too_young'; v_field := 'dob'; v_msg := format('Every driver must be %s or older at pickup. Check the dates of birth.', v_set.min_renter_age);
  elsif m ~* 'This car is for drivers' then
    v_code := 'car_age'; v_field := 'dob'; v_msg := format('This car is for drivers %s and over. Choose another car, or check the dates of birth.', v_set.standard_min_age);
  elsif m ~* 'licence' and m ~* '(is needed)' then
    v_code := 'licence_class'; v_field := 'licClass';
    v_msg := format('Choose your licence class (Ontario %s), or Something else with where it was issued.', array_to_string(v_set.accepted_licence_classes, ' or '));
  elsif m ~* 'up to \d+ additional drivers' then
    v_code := 'drivers_max'; v_field := 'drivers'; v_msg := format('A booking may name up to %s additional drivers. Remove one.', v_set.max_additional_drivers);
  elsif m ~* 'Each additional driver needs' then
    v_code := 'driver_missing'; v_field := 'drivers'; v_msg := 'Each additional driver needs a first and last name, a date of birth and an email.';
  elsif m ~* 'same driver is named twice' then
    v_code := 'driver_twice'; v_field := 'drivers'; v_msg := 'The same driver is named twice. Remove the copy.';
  elsif m ~* 'could not take this request online' then
    v_code := 'account_review';
    v_msg := 'We cannot take a request online for this account. We kept your request and our team will contact you.';
  else
    return jsonb_build_object('code', 'unexpected', 'field', null, 'unexpected', true,
      'message', 'Something went wrong on our side, not yours. We kept your request and our team will contact you to finish it. You do not need to fill the form in again.');
  end if;
  return jsonb_build_object('code', v_code, 'field', v_field, 'message', v_msg, 'unexpected', false);
end $$;
revoke all on function app.request_refusal(text, text, jsonb) from public, anon, authenticated;
grant execute on function app.request_refusal(text, text, jsonb) to service_role;

-- ================================================================ 2. keep the refused request and tell Sales
-- p: request (what was sent to submit_booking_request, when it got that far), code (an ok:false error, or security_check,
-- invalid), message (the database's words), contact {email, phone, name} and vehicle_id, pickup_at, return_at for a failure
-- before the request was built, ip, user.
create function public.server_booking_request_failed(p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  q jsonb := coalesce(p -> 'request', '{}'::jsonb);
  v_ref jsonb := app.request_refusal(p ->> 'code', p ->> 'message', p -> 'request');
  v_email text := nullif(lower(btrim(coalesce(q #>> '{renter,email}', p #>> '{contact,email}', ''))), '');
  v_phone text := nullif(btrim(coalesce(q #>> '{renter,mobile}', p #>> '{contact,phone}', '')), '');
  v_name text := nullif(left(btrim(coalesce(q #>> '{renter,full_name}', p #>> '{contact,name}', '')), 120), '');
  v_user uuid;
  v_vehicle uuid;
  v_pickup timestamptz; v_return timestamptz;
  v_day date := app.today();
  v_who text;
  v_key text;
  v_car text;
  v_id uuid; v_task uuid; v_tries integer;
  v_raw text := nullif(left(btrim(coalesce(p ->> 'message', '')), 500), '');
begin
  begin
    v_user := nullif(p ->> 'user', '')::uuid;
    v_vehicle := nullif(coalesce(q ->> 'vehicle_id', p ->> 'vehicle_id'), '')::uuid;
    v_pickup := nullif(coalesce(q ->> 'pickup_at', p ->> 'pickup_at'), '')::timestamptz;
    v_return := nullif(coalesce(q ->> 'return_at', p ->> 'return_at'), '')::timestamptz;
  exception when others then null;
  end;
  if v_user is not null and not exists (select 1 from users where id = v_user) then v_user := null; end if;
  if v_vehicle is not null and not exists (select 1 from vehicles where id = v_vehicle) then v_vehicle := null; end if;
  if v_user is not null then
    select coalesce(v_email, nullif(lower(u.email), '')), coalesce(v_phone, u.phone), coalesce(v_name, u.full_name) into v_email, v_phone, v_name from users u where u.id = v_user;
  end if;
  v_who := coalesce(v_email, nullif(regexp_replace(coalesce(v_phone, ''), '\D', '', 'g'), ''), v_user::text);
  -- nobody to contact: nothing to follow up
  if v_who is null or (v_email is not null and v_email !~ '^[^@\s]+@[^@\s]+\.[^@\s]+$' and v_phone is null) then
    return v_ref || jsonb_build_object('logged', false);
  end if;
  -- a flood from one network address is not kept (the person still gets the reason)
  if nullif(p ->> 'ip', '') is not null and not app.rate_limit('booking_request_failed:ip:' || (p ->> 'ip'), 30, interval '1 hour') then
    return v_ref || jsonb_build_object('logged', false);
  end if;
  delete from booking_request_failures where last_at < now() - interval '90 days';
  v_key := md5(v_who || '|' || coalesce(v_vehicle::text, '') || '|' || v_day);
  select trim(concat_ws(' ', v.year, v.make, v.model)) into v_car from vehicles v where v.id = v_vehicle;
  insert into booking_request_failures as f (dedupe_key, day, email, phone, full_name, user_id, vehicle_id, pickup_at, return_at, code, field, reason, raw, unexpected)
  values (v_key, v_day, v_email, v_phone, v_name, v_user, v_vehicle, v_pickup, v_return, v_ref ->> 'code', v_ref ->> 'field', v_ref ->> 'message', v_raw, (v_ref ->> 'unexpected')::boolean)
  on conflict (dedupe_key) do update set tries = f.tries + 1, last_at = now(), code = excluded.code, field = excluded.field, reason = excluded.reason, raw = excluded.raw,
    unexpected = excluded.unexpected, pickup_at = coalesce(excluded.pickup_at, f.pickup_at), return_at = coalesce(excluded.return_at, f.return_at),
    phone = coalesce(excluded.phone, f.phone), full_name = coalesce(excluded.full_name, f.full_name), resolved_at = null, resolved_booking_id = null
  returning f.id, f.tries into v_id, v_tries;
  v_task := app.raise_task(p_type => 'request_not_sent',
    p_title => left(format('Request did not go through: %s, %s', coalesce(v_name, v_email, v_phone), coalesce(v_car, 'no car chosen')), 200),
    p_detail => format('%s tried to send a request to book and it did not go through. Contact: %s. Car: %s. Dates: %s to %s (Toronto time). Reason shown to them: %s%s Call or text them and help them finish: their answers are saved in the form, or make the offer yourself with New quote.',
      coalesce(v_name, 'A visitor'), concat_ws(', ', v_email, v_phone), coalesce(v_car, 'not chosen'),
      coalesce(to_char(v_pickup at time zone 'America/Toronto', 'Mon FMDD, HH24:MI'), 'not set'), coalesce(to_char(v_return at time zone 'America/Toronto', 'Mon FMDD, HH24:MI'), 'not set'),
      v_ref ->> 'message', case when (v_ref ->> 'unexpected')::boolean and v_raw is not null then ' The system said: ' || v_raw || '.' else '' end),
    p_vehicle => v_vehicle, p_related_table => 'booking_request_failures', p_related_id => v_id,
    p_priority => case when (v_ref ->> 'unexpected')::boolean then 'urgent' else 'high' end, p_queue => 'sales', p_dedupe => 'request-not-sent:' || v_key);
  update booking_request_failures set task_id = v_task where id = v_id;
  return v_ref || jsonb_build_object('logged', true, 'failure_id', v_id, 'tries', v_tries);
end $$;
revoke all on function public.server_booking_request_failed(jsonb) from public, anon, authenticated;
grant execute on function public.server_booking_request_failed(jsonb) to service_role;

-- ================================================================ 3. a request that goes through closes it
create function app.booking_request_failures_resolve() returns trigger
language plpgsql security definer set search_path = public, app as $$
declare
  v_email text; v_user uuid;
begin
  -- never in the way of the request itself
  begin
    select nullif(lower(coalesce(r.email, u.email)), ''), r.user_id into v_email, v_user from renters r left join users u on u.id = r.user_id where r.id = new.renter_id;
    with done as (
      update booking_request_failures f set resolved_at = now(), resolved_booking_id = new.id
       where f.resolved_at is null and ((v_email is not null and f.email = v_email) or (v_user is not null and f.user_id = v_user))
      returning f.dedupe_key)
    update tasks t set status = 'done', completed_at = now(), completion_note = 'The request went through: ' || new.booking_number
      from done where t.dedupe_key = 'request-not-sent:' || done.dedupe_key and t.status in ('open', 'in_progress', 'waiting');
  exception when others then null;
  end;
  return null;
end $$;
create trigger bookings_zz_request_failures_resolve after insert on bookings
  for each row when (new.status = 'requested' and new.renter_id is not null) execute function app.booking_request_failures_resolve();

-- ================================================================ 4. the Admin's count on Leads
create function public.server_request_failures(p_by uuid) returns jsonb
language plpgsql stable security definer set search_path = public, app as $$
begin
  perform app.assert_admin(p_by);
  return jsonb_build_object(
    'count', (select count(*) from booking_request_failures f where f.resolved_at is null and f.last_at > now() - interval '14 days'),
    'reasons', coalesce((select jsonb_agg(jsonb_build_object('code', x.code, 'reason', x.reason, 'n', x.n) order by x.n desc, x.code)
                           from (select f.code, min(f.reason) as reason, count(*) as n from booking_request_failures f
                                  where f.resolved_at is null and f.last_at > now() - interval '14 days' group by f.code) x), '[]'::jsonb),
    'rows', coalesce((select jsonb_agg(to_jsonb(y) order by y.last_at desc) from (
        select f.id, f.full_name as name, f.email, f.phone, trim(concat_ws(' ', v.year, v.make, v.model)) as car, f.pickup_at, f.return_at, f.code, f.reason,
               case when f.unexpected then f.raw end as raw, f.unexpected, f.tries, f.last_at
          from booking_request_failures f left join vehicles v on v.id = f.vehicle_id
         where f.resolved_at is null and f.last_at > now() - interval '14 days' order by f.last_at desc limit 30) y), '[]'::jsonb));
end $$;
revoke all on function public.server_request_failures(uuid) from public, anon, authenticated;
grant execute on function public.server_request_failures(uuid) to service_role;

-- ================================================================ 5. loosened: requests an hour from one network address
-- 5 an hour refused real people who share an address (a mobile network, an office or campus Wi-Fi). An Admin's own value stays.
alter table program_settings alter column booking_request_hourly_limit set default 30;
update program_settings set booking_request_hourly_limit = 30 where booking_request_hourly_limit = 5;
