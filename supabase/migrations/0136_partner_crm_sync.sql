-- 0136_partner_crm_sync.sql
-- The partner CRM link (docs/changes/2026-10-24-01-motors-ghl.md). The owner, October 24, 2026: "I also need to set up
-- the CRM integration with 01 Motors so I can connect to their GoHighLevel CRM so that they can see all of our cars and
-- inventory available", and their cars, availability and photos coming to CarmaCars too.
--
-- 1. partner_crm_connections: one per partner (01 Motors first). Their GoHighLevel location and Private Integration
--    token (the token in Supabase Vault; the row keeps only the vault id and the last four characters), what we share,
--    the partner price rule, where their cars come from, the leads switch, the referral code of the booking links and
--    the feed key's version, and the last sync's result.
-- 2. What goes to them: app.partner_crm_outbound_cars. The owner's rule (October 24): ONLY CarmaCars' own cars
--    (supply_type 'company') and program owners' cars ('program_owner'). A partner car (01 Motors' own, or any other
--    partner's) is never sent, whatever the settings say: the function filters on supply_type itself, and the suite
--    (supabase/tests/85_partner_crm.sql) checks no partner car is ever in the payload. Only cars on the site (a public
--    listing row), never a sample car. Each with the partner price (the site's rates, or adjusted by a percentage), the
--    next 30 and 60 days, its photos and a booking link that tells us the partner sent the renter (/p/<code>/<car>).
-- 3. What comes from them: their cars (a custom object or products in their GoHighLevel, or a feed URL), matched to
--    their partner cars (0093) by the remote id, then the sheet name, then make, model, trim and colour; a car not
--    found is added as their partner car (on the partner-rate basis, the markup rules of 0093) and published only when
--    the setting says so. Their rates become the car's sheet rates; their booked dates become calendar blocks; their
--    photos are copied for a car with none of its own.
-- 4. Leads both ways (off until an Admin turns them on): a request for one of their cars, or one their link sent us,
--    becomes a contact and an opportunity in their pipeline; an opportunity they move to a chosen stage becomes a lead
--    here.
-- 5. The job: the Worker's five-minute tick runs it when the database says so (server_jobs_due 'crm': every 15 minutes,
--    and soon after a change to a car, a rate, a listing, a photo, a booking or a block).
-- 6. Admin > Settings > Partners through the door (admin_read 'partner_crm', admin_do 'partner_crm_save',
--    'partner_crm_disconnect', 'partner_crm_sync_now', 'partner_crm_feed_rotate', 'partner_crm_inbound_item'); the token
--    itself through public.server_partner_crm_token (service role only, never through the door, never returned).
-- 7. Admin > Today: a link that keeps failing.
-- 8. The guides.

-- ================================================================ 1. the connection
create table if not exists partner_crm_connections (
  id                  uuid primary key default gen_random_uuid(),
  partner_id          uuid not null unique references partners (id) on delete cascade,
  provider            text not null default 'gohighlevel' check (provider in ('gohighlevel')),
  location_id         text check (location_id ~ '^[A-Za-z0-9_-]{6,64}$'),
  token_ref           uuid,
  token_hint          text check (token_hint is null or length(token_hint) <= 8),
  token_store         text check (token_store in ('vault', 'database')),
  token_set_at        timestamptz,
  token_set_by        uuid references users (id),
  api_version         text not null default '2021-07-28' check (api_version in ('2021-07-28', '2021-04-15', 'v3')),
  enabled             boolean not null default true,
  -- what goes to them
  share_cars          boolean not null default true,
  share_owner_cars    boolean not null default true,
  share_rates         boolean not null default true,
  share_availability  boolean not null default true,
  share_photos        boolean not null default true,
  outbound_target     text not null default 'auto' check (outbound_target in ('auto', 'custom_object', 'products')),
  object_key          text not null default 'carmacars_vehicles' check (object_key ~ '^[a-z][a-z0-9_]{2,40}$'),
  price_mode          text not null default 'site' check (price_mode in ('site', 'percent')),
  price_adjust_bps    integer not null default 0 check (price_adjust_bps between -5000 and 5000),
  -- what comes from them
  inbound_enabled     boolean not null default true,
  inbound_source      text not null default 'auto' check (inbound_source in ('auto', 'custom_object', 'products', 'feed', 'off')),
  inbound_object_key  text check (inbound_object_key is null or inbound_object_key ~ '^[a-z][a-z0-9_.]{2,60}$'),
  inbound_feed_url    text check (inbound_feed_url is null or inbound_feed_url ~ '^https://[^[:space:]]+$'),
  inbound_publish     boolean not null default false,
  inbound_photos      boolean not null default true,
  inbound_blocks      boolean not null default true,
  -- leads both ways
  leads_enabled       boolean not null default false,
  leads_since         timestamptz,
  pipeline_id         text check (pipeline_id is null or pipeline_id ~ '^[A-Za-z0-9_-]{4,64}$'),
  pipeline_stage_id   text check (pipeline_stage_id is null or pipeline_stage_id ~ '^[A-Za-z0-9_-]{4,64}$'),
  inbound_stage_id    text check (inbound_stage_id is null or inbound_stage_id ~ '^[A-Za-z0-9_-]{4,64}$'),
  -- the booking links and the feed
  referral_code       text not null unique check (referral_code ~ '^[a-z0-9]+(-[a-z0-9]+)*$' and length(referral_code) between 3 and 30),
  feed_version        integer not null default 1 check (feed_version > 0),
  -- the last results
  detected_target     text check (detected_target in ('custom_object', 'products')),
  sync_requested_at   timestamptz,
  running_since       timestamptz,
  last_sync_at        timestamptz,
  last_sync_ok        boolean,
  last_error          text,
  failing_since       timestamptz,
  last_counts         jsonb not null default '{}'::jsonb,
  last_inbound_at     timestamptz,
  last_test_at        timestamptz,
  last_test           jsonb not null default '{}'::jsonb,
  created_by          uuid references users (id),
  created_at          timestamptz not null default now(),
  updated_at          timestamptz not null default now(),
  check ((token_ref is null) = (token_store is null))
);
create trigger partner_crm_connections_updated before update on partner_crm_connections for each row execute function app.set_updated_at();
comment on table partner_crm_connections is 'A partner''s CRM link (0136): their GoHighLevel location, the token''s vault id (never the token), what is shared both ways, the partner price rule, leads, the booking links'' code, the feed key''s version and the last results';
comment on column partner_crm_connections.token_ref is 'The id of the token in Supabase Vault (vault.secrets), or in app.crm_secrets where the vault is absent (the local and test databases only)';
comment on column partner_crm_connections.price_mode is 'site: the partner sees the site''s rates; percent: the site''s rates adjusted by price_adjust_bps (negative: below the site), to the nearest dollar';
comment on column partner_crm_connections.share_owner_cars is 'Program owners'' cars go too (with CarmaCars'' own); never a partner car (0136)';
comment on column partner_crm_connections.inbound_publish is 'A car of theirs not found here is added as their partner car and published at once (true) or left for a review in Admin (false)';

-- what we created in their CRM, per car
create table if not exists partner_crm_records (
  connection_id  uuid not null references partner_crm_connections (id) on delete cascade,
  vehicle_id     uuid not null references vehicles (id) on delete cascade,
  remote_kind    text not null check (remote_kind in ('object_record', 'product')),
  remote_id      text not null check (length(remote_id) between 1 and 80),
  price_id       text,
  payload_hash   text,
  synced_at      timestamptz not null default now(),
  primary key (connection_id, vehicle_id, remote_kind)
);
comment on table partner_crm_records is 'Each of our cars in a partner''s CRM (0136): the record or product id there and the hash of what was sent (unchanged: not sent again)';

-- their cars as their CRM or feed holds them
create table if not exists partner_crm_inbound (
  id             uuid primary key default gen_random_uuid(),
  connection_id  uuid not null references partner_crm_connections (id) on delete cascade,
  remote_kind    text not null check (remote_kind in ('object_record', 'product', 'feed')),
  remote_id      text not null check (length(remote_id) between 1 and 120),
  name           text,
  data           jsonb not null default '{}'::jsonb,
  vehicle_id     uuid references vehicles (id) on delete set null,
  status         text not null default 'review' check (status in ('linked', 'created', 'review', 'skipped', 'gone')),
  message        text,
  first_seen_at  timestamptz not null default now(),
  last_seen_at   timestamptz not null default now(),
  unique (connection_id, remote_kind, remote_id)
);
create index if not exists partner_crm_inbound_vehicle on partner_crm_inbound (vehicle_id) where vehicle_id is not null;
comment on table partner_crm_inbound is 'A partner''s car as their CRM or feed holds it (0136), normalised (data), and the partner car it is (linked), was added as (created), waits for (review) or was set aside (skipped); gone: no longer in their list';

-- their booked dates, as calendar blocks on their cars here
create table if not exists partner_crm_blocks (
  block_id    uuid primary key references vehicle_calendar_blocks (id) on delete cascade,
  inbound_id  uuid not null references partner_crm_inbound (id) on delete cascade,
  starts_on   date not null,
  ends_on     date not null
);
-- their photos copied here
create table if not exists partner_crm_photos (
  vehicle_id  uuid not null references vehicles (id) on delete cascade,
  url_hash    text not null,
  photo_id    uuid references vehicle_photos (id) on delete set null,
  created_at  timestamptz not null default now(),
  primary key (vehicle_id, url_hash)
);

-- every run: a sync, a test, a sync asked for by an Admin
create table if not exists partner_crm_runs (
  id             uuid primary key default gen_random_uuid(),
  connection_id  uuid not null references partner_crm_connections (id) on delete cascade,
  kind           text not null check (kind in ('sync', 'test')),
  started_at     timestamptz not null default now(),
  finished_at    timestamptz,
  ok             boolean,
  counts         jsonb not null default '{}'::jsonb,
  error          text,
  by_user        uuid references users (id)
);
create index if not exists partner_crm_runs_conn on partner_crm_runs (connection_id, started_at desc);

-- leads both ways
create table if not exists partner_crm_leads (
  id                     uuid primary key default gen_random_uuid(),
  connection_id          uuid not null references partner_crm_connections (id) on delete cascade,
  direction              text not null check (direction in ('to_partner', 'from_partner')),
  reason                 text not null check (reason in ('partner_car', 'referral', 'partner_stage')),
  booking_id             uuid references bookings (id) on delete set null,
  lead_id                uuid references leads (id) on delete set null,
  remote_contact_id      text,
  remote_opportunity_id  text,
  status                 text not null default 'queued' check (status in ('queued', 'sent', 'failed', 'skipped', 'received')),
  attempts               integer not null default 0,
  error                  text,
  created_at             timestamptz not null default now(),
  sent_at                timestamptz
);
create unique index if not exists partner_crm_leads_booking on partner_crm_leads (connection_id, booking_id) where direction = 'to_partner' and booking_id is not null;
create unique index if not exists partner_crm_leads_opportunity on partner_crm_leads (connection_id, remote_opportunity_id) where direction = 'from_partner';

-- a booking a partner's link sent us (/p/<code>/<car>: the cookie, then the request)
create table if not exists partner_referrals (
  booking_id  uuid primary key references bookings (id) on delete cascade,
  partner_id  uuid not null references partners (id) on delete cascade,
  code        text not null,
  created_at  timestamptz not null default now()
);
comment on table partner_referrals is 'A booking request made after a visitor came through a partner''s booking link (0136): the partner gets the lead in their CRM when leads are on';

-- the token where Supabase Vault is absent (the local and test databases): never granted to anyone
create table if not exists app.crm_secrets (
  id          uuid primary key default gen_random_uuid(),
  secret      text not null,
  created_at  timestamptz not null default now()
);
revoke all on app.crm_secrets from public, anon, authenticated;
comment on table app.crm_secrets is 'Stand-in for Supabase Vault where the vault is absent (local and test databases only; 0136). Production keeps partner tokens in vault.secrets.';

do $$
declare t text;
begin
  foreach t in array array['partner_crm_connections', 'partner_crm_records', 'partner_crm_inbound', 'partner_crm_blocks', 'partner_crm_photos',
                           'partner_crm_runs', 'partner_crm_leads', 'partner_referrals'] loop
    execute format('alter table %I enable row level security', t);
    execute format('revoke all on %I from anon', t);
    execute format('create policy admin_all on %I for all to authenticated using (app.is_admin()) with check (app.is_admin())', t);
  end loop;
end $$;
-- no row audit on the link (its status columns change every run): the Admin's changes write their own audit lines

-- ================================================================ the token: Supabase Vault (or the stand-in)
create or replace function app.crm_vault() returns boolean
language sql stable as $$ select to_regprocedure('vault.create_secret(text, text, text)') is not null $$;

create or replace function app.crm_secret_put(p_ref uuid, p_secret text, p_name text) returns uuid
language plpgsql security definer set search_path = public, app as $$
declare
  v_id uuid := p_ref;
begin
  if app.crm_vault() then
    if v_id is not null and exists (select 1 from vault.secrets s where s.id = v_id) then
      execute 'select vault.update_secret($1, $2)' using v_id, p_secret;
    else
      execute 'select vault.create_secret($1, $2, $3)' into v_id using p_secret, p_name || '-' || left(gen_random_uuid()::text, 8), 'Partner CRM token (migration 0136)';
    end if;
  else
    if v_id is not null and exists (select 1 from app.crm_secrets s where s.id = v_id) then
      update app.crm_secrets set secret = p_secret where id = v_id;
    else
      insert into app.crm_secrets (secret) values (p_secret) returning id into v_id;
    end if;
  end if;
  return v_id;
end $$;

create or replace function app.crm_secret_get(p_ref uuid) returns text
language plpgsql stable security definer set search_path = public, app as $$
declare
  v text;
begin
  if p_ref is null then return null; end if;
  if app.crm_vault() then
    execute 'select decrypted_secret from vault.decrypted_secrets where id = $1' into v using p_ref;
  else
    select secret into v from app.crm_secrets where id = p_ref;
  end if;
  return v;
end $$;

create or replace function app.crm_secret_drop(p_ref uuid) returns void
language plpgsql security definer set search_path = public, app as $$
begin
  if p_ref is null then return; end if;
  if app.crm_vault() then
    execute 'delete from vault.secrets where id = $1' using p_ref;
  else
    delete from app.crm_secrets where id = p_ref;
  end if;
end $$;

-- ================================================================ 2. what goes to them
-- The partner price of one of the site's rates.
create or replace function app.partner_crm_price(p_cents bigint, p_mode text, p_bps integer) returns bigint
language sql immutable as $$
  select case when p_cents is null then null
              when p_mode = 'percent' then (round(p_cents::numeric * (10000 + coalesce(p_bps, 0)) / 1000000) * 100)::bigint
              else p_cents end
$$;

-- A car's next p_days days (Toronto days): free today, the next free day, free days in 30 and 60, the booked runs.
-- Busy: a confirmed or on-rent booking that holds the calendar, or a calendar block (as app.vehicle_is_available).
create or replace function app.partner_crm_availability(p_vehicle uuid, p_days integer default 60) returns jsonb
language sql stable security definer set search_path = public, app as $$
  with d0 as (select app.today() d),
  days as (
    select g::date d, (g::date::timestamp at time zone 'America/Toronto') s, ((g::date + 1)::timestamp at time zone 'America/Toronto') e
      from d0, generate_series(d0.d, d0.d + greatest(least(p_days, 120), 1) - 1, interval '1 day') g),
  busy as (
    select x.d, exists (select 1 from bookings b where b.vehicle_id = p_vehicle and b.blocks_calendar and b.status in ('confirmed', 'on_rent')
                          and b.pickup_at < x.e and b.return_at > x.s)
             or exists (select 1 from vehicle_calendar_blocks c where c.vehicle_id = p_vehicle and c.removed_at is null
                          and c.starts_at < x.e and (c.ends_at is null or c.ends_at > x.s)) b
      from days x),
  runs as (
    select min(d) f, max(d) t from (select d, d - (row_number() over (order by d))::integer grp from busy where b) r group by grp)
  select jsonb_build_object(
    'available_today', not coalesce((select b from busy where d = (select d from d0)), false),
    'next_free_date', (select min(d) from busy where not b),
    'free_days_30', (select count(*) from busy where not b and d < (select d from d0) + 30),
    'free_days_60', (select count(*) from busy where not b and d < (select d from d0) + 60),
    'booked', coalesce((select jsonb_agg(jsonb_build_object('from', f, 'to', t) order by f) from runs), '[]'::jsonb))
$$;

-- The cars a partner sees. THE RULE (the owner, October 24, 2026): only CarmaCars' own cars and program owners' cars,
-- never a partner car, whatever the connection says. On the site (a public listing row), not a sample car, not retired.
create or replace function app.partner_crm_outbound_cars(p_conn uuid) returns jsonb
language plpgsql stable security definer set search_path = public, app as $$
declare
  c partner_crm_connections;
  s site_settings;
  v_base text;
begin
  select * into c from partner_crm_connections where id = p_conn;
  if c.id is null or not c.share_cars then return '[]'::jsonb; end if;
  select * into s from site_settings limit 1;
  v_base := rtrim(coalesce(nullif(s.site_url, ''), 'https://carmacars.ca'), '/');
  return coalesce((
    select jsonb_agg(x.car order by x.make, x.model, x.year desc nulls last, x.code)
      from (
        select v.make, v.model, v.year, v.car_code code,
          jsonb_build_object(
            'vehicle_id', v.id, 'car_code', v.car_code, 'supply_type', v.supply_type,
            'name', app.vehicle_name(v.id), 'year', case when v.year_approximate then null else v.year end,
            'make', v.make, 'model', v.model, 'trim', v.trim, 'colour', v.colour, 'class', v.class,
            'seats', r ->> 'seats', 'doors', r ->> 'doors', 'body_style', r ->> 'body_style', 'transmission', r ->> 'transmission',
            'drivetrain', r ->> 'drivetrain', 'fuel', r ->> 'fuel', 'slug', r ->> 'slug',
            'location', coalesce(nullif(r ->> 'home_area', '') || ', ' || coalesce(s.city, 'Toronto'), coalesce(s.city, 'Toronto')),
            'car_url', v_base || coalesce(r ->> 'path', '/cars/' || (r ->> 'slug')),
            'book_url', v_base || '/p/' || c.referral_code || '/' || (r ->> 'slug'),
            'photos', case when c.share_photos then coalesce((select jsonb_agg(ph ->> 'path' order by n) from jsonb_array_elements(app.public_listing_photos(v.id)) with ordinality p(ph, n)
                                                               where coalesce((ph ->> 'sample')::boolean, false) = false and coalesce(ph ->> 'path', '') <> ''), '[]'::jsonb) else '[]'::jsonb end,
            'photos_representative', c.share_photos and not exists (select 1 from jsonb_array_elements(app.public_listing_photos(v.id)) ph where coalesce((ph ->> 'sample')::boolean, false) = false),
            'daily_cents', case when c.share_rates then app.partner_crm_price((r ->> 'daily_rate_cents')::bigint, c.price_mode, c.price_adjust_bps) end,
            'weekly_cents', case when c.share_rates then app.partner_crm_price((r ->> 'weekly_rate_cents')::bigint, c.price_mode, c.price_adjust_bps) end,
            'monthly_cents', case when c.share_rates then app.partner_crm_price((r ->> 'monthly_rate_cents')::bigint, c.price_mode, c.price_adjust_bps) end,
            'deposit_cents', case when c.share_rates then (r ->> 'deposit_cents')::bigint end,
            'km_per_day', r ->> 'km_allowance_per_day',
            'availability', case when c.share_availability then app.partner_crm_availability(v.id, 60) end) car
          from vehicles v
          cross join lateral (select app.public_listing_row(v.id) r) pr
         where v.supply_type in ('company', 'program_owner')       -- the rule: never 'partner'
           and v.partner_id is null
           and (c.share_owner_cars or v.supply_type = 'company')
           and v.retired_at is null
           and not coalesce(v.is_sample, false)
           and pr.r is not null) x), '[]'::jsonb);
end $$;

-- ================================================================ 3. what comes from them
-- One of their cars, normalised by the Worker (src/features/partner-crm/mapping.ts): remote_kind, remote_id, name, make,
-- model, year, trim, colour, class, seats, doors, body, transmission, base_cents, multi_day_cents, long_term_cents, photos[],
-- booked[{from, to}]. Matched, added or left for review; their rates and booked dates applied. Returns the photos to copy.
-- p_full: the items are their whole list (a sync), so one not in it is gone; false for one item an Admin acted on.
create or replace function app.partner_crm_inbound_apply(p_conn uuid, p_items jsonb, p_full boolean default true) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  c partner_crm_connections;
  pr partners;
  it jsonb;
  ib partner_crm_inbound;
  v_vehicle uuid;
  v_status text;
  v_msg text;
  v_b bigint; v_m bigint; v_l bigint;
  v_class text;
  v_seen text[] := '{}';
  v_counts jsonb := '{"linked": 0, "created": 0, "review": 0, "gone": 0, "blocks": 0}'::jsonb;
  v_photos jsonb := '[]'::jsonb;
  v_pub jsonb;
  rng jsonb;
  v_block uuid;
  v_keep uuid[];
begin
  select * into c from partner_crm_connections where id = p_conn;
  select * into pr from partners where id = c.partner_id;
  if c.id is null or pr.id is null then raise exception 'No such partner link' using errcode = 'P0002'; end if;
  -- what this changes is the partner's own cars: it never asks for another sync of ours
  perform set_config('app.crm_applying', 'on', true);
  for it in select value from jsonb_array_elements(coalesce(p_items, '[]'::jsonb)) loop
    continue when coalesce(it ->> 'remote_id', '') = '' or coalesce(it ->> 'remote_kind', '') not in ('object_record', 'product', 'feed');
    v_seen := v_seen || ((it ->> 'remote_kind') || ':' || (it ->> 'remote_id'));
    insert into partner_crm_inbound (connection_id, remote_kind, remote_id, name, data)
    values (c.id, it ->> 'remote_kind', it ->> 'remote_id', left(it ->> 'name', 200), it)
    on conflict (connection_id, remote_kind, remote_id) do update set name = excluded.name, data = excluded.data, last_seen_at = now(),
      status = case when partner_crm_inbound.status = 'gone' then case when partner_crm_inbound.vehicle_id is null then 'review' else 'linked' end else partner_crm_inbound.status end
    returning * into ib;
    v_msg := null;
    if ib.status = 'skipped' then continue; end if;
    v_vehicle := ib.vehicle_id;
    -- a link that points to a car that is no longer theirs is dropped
    if v_vehicle is not null and not exists (select 1 from vehicles v where v.id = v_vehicle and v.partner_id = pr.id and v.retired_at is null) then v_vehicle := null; end if;
    if v_vehicle is null then
      select v.id into v_vehicle from vehicles v
       where v.partner_id = pr.id and v.retired_at is null
         and not exists (select 1 from partner_crm_inbound o where o.connection_id = c.id and o.vehicle_id = v.id and o.id <> ib.id and o.status in ('linked', 'created'))
         and (lower(v.partner_sheet_name) = lower(it ->> 'name')
              or (lower(v.make) = lower(it ->> 'make') and lower(v.model) = lower(it ->> 'model')
                  and lower(coalesce(v.trim, '')) = lower(coalesce(it ->> 'trim', '')) and lower(coalesce(v.colour, '')) = lower(coalesce(it ->> 'colour', ''))))
       order by (lower(v.partner_sheet_name) = lower(it ->> 'name')) desc nulls last, v.created_at
       limit 1;
      v_status := case when v_vehicle is not null then 'linked' end;
    else
      v_status := case when ib.status = 'created' then 'created' else 'linked' end;
    end if;
    v_b := nullif(it ->> 'base_cents', '')::bigint;
    v_m := least(coalesce(nullif(it ->> 'multi_day_cents', '')::bigint, v_b), v_b);
    v_l := least(coalesce(nullif(it ->> 'long_term_cents', '')::bigint, v_m), v_m);
    -- not here yet: added as their partner car when it has a make, a model and a rate
    if v_vehicle is null then
      v_class := lower(coalesce(it ->> 'class', ''));
      if v_class not in ('economy', 'standard', 'premium', 'suv', 'luxury', 'exotic') then
        v_class := case when coalesce(v_b, 0) >= 60000 then 'exotic' when coalesce(v_b, 0) >= 22500 then 'luxury' else 'premium' end;
      end if;
      if coalesce(it ->> 'make', '') = '' or coalesce(it ->> 'model', '') = '' or coalesce(v_b, 0) <= 0 then
        v_status := 'review';
        v_msg := 'Needs a make, a model and a daily rate before it can be added';
      else
        v_vehicle := gen_random_uuid();
        insert into vehicles (id, owner_id, supply_type, partner_id, year, make, model, trim, colour, fuel, class, status, management_mode,
                              enrollment_date, body_type, allows_18_to_20, title_brand_clear, year_approximate, partner_sheet_name)
        values (v_vehicle, pr.owner_id, 'partner', pr.id, coalesce(nullif(it ->> 'year', '')::smallint, extract(year from now())::smallint), it ->> 'make', it ->> 'model',
                nullif(it ->> 'trim', ''), nullif(it ->> 'colour', ''), 'gasoline', v_class::vehicle_class, 'available', 'managed', app.today(),
                nullif(it ->> 'body', ''), false, true, nullif(it ->> 'year', '') is null,
                case when exists (select 1 from vehicles x where x.partner_id = pr.id and lower(x.partner_sheet_name) = lower(it ->> 'name')) then null else nullif(left(it ->> 'name', 120), '') end);
        insert into partner_rates (vehicle_id, base_cents, multi_day_cents, long_term_cents, source)
        values (v_vehicle, v_b, v_m, v_l, 'Their CRM (' || (it ->> 'remote_kind') || ')');
        perform app.vehicle_after_add(v_vehicle, null, jsonb_build_object('class', v_class));
        perform app.partner_rates_apply(v_vehicle, null);
        perform app.ensure_listing(v_vehicle);
        update vehicle_listings set seats = coalesce(nullif(it ->> 'seats', '')::smallint, seats), doors = coalesce(nullif(it ->> 'doors', '')::smallint, doors),
               transmission = coalesce(nullif(it ->> 'transmission', ''), transmission), body_style = coalesce(nullif(it ->> 'body', ''), body_style)
         where vehicle_id = v_vehicle;
        perform app.listing_template_copy(v_vehicle);
        if c.inbound_publish then
          v_pub := app.listing_auto_publish(v_vehicle, 'added');
        end if;
        insert into audit_log (actor_user_id, action, entity_table, entity_id, after)
        values (null, 'partner_crm_car_added', 'vehicles', v_vehicle::text, jsonb_build_object('partner', pr.business_name, 'remote', it ->> 'remote_id', 'published', v_pub));
        v_status := 'created';
      end if;
    elsif v_b is not null and v_b > 0 then
      -- their rates become the car's sheet rates (the renter's follow, 0093)
      if not exists (select 1 from partner_rates r where r.vehicle_id = v_vehicle and r.base_cents = v_b and r.multi_day_cents = v_m and r.long_term_cents = v_l) then
        insert into partner_rates (vehicle_id, base_cents, multi_day_cents, long_term_cents, source)
        values (v_vehicle, v_b, v_m, v_l, 'Their CRM (' || (it ->> 'remote_kind') || ')')
        on conflict (vehicle_id) do update set base_cents = excluded.base_cents, multi_day_cents = excluded.multi_day_cents, long_term_cents = excluded.long_term_cents, source = excluded.source;
        perform app.partner_rates_apply(v_vehicle, null);
      end if;
    end if;
    update partner_crm_inbound set vehicle_id = v_vehicle, status = v_status, message = v_msg where id = ib.id;
    v_counts := jsonb_set(v_counts, array[v_status], to_jsonb(coalesce((v_counts ->> v_status)::integer, 0) + 1));
    continue when v_vehicle is null;
    -- their booked dates: blocks on the car here, kept in step
    if c.inbound_blocks and jsonb_typeof(it -> 'booked') = 'array' then
      v_keep := '{}';
      for rng in select value from jsonb_array_elements(it -> 'booked') loop
        continue when nullif(rng ->> 'from', '') is null or nullif(rng ->> 'to', '') is null or (rng ->> 'to')::date < app.today() or (rng ->> 'to')::date < (rng ->> 'from')::date;
        select k.block_id into v_block from partner_crm_blocks k join vehicle_calendar_blocks b on b.id = k.block_id
         where k.inbound_id = ib.id and k.starts_on = (rng ->> 'from')::date and k.ends_on = (rng ->> 'to')::date and b.vehicle_id = v_vehicle;
        if v_block is null then
          insert into vehicle_calendar_blocks (vehicle_id, reason, source, starts_at, ends_at, note)
          values (v_vehicle, 'external_booking', 'external', ((rng ->> 'from')::date)::timestamp at time zone 'America/Toronto',
                  (((rng ->> 'to')::date) + 1)::timestamp at time zone 'America/Toronto', left(pr.business_name || ' (their CRM): booked', 300))
          returning id into v_block;
          insert into partner_crm_blocks (block_id, inbound_id, starts_on, ends_on) values (v_block, ib.id, (rng ->> 'from')::date, (rng ->> 'to')::date);
          v_counts := jsonb_set(v_counts, '{blocks}', to_jsonb((v_counts ->> 'blocks')::integer + 1));
        else
          update vehicle_calendar_blocks set removed_at = null, removed_reason = null where id = v_block and removed_at is not null and removed_by is null;
        end if;
        v_keep := v_keep || v_block;
        v_block := null;
      end loop;
      update vehicle_calendar_blocks b set removed_at = now(), removed_reason = 'No longer booked in ' || pr.business_name || '''s CRM'
        from partner_crm_blocks k where k.block_id = b.id and k.inbound_id = ib.id and b.removed_at is null and not (b.id = any (v_keep));
    end if;
    -- their photos, for a car with no photos of its own yet
    if c.inbound_photos and jsonb_typeof(it -> 'photos') = 'array' and jsonb_array_length(it -> 'photos') > 0
       and not exists (select 1 from vehicle_photos ph where ph.vehicle_id = v_vehicle and ph.replaced_at is null and ph.status <> 'rejected'
                         and not exists (select 1 from partner_crm_photos x where x.photo_id = ph.id)) then
      v_photos := v_photos || jsonb_build_object('vehicle_id', v_vehicle, 'urls',
        coalesce((select jsonb_agg(u order by n) from (select u, n from jsonb_array_elements_text(it -> 'photos') with ordinality p(u, n)
                    where u ~ '^https://' and not exists (select 1 from partner_crm_photos x where x.vehicle_id = v_vehicle and x.url_hash = md5(u)) limit 8) q), '[]'::jsonb),
        'have', (select count(*) from partner_crm_photos x where x.vehicle_id = v_vehicle));
    end if;
  end loop;
  -- their cars no longer in their list: marked gone, their blocks lifted (the car itself stays, staff decide)
  if not p_full then
    return jsonb_build_object('counts', v_counts, 'photos', v_photos);
  end if;
  with g as (
    update partner_crm_inbound i set status = 'gone', last_seen_at = i.last_seen_at
     where i.connection_id = c.id and i.status <> 'gone' and not ((i.remote_kind || ':' || i.remote_id) = any (v_seen))
       and i.remote_kind = any (array(select distinct value ->> 'remote_kind' from jsonb_array_elements(coalesce(p_items, '[]'::jsonb))))
    returning i.id)
  select jsonb_set(v_counts, '{gone}', to_jsonb(count(*))) into v_counts from g;
  update vehicle_calendar_blocks b set removed_at = now(), removed_reason = 'No longer in ' || pr.business_name || '''s CRM'
    from partner_crm_blocks k join partner_crm_inbound i on i.id = k.inbound_id
   where k.block_id = b.id and i.connection_id = c.id and i.status = 'gone' and b.removed_at is null;
  update partner_crm_connections set last_inbound_at = now() where id = c.id;
  return jsonb_build_object('counts', v_counts, 'photos', v_photos);
end $$;

-- ================================================================ 4. leads
-- The requests to send them (leads on): a request for one of their cars, or one their link sent us, since leads were
-- turned on, not sent yet (failed ones again, up to 5 tries).
create or replace function app.partner_crm_leads_due(p_conn uuid) returns jsonb
language sql stable security definer set search_path = public, app as $$
  select coalesce(jsonb_agg(jsonb_build_object(
           'booking_id', b.id, 'booking_number', b.booking_number, 'reason', x.reason, 'status', b.status,
           'name', r.legal_name, 'email', r.email, 'phone', r.mobile, 'car', app.vehicle_name(b.vehicle_id),
           'pickup_at', b.pickup_at, 'return_at', b.return_at, 'total_cents', b.total_due_at_booking_cents, 'created_at', b.created_at)
           order by b.created_at), '[]'::jsonb)
    from partner_crm_connections c
    join lateral (
      select b.id, 'partner_car'::text reason from bookings b join vehicles v on v.id = b.vehicle_id
       where v.partner_id = c.partner_id and b.created_at >= c.leads_since
      union
      select f.booking_id, 'referral' from partner_referrals f join bookings b on b.id = f.booking_id
       where f.partner_id = c.partner_id and b.created_at >= c.leads_since
       and not exists (select 1 from bookings b2 join vehicles v2 on v2.id = b2.vehicle_id where b2.id = f.booking_id and v2.partner_id = c.partner_id)
    ) x on true
    join bookings b on b.id = x.id
    join renters r on r.id = b.renter_id
   where c.id = p_conn and c.leads_enabled and c.leads_since is not null and c.pipeline_id is not null and c.pipeline_stage_id is not null
     and not exists (select 1 from partner_crm_leads l where l.connection_id = c.id and l.direction = 'to_partner' and l.booking_id = b.id
                       and (l.status in ('sent', 'skipped') or l.attempts >= 5))
   limit 25
$$;

-- ================================================================ 5. the job (service role)
create or replace function public.server_partner_crm_due() returns jsonb
language sql stable security definer set search_path = public, app as $$
  select coalesce(jsonb_agg(c.id order by c.last_sync_at nulls first), '[]'::jsonb) from partner_crm_connections c
   where c.enabled and c.token_ref is not null and c.location_id is not null
     and (c.running_since is null or c.running_since < now() - interval '10 minutes')
     and (c.last_sync_at is null or c.last_sync_at < now() - interval '15 minutes'
          or c.sync_requested_at > c.last_sync_at
          -- failing: every 15 minutes still, but no faster
          )
$$;

-- What a run needs (never the token: server_partner_crm_secret). Marks the run started; a second run while one is going
-- (under 10 minutes) is refused.
create or replace function public.server_partner_crm_job(p_conn uuid, p_by uuid default null, p_kind text default 'sync') returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  c partner_crm_connections;
  pr partners;
  v_run uuid;
begin
  select * into c from partner_crm_connections where id = p_conn for update;
  if c.id is null then return jsonb_build_object('ok', false, 'error', 'No such partner link'); end if;
  if c.token_ref is null or c.location_id is null then return jsonb_build_object('ok', false, 'error', 'Not connected: paste their token and location ID first'); end if;
  if p_kind = 'sync' and c.running_since is not null and c.running_since > now() - interval '10 minutes' then
    return jsonb_build_object('ok', false, 'busy', true, 'error', 'A sync is already running');
  end if;
  select * into pr from partners where id = c.partner_id;
  if p_kind = 'sync' then update partner_crm_connections set running_since = now() where id = c.id; end if;
  insert into partner_crm_runs (connection_id, kind, by_user) values (c.id, case when p_kind = 'test' then 'test' else 'sync' end, p_by) returning id into v_run;
  return jsonb_build_object('ok', true, 'run_id', v_run,
    'connection', jsonb_build_object('id', c.id, 'partner_id', c.partner_id, 'partner', pr.business_name, 'location_id', c.location_id, 'api_version', c.api_version,
      'enabled', c.enabled, 'share_cars', c.share_cars, 'outbound_target', c.outbound_target, 'detected_target', c.detected_target, 'object_key', c.object_key,
      'inbound_enabled', c.inbound_enabled, 'inbound_source', c.inbound_source, 'inbound_object_key', c.inbound_object_key, 'inbound_feed_url', c.inbound_feed_url,
      'leads_enabled', c.leads_enabled, 'pipeline_id', c.pipeline_id, 'pipeline_stage_id', c.pipeline_stage_id, 'inbound_stage_id', c.inbound_stage_id,
      'referral_code', c.referral_code, 'price_mode', c.price_mode, 'price_adjust_bps', c.price_adjust_bps),
    'cars', case when p_kind = 'sync' then app.partner_crm_outbound_cars(c.id) else '[]'::jsonb end,
    'records', coalesce((select jsonb_agg(jsonb_build_object('vehicle_id', r.vehicle_id, 'remote_kind', r.remote_kind, 'remote_id', r.remote_id, 'price_id', r.price_id, 'payload_hash', r.payload_hash))
                           from partner_crm_records r where r.connection_id = c.id), '[]'::jsonb),
    'leads', case when p_kind = 'sync' then app.partner_crm_leads_due(c.id) else '[]'::jsonb end,
    'known_opportunities', coalesce((select jsonb_agg(l.remote_opportunity_id) from partner_crm_leads l where l.connection_id = c.id and l.remote_opportunity_id is not null), '[]'::jsonb),
    'site', (select jsonb_build_object('url', rtrim(coalesce(nullif(s.site_url, ''), 'https://carmacars.ca'), '/'), 'name', coalesce(s.brand_name, 'CarmaCars'), 'city', s.city) from site_settings s limit 1));
end $$;

-- The token of a link, for the server's call to their CRM only.
create or replace function public.server_partner_crm_secret(p_conn uuid) returns text
language sql stable security definer set search_path = public, app as $$
  select app.crm_secret_get(c.token_ref) from partner_crm_connections c where c.id = p_conn
$$;

-- A run's result. p: run_id, connection_id, kind ('sync' | 'test'), ok, error, target, counts, records [{vehicle_id,
-- remote_kind, remote_id, price_id, payload_hash}], removed [{vehicle_id, remote_kind}], inbound (null: not read) [items],
-- leads [{booking_id, reason, ok, contact_id, opportunity_id, error, skipped}], partner_leads [{opportunity_id, name, email,
-- phone, car, note, value_cents}], test {...}.
create or replace function public.server_partner_crm_done(p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  c partner_crm_connections;
  pr partners;
  r jsonb;
  v_in jsonb := null;
  v_lead uuid;
  v_ok boolean := coalesce((p ->> 'ok')::boolean, false);
  v_kind text := coalesce(p ->> 'kind', 'sync');
  v_counts jsonb := coalesce(p -> 'counts', '{}'::jsonb);
  v_err text := left(nullif(p ->> 'error', ''), 1000);
begin
  select * into c from partner_crm_connections where id = (p ->> 'connection_id')::uuid for update;
  if c.id is null then raise exception 'No such partner link' using errcode = 'P0002'; end if;
  select * into pr from partners where id = c.partner_id;
  -- our cars in their CRM
  for r in select value from jsonb_array_elements(coalesce(p -> 'records', '[]'::jsonb)) loop
    -- the rule again: a partner car never gets a record in a partner's CRM
    continue when not exists (select 1 from vehicles v where v.id = (r ->> 'vehicle_id')::uuid and v.supply_type in ('company', 'program_owner') and v.partner_id is null);
    insert into partner_crm_records (connection_id, vehicle_id, remote_kind, remote_id, price_id, payload_hash, synced_at)
    values (c.id, (r ->> 'vehicle_id')::uuid, r ->> 'remote_kind', r ->> 'remote_id', nullif(r ->> 'price_id', ''), r ->> 'payload_hash', now())
    on conflict (connection_id, vehicle_id, remote_kind) do update set remote_id = excluded.remote_id, price_id = excluded.price_id, payload_hash = excluded.payload_hash, synced_at = now();
  end loop;
  delete from partner_crm_records x using jsonb_array_elements(coalesce(p -> 'removed', '[]'::jsonb)) d
   where x.connection_id = c.id and x.vehicle_id = (d.value ->> 'vehicle_id')::uuid and x.remote_kind = d.value ->> 'remote_kind';
  -- their cars
  if jsonb_typeof(p -> 'inbound') = 'array' then
    v_in := app.partner_crm_inbound_apply(c.id, p -> 'inbound');
    v_counts := v_counts || jsonb_build_object('inbound', v_in -> 'counts');
  end if;
  -- leads we sent them
  for r in select value from jsonb_array_elements(coalesce(p -> 'leads', '[]'::jsonb)) loop
    insert into partner_crm_leads (connection_id, direction, reason, booking_id, remote_contact_id, remote_opportunity_id, status, attempts, error, sent_at)
    values (c.id, 'to_partner', coalesce(r ->> 'reason', 'partner_car'), (r ->> 'booking_id')::uuid, r ->> 'contact_id', r ->> 'opportunity_id',
            case when (r ->> 'skipped')::boolean then 'skipped' when (r ->> 'ok')::boolean then 'sent' else 'failed' end, 1, left(r ->> 'error', 500),
            case when (r ->> 'ok')::boolean then now() end)
    on conflict (connection_id, booking_id) where direction = 'to_partner' and booking_id is not null do update
      set remote_contact_id = coalesce(excluded.remote_contact_id, partner_crm_leads.remote_contact_id),
          remote_opportunity_id = coalesce(excluded.remote_opportunity_id, partner_crm_leads.remote_opportunity_id),
          status = excluded.status, attempts = partner_crm_leads.attempts + 1, error = excluded.error, sent_at = coalesce(excluded.sent_at, partner_crm_leads.sent_at);
  end loop;
  -- leads they sent us (an opportunity moved to the chosen stage)
  for r in select value from jsonb_array_elements(coalesce(p -> 'partner_leads', '[]'::jsonb)) loop
    continue when coalesce(r ->> 'opportunity_id', '') = '' or (nullif(btrim(r ->> 'email'), '') is null and nullif(btrim(r ->> 'phone'), '') is null);
    continue when exists (select 1 from partner_crm_leads l where l.connection_id = c.id and l.direction = 'from_partner' and l.remote_opportunity_id = r ->> 'opportunity_id');
    insert into leads (kind, name, email, phone, message, payload, source, referrer)
    values ('other', left(nullif(btrim(r ->> 'name'), ''), 200), lower(nullif(btrim(r ->> 'email'), '')), nullif(btrim(r ->> 'phone'), ''),
            left(concat_ws('. ', 'Sent by ' || pr.business_name || ' from their CRM', nullif(r ->> 'car', ''), nullif(r ->> 'note', '')), 2000),
            jsonb_build_object('partner', pr.business_name, 'partner_id', pr.id, 'opportunity_id', r ->> 'opportunity_id', 'car', r ->> 'car', 'value_cents', r ->> 'value_cents'),
            'partner', pr.business_name)
    returning id into v_lead;
    insert into partner_crm_leads (connection_id, direction, reason, lead_id, remote_opportunity_id, status)
    values (c.id, 'from_partner', 'partner_stage', v_lead, r ->> 'opportunity_id', 'received');
  end loop;
  -- the result
  if v_kind = 'test' then
    update partner_crm_connections set last_test_at = now(), last_test = coalesce(p -> 'test', '{}'::jsonb) || jsonb_build_object('ok', v_ok, 'error', v_err),
           detected_target = coalesce(nullif(p ->> 'target', ''), detected_target)
     where id = c.id;
  else
    update partner_crm_connections
       set running_since = null, last_sync_at = now(), last_sync_ok = v_ok, last_error = v_err, last_counts = v_counts,
           failing_since = case when v_ok then null else coalesce(failing_since, now()) end,
           detected_target = coalesce(nullif(p ->> 'target', ''), detected_target)
     where id = c.id;
  end if;
  update partner_crm_runs set finished_at = now(), ok = v_ok, counts = v_counts, error = v_err where id = nullif(p ->> 'run_id', '')::uuid and connection_id = c.id;
  delete from partner_crm_runs where connection_id = c.id and id not in (select id from partner_crm_runs where connection_id = c.id order by started_at desc limit 200);
  return jsonb_build_object('ok', true, 'counts', v_counts, 'photos', coalesce(v_in -> 'photos', '[]'::jsonb));
end $$;

-- One of their photos copied into the public bucket by the server: becomes a photo of their car here (approved, public).
create or replace function public.server_partner_crm_photo(p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  v_vehicle uuid := (p ->> 'vehicle_id')::uuid;
  v_n integer;
  v_id uuid;
begin
  if not exists (select 1 from vehicles v where v.id = v_vehicle and v.supply_type = 'partner') then raise exception 'Not a partner car' using errcode = '22023'; end if;
  if exists (select 1 from partner_crm_photos x where x.vehicle_id = v_vehicle and x.url_hash = md5(p ->> 'url')) then return jsonb_build_object('ok', true, 'duplicate', true); end if;
  select count(*) into v_n from vehicle_photos where vehicle_id = v_vehicle and replaced_at is null;
  insert into vehicle_photos (vehicle_id, angle, shot_type, original_path, processed_path, status, sort_order, is_cover, alt_text, width, height,
                              byte_size, mime_type, variants, background_status, is_public, approved_at)
  values (v_vehicle, case when v_n = 0 then 'front_left' else 'other' end, case when v_n = 0 then 'front_left' else 'other' end, p ->> 'path', p ->> 'path', 'approved', v_n,
          v_n = 0 and not exists (select 1 from vehicle_photos x where x.vehicle_id = v_vehicle and x.is_cover and x.replaced_at is null),
          left(app.vehicle_name(v_vehicle), 200), nullif(p ->> 'width', '')::integer, nullif(p ->> 'height', '')::integer, nullif(p ->> 'bytes', '')::bigint,
          p ->> 'mime', '[]'::jsonb, 'done', true, now())
  returning id into v_id;
  insert into partner_crm_photos (vehicle_id, url_hash, photo_id) values (v_vehicle, md5(p ->> 'url'), v_id);
  return jsonb_build_object('ok', true, 'id', v_id);
end $$;

-- The read-only feed and the widget: the same cars as the sync, and the key's version the server checks.
create or replace function public.server_partner_feed(p_partner uuid) returns jsonb
language sql stable security definer set search_path = public, app as $$
  select jsonb_build_object('feed_version', c.feed_version, 'enabled', c.enabled, 'partner', p.business_name,
           'cars', case when c.enabled then app.partner_crm_outbound_cars(c.id) else '[]'::jsonb end,
           'site', (select jsonb_build_object('url', rtrim(coalesce(nullif(s.site_url, ''), 'https://carmacars.ca'), '/'), 'name', coalesce(s.brand_name, 'CarmaCars')) from site_settings s limit 1))
    from partner_crm_connections c join partners p on p.id = c.partner_id where c.partner_id = p_partner
$$;

-- The booking link's code (/p/<code>/<car>): which partner, for the cookie.
create or replace function public.partner_referral_code_ok(p_code text) returns boolean
language sql stable security definer set search_path = public, app as $$
  select exists (select 1 from partner_crm_connections c where c.referral_code = lower(p_code))
$$;

-- A request sent after a partner's booking link: remembered for the partner's lead.
create or replace function public.server_partner_referral(p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  c partner_crm_connections;
  v_booking uuid;
begin
  select * into c from partner_crm_connections where referral_code = lower(p ->> 'code');
  select id into v_booking from bookings where booking_number = p ->> 'booking_number';
  if c.id is null or v_booking is null then return jsonb_build_object('ok', false); end if;
  insert into partner_referrals (booking_id, partner_id, code) values (v_booking, c.partner_id, c.referral_code) on conflict (booking_id) do nothing;
  if c.leads_enabled then update partner_crm_connections set sync_requested_at = now() where id = c.id; end if;
  return jsonb_build_object('ok', true);
end $$;

-- The token (pasted in Admin > Settings > Partners): through the server only, after the Admin is checked here again.
-- Stored in Supabase Vault; the row keeps its vault id and last four characters. An empty token disconnects.
create or replace function public.server_partner_crm_token(p_admin uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  c partner_crm_connections;
  v_token text := btrim(coalesce(p ->> 'token', ''));
  v_loc text := nullif(btrim(coalesce(p ->> 'location_id', '')), '');
  v_ref uuid;
begin
  perform app.assert_admin(p_admin);
  perform app.partner_crm_ensure(p_admin, (p ->> 'partner_id')::uuid);
  select * into c from partner_crm_connections where partner_id = (p ->> 'partner_id')::uuid for update;
  if v_loc is not null and v_loc !~ '^[A-Za-z0-9_-]{6,64}$' then raise exception 'The location ID is the code in their GoHighLevel address after /location/ (letters and digits)' using errcode = '22023'; end if;
  if v_token = '' then
    raise exception 'Paste their Private Integration token' using errcode = '22023';
  end if;
  if length(v_token) < 20 or length(v_token) > 400 or v_token ~ '[[:space:]]' then
    raise exception 'That does not look like a Private Integration token (it starts with pit- and has no spaces)' using errcode = '22023';
  end if;
  v_ref := app.crm_secret_put(c.token_ref, v_token, 'partner-crm-' || c.referral_code);
  update partner_crm_connections
     set token_ref = v_ref, token_store = case when app.crm_vault() then 'vault' else 'database' end, token_hint = right(v_token, 4),
         token_set_at = now(), token_set_by = p_admin, location_id = coalesce(v_loc, location_id), enabled = true,
         sync_requested_at = now(), last_error = null, failing_since = null
   where id = c.id returning * into c;
  insert into audit_log (actor_user_id, action, entity_table, entity_id, after)
  values (p_admin, 'partner_crm_token', 'partner_crm_connections', c.id::text, jsonb_build_object('location_id', c.location_id, 'token_hint', c.token_hint, 'store', c.token_store));
  return jsonb_build_object('ok', true, 'token_hint', c.token_hint, 'location_id', c.location_id, 'store', c.token_store);
end $$;

-- ================================================================ 6. Admin: read and change through the door
create or replace function app.partner_crm_slug(p_name text) returns text
language sql immutable as $$
  select left(trim(both '-' from regexp_replace(lower(coalesce(p_name, 'partner')), '[^a-z0-9]+', '-', 'g')), 30)
$$;

-- The partner's link row, made the first time it is needed (the settings page, the token).
create or replace function app.partner_crm_ensure(p_by uuid, p_partner uuid) returns uuid
language plpgsql security definer set search_path = public, app as $$
declare
  pr partners;
  v_id uuid;
  v_code text;
begin
  select id into v_id from partner_crm_connections where partner_id = p_partner;
  if v_id is not null then return v_id; end if;
  select * into pr from partners where id = p_partner;
  if pr.id is null then raise exception 'Partner not found' using errcode = 'P0002'; end if;
  v_code := app.partner_crm_slug(pr.business_name);
  if length(v_code) < 3 then v_code := 'partner-' || substr(pr.id::text, 1, 6); end if;
  if exists (select 1 from partner_crm_connections where referral_code = v_code) then v_code := left(v_code, 23) || '-' || substr(pr.id::text, 1, 6); end if;
  insert into partner_crm_connections (partner_id, referral_code, created_by) values (pr.id, v_code, p_by)
  on conflict (partner_id) do nothing returning id into v_id;
  return coalesce(v_id, (select id from partner_crm_connections where partner_id = p_partner));
end $$;

create or replace function app.partner_crm_row(c partner_crm_connections) returns jsonb
language sql stable security definer set search_path = public, app as $$
  select (to_jsonb(c) - 'token_ref' - 'created_by' - 'token_set_by')
    || jsonb_build_object('connected', c.token_ref is not null and c.location_id is not null,
         'token_set_by_name', (select u.full_name from users u where u.id = c.token_set_by),
         'running', c.running_since is not null and c.running_since > now() - interval '10 minutes')
$$;

create or replace function app.partner_crm_read(p_by uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  c partner_crm_connections;
  pr partners;
  v_id uuid;
begin
  perform app.assert_admin(p_by);
  if nullif(p ->> 'partner_id', '') is null then
    -- every partner and its link
    return jsonb_build_object('partners', coalesce((
      select jsonb_agg(jsonb_build_object('id', x.id, 'business_name', x.business_name, 'status', x.status, 'partner_number', x.partner_number,
               'cars', (select count(*) from vehicles v where v.partner_id = x.id and v.retired_at is null),
               'link', (select app.partner_crm_row(k) from partner_crm_connections k where k.partner_id = x.id)) order by x.business_name)
        from partners x), '[]'::jsonb),
      'shareable', (select count(*) from vehicles v where v.supply_type in ('company', 'program_owner') and v.partner_id is null and v.retired_at is null
                      and not coalesce(v.is_sample, false) and app.public_listing_row(v.id) is not null));
  end if;
  select * into pr from partners where id = (p ->> 'partner_id')::uuid;
  if pr.id is null then return null; end if;
  v_id := app.partner_crm_ensure(p_by, pr.id);
  select * into c from partner_crm_connections where id = v_id;
  return jsonb_build_object(
    'partner', jsonb_build_object('id', pr.id, 'business_name', pr.business_name, 'partner_number', pr.partner_number, 'status', pr.status,
                                  'markup_bps', pr.markup_bps, 'commission_bps', pr.commission_bps, 'payout_basis', pr.payout_basis),
    'link', app.partner_crm_row(c),
    'shared', jsonb_build_object(
      'company', (select count(*) from jsonb_array_elements(app.partner_crm_outbound_cars(c.id)) x where x ->> 'supply_type' = 'company'),
      'program_owner', (select count(*) from jsonb_array_elements(app.partner_crm_outbound_cars(c.id)) x where x ->> 'supply_type' = 'program_owner'),
      'in_their_crm', (select count(*) from partner_crm_records r where r.connection_id = c.id)),
    'sample', (select coalesce(jsonb_agg(x), '[]'::jsonb) from (select x from jsonb_array_elements(app.partner_crm_outbound_cars(c.id)) x limit 5) s),
    'partner_cars', (select count(*) from vehicles v where v.partner_id = pr.id and v.retired_at is null),
    'inbound', coalesce((select jsonb_agg(jsonb_build_object('id', i.id, 'remote_kind', i.remote_kind, 'remote_id', i.remote_id, 'name', i.name, 'status', i.status,
                           'message', i.message, 'vehicle_id', i.vehicle_id, 'vehicle_name', case when i.vehicle_id is not null then app.vehicle_name(i.vehicle_id) end,
                           'base_cents', i.data ->> 'base_cents', 'photos', jsonb_array_length(coalesce(i.data -> 'photos', '[]'::jsonb)), 'last_seen_at', i.last_seen_at)
                           order by (i.status = 'review') desc, i.name)
                         from partner_crm_inbound i where i.connection_id = c.id), '[]'::jsonb),
    'runs', coalesce((select jsonb_agg(jsonb_build_object('kind', r.kind, 'started_at', r.started_at, 'finished_at', r.finished_at, 'ok', r.ok, 'counts', r.counts, 'error', r.error,
                        'by', (select u.full_name from users u where u.id = r.by_user)) order by r.started_at desc)
                      from (select * from partner_crm_runs r where r.connection_id = c.id order by r.started_at desc limit 10) r), '[]'::jsonb),
    'leads', coalesce((select jsonb_agg(jsonb_build_object('direction', l.direction, 'reason', l.reason, 'status', l.status, 'error', l.error, 'created_at', l.created_at,
                         'booking_number', (select b.booking_number from bookings b where b.id = l.booking_id), 'lead_id', l.lead_id) order by l.created_at desc)
                       from (select * from partner_crm_leads l where l.connection_id = c.id order by l.created_at desc limit 20) l), '[]'::jsonb),
    'their_cars_for_link', coalesce((select jsonb_agg(jsonb_build_object('id', v.id, 'name', app.vehicle_name(v.id)) order by v.make, v.model)
                                       from vehicles v where v.partner_id = pr.id and v.retired_at is null), '[]'::jsonb));
end $$;

create or replace function app.partner_crm_save(p_by uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  c partner_crm_connections;
  v_allowed constant text[] := array['location_id', 'api_version', 'enabled', 'share_cars', 'share_owner_cars', 'share_rates', 'share_availability', 'share_photos',
    'outbound_target', 'object_key', 'price_mode', 'price_adjust_bps', 'inbound_enabled', 'inbound_source', 'inbound_object_key', 'inbound_feed_url',
    'inbound_publish', 'inbound_photos', 'inbound_blocks', 'leads_enabled', 'pipeline_id', 'pipeline_stage_id', 'inbound_stage_id', 'referral_code'];
  v jsonb := coalesce(p -> 'values', p - 'partner_id');
  k text;
begin
  perform app.assert_admin(p_by);
  perform app.partner_crm_ensure(p_by, (p ->> 'partner_id')::uuid);
  select * into c from partner_crm_connections where partner_id = (p ->> 'partner_id')::uuid for update;
  if exists (select 1 from jsonb_object_keys(v) x where not (x = any (v_allowed))) then
    raise exception 'Not a setting of the partner link: %', (select string_agg(x, ', ') from jsonb_object_keys(v) x where not (x = any (v_allowed))) using errcode = '22023';
  end if;
  -- empty text is no value
  for k in select x from jsonb_object_keys(v) x where jsonb_typeof(v -> x) = 'string' loop
    v := v || jsonb_build_object(k, nullif(btrim(v ->> k), ''));
  end loop;
  if v ? 'referral_code' then v := v || jsonb_build_object('referral_code', lower(v ->> 'referral_code')); end if;
  if (v ->> 'price_mode') = 'site' then v := v || '{"price_adjust_bps": 0}'::jsonb; end if;
  if (v ->> 'inbound_object_key') = c.object_key or (v ->> 'inbound_object_key') = 'custom_objects.' || c.object_key then
    raise exception 'That is the object we fill with our cars: choose the object that holds their cars' using errcode = '22023';
  end if;
  update partner_crm_connections set
    location_id = case when v ? 'location_id' then v ->> 'location_id' else location_id end,
    api_version = coalesce(case when v ? 'api_version' then v ->> 'api_version' end, api_version),
    enabled = coalesce((v ->> 'enabled')::boolean, enabled),
    share_cars = coalesce((v ->> 'share_cars')::boolean, share_cars),
    share_owner_cars = coalesce((v ->> 'share_owner_cars')::boolean, share_owner_cars),
    share_rates = coalesce((v ->> 'share_rates')::boolean, share_rates),
    share_availability = coalesce((v ->> 'share_availability')::boolean, share_availability),
    share_photos = coalesce((v ->> 'share_photos')::boolean, share_photos),
    outbound_target = coalesce(v ->> 'outbound_target', outbound_target),
    object_key = coalesce(v ->> 'object_key', object_key),
    price_mode = coalesce(v ->> 'price_mode', price_mode),
    price_adjust_bps = coalesce((v ->> 'price_adjust_bps')::integer, price_adjust_bps),
    inbound_enabled = coalesce((v ->> 'inbound_enabled')::boolean, inbound_enabled),
    inbound_source = coalesce(v ->> 'inbound_source', inbound_source),
    inbound_object_key = case when v ? 'inbound_object_key' then v ->> 'inbound_object_key' else inbound_object_key end,
    inbound_feed_url = case when v ? 'inbound_feed_url' then v ->> 'inbound_feed_url' else inbound_feed_url end,
    inbound_publish = coalesce((v ->> 'inbound_publish')::boolean, inbound_publish),
    inbound_photos = coalesce((v ->> 'inbound_photos')::boolean, inbound_photos),
    inbound_blocks = coalesce((v ->> 'inbound_blocks')::boolean, inbound_blocks),
    leads_enabled = coalesce((v ->> 'leads_enabled')::boolean, leads_enabled),
    leads_since = case when coalesce((v ->> 'leads_enabled')::boolean, leads_enabled) and not leads_enabled then now()
                       when not coalesce((v ->> 'leads_enabled')::boolean, leads_enabled) then null else leads_since end,
    pipeline_id = case when v ? 'pipeline_id' then v ->> 'pipeline_id' else pipeline_id end,
    pipeline_stage_id = case when v ? 'pipeline_stage_id' then v ->> 'pipeline_stage_id' else pipeline_stage_id end,
    inbound_stage_id = case when v ? 'inbound_stage_id' then v ->> 'inbound_stage_id' else inbound_stage_id end,
    referral_code = coalesce(v ->> 'referral_code', referral_code),
    sync_requested_at = now()
  where id = c.id returning * into c;
  if c.leads_enabled and (c.pipeline_id is null or c.pipeline_stage_id is null) then
    raise exception 'Choose their pipeline and its stage for the leads (Test connection lists them)' using errcode = '22023';
  end if;
  if c.inbound_source = 'feed' and c.inbound_enabled and c.inbound_feed_url is null then raise exception 'Give their feed address (https://...)' using errcode = '22023'; end if;
  if c.inbound_source = 'custom_object' and c.inbound_enabled and c.inbound_object_key is null then raise exception 'Give the key of the object that holds their cars' using errcode = '22023'; end if;
  insert into audit_log (actor_user_id, action, entity_table, entity_id, after) values (p_by, 'partner_crm_save', 'partner_crm_connections', c.id::text, v);
  return app.partner_crm_row(c);
exception when unique_violation then
  raise exception 'Another partner uses that booking link code' using errcode = '23505';
end $$;

create or replace function app.partner_crm_disconnect(p_by uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  c partner_crm_connections;
begin
  perform app.assert_admin(p_by);
  select * into c from partner_crm_connections where partner_id = (p ->> 'partner_id')::uuid for update;
  if c.id is null then raise exception 'Not connected' using errcode = 'P0002'; end if;
  perform app.crm_secret_drop(c.token_ref);
  update partner_crm_connections set token_ref = null, token_store = null, token_hint = null, token_set_at = null, token_set_by = null, running_since = null
   where id = c.id returning * into c;
  insert into audit_log (actor_user_id, action, entity_table, entity_id, after) values (p_by, 'partner_crm_disconnect', 'partner_crm_connections', c.id::text, '{}'::jsonb);
  return app.partner_crm_row(c);
end $$;

create or replace function app.partner_crm_feed_rotate(p_by uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  c partner_crm_connections;
begin
  perform app.assert_admin(p_by);
  perform app.partner_crm_ensure(p_by, (p ->> 'partner_id')::uuid);
  update partner_crm_connections set feed_version = feed_version + 1 where partner_id = (p ->> 'partner_id')::uuid returning * into c;
  insert into audit_log (actor_user_id, action, entity_table, entity_id, after) values (p_by, 'partner_crm_feed_rotate', 'partner_crm_connections', c.id::text, jsonb_build_object('feed_version', c.feed_version));
  return app.partner_crm_row(c);
end $$;

create or replace function app.partner_crm_sync_now(p_by uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  c partner_crm_connections;
begin
  perform app.assert_admin(p_by);
  update partner_crm_connections set sync_requested_at = now() where partner_id = (p ->> 'partner_id')::uuid returning * into c;
  if c.id is null or c.token_ref is null then raise exception 'Connect first: paste their token and location ID' using errcode = '22023'; end if;
  return app.partner_crm_row(c);
end $$;

-- One of their cars that waits: skip it, add it as their car, or link it to one of their cars here.
create or replace function app.partner_crm_inbound_item(p_by uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  i partner_crm_inbound;
  c partner_crm_connections;
  v_vehicle uuid := nullif(p ->> 'vehicle_id', '')::uuid;
  v_publish boolean;
begin
  perform app.assert_admin(p_by);
  select * into i from partner_crm_inbound where id = (p ->> 'id')::uuid for update;
  if i.id is null then raise exception 'Not found' using errcode = 'P0002'; end if;
  select * into c from partner_crm_connections where id = i.connection_id;
  case p ->> 'action'
    when 'skip' then update partner_crm_inbound set status = 'skipped', message = 'Set aside by an Admin' where id = i.id;
    when 'review' then update partner_crm_inbound set status = 'review', message = null, vehicle_id = null where id = i.id;
    when 'link' then
      if not exists (select 1 from vehicles v where v.id = v_vehicle and v.partner_id = c.partner_id) then raise exception 'Choose one of their cars' using errcode = '22023'; end if;
      update partner_crm_inbound set status = 'linked', vehicle_id = v_vehicle, message = null where id = i.id;
      perform app.partner_crm_inbound_apply(c.id, jsonb_build_array(i.data), false);
    when 'add' then
      v_publish := c.inbound_publish;
      update partner_crm_inbound set status = 'review', vehicle_id = null where id = i.id;
      update partner_crm_connections set inbound_publish = coalesce((p ->> 'publish')::boolean, inbound_publish) where id = c.id;
      perform app.partner_crm_inbound_apply(c.id, jsonb_build_array(i.data), false);
      update partner_crm_connections set inbound_publish = v_publish where id = c.id;
    else raise exception 'Unknown action' using errcode = '22023';
  end case;
  insert into audit_log (actor_user_id, action, entity_table, entity_id, after) values (p_by, 'partner_crm_inbound_item', 'partner_crm_inbound', i.id::text, p - 'id');
  select * into i from partner_crm_inbound where id = i.id;
  return to_jsonb(i);
end $$;

alter function app.door(uuid, text, text, text, jsonb) rename to door_pre0136;
create or replace function app.door(p_user uuid, p_aal text, p_call text, p_name text, p jsonb default '{}'::jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
begin
  if p_call = 'admin_read' and p_name = 'partner_crm' then
    perform app.door_begin(p_user, p_aal);
    return app.partner_crm_read(p_user, coalesce(p, '{}'::jsonb));
  end if;
  if p_call = 'admin_do' and p_name in ('partner_crm_save', 'partner_crm_disconnect', 'partner_crm_sync_now', 'partner_crm_feed_rotate', 'partner_crm_inbound_item') then
    perform app.door_begin(p_user, p_aal);
    return case p_name
      when 'partner_crm_save' then app.partner_crm_save(p_user, coalesce(p, '{}'::jsonb))
      when 'partner_crm_disconnect' then app.partner_crm_disconnect(p_user, coalesce(p, '{}'::jsonb))
      when 'partner_crm_sync_now' then app.partner_crm_sync_now(p_user, coalesce(p, '{}'::jsonb))
      when 'partner_crm_feed_rotate' then app.partner_crm_feed_rotate(p_user, coalesce(p, '{}'::jsonb))
      else app.partner_crm_inbound_item(p_user, coalesce(p, '{}'::jsonb)) end;
  end if;
  return app.door_pre0136(p_user, p_aal, p_call, p_name, p);
end $$;

-- ================================================================ 5b. on change, and the cron gate
-- A change to what a partner sees asks for a sync soon (the next five-minute tick). Statement-level, cheap: nothing to do
-- without a connected link, a link already waiting is left alone, and a busy row is skipped (never waited for).
create or replace function app.partner_crm_touch() returns trigger
language plpgsql security definer set search_path = public, app as $$
begin
  if current_setting('app.crm_applying', true) = 'on' then return null; end if;
  update partner_crm_connections k set sync_requested_at = now()
   where k.id in (select c.id from partner_crm_connections c
                   where c.enabled and c.token_ref is not null and c.share_cars
                     and (c.sync_requested_at is null or c.sync_requested_at <= coalesce(c.last_sync_at, '-infinity'::timestamptz))
                   for update skip locked);
  return null;
end $$;
do $$
declare t text;
begin
  foreach t in array array['vehicles', 'rate_cards', 'vehicle_listings', 'vehicle_photos', 'bookings', 'vehicle_calendar_blocks'] loop
    execute format('create trigger partner_crm_touch after insert or update or delete on %I for each statement execute function app.partner_crm_touch()', t);
  end loop;
end $$;

alter function app.server_jobs_due() rename to server_jobs_due_pre0136;
create or replace function app.server_jobs_due() returns jsonb
language plpgsql security definer set search_path = public, app as $$
begin
  return app.server_jobs_due_pre0136() || jsonb_build_object('crm', jsonb_array_length(public.server_partner_crm_due()) > 0);
end $$;

-- ================================================================ 7. Admin > Today: a link that keeps failing
alter function app.site_setup_problems() rename to site_setup_problems_pre0136;
create or replace function app.site_setup_problems() returns jsonb
language sql stable security definer set search_path = public, app as $$
  select coalesce(app.site_setup_problems_pre0136(), '[]'::jsonb) || coalesce((
    select jsonb_agg(jsonb_build_object('field', 'partner_crm', 'blocks', null, 'href', '/admin/settings/partners/' || c.partner_id,
             'message', format('The CRM link with %s has failed since %s: %s. Open Settings > Partners and press Test connection',
                               p.business_name, to_char(c.failing_since at time zone 'America/Toronto', 'Mon DD, HH24:MI'), coalesce(left(c.last_error, 160), 'no answer'))))
      from partner_crm_connections c join partners p on p.id = c.partner_id
     where c.enabled and c.token_ref is not null and c.failing_since < now() - interval '1 hour'), '[]'::jsonb)
$$;

-- ================================================================ privileges
do $$
declare
  f record;
begin
  for f in
    select p.oid::regprocedure as sig from pg_proc p join pg_namespace n on n.oid = p.pronamespace
     where (n.nspname = 'app' and p.proname = any (array['door', 'door_pre0136', 'crm_secret_put', 'crm_secret_get', 'crm_secret_drop', 'crm_vault',
              'partner_crm_price', 'partner_crm_availability', 'partner_crm_outbound_cars', 'partner_crm_inbound_apply', 'partner_crm_leads_due',
              'partner_crm_slug', 'partner_crm_ensure', 'partner_crm_row', 'partner_crm_read', 'partner_crm_save', 'partner_crm_disconnect',
              'partner_crm_feed_rotate', 'partner_crm_sync_now', 'partner_crm_inbound_item', 'server_jobs_due', 'server_jobs_due_pre0136']))
        or (n.nspname = 'public' and p.proname = any (array['server_partner_crm_due', 'server_partner_crm_job', 'server_partner_crm_secret', 'server_partner_crm_done',
              'server_partner_crm_photo', 'server_partner_feed', 'server_partner_referral', 'server_partner_crm_token']))
  loop
    execute format('revoke all on function %s from public, anon, authenticated', f.sig);
    execute format('grant execute on function %s to service_role', f.sig);
  end loop;
end $$;
revoke all on function public.partner_referral_code_ok(text) from public;
grant execute on function public.partner_referral_code_ok(text) to anon, authenticated, service_role;
revoke all on function app.partner_crm_touch() from public, anon, authenticated;
grant execute on function app.partner_crm_touch() to service_role;
revoke all on function app.site_setup_problems(), app.site_setup_problems_pre0136() from public, anon;
grant execute on function app.site_setup_problems(), app.site_setup_problems_pre0136() to authenticated, service_role;

-- 01 Motors' link row, ready for their token (nothing is sent until it is pasted)
select app.partner_crm_ensure(null, p.id) from partners p where p.business_name = '01 Motors';

-- ================================================================ 8. the guides
-- GUIDES 0136 START (generated by supabase/seed/0136_gen_guides.mjs from docs/guides/content; do not edit by hand)
select app.guide_release_section('admin', 'partners-company-cars-and-rentals-added-by-hand', 'chapter', 'fleet-and-listings', 'A car comes from one of three places: a program owner, CarmaCars itself, or a partner rental company. You add cars and rentals by hand, retire cars, and delete cars that were added by mistake.

## Add a car

**Cars** > **Vehicles**, then **Add a car**. Start with the VIN: everything else about the car comes from it.

1. Type or paste the VIN. At the 17th character the car is looked up: one line shows the year, make, model, trim, body, seats, doors, fuel, drive, gearbox and engine. Press Edit only if something is wrong.
2. When the VIN fits several trims, the form asks which trim it is: press the one on the car''s papers or badge, or **Not sure** (Admin > Today asks again).
3. No VIN at hand? Press **No VIN at hand? Add the car by its plate** and choose the year, make and model from the lists. The VIN can be added later; the details fill in then.
4. Tap the colour (it is not in the VIN). Leave it empty and it is read from the cover photo once the car has one.
5. Check the class. It is set from the make, model, body and age (a 2016 Porsche Macan is Premium, an SUV is SUV) and the line under it says why. Change it if it is wrong.
6. Choose who supplies it: **A program owner''s car** (choose the owner; the car starts its onboarding), **CarmaCars-owned (company fleet)** (no owner; all of its revenue is CarmaCars'') or **A partner rental company''s car** (choose the partner; leave the commission empty to use the partner''s).
7. The daily rate is filled in from similar cars, else the class. Keep it, change it, or empty it and set the rates later on the car''s Rates tab. Press **Add the car**.

> Tip: The title, description and features are written by themselves right after the car is added, from the VIN details. Change any of them on the car''s listing; a field you change is kept.

> Good to know: Every car gets a fleet number and its standard settings the moment it is added: a complete rate card (the daily rate you typed or the suggested one, weekend, weekly and monthly from it, the kilometres a day, the extra kilometre rate, the deposit and the delivery and pickup fee of its class) and drivers 18 to 20 allowed. Each value set this way says (Set automatically) on the car''s Overview and Rates tab until you change it. The defaults come from Settings: Program and Fee defaults.

> Tip: A VIN that does not add up (one character misread) shows a warning; you can still save it. A VIN the decoder cannot read asks only the year, make and model and never stops you: the details fill in when it is read later. The duplicate check runs as for every car: a VIN only once, a plate on one active car, and a likely twin waits for you in Similar cars before it is published.

The gearbox comes from the government''s fuel economy data for the model when it has one gearbox for it, or from the VIN when the VIN states it. Seats come from the VIN, or the usual number for the body (4 for a coupe or convertible, 5 for a sedan, SUV or hatchback). When either is not certain, Admin > Today shows **Confirm gearbox and seats**: press the gearbox and the number of seats, then **Save**. A car whose VIN fits several trims shows **Pick the trim** there: press the right one. Either way the title, description and search text are written again.

On a car''s page, **Who supplies the car** shows the supplier and the commission, and changes them. Vehicles filters by supply type.

## Partners

**People** > **Partners**. Partner rental companies whose cars we rent out on commission.

1. Press **Add a partner**: business and legal name, contacts, HST number, commission and insurance with its expiry date.
2. Open a partner for its cars, bookings, statements, payouts and documents. A warning shows when its insurance expires soon, and Staff tasks gets a reminder (Program settings sets how many days before).
3. Banking (Admins only): **Save the payout account** for the account we pay the partner into. The account number is stored encrypted. Press **Verify** once checked.
4. Portal: **Invite to the owner portal** gives the partner the owner portal with its cars, bookings, statements and the partner agreement, filled in and signed on screen in three taps.
5. Signed on paper? Press **Print the partner agreement**, then record the signed scan under Record a paper signature.

## A partner fleet on its own rates

Some partners send a price sheet of their own rates instead of sharing what the renter pays. 01 Motors works this way: its whole fleet is on the site, and staff manage its cars (it has no portal sign-in yet; add its email on the partner page and invite it later).

1. **People** > **Partners** > the partner. **Pricing** shows how it is paid: the renter pays the partner''s sheet rate plus the markup (10% unless you set another), rounded to the nearest dollar; CarmaCars keeps the markup plus its cut (20% of the sheet rate); the partner is owed the rest of its sheet rate. Press **Edit pricing** to change the markup, the cut or the basis for every car at once.
2. **Cars** lists each car with its sheet rates a day (1 to 2 days, 3 or more, 7 or more) and the renter''s rates. Press **Edit** on a car to change a negotiated rate, give that car its own markup or cut, mark it **Insurance included** or **No credit card needed**, or confirm its model year. The renter''s rates change at once.
3. The site shows these cars with their tiers (1 to 2 days, 3 to 6 days, 7 days or more) and "Guideline rates; final price confirmed after review". A car with insurance included needs no coverage choice from the renter (coverage option 4, confirmed by itself); a car with no credit card needed takes a debit card for the payment and the deposit. The deposit, the licence and identity checks and the ages stay the same.
4. The price sheet has no years, VINs or plates. Until you confirm the year, the site leaves it out and says "Year confirmed when you book"; an offer waits until the year is confirmed (Edit on the car, Model year). Add the plate and the VIN on the car''s page before its first handover.
5. Real photos: open the car (its name in Cars), **Photos**, and add them. Once approved they replace the eight studio stand-ins.

> Good to know: The partner''s monthly statement shows each rental at the sheet rate, the cut and the payout; never what the renter paid. A refund lowers the partner''s share in proportion; a discount CarmaCars gives comes out of the markup.

## Add a rental by hand

**Bookings** > **Add a rental**. For phone, walk-in, Turo, partner and insurer bookings, the owner using their own car, and placeholders: a rental already agreed. To send an offer instead, use Send an offer.

1. Quick start sets the usual choices in one tap: **Phone**, **Walk-in**, **Turo or another platform**, **Insurance replacement**, **Owner using own car** or **Placeholder**.
2. Choose the car and the dates. The calendar and the price are checked by themselves: clashes with other bookings and the cleaning time after each trip. An Admin may book over a clash with a reason.
3. The dates decide the case, shown under them (nothing to tick): a pickup ahead is an upcoming rental, handed over at pickup as usual. A pickup already passed with the return ahead is a rental already underway: it is recorded as on trip from the pickup you enter, on any active car (even one closed to public bookings), and anything a handover checks that is still missing (signature, licence check, coverage proof, deposit, condition report, insurance) becomes a task. A return already passed is a rental that has ended: kept as completed, paid another way or unpaid.
4. Find the renter by name, email or phone, or add a new one: name, email, phone, date of birth and licence. Add any other drivers.
5. Check the price: the car''s rates, extras, coverage and deposit. An Admin may set the price by hand; assistants use the rate sheet and the discounts allowed.
6. A car whose listing is not finished (a draft listing, onboarding, no photos or no rates yet) can be rented at once: it shows Listing not finished in the car list and stays off the public site. With no rates yet, type the rental charge for the whole rental and the reason.
7. An owner''s car that is not on the fleet insurance policy yet: only an Admin adds its rentals, and ticks I checked that this car is insured for this rental. An owner''s car needs its terms (Revenue Share) first. The handover still needs the car on the fleet policy: press **Insurer confirmed** once the insurer confirms it.
8. The rental is paid by: e-Transfer or cash (received), card on file (charged when the renter signs), payment link, platform payout (Turo), insurer billed later, cheque, bank transfer, or unpaid. The deposit is taken by card hold, cash, e-Transfer or no deposit.
9. The rental agreement: Send it to sign online, or Already signed on paper (a task asks for the scan). The calendar: untick Blocks the car''s calendar for an insurance replacement with dates not known yet, with the reason.
10. Tick **Do not email the renter** if they should not get the confirmation. Press **Add the rental**.

> Tip: The rental is on the calendars at once (a payment link waits for the payment). The renter signs the rental agreement in their portal, or on paper and you record it. With the saved card, nothing is charged when you add the rental: the card is charged when the renter presses Accept and sign, and until then the rental is awaiting signature. On the booking, **Verified in person** records a licence checked at the counter. A rental already underway can be paid by payment link (the renter signs, then pays from their booking) or the saved card, like an upcoming one.

## Retire or delete a car

**Cars** > **Retire or delete**, or the car''s own page.

1. **Retire this car** takes the car off the site and the calendars and keeps every record. It needs no future confirmed booking. **Restore** brings it back.
2. **Delete this car** removes a car added by mistake, with its photos. Only a car with nothing tied to money (no confirmed or paid booking, payment, statement, toll or damage). Type the plate or the name to confirm.
3. Booking requests that never confirmed and never took money (requested, offered, declined, expired) do not stop a delete. The confirmation lists them; they are removed with the car and a copy is kept. The renters stay on file.
4. On the same page, **Delete all sample cars** deletes every sample car that meets the rule at once, with its requests. Type DELETE SAMPLE CARS to confirm; the ones kept show why, with the booking numbers.

## Sample cars on the site

**Cars** > **Vehicles**, or **Settings** > **Site**. The 20 example cars the site started with, so the fleet never looks empty while the real cars are listed.

1. **Hide sample cars** asks first ("Hide all 20 sample cars from the site?"); press **Hide them** to take every sample car off the site at once, or **Keep them**. Nothing else stops it: not an enquiry, not an old request.
2. **Show sample cars** puts the 20 back, with their photos and rates. Ones that were deleted are made again.
3. On the site each one is marked "Example car". They never appear in search engines or the sitemap.
4. A request on a sample car is never a booking. When the person picks dates, the car page and the request form show a real car free for them (the same make and model first, else the same class and body at a similar price) with one tap to switch to it. If they keep the sample car, it becomes an enquiry (number EQ-1001 and up) and customer service gets the task Suggest a similar real car, naming the free real car.

> Tip: Hide the sample cars once enough real cars are on the site. Delete all sample cars removes them for good.

## Why a car is not on the site yet

**Cars** > **Vehicles**, the card Not on the site yet.

1. Every real car that is not on the site is listed with its next step first: the rates, Publish now, the listing review.
2. The same car is a line on To do with **Set rates and publish**. The car comes off both once it is on the site.
3. A car without photos is marked sample photos: once listed it shows a sample photo until its real photos are approved.

## Tolls when two rentals overlap

Bookings held for an insurer and other placeholders are never matched to a toll. When two real rentals overlap the toll time, nobody is charged automatically: the toll waits in the work queue under Two rentals, with both bookings, and you choose who pays.
', 'Partners, company cars and rentals added by hand', 'Add a car, partners, add a rental, retire or delete a car, sample cars and tolls with two rentals.',
  'A car comes from one of three places: a program owner, CarmaCars itself, or a partner rental company. You add cars and rentals by hand, retire cars, and delete cars that were added by mistake.

## Add a car

**Cars** > **Vehicles**, then **Add a car**. Start with the VIN: everything else about the car comes from it.

1. Type or paste the VIN. At the 17th character the car is looked up: one line shows the year, make, model, trim, body, seats, doors, fuel, drive, gearbox and engine. Press Edit only if something is wrong.
2. When the VIN fits several trims, the form asks which trim it is: press the one on the car''s papers or badge, or **Not sure** (Admin > Today asks again).
3. No VIN at hand? Press **No VIN at hand? Add the car by its plate** and choose the year, make and model from the lists. The VIN can be added later; the details fill in then.
4. Tap the colour (it is not in the VIN). Leave it empty and it is read from the cover photo once the car has one.
5. Check the class. It is set from the make, model, body and age (a 2016 Porsche Macan is Premium, an SUV is SUV) and the line under it says why. Change it if it is wrong.
6. Choose who supplies it: **A program owner''s car** (choose the owner; the car starts its onboarding), **CarmaCars-owned (company fleet)** (no owner; all of its revenue is CarmaCars'') or **A partner rental company''s car** (choose the partner; leave the commission empty to use the partner''s).
7. The daily rate is filled in from similar cars, else the class. Keep it, change it, or empty it and set the rates later on the car''s Rates tab. Press **Add the car**.

> Tip: The title, description and features are written by themselves right after the car is added, from the VIN details. Change any of them on the car''s listing; a field you change is kept.

> Good to know: Every car gets a fleet number and its standard settings the moment it is added: a complete rate card (the daily rate you typed or the suggested one, weekend, weekly and monthly from it, the kilometres a day, the extra kilometre rate, the deposit and the delivery and pickup fee of its class) and drivers 18 to 20 allowed. Each value set this way says (Set automatically) on the car''s Overview and Rates tab until you change it. The defaults come from Settings: Program and Fee defaults.

> Tip: A VIN that does not add up (one character misread) shows a warning; you can still save it. A VIN the decoder cannot read asks only the year, make and model and never stops you: the details fill in when it is read later. The duplicate check runs as for every car: a VIN only once, a plate on one active car, and a likely twin waits for you in Similar cars before it is published.

The gearbox comes from the government''s fuel economy data for the model when it has one gearbox for it, or from the VIN when the VIN states it. Seats come from the VIN, or the usual number for the body (4 for a coupe or convertible, 5 for a sedan, SUV or hatchback). When either is not certain, Admin > Today shows **Confirm gearbox and seats**: press the gearbox and the number of seats, then **Save**. A car whose VIN fits several trims shows **Pick the trim** there: press the right one. Either way the title, description and search text are written again.

On a car''s page, **Who supplies the car** shows the supplier and the commission, and changes them. Vehicles filters by supply type.

## Partners

**People** > **Partners**. Partner rental companies whose cars we rent out on commission.

1. Press **Add a partner**: business and legal name, contacts, HST number, commission and insurance with its expiry date.
2. Open a partner for its cars, bookings, statements, payouts and documents. A warning shows when its insurance expires soon, and Staff tasks gets a reminder (Program settings sets how many days before).
3. Banking (Admins only): **Save the payout account** for the account we pay the partner into. The account number is stored encrypted. Press **Verify** once checked.
4. Portal: **Invite to the owner portal** gives the partner the owner portal with its cars, bookings, statements and the partner agreement, filled in and signed on screen in three taps.
5. Signed on paper? Press **Print the partner agreement**, then record the signed scan under Record a paper signature.

## A partner fleet on its own rates

Some partners send a price sheet of their own rates instead of sharing what the renter pays. 01 Motors works this way: its whole fleet is on the site, and staff manage its cars (it has no portal sign-in yet; add its email on the partner page and invite it later).

1. **People** > **Partners** > the partner. **Pricing** shows how it is paid: the renter pays the partner''s sheet rate plus the markup (10% unless you set another), rounded to the nearest dollar; CarmaCars keeps the markup plus its cut (20% of the sheet rate); the partner is owed the rest of its sheet rate. Press **Edit pricing** to change the markup, the cut or the basis for every car at once.
2. **Cars** lists each car with its sheet rates a day (1 to 2 days, 3 or more, 7 or more) and the renter''s rates. Press **Edit** on a car to change a negotiated rate, give that car its own markup or cut, mark it **Insurance included** or **No credit card needed**, or confirm its model year. The renter''s rates change at once.
3. The site shows these cars with their tiers (1 to 2 days, 3 to 6 days, 7 days or more) and "Guideline rates; final price confirmed after review". A car with insurance included needs no coverage choice from the renter (coverage option 4, confirmed by itself); a car with no credit card needed takes a debit card for the payment and the deposit. The deposit, the licence and identity checks and the ages stay the same.
4. The price sheet has no years, VINs or plates. Until you confirm the year, the site leaves it out and says "Year confirmed when you book"; an offer waits until the year is confirmed (Edit on the car, Model year). Add the plate and the VIN on the car''s page before its first handover.
5. Real photos: open the car (its name in Cars), **Photos**, and add them. Once approved they replace the eight studio stand-ins.

> Good to know: The partner''s monthly statement shows each rental at the sheet rate, the cut and the payout; never what the renter paid. A refund lowers the partner''s share in proportion; a discount CarmaCars gives comes out of the markup.

## A partner''s CRM (01 Motors'' GoHighLevel)

**Settings**, the **Partners** tile, then the partner (or **CRM link** on the partner''s page). Their CRM gets our cars, kept up to date, and their cars come to us.

1. Ask the partner for a Private Integration token and their location ID (the box **What 01 Motors gives us** on the page says exactly what to create and which scopes to tick). Paste both and press **Connect**. The token goes to the vault; the page only ever shows its last four characters.
2. Connect tests the link (their location, objects, products and pipelines) and runs the first sync. After that it runs by itself every 15 minutes, and within five minutes of a change to a car, a rate, a photo, a booking or a block. **Test connection** and **Run sync now** do it at once.
3. **What 01 Motors sees**: CarmaCars'' own cars and program owners'' cars that are on the site, with rates, the next 60 days and photos, as records of a "CarmaCars Vehicles" object in their CRM (or as products when their plan has no custom objects). Partner cars are never sent: not theirs, not another partner''s. Press **Change what we share** to leave out program owners'' cars, rates, availability or photos.
4. **Partner price**: the site''s rates, or the site''s rates less (or plus) a percentage, to the nearest dollar.
5. **Their cars coming in**: name the object in their CRM that holds their cars (Test connection lists them), or their feed address. Each of their cars is matched to their car here, or added as their partner car (it waits off the site unless you choose otherwise), with their rates as its sheet rates, their booked dates as calendar blocks and their photos for a car with none. A car that waits shows **Add as their car**, **Link** or **Set aside**.
6. **Leads both ways** (off until you turn it on): requests for their cars, and requests that came through their booking links, become contacts and opportunities in the pipeline stage you choose; an opportunity they move to the stage you name becomes a lead in **Leads**.
7. **Feed, widget and booking links**: a JSON or CSV feed and a widget for their GoHighLevel funnels and sites (copy the iframe), and booking links carmacars.ca/p/01-motors/<car> that mark the request as theirs for 30 days. **New key** ends the old feed and widget addresses at once.

> Good to know: A link that has failed for an hour shows on Admin > Today. Disconnect deletes the token from the vault; what is already in their CRM stays there.

## Add a rental by hand

**Bookings** > **Add a rental**. For phone, walk-in, Turo, partner and insurer bookings, the owner using their own car, and placeholders: a rental already agreed. To send an offer instead, use Send an offer.

1. Quick start sets the usual choices in one tap: **Phone**, **Walk-in**, **Turo or another platform**, **Insurance replacement**, **Owner using own car** or **Placeholder**.
2. Choose the car and the dates. The calendar and the price are checked by themselves: clashes with other bookings and the cleaning time after each trip. An Admin may book over a clash with a reason.
3. The dates decide the case, shown under them (nothing to tick): a pickup ahead is an upcoming rental, handed over at pickup as usual. A pickup already passed with the return ahead is a rental already underway: it is recorded as on trip from the pickup you enter, on any active car (even one closed to public bookings), and anything a handover checks that is still missing (signature, licence check, coverage proof, deposit, condition report, insurance) becomes a task. A return already passed is a rental that has ended: kept as completed, paid another way or unpaid.
4. Find the renter by name, email or phone, or add a new one: name, email, phone, date of birth and licence. Add any other drivers.
5. Check the price: the car''s rates, extras, coverage and deposit. An Admin may set the price by hand; assistants use the rate sheet and the discounts allowed.
6. A car whose listing is not finished (a draft listing, onboarding, no photos or no rates yet) can be rented at once: it shows Listing not finished in the car list and stays off the public site. With no rates yet, type the rental charge for the whole rental and the reason.
7. An owner''s car that is not on the fleet insurance policy yet: only an Admin adds its rentals, and ticks I checked that this car is insured for this rental. An owner''s car needs its terms (Revenue Share) first. The handover still needs the car on the fleet policy: press **Insurer confirmed** once the insurer confirms it.
8. The rental is paid by: e-Transfer or cash (received), card on file (charged when the renter signs), payment link, platform payout (Turo), insurer billed later, cheque, bank transfer, or unpaid. The deposit is taken by card hold, cash, e-Transfer or no deposit.
9. The rental agreement: Send it to sign online, or Already signed on paper (a task asks for the scan). The calendar: untick Blocks the car''s calendar for an insurance replacement with dates not known yet, with the reason.
10. Tick **Do not email the renter** if they should not get the confirmation. Press **Add the rental**.

> Tip: The rental is on the calendars at once (a payment link waits for the payment). The renter signs the rental agreement in their portal, or on paper and you record it. With the saved card, nothing is charged when you add the rental: the card is charged when the renter presses Accept and sign, and until then the rental is awaiting signature. On the booking, **Verified in person** records a licence checked at the counter. A rental already underway can be paid by payment link (the renter signs, then pays from their booking) or the saved card, like an upcoming one.

## Retire or delete a car

**Cars** > **Retire or delete**, or the car''s own page.

1. **Retire this car** takes the car off the site and the calendars and keeps every record. It needs no future confirmed booking. **Restore** brings it back.
2. **Delete this car** removes a car added by mistake, with its photos. Only a car with nothing tied to money (no confirmed or paid booking, payment, statement, toll or damage). Type the plate or the name to confirm.
3. Booking requests that never confirmed and never took money (requested, offered, declined, expired) do not stop a delete. The confirmation lists them; they are removed with the car and a copy is kept. The renters stay on file.
4. On the same page, **Delete all sample cars** deletes every sample car that meets the rule at once, with its requests. Type DELETE SAMPLE CARS to confirm; the ones kept show why, with the booking numbers.

## Sample cars on the site

**Cars** > **Vehicles**, or **Settings** > **Site**. The 20 example cars the site started with, so the fleet never looks empty while the real cars are listed.

1. **Hide sample cars** asks first ("Hide all 20 sample cars from the site?"); press **Hide them** to take every sample car off the site at once, or **Keep them**. Nothing else stops it: not an enquiry, not an old request.
2. **Show sample cars** puts the 20 back, with their photos and rates. Ones that were deleted are made again.
3. On the site each one is marked "Example car". They never appear in search engines or the sitemap.
4. A request on a sample car is never a booking. When the person picks dates, the car page and the request form show a real car free for them (the same make and model first, else the same class and body at a similar price) with one tap to switch to it. If they keep the sample car, it becomes an enquiry (number EQ-1001 and up) and customer service gets the task Suggest a similar real car, naming the free real car.

> Tip: Hide the sample cars once enough real cars are on the site. Delete all sample cars removes them for good.

## Why a car is not on the site yet

**Cars** > **Vehicles**, the card Not on the site yet.

1. Every real car that is not on the site is listed with its next step first: the rates, Publish now, the listing review.
2. The same car is a line on To do with **Set rates and publish**. The car comes off both once it is on the site.
3. A car without photos is marked sample photos: once listed it shows a sample photo until its real photos are approved.

## Tolls when two rentals overlap

Bookings held for an insurer and other placeholders are never matched to a toll. When two real rentals overlap the toll time, nobody is charged automatically: the toll waits in the work queue under Two rentals, with both bookings, and you choose who pays.
',
  '<p class="gd-p">A car comes from one of three places: a program owner, CarmaCars itself, or a partner rental company. You add cars and rentals by hand, retire cars, and delete cars that were added by mistake.</p><section class="gd-task" id="partners-company-cars-and-rentals-added-by-hand-add-a-car" data-gd-task><h2 class="gd-h2">Add a car</h2><p class="gd-p"><b class="gd-ui">Cars</b> &gt; <b class="gd-ui">Vehicles</b>, then <b class="gd-ui">Add a car</b>. Start with the VIN: everything else about the car comes from it.</p><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">Type or paste the VIN. At the 17th character the car is looked up: one line shows the year, make, model, trim, body, seats, doors, fuel, drive, gearbox and engine. Press Edit only if something is wrong.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">When the VIN fits several trims, the form asks which trim it is: press the one on the car&#39;s papers or badge, or <b class="gd-ui">Not sure</b> (Admin &gt; Today asks again).</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">No VIN at hand? Press <b class="gd-ui">No VIN at hand? Add the car by its plate</b> and choose the year, make and model from the lists. The VIN can be added later; the details fill in then.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t">Tap the colour (it is not in the VIN). Leave it empty and it is read from the cover photo once the car has one.</div></li><li><span class="gd-n" aria-hidden="true">5</span><div class="gd-t">Check the class. It is set from the make, model, body and age (a 2016 Porsche Macan is Premium, an SUV is SUV) and the line under it says why. Change it if it is wrong.</div></li><li><span class="gd-n" aria-hidden="true">6</span><div class="gd-t">Choose who supplies it: <b class="gd-ui">A program owner&#39;s car</b> (choose the owner; the car starts its onboarding), <b class="gd-ui">CarmaCars-owned (company fleet)</b> (no owner; all of its revenue is CarmaCars&#39;) or <b class="gd-ui">A partner rental company&#39;s car</b> (choose the partner; leave the commission empty to use the partner&#39;s).</div></li><li><span class="gd-n" aria-hidden="true">7</span><div class="gd-t">The daily rate is filled in from similar cars, else the class. Keep it, change it, or empty it and set the rates later on the car&#39;s Rates tab. Press <b class="gd-ui">Add the car</b>.</div></li></ol></div><aside class="gd-box"><span class="gd-lbl">Tip</span><div>The title, description and features are written by themselves right after the car is added, from the VIN details. Change any of them on the car&#39;s listing; a field you change is kept.</div></aside><aside class="gd-box"><span class="gd-lbl">Good to know</span><div>Every car gets a fleet number and its standard settings the moment it is added: a complete rate card (the daily rate you typed or the suggested one, weekend, weekly and monthly from it, the kilometres a day, the extra kilometre rate, the deposit and the delivery and pickup fee of its class) and drivers 18 to 20 allowed. Each value set this way says (Set automatically) on the car&#39;s Overview and Rates tab until you change it. The defaults come from Settings: Program and Fee defaults.</div></aside><aside class="gd-box"><span class="gd-lbl">Tip</span><div>A VIN that does not add up (one character misread) shows a warning; you can still save it. A VIN the decoder cannot read asks only the year, make and model and never stops you: the details fill in when it is read later. The duplicate check runs as for every car: a VIN only once, a plate on one active car, and a likely twin waits for you in Similar cars before it is published.</div></aside><p class="gd-p">The gearbox comes from the government&#39;s fuel economy data for the model when it has one gearbox for it, or from the VIN when the VIN states it. Seats come from the VIN, or the usual number for the body (4 for a coupe or convertible, 5 for a sedan, SUV or hatchback). When either is not certain, Admin &gt; Today shows <b class="gd-ui">Confirm gearbox and seats</b>: press the gearbox and the number of seats, then <b class="gd-ui">Save</b>. A car whose VIN fits several trims shows <b class="gd-ui">Pick the trim</b> there: press the right one. Either way the title, description and search text are written again.</p><p class="gd-p">On a car&#39;s page, <b class="gd-ui">Who supplies the car</b> shows the supplier and the commission, and changes them. Vehicles filters by supply type.</p></section><section class="gd-task" id="partners-company-cars-and-rentals-added-by-hand-partners" data-gd-task><h2 class="gd-h2">Partners</h2><p class="gd-p"><b class="gd-ui">People</b> &gt; <b class="gd-ui">Partners</b>. Partner rental companies whose cars we rent out on commission.</p><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">Press <b class="gd-ui">Add a partner</b>: business and legal name, contacts, HST number, commission and insurance with its expiry date.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Open a partner for its cars, bookings, statements, payouts and documents. A warning shows when its insurance expires soon, and Staff tasks gets a reminder (Program settings sets how many days before).</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Banking (Admins only): <b class="gd-ui">Save the payout account</b> for the account we pay the partner into. The account number is stored encrypted. Press <b class="gd-ui">Verify</b> once checked.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t">Portal: <b class="gd-ui">Invite to the owner portal</b> gives the partner the owner portal with its cars, bookings, statements and the partner agreement, filled in and signed on screen in three taps.</div></li><li><span class="gd-n" aria-hidden="true">5</span><div class="gd-t">Signed on paper? Press <b class="gd-ui">Print the partner agreement</b>, then record the signed scan under Record a paper signature.</div></li></ol></div></section><section class="gd-task" id="partners-company-cars-and-rentals-added-by-hand-a-partner-fleet-on-its-own-rates" data-gd-task><h2 class="gd-h2">A partner fleet on its own rates</h2><p class="gd-p">Some partners send a price sheet of their own rates instead of sharing what the renter pays. 01 Motors works this way: its whole fleet is on the site, and staff manage its cars (it has no portal sign-in yet; add its email on the partner page and invite it later).</p><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t"><b class="gd-ui">People</b> &gt; <b class="gd-ui">Partners</b> &gt; the partner. <b class="gd-ui">Pricing</b> shows how it is paid: the renter pays the partner&#39;s sheet rate plus the markup (10% unless you set another), rounded to the nearest dollar; CarmaCars keeps the markup plus its cut (20% of the sheet rate); the partner is owed the rest of its sheet rate. Press <b class="gd-ui">Edit pricing</b> to change the markup, the cut or the basis for every car at once.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t"><b class="gd-ui">Cars</b> lists each car with its sheet rates a day (1 to 2 days, 3 or more, 7 or more) and the renter&#39;s rates. Press <b class="gd-ui">Edit</b> on a car to change a negotiated rate, give that car its own markup or cut, mark it <b class="gd-ui">Insurance included</b> or <b class="gd-ui">No credit card needed</b>, or confirm its model year. The renter&#39;s rates change at once.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">The site shows these cars with their tiers (1 to 2 days, 3 to 6 days, 7 days or more) and &quot;Guideline rates; final price confirmed after review&quot;. A car with insurance included needs no coverage choice from the renter (coverage option 4, confirmed by itself); a car with no credit card needed takes a debit card for the payment and the deposit. The deposit, the licence and identity checks and the ages stay the same.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t">The price sheet has no years, VINs or plates. Until you confirm the year, the site leaves it out and says &quot;Year confirmed when you book&quot;; an offer waits until the year is confirmed (Edit on the car, Model year). Add the plate and the VIN on the car&#39;s page before its first handover.</div></li><li><span class="gd-n" aria-hidden="true">5</span><div class="gd-t">Real photos: open the car (its name in Cars), <b class="gd-ui">Photos</b>, and add them. Once approved they replace the eight studio stand-ins.</div></li></ol></div><aside class="gd-box"><span class="gd-lbl">Good to know</span><div>The partner&#39;s monthly statement shows each rental at the sheet rate, the cut and the payout; never what the renter paid. A refund lowers the partner&#39;s share in proportion; a discount CarmaCars gives comes out of the markup.</div></aside></section><section class="gd-task" id="partners-company-cars-and-rentals-added-by-hand-a-partner-s-crm-01-motors-gohighlevel" data-gd-task><h2 class="gd-h2">A partner&#39;s CRM (01 Motors&#39; GoHighLevel)</h2><p class="gd-p"><b class="gd-ui">Settings</b>, the <b class="gd-ui">Partners</b> tile, then the partner (or <b class="gd-ui">CRM link</b> on the partner&#39;s page). Their CRM gets our cars, kept up to date, and their cars come to us.</p><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">Ask the partner for a Private Integration token and their location ID (the box <b class="gd-ui">What 01 Motors gives us</b> on the page says exactly what to create and which scopes to tick). Paste both and press <b class="gd-ui">Connect</b>. The token goes to the vault; the page only ever shows its last four characters.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Connect tests the link (their location, objects, products and pipelines) and runs the first sync. After that it runs by itself every 15 minutes, and within five minutes of a change to a car, a rate, a photo, a booking or a block. <b class="gd-ui">Test connection</b> and <b class="gd-ui">Run sync now</b> do it at once.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t"><b class="gd-ui">What 01 Motors sees</b>: CarmaCars&#39; own cars and program owners&#39; cars that are on the site, with rates, the next 60 days and photos, as records of a &quot;CarmaCars Vehicles&quot; object in their CRM (or as products when their plan has no custom objects). Partner cars are never sent: not theirs, not another partner&#39;s. Press <b class="gd-ui">Change what we share</b> to leave out program owners&#39; cars, rates, availability or photos.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t"><b class="gd-ui">Partner price</b>: the site&#39;s rates, or the site&#39;s rates less (or plus) a percentage, to the nearest dollar.</div></li><li><span class="gd-n" aria-hidden="true">5</span><div class="gd-t"><b class="gd-ui">Their cars coming in</b>: name the object in their CRM that holds their cars (Test connection lists them), or their feed address. Each of their cars is matched to their car here, or added as their partner car (it waits off the site unless you choose otherwise), with their rates as its sheet rates, their booked dates as calendar blocks and their photos for a car with none. A car that waits shows <b class="gd-ui">Add as their car</b>, <b class="gd-ui">Link</b> or <b class="gd-ui">Set aside</b>.</div></li><li><span class="gd-n" aria-hidden="true">6</span><div class="gd-t"><b class="gd-ui">Leads both ways</b> (off until you turn it on): requests for their cars, and requests that came through their booking links, become contacts and opportunities in the pipeline stage you choose; an opportunity they move to the stage you name becomes a lead in <b class="gd-ui">Leads</b>.</div></li><li><span class="gd-n" aria-hidden="true">7</span><div class="gd-t"><b class="gd-ui">Feed, widget and booking links</b>: a JSON or CSV feed and a widget for their GoHighLevel funnels and sites (copy the iframe), and booking links carmacars.ca/p/01-motors/&lt;car&gt; that mark the request as theirs for 30 days. <b class="gd-ui">New key</b> ends the old feed and widget addresses at once.</div></li></ol></div><aside class="gd-box"><span class="gd-lbl">Good to know</span><div>A link that has failed for an hour shows on Admin &gt; Today. Disconnect deletes the token from the vault; what is already in their CRM stays there.</div></aside></section><section class="gd-task" id="partners-company-cars-and-rentals-added-by-hand-add-a-rental-by-hand" data-gd-task><h2 class="gd-h2">Add a rental by hand</h2><p class="gd-p"><b class="gd-ui">Bookings</b> &gt; <b class="gd-ui">Add a rental</b>. For phone, walk-in, Turo, partner and insurer bookings, the owner using their own car, and placeholders: a rental already agreed. To send an offer instead, use Send an offer.</p><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">Quick start sets the usual choices in one tap: <b class="gd-ui">Phone</b>, <b class="gd-ui">Walk-in</b>, <b class="gd-ui">Turo or another platform</b>, <b class="gd-ui">Insurance replacement</b>, <b class="gd-ui">Owner using own car</b> or <b class="gd-ui">Placeholder</b>.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Choose the car and the dates. The calendar and the price are checked by themselves: clashes with other bookings and the cleaning time after each trip. An Admin may book over a clash with a reason.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">The dates decide the case, shown under them (nothing to tick): a pickup ahead is an upcoming rental, handed over at pickup as usual. A pickup already passed with the return ahead is a rental already underway: it is recorded as on trip from the pickup you enter, on any active car (even one closed to public bookings), and anything a handover checks that is still missing (signature, licence check, coverage proof, deposit, condition report, insurance) becomes a task. A return already passed is a rental that has ended: kept as completed, paid another way or unpaid.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t">Find the renter by name, email or phone, or add a new one: name, email, phone, date of birth and licence. Add any other drivers.</div></li><li><span class="gd-n" aria-hidden="true">5</span><div class="gd-t">Check the price: the car&#39;s rates, extras, coverage and deposit. An Admin may set the price by hand; assistants use the rate sheet and the discounts allowed.</div></li><li><span class="gd-n" aria-hidden="true">6</span><div class="gd-t">A car whose listing is not finished (a draft listing, onboarding, no photos or no rates yet) can be rented at once: it shows Listing not finished in the car list and stays off the public site. With no rates yet, type the rental charge for the whole rental and the reason.</div></li><li><span class="gd-n" aria-hidden="true">7</span><div class="gd-t">An owner&#39;s car that is not on the fleet insurance policy yet: only an Admin adds its rentals, and ticks I checked that this car is insured for this rental. An owner&#39;s car needs its terms (Revenue Share) first. The handover still needs the car on the fleet policy: press <b class="gd-ui">Insurer confirmed</b> once the insurer confirms it.</div></li><li><span class="gd-n" aria-hidden="true">8</span><div class="gd-t">The rental is paid by: e-Transfer or cash (received), card on file (charged when the renter signs), payment link, platform payout (Turo), insurer billed later, cheque, bank transfer, or unpaid. The deposit is taken by card hold, cash, e-Transfer or no deposit.</div></li><li><span class="gd-n" aria-hidden="true">9</span><div class="gd-t">The rental agreement: Send it to sign online, or Already signed on paper (a task asks for the scan). The calendar: untick Blocks the car&#39;s calendar for an insurance replacement with dates not known yet, with the reason.</div></li><li><span class="gd-n" aria-hidden="true">10</span><div class="gd-t">Tick <b class="gd-ui">Do not email the renter</b> if they should not get the confirmation. Press <b class="gd-ui">Add the rental</b>.</div></li></ol></div><aside class="gd-box"><span class="gd-lbl">Tip</span><div>The rental is on the calendars at once (a payment link waits for the payment). The renter signs the rental agreement in their portal, or on paper and you record it. With the saved card, nothing is charged when you add the rental: the card is charged when the renter presses Accept and sign, and until then the rental is awaiting signature. On the booking, <b class="gd-ui">Verified in person</b> records a licence checked at the counter. A rental already underway can be paid by payment link (the renter signs, then pays from their booking) or the saved card, like an upcoming one.</div></aside></section><section class="gd-task" id="partners-company-cars-and-rentals-added-by-hand-retire-or-delete-a-car" data-gd-task><h2 class="gd-h2">Retire or delete a car</h2><p class="gd-p"><b class="gd-ui">Cars</b> &gt; <b class="gd-ui">Retire or delete</b>, or the car&#39;s own page.</p><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t"><b class="gd-ui">Retire this car</b> takes the car off the site and the calendars and keeps every record. It needs no future confirmed booking. <b class="gd-ui">Restore</b> brings it back.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t"><b class="gd-ui">Delete this car</b> removes a car added by mistake, with its photos. Only a car with nothing tied to money (no confirmed or paid booking, payment, statement, toll or damage). Type the plate or the name to confirm.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Booking requests that never confirmed and never took money (requested, offered, declined, expired) do not stop a delete. The confirmation lists them; they are removed with the car and a copy is kept. The renters stay on file.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t">On the same page, <b class="gd-ui">Delete all sample cars</b> deletes every sample car that meets the rule at once, with its requests. Type DELETE SAMPLE CARS to confirm; the ones kept show why, with the booking numbers.</div></li></ol></div></section><section class="gd-task" id="partners-company-cars-and-rentals-added-by-hand-sample-cars-on-the-site" data-gd-task><h2 class="gd-h2">Sample cars on the site</h2><p class="gd-p"><b class="gd-ui">Cars</b> &gt; <b class="gd-ui">Vehicles</b>, or <b class="gd-ui">Settings</b> &gt; <b class="gd-ui">Site</b>. The 20 example cars the site started with, so the fleet never looks empty while the real cars are listed.</p><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t"><b class="gd-ui">Hide sample cars</b> asks first (&quot;Hide all 20 sample cars from the site?&quot;); press <b class="gd-ui">Hide them</b> to take every sample car off the site at once, or <b class="gd-ui">Keep them</b>. Nothing else stops it: not an enquiry, not an old request.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t"><b class="gd-ui">Show sample cars</b> puts the 20 back, with their photos and rates. Ones that were deleted are made again.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">On the site each one is marked &quot;Example car&quot;. They never appear in search engines or the sitemap.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t">A request on a sample car is never a booking. When the person picks dates, the car page and the request form show a real car free for them (the same make and model first, else the same class and body at a similar price) with one tap to switch to it. If they keep the sample car, it becomes an enquiry (number EQ-1001 and up) and customer service gets the task Suggest a similar real car, naming the free real car.</div></li></ol></div><aside class="gd-box"><span class="gd-lbl">Tip</span><div>Hide the sample cars once enough real cars are on the site. Delete all sample cars removes them for good.</div></aside></section><section class="gd-task" id="partners-company-cars-and-rentals-added-by-hand-why-a-car-is-not-on-the-site-yet" data-gd-task><h2 class="gd-h2">Why a car is not on the site yet</h2><p class="gd-p"><b class="gd-ui">Cars</b> &gt; <b class="gd-ui">Vehicles</b>, the card Not on the site yet.</p><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">Every real car that is not on the site is listed with its next step first: the rates, Publish now, the listing review.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">The same car is a line on To do with <b class="gd-ui">Set rates and publish</b>. The car comes off both once it is on the site.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">A car without photos is marked sample photos: once listed it shows a sample photo until its real photos are approved.</div></li></ol></div></section><section class="gd-task" id="partners-company-cars-and-rentals-added-by-hand-tolls-when-two-rentals-overlap" data-gd-task><h2 class="gd-h2">Tolls when two rentals overlap</h2><p class="gd-p">Bookings held for an insurer and other placeholders are never matched to a toll. When two real rentals overlap the toll time, nobody is charged automatically: the toll waits in the work queue under Two rentals, with both bookings, and you choose who pays.</p></section>');
select app.guide_release_section('admin', 'settings', 'chapter', 'search-car-pages-landing-pages-and-guides', 'Settings change the public site and the rules of the program at once. Program settings are kept as dated rows, so earlier values stay on record.

## The Settings page

1. Site setup lists what is still missing on the public site, with **Open site settings**.
2. Site settings: contact details, hours, tagline, logo, socials, Google place id and featured cars.
3. Program settings: every timing and policy value.
4. Forms: Blind Spot''s rental agreement for every booking, and the official ServiceOntario PDFs and what goes in each field.
5. Insurers: insurance companies billed for bookings.

![](/guides/img/admin-24-settings-desktop-89b31691.jpg "desktop; size: 1440 900; address: carmacars.ca/admin/settings; pins: 1 32.6 33.0, 2 25.8 40.2, 3 77.4 40.2, 4 25.8 73.2, 5 25.8 84.9")

The other tiles: Site content (headings, FAQs, legal text), Fee defaults, Deposit tiers, Kilometre choices, Vehicle classes, Airports and delivery, Protection Plan prices, Card coverage, Email aliases and reply-to, Staff and roles, Promo codes and Quick replies.

## Program settings

1. Turnaround between trips: the time held between two trips. The cleaning block after a trip is this time.
2. Settings come in groups such as Company, Booking requests and offers, Owner debits and statement emails, Deposits, Delivery, Owners and fleet, and Tolls and damage. Open one to see its fields.
3. First reply target for customer service and sales (minutes), under Booking requests and offers: 5 by default. New booking requests, enquiries, changes renters ask for and renter messages are due that many minutes after they come in; the scorecard and the staff screens use it. What renters are told (Reply wording, in Site settings) is separate.
4. Staff commissions and prices typed by hand: the commission outside Sales (10%), the three Sales tiers and their days (10%, 15% from 50 days, 20% from 100 days, the month''s target), the price floor a day (empty: none) and the discount from the rate sheet that flags a price (20%). The owner confirmed these values in October 2026.
5. Staff agreement defaults by function, at the bottom: pay (a month, an hour or commission only), the rate, the schedule (full time, part time or flexible), days a week and hours a day for Customer service, Fleet, Finance and Sales, the values every assistant shares, and the field staff wage. Sales is commission only: no rate and a flexible schedule. Press **Save the defaults**.
6. Live visitors and live chat: recording visits, the signal thresholds, follow-up tasks, the chat and its assistant, and how long visits and chats are kept.
7. Discount games: the same values as Settings, Discount games (the prize table and the games are easier to change there).
8. Sign-in by phone: codes by text from the CarmaCars number (on), US numbers (off until the Quo number is registered for US texting, A2P 10DLC), codes per number and per connection an hour, and whether a verified phone confirms an account like a confirmed email. Accepting an offer, signing and paying need a confirmed account; an account made by phone gives its email on the pay page before its first payment.
9. Calendar sync, Turo by email, Booking recovery emails and Site check: how often calendar links are read, the Turo inbound address and who may forward to it, the reminder delays and sending hours, and the site check with the address its alerts go to (rent@carmacars.ca), the minutes before an email, the daily limit and the quiet hours.
10. Change a value and press **Save**. It is saved as a new row from today; the rows before stay as they were.

![](/guides/img/admin-25-program-settings-desktop-d16b066c.jpg "desktop; size: 1440 1000; address: carmacars.ca/admin/settings/program; pins: 1 25.8 22.0, 2 27.8 49.0")

## Official ServiceOntario forms

The five official forms are loaded with a mapping to the owner, car, company and lender details. Each is the form exactly as ServiceOntario publishes it: only its empty text boxes are filled. Its checkboxes, drop-downs and signatures are done by hand at the counter, in ink. Until you check a form, owners get a data sheet with the values.

1. Open **Settings** > **Forms**. Each form shows "Mapping to check" (a draft is ready) or "Official PDF in use". Its notes say what the form is for and which boxes are left blank on purpose.
2. Press **Download a filled preview** for one car and check each value against the form.
3. Change a field if needed: What goes in it (or "Signed here by hand, in ink"), a Format (for example YYYY/MM/DD) and Only when. Press Save the mapping.
4. Press **Checked: use for owners**. Every owner''s form of that kind is filled again, except ones already signed or filed. Owners download it, print it and sign it in ink; record it with **Record paper signature**. Each form not checked yet is also a line on To do with the same button and Preview it.
5. A new version from ServiceOntario? Press **Upload the official fillable PDF**: the fields of the same name keep their mapping.

> Good to know: SR-LV-006 (registration), SR-LV-012 (two registrants), ON00453 (a company''s RIN), 013-1155 and 013-0169 (the tax-exempt transfer into an owner''s corporation). 013-1155 is sworn before a commissioner, so it is printed and signed in person. ON00453 is an Adobe form: it opens in Adobe Acrobat Reader. Each form''s notes list what to tick or choose at the counter.

## Blind Spot rental agreement

We rent under Blind Spot Car Rental''s insurance, so every booking has two agreements: CarmaCars'' rental agreement and Blind Spot''s own. Blind Spot''s is filled in from the booking, the renter and the car, and the renter signs both with one signature. Its PDF is stored privately, never on the website.

1. Open **Settings** > **Forms**. The Blind Spot Car Rental agreement card is first. Press **Upload Blind Spot''s PDF** and choose Blind Spot''s blank form (2 pages, A4).
2. Press **Download the filled sample**: a made-up booking on the form. **Sample billed to an insurer** also fills the claim number, the adjuster and the insurance company. Check every box.
3. On the form the old address (top left and twice in box 15) is replaced by the mailing address of Site settings, box 1 by CarmaCars'' HST number (Program settings, Company HST number; blank until it is entered), and box 21 has the representative''s signature instead of Sam''s.
4. Press **Checked: use for bookings**. From then on each booking gets it when its rental agreement is made; a renter whose agreement is already open gets it the next time they open the signing page.
5. Box 21: Ahmad is written in a script hand, as Blind Spot asked. To use a real signature instead, upload a PNG under Authorized company representative; Remove the image goes back to the written name. Full name is for the signature record page.
6. A new version of Blind Spot''s form? Upload it the same way: it waits for **Checked: use for bookings**, and bookings keep the version in use until then.

> Good to know: Each box is filled only when the booking has the value: the renter and their licence, the additional drivers, the car (plate, make and model, the fleet number as vehicle number), the pickup as time and date out, the due-back date and time, the kilometres allowed, the daily rate and the rental charge, the underage fee, the Protection Plan as CDW, winter tires, the subtotal, HST, total and deposit, and for a booking billed to an insurer the insurer, claim number and adjuster. Other charges, such as delivery, are listed in box 14. Initials, fuel and the boxes filled at return stay blank.

The renter''s signature goes in boxes 16, 17 and 20 of the signed copy, with a signature record page. Both agreements are in the booking''s Drivers and documents tab, in the renter''s Documents, and the signed Blind Spot agreement is attached to the "Your signed rental agreement" email. Admin > Today lists the HST number, the upload and the check until they are done.

## Agreements to sign: investors and staff

Investment agreements and staff agreements are made from the person''s record and signed in their own portal, or on paper.

1. Investor: open **People** > **Investors** and the investor. Under Investment agreement, press **Send the agreement to sign**. Check the values it is filled with (amount, yearly percentage, dates, exemption) and press **Send to sign**.
2. Once the investor signs, the agreement shows **Awaiting countersignature** on the investor''s page and on To do. It is not countersigned automatically: check it and press **Countersign**. CarmaCars is bound once it has countersigned and the funds clear.
3. Staff: open **People** > **Staff**. Under Staff agreements, press **Send the agreement to sign** beside the person. Pay, schedule, hours and the other values start from the staff profile and the defaults of their function in Program settings; change any before sending. For Sales the Pay is Commission only: the agreement then has no rate, schedule or hours, and pays the commission of section 3.4.
4. A field staff member''s agreement prints the home address they entered themselves. Staff enter their home address at their first sign-in, before they sign, or in their profile.
5. They get a notice, check the key values and sign in their portal in a few taps (their name is the signature, or they draw it). The signed copy is filed with their documents.
6. Your own PDF instead? **Send a PDF to sign** still works.
7. Signed on paper instead? Press **Record paper signature** in the same place and upload the scan.
8. Sent by mistake? Press **Withdraw** and give the reason.

## The user guides

**Settings** > **Guides**. The guide of each portal, as people read it under Guide.

1. Each guide shows its version, when it was published and whether there are unpublished changes.
2. Open a guide and press a section. Change its text and press **Show the preview** to see it as people will. Press **Save the draft**; each save is kept in the section''s history.
3. Move a section with the arrows, hide it, or press **Add a chapter**. Upload a screenshot under Screenshots and paste the line it gives you.
4. Press **Publish version** (the next number). The portals show the new version at once.
5. The stored PDF is printed again by the guides-pdf workflow. Until then the guide says the web guide has newer edits.

## The guides keep up by themselves

After every update of the site that changes the portals, the guides are checked without anyone asking.

1. Every screenshot is taken again on the new version of the site. One whose screen changed replaces the old one in the guide.
2. The text of each section whose screen changed, or that names a button the portals no longer show, is rewritten from the portal''s own labels and menu, checked, and published. The PDFs of those guides are printed again.
3. Such a section says **Changed automatically on** and the date, in the list of guides and in the guide''s editor. Not right? Open the section and press **Revert**: the text it replaced comes back, published at once.
4. This includes sections you edited: the newest automatic text is published, and every earlier version stays in the section''s history. There is nothing to review.
5. A rewrite that does not pass the checks is asked again, more strictly. If it still does not pass, the screenshots and button names are updated, the rest of the text stays as it was, and the next run tries again.

> Tip: The card "The guides keep up by themselves" at the top of Guides lists the last runs: when, how many screenshots were replaced, how many sections were rewritten, and how many PDFs were printed.

## Insurers and the other lists

1. Open Insurers. Each insurer on file opens to edit its billing contact, email, phone, address and notes.
2. To add one, fill in the Add form (Name, Billing contact, Billing email and the rest) and press **Add**.
3. Deposit tiers, Kilometre choices, Vehicle classes, Airports, Promo codes and Quick replies work the same way.

## Card coverage: which credit cards include rental car coverage

**Settings** > **Card coverage** is the list renters see at `carmacars.ca/credit-card-rental-coverage` and staff see under Card coverage in their portal. It starts filled in with 48 Canadian and US cards, each checked on October 23, 2026.

1. The table shows each card: who pays first (Primary, Secondary, or not stated), the car value limit (MSRP), the longest rental, whether the numbers were read in the issuer''s own document, and when it was last checked.
2. Open a card under Change a card, open its official guide, correct what changed and press **Save**. Changing the facts without a date marks the card checked today; type a Last checked date to record another day.
3. A card whose numbers come from a published summary has Read in the issuer''s own document unticked and the summary''s link under Where the numbers came from. The page shows it as Unverified. Tick it once you have read the issuer''s guide.
4. Add a card with the Add form; untick Shown to hide one. Changes reach the public page at once.

> Tip: A card not checked for 6 months shows on Today until it is checked again. The page tells renters to confirm with their card issuer and says CarmaCars decides no claims: keep the list to facts from the issuer''s guide.
', 'Settings', 'Site, program settings, official forms mapping, insurers and the other lists.',
  'Settings change the public site and the rules of the program at once. Program settings are kept as dated rows, so earlier values stay on record.

## The Settings page

1. Site setup lists what is still missing on the public site, with **Open site settings**.
2. Site settings: contact details, hours, tagline, logo, socials, Google place id and featured cars.
3. Program settings: every timing and policy value.
4. Forms: Blind Spot''s rental agreement for every booking, and the official ServiceOntario PDFs and what goes in each field.
5. Insurers: insurance companies billed for bookings.

![](/guides/img/admin-24-settings-desktop-89b31691.jpg "desktop; size: 1440 900; address: carmacars.ca/admin/settings; pins: 1 32.6 33.0, 2 25.8 40.2, 3 77.4 40.2, 4 25.8 73.2, 5 25.8 84.9")

The other tiles: Site content (headings, FAQs, legal text), Fee defaults, Deposit tiers, Kilometre choices, Vehicle classes, Airports and delivery, Protection Plan prices, Card coverage, Partners (each partner company''s CRM link: see Partners, company cars and rentals added by hand), Email aliases and reply-to, Staff and roles, Promo codes and Quick replies.

## Program settings

1. Turnaround between trips: the time held between two trips. The cleaning block after a trip is this time.
2. Settings come in groups such as Company, Booking requests and offers, Owner debits and statement emails, Deposits, Delivery, Owners and fleet, and Tolls and damage. Open one to see its fields.
3. First reply target for customer service and sales (minutes), under Booking requests and offers: 5 by default. New booking requests, enquiries, changes renters ask for and renter messages are due that many minutes after they come in; the scorecard and the staff screens use it. What renters are told (Reply wording, in Site settings) is separate.
4. Staff commissions and prices typed by hand: the commission outside Sales (10%), the three Sales tiers and their days (10%, 15% from 50 days, 20% from 100 days, the month''s target), the price floor a day (empty: none) and the discount from the rate sheet that flags a price (20%). The owner confirmed these values in October 2026.
5. Staff agreement defaults by function, at the bottom: pay (a month, an hour or commission only), the rate, the schedule (full time, part time or flexible), days a week and hours a day for Customer service, Fleet, Finance and Sales, the values every assistant shares, and the field staff wage. Sales is commission only: no rate and a flexible schedule. Press **Save the defaults**.
6. Live visitors and live chat: recording visits, the signal thresholds, follow-up tasks, the chat and its assistant, and how long visits and chats are kept.
7. Discount games: the same values as Settings, Discount games (the prize table and the games are easier to change there).
8. Sign-in by phone: codes by text from the CarmaCars number (on), US numbers (off until the Quo number is registered for US texting, A2P 10DLC), codes per number and per connection an hour, and whether a verified phone confirms an account like a confirmed email. Accepting an offer, signing and paying need a confirmed account; an account made by phone gives its email on the pay page before its first payment.
9. Calendar sync, Turo by email, Booking recovery emails and Site check: how often calendar links are read, the Turo inbound address and who may forward to it, the reminder delays and sending hours, and the site check with the address its alerts go to (rent@carmacars.ca), the minutes before an email, the daily limit and the quiet hours.
10. Change a value and press **Save**. It is saved as a new row from today; the rows before stay as they were.

![](/guides/img/admin-25-program-settings-desktop-d16b066c.jpg "desktop; size: 1440 1000; address: carmacars.ca/admin/settings/program; pins: 1 25.8 22.0, 2 27.8 49.0")

## Official ServiceOntario forms

The five official forms are loaded with a mapping to the owner, car, company and lender details. Each is the form exactly as ServiceOntario publishes it: only its empty text boxes are filled. Its checkboxes, drop-downs and signatures are done by hand at the counter, in ink. Until you check a form, owners get a data sheet with the values.

1. Open **Settings** > **Forms**. Each form shows "Mapping to check" (a draft is ready) or "Official PDF in use". Its notes say what the form is for and which boxes are left blank on purpose.
2. Press **Download a filled preview** for one car and check each value against the form.
3. Change a field if needed: What goes in it (or "Signed here by hand, in ink"), a Format (for example YYYY/MM/DD) and Only when. Press Save the mapping.
4. Press **Checked: use for owners**. Every owner''s form of that kind is filled again, except ones already signed or filed. Owners download it, print it and sign it in ink; record it with **Record paper signature**. Each form not checked yet is also a line on To do with the same button and Preview it.
5. A new version from ServiceOntario? Press **Upload the official fillable PDF**: the fields of the same name keep their mapping.

> Good to know: SR-LV-006 (registration), SR-LV-012 (two registrants), ON00453 (a company''s RIN), 013-1155 and 013-0169 (the tax-exempt transfer into an owner''s corporation). 013-1155 is sworn before a commissioner, so it is printed and signed in person. ON00453 is an Adobe form: it opens in Adobe Acrobat Reader. Each form''s notes list what to tick or choose at the counter.

## Blind Spot rental agreement

We rent under Blind Spot Car Rental''s insurance, so every booking has two agreements: CarmaCars'' rental agreement and Blind Spot''s own. Blind Spot''s is filled in from the booking, the renter and the car, and the renter signs both with one signature. Its PDF is stored privately, never on the website.

1. Open **Settings** > **Forms**. The Blind Spot Car Rental agreement card is first. Press **Upload Blind Spot''s PDF** and choose Blind Spot''s blank form (2 pages, A4).
2. Press **Download the filled sample**: a made-up booking on the form. **Sample billed to an insurer** also fills the claim number, the adjuster and the insurance company. Check every box.
3. On the form the old address (top left and twice in box 15) is replaced by the mailing address of Site settings, box 1 by CarmaCars'' HST number (Program settings, Company HST number; blank until it is entered), and box 21 has the representative''s signature instead of Sam''s.
4. Press **Checked: use for bookings**. From then on each booking gets it when its rental agreement is made; a renter whose agreement is already open gets it the next time they open the signing page.
5. Box 21: Ahmad is written in a script hand, as Blind Spot asked. To use a real signature instead, upload a PNG under Authorized company representative; Remove the image goes back to the written name. Full name is for the signature record page.
6. A new version of Blind Spot''s form? Upload it the same way: it waits for **Checked: use for bookings**, and bookings keep the version in use until then.

> Good to know: Each box is filled only when the booking has the value: the renter and their licence, the additional drivers, the car (plate, make and model, the fleet number as vehicle number), the pickup as time and date out, the due-back date and time, the kilometres allowed, the daily rate and the rental charge, the underage fee, the Protection Plan as CDW, winter tires, the subtotal, HST, total and deposit, and for a booking billed to an insurer the insurer, claim number and adjuster. Other charges, such as delivery, are listed in box 14. Initials, fuel and the boxes filled at return stay blank.

The renter''s signature goes in boxes 16, 17 and 20 of the signed copy, with a signature record page. Both agreements are in the booking''s Drivers and documents tab, in the renter''s Documents, and the signed Blind Spot agreement is attached to the "Your signed rental agreement" email. Admin > Today lists the HST number, the upload and the check until they are done.

## Agreements to sign: investors and staff

Investment agreements and staff agreements are made from the person''s record and signed in their own portal, or on paper.

1. Investor: open **People** > **Investors** and the investor. Under Investment agreement, press **Send the agreement to sign**. Check the values it is filled with (amount, yearly percentage, dates, exemption) and press **Send to sign**.
2. Once the investor signs, the agreement shows **Awaiting countersignature** on the investor''s page and on To do. It is not countersigned automatically: check it and press **Countersign**. CarmaCars is bound once it has countersigned and the funds clear.
3. Staff: open **People** > **Staff**. Under Staff agreements, press **Send the agreement to sign** beside the person. Pay, schedule, hours and the other values start from the staff profile and the defaults of their function in Program settings; change any before sending. For Sales the Pay is Commission only: the agreement then has no rate, schedule or hours, and pays the commission of section 3.4.
4. A field staff member''s agreement prints the home address they entered themselves. Staff enter their home address at their first sign-in, before they sign, or in their profile.
5. They get a notice, check the key values and sign in their portal in a few taps (their name is the signature, or they draw it). The signed copy is filed with their documents.
6. Your own PDF instead? **Send a PDF to sign** still works.
7. Signed on paper instead? Press **Record paper signature** in the same place and upload the scan.
8. Sent by mistake? Press **Withdraw** and give the reason.

## The user guides

**Settings** > **Guides**. The guide of each portal, as people read it under Guide.

1. Each guide shows its version, when it was published and whether there are unpublished changes.
2. Open a guide and press a section. Change its text and press **Show the preview** to see it as people will. Press **Save the draft**; each save is kept in the section''s history.
3. Move a section with the arrows, hide it, or press **Add a chapter**. Upload a screenshot under Screenshots and paste the line it gives you.
4. Press **Publish version** (the next number). The portals show the new version at once.
5. The stored PDF is printed again by the guides-pdf workflow. Until then the guide says the web guide has newer edits.

## The guides keep up by themselves

After every update of the site that changes the portals, the guides are checked without anyone asking.

1. Every screenshot is taken again on the new version of the site. One whose screen changed replaces the old one in the guide.
2. The text of each section whose screen changed, or that names a button the portals no longer show, is rewritten from the portal''s own labels and menu, checked, and published. The PDFs of those guides are printed again.
3. Such a section says **Changed automatically on** and the date, in the list of guides and in the guide''s editor. Not right? Open the section and press **Revert**: the text it replaced comes back, published at once.
4. This includes sections you edited: the newest automatic text is published, and every earlier version stays in the section''s history. There is nothing to review.
5. A rewrite that does not pass the checks is asked again, more strictly. If it still does not pass, the screenshots and button names are updated, the rest of the text stays as it was, and the next run tries again.

> Tip: The card "The guides keep up by themselves" at the top of Guides lists the last runs: when, how many screenshots were replaced, how many sections were rewritten, and how many PDFs were printed.

## Insurers and the other lists

1. Open Insurers. Each insurer on file opens to edit its billing contact, email, phone, address and notes.
2. To add one, fill in the Add form (Name, Billing contact, Billing email and the rest) and press **Add**.
3. Deposit tiers, Kilometre choices, Vehicle classes, Airports, Promo codes and Quick replies work the same way.

## Card coverage: which credit cards include rental car coverage

**Settings** > **Card coverage** is the list renters see at `carmacars.ca/credit-card-rental-coverage` and staff see under Card coverage in their portal. It starts filled in with 48 Canadian and US cards, each checked on October 23, 2026.

1. The table shows each card: who pays first (Primary, Secondary, or not stated), the car value limit (MSRP), the longest rental, whether the numbers were read in the issuer''s own document, and when it was last checked.
2. Open a card under Change a card, open its official guide, correct what changed and press **Save**. Changing the facts without a date marks the card checked today; type a Last checked date to record another day.
3. A card whose numbers come from a published summary has Read in the issuer''s own document unticked and the summary''s link under Where the numbers came from. The page shows it as Unverified. Tick it once you have read the issuer''s guide.
4. Add a card with the Add form; untick Shown to hide one. Changes reach the public page at once.

> Tip: A card not checked for 6 months shows on Today until it is checked again. The page tells renters to confirm with their card issuer and says CarmaCars decides no claims: keep the list to facts from the issuer''s guide.
',
  '<p class="gd-p">Settings change the public site and the rules of the program at once. Program settings are kept as dated rows, so earlier values stay on record.</p><section class="gd-task" id="settings-the-settings-page" data-gd-task><h2 class="gd-h2">The Settings page</h2><div class="gd-stepblock gd-stepblock--below"><div class="gd-stepcol"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">Site setup lists what is still missing on the public site, with <b class="gd-ui">Open site settings</b>.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Site settings: contact details, hours, tagline, logo, socials, Google place id and featured cars.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Program settings: every timing and policy value.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t">Forms: Blind Spot&#39;s rental agreement for every booking, and the official ServiceOntario PDFs and what goes in each field.</div></li><li><span class="gd-n" aria-hidden="true">5</span><div class="gd-t">Insurers: insurance companies billed for bookings.</div></li></ol></div><figure class="gd-fig gd-fig--desk"><div class="gd-browser"><div class="gd-bar" aria-hidden="true"><i></i><i></i><i></i><span class="gd-addr">carmacars.ca/admin/settings</span></div><div class="gd-imgwrap" style="aspect-ratio:1440/900"><img src="/guides/img/admin-24-settings-desktop-89b31691.jpg" alt="" loading="lazy" decoding="async" width="1440" height="900"><span class="gd-pin" style="left:32.6%;top:33%" aria-hidden="true">1</span><span class="gd-pin" style="left:25.8%;top:40.2%" aria-hidden="true">2</span><span class="gd-pin" style="left:77.4%;top:40.2%" aria-hidden="true">3</span><span class="gd-pin" style="left:25.8%;top:73.2%" aria-hidden="true">4</span><span class="gd-pin" style="left:25.8%;top:84.9%" aria-hidden="true">5</span></div></div></figure></div><p class="gd-p">The other tiles: Site content (headings, FAQs, legal text), Fee defaults, Deposit tiers, Kilometre choices, Vehicle classes, Airports and delivery, Protection Plan prices, Card coverage, Partners (each partner company&#39;s CRM link: see Partners, company cars and rentals added by hand), Email aliases and reply-to, Staff and roles, Promo codes and Quick replies.</p></section><section class="gd-task" id="settings-program-settings" data-gd-task><h2 class="gd-h2">Program settings</h2><div class="gd-stepblock gd-stepblock--below"><div class="gd-stepcol"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">Turnaround between trips: the time held between two trips. The cleaning block after a trip is this time.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Settings come in groups such as Company, Booking requests and offers, Owner debits and statement emails, Deposits, Delivery, Owners and fleet, and Tolls and damage. Open one to see its fields.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">First reply target for customer service and sales (minutes), under Booking requests and offers: 5 by default. New booking requests, enquiries, changes renters ask for and renter messages are due that many minutes after they come in; the scorecard and the staff screens use it. What renters are told (Reply wording, in Site settings) is separate.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t">Staff commissions and prices typed by hand: the commission outside Sales (10%), the three Sales tiers and their days (10%, 15% from 50 days, 20% from 100 days, the month&#39;s target), the price floor a day (empty: none) and the discount from the rate sheet that flags a price (20%). The owner confirmed these values in October 2026.</div></li><li><span class="gd-n" aria-hidden="true">5</span><div class="gd-t">Staff agreement defaults by function, at the bottom: pay (a month, an hour or commission only), the rate, the schedule (full time, part time or flexible), days a week and hours a day for Customer service, Fleet, Finance and Sales, the values every assistant shares, and the field staff wage. Sales is commission only: no rate and a flexible schedule. Press <b class="gd-ui">Save the defaults</b>.</div></li><li><span class="gd-n" aria-hidden="true">6</span><div class="gd-t">Live visitors and live chat: recording visits, the signal thresholds, follow-up tasks, the chat and its assistant, and how long visits and chats are kept.</div></li><li><span class="gd-n" aria-hidden="true">7</span><div class="gd-t">Discount games: the same values as Settings, Discount games (the prize table and the games are easier to change there).</div></li><li><span class="gd-n" aria-hidden="true">8</span><div class="gd-t">Sign-in by phone: codes by text from the CarmaCars number (on), US numbers (off until the Quo number is registered for US texting, A2P 10DLC), codes per number and per connection an hour, and whether a verified phone confirms an account like a confirmed email. Accepting an offer, signing and paying need a confirmed account; an account made by phone gives its email on the pay page before its first payment.</div></li><li><span class="gd-n" aria-hidden="true">9</span><div class="gd-t">Calendar sync, Turo by email, Booking recovery emails and Site check: how often calendar links are read, the Turo inbound address and who may forward to it, the reminder delays and sending hours, and the site check with the address its alerts go to (rent@carmacars.ca), the minutes before an email, the daily limit and the quiet hours.</div></li><li><span class="gd-n" aria-hidden="true">10</span><div class="gd-t">Change a value and press <b class="gd-ui">Save</b>. It is saved as a new row from today; the rows before stay as they were.</div></li></ol></div><figure class="gd-fig gd-fig--desk"><div class="gd-browser"><div class="gd-bar" aria-hidden="true"><i></i><i></i><i></i><span class="gd-addr">carmacars.ca/admin/settings/program</span></div><div class="gd-imgwrap" style="aspect-ratio:1440/1000"><img src="/guides/img/admin-25-program-settings-desktop-d16b066c.jpg" alt="" loading="lazy" decoding="async" width="1440" height="1000"><span class="gd-pin" style="left:25.8%;top:22%" aria-hidden="true">1</span><span class="gd-pin" style="left:27.8%;top:49%" aria-hidden="true">2</span></div></div></figure></div></section><section class="gd-task" id="settings-official-serviceontario-forms" data-gd-task><h2 class="gd-h2">Official ServiceOntario forms</h2><p class="gd-p">The five official forms are loaded with a mapping to the owner, car, company and lender details. Each is the form exactly as ServiceOntario publishes it: only its empty text boxes are filled. Its checkboxes, drop-downs and signatures are done by hand at the counter, in ink. Until you check a form, owners get a data sheet with the values.</p><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">Open <b class="gd-ui">Settings</b> &gt; <b class="gd-ui">Forms</b>. Each form shows &quot;Mapping to check&quot; (a draft is ready) or &quot;Official PDF in use&quot;. Its notes say what the form is for and which boxes are left blank on purpose.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Press <b class="gd-ui">Download a filled preview</b> for one car and check each value against the form.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Change a field if needed: What goes in it (or &quot;Signed here by hand, in ink&quot;), a Format (for example YYYY/MM/DD) and Only when. Press Save the mapping.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t">Press <b class="gd-ui">Checked: use for owners</b>. Every owner&#39;s form of that kind is filled again, except ones already signed or filed. Owners download it, print it and sign it in ink; record it with <b class="gd-ui">Record paper signature</b>. Each form not checked yet is also a line on To do with the same button and Preview it.</div></li><li><span class="gd-n" aria-hidden="true">5</span><div class="gd-t">A new version from ServiceOntario? Press <b class="gd-ui">Upload the official fillable PDF</b>: the fields of the same name keep their mapping.</div></li></ol></div><aside class="gd-box"><span class="gd-lbl">Good to know</span><div>SR-LV-006 (registration), SR-LV-012 (two registrants), ON00453 (a company&#39;s RIN), 013-1155 and 013-0169 (the tax-exempt transfer into an owner&#39;s corporation). 013-1155 is sworn before a commissioner, so it is printed and signed in person. ON00453 is an Adobe form: it opens in Adobe Acrobat Reader. Each form&#39;s notes list what to tick or choose at the counter.</div></aside></section><section class="gd-task" id="settings-blind-spot-rental-agreement" data-gd-task><h2 class="gd-h2">Blind Spot rental agreement</h2><p class="gd-p">We rent under Blind Spot Car Rental&#39;s insurance, so every booking has two agreements: CarmaCars&#39; rental agreement and Blind Spot&#39;s own. Blind Spot&#39;s is filled in from the booking, the renter and the car, and the renter signs both with one signature. Its PDF is stored privately, never on the website.</p><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">Open <b class="gd-ui">Settings</b> &gt; <b class="gd-ui">Forms</b>. The Blind Spot Car Rental agreement card is first. Press <b class="gd-ui">Upload Blind Spot&#39;s PDF</b> and choose Blind Spot&#39;s blank form (2 pages, A4).</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Press <b class="gd-ui">Download the filled sample</b>: a made-up booking on the form. <b class="gd-ui">Sample billed to an insurer</b> also fills the claim number, the adjuster and the insurance company. Check every box.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">On the form the old address (top left and twice in box 15) is replaced by the mailing address of Site settings, box 1 by CarmaCars&#39; HST number (Program settings, Company HST number; blank until it is entered), and box 21 has the representative&#39;s signature instead of Sam&#39;s.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t">Press <b class="gd-ui">Checked: use for bookings</b>. From then on each booking gets it when its rental agreement is made; a renter whose agreement is already open gets it the next time they open the signing page.</div></li><li><span class="gd-n" aria-hidden="true">5</span><div class="gd-t">Box 21: Ahmad is written in a script hand, as Blind Spot asked. To use a real signature instead, upload a PNG under Authorized company representative; Remove the image goes back to the written name. Full name is for the signature record page.</div></li><li><span class="gd-n" aria-hidden="true">6</span><div class="gd-t">A new version of Blind Spot&#39;s form? Upload it the same way: it waits for <b class="gd-ui">Checked: use for bookings</b>, and bookings keep the version in use until then.</div></li></ol></div><aside class="gd-box"><span class="gd-lbl">Good to know</span><div>Each box is filled only when the booking has the value: the renter and their licence, the additional drivers, the car (plate, make and model, the fleet number as vehicle number), the pickup as time and date out, the due-back date and time, the kilometres allowed, the daily rate and the rental charge, the underage fee, the Protection Plan as CDW, winter tires, the subtotal, HST, total and deposit, and for a booking billed to an insurer the insurer, claim number and adjuster. Other charges, such as delivery, are listed in box 14. Initials, fuel and the boxes filled at return stay blank.</div></aside><p class="gd-p">The renter&#39;s signature goes in boxes 16, 17 and 20 of the signed copy, with a signature record page. Both agreements are in the booking&#39;s Drivers and documents tab, in the renter&#39;s Documents, and the signed Blind Spot agreement is attached to the &quot;Your signed rental agreement&quot; email. Admin &gt; Today lists the HST number, the upload and the check until they are done.</p></section><section class="gd-task" id="settings-agreements-to-sign-investors-and-staff" data-gd-task><h2 class="gd-h2">Agreements to sign: investors and staff</h2><p class="gd-p">Investment agreements and staff agreements are made from the person&#39;s record and signed in their own portal, or on paper.</p><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">Investor: open <b class="gd-ui">People</b> &gt; <b class="gd-ui">Investors</b> and the investor. Under Investment agreement, press <b class="gd-ui">Send the agreement to sign</b>. Check the values it is filled with (amount, yearly percentage, dates, exemption) and press <b class="gd-ui">Send to sign</b>.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Once the investor signs, the agreement shows <b class="gd-ui">Awaiting countersignature</b> on the investor&#39;s page and on To do. It is not countersigned automatically: check it and press <b class="gd-ui">Countersign</b>. CarmaCars is bound once it has countersigned and the funds clear.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Staff: open <b class="gd-ui">People</b> &gt; <b class="gd-ui">Staff</b>. Under Staff agreements, press <b class="gd-ui">Send the agreement to sign</b> beside the person. Pay, schedule, hours and the other values start from the staff profile and the defaults of their function in Program settings; change any before sending. For Sales the Pay is Commission only: the agreement then has no rate, schedule or hours, and pays the commission of section 3.4.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t">A field staff member&#39;s agreement prints the home address they entered themselves. Staff enter their home address at their first sign-in, before they sign, or in their profile.</div></li><li><span class="gd-n" aria-hidden="true">5</span><div class="gd-t">They get a notice, check the key values and sign in their portal in a few taps (their name is the signature, or they draw it). The signed copy is filed with their documents.</div></li><li><span class="gd-n" aria-hidden="true">6</span><div class="gd-t">Your own PDF instead? <b class="gd-ui">Send a PDF to sign</b> still works.</div></li><li><span class="gd-n" aria-hidden="true">7</span><div class="gd-t">Signed on paper instead? Press <b class="gd-ui">Record paper signature</b> in the same place and upload the scan.</div></li><li><span class="gd-n" aria-hidden="true">8</span><div class="gd-t">Sent by mistake? Press <b class="gd-ui">Withdraw</b> and give the reason.</div></li></ol></div></section><section class="gd-task" id="settings-the-user-guides" data-gd-task><h2 class="gd-h2">The user guides</h2><p class="gd-p"><b class="gd-ui">Settings</b> &gt; <b class="gd-ui">Guides</b>. The guide of each portal, as people read it under Guide.</p><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">Each guide shows its version, when it was published and whether there are unpublished changes.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Open a guide and press a section. Change its text and press <b class="gd-ui">Show the preview</b> to see it as people will. Press <b class="gd-ui">Save the draft</b>; each save is kept in the section&#39;s history.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Move a section with the arrows, hide it, or press <b class="gd-ui">Add a chapter</b>. Upload a screenshot under Screenshots and paste the line it gives you.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t">Press <b class="gd-ui">Publish version</b> (the next number). The portals show the new version at once.</div></li><li><span class="gd-n" aria-hidden="true">5</span><div class="gd-t">The stored PDF is printed again by the guides-pdf workflow. Until then the guide says the web guide has newer edits.</div></li></ol></div></section><section class="gd-task" id="settings-the-guides-keep-up-by-themselves" data-gd-task><h2 class="gd-h2">The guides keep up by themselves</h2><p class="gd-p">After every update of the site that changes the portals, the guides are checked without anyone asking.</p><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">Every screenshot is taken again on the new version of the site. One whose screen changed replaces the old one in the guide.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">The text of each section whose screen changed, or that names a button the portals no longer show, is rewritten from the portal&#39;s own labels and menu, checked, and published. The PDFs of those guides are printed again.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Such a section says <b class="gd-ui">Changed automatically on</b> and the date, in the list of guides and in the guide&#39;s editor. Not right? Open the section and press <b class="gd-ui">Revert</b>: the text it replaced comes back, published at once.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t">This includes sections you edited: the newest automatic text is published, and every earlier version stays in the section&#39;s history. There is nothing to review.</div></li><li><span class="gd-n" aria-hidden="true">5</span><div class="gd-t">A rewrite that does not pass the checks is asked again, more strictly. If it still does not pass, the screenshots and button names are updated, the rest of the text stays as it was, and the next run tries again.</div></li></ol></div><aside class="gd-box"><span class="gd-lbl">Tip</span><div>The card &quot;The guides keep up by themselves&quot; at the top of Guides lists the last runs: when, how many screenshots were replaced, how many sections were rewritten, and how many PDFs were printed.</div></aside></section><section class="gd-task" id="settings-insurers-and-the-other-lists" data-gd-task><h2 class="gd-h2">Insurers and the other lists</h2><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">Open Insurers. Each insurer on file opens to edit its billing contact, email, phone, address and notes.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">To add one, fill in the Add form (Name, Billing contact, Billing email and the rest) and press <b class="gd-ui">Add</b>.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Deposit tiers, Kilometre choices, Vehicle classes, Airports, Promo codes and Quick replies work the same way.</div></li></ol></div></section><section class="gd-task" id="settings-card-coverage-which-credit-cards-include-rental-car-coverage" data-gd-task><h2 class="gd-h2">Card coverage: which credit cards include rental car coverage</h2><p class="gd-p"><b class="gd-ui">Settings</b> &gt; <b class="gd-ui">Card coverage</b> is the list renters see at <span class="gd-url">carmacars.ca/credit-card-rental-coverage</span> and staff see under Card coverage in their portal. It starts filled in with 48 Canadian and US cards, each checked on October 23, 2026.</p><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">The table shows each card: who pays first (Primary, Secondary, or not stated), the car value limit (MSRP), the longest rental, whether the numbers were read in the issuer&#39;s own document, and when it was last checked.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Open a card under Change a card, open its official guide, correct what changed and press <b class="gd-ui">Save</b>. Changing the facts without a date marks the card checked today; type a Last checked date to record another day.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">A card whose numbers come from a published summary has Read in the issuer&#39;s own document unticked and the summary&#39;s link under Where the numbers came from. The page shows it as Unverified. Tick it once you have read the issuer&#39;s guide.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t">Add a card with the Add form; untick Shown to hide one. Changes reach the public page at once.</div></li></ol></div><aside class="gd-box"><span class="gd-lbl">Tip</span><div>A card not checked for 6 months shows on Today until it is checked again. The page tells renters to confirm with their card issuer and says CarmaCars decides no claims: keep the list to facts from the issuer&#39;s guide.</div></aside></section>');
-- GUIDES 0136 END
