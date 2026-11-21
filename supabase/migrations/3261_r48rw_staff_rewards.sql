-- 3261_r48rw_staff_rewards.sql
-- Release 48, part RW: staff rewards (docs/changes/2026-11-20-r48-rewards-calendar-notify.md). The owner, Nov 20 12:04
-- and 12:06: "Staff get perks for renting cars out: free rentals they earn + discounts from day one."
--   Day one     15% off their own rentals once the academy and the staff agreement are done.
--   Free days   Sales: 1 free rental day per 100 rental days they book. Field: 1 per 100 handovers.
--   Tiers       by the rental days booked in a month: Silver from 50 (20% off), Gold from 100 (25% off and 1 bonus
--               free day that month). The month's top seller gets a free weekend.
--   Who         in-person staff in Canada only. Virtual assistants and other international or remote staff get no
--               rental perks (they cannot rent here).
--   Rules       the staff member is the primary driver (the code works only on their own renter account; licence
--               check, agreement and deposit as for any renter); no exotic or partner cars; never in the way of a paying
--               renter: the pickup is within 48 hours of booking (last minute) and no renter has asked for the car on
--               those dates; a free day ends 6 months after it was earned; a suspended account's perks are frozen.
--   Money       free days go on company or shareholder cars first; on a co-host owner's car the owner is paid as at the
--               full rate (promo_codes.company_funded, 2421). Every perk used is posted to the books as a staff benefit
--               expense (company_expenses, category staff_benefit, account 5300).
-- Every number is a Program settings column (staff_perk_*). The perks are promo codes of the person's own renter account
-- (sources staff_perk_discount and staff_perk_free_day), so the request, the offer, the agreement, the price and the
-- owner's split are the ones every booking uses; app.promo_code_problem holds the rules above.
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
  add column if not exists staff_perk_enabled boolean not null default true,
  add column if not exists staff_perk_base_bps integer not null default 1500 check (staff_perk_base_bps between 0 and 10000),
  add column if not exists staff_perk_days_per_free_day integer not null default 100 check (staff_perk_days_per_free_day between 1 and 100000),
  add column if not exists staff_perk_handovers_per_free_day integer not null default 100 check (staff_perk_handovers_per_free_day between 1 and 100000),
  add column if not exists staff_perk_handover_kinds text[] not null default '{handover,delivery}',
  add column if not exists staff_perk_silver_days integer not null default 50 check (staff_perk_silver_days >= 1),
  add column if not exists staff_perk_silver_bps integer not null default 2000 check (staff_perk_silver_bps between 0 and 10000),
  add column if not exists staff_perk_gold_days integer not null default 100 check (staff_perk_gold_days >= 1),
  add column if not exists staff_perk_gold_bps integer not null default 2500 check (staff_perk_gold_bps between 0 and 10000),
  add column if not exists staff_perk_gold_bonus_days integer not null default 1 check (staff_perk_gold_bonus_days between 0 and 7),
  add column if not exists staff_perk_top_seller_days integer not null default 2 check (staff_perk_top_seller_days between 0 and 7),
  add column if not exists staff_perk_max_ahead_hours integer not null default 48 check (staff_perk_max_ahead_hours between 1 and 720),
  add column if not exists staff_perk_expiry_months integer not null default 6 check (staff_perk_expiry_months between 1 and 60),
  add column if not exists staff_perk_expiry_notice_days integer not null default 14 check (staff_perk_expiry_notice_days between 1 and 90),
  add column if not exists staff_perk_count_from date not null default date '2026-11-01';
comment on column program_settings.staff_perk_enabled is 'Staff rewards (3261): on or off for everyone.';
comment on column program_settings.staff_perk_base_bps is 'Staff rewards (3261): the discount on a staff member''s own rentals once the academy and the agreement are done (1500 = 15%).';
comment on column program_settings.staff_perk_days_per_free_day is 'Staff rewards (3261): Sales earn 1 free rental day per this many rental days they book.';
comment on column program_settings.staff_perk_handovers_per_free_day is 'Staff rewards (3261): Field staff earn 1 free rental day per this many completed handovers.';
comment on column program_settings.staff_perk_handover_kinds is 'Staff rewards (3261): the field job kinds that count as a handover (handover, delivery; add return_check_in or pickup_from_renter to count returns too).';
comment on column program_settings.staff_perk_silver_days is 'Staff rewards (3261): rental days booked in a month for Silver.';
comment on column program_settings.staff_perk_silver_bps is 'Staff rewards (3261): Silver''s discount (2000 = 20%).';
comment on column program_settings.staff_perk_gold_days is 'Staff rewards (3261): rental days booked in a month for Gold.';
comment on column program_settings.staff_perk_gold_bps is 'Staff rewards (3261): Gold''s discount (2500 = 25%).';
comment on column program_settings.staff_perk_gold_bonus_days is 'Staff rewards (3261): bonus free days in a month Gold is reached.';
comment on column program_settings.staff_perk_top_seller_days is 'Staff rewards (3261): free days for the top seller of the month (2 = a free weekend).';
comment on column program_settings.staff_perk_max_ahead_hours is 'Staff rewards (3261): a rental with a staff perk is picked up within this many hours of booking, so it never takes a car a paying renter would book ahead.';
comment on column program_settings.staff_perk_expiry_months is 'Staff rewards (3261): a free day ends this many months after it was earned.';
comment on column program_settings.staff_perk_expiry_notice_days is 'Staff rewards (3261): days before a free day ends that its owner is reminded.';
comment on column program_settings.staff_perk_count_from is 'Staff rewards (3261): rental days and handovers count toward free days from this date.';

insert into gl_accounts (code, name, account_type, note) values
  ('5300', 'Staff benefits', 'expense', 'added in 3261: staff rewards used (discounts and free rental days on their own rentals)'),
  ('5310', 'Owner rewards and credits', 'expense', 'added in 3262: owner rewards (fleet discounts, friends-and-family discounts, referral and birthday credits, merch kits)')
on conflict (code) do nothing;
insert into company_expense_categories (code, label, gl_account) values
  ('staff_benefit', 'Staff benefit: rewards on a staff member''s own rental', '5300'),
  ('owner_reward', 'Owner reward: discount, credit or merch kit', '5310')
on conflict (code) do nothing;

insert into staff_alert_rules (rule, label, grp, who, tier, topic, wired, fixed, hint, sort, pref_type) values
  ('staff_perk_booking', 'A staff member asked for a rental with a staff perk', 'Staff', '{admin}', 'normal', 'requests', true, false, 'Staff rewards (3261): the request is handled like any other; the perk is posted as a staff benefit when it is used.', 180, 'staff_bookings'),
  ('staff_top_seller', 'Top seller of the month', 'Staff', '{admin}', 'digest', 'alerts', true, false, 'Staff rewards (3261): the month''s top seller got their free weekend.', 181, 'staff_system')
on conflict (rule) do nothing;

-- ================================================================ tables
alter table staff_profiles
  add column if not exists perks_eligible boolean,
  add column if not exists perks_note text check (perks_note is null or length(perks_note) <= 300),
  add column if not exists perks_unlocked_at timestamptz,
  add column if not exists perks_tier text not null default 'member' check (perks_tier in ('member', 'silver', 'gold')),
  add column if not exists perks_tier_month date;
comment on column staff_profiles.perks_eligible is 'Staff rewards (3261): an Admin''s answer for this person (true or false). Empty: by the rule (in person, in Canada).';

create table staff_free_days (
  id         uuid primary key default gen_random_uuid(),
  user_id    uuid not null references users (id) on delete cascade,
  source     text not null check (source in ('sales_days', 'handovers', 'gold_bonus', 'top_seller', 'adjust')),
  seq        text not null,
  days       integer not null check (days between 1 and 31),
  used_days  integer not null default 0 check (used_days >= 0),
  earned_at  timestamptz not null default now(),
  expires_at timestamptz not null,
  expiry_noticed_at timestamptz,
  note       text check (note is null or length(note) <= 300),
  created_by uuid references users (id) on delete set null,
  check (used_days <= days),
  unique (user_id, source, seq)
);
create index staff_free_days_user_idx on staff_free_days (user_id, expires_at);
comment on table staff_free_days is 'Staff rewards (3261): free rental days earned, one row each time (per 100 rental days booked, per 100 handovers, Gold''s bonus, top seller, an Admin''s adjustment). They end at expires_at; used_days are the ones put on a code.';

create table staff_perk_codes (
  promo_code_id uuid primary key references promo_codes (id) on delete cascade,
  user_id       uuid not null references users (id) on delete cascade,
  kind          text not null check (kind in ('discount', 'free_days')),
  days          integer check (days is null or days between 1 and 7),
  lots          jsonb not null default '[]'::jsonb,
  created_at    timestamptz not null default now(),
  cancelled_at  timestamptz
);
create index staff_perk_codes_user_idx on staff_perk_codes (user_id, kind);
comment on table staff_perk_codes is 'Staff rewards (3261): the promo codes that carry a staff member''s perks: the discount code (one, its percentage follows the tier) and each free-day code (lots: which earned days it took, given back if the code is cancelled unused).';

create table reward_postings (
  redemption_id uuid primary key references promo_redemptions (id) on delete cascade,
  kind          text not null check (kind in ('staff_benefit', 'owner_reward')),
  expense_id    uuid not null references company_expenses (id),
  amount_cents  bigint not null check (amount_cents > 0),
  posted_at     timestamptz not null default now()
);
create index reward_postings_expense_idx on reward_postings (expense_id);
comment on table reward_postings is 'Rewards (3261, 3262): the expense posted for a reward code used on a booking, once per use; voided if the booking is cancelled before it starts.';

do $$
declare t text;
begin
  foreach t in array array['staff_free_days', 'staff_perk_codes', 'reward_postings'] loop
    execute format('alter table %I enable row level security', t);
    execute format('revoke all on %I from public, anon, authenticated', t);
    execute format('grant all on %I to service_role', t);
    execute format('create policy admin_all on %I for all to authenticated using (app.is_admin()) with check (app.is_admin())', t);
    execute format('create trigger audit_%s after insert or update or delete on %I for each row execute function app.audit_row()', t, t);
  end loop;
end $$;

-- ================================================================ who gets perks
-- in person, in Canada, onboarded, not suspended. An Admin's answer (perks_eligible) wins over the in-person rule only.
create function app.staff_perk_facts(p_user uuid, out member boolean, out eligible boolean, out frozen boolean, out why_not text, out in_person boolean, out sales boolean, out field boolean)
language plpgsql stable security definer set search_path = public, app as $$
declare
  s program_settings := app.settings();
  sp staff_profiles;
  u users;
  v_onboarded boolean;
begin
  select * into sp from staff_profiles where user_id = p_user;
  select * into u from users where id = p_user;
  member := sp.user_id is not null and coalesce(sp.is_active, false) and u.status = 'active'
            and exists (select 1 from user_roles r where r.user_id = p_user and r.role::text in ('va', 'field'));
  sales := member and 'sales' = any (sp.functions);
  field := member and 'field' = any (sp.functions);
  in_person := member and (field or sp.sales_work_mode = 'in_person') and coalesce(sp.location_country, 'CA') = 'CA' and coalesce(sp.location_area, '') <> 'outside';
  frozen := member and sp.inactive_locked_at is not null;
  eligible := false;
  if not coalesce(member, false) then why_not := 'Staff rewards are for active staff.'; member := false; frozen := false; return; end if;
  if not s.staff_perk_enabled then why_not := 'Staff rewards are switched off for now.'; return; end if;
  if sp.perks_eligible is false then why_not := coalesce(nullif(btrim(sp.perks_note), ''), 'An Admin switched rental perks off for your account.'); return; end if;
  if not in_person and sp.perks_eligible is not true then
    why_not := 'Rental perks are for in-person staff in Canada. Remote and international staff cannot rent here, so there are no rental perks on this account.';
    return;
  end if;
  -- the academy and the agreement done (1151 keeps onboarding_done; an exempt or waived person counts as done)
  v_onboarded := coalesce(sp.onboarding_done, false) or coalesce(sp.onboarding_exempt, false)
                 or ((app.academy_done(p_user) or app.academy_waived(p_user)) and (app.staff_agreement_signed(p_user) or sp.agreement_waived_at is not null));
  if not v_onboarded then why_not := 'Finish the academy and sign your staff agreement to switch your perks on.'; return; end if;
  if frozen then why_not := 'Your account is suspended, so your perks are frozen. They come back when your access is restored.'; return; end if;
  eligible := true;
end $$;

-- rental days a Sales person booked in a month: bookings they are credited with, confirmed in that month
create function app.staff_perk_month_days(p_user uuid, p_month date) returns integer
language sql stable security definer set search_path = public, app as $$
  select coalesce(sum(b.billable_days), 0)::integer from bookings b
   where b.sales_staff_id = p_user and b.confirmed_at is not null and b.test_at is null
     and b.status::text not in ('cancelled', 'declined', 'expired', 'no_show', 'requested', 'offered', 'tentative')
     and app.month_start(app.local_date(b.confirmed_at)) = app.month_start(p_month)
$$;
create function app.staff_perk_total_days(p_user uuid) returns integer
language sql stable security definer set search_path = public, app as $$
  select coalesce(sum(b.billable_days), 0)::integer from bookings b
   where b.sales_staff_id = p_user and b.confirmed_at is not null and b.test_at is null
     and b.status::text not in ('cancelled', 'declined', 'expired', 'no_show', 'requested', 'offered', 'tentative')
     and app.local_date(b.confirmed_at) >= (app.settings()).staff_perk_count_from
$$;
create function app.staff_perk_total_handovers(p_user uuid) returns integer
language sql stable security definer set search_path = public, app as $$
  select count(*)::integer from field_jobs j
   where j.assigned_to = p_user and j.status = 'done' and j.kind = any ((app.settings()).staff_perk_handover_kinds)
     and app.local_date(j.completed_at) >= (app.settings()).staff_perk_count_from
$$;
-- the tier in force: the better of last month's result and this month so far
create function app.staff_perk_tier(p_user uuid, p_now timestamptz default now()) returns text
language plpgsql stable security definer set search_path = public, app as $$
declare
  s program_settings := app.settings();
  m date := app.month_start(app.local_date(p_now));
  d integer := greatest(app.staff_perk_month_days(p_user, m), app.staff_perk_month_days(p_user, (m - interval '1 month')::date));
begin
  return case when d >= s.staff_perk_gold_days then 'gold' when d >= s.staff_perk_silver_days then 'silver' else 'member' end;
end $$;
create function app.staff_perk_bps(p_tier text) returns integer
language sql stable security definer set search_path = public, app as $$
  select case p_tier when 'gold' then s.staff_perk_gold_bps when 'silver' then s.staff_perk_silver_bps else s.staff_perk_base_bps end from app.settings() s
$$;
create function app.staff_perk_balance(p_user uuid, p_now timestamptz default now()) returns integer
language sql stable security definer set search_path = public, app as $$
  select coalesce(sum(d.days - d.used_days), 0)::integer from staff_free_days d where d.user_id = p_user and d.expires_at > p_now
$$;
create function app.staff_perk_renter(p_user uuid) returns uuid
language sql stable security definer set search_path = public, app as $$
  select r.id from renters r where r.user_id = p_user and r.merged_into is null order by r.created_at limit 1
$$;

-- one notice to a staff member about their rewards (in the portal, on the phone and by email, by their preferences)
create function app.staff_perk_notify(p_user uuid, p_key text, p_title text, p_text text, p_detail text default null) returns void
language plpgsql security definer set search_path = public, app as $$
declare v_first text;
begin
  select coalesce(nullif(btrim(u.greeting_name), ''), nullif(split_part(btrim(coalesce(u.full_name, '')), ' ', 1), ''), 'there') into v_first from users u where u.id = p_user;
  perform app.emit_event('staff_reward_update', 'user', p_user, jsonb_build_object('recipient_user_id', p_user, 'first_name', v_first,
    'reward_title', p_title, 'reward_text', p_text, 'reward_detail', coalesce(p_detail, '')), 'staff_reward_update:' || p_user || ':' || p_key);
end $$;

-- a staff member's earnings brought up to date: perks switched on, the discount code and its percentage, free days
-- earned, Gold's bonus day, the tier. Safe to call any time; each thing is given once.
create function app.staff_perk_sync(p_user uuid, p_now timestamptz default now()) returns void
language plpgsql security definer set search_path = public, app as $$
declare
  s program_settings := app.settings();
  f record;
  sp staff_profiles;
  pc promo_codes;
  v_tier text;
  v_bps integer;
  v_renter uuid := app.staff_perk_renter(p_user);
  v_month date := app.month_start(app.local_date(p_now));
  v_expires timestamptz := p_now + make_interval(months => s.staff_perk_expiry_months);
  v_n integer; v_have integer; i integer;
  v_rank constant text[] := array['member', 'silver', 'gold'];
begin
  select * into f from app.staff_perk_facts(p_user);
  if not f.member then return; end if;
  select * into sp from staff_profiles where user_id = p_user for update;
  select p.* into pc from staff_perk_codes c join promo_codes p on p.id = c.promo_code_id where c.user_id = p_user and c.kind = 'discount' and c.cancelled_at is null order by c.created_at desc limit 1;
  if not f.eligible then
    -- not (or no longer) eligible: the discount code is switched off; earned days stay and wait
    if pc.id is not null and pc.is_active then update promo_codes set is_active = false where id = pc.id; end if;
    return;
  end if;
  v_tier := app.staff_perk_tier(p_user, p_now);
  v_bps := app.staff_perk_bps(v_tier);
  if pc.id is null then
    insert into promo_codes (code, description, percent_bps, once_per_renter, renter_id, source, company_funded, valid_until)
    values (app.rewards_code('STAFF'), 'Staff rewards: your discount on your own rentals', v_bps, false, v_renter, 'staff_perk_discount', true, p_now + interval '1 year')
    returning * into pc;
    insert into staff_perk_codes (promo_code_id, user_id, kind) values (pc.id, p_user, 'discount');
  else
    update promo_codes set percent_bps = v_bps, is_active = true, renter_id = coalesce(renter_id, v_renter),
           valid_until = greatest(valid_until, p_now + interval '6 months')
     where id = pc.id and (percent_bps is distinct from v_bps or not is_active or (renter_id is null and v_renter is not null) or valid_until < p_now + interval '6 months');
  end if;
  if sp.perks_unlocked_at is null then
    update staff_profiles set perks_unlocked_at = p_now where user_id = p_user;
    perform app.staff_perk_notify(p_user, 'unlocked', 'Your staff perks are on',
      format('You now get %s off your own rentals, and you earn free rental days as you work.', app.fmt_pct(s.staff_perk_base_bps)),
      'Your code and your progress are on My rewards in your portal.');
  end if;
  -- free days earned
  if f.sales then
    v_n := app.staff_perk_total_days(p_user) / s.staff_perk_days_per_free_day;
    select count(*) into v_have from staff_free_days where user_id = p_user and source = 'sales_days';
    for i in v_have + 1 .. v_n loop
      insert into staff_free_days (user_id, source, seq, days, earned_at, expires_at) values (p_user, 'sales_days', i::text, 1, p_now, v_expires) on conflict do nothing;
      perform app.staff_perk_notify(p_user, 'sales_days:' || i, 'You earned a free rental day',
        format('You have booked %s rental days: that is 1 free rental day for you.', i * s.staff_perk_days_per_free_day),
        format('Use it by %s. Get your code on My rewards.', app.fmt_day(app.local_date(v_expires))));
    end loop;
  end if;
  if f.field then
    v_n := app.staff_perk_total_handovers(p_user) / s.staff_perk_handovers_per_free_day;
    select count(*) into v_have from staff_free_days where user_id = p_user and source = 'handovers';
    for i in v_have + 1 .. v_n loop
      insert into staff_free_days (user_id, source, seq, days, earned_at, expires_at) values (p_user, 'handovers', i::text, 1, p_now, v_expires) on conflict do nothing;
      perform app.staff_perk_notify(p_user, 'handovers:' || i, 'You earned a free rental day',
        format('You have completed %s handovers: that is 1 free rental day for you.', i * s.staff_perk_handovers_per_free_day),
        format('Use it by %s. Get your code on My rewards.', app.fmt_day(app.local_date(v_expires))));
    end loop;
  end if;
  -- Gold reached this month: the bonus day, once a month
  if f.sales and s.staff_perk_gold_bonus_days > 0 and app.staff_perk_month_days(p_user, v_month) >= s.staff_perk_gold_days then
    insert into staff_free_days (user_id, source, seq, days, earned_at, expires_at)
    values (p_user, 'gold_bonus', to_char(v_month, 'YYYYMM'), s.staff_perk_gold_bonus_days, p_now, v_expires) on conflict do nothing;
  end if;
  -- the tier: told once when it rises (in a month); kept for the card
  if sp.perks_tier is distinct from v_tier or sp.perks_tier_month is distinct from v_month then
    if array_position(v_rank, v_tier) > array_position(v_rank, case when sp.perks_tier_month = v_month then sp.perks_tier else 'member' end)
       and app.staff_perk_month_days(p_user, v_month) >= s.staff_perk_silver_days then
      perform app.staff_perk_notify(p_user, 'tier:' || v_tier || ':' || to_char(v_month, 'YYYYMM'),
        case v_tier when 'gold' then 'You reached Gold' else 'You reached Silver' end,
        format('%s rental days booked this month. Your discount on your own rentals is now %s%s.', app.staff_perk_month_days(p_user, v_month), app.fmt_pct(v_bps),
               case when v_tier = 'gold' and s.staff_perk_gold_bonus_days > 0 then format(', and you got %s bonus free day%s', s.staff_perk_gold_bonus_days, case when s.staff_perk_gold_bonus_days = 1 then '' else 's' end) else '' end),
        'Your tier lasts through next month.');
    end if;
    update staff_profiles set perks_tier = v_tier, perks_tier_month = v_month where user_id = p_user;
  end if;
end $$;

-- a booking confirmed for a Sales person, a handover done: their rewards follow. Never in the way of the booking or the job.
create function app.staff_perk_after_work() returns trigger
language plpgsql security definer set search_path = public, app as $$
declare v_user uuid;
begin
  v_user := (to_jsonb(new) ->> case tg_table_name when 'bookings' then 'sales_staff_id' else 'assigned_to' end)::uuid;
  if v_user is null then return null; end if;
  begin
    perform app.staff_perk_sync(v_user);
  exception when others then
    raise warning 'staff rewards not brought up to date for %: %', v_user, sqlerrm;
  end;
  return null;
end $$;
create trigger bookings_staff_perks after update of status, sales_staff_id on bookings for each row
  when (new.sales_staff_id is not null and new.status::text in ('confirmed', 'on_rent', 'returned', 'closed', 'cancelled', 'no_show')) execute function app.staff_perk_after_work();
create trigger field_jobs_staff_perks after update of status on field_jobs for each row
  when (new.status = 'done' and old.status is distinct from new.status) execute function app.staff_perk_after_work();
-- access restored, the agreement signed, the academy passed: onboarding_done or the lock changes
create function app.staff_perk_after_profile() returns trigger
language plpgsql security definer set search_path = public, app as $$
begin
  begin
    perform app.staff_perk_sync(new.user_id);
  exception when others then
    raise warning 'staff rewards not brought up to date for %: %', new.user_id, sqlerrm;
  end;
  return null;
end $$;
create trigger staff_profiles_perks after update of onboarding_done, inactive_locked_at, perks_eligible, sales_work_mode, location_country, is_active on staff_profiles
  for each row execute function app.staff_perk_after_profile();

-- ================================================================ the job: everyone up to date, days about to end, the top seller
create function app.job_staff_perks(p_now timestamptz default now()) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  s program_settings := app.settings();
  r record;
  v_last date := (app.month_start(app.local_date(p_now)) - interval '1 month')::date;
  v_key text := to_char(v_last, 'YYYYMM');
  v_top uuid; v_days integer; v_name text;
  v_n integer := 0; v_soon integer := 0;
begin
  if not s.staff_perk_enabled then return jsonb_build_object('enabled', false); end if;
  for r in select sp.user_id from staff_profiles sp where sp.is_active loop
    begin perform app.staff_perk_sync(r.user_id, p_now); v_n := v_n + 1;
    exception when others then raise warning 'staff rewards: % not synced: %', r.user_id, sqlerrm; end;
  end loop;
  -- a free day about to end: one reminder
  for r in select d.id, d.user_id, d.days - d.used_days as left_days, d.expires_at from staff_free_days d
            where d.expiry_noticed_at is null and d.used_days < d.days and d.expires_at > p_now
              and d.expires_at <= p_now + make_interval(days => s.staff_perk_expiry_notice_days) for update skip locked loop
    update staff_free_days set expiry_noticed_at = p_now where id = r.id;
    if (select f.eligible from app.staff_perk_facts(r.user_id) f) then
      perform app.staff_perk_notify(r.user_id, 'ending:' || r.id, format('%s free rental day%s about to end', r.left_days, case when r.left_days = 1 then ' is' else 's are' end),
        format('Use %s by %s.', case when r.left_days = 1 then 'it' else 'them' end, app.fmt_day(app.local_date(r.expires_at))), 'Get your code on My rewards.');
      v_soon := v_soon + 1;
    end if;
  end loop;
  -- last month's top seller: the free weekend, once a month, to one person
  if s.staff_perk_top_seller_days > 0 and not exists (select 1 from staff_free_days where source = 'top_seller' and seq = v_key) then
    select x.user_id, x.d into v_top, v_days from (
      select sp.user_id, app.staff_perk_month_days(sp.user_id, v_last) d from staff_profiles sp
       where sp.is_active and 'sales' = any (sp.functions) and not app.staff_is_test(sp.user_id) and (select f.eligible from app.staff_perk_facts(sp.user_id) f)) x
     where x.d > 0 order by x.d desc, x.user_id limit 1;
    if v_top is not null then
      insert into staff_free_days (user_id, source, seq, days, earned_at, expires_at, note)
      values (v_top, 'top_seller', v_key, s.staff_perk_top_seller_days, p_now, p_now + make_interval(months => s.staff_perk_expiry_months), format('Top seller of %s: %s rental days', to_char(v_last, 'FMMonth YYYY'), v_days))
      on conflict do nothing;
      select coalesce(u.full_name, u.email) into v_name from users u where u.id = v_top;
      perform app.staff_perk_notify(v_top, 'top:' || v_key, format('Top seller of %s: a free weekend', to_char(v_last, 'FMMonth')),
        format('You booked %s rental days in %s, more than anyone. You have %s free rental days for a weekend.', v_days, to_char(v_last, 'FMMonth'), s.staff_perk_top_seller_days), 'Get your code on My rewards.');
      perform app.staff_alert('staff_top_seller', 'user', v_top, v_key, left(format('Top seller of %s: %s', to_char(v_last, 'FMMonth'), v_name), 140),
        format('%s rental days booked. %s free days were added to their rewards.', v_days, s.staff_perk_top_seller_days), jsonb_build_object('path_admin', '/admin/staff?tab=rewards'));
    end if;
  end if;
  return jsonb_build_object('synced', v_n, 'ending_soon', v_soon, 'top_seller', v_top);
end $$;

-- ================================================================ free-day codes
-- p: {days}. The days come off the earned days that end first; the code ends when the first of them does.
create function app.staff_perk_code_issue(p_user uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  f record;
  v_days integer := coalesce((p ->> 'days')::integer, 1);
  v_left integer := v_days;
  v_take integer;
  v_until timestamptz;
  v_lots jsonb := '[]'::jsonb;
  d staff_free_days;
  pc promo_codes;
begin
  select * into f from app.staff_perk_facts(p_user);
  if not f.eligible then raise exception '%', coalesce(f.why_not, 'Staff rewards are not on for this account') using errcode = '42501'; end if;
  if v_days < 1 or v_days > 7 then raise exception 'Choose 1 to 7 free days for one rental' using errcode = '22023'; end if;
  if app.staff_perk_balance(p_user) < v_days then raise exception 'You have % free rental day% to use', app.staff_perk_balance(p_user), case when app.staff_perk_balance(p_user) = 1 then '' else 's' end using errcode = '23514'; end if;
  if app.staff_perk_renter(p_user) is null then raise exception 'Create your renter profile first: open the site, sign in and send your first request' using errcode = '23514'; end if;
  perform app.rw_act_as(p_user);
  for d in select * from staff_free_days x where x.user_id = p_user and x.expires_at > now() and x.used_days < x.days order by x.expires_at, x.earned_at for update loop
    exit when v_left <= 0;
    v_take := least(d.days - d.used_days, v_left);
    update staff_free_days set used_days = used_days + v_take where id = d.id;
    v_lots := v_lots || jsonb_build_object('id', d.id, 'days', v_take);
    v_until := least(coalesce(v_until, d.expires_at), d.expires_at);
    v_left := v_left - v_take;
  end loop;
  insert into promo_codes (code, description, free_days, once_per_renter, max_uses, renter_id, source, company_funded, valid_until)
  values (app.rewards_code('FREE'), format('Staff rewards: %s free rental day%s', v_days, case when v_days = 1 then '' else 's' end), v_days, true, 1, app.staff_perk_renter(p_user), 'staff_perk_free_day', true,
          greatest(v_until, now() + interval '1 hour'))
  returning * into pc;
  insert into staff_perk_codes (promo_code_id, user_id, kind, days, lots) values (pc.id, p_user, 'free_days', v_days, v_lots);
  return app.staff_perk_state(p_user) || jsonb_build_object('issued', pc.code);
end $$;

-- p: {code}. An unused free-day code is cancelled and its days go back.
create function app.staff_perk_code_cancel(p_user uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  c staff_perk_codes;
  pc promo_codes;
  l jsonb;
begin
  select p2.* into pc from promo_codes p2 where p2.code = upper(btrim(coalesce(p ->> 'code', '')));
  select * into c from staff_perk_codes where promo_code_id = pc.id and user_id = p_user and kind = 'free_days' for update;
  if c.promo_code_id is null then raise exception 'Unknown code' using errcode = 'P0002'; end if;
  if c.cancelled_at is not null then raise exception 'This code was already cancelled' using errcode = '23514'; end if;
  if exists (select 1 from promo_redemptions r where r.promo_code_id = pc.id and r.status in ('applied', 'redeemed')) then
    raise exception 'This code is on a booking. Take it off the request first, or keep it.' using errcode = '23514';
  end if;
  perform app.rw_act_as(p_user);
  update promo_codes set is_active = false where id = pc.id;
  update staff_perk_codes set cancelled_at = now() where promo_code_id = pc.id;
  for l in select * from jsonb_array_elements(c.lots) loop
    update staff_free_days set used_days = greatest(used_days - (l ->> 'days')::integer, 0) where id = (l ->> 'id')::uuid;
  end loop;
  return app.staff_perk_state(p_user);
end $$;

-- ================================================================ the card
create function app.staff_perk_state(p_user uuid) returns jsonb
language plpgsql stable security definer set search_path = public, app as $$
declare
  s program_settings := app.settings();
  f record;
  v_month date := app.month_start(app.today());
  v_this integer; v_last integer; v_tier text; v_total integer; v_hand integer;
  pc promo_codes;
begin
  select * into f from app.staff_perk_facts(p_user);
  if not f.member then return jsonb_build_object('member', false, 'eligible', false, 'why_not', f.why_not); end if;
  v_this := app.staff_perk_month_days(p_user, v_month);
  v_last := app.staff_perk_month_days(p_user, (v_month - interval '1 month')::date);
  v_tier := app.staff_perk_tier(p_user);
  v_total := app.staff_perk_total_days(p_user);
  v_hand := app.staff_perk_total_handovers(p_user);
  select p.* into pc from staff_perk_codes c join promo_codes p on p.id = c.promo_code_id where c.user_id = p_user and c.kind = 'discount' and c.cancelled_at is null order by c.created_at desc limit 1;
  return jsonb_build_object(
    'member', true, 'eligible', f.eligible, 'frozen', f.frozen, 'why_not', f.why_not, 'sales', f.sales, 'field', f.field,
    'has_renter', app.staff_perk_renter(p_user) is not null,
    'discount', jsonb_build_object('bps', app.staff_perk_bps(v_tier), 'code', case when f.eligible and pc.is_active then pc.code end, 'tier', v_tier,
                                   'tier_name', case v_tier when 'gold' then 'Gold' when 'silver' then 'Silver' else 'Member' end),
    'tiers', jsonb_build_array(
      jsonb_build_object('code', 'member', 'name', 'Member', 'days', 0, 'bps', s.staff_perk_base_bps),
      jsonb_build_object('code', 'silver', 'name', 'Silver', 'days', s.staff_perk_silver_days, 'bps', s.staff_perk_silver_bps),
      jsonb_build_object('code', 'gold', 'name', 'Gold', 'days', s.staff_perk_gold_days, 'bps', s.staff_perk_gold_bps, 'bonus_days', s.staff_perk_gold_bonus_days)),
    'month', jsonb_build_object('label', to_char(v_month, 'FMMonth'), 'days', v_this, 'last_days', v_last,
       'next', case when v_this < s.staff_perk_silver_days then jsonb_build_object('name', 'Silver', 'at', s.staff_perk_silver_days, 'left', s.staff_perk_silver_days - v_this)
                    when v_this < s.staff_perk_gold_days then jsonb_build_object('name', 'Gold', 'at', s.staff_perk_gold_days, 'left', s.staff_perk_gold_days - v_this) end),
    'progress', jsonb_strip_nulls(jsonb_build_object(
      'sales', case when f.sales then jsonb_build_object('label', 'Rental days booked', 'per', s.staff_perk_days_per_free_day, 'total', v_total,
                 'toward', v_total % s.staff_perk_days_per_free_day, 'left', s.staff_perk_days_per_free_day - v_total % s.staff_perk_days_per_free_day) end,
      'field', case when f.field then jsonb_build_object('label', 'Handovers completed', 'per', s.staff_perk_handovers_per_free_day, 'total', v_hand,
                 'toward', v_hand % s.staff_perk_handovers_per_free_day, 'left', s.staff_perk_handovers_per_free_day - v_hand % s.staff_perk_handovers_per_free_day) end)),
    'free_days', jsonb_build_object(
      'balance', app.staff_perk_balance(p_user),
      'lots', (select coalesce(jsonb_agg(jsonb_build_object('days', d.days, 'left', d.days - d.used_days, 'expires_on', app.local_date(d.expires_at), 'earned_on', app.local_date(d.earned_at),
                 'source', case d.source when 'sales_days' then 'Rental days booked' when 'handovers' then 'Handovers' when 'gold_bonus' then 'Gold bonus' when 'top_seller' then 'Top seller of the month' else coalesce(d.note, 'Added by an Admin') end) order by d.expires_at), '[]'::jsonb)
                 from staff_free_days d where d.user_id = p_user and d.expires_at > now() - interval '30 days'),
      'codes', (select coalesce(jsonb_agg(jsonb_build_object('code', p.code, 'days', c.days, 'valid_until', p.valid_until, 'status', app.promo_status(p),
                 'booking_number', (select b.booking_number from promo_redemptions r join bookings b on b.id = r.booking_id where r.promo_code_id = p.id and r.status in ('applied', 'redeemed') limit 1)) order by c.created_at desc), '[]'::jsonb)
                 from staff_perk_codes c join promo_codes p on p.id = c.promo_code_id where c.user_id = p_user and c.kind = 'free_days' and c.cancelled_at is null and c.created_at > now() - interval '1 year')),
    'top_seller_days', s.staff_perk_top_seller_days,
    'rules', jsonb_build_array(
      'You must be the primary driver. Your licence check, the rental agreement and the deposit are the same as for any renter.',
      'Not on exotic cars or partner cars.',
      format('Last minute only: the pickup is within %s hours of booking, and never on dates a renter has asked for.', s.staff_perk_max_ahead_hours),
      format('A free day ends %s months after you earn it.', s.staff_perk_expiry_months),
      'Free days go on CarmaCars'' own cars first. One code a rental.',
      'Perks are yours only: not for anyone else to use, and not for sale. A suspended account''s perks are frozen.'));
end $$;

-- ================================================================ the rules, where every code is checked
alter function app.promo_code_problem(text, uuid, uuid, timestamptz) rename to promo_code_problem_pre3261;
create function app.promo_code_problem(p_code text, p_renter uuid, p_booking uuid default null, p_at timestamptz default now()) returns text
language plpgsql stable security definer set search_path = public, app as $$
declare
  s program_settings := app.settings();
  pc promo_codes;
  c staff_perk_codes;
  f record;
  b bookings;
  v vehicles;
  v_other text;
begin
  select * into pc from promo_codes where code = upper(btrim(coalesce(p_code, '')));
  if pc.id is null or pc.source not in ('staff_perk_discount', 'staff_perk_free_day') then
    return app.promo_code_problem_pre3261(p_code, p_renter, p_booking, p_at);
  end if;
  select * into c from staff_perk_codes where promo_code_id = pc.id;
  if c.user_id is null or c.cancelled_at is not null then return 'This code is no longer active'; end if;
  -- the staff member is the primary driver: the code works on their own renter account only
  if not exists (select 1 from renters r where r.id = p_renter and r.user_id = c.user_id) then
    return 'A staff perk is for a rental you drive yourself: sign in with your own account';
  end if;
  select * into f from app.staff_perk_facts(c.user_id);
  if not f.eligible then return coalesce(f.why_not, 'Staff rewards are not on for this account'); end if;
  if p_booking is not null then
    select * into b from bookings where id = p_booking;
    select * into v from vehicles where id = b.vehicle_id;
    if v.class::text = 'exotic' or exists (select 1 from vehicle_class_links l where l.vehicle_id = v.id and l.class_code = 'exotic') then
      return 'Staff perks are not for exotic cars';
    end if;
    if v.supply_type = 'partner' then return 'Staff perks are not for partner cars'; end if;
    if b.pickup_at > coalesce(b.requested_at, b.created_at, p_at) + make_interval(hours => s.staff_perk_max_ahead_hours) then
      return format('Staff perks are for last-minute rentals: pick up within %s hours of booking, so a paying renter is never blocked', s.staff_perk_max_ahead_hours);
    end if;
    if exists (select 1 from bookings o where o.vehicle_id = b.vehicle_id and o.id <> b.id and o.renter_id is distinct from b.renter_id
                 and o.status::text in ('requested', 'offered', 'pending_payment') and o.pickup_at < b.return_at and o.return_at > b.pickup_at) then
      return 'A renter has asked for this car on these dates. Choose another car or other dates';
    end if;
    -- a free day goes on a CarmaCars or shareholder car first
    if pc.source = 'staff_perk_free_day' and v.supply_type = 'program_owner' and not v.is_shareholder_owned
       and not coalesce((select o.is_shareholder from owners o where o.id = v.owner_id), false) then
      select app.vehicle_name(x.id) into v_other from vehicles x left join owners o on o.id = x.owner_id
       where (x.supply_type = 'company' or x.is_shareholder_owned or coalesce(o.is_shareholder, false)) and x.class::text <> 'exotic' and x.id <> v.id
         and x.status::text = 'available' and app.vehicle_bookable(x.id) and app.vehicle_is_available(x.id, b.pickup_at, b.return_at)
       order by x.created_seq limit 1;
      if v_other is not null then return format('Free days go on a CarmaCars car first: the %s is free on these dates', v_other); end if;
    end if;
  end if;
  return app.promo_code_problem_pre3261(p_code, p_renter, p_booking, p_at);
end $$;
select pg_temp.copy_grants('app.promo_code_problem(text, uuid, uuid, timestamptz)'::regprocedure, 'app.promo_code_problem_pre3261(text, uuid, uuid, timestamptz)'::regprocedure);

-- ================================================================ the books: a perk used is a staff benefit expense
create function app.reward_post() returns trigger
language plpgsql security definer set search_path = public, app as $$
declare
  pc promo_codes;
  b bookings;
  x reward_postings;
  v_kind text;
  v_who uuid;
  v_owner uuid;
  v_exp uuid;
begin
  select * into pc from promo_codes where id = new.promo_code_id;
  v_kind := case when pc.source like 'staff_perk_%' then 'staff_benefit' when pc.source like 'owner_reward_%' then 'owner_reward' end;
  if v_kind is null then return null; end if;
  select * into x from reward_postings where redemption_id = new.id;
  if new.status = 'redeemed' and new.discount_cents > 0 and x.redemption_id is null then
    select * into b from bookings where id = new.booking_id;
    if v_kind = 'staff_benefit' then select c.user_id into v_who from staff_perk_codes c where c.promo_code_id = pc.id;
    else v_owner := nullif(current_setting('app.reward_owner', true), '')::uuid; end if;
    if v_kind = 'owner_reward' and v_owner is null then
      begin execute 'select owner_id from owner_reward_codes where promo_code_id = $1' into v_owner using pc.id; exception when undefined_table then v_owner := null; end;
    end if;
    insert into company_expenses (expense_on, category, description, amount_cents, vehicle_id, owner_id, staff_user_id)
    values (app.today(), v_kind, left(format('%s, booking %s (code %s)', coalesce(pc.description, 'Reward'), b.booking_number, pc.code), 300), new.discount_cents, b.vehicle_id, v_owner, v_who)
    returning id into v_exp;
    insert into reward_postings (redemption_id, kind, expense_id, amount_cents) values (new.id, v_kind, v_exp, new.discount_cents);
  elsif new.status = 'released' and x.redemption_id is not null then
    update company_expenses set voided_at = now(), void_reason = 'The reward code came off the booking' where id = x.expense_id and voided_at is null;
    delete from reward_postings where redemption_id = new.id;
  end if;
  return null;
exception when others then
  raise warning 'reward not posted to the books for redemption %: %', new.id, sqlerrm;
  return null;
end $$;
create trigger promo_redemptions_reward_post after insert or update of status, discount_cents on promo_redemptions for each row execute function app.reward_post();

-- a request made with a staff perk: the Admins see it (it is handled like any request)
create function app.staff_perk_applied() returns trigger
language plpgsql security definer set search_path = public, app as $$
declare pc promo_codes; b bookings; v_name text;
begin
  if new.status <> 'applied' then return null; end if;
  select * into pc from promo_codes where id = new.promo_code_id;
  if pc.source not like 'staff_perk_%' then return null; end if;
  select * into b from bookings where id = new.booking_id;
  select coalesce(u.full_name, u.email) into v_name from staff_perk_codes c join users u on u.id = c.user_id where c.promo_code_id = pc.id;
  perform app.staff_alert('staff_perk_booking', 'booking', b.id, 'perk:' || pc.id, left(format('Staff perk on %s: %s', b.booking_number, v_name), 140),
    left(format('%s. %s, pickup %s.', coalesce(pc.description, 'Staff rewards'), app.vehicle_name(b.vehicle_id), app.fmt_at(b.pickup_at)), 240),
    jsonb_build_object('path_admin', '/admin/bookings/' || b.booking_number, 'booking_id', b.id));
  return null;
exception when others then
  raise warning 'staff perk alert not sent: %', sqlerrm;
  return null;
end $$;
create trigger promo_redemptions_staff_perk after insert or update of promo_code_id, status on promo_redemptions for each row execute function app.staff_perk_applied();

-- ================================================================ the Admin's view and changes
create function app.staff_perks_admin(p_by uuid, p jsonb) returns jsonb
language plpgsql stable security definer set search_path = public, app as $$
declare
  s program_settings := app.settings();
  v_month date := app.month_start(app.today());
begin
  if not app.user_is_admin(p_by) then raise exception 'Not permitted' using errcode = '42501'; end if;
  return jsonb_build_object(
    'settings', jsonb_build_object('enabled', s.staff_perk_enabled, 'base_bps', s.staff_perk_base_bps, 'days_per_free_day', s.staff_perk_days_per_free_day,
      'handovers_per_free_day', s.staff_perk_handovers_per_free_day, 'silver_days', s.staff_perk_silver_days, 'silver_bps', s.staff_perk_silver_bps, 'gold_days', s.staff_perk_gold_days,
      'gold_bps', s.staff_perk_gold_bps, 'gold_bonus_days', s.staff_perk_gold_bonus_days, 'top_seller_days', s.staff_perk_top_seller_days, 'max_ahead_hours', s.staff_perk_max_ahead_hours,
      'expiry_months', s.staff_perk_expiry_months, 'count_from', s.staff_perk_count_from),
    'month', to_char(v_month, 'FMMonth YYYY'),
    'cost_month_cents', (select coalesce(sum(e.amount_cents), 0) from company_expenses e where e.category = 'staff_benefit' and e.voided_at is null and app.month_start(e.expense_on) = v_month),
    'cost_year_cents', (select coalesce(sum(e.amount_cents), 0) from company_expenses e where e.category = 'staff_benefit' and e.voided_at is null and e.expense_on >= date_trunc('year', app.today())::date),
    'staff', (select coalesce(jsonb_agg(jsonb_build_object('user_id', sp.user_id, 'name', coalesce(u.full_name, u.email), 'functions', to_jsonb(sp.functions), 'eligible', f.eligible, 'frozen', f.frozen, 'why_not', f.why_not,
                'override', sp.perks_eligible, 'tier', app.staff_perk_tier(sp.user_id), 'month_days', app.staff_perk_month_days(sp.user_id, v_month), 'total_days', app.staff_perk_total_days(sp.user_id),
                'handovers', app.staff_perk_total_handovers(sp.user_id), 'free_days', app.staff_perk_balance(sp.user_id),
                'used_cents', (select coalesce(sum(e.amount_cents), 0) from company_expenses e where e.category = 'staff_benefit' and e.voided_at is null and e.staff_user_id = sp.user_id))
                order by f.eligible desc, u.full_name), '[]'::jsonb)
               from staff_profiles sp join users u on u.id = sp.user_id cross join lateral app.staff_perk_facts(sp.user_id) f where sp.is_active and f.member),
    'used', (select coalesce(jsonb_agg(to_jsonb(x) order by x.expense_on desc), '[]'::jsonb) from (
               select e.expense_on, e.description, e.amount_cents, coalesce(u.full_name, u.email) as name from company_expenses e left join users u on u.id = e.staff_user_id
                where e.category = 'staff_benefit' and e.voided_at is null order by e.expense_on desc, e.created_at desc limit 50) x));
end $$;

-- staff_perk_set {user, eligible: true | false | null, note}; staff_perk_adjust {user, days, note}
create function app.staff_perks_admin_do(p_by uuid, p_name text, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  s program_settings := app.settings();
  v_user uuid := (p ->> 'user')::uuid;
  v_days integer := coalesce((p ->> 'days')::integer, 0);
begin
  if not app.user_is_admin(p_by) then raise exception 'Not permitted' using errcode = '42501'; end if;
  if not exists (select 1 from staff_profiles where user_id = v_user) then raise exception 'Unknown staff member' using errcode = 'P0002'; end if;
  perform app.rw_act_as(p_by);
  if p_name = 'staff_perk_set' then
    update staff_profiles set perks_eligible = case p ->> 'eligible' when 'yes' then true when 'no' then false when 'true' then true when 'false' then false else null end,
           perks_note = nullif(btrim(coalesce(p ->> 'note', '')), '') where user_id = v_user;
  elsif p_name = 'staff_perk_adjust' then
    if v_days < 1 or v_days > 7 then raise exception 'Add 1 to 7 free days at a time' using errcode = '22023'; end if;
    if nullif(btrim(coalesce(p ->> 'note', '')), '') is null then raise exception 'Say why (the staff member sees it)' using errcode = '22023'; end if;
    insert into staff_free_days (user_id, source, seq, days, expires_at, note, created_by)
    values (v_user, 'adjust', gen_random_uuid()::text, v_days, now() + make_interval(months => s.staff_perk_expiry_months), left(btrim(p ->> 'note'), 300), p_by);
    perform app.staff_perk_notify(v_user, 'adjust:' || gen_random_uuid(), format('%s free rental day%s added', v_days, case when v_days = 1 then '' else 's' end), btrim(p ->> 'note'), 'Get your code on My rewards.');
  else raise exception 'Unknown action' using errcode = '22023';
  end if;
  perform app.staff_perk_sync(v_user);
  return jsonb_build_object('ok', true);
end $$;

insert into notification_catalogue (code, audience, category, subject, preheader, timing, trigger_text, link_path, variables, template_html, template_text, emitted_by, no_text, pref_type, priority, push_topic)
values ('staff_reward_update', 'staff_field', 'transactional', '{{reward_title}}', '{{reward_text}}', 'Immediate, once per event',
        'Staff rewards (3261): perks switched on, a free rental day earned, a tier reached, top seller of the month, a free day about to end, days added by an Admin.',
        '/staff/rewards',
        '[{"name":"first_name","type":"string"},{"name":"reward_title","type":"string"},{"name":"reward_text","type":"string"},{"name":"reward_detail","type":"string"}]'::jsonb,
        'templates/staff_reward_update.html', 'templates/staff_reward_update.txt', 'app.staff_perk_notify (3261)', true, 'staff_rewards', 4, 'alerts')
on conflict (code) do nothing;

do $$
begin
  if exists (select 1 from pg_extension where extname = 'pg_cron') then
    perform cron.schedule('carmacars-staff-perks', '20 * * * *', $q$select app.job_staff_perks()$q$);
  end if;
end $$;

do $$
declare f record;
begin
  for f in select p.oid::regprocedure as sig from pg_proc p join pg_namespace n on n.oid = p.pronamespace
            where n.nspname in ('app', 'public') and (p.proname ~ '^(staff_perk|staff_perks_|job_staff_perks|reward_post)' or p.proname ~ '_pre3261$')
  loop
    execute format('revoke all on function %s from public, anon, authenticated', f.sig);
    execute format('grant execute on function %s to service_role', f.sig);
  end loop;
end $$;
