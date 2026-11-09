-- 1068_r35k_field_calls_townhall_people.sql
-- Release 35, part K (items 15, 16 and 6; docs/changes/2026-11-09-r35-townhall-field-calls.md).
--   1. Field hiring (the owner's final rules, 15): a field applicant who passes screening and the AI interview (its pass
--      mark, no "decline") is invited to a live call with the booking link of 0173, which offers the call times of the
--      hour before the weekly townhall: six 10-minute slots, opened by themselves each week (app.townhall_field_slots).
--      Admin sees them on Hiring (days and calls); Fleet sees them on its Field jobs page (ops_read field_call_slots).
--   2. The townhall (16): its day is the least busy day of the week (the fewest pickups, returns and field jobs over the
--      last 8 weeks and the next 2 weeks booked, Monday to Saturday), recomputed every Sunday; a new day takes effect only
--      after 7 days' notice to every staff member. Every active staff member is reminded an hour before; attendance is a
--      join (the call link through the site) or a check-in; absences show on the staff list and the Admins are alerted to
--      the no-shows once the call is over. Every staff member has a tile on the deck: name, role, the week's numbers (Sales:
--      offers and bookings; customer service: replies and the average reply time; Fleet and field: jobs done; Finance:
--      deposits released) and a shout-out an Admin writes.
--   3. The live map (6): the bookings confirmed in the last 15 minutes ride on the figures' layer, so the map plays a short
--      celebration and a toast with the car and the Sales credit.
-- No applied migration is edited; this part's own functions of 1060 to 1064 are replaced.
set local check_function_bodies = off;

alter table program_settings
  add column if not exists townhall_auto_day boolean not null default true,
  add column if not exists townhall_next_weekday integer check (townhall_next_weekday between 1 and 7),
  add column if not exists townhall_next_from date;
comment on column program_settings.townhall_auto_day is 'Townhall (1068): the day follows the least busy day of the week, recomputed every Sunday, with 7 days'' notice.';
comment on column program_settings.townhall_next_from is 'Townhall (1068): the date from which townhall_next_weekday replaces townhall_weekday (staff were told 7 days before).';

create table if not exists townhall_attendance (
  meeting_at timestamptz not null,
  user_id    uuid not null references users (id) on delete cascade,
  at         timestamptz not null default now(),
  method     text not null check (method in ('join', 'checkin')),
  primary key (meeting_at, user_id)
);
create table if not exists townhall_meetings (
  meeting_at timestamptz primary key,
  absent     uuid[] not null default '{}',
  closed_at  timestamptz not null default now()
);
comment on table townhall_attendance is 'Townhall (1068): who joined (the call link through the site) or checked in, per meeting.';
comment on table townhall_meetings is 'Townhall (1068): each meeting once over, with the active staff who did not attend.';
do $$
declare t text;
begin
  foreach t in array array['townhall_attendance', 'townhall_meetings'] loop
    execute format('alter table %I enable row level security', t);
    execute format('revoke all on %I from anon, authenticated', t);
    execute format('grant all on %I to service_role', t);
    execute format('create policy admin_all on %I for select to authenticated using (app.is_admin())', t);
    execute format('create trigger %I after insert or update or delete on %I for each row execute function app.audit_row()', 'audit_' || t, t);
  end loop;
end $$;

insert into staff_alert_rules (rule, label, grp, who, tier, topic, wired, fixed, hint, sort) values
  ('townhall_moved', 'The townhall moves to another day', 'Staff', '{assigned}', 'normal', 'alerts', true, false, 'Every staff member, 7 days before the new day (1068).', 165),
  ('townhall_absent', 'Staff missed the townhall', 'Staff', '{admin}', 'normal', 'alerts', true, false, 'Once the call is over (1068).', 166)
on conflict (rule) do nothing;
update staff_alert_rules set who = '{assigned}', hint = 'Every active staff member, an hour before (1068).' where rule = 'townhall_soon';

-- ================================================================ the day
create or replace function app.townhall_weekday_now(p_day date default null) returns integer
language sql stable security definer set search_path = public, app as $$
  select case when s.townhall_next_from is not null and s.townhall_next_from <= coalesce(p_day, app.today()) then s.townhall_next_weekday else s.townhall_weekday end
    from (select (app.settings()).*) s
$$;

create or replace function app.townhall_next(p_now timestamptz default now()) returns timestamptz
language sql stable security definer set search_path = public, app as $$
  select min(((app.local_date(p_now) + d) + (app.settings()).townhall_time::time) at time zone 'America/Toronto')
    from generate_series(0, 7) d
   where extract(isodow from app.local_date(p_now) + d)::int = app.townhall_weekday_now(app.local_date(p_now) + d)
     and ((app.local_date(p_now) + d) + (app.settings()).townhall_time::time) at time zone 'America/Toronto' > p_now - make_interval(mins => (app.settings()).townhall_minutes)
$$;

-- how busy each weekday is: pickups, returns and field jobs over the last 8 weeks and the next 2 (Toronto days)
create function app.townhall_busy_days(p_now timestamptz default now()) returns jsonb
language sql stable security definer set search_path = public, app as $$
  select jsonb_object_agg(d::text, coalesce(n, 0)) from generate_series(1, 7) d left join (
    select extract(isodow from t at time zone 'America/Toronto')::int dow, count(*) n from (
      select b.pickup_at t from bookings b where b.status::text not in ('cancelled', 'declined', 'expired', 'requested', 'offered') and b.pickup_at between p_now - interval '56 days' and p_now + interval '14 days'
      union all select b.return_at from bookings b where b.status::text not in ('cancelled', 'declined', 'expired', 'requested', 'offered') and b.return_at between p_now - interval '56 days' and p_now + interval '14 days'
      union all select j.scheduled_at from field_jobs j where j.status <> 'cancelled' and j.scheduled_at between p_now - interval '56 days' and p_now + interval '14 days') x group by 1) c on c.dow = d
$$;

create function app.townhall_pick_day(p_now timestamptz default now()) returns integer
language sql stable security definer set search_path = public, app as $$
  select (k)::int from jsonb_each_text(app.townhall_busy_days(p_now)) e(k, v)
   where k::int between 1 and 6
   order by v::int, (k::int = app.townhall_weekday_now()) desc, k::int limit 1
$$;

-- ================================================================ field calls before the townhall
create function app.townhall_field_slots(p_now timestamptz default now()) returns integer
language plpgsql security definer set search_path = public, app as $$
declare
  v_at timestamptz := app.townhall_next(p_now);
  v_day date;
  v_start time;
  v_id uuid;
  v_roles uuid[] := array(select r.id from hiring_roles r where r.staff_kind = 'field');
begin
  if v_at is null or v_at <= p_now + interval '2 hours' or cardinality(v_roles) = 0 then return 0; end if;
  v_day := app.local_date(v_at);
  v_start := ((v_at at time zone 'America/Toronto') - interval '1 hour')::time;
  select id into v_id from interview_days where day = v_day and start_time = v_start and role_ids = v_roles;
  if v_id is null then
    insert into interview_days (day, start_time, end_time, slot_minutes, buffer_minutes, capacity, mode, role_ids, note, active)
    values (v_day, v_start, (v_at at time zone 'America/Toronto')::time, 10, 0, 1, 'video', v_roles, 'Field calls in the hour before the weekly townhall (1068)', true)
    returning id into v_id;
    return app.hiring_day_slots(v_id);
  end if;
  return 0;
end $$;

-- a field applicant who passed the AI interview: invited to the live call with the booking link
create function app.hiring_field_to_call(p_now timestamptz default now()) returns integer
language plpgsql security definer set search_path = public, app as $$
declare
  a job_applications;
  n integer := 0;
begin
  for a in select j.* from job_applications j join hiring_roles r on r.id = j.role_id join ai_interviews i on i.application_id = j.id
            where r.staff_kind = 'field' and i.state = 'scored' and i.live_call_at is null and coalesce(i.recommendation, '') <> 'decline'
              and i.interview_score >= r.pass_mark and cardinality(j.knockouts) = 0 and j.status = 'interviewed' and j.purged_at is null
            for update of j skip locked loop
    update ai_interviews set live_call_at = p_now, updated_at = p_now where application_id = a.id;
    update job_applications set status = 'invited', invited_at = p_now, updated_at = p_now where id = a.id returning * into a;
    perform app.hiring_emit_pre0380('applicant_invited', a, app.hiring_invite_vars(a), 'applicant_invited:' || a.id || ':field_call');
    n := n + 1;
  end loop;
  return n;
end $$;

create function app.field_call_slots(p_by uuid, p jsonb) returns jsonb
language plpgsql stable security definer set search_path = public, app as $$
begin
  if not (app.user_is_admin(p_by) or app.user_va_has(p_by, 'fleet')) then raise exception 'Fleet or an Admin' using errcode = '42501'; end if;
  return coalesce((select jsonb_agg(jsonb_build_object('starts_at', s.starts_at, 'ends_at', s.ends_at,
      'applicant', (select a.full_name from job_applications a where a.slot_id = s.id limit 1)) order by s.starts_at)
    from interview_slots s join interview_days d on d.id = s.day_id
   where d.note like 'Field calls in the hour before the weekly townhall%' and s.starts_at > now() - interval '1 hour'), '[]'::jsonb);
end $$;

-- ================================================================ the deck: a tile for every staff member
create function app.townhall_people(p_week date) returns jsonb
language sql stable security definer set search_path = public, app as $$
  with w as (select (p_week::timestamp at time zone 'America/Toronto') a, ((p_week + 7)::timestamp at time zone 'America/Toronto') z)
  select coalesce(jsonb_agg(jsonb_build_object('user_id', sp.user_id, 'name', coalesce(nullif(btrim(u.greeting_name), ''), u.full_name, u.email),
      'role', array_to_string(array(select case f when 'cs' then 'Customer service' when 'fleet' then 'Fleet' when 'finance' then 'Finance' when 'sales' then 'Sales' else 'Field' end
                                      from unnest(sp.functions) f), ', '),
      'points', (select jsonb_agg(p) from (
          select app.th_point('Offers sent', (select count(*) from booking_events e where e.actor_user_id = sp.user_id and e.kind = 'offer_sent' and e.created_at >= w.a and e.created_at < w.z)::text) p where 'sales' = any (sp.functions)
          union all select app.th_point('Bookings', (select count(*) from bookings b where b.sales_staff_id = sp.user_id and b.booked_at >= w.a and b.booked_at < w.z)::text) where 'sales' = any (sp.functions)
          union all select app.th_point('Replies', (select count(*) from phone_activity o where o.staff_user_id = sp.user_id and o.direction = 'out' and o.started_at >= w.a and o.started_at < w.z)::text) where 'cs' = any (sp.functions)
          union all select app.th_point('Average reply', coalesce((select round(avg(extract(epoch from o.started_at - (select max(i.started_at) from phone_activity i where i.thread_id = o.thread_id and i.direction = 'in' and i.started_at < o.started_at)) / 60))::text || ' min'
                                      from phone_activity o where o.staff_user_id = sp.user_id and o.direction = 'out' and o.started_at >= w.a and o.started_at < w.z), 'none')) where 'cs' = any (sp.functions)
          union all select app.th_point('Jobs done', (select count(*) from field_jobs j where j.assigned_to = sp.user_id and j.status = 'done' and j.completed_at >= w.a and j.completed_at < w.z)::text) where sp.functions && array['fleet', 'field']
          union all select app.th_point('Deposits released', (select count(*) from deposits d where d.release_approved_by = sp.user_id and d.released_at >= w.a and d.released_at < w.z)::text) where 'finance' = any (sp.functions)) q))
      order by coalesce(nullif(btrim(u.greeting_name), ''), u.full_name)), '[]'::jsonb)
    from staff_profiles sp join users u on u.id = sp.user_id, w
   where app.staff_is_member(sp.user_id)
$$;

alter function app.townhall_slides(date) rename to townhall_slides_pre1068;
create function app.townhall_slides(p_week date) returns jsonb
language sql stable security definer set search_path = public, app as $$
  select app.townhall_slides_pre1068(p_week) || jsonb_build_array(jsonb_build_object('key', 'people', 'title', 'The team this week', 'admin_only', false,
    'points', '[]'::jsonb, 'people', app.townhall_people(p_week)))
$$;

-- the view: the shout-outs on the people, the attendance of the next meeting; a note's key may be a person (p_<id>)
alter function app.townhall_view(uuid, jsonb) rename to townhall_view_pre1068;
create function app.townhall_view(p_by uuid, p jsonb) returns jsonb
language plpgsql stable security definer set search_path = public, app as $$
declare
  v jsonb := app.townhall_view_pre1068(p_by, p);
  d townhall_decks;
  v_next timestamptz := app.townhall_next(now());
begin
  select * into d from townhall_decks where id = nullif(v #>> '{deck,id}', '')::uuid;
  if d.id is not null then
    v := jsonb_set(v, '{deck,slides}', coalesce((select jsonb_agg(case when s ->> 'key' = 'people' then jsonb_set(s, '{people}', coalesce((select jsonb_agg(x || jsonb_build_object('shoutout', d.notes ->> ('p_' || (x ->> 'user_id')))) from jsonb_array_elements(s -> 'people') x), '[]'::jsonb)) else s end order by o)
                                              from jsonb_array_elements(v #> '{deck,slides}') with ordinality t(s, o)), '[]'::jsonb));
  end if;
  return v || jsonb_build_object('checked_in', exists (select 1 from townhall_attendance x where x.meeting_at = v_next and x.user_id = p_by),
    'can_check_in', v_next is not null and now() between v_next - interval '15 minutes' and v_next + make_interval(mins => (app.settings()).townhall_minutes),
    'weekday', app.townhall_weekday_now(), 'next_weekday', (app.settings()).townhall_next_weekday, 'next_from', (app.settings()).townhall_next_from,
    'attendance', case when app.user_is_admin(p_by) then (select jsonb_build_object('meetings', count(*), 'last_absent', (select cardinality(m.absent) from townhall_meetings m order by m.meeting_at desc limit 1)) from townhall_meetings) end);
end $$;

create or replace function app.townhall_do(p_by uuid, p_action text, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare v_id uuid;
begin
  perform app.assert_admin(p_by);
  if p_action = 'townhall_build' then
    v_id := app.townhall_build(nullif(p ->> 'week_of', '')::date, p_by);
  else
    if coalesce(p ->> 'key', '') !~ '^([a-z]{2,20}|p_[0-9a-f-]{36})$' then raise exception 'Choose the slide' using errcode = '22023'; end if;
    update townhall_decks set notes = case when nullif(btrim(coalesce(p ->> 'note', '')), '') is null then notes - (p ->> 'key')
                                          else notes || jsonb_build_object(p ->> 'key', left(btrim(p ->> 'note'), 2000)) end
     where id = nullif(p ->> 'deck', '')::uuid returning id into v_id;
    if v_id is null then raise exception 'Deck not found' using errcode = 'P0002'; end if;
  end if;
  return jsonb_build_object('id', v_id);
end $$;

-- a join (the call link through the site) or a check-in, for the meeting now or next
create function app.townhall_attend(p_by uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare v_next timestamptz := app.townhall_next(now());
begin
  if not (app.user_is_admin(p_by) or app.user_is_staff(p_by) or app.user_is_field(p_by)) then raise exception 'Staff only' using errcode = '42501'; end if;
  if v_next is null or now() < v_next - interval '15 minutes' then raise exception 'Check-in opens 15 minutes before the townhall' using errcode = '23514'; end if;
  insert into townhall_attendance (meeting_at, user_id, method) values (v_next, p_by, case when p ->> 'method' = 'join' then 'join' else 'checkin' end)
  on conflict do nothing;
  return jsonb_build_object('ok', true, 'meeting_at', v_next, 'call_url', nullif((app.settings()).townhall_call_url, ''));
end $$;

-- ================================================================ the job: the day, the reminders, the absences
alter function app.job_townhall(timestamptz) rename to job_townhall_pre1068;
create function app.job_townhall(p_now timestamptz default now()) returns text
language plpgsql security definer set search_path = public, app as $$
declare
  v_local timestamp := p_now at time zone 'America/Toronto';
  v_next timestamptz := app.townhall_next(p_now);
  v_last timestamptz;
  v_pick integer;
  v_absent uuid[];
  r record;
  n_rem integer := 0;
  s program_settings := app.settings();
  v_words text;
begin
  -- the deck of the week, as before (its alert to the Admins is replaced by the one to everyone below)
  perform app.job_townhall_pre1068(p_now);
  -- a new day that has come: in force
  if s.townhall_next_from is not null and s.townhall_next_from <= app.local_date(p_now) then
    update program_settings set townhall_weekday = townhall_next_weekday, townhall_next_weekday = null, townhall_next_from = null where townhall_next_from is not null;
  end if;
  -- Sunday evening: the least busy day; a change is announced 7 days ahead
  if s.townhall_auto_day and extract(isodow from v_local) = 7 and extract(hour from v_local) >= 21 and s.townhall_next_from is null then
    v_pick := app.townhall_pick_day(p_now);
    if v_pick is not null and v_pick <> s.townhall_weekday then
      update program_settings set townhall_next_weekday = v_pick, townhall_next_from = app.local_date(p_now) + 8;
      v_words := to_char(date '2026-01-04' + v_pick, 'FMDay');
      for r in select sp.user_id from staff_profiles sp where app.staff_is_member(sp.user_id) union select ur.user_id from user_roles ur where ur.role = 'admin' loop
        perform app.staff_alert('townhall_moved', 'user', r.user_id, 'moved:' || to_char(app.local_date(p_now) + 8, 'YYYYMMDD'),
          format('The townhall moves to %ss', v_words), format('From %s, at %s Toronto time: the quietest day of the week.', to_char(app.local_date(p_now) + 8, 'FMDay, FMMonth FMDD'), s.townhall_time),
          jsonb_build_object('assigned_to', r.user_id, 'path_staff', '/staff/townhall', 'path_admin', '/admin/townhall'));
      end loop;
    end if;
  end if;
  -- an hour before: every active staff member, and the Admins
  if v_next is not null and v_next > p_now and v_next <= p_now + interval '60 minutes' then
    for r in select sp.user_id from staff_profiles sp where app.staff_is_member(sp.user_id) union select ur.user_id from user_roles ur where ur.role = 'admin' loop
      perform app.staff_alert('townhall_soon', 'user', r.user_id, 'soon:' || to_char(v_next, 'YYYYMMDDHH24MI'), 'The weekly townhall starts in an hour',
        'At ' || to_char(v_next at time zone 'America/Toronto', 'FMHH12:MI am') || ' Toronto time. Join from Townhall: that counts as your attendance.',
        jsonb_build_object('assigned_to', r.user_id, 'path_admin', '/admin/townhall', 'path_staff', '/staff/townhall'));
      n_rem := n_rem + 1;
    end loop;
  end if;
  -- the field calls of the hour before the next meeting
  perform app.townhall_field_slots(p_now);
  -- the meeting over (15 minutes after its end): the absences, once
  v_last := app.townhall_next(p_now - interval '8 days');
  for v_last in select m from (select app.townhall_next(p_now - make_interval(days => d)) m from generate_series(1, 8) d) x
                 where m is not null and m + make_interval(mins => s.townhall_minutes + 15) <= p_now and m > p_now - interval '7 days' group by m loop
    if exists (select 1 from townhall_meetings where meeting_at = v_last) then continue; end if;
    v_absent := array(select sp.user_id from staff_profiles sp where app.staff_is_member(sp.user_id)
                        and not exists (select 1 from townhall_attendance a where a.meeting_at = v_last and a.user_id = sp.user_id));
    insert into townhall_meetings (meeting_at, absent) values (v_last, v_absent);
    if cardinality(v_absent) > 0 then
      perform app.staff_alert('townhall_absent', 'townhall_meeting', null, 'absent:' || to_char(v_last, 'YYYYMMDDHH24MI'),
        format('%s missed the townhall', cardinality(v_absent) || case when cardinality(v_absent) = 1 then ' person' else ' people' end),
        left(array_to_string(array(select coalesce(nullif(btrim(u.greeting_name), ''), u.full_name) from users u where u.id = any (v_absent) order by 1), ', '), 240),
        jsonb_build_object('path_admin', '/admin/settings/staff'));
    end if;
  end loop;
  return format('%s reminded', n_rem);
end $$;

-- the staff list: townhalls missed in the last 8 weeks
create or replace function app.staff_access_facts(p_by uuid, p jsonb) returns jsonb
language plpgsql stable security definer set search_path = public, app as $$
begin
  perform app.assert_admin(p_by);
  return coalesce((select jsonb_object_agg(sp.user_id::text, jsonb_build_object('last_sign_in_at', u.last_sign_in_at, 'last_active_at', app.staff_last_active(sp),
           'locked_at', sp.inactive_locked_at, 'preferred_name', nullif(btrim(u.greeting_name), ''), 'location', nullif(concat_ws(', ', sp.location_city, sp.location_country), ''),
           'townhalls_missed', (select count(*) from townhall_meetings m where sp.user_id = any (m.absent) and m.meeting_at > now() - interval '56 days')))
    from staff_profiles sp join users u on u.id = sp.user_id), '{}'::jsonb);
end $$;

-- ================================================================ 3. the live map's celebrations
create or replace function app.live_map_pre0470(p_by uuid, p jsonb default '{}'::jsonb) returns jsonb
language plpgsql stable security definer set search_path = public, app as $$
declare v jsonb := app.live_map_pre0470_k(p_by, p);
begin
  if v is null or jsonb_typeof(v) <> 'object' or coalesce(p ->> 'part', 'kpi') <> 'kpi' then return v; end if;
  if v ? 'kpi' then
    v := jsonb_set(v, '{kpi,on_rent_now}', to_jsonb((select count(*) from bookings b where b.booking_type <> 'owner' and not coalesce(b.is_placeholder, false)
           and (b.status = 'on_rent' or (b.status = 'confirmed' and b.pickup_at <= now() and b.return_at > now())))));
  end if;
  return v || jsonb_build_object('working', app.working_now(now()), 'leaderboard', app.sales_week_board(now()),
    'celebrations', coalesce((select jsonb_agg(jsonb_build_object('booking_number', b.booking_number, 'at', b.confirmed_at, 'car', app.vehicle_name(b.vehicle_id),
        'sales', (select coalesce(nullif(btrim(u.greeting_name), ''), split_part(btrim(coalesce(u.full_name, '')), ' ', 1)) from users u where u.id = b.sales_staff_id)) order by b.confirmed_at)
      from bookings b where b.confirmed_at > now() - interval '15 minutes' and b.booking_type <> 'owner' and not coalesce(b.is_placeholder, false)), '[]'::jsonb));
end $$;

-- ================================================================ the jobs and the door
alter function app.job_hiring(timestamptz) rename to job_hiring_pre1068;
create function app.job_hiring(p_now timestamptz default now()) returns jsonb
language plpgsql security definer set search_path = public, app as $$
begin
  return app.job_hiring_pre1068(p_now) || jsonb_build_object('field_to_call', app.hiring_field_to_call(p_now));
end $$;

alter function app.door(uuid, text, text, text, jsonb) rename to door_pre1068;
create function app.door(p_user uuid, p_aal text, p_call text, p_name text, p jsonb default '{}'::jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare p_ jsonb := coalesce(p, '{}'::jsonb) - '_va';
begin
  if (p_call = 'ops_do' and p_name = 'townhall_attend') or (p_call in ('ops_read', 'admin_read') and p_name = 'field_call_slots') then
    perform app.door_begin(p_user, p_aal);
    return case p_name when 'townhall_attend' then app.townhall_attend(p_user, p_) else app.field_call_slots(p_user, p_) end;
  end if;
  return app.door_pre1068(p_user, p_aal, p_call, p_name, p);
end $$;

do $$
declare f record;
begin
  for f in select p.oid::regprocedure as sig from pg_proc p join pg_namespace n on n.oid = p.pronamespace
            where n.nspname = 'app' and p.proname = any (array['townhall_weekday_now', 'townhall_next', 'townhall_busy_days', 'townhall_pick_day', 'townhall_field_slots',
                    'hiring_field_to_call', 'field_call_slots', 'townhall_people', 'townhall_slides_pre1068', 'townhall_slides', 'townhall_view_pre1068', 'townhall_view',
                    'townhall_do', 'townhall_attend', 'job_townhall_pre1068', 'job_townhall', 'staff_access_facts', 'live_map_pre0470', 'job_hiring_pre1068', 'job_hiring',
                    'door_pre1068', 'door'])
  loop
    execute format('revoke all on function %s from public, anon, authenticated', f.sig);
    execute format('grant execute on function %s to service_role', f.sig);
  end loop;
end $$;
