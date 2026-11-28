-- R51 (REQ-140, owner Nov 27 22:28: "How many users am I getting week over week"): the connector reads the site's
-- visitors week by week, read only, Admin only. Weeks start Monday, Toronto days. From visitor_daily (kept 3 years):
-- visits, new visits, page views, sign-ups, requests, bookings; unique browsers of the week from visitor_sessions
-- (bots and staff left out, as the daily totals do) while the visits are kept, else null.

create function pg_temp.copy_grants(p_new regprocedure, p_old regprocedure) returns void
language plpgsql as $$
declare g text;
begin
  execute format('revoke all on function %s from public, anon, authenticated', p_new);
  foreach g in array array['anon', 'authenticated', 'service_role'] loop
    if has_function_privilege(g, p_old, 'execute') then execute format('grant execute on function %s to %I', p_new, g); end if;
  end loop;
end $$;

create function app.visitor_weeks(p_by uuid, p jsonb default '{}') returns jsonb
language plpgsql stable security definer set search_path = public, app, pg_temp as $$
declare
  v_weeks integer := least(greatest(coalesce(nullif(p ->> 'weeks', '')::integer, 12), 1), 156);
  v_to date := date_trunc('week', app.today())::date;
  v_from date := v_to - 7 * (v_weeks - 1);
begin
  if not app.user_is_admin(p_by) then raise exception 'Only an Admin reads the visitors' using errcode = '42501'; end if;
  return jsonb_build_object(
    'weeks', coalesce((select jsonb_agg(w order by w ->> 'week_of' desc) from (
      select jsonb_build_object('week_of', g::date, 'in_progress', g::date = v_to,
        'visits', coalesce(sum(d.visits), 0), 'new_visits', coalesce(sum(d.new_visits), 0), 'returning_visits', coalesce(sum(d.returning_visits), 0),
        'unique_browsers', case when g::date + 6 < (select app.local_date(min(started_at)) from visitor_sessions) then null
                             else (select count(distinct s.visitor_id) from visitor_sessions s where s.exclude_reason is null
                                     and s.started_at >= (g::date::timestamp at time zone 'America/Toronto')
                                     and s.started_at < ((g::date + 7)::timestamp at time zone 'America/Toronto')) end,
        'page_views', coalesce(sum(d.page_views), 0), 'signups', coalesce(sum(d.signups), 0), 'requests', coalesce(sum(d.requests), 0),
        'bookings', coalesce(sum(d.bookings), 0), 'contacts', coalesce(sum(d.contacts), 0)) as w
      from generate_series(v_from, v_to, interval '7 days') g
      left join visitor_daily d on d.day between g::date and g::date + 6
      group by g) x), '[]'::jsonb),
    'visits_kept_since', (select app.local_date(min(started_at)) from visitor_sessions),
    'note', 'Weeks start Monday (Toronto). Bots and staff are left out. unique_browsers is null for weeks older than the kept visits; visits and the rest come from the daily totals.');
end $$;
comment on function app.visitor_weeks(uuid, jsonb) is 'R51 (5211, REQ-140): the site''s visitors week by week for the connector, read only, Admin only.';

alter function app.api_call(text, text, jsonb, text) rename to api_call_pre5211;
create function app.api_call(p_hash text, p_tool text, p_args jsonb, p_client text default null) returns jsonb
language plpgsql security definer set search_path = public, app, pg_temp as $$
declare
  a jsonb := case when jsonb_typeof(p_args) = 'object' then p_args else '{}'::jsonb end;
  chk jsonb;
  k api_keys;
  v_result jsonb;
begin
  if p_tool <> 'visitor_weeks' then return app.api_call_pre5211(p_hash, p_tool, p_args, p_client); end if;
  chk := app.api_key_check(p_hash, 'admin:read', p_tool, a, p_client);
  if not (chk ->> 'ok')::boolean then return chk; end if;
  k := jsonb_populate_record(null::api_keys, chk -> 'key');
  perform app.door_begin(k.user_id, 'aal2');
  begin
    v_result := app.visitor_weeks(k.user_id, a);
  exception when others then
    insert into api_calls (key_id, user_id, tool, target, args, ok, error, client) values (k.id, k.user_id, p_tool, p_tool, a, false, left(sqlerrm, 500), left(p_client, 64));
    return jsonb_build_object('ok', false, 'status', case sqlstate when '42501' then 403 else 400 end, 'error', regexp_replace(sqlerrm, '^.*?ERROR:\s*', ''));
  end;
  insert into api_calls (key_id, user_id, tool, target, args, ok, client) values (k.id, k.user_id, p_tool, p_tool, a, true, left(p_client, 64));
  return jsonb_build_object('ok', true, 'result', v_result);
end $$;
select pg_temp.copy_grants('app.api_call(text, text, jsonb, text)'::regprocedure, 'app.api_call_pre5211(text, text, jsonb, text)'::regprocedure);
revoke all on function app.visitor_weeks(uuid, jsonb) from public, anon, authenticated;
revoke all on function app.api_call_pre5211(text, text, jsonb, text) from public, anon, authenticated;
grant execute on function app.visitor_weeks(uuid, jsonb) to service_role;
grant execute on function app.api_call_pre5211(text, text, jsonb, text) to service_role;
