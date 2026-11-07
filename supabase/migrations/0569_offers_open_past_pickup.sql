-- 0569 (r28 P0): an offer sent for a pickup time already past no longer expires on the next job tick.
-- 0332 made the offers job expire an offer once its pickup time passed (b.pickup_at <= p_now). After the Nov 6 outage
-- many requests were past their pickup time, so every offer staff sent for them flipped to "expired" at once and the
-- renter could not accept it.
--   1. An offer expires at its offer_expires_at. The pickup only counts when the offer was sent before the pickup and
--      the pickup has been past for 2 hours or more (app.expire_offers and app.job_offers_expire, the same rule).
--   2. Repair: every booking this rule expired since 2026-11-05 whose offer was sent after its pickup, or whose own
--      expiry is still ahead, is offered again: booking 'offered', its offer 'sent', offer_expires_at the later of the
--      original expiry and now + 24 hours; a booking event; the open offer_expired To do resolved. No email from here
--      (staff update the pickup time and send it again from the booking). The count is raised as a NOTICE for the
--      deploy log and kept in app_migration_notes when that table exists.
-- No applied migration is edited.

create function pg_temp.patch_fn(p_sig regprocedure, p_old text, p_new text) returns void
language plpgsql as $$
declare
  d text := pg_get_functiondef(p_sig);
begin
  if position(p_old in d) = 0 then
    raise exception '0569: the text to change was not found in %: %', p_sig, left(p_old, 120);
  end if;
  execute replace(d, p_old, p_new);
end $$;

-- the offer's own sending time (the current version), for the pickup rule
create or replace function app.offer_sent_at(p_booking uuid, p_version integer) returns timestamptz
language sql stable security definer set search_path = public, app as $$
  select coalesce(o.sent_at, o.created_at) from booking_offers o where o.booking_id = p_booking and o.version = p_version
$$;
revoke all on function app.offer_sent_at(uuid, integer) from public, anon, authenticated;
grant execute on function app.offer_sent_at(uuid, integer) to service_role;
comment on function app.offer_sent_at(uuid, integer) is 'When the offer version was sent (0569): the pickup only expires an offer sent before it.';

select pg_temp.patch_fn('app.expire_offers(timestamptz)'::regprocedure,
  $o$least(b.offer_expires_at, b.pickup_at) as offer_expires_at$o$,
  $n$case when b.offer_expires_at <= p_now then b.offer_expires_at else least(b.offer_expires_at, b.pickup_at) end as offer_expires_at$n$);
select pg_temp.patch_fn('app.expire_offers(timestamptz)'::regprocedure,
  $o$where b.status = 'offered' and (b.offer_expires_at <= p_now or b.pickup_at <= p_now)$o$,
  $n$where b.status = 'offered' and (b.offer_expires_at <= p_now
                   or (b.pickup_at <= p_now - interval '2 hours' and coalesce(app.offer_sent_at(b.id, b.current_offer_version), '-infinity') < b.pickup_at))$n$);
select pg_temp.patch_fn('app.job_offers_expire(timestamptz)'::regprocedure,
  $o$if not exists (select 1 from bookings b where b.status = 'offered' and (b.offer_expires_at <= p_now or b.pickup_at <= p_now))$o$,
  $n$if not exists (select 1 from bookings b where b.status = 'offered' and (b.offer_expires_at <= p_now
                     or (b.pickup_at <= p_now - interval '2 hours' and coalesce(app.offer_sent_at(b.id, b.current_offer_version), '-infinity') < b.pickup_at)))$n$);

-- 2. the repair. "expired" to "offered" is allowed only for this repair (the row is removed after it)
insert into status_transitions (entity, from_status, to_status, note)
values ('booking', 'expired', 'offered', '0569: an offer that expired only because its pickup had passed, reopened as it was')
on conflict do nothing;
do $$
declare
  r record;
  n integer := 0;
begin
  for r in
    select b.id, b.booking_number, b.current_offer_version, o.id as offer_id, o.expires_at, coalesce(o.sent_at, o.created_at) as sent_at, b.pickup_at
      from bookings b
      join booking_offers o on o.booking_id = b.id and o.version = b.current_offer_version and o.status = 'expired'
     where b.status = 'expired'
       and exists (select 1 from booking_events e where e.booking_id = b.id and e.kind = 'offer_expired' and e.created_at >= timestamptz '2026-11-05 00:00 America/Toronto')
       and (coalesce(o.sent_at, o.created_at) >= b.pickup_at or o.expires_at > now())
     order by b.id
     for update of b
  loop
    update booking_offers set status = 'sent', responded_at = null where id = r.offer_id;
    update bookings set status = 'offered', offer_expires_at = greatest(r.expires_at, now() + interval '24 hours') where id = r.id;
    perform app.log_booking_event(r.id, 'reopened', 'expired', 'offered', r.current_offer_version,
      format('Offer version %s reopened (0569): it had expired only because its pickup time had passed. Update the pickup time before the renter accepts.', r.current_offer_version),
      null, 'system');
    perform app.resolve_tasks(array['offer_expired'], r.id, null, 'Offer reopened (0569)', false);
    n := n + 1;
  end loop;
  raise notice '0569: % booking(s) reopened', n;
  delete from status_transitions where entity = 'booking' and from_status = 'expired' and to_status = 'offered';
  if to_regclass('public.app_migration_notes') is not null then
    execute 'insert into app_migration_notes (migration, note) values ($1, $2)' using '0569', format('%s booking(s) reopened', n);
  end if;
end $$;

-- ================================================================ 3. staff: Reopen offer, one click (0569)
-- reopen_expired (Admin, Customer service and now Sales): the request reopens (app.reopen_expired_request: the event and
-- the offer_expired To do resolved), the new pickup and return when given, re-priced, and a new offer version sent
-- (the usual "offer ready" email and text) open for p.hours (default 24). A pickup already past needs new dates first.
create or replace function app.reopen_offer(p_booking uuid, p_by uuid, p jsonb default '{}'::jsonb) returns integer
language plpgsql security definer set search_path = public, app as $$
declare
  b bookings;
  v_pick timestamptz := nullif(p ->> 'pickup_at', '')::timestamptz;
  v_ret timestamptz := nullif(p ->> 'return_at', '')::timestamptz;
  v_hours integer := coalesce(nullif(p ->> 'hours', '')::numeric::integer, 24);
begin
  select * into b from bookings where id = p_booking for update;
  if b.id is null then raise exception 'Booking not found' using errcode = 'P0002'; end if;
  if b.status <> 'expired' then raise exception 'Booking % is %: only an expired offer is reopened', b.booking_number, b.status using errcode = '23514'; end if;
  if v_hours < 1 or v_hours > 336 then raise exception 'Open for 1 to 336 hours' using errcode = '22023'; end if;
  if (v_pick is null) <> (v_ret is null) then raise exception 'Give both the new pickup and the new return' using errcode = '22023'; end if;
  if coalesce(v_pick, b.pickup_at) <= now() then
    raise exception 'The pickup time has passed: give a new pickup and return before reopening' using errcode = '22023';
  end if;
  if v_ret is not null and v_ret <= v_pick then raise exception 'The return must be after the pickup' using errcode = '22023'; end if;
  perform app.reopen_expired_request(p_booking, p_by, nullif(btrim(coalesce(p ->> 'note', '')), ''));
  if v_pick is not null then
    update bookings set pickup_at = v_pick, return_at = v_ret, billable_days = calc_billable_days(v_pick, v_ret),
                        km_allowance_total = km_allowance_per_day * calc_billable_days(v_pick, v_ret) where id = p_booking;
    perform app.log_booking_event(p_booking, 'adjusted', 'requested', 'requested', b.current_offer_version,
      format('New dates to reopen the offer: %s to %s (Toronto)', to_char(v_pick at time zone 'America/Toronto', 'YYYY-MM-DD HH24:MI'),
             to_char(v_ret at time zone 'America/Toronto', 'YYYY-MM-DD HH24:MI')), p_by, 'staff');
  end if;
  select * into b from bookings where id = p_booking;
  if not app.vehicle_is_available(b.vehicle_id, b.pickup_at, b.return_at, b.id) then
    raise exception 'The car is no longer free for these dates: choose other dates or another car' using errcode = '23P01';
  end if;
  perform app.reprice_booking(p_booking);
  return app.send_offer(p_booking, p_by, nullif(btrim(coalesce(p ->> 'note', '')), ''), now() + make_interval(hours => v_hours));
end $$;
revoke all on function app.reopen_offer(uuid, uuid, jsonb) from public, anon, authenticated;
grant execute on function app.reopen_offer(uuid, uuid, jsonb) to service_role;
comment on function app.reopen_offer(uuid, uuid, jsonb) is 'Reopen an expired offer in one click (0569): new dates when the pickup has passed, re-priced, a new version sent, open p.hours (24).';

select pg_temp.patch_fn('app.admin_do_0030(uuid, text, jsonb)'::regprocedure,
  $o$perform app.reopen_expired_offer(b.id, p_admin, nullif(btrim(p_ ->> 'note'), ''));$o$,
  $n$return jsonb_build_object('version', app.reopen_offer(b.id, p_admin, p_));$n$);
-- Sales sends offers, so Sales reopens them too (Customer service already could)
select pg_temp.patch_fn('app.va_do_pre0071(uuid, text, jsonb)'::regprocedure,
  $o$when 'sales' then array['booking_save', 'send_offer', 'withdraw_offer', 'resend_offer', 'approve_offer_by_phone', 'ask_info', 'decline_request'$o$,
  $n$when 'sales' then array['booking_save', 'send_offer', 'withdraw_offer', 'resend_offer', 'approve_offer_by_phone', 'ask_info', 'decline_request', 'reopen_expired'$n$);

-- ================================================================ 4. the renter: Ask to reopen this offer (0569)
-- From the expired offer page (signed in) or /my-request (this device's unverified session, checked by the server
-- first): a To do "Renter wants expired offer reopened" for the requests team, alerted as a new lead is, once per 6 hours.
insert into staff_alert_rules (rule, label, grp, who, tier, topic, enabled, wired, fixed, hint, sort)
select 'staff_offer_reopen_ask', 'Renter wants expired offer reopened', grp, who, tier, topic, enabled, true, fixed,
       'A renter asked from their expired offer page to reopen it (0569).', sort + 1
  from staff_alert_rules where rule = 'staff_lead_new'
on conflict (rule) do nothing;

create or replace function public.server_renter_ask_reopen(p_number text, p_by uuid default null, p_pickup timestamptz default null) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  b bookings;
  v_task uuid;
begin
  select * into b from bookings where booking_number = p_number;
  if b.id is null then raise exception 'Booking not found' using errcode = 'P0002'; end if;
  -- signed in: the booking must be theirs; without (p_by null) the server checked this device's session first
  if p_by is not null then perform app.assert_booking_renter(b.id, p_by); end if;
  if b.status <> 'expired' then raise exception 'This offer is not expired' using errcode = '23514'; end if;
  if exists (select 1 from tasks t where t.booking_id = b.id and t.task_type = 'offer_reopen_ask' and t.created_at > now() - interval '6 hours') then
    return jsonb_build_object('ok', true, 'already', true);
  end if;
  if p_pickup is not null and p_pickup <= now() then raise exception 'Choose a pickup time in the future' using errcode = '22023'; end if;
  v_task := app.raise_task(p_type => 'offer_reopen_ask',
      p_title => format('Booking %s: Renter wants expired offer reopened', b.booking_number),
      p_detail => case when p_pickup is not null then format('The renter asks to reopen the offer with a pickup at %s (Toronto). Reopen offer on the booking.', to_char(p_pickup at time zone 'America/Toronto', 'YYYY-MM-DD HH24:MI'))
                       else 'The renter asks to reopen the offer. Reopen offer on the booking (new dates if the pickup has passed).' end,
      p_booking => b.id, p_vehicle => b.vehicle_id, p_renter => b.renter_id, p_priority => 'high', p_queue => 'cs',
      p_dedupe => format('offer_reopen_ask:%s:%s', b.id, floor(extract(epoch from now()) / 21600)::bigint));
  perform app.staff_alert('staff_offer_reopen_ask', 'booking', b.id, 'ask:' || floor(extract(epoch from now()) / 21600)::bigint,
    format('Renter wants expired offer reopened: %s', b.booking_number),
    case when p_pickup is not null then format('New pickup asked: %s', to_char(p_pickup at time zone 'America/Toronto', 'Mon DD HH24:MI')) else 'Reopen it from the booking.' end,
    jsonb_build_object('path_admin', '/admin/bookings/' || b.booking_number, 'path_staff', '/staff/bookings/' || b.booking_number));
  return jsonb_build_object('ok', true, 'already', false, 'task_id', v_task);
end $$;
revoke all on function public.server_renter_ask_reopen(text, uuid, timestamptz) from public, anon, authenticated;
grant execute on function public.server_renter_ask_reopen(text, uuid, timestamptz) to service_role;
comment on function public.server_renter_ask_reopen(text, uuid, timestamptz) is 'The renter asks to reopen an expired offer (0569): a To do and an alert to the requests team, once per 6 hours.';

-- Sales may reopen an expired offer (and only that, of the expired bookings)
select pg_temp.patch_fn('app.va_do_pre0071(uuid, text, jsonb)'::regprocedure,
  $o$if v_fn = 'sales' and b.status not in ('requested', 'offered') then$o$,
  $n$if v_fn = 'sales' and b.status not in ('requested', 'offered') and not (b.status = 'expired' and p_action = 'reopen_expired') then$n$);
