-- 2003_r36s_page_families.sql
-- Release 36, SEO (docs/changes/2026-11-11-r36-seo-growth.md): new page families, all from data.
--   5. Events: a page for each major Toronto and GTA event (/events/<slug>, hub /events) with the "rent a car for
--      <event>" angle. seo_events is seeded from the organisers' public pages with the months each is usually held
--      and the venue; exact dates are filled in by an Admin or marketing staff when the organiser announces them (the
--      page says "usually in <month>" until then, never a guessed date). Each change queues the page for IndexNow.
--   6. Turo problems: landing pages (/car-rental/<slug>, in the crawl scope) for people searching Turo cancellations,
--      deposits, fees, damage disputes and host no-shows. They describe CarmaCars' own process only, name Turo only
--      as what the reader searched, and say CarmaCars is not affiliated with Turo; nothing is said about Turo itself.
--   7. The GPS tracker product: its page (/gps-tracker) and a short section on every search page, from Program
--      settings (on or off, name, monthly price, install price, features, details). Prices left empty read "quoted".
--  10. Airports: /airport-car-rental/<code> for each active airport (Pearson, Billy Bishop): delivered to the terminal
--      at the standard delivery price (app.delivery_fee of each car, the lowest shown), no special offer.
--  11. Renting vs owning: the inputs of the /rent-vs-own pages. Program settings: the financing rate and term, the
--      kilometres a month, the yearly depreciation and the cleaning cost (assumptions set by CarmaCars, shown as
--      such); ownership_costs: sourced figures (insurance by age band and city, monthly parking by city, registration),
--      each with its source, loaded by an Admin or the seo-data workflow's curated CSV. A missing figure is left out.
-- No applied migration is edited.

-- ================================================================ 5. events
create table if not exists seo_events (
  slug           text primary key check (slug ~ '^[a-z0-9]+(-[a-z0-9]+)*$' and length(slug) <= 80),
  name           text not null check (length(name) between 3 and 120),
  category       text not null check (category in ('festival', 'film', 'parade', 'concerts', 'sports_season', 'fair', 'show', 'race', 'holiday_market', 'theme_park')),
  venue          text not null check (length(venue) between 2 and 120),
  venue_address  text check (venue_address is null or length(venue_address) <= 200),
  city           text not null default 'Toronto' check (length(city) between 2 and 60),
  lat            numeric(9, 6) not null check (lat between -90 and 90),
  lng            numeric(9, 6) not null check (lng between -180 and 180),
  usual_months   text not null check (length(usual_months) between 3 and 60),
  starts_on      date,
  ends_on        date,
  summary        text not null check (length(summary) between 20 and 600),
  source_name    text not null check (length(source_name) between 2 and 80),
  source_url     text not null check (source_url ~ '^https://'),
  is_active      boolean not null default true,
  sort_order     integer not null default 100,
  updated_by     uuid references users (id),
  created_at     timestamptz not null default now(),
  updated_at     timestamptz not null default now(),
  check (ends_on is null or starts_on is not null),
  check (ends_on is null or ends_on >= starts_on)
);
comment on table seo_events is 'Toronto and GTA events with a "rent a car for <event>" page (2003). usual_months is from the organiser''s past editions; starts_on and ends_on only once the organiser announces them.';
drop trigger if exists seo_events_updated on seo_events;
create trigger seo_events_updated before update on seo_events for each row execute function app.set_updated_at();
alter table seo_events enable row level security;
revoke all on seo_events from public, anon, authenticated;
grant select, insert, update, delete on seo_events to service_role;
drop policy if exists admin_all on seo_events;
create policy admin_all on seo_events for all to authenticated using (app.is_admin()) with check (app.is_admin());
drop trigger if exists audit_seo_events on seo_events;
create trigger audit_seo_events after insert or update or delete on seo_events for each row execute function app.audit_row();

insert into seo_events (slug, name, category, venue, venue_address, city, lat, lng, usual_months, summary, source_name, source_url, sort_order) values
  ('tiff', 'Toronto International Film Festival (TIFF)', 'film', 'TIFF Lightbox and King Street West', '350 King St W, Toronto', 'Toronto', 43.646500, -79.390300, 'September',
   'Ten days of premieres and screenings around King Street West and theatres across downtown Toronto.', 'TIFF', 'https://tiff.net/', 10),
  ('toronto-caribbean-carnival', 'Toronto Caribbean Carnival (Caribana)', 'parade', 'Exhibition Place and Lake Shore Boulevard', 'Exhibition Place, Toronto', 'Toronto', 43.633600, -79.418600, 'July and August',
   'Weeks of events ending with the Grand Parade along Lake Shore Boulevard West by Exhibition Place.', 'Toronto Caribbean Carnival', 'https://www.torontocarnival.ca/', 20),
  ('cne', 'Canadian National Exhibition (CNE)', 'fair', 'Exhibition Place', '210 Princes'' Blvd, Toronto', 'Toronto', 43.633600, -79.418600, 'August to Labour Day',
   'The late-summer fair at Exhibition Place: rides, food, shows and the air show.', 'The Ex', 'https://theex.com/', 30),
  ('pride-toronto', 'Pride Toronto', 'festival', 'Church-Wellesley Village', 'Church St and Wellesley St E, Toronto', 'Toronto', 43.665500, -79.380700, 'June',
   'The Pride Month festival and parades in and around the Church-Wellesley Village.', 'Pride Toronto', 'https://www.pridetoronto.com/', 40),
  ('veld-music-festival', 'Veld Music Festival', 'concerts', 'Downsview Park', '70 Canuck Ave, Toronto', 'Toronto', 43.744000, -79.480000, 'Late July or early August',
   'A weekend of electronic and hip hop music at Downsview Park in North York.', 'Veld Music Festival', 'https://www.veldmusicfestival.com/', 50),
  ('toronto-raptors-season', 'Toronto Raptors home games', 'sports_season', 'Scotiabank Arena', '40 Bay St, Toronto', 'Toronto', 43.643500, -79.379100, 'October to April',
   'NBA regular season home games at Scotiabank Arena, by Union Station.', 'Toronto Raptors', 'https://www.nba.com/raptors/', 60),
  ('toronto-maple-leafs-season', 'Toronto Maple Leafs home games', 'sports_season', 'Scotiabank Arena', '40 Bay St, Toronto', 'Toronto', 43.643500, -79.379100, 'October to April',
   'NHL regular season home games at Scotiabank Arena, by Union Station.', 'Toronto Maple Leafs', 'https://www.nhl.com/mapleleafs/', 70),
  ('toronto-blue-jays-season', 'Toronto Blue Jays home games', 'sports_season', 'Rogers Centre', '1 Blue Jays Way, Toronto', 'Toronto', 43.641400, -79.389400, 'April to September',
   'MLB regular season home games at Rogers Centre, beside the CN Tower.', 'Toronto Blue Jays', 'https://www.mlb.com/bluejays', 80),
  ('rogers-centre-concerts', 'Concerts at Rogers Centre', 'concerts', 'Rogers Centre', '1 Blue Jays Way, Toronto', 'Toronto', 43.641400, -79.389400, 'Through the year, mostly summer',
   'Stadium concerts and tours at Rogers Centre in downtown Toronto.', 'Rogers Centre', 'https://www.mlb.com/bluejays/ballpark', 90),
  ('scotiabank-arena-concerts', 'Concerts at Scotiabank Arena', 'concerts', 'Scotiabank Arena', '40 Bay St, Toronto', 'Toronto', 43.643500, -79.379100, 'Through the year',
   'Arena concerts and shows at Scotiabank Arena, by Union Station.', 'Scotiabank Arena', 'https://www.scotiabankarena.com/', 100),
  ('toronto-fc-season', 'Toronto FC home games', 'sports_season', 'BMO Field', '170 Princes'' Blvd, Toronto', 'Toronto', 43.633200, -79.418600, 'February to October',
   'MLS home games at BMO Field, Exhibition Place.', 'Toronto FC', 'https://www.torontofc.ca/', 110),
  ('toronto-argonauts-season', 'Toronto Argonauts home games', 'sports_season', 'BMO Field', '170 Princes'' Blvd, Toronto', 'Toronto', 43.633200, -79.418600, 'June to October',
   'CFL home games at BMO Field, Exhibition Place.', 'Toronto Argonauts', 'https://www.argonauts.ca/', 120),
  ('canadian-international-autoshow', 'Canadian International AutoShow', 'show', 'Metro Toronto Convention Centre', '255 Front St W, Toronto', 'Toronto', 43.642600, -79.387100, 'February',
   'Canada''s largest auto show, at the Metro Toronto Convention Centre.', 'Canadian International AutoShow', 'https://autoshow.ca/', 130),
  ('honda-indy-toronto', 'Honda Indy Toronto', 'race', 'Exhibition Place street circuit', 'Exhibition Place, Toronto', 'Toronto', 43.633600, -79.418600, 'July',
   'The IndyCar street race weekend around Exhibition Place.', 'Honda Indy Toronto', 'https://www.hondaindy.com/', 140),
  ('royal-agricultural-winter-fair', 'Royal Agricultural Winter Fair', 'fair', 'Enercare Centre, Exhibition Place', '100 Princes'' Blvd, Toronto', 'Toronto', 43.635700, -79.415500, 'November',
   'The indoor agricultural fair and horse show at Exhibition Place.', 'The Royal', 'https://www.royalfair.org/', 150),
  ('nuit-blanche-toronto', 'Nuit Blanche Toronto', 'festival', 'Across Toronto, around Nathan Phillips Square', '100 Queen St W, Toronto', 'Toronto', 43.652500, -79.383200, 'Late September or October',
   'The all-night contemporary art event across the city.', 'City of Toronto', 'https://www.toronto.ca/explore-enjoy/festivals-events/nuitblanche/', 160),
  ('toronto-christmas-market', 'Toronto Christmas Market', 'holiday_market', 'Distillery District', '55 Mill St, Toronto', 'Toronto', 43.650300, -79.359600, 'November and December',
   'The holiday market in the Distillery District''s brick lanes.', 'Distillery Winter Village', 'https://www.thedistillerydistrict.com/', 170),
  ('canadas-wonderland-season', 'Canada''s Wonderland season', 'theme_park', 'Canada''s Wonderland', '1 Canada''s Wonderland Dr, Vaughan', 'Vaughan', 43.843000, -79.539500, 'May to October',
   'The theme park''s season in Vaughan, north of Toronto, with Halloween Haunt in the fall.', 'Canada''s Wonderland', 'https://www.canadaswonderland.com/', 180),
  ('taste-of-the-danforth', 'Taste of the Danforth', 'festival', 'Danforth Avenue', 'Danforth Ave, Toronto', 'Toronto', 43.677900, -79.350000, 'August',
   'The street food festival along Danforth Avenue in Greektown.', 'Taste of the Danforth', 'https://tasteofthedanforth.com/', 190)
on conflict (slug) do nothing;

-- IndexNow: an event page (and its languages, 2004) when it changes
create or replace function app.indexnow_on_event() returns trigger
language plpgsql security definer set search_path = public, app as $$
begin
  if tg_op = 'DELETE' then return null; end if;
  if new.is_active then
    perform app.indexnow_queue_path('/events/' || new.slug, 'event');
    if tg_op = 'INSERT' then perform app.indexnow_queue_path('/events', 'events'); end if;
  end if;
  return null;
end $$;
drop trigger if exists indexnow_on_event on seo_events;
create trigger indexnow_on_event after insert or update on seo_events for each row execute function app.indexnow_on_event();

-- an Admin or marketing staff save an event (insert or update by slug)
create or replace function app.seo_event_save(p_by uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  v_slug text := lower(btrim(coalesce(p ->> 'slug', '')));
  e seo_events;
begin
  if not (app.user_is_admin(p_by) or app.user_va_has(p_by, variadic array['sales'])) then raise exception 'Only an Admin or sales can edit events' using errcode = '42501'; end if;
  if v_slug = '' then v_slug := trim(both '-' from regexp_replace(lower(coalesce(p ->> 'name', '')), '[^a-z0-9]+', '-', 'g')); end if;
  if exists (select 1 from seo_events where slug = v_slug) then
    update seo_events e0 set
    name = coalesce(nullif(btrim(p ->> 'name'), ''), e0.name), category = coalesce(nullif(p ->> 'category', ''), e0.category),
    venue = coalesce(nullif(btrim(p ->> 'venue'), ''), e0.venue), venue_address = coalesce(nullif(btrim(p ->> 'venue_address'), ''), e0.venue_address),
    lat = coalesce((p ->> 'lat')::numeric, e0.lat), lng = coalesce((p ->> 'lng')::numeric, e0.lng),
    usual_months = coalesce(nullif(btrim(p ->> 'usual_months'), ''), e0.usual_months),
    starts_on = case when p ? 'starts_on' then nullif(p ->> 'starts_on', '')::date else e0.starts_on end,
    ends_on = case when p ? 'ends_on' then nullif(p ->> 'ends_on', '')::date else e0.ends_on end,
    summary = coalesce(nullif(btrim(p ->> 'summary'), ''), e0.summary), source_name = coalesce(nullif(btrim(p ->> 'source_name'), ''), e0.source_name),
    source_url = coalesce(nullif(btrim(p ->> 'source_url'), ''), e0.source_url), is_active = coalesce((p ->> 'is_active')::boolean, e0.is_active), updated_by = p_by
     where e0.slug = v_slug
    returning * into e;
  else
  insert into seo_events (slug, name, category, venue, venue_address, city, lat, lng, usual_months, starts_on, ends_on, summary, source_name, source_url, is_active, updated_by)
    values (v_slug, btrim(p ->> 'name'), p ->> 'category', btrim(p ->> 'venue'), nullif(btrim(p ->> 'venue_address'), ''), coalesce(nullif(btrim(p ->> 'city'), ''), 'Toronto'),
            (p ->> 'lat')::numeric, (p ->> 'lng')::numeric, btrim(p ->> 'usual_months'), nullif(p ->> 'starts_on', '')::date, nullif(p ->> 'ends_on', '')::date,
            btrim(p ->> 'summary'), btrim(p ->> 'source_name'), btrim(p ->> 'source_url'), coalesce((p ->> 'is_active')::boolean, true), p_by)
    returning * into e;
  end if;
  return to_jsonb(e);
end $$;

create or replace function public.seo_events_list() returns jsonb
language sql stable security definer set search_path = public, app as $$
  select coalesce(jsonb_agg(to_jsonb(e) - 'updated_by' - 'created_at' order by e.sort_order, e.name), '[]'::jsonb) from seo_events e where e.is_active
$$;
create or replace function public.seo_event(p_slug text) returns jsonb
language sql stable security definer set search_path = public, app as $$
  select to_jsonb(e) - 'updated_by' - 'created_at' from seo_events e where e.slug = p_slug and e.is_active
$$;

-- ================================================================ 6. Turo problems (landing pages, factual)
insert into seo_pages (slug, kind, name, sort_order, facts, match, copy, source, status) values
  ('turo-trip-cancelled', 'use', 'Turo trip cancelled? Rent a car', 600, '{"topic": "a trip cancelled on another platform"}', '{"all": true}',
   jsonb_build_object('seo_title', 'Turo Trip Cancelled? Rent a Car in Toronto | {{brand}}', 'meta_description', 'Trip cancelled? Send {{brand}} your dates: we confirm the car and the full price before you pay, delivered or picked up in Toronto.',
     'h1', 'Turo trip cancelled? Rent a car with {{brand}}',
     'intro', 'If a trip you booked elsewhere was cancelled, send us your dates and we confirm a car and the full price before you pay. One company handles the car, the rental agreement, the deposit and support, from the request to the return. Turo is named only to describe what you searched; {{brand}} is not affiliated with, approved or endorsed by Turo.',
     'sections', jsonb_build_array(
       jsonb_build_object('heading', 'How a request works', 'body', 'Choose a car and your dates and send a request with no payment. We confirm the car and the price, you approve the offer, and only then do you pay. Book at least {{notice}} before pickup.'),
       jsonb_build_object('heading', 'Delivered when you need it', 'body', 'We deliver across {{deliveryArea}} and to Toronto Pearson and Billy Bishop airports, or you pick the car up from us. Delivery starts at {{delMin}}.')),
     'faq', jsonb_build_array(jsonb_build_object('question', 'Is {{brand}} part of Turo?', 'answer', 'No. {{brand}} is not affiliated with, approved or endorsed by Turo. You book with {{brand}} directly, on this site.'),
       jsonb_build_object('question', 'How fast can I get a car?', 'answer', 'Book at least {{notice}} before pickup. We reply {{replyShort}}.'))), 'seed', 'published'),
  ('turo-deposit-alternative', 'use', 'Car rental deposit explained', 610, '{"topic": "the security deposit"}', '{"all": true}',
   jsonb_build_object('seo_title', 'Car Rental Deposit in Toronto, Explained | {{brand}}', 'meta_description', 'How the {{brand}} deposit works: a hold of {{depMin}} to {{depMax}} on your card, taken {{depLead}} before pickup and released within {{releaseDays}}.',
     'h1', 'The car rental deposit, explained',
     'intro', 'At {{brand}} the deposit is a hold on your card of {{depMin}} to {{depMax}}, depending on the car. It is taken about {{depLead}} before pickup, never when you book, and released within {{releaseDays}} after you return the car. Searching about a Turo deposit? Turo is named only to describe what you searched; {{brand}} is not affiliated with, approved or endorsed by Turo.',
     'sections', jsonb_build_array(
       jsonb_build_object('heading', 'When the hold is released', 'body', 'After the return we check the car, the fuel and the kilometres. The hold is released within {{releaseDays}}; any charge is listed line by line first.'),
       jsonb_build_object('heading', 'Every fee on the offer', 'body', 'Your offer shows the rental, delivery, extras and HST before you pay. Standard fees are on the fees page and the requirements page.')),
     'faq', jsonb_build_array(jsonb_build_object('question', 'Is the deposit a charge?', 'answer', 'It is a hold on your card, released within {{releaseDays}} after the return.'),
       jsonb_build_object('question', 'Is {{brand}} part of Turo?', 'answer', 'No. {{brand}} is not affiliated with, approved or endorsed by Turo.'))), 'seed', 'published'),
  ('turo-fees-alternative', 'use', 'Car rental with every fee up front', 620, '{"topic": "fees"}', '{"all": true}',
   jsonb_build_object('seo_title', 'Car Rental With Every Fee Up Front in Toronto | {{brand}}', 'meta_description', 'See the full price before you pay: rental, delivery, extras and HST on one offer from {{brand}}. Request with no payment.',
     'h1', 'Car rental with every fee shown before you pay',
     'intro', 'Every {{brand}} car shows its daily, weekly and monthly rate, the deposit and the kilometres included. Your offer lists the rental, delivery, extras and HST before you pay, and you approve it first. Searching about Turo fees? Turo is named only to describe what you searched; {{brand}} is not affiliated with, approved or endorsed by Turo.',
     'sections', jsonb_build_array(
       jsonb_build_object('heading', 'What the offer shows', 'body', 'The rental for your dates, delivery and return, any extras you chose, the deposit hold and {{hst}} HST. Trips of {{weekFrom}} days or more use the weekly rate.'),
       jsonb_build_object('heading', 'The standard fees', 'body', 'Young driver, additional driver, late return, fuel, cleaning and tolls are listed on the requirements page with their amounts.')),
     'faq', jsonb_build_array(jsonb_build_object('question', 'When do I see the full price?', 'answer', 'In your offer, before you pay. You approve it first.'),
       jsonb_build_object('question', 'Is {{brand}} part of Turo?', 'answer', 'No. {{brand}} is not affiliated with, approved or endorsed by Turo.'))), 'seed', 'published'),
  ('turo-damage-claim-alternative', 'use', 'Car rental damage process, step by step', 630, '{"topic": "damage"}', '{"all": true}',
   jsonb_build_object('seo_title', 'Car Rental Damage Process in Toronto | {{brand}}', 'meta_description', 'How {{brand}} handles damage: photos at pickup and return, a written report, the {{deductible}} deductible on our fleet policy and your coverage options.',
     'h1', 'The damage process, step by step',
     'intro', 'At pickup and at return the car is photographed with you, so its condition is on record for both of us. Third-party liability is included in every rate; for damage to the car you choose a coverage option before pickup, and a claim on our fleet policy costs the {{deductible}} deductible. Searching about a Turo damage dispute? Turo is named only to describe what you searched; {{brand}} is not affiliated with, approved or endorsed by Turo.',
     'sections', jsonb_build_array(
       jsonb_build_object('heading', 'Photos at both ends', 'body', 'The handover photos are kept with your booking, with the time they were taken.'),
       jsonb_build_object('heading', 'A written report', 'body', 'Any damage found at the return is written up with its photos and the cost, before anything is charged.')),
     'faq', jsonb_build_array(jsonb_build_object('question', 'What is the deductible?', 'answer', '{{deductible}} on a claim on our fleet policy.'),
       jsonb_build_object('question', 'Is {{brand}} part of Turo?', 'answer', 'No. {{brand}} is not affiliated with, approved or endorsed by Turo.'))), 'seed', 'published'),
  ('turo-host-no-show-alternative', 'use', 'Host did not show up? Rent a car today', 640, '{"topic": "a missed handover"}', '{"all": true}',
   jsonb_build_object('seo_title', 'Car Handover on Time in Toronto | {{brand}}', 'meta_description', 'Need a car now? {{brand}} delivers to your address or the airport at the time we confirm, or you pick it up from us.',
     'h1', 'Need a car now? We meet you with it',
     'intro', 'Waiting for a handover that did not happen? Send {{brand}} a request: we confirm the car, the time and the place, and we meet you with the car at the time we confirm, at your address, at Toronto Pearson or Billy Bishop, or at our location. Turo is named only to describe what you searched; {{brand}} is not affiliated with, approved or endorsed by Turo.',
     'sections', jsonb_build_array(
       jsonb_build_object('heading', 'A confirmed time', 'body', 'Your offer states the handover time and place. Book at least {{notice}} before pickup; we reply {{replyShort}}.'),
       jsonb_build_object('heading', 'One company', 'body', '{{brand}} handles the car, the agreement, the deposit and support, from the request to the return.')),
     'faq', jsonb_build_array(jsonb_build_object('question', 'Can you deliver to the airport?', 'answer', 'Yes, to Toronto Pearson and Billy Bishop, at the time we confirm.'),
       jsonb_build_object('question', 'Is {{brand}} part of Turo?', 'answer', 'No. {{brand}} is not affiliated with, approved or endorsed by Turo.'))), 'seed', 'published')
on conflict (slug) do nothing;

-- ================================================================ 7. the GPS tracker product
alter table program_settings
  add column if not exists tracker_product_enabled boolean not null default true,
  add column if not exists tracker_product_name text not null default 'CarmaCars GPS tracker' check (length(tracker_product_name) between 3 and 80),
  add column if not exists tracker_product_monthly_cents integer check (tracker_product_monthly_cents is null or tracker_product_monthly_cents between 0 and 100000),
  add column if not exists tracker_product_install_cents integer check (tracker_product_install_cents is null or tracker_product_install_cents between 0 and 500000),
  add column if not exists tracker_product_features jsonb not null default '[
    {"title": "Live location", "text": "See where the car is on a map, from your phone or computer."},
    {"title": "Trip history", "text": "Each trip''s route, times and distance, kept with the car."},
    {"title": "Frequent readings", "text": "A location reading at least every {{trackerMinutes}} minutes while the car moves."},
    {"title": "Installed by us", "text": "We install the tracker and check it works before the car goes out."}]'::jsonb
    check (jsonb_typeof(tracker_product_features) = 'array' and jsonb_array_length(tracker_product_features) <= 12),
  add column if not exists tracker_product_details text check (tracker_product_details is null or length(tracker_product_details) <= 2000);
comment on column program_settings.tracker_product_enabled is 'The GPS tracker product (2003): its page /gps-tracker and the section on the search pages. Off hides both.';
comment on column program_settings.tracker_product_monthly_cents is 'The GPS tracker product (2003): the monthly price shown; empty: the page reads "quoted" (falls back to owner_calc_tracker_fee).';
comment on column program_settings.tracker_product_features is 'The GPS tracker product (2003): [{title, text}] shown on its page; {{trackerMinutes}} is tracker_reading_max_minutes.';

create or replace function public.tracker_product() returns jsonb
language sql stable security definer set search_path = public, app as $$
  select case when s.tracker_product_enabled then jsonb_build_object('name', s.tracker_product_name,
    'monthly_cents', coalesce(s.tracker_product_monthly_cents, s.owner_calc_tracker_fee), 'install_cents', s.tracker_product_install_cents,
    'features', (select coalesce(jsonb_agg(jsonb_build_object('title', f ->> 'title', 'text', replace(f ->> 'text', '{{trackerMinutes}}', s.tracker_reading_max_minutes::text))), '[]'::jsonb)
                   from jsonb_array_elements(s.tracker_product_features) f),
    'details', s.tracker_product_details) end
    from (select (app.settings()).*) s
$$;

-- ================================================================ 10. airports
create or replace function public.airport_pages() returns jsonb
language sql stable security definer set search_path = public, app as $$
  select coalesce(jsonb_agg(jsonb_build_object('code', a.code, 'name', a.name, 'lat', a.latitude, 'lng', a.longitude,
           'km', coalesce(a.distance_km, round(app.distance_km(s.company_latitude, s.company_longitude, a.latitude, a.longitude), 1)),
           'delivery_from_cents', (select min((app.delivery_fee(v.id, 'delivery', jsonb_build_object('kind', 'airport', 'airport_code', a.code)) ->> 'fee_cents')::bigint)
                                     from vehicles v join vehicle_listings l on l.vehicle_id = v.id
                                    where l.status = 'published' and not v.is_sample and v.management_mode <> 'turo_only' and v.retired_at is null))
         order by a.sort_order, a.code), '[]'::jsonb)
    from airports a cross join (select (app.settings()).*) s where a.is_active
$$;

-- ================================================================ 11. renting vs owning
alter table program_settings
  add column if not exists own_apr_bps integer not null default 799 check (own_apr_bps between 0 and 3000),
  add column if not exists own_term_months integer not null default 60 check (own_term_months between 12 and 96),
  add column if not exists own_km_per_month integer not null default 1500 check (own_km_per_month between 100 and 10000),
  add column if not exists own_depreciation_bps integer not null default 1500 check (own_depreciation_bps between 0 and 5000),
  add column if not exists own_cleaning_monthly_cents integer check (own_cleaning_monthly_cents is null or own_cleaning_monthly_cents between 0 and 100000);
comment on column program_settings.own_apr_bps is 'Renting vs owning (2003): the financing rate assumed on the price (799 = 7.99%), shown as a CarmaCars assumption.';
comment on column program_settings.own_term_months is 'Renting vs owning (2003): the loan term assumed (60 months).';
comment on column program_settings.own_km_per_month is 'Renting vs owning (2003): the kilometres a month behind the fuel cost (1,500).';
comment on column program_settings.own_depreciation_bps is 'Renting vs owning (2003): the yearly loss of value assumed on the price (1,500 = 15%).';
comment on column program_settings.own_cleaning_monthly_cents is 'Renting vs owning (2003): cleaning and detailing a month; empty: left out.';

create table if not exists ownership_costs (
  id            bigint generated always as identity primary key,
  component     text not null check (component in ('insurance', 'parking', 'registration')),
  scope         text not null default '' check (length(scope) <= 60),   -- insurance: '<age band>|<city slug or ''>'; parking: city slug; registration: ''
  monthly_cents integer not null check (monthly_cents between 0 and 500000),
  note          text check (note is null or length(note) <= 300),
  source        text not null check (length(source) between 2 and 120),
  source_url    text not null check (source_url ~ '^https://'),
  fetched_at    timestamptz not null default now(),
  unique (component, scope)
);
comment on table ownership_costs is 'Sourced monthly costs of owning a car (2003) for the renting vs owning pages: insurance by age band and city, parking by city, registration. Each with its source; a missing one is left out of the page.';
alter table ownership_costs enable row level security;
revoke all on ownership_costs from public, anon, authenticated;
grant select, insert, update, delete on ownership_costs to service_role;
drop policy if exists admin_all on ownership_costs;
create policy admin_all on ownership_costs for all to authenticated using (app.is_admin()) with check (app.is_admin());
drop trigger if exists audit_ownership_costs on ownership_costs;
create trigger audit_ownership_costs after insert or update or delete on ownership_costs for each row execute function app.audit_row();
-- Ontario passenger vehicles: no licence plate sticker fee since March 13, 2022 (Ontario.ca)
insert into ownership_costs (component, scope, monthly_cents, note, source, source_url) values
  ('registration', '', 0, 'Ontario removed the licence plate sticker renewal fee for passenger vehicles in 2022.', 'Ontario.ca', 'https://www.ontario.ca/page/renew-your-licence-plate-sticker')
on conflict (component, scope) do nothing;

create or replace function app.server_ownership_load(p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare r jsonb; n integer := 0;
begin
  for r in select * from jsonb_array_elements(coalesce(p -> 'rows', '[]'::jsonb)) loop
    if coalesce(r ->> 'source_url', '') !~ '^https://' then raise exception 'ownership costs: every row needs its source_url'; end if;
    insert into ownership_costs (component, scope, monthly_cents, note, source, source_url, fetched_at)
    values (r ->> 'component', coalesce(r ->> 'scope', ''), (r ->> 'monthly_cents')::integer, r ->> 'note', r ->> 'source', r ->> 'source_url', coalesce((r ->> 'fetched_at')::timestamptz, now()))
    on conflict (component, scope) do update set monthly_cents = excluded.monthly_cents, note = excluded.note, source = excluded.source, source_url = excluded.source_url, fetched_at = excluded.fetched_at;
    n := n + 1;
  end loop;
  return jsonb_build_object('loaded', n);
end $$;

-- the inputs of one page: the settings, the sourced costs (for the city and age bands), the model year's specs and the
-- lowest monthly rate of our cars of that class
create or replace function public.rent_vs_own_inputs(p_make text, p_model text, p_year integer, p_city text default null) returns jsonb
language sql stable security definer set search_path = public, app as $$
  select jsonb_build_object(
    'apr_bps', s.own_apr_bps, 'term_months', s.own_term_months, 'km_per_month', s.own_km_per_month, 'depreciation_bps', s.own_depreciation_bps,
    'cleaning_monthly_cents', s.own_cleaning_monthly_cents, 'gas_cents', s.vpage_gas_cents_per_litre, 'premium_extra_cents', s.vpage_premium_extra_cents, 'kwh_cents', s.vpage_electricity_cents_per_kwh,
    'costs', (select coalesce(jsonb_agg(to_jsonb(c) - 'id' order by c.component, c.scope), '[]'::jsonb) from ownership_costs c
               where c.component = 'registration' or (c.component = 'parking' and c.scope = coalesce(p_city, 'toronto'))
                  or (c.component = 'insurance' and (split_part(c.scope, '|', 2) = coalesce(p_city, '') or split_part(c.scope, '|', 2) = ''))),
    'specs', public.vehicle_specs_for(p_make, p_model, p_year),
    'catalog', (select jsonb_build_object('vclass', y.vclass, 'l100_min', y.l100_min, 'kwh100_min', y.kwh100_min)
                  from vehicle_catalog_years y join vehicle_catalog_makes mk on mk.slug = y.make_slug join vehicle_catalog_models md on md.make_slug = y.make_slug and md.slug = y.model_slug
                 where lower(mk.name) = lower(p_make) and lower(md.name) = lower(p_model) and y.year = p_year limit 1),
    'rental', (select jsonb_build_object('monthly_cents', min(rc.monthly_rate_cents), 'class', v.class::text)
                 from vehicles v join vehicle_listings l on l.vehicle_id = v.id join rate_cards rc on rc.vehicle_id = v.id and rc.effective_from <= now() and (rc.effective_to is null or rc.effective_to > now())
                where l.status = 'published' and not v.is_sample and lower(v.make) = lower(p_make) and lower(v.model) = lower(p_model) group by v.class limit 1),
    'rental_any', (select min(rc.monthly_rate_cents) from vehicles v join vehicle_listings l on l.vehicle_id = v.id join rate_cards rc on rc.vehicle_id = v.id and rc.effective_from <= now() and (rc.effective_to is null or rc.effective_to > now())
                    where l.status = 'published' and not v.is_sample))
    from (select (app.settings()).*) s
$$;

-- ================================================================ the door: events (Admin, sales)
alter function app.door(uuid, text, text, text, jsonb) rename to door_pre2003;
create function app.door(p_user uuid, p_aal text, p_call text, p_name text, p jsonb default '{}'::jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
begin
  if p_call in ('ops_do', 'admin_do', 'va_do') and p_name = 'seo_event_save' then
    perform app.door_begin(p_user, p_aal);
    return app.seo_event_save(p_user, coalesce(p, '{}'::jsonb) - '_va');
  end if;
  if p_call in ('ops_read', 'admin_read', 'va_read') and p_name = 'seo_events' then
    perform app.door_begin(p_user, p_aal);
    if not (app.user_is_admin(p_user) or app.user_va_has(p_user, variadic array['sales'])) then raise exception 'Not allowed' using errcode = '42501'; end if;
    return (select coalesce(jsonb_agg(to_jsonb(e) order by e.sort_order, e.name), '[]'::jsonb) from seo_events e);
  end if;
  return app.door_pre2003(p_user, p_aal, p_call, p_name, p);
end $$;
do $$
declare g text;
begin
  execute 'revoke all on function app.door(uuid, text, text, text, jsonb) from public, anon, authenticated';
  foreach g in array array['anon', 'authenticated', 'service_role'] loop
    if has_function_privilege(g, 'app.door_pre2003(uuid, text, text, text, jsonb)'::regprocedure, 'execute') then execute format('grant execute on function app.door(uuid, text, text, text, jsonb) to %I', g); end if;
  end loop;
end $$;

revoke all on function app.indexnow_on_event(), app.seo_event_save(uuid, jsonb), app.server_ownership_load(jsonb), app.door_pre2003(uuid, text, text, text, jsonb) from public, anon, authenticated;
grant execute on function app.indexnow_on_event(), app.seo_event_save(uuid, jsonb), app.server_ownership_load(jsonb), app.door_pre2003(uuid, text, text, text, jsonb) to service_role;
grant execute on function public.seo_events_list(), public.seo_event(text), public.tracker_product(), public.airport_pages(), public.rent_vs_own_inputs(text, text, integer, text) to anon, authenticated, service_role;
