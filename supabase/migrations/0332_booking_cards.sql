-- 0332: the rows of Requests and offers, All bookings and the Calendar, in the Now view's design (Release 26 part 2,
-- docs/changes/2026-11-06-bookings-now.md). The owner: "Requests still needs a revamp. And so does all booking and
-- calendar ... And this should edit the staff's corresponding versions of these portals too". SCHEMA_MARKER 0333 (0333 carries the guide chapters).
--
-- 1. app.booking_cards(by, {ids}): for up to 300 bookings the lists already show, what a row needs that the lists did
--    not carry: the car (photo, code, plate), the renter's mobile, the licence (verified, waiting for review, or not
--    uploaded), the money (paid, due, overdue, insurer billed, from app.booking_pay_schedule) and Bill to. Who may read it
--    is who already reads those lists: Admins and office staff (customer service, fleet, finance, sales). Door: ops_read
--    booking_cards. Nothing is shown that the booking page does not already show them.
-- 2. app.car_thumbs(by, {ids}): each car's cover photo, code and plate for the Calendar's rows. Admins and every staff
--    member who opens a calendar. Door: ops_read car_thumbs.
-- 3. app.my_bookings(by): a staff member's own bookings, for Rentals > Bookings (the owner, viewing a salesperson's portal:
--    "unable to see his bookings"): the ones they are credited with (bookings.sales_staff_id) or sent the offer for or
--    added by hand, from the offer on (offered, waiting for payment, booked, out, returned, closed), never placeholders,
--    each with its row (0332's card) and the commission (counting this month, waiting for approval, approved, paid,
--    reversed). Door: ops_read my_bookings; every office function, their own only.
-- 4. Requests that cannot be acted on leave the active queue by themselves: an offer still out when its pickup time
--    passes expires as an unanswered one does (app.expire_offers, run by the offers job), and an expired offer's
--    expiry time is on its row (expired_at) so the list moves it to the quiet Expired filter after 48 hours.
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

create or replace function app.uuid_list(p jsonb, p_max integer) returns uuid[]
language sql immutable as $$
  select coalesce(array_agg(x::uuid), '{}') from (
    select x from jsonb_array_elements_text(case when jsonb_typeof(p) = 'array' then p else '[]'::jsonb end) x
     where x ~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$' limit p_max) s
$$;

create or replace function app.booking_cards(p_by uuid, p jsonb) returns jsonb
language plpgsql stable security definer set search_path = public, app as $$
declare
  v_ids uuid[] := app.uuid_list(p -> 'ids', 300);
begin
  if not (app.user_is_admin(p_by) or app.user_va_has(p_by)) then
    raise exception 'Admins and office staff only' using errcode = '42501';
  end if;
  return coalesce((select jsonb_object_agg(b.id, jsonb_build_object(
      'car', app.fleet_board_car(b.vehicle_id),
      'phone', r.mobile,
      'licence', case when exists (select 1 from booking_drivers d where d.booking_id = b.id and d.role = 'renter' and d.identity_verified_on is not null) then 'verified'
                      when exists (select 1 from booking_drivers d join drivers dr on dr.id = d.driver_id where d.booking_id = b.id and d.role = 'renter' and dr.identity_status = 'verified') then 'verified'
                      when exists (select 1 from booking_drivers d join drivers dr on dr.id = d.driver_id where d.booking_id = b.id and d.role = 'renter' and dr.identity_status = 'pending') then 'pending'
                      when r.identity_status = 'verified' then 'verified'
                      when r.identity_status = 'pending' then 'pending'
                      else 'missing' end,
      'bill_to', b.bill_to,
      'placeholder', coalesce(b.is_placeholder, false),
      'expired_at', case when b.status::text = 'expired' then (select max(e.created_at) from booking_events e where e.booking_id = b.id and e.kind in ('offer_expired', 'request_expired')) end,
      'money', case when b.status::text in ('confirmed', 'on_rent', 'returned') then
                 (select jsonb_build_object('state', s ->> 'state', 'plan', s ->> 'plan', 'open_cents', (s ->> 'open_cents')::bigint,
                                            'next_cents', (s #>> '{next,cents}')::bigint, 'next_at', s #>> '{next,due_at}')
                    from (select app.booking_pay_schedule(b.id, now()) as s) z) end))
    from bookings b left join renters r on r.id = b.renter_id
   where b.id = any (v_ids)), '{}'::jsonb);
end $$;
comment on function app.booking_cards(uuid, jsonb) is 'The rows of Requests and offers and All bookings (0332): car photo, renter mobile, licence, money and Bill to, for bookings the caller''s lists already show.';

create or replace function app.car_thumbs(p_by uuid, p jsonb) returns jsonb
language plpgsql stable security definer set search_path = public, app as $$
declare
  v_ids uuid[] := app.uuid_list(p -> 'ids', 500);
begin
  if not (app.user_is_admin(p_by) or app.user_va_has(p_by) or app.user_is_field(p_by)) then
    raise exception 'Admins and staff only' using errcode = '42501';
  end if;
  return coalesce((select jsonb_object_agg(v.id, app.fleet_board_car(v.id)) from vehicles v where v.id = any (v_ids)), '{}'::jsonb);
end $$;

create or replace function app.my_bookings(p_by uuid, p jsonb default '{}'::jsonb) returns jsonb
language plpgsql stable security definer set search_path = public, app as $$
begin
  if not app.user_va_has(p_by) then
    raise exception 'Office staff only' using errcode = '42501';
  end if;
  return coalesce((select jsonb_agg(x.j order by x.rank, x.pickup_at desc) from (
    select b.pickup_at,
           case b.status::text when 'on_rent' then 0 when 'confirmed' then 1 when 'pending_payment' then 2 when 'offered' then 3 when 'returned' then 4 else 5 end as rank,
           jsonb_build_object('id', b.id, 'booking_number', b.booking_number, 'status', b.status, 'vehicle_name', app.vehicle_name(b.vehicle_id),
             'renter_name', r.legal_name, 'pickup_at', b.pickup_at, 'return_at', b.return_at, 'total_due_at_booking_cents', b.total_due_at_booking_cents,
             'bill_to', b.bill_to, 'blocks_calendar', b.blocks_calendar,
             'how', case when b.sales_staff_id = p_by then 'credited' when b.created_by = p_by then 'added' else 'offer' end,
             'commission', (select jsonb_build_object('status', c.status, 'amount_cents', c.amount_cents, 'base_cents', c.base_cents, 'rate_bps', c.rate_bps)
                              from staff_commissions c where c.booking_id = b.id and c.staff_id = p_by and c.kind = 'commission' order by c.created_at desc limit 1)) as j
      from bookings b left join renters r on r.id = b.renter_id
     where b.status::text in ('offered', 'pending_payment', 'confirmed', 'on_rent', 'returned', 'closed')
       and not coalesce(b.is_placeholder, false) and b.booking_type <> 'owner'
       and (b.sales_staff_id = p_by or b.created_by = p_by
            or exists (select 1 from booking_offers o where o.booking_id = b.id and o.sent_by = p_by))
       and (b.status::text not in ('returned', 'closed') or b.return_at > now() - interval '120 days')
     order by b.pickup_at desc limit 200) x), '[]'::jsonb);
end $$;
comment on function app.my_bookings(uuid, jsonb) is 'A staff member''s own bookings (0332): credited, offered or added by them, with the commission.';

-- 4. an offer still out when its pickup time passes expires (the offers job runs app.expire_offers)
create function pg_temp.patch_fn(p_sig regprocedure, p_old text, p_new text) returns void
language plpgsql as $$
declare
  d text := pg_get_functiondef(p_sig);
begin
  if position(p_old in d) = 0 then
    raise exception '0332: the text to change was not found in %: %', p_sig, left(p_old, 120);
  end if;
  execute replace(d, p_old, p_new);
end $$;
select pg_temp.patch_fn('app.expire_offers(timestamptz)'::regprocedure,
  $o$  for r in select b.id, b.booking_number, b.current_offer_version, b.vehicle_id, b.renter_id, b.offer_expires_at
             from bookings b
            where b.status = 'offered' and b.offer_expires_at <= p_now$o$,
  $n$  for r in select b.id, b.booking_number, b.current_offer_version, b.vehicle_id, b.renter_id, least(b.offer_expires_at, b.pickup_at) as offer_expires_at
             from bookings b
            where b.status = 'offered' and (b.offer_expires_at <= p_now or b.pickup_at <= p_now)$n$);
select pg_temp.patch_fn('app.job_offers_expire(timestamptz)'::regprocedure,
  $o$  if not exists (select 1 from bookings b where b.status = 'offered' and b.offer_expires_at <= p_now)$o$,
  $n$  if not exists (select 1 from bookings b where b.status = 'offered' and (b.offer_expires_at <= p_now or b.pickup_at <= p_now))$n$);

alter function app.door(uuid, text, text, text, jsonb) rename to door_pre0332;
create function app.door(p_user uuid, p_aal text, p_call text, p_name text, p jsonb default '{}'::jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
begin
  if p_call = 'ops_read' and p_name = 'my_bookings' then
    if coalesce(p, '{}'::jsonb) ? '_va' then perform set_config('app.va_active', coalesce(p ->> '_va', ''), true); end if;
    perform app.door_begin(p_user, p_aal);
    return app.my_bookings(p_user, coalesce(p, '{}'::jsonb) - '_va');
  end if;
  if p_call = 'ops_read' and p_name in ('booking_cards', 'car_thumbs') then
    if coalesce(p, '{}'::jsonb) ? '_va' then perform set_config('app.va_active', coalesce(p ->> '_va', ''), true); end if;
    perform app.door_begin(p_user, p_aal);
    return case p_name when 'booking_cards' then app.booking_cards(p_user, coalesce(p, '{}'::jsonb) - '_va')
                       else app.car_thumbs(p_user, coalesce(p, '{}'::jsonb) - '_va') end;
  end if;
  return app.door_pre0332(p_user, p_aal, p_call, p_name, p);
end $$;
select pg_temp.copy_grants('app.door(uuid, text, text, text, jsonb)'::regprocedure, 'app.door_pre0332(uuid, text, text, text, jsonb)'::regprocedure);

do $$
declare f record;
begin
  for f in select p.oid::regprocedure as sig from pg_proc p join pg_namespace n on n.oid = p.pronamespace
            where n.nspname = 'app' and p.proname in ('uuid_list', 'booking_cards', 'car_thumbs', 'my_bookings', 'door_pre0332') loop
    execute format('revoke all on function %s from public, anon, authenticated', f.sig);
    execute format('grant execute on function %s to service_role', f.sig);
  end loop;
end $$;
