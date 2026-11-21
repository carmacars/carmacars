-- 3262_r48rw_owner_rewards.sql
-- Release 48, part RW: owner rewards (docs/changes/2026-11-20-r48-rewards-calendar-notify.md). The owner, Nov 20
-- 12:54 and 12:57: an owner portal "Rewards" tab with progress, codes and history.
--   Fleet discount     20% off any other CarmaCars car while the owner's own car is not available (on rent, in service,
--                      in a claim). Never on exotic or partner cars. Down for a repair CarmaCars caused: the owner asks
--                      for a free upgrade, an Admin approves it (a one-time code for the difference).
--   Friends and family the owner's own code, link and QR: 10% off a friend's first rental, and the owner earns the
--                      existing 20% kickback on it (0007: referral_kickbacks, on the statement).
--   Refer an owner     a $100 credit once the referred owner's car has been live for 30 days.
--   Milestones         6 months: a merch kit; 12 months: a premium merch kit. Never automatic: the owner presses
--                      Redeem, confirms the address, the Admins get a To do to ship it, and the reward shows Shipped.
--   Birthday           a $25 rental credit. Also: priority support and early access to new programs.
--   Money              a credit is a line on the owner's statement (owner_credits, kind reward_credit) and every reward is
--                      posted to the books (company_expenses, category owner_reward, account 5310). Discounts come out of
--                      CarmaCars' share, never the other owner's payout (promo_codes.company_funded). The 30% management
--                      fee and the statements are otherwise unchanged.
-- Every number is a Program settings column (owner_reward_*). Rewards are for owners in the program (not partner
-- rental companies, not CarmaCars' own cars).
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

-- ================================================================ settings
alter table program_settings
  add column if not exists owner_reward_enabled boolean not null default true,
  add column if not exists owner_reward_fleet_bps integer not null default 2000 check (owner_reward_fleet_bps between 0 and 10000),
  add column if not exists owner_reward_ff_bps integer not null default 1000 check (owner_reward_ff_bps between 0 and 10000),
  add column if not exists owner_reward_refer_cents bigint not null default 10000 check (owner_reward_refer_cents >= 0),
  add column if not exists owner_reward_refer_live_days integer not null default 30 check (owner_reward_refer_live_days between 0 and 365),
  add column if not exists owner_reward_merch_months integer not null default 6 check (owner_reward_merch_months between 1 and 120),
  add column if not exists owner_reward_merch_premium_months integer not null default 12 check (owner_reward_merch_premium_months between 1 and 120),
  add column if not exists owner_reward_merch_cost_cents bigint not null default 4000 check (owner_reward_merch_cost_cents >= 0),
  add column if not exists owner_reward_merch_premium_cost_cents bigint not null default 9000 check (owner_reward_merch_premium_cost_cents >= 0),
  add column if not exists owner_reward_birthday_cents bigint not null default 2500 check (owner_reward_birthday_cents >= 0),
  add column if not exists owner_reward_birthday_valid_days integer not null default 60 check (owner_reward_birthday_valid_days between 7 and 365),
  add column if not exists owner_reward_upgrade_default_cents bigint not null default 5000 check (owner_reward_upgrade_default_cents >= 0);
comment on column program_settings.owner_reward_enabled is 'Owner rewards (3262): on or off for every owner.';
comment on column program_settings.owner_reward_fleet_bps is 'Owner rewards (3262): the discount on another CarmaCars car while the owner''s own car is not available (2000 = 20%).';
comment on column program_settings.owner_reward_ff_bps is 'Owner rewards (3262): what a friend gets off a first rental with an owner''s code (1000 = 10%). The owner''s kickback is the Kickback Rate (kickback_bps).';
comment on column program_settings.owner_reward_refer_cents is 'Owner rewards (3262): the credit for referring an owner, once their car has been live for owner_reward_refer_live_days.';
comment on column program_settings.owner_reward_refer_live_days is 'Owner rewards (3262): days the referred owner''s car must have been live.';
comment on column program_settings.owner_reward_merch_months is 'Owner rewards (3262): months in the program for the merch kit.';
comment on column program_settings.owner_reward_merch_premium_months is 'Owner rewards (3262): months in the program for the premium merch kit.';
comment on column program_settings.owner_reward_merch_cost_cents is 'Owner rewards (3262): what a merch kit costs CarmaCars, offered as the amount to post when it ships.';
comment on column program_settings.owner_reward_merch_premium_cost_cents is 'Owner rewards (3262): what a premium merch kit costs CarmaCars.';
comment on column program_settings.owner_reward_birthday_cents is 'Owner rewards (3262): the birthday rental credit.';
comment on column program_settings.owner_reward_birthday_valid_days is 'Owner rewards (3262): days the birthday credit can be used.';
comment on column program_settings.owner_reward_upgrade_default_cents is 'Owner rewards (3262): the amount offered when an Admin approves a free upgrade (the price difference CarmaCars covers).';

alter table owner_credits drop constraint owner_credits_kind_check;
alter table owner_credits add constraint owner_credits_kind_check
  check (kind = any (array['later_rental_revenue', 'correction', 'staff_commission_adjustment', 'flat_monthly', 'claim_profit_share', 'write_off_share', 'reward_credit']));

insert into staff_alert_rules (rule, label, grp, who, tier, topic, wired, fixed, hint, sort, pref_type) values
  ('owner_merch_to_ship', 'An owner redeemed a merch kit: ship it', 'Owners', '{admin}', 'normal', 'alerts', true, false, 'Owner rewards (3262): the address is on Owner rewards. Mark it shipped there.', 185, 'staff_system'),
  ('owner_upgrade_request', 'An owner asks for a free upgrade', 'Owners', '{admin}', 'normal', 'requests', true, false, 'Owner rewards (3262): their car is down for a repair they say CarmaCars caused. Approve or decline on Owner rewards.', 186, 'staff_bookings')
on conflict (rule) do nothing;

-- ================================================================ tables
create table owner_reward_codes (
  promo_code_id uuid primary key references promo_codes (id) on delete cascade,
  owner_id      uuid not null references owners (id) on delete cascade,
  kind          text not null check (kind in ('fleet', 'ff', 'birthday', 'upgrade')),
  period        text,
  created_at    timestamptz not null default now()
);
create index owner_reward_codes_owner_idx on owner_reward_codes (owner_id, kind);
create unique index owner_reward_codes_one_idx on owner_reward_codes (owner_id, kind, coalesce(period, '')) where kind in ('fleet', 'ff', 'birthday');
comment on table owner_reward_codes is 'Owner rewards (3262): the promo codes that carry an owner''s rewards: the fleet discount (their own renter account), the friends-and-family code (the owner''s referral code, public), each year''s birthday credit and an approved upgrade.';

create table owner_reward_ledger (
  id              uuid primary key default gen_random_uuid(),
  owner_id        uuid not null references owners (id) on delete cascade,
  kind            text not null check (kind in ('refer_owner', 'birthday', 'upgrade', 'merch_kit', 'merch_kit_premium', 'friend_rental', 'credit')),
  ref_key         text not null,
  title           text not null check (length(title) between 3 and 200),
  detail          text check (detail is null or length(detail) <= 400),
  amount_cents    bigint check (amount_cents is null or amount_cents >= 0),
  owner_credit_id uuid references owner_credits (id) on delete set null,
  promo_code_id   uuid references promo_codes (id) on delete set null,
  expense_id      uuid references company_expenses (id) on delete set null,
  created_by      uuid references users (id) on delete set null,
  created_at      timestamptz not null default now(),
  unique (owner_id, kind, ref_key)
);
create index owner_reward_ledger_owner_idx on owner_reward_ledger (owner_id, created_at desc);
create index owner_reward_ledger_credit_idx on owner_reward_ledger (owner_credit_id) where owner_credit_id is not null;
create index owner_reward_ledger_promo_idx on owner_reward_ledger (promo_code_id) where promo_code_id is not null;
create index owner_reward_ledger_expense_idx on owner_reward_ledger (expense_id) where expense_id is not null;
comment on table owner_reward_ledger is 'Owner rewards (3262): the history an owner reads on the Rewards tab: each reward once (ref_key), with its credit, code or expense.';

create table owner_reward_requests (
  id            uuid primary key default gen_random_uuid(),
  owner_id      uuid not null references owners (id) on delete cascade,
  kind          text not null check (kind in ('merch_kit', 'merch_kit_premium', 'upgrade')),
  status        text not null default 'requested' check (status in ('requested', 'approved', 'shipped', 'declined', 'cancelled')),
  vehicle_id    uuid references vehicles (id) on delete set null,
  note          text check (note is null or length(note) <= 600),
  ship_name     text, ship_line1 text, ship_line2 text, ship_city text, ship_province text, ship_postal_code text, ship_phone text,
  size          text check (size is null or size in ('S', 'M', 'L', 'XL', 'XXL')),
  decided_by    uuid references users (id) on delete set null,
  decided_at    timestamptz,
  decision_note text check (decision_note is null or length(decision_note) <= 400),
  tracking      text check (tracking is null or length(tracking) <= 200),
  shipped_at    timestamptz,
  cost_cents    bigint check (cost_cents is null or cost_cents >= 0),
  promo_code_id uuid references promo_codes (id) on delete set null,
  created_at    timestamptz not null default now(),
  updated_at    timestamptz not null default now(),
  check (kind = 'upgrade' or (ship_name is not null and ship_line1 is not null and ship_city is not null and ship_postal_code is not null)),
  check (status <> 'shipped' or shipped_at is not null)
);
create index owner_reward_requests_owner_idx on owner_reward_requests (owner_id, created_at desc);
create index owner_reward_requests_open_idx on owner_reward_requests (status) where status = 'requested';
create index owner_reward_requests_vehicle_idx on owner_reward_requests (vehicle_id) where vehicle_id is not null;
create index owner_reward_requests_promo_idx on owner_reward_requests (promo_code_id) where promo_code_id is not null;
create unique index owner_reward_requests_one_kit on owner_reward_requests (owner_id, kind) where kind <> 'upgrade' and status in ('requested', 'shipped');
comment on table owner_reward_requests is 'Owner rewards (3262): what an owner asked for by a button: a merch kit (the address they confirmed; an Admin ships it and marks it shipped) or a free upgrade while their car is down for a repair CarmaCars caused (an Admin approves or declines).';

do $$
declare t text;
begin
  foreach t in array array['owner_reward_codes', 'owner_reward_ledger', 'owner_reward_requests'] loop
    execute format('alter table %I enable row level security', t);
    execute format('revoke all on %I from public, anon, authenticated', t);
    execute format('grant all on %I to service_role', t);
    execute format('create policy admin_all on %I for all to authenticated using (app.is_admin()) with check (app.is_admin())', t);
    execute format('create trigger audit_%s after insert or update or delete on %I for each row execute function app.audit_row(%L)', t, t, case when t = 'owner_reward_requests' then 'redact' else '' end);
  end loop;
end $$;
create trigger owner_reward_requests_updated before update on owner_reward_requests for each row execute function app.set_updated_at();

-- ================================================================ who, since when
create function app.owner_reward_ok(p_owner uuid) returns boolean
language sql stable security definer set search_path = public, app as $$
  select (app.settings()).owner_reward_enabled
     and exists (select 1 from owners o where o.id = p_owner and o.kind = 'program' and o.status::text = 'active' and not coalesce(o.is_test, false))
$$;
-- the day the owner's first car joined the program (its enrollment, else its first day live on the site)
create function app.owner_reward_since(p_owner uuid) returns date
language sql stable security definer set search_path = public, app as $$
  select min(coalesce(v.enrollment_date, app.local_date(l.first_published_at)))
    from vehicles v left join vehicle_listings l on l.vehicle_id = v.id where v.owner_id = p_owner and v.supply_type = 'program_owner'
$$;
create function app.owner_reward_months(p_owner uuid) returns integer
language sql stable security definer set search_path = public, app as $$
  select case when app.owner_reward_since(p_owner) is null then 0
    else greatest((extract(year from age(app.today(), app.owner_reward_since(p_owner))) * 12 + extract(month from age(app.today(), app.owner_reward_since(p_owner))))::integer, 0) end
$$;
create function app.owner_reward_renter(p_owner uuid) returns uuid
language sql stable security definer set search_path = public, app as $$
  select r.id from owners o join renters r on r.user_id = o.user_id and r.merged_into is null where o.id = p_owner order by r.created_at limit 1
$$;
create function app.owner_reward_first_name(p_owner uuid) returns text
language sql stable security definer set search_path = public, app as $$
  select coalesce(nullif(btrim(o.first_name), ''), nullif(split_part(btrim(coalesce(o.legal_name, '')), ' ', 1), ''), 'there') from owners o where o.id = p_owner
$$;
-- is one of the owner's cars not available on these dates: on rent, or blocked for service, a repair or a claim
-- (never the owner's own block or their own use)
create function app.owner_reward_car_down(p_owner uuid, p_from timestamptz, p_to timestamptz) returns boolean
language sql stable security definer set search_path = public, app as $$
  select exists (
    select 1 from vehicles v where v.owner_id = p_owner and v.retired_at is null and (
      v.status::text = 'out_of_service'
      or exists (select 1 from bookings b where b.vehicle_id = v.id and b.booking_type::text <> 'owner' and b.status::text in ('confirmed', 'on_rent')
                  and b.pickup_at < p_to and b.return_at > p_from)
      or exists (select 1 from vehicle_calendar_blocks c where c.vehicle_id = v.id and c.removed_at is null and c.reason in ('service', 'repair', 'admin')
                  and c.starts_at < p_to and (c.ends_at is null or c.ends_at > p_from))))
$$;

create function app.owner_reward_notify(p_owner uuid, p_key text, p_title text, p_text text, p_detail text default null) returns void
language plpgsql security definer set search_path = public, app as $$
begin
  perform app.emit_event('owner_reward_update', 'owner', p_owner, jsonb_build_object('owner_id', p_owner, 'first_name', app.owner_reward_first_name(p_owner),
    'reward_title', p_title, 'reward_text', p_text, 'reward_detail', coalesce(p_detail, '')), 'owner_reward_update:' || p_owner || ':' || p_key);
end $$;

-- a credit: a line on the next statement, an expense in the books, a line in the history. Once per (kind, ref_key).
create function app.owner_reward_credit(p_owner uuid, p_kind text, p_ref text, p_cents bigint, p_title text, p_detail text default null, p_by uuid default null) returns uuid
language plpgsql security definer set search_path = public, app as $$
declare
  v_vehicle uuid;
  v_credit uuid;
  v_exp uuid;
  v_id uuid;
begin
  if p_cents <= 0 then return null; end if;
  if exists (select 1 from owner_reward_ledger where owner_id = p_owner and kind = p_kind and ref_key = p_ref) then return null; end if;
  select v.id into v_vehicle from vehicles v where v.owner_id = p_owner order by (v.retired_at is null) desc, v.enrollment_date nulls last, v.created_seq limit 1;
  if v_vehicle is null then raise exception 'This owner has no car to put the credit on' using errcode = '23514'; end if;
  insert into owner_credits (owner_id, vehicle_id, kind, description, amount_cents, incurred_on, created_by)
  values (p_owner, v_vehicle, 'reward_credit', left('Owner rewards: ' || p_title, 300), p_cents, app.today(), p_by) returning id into v_credit;
  insert into company_expenses (expense_on, category, description, amount_cents, owner_id, vehicle_id, created_by)
  values (app.today(), 'owner_reward', left('Owner rewards credit: ' || p_title, 300), p_cents, p_owner, v_vehicle, p_by) returning id into v_exp;
  insert into owner_reward_ledger (owner_id, kind, ref_key, title, detail, amount_cents, owner_credit_id, expense_id, created_by)
  values (p_owner, p_kind, p_ref, p_title, coalesce(p_detail, 'On your next statement.'), p_cents, v_credit, v_exp, p_by) returning id into v_id;
  return v_id;
end $$;

-- ================================================================ an owner's rewards brought up to date
create function app.owner_reward_sync(p_owner uuid, p_now timestamptz default now()) returns void
language plpgsql security definer set search_path = public, app as $$
declare
  s program_settings := app.settings();
  o owners;
  pc promo_codes;
  r record;
  v_renter uuid := app.owner_reward_renter(p_owner);
  v_months integer;
  v_bd date;
  v_year text := to_char(app.local_date(p_now), 'YYYY');
  v_today date := app.local_date(p_now);
  v_this date;
begin
  select * into o from owners where id = p_owner;
  if o.id is null then return; end if;
  if not app.owner_reward_ok(p_owner) then
    update promo_codes set is_active = false where is_active and id in (select promo_code_id from owner_reward_codes where owner_id = p_owner and kind in ('fleet', 'ff'));
    return;
  end if;
  -- the friends-and-family code is the owner's own referral code (the link /r/<code> and the QR carry the same)
  if nullif(btrim(coalesce(o.referral_code, '')), '') is not null and length(btrim(o.referral_code)) >= 3 then
    select p.* into pc from owner_reward_codes c join promo_codes p on p.id = c.promo_code_id where c.owner_id = p_owner and c.kind = 'ff';
    if pc.id is null and not exists (select 1 from promo_codes where code = upper(btrim(o.referral_code))) then
      insert into promo_codes (code, description, percent_bps, once_per_renter, source, company_funded)
      values (upper(btrim(o.referral_code)), 'Friends and family: off a first rental', s.owner_reward_ff_bps, true, 'owner_reward_ff', true) returning * into pc;
      insert into owner_reward_codes (promo_code_id, owner_id, kind) values (pc.id, p_owner, 'ff');
    elsif pc.id is not null and (pc.percent_bps is distinct from s.owner_reward_ff_bps or not pc.is_active) then
      update promo_codes set percent_bps = s.owner_reward_ff_bps, is_active = true where id = pc.id;
    end if;
  end if;
  -- the fleet discount: a code of the owner's own renter account
  pc := null;
  select p.* into pc from owner_reward_codes c join promo_codes p on p.id = c.promo_code_id where c.owner_id = p_owner and c.kind = 'fleet';
  if pc.id is null then
    insert into promo_codes (code, description, percent_bps, once_per_renter, renter_id, source, company_funded, valid_until)
    values (app.rewards_code('OWNER'), 'Owner rewards: off another CarmaCars car while yours is not available', s.owner_reward_fleet_bps, false, v_renter, 'owner_reward_fleet', true, p_now + interval '1 year')
    returning * into pc;
    insert into owner_reward_codes (promo_code_id, owner_id, kind) values (pc.id, p_owner, 'fleet');
  else
    update promo_codes set percent_bps = s.owner_reward_fleet_bps, is_active = true, renter_id = coalesce(renter_id, v_renter), valid_until = greatest(valid_until, p_now + interval '6 months')
     where id = pc.id and (percent_bps is distinct from s.owner_reward_fleet_bps or not is_active or (renter_id is null and v_renter is not null) or valid_until < p_now + interval '6 months');
  end if;
  -- an owner they referred whose car has been live long enough: the credit, once per referred owner
  if s.owner_reward_refer_cents > 0 then
    for r in
      select x.referred, min(l.first_published_at) as live_at, (select coalesce(nullif(btrim(ro.first_name), ''), split_part(ro.legal_name, ' ', 1)) from owners ro where ro.id = x.referred) as who
        from (select referred_owner_id as referred from owner_referral_credits where referrer_owner_id = p_owner and referred_owner_id is not null
              union select referred_owner_id from owner_referral_links where referrer_owner_id = p_owner) x
        join vehicles v on v.owner_id = x.referred and v.retired_at is null
        join vehicle_listings l on l.vehicle_id = v.id and l.first_published_at is not null and l.status::text = 'published'
       where x.referred <> p_owner
       group by x.referred
      having min(l.first_published_at) <= p_now - make_interval(days => s.owner_reward_refer_live_days)
    loop
      if app.owner_reward_credit(p_owner, 'refer_owner', r.referred::text, s.owner_reward_refer_cents,
           format('you referred %s (%s credit)', coalesce(r.who, 'an owner'), app.fmt_money(s.owner_reward_refer_cents)),
           format('Their car has been live for %s days. The credit is on your next statement.', s.owner_reward_refer_live_days)) is not null then
        perform app.owner_reward_notify(p_owner, 'refer:' || r.referred, format('%s credit: thank you for the referral', app.fmt_money(s.owner_reward_refer_cents)),
          format('%s''s car has been live for %s days, so your %s credit is on your next statement.', coalesce(r.who, 'The owner you referred'), s.owner_reward_refer_live_days, app.fmt_money(s.owner_reward_refer_cents)),
          'See it under Rewards in your owner portal.');
      end if;
    end loop;
  end if;
  -- the milestones: told once when the kit can be redeemed (redeeming is the owner's button)
  v_months := app.owner_reward_months(p_owner);
  if v_months >= s.owner_reward_merch_months and not exists (select 1 from owner_reward_requests q where q.owner_id = p_owner and q.kind = 'merch_kit') then
    perform app.owner_reward_notify(p_owner, 'kit_ready', 'Your CarmaCars merch kit is ready to redeem',
      format('%s months with CarmaCars. Thank you. Press Redeem my merch kit and confirm where to send it.', s.owner_reward_merch_months), 'Under Rewards in your owner portal.');
  end if;
  if v_months >= s.owner_reward_merch_premium_months and not exists (select 1 from owner_reward_requests q where q.owner_id = p_owner and q.kind = 'merch_kit_premium') then
    perform app.owner_reward_notify(p_owner, 'kit_premium_ready', 'Your premium merch kit is ready to redeem',
      format('%s months with CarmaCars. Press Redeem my premium kit and confirm where to send it.', s.owner_reward_merch_premium_months), 'Under Rewards in your owner portal.');
  end if;
  -- the birthday credit: on the day (or the first run after it, within 30 days), once a year
  select d.date_of_birth into v_bd from owner_private_details d where d.owner_id = p_owner;
  if v_bd is not null and s.owner_reward_birthday_cents > 0 then
    v_this := make_date(extract(year from v_today)::integer, extract(month from v_bd)::integer, least(extract(day from v_bd)::integer,
                extract(day from (date_trunc('month', make_date(extract(year from v_today)::integer, extract(month from v_bd)::integer, 1)) + interval '1 month - 1 day'))::integer));
    if v_today >= v_this and v_today < v_this + 30 and not exists (select 1 from owner_reward_codes c where c.owner_id = p_owner and c.kind = 'birthday' and c.period = v_year) then
      insert into promo_codes (code, description, amount_cents, once_per_renter, max_uses, renter_id, source, company_funded, valid_until)
      values (app.rewards_code('BDAY'), format('Owner rewards: %s birthday rental credit', app.fmt_money(s.owner_reward_birthday_cents)), s.owner_reward_birthday_cents, true, 1, v_renter, 'owner_reward_birthday', true,
              p_now + make_interval(days => s.owner_reward_birthday_valid_days))
      returning * into pc;
      insert into owner_reward_codes (promo_code_id, owner_id, kind, period) values (pc.id, p_owner, 'birthday', v_year);
      insert into owner_reward_ledger (owner_id, kind, ref_key, title, detail, amount_cents, promo_code_id)
      values (p_owner, 'birthday', v_year, format('Birthday rental credit: %s', app.fmt_money(s.owner_reward_birthday_cents)),
              format('Code %s, off any rental until %s.', pc.code, app.fmt_day(app.local_date(pc.valid_until))), s.owner_reward_birthday_cents, pc.id)
      on conflict do nothing;
      perform app.owner_reward_notify(p_owner, 'birthday:' || v_year, format('Happy birthday: %s off a rental', app.fmt_money(s.owner_reward_birthday_cents)),
        format('Your code %s takes %s off any CarmaCars rental until %s.', pc.code, app.fmt_money(s.owner_reward_birthday_cents), app.fmt_day(app.local_date(pc.valid_until))),
        'It is under Rewards in your owner portal.');
    end if;
  end if;
end $$;

create function app.job_owner_rewards(p_now timestamptz default now()) returns integer
language plpgsql security definer set search_path = public, app as $$
declare r record; n integer := 0;
begin
  for r in select o.id from owners o where o.kind = 'program' and o.status::text = 'active' loop
    begin perform app.owner_reward_sync(r.id, p_now); n := n + 1;
    exception when others then raise warning 'owner rewards: % not synced: %', r.id, sqlerrm; end;
  end loop;
  return n;
end $$;

-- a friend's first rental with the owner's code is confirmed: the owner is told (the kickback itself is 0007's)
create function app.owner_reward_friend_booked() returns trigger
language plpgsql security definer set search_path = public, app as $$
declare s program_settings := app.settings();
begin
  if new.status::text = 'confirmed' and old.status::text <> 'confirmed' and new.referrer_type = 'owner' and new.referrer_owner_id is not null
     and new.test_at is null and app.owner_reward_ok(new.referrer_owner_id) then
    begin
      insert into owner_reward_ledger (owner_id, kind, ref_key, title, detail)
      values (new.referrer_owner_id, 'friend_rental', new.id::text, 'A friend booked with your code',
              format('Booking %s. You earn %s of the rental charge once the trip is complete, on your statement.', new.booking_number, app.fmt_pct(s.kickback_bps)))
      on conflict do nothing;
      if found then
        perform app.owner_reward_notify(new.referrer_owner_id, 'friend:' || new.id, 'A friend booked with your code',
          format('You earn %s of the rental charge once the trip is complete. It shows on your statement.', app.fmt_pct(s.kickback_bps)), 'See your referrals under Rewards.');
      end if;
    exception when others then raise warning 'owner rewards: friend booking % not recorded: %', new.id, sqlerrm; end;
  end if;
  return null;
end $$;
create trigger bookings_owner_reward_friend after update of status on bookings for each row
  when (new.referrer_owner_id is not null and new.status::text = 'confirmed') execute function app.owner_reward_friend_booked();

-- ================================================================ what the owner sees
create function app.owner_reward_state(p_owner uuid) returns jsonb
language plpgsql stable security definer set search_path = public, app as $$
declare
  s program_settings := app.settings();
  o owners;
  v_months integer := app.owner_reward_months(p_owner);
  v_since date := app.owner_reward_since(p_owner);
  fleet promo_codes; ff promo_codes;
  v_base text := rtrim(s.notify_base_url, '/');
  v_bd date;
begin
  select * into o from owners where id = p_owner;
  if not app.owner_reward_ok(p_owner) then
    return jsonb_build_object('on', false, 'why', case when o.kind <> 'program' then 'Owner rewards are for owners in the Vehicle Owner Program.' else 'Owner rewards are switched off for now.' end);
  end if;
  select p.* into fleet from owner_reward_codes c join promo_codes p on p.id = c.promo_code_id where c.owner_id = p_owner and c.kind = 'fleet';
  select p.* into ff from owner_reward_codes c join promo_codes p on p.id = c.promo_code_id where c.owner_id = p_owner and c.kind = 'ff';
  select d.date_of_birth into v_bd from owner_private_details d where d.owner_id = p_owner;
  return jsonb_build_object(
    'on', true, 'since', v_since, 'months', v_months, 'has_renter', app.owner_reward_renter(p_owner) is not null,
    'fleet', jsonb_build_object('bps', s.owner_reward_fleet_bps, 'code', case when fleet.is_active then fleet.code end,
      'car_down_now', app.owner_reward_car_down(p_owner, now(), now() + interval '1 day'),
      'cars', (select coalesce(jsonb_agg(jsonb_build_object('vehicle_id', v.id, 'name', app.vehicle_name(v.id), 'status', v.status::text,
                 'down', app.owner_reward_car_down(p_owner, now(), now() + interval '1 day') and (v.status::text in ('on_rent', 'out_of_service')
                         or exists (select 1 from vehicle_calendar_blocks c where c.vehicle_id = v.id and c.removed_at is null and c.reason in ('service', 'repair', 'admin') and c.starts_at < now() + interval '1 day' and (c.ends_at is null or c.ends_at > now())))) order by v.created_seq), '[]'::jsonb)
                 from vehicles v where v.owner_id = p_owner and v.retired_at is null)),
    'upgrade', (select to_jsonb(x) from (select q.id, q.status, q.created_at, q.decision_note, (select p.code from promo_codes p where p.id = q.promo_code_id) as code,
                  (select p.amount_cents from promo_codes p where p.id = q.promo_code_id) as amount_cents, (select p.valid_until from promo_codes p where p.id = q.promo_code_id) as valid_until
                  from owner_reward_requests q where q.owner_id = p_owner and q.kind = 'upgrade' order by q.created_at desc limit 1) x),
    'friends', jsonb_build_object('bps', s.owner_reward_ff_bps, 'kickback_bps', s.kickback_bps, 'code', case when ff.is_active then ff.code else o.referral_code end,
      'link', v_base || '/r/' || o.referral_code,
      'rentals', (select count(*) from bookings b where b.referrer_owner_id = p_owner and b.referrer_type = 'owner' and b.status::text in ('confirmed', 'on_rent', 'returned', 'closed') and b.test_at is null),
      'earned_cents', (select coalesce(sum(k.amount_cents), 0) from referral_kickbacks k where k.referrer_owner_id = p_owner and k.reversed_at is null),
      'recent', (select coalesce(jsonb_agg(to_jsonb(x) order by x.at desc), '[]'::jsonb) from (
                   select b.booking_number, coalesce(b.confirmed_at, b.created_at) as at, b.status::text as status,
                          (select k.amount_cents from referral_kickbacks k where k.booking_id = b.id and k.reversed_at is null limit 1) as kickback_cents
                     from bookings b where b.referrer_owner_id = p_owner and b.referrer_type = 'owner' and b.status::text in ('confirmed', 'on_rent', 'returned', 'closed') and b.test_at is null
                    order by coalesce(b.confirmed_at, b.created_at) desc limit 10) x)),
    'refer_owner', jsonb_build_object('cents', s.owner_reward_refer_cents, 'live_days', s.owner_reward_refer_live_days, 'link', v_base || '/r/' || o.referral_code || '?to=owner',
      'referred', (select coalesce(jsonb_agg(jsonb_build_object('name', coalesce(nullif(btrim(ro.first_name), ''), split_part(ro.legal_name, ' ', 1)),
                     'live_at', (select min(l.first_published_at) from vehicles v join vehicle_listings l on l.vehicle_id = v.id where v.owner_id = ro.id and l.first_published_at is not null),
                     'credited', exists (select 1 from owner_reward_ledger g where g.owner_id = p_owner and g.kind = 'refer_owner' and g.ref_key = ro.id::text)) order by ro.created_at), '[]'::jsonb)
                    from owners ro where ro.id in (select referred_owner_id from owner_referral_credits where referrer_owner_id = p_owner and referred_owner_id is not null
                                                   union select referred_owner_id from owner_referral_links where referrer_owner_id = p_owner))),
    'milestones', (select jsonb_agg(jsonb_build_object('kind', m.kind, 'name', m.name, 'months', m.months, 'reached', v_months >= m.months, 'months_left', greatest(m.months - v_months, 0),
                     'request', (select jsonb_build_object('id', q.id, 'status', q.status, 'requested_at', q.created_at, 'shipped_at', q.shipped_at, 'tracking', q.tracking,
                                   'city', q.ship_city) from owner_reward_requests q where q.owner_id = p_owner and q.kind = m.kind and q.status in ('requested', 'shipped') limit 1)) order by m.months)
                     from (values ('merch_kit', 'CarmaCars merch kit', s.owner_reward_merch_months), ('merch_kit_premium', 'Premium merch kit', s.owner_reward_merch_premium_months)) m(kind, name, months)),
    'address', jsonb_build_object('name', coalesce(nullif(btrim(concat_ws(' ', o.first_name, o.last_name)), ''), o.legal_name),
      'line1', coalesce(nullif(o.mailing_address_line1, ''), o.address_line1), 'line2', coalesce(nullif(o.mailing_address_line2, ''), o.address_line2),
      'city', coalesce(nullif(o.mailing_city, ''), o.city), 'province', coalesce(nullif(o.mailing_province, ''), o.province),
      'postal_code', coalesce(nullif(o.mailing_postal_code, ''), o.postal_code), 'phone', o.phone),
    'birthday', jsonb_build_object('cents', s.owner_reward_birthday_cents, 'known', v_bd is not null,
      'code', (select jsonb_build_object('code', p.code, 'valid_until', p.valid_until, 'status', app.promo_status(p)) from owner_reward_codes c join promo_codes p on p.id = c.promo_code_id
                where c.owner_id = p_owner and c.kind = 'birthday' order by c.created_at desc limit 1)),
    'perks', jsonb_build_array(
      jsonb_build_object('name', 'Priority support', 'detail', 'Your calls, texts and messages are marked as an owner''s and answered first.'),
      jsonb_build_object('name', 'Early access', 'detail', 'You hear about new programs and offers before anyone else.')),
    'history', (select coalesce(jsonb_agg(jsonb_build_object('at', g.created_at, 'title', g.title, 'detail', g.detail, 'amount_cents', g.amount_cents, 'kind', g.kind) order by g.created_at desc), '[]'::jsonb)
                  from (select * from owner_reward_ledger x where x.owner_id = p_owner order by x.created_at desc limit 40) g),
    'rules', jsonb_build_array(
      'The fleet discount works on dates your own car is on rent, in service or in a claim. Never on exotic or partner cars, and not on your own car.',
      'You are the driver: the licence check, the rental agreement and the deposit are the same as for any renter.',
      'A friend''s code works on their first rental only.',
      'Credits show as a line on your statement. Your Revenue Share and fees do not change.'));
end $$;

-- the buttons. p_action: redeem_kit {kind, name, line1, line2, city, province, postal_code, phone, size} | upgrade_ask {vehicle, note} | upgrade_cancel {id}
create function app.owner_reward_do(p_owner uuid, p_by uuid, p_action text, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  s program_settings := app.settings();
  v_kind text := p ->> 'kind';
  v_need integer;
  q owner_reward_requests;
  v_name text := (select coalesce(nullif(btrim(concat_ws(' ', first_name, last_name)), ''), legal_name) from owners where id = p_owner);
  v_trim text[];
begin
  if not app.owner_reward_ok(p_owner) then raise exception 'Owner rewards are not on for this account' using errcode = '42501'; end if;
  perform app.rw_act_as(p_by);
  if p_action = 'redeem_kit' then
    if v_kind not in ('merch_kit', 'merch_kit_premium') then raise exception 'Choose a kit' using errcode = '22023'; end if;
    v_need := case v_kind when 'merch_kit' then s.owner_reward_merch_months else s.owner_reward_merch_premium_months end;
    if app.owner_reward_months(p_owner) < v_need then raise exception 'This kit is ready after % months with CarmaCars', v_need using errcode = '23514'; end if;
    if exists (select 1 from owner_reward_requests x where x.owner_id = p_owner and x.kind = v_kind and x.status in ('requested', 'shipped')) then
      raise exception 'You already redeemed this kit' using errcode = '23514';
    end if;
    v_trim := array[nullif(btrim(coalesce(p ->> 'name', '')), ''), nullif(btrim(coalesce(p ->> 'line1', '')), ''), nullif(btrim(coalesce(p ->> 'city', '')), ''), nullif(btrim(coalesce(p ->> 'postal_code', '')), '')];
    if v_trim[1] is null or v_trim[2] is null or v_trim[3] is null or v_trim[4] is null then
      raise exception 'Confirm the name, the street address, the city and the postal code to send it to' using errcode = '22023';
    end if;
    insert into owner_reward_requests (owner_id, kind, ship_name, ship_line1, ship_line2, ship_city, ship_province, ship_postal_code, ship_phone, size)
    values (p_owner, v_kind, left(v_trim[1], 120), left(v_trim[2], 160), left(nullif(btrim(coalesce(p ->> 'line2', '')), ''), 160), left(v_trim[3], 80),
            left(nullif(btrim(coalesce(p ->> 'province', '')), ''), 40), left(upper(v_trim[4]), 12), left(nullif(btrim(coalesce(p ->> 'phone', '')), ''), 30),
            case when upper(coalesce(p ->> 'size', '')) in ('S', 'M', 'L', 'XL', 'XXL') then upper(p ->> 'size') end)
    returning * into q;
    insert into owner_reward_ledger (owner_id, kind, ref_key, title, detail)
    values (p_owner, v_kind, q.id::text, case v_kind when 'merch_kit' then 'Merch kit redeemed' else 'Premium merch kit redeemed' end, format('Going to %s. We will tell you when it ships.', q.ship_city));
    perform app.staff_alert('owner_merch_to_ship', 'owner', p_owner, 'kit:' || q.id, left(format('Ship a %s to %s', case v_kind when 'merch_kit' then 'merch kit' else 'premium merch kit' end, v_name), 140),
      left(format('%s, %s. Mark it shipped on Owner rewards.', q.ship_city, coalesce(q.ship_province, '')), 240), jsonb_build_object('path_admin', '/admin/owners/rewards'));
    perform app.owner_reward_notify(p_owner, 'kit_redeemed:' || q.id, case v_kind when 'merch_kit' then 'Your merch kit is on our list to ship' else 'Your premium merch kit is on our list to ship' end,
      format('We are sending it to %s, %s. We will tell you when it ships.', q.ship_line1, q.ship_city), 'Its status is under Rewards in your owner portal.');
  elsif p_action = 'upgrade_ask' then
    if exists (select 1 from owner_reward_requests x where x.owner_id = p_owner and x.kind = 'upgrade' and x.status = 'requested') then
      raise exception 'Your request is already with the team' using errcode = '23514';
    end if;
    if not exists (select 1 from vehicles v where v.id = nullif(p ->> 'vehicle', '')::uuid and v.owner_id = p_owner) then raise exception 'Choose which of your cars is being repaired' using errcode = '22023'; end if;
    if nullif(btrim(coalesce(p ->> 'note', '')), '') is null then raise exception 'Say what happened in a line or two' using errcode = '22023'; end if;
    insert into owner_reward_requests (owner_id, kind, vehicle_id, note) values (p_owner, 'upgrade', (p ->> 'vehicle')::uuid, left(btrim(p ->> 'note'), 600)) returning * into q;
    perform app.staff_alert('owner_upgrade_request', 'owner', p_owner, 'upgrade:' || q.id, left(format('%s asks for a free upgrade', v_name), 140),
      left(format('%s is down for a repair. "%s"', app.vehicle_name(q.vehicle_id), q.note), 240), jsonb_build_object('path_admin', '/admin/owners/rewards'));
    perform app.owner_reward_notify(p_owner, 'upgrade_asked:' || q.id, 'We have your upgrade request', 'An Admin looks at it and answers here and by email.', 'Under Rewards in your owner portal.');
  elsif p_action = 'upgrade_cancel' then
    update owner_reward_requests set status = 'cancelled' where id = nullif(p ->> 'id', '')::uuid and owner_id = p_owner and kind = 'upgrade' and status = 'requested';
    if not found then raise exception 'There is no open request to cancel' using errcode = 'P0002'; end if;
  else raise exception 'Unknown action' using errcode = '22023';
  end if;
  return app.owner_reward_state(p_owner);
end $$;

-- the owner portal (the server passes the session's user; app.portal_owner_id answers only for an active owner account)
create function public.owner_portal_rewards(p_by uuid) returns jsonb
language sql stable security definer set search_path = public, app as $$ select app.owner_reward_state(app.portal_owner_id(p_by)) $$;
create function public.owner_portal_reward_do(p_by uuid, p_action text, p jsonb) returns jsonb
language sql security definer set search_path = public, app as $$ select app.owner_reward_do(app.portal_owner_id(p_by), p_by, p_action, p) $$;

-- ================================================================ the rules, where every code is checked
alter function app.promo_code_problem(text, uuid, uuid, timestamptz) rename to promo_code_problem_pre3262;
create function app.promo_code_problem(p_code text, p_renter uuid, p_booking uuid default null, p_at timestamptz default now()) returns text
language plpgsql stable security definer set search_path = public, app as $$
declare
  pc promo_codes;
  c owner_reward_codes;
  o owners;
  b bookings;
  v vehicles;
begin
  select * into pc from promo_codes where code = upper(btrim(coalesce(p_code, '')));
  if pc.id is null or pc.source not like 'owner_reward_%' then return app.promo_code_problem_pre3262(p_code, p_renter, p_booking, p_at); end if;
  select * into c from owner_reward_codes where promo_code_id = pc.id;
  select * into o from owners where id = c.owner_id;
  if o.id is null or not app.owner_reward_ok(o.id) then return 'This code is no longer active'; end if;
  if pc.source = 'owner_reward_ff' then
    -- a friend's first rental; never the owner's own
    if exists (select 1 from renters r where r.id = p_renter and r.user_id is not null and r.user_id = o.user_id) then return 'This is your own code: it is for your friends and family'; end if;
    if exists (select 1 from renters r where r.id = p_renter and r.first_completed_booking_id is not null)
       or exists (select 1 from bookings x where x.renter_id = p_renter and (p_booking is null or x.id <> p_booking) and x.status::text in ('confirmed', 'on_rent', 'returned', 'closed')) then
      return 'This code is for a first rental with CarmaCars';
    end if;
  else
    -- the owner is the driver: the code works on their own renter account only
    if not exists (select 1 from renters r where r.id = p_renter and r.user_id is not null and r.user_id = o.user_id) then
      return 'An owner reward is for a rental you drive yourself: sign in with your owner account';
    end if;
  end if;
  if p_booking is not null then
    select * into b from bookings where id = p_booking;
    select * into v from vehicles where id = b.vehicle_id;
    if pc.source in ('owner_reward_fleet', 'owner_reward_upgrade') then
      if v.owner_id = o.id then return 'Your own car is booked as an Owner Booking, at no charge. This code is for another CarmaCars car'; end if;
      if v.class::text = 'exotic' or exists (select 1 from vehicle_class_links l where l.vehicle_id = v.id and l.class_code = 'exotic') then return 'Owner rewards are not for exotic cars'; end if;
      if v.supply_type = 'partner' then return 'Owner rewards are not for partner cars'; end if;
    end if;
    if pc.source = 'owner_reward_fleet' and not app.owner_reward_car_down(o.id, b.pickup_at, b.return_at) then
      return 'The fleet discount is for dates your own car is on rent, in service or in a claim';
    end if;
  end if;
  return app.promo_code_problem_pre3262(p_code, p_renter, p_booking, p_at);
end $$;
select pg_temp.copy_grants('app.promo_code_problem(text, uuid, uuid, timestamptz)'::regprocedure, 'app.promo_code_problem_pre3262(text, uuid, uuid, timestamptz)'::regprocedure);

-- a request that came through an owner's link gets the friends-and-family discount without typing the code, and a
-- request that typed the code credits the owner. Never in the way of the request: a code that does not fit is left off.
alter function app.submit_booking_request(jsonb, inet, text, uuid) rename to submit_booking_request_pre3262;
create function app.submit_booking_request(p_request jsonb, p_ip inet default null, p_user_agent text default null, p_user uuid default null) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  v_req jsonb := p_request;
  v_promo text := upper(nullif(btrim(coalesce(p_request ->> 'promo_code', '')), ''));
  v_ref text := upper(nullif(btrim(coalesce(p_request ->> 'referred_by_code', '')), ''));
  v_ff text;
  v_out jsonb;
  b bookings;
begin
  if v_promo is not null and v_ref is null and exists (select 1 from promo_codes pc where pc.code = v_promo and pc.source = 'owner_reward_ff') then
    v_req := v_req || jsonb_build_object('referred_by_code', v_promo);
  elsif v_promo is null and v_ref is not null then
    select pc.code into v_ff from promo_codes pc where pc.code = v_ref and pc.source = 'owner_reward_ff' and pc.is_active;
  end if;
  v_out := app.submit_booking_request_pre3262(v_req, p_ip, p_user_agent, p_user);
  if v_ff is not null and coalesce((v_out ->> 'ok')::boolean, false) and coalesce((v_out ->> 'created')::boolean, true) and nullif(v_out ->> 'booking_id', '') is not null then
    select * into b from bookings where id = (v_out ->> 'booking_id')::uuid;
    if b.id is not null and b.promo_code_id is null and b.status::text in ('requested', 'offered') and app.promo_code_problem(v_ff, b.renter_id, b.id) is null then
      begin
        perform app.apply_promo_code(b.id, v_ff, null);
      exception when others then
        raise warning 'friends and family code % not applied to %: %', v_ff, b.booking_number, sqlerrm;
      end;
    end if;
  end if;
  return v_out;
end $$;
select pg_temp.copy_grants('app.submit_booking_request(jsonb, inet, text, uuid)'::regprocedure, 'app.submit_booking_request_pre3262(jsonb, inet, text, uuid)'::regprocedure);

-- ================================================================ the Admin's view, changes and To do
create function app.owner_rewards_admin(p_by uuid, p jsonb) returns jsonb
language plpgsql stable security definer set search_path = public, app as $$
declare s program_settings := app.settings();
begin
  if not app.user_is_admin(p_by) then raise exception 'Not permitted' using errcode = '42501'; end if;
  return jsonb_build_object(
    'settings', jsonb_build_object('enabled', s.owner_reward_enabled, 'fleet_bps', s.owner_reward_fleet_bps, 'ff_bps', s.owner_reward_ff_bps, 'kickback_bps', s.kickback_bps,
      'refer_cents', s.owner_reward_refer_cents, 'refer_live_days', s.owner_reward_refer_live_days, 'merch_months', s.owner_reward_merch_months, 'merch_premium_months', s.owner_reward_merch_premium_months,
      'merch_cost_cents', s.owner_reward_merch_cost_cents, 'merch_premium_cost_cents', s.owner_reward_merch_premium_cost_cents, 'birthday_cents', s.owner_reward_birthday_cents,
      'upgrade_default_cents', s.owner_reward_upgrade_default_cents),
    'requests', (select coalesce(jsonb_agg(jsonb_build_object('id', q.id, 'kind', q.kind, 'status', q.status, 'owner_id', q.owner_id, 'owner', o.legal_name, 'created_at', q.created_at,
                   'car', case when q.vehicle_id is not null then app.vehicle_name(q.vehicle_id) end, 'note', q.note, 'size', q.size,
                   'ship_to', case when q.kind <> 'upgrade' then concat_ws(', ', q.ship_name, q.ship_line1, q.ship_line2, q.ship_city, q.ship_province, q.ship_postal_code) end, 'phone', q.ship_phone,
                   'shipped_at', q.shipped_at, 'tracking', q.tracking, 'decision_note', q.decision_note, 'cost_cents', q.cost_cents,
                   'default_cost_cents', case q.kind when 'merch_kit' then s.owner_reward_merch_cost_cents when 'merch_kit_premium' then s.owner_reward_merch_premium_cost_cents else s.owner_reward_upgrade_default_cents end)
                   order by (q.status = 'requested') desc, q.created_at desc), '[]'::jsonb)
                   from (select * from owner_reward_requests order by (status = 'requested') desc, created_at desc limit 100) q join owners o on o.id = q.owner_id),
    'owners', (select coalesce(jsonb_agg(jsonb_build_object('owner_id', o.id, 'name', o.legal_name, 'months', app.owner_reward_months(o.id), 'since', app.owner_reward_since(o.id),
                 'code', o.referral_code, 'priority', true,
                 'friend_rentals', (select count(*) from bookings b where b.referrer_owner_id = o.id and b.referrer_type = 'owner' and b.status::text in ('confirmed', 'on_rent', 'returned', 'closed') and b.test_at is null),
                 'credits_cents', (select coalesce(sum(g.amount_cents), 0) from owner_reward_ledger g where g.owner_id = o.id and g.owner_credit_id is not null)) order by o.legal_name), '[]'::jsonb)
                 from owners o where o.kind = 'program' and o.status::text = 'active'),
    'cost_month_cents', (select coalesce(sum(e.amount_cents), 0) from company_expenses e where e.category = 'owner_reward' and e.voided_at is null and app.month_start(e.expense_on) = app.month_start(app.today())),
    'cost_year_cents', (select coalesce(sum(e.amount_cents), 0) from company_expenses e where e.category = 'owner_reward' and e.voided_at is null and e.expense_on >= date_trunc('year', app.today())::date),
    'recent', (select coalesce(jsonb_agg(to_jsonb(x) order by x.at desc), '[]'::jsonb) from (
                 select g.created_at as at, o.legal_name as owner, g.title, g.detail, g.amount_cents from owner_reward_ledger g join owners o on o.id = g.owner_id order by g.created_at desc limit 50) x));
end $$;

-- owner_reward_ship {id, tracking, cost_cents} | owner_reward_upgrade_decide {id, approve, amount_cents, note} | owner_reward_credit {owner, amount_cents, note}
create function app.owner_rewards_admin_do(p_by uuid, p_name text, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  s program_settings := app.settings();
  q owner_reward_requests;
  pc promo_codes;
  v_cost bigint := coalesce((p ->> 'cost_cents')::bigint, 0);
  v_amount bigint := coalesce((p ->> 'amount_cents')::bigint, 0);
  v_exp uuid;
  v_vehicle uuid;
  v_approve boolean := coalesce(p ->> 'approve', '') in ('true', 'yes', 'approve');
  v_note text := nullif(btrim(coalesce(p ->> 'note', '')), '');
begin
  if not app.user_is_admin(p_by) then raise exception 'Not permitted' using errcode = '42501'; end if;
  perform app.rw_act_as(p_by);
  if p_name = 'owner_reward_credit' then
    if v_amount <= 0 or v_note is null then raise exception 'Enter the amount and what it is for (the owner reads it)' using errcode = '22023'; end if;
    perform app.owner_reward_credit((p ->> 'owner')::uuid, 'credit', gen_random_uuid()::text, v_amount, left(v_note, 160), null, p_by);
    perform app.owner_reward_notify((p ->> 'owner')::uuid, 'credit:' || gen_random_uuid(), format('%s credit on your next statement', app.fmt_money(v_amount)), v_note, 'See it under Rewards in your owner portal.');
    return jsonb_build_object('ok', true);
  end if;
  select * into q from owner_reward_requests where id = nullif(p ->> 'id', '')::uuid for update;
  if q.id is null then raise exception 'Unknown request' using errcode = 'P0002'; end if;
  if p_name = 'owner_reward_ship' then
    if q.kind = 'upgrade' or q.status <> 'requested' then raise exception 'This is not a kit waiting to ship' using errcode = '23514'; end if;
    if v_cost > 0 then
      select v.id into v_vehicle from vehicles v where v.owner_id = q.owner_id order by v.created_seq limit 1;
      insert into company_expenses (expense_on, category, description, amount_cents, owner_id, vehicle_id, created_by)
      values (app.today(), 'owner_reward', left(format('Owner rewards: %s shipped to %s', case q.kind when 'merch_kit' then 'merch kit' else 'premium merch kit' end, q.ship_name), 300), v_cost, q.owner_id, v_vehicle, p_by)
      returning id into v_exp;
    end if;
    update owner_reward_requests set status = 'shipped', shipped_at = now(), tracking = left(nullif(btrim(coalesce(p ->> 'tracking', '')), ''), 200), cost_cents = nullif(v_cost, 0), decided_by = p_by, decided_at = now()
     where id = q.id returning * into q;
    update owner_reward_ledger set title = case q.kind when 'merch_kit' then 'Merch kit shipped' else 'Premium merch kit shipped' end,
           detail = format('Shipped %s to %s.%s', app.fmt_day(app.today()), q.ship_city, case when q.tracking is not null then ' Tracking: ' || q.tracking else '' end), expense_id = v_exp
     where owner_id = q.owner_id and kind = q.kind and ref_key = q.id::text;
    perform app.owner_reward_notify(q.owner_id, 'kit_shipped:' || q.id, case q.kind when 'merch_kit' then 'Your merch kit has shipped' else 'Your premium merch kit has shipped' end,
      format('It is on its way to %s, %s.', q.ship_line1, q.ship_city), case when q.tracking is not null then 'Tracking: ' || q.tracking else 'Enjoy it.' end);
  elsif p_name = 'owner_reward_upgrade_decide' then
    if q.kind <> 'upgrade' or q.status <> 'requested' then raise exception 'This is not an upgrade request waiting for an answer' using errcode = '23514'; end if;
    if v_approve then
      if v_amount <= 0 then v_amount := s.owner_reward_upgrade_default_cents; end if;
      if v_amount <= 0 then raise exception 'Enter what the upgrade is worth' using errcode = '22023'; end if;
      insert into promo_codes (code, description, amount_cents, once_per_renter, max_uses, renter_id, source, company_funded, valid_until)
      values (app.rewards_code('UPGR'), format('Owner rewards: free upgrade while the %s is repaired', app.vehicle_name(q.vehicle_id)), v_amount, true, 1, app.owner_reward_renter(q.owner_id), 'owner_reward_upgrade', true, now() + interval '30 days')
      returning * into pc;
      insert into owner_reward_codes (promo_code_id, owner_id, kind, period) values (pc.id, q.owner_id, 'upgrade', q.id::text);
      update owner_reward_requests set status = 'approved', decided_by = p_by, decided_at = now(), decision_note = left(v_note, 400), promo_code_id = pc.id where id = q.id;
      insert into owner_reward_ledger (owner_id, kind, ref_key, title, detail, amount_cents, promo_code_id, created_by)
      values (q.owner_id, 'upgrade', q.id::text, 'Free upgrade approved', format('Code %s takes %s off a rental until %s.', pc.code, app.fmt_money(v_amount), app.fmt_day(app.local_date(pc.valid_until))), v_amount, pc.id, p_by);
      perform app.owner_reward_notify(q.owner_id, 'upgrade:' || q.id, 'Your free upgrade is approved',
        format('Code %s takes %s off a rental of a car in a higher class, until %s. Use it together with your dates; the fleet discount code is for other rentals.', pc.code, app.fmt_money(v_amount), app.fmt_day(app.local_date(pc.valid_until))),
        coalesce(v_note, 'It is under Rewards in your owner portal.'));
    else
      if v_note is null then raise exception 'Say why (the owner reads it)' using errcode = '22023'; end if;
      update owner_reward_requests set status = 'declined', decided_by = p_by, decided_at = now(), decision_note = left(v_note, 400) where id = q.id;
      perform app.owner_reward_notify(q.owner_id, 'upgrade:' || q.id, 'About your upgrade request', v_note, 'Your fleet discount still works on the dates your car is not available.');
    end if;
  else raise exception 'Unknown action' using errcode = '22023';
  end if;
  return jsonb_build_object('ok', true);
end $$;

-- Admin > To do: kits to ship and upgrades to answer
alter function app.admin_todo(uuid) rename to admin_todo_pre3262;
create function app.admin_todo(p_admin uuid) returns jsonb
language plpgsql stable security definer set search_path = public, app as $$
declare
  v jsonb := app.admin_todo_pre3262(p_admin);
  v_kits integer := (select count(*) from owner_reward_requests where status = 'requested' and kind <> 'upgrade');
  v_up integer := (select count(*) from owner_reward_requests where status = 'requested' and kind = 'upgrade');
  v_items jsonb := coalesce(v -> 'items', '[]'::jsonb);
begin
  if v_kits + v_up = 0 then return v; end if;
  if v_kits > 0 then v_items := v_items || jsonb_build_object('key', 'owner_merch_ship', 'label', case when v_kits = 1 then 'Merch kit to ship to an owner' else 'Merch kits to ship to owners' end, 'button', 'Ship', 'href', '/admin/owners/rewards', 'count', v_kits); end if;
  if v_up > 0 then v_items := v_items || jsonb_build_object('key', 'owner_upgrade', 'label', case when v_up = 1 then 'Owner upgrade to approve' else 'Owner upgrades to approve' end, 'button', 'Answer', 'href', '/admin/owners/rewards', 'count', v_up); end if;
  return v || jsonb_build_object('items', v_items, 'need', app.todo_need(coalesce(v -> 'prompts', '[]'::jsonb), v_items));
end $$;
select pg_temp.copy_grants('app.admin_todo(uuid)'::regprocedure, 'app.admin_todo_pre3262(uuid)'::regprocedure);

insert into notification_catalogue (code, audience, category, subject, preheader, timing, trigger_text, link_path, variables, template_html, template_text, emitted_by, pref_type, priority, push_topic)
values ('owner_reward_update', 'owner', 'transactional', '{{reward_title}}', '{{reward_text}}', 'Immediate, once per event',
        'Owner rewards (3262): a merch kit ready to redeem, redeemed or shipped; an upgrade request received, approved or declined; a referral credit; the birthday credit; a friend''s rental with the owner''s code; a credit added by an Admin.',
        '/owner/rewards',
        '[{"name":"first_name","type":"string"},{"name":"reward_title","type":"string"},{"name":"reward_text","type":"string"},{"name":"reward_detail","type":"string"}]'::jsonb,
        'templates/owner_reward_update.html', 'templates/owner_reward_update.txt', 'app.owner_reward_notify (3262)', 'owner_rewards', 2, 'bookings')
on conflict (code) do nothing;

do $$
begin
  if exists (select 1 from pg_extension where extname = 'pg_cron') then
    perform cron.schedule('carmacars-owner-rewards', '35 * * * *', $q$select app.job_owner_rewards()$q$);
  end if;
end $$;

do $$
declare f record;
begin
  for f in select p.oid::regprocedure as sig from pg_proc p join pg_namespace n on n.oid = p.pronamespace
            where n.nspname in ('app', 'public') and (p.proname ~ '^(owner_reward|owner_rewards_|job_owner_rewards|owner_portal_reward)' or p.proname ~ '_pre3262$')
  loop
    execute format('revoke all on function %s from public, anon, authenticated', f.sig);
    execute format('grant execute on function %s to service_role', f.sig);
  end loop;
end $$;
