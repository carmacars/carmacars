-- r50 (4702): 4701 added the connector's app.site_health(uuid, jsonb default '{}') beside the Admin dashboard's
-- app.site_health(uuid) (0096). With the default, every one-argument call (admin_read 'site_health', the Admin home)
-- was ambiguous: "function app.site_health(uuid) is not unique". The connector's version takes its jsonb without a
-- default (api_call always passes it), so app.site_health(uuid) is the dashboard's again.
drop function if exists app.site_health(uuid, jsonb);

create function app.site_health(p_by uuid, p jsonb) returns jsonb
language plpgsql stable security definer set search_path = public, app, pg_temp as $$
declare
  h jsonb;
begin
  if not app.user_is_admin(p_by) then raise exception 'Only an Admin reads the site health' using errcode = '42501'; end if;
  h := app.data_health_read(p_by);
  return jsonb_build_object(
    'checks', coalesce((select jsonb_agg(jsonb_build_object('key', c.key, 'label', c.label, 'kind', c.kind, 'path', c.path, 'status', c.status,
              'failing_since', c.failing_since, 'consecutive_failures', c.consecutive_failures, 'last_checked_at', c.last_checked_at, 'last_ok_at', c.last_ok_at,
              'last_http', c.last_http, 'last_ms', c.last_ms, 'detail', left(app.redact_text(c.last_detail), 300), 'advice', c.advice,
              'failures_24h', (select count(*) from uptime_results r where r.check_key = c.key and not r.ok and r.at > now() - interval '24 hours')) order by c.sort)
             from uptime_checks c where c.enabled and (c.status is distinct from 'ok'
               or exists (select 1 from uptime_results r where r.check_key = c.key and not r.ok and r.at > now() - interval '24 hours'))), '[]'::jsonb),
    'checks_ok', (select count(*) from uptime_checks c where c.enabled and c.status = 'ok'),
    'data_health', jsonb_build_object('ran_at', h -> 'ran_at', 'issues', h -> 'issues',
      'problems', coalesce((select jsonb_agg(jsonb_build_object('key', c ->> 'key', 'title', c ->> 'title', 'count', (c ->> 'count')::integer, 'line', left(app.redact_text(c ->> 'line'), 300), 'href', c ->> 'href'))
                            from jsonb_array_elements(coalesce(h -> 'checks', '[]'::jsonb)) c where coalesce((c ->> 'count')::integer, 0) > 0), '[]'::jsonb),
      'fixed', h -> 'fixed'));
end $$;


revoke all on function app.site_health(uuid, jsonb) from public, anon, authenticated;
grant execute on function app.site_health(uuid, jsonb) to service_role;
