-- 47: search pages read fast (migration 0068). The snapshot of each landing page's cars, written from one read of the
-- fleet; a page reads it while the fleet is unchanged and the live fleet once a car, listing or rate changed; the
-- sitemap dates a landing page by its cars' last change without reading the fleet; who may write snapshots. Uses the
-- landing pages and cars of suite 40 (fixtures "se").
select test.suite('47 search pages read fast');

create temp table s44 as select public.seo_page('se-suv') as live_before;
select app.seo_snapshot_refresh();
select test.ok('snapshot: the refresh writes every active page', not exists (select 1 from seo_pages where is_active and (cars_snapshot is null or snapshot_stamp is null)));
select test.eq('snapshot: a page read from it is the page read live', (select public.seo_page('se-suv') - 'lastmod'), (select live_before - 'lastmod' from s44));
select test.eq('snapshot: it is used while the fleet is unchanged',
  (select app.seo_page_snapshot(p) is not null from seo_pages p where slug = 'se-suv'), true);
select test.eq('snapshot: an unchanged fleet changes no page', app.seo_snapshot_refresh(), 0);
update seo_pages set cars_changed_at = timestamptz '2026-01-01 00:00Z' where slug = 'se-suv';

-- a new daily rate for the SUV: the stamp changes, the page reads live at once, the refresh records the change
update rate_cards set effective_to = now() where vehicle_id = (select vehicle_id from vehicle_listings where slug = 'se-crv') and effective_to is null;
insert into rate_cards (vehicle_id, daily_rate_cents, weekend_rate_cents, weekly_rate_cents, monthly_rate_cents, km_allowance_per_day, overage_cents_per_km, deposit_cents, delivery_fee_cents, pickup_fee_cents, effective_from)
select vehicle_id, 4400, weekend_rate_cents, weekly_rate_cents, monthly_rate_cents, km_allowance_per_day, overage_cents_per_km, deposit_cents, delivery_fee_cents, pickup_fee_cents, clock_timestamp()
  from rate_cards where vehicle_id = (select vehicle_id from vehicle_listings where slug = 'se-crv') order by effective_from desc limit 1;
select test.eq('stale: after a rate change the snapshot is not used', (select app.seo_page_snapshot(p) is null from seo_pages p where slug = 'se-suv'), true);
select test.eq('stale: the page shows the new lowest price before any refresh', (select (public.seo_page('se-suv') ->> 'min_daily_cents')::integer), 4400);
create temp table s44r as select app.seo_snapshot_refresh() as n;
select test.ok('refresh: the SUV page changed', (select n >= 1 from s44r));
select test.ok('refresh: the date of its cars'' change moves to now',
  (select cars_changed_at > now() - interval '1 minute' and (cars_snapshot -> 'counts' ->> 'min_daily_cents')::integer = 4400 from seo_pages where slug = 'se-suv'));
select test.ok('sitemap: a landing page is dated by its text or its cars, whichever changed last',
  (select s.lastmod = greatest(p.content_updated_at, p.cars_changed_at) from public.sitemap_all() s join seo_pages p on s.path = '/car-rental/' || p.slug where p.slug = 'se-place'));
select test.ok('hub: the counts come from the snapshots', (select (x ->> 'min_daily_cents')::integer = 4400
  from jsonb_array_elements(public.seo_pages_public()) x where x ->> 'slug' = 'se-suv'));

set role anon;
select test.throws('anon: cannot write the snapshots', $$select public.server_seo_snapshots()$$, 'permission');
select test.throws('anon: cannot run the refresh', $$select app.seo_snapshot_refresh()$$, 'permission');
select test.lives('anon: still reads a landing page and the sitemap', $$select public.seo_page('se-suv'), (select count(*) from public.sitemap_all())$$);
reset role;
