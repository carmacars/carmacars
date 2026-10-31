-- 99: Listing channels and their feeds (migration 0216). Fixtures start with "lch".
select test.suite('99 listing channels');
select test.mk_user('lch_admin', 'admin');
select test.mk_user('lch_cs', 'va', 'cs');
select test.mk_owner('lch_own');
insert into partners (id, owner_id, business_name, status) values (test.id('partner:lch'), test.id('owner:lch_own'), 'Lch Partner Rentals', 'active');
insert into vehicles (id, owner_id, year, make, model, trim, colour, plate, vin, class, status, management_mode, onboarding_method, body_type, supply_type, partner_id, is_sample)
values (test.id('vehicle:LCH1'), test.id('owner:lch_own'), 2024, 'BMW', 'X5', 'xDrive40i', 'Black', 'LCH1AA', 'LCHVIN00000000001', 'suv', 'available', 'managed', 'transfer', 'SUV', 'company', null, false),
       (test.id('vehicle:LCH2'), test.id('owner:lch_own'), 2023, 'Audi', 'Q7', null, 'White', 'LCH2AA', 'LCHVIN00000000002', 'suv', 'available', 'managed', 'transfer', 'SUV', 'program_owner', null, false),
       (test.id('vehicle:LCH3'), test.id('owner:lch_own'), 2025, 'Ferrari', 'Roma', null, 'Red', 'LCH3AA', 'LCHVIN00000000003', 'exotic', 'available', 'managed', 'transfer', 'Coupe', 'partner', test.id('partner:lch'), false);
insert into rate_cards (vehicle_id, daily_rate_cents, weekend_rate_cents, weekly_rate_cents, monthly_rate_cents, km_allowance_per_day, overage_cents_per_km, deposit_cents, delivery_fee_cents, pickup_fee_cents, effective_from)
select x.id, x.p, x.p, x.p * 6, x.p * 20, 200, 35, 50000, 5000, 5000, now() - interval '1 day'
  from (values (test.id('vehicle:LCH1'), 18900), (test.id('vehicle:LCH2'), 16500), (test.id('vehicle:LCH3'), 150000)) x(id, p);
insert into vehicle_listings (vehicle_id, slug, headline, status, published_at, seats, transmission, body_style)
select v.id, 'lch-' || lower(v.plate), 'x', 'published', now(), 5, 'Automatic', v.body_type from vehicles v where v.plate like 'LCH%'
on conflict (vehicle_id) do update set status = excluded.status, published_at = now(), slug = excluded.slug;

create temp table lch_feed as select public.server_channel_feed((select feed_token from listing_channels where slug = 'meta_catalog')) f;
select test.ok('the channels are seeded, with a feed each', (select count(*) from listing_channels) >= 15 and exists (select 1 from listing_channels where slug = 'turo' and status = 'not_started'));
select test.ok('our car and the co-hosted car are in the feed', (select count(*) from lch_feed, jsonb_array_elements(f -> 'cars') c where c ->> 'vehicle_id' in (test.id('vehicle:LCH1')::text, test.id('vehicle:LCH2')::text)) = 2);
select test.eq('never a partner car (01 Motors or any other)', (select count(*)::int from lch_feed, jsonb_array_elements(f -> 'cars') c join vehicles v on v.id = (c ->> 'vehicle_id')::uuid
  where v.supply_type = 'partner' or v.partner_id is not null), 0);
select test.eq('with the site''s daily rate', (select (c ->> 'daily_cents')::int from lch_feed, jsonb_array_elements(f -> 'cars') c where c ->> 'vehicle_id' = test.id('vehicle:LCH1')::text), 18900);

-- a car opted out, a channel off, a rotated key
select public.door(test.id('lch_admin'), 'aal2', 'admin_do', 'vehicle_channel_opt_out', jsonb_build_object('vehicle', test.id('vehicle:LCH2'), 'opt_out', true));
select test.ok('an opted-out car leaves every feed', not exists (select 1 from jsonb_array_elements(public.server_channel_feed((select feed_token from listing_channels where slug = 'kayak')) -> 'cars') c
  where c ->> 'vehicle_id' = test.id('vehicle:LCH2')::text));
select public.door(test.id('lch_admin'), 'aal2', 'admin_do', 'listing_channel_save', jsonb_build_object('id', (select id from listing_channels where slug = 'kayak'), 'feed_enabled', false, 'status', 'applied', 'login_owner', 'Abbas', 'notes', 'Emailed the partner team'));
select test.ok('a channel turned off has no feed', public.server_channel_feed((select feed_token from listing_channels where slug = 'kayak')) is null
  and exists (select 1 from listing_channels where slug = 'kayak' and status = 'applied' and login_owner = 'Abbas'));
create temp table lch_old as select feed_token t from listing_channels where slug = 'meta_catalog';
select public.door(test.id('lch_admin'), 'aal2', 'admin_do', 'listing_channel_feed_rotate', jsonb_build_object('id', (select id from listing_channels where slug = 'meta_catalog')));
select test.ok('a new key ends the old address', public.server_channel_feed((select t from lch_old)) is null);
select public.door(test.id('lch_admin'), 'aal2', 'admin_do', 'listing_channel_save', '{"name": "Local Directory", "url": "https://example.test/list", "kind": "directory"}');
select test.ok('a channel of our own', exists (select 1 from listing_channels where name = 'Local Directory' and status = 'not_started'));
select test.throws('an address that is not https', format($s$select public.door(%L, 'aal2', 'admin_do', 'listing_channel_save', '{"name": "Bad", "url": "ftp://x"}')$s$, test.id('lch_admin')), 'https');
select test.throws('Admins only', format($s$select public.door(%L, 'aal2', 'admin_read', 'listing_channels', '{}')$s$, test.id('lch_cs')));

-- the hourly allowance
update program_settings set channel_feed_hourly_max = 2 where true;
delete from listing_channel_feed_stats where channel_id = (select id from listing_channels where slug = 'turo');
select public.server_channel_feed((select feed_token from listing_channels where slug = 'turo'));
select public.server_channel_feed((select feed_token from listing_channels where slug = 'turo'));
select test.ok('past the hourly allowance: limited', (public.server_channel_feed((select feed_token from listing_channels where slug = 'turo')) ->> 'limited')::boolean);
update program_settings set channel_feed_hourly_max = 60 where true;
select test.throws('the feed function is not for the public', $$set local role anon; select public.server_channel_feed(gen_random_uuid())$$);
