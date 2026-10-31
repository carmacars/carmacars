-- 0214: CarmaCars Rewards, the renter loyalty program (Release 22, item 1). SCHEMA_MARKER 0214.
-- docs/changes/2026-11-02-rewards.md.
--   1. Points. A rental earns rewards_settings.points_per_dollar (1) point per dollar of the rental charge after every
--      discount (never the fees, add-ons, coverage, tax or deposit), when the booking closes (deposit settled). More ways to
--      earn are rows of reward_actions, each on or off with its points (Admin > Settings > Rewards), seeded on:
--      referral (500 to the referrer, 250 to the friend, at the friend's first closed rental; the renter's own code on
--      /r/<code>, never a kickback: owner and staff kickbacks are untouched), a follow on Instagram, TikTok or Facebook (50
--      each, once per platform, granted on the click, which cannot be checked), a review on carmacars.ca (100, once per
--      rental, whatever the rating; the review then says "Received reward points"), a Google review (100, once per rental,
--      whatever the rating, on the renter's word: "I posted my review" with the name on it; Admin > Rewards lists every
--      claim with Reverse), a damage-free rental (200: no incident, no damage, cleaning, smoking or late fee, returned on
--      time), the birthday (100, date of birth on file) and the first rental (100). Every award has a unique source key, so
--      it is given once whatever runs twice.
--   2. Tiers by rental days in the last 12 months (reward_tiers): Member 0, Silver 10, Gold 30 days, with a discount
--      (0, 5%, 10%) as a promo code of the renter's own and a perk line. The discount is a promo code, so it comes off the
--      rental charge only and is shared with the owner exactly like any promo code (0016, 0186).
--   3. Redeeming: a renter turns points into a one-time code of their own (100 points = $1 by default, at least 500), valid
--      90 days, entered as a promo code. It too comes off the rental charge only. An unused code that ends gives the points
--      back; a code can be cancelled for the points while it is unused.
--   4. Expiry: points end 12 months after the last earn or redeem; a reminder email (renter_rewards_expiring, priority 4:
--      after customer, owner and staff emails under the 100-a-day cap) goes 30 days before.
--   5. Admin: the door (admin_read 'rewards', 'rewards_renter'; admin_do 'rewards_settings_save', 'rewards_action_save',
--      'rewards_tier_save', 'rewards_adjust', 'rewards_reverse'), the renter's my_rewards (a read) and its actions
--      (public.rewards_mine_*: not my_*, so an Admin viewing as the renter cannot use them).
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

-- ================================================================ 1. settings, tiers, ways to earn
create table if not exists rewards_settings (
  singleton            boolean primary key default true check (singleton),
  enabled              boolean not null default true,
  points_per_dollar    numeric(6, 2) not null default 1 check (points_per_dollar between 0 and 100),
  point_value_cents    numeric(6, 3) not null default 1 check (point_value_cents > 0 and point_value_cents <= 100),
  min_redeem_points    integer not null default 500 check (min_redeem_points between 1 and 1000000),
  code_valid_days      integer not null default 90 check (code_valid_days between 7 and 730),
  expiry_months        integer not null default 12 check (expiry_months between 1 and 120),
  reminder_days        integer not null default 30 check (reminder_days between 1 and 180),
  late_grace_minutes   integer not null default 30 check (late_grace_minutes between 0 and 1440),
  updated_by           uuid references users (id),
  updated_at           timestamptz not null default now()
);
insert into rewards_settings (singleton) values (true) on conflict do nothing;
comment on table rewards_settings is 'CarmaCars Rewards (0214): on by default; 1 point per dollar of the rental charge after discounts; 100 points = $1 (point_value_cents 1); redeem from 500; codes valid 90 days; points end 12 months after the last earn or redeem, with a reminder 30 days before.';

create table if not exists reward_tiers (
  code          text primary key check (code ~ '^[a-z]{2,20}$'),
  name          text not null check (length(btrim(name)) between 2 and 40),
  min_days      integer not null check (min_days >= 0),
  discount_bps  integer not null default 0 check (discount_bps between 0 and 5000),
  perk          text check (perk is null or length(perk) <= 200),
  sort          integer not null default 0
);
insert into reward_tiers (code, name, min_days, discount_bps, perk, sort) values
  ('member', 'Member', 0, 0, 'Earn points on every rental', 1),
  ('silver', 'Silver', 10, 500, '5% off the rental charge, and one add-on free per rental on request (a child seat or an extra driver)', 2),
  ('gold', 'Gold', 30, 1000, '10% off the rental charge, one add-on free per rental on request, and the first choice of car', 3)
on conflict (code) do nothing;
comment on table reward_tiers is 'CarmaCars Rewards (0214): tiers by rental days in the last 12 months. The discount is a promo code of the renter''s own (off the rental charge only); the perk is a line staff honour on request.';

create table if not exists reward_actions (
  code       text primary key,
  label      text not null,
  detail     text,
  points     integer not null check (points between 0 and 100000),
  enabled    boolean not null default true,
  limit_text text not null,
  sort       integer not null default 0,
  updated_at timestamptz not null default now()
);
insert into reward_actions (code, label, detail, points, limit_text, sort) values
  ('rental', 'Rent a car', 'Points for each dollar of the rental charge after discounts (fees, add-ons, coverage, tax and the deposit do not count). The points figure is per dollar.', 1, 'Every rental, when it closes', 1),
  ('first_rental', 'Your first rental', null, 100, 'Once', 2),
  ('referral_referrer', 'Refer a friend', 'When a friend who used your link completes their first rental.', 500, 'Each friend, once', 3),
  ('referral_referred', 'Rent with a friend''s link', 'For the friend, on that same first rental.', 250, 'Once', 4),
  ('damage_free', 'Damage-free rental', 'No damage, claim, cleaning or smoking fee, and returned on time.', 200, 'Each rental', 5),
  ('review_site', 'Review your rental on carmacars.ca', 'A rating and a few words, good or bad. The review shows that it received reward points.', 100, 'Each rental, once', 6),
  ('review_google', 'Review us on Google', 'Any honest review, good or bad. Press "I posted my review" and give the name on it.', 100, 'Each rental, once', 7),
  ('social_instagram', 'Follow us on Instagram', 'Points when you open our page from your Rewards page. We cannot check the follow.', 50, 'Once', 8),
  ('social_tiktok', 'Follow us on TikTok', 'Points when you open our page from your Rewards page. We cannot check the follow.', 50, 'Once', 9),
  ('social_facebook', 'Follow us on Facebook', 'Points when you open our page from your Rewards page. We cannot check the follow.', 50, 'Once', 10),
  ('birthday', 'Your birthday', 'With your date of birth on file.', 100, 'Once a year', 11)
on conflict (code) do nothing;
comment on table reward_actions is 'CarmaCars Rewards (0214): the ways to earn, each on or off with its points (rental: points per dollar). Admin > Settings > Rewards.';

-- ================================================================ 2. accounts and the ledger
create table if not exists reward_accounts (
  renter_id          uuid primary key references renters (id) on delete cascade,
  referral_code      text not null unique check (referral_code ~ '^[A-Z0-9]{4,12}$'),
  tier_code          text references reward_tiers (code),
  tier_promo_id      uuid references promo_codes (id),
  reminded_for       timestamptz,
  created_at         timestamptz not null default now()
);
comment on column reward_accounts.reminded_for is 'The last-activity time the expiry reminder was sent for (0214): one reminder per activity period.';

create table if not exists reward_ledger (
  id           uuid primary key default gen_random_uuid(),
  renter_id    uuid not null references renters (id) on delete cascade,
  points       integer not null check (points <> 0),
  kind         text not null check (kind in ('earn', 'redeem', 'refund', 'expire', 'adjust', 'reverse')),
  action       text,
  source_key   text not null unique,
  booking_id   uuid references bookings (id) on delete set null,
  promo_code_id uuid references promo_codes (id) on delete set null,
  rental_days  numeric(8, 2),
  reason       text not null,
  meta         jsonb not null default '{}'::jsonb,
  reversed_at  timestamptz,
  created_by   uuid references users (id) on delete set null,
  created_at   timestamptz not null default now()
);
create index if not exists reward_ledger_renter_idx on reward_ledger (renter_id, created_at desc);
create index if not exists reward_ledger_action_idx on reward_ledger (action, created_at desc);
comment on table reward_ledger is 'CarmaCars Rewards (0214): every change of a renter''s points with its reason. source_key makes each award happen once (rental:<booking>, review_google:<booking>, social:<platform>:<renter>, ...). A reversal is a new row (reverse:<id>).';

alter table reviews add column if not exists reward_points boolean not null default false;
comment on column reviews.reward_points is 'The review earned CarmaCars Rewards points (0214): shown with it as "Received reward points".';

create or replace function app.rewards() returns rewards_settings
language sql stable security definer set search_path = public, app as $$ select * from rewards_settings limit 1 $$;

create or replace function app.rewards_action(p_code text) returns reward_actions
language sql stable security definer set search_path = public, app as $$
  select a.* from reward_actions a where a.code = p_code and a.enabled and (app.rewards()).enabled
$$;

create or replace function app.rewards_balance(p_renter uuid) returns integer
language sql stable security definer set search_path = public, app as $$
  select coalesce(sum(points), 0)::int from reward_ledger where renter_id = p_renter
$$;

create or replace function app.rewards_last_activity(p_renter uuid) returns timestamptz
language sql stable security definer set search_path = public, app as $$
  select max(created_at) from reward_ledger where renter_id = p_renter and kind in ('earn', 'redeem', 'adjust') and points <> 0 and reversed_at is null
$$;

create or replace function app.rewards_days_12m(p_renter uuid) returns numeric
language sql stable security definer set search_path = public, app as $$
  select coalesce(sum(rental_days), 0) from reward_ledger
   where renter_id = p_renter and action = 'rental' and reversed_at is null and created_at > now() - interval '12 months'
$$;

create or replace function app.rewards_tier_of(p_renter uuid) returns reward_tiers
language sql stable security definer set search_path = public, app as $$
  select t.* from reward_tiers t where t.min_days <= app.rewards_days_12m(p_renter) order by t.min_days desc limit 1
$$;

create or replace function app.rewards_code(p_prefix text) returns text
language plpgsql volatile as $$
declare v text;
begin
  loop
    v := p_prefix || substr(translate(upper(md5(gen_random_uuid()::text)), '01', ''), 1, 7);
    exit when length(v) >= length(p_prefix) + 6
      and not exists (select 1 from promo_codes where code = v) and not exists (select 1 from reward_accounts where referral_code = v)
      and not exists (select 1 from owners where upper(referral_code) = v) and not exists (select 1 from staff_profiles where upper(referral_code) = v);
  end loop;
  return v;
end $$;

-- the renter's account (made on first use), with its referral code and the tier's promo code kept in step
create or replace function app.rewards_account(p_renter uuid) returns reward_accounts
language plpgsql security definer set search_path = public, app as $$
declare a reward_accounts;
begin
  select * into a from reward_accounts where renter_id = p_renter;
  if a.renter_id is null then
    insert into reward_accounts (renter_id, referral_code, tier_code) values (p_renter, app.rewards_code('R'), 'member')
    on conflict (renter_id) do nothing;
    select * into a from reward_accounts where renter_id = p_renter;
  end if;
  return a;
end $$;

create or replace function app.rewards_sync_tier(p_renter uuid) returns text
language plpgsql security definer set search_path = public, app as $$
declare
  a reward_accounts := app.rewards_account(p_renter);
  t reward_tiers := app.rewards_tier_of(p_renter);
  pc promo_codes;
  v_id uuid;
begin
  if a.tier_promo_id is not null then select * into pc from promo_codes where id = a.tier_promo_id; end if;
  if a.tier_code is not distinct from t.code and (t.discount_bps = 0 or (pc.id is not null and pc.is_active and pc.percent_bps = t.discount_bps)) then return t.code; end if;
  if pc.id is not null then update promo_codes set is_active = false where id = pc.id and is_active; end if;
  if t.discount_bps > 0 and (app.rewards()).enabled then
    insert into promo_codes (code, description, percent_bps, once_per_renter, renter_id, source)
    values (app.rewards_code(upper(left(t.code, 4))), 'CarmaCars Rewards ' || t.name || ' discount', t.discount_bps, false, p_renter, 'rewards_tier')
    returning id into v_id;
  end if;
  update reward_accounts set tier_code = t.code, tier_promo_id = v_id where renter_id = p_renter;
  return t.code;
end $$;

-- one award; nothing when the way to earn is off, the points are 0 or the source was already used
create or replace function app.rewards_award(p_renter uuid, p_action text, p_source text, p_points integer default null, p_booking uuid default null,
                                             p_reason text default null, p_meta jsonb default '{}'::jsonb, p_days numeric default null) returns integer
language plpgsql security definer set search_path = public, app as $$
declare
  a reward_actions := app.rewards_action(p_action);
  v integer := coalesce(p_points, a.points);
begin
  if p_renter is null or a.code is null or coalesce(v, 0) <= 0 then return 0; end if;
  perform app.rewards_account(p_renter);
  insert into reward_ledger (renter_id, points, kind, action, source_key, booking_id, reason, meta, rental_days)
  values (p_renter, v, 'earn', p_action, p_source, p_booking, coalesce(p_reason, a.label), coalesce(p_meta, '{}'::jsonb), p_days)
  on conflict (source_key) do nothing;
  if not found then return 0; end if;
  if p_action = 'rental' then perform app.rewards_sync_tier(p_renter); end if;
  return v;
end $$;

-- ================================================================ 3. earning when a booking closes (deposit settled)
create or replace function app.rewards_damage_free(b bookings) returns boolean
language sql stable security definer set search_path = public, app as $$
  select not exists (select 1 from incidents i where i.booking_id = b.id)
     and not exists (select 1 from booking_line_items li where li.booking_id = b.id and li.voided_at is null and li.amount_cents > 0
                      and li.charge_type in ('cleaning', 'cleaning_heavy', 'pet_cleaning', 'smoking', 'damage_at_cost', 'deductible', 'loss_of_use',
                                             'late_return_fee', 'late_return_extra_days', 'lost_key_cost', 'lost_key_fee', 'recovery_cost'))
     and (b.checked_in_at is null or b.checked_in_at <= b.return_at + make_interval(mins => (app.rewards()).late_grace_minutes))
$$;

create or replace function app.rewards_on_close(p_booking uuid) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  b bookings;
  s rewards_settings := app.rewards();
  v_net bigint;
  v_days numeric;
  v_first boolean;
  v_ref uuid;
  n jsonb := '{}'::jsonb;
begin
  select * into b from bookings where id = p_booking;
  if b.id is null or b.renter_id is null or b.status <> 'closed' or b.booking_type = 'owner' or not s.enabled then return n; end if;
  v_net := greatest(b.rental_charge_cents - b.discount_cents - b.staff_discount_cents - b.promo_discount_cents, 0);
  v_days := round(greatest(extract(epoch from (b.return_at - b.pickup_at)) / 86400.0, 0)::numeric, 2);
  n := n || jsonb_build_object('rental', app.rewards_award(b.renter_id, 'rental', 'rental:' || b.id,
         floor(v_net / 100.0 * s.points_per_dollar * coalesce((app.rewards_action('rental')).points, 0))::int, b.id,
         'Rental ' || b.booking_number || ' (' || to_char(v_net / 100.0, 'FM$999,999,990.00') || ' after discounts)', '{}'::jsonb, v_days));
  if app.rewards_damage_free(b) then
    n := n || jsonb_build_object('damage_free', app.rewards_award(b.renter_id, 'damage_free', 'damage_free:' || b.id, null, b.id, 'Damage-free rental ' || b.booking_number));
  end if;
  v_first := not exists (select 1 from bookings x where x.renter_id = b.renter_id and x.status = 'closed' and x.id <> b.id and x.booking_type <> 'owner');
  if v_first then
    n := n || jsonb_build_object('first_rental', app.rewards_award(b.renter_id, 'first_rental', 'first_rental:' || b.renter_id, null, b.id, 'First rental ' || b.booking_number));
    if b.referred_by_code is not null then
      select renter_id into v_ref from reward_accounts where referral_code = upper(b.referred_by_code) and renter_id <> b.renter_id;
      if v_ref is not null then
        n := n || jsonb_build_object('referrer', app.rewards_award(v_ref, 'referral_referrer', 'referral_referrer:' || b.renter_id, null, b.id,
                   'A friend you referred completed their first rental', jsonb_build_object('friend_renter_id', b.renter_id)));
        n := n || jsonb_build_object('referred', app.rewards_award(b.renter_id, 'referral_referred', 'referral_referred:' || b.renter_id, null, b.id,
                   'First rental with a friend''s link', jsonb_build_object('referrer_renter_id', v_ref)));
      end if;
    end if;
  end if;
  return n;
end $$;

create or replace function app.rewards_bookings_closed() returns trigger
language plpgsql security definer set search_path = public, app as $$
begin
  if new.status = 'closed' and old.status is distinct from 'closed' then
    begin
      perform app.rewards_on_close(new.id);
    exception when others then
      raise warning 'rewards: booking % not credited: %', new.booking_number, sqlerrm;   -- never stops a booking from closing
    end;
  end if;
  return null;
end $$;
drop trigger if exists bookings_rewards_closed on bookings;
create trigger bookings_rewards_closed after update of status on bookings for each row execute function app.rewards_bookings_closed();

-- a review on carmacars.ca: a rating and some words, for a rental that ended
create or replace function app.rewards_reviews_after() returns trigger
language plpgsql security definer set search_path = public, app as $$
declare v integer;
begin
  if length(btrim(coalesce(new.body, ''))) >= 1 and exists (select 1 from bookings b where b.id = new.booking_id and b.status in ('returned', 'closed')) then
    v := app.rewards_award(new.renter_id, 'review_site', 'review_site:' || new.booking_id, null, new.booking_id, 'Review on carmacars.ca');
    if v > 0 then update reviews set reward_points = true where id = new.id and not reward_points; end if;
  end if;
  return null;
end $$;
drop trigger if exists reviews_rewards on reviews;
create trigger reviews_rewards after insert or update of body on reviews for each row execute function app.rewards_reviews_after();

-- ================================================================ 4. the renter
create or replace function app.rewards_renter_of(p_user uuid) returns uuid
language sql stable security definer set search_path = public, app as $$
  select r.id from renters r where r.user_id = p_user and r.merged_into is null order by r.created_at limit 1
$$;

create or replace function app.rewards_social_url(p_platform text) returns text
language sql stable security definer set search_path = public, app as $$
  select nullif(btrim(coalesce(s.social_links ->> p_platform, '')), '') from site_settings s limit 1
$$;

create or replace function app.rewards_state(p_renter uuid) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  s rewards_settings := app.rewards();
  a reward_accounts;
  t reward_tiers;
  nt reward_tiers;
  v_bal integer;
  v_last timestamptz;
  v_site text := rtrim(coalesce((select nullif(site_url, '') from site_settings limit 1), (app.settings()).notify_base_url), '/');
  v_google text := (select nullif(btrim(coalesce(google_review_link, '')), '') from site_settings limit 1);
  v_days numeric;
begin
  if p_renter is null then return jsonb_build_object('enabled', s.enabled, 'renter', false); end if;
  perform app.rewards_sync_tier(p_renter);
  a := app.rewards_account(p_renter);
  t := app.rewards_tier_of(p_renter);
  v_days := app.rewards_days_12m(p_renter);
  select * into nt from reward_tiers where min_days > v_days order by min_days limit 1;
  v_bal := app.rewards_balance(p_renter);
  v_last := app.rewards_last_activity(p_renter);
  return jsonb_build_object('enabled', s.enabled, 'renter', true, 'balance', v_bal,
    'value_cents', floor(greatest(v_bal, 0) * s.point_value_cents)::bigint, 'point_value_cents', s.point_value_cents, 'min_redeem', s.min_redeem_points,
    'code_valid_days', s.code_valid_days, 'expiry_months', s.expiry_months,
    'expires_on', case when v_bal > 0 and v_last is not null then app.local_date(v_last + make_interval(months => s.expiry_months)) end,
    'rental_days_12m', v_days,
    'tier', jsonb_build_object('code', t.code, 'name', t.name, 'discount_bps', t.discount_bps, 'perk', t.perk,
                               'promo_code', (select code from promo_codes where id = a.tier_promo_id and is_active)),
    'next_tier', case when nt.code is not null then jsonb_build_object('name', nt.name, 'days_needed', greatest(nt.min_days - v_days, 0), 'discount_bps', nt.discount_bps) end,
    'tiers', (select jsonb_agg(jsonb_build_object('code', x.code, 'name', x.name, 'min_days', x.min_days, 'discount_bps', x.discount_bps, 'perk', x.perk) order by x.min_days) from reward_tiers x),
    'referral_code', a.referral_code, 'referral_url', v_site || '/r/' || a.referral_code,
    'actions', (select coalesce(jsonb_agg(jsonb_build_object('code', x.code, 'label', x.label, 'detail', x.detail, 'points', x.points, 'limit', x.limit_text) order by x.sort), '[]'::jsonb)
                  from reward_actions x where x.enabled and (x.code <> 'review_google' or v_google is not null)
                   and (x.code not like 'social\_%' or app.rewards_social_url(substr(x.code, 8)) is not null)),
    'socials', (select coalesce(jsonb_agg(jsonb_build_object('platform', substr(x.code, 8), 'label', x.label, 'points', x.points,
                   'done', exists (select 1 from reward_ledger l where l.source_key = 'social:' || substr(x.code, 8) || ':' || p_renter))), '[]'::jsonb)
                  from reward_actions x where x.enabled and x.code like 'social\_%' and app.rewards_social_url(substr(x.code, 8)) is not null),
    'google', case when v_google is not null and (app.rewards_action('review_google')).code is not null then jsonb_build_object('url', v_google, 'points', (app.rewards_action('review_google')).points,
                'bookings', (select coalesce(jsonb_agg(jsonb_build_object('number', b.booking_number, 'vehicle', app.vehicle_name(b.vehicle_id), 'returned', app.local_date(b.return_at),
                               'claimed', exists (select 1 from reward_ledger l where l.source_key = 'review_google:' || b.id)) order by b.return_at desc), '[]'::jsonb)
                             from bookings b where b.renter_id = p_renter and b.status in ('returned', 'closed') and b.booking_type <> 'owner' and b.return_at > now() - interval '12 months')) end,
    'site_reviews', (select coalesce(jsonb_agg(jsonb_build_object('number', b.booking_number, 'vehicle', app.vehicle_name(b.vehicle_id),
                       'reviewed', exists (select 1 from reviews r where r.booking_id = b.id)) order by b.return_at desc), '[]'::jsonb)
                     from bookings b where b.renter_id = p_renter and b.status in ('returned', 'closed') and b.booking_type <> 'owner' and b.return_at > now() - interval '12 months'
                       and (app.rewards_action('review_site')).code is not null),
    'codes', (select coalesce(jsonb_agg(jsonb_build_object('id', p.id, 'code', p.code, 'amount_cents', p.amount_cents, 'valid_until', app.local_date(p.valid_until),
                 'in_use', exists (select 1 from promo_redemptions r where r.promo_code_id = p.id and r.status in ('applied', 'redeemed')),
                 'used', exists (select 1 from promo_redemptions r where r.promo_code_id = p.id and r.status = 'redeemed')) order by p.created_at desc), '[]'::jsonb)
               from promo_codes p where p.renter_id = p_renter and p.source = 'rewards' and p.is_active and (p.valid_until is null or p.valid_until > now() - interval '30 days')),
    'ledger', (select coalesce(jsonb_agg(jsonb_build_object('at', l.created_at, 'points', l.points, 'kind', l.kind, 'reason', l.reason, 'reversed', l.reversed_at is not null) order by l.created_at desc), '[]'::jsonb)
                 from (select * from reward_ledger where renter_id = p_renter order by created_at desc limit 60) l));
end $$;

create or replace function public.my_rewards() returns jsonb
language sql security definer set search_path = public, app as $$
  select app.rewards_state(app.rewards_renter_of(app.uid()))
$$;

-- redeem: points become a one-time code of the renter's own, entered as a promo code
create or replace function app.rewards_redeem(p_renter uuid, p_points integer) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  s rewards_settings := app.rewards();
  v_bal integer;
  v_id uuid;
  v_code text;
  v_cents bigint;
begin
  if not s.enabled then raise exception 'Rewards are off' using errcode = '22023'; end if;
  if p_renter is null then raise exception 'Sign in as a renter' using errcode = '42501'; end if;
  perform 1 from reward_accounts where renter_id = p_renter for update;
  v_bal := app.rewards_balance(p_renter);
  if p_points is null or p_points < s.min_redeem_points then raise exception 'Redeem at least % points', s.min_redeem_points using errcode = '22023'; end if;
  if p_points > v_bal then raise exception 'You have % points', v_bal using errcode = '22023'; end if;
  v_cents := floor(p_points * s.point_value_cents)::bigint;
  if v_cents < 1 then raise exception 'That is worth less than a cent' using errcode = '22023'; end if;
  v_code := app.rewards_code('PTS');
  insert into promo_codes (code, description, amount_cents, valid_until, max_uses, once_per_renter, renter_id, source)
  values (v_code, 'CarmaCars Rewards: ' || p_points || ' points', v_cents, now() + make_interval(days => s.code_valid_days), 1, true, p_renter, 'rewards')
  returning id into v_id;
  insert into reward_ledger (renter_id, points, kind, action, source_key, promo_code_id, reason)
  values (p_renter, -p_points, 'redeem', 'redeem', 'redeem:' || v_id, v_id, 'Redeemed for code ' || v_code || ' (' || to_char(v_cents / 100.0, 'FM$999,990.00') || ' off the rental charge)');
  return jsonb_build_object('code', v_code, 'amount_cents', v_cents, 'valid_until', app.local_date(now() + make_interval(days => s.code_valid_days)));
end $$;

create or replace function public.rewards_mine_redeem(p_points integer) returns jsonb
language sql security definer set search_path = public, app as $$ select app.rewards_redeem(app.rewards_renter_of(app.uid()), p_points) $$;

-- an unused code given back for its points (the renter, or the job when it ends)
create or replace function app.rewards_code_refund(p_promo uuid, p_why text) returns integer
language plpgsql security definer set search_path = public, app as $$
declare
  l reward_ledger;
begin
  select * into l from reward_ledger where promo_code_id = p_promo and kind = 'redeem';
  if l.id is null then return 0; end if;
  if exists (select 1 from promo_redemptions r where r.promo_code_id = p_promo and r.status in ('applied', 'redeemed')) then
    raise exception 'The code is on a booking' using errcode = '22023';
  end if;
  update promo_codes set is_active = false where id = p_promo and is_active;
  insert into reward_ledger (renter_id, points, kind, action, source_key, promo_code_id, reason)
  values (l.renter_id, -l.points, 'refund', 'redeem', 'refund:' || p_promo, p_promo, p_why)
  on conflict (source_key) do nothing;
  return case when found then -l.points else 0 end;
end $$;

create or replace function public.rewards_mine_code_cancel(p_code text) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  v_renter uuid := app.rewards_renter_of(app.uid());
  p promo_codes;
begin
  select * into p from promo_codes where code = upper(btrim(coalesce(p_code, ''))) and renter_id = v_renter and source = 'rewards';
  if p.id is null then raise exception 'Code not found' using errcode = 'P0002'; end if;
  return jsonb_build_object('points', app.rewards_code_refund(p.id, 'Code ' || p.code || ' cancelled: points back'));
end $$;

-- a follow: points on the click (it cannot be checked); returns the page to open
create or replace function public.rewards_mine_social(p_platform text) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  v_renter uuid := app.rewards_renter_of(app.uid());
  v_url text;
  v integer := 0;
begin
  if p_platform not in ('instagram', 'tiktok', 'facebook') then raise exception 'Unknown platform' using errcode = '22023'; end if;
  v_url := app.rewards_social_url(p_platform);
  if v_url is null then raise exception 'No % page on file', p_platform using errcode = 'P0002'; end if;
  if v_renter is not null then
    v := app.rewards_award(v_renter, 'social_' || p_platform, 'social:' || p_platform || ':' || v_renter, null, null, 'Followed CarmaCars on ' || initcap(p_platform));
  end if;
  return jsonb_build_object('url', v_url, 'points', v);
end $$;

-- a Google review, on the renter's word: once per ended rental, whatever the rating
create or replace function public.rewards_mine_google_claim(p_number text, p_name text) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  v_renter uuid := app.rewards_renter_of(app.uid());
  b bookings;
  v_name text := btrim(coalesce(p_name, ''));
  v integer;
begin
  if (select nullif(btrim(coalesce(google_review_link, '')), '') from site_settings limit 1) is null or (app.rewards_action('review_google')).code is null then
    raise exception 'Google review points are off' using errcode = '22023'; end if;
  if length(v_name) < 2 or length(v_name) > 80 then raise exception 'Enter the name shown on your review' using errcode = '22023'; end if;
  select * into b from bookings where booking_number = p_number and renter_id = v_renter;
  if b.id is null then raise exception 'Booking not found' using errcode = 'P0002'; end if;
  if b.status not in ('returned', 'closed') then raise exception 'Points for a review come after the rental' using errcode = '22023'; end if;
  v := app.rewards_award(v_renter, 'review_google', 'review_google:' || b.id, null, b.id, 'Google review for ' || b.booking_number || ' (as ' || v_name || ')',
                         jsonb_build_object('review_name', v_name));
  if v = 0 then raise exception 'Points for this rental''s Google review were already given' using errcode = '23505'; end if;
  return jsonb_build_object('points', v);
end $$;

-- ================================================================ 5. the job: birthdays, ended codes, expiry and its reminder
create or replace function app.job_rewards() returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  s rewards_settings := app.rewards();
  r record;
  v_today date := app.today();
  n_b int := 0; n_r int := 0; n_e int := 0; n_m int := 0;
begin
  if not s.enabled then return jsonb_build_object('enabled', false); end if;
  -- birthdays (29 February on 28 February in other years), for renters with an account
  for r in select x.id from renters x where x.date_of_birth is not null and x.user_id is not null and not coalesce(x.is_blocked, false) and x.merged_into is null
             and (to_char(x.date_of_birth, 'MM-DD') = to_char(v_today, 'MM-DD')
                  or (to_char(x.date_of_birth, 'MM-DD') = '02-29' and to_char(v_today, 'MM-DD') = '02-28'
                      and extract(day from make_date(extract(year from v_today)::int, 3, 1) - 1) = 28)) loop
    n_b := n_b + sign(app.rewards_award(r.id, 'birthday', 'birthday:' || r.id || ':' || extract(year from v_today), null, null, 'Happy birthday'))::int;
  end loop;
  -- unused codes that ended give the points back
  for r in select p.id, p.code from promo_codes p where p.source = 'rewards' and p.valid_until < now()
             and exists (select 1 from reward_ledger l where l.promo_code_id = p.id and l.kind = 'redeem')
             and not exists (select 1 from reward_ledger l where l.source_key = 'refund:' || p.id)
             and not exists (select 1 from promo_redemptions x where x.promo_code_id = p.id and x.status in ('applied', 'redeemed')) loop
    n_r := n_r + sign(app.rewards_code_refund(r.id, 'Code ' || r.code || ' ended unused: points back'))::int;
  end loop;
  -- expiry and its reminder
  for r in select x.renter_id, app.rewards_balance(x.renter_id) bal, app.rewards_last_activity(x.renter_id) last, x.reminded_for from reward_accounts x loop
    continue when r.bal <= 0 or r.last is null;
    if r.last + make_interval(months => s.expiry_months) <= now() then
      insert into reward_ledger (renter_id, points, kind, action, source_key, reason)
      values (r.renter_id, -r.bal, 'expire', 'expire', 'expire:' || r.renter_id || ':' || extract(epoch from r.last)::bigint,
              'Points ended: no rental or redemption in ' || s.expiry_months || ' months')
      on conflict (source_key) do nothing;
      n_e := n_e + 1;
    elsif r.last + make_interval(months => s.expiry_months) - make_interval(days => s.reminder_days) <= now() and r.reminded_for is distinct from r.last then
      perform app.emit_event('renter_rewards_expiring', 'renter', r.renter_id,
        jsonb_build_object('renter_id', r.renter_id, 'points_balance', to_char(r.bal, 'FM999,999,990'),
          'points_value', to_char(floor(r.bal * s.point_value_cents) / 100.0, 'FM$999,999,990.00'),
          'expiry_date', to_char(app.local_date(r.last + make_interval(months => s.expiry_months)), 'Dy, Mon FMDD, YYYY'),
          'rewards_url', rtrim((app.settings()).notify_base_url, '/') || '/account/rewards'),
        'renter_rewards_expiring:' || r.renter_id || ':' || extract(epoch from r.last)::bigint);
      update reward_accounts set reminded_for = r.last where renter_id = r.renter_id;
      n_m := n_m + 1;
    end if;
  end loop;
  return jsonb_build_object('birthdays', n_b, 'refunds', n_r, 'expired', n_e, 'reminded', n_m);
end $$;

do $$
begin
  if to_regclass('cron.job') is not null then
    perform cron.schedule('carmacars-rewards', '41 * * * *', $q$select app.job_rewards()$q$);
  end if;
end $$;

-- the email's values: the event's payload (the renter's name comes from the recipient)
alter function app.notification_payload(text, app_events, jsonb) rename to ntf_payload_pre0214;
create function app.notification_payload(p_code text, p_event app_events, p_to jsonb) returns jsonb
language plpgsql stable security definer set search_path = public, app as $$
declare x jsonb := app.ntf_payload_pre0214(p_code, p_event, p_to);
begin
  if p_code = 'renter_rewards_expiring' then
    x := coalesce(x, '{}'::jsonb) || (coalesce(p_event.payload, '{}'::jsonb) - 'renter_id');
  end if;
  return x;
end $$;
select pg_temp.copy_grants('app.notification_payload(text, app_events, jsonb)'::regprocedure, 'app.ntf_payload_pre0214(text, app_events, jsonb)'::regprocedure);

-- low priority: these follow-ups wait behind customer, owner and staff emails under the daily cap
create table if not exists notification_low_priority (code text primary key, priority smallint not null check (priority between 4 and 5));
comment on table notification_low_priority is 'Codes app.notification_catalogue_refresh keeps at a low priority class (0214): reminders and follow-ups that may wait for the next day under the 100-a-day email cap.';
insert into notification_low_priority values ('renter_rewards_expiring', 4) on conflict (code) do nothing;
alter function app.notification_catalogue_refresh() rename to notification_catalogue_refresh_pre0214;
create function app.notification_catalogue_refresh() returns integer
language plpgsql security definer set search_path = public, app as $$
declare n integer := app.notification_catalogue_refresh_pre0214();
begin
  update notification_catalogue c set priority = l.priority from notification_low_priority l where l.code = c.code and c.priority <> l.priority;
  -- the express-consent emails (0161, 0167): the refresh of 0062 would set them back to implied (0211 did)
  update notification_catalogue set consent_rule = 'express' where code in ('renter_promo_expiry_3d', 'renter_promo_expiry_1d', 'owner_recruit_outreach') and consent_rule is distinct from 'express';
  return n;
end $$;

-- ================================================================ 6. Admin
create or replace function app.rewards_admin_read(p_by uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  s rewards_settings := app.rewards();
begin
  perform app.assert_admin(p_by);
  return jsonb_build_object('settings', to_jsonb(s) - 'singleton',
    'google_review_link', (select google_review_link from site_settings limit 1), 'social_links', (select social_links from site_settings limit 1),
    'actions', (select coalesce(jsonb_agg(to_jsonb(a) order by a.sort), '[]'::jsonb) from reward_actions a),
    'tiers', (select coalesce(jsonb_agg(to_jsonb(t) order by t.min_days), '[]'::jsonb) from reward_tiers t),
    'totals', (select jsonb_build_object('members', (select count(*) from reward_accounts), 'outstanding', coalesce(sum(points), 0),
                 'earned_30d', coalesce(sum(points) filter (where kind = 'earn' and created_at > now() - interval '30 days'), 0),
                 'redeemed_30d', coalesce(-sum(points) filter (where kind = 'redeem' and created_at > now() - interval '30 days'), 0)) from reward_ledger),
    'google_claims', (select coalesce(jsonb_agg(jsonb_build_object('id', l.id, 'at', l.created_at, 'renter', r.legal_name, 'renter_id', r.id, 'booking_number', b.booking_number,
                        'review_name', l.meta ->> 'review_name', 'points', l.points, 'reversed', l.reversed_at is not null) order by l.created_at desc), '[]'::jsonb)
                      from (select * from reward_ledger where action = 'review_google' and kind = 'earn' order by created_at desc limit 200) l
                      join renters r on r.id = l.renter_id left join bookings b on b.id = l.booking_id),
    'recent', (select coalesce(jsonb_agg(jsonb_build_object('id', l.id, 'at', l.created_at, 'renter', r.legal_name, 'renter_id', r.id, 'points', l.points, 'kind', l.kind,
                  'action', l.action, 'reason', l.reason, 'reversed', l.reversed_at is not null) order by l.created_at desc), '[]'::jsonb)
               from (select * from reward_ledger where (nullif(p ->> 'renter', '') is null or renter_id = (p ->> 'renter')::uuid) order by created_at desc limit 100) l
               join renters r on r.id = l.renter_id),
    'matches', case when length(btrim(coalesce(p ->> 'q', ''))) >= 2 then (select coalesce(jsonb_agg(jsonb_build_object('id', r.id, 'name', r.legal_name, 'email', r.email,
                   'balance', app.rewards_balance(r.id)) order by r.legal_name), '[]'::jsonb)
                 from (select * from renters x where x.merged_into is null and strpos(lower(concat_ws(' ', x.legal_name, x.email, x.mobile)), lower(btrim(p ->> 'q'))) > 0 limit 10) r) end,
    'renter', case when nullif(p ->> 'renter', '') is not null then app.rewards_state((p ->> 'renter')::uuid)
                     || jsonb_build_object('id', p ->> 'renter', 'name', (select legal_name from renters where id = (p ->> 'renter')::uuid)) end);
end $$;

create or replace function app.rewards_admin_do(p_by uuid, p_name text, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  l reward_ledger;
  v_reason text := nullif(btrim(coalesce(p ->> 'reason', '')), '');
  v_pts integer;
  v_renter uuid;
begin
  perform app.assert_admin(p_by);
  if p_name = 'rewards_settings_save' then
    update rewards_settings set enabled = coalesce((p ->> 'enabled')::boolean, enabled), points_per_dollar = coalesce((p ->> 'points_per_dollar')::numeric, points_per_dollar),
           point_value_cents = coalesce((p ->> 'point_value_cents')::numeric, point_value_cents), min_redeem_points = coalesce((p ->> 'min_redeem_points')::int, min_redeem_points),
           code_valid_days = coalesce((p ->> 'code_valid_days')::int, code_valid_days), expiry_months = coalesce((p ->> 'expiry_months')::int, expiry_months),
           reminder_days = coalesce((p ->> 'reminder_days')::int, reminder_days), late_grace_minutes = coalesce((p ->> 'late_grace_minutes')::int, late_grace_minutes),
           updated_by = p_by, updated_at = now() where singleton;
    if p ? 'google_review_link' then
      if nullif(btrim(p ->> 'google_review_link'), '') is not null and btrim(p ->> 'google_review_link') !~ '^https://[^[:space:]]+$' then
        raise exception 'The Google review link starts with https://' using errcode = '22023'; end if;
      update site_settings set google_review_link = nullif(btrim(p ->> 'google_review_link'), '') where singleton;
    end if;
    insert into audit_log (actor_user_id, action, entity_table, entity_id, after) values (p_by, p_name, 'rewards_settings', 'singleton', p);
    return to_jsonb(app.rewards()) - 'singleton';
  elsif p_name = 'rewards_action_save' then
    update reward_actions set points = coalesce((p ->> 'points')::int, points), enabled = coalesce((p ->> 'enabled')::boolean, enabled),
           label = coalesce(nullif(btrim(p ->> 'label'), ''), label), limit_text = coalesce(nullif(btrim(p ->> 'limit_text'), ''), limit_text), updated_at = now()
     where code = p ->> 'code';
    if not found then raise exception 'Unknown way to earn' using errcode = 'P0002'; end if;
    insert into audit_log (actor_user_id, action, entity_table, entity_id, after) values (p_by, p_name, 'reward_actions', p ->> 'code', p);
    return (select to_jsonb(a) from reward_actions a where code = p ->> 'code');
  elsif p_name = 'rewards_tier_save' then
    update reward_tiers set name = coalesce(nullif(btrim(p ->> 'name'), ''), name), min_days = coalesce((p ->> 'min_days')::int, min_days),
           discount_bps = coalesce((p ->> 'discount_bps')::int, discount_bps), perk = case when p ? 'perk' then nullif(btrim(p ->> 'perk'), '') else perk end
     where code = p ->> 'code';
    if not found then raise exception 'Unknown tier' using errcode = 'P0002'; end if;
    if (select min(min_days) from reward_tiers) <> 0 then raise exception 'The first tier starts at 0 days' using errcode = '22023'; end if;
    insert into audit_log (actor_user_id, action, entity_table, entity_id, after) values (p_by, p_name, 'reward_tiers', p ->> 'code', p);
    perform app.rewards_sync_tier(renter_id) from reward_accounts;
    return (select to_jsonb(t) from reward_tiers t where code = p ->> 'code');
  elsif p_name = 'rewards_adjust' then
    v_renter := nullif(p ->> 'renter', '')::uuid;
    v_pts := (p ->> 'points')::int;
    if v_renter is null or not exists (select 1 from renters where id = v_renter) then raise exception 'Choose the renter' using errcode = '22023'; end if;
    if v_pts is null or v_pts = 0 then raise exception 'Enter the points to add (or a minus to take off)' using errcode = '22023'; end if;
    if v_reason is null then raise exception 'Write the reason (the renter sees it)' using errcode = '22023'; end if;
    if app.rewards_balance(v_renter) + v_pts < 0 then raise exception 'That takes the balance below zero' using errcode = '22023'; end if;
    perform app.rewards_account(v_renter);
    insert into reward_ledger (renter_id, points, kind, action, source_key, reason, created_by)
    values (v_renter, v_pts, 'adjust', 'adjust', 'adjust:' || gen_random_uuid(), v_reason, p_by) returning * into l;
    insert into audit_log (actor_user_id, action, entity_table, entity_id, after) values (p_by, p_name, 'reward_ledger', l.id::text, to_jsonb(l));
    return jsonb_build_object('id', l.id, 'balance', app.rewards_balance(v_renter));
  elsif p_name = 'rewards_reverse' then
    if v_reason is null then raise exception 'Write the reason (for example: referral fraud)' using errcode = '22023'; end if;
    select * into l from reward_ledger where id = nullif(p ->> 'id', '')::uuid for update;
    if l.id is null then raise exception 'Entry not found' using errcode = 'P0002'; end if;
    if l.kind <> 'earn' and l.kind <> 'adjust' then raise exception 'Only points earned or added can be reversed' using errcode = '22023'; end if;
    if l.reversed_at is not null then raise exception 'Already reversed' using errcode = '23505'; end if;
    update reward_ledger set reversed_at = now() where id = l.id;
    insert into reward_ledger (renter_id, points, kind, action, source_key, booking_id, reason, created_by, meta)
    values (l.renter_id, -l.points, 'reverse', l.action, 'reverse:' || l.id, l.booking_id, 'Reversed: ' || v_reason, p_by, jsonb_build_object('entry', l.id));
    if l.action = 'review_site' then update reviews set reward_points = false where booking_id = l.booking_id and reward_points; end if;
    if l.action = 'rental' then perform app.rewards_sync_tier(l.renter_id); end if;
    insert into audit_log (actor_user_id, action, entity_table, entity_id, after) values (p_by, p_name, 'reward_ledger', l.id::text, jsonb_build_object('reason', v_reason));
    return jsonb_build_object('reversed', l.id, 'balance', app.rewards_balance(l.renter_id));
  end if;
  raise exception 'Unknown rewards call %', p_name using errcode = '22023';
end $$;

alter function app.door(uuid, text, text, text, jsonb) rename to door_pre0214;
create function app.door(p_user uuid, p_aal text, p_call text, p_name text, p jsonb default '{}'::jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
begin
  if p_call = 'admin_read' and p_name = 'rewards' then
    perform app.door_begin(p_user, p_aal);
    return app.rewards_admin_read(p_user, coalesce(p, '{}'::jsonb) - '_va');
  end if;
  if p_call = 'admin_do' and p_name in ('rewards_settings_save', 'rewards_action_save', 'rewards_tier_save', 'rewards_adjust', 'rewards_reverse') then
    perform app.door_begin(p_user, p_aal);
    return app.rewards_admin_do(p_user, p_name, coalesce(p, '{}'::jsonb) - '_va');
  end if;
  return app.door_pre0214(p_user, p_aal, p_call, p_name, p);
end $$;
select pg_temp.copy_grants('app.door(uuid, text, text, text, jsonb)'::regprocedure, 'app.door_pre0214(uuid, text, text, text, jsonb)'::regprocedure);

-- the car page: a review that earned points says so ("Received reward points")
create or replace function app.public_car_reviews(p_vehicle uuid) returns jsonb
language sql stable security definer set search_path = public, app as $$
  select jsonb_build_object(
    'count', (select count(*) from reviews r where r.vehicle_id = p_vehicle and r.status = 'published'),
    'average', (select round(avg(r.rating)::numeric, 1) from reviews r where r.vehicle_id = p_vehicle and r.status = 'published'),
    'min_for_rating', (app.settings()).seo_rating_min_reviews,
    'items', (select coalesce(jsonb_agg(jsonb_build_object('rating', x.rating, 'title', x.title, 'body', x.body, 'name', x.reviewer_first_name,
                                                          'month', x.review_month, 'reply', x.staff_reply,
                                                          'rewarded', coalesce((select rv.reward_points from reviews rv where rv.id = x.review_id), false))), '[]'::jsonb)
                from app.public_reviews(p_vehicle, 20, 0) x))
$$;

-- ================================================================ 7. privileges
do $$
declare t text;
begin
  foreach t in array array['rewards_settings', 'reward_tiers', 'reward_actions', 'reward_accounts', 'reward_ledger', 'notification_low_priority'] loop
    execute format('alter table %I enable row level security', t);
    execute format('revoke all on %I from anon, authenticated', t);
    execute format('grant all on %I to service_role', t);
    execute format('drop policy if exists admin_all on %I', t);
    execute format('create policy admin_all on %I for all to authenticated using (app.is_admin()) with check (app.is_admin())', t);
    execute format('drop trigger if exists %I on %I', 'audit_' || t, t);
    execute format('create trigger %I after insert or update or delete on %I for each row execute function app.audit_row()', 'audit_' || t, t);
  end loop;
end $$;

do $$
declare f record;
begin
  for f in select p.oid::regprocedure as sig, p.proname from pg_proc p join pg_namespace n on n.oid = p.pronamespace
            where (n.nspname = 'app' and (p.proname like 'rewards%' or p.proname in ('job_rewards', 'door_pre0214', 'ntf_payload_pre0214', 'notification_catalogue_refresh_pre0214', 'notification_catalogue_refresh')))
               or (n.nspname = 'public' and (p.proname like 'my\_rewards%' or p.proname like 'rewards\_mine\_%')) loop
    execute format('revoke all on function %s from public, anon, authenticated', f.sig);
    execute format('grant execute on function %s to service_role', f.sig);
    if f.proname like 'my\_rewards%' or f.proname like 'rewards\_mine\_%' then execute format('grant execute on function %s to authenticated', f.sig); end if;
  end loop;
end $$;

-- CATALOGUE 0214 START (generated by supabase/seed/0214_gen_catalogue.mjs; do not edit by hand)
insert into notification_catalogue (code, audience, also_sent_to, category, is_digest, digest_slot, from_address, reply_to,
    subject, preheader, timing, trigger_text, replaces_template, link_path, variables, template_html, template_text) values
  ('renter_rewards_expiring', 'renter', '{}'::text[], 'transactional', false, null, 'CarmaCars <hello@carmacars.ca>', 'contact@carmacars.ca', 'Your {{points_balance}} CarmaCars points end on {{expiry_date}}', 'Worth {{points_value}} off a rental. Rent or redeem before then to keep them.', 'About 30 days before the points end', 'CarmaCars Rewards job (hourly, migration 0214): a renter has points and no rental or redemption for the expiry period less the reminder days (Admin > Settings > Rewards: 12 months and 30 days by default). One email per period of activity. Low priority (class 4): it waits behind customer, owner and staff emails under the daily email cap.', null, null, '[{"name":"company_address","type":"string","global":true},{"name":"contact_email","type":"string","global":true},{"name":"expiry_date","type":"string"},{"name":"first_name","type":"string"},{"name":"instagram_url","type":"url","global":true},{"name":"opening_hours","type":"string","global":true},{"name":"points_balance","type":"string"},{"name":"points_value","type":"string"},{"name":"reply_time","type":"string","global":true},{"name":"rewards_url","type":"url"},{"name":"support_phone","type":"string","global":true},{"name":"tiktok_url","type":"url","global":true}]'::jsonb, 'templates/renter_rewards_expiring.html', 'templates/renter_rewards_expiring.txt')
on conflict (code) do update set
  audience = excluded.audience, also_sent_to = excluded.also_sent_to, category = excluded.category,
  is_digest = excluded.is_digest, digest_slot = excluded.digest_slot, from_address = excluded.from_address,
  reply_to = excluded.reply_to, subject = excluded.subject, preheader = excluded.preheader, timing = excluded.timing,
  trigger_text = excluded.trigger_text, replaces_template = excluded.replaces_template, link_path = excluded.link_path,
  variables = excluded.variables, template_html = excluded.template_html, template_text = excluded.template_text,
  in_catalogue = true, updated_at = now();
select app.notification_catalogue_refresh();
-- CATALOGUE 0214 END
update notification_catalogue set emitted_by = 'app.job_rewards (0214)' where code = 'renter_rewards_expiring';
update notification_catalogue set emitted_by = 'app.hiring_release_waiting (0211)' where code = 'applicant_new_times' and emitted_by is null;
select app.notification_catalogue_refresh();
-- its text, for a renter who chose texts (0096)
update notification_catalogue set link_path = '/account/rewards' where code = 'renter_rewards_expiring' and link_path is null;
insert into sms_templates (code, label, body, enabled, urgent, sort_order)
values ('renter_rewards_expiring', 'Rewards points ending', 'CarmaCars: your {{points_balance}} reward points end on {{expiry_date}}. Rent or redeem to keep them: {{link}}', true, false,
        coalesce((select max(sort_order) + 1 from sms_templates), 1))
on conflict (code) do nothing;
