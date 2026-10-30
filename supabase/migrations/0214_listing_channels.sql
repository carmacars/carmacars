-- 0214: Listing channels, CarmaCars' cars on other car rental sites (Release 22, item 3). SCHEMA_MARKER 0214.
-- docs/changes/2026-11-02-listing-channels.md.
--   1. listing_channels: a checklist of the sites and directories where CarmaCars can list its cars, each with its address,
--      status (not started, applied, live, paused, not for us), who holds the login, notes, and its own inventory feed
--      (on by default). Seeded with the sites that matter for Toronto and Canada. Nothing here is an integration: each
--      channel is applied for and managed on its own site; where a site or partner program ingests a feed, the channel's
--      feed address is what they are given.
--   2. The feed: CarmaCars' own cars and program owners' cars (co-hosted) on the site, never a partner's car (01 Motors' or
--      any other), never a sample, retired or opted-out car (vehicles.channel_feed_opt_out). JSON, CSV and a Google
--      vehicle-listings style XML, from public.server_channel_feed(token), at most channel_feed_hourly_max (60) fetches an
--      hour per channel; the Worker caches each answer 15 minutes.
--   3. Admin > Marketing > Listing channels through the door (admin_read 'listing_channels'; admin_do
--      'listing_channel_save', 'listing_channel_feed_rotate', 'vehicle_channel_opt_out').
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

alter table program_settings add column if not exists channel_feed_hourly_max integer not null default 60 check (channel_feed_hourly_max between 1 and 10000);
comment on column program_settings.channel_feed_hourly_max is 'Listing channels (0214): fetches of one channel''s feed allowed an hour; more get "429 Too many requests".';

alter table vehicles add column if not exists channel_feed_opt_out boolean not null default false;
comment on column vehicles.channel_feed_opt_out is 'Listing channels (0214): keep this car out of every channel feed (Admin > Marketing > Listing channels).';

create table if not exists listing_channels (
  id              uuid primary key default gen_random_uuid(),
  slug            text not null unique check (slug ~ '^[a-z0-9_]{2,40}$'),
  name            text not null check (length(btrim(name)) between 2 and 80),
  url             text check (url is null or url ~ '^https://[^[:space:]]+$'),
  kind            text not null check (kind in ('peer_to_peer', 'aggregator', 'classifieds', 'social', 'search', 'directory')),
  status          text not null default 'not_started' check (status in ('not_started', 'applied', 'live', 'paused', 'not_for_us')),
  login_owner     text check (login_owner is null or length(login_owner) <= 120),
  notes           text check (notes is null or length(notes) <= 2000),
  how_to_list     text,
  feed_enabled    boolean not null default true,
  feed_token      uuid not null default gen_random_uuid() unique,
  sort            integer not null default 100,
  updated_by      uuid references users (id) on delete set null,
  created_at      timestamptz not null default now(),
  updated_at      timestamptz not null default now()
);
comment on table listing_channels is 'Listing channels (0214): where CarmaCars lists its cars beyond carmacars.ca, with status, login owner and notes, and each channel''s own feed address. No integration is implied: the feed is what a site or partner program ingests, when it does.';

-- the feed's reads (a counter written on every read: kept apart so the audited channel row changes only when staff change it)
create table if not exists listing_channel_feed_stats (
  channel_id  uuid primary key references listing_channels (id) on delete cascade,
  window_at   timestamptz,
  window_n    integer not null default 0,
  last_at     timestamptz,
  fetches     bigint not null default 0
);
comment on table listing_channel_feed_stats is 'Listing channels (0214): reads of each channel''s feed (the hourly allowance and the last read).';

insert into listing_channels (slug, name, url, kind, how_to_list, sort) values
  ('turo', 'Turo', 'https://turo.com/ca/en/list-your-car', 'peer_to_peer', 'Each car is listed by hand in the Turo host app (no feed import). Trips come back through Calendar sync.', 1),
  ('getaround', 'Getaround', 'https://www.getaround.com/', 'peer_to_peer', 'Check whether Getaround operates in Toronto at the time; when it does, cars are listed by hand in its host app (no feed import).', 2),
  ('google_business', 'Google Business Profile', 'https://business.google.com/', 'search', 'The CarmaCars profile (car rental agency): photos, hours, products. Products can be added by hand from the feed.', 3),
  ('google_vehicle_ads', 'Google Merchant Center (vehicle listings)', 'https://merchants.google.com/', 'search', 'Check that the vehicle-listings program accepts rental cars in Canada before applying. Merchant Center takes a scheduled XML or CSV feed: give it this channel''s XML address.', 4),
  ('meta_catalog', 'Facebook and Instagram (Meta catalog)', 'https://business.facebook.com/commerce', 'social', 'Commerce Manager > Catalog > Data sources > Data feed: a scheduled feed from this channel''s CSV or XML address. Marketplace posts from a personal profile stay manual (Marketing > Listings).', 5),
  ('kijiji', 'Kijiji (Autos and Cars for rent)', 'https://www.kijiji.ca/', 'classifieds', 'Ads are posted by hand (Marketing > Listings writes the text). Kijiji''s dealer feed is for car sales, not rentals: ask before relying on it.', 6),
  ('fb_marketplace', 'Facebook Marketplace', 'https://www.facebook.com/marketplace/', 'classifieds', 'Posted by hand from a personal profile (Marketing > Listings). No feed.', 7),
  ('kayak', 'KAYAK (car rental partners)', 'https://www.kayak.com/', 'aggregator', 'Car rental results come from supplier and broker partners. Ask KAYAK''s partner team whether an independent Toronto company can join; if so, they ask for a feed: give this channel''s address.', 8),
  ('expedia', 'Expedia Group (car suppliers)', 'https://www.expediagroup.com/', 'aggregator', 'Car rental supply comes through car partners and brokers. Ask about an independent supplier connection; give this channel''s feed if they take one.', 9),
  ('discovercars', 'Discover Cars (supplier program)', 'https://www.discovercars.com/', 'aggregator', 'A broker that works with local rental companies: apply as a supplier. They may ask for rates and availability as a feed.', 10),
  ('rentalcars', 'Rentalcars.com (Booking.com cars)', 'https://www.rentalcars.com/', 'aggregator', 'Apply as a supplier through their supplier team; their requirements decide whether a feed is used.', 11),
  ('autotrader', 'AutoTrader.ca', 'https://www.autotrader.ca/', 'classifieds', 'A car sales site: rentals are not a listing category. Kept here so it is not re-checked.', 12),
  ('craigslist', 'Craigslist Toronto', 'https://toronto.craigslist.org/', 'classifieds', 'Posted by hand (Marketing > Listings).', 13),
  ('bing_places', 'Bing Places for Business', 'https://www.bingplaces.com/', 'directory', 'Import the Google Business Profile.', 14),
  ('apple_business', 'Apple Business Connect', 'https://businessconnect.apple.com/', 'directory', 'Claim the place card for Apple Maps.', 15),
  ('yelp', 'Yelp', 'https://biz.yelp.ca/', 'directory', 'Claim the business page.', 16),
  ('yellowpages', 'YellowPages.ca', 'https://www.yellowpages.ca/', 'directory', 'Free listing for the business.', 17)
on conflict (slug) do nothing;
update listing_channels set status = 'not_for_us', feed_enabled = false where slug = 'autotrader' and status = 'not_started';

-- the cars every channel may show: CarmaCars' own and program owners' (co-hosted), never a partner's
create or replace function app.channel_feed_cars() returns jsonb
language sql stable security definer set search_path = public, app as $$
  select coalesce(jsonb_agg(x.car order by x.make, x.model, x.year desc nulls last, x.code), '[]'::jsonb) from (
    select v.make, v.model, v.year, v.car_code code, jsonb_build_object(
      'vehicle_id', v.id, 'car_code', v.car_code, 'supply_type', v.supply_type, 'name', app.vehicle_name(v.id),
      'year', case when v.year_approximate then null else v.year end, 'make', v.make, 'model', v.model, 'trim', v.trim, 'colour', v.colour, 'class', v.class,
      'seats', r ->> 'seats', 'doors', r ->> 'doors', 'body_style', r ->> 'body_style', 'transmission', r ->> 'transmission', 'drivetrain', r ->> 'drivetrain', 'fuel', r ->> 'fuel',
      'slug', r ->> 'slug', 'location', coalesce(nullif(r ->> 'home_area', '') || ', ' || coalesce(s.city, 'Toronto'), coalesce(s.city, 'Toronto')),
      'car_url', rtrim(coalesce(nullif(s.site_url, ''), 'https://carmacars.ca'), '/') || coalesce(r ->> 'path', '/cars/' || (r ->> 'slug')),
      'photos', coalesce((select jsonb_agg(ph ->> 'path' order by n) from jsonb_array_elements(app.public_listing_photos(v.id)) with ordinality p(ph, n)
                           where coalesce((ph ->> 'sample')::boolean, false) = false and coalesce(ph ->> 'path', '') <> ''), '[]'::jsonb),
      'daily_cents', (r ->> 'daily_rate_cents')::bigint, 'weekly_cents', (r ->> 'weekly_rate_cents')::bigint, 'monthly_cents', (r ->> 'monthly_rate_cents')::bigint,
      'deposit_cents', (r ->> 'deposit_cents')::bigint, 'km_per_day', r ->> 'km_allowance_per_day',
      'availability', app.partner_crm_availability(v.id, 30)) car
      from vehicles v
      cross join lateral (select app.public_listing_row(v.id) r) pr
      left join site_settings s on true
     where v.supply_type in ('company', 'program_owner')        -- the rule: never a partner car
       and v.partner_id is null and v.retired_at is null and not coalesce(v.is_sample, false) and not v.channel_feed_opt_out
       and pr.r is not null) x
$$;

-- a channel's feed by its token: null when unknown or off; {limited: true} past the hourly allowance
create or replace function public.server_channel_feed(p_token uuid) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  c listing_channels;
  st listing_channel_feed_stats;
  v_max integer := (app.settings()).channel_feed_hourly_max;
begin
  select * into c from listing_channels where feed_token = p_token;
  if c.id is null or not c.feed_enabled then return null; end if;
  insert into listing_channel_feed_stats (channel_id) values (c.id) on conflict (channel_id) do nothing;
  select * into st from listing_channel_feed_stats where channel_id = c.id for update;
  if st.window_at is null or st.window_at < now() - interval '1 hour' then
    update listing_channel_feed_stats set window_at = now(), window_n = 1, last_at = now(), fetches = fetches + 1 where channel_id = c.id;
  elsif st.window_n >= v_max then
    return jsonb_build_object('limited', true, 'retry_after', greatest(1, extract(epoch from (st.window_at + interval '1 hour' - now()))::int));
  else
    update listing_channel_feed_stats set window_n = window_n + 1, last_at = now(), fetches = fetches + 1 where channel_id = c.id;
  end if;
  return jsonb_build_object('limited', false, 'channel', c.slug, 'channel_name', c.name, 'cars', app.channel_feed_cars(),
    'site', (select jsonb_build_object('url', rtrim(coalesce(nullif(s.site_url, ''), 'https://carmacars.ca'), '/'), 'name', coalesce(s.brand_name, 'CarmaCars'), 'city', coalesce(s.city, 'Toronto'))
               from site_settings s limit 1));
end $$;
revoke all on function public.server_channel_feed(uuid) from public, anon, authenticated;
grant execute on function public.server_channel_feed(uuid) to service_role;

-- ================================================================ Admin
create or replace function app.listing_channels_read(p_by uuid, p jsonb) returns jsonb
language plpgsql stable security definer set search_path = public, app as $$
begin
  perform app.assert_admin(p_by);
  return jsonb_build_object(
    'hourly_max', (app.settings()).channel_feed_hourly_max,
    'channels', (select coalesce(jsonb_agg(jsonb_build_object('id', c.id, 'slug', c.slug, 'name', c.name, 'url', c.url, 'kind', c.kind, 'status', c.status, 'login_owner', c.login_owner,
                   'notes', c.notes, 'how_to_list', c.how_to_list, 'feed_enabled', c.feed_enabled, 'feed_token', c.feed_token, 'feed_last_at', (select last_at from listing_channel_feed_stats where channel_id = c.id),
                   'feed_fetches', coalesce((select fetches from listing_channel_feed_stats where channel_id = c.id), 0))
                   order by c.sort, c.name), '[]'::jsonb) from listing_channels c),
    'cars', (select coalesce(jsonb_agg(jsonb_build_object('id', v.id, 'name', app.vehicle_name(v.id), 'car_code', v.car_code, 'supply_type', v.supply_type,
                   'listed', app.public_listing_row(v.id) is not null, 'opt_out', v.channel_feed_opt_out) order by v.make, v.model, v.car_code), '[]'::jsonb)
               from vehicles v where v.supply_type in ('company', 'program_owner') and v.partner_id is null and v.retired_at is null and not coalesce(v.is_sample, false)),
    'partner_cars', (select count(*) from vehicles v where (v.supply_type = 'partner' or v.partner_id is not null) and v.retired_at is null));
end $$;

create or replace function app.listing_channels_do(p_by uuid, p_name text, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  c listing_channels;
  v_url text := nullif(btrim(coalesce(p ->> 'url', '')), '');
  v_name text := nullif(btrim(coalesce(p ->> 'name', '')), '');
begin
  perform app.assert_admin(p_by);
  if p_name = 'listing_channel_save' then
    if v_url is not null and v_url !~ '^https://[^[:space:]]+$' then raise exception 'The address starts with https://' using errcode = '22023'; end if;
    if nullif(p ->> 'status', '') is not null and p ->> 'status' not in ('not_started', 'applied', 'live', 'paused', 'not_for_us') then raise exception 'Choose a status' using errcode = '22023'; end if;
    if nullif(p ->> 'id', '') is null then
      if v_name is null or length(v_name) < 2 then raise exception 'Name the site' using errcode = '22023'; end if;
      insert into listing_channels (slug, name, url, kind, status, login_owner, notes, updated_by)
      values (left(trim(both '_' from regexp_replace(lower(v_name), '[^a-z0-9]+', '_', 'g')), 30) || '_' || substr(md5(gen_random_uuid()::text), 1, 4), v_name, v_url,
              coalesce(nullif(p ->> 'kind', ''), 'directory'), coalesce(nullif(p ->> 'status', ''), 'not_started'),
              nullif(btrim(coalesce(p ->> 'login_owner', '')), ''), nullif(btrim(coalesce(p ->> 'notes', '')), ''), p_by)
      returning * into c;
    else
      update listing_channels set name = coalesce(v_name, name), url = case when p ? 'url' then v_url else url end,
             status = coalesce(nullif(p ->> 'status', ''), status),
             login_owner = case when p ? 'login_owner' then nullif(btrim(coalesce(p ->> 'login_owner', '')), '') else login_owner end,
             notes = case when p ? 'notes' then nullif(btrim(coalesce(p ->> 'notes', '')), '') else notes end,
             feed_enabled = coalesce((p ->> 'feed_enabled')::boolean, feed_enabled), updated_by = p_by, updated_at = now()
       where id = (p ->> 'id')::uuid returning * into c;
      if c.id is null then raise exception 'Channel not found' using errcode = 'P0002'; end if;
    end if;
    insert into audit_log (actor_user_id, action, entity_table, entity_id, after) values (p_by, p_name, 'listing_channels', c.id::text, p);
    return jsonb_build_object('id', c.id, 'status', c.status, 'feed_enabled', c.feed_enabled);
  elsif p_name = 'listing_channel_feed_rotate' then
    update listing_channels set feed_token = gen_random_uuid(), updated_by = p_by, updated_at = now() where id = (p ->> 'id')::uuid returning * into c;
    if c.id is null then raise exception 'Channel not found' using errcode = 'P0002'; end if;
    insert into audit_log (actor_user_id, action, entity_table, entity_id) values (p_by, p_name, 'listing_channels', c.id::text);
    return jsonb_build_object('id', c.id, 'feed_token', c.feed_token);
  elsif p_name = 'vehicle_channel_opt_out' then
    update vehicles set channel_feed_opt_out = coalesce((p ->> 'opt_out')::boolean, not channel_feed_opt_out) where id = (p ->> 'vehicle')::uuid;
    if not found then raise exception 'Car not found' using errcode = 'P0002'; end if;
    insert into audit_log (actor_user_id, action, entity_table, entity_id, after) values (p_by, p_name, 'vehicles', p ->> 'vehicle', p);
    return jsonb_build_object('vehicle', p ->> 'vehicle', 'opt_out', (select channel_feed_opt_out from vehicles where id = (p ->> 'vehicle')::uuid));
  end if;
  raise exception 'Unknown listing channel call %', p_name using errcode = '22023';
end $$;

alter function app.door(uuid, text, text, text, jsonb) rename to door_pre0214;
create function app.door(p_user uuid, p_aal text, p_call text, p_name text, p jsonb default '{}'::jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
begin
  if p_call = 'admin_read' and p_name = 'listing_channels' then
    perform app.door_begin(p_user, p_aal);
    return app.listing_channels_read(p_user, coalesce(p, '{}'::jsonb) - '_va');
  end if;
  if p_call = 'admin_do' and p_name in ('listing_channel_save', 'listing_channel_feed_rotate', 'vehicle_channel_opt_out') then
    perform app.door_begin(p_user, p_aal);
    return app.listing_channels_do(p_user, p_name, coalesce(p, '{}'::jsonb) - '_va');
  end if;
  return app.door_pre0214(p_user, p_aal, p_call, p_name, p);
end $$;
select pg_temp.copy_grants('app.door(uuid, text, text, text, jsonb)'::regprocedure, 'app.door_pre0214(uuid, text, text, text, jsonb)'::regprocedure);

do $$
declare t text;
begin
  foreach t in array array['listing_channels', 'listing_channel_feed_stats'] loop
    execute format('alter table %I enable row level security', t);
    execute format('revoke all on %I from anon, authenticated', t);
    execute format('grant all on %I to service_role', t);
    execute format('drop policy if exists admin_all on %I', t);
    execute format('create policy admin_all on %I for all to authenticated using (app.is_admin()) with check (app.is_admin())', t);
  end loop;
end $$;
-- row audit for the channel (the read counter is not audited: it changes on every read)
drop trigger if exists audit_listing_channels on listing_channels;
create trigger audit_listing_channels after insert or update or delete on listing_channels for each row execute function app.audit_row();
do $$
declare f record;
begin
  for f in select p.oid::regprocedure as sig from pg_proc p join pg_namespace n on n.oid = p.pronamespace
            where n.nspname = 'app' and p.proname in ('channel_feed_cars', 'listing_channels_read', 'listing_channels_do', 'door_pre0214') loop
    execute format('revoke all on function %s from public, anon, authenticated', f.sig);
    execute format('grant execute on function %s to service_role', f.sig);
  end loop;
end $$;
