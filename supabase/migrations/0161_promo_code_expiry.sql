-- 0161_promo_code_expiry.sql
-- Discount codes received from games and other ways expire, and the people who hold them are told before they do
-- (docs/changes/2026-10-25-promo-code-expiry.md). The owner, October 25, 2026: "Make discount codes received from games
-- and other ways expire and make sure that you are notifying people of the upcoming expiry of the discount code."
--
-- 1. Every code issued to a person has an end date. A "personal" code is one for a person: a discount game code
--    (source discount_game), a come-back code (followup_7d, followup_30d), a Live visitors code (live_visitors) or any
--    code made for one renter (renter_id set). Each source keeps its own setting for how long it lasts (game_code_valid_days 7,
--    notify_comeback_valid_days 30, the Live visitors discount_valid_days 3) and a new setting, promo_default_valid_days (30),
--    covers every other personal code. A trigger gives a personal code without an end date its source's default and refuses
--    to take the end date away later. Personal codes on file without an end date get one 30 days from this migration.
--    A public code (no renter, a campaign source) may still have no end date when an Admin leaves the field empty; the Admin
--    form starts with an end date filled in.
-- 2. Refusal: app.promo_code_problem (0016, 0069) already refuses an expired code wherever a code is applied (the booking
--    form's check, the quote, the request, the offer, Add a rental, the Admin booking edit all go through it and through
--    app.apply_promo_code). This migration keeps that and tests every one of those doors.
-- 3. Reminders for every personal code not yet used: one when the code's last day is promo_reminder_3d_days away (3, 0 turns it
--    off) and one the day before its last day (promo_reminder_1d_on), master switch promo_reminders_enabled, all on by default.
--    A code made less than that long before its last day gets no reminder of that kind. Email and text follow the person's
--    channel (0096). Discount game codes keep their transactional class (renter_game_code_reminder, now the day-before
--    reminder, and the new renter_game_code_reminder_3d); every other personal code is marketing, with the express consent
--    rule of the come-back offers: never after an unsubscribe, with the unsubscribe link, inside the sending hours (email
--    9 am to 9 pm, texts not 9 pm to 8 am) and under the existing outbox limits. One row per code and kind in
--    promo_reminders: never twice, and the game reminder is part of it (game_claims.reminder_sent_at is kept in step).
--    Never after the code is on a booking request or used (a reminder still waiting is cancelled) and never after it expired.
-- 4. The job: app.job_game_reminders (pg_cron carmacars-game-reminders, every 30 minutes) now also runs the promo code
--    reminders; no new job.
-- 5. Admin > Settings > Promo codes shows each code's end date and the reminders sent, and the codes sent to people; the renter's
--    account (Your trips) lists their codes with end dates (public.server_my_promo_codes).
-- No applied migration is edited.
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
create function pg_temp.service_only(p regprocedure) returns void
language plpgsql as $$
begin
  execute format('revoke all on function %s from public, anon, authenticated', p);
  execute format('grant execute on function %s to service_role', p);
end $$;

-- ================================================================ 1. settings
alter table program_settings
  add column if not exists promo_default_valid_days integer not null default 30 check (promo_default_valid_days between 1 and 365),
  add column if not exists promo_reminders_enabled boolean not null default true,
  add column if not exists promo_reminder_3d_days integer not null default 3 check (promo_reminder_3d_days = 0 or promo_reminder_3d_days between 2 and 30),
  add column if not exists promo_reminder_1d_on boolean not null default true;

comment on column program_settings.promo_default_valid_days is 'Promo codes: a code made for one person (staff, or any source without its own setting) is good for this many days when no end date is given (30). Games, come-back offers and Live visitors keep their own settings.';
comment on column program_settings.promo_reminders_enabled is 'Promo codes: remind people of a code they have not used before it ends (on by default): the two reminders below.';
comment on column program_settings.promo_reminder_3d_days is 'Promo codes: the first reminder goes this many days before the last day of an unused code (3; 0 turns it off).';
comment on column program_settings.promo_reminder_1d_on is 'Promo codes: the second reminder goes the day before the last day of an unused code (on by default). For a game code this is the reminder game_reminder_hours used to set.';
comment on column program_settings.game_reminder_hours is 'Discount games: no longer read since 0161. The reminder before a game code ends is the day-before promo code reminder (promo_reminder_1d_on).';

-- ================================================================ 2. personal codes have an end date
create or replace function app.promo_is_personal(p_renter uuid, p_source text) returns boolean
language sql immutable as $$
  select p_renter is not null or coalesce(p_source, '') in ('discount_game', 'followup_7d', 'followup_30d', 'live_visitors')
$$;
comment on function app.promo_is_personal(uuid, text) is '0161: a promo code issued to a person (a game, a come-back offer, Live visitors, or made for one renter): it always has an end date and gets the expiry reminders.';

create or replace function app.promo_default_days(p_source text) returns integer
language sql stable security definer set search_path = public, app as $$
  select case coalesce(p_source, '')
           when 'discount_game' then (app.settings()).game_code_valid_days
           when 'followup_7d' then (app.settings()).notify_comeback_valid_days
           when 'followup_30d' then (app.settings()).notify_comeback_valid_days
           when 'live_visitors' then coalesce((select c.discount_valid_days from visitor_signal_config c where c.id), (app.settings()).promo_default_valid_days)
           else (app.settings()).promo_default_valid_days end
$$;

create or replace function app.promo_code_expiry_guard() returns trigger
language plpgsql security definer set search_path = public, app as $$
begin
  if new.valid_until is null and app.promo_is_personal(new.renter_id, new.source) then
    if tg_op = 'UPDATE' then
      raise exception 'A code issued to a person needs an end date' using errcode = '23514';
    end if;
    new.valid_until := coalesce(new.valid_from, now()) + make_interval(days => app.promo_default_days(new.source));
  end if;
  return new;
end $$;
drop trigger if exists promo_codes_expiry_guard on promo_codes;
create trigger promo_codes_expiry_guard before insert or update on promo_codes for each row execute function app.promo_code_expiry_guard();

-- the codes on file for people without an end date: 30 days from now (never in the past)
update promo_codes pc
   set valid_until = greatest(now(), pc.valid_from) + make_interval(days => (app.settings()).promo_default_valid_days)
 where pc.valid_until is null and app.promo_is_personal(pc.renter_id, pc.source);

-- ================================================================ 3. the reminders kept
create table if not exists promo_reminders (
  id            uuid primary key default gen_random_uuid(),
  promo_code_id uuid not null references promo_codes (id) on delete cascade,
  kind          text not null check (kind in ('3d', '1d')),
  code          text not null,
  event_id      bigint,
  sent_at       timestamptz not null default now(),
  unique (promo_code_id, kind)
);
create index if not exists promo_reminders_sent_idx on promo_reminders (sent_at desc);
comment on table promo_reminders is '0161: one row per promo code and reminder kind (3d: days before the last day, 1d: the day before): a reminder is never sent twice.';
alter table promo_reminders enable row level security;
drop policy if exists admin_all on promo_reminders;
create policy admin_all on promo_reminders for all to authenticated using (app.is_admin()) with check (app.is_admin());
revoke all on promo_reminders from anon, authenticated;
create trigger audit_promo_reminders after insert or update or delete on promo_reminders for each row execute function app.audit_row();
-- the game reminders sent before 0161 count as the day-before reminder
insert into promo_reminders (promo_code_id, kind, code, sent_at)
select gc.promo_code_id, '1d', 'renter_game_code_reminder', gc.reminder_sent_at from game_claims gc where gc.reminder_sent_at is not null
on conflict (promo_code_id, kind) do nothing;

-- What a code gives, as the emails and texts say it: "10% off", "$25 off", "2 free days".
create or replace function app.promo_label(pc promo_codes) returns text
language sql stable security definer set search_path = public, app as $$
  select app.game_prize_label(case when pc.free_days is not null then jsonb_build_object('free_days', pc.free_days)
                                   when pc.percent_bps is not null then jsonb_build_object('percent_bps', pc.percent_bps)
                                   else jsonb_build_object('amount_cents', pc.amount_cents) end)
$$;
create or replace function app.promo_applies_to(pc promo_codes) returns text
language sql stable security definer set search_path = public, app as $$
  select app.game_code_applies(pc)
$$;
-- The last day of a code, the day a person sees: a code that ends at midnight ends the day before.
create or replace function app.promo_last_day(pc promo_codes) returns date
language sql stable security definer set search_path = public, app as $$
  select app.local_date(pc.valid_until - interval '1 second')
$$;
-- open, on_request (on a booking request), used, expired or off
create or replace function app.promo_status(pc promo_codes) returns text
language sql stable security definer set search_path = public, app as $$
  select case
    when exists (select 1 from promo_redemptions r where r.promo_code_id = pc.id and r.status = 'redeemed') then 'used'
    when exists (select 1 from promo_redemptions r where r.promo_code_id = pc.id and r.status = 'applied') then 'on_request'
    when not pc.is_active then 'off'
    when pc.valid_until is not null and pc.valid_until <= now() then 'expired'
    else 'open' end
$$;
-- The reminders sent for a code: {"3d": time, "1d": time}
create or replace function app.promo_reminder_marks(p_promo uuid) returns jsonb
language sql stable security definer set search_path = public, app as $$
  select coalesce(jsonb_object_agg(r.kind, r.sent_at), '{}'::jsonb) from promo_reminders r where r.promo_code_id = p_promo
$$;

-- The values of the emails and texts about a code.
create or replace function app.promo_email_values(pc promo_codes, p_on date default app.today()) returns jsonb
language sql stable security definer set search_path = public, app as $$
  select jsonb_build_object(
    'prize_label', app.promo_label(pc),
    'discount_code', pc.code,
    'discount_expires', app.fmt_day(app.promo_last_day(pc)),
    'discount_applies_to', app.promo_applies_to(pc),
    'discount_terms', 'Off the rental charge only, not fees, the Deposit or tax.'
                      || case when pc.min_rental_days is not null then format(' For rentals of %s days or more.', pc.min_rental_days) else '' end,
    'days_left', case when app.promo_last_day(pc) - p_on = 1 then 'tomorrow' else greatest(app.promo_last_day(pc) - p_on, 0) || ' days' end)
$$;

-- A reminder still waiting for a code that was used or has ended does not go (its text neither).
create or replace function app.promo_reminders_cancel(p_promo uuid, p_reason text) returns integer
language plpgsql security definer set search_path = public, app as $$
declare
  v_ids uuid[];
begin
  with gone as (
    update notification_outbox o set status = 'skipped', status_reason = p_reason
     where o.code in ('renter_promo_expiry_3d', 'renter_promo_expiry_1d', 'renter_game_code_reminder_3d', 'renter_game_code_reminder')
       and (o.status in ('queued', 'delayed') or (o.status = 'skipped' and o.status_reason like 'Sent by text%'))
       and (o.entity_id = p_promo or o.entity_id in (select gc.id from game_claims gc where gc.promo_code_id = p_promo))
    returning o.id)
  select coalesce(array_agg(id), '{}') into v_ids from gone;
  if cardinality(v_ids) > 0 then
    update phone_outbox t set status = 'skipped', status_reason = p_reason where t.notification_id = any (v_ids) and t.status = 'queued';
  end if;
  return cardinality(v_ids);
end $$;

create or replace function app.promo_redemption_cancels_reminders() returns trigger
language plpgsql security definer set search_path = public, app as $$
begin
  if new.status in ('applied', 'redeemed') then
    perform app.promo_reminders_cancel(new.promo_code_id, 'The code was used');
  end if;
  return new;
end $$;
drop trigger if exists promo_redemptions_cancel_reminders on promo_redemptions;
create trigger promo_redemptions_cancel_reminders after insert or update of status on promo_redemptions
  for each row execute function app.promo_redemption_cancels_reminders();

-- ================================================================ 4. the job
-- One tick: every personal code not used and not ended whose reminder is due. Called by app.job_game_reminders.
-- A reminder is due from the start of its day (Toronto): the first on the day promo_reminder_3d_days before the code's last
-- day, until the day before the last day begins; the second on the day before the last day, until the code ends. A code made
-- after that day began gets none of that kind. Returns how many were sent.
create or replace function app.promo_reminders_run(p_now timestamptz default now()) returns integer
language plpgsql security definer set search_path = public, app as $$
declare
  s program_settings := app.settings(app.local_date(p_now));
  pc promo_codes;
  c game_claims;
  v_kind text;
  v_end date;
  v_start timestamptz;
  v_stop timestamptz;
  v_user uuid;
  v_code text;
  v_event bigint;
  v_n integer := 0;
begin
  if not s.promo_reminders_enabled then return 0; end if;
  -- what waits for a code that has ended: nothing goes
  for pc in select x.* from promo_codes x
             where x.valid_until is not null and x.valid_until <= p_now and x.valid_until > p_now - interval '2 days'
               and exists (select 1 from notification_outbox o
                            where o.code in ('renter_promo_expiry_3d', 'renter_promo_expiry_1d', 'renter_game_code_reminder_3d', 'renter_game_code_reminder')
                              and (o.status in ('queued', 'delayed') or (o.status = 'skipped' and o.status_reason like 'Sent by text%'))
                              and (o.entity_id = x.id or o.entity_id in (select gc.id from game_claims gc where gc.promo_code_id = x.id))) loop
    perform app.promo_reminders_cancel(pc.id, 'The code ended');
  end loop;

  for pc in select x.* from promo_codes x
             where x.is_active and x.valid_until is not null and x.valid_until > p_now
               and x.valid_until <= p_now + make_interval(days => greatest(s.promo_reminder_3d_days, 1) + 2)
               and app.promo_is_personal(x.renter_id, x.source)
               and not exists (select 1 from promo_redemptions r where r.promo_code_id = x.id and r.status in ('applied', 'redeemed'))
             order by x.valid_until, x.id
               for update of x skip locked loop
    v_end := app.promo_last_day(pc);
    select * into c from game_claims where promo_code_id = pc.id;
    foreach v_kind in array array['3d', '1d'] loop
      if v_kind = '3d' then
        continue when s.promo_reminder_3d_days = 0;
        v_start := app.local_midnight(v_end - s.promo_reminder_3d_days);
        v_stop := least(app.local_midnight(v_end - 1), pc.valid_until);
      else
        continue when not s.promo_reminder_1d_on;
        v_start := app.local_midnight(v_end - 1);
        v_stop := pc.valid_until;
      end if;
      continue when p_now < v_start or p_now >= v_stop;
      continue when pc.created_at >= v_start;
      continue when exists (select 1 from promo_reminders r where r.promo_code_id = pc.id and r.kind = v_kind);
      if c.id is null then
        -- a code for a renter is an offer: only with their consent, never to a blocked renter
        select r.user_id into v_user from renters r where r.id = pc.renter_id and not r.is_blocked;
        continue when v_user is null or not app.has_marketing_consent(v_user, 'express');
        v_code := 'renter_promo_expiry_' || v_kind;
      else
        v_code := case v_kind when '3d' then 'renter_game_code_reminder_3d' else 'renter_game_code_reminder' end;
      end if;
      insert into promo_reminders (promo_code_id, kind, code, sent_at) values (pc.id, v_kind, v_code, p_now)
      on conflict (promo_code_id, kind) do nothing;
      continue when not found;
      if c.id is not null then
        v_event := app.emit_event(v_code, 'game_claim', c.id, '{}'::jsonb, v_code || ':' || c.id);
        if v_kind = '1d' then update game_claims set reminder_sent_at = coalesce(reminder_sent_at, p_now) where id = c.id; end if;
      else
        v_event := app.emit_event(v_code, 'promo_code', pc.id, jsonb_build_object('renter_id', pc.renter_id), v_code || ':' || pc.id);
      end if;
      update promo_reminders set event_id = v_event where promo_code_id = pc.id and kind = v_kind;
      v_n := v_n + 1;
    end loop;
  end loop;
  return v_n;
end $$;

-- The game job of 0069 (every 30 minutes, pg_cron carmacars-game-reminders): the reminders are now the promo code reminders;
-- the housekeeping is unchanged.
create or replace function app.job_game_reminders(p_now timestamptz default now()) returns text
language plpgsql security definer set search_path = public, app as $$
declare
  ps program_settings := app.settings();
  n integer;
  v_gone integer;
begin
  n := app.promo_reminders_run(p_now);
  -- a claim is kept 24 months after its code expired, unless the person became a customer (the privacy policy)
  delete from leads l using game_claims gc where gc.lead_id = l.id and gc.renter_id is null and gc.expires_at < p_now - interval '24 months';
  with gone as (delete from game_claims gc where gc.renter_id is null and gc.expires_at < p_now - interval '24 months' returning gc.play_id)
  delete from game_plays g using gone where g.id = gone.play_id;
  -- plays never claimed carry no personal information; they go after the visit records' period
  delete from game_plays g where g.claimed_at is null and g.created_at < p_now - make_interval(days => ps.visitor_events_keep_days);
  get diagnostics v_gone = row_count;
  return format('%s reminders, %s old plays removed', n, v_gone);
end $$;

-- ================================================================ 5. who gets it, and what it says
alter function app.notification_recipients(app_events, notification_catalogue) rename to notification_recipients_pre0161;
create function app.notification_recipients(p_event app_events, p_c notification_catalogue)
returns table (audience text, user_id uuid, email text, name text, renter_id uuid, owner_id uuid, immediate boolean)
language plpgsql stable security definer set search_path = public, app as $$
begin
  if p_c.code = 'renter_game_code_reminder_3d' then
    return query select 'renter'::text, c.user_id, c.email, c.first_name, c.renter_id, null::uuid, true
                   from game_claims c where c.id = p_event.entity_id;
    return;
  end if;
  return query select * from app.notification_recipients_pre0161(p_event, p_c);
end $$;
select pg_temp.copy_grants('app.notification_recipients(app_events, notification_catalogue)'::regprocedure, 'app.notification_recipients_pre0161(app_events, notification_catalogue)'::regprocedure);

alter function app.notification_payload(text, app_events, jsonb) rename to ntf_payload_pre0161;
create function app.notification_payload(p_code text, p_event app_events, p_to jsonb) returns jsonb
language plpgsql stable security definer set search_path = public, app as $$
declare
  x jsonb := app.ntf_payload_pre0161(p_code, p_event, p_to);
  pc promo_codes;
begin
  if p_code in ('renter_game_code', 'renter_game_code_reminder', 'renter_game_code_reminder_3d') and p_event.entity = 'game_claim' then
    select k.* into pc from game_claims g join promo_codes k on k.id = g.promo_code_id where g.id = p_event.entity_id;
  elsif p_code in ('renter_promo_expiry_3d', 'renter_promo_expiry_1d') and p_event.entity = 'promo_code' then
    select * into pc from promo_codes where id = p_event.entity_id;
  end if;
  if pc.id is not null then
    -- the values the earlier wording of a game code email already has stay as they were; the new emails get all of them
    x := app.promo_email_values(pc, app.local_date(p_event.created_at)) || x;
  end if;
  return x;
end $$;
select pg_temp.copy_grants('app.notification_payload(text, app_events, jsonb)'::regprocedure, 'app.ntf_payload_pre0161(text, app_events, jsonb)'::regprocedure);

-- ================================================================ 6. Admin: the codes with their end dates and reminders
alter function app.admin_settings() rename to admin_settings_pre0161;
create function app.admin_settings() returns jsonb
language sql stable security definer set search_path = public, app as $$
  select app.admin_settings_pre0161() || jsonb_build_object(
    -- the codes Admin makes and edits (campaigns and codes for one renter), with their end date and reminders
    'promo_codes', coalesce((select jsonb_agg(to_jsonb(x) || jsonb_build_object('uses', (select count(*) from promo_redemptions r where r.promo_code_id = x.id),
                                'reminders', app.promo_reminder_marks(x.id), 'personal', app.promo_is_personal(x.renter_id, x.source), 'status', app.promo_status(x))
                              order by x.created_at desc)
                               from promo_codes x where x.source not in ('discount_game', 'followup_7d', 'followup_30d', 'live_visitors')), '[]'::jsonb),
    -- the codes sent to people (games, come-back offers, Live visitors): read only, the latest 200
    'promo_personal', coalesce((select jsonb_agg(y.row order by (y.row ->> 'created_at') desc) from (
        select jsonb_build_object('id', x.id, 'code', x.code, 'source', x.source, 'percent_bps', x.percent_bps, 'amount_cents', x.amount_cents, 'free_days', x.free_days,
                 'valid_until', x.valid_until, 'is_active', x.is_active, 'created_at', x.created_at, 'status', app.promo_status(x),
                 'uses', (select count(*) from promo_redemptions r where r.promo_code_id = x.id), 'reminders', app.promo_reminder_marks(x.id)) as row
          from promo_codes x where x.source in ('discount_game', 'followup_7d', 'followup_30d', 'live_visitors') order by x.created_at desc limit 200) y), '[]'::jsonb),
    'promo_personal_count', (select count(*) from promo_codes x where x.source in ('discount_game', 'followup_7d', 'followup_30d', 'live_visitors')));
$$;
select pg_temp.copy_grants('app.admin_settings()'::regprocedure, 'app.admin_settings_pre0161()'::regprocedure);

-- ================================================================ 7. the renter's codes
create or replace function app.my_promo_codes(p_user uuid) returns jsonb
language sql stable security definer set search_path = public, app as $$
  select coalesce(jsonb_agg(jsonb_build_object('code', y.code, 'what', y.what, 'applies_to', y.applies_to, 'valid_until', y.valid_until,
           'ends', y.ends, 'days_left', y.days_left, 'status', y.status) order by y.sort, y.valid_until nulls last), '[]'::jsonb)
    from (
      select pc.code, app.promo_label(pc) as what, app.promo_applies_to(pc) as applies_to, pc.valid_until,
             case when pc.valid_until is null then null else app.fmt_day(app.promo_last_day(pc)) end as ends,
             case when pc.valid_until is null or pc.valid_until <= now() then null else greatest(app.promo_last_day(pc) - app.today(), 0) end as days_left,
             app.promo_status(pc) as status,
             case app.promo_status(pc) when 'open' then 0 when 'on_request' then 1 else 2 end as sort
        from promo_codes pc
       where pc.is_active and app.promo_status(pc) in ('open', 'on_request', 'expired')
         and (pc.valid_until is null or pc.valid_until > now() - interval '14 days')
         and (pc.renter_id in (select r.id from renters r where r.user_id = p_user)
              or exists (select 1 from game_claims g where g.promo_code_id = pc.id
                          and (g.user_id = p_user or g.renter_id in (select r.id from renters r where r.user_id = p_user))))
    ) y
$$;
create or replace function public.server_my_promo_codes(p_user uuid) returns jsonb
language sql stable security invoker set search_path = public, app as $$ select app.my_promo_codes(p_user) $$;

-- ================================================================ 8. grants of the new functions
select pg_temp.service_only(p.oid::regprocedure)
  from pg_proc p join pg_namespace n on n.oid = p.pronamespace
 where (n.nspname = 'app' and p.proname = any (array['promo_is_personal', 'promo_default_days', 'promo_code_expiry_guard', 'promo_label', 'promo_applies_to',
         'promo_last_day', 'promo_status', 'promo_reminder_marks', 'promo_email_values', 'promo_reminders_cancel', 'promo_redemption_cancels_reminders',
         'promo_reminders_run', 'job_game_reminders', 'my_promo_codes']))
    or (n.nspname = 'public' and p.proname = 'server_my_promo_codes');

-- ================================================================ 9. the email catalogue
-- CATALOGUE 0161 START (generated by supabase/seed/0161_gen_catalogue.mjs; do not edit by hand)
insert into notification_catalogue (code, audience, also_sent_to, category, is_digest, digest_slot, from_address, reply_to,
    subject, preheader, timing, trigger_text, replaces_template, link_path, variables, template_html, template_text) values
  ('renter_promo_expiry_3d', 'renter', '{}'::text[], 'marketing', false, null, 'CarmaCars <hello@carmacars.ca>', 'contact@carmacars.ca', 'Your {{prize_label}} code ends in {{days_left}}', 'Code {{discount_code}} is good until {{discount_expires}}.', 'promo_reminder_3d_days (3) days before the last day of the code', 'Promo code expiry (migration 0161): a discount code issued to a person (a come-back offer, a Live visitors code, a code made for one renter) has not been used and its last day is promo_reminder_3d_days days away (3 by default). Sent once per code, to the renter it was issued to, only while they have agreed to get offers and have not unsubscribed, never once the code is on a booking request, and only inside the sending hours. Discount game codes have their own transactional reminder (renter_game_code_reminder_3d).', null, '/cars', '[{"name":"company_address","type":"string","global":true},{"name":"contact_email","type":"string","global":true},{"name":"days_left","type":"string"},{"name":"discount_applies_to","type":"string"},{"name":"discount_code","type":"string"},{"name":"discount_expires","type":"string"},{"name":"discount_terms","type":"string"},{"name":"first_name","type":"string"},{"name":"instagram_url","type":"url","global":true},{"name":"opening_hours","type":"string","global":true},{"name":"prize_label","type":"string"},{"name":"reply_time","type":"string","global":true},{"name":"support_phone","type":"string","global":true},{"name":"tiktok_url","type":"url","global":true},{"name":"unsubscribe_url","type":"url"}]'::jsonb, 'templates/renter_promo_expiry_3d.html', 'templates/renter_promo_expiry_3d.txt'),
  ('renter_promo_expiry_1d', 'renter', '{}'::text[], 'marketing', false, null, 'CarmaCars <hello@carmacars.ca>', 'contact@carmacars.ca', 'Your {{prize_label}} code ends tomorrow', 'Code {{discount_code}} is good until {{discount_expires}}.', 'The day before the last day of the code', 'Promo code expiry (migration 0161): a discount code issued to a person (a come-back offer, a Live visitors code, a code made for one renter) has not been used and its last day is tomorrow (promo_reminder_1d_on). Sent once per code, to the renter it was issued to, only while they have agreed to get offers and have not unsubscribed, never once the code is on a booking request, and only inside the sending hours. Discount game codes have their own transactional reminder (renter_game_code_reminder).', null, '/cars', '[{"name":"company_address","type":"string","global":true},{"name":"contact_email","type":"string","global":true},{"name":"discount_applies_to","type":"string"},{"name":"discount_code","type":"string"},{"name":"discount_expires","type":"string"},{"name":"discount_terms","type":"string"},{"name":"first_name","type":"string"},{"name":"instagram_url","type":"url","global":true},{"name":"opening_hours","type":"string","global":true},{"name":"prize_label","type":"string"},{"name":"reply_time","type":"string","global":true},{"name":"support_phone","type":"string","global":true},{"name":"tiktok_url","type":"url","global":true},{"name":"unsubscribe_url","type":"url"}]'::jsonb, 'templates/renter_promo_expiry_1d.html', 'templates/renter_promo_expiry_1d.txt'),
  ('renter_game_code_reminder_3d', 'renter', '{}'::text[], 'transactional', false, null, 'CarmaCars <hello@carmacars.ca>', 'contact@carmacars.ca', 'Your {{prize_label}} code ends in {{days_left}}', 'Code {{discount_code}} is good until {{discount_expires}}.', 'promo_reminder_3d_days (3) days before the last day of the code', 'Promo code expiry (migration 0161): a code won in a discount game on the site has not been used and its last day is promo_reminder_3d_days days away (3 by default). Sent once per code, to the address that claimed it. Transactional: a reminder of the code they asked for, like the day-before reminder (renter_game_code_reminder). Not sent once the code is on a booking request.', null, '/cars', '[{"name":"company_address","type":"string","global":true},{"name":"contact_email","type":"string","global":true},{"name":"days_left","type":"string"},{"name":"discount_applies_to","type":"string"},{"name":"discount_code","type":"string"},{"name":"discount_expires","type":"string"},{"name":"discount_terms","type":"string"},{"name":"first_name","type":"string"},{"name":"instagram_url","type":"url","global":true},{"name":"opening_hours","type":"string","global":true},{"name":"prize_label","type":"string"},{"name":"reply_time","type":"string","global":true},{"name":"support_phone","type":"string","global":true},{"name":"tiktok_url","type":"url","global":true}]'::jsonb, 'templates/renter_game_code_reminder_3d.html', 'templates/renter_game_code_reminder_3d.txt'),
  ('renter_game_code_reminder', 'renter', '{}'::text[], 'transactional', false, null, 'CarmaCars <hello@carmacars.ca>', 'contact@carmacars.ca', 'Your {{prize_label}} code ends tomorrow', 'Code {{discount_code}} is good until {{discount_expires}}.', 'The day before the last day of the code', 'A code won in a discount game on the site has not been used and its last day is tomorrow (promo_reminder_1d_on; since migration 0161 the game reminder is one of the promo code expiry reminders, with the same day rule). Sent once per code, to the address that claimed it. Transactional: a reminder of the code they asked for. Not sent once the code is on a booking request.', null, '/cars', '[{"name":"company_address","type":"string","global":true},{"name":"contact_email","type":"string","global":true},{"name":"discount_applies_to","type":"string"},{"name":"discount_code","type":"string"},{"name":"discount_expires","type":"string"},{"name":"discount_terms","type":"string"},{"name":"first_name","type":"string"},{"name":"instagram_url","type":"url","global":true},{"name":"opening_hours","type":"string","global":true},{"name":"prize_label","type":"string"},{"name":"reply_time","type":"string","global":true},{"name":"support_phone","type":"string","global":true},{"name":"tiktok_url","type":"url","global":true}]'::jsonb, 'templates/renter_game_code_reminder.html', 'templates/renter_game_code_reminder.txt')
on conflict (code) do update set
  audience = excluded.audience, also_sent_to = excluded.also_sent_to, category = excluded.category,
  is_digest = excluded.is_digest, digest_slot = excluded.digest_slot, from_address = excluded.from_address,
  reply_to = excluded.reply_to, subject = excluded.subject, preheader = excluded.preheader, timing = excluded.timing,
  trigger_text = excluded.trigger_text, replaces_template = excluded.replaces_template, link_path = excluded.link_path,
  variables = excluded.variables, template_html = excluded.template_html, template_text = excluded.template_text,
  in_catalogue = true, updated_at = now();
select app.notification_catalogue_refresh();
-- CATALOGUE 0161 END
update notification_catalogue set consent_rule = 'express' where code in ('renter_promo_expiry_3d', 'renter_promo_expiry_1d');
update notification_catalogue set emitted_by = 'app.promo_reminders_run through app.job_game_reminders (0161)'
 where code in ('renter_promo_expiry_3d', 'renter_promo_expiry_1d', 'renter_game_code_reminder_3d', 'renter_game_code_reminder');

-- ================================================================ 10. texts
insert into sms_templates (code, label, body, urgent, sort_order) values
  ('renter_promo_expiry_3d', 'Code ends soon', 'CarmaCars: your {{prize_label}} code {{discount_code}} ends in {{days_left}}, on {{discount_expires}}. Book now: {{link}}', false, 123),
  ('renter_promo_expiry_1d', 'Code ends tomorrow', 'CarmaCars: your {{prize_label}} code {{discount_code}} ends tomorrow, {{discount_expires}}. Book now: {{link}}', false, 124),
  ('renter_game_code_reminder_3d', 'Game code ends soon', 'CarmaCars: your {{prize_label}} code {{discount_code}} ends in {{days_left}}, on {{discount_expires}}. Book now: {{link}}', false, 125)
on conflict (code) do nothing;
update sms_templates set body = 'CarmaCars: your {{prize_label}} code {{discount_code}} ends tomorrow, {{discount_expires}}. Book now: {{link}}'
 where code = 'renter_game_code_reminder' and body = 'CarmaCars: your {{prize_label}} code {{discount_code}} ends tomorrow. Book now: {{link}}';

-- ================================================================ 11. the guides
-- GUIDES 0161 START (generated by supabase/seed/0161_gen_guides.mjs from docs/guides/content; do not edit by hand)
select app.guide_release_section('renter', 'find-a-car-and-send-a-request', 'chapter', 'start-here', 'Every booking starts as a request. A person checks the car and the price, then sends you an offer. Nothing is charged until you approve, sign and pay.

:::flow
Request | You pick a car and dates
Offer | We confirm the price
Sign | The rental agreement
Pay | Your card is authorized
Verify | Licence, selfie, coverage
Pick up | We hand over the keys
:::

## Find a car

Start on carmacars.ca. You do not need to sign in to look around.

1. Go to `carmacars.ca` and press **Find a car**.
2. Add your pickup and return dates. The list then shows the cars that are free and what the whole trip costs.
3. Narrow the list with Filters: type, seats, transmission and daily rate.
4. Open a car to see its photos, rates, what is included and its own calendar. Its car code (like CC-7F3A) is under the price: quote it when you call or chat with us, and we know the car at once.

![](/guides/img/public-02-cars-desktop-b6cd4fb8.jpg "desktop; size: 1440 880; address: carmacars.ca/cars; pins: 1 86.1 4.0, 2 11.1 56.8, 3 3.0 82.3, 4 34.0 87.5")

## Choose your dates on the car page

1. Under Dates and price, tap your pickup date, then your return date. Hatched days are already booked.
2. Choose the Pickup time and the Return time.
3. Want it brought to you? Tick **Deliver it to me** or **Pick it up from me at the end**. Open Add-ons to add a baby seat, flowers, a full tank and more.
4. Check Your estimate, then press **Request to book**. The add-ons you chose come with you.

![](/guides/img/public-03-car-page-desktop-73be4d63.jpg "desktop; size: 1120 760; address: carmacars.ca/cars/bmw-330i; pins: 1 24.4 39.7, 2 12.9 68.2, 3 3.0 76.2, 4 97.0 50.0")

> Watch out: A request does not hold the car. The car is booked only once you approve the offer, sign and pay.

## Send your request

The request has five short steps. Your answers are saved as you go, so you can come back.

1. Step 1, Dates and delivery: check the car and tap your dates in the calendar.
2. Set the Pickup time and Return time. Any time, day or night, with at least 2 hours of notice.
3. Your request, on the right, shows the estimated total as you go.

![](/guides/img/public-04-book-1-trip-desktop-63a3738b.jpg "desktop; size: 1440 1002; address: carmacars.ca/book/bmw-330i?from=2026-11-25&to=2026-11-28&tf=10:00&tt=10:00; pins: 1 9.2 67.1, 2 15.3 91.0, 3 91.1 54.7")

4. Choose where you get the car: **At our location**, **Deliver it to an address** or **At the airport**. Then choose where you return it.
5. Press **Continue to driver details**.

![](/guides/img/public-04-book-1-trip-desktop-befba4f6.jpg "desktop; size: 760 942; address: carmacars.ca/book/bmw-330i?from=2026-11-25&to=2026-11-28&tf=10:00&tt=10:00; pins: 4 5.3 26.2, 5 61.8 93.3")

6. Step 2, The driver: fill in your first and last name, email, mobile number and date of birth.
7. Someone else will drive too? Add them under Additional drivers. Each needs a G2 or G licence and signs the agreement.
8. Press **Continue to licence**.

![](/guides/img/public-05-book-2-driver-desktop-7b572499.jpg "desktop; size: 980 1032; address: carmacars.ca/book/bmw-330i?from=2026-11-25&to=2026-11-28&tf=10:00&tt=10:00; pins: 6 30.6 21.1, 7 30.6 64.8, 8 55.6 88.0")

9. Step 3: choose your Licence class, for example Ontario G2.
10. Choose how the car is covered: Option 1 (OPCF 27 on your own auto policy), Option 2 (rental coverage on your credit card) or Option 3 (the CarmaCars Protection Plan). You can change this any time before pickup.
11. Choose the Booking type: Standard, or Non-refundable for 10% off with no refund.
12. Add anything we should know in the notes, for example a flight number.
13. Press **Continue to add-ons**. Step 4, Add-ons: tick what you want (see Add-ons below), then press **Review request**.

![](/guides/img/public-06-book-3-licence-desktop-22bb144e.jpg "desktop; size: 760 1452; address: carmacars.ca/book/bmw-330i?from=2026-11-25&to=2026-11-28&tf=10:00&tt=10:00; pins: 9 61.8 11.2, 10 92.1 32.2, 11 92.1 50.4, 12 92.1 66.9, 13 71.7 97.0")

14. Step 5, Check it and send: read every line. Use Edit beside a line to change it.
15. Tick the box to confirm you are 18 or older and agree to the Terms of use and Privacy policy.
16. Press **Send request**. Nothing is charged and no card is needed.

![](/guides/img/public-07-book-4-review-desktop-005f4c0b.jpg "desktop; size: 760 492; address: carmacars.ca/book/bmw-330i?from=2026-11-25&to=2026-11-28&tf=10:00&tt=10:00; pins: 14 92.1 24.8, 15 3.9 59.3, 16 73.7 89.0")

17. The confirmation shows your request number, for example CC-10021. Keep it for any question.
18. A person checks the calendar, your dates and your place, usually within 2 hours, day or night. Your offer arrives by email and in Trips.

![](/guides/img/public-08-book-5-sent-phone-14a99ccf.jpg "phone; size: 390 755; pins: 17 32.8 12.3")

## Upload your licence

Right after you send your request: the front and back of your licence and a selfie holding it.

1. On the Request sent page, press **Upload your licence** (or open your booking and press **Your licence**).
2. Take each photo with your phone, or choose it. Add the licence number and expiry date if we ask: it must be valid after your return.
3. Rented with us before? A licence on file that is still valid is used again; nothing to upload.

> Tip: You need your licence on file to accept the offer.

## Add-ons

Extras for your trip, such as a baby seat, a child or booster seat, flowers waiting in the car, a chauffeur, an umbrella, a phone charger or a full tank of gas.

1. On the car page (under Add-ons) or in step 4 of the request, tick an add-on or use + and − for seats. The estimate shows the price at once.
2. Each add-on shows its price: a trip, a day (with the most for a trip) or an hour. HST is added.
3. Some need notice, for example flowers need 24 hours. Seats and other items show how many are left for your dates.
4. A chauffeur is confirmed by our team in your offer.

With a full tank of gas (prepaid) you can return the car at any fuel level, with no fuel charge.

## Ask in the chat

The chat button sits in the corner of every page.

1. Press it and write your question: a car, your dates, the price, how booking works. The CarmaCars assistant answers right away with prices from our booking system.
2. Want a person? Press **Talk to a person**. When our team is away, leave your name and email or phone with **Send my details** and tick "Email me a copy of this chat".
3. Press **End chat** when you are done. If you gave your email, a copy of the chat arrives by email.

A price in the chat is for the dates you asked. Nothing is booked until you approve an offer, sign and pay.

## Carry on later

- Your name, email and mobile number are saved as you type them, so nothing is lost if you stop. We open an account for you with that email.
- Every form that saves as you type says so under it: "Saved as you type so you can pick up where you left off.", with a link to the privacy policy.
- On the same phone or computer, open `carmacars.ca/account` (or the request page again) to carry on, no password needed.
- We send you one email, "Continue your request". One tap signs you in, confirms your email and opens your request on any device. You need it before you can accept an offer, sign or pay.
- Already have an account? The form says "You have an account: we sent you a sign-in link".
', 'Find a car and send a request', 'Search the fleet, pick dates and add-ons, and send a request in five short steps.',
  'Every booking starts as a request. A person checks the car and the price, then sends you an offer. Nothing is charged until you approve, sign and pay.

:::flow
Request | You pick a car and dates
Offer | We confirm the price
Sign | The rental agreement
Pay | Your card is authorized
Verify | Licence, selfie, coverage
Pick up | We hand over the keys
:::

## Find a car

Start on carmacars.ca. You do not need to sign in to look around.

1. Go to `carmacars.ca` and press **Find a car**.
2. Add your pickup and return dates. The list then shows the cars that are free and what the whole trip costs.
3. Narrow the list with Filters: type, seats, transmission and daily rate.
4. Open a car to see its photos, rates, what is included and its own calendar. Its car code (like CC-7F3A) is under the price: quote it when you call or chat with us, and we know the car at once.

![](/guides/img/public-02-cars-desktop-b6cd4fb8.jpg "desktop; size: 1440 880; address: carmacars.ca/cars; pins: 1 86.1 4.0, 2 11.1 56.8, 3 3.0 82.3, 4 34.0 87.5")

## Choose your dates on the car page

1. Under Dates and price, tap your pickup date, then your return date. Hatched days are already booked.
2. Choose the Pickup time and the Return time.
3. Want it brought to you? Tick **Deliver it to me** or **Pick it up from me at the end**. Open Add-ons to add a baby seat, flowers, a full tank and more.
4. Check Your estimate, then press **Request to book**. The add-ons you chose come with you.

![](/guides/img/public-03-car-page-desktop-73be4d63.jpg "desktop; size: 1120 760; address: carmacars.ca/cars/bmw-330i; pins: 1 24.4 39.7, 2 12.9 68.2, 3 3.0 76.2, 4 97.0 50.0")

> Watch out: A request does not hold the car. The car is booked only once you approve the offer, sign and pay.

## Send your request

The request has five short steps. Your answers are saved as you go, so you can come back.

1. Step 1, Dates and delivery: check the car and tap your dates in the calendar.
2. Set the Pickup time and Return time. Any time, day or night, with at least 2 hours of notice.
3. Your request, on the right, shows the estimated total as you go.

![](/guides/img/public-04-book-1-trip-desktop-63a3738b.jpg "desktop; size: 1440 1002; address: carmacars.ca/book/bmw-330i?from=2026-11-25&to=2026-11-28&tf=10:00&tt=10:00; pins: 1 9.2 67.1, 2 15.3 91.0, 3 91.1 54.7")

4. Choose where you get the car: **At our location**, **Deliver it to an address** or **At the airport**. Then choose where you return it.
5. Press **Continue to driver details**.

![](/guides/img/public-04-book-1-trip-desktop-befba4f6.jpg "desktop; size: 760 942; address: carmacars.ca/book/bmw-330i?from=2026-11-25&to=2026-11-28&tf=10:00&tt=10:00; pins: 4 5.3 26.2, 5 61.8 93.3")

6. Step 2, The driver: fill in your first and last name, email, mobile number and date of birth.
7. Someone else will drive too? Add them under Additional drivers. Each needs a G2 or G licence and signs the agreement.
8. Press **Continue to licence**.

![](/guides/img/public-05-book-2-driver-desktop-7b572499.jpg "desktop; size: 980 1032; address: carmacars.ca/book/bmw-330i?from=2026-11-25&to=2026-11-28&tf=10:00&tt=10:00; pins: 6 30.6 21.1, 7 30.6 64.8, 8 55.6 88.0")

9. Step 3: choose your Licence class, for example Ontario G2.
10. Choose how the car is covered: Option 1 (OPCF 27 on your own auto policy), Option 2 (rental coverage on your credit card) or Option 3 (the CarmaCars Protection Plan). You can change this any time before pickup.
11. Choose the Booking type: Standard, or Non-refundable for 10% off with no refund.
12. Add anything we should know in the notes, for example a flight number.
13. Press **Continue to add-ons**. Step 4, Add-ons: tick what you want (see Add-ons below), then press **Review request**.

![](/guides/img/public-06-book-3-licence-desktop-22bb144e.jpg "desktop; size: 760 1452; address: carmacars.ca/book/bmw-330i?from=2026-11-25&to=2026-11-28&tf=10:00&tt=10:00; pins: 9 61.8 11.2, 10 92.1 32.2, 11 92.1 50.4, 12 92.1 66.9, 13 71.7 97.0")

14. Step 5, Check it and send: read every line. Use Edit beside a line to change it.
15. Tick the box to confirm you are 18 or older and agree to the Terms of use and Privacy policy.
16. Press **Send request**. Nothing is charged and no card is needed.

![](/guides/img/public-07-book-4-review-desktop-005f4c0b.jpg "desktop; size: 760 492; address: carmacars.ca/book/bmw-330i?from=2026-11-25&to=2026-11-28&tf=10:00&tt=10:00; pins: 14 92.1 24.8, 15 3.9 59.3, 16 73.7 89.0")

17. The confirmation shows your request number, for example CC-10021. Keep it for any question.
18. A person checks the calendar, your dates and your place, usually within 2 hours, day or night. Your offer arrives by email and in Trips.

![](/guides/img/public-08-book-5-sent-phone-14a99ccf.jpg "phone; size: 390 755; pins: 17 32.8 12.3")

## Upload your licence

Right after you send your request: the front and back of your licence and a selfie holding it.

1. On the Request sent page, press **Upload your licence** (or open your booking and press **Your licence**).
2. Take each photo with your phone, or choose it. Add the licence number and expiry date if we ask: it must be valid after your return.
3. Rented with us before? A licence on file that is still valid is used again; nothing to upload.

> Tip: You need your licence on file to accept the offer.

## Add-ons

Extras for your trip, such as a baby seat, a child or booster seat, flowers waiting in the car, a chauffeur, an umbrella, a phone charger or a full tank of gas.

1. On the car page (under Add-ons) or in step 4 of the request, tick an add-on or use + and − for seats. The estimate shows the price at once.
2. Each add-on shows its price: a trip, a day (with the most for a trip) or an hour. HST is added.
3. Some need notice, for example flowers need 24 hours. Seats and other items show how many are left for your dates.
4. A chauffeur is confirmed by our team in your offer.

With a full tank of gas (prepaid) you can return the car at any fuel level, with no fuel charge.

## A discount code

A code from a game on the site, an offer we sent you, or from our team.

- On the last step of your request, type it in the promo code box. The price shows the discount at once.
- Every code has a last day. You find it in the email or text that brought the code, and under Your discount codes on Your trips.
- If you have not used a code, we remind you 3 days before its last day and the day before, by email and text as you chose in Profile. A code you won in a game is always reminded; a reminder of an offer comes only if you agreed to get offers, and every email has an Unsubscribe link.
- A code that ended is refused with "This code has expired". You can still send the request without it.

## Ask in the chat

The chat button sits in the corner of every page.

1. Press it and write your question: a car, your dates, the price, how booking works. The CarmaCars assistant answers right away with prices from our booking system.
2. Want a person? Press **Talk to a person**. When our team is away, leave your name and email or phone with **Send my details** and tick "Email me a copy of this chat".
3. Press **End chat** when you are done. If you gave your email, a copy of the chat arrives by email.

A price in the chat is for the dates you asked. Nothing is booked until you approve an offer, sign and pay.

## Carry on later

- Your name, email and mobile number are saved as you type them, so nothing is lost if you stop. We open an account for you with that email.
- Every form that saves as you type says so under it: "Saved as you type so you can pick up where you left off.", with a link to the privacy policy.
- On the same phone or computer, open `carmacars.ca/account` (or the request page again) to carry on, no password needed.
- We send you one email, "Continue your request". One tap signs you in, confirms your email and opens your request on any device. You need it before you can accept an offer, sign or pay.
- Already have an account? The form says "You have an account: we sent you a sign-in link".
',
  '<p class="gd-p">Every booking starts as a request. A person checks the car and the price, then sends you an offer. Nothing is charged until you approve, sign and pay.</p><ol class="gd-flow"><li><b>1</b><span>Request</span><em>You pick a car and dates</em></li><li><b>2</b><span>Offer</span><em>We confirm the price</em></li><li><b>3</b><span>Sign</span><em>The rental agreement</em></li><li><b>4</b><span>Pay</span><em>Your card is authorized</em></li><li><b>5</b><span>Verify</span><em>Licence, selfie, coverage</em></li><li><b>6</b><span>Pick up</span><em>We hand over the keys</em></li></ol><section class="gd-task" id="find-a-car-and-send-a-request-find-a-car" data-gd-task><h2 class="gd-h2">Find a car</h2><p class="gd-p">Start on carmacars.ca. You do not need to sign in to look around.</p><div class="gd-stepblock gd-stepblock--below"><div class="gd-stepcol"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">Go to <span class="gd-url">carmacars.ca</span> and press <b class="gd-ui">Find a car</b>.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Add your pickup and return dates. The list then shows the cars that are free and what the whole trip costs.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Narrow the list with Filters: type, seats, transmission and daily rate.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t">Open a car to see its photos, rates, what is included and its own calendar. Its car code (like CC-7F3A) is under the price: quote it when you call or chat with us, and we know the car at once.</div></li></ol></div><figure class="gd-fig gd-fig--desk"><div class="gd-browser"><div class="gd-bar" aria-hidden="true"><i></i><i></i><i></i><span class="gd-addr">carmacars.ca/cars</span></div><div class="gd-imgwrap" style="aspect-ratio:1440/880"><img src="/guides/img/public-02-cars-desktop-b6cd4fb8.jpg" alt="" loading="lazy" decoding="async" width="1440" height="880"><span class="gd-pin" style="left:86.1%;top:4%" aria-hidden="true">1</span><span class="gd-pin" style="left:11.1%;top:56.8%" aria-hidden="true">2</span><span class="gd-pin" style="left:3%;top:82.3%" aria-hidden="true">3</span><span class="gd-pin" style="left:34%;top:87.5%" aria-hidden="true">4</span></div></div></figure></div></section><section class="gd-task" id="find-a-car-and-send-a-request-choose-your-dates-on-the-car-page" data-gd-task><h2 class="gd-h2">Choose your dates on the car page</h2><div class="gd-stepblock gd-stepblock--below"><div class="gd-stepcol"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">Under Dates and price, tap your pickup date, then your return date. Hatched days are already booked.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Choose the Pickup time and the Return time.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Want it brought to you? Tick <b class="gd-ui">Deliver it to me</b> or <b class="gd-ui">Pick it up from me at the end</b>. Open Add-ons to add a baby seat, flowers, a full tank and more.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t">Check Your estimate, then press <b class="gd-ui">Request to book</b>. The add-ons you chose come with you.</div></li></ol></div><figure class="gd-fig gd-fig--desk"><div class="gd-browser"><div class="gd-bar" aria-hidden="true"><i></i><i></i><i></i><span class="gd-addr">carmacars.ca/cars/bmw-330i</span></div><div class="gd-imgwrap" style="aspect-ratio:1120/760"><img src="/guides/img/public-03-car-page-desktop-73be4d63.jpg" alt="" loading="lazy" decoding="async" width="1120" height="760"><span class="gd-pin" style="left:24.4%;top:39.7%" aria-hidden="true">1</span><span class="gd-pin" style="left:12.9%;top:68.2%" aria-hidden="true">2</span><span class="gd-pin" style="left:3%;top:76.2%" aria-hidden="true">3</span><span class="gd-pin" style="left:97%;top:50%" aria-hidden="true">4</span></div></div></figure></div><aside class="gd-box gd-box--warn"><span class="gd-lbl">Watch out</span><div>A request does not hold the car. The car is booked only once you approve the offer, sign and pay.</div></aside></section><section class="gd-task" id="find-a-car-and-send-a-request-send-your-request" data-gd-task><h2 class="gd-h2">Send your request</h2><p class="gd-p">The request has five short steps. Your answers are saved as you go, so you can come back.</p><div class="gd-stepblock gd-stepblock--below"><div class="gd-stepcol"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">Step 1, Dates and delivery: check the car and tap your dates in the calendar.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Set the Pickup time and Return time. Any time, day or night, with at least 2 hours of notice.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Your request, on the right, shows the estimated total as you go.</div></li></ol></div><figure class="gd-fig gd-fig--desk"><div class="gd-browser"><div class="gd-bar" aria-hidden="true"><i></i><i></i><i></i><span class="gd-addr">carmacars.ca/book/bmw-330i?from=2026-11-25&amp;to=2026-11-28&amp;tf=10:00&amp;tt=10:00</span></div><div class="gd-imgwrap" style="aspect-ratio:1440/1002"><img src="/guides/img/public-04-book-1-trip-desktop-63a3738b.jpg" alt="" loading="lazy" decoding="async" width="1440" height="1002"><span class="gd-pin" style="left:9.2%;top:67.1%" aria-hidden="true">1</span><span class="gd-pin" style="left:15.3%;top:91%" aria-hidden="true">2</span><span class="gd-pin" style="left:91.1%;top:54.7%" aria-hidden="true">3</span></div></div></figure></div><div class="gd-stepblock gd-stepblock--below"><div class="gd-stepcol"><ol class="gd-ol" start="4"><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t">Choose where you get the car: <b class="gd-ui">At our location</b>, <b class="gd-ui">Deliver it to an address</b> or <b class="gd-ui">At the airport</b>. Then choose where you return it.</div></li><li><span class="gd-n" aria-hidden="true">5</span><div class="gd-t">Press <b class="gd-ui">Continue to driver details</b>.</div></li></ol></div><figure class="gd-fig gd-fig--desk"><div class="gd-browser"><div class="gd-bar" aria-hidden="true"><i></i><i></i><i></i><span class="gd-addr">carmacars.ca/book/bmw-330i?from=2026-11-25&amp;to=2026-11-28&amp;tf=10:00&amp;tt=10:00</span></div><div class="gd-imgwrap" style="aspect-ratio:760/942"><img src="/guides/img/public-04-book-1-trip-desktop-befba4f6.jpg" alt="" loading="lazy" decoding="async" width="760" height="942"><span class="gd-pin" style="left:5.3%;top:26.2%" aria-hidden="true">4</span><span class="gd-pin" style="left:61.8%;top:93.3%" aria-hidden="true">5</span></div></div></figure></div><div class="gd-stepblock gd-stepblock--below"><div class="gd-stepcol"><ol class="gd-ol" start="6"><li><span class="gd-n" aria-hidden="true">6</span><div class="gd-t">Step 2, The driver: fill in your first and last name, email, mobile number and date of birth.</div></li><li><span class="gd-n" aria-hidden="true">7</span><div class="gd-t">Someone else will drive too? Add them under Additional drivers. Each needs a G2 or G licence and signs the agreement.</div></li><li><span class="gd-n" aria-hidden="true">8</span><div class="gd-t">Press <b class="gd-ui">Continue to licence</b>.</div></li></ol></div><figure class="gd-fig gd-fig--desk"><div class="gd-browser"><div class="gd-bar" aria-hidden="true"><i></i><i></i><i></i><span class="gd-addr">carmacars.ca/book/bmw-330i?from=2026-11-25&amp;to=2026-11-28&amp;tf=10:00&amp;tt=10:00</span></div><div class="gd-imgwrap" style="aspect-ratio:980/1032"><img src="/guides/img/public-05-book-2-driver-desktop-7b572499.jpg" alt="" loading="lazy" decoding="async" width="980" height="1032"><span class="gd-pin" style="left:30.6%;top:21.1%" aria-hidden="true">6</span><span class="gd-pin" style="left:30.6%;top:64.8%" aria-hidden="true">7</span><span class="gd-pin" style="left:55.6%;top:88%" aria-hidden="true">8</span></div></div></figure></div><div class="gd-stepblock gd-stepblock--below"><div class="gd-stepcol"><ol class="gd-ol" start="9"><li><span class="gd-n" aria-hidden="true">9</span><div class="gd-t">Step 3: choose your Licence class, for example Ontario G2.</div></li><li><span class="gd-n" aria-hidden="true">10</span><div class="gd-t">Choose how the car is covered: Option 1 (OPCF 27 on your own auto policy), Option 2 (rental coverage on your credit card) or Option 3 (the CarmaCars Protection Plan). You can change this any time before pickup.</div></li><li><span class="gd-n" aria-hidden="true">11</span><div class="gd-t">Choose the Booking type: Standard, or Non-refundable for 10% off with no refund.</div></li><li><span class="gd-n" aria-hidden="true">12</span><div class="gd-t">Add anything we should know in the notes, for example a flight number.</div></li><li><span class="gd-n" aria-hidden="true">13</span><div class="gd-t">Press <b class="gd-ui">Continue to add-ons</b>. Step 4, Add-ons: tick what you want (see Add-ons below), then press <b class="gd-ui">Review request</b>.</div></li></ol></div><figure class="gd-fig gd-fig--desk"><div class="gd-browser"><div class="gd-bar" aria-hidden="true"><i></i><i></i><i></i><span class="gd-addr">carmacars.ca/book/bmw-330i?from=2026-11-25&amp;to=2026-11-28&amp;tf=10:00&amp;tt=10:00</span></div><div class="gd-imgwrap" style="aspect-ratio:760/1452"><img src="/guides/img/public-06-book-3-licence-desktop-22bb144e.jpg" alt="" loading="lazy" decoding="async" width="760" height="1452"><span class="gd-pin" style="left:61.8%;top:11.2%" aria-hidden="true">9</span><span class="gd-pin" style="left:92.1%;top:32.2%" aria-hidden="true">10</span><span class="gd-pin" style="left:92.1%;top:50.4%" aria-hidden="true">11</span><span class="gd-pin" style="left:92.1%;top:66.9%" aria-hidden="true">12</span><span class="gd-pin" style="left:71.7%;top:97%" aria-hidden="true">13</span></div></div></figure></div><div class="gd-stepblock gd-stepblock--below"><div class="gd-stepcol"><ol class="gd-ol" start="14"><li><span class="gd-n" aria-hidden="true">14</span><div class="gd-t">Step 5, Check it and send: read every line. Use Edit beside a line to change it.</div></li><li><span class="gd-n" aria-hidden="true">15</span><div class="gd-t">Tick the box to confirm you are 18 or older and agree to the Terms of use and Privacy policy.</div></li><li><span class="gd-n" aria-hidden="true">16</span><div class="gd-t">Press <b class="gd-ui">Send request</b>. Nothing is charged and no card is needed.</div></li></ol></div><figure class="gd-fig gd-fig--desk"><div class="gd-browser"><div class="gd-bar" aria-hidden="true"><i></i><i></i><i></i><span class="gd-addr">carmacars.ca/book/bmw-330i?from=2026-11-25&amp;to=2026-11-28&amp;tf=10:00&amp;tt=10:00</span></div><div class="gd-imgwrap" style="aspect-ratio:760/492"><img src="/guides/img/public-07-book-4-review-desktop-005f4c0b.jpg" alt="" loading="lazy" decoding="async" width="760" height="492"><span class="gd-pin" style="left:92.1%;top:24.8%" aria-hidden="true">14</span><span class="gd-pin" style="left:3.9%;top:59.3%" aria-hidden="true">15</span><span class="gd-pin" style="left:73.7%;top:89%" aria-hidden="true">16</span></div></div></figure></div><div class="gd-stepblock gd-stepblock--side"><div class="gd-stepcol"><ol class="gd-ol" start="17"><li><span class="gd-n" aria-hidden="true">17</span><div class="gd-t">The confirmation shows your request number, for example CC-10021. Keep it for any question.</div></li><li><span class="gd-n" aria-hidden="true">18</span><div class="gd-t">A person checks the calendar, your dates and your place, usually within 2 hours, day or night. Your offer arrives by email and in Trips.</div></li></ol></div><figure class="gd-fig gd-fig--phone"><div class="gd-phone"><div class="gd-imgwrap" style="aspect-ratio:390/755"><img src="/guides/img/public-08-book-5-sent-phone-14a99ccf.jpg" alt="" loading="lazy" decoding="async" width="390" height="755"><span class="gd-pin" style="left:32.8%;top:12.3%" aria-hidden="true">17</span></div></div></figure></div></section><section class="gd-task" id="find-a-car-and-send-a-request-upload-your-licence" data-gd-task><h2 class="gd-h2">Upload your licence</h2><p class="gd-p">Right after you send your request: the front and back of your licence and a selfie holding it.</p><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">On the Request sent page, press <b class="gd-ui">Upload your licence</b> (or open your booking and press <b class="gd-ui">Your licence</b>).</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Take each photo with your phone, or choose it. Add the licence number and expiry date if we ask: it must be valid after your return.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Rented with us before? A licence on file that is still valid is used again; nothing to upload.</div></li></ol></div><aside class="gd-box"><span class="gd-lbl">Tip</span><div>You need your licence on file to accept the offer.</div></aside></section><section class="gd-task" id="find-a-car-and-send-a-request-add-ons" data-gd-task><h2 class="gd-h2">Add-ons</h2><p class="gd-p">Extras for your trip, such as a baby seat, a child or booster seat, flowers waiting in the car, a chauffeur, an umbrella, a phone charger or a full tank of gas.</p><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">On the car page (under Add-ons) or in step 4 of the request, tick an add-on or use + and − for seats. The estimate shows the price at once.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Each add-on shows its price: a trip, a day (with the most for a trip) or an hour. HST is added.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Some need notice, for example flowers need 24 hours. Seats and other items show how many are left for your dates.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t">A chauffeur is confirmed by our team in your offer.</div></li></ol></div><p class="gd-p">With a full tank of gas (prepaid) you can return the car at any fuel level, with no fuel charge.</p></section><section class="gd-task" id="find-a-car-and-send-a-request-a-discount-code" data-gd-task><h2 class="gd-h2">A discount code</h2><p class="gd-p">A code from a game on the site, an offer we sent you, or from our team.</p><ul class="gd-ul"><li>On the last step of your request, type it in the promo code box. The price shows the discount at once.</li><li>Every code has a last day. You find it in the email or text that brought the code, and under Your discount codes on Your trips.</li><li>If you have not used a code, we remind you 3 days before its last day and the day before, by email and text as you chose in Profile. A code you won in a game is always reminded; a reminder of an offer comes only if you agreed to get offers, and every email has an Unsubscribe link.</li><li>A code that ended is refused with &quot;This code has expired&quot;. You can still send the request without it.</li></ul></section><section class="gd-task" id="find-a-car-and-send-a-request-ask-in-the-chat" data-gd-task><h2 class="gd-h2">Ask in the chat</h2><p class="gd-p">The chat button sits in the corner of every page.</p><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">Press it and write your question: a car, your dates, the price, how booking works. The CarmaCars assistant answers right away with prices from our booking system.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Want a person? Press <b class="gd-ui">Talk to a person</b>. When our team is away, leave your name and email or phone with <b class="gd-ui">Send my details</b> and tick &quot;Email me a copy of this chat&quot;.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Press <b class="gd-ui">End chat</b> when you are done. If you gave your email, a copy of the chat arrives by email.</div></li></ol></div><p class="gd-p">A price in the chat is for the dates you asked. Nothing is booked until you approve an offer, sign and pay.</p></section><section class="gd-task" id="find-a-car-and-send-a-request-carry-on-later" data-gd-task><h2 class="gd-h2">Carry on later</h2><ul class="gd-ul"><li>Your name, email and mobile number are saved as you type them, so nothing is lost if you stop. We open an account for you with that email.</li><li>Every form that saves as you type says so under it: &quot;Saved as you type so you can pick up where you left off.&quot;, with a link to the privacy policy.</li><li>On the same phone or computer, open <span class="gd-url">carmacars.ca/account</span> (or the request page again) to carry on, no password needed.</li><li>We send you one email, &quot;Continue your request&quot;. One tap signs you in, confirms your email and opens your request on any device. You need it before you can accept an offer, sign or pay.</li><li>Already have an account? The form says &quot;You have an account: we sent you a sign-in link&quot;.</li></ul></section>');
select app.guide_release_section('admin', 'discount-games-and-leads', 'chapter', 'text-alerts-email-text-or-both', 'Visitors who are not signed in and browse a few cars get one quick game: spin the wheel, scratch to reveal, quick blackjack, cup shuffle or Plinko. Every play wins a promo code. To see the code they give a first name and an email (a mobile number is optional), so you get a lead. It is on by default; nothing needs setting up.

## What the visitor sees

- After 2 car pages, or 60 seconds on the site, or (on a computer) when the mouse heads for the tabs. A card slides in at the bottom; on a phone it is a sheet at the bottom, never a full-screen block, and it always closes.
- Never for someone signed in or already known by email, never on booking, pay, sign or sign-in pages, never on the first page of a visit from a search engine on a phone, never over the cookie banner. After closing it, not again for 14 days; after claiming, never again.
- Every play wins: 5% off (70 in 100), 10% off (25), 15% off (4) or $50 off a rental of 3 days or more (1). The prize is decided before the game starts; the game only shows it. The short terms with the game list the prizes and say the chances differ.
- The code (for example WIN-7KQ4-XM2P) comes off the rental charge only, up to $75 for a percentage, on one booking, within 7 days, one per person, email, phone and device, never with another code. The email with the code goes either way; one reminder goes 24 hours before it expires. Offers only with the marketing box ticked.
- On this device the code fills itself into the promo code box of the request form. Like every promo code, the discount is shared with the owner in the split.

## Leads

**Bookings** > **Renter leads**.

1. The tiles: plays, claims, codes on booking requests, bookings, revenue and discounts from game codes in the last 30 days, then the same by game and by prize.
2. Each claim: when, the name (and "on the site now"), email and phone, the prize and game, the code and whether it is used (with the booking), marketing consent, and the visit: cars and pages viewed, minutes, city and device.
3. Press **Call** or **Email**, then **Contacted** (it is yours). **Close** with a reason when there is nothing more to do. A booking with the code marks the lead converted by itself.
4. A visitor who viewed 3 cars or more also gets a Sales task, for example "Claimed 10% off, viewed 6 cars: Maya". It closes when the code goes on a request.

## Contact details typed into forms

**Bookings** > **Renter leads**, the card "Typed into forms" at the top.

1. When someone types a name, email or phone into the request to book, the contact form, List your car, the owner application, Create an account, the discount game or the chat, it is saved as soon as each field is valid, even if they never press Send.
2. Each line: when, the name (and "On the site now"), email and phone, the form, and Sent or Not sent. "Email not confirmed" means the account was opened from the form and the person has not opened the link we emailed them yet.
3. After 30 minutes without sending, To do shows "Unfinished request from Maya Chen: follow up" (not raised from 23:00 to 07:00, the quiet hours of the site alerts). Call or email them; the task closes by itself when they send the form.
4. Only what they typed is saved, and never used for offers without their consent.

> Good to know: A new email gets an account at once (no password, email not confirmed) and one email "Continue your request" 30 minutes later, between 9:00 and 21:00. Until they open its link they cannot accept an offer, sign, pay or upload documents. An account never confirmed closes after 30 days; the lead stays. It is on by default; the times and the To do are in **Settings** > **Program**, the card "Forms left unfinished".

## Settings

**Settings** > **Discount games**.

- On or off, the cap for percentage codes ($75), how long a code is good for (7 days), when it shows (1 car page, 15 seconds, exit intent), the days a visitor keeps their prize (14), the cars viewed for a Sales task (3) and the reminder (24 hours).
- After a visitor closes a game, a different one shows on their 2nd page view after the close (any page) or 60 seconds later, whichever first; at most 3 in one visit and 6 a day in one browser. All four are settings. Never on booking, payment or signing pages; the request-to-book form has its own game.
- Prizes and games: each prize with its percent or dollars, a minimum rental length and its chance; each game''s weight (0 turns it off). Press **Save prizes and games**. Codes already sent keep their value.
', 'Discount games and leads', 'The giveaway game, the code it sends, game leads to call, and the report.',
  'Visitors who are not signed in and browse a few cars get one quick game: spin the wheel, scratch to reveal, quick blackjack, cup shuffle or Plinko. Every play wins a promo code. To see the code they give a first name and an email (a mobile number is optional), so you get a lead. It is on by default; nothing needs setting up.

## What the visitor sees

- After 2 car pages, or 60 seconds on the site, or (on a computer) when the mouse heads for the tabs. A card slides in at the bottom; on a phone it is a sheet at the bottom, never a full-screen block, and it always closes.
- Never for someone signed in or already known by email, never on booking, pay, sign or sign-in pages, never on the first page of a visit from a search engine on a phone, never over the cookie banner. After closing it, not again for 14 days; after claiming, never again.
- Every play wins: 5% off (70 in 100), 10% off (25), 15% off (4) or $50 off a rental of 3 days or more (1). The prize is decided before the game starts; the game only shows it. The short terms with the game list the prizes and say the chances differ.
- The code (for example WIN-7KQ4-XM2P) comes off the rental charge only, up to $75 for a percentage, on one booking, within 7 days, one per person, email, phone and device, never with another code. The email with the code goes either way; a reminder goes 3 days before its last day and another the day before (Promo codes). Offers only with the marketing box ticked.
- On this device the code fills itself into the promo code box of the request form. Like every promo code, the discount is shared with the owner in the split.

## Leads

**Bookings** > **Renter leads**.

1. The tiles: plays, claims, codes on booking requests, bookings, revenue and discounts from game codes in the last 30 days, then the same by game and by prize.
2. Each claim: when, the name (and "on the site now"), email and phone, the prize and game, the code and whether it is used (with the booking), marketing consent, and the visit: cars and pages viewed, minutes, city and device.
3. Press **Call** or **Email**, then **Contacted** (it is yours). **Close** with a reason when there is nothing more to do. A booking with the code marks the lead converted by itself.
4. A visitor who viewed 3 cars or more also gets a Sales task, for example "Claimed 10% off, viewed 6 cars: Maya". It closes when the code goes on a request.

## Contact details typed into forms

**Bookings** > **Renter leads**, the card "Typed into forms" at the top.

1. When someone types a name, email or phone into the request to book, the contact form, List your car, the owner application, Create an account, the discount game or the chat, it is saved as soon as each field is valid, even if they never press Send.
2. Each line: when, the name (and "On the site now"), email and phone, the form, and Sent or Not sent. "Email not confirmed" means the account was opened from the form and the person has not opened the link we emailed them yet.
3. After 30 minutes without sending, To do shows "Unfinished request from Maya Chen: follow up" (not raised from 23:00 to 07:00, the quiet hours of the site alerts). Call or email them; the task closes by itself when they send the form.
4. Only what they typed is saved, and never used for offers without their consent.

> Good to know: A new email gets an account at once (no password, email not confirmed) and one email "Continue your request" 30 minutes later, between 9:00 and 21:00. Until they open its link they cannot accept an offer, sign, pay or upload documents. An account never confirmed closes after 30 days; the lead stays. It is on by default; the times and the To do are in **Settings** > **Program**, the card "Forms left unfinished".

## Settings

**Settings** > **Discount games**.

- On or off, the cap for percentage codes ($75), how long a code is good for (7 days), when it shows (1 car page, 15 seconds, exit intent), the days a visitor keeps their prize (14), and the cars viewed for a Sales task (3). The reminders before a code ends are under Promo codes.
- After a visitor closes a game, a different one shows on their 2nd page view after the close (any page) or 60 seconds later, whichever first; at most 3 in one visit and 6 a day in one browser. All four are settings. Never on booking, payment or signing pages; the request-to-book form has its own game.
- Prizes and games: each prize with its percent or dollars, a minimum rental length and its chance; each game''s weight (0 turns it off). Press **Save prizes and games**. Codes already sent keep their value.
',
  '<p class="gd-p">Visitors who are not signed in and browse a few cars get one quick game: spin the wheel, scratch to reveal, quick blackjack, cup shuffle or Plinko. Every play wins a promo code. To see the code they give a first name and an email (a mobile number is optional), so you get a lead. It is on by default; nothing needs setting up.</p><section class="gd-task" id="discount-games-and-leads-what-the-visitor-sees" data-gd-task><h2 class="gd-h2">What the visitor sees</h2><ul class="gd-ul"><li>After 2 car pages, or 60 seconds on the site, or (on a computer) when the mouse heads for the tabs. A card slides in at the bottom; on a phone it is a sheet at the bottom, never a full-screen block, and it always closes.</li><li>Never for someone signed in or already known by email, never on booking, pay, sign or sign-in pages, never on the first page of a visit from a search engine on a phone, never over the cookie banner. After closing it, not again for 14 days; after claiming, never again.</li><li>Every play wins: 5% off (70 in 100), 10% off (25), 15% off (4) or $50 off a rental of 3 days or more (1). The prize is decided before the game starts; the game only shows it. The short terms with the game list the prizes and say the chances differ.</li><li>The code (for example WIN-7KQ4-XM2P) comes off the rental charge only, up to $75 for a percentage, on one booking, within 7 days, one per person, email, phone and device, never with another code. The email with the code goes either way; a reminder goes 3 days before its last day and another the day before (Promo codes). Offers only with the marketing box ticked.</li><li>On this device the code fills itself into the promo code box of the request form. Like every promo code, the discount is shared with the owner in the split.</li></ul></section><section class="gd-task" id="discount-games-and-leads-leads" data-gd-task><h2 class="gd-h2">Leads</h2><p class="gd-p"><b class="gd-ui">Bookings</b> &gt; <b class="gd-ui">Renter leads</b>.</p><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">The tiles: plays, claims, codes on booking requests, bookings, revenue and discounts from game codes in the last 30 days, then the same by game and by prize.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Each claim: when, the name (and &quot;on the site now&quot;), email and phone, the prize and game, the code and whether it is used (with the booking), marketing consent, and the visit: cars and pages viewed, minutes, city and device.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Press <b class="gd-ui">Call</b> or <b class="gd-ui">Email</b>, then <b class="gd-ui">Contacted</b> (it is yours). <b class="gd-ui">Close</b> with a reason when there is nothing more to do. A booking with the code marks the lead converted by itself.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t">A visitor who viewed 3 cars or more also gets a Sales task, for example &quot;Claimed 10% off, viewed 6 cars: Maya&quot;. It closes when the code goes on a request.</div></li></ol></div></section><section class="gd-task" id="discount-games-and-leads-contact-details-typed-into-forms" data-gd-task><h2 class="gd-h2">Contact details typed into forms</h2><p class="gd-p"><b class="gd-ui">Bookings</b> &gt; <b class="gd-ui">Renter leads</b>, the card &quot;Typed into forms&quot; at the top.</p><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">When someone types a name, email or phone into the request to book, the contact form, List your car, the owner application, Create an account, the discount game or the chat, it is saved as soon as each field is valid, even if they never press Send.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Each line: when, the name (and &quot;On the site now&quot;), email and phone, the form, and Sent or Not sent. &quot;Email not confirmed&quot; means the account was opened from the form and the person has not opened the link we emailed them yet.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">After 30 minutes without sending, To do shows &quot;Unfinished request from Maya Chen: follow up&quot; (not raised from 23:00 to 07:00, the quiet hours of the site alerts). Call or email them; the task closes by itself when they send the form.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t">Only what they typed is saved, and never used for offers without their consent.</div></li></ol></div><aside class="gd-box"><span class="gd-lbl">Good to know</span><div>A new email gets an account at once (no password, email not confirmed) and one email &quot;Continue your request&quot; 30 minutes later, between 9:00 and 21:00. Until they open its link they cannot accept an offer, sign, pay or upload documents. An account never confirmed closes after 30 days; the lead stays. It is on by default; the times and the To do are in <b class="gd-ui">Settings</b> &gt; <b class="gd-ui">Program</b>, the card &quot;Forms left unfinished&quot;.</div></aside></section><section class="gd-task" id="discount-games-and-leads-settings" data-gd-task><h2 class="gd-h2">Settings</h2><p class="gd-p"><b class="gd-ui">Settings</b> &gt; <b class="gd-ui">Discount games</b>.</p><ul class="gd-ul"><li>On or off, the cap for percentage codes ($75), how long a code is good for (7 days), when it shows (1 car page, 15 seconds, exit intent), the days a visitor keeps their prize (14), and the cars viewed for a Sales task (3). The reminders before a code ends are under Promo codes.</li><li>After a visitor closes a game, a different one shows on their 2nd page view after the close (any page) or 60 seconds later, whichever first; at most 3 in one visit and 6 a day in one browser. All four are settings. Never on booking, payment or signing pages; the request-to-book form has its own game.</li><li>Prizes and games: each prize with its percent or dollars, a minimum rental length and its chance; each game&#39;s weight (0 turns it off). Press <b class="gd-ui">Save prizes and games</b>. Codes already sent keep their value.</li></ul></section>');
select app.guide_release_section('admin', 'settings', 'chapter', 'search-car-pages-landing-pages-and-guides', 'Settings change the public site and the rules of the program at once. Program settings are kept as dated rows, so earlier values stay on record.

## The Settings page

1. Site setup lists what is still missing on the public site, with **Open site settings**.
2. Site settings: contact details, hours, tagline, logo, socials, Google place id and featured cars.
3. Program settings: every timing and policy value.
4. Forms: Blind Spot''s rental agreement for every booking, and the official ServiceOntario PDFs and what goes in each field.
5. Insurers: insurance companies billed for bookings.

![](/guides/img/admin-24-settings-desktop-89b31691.jpg "desktop; size: 1440 900; address: carmacars.ca/admin/settings; pins: 1 32.6 33.0, 2 25.8 40.2, 3 77.4 40.2, 4 25.8 73.2, 5 25.8 84.9")

The other tiles: Site content (headings, FAQs, legal text), Fee defaults, Deposit tiers, Kilometre choices, Vehicle classes, Airports and delivery, Protection Plan prices, Card coverage, Reviews, Text alerts, Partners (each partner company''s CRM link: see Partners, company cars and rentals added by hand), Email aliases and reply-to, Staff and roles, Promo codes and Quick replies.

## Program settings

1. Turnaround between trips: the time held between two trips. The cleaning block after a trip is this time.
2. Settings come in groups such as Company, Booking requests and offers, Owner debits and statement emails, Deposits, Delivery, Owners and fleet, and Tolls and damage. Open one to see its fields.
3. First reply target for customer service and sales (minutes), under Booking requests and offers: 5 by default. New booking requests, enquiries, changes renters ask for and renter messages are due that many minutes after they come in; the scorecard and the staff screens use it. What renters are told (Reply wording, in Site settings) is separate.
4. Staff commissions and prices typed by hand: the commission outside Sales (10%), the three Sales tiers and their days (10%, 15% from 50 days, 20% from 100 days, the month''s target), the price floor a day (empty: none) and the discount from the rate sheet that flags a price (20%). The owner confirmed these values in October 2026.
5. Staff agreement defaults by function, at the bottom: pay (a month, an hour or commission only), the rate, the schedule (full time, part time or flexible), days a week and hours a day for Customer service, Fleet, Finance and Sales, the values every assistant shares, and the field staff wage. Sales is commission only: no rate and a flexible schedule. Press **Save the defaults**.
6. Live visitors and live chat: recording visits, the signal thresholds, follow-up tasks, the chat and its assistant, and how long visits and chats are kept.
7. Discount games: the same values as Settings, Discount games (the prize table and the games are easier to change there).
8. Field jobs and handovers: field jobs made from each confirmed booking (on) and who gets them (the least busy field staff member, or nobody so Fleet assigns), how field staff may take a deposit at the check-out besides a card (e-Transfer and cash), and whether they may release a car whose tracker is not reporting, with a reason (on; you get an urgent task).
9. Sign-in by phone: codes by text from the CarmaCars number (on), US numbers (off until the Quo number is registered for US texting, A2P 10DLC), codes per number and per connection an hour, and whether a verified phone confirms an account like a confirmed email. Accepting an offer, signing and paying need a confirmed account; an account made by phone gives its email on the pay page before its first payment.
10. Calendar sync, Turo by email, Booking recovery emails and Site check: how often calendar links are read, the Turo inbound address and who may forward to it, the reminder delays and sending hours, and the site check with the address its alerts go to (rent@carmacars.ca), the minutes before an email, the daily limit and the quiet hours.
11. Change a value and press **Save**. It is saved as a new row from today; the rows before stay as they were.

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

## Reviews: review requests and Google

**Settings** > **Reviews**: when review requests go, the Google review link and the Google Business Profile connection. Review requests are on from the start.

1. When review requests go: the check-in (on or off, the shortest rental, hours after the pickup), the request (minutes after the check-in), the reminder (hours) and the final follow-up (days), the sending hours (9 am to 9 pm), and the hold while charges are open.
2. The Google review link: the Google place id (Site settings) makes it, or paste the Business Profile''s own review link.
3. Google Business Profile: press **Connect Google** and sign in with rent@carmacars.ca, then allow access. Reviews are read every 6 hours and matched to renters by name within 30 days after their return.
4. A clear match stops that renter''s reminders at once. A possible match waits in Reviews: press **Confirm**, **Not this renter** or **Match to a booking**.

> Tip: Until Google approves the Business Profile API for the project, the status says so and nothing else changes: renters still get the review link, and "I already left a review", Mark reviewed and on-site reviews still stop the messages.
', 'Settings', 'Site, program settings, official forms mapping, insurers and the other lists.',
  'Settings change the public site and the rules of the program at once. Program settings are kept as dated rows, so earlier values stay on record.

## The Settings page

1. Site setup lists what is still missing on the public site, with **Open site settings**.
2. Site settings: contact details, hours, tagline, logo, socials, Google place id and featured cars.
3. Program settings: every timing and policy value.
4. Forms: Blind Spot''s rental agreement for every booking, and the official ServiceOntario PDFs and what goes in each field.
5. Insurers: insurance companies billed for bookings.

![](/guides/img/admin-24-settings-desktop-89b31691.jpg "desktop; size: 1440 900; address: carmacars.ca/admin/settings; pins: 1 32.6 33.0, 2 25.8 40.2, 3 77.4 40.2, 4 25.8 73.2, 5 25.8 84.9")

The other tiles: Site content (headings, FAQs, legal text), Fee defaults, Deposit tiers, Kilometre choices, Vehicle classes, Airports and delivery, Protection Plan prices, Card coverage, Reviews, Text alerts, Partners (each partner company''s CRM link: see Partners, company cars and rentals added by hand), Email aliases and reply-to, Staff and roles, Promo codes and Quick replies.

## Program settings

1. Turnaround between trips: the time held between two trips. The cleaning block after a trip is this time.
2. Settings come in groups such as Company, Booking requests and offers, Owner debits and statement emails, Deposits, Delivery, Owners and fleet, and Tolls and damage. Open one to see its fields.
3. First reply target for customer service and sales (minutes), under Booking requests and offers: 5 by default. New booking requests, enquiries, changes renters ask for and renter messages are due that many minutes after they come in; the scorecard and the staff screens use it. What renters are told (Reply wording, in Site settings) is separate.
4. Staff commissions and prices typed by hand: the commission outside Sales (10%), the three Sales tiers and their days (10%, 15% from 50 days, 20% from 100 days, the month''s target), the price floor a day (empty: none) and the discount from the rate sheet that flags a price (20%). The owner confirmed these values in October 2026.
5. Staff agreement defaults by function, at the bottom: pay (a month, an hour or commission only), the rate, the schedule (full time, part time or flexible), days a week and hours a day for Customer service, Fleet, Finance and Sales, the values every assistant shares, and the field staff wage. Sales is commission only: no rate and a flexible schedule. Press **Save the defaults**.
6. Live visitors and live chat: recording visits, the signal thresholds, follow-up tasks, the chat and its assistant, and how long visits and chats are kept.
7. Discount games: the same values as Settings, Discount games (the prize table and the games are easier to change there).
8. Field jobs and handovers: field jobs made from each confirmed booking (on) and who gets them (the least busy field staff member, or nobody so Fleet assigns), how field staff may take a deposit at the check-out besides a card (e-Transfer and cash), and whether they may release a car whose tracker is not reporting, with a reason (on; you get an urgent task).
9. Sign-in by phone: codes by text from the CarmaCars number (on), US numbers (off until the Quo number is registered for US texting, A2P 10DLC), codes per number and per connection an hour, and whether a verified phone confirms an account like a confirmed email. Accepting an offer, signing and paying need a confirmed account; an account made by phone gives its email on the pay page before its first payment.
10. Calendar sync, Turo by email, Booking recovery emails and Site check: how often calendar links are read, the Turo inbound address and who may forward to it, the reminder delays and sending hours, and the site check with the address its alerts go to (rent@carmacars.ca), the minutes before an email, the daily limit and the quiet hours.
11. Change a value and press **Save**. It is saved as a new row from today; the rows before stay as they were.

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

## Promo codes: end dates and reminders

**Settings** > **All settings**, **Promo codes**.

- Every code made for a person has an end date: a game prize 7 days, a come-back offer 30, a Live visitors code 3 and a code made for one renter 30 unless you set another. The first card of Promo codes holds the 30 days and the two reminders.
- A code for everyone may have no end date: empty Valid until. The Add form starts with an end date 30 days ahead.
- A code that ended is refused wherever it is typed (the request form, an offer, Add a rental, a booking edit) with "This code has expired".
- A person who has not used a code is reminded 3 days before its last day and the day before, by email and by text as they chose, never once they used it, unsubscribed or the code ended, and never twice. A game code reminder always goes; a reminder of any other code needs their consent to offers.
- The list shows each code''s end date and the reminders sent. The card Codes sent to people lists game prizes, come-back offers and Live visitors codes the same way.

## Card coverage: which credit cards include rental car coverage

**Settings** > **Card coverage** is the list renters see at `carmacars.ca/credit-card-rental-coverage` and staff see under Card coverage in their portal. It starts filled in with 48 Canadian and US cards, each checked on October 23, 2026.

1. The table shows each card: who pays first (Primary, Secondary, or not stated), the car value limit (MSRP), the longest rental, whether the numbers were read in the issuer''s own document, and when it was last checked.
2. Open a card under Change a card, open its official guide, correct what changed and press **Save**. Changing the facts without a date marks the card checked today; type a Last checked date to record another day.
3. A card whose numbers come from a published summary has Read in the issuer''s own document unticked and the summary''s link under Where the numbers came from. The page shows it as Unverified. Tick it once you have read the issuer''s guide.
4. Add a card with the Add form; untick Shown to hide one. Changes reach the public page at once.

> Tip: A card not checked for 6 months shows on Today until it is checked again. The page tells renters to confirm with their card issuer and says CarmaCars decides no claims: keep the list to facts from the issuer''s guide.

## Reviews: review requests and Google

**Settings** > **Reviews**: when review requests go, the Google review link and the Google Business Profile connection. Review requests are on from the start.

1. When review requests go: the check-in (on or off, the shortest rental, hours after the pickup), the request (minutes after the check-in), the reminder (hours) and the final follow-up (days), the sending hours (9 am to 9 pm), and the hold while charges are open.
2. The Google review link: the Google place id (Site settings) makes it, or paste the Business Profile''s own review link.
3. Google Business Profile: press **Connect Google** and sign in with rent@carmacars.ca, then allow access. Reviews are read every 6 hours and matched to renters by name within 30 days after their return.
4. A clear match stops that renter''s reminders at once. A possible match waits in Reviews: press **Confirm**, **Not this renter** or **Match to a booking**.

> Tip: Until Google approves the Business Profile API for the project, the status says so and nothing else changes: renters still get the review link, and "I already left a review", Mark reviewed and on-site reviews still stop the messages.
',
  '<p class="gd-p">Settings change the public site and the rules of the program at once. Program settings are kept as dated rows, so earlier values stay on record.</p><section class="gd-task" id="settings-the-settings-page" data-gd-task><h2 class="gd-h2">The Settings page</h2><div class="gd-stepblock gd-stepblock--below"><div class="gd-stepcol"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">Site setup lists what is still missing on the public site, with <b class="gd-ui">Open site settings</b>.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Site settings: contact details, hours, tagline, logo, socials, Google place id and featured cars.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Program settings: every timing and policy value.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t">Forms: Blind Spot&#39;s rental agreement for every booking, and the official ServiceOntario PDFs and what goes in each field.</div></li><li><span class="gd-n" aria-hidden="true">5</span><div class="gd-t">Insurers: insurance companies billed for bookings.</div></li></ol></div><figure class="gd-fig gd-fig--desk"><div class="gd-browser"><div class="gd-bar" aria-hidden="true"><i></i><i></i><i></i><span class="gd-addr">carmacars.ca/admin/settings</span></div><div class="gd-imgwrap" style="aspect-ratio:1440/900"><img src="/guides/img/admin-24-settings-desktop-89b31691.jpg" alt="" loading="lazy" decoding="async" width="1440" height="900"><span class="gd-pin" style="left:32.6%;top:33%" aria-hidden="true">1</span><span class="gd-pin" style="left:25.8%;top:40.2%" aria-hidden="true">2</span><span class="gd-pin" style="left:77.4%;top:40.2%" aria-hidden="true">3</span><span class="gd-pin" style="left:25.8%;top:73.2%" aria-hidden="true">4</span><span class="gd-pin" style="left:25.8%;top:84.9%" aria-hidden="true">5</span></div></div></figure></div><p class="gd-p">The other tiles: Site content (headings, FAQs, legal text), Fee defaults, Deposit tiers, Kilometre choices, Vehicle classes, Airports and delivery, Protection Plan prices, Card coverage, Reviews, Text alerts, Partners (each partner company&#39;s CRM link: see Partners, company cars and rentals added by hand), Email aliases and reply-to, Staff and roles, Promo codes and Quick replies.</p></section><section class="gd-task" id="settings-program-settings" data-gd-task><h2 class="gd-h2">Program settings</h2><div class="gd-stepblock gd-stepblock--below"><div class="gd-stepcol"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">Turnaround between trips: the time held between two trips. The cleaning block after a trip is this time.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Settings come in groups such as Company, Booking requests and offers, Owner debits and statement emails, Deposits, Delivery, Owners and fleet, and Tolls and damage. Open one to see its fields.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">First reply target for customer service and sales (minutes), under Booking requests and offers: 5 by default. New booking requests, enquiries, changes renters ask for and renter messages are due that many minutes after they come in; the scorecard and the staff screens use it. What renters are told (Reply wording, in Site settings) is separate.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t">Staff commissions and prices typed by hand: the commission outside Sales (10%), the three Sales tiers and their days (10%, 15% from 50 days, 20% from 100 days, the month&#39;s target), the price floor a day (empty: none) and the discount from the rate sheet that flags a price (20%). The owner confirmed these values in October 2026.</div></li><li><span class="gd-n" aria-hidden="true">5</span><div class="gd-t">Staff agreement defaults by function, at the bottom: pay (a month, an hour or commission only), the rate, the schedule (full time, part time or flexible), days a week and hours a day for Customer service, Fleet, Finance and Sales, the values every assistant shares, and the field staff wage. Sales is commission only: no rate and a flexible schedule. Press <b class="gd-ui">Save the defaults</b>.</div></li><li><span class="gd-n" aria-hidden="true">6</span><div class="gd-t">Live visitors and live chat: recording visits, the signal thresholds, follow-up tasks, the chat and its assistant, and how long visits and chats are kept.</div></li><li><span class="gd-n" aria-hidden="true">7</span><div class="gd-t">Discount games: the same values as Settings, Discount games (the prize table and the games are easier to change there).</div></li><li><span class="gd-n" aria-hidden="true">8</span><div class="gd-t">Field jobs and handovers: field jobs made from each confirmed booking (on) and who gets them (the least busy field staff member, or nobody so Fleet assigns), how field staff may take a deposit at the check-out besides a card (e-Transfer and cash), and whether they may release a car whose tracker is not reporting, with a reason (on; you get an urgent task).</div></li><li><span class="gd-n" aria-hidden="true">9</span><div class="gd-t">Sign-in by phone: codes by text from the CarmaCars number (on), US numbers (off until the Quo number is registered for US texting, A2P 10DLC), codes per number and per connection an hour, and whether a verified phone confirms an account like a confirmed email. Accepting an offer, signing and paying need a confirmed account; an account made by phone gives its email on the pay page before its first payment.</div></li><li><span class="gd-n" aria-hidden="true">10</span><div class="gd-t">Calendar sync, Turo by email, Booking recovery emails and Site check: how often calendar links are read, the Turo inbound address and who may forward to it, the reminder delays and sending hours, and the site check with the address its alerts go to (rent@carmacars.ca), the minutes before an email, the daily limit and the quiet hours.</div></li><li><span class="gd-n" aria-hidden="true">11</span><div class="gd-t">Change a value and press <b class="gd-ui">Save</b>. It is saved as a new row from today; the rows before stay as they were.</div></li></ol></div><figure class="gd-fig gd-fig--desk"><div class="gd-browser"><div class="gd-bar" aria-hidden="true"><i></i><i></i><i></i><span class="gd-addr">carmacars.ca/admin/settings/program</span></div><div class="gd-imgwrap" style="aspect-ratio:1440/1000"><img src="/guides/img/admin-25-program-settings-desktop-d16b066c.jpg" alt="" loading="lazy" decoding="async" width="1440" height="1000"><span class="gd-pin" style="left:25.8%;top:22%" aria-hidden="true">1</span><span class="gd-pin" style="left:27.8%;top:49%" aria-hidden="true">2</span></div></div></figure></div></section><section class="gd-task" id="settings-official-serviceontario-forms" data-gd-task><h2 class="gd-h2">Official ServiceOntario forms</h2><p class="gd-p">The five official forms are loaded with a mapping to the owner, car, company and lender details. Each is the form exactly as ServiceOntario publishes it: only its empty text boxes are filled. Its checkboxes, drop-downs and signatures are done by hand at the counter, in ink. Until you check a form, owners get a data sheet with the values.</p><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">Open <b class="gd-ui">Settings</b> &gt; <b class="gd-ui">Forms</b>. Each form shows &quot;Mapping to check&quot; (a draft is ready) or &quot;Official PDF in use&quot;. Its notes say what the form is for and which boxes are left blank on purpose.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Press <b class="gd-ui">Download a filled preview</b> for one car and check each value against the form.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Change a field if needed: What goes in it (or &quot;Signed here by hand, in ink&quot;), a Format (for example YYYY/MM/DD) and Only when. Press Save the mapping.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t">Press <b class="gd-ui">Checked: use for owners</b>. Every owner&#39;s form of that kind is filled again, except ones already signed or filed. Owners download it, print it and sign it in ink; record it with <b class="gd-ui">Record paper signature</b>. Each form not checked yet is also a line on To do with the same button and Preview it.</div></li><li><span class="gd-n" aria-hidden="true">5</span><div class="gd-t">A new version from ServiceOntario? Press <b class="gd-ui">Upload the official fillable PDF</b>: the fields of the same name keep their mapping.</div></li></ol></div><aside class="gd-box"><span class="gd-lbl">Good to know</span><div>SR-LV-006 (registration), SR-LV-012 (two registrants), ON00453 (a company&#39;s RIN), 013-1155 and 013-0169 (the tax-exempt transfer into an owner&#39;s corporation). 013-1155 is sworn before a commissioner, so it is printed and signed in person. ON00453 is an Adobe form: it opens in Adobe Acrobat Reader. Each form&#39;s notes list what to tick or choose at the counter.</div></aside></section><section class="gd-task" id="settings-blind-spot-rental-agreement" data-gd-task><h2 class="gd-h2">Blind Spot rental agreement</h2><p class="gd-p">We rent under Blind Spot Car Rental&#39;s insurance, so every booking has two agreements: CarmaCars&#39; rental agreement and Blind Spot&#39;s own. Blind Spot&#39;s is filled in from the booking, the renter and the car, and the renter signs both with one signature. Its PDF is stored privately, never on the website.</p><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">Open <b class="gd-ui">Settings</b> &gt; <b class="gd-ui">Forms</b>. The Blind Spot Car Rental agreement card is first. Press <b class="gd-ui">Upload Blind Spot&#39;s PDF</b> and choose Blind Spot&#39;s blank form (2 pages, A4).</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Press <b class="gd-ui">Download the filled sample</b>: a made-up booking on the form. <b class="gd-ui">Sample billed to an insurer</b> also fills the claim number, the adjuster and the insurance company. Check every box.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">On the form the old address (top left and twice in box 15) is replaced by the mailing address of Site settings, box 1 by CarmaCars&#39; HST number (Program settings, Company HST number; blank until it is entered), and box 21 has the representative&#39;s signature instead of Sam&#39;s.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t">Press <b class="gd-ui">Checked: use for bookings</b>. From then on each booking gets it when its rental agreement is made; a renter whose agreement is already open gets it the next time they open the signing page.</div></li><li><span class="gd-n" aria-hidden="true">5</span><div class="gd-t">Box 21: Ahmad is written in a script hand, as Blind Spot asked. To use a real signature instead, upload a PNG under Authorized company representative; Remove the image goes back to the written name. Full name is for the signature record page.</div></li><li><span class="gd-n" aria-hidden="true">6</span><div class="gd-t">A new version of Blind Spot&#39;s form? Upload it the same way: it waits for <b class="gd-ui">Checked: use for bookings</b>, and bookings keep the version in use until then.</div></li></ol></div><aside class="gd-box"><span class="gd-lbl">Good to know</span><div>Each box is filled only when the booking has the value: the renter and their licence, the additional drivers, the car (plate, make and model, the fleet number as vehicle number), the pickup as time and date out, the due-back date and time, the kilometres allowed, the daily rate and the rental charge, the underage fee, the Protection Plan as CDW, winter tires, the subtotal, HST, total and deposit, and for a booking billed to an insurer the insurer, claim number and adjuster. Other charges, such as delivery, are listed in box 14. Initials, fuel and the boxes filled at return stay blank.</div></aside><p class="gd-p">The renter&#39;s signature goes in boxes 16, 17 and 20 of the signed copy, with a signature record page. Both agreements are in the booking&#39;s Drivers and documents tab, in the renter&#39;s Documents, and the signed Blind Spot agreement is attached to the &quot;Your signed rental agreement&quot; email. Admin &gt; Today lists the HST number, the upload and the check until they are done.</p></section><section class="gd-task" id="settings-agreements-to-sign-investors-and-staff" data-gd-task><h2 class="gd-h2">Agreements to sign: investors and staff</h2><p class="gd-p">Investment agreements and staff agreements are made from the person&#39;s record and signed in their own portal, or on paper.</p><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">Investor: open <b class="gd-ui">People</b> &gt; <b class="gd-ui">Investors</b> and the investor. Under Investment agreement, press <b class="gd-ui">Send the agreement to sign</b>. Check the values it is filled with (amount, yearly percentage, dates, exemption) and press <b class="gd-ui">Send to sign</b>.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Once the investor signs, the agreement shows <b class="gd-ui">Awaiting countersignature</b> on the investor&#39;s page and on To do. It is not countersigned automatically: check it and press <b class="gd-ui">Countersign</b>. CarmaCars is bound once it has countersigned and the funds clear.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Staff: open <b class="gd-ui">People</b> &gt; <b class="gd-ui">Staff</b>. Under Staff agreements, press <b class="gd-ui">Send the agreement to sign</b> beside the person. Pay, schedule, hours and the other values start from the staff profile and the defaults of their function in Program settings; change any before sending. For Sales the Pay is Commission only: the agreement then has no rate, schedule or hours, and pays the commission of section 3.4.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t">A field staff member&#39;s agreement prints the home address they entered themselves. Staff enter their home address at their first sign-in, before they sign, or in their profile.</div></li><li><span class="gd-n" aria-hidden="true">5</span><div class="gd-t">They get a notice, check the key values and sign in their portal in a few taps (their name is the signature, or they draw it). The signed copy is filed with their documents.</div></li><li><span class="gd-n" aria-hidden="true">6</span><div class="gd-t">Your own PDF instead? <b class="gd-ui">Send a PDF to sign</b> still works.</div></li><li><span class="gd-n" aria-hidden="true">7</span><div class="gd-t">Signed on paper instead? Press <b class="gd-ui">Record paper signature</b> in the same place and upload the scan.</div></li><li><span class="gd-n" aria-hidden="true">8</span><div class="gd-t">Sent by mistake? Press <b class="gd-ui">Withdraw</b> and give the reason.</div></li></ol></div></section><section class="gd-task" id="settings-the-user-guides" data-gd-task><h2 class="gd-h2">The user guides</h2><p class="gd-p"><b class="gd-ui">Settings</b> &gt; <b class="gd-ui">Guides</b>. The guide of each portal, as people read it under Guide.</p><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">Each guide shows its version, when it was published and whether there are unpublished changes.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Open a guide and press a section. Change its text and press <b class="gd-ui">Show the preview</b> to see it as people will. Press <b class="gd-ui">Save the draft</b>; each save is kept in the section&#39;s history.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Move a section with the arrows, hide it, or press <b class="gd-ui">Add a chapter</b>. Upload a screenshot under Screenshots and paste the line it gives you.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t">Press <b class="gd-ui">Publish version</b> (the next number). The portals show the new version at once.</div></li><li><span class="gd-n" aria-hidden="true">5</span><div class="gd-t">The stored PDF is printed again by the guides-pdf workflow. Until then the guide says the web guide has newer edits.</div></li></ol></div></section><section class="gd-task" id="settings-the-guides-keep-up-by-themselves" data-gd-task><h2 class="gd-h2">The guides keep up by themselves</h2><p class="gd-p">After every update of the site that changes the portals, the guides are checked without anyone asking.</p><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">Every screenshot is taken again on the new version of the site. One whose screen changed replaces the old one in the guide.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">The text of each section whose screen changed, or that names a button the portals no longer show, is rewritten from the portal&#39;s own labels and menu, checked, and published. The PDFs of those guides are printed again.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Such a section says <b class="gd-ui">Changed automatically on</b> and the date, in the list of guides and in the guide&#39;s editor. Not right? Open the section and press <b class="gd-ui">Revert</b>: the text it replaced comes back, published at once.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t">This includes sections you edited: the newest automatic text is published, and every earlier version stays in the section&#39;s history. There is nothing to review.</div></li><li><span class="gd-n" aria-hidden="true">5</span><div class="gd-t">A rewrite that does not pass the checks is asked again, more strictly. If it still does not pass, the screenshots and button names are updated, the rest of the text stays as it was, and the next run tries again.</div></li></ol></div><aside class="gd-box"><span class="gd-lbl">Tip</span><div>The card &quot;The guides keep up by themselves&quot; at the top of Guides lists the last runs: when, how many screenshots were replaced, how many sections were rewritten, and how many PDFs were printed.</div></aside></section><section class="gd-task" id="settings-insurers-and-the-other-lists" data-gd-task><h2 class="gd-h2">Insurers and the other lists</h2><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">Open Insurers. Each insurer on file opens to edit its billing contact, email, phone, address and notes.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">To add one, fill in the Add form (Name, Billing contact, Billing email and the rest) and press <b class="gd-ui">Add</b>.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Deposit tiers, Kilometre choices, Vehicle classes, Airports, Promo codes and Quick replies work the same way.</div></li></ol></div></section><section class="gd-task" id="settings-promo-codes-end-dates-and-reminders" data-gd-task><h2 class="gd-h2">Promo codes: end dates and reminders</h2><p class="gd-p"><b class="gd-ui">Settings</b> &gt; <b class="gd-ui">All settings</b>, <b class="gd-ui">Promo codes</b>.</p><ul class="gd-ul"><li>Every code made for a person has an end date: a game prize 7 days, a come-back offer 30, a Live visitors code 3 and a code made for one renter 30 unless you set another. The first card of Promo codes holds the 30 days and the two reminders.</li><li>A code for everyone may have no end date: empty Valid until. The Add form starts with an end date 30 days ahead.</li><li>A code that ended is refused wherever it is typed (the request form, an offer, Add a rental, a booking edit) with &quot;This code has expired&quot;.</li><li>A person who has not used a code is reminded 3 days before its last day and the day before, by email and by text as they chose, never once they used it, unsubscribed or the code ended, and never twice. A game code reminder always goes; a reminder of any other code needs their consent to offers.</li><li>The list shows each code&#39;s end date and the reminders sent. The card Codes sent to people lists game prizes, come-back offers and Live visitors codes the same way.</li></ul></section><section class="gd-task" id="settings-card-coverage-which-credit-cards-include-rental-car-coverage" data-gd-task><h2 class="gd-h2">Card coverage: which credit cards include rental car coverage</h2><p class="gd-p"><b class="gd-ui">Settings</b> &gt; <b class="gd-ui">Card coverage</b> is the list renters see at <span class="gd-url">carmacars.ca/credit-card-rental-coverage</span> and staff see under Card coverage in their portal. It starts filled in with 48 Canadian and US cards, each checked on October 23, 2026.</p><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">The table shows each card: who pays first (Primary, Secondary, or not stated), the car value limit (MSRP), the longest rental, whether the numbers were read in the issuer&#39;s own document, and when it was last checked.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Open a card under Change a card, open its official guide, correct what changed and press <b class="gd-ui">Save</b>. Changing the facts without a date marks the card checked today; type a Last checked date to record another day.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">A card whose numbers come from a published summary has Read in the issuer&#39;s own document unticked and the summary&#39;s link under Where the numbers came from. The page shows it as Unverified. Tick it once you have read the issuer&#39;s guide.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t">Add a card with the Add form; untick Shown to hide one. Changes reach the public page at once.</div></li></ol></div><aside class="gd-box"><span class="gd-lbl">Tip</span><div>A card not checked for 6 months shows on Today until it is checked again. The page tells renters to confirm with their card issuer and says CarmaCars decides no claims: keep the list to facts from the issuer&#39;s guide.</div></aside></section><section class="gd-task" id="settings-reviews-review-requests-and-google" data-gd-task><h2 class="gd-h2">Reviews: review requests and Google</h2><p class="gd-p"><b class="gd-ui">Settings</b> &gt; <b class="gd-ui">Reviews</b>: when review requests go, the Google review link and the Google Business Profile connection. Review requests are on from the start.</p><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">When review requests go: the check-in (on or off, the shortest rental, hours after the pickup), the request (minutes after the check-in), the reminder (hours) and the final follow-up (days), the sending hours (9 am to 9 pm), and the hold while charges are open.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">The Google review link: the Google place id (Site settings) makes it, or paste the Business Profile&#39;s own review link.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Google Business Profile: press <b class="gd-ui">Connect Google</b> and sign in with rent@carmacars.ca, then allow access. Reviews are read every 6 hours and matched to renters by name within 30 days after their return.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t">A clear match stops that renter&#39;s reminders at once. A possible match waits in Reviews: press <b class="gd-ui">Confirm</b>, <b class="gd-ui">Not this renter</b> or <b class="gd-ui">Match to a booking</b>.</div></li></ol></div><aside class="gd-box"><span class="gd-lbl">Tip</span><div>Until Google approves the Business Profile API for the project, the status says so and nothing else changes: renters still get the review link, and &quot;I already left a review&quot;, Mark reviewed and on-site reviews still stop the messages.</div></aside></section>');
-- GUIDES 0161 END
