-- 5050: field shifts in Google Calendar by subscription (release 50; docs/changes/2026-11-25-r50-shift-feed.md).
-- The owner (Nov 25): "employee shifts should get added to the carmacars admin google calendar automatically ... but also
-- admin is getting absolutely spammed with emails". So no email: a private iCal feed each person subscribes to once.
-- No applied migration is edited.
--   1. shift_feeds: one private feed address per person and scope, a 64-character random token (two random UUIDs),
--      revocable (revoked_at) and regenerable (the old row is revoked, a new token is made). RLS admin_all, audited.
--        all    every field shift (an Admin and Fleet: app.user_runs_fleet): the day, the start and end in Toronto time,
--               who claimed it or "Open", the tasks on it, a link to it on the field jobs board
--        mine   a field staff member's own claimed shifts (app.is_field_person), with the tasks given to them, and a
--               link to My shifts
--   2. app.shift_feed_ics(token): the feed as text/calendar (METHOD:PUBLISH, the Toronto VTIMEZONE and the ICS helpers of
--      5000), from 14 days back to 60 days ahead. A revoked token, a person no longer active or no longer allowed the
--      scope gives null (the route answers 404). public.server_shift_feed is the server's call (service_role only).
--   3. The door: ops_read / admin_read / field_read shift_feed (the person's feeds and the scopes they may have) and
--      ops_do / admin_do / field_do shift_feed_set {scope, action: create | regenerate | revoke}.
set local check_function_bodies = off;

create function pg_temp.copy_grants(p_new regprocedure, p_old regprocedure) returns void
language plpgsql as $$
declare g text;
begin
  execute format('revoke all on function %s from public, anon, authenticated', p_new);
  foreach g in array array['anon', 'authenticated', 'service_role'] loop
    if has_function_privilege(g, p_old, 'execute') then execute format('grant execute on function %s to %I', p_new, g); end if;
  end loop;
end $$;

-- ================================================================ 1. the feeds
create table if not exists shift_feeds (
  id          uuid primary key default gen_random_uuid(),
  user_id     uuid not null references users (id) on delete cascade,
  scope       text not null check (scope in ('all', 'mine')),
  token       text not null unique check (token ~ '^[0-9a-f]{64}$'),
  created_at  timestamptz not null default now(),
  revoked_at  timestamptz,
  revoked_by  uuid references users (id) on delete set null
);
create index if not exists shift_feeds_user on shift_feeds (user_id, scope);
create unique index if not exists shift_feeds_one_live on shift_feeds (user_id, scope) where revoked_at is null;
comment on table shift_feeds is 'Private shift calendar feeds (5050): one live address per person and scope (all: every field shift, for an Admin and Fleet; mine: a field staff member''s own). The token is the secret in the address; a regenerated or turned-off feed keeps its row with revoked_at.';
alter table shift_feeds enable row level security;
revoke all on shift_feeds from public, anon, authenticated;
grant all on shift_feeds to service_role;
drop policy if exists admin_all on shift_feeds;
create policy admin_all on shift_feeds for all to authenticated using (app.is_admin()) with check (app.is_admin());
drop trigger if exists audit_shift_feeds on shift_feeds;
create trigger audit_shift_feeds after insert or update or delete on shift_feeds for each row execute function app.audit_row('redact');

-- the scopes a person may have now
create function app.shift_feed_scopes(p_user uuid) returns text[]
language sql stable security definer set search_path = public, app, pg_temp as $$
  select array_remove(array[case when app.user_runs_fleet(p_user) then 'all' end, case when app.is_field_person(p_user) then 'mine' end], null)
$$;

create function app.shift_feed_token() returns text
language sql volatile set search_path = public, app, pg_temp as $$
  select replace(gen_random_uuid()::text, '-', '') || replace(gen_random_uuid()::text, '-', '')
$$;

-- the person's feeds, for the card (the token is shown to its owner only)
create function app.shift_feed_state(p_by uuid) returns jsonb
language plpgsql stable security definer set search_path = public, app, pg_temp as $$
declare v_scopes text[] := app.shift_feed_scopes(p_by);
begin
  if cardinality(v_scopes) = 0 then raise exception 'Only Admins, Fleet and field staff have a shift calendar' using errcode = '42501'; end if;
  return jsonb_build_object('scopes', to_jsonb(v_scopes), 'feeds', coalesce((
    select jsonb_agg(jsonb_build_object('scope', s.scope, 'token', f.token, 'created_at', f.created_at) order by s.ord)
      from unnest(v_scopes) with ordinality s(scope, ord)
      left join shift_feeds f on f.user_id = p_by and f.scope = s.scope and f.revoked_at is null), '[]'::jsonb));
end $$;

-- p: {scope, action: create | regenerate | revoke}
create function app.shift_feed_set(p_by uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app, pg_temp as $$
declare
  v_scope text := p ->> 'scope';
  v_action text := p ->> 'action';
  v_old shift_feeds;
  v_new shift_feeds;
begin
  if v_scope is null or not (v_scope = any (app.shift_feed_scopes(p_by))) then raise exception 'This shift calendar is not yours to change' using errcode = '42501'; end if;
  if v_action is null or v_action not in ('create', 'regenerate', 'revoke') then raise exception 'Create, regenerate or turn off the link' using errcode = '22023'; end if;
  select * into v_old from shift_feeds where user_id = p_by and scope = v_scope and revoked_at is null for update;
  if v_action = 'create' and v_old.id is not null then return app.shift_feed_state(p_by); end if;
  if v_action = 'revoke' and v_old.id is null then return app.shift_feed_state(p_by); end if;
  if v_old.id is not null then
    update shift_feeds set revoked_at = now(), revoked_by = p_by where id = v_old.id and revoked_at is null;
  end if;
  if v_action in ('create', 'regenerate') then
    insert into shift_feeds (user_id, scope, token) values (p_by, v_scope, app.shift_feed_token()) returning * into v_new;
  end if;
  insert into audit_log (actor_user_id, action, entity_table, entity_id, before, after)
  values (p_by, 'shift_feed_' || v_action, 'shift_feeds', coalesce(v_new.id, v_old.id)::text,
          case when v_old.id is not null then jsonb_build_object('scope', v_scope, 'feed', v_old.id) end,
          case when v_new.id is not null then jsonb_build_object('scope', v_scope, 'feed', v_new.id) end);
  return app.shift_feed_state(p_by);
end $$;

-- ================================================================ 2. the calendar text
create function app.shift_feed_ics(p_token text, p_now timestamptz default now()) returns text
language plpgsql stable security definer set search_path = public, app, pg_temp as $$
declare
  f shift_feeds;
  v_base text := rtrim(coalesce((app.settings()).notify_base_url, 'https://carmacars.ca'), '/');
  v_admin boolean;
  v_from timestamptz := p_now - interval '14 days';
  v_to timestamptz := p_now + interval '60 days';
  l text[];
  e record;
begin
  if p_token is null or p_token !~ '^[0-9a-f]{64}$' then return null; end if;
  select * into f from shift_feeds where token = p_token and revoked_at is null;
  if f.id is null or not exists (select 1 from users u where u.id = f.user_id and u.status = 'active') or not (f.scope = any (app.shift_feed_scopes(f.user_id))) then
    return null;
  end if;
  v_admin := app.user_is_admin(f.user_id);
  l := array['BEGIN:VCALENDAR', 'PRODID:-//CarmaCars//Shifts//EN', 'VERSION:2.0', 'CALSCALE:GREGORIAN', 'METHOD:PUBLISH',
    app.ics_fold('X-WR-CALNAME:' || app.ics_esc(case f.scope when 'all' then 'CarmaCars field shifts' else 'My CarmaCars shifts' end)),
    'X-WR-TIMEZONE:America/Toronto', 'REFRESH-INTERVAL;VALUE=DURATION:PT1H', 'X-PUBLISHED-TTL:PT1H', app.ics_vtimezone()];
  for e in
    select s.id as uid_id, s.starts_at, s.ends_at, s.note, s.capacity,
           greatest(s.updated_at, coalesce(max(pl.updated_at), s.updated_at)) as changed_at,
           string_agg(u.full_name, ', ' order by u.full_name) filter (where pl.id is not null) as names,
           count(pl.id)::integer as taken,
           (select count(*) from field_jobs j where j.shift_slot_id = s.id and j.status <> 'cancelled')::integer as tasks,
           case when v_admin then v_base || '/admin/field-jobs?slot=' || s.id else v_base || '/staff/fleet?slot=' || s.id end as url
      from field_shift_slots s
      left join field_shift_plans pl on pl.slot_id = s.id and pl.cancelled_at is null
      left join users u on u.id = pl.staff_id
     where f.scope = 'all' and s.cancelled_at is null and s.ends_at >= v_from and s.starts_at <= v_to
     group by s.id
    union all
    select pl.id, pl.starts_at, pl.ends_at, coalesce(pl.note, s.note), 1, greatest(pl.updated_at, s.updated_at), null, 1,
           (select count(*) from field_jobs j where j.shift_slot_id = s.id and j.assigned_to = f.user_id and j.status <> 'cancelled')::integer,
           v_base || '/staff/field/shifts'
      from field_shift_plans pl join field_shift_slots s on s.id = pl.slot_id
     where f.scope = 'mine' and pl.staff_id = f.user_id and pl.cancelled_at is null and s.cancelled_at is null
       and pl.ends_at >= v_from and pl.starts_at <= v_to
     order by 2, 1
  loop
    l := l || array['BEGIN:VEVENT', 'UID:shift-' || e.uid_id || '@carmacars.ca', 'DTSTAMP:' || app.ics_utc(p_now), 'LAST-MODIFIED:' || app.ics_utc(e.changed_at),
      'DTSTART;TZID=America/Toronto:' || app.ics_local(e.starts_at), 'DTEND;TZID=America/Toronto:' || app.ics_local(e.ends_at)];
    if f.scope = 'all' then
      l := l || app.ics_fold('SUMMARY:' || app.ics_esc('Field shift: ' || case when e.taken = 0 then 'Open'
                 else e.names || case when e.taken < e.capacity then ' (' || (e.capacity - e.taken) || ' open)' else '' end end));
      l := l || app.ics_fold('DESCRIPTION:' || app.ics_esc(
                 'Claimed by: ' || coalesce(e.names, 'nobody yet (open)') || E'\n'
                 || 'Tasks: ' || e.tasks || E'\n'
                 || coalesce('Note: ' || nullif(btrim(e.note), '') || E'\n', '')
                 || 'Open it: ' || e.url));
      l := l || 'TRANSP:TRANSPARENT'::text;
    else
      l := l || app.ics_fold('SUMMARY:' || app.ics_esc('CarmaCars field shift'));
      l := l || app.ics_fold('DESCRIPTION:' || app.ics_esc(
                 'Tasks given to you: ' || e.tasks || E'\n'
                 || coalesce('Note: ' || nullif(btrim(e.note), '') || E'\n', '')
                 || 'Your shifts: ' || e.url));
      l := l || 'TRANSP:OPAQUE'::text;
    end if;
    l := l || app.ics_fold('URL:' || e.url) || 'STATUS:CONFIRMED'::text || 'END:VEVENT'::text;
  end loop;
  l := l || 'END:VCALENDAR'::text;
  return array_to_string(l, E'\r\n') || E'\r\n';
end $$;

-- the route's call (/api/shift-feed/<token>.ics): the server role only
create function public.server_shift_feed(p_token text) returns text
language sql stable security definer set search_path = public, app, pg_temp as $$ select app.shift_feed_ics(lower(p_token)) $$;
revoke all on function public.server_shift_feed(text) from public, anon, authenticated;
grant execute on function public.server_shift_feed(text) to service_role;

-- ================================================================ 3. the door
alter function app.door(uuid, text, text, text, jsonb) rename to door_pre5050;
create function app.door(p_user uuid, p_aal text, p_call text, p_name text, p jsonb default '{}'::jsonb) returns jsonb
language plpgsql security definer set search_path = public, app, pg_temp as $$
begin
  if p_call in ('ops_read', 'admin_read', 'field_read') and p_name = 'shift_feed' then
    perform app.door_begin(p_user, p_aal);
    return app.shift_feed_state(p_user);
  end if;
  if p_call in ('ops_do', 'admin_do', 'field_do') and p_name = 'shift_feed_set' then
    perform app.door_begin(p_user, p_aal);
    return app.shift_feed_set(p_user, coalesce(p, '{}'::jsonb) - '_va');
  end if;
  return app.door_pre5050(p_user, p_aal, p_call, p_name, p);
end $$;
select pg_temp.copy_grants('app.door(uuid, text, text, text, jsonb)'::regprocedure, 'app.door_pre5050(uuid, text, text, text, jsonb)'::regprocedure);

-- ================================================================ privileges
do $$
declare f record;
begin
  for f in select p.oid::regprocedure as sig from pg_proc p join pg_namespace n on n.oid = p.pronamespace
            where n.nspname = 'app' and p.proname = any (array['shift_feed_scopes', 'shift_feed_token', 'shift_feed_state', 'shift_feed_set', 'shift_feed_ics', 'door_pre5050']) loop
    execute format('revoke all on function %s from public, anon, authenticated', f.sig);
    execute format('grant execute on function %s to service_role', f.sig);
  end loop;
end $$;
