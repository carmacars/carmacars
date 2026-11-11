-- 1202_r35h_rentalcover.sql
-- Release 35, part H (docs/changes/2026-11-09-r35-offer-pricing-extensions-coverage.md), items 3 and 4.
-- 3. RentalCover quotes. The Protection Plan stays CarmaCars' product (no RentalCover name or link shown to renters).
--    Own pricing (the Protection Plan table) unless the partner key is set: with the Worker secret RENTALCOVER_API_KEY and
--    rentalcover_api_allowed (on), the server asks RentalCover for a quote for the renter (dates, age at pickup, name,
--    email; CA and CA) at checkout and when staff send an offer, records it here, and the price is the quote plus our
--    markup (rentalcover_markup_enabled on, rentalcover_markup_pct 20, rentalcover_markup_flat_cents 0). The raw quote and
--    our price are kept on the booking; a quote is reused for 15 minutes; on a failure the plan keeps its own price. The
--    purchase needs the renter's card: not made here (TODO, see the change record).
-- 4. RentalCover covers up to $50,000 an incident: it is offered only for a car worth less than
--    rentalcover_max_vehicle_value_cents ($50,000), in both modes. The car's value: an Admin's replacement value (an
--    override), else its Canadian Black Book value (vehicles.black_book_value_cents, else the last buyout's), else an AI
--    estimate from typical listing prices (vehicles.estimated_value_*, filled by the server's value job), else unknown,
--    which counts as over the cap. At or over the cap only OPCF 27 or credit card coverage: the checkout quote says so,
--    the offer screen and the request form leave the option out, and a trigger refuses option 3 on such a car. Data Health
--    lists the cars with no value.
set local check_function_bodies = off;

create or replace function pg_temp.copy_grants(p_new regprocedure, p_old regprocedure) returns void
language plpgsql as $$
declare g text;
begin
  execute format('revoke all on function %s from public, anon, authenticated', p_new);
  foreach g in array array['anon', 'authenticated', 'service_role'] loop
    if has_function_privilege(g, p_old, 'execute') then execute format('grant execute on function %s to %I', p_new, g); end if;
  end loop;
end $$;

-- ================================================================ settings and the car's value
alter table program_settings
  add column if not exists rentalcover_api_allowed boolean not null default true,
  add column if not exists rentalcover_markup_enabled boolean not null default true,
  add column if not exists rentalcover_markup_pct numeric(6,2) not null default 20 check (rentalcover_markup_pct >= 0 and rentalcover_markup_pct <= 500),
  add column if not exists rentalcover_markup_flat_cents bigint not null default 0 check (rentalcover_markup_flat_cents >= 0),
  add column if not exists rentalcover_quote_cache_minutes integer not null default 15 check (rentalcover_quote_cache_minutes between 1 and 1440),
  add column if not exists rentalcover_max_vehicle_value_cents bigint not null default 5000000 check (rentalcover_max_vehicle_value_cents > 0),
  add column if not exists rentalcover_unknown_value_allowed boolean not null default false;
-- a settings row cached earlier in this session has fewer columns: read it again (app.settings, 0827)
select set_config('app.settings_gen', gen_random_uuid()::text, true);
comment on column program_settings.rentalcover_api_allowed is 'RentalCover (1202): price the Protection Plan from a RentalCover quote plus our markup when the partner key (RENTALCOVER_API_KEY) is set. Off, or no key: our own pricing (the Protection Plan table).';
comment on column program_settings.rentalcover_markup_enabled is 'RentalCover api mode (1202): add our markup to the quote (on: a licensed rental company may resell with a markup).';
comment on column program_settings.rentalcover_markup_pct is 'RentalCover api mode (1202): markup, percent of the quote (20 by default).';
comment on column program_settings.rentalcover_markup_flat_cents is 'RentalCover (1202): markup, a fixed amount per quote (0 by default).';
comment on column program_settings.rentalcover_quote_cache_minutes is 'RentalCover (1202): a quote for the same renter and dates is reused for this many minutes.';
comment on column program_settings.rentalcover_max_vehicle_value_cents is 'RentalCover (1202): the Protection Plan is offered only for a car worth less than this (it covers up to $50,000 an incident).';
comment on column program_settings.rentalcover_unknown_value_allowed is 'RentalCover (1202): offer the Protection Plan on a car with no value on file (off: unknown counts as over the cap).';

alter table vehicles
  add column if not exists replacement_value_cents bigint check (replacement_value_cents is null or replacement_value_cents > 0),
  add column if not exists black_book_value_cents bigint check (black_book_value_cents is null or black_book_value_cents > 0),
  add column if not exists black_book_value_on date,
  add column if not exists estimated_value_cents bigint check (estimated_value_cents is null or estimated_value_cents > 0),
  add column if not exists estimated_value_source text,
  add column if not exists estimated_value_at timestamptz,
  add column if not exists estimated_value_tried_at timestamptz;
comment on column vehicles.replacement_value_cents is 'An Admin''s value for the RentalCover cap (1202): wins over every other source when set.';
comment on column vehicles.black_book_value_cents is 'Canadian Black Book value (1202): the primary value for the RentalCover cap (else the last buyout''s Black Book value).';
comment on column vehicles.estimated_value_cents is 'An AI estimate from typical Canadian listing prices (1202), used for the RentalCover cap when there is no Black Book value; source and date beside it.';
comment on column vehicles.estimated_value_tried_at is 'When the value job last asked for an estimate (1202): one try a day per car; null asks again (Refresh on the car page).';

-- the car's value for the cap, and where it came from
create function app.vehicle_cover_value(p_vehicle uuid) returns jsonb
language sql stable security definer set search_path = public, app as $$
  select case
    when v.replacement_value_cents is not null then jsonb_build_object('value_cents', v.replacement_value_cents, 'source', 'replacement_value')
    when v.black_book_value_cents is not null then jsonb_build_object('value_cents', v.black_book_value_cents, 'source', 'black_book', 'on', v.black_book_value_on)
    when bb.black_book_value_cents is not null then jsonb_build_object('value_cents', bb.black_book_value_cents, 'source', 'black_book')
    when v.estimated_value_cents is not null then jsonb_build_object('value_cents', v.estimated_value_cents, 'source', 'estimate',
                                                                    'estimate_source', v.estimated_value_source, 'at', v.estimated_value_at)
    else jsonb_build_object('value_cents', null, 'source', 'unknown') end
    from vehicles v
    left join lateral (select x.black_book_value_cents from vehicle_buyouts x where x.vehicle_id = v.id and x.black_book_value_cents is not null
                        order by x.offered_on desc, x.created_at desc limit 1) bb on true
   where v.id = p_vehicle
$$;

-- whether RentalCover may be offered for the car, with the reason when not
create function app.rentalcover_check(p_vehicle uuid) returns jsonb
language sql stable security definer set search_path = public, app as $$
  select jsonb_build_object('allowed', case when (c ->> 'value_cents') is null then s.rentalcover_unknown_value_allowed
                                            else (c ->> 'value_cents')::bigint < s.rentalcover_max_vehicle_value_cents end,
           'value_cents', (c ->> 'value_cents')::bigint, 'source', c ->> 'source', 'cap_cents', s.rentalcover_max_vehicle_value_cents,
           'reason', case when (c ->> 'value_cents') is null and not s.rentalcover_unknown_value_allowed
                            then 'The Protection Plan is offered only for a car with its value on file: choose your own policy with OPCF 27, or credit card coverage.'
                          when (c ->> 'value_cents') is not null and (c ->> 'value_cents')::bigint >= s.rentalcover_max_vehicle_value_cents
                            then format('The Protection Plan covers up to %s an incident, so it is not offered for this car: choose your own policy with OPCF 27, or credit card coverage.',
                                        app.fmt_money(s.rentalcover_max_vehicle_value_cents)) end)
    from app.settings() s, app.vehicle_cover_value(p_vehicle) c
$$;
create function app.rentalcover_allowed(p_vehicle uuid) returns boolean
language sql stable security definer set search_path = public, app as $$ select coalesce((app.rentalcover_check(p_vehicle) ->> 'allowed')::boolean, false) $$;

-- the database refuses the Protection Plan on such a car, whatever the path (a request, an offer, a change, a switch)
create function app.bookings_rentalcover_cap() returns trigger
language plpgsql security definer set search_path = public, app as $$
begin
  if new.coverage_option = 3 and new.booking_type <> 'owner'
     and (tg_op = 'INSERT' or old.coverage_option is distinct from 3)
     and not app.rentalcover_allowed(new.vehicle_id) then
    raise exception '%', app.rentalcover_check(new.vehicle_id) ->> 'reason' using errcode = '23514';
  end if;
  return new;
end $$;
create trigger bookings_z1_rentalcover_cap before insert or update of coverage_option on bookings
  for each row execute function app.bookings_rentalcover_cap();

-- ================================================================ the quotes
create table rentalcover_quotes (
  id uuid primary key default gen_random_uuid(),
  created_at timestamptz not null default now(),
  expires_at timestamptz not null,
  source text not null default 'checkout' check (source in ('checkout', 'offer', 'review', 'request')),
  vehicle_id uuid references vehicles(id) on delete set null,
  booking_id uuid references bookings(id) on delete set null,
  renter_id uuid references renters(id) on delete set null,
  from_at timestamptz not null,
  to_at timestamptz not null,
  customer_age integer,
  cache_key text not null,
  status text not null check (status in ('ok', 'failed')),
  reference text,
  policy_code text,
  quote_cents bigint check (quote_cents is null or quote_cents >= 0),
  currency text,
  markup_cents bigint,
  price_cents bigint check (price_cents is null or price_cents >= 0),
  markup jsonb,
  request jsonb,
  response jsonb,
  error text,
  check (status <> 'ok' or (quote_cents is not null and price_cents is not null))
);
create index rentalcover_quotes_cache on rentalcover_quotes (cache_key, expires_at desc) where status = 'ok';
create index rentalcover_quotes_booking on rentalcover_quotes (booking_id) where booking_id is not null;
alter table rentalcover_quotes enable row level security;
revoke all on rentalcover_quotes from anon, authenticated;
grant all on rentalcover_quotes to service_role;
-- an Admin reads them (the audit of a price); only the server writes them
grant select on rentalcover_quotes to authenticated;
create policy admin_all on rentalcover_quotes for select to authenticated using (app.is_admin());
create trigger audit_rentalcover_quotes after insert or update or delete on rentalcover_quotes for each row execute function app.audit_row();
comment on table rentalcover_quotes is 'RentalCover quotes (1202): the raw quote, our markup and price, for audit and a short cache. The request is kept without the email (only a hash in cache_key).';

alter table bookings
  add column if not exists rentalcover_quote_id uuid references rentalcover_quotes(id) on delete set null,
  add column if not exists rentalcover_quote_cents bigint,
  add column if not exists rentalcover_price_cents bigint;
comment on column bookings.rentalcover_quote_id is 'The RentalCover quote the Protection Plan was priced from (1202).';
comment on column bookings.rentalcover_quote_cents is 'RentalCover''s quote (raw) for this booking, for audit (1202).';
comment on column bookings.rentalcover_price_cents is 'Our Protection Plan price from that quote (quote plus markup), for audit (1202).';

-- our price from a quote: the quote, plus the markup when Program settings turn it on
create function app.rentalcover_price(p_quote_cents bigint) returns jsonb
language sql stable security definer set search_path = public, app as $$
  select jsonb_build_object('quote_cents', p_quote_cents,
           'markup_cents', case when s.rentalcover_markup_enabled then round(p_quote_cents * s.rentalcover_markup_pct / 100.0)::bigint + s.rentalcover_markup_flat_cents else 0 end,
           'price_cents', p_quote_cents + case when s.rentalcover_markup_enabled then round(p_quote_cents * s.rentalcover_markup_pct / 100.0)::bigint + s.rentalcover_markup_flat_cents else 0 end,
           'markup', jsonb_build_object('enabled', s.rentalcover_markup_enabled, 'pct', s.rentalcover_markup_pct, 'flat_cents', s.rentalcover_markup_flat_cents))
    from app.settings() s
$$;

-- what the server needs to ask for a quote: the car's check, the renter (a booking's, one on file, or typed), the age at
-- pickup, and a quote still fresh for the same renter and dates. p: coverage_option, vehicle_id, pickup_at, return_at,
-- and booking (with changes: the review screen's new dates or car) or renter_id or renter {full_name, email, date_of_birth}
create function app.rentalcover_facts(p jsonb) returns jsonb
language plpgsql stable security definer set search_path = public, app as $$
declare
  b bookings;
  rn renters;
  v_vehicle uuid := nullif(p ->> 'vehicle_id', '')::uuid;
  v_from timestamptz := nullif(p ->> 'pickup_at', '')::timestamptz;
  v_to timestamptz := nullif(p ->> 'return_at', '')::timestamptz;
  v_name text;
  v_email text;
  v_dob date;
  v_first text;
  v_last text;
  v_age integer;
  v_key text;
  q rentalcover_quotes;
begin
  if nullif(p ->> 'booking', '') is not null then
    select * into b from bookings where id::text = p ->> 'booking' or booking_number = upper(btrim(p ->> 'booking'));
    if b.id is not null then
      v_vehicle := coalesce(v_vehicle, b.vehicle_id); v_from := coalesce(v_from, b.pickup_at); v_to := coalesce(v_to, b.return_at);
      select * into rn from renters where id = b.renter_id;
    end if;
  elsif nullif(p ->> 'renter_id', '') is not null then
    select * into rn from renters where id = (p ->> 'renter_id')::uuid;
  end if;
  if rn.id is not null then
    v_name := rn.legal_name; v_email := coalesce(rn.email, (select u.email from users u where u.id = rn.user_id)); v_dob := rn.date_of_birth;
  end if;
  v_name := coalesce(v_name, nullif(btrim(p #>> '{renter,full_name}'), ''));
  v_email := lower(coalesce(v_email, nullif(btrim(p #>> '{renter,email}'), '')));
  v_dob := coalesce(v_dob, nullif(p #>> '{renter,date_of_birth}', '')::date);
  v_vehicle := coalesce(nullif(p #>> '{changes,vehicle_id}', '')::uuid, v_vehicle);
  v_from := coalesce(nullif(p #>> '{changes,pickup_at}', '')::timestamptz, v_from);
  v_to := coalesce(nullif(p #>> '{changes,return_at}', '')::timestamptz, v_to);
  -- only for the Protection Plan: the option given, else the booking's
  if coalesce(nullif(p ->> 'coverage_option', '')::integer, b.coverage_option) is distinct from 3 then
    return jsonb_build_object('ok', false, 'missing', 'not_the_plan');
  end if;
  if not coalesce((app.settings()).rentalcover_api_allowed, true) then return jsonb_build_object('ok', false, 'missing', 'own_pricing'); end if;
  if v_vehicle is null or v_from is null or v_to is null or v_to <= v_from then
    return jsonb_build_object('ok', false, 'missing', 'dates');
  end if;
  if not app.rentalcover_allowed(v_vehicle) then
    return jsonb_build_object('ok', false, 'missing', 'not_offered', 'check', app.rentalcover_check(v_vehicle));
  end if;
  if v_name is null or v_email is null or v_dob is null then
    return jsonb_build_object('ok', false, 'missing', 'renter');
  end if;
  v_first := split_part(btrim(v_name), ' ', 1);
  v_last := coalesce(nullif(btrim(substr(btrim(v_name), length(v_first) + 1)), ''), v_first);
  v_age := app.age_on(v_dob, app.local_date(v_from));
  v_key := encode(sha256(convert_to(concat_ws('|', to_char(v_from at time zone 'America/Toronto', 'YYYY-MM-DD HH24:MI:SS'),
                                              to_char(v_to at time zone 'America/Toronto', 'YYYY-MM-DD HH24:MI:SS'), v_age, v_email, lower(v_first), lower(v_last)), 'UTF8')), 'hex');
  select * into q from rentalcover_quotes x where x.cache_key = v_key and x.status = 'ok' and x.expires_at > now() order by x.created_at desc limit 1;
  return jsonb_build_object('ok', true, 'vehicle_id', v_vehicle, 'booking_id', b.id, 'renter_id', rn.id,
    'from_date', to_char(v_from at time zone 'America/Toronto', 'YYYY-MM-DD HH24:MI:SS'), 'to_date', to_char(v_to at time zone 'America/Toronto', 'YYYY-MM-DD HH24:MI:SS'),
    'pickup_at', v_from, 'return_at', v_to, 'customer_age', v_age, 'first_name', v_first, 'last_name', v_last, 'email', v_email,
    'country', 'CA', 'destination_country', 'CA', 'cache_key', v_key,
    'cached', case when q.id is not null then jsonb_build_object('id', q.id, 'price_cents', q.price_cents, 'reference', q.reference) end);
end $$;

-- the server records a quote (or a failure); our price follows the settings. p: the facts above, plus status, reference,
-- policy_code, quote_cents, currency, response, error, source
create function app.rentalcover_record(p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  v_ok boolean := coalesce(p ->> 'status', '') = 'ok' and nullif(p ->> 'quote_cents', '') is not null;
  v_price jsonb := case when coalesce(p ->> 'status', '') = 'ok' and nullif(p ->> 'quote_cents', '') is not null then app.rentalcover_price((p ->> 'quote_cents')::bigint) end;
  v_id uuid;
begin
  insert into rentalcover_quotes (expires_at, source, vehicle_id, booking_id, renter_id, from_at, to_at, customer_age, cache_key, status, reference, policy_code,
                                  quote_cents, currency, markup_cents, price_cents, markup, request, response, error)
  values (now() + make_interval(mins => (app.settings()).rentalcover_quote_cache_minutes),
          case when p ->> 'source' in ('checkout', 'offer', 'review', 'request') then p ->> 'source' else 'checkout' end,
          nullif(p ->> 'vehicle_id', '')::uuid, nullif(p ->> 'booking_id', '')::uuid, nullif(p ->> 'renter_id', '')::uuid,
          (p ->> 'pickup_at')::timestamptz, (p ->> 'return_at')::timestamptz, nullif(p ->> 'customer_age', '')::integer, coalesce(p ->> 'cache_key', ''),
          case when v_ok then 'ok' else 'failed' end, nullif(p ->> 'reference', ''), nullif(p ->> 'policy_code', ''),
          (v_price ->> 'quote_cents')::bigint, nullif(p ->> 'currency', ''), (v_price ->> 'markup_cents')::bigint, (v_price ->> 'price_cents')::bigint, v_price -> 'markup',
          jsonb_strip_nulls(jsonb_build_object('FromDate', p ->> 'from_date', 'ToDate', p ->> 'to_date', 'CustomerAge', (p ->> 'customer_age')::integer,
                                               'Country', coalesce(p ->> 'country', 'CA'), 'DestinationCountry', coalesce(p ->> 'destination_country', 'CA'))),
          case when jsonb_typeof(p -> 'response') = 'object' then p -> 'response' end, left(nullif(p ->> 'error', ''), 500))
  returning id into v_id;
  return jsonb_build_object('id', case when v_ok then v_id end, 'logged_id', v_id, 'ok', v_ok, 'price_cents', (v_price ->> 'price_cents')::bigint);
end $$;

-- a quote that prices these dates: recorded fine and still fresh (to_at and from_at the same instants)
create function app.rentalcover_quote_for(p_quote uuid, p_from timestamptz, p_to timestamptz, p_fresh boolean default true) returns rentalcover_quotes
language sql stable security definer set search_path = public, app as $$
  select q.* from rentalcover_quotes q
   where q.id = p_quote and q.status = 'ok' and q.from_at = p_from and q.to_at = p_to and (not p_fresh or q.expires_at > now() - interval '2 hours')
$$;

-- the booking takes the quote: the Protection Plan line at our price (a price staff typed by hand wins), the raw quote
-- and our price kept for audit. Only while the booking is a request or an offer being made (its price not settled).
create function app.rentalcover_apply(p_booking uuid, p_quote uuid) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  b bookings;
  q rentalcover_quotes;
  o booking_line_overrides;
begin
  select * into b from bookings where id = p_booking for update;
  if b.id is null or p_quote is null then return jsonb_build_object('applied', false, 'why', 'no_booking'); end if;
  if b.coverage_option is distinct from 3 then return jsonb_build_object('applied', false, 'why', 'not_the_plan'); end if;
  if b.status::text not in ('requested', 'tentative') then return jsonb_build_object('applied', false, 'why', 'price_settled'); end if;
  if not app.rentalcover_allowed(b.vehicle_id) then return jsonb_build_object('applied', false, 'why', 'not_offered'); end if;
  q := app.rentalcover_quote_for(p_quote, b.pickup_at, b.return_at);
  if q.id is null then return jsonb_build_object('applied', false, 'why', 'quote_not_for_these_dates'); end if;
  select * into o from booking_line_overrides where booking_id = b.id and line_key = 'coverage_sold';
  if o.id is not null and o.set_by is not null and coalesce(o.reason, '') not like 'RentalCover quote%' then
    return jsonb_build_object('applied', false, 'why', 'typed_by_staff');
  end if;
  insert into booking_line_overrides (booking_id, line_key, total_cents, reason, set_by)
  values (b.id, 'coverage_sold', q.price_cents, format('RentalCover quote %s', coalesce(q.reference, q.id::text)), null)
  on conflict (booking_id, line_key) do update set total_cents = excluded.total_cents, reason = excluded.reason, set_by = null, set_at = now();
  update bookings set rentalcover_quote_id = q.id, rentalcover_quote_cents = q.quote_cents, rentalcover_price_cents = q.price_cents where id = b.id;
  update rentalcover_quotes set booking_id = coalesce(booking_id, b.id) where id = q.id;
  perform app.sync_booking_price(b.id);
  return jsonb_build_object('applied', true, 'price_cents', q.price_cents, 'quote_cents', q.quote_cents);
end $$;

-- the server's doors (service role only)
create function public.server_rentalcover_facts(p jsonb) returns jsonb
language sql stable security definer set search_path = public, app as $$ select app.rentalcover_facts(coalesce(p, '{}'::jsonb)) $$;
create function public.server_rentalcover_record(p jsonb) returns jsonb
language sql security definer set search_path = public, app as $$ select app.rentalcover_record(coalesce(p, '{}'::jsonb)) $$;
create function public.server_rentalcover_apply(p_booking text, p_quote uuid) returns jsonb
language sql security definer set search_path = public, app as $$
  select app.rentalcover_apply((select id from bookings where id::text = p_booking or booking_number = upper(btrim(p_booking))), p_quote) $$;

-- ================================================================ the checkout quote
-- a car over the cap: the option is not offered (and refused when chosen); a fresh RentalCover quote for these dates
-- prices the Protection Plan at our price
alter function app.price_quote(uuid, timestamptz, timestamptz, jsonb) rename to price_quote_pre1202;
create function app.price_quote(p_vehicle uuid, p_pickup timestamptz, p_return timestamptz, p_options jsonb default '{}'::jsonb) returns jsonb
language plpgsql stable security definer set search_path = public, app as $$
declare
  v jsonb := app.price_quote_pre1202(p_vehicle, p_pickup, p_return, p_options);
  c jsonb := app.rentalcover_check(p_vehicle);
  q rentalcover_quotes;
  v_line jsonb;
  v_lines jsonb;
  v_hst integer := (app.settings()).hst_bps;
  v_sub bigint;
  v_tax bigint;
begin
  if not (c ->> 'allowed')::boolean then
    v := jsonb_set(v, '{coverage}', coalesce(v -> 'coverage', '{}'::jsonb) || jsonb_build_object('sold_by_carmacars_available', false, 'not_offered_reason', c ->> 'reason'));
    if coalesce(p_options ->> 'coverage_option', '') = '3' then
      v := jsonb_set(v, '{problems}', coalesce(v -> 'problems', '[]'::jsonb) || jsonb_build_array(jsonb_build_object('code', 'coverage_not_offered', 'message', c ->> 'reason')));
    end if;
    return v;
  end if;
  if coalesce(p_options ->> 'coverage_option', '') <> '3' or nullif(p_options ->> 'rentalcover_quote_id', '') is null
     or (coalesce(current_setting('app.staff_pricing', true), '') = 'on' and jsonb_typeof(p_options #> '{line_overrides,coverage_sold}') = 'number') then
    return v;
  end if;
  q := app.rentalcover_quote_for((p_options ->> 'rentalcover_quote_id')::uuid, p_pickup, p_return);
  if q.id is null then return v; end if;
  v_line := (app.price_line('coverage_sold', 1, q.price_cents, q.price_cents, v_hst, null, null, jsonb_build_object('source', 'rentalcover')) - 'revenue_class' - 'sort_order');
  select coalesce(jsonb_agg(x.value order by x.ord), '[]'::jsonb) into v_lines
    from jsonb_array_elements(coalesce(v -> 'lines', '[]'::jsonb)) with ordinality x(value, ord) where x.value ->> 'charge_type' <> 'coverage_sold';
  v_lines := v_lines || jsonb_build_array(v_line);
  select coalesce(sum((x ->> 'amount_cents')::bigint), 0), coalesce(sum((x ->> 'hst_cents')::bigint), 0) into v_sub, v_tax from jsonb_array_elements(v_lines) x;
  return v || jsonb_build_object('lines', v_lines, 'subtotal_cents', v_sub, 'hst_cents', v_tax, 'total_cents', v_sub + v_tax, 'total_due_at_booking_cents', v_sub + v_tax,
    'coverage', coalesce(v -> 'coverage', '{}'::jsonb) || jsonb_build_object('sold_by_carmacars_price_cents', q.price_cents, 'sold_by_carmacars_per_day', false,
                                                                            'priced_in_offer', false, 'price_note', null, 'rentalcover_quoted', true));
end $$;
select pg_temp.copy_grants('app.price_quote(uuid, timestamptz, timestamptz, jsonb)'::regprocedure, 'app.price_quote_pre1202(uuid, timestamptz, timestamptz, jsonb)'::regprocedure);

-- ================================================================ offers and the review screen
-- a quote passed with the offer (rentalcover_quote_id) prices its Protection Plan, after the rest of the edit
alter function app.admin_apply_booking_edit(uuid, uuid, jsonb) rename to admin_apply_booking_edit_pre1202;
create function app.admin_apply_booking_edit(p_admin uuid, p_booking uuid, p jsonb) returns void
language plpgsql security definer set search_path = public, app as $$
begin
  perform app.admin_apply_booking_edit_pre1202(p_admin, p_booking, p - 'rentalcover_quote_id');
  if nullif(p ->> 'rentalcover_quote_id', '') is not null and not (jsonb_typeof(p #> '{line_overrides,coverage_sold}') = 'number') then
    perform app.rentalcover_apply(p_booking, (p ->> 'rentalcover_quote_id')::uuid);
  end if;
end $$;
select pg_temp.copy_grants('app.admin_apply_booking_edit(uuid, uuid, jsonb)'::regprocedure, 'app.admin_apply_booking_edit_pre1202(uuid, uuid, jsonb)'::regprocedure);

alter function app.staff_offer_create(uuid, jsonb) rename to staff_offer_create_pre1202;
create function app.staff_offer_create(p_by uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  v_out jsonb;
  v_id uuid;
begin
  if nullif(p ->> 'rentalcover_quote_id', '') is null or jsonb_typeof(p #> '{line_overrides,coverage_sold}') = 'number' then
    return app.staff_offer_create_pre1202(p_by, p - 'rentalcover_quote_id');
  end if;
  -- made as a draft first, priced from the quote, then sent as staff_offer_create sends it
  v_out := app.staff_offer_create_pre1202(p_by, (p - 'rentalcover_quote_id') || jsonb_build_object('draft', true));
  v_id := (v_out ->> 'booking_id')::uuid;
  perform app.rentalcover_apply(v_id, (p ->> 'rentalcover_quote_id')::uuid);
  if coalesce((p ->> 'draft')::boolean, false) then return v_out; end if;
  return app.offer_revise(p_by, jsonb_build_object('booking', v_id, 'changes', '{}'::jsonb, 'send', true, 'notify', coalesce((p ->> 'notify')::boolean, true),
    'channels', p -> 'channels', 'message', p ->> 'message', 'expires_at', p ->> 'expires_at')) || jsonb_build_object('booking_id', v_id, 'renter_id',
    (select renter_id from bookings where id = v_id), 'total_cents', (select total_due_at_booking_cents from bookings where id = v_id),
    'due_cents', (select renter_due_at_booking_cents from bookings where id = v_id), 'expires_at', (select offer_expires_at from bookings where id = v_id),
    'renter_existing', nullif(p ->> 'renter_id', '') is not null, 'price_flags', (select to_jsonb(price_flags) from bookings where id = v_id));
end $$;
select pg_temp.copy_grants('app.staff_offer_create(uuid, jsonb)'::regprocedure, 'app.staff_offer_create_pre1202(uuid, jsonb)'::regprocedure);

-- the offer screen's cars and the request form's car say whether the Protection Plan is offered
alter function app.staff_offer_form(uuid, jsonb) rename to staff_offer_form_pre1202;
create function app.staff_offer_form(p_by uuid, p jsonb) returns jsonb
language plpgsql stable security definer set search_path = public, app as $$
declare
  v jsonb := app.staff_offer_form_pre1202(p_by, p);
begin
  return v || jsonb_build_object('cars', coalesce((select jsonb_agg(c || jsonb_build_object('rentalcover', app.rentalcover_check((c ->> 'id')::uuid)) order by n)
                       from jsonb_array_elements(coalesce(v -> 'cars', '[]'::jsonb)) with ordinality x(c, n)), '[]'::jsonb));
end $$;
select pg_temp.copy_grants('app.staff_offer_form(uuid, jsonb)'::regprocedure, 'app.staff_offer_form_pre1202(uuid, jsonb)'::regprocedure);

alter function app.booking_car(text) rename to booking_car_pre1202;
create function app.booking_car(p_slug text) returns jsonb
language sql stable security definer set search_path = public, app as $$
  select case when r is null then null
              else r || jsonb_build_object('protection_plan_offered', app.rentalcover_allowed((r ->> 'vehicle_id')::uuid)) end
    from app.booking_car_pre1202(p_slug) r
$$;
select pg_temp.copy_grants('app.booking_car(text)'::regprocedure, 'app.booking_car_pre1202(text)'::regprocedure);

-- the car page (Admin): its value for the cap
alter function app.admin_vehicle(uuid) rename to admin_vehicle_pre1202;
create function app.admin_vehicle(p_vehicle uuid) returns jsonb
language sql stable security definer set search_path = public, app as $$
  select app.admin_vehicle_pre1202(p_vehicle) || jsonb_build_object('rentalcover', app.rentalcover_check(p_vehicle))
$$;
select pg_temp.copy_grants('app.admin_vehicle(uuid)'::regprocedure, 'app.admin_vehicle_pre1202(uuid)'::regprocedure);

-- an Admin sets the car's value (empty clears it)
create function app.vehicle_cover_value_set(p_by uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  v_id uuid := nullif(p ->> 'vehicle_id', '')::uuid;
  v vehicles;
  v_val bigint := nullif(p ->> 'replacement_value_cents', '')::bigint;
  v_bb bigint := nullif(p ->> 'black_book_value_cents', '')::bigint;
begin
  perform app.assert_admin(p_by);
  if (v_val is not null and v_val <= 0) or (v_bb is not null and v_bb <= 0) then raise exception 'Enter what the car is worth, or leave it empty' using errcode = '22023'; end if;
  select * into v from vehicles where id = v_id for update;
  if v.id is null then raise exception 'Car not found' using errcode = 'P0002'; end if;
  update vehicles set replacement_value_cents = case when p ? 'replacement_value_cents' then v_val else replacement_value_cents end,
         black_book_value_cents = case when p ? 'black_book_value_cents' then v_bb else black_book_value_cents end,
         black_book_value_on = case when p ? 'black_book_value_cents' and v_bb is distinct from v.black_book_value_cents then case when v_bb is not null then app.today() end else black_book_value_on end
   where id = v_id;
  insert into audit_log (actor_user_id, action, entity_table, entity_id, before, after)
  values (p_by, 'vehicle_cover_value_set', 'vehicles', v_id,
          jsonb_build_object('replacement_value_cents', v.replacement_value_cents, 'black_book_value_cents', v.black_book_value_cents),
          (select jsonb_build_object('replacement_value_cents', x.replacement_value_cents, 'black_book_value_cents', x.black_book_value_cents) from vehicles x where x.id = v_id));
  return jsonb_build_object('ok', true, 'rentalcover', app.rentalcover_check(v_id));
end $$;

-- ================================================================ the value job: an AI estimate where there is no Black Book value
-- the cars the job estimates: active, no override and no Black Book value, no estimate in 90 days, not tried today
create function app.car_values_due(p_limit integer default 5, p_vehicle uuid default null) returns jsonb
language sql stable security definer set search_path = public, app as $$
  select coalesce(jsonb_agg(jsonb_build_object('vehicle_id', v.id, 'year', v.year, 'make', v.make, 'model', v.model, 'trim', v.trim,
           'odometer_km', v.odometer_km, 'fuel', v.fuel, 'body_type', v.body_type) order by v.estimated_value_tried_at nulls first, v.created_at), '[]'::jsonb)
    from (select x.* from vehicles x
           where (p_vehicle is null or x.id = p_vehicle) and not coalesce(x.is_sample, false) and x.status not in ('exited', 'total_loss', 'declined')
             and x.replacement_value_cents is null and x.black_book_value_cents is null
             and not exists (select 1 from vehicle_buyouts b where b.vehicle_id = x.id and b.black_book_value_cents is not null)
             and (x.estimated_value_at is null or x.estimated_value_at < now() - interval '90 days')
             and (x.estimated_value_tried_at is null or x.estimated_value_tried_at < now() - interval '1 day')
             and x.make is not null and x.model is not null and x.year is not null
           order by x.estimated_value_tried_at nulls first, x.created_at limit greatest(least(p_limit, 25), 1)) v
$$;
create function public.server_car_values_due(p_limit integer default 5, p_vehicle uuid default null) returns jsonb
language sql stable security definer set search_path = public, app as $$ select app.car_values_due(p_limit, p_vehicle) $$;
-- the job's answer for one car: an estimate (cents, its source such as "ai:<model>", the basis) or a failed try
create function public.server_car_value_save(p_vehicle uuid, p_cents bigint, p_source text, p_basis text default null) returns jsonb
language plpgsql security definer set search_path = public, app as $$
begin
  if p_cents is not null and (p_cents < 100000 or p_cents > 100000000) then p_cents := null; end if;
  update vehicles set estimated_value_tried_at = now(),
         estimated_value_cents = coalesce(p_cents, estimated_value_cents),
         estimated_value_source = case when p_cents is not null then left(coalesce(p_source, 'ai') || coalesce(': ' || left(p_basis, 200), ''), 300) else estimated_value_source end,
         estimated_value_at = case when p_cents is not null then now() else estimated_value_at end
   where id = p_vehicle;
  return jsonb_build_object('ok', found, 'saved', p_cents is not null);
end $$;
-- the job runs while a car is due (the Worker's cron tick)
alter function app.server_jobs_due() rename to server_jobs_due_pre1202;
create function app.server_jobs_due() returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare j jsonb := app.server_jobs_due_pre1202();
begin
  if jsonb_array_length(app.car_values_due(1)) > 0 then j := j || jsonb_build_object('car_values', true); end if;
  return j;
end $$;
select pg_temp.copy_grants('app.server_jobs_due()'::regprocedure, 'app.server_jobs_due_pre1202()'::regprocedure);
-- staff ask again for one car (Refresh on the car page): the job picks it up on its next tick
create function app.vehicle_value_refresh(p_by uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare v_id uuid := nullif(p ->> 'vehicle_id', '')::uuid;
begin
  if not (app.user_is_admin(p_by) or app.user_va_has(p_by, 'fleet') or app.user_va_has(p_by, 'cs')) then
    raise exception 'Only an Admin, fleet or customer service asks for a new estimate' using errcode = '42501';
  end if;
  update vehicles set estimated_value_tried_at = null, estimated_value_at = case when estimated_value_at is not null then now() - interval '91 days' end where id = v_id;
  if not found then raise exception 'Car not found' using errcode = 'P0002'; end if;
  return jsonb_build_object('ok', true, 'queued', jsonb_array_length(app.car_values_due(1, v_id)) > 0, 'rentalcover', app.rentalcover_check(v_id));
end $$;

-- ================================================================ Data Health: cars with no value on file
alter function app.data_health(timestamptz) rename to data_health_pre1202;
create function app.data_health(p_now timestamptz default now()) returns jsonb
language plpgsql stable security definer set search_path = public, app as $$
declare
  r jsonb := app.data_health_pre1202(p_now);
  x jsonb;
  c jsonb;
begin
  select coalesce(jsonb_agg(app.dh_item(v.id, format('%s: no value on file, so the Protection Plan (RentalCover) is not offered for it', app.vehicle_name(v.id)),
                                        '/admin/vehicles/' || v.id) order by v.make, v.model), '[]'::jsonb) into x
    from vehicles v
   where not coalesce(v.is_sample, false) and v.status not in ('exited', 'total_loss', 'declined')
     and (app.vehicle_cover_value(v.id) ->> 'value_cents') is null;
  c := app.dh_check('car_value_missing', 'Car value missing',
                    'Cars with no value on file: RentalCover covers up to $50,000, so the Protection Plan is offered only once the car''s value is entered on its page', x, '/admin/vehicles');
  return jsonb_set(jsonb_set(r, '{checks}', (r -> 'checks') || c), '{issues}', to_jsonb((r ->> 'issues')::integer + (c ->> 'count')::integer));
end $$;
select pg_temp.copy_grants('app.data_health(timestamptz)'::regprocedure, 'app.data_health_pre1202(timestamptz)'::regprocedure);

alter function app.data_health_keys(text) rename to data_health_keys_pre1202;
create function app.data_health_keys(p_fn text) returns text[]
language sql immutable as $$
  select case when p_fn = 'fleet' then app.data_health_keys_pre1202(p_fn) || array['car_value_missing'] else app.data_health_keys_pre1202(p_fn) end
$$;
select pg_temp.copy_grants('app.data_health_keys(text)'::regprocedure, 'app.data_health_keys_pre1202(text)'::regprocedure);

-- ================================================================ the door
alter function app.door(uuid, text, text, text, jsonb) rename to door_pre1202;
create function app.door(p_user uuid, p_aal text, p_call text, p_name text, p jsonb default '{}'::jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
begin
  if p_call = 'admin_do' and p_name = 'vehicle_cover_value' then
    perform app.door_begin(p_user, p_aal);
    return app.vehicle_cover_value_set(p_user, coalesce(p, '{}'::jsonb) - '_va');
  end if;
  if p_call in ('admin_do', 'ops_do') and p_name = 'vehicle_value_refresh' then
    if coalesce(p, '{}'::jsonb) ? '_va' then perform set_config('app.va_active', coalesce(p ->> '_va', ''), true); end if;
    perform app.door_begin(p_user, p_aal);
    return app.vehicle_value_refresh(p_user, coalesce(p, '{}'::jsonb) - '_va');
  end if;
  return app.door_pre1202(p_user, p_aal, p_call, p_name, p);
end $$;
select pg_temp.copy_grants('app.door(uuid, text, text, text, jsonb)'::regprocedure, 'app.door_pre1202(uuid, text, text, text, jsonb)'::regprocedure);

-- ================================================================ privileges
do $$
declare f record;
begin
  for f in select p.oid::regprocedure as sig from pg_proc p join pg_namespace n on n.oid = p.pronamespace
            where (n.nspname = 'app' and p.proname = any (array['vehicle_cover_value', 'rentalcover_check', 'rentalcover_allowed', 'bookings_rentalcover_cap', 'rentalcover_price',
                     'rentalcover_facts', 'rentalcover_record', 'rentalcover_quote_for', 'rentalcover_apply', 'vehicle_cover_value_set', 'price_quote_pre1202',
                     'admin_apply_booking_edit_pre1202', 'staff_offer_create_pre1202', 'staff_offer_form_pre1202', 'booking_car_pre1202', 'admin_vehicle_pre1202',
                     'data_health_pre1202', 'data_health_keys_pre1202', 'door_pre1202',
                     'car_values_due', 'server_jobs_due_pre1202', 'vehicle_value_refresh']))
               or (n.nspname = 'public' and p.proname in ('server_rentalcover_facts', 'server_rentalcover_record', 'server_rentalcover_apply', 'server_car_values_due', 'server_car_value_save'))
  loop
    execute format('revoke all on function %s from public, anon, authenticated', f.sig);
    execute format('grant execute on function %s to service_role', f.sig);
  end loop;
end $$;
