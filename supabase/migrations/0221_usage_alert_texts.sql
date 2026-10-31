-- 0221: usage alerts by text to the Admins, and the red banner on Admin > Today
-- (docs/changes/2026-11-03-usage-alert-texts.md). The owner did not know the Worker's CPU time was 36 times its included
-- allowance: the alerts went by email to the company address only (0080), behind the day's email cap.
--
-- 1. When a figure of Settings > Usage reaches 80% of its included allowance, and again at 100% (the alerts of 0080:
--    usage_alerts, one per service, period and level; a figure whose warning starts lower, the Worker's CPU time at 70%,
--    has a 70% alert too, the owner's choice), every Admin with a verified phone gets a text from the CarmaCars
--    Quo number (phone_outbox, the five-minute phone job). Once per service and level a calendar month (a daily figure
--    such as the day's emails is texted at most once a month at each level); a 100% alert covers its 80%. Outside the
--    quiet hours of the site check (they wait until morning). On by default: Program settings, usage_alert_texts.
-- 2. Admin > Today: a red banner for every figure at or past 100% this period, an amber one from its warning level (not dismissible:
--    it goes when the figure resets or the allowance is raised). Read through the door: ops_read usage_banner.
-- No applied migration is edited.

create function pg_temp.copy_grants(p_new regprocedure, p_old regprocedure) returns void
language plpgsql as $$
declare g text;
begin
  execute format('revoke all on function %s from public, anon, authenticated', p_new);
  foreach g in array array['anon', 'authenticated', 'service_role'] loop
    if has_function_privilege(g, p_old, 'execute') then execute format('grant execute on function %s to %I', p_new, g); end if;
  end loop;
end $$;

alter table program_settings add column if not exists usage_alert_texts boolean not null default true;
comment on column program_settings.usage_alert_texts is 'Usage alerts at 80% and 100% are also texted to every Admin with a verified phone (0221), once per service and level a month.';
alter table usage_alerts add column if not exists texted_at timestamptz, add column if not exists text_note text;
comment on column usage_alerts.texted_at is 'When the Admins were texted about this alert (0221); text_note says why not, when not.';

-- a 70% level for the figures whose warning starts below 80% (the Worker's CPU time, warn_bps 7000)
alter table usage_alerts drop constraint if exists usage_alerts_level_check;
alter table usage_alerts add constraint usage_alerts_level_check check (level in (70, 80, 100));
update usage_services set warn_bps = 7000 where service = 'workers_cpu' and warn_bps > 7000;

alter function app.usage_refresh_service(text, timestamptz) rename to usage_refresh_service_pre0221;
create function app.usage_refresh_service(p_service text, p_now timestamptz default now()) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  st jsonb := app.usage_refresh_service_pre0221(p_service, p_now);
  s usage_services;
  v_share integer := coalesce((st ->> 'share_bps')::integer, 0);
begin
  select * into s from usage_services where service = p_service;
  if s.warn_bps < 8000 and s.enabled and not s.unlimited and s.included > 0 then
    -- the warning alert (0080 files it as level 80 at warn_bps) is the 70% one while the figure is under 80%
    update usage_alerts a set level = 70
     where a.service = p_service and a.period_start = s.period_start and a.level = 80 and v_share < 8000
       and not exists (select 1 from usage_alerts b where b.service = a.service and b.period_start = a.period_start and b.level = 70);
    if v_share >= 8000 then
      insert into usage_alerts (service, period_start, level, used, included) values (p_service, s.period_start, 70, (st ->> 'used')::numeric, s.included)
      on conflict (service, period_start, level) do nothing;
      insert into usage_alerts (service, period_start, level, used, included) values (p_service, s.period_start, 80, (st ->> 'used')::numeric, s.included)
      on conflict (service, period_start, level) do nothing;
    end if;
  end if;
  return st;
end $$;
select pg_temp.copy_grants('app.usage_refresh_service(text, timestamptz)'::regprocedure, 'app.usage_refresh_service_pre0221(text, timestamptz)'::regprocedure);

-- the words of one alert's text
create or replace function app.usage_alert_text(p_service text, p_level integer, p_now timestamptz default now()) returns text
language sql stable security definer set search_path = public, app as $$
  select format('CarmaCars: %s at %s%% of the included allowance (%s of %s)%s. Settings > Usage: %s',
           regexp_replace(st ->> 'label', '\s*\(.*\)$', ''), greatest(p_level, ((st ->> 'share_bps')::integer / 100)),
           st ->> 'used_text', st ->> 'included_text',
           case when coalesce((st ->> 'overage_usd')::numeric, 0) > 0 then format(', about US$%s above it so far', to_char((st ->> 'overage_usd')::numeric, 'FM999,990.00')) else '' end,
           (app.settings()).notify_base_url || '/admin/settings/usage')
    from (select app.usage_state(p_service, p_now) st) x
$$;

create or replace function app.usage_send_texts(p_now timestamptz default now()) returns integer
language plpgsql security definer set search_path = public, app as $$
declare
  ps program_settings := app.settings(app.local_date(p_now));
  v_hour integer := app.local_hour(p_now);
  v_month text := to_char(app.local_date(p_now), 'YYYY-MM');
  a usage_alerts;
  u record;
  v_body text;
  v_quiet boolean;
  n integer := 0;
  k integer;
begin
  if not coalesce(ps.usage_alert_texts, true) then return 0; end if;
  v_quiet := case when ps.uptime_quiet_from_hour > ps.uptime_quiet_until_hour then v_hour >= ps.uptime_quiet_from_hour or v_hour < ps.uptime_quiet_until_hour
                  else v_hour >= ps.uptime_quiet_from_hour and v_hour < ps.uptime_quiet_until_hour end;
  if v_quiet then return 0; end if;
  for a in select * from usage_alerts x where x.texted_at is null and x.created_at > p_now - interval '35 days' and x.level in (70, 80, 100)
            order by x.level desc, x.created_at loop
    if exists (select 1 from usage_alerts b where b.service = a.service and b.level >= a.level and b.id <> a.id and b.texted_at is not null
                 and b.text_note is null and to_char(b.texted_at at time zone 'America/Toronto', 'YYYY-MM') = v_month) then
      update usage_alerts set texted_at = p_now, text_note = 'already texted this month' where id = a.id;
      continue;
    end if;
    if a.level < 100 and exists (select 1 from usage_alerts b where b.service = a.service and b.period_start = a.period_start and b.level > a.level) then
      update usage_alerts set texted_at = p_now, text_note = 'covered by a higher alert' where id = a.id;
      continue;
    end if;
    v_body := app.usage_alert_text(a.service, a.level, p_now);
    k := 0;
    for u in select x.id, x.phone from users x where app.user_is_admin(x.id) and x.phone_verified_at is not null and nullif(btrim(x.phone), '') is not null loop
      perform app.phone_outbox_put(u.phone, v_body, 'staff', null, null, 'usage_alert', null, format('usage_text:%s:%s:%s:%s', a.service, a.level, v_month, u.id));
      k := k + 1;
    end loop;
    update usage_alerts set texted_at = p_now, text_note = case when k = 0 then 'no Admin has a verified phone' end where id = a.id;
    n := n + k;
  end loop;
  return n;
end $$;

alter function app.usage_send_alerts(timestamptz) rename to usage_send_alerts_pre0221;
create function app.usage_send_alerts(p_now timestamptz default now()) returns integer
language plpgsql security definer set search_path = public, app as $$
declare n integer := app.usage_send_alerts_pre0221(p_now);
begin
  begin
    perform app.usage_send_texts(p_now);
  exception when others then
    raise warning 'usage alert texts: %', sqlerrm;
  end;
  return n;
end $$;
select pg_temp.copy_grants('app.usage_send_alerts(timestamptz)'::regprocedure, 'app.usage_send_alerts_pre0221(timestamptz)'::regprocedure);

-- ================================================================ 2. the banner on Admin > Today
create or replace function app.usage_banner(p_user uuid, p_now timestamptz default now()) returns jsonb
language plpgsql stable security definer set search_path = public, app as $$
begin
  perform app.assert_admin(p_user);
  return coalesce((select jsonb_agg(jsonb_build_object('service', s.service, 'label', st ->> 'label', 'share_bps', (st ->> 'share_bps')::integer,
                    'level', case when (st ->> 'share_bps')::integer >= 10000 then 100 when (st ->> 'share_bps')::integer >= 8000 then 80 else 70 end, 'used_text', st ->> 'used_text',
                    'included_text', st ->> 'included_text', 'overage_usd', (st ->> 'overage_usd')::numeric, 'resets_at', st ->> 'resets_at', 'period', s.period)
                    order by (st ->> 'share_bps')::integer desc)
                    from usage_services s cross join lateral app.usage_state(s.service, p_now) st
                   where s.enabled and not s.unlimited and s.included > 0 and s.service <> 'supabase_egress'
                     and (st ->> 'share_bps')::integer >= least(s.warn_bps, 8000)), '[]'::jsonb);
end $$;

alter function app.door(uuid, text, text, text, jsonb) rename to door_pre0221;
create function app.door(p_user uuid, p_aal text, p_call text, p_name text, p jsonb default '{}'::jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
begin
  if p_call in ('ops_read', 'admin_read') and p_name = 'usage_banner' then
    perform app.door_begin(p_user, p_aal);
    return app.usage_banner(p_user);
  end if;
  return app.door_pre0221(p_user, p_aal, p_call, p_name, p);
end $$;
select pg_temp.copy_grants('app.door(uuid, text, text, text, jsonb)'::regprocedure, 'app.door_pre0221(uuid, text, text, text, jsonb)'::regprocedure);

do $$
declare f record;
begin
  for f in select p.oid::regprocedure as sig from pg_proc p join pg_namespace n on n.oid = p.pronamespace
            where n.nspname = 'app' and p.proname in ('usage_alert_text', 'usage_send_texts', 'usage_send_alerts_pre0221', 'usage_refresh_service_pre0221', 'usage_banner', 'door_pre0221') loop
    execute format('revoke all on function %s from public, anon, authenticated', f.sig);
    execute format('grant execute on function %s to service_role', f.sig);
  end loop;
end $$;

-- the alerts of this month already emailed are texted once now (the owner had not heard of them)
update usage_alerts set texted_at = null where texted_at is null and created_at > now() - interval '35 days';
