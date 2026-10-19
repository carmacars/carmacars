-- 0061: search (October 19, 2026). The owner's goal: carmacars.ca ranks for car rental searches in Toronto and the
-- GTA, and no person types listing copy.
--
--   1  settings: search engine verification (Google, Bing), the IndexNow key, the business name, address and phone
--      (NAP) for the business listings, the business description and categories, the checklist of listings; the
--      Workers AI budget for search copy, the landing page threshold, the rating threshold, the Google review delay
--   2  car copy written by Workers AI from each real car's facts (car_copy): a fixed structure, checked by the server
--      (web/src/features/seo/copy.ts) and again here, published when it passes, written again when the facts change
--      (a field an Admin edits is locked and kept); a plain copy from the facts in the meantime, never typed
--   3  landing pages (seo_pages): locations and uses, each with its matching live cars, indexable only for a location
--      or with enough real matching cars
--   4  articles (/guides): written, checked and published with their facts; editable in Admin
--   5  IndexNow: the addresses that changed, sent by the search job (Bing, Yandex and the other IndexNow engines)
--   6  the Google review request: a while after a completed rental, under the same rules as the on-site request
--   7  public reads: the car page's copy, reviews and rating summary, landing pages, articles, the sitemaps
--   8  the door: Admin > Settings > Site (business listings), Admin > Settings > Search, the car copy on the listing
-- Fixed names here are the names of settings; values a person may change live in site_settings or program_settings.

-- ================================================================ 1. settings
alter table site_settings
  add column if not exists google_site_verification text check (google_site_verification is null or google_site_verification ~ '^[A-Za-z0-9_-]{10,120}$'),
  add column if not exists google_verification_file text check (google_verification_file is null or google_verification_file ~ '^google[a-z0-9]{6,40}\.html$'),
  add column if not exists bing_site_verification text check (bing_site_verification is null or bing_site_verification ~ '^[A-Za-z0-9]{16,64}$'),
  add column if not exists indexnow_key text not null default md5(gen_random_uuid()::text) check (indexnow_key ~ '^[a-f0-9]{32}$'),
  add column if not exists business_name text,
  add column if not exists business_street text,
  add column if not exists business_city text,
  add column if not exists business_region text,
  add column if not exists business_postal_code text,
  add column if not exists business_latitude numeric(9, 6) check (business_latitude between -90 and 90),
  add column if not exists business_longitude numeric(9, 6) check (business_longitude between -180 and 180),
  add column if not exists business_categories text[] not null default array['Car rental agency'],
  add column if not exists business_description text,
  add column if not exists business_listings jsonb not null default '{}'::jsonb check (jsonb_typeof(business_listings) = 'object');
comment on column site_settings.google_site_verification is 'Google Search Console: the content of the google-site-verification meta tag (HTML tag method). Added to every page''s head.';
comment on column site_settings.google_verification_file is 'Google Search Console: the file name of the HTML file method, for example google1234abcd.html. The site answers it at its root.';
comment on column site_settings.bing_site_verification is 'Bing Webmaster Tools: the content of the msvalidate.01 meta tag.';
comment on column site_settings.indexnow_key is 'IndexNow key (Bing, Yandex and the other IndexNow engines). The site answers /<key>.txt with it. Made once; change it only if it leaked.';
comment on column site_settings.business_name is 'Name on Google Business Profile, Bing Places, Apple Business Connect and directories (NAP). Exactly the brand, nothing added.';
comment on column site_settings.business_street is 'Street address used in the structured data and the business listings (NAP)';
comment on column site_settings.business_latitude is 'Map position of the business address, for the structured data (geo). Empty: left out.';
comment on column site_settings.business_categories is 'Business categories for the listings, primary first (Google: as few as possible)';
comment on column site_settings.business_description is 'The business description for Google Business Profile and the directories (750 characters at most on Google)';
comment on column site_settings.business_listings is 'Admin > Settings > Site, Business listings: per platform {done, url, at, by}';

update site_settings set
  business_name = coalesce(business_name, brand_name),
  business_street = coalesce(business_street, '2967 Dundas St W, Unit 208B'),
  business_city = coalesce(business_city, 'Toronto'),
  business_region = coalesce(business_region, 'ON'),
  business_postal_code = coalesce(business_postal_code, 'M6P 1Z2'),
  business_description = coalesce(business_description,
    'CarmaCars is a car rental company in Toronto. Pick a car on carmacars.ca, send a request with no payment, and we confirm the price and the car before you pay. '
    || 'Rent by the day, the week or the month, with delivery to your door, to Pearson and Billy Bishop airports, or pickup from our location. '
    || 'Every rental includes third-party liability coverage and roadside assistance. Drivers 18 and older with a G or G2 licence can rent.');

alter table program_settings
  add column if not exists seo_ai_daily_neurons integer not null default 4000 check (seo_ai_daily_neurons >= 0),
  add column if not exists seo_copy_max_attempts integer not null default 3 check (seo_copy_max_attempts between 1 and 6),
  add column if not exists seo_copy_retry_hours integer not null default 6 check (seo_copy_retry_hours between 1 and 168),
  add column if not exists seo_copy_similarity_max_bps integer not null default 5000 check (seo_copy_similarity_max_bps between 1000 and 10000),
  add column if not exists seo_landing_min_real_cars integer not null default 2 check (seo_landing_min_real_cars >= 1),
  add column if not exists seo_rating_min_reviews integer not null default 3 check (seo_rating_min_reviews >= 1),
  add column if not exists google_review_delay_days integer not null default 3 check (google_review_delay_days between 1 and 30),
  add column if not exists indexnow_enabled boolean not null default true;
comment on column program_settings.seo_ai_daily_neurons is 'Search copy (cars, landing pages, articles): Workers AI neurons per Toronto day. Also stops once every Workers AI use of the day reaches chat_ai_total_daily_neurons.';
comment on column program_settings.seo_copy_max_attempts is 'Search copy: how many times one run asks the model again (naming the problems) before keeping the current text';
comment on column program_settings.seo_copy_retry_hours is 'Search copy: after a run whose every attempt failed, the hours before the next run tries again';
comment on column program_settings.seo_copy_similarity_max_bps is 'Car copy: the largest share of shared five-word sequences with another car''s copy, in basis points (5000 = 50%)';
comment on column program_settings.seo_landing_min_real_cars is 'Landing pages for a use (monthly, SUV, ...): indexable only with at least this many real matching cars (location pages always)';
comment on column program_settings.seo_rating_min_reviews is 'Car pages: star rating markup only with at least this many published reviews of that car, shown on the page';
comment on column program_settings.google_review_delay_days is 'Days after a booking closes before the Google review request (only when the Google place id is set)';
comment on column program_settings.indexnow_enabled is 'Send changed addresses to IndexNow (production only)';

-- the car copy's structure: a short intro, 3 to 6 highlights, 4 to 6 questions (the owner's decision of October 19)
update program_settings set listing_headline_chars = int4range(20, 71), listing_description_words = int4range(40, 161),
       listing_features_count = int4range(3, 13)
 where id = (app.settings()).id or effective_from > app.today();
alter table program_settings alter column listing_headline_chars set default int4range(20, 71),
  alter column listing_description_words set default int4range(40, 161), alter column listing_features_count set default int4range(3, 13);
update program_settings set listing_banned_phrases = (select array_agg(distinct x order by x) from unnest(listing_banned_phrases || array[
    'look no further', 'elevate', 'seamless', 'whether you are', 'unparalleled', 'best in class', 'unleash', 'nestled', 'boasts', 'delve',
    'testament', 'embark', 'game changer', 'game-changer', 'unforgettable', 'effortless', 'in today''s', 'look no', 'top-notch', 'second to none',
    'hidden gem', 'must-have', 'dream car', 'thrill', 'exhilarating', 'world-class', 'cutting-edge', 'state-of-the-art', 'breathtaking',
    'luxurious ride', 'turn heads', 'head-turning', 'hit the road', 'open road awaits', 'adventure awaits', 'whether you''re', 'unlock']) x)
 where id = (app.settings()).id or effective_from > app.today();

-- ================================================================ 2. car copy
create table car_copy (
  vehicle_id      uuid primary key references vehicles (id) on delete cascade,
  status          text not null default 'pending' check (status in ('pending', 'running', 'published', 'failed')),
  source          text not null default 'template' check (source in ('template', 'ai')),
  facts           jsonb not null default '{}'::jsonb,
  facts_hash      text,
  copy_facts_hash text,                -- the facts the live copy was written from
  copy            jsonb not null default '{}'::jsonb check (jsonb_typeof(copy) = 'object'),
  locked          text[] not null default '{}',
  attempts        integer not null default 0,
  runs            integer not null default 0,
  problems        text[] not null default '{}',
  last_error      text,
  next_attempt_at timestamptz not null default now(),
  locked_at       timestamptz,
  worker          text,
  model           text,
  prompt_version  text,
  neurons         integer not null default 0,
  generated_at    timestamptz,
  published_at    timestamptz,
  requested_by    uuid references users (id),
  asked_at        timestamptz,         -- Write again or Unlock by a person: the next run takes this car first
  edited_by       uuid references users (id),
  edited_at       timestamptz,
  created_at      timestamptz not null default now(),
  updated_at      timestamptz not null default now()
);
create index car_copy_due_idx on car_copy (status, next_attempt_at);
create trigger car_copy_updated before update on car_copy for each row execute function app.set_updated_at();
comment on table car_copy is 'The car page copy written by Workers AI from the car''s facts (0061). copy: seo_title, meta_description, h1, intro, highlights, good_for, included, pickup_delivery, requirements, faq, alt_texts. A locked field is an Admin''s and is never rewritten.';

-- The fields of the copy, in page order.
create or replace function app.car_copy_fields() returns text[]
language sql immutable as $$
  select array['seo_title', 'meta_description', 'h1', 'intro', 'highlights', 'good_for', 'included', 'pickup_delivery', 'requirements', 'faq', 'alt_texts']
$$;

create or replace function app.money_words(p_cents bigint) returns text
language sql immutable as $$
  select case when p_cents is null then null
              when p_cents % 100 = 0 then '$' || to_char(p_cents / 100, 'FM999,999,990')
              else '$' || to_char(p_cents / 100.0, 'FM999,999,990.00') end
$$;

-- Which cars get written copy: real cars with a listing that is not retired, exited or Turo only.
create or replace function app.car_copy_eligible(p_vehicle uuid) returns boolean
language sql stable security definer set search_path = public, app as $$
  select exists (select 1 from vehicles v join vehicle_listings l on l.vehicle_id = v.id
                  where v.id = p_vehicle and not v.is_sample and v.retired_at is null and v.status <> 'exited'
                    and v.management_mode <> 'turo_only' and l.status <> 'unpublished'
                    and v.year is not null and nullif(btrim(v.make), '') is not null and nullif(btrim(v.model), '') is not null)
$$;

-- The facts the copy is written from: the car, its rates in force, where it is, the rules for renters, what every
-- rental includes, its public photos. Nothing private (no VIN, plate, owner, odometer or address). Every number the
-- copy may use is in here; the checks refuse any other.
create or replace function app.car_copy_facts(p_vehicle uuid) returns jsonb
language sql stable security definer set search_path = public, app as $$
  with v as (select * from vehicles where id = p_vehicle),
       l as (select * from vehicle_listings where vehicle_id = p_vehicle),
       rc as (select r.* from rate_cards r where r.vehicle_id = p_vehicle and r.effective_from <= now() and (r.effective_to is null or r.effective_to > now())
              order by r.effective_from desc limit 1),
       s as (select * from site_settings limit 1),
       f as (select public.site_facts() j),
       vd as (select d.* from vin_decodes d join v on upper(d.vin) = upper(v.vin) where d.ok order by d.decoded_at desc limit 1)
  select jsonb_strip_nulls(jsonb_build_object(
    'car', jsonb_build_object(
      'year', v.year, 'make', v.make, 'model', v.model, 'trim', nullif(btrim(v.trim), ''), 'colour', nullif(btrim(v.colour), ''),
      'body_style', coalesce(nullif(btrim(l.body_style), ''), nullif(btrim(v.body_type), '')),
      'seats', l.seats, 'doors', l.doors,
      'fuel', case v.fuel when 'gasoline' then 'Gas' when 'diesel' then 'Diesel' when 'hybrid' then 'Hybrid' when 'plug_in_hybrid' then 'Plug-in hybrid'
                          when 'electric' then 'Electric' end,
      'transmission', nullif(btrim(l.transmission), ''), 'drivetrain', coalesce(nullif(btrim(l.drivetrain), ''), vd.drivetrain),
      'luggage', nullif(btrim(l.luggage), ''), 'engine', coalesce(l.specs ->> 'engine', vd.engine),
      'consumption', l.specs ->> 'consumption', 'range', l.specs ->> 'range',
      'equipment', case when jsonb_typeof(l.specs -> 'equipment') = 'array' then l.specs -> 'equipment' end,
      'classes', (select jsonb_agg(c.label order by c.sort_order) from vehicle_classes c where c.code = any (app.vehicle_class_list(v.id)))),
    'prices', case when rc.id is not null then jsonb_build_object(
      'daily', app.money_words(rc.daily_rate_cents), 'weekend_day', app.money_words(rc.weekend_rate_cents),
      'weekly', app.money_words(rc.weekly_rate_cents), 'monthly', app.money_words(rc.monthly_rate_cents),
      'monthly_days', (f.j ->> 'max_rental_days')::integer, 'km_per_day', rc.km_allowance_per_day,
      'extra_km', app.money_words(rc.overage_cents_per_km), 'deposit', app.money_words(rc.deposit_cents),
      'delivery_fee', app.money_words(rc.delivery_fee_cents), 'return_pickup_fee', app.money_words(rc.pickup_fee_cents),
      'tax', 'HST ' || app.fmt_pct((f.j ->> 'hst_bps')::integer) || ' added') end,
    'place', jsonb_build_object('area', coalesce(nullif(btrim(l.home_area), ''), s.city), 'city', s.city, 'region', s.region,
      'delivery', 'Delivered to any address for the car''s delivery fee' || case when (f.j ->> 'delivery_per_km_cents')::integer > 0 then ' plus distance' else '' end,
      'airports', (select jsonb_agg(a ->> 'name') from jsonb_array_elements(f.j -> 'airports') a),
      'pickup', 'Collect it at our location at no charge, or have it delivered'),
    'rules', jsonb_build_object(
      'min_age', (f.j ->> 'min_renter_age')::integer,
      'young_driver_fee_ages', (select jsonb_agg((b ->> 'from_age') || ' to ' || (b ->> 'to_age')) from jsonb_array_elements(f.j -> 'young_driver_bands') b
                                 where v.allows_18_to_20 or (b ->> 'from_age')::integer >= 21),
      'drivers_18_to_20', v.allows_18_to_20,
      'licence', 'Ontario ' || array_to_string(array(select jsonb_array_elements_text(f.j -> 'accepted_licence_classes')), ' or ') || ' licence',
      'card', 'A credit card in the renter''s name', 'identity', 'Licence and identity checked before pickup',
      'max_rental_days', (f.j ->> 'max_rental_days')::integer, 'request', 'Request to book with no payment; pay after we confirm'),
    'included', jsonb_build_array('Third-party liability coverage', 'Roadside assistance, 24 hours a day',
      case when rc.km_allowance_per_day is not null then rc.km_allowance_per_day || ' km a day' end, 'Handover in person with a walk-around of the car'),
    'photos', (select jsonb_agg(distinct ph.shot_type order by ph.shot_type) from vehicle_photos ph
                where ph.vehicle_id = v.id and ph.is_public and ph.status = 'approved' and ph.replaced_at is null),
    'staff_note', nullif(btrim(l.staff_note), ''),
    'brand', s.brand_name))
    from v left join l on true left join rc on true cross join s cross join f left join vd on true
$$;

-- A plain copy from the facts alone, used until the AI copy is published (and kept if the model is unavailable for
-- days). It passes the same checks.
create or replace function app.car_copy_template(p_facts jsonb) returns jsonb
language plpgsql immutable as $$
declare
  c jsonb := coalesce(p_facts -> 'car', '{}'::jsonb);
  pr jsonb := coalesce(p_facts -> 'prices', '{}'::jsonb);
  pl jsonb := coalesce(p_facts -> 'place', '{}'::jsonb);
  ru jsonb := coalesce(p_facts -> 'rules', '{}'::jsonb);
  v_name text := concat_ws(' ', c ->> 'year', c ->> 'make', c ->> 'model');
  v_full text := concat_ws(' ', c ->> 'year', c ->> 'make', c ->> 'model', c ->> 'trim');
  v_body text := lower(coalesce(c ->> 'body_style', 'car'));
  v_city text := coalesce(pl ->> 'city', 'Toronto');
  v_area text := coalesce(pl ->> 'area', v_city);
  v_brand text := coalesce(p_facts ->> 'brand', 'CarmaCars');
  v_h1 text;
  v_title text;
  v_desc text;
  v_intro text;
  v_alt jsonb := '{}'::jsonb;
  k text;
begin
  v_h1 := v_full || ' rental in ' || v_city;
  if length(v_h1) > 70 then v_h1 := v_name || ' rental in ' || v_city; end if;
  v_title := 'Rent a ' || v_name || ' in ' || v_city;
  if length(v_title || ' | ' || v_brand) <= 60 then v_title := v_title || ' | ' || v_brand; end if;
  if length(v_title) > 60 then v_title := left(v_name || ' rental ' || v_city, 60); end if;
  v_desc := 'Rent this ' || coalesce(lower(c ->> 'colour') || ' ', '') || v_name || ' in ' || v_city
            || coalesce(' from ' || (pr ->> 'daily') || ' a day', '') || '. '
            || coalesce((c ->> 'seats') || ' seats, ', '') || coalesce(lower(c ->> 'transmission') || '. ', '')
            || 'Request with no payment up front.';
  if length(v_desc) > 155 then v_desc := 'Rent this ' || v_name || ' in ' || v_city || coalesce(' from ' || (pr ->> 'daily') || ' a day', '') || '. Request with no payment up front.'; end if;
  v_intro := 'This ' || v_full || ' is a ' || coalesce(lower(c ->> 'colour') || ' ', '') || v_body
             || coalesce(' with ' || (c ->> 'seats') || ' seats', '') || coalesce(' and an ' || lower(c ->> 'transmission') || ' transmission', '') || '. '
             || 'It is kept in ' || v_area || ', and you can collect it from our location or have it delivered to your door. '
             || coalesce('It costs ' || (pr ->> 'daily') || ' a day, ' || (pr ->> 'weekly') || ' for a week or ' || (pr ->> 'monthly') || ' for ' || (pr ->> 'monthly_days') || ' days, plus HST. ', '')
             || coalesce((pr ->> 'km_per_day') || ' km a day are included. ', '')
             || 'Send a request with your dates. We confirm the car and the price before you pay anything.';
  if jsonb_typeof(p_facts -> 'photos') = 'array' then
    for k in select jsonb_array_elements_text(p_facts -> 'photos') loop
      v_alt := v_alt || jsonb_build_object(k, v_full || coalesce(' in ' || lower(c ->> 'colour'), '') || ', ' || replace(k, '_', ' ') || ' view');
    end loop;
  end if;
  return jsonb_build_object(
    'seo_title', v_title, 'meta_description', v_desc, 'h1', v_h1, 'intro', v_intro,
    'highlights', to_jsonb(array_remove(array[
        case when c ? 'seats' then (c ->> 'seats') || ' seats' end,
        case when c ? 'transmission' then (c ->> 'transmission') || ' transmission' end,
        case when c ? 'fuel' then (c ->> 'fuel') || case when c ->> 'fuel' = 'Electric' then ' power' else ' engine' end end,
        case when c ? 'drivetrain' then (c ->> 'drivetrain') end,
        case when pr ? 'km_per_day' then (pr ->> 'km_per_day') || ' km a day included' end], null)),
    'good_for', jsonb_build_array('Trips in and around ' || v_city, 'Weekly and monthly rentals'),
    'included', coalesce(p_facts -> 'included', '[]'::jsonb),
    'pickup_delivery', 'The car is kept in ' || v_area || '. Collect it at our location at no charge, or we deliver it to your address'
                       || coalesce(' for ' || (pr ->> 'delivery_fee'), '') || '. We hand it over in person and walk around the car with you.',
    'requirements', to_jsonb(array_remove(array[
        case when ru ? 'min_age' then 'Drivers ' || (ru ->> 'min_age') || ' or older' end, ru ->> 'licence', ru ->> 'card', ru ->> 'identity'], null)),
    'faq', jsonb_build_array(
      jsonb_build_object('question', 'How many people fit in the ' || (c ->> 'model') || '?',
        'answer', coalesce('It has ' || (c ->> 'seats') || ' seats.', 'Ask us before you book.')),
      jsonb_build_object('question', 'Where do I pick up the ' || (c ->> 'model') || '?',
        'answer', 'At our location at no charge, or we deliver it to your address' || coalesce(' for ' || (pr ->> 'delivery_fee'), '') || '.'),
      jsonb_build_object('question', 'How many kilometres are included?',
        'answer', coalesce((pr ->> 'km_per_day') || ' km for each day of the rental.', 'The allowance is shown with the rates.')),
      jsonb_build_object('question', 'Do I pay when I send a request?',
        'answer', 'No. We confirm the car and the price first, and you pay only when you approve.')),
    'alt_texts', v_alt);
end $$;

-- The checks the database applies to a copy before it goes live (the server's checks are stricter: invented
-- numbers, similarity, banned words and the brand). Returns the problems in words.
create or replace function app.car_copy_problems(p_copy jsonb) returns text[]
language plpgsql stable security definer set search_path = public, app as $$
declare
  v_out text[] := '{}';
  v_all text := lower(coalesce(p_copy::text, ''));
  v_phrase text;
  k text;
begin
  foreach k in array array['seo_title', 'meta_description', 'h1', 'intro', 'pickup_delivery'] loop
    if nullif(btrim(coalesce(p_copy ->> k, '')), '') is null then v_out := v_out || format('%s is empty', k); end if;
  end loop;
  foreach k in array array['highlights', 'included', 'requirements', 'faq'] loop
    if jsonb_typeof(p_copy -> k) is distinct from 'array' or jsonb_array_length(p_copy -> k) = 0 then v_out := v_out || format('%s is empty', k); end if;
  end loop;
  if length(coalesce(p_copy ->> 'seo_title', '')) > 60 then v_out := v_out || 'The search title is over 60 characters'::text; end if;
  if length(coalesce(p_copy ->> 'meta_description', '')) > 155 then v_out := v_out || 'The search description is over 155 characters'::text; end if;
  if length(coalesce(p_copy ->> 'h1', '')) > 70 then v_out := v_out || 'The heading is over 70 characters'::text; end if;
  if position(chr(8212) in v_all) > 0 or position(chr(8211) in v_all) > 0 then v_out := v_out || 'Remove the long dash'::text; end if;
  if v_all ~ '18122211|canada inc' then v_out := v_out || 'The numbered company is never named'::text; end if;
  foreach v_phrase in array (app.settings()).listing_banned_phrases loop
    if position(lower(v_phrase) in v_all) > 0 then v_out := v_out || format('Remove the phrase "%s"', v_phrase); end if;
  end loop;
  return v_out;
end $$;

-- Put a copy live: the fields an Admin locked keep their text; the listing's headline, description, highlights,
-- questions and search text follow it, and each public photo gets its alt text. A listing approved and waiting for
-- its copy is published now. The car's address goes to IndexNow.
create or replace function app.car_copy_apply(p_vehicle uuid, p_copy jsonb, p_source text, p_facts_hash text default null) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  cc car_copy;
  v_new jsonb := coalesce(p_copy, '{}'::jsonb);
  k text;
  v_problems text[];
  l vehicle_listings;
  i listing_intakes;
begin
  select * into cc from car_copy where vehicle_id = p_vehicle for update;
  if cc.vehicle_id is null then
    insert into car_copy (vehicle_id) values (p_vehicle) returning * into cc;
  end if;
  foreach k in array cc.locked loop
    if cc.copy ? k then v_new := v_new || jsonb_build_object(k, cc.copy -> k); end if;
  end loop;
  v_new := (select coalesce(jsonb_object_agg(e.key, e.value), '{}'::jsonb) from jsonb_each(v_new) e where e.key = any (app.car_copy_fields()));
  v_problems := app.car_copy_problems(v_new);
  if cardinality(v_problems) > 0 then
    raise exception 'The copy is not ready: %', array_to_string(v_problems, '; ') using errcode = '23514';
  end if;
  update car_copy set copy = v_new, source = p_source, status = 'published', published_at = now(), problems = '{}', last_error = null,
         attempts = 0, locked_at = null, worker = null, copy_facts_hash = coalesce(p_facts_hash, facts_hash),
         generated_at = case when p_source = 'ai' then now() else generated_at end
   where vehicle_id = p_vehicle;
  perform app.ensure_listing(p_vehicle);
  update vehicle_listings set
    headline = v_new ->> 'h1', description = v_new ->> 'intro',
    features = coalesce((select array_agg(x) from jsonb_array_elements_text(v_new -> 'highlights') x), '{}'),
    faq = coalesce((select jsonb_agg(jsonb_build_object('question', e ->> 'question', 'answer', e ->> 'answer', 'check', false)) from jsonb_array_elements(v_new -> 'faq') e), '[]'::jsonb),
    seo_title = v_new ->> 'seo_title', seo_description = v_new ->> 'meta_description', needs_rewrite = false
   where vehicle_id = p_vehicle
  returning * into l;
  if jsonb_typeof(v_new -> 'alt_texts') = 'object' then
    update vehicle_photos ph set alt_text = left(v_new -> 'alt_texts' ->> ph.shot_type, 200)
     where ph.vehicle_id = p_vehicle and ph.replaced_at is null and nullif(btrim(v_new -> 'alt_texts' ->> ph.shot_type), '') is not null
       and ph.alt_text is distinct from left(v_new -> 'alt_texts' ->> ph.shot_type, 200);
  end if;
  if l.status in ('published', 'paused') and l.slug is not null then
    perform app.indexnow_queue_path('/cars/' || l.slug, 'car copy');
  end if;
  -- an approved listing that waited for its copy goes live now
  select * into i from listing_intakes where vehicle_id = p_vehicle and state = 'approved' order by created_at desc limit 1;
  if i.id is not null and l.status not in ('published', 'paused') then
    begin
      perform app.publish_listing(p_vehicle, null);
    exception when sqlstate '23514' or sqlstate '42501' or sqlstate 'P0002' then
      null;
    end;
  end if;
  return jsonb_build_object('vehicle_id', p_vehicle, 'status', 'published', 'source', p_source);
end $$;

-- Bring every real car's copy in step with its facts: a new car gets its row (and the plain copy at once when its
-- listing has no text yet); a car whose facts changed is written again. Run by every claim of the search job.
create or replace function app.car_copy_scan() returns integer
language plpgsql security definer set search_path = public, app as $$
declare
  r record;
  v_facts jsonb;
  v_hash text;
  cc car_copy;
  n integer := 0;
begin
  -- one scan at a time (the five-minute tick, a click on Write again and an edit can meet)
  perform pg_advisory_xact_lock(hashtext('carmacars:car_copy_scan'));
  for r in select v.id from vehicles v join vehicle_listings l on l.vehicle_id = v.id where app.car_copy_eligible(v.id) loop
    v_facts := app.car_copy_facts(r.id);
    v_hash := md5(v_facts::text);
    insert into car_copy (vehicle_id, facts, facts_hash, status, next_attempt_at) values (r.id, v_facts, v_hash, 'pending', now())
    on conflict (vehicle_id) do nothing;
    if found then n := n + 1; end if;
    select * into cc from car_copy where vehicle_id = r.id for update;
    if cc.facts_hash is distinct from v_hash then
      update car_copy set facts = v_facts, facts_hash = v_hash, attempts = 0, next_attempt_at = now(),
             status = case when status = 'running' and locked_at > now() - interval '10 minutes' then status else 'pending' end
       where vehicle_id = r.id returning * into cc;
      n := n + 1;
    end if;
    -- the plain copy while there is no written copy (or the plain one is out of date)
    if cc.source = 'template' and (cc.copy = '{}'::jsonb or cc.copy_facts_hash is distinct from v_hash) then
      begin
        perform app.car_copy_apply(r.id, app.car_copy_template(v_facts), 'template', v_hash);
        update car_copy set status = 'pending', next_attempt_at = least(next_attempt_at, now()) where vehicle_id = r.id;
      exception when sqlstate '23514' then
        update car_copy set problems = array['The plain copy could not be made: ' || sqlerrm] where vehicle_id = r.id;
      end;
    end if;
  end loop;
  -- a running row left behind by a worker that stopped
  update car_copy set status = 'pending', locked_at = null, worker = null where status = 'running' and locked_at < now() - interval '10 minutes';
  return n;
end $$;

-- ================================================================ 3. landing pages
create table seo_pages (
  slug            text primary key check (slug ~ '^[a-z0-9]+(-[a-z0-9]+)*$'),
  kind            text not null check (kind in ('location', 'use')),
  name            text not null,
  sort_order      integer not null default 100,
  is_active       boolean not null default true,
  facts           jsonb not null default '{}'::jsonb check (jsonb_typeof(facts) = 'object'),
  match           jsonb not null default '{}'::jsonb check (jsonb_typeof(match) = 'object'),
  copy            jsonb not null default '{}'::jsonb check (jsonb_typeof(copy) = 'object'),
  locked          text[] not null default '{}',
  source          text not null default 'seed' check (source in ('seed', 'ai', 'staff')),
  status          text not null default 'published' check (status in ('pending', 'running', 'published', 'failed')),
  facts_hash      text,
  copy_facts_hash text,
  attempts        integer not null default 0,
  problems        text[] not null default '{}',
  last_error      text,
  next_attempt_at timestamptz not null default now(),
  locked_at       timestamptz,
  model           text,
  prompt_version  text,
  generated_at    timestamptz,
  content_updated_at timestamptz not null default now(),
  updated_by      uuid references users (id),
  created_at      timestamptz not null default now(),
  updated_at      timestamptz not null default now()
);
create trigger seo_pages_updated before update on seo_pages for each row execute function app.set_updated_at();
comment on table seo_pages is 'Landing pages at /car-rental/<slug> (0061). facts: what the copy may say about the place or use; match: which live cars it lists (classes, fuels, seats_min, young, all); copy: seo_title, meta_description, h1, intro, sections [{heading, body}], faq. Rows are added by the content seed and edited in Admin > Settings > Search.';

create or replace function app.seo_page_before() returns trigger
language plpgsql security definer set search_path = public, app as $$
begin
  new.facts_hash := md5(jsonb_build_object('name', new.name, 'kind', new.kind, 'facts', new.facts)::text);
  if tg_op = 'INSERT' then
    new.copy_facts_hash := coalesce(new.copy_facts_hash, case when new.copy <> '{}'::jsonb then new.facts_hash end);
    if new.copy = '{}'::jsonb then new.status := 'pending'; end if;
  elsif new.copy is distinct from old.copy or new.is_active is distinct from old.is_active or new.name is distinct from old.name then
    new.content_updated_at := now();
  end if;
  -- facts changed since the copy was written: write it again (locked fields are kept)
  if new.copy_facts_hash is distinct from new.facts_hash and new.status in ('published', 'failed') and new.copy <> '{}'::jsonb then
    new.status := 'pending'; new.next_attempt_at := now(); new.attempts := 0;
  end if;
  return new;
end $$;
create trigger seo_pages_before before insert or update on seo_pages for each row execute function app.seo_page_before();

create or replace function app.seo_page_path(p_slug text) returns text
language sql immutable as $$ select '/car-rental/' || p_slug $$;

-- The live cars a landing page lists (match: {} all; classes; fuels; seats_min; young = cars taking drivers 18 to 20),
-- cheapest first. A sample car is listed but never counts toward indexing.
create or replace function app.seo_match(r jsonb, m jsonb) returns boolean
language sql immutable as $$
  select coalesce((r ->> 'taking_requests')::boolean, false)
     and (jsonb_typeof(m -> 'classes') is distinct from 'array'
          or exists (select 1 from jsonb_array_elements_text(r -> 'classes') c where c = any (array(select jsonb_array_elements_text(m -> 'classes')))))
     and (jsonb_typeof(m -> 'fuels') is distinct from 'array' or (r ->> 'fuel') = any (array(select jsonb_array_elements_text(m -> 'fuels'))))
     and (m ->> 'seats_min' is null or coalesce((r ->> 'seats')::integer, 0) >= (m ->> 'seats_min')::integer)
     and (not coalesce((m ->> 'young')::boolean, false) or coalesce((r ->> 'allows_18_to_20')::boolean, false))
$$;

create or replace function app.seo_page_cars(p_match jsonb) returns setof jsonb
language sql stable security definer set search_path = public, app as $$
  select r from app.public_fleet('{}'::jsonb) r where app.seo_match(r, p_match) order by (r ->> 'daily_rate_cents')::bigint nulls last
$$;

create or replace function app.seo_counts_of(p_cars jsonb) returns jsonb
language sql immutable as $$
  select jsonb_build_object('car_count', count(*), 'real_cars', count(*) filter (where not coalesce((c ->> 'is_sample')::boolean, false)),
                            'min_daily_cents', min((c ->> 'daily_rate_cents')::bigint), 'min_monthly_cents', min((c ->> 'monthly_rate_cents')::bigint),
                            'min_weekly_cents', min((c ->> 'weekly_rate_cents')::bigint), 'min_delivery_cents', min((c ->> 'delivery_fee_cents')::bigint))
    from jsonb_array_elements(coalesce(p_cars, '[]'::jsonb)) c
$$;

create or replace function app.seo_page_counts(p seo_pages) returns jsonb
language sql stable security definer set search_path = public, app as $$
  select app.seo_counts_of((select coalesce(jsonb_agg(c), '[]'::jsonb) from app.seo_page_cars(p.match) c))
$$;

-- the real cars taking requests that match, counted from the tables (fast: the footer reads it on every page)
create or replace function app.seo_real_count(p_match jsonb) returns integer
language sql stable security definer set search_path = public, app as $$
  select count(*)::integer
    from vehicle_listings l join vehicles v on v.id = l.vehicle_id join public_vehicle_listings pv on pv.vehicle_id = v.id
   where l.status = 'published' and v.management_mode <> 'turo_only' and not v.is_sample
     and (jsonb_typeof(p_match -> 'classes') is distinct from 'array'
          or app.vehicle_class_list(v.id) && array(select jsonb_array_elements_text(p_match -> 'classes')))
     and (jsonb_typeof(p_match -> 'fuels') is distinct from 'array' or v.fuel::text = any (array(select jsonb_array_elements_text(p_match -> 'fuels'))))
     and (p_match ->> 'seats_min' is null or coalesce(l.seats, 0) >= (p_match ->> 'seats_min')::integer)
     and (not coalesce((p_match ->> 'young')::boolean, false) or v.allows_18_to_20)
$$;

create or replace function app.seo_page_indexable(p seo_pages) returns boolean
language sql stable security definer set search_path = public, app as $$
  select p.is_active and p.copy <> '{}'::jsonb
     and (p.kind = 'location' or app.seo_real_count(p.match) >= (app.settings()).seo_landing_min_real_cars)
$$;

-- the links of every page that may be indexed (the footer and the hub's lists)
create or replace function app.public_seo_links() returns jsonb
language sql stable security definer set search_path = public, app as $$
  select coalesce(jsonb_agg(jsonb_build_object('slug', p.slug, 'kind', p.kind, 'name', p.name, 'path', app.seo_page_path(p.slug))
                            order by p.kind, p.sort_order, p.name), '[]'::jsonb)
    from seo_pages p where app.seo_page_indexable(p)
$$;

-- every active page with its counts, the fleet read once: the hub page
create or replace function app.public_seo_pages() returns jsonb
language sql stable security definer set search_path = public, app as $$
  with f as materialized (select r from app.public_fleet('{}'::jsonb) r),
       x as (select p, app.seo_counts_of((select coalesce(jsonb_agg(f.r), '[]'::jsonb) from f where app.seo_match(f.r, p.match))) as n
               from seo_pages p where p.is_active and p.copy <> '{}'::jsonb)
  select coalesce(jsonb_agg(jsonb_build_object('slug', (x.p).slug, 'kind', (x.p).kind, 'name', (x.p).name, 'path', app.seo_page_path((x.p).slug),
           'h1', (x.p).copy ->> 'h1', 'summary', (x.p).copy ->> 'meta_description', 'indexable', app.seo_page_indexable(x.p),
           'lastmod', (x.p).content_updated_at) || x.n order by (x.p).kind, (x.p).sort_order, (x.p).name), '[]'::jsonb)
    from x
$$;

-- one page with its cars (the car rows of the fleet, read once), its delivery facts and its neighbours
create or replace function app.public_seo_page(p_slug text) returns jsonb
language sql stable security definer set search_path = public, app as $$
  with p as (select * from seo_pages where slug = lower(btrim(p_slug)) and is_active and copy <> '{}'::jsonb),
       c as (select coalesce(jsonb_agg(r order by (r ->> 'daily_rate_cents')::bigint nulls last), '[]'::jsonb) as cars
               from app.public_fleet('{}'::jsonb) r, p where app.seo_match(r, p.match))
  select jsonb_build_object('slug', p.slug, 'kind', p.kind, 'name', p.name, 'path', app.seo_page_path(p.slug), 'copy', p.copy,
           'facts', p.facts, 'indexable', app.seo_page_indexable(p), 'lastmod', p.content_updated_at,
           'cars', (select coalesce(jsonb_agg(e.v order by e.n), '[]'::jsonb) from jsonb_array_elements(c.cars) with ordinality e(v, n) where e.n <= 24),
           'airport', case when p.facts ? 'airport_code' then (select jsonb_build_object('code', a.code, 'name', a.name, 'surcharge_cents', a.surcharge_cents)
                                                               from airports a where a.code = p.facts ->> 'airport_code' and a.is_active) end,
           'delivery_per_km_cents', (app.settings()).delivery_per_km_cents,
           'distance_km', case when (app.settings()).company_latitude is not null and p.facts ? 'lat'
                               then round(app.distance_km((app.settings()).company_latitude, (app.settings()).company_longitude,
                                                          (p.facts ->> 'lat')::numeric, (p.facts ->> 'lng')::numeric), 0) end,
           'nearby', (select coalesce(jsonb_agg(jsonb_build_object('slug', n.slug, 'name', n.name, 'path', app.seo_page_path(n.slug)) order by n.sort_order), '[]'::jsonb)
                        from seo_pages n where n.slug <> p.slug and n.kind = p.kind
                          and (jsonb_typeof(p.facts -> 'nearby') is distinct from 'array' or n.slug = any (array(select jsonb_array_elements_text(p.facts -> 'nearby'))))
                          and app.seo_page_indexable(n)),
           'other', (select coalesce(jsonb_agg(jsonb_build_object('slug', n.slug, 'name', n.name, 'path', app.seo_page_path(n.slug)) order by n.sort_order), '[]'::jsonb)
                        from seo_pages n where n.kind <> p.kind and app.seo_page_indexable(n)
                          and (jsonb_typeof(p.facts -> 'nearby') is distinct from 'array' or n.slug = any (array(select jsonb_array_elements_text(p.facts -> 'nearby'))))))
         || app.seo_counts_of(c.cars)
    from p, c
$$;

-- ================================================================ 4. articles (/guides)
create table articles (
  slug            text primary key check (slug ~ '^[a-z0-9]+(-[a-z0-9]+)*$'),
  title           text not null check (length(title) between 10 and 110),
  seo_title       text check (seo_title is null or length(seo_title) <= 60),
  description     text not null check (length(description) between 50 and 160),
  summary         text,
  body_md         text not null,
  faq             jsonb not null default '[]'::jsonb check (jsonb_typeof(faq) = 'array'),
  links           jsonb not null default '[]'::jsonb check (jsonb_typeof(links) = 'array'),
  topic           text,
  author_name     text,
  sort_order      integer not null default 100,
  is_published    boolean not null default true,
  locked          text[] not null default '{}',
  source          text not null default 'seed' check (source in ('seed', 'ai', 'staff')),
  status          text not null default 'published' check (status in ('pending', 'running', 'published', 'failed')),
  brief           text,
  attempts        integer not null default 0,
  problems        text[] not null default '{}',
  last_error      text,
  next_attempt_at timestamptz not null default now(),
  locked_at       timestamptz,
  model           text,
  prompt_version  text,
  generated_at    timestamptz,
  published_at    timestamptz not null default now(),
  content_updated_at timestamptz not null default now(),
  updated_by      uuid references users (id),
  created_at      timestamptz not null default now(),
  updated_at      timestamptz not null default now()
);
create trigger articles_updated before update on articles for each row execute function app.set_updated_at();
comment on table articles is 'Articles at /guides/<slug> (0061): Markdown with {{tokens}} filled from settings when the page is built, so a fee or a rule in an article is always the live one. brief: what a rewrite must cover. Edited in Admin > Settings > Search.';

create or replace function app.article_before() returns trigger
language plpgsql security definer set search_path = public, app as $$
begin
  if tg_op = 'UPDATE' and (new.title, new.description, new.body_md, new.faq, new.is_published, new.seo_title)
                          is distinct from (old.title, old.description, old.body_md, old.faq, old.is_published, old.seo_title) then
    new.content_updated_at := now();
  end if;
  return new;
end $$;
create trigger articles_before before update on articles for each row execute function app.article_before();

create or replace function app.public_articles() returns jsonb
language sql stable security definer set search_path = public, app as $$
  select coalesce(jsonb_agg(jsonb_build_object('slug', a.slug, 'title', a.title, 'description', a.description, 'summary', a.summary, 'topic', a.topic,
           'path', '/guides/' || a.slug, 'published_at', a.published_at, 'updated_at', a.content_updated_at) order by a.sort_order, a.title), '[]'::jsonb)
    from articles a where a.is_published
$$;
create or replace function app.public_article(p_slug text) returns jsonb
language sql stable security definer set search_path = public, app as $$
  select jsonb_build_object('slug', a.slug, 'title', a.title, 'seo_title', a.seo_title, 'description', a.description, 'summary', a.summary,
           'body_md', a.body_md, 'faq', a.faq, 'links', a.links, 'topic', a.topic, 'author_name', a.author_name,
           'path', '/guides/' || a.slug, 'published_at', a.published_at, 'updated_at', a.content_updated_at,
           'related', (select coalesce(jsonb_agg(jsonb_build_object('slug', x.slug, 'title', x.title, 'path', '/guides/' || x.slug) order by x.sort_order), '[]'::jsonb)
                         from (select * from articles r where r.is_published and r.slug <> a.slug order by (r.topic is not distinct from a.topic) desc, r.sort_order limit 3) x))
    from articles a where a.slug = lower(btrim(p_slug)) and a.is_published
$$;

-- ================================================================ 5. IndexNow
create table indexnow_queue (
  path        text primary key check (path ~ '^/[a-z0-9/._-]*$'),
  reason      text,
  queued_at   timestamptz not null default now(),
  sent_at     timestamptz,
  attempts    integer not null default 0,
  last_status integer,
  last_error  text
);
create index indexnow_queue_due_idx on indexnow_queue (sent_at, queued_at);
comment on table indexnow_queue is 'Addresses whose content changed, sent to IndexNow by the search job (0061). A path queued again after it was sent is sent again.';

create or replace function app.indexnow_queue_path(p_path text, p_reason text default null) returns void
language sql security definer set search_path = public, app as $$
  insert into indexnow_queue (path, reason) values (p_path, p_reason)
  on conflict (path) do update set queued_at = now(), sent_at = null, attempts = 0, reason = excluded.reason
$$;

-- a car that goes on or off the site, a landing page or an article that changes
create or replace function app.indexnow_on_listing() returns trigger
language plpgsql security definer set search_path = public, app as $$
begin
  if new.slug is not null and (new.status is distinct from old.status) and (new.status in ('published', 'unpublished') or old.status = 'published')
     and not exists (select 1 from vehicles v where v.id = new.vehicle_id and v.is_sample) then
    perform app.indexnow_queue_path('/cars/' || new.slug, 'listing ' || new.status);
    perform app.indexnow_queue_path('/cars', 'fleet');
  end if;
  return null;
end $$;
create trigger vehicle_listings_indexnow after update of status on vehicle_listings for each row execute function app.indexnow_on_listing();

create or replace function app.indexnow_on_page() returns trigger
language plpgsql security definer set search_path = public, app as $$
begin
  if tg_table_name = 'seo_pages' and (tg_op = 'INSERT' or new.content_updated_at is distinct from old.content_updated_at) then
    perform app.indexnow_queue_path(app.seo_page_path(new.slug), 'landing page');
  elsif tg_table_name = 'articles' and (tg_op = 'INSERT' or new.content_updated_at is distinct from old.content_updated_at) then
    perform app.indexnow_queue_path('/guides/' || new.slug, 'article');
    perform app.indexnow_queue_path('/guides', 'articles');
  end if;
  return null;
end $$;
create trigger seo_pages_indexnow after insert or update on seo_pages for each row execute function app.indexnow_on_page();
create trigger articles_indexnow after insert or update on articles for each row execute function app.indexnow_on_page();

-- ================================================================ 6. the search job: claim and results
create or replace function app.seo_neurons_today() returns jsonb
language sql stable security definer set search_path = public, app as $$
  with day as (select (app.today()::timestamp at time zone 'America/Toronto') t0)
  select jsonb_build_object(
    'seo', (select coalesce(sum(c.units), 0) from provider_calls c, day where c.unit = 'neurons' and c.purpose like 'seo_%' and c.created_at >= day.t0),
    'all', (select coalesce(sum(c.units), 0) from provider_calls c, day where c.unit = 'neurons' and c.created_at >= day.t0),
    'seo_cap', (app.settings()).seo_ai_daily_neurons, 'all_cap', (app.settings()).chat_ai_total_daily_neurons)
$$;

-- What the job does now: the cars, landing pages and articles due (within the day's neurons), each with its facts,
-- locked fields and the copy of similar cars to stay apart from; the IndexNow addresses to send.
create or replace function app.server_seo_claim(p_worker text, p_limit integer default 3) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  ps program_settings := app.settings();
  b jsonb;
  v_ai boolean;
  v_cars jsonb := '[]'::jsonb;
  v_pages jsonb := '[]'::jsonb;
  v_articles jsonb := '[]'::jsonb;
  v_n integer;
  r record;
begin
  v_n := app.car_copy_scan();
  b := app.seo_neurons_today();
  v_ai := (b ->> 'seo')::numeric < ps.seo_ai_daily_neurons and (b ->> 'all')::numeric < ps.chat_ai_total_daily_neurons;
  if v_ai then
    for r in select cc.vehicle_id from car_copy cc
              where (cc.status = 'pending' or (cc.status = 'failed' and cc.next_attempt_at <= now())) and cc.next_attempt_at <= now()
                and app.car_copy_eligible(cc.vehicle_id)
              order by (cc.asked_at is not null) desc, (cc.source = 'template') desc, cc.next_attempt_at
              limit greatest(coalesce(p_limit, 3), 0) for update skip locked loop
      update car_copy set status = 'running', locked_at = now(), worker = p_worker, asked_at = null where vehicle_id = r.vehicle_id;
      v_cars := v_cars || jsonb_build_object('vehicle_id', r.vehicle_id, 'slug', (select l.slug from vehicle_listings l where l.vehicle_id = r.vehicle_id and l.status in ('published', 'paused')),
        'facts', (select facts from car_copy where vehicle_id = r.vehicle_id),
        'locked', (select to_jsonb(locked) from car_copy where vehicle_id = r.vehicle_id),
        'current', (select copy from car_copy where vehicle_id = r.vehicle_id),
        'others', (select coalesce(jsonb_agg(o.copy ->> 'intro'), '[]'::jsonb) from car_copy o join vehicles ov on ov.id = o.vehicle_id, vehicles v
                    where v.id = r.vehicle_id and o.vehicle_id <> r.vehicle_id and o.source = 'ai'
                      and app.slugify(ov.make || ' ' || ov.model) = app.slugify(v.make || ' ' || v.model)),
        'all_intros', (select coalesce(jsonb_agg(o.copy ->> 'intro'), '[]'::jsonb) from car_copy o where o.vehicle_id <> r.vehicle_id and o.source = 'ai'));
    end loop;
    for r in select p.slug from seo_pages p
              where p.is_active and (p.status = 'pending' or (p.status = 'failed' and p.next_attempt_at <= now())) and p.next_attempt_at <= now()
              order by p.next_attempt_at limit 1 for update skip locked loop
      update seo_pages set status = 'running', locked_at = now() where slug = r.slug;
      v_pages := v_pages || (select jsonb_build_object('slug', p.slug, 'kind', p.kind, 'name', p.name, 'facts', p.facts, 'copy', p.copy,
                                     'locked', to_jsonb(p.locked), 'counts', app.seo_page_counts(p), 'city', (select city from site_settings limit 1))
                               from seo_pages p where p.slug = r.slug);
    end loop;
    for r in select a.slug from articles a
              where (a.status = 'pending' or (a.status = 'failed' and a.next_attempt_at <= now())) and a.next_attempt_at <= now()
              order by a.next_attempt_at limit 1 for update skip locked loop
      update articles set status = 'running', locked_at = now() where slug = r.slug;
      v_articles := v_articles || (select jsonb_build_object('slug', a.slug, 'title', a.title, 'description', a.description, 'brief', a.brief,
                                           'body_md', a.body_md, 'faq', a.faq, 'locked', to_jsonb(a.locked)) from articles a where a.slug = r.slug);
    end loop;
  end if;
  update seo_pages set status = 'pending', locked_at = null where status = 'running' and locked_at < now() - interval '10 minutes';
  update articles set status = 'pending', locked_at = null where status = 'running' and locked_at < now() - interval '10 minutes';
  return jsonb_build_object('cars', v_cars, 'pages', v_pages, 'articles', v_articles, 'scanned', v_n, 'budget', b, 'ai', v_ai,
    'max_attempts', ps.seo_copy_max_attempts, 'similarity_max_bps', ps.seo_copy_similarity_max_bps, 'banned', to_jsonb(ps.listing_banned_phrases),
    'indexnow', jsonb_build_object('enabled', ps.indexnow_enabled, 'key', (select indexnow_key from site_settings limit 1),
      'paths', (select coalesce(jsonb_agg(q.path order by q.queued_at), '[]'::jsonb) from (select path, queued_at from indexnow_queue where sent_at is null and attempts < 5 order by queued_at limit 500) q)),
    'due', jsonb_build_object('cars', (select count(*) from car_copy where status = 'pending'), 'pages', (select count(*) from seo_pages where status = 'pending'),
                              'articles', (select count(*) from articles where status = 'pending')));
end $$;

-- One result. p: {kind: car | page | article, id, ok, copy (car or page) or article fields, problems, error, model, prompt_version, neurons, ms}.
-- ok: published (the locked fields kept); not ok: the current text stays and the item is tried again after
-- seo_copy_retry_hours. Every call with neurons is logged in provider_calls (purpose seo_car, seo_page or seo_article).
create or replace function app.server_seo_result(p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  ps program_settings := app.settings();
  v_kind text := p ->> 'kind';
  v_id text := p ->> 'id';
  v_ok boolean := coalesce((p ->> 'ok')::boolean, false);
  v_out jsonb;
  pg seo_pages;
  a articles;
  k text;
  v_new jsonb;
  v_problems text[] := coalesce(array(select jsonb_array_elements_text(coalesce(p -> 'problems', '[]'::jsonb))), '{}');
begin
  if coalesce((p ->> 'neurons')::numeric, 0) > 0 or p ? 'error' then
    insert into provider_calls (provider, purpose, vehicle_id, ok, error, duration_ms, cost_microusd, units, unit)
    values (coalesce(p ->> 'provider', 'workers-ai'), 'seo_' || v_kind, case when v_kind = 'car' then v_id::uuid end, v_ok, left(p ->> 'error', 500),
            (p ->> 'ms')::integer, 0, coalesce((p ->> 'neurons')::numeric, 0), 'neurons');
  end if;
  if v_kind = 'car' then
    if v_ok then
      begin
        v_out := app.car_copy_apply(v_id::uuid, p -> 'copy', 'ai', (select facts_hash from car_copy where vehicle_id = v_id::uuid));
        update car_copy set model = p ->> 'model', prompt_version = p ->> 'prompt_version', neurons = neurons + coalesce((p ->> 'neurons')::integer, 0),
               runs = runs + 1, generated_at = now() where vehicle_id = v_id::uuid;
        -- the facts changed while it was being written: write it again
        update car_copy set status = 'pending', next_attempt_at = now() where vehicle_id = v_id::uuid and copy_facts_hash is distinct from facts_hash;
        return v_out;
      exception when sqlstate '23514' then
        v_problems := v_problems || sqlerrm;
      end;
    end if;
    update car_copy set status = 'failed', locked_at = null, worker = null, runs = runs + 1, attempts = attempts + 1,
           problems = v_problems, last_error = left(coalesce(p ->> 'error', array_to_string(v_problems, '; ')), 500),
           neurons = neurons + coalesce((p ->> 'neurons')::integer, 0),
           next_attempt_at = now() + make_interval(hours => ps.seo_copy_retry_hours)
     where vehicle_id = v_id::uuid;
    return jsonb_build_object('vehicle_id', v_id, 'status', 'failed');
  elsif v_kind = 'page' then
    select * into pg from seo_pages where slug = v_id for update;
    if pg.slug is null then raise exception 'Landing page not found' using errcode = 'P0002'; end if;
    if v_ok and jsonb_typeof(p -> 'copy') = 'object' then
      v_new := p -> 'copy';
      foreach k in array pg.locked loop if pg.copy ? k then v_new := v_new || jsonb_build_object(k, pg.copy -> k); end if; end loop;
      update seo_pages set copy = v_new, source = 'ai', status = 'published', copy_facts_hash = facts_hash, attempts = 0, problems = '{}', last_error = null,
             locked_at = null, model = p ->> 'model', prompt_version = p ->> 'prompt_version', generated_at = now()
       where slug = v_id;
      return jsonb_build_object('slug', v_id, 'status', 'published');
    end if;
    update seo_pages set status = 'failed', locked_at = null, attempts = attempts + 1, problems = v_problems,
           last_error = left(coalesce(p ->> 'error', array_to_string(v_problems, '; ')), 500), next_attempt_at = now() + make_interval(hours => ps.seo_copy_retry_hours)
     where slug = v_id;
    return jsonb_build_object('slug', v_id, 'status', 'failed');
  elsif v_kind = 'article' then
    select * into a from articles where slug = v_id for update;
    if a.slug is null then raise exception 'Article not found' using errcode = 'P0002'; end if;
    if v_ok and nullif(btrim(p ->> 'body_md'), '') is not null then
      update articles set
        title = case when 'title' = any (locked) then title else coalesce(nullif(btrim(p ->> 'title'), ''), title) end,
        description = case when 'description' = any (locked) then description else coalesce(nullif(btrim(p ->> 'description'), ''), description) end,
        body_md = case when 'body_md' = any (locked) then body_md else p ->> 'body_md' end,
        faq = case when 'faq' = any (locked) or jsonb_typeof(p -> 'faq') <> 'array' then faq else p -> 'faq' end,
        source = 'ai', status = 'published', attempts = 0, problems = '{}', last_error = null, locked_at = null,
        model = p ->> 'model', prompt_version = p ->> 'prompt_version', generated_at = now()
       where slug = v_id;
      return jsonb_build_object('slug', v_id, 'status', 'published');
    end if;
    update articles set status = 'failed', locked_at = null, attempts = attempts + 1, problems = v_problems,
           last_error = left(coalesce(p ->> 'error', array_to_string(v_problems, '; ')), 500), next_attempt_at = now() + make_interval(hours => ps.seo_copy_retry_hours)
     where slug = v_id;
    return jsonb_build_object('slug', v_id, 'status', 'failed');
  end if;
  raise exception 'Unknown kind %', v_kind using errcode = '22023';
end $$;

-- IndexNow: the job reports what it sent (p: {paths, status, error}).
create or replace function app.server_indexnow_sent(p jsonb) returns integer
language plpgsql security definer set search_path = public, app as $$
declare
  v_ok boolean := coalesce((p ->> 'status')::integer, 0) between 200 and 299;
  n integer;
begin
  update indexnow_queue set attempts = attempts + 1, last_status = (p ->> 'status')::integer, last_error = left(p ->> 'error', 300),
         sent_at = case when v_ok then now() else sent_at end
   where path = any (array(select jsonb_array_elements_text(coalesce(p -> 'paths', '[]'::jsonb))));
  get diagnostics n = row_count;
  return n;
end $$;

-- ================================================================ 7. reviews on car pages, sitemaps, public settings
-- A car's published reviews (in full, as shown on its page) and the summary the Car node may carry: only when the
-- page shows at least seo_rating_min_reviews of them. The business node never carries a rating.
create or replace function app.public_car_reviews(p_vehicle uuid) returns jsonb
language sql stable security definer set search_path = public, app as $$
  select jsonb_build_object(
    'count', (select count(*) from reviews r where r.vehicle_id = p_vehicle and r.status = 'published'),
    'average', (select round(avg(r.rating)::numeric, 1) from reviews r where r.vehicle_id = p_vehicle and r.status = 'published'),
    'min_for_rating', (app.settings()).seo_rating_min_reviews,
    'items', (select coalesce(jsonb_agg(jsonb_build_object('rating', x.rating, 'title', x.title, 'body', x.body, 'name', x.reviewer_first_name,
                                                          'month', x.review_month, 'reply', x.staff_reply)), '[]'::jsonb)
                from app.public_reviews(p_vehicle, 20, 0) x))
$$;

alter function app.public_car_page(text) rename to public_car_page_pre0061;
create or replace function app.public_car_page(p_slug text) returns jsonb
language sql stable security definer set search_path = public, app as $$
  select case when r is null or r ? 'redirect' then r
              else r || jsonb_build_object(
                'copy', (select case when cc.copy = '{}'::jsonb then null else cc.copy - 'alt_texts' end from car_copy cc where cc.vehicle_id = (r ->> 'vehicle_id')::uuid),
                'reviews', app.public_car_reviews((r ->> 'vehicle_id')::uuid)) end
    from (select app.public_car_page_pre0061(p_slug) r) x
$$;

-- The sitemaps: cars (with their public photos), model pages, landing pages and articles, each with the date its
-- content last changed. Sample cars and pages that are noindex are left out.
create or replace function app.public_sitemap_rows() returns table (path text, kind text, lastmod timestamptz, images jsonb)
language sql stable security definer set search_path = public, app as $$
  select s.path, s.kind, s.lastmod,
         case when s.kind = 'car' then (select coalesce(jsonb_agg(jsonb_build_object('loc', ph.processed_path, 'title', ph.alt_text) order by ph.is_cover desc, st.seq), '[]'::jsonb)
                                         from vehicle_listings l join vehicle_photos ph on ph.vehicle_id = l.vehicle_id
                                         left join listing_shot_types st on st.code = ph.shot_type
                                        where '/cars/' || l.slug = s.path and ph.is_public and ph.status = 'approved' and ph.replaced_at is null
                                          and ph.processed_path is not null) end
    from app.public_sitemap() s
  union all
  select app.seo_page_path(p.slug), 'landing', greatest(p.content_updated_at,
           (select max((c ->> 'updated_at')::timestamptz) from app.seo_page_cars(p.match) c)), null
    from seo_pages p where app.seo_page_indexable(p)
  union all
  select '/guides/' || a.slug, 'article', a.content_updated_at, null from articles a where a.is_published
$$;

-- the verification tokens go to every page; the NAP to the structured data
alter function app.public_site_settings() rename to public_site_settings_pre0061;
create or replace function app.public_site_settings() returns jsonb
language sql stable security definer set search_path = public, app as $$
  select app.public_site_settings_pre0061() || (select jsonb_build_object(
    'google_site_verification', s.google_site_verification, 'bing_site_verification', s.bing_site_verification,
    'business', jsonb_build_object('name', coalesce(s.business_name, s.brand_name), 'street', s.business_street, 'city', s.business_city,
      'region', s.business_region, 'postal_code', s.business_postal_code, 'country', 'CA', 'latitude', s.business_latitude, 'longitude', s.business_longitude))
    from site_settings s limit 1)
$$;

-- the root files: /<indexnow key>.txt and the Google verification file, answered only for the values in settings
create or replace function app.public_site_file(p_name text) returns text
language sql stable security definer set search_path = public, app as $$
  select case when p_name = s.indexnow_key || '.txt' then s.indexnow_key
              when s.google_verification_file is not null and p_name = s.google_verification_file then 'google-site-verification: ' || s.google_verification_file end
    from site_settings s limit 1
$$;

create or replace function public.seo_pages_public() returns jsonb language sql stable security definer set search_path = public, app as $$ select app.public_seo_pages() $$;
create or replace function public.seo_links() returns jsonb language sql stable security definer set search_path = public, app as $$ select app.public_seo_links() $$;
create or replace function public.seo_page(p_slug text) returns jsonb language sql stable security definer set search_path = public, app as $$ select app.public_seo_page(p_slug) $$;
create or replace function public.articles_public() returns jsonb language sql stable security definer set search_path = public, app as $$ select app.public_articles() $$;
create or replace function public.article(p_slug text) returns jsonb language sql stable security definer set search_path = public, app as $$ select app.public_article(p_slug) $$;
create or replace function public.sitemap_all() returns table (path text, kind text, lastmod timestamptz, images jsonb)
language sql stable security definer set search_path = public, app as $$ select * from app.public_sitemap_rows() $$;
create or replace function public.site_file(p_name text) returns text language sql stable security definer set search_path = public, app as $$ select app.public_site_file(p_name) $$;
create or replace function public.server_seo_claim(p_worker text, p_limit integer default 3) returns jsonb
language sql security definer set search_path = public, app as $$ select app.server_seo_claim(p_worker, p_limit) $$;
create or replace function public.server_seo_result(p jsonb) returns jsonb
language sql security definer set search_path = public, app as $$ select app.server_seo_result(p) $$;
create or replace function public.server_indexnow_sent(p jsonb) returns integer
language sql security definer set search_path = public, app as $$ select app.server_indexnow_sent(p) $$;

-- ================================================================ 8. the Google review request
-- A while after a booking closes (google_review_delay_days), the renter is asked to review CarmaCars on Google,
-- only when the Google place id is in Site settings. The same rules as the on-site request: not unsubscribed, no
-- open problem on the renter's account, and a booking that had a problem waits for the staff decision of 0025 (only
-- a yes sends either request). One per booking.
create or replace function app.google_review_url() returns text
language sql stable security definer set search_path = public, app as $$
  select case when nullif(btrim(s.google_place_id), '') is not null then 'https://search.google.com/local/writereview?placeid=' || s.google_place_id end
    from site_settings s limit 1
$$;

create or replace function app.notify_google_reviews(p_now timestamptz default now()) returns integer
language plpgsql security definer set search_path = public, app as $$
declare
  s program_settings := app.settings(app.local_date(p_now));
  v_today date := app.local_date(p_now);
  r record;
  n integer := 0;
begin
  if app.google_review_url() is null then return 0; end if;
  for r in select b.id, b.renter_id, rn.user_id, app.local_date(app.ntf_closed_at(b.id)) as closed_on
             from bookings b join renters rn on rn.id = b.renter_id
            where b.status = 'closed' and b.booking_type <> 'owner'
              and app.local_date(app.ntf_closed_at(b.id)) between v_today - s.google_review_delay_days - 3 and v_today - s.google_review_delay_days loop
    continue when exists (select 1 from marketing_sends m where m.code = 'renter_google_review_request' and m.booking_id = r.id);
    continue when not app.ntf_renter_clear(r.id, r.renter_id);
    continue when not app.has_marketing_consent(r.user_id, 'implied');
    continue when cardinality(app.booking_review_problems(r.id)) > 0
              and not exists (select 1 from review_request_decisions d where d.booking_id = r.id and d.status = 'send');
    insert into marketing_sends (code, booking_id, renter_id, user_id) values ('renter_google_review_request', r.id, r.renter_id, r.user_id)
    on conflict (code, booking_id) do nothing;
    if found then
      perform app.ntf_emit('renter_google_review_request', 'booking', r.id, 'closed', jsonb_build_object('booking_id', r.id));
      n := n + 1;
    end if;
  end loop;
  return n;
end $$;

alter function app.notify_followups(timestamptz) rename to notify_followups_pre0061;
create or replace function app.notify_followups(p_now timestamptz default now()) returns integer
language plpgsql security definer set search_path = public, app as $$
begin
  return app.notify_followups_pre0061(p_now) + app.notify_google_reviews(p_now);
end $$;

alter function app.notification_payload(text, app_events, jsonb) rename to ntf_payload_pre0061;
create or replace function app.notification_payload(p_code text, p_event app_events, p_to jsonb) returns jsonb
language plpgsql stable security definer set search_path = public, app as $$
declare
  x jsonb := app.ntf_payload_pre0061(p_code, p_event, p_to);
begin
  if p_code = 'renter_google_review_request' then
    x := x || jsonb_build_object('google_review_url', coalesce(app.google_review_url(), 'https://carmacars.ca/'),
                                 '_url', coalesce(app.google_review_url(), 'https://carmacars.ca/'));
  end if;
  return x;
end $$;

-- ================================================================ 9. the door: search settings, car copy, business listings
-- Admin > Settings > Search (seo_overview), the car copy on a listing (car_copy: Admins, Fleet and customer service),
-- a field edited by a person (locked, kept by every rewrite), Write again, a landing page or an article edited or
-- written again, a business listing ticked.
create or replace function app.seo_may_copy(p_user uuid) returns boolean
language sql stable security definer set search_path = public, app as $$
  select p_user is not null and (app.user_is_admin(p_user) or app.user_va_has(p_user, 'cs', 'fleet'))
$$;

create or replace function app.car_copy_read(p_user uuid, p_vehicle uuid) returns jsonb
language plpgsql stable security definer set search_path = public, app as $$
begin
  if not app.seo_may_copy(p_user) then raise exception 'Only an Admin, Fleet or customer service sees the car copy' using errcode = '42501'; end if;
  return (select jsonb_build_object('vehicle_id', v.id, 'vehicle', app.vehicle_name(v.id), 'eligible', app.car_copy_eligible(v.id), 'is_sample', v.is_sample,
            'status', cc.status, 'source', cc.source, 'copy', cc.copy, 'locked', to_jsonb(coalesce(cc.locked, '{}')), 'problems', to_jsonb(coalesce(cc.problems, '{}')),
            'last_error', cc.last_error, 'generated_at', cc.generated_at, 'published_at', cc.published_at, 'next_attempt_at', cc.next_attempt_at,
            'model', cc.model, 'runs', cc.runs, 'up_to_date', cc.copy_facts_hash is not distinct from cc.facts_hash, 'facts', cc.facts)
            from vehicles v left join car_copy cc on cc.vehicle_id = v.id where v.id = p_vehicle);
end $$;

create or replace function app.car_copy_edit(p_user uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  v_vehicle uuid := (p ->> 'vehicle')::uuid;
  v_field text := p ->> 'field';
  cc car_copy;
  v_new jsonb;
begin
  if not app.seo_may_copy(p_user) then raise exception 'Only an Admin, Fleet or customer service edits the car copy' using errcode = '42501'; end if;
  if not (v_field = any (app.car_copy_fields())) then raise exception 'Not a field of the car copy: %', v_field using errcode = '22023'; end if;
  perform app.car_copy_scan();
  select * into cc from car_copy where vehicle_id = v_vehicle for update;
  if cc.vehicle_id is null then raise exception 'This car has no copy yet (a sample car, or no listing)' using errcode = 'P0002'; end if;
  if coalesce((p ->> 'unlock')::boolean, false) then
    update car_copy set locked = array_remove(locked, v_field), status = 'pending', next_attempt_at = now(), asked_at = now(), attempts = 0, edited_by = p_user, edited_at = now()
     where vehicle_id = v_vehicle;
    insert into audit_log (actor_user_id, action, entity_table, entity_id, after) values (p_user, 'car_copy_unlock', 'car_copy', v_vehicle::text, jsonb_build_object('field', v_field));
    return jsonb_build_object('vehicle_id', v_vehicle, 'field', v_field, 'locked', false);
  end if;
  v_new := cc.copy || jsonb_build_object(v_field, p -> 'value');
  -- the person's text goes on the row first: applying keeps the locked fields from the row
  update car_copy set copy = v_new, locked = array(select distinct x from unnest(locked || v_field) x), edited_by = p_user, edited_at = now() where vehicle_id = v_vehicle;
  perform app.car_copy_apply(v_vehicle, v_new, cc.source, cc.copy_facts_hash);
  insert into audit_log (actor_user_id, action, entity_table, entity_id, before, after)
  values (p_user, 'car_copy_edit', 'car_copy', v_vehicle::text, jsonb_build_object(v_field, cc.copy -> v_field), jsonb_build_object(v_field, p -> 'value'));
  return jsonb_build_object('vehicle_id', v_vehicle, 'field', v_field, 'locked', true);
end $$;

create or replace function app.car_copy_regenerate(p_user uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
begin
  if not app.seo_may_copy(p_user) then raise exception 'Only an Admin, Fleet or customer service asks for new car copy' using errcode = '42501'; end if;
  perform app.car_copy_scan();
  update car_copy set status = 'pending', next_attempt_at = now(), asked_at = now(), attempts = 0, requested_by = p_user where vehicle_id = (p ->> 'vehicle')::uuid;
  if not found then raise exception 'This car has no copy yet (a sample car, or no listing)' using errcode = 'P0002'; end if;
  return jsonb_build_object('vehicle_id', p ->> 'vehicle', 'status', 'pending');
end $$;

create or replace function app.seo_overview(p_admin uuid) returns jsonb
language plpgsql stable security definer set search_path = public, app as $$
begin
  perform app.assert_admin(p_admin);
  return jsonb_build_object(
    'cars', (select coalesce(jsonb_agg(jsonb_build_object('vehicle_id', cc.vehicle_id, 'vehicle', app.vehicle_name(cc.vehicle_id), 'status', cc.status, 'source', cc.source,
                     'h1', cc.copy ->> 'h1', 'locked', to_jsonb(cc.locked), 'problems', to_jsonb(cc.problems), 'last_error', cc.last_error,
                     'published_at', cc.published_at, 'next_attempt_at', cc.next_attempt_at, 'up_to_date', cc.copy_facts_hash is not distinct from cc.facts_hash,
                     'slug', (select l.slug from vehicle_listings l where l.vehicle_id = cc.vehicle_id)) order by app.vehicle_name(cc.vehicle_id)), '[]'::jsonb) from car_copy cc),
    'pages', (select coalesce(jsonb_agg(to_jsonb(p) - 'facts_hash' - 'copy_facts_hash' || jsonb_build_object('path', app.seo_page_path(p.slug), 'indexable', app.seo_page_indexable(p))
                     || app.seo_page_counts(p) order by p.kind, p.sort_order), '[]'::jsonb) from seo_pages p),
    'articles', (select coalesce(jsonb_agg(to_jsonb(a) || jsonb_build_object('path', '/guides/' || a.slug) order by a.sort_order), '[]'::jsonb) from articles a),
    'indexnow', jsonb_build_object('waiting', (select count(*) from indexnow_queue where sent_at is null), 'sent_7d', (select count(*) from indexnow_queue where sent_at > now() - interval '7 days'),
                                   'last', (select jsonb_build_object('at', max(sent_at), 'status', (select last_status from indexnow_queue where sent_at is not null order by sent_at desc limit 1)) from indexnow_queue)),
    'neurons', app.seo_neurons_today(),
    'min_real_cars', (app.settings()).seo_landing_min_real_cars);
end $$;

-- what the database refuses on a landing page (the server checks more): the lengths, the long dash, the numbered
-- company, the banned phrases
create or replace function app.seo_page_problems(p_copy jsonb) returns text[]
language plpgsql stable security definer set search_path = public, app as $$
declare
  v_out text[] := '{}';
  v_all text := lower(coalesce(p_copy::text, ''));
  v_phrase text;
begin
  if nullif(btrim(coalesce(p_copy ->> 'h1', '')), '') is null or nullif(btrim(coalesce(p_copy ->> 'intro', '')), '') is null then v_out := v_out || 'The heading and the introduction are needed'::text; end if;
  if length(coalesce(p_copy ->> 'seo_title', '')) > 60 then v_out := v_out || 'The search title is over 60 characters'::text; end if;
  if length(coalesce(p_copy ->> 'meta_description', '')) > 160 then v_out := v_out || 'The search description is over 160 characters'::text; end if;
  if length(coalesce(p_copy ->> 'h1', '')) > 70 then v_out := v_out || 'The heading is over 70 characters'::text; end if;
  if position(chr(8212) in v_all) > 0 or position(chr(8211) in v_all) > 0 then v_out := v_out || 'Remove the long dash'::text; end if;
  if v_all ~ '18122211|canada inc' then v_out := v_out || 'The numbered company is never named'::text; end if;
  foreach v_phrase in array (app.settings()).listing_banned_phrases loop
    if position(lower(v_phrase) in v_all) > 0 then v_out := v_out || format('Remove the phrase "%s"', v_phrase); end if;
  end loop;
  return v_out;
end $$;

create or replace function app.seo_page_save(p_admin uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  pg seo_pages;
  v_copy jsonb;
  v_edited text[] := '{}';
  k text;
begin
  perform app.assert_admin(p_admin);
  select * into pg from seo_pages where slug = p ->> 'slug' for update;
  if pg.slug is null then raise exception 'Landing page not found' using errcode = 'P0002'; end if;
  if coalesce((p ->> 'regenerate')::boolean, false) then
    update seo_pages set status = 'pending', next_attempt_at = now(), attempts = 0, locked = case when coalesce((p ->> 'unlock')::boolean, false) then '{}' else locked end,
           updated_by = p_admin where slug = pg.slug;
    return jsonb_build_object('slug', pg.slug, 'status', 'pending');
  end if;
  v_copy := pg.copy;
  if jsonb_typeof(p -> 'copy') = 'object' then
    for k in select jsonb_object_keys(p -> 'copy') loop
      if not (k = any (array['seo_title', 'meta_description', 'h1', 'intro', 'sections', 'faq'])) then raise exception 'Not a field of a landing page: %', k using errcode = '22023'; end if;
      if (p -> 'copy' -> k) is distinct from (pg.copy -> k) then v_copy := v_copy || jsonb_build_object(k, p -> 'copy' -> k); v_edited := v_edited || k; end if;
    end loop;
  end if;
  if cardinality(app.seo_page_problems(v_copy)) > 0 then
    raise exception 'The page is not ready: %', array_to_string(app.seo_page_problems(v_copy), '; ') using errcode = '23514';
  end if;
  update seo_pages set copy = v_copy, locked = array(select distinct x from unnest(locked || v_edited) x),
         source = case when cardinality(v_edited) > 0 then 'staff' else source end,
         is_active = coalesce((p ->> 'is_active')::boolean, is_active),
         facts = case when jsonb_typeof(p -> 'facts') = 'object' then p -> 'facts' else facts end,
         match = case when jsonb_typeof(p -> 'match') = 'object' then p -> 'match' else match end,
         sort_order = coalesce((p ->> 'sort_order')::integer, sort_order), updated_by = p_admin
   where slug = pg.slug;
  insert into audit_log (actor_user_id, action, entity_table, entity_id, before, after)
  values (p_admin, 'seo_page_save', 'seo_pages', pg.slug, to_jsonb(pg) - 'facts_hash', (select to_jsonb(x) - 'facts_hash' from seo_pages x where x.slug = pg.slug));
  return jsonb_build_object('slug', pg.slug, 'edited', to_jsonb(v_edited));
end $$;

create or replace function app.article_save(p_admin uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  a articles;
  v_edited text[] := '{}';
  k text;
begin
  perform app.assert_admin(p_admin);
  select * into a from articles where slug = p ->> 'slug' for update;
  if a.slug is null then raise exception 'Article not found' using errcode = 'P0002'; end if;
  if coalesce((p ->> 'regenerate')::boolean, false) then
    update articles set status = 'pending', next_attempt_at = now(), attempts = 0, brief = coalesce(nullif(btrim(p ->> 'brief'), ''), brief),
           locked = case when coalesce((p ->> 'unlock')::boolean, false) then '{}' else locked end, updated_by = p_admin where slug = a.slug;
    return jsonb_build_object('slug', a.slug, 'status', 'pending');
  end if;
  foreach k in array array['title', 'seo_title', 'description', 'summary', 'body_md', 'faq', 'author_name'] loop
    if p ? k and (p -> k) is distinct from (to_jsonb(a) -> k) then v_edited := v_edited || k; end if;
  end loop;
  if position(chr(8212) in coalesce(p::text, '')) > 0 or position(chr(8211) in coalesce(p::text, '')) > 0 then
    raise exception 'Remove the long dash' using errcode = '23514';
  end if;
  update articles set
    title = coalesce(nullif(btrim(p ->> 'title'), ''), title), seo_title = case when p ? 'seo_title' then nullif(btrim(p ->> 'seo_title'), '') else seo_title end,
    description = coalesce(nullif(btrim(p ->> 'description'), ''), description), summary = case when p ? 'summary' then nullif(btrim(p ->> 'summary'), '') else summary end,
    body_md = coalesce(nullif(p ->> 'body_md', ''), body_md), faq = case when jsonb_typeof(p -> 'faq') = 'array' then p -> 'faq' else faq end,
    author_name = case when p ? 'author_name' then nullif(btrim(p ->> 'author_name'), '') else author_name end,
    is_published = coalesce((p ->> 'is_published')::boolean, is_published), brief = case when p ? 'brief' then nullif(btrim(p ->> 'brief'), '') else brief end,
    locked = array(select distinct x from unnest(locked || array_remove(v_edited, 'author_name')) x),
    source = case when cardinality(v_edited) > 0 then 'staff' else source end, updated_by = p_admin
   where slug = a.slug;
  insert into audit_log (actor_user_id, action, entity_table, entity_id, before, after)
  values (p_admin, 'article_save', 'articles', a.slug, to_jsonb(a) - 'body_md', jsonb_build_object('edited', to_jsonb(v_edited)));
  return jsonb_build_object('slug', a.slug, 'edited', to_jsonb(v_edited));
end $$;

create or replace function app.business_listing_tick(p_admin uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  v_key text := p ->> 'platform';
begin
  perform app.assert_admin(p_admin);
  if v_key is null or v_key !~ '^[a-z_]{2,40}$' then raise exception 'Choose a platform' using errcode = '22023'; end if;
  update site_settings set business_listings = business_listings || jsonb_build_object(v_key, jsonb_build_object(
           'done', coalesce((p ->> 'done')::boolean, true), 'url', nullif(btrim(p ->> 'url'), ''), 'at', now(), 'by', p_admin)),
         updated_by = p_admin;
  return (select business_listings from site_settings limit 1);
end $$;

create or replace function app.seo61(p_user uuid, p_call text, p_name text, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
begin
  case p_name
  when 'seo_overview' then return app.seo_overview(p_user);
  when 'car_copy' then return app.car_copy_read(p_user, (p ->> 'vehicle')::uuid);
  when 'car_copy_edit' then return app.car_copy_edit(p_user, p);
  when 'car_copy_regenerate' then return app.car_copy_regenerate(p_user, p);
  when 'seo_page_save' then return app.seo_page_save(p_user, p);
  when 'article_save' then return app.article_save(p_user, p);
  when 'business_listing_tick' then return app.business_listing_tick(p_user, p);
  else raise exception 'Unknown action %', p_name using errcode = '22023';
  end case;
end $$;

alter function app.door(uuid, text, text, text, jsonb) rename to door_pre0061;
create or replace function app.door(p_user uuid, p_aal text, p_call text, p_name text, p jsonb default '{}'::jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  p_ jsonb := coalesce(p, '{}'::jsonb);
begin
  if (p_call in ('admin_read', 'ops_read', 'va_read') and p_name in ('seo_overview', 'car_copy'))
     or (p_call in ('admin_do', 'ops_do', 'va_do') and p_name in ('car_copy_edit', 'car_copy_regenerate', 'seo_page_save', 'article_save', 'business_listing_tick')) then
    if p_ ? '_va' then perform set_config('app.va_active', coalesce(p_ ->> '_va', ''), true); end if;
    perform app.door_begin(p_user, p_aal);
    return app.seo61(p_user, p_call, p_name, p_ - '_va');
  end if;
  return app.door_pre0061(p_user, p_aal, p_call, p_name, p);
end $$;

-- ================================================================ 10. security, audit, privileges
do $$
declare t text;
begin
  foreach t in array array['car_copy', 'seo_pages', 'articles', 'indexnow_queue'] loop
    execute format('alter table %I enable row level security', t);
    execute format('create policy admin_all on %I for all to authenticated using (app.is_admin()) with check (app.is_admin())', t);
    execute format('revoke all on %I from anon, authenticated', t);
  end loop;
end $$;
-- audited like every table that holds content a person may change (0013); the IndexNow queue is a work list
do $$
declare t text;
begin
  foreach t in array array['car_copy', 'seo_pages', 'articles'] loop
    execute format('create trigger %I after insert or update or delete on public.%I for each row execute function app.audit_row()', 'audit_' || t, t);
  end loop;
end $$;

-- the renamed functions keep the privileges they had; the ones in their place get the same (the public site reads
-- the car page and the settings through invoker wrappers, as anon)
do $$
declare
  r record;
  v_new regprocedure;
  g text;
begin
  for r in select p.oid, m.new_name, oidvectortypes(p.proargtypes) as args
             from pg_proc p join pg_namespace n on n.oid = p.pronamespace
             join (values ('door_pre0061', 'door'), ('ntf_payload_pre0061', 'notification_payload'), ('notify_followups_pre0061', 'notify_followups'),
                          ('public_car_page_pre0061', 'public_car_page'), ('public_site_settings_pre0061', 'public_site_settings')) m(old_name, new_name)
               on m.old_name = p.proname
            where n.nspname = 'app' loop
    v_new := format('app.%I(%s)', r.new_name, r.args)::regprocedure;
    execute format('revoke all on function %s from public, anon, authenticated', v_new);
    foreach g in array array['anon', 'authenticated', 'service_role'] loop
      if has_function_privilege(g, r.oid, 'execute') then execute format('grant execute on function %s to %I', v_new, g); end if;
    end loop;
  end loop;
end $$;

do $$
declare
  f record;
begin
  for f in
    select p.oid::regprocedure as sig from pg_proc p join pg_namespace n on n.oid = p.pronamespace
     where (n.nspname = 'app' and p.proname = any (array['car_copy_fields', 'money_words', 'car_copy_eligible', 'car_copy_facts', 'car_copy_template', 'car_copy_problems',
              'car_copy_apply', 'car_copy_scan', 'seo_page_before', 'seo_page_path', 'seo_match', 'seo_page_cars', 'seo_counts_of', 'seo_page_counts', 'seo_real_count', 'seo_page_indexable', 'public_seo_links', 'public_seo_pages', 'public_seo_page',
              'article_before', 'public_articles', 'public_article', 'indexnow_queue_path', 'indexnow_on_listing', 'indexnow_on_page', 'seo_neurons_today', 'server_seo_claim',
              'server_seo_result', 'server_indexnow_sent', 'public_car_reviews', 'public_sitemap_rows', 'public_site_file', 'google_review_url', 'notify_google_reviews',
              'seo_may_copy', 'car_copy_read', 'car_copy_edit', 'car_copy_regenerate', 'seo_overview', 'seo_page_problems', 'seo_page_save', 'article_save', 'business_listing_tick', 'seo61']))
        or (n.nspname = 'public' and p.proname = any (array['server_seo_claim', 'server_seo_result', 'server_indexnow_sent']))
  loop
    execute format('revoke all on function %s from public, anon, authenticated', f.sig);
    execute format('grant execute on function %s to service_role', f.sig);
  end loop;
  -- the public site's reads (anon, through the public wrappers, which are definers; the app functions stay closed)
  revoke all on function public.seo_pages_public(), public.seo_links(), public.seo_page(text), public.articles_public(), public.article(text), public.sitemap_all(), public.site_file(text) from public;
  grant execute on function public.seo_pages_public(), public.seo_links(), public.seo_page(text), public.articles_public(), public.article(text), public.sitemap_all(), public.site_file(text)
    to anon, authenticated, service_role;
end $$;

-- ================================================================ 11. the guides: the Admin and VA chapters of this release
-- GUIDES 0061 START (generated by supabase/seed/0061_gen_guides.mjs from docs/guides/content; do not edit by hand)
select app.guide_release_section('admin', 'fleet-and-listings', 'chapter', 'calendar-sync-with-turo-and-other-platforms', 'Vehicles is the fleet. Listings is the pipeline that turns a car into a page on carmacars.ca: photos, copy, a duplicate check and a covered plate on every public photo.

## Vehicles

**Cars** > **Vehicles**

1. Filter by status and mode. Each row shows the plate, class, owner, mode, status, listing and daily rate.
2. Search by plate, model or owner. **Cars** > **Rates for many cars** changes the rates of many cars at once.
3. Open a car for its tabs: Overview, Rates, Fees and coverage, Calendar, Listing, and Owner, documents, tracker.

![](/guides/img/admin-08-vehicles-desktop-46461f49.jpg "desktop; size: 1440 900; address: carmacars.ca/admin/vehicles; pins: 1 18.5 19.3, 2 83.5 12.9, 3 73.6 38.9")

> Coming soon: The Tracker card on a car says "Coming soon": live location, the remote immobilize request and mileage from the tracker need the tracker company''s connection first.

## The listing pipeline

Open **Cars** > **Listings**. A draft waiting for review shows Needs review.

1. Each row shows the car, plate, state, photos and the pipeline''s progress.
2. Press **Start a listing** to begin one for a car that has none.
3. Open a car to review it.

![](/guides/img/admin-09-listings-desktop-970819b6.jpg "desktop; size: 1440 560; address: carmacars.ca/admin/listings; pins: 1 53.5 37.0, 2 87.2 21.1, 3 32.6 37.0")

## Review a listing

1. Pipeline shows each step done, such as photo sizes, copy draft and backgrounds.
2. Similar cars on file lists possible duplicates. Press **Not a duplicate** or **Same car**. An open flag stops publishing.
3. Check the copy: headline, description, features, questions, search title and description.
4. Under Photos, each public photo shows its plate state: Plate not checked, Plate covered or No plate visible.

![](/guides/img/admin-10-listing-review-desktop-352745fd.jpg "desktop; size: 1440 1100; address: carmacars.ca/admin/listings/7e43d38d-32bb-4666-a742-81813c3b7671; pins: 1 20.6 16.6, 2 86.1 47.5, 3 19.9 106.8, 4 74.9 106.8")

## Cover the licence plate

On each public photo press **Cover the plate**. The editor opens.

1. The editor suggests a box over the plate. Check it. **Suggest the plate** asks again.
2. Drag over a plate to draw a box. Drag a box to move it, or its corner to resize it.
3. Under Cover the plate with, choose **A CarmaCars plate**, **Pixelation** or **Blur**.
4. Press **Save the covered photo**. **Clear the boxes** starts over.
5. No plate in the shot? Press **No plate visible on this photo**.

![](/guides/img/admin-11-plate-editor-desktop-4219ad93.jpg "desktop; size: 690 703; address: carmacars.ca/admin/listings/7e43d38d-32bb-4666-a742-81813c3b7671; pins: 1 42.5 83.8, 2 49.6 29.9, 3 4.3 77.4, 4 15.5 83.8, 5 18.1 91.2")

> Tip: The covered photo replaces the public one; the original is kept privately. Keyboard: N adds a box, the arrows move it, Shift and the arrows resize it, Delete removes it.

## Publish

1. When every public photo is covered or marked, press **Approve and publish**.
2. Or press **Approve, publish later**, or **Send back** with what to fix.

> Watch out: Publishing waits for a plate decision on every public photo ("Cover the licence plate or mark it not visible on every public photo first"). Listings already live show "Plate not checked" until someone checks them.

## A listing without photos yet: sample photos

A car can be listed before its photos are taken. Until then the site shows a sample photo.

1. Submit the listing without photos. The listing copy is still written for you from the car''s details.
2. The car page and the car''s card show a sample photo, captioned "Sample photo", so renters know it is not this car. Staff see "Using sample photos" on the car and in Listings.
3. Publishing does not wait for a plate check: a sample photo has no plate.
4. Add the real photos when they are taken. Once real photos are approved they replace the sample at once; nothing else to do.

## Sample photos

**Settings** > **Sample photos**. The pictures a car shows until its real photos are in.

1. Every body type has a built-in picture (sedan, SUV, truck, van, coupe, hatchback, electric car).
2. Add your own: choose the Body type, and a Make and Model if the photo is of that exact model, pick the Photo, and press **Add the photo**.
3. The most specific photo wins: make and model, then make and body type, then body type. **Turn off** or **Delete** a photo you no longer want.
4. Cars using sample photos lists the cars still waiting for real photos. It is also a line on To do.

![](/guides/img/admin-36-sample-photos-desktop-55c64070.jpg "desktop; size: 1440 812; address: carmacars.ca/admin/settings/sample-photos; pins: 4 26.8 28.9")
', 'Fleet and listings', 'Vehicles, the listing pipeline, similar cars and covering licence plates.',
  'Vehicles is the fleet. Listings is the pipeline that turns a car into a page on carmacars.ca: photos, copy, a duplicate check and a covered plate on every public photo.

## Vehicles

**Cars** > **Vehicles**

1. Filter by status and mode. Each row shows the plate, class, owner, mode, status, listing and daily rate.
2. Search by plate, model or owner. **Cars** > **Rates for many cars** changes the rates of many cars at once.
3. Open a car for its tabs: Overview, Rates, Fees and coverage, Calendar, Listing, and Owner, documents, tracker.

![](/guides/img/admin-08-vehicles-desktop-46461f49.jpg "desktop; size: 1440 900; address: carmacars.ca/admin/vehicles; pins: 1 18.5 19.3, 2 83.5 12.9, 3 73.6 38.9")

> Coming soon: The Tracker card on a car says "Coming soon": live location, the remote immobilize request and mileage from the tracker need the tracker company''s connection first.

## The listing pipeline

Open **Cars** > **Listings**. A draft waiting for review shows Needs review.

1. Each row shows the car, plate, state, photos and the pipeline''s progress.
2. Press **Start a listing** to begin one for a car that has none.
3. Open a car to review it.

![](/guides/img/admin-09-listings-desktop-970819b6.jpg "desktop; size: 1440 560; address: carmacars.ca/admin/listings; pins: 1 53.5 37.0, 2 87.2 21.1, 3 32.6 37.0")

## Review a listing

1. Pipeline shows each step done, such as photo sizes, copy draft and backgrounds.
2. Similar cars on file lists possible duplicates. Press **Not a duplicate** or **Same car**. An open flag stops publishing.
3. The copy is written by itself from the car''s facts and published when it passes the checks: nothing to type. To change a line, press Change; that field is then locked and kept by every new version.
4. Under Photos, each public photo shows its plate state: Plate not checked, Plate covered or No plate visible.

![](/guides/img/admin-10-listing-review-desktop-352745fd.jpg "desktop; size: 1440 1100; address: carmacars.ca/admin/listings/7e43d38d-32bb-4666-a742-81813c3b7671; pins: 1 20.6 16.6, 2 86.1 47.5, 3 19.9 106.8, 4 74.9 106.8")

## Cover the licence plate

On each public photo press **Cover the plate**. The editor opens.

1. The editor suggests a box over the plate. Check it. **Suggest the plate** asks again.
2. Drag over a plate to draw a box. Drag a box to move it, or its corner to resize it.
3. Under Cover the plate with, choose **A CarmaCars plate**, **Pixelation** or **Blur**.
4. Press **Save the covered photo**. **Clear the boxes** starts over.
5. No plate in the shot? Press **No plate visible on this photo**.

![](/guides/img/admin-11-plate-editor-desktop-4219ad93.jpg "desktop; size: 690 703; address: carmacars.ca/admin/listings/7e43d38d-32bb-4666-a742-81813c3b7671; pins: 1 42.5 83.8, 2 49.6 29.9, 3 4.3 77.4, 4 15.5 83.8, 5 18.1 91.2")

> Tip: The covered photo replaces the public one; the original is kept privately. Keyboard: N adds a box, the arrows move it, Shift and the arrows resize it, Delete removes it.

## Publish

1. When every public photo is covered or marked, press **Approve and publish**.
2. Or press **Approve, publish later**, or **Send back** with what to fix.

> Watch out: Publishing waits for a plate decision on every public photo ("Cover the licence plate or mark it not visible on every public photo first"). Listings already live show "Plate not checked" until someone checks them.

## A listing without photos yet: sample photos

A car can be listed before its photos are taken. Until then the site shows a sample photo.

1. Submit the listing without photos. The listing copy is still written for you from the car''s details.
2. The car page and the car''s card show a sample photo, captioned "Sample photo", so renters know it is not this car. Staff see "Using sample photos" on the car and in Listings.
3. Publishing does not wait for a plate check: a sample photo has no plate.
4. Add the real photos when they are taken. Once real photos are approved they replace the sample at once; nothing else to do.

## Sample photos

**Settings** > **Sample photos**. The pictures a car shows until its real photos are in.

1. Every body type has a built-in picture (sedan, SUV, truck, van, coupe, hatchback, electric car).
2. Add your own: choose the Body type, and a Make and Model if the photo is of that exact model, pick the Photo, and press **Add the photo**.
3. The most specific photo wins: make and model, then make and body type, then body type. **Turn off** or **Delete** a photo you no longer want.
4. Cars using sample photos lists the cars still waiting for real photos. It is also a line on To do.

![](/guides/img/admin-36-sample-photos-desktop-55c64070.jpg "desktop; size: 1440 812; address: carmacars.ca/admin/settings/sample-photos; pins: 4 26.8 28.9")
',
  '<p class="gd-p">Vehicles is the fleet. Listings is the pipeline that turns a car into a page on carmacars.ca: photos, copy, a duplicate check and a covered plate on every public photo.</p><section class="gd-task" id="fleet-and-listings-vehicles" data-gd-task><h2 class="gd-h2">Vehicles</h2><p class="gd-p"><b class="gd-ui">Cars</b> &gt; <b class="gd-ui">Vehicles</b></p><div class="gd-stepblock gd-stepblock--below"><div class="gd-stepcol"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">Filter by status and mode. Each row shows the plate, class, owner, mode, status, listing and daily rate.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Search by plate, model or owner. <b class="gd-ui">Cars</b> &gt; <b class="gd-ui">Rates for many cars</b> changes the rates of many cars at once.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Open a car for its tabs: Overview, Rates, Fees and coverage, Calendar, Listing, and Owner, documents, tracker.</div></li></ol></div><figure class="gd-fig gd-fig--desk"><div class="gd-browser"><div class="gd-bar" aria-hidden="true"><i></i><i></i><i></i><span class="gd-addr">carmacars.ca/admin/vehicles</span></div><div class="gd-imgwrap" style="aspect-ratio:1440/900"><img src="/guides/img/admin-08-vehicles-desktop-46461f49.jpg" alt="" loading="lazy" decoding="async" width="1440" height="900"><span class="gd-pin" style="left:18.5%;top:19.3%" aria-hidden="true">1</span><span class="gd-pin" style="left:83.5%;top:12.9%" aria-hidden="true">2</span><span class="gd-pin" style="left:73.6%;top:38.9%" aria-hidden="true">3</span></div></div></figure></div><aside class="gd-box"><div>Coming soon: The Tracker card on a car says &quot;Coming soon&quot;: live location, the remote immobilize request and mileage from the tracker need the tracker company&#39;s connection first.</div></aside></section><section class="gd-task" id="fleet-and-listings-the-listing-pipeline" data-gd-task><h2 class="gd-h2">The listing pipeline</h2><p class="gd-p">Open <b class="gd-ui">Cars</b> &gt; <b class="gd-ui">Listings</b>. A draft waiting for review shows Needs review.</p><div class="gd-stepblock gd-stepblock--below"><div class="gd-stepcol"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">Each row shows the car, plate, state, photos and the pipeline&#39;s progress.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Press <b class="gd-ui">Start a listing</b> to begin one for a car that has none.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Open a car to review it.</div></li></ol></div><figure class="gd-fig gd-fig--desk"><div class="gd-browser"><div class="gd-bar" aria-hidden="true"><i></i><i></i><i></i><span class="gd-addr">carmacars.ca/admin/listings</span></div><div class="gd-imgwrap" style="aspect-ratio:1440/560"><img src="/guides/img/admin-09-listings-desktop-970819b6.jpg" alt="" loading="lazy" decoding="async" width="1440" height="560"><span class="gd-pin" style="left:53.5%;top:37%" aria-hidden="true">1</span><span class="gd-pin" style="left:87.2%;top:21.1%" aria-hidden="true">2</span><span class="gd-pin" style="left:32.6%;top:37%" aria-hidden="true">3</span></div></div></figure></div></section><section class="gd-task" id="fleet-and-listings-review-a-listing" data-gd-task><h2 class="gd-h2">Review a listing</h2><div class="gd-stepblock gd-stepblock--below"><div class="gd-stepcol"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">Pipeline shows each step done, such as photo sizes, copy draft and backgrounds.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Similar cars on file lists possible duplicates. Press <b class="gd-ui">Not a duplicate</b> or <b class="gd-ui">Same car</b>. An open flag stops publishing.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">The copy is written by itself from the car&#39;s facts and published when it passes the checks: nothing to type. To change a line, press Change; that field is then locked and kept by every new version.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t">Under Photos, each public photo shows its plate state: Plate not checked, Plate covered or No plate visible.</div></li></ol></div><figure class="gd-fig gd-fig--desk"><div class="gd-browser"><div class="gd-bar" aria-hidden="true"><i></i><i></i><i></i><span class="gd-addr">carmacars.ca/admin/listings/7e43d38d-32bb-4666-a742-81813c3b7671</span></div><div class="gd-imgwrap" style="aspect-ratio:1440/1100"><img src="/guides/img/admin-10-listing-review-desktop-352745fd.jpg" alt="" loading="lazy" decoding="async" width="1440" height="1100"><span class="gd-pin" style="left:20.6%;top:16.6%" aria-hidden="true">1</span><span class="gd-pin" style="left:86.1%;top:47.5%" aria-hidden="true">2</span><span class="gd-pin" style="left:19.9%;top:100%" aria-hidden="true">3</span><span class="gd-pin" style="left:74.9%;top:100%" aria-hidden="true">4</span></div></div></figure></div></section><section class="gd-task" id="fleet-and-listings-cover-the-licence-plate" data-gd-task><h2 class="gd-h2">Cover the licence plate</h2><p class="gd-p">On each public photo press <b class="gd-ui">Cover the plate</b>. The editor opens.</p><div class="gd-stepblock gd-stepblock--below"><div class="gd-stepcol"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">The editor suggests a box over the plate. Check it. <b class="gd-ui">Suggest the plate</b> asks again.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Drag over a plate to draw a box. Drag a box to move it, or its corner to resize it.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Under Cover the plate with, choose <b class="gd-ui">A CarmaCars plate</b>, <b class="gd-ui">Pixelation</b> or <b class="gd-ui">Blur</b>.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t">Press <b class="gd-ui">Save the covered photo</b>. <b class="gd-ui">Clear the boxes</b> starts over.</div></li><li><span class="gd-n" aria-hidden="true">5</span><div class="gd-t">No plate in the shot? Press <b class="gd-ui">No plate visible on this photo</b>.</div></li></ol></div><figure class="gd-fig gd-fig--desk"><div class="gd-browser"><div class="gd-bar" aria-hidden="true"><i></i><i></i><i></i><span class="gd-addr">carmacars.ca/admin/listings/7e43d38d-32bb-4666-a742-81813c3b7671</span></div><div class="gd-imgwrap" style="aspect-ratio:690/703"><img src="/guides/img/admin-11-plate-editor-desktop-4219ad93.jpg" alt="" loading="lazy" decoding="async" width="690" height="703"><span class="gd-pin" style="left:42.5%;top:83.8%" aria-hidden="true">1</span><span class="gd-pin" style="left:49.6%;top:29.9%" aria-hidden="true">2</span><span class="gd-pin" style="left:4.3%;top:77.4%" aria-hidden="true">3</span><span class="gd-pin" style="left:15.5%;top:83.8%" aria-hidden="true">4</span><span class="gd-pin" style="left:18.1%;top:91.2%" aria-hidden="true">5</span></div></div></figure></div><aside class="gd-box"><span class="gd-lbl">Tip</span><div>The covered photo replaces the public one; the original is kept privately. Keyboard: N adds a box, the arrows move it, Shift and the arrows resize it, Delete removes it.</div></aside></section><section class="gd-task" id="fleet-and-listings-publish" data-gd-task><h2 class="gd-h2">Publish</h2><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">When every public photo is covered or marked, press <b class="gd-ui">Approve and publish</b>.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Or press <b class="gd-ui">Approve, publish later</b>, or <b class="gd-ui">Send back</b> with what to fix.</div></li></ol></div><aside class="gd-box gd-box--warn"><span class="gd-lbl">Watch out</span><div>Publishing waits for a plate decision on every public photo (&quot;Cover the licence plate or mark it not visible on every public photo first&quot;). Listings already live show &quot;Plate not checked&quot; until someone checks them.</div></aside></section><section class="gd-task" id="fleet-and-listings-a-listing-without-photos-yet-sample-photos" data-gd-task><h2 class="gd-h2">A listing without photos yet: sample photos</h2><p class="gd-p">A car can be listed before its photos are taken. Until then the site shows a sample photo.</p><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">Submit the listing without photos. The listing copy is still written for you from the car&#39;s details.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">The car page and the car&#39;s card show a sample photo, captioned &quot;Sample photo&quot;, so renters know it is not this car. Staff see &quot;Using sample photos&quot; on the car and in Listings.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Publishing does not wait for a plate check: a sample photo has no plate.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t">Add the real photos when they are taken. Once real photos are approved they replace the sample at once; nothing else to do.</div></li></ol></div></section><section class="gd-task" id="fleet-and-listings-sample-photos" data-gd-task><h2 class="gd-h2">Sample photos</h2><p class="gd-p"><b class="gd-ui">Settings</b> &gt; <b class="gd-ui">Sample photos</b>. The pictures a car shows until its real photos are in.</p><div class="gd-stepblock gd-stepblock--below"><div class="gd-stepcol"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">Every body type has a built-in picture (sedan, SUV, truck, van, coupe, hatchback, electric car).</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Add your own: choose the Body type, and a Make and Model if the photo is of that exact model, pick the Photo, and press <b class="gd-ui">Add the photo</b>.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">The most specific photo wins: make and model, then make and body type, then body type. <b class="gd-ui">Turn off</b> or <b class="gd-ui">Delete</b> a photo you no longer want.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t">Cars using sample photos lists the cars still waiting for real photos. It is also a line on To do.</div></li></ol></div><figure class="gd-fig gd-fig--desk"><div class="gd-browser"><div class="gd-bar" aria-hidden="true"><i></i><i></i><i></i><span class="gd-addr">carmacars.ca/admin/settings/sample-photos</span></div><div class="gd-imgwrap" style="aspect-ratio:1440/812"><img src="/guides/img/admin-36-sample-photos-desktop-55c64070.jpg" alt="" loading="lazy" decoding="async" width="1440" height="812"><span class="gd-pin" style="left:26.8%;top:28.9%" aria-hidden="true">4</span></div></div></figure></div></section>');
select app.guide_release_section('admin', 'search-car-pages-landing-pages-and-guides', 'chapter', 'live-visitors-and-live-chat', null, 'Search: car pages, landing pages and guides', 'Car copy written by itself, landing pages, guides, search engines, business listings and IndexNow.',
  'The text of every car page, the landing pages for each area and way of renting, and the guides are written by Workers AI from the facts in the database, checked and published by themselves. Nobody has to type or review anything. You can still change any line; what you change is kept.

## The copy of a car

**Cars** > **Vehicles**, then the car, then its Listing tab. The same card is on the listing review.

1. The card says who wrote the text: a plain copy from the car''s facts while the written copy is prepared (usually minutes), then Workers AI.
2. Every field is shown: search title and description, heading, introduction, highlights, good for, what''s included, pickup and delivery, requirements, questions and the photo descriptions.
3. To change a field press **Change**, then **Save and lock**. A locked field is kept by every new version. **Unlock** lets it be written again.
4. **Write again** asks for a new version now. A new version is also written by itself when the car''s facts change: its rates, specs, area or photos.

> Good to know: The checks refuse long dashes, sales words, the numbered company, any number that is not in the car''s facts (a price, a seat count) and equipment the facts do not list. A version that fails is asked again with the problems named; if it still fails, the page keeps its current text and it is tried again later.

## Landing pages and guides

**Settings** > **All settings**, then Search.

1. Today: the Workers AI used for search copy and in all, and IndexNow (addresses waiting and sent).
2. Car copy: every real car, who wrote its text, and whether its facts changed since.
3. Landing pages: each place and way of renting, whether it is in search, its cars and who wrote it. A page for a way of renting (monthly, SUV) goes into search once enough real cars match it (Program settings).
4. Open **Edit** on a page or a guide to change its text. Edited fields are locked. **Write again** asks for a new version; on a guide, the brief says what it must cover.

## Search engines and business listings

**Settings** > **All settings**, then Site settings.

1. Search engines: paste the Google Search Console value (HTML tag) or the file name (HTML file), and the Bing value. The steps are on the card.
2. Business name, address and phone: the exact text for every listing, and the description and categories.
3. Business listings: press **Copy** beside each line and paste it into Google Business Profile, Bing Places, Apple Business Connect, Yelp, Yellow Pages and Facebook. Tick each one when it is done.

> Good to know: Changed pages are sent to IndexNow (Bing and the other engines that use it) by themselves. Google reads the sitemap: submit carmacars.ca/sitemap.xml once in Search Console.
',
  '<p class="gd-p">The text of every car page, the landing pages for each area and way of renting, and the guides are written by Workers AI from the facts in the database, checked and published by themselves. Nobody has to type or review anything. You can still change any line; what you change is kept.</p><section class="gd-task" id="search-car-pages-landing-pages-and-guides-the-copy-of-a-car" data-gd-task><h2 class="gd-h2">The copy of a car</h2><p class="gd-p"><b class="gd-ui">Cars</b> &gt; <b class="gd-ui">Vehicles</b>, then the car, then its Listing tab. The same card is on the listing review.</p><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">The card says who wrote the text: a plain copy from the car&#39;s facts while the written copy is prepared (usually minutes), then Workers AI.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Every field is shown: search title and description, heading, introduction, highlights, good for, what&#39;s included, pickup and delivery, requirements, questions and the photo descriptions.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">To change a field press <b class="gd-ui">Change</b>, then <b class="gd-ui">Save and lock</b>. A locked field is kept by every new version. <b class="gd-ui">Unlock</b> lets it be written again.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t"><b class="gd-ui">Write again</b> asks for a new version now. A new version is also written by itself when the car&#39;s facts change: its rates, specs, area or photos.</div></li></ol></div><aside class="gd-box"><span class="gd-lbl">Good to know</span><div>The checks refuse long dashes, sales words, the numbered company, any number that is not in the car&#39;s facts (a price, a seat count) and equipment the facts do not list. A version that fails is asked again with the problems named; if it still fails, the page keeps its current text and it is tried again later.</div></aside></section><section class="gd-task" id="search-car-pages-landing-pages-and-guides-landing-pages-and-guides" data-gd-task><h2 class="gd-h2">Landing pages and guides</h2><p class="gd-p"><b class="gd-ui">Settings</b> &gt; <b class="gd-ui">All settings</b>, then Search.</p><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">Today: the Workers AI used for search copy and in all, and IndexNow (addresses waiting and sent).</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Car copy: every real car, who wrote its text, and whether its facts changed since.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Landing pages: each place and way of renting, whether it is in search, its cars and who wrote it. A page for a way of renting (monthly, SUV) goes into search once enough real cars match it (Program settings).</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t">Open <b class="gd-ui">Edit</b> on a page or a guide to change its text. Edited fields are locked. <b class="gd-ui">Write again</b> asks for a new version; on a guide, the brief says what it must cover.</div></li></ol></div></section><section class="gd-task" id="search-car-pages-landing-pages-and-guides-search-engines-and-business-listings" data-gd-task><h2 class="gd-h2">Search engines and business listings</h2><p class="gd-p"><b class="gd-ui">Settings</b> &gt; <b class="gd-ui">All settings</b>, then Site settings.</p><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">Search engines: paste the Google Search Console value (HTML tag) or the file name (HTML file), and the Bing value. The steps are on the card.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Business name, address and phone: the exact text for every listing, and the description and categories.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Business listings: press <b class="gd-ui">Copy</b> beside each line and paste it into Google Business Profile, Bing Places, Apple Business Connect, Yelp, Yellow Pages and Facebook. Tick each one when it is done.</div></li></ol></div><aside class="gd-box"><span class="gd-lbl">Good to know</span><div>Changed pages are sent to IndexNow (Bing and the other engines that use it) by themselves. Google reads the sitemap: submit carmacars.ca/sitemap.xml once in Search Console.</div></aside></section>');
select app.guide_release_section('va', 'fleet', 'chapter', 'finance', 'You keep the cars moving: field jobs, daily checks, photo reviews after returns, and the listing pipeline with its duplicate check and plate covering.

Your rail: Queue, Today, Field jobs, Daily checks, Photo reviews, Calendar, Listings, Similar cars, Find a renter and Scorecard.

## Schedule field jobs

1. Handovers and returns without a job are listed first. Every booking needs one.
2. Press **Schedule**: choose the kind, car, when, place, field staff and instructions.
3. Jobs, next three days: each with its field staff and whether they acknowledged it.
4. Change a job with **Assign**, **Reassign**, **Move** or **Cancel**.

![](/guides/img/va-fleet-02-field-jobs-desktop-b985927b.jpg "desktop; size: 1230 1180; address: carmacars.ca/va/fleet; pins: 1 15.4 10.4, 2 78.9 12.7, 3 11.4 68.6, 4 78.9 83.9")

## Daily checks

Twice a day: the opening check by 9:00 and the closing check by 18:00.

1. Open **Daily checks** and choose **Opening check** or **Closing check**.
2. Each line shows what was found. Tick OK, or Problem with a note.
3. Press **Save the opening check** (or **Save the closing check**). You can save it again.

![](/guides/img/va-fleet-03-daily-checks-desktop-be06d6c0.jpg "desktop; size: 1230 820; address: carmacars.ca/va/checks; pins: 1 6.5 15.4, 2 44.7 42.0, 3 64.2 94.0")

## Photo reviews after a return

After each return, the field photo set waits under **Photo reviews**. Compare it with the pickup set. Press **Review done**, or **Ask for a re-shoot** if a photo is missing or unclear.

## Similar cars

A possible duplicate listing stops publishing until you decide.

1. Each flag shows the car, what it looks like (same VIN, plate, photo or specs) and the other car.
2. Compare the permit, the plate and the photos.
3. Press **Not a duplicate** with a note when they are different cars, or **Same car** when they are.

![](/guides/img/va-fleet-06-similar-cars-desktop-562b0382.jpg "desktop; size: 1230 460; address: carmacars.ca/va/similar-cars; pins: 1 23.6 30.4, 3 94.8 30.4")

## Listings and covering plates

1. Open **Listings**. A draft waiting shows Needs review. Open it.
2. Check the copy and photos. On each public photo, cover the plate or mark it not visible.

![](/guides/img/va-fleet-05-listings-desktop-d2672e0a.jpg "desktop; size: 1230 340; address: carmacars.ca/va/listings; pins: 1 54.5 49.1")

3. Press **Cover the plate**. Check the suggested box; **Suggest the plate** asks again.
4. Drag over a plate to draw a box; drag a box to move it, its corner to resize it.
5. Choose **A CarmaCars plate**, **Pixelation** or **Blur**, then **Save the covered photo**.
6. No plate in the shot? **No plate visible on this photo**.

![](/guides/img/admin-11-plate-editor-phone-95d5afd2.jpg "phone; size: 390 776; pins: 3 52.6 78.9, 4 50.0 43.8, 5 61.5 62.1, 6 43.1 92.3")

> Watch out: Publishing waits until every public photo is covered or marked. The covered photo replaces the public one; the original is kept privately.

## Calendar sync with Turo and other platforms

**Cars** > **Calendar sync**: a car listed on Turo or Getaround must never be booked twice.

1. On the platform, copy the car''s calendar link (iCal, it ends in .ics). Here, find the car, open **Add a calendar link**, choose the platform, paste it and press **Add the link**.
2. Its trips block the car here with the turnaround before and after, read every 10 minutes. The card shows "Working" and the next trips.
3. Copy the car''s CarmaCars link "For Turo" (or Getaround) with **Copy** and paste it into the platform''s calendar import. It shows only "Booked".
4. A double booking raises an urgent task for you and an email: move, swap or cancel one trip. A link that stops working raises a task after 3 failed reads: copy it from the platform again.
', 'Fleet', 'Field jobs, daily checks, photo reviews, similar cars and listings.',
  'You keep the cars moving: field jobs, daily checks, photo reviews after returns, and the listing pipeline with its duplicate check and plate covering.

Your rail: Queue, Today, Field jobs, Daily checks, Photo reviews, Calendar, Listings, Similar cars, Find a renter and Scorecard.

## Schedule field jobs

1. Handovers and returns without a job are listed first. Every booking needs one.
2. Press **Schedule**: choose the kind, car, when, place, field staff and instructions.
3. Jobs, next three days: each with its field staff and whether they acknowledged it.
4. Change a job with **Assign**, **Reassign**, **Move** or **Cancel**.

![](/guides/img/va-fleet-02-field-jobs-desktop-b985927b.jpg "desktop; size: 1230 1180; address: carmacars.ca/va/fleet; pins: 1 15.4 10.4, 2 78.9 12.7, 3 11.4 68.6, 4 78.9 83.9")

## Daily checks

Twice a day: the opening check by 9:00 and the closing check by 18:00.

1. Open **Daily checks** and choose **Opening check** or **Closing check**.
2. Each line shows what was found. Tick OK, or Problem with a note.
3. Press **Save the opening check** (or **Save the closing check**). You can save it again.

![](/guides/img/va-fleet-03-daily-checks-desktop-be06d6c0.jpg "desktop; size: 1230 820; address: carmacars.ca/va/checks; pins: 1 6.5 15.4, 2 44.7 42.0, 3 64.2 94.0")

## Photo reviews after a return

After each return, the field photo set waits under **Photo reviews**. Compare it with the pickup set. Press **Review done**, or **Ask for a re-shoot** if a photo is missing or unclear.

## Similar cars

A possible duplicate listing stops publishing until you decide.

1. Each flag shows the car, what it looks like (same VIN, plate, photo or specs) and the other car.
2. Compare the permit, the plate and the photos.
3. Press **Not a duplicate** with a note when they are different cars, or **Same car** when they are.

![](/guides/img/va-fleet-06-similar-cars-desktop-562b0382.jpg "desktop; size: 1230 460; address: carmacars.ca/va/similar-cars; pins: 1 23.6 30.4, 3 94.8 30.4")

## Listings and covering plates

1. Open **Listings**. A draft waiting shows Needs review. Open it.
2. The copy is written by itself (change a line only if you must: it is then kept). Check the photos: on each public photo, cover the plate or mark it not visible.

![](/guides/img/va-fleet-05-listings-desktop-d2672e0a.jpg "desktop; size: 1230 340; address: carmacars.ca/va/listings; pins: 1 54.5 49.1")

3. Press **Cover the plate**. Check the suggested box; **Suggest the plate** asks again.
4. Drag over a plate to draw a box; drag a box to move it, its corner to resize it.
5. Choose **A CarmaCars plate**, **Pixelation** or **Blur**, then **Save the covered photo**.
6. No plate in the shot? **No plate visible on this photo**.

![](/guides/img/admin-11-plate-editor-phone-95d5afd2.jpg "phone; size: 390 776; pins: 3 52.6 78.9, 4 50.0 43.8, 5 61.5 62.1, 6 43.1 92.3")

> Watch out: Publishing waits until every public photo is covered or marked. The covered photo replaces the public one; the original is kept privately.

## Calendar sync with Turo and other platforms

**Cars** > **Calendar sync**: a car listed on Turo or Getaround must never be booked twice.

1. On the platform, copy the car''s calendar link (iCal, it ends in .ics). Here, find the car, open **Add a calendar link**, choose the platform, paste it and press **Add the link**.
2. Its trips block the car here with the turnaround before and after, read every 10 minutes. The card shows "Working" and the next trips.
3. Copy the car''s CarmaCars link "For Turo" (or Getaround) with **Copy** and paste it into the platform''s calendar import. It shows only "Booked".
4. A double booking raises an urgent task for you and an email: move, swap or cancel one trip. A link that stops working raises a task after 3 failed reads: copy it from the platform again.
',
  '<p class="gd-p">You keep the cars moving: field jobs, daily checks, photo reviews after returns, and the listing pipeline with its duplicate check and plate covering.</p><p class="gd-p">Your rail: Queue, Today, Field jobs, Daily checks, Photo reviews, Calendar, Listings, Similar cars, Find a renter and Scorecard.</p><section class="gd-task" id="fleet-schedule-field-jobs" data-gd-task><h2 class="gd-h2">Schedule field jobs</h2><div class="gd-stepblock gd-stepblock--below"><div class="gd-stepcol"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">Handovers and returns without a job are listed first. Every booking needs one.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Press <b class="gd-ui">Schedule</b>: choose the kind, car, when, place, field staff and instructions.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Jobs, next three days: each with its field staff and whether they acknowledged it.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t">Change a job with <b class="gd-ui">Assign</b>, <b class="gd-ui">Reassign</b>, <b class="gd-ui">Move</b> or <b class="gd-ui">Cancel</b>.</div></li></ol></div><figure class="gd-fig gd-fig--desk"><div class="gd-browser"><div class="gd-bar" aria-hidden="true"><i></i><i></i><i></i><span class="gd-addr">carmacars.ca/va/fleet</span></div><div class="gd-imgwrap" style="aspect-ratio:1230/1180"><img src="/guides/img/va-fleet-02-field-jobs-desktop-b985927b.jpg" alt="" loading="lazy" decoding="async" width="1230" height="1180"><span class="gd-pin" style="left:15.4%;top:10.4%" aria-hidden="true">1</span><span class="gd-pin" style="left:78.9%;top:12.7%" aria-hidden="true">2</span><span class="gd-pin" style="left:11.4%;top:68.6%" aria-hidden="true">3</span><span class="gd-pin" style="left:78.9%;top:83.9%" aria-hidden="true">4</span></div></div></figure></div></section><section class="gd-task" id="fleet-daily-checks" data-gd-task><h2 class="gd-h2">Daily checks</h2><p class="gd-p">Twice a day: the opening check by 9:00 and the closing check by 18:00.</p><div class="gd-stepblock gd-stepblock--below"><div class="gd-stepcol"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">Open <b class="gd-ui">Daily checks</b> and choose <b class="gd-ui">Opening check</b> or <b class="gd-ui">Closing check</b>.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Each line shows what was found. Tick OK, or Problem with a note.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Press <b class="gd-ui">Save the opening check</b> (or <b class="gd-ui">Save the closing check</b>). You can save it again.</div></li></ol></div><figure class="gd-fig gd-fig--desk"><div class="gd-browser"><div class="gd-bar" aria-hidden="true"><i></i><i></i><i></i><span class="gd-addr">carmacars.ca/va/checks</span></div><div class="gd-imgwrap" style="aspect-ratio:1230/820"><img src="/guides/img/va-fleet-03-daily-checks-desktop-be06d6c0.jpg" alt="" loading="lazy" decoding="async" width="1230" height="820"><span class="gd-pin" style="left:6.5%;top:15.4%" aria-hidden="true">1</span><span class="gd-pin" style="left:44.7%;top:42%" aria-hidden="true">2</span><span class="gd-pin" style="left:64.2%;top:94%" aria-hidden="true">3</span></div></div></figure></div></section><section class="gd-task" id="fleet-photo-reviews-after-a-return" data-gd-task><h2 class="gd-h2">Photo reviews after a return</h2><p class="gd-p">After each return, the field photo set waits under <b class="gd-ui">Photo reviews</b>. Compare it with the pickup set. Press <b class="gd-ui">Review done</b>, or <b class="gd-ui">Ask for a re-shoot</b> if a photo is missing or unclear.</p></section><section class="gd-task" id="fleet-similar-cars" data-gd-task><h2 class="gd-h2">Similar cars</h2><p class="gd-p">A possible duplicate listing stops publishing until you decide.</p><div class="gd-stepblock gd-stepblock--below"><div class="gd-stepcol"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">Each flag shows the car, what it looks like (same VIN, plate, photo or specs) and the other car.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Compare the permit, the plate and the photos.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Press <b class="gd-ui">Not a duplicate</b> with a note when they are different cars, or <b class="gd-ui">Same car</b> when they are.</div></li></ol></div><figure class="gd-fig gd-fig--desk"><div class="gd-browser"><div class="gd-bar" aria-hidden="true"><i></i><i></i><i></i><span class="gd-addr">carmacars.ca/va/similar-cars</span></div><div class="gd-imgwrap" style="aspect-ratio:1230/460"><img src="/guides/img/va-fleet-06-similar-cars-desktop-562b0382.jpg" alt="" loading="lazy" decoding="async" width="1230" height="460"><span class="gd-pin" style="left:23.6%;top:30.4%" aria-hidden="true">1</span><span class="gd-pin" style="left:94.8%;top:30.4%" aria-hidden="true">3</span></div></div></figure></div></section><section class="gd-task" id="fleet-listings-and-covering-plates" data-gd-task><h2 class="gd-h2">Listings and covering plates</h2><div class="gd-stepblock gd-stepblock--below"><div class="gd-stepcol"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">Open <b class="gd-ui">Listings</b>. A draft waiting shows Needs review. Open it.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">The copy is written by itself (change a line only if you must: it is then kept). Check the photos: on each public photo, cover the plate or mark it not visible.</div></li></ol></div><figure class="gd-fig gd-fig--desk"><div class="gd-browser"><div class="gd-bar" aria-hidden="true"><i></i><i></i><i></i><span class="gd-addr">carmacars.ca/va/listings</span></div><div class="gd-imgwrap" style="aspect-ratio:1230/340"><img src="/guides/img/va-fleet-05-listings-desktop-d2672e0a.jpg" alt="" loading="lazy" decoding="async" width="1230" height="340"><span class="gd-pin" style="left:54.5%;top:49.1%" aria-hidden="true">1</span></div></div></figure></div><div class="gd-stepblock gd-stepblock--side"><div class="gd-stepcol"><ol class="gd-ol" start="3"><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Press <b class="gd-ui">Cover the plate</b>. Check the suggested box; <b class="gd-ui">Suggest the plate</b> asks again.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t">Drag over a plate to draw a box; drag a box to move it, its corner to resize it.</div></li><li><span class="gd-n" aria-hidden="true">5</span><div class="gd-t">Choose <b class="gd-ui">A CarmaCars plate</b>, <b class="gd-ui">Pixelation</b> or <b class="gd-ui">Blur</b>, then <b class="gd-ui">Save the covered photo</b>.</div></li><li><span class="gd-n" aria-hidden="true">6</span><div class="gd-t">No plate in the shot? <b class="gd-ui">No plate visible on this photo</b>.</div></li></ol></div><figure class="gd-fig gd-fig--phone"><div class="gd-phone"><div class="gd-imgwrap" style="aspect-ratio:390/776"><img src="/guides/img/admin-11-plate-editor-phone-95d5afd2.jpg" alt="" loading="lazy" decoding="async" width="390" height="776"><span class="gd-pin" style="left:52.6%;top:78.9%" aria-hidden="true">3</span><span class="gd-pin" style="left:50%;top:43.8%" aria-hidden="true">4</span><span class="gd-pin" style="left:61.5%;top:62.1%" aria-hidden="true">5</span><span class="gd-pin" style="left:43.1%;top:92.3%" aria-hidden="true">6</span></div></div></figure></div><aside class="gd-box gd-box--warn"><span class="gd-lbl">Watch out</span><div>Publishing waits until every public photo is covered or marked. The covered photo replaces the public one; the original is kept privately.</div></aside></section><section class="gd-task" id="fleet-calendar-sync-with-turo-and-other-platforms" data-gd-task><h2 class="gd-h2">Calendar sync with Turo and other platforms</h2><p class="gd-p"><b class="gd-ui">Cars</b> &gt; <b class="gd-ui">Calendar sync</b>: a car listed on Turo or Getaround must never be booked twice.</p><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">On the platform, copy the car&#39;s calendar link (iCal, it ends in .ics). Here, find the car, open <b class="gd-ui">Add a calendar link</b>, choose the platform, paste it and press <b class="gd-ui">Add the link</b>.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Its trips block the car here with the turnaround before and after, read every 10 minutes. The card shows &quot;Working&quot; and the next trips.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Copy the car&#39;s CarmaCars link &quot;For Turo&quot; (or Getaround) with <b class="gd-ui">Copy</b> and paste it into the platform&#39;s calendar import. It shows only &quot;Booked&quot;.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t">A double booking raises an urgent task for you and an email: move, swap or cancel one trip. A link that stops working raises a task after 3 failed reads: copy it from the platform again.</div></li></ol></div></section>');
-- GUIDES 0061 END

-- ================================================================ 12. the email catalogue
-- CATALOGUE 0061 START (generated by supabase/seed/0061_gen_catalogue.mjs; do not edit by hand)
insert into notification_catalogue (code, audience, also_sent_to, category, is_digest, digest_slot, from_address, reply_to,
    subject, preheader, timing, trigger_text, replaces_template, link_path, variables, template_html, template_text) values
  ('renter_google_review_request', 'renter', '{}'::text[], 'marketing', false, null, 'CarmaCars <hello@carmacars.ca>', 'contact@carmacars.ca', 'Would you review CarmaCars on Google?', 'A line or two helps other renters choose.', 'google_review_delay_days after the booking closes', 'Program settings google_review_delay_days (3 by default) after booking status becomes closed, only when the Google place id is set in Site settings (app.notify_google_reviews, migration 0061). The same rules as renter_review_request: not unsubscribed, nothing unpaid or open on the renter, and a booking that had a problem (an incident, a dispute, an unpaid balance or a damage charge) is sent only after a staff member answers yes to the review request decision. Never depends on the rating the renter gave, and offers nothing for a review. One per booking. Relies on the existing business relationship for consent, so it carries the unsubscribe link and mailing address.', null, null, '[{"name":"booking_number","type":"string"},{"name":"company_address","type":"string","global":true},{"name":"contact_email","type":"string","global":true},{"name":"first_name","type":"string"},{"name":"google_review_url","type":"url"},{"name":"instagram_url","type":"url","global":true},{"name":"opening_hours","type":"string","global":true},{"name":"pickup_date","type":"string"},{"name":"reply_time","type":"string","global":true},{"name":"return_date","type":"string"},{"name":"support_phone","type":"string","global":true},{"name":"tiktok_url","type":"url","global":true},{"name":"unsubscribe_url","type":"url"},{"name":"vehicle_image_url","type":"url"},{"name":"vehicle_name","type":"string"}]'::jsonb, 'templates/renter_google_review_request.html', 'templates/renter_google_review_request.txt')
on conflict (code) do update set
  audience = excluded.audience, also_sent_to = excluded.also_sent_to, category = excluded.category,
  is_digest = excluded.is_digest, digest_slot = excluded.digest_slot, from_address = excluded.from_address,
  reply_to = excluded.reply_to, subject = excluded.subject, preheader = excluded.preheader, timing = excluded.timing,
  trigger_text = excluded.trigger_text, replaces_template = excluded.replaces_template, link_path = excluded.link_path,
  variables = excluded.variables, template_html = excluded.template_html, template_text = excluded.template_text,
  in_catalogue = true, updated_at = now();
select app.notification_catalogue_refresh();
-- CATALOGUE 0061 END
update notification_catalogue set emitted_by = 'app.notify_google_reviews, through app.notify_followups (0061)' where code = 'renter_google_review_request';
