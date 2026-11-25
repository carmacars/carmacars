-- 5000: calendar invites by email (release 50; docs/changes/2026-11-24-r50-calendar-invites.md). SCHEMA_MARKER 5000.
-- No applied migration is edited.
--   1. calendar_invites: every invite and cancellation sent (who, which event, its UID and SEQUENCE, the times), so each
--      next one is a proper update of the one before and the history is on record.
--   2. The weekly townhall: every staff member (app.staff_is_member) and every Admin gets an .ics (METHOD:REQUEST, the
--      weekly RRULE on the townhall's day, Toronto time with its VTIMEZONE, ORGANIZER, LOCATION the in-site call page)
--      when they join the team and again as an update when the day, the time or the length changes. A townhall an Admin
--      cancels ahead sends METHOD:CANCEL for that one meeting (RECURRENCE-ID); put back on, the series is sent again. A
--      person who leaves the team gets METHOD:CANCEL for the series. app.townhall_invites_sweep does all of it: the
--      townhall job runs it every 15 minutes, and a change of the schedule or a cancellation runs it at once.
--   3. Interview calls: the booking confirmation (applicant_booked) carries a REQUEST for the booked slot, a moved call an
--      update of the same event; any later email while the call is off (cancelled, released, declined) carries the CANCEL.
--   4. The files ride on the email: app.outbox_inline_files (send-outbox attaches them, text/calendar).
--   5. /api/townhall-ics (Add to calendar) reads the same invite (METHOD:PUBLISH) through door ops_read townhall_ics.
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
create function pg_temp.patch_fn(p_sig regprocedure, p_old text, p_new text) returns void
language plpgsql as $$
declare d text := pg_get_functiondef(p_sig);
begin
  if position(p_old in d) = 0 then raise exception '5000: the text to change was not found in %: %', p_sig, left(p_old, 160); end if;
  execute replace(d, p_old, p_new);
end $$;

-- ================================================================ 1. the record
create table if not exists calendar_invites (
  id             uuid primary key default gen_random_uuid(),
  kind           text not null check (kind in ('townhall', 'interview')),
  user_id        uuid references users (id) on delete cascade,
  application_id uuid references job_applications (id) on delete cascade,
  uid            text not null check (length(uid) between 5 and 200),
  seq            integer not null check (seq >= 0),
  method         text not null check (method in ('REQUEST', 'CANCEL')),
  recurrence_id  timestamptz,
  starts_at      timestamptz not null,
  ends_at        timestamptz not null check (ends_at > starts_at),
  rrule          text check (rrule is null or rrule ~ '^FREQ=WEEKLY;BYDAY=(MO|TU|WE|TH|FR|SA|SU)$'),
  exdates        timestamptz[] not null default '{}',
  summary        text not null,
  description    text not null default '',
  location       text not null default '',
  attendee_email text not null,
  attendee_name  text,
  sig            text,
  created_at     timestamptz not null default now(),
  check ((kind = 'townhall' and user_id is not null) or (kind = 'interview' and application_id is not null))
);
create index if not exists calendar_invites_user on calendar_invites (user_id, kind, created_at desc) where user_id is not null;
create index if not exists calendar_invites_app on calendar_invites (application_id, created_at desc) where application_id is not null;
comment on table calendar_invites is 'Calendar invites sent by email (5000): each REQUEST or CANCEL with its UID and SEQUENCE (one event a person: the weekly townhall, an interview call). The .ics is built from the row at send time (app.calendar_invite_ics).';
alter table calendar_invites enable row level security;
revoke all on calendar_invites from public, anon, authenticated;
grant all on calendar_invites to service_role;
drop policy if exists admin_all on calendar_invites;
create policy admin_all on calendar_invites for all to authenticated using (app.is_admin()) with check (app.is_admin());
drop trigger if exists audit_calendar_invites on calendar_invites;
create trigger audit_calendar_invites after insert or update or delete on calendar_invites for each row execute function app.audit_row();

-- ================================================================ 2. iCalendar text (RFC 5545)
create function app.ics_esc(p text) returns text
language sql immutable set search_path = public, app, pg_temp as $$
  select replace(replace(replace(replace(replace(coalesce(p, ''), '\', '\\'), ';', '\;'), ',', '\,'), E'\r', ''), E'\n', '\n')
$$;
-- a content line folded at 74 characters (continuation lines start with a space)
create function app.ics_fold(p text) returns text
language sql immutable set search_path = public, app, pg_temp as $$
  select string_agg(substr(p, 1 + (i * 74), 74), E'\r\n ' order by i) from generate_series(0, greatest((length(p) - 1) / 74, 0)) i
$$;
create function app.ics_local(p timestamptz) returns text
language sql immutable set search_path = public, app, pg_temp as $$ select to_char(p at time zone 'America/Toronto', 'YYYYMMDD"T"HH24MISS') $$;
create function app.ics_utc(p timestamptz) returns text
language sql immutable set search_path = public, app, pg_temp as $$ select to_char(p at time zone 'UTC', 'YYYYMMDD"T"HH24MISS"Z"') $$;
create function app.ics_byday(p_isodow integer) returns text
language sql immutable set search_path = public, app, pg_temp as $$ select (array['MO', 'TU', 'WE', 'TH', 'FR', 'SA', 'SU'])[p_isodow] $$;

-- Toronto's rules (Eastern: EDT from the second Sunday of March, EST from the first Sunday of November)
create function app.ics_vtimezone() returns text
language sql immutable set search_path = public, app, pg_temp as $$
  select array_to_string(array['BEGIN:VTIMEZONE', 'TZID:America/Toronto', 'X-LIC-LOCATION:America/Toronto',
    'BEGIN:DAYLIGHT', 'TZOFFSETFROM:-0500', 'TZOFFSETTO:-0400', 'TZNAME:EDT', 'DTSTART:19700308T020000', 'RRULE:FREQ=YEARLY;BYMONTH=3;BYDAY=2SU', 'END:DAYLIGHT',
    'BEGIN:STANDARD', 'TZOFFSETFROM:-0400', 'TZOFFSETTO:-0500', 'TZNAME:EST', 'DTSTART:19701101T020000', 'RRULE:FREQ=YEARLY;BYMONTH=11;BYDAY=1SU', 'END:STANDARD',
    'END:VTIMEZONE'], E'\r\n')
$$;

-- One event as an .ics: method REQUEST (an invite or its update), CANCEL (the event, or one meeting of the series with
-- recurrence_id) or PUBLISH (a download, no attendee).
create function app.ics_build(p_method text, ci calendar_invites, p_location text default null) returns text
language plpgsql stable security definer set search_path = public, app, pg_temp as $$
declare
  v_loc text := coalesce(nullif(p_location, ''), ci.location);
  v_org text := 'hello@carmacars.ca';
  l text[];
begin
  if p_method not in ('REQUEST', 'CANCEL', 'PUBLISH') then raise exception 'Unknown calendar method %', p_method using errcode = '22023'; end if;
  l := array['BEGIN:VCALENDAR', 'PRODID:-//CarmaCars//Calls//EN', 'VERSION:2.0', 'CALSCALE:GREGORIAN', 'METHOD:' || p_method, app.ics_vtimezone(),
    'BEGIN:VEVENT', 'UID:' || ci.uid, 'SEQUENCE:' || ci.seq, 'DTSTAMP:' || app.ics_utc(ci.created_at)];
  if ci.recurrence_id is not null then
    l := l || ('RECURRENCE-ID;TZID=America/Toronto:' || app.ics_local(ci.recurrence_id));
    l := l || ('DTSTART;TZID=America/Toronto:' || app.ics_local(ci.recurrence_id)) || ('DTEND;TZID=America/Toronto:' || app.ics_local(ci.recurrence_id + (ci.ends_at - ci.starts_at)));
  else
    l := l || ('DTSTART;TZID=America/Toronto:' || app.ics_local(ci.starts_at)) || ('DTEND;TZID=America/Toronto:' || app.ics_local(ci.ends_at));
    if ci.rrule is not null then l := l || ('RRULE:' || ci.rrule); end if;
    if p_method <> 'CANCEL' and cardinality(ci.exdates) > 0 then
      l := l || ('EXDATE;TZID=America/Toronto:' || (select string_agg(app.ics_local(x), ',' order by x) from unnest(ci.exdates) x));
    end if;
  end if;
  l := l || app.ics_fold('SUMMARY:' || app.ics_esc(ci.summary));
  if ci.description <> '' then l := l || app.ics_fold('DESCRIPTION:' || app.ics_esc(ci.description)); end if;
  if v_loc <> '' then l := l || app.ics_fold('LOCATION:' || app.ics_esc(v_loc)); end if;
  if v_loc ~ '^https://' then l := l || app.ics_fold('URL:' || v_loc); end if;
  l := l || app.ics_fold('ORGANIZER;CN=CarmaCars:mailto:' || v_org);
  if p_method <> 'PUBLISH' then
    l := l || app.ics_fold('ATTENDEE;CN="' || replace(coalesce(nullif(ci.attendee_name, ''), ci.attendee_email), '"', '') || '";ROLE=REQ-PARTICIPANT;PARTSTAT=NEEDS-ACTION;RSVP=TRUE:mailto:' || ci.attendee_email);
  end if;
  l := l || ('STATUS:' || case when p_method = 'CANCEL' then 'CANCELLED' else 'CONFIRMED' end) || 'TRANSP:OPAQUE'::text;
  if p_method <> 'CANCEL' then
    l := l || array['BEGIN:VALARM', 'ACTION:DISPLAY', 'DESCRIPTION:' || app.ics_esc(ci.summary), 'TRIGGER:-PT15M', 'END:VALARM'];
  end if;
  l := l || array['END:VEVENT', 'END:VCALENDAR'];
  return array_to_string(l, E'\r\n') || E'\r\n';
end $$;

-- the .ics of a recorded invite; an interview's location is the call's link as it is now (a Meet link that came later)
create function app.calendar_invite_ics(p_id uuid) returns text
language plpgsql stable security definer set search_path = public, app, pg_temp as $$
declare
  ci calendar_invites;
  v_loc text;
begin
  select * into ci from calendar_invites where id = p_id;
  if ci.id is null then return null; end if;
  if ci.kind = 'interview' and ci.method = 'REQUEST' then
    select nullif(btrim(coalesce(a.meet_url, '')), '') into v_loc from job_applications a
     where a.id = ci.application_id and a.status = 'booked' and ci.id = (select x.id from calendar_invites x where x.application_id = a.id order by x.created_at desc, x.seq desc limit 1);
  end if;
  return app.ics_build(ci.method, ci, v_loc);
end $$;

-- ================================================================ 3. the weekly townhall
create function app.townhall_call_page() returns text
language sql stable security definer set search_path = public, app, pg_temp as $$ select rtrim((app.settings()).notify_base_url, '/') || '/staff/townhall/live' $$;

-- the series as it is now: what an invite must say ("sig" changes when the day, the time, the length or the place does)
create function app.townhall_series(p_now timestamptz default now()) returns jsonb
language sql stable security definer set search_path = public, app, pg_temp as $$
  select jsonb_build_object('starts_at', n, 'ends_at', n + make_interval(mins => s.townhall_minutes), 'rrule', 'FREQ=WEEKLY;BYDAY=' || app.ics_byday(s.townhall_weekday),
    'minutes', s.townhall_minutes, 'location', app.townhall_call_page(),
    'when', 'Every ' || (array['Monday', 'Tuesday', 'Wednesday', 'Thursday', 'Friday', 'Saturday', 'Sunday'])[s.townhall_weekday] || ' at '
            || to_char(('2000-01-01 ' || s.townhall_time)::timestamp, 'FMHH12:MI am') || ' Toronto time',
    'sig', s.townhall_weekday || '|' || s.townhall_time || '|' || s.townhall_minutes || '|' || app.townhall_call_page())
    from app.settings() s, lateral (select app.townhall_next(p_now) n) y
   where n is not null
$$;

-- who has the townhall in their calendar: every staff member and every active Admin with an email
create function app.townhall_invitees() returns table (user_id uuid, email text, name text, first_name text)
language sql stable security definer set search_path = public, app, pg_temp as $$
  select u.id, lower(btrim(u.email)), coalesce(nullif(btrim(u.full_name), ''), u.email),
         coalesce(nullif(btrim(u.greeting_name), ''), nullif(split_part(btrim(coalesce(u.full_name, '')), ' ', 1), ''), 'there')
    from users u
   where nullif(btrim(coalesce(u.email, '')), '') is not null
     and (app.staff_is_member(u.id) or (app.user_is_admin(u.id) and coalesce(u.status::text, 'active') = 'active'))
$$;

create function app.townhall_invite_send(p_user uuid, p_email text, p_name text, p_first text, p_method text, p_recurrence timestamptz,
                                         p_series jsonb, p_extra jsonb default '{}'::jsonb) returns uuid
language plpgsql security definer set search_path = public, app, pg_temp as $$
declare
  ci calendar_invites;
  v_prev integer;
  v_ex timestamptz[];
  v_code text;
  v_when text;
begin
  select max(seq) into v_prev from calendar_invites where user_id = p_user and kind = 'townhall';
  select coalesce(array_agg(c.meeting_at order by c.meeting_at), '{}') into v_ex from townhall_cancellations c where c.meeting_at > now();
  insert into calendar_invites (kind, user_id, uid, seq, method, recurrence_id, starts_at, ends_at, rrule, exdates, summary, description, location, attendee_email, attendee_name, sig)
  values ('townhall', p_user, 'townhall@carmacars.ca', coalesce(v_prev + 1, 0), p_method, p_recurrence,
          coalesce((p_series ->> 'starts_at')::timestamptz, p_recurrence), coalesce((p_series ->> 'ends_at')::timestamptz, p_recurrence + interval '45 minutes'),
          p_series ->> 'rrule', case when p_method = 'REQUEST' then v_ex else '{}' end,
          'CarmaCars weekly townhall',
          'The week in review: the numbers, what changed on the platform, shout-outs and what comes next. Join from the staff portal (Townhall, Join the call): that counts your attendance. Cameras on.',
          coalesce(p_series ->> 'location', ''), p_email, p_name, p_series ->> 'sig')
  returning * into ci;
  if p_method = 'REQUEST' then
    v_code := 'staff_townhall_invite';
    perform app.emit_event(v_code, 'user', p_user, jsonb_build_object('recipient_user_id', p_user, 'first_name', p_first,
      'invite_subject', case when v_prev is null then 'Weekly townhall: your calendar invite' else 'Weekly townhall: updated calendar invite' end,
      'invite_title', case when v_prev is null then 'Your townhall invite' else 'The townhall invite, updated' end,
      'townhall_when', p_series ->> 'when', 'townhall_minutes', p_series ->> 'minutes', 'is_update', v_prev is not null,
      'call_url', p_series ->> 'location', '_ics_id', ci.id), v_code || ':' || ci.id);
  else
    v_code := 'staff_townhall_cancelled';
    v_when := case when p_recurrence is not null then to_char(p_recurrence at time zone 'America/Toronto', 'FMDay, FMMonth FMDD "at" FMHH12:MI am') end;
    perform app.emit_event(v_code, 'user', p_user, jsonb_build_object('recipient_user_id', p_user, 'first_name', p_first,
      'cancel_subject', case when p_recurrence is null then 'Weekly townhall: removed from your calendar' else 'Townhall cancelled: ' || to_char(p_recurrence at time zone 'America/Toronto', 'FMDay, FMMonth FMDD') end,
      'cancel_title', case when p_recurrence is null then 'The weekly townhall is off your calendar' else 'This townhall is cancelled' end,
      'cancel_lead', case when p_recurrence is null then 'You are no longer on the CarmaCars team, so the weekly townhall comes off your calendar.'
                          else 'The townhall of ' || v_when || ' is cancelled. The next one is on as usual.' end,
      'meeting_when', coalesce(v_when, ''), 'reason', coalesce(p_extra ->> 'reason', ''), 'is_series', p_recurrence is null,
      'call_url', rtrim((app.settings()).notify_base_url, '/') || '/staff/townhall', '_ics_id', ci.id), v_code || ':' || ci.id);
  end if;
  return ci.id;
end $$;

-- Everyone's townhall invite as it should be: a REQUEST for whoever has none, an outdated one or a cancelled meeting put
-- back on; a CANCEL of one meeting an Admin cancelled ahead; a CANCEL of the series for whoever left the team.
create function app.townhall_invites_sweep(p_now timestamptz default now()) returns integer
language plpgsql security definer set search_path = public, app, pg_temp as $$
declare
  v_series jsonb := app.townhall_series(p_now);
  r record;
  last calendar_invites;
  c record;
  n integer := 0;
begin
  if v_series is null then return 0; end if;
  perform pg_advisory_xact_lock(hashtext('townhall_invites_sweep'));
  for r in select * from app.townhall_invitees() loop
    select * into last from calendar_invites x where x.user_id = r.user_id and x.kind = 'townhall' and x.recurrence_id is null order by x.created_at desc, x.seq desc limit 1;
    if last.id is null or last.method = 'CANCEL' or last.sig is distinct from v_series ->> 'sig' or last.attendee_email <> r.email
       -- a meeting cancelled (in the series' exceptions, or cancelled by itself since) and put back on
       or exists (select 1 from (select unnest(last.exdates) t union select x.recurrence_id from calendar_invites x
                                  where x.user_id = r.user_id and x.kind = 'townhall' and x.recurrence_id is not null and x.method = 'CANCEL' and x.created_at >= last.created_at) m
                   where m.t > p_now and not exists (select 1 from townhall_cancellations k where k.meeting_at = m.t)) then
      perform app.townhall_invite_send(r.user_id, r.email, r.name, r.first_name, 'REQUEST', null, v_series);
      n := n + 1;
    else
      for c in select k.meeting_at, k.reason from townhall_cancellations k
                where k.meeting_at > p_now and not (k.meeting_at = any (last.exdates))
                  and not exists (select 1 from calendar_invites x where x.user_id = r.user_id and x.kind = 'townhall' and x.recurrence_id = k.meeting_at
                                     and x.method = 'CANCEL' and x.created_at >= last.created_at)
                order by k.meeting_at loop
        perform app.townhall_invite_send(r.user_id, r.email, r.name, r.first_name, 'CANCEL', c.meeting_at,
          jsonb_build_object('starts_at', c.meeting_at, 'ends_at', c.meeting_at + make_interval(mins => (v_series ->> 'minutes')::int), 'location', v_series ->> 'location', 'sig', last.sig),
          jsonb_build_object('reason', c.reason));
        n := n + 1;
      end loop;
    end if;
  end loop;
  -- left the team: the series comes off their calendar
  for r in select distinct on (x.user_id) x.* from calendar_invites x where x.kind = 'townhall' and x.recurrence_id is null order by x.user_id, x.created_at desc, x.seq desc loop
    if r.method = 'REQUEST' and not exists (select 1 from app.townhall_invitees() i where i.user_id = r.user_id) then
      perform app.townhall_invite_send(r.user_id, r.attendee_email, r.attendee_name,
        coalesce((select coalesce(nullif(btrim(u.greeting_name), ''), nullif(split_part(btrim(coalesce(u.full_name, '')), ' ', 1), ''), 'there') from users u where u.id = r.user_id), 'there'),
        'CANCEL', null, jsonb_build_object('starts_at', r.starts_at, 'ends_at', r.ends_at, 'rrule', r.rrule, 'location', r.location, 'sig', r.sig));
      n := n + 1;
    end if;
  end loop;
  return n;
end $$;

-- the townhall job (every 15 minutes) keeps the invites right
alter function app.job_townhall(timestamptz) rename to job_townhall_pre5000;
create function app.job_townhall(p_now timestamptz default now()) returns text
language plpgsql security definer set search_path = public, app, pg_temp as $$
declare v text := app.job_townhall_pre5000(p_now);
begin
  return v || format(', %s calendar invites', app.townhall_invites_sweep(p_now));
end $$;
select pg_temp.copy_grants('app.job_townhall(timestamptz)'::regprocedure, 'app.job_townhall_pre5000(timestamptz)'::regprocedure);

-- a new day, time or length, and a cancellation or its undoing, go out at once
create function app.townhall_invites_now() returns trigger
language plpgsql security definer set search_path = public, app, pg_temp as $$
begin
  perform app.townhall_invites_sweep(now());
  return null;
end $$;
drop trigger if exists program_settings_townhall_invites on program_settings;
create trigger program_settings_townhall_invites after update of townhall_weekday, townhall_time, townhall_minutes on program_settings
  for each statement execute function app.townhall_invites_now();
drop trigger if exists townhall_cancellations_invites on townhall_cancellations;
create trigger townhall_cancellations_invites after insert or delete on townhall_cancellations for each statement execute function app.townhall_invites_now();

-- the Add to calendar download (/api/townhall-ics): the same event, METHOD:PUBLISH
create function app.townhall_ics(p_by uuid) returns jsonb
language plpgsql stable security definer set search_path = public, app, pg_temp as $$
declare
  v jsonb := app.townhall_series(now());
  ci calendar_invites;
begin
  if not (app.user_is_admin(p_by) or app.user_is_staff(p_by) or app.user_is_field(p_by)) then raise exception 'Staff only' using errcode = '42501'; end if;
  if v is null then return jsonb_build_object('ics', null); end if;
  select * into ci from calendar_invites x where x.user_id = p_by and x.kind = 'townhall' and x.recurrence_id is null order by x.created_at desc, x.seq desc limit 1;
  ci.kind := 'townhall'; ci.uid := 'townhall@carmacars.ca'; ci.seq := coalesce(ci.seq, 0); ci.recurrence_id := null; ci.created_at := now();
  ci.starts_at := (v ->> 'starts_at')::timestamptz; ci.ends_at := (v ->> 'ends_at')::timestamptz; ci.rrule := v ->> 'rrule';
  ci.exdates := coalesce((select array_agg(c.meeting_at order by c.meeting_at) from townhall_cancellations c where c.meeting_at > now()), '{}');
  ci.summary := 'CarmaCars weekly townhall'; ci.location := v ->> 'location'; ci.attendee_email := coalesce(ci.attendee_email, 'staff@carmacars.ca');
  ci.description := 'The week in review. Join from the staff portal (Townhall, Join the call): that counts your attendance.';
  return jsonb_build_object('ics', app.ics_build('PUBLISH', ci));
end $$;

-- ================================================================ 4. interview calls
create function app.interview_invite(p_code text, a job_applications) returns uuid
language plpgsql security definer set search_path = public, app, pg_temp as $$
declare
  last calendar_invites;
  s interview_slots;
  d interview_days;
  r hiring_roles;
  ci calendar_invites;
  v_loc text;
begin
  if a.id is null or nullif(btrim(coalesce(a.email, '')), '') is null or p_code = 'applicant_reminder' then return null; end if;
  select * into last from calendar_invites x where x.application_id = a.id order by x.created_at desc, x.seq desc limit 1;
  select * into r from hiring_roles where id = a.role_id;
  if p_code = 'applicant_booked' and a.status = 'booked' and a.slot_id is not null then
    select * into s from interview_slots where id = a.slot_id;
    select * into d from interview_days where id = s.day_id;
    if s.id is null then return null; end if;
    v_loc := case when d.mode = 'phone' then 'Phone call: CarmaCars calls you' || coalesce(' at ' || nullif(btrim(coalesce(a.phone, '')), ''), '')
                  else coalesce(nullif(btrim(coalesce(a.meet_url, '')), ''), '') end;
    insert into calendar_invites (kind, application_id, uid, seq, method, starts_at, ends_at, summary, description, location, attendee_email, attendee_name)
    values ('interview', a.id, 'interview-' || a.id || '@carmacars.ca', coalesce(last.seq + 1, 0), 'REQUEST', s.starts_at, s.ends_at,
            'CarmaCars interview call: ' || coalesce(r.short_title, r.title, 'your application'),
            'Your interview call with CarmaCars for ' || coalesce(r.title, 'the role') || '. '
              || case when d.mode = 'phone' then 'We call you at the time booked.' else 'Open the link a minute early, with your camera and microphone allowed.' end
              || ' To move or cancel it: ' || app.hiring_url('/careers/book/' || a.token),
            v_loc, lower(btrim(a.email)), a.full_name)
    returning * into ci;
    return ci.id;
  end if;
  -- the call is off (cancelled, released, declined, moved away): its event comes off the calendar
  if last.id is not null and last.method = 'REQUEST' and last.starts_at > now() and (a.slot_id is null or a.status <> 'booked') then
    insert into calendar_invites (kind, application_id, uid, seq, method, starts_at, ends_at, summary, description, location, attendee_email, attendee_name)
    values ('interview', a.id, last.uid, last.seq + 1, 'CANCEL', last.starts_at, last.ends_at, last.summary, 'This interview call is cancelled.', last.location, last.attendee_email, last.attendee_name)
    returning * into ci;
    return ci.id;
  end if;
  return null;
end $$;

alter function app.hiring_emit(text, job_applications, jsonb, text) rename to hiring_emit_pre5000;
create function app.hiring_emit(p_code text, a job_applications, p_extra jsonb default '{}'::jsonb, p_dedupe text default null) returns bigint
language plpgsql security definer set search_path = public, app, pg_temp as $$
declare v_ics uuid := app.interview_invite(p_code, a);
begin
  return app.hiring_emit_pre5000(p_code, a, coalesce(p_extra, '{}'::jsonb) || case when v_ics is not null then jsonb_build_object('_ics_id', v_ics) else '{}'::jsonb end, p_dedupe);
end $$;
select pg_temp.copy_grants('app.hiring_emit(text, job_applications, jsonb, text)'::regprocedure, 'app.hiring_emit_pre5000(text, job_applications, jsonb, text)'::regprocedure);

-- ================================================================ 5. the files ride on the email (send-outbox)
create function app.outbox_inline_files(p_outbox uuid) returns jsonb
language plpgsql stable security definer set search_path = public, app, pg_temp as $$
declare
  o notification_outbox;
  ci calendar_invites;
  v_id text;
begin
  select * into o from notification_outbox where id = p_outbox;
  if o.id is null then return '[]'::jsonb; end if;
  -- the invite's id is on the event the email was routed from (the outbox keeps the template's variables)
  v_id := coalesce(nullif(o.payload ->> '_ics_id', ''), (select nullif(e.payload ->> '_ics_id', '') from app_events e where e.id = o.event_id));
  if v_id is null or v_id !~ '^[0-9a-f-]{36}$' then return '[]'::jsonb; end if;
  select * into ci from calendar_invites where id = v_id::uuid;
  if ci.id is null then return '[]'::jsonb; end if;
  return jsonb_build_array(jsonb_build_object('filename', case when ci.kind = 'townhall' then 'carmacars-townhall.ics' else 'carmacars-interview.ics' end,
    'content_type', 'text/calendar; method=' || ci.method || '; charset=UTF-8', 'content', app.calendar_invite_ics(ci.id)));
end $$;

-- ================================================================ 6. the door: the download
alter function app.door(uuid, text, text, text, jsonb) rename to door_pre5000;
create function app.door(p_user uuid, p_aal text, p_call text, p_name text, p jsonb default '{}'::jsonb) returns jsonb
language plpgsql security definer set search_path = public, app, pg_temp as $$
begin
  if p_call in ('ops_read', 'admin_read', 'field_read') and p_name = 'townhall_ics' then
    perform app.door_begin(p_user, p_aal);
    return app.townhall_ics(p_user);
  end if;
  return app.door_pre5000(p_user, p_aal, p_call, p_name, p);
end $$;
select pg_temp.copy_grants('app.door(uuid, text, text, text, jsonb)'::regprocedure, 'app.door_pre5000(uuid, text, text, text, jsonb)'::regprocedure);

-- ================================================================ 7. the emails
-- CATALOGUE 5000 START (generated by supabase/seed/5000_gen_catalogue.mjs; do not edit by hand)
insert into notification_catalogue (code, audience, also_sent_to, category, is_digest, digest_slot, from_address, reply_to,
    subject, preheader, timing, trigger_text, replaces_template, link_path, variables, template_html, template_text) values
  ('staff_townhall_invite', 'staff_field', '{}'::text[], 'transactional', false, null, 'CarmaCars <hello@carmacars.ca>', 'contact@carmacars.ca', '{{invite_subject}}', '{{townhall_when}}, {{townhall_minutes}} minutes. Open the invite to add it to your calendar.', 'Immediate: on joining the team, and on every change of the day or time', 'Release 50 (5000): the weekly townhall calendar invite (an .ics file, METHOD:REQUEST, repeating every week, Toronto time) to every staff member and Admin: once when they join the team, and again as an update whenever an Admin changes the day, the time or the length, or puts a cancelled townhall back on. Sent by the townhall job (app.townhall_invites_sweep).', null, null, '[{"name":"call_url","type":"url"},{"name":"company_address","type":"string","global":true},{"name":"first_name","type":"string"},{"name":"invite_subject","type":"string"},{"name":"invite_title","type":"string"},{"name":"is_update","type":"boolean"},{"name":"townhall_minutes","type":"string"},{"name":"townhall_when","type":"string"}]'::jsonb, 'templates/staff_townhall_invite.html', 'templates/staff_townhall_invite.txt'),
  ('staff_townhall_cancelled', 'staff_field', '{}'::text[], 'transactional', false, null, 'CarmaCars <hello@carmacars.ca>', 'contact@carmacars.ca', '{{cancel_subject}}', '{{cancel_lead}}', 'Immediate, when a townhall is cancelled or the person leaves the team', 'Release 50 (5000): a calendar cancellation (an .ics file, METHOD:CANCEL). One townhall: an Admin cancels it ahead (Townhall > Meetings), to every staff member and Admin who has the weekly invite. The whole series: the person is no longer on the team. Sent by the townhall job (app.townhall_invites_sweep).', null, null, '[{"name":"call_url","type":"url"},{"name":"cancel_lead","type":"string"},{"name":"cancel_subject","type":"string"},{"name":"cancel_title","type":"string"},{"name":"company_address","type":"string","global":true},{"name":"first_name","type":"string"},{"name":"is_series","type":"boolean"},{"name":"meeting_when","type":"string"},{"name":"reason","type":"string"}]'::jsonb, 'templates/staff_townhall_cancelled.html', 'templates/staff_townhall_cancelled.txt')
on conflict (code) do update set
  audience = excluded.audience, also_sent_to = excluded.also_sent_to, category = excluded.category,
  is_digest = excluded.is_digest, digest_slot = excluded.digest_slot, from_address = excluded.from_address,
  reply_to = excluded.reply_to, subject = excluded.subject, preheader = excluded.preheader, timing = excluded.timing,
  trigger_text = excluded.trigger_text, replaces_template = excluded.replaces_template, link_path = excluded.link_path,
  variables = excluded.variables, template_html = excluded.template_html, template_text = excluded.template_text,
  in_catalogue = true, updated_at = now();
select app.notification_catalogue_refresh();
-- CATALOGUE 5000 END
update notification_catalogue set emitted_by = 'app.townhall_invites_sweep (5000): a staff member or Admin joins, the townhall''s day or time changes, or a cancelled townhall is back on'
 where code = 'staff_townhall_invite';
update notification_catalogue set emitted_by = 'app.townhall_invites_sweep (5000): an Admin cancels one townhall ahead, or the person leaves the team'
 where code = 'staff_townhall_cancelled';
update notification_catalogue set no_text = true, hold_to_merge = false, priority = 3 where code in ('staff_townhall_invite', 'staff_townhall_cancelled');
-- sent by themselves, never folded into the staff email digest (the .ics must reach the calendar)
select pg_temp.patch_fn('app.staff_email_own(text)'::regprocedure,
  $o$'staff_inactivity_warning')$o$, $n$'staff_inactivity_warning', 'staff_townhall_invite', 'staff_townhall_cancelled')$n$);

-- ================================================================ privileges
do $$
declare f record;
begin
  for f in select p.oid::regprocedure as sig from pg_proc p join pg_namespace n on n.oid = p.pronamespace
            where n.nspname = 'app' and p.proname = any (array['ics_esc', 'ics_fold', 'ics_local', 'ics_utc', 'ics_byday', 'ics_vtimezone', 'ics_build', 'calendar_invite_ics',
                    'townhall_call_page', 'townhall_series', 'townhall_invitees', 'townhall_invite_send', 'townhall_invites_sweep', 'job_townhall_pre5000', 'townhall_invites_now',
                    'townhall_ics', 'interview_invite', 'hiring_emit_pre5000', 'outbox_inline_files', 'door_pre5000']) loop
    execute format('revoke all on function %s from public, anon, authenticated', f.sig);
    execute format('grant execute on function %s to service_role', f.sig);
  end loop;
end $$;

-- ================================================================ now: everyone on the team gets the weekly invite
select app.townhall_invites_sweep(now());
