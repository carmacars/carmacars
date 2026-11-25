-- 5041 (release 50; docs/changes/2026-11-25-r50-address.md): the company's location moves from 1570 Midland Ave to
-- 1940 Eglinton Ave E, Toronto, ON M1L 4R1 (the owner, Nov 25; no unit). The site's address (footer, contact, the
-- business's structured data, the map pin), the place delivery is measured from, and the guide and academy wording that
-- named the old address. The mailing address (Dundas St W) is unchanged.
-- SCHEMA_MARKER 5041.

update site_settings set
  street_address = '1940 Eglinton Ave E, Toronto, ON M1L 4R1',
  business_street = '1940 Eglinton Ave E',
  business_postal_code = 'M1L 4R1',
  business_city = 'Toronto',
  business_latitude = 43.728143,
  business_longitude = -79.288716,
  updated_at = now()
 where singleton;

update program_settings set delivery_origin_address = '1940 Eglinton Ave E, Toronto, ON M1L 4R1',
  company_latitude = 43.728143, company_longitude = -79.288716
 where delivery_origin_address ilike '%1570 Midland%';

-- the wording of the guides and the academy (the published copy too, so readers see it at once)
update guide_sections set
  body_md = replace(replace(body_md, '1570 Midland Ave, Scarborough', '1940 Eglinton Ave E, Scarborough'), '1570 Midland Ave', '1940 Eglinton Ave E'),
  published_md = replace(replace(published_md, '1570 Midland Ave, Scarborough', '1940 Eglinton Ave E, Scarborough'), '1570 Midland Ave', '1940 Eglinton Ave E'),
  published_html = replace(replace(published_html, '1570 Midland Ave, Scarborough', '1940 Eglinton Ave E, Scarborough'), '1570 Midland Ave', '1940 Eglinton Ave E')
 where coalesce(body_md, '') || coalesce(published_md, '') || coalesce(published_html, '') like '%1570 Midland Ave%';

update academy_questions set
  prompt = replace(prompt, '1570 Midland Ave', '1940 Eglinton Ave E'),
  explain = replace(explain, '1570 Midland Ave', '1940 Eglinton Ave E'),
  options = replace(options::text, '1570 Midland Ave', '1940 Eglinton Ave E')::jsonb
 where prompt || explain || options::text like '%1570 Midland Ave%';

update academy_lessons set scenes = replace(scenes::text, '1570 Midland Ave', '1940 Eglinton Ave E')::jsonb
 where scenes::text like '%1570 Midland Ave%';
