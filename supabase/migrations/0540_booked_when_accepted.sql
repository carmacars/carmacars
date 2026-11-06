-- 0540: a booking the renter accepted is booked everywhere (docs/changes/2026-11-07-r28-operations.md, A1). SCHEMA_MARKER 0540+.
--
-- The owner: "bookings come through and don't show as booked because payment wasn't recorded or the pickup wasn't done.
-- Bad workflow."
--
-- A booking is booked from the moment the renter accepts the offer (status pending_payment: the offer approved; signing
-- and payment follow), and stays booked while confirmed or on rent. Payment and the handover are separate badges
-- ("Payment due", "Pickup not recorded") and To dos, never the reason a booking does not take the car:
--   1. The car's calendar, its availability, the public calendar, the Admin calendar, the fleet board, calendar feeds,
--      the partner availability and the date-conflict check count an accepted booking as booked (they counted confirmed
--      and on rent only, so an accepted, unpaid booking left the car free to be offered again).
--   2. The first renter to accept gets the car: accepting already checks the car is free (app.approve_offer), which now
--      sees the other accepted bookings; the other open offers on the same car and dates go back to staff at once with a
--      "Re-offer" To do (they went back only when the first one paid).
--   3. app.booking_is_booked (reports) counts accepted bookings.
--   4. A To do for every booked rental still unpaid within 48 hours of its pickup ("booked_unpaid"), beside the existing
--      "Record the pickup" To do for pickups past their time.
--   5. The data fix: an accepted booking already paid in full but never confirmed is confirmed now (each one in the audit
--      log); nothing is deleted.
-- No applied migration is edited.

create function pg_temp.patch_all(p_name text, p_old text, p_new text) returns integer
language plpgsql as $$
declare
  f regprocedure;
  d text;
  n integer := 0;
begin
  for f in select p.oid::regprocedure from pg_proc p join pg_namespace s on s.oid = p.pronamespace
            where s.nspname in ('app', 'public') and p.proname = p_name loop
    d := pg_get_functiondef(f);
    if position(p_old in d) > 0 then
      execute replace(d, p_old, p_new);
      n := n + 1;
    end if;
  end loop;
  if n = 0 then raise exception '0540: the text to change was not found in %: %', p_name, left(p_old, 120); end if;
  return n;
end $$;

-- ================================================================ 1. accepted bookings take the car
select pg_temp.patch_all('vehicle_is_available', $o$b.blocks_calendar and b.status in ('confirmed', 'on_rent')$o$,
                                                $n$b.blocks_calendar and b.status in ('pending_payment', 'confirmed', 'on_rent')$n$);
select pg_temp.patch_all('public_vehicle_calendar', $o$b.blocks_calendar and b.status in ('confirmed', 'on_rent')$o$,
                                                   $n$b.blocks_calendar and b.status in ('pending_payment', 'confirmed', 'on_rent')$n$);
select pg_temp.patch_all('vehicle_free_until', $o$b.blocks_calendar and b.status in ('confirmed', 'on_rent')$o$,
                                              $n$b.blocks_calendar and b.status in ('pending_payment', 'confirmed', 'on_rent')$n$);
select pg_temp.patch_all('calendar_export_ics', $o$b.blocks_calendar and b.status in ('confirmed', 'on_rent')$o$,
                                               $n$b.blocks_calendar and b.status in ('pending_payment', 'confirmed', 'on_rent')$n$);
select pg_temp.patch_all('partner_crm_availability', $o$b.blocks_calendar and b.status in ('confirmed', 'on_rent')$o$,
                                                    $n$b.blocks_calendar and b.status in ('pending_payment', 'confirmed', 'on_rent')$n$);
select pg_temp.patch_all('vehicle_calendar', $o$(b.blocks_calendar and b.status::text in ('confirmed', 'on_rent')) as is_blocking$o$,
                                            $n$(b.blocks_calendar and b.status::text in ('pending_payment', 'confirmed', 'on_rent')) as is_blocking$n$);
select pg_temp.patch_all('admin_calendar', $o$x ->> 'status' in ('confirmed', 'on_rent')) as takes$o$,
                                          $n$x ->> 'status' in ('pending_payment', 'confirmed', 'on_rent')) as takes$n$);
select pg_temp.patch_all('server_booking_calendar', $o$b.status in ('confirmed', 'on_rent')$o$, $n$b.status in ('pending_payment', 'confirmed', 'on_rent')$n$);
select pg_temp.patch_all('booking_date_conflicts', $o$o.status in ('confirmed', 'on_rent')$o$, $n$o.status in ('pending_payment', 'confirmed', 'on_rent')$n$);
select pg_temp.patch_all('calendar_conflicts_check', $o$case when x.status in ('confirmed', 'on_rent') then 'booking' else 'offer' end$o$,
                                                    $n$case when x.status in ('pending_payment', 'confirmed', 'on_rent') then 'booking' else 'offer' end$n$);
-- the fleet board: the next booking of a free car, and a car whose booked pickup passed
select pg_temp.patch_all('fleet_board', $o$nb.status::text = 'confirmed' and nb.pickup_at > p_now$o$, $n$nb.status::text in ('pending_payment', 'confirmed') and nb.pickup_at > p_now$n$);
select pg_temp.patch_all('fleet_board', $o$cb.status::text = 'confirmed' and cb.blocks_calendar$o$, $n$cb.status::text in ('pending_payment', 'confirmed') and cb.blocks_calendar$n$);

-- reports: an accepted booking is a booking
create or replace function app.booking_is_booked(b bookings) returns boolean
language sql immutable as $$ select b.status in ('pending_payment', 'confirmed', 'on_rent', 'returned', 'closed') $$;
comment on function app.booking_is_booked(bookings) is 'Booked: accepted by the renter (pending_payment), confirmed, on rent, returned or closed (0540). Payment and the handover never decide it.';

-- one place that says it, for the screens and later checks
create or replace function app.booking_status_booked(s booking_status) returns boolean
language sql immutable as $$ select s::text in ('pending_payment', 'confirmed', 'on_rent') $$;
comment on function app.booking_status_booked(booking_status) is 'The statuses that hold the car (0540): accepted (pending_payment), confirmed, on rent.';

-- ================================================================ 2. the first to accept gets the car
create or replace function app.booking_accepted_takes_car() returns trigger
language plpgsql security definer set search_path = public, app as $$
declare
  v_buffer interval;
  r record;
begin
  if not (new.status = 'pending_payment' and old.status is distinct from 'pending_payment' and new.blocks_calendar) then return null; end if;
  if coalesce(new.is_placeholder, false) then return null; end if;
  v_buffer := make_interval(mins => coalesce((app.settings()).turnaround_buffer_minutes, 0));
  for r in
    select o.id, o.booking_number, o.status, o.current_offer_version, o.renter_id
      from bookings o
     where o.vehicle_id = new.vehicle_id and o.id <> new.id and o.blocks_calendar and o.status = 'offered'
       and not coalesce(o.is_placeholder, false)
       and o.pickup_at < new.return_at + v_buffer and o.return_at > new.pickup_at - v_buffer
     order by o.booked_at, o.id
     for update
  loop
    update booking_offers
       set status = 'withdrawn', responded_at = now(),
           response_note = format('Booking %s was accepted on this vehicle for overlapping dates', new.booking_number)
     where booking_id = r.id and status = 'sent';
    update bookings set status = 'requested' where id = r.id;
    perform app.log_booking_event(r.id, 'pushed_back', r.status::text, 'requested', r.current_offer_version,
      format('Booking %s was accepted on this vehicle for overlapping dates. This request is back with staff: offer another vehicle or other dates.',
             new.booking_number), null, 'system');
    perform app.raise_task(p_type => 'reoffer_booking', p_title => format('Re-offer booking %s: the car was taken', r.booking_number),
      p_detail => format('Booking %s was accepted on the same vehicle for overlapping dates, so the offer on %s was withdrawn. Offer another vehicle or other dates, or decline.',
                         new.booking_number, r.booking_number),
      p_booking => r.id, p_vehicle => new.vehicle_id, p_renter => r.renter_id, p_priority => 'high', p_queue => 'cs',
      p_dedupe => 'reoffer_booking:' || r.id || ':' || new.id);
  end loop;
  return null;
end $$;
drop trigger if exists bookings_accepted_takes_car on bookings;
create trigger bookings_accepted_takes_car after update of status on bookings for each row execute function app.booking_accepted_takes_car();

-- ================================================================ 3. To do: booked, still unpaid near the pickup
insert into task_rules (task_type, queue, title, priority, due_kind, due_amount, procedure_no, description)
values ('booked_unpaid', 'cs', 'Booked, payment due: collect it before the pickup', 'high', 'none', 0, 1,
        'A booking the renter accepted is booked; its payment is still open within 48 hours of the pickup (0540). Collect it (pay link, saved card, or record the payment).')
on conflict (task_type) do nothing;

create or replace function app.booked_unpaid_tasks(p_now timestamptz default now()) returns integer
language plpgsql security definer set search_path = public, app as $$
declare
  r record;
  v_n integer := 0;
  v_open bigint;
begin
  for r in select b.id, b.booking_number, b.vehicle_id, b.renter_id, b.pickup_at, app.vehicle_name(b.vehicle_id) as car
             from bookings b
            where b.status = 'pending_payment' and b.booking_type <> 'owner' and not coalesce(b.is_placeholder, false)
              and coalesce(b.rental_pay_method, 'card') not in ('insurer', 'platform_payout')
              and b.pickup_at <= p_now + interval '48 hours' and b.return_at > p_now loop
    v_open := app.booking_part_open(r.id, 'rental') + app.booking_part_open(r.id, 'fees');
    if v_open > 0 then
      perform app.raise_task(p_type => 'booked_unpaid',
        p_title => format('%s is booked, %s still due: collect it before the pickup', r.booking_number, app.fmt_money(v_open)),
        p_detail => format('The %s goes out %s. The booking stands; only the payment is open. Money tab: send the pay link, charge the saved card, or record the payment.',
                           coalesce(r.car, 'car'), app.fmt_at(r.pickup_at)),
        p_booking => r.id, p_vehicle => r.vehicle_id, p_renter => r.renter_id, p_due_at => least(r.pickup_at, p_now + interval '24 hours'),
        p_dedupe => 'booked_unpaid:' || r.id);
      v_n := v_n + 1;
    end if;
  end loop;
  -- paid since, or no longer booked: the To do closes
  for r in select distinct t.booking_id from tasks t join bookings b on b.id = t.booking_id
            where t.task_type = 'booked_unpaid' and t.status in ('open', 'in_progress', 'waiting')
              and (b.status <> 'pending_payment' or app.booking_part_open(b.id, 'rental') + app.booking_part_open(b.id, 'fees') = 0) loop
    perform app.resolve_tasks(array['booked_unpaid'], r.booking_id, null, 'Paid, or no longer waiting for payment');
  end loop;
  return v_n;
end $$;
revoke all on function app.booked_unpaid_tasks(timestamptz) from public, anon, authenticated;
grant execute on function app.booked_unpaid_tasks(timestamptz) to service_role;

-- the staff notification run (every few minutes) raises them
alter function app.notify_booking_staff(timestamptz) rename to notify_booking_staff_pre0540;
create function app.notify_booking_staff(p_now timestamptz default now()) returns integer
language plpgsql security definer set search_path = public, app as $$
declare
  v integer := app.notify_booking_staff_pre0540(p_now);
begin
  begin
    v := v + app.booked_unpaid_tasks(p_now);
  exception when others then
    raise warning '0540 booked_unpaid_tasks: %', sqlerrm;
  end;
  return v;
end $$;
revoke all on function app.notify_booking_staff(timestamptz) from public, anon, authenticated;
do $$
declare g text;
begin
  foreach g in array array['anon', 'authenticated', 'service_role'] loop
    if has_function_privilege(g, 'app.notify_booking_staff_pre0540(timestamptz)', 'execute') then
      execute format('grant execute on function app.notify_booking_staff(timestamptz) to %I', g);
    end if;
  end loop;
end $$;

-- ================================================================ 4. the data fix: accepted and paid in full, never confirmed
do $$
declare
  r record;
  v jsonb;
begin
  for r in select b.id, b.booking_number, b.offer_approved_by from bookings b
            where b.status = 'pending_payment' and b.booking_type <> 'owner' and not coalesce(b.is_placeholder, false)
              and b.return_at > now()
              and b.offer_approved_version is not null and b.offer_approved_version = b.current_offer_version
              and app.booking_part_open(b.id, 'rental') + app.booking_part_open(b.id, 'fees') = 0
              and (exists (select 1 from payments p where p.booking_id = b.id and p.purpose = 'booking_total' and p.status = 'succeeded')
                   or exists (select 1 from manual_payments m where m.booking_id = b.id and m.voided_at is null and m.covers in ('rental', 'fees'))) loop
    begin
      v := app.confirm_when_paid(r.id, r.offer_approved_by);
    exception when others then
      v := jsonb_build_object('ok', false, 'reason', sqlerrm);
    end;
    insert into audit_log (action, entity_table, entity_id, before, after)
    values ('0540_booked_data_fix', 'bookings', r.id::text, jsonb_build_object('status', 'pending_payment', 'booking_number', r.booking_number),
            jsonb_build_object('status', (select status from bookings where id = r.id), 'result', v));
  end loop;
end $$;

revoke all on function app.booking_accepted_takes_car(), app.booking_status_booked(booking_status) from public, anon;
grant execute on function app.booking_status_booked(booking_status) to authenticated, service_role;
