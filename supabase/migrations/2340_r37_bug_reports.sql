-- 2340_r37_bug_reports.sql (release 37)
-- The owner, November 11, 2026: "a bug report thing for staff so that when they report a bug with a detailed description as
-- to what's wrong and a screenshot, you're able to see the log and work from there directly."
--   1. bug_reports: what happened (30 characters at least), what they expected, the steps, the severity (blocks work,
--      annoying, cosmetic), the page (path only, never a query string), the context the browser attached (viewport, browser,
--      build, schema, role), its last 50 console errors and failed calls (redacted in the browser and again on the server),
--      and its screenshots (private documents bucket, bug-reports/<id>/<file>). Status new, triaged, fixed or won't fix,
--      the Admin's notes and the release that fixed it.
--   2. Who: any active staff member (office or field) and an Admin report; staff read their own, an Admin reads and
--      triages every one (row level security says the same for a signed-in session).
--   3. Alerts: "blocks work" alerts the Admins at once (staff alert rule staff_bug_report_urgent, urgent); the others go in
--      the Admins' morning digest.
--   4. The server's side: a report carries the crashes recorded for that person (client_errors now keeps who was signed in)
--      and on that page around that time, and the person's failed connector calls.
--   5. The door: ops_read/va_read bug_reports {id?, status?, since?}; ops_do/va_do bug_report_create, bug_report_update.
--   6. The connector (0562): bug_reports_list {status, since} and bug_report_get {id} (admin:read), bug_report_update
--      {id, status, note, fixed_in} (admin:write: previewed, then confirmed), each logged in api_calls. The web layer turns
--      the screenshot paths into links that expire in ten minutes. Nothing is ever posted to GitHub (public repository).

create function pg_temp.copy_grants(p_new regprocedure, p_old regprocedure) returns void
language plpgsql as $$
declare g text;
begin
  execute format('revoke all on function %s from public, anon, authenticated', p_new);
  foreach g in array array['anon', 'authenticated', 'service_role'] loop
    if has_function_privilege(g, p_old, 'execute') then execute format('grant execute on function %s to %I', p_new, g); end if;
  end loop;
end $$;

-- ================================================================ 1. the table
create table if not exists bug_reports (
  id                uuid primary key default gen_random_uuid(),
  number            bigint generated always as identity unique,
  reporter_id       uuid not null references users (id) on delete cascade,
  portal            text not null default 'staff' check (portal in ('admin', 'staff', 'field')),
  happened          text not null check (char_length(btrim(happened)) between 30 and 4000),
  expected          text check (char_length(expected) <= 2000),
  steps             text check (char_length(steps) <= 4000),
  severity          text not null check (severity in ('blocks_work', 'annoying', 'cosmetic')),
  page_path         text not null check (char_length(page_path) between 1 and 500 and page_path !~ '[?#]'),
  context           jsonb not null default '{}'::jsonb check (jsonb_typeof(context) = 'object' and pg_column_size(context) <= 16384),
  client_logs       jsonb not null default '[]'::jsonb check (jsonb_typeof(client_logs) = 'array' and jsonb_array_length(client_logs) <= 50 and pg_column_size(client_logs) <= 65536),
  screenshots       jsonb not null default '[]'::jsonb check (jsonb_typeof(screenshots) = 'array' and jsonb_array_length(screenshots) <= 6),
  status            text not null default 'new' check (status in ('new', 'triaged', 'fixed', 'wont_fix')),
  admin_notes       text check (char_length(admin_notes) <= 8000),
  fixed_in          text check (char_length(fixed_in) <= 40),
  status_changed_at timestamptz,
  status_changed_by uuid references users (id) on delete set null,
  created_at        timestamptz not null default now(),
  updated_at        timestamptz not null default now()
);
comment on table bug_reports is 'Bug reports from staff and Admins (2340): description, severity, page, browser context, the last client errors and failed calls (redacted), screenshots in the private documents bucket (bug-reports/<id>/). Staff read their own; an Admin triages.';
create index if not exists bug_reports_status_idx on bug_reports (status, created_at desc);
create index if not exists bug_reports_reporter_idx on bug_reports (reporter_id, created_at desc);
drop trigger if exists bug_reports_updated on bug_reports;
create trigger bug_reports_updated before update on bug_reports for each row execute function app.set_updated_at();
drop trigger if exists audit_bug_reports on bug_reports;
create trigger audit_bug_reports after insert or update or delete on bug_reports for each row execute function app.audit_row();

-- who may report: an active Admin, office staff or field staff
create or replace function app.bug_report_may(p_user uuid) returns boolean
language sql stable security definer set search_path = public, app as $$
  select p_user is not null and (app.user_is_admin(p_user) or app.user_is_staff(p_user) or coalesce(app.user_is_field(p_user), false))
$$;

alter table bug_reports enable row level security;
drop policy if exists admin_all on bug_reports;
create policy admin_all on bug_reports for all to authenticated using (app.is_admin()) with check (app.is_admin());
drop policy if exists own_read on bug_reports;
create policy own_read on bug_reports for select to authenticated using (reporter_id = app.uid());
drop policy if exists own_insert on bug_reports;
create policy own_insert on bug_reports for insert to authenticated
  with check (reporter_id = app.uid() and app.bug_report_may(app.uid()) and status = 'new' and admin_notes is null and fixed_in is null and status_changed_by is null);
revoke all on bug_reports from public, anon, authenticated;
grant select, insert on bug_reports to authenticated;
grant update, delete on bug_reports to authenticated; -- only the admin_all policy lets a row through
grant all on bug_reports to service_role;

-- ================================================================ 2. who was signed in when a page crashed
alter table client_errors add column if not exists user_id uuid references users (id) on delete set null
  default nullif(current_setting('app.client_error_user', true), '')::uuid;
create index if not exists client_errors_user_idx on client_errors (user_id, created_at desc) where user_id is not null;
comment on column client_errors.user_id is 'The signed-in person whose browser reported the crash, when there was one (2340): read by bug reports.';

alter function public.server_client_error(jsonb) rename to server_client_error_pre2340;
create function public.server_client_error(p jsonb) returns text
language plpgsql security definer set search_path = public, app as $$
declare v_user uuid := case when coalesce(p ->> 'user_id', '') ~ '^[0-9a-f-]{36}$' then (p ->> 'user_id')::uuid end;
begin
  if v_user is not null and exists (select 1 from users where id = v_user) then perform set_config('app.client_error_user', v_user::text, true); end if;
  return public.server_client_error_pre2340(p - 'user_id');
end $$;
select pg_temp.copy_grants('public.server_client_error(jsonb)'::regprocedure, 'public.server_client_error_pre2340(jsonb)'::regprocedure);

-- ================================================================ 3. the alert rule
insert into staff_alert_rules (rule, label, grp, who, tier, topic, wired, fixed, hint, sort) values
  ('staff_bug_report_urgent', 'A bug blocks someone''s work', 'Staff', '{admin}', 'urgent', 'alerts', true, false,
   'A staff member reported a bug with severity "blocks work" (2340). Other bug reports go in the morning digest.', 167)
on conflict (rule) do nothing;

-- ================================================================ 4. reads
-- the server's side of one report: the person's crashes, the page's crashes around then, the person's failed connector calls
create or replace function app.bug_report_server_errors(p_id uuid) returns jsonb
language sql stable security definer set search_path = public, app as $$
  select jsonb_build_object(
    'window', jsonb_build_object('from', b.created_at - interval '2 hours', 'to', b.created_at + interval '10 minutes'),
    'client_errors_of_reporter', coalesce((select jsonb_agg(jsonb_build_object('at', e.created_at, 'path', e.path, 'message', e.message, 'digest', e.digest, 'stack', left(e.stack, 1500)) order by e.created_at desc)
        from (select * from client_errors e where e.user_id = b.reporter_id and e.created_at between b.created_at - interval '2 hours' and b.created_at + interval '10 minutes' order by e.created_at desc limit 30) e), '[]'::jsonb),
    'client_errors_on_page', coalesce((select jsonb_agg(jsonb_build_object('at', e.created_at, 'message', e.message, 'digest', e.digest, 'same_person', e.user_id = b.reporter_id) order by e.created_at desc)
        from (select * from client_errors e where e.path = b.page_path and e.created_at between b.created_at - interval '30 minutes' and b.created_at + interval '10 minutes' order by e.created_at desc limit 10) e), '[]'::jsonb),
    'failed_api_calls', coalesce((select jsonb_agg(jsonb_build_object('at', c.created_at, 'tool', c.tool, 'target', c.target, 'error', c.error) order by c.created_at desc)
        from (select * from api_calls c where c.user_id = b.reporter_id and not c.ok and c.created_at between b.created_at - interval '2 hours' and b.created_at + interval '10 minutes' order by c.created_at desc limit 20) c), '[]'::jsonb))
  from bug_reports b where b.id = p_id
$$;

create or replace function app.bug_report_row(b bug_reports, p_full boolean) returns jsonb
language sql stable security definer set search_path = public, app as $$
  select jsonb_build_object('id', b.id, 'number', 'BR-' || b.number, 'status', b.status, 'severity', b.severity, 'portal', b.portal, 'page_path', b.page_path,
      'happened', case when p_full then b.happened else left(b.happened, 200) end, 'created_at', b.created_at, 'updated_at', b.updated_at,
      'fixed_in', b.fixed_in, 'status_changed_at', b.status_changed_at, 'screenshot_count', jsonb_array_length(b.screenshots),
      'reporter', (select jsonb_build_object('id', u.id, 'name', coalesce(u.full_name, u.email)) from users u where u.id = b.reporter_id),
      'admin_path', '/admin/bug-reports/' || b.id)
    || case when p_full then jsonb_build_object('expected', b.expected, 'steps', b.steps, 'context', b.context, 'client_logs', b.client_logs,
           'screenshots', b.screenshots, 'admin_notes', b.admin_notes) else '{}'::jsonb end
$$;

-- p: id (one report: its reporter or an Admin; the server's errors for an Admin), or a list: an Admin sees every report
-- (status, since, mine), anyone else their own
create or replace function app.bug_reports_read(p_by uuid, p jsonb) returns jsonb
language plpgsql stable security definer set search_path = public, app as $$
declare
  b bug_reports;
  v_admin boolean := app.user_is_admin(p_by);
  v_status text := nullif(p ->> 'status', '');
  v_since timestamptz := nullif(p ->> 'since', '')::timestamptz;
  v_mine boolean := coalesce((p ->> 'mine')::boolean, false) or not v_admin;
begin
  if not app.bug_report_may(p_by) then raise exception 'Bug reports are for staff' using errcode = '42501'; end if;
  if v_status is not null and v_status not in ('new', 'triaged', 'fixed', 'wont_fix', 'open') then raise exception 'status: new, triaged, fixed, wont_fix or open' using errcode = '22023'; end if;
  if nullif(p ->> 'id', '') is not null then
    select * into b from bug_reports where id::text = p ->> 'id' or 'BR-' || number = upper(btrim(p ->> 'id'));
    if b.id is null or (not v_admin and b.reporter_id <> p_by) then raise exception 'No such bug report' using errcode = 'P0002'; end if;
    return app.bug_report_row(b, true) || case when v_admin then jsonb_build_object('server_errors', app.bug_report_server_errors(b.id)) else '{}'::jsonb end;
  end if;
  return jsonb_build_object('reports', coalesce((select jsonb_agg(app.bug_report_row(q.r, false) order by (q.r).created_at desc)
      from (select x as r from bug_reports x
             where (not v_mine or x.reporter_id = p_by)
               and (v_status is null or (v_status = 'open' and x.status in ('new', 'triaged')) or x.status = v_status)
               and (v_since is null or x.created_at >= v_since)
             order by x.created_at desc limit least(greatest(coalesce((p ->> 'limit')::int, 100), 1), 200)) q), '[]'::jsonb),
    'counts', (select jsonb_build_object('new', count(*) filter (where status = 'new'), 'triaged', count(*) filter (where status = 'triaged'),
                 'fixed', count(*) filter (where status = 'fixed'), 'wont_fix', count(*) filter (where status = 'wont_fix'))
                 from bug_reports x where not v_mine or x.reporter_id = p_by));
end $$;

-- ================================================================ 5. writes
-- p: id (made by the web layer, which stored the screenshots under bug-reports/<id>/), happened, expected, steps, severity,
-- page_path, portal, context, client_logs, screenshots [{path, mime, bytes, kind}]
create or replace function app.bug_report_create(p_by uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  b bug_reports;
  v_id uuid := coalesce(nullif(p ->> 'id', '')::uuid, gen_random_uuid());
  v_shots jsonb := coalesce(p -> 'screenshots', '[]'::jsonb);
  v_logs jsonb := coalesce(p -> 'client_logs', '[]'::jsonb);
  v_sev text := coalesce(p ->> 'severity', '');
  v_title text;
  s jsonb;
begin
  if not app.bug_report_may(p_by) then raise exception 'Bug reports are for staff' using errcode = '42501'; end if;
  if char_length(btrim(coalesce(p ->> 'happened', ''))) < 30 then raise exception 'Describe what happened in at least 30 characters' using errcode = '22023'; end if;
  if v_sev not in ('blocks_work', 'annoying', 'cosmetic') then raise exception 'Choose how bad it is: blocks work, annoying or cosmetic' using errcode = '22023'; end if;
  if jsonb_typeof(v_shots) <> 'array' or jsonb_typeof(v_logs) <> 'array' then raise exception 'screenshots and client_logs are lists' using errcode = '22023'; end if;
  for s in select * from jsonb_array_elements(v_shots) loop
    if coalesce(s ->> 'path', '') !~ ('^bug-reports/' || v_id || '/[0-9a-f-]{36}\.(png|jpg|webp)$') then raise exception 'A screenshot is not in this report''s folder' using errcode = '22023'; end if;
    if coalesce(s ->> 'mime', '') not in ('image/png', 'image/jpeg', 'image/webp') or coalesce((s ->> 'bytes')::bigint, 0) not between 1 and 5 * 1024 * 1024 then
      raise exception 'Screenshots are PNG, JPEG or WebP images under 5 MB' using errcode = '22023';
    end if;
  end loop;
  -- at most 20 a day each: a loop in a browser cannot flood the Admins
  if (select count(*) from bug_reports where reporter_id = p_by and created_at > now() - interval '1 day') >= 20 then
    raise exception 'That is 20 bug reports today: an Admin will look at them first' using errcode = '54000';
  end if;
  insert into bug_reports (id, reporter_id, portal, happened, expected, steps, severity, page_path, context, client_logs, screenshots)
  values (v_id, p_by, case when p ->> 'portal' in ('admin', 'staff', 'field') then p ->> 'portal' else 'staff' end,
          btrim(p ->> 'happened'), nullif(left(btrim(coalesce(p ->> 'expected', '')), 2000), ''), nullif(left(btrim(coalesce(p ->> 'steps', '')), 4000), ''), v_sev,
          coalesce(nullif(left(split_part(split_part(coalesce(p ->> 'page_path', ''), '?', 1), '#', 1), 500), ''), '/'),
          (case when jsonb_typeof(p -> 'context') = 'object' then p -> 'context' else '{}'::jsonb end)
            || jsonb_build_object('roles', (select coalesce(jsonb_agg(r.role order by r.role), '[]'::jsonb) from user_roles r where r.user_id = p_by),
                                  'functions', (select to_jsonb(sp.functions) from staff_profiles sp where sp.user_id = p_by),
                                  'va_function', (select sp.va_function from staff_profiles sp where sp.user_id = p_by)),
          (select coalesce(jsonb_agg(x), '[]'::jsonb) from (select x from jsonb_array_elements(v_logs) x limit 50) q),
          v_shots)
  returning * into b;
  v_title := left(format('Bug BR-%s (%s) from %s: %s', b.number, replace(b.severity, '_', ' '),
                         coalesce((select coalesce(u.full_name, u.email) from users u where u.id = p_by), 'staff'), b.happened), 140);
  if b.severity = 'blocks_work' then
    perform app.staff_alert('staff_bug_report_urgent', 'bug_report', b.id, 'new', v_title, left('On ' || b.page_path || '. ' || b.happened, 240),
      jsonb_build_object('path_admin', '/admin/bug-reports/' || b.id));
  else
    insert into staff_digest_items (role, code, digest_slot, line, meta, url, entity, entity_id, dedupe_key)
    values ('admin', 'staff_site_alert', 'morning', left(v_title, 300), 'On ' || left(b.page_path, 120),
            rtrim((app.settings()).notify_base_url, '/') || '/admin/bug-reports/' || b.id, 'bug_report', b.id, 'bug_report:' || b.id)
    on conflict (dedupe_key) do nothing;
  end if;
  return app.bug_report_row(b, false);
end $$;

-- p: id, status?, note? (added to the notes with the date), fixed_in?  (an Admin only)
create or replace function app.bug_report_update(p_by uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  b bug_reports;
  v_status text := nullif(p ->> 'status', '');
  v_note text := nullif(btrim(coalesce(p ->> 'note', '')), '');
  v_fixed text := nullif(btrim(coalesce(p ->> 'fixed_in', '')), '');
begin
  if not app.user_is_admin(p_by) then raise exception 'An Admin triages bug reports' using errcode = '42501'; end if;
  if v_status is not null and v_status not in ('new', 'triaged', 'fixed', 'wont_fix') then raise exception 'status: new, triaged, fixed or wont_fix' using errcode = '22023'; end if;
  if v_status is null and v_note is null and v_fixed is null then raise exception 'Nothing to change: give a status, a note or fixed_in' using errcode = '22023'; end if;
  select * into b from bug_reports where id::text = p ->> 'id' or 'BR-' || number = upper(btrim(coalesce(p ->> 'id', ''))) for update;
  if b.id is null then raise exception 'No such bug report' using errcode = 'P0002'; end if;
  update bug_reports
     set status = coalesce(v_status, status),
         status_changed_at = case when v_status is not null and v_status <> b.status then now() else status_changed_at end,
         status_changed_by = case when v_status is not null and v_status <> b.status then p_by else status_changed_by end,
         fixed_in = coalesce(left(v_fixed, 40), fixed_in),
         admin_notes = case when v_note is null then admin_notes
                            else left(concat_ws(E'\n', admin_notes, to_char(now() at time zone 'America/Toronto', 'YYYY-MM-DD HH24:MI') || ' ' || left(v_note, 2000)), 8000) end
   where id = b.id returning * into b;
  return app.bug_report_row(b, true);
end $$;

-- ================================================================ 6. the door
alter function app.door(uuid, text, text, text, jsonb) rename to door_pre2340;
create function app.door(p_user uuid, p_aal text, p_call text, p_name text, p jsonb default '{}'::jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
begin
  if (p_call in ('ops_read', 'va_read', 'admin_read') and p_name = 'bug_reports') or (p_call in ('ops_do', 'va_do', 'admin_do') and p_name in ('bug_report_create', 'bug_report_update')) then
    if coalesce(p, '{}'::jsonb) ? '_va' then perform set_config('app.va_active', coalesce(p ->> '_va', ''), true); end if;
    perform app.door_begin(p_user, p_aal);
    p := coalesce(p, '{}'::jsonb) - '_va';
    return case p_name when 'bug_reports' then app.bug_reports_read(p_user, p) when 'bug_report_create' then app.bug_report_create(p_user, p)
                       else app.bug_report_update(p_user, p) end;
  end if;
  return app.door_pre2340(p_user, p_aal, p_call, p_name, p);
end $$;
select pg_temp.copy_grants('app.door(uuid, text, text, text, jsonb)'::regprocedure, 'app.door_pre2340(uuid, text, text, text, jsonb)'::regprocedure);

-- ================================================================ 7. the connector
alter function app.api_call(text, text, jsonb, text) rename to api_call_pre2340;
create function app.api_call(p_hash text, p_tool text, p_args jsonb, p_client text default null) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  a jsonb := case when jsonb_typeof(p_args) = 'object' then p_args else '{}'::jsonb end;
  v_write boolean := p_tool = 'bug_report_update';
  chk jsonb;
  k api_keys;
  v_args jsonb;
  v_confirm boolean;
  pv api_previews;
  v_before jsonb;
  v_target text;
  v_result jsonb;
begin
  if p_tool not in ('bug_reports_list', 'bug_report_get', 'bug_report_update') then return app.api_call_pre2340(p_hash, p_tool, p_args, p_client); end if;
  chk := app.api_key_check(p_hash, case when v_write then 'admin:write' else 'admin:read' end, p_tool, a, p_client);
  if not (chk ->> 'ok')::boolean then return chk; end if;
  k := jsonb_populate_record(null::api_keys, chk -> 'key');
  perform app.door_begin(k.user_id, 'aal2');
  v_confirm := coalesce((a ->> 'confirm')::boolean, false);
  v_args := a - 'confirm' - 'preview_id';
  v_target := left(coalesce(v_args ->> 'id', v_args ->> 'status', p_tool), 200);
  begin
    if p_tool = 'bug_reports_list' then
      v_result := app.bug_reports_read(k.user_id, jsonb_build_object('status', coalesce(nullif(v_args ->> 'status', ''), 'open'), 'since', v_args ->> 'since', 'limit', v_args ->> 'limit'));
    elsif p_tool = 'bug_report_get' then
      if nullif(v_args ->> 'id', '') is null then raise exception 'id: the bug report (BR-... or its id)' using errcode = '22023'; end if;
      v_result := app.bug_reports_read(k.user_id, jsonb_build_object('id', v_args ->> 'id'));
      v_target := v_result ->> 'number';
    else
      v_before := (select jsonb_build_object('number', 'BR-' || b.number, 'status', b.status, 'fixed_in', b.fixed_in) from bug_reports b
                    where b.id::text = v_args ->> 'id' or 'BR-' || b.number = upper(btrim(coalesce(v_args ->> 'id', ''))));
      if v_before is null then raise exception 'No such bug report' using errcode = 'P0002'; end if;
      v_target := v_before ->> 'number';
      if not v_confirm then
        -- checks the arguments without keeping anything
        begin
          perform app.bug_report_update(k.user_id, v_args);
          raise exception using errcode = 'P0001', message = '__rollback__';
        exception when others then
          if sqlerrm <> '__rollback__' then raise; end if;
        end;
        insert into api_previews (key_id, user_id, tool, args, before, after) values (k.id, k.user_id, p_tool, v_args, v_before, null) returning * into pv;
        v_result := jsonb_build_object('preview', true, 'preview_id', pv.id, 'tool', p_tool, 'expires_at', pv.created_at + interval '10 minutes', 'before', v_before,
          'will_do', format('Bug report %s: %s.', v_target, concat_ws(', ',
              case when v_args ? 'status' then 'status ' || coalesce(v_before ->> 'status', '') || ' to ' || (v_args ->> 'status') end,
              case when nullif(btrim(coalesce(v_args ->> 'note', '')), '') is not null then 'add a note' end,
              case when nullif(btrim(coalesce(v_args ->> 'fixed_in', '')), '') is not null then 'fixed in ' || (v_args ->> 'fixed_in') end)),
          'next', 'Nothing was changed. To do it, call this tool again with exactly the same arguments plus "confirm": true and "preview_id": "' || pv.id || '".');
      else
        select * into pv from api_previews where id = nullif(a ->> 'preview_id', '')::uuid for update;
        if pv.id is null or pv.key_id <> k.id or pv.tool <> p_tool then raise exception 'Preview first: call without confirm, then confirm with its preview_id' using errcode = '22023'; end if;
        if pv.used_at is not null then raise exception 'This preview was already used: preview again' using errcode = '22023'; end if;
        if pv.created_at < now() - interval '10 minutes' then raise exception 'This preview is more than 10 minutes old: preview again' using errcode = '22023'; end if;
        if pv.args is distinct from v_args then raise exception 'The arguments differ from the preview: preview again with these' using errcode = '22023'; end if;
        update api_previews set used_at = now() where id = pv.id;
        v_result := jsonb_build_object('done', true, 'tool', p_tool) || app.bug_report_update(k.user_id, v_args);
      end if;
    end if;
  exception when others then
    insert into api_calls (key_id, user_id, tool, target, args, ok, error, client) values (k.id, k.user_id, p_tool, v_target, v_args, false, left(sqlerrm, 500), left(p_client, 64));
    return jsonb_build_object('ok', false, 'status', case sqlstate when 'P0002' then 404 when '42501' then 403 else 400 end, 'error', regexp_replace(sqlerrm, '^.*?ERROR:\s*', ''));
  end;
  insert into api_calls (key_id, user_id, tool, target, args, before, after, ok, client)
  values (k.id, k.user_id, case when v_write and not v_confirm then p_tool || ':preview' else p_tool end, v_target, v_args, v_before,
          case when v_write and v_confirm then jsonb_build_object('status', v_result ->> 'status', 'fixed_in', v_result ->> 'fixed_in') end, true, left(p_client, 64));
  return jsonb_build_object('ok', true, 'result', v_result);
end $$;
select pg_temp.copy_grants('app.api_call(text, text, jsonb, text)'::regprocedure, 'app.api_call_pre2340(text, text, jsonb, text)'::regprocedure);

-- ================================================================ 8. privileges
do $$
declare f record;
begin
  for f in
    select p.oid::regprocedure as sig from pg_proc p join pg_namespace n on n.oid = p.pronamespace
     where n.nspname = 'app' and p.proname = any (array['bug_report_server_errors', 'bug_report_row', 'bug_reports_read', 'bug_report_create', 'bug_report_update', 'door_pre2340', 'api_call_pre2340'])
  loop
    execute format('revoke all on function %s from public, anon, authenticated', f.sig);
    execute format('grant execute on function %s to service_role', f.sig);
  end loop;
end $$;
-- the row level security policies call it for a signed-in session
revoke all on function app.bug_report_may(uuid) from public, anon;
grant execute on function app.bug_report_may(uuid) to authenticated, service_role;

-- GUIDES 2340 START (generated by supabase/seed/2340_gen_guides.mjs from docs/guides/content; do not edit by hand)
select app.guide_release_section('admin', 'bug-reports', 'chapter', 'settings', null, 'Bug reports', 'Bugs staff report with a picture, their browser and its errors; triage them here or through Claude.',
  'Every staff portal and Admin has **Report a bug** at the top of each page. Pressing it takes a picture of the page (passwords, card fields and anything marked sensitive are hidden), then the person writes what happened (at least 30 characters), what they expected, the steps, and how bad it is: **Blocks my work**, **Annoying** or **Cosmetic**. They can add or paste more pictures (up to six, 5 MB each).

## What comes with a report
- The page (its path only, never a link''s query), the person and their roles, the browser, the screen size, the build and the schema number.
- The last 50 errors and failed calls in their browser, with emails, phone numbers, keys and tokens masked.
- On the report page: the crashes recorded for that person in the two hours before, the crashes on that page, and their failed connector calls.

## Alerts
A report that **blocks work** alerts every Admin at once (the alert rule "A bug blocks someone''s work" in Alerts settings). The others are in the morning digest.

## Triage
Open Settings, **Bug reports**: open reports first, filter by status. On a report, set the status (**New**, **Being looked at**, **Fixed**, **Won''t fix**), the release that fixed it and a note. The person sees the status in **My bug reports**.

## With Claude
The CarmaCars connector reads them: `bug_reports_list` (by status and date), `bug_report_get` (the full text, the logs and links to the pictures that expire in ten minutes) and `bug_report_update` (status, note, fixed in; previewed, then confirmed). Every call is logged. Reports are never posted to GitHub: the code is public and the pictures may show personal data.',
  '<p class="gd-p">Every staff portal and Admin has <b class="gd-ui">Report a bug</b> at the top of each page. Pressing it takes a picture of the page (passwords, card fields and anything marked sensitive are hidden), then the person writes what happened (at least 30 characters), what they expected, the steps, and how bad it is: <b class="gd-ui">Blocks my work</b>, <b class="gd-ui">Annoying</b> or <b class="gd-ui">Cosmetic</b>. They can add or paste more pictures (up to six, 5 MB each).</p><section class="gd-task" id="bug-reports-what-comes-with-a-report" data-gd-task><h2 class="gd-h2">What comes with a report</h2><ul class="gd-ul"><li>The page (its path only, never a link&#39;s query), the person and their roles, the browser, the screen size, the build and the schema number.</li><li>The last 50 errors and failed calls in their browser, with emails, phone numbers, keys and tokens masked.</li><li>On the report page: the crashes recorded for that person in the two hours before, the crashes on that page, and their failed connector calls.</li></ul></section><section class="gd-task" id="bug-reports-alerts" data-gd-task><h2 class="gd-h2">Alerts</h2><p class="gd-p">A report that <b class="gd-ui">blocks work</b> alerts every Admin at once (the alert rule &quot;A bug blocks someone&#39;s work&quot; in Alerts settings). The others are in the morning digest.</p></section><section class="gd-task" id="bug-reports-triage" data-gd-task><h2 class="gd-h2">Triage</h2><p class="gd-p">Open Settings, <b class="gd-ui">Bug reports</b>: open reports first, filter by status. On a report, set the status (<b class="gd-ui">New</b>, <b class="gd-ui">Being looked at</b>, <b class="gd-ui">Fixed</b>, <b class="gd-ui">Won&#39;t fix</b>), the release that fixed it and a note. The person sees the status in <b class="gd-ui">My bug reports</b>.</p></section><section class="gd-task" id="bug-reports-with-claude" data-gd-task><h2 class="gd-h2">With Claude</h2><p class="gd-p">The CarmaCars connector reads them: <span class="gd-url">bug_reports_list</span> (by status and date), <span class="gd-url">bug_report_get</span> (the full text, the logs and links to the pictures that expire in ten minutes) and <span class="gd-url">bug_report_update</span> (status, note, fixed in; previewed, then confirmed). Every call is logged. Reports are never posted to GitHub: the code is public and the pictures may show personal data.</p></section>');
select app.guide_release_section('va', 'start-here', 'start', null, '### Who this guide is for

CarmaCars staff in Customer service, Finance, Fleet and Sales, in the office, remote or in person. Everyone works in one staff portal: its menu shows a group for each function you hold. Read chapter 1, then the chapter for each of your functions. If you also do field work (handovers, returns, moving cars), read the Field Guide too: your jobs are under **Field work** in the same menu.

### What you need

- The invitation email from CarmaCars (the link works for 24 hours)
- A computer for your shift. The portal also works on a phone
- An authenticator app on your phone, if your Admin turns on two-step sign-in

## Your first sign-in

1. Open the invitation email and press its link within 24 hours. Choose a password of 8 characters or more and press **Save the new password**.
2. You land in your portal, on **To do**, working as your main function.
3. At the top of the page, fill in your Home address and Postal code and press **Save my home address**. You need it before you add a rental or earn a commission. Change it later under **Profile**, at the top of the menu.
4. Then on **Profile**, **Pay details**: choose how you are paid (bank account, GCash, PayPal, Wise, e-Transfer or through OnlineJobs.ph) and press **Save my pay details**. Only the last 4 digits of an account number are ever shown; an Admin confirms new details with you.
5. Next time, sign in at `carmacars.ca/sign-in` with your Email and Password, then **Sign in**.
6. Link expired? Press **Send me a new link** on the page it opens, or ask an Admin for a password link.
7. Sign in with your phone: on **Profile**, press **Add and verify my phone number** and enter the 6-digit code we text you. Then press **Use my phone number instead** on the sign-in page. Two-step sign-in still asks for your authenticator code.

![](/guides/img/public-09-sign-in-phone-1f766061.jpg "phone; size: 390 645; pins: 3 95.4 78.4")

> Good to know: Recommended: open your profile and press **Set up two-step sign-in**. Scan the code with your authenticator app, type the 6 digits and press **Continue**. After that every sign-in asks for a code.

## Stuck on a page?

If you work on a page for a few minutes without anything saving, see the same error three times, or go back and forth between the same two steps, a small box asks **Need a hand with** the page. **Open the guide section** opens this guide at the chapter for that page beside it (a sheet from the bottom on a phone); **Back to what I was doing** closes it and everything you typed is still there. **Open the Academy lesson** opens the lesson in a new tab. **Not now** quiets it on that page for a day.

> Good to know: When we update our terms of use, our privacy policy or an agreement you signed with us, the next time you open your portal it shows **We''ve updated our terms**: a short summary of what changed and the new text. Tick that you read it and press **Accept** to continue. It does not change an agreement you already signed or a past booking.

## Your name and password (release 34)
Open Profile. **Save my display name** changes how you are greeted, at once. Your legal name is the one on your signed agreements, so it is not edited freely: press **Request a name change**, write the full name and why, and an Admin approves it. Until then the name on file stays. To change your email, use Change my email under Sign-in; to add or change your phone, use the phone box under Sign-in (we text a code). **Change my password** sends you to the password page.', 'Start here', 'Who this is for and your first sign-in.',
  '### Who this guide is for

CarmaCars staff in Customer service, Finance, Fleet and Sales, in the office, remote or in person. Everyone works in one staff portal: its menu shows a group for each function you hold. Read chapter 1, then the chapter for each of your functions. If you also do field work (handovers, returns, moving cars), read the Field Guide too: your jobs are under **Field work** in the same menu.

### What you need

- The invitation email from CarmaCars (the link works for 24 hours)
- A computer for your shift. The portal also works on a phone
- An authenticator app on your phone, if your Admin turns on two-step sign-in

## Your first sign-in

1. Open the invitation email and press its link within 24 hours. Choose a password of 8 characters or more and press **Save the new password**.
2. You land in your portal, on **To do**, working as your main function.
3. At the top of the page, fill in your Home address and Postal code and press **Save my home address**. You need it before you add a rental or earn a commission. Change it later under **Profile**, at the top of the menu.
4. Then on **Profile**, **Pay details**: choose how you are paid (bank account, GCash, PayPal, Wise, e-Transfer or through OnlineJobs.ph) and press **Save my pay details**. Only the last 4 digits of an account number are ever shown; an Admin confirms new details with you.
5. Next time, sign in at `carmacars.ca/sign-in` with your Email and Password, then **Sign in**.
6. Link expired? Press **Send me a new link** on the page it opens, or ask an Admin for a password link.
7. Sign in with your phone: on **Profile**, press **Add and verify my phone number** and enter the 6-digit code we text you. Then press **Use my phone number instead** on the sign-in page. Two-step sign-in still asks for your authenticator code.

![](/guides/img/public-09-sign-in-phone-1f766061.jpg "phone; size: 390 645; pins: 3 95.4 78.4")

> Good to know: Recommended: open your profile and press **Set up two-step sign-in**. Scan the code with your authenticator app, type the 6 digits and press **Continue**. After that every sign-in asks for a code.

## Stuck on a page?

If you work on a page for a few minutes without anything saving, see the same error three times, or go back and forth between the same two steps, a small box asks **Need a hand with** the page. **Open the guide section** opens this guide at the chapter for that page beside it (a sheet from the bottom on a phone); **Back to what I was doing** closes it and everything you typed is still there. **Open the Academy lesson** opens the lesson in a new tab. **Not now** quiets it on that page for a day.

> Good to know: When we update our terms of use, our privacy policy or an agreement you signed with us, the next time you open your portal it shows **We''ve updated our terms**: a short summary of what changed and the new text. Tick that you read it and press **Accept** to continue. It does not change an agreement you already signed or a past booking.

## Your name and password (release 34)
Open Profile. **Save my display name** changes how you are greeted, at once. Your legal name is the one on your signed agreements, so it is not edited freely: press **Request a name change**, write the full name and why, and an Admin approves it. Until then the name on file stays. To change your email, use Change my email under Sign-in; to add or change your phone, use the phone box under Sign-in (we text a code). **Change my password** sends you to the password page.

## Report a bug (release 37)
Something not working? Press **Report a bug** at the top of any page. A picture of the page is taken first (passwords and card fields are hidden); write what happened (at least 30 characters), what you expected and the steps if you know them, choose how bad it is (**Blocks my work** alerts the Admins at once) and add or paste more pictures. The page, your browser and its recent errors go with it. **My bug reports** shows each report and its status: new, being looked at, fixed or won''t fix.',
  '<h3 class="gd-h3">Who this guide is for</h3><p class="gd-p">CarmaCars staff in Customer service, Finance, Fleet and Sales, in the office, remote or in person. Everyone works in one staff portal: its menu shows a group for each function you hold. Read chapter 1, then the chapter for each of your functions. If you also do field work (handovers, returns, moving cars), read the Field Guide too: your jobs are under <b class="gd-ui">Field work</b> in the same menu.</p><h3 class="gd-h3">What you need</h3><ul class="gd-ul"><li>The invitation email from CarmaCars (the link works for 24 hours)</li><li>A computer for your shift. The portal also works on a phone</li><li>An authenticator app on your phone, if your Admin turns on two-step sign-in</li></ul><section class="gd-task" id="start-here-your-first-sign-in" data-gd-task><h2 class="gd-h2">Your first sign-in</h2><div class="gd-stepblock gd-stepblock--side"><div class="gd-stepcol"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">Open the invitation email and press its link within 24 hours. Choose a password of 8 characters or more and press <b class="gd-ui">Save the new password</b>.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">You land in your portal, on <b class="gd-ui">To do</b>, working as your main function.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">At the top of the page, fill in your Home address and Postal code and press <b class="gd-ui">Save my home address</b>. You need it before you add a rental or earn a commission. Change it later under <b class="gd-ui">Profile</b>, at the top of the menu.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t">Then on <b class="gd-ui">Profile</b>, <b class="gd-ui">Pay details</b>: choose how you are paid (bank account, GCash, PayPal, Wise, e-Transfer or through OnlineJobs.ph) and press <b class="gd-ui">Save my pay details</b>. Only the last 4 digits of an account number are ever shown; an Admin confirms new details with you.</div></li><li><span class="gd-n" aria-hidden="true">5</span><div class="gd-t">Next time, sign in at <span class="gd-url">carmacars.ca/sign-in</span> with your Email and Password, then <b class="gd-ui">Sign in</b>.</div></li><li><span class="gd-n" aria-hidden="true">6</span><div class="gd-t">Link expired? Press <b class="gd-ui">Send me a new link</b> on the page it opens, or ask an Admin for a password link.</div></li><li><span class="gd-n" aria-hidden="true">7</span><div class="gd-t">Sign in with your phone: on <b class="gd-ui">Profile</b>, press <b class="gd-ui">Add and verify my phone number</b> and enter the 6-digit code we text you. Then press <b class="gd-ui">Use my phone number instead</b> on the sign-in page. Two-step sign-in still asks for your authenticator code.</div></li></ol></div><figure class="gd-fig gd-fig--phone"><div class="gd-phone"><div class="gd-imgwrap" style="aspect-ratio:390/645"><img src="/guides/img/public-09-sign-in-phone-1f766061.jpg" alt="" loading="lazy" decoding="async" width="390" height="645"><span class="gd-pin" style="left:95.4%;top:78.4%" aria-hidden="true">3</span></div></div></figure></div><aside class="gd-box"><span class="gd-lbl">Good to know</span><div>Recommended: open your profile and press <b class="gd-ui">Set up two-step sign-in</b>. Scan the code with your authenticator app, type the 6 digits and press <b class="gd-ui">Continue</b>. After that every sign-in asks for a code.</div></aside></section><section class="gd-task" id="start-here-stuck-on-a-page" data-gd-task><h2 class="gd-h2">Stuck on a page?</h2><p class="gd-p">If you work on a page for a few minutes without anything saving, see the same error three times, or go back and forth between the same two steps, a small box asks <b class="gd-ui">Need a hand with</b> the page. <b class="gd-ui">Open the guide section</b> opens this guide at the chapter for that page beside it (a sheet from the bottom on a phone); <b class="gd-ui">Back to what I was doing</b> closes it and everything you typed is still there. <b class="gd-ui">Open the Academy lesson</b> opens the lesson in a new tab. <b class="gd-ui">Not now</b> quiets it on that page for a day.</p><aside class="gd-box"><span class="gd-lbl">Good to know</span><div>When we update our terms of use, our privacy policy or an agreement you signed with us, the next time you open your portal it shows <b class="gd-ui">We&#39;ve updated our terms</b>: a short summary of what changed and the new text. Tick that you read it and press <b class="gd-ui">Accept</b> to continue. It does not change an agreement you already signed or a past booking.</div></aside></section><section class="gd-task" id="start-here-your-name-and-password-release-34" data-gd-task><h2 class="gd-h2">Your name and password (release 34)</h2><p class="gd-p">Open Profile. <b class="gd-ui">Save my display name</b> changes how you are greeted, at once. Your legal name is the one on your signed agreements, so it is not edited freely: press <b class="gd-ui">Request a name change</b>, write the full name and why, and an Admin approves it. Until then the name on file stays. To change your email, use Change my email under Sign-in; to add or change your phone, use the phone box under Sign-in (we text a code). <b class="gd-ui">Change my password</b> sends you to the password page.</p></section><section class="gd-task" id="start-here-report-a-bug-release-37" data-gd-task><h2 class="gd-h2">Report a bug (release 37)</h2><p class="gd-p">Something not working? Press <b class="gd-ui">Report a bug</b> at the top of any page. A picture of the page is taken first (passwords and card fields are hidden); write what happened (at least 30 characters), what you expected and the steps if you know them, choose how bad it is (<b class="gd-ui">Blocks my work</b> alerts the Admins at once) and add or paste more pictures. The page, your browser and its recent errors go with it. <b class="gd-ui">My bug reports</b> shows each report and its status: new, being looked at, fixed or won&#39;t fix.</p></section>');
select app.guide_release_section('field', 'start-here', 'start', null, '### Who this guide is for

CarmaCars field staff: drivers, detailers, and drivers who also detail. You hand cars over, take them back, move them and shoot listing photos. Everything is on your phone. Your jobs are under **Field work** in the staff portal; if you also hold another function (Sales, for example), its pages are in the same menu.

### What you need

- Your phone, charged, with a data connection (photos and signatures save as you take them)
- The invitation email from CarmaCars (the link works for 24 hours)
- A car charger and a cloth for the camera lens

## Your first sign-in

1. Open the invitation email on your phone and press its link within 24 hours. Choose a password and press **Save the new password**.
2. You land on **Today**. Next time, sign in at `carmacars.ca/sign-in` with your Email and Password.
3. In your browser''s menu, choose **Add to Home Screen**. The portal then opens full screen, like an app.
4. Open **Profile**, add your mobile number and press **Save my phone**.
5. At the top of the page, fill in your Home address and Postal code and press **Save my home address**. You need it before you add a rental or earn a commission.

![](/guides/img/field-04-profile-phone-f05000e2.jpg "phone; size: 390 920; pins: 4 92.3 78.3")

> Good to know: Recommended: on Profile, press **Set up two-step sign-in** and follow the steps with an authenticator app.

## Stuck on a page?

If you work on a page for a few minutes without anything saving, see the same error three times, or go back and forth between the same two steps, a small box asks **Need a hand with** the page. **Open the guide section** opens this guide at the right chapter in a sheet from the bottom of the screen; **Back to what I was doing** closes it and everything you typed is still there. **Open the Academy lesson** opens the lesson in a new tab. **Not now** quiets it on that page for a day. It never shows while a renter signs.

> Good to know: When we update our terms of use, our privacy policy or an agreement you signed with us, the next time you open your portal it shows **We''ve updated our terms**: a short summary of what changed and the new text. Tick that you read it and press **Accept** to continue. It does not change an agreement you already signed or a past booking.

## Your first days

Your portal opens in order: the academy (Training) first, then your staff agreement, then your jobs. Welcome shows each step and asks for the name you go by. Once both are done, Welcome and Today show the team''s WhatsApp group: join it, then press **I joined**.

## The weekly townhall (release 35)

Every Wednesday at 1:00 pm Toronto time, and everyone attends. Open **Townhall**: **Join the call** there, or **Check in** from 15 minutes before, counts you as there. You get a reminder an hour before.', 'Start here', 'Who this is for and your first sign-in.',
  '### Who this guide is for

CarmaCars field staff: drivers, detailers, and drivers who also detail. You hand cars over, take them back, move them and shoot listing photos. Everything is on your phone. Your jobs are under **Field work** in the staff portal; if you also hold another function (Sales, for example), its pages are in the same menu.

### What you need

- Your phone, charged, with a data connection (photos and signatures save as you take them)
- The invitation email from CarmaCars (the link works for 24 hours)
- A car charger and a cloth for the camera lens

## Your first sign-in

1. Open the invitation email on your phone and press its link within 24 hours. Choose a password and press **Save the new password**.
2. You land on **Today**. Next time, sign in at `carmacars.ca/sign-in` with your Email and Password.
3. In your browser''s menu, choose **Add to Home Screen**. The portal then opens full screen, like an app.
4. Open **Profile**, add your mobile number and press **Save my phone**.
5. At the top of the page, fill in your Home address and Postal code and press **Save my home address**. You need it before you add a rental or earn a commission.

![](/guides/img/field-04-profile-phone-f05000e2.jpg "phone; size: 390 920; pins: 4 92.3 78.3")

> Good to know: Recommended: on Profile, press **Set up two-step sign-in** and follow the steps with an authenticator app.

## Stuck on a page?

If you work on a page for a few minutes without anything saving, see the same error three times, or go back and forth between the same two steps, a small box asks **Need a hand with** the page. **Open the guide section** opens this guide at the right chapter in a sheet from the bottom of the screen; **Back to what I was doing** closes it and everything you typed is still there. **Open the Academy lesson** opens the lesson in a new tab. **Not now** quiets it on that page for a day. It never shows while a renter signs.

> Good to know: When we update our terms of use, our privacy policy or an agreement you signed with us, the next time you open your portal it shows **We''ve updated our terms**: a short summary of what changed and the new text. Tick that you read it and press **Accept** to continue. It does not change an agreement you already signed or a past booking.

## Your first days

Your portal opens in order: the academy (Training) first, then your staff agreement, then your jobs. Welcome shows each step and asks for the name you go by. Once both are done, Welcome and Today show the team''s WhatsApp group: join it, then press **I joined**.

## The weekly townhall (release 35)

Every Wednesday at 1:00 pm Toronto time, and everyone attends. Open **Townhall**: **Join the call** there, or **Check in** from 15 minutes before, counts you as there. You get a reminder an hour before.

## Report a bug (release 37)
Something not working? Press **Report a bug** at the top of any page. A picture of the page is taken first (passwords and card fields are hidden); write what happened (at least 30 characters), what you expected and the steps if you know them, choose how bad it is (**Blocks my work** alerts the Admins at once) and add or paste more pictures. The page, your browser and its recent errors go with it. **My bug reports** shows each report and its status: new, being looked at, fixed or won''t fix.',
  '<h3 class="gd-h3">Who this guide is for</h3><p class="gd-p">CarmaCars field staff: drivers, detailers, and drivers who also detail. You hand cars over, take them back, move them and shoot listing photos. Everything is on your phone. Your jobs are under <b class="gd-ui">Field work</b> in the staff portal; if you also hold another function (Sales, for example), its pages are in the same menu.</p><h3 class="gd-h3">What you need</h3><ul class="gd-ul"><li>Your phone, charged, with a data connection (photos and signatures save as you take them)</li><li>The invitation email from CarmaCars (the link works for 24 hours)</li><li>A car charger and a cloth for the camera lens</li></ul><section class="gd-task" id="start-here-your-first-sign-in" data-gd-task><h2 class="gd-h2">Your first sign-in</h2><div class="gd-stepblock gd-stepblock--side"><div class="gd-stepcol"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">Open the invitation email on your phone and press its link within 24 hours. Choose a password and press <b class="gd-ui">Save the new password</b>.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">You land on <b class="gd-ui">Today</b>. Next time, sign in at <span class="gd-url">carmacars.ca/sign-in</span> with your Email and Password.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">In your browser&#39;s menu, choose <b class="gd-ui">Add to Home Screen</b>. The portal then opens full screen, like an app.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t">Open <b class="gd-ui">Profile</b>, add your mobile number and press <b class="gd-ui">Save my phone</b>.</div></li><li><span class="gd-n" aria-hidden="true">5</span><div class="gd-t">At the top of the page, fill in your Home address and Postal code and press <b class="gd-ui">Save my home address</b>. You need it before you add a rental or earn a commission.</div></li></ol></div><figure class="gd-fig gd-fig--phone"><div class="gd-phone"><div class="gd-imgwrap" style="aspect-ratio:390/920"><img src="/guides/img/field-04-profile-phone-f05000e2.jpg" alt="" loading="lazy" decoding="async" width="390" height="920"><span class="gd-pin" style="left:92.3%;top:78.3%" aria-hidden="true">4</span></div></div></figure></div><aside class="gd-box"><span class="gd-lbl">Good to know</span><div>Recommended: on Profile, press <b class="gd-ui">Set up two-step sign-in</b> and follow the steps with an authenticator app.</div></aside></section><section class="gd-task" id="start-here-stuck-on-a-page" data-gd-task><h2 class="gd-h2">Stuck on a page?</h2><p class="gd-p">If you work on a page for a few minutes without anything saving, see the same error three times, or go back and forth between the same two steps, a small box asks <b class="gd-ui">Need a hand with</b> the page. <b class="gd-ui">Open the guide section</b> opens this guide at the right chapter in a sheet from the bottom of the screen; <b class="gd-ui">Back to what I was doing</b> closes it and everything you typed is still there. <b class="gd-ui">Open the Academy lesson</b> opens the lesson in a new tab. <b class="gd-ui">Not now</b> quiets it on that page for a day. It never shows while a renter signs.</p><aside class="gd-box"><span class="gd-lbl">Good to know</span><div>When we update our terms of use, our privacy policy or an agreement you signed with us, the next time you open your portal it shows <b class="gd-ui">We&#39;ve updated our terms</b>: a short summary of what changed and the new text. Tick that you read it and press <b class="gd-ui">Accept</b> to continue. It does not change an agreement you already signed or a past booking.</div></aside></section><section class="gd-task" id="start-here-your-first-days" data-gd-task><h2 class="gd-h2">Your first days</h2><p class="gd-p">Your portal opens in order: the academy (Training) first, then your staff agreement, then your jobs. Welcome shows each step and asks for the name you go by. Once both are done, Welcome and Today show the team&#39;s WhatsApp group: join it, then press <b class="gd-ui">I joined</b>.</p></section><section class="gd-task" id="start-here-the-weekly-townhall-release-35" data-gd-task><h2 class="gd-h2">The weekly townhall (release 35)</h2><p class="gd-p">Every Wednesday at 1:00 pm Toronto time, and everyone attends. Open <b class="gd-ui">Townhall</b>: <b class="gd-ui">Join the call</b> there, or <b class="gd-ui">Check in</b> from 15 minutes before, counts you as there. You get a reminder an hour before.</p></section><section class="gd-task" id="start-here-report-a-bug-release-37" data-gd-task><h2 class="gd-h2">Report a bug (release 37)</h2><p class="gd-p">Something not working? Press <b class="gd-ui">Report a bug</b> at the top of any page. A picture of the page is taken first (passwords and card fields are hidden); write what happened (at least 30 characters), what you expected and the steps if you know them, choose how bad it is (<b class="gd-ui">Blocks my work</b> alerts the Admins at once) and add or paste more pictures. The page, your browser and its recent errors go with it. <b class="gd-ui">My bug reports</b> shows each report and its status: new, being looked at, fixed or won&#39;t fix.</p></section>');
-- GUIDES 2340 END
