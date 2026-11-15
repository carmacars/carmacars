-- 3000 (release 48): CarmaCars Rewards talks to the renter (docs/changes/2026-11-14-r48-rewards-notices.md).
--
-- The owner, Nov 14: "introduce some automated emails and notifications regarding the rewards program". Until now the
-- program (0214, 1305, 2421) sent only the 30-day expiry reminder. Every notice goes through the notification pipeline
-- (app_events, notification_outbox, the in-app notice in the renter portal, app.notify_route and the channel policy of
-- 2971: none is urgent, so email once email is ready for production, a text only when there is no email). Each has its
-- switch in Admin > Settings > Rewards (notification_catalogue.is_enabled, on by default) with its count of the last
-- 30 days, and an Admin previews each email there. Every event has its own dedupe key, so nothing goes twice.
--   renter_rewards_welcome         the account is made or the first booking confirmed, whichever is first (once)
--   renter_rewards_points          points earned (one email for everything earned in one go; never a follow or an adjustment)
--   renter_rewards_tier_up         a higher tier, with its perks
--   renter_rewards_free_day        the Black tier's free day code is made: a link that books with it
--   renter_rewards_near_tier       marketing: two days after a rental, within 20% of the next tier
--   renter_rewards_waiting         marketing: 30 days after the last rental with points or a free day waiting (60 days apart)
--   renter_rewards_expiring_7d     7 days before the points end (after the 30-day reminder of 0214)
--   renter_rewards_free_day_ending 30 and 7 days before an unused free day code ends
--   renter_rewards_statement       marketing: the 1st of each month, for a balance or the month's activity
--   renter_rewards_birthday        marketing: 14 days before the birthday, for a tier with a birthday reward
--   renter_rewards_holiday         marketing: 10 days before each holiday weekend, for a tier with a holiday reward
-- Marketing notices carry the unsubscribe link and go only while the renter has not unsubscribed (implied consent); the
-- others are transactional. The suppression list, the outbox and a booking's Do not email are respected.
-- rewards_settings.notices_enabled switches every one off at once (the test suites before 99 run with it off).
-- Migration 3001 carries the birthday and holiday rewards in the price.
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

-- ================================================================ 1. settings
alter table rewards_settings
  add column if not exists notices_enabled boolean not null default true,
  add column if not exists notice_near_tier_pct integer not null default 20 check (notice_near_tier_pct between 1 and 90),
  add column if not exists notice_near_tier_hours integer not null default 48 check (notice_near_tier_hours between 0 and 720),
  add column if not exists notice_waiting_days integer not null default 30 check (notice_waiting_days between 7 and 365),
  add column if not exists notice_waiting_every_days integer not null default 60 check (notice_waiting_every_days between 14 and 365);
comment on column rewards_settings.notices_enabled is 'r48 (3000): the Rewards emails and notices to renters, all at once. Each one also has its own switch (notification_catalogue.is_enabled).';
comment on column rewards_settings.notice_near_tier_pct is 'r48 (3000): "You are X points from <tier>" after a rental, when the points still needed are at most this percent of the tier.';
comment on column rewards_settings.notice_near_tier_hours is 'r48 (3000): hours after the rental closes before "You are X points from <tier>" goes.';
comment on column rewards_settings.notice_waiting_days is 'r48 (3000): "Your points are waiting" this many days after the last completed rental.';
comment on column rewards_settings.notice_waiting_every_days is 'r48 (3000): "Your points are waiting" at most once in this many days.';

alter table reward_accounts
  add column if not exists reminded_7d_for timestamptz,
  add column if not exists waiting_sent_at timestamptz;
comment on column reward_accounts.reminded_7d_for is 'r48 (3000): the last-activity time the 7-day expiry reminder was sent for.';
comment on column reward_accounts.waiting_sent_at is 'r48 (3000): when "Your points are waiting" last went.';

create function app.rewards_notice_codes() returns text[]
language sql immutable as $$
  select array['renter_rewards_welcome', 'renter_rewards_points', 'renter_rewards_tier_up', 'renter_rewards_free_day', 'renter_rewards_near_tier',
               'renter_rewards_waiting', 'renter_rewards_expiring_7d', 'renter_rewards_free_day_ending', 'renter_rewards_statement',
               'renter_rewards_birthday', 'renter_rewards_holiday']
$$;

-- may this notice be emitted now? Rewards on, its notices on, and its own switch on
create function app.rewards_notice_on(p_code text) returns boolean
language sql stable security definer set search_path = public, app as $$
  select coalesce((app.rewards()).enabled, false) and coalesce((app.rewards()).notices_enabled, false)
     and coalesce((select c.is_enabled from notification_catalogue c where c.code = p_code), false)
$$;

-- a renter we may write to about Rewards: not blocked, not merged away
create function app.rewards_notice_renter_ok(p_renter uuid) returns boolean
language sql stable security definer set search_path = public, app as $$
  select exists (select 1 from renters r where r.id = p_renter and not coalesce(r.is_blocked, false) and r.merged_into is null)
$$;

create function app.rewards_notice_emit(p_code text, p_renter uuid, p_disc text, p_payload jsonb default '{}'::jsonb) returns bigint
language plpgsql security definer set search_path = public, app as $$
begin
  if p_renter is null or not app.rewards_notice_on(p_code) or not app.rewards_notice_renter_ok(p_renter) then return null; end if;
  return app.emit_event(p_code, 'renter', p_renter, coalesce(p_payload, '{}'::jsonb) || jsonb_build_object('renter_id', p_renter),
                        p_code || ':' || p_renter || ':' || p_disc);
end $$;

create function app.rewards_fmt_points(p integer) returns text
language sql immutable as $$ select to_char(coalesce(p, 0), 'FM999,999,990') $$;

-- the values every Rewards email may use, read when the notice is processed (so the balance is the one of the moment)
create function app.rewards_notice_values(p_renter uuid) returns jsonb
language plpgsql stable security definer set search_path = public, app as $$
declare
  s rewards_settings := app.rewards();
  v_bal integer := app.rewards_balance(p_renter);
  v_pts integer := app.rewards_points_12m(p_renter);
  t reward_tiers := app.rewards_tier_of(p_renter);
  nt reward_tiers;
  v_perk text;
  fd promo_codes;
  v_base text := rtrim(coalesce((app.settings()).notify_base_url, 'https://carmacars.ca'), '/');
begin
  if p_renter is null then return '{}'::jsonb; end if;
  select * into nt from reward_tiers x where x.active and x.code <> 'member' and x.min_points > v_pts order by x.min_points limit 1;
  if nt.code is not null then
    select k.label into v_perk from reward_tier_perks k where k.tier_code = nt.code and k.enabled order by k.sort limit 1;
  end if;
  select pc.* into fd from promo_codes pc
   where pc.renter_id = p_renter and pc.source = 'rewards_free_day' and pc.is_active and (pc.valid_until is null or pc.valid_until > now())
     and not exists (select 1 from promo_redemptions r where r.promo_code_id = pc.id and r.status in ('applied', 'redeemed'))
   order by pc.created_at desc limit 1;
  return jsonb_build_object(
    'points_balance', app.rewards_fmt_points(v_bal),
    'points_value', to_char(floor(greatest(v_bal, 0) * s.point_value_cents) / 100.0, 'FM$999,999,990.00'),
    'points_12m', app.rewards_fmt_points(v_pts),
    'tier_name', case when t.code is null or t.code = 'member' then 'Member' else t.name end,
    'has_next_tier', nt.code is not null, 'next_tier', coalesce(nt.name, ''),
    'points_to_next', case when nt.code is not null then app.rewards_fmt_points(nt.min_points - v_pts) else '' end,
    'has_next_perk', v_perk is not null, 'next_perk', coalesce(v_perk, ''),
    'min_redeem_points', app.rewards_fmt_points(s.min_redeem_points), 'can_redeem', v_bal >= s.min_redeem_points,
    'rewards_url', v_base || '/account/rewards',
    'has_free_day', fd.id is not null, 'free_day_code', coalesce(fd.code, ''),
    'free_day_until', coalesce(app.fmt_date(fd.valid_until), ''),
    'book_url', case when fd.id is not null then v_base || '/book?promo=' || fd.code else v_base || '/cars' end);
end $$;

-- ================================================================ 2. welcome: the account, or the first confirmed booking
create function app.rewards_welcome(p_renter uuid) returns bigint
language plpgsql security definer set search_path = public, app as $$
begin
  if p_renter is null or not app.rewards_notice_on('renter_rewards_welcome') then return null; end if;
  perform app.rewards_account(p_renter);
  return app.emit_event('renter_rewards_welcome', 'renter', p_renter, jsonb_build_object('renter_id', p_renter), 'renter_rewards_welcome:' || p_renter);
exception when others then
  raise warning 'rewards welcome %: %', p_renter, sqlerrm;   -- never stops the account or the booking
  return null;
end $$;

create function app.rewards_welcome_renter() returns trigger
language plpgsql security definer set search_path = public, app as $$
begin
  if new.user_id is not null and (tg_op = 'INSERT' or old.user_id is null) and app.rewards_notice_renter_ok(new.id) then
    perform app.rewards_welcome(new.id);
  end if;
  return null;
end $$;
create trigger renters_rewards_welcome after insert or update of user_id on renters for each row execute function app.rewards_welcome_renter();

create function app.rewards_welcome_booking() returns trigger
language plpgsql security definer set search_path = public, app as $$
begin
  if new.status::text = 'confirmed' and (tg_op = 'INSERT' or old.status is distinct from new.status) and new.renter_id is not null
     and new.booking_type::text <> 'owner' and not coalesce(new.do_not_email, false) and not coalesce(new.is_placeholder, false)
     and app.rewards_notice_renter_ok(new.renter_id) then
    perform app.rewards_welcome(new.renter_id);
  end if;
  return null;
end $$;
create trigger bookings_rewards_welcome after insert or update of status on bookings for each row execute function app.rewards_welcome_booking();

-- ================================================================ 3. points earned (and the nudge near a tier)
-- Every earn of one transaction for one renter is one email: the trigger is deferred to the commit, the first row sends
-- it with every row of the transaction, the others find its dedupe key taken.
create function app.rewards_points_notice(p_renter uuid) returns bigint
language plpgsql security definer set search_path = public, app as $$
declare
  s rewards_settings := app.rewards();
  v_rows jsonb;
  v_sum integer;
  v_bal integer;
  v_id bigint;
  v_rental record;
  nt reward_tiers;
  v_pts integer;
begin
  if p_renter is null or not app.rewards_notice_renter_ok(p_renter) then return null; end if;
  perform app.rewards_sync_tier(p_renter);
  select coalesce(jsonb_agg(jsonb_build_object('reason', l.reason, 'points', app.rewards_fmt_points(l.points)) order by l.points desc, l.id), '[]'::jsonb), coalesce(sum(l.points), 0)
    into v_rows, v_sum
    from reward_ledger l left join bookings b on b.id = l.booking_id
   where l.renter_id = p_renter and l.kind = 'earn' and l.points > 0 and l.reversed_at is null and l.created_at = now()
     and coalesce(l.action, '') not like 'social\_%' and not coalesce(b.do_not_email, false);
  if v_sum > 0 and app.rewards_notice_on('renter_rewards_points') then
    v_bal := app.rewards_balance(p_renter);
    v_id := app.emit_event('renter_rewards_points', 'renter', p_renter,
      jsonb_build_object('renter_id', p_renter, 'earned', v_rows, 'points_earned', app.rewards_fmt_points(v_sum),
                         'can_redeem', v_bal >= s.min_redeem_points and v_bal - v_sum < s.min_redeem_points),
      'renter_rewards_points:' || p_renter || ':' || txid_current());
  end if;
  -- a rental closed in this transaction: within the percent of the next tier, a nudge a little later
  select l.booking_id into v_rental from reward_ledger l join bookings b on b.id = l.booking_id
   where l.renter_id = p_renter and l.kind = 'earn' and l.action = 'rental' and l.created_at = now() and not coalesce(b.do_not_email, false) limit 1;
  if v_rental.booking_id is not null and app.rewards_notice_on('renter_rewards_near_tier') then
    v_pts := app.rewards_points_12m(p_renter);
    select * into nt from reward_tiers x where x.active and x.code <> 'member' and x.min_points > v_pts order by x.min_points limit 1;
    if nt.code is not null and (nt.min_points - v_pts) * 100 <= nt.min_points * s.notice_near_tier_pct then
      perform app.emit_event('renter_rewards_near_tier', 'renter', p_renter,
        jsonb_build_object('renter_id', p_renter, 'booking_id', v_rental.booking_id, '_send_after', now() + make_interval(hours => s.notice_near_tier_hours)),
        'renter_rewards_near_tier:' || p_renter || ':' || nt.code || ':' || v_rental.booking_id);
    end if;
  end if;
  return v_id;
end $$;

create function app.rewards_ledger_notice() returns trigger
language plpgsql security definer set search_path = public, app as $$
begin
  if new.kind = 'earn' and new.points > 0 and coalesce(new.action, '') not like 'social\_%'
     and coalesce((app.rewards()).notices_enabled, false) then
    begin
      perform app.rewards_points_notice(new.renter_id);
    exception when others then
      raise warning 'rewards points notice %: %', new.renter_id, sqlerrm;   -- never stops the points
    end;
  end if;
  return null;
end $$;
create constraint trigger reward_ledger_notice after insert on reward_ledger deferrable initially deferred
  for each row execute function app.rewards_ledger_notice();

-- ================================================================ 4. a higher tier
create function app.rewards_tier_notice() returns trigger
language plpgsql security definer set search_path = public, app as $$
declare
  t reward_tiers;
  o reward_tiers;
begin
  if new.tier_code is null or new.tier_code is not distinct from old.tier_code or not app.rewards_notice_on('renter_rewards_tier_up') then return null; end if;
  select * into t from reward_tiers where code = new.tier_code;
  select * into o from reward_tiers where code = old.tier_code;
  if t.code is null or t.code = 'member' or not t.active or t.min_points <= coalesce(o.min_points, 0) then return null; end if;
  -- once per tier in 12 months (a tier lost and won back within the year is not news)
  if exists (select 1 from app_events e where e.code = 'renter_rewards_tier_up' and e.entity_id = new.renter_id and e.payload ->> 'tier_code' = t.code
               and e.created_at > now() - interval '12 months') then return null; end if;
  begin
    perform app.rewards_notice_emit('renter_rewards_tier_up', new.renter_id, t.code || ':' || app.today(), jsonb_build_object('tier_code', t.code));
  exception when others then
    raise warning 'rewards tier notice %: %', new.renter_id, sqlerrm;
  end;
  return null;
end $$;
create trigger reward_accounts_tier_notice after update of tier_code on reward_accounts for each row execute function app.rewards_tier_notice();

-- ================================================================ 5. the free day is ready
create function app.rewards_free_day_notice() returns trigger
language plpgsql security definer set search_path = public, app as $$
begin
  if new.source = 'rewards_free_day' and new.renter_id is not null then
    begin
      perform app.rewards_notice_emit('renter_rewards_free_day', new.renter_id, new.id::text, jsonb_build_object('promo_code_id', new.id));
    exception when others then
      raise warning 'rewards free day notice %: %', new.renter_id, sqlerrm;
    end;
  end if;
  return null;
end $$;
create trigger promo_codes_rewards_free_day after insert on promo_codes for each row execute function app.rewards_free_day_notice();

-- the free day's own code in its emails (the newest unused one is in the values; this one is the one the event names)
create function app.rewards_free_day_values(p_promo uuid) returns jsonb
language sql stable security definer set search_path = public, app as $$
  select jsonb_build_object('free_day_code', pc.code, 'free_day_until', coalesce(app.fmt_date(pc.valid_until), ''),
           'book_url', rtrim(coalesce((app.settings()).notify_base_url, 'https://carmacars.ca'), '/') || '/book?promo=' || pc.code,
           'days_left', case when pc.valid_until is null then '' when pc.valid_until - now() <= interval '1 day' then '1 day'
                             else ceil(extract(epoch from (pc.valid_until - now())) / 86400.0)::int || ' days' end)
    from promo_codes pc where pc.id = p_promo
$$;

-- ================================================================ 6. the hourly job: reminders, nudges, the statement
-- (the birthday and holiday notices are added by 3001)
create function app.job_rewards_notices(p_now timestamptz default now()) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  s rewards_settings := app.rewards();
  v_local timestamp := p_now at time zone 'America/Toronto';
  v_today date := (p_now at time zone 'America/Toronto')::date;
  r record;
  v_end timestamptz;
  v_month date;
  n_7 int := 0; n_fd int := 0; n_w int := 0; n_s int := 0;
  v_entries jsonb;
begin
  if not s.enabled or not s.notices_enabled then return jsonb_build_object('enabled', false); end if;

  -- 7 days before the points end (the 30-day reminder is 0214's)
  if app.rewards_notice_on('renter_rewards_expiring_7d') and s.reminder_days > 7 then
    for r in select x.renter_id, app.rewards_balance(x.renter_id) bal, app.rewards_last_activity(x.renter_id) last, x.reminded_7d_for from reward_accounts x loop
      continue when r.bal <= 0 or r.last is null or r.reminded_7d_for is not distinct from r.last;
      v_end := r.last + make_interval(months => s.expiry_months);
      continue when not (v_end - interval '7 days' <= p_now and v_end > p_now);
      perform app.rewards_notice_emit('renter_rewards_expiring_7d', r.renter_id, extract(epoch from r.last)::bigint::text,
        jsonb_build_object('expiry_date', to_char(app.local_date(v_end), 'Dy, Mon FMDD, YYYY')));
      update reward_accounts set reminded_7d_for = r.last where renter_id = r.renter_id;
      n_7 := n_7 + 1;
    end loop;
  end if;

  -- an unused free day that ends in 30 days, and in 7
  if app.rewards_notice_on('renter_rewards_free_day_ending') then
    for r in select pc.id, pc.renter_id, pc.valid_until from promo_codes pc
              where pc.source = 'rewards_free_day' and pc.renter_id is not null and pc.is_active and pc.valid_until > p_now and pc.valid_until <= p_now + interval '30 days'
                and not exists (select 1 from promo_redemptions x where x.promo_code_id = pc.id and x.status in ('applied', 'redeemed')) loop
      if app.rewards_notice_emit('renter_rewards_free_day_ending', r.renter_id, r.id || case when r.valid_until <= p_now + interval '7 days' then ':7' else ':30' end,
           jsonb_build_object('promo_code_id', r.id)) is not null then n_fd := n_fd + 1; end if;
    end loop;
  end if;

  -- marketing, inside the day (10:00 to 19:59 Toronto time)
  if extract(hour from v_local) between 10 and 19 then
    -- your points are waiting: the last rental long enough ago, nothing coming up, not too often
    if app.rewards_notice_on('renter_rewards_waiting') then
      for r in select x.renter_id, (select max(coalesce(b.checked_in_at, b.return_at)) from bookings b where b.renter_id = x.renter_id and b.status::text in ('returned', 'closed') and b.booking_type::text <> 'owner') last_trip
                 from reward_accounts x
                where (x.waiting_sent_at is null or x.waiting_sent_at < p_now - make_interval(days => s.notice_waiting_every_days))
                  and not exists (select 1 from bookings b where b.renter_id = x.renter_id and b.status::text in ('requested', 'offered', 'tentative', 'pending_payment', 'confirmed', 'on_rent'))
                  and (app.rewards_balance(x.renter_id) > 0 or exists (select 1 from promo_codes pc where pc.renter_id = x.renter_id and pc.source = 'rewards_free_day' and pc.is_active and pc.valid_until > p_now
                         and not exists (select 1 from promo_redemptions y where y.promo_code_id = pc.id and y.status in ('applied', 'redeemed')))) loop
        continue when r.last_trip is null or r.last_trip > p_now - make_interval(days => s.notice_waiting_days);
        if app.rewards_notice_emit('renter_rewards_waiting', r.renter_id, v_today::text) is not null then
          update reward_accounts set waiting_sent_at = p_now where renter_id = r.renter_id;
          n_w := n_w + 1;
        end if;
      end loop;
    end if;

    -- the monthly statement, on the 1st: last month's points
    if extract(day from v_local) = 1 and app.rewards_notice_on('renter_rewards_statement') then
      v_month := (date_trunc('month', v_today) - interval '1 month')::date;
      for r in select x.renter_id from reward_accounts x
                where app.rewards_balance(x.renter_id) > 0
                   or exists (select 1 from reward_ledger l where l.renter_id = x.renter_id and l.points <> 0
                                and l.created_at >= app.local_midnight(v_month) and l.created_at < app.local_midnight((v_month + interval '1 month')::date)) loop
        continue when exists (select 1 from app_events e where e.dedupe_key = 'renter_rewards_statement:' || r.renter_id || ':' || to_char(v_month, 'YYYY-MM'));
        select coalesce(jsonb_agg(jsonb_build_object('date', app.fmt_date(l.created_at), 'reason', l.reason,
                 'points', case when l.points > 0 then '+' else chr(8722) end || app.rewards_fmt_points(abs(l.points))) order by l.created_at, l.id), '[]'::jsonb)
          into v_entries
          from (select * from reward_ledger l where l.renter_id = r.renter_id and l.points <> 0
                   and l.created_at >= app.local_midnight(v_month) and l.created_at < app.local_midnight((v_month + interval '1 month')::date)
                 order by l.created_at, l.id limit 12) l;
        if app.rewards_notice_emit('renter_rewards_statement', r.renter_id, to_char(v_month, 'YYYY-MM'), jsonb_build_object(
             'month_label', to_char(v_month, 'FMMonth YYYY'),
             'month_earned', app.rewards_fmt_points((select coalesce(sum(points), 0)::int from reward_ledger l where l.renter_id = r.renter_id and l.points > 0 and l.kind in ('earn', 'adjust', 'refund')
                               and l.created_at >= app.local_midnight(v_month) and l.created_at < app.local_midnight((v_month + interval '1 month')::date))),
             'month_used', app.rewards_fmt_points((select coalesce(-sum(points), 0)::int from reward_ledger l where l.renter_id = r.renter_id and l.points < 0 and l.kind = 'redeem'
                               and l.created_at >= app.local_midnight(v_month) and l.created_at < app.local_midnight((v_month + interval '1 month')::date))),
             'has_entries', jsonb_array_length(v_entries) > 0, 'entries', v_entries)) is not null then n_s := n_s + 1; end if;
      end loop;
    end if;
  end if;
  return jsonb_build_object('expiring_7d', n_7, 'free_day_ending', n_fd, 'waiting', n_w, 'statements', n_s);
end $$;

do $$
begin
  if to_regclass('cron.job') is not null then
    perform cron.schedule('carmacars-rewards-notices', '47 * * * *', $q$select app.job_rewards_notices()$q$);
  end if;
end $$;

-- ================================================================ 7. the values of the emails
alter function app.notification_payload(text, app_events, jsonb) rename to ntf_payload_pre3000;
create function app.notification_payload(p_code text, p_event app_events, p_to jsonb) returns jsonb
language plpgsql stable security definer set search_path = public, app as $$
declare
  x jsonb := app.ntf_payload_pre3000(p_code, p_event, p_to);
  v_r uuid;
  t reward_tiers;
begin
  if not (p_code = any (app.rewards_notice_codes())) then return x; end if;
  v_r := coalesce(nullif(p_event.payload ->> 'renter_id', '')::uuid, nullif(p_to ->> 'renter_id', '')::uuid, case when p_event.entity = 'renter' then p_event.entity_id end);
  x := coalesce(x, '{}'::jsonb) || app.rewards_notice_values(v_r);
  if p_code = 'renter_rewards_welcome' then
    x := x || jsonb_build_object('ways', (select coalesce(jsonb_agg(jsonb_build_object('label', a.label,
               'points', case when a.code = 'rental' then a.points || ' a dollar' else app.rewards_fmt_points(a.points) end) order by a.sort, a.code), '[]'::jsonb)
             from reward_actions a where a.enabled and a.points > 0
               and (a.code <> 'review_google' or exists (select 1 from site_settings ss where nullif(btrim(coalesce(ss.google_place_id, '')), '') is not null))));
  elsif p_code = 'renter_rewards_tier_up' then
    select * into t from reward_tiers where code = coalesce(p_event.payload ->> 'tier_code', '');
    if t.code is not null then
      x := x || jsonb_build_object('tier_name', t.name, 'perks', (select coalesce(jsonb_agg(jsonb_build_object('label', k.label, 'detail', coalesce(k.detail, '')) order by pt.min_points, k.sort), '[]'::jsonb)
               from reward_tier_perks k join reward_tiers pt on pt.code = k.tier_code where k.enabled and pt.active and pt.min_points <= t.min_points and pt.code <> 'member'));
    end if;
  elsif p_code in ('renter_rewards_free_day', 'renter_rewards_free_day_ending') and nullif(p_event.payload ->> 'promo_code_id', '') is not null then
    x := x || coalesce(app.rewards_free_day_values((p_event.payload ->> 'promo_code_id')::uuid), '{}'::jsonb);
  end if;
  return x || (coalesce(p_event.payload, '{}'::jsonb) - 'renter_id' - 'promo_code_id' - 'tier_code');
end $$;
select pg_temp.copy_grants('app.notification_payload(text, app_events, jsonb)'::regprocedure, 'app.ntf_payload_pre3000(text, app_events, jsonb)'::regprocedure);

-- CATALOGUE 3000 START (generated by supabase/seed/3000_gen_catalogue.mjs; do not edit by hand)
insert into notification_catalogue (code, audience, also_sent_to, category, is_digest, digest_slot, from_address, reply_to,
    subject, preheader, timing, trigger_text, replaces_template, link_path, variables, template_html, template_text) values
  ('renter_rewards_welcome', 'renter', '{}'::text[], 'transactional', false, null, 'CarmaCars <hello@carmacars.ca>', 'contact@carmacars.ca', 'Welcome to CarmaCars Rewards', 'You earn points on every rental. You have {{points_balance}} points now.', 'Once, when the account is made or the first booking is confirmed', 'CarmaCars Rewards notices (migration 3000): once per renter, when the renter''s account is made or their first booking is confirmed, whichever comes first (the dedupe key is the renter). Switch: Admin > Settings > Rewards, Emails and notices (on by default). Not sent while Rewards is off.', null, null, '[{"name":"company_address","type":"string","global":true},{"name":"contact_email","type":"string","global":true},{"name":"first_name","type":"string"},{"name":"instagram_url","type":"url","global":true},{"name":"min_redeem_points","type":"string"},{"name":"opening_hours","type":"string","global":true},{"name":"points_balance","type":"string"},{"name":"points_value","type":"string"},{"name":"reply_time","type":"string","global":true},{"name":"rewards_url","type":"url"},{"name":"support_phone","type":"string","global":true},{"name":"tier_name","type":"string"},{"name":"tiktok_url","type":"url","global":true},{"name":"ways","type":"list","fields":["label","points"]}]'::jsonb, 'templates/renter_rewards_welcome.html', 'templates/renter_rewards_welcome.txt'),
  ('renter_rewards_points', 'renter', '{}'::text[], 'transactional', false, null, 'CarmaCars <hello@carmacars.ca>', 'contact@carmacars.ca', '+{{points_earned}} CarmaCars points', 'Your balance is {{points_balance}} points, worth {{points_value}}.', 'When points are earned', 'CarmaCars Rewards notices (migration 3000): points were earned (a completed rental, a damage-free rental, the first rental, booking again, a review, a review photo, a Google review, a referral, the birthday). One email per renter for everything earned at once (the dedupe key is the renter and the transaction), never for a follow on social media or an Admin''s adjustment, never for a booking marked Do not email. Switch: Admin > Settings > Rewards, Emails and notices (on by default).', null, null, '[{"name":"can_redeem","type":"boolean"},{"name":"company_address","type":"string","global":true},{"name":"contact_email","type":"string","global":true},{"name":"earned","type":"list","fields":["reason","points"]},{"name":"first_name","type":"string"},{"name":"has_next_perk","type":"boolean"},{"name":"has_next_tier","type":"boolean"},{"name":"instagram_url","type":"url","global":true},{"name":"min_redeem_points","type":"string"},{"name":"next_perk","type":"string"},{"name":"next_tier","type":"string"},{"name":"opening_hours","type":"string","global":true},{"name":"points_balance","type":"string"},{"name":"points_earned","type":"string"},{"name":"points_to_next","type":"string"},{"name":"points_value","type":"string"},{"name":"reply_time","type":"string","global":true},{"name":"rewards_url","type":"url"},{"name":"support_phone","type":"string","global":true},{"name":"tier_name","type":"string"},{"name":"tiktok_url","type":"url","global":true}]'::jsonb, 'templates/renter_rewards_points.html', 'templates/renter_rewards_points.txt'),
  ('renter_rewards_tier_up', 'renter', '{}'::text[], 'transactional', false, null, 'CarmaCars <hello@carmacars.ca>', 'contact@carmacars.ca', 'You are {{tier_name}} now', 'Thank you for renting with CarmaCars. Here is what {{tier_name}} brings.', 'When the renter reaches a new tier', 'CarmaCars Rewards notices (migration 3000): the renter reached a higher tier (Gold, Platinum, Black by points earned in the last 12 months). Once per tier in 12 months (the dedupe key is the renter, the tier and the day). Switch: Admin > Settings > Rewards, Emails and notices (on by default).', null, null, '[{"name":"company_address","type":"string","global":true},{"name":"contact_email","type":"string","global":true},{"name":"first_name","type":"string"},{"name":"instagram_url","type":"url","global":true},{"name":"opening_hours","type":"string","global":true},{"name":"perks","type":"list","fields":["label","detail"]},{"name":"points_12m","type":"string"},{"name":"reply_time","type":"string","global":true},{"name":"rewards_url","type":"url"},{"name":"support_phone","type":"string","global":true},{"name":"tier_name","type":"string"},{"name":"tiktok_url","type":"url","global":true}]'::jsonb, 'templates/renter_rewards_tier_up.html', 'templates/renter_rewards_tier_up.txt'),
  ('renter_rewards_free_day', 'renter', '{}'::text[], 'transactional', false, null, 'CarmaCars <hello@carmacars.ca>', 'contact@carmacars.ca', 'Your free rental day is ready', 'Code {{free_day_code}} is good until {{free_day_until}}.', 'When the free day code is made', 'CarmaCars Rewards notices (migration 3000): the Black tier''s free rental day code was made for the renter (2421, one a year). Once per code. Switch: Admin > Settings > Rewards, Emails and notices (on by default).', null, null, '[{"name":"book_url","type":"url"},{"name":"company_address","type":"string","global":true},{"name":"contact_email","type":"string","global":true},{"name":"first_name","type":"string"},{"name":"free_day_code","type":"string"},{"name":"free_day_until","type":"string"},{"name":"instagram_url","type":"url","global":true},{"name":"opening_hours","type":"string","global":true},{"name":"reply_time","type":"string","global":true},{"name":"support_phone","type":"string","global":true},{"name":"tier_name","type":"string"},{"name":"tiktok_url","type":"url","global":true}]'::jsonb, 'templates/renter_rewards_free_day.html', 'templates/renter_rewards_free_day.txt'),
  ('renter_rewards_near_tier', 'renter', '{}'::text[], 'marketing', false, null, 'CarmaCars <hello@carmacars.ca>', 'contact@carmacars.ca', 'You are {{points_to_next}} points from {{next_tier}}', 'One more rental could get you there.', 'Two days after a rental, when close to the next tier', 'CarmaCars Rewards notices (migration 3000): two days after a completed rental, when the points the renter earned in the last 12 months are within 20% of the next tier (rewards_settings.notice_near_tier_pct) and the rental did not already move them up. Once per renter, tier and rental. Marketing: only while the renter has not unsubscribed. Switch: Admin > Settings > Rewards, Emails and notices (on by default).', null, '/cars', '[{"name":"company_address","type":"string","global":true},{"name":"contact_email","type":"string","global":true},{"name":"first_name","type":"string"},{"name":"instagram_url","type":"url","global":true},{"name":"next_perk","type":"string"},{"name":"next_tier","type":"string"},{"name":"opening_hours","type":"string","global":true},{"name":"points_12m","type":"string"},{"name":"points_to_next","type":"string"},{"name":"reply_time","type":"string","global":true},{"name":"support_phone","type":"string","global":true},{"name":"tiktok_url","type":"url","global":true},{"name":"unsubscribe_url","type":"url"}]'::jsonb, 'templates/renter_rewards_near_tier.html', 'templates/renter_rewards_near_tier.txt'),
  ('renter_rewards_waiting', 'renter', '{}'::text[], 'marketing', false, null, 'CarmaCars <hello@carmacars.ca>', 'contact@carmacars.ca', 'Your {{points_balance}} CarmaCars points are waiting', 'Worth {{points_value}} off your next rental.', '30 days after the last rental, at most every 60 days', 'CarmaCars Rewards notices (migration 3000, hourly job): 30 days after the renter''s last completed rental (rewards_settings.notice_waiting_days) with points or an unused free day, and no booking coming up. At most once in 60 days (notice_waiting_every_days). Marketing: only while the renter has not unsubscribed. Switch: Admin > Settings > Rewards, Emails and notices (on by default).', null, '/cars', '[{"name":"company_address","type":"string","global":true},{"name":"contact_email","type":"string","global":true},{"name":"first_name","type":"string"},{"name":"free_day_code","type":"string"},{"name":"free_day_until","type":"string"},{"name":"has_free_day","type":"boolean"},{"name":"instagram_url","type":"url","global":true},{"name":"opening_hours","type":"string","global":true},{"name":"points_balance","type":"string"},{"name":"points_value","type":"string"},{"name":"reply_time","type":"string","global":true},{"name":"support_phone","type":"string","global":true},{"name":"tier_name","type":"string"},{"name":"tiktok_url","type":"url","global":true},{"name":"unsubscribe_url","type":"url"}]'::jsonb, 'templates/renter_rewards_waiting.html', 'templates/renter_rewards_waiting.txt'),
  ('renter_rewards_expiring_7d', 'renter', '{}'::text[], 'transactional', false, null, 'CarmaCars <hello@carmacars.ca>', 'contact@carmacars.ca', 'Last week to keep your {{points_balance}} CarmaCars points', 'They end on {{expiry_date}}.', '7 days before the points end', 'CarmaCars Rewards notices (migration 3000, hourly job): 7 days before the renter''s points end (12 months after the last rental or redemption by default), after the 30-day reminder (renter_rewards_expiring). Once per period of activity. Not sent when the reminder days are 7 or fewer. Switch: Admin > Settings > Rewards, Emails and notices (on by default).', null, null, '[{"name":"company_address","type":"string","global":true},{"name":"contact_email","type":"string","global":true},{"name":"expiry_date","type":"string"},{"name":"first_name","type":"string"},{"name":"instagram_url","type":"url","global":true},{"name":"opening_hours","type":"string","global":true},{"name":"points_balance","type":"string"},{"name":"points_value","type":"string"},{"name":"reply_time","type":"string","global":true},{"name":"rewards_url","type":"url"},{"name":"support_phone","type":"string","global":true},{"name":"tiktok_url","type":"url","global":true}]'::jsonb, 'templates/renter_rewards_expiring_7d.html', 'templates/renter_rewards_expiring_7d.txt'),
  ('renter_rewards_free_day_ending', 'renter', '{}'::text[], 'transactional', false, null, 'CarmaCars <hello@carmacars.ca>', 'contact@carmacars.ca', 'Your free rental day ends in {{days_left}}', 'Code {{free_day_code}} is good until {{free_day_until}}.', '30 and 7 days before the free day code ends', 'CarmaCars Rewards notices (migration 3000, hourly job): the renter''s free rental day code is unused and ends in 30 days, and again in 7 days. Once each. Switch: Admin > Settings > Rewards, Emails and notices (on by default).', null, null, '[{"name":"book_url","type":"url"},{"name":"company_address","type":"string","global":true},{"name":"contact_email","type":"string","global":true},{"name":"days_left","type":"string"},{"name":"first_name","type":"string"},{"name":"free_day_code","type":"string"},{"name":"free_day_until","type":"string"},{"name":"instagram_url","type":"url","global":true},{"name":"opening_hours","type":"string","global":true},{"name":"reply_time","type":"string","global":true},{"name":"support_phone","type":"string","global":true},{"name":"tiktok_url","type":"url","global":true}]'::jsonb, 'templates/renter_rewards_free_day_ending.html', 'templates/renter_rewards_free_day_ending.txt'),
  ('renter_rewards_statement', 'renter', '{}'::text[], 'marketing', false, null, 'CarmaCars <hello@carmacars.ca>', 'contact@carmacars.ca', 'Your CarmaCars points for {{month_label}}', '{{points_balance}} points, worth {{points_value}}.', 'Monthly, on the 1st', 'CarmaCars Rewards notices (migration 3000, hourly job): on the 1st of each month from 9:00 Toronto time, the last month''s points for each renter with a balance above 0 or points earned or used that month. Once per renter and month. Marketing: only while the renter has not unsubscribed. Switch: Admin > Settings > Rewards, Emails and notices (on by default).', null, null, '[{"name":"company_address","type":"string","global":true},{"name":"contact_email","type":"string","global":true},{"name":"entries","type":"list","fields":["date","reason","points"]},{"name":"first_name","type":"string"},{"name":"has_entries","type":"boolean"},{"name":"has_next_tier","type":"boolean"},{"name":"instagram_url","type":"url","global":true},{"name":"month_earned","type":"string"},{"name":"month_label","type":"string"},{"name":"month_used","type":"string"},{"name":"next_tier","type":"string"},{"name":"opening_hours","type":"string","global":true},{"name":"points_balance","type":"string"},{"name":"points_to_next","type":"string"},{"name":"points_value","type":"string"},{"name":"reply_time","type":"string","global":true},{"name":"rewards_url","type":"url"},{"name":"support_phone","type":"string","global":true},{"name":"tier_name","type":"string"},{"name":"tiktok_url","type":"url","global":true},{"name":"unsubscribe_url","type":"url"}]'::jsonb, 'templates/renter_rewards_statement.html', 'templates/renter_rewards_statement.txt'),
  ('renter_rewards_birthday', 'renter', '{}'::text[], 'marketing', false, null, 'CarmaCars <hello@carmacars.ca>', 'contact@carmacars.ca', 'Your birthday reward is waiting: {{reward_pct}} off', 'Pick up a car between {{window_from}} and {{window_to}}.', '14 days before the birthday', 'CarmaCars Rewards notices (migration 3000, hourly job): 14 days before the renter''s birthday (rewards_settings.birthday_notice_days), for a renter whose tier has a birthday reward switched on (Platinum 10%, Black 20% by default, Gold off). Once a year. Marketing: only while the renter has not unsubscribed. Switch: Admin > Settings > Rewards, Emails and notices (on by default).', null, '/cars', '[{"name":"company_address","type":"string","global":true},{"name":"contact_email","type":"string","global":true},{"name":"first_name","type":"string"},{"name":"instagram_url","type":"url","global":true},{"name":"opening_hours","type":"string","global":true},{"name":"reply_time","type":"string","global":true},{"name":"reward_pct","type":"string"},{"name":"support_phone","type":"string","global":true},{"name":"tier_name","type":"string"},{"name":"tiktok_url","type":"url","global":true},{"name":"unsubscribe_url","type":"url"},{"name":"window_from","type":"string"},{"name":"window_to","type":"string"}]'::jsonb, 'templates/renter_rewards_birthday.html', 'templates/renter_rewards_birthday.txt'),
  ('renter_rewards_holiday', 'renter', '{}'::text[], 'marketing', false, null, 'CarmaCars <hello@carmacars.ca>', 'contact@carmacars.ca', '{{holiday_name}}: {{reward_pct}} off for you', 'Pick up a car between {{window_from}} and {{window_to}}.', '10 days before each holiday weekend', 'CarmaCars Rewards notices (migration 3000, hourly job): 10 days before a holiday weekend (rewards_settings.holiday_notice_days; the Ontario holidays in Admin > Settings > Rewards), for a renter whose tier has a holiday reward switched on (Platinum 10%, Black 20% by default, Gold off). Once per holiday. Marketing: only while the renter has not unsubscribed. Switch: Admin > Settings > Rewards, Emails and notices (on by default).', null, '/cars', '[{"name":"company_address","type":"string","global":true},{"name":"contact_email","type":"string","global":true},{"name":"first_name","type":"string"},{"name":"holiday_name","type":"string"},{"name":"instagram_url","type":"url","global":true},{"name":"opening_hours","type":"string","global":true},{"name":"reply_time","type":"string","global":true},{"name":"reward_pct","type":"string"},{"name":"support_phone","type":"string","global":true},{"name":"tier_name","type":"string"},{"name":"tiktok_url","type":"url","global":true},{"name":"unsubscribe_url","type":"url"},{"name":"window_from","type":"string"},{"name":"window_to","type":"string"}]'::jsonb, 'templates/renter_rewards_holiday.html', 'templates/renter_rewards_holiday.txt')
on conflict (code) do update set
  audience = excluded.audience, also_sent_to = excluded.also_sent_to, category = excluded.category,
  is_digest = excluded.is_digest, digest_slot = excluded.digest_slot, from_address = excluded.from_address,
  reply_to = excluded.reply_to, subject = excluded.subject, preheader = excluded.preheader, timing = excluded.timing,
  trigger_text = excluded.trigger_text, replaces_template = excluded.replaces_template, link_path = excluded.link_path,
  variables = excluded.variables, template_html = excluded.template_html, template_text = excluded.template_text,
  in_catalogue = true, updated_at = now();
select app.notification_catalogue_refresh();
-- CATALOGUE 3000 END

update notification_catalogue set emitted_by = case code
    when 'renter_rewards_welcome' then 'renters_rewards_welcome, bookings_rewards_welcome (3000): the account is made or the first booking confirmed'
    when 'renter_rewards_points' then 'reward_ledger_notice (3000): points earned, one email a transaction'
    when 'renter_rewards_tier_up' then 'reward_accounts_tier_notice (3000): a higher tier'
    when 'renter_rewards_free_day' then 'promo_codes_rewards_free_day (3000): the free day code is made'
    when 'renter_rewards_near_tier' then 'app.rewards_points_notice (3000): after a rental, close to the next tier'
    else 'app.job_rewards_notices (3000, hourly)' end,
  link_path = case code
    when 'renter_rewards_near_tier' then '/cars' when 'renter_rewards_waiting' then '/cars' when 'renter_rewards_birthday' then '/cars' when 'renter_rewards_holiday' then '/cars'
    when 'renter_rewards_free_day' then '/book?promo={{free_day_code}}' when 'renter_rewards_free_day_ending' then '/book?promo={{free_day_code}}'
    else '/account/rewards' end,
  updated_at = now()
 where code = any (app.rewards_notice_codes());
-- the follow-ups wait behind customer, owner and staff emails under the daily cap (marketing is class 5 by itself)
insert into notification_low_priority (code, priority)
select c, 4 from unnest(array['renter_rewards_welcome', 'renter_rewards_points', 'renter_rewards_tier_up', 'renter_rewards_free_day',
                              'renter_rewards_expiring_7d', 'renter_rewards_free_day_ending']) c
on conflict (code) do nothing;
select app.notification_catalogue_refresh();
-- texts: the short transactional ones have a text for a renter without email; the lists and the marketing ones never go by text
insert into sms_templates (code, label, body, enabled, urgent, sort_order) values
  ('renter_rewards_points', 'Rewards points earned', 'CarmaCars: +{{points_earned}} reward points. You have {{points_balance}}, worth {{points_value}}: {{link}}', true, false, coalesce((select max(sort_order) + 1 from sms_templates), 1)),
  ('renter_rewards_tier_up', 'Rewards new tier', 'CarmaCars: you are {{tier_name}} now. Thank you. Your perks: {{link}}', true, false, coalesce((select max(sort_order) + 2 from sms_templates), 2)),
  ('renter_rewards_free_day', 'Rewards free day', 'CarmaCars: your free rental day is ready, code {{free_day_code}} until {{free_day_until}}. Book: {{link}}', true, false, coalesce((select max(sort_order) + 3 from sms_templates), 3)),
  ('renter_rewards_expiring_7d', 'Rewards points ending in 7 days', 'CarmaCars: your {{points_balance}} reward points end on {{expiry_date}}. Rent or redeem to keep them: {{link}}', true, false, coalesce((select max(sort_order) + 4 from sms_templates), 4)),
  ('renter_rewards_free_day_ending', 'Rewards free day ending', 'CarmaCars: your free rental day code {{free_day_code}} ends {{free_day_until}}. Book: {{link}}', true, false, coalesce((select max(sort_order) + 5 from sms_templates), 5))
on conflict (code) do nothing;
update notification_catalogue set no_text = true
 where code in ('renter_rewards_welcome', 'renter_rewards_near_tier', 'renter_rewards_waiting', 'renter_rewards_statement', 'renter_rewards_birthday', 'renter_rewards_holiday');

-- ================================================================ 8. Admin > Settings > Rewards: the notices, their switches and counts
create function app.rewards_notices_admin(p_by uuid) returns jsonb
language plpgsql stable security definer set search_path = public, app as $$
declare s rewards_settings := app.rewards();
begin
  perform app.assert_admin(p_by);
  return jsonb_build_object('enabled', s.notices_enabled, 'near_tier_pct', s.notice_near_tier_pct, 'near_tier_hours', s.notice_near_tier_hours,
    'waiting_days', s.notice_waiting_days, 'waiting_every_days', s.notice_waiting_every_days,
    'items', (select coalesce(jsonb_agg(jsonb_build_object('code', c.code, 'subject', c.subject, 'timing', c.timing, 'category', c.category, 'enabled', c.is_enabled,
                'sent_30d', (select count(*) from notification_outbox o where o.code = c.code and o.status = 'sent' and o.sent_at > now() - interval '30 days'),
                'notices_30d', (select count(*) from notifications n where n.code = c.code and n.created_at > now() - interval '30 days'))
              order by array_position(array['renter_rewards_welcome'] || app.rewards_notice_codes() || array['renter_rewards_expiring'], c.code)), '[]'::jsonb)
             from notification_catalogue c where c.code = any (app.rewards_notice_codes() || array['renter_rewards_expiring'])));
end $$;

create function app.rewards_notices_admin_do(p_by uuid, p_name text, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  v_code text := nullif(btrim(coalesce(p ->> 'code', '')), '');
  v_old boolean;
begin
  perform app.assert_admin(p_by);
  if p_name = 'rewards_notice_set' then
    if v_code is null or not (v_code = any (app.rewards_notice_codes() || array['renter_rewards_expiring'])) then
      raise exception 'Choose a Rewards email' using errcode = '22023';
    end if;
    if (p ->> 'enabled') is null then raise exception 'On or off' using errcode = '22023'; end if;
    select is_enabled into v_old from notification_catalogue where code = v_code;
    update notification_catalogue set is_enabled = (p ->> 'enabled')::boolean, updated_at = now() where code = v_code;
    insert into audit_log (actor_user_id, action, entity_table, entity_id, before, after)
    values (p_by, p_name, 'notification_catalogue', v_code, jsonb_build_object('enabled', v_old), jsonb_build_object('enabled', (p ->> 'enabled')::boolean));
    return jsonb_build_object('code', v_code, 'enabled', (p ->> 'enabled')::boolean);
  elsif p_name = 'rewards_notices_save' then
    update rewards_settings set notices_enabled = coalesce((p ->> 'enabled')::boolean, notices_enabled),
           notice_near_tier_pct = coalesce((p ->> 'near_tier_pct')::int, notice_near_tier_pct), notice_near_tier_hours = coalesce((p ->> 'near_tier_hours')::int, notice_near_tier_hours),
           notice_waiting_days = coalesce((p ->> 'waiting_days')::int, notice_waiting_days), notice_waiting_every_days = coalesce((p ->> 'waiting_every_days')::int, notice_waiting_every_days),
           updated_by = p_by, updated_at = now() where singleton;
    insert into audit_log (actor_user_id, action, entity_table, entity_id, after) values (p_by, p_name, 'rewards_settings', 'singleton', p);
    return app.rewards_notices_admin(p_by);
  end if;
  raise exception 'Unknown rewards call %', p_name using errcode = '22023';
end $$;

alter function app.door(uuid, text, text, text, jsonb) rename to door_pre3000;
create function app.door(p_user uuid, p_aal text, p_call text, p_name text, p jsonb default '{}'::jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare v jsonb;
begin
  if p_call = 'admin_read' and p_name = 'rewards' then
    v := app.door_pre3000(p_user, p_aal, p_call, p_name, p);
    return v || jsonb_build_object('notices', app.rewards_notices_admin(p_user));
  end if;
  if p_call = 'admin_do' and p_name in ('rewards_notice_set', 'rewards_notices_save') then
    perform app.door_begin(p_user, p_aal);
    return app.rewards_notices_admin_do(p_user, p_name, coalesce(p, '{}'::jsonb) - '_va');
  end if;
  return app.door_pre3000(p_user, p_aal, p_call, p_name, p);
end $$;
select pg_temp.copy_grants('app.door(uuid, text, text, text, jsonb)'::regprocedure, 'app.door_pre3000(uuid, text, text, text, jsonb)'::regprocedure);

-- ================================================================ 9. privileges
do $$
declare f record;
begin
  for f in
    select p.oid::regprocedure as sig from pg_proc p join pg_namespace n on n.oid = p.pronamespace
     where n.nspname = 'app' and p.proname = any (array['rewards_notice_codes', 'rewards_notice_on', 'rewards_notice_renter_ok', 'rewards_notice_emit', 'rewards_fmt_points',
             'rewards_notice_values', 'rewards_welcome', 'rewards_welcome_renter', 'rewards_welcome_booking', 'rewards_points_notice', 'rewards_ledger_notice',
             'rewards_tier_notice', 'rewards_free_day_notice', 'rewards_free_day_values', 'job_rewards_notices', 'ntf_payload_pre3000',
             'rewards_notices_admin', 'rewards_notices_admin_do', 'door_pre3000'])
  loop
    execute format('revoke all on function %s from public, anon, authenticated', f.sig);
    execute format('grant execute on function %s to service_role', f.sig);
  end loop;
end $$;
