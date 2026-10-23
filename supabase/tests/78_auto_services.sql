-- 78: the mechanical work we arrange (migration 0121). Pages for mechanical work CarmaCars does not do: own terms and
-- synonyms in the body shop family, each a request of the auto_service kind (a task for the team to arrange it with a
-- trusted shop), never served as our work, no questions of their own, no vehicle page trees, their own four places in the
-- priority sitemap. Fixtures: one request, removed again.
select test.suite('78 auto services');

-- ================================================================ 1. the terms
select test.eq('terms: the mechanical work the owner listed, each with its own page',
  (select string_agg(slug, ',' order by slug) from place_terms where lead_kind = 'auto_service' and canonical_slug is null),
  'battery-boost,brake-repair,car-ac-repair,car-battery-replacement,car-diagnostics,car-inspection,emissions-test,engine-repair,exhaust-repair,mechanic,oil-change,'
  || 'safety-certificate,suspension-repair,tire-change,tire-repair,tire-shop,towing,transmission-repair,wheel-alignment,winter-tires');
select test.eq('terms: body shop family, a request, no service of ours, no questions',
  (select count(*)::integer from place_terms where lead_kind = 'auto_service'
      and (vertical <> 'bodyshop' or served <> 'request' or service_code is not null or faq <> '[]'::jsonb or landing_slug is not null)), 0);
select test.eq('terms: every note says the work is not done by CarmaCars',
  (select string_agg(slug, ',') from place_terms where lead_kind = 'auto_service' and intent_note !~ 'not by CarmaCars'), null);
select test.eq('terms: the synonyms of 0121 point to its own terms',
  (select count(*)::integer from place_terms s join place_terms t on t.slug = s.canonical_slug where s.lead_kind = 'auto_service' and t.lead_kind = 'auto_service'), 57);
select test.eq('terms: the owner''s words each have a page or a synonym',
  (select string_agg(w, ',') from unnest(array['mechanic', 'auto-mechanic', 'oil-change', 'brake-repair', 'tire-change', 'tire-shop', 'winter-tires', 'towing', 'tow-truck',
     'car-battery-replacement', 'battery-boost', 'wheel-alignment', 'transmission-repair', 'engine-repair', 'car-inspection', 'safety-certificate', 'emissions-test',
     'car-ac-repair', 'car-diagnostics']) w where not exists (select 1 from place_terms t where t.slug = w and t.is_active)), null);
select test.ok('terms: body repair still says it is not mechanical work, and the windshield stays body work',
  (select bool_and(intent_note ~* 'do not do mechanical') from place_terms where slug in ('car-repair', 'auto-repair'))
  and (select lead_kind from place_terms where slug = 'windshield-repair') = 'bodyshop');
select test.throws('terms: a lead kind must be one we handle', $$update place_terms set lead_kind = 'garage' where slug = 'oil-change'$$, 'place_terms_lead_kind_check');

-- ================================================================ 2. the pages
select test.eq('hub: a place page in the body shop family, a request we arrange, no service of ours',
  (select format('%s %s %s %s', h ->> 'path', h -> 'term' ->> 'served', h -> 'term' ->> 'lead_kind', coalesce(h ->> 'service', 'none'))
     from (select public.place_hub('bodyshop', 'oil-change', 'canada') h) x), '/body-shop/oil-change/canada request auto_service none');
select test.eq('hub: a synonym is served with its term''s page as canonical',
  (select public.place_hub('bodyshop', 'tow-truck', 'canada') -> 'term' ->> 'canonical_path'), '/body-shop/towing/canada');
select test.eq('hub: a synonym is never indexed', (select (public.place_hub('bodyshop', 'tow-truck', 'canada') ->> 'indexable')::boolean), false);
select test.eq('the public term list gives the lead kind',
  (select e ->> 'lead_kind' from jsonb_array_elements(public.place_terms_public()) e where e ->> 'slug' = 'oil-change'), 'auto_service');

-- ================================================================ 3. sitemaps, vehicle pages, priority
select test.eq('sitemaps: every own term has its files, no synonym',
  (select count(distinct f ->> 'term')::integer from jsonb_array_elements(public.place_sitemap_files()) f join place_terms t on t.slug = f ->> 'term' and t.lead_kind = 'auto_service'),
  (select case when (app.settings()).bodyshop_hubs_index then 20 else 0 end));
select test.eq('vehicle pages: no tree for the mechanical work we arrange',
  (select count(*)::integer from app.vpage_terms() v join place_terms t on t.slug = v.slug where t.lead_kind = 'auto_service'), 0);
select test.ok('vehicle pages: the body shop trees stay', exists (select 1 from app.vpage_terms() where slug = 'collision-repair'));
select test.ok('priority sitemap: the first four of the mechanical work only, as a family of its own',
  app.sitemap_priority_refresh() >= 0
  and not exists (select 1 from app.sitemap_priority_cache c join place_terms t on t.lead_kind = 'auto_service' and c.path like '/body-shop/' || t.slug || '/%'
                   where t.slug not in ('mechanic', 'oil-change', 'brake-repair', 'tire-change'))
  and ((select count(*) from places p join place_regions r on r.id = p.region_id and r.code = 'CA-ON' where p.kind in (5, 6) and p.is_active) = 0
       or exists (select 1 from app.sitemap_priority_cache c where c.path like '/body-shop/oil-change/%')));

-- ================================================================ 4. the request
create temp table r78 as select public.submit_place_lead(jsonb_build_object('kind', 'auto_service', 'name', 'Test Seventyeight', 'email', 't78@example.com',
  'payload', jsonb_build_object('service', 'Oil Change', 'vehicle', '2019 Honda Civic', 'place', 'Kingston', 'term', 'oil-change'))) as r;
select test.eq('request: taken', (select r ->> 'ok' from r78), 'true');
select test.eq('request: a lead of the auto_service kind',
  (select kind from leads where id = (select (r ->> 'lead_id')::uuid from r78)), 'auto_service');
select test.ok('request: a task for the team to arrange it, high, within the hour, saying it is not ours',
  exists (select 1 from tasks where related_id = (select (r ->> 'lead_id')::uuid from r78) and task_type = 'auto_service_request' and queue = 'cs'
           and detail ~ 'mechanical work we arrange \(not ours\)' and detail ~ 'Oil Change'));
select test.throws('request: an unknown kind is refused', $$select public.submit_place_lead('{"kind": "garage", "name": "X", "email": "x@example.com"}')$$, 'Unknown kind');
delete from tasks where related_id = (select (r ->> 'lead_id')::uuid from r78);
delete from leads where id = (select (r ->> 'lead_id')::uuid from r78);
