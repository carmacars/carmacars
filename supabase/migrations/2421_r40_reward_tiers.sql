-- 2421_r40_reward_tiers.sql (release 40)
-- The owner, Nov 12: CarmaCars Rewards has three tiers with real perks, by points earned, no discounts.
--   1. Tiers by POINTS EARNED in the last 12 months (reward_ledger kind earn; redeeming never drops a tier): Gold 1,000,
--      Platinum 15,000, Black 60,000 (reward_tiers.min_points, edited on Admin > Rewards). Below Gold a renter has no
--      tier ("Member" in words only: the member row stays as the floor). Silver is retired (active false), never deleted.
--      No tier discount any more: no new tier promo code is made; the codes already issued stay valid until they end.
--   2. Perks are rows (reward_tier_perks), each on one tier and kept by every tier above (cumulative), edited on Admin >
--      Rewards (which tier, the words, on or off):
--        instant_book  Gold      Instant Book: app.instant_book_check reads the tier instead of the completed rentals
--                                (an Admin's revoke, the licence, claims and money owing still decide first).
--        any_car       Platinum  "Any car, any time": a request on dates the car shows as taken is a priority request
--                                (bookings.any_car_priority, any_car_due_at) with an urgent Fleet task due within
--                                rewards_settings.any_car_response_hours (4). Fleet confirms, offers an equivalent or an
--                                upgrade, or declines with a reason, with the usual offer and decline. Nothing here
--                                touches another renter's booking: the request is only a request until Fleet acts.
--        free_day      Black     One free rental day a year: a one-time code (free_days 1, the renter's own, a year to
--                                use it), promo_codes.company_funded: the split gives the owner the payout of the price
--                                before that code, so the day comes out of CarmaCars' share, never the owner's payout.
--   3. my_rewards adds `ladder` (points earned in 12 months, the tier, the three tiers with their perks, the free day
--      code, the response hours); public.my_any_car() tells the car page whether the signed-in renter may request taken
--      dates.
-- No applied migration is edited: functions that change are wrapped (_pre2421) or replaced whole where 0214 owns them.
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
create function pg_temp.patch_fn(p_sig regprocedure, p_old text, p_new text) returns void
language plpgsql as $$
declare d text := pg_get_functiondef(p_sig);
begin
  if position(p_old in d) = 0 then raise exception '2421: the text to change was not found in %: %', p_sig, left(p_old, 120); end if;
  execute replace(d, p_old, p_new);
end $$;

-- ================================================================ 1. tiers by points
alter table reward_tiers add column if not exists min_points integer not null default 0 check (min_points between 0 and 10000000),
  add column if not exists active boolean not null default true;
comment on column reward_tiers.min_points is 'Points earned in the last 12 months to reach the tier (2421; redeemed points still count).';
comment on column reward_tiers.active is 'A retired tier (2421: Silver) stays for the history and is never reached.';
alter table reward_tiers alter column min_days set default 0;
update reward_tiers set min_points = 0, discount_bps = 0, perk = 'Earn points on every rental' where code = 'member';
update reward_tiers set active = false, discount_bps = 0 where code = 'silver';
update reward_tiers set min_points = 1000, min_days = 0, discount_bps = 0, perk = null, sort = 3 where code = 'gold';
insert into reward_tiers (code, name, min_days, min_points, discount_bps, perk, sort) values
  ('platinum', 'Platinum', 0, 15000, 0, null, 4),
  ('black', 'Black', 0, 60000, 0, null, 5)
on conflict (code) do nothing;
comment on table reward_tiers is 'CarmaCars Rewards (0214, 2421): tiers by points earned in the last 12 months (Gold, Platinum, Black; member is the floor, "Member" in words). Perks are reward_tier_perks; no tier discount since 2421.';

alter table rewards_settings add column if not exists any_car_response_hours integer not null default 4 check (any_car_response_hours between 1 and 72);
comment on column rewards_settings.any_car_response_hours is 'Any car, any time (2421): Fleet answers a priority request within this many hours.';

create table if not exists reward_tier_perks (
  code       text primary key check (code in ('instant_book', 'any_car', 'free_day')),
  tier_code  text not null references reward_tiers (code),
  label      text not null check (length(btrim(label)) between 2 and 80),
  detail     text check (detail is null or length(detail) <= 300),
  enabled    boolean not null default true,
  sort       integer not null default 0,
  updated_by uuid references users (id),
  updated_at timestamptz not null default now()
);
create index if not exists reward_tier_perks_tier_idx on reward_tier_perks (tier_code);
create index if not exists reward_tier_perks_updated_by_idx on reward_tier_perks (updated_by) where updated_by is not null;
insert into reward_tier_perks (code, tier_code, label, detail, sort) values
  ('instant_book', 'gold', 'Instant Book', 'Book without sending a request: the car is yours at once, then you sign and pay.', 1),
  ('any_car', 'platinum', 'Any car, any time', 'Request any car, even on dates it shows as taken. We will open it up for you.', 2),
  ('free_day', 'black', 'A free rental day every year', 'A one-time code for one free day, good for a year. CarmaCars pays for it, not the car owner.', 3)
on conflict (code) do nothing;
comment on table reward_tier_perks is 'CarmaCars Rewards perks (2421): each on one tier and kept by every tier above it.';
alter table reward_tier_perks enable row level security;
revoke all on reward_tier_perks from anon, authenticated;

alter table reward_accounts add column if not exists free_day_promo_id uuid references promo_codes (id);
create index if not exists reward_accounts_free_day_promo_idx on reward_accounts (free_day_promo_id) where free_day_promo_id is not null;
comment on column reward_accounts.free_day_promo_id is 'The latest free rental day code of the Black tier (2421), one a year.';

alter table promo_codes add column if not exists company_funded boolean not null default false;
comment on column promo_codes.company_funded is 'The discount comes out of CarmaCars'' share, never the owner''s payout (2421: the Black tier''s free day).';

-- points earned in the last 12 months (what the tier reads): redeeming, expiry and refunds never lower it; a reversed earn does
create or replace function app.rewards_points_12m(p_renter uuid) returns integer
language sql stable security definer set search_path = public, app as $$
  select coalesce(sum(points), 0)::integer from reward_ledger
   where renter_id = p_renter and kind = 'earn' and points > 0 and reversed_at is null and created_at > now() - interval '12 months'
$$;

create or replace function app.rewards_tier_of(p_renter uuid) returns reward_tiers
language sql stable security definer set search_path = public, app as $$
  select t.* from reward_tiers t where t.active and t.min_points <= app.rewards_points_12m(p_renter) order by t.min_points desc, t.sort desc limit 1
$$;

-- has the renter's tier (or a tier below it) this perk, switched on?
create or replace function app.rewards_has_perk(p_renter uuid, p_perk text) returns boolean
language sql stable security definer set search_path = public, app as $$
  select coalesce((app.rewards()).enabled, false) and exists (
    select 1 from reward_tier_perks k join reward_tiers pt on pt.code = k.tier_code
     where k.code = p_perk and k.enabled and pt.active and pt.min_points <= coalesce((app.rewards_tier_of(p_renter)).min_points, -1)
       and (app.rewards_tier_of(p_renter)).code <> 'member')
$$;

-- the tier kept in step; no tier code is made any more and the ones issued are left as they are (valid until they end);
-- the Black tier's free day: one code a year while the renter has the perk
create or replace function app.rewards_sync_tier(p_renter uuid) returns text
language plpgsql security definer set search_path = public, app as $$
declare
  a reward_accounts := app.rewards_account(p_renter);
  t reward_tiers := app.rewards_tier_of(p_renter);
  v_id uuid;
begin
  if a.tier_code is distinct from t.code then update reward_accounts set tier_code = t.code where renter_id = p_renter; end if;
  if app.rewards_has_perk(p_renter, 'free_day')
     and not exists (select 1 from promo_codes pc where pc.renter_id = p_renter and pc.source = 'rewards_free_day' and pc.created_at > now() - interval '1 year') then
    insert into promo_codes (code, description, free_days, once_per_renter, max_uses, renter_id, source, company_funded, valid_until)
    values (app.rewards_code('FREE'), 'CarmaCars Rewards ' || t.name || ': one free rental day', 1, true, 1, p_renter, 'rewards_free_day', true, now() + interval '1 year')
    returning id into v_id;
    update reward_accounts set free_day_promo_id = v_id where renter_id = p_renter;
  end if;
  return t.code;
end $$;
revoke all on function app.rewards_points_12m(uuid), app.rewards_has_perk(uuid, text) from public, anon, authenticated;

-- ================================================================ 2. Instant Book reads the tier (Gold and up)
select pg_temp.patch_fn('app.instant_book_check(uuid)'::regprocedure,
  'when v_done < s.instant_book_min_rentals then format(''%s of %s completed rentals'', v_done, s.instant_book_min_rentals)',
  'when not app.rewards_has_perk(r.id, ''instant_book'') then format(''Instant Book comes with a Rewards tier: %s points earned in 12 months'', app.rewards_points_12m(r.id))');

-- ================================================================ 3. Any car, any time: the priority request
alter table bookings add column if not exists any_car_priority boolean not null default false,
  add column if not exists any_car_due_at timestamptz;
comment on column bookings.any_car_priority is 'Any car, any time (2421): a Platinum renter asked for dates the car shows as taken. Fleet confirms, offers an equivalent or upgrade, or declines with a reason; nothing moves another booking.';
create index if not exists bookings_any_car_open_idx on bookings (any_car_due_at) where any_car_priority and status = 'requested';

alter function app.submit_booking_request(jsonb, inet, text, uuid) rename to submit_booking_request_pre2421;
create function app.submit_booking_request(p_request jsonb, p_ip inet default null, p_user_agent text default null, p_user uuid default null) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  v_out jsonb := app.submit_booking_request_pre2421(p_request, p_ip, p_user_agent, p_user);
  v_hours integer := coalesce((app.rewards()).any_car_response_hours, 4);
  b bookings;
begin
  if coalesce((v_out ->> 'ok')::boolean, false) and coalesce((v_out ->> 'conflict_at_submit')::boolean, false) and nullif(v_out ->> 'renter_id', '') is not null
     and app.rewards_has_perk((v_out ->> 'renter_id')::uuid, 'any_car') then
    update bookings set any_car_priority = true, any_car_due_at = now() + make_interval(hours => v_hours)
     where id = (v_out ->> 'booking_id')::uuid returning * into b;
    perform app.raise_task(p_type => 'any_car_request', p_title => left(format('Any car, any time: %s (%s)', b.booking_number, (select v.make || ' ' || v.model from vehicles v where v.id = b.vehicle_id)), 200),
      p_detail => format('A %s member asked for dates this car shows as taken. Answer within %s hours: confirm it, offer an equivalent car or an upgrade, or decline with a reason. Never cancel or move another renter''s confirmed booking.',
                         (app.rewards_tier_of(b.renter_id)).name, v_hours),
      p_booking => b.id, p_vehicle => b.vehicle_id, p_renter => b.renter_id, p_due_at => b.any_car_due_at, p_priority => 'urgent', p_queue => 'fleet',
      p_dedupe => 'any_car:' || b.id);
    v_out := v_out || jsonb_build_object('any_car', true, 'any_car_due_at', b.any_car_due_at, 'any_car_hours', v_hours);
  end if;
  return v_out;
end $$;
select pg_temp.copy_grants('app.submit_booking_request(jsonb, inet, text, uuid)'::regprocedure, 'app.submit_booking_request_pre2421(jsonb, inet, text, uuid)'::regprocedure);

-- the Fleet task closes once the request is answered (an offer, a decline, a withdrawal)
create or replace function app.any_car_answered() returns trigger
language plpgsql security definer set search_path = public, app as $$
begin
  if new.any_car_priority and old.status = 'requested' and new.status <> 'requested' then
    update tasks set status = 'done', completed_at = now(), completion_note = 'Answered: ' || new.status::text
     where dedupe_key = 'any_car:' || new.id and status in ('open', 'in_progress', 'waiting');
  end if;
  return new;
end $$;
drop trigger if exists bookings_any_car_answered on bookings;
create trigger bookings_any_car_answered after update of status on bookings for each row when (new.any_car_priority) execute function app.any_car_answered();

-- the car page: may the signed-in renter request dates the car shows as taken?
create or replace function public.my_any_car() returns jsonb
language sql stable security definer set search_path = public, app as $$
  select jsonb_build_object('any_car', coalesce(app.rewards_has_perk(app.rewards_renter_of(app.uid()), 'any_car'), false),
                            'hours', (app.rewards()).any_car_response_hours,
                            'tier', case when app.rewards_has_perk(app.rewards_renter_of(app.uid()), 'any_car') then (app.rewards_tier_of(app.rewards_renter_of(app.uid()))).name end)
$$;
revoke all on function public.my_any_car() from public;
grant execute on function public.my_any_car() to anon, authenticated, service_role;

-- ================================================================ 4. the free day comes out of CarmaCars' share
alter function app.compute_booking_split(uuid) rename to compute_booking_split_pre2421;
create function app.compute_booking_split(p_booking uuid) returns void
language plpgsql security definer set search_path = public, app as $$
declare
  v_disc bigint;
  v_w bigint;
begin
  perform app.compute_booking_split_pre2421(p_booking);
  select b.promo_discount_cents into v_disc from bookings b join promo_codes pc on pc.id = b.promo_code_id
   where b.id = p_booking and pc.company_funded and b.promo_discount_cents > 0;
  if coalesce(v_disc, 0) <= 0 then return; end if;
  -- the owner's part of the discount goes back to the owner, taken from the company share (a flat arrangement, a
  -- partner's listed-rate payout and a booking left out of the owner's revenue have no owner part to give back)
  select sum(rental_charge_cents) into v_w from booking_splits
   where booking_id = p_booking and owner_statement_id is null and flat_arrangement_id is null and partner_kickback_cents = 0 and rental_charge_cents > 0;
  if coalesce(v_w, 0) <= 0 then return; end if;
  update booking_splits s
     set owner_payout_cents = s.owner_payout_cents + x.back, company_share_cents = s.company_share_cents - x.back
    from (select vehicle_id, round(round(v_disc::numeric * rental_charge_cents / v_w) * (10000 - company_share_bps) / 10000)::bigint as back
            from booking_splits where booking_id = p_booking and owner_statement_id is null and flat_arrangement_id is null and partner_kickback_cents = 0 and rental_charge_cents > 0) x
   where s.booking_id = p_booking and s.vehicle_id = x.vehicle_id and x.back > 0;
end $$;
select pg_temp.copy_grants('app.compute_booking_split(uuid)'::regprocedure, 'app.compute_booking_split_pre2421(uuid)'::regprocedure);

-- ================================================================ 5. the renter's Rewards: the ladder
alter function app.rewards_state(uuid) rename to rewards_state_pre2421;
create function app.rewards_state(p_renter uuid) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  v jsonb := app.rewards_state_pre2421(p_renter);
  t reward_tiers;
  nt reward_tiers;
  v_pts integer;
  fd promo_codes;
  v_tiers jsonb;
begin
  if p_renter is null or not coalesce((v ->> 'renter')::boolean, false) then return v; end if;
  v_pts := app.rewards_points_12m(p_renter);
  t := app.rewards_tier_of(p_renter);
  select * into nt from reward_tiers x where x.active and x.code <> 'member' and x.min_points > v_pts order by x.min_points limit 1;
  select pc.* into fd from reward_accounts a join promo_codes pc on pc.id = a.free_day_promo_id where a.renter_id = p_renter;
  select coalesce(jsonb_agg(jsonb_build_object('code', x.code, 'name', x.name, 'min_points', x.min_points,
           'perks', (select coalesce(jsonb_agg(jsonb_build_object('code', k.code, 'label', k.label, 'detail', k.detail) order by k.sort), '[]'::jsonb)
                       from reward_tier_perks k where k.tier_code = x.code and k.enabled)) order by x.min_points), '[]'::jsonb)
    into v_tiers from reward_tiers x where x.active and x.code <> 'member';
  return v || jsonb_build_object(
    'tier', jsonb_build_object('code', t.code, 'name', case when t.code = 'member' then 'Member' else t.name end, 'discount_bps', 0, 'perk', null,
                               'promo_code', v -> 'tier' ->> 'promo_code'),
    'next_tier', case when nt.code is not null then jsonb_build_object('name', nt.name, 'days_needed', 0, 'points_needed', nt.min_points - v_pts, 'discount_bps', 0) end,
    'tiers', (select coalesce(jsonb_agg(jsonb_build_object('code', x ->> 'code', 'name', x ->> 'name', 'min_days', 0, 'discount_bps', 0, 'perk', null)), '[]'::jsonb) from jsonb_array_elements(v_tiers) x),
    'ladder', jsonb_build_object('points_12m', v_pts, 'tier_code', case when t.code = 'member' then null else t.code end, 'tiers', v_tiers,
      'any_car_hours', (app.rewards()).any_car_response_hours,
      'free_day', case when fd.id is not null then jsonb_build_object('code', fd.code, 'valid_until', fd.valid_until,
        'used', fd.is_active is false or exists (select 1 from promo_redemptions r where r.promo_code_id = fd.id and r.status in ('applied', 'redeemed'))) end));
end $$;
select pg_temp.copy_grants('app.rewards_state(uuid)'::regprocedure, 'app.rewards_state_pre2421(uuid)'::regprocedure);

-- ================================================================ 6. Admin > Rewards: thresholds, perks, the response time
create or replace function app.rewards_tiers_admin_do(p_by uuid, p_name text, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  v_tier text := nullif(p ->> 'tier_code', '');
begin
  perform app.assert_admin(p_by);
  if p_name = 'rewards_tier_save' then
    update reward_tiers set name = coalesce(nullif(btrim(p ->> 'name'), ''), name), min_points = coalesce((p ->> 'min_points')::int, min_points)
     where code = p ->> 'code' and active and code <> 'member';
    if not found then raise exception 'Unknown tier' using errcode = 'P0002'; end if;
    if exists (select 1 from reward_tiers a join reward_tiers b on a.active and b.active and a.code <> b.code and a.code <> 'member' and b.code <> 'member'
                and a.sort < b.sort and a.min_points >= b.min_points) then
      raise exception 'Each tier needs more points than the one below it' using errcode = '22023'; end if;
    if exists (select 1 from reward_tiers where active and code <> 'member' and min_points < 1) then raise exception 'A tier starts at 1 point or more' using errcode = '22023'; end if;
    insert into audit_log (actor_user_id, action, entity_table, entity_id, after) values (p_by, p_name, 'reward_tiers', p ->> 'code', p);
    perform app.rewards_sync_tier(renter_id) from reward_accounts;
    return (select to_jsonb(t) from reward_tiers t where code = p ->> 'code');
  elsif p_name = 'rewards_perk_save' then
    if v_tier is not null and not exists (select 1 from reward_tiers where code = v_tier and active and code <> 'member') then
      raise exception 'Choose Gold, Platinum or Black' using errcode = '22023'; end if;
    update reward_tier_perks set tier_code = coalesce(v_tier, tier_code), label = coalesce(nullif(btrim(p ->> 'label'), ''), label),
           detail = case when p ? 'detail' then nullif(btrim(p ->> 'detail'), '') else detail end, enabled = coalesce((p ->> 'enabled')::boolean, enabled),
           updated_by = p_by, updated_at = now()
     where code = p ->> 'code';
    if not found then raise exception 'Unknown perk' using errcode = 'P0002'; end if;
    insert into audit_log (actor_user_id, action, entity_table, entity_id, after) values (p_by, p_name, 'reward_tier_perks', p ->> 'code', p);
    return (select to_jsonb(k) from reward_tier_perks k where code = p ->> 'code');
  end if;
  raise exception 'Unknown action' using errcode = '22023';
end $$;
revoke all on function app.rewards_tiers_admin_do(uuid, text, jsonb) from public, anon, authenticated;

alter function app.door(uuid, text, text, text, jsonb) rename to door_pre2421;
create function app.door(p_user uuid, p_aal text, p_call text, p_name text, p jsonb default '{}'::jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  v jsonb;
begin
  if p_call = 'admin_read' and p_name = 'rewards' then
    v := app.door_pre2421(p_user, p_aal, p_call, p_name, p);
    return v || jsonb_build_object(
      'tiers', (select coalesce(jsonb_agg(to_jsonb(t) order by t.min_points), '[]'::jsonb) from reward_tiers t where t.active and t.code <> 'member'),
      'perks', (select coalesce(jsonb_agg(to_jsonb(k) order by k.sort), '[]'::jsonb) from reward_tier_perks k),
      'any_car_response_hours', (app.rewards()).any_car_response_hours,
      'any_car_open', (select coalesce(jsonb_agg(jsonb_build_object('number', b.booking_number, 'due_at', b.any_car_due_at, 'late', b.any_car_due_at < now(),
                         'vehicle', v2.year || ' ' || v2.make || ' ' || v2.model) order by b.any_car_due_at), '[]'::jsonb)
                        from bookings b join vehicles v2 on v2.id = b.vehicle_id where b.any_car_priority and b.status = 'requested'));
  end if;
  if p_call = 'admin_do' and p_name in ('rewards_tier_save', 'rewards_perk_save') then
    perform app.door_begin(p_user, p_aal);
    return app.rewards_tiers_admin_do(p_user, p_name, coalesce(p, '{}'::jsonb) - '_va');
  end if;
  if p_call = 'admin_do' and p_name = 'rewards_settings_save' and p ? 'any_car_response_hours' then
    -- the rest of the settings as before (it checks the Admin), then the response time
    v := app.door_pre2421(p_user, p_aal, p_call, p_name, p - 'any_car_response_hours');
    update rewards_settings set any_car_response_hours = (p ->> 'any_car_response_hours')::int, updated_by = p_user, updated_at = now() where singleton;
    return v || jsonb_build_object('any_car_response_hours', (p ->> 'any_car_response_hours')::int);
  end if;
  return app.door_pre2421(p_user, p_aal, p_call, p_name, p);
end $$;
select pg_temp.copy_grants('app.door(uuid, text, text, text, jsonb)'::regprocedure, 'app.door_pre2421(uuid, text, text, text, jsonb)'::regprocedure);

-- every renter's tier as points decide it now (no code made, none taken away; Black gets its free day code)
select app.rewards_sync_tier(renter_id) from reward_accounts;
