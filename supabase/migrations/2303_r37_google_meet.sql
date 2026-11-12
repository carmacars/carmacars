-- 2303_r37_google_meet.sql (release 37)
-- Interview calls on Google Meet instead of Jitsi, through the Google Calendar API, once an Admin connects the company's
-- Google Calendar (Admin > Hiring, "Connect Google Calendar": OAuth with the site's Google client, calendar.events scope,
-- offline access). The refresh token lives in the vault (as the reviews sync's, 0146); nothing else stores it.
--   1. calendar_google_link: the one connection (status, account, calendar, who connected it, the last error).
--   2. Booking or moving a video call still writes a Jitsi link first (0173/0229); when the calendar is connected, a trigger
--      marks the application for the calendar job (meet_sync create or update), and its confirmation email waits up to
--      app.settings().meet_hold_minutes. The job (/api/jobs/meet, every five minutes while something is waiting) creates or
--      moves the Calendar event with a Meet conference; public.server_hiring_meet_done puts the Meet link on the
--      application and into the waiting emails, which then go at once. A refused or failed call keeps the Jitsi link (the
--      fallback), so a candidate always has a working link. Cancelling the call deletes the event.
--   3. Not connected: everything stays on Jitsi, and Admin > Hiring shows "Connect Google Calendar".

alter table program_settings add column if not exists meet_hold_minutes integer not null default 10 check (meet_hold_minutes between 0 and 60);
comment on column program_settings.meet_hold_minutes is 'Google Meet (2303): how long an interview confirmation waits for its Meet link before it goes with the Jitsi link instead.';

create table if not exists calendar_google_link (
  id            boolean primary key default true check (id),
  status        text not null default 'not_connected' check (status in ('not_connected', 'connected', 'error')),
  account_email text,
  calendar_id   text not null default 'primary' check (length(calendar_id) between 1 and 200),
  connected_at  timestamptz,
  connected_by  uuid references users (id),
  last_error    text,
  updated_at    timestamptz not null default now()
);
insert into calendar_google_link (id) values (true) on conflict (id) do nothing;
comment on table calendar_google_link is 'Google Calendar (2303): the company calendar interview calls are booked on, with a Google Meet link each. The refresh token is in the vault (google_calendar_refresh_token).';
alter table calendar_google_link enable row level security;
drop policy if exists admin_all on calendar_google_link;
create policy admin_all on calendar_google_link for all to authenticated using (app.is_admin()) with check (app.is_admin());
revoke all on calendar_google_link from public, anon, authenticated;
grant select, insert, update, delete on calendar_google_link to service_role;
drop trigger if exists audit_calendar_google_link on calendar_google_link;
create trigger audit_calendar_google_link after insert or update or delete on calendar_google_link for each row execute function app.audit_row();

alter table job_applications
  add column if not exists meet_provider text check (meet_provider in ('jitsi', 'google')),
  add column if not exists meet_event_id text,
  add column if not exists meet_sync text check (meet_sync in ('create', 'update', 'delete')),
  add column if not exists meet_sync_since timestamptz,
  add column if not exists meet_error text;
comment on column job_applications.meet_sync is 'Google Meet (2303): what the calendar job still has to do for this call (create or move the event, or delete it).';

-- ================================================================ the token (the vault)
create or replace function app.calendar_google_token_set(p_token text) returns void
language plpgsql security definer set search_path = public, app as $$
declare v_id uuid;
begin
  if to_regnamespace('vault') is null then raise exception 'The vault is not available on this database' using errcode = '55000'; end if;
  execute 'select id from vault.secrets where name = $1' into v_id using 'google_calendar_refresh_token';
  if p_token is null then
    if v_id is not null then execute 'delete from vault.secrets where id = $1' using v_id; end if;
  elsif v_id is null then
    execute 'select vault.create_secret($1, $2, $3)' using p_token, 'google_calendar_refresh_token', 'Google Calendar for interview calls with Google Meet, 2303';
  else
    execute 'select vault.update_secret($1, $2)' using v_id, p_token;
  end if;
end $$;

create or replace function app.calendar_google_token() returns text
language plpgsql stable security definer set search_path = public, app as $$
declare v text;
begin
  if to_regnamespace('vault') is null then return null; end if;
  execute 'select decrypted_secret from vault.decrypted_secrets where name = $1' into v using 'google_calendar_refresh_token';
  return v;
end $$;

create or replace function app.meet_connected() returns boolean
language sql stable security definer set search_path = public, app as $$ select coalesce((select status = 'connected' from calendar_google_link), false) $$;

-- the OAuth callback (an Admin connected the calendar) and the disconnect
create or replace function app.calendar_google_connect(p_admin uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
begin
  perform app.assert_admin(p_admin);
  if nullif(p ->> 'refresh_token', '') is null then raise exception 'Google sent no refresh token: connect again and allow offline access' using errcode = '22023'; end if;
  perform app.calendar_google_token_set(p ->> 'refresh_token');
  update calendar_google_link set status = 'connected', account_email = nullif(btrim(coalesce(p ->> 'email', '')), ''), connected_at = now(), connected_by = p_admin,
         last_error = null, updated_at = now() where id;
  return app.calendar_google_state(p_admin, '{}'::jsonb);
end $$;

create or replace function app.calendar_google_disconnect(p_admin uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
begin
  perform app.assert_admin(p_admin);
  perform app.calendar_google_token_set(null);
  update calendar_google_link set status = 'not_connected', account_email = null, connected_at = null, connected_by = null, last_error = null, updated_at = now() where id;
  -- calls waiting for a Meet link keep their Jitsi link
  update job_applications set meet_sync = null, meet_sync_since = null where meet_sync in ('create', 'update');
  update notification_outbox set send_after = now() where entity = 'job_application' and status in ('queued', 'delayed') and send_after > now()
     and code in ('applicant_booked', 'applicant_confirm');
  return app.calendar_google_state(p_admin, '{}'::jsonb);
end $$;

create or replace function app.calendar_google_state(p_admin uuid, p jsonb) returns jsonb
language plpgsql stable security definer set search_path = public, app as $$
begin
  perform app.assert_admin(p_admin);
  return (select jsonb_build_object('status', l.status, 'account_email', l.account_email, 'calendar_id', l.calendar_id, 'connected_at', l.connected_at, 'last_error', l.last_error,
            'provider', case when l.status = 'connected' then 'google' else 'jitsi' end,
            'waiting', (select count(*) from job_applications where meet_sync is not null)) from calendar_google_link l);
end $$;

-- ================================================================ the link choice on booking, moving and cancelling
create or replace function app.job_application_meet() returns trigger
language plpgsql security definer set search_path = public, app as $$
begin
  if new.meet_url is not null and new.meet_url like 'https://meet.jit.si/%' and new.meet_url is distinct from old.meet_url then
    new.meet_provider := 'jitsi';
    if app.meet_connected() then
      -- booked or moved: the calendar job makes (or moves) the Meet event; the Jitsi link stays as the fallback until then
      new.meet_sync := case when new.meet_event_id is null then 'create' else 'update' end;
      new.meet_sync_since := now(); new.meet_error := null;
    end if;
  elsif new.slot_id is null and old.slot_id is not null then
    -- cancelled: the event goes too
    new.meet_sync := case when coalesce(new.meet_event_id, old.meet_event_id) is not null and app.meet_connected() then 'delete' end;
    new.meet_sync_since := case when new.meet_sync is not null then now() end;
    if new.meet_sync is null then new.meet_event_id := null; end if;
  end if;
  return new;
end $$;
drop trigger if exists job_applications_meet on job_applications;
create trigger job_applications_meet before update of meet_url, slot_id on job_applications for each row execute function app.job_application_meet();

-- the confirmation of a call waiting for its Meet link waits for it (at most meet_hold_minutes)
create or replace function app.outbox_wait_meet() returns trigger
language plpgsql security definer set search_path = public, app as $$
begin
  if new.entity = 'job_application' and new.code in ('applicant_booked', 'applicant_confirm')
     and exists (select 1 from job_applications a where a.id::text = new.entity_id::text and a.meet_sync in ('create', 'update')) then
    new.send_after := greatest(coalesce(new.send_after, now()), now() + make_interval(mins => (app.settings()).meet_hold_minutes));
  end if;
  return new;
end $$;
drop trigger if exists outbox_wait_meet on notification_outbox;
create trigger outbox_wait_meet before insert on notification_outbox for each row execute function app.outbox_wait_meet();

-- ================================================================ the job
-- what the calendar job has to do: the calls, their times and the token (the server only)
create or replace function public.server_hiring_meet_due() returns jsonb
language sql stable security definer set search_path = public, app as $$
  select jsonb_build_object('connected', app.meet_connected(), 'calendar_id', (select calendar_id from calendar_google_link),
    'refresh_token', case when app.meet_connected() and exists (select 1 from job_applications where meet_sync is not null) then app.calendar_google_token() end,
    'calls', coalesce((select jsonb_agg(jsonb_build_object('id', a.id, 'sync', a.meet_sync, 'event_id', a.meet_event_id, 'starts_at', s.starts_at, 'ends_at', s.ends_at,
                 'title', 'Interview call: ' || coalesce(r.short_title, r.title, 'CarmaCars') || ' (' || app.hiring_first_name(a.full_name) || ')', 'email', a.email) order by a.meet_sync_since)
        from job_applications a left join interview_slots s on s.id = a.slot_id left join hiring_roles r on r.id = a.role_id
       where a.meet_sync is not null and app.meet_connected()), '[]'::jsonb))
$$;

-- p: id, ok, event_id, meet_url, error. The Meet link onto the call and into its waiting emails (sent at once); a failure
-- keeps the Jitsi link and lets the emails go.
create or replace function public.server_hiring_meet_done(p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare a job_applications; v_url text := nullif(btrim(coalesce(p ->> 'meet_url', '')), '');
begin
  select * into a from job_applications where id = nullif(p ->> 'id', '')::uuid for update;
  if a.id is null or a.meet_sync is null then return jsonb_build_object('ok', false, 'reason', 'nothing to do'); end if;
  if v_url is not null and v_url !~ '^https://meet\.google\.com/[a-z0-9-]+$' then raise exception 'Not a Google Meet link' using errcode = '22023'; end if;
  if a.meet_sync = 'delete' then
    update job_applications set meet_sync = null, meet_sync_since = null, meet_event_id = null, meet_provider = null,
           meet_error = case when coalesce((p ->> 'ok')::boolean, false) then null else left(p ->> 'error', 300) end where id = a.id;
    return jsonb_build_object('ok', true);
  end if;
  if coalesce((p ->> 'ok')::boolean, false) and v_url is not null then
    update job_applications set meet_url = v_url, meet_provider = 'google', meet_event_id = nullif(p ->> 'event_id', ''), meet_sync = null, meet_sync_since = null, meet_error = null
     where id = a.id;
    update notification_outbox set payload = jsonb_set(payload, '{meet_url}', to_jsonb(v_url)), send_after = now()
     where entity = 'job_application' and entity_id::text = a.id::text and status in ('queued', 'delayed') and code in ('applicant_booked', 'applicant_confirm', 'applicant_reminder');
  else
    update job_applications set meet_sync = null, meet_sync_since = null, meet_error = left(coalesce(p ->> 'error', 'Google refused the event'), 300) where id = a.id;
    update notification_outbox set send_after = now() where entity = 'job_application' and entity_id::text = a.id::text and status in ('queued', 'delayed') and send_after > now()
       and code in ('applicant_booked', 'applicant_confirm');
    update calendar_google_link set last_error = left(coalesce(p ->> 'error', 'Google refused the event'), 300), updated_at = now() where id;
  end if;
  return jsonb_build_object('ok', true);
end $$;

-- the Worker's tick runs the job only while a call waits
alter function app.server_jobs_due() rename to server_jobs_due_pre2303;
create function app.server_jobs_due() returns jsonb
language plpgsql volatile security definer set search_path = public, app as $$
declare v jsonb := app.server_jobs_due_pre2303();
begin
  return v || jsonb_build_object('meet', app.meet_connected() and exists (select 1 from job_applications where meet_sync is not null));
end $$;

-- ================================================================ the door (Admin > Hiring)
create function pg_temp.copy_grants(p_new regprocedure, p_old regprocedure) returns void
language plpgsql as $$
declare g text;
begin
  execute format('revoke all on function %s from public, anon, authenticated', p_new);
  foreach g in array array['anon', 'authenticated', 'service_role'] loop
    if has_function_privilege(g, p_old, 'execute') then execute format('grant execute on function %s to %I', p_new, g); end if;
  end loop;
end $$;
select pg_temp.copy_grants('app.server_jobs_due()'::regprocedure, 'app.server_jobs_due_pre2303()'::regprocedure);

alter function app.door(uuid, text, text, text, jsonb) rename to door_pre2303;
create function app.door(p_user uuid, p_aal text, p_call text, p_name text, p jsonb default '{}'::jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
begin
  if (p_call = 'admin_read' and p_name = 'calendar_google_state') or (p_call = 'admin_do' and p_name in ('calendar_google_connect', 'calendar_google_disconnect')) then
    perform app.door_begin(p_user, p_aal);
    return case p_name when 'calendar_google_state' then app.calendar_google_state(p_user, coalesce(p, '{}'::jsonb))
                       when 'calendar_google_connect' then app.calendar_google_connect(p_user, coalesce(p, '{}'::jsonb))
                       else app.calendar_google_disconnect(p_user, coalesce(p, '{}'::jsonb)) end;
  end if;
  return app.door_pre2303(p_user, p_aal, p_call, p_name, p);
end $$;
select pg_temp.copy_grants('app.door(uuid, text, text, text, jsonb)'::regprocedure, 'app.door_pre2303(uuid, text, text, text, jsonb)'::regprocedure);

do $$
declare f record;
begin
  for f in
    select p.oid::regprocedure as sig from pg_proc p join pg_namespace n on n.oid = p.pronamespace
     where (n.nspname = 'app' and p.proname = any (array['calendar_google_token_set', 'calendar_google_token', 'meet_connected', 'calendar_google_connect',
              'calendar_google_disconnect', 'calendar_google_state', 'job_application_meet', 'outbox_wait_meet', 'door_pre2303', 'server_jobs_due_pre2303']))
        or (n.nspname = 'public' and p.proname = any (array['server_hiring_meet_due', 'server_hiring_meet_done']))
  loop
    execute format('revoke all on function %s from public, anon, authenticated', f.sig);
    execute format('grant execute on function %s to service_role', f.sig);
  end loop;
end $$;
