-- 5195 (r50 hotfix2, REQ-129): "the car is not available" always names what blocks it, and the connector's revise_offer
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
--   4. Cleaning never stops a rental (owner, Nov 27 16:51: "Why the fuck is it marked cleaning it's already available").
--      A return sets the car to cleaning (0011) and nothing set it back: the detail job's Done did not, so the Forte stayed
--      in cleaning from CC-10478's return (Nov 16), its next pickup (CC-10602) could not be recorded ("Vehicle is cleaning
--      and cannot be handed over"), CC-10602 stayed confirmed and the Forte stayed presumed out. Now a detail job marked
--      done puts a car in cleaning back to available, a handover takes a car in cleaning (it describes the car between
--      rentals, not its dates), and cars left in cleaning with no open detail job are made available once here.
--   5. The connector's set_car_status (admin_do vehicle_status_set): an Admin changes a car's status to one the Admin car
--      page offers (the status rules), with a reason kept in the audit log. Never on rent or exited (a handover, the exit flow).
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
  -- a past rental still confirmed with its pickup never recorded (3810: presumed out until it is recorded), named only
  -- when it is what makes the car not available (5111 ends that rule; the live build before 5111 still has it)
  if p_to > now() and not app.vehicle_is_available(p_vehicle, p_from, p_to, p_ignore_booking) then
    b := app.vehicle_presumed_out(p_vehicle, p_ignore_booking);
    if b.id is not null then
      return format('booking %s (confirmed, its pickup on %s never recorded, return %s: the car counts as out until its handover, return or no-show is recorded)',
        b.booking_number, app.fmt_at(b.pickup_at), app.fmt_at(b.return_at));
    end if;
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
  $n$    -- staff and the server see what is in the way; a renter or an owner keeps the old message (no other rental shown)
    if (auth.uid() is not null and (app.user_is_admin(auth.uid()) or app.user_is_staff(auth.uid())))
       or (auth.uid() is null and coalesce(nullif(current_setting('request.jwt.claims', true), '')::jsonb ->> 'role', 'service_role') = 'service_role') then
      raise exception 'The vehicle is not available for these dates: blocked by %',
        coalesce(app.vehicle_blocker(new.vehicle_id, new.pickup_at, new.return_at, new.id), 'a confirmed booking or a calendar block') using errcode = '23P01';
    end if;
    raise exception 'The vehicle is not available for these dates: a confirmed booking or a calendar block overlaps'
      using errcode = '23P01';$n$);

-- sending an offer
select pg_temp.patch_fn('app.send_offer_pre0148(uuid, uuid, text, timestamptz)'::regprocedure,
  $o$    raise exception 'The vehicle is not available for these dates: change the vehicle or the dates before sending the offer'
      using errcode = '23P01';$o$,
  $n$    raise exception 'The vehicle is not available for these dates: blocked by %. Change the vehicle or the dates before sending the offer',
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
      'blocker', (select case when not app.vehicle_is_available(b.vehicle_id, b.pickup_at, b.return_at, b.id) then app.vehicle_blocker(b.vehicle_id, b.pickup_at, b.return_at, b.id) end from bookings b where b.id = v_id),$n$);
select pg_temp.patch_fn('app.admin_booking_preview(uuid, uuid, jsonb)'::regprocedure,
  $o$'available', (select app.vehicle_is_available(b.vehicle_id, b.pickup_at, b.return_at, b.id) from bookings b where b.id = p_booking)$o$,
  $n$'blocker', (select case when not app.vehicle_is_available(b.vehicle_id, b.pickup_at, b.return_at, b.id) then app.vehicle_blocker(b.vehicle_id, b.pickup_at, b.return_at, b.id) end from bookings b where b.id = p_booking),
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

-- ================================================================ 4. cleaning never stops a rental
select pg_temp.patch_fn('app.booking_after_status()'::regprocedure,
  $o$    if v_status not in ('available', 'exit_notice', 'ready_to_list') then
      if not app.override_skips(new.id, 'vehicle_status') then raise exception 'Vehicle is % and cannot be handed over', v_status using errcode = '23514'; end if;
    end if;
    update vehicles set status = 'on_rent' where id = new.vehicle_id;$o$,
  $n$    if v_status not in ('available', 'exit_notice', 'ready_to_list', 'cleaning') then
      if not app.override_skips(new.id, 'vehicle_status') then raise exception 'Vehicle is % and cannot be handed over', v_status using errcode = '23514'; end if;
    end if;
    -- the status rules have no cleaning to on_rent: the car becomes available first (as 0072 does for a rental already out)
    if v_status = 'cleaning' then update vehicles set status = 'available' where id = new.vehicle_id and status = 'cleaning'; end if;
    update vehicles set status = 'on_rent' where id = new.vehicle_id;$n$);

select pg_temp.patch_fn('app.handover_blockers_pre0930(uuid, uuid, text, jsonb)'::regprocedure,
  $o$    if v_status not in ('available', 'exit_notice', 'ready_to_list') then v_codes := v_codes || 'vehicle_status'::text; end if;$o$,
  $n$    if v_status not in ('available', 'exit_notice', 'ready_to_list', 'cleaning') then v_codes := v_codes || 'vehicle_status'::text; end if;$n$);

create function app.detail_done_car_available() returns trigger
language plpgsql security definer set search_path = public, app, pg_temp as $$
begin
  if new.kind = 'detail' and new.status = 'done' and old.status is distinct from 'done' and new.vehicle_id is not null
     and coalesce(new.scheduled_at, new.created_at) >= coalesce((select max(h.changed_at) from status_history h
           where h.entity = 'vehicle' and h.entity_id = new.vehicle_id and h.to_status = 'cleaning'), '-infinity')
     and not exists (select 1 from field_jobs j where j.vehicle_id = new.vehicle_id and j.id <> new.id
           and j.status in ('scheduled', 'acknowledged', 'in_progress')) then
    update vehicles set status = 'available' where id = new.vehicle_id and status = 'cleaning';
  end if;
  return null;
end $$;
revoke all on function app.detail_done_car_available() from public, anon, authenticated;
grant execute on function app.detail_done_car_available() to service_role;
create trigger field_jobs_detail_done_available after update of status on field_jobs
  for each row execute function app.detail_done_car_available();

-- the cars left in cleaning for over 24 hours with no field job of any kind still open (the Forte since Nov 16)
update vehicles v set status = 'available'
 where v.status = 'cleaning'
   and coalesce((select max(h.changed_at) from status_history h where h.entity = 'vehicle' and h.entity_id = v.id and h.to_status = 'cleaning'), '-infinity') < now() - interval '24 hours'
   and not exists (select 1 from field_jobs j where j.vehicle_id = v.id and j.status in ('scheduled', 'acknowledged', 'in_progress'));

-- ================================================================ 5. set_car_status
create function app.vehicle_status_set(p_by uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app, pg_temp as $$
declare
  v vehicles;
  v_to text := nullif(btrim(coalesce(p ->> 'status', '')), '');
  v_reason text := nullif(btrim(coalesce(p ->> 'reason', '')), '');
begin
  if not app.user_is_admin(p_by) then raise exception 'Only an Admin changes a car''s status' using errcode = '42501'; end if;
  select * into v from vehicles where id::text = coalesce(p ->> 'vehicle_id', p ->> 'vehicle') for update;
  if v.id is null then raise exception 'Car not found' using errcode = 'P0002'; end if;
  if v_reason is null or char_length(v_reason) < 3 then raise exception 'Say why the status changes' using errcode = '22023'; end if;
  if v_to in ('on_rent', 'exited') then
    raise exception 'A car goes on rent only through a handover, and exits only through the exit flow' using errcode = '23514';
  end if;
  if v_to is null or v_to = v.status::text then raise exception 'The car is already %', replace(v.status::text, '_', ' ') using errcode = '22023'; end if;
  if not exists (select 1 from status_transitions t where t.entity = 'vehicle' and t.from_status = v.status::text and t.to_status = v_to) then
    raise exception 'A car goes from % to: %', replace(v.status::text, '_', ' '),
      coalesce((select string_agg(replace(t.to_status, '_', ' '), ', ' order by t.to_status) from status_transitions t where t.entity = 'vehicle' and t.from_status = v.status::text), 'nothing') using errcode = '23514';
  end if;
  update vehicles set status = v_to::vehicle_status where id = v.id;
  insert into audit_log (actor_user_id, action, entity_table, entity_id, before, after)
  values (p_by, 'vehicle_status_set', 'vehicles', v.id::text, jsonb_build_object('status', v.status), jsonb_build_object('status', v_to, 'reason', v_reason));
  return jsonb_build_object('ok', true, 'vehicle_id', v.id, 'vehicle', app.vehicle_name(v.id), 'from', v.status, 'status', v_to);
end $$;
revoke all on function app.vehicle_status_set(uuid, jsonb) from public, anon, authenticated;
grant execute on function app.vehicle_status_set(uuid, jsonb) to service_role;

alter function app.door(uuid, text, text, text, jsonb) rename to door_pre5195;
create function app.door(p_user uuid, p_aal text, p_call text, p_name text, p jsonb default '{}'::jsonb) returns jsonb
language plpgsql security definer set search_path = public, app, pg_temp as $$
begin
  if p_call = 'admin_do' and p_name = 'vehicle_status_set' then
    perform app.door_begin(p_user, p_aal);
    return app.vehicle_status_set(p_user, p);
  end if;
  return app.door_pre5195(p_user, p_aal, p_call, p_name, p);
end $$;

alter function app.api_action(text) rename to api_action_pre5195;
create function app.api_action(p_tool text) returns jsonb
language sql immutable as $$
  select case p_tool
    when 'set_car_status' then '{"call":"admin_do","name":"vehicle_status_set","target":"vehicle"}'::jsonb
    else app.api_action_pre5195(p_tool) end
$$;

do $$
declare g text;
begin
  execute 'revoke all on function app.door(uuid, text, text, text, jsonb), app.api_action(text) from public, anon, authenticated';
  foreach g in array array['anon', 'authenticated', 'service_role'] loop
    if has_function_privilege(g, 'app.door_pre5195(uuid, text, text, text, jsonb)'::regprocedure, 'execute') then execute format('grant execute on function app.door(uuid, text, text, text, jsonb) to %I', g); end if;
    if has_function_privilege(g, 'app.api_action_pre5195(text)'::regprocedure, 'execute') then execute format('grant execute on function app.api_action(text) to %I', g); end if;
  end loop;
end $$;

-- SCHEMA_MARKER 5195
