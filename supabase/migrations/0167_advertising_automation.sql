-- 0167_advertising_automation.sql
-- The owner's advertising and marketing automation (the spec "CarmaCars Advertising Automation", tasks 4 to 9, and owner
-- recruitment; docs/changes/2026-10-25-advertising-automation.md). No paid service and no AI: every text is a template.
--
-- 1. Posted ads: an ad a person posted by hand (Facebook Marketplace from the owner's own profile, Kijiji, Craigslist, an
--    Instagram or Facebook Page post, a Google Business Profile post) is recorded with its address and date and what it said
--    (the rates and whether the car took requests). Admin > Marketing > Listings writes the text per car and channel (in the
--    web app, from the facts read here) and records the posting.
-- 2. Rate change tasks: when a car's rates change by at least ads_rate_change_bps (3% by default), or its deposit, kilometres,
--    overage or delivery fee change, or it stops (or starts again) taking requests, every live ad of that car opens a task
--    for the sales assistants (ad_update) with the new price line; the new full text is one click away. Marking the ad
--    updated (or closing the task) records the new figures. Checked at commit by deferred triggers on the rate card, the
--    listing and the car, and again by the ads job every 6 hours (a rate card dated in the future).
-- 3. Bookings per channel: the first and last visit of the renter's browser before the request (0060 visitor sessions,
--    with 0086's UTM and referring site) are kept with the booking when the request is sent (they outlive the 90 days of
--    visits); staff may set the source by hand (bookings.marketing_source: a Kijiji reply, a walk-in). The report counts
--    requests, bookings, revenue (the rental charge after discounts) and conversion by channel and month, first or last touch.
-- 4. Facebook Page and Instagram drafts: a weekly calendar of drafts written from the fleet (a new or featured car, the owner
--    program, the cars free this weekend, the requirements, a price highlight or a seasonal trip), approved or edited by staff,
--    then copied and posted by hand. Publishing through Meta's API is built but off (meta_publishing) until an Admin enters
--    the Page id, the Instagram account id and a Page access token (kept in Supabase Vault).
-- 5. Owner recruitment under the anti-spam law (CASL): leads typed by staff from a classified ad (kind owner_recruit on 0022's
--    leads), a consent log that is never edited (express, implied by an inquiry for 6 months, implied by a business
--    relationship for 2 years, implied by a business address published without a "no solicitation" note, one message after
--    a referral; withdrawals), a call log, and email or text templates that send only when the log allows. Every email names
--    CarmaCars, its mailing address and carries the unsubscribe link (0018's one-click unsubscribe); every text names
--    CarmaCars and ends with "Reply STOP to opt out." An unsubscribe or a STOP is written into the log at once.
-- 6. Admin: the doors (admin_read 'ads_listings', 'ads_postings', 'ads_report', 'booking_marketing', 'social_drafts',
--    'meta_publishing', 'recruit_leads', 'recruit_lead'; admin_do 'ad_posting_save', 'ad_posting_remove',
--    'booking_marketing_source', 'social_drafts_put', 'social_draft_save', 'social_draft_decide', 'social_draft_posted',
--    'meta_publishing_save', 'recruit_lead_save', 'recruit_consent_add', 'recruit_call_log', 'recruit_send',
--    'recruit_do_not_contact'), the ads job (server_jobs_due "ads") and the guides.
-- No applied migration is edited. app.door (0165) and app.server_jobs_due (0155) are wrapped here.

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
  add column if not exists ads_rate_change_bps integer not null default 300 check (ads_rate_change_bps between 0 and 5000),
  add column if not exists ads_social_drafts_enabled boolean not null default true,
  add column if not exists recruit_outreach_enabled boolean not null default true;
comment on column program_settings.ads_rate_change_bps is 'Advertising (0167): a rate change of at least this share (300 = 3%) opens a task to update each posted ad of the car. Any change of the deposit, kilometres, overage or delivery fee does too.';
comment on column program_settings.ads_social_drafts_enabled is 'Advertising (0167): write the week''s Facebook Page and Instagram drafts from the fleet (they wait for approval; nothing is posted by itself).';
comment on column program_settings.recruit_outreach_enabled is 'Owner recruitment (0167): emails and texts to recruitment leads may be sent (each still needs consent in the log).';

-- ================================================================ 2. channels and words
create or replace function app.ad_channels() returns text[]
language sql immutable as $$ select array['fb_marketplace', 'kijiji', 'craigslist', 'instagram', 'facebook_page', 'google_business'] $$;

-- Every channel the report knows: the ad channels, sources of a visit, and what staff may set by hand.
create or replace function app.ad_channel_label(p text) returns text
language sql immutable as $$
  select case p
    when 'fb_marketplace' then 'Facebook Marketplace' when 'kijiji' then 'Kijiji' when 'craigslist' then 'Craigslist'
    when 'instagram' then 'Instagram' when 'facebook_page' then 'Facebook Page' when 'google_business' then 'Google Business Profile'
    when 'facebook' then 'Facebook (other)' when 'google' then 'Google search' when 'bing' then 'Bing'
    when 'other_site' then 'Another website' when 'direct' then 'Direct (typed or bookmarked)' when 'referral' then 'Referral code'
    when 'phone' then 'Phone call' when 'email' then 'Email' when 'whatsapp' then 'WhatsApp' when 'walk_in' then 'Walk-in'
    when 'repeat' then 'Returning renter' when 'word_of_mouth' then 'Word of mouth' when 'turo' then 'Turo'
    when 'other' then 'Other' else 'Not known' end
$$;

create or replace function app.marketing_sources() returns text[]
language sql immutable as $$ select app.ad_channels() || array['google', 'referral', 'walk_in', 'repeat', 'word_of_mouth', 'other'] $$;

-- The channel of a visit, from its campaign source and the referring site's host.
create or replace function app.ad_channel_of(p_source text, p_referrer text) returns text
language plpgsql immutable as $$
declare
  s text := lower(btrim(coalesce(p_source, '')));
  r text := lower(btrim(coalesce(p_referrer, '')));
begin
  if s <> '' then
    if s = any (app.ad_channels()) then return s; end if;
    if s in ('marketplace', 'fbmarketplace', 'facebook_marketplace', 'fb_market') then return 'fb_marketplace'; end if;
    if s like '%kijiji%' then return 'kijiji'; end if;
    if s like '%craigslist%' then return 'craigslist'; end if;
    if s in ('ig', 'insta') or s like 'instagram%' then return 'instagram'; end if;
    if s in ('fb', 'meta') or s like 'facebook%' then return 'facebook'; end if;
    if s in ('gbp', 'google_business_profile', 'gmb') then return 'google_business'; end if;
    if s like 'google%' then return 'google'; end if;
    if s like 'bing%' then return 'bing'; end if;
    return 'other';
  end if;
  if r = '' then return 'direct'; end if;
  if r like '%kijiji.%' then return 'kijiji'; end if;
  if r like '%craigslist.%' then return 'craigslist'; end if;
  if r like '%instagram.%' then return 'instagram'; end if;
  if r like '%facebook.%' or r = 'fb.com' or r like '%.fb.com' or r = 'fb.me' then return 'facebook'; end if;
  if r ~ '(^|\.)google\.' then return 'google'; end if;
  if r ~ '(^|\.)bing\.' then return 'bing'; end if;
  return 'other_site';
end $$;

-- Text we publish: no long dashes, never the numbered company name (CarmaCars only).
create or replace function app.ads_text_problem(p text) returns text
language sql immutable as $$
  select case when p is null or btrim(p) = '' then 'The text is empty'
              when position(chr(8212) in p) > 0 or position(' ' || chr(8211) || ' ' in p) > 0 then 'Rewrite the long dash with a comma, colon or full stop'
              when p ~ '\m18122211\M' then 'Use the brand name CarmaCars, not the numbered company name' end
$$;

-- Money as an ad says it: $75, $1,600, $72.50.
create or replace function app.ad_money(p_cents bigint) returns text
language sql immutable as $$
  select case when p_cents is null then null when p_cents % 100 = 0 then '$' || to_char(p_cents / 100, 'FM999,999,990')
              else '$' || to_char(p_cents / 100.0, 'FM999,999,990.00') end
$$;

-- ================================================================ 3. posted ads
create table if not exists ad_postings (
  id              uuid primary key default gen_random_uuid(),
  vehicle_id      uuid not null references vehicles (id) on delete cascade,
  channel         text not null check (channel = any (app.ad_channels())),
  url             text check (url is null or url ~ '^https?://[^[:space:]]+$'),
  posted_on       date not null,
  status          text not null default 'live' check (status in ('live', 'removed')),
  title           text,
  body            text,
  price_line      text,
  snapshot        jsonb not null default '{}'::jsonb,
  needs_update    boolean not null default false,
  update_reason   text,
  update_task_id  uuid references tasks (id) on delete set null,
  updated_on      date,
  removed_on      date,
  removed_reason  text,
  note            text,
  posted_by       uuid references users (id) on delete set null,
  created_at      timestamptz not null default now(),
  updated_at      timestamptz not null default now(),
  check (status <> 'removed' or removed_on is not null)
);
create trigger ad_postings_updated before update on ad_postings for each row execute function app.set_updated_at();
create unique index if not exists ad_postings_live_one_idx on ad_postings (vehicle_id, channel) where status = 'live';
create index if not exists ad_postings_vehicle_idx on ad_postings (vehicle_id, status);
comment on table ad_postings is 'Advertising (0167): an ad a person posted by hand on a channel (one live ad per car and channel), what it said (snapshot: the rates and whether the car took requests) and whether it needs updating.';
comment on column ad_postings.snapshot is 'What the ad said when it was posted or last updated: {taking, daily, weekend, weekly, monthly, deposit, km, overage, delivery} (cents, km).';

insert into task_rules (task_type, queue, title, priority, due_kind, due_amount, procedure_no, completion_rule, description) values
  ('ad_update', 'sales', 'Update a posted ad', 'normal', 'business_days', 1, null, null,
   'A car''s rates or availability changed: update (or take down) the ad on the channel with the new text from Admin > Marketing > Listings, then mark it updated (0167)')
on conflict (task_type) do nothing;

-- What an ad would say about the car now (the public listing: taking requests, the current rate card).
create or replace function app.ad_snapshot(p_vehicle uuid) returns jsonb
language sql stable security definer set search_path = public, app as $$
  select jsonb_build_object('taking', pv.vehicle_id is not null, 'daily', pv.daily_rate_cents, 'weekend', pv.weekend_rate_cents,
           'weekly', pv.weekly_rate_cents, 'monthly', pv.monthly_rate_cents, 'deposit', pv.deposit_cents, 'km', pv.km_allowance_per_day,
           'overage', pv.overage_cents_per_km, 'delivery', pv.delivery_fee_cents)
    from (select p_vehicle as id) x left join lateral (select * from public_vehicle_listings p where p.vehicle_id = x.id limit 1) pv on true
$$;

-- The price line every channel's text carries (the web app writes the same: features/ads/listing.ts priceLine).
create or replace function app.ad_price_line(s jsonb) returns text
language sql immutable as $$
  select case when coalesce((s ->> 'daily')::bigint, 0) <= 0 then null else
    'From ' || app.ad_money((s ->> 'daily')::bigint) || ' a day'
    || case when coalesce((s ->> 'weekly')::bigint, 0) > 0 then ', ' || app.ad_money((s ->> 'weekly')::bigint) || ' a week' else '' end
    || case when coalesce((s ->> 'monthly')::bigint, 0) > 0 then ', ' || app.ad_money((s ->> 'monthly')::bigint) || ' for 30 days' else '' end
    || ', plus HST.' end
$$;

-- Why an ad no longer matches the car (null: it still does). A rate counts when it moved by p_bps or more.
create or replace function app.ad_change_reason(p_old jsonb, p_new jsonb, p_bps integer) returns text
language plpgsql immutable as $$
declare
  v_parts text[] := '{}';
  k record;
  o bigint;
  n bigint;
begin
  if coalesce((p_old ->> 'taking')::boolean, true) and not coalesce((p_new ->> 'taking')::boolean, false) then
    return 'The car stopped taking requests on the site: take the ad down or pause it.';
  end if;
  if not coalesce((p_old ->> 'taking')::boolean, true) and coalesce((p_new ->> 'taking')::boolean, false) then
    v_parts := v_parts || 'The car takes requests again'::text;
  end if;
  for k in select * from (values ('daily', 'Daily rate', true), ('weekend', 'Weekend rate', true), ('weekly', 'Weekly rate', true), ('monthly', '30-day rate', true),
                                 ('deposit', 'Deposit', false), ('km', 'Kilometres a day', false), ('overage', 'Extra km', false), ('delivery', 'Delivery fee', false)) x(key, label, pct) loop
    o := nullif(p_old ->> k.key, '')::bigint;
    n := nullif(p_new ->> k.key, '')::bigint;
    if o is not distinct from n then continue; end if;
    if k.pct and o is not null and n is not null and o > 0 and abs(n - o) * 10000 < o * greatest(p_bps, 0) then continue; end if;
    v_parts := v_parts || (k.label || ' ' || case when k.key = 'km' then coalesce(o::text, 'none') || ' to ' || coalesce(n::text, 'none')
                                            when k.key = 'overage' then coalesce(o::text || ' cents', 'none') || ' to ' || coalesce(n::text || ' cents', 'none')
                                            else coalesce(app.ad_money(o), 'none') || ' to ' || coalesce(app.ad_money(n), 'none') end);
  end loop;
  if cardinality(v_parts) = 0 then return null; end if;
  return array_to_string(v_parts, '; ') || '.';
end $$;

-- Bring every live ad of a car in step: a task for each ad that no longer matches (one open task per ad, its text kept up
-- to date), and the task closed when the car is back to what the ad says. Returns the number of ads that need updating.
create or replace function app.ads_check_vehicle(p_vehicle uuid) returns integer
language plpgsql security definer set search_path = public, app as $$
declare
  s program_settings := app.settings();
  v_now jsonb := app.ad_snapshot(p_vehicle);
  a ad_postings;
  v_reason text;
  v_task uuid;
  v_detail text;
  v_name text := app.vehicle_name(p_vehicle);
  n integer := 0;
begin
  for a in select * from ad_postings where vehicle_id = p_vehicle and status = 'live' for update loop
    v_reason := app.ad_change_reason(a.snapshot, v_now, s.ads_rate_change_bps);
    if v_reason is null then
      if a.needs_update then
        update tasks set status = 'cancelled', completed_at = now(), completion_note = 'The car is back to what the ad says'
         where id = a.update_task_id and status in ('open', 'in_progress', 'waiting');
        update ad_postings set needs_update = false, update_reason = null, update_task_id = null where id = a.id;
      end if;
      continue;
    end if;
    n := n + 1;
    v_detail := concat_ws(' ', v_reason,
      case when coalesce((v_now ->> 'taking')::boolean, false) then 'New price line: ' || coalesce(app.ad_price_line(v_now), '(no daily rate)') end,
      'Ad: ' || coalesce(a.url, 'no address recorded') || '.',
      'The new text: ' || s.notify_base_url || '/admin/marketing/listings?car=' || p_vehicle || '&channel=' || a.channel);
    if a.update_task_id is not null and exists (select 1 from tasks t where t.id = a.update_task_id and t.status in ('open', 'in_progress', 'waiting')) then
      v_task := a.update_task_id;
      update tasks set detail = v_detail where id = v_task and detail is distinct from v_detail;
    else
      v_task := app.raise_task(p_type => 'ad_update', p_title => 'Update the ' || app.ad_channel_label(a.channel) || ' ad: ' || coalesce(v_name, 'a car'),
                               p_detail => v_detail, p_vehicle => p_vehicle, p_related_table => 'ad_postings', p_related_id => a.id,
                               p_due_at => now() + interval '1 day', p_dedupe => 'adupd:' || a.id);
    end if;
    update ad_postings set needs_update = true, update_reason = v_reason, update_task_id = v_task where id = a.id;
  end loop;
  return n;
end $$;

-- At commit (the rate card is replaced in two steps; the final state counts), for a car with a live ad.
create or replace function app.ads_check_trigger() returns trigger
language plpgsql security definer set search_path = public, app as $$
declare
  v uuid := coalesce((to_jsonb(new) ->> 'vehicle_id')::uuid, case when tg_table_name = 'vehicles' then (to_jsonb(new) ->> 'id')::uuid end);
begin
  if v is not null and exists (select 1 from ad_postings a where a.vehicle_id = v and a.status = 'live') then
    perform app.ads_check_vehicle(v);
  end if;
  return null;
end $$;
create constraint trigger ads_check_rate_cards after insert or update on rate_cards deferrable initially deferred
  for each row execute function app.ads_check_trigger();
create constraint trigger ads_check_listings after insert or update of status, publish_at on vehicle_listings deferrable initially deferred
  for each row execute function app.ads_check_trigger();
create constraint trigger ads_check_vehicles after update of status, bookings_enabled, retired_at, management_mode, in_arrears on vehicles deferrable initially deferred
  for each row execute function app.ads_check_trigger();

-- A task closed by hand (Staff tasks, Done) counts as the ad updated: the figures it now says are the car's.
create or replace function app.ads_task_done() returns trigger
language plpgsql security definer set search_path = public, app as $$
begin
  if new.task_type = 'ad_update' and new.status = 'done' and old.status is distinct from 'done' and new.related_table = 'ad_postings' then
    update ad_postings set snapshot = app.ad_snapshot(vehicle_id), price_line = coalesce(app.ad_price_line(app.ad_snapshot(vehicle_id)), price_line),
           needs_update = false, update_reason = null, update_task_id = null, updated_on = app.today()
     where id = new.related_id and status = 'live';
  end if;
  return null;
end $$;
create trigger tasks_ads_done after update of status on tasks for each row execute function app.ads_task_done();

-- ================================================================ 4. bookings per channel
alter table bookings
  add column if not exists marketing_source text check (marketing_source is null or marketing_source = any (app.marketing_sources())),
  add column if not exists marketing_source_note text,
  add column if not exists marketing_source_by uuid references users (id) on delete set null,
  add column if not exists marketing_source_at timestamptz;
comment on column bookings.marketing_source is 'Advertising (0167): where the renter came from, set by staff (a Kijiji reply, a walk-in). Wins over the visit''s source in the channel report.';

create table if not exists booking_attribution (
  booking_id       uuid primary key references bookings (id) on delete cascade,
  visitor_id       uuid,
  first_at         timestamptz,
  first_source     text,
  first_medium     text,
  first_campaign   text,
  first_referrer   text,
  first_landing    text,
  first_channel    text,
  last_at          timestamptz,
  last_source      text,
  last_medium      text,
  last_campaign    text,
  last_referrer    text,
  last_landing     text,
  last_channel     text,
  captured_at      timestamptz not null default now()
);
comment on table booking_attribution is 'Advertising (0167): the first and last visit of the renter''s browser before the request (campaign source, medium and name, referring site, landing page), kept with the booking when the request is sent. Visits themselves are deleted after 90 days.';

-- Capture (or capture again) a booking's first and last touch from the visits still kept. Prefers a visit with a source
-- (a campaign or a referring site) over a direct one for both touches.
create or replace function app.booking_attribution_capture(p_booking uuid) returns void
language plpgsql security definer set search_path = public, app as $$
declare
  b bookings;
  v_at timestamptz;
  v_vid uuid;
  f visitor_sessions;
  l visitor_sessions;
begin
  select * into b from bookings where id = p_booking;
  if b.id is null or b.booking_type = 'owner' then return; end if;
  v_at := coalesce(b.requested_at, b.created_at) + interval '10 minutes';
  select s.visitor_id into v_vid from visitor_events e join visitor_sessions s on s.id = e.session_id
   where e.booking_id = b.id and e.kind = 'request_submitted' order by e.at limit 1;
  if v_vid is null then
    select s.visitor_id into v_vid from visitor_sessions s where s.renter_id = b.renter_id and s.started_at <= v_at order by s.started_at desc limit 1;
  end if;
  if v_vid is not null then
    select * into f from visitor_sessions s where s.visitor_id = v_vid and s.started_at <= v_at
     order by (nullif(btrim(coalesce(s.utm ->> 'source', '')), '') is not null or nullif(btrim(coalesce(s.referrer, '')), '') is not null) desc, s.started_at asc limit 1;
    select * into l from visitor_sessions s where s.visitor_id = v_vid and s.started_at <= v_at
     order by (nullif(btrim(coalesce(s.utm ->> 'source', '')), '') is not null or nullif(btrim(coalesce(s.referrer, '')), '') is not null) desc, s.started_at desc limit 1;
  end if;
  insert into booking_attribution as x (booking_id, visitor_id, first_at, first_source, first_medium, first_campaign, first_referrer, first_landing, first_channel,
                                         last_at, last_source, last_medium, last_campaign, last_referrer, last_landing, last_channel, captured_at)
  values (b.id, v_vid, f.started_at, f.utm ->> 'source', f.utm ->> 'medium', f.utm ->> 'campaign', f.referrer, f.landing_path,
          case when f.id is not null then app.ad_channel_of(f.utm ->> 'source', f.referrer) end,
          l.started_at, l.utm ->> 'source', l.utm ->> 'medium', l.utm ->> 'campaign', l.referrer, l.landing_path,
          case when l.id is not null then app.ad_channel_of(l.utm ->> 'source', l.referrer) end, now())
  on conflict (booking_id) do update set visitor_id = excluded.visitor_id, first_at = excluded.first_at, first_source = excluded.first_source,
    first_medium = excluded.first_medium, first_campaign = excluded.first_campaign, first_referrer = excluded.first_referrer, first_landing = excluded.first_landing,
    first_channel = excluded.first_channel, last_at = excluded.last_at, last_source = excluded.last_source, last_medium = excluded.last_medium,
    last_campaign = excluded.last_campaign, last_referrer = excluded.last_referrer, last_landing = excluded.last_landing, last_channel = excluded.last_channel,
    captured_at = now()
   where excluded.visitor_id is not null or x.visitor_id is null;
end $$;

-- The request's page view ("Request sent") ties the visit to the booking: capture then.
create or replace function app.booking_attribution_trigger() returns trigger
language plpgsql security definer set search_path = public, app as $$
begin
  perform app.booking_attribution_capture(new.booking_id);
  return null;
end $$;
create trigger visitor_events_attribution after insert on visitor_events for each row
  when (new.kind = 'request_submitted' and new.booking_id is not null) execute function app.booking_attribution_trigger();

-- The channel a booking counts under: staff's source, then the visit (first or last touch) unless direct, then a referral
-- code, then how the request reached us (phone, email, WhatsApp), then direct, else not known.
create or replace function app.booking_channel(b bookings, a booking_attribution, p_model text default 'last') returns text
language sql immutable as $$
  select coalesce(b.marketing_source,
    nullif(case when p_model = 'first' then a.first_channel else a.last_channel end, 'direct'),
    case when b.referral_partner_id is not null or b.referrer_type is not null then 'referral' end,
    case when b.source in ('phone', 'email', 'whatsapp') then b.source end,
    case when p_model = 'first' then a.first_channel else a.last_channel end,
    'unknown')
$$;

create or replace function app.booking_is_booked(b bookings) returns boolean
language sql immutable as $$ select b.status in ('confirmed', 'on_rent', 'returned', 'closed') $$;
create or replace function app.booking_revenue_cents(b bookings) returns bigint
language sql immutable as $$ select greatest(0, b.rental_charge_cents - b.discount_cents - b.staff_discount_cents - b.promo_discount_cents)::bigint $$;

-- Requests and bookings by channel and month. p: {from, to (dates, Toronto), model: last | first}
create or replace function app.ads_report(p_by uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  v_to date := coalesce(nullif(p ->> 'to', '')::date, app.today());
  v_from date := coalesce(nullif(p ->> 'from', '')::date, (app.month_start(app.today()) - interval '11 months')::date);
  v_model text := case when p ->> 'model' = 'first' then 'first' else 'last' end;
  x record;
begin
  perform app.assert_admin(p_by);
  if v_from > v_to then raise exception 'The start date is after the end date' using errcode = '22023'; end if;
  -- the bookings of the period not captured yet (added by staff, or sent before this report existed)
  for x in select b.id from bookings b where b.booking_type <> 'owner' and app.local_date(coalesce(b.requested_at, b.created_at)) between v_from and v_to
             and not exists (select 1 from booking_attribution a where a.booking_id = b.id) limit 2000 loop
    perform app.booking_attribution_capture(x.id);
  end loop;
  return (
    with b as (
      select bk.id, app.booking_channel(bk, a, v_model) as channel, to_char(app.local_date(coalesce(bk.requested_at, bk.created_at)), 'YYYY-MM') as month,
             app.booking_is_booked(bk) as booked, case when app.booking_is_booked(bk) then app.booking_revenue_cents(bk) else 0 end as revenue
        from bookings bk left join booking_attribution a on a.booking_id = bk.id
       where bk.booking_type <> 'owner' and app.local_date(coalesce(bk.requested_at, bk.created_at)) between v_from and v_to),
    c as (select channel, count(*) as requests, count(*) filter (where booked) as bookings, sum(revenue) as revenue from b group by channel),
    m as (select month, channel, count(*) as requests, count(*) filter (where booked) as bookings, sum(revenue) as revenue from b group by month, channel)
    select jsonb_build_object('from', v_from, 'to', v_to, 'model', v_model,
      'totals', (select jsonb_build_object('requests', count(*), 'bookings', count(*) filter (where booked), 'revenue_cents', coalesce(sum(revenue), 0)) from b),
      'channels', (select coalesce(jsonb_agg(jsonb_build_object('channel', c.channel, 'label', app.ad_channel_label(c.channel), 'requests', c.requests, 'bookings', c.bookings,
                     'revenue_cents', c.revenue, 'conversion_bps', case when c.requests > 0 then round(c.bookings * 10000.0 / c.requests)::integer else 0 end)
                     order by c.bookings desc, c.requests desc, c.channel), '[]'::jsonb) from c),
      'months', (select coalesce(jsonb_agg(jsonb_build_object('month', m.month, 'channel', m.channel, 'label', app.ad_channel_label(m.channel), 'requests', m.requests,
                     'bookings', m.bookings, 'revenue_cents', m.revenue) order by m.month desc, m.bookings desc, m.channel), '[]'::jsonb) from m),
      'postings', (select jsonb_build_object('live', count(*) filter (where status = 'live'), 'needs_update', count(*) filter (where status = 'live' and needs_update)) from ad_postings))
  );
end $$;

-- One booking's source for its page. p: {booking: number}
create or replace function app.booking_marketing(p_by uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  b bookings;
  a booking_attribution;
begin
  perform app.assert_admin(p_by);
  select * into b from bookings where booking_number = p ->> 'booking';
  if b.id is null then raise exception 'Booking not found' using errcode = 'P0002'; end if;
  if not exists (select 1 from booking_attribution x where x.booking_id = b.id) then perform app.booking_attribution_capture(b.id); end if;
  select * into a from booking_attribution where booking_id = b.id;
  return jsonb_build_object('channel', app.booking_channel(b, a, 'last'), 'label', app.ad_channel_label(app.booking_channel(b, a, 'last')),
    'first', app.ad_channel_label(app.booking_channel(b, a, 'first')), 'staff_source', b.marketing_source, 'staff_note', b.marketing_source_note,
    'visit', case when a.visitor_id is not null then jsonb_build_object('first_source', a.first_source, 'first_campaign', a.first_campaign, 'first_referrer', a.first_referrer,
      'first_at', a.first_at, 'last_source', a.last_source, 'last_campaign', a.last_campaign, 'last_referrer', a.last_referrer, 'last_at', a.last_at) end,
    'options', (select jsonb_agg(jsonb_build_array(k, app.ad_channel_label(k)) order by n) from unnest(app.marketing_sources()) with ordinality u(k, n)));
end $$;

-- p: {booking: number, source (empty clears it), note}
create or replace function app.booking_marketing_source(p_by uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  b bookings;
  v text := nullif(btrim(coalesce(p ->> 'source', '')), '');
begin
  perform app.assert_admin(p_by);
  select * into b from bookings where booking_number = p ->> 'booking' for update;
  if b.id is null then raise exception 'Booking not found' using errcode = 'P0002'; end if;
  if v is not null and not v = any (app.marketing_sources()) then raise exception 'Choose where the renter came from in the list' using errcode = '22023'; end if;
  update bookings set marketing_source = v, marketing_source_note = nullif(btrim(coalesce(p ->> 'note', '')), ''), marketing_source_by = p_by, marketing_source_at = now() where id = b.id;
  insert into audit_log (actor_user_id, action, entity_table, entity_id, before, after)
  values (p_by, 'booking_marketing_source', 'bookings', b.id::text, jsonb_build_object('source', b.marketing_source), jsonb_build_object('source', v));
  return jsonb_build_object('source', v);
end $$;

-- ================================================================ 5. the listing facts and the postings (Admin)
-- Everything the listing text generator needs, per car with a listing (taking requests or not), and the rules of the site.
create or replace function app.ads_facts() returns jsonb
language sql stable security definer set search_path = public, app as $$
  select jsonb_build_object('today', app.today(), 'site_url', (app.settings()).notify_base_url,
    'rules', jsonb_build_object('min_age', (app.settings()).min_renter_age, 'standard_min_age', (app.settings()).standard_min_age, 'max_days', (app.settings()).max_rental_days),
    'cars', coalesce((select jsonb_agg(c order by (c ->> 'taking')::boolean desc, c ->> 'name') from (
      select jsonb_build_object('vehicle_id', v.id, 'car_code', v.car_code, 'slug', l.slug, 'name', app.vehicle_name(v.id), 'year', v.year, 'make', v.make, 'model', v.model, 'trim', v.trim,
        'colour', v.colour, 'fuel', v.fuel, 'class', coalesce((select vc.label from vehicle_classes vc where vc.code = v.class::text), initcap(replace(v.class::text, '_', ' '))),
        'seats', l.seats, 'transmission', l.transmission, 'body_style', coalesce(l.body_style, v.body_type), 'features', to_jsonb(coalesce(l.features, '{}')),
        'allows_18_to_20', v.allows_18_to_20, 'no_credit_card', v.no_credit_card, 'on_fleet_policy', v.on_fleet_policy, 'is_featured', l.is_featured,
        'first_published_at', l.first_published_at, 'taking', (s ->> 'taking')::boolean,
        'daily', (s ->> 'daily')::bigint, 'weekend', (s ->> 'weekend')::bigint, 'weekly', (s ->> 'weekly')::bigint, 'monthly', (s ->> 'monthly')::bigint,
        'deposit', (s ->> 'deposit')::bigint, 'km', (s ->> 'km')::integer, 'overage', (s ->> 'overage')::integer, 'delivery', (s ->> 'delivery')::bigint,
        'free_this_weekend', case when (s ->> 'taking')::boolean then public.vehicle_is_available(v.id,
            app.local_midnight(app.today() + ((5 - extract(isodow from app.today())::integer + 7) % 7)) + interval '17 hours',
            app.local_midnight(app.today() + ((5 - extract(isodow from app.today())::integer + 7) % 7) + 2) + interval '20 hours') else false end,
        'photos', coalesce((select jsonb_agg(jsonb_build_object('path', ph ->> 'path', 'label', ph ->> 'label', 'shot', ph ->> 'shot', 'alt', ph ->> 'alt', 'sample', coalesce((ph ->> 'sample')::boolean, false)))
                              from jsonb_array_elements(app.public_listing_photos(v.id)) ph), '[]'::jsonb)) as c
        from vehicles v join vehicle_listings l on l.vehicle_id = v.id
        cross join lateral (select app.ad_snapshot(v.id) s) snap
       where v.retired_at is null and v.management_mode <> 'turo_only' and l.slug is not null) cars), '[]'::jsonb))
$$;

create or replace function app.ad_posting_row(a ad_postings) returns jsonb
language sql stable security definer set search_path = public, app as $$
  select jsonb_build_object('id', a.id, 'vehicle_id', a.vehicle_id, 'car', app.vehicle_name(a.vehicle_id), 'car_code', (select car_code from vehicles where id = a.vehicle_id),
    'channel', a.channel, 'channel_label', app.ad_channel_label(a.channel), 'url', a.url, 'posted_on', a.posted_on, 'status', a.status, 'title', a.title, 'price_line', a.price_line,
    'needs_update', a.needs_update, 'update_reason', a.update_reason, 'update_task_id', a.update_task_id, 'updated_on', a.updated_on, 'removed_on', a.removed_on,
    'removed_reason', a.removed_reason, 'note', a.note, 'posted_by', (select full_name from users where id = a.posted_by))
$$;

create or replace function app.ads_listings_read(p_by uuid, p jsonb) returns jsonb
language plpgsql stable security definer set search_path = public, app as $$
begin
  perform app.assert_admin(p_by);
  return app.ads_facts() || jsonb_build_object('channels', to_jsonb(app.ad_channels()),
    'postings', (select coalesce(jsonb_agg(app.ad_posting_row(a) order by a.posted_on desc), '[]'::jsonb) from ad_postings a where a.status = 'live'));
end $$;

create or replace function app.ads_postings_read(p_by uuid, p jsonb) returns jsonb
language plpgsql stable security definer set search_path = public, app as $$
declare
  v_status text := nullif(p ->> 'status', '');
begin
  perform app.assert_admin(p_by);
  return jsonb_build_object('rows', (select coalesce(jsonb_agg(app.ad_posting_row(a) order by a.needs_update desc, a.posted_on desc, a.created_at desc), '[]'::jsonb)
      from ad_postings a where (v_status is null and a.status = 'live') or (v_status = 'needs_update' and a.status = 'live' and a.needs_update) or (v_status = 'removed' and a.status = 'removed') or v_status = 'all'),
    'counts', (select jsonb_build_object('live', count(*) filter (where status = 'live'), 'needs_update', count(*) filter (where status = 'live' and needs_update), 'removed', count(*) filter (where status = 'removed')) from ad_postings));
end $$;

-- Record an ad posted by hand, or that it was updated. p: {vehicle, channel, url, posted_on, title, body, price_line, note}
-- A live ad of the car on the channel is the same ad (its address and text are replaced): one ad per car and channel.
create or replace function app.ad_posting_save(p_by uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  v_vehicle uuid := nullif(p ->> 'vehicle', '')::uuid;
  v_channel text := p ->> 'channel';
  v_url text := nullif(btrim(coalesce(p ->> 'url', '')), '');
  v_on date := coalesce(nullif(p ->> 'posted_on', '')::date, app.today());
  v_body text := nullif(btrim(coalesce(p ->> 'body', '')), '');
  v_title text := nullif(btrim(coalesce(p ->> 'title', '')), '');
  a ad_postings;
  v_snap jsonb;
  v_problem text;
begin
  perform app.assert_admin(p_by);
  if v_vehicle is null or not exists (select 1 from vehicles where id = v_vehicle) then raise exception 'Choose the car' using errcode = '22023'; end if;
  if v_channel is null or not v_channel = any (app.ad_channels()) then raise exception 'Choose the channel' using errcode = '22023'; end if;
  if v_url is not null and v_url !~ '^https?://[^[:space:]]+$' then raise exception 'Paste the ad''s address as it shows in the browser (it starts with https://)' using errcode = '22023'; end if;
  if v_on > app.today() then raise exception 'The date posted cannot be in the future' using errcode = '22023'; end if;
  v_problem := case when v_body is not null then app.ads_text_problem(v_body) end;
  if v_problem is null and v_title is not null then v_problem := app.ads_text_problem(v_title); end if;
  if v_problem is not null then raise exception '%', v_problem using errcode = '22023'; end if;
  v_snap := app.ad_snapshot(v_vehicle);
  select * into a from ad_postings where vehicle_id = v_vehicle and channel = v_channel and status = 'live' for update;
  if a.id is null then
    insert into ad_postings (vehicle_id, channel, url, posted_on, title, body, price_line, snapshot, note, posted_by, updated_on)
    values (v_vehicle, v_channel, v_url, v_on, v_title, v_body, coalesce(nullif(btrim(coalesce(p ->> 'price_line', '')), ''), app.ad_price_line(v_snap)), v_snap,
            nullif(btrim(coalesce(p ->> 'note', '')), ''), p_by, v_on)
    returning * into a;
  else
    if a.update_task_id is not null then
      update tasks set status = 'done', completed_at = now(), completed_by = p_by, completion_note = 'Ad updated'
       where id = a.update_task_id and status in ('open', 'in_progress', 'waiting');
    end if;
    update ad_postings set url = coalesce(v_url, url), title = coalesce(v_title, title), body = coalesce(v_body, body),
           price_line = coalesce(nullif(btrim(coalesce(p ->> 'price_line', '')), ''), app.ad_price_line(v_snap), price_line), snapshot = v_snap,
           needs_update = false, update_reason = null, update_task_id = null, updated_on = v_on, note = coalesce(nullif(btrim(coalesce(p ->> 'note', '')), ''), note)
     where id = a.id returning * into a;
  end if;
  return app.ad_posting_row(a);
end $$;

-- The ad was taken down. p: {id, reason}
create or replace function app.ad_posting_remove(p_by uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  a ad_postings;
begin
  perform app.assert_admin(p_by);
  select * into a from ad_postings where id = nullif(p ->> 'id', '')::uuid for update;
  if a.id is null then raise exception 'Ad not found' using errcode = 'P0002'; end if;
  if a.status = 'removed' then return app.ad_posting_row(a); end if;
  if a.update_task_id is not null then
    update tasks set status = 'done', completed_at = now(), completed_by = p_by, completion_note = 'Ad taken down'
     where id = a.update_task_id and status in ('open', 'in_progress', 'waiting');
  end if;
  update ad_postings set status = 'removed', removed_on = app.today(), removed_reason = coalesce(nullif(btrim(coalesce(p ->> 'reason', '')), ''), 'Taken down'),
         needs_update = false, update_task_id = null
   where id = a.id returning * into a;
  return app.ad_posting_row(a);
end $$;

-- ================================================================ 6. Facebook Page and Instagram drafts
create table if not exists social_drafts (
  id               uuid primary key default gen_random_uuid(),
  slot_date        date not null,
  kind             text not null check (kind in ('new_car', 'featured_car', 'price_highlight', 'weekend_list', 'seasonal', 'owner_program', 'requirements', 'custom')),
  channels         text[] not null default array['instagram', 'facebook_page'] check (cardinality(channels) > 0 and channels <@ array['instagram', 'facebook_page']),
  vehicle_id       uuid references vehicles (id) on delete set null,
  caption          text not null check (length(caption) between 1 and 2200),
  link             text check (link is null or link ~ '^https://[^[:space:]]+$'),
  photos           jsonb not null default '[]'::jsonb check (jsonb_typeof(photos) = 'array'),
  status           text not null default 'draft' check (status in ('draft', 'approved', 'posted', 'skipped')),
  source           text not null default 'auto' check (source in ('auto', 'staff')),
  edited           boolean not null default false,
  approved_by      uuid references users (id) on delete set null,
  approved_at      timestamptz,
  posted           jsonb not null default '{}'::jsonb,
  publish_error    text,
  publish_attempts integer not null default 0,
  created_by       uuid references users (id) on delete set null,
  created_at       timestamptz not null default now(),
  updated_at       timestamptz not null default now(),
  check (status not in ('approved', 'posted') or approved_at is not null)
);
create trigger social_drafts_updated before update on social_drafts for each row execute function app.set_updated_at();
create unique index if not exists social_drafts_auto_one_idx on social_drafts (slot_date, kind) where source = 'auto';
create index if not exists social_drafts_slot_idx on social_drafts (slot_date, status);
comment on table social_drafts is 'Advertising (0167): a Facebook Page and Instagram post for a day: written from the fleet (source auto) or by staff, approved, then posted by hand (copy and post) or through Meta''s API when it is set up. posted: {channel: {url, post_id, at, how: hand | api}}.';

create table if not exists meta_publishing (
  singleton      boolean primary key default true check (singleton),
  enabled        boolean not null default false,
  page_id        text check (page_id is null or page_id ~ '^[0-9]{5,30}$'),
  ig_user_id     text check (ig_user_id is null or ig_user_id ~ '^[0-9]{5,30}$'),
  graph_version  text not null default 'v21.0' check (graph_version ~ '^v[0-9]{1,2}\.[0-9]$'),
  token_ref      uuid,
  token_store    text check (token_store in ('vault', 'database')),
  token_hint     text,
  last_ok_at     timestamptz,
  last_error     text,
  updated_by     uuid references users (id) on delete set null,
  updated_at     timestamptz not null default now()
);
insert into meta_publishing (singleton) values (true) on conflict do nothing;
comment on table meta_publishing is 'Advertising (0167): publishing approved drafts to the Facebook Page and Instagram through Meta''s Graph API. Off until an Admin enters the Page id, the Instagram professional account id and a Page access token (the token in Supabase Vault; the row keeps only its vault id and last four characters).';

create table if not exists ads_job_state (
  singleton      boolean primary key default true check (singleton),
  last_run_at    timestamptz,
  last_result    jsonb
);
insert into ads_job_state (singleton) values (true) on conflict do nothing;

create or replace function app.meta_usable(m meta_publishing) returns boolean
language sql immutable as $$ select m.enabled and m.token_ref is not null and m.page_id is not null $$;

create or replace function app.social_draft_row(x social_drafts) returns jsonb
language sql stable security definer set search_path = public, app as $$
  select jsonb_build_object('id', x.id, 'slot_date', x.slot_date, 'weekday', to_char(x.slot_date, 'FMDay'), 'kind', x.kind, 'channels', to_jsonb(x.channels),
    'vehicle_id', x.vehicle_id, 'car', case when x.vehicle_id is not null then app.vehicle_name(x.vehicle_id) end, 'car_code', (select v.car_code from vehicles v where v.id = x.vehicle_id), 'caption', x.caption, 'link', x.link, 'photos', x.photos,
    'status', x.status, 'source', x.source, 'edited', x.edited, 'approved_by', (select full_name from users where id = x.approved_by), 'approved_at', x.approved_at,
    'posted', x.posted, 'publish_error', x.publish_error)
$$;

-- The week of drafts (Monday to Sunday). p: {week: a date in the week}
create or replace function app.social_drafts_read(p_by uuid, p jsonb) returns jsonb
language plpgsql stable security definer set search_path = public, app as $$
declare
  v_day date := coalesce(nullif(p ->> 'week', '')::date, app.today());
  v_mon date := v_day - (extract(isodow from v_day)::integer - 1);
  m meta_publishing;
begin
  perform app.assert_admin(p_by);
  select * into m from meta_publishing;
  return jsonb_build_object('week', v_mon, 'today', app.today(), 'enabled', (app.settings()).ads_social_drafts_enabled,
    'drafts', (select coalesce(jsonb_agg(app.social_draft_row(x) order by x.slot_date, x.created_at), '[]'::jsonb) from social_drafts x where x.slot_date between v_mon and v_mon + 6),
    'meta', jsonb_build_object('usable', app.meta_usable(m), 'enabled', m.enabled, 'instagram', m.ig_user_id is not null));
end $$;

-- Drafts from the generator (the ads job, or Admin's "Write this week's drafts"). An automatic draft already there for the
-- day and kind is left alone (edited, approved or not). p: {drafts: [{slot_date, kind, channels, vehicle_id, caption, link, photos}]}
create or replace function app.social_drafts_store(p jsonb, p_by uuid default null, p_source text default 'auto') returns integer
language plpgsql security definer set search_path = public, app as $$
declare
  d jsonb;
  n integer := 0;
  v_problem text;
begin
  for d in select * from jsonb_array_elements(coalesce(p -> 'drafts', '[]'::jsonb)) loop
    v_problem := app.ads_text_problem(d ->> 'caption');
    if v_problem is not null then raise exception 'Draft for %: %', d ->> 'slot_date', v_problem using errcode = '22023'; end if;
    insert into social_drafts (slot_date, kind, channels, vehicle_id, caption, link, photos, source, created_by)
    values ((d ->> 'slot_date')::date, d ->> 'kind', coalesce((select array_agg(c) from jsonb_array_elements_text(d -> 'channels') c), array['instagram', 'facebook_page']),
            nullif(d ->> 'vehicle_id', '')::uuid, d ->> 'caption', nullif(d ->> 'link', ''), coalesce(d -> 'photos', '[]'::jsonb), p_source, p_by)
    on conflict (slot_date, kind) where source = 'auto' do nothing;
    if found then n := n + 1; end if;
  end loop;
  return n;
end $$;

create or replace function app.social_drafts_put(p_by uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
begin
  perform app.assert_admin(p_by);
  return jsonb_build_object('added', app.social_drafts_store(p, p_by, case when p ->> 'source' = 'staff' then 'staff' else 'auto' end));
end $$;

-- Edit a draft (or add one: no id). p: {id?, slot_date, caption, channels, link, photos}. An approved draft goes back to draft.
create or replace function app.social_draft_save(p_by uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  x social_drafts;
  v_caption text := btrim(coalesce(p ->> 'caption', ''));
  v_problem text := app.ads_text_problem(v_caption);
  v_channels text[] := case when jsonb_typeof(p -> 'channels') = 'array' then (select array_agg(c) from jsonb_array_elements_text(p -> 'channels') c)
                            when nullif(p ->> 'channels', '') is not null then string_to_array(replace(p ->> 'channels', ' ', ''), ',') end;
begin
  perform app.assert_admin(p_by);
  if v_problem is not null then raise exception '%', v_problem using errcode = '22023'; end if;
  if length(v_caption) > 2200 then raise exception 'Instagram takes 2,200 characters at most' using errcode = '22023'; end if;
  if v_channels is not null and not (cardinality(v_channels) > 0 and v_channels <@ array['instagram', 'facebook_page']) then raise exception 'Choose Instagram, the Facebook Page or both' using errcode = '22023'; end if;
  if nullif(p ->> 'id', '') is null then
    insert into social_drafts (slot_date, kind, channels, caption, link, photos, source, created_by, edited)
    values (coalesce(nullif(p ->> 'slot_date', '')::date, app.today()), 'custom', coalesce(v_channels, array['instagram', 'facebook_page']), v_caption,
            nullif(btrim(coalesce(p ->> 'link', '')), ''), coalesce(p -> 'photos', '[]'::jsonb), 'staff', p_by, true)
    returning * into x;
  else
    select * into x from social_drafts where id = (p ->> 'id')::uuid for update;
    if x.id is null then raise exception 'Draft not found' using errcode = 'P0002'; end if;
    if x.status = 'posted' then raise exception 'This post is already published: edit it on the channel itself' using errcode = '22023'; end if;
    update social_drafts set caption = v_caption, channels = coalesce(v_channels, channels), slot_date = coalesce(nullif(p ->> 'slot_date', '')::date, slot_date),
           link = case when p ? 'link' then nullif(btrim(coalesce(p ->> 'link', '')), '') else link end, photos = coalesce(p -> 'photos', photos),
           edited = true, status = case when status = 'approved' then 'draft' else status end, approved_by = case when status = 'approved' then null else approved_by end,
           approved_at = case when status = 'approved' then null else approved_at end
     where id = x.id returning * into x;
  end if;
  return app.social_draft_row(x);
end $$;

-- p: {id, action: approve | unapprove | skip | restore}
create or replace function app.social_draft_decide(p_by uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  x social_drafts;
  v_action text := p ->> 'action';
begin
  perform app.assert_admin(p_by);
  select * into x from social_drafts where id = nullif(p ->> 'id', '')::uuid for update;
  if x.id is null then raise exception 'Draft not found' using errcode = 'P0002'; end if;
  if x.status = 'posted' then raise exception 'This post is already published' using errcode = '22023'; end if;
  if v_action = 'approve' then update social_drafts set status = 'approved', approved_by = p_by, approved_at = now(), publish_error = null where id = x.id returning * into x;
  elsif v_action = 'unapprove' or v_action = 'restore' then update social_drafts set status = 'draft', approved_by = null, approved_at = null where id = x.id returning * into x;
  elsif v_action = 'skip' then update social_drafts set status = 'skipped' where id = x.id returning * into x;
  else raise exception 'Unknown action' using errcode = '22023'; end if;
  return app.social_draft_row(x);
end $$;

-- Mark one channel of an approved draft posted (by hand, copy and post; or by the publishing job). The draft is posted
-- once every channel it is for is. p: {id, channel, url, post_id}
create or replace function app.social_mark_posted(p_id uuid, p_channel text, p_url text, p_post_id text, p_how text, p_by uuid) returns social_drafts
language plpgsql security definer set search_path = public, app as $$
declare
  x social_drafts;
begin
  select * into x from social_drafts where id = p_id for update;
  if x.id is null then raise exception 'Draft not found' using errcode = 'P0002'; end if;
  if not p_channel = any (x.channels) then raise exception 'This draft is not for that channel' using errcode = '22023'; end if;
  if x.status not in ('approved', 'posted') then raise exception 'Approve the draft before posting it' using errcode = '22023'; end if;
  if p_url is not null and p_url !~ '^https://[^[:space:]]+$' then raise exception 'Paste the post''s address (it starts with https://)' using errcode = '22023'; end if;
  update social_drafts set posted = posted || jsonb_build_object(p_channel, jsonb_strip_nulls(jsonb_build_object('url', p_url, 'post_id', p_post_id, 'at', now(), 'how', p_how, 'by', p_by))),
         publish_error = null
   where id = x.id returning * into x;
  if (select bool_and(x.posted ? c) from unnest(x.channels) c) then
    update social_drafts set status = 'posted' where id = x.id returning * into x;
  end if;
  return x;
end $$;

create or replace function app.social_draft_posted(p_by uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
begin
  perform app.assert_admin(p_by);
  return app.social_draft_row(app.social_mark_posted(nullif(p ->> 'id', '')::uuid, p ->> 'channel', nullif(btrim(coalesce(p ->> 'url', '')), ''), null, 'hand', p_by));
end $$;

create or replace function app.meta_publishing_read(p_by uuid, p jsonb) returns jsonb
language plpgsql stable security definer set search_path = public, app as $$
declare
  m meta_publishing;
begin
  perform app.assert_admin(p_by);
  select * into m from meta_publishing;
  return jsonb_build_object('enabled', m.enabled, 'usable', app.meta_usable(m), 'page_id', m.page_id, 'ig_user_id', m.ig_user_id, 'graph_version', m.graph_version,
    'has_token', m.token_ref is not null, 'token_hint', m.token_hint, 'token_store', m.token_store, 'last_ok_at', m.last_ok_at, 'last_error', m.last_error, 'updated_at', m.updated_at,
    'posted_by_api', (select count(*) from social_drafts x, jsonb_each(x.posted) e where e.value ->> 'how' = 'api'));
end $$;

-- p: {page_id, ig_user_id, graph_version, token (empty: keep; "-" removes it), enabled}. On needs the token and the Page id.
create or replace function app.meta_publishing_save(p_by uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  o meta_publishing;
  m meta_publishing;
  v_token text := nullif(btrim(coalesce(p ->> 'token', '')), '');
  v_ref uuid;
  v_page text;
  v_enabled boolean;
begin
  perform app.assert_admin(p_by);
  select * into o from meta_publishing for update;
  v_ref := o.token_ref;
  if v_token = '-' then perform app.crm_secret_drop(o.token_ref); v_ref := null;
  elsif v_token is not null then
    if length(v_token) < 20 or v_token ~ '\s' then raise exception 'Paste the whole Page access token (a long string without spaces)' using errcode = '22023'; end if;
    v_ref := app.crm_secret_put(o.token_ref, v_token, 'meta-page-token');
  end if;
  v_page := case when p ? 'page_id' then nullif(btrim(coalesce(p ->> 'page_id', '')), '') else o.page_id end;
  v_enabled := coalesce((p ->> 'enabled')::boolean, o.enabled);
  if v_enabled and (v_ref is null or v_page is null) then raise exception 'Publishing needs the Page id and the Page access token first' using errcode = '22023'; end if;
  update meta_publishing set page_id = v_page,
         ig_user_id = case when p ? 'ig_user_id' then nullif(btrim(coalesce(p ->> 'ig_user_id', '')), '') else ig_user_id end,
         graph_version = coalesce(nullif(btrim(coalesce(p ->> 'graph_version', '')), ''), graph_version),
         token_ref = v_ref, token_store = case when v_ref is null then null when v_token is not null then case when app.crm_vault() then 'vault' else 'database' end else token_store end,
         token_hint = case when v_ref is null then null when v_token is not null and v_token <> '-' then right(v_token, 4) else token_hint end,
         enabled = v_enabled, last_error = case when v_token is not null then null else last_error end, updated_by = p_by, updated_at = now()
   returning * into m;
  insert into audit_log (actor_user_id, action, entity_table, entity_id, before, after)
  values (p_by, 'meta_publishing_save', 'meta_publishing', 'singleton', jsonb_build_object('enabled', o.enabled, 'has_token', o.token_ref is not null, 'page_id', o.page_id),
          jsonb_build_object('enabled', m.enabled, 'has_token', m.token_ref is not null, 'page_id', m.page_id));
  return jsonb_build_object('enabled', m.enabled, 'usable', app.meta_usable(m));
end $$;

-- ================================================================ 7. the ads job (every 6 hours, and when an approved post is due)
create or replace function app.ads_job_due() returns boolean
language sql stable security definer set search_path = public, app as $$
  select coalesce((select last_run_at from ads_job_state), '-infinity'::timestamptz) < now() - interval '6 hours'
      or ((select app.meta_usable(m) from meta_publishing m)
          and exists (select 1 from social_drafts x where x.status = 'approved' and x.slot_date <= app.today() and x.publish_attempts < 3
                        and coalesce(x.updated_at, x.created_at) < now() - interval '5 minutes'))
$$;
alter function app.server_jobs_due() rename to server_jobs_due_pre0167;
create or replace function app.server_jobs_due() returns jsonb
language plpgsql security definer set search_path = public, app as $$
begin
  return app.server_jobs_due_pre0167() || jsonb_build_object('ads', app.ads_job_due());
end $$;
select pg_temp.copy_grants('app.server_jobs_due()'::regprocedure, 'app.server_jobs_due_pre0167()'::regprocedure);

-- The job begins: every car with a live ad is checked against its rates, and the job gets the fleet's facts (for the
-- week's drafts), whether publishing is on, and the approved posts that are due (with the token, for the server only).
create or replace function public.server_ads_job() returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  m meta_publishing;
  v uuid;
  n integer := 0;
  v_usable boolean;
begin
  for v in select distinct vehicle_id from ad_postings where status = 'live' loop
    n := n + app.ads_check_vehicle(v);
  end loop;
  update ads_job_state set last_run_at = now(), last_result = jsonb_build_object('ads_to_update', n);
  select * into m from meta_publishing;
  v_usable := app.meta_usable(m);
  return jsonb_build_object('ads_to_update', n, 'drafts_enabled', (app.settings()).ads_social_drafts_enabled, 'facts', app.ads_facts(),
    'meta', jsonb_build_object('usable', v_usable, 'page_id', m.page_id, 'ig_user_id', m.ig_user_id, 'graph_version', m.graph_version,
                               'token', case when v_usable then app.crm_secret_get(m.token_ref) end),
    'due', case when v_usable then (select coalesce(jsonb_agg(app.social_draft_row(x) order by x.slot_date, x.created_at), '[]'::jsonb) from social_drafts x
                                     where x.status = 'approved' and x.slot_date <= app.today() and x.publish_attempts < 3) else '[]'::jsonb end);
end $$;

create or replace function public.server_social_drafts_put(p jsonb) returns integer
language sql security definer set search_path = public, app as $$ select app.social_drafts_store(p, null, 'auto') $$;

-- What the publishing job did with one channel of a draft. p: {id, channel, ok, post_id, url, error}
create or replace function public.server_social_published(p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  x social_drafts;
begin
  if coalesce((p ->> 'ok')::boolean, false) then
    x := app.social_mark_posted((p ->> 'id')::uuid, p ->> 'channel', nullif(p ->> 'url', ''), nullif(p ->> 'post_id', ''), 'api', null);
    update meta_publishing set last_ok_at = now(), last_error = null;
  else
    update social_drafts set publish_error = left(coalesce(p ->> 'error', 'Meta refused the post'), 500), publish_attempts = publish_attempts + 1
     where id = (p ->> 'id')::uuid returning * into x;
    update meta_publishing set last_error = left(coalesce(p ->> 'error', 'Meta refused the post'), 500);
  end if;
  return jsonb_build_object('status', x.status);
end $$;

-- ================================================================ 8. owner recruitment (CASL)
do $$
declare
  d text;
  v text[];
begin
  select pg_get_constraintdef(oid) into d from pg_constraint where conrelid = 'leads'::regclass and conname = 'leads_kind_check';
  v := array(select distinct m[1] from regexp_matches(coalesce(d, ''), '''([a-z_]+)''', 'g') m);
  if cardinality(v) = 0 then raise exception 'leads_kind_check: cannot read the allowed kinds from %', d; end if;
  if not 'owner_recruit' = any (v) then v := v || 'owner_recruit'::text; end if;
  execute 'alter table leads drop constraint if exists leads_kind_check';
  execute format('alter table leads add constraint leads_kind_check check (kind = any (array[%s]))', (select string_agg(quote_literal(x), ', ' order by x) from unnest(v) x));
end $$;

alter table leads
  add column if not exists listing_url text check (listing_url is null or listing_url ~ '^https?://[^[:space:]]+$'),
  add column if not exists listing_site text check (listing_site is null or listing_site in ('kijiji', 'fb_marketplace', 'autotrader', 'craigslist', 'turo', 'other')),
  add column if not exists contact_kind text check (contact_kind is null or contact_kind in ('private_seller', 'dealer', 'rental_business', 'other_business')),
  add column if not exists business_name text,
  add column if not exists vehicle_text text,
  add column if not exists do_not_contact_at timestamptz;
comment on column leads.contact_kind is 'Owner recruitment (0167): a private seller (no electronic message without express consent: phone first), a dealer, a rental business or another business (a published business address with no "no solicitation" note implies consent for a message about their business).';
comment on column leads.listing_url is 'Owner recruitment (0167): the classified ad the lead came from (typed by staff; nothing is collected from the site).';

create table if not exists recruit_consents (
  id             uuid primary key default gen_random_uuid(),
  lead_id        uuid not null references leads (id) on delete cascade,
  channel        text not null check (channel in ('email', 'text', 'any')),
  basis          text not null check (basis in ('express', 'implied_inquiry', 'implied_business', 'implied_published', 'referral', 'withdrawn', 'do_not_contact')),
  method         text check (method in ('oral', 'written', 'form', 'reply', 'published', 'referral', 'unsubscribe_link', 'stop_reply', 'staff')),
  source         text not null,
  evidence       text,
  referrer_name  text,
  obtained_on    date not null,
  expires_on     date,
  recorded_by    uuid references users (id) on delete set null,
  created_at     timestamptz not null default now()
);
create index if not exists recruit_consents_lead_idx on recruit_consents (lead_id, created_at);
comment on table recruit_consents is 'Owner recruitment (0167): the consent log under the anti-spam law. Each row is a consent (express; implied by an inquiry, 6 months; implied by a business relationship, 2 years; implied by a published business address; one message after a referral) or a withdrawal (unsubscribe, STOP, do not contact), with how and when it was obtained and its proof. Never edited: a change is a new row.';

create or replace function app.recruit_consents_frozen() returns trigger
language plpgsql as $$
begin
  raise exception 'The consent log is never edited: add a new entry (a withdrawal or a new consent)' using errcode = '42501';
end $$;
create trigger recruit_consents_frozen before update on recruit_consents for each row execute function app.recruit_consents_frozen();

create table if not exists recruit_calls (
  id          uuid primary key default gen_random_uuid(),
  lead_id     uuid not null references leads (id) on delete cascade,
  outcome     text not null check (outcome in ('yes_email', 'yes_text', 'yes_both', 'no', 'no_answer', 'call_back')),
  note        text,
  called_by   uuid references users (id) on delete set null,
  called_at   timestamptz not null default now()
);
create index if not exists recruit_calls_lead_idx on recruit_calls (lead_id, called_at);

create table if not exists recruit_messages (
  id                uuid primary key default gen_random_uuid(),
  lead_id           uuid not null references leads (id) on delete cascade,
  channel           text not null check (channel in ('email', 'text')),
  template          text not null,
  subject           text,
  body              text not null,
  to_address        text not null,
  consent_id        uuid references recruit_consents (id) on delete set null,
  basis             text not null,
  outbox_id         uuid references notification_outbox (id) on delete set null,
  phone_outbox_id   uuid references phone_outbox (id) on delete set null,
  sent_by           uuid references users (id) on delete set null,
  created_at        timestamptz not null default now()
);
create index if not exists recruit_messages_lead_idx on recruit_messages (lead_id, created_at);
comment on table recruit_messages is 'Owner recruitment (0167): each email or text sent to a recruitment lead, the consent it relied on and the outbox row that carries it.';

-- Whether a message may go to a lead on a channel, and on what basis. {allowed, basis, consent_id, expires_on, reason}
create or replace function app.recruit_consent_state(p_lead uuid, p_channel text) returns jsonb
language plpgsql stable security definer set search_path = public, app as $$
declare
  l leads;
  v_addr text;
  v_w timestamptz;
  c recruit_consents;
  v_expired date;
  no jsonb := jsonb_build_object('allowed', false);
begin
  select * into l from leads where id = p_lead;
  if l.id is null or l.kind <> 'owner_recruit' then return no || jsonb_build_object('reason', 'Not a recruitment lead'); end if;
  v_addr := case p_channel when 'email' then nullif(lower(btrim(coalesce(l.email, ''))), '') when 'text' then app.phone_e164(l.phone) end;
  if v_addr is null then return no || jsonb_build_object('reason', case p_channel when 'email' then 'No email address' else 'No mobile number' end); end if;
  if l.do_not_contact_at is not null then return no || jsonb_build_object('reason', 'Do not contact (since ' || to_char(l.do_not_contact_at at time zone 'America/Toronto', 'FMMon FMDD, YYYY') || ')'); end if;
  if p_channel = 'email' and app.email_suppressed(v_addr, true) then return no || jsonb_build_object('reason', 'They unsubscribed'); end if;
  if p_channel = 'text' and exists (select 1 from phone_threads t where t.number = v_addr and t.opted_out_at is not null) then return no || jsonb_build_object('reason', 'They replied STOP'); end if;
  select max(created_at) into v_w from recruit_consents where lead_id = p_lead and basis in ('withdrawn', 'do_not_contact') and channel in (p_channel, 'any');
  select * into c from recruit_consents x
   where x.lead_id = p_lead and x.channel in (p_channel, 'any') and x.basis in ('express', 'implied_inquiry', 'implied_business', 'implied_published', 'referral')
     and x.created_at > coalesce(v_w, '-infinity'::timestamptz) and (x.expires_on is null or x.expires_on >= app.today())
   order by (x.basis = 'express') desc, x.created_at desc limit 1;
  if c.id is null then
    select max(expires_on) into v_expired from recruit_consents x where x.lead_id = p_lead and x.channel in (p_channel, 'any') and x.expires_on < app.today()
       and x.created_at > coalesce(v_w, '-infinity'::timestamptz);
    return no || jsonb_build_object('reason', case when v_w is not null then 'They withdrew consent'
      when v_expired is not null then 'Implied consent ended on ' || to_char(v_expired, 'FMMon FMDD, YYYY')
      when l.contact_kind = 'private_seller' or l.contact_kind is null then 'No consent yet: phone them and record their yes first'
      else 'No consent recorded' end);
  end if;
  if c.basis = 'implied_published' and coalesce(l.contact_kind, 'private_seller') = 'private_seller' then
    return no || jsonb_build_object('reason', 'A private seller''s ad does not imply consent');
  end if;
  if c.basis = 'referral' and exists (select 1 from recruit_messages m where m.consent_id = c.id) then
    return no || jsonb_build_object('reason', 'A referral allows one message, and it was sent');
  end if;
  return jsonb_build_object('allowed', true, 'basis', c.basis, 'consent_id', c.id, 'expires_on', c.expires_on, 'referrer_name', c.referrer_name);
end $$;

create or replace function app.recruit_basis_words(p text) returns text
language sql immutable as $$
  select case p when 'express' then 'Express consent' when 'implied_inquiry' then 'Implied: they asked us (6 months)'
    when 'implied_business' then 'Implied: business relationship (2 years)' when 'implied_published' then 'Implied: published business address'
    when 'referral' then 'Referral (one message)' when 'withdrawn' then 'Withdrawn' when 'do_not_contact' then 'Do not contact' else p end
$$;

create or replace function app.recruit_lead_row(l leads) returns jsonb
language sql stable security definer set search_path = public, app as $$
  select jsonb_build_object('id', l.id, 'name', l.name, 'business_name', l.business_name, 'email', l.email, 'phone', l.phone, 'listing_url', l.listing_url,
    'listing_site', l.listing_site, 'contact_kind', l.contact_kind, 'vehicle_text', l.vehicle_text, 'status', l.status, 'message', l.message, 'created_at', l.created_at,
    'do_not_contact_at', l.do_not_contact_at, 'owner_id', l.owner_id,
    'email_state', app.recruit_consent_state(l.id, 'email'), 'text_state', app.recruit_consent_state(l.id, 'text'),
    'last_message_at', (select max(created_at) from recruit_messages m where m.lead_id = l.id),
    'last_call', (select jsonb_build_object('outcome', c.outcome, 'at', c.called_at) from recruit_calls c where c.lead_id = l.id order by c.called_at desc limit 1),
    'messages', (select count(*) from recruit_messages m where m.lead_id = l.id))
$$;

create or replace function app.recruit_leads_read(p_by uuid, p jsonb) returns jsonb
language plpgsql stable security definer set search_path = public, app as $$
declare
  v_status text := nullif(p ->> 'status', '');
  v_q text := nullif(lower(btrim(coalesce(p ->> 'q', ''))), '');
begin
  perform app.assert_admin(p_by);
  return jsonb_build_object('enabled', (app.settings()).recruit_outreach_enabled,
    'rows', (select coalesce(jsonb_agg(app.recruit_lead_row(l) order by l.created_at desc), '[]'::jsonb) from leads l
      where l.kind = 'owner_recruit' and (v_status is null or (v_status = 'open' and l.status in ('new', 'contacted', 'qualified') and l.do_not_contact_at is null) or l.status = v_status
                                          or (v_status = 'do_not_contact' and l.do_not_contact_at is not null))
        and (v_q is null or strpos(lower(concat_ws(' ', l.name, l.business_name, l.email, l.phone, l.vehicle_text, l.listing_url)), v_q) > 0)),
    'counts', (select jsonb_build_object('all', count(*), 'open', count(*) filter (where status in ('new', 'contacted', 'qualified') and do_not_contact_at is null),
                 'do_not_contact', count(*) filter (where do_not_contact_at is not null)) from leads where kind = 'owner_recruit'));
end $$;

create or replace function app.recruit_lead_read(p_by uuid, p jsonb) returns jsonb
language plpgsql stable security definer set search_path = public, app as $$
declare
  l leads;
begin
  perform app.assert_admin(p_by);
  select * into l from leads where id = nullif(p ->> 'id', '')::uuid and kind = 'owner_recruit';
  if l.id is null then return null; end if;
  return jsonb_build_object('lead', app.recruit_lead_row(l), 'today', app.today(), 'enabled', (app.settings()).recruit_outreach_enabled,
    'sender', (select nullif(split_part(btrim(coalesce(full_name, '')), ' ', 1), '') from users where id = p_by),
    'company', jsonb_build_object('address', coalesce((select nullif(ss.mailing_address, '') from site_settings ss limit 1), (app.settings()).company_address),
                                  'email', coalesce((select public_email from site_settings limit 1), (app.settings()).company_email),
                                  'phone', coalesce((select phone from site_settings limit 1), (app.settings()).company_phone), 'site_url', (app.settings()).notify_base_url),
    'consents', (select coalesce(jsonb_agg(jsonb_build_object('id', c.id, 'channel', c.channel, 'basis', c.basis, 'basis_words', app.recruit_basis_words(c.basis), 'method', c.method,
                   'source', c.source, 'evidence', c.evidence, 'referrer_name', c.referrer_name, 'obtained_on', c.obtained_on, 'expires_on', c.expires_on,
                   'recorded_by', (select full_name from users where id = c.recorded_by), 'created_at', c.created_at) order by c.created_at desc), '[]'::jsonb)
                   from recruit_consents c where c.lead_id = l.id),
    'calls', (select coalesce(jsonb_agg(jsonb_build_object('outcome', c.outcome, 'note', c.note, 'at', c.called_at, 'by', (select full_name from users where id = c.called_by))
                   order by c.called_at desc), '[]'::jsonb) from recruit_calls c where c.lead_id = l.id),
    'messages', (select coalesce(jsonb_agg(jsonb_build_object('id', m.id, 'channel', m.channel, 'template', m.template, 'subject', m.subject, 'body', m.body, 'to', m.to_address,
                   'basis', m.basis, 'at', m.created_at, 'by', (select full_name from users where id = m.sent_by),
                   'status', coalesce((select o.status from notification_outbox o where o.id = m.outbox_id), (select o.status from phone_outbox o where o.id = m.phone_outbox_id)))
                   order by m.created_at desc), '[]'::jsonb) from recruit_messages m where m.lead_id = l.id));
end $$;

-- Add or change a recruitment lead. p: {id?, listing_url, listing_site, name, business_name, contact_kind, email, phone, vehicle_text, note}
create or replace function app.recruit_lead_save(p_by uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  l leads;
  v_url text := nullif(btrim(coalesce(p ->> 'listing_url', '')), '');
  v_email text := nullif(lower(btrim(coalesce(p ->> 'email', ''))), '');
  v_phone text := nullif(btrim(coalesce(p ->> 'phone', '')), '');
  v_kind text := coalesce(nullif(p ->> 'contact_kind', ''), 'private_seller');
  v_site text := nullif(p ->> 'listing_site', '');
begin
  perform app.assert_admin(p_by);
  if v_url is not null and v_url !~ '^https?://[^[:space:]]+$' then raise exception 'Paste the ad''s address as it shows in the browser (it starts with https://)' using errcode = '22023'; end if;
  if v_email is not null and v_email !~ '^[^@\s]+@[^@\s]+\.[^@\s]+$' then raise exception 'Enter a full email address, for example name@example.com' using errcode = '22023'; end if;
  if v_email is null and v_phone is null then raise exception 'Give a phone number or an email address' using errcode = '22023'; end if;
  if v_phone is not null and app.phone_e164(v_phone) is null then raise exception 'Enter the phone number with its area code' using errcode = '22023'; end if;
  if v_site is null and v_url is not null then
    v_site := case when v_url ~* 'kijiji\.' then 'kijiji' when v_url ~* 'facebook\.com/marketplace|fb\.com' then 'fb_marketplace' when v_url ~* 'autotrader\.' then 'autotrader'
                   when v_url ~* 'craigslist\.' then 'craigslist' when v_url ~* 'turo\.' then 'turo' else 'other' end;
  end if;
  if nullif(p ->> 'id', '') is null then
    insert into leads (kind, name, email, phone, message, source, source_url, listing_url, listing_site, contact_kind, business_name, vehicle_text, assigned_to)
    values ('owner_recruit', nullif(btrim(coalesce(p ->> 'name', '')), ''), v_email, v_phone, nullif(btrim(coalesce(p ->> 'note', '')), ''), 'classified', v_url, v_url, v_site, v_kind,
            nullif(btrim(coalesce(p ->> 'business_name', '')), ''), nullif(btrim(coalesce(p ->> 'vehicle_text', '')), ''), p_by)
    returning * into l;
  else
    update leads set name = coalesce(nullif(btrim(coalesce(p ->> 'name', '')), ''), name), email = case when p ? 'email' then v_email else email end,
           phone = case when p ? 'phone' then v_phone else phone end, listing_url = coalesce(v_url, listing_url), listing_site = coalesce(v_site, listing_site),
           contact_kind = v_kind, business_name = case when p ? 'business_name' then nullif(btrim(coalesce(p ->> 'business_name', '')), '') else business_name end,
           vehicle_text = case when p ? 'vehicle_text' then nullif(btrim(coalesce(p ->> 'vehicle_text', '')), '') else vehicle_text end,
           message = case when p ? 'note' then nullif(btrim(coalesce(p ->> 'note', '')), '') else message end,
           status = coalesce(nullif(p ->> 'status', ''), status)
     where id = (p ->> 'id')::uuid and kind = 'owner_recruit' returning * into l;
    if l.id is null then raise exception 'Lead not found' using errcode = 'P0002'; end if;
  end if;
  return app.recruit_lead_row(l);
end $$;

-- Record a consent (or a withdrawal). p: {lead, channel, basis, method, source, evidence, referrer_name, obtained_on}
create or replace function app.recruit_consent_add(p_by uuid, p jsonb, p_check_admin boolean default true) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  l leads;
  v_basis text := p ->> 'basis';
  v_channel text := coalesce(nullif(p ->> 'channel', ''), 'any');
  v_on date := coalesce(nullif(p ->> 'obtained_on', '')::date, app.today());
  v_source text := nullif(btrim(coalesce(p ->> 'source', '')), '');
  v_evidence text := nullif(btrim(coalesce(p ->> 'evidence', '')), '');
  v_method text := nullif(p ->> 'method', '');
  v_id uuid;
begin
  if p_check_admin then perform app.assert_admin(p_by); end if;
  select * into l from leads where id = nullif(p ->> 'lead', '')::uuid and kind = 'owner_recruit' for update;
  if l.id is null then raise exception 'Lead not found' using errcode = 'P0002'; end if;
  if v_basis is null or v_basis not in ('express', 'implied_inquiry', 'implied_business', 'implied_published', 'referral', 'withdrawn', 'do_not_contact') then
    raise exception 'Choose the kind of consent' using errcode = '22023'; end if;
  if v_channel not in ('email', 'text', 'any') then raise exception 'Choose email, text or both' using errcode = '22023'; end if;
  if v_on > app.today() then raise exception 'The date cannot be in the future' using errcode = '22023'; end if;
  if v_source is null then raise exception 'Say how and where you got it (for example "phone call to the number in the Kijiji ad")' using errcode = '22023'; end if;
  if v_basis = 'express' and v_evidence is null then raise exception 'Write the proof of their yes: their words and the time, or the recording or message it is in' using errcode = '22023'; end if;
  if v_basis = 'implied_published' and coalesce(l.contact_kind, 'private_seller') = 'private_seller' then
    raise exception 'A private seller''s ad does not imply consent: only a business that published its address (with no "no solicitation" note) does' using errcode = '22023'; end if;
  if v_basis = 'implied_published' and v_evidence is null then raise exception 'Paste the page where the business published the address' using errcode = '22023'; end if;
  if v_basis = 'referral' and nullif(btrim(coalesce(p ->> 'referrer_name', '')), '') is null then raise exception 'Name the person who referred them (the message names them)' using errcode = '22023'; end if;
  insert into recruit_consents (lead_id, channel, basis, method, source, evidence, referrer_name, obtained_on, expires_on, recorded_by)
  values (l.id, v_channel, v_basis, v_method, v_source, v_evidence, nullif(btrim(coalesce(p ->> 'referrer_name', '')), ''), v_on,
          case v_basis when 'implied_inquiry' then (v_on + interval '6 months')::date when 'implied_business' then (v_on + interval '2 years')::date end, p_by)
  returning id into v_id;
  if v_basis = 'do_not_contact' then
    update leads set do_not_contact_at = coalesce(do_not_contact_at, now()), status = 'closed', closed_reason = coalesce(closed_reason, 'Do not contact') where id = l.id;
  end if;
  return jsonb_build_object('id', v_id, 'email_state', app.recruit_consent_state(l.id, 'email'), 'text_state', app.recruit_consent_state(l.id, 'text'));
end $$;

create or replace function app.recruit_do_not_contact(p_by uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
begin
  return app.recruit_consent_add(p_by, jsonb_build_object('lead', p ->> 'lead', 'channel', 'any', 'basis', 'do_not_contact', 'method', 'staff',
    'source', coalesce(nullif(btrim(coalesce(p ->> 'reason', '')), ''), 'Asked not to be contacted')));
end $$;

-- A phone call (the anti-spam law does not cover a live voice call). p: {lead, outcome, note}. A yes is express consent,
-- recorded with the note as its proof; a no is "do not contact".
create or replace function app.recruit_call_log(p_by uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  l leads;
  v_out text := p ->> 'outcome';
  v_note text := nullif(btrim(coalesce(p ->> 'note', '')), '');
  v_who text := (select full_name from users where id = p_by);
begin
  perform app.assert_admin(p_by);
  select * into l from leads where id = nullif(p ->> 'lead', '')::uuid and kind = 'owner_recruit';
  if l.id is null then raise exception 'Lead not found' using errcode = 'P0002'; end if;
  if v_out is null or v_out not in ('yes_email', 'yes_text', 'yes_both', 'no', 'no_answer', 'call_back') then raise exception 'Choose how the call went' using errcode = '22023'; end if;
  if v_out like 'yes%' and v_note is null then raise exception 'Write what they agreed to, in their words (for example "Yes, text me the details")' using errcode = '22023'; end if;
  insert into recruit_calls (lead_id, outcome, note, called_by) values (l.id, v_out, v_note, p_by);
  if v_out like 'yes%' then
    perform app.recruit_consent_add(p_by, jsonb_build_object('lead', l.id, 'channel', case v_out when 'yes_email' then 'email' when 'yes_text' then 'text' else 'any' end,
      'basis', 'express', 'method', 'oral', 'source', 'Phone call by ' || coalesce(v_who, 'staff') || ' on ' || to_char(now() at time zone 'America/Toronto', 'FMMon FMDD, YYYY "at" FMHH12:MI am'),
      'evidence', v_note), false);
    update leads set status = case when status = 'new' then 'contacted' else status end where id = l.id;
  elsif v_out = 'no' then
    perform app.recruit_consent_add(p_by, jsonb_build_object('lead', l.id, 'channel', 'any', 'basis', 'do_not_contact', 'method', 'oral',
      'source', 'Said no on a phone call' || coalesce(': ' || v_note, '')), false);
  else
    update leads set status = case when status = 'new' then 'contacted' else status end where id = l.id;
  end if;
  return app.recruit_lead_row((select x from leads x where x.id = l.id));
end $$;

-- Send an email or a text to a recruitment lead: only when the consent log allows it on that channel. The email carries
-- CarmaCars' name and mailing address and the one-click unsubscribe; the text names CarmaCars and ends "Reply STOP to opt out."
-- p: {lead, channel: email | text, template, subject, body}
create or replace function app.recruit_send(p_by uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  s program_settings := app.settings();
  l leads;
  v_channel text := p ->> 'channel';
  v_state jsonb;
  v_body text := btrim(coalesce(p ->> 'body', ''));
  v_subject text := nullif(btrim(coalesce(p ->> 'subject', '')), '');
  v_problem text;
  v_id uuid := gen_random_uuid();
  v_token uuid;
  v_out uuid;
  c notification_catalogue;
  o phone_outbox;
  v_to text;
begin
  perform app.assert_admin(p_by);
  if not s.recruit_outreach_enabled then raise exception 'Recruitment messages are off in Program settings' using errcode = '22023'; end if;
  select * into l from leads where id = nullif(p ->> 'lead', '')::uuid and kind = 'owner_recruit' for update;
  if l.id is null then raise exception 'Lead not found' using errcode = 'P0002'; end if;
  if v_channel not in ('email', 'text') then raise exception 'Choose email or text' using errcode = '22023'; end if;
  v_state := app.recruit_consent_state(l.id, v_channel);
  if not (v_state ->> 'allowed')::boolean then raise exception 'Not sent: %', v_state ->> 'reason' using errcode = '22023'; end if;
  v_problem := app.ads_text_problem(v_body);
  if v_problem is not null then raise exception '%', v_problem using errcode = '22023'; end if;
  if v_channel = 'email' then
    if v_subject is null then raise exception 'Write a subject' using errcode = '22023'; end if;
    if length(v_body) > 4000 then raise exception 'Keep the email under 4,000 characters' using errcode = '22023'; end if;
    select * into c from notification_catalogue where code = 'owner_recruit_outreach';
    v_to := lower(btrim(l.email));
    v_token := gen_random_uuid();
    insert into notification_outbox (code, category, priority, audience, to_address, to_name, entity, entity_id, payload, dedupe_key, status, send_after, unsubscribe_token)
    values ('owner_recruit_outreach', 'marketing', coalesce(c.priority, 4), 'owner', v_to, l.name, 'lead', l.id,
            jsonb_build_object('first_name', coalesce(nullif(split_part(btrim(coalesce(l.name, '')), ' ', 1), ''), 'there'), 'subject_line', v_subject, 'message_body', v_body,
                               'sender_name', coalesce((select split_part(full_name, ' ', 1) from users where id = p_by), 'CarmaCars'),
                               'consent_reason', case v_state ->> 'basis' when 'express' then 'you agreed to hear from CarmaCars about the owner program'
                                 when 'implied_inquiry' then 'you asked CarmaCars about the owner program' when 'implied_business' then 'you do business with CarmaCars'
                                 when 'implied_published' then 'your business published this address' when 'referral' then coalesce(v_state ->> 'referrer_name', 'someone you know') || ' suggested we write to you'
                                 else 'you agreed to hear from CarmaCars' end,
                               'unsubscribe_url', s.notify_base_url || s.notify_unsubscribe_path || '?token=' || v_token::text),
            'recruit:' || v_id, 'queued', now(), v_token)
    returning id into v_out;
  else
    if position('carmacars' in lower(v_body)) = 0 then raise exception 'Name CarmaCars in the text' using errcode = '22023'; end if;
    if v_body !~* 'reply stop' then v_body := v_body || ' Reply STOP to opt out.'; end if;
    if length(v_body) > 480 then raise exception 'Keep the text under 480 characters (three text messages)' using errcode = '22023'; end if;
    v_to := app.phone_e164(l.phone);
    o := app.phone_outbox_put(v_to, v_body, 'staff', null, null, 'recruit', null, 'recruit:' || v_id, app.sms_quiet_end(now()), 'queued', p_by);
    if o.status = 'skipped' then raise exception 'Not sent: %', coalesce(o.status_reason, 'the text could not be queued') using errcode = '22023'; end if;
    update phone_threads set lead_id = coalesce(lead_id, l.id), match_kind = case when match_kind = 'unknown' then 'lead' else match_kind end where id = o.thread_id;
  end if;
  insert into recruit_messages (id, lead_id, channel, template, subject, body, to_address, consent_id, basis, outbox_id, phone_outbox_id, sent_by)
  values (v_id, l.id, v_channel, coalesce(nullif(p ->> 'template', ''), 'custom'), v_subject, v_body, v_to, nullif(v_state ->> 'consent_id', '')::uuid, v_state ->> 'basis',
          v_out, o.id, p_by);
  update leads set status = case when status = 'new' then 'contacted' else status end where id = l.id;
  return jsonb_build_object('id', v_id, 'channel', v_channel, 'basis', v_state ->> 'basis');
end $$;

-- An unsubscribe (the link, a complaint or staff) and a STOP reply are written into the consent log at once.
create or replace function app.recruit_suppression_logged() returns trigger
language plpgsql security definer set search_path = public, app as $$
begin
  if new.lifted_at is not null then return null; end if;
  insert into recruit_consents (lead_id, channel, basis, method, source, obtained_on)
  select l.id, 'email', 'withdrawn', case when new.reason = 'unsubscribe' then 'unsubscribe_link' else 'staff' end,
         'Email address suppressed (' || new.reason || coalesce(': ' || new.detail, '') || ')', app.today()
    from leads l where l.kind = 'owner_recruit' and lower(btrim(l.email)) = new.email;
  return null;
end $$;
create trigger email_suppressions_recruit after insert on email_suppressions for each row execute function app.recruit_suppression_logged();

create or replace function app.recruit_stop_logged() returns trigger
language plpgsql security definer set search_path = public, app as $$
begin
  if new.action <> 'stop' then return null; end if;
  insert into recruit_consents (lead_id, channel, basis, method, source, obtained_on)
  select l.id, 'text', 'withdrawn', 'stop_reply', 'Replied STOP to a text' || case when new.source is not null and new.source <> 'stop' then ' (' || new.source || ')' else '' end, app.today()
    from leads l where l.kind = 'owner_recruit' and app.phone_e164(l.phone) = new.number;
  return null;
end $$;
create trigger sms_opt_out_log_recruit after insert on sms_opt_out_log for each row execute function app.recruit_stop_logged();

-- ================================================================ 9. the door
alter function app.door(uuid, text, text, text, jsonb) rename to door_pre0167;
create or replace function app.door(p_user uuid, p_aal text, p_call text, p_name text, p jsonb default '{}'::jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  q jsonb := coalesce(p, '{}'::jsonb);
begin
  if p_call = 'admin_read' and p_name in ('ads_listings', 'ads_postings', 'ads_report', 'booking_marketing', 'social_drafts', 'meta_publishing', 'recruit_leads', 'recruit_lead') then
    perform app.door_begin(p_user, p_aal);
    return case p_name
      when 'ads_listings' then app.ads_listings_read(p_user, q)
      when 'ads_postings' then app.ads_postings_read(p_user, q)
      when 'ads_report' then app.ads_report(p_user, q)
      when 'booking_marketing' then app.booking_marketing(p_user, q)
      when 'social_drafts' then app.social_drafts_read(p_user, q)
      when 'meta_publishing' then app.meta_publishing_read(p_user, q)
      when 'recruit_leads' then app.recruit_leads_read(p_user, q)
      else app.recruit_lead_read(p_user, q) end;
  end if;
  if p_call = 'admin_do' and p_name in ('ad_posting_save', 'ad_posting_remove', 'booking_marketing_source', 'social_drafts_put', 'social_draft_save', 'social_draft_decide',
                                        'social_draft_posted', 'meta_publishing_save', 'recruit_lead_save', 'recruit_consent_add', 'recruit_call_log', 'recruit_send', 'recruit_do_not_contact') then
    perform app.door_begin(p_user, p_aal);
    return case p_name
      when 'ad_posting_save' then app.ad_posting_save(p_user, q)
      when 'ad_posting_remove' then app.ad_posting_remove(p_user, q)
      when 'booking_marketing_source' then app.booking_marketing_source(p_user, q)
      when 'social_drafts_put' then app.social_drafts_put(p_user, q)
      when 'social_draft_save' then app.social_draft_save(p_user, q)
      when 'social_draft_decide' then app.social_draft_decide(p_user, q)
      when 'social_draft_posted' then app.social_draft_posted(p_user, q)
      when 'meta_publishing_save' then app.meta_publishing_save(p_user, q)
      when 'recruit_lead_save' then app.recruit_lead_save(p_user, q)
      when 'recruit_consent_add' then app.recruit_consent_add(p_user, q)
      when 'recruit_call_log' then app.recruit_call_log(p_user, q)
      when 'recruit_send' then app.recruit_send(p_user, q)
      else app.recruit_do_not_contact(p_user, q) end;
  end if;
  return app.door_pre0167(p_user, p_aal, p_call, p_name, p);
end $$;
select pg_temp.copy_grants('app.door(uuid, text, text, text, jsonb)'::regprocedure, 'app.door_pre0167(uuid, text, text, text, jsonb)'::regprocedure);

-- ================================================================ 10. the bookings of the past (captured once, from the visits still kept)
do $$
declare x record;
begin
  for x in select b.id from bookings b where b.booking_type <> 'owner' and coalesce(b.requested_at, b.created_at) > now() - interval '120 days' loop
    perform app.booking_attribution_capture(x.id);
  end loop;
end $$;

-- ================================================================ privileges
do $$
declare
  f record;
begin
  for f in
    select p.oid::regprocedure as sig from pg_proc p join pg_namespace n on n.oid = p.pronamespace
     where (n.nspname = 'app' and p.proname = any (array['door_pre0167', 'server_jobs_due_pre0167', 'ad_snapshot', 'ads_check_vehicle', 'ads_check_trigger', 'ads_task_done',
              'booking_attribution_capture', 'booking_attribution_trigger', 'ads_report', 'booking_marketing', 'booking_marketing_source', 'ads_facts', 'ad_posting_row',
              'ads_listings_read', 'ads_postings_read', 'ad_posting_save', 'ad_posting_remove', 'social_draft_row', 'social_drafts_read', 'social_drafts_store', 'social_drafts_put',
              'social_draft_save', 'social_draft_decide', 'social_mark_posted', 'social_draft_posted', 'meta_publishing_read', 'meta_publishing_save', 'ads_job_due',
              'recruit_consent_state', 'recruit_lead_row', 'recruit_leads_read', 'recruit_lead_read', 'recruit_lead_save', 'recruit_consent_add', 'recruit_do_not_contact',
              'recruit_call_log', 'recruit_send', 'recruit_suppression_logged', 'recruit_stop_logged']))
        or (n.nspname = 'public' and p.proname = any (array['server_ads_job', 'server_social_drafts_put', 'server_social_published']))
  loop
    execute format('revoke all on function %s from public, anon, authenticated', f.sig);
    execute format('grant execute on function %s to service_role', f.sig);
  end loop;
end $$;

do $$
declare t text;
begin
  foreach t in array array['ad_postings', 'booking_attribution', 'social_drafts', 'meta_publishing', 'ads_job_state', 'recruit_consents', 'recruit_calls', 'recruit_messages'] loop
    execute format('alter table %I enable row level security', t);
    execute format('revoke all on %I from anon, authenticated', t);
    execute format('create policy admin_all on %I for all to authenticated using (app.is_admin()) with check (app.is_admin())', t);
    execute format('grant all on %I to service_role', t);
  end loop;
  -- row audit for what staff change (not the job's state, nor the attribution the system writes)
  foreach t in array array['ad_postings', 'social_drafts', 'meta_publishing', 'recruit_consents', 'recruit_calls', 'recruit_messages'] loop
    execute format('create trigger %I after insert or update or delete on %I for each row execute function app.audit_row()', 'audit_' || t, t);
  end loop;
end $$;

-- the owner program page the recruitment email's button opens (emails/src/links.mjs, list_your_car)
insert into notification_link_paths (key, path) values ('list_your_car', '/list-your-car') on conflict (key) do update set path = excluded.path;
-- CATALOGUE 0167 START (generated by supabase/seed/0167_gen_catalogue.mjs; do not edit by hand)
insert into notification_catalogue (code, audience, also_sent_to, category, is_digest, digest_slot, from_address, reply_to,
    subject, preheader, timing, trigger_text, replaces_template, link_path, variables, template_html, template_text) values
  ('owner_recruit_outreach', 'owner', '{}'::text[], 'marketing', false, null, 'CarmaCars <owners@carmacars.ca>', 'owners@carmacars.ca', '{{subject_line}}', 'A message from {{sender_name}} at CarmaCars about the owner program.', 'Immediate, when the Admin sends it', 'An Admin sends a message to a prospective owner from Admin > Marketing > Owner recruitment (migration 0167). It is sent only when the consent log allows email for that person: express consent (a yes on a call, a form or a reply), implied consent from their inquiry (6 months) or a business relationship (2 years), a business address published with no "no solicitation" note, or one message after a referral. The message is a template the Admin may edit; the footer names CarmaCars, its mailing address and the reason for the email, and carries the unsubscribe link. One email per send.', null, '/list-your-car', '[{"name":"company_address","type":"string","global":true},{"name":"consent_reason","type":"string"},{"name":"contact_email","type":"string","global":true},{"name":"first_name","type":"string"},{"name":"instagram_url","type":"url","global":true},{"name":"message_body","type":"string"},{"name":"opening_hours","type":"string","global":true},{"name":"reply_time","type":"string","global":true},{"name":"sender_name","type":"string"},{"name":"subject_line","type":"string"},{"name":"support_phone","type":"string","global":true},{"name":"tiktok_url","type":"url","global":true},{"name":"unsubscribe_url","type":"url"}]'::jsonb, 'templates/owner_recruit_outreach.html', 'templates/owner_recruit_outreach.txt')
on conflict (code) do update set
  audience = excluded.audience, also_sent_to = excluded.also_sent_to, category = excluded.category,
  is_digest = excluded.is_digest, digest_slot = excluded.digest_slot, from_address = excluded.from_address,
  reply_to = excluded.reply_to, subject = excluded.subject, preheader = excluded.preheader, timing = excluded.timing,
  trigger_text = excluded.trigger_text, replaces_template = excluded.replaces_template, link_path = excluded.link_path,
  variables = excluded.variables, template_html = excluded.template_html, template_text = excluded.template_text,
  in_catalogue = true, updated_at = now();
select app.notification_catalogue_refresh();
-- CATALOGUE 0167 END
-- the outreach email never becomes a text (a text to a lead is its own message, with its own consent)
update notification_catalogue set no_text = true where code = 'owner_recruit_outreach';
-- the catalogue refresh above recomputes each marketing email's consent rule: the promo reminders keep express consent (0161,
-- as 0165 did), and the recruitment email's own consent is checked against the consent log before it is queued
update notification_catalogue set consent_rule = 'express' where code in ('renter_promo_expiry_3d', 'renter_promo_expiry_1d', 'owner_recruit_outreach');
update notification_catalogue set emitted_by = 'app.recruit_send (0167), only when app.recruit_consent_state allows email' where code = 'owner_recruit_outreach';

-- GUIDES 0167 START (generated by supabase/seed/0167_gen_guides.mjs from docs/guides/content; do not edit by hand)
select app.guide_release_section('admin', 'getting-around-admin', 'chapter', 'start-here', 'Admin opens on To do: the day''s counts at the top, then what needs you now, most urgent first. The menu groups every screen into six groups: Today, Bookings, Cars, People, Money and Settings. The long groups come in labelled parts (for example People: Owners and partners, then Renters, staff and investors). Search finds any booking, car or person, and Ctrl+K jumps to any page.

## To do

Start every shift here. Each line says what to do and why, and its button opens a small pop-up that does it, already filled in. Nothing to remember and no menu to search.

1. Each piece of work is its own line (work of one kind for several cars is one line, such as Add real photos (72 cars); its button opens the list), marked Now, Today or When you can: a car the insurer has not confirmed, a car not on the site, a renter''s documents to check, a visitor waiting in live chat, a booking request, a change a renter asked for, an owner application, an owner invoice waiting for payment, the first and last month an owner paid after their invoices were voided, the terms agreed with an owner still on the standard grid, documents an owner has not signed, an official form to check, a plate to check, a car showing sample photos, and any task of the Admin.
2. Press the line''s button: Mark insured, Set rates and publish, Review documents, Record payment, Record what they paid, Enter the terms, Record paper signature, Checked: use for owners, Open the chat, and so on. A line you do not need has Not needed or These are correct. The pop-up is filled in; check it and confirm. The line disappears once the work is done.
3. Under the lines, the counts with one button each (failed payments, agreements to countersign, tolls, listings, insurance, staff commissions, prices typed by hand, sales claims, Turo emails). A count with nothing waiting moves to the bottom, under "more with nothing waiting".
4. While no assistant holds customer service, sales, finance or fleet (the live verification''s test accounts do not count), their tasks come to To do too, and so do their emails, to rent@carmacars.ca.
5. Beside the list (under it on a phone): today''s pickups (ready or not ready), today''s returns (due or late) and today''s chauffeur bookings, by time.
6. Press **Overview** for the money, fleet and queue figures, the alerts and the team''s sales for the month.
7. The dark band at the top counts the day, each count one tap from its page: requests waiting (with how long the oldest has waited, red past the reply target), pickups and returns today, payments to chase, deposits to settle, staff tasks open and alerts. A count that needs you now is red and says so.

![](/guides/img/admin-01-today-desktop-ea48309c.jpg "desktop; size: 1440 900; address: carmacars.ca/admin; pins: 1 22.6 31.6, 2 90.3 31.7, 3 18.4 90.2, 4 94.4 22.2")

## The menu

The current group is open, with its pages; press another group to open it. On a phone the whole menu sits behind one Menu button that says where you are.

| Group | Pages |
| --- | --- |
| Today | To do, Overview, Staff tasks, Live visitors |
| Bookings | Trips: Requests, Bookings, Calendar, Add a rental, Chauffeur. Customers: Live chat, Renter leads, Reviews. Problems: Damage, Incidents and claims |
| Cars | Vehicles, Listings, Maintenance, Rates for many cars, Calendar sync, Similar cars, Retire or delete |
| Money | Owners: Owner invoices, Owner debits, Owner statements, Payouts. Renters: Payments by day, Payments and refunds, Tolls and tickets. Company: Company statements, Reconciliation, Expenses, Insurer rates, Insurer invoices, Staff commissions, Field pay |
| People | Owners and partners: Applications, Owners, Add a car for an owner, Partners, Owner forms, Paid and signed. Renters, staff and investors: Renters, Staff, Investors, Portals and view as |
| Settings | All settings. Website: Site, Vehicle pages, Sample photos, Add-ons, Discount games, Guides. Rules: Program, Forms, Maintenance, Emails. Records: Email log, Audit log |

![On a phone: press Menu (1), then a group (2), then the page (3).](/guides/img/admin-31-menu-phone-667dc2fd.jpg "phone; size: 390 715; pins: 1 10.3 28.7, 2 76.9 42.4, 3 76.9 48.3")

## Search

The search box sits at the top of the menu, on every page.

1. Type a booking number (CC-1042), a car code (CC-7F3A, on every car page and fleet card), a plate, a VIN, or a name or email address.
2. Press **Search** (or Enter). Results come in groups: bookings, cars, owners, partners and renters. Open one to go to its page.
3. To go to a page instead, press Ctrl+K (Cmd+K on a Mac) or **Jump to a page** under the search box, type a few letters (Payouts, Program settings) and press Enter. The first line searches the records for what you typed.

![](/guides/img/admin-32-search-desktop-ca548a70.jpg "desktop; size: 1440 420; address: carmacars.ca/admin/search?q=CC-10057; pins: 1 7.4 45.2, 2 95.0 46.9")

## Keyboard shortcuts

Press g, then a letter. Press / to jump to the search box, and Ctrl+K to jump to any page.

| Keys | Opens | Keys | Opens |
| --- | --- | --- | --- |
| g t | To do | g v | Vehicles |
| g r | Requests | g l | Listings |
| g b | Bookings | g a | Applications |
| g c | Calendar | g o | Owners |
| g k | Staff tasks | g m | Payments and refunds |
| g s | All settings | / | Search |
| Ctrl K | Jump to a page | Esc | Close it |
', 'Getting around Admin', 'To do, the menu, search, keyboard shortcuts and your other portals.',
  'Admin opens on To do: the day''s counts at the top, then what needs you now, most urgent first. The menu groups every screen into seven groups: Today, Bookings, Cars, People, Marketing, Money and Settings. The long groups come in labelled parts (for example People: Owners and partners, then Renters, staff and investors). Search finds any booking, car or person, and Ctrl+K jumps to any page.

## To do

Start every shift here. Each line says what to do and why, and its button opens a small pop-up that does it, already filled in. Nothing to remember and no menu to search.

1. Each piece of work is its own line (work of one kind for several cars is one line, such as Add real photos (72 cars); its button opens the list), marked Now, Today or When you can: a car the insurer has not confirmed, a car not on the site, a renter''s documents to check, a visitor waiting in live chat, a booking request, a change a renter asked for, an owner application, an owner invoice waiting for payment, the first and last month an owner paid after their invoices were voided, the terms agreed with an owner still on the standard grid, documents an owner has not signed, an official form to check, a plate to check, a car showing sample photos, and any task of the Admin.
2. Press the line''s button: Mark insured, Set rates and publish, Review documents, Record payment, Record what they paid, Enter the terms, Record paper signature, Checked: use for owners, Open the chat, and so on. A line you do not need has Not needed or These are correct. The pop-up is filled in; check it and confirm. The line disappears once the work is done.
3. Under the lines, the counts with one button each (failed payments, agreements to countersign, tolls, listings, insurance, staff commissions, prices typed by hand, sales claims, Turo emails). A count with nothing waiting moves to the bottom, under "more with nothing waiting".
4. While no assistant holds customer service, sales, finance or fleet (the live verification''s test accounts do not count), their tasks come to To do too, and so do their emails, to rent@carmacars.ca.
5. Beside the list (under it on a phone): today''s pickups (ready or not ready), today''s returns (due or late) and today''s chauffeur bookings, by time.
6. Press **Overview** for the money, fleet and queue figures, the alerts and the team''s sales for the month.
7. The dark band at the top counts the day, each count one tap from its page: requests waiting (with how long the oldest has waited, red past the reply target), pickups and returns today, payments to chase, deposits to settle, staff tasks open and alerts. A count that needs you now is red and says so.

![](/guides/img/admin-01-today-desktop-ea48309c.jpg "desktop; size: 1440 900; address: carmacars.ca/admin; pins: 1 22.6 31.6, 2 90.3 31.7, 3 18.4 90.2, 4 94.4 22.2")

## The menu

The current group is open, with its pages; press another group to open it. On a phone the whole menu sits behind one Menu button that says where you are.

| Group | Pages |
| --- | --- |
| Today | To do, Overview, Staff tasks, Live visitors |
| Bookings | Trips: Requests, Bookings, Calendar, Add a rental, Chauffeur. Customers: Live chat, Renter leads, Reviews. Problems: Damage, Incidents and claims |
| Cars | Vehicles, Listings, Maintenance, Rates for many cars, Calendar sync, Similar cars, Retire or delete |
| Money | Owners: Owner invoices, Owner debits, Owner statements, Payouts. Renters: Payments by day, Payments and refunds, Tolls and tickets. Company: Company statements, Reconciliation, Expenses, Insurer rates, Insurer invoices, Staff commissions, Field pay |
| People | Owners and partners: Applications, Owners, Add a car for an owner, Partners, Owner forms, Paid and signed. Renters, staff and investors: Renters, Staff, Investors, Portals and view as |
| Marketing | Ads: Listings, Posted ads, Social drafts. Results: Bookings by channel. Owners: Owner recruitment |
| Settings | All settings. Website: Site, Vehicle pages, Sample photos, Add-ons, Discount games, Guides. Rules: Program, Forms, Maintenance, Emails. Records: Email log, Audit log |

![On a phone: press Menu (1), then a group (2), then the page (3).](/guides/img/admin-31-menu-phone-667dc2fd.jpg "phone; size: 390 715; pins: 1 10.3 28.7, 2 76.9 42.4, 3 76.9 48.3")

## Search

The search box sits at the top of the menu, on every page.

1. Type a booking number (CC-1042), a car code (CC-7F3A, on every car page and fleet card), a plate, a VIN, or a name or email address.
2. Press **Search** (or Enter). Results come in groups: bookings, cars, owners, partners and renters. Open one to go to its page.
3. To go to a page instead, press Ctrl+K (Cmd+K on a Mac) or **Jump to a page** under the search box, type a few letters (Payouts, Program settings) and press Enter. The first line searches the records for what you typed.

![](/guides/img/admin-32-search-desktop-ca548a70.jpg "desktop; size: 1440 420; address: carmacars.ca/admin/search?q=CC-10057; pins: 1 7.4 45.2, 2 95.0 46.9")

## Keyboard shortcuts

Press g, then a letter. Press / to jump to the search box, and Ctrl+K to jump to any page.

| Keys | Opens | Keys | Opens |
| --- | --- | --- | --- |
| g t | To do | g v | Vehicles |
| g r | Requests | g l | Listings |
| g b | Bookings | g a | Applications |
| g c | Calendar | g o | Owners |
| g k | Staff tasks | g m | Payments and refunds |
| g s | All settings | / | Search |
| Ctrl K | Jump to a page | Esc | Close it |
',
  '<p class="gd-p">Admin opens on To do: the day&#39;s counts at the top, then what needs you now, most urgent first. The menu groups every screen into seven groups: Today, Bookings, Cars, People, Marketing, Money and Settings. The long groups come in labelled parts (for example People: Owners and partners, then Renters, staff and investors). Search finds any booking, car or person, and Ctrl+K jumps to any page.</p><section class="gd-task" id="getting-around-admin-to-do" data-gd-task><h2 class="gd-h2">To do</h2><p class="gd-p">Start every shift here. Each line says what to do and why, and its button opens a small pop-up that does it, already filled in. Nothing to remember and no menu to search.</p><div class="gd-stepblock gd-stepblock--below"><div class="gd-stepcol"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">Each piece of work is its own line (work of one kind for several cars is one line, such as Add real photos (72 cars); its button opens the list), marked Now, Today or When you can: a car the insurer has not confirmed, a car not on the site, a renter&#39;s documents to check, a visitor waiting in live chat, a booking request, a change a renter asked for, an owner application, an owner invoice waiting for payment, the first and last month an owner paid after their invoices were voided, the terms agreed with an owner still on the standard grid, documents an owner has not signed, an official form to check, a plate to check, a car showing sample photos, and any task of the Admin.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Press the line&#39;s button: Mark insured, Set rates and publish, Review documents, Record payment, Record what they paid, Enter the terms, Record paper signature, Checked: use for owners, Open the chat, and so on. A line you do not need has Not needed or These are correct. The pop-up is filled in; check it and confirm. The line disappears once the work is done.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Under the lines, the counts with one button each (failed payments, agreements to countersign, tolls, listings, insurance, staff commissions, prices typed by hand, sales claims, Turo emails). A count with nothing waiting moves to the bottom, under &quot;more with nothing waiting&quot;.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t">While no assistant holds customer service, sales, finance or fleet (the live verification&#39;s test accounts do not count), their tasks come to To do too, and so do their emails, to rent@carmacars.ca.</div></li><li><span class="gd-n" aria-hidden="true">5</span><div class="gd-t">Beside the list (under it on a phone): today&#39;s pickups (ready or not ready), today&#39;s returns (due or late) and today&#39;s chauffeur bookings, by time.</div></li><li><span class="gd-n" aria-hidden="true">6</span><div class="gd-t">Press <b class="gd-ui">Overview</b> for the money, fleet and queue figures, the alerts and the team&#39;s sales for the month.</div></li><li><span class="gd-n" aria-hidden="true">7</span><div class="gd-t">The dark band at the top counts the day, each count one tap from its page: requests waiting (with how long the oldest has waited, red past the reply target), pickups and returns today, payments to chase, deposits to settle, staff tasks open and alerts. A count that needs you now is red and says so.</div></li></ol></div><figure class="gd-fig gd-fig--desk"><div class="gd-browser"><div class="gd-bar" aria-hidden="true"><i></i><i></i><i></i><span class="gd-addr">carmacars.ca/admin</span></div><div class="gd-imgwrap" style="aspect-ratio:1440/900"><img src="/guides/img/admin-01-today-desktop-ea48309c.jpg" alt="" loading="lazy" decoding="async" width="1440" height="900"><span class="gd-pin" style="left:22.6%;top:31.6%" aria-hidden="true">1</span><span class="gd-pin" style="left:90.3%;top:31.7%" aria-hidden="true">2</span><span class="gd-pin" style="left:18.4%;top:90.2%" aria-hidden="true">3</span><span class="gd-pin" style="left:94.4%;top:22.2%" aria-hidden="true">4</span></div></div></figure></div></section><section class="gd-task" id="getting-around-admin-the-menu" data-gd-task><h2 class="gd-h2">The menu</h2><p class="gd-p">The current group is open, with its pages; press another group to open it. On a phone the whole menu sits behind one Menu button that says where you are.</p><div class="gd-tablewrap"><table class="gd-table"><thead><tr><th scope="col">Group</th><th scope="col">Pages</th></tr></thead><tbody><tr><td>Today</td><td>To do, Overview, Staff tasks, Live visitors</td></tr><tr><td>Bookings</td><td>Trips: Requests, Bookings, Calendar, Add a rental, Chauffeur. Customers: Live chat, Renter leads, Reviews. Problems: Damage, Incidents and claims</td></tr><tr><td>Cars</td><td>Vehicles, Listings, Maintenance, Rates for many cars, Calendar sync, Similar cars, Retire or delete</td></tr><tr><td>Money</td><td>Owners: Owner invoices, Owner debits, Owner statements, Payouts. Renters: Payments by day, Payments and refunds, Tolls and tickets. Company: Company statements, Reconciliation, Expenses, Insurer rates, Insurer invoices, Staff commissions, Field pay</td></tr><tr><td>People</td><td>Owners and partners: Applications, Owners, Add a car for an owner, Partners, Owner forms, Paid and signed. Renters, staff and investors: Renters, Staff, Investors, Portals and view as</td></tr><tr><td>Marketing</td><td>Ads: Listings, Posted ads, Social drafts. Results: Bookings by channel. Owners: Owner recruitment</td></tr><tr><td>Settings</td><td>All settings. Website: Site, Vehicle pages, Sample photos, Add-ons, Discount games, Guides. Rules: Program, Forms, Maintenance, Emails. Records: Email log, Audit log</td></tr></tbody></table></div><div class="gd-figblock"><figure class="gd-fig gd-fig--phone"><div class="gd-phone"><div class="gd-imgwrap" style="aspect-ratio:390/715"><img src="/guides/img/admin-31-menu-phone-667dc2fd.jpg" alt="On a phone: press Menu (1), then a group (2), then the page (3)." loading="lazy" decoding="async" width="390" height="715"><span class="gd-pin" style="left:10.3%;top:28.7%" aria-hidden="true">1</span><span class="gd-pin" style="left:76.9%;top:42.4%" aria-hidden="true">2</span><span class="gd-pin" style="left:76.9%;top:48.3%" aria-hidden="true">3</span></div></div><figcaption>On a phone: press Menu (1), then a group (2), then the page (3).</figcaption></figure></div></section><section class="gd-task" id="getting-around-admin-search" data-gd-task><h2 class="gd-h2">Search</h2><p class="gd-p">The search box sits at the top of the menu, on every page.</p><div class="gd-stepblock gd-stepblock--below"><div class="gd-stepcol"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">Type a booking number (CC-1042), a car code (CC-7F3A, on every car page and fleet card), a plate, a VIN, or a name or email address.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Press <b class="gd-ui">Search</b> (or Enter). Results come in groups: bookings, cars, owners, partners and renters. Open one to go to its page.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">To go to a page instead, press Ctrl+K (Cmd+K on a Mac) or <b class="gd-ui">Jump to a page</b> under the search box, type a few letters (Payouts, Program settings) and press Enter. The first line searches the records for what you typed.</div></li></ol></div><figure class="gd-fig gd-fig--desk"><div class="gd-browser"><div class="gd-bar" aria-hidden="true"><i></i><i></i><i></i><span class="gd-addr">carmacars.ca/admin/search?q=CC-10057</span></div><div class="gd-imgwrap" style="aspect-ratio:1440/420"><img src="/guides/img/admin-32-search-desktop-ca548a70.jpg" alt="" loading="lazy" decoding="async" width="1440" height="420"><span class="gd-pin" style="left:7.4%;top:45.2%" aria-hidden="true">1</span><span class="gd-pin" style="left:95%;top:46.9%" aria-hidden="true">2</span></div></div></figure></div></section><section class="gd-task" id="getting-around-admin-keyboard-shortcuts" data-gd-task><h2 class="gd-h2">Keyboard shortcuts</h2><p class="gd-p">Press g, then a letter. Press / to jump to the search box, and Ctrl+K to jump to any page.</p><div class="gd-tablewrap"><table class="gd-table"><thead><tr><th scope="col">Keys</th><th scope="col">Opens</th><th scope="col">Keys</th><th scope="col">Opens</th></tr></thead><tbody><tr><td>g t</td><td>To do</td><td>g v</td><td>Vehicles</td></tr><tr><td>g r</td><td>Requests</td><td>g l</td><td>Listings</td></tr><tr><td>g b</td><td>Bookings</td><td>g a</td><td>Applications</td></tr><tr><td>g c</td><td>Calendar</td><td>g o</td><td>Owners</td></tr><tr><td>g k</td><td>Staff tasks</td><td>g m</td><td>Payments and refunds</td></tr><tr><td>g s</td><td>All settings</td><td>/</td><td>Search</td></tr><tr><td>Ctrl K</td><td>Jump to a page</td><td>Esc</td><td>Close it</td></tr></tbody></table></div></section>');
select app.guide_release_section('admin', 'advertising-and-owner-recruitment', 'chapter', 'referral-partners-and-rentalcoverage', null, 'Advertising and owner recruitment', 'Ad text for each car and channel, posted ads and their update tasks, bookings by channel, social drafts, Meta publishing, owner recruitment and its consent log.',
  'Marketing writes the text of every ad from the car''s own record, keeps track of where each ad is posted, tells the sales assistants when an ad needs updating, shows which channels bring bookings, drafts the week''s Facebook Page and Instagram posts and keeps the consent log for owner recruitment. Nothing is posted by the server: you post by hand, and Facebook Marketplace from the owner''s own profile.

## Write an ad

**Marketing** > **Listings**.

1. Choose the car and the channel (Facebook Marketplace, Kijiji, Craigslist, Instagram, Facebook Page or Google Business Profile) and press **Write it**.
2. Copy each part with its button: the title, the price line, the description (or caption), the hashtags and the tracked link. Each shows its length against the channel''s limit (a Kijiji title takes 64 characters, Craigslist 70, an Instagram caption 2,200, a Google post 1,500).
3. Add the photos in the order shown: the first is the cover. Open a photo to save it.
4. Post the ad on the site, then press **Mark as posted** and paste its address and the date.

- The text comes from the car''s record only: the rates, kilometres, deposit, delivery fee, who may rent it and the car code. A fact the record does not have is left out. No review, rating or claim is added.
- The tracked link opens the car''s page with utm_source (the channel), utm_medium and utm_campaign (the car code), so the request counts under that channel.
- A warning shows when the car does not take requests, has no daily rate, or shows sample photos (take real photos first: an ad shows the car itself).
- Facebook Marketplace is posted from the owner''s own Facebook profile in their browser: Meta does not take vehicle listings from business Pages. Kijiji takes one ad per car, in one category and one region. An Instagram caption cannot hold a working link: put it in the bio or a story link sticker.

## When an ad needs updating

**Marketing** > **Posted ads**, or the task in **Today** > **Staff tasks**.

1. A change of 3% or more in a car''s daily, weekend, weekly or 30-day rate, any change of its deposit, kilometres, extra-km price or delivery fee, or the car leaving the site marks each of its live ads Needs updating and opens a task for the sales assistants (for example Update the Kijiji ad and the car). The task says what changed, the new price line and the ad''s address.
2. Press **New text**, copy the new text and update the ad on the site.
3. Press **Mark the ad updated**. The task closes. Closing the task in Staff tasks counts too.
4. Car off the site: take the ad down and press **Taken down**. If the car comes back at the same rates first, the task is cancelled by itself.

> Good to know: The 3% is under **Settings** > **Program**, Advertising and owner recruitment. The rates are checked again every 6 hours, so a rate dated ahead is caught on its day.

## Bookings by channel

**Marketing** > **Bookings by channel**.

- Every request of the dates chosen counts once: under the source staff set on the booking, else the renter''s visit (the campaign source of a tracked link, or the site they came from), else a referral code, else how it reached us (phone, email, WhatsApp).
- Choose the last visit before the request or the first visit. A booking is a request that was confirmed, paid or completed; revenue is its rental charge after discounts. The months add up to the Bookings list.
- The visit is kept with the request when it is sent, so the source outlives the 90 days of visit history. A visitor who refused analytics cookies has no source.
- On a booking, the line Came from shows the source. Press **Set** to give it by hand when the renter told you (a Kijiji reply, a walk-in, word of mouth).

## Facebook Page and Instagram drafts

**Marketing** > **Social drafts**.

1. The week''s drafts are written from the fleet every 6 hours, for this week and the next: Monday a new car (published in the last 14 days) or a featured one; Tuesday the owner program; Thursday the cars free this weekend; Friday the requirements (Instagram); Sunday a price highlight or a seasonal trip (Facebook Page). Press **Write drafts for this week** to write them now.
2. Read each draft. Press **Edit** to change the caption, the channels or the day, then **Approve**; or press **Skip**.
3. Copy the caption for each channel (on the Facebook Page the tracked link is in the text; for Instagram copy the link for the bio), post it with the photos shown, then press **Posted on Instagram** or **Posted on Facebook Page** and paste the post''s address.

- Wednesday''s walkaround video and Saturday''s handover story are filmed by field staff. No renter is shown without written consent.
- Press **Add a post of your own** at the bottom of the week for anything else.

## Meta publishing (off until set up)

**Settings** > **Meta publishing**. Until it is on, every post is copied and posted by hand.

1. Make the Instagram account a professional account and link it to the CarmaCars Facebook Page.
2. At developers.facebook.com, create a Business app owned by the CarmaCars business portfolio. Give it the permissions pages_show_list, pages_read_engagement, pages_manage_posts, instagram_basic and instagram_content_publish, and make a long-lived Page access token. Meta may ask for App Review before posts are public.
3. Press **Enter the details**: the Page id, the Instagram account id and the token. The token goes to the vault; the page shows only its last four characters.
4. Press **Switch on**. Approved drafts then go out on their day and their post links are recorded; a refusal shows on the draft. Press **Switch off** or **Remove the token** at any time.

## Owner recruitment

**Marketing** > **Owner recruitment**.

Owners and co-hosts are found in classified ads. The anti-spam law (CASL) does not cover a live phone call, but an email or a text needs consent, names the sender and offers an unsubscribe. The lawyer confirms the approach before outreach starts.

1. Press **Add a lead**: paste the ad''s address, choose who is selling (a private seller, a dealer or a rental business) and type the name, the phone and the car from the ad. Nothing is collected from the classified site.
2. Call them with the script on the lead''s page and press **Log the call**. A yes needs their words ("Yes, text me the details"): they become express consent in the log. A no means do not contact, ever.
3. When the lead''s page says email or text is allowed, choose a template, check the words and press **Send**. The email adds CarmaCars'' name, mailing address and the unsubscribe link; the text ends with "Reply STOP to opt out." Texts wait for 8 am during quiet hours.

- Press **Record consent** for consent given another way: express (with its proof), implied by their inquiry (6 months), implied by a business relationship (2 years), a business address published with no "no solicitation" note (never a private seller), or one message after a referral (naming the referrer).
- The consent log is never edited: a change is a new line. An unsubscribe or a STOP reply adds a withdrawal by itself, and nothing more goes on that channel.
- A message without consent is refused with the reason. **Settings** > **Program** has a switch that stops all recruitment messages.

> Watch out: Keep the proof of an oral yes: a recording, or a note written during the call with the time. Consent you cannot show does not count.
',
  '<p class="gd-p">Marketing writes the text of every ad from the car&#39;s own record, keeps track of where each ad is posted, tells the sales assistants when an ad needs updating, shows which channels bring bookings, drafts the week&#39;s Facebook Page and Instagram posts and keeps the consent log for owner recruitment. Nothing is posted by the server: you post by hand, and Facebook Marketplace from the owner&#39;s own profile.</p><section class="gd-task" id="advertising-and-owner-recruitment-write-an-ad" data-gd-task><h2 class="gd-h2">Write an ad</h2><p class="gd-p"><b class="gd-ui">Marketing</b> &gt; <b class="gd-ui">Listings</b>.</p><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">Choose the car and the channel (Facebook Marketplace, Kijiji, Craigslist, Instagram, Facebook Page or Google Business Profile) and press <b class="gd-ui">Write it</b>.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Copy each part with its button: the title, the price line, the description (or caption), the hashtags and the tracked link. Each shows its length against the channel&#39;s limit (a Kijiji title takes 64 characters, Craigslist 70, an Instagram caption 2,200, a Google post 1,500).</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Add the photos in the order shown: the first is the cover. Open a photo to save it.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t">Post the ad on the site, then press <b class="gd-ui">Mark as posted</b> and paste its address and the date.</div></li></ol></div><ul class="gd-ul"><li>The text comes from the car&#39;s record only: the rates, kilometres, deposit, delivery fee, who may rent it and the car code. A fact the record does not have is left out. No review, rating or claim is added.</li><li>The tracked link opens the car&#39;s page with utm_source (the channel), utm_medium and utm_campaign (the car code), so the request counts under that channel.</li><li>A warning shows when the car does not take requests, has no daily rate, or shows sample photos (take real photos first: an ad shows the car itself).</li><li>Facebook Marketplace is posted from the owner&#39;s own Facebook profile in their browser: Meta does not take vehicle listings from business Pages. Kijiji takes one ad per car, in one category and one region. An Instagram caption cannot hold a working link: put it in the bio or a story link sticker.</li></ul></section><section class="gd-task" id="advertising-and-owner-recruitment-when-an-ad-needs-updating" data-gd-task><h2 class="gd-h2">When an ad needs updating</h2><p class="gd-p"><b class="gd-ui">Marketing</b> &gt; <b class="gd-ui">Posted ads</b>, or the task in <b class="gd-ui">Today</b> &gt; <b class="gd-ui">Staff tasks</b>.</p><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">A change of 3% or more in a car&#39;s daily, weekend, weekly or 30-day rate, any change of its deposit, kilometres, extra-km price or delivery fee, or the car leaving the site marks each of its live ads Needs updating and opens a task for the sales assistants (for example Update the Kijiji ad and the car). The task says what changed, the new price line and the ad&#39;s address.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Press <b class="gd-ui">New text</b>, copy the new text and update the ad on the site.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Press <b class="gd-ui">Mark the ad updated</b>. The task closes. Closing the task in Staff tasks counts too.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t">Car off the site: take the ad down and press <b class="gd-ui">Taken down</b>. If the car comes back at the same rates first, the task is cancelled by itself.</div></li></ol></div><aside class="gd-box"><span class="gd-lbl">Good to know</span><div>The 3% is under <b class="gd-ui">Settings</b> &gt; <b class="gd-ui">Program</b>, Advertising and owner recruitment. The rates are checked again every 6 hours, so a rate dated ahead is caught on its day.</div></aside></section><section class="gd-task" id="advertising-and-owner-recruitment-bookings-by-channel" data-gd-task><h2 class="gd-h2">Bookings by channel</h2><p class="gd-p"><b class="gd-ui">Marketing</b> &gt; <b class="gd-ui">Bookings by channel</b>.</p><ul class="gd-ul"><li>Every request of the dates chosen counts once: under the source staff set on the booking, else the renter&#39;s visit (the campaign source of a tracked link, or the site they came from), else a referral code, else how it reached us (phone, email, WhatsApp).</li><li>Choose the last visit before the request or the first visit. A booking is a request that was confirmed, paid or completed; revenue is its rental charge after discounts. The months add up to the Bookings list.</li><li>The visit is kept with the request when it is sent, so the source outlives the 90 days of visit history. A visitor who refused analytics cookies has no source.</li><li>On a booking, the line Came from shows the source. Press <b class="gd-ui">Set</b> to give it by hand when the renter told you (a Kijiji reply, a walk-in, word of mouth).</li></ul></section><section class="gd-task" id="advertising-and-owner-recruitment-facebook-page-and-instagram-drafts" data-gd-task><h2 class="gd-h2">Facebook Page and Instagram drafts</h2><p class="gd-p"><b class="gd-ui">Marketing</b> &gt; <b class="gd-ui">Social drafts</b>.</p><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">The week&#39;s drafts are written from the fleet every 6 hours, for this week and the next: Monday a new car (published in the last 14 days) or a featured one; Tuesday the owner program; Thursday the cars free this weekend; Friday the requirements (Instagram); Sunday a price highlight or a seasonal trip (Facebook Page). Press <b class="gd-ui">Write drafts for this week</b> to write them now.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Read each draft. Press <b class="gd-ui">Edit</b> to change the caption, the channels or the day, then <b class="gd-ui">Approve</b>; or press <b class="gd-ui">Skip</b>.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Copy the caption for each channel (on the Facebook Page the tracked link is in the text; for Instagram copy the link for the bio), post it with the photos shown, then press <b class="gd-ui">Posted on Instagram</b> or <b class="gd-ui">Posted on Facebook Page</b> and paste the post&#39;s address.</div></li></ol></div><ul class="gd-ul"><li>Wednesday&#39;s walkaround video and Saturday&#39;s handover story are filmed by field staff. No renter is shown without written consent.</li><li>Press <b class="gd-ui">Add a post of your own</b> at the bottom of the week for anything else.</li></ul></section><section class="gd-task" id="advertising-and-owner-recruitment-meta-publishing-off-until-set-up" data-gd-task><h2 class="gd-h2">Meta publishing (off until set up)</h2><p class="gd-p"><b class="gd-ui">Settings</b> &gt; <b class="gd-ui">Meta publishing</b>. Until it is on, every post is copied and posted by hand.</p><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">Make the Instagram account a professional account and link it to the CarmaCars Facebook Page.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">At developers.facebook.com, create a Business app owned by the CarmaCars business portfolio. Give it the permissions pages_show_list, pages_read_engagement, pages_manage_posts, instagram_basic and instagram_content_publish, and make a long-lived Page access token. Meta may ask for App Review before posts are public.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Press <b class="gd-ui">Enter the details</b>: the Page id, the Instagram account id and the token. The token goes to the vault; the page shows only its last four characters.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t">Press <b class="gd-ui">Switch on</b>. Approved drafts then go out on their day and their post links are recorded; a refusal shows on the draft. Press <b class="gd-ui">Switch off</b> or <b class="gd-ui">Remove the token</b> at any time.</div></li></ol></div></section><section class="gd-task" id="advertising-and-owner-recruitment-owner-recruitment" data-gd-task><h2 class="gd-h2">Owner recruitment</h2><p class="gd-p"><b class="gd-ui">Marketing</b> &gt; <b class="gd-ui">Owner recruitment</b>.</p><p class="gd-p">Owners and co-hosts are found in classified ads. The anti-spam law (CASL) does not cover a live phone call, but an email or a text needs consent, names the sender and offers an unsubscribe. The lawyer confirms the approach before outreach starts.</p><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">Press <b class="gd-ui">Add a lead</b>: paste the ad&#39;s address, choose who is selling (a private seller, a dealer or a rental business) and type the name, the phone and the car from the ad. Nothing is collected from the classified site.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Call them with the script on the lead&#39;s page and press <b class="gd-ui">Log the call</b>. A yes needs their words (&quot;Yes, text me the details&quot;): they become express consent in the log. A no means do not contact, ever.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">When the lead&#39;s page says email or text is allowed, choose a template, check the words and press <b class="gd-ui">Send</b>. The email adds CarmaCars&#39; name, mailing address and the unsubscribe link; the text ends with &quot;Reply STOP to opt out.&quot; Texts wait for 8 am during quiet hours.</div></li></ol></div><ul class="gd-ul"><li>Press <b class="gd-ui">Record consent</b> for consent given another way: express (with its proof), implied by their inquiry (6 months), implied by a business relationship (2 years), a business address published with no &quot;no solicitation&quot; note (never a private seller), or one message after a referral (naming the referrer).</li><li>The consent log is never edited: a change is a new line. An unsubscribe or a STOP reply adds a withdrawal by itself, and nothing more goes on that channel.</li><li>A message without consent is refused with the reason. <b class="gd-ui">Settings</b> &gt; <b class="gd-ui">Program</b> has a switch that stops all recruitment messages.</li></ul><aside class="gd-box gd-box--warn"><span class="gd-lbl">Watch out</span><div>Keep the proof of an oral yes: a recording, or a note written during the call with the time. Consent you cannot show does not count.</div></aside></section>');
select app.guide_release_section('admin', 'quick-reference', 'reference', 'email-backups-and-site-health', '### Where things are

| Item | What it is for |
| --- | --- |
| **To do** | What needs you now, most urgent first |
| **Search** | Any booking, plate, VIN, name or email |
| **Bookings** | Requests, bookings, the calendar, adding a rental |
| **Cars** | Vehicles, listings, calendar sync, sample photos |
| **Money** | Owner invoices and debits, payments, statements, tolls |
| **People** | Applications, owners, partners, owner forms; renters, staff, investors, View as |
| **Settings** | Site, program, forms, guides, emails, audit log |

### Top tasks

1. *Answer an application:* **People** > **Applications**, then **Approve**, **Ask for something** or **Decline**
2. *Send an offer:* **Bookings** > **Requests**, the booking, then **Send the offer**
3. *Change a booking:* The booking''s Changes tab, then **Send to the renter**
4. *Publish a car:* To do, the car''s line, then **Set rates and publish**
5. *Mark a car insured:* To do, the car''s line, then **Mark insured**
6. *Check renter documents:* To do, the booking''s line, then **Review documents**
7. *Let someone in:* **People** > **Portals and view as**, then **Invite**
8. *Help someone sign in:* **Send password link**
9. *Read a toll notice:* **Money** > **Tolls and tickets**, then **Read a notice**
10. *Monthly statements:* **Build all for a month**, Approve, Issue

### If something goes wrong

| What you see | What to do |
| --- | --- |
| **A link says it expired** | Links in our emails work for 24 hours, once. Press **Send me a new link** on that page. |
| **"Error 1102" on a page** | A short limit on our web host. Reload the page. You are still signed in. |
| **"That email and password do not match an account."** | Check the address, or use **Set a new password** on the sign-in page. |
| **You can''t change anything** | You are viewing as someone. Press Exit on the red banner. |
| **Asked for a 6-digit code** | Open your authenticator app. Lost phone: remove the factor in the Supabase dashboard. |
', 'Quick reference', 'One page with the essentials.',
  '### Where things are

| Item | What it is for |
| --- | --- |
| **To do** | What needs you now, most urgent first |
| **Search** | Any booking, plate, VIN, name or email |
| **Bookings** | Requests, bookings, the calendar, adding a rental |
| **Cars** | Vehicles, listings, calendar sync, sample photos |
| **Money** | Owner invoices and debits, payments, statements, tolls |
| **People** | Applications, owners, partners, owner forms; renters, staff, investors, View as |
| **Marketing** | Ad text for each channel, posted ads, social drafts, bookings by channel, owner recruitment |
| **Settings** | Site, program, forms, guides, emails, audit log |

### Top tasks

1. *Answer an application:* **People** > **Applications**, then **Approve**, **Ask for something** or **Decline**
2. *Send an offer:* **Bookings** > **Requests**, the booking, then **Send the offer**
3. *Change a booking:* The booking''s Changes tab, then **Send to the renter**
4. *Publish a car:* To do, the car''s line, then **Set rates and publish**
5. *Mark a car insured:* To do, the car''s line, then **Mark insured**
6. *Check renter documents:* To do, the booking''s line, then **Review documents**
7. *Let someone in:* **People** > **Portals and view as**, then **Invite**
8. *Help someone sign in:* **Send password link**
9. *Read a toll notice:* **Money** > **Tolls and tickets**, then **Read a notice**
10. *Monthly statements:* **Build all for a month**, Approve, Issue

### If something goes wrong

| What you see | What to do |
| --- | --- |
| **A link says it expired** | Links in our emails work for 24 hours, once. Press **Send me a new link** on that page. |
| **"Error 1102" on a page** | A short limit on our web host. Reload the page. You are still signed in. |
| **"That email and password do not match an account."** | Check the address, or use **Set a new password** on the sign-in page. |
| **You can''t change anything** | You are viewing as someone. Press Exit on the red banner. |
| **Asked for a 6-digit code** | Open your authenticator app. Lost phone: remove the factor in the Supabase dashboard. |
',
  '<h3 class="gd-h3">Where things are</h3><div class="gd-tablewrap"><table class="gd-table"><thead><tr><th scope="col">Item</th><th scope="col">What it is for</th></tr></thead><tbody><tr><td><b class="gd-ui">To do</b></td><td>What needs you now, most urgent first</td></tr><tr><td><b class="gd-ui">Search</b></td><td>Any booking, plate, VIN, name or email</td></tr><tr><td><b class="gd-ui">Bookings</b></td><td>Requests, bookings, the calendar, adding a rental</td></tr><tr><td><b class="gd-ui">Cars</b></td><td>Vehicles, listings, calendar sync, sample photos</td></tr><tr><td><b class="gd-ui">Money</b></td><td>Owner invoices and debits, payments, statements, tolls</td></tr><tr><td><b class="gd-ui">People</b></td><td>Applications, owners, partners, owner forms; renters, staff, investors, View as</td></tr><tr><td><b class="gd-ui">Marketing</b></td><td>Ad text for each channel, posted ads, social drafts, bookings by channel, owner recruitment</td></tr><tr><td><b class="gd-ui">Settings</b></td><td>Site, program, forms, guides, emails, audit log</td></tr></tbody></table></div><h3 class="gd-h3">Top tasks</h3><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t"><em>Answer an application:</em> <b class="gd-ui">People</b> &gt; <b class="gd-ui">Applications</b>, then <b class="gd-ui">Approve</b>, <b class="gd-ui">Ask for something</b> or <b class="gd-ui">Decline</b></div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t"><em>Send an offer:</em> <b class="gd-ui">Bookings</b> &gt; <b class="gd-ui">Requests</b>, the booking, then <b class="gd-ui">Send the offer</b></div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t"><em>Change a booking:</em> The booking&#39;s Changes tab, then <b class="gd-ui">Send to the renter</b></div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t"><em>Publish a car:</em> To do, the car&#39;s line, then <b class="gd-ui">Set rates and publish</b></div></li><li><span class="gd-n" aria-hidden="true">5</span><div class="gd-t"><em>Mark a car insured:</em> To do, the car&#39;s line, then <b class="gd-ui">Mark insured</b></div></li><li><span class="gd-n" aria-hidden="true">6</span><div class="gd-t"><em>Check renter documents:</em> To do, the booking&#39;s line, then <b class="gd-ui">Review documents</b></div></li><li><span class="gd-n" aria-hidden="true">7</span><div class="gd-t"><em>Let someone in:</em> <b class="gd-ui">People</b> &gt; <b class="gd-ui">Portals and view as</b>, then <b class="gd-ui">Invite</b></div></li><li><span class="gd-n" aria-hidden="true">8</span><div class="gd-t"><em>Help someone sign in:</em> <b class="gd-ui">Send password link</b></div></li><li><span class="gd-n" aria-hidden="true">9</span><div class="gd-t"><em>Read a toll notice:</em> <b class="gd-ui">Money</b> &gt; <b class="gd-ui">Tolls and tickets</b>, then <b class="gd-ui">Read a notice</b></div></li><li><span class="gd-n" aria-hidden="true">10</span><div class="gd-t"><em>Monthly statements:</em> <b class="gd-ui">Build all for a month</b>, Approve, Issue</div></li></ol></div><h3 class="gd-h3">If something goes wrong</h3><div class="gd-tablewrap"><table class="gd-table"><thead><tr><th scope="col">What you see</th><th scope="col">What to do</th></tr></thead><tbody><tr><td><b class="gd-ui">A link says it expired</b></td><td>Links in our emails work for 24 hours, once. Press <b class="gd-ui">Send me a new link</b> on that page.</td></tr><tr><td><b class="gd-ui">&quot;Error 1102&quot; on a page</b></td><td>A short limit on our web host. Reload the page. You are still signed in.</td></tr><tr><td><b class="gd-ui">&quot;That email and password do not match an account.&quot;</b></td><td>Check the address, or use <b class="gd-ui">Set a new password</b> on the sign-in page.</td></tr><tr><td><b class="gd-ui">You can&#39;t change anything</b></td><td>You are viewing as someone. Press Exit on the red banner.</td></tr><tr><td><b class="gd-ui">Asked for a 6-digit code</b></td><td>Open your authenticator app. Lost phone: remove the factor in the Supabase dashboard.</td></tr></tbody></table></div>');
-- GUIDES 0167 END
