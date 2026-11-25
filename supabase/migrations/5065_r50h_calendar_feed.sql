-- 5065 (R50 hotfix, docs/changes/2026-11-25-r50-hotfix.md): one calendar subscription shows everything.
-- The owner (an Admin, Nov 25): "I still don't see the interview or townhall in my calendar!" Why: the interview call's
-- calendar invite (5000, app.interview_invite) goes only to the applicant: no Admin or interviewer ever gets one, and the
-- Admin's own notice of a booked call (5051 app.admin_now_email, live_call_booked) is a plain alert email without an .ics,
-- capped at 3 an hour (5063). The townhall invite is an email (5000): it is not digested or capped for an Admin (5051
-- admin_email_keep through app.staff_email_own; 99_r50h_calendar.sql checks it), but it needs an email client that adds
-- invites. Now the private calendar feed of 5050 (one Google Calendar subscription) also carries:
--   1. the weekly townhall: the next 8 meetings as single events (UID townhall-YYYYMMDD@carmacars.ca), a cancelled one
--      left out, on every feed (an Admin's, Fleet's and a field staff member's own);
--   2. on an Admin's feed: every booked interview call (time, applicant's first name, role, the call link, the applicant's
--      page), UID interview-<application id>@carmacars.ca, so a moved call moves in the calendar.
-- No applied migration is edited: app.shift_feed_ics is replaced with create or replace (same signature, grants kept).
-- SCHEMA_MARKER 5065.
set local check_function_bodies = off;

create or replace function app.shift_feed_ics(p_token text, p_now timestamptz default now()) returns text
language plpgsql stable security definer set search_path = public, app, pg_temp as $$
declare
  f shift_feeds;
  v_base text := rtrim(coalesce((app.settings()).notify_base_url, 'https://carmacars.ca'), '/');
  v_admin boolean;
  v_from timestamptz := p_now - interval '14 days';
  v_to timestamptz := p_now + interval '60 days';
  l text[];
  e record;
  v_th timestamptz;
  v_local timestamp;
  k integer;
begin
  if p_token is null or p_token !~ '^[0-9a-f]{64}$' then return null; end if;
  select * into f from shift_feeds where token = p_token and revoked_at is null;
  if f.id is null or not exists (select 1 from users u where u.id = f.user_id and u.status = 'active') or not (f.scope = any (app.shift_feed_scopes(f.user_id))) then
    return null;
  end if;
  v_admin := app.user_is_admin(f.user_id);
  l := array['BEGIN:VCALENDAR', 'PRODID:-//CarmaCars//Shifts//EN', 'VERSION:2.0', 'CALSCALE:GREGORIAN', 'METHOD:PUBLISH',
    app.ics_fold('X-WR-CALNAME:' || app.ics_esc(case f.scope when 'all' then 'CarmaCars shifts, townhalls and interviews' else 'My CarmaCars shifts and townhalls' end)),
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
  -- 5065: the weekly townhall, the next 8 meetings as single events (a stable UID per meeting day; a cancelled one is left out)
  v_th := app.townhall_next(p_now);
  if v_th is not null then
    for k in 0..7 loop
      v_local := (v_th at time zone 'America/Toronto') + make_interval(days => 7 * k);
      continue when exists (select 1 from townhall_cancellations c where (c.meeting_at at time zone 'America/Toronto')::date = v_local::date);
      l := l || array['BEGIN:VEVENT', 'UID:townhall-' || to_char(v_local, 'YYYYMMDD') || '@carmacars.ca', 'DTSTAMP:' || app.ics_utc(p_now),
        'DTSTART;TZID=America/Toronto:' || to_char(v_local, 'YYYYMMDD"T"HH24MISS'),
        'DTEND;TZID=America/Toronto:' || to_char(v_local + make_interval(mins => coalesce((app.settings()).townhall_minutes, 30)), 'YYYYMMDD"T"HH24MISS')];
      l := l || app.ics_fold('SUMMARY:' || app.ics_esc('CarmaCars weekly townhall'));
      l := l || app.ics_fold('DESCRIPTION:' || app.ics_esc('The week in review. Join from the staff portal (Townhall, Join the call): that counts your attendance. ' || app.townhall_call_page()));
      l := l || app.ics_fold('LOCATION:' || app.ics_esc(app.townhall_call_page())) || app.ics_fold('URL:' || app.townhall_call_page())
             || 'TRANSP:OPAQUE'::text || 'STATUS:CONFIRMED'::text || 'END:VEVENT'::text;
    end loop;
  end if;
  -- 5065: an Admin's feed: every booked interview call (the time, the applicant's first name, the role, the call link)
  if f.scope = 'all' and v_admin then
    for e in
      select a.id, s.starts_at, s.ends_at, coalesce(nullif(split_part(btrim(a.full_name), ' ', 1), ''), 'Applicant') as first_name,
             coalesce(r.title, 'a role') as role, nullif(btrim(coalesce(a.meet_url, '')), '') as call_url, d.mode, a.updated_at
        from job_applications a join interview_slots s on s.id = a.slot_id join interview_days d on d.id = s.day_id
        left join hiring_roles r on r.id = a.role_id
       where a.status = 'booked' and s.ends_at >= v_from and s.starts_at <= v_to
       order by s.starts_at, a.id
    loop
      l := l || array['BEGIN:VEVENT', 'UID:interview-' || e.id || '@carmacars.ca', 'DTSTAMP:' || app.ics_utc(p_now), 'LAST-MODIFIED:' || app.ics_utc(coalesce(e.updated_at, p_now)),
        'DTSTART;TZID=America/Toronto:' || app.ics_local(e.starts_at), 'DTEND;TZID=America/Toronto:' || app.ics_local(e.ends_at)];
      l := l || app.ics_fold('SUMMARY:' || app.ics_esc('Interview call: ' || e.first_name || ', ' || e.role));
      l := l || app.ics_fold('DESCRIPTION:' || app.ics_esc(
                 case when e.mode = 'phone' then 'A phone call: we call the applicant.' else 'The call: ' || coalesce(e.call_url, 'the link is on the applicant''s page') end || E'\n'
                 || 'The applicant: ' || v_base || '/admin/hiring/' || e.id));
      if e.mode <> 'phone' and e.call_url is not null then l := l || app.ics_fold('LOCATION:' || app.ics_esc(e.call_url)); end if;
      l := l || app.ics_fold('URL:' || v_base || '/admin/hiring/' || e.id) || 'TRANSP:OPAQUE'::text || 'STATUS:CONFIRMED'::text || 'END:VEVENT'::text;
    end loop;
  end if;
  l := l || 'END:VCALENDAR'::text;
  return array_to_string(l, E'\r\n') || E'\r\n';
end $$;
