-- 2254: pg_safeupdate refuses an UPDATE without a WHERE clause on the server: the usage switch (1860) and the Meta
-- publishing state (2220) update their one-row tables with an explicit WHERE. Bodies otherwise unchanged.
create or replace function app.usage_cached_check(p_now timestamptz default now()) returns boolean
language plpgsql security definer set search_path = public, app as $$
declare
  ps program_settings := app.settings(app.local_date(p_now));
  m jsonb := app.usage_cached_share(p_now);
  v_on boolean := (m ->> 'share_bps')::int >= ps.usage_cached_pct * 100;
begin
  if v_on and ps.usage_cached_since is null then
    update program_settings set usage_cached_since = p_now where id is not null; -- every dated row of the settings: it is a state, not a setting
    insert into audit_log (actor_user_id, action, entity_table, entity_id, after)
    values (null, 'usage_cached_on', 'program_settings', ps.id::text, jsonb_build_object('usage', m, 'line_pct', ps.usage_cached_pct));
  elsif not v_on and ps.usage_cached_since is not null then
    update program_settings set usage_cached_since = null where id is not null;
    insert into audit_log (actor_user_id, action, entity_table, entity_id, after)
    values (null, 'usage_cached_off', 'program_settings', ps.id::text, jsonb_build_object('usage', m, 'line_pct', ps.usage_cached_pct));
  end if;
  return v_on;
end $$;

create or replace function public.server_social_queue_result(p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare x social_queue;
begin
  select * into x from social_queue where id = nullif(p ->> 'id', '')::uuid and status = 'posting' for update;
  if x.id is null then return jsonb_build_object('ok', false); end if;
  if coalesce((p ->> 'ok')::boolean, false) then
    update social_queue set status = 'posted', how = 'api', post_id = left(p ->> 'post_id', 120),
           post_url = case when (p ->> 'url') ~ '^https://[^[:space:]]+$' then p ->> 'url' end, posted_at = now(), error = null where id = x.id;
    perform app.social_log(x.id, 'posted', coalesce(p ->> 'url', p ->> 'post_id'));
    update meta_publishing set last_ok_at = now(), last_error = null where singleton;
  else
    update social_queue set status = case when x.attempts >= 3 then 'failed' else 'due' end, error = left(coalesce(p ->> 'error', 'Meta refused the post'), 300) where id = x.id;
    perform app.social_log(x.id, case when x.attempts >= 3 then 'failed' else 'retry' end, p ->> 'error');
    update meta_publishing set last_error = left(coalesce(p ->> 'error', 'Meta refused the post'), 300) where singleton;
  end if;
  return jsonb_build_object('ok', true);
end $$;
