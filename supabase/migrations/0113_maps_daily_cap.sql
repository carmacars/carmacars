-- 0113: a hard daily cap on each Google Maps Platform call the website makes, so the use stays inside Google's free
-- monthly allowance (10,000 calls a SKU a month; 320 a day x 31 days = 9,920).
--   Address suggestions (Places API (New) Autocomplete), Place Details and Routes computeRoutes each have their own
--   cap a Toronto calendar day (Admin > Settings > Program, maps_daily_cap_*; 320 by default, 0 = never call Google).
--   The website takes one call from the day's budget before each request to Google (public.server_maps_take, service
--   role only). Over the cap, or when the database cannot be reached, it does not call Google: the address field takes
--   the address as typed and the delivery distance is the straight-line estimate (web/src/integrations/maps/budget.ts).
-- The count is app.rate_limit (0019) on a key per SKU and Toronto date. app.rate_limit bins its windows from midnight
-- UTC, and a Toronto day always spans one, so a one-day window would start the count again at 19:00 or 20:00 Toronto
-- time. The key carries the Toronto date instead and the window is one bin that holds every date (100,000 days from
-- 2000-01-01): the count runs exactly from Toronto midnight to Toronto midnight. Those rows are never old enough for
-- the purge job (0024); the first call of a day removes the earlier days' maps rows itself.

alter table program_settings
  add column if not exists maps_daily_cap_autocomplete integer not null default 320 check (maps_daily_cap_autocomplete between 0 and 10000),
  add column if not exists maps_daily_cap_place_details integer not null default 320 check (maps_daily_cap_place_details between 0 and 10000),
  add column if not exists maps_daily_cap_routes integer not null default 320 check (maps_daily_cap_routes between 0 and 10000);
comment on column program_settings.maps_daily_cap_autocomplete is 'Google address suggestions (Places Autocomplete) the website may ask for in one Toronto day (0113). Over it the address field takes the address as typed. 320 a day keeps a month inside Google''s free 10,000. 0 = never call Google.';
comment on column program_settings.maps_daily_cap_place_details is 'Google Place Details lookups (the chosen address''s location) in one Toronto day (0113). Over it the delivery distance is "to be confirmed". 320 a day keeps a month inside Google''s free 10,000. 0 = never call Google.';
comment on column program_settings.maps_daily_cap_routes is 'Google Routes driving distances (the delivery fee) in one Toronto day (0113). Over it the distance is the straight-line estimate. 320 a day keeps a month inside Google''s free 10,000. 0 = never call Google.';

-- True when the call may go to Google: this SKU has been used no more than its cap today (Toronto). Counts the call.
create or replace function app.maps_take(p_sku text, p_now timestamptz default now()) returns boolean
language plpgsql security definer set search_path = public, app as $$
declare
  v_day date := app.local_date(p_now);
  v_set program_settings := app.settings();   -- the caps in force now (p_now only places the call in its Toronto day)
  v_cap integer;
  v_key text;
begin
  v_cap := case p_sku
    when 'autocomplete' then v_set.maps_daily_cap_autocomplete
    when 'place_details' then v_set.maps_daily_cap_place_details
    when 'routes' then v_set.maps_daily_cap_routes
  end;
  if v_cap is null then
    raise exception 'Unknown maps SKU: %', coalesce(p_sku, 'null') using errcode = '22023';
  end if;
  if v_cap < 1 then return false; end if;
  v_key := 'maps:' || p_sku || ':' || to_char(v_day, 'YYYY-MM-DD');
  if not exists (select 1 from app.rate_limit_hits where key = v_key) then
    -- the day's first call: the earlier days' counters of this SKU are not read again
    delete from app.rate_limit_hits where key like 'maps:' || p_sku || ':%' and key <> v_key;
  end if;
  return app.rate_limit(v_key, v_cap, interval '100000 days');
end $$;

-- The website's call (service role): one round trip before each Google request.
create or replace function public.server_maps_take(p_sku text) returns boolean
language sql volatile security definer set search_path = public, app as $$ select app.maps_take(p_sku) $$;

-- What today's counters say (for a support check in SQL; not called by the website).
create or replace function app.maps_usage_today(p_now timestamptz default now()) returns jsonb
language sql stable security definer set search_path = public, app as $$
  select jsonb_build_object(
    'day', app.local_date(p_now),
    'autocomplete', coalesce((select hits from app.rate_limit_hits where key = 'maps:autocomplete:' || to_char(app.local_date(p_now), 'YYYY-MM-DD')), 0),
    'place_details', coalesce((select hits from app.rate_limit_hits where key = 'maps:place_details:' || to_char(app.local_date(p_now), 'YYYY-MM-DD')), 0),
    'routes', coalesce((select hits from app.rate_limit_hits where key = 'maps:routes:' || to_char(app.local_date(p_now), 'YYYY-MM-DD')), 0))
$$;

revoke all on function app.maps_take(text, timestamptz) from public, anon, authenticated;
revoke all on function app.maps_usage_today(timestamptz) from public, anon, authenticated;
revoke all on function public.server_maps_take(text) from public, anon, authenticated;
grant execute on function app.maps_take(text, timestamptz) to service_role;
grant execute on function app.maps_usage_today(timestamptz) to service_role;
grant execute on function public.server_maps_take(text) to service_role;
