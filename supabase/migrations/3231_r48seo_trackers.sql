-- 3231 (release 48, SEO): the GPS tracker and kill switch as a product with its own pages, its volume pricing and a
-- waitlist (docs/changes/2026-11-20-r48-seo.md).
--
-- The owner, Nov 20 (12:45 to 12:47): the tracker gets a product page and a cluster (GPS tracker, kill switch, starter
-- interrupt, anti-theft, fleet tracking, Turo host tracker, install near me). The price is by the number of cars, from the
-- Vehicle Owner Program: $25 a month per car for 1 or 2 cars, $20 for 3 to 9, $15 for 10 or more; install $150 once per
-- car. The trackers are not in hand yet: the pages say "Join the waitlist / pre-order" while trackers_available is off,
-- and never say a tracker is in stock.
--
-- - program_settings.tracker_product_tiers: the monthly price by number of cars. tracker_product_install_cents = $150.
-- - public.tracker_product() also answers the tiers, the lowest monthly price and whether trackers can be installed now.
-- - public.submit_tracker_waitlist: the waitlist or pre-order form (a lead for Sales with its To do and the staff alert of
--   0460, like every website lead) and the person's confirmation email (tracker_waitlist_joined).
-- - public.tracker_install_places: the Ontario cities whose install page the sitemap lists.
-- - /gps-tracker moved to /trackers: the families sitemap lists the new addresses.
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
-- Called by the check constraint below for whoever saves Program settings, so it keeps the default execute (it reads nothing).
create or replace function app.tracker_tiers_ok(p jsonb) returns boolean
language sql immutable as $$
  select jsonb_typeof(p) = 'array' and jsonb_array_length(p) between 1 and 8
     and not exists (select 1 from jsonb_array_elements(p) t
                      where jsonb_typeof(t) <> 'object' or jsonb_typeof(t -> 'from_cars') <> 'number' or jsonb_typeof(t -> 'monthly_cents') <> 'number'
                         or (t ->> 'from_cars')::numeric < 1 or (t ->> 'monthly_cents')::numeric not between 0 and 100000)
     and exists (select 1 from jsonb_array_elements(p) t where (t ->> 'from_cars')::numeric = 1)
$$;

alter table program_settings
  add column if not exists tracker_product_tiers jsonb not null
    default '[{"from_cars": 1, "monthly_cents": 2500}, {"from_cars": 3, "monthly_cents": 2000}, {"from_cars": 10, "monthly_cents": 1500}]'::jsonb
    check (app.tracker_tiers_ok(tracker_product_tiers)),
  add column if not exists tracker_product_launch_note text not null default 'Shipping soon' check (length(tracker_product_launch_note) between 2 and 80);
comment on column program_settings.tracker_product_tiers is 'GPS tracker product (3231): the monthly price per car by the number of cars, [{from_cars, monthly_cents}], before HST. From the Vehicle Owner Program: $25 for 1 or 2 cars, $20 for 3 to 9, $15 for 10 or more.';
comment on column program_settings.tracker_product_launch_note is 'GPS tracker product (3231): the words shown beside "Join the waitlist" while trackers cannot be installed yet (trackers_available off). Never a date we cannot keep.';

-- the install price ($150 once per car, the owner, Nov 20) and what the tracker does, where the release 36 defaults still stand
update program_settings set tracker_product_install_cents = 15000 where tracker_product_install_cents is null or tracker_product_install_cents = 10000;
update program_settings set tracker_product_features = '[
    {"title": "Live GPS location", "text": "See where the car is on a map from your phone or computer, with a reading at least every {{trackerMinutes}} minutes while it moves. You see it, and so do we."},
    {"title": "Kill switch (engine shut-off)", "text": "A starter interrupt: once the car is parked, the engine can be kept from starting again, from your phone. Used when a car is overdue, stolen or not paid for."},
    {"title": "Remote lock and door release", "text": "Lock the doors or open them for a handover without meeting anyone and without a spare key changing hands."},
    {"title": "Alarm", "text": "Sound the horn and flash the lights from your phone to find the car or scare off a thief."},
    {"title": "Trip history", "text": "Each trip with its route, times and distance, kept with the car."},
    {"title": "Tolls and tickets go to the driver", "text": "Every 407 ETR toll and ticket is matched to whoever had the car at that minute and billed to that renter, with the proof."},
    {"title": "Installed by us", "text": "We install the tracker out of sight and check that it works before the car goes out."}
  ]'::jsonb
 where tracker_product_features::text like '%"Frequent readings"%';
alter table program_settings alter column tracker_product_features set default '[
    {"title": "Live GPS location", "text": "See where the car is on a map from your phone or computer, with a reading at least every {{trackerMinutes}} minutes while it moves. You see it, and so do we."},
    {"title": "Kill switch (engine shut-off)", "text": "A starter interrupt: once the car is parked, the engine can be kept from starting again, from your phone. Used when a car is overdue, stolen or not paid for."},
    {"title": "Remote lock and door release", "text": "Lock the doors or open them for a handover without meeting anyone and without a spare key changing hands."},
    {"title": "Alarm", "text": "Sound the horn and flash the lights from your phone to find the car or scare off a thief."},
    {"title": "Trip history", "text": "Each trip with its route, times and distance, kept with the car."},
    {"title": "Tolls and tickets go to the driver", "text": "Every 407 ETR toll and ticket is matched to whoever had the car at that minute and billed to that renter, with the proof."},
    {"title": "Installed by us", "text": "We install the tracker out of sight and check that it works before the car goes out."}
  ]'::jsonb;

-- The monthly price per car for a number of cars.
create or replace function app.tracker_monthly_cents(p_cars integer) returns integer
language sql stable security definer set search_path = public, app as $$
  select (t ->> 'monthly_cents')::integer from jsonb_array_elements((app.settings()).tracker_product_tiers) t
   where (t ->> 'from_cars')::integer <= greatest(coalesce(p_cars, 1), 1) order by (t ->> 'from_cars')::integer desc limit 1
$$;

-- The product as the public pages read it (replaces 2003's): the tiers in order with the range each covers, the lowest
-- monthly price, the install price, and whether trackers can be installed now (off: the pages show the waitlist).
create or replace function public.tracker_product() returns jsonb
language sql stable security definer set search_path = public, app as $$
  with s as (select (app.settings()).*),
  t as (select (x ->> 'from_cars')::integer from_cars, (x ->> 'monthly_cents')::integer monthly_cents from s, jsonb_array_elements(s.tracker_product_tiers) x),
  r as (select from_cars, monthly_cents, lead(from_cars) over (order by from_cars) - 1 to_cars from t)
  select case when s.tracker_product_enabled then jsonb_build_object('name', s.tracker_product_name,
    'monthly_cents', coalesce((select min(monthly_cents) from t), s.tracker_product_monthly_cents, s.owner_calc_tracker_fee),
    'install_cents', s.tracker_product_install_cents,
    'tiers', (select coalesce(jsonb_agg(jsonb_build_object('from_cars', from_cars, 'to_cars', to_cars, 'monthly_cents', monthly_cents) order by from_cars), '[]'::jsonb) from r),
    'available', coalesce(s.trackers_available, false), 'launch_note', s.tracker_product_launch_note,
    'hst_bps', s.hst_bps,
    'features', (select coalesce(jsonb_agg(jsonb_build_object('title', f ->> 'title', 'text', replace(f ->> 'text', '{{trackerMinutes}}', s.tracker_reading_max_minutes::text))), '[]'::jsonb)
                   from jsonb_array_elements(s.tracker_product_features) f),
    'details', s.tracker_product_details) end
    from s
$$;

-- ================================================================ 2. the waitlist
-- p: {name, email, phone, cars, vehicle, city, want ('waitlist' | 'preorder'), note}. A lead for Sales (kind other, form
-- tracker_waitlist) through app.submit_lead, so the rate limit, the To do and the staff alert are the usual ones.
create or replace function app.submit_tracker_waitlist(p jsonb, p_ip text default null) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  s program_settings := app.settings();
  v_cars integer := greatest(1, least(coalesce(nullif(regexp_replace(coalesce(p ->> 'cars', ''), '\D', '', 'g'), '')::integer, 1), 500));
  v_want text := case when p ->> 'want' = 'preorder' then 'preorder' else 'waitlist' end;
  v_name text := nullif(btrim(p ->> 'name'), '');
  v_monthly integer := app.tracker_monthly_cents(v_cars);
  v_money text;
  r jsonb;
  v_id uuid;
begin
  if not s.tracker_product_enabled then raise exception 'The tracker is not offered at the moment' using errcode = '22023'; end if;
  if nullif(btrim(p ->> 'email'), '') is null then raise exception 'Give an email address so we can tell you when trackers arrive' using errcode = '22023'; end if;
  v_money := '$' || trim(to_char(v_monthly / 100.0, 'FM999990.00'));
  r := app.submit_lead(jsonb_build_object('kind', 'other', 'source', 'web', 'source_url', p ->> 'source_url', 'name', v_name, 'email', p ->> 'email', 'phone', p ->> 'phone',
    'message', concat_ws(' ', case v_want when 'preorder' then 'Wants to pre-order the GPS tracker' else 'Joined the GPS tracker waitlist' end || ' for ' || v_cars || case when v_cars = 1 then ' car.' else ' cars.' end,
                         'Car: ' || nullif(btrim(p ->> 'vehicle'), '') || '.', 'Where: ' || nullif(btrim(p ->> 'city'), '') || '.', nullif(btrim(p ->> 'note'), '')),
    'payload', jsonb_strip_nulls(jsonb_build_object('form', 'tracker_waitlist', 'want', v_want, 'cars', v_cars, 'vehicle', nullif(btrim(p ->> 'vehicle'), ''), 'place', nullif(btrim(p ->> 'city'), ''),
               'quoted_monthly_cents', v_monthly, 'quoted_install_cents', s.tracker_product_install_cents, 'trackers_available', coalesce(s.trackers_available, false))),
    'utm', p -> 'utm', 'referrer', p ->> 'referrer'), p_ip);
  if not coalesce((r ->> 'ok')::boolean, false) then return r; end if;
  v_id := (r ->> 'lead_id')::uuid;
  perform app.emit_event('tracker_waitlist_joined', 'lead', v_id,
    jsonb_build_object('email', lower(btrim(p ->> 'email')), 'name', v_name, 'first_name', coalesce(nullif(split_part(coalesce(v_name, ''), ' ', 1), ''), 'there'),
                       'tracker_name', s.tracker_product_name, 'cars_count', v_cars::text, 'monthly_price', regexp_replace(v_money, '\.00$', '') || ' a month',
                       'install_price', case when s.tracker_product_install_cents is null then 'Quoted for your car' else regexp_replace('$' || trim(to_char(s.tracker_product_install_cents / 100.0, 'FM999990.00')), '\.00$', '') end),
    'tracker_waitlist_joined:' || v_id);
  return r || jsonb_build_object('monthly_cents', v_monthly, 'cars', v_cars);
end $$;
create or replace function public.submit_tracker_waitlist(p jsonb, p_ip text default null) returns jsonb
language sql security definer set search_path = public, app as $$ select app.submit_tracker_waitlist(p, p_ip) $$;

-- The lead's source in the lead lists.
alter function app.sl_source(leads) rename to sl_source_pre3231;
create function app.sl_source(l leads) returns text
language sql stable security definer set search_path = public, app as $$
  select case when l.payload ->> 'form' = 'tracker_waitlist' then case when l.payload ->> 'want' = 'preorder' then 'GPS tracker pre-order' else 'GPS tracker waitlist' end
              else app.sl_source_pre3231(l) end
$$;
select pg_temp.copy_grants('app.sl_source(leads)'::regprocedure, 'app.sl_source_pre3231(leads)'::regprocedure);

-- ================================================================ 3. the confirmation email
-- CATALOGUE 3231 START (generated by supabase/seed/3231_gen_catalogue.mjs; do not edit by hand)
insert into notification_catalogue (code, audience, also_sent_to, category, is_digest, digest_slot, from_address, reply_to,
    subject, preheader, timing, trigger_text, replaces_template, link_path, variables, template_html, template_text) values
  ('tracker_waitlist_joined', 'owner', '{}'::text[], 'transactional', false, null, 'CarmaCars <owners@carmacars.ca>', 'owners@carmacars.ca', 'You are on the {{tracker_name}} waitlist', 'We will write as soon as the trackers arrive. Nothing is charged today.', 'Immediate', 'A person joins the GPS tracker waitlist or pre-orders on /trackers (public.submit_tracker_waitlist, migration 3231). Once per sign-up.', null, '/trackers', '[{"name":"cars_count","type":"string"},{"name":"company_address","type":"string","global":true},{"name":"contact_email","type":"string","global":true},{"name":"first_name","type":"string"},{"name":"instagram_url","type":"url","global":true},{"name":"install_price","type":"string"},{"name":"monthly_price","type":"string"},{"name":"opening_hours","type":"string","global":true},{"name":"reply_time","type":"string","global":true},{"name":"support_phone","type":"string","global":true},{"name":"tiktok_url","type":"url","global":true},{"name":"tracker_name","type":"string"}]'::jsonb, 'templates/tracker_waitlist_joined.html', 'templates/tracker_waitlist_joined.txt')
on conflict (code) do update set
  audience = excluded.audience, also_sent_to = excluded.also_sent_to, category = excluded.category,
  is_digest = excluded.is_digest, digest_slot = excluded.digest_slot, from_address = excluded.from_address,
  reply_to = excluded.reply_to, subject = excluded.subject, preheader = excluded.preheader, timing = excluded.timing,
  trigger_text = excluded.trigger_text, replaces_template = excluded.replaces_template, link_path = excluded.link_path,
  variables = excluded.variables, template_html = excluded.template_html, template_text = excluded.template_text,
  in_catalogue = true, updated_at = now();
select app.notification_catalogue_refresh();
-- CATALOGUE 3231 END

-- email only: the form asks for an email (the phone is optional), and one confirmation is enough
update notification_catalogue set emitted_by = 'app.submit_tracker_waitlist (3231): the waitlist or pre-order form of /trackers', link_path = '/trackers', no_text = true, updated_at = now()
 where code = 'tracker_waitlist_joined';
select app.notification_catalogue_refresh();

-- the person is not a user yet: the email goes to the address they gave
alter function app.notification_recipients(app_events, notification_catalogue) rename to notification_recipients_pre3231;
create function app.notification_recipients(p_event app_events, p_c notification_catalogue)
returns table (audience text, user_id uuid, email text, name text, renter_id uuid, owner_id uuid, immediate boolean)
language plpgsql stable security definer set search_path = public, app as $$
begin
  if p_c.code = 'tracker_waitlist_joined' then
    if nullif(btrim(coalesce(p_event.payload ->> 'email', '')), '') is not null then
      return query select 'owner'::text, null::uuid, btrim(p_event.payload ->> 'email'), coalesce(nullif(p_event.payload ->> 'first_name', ''), 'there'), null::uuid, null::uuid, true;
    end if;
    return;
  end if;
  return query select * from app.notification_recipients_pre3231(p_event, p_c);
end $$;
select pg_temp.copy_grants('app.notification_recipients(app_events, notification_catalogue)'::regprocedure, 'app.notification_recipients_pre3231(app_events, notification_catalogue)'::regprocedure);

-- ================================================================ 4. the install pages and the sitemap
-- The Ontario cities nearest our location whose "tracker install in <city>" page the sitemap lists and the product page
-- links: the same gate as the place pages (the region on, within the delivery reach). Read by the server only.
create or replace function public.tracker_install_places(p_limit integer default 60) returns jsonb
language sql stable security definer set search_path = public, app as $$
  select coalesce(jsonb_agg(jsonb_build_object('slug', c.slug, 'name', c.name, 'km', round(c.km)) order by c.km), '[]'::jsonb)
    from (select p.slug, p.name, app.place_km(p) km from places p, (select (app.settings()).*) s
           where s.tracker_product_enabled and p.kind = 5 and app.place_enabled(p) and app.place_km(p) <= s.place_delivery_reach_km
           order by app.place_km(p) limit greatest(1, least(coalesce(p_limit, 60), 300))) c
$$;

-- The families sitemap (2402's, with the tracker at its new address). The tracker's own pages (the product, the intent
-- pages and the install pages) are added by the site from its page list (web/src/features/trackers/pages.ts).
create or replace function public.sitemap_families() returns jsonb
language sql stable security definer set search_path = public, app as $$
  with s as (select (app.settings()).*),
  ev as (select '/events/' || slug path, updated_at lastmod from seo_events where is_active),
  ap as (select '/airport-car-rental/' || lower(code) path, updated_at lastmod from airports where is_active),
  pop as (select y.make_slug, y.model_slug, y.year::integer y from vehicle_catalog_popular p join vehicle_catalog_years y on y.make_slug = p.make_slug and y.model_slug = p.model_slug
           where y.year >= greatest(extract(year from now())::integer - 11, (select vpage_min_year from s))),
  cities as (select p.slug from places p, s where p.kind = 5 and app.place_enabled(p) and app.place_km(p) <= s.place_delivery_reach_km order by app.place_km(p) limit 20),
  rvo as (select '/rent-vs-own/' || make_slug || '/' || model_slug || '/' || y path, null::timestamptz lastmod from pop
          union all
          select '/rent-vs-own/' || make_slug || '/' || model_slug || '/' || y || '/' || c.slug, null from pop, cities c where pop.y >= extract(year from now())::integer - 2),
  hubs as (select x path, null::timestamptz lastmod from unnest(array['/events', '/airport-car-rental', '/rent-vs-own']) x
           union all select '/trackers', null from s where s.tracker_product_enabled)
  select coalesce(jsonb_agg(jsonb_build_object('path', path, 'lastmod', lastmod)), '[]'::jsonb) from (select * from hubs union all select * from ev union all select * from ap union all select * from rvo limit 45000) a
$$;

-- ================================================================ 5. privileges
do $$
declare f record;
begin
  for f in
    select p.oid::regprocedure as sig from pg_proc p join pg_namespace n on n.oid = p.pronamespace
     where (n.nspname = 'app' and p.proname = any (array['tracker_monthly_cents', 'submit_tracker_waitlist', 'sl_source_pre3231', 'notification_recipients_pre3231']))
        or (n.nspname = 'public' and p.proname in ('submit_tracker_waitlist', 'tracker_install_places'))
  loop
    execute format('revoke all on function %s from public, anon, authenticated', f.sig);
    execute format('grant execute on function %s to service_role', f.sig);
  end loop;
end $$;
