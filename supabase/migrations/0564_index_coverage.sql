-- 0564_index_coverage.sql
-- Release 28 (docs/changes/2026-11-06-r28-platform.md, B7: "the pages indexed are stuck at 172k"). Index everything stays
-- the rule: nothing is noindexed, disallowed or taken out of a sitemap.
--   1. IndexNow on every change that a search engine should see again (0061 sent a car only when it went on or off the
--      site): a car's page copy, its prices (a new rate card) and its photos (approved, public, the cover). Each queues
--      the car's address once; the five-minute job and the gsc workflow send the queue to Bing's IndexNow (shared with
--      Yandex and the other IndexNow engines, which feed Copilot and ChatGPT search).
--   2. The index coverage report: the gsc workflow inspects a sample of addresses each run with Search Console's URL
--      Inspection API (web/scripts/gsc-coverage.mjs; within its 2,000 a day) and stores the counts here: indexed, crawled
--      not indexed, discovered not indexed, and the rest, by kind of page (cars, places, vehicle pages, guides, other).

-- ================================================================ 1. IndexNow on changes
create or replace function app.indexnow_on_listing_content() returns trigger
language plpgsql security definer set search_path = public, app as $$
begin
  if new.slug is not null and new.status = 'published'
     and (new.headline, new.description, new.features, new.faq, new.seo_title, new.seo_description, new.home_area, new.content_updated_at)
         is distinct from (old.headline, old.description, old.features, old.faq, old.seo_title, old.seo_description, old.home_area, old.content_updated_at)
     and not exists (select 1 from vehicles v where v.id = new.vehicle_id and v.is_sample) then
    perform app.indexnow_queue_path('/cars/' || new.slug, 'car page changed');
  end if;
  return null;
end $$;
drop trigger if exists vehicle_listings_indexnow_content on vehicle_listings;
create trigger vehicle_listings_indexnow_content after update on vehicle_listings for each row execute function app.indexnow_on_listing_content();

create or replace function app.indexnow_on_car_change() returns trigger
language plpgsql security definer set search_path = public, app as $$
declare v_slug text;
begin
  select l.slug into v_slug from vehicle_listings l join vehicles v on v.id = l.vehicle_id
   where l.vehicle_id = new.vehicle_id and l.status = 'published' and l.slug is not null and not coalesce(v.is_sample, false);
  if v_slug is not null then
    if tg_table_name = 'rate_cards' then
      perform app.indexnow_queue_path('/cars/' || v_slug, 'prices changed');
    elsif new.is_public and new.status = 'approved' and (tg_op = 'INSERT' or (new.status, new.is_public, new.is_cover, new.processed_path, new.replaced_at)
                                                            is distinct from (old.status, old.is_public, old.is_cover, old.processed_path, old.replaced_at)) then
      perform app.indexnow_queue_path('/cars/' || v_slug, 'photos changed');
    end if;
  end if;
  return null;
end $$;
drop trigger if exists rate_cards_indexnow on rate_cards;
create trigger rate_cards_indexnow after insert on rate_cards for each row execute function app.indexnow_on_car_change();
drop trigger if exists vehicle_photos_indexnow on vehicle_photos;
create trigger vehicle_photos_indexnow after insert or update on vehicle_photos for each row execute function app.indexnow_on_car_change();
revoke all on function app.indexnow_on_listing_content(), app.indexnow_on_car_change() from public, anon, authenticated;

-- ================================================================ 2. the index coverage report
create table if not exists app.gsc_coverage_log (
  id        bigint generated always as identity primary key,
  at        timestamptz not null default now(),
  inspected integer not null check (inspected >= 0),
  by_state  jsonb not null default '{}'::jsonb,   -- {"Submitted and indexed": 80, "Crawled - currently not indexed": 30, ...}
  by_kind   jsonb not null default '{}'::jsonb,   -- {"place": {"indexed": 10, "crawled": 20, "discovered": 5, "other": 1}, ...}
  errors    integer not null default 0
);
comment on table app.gsc_coverage_log is 'Index coverage by sample (0564): each gsc run inspects addresses with Search Console''s URL Inspection API and keeps the counts by coverage state and by kind of page. Kept 180 days.';
revoke all on app.gsc_coverage_log from public, anon, authenticated;
grant select, insert, delete on app.gsc_coverage_log to service_role;

create or replace function app.gsc_coverage_store(p jsonb) returns bigint
language plpgsql security definer set search_path = public, app as $$
declare v_id bigint;
begin
  insert into app.gsc_coverage_log (inspected, by_state, by_kind, errors)
  values (greatest(coalesce((p ->> 'inspected')::integer, 0), 0), coalesce(p -> 'by_state', '{}'::jsonb), coalesce(p -> 'by_kind', '{}'::jsonb), greatest(coalesce((p ->> 'errors')::integer, 0), 0))
  returning id into v_id;
  delete from app.gsc_coverage_log where at < now() - interval '180 days';
  return v_id;
end $$;
revoke all on function app.gsc_coverage_store(jsonb) from public, anon, authenticated;
grant execute on function app.gsc_coverage_store(jsonb) to service_role;

-- the last 30 days by day, for Admin > Settings > Search (the share indexed of what was inspected)
create or replace function app.gsc_coverage_trend(p_admin uuid) returns jsonb
language plpgsql stable security definer set search_path = public, app as $$
begin
  perform app.assert_admin(p_admin);
  return coalesce((select jsonb_agg(jsonb_build_object('day', d.day, 'inspected', d.inspected, 'indexed', d.indexed, 'crawled', d.crawled, 'discovered', d.discovered) order by d.day desc)
    from (select (c.at at time zone 'America/Toronto')::date as day, sum(c.inspected) inspected,
                 sum(coalesce((c.by_state ->> 'Submitted and indexed')::int, 0) + coalesce((c.by_state ->> 'Indexed, not submitted in sitemap')::int, 0)) indexed,
                 sum(coalesce((c.by_state ->> 'Crawled - currently not indexed')::int, 0)) crawled,
                 sum(coalesce((c.by_state ->> 'Discovered - currently not indexed')::int, 0)) discovered
            from app.gsc_coverage_log c where c.at > now() - interval '30 days' group by 1) d), '[]'::jsonb);
end $$;
create or replace function public.server_gsc_coverage_trend(p_admin uuid) returns jsonb
language sql stable security definer set search_path = public, app as $$ select app.gsc_coverage_trend(p_admin) $$;
revoke all on function app.gsc_coverage_trend(uuid), public.server_gsc_coverage_trend(uuid) from public, anon, authenticated;
grant execute on function public.server_gsc_coverage_trend(uuid) to service_role;

-- the server may run every function of the app schema (suites 06, 08 and 09)
do $g$
declare f regprocedure;
begin
  for f in select p.oid::regprocedure from pg_proc p join pg_namespace n on n.oid = p.pronamespace
            where n.nspname = 'app' and not has_function_privilege('service_role', p.oid, 'execute') loop
    execute format('grant execute on function %s to service_role', f);
  end loop;
end $g$;
