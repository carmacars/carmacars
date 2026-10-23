-- 0121: two owner decisions of October 23, 2026.
--   A. "Lawyer oked it": visit summaries are kept 13 months. 0118 kept them 90 days by default and left the privacy
--      policy as it was; the lawyer approved the 13 months, so program_settings.visitor_sessions_keep_days is 395 by
--      default (and now, where it is still 0118's 90), and the privacy policy's retention table gets the row the
--      visitor history branch wrote (docs/source/website_terms_policies.md, section 1). The policy's "last updated"
--      (site_content_blocks legal.meta, shared by the legal pages) becomes October 23, 2026.
--   B. "Make the pages for services we don't offer.": 0115 made no page for mechanical work. Mechanical repair and
--      maintenance (a mechanic, oil changes, brakes, tires, towing, batteries and boosts, alignment, transmission,
--      engine, diagnostics, inspections and the Ontario safety certificate, emissions, AC, exhaust, suspension) now
--      have their own search terms with a page for every place, in the body shop family (/body-shop/<term>/<place>,
--      the same template, switch and sitemaps), with synonyms (canonical_slug) as 0115 made them. They never say
--      CarmaCars does the work: each is a request (served 'request') of the new lead kind auto_service, which raises a
--      task for the team to arrange the work with a trusted shop or recommend one, and to offer a rental while the
--      car is in. No questions of their own (faq empty) and no rating. They stay out of the vehicle page trees
--      (app.vpage_terms), take their own four places in the priority sitemap, and are listed apart on the pages
--      (place_terms_public gives the lead kind).
-- No applied migration is edited.

-- ================================================================ A1. visit summaries: 13 months
alter table program_settings alter column visitor_sessions_keep_days set default 395;
update program_settings set visitor_sessions_keep_days = 395 where visitor_sessions_keep_days = 90;
comment on column program_settings.visitor_sessions_keep_days is 'Visitor history (0118, 0121): a visit''s summary (date, how it arrived, device, approximate city, pages viewed, conversions) is kept this many days (395, 13 months, by default, as the privacy policy says since the lawyer approved it on October 23, 2026). Never less than the page views and events (visitor_events_keep_days).';

-- ================================================================ A2. the privacy policy (section 1, retention)
-- The live copy changes only where it still carries our text; an Admin's own edit is left as it is.
update site_content_blocks
   set body = replace(body,
     '| Site visit records (pages, events) | 90 days; daily counts per car without personal information are kept |',
     '| Site visit records (pages, events) | 90 days; daily counts per car without personal information are kept |
| Site visit summaries (date, the site or campaign that sent you, first and last page, device, approximate city, number of pages, whether you sent a request or gave contact details) | 13 months; daily totals without personal information are kept |')
 where block_key = 'legal.privacy' and body like '%| Site visit records (pages, events) | 90 days; daily counts per car without personal information are kept |%'
   and body not like '%| Site visit summaries%';
update site_content_blocks set data = data || jsonb_build_object('last_updated', 'October 23, 2026')
 where block_key = 'legal.meta'
   and (data ->> 'last_updated') in ('October 8, 2026', 'October 16, 2026', 'October 19, 2026', 'October 20, 2026', 'October 21, 2026', 'October 22, 2026');

-- ================================================================ B1. the lead kind: mechanical work we arrange
do $$
declare
  d text;
  v text[];
begin
  select pg_get_constraintdef(oid) into d from pg_constraint where conrelid = 'leads'::regclass and conname = 'leads_kind_check';
  v := array(select distinct m[1] from regexp_matches(coalesce(d, ''), '''([a-z_]+)''', 'g') m);
  if cardinality(v) = 0 then raise exception 'leads_kind_check: cannot read the allowed kinds from %', d; end if;
  if not 'auto_service' = any (v) then v := v || 'auto_service'::text; end if;
  execute 'alter table leads drop constraint if exists leads_kind_check';
  execute format('alter table leads add constraint leads_kind_check check (kind = any (array[%s]))', (select string_agg(quote_literal(x), ', ' order by x) from unnest(v) x));
end $$;

alter table place_terms drop constraint if exists place_terms_lead_kind_check;
alter table place_terms add constraint place_terms_lead_kind_check
  check (lead_kind is null or lead_kind in ('buyer', 'finance', 'detailing', 'bodyshop', 'place_request', 'auto_service'));

insert into task_rules (task_type, queue, title, priority, due_kind, due_amount, description) values
  ('auto_service_request', 'cs', 'Mechanical work to arrange', 'high', 'opening_minutes', 60,
   'Someone asked for mechanical work from a place page (an oil change, brakes, tires, a tow and the like). CarmaCars does not do this work: arrange it with a trusted shop or recommend one, never promise a price or a time for the shop, and offer a rental while their car is in (0121)')
on conflict (task_type) do nothing;

-- 0095's request, with the new kind
create or replace function app.submit_place_lead(p jsonb, p_ip text default null) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  v_id uuid := gen_random_uuid();
  v_kind text := p ->> 'kind';
  v_email text := nullif(lower(btrim(p ->> 'email')), '');
  v_phone text := nullif(btrim(p ->> 'phone'), '');
  v_name text := nullif(btrim(p ->> 'name'), '');
  v_set program_settings := app.settings();
  v_payload jsonb := app.strip_transient(coalesce(p -> 'payload', '{}'::jsonb));
  v_task uuid;
begin
  if nullif(btrim(p_ip), '') is not null and not app.rate_limit('lead:ip:' || btrim(p_ip), v_set.lead_hourly_limit, interval '1 hour') then
    return jsonb_build_object('ok', false, 'error', 'rate_limited');
  end if;
  if v_kind is null or v_kind not in ('buyer', 'finance', 'place_request', 'detailing', 'bodyshop', 'auto_service') then
    raise exception 'Unknown kind of request: %', v_kind using errcode = '22023';
  end if;
  if v_email is null and v_phone is null then raise exception 'Give an email address or a phone number so we can reply' using errcode = '22023'; end if;
  if v_email is not null and v_email !~ '^[^@\s]+@[^@\s]+\.[^@\s]+$' then raise exception 'Enter a full email address, for example name@example.com' using errcode = '22023'; end if;
  if char_length(coalesce(p ->> 'message', '')) > 2000 then raise exception 'The message is too long (2,000 characters at most)' using errcode = '22023'; end if;
  insert into leads (id, kind, name, email, phone, message, payload, source, source_url, referrer)
  values (v_id, v_kind, v_name, v_email, v_phone, nullif(btrim(p ->> 'message'), ''), v_payload, coalesce(nullif(p ->> 'source', ''), 'web'), p ->> 'source_url', p ->> 'referrer');
  v_task := app.raise_task(p_type => case v_kind when 'detailing' then 'detailing_request' when 'bodyshop' then 'bodyshop_request' when 'buyer' then 'buyer_lead'
                                                 when 'finance' then 'finance_lead' when 'auto_service' then 'auto_service_request' else 'place_request' end,
                           p_detail => concat_ws(' ', coalesce(v_name, 'Someone'), 'asked',
                             case v_kind when 'detailing' then 'for detailing:' when 'bodyshop' then 'for body work:' when 'buyer' then 'for help finding a car:'
                                         when 'finance' then 'about financing or leasing:' when 'auto_service' then 'for mechanical work we arrange (not ours):' else 'for a car:' end,
                             concat_ws(', ', v_payload ->> 'service', v_payload ->> 'vehicle', v_payload ->> 'damage', v_payload ->> 'place', v_payload ->> 'date',
                                       v_payload ->> 'where', case when v_payload ->> 'insurance_claim' = 'yes' then 'insurance claim' end, v_payload ->> 'term'),
                             nullif(btrim(p ->> 'message'), '')),
                           p_related_table => 'leads', p_related_id => v_id, p_dedupe => 'lead:' || v_id);
  return jsonb_build_object('ok', true, 'lead_id', v_id);
end $$;

-- ================================================================ B2. the terms with their own pages
insert into place_terms (slug, vertical, phrase, title, served, lead_kind, intent_note, faq, sort_order)
select x.slug, 'bodyshop', x.phrase, x.title, 'request', 'auto_service', x.note, '[]'::jsonb, 400 + x.o * 10 from (values
  ('mechanic', 'mechanic', 'Mechanic', 'Repairs and maintenance by a mechanic at a trusted shop we arrange, not by CarmaCars.', 1),
  ('oil-change', 'oil change', 'Oil Change', 'An oil and filter change, done by a trusted shop we arrange, not by CarmaCars.', 2),
  ('brake-repair', 'brake repair', 'Brake Repair', 'Brake pads, rotors and calipers checked and replaced, by a trusted shop we arrange, not by CarmaCars.', 3),
  ('tire-change', 'tire change', 'Tire Change', 'Seasonal tires swapped and balanced, by a trusted shop we arrange, not by CarmaCars.', 4),
  ('tire-shop', 'tire shop', 'Tire Shop', 'New tires bought and installed at a trusted tire shop we arrange, not by CarmaCars.', 5),
  ('winter-tires', 'winter tires', 'Winter Tires', 'Winter tires bought or put on for the season, by a trusted shop we arrange, not by CarmaCars.', 6),
  ('tire-repair', 'tire repair', 'Tire Repair', 'A flat or punctured tire repaired or replaced, by a trusted shop we arrange, not by CarmaCars.', 7),
  ('towing', 'towing', 'Towing', 'A tow to a shop or to your home, by a towing company we arrange, not by CarmaCars. If you are in danger or blocking traffic, call 911 first.', 8),
  ('car-battery-replacement', 'car battery replacement', 'Car Battery Replacement', 'A car battery tested and replaced, by a trusted shop we arrange, not by CarmaCars.', 9),
  ('battery-boost', 'battery boost', 'Battery Boost', 'A boost for a dead battery, by a roadside service we arrange, not by CarmaCars.', 10),
  ('wheel-alignment', 'wheel alignment', 'Wheel Alignment', 'Wheels aligned so the car drives straight and the tires wear evenly, by a trusted shop we arrange, not by CarmaCars.', 11),
  ('transmission-repair', 'transmission repair', 'Transmission Repair', 'Transmission service, repair or replacement, by a trusted shop we arrange, not by CarmaCars.', 12),
  ('engine-repair', 'engine repair', 'Engine Repair', 'Engine repair, from a leak to a rebuild, by a trusted shop we arrange, not by CarmaCars.', 13),
  ('car-diagnostics', 'car diagnostics', 'Car Diagnostics', 'A diagnostic scan when a warning light is on or something feels wrong, by a trusted shop we arrange, not by CarmaCars.', 14),
  ('car-inspection', 'car inspection', 'Car Inspection', 'A mechanical inspection, for example before you buy a used car, by a trusted shop we arrange, not by CarmaCars.', 15),
  ('safety-certificate', 'safety certificate', 'Safety Certificate', 'A Safety Standards Certificate, needed in Ontario to register a used car you buy, issued by a licensed Motor Vehicle Inspection Station we arrange, not by CarmaCars.', 16),
  ('emissions-test', 'emissions test', 'Emissions Test', 'An emissions test or emissions repair where your province or state requires one, by a licensed shop we arrange, not by CarmaCars.', 17),
  ('car-ac-repair', 'car AC repair', 'Car AC Repair', 'Air conditioning checked, recharged or repaired, by a trusted shop we arrange, not by CarmaCars.', 18),
  ('exhaust-repair', 'exhaust repair', 'Exhaust Repair', 'Mufflers, pipes and catalytic converters repaired or replaced, by a trusted shop we arrange, not by CarmaCars.', 19),
  ('suspension-repair', 'suspension repair', 'Suspension Repair', 'Shocks, struts and steering parts repaired or replaced, by a trusted shop we arrange, not by CarmaCars.', 20)
) x(slug, phrase, title, note, o)
on conflict do nothing;

-- ================================================================ B3. synonyms: the term's pages, by another name (0115's rule)
insert into place_terms (slug, vertical, phrase, title, canonical_slug, match, served, landing_slug, service_code, lead_kind, intent_note, faq, sort_order)
select x.slug, t.vertical, x.phrase, x.title, t.slug, t.match, t.served, t.landing_slug, t.service_code, t.lead_kind, t.intent_note, t.faq, t.sort_order + 1
  from (values
    ('car-mechanic', 'car mechanic', 'Car Mechanic', 'mechanic'),
    ('auto-mechanic', 'auto mechanic', 'Auto Mechanic', 'mechanic'),
    ('mechanic-shop', 'mechanic shop', 'Mechanic Shop', 'mechanic'),
    ('mechanical-repair', 'mechanical repair', 'Mechanical Repair', 'mechanic'),
    ('car-garage', 'car garage', 'Car Garage', 'mechanic'),
    ('car-maintenance', 'car maintenance', 'Car Maintenance', 'mechanic'),
    ('car-servicing', 'car servicing', 'Car Servicing', 'mechanic'),
    ('tune-up', 'tune up', 'Tune Up', 'mechanic'),
    ('car-oil-change', 'car oil change', 'Car Oil Change', 'oil-change'),
    ('oil-and-filter-change', 'oil and filter change', 'Oil and Filter Change', 'oil-change'),
    ('synthetic-oil-change', 'synthetic oil change', 'Synthetic Oil Change', 'oil-change'),
    ('brake-service', 'brake service', 'Brake Service', 'brake-repair'),
    ('brake-replacement', 'brake replacement', 'Brake Replacement', 'brake-repair'),
    ('brake-pad-replacement', 'brake pad replacement', 'Brake Pad Replacement', 'brake-repair'),
    ('tire-swap', 'tire swap', 'Tire Swap', 'tire-change'),
    ('seasonal-tire-change', 'seasonal tire change', 'Seasonal Tire Change', 'tire-change'),
    ('tire-store', 'tire store', 'Tire Store', 'tire-shop'),
    ('tire-installation', 'tire installation', 'Tire Installation', 'tire-shop'),
    ('new-tires', 'new tires', 'New Tires', 'tire-shop'),
    ('snow-tires', 'snow tires', 'Snow Tires', 'winter-tires'),
    ('winter-tire-installation', 'winter tire installation', 'Winter Tire Installation', 'winter-tires'),
    ('winter-tire-change', 'winter tire change', 'Winter Tire Change', 'winter-tires'),
    ('flat-tire-repair', 'flat tire repair', 'Flat Tire Repair', 'tire-repair'),
    ('tire-puncture-repair', 'tire puncture repair', 'Tire Puncture Repair', 'tire-repair'),
    ('tow-truck', 'tow truck', 'Tow Truck', 'towing'),
    ('towing-service', 'towing service', 'Towing Service', 'towing'),
    ('car-towing', 'car towing', 'Car Towing', 'towing'),
    ('tow-service', 'tow service', 'Tow Service', 'towing'),
    ('battery-replacement', 'battery replacement', 'Battery Replacement', 'car-battery-replacement'),
    ('car-battery', 'car battery', 'Car Battery', 'car-battery-replacement'),
    ('car-boost', 'car boost', 'Car Boost', 'battery-boost'),
    ('jump-start', 'jump start', 'Jump Start', 'battery-boost'),
    ('boost-service', 'boost service', 'Boost Service', 'battery-boost'),
    ('alignment', 'alignment', 'Alignment', 'wheel-alignment'),
    ('car-alignment', 'car alignment', 'Car Alignment', 'wheel-alignment'),
    ('tire-alignment', 'tire alignment', 'Tire Alignment', 'wheel-alignment'),
    ('transmission-shop', 'transmission shop', 'Transmission Shop', 'transmission-repair'),
    ('transmission-service', 'transmission service', 'Transmission Service', 'transmission-repair'),
    ('engine-rebuild', 'engine rebuild', 'Engine Rebuild', 'engine-repair'),
    ('engine-replacement', 'engine replacement', 'Engine Replacement', 'engine-repair'),
    ('check-engine-light', 'check engine light', 'Check Engine Light', 'car-diagnostics'),
    ('car-diagnostic-test', 'car diagnostic test', 'Car Diagnostic Test', 'car-diagnostics'),
    ('auto-diagnostics', 'auto diagnostics', 'Auto Diagnostics', 'car-diagnostics'),
    ('vehicle-inspection', 'vehicle inspection', 'Vehicle Inspection', 'car-inspection'),
    ('pre-purchase-inspection', 'pre-purchase inspection', 'Pre-Purchase Inspection', 'car-inspection'),
    ('safety-inspection', 'safety inspection', 'Safety Inspection', 'safety-certificate'),
    ('ontario-safety-certificate', 'Ontario safety certificate', 'Ontario Safety Certificate', 'safety-certificate'),
    ('safety-standards-certificate', 'safety standards certificate', 'Safety Standards Certificate', 'safety-certificate'),
    ('emissions-testing', 'emissions testing', 'Emissions Testing', 'emissions-test'),
    ('smog-check', 'smog check', 'Smog Check', 'emissions-test'),
    ('auto-ac-repair', 'auto AC repair', 'Auto AC Repair', 'car-ac-repair'),
    ('car-air-conditioning-repair', 'car air conditioning repair', 'Car Air Conditioning Repair', 'car-ac-repair'),
    ('ac-recharge', 'AC recharge', 'AC Recharge', 'car-ac-repair'),
    ('muffler-repair', 'muffler repair', 'Muffler Repair', 'exhaust-repair'),
    ('muffler-shop', 'muffler shop', 'Muffler Shop', 'exhaust-repair'),
    ('shocks-and-struts', 'shocks and struts', 'Shocks and Struts', 'suspension-repair'),
    ('steering-repair', 'steering repair', 'Steering Repair', 'suspension-repair')
  ) x(slug, phrase, title, target)
  join place_terms t on t.slug = x.target and t.canonical_slug is null and t.lead_kind = 'auto_service'
on conflict do nothing;

-- ================================================================ B4. the vehicle page trees: our own work only
-- 0097's list, without the mechanical work we arrange (a page per make, model and year would say more than we do)
create or replace function app.vpage_terms() returns table (slug text, name text, kind text, sort integer, lead text, phrase text)
language plpgsql stable security definer set search_path = public, app as $$
begin
  if app.vpage_has('place_terms') then
    return query execute $q$
      select t.slug, app.vpage_term_name(t.phrase, t.title), t.vertical, t.sort_order, t.lead_kind, btrim(t.phrase)
        from place_terms t where t.is_active and t.canonical_slug is null and t.slug <> 'car-rental' and t.lead_kind is distinct from 'auto_service'
       order by t.vertical, t.sort_order, t.slug $q$;
  else
    return query select x.slug, x.name, x.kind, x.sort, x.lead, lower(left(x.name, 1)) || substr(x.name, 2) from (values
      ('car-hire', 'Car hire', 'rental', 20, null::text), ('cars-for-hire', 'Cars for hire', 'rental', 30, null), ('vehicle-rental', 'Vehicle rental', 'rental', 40, null),
      ('insurance-replacement', 'Insurance replacement rental', 'rental', 50, null),
      ('used', 'Used', 'sale', 110, 'buyer'), ('financing', 'Financing', 'sale', 120, 'finance'), ('leasing', 'Leasing', 'sale', 130, 'finance'), ('lease-takeover', 'Lease takeover', 'sale', 140, 'finance'),
      ('car-detailing', 'Car detailing', 'detailing', 210, 'detailing'), ('interior-detailing', 'Interior detailing', 'detailing', 220, 'detailing'),
      ('exterior-detailing', 'Exterior detailing', 'detailing', 230, 'detailing'), ('mobile-detailing', 'Mobile detailing', 'detailing', 240, 'detailing'),
      ('paint-correction', 'Paint correction', 'detailing', 250, 'detailing'), ('ceramic-coating', 'Ceramic coating', 'detailing', 260, 'detailing'),
      ('window-tint', 'Window tint', 'detailing', 270, 'detailing'), ('ppf', 'Paint protection film (PPF)', 'detailing', 280, 'detailing'), ('vinyl-wrap', 'Vinyl wrap', 'detailing', 290, 'detailing'),
      ('collision-repair', 'Collision repair', 'bodyshop', 310, 'bodyshop'), ('auto-body', 'Auto body repair', 'bodyshop', 320, 'bodyshop'), ('dent-repair', 'Dent repair', 'bodyshop', 330, 'bodyshop'),
      ('bumper-repair', 'Bumper repair', 'bodyshop', 340, 'bodyshop'), ('car-painting', 'Car painting', 'bodyshop', 350, 'bodyshop'), ('scratch-repair', 'Scratch repair', 'bodyshop', 360, 'bodyshop')
    ) x(slug, name, kind, sort, lead) order by x.kind, x.sort;
  end if;
end $$;

-- ================================================================ B5. the public term list, with the lead kind (the pages list the mechanical work apart)
create or replace function public.place_terms_public() returns jsonb
language sql stable security definer set search_path = public, app as $$
  select coalesce(jsonb_agg(jsonb_build_object('slug', t.slug, 'vertical', t.vertical, 'phrase', t.phrase, 'title', t.title, 'landing_slug', t.landing_slug, 'service_code', t.service_code,
                                               'lead_kind', t.lead_kind)
                            order by t.vertical, t.sort_order), '[]'::jsonb)
    from place_terms t where t.is_active and t.canonical_slug is null
$$;

-- ================================================================ B6. the priority sitemap: the mechanical work is a family of its own
-- 0115's refresh; the first four terms of the mechanical work we arrange join the first terms of each family.
create or replace function app.sitemap_priority_refresh() returns integer
language plpgsql security definer set search_path = public, app as $$
declare
  s program_settings := app.settings();
  o jsonb := app.place_origin();
  v_vehicles integer;
  v_terms integer;
  v_per integer;
  n integer;
begin
  perform set_config('statement_timeout', '120s', true);
  create temp table if not exists _spc (path text primary key, lastmod timestamptz, sort integer) on commit drop;
  truncate _spc;
  -- the vehicles: every make, then the popular models in their order, model page first, newest years first
  insert into _spc (path, lastmod, sort)
    select c.path, c.lastmod, row_number() over (order by c.path)::integer from app.vehicle_sitemap_paths_cache c where c.base = 'makes'
    on conflict do nothing;
  insert into _spc (path, lastmod, sort)
    select x.path, x.lastmod, 10000 + row_number() over (order by x.psort, x.yr desc nulls first, x.path)::integer
      from (select c.path, c.lastmod, p.sort psort, nullif(split_part(c.path, '/', 5), '')::integer yr
              from vehicle_catalog_popular p
              join app.vehicle_sitemap_paths_cache c on c.base in (p.make_slug || '-models', p.make_slug || '-years', p.make_slug || '-trims')
               and (c.path = app.vpage_path(p.make_slug, p.model_slug) or c.path like app.vpage_path(p.make_slug, p.model_slug) || '/%')) x
     where x.yr is null or x.yr >= s.vpage_popular_from_year
     order by x.psort, x.yr desc nulls first, x.path
     limit 15000
    on conflict do nothing;
  select count(*) into v_vehicles from _spc;
  -- the place pages: the first terms of each family whose pages are in search, for the Ontario places nearest us
  create temp table if not exists _spt on commit drop as select vertical, slug, sort_order, landing_slug from place_terms limit 0;
  truncate _spt;
  insert into _spt
    select t.vertical, t.slug, t.sort_order, t.landing_slug from (
      select t.*, row_number() over (partition by t.vertical, t.lead_kind is not distinct from 'auto_service' order by t.sort_order, t.slug) rn from place_terms t
       where t.is_active and t.canonical_slug is null
         and case t.vertical when 'rental' then s.place_hubs_index when 'sale' then s.sale_hubs_index when 'bodyshop' then s.bodyshop_hubs_index else s.detailing_hubs_index end
         and (not s.place_quality_gate or t.vertical <> 'rental' or t.served = 'request' or app.seo_real_count(t.match) >= 1)) t
     where t.rn <= case t.vertical when 'rental' then 12 when 'sale' then 3 else 4 end;
  select count(*) into v_terms from _spt;
  v_per := case when v_terms > 0 then greatest(0, (49000 - v_vehicles - 500) / v_terms) else 0 end;
  insert into _spc (path, lastmod, sort)
    select app.place_hub_path(t.vertical, t.slug, p.slug), p.updated_on::timestamptz,
           100000 + (row_number() over (order by p.rk, t.vertical <> 'rental', t.sort_order, t.slug))::integer
      from (select p.*, row_number() over (order by (p.lat - (o ->> 'lat')::real) ^ 2 + ((p.lng - (o ->> 'lng')::real) * cos(radians((o ->> 'lat')::numeric)::real)) ^ 2, p.id) rk
              from places p join place_regions r on r.id = p.region_id and r.is_enabled and r.code = 'CA-ON'
             where p.is_active and p.kind in (4, 5, 6) and p.lat is not null
               and (not s.place_quality_gate or app.distance_km((o ->> 'lat')::numeric, (o ->> 'lng')::numeric, p.lat::numeric, p.lng::numeric) <= s.place_delivery_reach_km)) p
      cross join _spt t
     where p.rk <= v_per
       and not (t.vertical = 'rental' and t.slug = 'car-rental' and p.landing_slug is not null)
       and not (t.vertical = 'rental' and p.slug = 'toronto' and t.landing_slug is not null)
    on conflict do nothing;
  delete from app.sitemap_priority_cache c where not exists (select 1 from _spc x where x.path = c.path);
  insert into app.sitemap_priority_cache (path, lastmod, sort) select path, lastmod, sort from _spc
    on conflict (path) do update set lastmod = excluded.lastmod, sort = excluded.sort
    where (app.sitemap_priority_cache.lastmod, app.sitemap_priority_cache.sort) is distinct from (excluded.lastmod, excluded.sort);
  select count(*) into n from app.sitemap_priority_cache;
  return n;
end $$;

select app.sitemap_priority_refresh();

-- ================================================================ C. the guides of this release
-- GUIDES 0121 START (generated by supabase/seed/0121_gen_guides.mjs from docs/guides/content; do not edit by hand)
select app.guide_release_section('admin', 'live-visitors-and-live-chat', 'chapter', 'tolls-and-tickets', 'See who is on the site right now and what they look at, with buying signals, and answer the live chat. The CarmaCars assistant answers the chat first; you take over whenever you want, and it hands over by itself for complaints, damage, payments and anything it should not answer.

## Live visitors

Visitors who accepted analytics (or got the notice in Canada outside Quebec and the US), known customers on their own booking pages and anyone in a chat.

1. Open **Today** > **Live visitors**. "Live now" counts who is on the site now (seen in the last 5 minutes; an open page says it is still there every 45 seconds, so someone reading one page stays on the list). "Visitors today" counts people, with their visits below. The other tiles count hot visitors now, known customers now and chats today. The menu shows how many hot visitors are on the site.
2. Visitors who chose necessary cookies only are never recorded: a line under the tiles says how many chose that today. Closing the tab takes a visitor off the list at once.
3. Each visitor shows a booking likelihood from 0 to 100, with Hot (60 or more), Warm (30 or more) or Cold. The list is sorted by it; choose "Most recent" in Sort, or tick "Hot and warm only".
4. "Why" gives the three strongest reasons, for example "Pickup tomorrow · Reached step 3 of the request form · Tapped to call". The badges are all the signals of the visit; the dots say how strong each is.
5. Each visitor also shows their name when known (signed in, or arrived from one of our emails), otherwise "Visitor from Toronto, phone"; the page and car they are on, and how many others look at that car now; the device, city, the site or campaign that sent them and "from an ad".
6. Suggested: the best next step and the message to send. Press **Invite to chat with this message** to send it at once, **Edit the message** to change it first, **Offer a 10% discount code**, **Assign to Sales** or, when their dates are taken, **Suggest a similar free car**.
7. Press **Pages** for every page and event of the visit with each signal''s points, or **Start a chat** to write your own message. They see it in a bubble and reply from it.
8. Below: hot visitors today (and whether someone acted), the signals of the last 24 hours, and the most viewed cars of the week with prices shown and the car most compared with each. The page refreshes by itself every 15 seconds.

## The signals

Each signal adds points to the booking likelihood. They come from what the visitor does on the site, never from what they type.

- Intent: dates searched again and again, saw the full price, reached the booking form (and which step), came back for the same car on another day, comparing two or three cars, read the cancellation policy, read about the deposit, insurance or requirements, tapped to call, text or WhatsApp us or copied our number, checked delivery, looked through many photos or stayed long on one car.
- Urgency: pickup within 72 hours, weekend or holiday dates, on a phone late at night, came from a city or model page or a "near me" search.
- Value: a weekly or monthly rental, a premium car, SUV or van, adding a driver, asked about young drivers, a business email.
- Hesitation: watching the price (sorted by lowest price, lowered the price limit), left after seeing the price, unsure about the deposit, trouble with a form, the car not free for their dates.
- Context: came from an ad, a past renter, an offer or payment waiting, a game code not used yet, a popular car. The signals of known customers (offer opened, pay page left, change proposal, request stopped, returning visitor, viewing spree) count too.

## Hot visitors and the actions

- When a visitor turns hot, everyone with Live visitors open sees an alert at the top of the page. Turn on desktop alerts in Live chat to get one on your computer too; none come in the quiet hours (11 pm to 7 am). No email is sent.
- A discount code is single use, 10% off the rental charge (at most $75), valid 3 days, one per visitor a week and 10 a day per person. Admins and Sales send them; the code goes in the chat with the message.
- Assign to Sales gives the visitor to the Sales person on shift (or to you if you work Sales) and raises a task with the reasons and the contact when we know who they are.
- Each action shows on the visitor ("Invited by Lena, 2 min ago") so two people do not write to the same visitor.

## Signal settings

1. Open **Today** > **Live visitors** and press **Signal settings**.
2. Score and actions: from how many points a visitor is hot or warm, when a signal is strong or medium, the hot alert, and the discount code (percent, most off a booking, days valid, codes a day per person, whether customer service may send codes, and the message).
3. Each signal: on or off, its points, its thresholds (for example 72 hours for "Pickup soon", 3 searches for "Searching dates again and again"), the suggested action and the message. {car}, {days}, {pickup} and the other words in braces are filled in from the visit.
4. Press **Save the signals**. The next look at each visit uses them.

## Follow-up tasks

Signals of known visitors become tasks with a suggested action, for example "Call or message Maya Chen: opened offer CC-1042 twice, no answer for 6 hours".

- An offer opened and not answered: after 6 hours, to Sales when the booking is credited to someone in Sales, otherwise customer service.
- The pay page left without paying: after 30 minutes, customer service. The change proposal opened twice: customer service.
- A booking request started and stopped, or a viewing spree, by a known visitor: Sales.
- A task closes by itself when the renter answers the offer, pays or answers the proposal. Each signal raises one task only.
- The thresholds are in **Settings** > **Program**, group "Live visitors and live chat", with how long "on the site now" lasts (5 minutes) and how often an open page says it is still there (45 seconds). Follow-ups done count in My sales.

## Recovery emails

Known renters who stop before finishing get one polite reminder, and at most one more a day later.

- An offer opened and not answered: after 4 hours. The pay page left without paying: after an hour. A change proposal opened and not answered: after 4 hours.
- A booking request started and not sent: after 2 hours, and only to renters who agreed to hear from us (marketing consent).
- Sent only between 9:00 and 21:00 Toronto time, never to someone who unsubscribed, and never while a staff member is handling the renter (a task they took, a chat with a person, a message from staff).
- They stop as soon as the renter answers, pays or sends the request; a reminder still waiting is not sent. The delays and hours are in Program settings, "Booking recovery emails".

## Interest in a car

**Cars** > **Vehicles**, a car, Overview: "Interest on the site" shows who is looking now, views today and in 7 days, the people who saw the price for their dates, conversion over 30 days (requests from the people who viewed it), the cars most often compared with it, and the last 14 days. The Vehicles list has "Most viewed cars this week".

## A renter''s visits

On a renter''s page (People > Renters, the name) and on a booking''s History tab, "On the site" lists when they viewed the offer, opened the change proposal, viewed or left the pay page, which cars they looked at, and their chats.

## Live chat

1. A visitor who asks for a person is a line on To do, marked Now: press **Open the chat**. Or open **Bookings** > **Live chat**. The menu counts chats waiting for a person. Open chats come first, those waiting for a person on top, with their minutes against the first reply target (5 minutes).
2. Choose a conversation. Beside it you see the visitor''s page, pages, signals, and the renter with their bookings when known.
3. Press **Take over**: the assistant stops and the visitor reads that you joined. Writing a reply also takes over. Press **Send** (or Enter).
4. **Hand back to the assistant** lets it answer again. **Close** ends the chat; if the visitor gave an email they get a copy. **Email the transcript** sends it any time.
5. Notify me: "Email me when a chat waits (while I am on shift)" and desktop alerts in this browser. You are on shift while Live chat or Live visitors is open.

> Tip: The assistant only repeats prices from our pricing (a quote or the car''s rates), never offers discounts or promises a car, never talks about insurance and never names a provider. Each reply it was not allowed to send says so in the conversation. When nobody is on shift, the chat asks for the visitor''s name, email or phone and raises a task. A booking from a chat you handled is credited only when you choose "I sourced this client" on the quote or offer.

## The assistant''s settings

In Program settings, "Live visitors and live chat": the chat on or off, the AI first or not, its model, the neurons it may use a day (6,000, about 10 chats; then chats wait for a person), the greeting on car pages after some seconds (off by default), how long chats and visits are kept (12 months and 90 days, as the privacy policy says).

## What a visitor typed

A visitor who typed contact details into a form shows them on their line: "Typed into the booking request, not sent: Maya Chen, maya@example.com", with **Email not confirmed** until they open the link we emailed, and **Renter page**.
', 'Live visitors and live chat', 'Who is on the site now, how likely each visitor is to book and why, one-click actions, follow-ups, interest per car, the chat inbox.',
  'See who is on the site right now and what they look at, with buying signals, and answer the live chat. The CarmaCars assistant answers the chat first; you take over whenever you want, and it hands over by itself for complaints, damage, payments and anything it should not answer.

## Live visitors

Visitors who accepted analytics (or got the notice in Canada outside Quebec and the US), known customers on their own booking pages and anyone in a chat.

1. Open **Today** > **Live visitors**. "Live now" counts who is on the site now (seen in the last 5 minutes; an open page says it is still there every 45 seconds, so someone reading one page stays on the list). "Visitors today" counts people, with their visits below. The other tiles count hot visitors now, known customers now and chats today. The menu shows how many hot visitors are on the site.
2. Visitors who chose necessary cookies only are never recorded: a line under the tiles says how many chose that today. Closing the tab takes a visitor off the list at once.
3. Each visitor shows a booking likelihood from 0 to 100, with Hot (60 or more), Warm (30 or more) or Cold. The list is sorted by it; choose "Most recent" in Sort, or tick "Hot and warm only".
4. "Why" gives the three strongest reasons, for example "Pickup tomorrow · Reached step 3 of the request form · Tapped to call". The badges are all the signals of the visit; the dots say how strong each is.
5. Each visitor also shows their name when known (signed in, or arrived from one of our emails), otherwise "Visitor from Toronto, phone"; the page and car they are on, and how many others look at that car now; the device, city, the site or campaign that sent them and "from an ad".
6. Suggested: the best next step and the message to send. Press **Invite to chat with this message** to send it at once, **Edit the message** to change it first, **Offer a 10% discount code**, **Assign to Sales** or, when their dates are taken, **Suggest a similar free car**.
7. Press **Pages** for every page and event of the visit with each signal''s points, or **Start a chat** to write your own message. They see it in a bubble and reply from it.
8. Below: hot visitors today (and whether someone acted), the signals of the last 24 hours, and the most viewed cars of the week with prices shown and the car most compared with each. The page refreshes by itself every 15 seconds.

## The signals

Each signal adds points to the booking likelihood. They come from what the visitor does on the site, never from what they type.

- Intent: dates searched again and again, saw the full price, reached the booking form (and which step), came back for the same car on another day, comparing two or three cars, read the cancellation policy, read about the deposit, insurance or requirements, tapped to call, text or WhatsApp us or copied our number, checked delivery, looked through many photos or stayed long on one car.
- Urgency: pickup within 72 hours, weekend or holiday dates, on a phone late at night, came from a city or model page or a "near me" search.
- Value: a weekly or monthly rental, a premium car, SUV or van, adding a driver, asked about young drivers, a business email.
- Hesitation: watching the price (sorted by lowest price, lowered the price limit), left after seeing the price, unsure about the deposit, trouble with a form, the car not free for their dates.
- Context: came from an ad, a past renter, an offer or payment waiting, a game code not used yet, a popular car. The signals of known customers (offer opened, pay page left, change proposal, request stopped, returning visitor, viewing spree) count too.

## Hot visitors and the actions

- When a visitor turns hot, everyone with Live visitors open sees an alert at the top of the page. Turn on desktop alerts in Live chat to get one on your computer too; none come in the quiet hours (11 pm to 7 am). No email is sent.
- A discount code is single use, 10% off the rental charge (at most $75), valid 3 days, one per visitor a week and 10 a day per person. Admins and Sales send them; the code goes in the chat with the message.
- Assign to Sales gives the visitor to the Sales person on shift (or to you if you work Sales) and raises a task with the reasons and the contact when we know who they are.
- Each action shows on the visitor ("Invited by Lena, 2 min ago") so two people do not write to the same visitor.

## Signal settings

1. Open **Today** > **Live visitors** and press **Signal settings**.
2. Score and actions: from how many points a visitor is hot or warm, when a signal is strong or medium, the hot alert, and the discount code (percent, most off a booking, days valid, codes a day per person, whether customer service may send codes, and the message).
3. Each signal: on or off, its points, its thresholds (for example 72 hours for "Pickup soon", 3 searches for "Searching dates again and again"), the suggested action and the message. {car}, {days}, {pickup} and the other words in braces are filled in from the visit.
4. Press **Save the signals**. The next look at each visit uses them.

## Follow-up tasks

Signals of known visitors become tasks with a suggested action, for example "Call or message Maya Chen: opened offer CC-1042 twice, no answer for 6 hours".

- An offer opened and not answered: after 6 hours, to Sales when the booking is credited to someone in Sales, otherwise customer service.
- The pay page left without paying: after 30 minutes, customer service. The change proposal opened twice: customer service.
- A booking request started and stopped, or a viewing spree, by a known visitor: Sales.
- A task closes by itself when the renter answers the offer, pays or answers the proposal. Each signal raises one task only.
- The thresholds are in **Settings** > **Program**, group "Live visitors and live chat", with how long "on the site now" lasts (5 minutes) and how often an open page says it is still there (45 seconds). Follow-ups done count in My sales.

## Recovery emails

Known renters who stop before finishing get one polite reminder, and at most one more a day later.

- An offer opened and not answered: after 4 hours. The pay page left without paying: after an hour. A change proposal opened and not answered: after 4 hours.
- A booking request started and not sent: after 2 hours, and only to renters who agreed to hear from us (marketing consent).
- Sent only between 9:00 and 21:00 Toronto time, never to someone who unsubscribed, and never while a staff member is handling the renter (a task they took, a chat with a person, a message from staff).
- They stop as soon as the renter answers, pays or sends the request; a reminder still waiting is not sent. The delays and hours are in Program settings, "Booking recovery emails".

## Interest in a car

**Cars** > **Vehicles**, a car, Overview: "Interest on the site" shows who is looking now, views today and in 7 days, the people who saw the price for their dates, conversion over 30 days (requests from the people who viewed it), the cars most often compared with it, and the last 14 days. The Vehicles list has "Most viewed cars this week".

## A renter''s visits

On a renter''s page (People > Renters, the name) and on a booking''s History tab, "On the site" lists when they viewed the offer, opened the change proposal, viewed or left the pay page, which cars they looked at, and their chats.

## Live chat

1. A visitor who asks for a person is a line on To do, marked Now: press **Open the chat**. Or open **Bookings** > **Live chat**. The menu counts chats waiting for a person. Open chats come first, those waiting for a person on top, with their minutes against the first reply target (5 minutes).
2. Choose a conversation. Beside it you see the visitor''s page, pages, signals, and the renter with their bookings when known.
3. Press **Take over**: the assistant stops and the visitor reads that you joined. Writing a reply also takes over. Press **Send** (or Enter).
4. **Hand back to the assistant** lets it answer again. **Close** ends the chat; if the visitor gave an email they get a copy. **Email the transcript** sends it any time.
5. Notify me: "Email me when a chat waits (while I am on shift)" and desktop alerts in this browser. You are on shift while Live chat or Live visitors is open.

> Tip: The assistant only repeats prices from our pricing (a quote or the car''s rates), never offers discounts or promises a car, never talks about insurance and never names a provider. Each reply it was not allowed to send says so in the conversation. When nobody is on shift, the chat asks for the visitor''s name, email or phone and raises a task. A booking from a chat you handled is credited only when you choose "I sourced this client" on the quote or offer.

## The assistant''s settings

In Program settings, "Live visitors and live chat": the chat on or off, the AI first or not, its model, the neurons it may use a day (6,000, about 10 chats; then chats wait for a person), the greeting on car pages after some seconds (off by default), how long chats and visits are kept, as the privacy policy says: chats 12 months, the pages of a visit 90 days, the visit''s summary in Visitor history 13 months, and the daily totals, which name no one, 3 years.

## What a visitor typed

A visitor who typed contact details into a form shows them on their line: "Typed into the booking request, not sent: Maya Chen, maya@example.com", with **Email not confirmed** until they open the link we emailed, and **Renter page**.
',
  '<p class="gd-p">See who is on the site right now and what they look at, with buying signals, and answer the live chat. The CarmaCars assistant answers the chat first; you take over whenever you want, and it hands over by itself for complaints, damage, payments and anything it should not answer.</p><section class="gd-task" id="live-visitors-and-live-chat-live-visitors" data-gd-task><h2 class="gd-h2">Live visitors</h2><p class="gd-p">Visitors who accepted analytics (or got the notice in Canada outside Quebec and the US), known customers on their own booking pages and anyone in a chat.</p><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">Open <b class="gd-ui">Today</b> &gt; <b class="gd-ui">Live visitors</b>. &quot;Live now&quot; counts who is on the site now (seen in the last 5 minutes; an open page says it is still there every 45 seconds, so someone reading one page stays on the list). &quot;Visitors today&quot; counts people, with their visits below. The other tiles count hot visitors now, known customers now and chats today. The menu shows how many hot visitors are on the site.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Visitors who chose necessary cookies only are never recorded: a line under the tiles says how many chose that today. Closing the tab takes a visitor off the list at once.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Each visitor shows a booking likelihood from 0 to 100, with Hot (60 or more), Warm (30 or more) or Cold. The list is sorted by it; choose &quot;Most recent&quot; in Sort, or tick &quot;Hot and warm only&quot;.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t">&quot;Why&quot; gives the three strongest reasons, for example &quot;Pickup tomorrow · Reached step 3 of the request form · Tapped to call&quot;. The badges are all the signals of the visit; the dots say how strong each is.</div></li><li><span class="gd-n" aria-hidden="true">5</span><div class="gd-t">Each visitor also shows their name when known (signed in, or arrived from one of our emails), otherwise &quot;Visitor from Toronto, phone&quot;; the page and car they are on, and how many others look at that car now; the device, city, the site or campaign that sent them and &quot;from an ad&quot;.</div></li><li><span class="gd-n" aria-hidden="true">6</span><div class="gd-t">Suggested: the best next step and the message to send. Press <b class="gd-ui">Invite to chat with this message</b> to send it at once, <b class="gd-ui">Edit the message</b> to change it first, <b class="gd-ui">Offer a 10% discount code</b>, <b class="gd-ui">Assign to Sales</b> or, when their dates are taken, <b class="gd-ui">Suggest a similar free car</b>.</div></li><li><span class="gd-n" aria-hidden="true">7</span><div class="gd-t">Press <b class="gd-ui">Pages</b> for every page and event of the visit with each signal&#39;s points, or <b class="gd-ui">Start a chat</b> to write your own message. They see it in a bubble and reply from it.</div></li><li><span class="gd-n" aria-hidden="true">8</span><div class="gd-t">Below: hot visitors today (and whether someone acted), the signals of the last 24 hours, and the most viewed cars of the week with prices shown and the car most compared with each. The page refreshes by itself every 15 seconds.</div></li></ol></div></section><section class="gd-task" id="live-visitors-and-live-chat-the-signals" data-gd-task><h2 class="gd-h2">The signals</h2><p class="gd-p">Each signal adds points to the booking likelihood. They come from what the visitor does on the site, never from what they type.</p><ul class="gd-ul"><li>Intent: dates searched again and again, saw the full price, reached the booking form (and which step), came back for the same car on another day, comparing two or three cars, read the cancellation policy, read about the deposit, insurance or requirements, tapped to call, text or WhatsApp us or copied our number, checked delivery, looked through many photos or stayed long on one car.</li><li>Urgency: pickup within 72 hours, weekend or holiday dates, on a phone late at night, came from a city or model page or a &quot;near me&quot; search.</li><li>Value: a weekly or monthly rental, a premium car, SUV or van, adding a driver, asked about young drivers, a business email.</li><li>Hesitation: watching the price (sorted by lowest price, lowered the price limit), left after seeing the price, unsure about the deposit, trouble with a form, the car not free for their dates.</li><li>Context: came from an ad, a past renter, an offer or payment waiting, a game code not used yet, a popular car. The signals of known customers (offer opened, pay page left, change proposal, request stopped, returning visitor, viewing spree) count too.</li></ul></section><section class="gd-task" id="live-visitors-and-live-chat-hot-visitors-and-the-actions" data-gd-task><h2 class="gd-h2">Hot visitors and the actions</h2><ul class="gd-ul"><li>When a visitor turns hot, everyone with Live visitors open sees an alert at the top of the page. Turn on desktop alerts in Live chat to get one on your computer too; none come in the quiet hours (11 pm to 7 am). No email is sent.</li><li>A discount code is single use, 10% off the rental charge (at most $75), valid 3 days, one per visitor a week and 10 a day per person. Admins and Sales send them; the code goes in the chat with the message.</li><li>Assign to Sales gives the visitor to the Sales person on shift (or to you if you work Sales) and raises a task with the reasons and the contact when we know who they are.</li><li>Each action shows on the visitor (&quot;Invited by Lena, 2 min ago&quot;) so two people do not write to the same visitor.</li></ul></section><section class="gd-task" id="live-visitors-and-live-chat-signal-settings" data-gd-task><h2 class="gd-h2">Signal settings</h2><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">Open <b class="gd-ui">Today</b> &gt; <b class="gd-ui">Live visitors</b> and press <b class="gd-ui">Signal settings</b>.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Score and actions: from how many points a visitor is hot or warm, when a signal is strong or medium, the hot alert, and the discount code (percent, most off a booking, days valid, codes a day per person, whether customer service may send codes, and the message).</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Each signal: on or off, its points, its thresholds (for example 72 hours for &quot;Pickup soon&quot;, 3 searches for &quot;Searching dates again and again&quot;), the suggested action and the message. {car}, {days}, {pickup} and the other words in braces are filled in from the visit.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t">Press <b class="gd-ui">Save the signals</b>. The next look at each visit uses them.</div></li></ol></div></section><section class="gd-task" id="live-visitors-and-live-chat-follow-up-tasks" data-gd-task><h2 class="gd-h2">Follow-up tasks</h2><p class="gd-p">Signals of known visitors become tasks with a suggested action, for example &quot;Call or message Maya Chen: opened offer CC-1042 twice, no answer for 6 hours&quot;.</p><ul class="gd-ul"><li>An offer opened and not answered: after 6 hours, to Sales when the booking is credited to someone in Sales, otherwise customer service.</li><li>The pay page left without paying: after 30 minutes, customer service. The change proposal opened twice: customer service.</li><li>A booking request started and stopped, or a viewing spree, by a known visitor: Sales.</li><li>A task closes by itself when the renter answers the offer, pays or answers the proposal. Each signal raises one task only.</li><li>The thresholds are in <b class="gd-ui">Settings</b> &gt; <b class="gd-ui">Program</b>, group &quot;Live visitors and live chat&quot;, with how long &quot;on the site now&quot; lasts (5 minutes) and how often an open page says it is still there (45 seconds). Follow-ups done count in My sales.</li></ul></section><section class="gd-task" id="live-visitors-and-live-chat-recovery-emails" data-gd-task><h2 class="gd-h2">Recovery emails</h2><p class="gd-p">Known renters who stop before finishing get one polite reminder, and at most one more a day later.</p><ul class="gd-ul"><li>An offer opened and not answered: after 4 hours. The pay page left without paying: after an hour. A change proposal opened and not answered: after 4 hours.</li><li>A booking request started and not sent: after 2 hours, and only to renters who agreed to hear from us (marketing consent).</li><li>Sent only between 9:00 and 21:00 Toronto time, never to someone who unsubscribed, and never while a staff member is handling the renter (a task they took, a chat with a person, a message from staff).</li><li>They stop as soon as the renter answers, pays or sends the request; a reminder still waiting is not sent. The delays and hours are in Program settings, &quot;Booking recovery emails&quot;.</li></ul></section><section class="gd-task" id="live-visitors-and-live-chat-interest-in-a-car" data-gd-task><h2 class="gd-h2">Interest in a car</h2><p class="gd-p"><b class="gd-ui">Cars</b> &gt; <b class="gd-ui">Vehicles</b>, a car, Overview: &quot;Interest on the site&quot; shows who is looking now, views today and in 7 days, the people who saw the price for their dates, conversion over 30 days (requests from the people who viewed it), the cars most often compared with it, and the last 14 days. The Vehicles list has &quot;Most viewed cars this week&quot;.</p></section><section class="gd-task" id="live-visitors-and-live-chat-a-renter-s-visits" data-gd-task><h2 class="gd-h2">A renter&#39;s visits</h2><p class="gd-p">On a renter&#39;s page (People &gt; Renters, the name) and on a booking&#39;s History tab, &quot;On the site&quot; lists when they viewed the offer, opened the change proposal, viewed or left the pay page, which cars they looked at, and their chats.</p></section><section class="gd-task" id="live-visitors-and-live-chat-live-chat" data-gd-task><h2 class="gd-h2">Live chat</h2><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">A visitor who asks for a person is a line on To do, marked Now: press <b class="gd-ui">Open the chat</b>. Or open <b class="gd-ui">Bookings</b> &gt; <b class="gd-ui">Live chat</b>. The menu counts chats waiting for a person. Open chats come first, those waiting for a person on top, with their minutes against the first reply target (5 minutes).</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Choose a conversation. Beside it you see the visitor&#39;s page, pages, signals, and the renter with their bookings when known.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Press <b class="gd-ui">Take over</b>: the assistant stops and the visitor reads that you joined. Writing a reply also takes over. Press <b class="gd-ui">Send</b> (or Enter).</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t"><b class="gd-ui">Hand back to the assistant</b> lets it answer again. <b class="gd-ui">Close</b> ends the chat; if the visitor gave an email they get a copy. <b class="gd-ui">Email the transcript</b> sends it any time.</div></li><li><span class="gd-n" aria-hidden="true">5</span><div class="gd-t">Notify me: &quot;Email me when a chat waits (while I am on shift)&quot; and desktop alerts in this browser. You are on shift while Live chat or Live visitors is open.</div></li></ol></div><aside class="gd-box"><span class="gd-lbl">Tip</span><div>The assistant only repeats prices from our pricing (a quote or the car&#39;s rates), never offers discounts or promises a car, never talks about insurance and never names a provider. Each reply it was not allowed to send says so in the conversation. When nobody is on shift, the chat asks for the visitor&#39;s name, email or phone and raises a task. A booking from a chat you handled is credited only when you choose &quot;I sourced this client&quot; on the quote or offer.</div></aside></section><section class="gd-task" id="live-visitors-and-live-chat-the-assistant-s-settings" data-gd-task><h2 class="gd-h2">The assistant&#39;s settings</h2><p class="gd-p">In Program settings, &quot;Live visitors and live chat&quot;: the chat on or off, the AI first or not, its model, the neurons it may use a day (6,000, about 10 chats; then chats wait for a person), the greeting on car pages after some seconds (off by default), how long chats and visits are kept, as the privacy policy says: chats 12 months, the pages of a visit 90 days, the visit&#39;s summary in Visitor history 13 months, and the daily totals, which name no one, 3 years.</p></section><section class="gd-task" id="live-visitors-and-live-chat-what-a-visitor-typed" data-gd-task><h2 class="gd-h2">What a visitor typed</h2><p class="gd-p">A visitor who typed contact details into a form shows them on their line: &quot;Typed into the booking request, not sent: Maya Chen, maya@example.com&quot;, with <b class="gd-ui">Email not confirmed</b> until they open the link we emailed, and <b class="gd-ui">Renter page</b>.</p></section>');
select app.guide_release_section('admin', 'search-car-pages-landing-pages-and-guides', 'chapter', 'discount-games-and-leads', 'The text of every car page, the landing pages for each area and way of renting, and the guides are written by Workers AI from the facts in the database, checked and published by themselves. Nobody has to type or review anything. You can still change any line; what you change is kept.

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

## Vehicle pages

**Settings** > **Vehicle pages**. A page for every make, model, model year and Canadian trim of every year, at carmacars.ca/cars/make/model/year/trim, with our cars below it; each trim also in every place and in 12 colours (a black 2020 Volkswagen Jetta Sportline in Mississauga, for example); every page again for sale (carmacars.ca/buy/...) and for each search term: renting (car hire), sale (financing), detailing (ceramic coating) and body shop (bumper repair), at carmacars.ca/t/term/...

1. Pages: how many pages each level and each tier has, the total, and how many are in search. Every page is in search by default; nothing needs setting up.
2. One switch per tier takes it out of search at once: **Index the place pages**, **Index the colour pages**, **Index the search term pages**, **Index the /buy pages**, **Index the detailing pages**, **Index the body shop pages**. Off, those pages stay visible but leave the sitemaps and search.
3. The places are the place list of the local search release (every city, town and neighbourhood, with GTA and country levels); until it is filled, the area landing pages. The search terms are edited with them.
4. **Financing disclaimer**: the text on financing and leasing pages. CarmaCars never says it lends or leases.
5. Database: its size against the cap the catalog and places imports keep under: the cap of the Database plan (Pro, 6,144 MB, by default; Free, 450 MB). IndexNow: the addresses sent today, where the sweep is, and any back-off; nothing to do.
6. Each page is built from data: the EPA fuel-use ratings in litres per 100 km, the cost to drive 100 km at the gas or electricity price set here, what changed from the year before, how a trim differs from the others, similar models, and the rental questions from the program settings.
7. Below the facts: our cars of that exact year, model and trim, then the same model in other years, then similar cars free now, and Request it, which sends an enquiry to Bookings > Leads.
8. Settings: **Index every page** (the default) or **Only pages that pass the rules**: makes, models with 2 or more years of data, years with one of our cars or of a popular model from 2015, trims with one of our cars. The others stay visible but out of search. Also the gas, premium and electricity prices, and how often the catalog is imported (every 30 days).
9. Canadian trims: open a model and type one line per run of years, entry trim first: 2020-2021: Comfortline, Highline, Sportline, Execline. Your lines are kept by every import; empty them to go back to the CarmaCars list. **Add trims for another model** adds a model that has none.
10. Catalog import: the last import and its counts. **Import now** asks for a new one; it runs at the next daily check, at 07:17 UTC.

> Good to know: A car joins its pages by itself once it is on the site: its make, model, year and trim are read from the car. A trim that names several (S / SE / R-Line) leaves the car on the year page only; set the car''s trim to one Canadian name to put it on the trim page.

## A car for sale

**Cars** > **Vehicles**, then the car. On the For sale card, tick **For sale**, enter the Asking price and press **Save**.

1. The car then shows at the top of its /buy pages (its make, model, year and trim) with the asking price, the only time a page says a car is for sale.
2. Untick it when the car is sold or no longer for sale: the pages say so at once.
3. "Find me this car" on the /buy pages sends a buyer lead to Sales (staff portal: **Owner leads**, Buyer leads), with a To do line.

## Search engines and business listings

**Settings** > **All settings**, then Site settings.

1. Search engines: paste the Google Search Console value (HTML tag) or the file name (HTML file), and the Bing value. The steps are on the card.
2. Business name, address and phone: the exact text for every listing, and the description and categories.
3. Business listings: press **Copy** beside each line and paste it into Google Business Profile, Bing Places, Apple Business Connect, Yelp, Yellow Pages and Facebook. Tick each one when it is done.

> Good to know: Changed pages are sent to IndexNow (Bing and the other engines that use it) by themselves. Google reads the sitemap: submit carmacars.ca/sitemap.xml once in Search Console.

## Place pages

Every place we have, from a country down to a neighbourhood, gets a page for every term people search with: renting (car hire, SUV rental, monthly car rental ...), buying help (used cars, car financing ...), detailing (ceramic coating, window tint ...) and body work (collision repair, dent repair ...). Each page is written from real data only: the distance from us, the delivery price within our reach, the nearest airport, the landmarks near it, our live cars and the places around it. A place far from Toronto says we serve the Toronto area and takes a request instead. **Settings** > **All settings**, then Search.

1. Place pages: four switches, one for each family, put the pages in search and in the sitemaps. All four are on.
2. Quality gate: off. On, only places within the delivery reach are in search, and rental pages only with a real matching car. Search engines can treat many similar pages as low value; the gate lowers that risk.
3. Delivery reach: places within this distance of our location are offered delivery. Database size cap: the places import stops before the database passes it.
4. Regions and places: every province, state and territory is on. Untick a region to take its pages and sitemaps off the site.
5. Terms and services: change a term''s title or what is true about it, point a synonym to another term (its pages then leave search), switch a term off, or add one. Give a service a starting price, or leave it empty for "price on request".

> Good to know: A region has pages once the places workflow has loaded it: GitHub, Actions, places, Run workflow, with the regions or all. The run loads Ontario first and names any region it skipped because of the size cap.

## Requests from the place pages

The buying help, detailing and body shop pages, and the pages of places beyond our reach, have a request form. Each request is a lead with a task in **To do**: detailing and body shop requests are due within an hour of opening and show in Today. Buying help pages say plainly that CarmaCars does not sell, finance or lease cars; the notice at the top is set under Place pages.

## One name, address and phone

The footer, the contact page, the structured data and every business listing show the business address of Site settings. Keep it the address renters come to, and change it there only.
', 'Search: car pages, landing pages and guides', 'Car copy written by itself, landing pages, place pages for every place and term, detailing and body shop, guides, business listings and IndexNow.',
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

## Vehicle pages

**Settings** > **Vehicle pages**. A page for every make, model, model year and Canadian trim of every year, at carmacars.ca/cars/make/model/year/trim, with our cars below it; each trim also in every place and in 12 colours (a black 2020 Volkswagen Jetta Sportline in Mississauga, for example); every page again for sale (carmacars.ca/buy/...) and for each search term: renting (car hire), sale (financing), detailing (ceramic coating) and body shop (bumper repair), at carmacars.ca/t/term/...

1. Pages: how many pages each level and each tier has, the total, and how many are in search. Every page is in search by default; nothing needs setting up.
2. One switch per tier takes it out of search at once: **Index the place pages**, **Index the colour pages**, **Index the search term pages**, **Index the /buy pages**, **Index the detailing pages**, **Index the body shop pages**. Off, those pages stay visible but leave the sitemaps and search.
3. The places are the place list of the local search release (every city, town and neighbourhood, with GTA and country levels); until it is filled, the area landing pages. The search terms are edited with them.
4. **Financing disclaimer**: the text on financing and leasing pages. CarmaCars never says it lends or leases.
5. Database: its size against the cap the catalog and places imports keep under: the cap of the Database plan (Pro, 6,144 MB, by default; Free, 450 MB). IndexNow: the addresses sent today, where the sweep is, and any back-off; nothing to do.
6. Each page is built from data: the EPA fuel-use ratings in litres per 100 km, the cost to drive 100 km at the gas or electricity price set here, what changed from the year before, how a trim differs from the others, similar models, and the rental questions from the program settings.
7. Below the facts: our cars of that exact year, model and trim, then the same model in other years, then similar cars free now, and Request it, which sends an enquiry to Bookings > Leads.
8. Settings: **Index every page** (the default) or **Only pages that pass the rules**: makes, models with 2 or more years of data, years with one of our cars or of a popular model from 2015, trims with one of our cars. The others stay visible but out of search. Also the gas, premium and electricity prices, and how often the catalog is imported (every 30 days).
9. Canadian trims: open a model and type one line per run of years, entry trim first: 2020-2021: Comfortline, Highline, Sportline, Execline. Your lines are kept by every import; empty them to go back to the CarmaCars list. **Add trims for another model** adds a model that has none.
10. Catalog import: the last import and its counts. **Import now** asks for a new one; it runs at the next daily check, at 07:17 UTC.

> Good to know: A car joins its pages by itself once it is on the site: its make, model, year and trim are read from the car. A trim that names several (S / SE / R-Line) leaves the car on the year page only; set the car''s trim to one Canadian name to put it on the trim page.

## A car for sale

**Cars** > **Vehicles**, then the car. On the For sale card, tick **For sale**, enter the Asking price and press **Save**.

1. The car then shows at the top of its /buy pages (its make, model, year and trim) with the asking price, the only time a page says a car is for sale.
2. Untick it when the car is sold or no longer for sale: the pages say so at once.
3. "Find me this car" on the /buy pages sends a buyer lead to Sales (staff portal: **Owner leads**, Buyer leads), with a To do line.

## Search engines and business listings

**Settings** > **All settings**, then Site settings.

1. Search engines: paste the Google Search Console value (HTML tag) or the file name (HTML file), and the Bing value. The steps are on the card.
2. Business name, address and phone: the exact text for every listing, and the description and categories.
3. Business listings: press **Copy** beside each line and paste it into Google Business Profile, Bing Places, Apple Business Connect, Yelp, Yellow Pages and Facebook. Tick each one when it is done.

> Good to know: Changed pages are sent to IndexNow (Bing and the other engines that use it) by themselves. Google reads the sitemap: submit carmacars.ca/sitemap.xml once in Search Console.

## Place pages

Every place we have, from a country down to a neighbourhood, gets a page for every term people search with: renting (car hire, SUV rental, monthly car rental ...), buying help (used cars, car financing ...), detailing (ceramic coating, window tint ...) and body work (collision repair, dent repair ...). Each page is written from real data only: the distance from us, the delivery price within our reach, the nearest airport, the landmarks near it, our live cars and the places around it. A place far from Toronto says we serve the Toronto area and takes a request instead. **Settings** > **All settings**, then Search.

1. Place pages: four switches, one for each family, put the pages in search and in the sitemaps. All four are on.
2. Quality gate: off. On, only places within the delivery reach are in search, and rental pages only with a real matching car. Search engines can treat many similar pages as low value; the gate lowers that risk.
3. Delivery reach: places within this distance of our location are offered delivery. Database size cap: the places import stops before the database passes it.
4. Regions and places: every province, state and territory is on. Untick a region to take its pages and sitemaps off the site.
5. Terms and services: change a term''s title or what is true about it, point a synonym to another term (its pages then leave search), switch a term off, or add one. Give a service a starting price, or leave it empty for "price on request".

> Good to know: A region has pages once the places workflow has loaded it: GitHub, Actions, places, Run workflow, with the regions or all. The run loads Ontario first and names any region it skipped because of the size cap.

## Requests from the place pages

The buying help, detailing and body shop pages, and the pages of places beyond our reach, have a request form. Each request is a lead with a task in **To do**: detailing and body shop requests are due within an hour of opening and show in Today. Buying help pages say plainly that CarmaCars does not sell, finance or lease cars; the notice at the top is set under Place pages.

Mechanical work has pages too, under the body shop pages and listed apart as "Auto services we arrange": a mechanic, oil changes, brakes, tires and winter tires, towing, batteries and boosts, alignment, transmission and engine repair, diagnostics, inspections and the Ontario safety certificate, emissions, AC, exhaust and suspension. CarmaCars does not do this work, and the pages say so: each takes a request (a "Mechanical work to arrange" task, due within an hour of opening) and offers a rental while the car is in. They have no questions of their own and no vehicle pages.

## One name, address and phone

The footer, the contact page, the structured data and every business listing show the business address of Site settings. Keep it the address renters come to, and change it there only.
',
  '<p class="gd-p">The text of every car page, the landing pages for each area and way of renting, and the guides are written by Workers AI from the facts in the database, checked and published by themselves. Nobody has to type or review anything. You can still change any line; what you change is kept.</p><section class="gd-task" id="search-car-pages-landing-pages-and-guides-the-copy-of-a-car" data-gd-task><h2 class="gd-h2">The copy of a car</h2><p class="gd-p"><b class="gd-ui">Cars</b> &gt; <b class="gd-ui">Vehicles</b>, then the car, then its Listing tab. The same card is on the listing review.</p><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">The card says who wrote the text: a plain copy from the car&#39;s facts while the written copy is prepared (usually minutes), then Workers AI.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Every field is shown: search title and description, heading, introduction, highlights, good for, what&#39;s included, pickup and delivery, requirements, questions and the photo descriptions.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">To change a field press <b class="gd-ui">Change</b>, then <b class="gd-ui">Save and lock</b>. A locked field is kept by every new version. <b class="gd-ui">Unlock</b> lets it be written again.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t"><b class="gd-ui">Write again</b> asks for a new version now. A new version is also written by itself when the car&#39;s facts change: its rates, specs, area or photos.</div></li></ol></div><aside class="gd-box"><span class="gd-lbl">Good to know</span><div>The checks refuse long dashes, sales words, the numbered company, any number that is not in the car&#39;s facts (a price, a seat count) and equipment the facts do not list. A version that fails is asked again with the problems named; if it still fails, the page keeps its current text and it is tried again later.</div></aside></section><section class="gd-task" id="search-car-pages-landing-pages-and-guides-landing-pages-and-guides" data-gd-task><h2 class="gd-h2">Landing pages and guides</h2><p class="gd-p"><b class="gd-ui">Settings</b> &gt; <b class="gd-ui">All settings</b>, then Search.</p><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">Today: the Workers AI used for search copy and in all, and IndexNow (addresses waiting and sent).</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Car copy: every real car, who wrote its text, and whether its facts changed since.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Landing pages: each place and way of renting, whether it is in search, its cars and who wrote it. A page for a way of renting (monthly, SUV) goes into search once enough real cars match it (Program settings).</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t">Open <b class="gd-ui">Edit</b> on a page or a guide to change its text. Edited fields are locked. <b class="gd-ui">Write again</b> asks for a new version; on a guide, the brief says what it must cover.</div></li></ol></div></section><section class="gd-task" id="search-car-pages-landing-pages-and-guides-vehicle-pages" data-gd-task><h2 class="gd-h2">Vehicle pages</h2><p class="gd-p"><b class="gd-ui">Settings</b> &gt; <b class="gd-ui">Vehicle pages</b>. A page for every make, model, model year and Canadian trim of every year, at carmacars.ca/cars/make/model/year/trim, with our cars below it; each trim also in every place and in 12 colours (a black 2020 Volkswagen Jetta Sportline in Mississauga, for example); every page again for sale (carmacars.ca/buy/...) and for each search term: renting (car hire), sale (financing), detailing (ceramic coating) and body shop (bumper repair), at carmacars.ca/t/term/...</p><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">Pages: how many pages each level and each tier has, the total, and how many are in search. Every page is in search by default; nothing needs setting up.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">One switch per tier takes it out of search at once: <b class="gd-ui">Index the place pages</b>, <b class="gd-ui">Index the colour pages</b>, <b class="gd-ui">Index the search term pages</b>, <b class="gd-ui">Index the /buy pages</b>, <b class="gd-ui">Index the detailing pages</b>, <b class="gd-ui">Index the body shop pages</b>. Off, those pages stay visible but leave the sitemaps and search.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">The places are the place list of the local search release (every city, town and neighbourhood, with GTA and country levels); until it is filled, the area landing pages. The search terms are edited with them.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t"><b class="gd-ui">Financing disclaimer</b>: the text on financing and leasing pages. CarmaCars never says it lends or leases.</div></li><li><span class="gd-n" aria-hidden="true">5</span><div class="gd-t">Database: its size against the cap the catalog and places imports keep under: the cap of the Database plan (Pro, 6,144 MB, by default; Free, 450 MB). IndexNow: the addresses sent today, where the sweep is, and any back-off; nothing to do.</div></li><li><span class="gd-n" aria-hidden="true">6</span><div class="gd-t">Each page is built from data: the EPA fuel-use ratings in litres per 100 km, the cost to drive 100 km at the gas or electricity price set here, what changed from the year before, how a trim differs from the others, similar models, and the rental questions from the program settings.</div></li><li><span class="gd-n" aria-hidden="true">7</span><div class="gd-t">Below the facts: our cars of that exact year, model and trim, then the same model in other years, then similar cars free now, and Request it, which sends an enquiry to Bookings &gt; Leads.</div></li><li><span class="gd-n" aria-hidden="true">8</span><div class="gd-t">Settings: <b class="gd-ui">Index every page</b> (the default) or <b class="gd-ui">Only pages that pass the rules</b>: makes, models with 2 or more years of data, years with one of our cars or of a popular model from 2015, trims with one of our cars. The others stay visible but out of search. Also the gas, premium and electricity prices, and how often the catalog is imported (every 30 days).</div></li><li><span class="gd-n" aria-hidden="true">9</span><div class="gd-t">Canadian trims: open a model and type one line per run of years, entry trim first: 2020-2021: Comfortline, Highline, Sportline, Execline. Your lines are kept by every import; empty them to go back to the CarmaCars list. <b class="gd-ui">Add trims for another model</b> adds a model that has none.</div></li><li><span class="gd-n" aria-hidden="true">10</span><div class="gd-t">Catalog import: the last import and its counts. <b class="gd-ui">Import now</b> asks for a new one; it runs at the next daily check, at 07:17 UTC.</div></li></ol></div><aside class="gd-box"><span class="gd-lbl">Good to know</span><div>A car joins its pages by itself once it is on the site: its make, model, year and trim are read from the car. A trim that names several (S / SE / R-Line) leaves the car on the year page only; set the car&#39;s trim to one Canadian name to put it on the trim page.</div></aside></section><section class="gd-task" id="search-car-pages-landing-pages-and-guides-a-car-for-sale" data-gd-task><h2 class="gd-h2">A car for sale</h2><p class="gd-p"><b class="gd-ui">Cars</b> &gt; <b class="gd-ui">Vehicles</b>, then the car. On the For sale card, tick <b class="gd-ui">For sale</b>, enter the Asking price and press <b class="gd-ui">Save</b>.</p><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">The car then shows at the top of its /buy pages (its make, model, year and trim) with the asking price, the only time a page says a car is for sale.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Untick it when the car is sold or no longer for sale: the pages say so at once.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">&quot;Find me this car&quot; on the /buy pages sends a buyer lead to Sales (staff portal: <b class="gd-ui">Owner leads</b>, Buyer leads), with a To do line.</div></li></ol></div></section><section class="gd-task" id="search-car-pages-landing-pages-and-guides-search-engines-and-business-listings" data-gd-task><h2 class="gd-h2">Search engines and business listings</h2><p class="gd-p"><b class="gd-ui">Settings</b> &gt; <b class="gd-ui">All settings</b>, then Site settings.</p><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">Search engines: paste the Google Search Console value (HTML tag) or the file name (HTML file), and the Bing value. The steps are on the card.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Business name, address and phone: the exact text for every listing, and the description and categories.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Business listings: press <b class="gd-ui">Copy</b> beside each line and paste it into Google Business Profile, Bing Places, Apple Business Connect, Yelp, Yellow Pages and Facebook. Tick each one when it is done.</div></li></ol></div><aside class="gd-box"><span class="gd-lbl">Good to know</span><div>Changed pages are sent to IndexNow (Bing and the other engines that use it) by themselves. Google reads the sitemap: submit carmacars.ca/sitemap.xml once in Search Console.</div></aside></section><section class="gd-task" id="search-car-pages-landing-pages-and-guides-place-pages" data-gd-task><h2 class="gd-h2">Place pages</h2><p class="gd-p">Every place we have, from a country down to a neighbourhood, gets a page for every term people search with: renting (car hire, SUV rental, monthly car rental ...), buying help (used cars, car financing ...), detailing (ceramic coating, window tint ...) and body work (collision repair, dent repair ...). Each page is written from real data only: the distance from us, the delivery price within our reach, the nearest airport, the landmarks near it, our live cars and the places around it. A place far from Toronto says we serve the Toronto area and takes a request instead. <b class="gd-ui">Settings</b> &gt; <b class="gd-ui">All settings</b>, then Search.</p><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">Place pages: four switches, one for each family, put the pages in search and in the sitemaps. All four are on.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Quality gate: off. On, only places within the delivery reach are in search, and rental pages only with a real matching car. Search engines can treat many similar pages as low value; the gate lowers that risk.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Delivery reach: places within this distance of our location are offered delivery. Database size cap: the places import stops before the database passes it.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t">Regions and places: every province, state and territory is on. Untick a region to take its pages and sitemaps off the site.</div></li><li><span class="gd-n" aria-hidden="true">5</span><div class="gd-t">Terms and services: change a term&#39;s title or what is true about it, point a synonym to another term (its pages then leave search), switch a term off, or add one. Give a service a starting price, or leave it empty for &quot;price on request&quot;.</div></li></ol></div><aside class="gd-box"><span class="gd-lbl">Good to know</span><div>A region has pages once the places workflow has loaded it: GitHub, Actions, places, Run workflow, with the regions or all. The run loads Ontario first and names any region it skipped because of the size cap.</div></aside></section><section class="gd-task" id="search-car-pages-landing-pages-and-guides-requests-from-the-place-pages" data-gd-task><h2 class="gd-h2">Requests from the place pages</h2><p class="gd-p">The buying help, detailing and body shop pages, and the pages of places beyond our reach, have a request form. Each request is a lead with a task in <b class="gd-ui">To do</b>: detailing and body shop requests are due within an hour of opening and show in Today. Buying help pages say plainly that CarmaCars does not sell, finance or lease cars; the notice at the top is set under Place pages.</p><p class="gd-p">Mechanical work has pages too, under the body shop pages and listed apart as &quot;Auto services we arrange&quot;: a mechanic, oil changes, brakes, tires and winter tires, towing, batteries and boosts, alignment, transmission and engine repair, diagnostics, inspections and the Ontario safety certificate, emissions, AC, exhaust and suspension. CarmaCars does not do this work, and the pages say so: each takes a request (a &quot;Mechanical work to arrange&quot; task, due within an hour of opening) and offers a rental while the car is in. They have no questions of their own and no vehicle pages.</p></section><section class="gd-task" id="search-car-pages-landing-pages-and-guides-one-name-address-and-phone" data-gd-task><h2 class="gd-h2">One name, address and phone</h2><p class="gd-p">The footer, the contact page, the structured data and every business listing show the business address of Site settings. Keep it the address renters come to, and change it there only.</p></section>');
select app.guide_release_section('va', 'customer-service', 'chapter', 'your-workday', 'You answer requests with offers, quote callers, reply to renters, look renters up, and review owner forms. You are often the renter''s first person.

Your rail: Queue, Today, Requests, New quote, Renter messages, Find a renter, Calendar, Listings, Similar cars, Owners and enquiries, Owner forms and Scorecard.

## Answer a request

1. Open **Requests**. Filter by New, Waiting on the renter, Pushed back, Offer out or Offer expired.
2. Waiting shows how long the renter has waited. Open the booking number.

![](/guides/img/va-cs-03-requests-desktop-b3c66d25.jpg "desktop; size: 1440 640; address: carmacars.ca/va/requests; pins: 1 27.1 17.5, 2 52.8 32.8")

3. On the Review tab, check the request: the car is free, the renter, the places.
4. Press **Adjust the booking** to change the car, dates, places, price or extras, then **Save changes**.
5. Add a message and press **Send the offer**. Within your limit you can also use **Approve (within my limit)** or **Approve and send the pay link**.
6. Can''t do it? **Decline** with Reason and any alternative. Need to know more? **Ask the renter**.

![](/guides/img/va-cs-04-booking-review-desktop-52c68a73.jpg "desktop; size: 1440 1000; address: carmacars.ca/va/bookings/CC-10056?tab=review; pins: 3 69.4 24.0, 4 95.8 98.0")

> Tip: Reply within 5 minutes: send the offer, or ask the renter what you need. That is the "First reply in opening hours" measure on your scorecard. Requests waiting longer show in red.

## An enquiry on an example car

Some cars on the site are marked "Example car": samples that show the kind of cars we rent. A request on one is an enquiry, never a booking.

1. The task Suggest a similar real car comes to To do with the enquiry number (EQ-1001 and up), the car asked for, the dates and the contact. When a real car was free for those dates, the task names it after **Free:** (the same make and model first, else the same class and body at a similar price), and the person was told we have a similar car and will confirm it within 2 hours.
2. Check the named car is still right for them (or find a real car of the same kind and price that is free for those dates), and make a **New quote** for it.
3. Call or email the person with the car and the price, then mark the task done.

> Tip: Reply within the first reply target, as for any request. Never offer the example car itself: it does not exist.

## A request from a vehicle page

Every make, model, year and trim page (carmacars.ca/cars/toyota/rav4/2023/xle, for example) has Request it, for the exact car the person wants.

1. The request arrives as an enquiry with the car named in the message ("About the car: 2023 Toyota RAV4 XLE") and an Enquiry task in To do.
2. If we have that car, or one close to it, free for their dates, make a **New quote** for it. If not, suggest the nearest car of the same kind and price.
3. Reply by email or phone, then mark the task done.

> Tip: The pages say only what the data says: EPA fuel use, the Canadian trims and our own cars. Never promise equipment the page does not list.

## A buyer lead from a /buy page

Every vehicle page has a for-sale twin (carmacars.ca/buy/toyota/rav4/2023/xle) with "Find me this car", and twins for financing, detailing and body shop work with their own request: a name, an email or phone, and when.

1. The lead is in **Owner leads** (customer service: **Owners and enquiries**), Buyer leads (kind buyer, finance, detailing or body shop), with the car and what they asked, and a To do line for Sales: A buyer asked us to find a car, Someone asked about financing or leasing a car, A detailing request, or A body shop request.
2. If one of our cars of that kind is for sale (an Admin flags it with its price), offer it. If not, offer to rent them the car for a week first, and say what we can find. We do not lend or lease: on a financing question, say so and offer the rental. For detailing or body shop work, give a time and a price, and always offer a rental while their car is in (an insurance replacement rental when it is a claim).
3. Press **Take it**, then **Update** as you go: contacted, qualified, converted or closed with the reason.

> Tip: We mostly rent cars. Never say a car is for sale unless an Admin flagged it; the page shows it with its price when one is.

## New quote for a caller

1. Open **New quote**. Choose the Car, the Pickup and Return (at least 2 hours from now).
2. Choose how the lead came in, then the caller''s Full legal name, Email, Mobile and Date of birth.
3. Set the Licence class and Damage cover, and note places, extras and what they asked.
4. Press **Create the request**. It opens like any request; send the offer from there.

![](/guides/img/va-cs-05-new-quote-desktop-4e386b1c.jpg "desktop; size: 1220 1260; address: carmacars.ca/va/quotes/new; pins: 1 72.1 15.6, 2 72.1 41.7, 3 72.1 72.7, 4 63.9 85.5")

## Renter messages and Find a renter

1. **Renter messages** lists the latest messages with their booking. Open the booking to reply, then press **Send**.
2. **Find a renter**: search by name, email, phone or booking number.
3. To open a renter''s private details, press **Open with a reason**. The reason is kept in the access log.

![](/guides/img/va-cs-06-messages-desktop-3441fa91.jpg "desktop; size: 1440 260; address: carmacars.ca/va/messages; pins: 1 32.6 48.5")

## Add a car for an owner

Open **Owners** > **Add a car for an owner** (fleet: under Cars). You enter everything for the owner; they never fill in the application.

1. The owner: find them by name, email or phone, or choose New owner and enter the name, email, phone and address.
2. The car: type the VIN. The car is looked up at once and shown in one line with the year, make, model, trim and details (Edit if something is wrong). No VIN at hand: add it by its plate and choose the year, make and model. Tap the colour and check the class. Upload the ownership permit, the insurance slip and the lender''s information if you have them. Photos are optional.
3. Terms and first invoice: what was agreed with the owner, to the cent. An Admin checks them before anything is sent.
4. Who sourced the owner: Entered for CarmaCars, or I sourced this owner. How the owner signs: by email, or on paper.
5. Press **Add the car and send to an Admin**. The application waits in the Admin''s Applications, marked Entered by staff with your name. When the Admin approves, the owner gets one email to review and sign.

## Owner forms (Forms C and D)

1. Open **Owner forms**. Each row is a scan an owner uploaded, with the witnesses and the status.
2. Press Open to read the scan. Check every page is there and signed, with each witness''s signature and name.
3. Press **Approve**, or **Send back** with What to fix (the owner reads this).

![](/guides/img/va-cs-08-owner-forms-desktop-eceaee0b.jpg "desktop; size: 1440 300; address: carmacars.ca/va/owner-forms; pins: 2 68.6 36.7, 3 76.7 36.7")

## A rental agreement signed on paper

1. Open the booking. Under Signed on paper, press **Record paper signature**.
2. Choose the Rental agreement, or the booking change the renter signed.
3. Check Signed by and Date signed, and upload the scan of every signed page.
4. Press **Record signature**. It counts as signed, and the renter is not asked to sign again.

## Check renter documents

The renter''s licence photos, selfie and proof of coverage, before the handover.

1. Open the task "identity documents or coverage proof to review", or open the booking: **Review** shows the documents of any booking being arranged or under way, with no task needed.
2. Tick every check under a document, then press **Approve**. Or type the reason the renter reads and press **Reject**.
3. The coverage: OPCF 27 shows the insurer, policy number and expiry; credit card coverage shows the card, its type and whether the name matches. Approve or reject it as a whole.

> Tip: Each opening is logged. An Admin can do the same from Admin > To do.

## A change to a confirmed booking

On a booking''s Changes tab you can propose new dates, times or another car, as an Admin does: set the change, write the reason, press **Preview the price**, then **Send to the renter**. The renter has 48 hours to accept and sign the amendment. You also send a new signing link to an additional driver from the booking screen.

## A late return

A booking past its return time shows the late return panel. Work it in order:

| Button | When |
| --- | --- |
| **Log a call** | Record each call to the renter and what they said. |
| **Send T13** | The first late notice email. |
| **Send T14 (final notice)** | The final notice. |
| **Request disable** | Ask an Admin to approve disabling the car. |
| **Open an incident** | When the car is not coming back as planned. |
', 'Customer service', 'Requests and offers, new quotes, renter messages, find a renter, owner forms, late returns.',
  'You answer requests with offers, quote callers, reply to renters, look renters up, and review owner forms. You are often the renter''s first person.

Your rail: Queue, Today, Requests, New quote, Renter messages, Find a renter, Calendar, Listings, Similar cars, Owners and enquiries, Owner forms and Scorecard.

## Answer a request

1. Open **Requests**. Filter by New, Waiting on the renter, Pushed back, Offer out or Offer expired.
2. Waiting shows how long the renter has waited. Open the booking number.

![](/guides/img/va-cs-03-requests-desktop-b3c66d25.jpg "desktop; size: 1440 640; address: carmacars.ca/va/requests; pins: 1 27.1 17.5, 2 52.8 32.8")

3. On the Review tab, check the request: the car is free, the renter, the places.
4. Press **Adjust the booking** to change the car, dates, places, price or extras, then **Save changes**.
5. Add a message and press **Send the offer**. Within your limit you can also use **Approve (within my limit)** or **Approve and send the pay link**.
6. Can''t do it? **Decline** with Reason and any alternative. Need to know more? **Ask the renter**.

![](/guides/img/va-cs-04-booking-review-desktop-52c68a73.jpg "desktop; size: 1440 1000; address: carmacars.ca/va/bookings/CC-10056?tab=review; pins: 3 69.4 24.0, 4 95.8 98.0")

> Tip: Reply within 5 minutes: send the offer, or ask the renter what you need. That is the "First reply in opening hours" measure on your scorecard. Requests waiting longer show in red.

## An enquiry on an example car

Some cars on the site are marked "Example car": samples that show the kind of cars we rent. A request on one is an enquiry, never a booking.

1. The task Suggest a similar real car comes to To do with the enquiry number (EQ-1001 and up), the car asked for, the dates and the contact. When a real car was free for those dates, the task names it after **Free:** (the same make and model first, else the same class and body at a similar price), and the person was told we have a similar car and will confirm it within 2 hours.
2. Check the named car is still right for them (or find a real car of the same kind and price that is free for those dates), and make a **New quote** for it.
3. Call or email the person with the car and the price, then mark the task done.

> Tip: Reply within the first reply target, as for any request. Never offer the example car itself: it does not exist.

## A request from a vehicle page

Every make, model, year and trim page (carmacars.ca/cars/toyota/rav4/2023/xle, for example) has Request it, for the exact car the person wants.

1. The request arrives as an enquiry with the car named in the message ("About the car: 2023 Toyota RAV4 XLE") and an Enquiry task in To do.
2. If we have that car, or one close to it, free for their dates, make a **New quote** for it. If not, suggest the nearest car of the same kind and price.
3. Reply by email or phone, then mark the task done.

> Tip: The pages say only what the data says: EPA fuel use, the Canadian trims and our own cars. Never promise equipment the page does not list.

## A buyer lead from a /buy page

Every vehicle page has a for-sale twin (carmacars.ca/buy/toyota/rav4/2023/xle) with "Find me this car", and twins for financing, detailing and body shop work with their own request: a name, an email or phone, and when.

1. The lead is in **Owner leads** (customer service: **Owners and enquiries**), Buyer leads (kind buyer, finance, detailing or body shop), with the car and what they asked, and a To do line for Sales: A buyer asked us to find a car, Someone asked about financing or leasing a car, A detailing request, or A body shop request.
2. If one of our cars of that kind is for sale (an Admin flags it with its price), offer it. If not, offer to rent them the car for a week first, and say what we can find. We do not lend or lease: on a financing question, say so and offer the rental. For detailing or body shop work, give a time and a price, and always offer a rental while their car is in (an insurance replacement rental when it is a claim). For mechanical work (a "Mechanical work to arrange" task: an oil change, brakes, tires, a tow and the like), CarmaCars does not do the work: book it with a trusted shop or recommend one, never promise the shop''s price or time, and offer a rental while their car is in.
3. Press **Take it**, then **Update** as you go: contacted, qualified, converted or closed with the reason.

> Tip: We mostly rent cars. Never say a car is for sale unless an Admin flagged it; the page shows it with its price when one is.

## New quote for a caller

1. Open **New quote**. Choose the Car, the Pickup and Return (at least 2 hours from now).
2. Choose how the lead came in, then the caller''s Full legal name, Email, Mobile and Date of birth.
3. Set the Licence class and Damage cover, and note places, extras and what they asked.
4. Press **Create the request**. It opens like any request; send the offer from there.

![](/guides/img/va-cs-05-new-quote-desktop-4e386b1c.jpg "desktop; size: 1220 1260; address: carmacars.ca/va/quotes/new; pins: 1 72.1 15.6, 2 72.1 41.7, 3 72.1 72.7, 4 63.9 85.5")

## Renter messages and Find a renter

1. **Renter messages** lists the latest messages with their booking. Open the booking to reply, then press **Send**.
2. **Find a renter**: search by name, email, phone or booking number.
3. To open a renter''s private details, press **Open with a reason**. The reason is kept in the access log.

![](/guides/img/va-cs-06-messages-desktop-3441fa91.jpg "desktop; size: 1440 260; address: carmacars.ca/va/messages; pins: 1 32.6 48.5")

## Add a car for an owner

Open **Owners** > **Add a car for an owner** (fleet: under Cars). You enter everything for the owner; they never fill in the application.

1. The owner: find them by name, email or phone, or choose New owner and enter the name, email, phone and address.
2. The car: type the VIN. The car is looked up at once and shown in one line with the year, make, model, trim and details (Edit if something is wrong). No VIN at hand: add it by its plate and choose the year, make and model. Tap the colour and check the class. Upload the ownership permit, the insurance slip and the lender''s information if you have them. Photos are optional.
3. Terms and first invoice: what was agreed with the owner, to the cent. An Admin checks them before anything is sent.
4. Who sourced the owner: Entered for CarmaCars, or I sourced this owner. How the owner signs: by email, or on paper.
5. Press **Add the car and send to an Admin**. The application waits in the Admin''s Applications, marked Entered by staff with your name. When the Admin approves, the owner gets one email to review and sign.

## Owner forms (Forms C and D)

1. Open **Owner forms**. Each row is a scan an owner uploaded, with the witnesses and the status.
2. Press Open to read the scan. Check every page is there and signed, with each witness''s signature and name.
3. Press **Approve**, or **Send back** with What to fix (the owner reads this).

![](/guides/img/va-cs-08-owner-forms-desktop-eceaee0b.jpg "desktop; size: 1440 300; address: carmacars.ca/va/owner-forms; pins: 2 68.6 36.7, 3 76.7 36.7")

## A rental agreement signed on paper

1. Open the booking. Under Signed on paper, press **Record paper signature**.
2. Choose the Rental agreement, or the booking change the renter signed.
3. Check Signed by and Date signed, and upload the scan of every signed page.
4. Press **Record signature**. It counts as signed, and the renter is not asked to sign again.

## Check renter documents

The renter''s licence photos, selfie and proof of coverage, before the handover.

1. Open the task "identity documents or coverage proof to review", or open the booking: **Review** shows the documents of any booking being arranged or under way, with no task needed.
2. Tick every check under a document, then press **Approve**. Or type the reason the renter reads and press **Reject**.
3. The coverage: OPCF 27 shows the insurer, policy number and expiry; credit card coverage shows the card, its type and whether the name matches. Approve or reject it as a whole.

> Tip: Each opening is logged. An Admin can do the same from Admin > To do.

## A change to a confirmed booking

On a booking''s Changes tab you can propose new dates, times or another car, as an Admin does: set the change, write the reason, press **Preview the price**, then **Send to the renter**. The renter has 48 hours to accept and sign the amendment. You also send a new signing link to an additional driver from the booking screen.

## A late return

A booking past its return time shows the late return panel. Work it in order:

| Button | When |
| --- | --- |
| **Log a call** | Record each call to the renter and what they said. |
| **Send T13** | The first late notice email. |
| **Send T14 (final notice)** | The final notice. |
| **Request disable** | Ask an Admin to approve disabling the car. |
| **Open an incident** | When the car is not coming back as planned. |
',
  '<p class="gd-p">You answer requests with offers, quote callers, reply to renters, look renters up, and review owner forms. You are often the renter&#39;s first person.</p><p class="gd-p">Your rail: Queue, Today, Requests, New quote, Renter messages, Find a renter, Calendar, Listings, Similar cars, Owners and enquiries, Owner forms and Scorecard.</p><section class="gd-task" id="customer-service-answer-a-request" data-gd-task><h2 class="gd-h2">Answer a request</h2><div class="gd-stepblock gd-stepblock--below"><div class="gd-stepcol"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">Open <b class="gd-ui">Requests</b>. Filter by New, Waiting on the renter, Pushed back, Offer out or Offer expired.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Waiting shows how long the renter has waited. Open the booking number.</div></li></ol></div><figure class="gd-fig gd-fig--desk"><div class="gd-browser"><div class="gd-bar" aria-hidden="true"><i></i><i></i><i></i><span class="gd-addr">carmacars.ca/va/requests</span></div><div class="gd-imgwrap" style="aspect-ratio:1440/640"><img src="/guides/img/va-cs-03-requests-desktop-b3c66d25.jpg" alt="" loading="lazy" decoding="async" width="1440" height="640"><span class="gd-pin" style="left:27.1%;top:17.5%" aria-hidden="true">1</span><span class="gd-pin" style="left:52.8%;top:32.8%" aria-hidden="true">2</span></div></div></figure></div><div class="gd-stepblock gd-stepblock--below"><div class="gd-stepcol"><ol class="gd-ol" start="3"><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">On the Review tab, check the request: the car is free, the renter, the places.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t">Press <b class="gd-ui">Adjust the booking</b> to change the car, dates, places, price or extras, then <b class="gd-ui">Save changes</b>.</div></li><li><span class="gd-n" aria-hidden="true">5</span><div class="gd-t">Add a message and press <b class="gd-ui">Send the offer</b>. Within your limit you can also use <b class="gd-ui">Approve (within my limit)</b> or <b class="gd-ui">Approve and send the pay link</b>.</div></li><li><span class="gd-n" aria-hidden="true">6</span><div class="gd-t">Can&#39;t do it? <b class="gd-ui">Decline</b> with Reason and any alternative. Need to know more? <b class="gd-ui">Ask the renter</b>.</div></li></ol></div><figure class="gd-fig gd-fig--desk"><div class="gd-browser"><div class="gd-bar" aria-hidden="true"><i></i><i></i><i></i><span class="gd-addr">carmacars.ca/va/bookings/CC-10056?tab=review</span></div><div class="gd-imgwrap" style="aspect-ratio:1440/1000"><img src="/guides/img/va-cs-04-booking-review-desktop-52c68a73.jpg" alt="" loading="lazy" decoding="async" width="1440" height="1000"><span class="gd-pin" style="left:69.4%;top:24%" aria-hidden="true">3</span><span class="gd-pin" style="left:95.8%;top:98%" aria-hidden="true">4</span></div></div></figure></div><aside class="gd-box"><span class="gd-lbl">Tip</span><div>Reply within 5 minutes: send the offer, or ask the renter what you need. That is the &quot;First reply in opening hours&quot; measure on your scorecard. Requests waiting longer show in red.</div></aside></section><section class="gd-task" id="customer-service-an-enquiry-on-an-example-car" data-gd-task><h2 class="gd-h2">An enquiry on an example car</h2><p class="gd-p">Some cars on the site are marked &quot;Example car&quot;: samples that show the kind of cars we rent. A request on one is an enquiry, never a booking.</p><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">The task Suggest a similar real car comes to To do with the enquiry number (EQ-1001 and up), the car asked for, the dates and the contact. When a real car was free for those dates, the task names it after <b class="gd-ui">Free:</b> (the same make and model first, else the same class and body at a similar price), and the person was told we have a similar car and will confirm it within 2 hours.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Check the named car is still right for them (or find a real car of the same kind and price that is free for those dates), and make a <b class="gd-ui">New quote</b> for it.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Call or email the person with the car and the price, then mark the task done.</div></li></ol></div><aside class="gd-box"><span class="gd-lbl">Tip</span><div>Reply within the first reply target, as for any request. Never offer the example car itself: it does not exist.</div></aside></section><section class="gd-task" id="customer-service-a-request-from-a-vehicle-page" data-gd-task><h2 class="gd-h2">A request from a vehicle page</h2><p class="gd-p">Every make, model, year and trim page (carmacars.ca/cars/toyota/rav4/2023/xle, for example) has Request it, for the exact car the person wants.</p><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">The request arrives as an enquiry with the car named in the message (&quot;About the car: 2023 Toyota RAV4 XLE&quot;) and an Enquiry task in To do.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">If we have that car, or one close to it, free for their dates, make a <b class="gd-ui">New quote</b> for it. If not, suggest the nearest car of the same kind and price.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Reply by email or phone, then mark the task done.</div></li></ol></div><aside class="gd-box"><span class="gd-lbl">Tip</span><div>The pages say only what the data says: EPA fuel use, the Canadian trims and our own cars. Never promise equipment the page does not list.</div></aside></section><section class="gd-task" id="customer-service-a-buyer-lead-from-a-buy-page" data-gd-task><h2 class="gd-h2">A buyer lead from a /buy page</h2><p class="gd-p">Every vehicle page has a for-sale twin (carmacars.ca/buy/toyota/rav4/2023/xle) with &quot;Find me this car&quot;, and twins for financing, detailing and body shop work with their own request: a name, an email or phone, and when.</p><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">The lead is in <b class="gd-ui">Owner leads</b> (customer service: <b class="gd-ui">Owners and enquiries</b>), Buyer leads (kind buyer, finance, detailing or body shop), with the car and what they asked, and a To do line for Sales: A buyer asked us to find a car, Someone asked about financing or leasing a car, A detailing request, or A body shop request.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">If one of our cars of that kind is for sale (an Admin flags it with its price), offer it. If not, offer to rent them the car for a week first, and say what we can find. We do not lend or lease: on a financing question, say so and offer the rental. For detailing or body shop work, give a time and a price, and always offer a rental while their car is in (an insurance replacement rental when it is a claim). For mechanical work (a &quot;Mechanical work to arrange&quot; task: an oil change, brakes, tires, a tow and the like), CarmaCars does not do the work: book it with a trusted shop or recommend one, never promise the shop&#39;s price or time, and offer a rental while their car is in.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Press <b class="gd-ui">Take it</b>, then <b class="gd-ui">Update</b> as you go: contacted, qualified, converted or closed with the reason.</div></li></ol></div><aside class="gd-box"><span class="gd-lbl">Tip</span><div>We mostly rent cars. Never say a car is for sale unless an Admin flagged it; the page shows it with its price when one is.</div></aside></section><section class="gd-task" id="customer-service-new-quote-for-a-caller" data-gd-task><h2 class="gd-h2">New quote for a caller</h2><div class="gd-stepblock gd-stepblock--below"><div class="gd-stepcol"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">Open <b class="gd-ui">New quote</b>. Choose the Car, the Pickup and Return (at least 2 hours from now).</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Choose how the lead came in, then the caller&#39;s Full legal name, Email, Mobile and Date of birth.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Set the Licence class and Damage cover, and note places, extras and what they asked.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t">Press <b class="gd-ui">Create the request</b>. It opens like any request; send the offer from there.</div></li></ol></div><figure class="gd-fig gd-fig--desk"><div class="gd-browser"><div class="gd-bar" aria-hidden="true"><i></i><i></i><i></i><span class="gd-addr">carmacars.ca/va/quotes/new</span></div><div class="gd-imgwrap" style="aspect-ratio:1220/1260"><img src="/guides/img/va-cs-05-new-quote-desktop-4e386b1c.jpg" alt="" loading="lazy" decoding="async" width="1220" height="1260"><span class="gd-pin" style="left:72.1%;top:15.6%" aria-hidden="true">1</span><span class="gd-pin" style="left:72.1%;top:41.7%" aria-hidden="true">2</span><span class="gd-pin" style="left:72.1%;top:72.7%" aria-hidden="true">3</span><span class="gd-pin" style="left:63.9%;top:85.5%" aria-hidden="true">4</span></div></div></figure></div></section><section class="gd-task" id="customer-service-renter-messages-and-find-a-renter" data-gd-task><h2 class="gd-h2">Renter messages and Find a renter</h2><div class="gd-stepblock gd-stepblock--below"><div class="gd-stepcol"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t"><b class="gd-ui">Renter messages</b> lists the latest messages with their booking. Open the booking to reply, then press <b class="gd-ui">Send</b>.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t"><b class="gd-ui">Find a renter</b>: search by name, email, phone or booking number.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">To open a renter&#39;s private details, press <b class="gd-ui">Open with a reason</b>. The reason is kept in the access log.</div></li></ol></div><figure class="gd-fig gd-fig--desk"><div class="gd-browser"><div class="gd-bar" aria-hidden="true"><i></i><i></i><i></i><span class="gd-addr">carmacars.ca/va/messages</span></div><div class="gd-imgwrap" style="aspect-ratio:1440/260"><img src="/guides/img/va-cs-06-messages-desktop-3441fa91.jpg" alt="" loading="lazy" decoding="async" width="1440" height="260"><span class="gd-pin" style="left:32.6%;top:48.5%" aria-hidden="true">1</span></div></div></figure></div></section><section class="gd-task" id="customer-service-add-a-car-for-an-owner" data-gd-task><h2 class="gd-h2">Add a car for an owner</h2><p class="gd-p">Open <b class="gd-ui">Owners</b> &gt; <b class="gd-ui">Add a car for an owner</b> (fleet: under Cars). You enter everything for the owner; they never fill in the application.</p><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">The owner: find them by name, email or phone, or choose New owner and enter the name, email, phone and address.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">The car: type the VIN. The car is looked up at once and shown in one line with the year, make, model, trim and details (Edit if something is wrong). No VIN at hand: add it by its plate and choose the year, make and model. Tap the colour and check the class. Upload the ownership permit, the insurance slip and the lender&#39;s information if you have them. Photos are optional.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Terms and first invoice: what was agreed with the owner, to the cent. An Admin checks them before anything is sent.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t">Who sourced the owner: Entered for CarmaCars, or I sourced this owner. How the owner signs: by email, or on paper.</div></li><li><span class="gd-n" aria-hidden="true">5</span><div class="gd-t">Press <b class="gd-ui">Add the car and send to an Admin</b>. The application waits in the Admin&#39;s Applications, marked Entered by staff with your name. When the Admin approves, the owner gets one email to review and sign.</div></li></ol></div></section><section class="gd-task" id="customer-service-owner-forms-forms-c-and-d" data-gd-task><h2 class="gd-h2">Owner forms (Forms C and D)</h2><div class="gd-stepblock gd-stepblock--below"><div class="gd-stepcol"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">Open <b class="gd-ui">Owner forms</b>. Each row is a scan an owner uploaded, with the witnesses and the status.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Press Open to read the scan. Check every page is there and signed, with each witness&#39;s signature and name.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Press <b class="gd-ui">Approve</b>, or <b class="gd-ui">Send back</b> with What to fix (the owner reads this).</div></li></ol></div><figure class="gd-fig gd-fig--desk"><div class="gd-browser"><div class="gd-bar" aria-hidden="true"><i></i><i></i><i></i><span class="gd-addr">carmacars.ca/va/owner-forms</span></div><div class="gd-imgwrap" style="aspect-ratio:1440/300"><img src="/guides/img/va-cs-08-owner-forms-desktop-eceaee0b.jpg" alt="" loading="lazy" decoding="async" width="1440" height="300"><span class="gd-pin" style="left:68.6%;top:36.7%" aria-hidden="true">2</span><span class="gd-pin" style="left:76.7%;top:36.7%" aria-hidden="true">3</span></div></div></figure></div></section><section class="gd-task" id="customer-service-a-rental-agreement-signed-on-paper" data-gd-task><h2 class="gd-h2">A rental agreement signed on paper</h2><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">Open the booking. Under Signed on paper, press <b class="gd-ui">Record paper signature</b>.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Choose the Rental agreement, or the booking change the renter signed.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Check Signed by and Date signed, and upload the scan of every signed page.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t">Press <b class="gd-ui">Record signature</b>. It counts as signed, and the renter is not asked to sign again.</div></li></ol></div></section><section class="gd-task" id="customer-service-check-renter-documents" data-gd-task><h2 class="gd-h2">Check renter documents</h2><p class="gd-p">The renter&#39;s licence photos, selfie and proof of coverage, before the handover.</p><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">Open the task &quot;identity documents or coverage proof to review&quot;, or open the booking: <b class="gd-ui">Review</b> shows the documents of any booking being arranged or under way, with no task needed.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Tick every check under a document, then press <b class="gd-ui">Approve</b>. Or type the reason the renter reads and press <b class="gd-ui">Reject</b>.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">The coverage: OPCF 27 shows the insurer, policy number and expiry; credit card coverage shows the card, its type and whether the name matches. Approve or reject it as a whole.</div></li></ol></div><aside class="gd-box"><span class="gd-lbl">Tip</span><div>Each opening is logged. An Admin can do the same from Admin &gt; To do.</div></aside></section><section class="gd-task" id="customer-service-a-change-to-a-confirmed-booking" data-gd-task><h2 class="gd-h2">A change to a confirmed booking</h2><p class="gd-p">On a booking&#39;s Changes tab you can propose new dates, times or another car, as an Admin does: set the change, write the reason, press <b class="gd-ui">Preview the price</b>, then <b class="gd-ui">Send to the renter</b>. The renter has 48 hours to accept and sign the amendment. You also send a new signing link to an additional driver from the booking screen.</p></section><section class="gd-task" id="customer-service-a-late-return" data-gd-task><h2 class="gd-h2">A late return</h2><p class="gd-p">A booking past its return time shows the late return panel. Work it in order:</p><div class="gd-tablewrap"><table class="gd-table"><thead><tr><th scope="col">Button</th><th scope="col">When</th></tr></thead><tbody><tr><td><b class="gd-ui">Log a call</b></td><td>Record each call to the renter and what they said.</td></tr><tr><td><b class="gd-ui">Send T13</b></td><td>The first late notice email.</td></tr><tr><td><b class="gd-ui">Send T14 (final notice)</b></td><td>The final notice.</td></tr><tr><td><b class="gd-ui">Request disable</b></td><td>Ask an Admin to approve disabling the car.</td></tr><tr><td><b class="gd-ui">Open an incident</b></td><td>When the car is not coming back as planned.</td></tr></tbody></table></div></section>');
-- GUIDES 0121 END
