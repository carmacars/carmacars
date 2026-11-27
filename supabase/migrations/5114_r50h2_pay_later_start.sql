-- 5114 (r50 hotfix2): with no card processor, an Admin can let a rental start before it is paid. CC-10673 was stuck
-- "pending payment" with the car already out since the evening before, and the pickup was refused.
--   1. bookings.pay_later_at, pay_later_by, pay_later_reason.
--   2. app.booking_pay_later(admin, {booking, reason}): an approved offer waiting for payment (pending_payment) is
--      confirmed with the rental and the deposit still owed ("pay later": no processor now, the renter pays later), with
--      the reason (10 characters or more) on the booking's history and a Finance To do to collect what is open. Admins only.
--   3. app.booking_start_pay_later(admin, {booking, reason, at, odometer_km, fuel_pct}): in one step for a rental that
--      already started: an open offer is booked now (app.offer_book_now), confirmed pay later as above, and the pickup
--      recorded at the real time given (in the past; app.handover_override as an Admin, so the deposit may still be owed).
--   Door: admin_do booking_pay_later, booking_start_pay_later.

alter table bookings add column if not exists pay_later_at timestamptz;
alter table bookings add column if not exists pay_later_by uuid references users (id);
alter table bookings add column if not exists pay_later_reason text check (pay_later_reason is null or char_length(pay_later_reason) between 10 and 500);
comment on column bookings.pay_later_at is 'Confirmed pay later (5114): an Admin confirmed it with the rental and the deposit owed; pay_later_reason says why.';

create function app.booking_pay_later(p_by uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app, pg_temp as $$
declare
  b bookings;
  v_reason text := nullif(btrim(coalesce(p ->> 'reason', '')), '');
  v_open bigint;
begin
  if not app.user_is_admin(p_by) then raise exception 'Only an Admin confirms a booking to be paid later' using errcode = '42501'; end if;
  if v_reason is null or char_length(v_reason) < 10 then raise exception 'Say why it is paid later (10 characters or more)' using errcode = '22023'; end if;
  perform 1 from vehicles where id = (select vehicle_id from bookings where id::text = p ->> 'booking' or booking_number = upper(btrim(coalesce(p ->> 'booking', '')))) for no key update;
  select * into b from bookings where id::text = p ->> 'booking' or booking_number = upper(btrim(coalesce(p ->> 'booking', ''))) for update;
  if b.id is null then raise exception 'Booking not found' using errcode = 'P0002'; end if;
  if b.status <> 'pending_payment' then raise exception 'Booking % is %, not waiting for payment', b.booking_number, replace(b.status::text, '_', ' ') using errcode = '23514'; end if;
  if b.offer_approved_version is distinct from b.current_offer_version then raise exception 'The current offer is not approved: book it now first' using errcode = '23514'; end if;
  if b.blocks_calendar and not app.vehicle_is_available(b.vehicle_id, b.pickup_at, b.return_at, b.id) then raise exception 'The car is not free for these dates' using errcode = '23514'; end if;
  perform set_config('app.confirm_offline', b.id::text, true);
  update bookings set status = 'confirmed', pay_later_at = now(), pay_later_by = p_by, pay_later_reason = v_reason where id = b.id;
  perform set_config('app.confirm_offline', '', true);
  v_open := app.booking_balance_open(b.id);
  perform app.log_booking_event(b.id, 'confirmed', 'pending_payment', 'confirmed', b.offer_approved_version,
    format('Confirmed pay later by an Admin: %s. Owed: %s and the deposit %s', v_reason, app.fmt_money(greatest(v_open, 0)), app.fmt_money(coalesce(b.deposit_cents, 0))),
    p_by, 'staff', jsonb_build_object('mode', 'pay_later', 'reason', v_reason, 'open_cents', v_open, 'deposit_cents', b.deposit_cents));
  perform app.raise_task(p_type => 'collect_pay_later', p_queue => 'finance', p_priority => 'high', p_booking => b.id, p_vehicle => b.vehicle_id, p_renter => b.renter_id,
    p_title => left(format('Collect the payment: %s (confirmed pay later)', b.booking_number), 200),
    p_detail => left(format('An Admin confirmed %s before payment: %s. Collect %s and the deposit of %s by e-Transfer or cash, then record them on the booking.',
                            b.booking_number, v_reason, app.fmt_money(greatest(v_open, 0)), app.fmt_money(coalesce(b.deposit_cents, 0))), 2000),
    p_dedupe => 'collect_pay_later:' || b.id, p_created_by => p_by);
  perform app.resolve_tasks(array['confirm_offline_booking'], b.id, p_by, 'Confirmed pay later');
  return jsonb_build_object('ok', true, 'status', 'confirmed', 'booking_number', b.booking_number, 'open_cents', v_open, 'deposit_cents', b.deposit_cents);
end $$;

create function app.booking_start_pay_later(p_by uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app, pg_temp as $$
declare
  b bookings;
  v_at timestamptz := nullif(p ->> 'at', '')::timestamptz;
  v_reason text := nullif(btrim(coalesce(p ->> 'reason', '')), '');
  v_pick jsonb;
begin
  if not app.user_is_admin(p_by) then raise exception 'Only an Admin starts a rental before it is paid' using errcode = '42501'; end if;
  if v_at is null then raise exception 'Give the real pickup time' using errcode = '22023'; end if;
  if v_at > now() + interval '5 minutes' then raise exception 'The pickup time is in the future: confirm pay later now and record the pickup when the car goes' using errcode = '22023'; end if;
  if v_reason is null or char_length(v_reason) < 10 then raise exception 'Say why it is paid later (10 characters or more)' using errcode = '22023'; end if;
  select * into b from bookings where id::text = p ->> 'booking' or booking_number = upper(btrim(coalesce(p ->> 'booking', '')));
  if b.id is null then raise exception 'Booking not found' using errcode = 'P0002'; end if;
  if b.status = 'offered' then perform app.offer_book_now(p_by, b.id, v_reason); end if;
  if (select status from bookings where id = b.id) = 'pending_payment' then perform app.booking_pay_later(p_by, jsonb_build_object('booking', b.id, 'reason', v_reason)); end if;
  if (select status from bookings where id = b.id) <> 'confirmed' then
    raise exception 'Booking % is %: only an offer, a booking waiting for payment or a confirmed one starts here', b.booking_number, replace((select status from bookings where id = b.id)::text, '_', ' ') using errcode = '23514';
  end if;
  v_pick := app.handover_override(p_by, jsonb_build_object('booking', b.id, 'kind', 'pickup', 'at', v_at, 'reason', 'Started before payment: ' || v_reason)
                                        || jsonb_strip_nulls(jsonb_build_object('odometer_km', p -> 'odometer_km', 'fuel_pct', p -> 'fuel_pct')));
  return jsonb_build_object('ok', true, 'booking_number', b.booking_number, 'status', (select status from bookings where id = b.id), 'pickup', v_pick);
end $$;

alter function app.door(uuid, text, text, text, jsonb) rename to door_pre5114;
create function app.door(p_user uuid, p_aal text, p_call text, p_name text, p jsonb default '{}'::jsonb) returns jsonb
language plpgsql security definer set search_path = public, app, pg_temp as $$
begin
  if p_call = 'admin_do' and p_name in ('booking_pay_later', 'booking_start_pay_later') then
    perform app.door_begin(p_user, p_aal);
    if p_name = 'booking_pay_later' then return app.booking_pay_later(p_user, p); end if;
    return app.booking_start_pay_later(p_user, p);
  end if;
  return app.door_pre5114(p_user, p_aal, p_call, p_name, p);
end $$;

do $$
declare g text;
begin
  execute 'revoke all on function app.door(uuid, text, text, text, jsonb) from public, anon, authenticated';
  foreach g in array array['anon', 'authenticated', 'service_role'] loop
    if has_function_privilege(g, 'app.door_pre5114(uuid, text, text, text, jsonb)'::regprocedure, 'execute') then execute format('grant execute on function app.door(uuid, text, text, text, jsonb) to %I', g); end if;
  end loop;
  revoke all on function app.booking_pay_later(uuid, jsonb), app.booking_start_pay_later(uuid, jsonb) from public, anon, authenticated;
  grant execute on function app.booking_pay_later(uuid, jsonb), app.booking_start_pay_later(uuid, jsonb) to service_role;
end $$;
create index if not exists bookings_pay_later_by_idx on bookings (pay_later_by) where pay_later_by is not null;

-- the renter's digital incident card (/account/incident, server_incident_digital and its documents) whenever the renter
-- has the car: a rental on rent, a confirmed one about to start, and one whose handover is recorded while its payment is
-- still owed (pay later)
create or replace function app.booking_in_progress(b bookings, p_now timestamptz default now()) returns boolean
language sql stable set search_path = public, app, pg_temp as $$
  select b.status::text = 'on_rent' or (b.status::text = 'confirmed' and b.pickup_at <= p_now + interval '12 hours' and b.return_at > p_now)
      or (b.handed_over_at is not null and b.status::text in ('confirmed', 'pending_payment'))
$$;
