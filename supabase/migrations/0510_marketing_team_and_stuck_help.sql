-- 0510: Sales's Marketing tab (Facebook Marketplace from each salesperson's own profile, with no ad posted twice) and the
-- "Stuck?" help of every portal. SCHEMA_MARKER 0511 (with the guides of 0511). docs/changes/2026-11-07-marketing-and-stuck-help.md.
-- The owner (November 2, 2026): "Sales should have access to the FB Marketplace listing tool and auto-responder setup, their own
-- marketing tab with everything you've given me, but make sure none of us are posting the exact same ad/copy twice."
--   1. Settings: marketplace_max_live_per_car (5: live Marketplace listings of one car across the team, the owner's own listing
--      included), marketplace_listing_days (30: how long a Facebook listing stays up before it lapses unless renewed),
--      stuck_help_on, stuck_idle_minutes (3), stuck_errors (3).
--   2. marketplace_claims: one salesperson's listing of one car in one copy variant. Variant 1 is the owner's kit (Admin >
--      Marketing > Marketplace, ad_postings); the team claims variants 2 to the setting. While a claim is not ended, its
--      variant, title, description and cover photo are unique for the car (unique indexes), a person holds one listing of a
--      car, and the car has at most the setting's live listings. A claim not posted within a day ends, and so does a listing
--      past Facebook's lifetime since it was posted or renewed, or one marked taken down.
--   3. marketplace_log.claim_id and variant: the team's posts, renewals, updates and take-downs are logged per person, car and
--      variant. The owner's daily allowance (done_today) counts only his own listings.
--   4. The Sales door: va_read mp_team; va_do mp_claim, mp_team_log, mp_team_inbox (the inbox numbers become leads assigned to
--      the salesperson who collected them, with the same call-back task as 0410). Admins may use them too.
--   5. help_stuck_events: when the "Stuck?" prompt showed and what the person chose, by page; public.help_stuck_settings and
--      public.help_stuck_log (service role: the /api/help route of the signed-in person); admin_read help_stuck (the pages
--      that trigger it most, in Settings > Program settings).
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
alter table program_settings
  add column if not exists marketplace_max_live_per_car integer not null default 5 check (marketplace_max_live_per_car between 2 and 10),
  add column if not exists marketplace_listing_days integer not null default 30 check (marketplace_listing_days between 7 and 90),
  add column if not exists stuck_help_on boolean not null default true,
  add column if not exists stuck_idle_minutes integer not null default 3 check (stuck_idle_minutes between 1 and 30),
  add column if not exists stuck_errors integer not null default 3 check (stuck_errors between 2 and 10);
comment on column program_settings.marketplace_max_live_per_car is 'Marketplace (0510): live Marketplace listings of one car across the team at most, the owner''s own included; each is a different copy variant.';
comment on column program_settings.marketplace_listing_days is 'Marketplace (0510): a team listing ends this many days after it was posted or last renewed (Facebook''s listing lifetime).';
comment on column program_settings.stuck_help_on is 'Stuck? help (0510): offer the guide and the Academy lesson to someone who seems stuck on a page.';
comment on column program_settings.stuck_idle_minutes is 'Stuck? help (0510): minutes on a page with activity but no successful action before the prompt shows.';
comment on column program_settings.stuck_errors is 'Stuck? help (0510): validation errors on a page, without a successful action, before the prompt shows.';

-- ================================================================ 2. the team's listings
create table if not exists marketplace_claims (
  id           uuid primary key default gen_random_uuid(),
  vehicle_id   uuid not null references vehicles (id) on delete cascade,
  variant      smallint not null check (variant between 2 and 10),
  poster_id    uuid not null references users (id) on delete cascade,
  status       text not null default 'claimed' check (status in ('claimed', 'live', 'ended')),
  title        text not null check (length(btrim(title)) between 5 and 200),
  body_hash    text not null check (body_hash ~ '^[0-9a-f]{32}$'),
  cover        text not null check (length(cover) between 1 and 500),
  price_line   text check (price_line is null or length(price_line) <= 300),
  url          text check (url is null or url ~* '^https://([a-z]+\.)?facebook\.com/'),
  claimed_at   timestamptz not null default now(),
  posted_on    date,
  renewed_on   date,
  updated_on   date,
  expires_at   timestamptz not null,
  ended_at     timestamptz,
  ended_reason text check (ended_reason is null or length(ended_reason) <= 300),
  check (status <> 'ended' or ended_at is not null),
  check (status <> 'live' or posted_on is not null)
);
create unique index if not exists marketplace_claims_variant_uq on marketplace_claims (vehicle_id, variant) where status <> 'ended';
create unique index if not exists marketplace_claims_person_uq on marketplace_claims (vehicle_id, poster_id) where status <> 'ended';
create unique index if not exists marketplace_claims_title_uq on marketplace_claims (vehicle_id, lower(title)) where status <> 'ended';
create unique index if not exists marketplace_claims_body_uq on marketplace_claims (vehicle_id, body_hash) where status <> 'ended';
create unique index if not exists marketplace_claims_cover_uq on marketplace_claims (vehicle_id, cover) where status <> 'ended';
create index if not exists marketplace_claims_poster_idx on marketplace_claims (poster_id, claimed_at desc);
comment on table marketplace_claims is 'Marketplace (0510): one salesperson''s Facebook Marketplace listing of one car in one copy variant (2 and up; 1 is the owner''s). Not ended: the variant, title, description and cover are the car''s alone.';

alter table marketplace_log
  add column if not exists claim_id uuid references marketplace_claims (id) on delete set null,
  add column if not exists variant smallint;
create index if not exists marketplace_log_by_idx on marketplace_log (logged_by, on_date desc);

alter table marketplace_claims enable row level security;
revoke all on marketplace_claims from anon, authenticated;
grant all on marketplace_claims to service_role;
drop policy if exists admin_all on marketplace_claims;
create policy admin_all on marketplace_claims for all to authenticated using (app.is_admin()) with check (app.is_admin());

-- claims past their time end (a claim not posted within a day; a listing past Facebook's lifetime)
create or replace function app.mp_expire() returns integer
language plpgsql volatile security definer set search_path = public, app as $$
declare n integer;
begin
  update marketplace_claims set status = 'ended', ended_at = now(),
         ended_reason = case when status = 'claimed' then 'Not posted within a day of claiming it' else 'Past Facebook''s listing lifetime: renew it or post it again' end
   where status <> 'ended' and expires_at <= now();
  get diagnostics n = row_count;
  return n;
end $$;

create or replace function app.mp_is_team(p_by uuid) returns boolean
language sql stable security definer set search_path = public, app as $$
  select p_by is not null and (app.user_is_admin(p_by) or app.user_va_has(p_by, 'sales'))
$$;

create or replace function app.mp_claim_row(c marketplace_claims, p_names boolean default true) returns jsonb
language sql stable security definer set search_path = public, app as $$
  select jsonb_build_object('id', c.id, 'vehicle_id', c.vehicle_id, 'car', app.vehicle_name(c.vehicle_id), 'variant', c.variant, 'status', c.status,
    'poster_id', c.poster_id, 'poster', case when p_names then (select coalesce(nullif(btrim(u.greeting_name), ''), u.full_name) from users u where u.id = c.poster_id) end,
    'title', c.title, 'cover', c.cover, 'price_line', c.price_line, 'url', c.url, 'claimed_at', c.claimed_at, 'posted_on', c.posted_on, 'renewed_on', c.renewed_on,
    'updated_on', c.updated_on, 'expires_at', c.expires_at, 'ended_at', c.ended_at, 'ended_reason', c.ended_reason)
$$;

-- 0410's read, with the team's listings and the new settings; the owner's day counts his own posts and renewals only
create or replace function app.marketplace_read(p_by uuid, p jsonb) returns jsonb
language plpgsql stable security definer set search_path = public, app as $$
declare
  s program_settings := app.settings();
begin
  perform app.assert_admin(p_by);
  return app.ads_facts() || jsonb_build_object(
    'settings', jsonb_build_object('posts_per_day', s.marketplace_posts_per_day, 'renew_days', s.marketplace_renew_days, 'location', s.marketplace_location,
      'max_live', s.marketplace_max_live_per_car, 'listing_days', s.marketplace_listing_days),
    'phone', (select coalesce(ss.phone_display, ss.phone) from site_settings ss limit 1),
    'extra', coalesce((select jsonb_object_agg(v.id::text, jsonb_build_object(
        'odometer_km', greatest(coalesce(v.odometer_km, 0), coalesce((select max(r.km) from vehicle_odometer_readings r where r.vehicle_id = v.id and r.voided_at is null), 0)),
        'home_area', nullif(btrim(coalesce(l.home_area, '')), ''), 'supply', v.supply_type, 'drivetrain', l.drivetrain, 'doors', l.doors))
      from vehicles v join vehicle_listings l on l.vehicle_id = v.id where v.retired_at is null and l.slug is not null), '{}'::jsonb),
    'postings', coalesce((select jsonb_agg(app.ad_posting_row(a) || jsonb_build_object('renewed_on', a.renewed_on) order by a.posted_on desc)
      from ad_postings a where a.channel = 'fb_marketplace' and (a.status = 'live' or a.removed_on > app.today() - 30)), '[]'::jsonb),
    'team', coalesce((select jsonb_agg(app.mp_claim_row(c) order by c.claimed_at desc)
      from marketplace_claims c where (c.status <> 'ended' and c.expires_at > now()) or c.ended_at > now() - interval '14 days'), '[]'::jsonb),
    'log', coalesce((select jsonb_agg(jsonb_build_object('id', m.id, 'at', m.at, 'on_date', m.on_date, 'kind', m.kind, 'vehicle_id', m.vehicle_id,
        'car', case when m.vehicle_id is not null then app.vehicle_name(m.vehicle_id) end, 'conversations', m.conversations, 'replies', m.replies,
        'numbers', m.numbers, 'note', m.note, 'variant', m.variant, 'by', (select full_name from users where id = m.logged_by)) order by m.at desc)
      from (select * from marketplace_log order by at desc limit 40) m), '[]'::jsonb),
    'done_today', (select count(*) from marketplace_log where on_date = app.today() and kind in ('posted', 'renewed') and claim_id is null),
    'week', (select jsonb_build_object('posted', count(*) filter (where kind = 'posted'), 'renewed', count(*) filter (where kind = 'renewed'),
        'conversations', coalesce(sum(conversations), 0), 'replies', coalesce(sum(replies), 0), 'numbers', coalesce(sum(numbers), 0))
      from marketplace_log where on_date > app.today() - 7),
    'leads_30', (select count(*) from leads where source = 'fb_marketplace' and created_at > now() - interval '30 days'),
    'requests_30', (select count(*) from bookings b left join booking_attribution a on a.booking_id = b.id
      where b.booking_type <> 'owner' and coalesce(b.requested_at, b.created_at) > now() - interval '30 days' and app.booking_channel(b, a, 'last') = 'fb_marketplace'));
end $$;

-- The Marketing tab of a salesperson (or an Admin): the kits, the team's listings (names only of their own), their own log,
-- day and week.
create or replace function app.mp_team_read(p_by uuid, p jsonb default '{}'::jsonb) returns jsonb
language plpgsql volatile security definer set search_path = public, app as $$
declare
  v jsonb;
  v_admin boolean := app.user_is_admin(p_by);
begin
  if not app.mp_is_team(p_by) then raise exception 'The Marketing tab is for Sales and Admins' using errcode = '42501'; end if;
  perform app.mp_expire();
  perform app.staff_view(p_by);
  v := app.marketplace_read(p_by, coalesce(p, '{}'::jsonb));
  perform app.staff_view(null);
  return v || jsonb_build_object(
    'me', p_by,
    'team', coalesce((select jsonb_agg(case when v_admin or (t ->> 'poster_id')::uuid = p_by then t else t || jsonb_build_object('poster', null, 'url', null) end)
      from jsonb_array_elements(v -> 'team') t), '[]'::jsonb),
    'log', coalesce((select jsonb_agg(jsonb_build_object('id', m.id, 'at', m.at, 'on_date', m.on_date, 'kind', m.kind, 'vehicle_id', m.vehicle_id,
        'car', case when m.vehicle_id is not null then app.vehicle_name(m.vehicle_id) end, 'conversations', m.conversations, 'replies', m.replies,
        'numbers', m.numbers, 'note', m.note, 'variant', m.variant, 'by', null) order by m.at desc)
      from (select * from marketplace_log where logged_by = p_by order by at desc limit 30) m), '[]'::jsonb),
    'done_today', (select count(*) from marketplace_log where logged_by = p_by and on_date = app.today() and kind in ('posted', 'renewed') and claim_id is not null),
    'week', (select jsonb_build_object('posted', count(*) filter (where kind = 'posted'), 'renewed', count(*) filter (where kind = 'renewed'),
        'conversations', coalesce(sum(conversations), 0), 'replies', coalesce(sum(replies), 0), 'numbers', coalesce(sum(numbers), 0))
      from marketplace_log where logged_by = p_by and on_date > app.today() - 7),
    'leads_30', (select count(*) from leads where source = 'fb_marketplace' and assigned_to = p_by and created_at > now() - interval '30 days'));
end $$;

-- Claim a car in one copy variant before posting it. p: {vehicle, variant, title, body, cover, price_line}
create or replace function app.mp_claim(p_by uuid, p jsonb) returns jsonb
language plpgsql volatile security definer set search_path = public, app as $$
declare
  s program_settings := app.settings();
  v_vehicle uuid := nullif(p ->> 'vehicle', '')::uuid;
  v_variant integer := nullif(p ->> 'variant', '')::integer;
  v_title text := btrim(coalesce(p ->> 'title', ''));
  v_body text := btrim(coalesce(p ->> 'body', ''));
  v_cover text := btrim(coalesce(p ->> 'cover', ''));
  v_hash text;
  v_owner ad_postings;
  c marketplace_claims;
  n integer;
begin
  if not app.mp_is_team(p_by) then raise exception 'Only Sales and Admins post on Marketplace from the Marketing tab' using errcode = '42501'; end if;
  perform app.mp_expire();
  if v_vehicle is null or not exists (select 1 from vehicles v join vehicle_listings l on l.vehicle_id = v.id where v.id = v_vehicle and v.retired_at is null and l.slug is not null) then
    raise exception 'Choose a car that is on the site' using errcode = '22023';
  end if;
  if v_variant is null or v_variant < 2 or v_variant > s.marketplace_max_live_per_car then
    raise exception 'Choose a copy variant from 2 to %', s.marketplace_max_live_per_car using errcode = '22023';
  end if;
  if length(v_title) < 5 or length(v_body) < 40 or v_cover = '' then raise exception 'The kit''s title, description and cover photo are needed' using errcode = '22023'; end if;
  -- the owner's wording rule (November 1, 2026)
  if v_title || ' ' || v_body ~* '\m(rent|rental|rentals|renting|for rent)\M' then raise exception 'Marketplace copy never says rent or rental: use the kit''s words' using errcode = '22023'; end if;
  if v_body !~* 'not for sale' then raise exception 'The description must say "Daily and weekly bookings only, not for sale"' using errcode = '22023'; end if;
  v_hash := md5(v_body);
  -- one claim of a car at a time
  perform 1 from vehicles where id = v_vehicle for update;
  select * into c from marketplace_claims where vehicle_id = v_vehicle and poster_id = p_by and status <> 'ended';
  if c.id is not null then raise exception 'You already have this car on Marketplace (variant %): renew it instead of posting it again', c.variant using errcode = '23505'; end if;
  if exists (select 1 from marketplace_claims where vehicle_id = v_vehicle and variant = v_variant and status <> 'ended') then
    raise exception 'Variant % of this car is already taken by someone else: choose another', v_variant using errcode = '23505';
  end if;
  select * into v_owner from ad_postings where vehicle_id = v_vehicle and channel = 'fb_marketplace' and status = 'live';
  n := (select count(*) from marketplace_claims where vehicle_id = v_vehicle and status <> 'ended') + case when v_owner.id is not null then 1 else 0 end;
  if n >= s.marketplace_max_live_per_car then
    raise exception 'This car already has % live listings, the most allowed: choose another car', n using errcode = '23505';
  end if;
  if exists (select 1 from marketplace_claims where vehicle_id = v_vehicle and status <> 'ended' and (lower(title) = lower(v_title) or body_hash = v_hash or cover = v_cover))
     or (v_owner.id is not null and (lower(coalesce(v_owner.title, '')) = lower(v_title) or md5(btrim(coalesce(v_owner.body, ''))) = v_hash)) then
    raise exception 'This copy or cover photo is already live for this car: choose another variant' using errcode = '23505';
  end if;
  insert into marketplace_claims (vehicle_id, variant, poster_id, title, body_hash, cover, price_line, expires_at)
  values (v_vehicle, v_variant, p_by, v_title, v_hash, v_cover, nullif(btrim(coalesce(p ->> 'price_line', '')), ''), now() + interval '1 day')
  returning * into c;
  insert into audit_log (actor_user_id, action, entity_table, entity_id, after) values (p_by, 'mp_claim', 'marketplace_claims', c.id::text, p - 'body');
  return app.mp_claim_row(c);
end $$;

-- Record what was done with one's listing. p: {claim, kind: posted | renewed | updated | removed, url, on_date, note, price_line}
create or replace function app.mp_team_log(p_by uuid, p jsonb) returns jsonb
language plpgsql volatile security definer set search_path = public, app as $$
declare
  s program_settings := app.settings();
  v_kind text := p ->> 'kind';
  v_on date := coalesce(nullif(p ->> 'on_date', '')::date, app.today());
  v_url text := nullif(btrim(coalesce(p ->> 'url', '')), '');
  v_note text := nullif(btrim(coalesce(p ->> 'note', '')), '');
  c marketplace_claims;
begin
  if not app.mp_is_team(p_by) then raise exception 'Only Sales and Admins log Marketplace listings here' using errcode = '42501'; end if;
  if v_kind is null or v_kind not in ('posted', 'renewed', 'updated', 'removed') then raise exception 'Say what was done: posted, renewed, updated or taken down' using errcode = '22023'; end if;
  if v_on > app.today() then raise exception 'The date cannot be in the future' using errcode = '22023'; end if;
  perform app.mp_expire();
  select * into c from marketplace_claims where id = nullif(p ->> 'claim', '')::uuid for update;
  if c.id is null then raise exception 'No such listing' using errcode = '22023'; end if;
  if c.poster_id <> p_by and not app.user_is_admin(p_by) then raise exception 'This listing is someone else''s' using errcode = '42501'; end if;
  if c.status = 'ended' then raise exception 'This listing has ended (%): claim the car again', coalesce(c.ended_reason, 'ended') using errcode = '22023'; end if;
  if v_kind in ('renewed', 'updated') and c.status <> 'live' then raise exception 'Record it as posted first' using errcode = '22023'; end if;
  if v_kind = 'posted' then
    if v_url is null or v_url !~* '^https://([a-z]+\.)?facebook\.com/' then raise exception 'Paste the listing''s address (facebook.com/marketplace/item/...)' using errcode = '22023'; end if;
    update marketplace_claims set status = 'live', url = v_url, posted_on = v_on, renewed_on = v_on,
           expires_at = ((v_on + s.marketplace_listing_days)::timestamp + interval '23 hours 59 minutes') at time zone 'America/Toronto'
     where id = c.id returning * into c;
  elsif v_kind = 'renewed' then
    update marketplace_claims set renewed_on = app.today(), url = coalesce(v_url, url),
           expires_at = ((app.today() + s.marketplace_listing_days)::timestamp + interval '23 hours 59 minutes') at time zone 'America/Toronto'
     where id = c.id returning * into c;
  elsif v_kind = 'updated' then
    update marketplace_claims set updated_on = app.today(), price_line = coalesce(nullif(btrim(coalesce(p ->> 'price_line', '')), ''), price_line) where id = c.id returning * into c;
  else
    update marketplace_claims set status = 'ended', ended_at = now(), ended_reason = coalesce(v_note, case when c.status = 'claimed' then 'Let go before posting' else 'Taken down' end)
     where id = c.id returning * into c;
  end if;
  insert into marketplace_log (on_date, kind, vehicle_id, claim_id, variant, note, logged_by) values (v_on, v_kind, c.vehicle_id, c.id, c.variant, v_note, p_by);
  insert into audit_log (actor_user_id, action, entity_table, entity_id, after) values (p_by, 'mp_team_log', 'marketplace_claims', c.id::text, p);
  return app.mp_claim_row(c);
end $$;

-- A salesperson's inbox session: 0410's, with each number credited to them (the lead is assigned to them)
create or replace function app.mp_team_inbox(p_by uuid, p jsonb) returns jsonb
language plpgsql volatile security definer set search_path = public, app as $$
declare r jsonb;
begin
  if not app.mp_is_team(p_by) then raise exception 'Only Sales and Admins log Marketplace inbox sessions here' using errcode = '42501'; end if;
  perform app.staff_view(p_by);
  r := app.marketplace_inbox_save(p_by, coalesce(p, '{}'::jsonb));
  perform app.staff_view(null);
  update leads set assigned_to = p_by, payload = coalesce(payload, '{}'::jsonb) || jsonb_build_object('credited_to', p_by)
   where id in (select (x #>> '{}')::uuid from jsonb_array_elements(coalesce(r -> 'leads', '[]'::jsonb)) x) and assigned_to is null;
  return r;
end $$;

-- ================================================================ 5. Stuck? help
create table if not exists help_stuck_events (
  id       uuid primary key default gen_random_uuid(),
  at       timestamptz not null default now(),
  user_id  uuid references users (id) on delete set null,
  portal   text not null check (portal in ('admin', 'va', 'field', 'owner', 'renter', 'investor')),
  route    text not null check (route ~ '^/[A-Za-z0-9/_\[\]\.-]*$' and length(route) <= 200),
  tab      text check (tab is null or length(tab) <= 60),
  trigger  text check (trigger is null or trigger in ('idle', 'errors', 'loop')),
  action   text not null check (action in ('shown', 'guide', 'lesson', 'snooze', 'back'))
);
create index if not exists help_stuck_events_at_idx on help_stuck_events (at desc);
create index if not exists help_stuck_events_route_idx on help_stuck_events (route, at desc);
comment on table help_stuck_events is 'Stuck? help (0510): the prompt shown on a page (route pattern, tab) and what the person chose.';
alter table help_stuck_events enable row level security;
revoke all on help_stuck_events from anon, authenticated;
grant all on help_stuck_events to service_role;
drop policy if exists admin_read on help_stuck_events;
create policy admin_read on help_stuck_events for select to authenticated using (app.is_admin());

create or replace function public.help_stuck_settings() returns jsonb
language sql stable security definer set search_path = public, app as $$
  select jsonb_build_object('on', s.stuck_help_on, 'idle_minutes', s.stuck_idle_minutes, 'errors', s.stuck_errors) from app.settings() s
$$;
revoke all on function public.help_stuck_settings() from public, anon, authenticated;
grant execute on function public.help_stuck_settings() to service_role;

-- one event from the signed-in person's browser; at most 300 a person a day (a stuck loop never floods the table)
create or replace function public.help_stuck_log(p_by uuid, p jsonb) returns boolean
language plpgsql volatile security definer set search_path = public, app as $$
begin
  if p_by is null or not exists (select 1 from users where id = p_by) then return false; end if;
  if (select count(*) from help_stuck_events where user_id = p_by and at > now() - interval '1 day') >= 300 then return false; end if;
  insert into help_stuck_events (user_id, portal, route, tab, trigger, action)
  values (p_by, p ->> 'portal', p ->> 'route', nullif(left(btrim(coalesce(p ->> 'tab', '')), 60), ''), nullif(p ->> 'trigger', ''), p ->> 'action');
  return true;
exception when check_violation or not_null_violation then
  raise exception 'Not a help event' using errcode = '22023';
end $$;
revoke all on function public.help_stuck_log(uuid, jsonb) from public, anon, authenticated;
grant execute on function public.help_stuck_log(uuid, jsonb) to service_role;

-- Admin: the pages that trigger the prompt most in the last 30 days, and what people chose
create or replace function app.help_stuck_report(p_by uuid, p jsonb default '{}'::jsonb) returns jsonb
language plpgsql stable security definer set search_path = public, app as $$
begin
  perform app.assert_admin(p_by);
  return jsonb_build_object('settings', public.help_stuck_settings(),
    'shown_30', (select count(*) from help_stuck_events where action = 'shown' and at > now() - interval '30 days'),
    'pages', coalesce((select jsonb_agg(x order by (x ->> 'shown')::int desc, x ->> 'route') from (
        select jsonb_build_object('portal', portal, 'route', route, 'tab', tab,
          'shown', count(*) filter (where action = 'shown'), 'guide', count(*) filter (where action = 'guide'), 'lesson', count(*) filter (where action = 'lesson'),
          'snooze', count(*) filter (where action = 'snooze'), 'people', count(distinct user_id), 'last', max(at)) x
          from help_stuck_events where at > now() - interval '30 days' group by portal, route, tab
          order by count(*) filter (where action = 'shown') desc limit 10) q), '[]'::jsonb));
end $$;

-- ================================================================ the door
alter function app.door(uuid, text, text, text, jsonb) rename to door_pre0510;
create function app.door(p_user uuid, p_aal text, p_call text, p_name text, p jsonb default '{}'::jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  p_ jsonb := coalesce(p, '{}'::jsonb);
begin
  if p_call in ('va_read', 'admin_read') and p_name = 'mp_team' then
    if p_ ? '_va' then perform set_config('app.va_active', coalesce(p_ ->> '_va', ''), true); end if;
    perform app.door_begin(p_user, p_aal);
    return app.mp_team_read(p_user, p_ - '_va');
  end if;
  if p_call in ('va_do', 'admin_do') and p_name in ('mp_claim', 'mp_team_log', 'mp_team_inbox') then
    perform app.door_begin(p_user, p_aal);
    return case p_name when 'mp_claim' then app.mp_claim(p_user, p_ - '_va') when 'mp_team_log' then app.mp_team_log(p_user, p_ - '_va')
      else app.mp_team_inbox(p_user, p_ - '_va') end;
  end if;
  if p_call = 'admin_read' and p_name = 'help_stuck' then
    perform app.door_begin(p_user, p_aal);
    return app.help_stuck_report(p_user, p_);
  end if;
  return app.door_pre0510(p_user, p_aal, p_call, p_name, p);
end $$;
select pg_temp.copy_grants('app.door(uuid, text, text, text, jsonb)'::regprocedure, 'app.door_pre0510(uuid, text, text, text, jsonb)'::regprocedure);

do $$
declare f record;
begin
  for f in select p.oid::regprocedure as sig from pg_proc p join pg_namespace n on n.oid = p.pronamespace
            where n.nspname = 'app' and p.proname in ('mp_expire', 'mp_is_team', 'mp_claim_row', 'marketplace_read', 'mp_team_read', 'mp_claim', 'mp_team_log', 'mp_team_inbox',
              'help_stuck_report', 'door_pre0510') loop
    execute format('revoke all on function %s from public, anon, authenticated', f.sig);
    execute format('grant execute on function %s to service_role', f.sig);
  end loop;
end $$;
