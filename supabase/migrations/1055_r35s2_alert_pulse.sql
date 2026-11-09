-- 1055_r35s2_alert_pulse.sql
-- Release 35, part S2: the Admin and staff portals show a toast with a pulse when a new request (or an accepted offer)
-- comes in while a page is open (web/src/features/motion/Moment.tsx, AlertPulse; read by /api/alerts/latest every 30
-- seconds). public.server_alert_latest: the person's newest unread staff alert of the last day, with its kind. No
-- applied migration is edited.
create function app.server_alert_latest(p_user uuid) returns jsonb
language sql stable security definer set search_path = public, app as $$
  select jsonb_build_object('latest', (
    select jsonb_build_object('id', n.id, 'title', n.title, 'url', n.url, 'created_at', n.created_at,
             'kind', case when n.code like '%offer%' and (n.code like '%approved%' or n.code like '%accepted%' or n.code like '%paid%') then 'offer'
                          when n.code like '%request%' or n.code like '%lead%' then 'request' else 'other' end)
      from notifications n join notification_catalogue c on c.code = n.code
     where n.user_id = p_user and n.read_at is null and c.audience like 'staff%' and n.created_at > now() - interval '1 day'
     order by n.created_at desc limit 1))
$$;
create function public.server_alert_latest(p_user uuid) returns jsonb
language sql stable security definer set search_path = public, app as $$ select app.server_alert_latest(p_user) $$;
revoke all on function app.server_alert_latest(uuid), public.server_alert_latest(uuid) from public, anon, authenticated;
grant execute on function app.server_alert_latest(uuid), public.server_alert_latest(uuid) to service_role;
