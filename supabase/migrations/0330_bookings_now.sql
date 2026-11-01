-- 0330: Bookings > Now, the one screen for what is out, coming back, going out and owed (docs/changes/2026-11-06-bookings-now.md).
--
-- The owner: "the literal most important thing, which cars are currently out and to which renters and which need to
-- return it and at what time and when they need to pay next (whether they're on biweekly or weekly and they have a
-- payment coming up) or whether a car needs to go out soon and what not. There's no clear way to see all of these
-- things in one place." Then: "Instead of building yet another board, I'm sure a few of the tabs or boards under
-- 'bookings' could either be revamped or merged." Bookings opens on Now; the list of every booking is its All tab.
--
-- 1. bookings.pay_every: how the renter pays the rental. Null (the default) works it out: a long rental cut into
--    periods (0139, 0148) pays each period (monthly), anything else pays the whole rental. weekly or biweekly: the rental
--    is paid in instalments of 7 or 14 days from the pickup, each its share of the total by its days. monthly: the
--    periods, or 30 days each when the rental has none. whole: everything at the pickup. Set on the booking page
--    (ops_do booking_pay_every: Admins, customer service, finance), recorded in the booking history; the booking page
--    shows the plan and its instalments (ops_read booking_pay_plan: Admins, customer service, fleet, finance).
-- 2. app.booking_pay_schedule(booking, now): the plan, what the renter owes and has paid (insurer payments apart), the
--    instalments, and the next payment: when, how much (everything owed up to and including it) and its state: paid,
--    overdue, soon (within 3 days) or upcoming. An insurer-billed rental with nothing for the renter is "insurer"; a split
--    bill keeps the renter's part on its plan and shows the insurer's part beside it. An Owner Booking owes nothing.
-- 3. app.fleet_board(now): the whole screen in one read. Out now (every car on rent with its renter, pickup, due back,
--    plan, next payment, deposit held, km and fuel at pickup; a confirmed booking whose pickup time has passed with no
--    check-out recorded counts as out, marked "pickup not recorded"; overdue returns first), going out (confirmed pickups
--    in the next 72 hours, with the readiness: licence, agreement, paid, deposit (0261: placed the morning of the pickup
--    day, so "scheduled" before then), check-out photos), coming back (today, tomorrow, overdue), money due (the next
--    payment within 7 days or overdue, every confirmed, on rent or returned booking) and free cars (available and not
--    out: idle days, the next pickup; and the cars in maintenance or cleaning; partners' cars are counted apart). Placeholders
--    (0283) are never on it.
--    Every due time is Toronto time.
--    Ended, never closed: a confirmed booking with no check-out whose return time passed and whose car went out again
--    after it; not out, listed apart with Close (ops_do booking_close_ended: the pickup and the return recorded at the
--    booked times through 0195's record-now path, with its guards). Each rental carries bill_to for the Bill to filter.
-- 4. The door: ops_read bookings_now. Admins and the fleet and customer service staff see everything; field staff see
--    the cars (out, going out, coming back, free) with no money, and the renter's phone only on their own jobs.
-- No applied migration is edited.
set local check_function_bodies = off;

create function pg_temp.copy_grants(p_new regprocedure, p_old regprocedure) returns void
language plpgsql as $$
declare g text;
begin
  execute format('revoke all on function %s from public, anon, authenticated', p_new);
  foreach g in array array['anon', 'authenticated', 'service_role'] loop
    if has_function_privilege(g, p_old, 'execute') then execute format('grant execute on function %s to %I', p_new, g); end if;
  end loop;
end $$;

-- ================================================================ 1. how the renter pays
alter table bookings add column if not exists pay_every text check (pay_every in ('whole', 'weekly', 'biweekly', 'monthly'));
comment on column bookings.pay_every is 'How the renter pays the rental (0330): whole (at the pickup), weekly or biweekly instalments from the pickup, monthly (the long rental''s periods). Null: monthly when the rental has periods, else whole.';

-- ================================================================ 2. the payment schedule
create or replace function app.booking_pay_schedule(p_booking uuid, p_now timestamptz default now()) returns jsonb
language plpgsql stable security definer set search_path = public, app as $$
declare
  b bookings;
  v_plan text;
  v_owed bigint;
  v_paid bigint;
  v_ins_paid bigint;
  v_step integer;
  v_n integer;
  v_total_s numeric;
  v_cum bigint := 0;
  v_amt bigint;
  v_start timestamptz;
  v_end timestamptz;
  v_rows jsonb := '[]'::jsonb;
  v_next jsonb;
  v_state text;
  v_overdue integer := 0;
  r record;
  i integer;
begin
  select * into b from bookings where id = p_booking;
  if b.id is null then return null; end if;
  -- the renter's part: the total less the insurer's share and its HST (renter_due_at_booking_cents, generated)
  v_owed := case when b.booking_type = 'owner' then 0 else greatest(coalesce(b.renter_due_at_booking_cents, b.total_due_at_booking_cents, 0), 0) end;
  v_ins_paid := coalesce((select sum(p.amount_cents) from payments p where p.booking_id = b.id and p.status = 'succeeded' and p.kind = 'charge' and p.method = 'insurer'), 0);
  v_paid := greatest(app.booking_paid_cents(b.id) - v_ins_paid, 0);
  v_plan := case when b.booking_type = 'owner' then 'owner'
                 when b.bill_to = 'insurer' and v_owed = 0 then 'insurer'
                 when b.pay_every is not null then b.pay_every
                 when exists (select 1 from booking_periods bp where bp.booking_id = b.id and bp.status <> 'cancelled') then 'monthly'
                 else 'whole' end;

  if v_owed > 0 then
    if v_plan = 'monthly' and exists (select 1 from booking_periods bp where bp.booking_id = b.id and bp.status <> 'cancelled') then
      select count(*) into v_n from booking_periods bp where bp.booking_id = b.id and bp.status <> 'cancelled';
      i := 0;
      for r in select bp.seq, bp.starts_at, bp.ends_at, bp.amount_cents from booking_periods bp
                where bp.booking_id = b.id and bp.status <> 'cancelled' order by bp.seq loop
        i := i + 1;
        v_amt := case when i = v_n then v_owed - v_cum else least(greatest(r.amount_cents, 0), v_owed - v_cum) end;
        v_cum := v_cum + v_amt;
        v_rows := v_rows || jsonb_build_object('seq', i, 'due_at', r.starts_at, 'ends_at', r.ends_at, 'cents', v_amt, 'through_cents', v_cum);
      end loop;
    elsif v_plan in ('weekly', 'biweekly', 'monthly') then
      v_step := case v_plan when 'weekly' then 7 when 'biweekly' then 14 else 30 end;
      v_total_s := greatest(extract(epoch from b.return_at - b.pickup_at), 1);
      v_n := greatest(ceil(v_total_s / (v_step * 86400.0))::integer, 1);
      for i in 1 .. v_n loop
        v_start := b.pickup_at + make_interval(days => (i - 1) * v_step);
        v_end := least(b.pickup_at + make_interval(days => i * v_step), b.return_at);
        v_amt := case when i = v_n then v_owed - v_cum else round(v_owed * extract(epoch from v_end - v_start) / v_total_s)::bigint end;
        v_cum := v_cum + v_amt;
        v_rows := v_rows || jsonb_build_object('seq', i, 'due_at', v_start, 'ends_at', v_end, 'cents', v_amt, 'through_cents', v_cum);
      end loop;
    else
      v_rows := jsonb_build_array(jsonb_build_object('seq', 1, 'due_at', b.pickup_at, 'ends_at', b.return_at, 'cents', v_owed, 'through_cents', v_owed));
    end if;
  end if;

  -- the next payment: the first instalment not covered by what was paid; its amount is everything owed up to it
  select x into v_next from jsonb_array_elements(v_rows) x where (x ->> 'through_cents')::bigint > v_paid order by (x ->> 'seq')::integer limit 1;
  select count(*) into v_overdue from jsonb_array_elements(v_rows) x
   where (x ->> 'through_cents')::bigint > v_paid and (x ->> 'due_at')::timestamptz < p_now;
  v_state := case when v_plan in ('owner', 'insurer') then 'none'
                  when v_owed = 0 or v_next is null then 'paid'
                  when (v_next ->> 'due_at')::timestamptz < p_now then 'overdue'
                  when (v_next ->> 'due_at')::timestamptz <= p_now + interval '3 days' then 'soon'
                  else 'upcoming' end;
  return jsonb_build_object(
    'plan', v_plan, 'set', b.pay_every is not null, 'state', v_state,
    'owed_cents', v_owed, 'paid_cents', least(v_paid, v_owed), 'open_cents', greatest(v_owed - v_paid, 0),
    'count', jsonb_array_length(v_rows), 'per_cents', case when jsonb_array_length(v_rows) > 0 then (v_rows -> 0 ->> 'cents')::bigint end,
    'overdue_count', v_overdue,
    -- cents: what to collect now. Overdue: everything due by now not paid; otherwise what is left of the next instalment.
    'next', case when v_next is not null then jsonb_build_object('seq', (v_next ->> 'seq')::integer, 'due_at', v_next ->> 'due_at',
                   'cents', case when v_state = 'overdue'
                                 then (select max((x ->> 'through_cents')::bigint) from jsonb_array_elements(v_rows) x where (x ->> 'due_at')::timestamptz < p_now) - v_paid
                                 else (v_next ->> 'through_cents')::bigint - v_paid end,
                   'instalment_cents', (v_next ->> 'cents')::bigint) end,
    'insurer', case when b.bill_to <> 'renter' then jsonb_build_object('name', (select i2.name from insurers i2 where i2.id = b.insurer_id),
                   'claim', b.insurer_claim_number,
                   'share_cents', coalesce(b.insurer_share_cents, 0) + coalesce(b.insurer_hst_cents, 0),
                   'paid_cents', v_ins_paid) end,
    'schedule', v_rows);
end $$;
comment on function app.booking_pay_schedule(uuid, timestamptz) is 'The renter''s payment plan for a booking (0330): plan, owed, paid, instalments and the next payment with its state (paid, overdue, soon, upcoming; none for an insurer or Owner Booking).';

-- ================================================================ 3. the screen in one read
create or replace function app.fleet_board_car(p_vehicle uuid) returns jsonb
language sql stable security definer set search_path = public, app as $$
  select jsonb_build_object('id', v.id, 'name', app.vehicle_name(v.id), 'code', v.car_code, 'plate', v.plate, 'colour', v.colour,
    'photo', (select jsonb_build_object('path', ph.processed_path, 'variants', ph.variants, 'alt', ph.alt_text)
                from vehicle_photos ph where ph.vehicle_id = v.id and ph.is_cover and ph.status = 'approved' and ph.replaced_at is null
                 and ph.processed_path is not null order by ph.is_public desc limit 1))
    from vehicles v where v.id = p_vehicle
$$;

create or replace function app.fleet_board(p_now timestamptz default now()) returns jsonb
language plpgsql stable security definer set search_path = public, app as $$
declare
  v_today date := (p_now at time zone 'America/Toronto')::date;
  s program_settings := app.settings();
  v_out jsonb;
begin
  with live as (
    select b.*, app.booking_pay_schedule(b.id, p_now) as pay,
           (b.return_at at time zone 'America/Toronto')::date as ret_day,
           (b.pickup_at at time zone 'America/Toronto')::date as pick_day,
           -- out: on rent, or confirmed with its pickup time passed and no check-out recorded (the car is most likely
           -- out; the screen says "pickup not recorded" so staff fix the record)
           (b.status::text = 'on_rent' or (b.status::text = 'confirmed' and b.pickup_at <= p_now and b.handed_over_at is null
              and not exists (select 1 from condition_reports c where c.booking_id = b.id and c.kind = 'pickup' and c.completed_at is not null))) as out0,
           (b.status::text = 'confirmed' and b.pickup_at <= p_now and b.handed_over_at is null) as unrecorded,
           -- ended, never closed: confirmed, no check-out, its return time passed and the same car went out again after it
           (b.status::text = 'confirmed' and b.handed_over_at is null and b.return_at < p_now and exists (
              select 1 from bookings n where n.vehicle_id = b.vehicle_id and n.id <> b.id and not n.is_placeholder
                 and n.pickup_at >= b.return_at - interval '1 hour' and n.pickup_at <= p_now
                 and (n.status::text in ('on_rent', 'returned', 'closed') or (n.status::text = 'confirmed' and n.pickup_at <= p_now)))) as stale
      from bookings b
     where b.status::text in ('confirmed', 'on_rent', 'returned')
       and not coalesce(b.is_placeholder, false) and not app.booking_is_placeholder(b.id)
       and (b.status::text <> 'returned' or b.checked_in_at > p_now - interval '120 days' or b.return_at > p_now - interval '120 days')
  ),
  live2 as (select l.*, l.out0 and not l.stale as is_out from live l),
  card as (
    select l.id,
           jsonb_build_object(
             'booking_id', l.id, 'number', l.booking_number, 'status', l.status, 'type', l.booking_type,
             'car', app.fleet_board_car(l.vehicle_id),
             'renter', (select jsonb_build_object('id', r.id, 'name', r.legal_name, 'phone', r.mobile, 'email', r.email) from renters r where r.id = l.renter_id),
             'pickup_at', coalesce(l.handed_over_at, l.pickup_at), 'booked_pickup_at', l.pickup_at, 'return_at', l.return_at,
             'unrecorded', l.unrecorded and l.is_out,
             'stale', l.stale,
             'bill_to', l.bill_to,
             'due', case when l.is_out and l.return_at < p_now then 'overdue'
                         when l.ret_day = v_today then 'today' when l.ret_day = v_today + 1 then 'tomorrow' else 'later' end,
             'minutes_late', case when l.is_out and l.return_at < p_now then floor(extract(epoch from p_now - l.return_at) / 60)::integer end,
             'backdated', coalesce(l.added_mode in ('past', 'in_progress'), false),
             'pickup_kind', coalesce(l.pickup_location_kind, case when l.pickup_method = 'delivered' then 'delivery' else 'our_location' end),
             'return_kind', coalesce(l.return_location_kind, case when l.return_method = 'delivered' then 'delivery' else 'our_location' end),
             'pickup_place', l.pickup_place, 'return_place', l.return_place,
             'pay', l.pay,
             'deposit', jsonb_build_object(
                'required_cents', coalesce(l.deposit_cents, 0),
                'waived', l.deposit_waived_at is not null,
                'held_cents', coalesce((select sum(d.amount_cents - d.applied_cents - d.released_cents) from deposits d
                                         where d.booking_id = l.id and d.status in ('held', 'captured')), 0),
                'how', (select case when d.method = 'offline' then d.paid_method when d.method = 'card_hold' then 'card_hold' else d.method end from deposits d
                          where d.booking_id = l.id and d.status in ('held', 'captured') order by d.created_at desc limit 1)),
             'km_out', coalesce((select c.odometer_km from condition_reports c where c.booking_id = l.id and c.kind = 'pickup' and c.odometer_km is not null order by c.performed_at desc nulls last limit 1), l.odometer_out_km),
             'fuel_out', coalesce((select c.fuel_pct from condition_reports c where c.booking_id = l.id and c.kind = 'pickup' and c.fuel_pct is not null order by c.performed_at desc nulls last limit 1), l.fuel_out_pct),
             'field_staff', (select array_agg(j.assigned_to) from field_jobs j where j.booking_id = l.id and j.status <> 'cancelled' and j.assigned_to is not null)
           ) as j
      from live2 l
  ),
  going as (
    select l.id, l.pickup_at, c.j || jsonb_build_object(
             'late_pickup', l.pickup_at < p_now,
             'ready', (select jsonb_build_object(
                 'licence', coalesce((e ->> 'licence')::boolean, false),
                 'agreement', coalesce((e ->> 'agreement')::boolean, false),
                 'paid', case when (l.pay ->> 'state') in ('none', 'paid') then true
                              else coalesce((l.pay #>> '{next,due_at}')::timestamptz > l.pickup_at, false) end,
                 'deposit', case when coalesce((e ->> 'deposit')::boolean, false) then 'yes'
                                 when s.deposit_timing = 'pickup_day' and l.pick_day > v_today and coalesce(l.deposit_pay_method, 'card') = 'card'
                                      and l.card_on_file_id is not null then 'scheduled'
                                 else 'no' end,
                 'photos', coalesce((e ->> 'checkout_photos')::boolean, false))
               from (select app.handover_essentials(l.id) as e) z)) as j
      from live2 l join card c on c.id = l.id
     where l.status::text = 'confirmed' and not l.is_out and l.pickup_at <= p_now + interval '72 hours' and l.return_at > p_now
  )
  select jsonb_build_object(
    'at', p_now, 'today', v_today,
    -- overdue returns first, then by the time each is due back
    'out', coalesce((select jsonb_agg(c.j order by (l.return_at < p_now) desc, l.return_at) from live2 l join card c on c.id = l.id where l.is_out), '[]'::jsonb),
    'going', coalesce((select jsonb_agg(g.j order by g.pickup_at) from going g), '[]'::jsonb),
    'stale', coalesce((select jsonb_agg(c.j order by l.return_at) from live2 l join card c on c.id = l.id where l.stale), '[]'::jsonb),
    'back', coalesce((select jsonb_agg(c.j order by l.return_at) from live2 l join card c on c.id = l.id
                       where l.is_out and (l.return_at < p_now or l.ret_day <= v_today + 1)), '[]'::jsonb),
    'money', coalesce((select jsonb_agg(c.j order by (l.pay #>> '{next,due_at}')::timestamptz) from live2 l join card c on c.id = l.id
                        where (l.pay ->> 'state') in ('overdue', 'soon', 'upcoming') and (l.pay #>> '{next,due_at}')::timestamptz <= p_now + interval '7 days'), '[]'::jsonb),
    'cars', coalesce((select jsonb_agg(x.j order by x.rank, x.idle_since nulls first, x.code) from (
        select v.car_code as code,
               case when v.status::text in ('cleaning', 'out_of_service') or blk.id is not null then 1 else 0 end as rank,
               idle.at as idle_since,
               app.fleet_board_car(v.id) || jsonb_build_object(
                 'state', case when v.status::text in ('cleaning', 'out_of_service') or blk.id is not null then 'maintenance' else 'free' end,
                 'why', case when blk.id is not null then blk.reason when v.status::text in ('cleaning', 'out_of_service') then v.status::text end,
                 'note', blk.note, 'until', blk.ends_at,
                 'idle_since', idle.at,
                 'idle_days', case when idle.at is not null then greatest(v_today - (idle.at at time zone 'America/Toronto')::date, 0) end,
                 'next', (select jsonb_build_object('booking_id', nb.id, 'number', nb.booking_number, 'pickup_at', nb.pickup_at)
                            from bookings nb where nb.vehicle_id = v.id and nb.status::text = 'confirmed' and nb.pickup_at > p_now
                             and not app.booking_is_placeholder(nb.id) order by nb.pickup_at limit 1)) as j
          from vehicles v
          left join lateral (select k.* from vehicle_calendar_blocks k
                              where k.vehicle_id = v.id and k.removed_at is null and k.reason in ('service', 'repair', 'cleaning')
                                and k.starts_at <= p_now and (k.ends_at is null or k.ends_at > p_now)
                              order by k.starts_at desc limit 1) blk on true
          left join lateral (select max(coalesce(pb.checked_in_at, pb.return_at)) as at from bookings pb
                              where pb.vehicle_id = v.id and pb.status::text in ('returned', 'closed') and not app.booking_is_placeholder(pb.id)) idle on true
         where v.retired_at is null and not coalesce(v.is_sample, false)
           and v.status::text in ('available', 'cleaning', 'out_of_service')
           -- a partner's car (0046) is on request from the partner, not parked here: counted apart
           and coalesce(v.supply_type, '') <> 'partner'
           -- away on another platform, with the owner or leaving: not free and not in the shop
           and not exists (select 1 from vehicle_calendar_blocks k2 where k2.vehicle_id = v.id and k2.removed_at is null
                             and k2.reason in ('external_booking', 'turo_owner_use', 'owner_unavailable', 'exit')
                             and k2.starts_at <= p_now and (k2.ends_at is null or k2.ends_at > p_now))
           and not exists (select 1 from bookings ob where ob.vehicle_id = v.id and ob.status::text = 'on_rent')
           and not exists (select 1 from bookings cb where cb.vehicle_id = v.id and cb.status::text = 'confirmed' and cb.blocks_calendar
                             and cb.pickup_at <= p_now and cb.return_at > p_now and not app.booking_is_placeholder(cb.id))) x), '[]'::jsonb)
  ) into v_out;

  return v_out || jsonb_build_object('summary', jsonb_build_object(
    'out', jsonb_array_length(v_out -> 'out'),
    'stale', jsonb_array_length(v_out -> 'stale'),
    'unrecorded', (select count(*) from jsonb_array_elements(v_out -> 'out') x where (x ->> 'unrecorded')::boolean),
    'due_today', (select count(*) from jsonb_array_elements(v_out -> 'out') x where x ->> 'due' = 'today'),
    'overdue', (select count(*) from jsonb_array_elements(v_out -> 'out') x where x ->> 'due' = 'overdue'),
    'going', jsonb_array_length(v_out -> 'going'),
    'money', jsonb_array_length(v_out -> 'money'),
    'money_cents', coalesce((select sum((x #>> '{pay,next,cents}')::bigint) from jsonb_array_elements(v_out -> 'money') x), 0),
    'money_overdue', (select count(*) from jsonb_array_elements(v_out -> 'money') x where x #>> '{pay,state}' = 'overdue'),
    'free', (select count(*) from jsonb_array_elements(v_out -> 'cars') x where x ->> 'state' = 'free'),
    'maintenance', (select count(*) from jsonb_array_elements(v_out -> 'cars') x where x ->> 'state' = 'maintenance'),
    'partner_cars', (select count(*) from vehicles v where v.retired_at is null and not coalesce(v.is_sample, false) and v.supply_type = 'partner'
                       and v.status::text = 'available' and coalesce(v.bookings_enabled, true))));
end $$;
comment on function app.fleet_board(timestamptz) is 'Bookings > Now (0330): out now, going out in 72 hours with readiness, coming back, money due in 7 days or overdue, free cars and the summary. Placeholders are left out. Toronto days.';

-- who reads it, and what they see
create or replace function app.bookings_now_read(p_by uuid, p jsonb default '{}'::jsonb) returns jsonb
language plpgsql stable security definer set search_path = public, app as $$
declare
  v_full boolean := app.user_is_admin(p_by) or app.user_va_has(p_by, 'fleet', 'cs');
  v_field boolean := app.user_is_field(p_by);
  d jsonb;
  k text;
begin
  if not v_full and not v_field then
    raise exception 'Admins, fleet, customer service and field staff only' using errcode = '42501';
  end if;
  d := app.fleet_board(now());
  d := d || jsonb_build_object('scope', case when v_full then 'full' else 'field' end);
  if v_full then
    -- the list of field staff ids is only for the field view
    foreach k in array array['out', 'going', 'back', 'money', 'stale'] loop
      d := jsonb_set(d, array[k], coalesce((select jsonb_agg(x - 'field_staff') from jsonb_array_elements(d -> k) x), '[]'::jsonb));
    end loop;
    return d;
  end if;
  -- field staff: the cars, no money; the renter's phone and email only on their own jobs
  d := d - 'money';
  d := jsonb_set(d, '{summary}', (d -> 'summary') - 'money' - 'money_cents' - 'money_overdue');
  d := d - 'stale';
  foreach k in array array['out', 'going', 'back'] loop
    d := jsonb_set(d, array[k], coalesce((select jsonb_agg(
            (x - 'pay' - 'deposit' - 'field_staff')
            || jsonb_build_object('renter', case when coalesce(x -> 'field_staff', '[]'::jsonb) ? p_by::text then x -> 'renter'
                                                 else (x -> 'renter') - 'phone' - 'email' end)
            || case when x ? 'ready' then jsonb_build_object('ready', (x -> 'ready') - 'paid') else '{}'::jsonb end)
          from jsonb_array_elements(d -> k) x), '[]'::jsonb));
  end loop;
  return d;
end $$;

-- the plan, set on the booking page
create or replace function app.booking_pay_every_set(p_by uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  b bookings;
  v_new text := nullif(btrim(coalesce(p ->> 'pay_every', '')), '');
begin
  if not (app.user_is_admin(p_by) or app.user_va_has(p_by, 'cs', 'finance')) then
    raise exception 'Admins, customer service and finance only' using errcode = '42501';
  end if;
  if v_new = 'auto' then v_new := null; end if;
  if v_new is not null and v_new not in ('whole', 'weekly', 'biweekly', 'monthly') then
    raise exception 'Choose whole, weekly, biweekly or monthly' using errcode = '22023';
  end if;
  select * into b from bookings where id = (p ->> 'booking')::uuid for update;
  if b.id is null then raise exception 'Booking not found' using errcode = 'P0002'; end if;
  if b.status::text in ('closed', 'cancelled', 'declined', 'expired') then
    raise exception 'This booking is %; its payment plan no longer changes', b.status using errcode = '22023';
  end if;
  if b.pay_every is not distinct from v_new then return jsonb_build_object('ok', true, 'changed', false, 'pay', app.booking_pay_schedule(b.id)); end if;
  update bookings set pay_every = v_new where id = b.id;
  insert into booking_events (booking_id, kind, note, details, actor_type, actor_user_id)
  values (b.id, 'adjusted', format('Payment plan: %s', coalesce(v_new, 'automatic')),
          jsonb_build_object('pay_every', jsonb_build_object('before', b.pay_every, 'after', v_new)), 'staff', p_by);
  return jsonb_build_object('ok', true, 'changed', true, 'pay', app.booking_pay_schedule(b.id));
end $$;

-- the plan on the booking page, by the booking's id or number
create or replace function app.booking_pay_plan_read(p_by uuid, p jsonb) returns jsonb
language plpgsql stable security definer set search_path = public, app as $$
declare
  v_id uuid;
begin
  if not (app.user_is_admin(p_by) or app.user_va_has(p_by, 'cs', 'fleet', 'finance')) then
    raise exception 'Admins, customer service, fleet and finance only' using errcode = '42501';
  end if;
  select b.id into v_id from bookings b
   where b.booking_number = p ->> 'booking' or (p ->> 'booking' ~* '^[0-9a-f-]{36}$' and b.id = (p ->> 'booking')::uuid);
  if v_id is null then raise exception 'Booking not found' using errcode = 'P0002'; end if;
  return app.booking_pay_schedule(v_id, now()) || jsonb_build_object('may_change', app.user_is_admin(p_by) or app.user_va_has(p_by, 'cs', 'finance'));
end $$;

-- Ended, never closed: one tap records what happened through the record-now path of 0195 (the pickup at the booked
-- pickup time, then the return at the booked return time; photos, km and fuel later, Fleet gets the task). Its guards
-- stay (deposit, signature, agreement, every driver verified, coverage); a refusal comes back as worded.
create or replace function app.booking_close_ended(p_by uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  b bookings;
  v_reason text := coalesce(nullif(btrim(coalesce(p ->> 'reason', '')), ''), 'Ended, never closed: recorded from Bookings > Now');
begin
  select * into b from bookings where id::text = p ->> 'booking' or booking_number = upper(btrim(coalesce(p ->> 'booking', '')));
  if b.id is null then raise exception 'Booking not found' using errcode = 'P0002'; end if;
  if b.status::text <> 'confirmed' or b.handed_over_at is not null or b.return_at >= now() then
    raise exception 'Booking % has not ended without a check-out (it is %)', b.booking_number, replace(b.status::text, '_', ' ') using errcode = '23514';
  end if;
  perform app.handover_record_now(p_by, (p - 'reason') || jsonb_build_object('booking', b.id, 'kind', 'pickup', 'at', b.pickup_at, 'reason', v_reason));
  perform app.handover_record_now(p_by, jsonb_build_object('booking', b.id, 'kind', 'return', 'at', b.return_at, 'reason', v_reason));
  return jsonb_build_object('ok', true, 'booking_status', (select status from bookings where id = b.id));
end $$;

-- ================================================================ 4. the door
alter function app.door(uuid, text, text, text, jsonb) rename to door_pre0330;
create function app.door(p_user uuid, p_aal text, p_call text, p_name text, p jsonb default '{}'::jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
begin
  if p_call in ('ops_read', 'field_read') and p_name = 'bookings_now' then
    if coalesce(p, '{}'::jsonb) ? '_va' then perform set_config('app.va_active', coalesce(p ->> '_va', ''), true); end if;
    perform app.door_begin(p_user, p_aal);
    return app.bookings_now_read(p_user, coalesce(p, '{}'::jsonb) - '_va');
  end if;
  if p_call = 'ops_read' and p_name = 'booking_pay_plan' then
    if coalesce(p, '{}'::jsonb) ? '_va' then perform set_config('app.va_active', coalesce(p ->> '_va', ''), true); end if;
    perform app.door_begin(p_user, p_aal);
    return app.booking_pay_plan_read(p_user, coalesce(p, '{}'::jsonb) - '_va');
  end if;
  if p_call = 'ops_do' and p_name = 'booking_close_ended' then
    if coalesce(p, '{}'::jsonb) ? '_va' then perform set_config('app.va_active', coalesce(p ->> '_va', ''), true); end if;
    perform app.door_begin(p_user, p_aal);
    return app.booking_close_ended(p_user, coalesce(p, '{}'::jsonb) - '_va');
  end if;
  if p_call in ('ops_do', 'admin_do') and p_name = 'booking_pay_every' then
    if coalesce(p, '{}'::jsonb) ? '_va' then perform set_config('app.va_active', coalesce(p ->> '_va', ''), true); end if;
    perform app.door_begin(p_user, p_aal);
    return app.booking_pay_every_set(p_user, coalesce(p, '{}'::jsonb) - '_va');
  end if;
  return app.door_pre0330(p_user, p_aal, p_call, p_name, p);
end $$;
select pg_temp.copy_grants('app.door(uuid, text, text, text, jsonb)'::regprocedure, 'app.door_pre0330(uuid, text, text, text, jsonb)'::regprocedure);

-- ================================================================ privileges
do $$
declare f record;
begin
  for f in select p.oid::regprocedure as sig from pg_proc p join pg_namespace n on n.oid = p.pronamespace
            where n.nspname = 'app' and p.proname in ('booking_pay_schedule', 'fleet_board', 'fleet_board_car', 'bookings_now_read', 'booking_pay_every_set', 'booking_pay_plan_read', 'booking_close_ended', 'door_pre0330') loop
    execute format('revoke all on function %s from public, anon, authenticated', f.sig);
    execute format('grant execute on function %s to service_role', f.sig);
  end loop;
end $$;
