-- 99: release 37 (migration 2304): the Channel API for rental distribution partners. Scopes (bookings off by default),
-- only public listing data and prices (no plate, VIN, owner, renter or cost), the partner's markup, another partner's cars
-- and calls unseen, a revoked key refused at once, the per-key rate limit, the switch, the call log, Admin-only management.
-- Fixtures "r37c"; addresses are example.test.
select test.suite('99 r37 channel api (2304)');

select test.mk_user('r37c_admin', 'admin');
select test.mk_user('r37c_sales', 'va', 'sales');
select test.mk_owner('r37c_olive');
select test.mk_vehicle('r37c_car', 'r37c_olive');
select test.mk_vehicle('r37c_suv', 'r37c_olive');
insert into vehicle_listings (vehicle_id) values (test.id('vehicle:r37c_car')), (test.id('vehicle:r37c_suv')) on conflict (vehicle_id) do nothing;
update vehicle_listings set status = 'published', slug = 'r37c-car-' || left(vehicle_id::text, 6), seats = 5 where vehicle_id in (test.id('vehicle:r37c_car'), test.id('vehicle:r37c_suv'));
-- a VIN of its own: 87 and 99_r28 use 1HGCM82633A004352 (vehicles.vin is unique)
update vehicles set vin = '3R37CHANNEL000001', class = 'standard' where id = test.id('vehicle:r37c_car');
update vehicles set class = 'suv' where id = test.id('vehicle:r37c_suv');
create function pg_temp.adm(p_name text, p jsonb) returns jsonb language sql as $$ select public.door(test.id('r37c_admin'), 'aal2', case when p_name = 'channel_state' then 'admin_read' else 'admin_do' end, p_name, p) $$;

select pg_temp.adm('channel_partner_save', jsonb_build_object('id', test.id('partner:A'), 'name', 'Partner A', 'markup_bps', 1000, 'calls_per_minute', 3, 'allowed_classes', jsonb_build_array('standard')));
select pg_temp.adm('channel_partner_save', jsonb_build_object('id', test.id('partner:B'), 'name', 'Partner B'));
create temp table r37k as select pg_temp.adm('channel_key_create', jsonb_build_object('partner', test.id('partner:A'))) ->> 'new_key' a,
                                 pg_temp.adm('channel_key_create', jsonb_build_object('partner', test.id('partner:B'), 'scopes', jsonb_build_array('availability:read', 'rates:read', 'bookings:create'))) ->> 'new_key' b;
select test.ok('a key is shown once and kept only as its SHA-256', (select a like 'cc_chan_%' from r37k)
  and not exists (select 1 from channel_keys k, r37k where k.key_hash = a or k.prefix = a)
  and exists (select 1 from channel_keys k, r37k where k.key_hash = encode(sha256(convert_to(a, 'UTF8')), 'hex')));
select test.eq('scopes: availability and rates by default, bookings off', (select scopes from channel_keys where partner_id = test.id('partner:A')), array['availability:read', 'rates:read']);
select test.throws('staff do not manage partners', $$select public.door(test.id('r37c_sales'), 'aal2', 'admin_do', 'channel_key_create', jsonb_build_object('partner', test.id('partner:A')))$$, null);

create temp table r37v as select public.channel_api((select a from r37k), 'vehicles', '{}') r;
-- other suites' published cars are listed too: this suite's two cars, and only the allowed class
select test.eq('Partner A sees only its allowed class', (select count(*) filter (where v ->> 'ref' like 'r37c-%') || '/' || count(*) filter (where v ->> 'class' <> 'standard')
  from r37v, jsonb_array_elements(r #> '{data,vehicles}') v), '1/0');
select test.ok('only public fields: no plate, VIN, owner or cost', (select not (r::text ~* '(3R37CHANNEL000001|plate|vin|owner|cost|odometer)') from r37v)
  and (select (select array_agg(k order by k) from jsonb_object_keys(r #> '{data,vehicles,0}') k) <@ array['body_style', 'class', 'doors', 'features', 'luggage', 'make', 'model', 'photos', 'ref', 'seats', 'transmission', 'trim', 'year'] from r37v));
select test.ok('Partner B sees every class (both cars)', (select count(*) = 2 from jsonb_array_elements(public.channel_api((select b from r37k), 'vehicles', '{}') #> '{data,vehicles}') v where v ->> 'ref' like 'r37c-%'));

create temp table r37q as select public.channel_api((select b from r37k), 'availability', jsonb_build_object('pickup_at', now() + interval '10 days', 'return_at', now() + interval '12 days', 'ref', 'r37c-car-' || left(test.id('vehicle:r37c_car')::text, 6))) r;
create temp table r37qa as select public.channel_api((select a from r37k), 'availability', jsonb_build_object('pickup_at', now() + interval '10 days', 'return_at', now() + interval '12 days', 'ref', 'r37c-car-' || left(test.id('vehicle:r37c_car')::text, 6))) r;
select test.ok('availability answers the public quote (no personal data)', (select (r ->> 'ok')::boolean and jsonb_array_length(r #> '{data,vehicles}') = 1 and not (r::text ~* '(owner|email|phone|vin|plate|legal_name|date_of_birth|cost)') from r37q));
select test.eq('Partner A''s 10% markup is on the rental', (select ((r #>> '{data,vehicles,0,rental_cents}')::bigint) from r37qa),
  (select round(((r #>> '{data,vehicles,0,rental_cents}')::bigint) * 1.1)::bigint from r37q));
select test.eq('Partner A cannot book (scope off by default)', (select public.channel_api(a, 'booking_create', '{}') ->> 'code' from r37k), 'scope');
select test.eq('a partner cancels only its own bookings', (select public.channel_api(b, 'booking_cancel', '{"booking_number": "CC-1"}') ->> 'code' from r37k), 'scope');

-- rate limit: Partner A has 3 calls a minute (scope refusals are not counted): vehicles, availability, then locations
select test.eq('the 3rd call in the minute answers', (select public.channel_api(a, 'locations', '{}') ->> 'ok' from r37k), 'true');
select test.eq('the 4th call in the minute is refused', (select public.channel_api(a, 'vehicles', '{}') ->> 'code' from r37k), 'rate');
select test.eq('the other partner is not affected', (select public.channel_api(b, 'vehicles', '{}') ->> 'ok' from r37k), 'true');
-- revoked at once
select pg_temp.adm('channel_key_revoke', jsonb_build_object('id', (select id from channel_keys where partner_id = test.id('partner:B'))));
select test.eq('a revoked key is refused at once', (select public.channel_api(b, 'vehicles', '{}') ->> 'code' from r37k), 'key');
select test.eq('an unknown key is refused', public.channel_api('cc_chan_nope', 'vehicles', '{}') ->> 'code', 'key');
update program_settings set channel_api_enabled = false where id = (app.settings()).id;
select test.eq('the switch off refuses everyone', (select public.channel_api(a, 'locations', '{}') ->> 'code' from r37k), 'off');
update program_settings set channel_api_enabled = true where id = (app.settings()).id;
select test.ok('every call is in the log, refused ones too', (select count(*) >= 8 and count(*) filter (where not ok) >= 5 from channel_calls));
select test.ok('the Admin reads the log', jsonb_array_length(pg_temp.adm('channel_state', '{}') -> 'calls') >= 8);
select test.ok('partners, keys and the log are closed to signed-in users, the entry point is the server''s',
  not has_table_privilege('authenticated', 'channel_keys', 'select') and not has_table_privilege('authenticated', 'channel_calls', 'select')
  and not has_function_privilege('anon', 'public.channel_api(text, text, jsonb)', 'execute') and not has_function_privilege('authenticated', 'public.channel_api(text, text, jsonb)', 'execute'));
