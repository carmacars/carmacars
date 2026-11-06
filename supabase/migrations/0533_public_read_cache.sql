-- 0533 (hotfix r27b, part 1b, 2026-11-06, docs/changes/2026-11-06-r27b-load-guard.md): the three reads every public page
-- makes, kept in the database. pg_stat_statements on the company server: public.seo_links() 1,313 ms a call (619,000
-- calls), public.seo_hub_links() 1,134 ms (611,000), public.site_facts() about 650 ms (531,000). They take no argument and
-- answer the same for every page; the Worker keeps them 5 minutes per isolate, but scrapers spread over hundreds of data
-- centres start cold isolates all the time, and at 16:30 UTC these reads held most of PostgREST's 20 connections
-- (load 25, the API timing out, Admin sign-in failing). Now each is worked out once every few minutes by pg_cron and the
-- functions answer from the kept copy (a few milliseconds); with no copy yet they work it out as before.
-- No applied migration is edited.

create table if not exists app.public_read_cache (
  key   text primary key,
  value jsonb not null,
  at    timestamptz not null default now()
);
comment on table app.public_read_cache is 'The public reads every page makes (0533), worked out every few minutes by app.job_public_read_cache().';
revoke all on app.public_read_cache from public, anon, authenticated;

-- the live versions, out of the public schema
alter function public.seo_hub_links() rename to seo_hub_links_live;
alter function public.seo_hub_links_live() set schema app;
alter function public.site_facts() rename to site_facts_live;
alter function public.site_facts_live() set schema app;
revoke all on function app.seo_hub_links_live(), app.site_facts_live() from public, anon, authenticated;

create or replace function app.job_public_read_cache() returns text
language plpgsql security definer set search_path = public, app as $$
begin
  insert into app.public_read_cache (key, value, at) values
    ('seo_links', coalesce(app.public_seo_links(), '[]'::jsonb), now()),
    ('seo_hub_links', coalesce(app.seo_hub_links_live(), '{}'::jsonb), now()),
    ('site_facts', coalesce(app.site_facts_live(), '{}'::jsonb), now())
  on conflict (key) do update set value = excluded.value, at = excluded.at;
  return 'ok';
end $$;
revoke all on function app.job_public_read_cache() from public, anon, authenticated;

-- the database test suites switch the copy off (helpers.sql: alter database ... set app.read_cache = 'off'): they change the
-- data and read it back at once
create or replace function app.read_cache_on() returns boolean
language sql stable as $$ select coalesce(current_setting('app.read_cache', true), '') <> 'off' $$;

create or replace function public.seo_links() returns jsonb
language sql stable security definer set search_path = public, app as $$
  select coalesce((select c.value from app.public_read_cache c where c.key = 'seo_links' and app.read_cache_on() and c.at > now() - interval '1 hour'), app.public_seo_links())
$$;
create or replace function public.seo_hub_links() returns jsonb
language sql stable security definer set search_path = public, app as $$
  select coalesce((select c.value from app.public_read_cache c where c.key = 'seo_hub_links' and app.read_cache_on() and c.at > now() - interval '1 hour'), app.seo_hub_links_live())
$$;
create or replace function public.site_facts() returns jsonb
language sql stable security definer set search_path = public, app as $$
  select coalesce((select c.value from app.public_read_cache c where c.key = 'site_facts' and app.read_cache_on() and c.at > now() - interval '15 minutes'), app.site_facts_live())
$$;
revoke all on function public.seo_links(), public.seo_hub_links(), public.site_facts() from public;
grant execute on function public.seo_links(), public.seo_hub_links(), public.site_facts() to anon, authenticated, service_role;

-- an edit of the site's or the program's settings is shown at once (the copy is dropped; the next read works it out)
create or replace function app.public_read_cache_drop() returns trigger
language plpgsql security definer set search_path = public, app as $$
begin
  delete from app.public_read_cache;
  return null;
end $$;
drop trigger if exists public_read_cache_drop on site_settings;
create trigger public_read_cache_drop after insert or update or delete on site_settings for each statement execute function app.public_read_cache_drop();
drop trigger if exists public_read_cache_drop on program_settings;
create trigger public_read_cache_drop after insert or update or delete on program_settings for each statement execute function app.public_read_cache_drop();

-- the first copy now, then every 3 minutes
select app.job_public_read_cache();
do $$
begin
  if to_regclass('cron.job') is not null then
    perform cron.schedule('carmacars-public-read-cache', '*/3 * * * *', 'select app.job_public_read_cache()');
  end if;
end $$;
