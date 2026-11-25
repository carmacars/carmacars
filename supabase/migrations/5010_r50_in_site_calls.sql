-- 5010: calls inside the site (release 50; docs/changes/2026-11-24-r50-in-site-calls.md). SCHEMA_MARKER 5010.
-- No applied migration is edited.
--   1. Program settings calls_mode: in_site (the default: the weekly townhall and interview calls run on the company's own
--      media server, LiveKit on the VPS) or link (the old outside call link of Program settings, for when the media
--      server is down). An Admin switches it on the Townhall page.
--   2. call_rooms and call_participants: every call (the townhall of a date, an interview slot) and who was in it, when
--      they joined and left and for how long, from the media server's webhook and the page's own heartbeat.
--   3. Townhall attendance is automatic: being in the in-site call records the join and leave times in
--      townhall_attendance (method call, confirmed), so the missed counts and the two-in-a-row lock keep working as is.
--   4. Interviews: a video slot's call is a private room per slot. The candidate's link (in the booking email, in place of
--      the Jitsi link) is single use: call_guest_links keeps only its hash; the first open from a browser binds it to
--      that browser's signed session, any other browser is refused. The interviewer (Admin) joins from the candidate's page.
--   5. The door: call_join (who may join which room, as what), call_live (Admin: who is in now), calls_mode (Admin);
--      the townhall reads say whether the call is in the site. The server's own functions (service role):
--      server_call_event, server_call_guest_peek, server_call_guest_open, server_call_guest_session.
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

-- ================================================================ 1. the setting
alter table program_settings add column if not exists calls_mode text not null default 'in_site' check (calls_mode in ('in_site', 'link'));
comment on column program_settings.calls_mode is 'Calls (5010): in_site, the townhall and interview calls in the site on the company''s media server; link, the outside call link (townhall_call_url) as the fallback.';

create function app.calls_in_site() returns boolean
language sql stable security definer set search_path = public, app, pg_temp as $$ select (app.settings()).calls_mode = 'in_site' $$;

-- ================================================================ 2. rooms and who was in them
create table if not exists call_rooms (
  id             uuid primary key default gen_random_uuid(),
  kind           text not null check (kind in ('townhall', 'interview', 'staff')),
  name           text not null unique check (name ~ '^[a-z0-9-]{6,80}$'),
  title          text not null,
  meeting_at     timestamptz,
  application_id uuid references job_applications (id) on delete set null,
  slot_id        uuid references interview_slots (id) on delete set null,
  created_at     timestamptz not null default now(),
  started_at     timestamptz,
  ended_at       timestamptz
);
comment on table call_rooms is 'Calls in the site (5010): one room per townhall meeting (townhall-YYYYMMDD-HHMM) and per interview slot (iv-<slot>).';
create table if not exists call_participants (
  room_id        uuid not null references call_rooms (id) on delete cascade,
  identity       text not null check (identity ~ '^(u|g)-[0-9a-f-]{36}$'),
  user_id        uuid references users (id) on delete cascade,
  application_id uuid references job_applications (id) on delete cascade,
  name           text not null,
  role           text not null check (role in ('presenter', 'host', 'member', 'guest')),
  joined_at      timestamptz not null,
  last_join_at   timestamptz not null,
  left_at        timestamptz,
  last_seen_at   timestamptz not null,
  seconds        integer not null default 0 check (seconds >= 0),
  joins          integer not null default 1 check (joins >= 1),
  primary key (room_id, identity)
);
comment on table call_participants is 'Calls in the site (5010): each person in a room: the first join, the last join and leave, the time in the call (seconds, closed visits), how many times they joined.';
create table if not exists call_guest_links (
  id             uuid primary key default gen_random_uuid(),
  application_id uuid not null references job_applications (id) on delete cascade,
  slot_id        uuid references interview_slots (id) on delete cascade,
  token_hash     text not null unique check (token_hash ~ '^[0-9a-f]{64}$'),
  created_at     timestamptz not null default now(),
  used_at        timestamptz,
  session_nonce  text check (session_nonce is null or session_nonce ~ '^[A-Za-z0-9_-]{22,64}$'),
  revoked_at     timestamptz
);
create index if not exists call_guest_links_app on call_guest_links (application_id) where revoked_at is null;
comment on table call_guest_links is 'Calls in the site (5010): a candidate''s single-use link to their interview call (only the hash of the token is kept); used_at and the browser session it is bound to.';
do $$
declare t text;
begin
  foreach t in array array['call_rooms', 'call_participants', 'call_guest_links'] loop
    execute format('alter table %I enable row level security', t);
    execute format('revoke all on %I from public, anon, authenticated', t);
    execute format('grant all on %I to service_role', t);
    execute format('drop policy if exists admin_all on %I', t);
    execute format('create policy admin_all on %I for all to authenticated using (app.is_admin()) with check (app.is_admin())', t);
    execute format('drop trigger if exists %I on %I', 'audit_' || t, t);
    execute format('create trigger %I after insert or update or delete on %I for each row execute function app.audit_row()', 'audit_' || t, t);
  end loop;
end $$;

-- the townhall attendance: being in the call counts by itself, with the times
alter table townhall_attendance drop constraint if exists townhall_attendance_method_check;
alter table townhall_attendance add constraint townhall_attendance_method_check check (method in ('join', 'checkin', 'admin', 'call'));
alter table townhall_attendance add column if not exists joined_at timestamptz, add column if not exists left_at timestamptz,
  add column if not exists seconds integer not null default 0 check (seconds >= 0);
comment on column townhall_attendance.joined_at is 'In-site call (5010): the first time the person joined the call.';
comment on column townhall_attendance.left_at is 'In-site call (5010): the last time they left it (null while in).';

-- ================================================================ 3. the rooms
create function app.call_townhall_room(p_meeting timestamptz) returns call_rooms
language plpgsql security definer set search_path = public, app, pg_temp as $$
declare r call_rooms;
begin
  insert into call_rooms (kind, name, title, meeting_at)
  values ('townhall', 'townhall-' || to_char(p_meeting at time zone 'America/Toronto', 'YYYYMMDD-HH24MI'),
          'Townhall, ' || to_char(p_meeting at time zone 'America/Toronto', 'FMDay, FMMonth FMDD'), p_meeting)
  on conflict (name) do update set title = excluded.title
  returning * into r;
  return r;
end $$;

create function app.call_interview_room(a job_applications) returns call_rooms
language plpgsql security definer set search_path = public, app, pg_temp as $$
declare r call_rooms; s interview_slots;
begin
  select * into s from interview_slots where id = a.slot_id;
  if s.id is null then raise exception 'No call is booked' using errcode = '23514'; end if;
  insert into call_rooms (kind, name, title, meeting_at, application_id, slot_id)
  values ('interview', 'iv-' || s.id, 'Interview, ' || a.full_name, s.starts_at, a.id, s.id)
  on conflict (name) do update set application_id = excluded.application_id, title = excluded.title, meeting_at = excluded.meeting_at
  returning * into r;
  return r;
end $$;

-- who may join which room, as what. p: {room: townhall} | {room: interview, application_id}
create function app.call_join(p_by uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app, pg_temp as $$
declare
  v_admin boolean := app.user_is_admin(p_by);
  v_next timestamptz;
  s program_settings := app.settings();
  r call_rooms;
  a job_applications;
  u users;
begin
  select * into u from users where id = p_by;
  if p ->> 'room' = 'townhall' then
    if not (v_admin or app.user_is_staff(p_by) or app.user_is_field(p_by)) then raise exception 'Staff only' using errcode = '42501'; end if;
    v_next := app.townhall_next(now());
    if v_next is null then raise exception 'No townhall is scheduled' using errcode = '23514'; end if;
    -- staff from 15 minutes before; an Admin (the presenter) any time before, to set up
    if not v_admin and now() < v_next - interval '15 minutes' then
      raise exception 'The call opens 15 minutes before the townhall' using errcode = '23514';
    end if;
    if exists (select 1 from townhall_cancellations c where c.meeting_at = v_next) and not v_admin then
      raise exception 'This townhall is cancelled' using errcode = '23514';
    end if;
    r := app.call_townhall_room(v_next);
  elsif p ->> 'room' = 'interview' then
    if not v_admin then raise exception 'Only an Admin runs interview calls' using errcode = '42501'; end if;
    select * into a from job_applications where id = nullif(p ->> 'application_id', '')::uuid;
    if a.id is null then raise exception 'Candidate not found' using errcode = 'P0002'; end if;
    r := app.call_interview_room(a);
  else
    raise exception 'Choose the call' using errcode = '22023';
  end if;
  return jsonb_build_object('in_site', s.calls_mode = 'in_site', 'room', r.name, 'kind', r.kind, 'title', r.title, 'meeting_at', r.meeting_at,
    'identity', 'u-' || p_by, 'name', coalesce(nullif(btrim(u.greeting_name), ''), nullif(btrim(u.full_name), ''), u.email, 'Staff'),
    'role', case when r.kind = 'interview' then 'host' when v_admin then 'presenter' else 'member' end,
    'minutes', case when r.kind = 'townhall' then s.townhall_minutes else 15 end,
    'fallback_url', case when r.kind = 'townhall' then nullif(s.townhall_call_url, '') end);
end $$;

-- ================================================================ 4. joins and leaves (the webhook, the heartbeat)
-- p: {room, identity, event: joined | left | seen, at?}. The server passes only what it checked (the webhook's signature,
-- the signed-in user or the guest's signed session).
create function app.call_event(p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app, pg_temp as $$
declare
  r call_rooms;
  cp call_participants;
  v_at timestamptz := least(coalesce(nullif(p ->> 'at', '')::timestamptz, now()), now());
  v_ev text := p ->> 'event';
  v_id text := p ->> 'identity';
  v_user uuid;
  v_app uuid;
  v_name text;
  v_role text;
begin
  if v_ev not in ('joined', 'left', 'seen') then raise exception 'Unknown call event' using errcode = '22023'; end if;
  if coalesce(v_id, '') !~ '^(u|g)-[0-9a-f-]{36}$' then raise exception 'Unknown participant' using errcode = '22023'; end if;
  select * into r from call_rooms where name = p ->> 'room';
  if r.id is null then return jsonb_build_object('ok', false, 'error', 'no_room'); end if;
  if v_id like 'u-%' then
    v_user := substr(v_id, 3)::uuid;
    if not exists (select 1 from users where id = v_user) then return jsonb_build_object('ok', false, 'error', 'no_user'); end if;
    select coalesce(nullif(btrim(greeting_name), ''), nullif(btrim(full_name), ''), email) into v_name from users where id = v_user;
    v_role := case when r.kind = 'interview' then 'host' when app.user_is_admin(v_user) then 'presenter' else 'member' end;
  else
    v_app := substr(v_id, 3)::uuid;
    if r.application_id is distinct from v_app then return jsonb_build_object('ok', false, 'error', 'not_this_room'); end if;
    select full_name into v_name from job_applications where id = v_app;
    v_role := 'guest';
  end if;
  select * into cp from call_participants where room_id = r.id and identity = v_id for update;
  if cp.room_id is null then
    if v_ev = 'left' then return jsonb_build_object('ok', true, 'noop', true); end if;
    insert into call_participants (room_id, identity, user_id, application_id, name, role, joined_at, last_join_at, last_seen_at)
    values (r.id, v_id, v_user, v_app, coalesce(v_name, 'Guest'), v_role, v_at, v_at, v_at) returning * into cp;
    update call_rooms set started_at = coalesce(started_at, v_at) where id = r.id;
  elsif v_ev in ('joined', 'seen') then
    -- back after a leave: a new visit
    update call_participants set last_seen_at = greatest(last_seen_at, v_at),
           last_join_at = case when left_at is not null then v_at else last_join_at end,
           joins = joins + case when left_at is not null then 1 else 0 end, left_at = null
     where room_id = r.id and identity = v_id returning * into cp;
  elsif cp.left_at is null then
    update call_participants set left_at = v_at, last_seen_at = greatest(last_seen_at, v_at),
           seconds = seconds + greatest(0, extract(epoch from v_at - last_join_at))::int
     where room_id = r.id and identity = v_id returning * into cp;
  end if;
  -- the townhall: the attendance, by itself
  if r.kind = 'townhall' and v_user is not null then
    insert into townhall_attendance (meeting_at, user_id, method, confirmed_at, joined_at, left_at, seconds)
    values (r.meeting_at, v_user, 'call', v_at, cp.joined_at, cp.left_at, cp.seconds)
    on conflict (meeting_at, user_id) do update set confirmed_at = coalesce(townhall_attendance.confirmed_at, excluded.confirmed_at),
      method = case when townhall_attendance.method = 'join' then 'call' else townhall_attendance.method end,
      joined_at = least(coalesce(townhall_attendance.joined_at, excluded.joined_at), excluded.joined_at),
      left_at = excluded.left_at, seconds = excluded.seconds;
    -- a meeting already closed with this person absent: corrected
    update townhall_meetings set absent = array_remove(absent, v_user) where meeting_at = r.meeting_at and v_user = any (absent);
  end if;
  return jsonb_build_object('ok', true, 'in', cp.left_at is null, 'seconds', cp.seconds, 'joins', cp.joins);
end $$;

create function public.server_call_event(p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app, pg_temp as $$ begin return app.call_event(p); end $$;

-- who is in the call now, and who of the team is not (Admin)
create function app.call_live(p_by uuid, p jsonb) returns jsonb
language plpgsql stable security definer set search_path = public, app, pg_temp as $$
declare
  r call_rooms;
begin
  perform app.assert_admin(p_by);
  select * into r from call_rooms where name = p ->> 'room';
  if r.id is null and p ->> 'room' = 'townhall' then
    select * into r from call_rooms where kind = 'townhall' and meeting_at = app.townhall_next(now());
  end if;
  if r.id is null then return jsonb_build_object('room', null, 'in', '[]'::jsonb, 'left', '[]'::jsonb, 'not_joined', '[]'::jsonb); end if;
  return jsonb_build_object('room', r.name, 'kind', r.kind, 'meeting_at', r.meeting_at,
    'in', coalesce((select jsonb_agg(jsonb_build_object('identity', c.identity, 'name', c.name, 'role', c.role, 'since', c.last_join_at, 'joined_at', c.joined_at) order by c.joined_at)
                      from call_participants c where c.room_id = r.id and c.left_at is null), '[]'::jsonb),
    'left', coalesce((select jsonb_agg(jsonb_build_object('identity', c.identity, 'name', c.name, 'joined_at', c.joined_at, 'left_at', c.left_at, 'minutes', round(c.seconds / 60.0)) order by c.left_at)
                        from call_participants c where c.room_id = r.id and c.left_at is not null), '[]'::jsonb),
    'not_joined', case when r.kind = 'townhall' then coalesce((select jsonb_agg(jsonb_build_object('user_id', sp.user_id, 'name', coalesce(nullif(btrim(u.greeting_name), ''), u.full_name, u.email)) order by coalesce(nullif(btrim(u.greeting_name), ''), u.full_name, u.email))
                        from staff_profiles sp join users u on u.id = sp.user_id
                       where app.staff_is_member(sp.user_id) and not exists (select 1 from call_participants c where c.room_id = r.id and c.user_id = sp.user_id)), '[]'::jsonb) else '[]'::jsonb end);
end $$;

-- ================================================================ 5. the candidate's single-use link
create function app.call_token_hash(p_token text) returns text
language sql immutable set search_path = public, app, pg_temp as $$ select encode(sha256(convert_to(coalesce(p_token, ''), 'UTF8')), 'hex') $$;

-- booking or moving a video call: the in-site link in place of the Jitsi one (before the Google Meet trigger, which then
-- leaves it alone); the earlier links of the candidate stop working
create function app.job_application_call_link() returns trigger
language plpgsql security definer set search_path = public, app, pg_temp as $$
declare v_tok text;
begin
  if app.calls_in_site() and new.meet_url like 'https://meet.jit.si/%' then
    v_tok := replace(gen_random_uuid()::text, '-', '') || replace(gen_random_uuid()::text, '-', '');
    update call_guest_links set revoked_at = now() where application_id = new.id and revoked_at is null;
    insert into call_guest_links (application_id, slot_id, token_hash) values (new.id, new.slot_id, app.call_token_hash(v_tok));
    new.meet_url := app.hiring_url('/call/i/' || v_tok);
    new.meet_provider := null;
  elsif tg_op = 'UPDATE' and new.slot_id is null and old.slot_id is not null then
    update call_guest_links set revoked_at = now() where application_id = new.id and revoked_at is null;
  end if;
  return new;
end $$;
drop trigger if exists job_applications_call_link on job_applications;
create trigger job_applications_call_link before insert or update of meet_url, slot_id on job_applications for each row execute function app.job_application_call_link();
-- (job_applications_call_link sorts before job_applications_meet, so it fires first)

-- the call's facts for the candidate's page, without using the link (an email scanner opening it uses nothing)
create function app.call_guest_facts(l call_guest_links) returns jsonb
language sql stable security definer set search_path = public, app, pg_temp as $$
  select jsonb_build_object('first_name', app.hiring_first_name(a.full_name), 'name', a.full_name, 'role_title', r.title,
    'starts_at', s.starts_at, 'ends_at', s.ends_at, 'opens_at', s.starts_at - interval '15 minutes', 'closes_at', s.ends_at + interval '30 minutes',
    'booking_url', app.hiring_url('/careers/book/' || a.token))
    from job_applications a join interview_slots s on s.id = l.slot_id join hiring_roles r on r.id = a.role_id
   where a.id = l.application_id
$$;

create function app.call_guest_check(l call_guest_links) returns text
language sql stable security definer set search_path = public, app, pg_temp as $$
  select case
    when l.id is null then 'not_found'
    when l.revoked_at is not null then 'replaced'
    when a.id is null or a.purged_at is not null or a.status <> 'booked' or a.slot_id is distinct from l.slot_id then 'not_booked'
    when now() < s.starts_at - interval '15 minutes' then 'early'
    when now() > s.ends_at + interval '30 minutes' then 'over'
    else 'open' end
    from (select 1) one left join job_applications a on a.id = l.application_id left join interview_slots s on s.id = l.slot_id
$$;

create function public.server_call_guest_peek(p_token text) returns jsonb
language plpgsql stable security definer set search_path = public, app, pg_temp as $$
declare l call_guest_links;
begin
  select * into l from call_guest_links where token_hash = app.call_token_hash(p_token);
  return jsonb_build_object('state', app.call_guest_check(l), 'used', l.used_at is not null) || coalesce(case when l.id is not null then app.call_guest_facts(l) end, '{}'::jsonb);
end $$;

-- the first open binds the link to this browser's session (p_nonce, kept in its signed cookie); another browser is refused
create function public.server_call_guest_open(p_token text, p_nonce text) returns jsonb
language plpgsql security definer set search_path = public, app, pg_temp as $$
declare
  l call_guest_links;
  v_state text;
begin
  if coalesce(p_nonce, '') !~ '^[A-Za-z0-9_-]{22,64}$' then return jsonb_build_object('ok', false, 'error', 'bad_session'); end if;
  select * into l from call_guest_links where token_hash = app.call_token_hash(p_token) for update;
  v_state := app.call_guest_check(l);
  if v_state <> 'open' then return jsonb_build_object('ok', false, 'error', v_state); end if;
  if l.used_at is not null and l.session_nonce is distinct from p_nonce then return jsonb_build_object('ok', false, 'error', 'used'); end if;
  if l.used_at is null then
    update call_guest_links set used_at = now(), session_nonce = p_nonce where id = l.id returning * into l;
    insert into audit_log (actor_user_id, action, entity_table, entity_id, after)
    values (null, 'call_guest_link_used', 'call_guest_links', l.id::text, jsonb_build_object('application_id', l.application_id, 'slot_id', l.slot_id));
  end if;
  return jsonb_build_object('ok', true, 'link_id', l.id, 'closes_at', (app.call_guest_facts(l) ->> 'closes_at'));
end $$;

-- the guest's session (the signed cookie's link and nonce): the room, the identity, the name
create function public.server_call_guest_session(p_link uuid, p_nonce text) returns jsonb
language plpgsql security definer set search_path = public, app, pg_temp as $$
declare
  l call_guest_links;
  a job_applications;
  r call_rooms;
  v_state text;
begin
  select * into l from call_guest_links where id = p_link;
  v_state := app.call_guest_check(l);
  if l.id is null or l.used_at is null or l.session_nonce is distinct from p_nonce then return jsonb_build_object('ok', false, 'error', 'used'); end if;
  if v_state <> 'open' then return jsonb_build_object('ok', false, 'error', v_state); end if;
  select * into a from job_applications where id = l.application_id;
  r := app.call_interview_room(a);
  return jsonb_build_object('ok', true, 'room', r.name, 'identity', 'g-' || a.id, 'name', a.full_name, 'role', 'guest', 'title', 'Your CarmaCars interview call') || app.call_guest_facts(l);
end $$;

-- ================================================================ 6. the fallback switch (Admin)
create function app.calls_mode_set(p_by uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app, pg_temp as $$
declare v text := p ->> 'mode';
begin
  perform app.assert_admin(p_by);
  if v not in ('in_site', 'link') then raise exception 'Choose in_site or link' using errcode = '22023'; end if;
  if v = 'link' and (app.settings()).townhall_call_url = '' then raise exception 'Set the outside call link first (Program settings, Townhall call link)' using errcode = '23514'; end if;
  update program_settings set calls_mode = v where id = (app.settings()).id;
  insert into audit_log (actor_user_id, action, entity_table, entity_id, after) values (p_by, 'calls_mode', 'program_settings', null, jsonb_build_object('calls_mode', v));
  return jsonb_build_object('calls_mode', v);
end $$;

-- ================================================================ 7. the door
alter function app.door(uuid, text, text, text, jsonb) rename to door_pre5010;
create function app.door(p_user uuid, p_aal text, p_call text, p_name text, p jsonb default '{}'::jsonb) returns jsonb
language plpgsql security definer set search_path = public, app, pg_temp as $$
declare
  p_ jsonb := coalesce(p, '{}'::jsonb) - '_va';
  v jsonb;
begin
  if (p_call in ('ops_read', 'admin_read', 'field_read') and p_name = 'call_join')
     or (p_call = 'admin_read' and p_name = 'call_live')
     or (p_call = 'admin_do' and p_name = 'calls_mode') then
    perform app.door_begin(p_user, p_aal);
    return case p_name when 'call_join' then app.call_join(p_user, p_) when 'call_live' then app.call_live(p_user, p_) else app.calls_mode_set(p_user, p_) end;
  end if;
  v := app.door_pre5010(p_user, p_aal, p_call, p_name, p);
  -- the townhall reads say whether the call is in the site
  if p_name in ('townhall', 'townhall_link') and jsonb_typeof(v) = 'object' then
    v := v || jsonb_build_object('in_site', app.calls_in_site(), 'calls_mode', (app.settings()).calls_mode);
  end if;
  return v;
end $$;
select pg_temp.copy_grants('app.door(uuid, text, text, text, jsonb)'::regprocedure, 'app.door_pre5010(uuid, text, text, text, jsonb)'::regprocedure);

-- ================================================================ privileges
do $$
declare f record;
begin
  for f in select p.oid::regprocedure as sig from pg_proc p join pg_namespace n on n.oid = p.pronamespace
            where (n.nspname = 'app' and p.proname = any (array['calls_in_site', 'call_townhall_room', 'call_interview_room', 'call_join', 'call_event', 'call_live',
                    'call_token_hash', 'job_application_call_link', 'call_guest_facts', 'call_guest_check', 'calls_mode_set', 'door_pre5010']))
               or (n.nspname = 'public' and p.proname = any (array['server_call_event', 'server_call_guest_peek', 'server_call_guest_open', 'server_call_guest_session'])) loop
    execute format('revoke all on function %s from public, anon, authenticated', f.sig);
    execute format('grant execute on function %s to service_role', f.sig);
  end loop;
end $$;
