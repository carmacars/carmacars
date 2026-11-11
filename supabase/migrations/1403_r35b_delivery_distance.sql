-- 1403_r35b_delivery_distance.sql
-- Release 35 part B, task 4 (docs/changes/2026-11-11-r35-card-pick-opcf-fuel-delivery.md). The owner, November 11, 2026:
-- "Delivery priced by distance: $75 base including the first 15 km from the company address, then $2 a km; road distance
-- (straight-line distance x 1.3 when no road distance), each way for delivery and pickup, shown at checkout and in offers.
-- Per-car override still possible."
--
-- 1. Program settings: delivery_base_cents (7500), delivery_included_km (15), delivery_per_km_cents (now 200 a km),
--    delivery_road_factor (1.3); the company's location (company_latitude, company_longitude) filled for the address on
--    file when it was empty, so every delivery is measured from it.
-- 2. Each leg (delivery, and pickup at the end): the car's base fee + the per-km rate x the km beyond the included km,
--    between the optional minimum and maximum, rounded as before (app.delivery_fee). The distance: the road distance the
--    server measured; without one, the straight line from the company to the place the server located (lat, lng) x the
--    road factor; an airport without its driving distance the same. The quote and the offer carry included_km and the
--    working.
-- 3. The base: the program's delivery_base_cents for every car, unless the car's rate card has its own delivery or pickup
--    fee (rate_cards.delivery_fee_custom, set when a rate card is saved with another amount: the per-car override). A new
--    base in Program settings moves every car that follows it.
-- No applied migration is edited.

create function pg_temp.patch_fn(p_sig regprocedure, p_old text, p_new text) returns void
language plpgsql as $$
declare
  d text := pg_get_functiondef(p_sig);
begin
  if position(p_old in d) = 0 then
    raise exception '1403: the text to change was not found in %: %', p_sig, left(p_old, 120);
  end if;
  execute replace(d, p_old, p_new);
end $$;

-- ================================================================ 1. settings
alter table program_settings
  add column if not exists delivery_base_cents bigint not null default 7500 check (delivery_base_cents >= 0),
  add column if not exists delivery_included_km numeric(6, 1) not null default 15 check (delivery_included_km >= 0),
  add column if not exists delivery_road_factor numeric(4, 2) not null default 1.3 check (delivery_road_factor between 1 and 3);
comment on column program_settings.delivery_base_cents is 'Each delivery or pickup leg: this base fee, which includes the first delivery_included_km from the company''s location (1403); a car''s own rate card fee overrides it';
comment on column program_settings.delivery_included_km is 'The km from the company''s location included in the delivery base fee (1403)';
comment on column program_settings.delivery_road_factor is 'Without a road distance, the straight-line distance times this (1.3) (1403)';
alter table program_settings alter column delivery_per_km_cents set default 200;
-- the owner's rate, on the row in force (a rate already set by an Admin is kept)
update program_settings set delivery_per_km_cents = 200 where id = (app.settings()).id and delivery_per_km_cents = 0;
-- the company's location: the address on file (2967 Dundas St W, Toronto), when none was entered
update program_settings set company_latitude = 43.6655, company_longitude = -79.4686
 where id = (app.settings()).id and company_latitude is null and company_longitude is null and company_address ilike '%2967 Dundas%';

-- ================================================================ 3. the per-car override
alter table rate_cards add column if not exists delivery_fee_custom boolean not null default false;
comment on column rate_cards.delivery_fee_custom is 'The car has its own delivery or pickup fee (the per-car override); otherwise both follow Program settings delivery_base_cents (1403)';
update rate_cards set delivery_fee_custom = delivery_fee_cents <> (app.settings()).delivery_base_cents or pickup_fee_cents <> (app.settings()).delivery_base_cents;

create or replace function app.rate_card_delivery_custom() returns trigger
language plpgsql security definer set search_path = public, app as $$
declare
  v_base bigint := (app.settings()).delivery_base_cents;
begin
  new.delivery_fee_custom := new.delivery_fee_cents <> v_base or new.pickup_fee_cents <> v_base;
  return new;
end $$;
drop trigger if exists rate_cards_delivery_custom on rate_cards;
create trigger rate_cards_delivery_custom before insert or update of delivery_fee_cents, pickup_fee_cents on rate_cards
  for each row execute function app.rate_card_delivery_custom();

-- a new base moves every car that follows it (the shown fees stay true)
create or replace function app.delivery_base_follow() returns trigger
language plpgsql security definer set search_path = public, app as $$
declare
  v_base bigint := (app.settings()).delivery_base_cents;
begin
  update rate_cards set delivery_fee_cents = v_base, pickup_fee_cents = v_base
   where not delivery_fee_custom and (delivery_fee_cents <> v_base or pickup_fee_cents <> v_base)
     and (effective_to is null or effective_to > now());
  return null;
end $$;
drop trigger if exists program_settings_delivery_base on program_settings;
create trigger program_settings_delivery_base after insert or update on program_settings
  for each statement execute function app.delivery_base_follow();

-- ================================================================ 2. the fee of a leg
select pg_temp.patch_fn('app.delivery_fee(uuid, text, jsonb)'::regprocedure,
  $o$  v_surcharge bigint := 0;$o$,
  $n$  v_surcharge bigint := 0;
  v_how text;$n$);
select pg_temp.patch_fn('app.delivery_fee(uuid, text, jsonb)'::regprocedure,
  $o$  v_base := coalesce(case when p_leg = 'return' then rc.pickup_fee_cents else rc.delivery_fee_cents end, 0);$o$,
  $n$  v_base := case when rc.id is not null and rc.delivery_fee_custom then case when p_leg = 'return' then rc.pickup_fee_cents else rc.delivery_fee_cents end
                  else s.delivery_base_cents end;$n$);
select pg_temp.patch_fn('app.delivery_fee(uuid, text, jsonb)'::regprocedure,
  $o$    v_km := coalesce(a.distance_km, app.distance_km(s.company_latitude, s.company_longitude, a.latitude, a.longitude));$o$,
  $n$    v_km := coalesce(a.distance_km, round(app.distance_km(s.company_latitude, s.company_longitude, a.latitude, a.longitude) * s.delivery_road_factor, 1));
    v_how := case when a.distance_km is not null then 'road' else 'straight_line' end;$n$);
select pg_temp.patch_fn('app.delivery_fee(uuid, text, jsonb)'::regprocedure,
  $o$  elsif not v_browser then
    v_km := (p_place ->> 'distance_km')::numeric;
  end if;$o$,
  $n$  elsif not v_browser then
    v_km := (p_place ->> 'distance_km')::numeric;
    v_how := case when v_km is not null then 'road' end;
    -- no road distance: the straight line to the place the server located, times the road factor
    if v_km is null and nullif(p_place ->> 'lat', '') is not null and nullif(p_place ->> 'lng', '') is not null and s.company_latitude is not null then
      v_km := round(app.distance_km(s.company_latitude, s.company_longitude, (p_place ->> 'lat')::numeric, (p_place ->> 'lng')::numeric) * s.delivery_road_factor, 1);
      v_how := 'straight_line';
    end if;
  end if;$n$);
select pg_temp.patch_fn('app.delivery_fee(uuid, text, jsonb)'::regprocedure,
  $o$    v_dist_part := round(s.delivery_per_km_cents * v_km)::bigint;$o$,
  $n$    v_dist_part := round(s.delivery_per_km_cents * greatest(v_km - s.delivery_included_km, 0))::bigint;$n$);
select pg_temp.patch_fn('app.delivery_fee(uuid, text, jsonb)'::regprocedure,
  $o$                            'needs_distance', v_kind = 'delivery' and v_km is null);$o$,
  $n$                            'needs_distance', v_kind = 'delivery' and v_km is null,
                            'included_km', s.delivery_included_km, 'extra_km', case when v_km is null then null else greatest(v_km - s.delivery_included_km, 0) end,
                            'distance_how', v_how, 'road_factor', s.delivery_road_factor, 'custom_base', coalesce(rc.delivery_fee_custom, false));$n$);

-- the booking keeps the distance it was priced on (a later reprice reads it): the straight line x the road factor when
-- the server located the place but had no road distance
select pg_temp.patch_fn('app.apply_booking_places(uuid, jsonb)'::regprocedure,
  $o$      v_km := (pl ->> 'distance_km')::numeric;$o$,
  $n$      v_km := coalesce((pl ->> 'distance_km')::numeric,
                       case when nullif(pl ->> 'lat', '') is not null and nullif(pl ->> 'lng', '') is not null and (app.settings()).company_latitude is not null
                            then round(app.distance_km((app.settings()).company_latitude, (app.settings()).company_longitude, (pl ->> 'lat')::numeric, (pl ->> 'lng')::numeric)
                                       * (app.settings()).delivery_road_factor, 1) end);$n$);
