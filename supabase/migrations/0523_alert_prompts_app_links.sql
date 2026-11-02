-- 0523: ask for alerts at the right moment, and the store app's links (docs/changes/2026-11-07-r27-leftovers.md, section 5).
--
-- 1. When to ask. 0300's invitation shows on a portal's first page unless "Not now" was pressed on that device in the
--    last 30 days, so an owner who pressed it while the application was waiting was never asked again once approved,
--    and staff were asked like everyone else. Now the database says when a person must be asked, whatever the device
--    remembers: an owner once their application is approved (asked again after a later approval), staff (Admin,
--    assistants, field) at their first sign-in. users.alerts_asked_at records the answer (Turn on or Not now, on any
--    device); a person with a device already on is never asked. public.server_alerts_ask (the portal layouts) and
--    public.server_alerts_asked (the invitation's buttons), service role only.
-- 2. The store app's links. Program settings app_store_url and play_store_url (empty until the apps are live). When one
--    is set, a phone browser sees "Download the CarmaCars app" (the site footer and the alerts invitation), with the link
--    of its own store; never inside the app. public.app_links() reads them (anyone).
-- 3. client_errors (0433) gets the admin policy every table has (04_rls) and joins the telemetry tables that keep no row
--    audit (03_flows): a crash report is written by the server only and never changed.
-- 4. Live map (found by the full test suite): while any placeholder booking (0283) was open, every pin without a booking
--    (a visitor on the site, a lead, a game) disappeared, because 0283's filter compared their empty booking number with
--    the placeholders' and a comparison with nothing is never true. Only the placeholders' own pins are left out now.
--    0283's layer (renamed live_map_pre0400 by 0400) is replaced with the corrected filter.
-- No applied migration is edited.

-- ================================================================ 1. when to ask
alter table users add column if not exists alerts_asked_at timestamptz;
comment on column users.alerts_asked_at is 'Alerts (0523): when this person answered the invitation (Turn on or Not now, on any device). An owner is asked again after a later approval; staff only once.';

create or replace function public.server_alerts_ask(p_user uuid) returns jsonb
language plpgsql stable security definer set search_path = public, app as $$
declare
  u users;
  v_approved timestamptz;
  v_why text;
begin
  select * into u from users where id = p_user;
  if not found then return jsonb_build_object('ask', false, 'why', null); end if;
  if exists (select 1 from push_subscriptions s where s.user_id = p_user) then return jsonb_build_object('ask', false, 'why', 'on'); end if;
  -- staff: their first sign-in (never answered)
  if u.alerts_asked_at is null and exists (select 1 from user_roles r where r.user_id = p_user and r.role::text in ('admin', 'va', 'field')) then
    v_why := 'staff_first';
  else
    -- an owner: the application approved after the last answer
    select max(a.decided_at) into v_approved
      from owner_applications a join owners o on o.id = a.owner_id
     where o.user_id = p_user and a.status = 'approved' and a.decided_at is not null;
    if v_approved is not null and v_approved > coalesce(u.alerts_asked_at, '-infinity'::timestamptz) then v_why := 'owner_approved'; end if;
  end if;
  return jsonb_build_object('ask', v_why is not null, 'why', v_why);
end $$;

create or replace function public.server_alerts_asked(p_user uuid, p_answer text) returns jsonb
language plpgsql security definer set search_path = public, app as $$
begin
  if p_answer not in ('on', 'later') then raise exception 'Answer on or later' using errcode = '22023'; end if;
  update users set alerts_asked_at = now() where id = p_user;
  return public.server_alerts_ask(p_user);
end $$;

-- ================================================================ 2. the store app's links
alter table program_settings
  add column if not exists app_store_url text check (app_store_url is null or app_store_url = '' or app_store_url ~ '^https://apps\.apple\.com/[^\s]+$'),
  add column if not exists play_store_url text check (play_store_url is null or play_store_url = '' or play_store_url ~ '^https://play\.google\.com/[^\s]+$');
-- 0463 (staff alerts) added the same two columns with a looser check: each must be a link of its own store
alter table program_settings
  add constraint program_settings_app_store_url_store check (app_store_url is null or app_store_url = '' or app_store_url ~ '^https://apps\.apple\.com/[^\s]+$'),
  add constraint program_settings_play_store_url_store check (play_store_url is null or play_store_url = '' or play_store_url ~ '^https://play\.google\.com/[^\s]+$');
comment on column program_settings.app_store_url is 'The CarmaCars app on the App Store (0523), https://apps.apple.com/... Empty until the app is live. When set, iPhones browsing the site see "Download the CarmaCars app".';
comment on column program_settings.play_store_url is 'The CarmaCars app on Google Play (0523), https://play.google.com/... Empty until the app is live. When set, Android phones browsing the site see "Download the CarmaCars app".';

create or replace function public.app_links() returns jsonb
language sql stable security definer set search_path = public, app as $$
  select jsonb_build_object('ios', nullif(btrim(s.app_store_url), ''), 'android', nullif(btrim(s.play_store_url), '')) from (select (app.settings()).*) s
$$;

-- ================================================================ 3. client_errors: the admin policy
drop policy if exists admin_all on client_errors;
create policy admin_all on client_errors for all to authenticated using (app.is_admin()) with check (app.is_admin());
revoke all on client_errors from anon, authenticated;
grant all on client_errors to service_role;

-- ================================================================ 4. live map: pins without a booking stay
create or replace function app.live_map_pre0400(p_by uuid, p jsonb default '{}'::jsonb) returns jsonb
language plpgsql stable security definer set search_path = public, app as $$
declare
  v jsonb := app.live_map_pre0283(p_by, p);
  v_day date := app.local_date(now());
  v_ph text[] := array(select b.booking_number from bookings b where b.is_placeholder and b.status in ('requested', 'offered', 'tentative', 'pending_payment', 'confirmed', 'on_rent'));
begin
  if cardinality(v_ph) = 0 or v is null then return v; end if;
  v := jsonb_set(v, '{pins}', coalesce((select jsonb_agg(x order by n) from jsonb_array_elements(v -> 'pins') with ordinality t(x, n)
                                         where coalesce(x ->> 'booking_number', '') <> all (v_ph)), '[]'::jsonb));
  v := jsonb_set(v, '{kpi,requests_today}', to_jsonb(greatest(0, coalesce((v #>> '{kpi,requests_today}')::integer, 0)
         - (select count(*) from bookings b where b.is_placeholder and b.booked_at >= app.local_midnight(v_day) and b.booking_type <> 'owner')::integer)));
  v := jsonb_set(v, '{kpi,bookings_week}', to_jsonb(greatest(0, coalesce((v #>> '{kpi,bookings_week}')::integer, 0)
         - (select count(*) from bookings b where b.is_placeholder and b.confirmed_at >= app.local_midnight(date_trunc('week', v_day)::date) and b.booking_type <> 'owner')::integer)));
  return v;
end $$;

-- ================================================================ privileges
revoke all on function public.server_alerts_ask(uuid) from public, anon, authenticated;
revoke all on function public.server_alerts_asked(uuid, text) from public, anon, authenticated;
grant execute on function public.server_alerts_ask(uuid), public.server_alerts_asked(uuid, text) to service_role;
revoke all on function public.app_links() from public;
grant execute on function public.app_links() to anon, authenticated, service_role;
