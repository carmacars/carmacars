-- 1505_r35c_townhall_deck.sql
-- Release 35, part C (item 4): the weekly townhall (Wednesday 1:00 pm Toronto, 1068) as a 30-minute run.
--   * The call link (Program settings townhall_call_url, empty until set; 1062's column is the owner's "townhall_link")
--     is on every staff portal's frame (townhall_link read): Join opens it through the site, which counts the join.
--   * The deck's sections, from the live data of the week, each with its minutes (30 in all): cameras on, new hires,
--     the craziest story of the week (staff submit theirs in the portal, an Admin picks one), the lead funnel (generated,
--     contacted, offers submitted, requested back, closed), social media growth (entered by hand per week and platform:
--     no API), fleet additions and removals week by week, investor progress, owner stats, the top cars by leads, occupancy
--     and revenue, insurer-billed rentals, the leaderboard, platform updates, and every staff member's tile.
--   * A recording link per townhall (an Admin adds it), shown in every portal with the past weeks'.
--   * Attendance: a join through the link counts once the person confirms they are in the call (Confirm), a check-in
--     counts, and an Admin marks anyone present or absent. Staff who miss two townhalls in a row are locked out
--     (staff_profiles.inactive_locked_at with lock_reason 'townhall') until an Admin restores them (Unlock).
-- No applied migration is edited: app.townhall_slides, app.townhall_view, app.job_townhall, app.door_begin and app.door
-- are wrapped; app.staff_access_facts replaced (1068's with the lock's reason).
set local check_function_bodies = off;

create function pg_temp.patch_fn(p_sig regprocedure, p_old text, p_new text) returns void
language plpgsql as $$
declare d text := pg_get_functiondef(p_sig);
begin
  if position(p_old in d) = 0 then raise exception '1505: the text to change was not found in %: %', p_sig, left(p_old, 160); end if;
  execute replace(d, p_old, p_new);
end $$;

-- a 30-minute run
alter table program_settings alter column townhall_minutes set default 30;
update program_settings set townhall_minutes = 30 where townhall_minutes = 45;

alter table townhall_decks add column if not exists recording_url text check (recording_url is null or recording_url ~ '^https://[^\s]+$');
comment on column townhall_decks.recording_url is 'Townhall (1505): the recording of that week''s call, added by an Admin; shown in every staff portal.';

alter table townhall_attendance drop constraint if exists townhall_attendance_method_check;
alter table townhall_attendance add constraint townhall_attendance_method_check check (method in ('join', 'checkin', 'admin'));
alter table townhall_attendance add column if not exists confirmed_at timestamptz, add column if not exists marked_by uuid references users (id);
comment on column townhall_attendance.confirmed_at is 'Townhall (1505): a join through the link counts once the person confirms they are in the call; a check-in or an Admin''s mark counts by itself.';

alter table staff_profiles add column if not exists lock_reason text check (lock_reason is null or lock_reason in ('inactivity', 'townhall'));
comment on column staff_profiles.lock_reason is 'Why inactive_locked_at is set (1505): inactivity (1060) or two townhalls missed in a row; an Admin''s Unlock clears both.';
create function app.staff_lock_reason_clear() returns trigger language plpgsql as $$
begin
  if new.inactive_locked_at is null then new.lock_reason := null; end if;
  return new;
end $$;
drop trigger if exists staff_profiles_lock_reason on staff_profiles;
create trigger staff_profiles_lock_reason before update of inactive_locked_at on staff_profiles for each row execute function app.staff_lock_reason_clear();

create table if not exists townhall_stories (
  id         uuid primary key default gen_random_uuid(),
  user_id    uuid not null references users (id) on delete cascade,
  week_of    date not null check (extract(isodow from week_of) = 1),
  body       text not null check (length(btrim(body)) between 10 and 1500),
  picked_at  timestamptz,
  picked_by  uuid references users (id),
  created_at timestamptz not null default now()
);
comment on table townhall_stories is 'Townhall (1505): the craziest story of the week, submitted by staff in the portal; an Admin picks one per week for the deck.';
create unique index if not exists townhall_stories_one_pick on townhall_stories (week_of) where picked_at is not null;

create table if not exists townhall_social (
  week_of    date not null check (extract(isodow from week_of) = 1),
  platform   text not null check (platform in ('instagram', 'tiktok', 'facebook', 'youtube', 'google', 'x', 'linkedin')),
  followers  integer check (followers >= 0),
  posts      integer check (posts >= 0),
  views      integer check (views >= 0),
  entered_by uuid references users (id),
  entered_at timestamptz not null default now(),
  primary key (week_of, platform)
);
comment on table townhall_social is 'Townhall (1505): social media figures per week and platform, entered by hand (no API); the deck shows the growth on the week before.';

do $$
declare t text;
begin
  foreach t in array array['townhall_stories', 'townhall_social'] loop
    execute format('alter table %I enable row level security', t);
    execute format('revoke all on %I from anon, authenticated', t);
    execute format('grant all on %I to service_role', t);
    execute format('create policy admin_all on %I for select to authenticated using (app.is_admin())', t);
    execute format('drop trigger if exists %I on %I', 'audit_' || t, t);
    execute format('create trigger %I after insert or update or delete on %I for each row execute function app.audit_row()', 'audit_' || t, t);
  end loop;
end $$;

-- ================================================================ attendance
create function app.townhall_attended(p_meeting timestamptz, p_user uuid) returns boolean
language sql stable security definer set search_path = public, app as $$
  select exists (select 1 from townhall_attendance a where a.meeting_at = p_meeting and a.user_id = p_user and (a.method <> 'join' or a.confirmed_at is not null))
$$;

-- the absences of a meeting count only confirmed joins, check-ins and an Admin's marks
select pg_temp.patch_fn('app.job_townhall(timestamptz)'::regprocedure,
  'and not exists (select 1 from townhall_attendance a where a.meeting_at = v_last and a.user_id = sp.user_id));',
  'and not app.townhall_attended(v_last, sp.user_id));');

-- two townhalls missed in a row: locked until an Admin restores the person (not again for the same two meetings)
create function app.townhall_lockouts(p_now timestamptz default now()) returns integer
language plpgsql security definer set search_path = public, app as $$
declare
  m1 townhall_meetings; m0 townhall_meetings;
  r record;
  n integer := 0;
begin
  select * into m1 from townhall_meetings order by meeting_at desc limit 1;
  select * into m0 from townhall_meetings where meeting_at < m1.meeting_at order by meeting_at desc limit 1;
  if m1.meeting_at is null or m0.meeting_at is null then return 0; end if;
  for r in select sp.user_id from staff_profiles sp
            where sp.user_id = any (m1.absent) and sp.user_id = any (m0.absent) and sp.inactive_locked_at is null and app.staff_is_member(sp.user_id)
              and coalesce(sp.inactive_unlocked_at, '-infinity'::timestamptz) < m1.meeting_at loop
    update staff_profiles set inactive_locked_at = p_now, lock_reason = 'townhall' where user_id = r.user_id;
    insert into audit_log (actor_user_id, action, entity_table, entity_id, after)
    values (null, 'staff_locked_townhall', 'staff_profiles', r.user_id::text, jsonb_build_object('meetings', jsonb_build_array(m0.meeting_at, m1.meeting_at)));
    perform app.staff_alert('townhall_absent', 'user', r.user_id, 'locked:' || r.user_id || ':' || to_char(m1.meeting_at, 'YYYYMMDDHH24MI'),
      (select coalesce(nullif(btrim(u.greeting_name), ''), u.full_name, u.email) from users u where u.id = r.user_id) || ' is locked out: two townhalls missed in a row',
      'Unlock them on the staff list once you have spoken to them.', jsonb_build_object('path_admin', '/admin/settings/staff'));
    n := n + 1;
  end loop;
  return n;
end $$;

alter function app.job_townhall(timestamptz) rename to job_townhall_pre1505;
create function app.job_townhall(p_now timestamptz default now()) returns text
language plpgsql security definer set search_path = public, app as $$
declare v text := app.job_townhall_pre1505(p_now);
begin
  return v || format(', %s locked out', app.townhall_lockouts(p_now));
end $$;

-- the message of a locked account says why
alter function app.door_begin(uuid, text) rename to door_begin_pre1505;
create function app.door_begin(p_user uuid, p_aal text) returns void
language plpgsql security definer set search_path = public, app as $$
begin
  if p_user is not null and app.inactive_locked(p_user)
     and exists (select 1 from staff_profiles sp where sp.user_id = p_user and sp.lock_reason = 'townhall') then
    raise exception 'Your account is locked: you missed two townhalls in a row. Ask an Admin to restore it.' using errcode = '42501';
  end if;
  perform app.door_begin_pre1505(p_user, p_aal);
end $$;

do $$
declare g text;
begin
  execute 'revoke all on function app.door_begin(uuid, text) from public, anon, authenticated';
  foreach g in array array['anon', 'authenticated', 'service_role'] loop
    if has_function_privilege(g, 'app.door_begin_pre1505(uuid, text)', 'execute') then execute format('grant execute on function app.door_begin(uuid, text) to %I', g); end if;
  end loop;
end $$;

-- p: {method: join | checkin | confirm}: a join waits for Confirm; a check-in or Confirm counts
create function app.townhall_attend_1505(p_by uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  v_next timestamptz := app.townhall_next(now());
  v_m text := coalesce(p ->> 'method', 'checkin');
begin
  if not (app.user_is_admin(p_by) or app.user_is_staff(p_by) or app.user_is_field(p_by)) then raise exception 'Staff only' using errcode = '42501'; end if;
  if v_next is null or now() < v_next - interval '15 minutes' then raise exception 'Check-in opens 15 minutes before the townhall' using errcode = '23514'; end if;
  if v_m = 'join' then
    insert into townhall_attendance (meeting_at, user_id, method) values (v_next, p_by, 'join') on conflict do nothing;
  else
    insert into townhall_attendance (meeting_at, user_id, method, confirmed_at) values (v_next, p_by, 'checkin', now())
    on conflict (meeting_at, user_id) do update set confirmed_at = coalesce(townhall_attendance.confirmed_at, now());
  end if;
  return jsonb_build_object('ok', true, 'meeting_at', v_next, 'call_url', nullif((app.settings()).townhall_call_url, ''), 'counted', app.townhall_attended(v_next, p_by));
end $$;

-- An Admin marks a person present or absent for a meeting (default the latest or the one now); a meeting already closed
-- has its absences corrected. p: {user_id, present, meeting_at}
create function app.townhall_mark(p_by uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  v_user uuid := nullif(p ->> 'user_id', '')::uuid;
  v_at timestamptz := coalesce(nullif(p ->> 'meeting_at', '')::timestamptz,
                               (select m from (select app.townhall_next(now()) m) x where m <= now() + interval '15 minutes'),
                               (select max(meeting_at) from townhall_meetings));
  v_present boolean := coalesce((p ->> 'present')::boolean, true);
begin
  perform app.assert_admin(p_by);
  if v_at is null then raise exception 'There is no townhall to mark yet' using errcode = '23514'; end if;
  if not exists (select 1 from staff_profiles sp where sp.user_id = v_user) then raise exception 'Choose the staff member' using errcode = '22023'; end if;
  if v_present then
    insert into townhall_attendance (meeting_at, user_id, method, confirmed_at, marked_by) values (v_at, v_user, 'admin', now(), p_by)
    on conflict (meeting_at, user_id) do update set confirmed_at = coalesce(townhall_attendance.confirmed_at, now()), marked_by = p_by;
    update townhall_meetings set absent = array_remove(absent, v_user) where meeting_at = v_at;
  else
    delete from townhall_attendance where meeting_at = v_at and user_id = v_user;
    update townhall_meetings set absent = case when v_user = any (absent) then absent else absent || v_user end where meeting_at = v_at;
  end if;
  insert into audit_log (actor_user_id, action, entity_table, entity_id, after)
  values (p_by, 'townhall_mark', 'townhall_attendance', v_user::text, jsonb_build_object('meeting_at', v_at, 'present', v_present));
  return jsonb_build_object('meeting_at', v_at, 'user_id', v_user, 'present', v_present);
end $$;

-- ================================================================ stories, social figures, the recording
create function app.townhall_story(p_by uuid, p_action text, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  v_week date := (date_trunc('week', app.today()::timestamp))::date;
  v_id uuid;
begin
  if p_action = 'townhall_story_submit' then
    if not (app.user_is_admin(p_by) or app.user_is_staff(p_by) or app.user_is_field(p_by)) then raise exception 'Staff only' using errcode = '42501'; end if;
    if length(btrim(coalesce(p ->> 'body', ''))) < 10 then raise exception 'Tell the story in a few sentences' using errcode = '22023'; end if;
    if (select count(*) from townhall_stories where user_id = p_by and week_of = v_week) >= 3 then raise exception 'Three stories a week at most' using errcode = '23514'; end if;
    insert into townhall_stories (user_id, week_of, body) values (p_by, v_week, left(btrim(p ->> 'body'), 1500)) returning id into v_id;
  else
    perform app.assert_admin(p_by);
    select week_of into v_week from townhall_stories where id = nullif(p ->> 'id', '')::uuid;
    if v_week is null then raise exception 'Story not found' using errcode = 'P0002'; end if;
    update townhall_stories set picked_at = null, picked_by = null where week_of = v_week and picked_at is not null;
    update townhall_stories set picked_at = now(), picked_by = p_by where id = (p ->> 'id')::uuid returning id into v_id;
  end if;
  return jsonb_build_object('id', v_id);
end $$;

-- p: {week_of (a Monday; default this week), platform, followers, posts, views}
create function app.townhall_social_save(p_by uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare v_week date := (date_trunc('week', coalesce(nullif(p ->> 'week_of', '')::date, app.today())::timestamp))::date;
begin
  perform app.assert_admin(p_by);
  if coalesce(p ->> 'platform', '') not in ('instagram', 'tiktok', 'facebook', 'youtube', 'google', 'x', 'linkedin') then raise exception 'Choose the platform' using errcode = '22023'; end if;
  insert into townhall_social (week_of, platform, followers, posts, views, entered_by)
  values (v_week, p ->> 'platform', nullif(p ->> 'followers', '')::int, nullif(p ->> 'posts', '')::int, nullif(p ->> 'views', '')::int, p_by)
  on conflict (week_of, platform) do update set followers = excluded.followers, posts = excluded.posts, views = excluded.views, entered_by = p_by, entered_at = now();
  return jsonb_build_object('week_of', v_week, 'platform', p ->> 'platform');
end $$;

create function app.townhall_recording(p_by uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare v_id uuid; v_url text := nullif(btrim(coalesce(p ->> 'url', '')), '');
begin
  perform app.assert_admin(p_by);
  if v_url is not null and v_url !~ '^https://[^\s]+$' then raise exception 'The recording link starts with https://' using errcode = '22023'; end if;
  update townhall_decks set recording_url = v_url where id = nullif(p ->> 'deck', '')::uuid returning id into v_id;
  if v_id is null then raise exception 'Deck not found' using errcode = 'P0002'; end if;
  return jsonb_build_object('id', v_id, 'recording_url', v_url);
end $$;

-- the social slide's figures of a week (and the growth on the week before), live
create function app.townhall_social_points(p_week date) returns jsonb
language sql stable security definer set search_path = public, app as $$
  select coalesce(jsonb_agg(app.th_point(initcap(s.platform),
           coalesce(s.followers::text || ' followers', '') || case when s.followers is not null and o.followers is not null then ' (' || case when s.followers >= o.followers then '+' else '' end || (s.followers - o.followers) || ')' else '' end
           || coalesce(', ' || s.posts || ' posts', '') || coalesce(', ' || s.views || ' views', '')) order by s.platform), '[]'::jsonb)
    from townhall_social s left join townhall_social o on o.platform = s.platform and o.week_of = s.week_of - 7
   where s.week_of = p_week
$$;

-- ================================================================ the deck: the 30-minute run
create function app.townhall_slides_1505(p_week date) returns jsonb
language plpgsql stable security definer set search_path = public, app as $$
declare
  a timestamptz := p_week::timestamp at time zone 'America/Toronto';
  z timestamptz := (p_week + 7)::timestamp at time zone 'America/Toronto';
  v_old jsonb := app.townhall_slides_pre1505(p_week);
  v_hires jsonb; v_fleet jsonb; v_top jsonb; v_rev jsonb; v_board jsonb;
  n_gen integer; n_contact integer; n_off integer; n_req integer; n_closed integer;
  n_inv integer; n_inv_new integer; v_committed bigint; n_own integer; n_own_new integer; n_apps integer; n_cars integer;
  n_ins integer; n_ins_on integer; v_ins_days numeric;
begin
  select coalesce(jsonb_agg(coalesce(nullif(btrim(u.greeting_name), ''), u.full_name, u.email) || ', ' ||
           coalesce(array_to_string(array(select case f when 'cs' then 'customer service' when 'fleet' then 'Fleet' when 'finance' then 'Finance' when 'sales' then 'Sales' else 'field' end
                                             from unnest(sp.functions) f), ', '), 'staff') order by sp.created_at), '[]'::jsonb) into v_hires
    from staff_profiles sp join users u on u.id = sp.user_id
   where coalesce(sp.started_on::timestamp at time zone 'America/Toronto', sp.created_at) >= a and coalesce(sp.started_on::timestamp at time zone 'America/Toronto', sp.created_at) < z
     and not app.staff_is_test(sp.user_id);
  select count(*) into n_gen from leads l where l.created_at >= a and l.created_at < z and l.kind not like 'owner%';
  select count(*) into n_contact from leads l where l.first_contact_at >= a and l.first_contact_at < z and l.kind not like 'owner%';
  select count(*) into n_off from booking_events e where e.kind = 'offer_sent' and e.created_at >= a and e.created_at < z;
  select count(*) into n_req from bookings b where b.created_at >= a and b.created_at < z and not coalesce(b.is_placeholder, false) and b.booking_type <> 'owner';
  select count(*) into n_closed from bookings b where b.confirmed_at >= a and b.confirmed_at < z and not coalesce(b.is_placeholder, false) and b.booking_type <> 'owner';
  -- fleet: the last four weeks, added and removed
  select coalesce(jsonb_agg(format('Week of %s: %s added, %s removed', to_char(w, 'FMMon FMDD'),
           (select count(*) from vehicles v where not coalesce(v.is_sample, false) and v.created_at >= w::timestamp at time zone 'America/Toronto' and v.created_at < (w + 7)::timestamp at time zone 'America/Toronto'),
           (select count(*) from vehicles v where not coalesce(v.is_sample, false) and v.retired_at >= w::timestamp at time zone 'America/Toronto' and v.retired_at < (w + 7)::timestamp at time zone 'America/Toronto'))
           order by w), '[]'::jsonb) into v_fleet
    from (select p_week - 7 * k w from generate_series(0, 3) k) x;
  select count(*) filter (where i.status = 'active'), count(*) filter (where i.created_at >= a and i.created_at < z), coalesce(sum(i.committed_amount_cents) filter (where i.status = 'active'), 0)
    into n_inv, n_inv_new, v_committed from investors i;
  select count(distinct v.owner_id) into n_own from vehicles v where v.retired_at is null and not coalesce(v.is_sample, false);
  select count(*) into n_own_new from owners o where o.created_at >= a and o.created_at < z;
  select count(*) into n_apps from owner_applications o where o.created_at >= a and o.created_at < z;
  select count(*) into n_cars from vehicles v where v.retired_at is null and not coalesce(v.is_sample, false) and v.status not in ('exited', 'total_loss', 'declined');
  -- the top cars: requests (leads), days on rent in the week (occupancy), the rental charge of the bookings confirmed
  select coalesce(jsonb_agg(x.line order by x.o), '[]'::jsonb) into v_top from (
    select 1 o, 'Most requested: ' || coalesce(string_agg(t.name || ' (' || t.n || ')', ', ' order by t.n desc, t.name), 'none') line
      from (select app.vehicle_name(b.vehicle_id) name, count(*) n from bookings b where b.created_at >= a and b.created_at < z and b.vehicle_id is not null
              and not coalesce(b.is_placeholder, false) and b.booking_type <> 'owner' group by b.vehicle_id order by 2 desc limit 3) t
    union all
    select 2, 'Busiest: ' || coalesce(string_agg(t.name || ' (' || t.pct || '%)', ', ' order by t.pct desc, t.name), 'none')
      from (select app.vehicle_name(b.vehicle_id) name, least(100, round(100 * sum(extract(epoch from (least(coalesce(b.checked_in_at, b.return_at), z) - greatest(coalesce(b.handed_over_at, b.pickup_at), a))) / 86400.0) / 7))::int pct
              from bookings b where b.status in ('on_rent', 'returned', 'closed') and coalesce(b.handed_over_at, b.pickup_at) < z and coalesce(b.checked_in_at, b.return_at) > a
             group by b.vehicle_id order by 2 desc limit 3) t) x;
  select coalesce(jsonb_agg(app.th_point(t.name, app.fmt_money(t.c)) order by t.c desc), '[]'::jsonb) into v_rev
    from (select app.vehicle_name(b.vehicle_id) name, sum(b.rental_charge_cents) c from bookings b where b.confirmed_at >= a and b.confirmed_at < z and b.booking_type <> 'owner'
           group by b.vehicle_id order by 2 desc limit 3) t;
  select count(*) filter (where coalesce(b.handed_over_at, b.pickup_at) >= a and coalesce(b.handed_over_at, b.pickup_at) < z), count(*) filter (where b.status = 'on_rent'),
         coalesce(sum(extract(epoch from (least(coalesce(b.checked_in_at, b.return_at), z) - greatest(coalesce(b.handed_over_at, b.pickup_at), a))) / 86400.0)
                  filter (where coalesce(b.handed_over_at, b.pickup_at) < z and coalesce(b.checked_in_at, b.return_at) > a and b.status in ('on_rent', 'returned', 'closed')), 0)
    into n_ins, n_ins_on, v_ins_days
    from bookings b where b.bill_to in ('insurer', 'split');
  select coalesce((select s -> 'board' from jsonb_array_elements(v_old) s where s ->> 'key' = 'sales'), '[]'::jsonb) into v_board;
  return jsonb_build_array(
    jsonb_build_object('key', 'opener', 'title', 'Cameras on', 'admin_only', false, 'minutes', 1, 'points', '[]'::jsonb,
      'lines', jsonb_build_array('Cameras on, everyone: say hello.', 'Thirty minutes, every section on time.')),
    jsonb_build_object('key', 'hires', 'title', 'New this week', 'admin_only', false, 'minutes', 2, 'points', jsonb_build_array(app.th_point('New hires', jsonb_array_length(v_hires)::text)),
      'lines', case when jsonb_array_length(v_hires) > 0 then v_hires else '["Nobody new this week."]'::jsonb end),
    jsonb_build_object('key', 'story', 'title', 'Craziest story of the week', 'admin_only', false, 'minutes', 3, 'points', '[]'::jsonb, 'lines', '[]'::jsonb),
    jsonb_build_object('key', 'funnel', 'title', 'Lead funnel', 'admin_only', false, 'minutes', 3, 'points', jsonb_build_array(
      app.th_point('Leads generated', n_gen::text), app.th_point('Contacted', n_contact::text), app.th_point('Offers submitted', n_off::text),
      app.th_point('Requested back', n_req::text), app.th_point('Closed', n_closed::text))),
    jsonb_build_object('key', 'social', 'title', 'Social media growth', 'admin_only', false, 'minutes', 2, 'points', '[]'::jsonb),
    jsonb_build_object('key', 'fleet', 'title', 'Fleet, week by week', 'admin_only', false, 'minutes', 3, 'points', jsonb_build_array(app.th_point('Cars in the fleet', n_cars::text)), 'lines', v_fleet),
    jsonb_build_object('key', 'investors', 'title', 'Investor progress', 'admin_only', false, 'minutes', 2, 'points', jsonb_build_array(
      app.th_point('Investors', n_inv::text), app.th_point('New this week', n_inv_new::text))),
    jsonb_build_object('key', 'investmoney', 'title', 'Investor money', 'admin_only', true, 'minutes', 0, 'points', jsonb_build_array(app.th_point('Committed (active investors)', app.fmt_money(v_committed)))),
    jsonb_build_object('key', 'owners', 'title', 'Owners', 'admin_only', false, 'minutes', 2, 'points', jsonb_build_array(
      app.th_point('Owners with cars', n_own::text), app.th_point('New owners', n_own_new::text), app.th_point('Owner applications', n_apps::text))),
    jsonb_build_object('key', 'topcars', 'title', 'Top cars', 'admin_only', false, 'minutes', 3, 'points', '[]'::jsonb, 'lines', v_top),
    jsonb_build_object('key', 'toprevenue', 'title', 'Top cars by revenue', 'admin_only', true, 'minutes', 0, 'points', v_rev),
    jsonb_build_object('key', 'insurer', 'title', 'Insurer-billed rentals', 'admin_only', false, 'minutes', 2, 'points', jsonb_build_array(
      app.th_point('Started this week', n_ins::text), app.th_point('On rent now', n_ins_on::text), app.th_point('Days on rent this week', round(v_ins_days)::text))),
    jsonb_build_object('key', 'leaderboard', 'title', 'Leaderboard', 'admin_only', false, 'minutes', 2, 'points', '[]'::jsonb, 'board', v_board),
    jsonb_build_object('key', 'dev', 'title', 'Platform updates', 'admin_only', false, 'minutes', 1, 'points', '[]'::jsonb),
    jsonb_build_object('key', 'people', 'title', 'The team this week', 'admin_only', false, 'minutes', 4, 'points', '[]'::jsonb, 'people', app.townhall_people(p_week)));
end $$;

alter function app.townhall_slides(date) rename to townhall_slides_pre1505;
create function app.townhall_slides(p_week date) returns jsonb
language sql stable security definer set search_path = public, app as $$ select app.townhall_slides_1505(p_week) $$;

-- the view: the story picked and the social figures live on their slides; the stories, the recording, the join to
-- confirm, the people to mark (Admin)
alter function app.townhall_view(uuid, jsonb) rename to townhall_view_pre1505;
create function app.townhall_view(p_by uuid, p jsonb) returns jsonb
language plpgsql stable security definer set search_path = public, app as $$
declare
  v jsonb := app.townhall_view_pre1505(p_by, p);
  v_admin boolean := app.user_is_admin(p_by);
  v_week date := nullif(v #>> '{deck,week_of}', '')::date;
  v_story text;
  v_next timestamptz := app.townhall_next(now());
  v_this date := (date_trunc('week', app.today()::timestamp))::date;
begin
  if v_week is not null then
    -- the story of the deck's week is the one picked in the week after it (the week of the call)
    select coalesce(nullif(btrim(u.greeting_name), ''), u.full_name) || ': ' || s.body into v_story
      from townhall_stories s join users u on u.id = s.user_id where s.week_of in (v_week, v_week + 7) and s.picked_at is not null order by s.week_of desc limit 1;
    v := jsonb_set(v, '{deck,slides}', coalesce((select jsonb_agg(case s ->> 'key'
             when 'story' then s || jsonb_build_object('lines', case when v_story is not null then jsonb_build_array(v_story) else '["No story picked yet: submit yours on the Townhall page."]'::jsonb end)
             when 'social' then s || jsonb_build_object('points', app.townhall_social_points(v_week), 'lines', case when jsonb_array_length(app.townhall_social_points(v_week)) = 0 then '["No figures entered for this week."]'::jsonb else '[]'::jsonb end)
             else s end order by o) from jsonb_array_elements(v #> '{deck,slides}') with ordinality t(s, o)), '[]'::jsonb));
    v := jsonb_set(v, '{deck,recording_url}', coalesce(to_jsonb((select d.recording_url from townhall_decks d where d.week_of = v_week)), 'null'::jsonb));
  end if;
  return v || jsonb_build_object(
    'checked_in', v_next is not null and app.townhall_attended(v_next, p_by),
    'joined_unconfirmed', v_next is not null and exists (select 1 from townhall_attendance a where a.meeting_at = v_next and a.user_id = p_by and a.method = 'join' and a.confirmed_at is null),
    'run_minutes', coalesce((select sum(coalesce((s ->> 'minutes')::int, 0)) from jsonb_array_elements(v #> '{deck,slides}') s), 0),
    'recordings', coalesce((select jsonb_agg(jsonb_build_object('week_of', d.week_of, 'url', d.recording_url) order by d.week_of desc)
                              from (select * from townhall_decks where recording_url is not null order by week_of desc limit 12) d), '[]'::jsonb),
    'my_stories', coalesce((select jsonb_agg(jsonb_build_object('id', s.id, 'body', s.body, 'picked', s.picked_at is not null, 'week_of', s.week_of) order by s.created_at desc)
                              from townhall_stories s where s.user_id = p_by and s.week_of >= v_this - 7), '[]'::jsonb),
    'stories', case when v_admin then coalesce((select jsonb_agg(jsonb_build_object('id', s.id, 'name', coalesce(nullif(btrim(u.greeting_name), ''), u.full_name, u.email), 'body', s.body,
                              'picked', s.picked_at is not null, 'week_of', s.week_of) order by s.picked_at nulls last, s.created_at desc)
                              from townhall_stories s join users u on u.id = s.user_id where s.week_of >= v_this - 7), '[]'::jsonb) end,
    'social', case when v_admin then coalesce((select jsonb_agg(to_jsonb(x) order by x.week_of desc, x.platform) from (select * from townhall_social where week_of >= v_this - 21) x), '[]'::jsonb) end,
    'mark', case when v_admin then jsonb_build_object('meeting_at', coalesce((select m from (select app.townhall_next(now()) m) x where m <= now() + interval '15 minutes'), (select max(meeting_at) from townhall_meetings)),
        'people', coalesce((select jsonb_agg(jsonb_build_object('user_id', sp.user_id, 'name', coalesce(nullif(btrim(u.greeting_name), ''), u.full_name, u.email),
            'present', app.townhall_attended(coalesce((select m from (select app.townhall_next(now()) m) x where m <= now() + interval '15 minutes'), (select max(meeting_at) from townhall_meetings)), sp.user_id),
            'locked', sp.lock_reason = 'townhall') order by coalesce(nullif(btrim(u.greeting_name), ''), u.full_name, u.email))
          from staff_profiles sp join users u on u.id = sp.user_id where app.staff_is_member(sp.user_id) or sp.lock_reason = 'townhall'), '[]'::jsonb)) end);
end $$;

-- the frame of every staff portal: the call link and the next call
create function app.townhall_link(p_by uuid) returns jsonb
language sql stable security definer set search_path = public, app as $$
  select jsonb_build_object('has_link', (app.settings()).townhall_call_url <> '', 'next_at', app.townhall_next(now()), 'minutes', (app.settings()).townhall_minutes,
    'live', app.townhall_next(now()) <= now() + interval '15 minutes')
$$;

-- the staff list: townhalls missed and why an account is locked
create or replace function app.staff_access_facts(p_by uuid, p jsonb) returns jsonb
language plpgsql stable security definer set search_path = public, app as $$
begin
  perform app.assert_admin(p_by);
  return coalesce((select jsonb_object_agg(sp.user_id::text, jsonb_build_object('last_sign_in_at', u.last_sign_in_at, 'last_active_at', app.staff_last_active(sp),
           'locked_at', sp.inactive_locked_at, 'lock_reason', case when sp.inactive_locked_at is not null then coalesce(sp.lock_reason, 'inactivity') end,
           'preferred_name', nullif(btrim(u.greeting_name), ''), 'location', nullif(concat_ws(', ', sp.location_city, sp.location_country), ''),
           'townhalls_missed', (select count(*) from townhall_meetings m where sp.user_id = any (m.absent) and m.meeting_at > now() - interval '56 days')))
    from staff_profiles sp join users u on u.id = sp.user_id), '{}'::jsonb);
end $$;

alter function app.door(uuid, text, text, text, jsonb) rename to door_pre1505;
create function app.door(p_user uuid, p_aal text, p_call text, p_name text, p jsonb default '{}'::jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare p_ jsonb := coalesce(p, '{}'::jsonb) - '_va';
begin
  if (p_call = 'ops_do' and p_name in ('townhall_attend', 'townhall_story_submit'))
     or (p_call in ('ops_do', 'admin_do') and p_name in ('townhall_mark', 'townhall_story_pick', 'townhall_social_save', 'townhall_recording'))
     or (p_call in ('ops_read', 'admin_read', 'field_read') and p_name = 'townhall_link') then
    perform app.door_begin(p_user, p_aal);
    return case p_name when 'townhall_attend' then app.townhall_attend_1505(p_user, p_)
                       when 'townhall_mark' then app.townhall_mark(p_user, p_)
                       when 'townhall_social_save' then app.townhall_social_save(p_user, p_)
                       when 'townhall_recording' then app.townhall_recording(p_user, p_)
                       when 'townhall_link' then app.townhall_link(p_user)
                       else app.townhall_story(p_user, p_name, p_) end;
  end if;
  return app.door_pre1505(p_user, p_aal, p_call, p_name, p);
end $$;

do $$
declare f record;
begin
  for f in select p.oid::regprocedure as sig from pg_proc p join pg_namespace n on n.oid = p.pronamespace
            where n.nspname = 'app' and p.proname = any (array['townhall_attended', 'townhall_lockouts', 'job_townhall_pre1505', 'job_townhall',
                    'townhall_attend_1505', 'townhall_mark', 'townhall_story', 'townhall_social_save', 'townhall_recording', 'townhall_social_points', 'townhall_slides_1505',
                    'townhall_slides_pre1505', 'townhall_slides', 'townhall_view_pre1505', 'townhall_view', 'townhall_link', 'door_pre1505', 'door'])
  loop
    execute format('revoke all on function %s from public, anon, authenticated', f.sig);
    execute format('grant execute on function %s to service_role', f.sig);
  end loop;
end $$;
