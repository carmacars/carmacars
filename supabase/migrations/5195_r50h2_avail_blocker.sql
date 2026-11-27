-- 5195 (r50 hotfix2, REQ-126): "the car is not available" always names what blocks it, and the connector's revise_offer
-- changes the car of an offer.
-- The owner, Nov 27 15:43 to 15:50 (CC-10674): "Trying to put this booking through, but it says ... the car is not
-- available. Force the booking." and "Make sure that stops happening, because whatever is causing that has happened
-- before, and that has become a regular issue."
-- The cause: CC-10674 was moved to the 2021 Kia Forte, whose last rental CC-10602 is still "confirmed" with its pickup never
-- recorded (return Nov 26). The live database (build 97e9b615, before 5111) keeps such a car "presumed out" with no end
-- (3810), so every check refused the Forte. 5111 (ended bookings never block) is the fix and ships with this release; the
-- test 99_r50h2_avail proves it on the CC-10674 shape. What was missing is that the refusal never said which booking or
-- block was in the way, so each time it was a mystery. Now:
--   1. app.vehicle_blocker(vehicle, from, to, ignore): the first booking or calendar block that makes
--      app.vehicle_is_available false (the same rules: other bookings waiting for payment while their hold lasts,
--      confirmed or on rent, with the turnaround; calendar blocks not of this booking), as text: the booking number, its
--      status and dates, or the block's reason, source and dates. Null when the car is free.
--   2. Every "not available" or "not free" refusal of an offer, an approval by staff, a car change, a confirmation, pay
--      later and the booking write itself ends with ": blocked by <that>". The previews of the offer screens return it
--      (blocker). A renter approving their own offer is not shown another rental.
--   3. offer_revise (the connector's revise_offer) takes vehicle_id: it is the car box of Admin > Edit the offer
--      (changes.vehicle_id), with the same checks and the same one new version; notify false tells the renter nothing.
-- No applied migration is edited: functions are patched in place (the patch refuses when the text is not found).
set local check_function_bodies = off;

create function pg_temp.patch_fn(p_sig regprocedure, p_old text, p_new text) returns void
language plpgsql as $$
declare
  d text := pg_get_functiondef(p_sig);
begin
  if position(p_old in d) = 0 then
    raise exception '5195: the text to change was not found in %: %', p_sig, left(p_old, 160);
  end if;
  execute replace(d, p_old, p_new);
end $$;

-- ================================================================ 1. what blocks the car
create function app.vehicle_blocker(p_vehicle uuid, p_from timestamptz, p_to timestamptz, p_ignore_booking uuid default null) returns text
language plpgsql stable security definer set search_path = public, app, pg_temp as $$
declare
  v_turn interval := make_interval(mins => coalesce(app.turnaround_minutes(p_vehicle), 0));
  b bookings;
  c vehicle_calendar_blocks;
  v_turn_block boolean;
begin
  if p_vehicle is null or p_from is null or p_to is null or p_to <= p_from then
    return 'the dates (the return must be after the pickup)';
  end if;
  -- the bookings, as app.vehicle_is_available_pre3810 reads them
  select x.* into b from bookings x
   where x.vehicle_id = p_vehicle and x.blocks_calendar and x.status in ('pending_payment', 'confirmed', 'on_rent') and not app.unpaid_hold_over(x)
     and (p_ignore_booking is null or x.id <> p_ignore_booking)
     and x.pickup_at - v_turn < p_to
     and x.return_at + case when exists (select 1 from vehicle_calendar_blocks k where k.booking_id = x.id and k.source = 'turnaround')
                            then interval '0' else v_turn end > p_from
   order by x.pickup_at limit 1;
  if b.id is not null then
    v_turn_block := exists (select 1 from vehicle_calendar_blocks k where k.booking_id = b.id and k.source = 'turnaround');
    return format('booking %s (%s, %s to %s%s%s)', b.booking_number, replace(b.status::text, '_', ' '), app.fmt_at(b.pickup_at), app.fmt_at(b.return_at),
      case when v_turn > interval '0' and not v_turn_block then format(', plus %s minutes between trips', extract(epoch from v_turn)::integer / 60) else '' end,
      case when b.status = 'pending_payment' then coalesce(', held unpaid until ' || app.fmt_at(app.unpaid_hold_until(b)), '') else '' end);
  end if;
  select k.* into c from vehicle_calendar_blocks k
   where k.vehicle_id = p_vehicle and k.removed_at is null
     and (p_ignore_booking is null or k.booking_id is distinct from p_ignore_booking)
     and k.starts_at < p_to and (k.ends_at is null or k.ends_at > p_from)
   order by k.starts_at limit 1;
  if c.id is not null then
    return format('a calendar block (%s, %s, %s to %s)', replace(c.reason, '_', ' '),
      case c.source when 'external' then 'from the linked calendar'
                    when 'turnaround' then 'time between trips after ' || coalesce((select x.booking_number from bookings x where x.id = c.booking_id), 'a booking')
                    when 'rolling' then 'long-term rental ' || coalesce((select x.booking_number from bookings x where x.id = c.booking_id), '')
                    else 'added by staff' end,
      app.fmt_at(c.starts_at), coalesce(app.fmt_at(c.ends_at), 'no end'));
  end if;
  return null;
end $$;
revoke all on function app.vehicle_blocker(uuid, timestamptz, timestamptz, uuid) from public, anon, authenticated;
grant execute on function app.vehicle_blocker(uuid, timestamptz, timestamptz, uuid) to service_role;

-- ================================================================ 2. every refusal names it
-- the booking write itself (a booking that starts to block, or moves while blocking)
select pg_temp.patch_fn('app.booking_before_write()'::regprocedure,
  $o$    raise exception 'The vehicle is not available for these dates: a confirmed booking or a calendar block overlaps'
      using errcode = '23P01';$o$,
  $n$    raise exception 'The vehicle is not available for these dates: blocked by %',
      coalesce(app.vehicle_blocker(new.vehicle_id, new.pickup_at, new.return_at, new.id), 'a confirmed booking or a calendar block') using errcode = '23P01';$n$);

-- sending an offer
select pg_temp.patch_fn('app.send_offer_pre0148(uuid, uuid, text, timestamptz)'::regprocedure,
  $o$    raise exception 'The vehicle is not available for these dates: change the vehicle or the dates before sending the offer'
      using errcode = '23P01';$o$,
  $n$    raise exception 'The vehicle is not available for these dates: blocked by %. Change the car or the dates, or clear that first',
      coalesce(app.vehicle_blocker(b.vehicle_id, b.pickup_at, b.return_at, b.id), 'a booking or a calendar block') using errcode = '23P01';$n$);

-- approving an offer (the renter, staff by phone, Book it now)
select pg_temp.patch_fn('app.approve_offer_pre0130(uuid, integer, uuid, timestamptz)'::regprocedure,
  $o$    raise exception 'The vehicle is no longer available for these dates' using errcode = '23P01';$o$,
  $n$    -- staff see what is in the way; a renter approving their own offer is not shown another rental
    raise exception 'The vehicle is no longer available for these dates%', case when app.user_is_staff(p_by)
      then ': blocked by ' || coalesce(app.vehicle_blocker(b.vehicle_id, b.pickup_at, b.return_at, b.id), 'a booking or a calendar block') else '' end using errcode = '23P01';$n$);

-- changing the car (Admin > the booking > Change the car, and its list of free cars)
select pg_temp.patch_fn('app.car_change_refusal(bookings, uuid)'::regprocedure,
  $o$  if not app.vehicle_is_available(p_vehicle, b.pickup_at, b.return_at, b.id) then return 'That car is not free for the whole of these dates'; end if;$o$,
  $n$  if not app.vehicle_is_available(p_vehicle, b.pickup_at, b.return_at, b.id) then
    return 'That car is not free for the whole of these dates: blocked by '
      || coalesce(app.vehicle_blocker(p_vehicle, b.pickup_at, b.return_at, b.id), 'a booking or a calendar block');
  end if;$n$);

-- confirm pay later, and a rental already out
select pg_temp.patch_fn('app.booking_pay_later(uuid, jsonb)'::regprocedure,
  $o$then raise exception 'The car is not free for these dates' using errcode = '23514'; end if;$o$,
  $n$then raise exception 'The car is not free for these dates: blocked by %', coalesce(app.vehicle_blocker(b.vehicle_id, b.pickup_at, b.return_at, b.id), 'a booking or a calendar block') using errcode = '23514'; end if;$n$);
select pg_temp.patch_fn('app.booking_start_pay_later(uuid, jsonb)'::regprocedure,
  $o$then raise exception 'The car is not free for these dates' using errcode = '23514'; end if;$o$,
  $n$then raise exception 'The car is not free for these dates: blocked by %', coalesce(app.vehicle_blocker(b.vehicle_id, b.pickup_at, b.return_at, b.id), 'a booking or a calendar block') using errcode = '23514'; end if;$n$);

-- the previews of the offer screens: what blocks the car, beside available
select pg_temp.patch_fn('app.staff_offer_preview(uuid, jsonb)'::regprocedure,
  $o$'available', (select app.vehicle_is_available(b.vehicle_id, b.pickup_at, b.return_at, b.id) from bookings b where b.id = v_id),$o$,
  $n$'available', (select app.vehicle_is_available(b.vehicle_id, b.pickup_at, b.return_at, b.id) from bookings b where b.id = v_id),
      'blocker', (select app.vehicle_blocker(b.vehicle_id, b.pickup_at, b.return_at, b.id) from bookings b where b.id = v_id),$n$);
select pg_temp.patch_fn('app.admin_booking_preview(uuid, uuid, jsonb)'::regprocedure,
  $o$'available', (select app.vehicle_is_available(b.vehicle_id, b.pickup_at, b.return_at, b.id) from bookings b where b.id = p_booking)$o$,
  $n$'blocker', (select app.vehicle_blocker(b.vehicle_id, b.pickup_at, b.return_at, b.id) from bookings b where b.id = p_booking),
                                'available', (select app.vehicle_is_available(b.vehicle_id, b.pickup_at, b.return_at, b.id) from bookings b where b.id = p_booking)$n$);

-- ================================================================ 3. revise_offer changes the car
-- the connector's vehicle_id is the car box of Admin > Edit the offer (changes.vehicle_id): the same edit, the same checks
-- and the same one new version
alter function app.offer_revise(uuid, jsonb) rename to offer_revise_pre5195;
create function app.offer_revise(p_by uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app, pg_temp as $$
begin
  if nullif(p ->> 'vehicle_id', '') is not null then
    p := (p - 'vehicle_id') || jsonb_build_object('changes',
           (case when jsonb_typeof(p -> 'changes') = 'object' then p -> 'changes' else '{}'::jsonb end) || jsonb_build_object('vehicle_id', p ->> 'vehicle_id'));
  end if;
  return app.offer_revise_pre5195(p_by, p);
end $$;

do $$
declare g text;
begin
  execute 'revoke all on function app.offer_revise(uuid, jsonb) from public, anon, authenticated';
  foreach g in array array['anon', 'authenticated', 'service_role'] loop
    if has_function_privilege(g, 'app.offer_revise_pre5195(uuid, jsonb)'::regprocedure, 'execute') then execute format('grant execute on function app.offer_revise(uuid, jsonb) to %I', g); end if;
  end loop;
  revoke all on function app.offer_revise_pre5195(uuid, jsonb) from public, anon, authenticated;
  grant execute on function app.offer_revise_pre5195(uuid, jsonb) to service_role;
end $$;

-- SCHEMA_MARKER 5195
