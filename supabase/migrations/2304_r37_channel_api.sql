-- 2304_r37_channel_api.sql (release 37)
-- The Channel API for rental distribution partners (VIPCars, EconomyBookings, Rentalcars.com / Booking.com Cars,
-- CarTrawler, Kayak through connectors). Separate from the Admin API keys of 0562: a partner sees only public listing
-- data and public prices, never a renter, an owner, a plate, a VIN, a cost, utilization or another partner.
--   1. channel_partners: name, status, markup (added to the public price) and commission (what we pay them, for our books
--      only), the classes or cars they may sell (empty: all), calls a minute.
--   2. channel_keys: a key per partner, shown once, kept only as its SHA-256, with scopes availability:read, rates:read and,
--      off by default, bookings:create and bookings:cancel. Revoked at once.
--   3. channel_calls: every call (allowed or refused), visible to Admins.
--   4. public.channel_api(key, call, params): the one entry point (the server's /api/channel/v1 routes, service_role only):
--      the switch (Program setting channel_api_enabled), the key, the partner, the scope, the rate limit, then
--      locations | vehicles | availability | booking_create | booking_cancel. A booking is a normal booking request
--      (public.submit_booking_request): the renter still verifies their licence and every rule applies.

alter table program_settings add column if not exists channel_api_enabled boolean not null default true;
comment on column program_settings.channel_api_enabled is 'Channel API (2304): partners'' keys answer at all. Off: every channel call is refused until it is turned on again.';

create table if not exists channel_partners (
  id               uuid primary key default gen_random_uuid(),
  name             text not null unique check (length(btrim(name)) between 2 and 80),
  status           text not null default 'active' check (status in ('active', 'paused')),
  markup_bps       integer not null default 0 check (markup_bps between 0 and 10000),
  commission_bps   integer not null default 0 check (commission_bps between 0 and 10000),
  allowed_classes  text[] not null default '{}',
  allowed_vehicles uuid[] not null default '{}',
  calls_per_minute integer not null default 60 check (calls_per_minute between 1 and 600),
  created_by       uuid references users (id),
  created_at       timestamptz not null default now()
);
comment on table channel_partners is 'Channel API partners (2304): markup on the public price, commission (ours to pay, never shown to them), the classes or cars they may sell (empty: all), their rate limit.';

create table if not exists channel_keys (
  id           uuid primary key default gen_random_uuid(),
  partner_id   uuid not null references channel_partners (id) on delete cascade,
  prefix       text not null check (length(prefix) between 6 and 24),
  key_hash     text not null unique check (key_hash ~ '^[0-9a-f]{64}$'),
  scopes       text[] not null check (cardinality(scopes) >= 1 and scopes <@ array['availability:read', 'rates:read', 'bookings:create', 'bookings:cancel']),
  created_by   uuid references users (id),
  created_at   timestamptz not null default now(),
  last_used_at timestamptz,
  revoked_at   timestamptz,
  revoked_by   uuid references users (id)
);
comment on table channel_keys is 'Channel API keys (2304): only the SHA-256 is kept; the key is shown once. bookings:create and bookings:cancel are off unless an Admin ticks them.';

create table if not exists channel_calls (
  id         bigint generated always as identity primary key,
  partner_id uuid references channel_partners (id) on delete set null,
  key_id     uuid references channel_keys (id) on delete set null,
  call       text not null,
  ok         boolean not null,
  code       text,
  at         timestamptz not null default now()
);
create index if not exists channel_calls_at on channel_calls (at desc);
comment on table channel_calls is 'Every Channel API call (2304), allowed or refused: who, what, when, the outcome. Admins read it.';

create table if not exists channel_bookings (
  booking_id uuid primary key references bookings (id) on delete cascade,
  partner_id uuid not null references channel_partners (id),
  partner_ref text check (partner_ref is null or length(partner_ref) <= 80),
  created_at timestamptz not null default now()
);
comment on table channel_bookings is 'Booking requests a channel partner sent (2304): a partner may cancel only its own.';

do $$
declare t text;
begin
  foreach t in array array['channel_partners', 'channel_keys', 'channel_calls', 'channel_bookings'] loop
    execute format('alter table %I enable row level security', t);
    execute format('revoke all on %I from public, anon, authenticated', t);
    execute format('grant select, insert, update, delete on %I to service_role', t);
    execute format('drop policy if exists admin_all on %I', t);
    execute format('create policy admin_all on %I for all to authenticated using (app.is_admin()) with check (app.is_admin())', t);
  end loop;
end $$;
create trigger audit_channel_partners after insert or update or delete on channel_partners for each row execute function app.audit_row();
create trigger audit_channel_keys after insert or update or delete on channel_keys for each row execute function app.audit_row();

-- ================================================================ the cars a partner may sell (public listing data only)
create or replace function app.channel_cars(p_partner channel_partners) returns table (vehicle_id uuid, ref text, class text)
language sql stable security definer set search_path = public, app as $$
  select v.id, l.slug, v.class::text from vehicles v join vehicle_listings l on l.vehicle_id = v.id
   where l.status = 'published' and l.slug is not null and not coalesce(v.is_sample, false) and v.management_mode <> 'turo_only'
     and (cardinality(p_partner.allowed_classes) = 0 or v.class::text = any (p_partner.allowed_classes))
     and (cardinality(p_partner.allowed_vehicles) = 0 or v.id = any (p_partner.allowed_vehicles))
$$;

create or replace function app.channel_vehicle_json(p_vehicle uuid, p_ref text) returns jsonb
language sql stable security definer set search_path = public, app as $$
  -- an explicit list of public fields: never the plate, VIN, owner, cost, odometer or calendar
  select jsonb_build_object('ref', p_ref, 'class', v.class::text, 'make', v.make, 'model', v.model, 'year', v.year, 'trim', v.trim,
    'body_style', l.body_style, 'seats', l.seats, 'doors', l.doors, 'transmission', l.transmission, 'luggage', l.luggage,
    'features', coalesce(to_jsonb(l.features), '[]'::jsonb),
    'photos', coalesce((select jsonb_agg(e ->> 'path' order by k) from jsonb_array_elements(app.public_listing_photos(v.id)) with ordinality t(e, k)
                         where coalesce(e ->> 'path', '') <> '' and k <= 12), '[]'::jsonb))
    from vehicles v join vehicle_listings l on l.vehicle_id = v.id where v.id = p_vehicle
$$;

-- the public quote with the partner's markup on the rental (HST on it too); only renter-facing price fields
create or replace function app.channel_quote(p_partner channel_partners, p_vehicle uuid, p_ref text, p_pickup timestamptz, p_return timestamptz, p_options jsonb) returns jsonb
language plpgsql stable security definer set search_path = public, app as $$
declare q jsonb; m bigint; h bigint;
begin
  q := public.quote_booking(p_vehicle, p_pickup, p_return, coalesce(p_options, '{}'::jsonb) - 'promo_code' - 'staff');
  m := round(coalesce((q ->> 'rental_charge_cents')::bigint, 0) * p_partner.markup_bps / 10000.0);
  h := round(m * coalesce((q ->> 'hst_bps')::integer, 0) / 10000.0);
  return jsonb_build_object('ref', p_ref, 'available', coalesce((q ->> 'available')::boolean, false), 'problems', coalesce(q -> 'problems', '[]'::jsonb),
    'currency', coalesce(q ->> 'currency', 'CAD'), 'billable_days', q -> 'billable_days',
    'rental_cents', coalesce((q ->> 'rental_charge_cents')::bigint, 0) + m, 'subtotal_cents', coalesce((q ->> 'subtotal_cents')::bigint, 0) + m,
    'hst_cents', coalesce((q ->> 'hst_cents')::bigint, 0) + h, 'total_cents', coalesce((q ->> 'total_cents')::bigint, 0) + m + h,
    'deposit_cents', q -> 'deposit_cents', 'km_per_day', q -> 'km_allowance_per_day', 'km_total', q -> 'km_allowance_total', 'extra_km_cents', q -> 'overage_cents_per_km',
    'delivery', q -> 'delivery', 'coverage', q -> 'coverage', 'drivers', q -> 'drivers', 'addons', q -> 'addons');
end $$;

-- ================================================================ the entry point
create or replace function public.channel_api(p_key text, p_call text, p jsonb default '{}'::jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  s program_settings := app.settings();
  k channel_keys; pt channel_partners;
  v_need text := case p_call when 'locations' then 'availability:read' when 'vehicles' then 'availability:read' when 'availability' then 'rates:read'
                             when 'booking_create' then 'bookings:create' when 'booking_cancel' then 'bookings:cancel' end;
  v_out jsonb; v_pickup timestamptz; v_return timestamptz; v_b jsonb; v_id uuid; c record;
begin
  p := coalesce(p, '{}'::jsonb);
  if not s.channel_api_enabled then
    insert into channel_calls (call, ok, code) values (left(coalesce(p_call, ''), 40), false, 'off');
    return jsonb_build_object('ok', false, 'status', 503, 'code', 'off', 'message', 'The channel API is switched off');
  end if;
  select * into k from channel_keys where key_hash = encode(sha256(convert_to(coalesce(p_key, ''), 'UTF8')), 'hex');
  if k.id is null or k.revoked_at is not null then
    insert into channel_calls (partner_id, key_id, call, ok, code) values (k.partner_id, k.id, left(coalesce(p_call, ''), 40), false, 'key');
    return jsonb_build_object('ok', false, 'status', 401, 'code', 'key', 'message', 'Unknown or revoked key');
  end if;
  select * into pt from channel_partners where id = k.partner_id;
  if pt.status <> 'active' then
    insert into channel_calls (partner_id, key_id, call, ok, code) values (pt.id, k.id, left(coalesce(p_call, ''), 40), false, 'paused');
    return jsonb_build_object('ok', false, 'status', 403, 'code', 'paused', 'message', 'This partner is paused');
  end if;
  if v_need is null or not (v_need = any (k.scopes)) then
    insert into channel_calls (partner_id, key_id, call, ok, code) values (pt.id, k.id, left(coalesce(p_call, ''), 40), false, 'scope');
    return jsonb_build_object('ok', false, 'status', 403, 'code', 'scope', 'message', coalesce('This key has no ' || v_need || ' scope', 'Unknown call'));
  end if;
  if not app.rate_limit('channel:' || k.id, pt.calls_per_minute, interval '1 minute') then
    insert into channel_calls (partner_id, key_id, call, ok, code) values (pt.id, k.id, p_call, false, 'rate');
    return jsonb_build_object('ok', false, 'status', 429, 'code', 'rate', 'message', 'Too many calls: try again in a minute');
  end if;
  update channel_keys set last_used_at = now() where id = k.id;

  begin
    if p_call = 'locations' then
      v_out := jsonb_build_object('locations', jsonb_build_array(jsonb_build_object('code', 'BASE', 'name', 'Toronto (Scarborough) base', 'type', 'base', 'address', s.company_address))
        || coalesce((select jsonb_agg(jsonb_build_object('code', a.code, 'name', a.name, 'type', 'airport_delivery') order by a.code) from airports a where a.is_active), '[]'::jsonb),
        'delivery', 'Delivery to any address is quoted with lat and lng on the availability call.');
    elsif p_call = 'vehicles' then
      v_out := jsonb_build_object('vehicles', coalesce((select jsonb_agg(app.channel_vehicle_json(x.vehicle_id, x.ref) order by x.ref) from app.channel_cars(pt) x), '[]'::jsonb));
    elsif p_call = 'availability' then
      v_pickup := (p ->> 'pickup_at')::timestamptz; v_return := (p ->> 'return_at')::timestamptz;
      if v_pickup is null or v_return is null or v_return <= v_pickup then raise exception 'pickup_at and return_at are needed, return after pickup' using errcode = '22023'; end if;
      v_out := jsonb_build_object('pickup_at', v_pickup, 'return_at', v_return,
        'delivery', case when p ? 'lat' and p ? 'lng' then public.delivery_to_point((p ->> 'lat')::numeric, (p ->> 'lng')::numeric) end,
        'vehicles', coalesce((select jsonb_agg(app.channel_quote(pt, x.vehicle_id, x.ref, v_pickup, v_return, p -> 'options') order by x.ref)
                                from app.channel_cars(pt) x where p ->> 'ref' is null or x.ref = p ->> 'ref'), '[]'::jsonb));
    elsif p_call = 'booking_create' then
      select x.vehicle_id into v_id from app.channel_cars(pt) x where x.ref = p ->> 'ref';
      if v_id is null then raise exception 'Unknown car for this partner' using errcode = 'P0002'; end if;
      -- a normal booking request: the database's own rules, the renter verifies their licence before the car is theirs
      v_b := public.submit_booking_request(jsonb_build_object('vehicle_id', v_id, 'pickup_at', p ->> 'pickup_at', 'return_at', p ->> 'return_at',
        'booking_type', 'standard', 'pickup_method', coalesce(p ->> 'pickup_method', 'collected'), 'return_method', coalesce(p ->> 'return_method', 'returned'),
        'pickup_place', p ->> 'pickup_place', 'return_place', p ->> 'return_place', 'note', left(p ->> 'note', 500), 'coverage_option', p -> 'coverage_option',
        'renter', p -> 'renter', 'additional_drivers', coalesce(p -> 'additional_drivers', '[]'::jsonb), 'consents', p -> 'consents',
        'details', jsonb_build_object('source', 'channel', 'channel_partner', pt.name, 'partner_ref', left(p ->> 'partner_ref', 80))), null, 'channel:' || pt.name, null);
      select b.id into v_id from bookings b where b.booking_number = v_b ->> 'booking_number';
      if v_id is not null then insert into channel_bookings (booking_id, partner_id, partner_ref) values (v_id, pt.id, left(p ->> 'partner_ref', 80)) on conflict do nothing; end if;
      v_out := jsonb_build_object('booking_number', v_b ->> 'booking_number', 'status', 'requested',
        'next', 'We confirm the car and the price; the renter verifies their licence before the booking is confirmed.');
    elsif p_call = 'booking_cancel' then
      select b.id, b.status::text status, r.user_id into c from channel_bookings cb join bookings b on b.id = cb.booking_id left join renters r on r.id = b.renter_id
       where cb.partner_id = pt.id and b.booking_number = p ->> 'booking_number';
      if c.id is null then raise exception 'Unknown booking for this partner' using errcode = 'P0002'; end if;
      perform public.renter_withdraw_request(c.id, c.user_id, 'Cancelled by the channel partner ' || pt.name);
      v_out := jsonb_build_object('booking_number', p ->> 'booking_number', 'status', 'cancelled');
    end if;
  exception when others then
    insert into channel_calls (partner_id, key_id, call, ok, code) values (pt.id, k.id, p_call, false, 'refused');
    return jsonb_build_object('ok', false, 'status', 400, 'code', 'refused', 'message', regexp_replace(sqlerrm, '\s+', ' ', 'g'));
  end;
  insert into channel_calls (partner_id, key_id, call, ok, code) values (pt.id, k.id, p_call, true, null);
  return jsonb_build_object('ok', true, 'partner', pt.name, 'data', v_out);
end $$;
comment on function public.channel_api(text, text, jsonb) is 'Channel API (2304): the one entry point for partners'' keys; the server''s /api/channel/v1 routes call it as service_role.';

-- ================================================================ Admin > Settings > Channel partners (Admin only)
create or replace function app.channel_admin(p_by uuid, p_name text, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare v_key text; v_id uuid; v_scopes text[];
begin
  perform app.assert_admin(p_by);
  p := coalesce(p, '{}'::jsonb);
  if p_name = 'channel_partner_save' then
    insert into channel_partners (id, name, status, markup_bps, commission_bps, allowed_classes, calls_per_minute, created_by)
    values (coalesce(nullif(p ->> 'id', '')::uuid, gen_random_uuid()), btrim(p ->> 'name'), coalesce(p ->> 'status', 'active'), coalesce((p ->> 'markup_bps')::integer, 0),
            coalesce((p ->> 'commission_bps')::integer, 0), coalesce(array(select jsonb_array_elements_text(p -> 'allowed_classes')), '{}'), coalesce((p ->> 'calls_per_minute')::integer, 60), p_by)
    on conflict (id) do update set name = excluded.name, status = excluded.status, markup_bps = excluded.markup_bps, commission_bps = excluded.commission_bps,
      allowed_classes = excluded.allowed_classes, calls_per_minute = excluded.calls_per_minute;
  elsif p_name = 'channel_key_create' then
    v_scopes := array(select distinct x from jsonb_array_elements_text(coalesce(p -> 'scopes', '["availability:read", "rates:read"]'::jsonb)) x);
    v_key := 'cc_chan_' || replace(gen_random_uuid()::text, '-', '') || replace(gen_random_uuid()::text, '-', '');
    insert into channel_keys (partner_id, prefix, key_hash, scopes, created_by)
    values ((p ->> 'partner')::uuid, left(v_key, 14), encode(sha256(convert_to(v_key, 'UTF8')), 'hex'), v_scopes, p_by) returning id into v_id;
    return app.channel_admin(p_by, 'channel_state', '{}'::jsonb) || jsonb_build_object('new_key', v_key, 'key_id', v_id, 'note', 'Shown once: copy it now.');
  elsif p_name = 'channel_key_revoke' then
    update channel_keys set revoked_at = now(), revoked_by = p_by where id = (p ->> 'id')::uuid and revoked_at is null;
  elsif p_name <> 'channel_state' then
    raise exception 'Unknown channel action' using errcode = '22023';
  end if;
  return jsonb_build_object('enabled', (app.settings()).channel_api_enabled,
    'partners', coalesce((select jsonb_agg(jsonb_build_object('id', c.id, 'name', c.name, 'status', c.status, 'markup_bps', c.markup_bps, 'commission_bps', c.commission_bps,
        'allowed_classes', c.allowed_classes, 'calls_per_minute', c.calls_per_minute,
        'keys', coalesce((select jsonb_agg(jsonb_build_object('id', k.id, 'prefix', k.prefix, 'scopes', k.scopes, 'created_at', k.created_at, 'last_used_at', k.last_used_at, 'revoked_at', k.revoked_at) order by k.created_at desc)
                          from channel_keys k where k.partner_id = c.id), '[]'::jsonb),
        'calls_today', (select count(*) from channel_calls x where x.partner_id = c.id and x.at > now() - interval '1 day')) order by c.name) from channel_partners c), '[]'::jsonb),
    'calls', coalesce((select jsonb_agg(jsonb_build_object('at', x.at, 'partner', pp.name, 'key', kk.prefix, 'call', x.call, 'ok', x.ok, 'code', x.code) order by x.at desc)
        from (select * from channel_calls order by at desc limit 100) x left join channel_partners pp on pp.id = x.partner_id left join channel_keys kk on kk.id = x.key_id), '[]'::jsonb));
end $$;

create function pg_temp.copy_grants(p_new regprocedure, p_old regprocedure) returns void
language plpgsql as $$
declare g text;
begin
  execute format('revoke all on function %s from public, anon, authenticated', p_new);
  foreach g in array array['anon', 'authenticated', 'service_role'] loop
    if has_function_privilege(g, p_old, 'execute') then execute format('grant execute on function %s to %I', p_new, g); end if;
  end loop;
end $$;
alter function app.door(uuid, text, text, text, jsonb) rename to door_pre2304;
create function app.door(p_user uuid, p_aal text, p_call text, p_name text, p jsonb default '{}'::jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
begin
  if (p_call = 'admin_read' and p_name = 'channel_state') or (p_call = 'admin_do' and p_name in ('channel_partner_save', 'channel_key_create', 'channel_key_revoke')) then
    perform app.door_begin(p_user, p_aal);
    return app.channel_admin(p_user, p_name, p);
  end if;
  return app.door_pre2304(p_user, p_aal, p_call, p_name, p);
end $$;
select pg_temp.copy_grants('app.door(uuid, text, text, text, jsonb)'::regprocedure, 'app.door_pre2304(uuid, text, text, text, jsonb)'::regprocedure);

do $$
declare f record;
begin
  for f in
    select p.oid::regprocedure as sig from pg_proc p join pg_namespace n on n.oid = p.pronamespace
     where (n.nspname = 'app' and p.proname = any (array['channel_cars', 'channel_vehicle_json', 'channel_quote', 'channel_admin', 'door_pre2304']))
        or (n.nspname = 'public' and p.proname = 'channel_api')
  loop
    execute format('revoke all on function %s from public, anon, authenticated', f.sig);
    execute format('grant execute on function %s to service_role', f.sig);
  end loop;
end $$;
