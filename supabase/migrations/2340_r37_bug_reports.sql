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
select app.guide_release_section('admin', 'people-and-access', 'chapter', 'getting-around-admin', 'Let people in, help them back in when they are locked out, and see exactly what they see. Every step is recorded in the audit log.

## Portals and sign-in

Open **People** > **Portals and view as**. Every portal has a card.

1. Each card links to **Its sign-in page**, the address to send that person.
2. Choose a person in the list on the card.
3. Press **Open as this person** to see that portal as they see it.

> Good to know: The site''s own test accounts (verify- addresses and Resend''s test inboxes) are marked "Test account" in People who can sign in. They sign in like anyone, but no real work is ever given to them (see Data health).

![](/guides/img/admin-27-portals-desktop-0361bf61.jpg "desktop; size: 1440 820; address: carmacars.ca/admin/portals; pins: 1 65.9 30.2, 2 58.1 39.4, 3 51.6 45.6")

## Invite a person

Invitations work for staff, field staff, owners and investors. The person gets our invitation email and chooses a password.

1. Under Invite a person, choose the Role: Staff (assistant), Field staff, Owner on file or Investor on file. Admin is not offered: only rent@carmacars.ca can be an Admin.
2. Fill in the Name and Email.
3. For staff, pick the Main function, and tick Also covers for any other function they help with. For field staff, pick the Field function.
4. Press **Invite**. The link in the email works for 24 hours.

![](/guides/img/admin-27-portals-desktop-c10725cb.jpg "desktop; size: 1230 360; address: carmacars.ca/admin/portals; pins: 1 18.8 40.8, 2 50.0 40.8, 3 18.8 66.7, 4 9.8 87.8")

> Tip: Someone who already signs in gets the new role at once, with no email. Owners and investors must be on file first: People > Owners and People > Investors also have a one-click invite for a record without a sign-in.

## Add an investor

1. Open **People** > **Investors** and press **Add an investor**.
2. Fill in the Legal name and the Type: Individual, or Corporation with the Person who signs for the corporation. Then the Email, the Phone and the Address (start typing and choose it).
3. Optional: the Amount committed, and the Yearly return offered (the investor offer''s, 30% unless you change it; the investment agreement sets the one that applies).
4. Invite now is ticked: press **Add and invite**. The record is added and the investor gets the invitation to choose a password for the investor portal. Untick it to add the record only, and invite later from the list.

## Send a password link

For anyone who forgot their password or let their invitation expire.

1. Under People who can sign in, search by name or email.
2. On their row, press **Send password link**. They get "Reset your CarmaCars password", valid for 24 hours.
3. **View as (...)** on the same row opens their portal, read only.

![](/guides/img/admin-27-portals-desktop-ee9b3e94.jpg "desktop; size: 1230 440; address: carmacars.ca/admin/portals; pins: 1 74.8 6.6, 2 68.2 28.6, 3 84.1 28.6")

## View as: see what someone sees

1. A red banner says "Viewing as Name (email), read only." on every page.
2. Click around their portal. Nothing can be changed: every save is refused.
3. Press **Exit** to come back. A view also ends by itself after 30 minutes.

![](/guides/img/admin-28-view-as-desktop-f858e38c.jpg "desktop; size: 1440 620; address: carmacars.ca/owner; pins: 1 48.6 4.5, 3 94.4 4.5")

> Watch out: Can''t change anything in Admin? You may still be viewing as someone. Look for the red banner and press Exit.

## The audit log

**Settings** > **Logs**, the **Changes** tab, shows who changed what, and when.

1. Changes lists every change with the person, the action, the table and the record. Data access lists lookups of private data.
2. Every View as is recorded (view_as_start), with the person viewed.
3. Search by table, record id or value.

![](/guides/img/admin-29-audit-desktop-b7504100.jpg "desktop; size: 1440 560; address: carmacars.ca/admin/audit; pins: 1 22.6 31.1, 2 39.0 46.4, 3 89.6 20.7")

## Staff and roles

**People** > **Team** opens Staff and roles.

1. Invite staff here too: Role, Name, Email, Main function and Also covers, then **Invite**.
2. Each row has **Send password link**, **View as (...)** and Limits (how much they may approve or refund).
3. Press **End access** to close their staff portal at once. **Restore** undoes it.

![](/guides/img/admin-26-staff-desktop-72287d0b.jpg "desktop; size: 1440 780; address: carmacars.ca/admin/settings/staff; pins: 1 20.8 59.0, 2 94.4 86.7, 3 83.3 92.6")

## Admin access

**Settings**, then Admin access. Who may hold the Admin role.

1. The list holds rent@carmacars.ca, and verify-admin@carmacars.ca, the automated test account the site''s nightly checks sign in with.
2. Below it: everyone who holds the Admin role now. Each must be on the list; the database refuses the Admin role to any other address.
3. Change the list only if the business''s Admin address changes.

## Staff scorecards

See how each assistant is doing against the targets.

1. On a staff member''s row in Staff and roles, press **Scorecard**.
2. By week shows each measure (for example quote sent within 5 minutes) and the result for each week.
3. A task meets its target when it is done by its due time. Daily checks count when done by 9:00 and 18:00.

![](/guides/img/va-sales-05-scorecard-desktop-956a5a9e.jpg "desktop; size: 1230 350; address: carmacars.ca/va/scorecard; pins: 2 21.1 42.9")

## Sales by staff member

See each person''s commissions, quotes, offers, rentals added, bookings confirmed and booked revenue.

1. On a staff member''s row in Staff and roles, press **Sales**. Press **By week** or **By month**.
2. The tiles show the current week or month. By week (or By month) lists each period: quotes created, offers sent, rentals added, bookings confirmed, conversion and booked revenue.
3. Follow-ups due lists their open deals with the next step. Deals lists each booking they created, added or sent an offer on, with what it counts.
4. A deal credited to the wrong person, or marked sourced when it was not? Press **Reassign** beside it, choose who, say whether they sourced the client, and write the reason.
5. **Commission rate** gives this person their own flat rate (empty: the Program settings). **Reverse** beside a commission stops it, for example for a household rental found later.
6. Staff enter their own home address (at their first sign-in, before they sign their agreement, or in their profile). It is needed before they add a rental or earn a commission, and spots a household rental. **Home address** here changes it if it is wrong.
7. The whole team: **Today** > **Overview**, the Sales card at the bottom. Choose another month and press **Show**.

| Figure | How it is counted |
| --- | --- |
| Credited to | Whoever created the quote or added the rental; for a website request, whoever sent its first offer. An Admin can reassign it. |
| Conversion | Of the deals credited in the period, the share confirmed so far. |
| Booked revenue | The rental charge before tax, after discounts, for bookings confirmed in the period. A cancelled booking counts only what was kept; refunds come off. |

## Sales staff: in person or remote

Each Sales person works in person (Toronto) or remote (anywhere, a contractor). Staff and roles lists them under Sales staff: in person or remote.

1. Press **Work mode** on a person (or on their Sales page), choose In person or Remote and give the reason. A new Sales person starts in person.
2. The list shows the mode, the rate now, the rate the month would end at, and for remote this month''s touches against 400, the peak hours scheduled this week (20 needed, Thursday to Sunday afternoons) and the replies on time.
3. On a remote person''s Sales page, Remote duties shows their checklist, touches, blocks and reply time. **Void** beside a touch logged by mistake takes it off, with a reason.
4. When you approve a Sales month, its mode, rates, touches and any drop are locked: a later change of mode or settings does not change it. Their My sales shows each month in one line.

|  | Rule |
| --- | --- |
| Rates | In person 10%, 15% from 50 rental days, 20% from 100. Remote 5 points lower on every tier: 5%, 10%, 15% |
| Credit | In person: walk-ins, handovers, partner visits and the rentals they source. Remote: only the rentals they source; a website request they answer with the first offer during their blocks is credited to them; a walk-in or a partner deal earns them nothing |
| Remote minimum | 400 touches a month. Under it, when the month ends, the month''s rate is one tier lower (5% becomes 2.5%). Settings > Program settings, Staff commissions, changes the minimum, the drop and the floor |

## An Admin has every staff page

An Admin account is only an Admin: it already has every page of the staff portals, so no office or field role can be added to it, and the invite form and Staff and roles refuse it. To work as staff, use a separate account. An Admin can still be given a field job and opens it on the field portal.
## Two records of one person

When two renter records are clearly the same person (the same phone verified with a code, or the same name, date of birth and phone), the site merges them by itself within 15 minutes, into the record with more bookings. Bookings, licences, cards, payments, documents and messages move. The person can then sign in with either email or with their phone number and a code, and gets one short note: "Your CarmaCars accounts are now one". A match on the name alone stays a task for you, and **Merge into this record** under the renter still works as before.

1. Open the renter. The Merged records card lists each merge, automatic or by staff, with what moved and the emails that now sign in there.
2. Two different people after all? Press **Undo** and say why. Everything moved goes back and both records are as they were.

## New staff: the academy, then the agreement, then the portal

Every staff member (never an Admin) opens their portal in this order: the academy first, then their staff agreement, then everything else. Until the academy is passed they open only the academy, the guide, their profile and **Welcome**; after it, until the agreement is signed, only Welcome, their profile and their documents to sign.

1. The agreement is sent by itself to everyone without one, filled from their record and their hire''s pay and start date: the Field Staff Agreement for field work, the contractor agreement for customer service, Fleet, Finance and Sales (in person or remote). One reminder goes 3 days after it was sent.
2. **Team** > **Staff and roles**, **Staff agreements**: who has not signed, what the automatic send waits for (for example a field hire''s licence number), and **Waive** with the reason.
3. Welcome also asks for the name they go by (the preferred name, shown across the portals and on the staff list), and, once the academy and the agreement are done, shows the team''s WhatsApp group (Program settings, **WhatsApp team group link** and **WhatsApp Sales group link**; empty until you set them). The same link goes by email, once.

## Accounts locked for inactivity

A staff account with no sign-in or use for 10 days (Program settings, **Staff inactive lock days**) is locked; the person is warned by email on day 7 and sees "Account locked for inactivity" when they sign in. You get an alert. On **Team** > **Staff and roles** the row says **Locked for inactivity**: press **Unlock**. The staff list shows each person''s last sign-in. Admin accounts are never locked.

## Hours and the townhall

**Team** > **Timesheet**: the hours customer service, Fleet and Finance clocked (Clock in and out on their home page). Add hours someone forgot, or void a wrong entry, with the reason. A person not clocked in 15 minutes after their start time (customer service 9:00, Fleet 11:00, Toronto) is reminded.

**Breaks and idle time (release 35).** Customer service, Fleet and Finance press **Start break** and **End break** next to the clock; breaks have no fixed length. On **Timesheet**, each person''s days show the hours clocked and worked, their breaks (how many, the total and the longest) and their idle time, with every break and idle stretch listed. **Edit** or **Remove** a break with the reason (in the audit log). Finance sees the breaks but never the idle time. A break open past 30 minutes reminds the person and you. Whether breaks are paid is **Program settings** > va_breaks_paid (on: salaried; off: breaks come off the hours on the payroll, where each line shows the period''s breaks).

While someone is clocked in, not on a break and within their scheduled hours, the portal notes the fact of their activity (never keys, pages or screens), at most once a minute; their actions count too. With no activity for more than va_idle_alert_minutes (10), you get one alert, "Name (role) inactive since 10:42, 12 min", and one more at va_idle_followup_minutes (30). A call they are on (their Quo user, set with **Set Quo user** on Timesheet; the **Call** button; a note in the caller pop-up) and the townhall (joined or present, to its end plus 10 minutes) pause it. **KPIs** shows **Idle minutes** against kpi_idle_minutes_week.

**Team** > **Townhall**: the weekly staff call (Wednesdays at 1:00 pm Toronto). The deck builds itself every Sunday night from the week''s data: the week, platform updates, fleet, staff, sales with the leaderboard, finances and claims (the last two for Admins only). Add a note to any slide; **Build again** refreshes the numbers. Set the call link in Program settings; staff add the call to their calendar from the page.

## The townhall day, attendance and the team slide (release 35)

1. The townhall is every Wednesday at 1:00 pm Toronto time. To change it, press **Change the day or time** on the Townhall page. Beside it, a table shows the website''s visitor sessions of the last 8 weeks for each day, as information. Field applicants'' live calls always take the hour before.
2. Every staff member is invited and reminded an hour before. **Join the call** on the townhall page, or **Check in** from 15 minutes before, counts them as there.
3. When the call ends, the people who missed it are recorded, the staff list shows "Missed N townhalls" for the last 8 weeks, and you get an alert with the names.
4. The deck''s last slide is the team: a tile per person with their role''s numbers for the week. Press **Add a shout-out** on a tile to add yours.

## Where staff live (release 35)

Welcome asks every hire for their city and country. In the Toronto area Sales keep the mode they were hired in; elsewhere Sales is remote. The staff list shows the location.

## Staff onboarding, breaks and shifts (release 35)

- New staff open their portal after four steps in order: the academy, the staff agreement, confirming the team''s WhatsApp groups, then an Admin''s or a Fleet VA''s approval (or a rejection with a reason the person sees). Everyone already working waits for the same approval once.
- Schedules: customer service, Fleet and Finance have a schedule per role, and an Admin can give one person their own. Today''s duty board shows who is working, late or absent.
- Breaks: office staff log a break from their home page, and the time on break is kept on their timesheet. While someone is on a break, on a call or in the townhall, the idle alert is paused; otherwise a person with no activity for a while on a shift gets an alert, then the Admins do.
- Quiet hours: staff alerts held by a person''s quiet hours arrive as one summary when they end, and no text goes to a renter at night (an answer asked for then arrives in the morning).
- Field staff set their availability (mornings, afternoons and evenings for each weekday) on Welcome and later on My shifts or Profile; Fleet and Admin see it on the shift board.
- Standing weekly shifts are claimed by themselves up to two weeks ahead; the minimum shifts a week is a Program setting (2 in 7 days), and anyone under it gets a reminder and a To do.
- A published shift nobody has claimed 48 hours before it starts alerts Fleet and the Admins with the people to ask.
- Payroll runs every two weeks: Finance prepares it, an Admin approves it and records the payments. KPIs per role are on Team, KPIs, each against a target in Program settings.
- The townhall is every Wednesday at 1:00 pm Toronto time; two missed in a row lock the account until an Admin restores it.', 'People and access', 'Portals and sign-in, invitations, password links, View as, staff and scorecards.',
  'Let people in, help them back in when they are locked out, and see exactly what they see. Every step is recorded in the audit log.

## Portals and sign-in

Open **People** > **Portals and view as**. Every portal has a card.

1. Each card links to **Its sign-in page**, the address to send that person.
2. Choose a person in the list on the card.
3. Press **Open as this person** to see that portal as they see it.

> Good to know: The site''s own test accounts (verify- addresses and Resend''s test inboxes) are marked "Test account" in People who can sign in. They sign in like anyone, but no real work is ever given to them (see Data health).

![](/guides/img/admin-27-portals-desktop-0361bf61.jpg "desktop; size: 1440 820; address: carmacars.ca/admin/portals; pins: 1 65.9 30.2, 2 58.1 39.4, 3 51.6 45.6")

## Invite a person

Invitations work for staff, field staff, owners and investors. The person gets our invitation email and chooses a password.

1. Under Invite a person, choose the Role: Staff (assistant), Field staff, Owner on file or Investor on file. Admin is not offered: only rent@carmacars.ca can be an Admin.
2. Fill in the Name and Email.
3. For staff, pick the Main function, and tick Also covers for any other function they help with. For field staff, pick the Field function.
4. Press **Invite**. The link in the email works for 24 hours.

![](/guides/img/admin-27-portals-desktop-c10725cb.jpg "desktop; size: 1230 360; address: carmacars.ca/admin/portals; pins: 1 18.8 40.8, 2 50.0 40.8, 3 18.8 66.7, 4 9.8 87.8")

> Tip: Someone who already signs in gets the new role at once, with no email. Owners and investors must be on file first: People > Owners and People > Investors also have a one-click invite for a record without a sign-in.

## Add an investor

1. Open **People** > **Investors** and press **Add an investor**.
2. Fill in the Legal name and the Type: Individual, or Corporation with the Person who signs for the corporation. Then the Email, the Phone and the Address (start typing and choose it).
3. Optional: the Amount committed, and the Yearly return offered (the investor offer''s, 30% unless you change it; the investment agreement sets the one that applies).
4. Invite now is ticked: press **Add and invite**. The record is added and the investor gets the invitation to choose a password for the investor portal. Untick it to add the record only, and invite later from the list.

## Send a password link

For anyone who forgot their password or let their invitation expire.

1. Under People who can sign in, search by name or email.
2. On their row, press **Send password link**. They get "Reset your CarmaCars password", valid for 24 hours.
3. **View as (...)** on the same row opens their portal, read only.

![](/guides/img/admin-27-portals-desktop-ee9b3e94.jpg "desktop; size: 1230 440; address: carmacars.ca/admin/portals; pins: 1 74.8 6.6, 2 68.2 28.6, 3 84.1 28.6")

## View as: see what someone sees

1. A red banner says "Viewing as Name (email), read only." on every page.
2. Click around their portal. Nothing can be changed: every save is refused.
3. Press **Exit** to come back. A view also ends by itself after 30 minutes.

![](/guides/img/admin-28-view-as-desktop-f858e38c.jpg "desktop; size: 1440 620; address: carmacars.ca/owner; pins: 1 48.6 4.5, 3 94.4 4.5")

> Watch out: Can''t change anything in Admin? You may still be viewing as someone. Look for the red banner and press Exit.

## The audit log

**Settings** > **Logs**, the **Changes** tab, shows who changed what, and when.

1. Changes lists every change with the person, the action, the table and the record. Data access lists lookups of private data.
2. Every View as is recorded (view_as_start), with the person viewed.
3. Search by table, record id or value.

![](/guides/img/admin-29-audit-desktop-b7504100.jpg "desktop; size: 1440 560; address: carmacars.ca/admin/audit; pins: 1 22.6 31.1, 2 39.0 46.4, 3 89.6 20.7")

## Staff and roles

**People** > **Team** opens Staff and roles.

1. Invite staff here too: Role, Name, Email, Main function and Also covers, then **Invite**.
2. Each row has **Send password link**, **View as (...)** and Limits (how much they may approve or refund).
3. Press **End access** to close their staff portal at once. **Restore** undoes it.

![](/guides/img/admin-26-staff-desktop-72287d0b.jpg "desktop; size: 1440 780; address: carmacars.ca/admin/settings/staff; pins: 1 20.8 59.0, 2 94.4 86.7, 3 83.3 92.6")

## Admin access

**Settings**, then Admin access. Who may hold the Admin role.

1. The list holds rent@carmacars.ca, and verify-admin@carmacars.ca, the automated test account the site''s nightly checks sign in with.
2. Below it: everyone who holds the Admin role now. Each must be on the list; the database refuses the Admin role to any other address.
3. Change the list only if the business''s Admin address changes.

## Staff scorecards

See how each assistant is doing against the targets.

1. On a staff member''s row in Staff and roles, press **Scorecard**.
2. By week shows each measure (for example quote sent within 5 minutes) and the result for each week.
3. A task meets its target when it is done by its due time. Daily checks count when done by 9:00 and 18:00.

![](/guides/img/va-sales-05-scorecard-desktop-956a5a9e.jpg "desktop; size: 1230 350; address: carmacars.ca/va/scorecard; pins: 2 21.1 42.9")

## Sales by staff member

See each person''s commissions, quotes, offers, rentals added, bookings confirmed and booked revenue.

1. On a staff member''s row in Staff and roles, press **Sales**. Press **By week** or **By month**.
2. The tiles show the current week or month. By week (or By month) lists each period: quotes created, offers sent, rentals added, bookings confirmed, conversion and booked revenue.
3. Follow-ups due lists their open deals with the next step. Deals lists each booking they created, added or sent an offer on, with what it counts.
4. A deal credited to the wrong person, or marked sourced when it was not? Press **Reassign** beside it, choose who, say whether they sourced the client, and write the reason.
5. **Commission rate** gives this person their own flat rate (empty: the Program settings). **Reverse** beside a commission stops it, for example for a household rental found later.
6. Staff enter their own home address (at their first sign-in, before they sign their agreement, or in their profile). It is needed before they add a rental or earn a commission, and spots a household rental. **Home address** here changes it if it is wrong.
7. The whole team: **Today** > **Overview**, the Sales card at the bottom. Choose another month and press **Show**.

| Figure | How it is counted |
| --- | --- |
| Credited to | Whoever created the quote or added the rental; for a website request, whoever sent its first offer. An Admin can reassign it. |
| Conversion | Of the deals credited in the period, the share confirmed so far. |
| Booked revenue | The rental charge before tax, after discounts, for bookings confirmed in the period. A cancelled booking counts only what was kept; refunds come off. |

## Sales staff: in person or remote

Each Sales person works in person (Toronto) or remote (anywhere, a contractor). Staff and roles lists them under Sales staff: in person or remote.

1. Press **Work mode** on a person (or on their Sales page), choose In person or Remote and give the reason. A new Sales person starts in person.
2. The list shows the mode, the rate now, the rate the month would end at, and for remote this month''s touches against 400, the peak hours scheduled this week (20 needed, Thursday to Sunday afternoons) and the replies on time.
3. On a remote person''s Sales page, Remote duties shows their checklist, touches, blocks and reply time. **Void** beside a touch logged by mistake takes it off, with a reason.
4. When you approve a Sales month, its mode, rates, touches and any drop are locked: a later change of mode or settings does not change it. Their My sales shows each month in one line.

|  | Rule |
| --- | --- |
| Rates | In person 10%, 15% from 50 rental days, 20% from 100. Remote 5 points lower on every tier: 5%, 10%, 15% |
| Credit | In person: walk-ins, handovers, partner visits and the rentals they source. Remote: only the rentals they source; a website request they answer with the first offer during their blocks is credited to them; a walk-in or a partner deal earns them nothing |
| Remote minimum | 400 touches a month. Under it, when the month ends, the month''s rate is one tier lower (5% becomes 2.5%). Settings > Program settings, Staff commissions, changes the minimum, the drop and the floor |

## An Admin has every staff page

An Admin account is only an Admin: it already has every page of the staff portals, so no office or field role can be added to it, and the invite form and Staff and roles refuse it. To work as staff, use a separate account. An Admin can still be given a field job and opens it on the field portal.
## Two records of one person

When two renter records are clearly the same person (the same phone verified with a code, or the same name, date of birth and phone), the site merges them by itself within 15 minutes, into the record with more bookings. Bookings, licences, cards, payments, documents and messages move. The person can then sign in with either email or with their phone number and a code, and gets one short note: "Your CarmaCars accounts are now one". A match on the name alone stays a task for you, and **Merge into this record** under the renter still works as before.

1. Open the renter. The Merged records card lists each merge, automatic or by staff, with what moved and the emails that now sign in there.
2. Two different people after all? Press **Undo** and say why. Everything moved goes back and both records are as they were.

## New staff: the academy, then the agreement, then the portal

Every staff member (never an Admin) opens their portal in this order: the academy first, then their staff agreement, then everything else. Until the academy is passed they open only the academy, the guide, their profile and **Welcome**; after it, until the agreement is signed, only Welcome, their profile and their documents to sign.

1. The agreement is sent by itself to everyone without one, filled from their record and their hire''s pay and start date: the Field Staff Agreement for field work, the contractor agreement for customer service, Fleet, Finance and Sales (in person or remote). One reminder goes 3 days after it was sent.
2. **Team** > **Staff and roles**, **Staff agreements**: who has not signed, what the automatic send waits for (for example a field hire''s licence number), and **Waive** with the reason.
3. Welcome also asks for the name they go by (the preferred name, shown across the portals and on the staff list), and, once the academy and the agreement are done, shows the team''s WhatsApp group (Program settings, **WhatsApp team group link** and **WhatsApp Sales group link**; empty until you set them). The same link goes by email, once.

## Accounts locked for inactivity

A staff account with no sign-in or use for 10 days (Program settings, **Staff inactive lock days**) is locked; the person is warned by email on day 7 and sees "Account locked for inactivity" when they sign in. You get an alert. On **Team** > **Staff and roles** the row says **Locked for inactivity**: press **Unlock**. The staff list shows each person''s last sign-in. Admin accounts are never locked.

## Hours and the townhall

**Team** > **Timesheet**: the hours customer service, Fleet and Finance clocked (Clock in and out on their home page). Add hours someone forgot, or void a wrong entry, with the reason. A person not clocked in 15 minutes after their start time (customer service 9:00, Fleet 11:00, Toronto) is reminded.

**Breaks and idle time (release 35).** Customer service, Fleet and Finance press **Start break** and **End break** next to the clock; breaks have no fixed length. On **Timesheet**, each person''s days show the hours clocked and worked, their breaks (how many, the total and the longest) and their idle time, with every break and idle stretch listed. **Edit** or **Remove** a break with the reason (in the audit log). Finance sees the breaks but never the idle time. A break open past 30 minutes reminds the person and you. Whether breaks are paid is **Program settings** > va_breaks_paid (on: salaried; off: breaks come off the hours on the payroll, where each line shows the period''s breaks).

While someone is clocked in, not on a break and within their scheduled hours, the portal notes the fact of their activity (never keys, pages or screens), at most once a minute; their actions count too. With no activity for more than va_idle_alert_minutes (10), you get one alert, "Name (role) inactive since 10:42, 12 min", and one more at va_idle_followup_minutes (30). A call they are on (their Quo user, set with **Set Quo user** on Timesheet; the **Call** button; a note in the caller pop-up) and the townhall (joined or present, to its end plus 10 minutes) pause it. **KPIs** shows **Idle minutes** against kpi_idle_minutes_week.

**Team** > **Townhall**: the weekly staff call (Wednesdays at 1:00 pm Toronto). The deck builds itself every Sunday night from the week''s data: the week, platform updates, fleet, staff, sales with the leaderboard, finances and claims (the last two for Admins only). Add a note to any slide; **Build again** refreshes the numbers. Set the call link in Program settings; staff add the call to their calendar from the page.

## The townhall day, attendance and the team slide (release 35)

1. The townhall is every Wednesday at 1:00 pm Toronto time. To change it, press **Change the day or time** on the Townhall page. Beside it, a table shows the website''s visitor sessions of the last 8 weeks for each day, as information. Field applicants'' live calls always take the hour before.
2. Every staff member is invited and reminded an hour before. **Join the call** on the townhall page, or **Check in** from 15 minutes before, counts them as there.
3. When the call ends, the people who missed it are recorded, the staff list shows "Missed N townhalls" for the last 8 weeks, and you get an alert with the names.
4. The deck''s last slide is the team: a tile per person with their role''s numbers for the week. Press **Add a shout-out** on a tile to add yours.

## Where staff live (release 35)

Welcome asks every hire for their city and country. In the Toronto area Sales keep the mode they were hired in; elsewhere Sales is remote. The staff list shows the location.

## Staff onboarding, breaks and shifts (release 35)

- New staff open their portal after four steps in order: the academy, the staff agreement, confirming the team''s WhatsApp groups, then an Admin''s or a Fleet VA''s approval (or a rejection with a reason the person sees). Everyone already working waits for the same approval once.
- Each person''s row on the Staff onboarding card in Settings and on the Fleet approvals list says exactly what is missing, for example "Waiting on: Academy (3 of 11 sections), Staff agreement signature". **Mark WhatsApp joined** records only the WhatsApp groups, at any step: it never passes the academy or signs the agreement, and it counts when the person reaches that step. Once the academy and the agreement are done, **Confirm WhatsApp and approve** marks the groups and approves in one press (Admins only, recorded in the audit log).
- Schedules: customer service, Fleet and Finance have a schedule per role, and an Admin can give one person their own. Today''s duty board shows who is working, late or absent.
- Breaks: office staff log a break from their home page, and the time on break is kept on their timesheet. While someone is on a break, on a call or in the townhall, the idle alert is paused; otherwise a person with no activity for a while on a shift gets an alert, then the Admins do.
- Quiet hours: staff alerts held by a person''s quiet hours arrive as one summary when they end, and no text goes to a renter at night (an answer asked for then arrives in the morning).
- Field staff set their availability (mornings, afternoons and evenings for each weekday) on Welcome and later on My shifts or Profile; Fleet and Admin see it on the shift board.
- Standing weekly shifts are claimed by themselves up to two weeks ahead; the minimum shifts a week is a Program setting (2 in 7 days), and anyone under it gets a reminder and a To do.
- A published shift nobody has claimed 48 hours before it starts alerts Fleet and the Admins with the people to ask.
- Payroll runs every two weeks: Finance prepares it, an Admin approves it and records the payments. KPIs per role are on Team, KPIs, each against a target in Program settings.
- The townhall is every Wednesday at 1:00 pm Toronto time; two missed in a row lock the account until an Admin restores it.',
  '<p class="gd-p">Let people in, help them back in when they are locked out, and see exactly what they see. Every step is recorded in the audit log.</p><section class="gd-task" id="people-and-access-portals-and-sign-in" data-gd-task><h2 class="gd-h2">Portals and sign-in</h2><p class="gd-p">Open <b class="gd-ui">People</b> &gt; <b class="gd-ui">Portals and view as</b>. Every portal has a card.</p><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">Each card links to <b class="gd-ui">Its sign-in page</b>, the address to send that person.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Choose a person in the list on the card.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Press <b class="gd-ui">Open as this person</b> to see that portal as they see it.</div></li></ol></div><aside class="gd-box"><span class="gd-lbl">Good to know</span><div>The site&#39;s own test accounts (verify- addresses and Resend&#39;s test inboxes) are marked &quot;Test account&quot; in People who can sign in. They sign in like anyone, but no real work is ever given to them (see Data health).</div></aside><div class="gd-figblock"><figure class="gd-fig gd-fig--desk"><div class="gd-browser"><div class="gd-bar" aria-hidden="true"><i></i><i></i><i></i><span class="gd-addr">carmacars.ca/admin/portals</span></div><div class="gd-imgwrap" style="aspect-ratio:1440/820"><img src="/guides/img/admin-27-portals-desktop-0361bf61.jpg" alt="" loading="lazy" decoding="async" width="1440" height="820"><span class="gd-pin" style="left:65.9%;top:30.2%" aria-hidden="true">1</span><span class="gd-pin" style="left:58.1%;top:39.4%" aria-hidden="true">2</span><span class="gd-pin" style="left:51.6%;top:45.6%" aria-hidden="true">3</span></div></div></figure></div></section><section class="gd-task" id="people-and-access-invite-a-person" data-gd-task><h2 class="gd-h2">Invite a person</h2><p class="gd-p">Invitations work for staff, field staff, owners and investors. The person gets our invitation email and chooses a password.</p><div class="gd-stepblock gd-stepblock--below"><div class="gd-stepcol"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">Under Invite a person, choose the Role: Staff (assistant), Field staff, Owner on file or Investor on file. Admin is not offered: only rent@carmacars.ca can be an Admin.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Fill in the Name and Email.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">For staff, pick the Main function, and tick Also covers for any other function they help with. For field staff, pick the Field function.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t">Press <b class="gd-ui">Invite</b>. The link in the email works for 24 hours.</div></li></ol></div><figure class="gd-fig gd-fig--desk"><div class="gd-browser"><div class="gd-bar" aria-hidden="true"><i></i><i></i><i></i><span class="gd-addr">carmacars.ca/admin/portals</span></div><div class="gd-imgwrap" style="aspect-ratio:1230/360"><img src="/guides/img/admin-27-portals-desktop-c10725cb.jpg" alt="" loading="lazy" decoding="async" width="1230" height="360"><span class="gd-pin" style="left:18.8%;top:40.8%" aria-hidden="true">1</span><span class="gd-pin" style="left:50%;top:40.8%" aria-hidden="true">2</span><span class="gd-pin" style="left:18.8%;top:66.7%" aria-hidden="true">3</span><span class="gd-pin" style="left:9.8%;top:87.8%" aria-hidden="true">4</span></div></div></figure></div><aside class="gd-box"><span class="gd-lbl">Tip</span><div>Someone who already signs in gets the new role at once, with no email. Owners and investors must be on file first: People &gt; Owners and People &gt; Investors also have a one-click invite for a record without a sign-in.</div></aside></section><section class="gd-task" id="people-and-access-add-an-investor" data-gd-task><h2 class="gd-h2">Add an investor</h2><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">Open <b class="gd-ui">People</b> &gt; <b class="gd-ui">Investors</b> and press <b class="gd-ui">Add an investor</b>.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Fill in the Legal name and the Type: Individual, or Corporation with the Person who signs for the corporation. Then the Email, the Phone and the Address (start typing and choose it).</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Optional: the Amount committed, and the Yearly return offered (the investor offer&#39;s, 30% unless you change it; the investment agreement sets the one that applies).</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t">Invite now is ticked: press <b class="gd-ui">Add and invite</b>. The record is added and the investor gets the invitation to choose a password for the investor portal. Untick it to add the record only, and invite later from the list.</div></li></ol></div></section><section class="gd-task" id="people-and-access-send-a-password-link" data-gd-task><h2 class="gd-h2">Send a password link</h2><p class="gd-p">For anyone who forgot their password or let their invitation expire.</p><div class="gd-stepblock gd-stepblock--below"><div class="gd-stepcol"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">Under People who can sign in, search by name or email.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">On their row, press <b class="gd-ui">Send password link</b>. They get &quot;Reset your CarmaCars password&quot;, valid for 24 hours.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t"><b class="gd-ui">View as (...)</b> on the same row opens their portal, read only.</div></li></ol></div><figure class="gd-fig gd-fig--desk"><div class="gd-browser"><div class="gd-bar" aria-hidden="true"><i></i><i></i><i></i><span class="gd-addr">carmacars.ca/admin/portals</span></div><div class="gd-imgwrap" style="aspect-ratio:1230/440"><img src="/guides/img/admin-27-portals-desktop-ee9b3e94.jpg" alt="" loading="lazy" decoding="async" width="1230" height="440"><span class="gd-pin" style="left:74.8%;top:6.6%" aria-hidden="true">1</span><span class="gd-pin" style="left:68.2%;top:28.6%" aria-hidden="true">2</span><span class="gd-pin" style="left:84.1%;top:28.6%" aria-hidden="true">3</span></div></div></figure></div></section><section class="gd-task" id="people-and-access-view-as-see-what-someone-sees" data-gd-task><h2 class="gd-h2">View as: see what someone sees</h2><div class="gd-stepblock gd-stepblock--below"><div class="gd-stepcol"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">A red banner says &quot;Viewing as Name (email), read only.&quot; on every page.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Click around their portal. Nothing can be changed: every save is refused.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Press <b class="gd-ui">Exit</b> to come back. A view also ends by itself after 30 minutes.</div></li></ol></div><figure class="gd-fig gd-fig--desk"><div class="gd-browser"><div class="gd-bar" aria-hidden="true"><i></i><i></i><i></i><span class="gd-addr">carmacars.ca/owner</span></div><div class="gd-imgwrap" style="aspect-ratio:1440/620"><img src="/guides/img/admin-28-view-as-desktop-f858e38c.jpg" alt="" loading="lazy" decoding="async" width="1440" height="620"><span class="gd-pin" style="left:48.6%;top:4.5%" aria-hidden="true">1</span><span class="gd-pin" style="left:94.4%;top:4.5%" aria-hidden="true">3</span></div></div></figure></div><aside class="gd-box gd-box--warn"><span class="gd-lbl">Watch out</span><div>Can&#39;t change anything in Admin? You may still be viewing as someone. Look for the red banner and press Exit.</div></aside></section><section class="gd-task" id="people-and-access-the-audit-log" data-gd-task><h2 class="gd-h2">The audit log</h2><p class="gd-p"><b class="gd-ui">Settings</b> &gt; <b class="gd-ui">Logs</b>, the <b class="gd-ui">Changes</b> tab, shows who changed what, and when.</p><div class="gd-stepblock gd-stepblock--below"><div class="gd-stepcol"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">Changes lists every change with the person, the action, the table and the record. Data access lists lookups of private data.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Every View as is recorded (view_as_start), with the person viewed.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Search by table, record id or value.</div></li></ol></div><figure class="gd-fig gd-fig--desk"><div class="gd-browser"><div class="gd-bar" aria-hidden="true"><i></i><i></i><i></i><span class="gd-addr">carmacars.ca/admin/audit</span></div><div class="gd-imgwrap" style="aspect-ratio:1440/560"><img src="/guides/img/admin-29-audit-desktop-b7504100.jpg" alt="" loading="lazy" decoding="async" width="1440" height="560"><span class="gd-pin" style="left:22.6%;top:31.1%" aria-hidden="true">1</span><span class="gd-pin" style="left:39%;top:46.4%" aria-hidden="true">2</span><span class="gd-pin" style="left:89.6%;top:20.7%" aria-hidden="true">3</span></div></div></figure></div></section><section class="gd-task" id="people-and-access-staff-and-roles" data-gd-task><h2 class="gd-h2">Staff and roles</h2><p class="gd-p"><b class="gd-ui">People</b> &gt; <b class="gd-ui">Team</b> opens Staff and roles.</p><div class="gd-stepblock gd-stepblock--below"><div class="gd-stepcol"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">Invite staff here too: Role, Name, Email, Main function and Also covers, then <b class="gd-ui">Invite</b>.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Each row has <b class="gd-ui">Send password link</b>, <b class="gd-ui">View as (...)</b> and Limits (how much they may approve or refund).</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Press <b class="gd-ui">End access</b> to close their staff portal at once. <b class="gd-ui">Restore</b> undoes it.</div></li></ol></div><figure class="gd-fig gd-fig--desk"><div class="gd-browser"><div class="gd-bar" aria-hidden="true"><i></i><i></i><i></i><span class="gd-addr">carmacars.ca/admin/settings/staff</span></div><div class="gd-imgwrap" style="aspect-ratio:1440/780"><img src="/guides/img/admin-26-staff-desktop-72287d0b.jpg" alt="" loading="lazy" decoding="async" width="1440" height="780"><span class="gd-pin" style="left:20.8%;top:59%" aria-hidden="true">1</span><span class="gd-pin" style="left:94.4%;top:86.7%" aria-hidden="true">2</span><span class="gd-pin" style="left:83.3%;top:92.6%" aria-hidden="true">3</span></div></div></figure></div></section><section class="gd-task" id="people-and-access-admin-access" data-gd-task><h2 class="gd-h2">Admin access</h2><p class="gd-p"><b class="gd-ui">Settings</b>, then Admin access. Who may hold the Admin role.</p><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">The list holds rent@carmacars.ca, and verify-admin@carmacars.ca, the automated test account the site&#39;s nightly checks sign in with.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Below it: everyone who holds the Admin role now. Each must be on the list; the database refuses the Admin role to any other address.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Change the list only if the business&#39;s Admin address changes.</div></li></ol></div></section><section class="gd-task" id="people-and-access-staff-scorecards" data-gd-task><h2 class="gd-h2">Staff scorecards</h2><p class="gd-p">See how each assistant is doing against the targets.</p><div class="gd-stepblock gd-stepblock--below"><div class="gd-stepcol"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">On a staff member&#39;s row in Staff and roles, press <b class="gd-ui">Scorecard</b>.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">By week shows each measure (for example quote sent within 5 minutes) and the result for each week.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">A task meets its target when it is done by its due time. Daily checks count when done by 9:00 and 18:00.</div></li></ol></div><figure class="gd-fig gd-fig--desk"><div class="gd-browser"><div class="gd-bar" aria-hidden="true"><i></i><i></i><i></i><span class="gd-addr">carmacars.ca/va/scorecard</span></div><div class="gd-imgwrap" style="aspect-ratio:1230/350"><img src="/guides/img/va-sales-05-scorecard-desktop-956a5a9e.jpg" alt="" loading="lazy" decoding="async" width="1230" height="350"><span class="gd-pin" style="left:21.1%;top:42.9%" aria-hidden="true">2</span></div></div></figure></div></section><section class="gd-task" id="people-and-access-sales-by-staff-member" data-gd-task><h2 class="gd-h2">Sales by staff member</h2><p class="gd-p">See each person&#39;s commissions, quotes, offers, rentals added, bookings confirmed and booked revenue.</p><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">On a staff member&#39;s row in Staff and roles, press <b class="gd-ui">Sales</b>. Press <b class="gd-ui">By week</b> or <b class="gd-ui">By month</b>.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">The tiles show the current week or month. By week (or By month) lists each period: quotes created, offers sent, rentals added, bookings confirmed, conversion and booked revenue.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Follow-ups due lists their open deals with the next step. Deals lists each booking they created, added or sent an offer on, with what it counts.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t">A deal credited to the wrong person, or marked sourced when it was not? Press <b class="gd-ui">Reassign</b> beside it, choose who, say whether they sourced the client, and write the reason.</div></li><li><span class="gd-n" aria-hidden="true">5</span><div class="gd-t"><b class="gd-ui">Commission rate</b> gives this person their own flat rate (empty: the Program settings). <b class="gd-ui">Reverse</b> beside a commission stops it, for example for a household rental found later.</div></li><li><span class="gd-n" aria-hidden="true">6</span><div class="gd-t">Staff enter their own home address (at their first sign-in, before they sign their agreement, or in their profile). It is needed before they add a rental or earn a commission, and spots a household rental. <b class="gd-ui">Home address</b> here changes it if it is wrong.</div></li><li><span class="gd-n" aria-hidden="true">7</span><div class="gd-t">The whole team: <b class="gd-ui">Today</b> &gt; <b class="gd-ui">Overview</b>, the Sales card at the bottom. Choose another month and press <b class="gd-ui">Show</b>.</div></li></ol></div><div class="gd-tablewrap"><table class="gd-table"><thead><tr><th scope="col">Figure</th><th scope="col">How it is counted</th></tr></thead><tbody><tr><td>Credited to</td><td>Whoever created the quote or added the rental; for a website request, whoever sent its first offer. An Admin can reassign it.</td></tr><tr><td>Conversion</td><td>Of the deals credited in the period, the share confirmed so far.</td></tr><tr><td>Booked revenue</td><td>The rental charge before tax, after discounts, for bookings confirmed in the period. A cancelled booking counts only what was kept; refunds come off.</td></tr></tbody></table></div></section><section class="gd-task" id="people-and-access-sales-staff-in-person-or-remote" data-gd-task><h2 class="gd-h2">Sales staff: in person or remote</h2><p class="gd-p">Each Sales person works in person (Toronto) or remote (anywhere, a contractor). Staff and roles lists them under Sales staff: in person or remote.</p><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">Press <b class="gd-ui">Work mode</b> on a person (or on their Sales page), choose In person or Remote and give the reason. A new Sales person starts in person.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">The list shows the mode, the rate now, the rate the month would end at, and for remote this month&#39;s touches against 400, the peak hours scheduled this week (20 needed, Thursday to Sunday afternoons) and the replies on time.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">On a remote person&#39;s Sales page, Remote duties shows their checklist, touches, blocks and reply time. <b class="gd-ui">Void</b> beside a touch logged by mistake takes it off, with a reason.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t">When you approve a Sales month, its mode, rates, touches and any drop are locked: a later change of mode or settings does not change it. Their My sales shows each month in one line.</div></li></ol></div><div class="gd-tablewrap"><table class="gd-table"><thead><tr><th scope="col"></th><th scope="col">Rule</th></tr></thead><tbody><tr><td>Rates</td><td>In person 10%, 15% from 50 rental days, 20% from 100. Remote 5 points lower on every tier: 5%, 10%, 15%</td></tr><tr><td>Credit</td><td>In person: walk-ins, handovers, partner visits and the rentals they source. Remote: only the rentals they source; a website request they answer with the first offer during their blocks is credited to them; a walk-in or a partner deal earns them nothing</td></tr><tr><td>Remote minimum</td><td>400 touches a month. Under it, when the month ends, the month&#39;s rate is one tier lower (5% becomes 2.5%). Settings &gt; Program settings, Staff commissions, changes the minimum, the drop and the floor</td></tr></tbody></table></div></section><section class="gd-task" id="people-and-access-an-admin-has-every-staff-page" data-gd-task><h2 class="gd-h2">An Admin has every staff page</h2><p class="gd-p">An Admin account is only an Admin: it already has every page of the staff portals, so no office or field role can be added to it, and the invite form and Staff and roles refuse it. To work as staff, use a separate account. An Admin can still be given a field job and opens it on the field portal.</p></section><section class="gd-task" id="people-and-access-two-records-of-one-person" data-gd-task><h2 class="gd-h2">Two records of one person</h2><p class="gd-p">When two renter records are clearly the same person (the same phone verified with a code, or the same name, date of birth and phone), the site merges them by itself within 15 minutes, into the record with more bookings. Bookings, licences, cards, payments, documents and messages move. The person can then sign in with either email or with their phone number and a code, and gets one short note: &quot;Your CarmaCars accounts are now one&quot;. A match on the name alone stays a task for you, and <b class="gd-ui">Merge into this record</b> under the renter still works as before.</p><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">Open the renter. The Merged records card lists each merge, automatic or by staff, with what moved and the emails that now sign in there.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Two different people after all? Press <b class="gd-ui">Undo</b> and say why. Everything moved goes back and both records are as they were.</div></li></ol></div></section><section class="gd-task" id="people-and-access-new-staff-the-academy-then-the-agreement-then-the-portal" data-gd-task><h2 class="gd-h2">New staff: the academy, then the agreement, then the portal</h2><p class="gd-p">Every staff member (never an Admin) opens their portal in this order: the academy first, then their staff agreement, then everything else. Until the academy is passed they open only the academy, the guide, their profile and <b class="gd-ui">Welcome</b>; after it, until the agreement is signed, only Welcome, their profile and their documents to sign.</p><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">The agreement is sent by itself to everyone without one, filled from their record and their hire&#39;s pay and start date: the Field Staff Agreement for field work, the contractor agreement for customer service, Fleet, Finance and Sales (in person or remote). One reminder goes 3 days after it was sent.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t"><b class="gd-ui">Team</b> &gt; <b class="gd-ui">Staff and roles</b>, <b class="gd-ui">Staff agreements</b>: who has not signed, what the automatic send waits for (for example a field hire&#39;s licence number), and <b class="gd-ui">Waive</b> with the reason.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Welcome also asks for the name they go by (the preferred name, shown across the portals and on the staff list), and, once the academy and the agreement are done, shows the team&#39;s WhatsApp group (Program settings, <b class="gd-ui">WhatsApp team group link</b> and <b class="gd-ui">WhatsApp Sales group link</b>; empty until you set them). The same link goes by email, once.</div></li></ol></div></section><section class="gd-task" id="people-and-access-accounts-locked-for-inactivity" data-gd-task><h2 class="gd-h2">Accounts locked for inactivity</h2><p class="gd-p">A staff account with no sign-in or use for 10 days (Program settings, <b class="gd-ui">Staff inactive lock days</b>) is locked; the person is warned by email on day 7 and sees &quot;Account locked for inactivity&quot; when they sign in. You get an alert. On <b class="gd-ui">Team</b> &gt; <b class="gd-ui">Staff and roles</b> the row says <b class="gd-ui">Locked for inactivity</b>: press <b class="gd-ui">Unlock</b>. The staff list shows each person&#39;s last sign-in. Admin accounts are never locked.</p></section><section class="gd-task" id="people-and-access-hours-and-the-townhall" data-gd-task><h2 class="gd-h2">Hours and the townhall</h2><p class="gd-p"><b class="gd-ui">Team</b> &gt; <b class="gd-ui">Timesheet</b>: the hours customer service, Fleet and Finance clocked (Clock in and out on their home page). Add hours someone forgot, or void a wrong entry, with the reason. A person not clocked in 15 minutes after their start time (customer service 9:00, Fleet 11:00, Toronto) is reminded.</p><p class="gd-p"><b class="gd-ui">Breaks and idle time (release 35).</b> Customer service, Fleet and Finance press <b class="gd-ui">Start break</b> and <b class="gd-ui">End break</b> next to the clock; breaks have no fixed length. On <b class="gd-ui">Timesheet</b>, each person&#39;s days show the hours clocked and worked, their breaks (how many, the total and the longest) and their idle time, with every break and idle stretch listed. <b class="gd-ui">Edit</b> or <b class="gd-ui">Remove</b> a break with the reason (in the audit log). Finance sees the breaks but never the idle time. A break open past 30 minutes reminds the person and you. Whether breaks are paid is <b class="gd-ui">Program settings</b> &gt; va_breaks_paid (on: salaried; off: breaks come off the hours on the payroll, where each line shows the period&#39;s breaks).</p><p class="gd-p">While someone is clocked in, not on a break and within their scheduled hours, the portal notes the fact of their activity (never keys, pages or screens), at most once a minute; their actions count too. With no activity for more than va_idle_alert_minutes (10), you get one alert, &quot;Name (role) inactive since 10:42, 12 min&quot;, and one more at va_idle_followup_minutes (30). A call they are on (their Quo user, set with <b class="gd-ui">Set Quo user</b> on Timesheet; the <b class="gd-ui">Call</b> button; a note in the caller pop-up) and the townhall (joined or present, to its end plus 10 minutes) pause it. <b class="gd-ui">KPIs</b> shows <b class="gd-ui">Idle minutes</b> against kpi_idle_minutes_week.</p><p class="gd-p"><b class="gd-ui">Team</b> &gt; <b class="gd-ui">Townhall</b>: the weekly staff call (Wednesdays at 1:00 pm Toronto). The deck builds itself every Sunday night from the week&#39;s data: the week, platform updates, fleet, staff, sales with the leaderboard, finances and claims (the last two for Admins only). Add a note to any slide; <b class="gd-ui">Build again</b> refreshes the numbers. Set the call link in Program settings; staff add the call to their calendar from the page.</p></section><section class="gd-task" id="people-and-access-the-townhall-day-attendance-and-the-team-slide-release-35" data-gd-task><h2 class="gd-h2">The townhall day, attendance and the team slide (release 35)</h2><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">The townhall is every Wednesday at 1:00 pm Toronto time. To change it, press <b class="gd-ui">Change the day or time</b> on the Townhall page. Beside it, a table shows the website&#39;s visitor sessions of the last 8 weeks for each day, as information. Field applicants&#39; live calls always take the hour before.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Every staff member is invited and reminded an hour before. <b class="gd-ui">Join the call</b> on the townhall page, or <b class="gd-ui">Check in</b> from 15 minutes before, counts them as there.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">When the call ends, the people who missed it are recorded, the staff list shows &quot;Missed N townhalls&quot; for the last 8 weeks, and you get an alert with the names.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t">The deck&#39;s last slide is the team: a tile per person with their role&#39;s numbers for the week. Press <b class="gd-ui">Add a shout-out</b> on a tile to add yours.</div></li></ol></div></section><section class="gd-task" id="people-and-access-where-staff-live-release-35" data-gd-task><h2 class="gd-h2">Where staff live (release 35)</h2><p class="gd-p">Welcome asks every hire for their city and country. In the Toronto area Sales keep the mode they were hired in; elsewhere Sales is remote. The staff list shows the location.</p></section><section class="gd-task" id="people-and-access-staff-onboarding-breaks-and-shifts-release-35" data-gd-task><h2 class="gd-h2">Staff onboarding, breaks and shifts (release 35)</h2><ul class="gd-ul"><li>New staff open their portal after four steps in order: the academy, the staff agreement, confirming the team&#39;s WhatsApp groups, then an Admin&#39;s or a Fleet VA&#39;s approval (or a rejection with a reason the person sees). Everyone already working waits for the same approval once.</li><li>Each person&#39;s row on the Staff onboarding card in Settings and on the Fleet approvals list says exactly what is missing, for example &quot;Waiting on: Academy (3 of 11 sections), Staff agreement signature&quot;. <b class="gd-ui">Mark WhatsApp joined</b> records only the WhatsApp groups, at any step: it never passes the academy or signs the agreement, and it counts when the person reaches that step. Once the academy and the agreement are done, <b class="gd-ui">Confirm WhatsApp and approve</b> marks the groups and approves in one press (Admins only, recorded in the audit log).</li><li>Schedules: customer service, Fleet and Finance have a schedule per role, and an Admin can give one person their own. Today&#39;s duty board shows who is working, late or absent.</li><li>Breaks: office staff log a break from their home page, and the time on break is kept on their timesheet. While someone is on a break, on a call or in the townhall, the idle alert is paused; otherwise a person with no activity for a while on a shift gets an alert, then the Admins do.</li><li>Quiet hours: staff alerts held by a person&#39;s quiet hours arrive as one summary when they end, and no text goes to a renter at night (an answer asked for then arrives in the morning).</li><li>Field staff set their availability (mornings, afternoons and evenings for each weekday) on Welcome and later on My shifts or Profile; Fleet and Admin see it on the shift board.</li><li>Standing weekly shifts are claimed by themselves up to two weeks ahead; the minimum shifts a week is a Program setting (2 in 7 days), and anyone under it gets a reminder and a To do.</li><li>A published shift nobody has claimed 48 hours before it starts alerts Fleet and the Admins with the people to ask.</li><li>Payroll runs every two weeks: Finance prepares it, an Admin approves it and records the payments. KPIs per role are on Team, KPIs, each against a target in Program settings.</li><li>The townhall is every Wednesday at 1:00 pm Toronto time; two missed in a row lock the account until an Admin restores it.</li></ul></section>');
select app.guide_release_section('admin', 'owner-money', 'chapter', 'owners-and-onboarding', 'Owner fee invoices are issued on the notice day and debited on the 15th. Invoices of any amount are made by hand, as drafts first. Statements are built, approved and issued each month, and payouts follow.

## Owner invoices

**Money** > **Owner money**, the **Invoices** tab. Every owner invoice, drafts and voids included. The same list is on each owner''s and each application''s Invoices tab.

1. Filter by Drafts, Open, Partly paid, Paid, Failed, In arrears or Void, or search by invoice number or owner. Open an invoice to see everything about it.
2. **New invoice** makes an invoice of any amount for an owner''s car, for example a registration fee of $123.45.
3. The monthly run and tracker invoices: **Run the monthly invoices** issues the invoices for the 15th by hand, for a missed month (never twice); **Issue all tracker invoices** bills the Tracker Install for each car waiting for its tracker.

![](/guides/img/admin-14-owner-invoices-desktop-dc4ed1f1.jpg "desktop; size: 1440 1060; address: carmacars.ca/admin/invoices; pins: 1 83.3 22.4, 2 41.7 35.7, 3 29.0 43.4")

## Make, edit and issue an invoice

A new invoice is a draft: the owner sees nothing and it is never debited until you issue it.

1. Choose the car, a title (for example Registration fee) and, if you like, the due date (empty: 7 days after it is issued). Each line: the description, the quantity, the unit amount to the cent, HST on or off, and a note. **Add a line** for more.
2. **Save as draft** to come back to it, or **Save and issue** to send it now. On a draft''s page, **Issue and email** sends it.
3. Paid another way? Press **Already paid outside the platform** on the invoice: choose how (e-Transfer, cash, cheque, bank transfer or card outside the platform), the date and the reference. A draft is issued without the invoice email first, the payment is recorded, and the owner gets no email unless you tick **Email the owner a receipt**. To record a smaller or extra payment, press **Record payment**. The page lists the payments with their receipts, the automatic debits, the emails sent and the history.
4. **Resend email** sends the invoice again. **PDF** opens it as a PDF.

## Correct an issued invoice

An issued invoice is never edited. You void it and issue a corrected one.

1. Press **Void**, write the reason (the owner reads it), keep Make a corrected invoice from it ticked, and press **Void the invoice**. Its scheduled debit is cancelled and the owner is told.
2. The corrected invoice opens as a draft with the same lines. Fix the amounts and press **Save and issue**.
3. Already paid? Void the payment first, or press **Credit note** for the amount to give back: it gets its own number and the owner sees it.

Invoices issued before October 20, 2026 at the old default (for example $904.00, or $1,017.00 when the Insurance Fee was $450.00) are not changed by themselves. Where an owner agreed another amount, void them and reissue at the agreed amount.

## The automatic debit

The debit runs by itself. Your job is to watch for payments the bank sends back and owners with no bank debit set up.

:::flow
Notice day | Invoices issued, one notice per owner, 10 days before
Debit day | The 15th from 6:00: one debit per invoice
Cleared | The invoice is paid
Returned, insufficient funds | The $50.00 Late Fee is added once; the same amount is tried again within 30 days
Returned for another reason | No retry and no Late Fee: the debit pauses and you get a task
:::

1. The tiles show the next debit day and notice day, scheduled, processing, cleared and returned debits.
2. How it runs explains the policy in words, read from Program settings.
3. Scheduled and processing lists each debit. **Pause** holds one (a reason is needed).
4. Owners lists each owner''s bank debit. Use **Pause**, **Resume**, **Send a notice now** or, with no bank debit set up, **Send the sign-up link**.

![](/guides/img/admin-15-owner-debits-desktop-f65f061a.jpg "desktop; size: 1440 920; address: carmacars.ca/admin/debits; pins: 1 21.8 21.7, 2 21.5 35.5, 3 91.5 75.4, 4 84.7 94.7")

5. Results: each debit, cleared or returned, with the bank''s reason.
6. Run log: each notice and debit run, with its counts.
7. Notices sent: who was told what, for which debit day.

![](/guides/img/admin-15-owner-debits-desktop-8d4682bc.jpg "desktop; size: 1230 520; address: carmacars.ca/admin/debits; pins: 5 11.0 14.4, 6 10.2 52.3, 7 15.4 89.8")

Insufficient funds: the $50.00 Late Fee is added to that invoice once and collected with the owner''s next debit, and the original amount is tried again within 30 days, as section 4.4 of the Enrollment Agreement sets out. The retry is never more than the original amount. Returned again: the invoice is in arrears and you get a task. Any debit missed (returned for another reason, too late to retry, or a retry still waiting) comes off the owner''s next revenue statement by itself: when the statement is built, the invoice goes in arrears (a waiting retry is cancelled) and the statement deducts it. Nothing to do.

> Watch out: Returned for any other reason (account closed, payment stopped, no authorization): there is no retry and no Late Fee. The owner''s debit pauses, the owner gets an email asking them to fix the account or pay another way, and you get a task. A debit is never more than its notice said. An owner with no bank debit set up gets an email on the notice day and you get a task; nothing is debited for them.

## Before the debit day: the Debit preview

The top of the Debits tab shows the coming debit day.

1. **Debit preview** lists each owner with something to debit: the total, whether a bank debit is set up, whether the notice went, and each invoice in one line: the amount, the car, the fee (monthly fee, first and last month, tracker install, adjustment, late fee), the period and how it was worked out, such as "prorated: 20 of 30 days". The line opens the invoice.
2. Something looks wrong? Press **Hold** beside the owner and give the reason. Nothing is debited for that owner until you press **Resume**.
3. **Fee check** compares the month''s invoices with each car''s signed terms: no monthly fee on a flat monthly payment, a Turo-Only car, a shareholder''s car or a company car, nothing before the Enrollment Date, and the amount the terms give. It changes nothing: void and reissue an invoice that does not match. Each production deploy prints the same check.

## When a debit can''t go ahead

You get one email: "Can''t collect $X from the owner: the reason". The reasons are the words of the owner guide: no bank debit set up, owner cancelled the debit at their bank, amount went up after the notice, the bank sent the payment back. The email lists each amount in one line and has one button that fixes it.

1. **Send the sign-up link** opens the Debits tab on that owner. Press **Send the sign-up link** again there: the owner gets the email to set up their bank debit.
2. **Send a new notice** opens the same place with **Send a new notice** for the new amount.
3. **Open the invoice** opens the invoice to record a payment made another way.

## Owner statements

**Money** > **Owner money**, the **Statements** tab

1. Press **Build all for a month** (or **Build one**).
2. Open each draft. Check it, **Rebuild** after a correction, **Preview PDF**, then **Approve**.
3. Press **Issue to the owner**. **Reissue** sends a corrected copy; **CSV** exports it.

![](/guides/img/admin-16-statements-desktop-43a313ea.jpg "desktop; size: 1440 400; address: carmacars.ca/admin/statements; pins: 1 79.9 27.3")

![An approved statement: the owner gets it by email with the PDF on the 10th, and payouts follow under Payouts.](/guides/img/admin-17-statement-desktop-106ee57f.jpg "desktop; size: 1440 520; address: carmacars.ca/admin/statements/2eedf660-50ce-4bd9-86d6-01bbe149c000; pins: 3 86.0 22.7")

## Staff commissions

**Money** > **Company**, the **Commissions** tab. Nothing is paid automatically.

:::flow
Not earned yet | The rental is ahead, or not paid in full
Pending approval | Completed and paid in full; a Sales month once it has ended
Approved | You approved it; the staff member is told
Paid | You recorded the payment; the staff member is told
Reversed | Cancelled, refunded or charged back; after payment it comes off the next payment
:::

1. By person shows each staff member''s month (Sales: rental days of 100 and the tier), what is not earned yet, pending approval, approved and paid.
2. Press **Approve** on a person (everything that may be approved now) or on one commission.
3. Press **Record a payment**: choose how it was paid (e-Transfer, bank transfer, Wise, cash, the monthly pay statement or another way), the reference and the date.
4. **Prices to review** lists prices typed by hand; **Sourcing claims** lists staff who say they sourced a website request; **Payments made** lists each payment.
5. **Owner requests** lists the commission each salesperson asks for an owner they brought in: a flat amount, or a percent of the company''s share or of the cars'' rental revenue, for a number of months or for as long as the car is with us. Press **Approve**, **Change and approve** (your terms, with a note) or **Decline**. Nothing accrues before you approve. A flat amount is earned at the owner''s first paid rental, once; a percent on each paid rental of the owner''s cars in the time approved. Each then comes to the list above for approval.
6. Who sourced an owner: the owner''s page, **Sourced by**. Only an Admin changes it, with a reason. A waiting request of the person before is withdrawn; an approved one, with what it has not paid yet, goes to the new person.

|  | Commission |
| --- | --- |
| Sales | By rental days of the month: under 50 days 10%, from 50 days 15%, from 100 days 20%, on all that month''s rentals |
| An owner a salesperson brought in | The request you approved. A CarmaCars expense, never deducted before Owner Revenue; none on CarmaCars'', a partner''s or a shareholder''s cars |
| Customer service, finance, fleet, field staff | 10% (also the field referral fee) |
| Base | The rental charge before tax, after discounts, with late extra days; never delivery, kilometres, add-ons or anything else bought. Only a refund of the rental charge comes off |
| On the owner statement | An owner''s car: deducted with the kickbacks before Owner Revenue, its own line on the statement. A partner''s car: from CarmaCars'' commission. A CarmaCars-owned car: a CarmaCars expense |

> Tip: A commission that changes after an owner statement was built (a refund, or the month''s Sales tier) goes on the owner''s next statement as an adjustment line.

## Field pay

**Money** > **Company**, the **Field pay** tab. Field staff clock in and out on their phones (My hours); you run the pay every two weeks. Nothing is paid automatically.

:::flow
Clocked in and out | Field staff press Clock in and Clock out; Fleet or you fix a forgotten clock-out
Pay run started | Hours times the hourly rate, plus the approved commissions
Approved | The figures are frozen, the period''s hours are locked, the statements are numbered
Paid | You recorded how each person was paid; they get their statement by email
:::

1. The tab **Pay run** shows the current two-week period (Sunday to Saturday: the first day is Settings > Program, Field pay). **Earlier period** and **Later period** move between periods.
2. After the period ends, press **Start the payroll**: one line for each person with hours times their hourly rate, plus the staff commissions and referral fees approved by the end of the period (see Staff commissions). **Refresh the figures** takes in a change made since.
3. Press **Approve**. The period''s hours are locked, each line gets a statement number and the figures are frozen. Someone still clocked in blocks it: fix their shift under **Hours** first. **Withdraw** takes an approved run back while no payment is recorded.
4. Press **Record payment** on a line: choose e-Transfer, bank transfer or cash, the reference (not needed for cash) and the date. The commissions in the line are marked paid and the person gets their pay statement by email (**Send again** repeats it). The statement''s number opens its PDF; **CSV** gives the run for your accountant.
5. **Hours** lists everyone''s shifts of the period. **Add hours** enters a shift for someone who forgot to clock in, **Change** fixes one and **Remove** takes one out. Each needs a reason and is kept in a log. Fleet does the same under Field hours but sees no pay.
6. **Hourly rates** shows each person''s rate: CA$18.00 an hour unless you give them their own with **Set the rate** (a reason is needed). A pay run keeps the rate it was started with.

|  | Field pay |
| --- | --- |
| Overtime | Off. Settings > Program, Field pay: pay overtime, after 44 hours in a week, at 150% of the rate |
| Vacation pay | Off. Settings > Program, Field pay: vacation pay (Ontario: 4%) adds that share of wages, overtime and commissions to each statement |
| Deductions | None are worked out: income tax, CPP, EI and the employer''s contributions are for your accountant. Each statement says so |
| Commissions that net to nothing | A person whose approved commissions add up to nothing or less (a clawback) is not paid them this period: they carry to the next |

> Tip: A shift of more than 16 hours (a setting) is refused, and so are hours that overlap another shift of the same person. The field staff member sees their hours and statements under My hours on their phone.

## Company model

Money > **Company model** is the CarmaCars model workbook, live: the actuals, the forecast and the pro forma on one page. Admins only (not Finance). Never share it: investors have their own sheets in the investor portal.

1. **Forecast**: the latest actual month, the EBITDA break-even month, the next 12 months'' EBITDA and the lowest cash, a chart of EBITDA and cash, and 36 months marked A (actual) or F (forecast): cars, utilization, revenue per rented day, revenue, costs, EBITDA, investor returns, tax and cash.
2. **Actuals**: filled in by themselves every hour from the bookings, payments, payouts, expenses and investments. Rental earned is spread over each rental''s days (before HST, insurer-billed and renter-billed apart, placeholders left out), with fees by kind, cash received by method, rentals and rented days, owner and partner shares, commissions, kickbacks, expenses by category and investor payouts. **Refresh actuals now** recomputes them at once.
3. **Pro forma 5 years**: each year''s income statement, cash flow and key figures.
4. **Assumptions**: growth, the utilization ramp, rates, monthly costs, hires, planned capital raises, the fleet insurance premium and tax. Press **Save the assumptions**; the forecast, the pro forma and the download use them at once. A field marked "From the actuals" left blank uses the latest complete month.
5. **Download as Excel**: the full internal workbook with live formulas and the current actuals.

> Tip: Enter the fleet insurance premium under Assumptions; until then it counts as $0 and profit is overstated. Enter each month''s costs in Money > Expenses: a cost line with nothing entered for an actual month uses the assumption, marked est.

## Payroll for everyone (release 35)

**Money** > **Payroll** is one run every two weeks for the field staff (hours) and for customer service, Fleet and Finance (salary).

1. A salaried person is paid their monthly salary x 12 / 26, for the days they were employed in the period. The salary is their own (**Set the salary**, with a reason), else the monthly pay they were hired at, else their role''s (Program settings, va_salary_defaults), in US dollars unless set otherwise.
2. Finance prepares it: **Start the payroll**, **Add a bonus or deduction** with the reason, then **Send for approval**. You get an alert.
3. You press **Approve**, then **Record all payments** (one method and reference; each stub number is added to it) or **Record payment** line by line. Each person gets their stub by email and in their portal.

> Tip: Admin > Team also has **Schedules** (each role''s days and hours, anyone''s own, who is late today) and **KPIs** (every staff member''s KPIs for a week against the targets in Program settings).

> Good to know: The townhall page: pick the craziest story, enter the week''s social media figures, add the recording link, and mark anyone present or absent. Staff who miss two townhalls in a row are locked until you press **Unlock** on the staff list.

> Good to know: Each renter and lead shows an Intent card (hot, warm or cold, with the budget, car, length, dates, urgency, delivery and coverage they mentioned). The live map shows it on each pin. An AI reading fills the gaps within the free daily allowance only (Program settings, intent_ai_enabled).

> Good to know: Investors see Search traction under the deck: Google clicks and impressions of the last 28 days, indexed pages and the weekly trend. Type the indexed pages from Search Console on the investor deck page under Investors (no API exists for it).

## Company statements

**Money** > **Company**, the **Monthly statements** tab: CarmaCars'' own monthly statement, in twelve sections.

1. Choose the month. The tiles show revenue, fees, refunds, expenses and the company net.
2. Switch between Total, Per owner and Per vehicle.
3. Download **PDF**, **PDF by owner** or **PDF by vehicle**, or press **Email me the PDFs**.
4. **Finalize** freezes the month. **Rebuild** works until then.

![](/guides/img/admin-18-company-statements-desktop-8e2738ed.jpg "desktop; size: 1440 760; address: carmacars.ca/admin/reports; pins: 1 20.8 28.0, 2 19.4 59.3, 3 77.1 15.5, 4 46.9 15.5")

### Fees taken from the revenue statement
On an owner''s page, the **Fees** button sets **How fees are paid**: **Bank debit** (the default) or **Take from revenue statement**. Taken from the statement, the owner''s invoices (not the upfront one) are not debited: the next owner statement pays each one from the payout, as far as it goes, with the line "Invoice INV-..., paid from statement". Approved, the invoice reads **Paid from statement**, or part paid with the rest on the next statement. An invoice still owing 2 months after its billing date goes back to the bank debit after the usual notice, and you get the task **Invoice ... back to the bank debit**.

### The flat-rate agreements
An owner whose every car is on a flat monthly payment signs the **Flat-Rate Vehicle Enrollment Agreement** instead of the standard one (the Title-Holding and Lease Agreement and Forms A to D are the same). The owner''s page says which set applies. When the pay model changes, the signed Enrollment Agreement ends and the owner signs the new one in the owner portal; changed back before signing, the signed one is in force again. The lawyer approved the flat-rate set: Program settings > **Flat-rate agreements awaiting lawyer OK** is off, and is turned on only to mark a new text still under review. Owners can sign either way.

## How it''s paid: bank debit or deducted from payouts

Every owner invoice is paid one of two ways: **Bank debit on the 15th**, or **Deduct from payouts** (taken from the owner''s monthly payouts until paid, never debited).

1. On an invoice, **How it''s paid**, **Change**. A draft changed to Deduct from payouts is issued without the debit email.
2. Each monthly statement deducts as much as the payout allows and shows it to the owner as a deduction; the rest waits for the next statement. The invoice screen shows what was deducted and what is left.
3. For the first and last month, choose **Deduct from payouts** on the Terms tab (or at approval).
4. On the Terms tab, **Charge the agreed one-off fees** makes one invoice for a car from the one-off fees agreed on the owner''s terms (all, or the ones you name), deducted from payouts or debited.

## Referral links between owners (release 28)

When one owner referred another, open the referrer''s **Terms** tab, **Referral links**, **This owner referred another owner**: choose the owner referred and the share in basis points (1000 = 10 points of the revenue the management fee is taken from). Set the referred owner''s own fee on their Terms as usual (for example a 40% management fee and $350 a month per car). Every statement of the referrer then has a **Referral share** line per referred car; it is paid from CarmaCars'' share, never the referred owner''s payout. With **sees the cars** on, the referrer finds **Cars you referred** in their owner portal: bookings, use and revenue, read only, without the other owner''s details. **End** stops the link; shares already earned are still paid.

## Statement periods (release 35)

Statements run from the 8th of one month to the 7th of the next, and the payout on the 10th covers them. A rental that crosses the cutoff, or a long weekly or biweekly rental, is paid for the days inside each period, never twice. Each statement lists amounts still uncollected from the renter separately; they are paid on the statement after they are collected.', 'Owner money', 'Owner invoices (drafts, void and reissue, credit notes), the automatic debit, statements, payouts and the company statement.',
  'Owner fee invoices are issued on the notice day and debited on the 15th. Invoices of any amount are made by hand, as drafts first. Statements are built, approved and issued each month, and payouts follow.

## Owner invoices

**Money** > **Owner money**, the **Invoices** tab. Every owner invoice, drafts and voids included. The same list is on each owner''s and each application''s Invoices tab.

1. Filter by Drafts, Open, Partly paid, Paid, Failed, In arrears or Void, or search by invoice number or owner. Open an invoice to see everything about it.
2. **New invoice** makes an invoice of any amount for an owner''s car, for example a registration fee of $123.45.
3. The monthly run and tracker invoices: **Run the monthly invoices** issues the invoices for the 15th by hand, for a missed month (never twice); **Issue all tracker invoices** bills the Tracker Install for each car waiting for its tracker.

![](/guides/img/admin-14-owner-invoices-desktop-dc4ed1f1.jpg "desktop; size: 1440 1060; address: carmacars.ca/admin/invoices; pins: 1 83.3 22.4, 2 41.7 35.7, 3 29.0 43.4")

## Make, edit and issue an invoice

A new invoice is a draft: the owner sees nothing and it is never debited until you issue it.

1. Choose the car, a title (for example Registration fee) and, if you like, the due date (empty: 7 days after it is issued). Each line: the description, the quantity, the unit amount to the cent, HST on or off, and a note. **Add a line** for more.
2. **Save as draft** to come back to it, or **Save and issue** to send it now. On a draft''s page, **Issue and email** sends it.
3. Paid another way? Press **Already paid outside the platform** on the invoice: choose how (e-Transfer, cash, cheque, bank transfer or card outside the platform), the date and the reference. A draft is issued without the invoice email first, the payment is recorded, and the owner gets no email unless you tick **Email the owner a receipt**. To record a smaller or extra payment, press **Record payment**. The page lists the payments with their receipts, the automatic debits, the emails sent and the history.
4. **Resend email** sends the invoice again. **PDF** opens it as a PDF.

## Correct an issued invoice

An issued invoice is never edited. You void it and issue a corrected one.

1. Press **Void**, write the reason (the owner reads it), keep Make a corrected invoice from it ticked, and press **Void the invoice**. Its scheduled debit is cancelled and the owner is told.
2. The corrected invoice opens as a draft with the same lines. Fix the amounts and press **Save and issue**.
3. Already paid? Void the payment first, or press **Credit note** for the amount to give back: it gets its own number and the owner sees it.

Invoices issued before October 20, 2026 at the old default (for example $904.00, or $1,017.00 when the Insurance Fee was $450.00) are not changed by themselves. Where an owner agreed another amount, void them and reissue at the agreed amount.

## The automatic debit

The debit runs by itself. Your job is to watch for payments the bank sends back and owners with no bank debit set up.

:::flow
Notice day | Invoices issued, one notice per owner, 10 days before
Debit day | The 15th from 6:00: one debit per invoice
Cleared | The invoice is paid
Returned, insufficient funds | The $50.00 Late Fee is added once; the same amount is tried again within 30 days
Returned for another reason | No retry and no Late Fee: the debit pauses and you get a task
:::

1. The tiles show the next debit day and notice day, scheduled, processing, cleared and returned debits.
2. How it runs explains the policy in words, read from Program settings.
3. Scheduled and processing lists each debit. **Pause** holds one (a reason is needed).
4. Owners lists each owner''s bank debit. Use **Pause**, **Resume**, **Send a notice now** or, with no bank debit set up, **Send the sign-up link**.

![](/guides/img/admin-15-owner-debits-desktop-f65f061a.jpg "desktop; size: 1440 920; address: carmacars.ca/admin/debits; pins: 1 21.8 21.7, 2 21.5 35.5, 3 91.5 75.4, 4 84.7 94.7")

5. Results: each debit, cleared or returned, with the bank''s reason.
6. Run log: each notice and debit run, with its counts.
7. Notices sent: who was told what, for which debit day.

![](/guides/img/admin-15-owner-debits-desktop-8d4682bc.jpg "desktop; size: 1230 520; address: carmacars.ca/admin/debits; pins: 5 11.0 14.4, 6 10.2 52.3, 7 15.4 89.8")

Insufficient funds: the $50.00 Late Fee is added to that invoice once and collected with the owner''s next debit, and the original amount is tried again within 30 days, as section 4.4 of the Enrollment Agreement sets out. The retry is never more than the original amount. Returned again: the invoice is in arrears and you get a task. Any debit missed (returned for another reason, too late to retry, or a retry still waiting) comes off the owner''s next revenue statement by itself: when the statement is built, the invoice goes in arrears (a waiting retry is cancelled) and the statement deducts it. Nothing to do.

> Watch out: Returned for any other reason (account closed, payment stopped, no authorization): there is no retry and no Late Fee. The owner''s debit pauses, the owner gets an email asking them to fix the account or pay another way, and you get a task. A debit is never more than its notice said. An owner with no bank debit set up gets an email on the notice day and you get a task; nothing is debited for them.

## Before the debit day: the Debit preview

The top of the Debits tab shows the coming debit day.

1. **Debit preview** lists each owner with something to debit: the total, whether a bank debit is set up, whether the notice went, and each invoice in one line: the amount, the car, the fee (monthly fee, first and last month, tracker install, adjustment, late fee), the period and how it was worked out, such as "prorated: 20 of 30 days". The line opens the invoice.
2. Something looks wrong? Press **Hold** beside the owner and give the reason. Nothing is debited for that owner until you press **Resume**.
3. **Fee check** compares the month''s invoices with each car''s signed terms: no monthly fee on a flat monthly payment, a Turo-Only car, a shareholder''s car or a company car, nothing before the Enrollment Date, and the amount the terms give. It changes nothing: void and reissue an invoice that does not match. Each production deploy prints the same check.

## When a debit can''t go ahead

You get one email: "Can''t collect $X from the owner: the reason". The reasons are the words of the owner guide: no bank debit set up, owner cancelled the debit at their bank, amount went up after the notice, the bank sent the payment back. The email lists each amount in one line and has one button that fixes it.

1. **Send the sign-up link** opens the Debits tab on that owner. Press **Send the sign-up link** again there: the owner gets the email to set up their bank debit.
2. **Send a new notice** opens the same place with **Send a new notice** for the new amount.
3. **Open the invoice** opens the invoice to record a payment made another way.

## Owner statements

**Money** > **Owner money**, the **Statements** tab

1. Press **Build all for a month** (or **Build one**).
2. Open each draft. Check it, **Rebuild** after a correction, **Preview PDF**, then **Approve**.
3. Press **Issue to the owner**. **Reissue** sends a corrected copy; **CSV** exports it.

![](/guides/img/admin-16-statements-desktop-43a313ea.jpg "desktop; size: 1440 400; address: carmacars.ca/admin/statements; pins: 1 79.9 27.3")

![An approved statement: the owner gets it by email with the PDF on the 10th, and payouts follow under Payouts.](/guides/img/admin-17-statement-desktop-106ee57f.jpg "desktop; size: 1440 520; address: carmacars.ca/admin/statements/2eedf660-50ce-4bd9-86d6-01bbe149c000; pins: 3 86.0 22.7")

## Staff commissions

**Money** > **Company**, the **Commissions** tab. Nothing is paid automatically.

:::flow
Not earned yet | The rental is ahead, or not paid in full
Pending approval | Completed and paid in full; a Sales month once it has ended
Approved | You approved it; the staff member is told
Paid | You recorded the payment; the staff member is told
Reversed | Cancelled, refunded or charged back; after payment it comes off the next payment
:::

1. By person shows each staff member''s month (Sales: rental days of 100 and the tier), what is not earned yet, pending approval, approved and paid.
2. Press **Approve** on a person (everything that may be approved now) or on one commission.
3. Press **Record a payment**: choose how it was paid (e-Transfer, bank transfer, Wise, cash, the monthly pay statement or another way), the reference and the date.
4. **Prices to review** lists prices typed by hand; **Sourcing claims** lists staff who say they sourced a website request; **Payments made** lists each payment.
5. **Owner requests** lists the commission each salesperson asks for an owner they brought in: a flat amount, or a percent of the company''s share or of the cars'' rental revenue, for a number of months or for as long as the car is with us. Press **Approve**, **Change and approve** (your terms, with a note) or **Decline**. Nothing accrues before you approve. A flat amount is earned at the owner''s first paid rental, once; a percent on each paid rental of the owner''s cars in the time approved. Each then comes to the list above for approval.
6. Who sourced an owner: the owner''s page, **Sourced by**. Only an Admin changes it, with a reason. A waiting request of the person before is withdrawn; an approved one, with what it has not paid yet, goes to the new person.

|  | Commission |
| --- | --- |
| Sales | By rental days of the month: under 50 days 10%, from 50 days 15%, from 100 days 20%, on all that month''s rentals |
| An owner a salesperson brought in | The request you approved. A CarmaCars expense, never deducted before Owner Revenue; none on CarmaCars'', a partner''s or a shareholder''s cars |
| Field staff | 10% (also the field referral fee). Customer service, Fleet and Finance staff get no sales credit or commission, ever: their help is credited as Helped by on the booking and on their scorecard |
| Base | The rental charge before tax, after discounts, with late extra days; never delivery, kilometres, add-ons or anything else bought. Only a refund of the rental charge comes off |
| On the owner statement | An owner''s car: deducted with the kickbacks before Owner Revenue, its own line on the statement. A partner''s car: from CarmaCars'' commission. A CarmaCars-owned car: a CarmaCars expense |

> Tip: A commission that changes after an owner statement was built (a refund, or the month''s Sales tier) goes on the owner''s next statement as an adjustment line.

## Field pay

**Money** > **Company**, the **Field pay** tab. Field staff clock in and out on their phones (My hours); you run the pay every two weeks. Nothing is paid automatically.

:::flow
Clocked in and out | Field staff press Clock in and Clock out; Fleet or you fix a forgotten clock-out
Pay run started | Hours times the hourly rate, plus the approved commissions
Approved | The figures are frozen, the period''s hours are locked, the statements are numbered
Paid | You recorded how each person was paid; they get their statement by email
:::

1. The tab **Pay run** shows the current two-week period (Sunday to Saturday: the first day is Settings > Program, Field pay). **Earlier period** and **Later period** move between periods.
2. After the period ends, press **Start the payroll**: one line for each person with hours times their hourly rate, plus the staff commissions and referral fees approved by the end of the period (see Staff commissions). **Refresh the figures** takes in a change made since.
3. Press **Approve**. The period''s hours are locked, each line gets a statement number and the figures are frozen. Someone still clocked in blocks it: fix their shift under **Hours** first. **Withdraw** takes an approved run back while no payment is recorded.
4. Press **Record payment** on a line: choose e-Transfer, bank transfer or cash, the reference (not needed for cash) and the date. The commissions in the line are marked paid and the person gets their pay statement by email (**Send again** repeats it). The statement''s number opens its PDF; **CSV** gives the run for your accountant.
5. **Hours** lists everyone''s shifts of the period. **Add hours** enters a shift for someone who forgot to clock in, **Change** fixes one and **Remove** takes one out. Each needs a reason and is kept in a log. Fleet does the same under Field hours but sees no pay.
6. **Hourly rates** shows each person''s rate: CA$18.00 an hour unless you give them their own with **Set the rate** (a reason is needed). A pay run keeps the rate it was started with.

|  | Field pay |
| --- | --- |
| Overtime | Off. Settings > Program, Field pay: pay overtime, after 44 hours in a week, at 150% of the rate |
| Vacation pay | Off. Settings > Program, Field pay: vacation pay (Ontario: 4%) adds that share of wages, overtime and commissions to each statement |
| Deductions | None are worked out: income tax, CPP, EI and the employer''s contributions are for your accountant. Each statement says so |
| Commissions that net to nothing | A person whose approved commissions add up to nothing or less (a clawback) is not paid them this period: they carry to the next |

> Tip: A shift of more than 16 hours (a setting) is refused, and so are hours that overlap another shift of the same person. The field staff member sees their hours and statements under My hours on their phone.

## Company model

Money > **Company model** is the CarmaCars model workbook, live: the actuals, the forecast and the pro forma on one page. Admins only (not Finance). Never share it: investors have their own sheets in the investor portal.

1. **Forecast**: the latest actual month, the EBITDA break-even month, the next 12 months'' EBITDA and the lowest cash, a chart of EBITDA and cash, and 36 months marked A (actual) or F (forecast): cars, utilization, revenue per rented day, revenue, costs, EBITDA, investor returns, tax and cash.
2. **Actuals**: filled in by themselves every hour from the bookings, payments, payouts, expenses and investments. Rental earned is spread over each rental''s days (before HST, insurer-billed and renter-billed apart, placeholders left out), with fees by kind, cash received by method, rentals and rented days, owner and partner shares, commissions, kickbacks, expenses by category and investor payouts. **Refresh actuals now** recomputes them at once.
3. **Pro forma 5 years**: each year''s income statement, cash flow and key figures.
4. **Assumptions**: growth, the utilization ramp, rates, monthly costs, hires, planned capital raises, the fleet insurance premium and tax. Press **Save the assumptions**; the forecast, the pro forma and the download use them at once. A field marked "From the actuals" left blank uses the latest complete month.
5. **Download as Excel**: the full internal workbook with live formulas and the current actuals.

> Tip: Enter the fleet insurance premium under Assumptions; until then it counts as $0 and profit is overstated. Enter each month''s costs in Money > Expenses: a cost line with nothing entered for an actual month uses the assumption, marked est.

## Payroll for everyone (release 35)

**Money** > **Payroll** is one run every two weeks for the field staff (hours) and for customer service, Fleet and Finance (salary).

1. A salaried person is paid their monthly salary x 12 / 26, for the days they were employed in the period. The salary is their own (**Set the salary**, with a reason), else the monthly pay they were hired at, else their role''s (Program settings, va_salary_defaults), in US dollars unless set otherwise.
2. Finance prepares it: **Start the payroll**, **Add a bonus or deduction** with the reason, then **Send for approval**. You get an alert.
3. You press **Approve**, then **Record all payments** (one method and reference; each stub number is added to it) or **Record payment** line by line. Each person gets their stub by email and in their portal.

> Tip: Admin > Team also has **Schedules** (each role''s days and hours, anyone''s own, who is late today) and **KPIs** (every staff member''s KPIs for a week against the targets in Program settings).

> Good to know: The townhall page: pick the craziest story, enter the week''s social media figures, add the recording link, and mark anyone present or absent. Staff who miss two townhalls in a row are locked until you press **Unlock** on the staff list.

> Good to know: Each renter and lead shows an Intent card (hot, warm or cold, with the budget, car, length, dates, urgency, delivery and coverage they mentioned). The live map shows it on each pin. An AI reading fills the gaps within the free daily allowance only (Program settings, intent_ai_enabled).

> Good to know: Investors see Search traction under the deck: Google clicks and impressions of the last 28 days, indexed pages and the weekly trend. Type the indexed pages from Search Console on the investor deck page under Investors (no API exists for it).

## Company statements

**Money** > **Company**, the **Monthly statements** tab: CarmaCars'' own monthly statement, in twelve sections.

1. Choose the month. The tiles show revenue, fees, refunds, expenses and the company net.
2. Switch between Total, Per owner and Per vehicle.
3. Download **PDF**, **PDF by owner** or **PDF by vehicle**, or press **Email me the PDFs**.
4. **Finalize** freezes the month. **Rebuild** works until then.

![](/guides/img/admin-18-company-statements-desktop-8e2738ed.jpg "desktop; size: 1440 760; address: carmacars.ca/admin/reports; pins: 1 20.8 28.0, 2 19.4 59.3, 3 77.1 15.5, 4 46.9 15.5")

### Fees taken from the revenue statement
On an owner''s page, the **Fees** button sets **How fees are paid**: **Bank debit** (the default) or **Take from revenue statement**. Taken from the statement, the owner''s invoices (not the upfront one) are not debited: the next owner statement pays each one from the payout, as far as it goes, with the line "Invoice INV-..., paid from statement". Approved, the invoice reads **Paid from statement**, or part paid with the rest on the next statement. An invoice still owing 2 months after its billing date goes back to the bank debit after the usual notice, and you get the task **Invoice ... back to the bank debit**.

### The flat-rate agreements
An owner whose every car is on a flat monthly payment signs the **Flat-Rate Vehicle Enrollment Agreement** instead of the standard one (the Title-Holding and Lease Agreement and Forms A to D are the same). The owner''s page says which set applies. When the pay model changes, the signed Enrollment Agreement ends and the owner signs the new one in the owner portal; changed back before signing, the signed one is in force again. The lawyer approved the flat-rate set: Program settings > **Flat-rate agreements awaiting lawyer OK** is off, and is turned on only to mark a new text still under review. Owners can sign either way.

## How it''s paid: bank debit or deducted from payouts

Every owner invoice is paid one of two ways: **Bank debit on the 15th**, or **Deduct from payouts** (taken from the owner''s monthly payouts until paid, never debited).

1. On an invoice, **How it''s paid**, **Change**. A draft changed to Deduct from payouts is issued without the debit email.
2. Each monthly statement deducts as much as the payout allows and shows it to the owner as a deduction; the rest waits for the next statement. The invoice screen shows what was deducted and what is left.
3. For the first and last month, choose **Deduct from payouts** on the Terms tab (or at approval).
4. On the Terms tab, **Charge the agreed one-off fees** makes one invoice for a car from the one-off fees agreed on the owner''s terms (all, or the ones you name), deducted from payouts or debited.

## Referral links between owners (release 28)

When one owner referred another, open the referrer''s **Terms** tab, **Referral links**, **This owner referred another owner**: choose the owner referred and the share in basis points (1000 = 10 points of the revenue the management fee is taken from). Set the referred owner''s own fee on their Terms as usual (for example a 40% management fee and $350 a month per car). Every statement of the referrer then has a **Referral share** line per referred car; it is paid from CarmaCars'' share, never the referred owner''s payout. With **sees the cars** on, the referrer finds **Cars you referred** in their owner portal: bookings, use and revenue, read only, without the other owner''s details. **End** stops the link; shares already earned are still paid.

## Statement periods (release 35)

Statements run from the 8th of one month to the 7th of the next, and the payout on the 10th covers them. A rental that crosses the cutoff, or a long weekly or biweekly rental, is paid for the days inside each period, never twice. Each statement lists amounts still uncollected from the renter separately; they are paid on the statement after they are collected.',
  '<p class="gd-p">Owner fee invoices are issued on the notice day and debited on the 15th. Invoices of any amount are made by hand, as drafts first. Statements are built, approved and issued each month, and payouts follow.</p><section class="gd-task" id="owner-money-owner-invoices" data-gd-task><h2 class="gd-h2">Owner invoices</h2><p class="gd-p"><b class="gd-ui">Money</b> &gt; <b class="gd-ui">Owner money</b>, the <b class="gd-ui">Invoices</b> tab. Every owner invoice, drafts and voids included. The same list is on each owner&#39;s and each application&#39;s Invoices tab.</p><div class="gd-stepblock gd-stepblock--below"><div class="gd-stepcol"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">Filter by Drafts, Open, Partly paid, Paid, Failed, In arrears or Void, or search by invoice number or owner. Open an invoice to see everything about it.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t"><b class="gd-ui">New invoice</b> makes an invoice of any amount for an owner&#39;s car, for example a registration fee of $123.45.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">The monthly run and tracker invoices: <b class="gd-ui">Run the monthly invoices</b> issues the invoices for the 15th by hand, for a missed month (never twice); <b class="gd-ui">Issue all tracker invoices</b> bills the Tracker Install for each car waiting for its tracker.</div></li></ol></div><figure class="gd-fig gd-fig--desk"><div class="gd-browser"><div class="gd-bar" aria-hidden="true"><i></i><i></i><i></i><span class="gd-addr">carmacars.ca/admin/invoices</span></div><div class="gd-imgwrap" style="aspect-ratio:1440/1060"><img src="/guides/img/admin-14-owner-invoices-desktop-dc4ed1f1.jpg" alt="" loading="lazy" decoding="async" width="1440" height="1060"><span class="gd-pin" style="left:83.3%;top:22.4%" aria-hidden="true">1</span><span class="gd-pin" style="left:41.7%;top:35.7%" aria-hidden="true">2</span><span class="gd-pin" style="left:29%;top:43.4%" aria-hidden="true">3</span></div></div></figure></div></section><section class="gd-task" id="owner-money-make-edit-and-issue-an-invoice" data-gd-task><h2 class="gd-h2">Make, edit and issue an invoice</h2><p class="gd-p">A new invoice is a draft: the owner sees nothing and it is never debited until you issue it.</p><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">Choose the car, a title (for example Registration fee) and, if you like, the due date (empty: 7 days after it is issued). Each line: the description, the quantity, the unit amount to the cent, HST on or off, and a note. <b class="gd-ui">Add a line</b> for more.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t"><b class="gd-ui">Save as draft</b> to come back to it, or <b class="gd-ui">Save and issue</b> to send it now. On a draft&#39;s page, <b class="gd-ui">Issue and email</b> sends it.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Paid another way? Press <b class="gd-ui">Already paid outside the platform</b> on the invoice: choose how (e-Transfer, cash, cheque, bank transfer or card outside the platform), the date and the reference. A draft is issued without the invoice email first, the payment is recorded, and the owner gets no email unless you tick <b class="gd-ui">Email the owner a receipt</b>. To record a smaller or extra payment, press <b class="gd-ui">Record payment</b>. The page lists the payments with their receipts, the automatic debits, the emails sent and the history.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t"><b class="gd-ui">Resend email</b> sends the invoice again. <b class="gd-ui">PDF</b> opens it as a PDF.</div></li></ol></div></section><section class="gd-task" id="owner-money-correct-an-issued-invoice" data-gd-task><h2 class="gd-h2">Correct an issued invoice</h2><p class="gd-p">An issued invoice is never edited. You void it and issue a corrected one.</p><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">Press <b class="gd-ui">Void</b>, write the reason (the owner reads it), keep Make a corrected invoice from it ticked, and press <b class="gd-ui">Void the invoice</b>. Its scheduled debit is cancelled and the owner is told.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">The corrected invoice opens as a draft with the same lines. Fix the amounts and press <b class="gd-ui">Save and issue</b>.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Already paid? Void the payment first, or press <b class="gd-ui">Credit note</b> for the amount to give back: it gets its own number and the owner sees it.</div></li></ol></div><p class="gd-p">Invoices issued before October 20, 2026 at the old default (for example $904.00, or $1,017.00 when the Insurance Fee was $450.00) are not changed by themselves. Where an owner agreed another amount, void them and reissue at the agreed amount.</p></section><section class="gd-task" id="owner-money-the-automatic-debit" data-gd-task><h2 class="gd-h2">The automatic debit</h2><p class="gd-p">The debit runs by itself. Your job is to watch for payments the bank sends back and owners with no bank debit set up.</p><ol class="gd-flow"><li><b>1</b><span>Notice day</span><em>Invoices issued, one notice per owner, 10 days before</em></li><li><b>2</b><span>Debit day</span><em>The 15th from 6:00: one debit per invoice</em></li><li><b>3</b><span>Cleared</span><em>The invoice is paid</em></li><li><b>4</b><span>Returned, insufficient funds</span><em>The $50.00 Late Fee is added once; the same amount is tried again within 30 days</em></li><li><b>5</b><span>Returned for another reason</span><em>No retry and no Late Fee: the debit pauses and you get a task</em></li></ol><div class="gd-stepblock gd-stepblock--below"><div class="gd-stepcol"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">The tiles show the next debit day and notice day, scheduled, processing, cleared and returned debits.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">How it runs explains the policy in words, read from Program settings.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Scheduled and processing lists each debit. <b class="gd-ui">Pause</b> holds one (a reason is needed).</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t">Owners lists each owner&#39;s bank debit. Use <b class="gd-ui">Pause</b>, <b class="gd-ui">Resume</b>, <b class="gd-ui">Send a notice now</b> or, with no bank debit set up, <b class="gd-ui">Send the sign-up link</b>.</div></li></ol></div><figure class="gd-fig gd-fig--desk"><div class="gd-browser"><div class="gd-bar" aria-hidden="true"><i></i><i></i><i></i><span class="gd-addr">carmacars.ca/admin/debits</span></div><div class="gd-imgwrap" style="aspect-ratio:1440/920"><img src="/guides/img/admin-15-owner-debits-desktop-f65f061a.jpg" alt="" loading="lazy" decoding="async" width="1440" height="920"><span class="gd-pin" style="left:21.8%;top:21.7%" aria-hidden="true">1</span><span class="gd-pin" style="left:21.5%;top:35.5%" aria-hidden="true">2</span><span class="gd-pin" style="left:91.5%;top:75.4%" aria-hidden="true">3</span><span class="gd-pin" style="left:84.7%;top:94.7%" aria-hidden="true">4</span></div></div></figure></div><div class="gd-stepblock gd-stepblock--below"><div class="gd-stepcol"><ol class="gd-ol" start="5"><li><span class="gd-n" aria-hidden="true">5</span><div class="gd-t">Results: each debit, cleared or returned, with the bank&#39;s reason.</div></li><li><span class="gd-n" aria-hidden="true">6</span><div class="gd-t">Run log: each notice and debit run, with its counts.</div></li><li><span class="gd-n" aria-hidden="true">7</span><div class="gd-t">Notices sent: who was told what, for which debit day.</div></li></ol></div><figure class="gd-fig gd-fig--desk"><div class="gd-browser"><div class="gd-bar" aria-hidden="true"><i></i><i></i><i></i><span class="gd-addr">carmacars.ca/admin/debits</span></div><div class="gd-imgwrap" style="aspect-ratio:1230/520"><img src="/guides/img/admin-15-owner-debits-desktop-8d4682bc.jpg" alt="" loading="lazy" decoding="async" width="1230" height="520"><span class="gd-pin" style="left:11%;top:14.4%" aria-hidden="true">5</span><span class="gd-pin" style="left:10.2%;top:52.3%" aria-hidden="true">6</span><span class="gd-pin" style="left:15.4%;top:89.8%" aria-hidden="true">7</span></div></div></figure></div><p class="gd-p">Insufficient funds: the $50.00 Late Fee is added to that invoice once and collected with the owner&#39;s next debit, and the original amount is tried again within 30 days, as section 4.4 of the Enrollment Agreement sets out. The retry is never more than the original amount. Returned again: the invoice is in arrears and you get a task. Any debit missed (returned for another reason, too late to retry, or a retry still waiting) comes off the owner&#39;s next revenue statement by itself: when the statement is built, the invoice goes in arrears (a waiting retry is cancelled) and the statement deducts it. Nothing to do.</p><aside class="gd-box gd-box--warn"><span class="gd-lbl">Watch out</span><div>Returned for any other reason (account closed, payment stopped, no authorization): there is no retry and no Late Fee. The owner&#39;s debit pauses, the owner gets an email asking them to fix the account or pay another way, and you get a task. A debit is never more than its notice said. An owner with no bank debit set up gets an email on the notice day and you get a task; nothing is debited for them.</div></aside></section><section class="gd-task" id="owner-money-before-the-debit-day-the-debit-preview" data-gd-task><h2 class="gd-h2">Before the debit day: the Debit preview</h2><p class="gd-p">The top of the Debits tab shows the coming debit day.</p><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t"><b class="gd-ui">Debit preview</b> lists each owner with something to debit: the total, whether a bank debit is set up, whether the notice went, and each invoice in one line: the amount, the car, the fee (monthly fee, first and last month, tracker install, adjustment, late fee), the period and how it was worked out, such as &quot;prorated: 20 of 30 days&quot;. The line opens the invoice.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Something looks wrong? Press <b class="gd-ui">Hold</b> beside the owner and give the reason. Nothing is debited for that owner until you press <b class="gd-ui">Resume</b>.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t"><b class="gd-ui">Fee check</b> compares the month&#39;s invoices with each car&#39;s signed terms: no monthly fee on a flat monthly payment, a Turo-Only car, a shareholder&#39;s car or a company car, nothing before the Enrollment Date, and the amount the terms give. It changes nothing: void and reissue an invoice that does not match. Each production deploy prints the same check.</div></li></ol></div></section><section class="gd-task" id="owner-money-when-a-debit-can-t-go-ahead" data-gd-task><h2 class="gd-h2">When a debit can&#39;t go ahead</h2><p class="gd-p">You get one email: &quot;Can&#39;t collect $X from the owner: the reason&quot;. The reasons are the words of the owner guide: no bank debit set up, owner cancelled the debit at their bank, amount went up after the notice, the bank sent the payment back. The email lists each amount in one line and has one button that fixes it.</p><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t"><b class="gd-ui">Send the sign-up link</b> opens the Debits tab on that owner. Press <b class="gd-ui">Send the sign-up link</b> again there: the owner gets the email to set up their bank debit.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t"><b class="gd-ui">Send a new notice</b> opens the same place with <b class="gd-ui">Send a new notice</b> for the new amount.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t"><b class="gd-ui">Open the invoice</b> opens the invoice to record a payment made another way.</div></li></ol></div></section><section class="gd-task" id="owner-money-owner-statements" data-gd-task><h2 class="gd-h2">Owner statements</h2><p class="gd-p"><b class="gd-ui">Money</b> &gt; <b class="gd-ui">Owner money</b>, the <b class="gd-ui">Statements</b> tab</p><div class="gd-stepblock gd-stepblock--below"><div class="gd-stepcol"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">Press <b class="gd-ui">Build all for a month</b> (or <b class="gd-ui">Build one</b>).</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Open each draft. Check it, <b class="gd-ui">Rebuild</b> after a correction, <b class="gd-ui">Preview PDF</b>, then <b class="gd-ui">Approve</b>.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Press <b class="gd-ui">Issue to the owner</b>. <b class="gd-ui">Reissue</b> sends a corrected copy; <b class="gd-ui">CSV</b> exports it.</div></li></ol></div><figure class="gd-fig gd-fig--desk"><div class="gd-browser"><div class="gd-bar" aria-hidden="true"><i></i><i></i><i></i><span class="gd-addr">carmacars.ca/admin/statements</span></div><div class="gd-imgwrap" style="aspect-ratio:1440/400"><img src="/guides/img/admin-16-statements-desktop-43a313ea.jpg" alt="" loading="lazy" decoding="async" width="1440" height="400"><span class="gd-pin" style="left:79.9%;top:27.3%" aria-hidden="true">1</span></div></div></figure></div><div class="gd-figblock"><figure class="gd-fig gd-fig--desk"><div class="gd-browser"><div class="gd-bar" aria-hidden="true"><i></i><i></i><i></i><span class="gd-addr">carmacars.ca/admin/statements/2eedf660-50ce-4bd9-86d6-01bbe149c000</span></div><div class="gd-imgwrap" style="aspect-ratio:1440/520"><img src="/guides/img/admin-17-statement-desktop-106ee57f.jpg" alt="An approved statement: the owner gets it by email with the PDF on the 10th, and payouts follow under Payouts." loading="lazy" decoding="async" width="1440" height="520"><span class="gd-pin" style="left:86%;top:22.7%" aria-hidden="true">3</span></div></div><figcaption>An approved statement: the owner gets it by email with the PDF on the 10th, and payouts follow under Payouts.</figcaption></figure></div></section><section class="gd-task" id="owner-money-staff-commissions" data-gd-task><h2 class="gd-h2">Staff commissions</h2><p class="gd-p"><b class="gd-ui">Money</b> &gt; <b class="gd-ui">Company</b>, the <b class="gd-ui">Commissions</b> tab. Nothing is paid automatically.</p><ol class="gd-flow"><li><b>1</b><span>Not earned yet</span><em>The rental is ahead, or not paid in full</em></li><li><b>2</b><span>Pending approval</span><em>Completed and paid in full; a Sales month once it has ended</em></li><li><b>3</b><span>Approved</span><em>You approved it; the staff member is told</em></li><li><b>4</b><span>Paid</span><em>You recorded the payment; the staff member is told</em></li><li><b>5</b><span>Reversed</span><em>Cancelled, refunded or charged back; after payment it comes off the next payment</em></li></ol><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">By person shows each staff member&#39;s month (Sales: rental days of 100 and the tier), what is not earned yet, pending approval, approved and paid.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Press <b class="gd-ui">Approve</b> on a person (everything that may be approved now) or on one commission.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Press <b class="gd-ui">Record a payment</b>: choose how it was paid (e-Transfer, bank transfer, Wise, cash, the monthly pay statement or another way), the reference and the date.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t"><b class="gd-ui">Prices to review</b> lists prices typed by hand; <b class="gd-ui">Sourcing claims</b> lists staff who say they sourced a website request; <b class="gd-ui">Payments made</b> lists each payment.</div></li><li><span class="gd-n" aria-hidden="true">5</span><div class="gd-t"><b class="gd-ui">Owner requests</b> lists the commission each salesperson asks for an owner they brought in: a flat amount, or a percent of the company&#39;s share or of the cars&#39; rental revenue, for a number of months or for as long as the car is with us. Press <b class="gd-ui">Approve</b>, <b class="gd-ui">Change and approve</b> (your terms, with a note) or <b class="gd-ui">Decline</b>. Nothing accrues before you approve. A flat amount is earned at the owner&#39;s first paid rental, once; a percent on each paid rental of the owner&#39;s cars in the time approved. Each then comes to the list above for approval.</div></li><li><span class="gd-n" aria-hidden="true">6</span><div class="gd-t">Who sourced an owner: the owner&#39;s page, <b class="gd-ui">Sourced by</b>. Only an Admin changes it, with a reason. A waiting request of the person before is withdrawn; an approved one, with what it has not paid yet, goes to the new person.</div></li></ol></div><div class="gd-tablewrap"><table class="gd-table"><thead><tr><th scope="col"></th><th scope="col">Commission</th></tr></thead><tbody><tr><td>Sales</td><td>By rental days of the month: under 50 days 10%, from 50 days 15%, from 100 days 20%, on all that month&#39;s rentals</td></tr><tr><td>An owner a salesperson brought in</td><td>The request you approved. A CarmaCars expense, never deducted before Owner Revenue; none on CarmaCars&#39;, a partner&#39;s or a shareholder&#39;s cars</td></tr><tr><td>Field staff</td><td>10% (also the field referral fee). Customer service, Fleet and Finance staff get no sales credit or commission, ever: their help is credited as Helped by on the booking and on their scorecard</td></tr><tr><td>Base</td><td>The rental charge before tax, after discounts, with late extra days; never delivery, kilometres, add-ons or anything else bought. Only a refund of the rental charge comes off</td></tr><tr><td>On the owner statement</td><td>An owner&#39;s car: deducted with the kickbacks before Owner Revenue, its own line on the statement. A partner&#39;s car: from CarmaCars&#39; commission. A CarmaCars-owned car: a CarmaCars expense</td></tr></tbody></table></div><aside class="gd-box"><span class="gd-lbl">Tip</span><div>A commission that changes after an owner statement was built (a refund, or the month&#39;s Sales tier) goes on the owner&#39;s next statement as an adjustment line.</div></aside></section><section class="gd-task" id="owner-money-field-pay" data-gd-task><h2 class="gd-h2">Field pay</h2><p class="gd-p"><b class="gd-ui">Money</b> &gt; <b class="gd-ui">Company</b>, the <b class="gd-ui">Field pay</b> tab. Field staff clock in and out on their phones (My hours); you run the pay every two weeks. Nothing is paid automatically.</p><ol class="gd-flow"><li><b>1</b><span>Clocked in and out</span><em>Field staff press Clock in and Clock out; Fleet or you fix a forgotten clock-out</em></li><li><b>2</b><span>Pay run started</span><em>Hours times the hourly rate, plus the approved commissions</em></li><li><b>3</b><span>Approved</span><em>The figures are frozen, the period&#39;s hours are locked, the statements are numbered</em></li><li><b>4</b><span>Paid</span><em>You recorded how each person was paid; they get their statement by email</em></li></ol><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">The tab <b class="gd-ui">Pay run</b> shows the current two-week period (Sunday to Saturday: the first day is Settings &gt; Program, Field pay). <b class="gd-ui">Earlier period</b> and <b class="gd-ui">Later period</b> move between periods.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">After the period ends, press <b class="gd-ui">Start the payroll</b>: one line for each person with hours times their hourly rate, plus the staff commissions and referral fees approved by the end of the period (see Staff commissions). <b class="gd-ui">Refresh the figures</b> takes in a change made since.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Press <b class="gd-ui">Approve</b>. The period&#39;s hours are locked, each line gets a statement number and the figures are frozen. Someone still clocked in blocks it: fix their shift under <b class="gd-ui">Hours</b> first. <b class="gd-ui">Withdraw</b> takes an approved run back while no payment is recorded.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t">Press <b class="gd-ui">Record payment</b> on a line: choose e-Transfer, bank transfer or cash, the reference (not needed for cash) and the date. The commissions in the line are marked paid and the person gets their pay statement by email (<b class="gd-ui">Send again</b> repeats it). The statement&#39;s number opens its PDF; <b class="gd-ui">CSV</b> gives the run for your accountant.</div></li><li><span class="gd-n" aria-hidden="true">5</span><div class="gd-t"><b class="gd-ui">Hours</b> lists everyone&#39;s shifts of the period. <b class="gd-ui">Add hours</b> enters a shift for someone who forgot to clock in, <b class="gd-ui">Change</b> fixes one and <b class="gd-ui">Remove</b> takes one out. Each needs a reason and is kept in a log. Fleet does the same under Field hours but sees no pay.</div></li><li><span class="gd-n" aria-hidden="true">6</span><div class="gd-t"><b class="gd-ui">Hourly rates</b> shows each person&#39;s rate: CA$18.00 an hour unless you give them their own with <b class="gd-ui">Set the rate</b> (a reason is needed). A pay run keeps the rate it was started with.</div></li></ol></div><div class="gd-tablewrap"><table class="gd-table"><thead><tr><th scope="col"></th><th scope="col">Field pay</th></tr></thead><tbody><tr><td>Overtime</td><td>Off. Settings &gt; Program, Field pay: pay overtime, after 44 hours in a week, at 150% of the rate</td></tr><tr><td>Vacation pay</td><td>Off. Settings &gt; Program, Field pay: vacation pay (Ontario: 4%) adds that share of wages, overtime and commissions to each statement</td></tr><tr><td>Deductions</td><td>None are worked out: income tax, CPP, EI and the employer&#39;s contributions are for your accountant. Each statement says so</td></tr><tr><td>Commissions that net to nothing</td><td>A person whose approved commissions add up to nothing or less (a clawback) is not paid them this period: they carry to the next</td></tr></tbody></table></div><aside class="gd-box"><span class="gd-lbl">Tip</span><div>A shift of more than 16 hours (a setting) is refused, and so are hours that overlap another shift of the same person. The field staff member sees their hours and statements under My hours on their phone.</div></aside></section><section class="gd-task" id="owner-money-company-model" data-gd-task><h2 class="gd-h2">Company model</h2><p class="gd-p">Money &gt; <b class="gd-ui">Company model</b> is the CarmaCars model workbook, live: the actuals, the forecast and the pro forma on one page. Admins only (not Finance). Never share it: investors have their own sheets in the investor portal.</p><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t"><b class="gd-ui">Forecast</b>: the latest actual month, the EBITDA break-even month, the next 12 months&#39; EBITDA and the lowest cash, a chart of EBITDA and cash, and 36 months marked A (actual) or F (forecast): cars, utilization, revenue per rented day, revenue, costs, EBITDA, investor returns, tax and cash.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t"><b class="gd-ui">Actuals</b>: filled in by themselves every hour from the bookings, payments, payouts, expenses and investments. Rental earned is spread over each rental&#39;s days (before HST, insurer-billed and renter-billed apart, placeholders left out), with fees by kind, cash received by method, rentals and rented days, owner and partner shares, commissions, kickbacks, expenses by category and investor payouts. <b class="gd-ui">Refresh actuals now</b> recomputes them at once.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t"><b class="gd-ui">Pro forma 5 years</b>: each year&#39;s income statement, cash flow and key figures.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t"><b class="gd-ui">Assumptions</b>: growth, the utilization ramp, rates, monthly costs, hires, planned capital raises, the fleet insurance premium and tax. Press <b class="gd-ui">Save the assumptions</b>; the forecast, the pro forma and the download use them at once. A field marked &quot;From the actuals&quot; left blank uses the latest complete month.</div></li><li><span class="gd-n" aria-hidden="true">5</span><div class="gd-t"><b class="gd-ui">Download as Excel</b>: the full internal workbook with live formulas and the current actuals.</div></li></ol></div><aside class="gd-box"><span class="gd-lbl">Tip</span><div>Enter the fleet insurance premium under Assumptions; until then it counts as $0 and profit is overstated. Enter each month&#39;s costs in Money &gt; Expenses: a cost line with nothing entered for an actual month uses the assumption, marked est.</div></aside></section><section class="gd-task" id="owner-money-payroll-for-everyone-release-35" data-gd-task><h2 class="gd-h2">Payroll for everyone (release 35)</h2><p class="gd-p"><b class="gd-ui">Money</b> &gt; <b class="gd-ui">Payroll</b> is one run every two weeks for the field staff (hours) and for customer service, Fleet and Finance (salary).</p><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">A salaried person is paid their monthly salary x 12 / 26, for the days they were employed in the period. The salary is their own (<b class="gd-ui">Set the salary</b>, with a reason), else the monthly pay they were hired at, else their role&#39;s (Program settings, va_salary_defaults), in US dollars unless set otherwise.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Finance prepares it: <b class="gd-ui">Start the payroll</b>, <b class="gd-ui">Add a bonus or deduction</b> with the reason, then <b class="gd-ui">Send for approval</b>. You get an alert.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">You press <b class="gd-ui">Approve</b>, then <b class="gd-ui">Record all payments</b> (one method and reference; each stub number is added to it) or <b class="gd-ui">Record payment</b> line by line. Each person gets their stub by email and in their portal.</div></li></ol></div><aside class="gd-box"><span class="gd-lbl">Tip</span><div>Admin &gt; Team also has <b class="gd-ui">Schedules</b> (each role&#39;s days and hours, anyone&#39;s own, who is late today) and <b class="gd-ui">KPIs</b> (every staff member&#39;s KPIs for a week against the targets in Program settings).</div></aside><aside class="gd-box"><span class="gd-lbl">Good to know</span><div>The townhall page: pick the craziest story, enter the week&#39;s social media figures, add the recording link, and mark anyone present or absent. Staff who miss two townhalls in a row are locked until you press <b class="gd-ui">Unlock</b> on the staff list.</div></aside><aside class="gd-box"><span class="gd-lbl">Good to know</span><div>Each renter and lead shows an Intent card (hot, warm or cold, with the budget, car, length, dates, urgency, delivery and coverage they mentioned). The live map shows it on each pin. An AI reading fills the gaps within the free daily allowance only (Program settings, intent_ai_enabled).</div></aside><aside class="gd-box"><span class="gd-lbl">Good to know</span><div>Investors see Search traction under the deck: Google clicks and impressions of the last 28 days, indexed pages and the weekly trend. Type the indexed pages from Search Console on the investor deck page under Investors (no API exists for it).</div></aside></section><section class="gd-task" id="owner-money-company-statements" data-gd-task><h2 class="gd-h2">Company statements</h2><p class="gd-p"><b class="gd-ui">Money</b> &gt; <b class="gd-ui">Company</b>, the <b class="gd-ui">Monthly statements</b> tab: CarmaCars&#39; own monthly statement, in twelve sections.</p><div class="gd-stepblock gd-stepblock--below"><div class="gd-stepcol"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">Choose the month. The tiles show revenue, fees, refunds, expenses and the company net.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Switch between Total, Per owner and Per vehicle.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Download <b class="gd-ui">PDF</b>, <b class="gd-ui">PDF by owner</b> or <b class="gd-ui">PDF by vehicle</b>, or press <b class="gd-ui">Email me the PDFs</b>.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t"><b class="gd-ui">Finalize</b> freezes the month. <b class="gd-ui">Rebuild</b> works until then.</div></li></ol></div><figure class="gd-fig gd-fig--desk"><div class="gd-browser"><div class="gd-bar" aria-hidden="true"><i></i><i></i><i></i><span class="gd-addr">carmacars.ca/admin/reports</span></div><div class="gd-imgwrap" style="aspect-ratio:1440/760"><img src="/guides/img/admin-18-company-statements-desktop-8e2738ed.jpg" alt="" loading="lazy" decoding="async" width="1440" height="760"><span class="gd-pin" style="left:20.8%;top:28%" aria-hidden="true">1</span><span class="gd-pin" style="left:19.4%;top:59.3%" aria-hidden="true">2</span><span class="gd-pin" style="left:77.1%;top:15.5%" aria-hidden="true">3</span><span class="gd-pin" style="left:46.9%;top:15.5%" aria-hidden="true">4</span></div></div></figure></div><h3 class="gd-h3">Fees taken from the revenue statement</h3><p class="gd-p">On an owner&#39;s page, the <b class="gd-ui">Fees</b> button sets <b class="gd-ui">How fees are paid</b>: <b class="gd-ui">Bank debit</b> (the default) or <b class="gd-ui">Take from revenue statement</b>. Taken from the statement, the owner&#39;s invoices (not the upfront one) are not debited: the next owner statement pays each one from the payout, as far as it goes, with the line &quot;Invoice INV-..., paid from statement&quot;. Approved, the invoice reads <b class="gd-ui">Paid from statement</b>, or part paid with the rest on the next statement. An invoice still owing 2 months after its billing date goes back to the bank debit after the usual notice, and you get the task <b class="gd-ui">Invoice ... back to the bank debit</b>.</p><h3 class="gd-h3">The flat-rate agreements</h3><p class="gd-p">An owner whose every car is on a flat monthly payment signs the <b class="gd-ui">Flat-Rate Vehicle Enrollment Agreement</b> instead of the standard one (the Title-Holding and Lease Agreement and Forms A to D are the same). The owner&#39;s page says which set applies. When the pay model changes, the signed Enrollment Agreement ends and the owner signs the new one in the owner portal; changed back before signing, the signed one is in force again. The lawyer approved the flat-rate set: Program settings &gt; <b class="gd-ui">Flat-rate agreements awaiting lawyer OK</b> is off, and is turned on only to mark a new text still under review. Owners can sign either way.</p></section><section class="gd-task" id="owner-money-how-it-s-paid-bank-debit-or-deducted-from-payouts" data-gd-task><h2 class="gd-h2">How it&#39;s paid: bank debit or deducted from payouts</h2><p class="gd-p">Every owner invoice is paid one of two ways: <b class="gd-ui">Bank debit on the 15th</b>, or <b class="gd-ui">Deduct from payouts</b> (taken from the owner&#39;s monthly payouts until paid, never debited).</p><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">On an invoice, <b class="gd-ui">How it&#39;s paid</b>, <b class="gd-ui">Change</b>. A draft changed to Deduct from payouts is issued without the debit email.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Each monthly statement deducts as much as the payout allows and shows it to the owner as a deduction; the rest waits for the next statement. The invoice screen shows what was deducted and what is left.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">For the first and last month, choose <b class="gd-ui">Deduct from payouts</b> on the Terms tab (or at approval).</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t">On the Terms tab, <b class="gd-ui">Charge the agreed one-off fees</b> makes one invoice for a car from the one-off fees agreed on the owner&#39;s terms (all, or the ones you name), deducted from payouts or debited.</div></li></ol></div></section><section class="gd-task" id="owner-money-referral-links-between-owners-release-28" data-gd-task><h2 class="gd-h2">Referral links between owners (release 28)</h2><p class="gd-p">When one owner referred another, open the referrer&#39;s <b class="gd-ui">Terms</b> tab, <b class="gd-ui">Referral links</b>, <b class="gd-ui">This owner referred another owner</b>: choose the owner referred and the share in basis points (1000 = 10 points of the revenue the management fee is taken from). Set the referred owner&#39;s own fee on their Terms as usual (for example a 40% management fee and $350 a month per car). Every statement of the referrer then has a <b class="gd-ui">Referral share</b> line per referred car; it is paid from CarmaCars&#39; share, never the referred owner&#39;s payout. With <b class="gd-ui">sees the cars</b> on, the referrer finds <b class="gd-ui">Cars you referred</b> in their owner portal: bookings, use and revenue, read only, without the other owner&#39;s details. <b class="gd-ui">End</b> stops the link; shares already earned are still paid.</p></section><section class="gd-task" id="owner-money-statement-periods-release-35" data-gd-task><h2 class="gd-h2">Statement periods (release 35)</h2><p class="gd-p">Statements run from the 8th of one month to the 7th of the next, and the payout on the 10th covers them. A rental that crosses the cutoff, or a long weekly or biweekly rental, is paid for the days inside each period, never twice. Each statement lists amounts still uncollected from the renter separately; they are paid on the statement after they are collected.</p></section>');
select app.guide_release_section('admin', 'texts-and-calls-the-quo-phone-line', 'chapter', 'live-visitors-and-live-chat', 'Every call and text on the CarmaCars number (Quo) is kept and matched to the person: staff, a renter and their booking, an owner or a lead. Staff answer texts from the same inbox as live chat. It is on by default; Program settings switch each part.

## The inbox

1. Open **Today** > **Visitors**, the **Chat** tab, and press **Texts and calls**. Each number shows who it is (Renter, Owner, Lead, Staff or Unknown caller), unread texts and missed calls.
2. Choose a number. Calls and texts are in order; a call shows its length, and Quo''s summary or a one-line AI summary when there is one.
3. Write a text and press **Send text**: it goes from the CarmaCars number through Quo. **Suggest a reply** puts an AI draft in the box; nothing is ever sent until you press Send text.
4. Beside the conversation: the renter with their bookings, the owner or the lead. A caller who gave the same phone in live chat or a discount game shows their visit on the site.
5. **Stop texts** stops every text to the number, booking texts included. A person who texts STOP is stopped the same way; START allows texts again.

## Unknown callers

Press **Unknown callers**. For a number nobody on file has, type the name if you know it and press **Create lead**, or find the renter and press **Link to** the name. The calls and texts so far follow the link. **Match automatically again** undoes a link made by hand.

## Missed calls

A missed call raises the task "Missed call from ..." for the person on duty in customer service (whoever has Live chat or Texts and calls open), otherwise the customer service queue, and the Admins when nobody holds that function. In the quiet hours (11 pm to 7 am) the task is due at 7 am. One open task per number.

> Tip: Quo itself texts back missed callers (its own auto-reply). The platform can do it instead (Program settings, "Missed call: text the caller back"), once per number in 12 hours: turn off Quo''s own auto-reply first, or callers get two texts.

## Calls and texts on records

A renter''s page and a booking''s Messages & history section show the texts, calls, missed calls, voicemails and summaries in the Activity log (chips **Texts** and **Calls**); an owner''s page has "Calls and texts". Calls are recorded: each call has its transcript and a one-line summary in the Activity log, and calls placed from the site''s Call button are recorded too (below).

## The Activity log (release 35)

A renter''s page and a booking''s **Messages & history** section have one **Activity** log: everything about the renter, newest first, grouped by day. It holds the emails and account messages both ways and the emails the platform sent, the texts, the live chat, the calls with their summaries and next steps, the notes, the booking''s events, the payments and refunds, the documents, identity checks and signatures, and the visits to the site with what they did there and the signals.

1. **All** shows everything. Press a chip (Emails, Texts, Live chat, Calls, Notes, Booking, Payments, Documents and ID, Website) to see one type; press **All** to go back.
2. Type in **Search the activity** and press **Search** to find a word in the log; **Clear** takes it away.
3. 50 lines show at a time: **Older** shows the next 50, **Newest** goes back to the top.
4. **Email**, **Call** and **Text** are at the top of the log. An email from the renter has **Reply**, a text or call from them **Text** or **Call**, a chat line **Open the chat**.
5. **Add a note** is above the log; the note shows in it at once.

> Good to know: Payments show to Admins, customer service, Sales and Finance, as the booking''s Money section. The log never shows an email address or a phone number.

## Quo contacts

Everyone on the site with a phone number is a contact in Quo under the same name, with their email and company: staff, renters and their drivers, owners, partners, investors, referral partners, job applicants, named visitors, leads, chauffeur clients, live chats, game players and forms left unfinished.

- A new person is added within about five minutes; a changed name, phone or email is updated the same way. Change people on the site, not in Quo: the site''s version is sent again.
- One contact per number. When two records share a number, the strongest names the contact: staff, then a renter, a driver, an owner, a partner. A number without any name is not sent.
- A contact someone already made in Quo for the number is updated rather than made twice, and its other numbers and emails are kept.
- If Quo is down or slow, bookings and everything else go on; the contacts follow when it answers again.
- **Settings**, **Quo contacts**: how many are in Quo, waiting and in error, the last run and the last error, and **Sync everyone again**. Program settings, "Phone and texts (Quo)", turn it off.

## Booking texts

Since October 22, 2026 these are text alerts: each person chooses Email, Text or Both (the chapter Text alerts, below, and **Settings**, **Text alerts**).

## The settings

Program settings, "Phone and texts (Quo)": the line on or off, calls and texts kept, the missed-call text and its task, who calls back, AI suggestions and summaries with their daily neurons, the visit of a caller, and how long calls and texts of people who are not customers are kept (12 months).


## Call and Text buttons

Every Call and Text button in Admin and the staff portal (a booking, a renter, the Now view, the map''s cards, Visitors, the field jobs) goes through Quo, from the CarmaCars number.

1. Press **Text**: a small window opens with the person and the number. Write the text (sign it CarmaCars) and press **Send**. It goes out from the CarmaCars number at once and is kept in the person''s conversation under **Today** > **Visitors** > **Chat** > **Texts and calls**; press **Open the conversation** to see it there. A number that asked for no texts is refused with the reason.
2. Press **Call**: on a phone the Quo app opens with the number in its dialer; press call there. On a computer the Quo web app opens in a new tab and the number is copied: open the dialer (Alt+C, or Ctrl+C on a Mac) and paste it. If Quo''s desktop app is your computer''s calling app, tick **On this computer, call with the Quo desktop app** once: Call then opens it straight away. Every call is noted on the conversation as Call started from the site, and Quo adds the call itself when it ends.
3. Fleet, finance and field staff can call and text the people of their work (renters, owners, leads and staff); customer service and Sales any number.
4. To use the phone''s own phone and messages apps instead, turn off **Call and Text buttons go through Quo** in **Settings** > **Program**. With Phone and texts off, the buttons use the phone''s own apps too.

## The CarmaCars app links

**Settings** > **Program**, card The CarmaCars app (App Store and Google Play). Paste the App Store link (https://apps.apple.com/...) and the Google Play link (https://play.google.com/...) once the apps are live and press Save. From then on, iPhones and Android phones browsing the site see **Download the CarmaCars app** in the footer and in the alerts invitation, with the link of their own store. Empty, nothing shows.

## Who is calling: the caller pop-up (release 34)

When someone calls the CarmaCars number, a panel opens at the bottom right of every Admin page (across the bottom on a phone) while the phone rings, and stays while the call goes on and for 3 minutes after it ends. Customer service get the same panel in their portal. The number is matched to the renter on file (their mobile or their account holder''s), the same way Texts and calls matches it.

1. A renter: their name, the booking on rent (or the next one coming) with the car, the balance they owe now (rental payments due and unpaid charges after a rental, **overdue** when a payment is late), the deposit (held, waived, released, or not taken yet), what they are waiting on (a booking request or offer, a change, a question to them, an open To do) and the last three notes.
2. Write what the call was about in **Note about this call** and press **Add note**: it is kept on the renter with the time, your name and the booking.
3. **Open the renter''s page** opens the full record. The booking opens from its line.
4. An unknown number shows **Unknown caller**: press **Create lead** to keep it as a phone lead, then open the conversation in Texts and calls to name it.
5. Press the cross to close a call; it stays closed in this browser. The panel checks for calls every 10 seconds while you use the portal (once a minute when the page is left alone).

## Renter notes (release 34)

Every renter page has **Add a note**, and its Activity log lists the notes (chip **Notes**): what staff noted about the renter, newest first, with the date and time, who wrote it and their role, the booking and the words during a call when it was written from the pop-up. Admins and office staff add notes; nobody can change one. To take one away, press **Remove** and give the reason: it is no longer shown, and the note, the removal and the reason stay in the audit log. The same notes show on the caller pop-up, on a renter''s conversation in Texts and calls, and on the staff portal''s renter.

## The Call button through Twilio (release 35)
Quo keeps incoming calls, texts and AI answering. **Call** on a staff page rings the staff member''s own cell, then connects the customer with the CarmaCars number as caller ID, and logs the call with its length and outcome on the renter, lead or booking. It needs the GitHub secrets TWILIO_ACCOUNT_SID, TWILIO_API_KEY and TWILIO_API_SECRET (and the CarmaCars number as a verified caller ID in Twilio); until then **Call** opens Quo and says why.

Sales sees customer numbers hidden. Viewing as a Sales rep, **Reveal** shows a number; every reveal is in the audit log.

## Unanswered

**Leads** > **Unanswered** (customer service has it too): every customer text with no reply and every missed call not called back, oldest first. **Reply** or **Call back** opens the conversation; **Mark answered** when it was answered another way. A customer waiting more than 15 minutes (Program settings, **Unanswered SLA minutes**) alerts customer service and the Admins once. WhatsApp is not in the list: the morning digest reminds you to check it.

## Call recording and transcripts (release 35)

Calls placed from the site''s Call button are recorded from the moment the customer answers. No caller notice plays.

1. The recording is copied to CarmaCars'' private storage and deleted at Twilio once our copy is safe (Program settings, on by default).
2. It is turned into text with the free daily AI allowance; when the allowance is used, the call waits for the next day.
3. The transcript, its summary and Play recording show on the renter''s, the lead''s, the booking''s and the conversation''s history, for Admins, customer service and Sales.
4. The transcript feeds the renter''s and the lead''s intent at once (hot, warm or cold, with what they said they want).
5. Recording and deleting at Twilio are two switches in Program settings, under the phone settings.', 'Texts and calls (the Quo phone line)', 'Texts and calls in the chat inbox, unknown callers, missed calls, booking texts, call summaries and the settings.',
  'Every call and text on the CarmaCars number (Quo) is kept and matched to the person: staff, a renter and their booking, an owner or a lead. Staff answer texts from the same inbox as live chat. It is on by default; Program settings switch each part.

## The inbox

1. Open **Today** > **Visitors**, the **Chat** tab, and press **Texts and calls**. Each number shows who it is (Renter, Owner, Lead, Staff or Unknown caller), unread texts and missed calls.
2. Choose a number. Calls and texts are in order; a call shows its length, and Quo''s summary or a one-line AI summary when there is one.
3. Write a text and press **Send text**: it goes from the CarmaCars number through Quo. **Suggest a reply** puts an AI draft in the box; nothing is ever sent until you press Send text.
4. Beside the conversation: the renter with their bookings, the owner or the lead. A caller who gave the same phone in live chat or a discount game shows their visit on the site.
5. **Stop texts** stops every text to the number, booking texts included. A person who texts STOP is stopped the same way; START allows texts again.

## Unknown callers

Press **Unknown callers**. For a number nobody on file has, type the name if you know it and press **Create lead**, or find the renter and press **Link to** the name. The calls and texts so far follow the link. **Match automatically again** undoes a link made by hand.

## Missed calls

A missed call raises the task "Missed call from ..." for the person on duty in customer service (whoever has Live chat or Texts and calls open), otherwise the customer service queue, and the Admins when nobody holds that function. In the quiet hours (11 pm to 7 am) the task is due at 7 am. One open task per number.

> Tip: Quo itself texts back missed callers (its own auto-reply). The platform can do it instead (Program settings, "Missed call: text the caller back"), once per number in 12 hours: turn off Quo''s own auto-reply first, or callers get two texts.

## Calls and texts on records

A renter''s page and a booking''s Messages & history section show the texts, calls, missed calls, voicemails and summaries in the Activity log (chips **Texts** and **Calls**); an owner''s page has "Calls and texts". Calls are recorded: each call has its transcript and a one-line summary in the Activity log, and calls placed from the site''s Call button are recorded too (below).

## The Activity log (release 35)

A renter''s page and a booking''s **Messages & history** section have one **Activity** log: everything about the renter, newest first, grouped by day. It holds the emails and account messages both ways and the emails the platform sent, the texts, the live chat, the calls with their summaries and next steps, the notes, the booking''s events, the payments and refunds, the documents, identity checks and signatures, and the visits to the site with what they did there and the signals.

1. **All** shows everything. Press a chip (Emails, Texts, Live chat, Calls, Notes, Booking, Payments, Documents and ID, Website) to see one type; press **All** to go back.
2. Type in **Search the activity** and press **Search** to find a word in the log; **Clear** takes it away.
3. 50 lines show at a time: **Older** shows the next 50, **Newest** goes back to the top.
4. **Email**, **Call** and **Text** are at the top of the log. An email from the renter has **Reply**, a text or call from them **Text** or **Call**, a chat line **Open the chat**.
5. **Add a note** is above the log; the note shows in it at once.

> Good to know: Payments show to Admins, customer service, Sales and Finance, as the booking''s Money section. The log never shows an email address or a phone number.

## Quo contacts

Everyone on the site with a phone number is a contact in Quo under the same name, with their email and company: staff, renters and their drivers, owners, partners, investors, referral partners, job applicants, named visitors, leads, chauffeur clients, live chats, game players and forms left unfinished.

- A new person is added within about five minutes; a changed name, phone or email is updated the same way. Change people on the site, not in Quo: the site''s version is sent again.
- One contact per number. When two records share a number, the strongest names the contact: staff, then a renter, a driver, an owner, a partner. A number without any name is not sent.
- A contact someone already made in Quo for the number is updated rather than made twice, and its other numbers and emails are kept.
- If Quo is down or slow, bookings and everything else go on; the contacts follow when it answers again.
- **Settings**, **Quo contacts**: how many are in Quo, waiting and in error, the last run and the last error, and **Sync everyone again**. Program settings, "Phone and texts (Quo)", turn it off.

## Booking texts

Since October 22, 2026 these are text alerts: each person chooses Email, Text or Both (the chapter Text alerts, below, and **Settings**, **Text alerts**).

## The settings

Program settings, "Phone and texts (Quo)": the line on or off, calls and texts kept, the missed-call text and its task, who calls back, AI suggestions and summaries with their daily neurons, the visit of a caller, and how long calls and texts of people who are not customers are kept (12 months).


## Call and Text buttons

Every Call and Text button in Admin and the staff portal (a booking, a renter, the Now view, the map''s cards, Visitors, the field jobs) goes through Quo, from the CarmaCars number.

1. Press **Text**: a small window opens with the person and the number. Write the text (sign it CarmaCars) and press **Send**. It goes out from the CarmaCars number at once and is kept in the person''s conversation under **Today** > **Visitors** > **Chat** > **Texts and calls**; press **Open the conversation** to see it there. A number that asked for no texts is refused with the reason.
2. Press **Call**: on a phone the Quo app opens with the number in its dialer; press call there. On a computer the Quo web app opens in a new tab and the number is copied: open the dialer (Alt+C, or Ctrl+C on a Mac) and paste it. If Quo''s desktop app is your computer''s calling app, tick **On this computer, call with the Quo desktop app** once: Call then opens it straight away. Every call is noted on the conversation as Call started from the site, and Quo adds the call itself when it ends.
3. Fleet, finance and field staff can call and text the people of their work (renters, owners, leads and staff); customer service and Sales any number.
4. To use the phone''s own phone and messages apps instead, turn off **Call and Text buttons go through Quo** in **Settings** > **Program**. With Phone and texts off, the buttons use the phone''s own apps too.

## The CarmaCars app links

**Settings** > **Program**, card The CarmaCars app (App Store and Google Play). Paste the App Store link (https://apps.apple.com/...) and the Google Play link (https://play.google.com/...) once the apps are live and press Save. From then on, iPhones and Android phones browsing the site see **Download the CarmaCars app** in the footer and in the alerts invitation, with the link of their own store. Empty, nothing shows.

## Who is calling: the caller pop-up (release 34)

When someone calls the CarmaCars number, a panel opens at the bottom right of every Admin page (across the bottom on a phone) while the phone rings, and stays while the call goes on and for 3 minutes after it ends. Customer service get the same panel in their portal. The number is matched to the renter on file (their mobile or their account holder''s), the same way Texts and calls matches it.

1. A renter: their name, the booking on rent (or the next one coming) with the car, the balance they owe now (rental payments due and unpaid charges after a rental, **overdue** when a payment is late), the deposit (held, waived, released, or not taken yet), what they are waiting on (a booking request or offer, a change, a question to them, an open To do) and the last three notes.
2. Write what the call was about in **Note about this call** and press **Add note**: it is kept on the renter with the time, your name and the booking.
3. **Open the renter''s page** opens the full record. The booking opens from its line.
4. An unknown number shows **Unknown caller**: press **Create lead** to keep it as a phone lead, then open the conversation in Texts and calls to name it.
5. Press the cross to close a call; it stays closed in this browser. The panel checks for calls every 10 seconds while you use the portal (once a minute when the page is left alone).

## Renter notes (release 34)

Every renter page has **Add a note**, and its Activity log lists the notes (chip **Notes**): what staff noted about the renter, newest first, with the date and time, who wrote it and their role, the booking and the words during a call when it was written from the pop-up. Admins and office staff add notes; nobody can change one. To take one away, press **Remove** and give the reason: it is no longer shown, and the note, the removal and the reason stay in the audit log. The same notes show on the caller pop-up, on a renter''s conversation in Texts and calls, and on the staff portal''s renter.

## The Call button through Twilio (release 35)
Quo keeps incoming calls, texts and AI answering. **Call** on a staff page rings the staff member''s own cell, then connects the customer with the CarmaCars number as caller ID, and logs the call with its length and outcome on the renter, lead or booking. It needs the GitHub secrets TWILIO_ACCOUNT_SID, TWILIO_API_KEY and TWILIO_API_SECRET (and the CarmaCars number as a verified caller ID in Twilio); until then **Call** opens Quo and says why.

Sales sees customer numbers hidden. Viewing as a Sales rep, **Reveal** shows a number; every reveal is in the audit log.

## Unanswered

**Leads** > **Unanswered** (customer service has it too): every customer text with no reply and every missed call not called back, oldest first. **Reply** or **Call back** opens the conversation; **Mark answered** when it was answered another way. A customer waiting more than 15 minutes (Program settings, **Unanswered SLA minutes**) alerts customer service and the Admins once. WhatsApp is not in the list: the morning digest reminds you to check it.

## Call recording and transcripts (release 35)

Calls placed from the site''s Call button are recorded from the moment the customer answers. No caller notice plays.

1. The recording is copied to CarmaCars'' private storage and deleted at Twilio once our copy is safe (Program settings, on by default).
2. It is turned into text with the free daily AI allowance; when the allowance is used, the call waits for the next day.
3. The transcript, its summary and Play recording show on the renter''s, the lead''s, the booking''s and the conversation''s history, for Admins, customer service and Sales.
4. The transcript feeds the renter''s and the lead''s intent at once (hot, warm or cold, with what they said they want).
5. Recording and deleting at Twilio are two switches in Program settings, under the phone settings.

## Calls first, texts after (release 37)

Your main priority is always to be on the phone with people.

1. Answer a ringing call before anything else, and return a missed call at once.
2. **Call before you text.** On a lead, a renter or a booking, **Call** is the first button and **Text** the second.
3. A text is a follow-up: after a call attempt (no answer, a voicemail left), or when the person asked for a text.
4. On your To do and on **Unanswered**, missed calls and call-backs are listed above unanswered texts.',
  '<p class="gd-p">Every call and text on the CarmaCars number (Quo) is kept and matched to the person: staff, a renter and their booking, an owner or a lead. Staff answer texts from the same inbox as live chat. It is on by default; Program settings switch each part.</p><section class="gd-task" id="texts-and-calls-the-quo-phone-line-the-inbox" data-gd-task><h2 class="gd-h2">The inbox</h2><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">Open <b class="gd-ui">Today</b> &gt; <b class="gd-ui">Visitors</b>, the <b class="gd-ui">Chat</b> tab, and press <b class="gd-ui">Texts and calls</b>. Each number shows who it is (Renter, Owner, Lead, Staff or Unknown caller), unread texts and missed calls.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Choose a number. Calls and texts are in order; a call shows its length, and Quo&#39;s summary or a one-line AI summary when there is one.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Write a text and press <b class="gd-ui">Send text</b>: it goes from the CarmaCars number through Quo. <b class="gd-ui">Suggest a reply</b> puts an AI draft in the box; nothing is ever sent until you press Send text.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t">Beside the conversation: the renter with their bookings, the owner or the lead. A caller who gave the same phone in live chat or a discount game shows their visit on the site.</div></li><li><span class="gd-n" aria-hidden="true">5</span><div class="gd-t"><b class="gd-ui">Stop texts</b> stops every text to the number, booking texts included. A person who texts STOP is stopped the same way; START allows texts again.</div></li></ol></div></section><section class="gd-task" id="texts-and-calls-the-quo-phone-line-unknown-callers" data-gd-task><h2 class="gd-h2">Unknown callers</h2><p class="gd-p">Press <b class="gd-ui">Unknown callers</b>. For a number nobody on file has, type the name if you know it and press <b class="gd-ui">Create lead</b>, or find the renter and press <b class="gd-ui">Link to</b> the name. The calls and texts so far follow the link. <b class="gd-ui">Match automatically again</b> undoes a link made by hand.</p></section><section class="gd-task" id="texts-and-calls-the-quo-phone-line-missed-calls" data-gd-task><h2 class="gd-h2">Missed calls</h2><p class="gd-p">A missed call raises the task &quot;Missed call from ...&quot; for the person on duty in customer service (whoever has Live chat or Texts and calls open), otherwise the customer service queue, and the Admins when nobody holds that function. In the quiet hours (11 pm to 7 am) the task is due at 7 am. One open task per number.</p><aside class="gd-box"><span class="gd-lbl">Tip</span><div>Quo itself texts back missed callers (its own auto-reply). The platform can do it instead (Program settings, &quot;Missed call: text the caller back&quot;), once per number in 12 hours: turn off Quo&#39;s own auto-reply first, or callers get two texts.</div></aside></section><section class="gd-task" id="texts-and-calls-the-quo-phone-line-calls-and-texts-on-records" data-gd-task><h2 class="gd-h2">Calls and texts on records</h2><p class="gd-p">A renter&#39;s page and a booking&#39;s Messages &amp; history section show the texts, calls, missed calls, voicemails and summaries in the Activity log (chips <b class="gd-ui">Texts</b> and <b class="gd-ui">Calls</b>); an owner&#39;s page has &quot;Calls and texts&quot;. Calls are recorded: each call has its transcript and a one-line summary in the Activity log, and calls placed from the site&#39;s Call button are recorded too (below).</p></section><section class="gd-task" id="texts-and-calls-the-quo-phone-line-the-activity-log-release-35" data-gd-task><h2 class="gd-h2">The Activity log (release 35)</h2><p class="gd-p">A renter&#39;s page and a booking&#39;s <b class="gd-ui">Messages &amp; history</b> section have one <b class="gd-ui">Activity</b> log: everything about the renter, newest first, grouped by day. It holds the emails and account messages both ways and the emails the platform sent, the texts, the live chat, the calls with their summaries and next steps, the notes, the booking&#39;s events, the payments and refunds, the documents, identity checks and signatures, and the visits to the site with what they did there and the signals.</p><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t"><b class="gd-ui">All</b> shows everything. Press a chip (Emails, Texts, Live chat, Calls, Notes, Booking, Payments, Documents and ID, Website) to see one type; press <b class="gd-ui">All</b> to go back.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Type in <b class="gd-ui">Search the activity</b> and press <b class="gd-ui">Search</b> to find a word in the log; <b class="gd-ui">Clear</b> takes it away.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">50 lines show at a time: <b class="gd-ui">Older</b> shows the next 50, <b class="gd-ui">Newest</b> goes back to the top.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t"><b class="gd-ui">Email</b>, <b class="gd-ui">Call</b> and <b class="gd-ui">Text</b> are at the top of the log. An email from the renter has <b class="gd-ui">Reply</b>, a text or call from them <b class="gd-ui">Text</b> or <b class="gd-ui">Call</b>, a chat line <b class="gd-ui">Open the chat</b>.</div></li><li><span class="gd-n" aria-hidden="true">5</span><div class="gd-t"><b class="gd-ui">Add a note</b> is above the log; the note shows in it at once.</div></li></ol></div><aside class="gd-box"><span class="gd-lbl">Good to know</span><div>Payments show to Admins, customer service, Sales and Finance, as the booking&#39;s Money section. The log never shows an email address or a phone number.</div></aside></section><section class="gd-task" id="texts-and-calls-the-quo-phone-line-quo-contacts" data-gd-task><h2 class="gd-h2">Quo contacts</h2><p class="gd-p">Everyone on the site with a phone number is a contact in Quo under the same name, with their email and company: staff, renters and their drivers, owners, partners, investors, referral partners, job applicants, named visitors, leads, chauffeur clients, live chats, game players and forms left unfinished.</p><ul class="gd-ul"><li>A new person is added within about five minutes; a changed name, phone or email is updated the same way. Change people on the site, not in Quo: the site&#39;s version is sent again.</li><li>One contact per number. When two records share a number, the strongest names the contact: staff, then a renter, a driver, an owner, a partner. A number without any name is not sent.</li><li>A contact someone already made in Quo for the number is updated rather than made twice, and its other numbers and emails are kept.</li><li>If Quo is down or slow, bookings and everything else go on; the contacts follow when it answers again.</li><li><b class="gd-ui">Settings</b>, <b class="gd-ui">Quo contacts</b>: how many are in Quo, waiting and in error, the last run and the last error, and <b class="gd-ui">Sync everyone again</b>. Program settings, &quot;Phone and texts (Quo)&quot;, turn it off.</li></ul></section><section class="gd-task" id="texts-and-calls-the-quo-phone-line-booking-texts" data-gd-task><h2 class="gd-h2">Booking texts</h2><p class="gd-p">Since October 22, 2026 these are text alerts: each person chooses Email, Text or Both (the chapter Text alerts, below, and <b class="gd-ui">Settings</b>, <b class="gd-ui">Text alerts</b>).</p></section><section class="gd-task" id="texts-and-calls-the-quo-phone-line-the-settings" data-gd-task><h2 class="gd-h2">The settings</h2><p class="gd-p">Program settings, &quot;Phone and texts (Quo)&quot;: the line on or off, calls and texts kept, the missed-call text and its task, who calls back, AI suggestions and summaries with their daily neurons, the visit of a caller, and how long calls and texts of people who are not customers are kept (12 months).</p></section><section class="gd-task" id="texts-and-calls-the-quo-phone-line-call-and-text-buttons" data-gd-task><h2 class="gd-h2">Call and Text buttons</h2><p class="gd-p">Every Call and Text button in Admin and the staff portal (a booking, a renter, the Now view, the map&#39;s cards, Visitors, the field jobs) goes through Quo, from the CarmaCars number.</p><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">Press <b class="gd-ui">Text</b>: a small window opens with the person and the number. Write the text (sign it CarmaCars) and press <b class="gd-ui">Send</b>. It goes out from the CarmaCars number at once and is kept in the person&#39;s conversation under <b class="gd-ui">Today</b> &gt; <b class="gd-ui">Visitors</b> &gt; <b class="gd-ui">Chat</b> &gt; <b class="gd-ui">Texts and calls</b>; press <b class="gd-ui">Open the conversation</b> to see it there. A number that asked for no texts is refused with the reason.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Press <b class="gd-ui">Call</b>: on a phone the Quo app opens with the number in its dialer; press call there. On a computer the Quo web app opens in a new tab and the number is copied: open the dialer (Alt+C, or Ctrl+C on a Mac) and paste it. If Quo&#39;s desktop app is your computer&#39;s calling app, tick <b class="gd-ui">On this computer, call with the Quo desktop app</b> once: Call then opens it straight away. Every call is noted on the conversation as Call started from the site, and Quo adds the call itself when it ends.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Fleet, finance and field staff can call and text the people of their work (renters, owners, leads and staff); customer service and Sales any number.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t">To use the phone&#39;s own phone and messages apps instead, turn off <b class="gd-ui">Call and Text buttons go through Quo</b> in <b class="gd-ui">Settings</b> &gt; <b class="gd-ui">Program</b>. With Phone and texts off, the buttons use the phone&#39;s own apps too.</div></li></ol></div></section><section class="gd-task" id="texts-and-calls-the-quo-phone-line-the-carmacars-app-links" data-gd-task><h2 class="gd-h2">The CarmaCars app links</h2><p class="gd-p"><b class="gd-ui">Settings</b> &gt; <b class="gd-ui">Program</b>, card The CarmaCars app (App Store and Google Play). Paste the App Store link (https://apps.apple.com/...) and the Google Play link (https://play.google.com/...) once the apps are live and press Save. From then on, iPhones and Android phones browsing the site see <b class="gd-ui">Download the CarmaCars app</b> in the footer and in the alerts invitation, with the link of their own store. Empty, nothing shows.</p></section><section class="gd-task" id="texts-and-calls-the-quo-phone-line-who-is-calling-the-caller-pop-up-release-34" data-gd-task><h2 class="gd-h2">Who is calling: the caller pop-up (release 34)</h2><p class="gd-p">When someone calls the CarmaCars number, a panel opens at the bottom right of every Admin page (across the bottom on a phone) while the phone rings, and stays while the call goes on and for 3 minutes after it ends. Customer service get the same panel in their portal. The number is matched to the renter on file (their mobile or their account holder&#39;s), the same way Texts and calls matches it.</p><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">A renter: their name, the booking on rent (or the next one coming) with the car, the balance they owe now (rental payments due and unpaid charges after a rental, <b class="gd-ui">overdue</b> when a payment is late), the deposit (held, waived, released, or not taken yet), what they are waiting on (a booking request or offer, a change, a question to them, an open To do) and the last three notes.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Write what the call was about in <b class="gd-ui">Note about this call</b> and press <b class="gd-ui">Add note</b>: it is kept on the renter with the time, your name and the booking.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t"><b class="gd-ui">Open the renter&#39;s page</b> opens the full record. The booking opens from its line.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t">An unknown number shows <b class="gd-ui">Unknown caller</b>: press <b class="gd-ui">Create lead</b> to keep it as a phone lead, then open the conversation in Texts and calls to name it.</div></li><li><span class="gd-n" aria-hidden="true">5</span><div class="gd-t">Press the cross to close a call; it stays closed in this browser. The panel checks for calls every 10 seconds while you use the portal (once a minute when the page is left alone).</div></li></ol></div></section><section class="gd-task" id="texts-and-calls-the-quo-phone-line-renter-notes-release-34" data-gd-task><h2 class="gd-h2">Renter notes (release 34)</h2><p class="gd-p">Every renter page has <b class="gd-ui">Add a note</b>, and its Activity log lists the notes (chip <b class="gd-ui">Notes</b>): what staff noted about the renter, newest first, with the date and time, who wrote it and their role, the booking and the words during a call when it was written from the pop-up. Admins and office staff add notes; nobody can change one. To take one away, press <b class="gd-ui">Remove</b> and give the reason: it is no longer shown, and the note, the removal and the reason stay in the audit log. The same notes show on the caller pop-up, on a renter&#39;s conversation in Texts and calls, and on the staff portal&#39;s renter.</p></section><section class="gd-task" id="texts-and-calls-the-quo-phone-line-the-call-button-through-twilio-release-35" data-gd-task><h2 class="gd-h2">The Call button through Twilio (release 35)</h2><p class="gd-p">Quo keeps incoming calls, texts and AI answering. <b class="gd-ui">Call</b> on a staff page rings the staff member&#39;s own cell, then connects the customer with the CarmaCars number as caller ID, and logs the call with its length and outcome on the renter, lead or booking. It needs the GitHub secrets TWILIO_ACCOUNT_SID, TWILIO_API_KEY and TWILIO_API_SECRET (and the CarmaCars number as a verified caller ID in Twilio); until then <b class="gd-ui">Call</b> opens Quo and says why.</p><p class="gd-p">Sales sees customer numbers hidden. Viewing as a Sales rep, <b class="gd-ui">Reveal</b> shows a number; every reveal is in the audit log.</p></section><section class="gd-task" id="texts-and-calls-the-quo-phone-line-unanswered" data-gd-task><h2 class="gd-h2">Unanswered</h2><p class="gd-p"><b class="gd-ui">Leads</b> &gt; <b class="gd-ui">Unanswered</b> (customer service has it too): every customer text with no reply and every missed call not called back, oldest first. <b class="gd-ui">Reply</b> or <b class="gd-ui">Call back</b> opens the conversation; <b class="gd-ui">Mark answered</b> when it was answered another way. A customer waiting more than 15 minutes (Program settings, <b class="gd-ui">Unanswered SLA minutes</b>) alerts customer service and the Admins once. WhatsApp is not in the list: the morning digest reminds you to check it.</p></section><section class="gd-task" id="texts-and-calls-the-quo-phone-line-call-recording-and-transcripts-release-35" data-gd-task><h2 class="gd-h2">Call recording and transcripts (release 35)</h2><p class="gd-p">Calls placed from the site&#39;s Call button are recorded from the moment the customer answers. No caller notice plays.</p><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">The recording is copied to CarmaCars&#39; private storage and deleted at Twilio once our copy is safe (Program settings, on by default).</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">It is turned into text with the free daily AI allowance; when the allowance is used, the call waits for the next day.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">The transcript, its summary and Play recording show on the renter&#39;s, the lead&#39;s, the booking&#39;s and the conversation&#39;s history, for Admins, customer service and Sales.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t">The transcript feeds the renter&#39;s and the lead&#39;s intent at once (hot, warm or cold, with what they said they want).</div></li><li><span class="gd-n" aria-hidden="true">5</span><div class="gd-t">Recording and deleting at Twilio are two switches in Program settings, under the phone settings.</div></li></ol></div></section><section class="gd-task" id="texts-and-calls-the-quo-phone-line-calls-first-texts-after-release-37" data-gd-task><h2 class="gd-h2">Calls first, texts after (release 37)</h2><p class="gd-p">Your main priority is always to be on the phone with people.</p><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">Answer a ringing call before anything else, and return a missed call at once.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t"><b class="gd-ui">Call before you text.</b> On a lead, a renter or a booking, <b class="gd-ui">Call</b> is the first button and <b class="gd-ui">Text</b> the second.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">A text is a follow-up: after a call attempt (no answer, a voicemail left), or when the person asked for a text.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t">On your To do and on <b class="gd-ui">Unanswered</b>, missed calls and call-backs are listed above unanswered texts.</div></li></ol></div></section>');
select app.guide_release_section('admin', 'leads-and-sales-claims', 'chapter', 'text-alerts-email-text-or-both', 'Every lead in one place: people who are not renters or owners yet, from every source, with who is working on each one. Open **People** > **Renters** > **All leads**. An alert for a new lead (in the app, on the phone, or by email) opens that lead''s own page.

## What is in the list

- **Renter leads**: the contact form, live chat, the phone number box, discount game claims, offers that expired, booking requests typed and not sent, calls missed from a number with no booking (they arrive by themselves within 15 minutes), and Live visitors who turned Hot and left an email.
- **Owner leads**: owner program enquiries, owner applications started and not finished, owner form contacts and earnings calculator contacts. They are also under **People** > **Owners** > **Leads**, and each New owner program enquiry task opens its lead.
- **Partner leads**: fleet suppliers, dealers, rental businesses and insurers.

Each card shows the name, phone, email, the source in plain words (a live chat lead says Live chat), how old it is, and the start of what they wrote. New and hot leads come first. Open a lead for everything they wrote, the live chat transcript, their calls, every contact logged and the claim history.

## Work a lead

1. Press **Claim** on a card, or **Next lead** for the oldest hot lead nobody holds. It is yours for 15 minutes; nobody else can work on it meanwhile.
2. Press **Call**, **Text** or **Email**. Your phone or mail app opens and the contact is logged on the lead. Each call, text, email or **Note** adds another 15 minutes to your claim, up to 60 minutes from when you claimed it.
3. Press **Outcome** and choose Contacted, Call booked, Applied, Won (with the booking number when there is one) or Lost (say why). Won and lost close the lead.
4. Nothing more to do? Press **Mark handled**. Done with it for now? Press **Unclaim**: it goes back to the pool at once.

A claim that runs out returns the lead to the pool for everyone. One person holds at most 25 leads at a time. When a renter lead''s person books and the booking is confirmed, the lead closes as Won by itself, for the Sales person on the booking.

## As an Admin

- **Reassign** gives a lead to a person (their claim, and the lead is assigned to them). **Release** ends someone''s claim.
- **Sales team** shows each person''s leads claimed, won, close rate (won out of claimed), contacted, time to first contact and claims that ran out, today, this week or this month, best first.
- **Settings** > **Sales** sets how long a claim holds for renter, owner and partner leads (10 to 15 minutes suggested), the most a claim can be extended to, how many leads one person may hold, and how long a lead counts as hot.

> Good to know: Filters narrow the list by type, source, status, age, person and your own leads; the search finds a name, phone number, email or words they wrote.

## Rebooking, intent and leads (release 35)

- A returning renter''s new request goes straight to the salesperson of their last booking, with the usual claim time.
- Every renter and lead has an intent score (hot, warm or cold) with what they said they want: budget, car class, length, dates, urgency, delivery and coverage, read from calls (with their transcripts), texts, emails, the site chat and their visits.
- Leads are never given out by themselves: onboarded Sales claim them, one every 5 minutes, up to 3 open at once plus one for every 5 won in the last 30 days (at most 10).', 'Leads and Sales claims', 'Every lead in one place, claims, outcomes and the Sales team''s numbers.',
  'Every lead in one place: people who are not renters or owners yet, from every source, with who is working on each one. Open **People** > **Renters** > **All leads**. An alert for a new lead (in the app, on the phone, or by email) opens that lead''s own page.

## What is in the list

- **Renter leads**: the contact form, live chat, the phone number box, discount game claims, offers that expired, booking requests typed and not sent, calls missed from a number with no booking (they arrive by themselves within 15 minutes), and Live visitors who turned Hot and left an email.
- **Owner leads**: owner program enquiries, owner applications started and not finished, owner form contacts and earnings calculator contacts. They are also under **People** > **Owners** > **Leads**, and each New owner program enquiry task opens its lead.
- **Partner leads**: fleet suppliers, dealers, rental businesses and insurers.

Each card shows the name, phone, email, the source in plain words (a live chat lead says Live chat), how old it is, and the start of what they wrote. New and hot leads come first. Open a lead for everything they wrote, the live chat transcript, their calls, every contact logged and the claim history.

## Work a lead

1. Press **Claim** on a card, or **Next lead** for the oldest hot lead nobody holds. It is yours for 15 minutes; nobody else can work on it meanwhile.
2. Press **Call**, **Text** or **Email**. Your phone or mail app opens and the contact is logged on the lead. Each call, text, email or **Note** adds another 15 minutes to your claim, up to 60 minutes from when you claimed it.
3. Press **Outcome** and choose Contacted, Call booked, Applied, Won (with the booking number when there is one) or Lost (say why). Won and lost close the lead.
4. Nothing more to do? Press **Mark handled**. Done with it for now? Press **Unclaim**: it goes back to the pool at once.

A claim that runs out returns the lead to the pool for everyone. One person holds at most 25 leads at a time. When a renter lead''s person books and the booking is confirmed, the lead closes as Won by itself, for the Sales person on the booking.

## As an Admin

- **Reassign** gives a lead to a person (their claim, and the lead is assigned to them). **Release** ends someone''s claim.
- **Sales team** shows each person''s leads claimed, won, close rate (won out of claimed), contacted, time to first contact and claims that ran out, today, this week or this month, best first.
- **Settings** > **Sales** sets how long a claim holds for renter, owner and partner leads (10 to 15 minutes suggested), the most a claim can be extended to, how many leads one person may hold, and how long a lead counts as hot.

> Good to know: Filters narrow the list by type, source, status, age, person and your own leads; the search finds a name, phone number, email or words they wrote.

## Rebooking, intent and leads (release 35)

- A returning renter''s new request goes straight to the salesperson of their last booking, with the usual claim time.
- Every renter and lead has an intent score (hot, warm or cold) with what they said they want: budget, car class, length, dates, urgency, delivery and coverage, read from calls (with their transcripts), texts, emails, the site chat and their visits.
- Leads are never given out by themselves: onboarded Sales claim them, one every 5 minutes, up to 3 open at once plus one for every 5 won in the last 30 days (at most 10).

## Leads handled on a call by customer service or Fleet (release 37)

A lead that customer service or Fleet handle on a call (they answer or place the call, add a note, or create the lead from the call) is held for them for **Customer service and Fleet: a lead they handle on a call is held for** minutes in **Settings** > **Sales** (empty: the Sales claim minutes of its type). Each new handled call adds the time. Sales see **Being handled by** and cannot work it; **Next lead** skips it. **Release hold** on the lead ends it at once; it returns to the salesperson who had a claim on it or brought it, else the open list. Your own reassign also ends it. A booking made from the lead keeps the usual credit; the hold is not a claim, so customer service is never credited. Every step is in the lead''s history (hold, another call handled, hold ended).',
  '<p class="gd-p">Every lead in one place: people who are not renters or owners yet, from every source, with who is working on each one. Open <b class="gd-ui">People</b> &gt; <b class="gd-ui">Renters</b> &gt; <b class="gd-ui">All leads</b>. An alert for a new lead (in the app, on the phone, or by email) opens that lead&#39;s own page.</p><section class="gd-task" id="leads-and-sales-claims-what-is-in-the-list" data-gd-task><h2 class="gd-h2">What is in the list</h2><ul class="gd-ul"><li><b class="gd-ui">Renter leads</b>: the contact form, live chat, the phone number box, discount game claims, offers that expired, booking requests typed and not sent, calls missed from a number with no booking (they arrive by themselves within 15 minutes), and Live visitors who turned Hot and left an email.</li><li><b class="gd-ui">Owner leads</b>: owner program enquiries, owner applications started and not finished, owner form contacts and earnings calculator contacts. They are also under <b class="gd-ui">People</b> &gt; <b class="gd-ui">Owners</b> &gt; <b class="gd-ui">Leads</b>, and each New owner program enquiry task opens its lead.</li><li><b class="gd-ui">Partner leads</b>: fleet suppliers, dealers, rental businesses and insurers.</li></ul><p class="gd-p">Each card shows the name, phone, email, the source in plain words (a live chat lead says Live chat), how old it is, and the start of what they wrote. New and hot leads come first. Open a lead for everything they wrote, the live chat transcript, their calls, every contact logged and the claim history.</p></section><section class="gd-task" id="leads-and-sales-claims-work-a-lead" data-gd-task><h2 class="gd-h2">Work a lead</h2><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">Press <b class="gd-ui">Claim</b> on a card, or <b class="gd-ui">Next lead</b> for the oldest hot lead nobody holds. It is yours for 15 minutes; nobody else can work on it meanwhile.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Press <b class="gd-ui">Call</b>, <b class="gd-ui">Text</b> or <b class="gd-ui">Email</b>. Your phone or mail app opens and the contact is logged on the lead. Each call, text, email or <b class="gd-ui">Note</b> adds another 15 minutes to your claim, up to 60 minutes from when you claimed it.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Press <b class="gd-ui">Outcome</b> and choose Contacted, Call booked, Applied, Won (with the booking number when there is one) or Lost (say why). Won and lost close the lead.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t">Nothing more to do? Press <b class="gd-ui">Mark handled</b>. Done with it for now? Press <b class="gd-ui">Unclaim</b>: it goes back to the pool at once.</div></li></ol></div><p class="gd-p">A claim that runs out returns the lead to the pool for everyone. One person holds at most 25 leads at a time. When a renter lead&#39;s person books and the booking is confirmed, the lead closes as Won by itself, for the Sales person on the booking.</p></section><section class="gd-task" id="leads-and-sales-claims-as-an-admin" data-gd-task><h2 class="gd-h2">As an Admin</h2><ul class="gd-ul"><li><b class="gd-ui">Reassign</b> gives a lead to a person (their claim, and the lead is assigned to them). <b class="gd-ui">Release</b> ends someone&#39;s claim.</li><li><b class="gd-ui">Sales team</b> shows each person&#39;s leads claimed, won, close rate (won out of claimed), contacted, time to first contact and claims that ran out, today, this week or this month, best first.</li><li><b class="gd-ui">Settings</b> &gt; <b class="gd-ui">Sales</b> sets how long a claim holds for renter, owner and partner leads (10 to 15 minutes suggested), the most a claim can be extended to, how many leads one person may hold, and how long a lead counts as hot.</li></ul><aside class="gd-box"><span class="gd-lbl">Good to know</span><div>Filters narrow the list by type, source, status, age, person and your own leads; the search finds a name, phone number, email or words they wrote.</div></aside></section><section class="gd-task" id="leads-and-sales-claims-rebooking-intent-and-leads-release-35" data-gd-task><h2 class="gd-h2">Rebooking, intent and leads (release 35)</h2><ul class="gd-ul"><li>A returning renter&#39;s new request goes straight to the salesperson of their last booking, with the usual claim time.</li><li>Every renter and lead has an intent score (hot, warm or cold) with what they said they want: budget, car class, length, dates, urgency, delivery and coverage, read from calls (with their transcripts), texts, emails, the site chat and their visits.</li><li>Leads are never given out by themselves: onboarded Sales claim them, one every 5 minutes, up to 3 open at once plus one for every 5 won in the last 30 days (at most 10).</li></ul></section><section class="gd-task" id="leads-and-sales-claims-leads-handled-on-a-call-by-customer-service-or-fleet-release" data-gd-task><h2 class="gd-h2">Leads handled on a call by customer service or Fleet (release 37)</h2><p class="gd-p">A lead that customer service or Fleet handle on a call (they answer or place the call, add a note, or create the lead from the call) is held for them for <b class="gd-ui">Customer service and Fleet: a lead they handle on a call is held for</b> minutes in <b class="gd-ui">Settings</b> &gt; <b class="gd-ui">Sales</b> (empty: the Sales claim minutes of its type). Each new handled call adds the time. Sales see <b class="gd-ui">Being handled by</b> and cannot work it; <b class="gd-ui">Next lead</b> skips it. <b class="gd-ui">Release hold</b> on the lead ends it at once; it returns to the salesperson who had a claim on it or brought it, else the open list. Your own reassign also ends it. A booking made from the lead keeps the usual credit; the hold is not a claim, so customer service is never credited. Every step is in the lead&#39;s history (hold, another call handled, hold ended).</p></section>');
select app.guide_release_section('admin', 'settings', 'chapter', 'search-car-pages-landing-pages-and-guides', 'Settings change the public site and the rules of the program at once. Program settings are kept as dated rows, so earlier values stay on record.

## The Settings page

1. Site setup lists what is still missing on the public site, with **Open site settings**.
2. Site settings: contact details, hours, tagline, logo, socials, Google place id and featured cars.
3. Program settings: every timing and policy value.
4. Forms: Blind Spot''s rental agreement for every booking, and the official ServiceOntario PDFs and what goes in each field.
5. Insurers: insurance companies billed for bookings.

![](/guides/img/admin-24-settings-desktop-89b31691.jpg "desktop; size: 1440 900; address: carmacars.ca/admin/settings; pins: 1 32.6 33.0, 2 25.8 40.2, 3 77.4 40.2, 4 25.8 73.2, 5 25.8 84.9")

The other tiles: Site content (headings, FAQs, legal text), Fee defaults, Deposit tiers, Kilometre choices, Vehicle classes, Vehicle class rules, Airports and delivery, Protection Plan prices, Card coverage, Reviews, Quo contacts (everyone with a phone number as a contact in Quo: see Texts and calls), Text alerts, Partners (each partner company''s CRM link: see Partners, company cars and rentals added by hand), Email aliases and reply-to, My profile, Staff and roles, Promo codes and Quick replies.

**My profile**: the greeting name of this login. To do greets it whole ("Good morning, Abbas and Mahad" on a login the owners share) and the assistant uses it; empty, the first name of the account. Press **Change the greeting name**, type it and save.

## Program settings

1. Buffer between trips (90 minutes): the time held before and after every trip, in every availability and conflict check (requests, offers, date changes, extensions, the calendar). The cleaning block after a trip is this time; Turnaround between trips is the same number. A booking already closer than this is not changed: the calendar rings it.
1. Late fee and extensions (Booking requests and offers): the late fee per started hour (17.5% of the daily rate, at least $25; new bookings and offers only), the extension discounts (no longer applied since release 35: an extension costs the booking''s all-in price a day) and **Approve a renter''s extension at once when nothing needs a person** (on). A car''s own switch is in Fleet, the car, **Edit details**: **Renters extend themselves**.
1. RentalCover (the Protection Plan): whether quotes price the plan once the key is set (on), the markup (on, 20%, no fixed amount), how long a quote is reused, the car value limit ($50,000) and whether a car with no value may have the plan (off).
2. Settings come in groups such as Company, Booking requests and offers, Owner debits and statement emails, Deposits, Delivery, Owners and fleet, and Tolls and damage. Open one to see its fields.
3. First reply target for customer service and sales (minutes), under Booking requests and offers: 5 by default. New booking requests, enquiries, changes renters ask for and renter messages are due that many minutes after they come in; the scorecard and the staff screens use it. What renters are told (Reply wording, in Site settings) is separate.
4. Staff commissions and prices typed by hand: the commission outside Sales (10%), the three Sales tiers and their days (10%, 15% from 50 days, 20% from 100 days, the month''s target), the price floor a day (empty: none) and the discount from the rate sheet that flags a price (20%). The owner confirmed these values in October 2026. The remote Sales values follow: the three remote tiers (5%, 10%, 15%), the touches a month (400), the drop under it (one tier) and its floor (2.5%), the peak hours a week (20), the reply target (15 minutes) and the peak hours (noon to 6 pm, Thursday to Sunday).
5. Staff agreement defaults by function, at the bottom: pay (a month, an hour or commission only), the rate, the schedule (full time, part time or flexible), days a week and hours a day for Customer service, Fleet, Finance and Sales, the values every assistant shares, and the field staff wage. Sales is commission only: no rate and a flexible schedule. Press **Save the defaults**.
6. Live visitors and live chat: recording visits, the signal thresholds, follow-up tasks, the chat and its assistant, and how long visits and chats are kept.
7. Discount games: the same values as Settings, Discount games (the prize table and the games are easier to change there).
8. Deposits: the toll and ticket window after the return (7 days: settling sooner suggests a hold-back), the longest hold-back (30 days after the return), how long before a card hold lapses it is collected (36 hours), and collecting what is owed after the deposit by itself (the card on file, then a pay link, then a Finance task). A deposit is never released by itself.
9. Field jobs and handovers: field jobs made from each confirmed booking (on) and who gets them (the least busy field staff member, or nobody so Fleet assigns), how field staff may take a deposit at the check-in besides a card (e-Transfer and cash), and whether they may release a car whose tracker is not reporting, with a reason (on; you get an urgent task). Field pay: the first day of a pay period (every period is two weeks), the default hourly rate (CA$18.00), whether overtime is paid (off), after how many hours in a week (44) and at what share of the rate (150%), vacation pay added to each statement (off; Ontario 4%) and the longest shift (16 hours).
10. Sign-in by phone: codes by text from the CarmaCars number (on), US numbers (off until the Quo number is registered for US texting, A2P 10DLC), codes per number and per connection an hour, and whether a verified phone confirms an account like a confirmed email. Accepting an offer, signing and paying need a confirmed account; an account made by phone gives its email on the pay page before its first payment.
11. Calendar sync, Turo by email, Booking recovery emails and Site check: how often calendar links are read, the Turo inbound address and who may forward to it, the reminder delays and sending hours, and the site check with the address its alerts go to (rent@carmacars.ca), the minutes before an email, the daily limit and the quiet hours.
12. Change a value and press **Save**. It is saved as a new row from today; the rows before stay as they were.

![](/guides/img/admin-25-program-settings-desktop-d16b066c.jpg "desktop; size: 1440 1000; address: carmacars.ca/admin/settings/program; pins: 1 25.8 22.0, 2 27.8 49.0")


## Lead-time pricing

A car booked at short notice costs a little more and one booked well ahead a little less. Open **Settings**, then **Program settings**: Lead-time pricing is at the top.

1. The switch turns it on or off for every car (on by default).
2. The table holds the tiers: when the pickup is that many hours away, the rental charge changes by that percentage. By default: under 24 hours +15%, 24 to 72 hours +10%, 3 to 13 days 0%, 14 days or more −5%. Type the hours and the percentage on each row (a minus for less); **Add a tier** adds one, **Remove** takes one off. Each row shows what it does to a $500 rental.
3. **Also adjust bookings billed to an insurer** is off by default: an insurer pays its own rate, never a short-notice premium.
4. Press **Save lead-time pricing**. New quotes and requests use it; bookings already made keep theirs.

| What it touches | How |
| --- | --- |
| The rental charge | The percentage of the rental charge only, before tax: one line in the price, "Short-notice pricing +10%" or "Booked ahead −5%". Never the fees, the deposit or add-ons |
| When it is worked out | When the quote is made (the car page, the cars list once dates are chosen, the request), from that moment to the pickup on Toronto clocks. "From $X a day" stays at the base rate |
| When it is locked | On the request: the offer, a change of dates and the payment keep the same percentage |
| Other discounts | The non-refundable discount, a promo code and a staff discount are worked out on the rental charge from the rates, as before, and show beside it |
| Owner revenue and commissions | Count the rental charge after it, as they count the discounts |
| Staff | Change it on a booking under **More options** on the review screen; a price typed by hand replaces it. Rentals added by hand, Owner Bookings and placeholders are not adjusted |

> Tip: A car can turn it off or have its own tiers: **Vehicles** > the car > **Rates** > Lead-time pricing for this car.
## Vehicle class rules

Open **Settings**, then **Vehicle class rules**. How a new car''s class is decided from its VIN: the first rule that matches wins.

1. The table lists each rule: its rank, what the car must be (a make, and patterns for the model, the trim and the body), the class it gets, the class once the car is old enough, a note and whether it is on. The lowest rank that matches is used; a car that matches no rule is Standard.
2. Press **Add a rule** or **Change**: a rank, at least one condition, the class, optionally the years old after which an older class applies, and a note (it is shown as the reason for the class). A pattern is not case sensitive: ^911 matches models that start with 911. A rule with no condition, a pattern that does not compile and an older class equal to the class are refused.
3. **Try a car** gives the class the rules decide for a year, make, model, trim and body, and why.
4. **Delete** removes a rule; switch it off instead to keep it. Every add, change and delete is in the audit log, with before and after.

> Tip: A rule changes the cars entered from then on. A car already listed keeps its class until you change it on the car.

## Official ServiceOntario forms

The five official forms are loaded with a mapping to the owner, car, company and lender details. Each is the form exactly as ServiceOntario publishes it: only its empty text boxes are filled; its own text and layout are never changed. A form whose stored PDF is not the publisher''s download (or your upload of it) gives owners the data sheet instead. Its checkboxes, drop-downs and signatures are done by hand at the counter, in ink. Until you check a form, owners get a data sheet with the values.

1. Open **Settings** > **Forms**. Each form shows "Mapping to check" (a draft is ready) or "Official PDF in use". Its notes say what the form is for and which boxes are left blank on purpose.
2. Choose **Preview with**: a sample car (made-up values) or one of the cars. Press **Download a filled preview** and check each value against the form. The preview uses the mapping on screen, saved or not.
3. Change a field if needed: What goes in it (or "Signed here by hand, in ink"), a Format (for example YYYY/MM/DD) and Only when. Write what you changed and press Save the mapping. **Earlier mappings** lists every save, with who and when; **Load** puts one back on screen to preview and save again. Fleet can map the forms too (Owners > Government forms), but only an Admin uploads a form.
4. Press **Checked: use for owners**. Every owner''s form of that kind is filled again, except ones already signed or filed. Owners download it, print it and sign it in ink; record it with **Record an official form signed in ink**. Each form not checked yet is also a line on To do with the same button and Preview it.
5. A new version from ServiceOntario? Press **Upload the official fillable PDF**: the fields of the same name keep their mapping.

> Good to know: SR-LV-006 (registration), SR-LV-012 (two registrants), ON00453 (a company''s RIN), 013-1155 and 013-0169 (the tax-exempt transfer into an owner''s corporation). 013-1155 is sworn before a commissioner, so it is printed and signed in person. ON00453 is an Adobe form: it opens in Adobe Acrobat Reader. Each form''s notes list what to tick or choose at the counter. A car gets only the forms its onboarding method needs: no form for a Transfer of a car owned outright or financed (the sign-back on the permit), 013-1155 and 013-0169 only for a Lease through a new Owner Corporation.

## Blind Spot rental agreement

We rent under Blind Spot Car Rental''s insurance, so every booking has two agreements: CarmaCars'' rental agreement and Blind Spot''s own. Blind Spot''s is filled in from the booking, the renter and the car, and the renter signs both with one signature. Its PDF is stored privately, never on the website.

1. Open **Settings** > **Forms**. The Blind Spot Car Rental agreement card is first. Press **Upload Blind Spot''s PDF** and choose Blind Spot''s blank form (2 pages, A4).
2. Press **Download the filled sample**: a made-up booking on the form. **Sample billed to an insurer** also fills the claim number, the adjuster and the insurance company. Check every box.
3. On the form the old address (top left and twice in box 15) is replaced by the mailing address of Site settings, box 1 by CarmaCars'' HST number (Program settings, Company HST number; blank until it is entered), and box 21 has the representative''s signature instead of Sam''s.
4. Press **Checked: use for bookings**. From then on each booking gets it when its rental agreement is made; a renter whose agreement is already open gets it the next time they open the signing page.
5. Box 21: Ahmad is written in a script hand, as Blind Spot asked. To use a real signature instead, upload a PNG under Authorized company representative; Remove the image goes back to the written name. Full name is for the signature record page.
6. A new version of Blind Spot''s form? Upload it the same way: it waits for **Checked: use for bookings**, and bookings keep the version in use until then.

> Good to know: Each box is filled only when the booking has the value: the renter and their licence, the additional drivers, the car (plate, make and model, the fleet number as vehicle number), the pickup as time and date out, the due-back date and time, the kilometres allowed, the rate rows (days, weeks or months @ the rate = the amount; a rental counted by the day, such as 31 days at the monthly rate, shows its daily rate rounded to the cent, and box 14 says how the charge was made), the underage fee, the Protection Plan as CDW, winter tires, the subtotal, HST (13% of the subtotal), total and deposit, the deposit received and the day it was taken (before pickup, the amount due at pickup), and for a booking billed to an insurer the insurer, claim number and adjuster. Other charges, such as delivery, are listed in box 14. The boxes filled at check-in and check-out stay blank until then. The fuel gauges are covered and the level of the check-in report (fuel out) and the check-out report (fuel in) is written in words, blank with no reading.

The renter''s signature goes in boxes 16, 17 and 20 of the signed copy, with the day they signed beside box 20 and a signature record page. Each later version (as picked up, as returned, corrected) carries the same signature and day. Both agreements are in the booking''s Drivers and documents tab, in the renter''s Documents, and the signed Blind Spot agreement is attached to the "Your signed rental agreement" email. Admin > Today lists the HST number, the upload and the check until they are done.

## Agreements to sign: investors and staff

Investment agreements and staff agreements are made from the person''s record and signed in their own portal, with the e-signature (never on paper).

1. Investor: open **People** > **Investors** and the investor. Under Investment agreement, press **Send the agreement to sign**. Check the values it is filled with (amount, yearly percentage, dates, exemption) and press **Send to sign**.
2. Once the investor signs, the agreement shows **Awaiting countersignature** on the investor''s page and on To do. It is not countersigned automatically: check it and press **Countersign**. CarmaCars is bound once it has countersigned and the funds clear.
3. Staff: open **People** > **Team**. Under Staff agreements, press **Send the agreement to sign** beside the person. Pay, schedule, hours and the other values start from the staff profile and the defaults of their function in Program settings; change any before sending. For Sales the Pay is Commission only: the agreement then has no rate, schedule or hours, and pays the commission of section 3.4.
4. A field staff member''s agreement prints the home address they entered themselves. Staff enter their home address at their first sign-in, before they sign, or in their profile.
5. They get a notice, check the key values and sign in their portal in a few taps (their name is the signature, or they draw it). The signed copy is filed with their documents.
6. Your own PDF instead? **Send a PDF to sign** still works.
7. Sent by mistake? Press **Withdraw** and give the reason.

## The user guides

**Settings** > **Guides**. The guide of each portal, as people read it under Guide.

1. Each guide shows its version, when it was published and whether there are unpublished changes.
2. Open a guide and press a section. Change its text and press **Show the preview** to see it as people will. Press **Save the draft**; each save is kept in the section''s history.
3. Move a section with the arrows, hide it, or press **Add a chapter**. Upload a screenshot under Screenshots and paste the line it gives you.
4. Press **Publish version** (the next number). The portals show the new version at once.
5. The stored PDF is printed again by the guides-pdf workflow. Until then the guide says the web guide has newer edits.

## The guides keep up by themselves

After every update of the site that changes the portals, the guides are checked without anyone asking.

1. Every screenshot is taken again on the new version of the site. One whose screen changed replaces the old one in the guide.
2. The text of each section whose screen changed, or that names a button the portals no longer show, is rewritten from the portal''s own labels and menu, checked, and published. The PDFs of those guides are printed again.
3. Such a section says **Changed automatically on** and the date, in the list of guides and in the guide''s editor. Not right? Open the section and press **Revert**: the text it replaced comes back, published at once.
4. This includes sections you edited: the newest automatic text is published, and every earlier version stays in the section''s history. There is nothing to review.
5. A rewrite that does not pass the checks is asked again, more strictly. If it still does not pass, the screenshots and button names are updated, the rest of the text stays as it was, and the next run tries again.

> Tip: The card "The guides keep up by themselves" at the top of Guides lists the last runs: when, how many screenshots were replaced, how many sections were rewritten, and how many PDFs were printed.

## Insurers and the other lists

1. Open Insurers. Each insurer on file opens to edit its billing contact, email, phone, address and notes. Its rates by car class are in **Money** > **Insurers**.
2. To add one, fill in the Add form (Name, Billing contact, Billing email and the rest) and press **Add**.
3. Deposit tiers, Kilometre choices, Vehicle classes, Airports, Promo codes and Quick replies work the same way.

## Promo codes: end dates and reminders

**Settings**, **Promo codes**.

- Every code made for a person has an end date: a game prize 7 days, a come-back offer 30, a Live visitors code 3 and a code made for one renter 30 unless you set another. The first card of Promo codes holds the 30 days and the two reminders.
- A code for everyone may have no end date: empty Valid until. The Add form starts with an end date 30 days ahead.
- A code that ended is refused wherever it is typed (the request form, an offer, Add a rental, a booking edit) with "This code has expired".
- A person who has not used a code is reminded 3 days before its last day and the day before, by email and by text as they chose, never once they used it, unsubscribed or the code ended, and never twice. A game code reminder always goes; a reminder of any other code needs their consent to offers.
- The list shows each code''s end date and the reminders sent. The card Codes sent to people lists game prizes, come-back offers and Live visitors codes the same way.

## Card coverage: which credit cards include rental car coverage

**Settings** > **Card coverage** is the list renters see at `carmacars.ca/credit-card-rental-coverage` and staff see under Card coverage in their portal. It starts filled in with 48 Canadian and US cards, each checked on October 23, 2026.

1. The table shows each card: who pays first (Primary, Secondary, or not stated), the car value limit (MSRP), the longest rental, whether the numbers were read in the issuer''s own document, and when it was last checked.
2. Open a card under Change a card, open its official guide, correct what changed and press **Save**. Changing the facts without a date marks the card checked today; type a Last checked date to record another day.
3. A card whose numbers come from a published summary has Read in the issuer''s own document unticked and the summary''s link under Where the numbers came from. The page shows it as Unverified. Tick it once you have read the issuer''s guide.
4. Add a card with the Add form; untick Shown to hide one. Changes reach the public page at once.

> Tip: A card not checked for 6 months shows on Today until it is checked again. The page tells renters to confirm with their card issuer and says CarmaCars decides no claims: keep the list to facts from the issuer''s guide.

## Reviews: review requests and Google

**Settings** > **Reviews**: when review requests go, the Google review link and the Google Business Profile connection. Review requests are on from the start.

1. When review requests go: the check-out (on or off, the shortest rental, hours after the pickup), the request (minutes after the check-out), the reminder (hours) and the final follow-up (days), the sending hours (9 am to 9 pm), and the hold while charges are open.
2. The Google review link: the Google place id (Site settings) makes it, or paste the Business Profile''s own review link.
3. Google Business Profile: press **Connect Google** and sign in with rent@carmacars.ca, then allow access. Reviews are read every 6 hours and matched to renters by name within 30 days after their return.
4. A clear match stops that renter''s reminders at once. A possible match waits in Reviews: press **Confirm**, **Not this renter** or **Match to a booking**.

> Tip: Until Google approves the Business Profile API for the project, the status says so and nothing else changes: renters still get the review link, and "I already left a review", Mark reviewed and on-site reviews still stop the messages.

### Pair the card reader
**Settings** > **Card reader**. On the Stripe S700, swipe from the left edge, open **Settings**, then **Generate pairing code**. Type the three words in **Pairing code**, name the reader (Front desk) and press **Pair reader**. The first time, a Stripe Terminal location is made from the mailing address in Site settings: write it as street, city, province and postal code. **Remove** takes a reader off the list. Card statements read 18122211 Canada Inc., the Stripe account''s statement descriptor.

### Rewards
**Settings** > **Rewards**. CarmaCars Rewards is on: 1 point per dollar of the rental charge after discounts (never fees, add-ons, coverage, tax or the deposit), 100 points = $1, redeemed from 500 points as a code of the renter''s own, valid 90 days. Points end 12 months after the last rental or redemption, with a reminder email 30 days before.

1. **Ways to earn**: each on or off with its points. Referral (500 to the referrer, 250 to the friend, at the friend''s first completed rental), a follow on Instagram, TikTok or Facebook (50 each, once, granted on the click from the Rewards page, since a follow cannot be checked; a platform shows only with its page in Site settings), a review on carmacars.ca (100, any rating; the review shows "Received reward points"), a Google review (100 a rental, any rating, on the renter''s word: they press I posted my review and give the name on it; hidden until the Google review page is set here), a damage-free rental (200: no damage, claim, cleaning or smoking fee, back on time), the birthday (100) and the first rental (100).
2. **Tiers**: Member, Silver from 10 rental days in 12 months (5% off) and Gold from 30 (10% off), with a perk staff honour on request. The discount is a promo code of the renter''s own.
3. Points, tier discounts and codes come off the rental charge only and reduce Owner Revenue like any promo code.
4. **Google reviews claimed** lists every claim; **Reverse** takes the points back with a reason. **A renter''s points**: find the renter, then **Add or take off points** with a reason, or reverse any entry (for example, referral fraud).

### Setup checklist
**Settings** shows what still needs a key from one of CarmaCars'' own accounts. **Add to Apple Wallet** stays hidden until the Apple Pass Type ID certificate is added (WALLET_PASS_CERT, WALLET_PASS_KEY, WALLET_WWDR_CERT, WALLET_PASS_TYPE_ID and WALLET_TEAM_ID in the Worker''s secrets); then it shows on every confirmed booking.


Program: **Call and Text buttons go through Quo** (on) makes every Call and Text button use the CarmaCars number in Quo (chapter Texts and calls). Off, they open the device''s own phone and messages apps.

## Stuck? help

**Settings** > **Program settings** > **Stuck? help**: turn it on or off, the minutes on a page without a successful action (3), and the errors (3) before the box offers the guide and the Academy lesson. **Where people get stuck**, on the same page, lists the pages it showed on most in the last 30 days, with how often the guide and the lesson were opened.

### API access (Claude and scripts)

Settings > **API access** connects Claude so you (or Mahad) can run CarmaCars from a Claude chat: bookings, offers, payments, refunds, returns, cars, rates, listings, owners, invoices, staff and hiring ("hire Ana as customer service"). **Connect from Claude**: in Claude, Settings > Connectors > Add custom connector, paste https://carmacars.ca/api/mcp, then sign in to CarmaCars and press **Allow**. Every change is two steps: Claude first shows what will change (nothing is changed yet), and does it only when you agree. Keys and connections made with every scope got the Admin scopes in release 33; a key with fewer scopes keeps them. For Claude Code or a script, **Make a key**: copy it at once, it is shown only once. Each key or connection acts as its Admin, with the scopes chosen; **Revoke** stops it at once. The **Call log** lists every call (the previews too) with the values before and after. The database checks each action exactly as the Admin screens do.

### The logo

The site, every portal, every email and the documents show the brand logo. To use another, upload it under Settings > **Site settings**, the Logo card (PNG or JPEG for emails and documents).

## Deposits stay as holds (release 28)

Every deposit by card is a hold (an authorization) that stays with Stripe: it is never captured by itself, so nothing is paid out and nothing has to be refunded. Capture only what is owed, and release the rest from the booking. The booking''s Security deposit panel shows Hold expires with the date Stripe gives. When a hold nears its expiry while the car is out or tickets can still come in, Finance gets a To do with **Re-authorize the hold**: a new hold on the saved card, then the old one is released.

**Program settings**: **Extended deposit holds (up to about 30 days)** stays off until Stripe confirms IC+ pricing and extended authorization; when on, the hold on the saved card asks for a longer authorization and falls back to a standard one by itself. It never touches the rental payment. Capturing a deposit hold by itself is off. The heavy cleaning fee (an excessively dirty or smoked-in car) is $300 in **Fees**, editable as every fee.

## Updated terms to accept

**Settings** > **Updated terms**. When the terms of use, the privacy policy or an agreement template changes, publish the new version here; with **Requires acceptance** on, each person it binds accepts it before using their portal.

1. Press **Publish a version**. Choose the Document (the terms of use and the privacy policy bind everyone with a portal; each agreement binds the people who sign it: renters, owners, fleet suppliers, partners, investors, or staff and field).
2. Give the Version (for example the date it takes effect) and **What changed**: people read this summary first.
3. Paste **The new text**. For the terms of use or the privacy policy, leave it empty to use the site''s current text; a text you paste also replaces the site''s page.
4. Leave **Requires acceptance** on and press **Publish a version**.
5. Everyone it binds whose account was opened before sees **We''ve updated our terms** full screen on their next visit, with your summary and the text, and presses Accept. The acceptance is recorded with the time, the IP address, the device and the version.
6. **Accepted** on each version opens who accepted it and when.

> Good to know: It is a click-through acceptance of the new version: no signed agreement is voided and no renter signs the agreement of a past booking again. An Admin account is never asked.

> Good to know: Every agreement is signed with the e-signature only (the identity steps, the IP address, the audit trail): a signature on paper is never recorded. Only an official ServiceOntario form, which the government requires signed in ink, is recorded from its scan.

### Card processing fee for a debit deposit
Program settings: **Card processing fee for a debit deposit: percent (hundredths: 290 is 2.9%)** and **Card processing fee for a debit deposit: fixed part (cents)** (30 is $0.30). When a deposit is charged instead of held on a debit or prepaid card, the renter pays this fee on it, as a separate non-refundable amount shown before they pay, on the receipt and on the Money tab. Set both to 0 to charge no fee.

## My profile and name changes (release 34)
Settings > **My profile** has your display name, **Request a name change** for your legal name, your phone number and **Change my password**. When someone else asks to change the legal name on their agreements, it comes to To do with Approve and Decline, and shows on their page (owner, investor or renter). Approving changes the name on their account and record; agreements already signed keep the name they were signed with.

## AI auto-replies (release 36)

**Settings** > **Program settings**, the AI auto-replies group, answers common questions by itself, only from the FAQ (**Site content**), within Workers AI''s free daily allowance. Each channel has its switch, on by default: texts to the CarmaCars number, emails to the inboxes listed (help@in.carmacars.ca), the website live chat, WhatsApp, Facebook Page messages and Instagram messages.

1. A question the FAQ answers gets the answer at once. A text asked between 1 am and 5 am is answered at 5 am (the quiet hours are settings).
2. When the FAQ does not answer it, or the model is not sure enough (70%), nothing is sent: a text stays in Messages for staff, and an email or a Meta message becomes a To do for customer service, **Answer** and the question.
3. Each person gets at most 5 automatic answers a day, never while a staff member texted them in the last 2 hours, and none once the day''s free AI allowance is used.
4. The card **AI auto-replies: the last answers** shows today''s answers and the last questions, with what was sent or why not.

Messenger, Instagram and WhatsApp need the Meta app''s webhook set to https://carmacars.ca/api/webhooks/meta with the verify token shown in the settings, and the Worker secrets META_APP_SECRET (and WHATSAPP_TOKEN with the WhatsApp number id). TikTok has no inbound message path for businesses, so it is not answered.

## Address suggestions (release 36)

The address fields suggest Canadian addresses from the site''s own address database (Statistics Canada''s Open Database of Addresses, loaded by the addresses workflow, Ontario first). Google is asked only for what the database does not have, and only when its key is set.

## Card coverage: the facts the booking check uses (release 35)

Each card also has: **Network** (Visa, Mastercard, American Express), **Includes rental car damage coverage (CDW)** (Yes, No or Unknown), **Vehicle types not covered** (comma separated: exotic, luxury, truck, van, off_road, antique, motorcycle, limousine, rv), **Must decline the rental company''s CDW** and **Must pay the full rental on the card**. A renter on card coverage picks their card from this list; the site checks it against the car''s value (the Black Book value or the estimate on the car), the car''s type and the length of the rental, and refuses a card that does not cover it. Unknown sends the renter to staff review. Exotic makes are listed in **Program** > **Coverage checks**.

## Fuel prices and delivery (release 35)

- **Program** > **Fuel and charging at the return**: the local pump prices of regular, premium and diesel (a litre), the multiplier (1.25), the refuelling fee ($20), the price a kWh for electric cars ($0.40), and the tank and battery sizes for a car without its own. Update the pump prices every week: **Today** reminds you after 7 days.
- **Airports and delivery** > **Delivery rate and origin**: the base fee each way ($75), the km it includes from the company''s location (15), the rate per km after them ($2), and the straight line to road distance factor (1.3) used when the maps service gives no road distance. A car whose rate card has its own delivery or pickup fee keeps it; every other car follows the base.

## Automatic answers and email budgets (release 36)

- Automatic answers: each channel (text, email, chat, social messages) switches on or off, with the quiet hours, the daily limit per person and how sure the answer must be. The last answers and the questions left for a person show in settings and under renter messages; a question it cannot answer becomes a To do. They stay inside the free daily AI allowance.
- Email budgets: Settings, Usage shows the real daily email capacity of all our sending services together (Cloudflare included), and when a service is not sending, why. Receipts, signed copies and staff messages always go.
- First photo: each listing chooses its first photo, the plain car, a car-show photo with a model, or a flyer with the live price; the flyer is made again when the price changes.
- Rewards: points for a photo with a review and for every rental after the first; every way to earn is on the renter''s Rewards page.', 'Settings', 'Site, program settings, official forms mapping, insurers and the other lists.',
  'Settings change the public site and the rules of the program at once. Program settings are kept as dated rows, so earlier values stay on record.

## The Settings page

1. Site setup lists what is still missing on the public site, with **Open site settings**.
2. Site settings: contact details, hours, tagline, logo, socials, Google place id and featured cars.
3. Program settings: every timing and policy value.
4. Forms: Blind Spot''s rental agreement for every booking, and the official ServiceOntario PDFs and what goes in each field.
5. Insurers: insurance companies billed for bookings.

![](/guides/img/admin-24-settings-desktop-89b31691.jpg "desktop; size: 1440 900; address: carmacars.ca/admin/settings; pins: 1 32.6 33.0, 2 25.8 40.2, 3 77.4 40.2, 4 25.8 73.2, 5 25.8 84.9")

The other tiles: Site content (headings, FAQs, legal text), Fee defaults, Deposit tiers, Kilometre choices, Vehicle classes, Vehicle class rules, Airports and delivery, Protection Plan prices, Card coverage, Reviews, Quo contacts (everyone with a phone number as a contact in Quo: see Texts and calls), Text alerts, Partners (each partner company''s CRM link: see Partners, company cars and rentals added by hand), Email aliases and reply-to, My profile, Staff and roles, Promo codes and Quick replies.

**My profile**: the greeting name of this login. To do greets it whole ("Good morning, Abbas and Mahad" on a login the owners share) and the assistant uses it; empty, the first name of the account. Press **Change the greeting name**, type it and save.

## Program settings

1. Buffer between trips (90 minutes): the time held before and after every trip, in every availability and conflict check (requests, offers, date changes, extensions, the calendar). The cleaning block after a trip is this time; Turnaround between trips is the same number. A booking already closer than this is not changed: the calendar rings it.
1. Late fee and extensions (Booking requests and offers): the late fee per started hour (17.5% of the daily rate, at least $25; new bookings and offers only), the extension discounts (no longer applied since release 35: an extension costs the booking''s all-in price a day) and **Approve a renter''s extension at once when nothing needs a person** (on). A car''s own switch is in Fleet, the car, **Edit details**: **Renters extend themselves**.
1. RentalCover (the Protection Plan): whether quotes price the plan once the key is set (on), the markup (on, 20%, no fixed amount), how long a quote is reused, the car value limit ($50,000) and whether a car with no value may have the plan (off).
2. Settings come in groups such as Company, Booking requests and offers, Owner debits and statement emails, Deposits, Delivery, Owners and fleet, and Tolls and damage. Open one to see its fields.
3. First reply target for customer service and sales (minutes), under Booking requests and offers: 5 by default. New booking requests, enquiries, changes renters ask for and renter messages are due that many minutes after they come in; the scorecard and the staff screens use it. What renters are told (Reply wording, in Site settings) is separate.
4. Staff commissions and prices typed by hand: the commission outside Sales (10%, field staff only: customer service, Fleet and Finance earn none), the three Sales tiers and their days (10%, 15% from 50 days, 20% from 100 days, the month''s target), the price floor a day (empty: none) and the discount from the rate sheet that flags a price (20%). The owner confirmed these values in October 2026. The remote Sales values follow: the three remote tiers (5%, 10%, 15%), the touches a month (400), the drop under it (one tier) and its floor (2.5%), the peak hours a week (20), the reply target (15 minutes) and the peak hours (noon to 6 pm, Thursday to Sunday).
5. Staff agreement defaults by function, at the bottom: pay (a month, an hour or commission only), the rate, the schedule (full time, part time or flexible), days a week and hours a day for Customer service, Fleet, Finance and Sales, the values every assistant shares, and the field staff wage. Sales is commission only: no rate and a flexible schedule. Press **Save the defaults**.
6. Live visitors and live chat: recording visits, the signal thresholds, follow-up tasks, the chat and its assistant, and how long visits and chats are kept.
7. Discount games: the same values as Settings, Discount games (the prize table and the games are easier to change there).
8. Deposits: the toll and ticket window after the return (7 days: settling sooner suggests a hold-back), the longest hold-back (30 days after the return), how long before a card hold lapses it is collected (36 hours), and collecting what is owed after the deposit by itself (the card on file, then a pay link, then a Finance task). A deposit is never released by itself.
9. Field jobs and handovers: field jobs made from each confirmed booking (on) and who gets them (the least busy field staff member, or nobody so Fleet assigns), how field staff may take a deposit at the check-in besides a card (e-Transfer and cash), and whether they may release a car whose tracker is not reporting, with a reason (on; you get an urgent task). Field pay: the first day of a pay period (every period is two weeks), the default hourly rate (CA$18.00), whether overtime is paid (off), after how many hours in a week (44) and at what share of the rate (150%), vacation pay added to each statement (off; Ontario 4%) and the longest shift (16 hours).
10. Sign-in by phone: codes by text from the CarmaCars number (on), US numbers (off until the Quo number is registered for US texting, A2P 10DLC), codes per number and per connection an hour, and whether a verified phone confirms an account like a confirmed email. Accepting an offer, signing and paying need a confirmed account; an account made by phone gives its email on the pay page before its first payment.
11. Calendar sync, Turo by email, Booking recovery emails and Site check: how often calendar links are read, the Turo inbound address and who may forward to it, the reminder delays and sending hours, and the site check with the address its alerts go to (rent@carmacars.ca), the minutes before an email, the daily limit and the quiet hours.
12. Change a value and press **Save**. It is saved as a new row from today; the rows before stay as they were.

![](/guides/img/admin-25-program-settings-desktop-d16b066c.jpg "desktop; size: 1440 1000; address: carmacars.ca/admin/settings/program; pins: 1 25.8 22.0, 2 27.8 49.0")


## Lead-time pricing

A car booked at short notice costs a little more and one booked well ahead a little less. Open **Settings**, then **Program settings**: Lead-time pricing is at the top.

1. The switch turns it on or off for every car (on by default).
2. The table holds the tiers: when the pickup is that many hours away, the rental charge changes by that percentage. By default: under 24 hours +15%, 24 to 72 hours +10%, 3 to 13 days 0%, 14 days or more −5%. Type the hours and the percentage on each row (a minus for less); **Add a tier** adds one, **Remove** takes one off. Each row shows what it does to a $500 rental.
3. **Also adjust bookings billed to an insurer** is off by default: an insurer pays its own rate, never a short-notice premium.
4. Press **Save lead-time pricing**. New quotes and requests use it; bookings already made keep theirs.

| What it touches | How |
| --- | --- |
| The rental charge | The percentage of the rental charge only, before tax: one line in the price, "Short-notice pricing +10%" or "Booked ahead −5%". Never the fees, the deposit or add-ons |
| When it is worked out | When the quote is made (the car page, the cars list once dates are chosen, the request), from that moment to the pickup on Toronto clocks. "From $X a day" stays at the base rate |
| When it is locked | On the request: the offer, a change of dates and the payment keep the same percentage |
| Other discounts | The non-refundable discount, a promo code and a staff discount are worked out on the rental charge from the rates, as before, and show beside it |
| Owner revenue and commissions | Count the rental charge after it, as they count the discounts |
| Staff | Change it on a booking under **More options** on the review screen; a price typed by hand replaces it. Rentals added by hand, Owner Bookings and placeholders are not adjusted |

> Tip: A car can turn it off or have its own tiers: **Vehicles** > the car > **Rates** > Lead-time pricing for this car.
## Vehicle class rules

Open **Settings**, then **Vehicle class rules**. How a new car''s class is decided from its VIN: the first rule that matches wins.

1. The table lists each rule: its rank, what the car must be (a make, and patterns for the model, the trim and the body), the class it gets, the class once the car is old enough, a note and whether it is on. The lowest rank that matches is used; a car that matches no rule is Standard.
2. Press **Add a rule** or **Change**: a rank, at least one condition, the class, optionally the years old after which an older class applies, and a note (it is shown as the reason for the class). A pattern is not case sensitive: ^911 matches models that start with 911. A rule with no condition, a pattern that does not compile and an older class equal to the class are refused.
3. **Try a car** gives the class the rules decide for a year, make, model, trim and body, and why.
4. **Delete** removes a rule; switch it off instead to keep it. Every add, change and delete is in the audit log, with before and after.

> Tip: A rule changes the cars entered from then on. A car already listed keeps its class until you change it on the car.

## Official ServiceOntario forms

The five official forms are loaded with a mapping to the owner, car, company and lender details. Each is the form exactly as ServiceOntario publishes it: only its empty text boxes are filled; its own text and layout are never changed. A form whose stored PDF is not the publisher''s download (or your upload of it) gives owners the data sheet instead. Its checkboxes, drop-downs and signatures are done by hand at the counter, in ink. Until you check a form, owners get a data sheet with the values.

1. Open **Settings** > **Forms**. Each form shows "Mapping to check" (a draft is ready) or "Official PDF in use". Its notes say what the form is for and which boxes are left blank on purpose.
2. Choose **Preview with**: a sample car (made-up values) or one of the cars. Press **Download a filled preview** and check each value against the form. The preview uses the mapping on screen, saved or not.
3. Change a field if needed: What goes in it (or "Signed here by hand, in ink"), a Format (for example YYYY/MM/DD) and Only when. Write what you changed and press Save the mapping. **Earlier mappings** lists every save, with who and when; **Load** puts one back on screen to preview and save again. Fleet can map the forms too (Owners > Government forms), but only an Admin uploads a form.
4. Press **Checked: use for owners**. Every owner''s form of that kind is filled again, except ones already signed or filed. Owners download it, print it and sign it in ink; record it with **Record an official form signed in ink**. Each form not checked yet is also a line on To do with the same button and Preview it.
5. A new version from ServiceOntario? Press **Upload the official fillable PDF**: the fields of the same name keep their mapping.

> Good to know: SR-LV-006 (registration), SR-LV-012 (two registrants), ON00453 (a company''s RIN), 013-1155 and 013-0169 (the tax-exempt transfer into an owner''s corporation). 013-1155 is sworn before a commissioner, so it is printed and signed in person. ON00453 is an Adobe form: it opens in Adobe Acrobat Reader. Each form''s notes list what to tick or choose at the counter. A car gets only the forms its onboarding method needs: no form for a Transfer of a car owned outright or financed (the sign-back on the permit), 013-1155 and 013-0169 only for a Lease through a new Owner Corporation.

## Blind Spot rental agreement

We rent under Blind Spot Car Rental''s insurance, so every booking has two agreements: CarmaCars'' rental agreement and Blind Spot''s own. Blind Spot''s is filled in from the booking, the renter and the car, and the renter signs both with one signature. Its PDF is stored privately, never on the website.

1. Open **Settings** > **Forms**. The Blind Spot Car Rental agreement card is first. Press **Upload Blind Spot''s PDF** and choose Blind Spot''s blank form (2 pages, A4).
2. Press **Download the filled sample**: a made-up booking on the form. **Sample billed to an insurer** also fills the claim number, the adjuster and the insurance company. Check every box.
3. On the form the old address (top left and twice in box 15) is replaced by the mailing address of Site settings, box 1 by CarmaCars'' HST number (Program settings, Company HST number; blank until it is entered), and box 21 has the representative''s signature instead of Sam''s.
4. Press **Checked: use for bookings**. From then on each booking gets it when its rental agreement is made; a renter whose agreement is already open gets it the next time they open the signing page.
5. Box 21: Ahmad is written in a script hand, as Blind Spot asked. To use a real signature instead, upload a PNG under Authorized company representative; Remove the image goes back to the written name. Full name is for the signature record page.
6. A new version of Blind Spot''s form? Upload it the same way: it waits for **Checked: use for bookings**, and bookings keep the version in use until then.

> Good to know: Each box is filled only when the booking has the value: the renter and their licence, the additional drivers, the car (plate, make and model, the fleet number as vehicle number), the pickup as time and date out, the due-back date and time, the kilometres allowed, the rate rows (days, weeks or months @ the rate = the amount; a rental counted by the day, such as 31 days at the monthly rate, shows its daily rate rounded to the cent, and box 14 says how the charge was made), the underage fee, the Protection Plan as CDW, winter tires, the subtotal, HST (13% of the subtotal), total and deposit, the deposit received and the day it was taken (before pickup, the amount due at pickup), and for a booking billed to an insurer the insurer, claim number and adjuster. Other charges, such as delivery, are listed in box 14. The boxes filled at check-in and check-out stay blank until then. The fuel gauges are covered and the level of the check-in report (fuel out) and the check-out report (fuel in) is written in words, blank with no reading.

The renter''s signature goes in boxes 16, 17 and 20 of the signed copy, with the day they signed beside box 20 and a signature record page. Each later version (as picked up, as returned, corrected) carries the same signature and day. Both agreements are in the booking''s Drivers and documents tab, in the renter''s Documents, and the signed Blind Spot agreement is attached to the "Your signed rental agreement" email. Admin > Today lists the HST number, the upload and the check until they are done.

## Agreements to sign: investors and staff

Investment agreements and staff agreements are made from the person''s record and signed in their own portal, with the e-signature (never on paper).

1. Investor: open **People** > **Investors** and the investor. Under Investment agreement, press **Send the agreement to sign**. Check the values it is filled with (amount, yearly percentage, dates, exemption) and press **Send to sign**.
2. Once the investor signs, the agreement shows **Awaiting countersignature** on the investor''s page and on To do. It is not countersigned automatically: check it and press **Countersign**. CarmaCars is bound once it has countersigned and the funds clear.
3. Staff: open **People** > **Team**. Under Staff agreements, press **Send the agreement to sign** beside the person. Pay, schedule, hours and the other values start from the staff profile and the defaults of their function in Program settings; change any before sending. For Sales the Pay is Commission only: the agreement then has no rate, schedule or hours, and pays the commission of section 3.4.
4. A field staff member''s agreement prints the home address they entered themselves. Staff enter their home address at their first sign-in, before they sign, or in their profile.
5. They get a notice, check the key values and sign in their portal in a few taps (their name is the signature, or they draw it). The signed copy is filed with their documents.
6. Your own PDF instead? **Send a PDF to sign** still works.
7. Sent by mistake? Press **Withdraw** and give the reason.

## The user guides

**Settings** > **Guides**. The guide of each portal, as people read it under Guide.

1. Each guide shows its version, when it was published and whether there are unpublished changes.
2. Open a guide and press a section. Change its text and press **Show the preview** to see it as people will. Press **Save the draft**; each save is kept in the section''s history.
3. Move a section with the arrows, hide it, or press **Add a chapter**. Upload a screenshot under Screenshots and paste the line it gives you.
4. Press **Publish version** (the next number). The portals show the new version at once.
5. The stored PDF is printed again by the guides-pdf workflow. Until then the guide says the web guide has newer edits.

## The guides keep up by themselves

After every update of the site that changes the portals, the guides are checked without anyone asking.

1. Every screenshot is taken again on the new version of the site. One whose screen changed replaces the old one in the guide.
2. The text of each section whose screen changed, or that names a button the portals no longer show, is rewritten from the portal''s own labels and menu, checked, and published. The PDFs of those guides are printed again.
3. Such a section says **Changed automatically on** and the date, in the list of guides and in the guide''s editor. Not right? Open the section and press **Revert**: the text it replaced comes back, published at once.
4. This includes sections you edited: the newest automatic text is published, and every earlier version stays in the section''s history. There is nothing to review.
5. A rewrite that does not pass the checks is asked again, more strictly. If it still does not pass, the screenshots and button names are updated, the rest of the text stays as it was, and the next run tries again.

> Tip: The card "The guides keep up by themselves" at the top of Guides lists the last runs: when, how many screenshots were replaced, how many sections were rewritten, and how many PDFs were printed.

## Insurers and the other lists

1. Open Insurers. Each insurer on file opens to edit its billing contact, email, phone, address and notes. Its rates by car class are in **Money** > **Insurers**.
2. To add one, fill in the Add form (Name, Billing contact, Billing email and the rest) and press **Add**.
3. Deposit tiers, Kilometre choices, Vehicle classes, Airports, Promo codes and Quick replies work the same way.

## Promo codes: end dates and reminders

**Settings**, **Promo codes**.

- Every code made for a person has an end date: a game prize 7 days, a come-back offer 30, a Live visitors code 3 and a code made for one renter 30 unless you set another. The first card of Promo codes holds the 30 days and the two reminders.
- A code for everyone may have no end date: empty Valid until. The Add form starts with an end date 30 days ahead.
- A code that ended is refused wherever it is typed (the request form, an offer, Add a rental, a booking edit) with "This code has expired".
- A person who has not used a code is reminded 3 days before its last day and the day before, by email and by text as they chose, never once they used it, unsubscribed or the code ended, and never twice. A game code reminder always goes; a reminder of any other code needs their consent to offers.
- The list shows each code''s end date and the reminders sent. The card Codes sent to people lists game prizes, come-back offers and Live visitors codes the same way.

## Card coverage: which credit cards include rental car coverage

**Settings** > **Card coverage** is the list renters see at `carmacars.ca/credit-card-rental-coverage` and staff see under Card coverage in their portal. It starts filled in with 48 Canadian and US cards, each checked on October 23, 2026.

1. The table shows each card: who pays first (Primary, Secondary, or not stated), the car value limit (MSRP), the longest rental, whether the numbers were read in the issuer''s own document, and when it was last checked.
2. Open a card under Change a card, open its official guide, correct what changed and press **Save**. Changing the facts without a date marks the card checked today; type a Last checked date to record another day.
3. A card whose numbers come from a published summary has Read in the issuer''s own document unticked and the summary''s link under Where the numbers came from. The page shows it as Unverified. Tick it once you have read the issuer''s guide.
4. Add a card with the Add form; untick Shown to hide one. Changes reach the public page at once.

> Tip: A card not checked for 6 months shows on Today until it is checked again. The page tells renters to confirm with their card issuer and says CarmaCars decides no claims: keep the list to facts from the issuer''s guide.

## Reviews: review requests and Google

**Settings** > **Reviews**: when review requests go, the Google review link and the Google Business Profile connection. Review requests are on from the start.

1. When review requests go: the check-out (on or off, the shortest rental, hours after the pickup), the request (minutes after the check-out), the reminder (hours) and the final follow-up (days), the sending hours (9 am to 9 pm), and the hold while charges are open.
2. The Google review link: the Google place id (Site settings) makes it, or paste the Business Profile''s own review link.
3. Google Business Profile: press **Connect Google** and sign in with rent@carmacars.ca, then allow access. Reviews are read every 6 hours and matched to renters by name within 30 days after their return.
4. A clear match stops that renter''s reminders at once. A possible match waits in Reviews: press **Confirm**, **Not this renter** or **Match to a booking**.

> Tip: Until Google approves the Business Profile API for the project, the status says so and nothing else changes: renters still get the review link, and "I already left a review", Mark reviewed and on-site reviews still stop the messages.

### Pair the card reader
**Settings** > **Card reader**. On the Stripe S700, swipe from the left edge, open **Settings**, then **Generate pairing code**. Type the three words in **Pairing code**, name the reader (Front desk) and press **Pair reader**. The first time, a Stripe Terminal location is made from the mailing address in Site settings: write it as street, city, province and postal code. **Remove** takes a reader off the list. Card statements read 18122211 Canada Inc., the Stripe account''s statement descriptor.

### Rewards
**Settings** > **Rewards**. CarmaCars Rewards is on: 1 point per dollar of the rental charge after discounts (never fees, add-ons, coverage, tax or the deposit), 100 points = $1, redeemed from 500 points as a code of the renter''s own, valid 90 days. Points end 12 months after the last rental or redemption, with a reminder email 30 days before.

1. **Ways to earn**: each on or off with its points. Referral (500 to the referrer, 250 to the friend, at the friend''s first completed rental), a follow on Instagram, TikTok or Facebook (50 each, once, granted on the click from the Rewards page, since a follow cannot be checked; a platform shows only with its page in Site settings), a review on carmacars.ca (100, any rating; the review shows "Received reward points"), a Google review (100 a rental, any rating, on the renter''s word: they press I posted my review and give the name on it; hidden until the Google review page is set here), a damage-free rental (200: no damage, claim, cleaning or smoking fee, back on time), the birthday (100) and the first rental (100).
2. **Tiers**: Member, Silver from 10 rental days in 12 months (5% off) and Gold from 30 (10% off), with a perk staff honour on request. The discount is a promo code of the renter''s own.
3. Points, tier discounts and codes come off the rental charge only and reduce Owner Revenue like any promo code.
4. **Google reviews claimed** lists every claim; **Reverse** takes the points back with a reason. **A renter''s points**: find the renter, then **Add or take off points** with a reason, or reverse any entry (for example, referral fraud).

### Setup checklist
**Settings** shows what still needs a key from one of CarmaCars'' own accounts. **Add to Apple Wallet** stays hidden until the Apple Pass Type ID certificate is added (WALLET_PASS_CERT, WALLET_PASS_KEY, WALLET_WWDR_CERT, WALLET_PASS_TYPE_ID and WALLET_TEAM_ID in the Worker''s secrets); then it shows on every confirmed booking.


Program: **Call and Text buttons go through Quo** (on) makes every Call and Text button use the CarmaCars number in Quo (chapter Texts and calls). Off, they open the device''s own phone and messages apps.

## Stuck? help

**Settings** > **Program settings** > **Stuck? help**: turn it on or off, the minutes on a page without a successful action (3), and the errors (3) before the box offers the guide and the Academy lesson. **Where people get stuck**, on the same page, lists the pages it showed on most in the last 30 days, with how often the guide and the lesson were opened.

### API access (Claude and scripts)

Settings > **API access** connects Claude so you (or Mahad) can run CarmaCars from a Claude chat: bookings, offers, payments, refunds, returns, cars, rates, listings, owners, invoices, staff and hiring ("hire Ana as customer service"). **Connect from Claude**: in Claude, Settings > Connectors > Add custom connector, paste https://carmacars.ca/api/mcp, then sign in to CarmaCars and press **Allow**. Every change is two steps: Claude first shows what will change (nothing is changed yet), and does it only when you agree. Keys and connections made with every scope got the Admin scopes in release 33; a key with fewer scopes keeps them. For Claude Code or a script, **Make a key**: copy it at once, it is shown only once. Each key or connection acts as its Admin, with the scopes chosen; **Revoke** stops it at once. The **Call log** lists every call (the previews too) with the values before and after. The database checks each action exactly as the Admin screens do.

### The logo

The site, every portal, every email and the documents show the brand logo. To use another, upload it under Settings > **Site settings**, the Logo card (PNG or JPEG for emails and documents).

## Deposits stay as holds (release 28)

Every deposit by card is a hold (an authorization) that stays with Stripe: it is never captured by itself, so nothing is paid out and nothing has to be refunded. Capture only what is owed, and release the rest from the booking. The booking''s Security deposit panel shows Hold expires with the date Stripe gives. When a hold nears its expiry while the car is out or tickets can still come in, Finance gets a To do with **Re-authorize the hold**: a new hold on the saved card, then the old one is released.

**Program settings**: **Extended deposit holds (up to about 30 days)** stays off until Stripe confirms IC+ pricing and extended authorization; when on, the hold on the saved card asks for a longer authorization and falls back to a standard one by itself. It never touches the rental payment. Capturing a deposit hold by itself is off. The heavy cleaning fee (an excessively dirty or smoked-in car) is $300 in **Fees**, editable as every fee.

## Updated terms to accept

**Settings** > **Updated terms**. When the terms of use, the privacy policy or an agreement template changes, publish the new version here; with **Requires acceptance** on, each person it binds accepts it before using their portal.

1. Press **Publish a version**. Choose the Document (the terms of use and the privacy policy bind everyone with a portal; each agreement binds the people who sign it: renters, owners, fleet suppliers, partners, investors, or staff and field).
2. Give the Version (for example the date it takes effect) and **What changed**: people read this summary first.
3. Paste **The new text**. For the terms of use or the privacy policy, leave it empty to use the site''s current text; a text you paste also replaces the site''s page.
4. Leave **Requires acceptance** on and press **Publish a version**.
5. Everyone it binds whose account was opened before sees **We''ve updated our terms** full screen on their next visit, with your summary and the text, and presses Accept. The acceptance is recorded with the time, the IP address, the device and the version.
6. **Accepted** on each version opens who accepted it and when.

> Good to know: It is a click-through acceptance of the new version: no signed agreement is voided and no renter signs the agreement of a past booking again. An Admin account is never asked.

> Good to know: Every agreement is signed with the e-signature only (the identity steps, the IP address, the audit trail): a signature on paper is never recorded. Only an official ServiceOntario form, which the government requires signed in ink, is recorded from its scan.

### Card processing fee for a debit deposit
Program settings: **Card processing fee for a debit deposit: percent (hundredths: 290 is 2.9%)** and **Card processing fee for a debit deposit: fixed part (cents)** (30 is $0.30). When a deposit is charged instead of held on a debit or prepaid card, the renter pays this fee on it, as a separate non-refundable amount shown before they pay, on the receipt and on the Money tab. Set both to 0 to charge no fee.

## My profile and name changes (release 34)
Settings > **My profile** has your display name, **Request a name change** for your legal name, your phone number and **Change my password**. When someone else asks to change the legal name on their agreements, it comes to To do with Approve and Decline, and shows on their page (owner, investor or renter). Approving changes the name on their account and record; agreements already signed keep the name they were signed with.

## AI auto-replies (release 36)

**Settings** > **Program settings**, the AI auto-replies group, answers common questions by itself, only from the FAQ (**Site content**), within Workers AI''s free daily allowance. Each channel has its switch, on by default: texts to the CarmaCars number, emails to the inboxes listed (help@in.carmacars.ca), the website live chat, WhatsApp, Facebook Page messages and Instagram messages.

1. A question the FAQ answers gets the answer at once. A text asked between 1 am and 5 am is answered at 5 am (the quiet hours are settings).
2. When the FAQ does not answer it, or the model is not sure enough (70%), nothing is sent: a text stays in Messages for staff, and an email or a Meta message becomes a To do for customer service, **Answer** and the question.
3. Each person gets at most 5 automatic answers a day, never while a staff member texted them in the last 2 hours, and none once the day''s free AI allowance is used.
4. The card **AI auto-replies: the last answers** shows today''s answers and the last questions, with what was sent or why not.

Messenger, Instagram and WhatsApp need the Meta app''s webhook set to https://carmacars.ca/api/webhooks/meta with the verify token shown in the settings, and the Worker secrets META_APP_SECRET (and WHATSAPP_TOKEN with the WhatsApp number id). TikTok has no inbound message path for businesses, so it is not answered.

## Address suggestions (release 36)

The address fields suggest Canadian addresses from the site''s own address database (Statistics Canada''s Open Database of Addresses, loaded by the addresses workflow, Ontario first). Google is asked only for what the database does not have, and only when its key is set.

## Card coverage: the facts the booking check uses (release 35)

Each card also has: **Network** (Visa, Mastercard, American Express), **Includes rental car damage coverage (CDW)** (Yes, No or Unknown), **Vehicle types not covered** (comma separated: exotic, luxury, truck, van, off_road, antique, motorcycle, limousine, rv), **Must decline the rental company''s CDW** and **Must pay the full rental on the card**. A renter on card coverage picks their card from this list; the site checks it against the car''s value (the Black Book value or the estimate on the car), the car''s type and the length of the rental, and refuses a card that does not cover it. Unknown sends the renter to staff review. Exotic makes are listed in **Program** > **Coverage checks**.

## Fuel prices and delivery (release 35)

- **Program** > **Fuel and charging at the return**: the local pump prices of regular, premium and diesel (a litre), the multiplier (1.25), the refuelling fee ($20), the price a kWh for electric cars ($0.40), and the tank and battery sizes for a car without its own. Update the pump prices every week: **Today** reminds you after 7 days.
- **Airports and delivery** > **Delivery rate and origin**: the base fee each way ($75), the km it includes from the company''s location (15), the rate per km after them ($2), and the straight line to road distance factor (1.3) used when the maps service gives no road distance. A car whose rate card has its own delivery or pickup fee keeps it; every other car follows the base.

## Automatic answers and email budgets (release 36)

- Automatic answers: each channel (text, email, chat, social messages) switches on or off, with the quiet hours, the daily limit per person and how sure the answer must be. The last answers and the questions left for a person show in settings and under renter messages; a question it cannot answer becomes a To do. They stay inside the free daily AI allowance.
- Email budgets: Settings, Usage shows the real daily email capacity of all our sending services together (Cloudflare included), and when a service is not sending, why. Receipts, signed copies and staff messages always go.
- First photo: each listing chooses its first photo, the plain car, a car-show photo with a model, or a flyer with the live price; the flyer is made again when the price changes.
- Rewards: points for a photo with a review and for every rental after the first; every way to earn is on the renter''s Rewards page.',
  '<p class="gd-p">Settings change the public site and the rules of the program at once. Program settings are kept as dated rows, so earlier values stay on record.</p><section class="gd-task" id="settings-the-settings-page" data-gd-task><h2 class="gd-h2">The Settings page</h2><div class="gd-stepblock gd-stepblock--below"><div class="gd-stepcol"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">Site setup lists what is still missing on the public site, with <b class="gd-ui">Open site settings</b>.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Site settings: contact details, hours, tagline, logo, socials, Google place id and featured cars.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Program settings: every timing and policy value.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t">Forms: Blind Spot&#39;s rental agreement for every booking, and the official ServiceOntario PDFs and what goes in each field.</div></li><li><span class="gd-n" aria-hidden="true">5</span><div class="gd-t">Insurers: insurance companies billed for bookings.</div></li></ol></div><figure class="gd-fig gd-fig--desk"><div class="gd-browser"><div class="gd-bar" aria-hidden="true"><i></i><i></i><i></i><span class="gd-addr">carmacars.ca/admin/settings</span></div><div class="gd-imgwrap" style="aspect-ratio:1440/900"><img src="/guides/img/admin-24-settings-desktop-89b31691.jpg" alt="" loading="lazy" decoding="async" width="1440" height="900"><span class="gd-pin" style="left:32.6%;top:33%" aria-hidden="true">1</span><span class="gd-pin" style="left:25.8%;top:40.2%" aria-hidden="true">2</span><span class="gd-pin" style="left:77.4%;top:40.2%" aria-hidden="true">3</span><span class="gd-pin" style="left:25.8%;top:73.2%" aria-hidden="true">4</span><span class="gd-pin" style="left:25.8%;top:84.9%" aria-hidden="true">5</span></div></div></figure></div><p class="gd-p">The other tiles: Site content (headings, FAQs, legal text), Fee defaults, Deposit tiers, Kilometre choices, Vehicle classes, Vehicle class rules, Airports and delivery, Protection Plan prices, Card coverage, Reviews, Quo contacts (everyone with a phone number as a contact in Quo: see Texts and calls), Text alerts, Partners (each partner company&#39;s CRM link: see Partners, company cars and rentals added by hand), Email aliases and reply-to, My profile, Staff and roles, Promo codes and Quick replies.</p><p class="gd-p"><b class="gd-ui">My profile</b>: the greeting name of this login. To do greets it whole (&quot;Good morning, Abbas and Mahad&quot; on a login the owners share) and the assistant uses it; empty, the first name of the account. Press <b class="gd-ui">Change the greeting name</b>, type it and save.</p></section><section class="gd-task" id="settings-program-settings" data-gd-task><h2 class="gd-h2">Program settings</h2><div class="gd-stepblock gd-stepblock--below"><div class="gd-stepcol"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">Buffer between trips (90 minutes): the time held before and after every trip, in every availability and conflict check (requests, offers, date changes, extensions, the calendar). The cleaning block after a trip is this time; Turnaround between trips is the same number. A booking already closer than this is not changed: the calendar rings it.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Late fee and extensions (Booking requests and offers): the late fee per started hour (17.5% of the daily rate, at least $25; new bookings and offers only), the extension discounts (no longer applied since release 35: an extension costs the booking&#39;s all-in price a day) and <b class="gd-ui">Approve a renter&#39;s extension at once when nothing needs a person</b> (on). A car&#39;s own switch is in Fleet, the car, <b class="gd-ui">Edit details</b>: <b class="gd-ui">Renters extend themselves</b>.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">RentalCover (the Protection Plan): whether quotes price the plan once the key is set (on), the markup (on, 20%, no fixed amount), how long a quote is reused, the car value limit ($50,000) and whether a car with no value may have the plan (off).</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t">Settings come in groups such as Company, Booking requests and offers, Owner debits and statement emails, Deposits, Delivery, Owners and fleet, and Tolls and damage. Open one to see its fields.</div></li><li><span class="gd-n" aria-hidden="true">5</span><div class="gd-t">First reply target for customer service and sales (minutes), under Booking requests and offers: 5 by default. New booking requests, enquiries, changes renters ask for and renter messages are due that many minutes after they come in; the scorecard and the staff screens use it. What renters are told (Reply wording, in Site settings) is separate.</div></li><li><span class="gd-n" aria-hidden="true">6</span><div class="gd-t">Staff commissions and prices typed by hand: the commission outside Sales (10%, field staff only: customer service, Fleet and Finance earn none), the three Sales tiers and their days (10%, 15% from 50 days, 20% from 100 days, the month&#39;s target), the price floor a day (empty: none) and the discount from the rate sheet that flags a price (20%). The owner confirmed these values in October 2026. The remote Sales values follow: the three remote tiers (5%, 10%, 15%), the touches a month (400), the drop under it (one tier) and its floor (2.5%), the peak hours a week (20), the reply target (15 minutes) and the peak hours (noon to 6 pm, Thursday to Sunday).</div></li><li><span class="gd-n" aria-hidden="true">7</span><div class="gd-t">Staff agreement defaults by function, at the bottom: pay (a month, an hour or commission only), the rate, the schedule (full time, part time or flexible), days a week and hours a day for Customer service, Fleet, Finance and Sales, the values every assistant shares, and the field staff wage. Sales is commission only: no rate and a flexible schedule. Press <b class="gd-ui">Save the defaults</b>.</div></li><li><span class="gd-n" aria-hidden="true">8</span><div class="gd-t">Live visitors and live chat: recording visits, the signal thresholds, follow-up tasks, the chat and its assistant, and how long visits and chats are kept.</div></li><li><span class="gd-n" aria-hidden="true">9</span><div class="gd-t">Discount games: the same values as Settings, Discount games (the prize table and the games are easier to change there).</div></li><li><span class="gd-n" aria-hidden="true">10</span><div class="gd-t">Deposits: the toll and ticket window after the return (7 days: settling sooner suggests a hold-back), the longest hold-back (30 days after the return), how long before a card hold lapses it is collected (36 hours), and collecting what is owed after the deposit by itself (the card on file, then a pay link, then a Finance task). A deposit is never released by itself.</div></li><li><span class="gd-n" aria-hidden="true">11</span><div class="gd-t">Field jobs and handovers: field jobs made from each confirmed booking (on) and who gets them (the least busy field staff member, or nobody so Fleet assigns), how field staff may take a deposit at the check-in besides a card (e-Transfer and cash), and whether they may release a car whose tracker is not reporting, with a reason (on; you get an urgent task). Field pay: the first day of a pay period (every period is two weeks), the default hourly rate (CA$18.00), whether overtime is paid (off), after how many hours in a week (44) and at what share of the rate (150%), vacation pay added to each statement (off; Ontario 4%) and the longest shift (16 hours).</div></li><li><span class="gd-n" aria-hidden="true">12</span><div class="gd-t">Sign-in by phone: codes by text from the CarmaCars number (on), US numbers (off until the Quo number is registered for US texting, A2P 10DLC), codes per number and per connection an hour, and whether a verified phone confirms an account like a confirmed email. Accepting an offer, signing and paying need a confirmed account; an account made by phone gives its email on the pay page before its first payment.</div></li><li><span class="gd-n" aria-hidden="true">13</span><div class="gd-t">Calendar sync, Turo by email, Booking recovery emails and Site check: how often calendar links are read, the Turo inbound address and who may forward to it, the reminder delays and sending hours, and the site check with the address its alerts go to (rent@carmacars.ca), the minutes before an email, the daily limit and the quiet hours.</div></li><li><span class="gd-n" aria-hidden="true">14</span><div class="gd-t">Change a value and press <b class="gd-ui">Save</b>. It is saved as a new row from today; the rows before stay as they were.</div></li></ol></div><figure class="gd-fig gd-fig--desk"><div class="gd-browser"><div class="gd-bar" aria-hidden="true"><i></i><i></i><i></i><span class="gd-addr">carmacars.ca/admin/settings/program</span></div><div class="gd-imgwrap" style="aspect-ratio:1440/1000"><img src="/guides/img/admin-25-program-settings-desktop-d16b066c.jpg" alt="" loading="lazy" decoding="async" width="1440" height="1000"><span class="gd-pin" style="left:25.8%;top:22%" aria-hidden="true">1</span><span class="gd-pin" style="left:27.8%;top:49%" aria-hidden="true">2</span></div></div></figure></div></section><section class="gd-task" id="settings-lead-time-pricing" data-gd-task><h2 class="gd-h2">Lead-time pricing</h2><p class="gd-p">A car booked at short notice costs a little more and one booked well ahead a little less. Open <b class="gd-ui">Settings</b>, then <b class="gd-ui">Program settings</b>: Lead-time pricing is at the top.</p><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">The switch turns it on or off for every car (on by default).</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">The table holds the tiers: when the pickup is that many hours away, the rental charge changes by that percentage. By default: under 24 hours +15%, 24 to 72 hours +10%, 3 to 13 days 0%, 14 days or more −5%. Type the hours and the percentage on each row (a minus for less); <b class="gd-ui">Add a tier</b> adds one, <b class="gd-ui">Remove</b> takes one off. Each row shows what it does to a $500 rental.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t"><b class="gd-ui">Also adjust bookings billed to an insurer</b> is off by default: an insurer pays its own rate, never a short-notice premium.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t">Press <b class="gd-ui">Save lead-time pricing</b>. New quotes and requests use it; bookings already made keep theirs.</div></li></ol></div><div class="gd-tablewrap"><table class="gd-table"><thead><tr><th scope="col">What it touches</th><th scope="col">How</th></tr></thead><tbody><tr><td>The rental charge</td><td>The percentage of the rental charge only, before tax: one line in the price, &quot;Short-notice pricing +10%&quot; or &quot;Booked ahead −5%&quot;. Never the fees, the deposit or add-ons</td></tr><tr><td>When it is worked out</td><td>When the quote is made (the car page, the cars list once dates are chosen, the request), from that moment to the pickup on Toronto clocks. &quot;From $X a day&quot; stays at the base rate</td></tr><tr><td>When it is locked</td><td>On the request: the offer, a change of dates and the payment keep the same percentage</td></tr><tr><td>Other discounts</td><td>The non-refundable discount, a promo code and a staff discount are worked out on the rental charge from the rates, as before, and show beside it</td></tr><tr><td>Owner revenue and commissions</td><td>Count the rental charge after it, as they count the discounts</td></tr><tr><td>Staff</td><td>Change it on a booking under <b class="gd-ui">More options</b> on the review screen; a price typed by hand replaces it. Rentals added by hand, Owner Bookings and placeholders are not adjusted</td></tr></tbody></table></div><aside class="gd-box"><span class="gd-lbl">Tip</span><div>A car can turn it off or have its own tiers: <b class="gd-ui">Vehicles</b> &gt; the car &gt; <b class="gd-ui">Rates</b> &gt; Lead-time pricing for this car.</div></aside></section><section class="gd-task" id="settings-vehicle-class-rules" data-gd-task><h2 class="gd-h2">Vehicle class rules</h2><p class="gd-p">Open <b class="gd-ui">Settings</b>, then <b class="gd-ui">Vehicle class rules</b>. How a new car&#39;s class is decided from its VIN: the first rule that matches wins.</p><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">The table lists each rule: its rank, what the car must be (a make, and patterns for the model, the trim and the body), the class it gets, the class once the car is old enough, a note and whether it is on. The lowest rank that matches is used; a car that matches no rule is Standard.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Press <b class="gd-ui">Add a rule</b> or <b class="gd-ui">Change</b>: a rank, at least one condition, the class, optionally the years old after which an older class applies, and a note (it is shown as the reason for the class). A pattern is not case sensitive: ^911 matches models that start with 911. A rule with no condition, a pattern that does not compile and an older class equal to the class are refused.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t"><b class="gd-ui">Try a car</b> gives the class the rules decide for a year, make, model, trim and body, and why.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t"><b class="gd-ui">Delete</b> removes a rule; switch it off instead to keep it. Every add, change and delete is in the audit log, with before and after.</div></li></ol></div><aside class="gd-box"><span class="gd-lbl">Tip</span><div>A rule changes the cars entered from then on. A car already listed keeps its class until you change it on the car.</div></aside></section><section class="gd-task" id="settings-official-serviceontario-forms" data-gd-task><h2 class="gd-h2">Official ServiceOntario forms</h2><p class="gd-p">The five official forms are loaded with a mapping to the owner, car, company and lender details. Each is the form exactly as ServiceOntario publishes it: only its empty text boxes are filled; its own text and layout are never changed. A form whose stored PDF is not the publisher&#39;s download (or your upload of it) gives owners the data sheet instead. Its checkboxes, drop-downs and signatures are done by hand at the counter, in ink. Until you check a form, owners get a data sheet with the values.</p><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">Open <b class="gd-ui">Settings</b> &gt; <b class="gd-ui">Forms</b>. Each form shows &quot;Mapping to check&quot; (a draft is ready) or &quot;Official PDF in use&quot;. Its notes say what the form is for and which boxes are left blank on purpose.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Choose <b class="gd-ui">Preview with</b>: a sample car (made-up values) or one of the cars. Press <b class="gd-ui">Download a filled preview</b> and check each value against the form. The preview uses the mapping on screen, saved or not.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Change a field if needed: What goes in it (or &quot;Signed here by hand, in ink&quot;), a Format (for example YYYY/MM/DD) and Only when. Write what you changed and press Save the mapping. <b class="gd-ui">Earlier mappings</b> lists every save, with who and when; <b class="gd-ui">Load</b> puts one back on screen to preview and save again. Fleet can map the forms too (Owners &gt; Government forms), but only an Admin uploads a form.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t">Press <b class="gd-ui">Checked: use for owners</b>. Every owner&#39;s form of that kind is filled again, except ones already signed or filed. Owners download it, print it and sign it in ink; record it with <b class="gd-ui">Record an official form signed in ink</b>. Each form not checked yet is also a line on To do with the same button and Preview it.</div></li><li><span class="gd-n" aria-hidden="true">5</span><div class="gd-t">A new version from ServiceOntario? Press <b class="gd-ui">Upload the official fillable PDF</b>: the fields of the same name keep their mapping.</div></li></ol></div><aside class="gd-box"><span class="gd-lbl">Good to know</span><div>SR-LV-006 (registration), SR-LV-012 (two registrants), ON00453 (a company&#39;s RIN), 013-1155 and 013-0169 (the tax-exempt transfer into an owner&#39;s corporation). 013-1155 is sworn before a commissioner, so it is printed and signed in person. ON00453 is an Adobe form: it opens in Adobe Acrobat Reader. Each form&#39;s notes list what to tick or choose at the counter. A car gets only the forms its onboarding method needs: no form for a Transfer of a car owned outright or financed (the sign-back on the permit), 013-1155 and 013-0169 only for a Lease through a new Owner Corporation.</div></aside></section><section class="gd-task" id="settings-blind-spot-rental-agreement" data-gd-task><h2 class="gd-h2">Blind Spot rental agreement</h2><p class="gd-p">We rent under Blind Spot Car Rental&#39;s insurance, so every booking has two agreements: CarmaCars&#39; rental agreement and Blind Spot&#39;s own. Blind Spot&#39;s is filled in from the booking, the renter and the car, and the renter signs both with one signature. Its PDF is stored privately, never on the website.</p><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">Open <b class="gd-ui">Settings</b> &gt; <b class="gd-ui">Forms</b>. The Blind Spot Car Rental agreement card is first. Press <b class="gd-ui">Upload Blind Spot&#39;s PDF</b> and choose Blind Spot&#39;s blank form (2 pages, A4).</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Press <b class="gd-ui">Download the filled sample</b>: a made-up booking on the form. <b class="gd-ui">Sample billed to an insurer</b> also fills the claim number, the adjuster and the insurance company. Check every box.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">On the form the old address (top left and twice in box 15) is replaced by the mailing address of Site settings, box 1 by CarmaCars&#39; HST number (Program settings, Company HST number; blank until it is entered), and box 21 has the representative&#39;s signature instead of Sam&#39;s.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t">Press <b class="gd-ui">Checked: use for bookings</b>. From then on each booking gets it when its rental agreement is made; a renter whose agreement is already open gets it the next time they open the signing page.</div></li><li><span class="gd-n" aria-hidden="true">5</span><div class="gd-t">Box 21: Ahmad is written in a script hand, as Blind Spot asked. To use a real signature instead, upload a PNG under Authorized company representative; Remove the image goes back to the written name. Full name is for the signature record page.</div></li><li><span class="gd-n" aria-hidden="true">6</span><div class="gd-t">A new version of Blind Spot&#39;s form? Upload it the same way: it waits for <b class="gd-ui">Checked: use for bookings</b>, and bookings keep the version in use until then.</div></li></ol></div><aside class="gd-box"><span class="gd-lbl">Good to know</span><div>Each box is filled only when the booking has the value: the renter and their licence, the additional drivers, the car (plate, make and model, the fleet number as vehicle number), the pickup as time and date out, the due-back date and time, the kilometres allowed, the rate rows (days, weeks or months @ the rate = the amount; a rental counted by the day, such as 31 days at the monthly rate, shows its daily rate rounded to the cent, and box 14 says how the charge was made), the underage fee, the Protection Plan as CDW, winter tires, the subtotal, HST (13% of the subtotal), total and deposit, the deposit received and the day it was taken (before pickup, the amount due at pickup), and for a booking billed to an insurer the insurer, claim number and adjuster. Other charges, such as delivery, are listed in box 14. The boxes filled at check-in and check-out stay blank until then. The fuel gauges are covered and the level of the check-in report (fuel out) and the check-out report (fuel in) is written in words, blank with no reading.</div></aside><p class="gd-p">The renter&#39;s signature goes in boxes 16, 17 and 20 of the signed copy, with the day they signed beside box 20 and a signature record page. Each later version (as picked up, as returned, corrected) carries the same signature and day. Both agreements are in the booking&#39;s Drivers and documents tab, in the renter&#39;s Documents, and the signed Blind Spot agreement is attached to the &quot;Your signed rental agreement&quot; email. Admin &gt; Today lists the HST number, the upload and the check until they are done.</p></section><section class="gd-task" id="settings-agreements-to-sign-investors-and-staff" data-gd-task><h2 class="gd-h2">Agreements to sign: investors and staff</h2><p class="gd-p">Investment agreements and staff agreements are made from the person&#39;s record and signed in their own portal, with the e-signature (never on paper).</p><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">Investor: open <b class="gd-ui">People</b> &gt; <b class="gd-ui">Investors</b> and the investor. Under Investment agreement, press <b class="gd-ui">Send the agreement to sign</b>. Check the values it is filled with (amount, yearly percentage, dates, exemption) and press <b class="gd-ui">Send to sign</b>.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Once the investor signs, the agreement shows <b class="gd-ui">Awaiting countersignature</b> on the investor&#39;s page and on To do. It is not countersigned automatically: check it and press <b class="gd-ui">Countersign</b>. CarmaCars is bound once it has countersigned and the funds clear.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Staff: open <b class="gd-ui">People</b> &gt; <b class="gd-ui">Team</b>. Under Staff agreements, press <b class="gd-ui">Send the agreement to sign</b> beside the person. Pay, schedule, hours and the other values start from the staff profile and the defaults of their function in Program settings; change any before sending. For Sales the Pay is Commission only: the agreement then has no rate, schedule or hours, and pays the commission of section 3.4.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t">A field staff member&#39;s agreement prints the home address they entered themselves. Staff enter their home address at their first sign-in, before they sign, or in their profile.</div></li><li><span class="gd-n" aria-hidden="true">5</span><div class="gd-t">They get a notice, check the key values and sign in their portal in a few taps (their name is the signature, or they draw it). The signed copy is filed with their documents.</div></li><li><span class="gd-n" aria-hidden="true">6</span><div class="gd-t">Your own PDF instead? <b class="gd-ui">Send a PDF to sign</b> still works.</div></li><li><span class="gd-n" aria-hidden="true">7</span><div class="gd-t">Sent by mistake? Press <b class="gd-ui">Withdraw</b> and give the reason.</div></li></ol></div></section><section class="gd-task" id="settings-the-user-guides" data-gd-task><h2 class="gd-h2">The user guides</h2><p class="gd-p"><b class="gd-ui">Settings</b> &gt; <b class="gd-ui">Guides</b>. The guide of each portal, as people read it under Guide.</p><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">Each guide shows its version, when it was published and whether there are unpublished changes.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Open a guide and press a section. Change its text and press <b class="gd-ui">Show the preview</b> to see it as people will. Press <b class="gd-ui">Save the draft</b>; each save is kept in the section&#39;s history.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Move a section with the arrows, hide it, or press <b class="gd-ui">Add a chapter</b>. Upload a screenshot under Screenshots and paste the line it gives you.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t">Press <b class="gd-ui">Publish version</b> (the next number). The portals show the new version at once.</div></li><li><span class="gd-n" aria-hidden="true">5</span><div class="gd-t">The stored PDF is printed again by the guides-pdf workflow. Until then the guide says the web guide has newer edits.</div></li></ol></div></section><section class="gd-task" id="settings-the-guides-keep-up-by-themselves" data-gd-task><h2 class="gd-h2">The guides keep up by themselves</h2><p class="gd-p">After every update of the site that changes the portals, the guides are checked without anyone asking.</p><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">Every screenshot is taken again on the new version of the site. One whose screen changed replaces the old one in the guide.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">The text of each section whose screen changed, or that names a button the portals no longer show, is rewritten from the portal&#39;s own labels and menu, checked, and published. The PDFs of those guides are printed again.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Such a section says <b class="gd-ui">Changed automatically on</b> and the date, in the list of guides and in the guide&#39;s editor. Not right? Open the section and press <b class="gd-ui">Revert</b>: the text it replaced comes back, published at once.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t">This includes sections you edited: the newest automatic text is published, and every earlier version stays in the section&#39;s history. There is nothing to review.</div></li><li><span class="gd-n" aria-hidden="true">5</span><div class="gd-t">A rewrite that does not pass the checks is asked again, more strictly. If it still does not pass, the screenshots and button names are updated, the rest of the text stays as it was, and the next run tries again.</div></li></ol></div><aside class="gd-box"><span class="gd-lbl">Tip</span><div>The card &quot;The guides keep up by themselves&quot; at the top of Guides lists the last runs: when, how many screenshots were replaced, how many sections were rewritten, and how many PDFs were printed.</div></aside></section><section class="gd-task" id="settings-insurers-and-the-other-lists" data-gd-task><h2 class="gd-h2">Insurers and the other lists</h2><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">Open Insurers. Each insurer on file opens to edit its billing contact, email, phone, address and notes. Its rates by car class are in <b class="gd-ui">Money</b> &gt; <b class="gd-ui">Insurers</b>.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">To add one, fill in the Add form (Name, Billing contact, Billing email and the rest) and press <b class="gd-ui">Add</b>.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Deposit tiers, Kilometre choices, Vehicle classes, Airports, Promo codes and Quick replies work the same way.</div></li></ol></div></section><section class="gd-task" id="settings-promo-codes-end-dates-and-reminders" data-gd-task><h2 class="gd-h2">Promo codes: end dates and reminders</h2><p class="gd-p"><b class="gd-ui">Settings</b>, <b class="gd-ui">Promo codes</b>.</p><ul class="gd-ul"><li>Every code made for a person has an end date: a game prize 7 days, a come-back offer 30, a Live visitors code 3 and a code made for one renter 30 unless you set another. The first card of Promo codes holds the 30 days and the two reminders.</li><li>A code for everyone may have no end date: empty Valid until. The Add form starts with an end date 30 days ahead.</li><li>A code that ended is refused wherever it is typed (the request form, an offer, Add a rental, a booking edit) with &quot;This code has expired&quot;.</li><li>A person who has not used a code is reminded 3 days before its last day and the day before, by email and by text as they chose, never once they used it, unsubscribed or the code ended, and never twice. A game code reminder always goes; a reminder of any other code needs their consent to offers.</li><li>The list shows each code&#39;s end date and the reminders sent. The card Codes sent to people lists game prizes, come-back offers and Live visitors codes the same way.</li></ul></section><section class="gd-task" id="settings-card-coverage-which-credit-cards-include-rental-car-coverage" data-gd-task><h2 class="gd-h2">Card coverage: which credit cards include rental car coverage</h2><p class="gd-p"><b class="gd-ui">Settings</b> &gt; <b class="gd-ui">Card coverage</b> is the list renters see at <span class="gd-url">carmacars.ca/credit-card-rental-coverage</span> and staff see under Card coverage in their portal. It starts filled in with 48 Canadian and US cards, each checked on October 23, 2026.</p><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">The table shows each card: who pays first (Primary, Secondary, or not stated), the car value limit (MSRP), the longest rental, whether the numbers were read in the issuer&#39;s own document, and when it was last checked.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Open a card under Change a card, open its official guide, correct what changed and press <b class="gd-ui">Save</b>. Changing the facts without a date marks the card checked today; type a Last checked date to record another day.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">A card whose numbers come from a published summary has Read in the issuer&#39;s own document unticked and the summary&#39;s link under Where the numbers came from. The page shows it as Unverified. Tick it once you have read the issuer&#39;s guide.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t">Add a card with the Add form; untick Shown to hide one. Changes reach the public page at once.</div></li></ol></div><aside class="gd-box"><span class="gd-lbl">Tip</span><div>A card not checked for 6 months shows on Today until it is checked again. The page tells renters to confirm with their card issuer and says CarmaCars decides no claims: keep the list to facts from the issuer&#39;s guide.</div></aside></section><section class="gd-task" id="settings-reviews-review-requests-and-google" data-gd-task><h2 class="gd-h2">Reviews: review requests and Google</h2><p class="gd-p"><b class="gd-ui">Settings</b> &gt; <b class="gd-ui">Reviews</b>: when review requests go, the Google review link and the Google Business Profile connection. Review requests are on from the start.</p><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">When review requests go: the check-out (on or off, the shortest rental, hours after the pickup), the request (minutes after the check-out), the reminder (hours) and the final follow-up (days), the sending hours (9 am to 9 pm), and the hold while charges are open.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">The Google review link: the Google place id (Site settings) makes it, or paste the Business Profile&#39;s own review link.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Google Business Profile: press <b class="gd-ui">Connect Google</b> and sign in with rent@carmacars.ca, then allow access. Reviews are read every 6 hours and matched to renters by name within 30 days after their return.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t">A clear match stops that renter&#39;s reminders at once. A possible match waits in Reviews: press <b class="gd-ui">Confirm</b>, <b class="gd-ui">Not this renter</b> or <b class="gd-ui">Match to a booking</b>.</div></li></ol></div><aside class="gd-box"><span class="gd-lbl">Tip</span><div>Until Google approves the Business Profile API for the project, the status says so and nothing else changes: renters still get the review link, and &quot;I already left a review&quot;, Mark reviewed and on-site reviews still stop the messages.</div></aside><h3 class="gd-h3">Pair the card reader</h3><p class="gd-p"><b class="gd-ui">Settings</b> &gt; <b class="gd-ui">Card reader</b>. On the Stripe S700, swipe from the left edge, open <b class="gd-ui">Settings</b>, then <b class="gd-ui">Generate pairing code</b>. Type the three words in <b class="gd-ui">Pairing code</b>, name the reader (Front desk) and press <b class="gd-ui">Pair reader</b>. The first time, a Stripe Terminal location is made from the mailing address in Site settings: write it as street, city, province and postal code. <b class="gd-ui">Remove</b> takes a reader off the list. Card statements read 18122211 Canada Inc., the Stripe account&#39;s statement descriptor.</p><h3 class="gd-h3">Rewards</h3><p class="gd-p"><b class="gd-ui">Settings</b> &gt; <b class="gd-ui">Rewards</b>. CarmaCars Rewards is on: 1 point per dollar of the rental charge after discounts (never fees, add-ons, coverage, tax or the deposit), 100 points = $1, redeemed from 500 points as a code of the renter&#39;s own, valid 90 days. Points end 12 months after the last rental or redemption, with a reminder email 30 days before.</p><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t"><b class="gd-ui">Ways to earn</b>: each on or off with its points. Referral (500 to the referrer, 250 to the friend, at the friend&#39;s first completed rental), a follow on Instagram, TikTok or Facebook (50 each, once, granted on the click from the Rewards page, since a follow cannot be checked; a platform shows only with its page in Site settings), a review on carmacars.ca (100, any rating; the review shows &quot;Received reward points&quot;), a Google review (100 a rental, any rating, on the renter&#39;s word: they press I posted my review and give the name on it; hidden until the Google review page is set here), a damage-free rental (200: no damage, claim, cleaning or smoking fee, back on time), the birthday (100) and the first rental (100).</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t"><b class="gd-ui">Tiers</b>: Member, Silver from 10 rental days in 12 months (5% off) and Gold from 30 (10% off), with a perk staff honour on request. The discount is a promo code of the renter&#39;s own.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Points, tier discounts and codes come off the rental charge only and reduce Owner Revenue like any promo code.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t"><b class="gd-ui">Google reviews claimed</b> lists every claim; <b class="gd-ui">Reverse</b> takes the points back with a reason. <b class="gd-ui">A renter&#39;s points</b>: find the renter, then <b class="gd-ui">Add or take off points</b> with a reason, or reverse any entry (for example, referral fraud).</div></li></ol></div><h3 class="gd-h3">Setup checklist</h3><p class="gd-p"><b class="gd-ui">Settings</b> shows what still needs a key from one of CarmaCars&#39; own accounts. <b class="gd-ui">Add to Apple Wallet</b> stays hidden until the Apple Pass Type ID certificate is added (WALLET_PASS_CERT, WALLET_PASS_KEY, WALLET_WWDR_CERT, WALLET_PASS_TYPE_ID and WALLET_TEAM_ID in the Worker&#39;s secrets); then it shows on every confirmed booking.</p><p class="gd-p">Program: <b class="gd-ui">Call and Text buttons go through Quo</b> (on) makes every Call and Text button use the CarmaCars number in Quo (chapter Texts and calls). Off, they open the device&#39;s own phone and messages apps.</p></section><section class="gd-task" id="settings-stuck-help" data-gd-task><h2 class="gd-h2">Stuck? help</h2><p class="gd-p"><b class="gd-ui">Settings</b> &gt; <b class="gd-ui">Program settings</b> &gt; <b class="gd-ui">Stuck? help</b>: turn it on or off, the minutes on a page without a successful action (3), and the errors (3) before the box offers the guide and the Academy lesson. <b class="gd-ui">Where people get stuck</b>, on the same page, lists the pages it showed on most in the last 30 days, with how often the guide and the lesson were opened.</p><h3 class="gd-h3">API access (Claude and scripts)</h3><p class="gd-p">Settings &gt; <b class="gd-ui">API access</b> connects Claude so you (or Mahad) can run CarmaCars from a Claude chat: bookings, offers, payments, refunds, returns, cars, rates, listings, owners, invoices, staff and hiring (&quot;hire Ana as customer service&quot;). <b class="gd-ui">Connect from Claude</b>: in Claude, Settings &gt; Connectors &gt; Add custom connector, paste https://carmacars.ca/api/mcp, then sign in to CarmaCars and press <b class="gd-ui">Allow</b>. Every change is two steps: Claude first shows what will change (nothing is changed yet), and does it only when you agree. Keys and connections made with every scope got the Admin scopes in release 33; a key with fewer scopes keeps them. For Claude Code or a script, <b class="gd-ui">Make a key</b>: copy it at once, it is shown only once. Each key or connection acts as its Admin, with the scopes chosen; <b class="gd-ui">Revoke</b> stops it at once. The <b class="gd-ui">Call log</b> lists every call (the previews too) with the values before and after. The database checks each action exactly as the Admin screens do.</p><h3 class="gd-h3">The logo</h3><p class="gd-p">The site, every portal, every email and the documents show the brand logo. To use another, upload it under Settings &gt; <b class="gd-ui">Site settings</b>, the Logo card (PNG or JPEG for emails and documents).</p></section><section class="gd-task" id="settings-deposits-stay-as-holds-release-28" data-gd-task><h2 class="gd-h2">Deposits stay as holds (release 28)</h2><p class="gd-p">Every deposit by card is a hold (an authorization) that stays with Stripe: it is never captured by itself, so nothing is paid out and nothing has to be refunded. Capture only what is owed, and release the rest from the booking. The booking&#39;s Security deposit panel shows Hold expires with the date Stripe gives. When a hold nears its expiry while the car is out or tickets can still come in, Finance gets a To do with <b class="gd-ui">Re-authorize the hold</b>: a new hold on the saved card, then the old one is released.</p><p class="gd-p"><b class="gd-ui">Program settings</b>: <b class="gd-ui">Extended deposit holds (up to about 30 days)</b> stays off until Stripe confirms IC+ pricing and extended authorization; when on, the hold on the saved card asks for a longer authorization and falls back to a standard one by itself. It never touches the rental payment. Capturing a deposit hold by itself is off. The heavy cleaning fee (an excessively dirty or smoked-in car) is $300 in <b class="gd-ui">Fees</b>, editable as every fee.</p></section><section class="gd-task" id="settings-updated-terms-to-accept" data-gd-task><h2 class="gd-h2">Updated terms to accept</h2><p class="gd-p"><b class="gd-ui">Settings</b> &gt; <b class="gd-ui">Updated terms</b>. When the terms of use, the privacy policy or an agreement template changes, publish the new version here; with <b class="gd-ui">Requires acceptance</b> on, each person it binds accepts it before using their portal.</p><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">Press <b class="gd-ui">Publish a version</b>. Choose the Document (the terms of use and the privacy policy bind everyone with a portal; each agreement binds the people who sign it: renters, owners, fleet suppliers, partners, investors, or staff and field).</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Give the Version (for example the date it takes effect) and <b class="gd-ui">What changed</b>: people read this summary first.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Paste <b class="gd-ui">The new text</b>. For the terms of use or the privacy policy, leave it empty to use the site&#39;s current text; a text you paste also replaces the site&#39;s page.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t">Leave <b class="gd-ui">Requires acceptance</b> on and press <b class="gd-ui">Publish a version</b>.</div></li><li><span class="gd-n" aria-hidden="true">5</span><div class="gd-t">Everyone it binds whose account was opened before sees <b class="gd-ui">We&#39;ve updated our terms</b> full screen on their next visit, with your summary and the text, and presses Accept. The acceptance is recorded with the time, the IP address, the device and the version.</div></li><li><span class="gd-n" aria-hidden="true">6</span><div class="gd-t"><b class="gd-ui">Accepted</b> on each version opens who accepted it and when.</div></li></ol></div><aside class="gd-box"><span class="gd-lbl">Good to know</span><div>It is a click-through acceptance of the new version: no signed agreement is voided and no renter signs the agreement of a past booking again. An Admin account is never asked.</div></aside><aside class="gd-box"><span class="gd-lbl">Good to know</span><div>Every agreement is signed with the e-signature only (the identity steps, the IP address, the audit trail): a signature on paper is never recorded. Only an official ServiceOntario form, which the government requires signed in ink, is recorded from its scan.</div></aside><h3 class="gd-h3">Card processing fee for a debit deposit</h3><p class="gd-p">Program settings: <b class="gd-ui">Card processing fee for a debit deposit: percent (hundredths: 290 is 2.9%)</b> and <b class="gd-ui">Card processing fee for a debit deposit: fixed part (cents)</b> (30 is $0.30). When a deposit is charged instead of held on a debit or prepaid card, the renter pays this fee on it, as a separate non-refundable amount shown before they pay, on the receipt and on the Money tab. Set both to 0 to charge no fee.</p></section><section class="gd-task" id="settings-my-profile-and-name-changes-release-34" data-gd-task><h2 class="gd-h2">My profile and name changes (release 34)</h2><p class="gd-p">Settings &gt; <b class="gd-ui">My profile</b> has your display name, <b class="gd-ui">Request a name change</b> for your legal name, your phone number and <b class="gd-ui">Change my password</b>. When someone else asks to change the legal name on their agreements, it comes to To do with Approve and Decline, and shows on their page (owner, investor or renter). Approving changes the name on their account and record; agreements already signed keep the name they were signed with.</p></section><section class="gd-task" id="settings-ai-auto-replies-release-36" data-gd-task><h2 class="gd-h2">AI auto-replies (release 36)</h2><p class="gd-p"><b class="gd-ui">Settings</b> &gt; <b class="gd-ui">Program settings</b>, the AI auto-replies group, answers common questions by itself, only from the FAQ (<b class="gd-ui">Site content</b>), within Workers AI&#39;s free daily allowance. Each channel has its switch, on by default: texts to the CarmaCars number, emails to the inboxes listed (help@in.carmacars.ca), the website live chat, WhatsApp, Facebook Page messages and Instagram messages.</p><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">A question the FAQ answers gets the answer at once. A text asked between 1 am and 5 am is answered at 5 am (the quiet hours are settings).</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">When the FAQ does not answer it, or the model is not sure enough (70%), nothing is sent: a text stays in Messages for staff, and an email or a Meta message becomes a To do for customer service, <b class="gd-ui">Answer</b> and the question.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Each person gets at most 5 automatic answers a day, never while a staff member texted them in the last 2 hours, and none once the day&#39;s free AI allowance is used.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t">The card <b class="gd-ui">AI auto-replies: the last answers</b> shows today&#39;s answers and the last questions, with what was sent or why not.</div></li></ol></div><p class="gd-p">Messenger, Instagram and WhatsApp need the Meta app&#39;s webhook set to https://carmacars.ca/api/webhooks/meta with the verify token shown in the settings, and the Worker secrets META_APP_SECRET (and WHATSAPP_TOKEN with the WhatsApp number id). TikTok has no inbound message path for businesses, so it is not answered.</p></section><section class="gd-task" id="settings-address-suggestions-release-36" data-gd-task><h2 class="gd-h2">Address suggestions (release 36)</h2><p class="gd-p">The address fields suggest Canadian addresses from the site&#39;s own address database (Statistics Canada&#39;s Open Database of Addresses, loaded by the addresses workflow, Ontario first). Google is asked only for what the database does not have, and only when its key is set.</p></section><section class="gd-task" id="settings-card-coverage-the-facts-the-booking-check-uses-release-35" data-gd-task><h2 class="gd-h2">Card coverage: the facts the booking check uses (release 35)</h2><p class="gd-p">Each card also has: <b class="gd-ui">Network</b> (Visa, Mastercard, American Express), <b class="gd-ui">Includes rental car damage coverage (CDW)</b> (Yes, No or Unknown), <b class="gd-ui">Vehicle types not covered</b> (comma separated: exotic, luxury, truck, van, off_road, antique, motorcycle, limousine, rv), <b class="gd-ui">Must decline the rental company&#39;s CDW</b> and <b class="gd-ui">Must pay the full rental on the card</b>. A renter on card coverage picks their card from this list; the site checks it against the car&#39;s value (the Black Book value or the estimate on the car), the car&#39;s type and the length of the rental, and refuses a card that does not cover it. Unknown sends the renter to staff review. Exotic makes are listed in <b class="gd-ui">Program</b> &gt; <b class="gd-ui">Coverage checks</b>.</p></section><section class="gd-task" id="settings-fuel-prices-and-delivery-release-35" data-gd-task><h2 class="gd-h2">Fuel prices and delivery (release 35)</h2><ul class="gd-ul"><li><b class="gd-ui">Program</b> &gt; <b class="gd-ui">Fuel and charging at the return</b>: the local pump prices of regular, premium and diesel (a litre), the multiplier (1.25), the refuelling fee ($20), the price a kWh for electric cars ($0.40), and the tank and battery sizes for a car without its own. Update the pump prices every week: <b class="gd-ui">Today</b> reminds you after 7 days.</li><li><b class="gd-ui">Airports and delivery</b> &gt; <b class="gd-ui">Delivery rate and origin</b>: the base fee each way ($75), the km it includes from the company&#39;s location (15), the rate per km after them ($2), and the straight line to road distance factor (1.3) used when the maps service gives no road distance. A car whose rate card has its own delivery or pickup fee keeps it; every other car follows the base.</li></ul></section><section class="gd-task" id="settings-automatic-answers-and-email-budgets-release-36" data-gd-task><h2 class="gd-h2">Automatic answers and email budgets (release 36)</h2><ul class="gd-ul"><li>Automatic answers: each channel (text, email, chat, social messages) switches on or off, with the quiet hours, the daily limit per person and how sure the answer must be. The last answers and the questions left for a person show in settings and under renter messages; a question it cannot answer becomes a To do. They stay inside the free daily AI allowance.</li><li>Email budgets: Settings, Usage shows the real daily email capacity of all our sending services together (Cloudflare included), and when a service is not sending, why. Receipts, signed copies and staff messages always go.</li><li>First photo: each listing chooses its first photo, the plain car, a car-show photo with a model, or a flyer with the live price; the flyer is made again when the price changes.</li><li>Rewards: points for a photo with a review and for every rental after the first; every way to earn is on the renter&#39;s Rewards page.</li></ul></section>');
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
select app.guide_release_section('va', 'customer-service', 'chapter', 'your-workday', 'You answer requests with offers, quote callers, reply to renters, look renters up, and review owner forms. You are often the renter''s first person.

Your rail: Queue, Today, Requests, New quote, Renter messages, Find a renter, Calendar, Listings, Similar cars, Owners and enquiries, Owner forms and Scorecard.

## Answer a request

1. Open **Requests and offers**: one queue (the numbers at the top are filters; **Active** always shows everything), the most urgent first, with how long each renter has waited, the countdown to the 2 hours the site promises, the car''s photo, the renter with **Call** and **Text**, the licence and one button (**Send offer**, **Follow up** or **Open**). Filter by Active, New, Asked the renter, Changes asked, Offer out, Not paid or Expired; an expired offer moves to Expired after 48 hours.
2. Waiting shows how long the renter has waited. Open the booking number.

![](/guides/img/va-cs-03-requests-desktop-b3c66d25.jpg "desktop; size: 1440 640; address: carmacars.ca/va/requests; pins: 1 27.1 17.5, 2 52.8 32.8")

3. On the Review tab, check the request: the car is free, the renter, the places.
4. Press **Adjust the booking** to change the car, dates, places, price or extras, then **Save changes**.
5. Add a message and press **Send the offer**. Within your limit you can also use **Approve (within my limit)** or **Approve and send the pay link**.
6. Can''t do it? **Decline** with Reason and any alternative. Need to know more? **Ask the renter**.

![](/guides/img/va-cs-04-booking-review-desktop-52c68a73.jpg "desktop; size: 1440 1000; address: carmacars.ca/va/bookings/CC-10069?tab=review; pins: 3 69.4 24.0, 4 95.8 98.0")

> Tip: Reply within 5 minutes: send the offer, or ask the renter what you need. That is the "First reply in opening hours" measure on your scorecard. Requests waiting longer show in red.

Opening a request takes it for you: the others see "Being answered by" your name and cannot answer it until you send, decline or leave (20 minutes, renewed while you work). One someone else holds shows who, with the buttons off; it opens to you when their claim runs out, or ask an Admin to take it over. Sales: a request from the website shows "Opens to you at" a time for its first 15 minutes, and a To do task says when it opens; after that whoever opens it first answers it, customer service included.

## An enquiry on an example car

Some cars on the site are marked "Example car": samples that show the kind of cars we rent. A request on one is an enquiry, never a booking.

1. The task Suggest a similar real car comes to To do with the enquiry number (EQ-1001 and up), the car asked for, the dates and the contact. When a real car was free for those dates, the task names it after **Free:** (the same make and model first, else the same class and body at a similar price), and the person was told we have a similar car and will confirm it within 2 hours.
2. Check the named car is still right for them (or find a real car of the same kind and price that is free for those dates), and make a **New quote** for it.
3. Call or email the person with the car and the price, then mark the task done.

> Tip: Reply within the first reply target, as for any request. Never offer the example car itself: it does not exist.

## A request from a vehicle page

Every make, model, year and trim page (carmacars.ca/cars/toyota/rav4/2023/xle, for example) has Request it, for the exact car the person wants.

1. The request arrives as an enquiry with the car named in the message ("About the car: 2023 Toyota RAV4 XLE") and an Enquiry task in To do.
2. If we have that car, or one close to it, free for their dates, make a **New quote** for it. If not, suggest the nearest car of the same kind and price.
3. Reply by email or phone, then mark the task done.

> Tip: The pages say only what the data says: EPA fuel use, the Canadian trims and our own cars. Never promise equipment the page does not list.

## A buyer lead from a /buy page

Every vehicle page has a for-sale twin (carmacars.ca/buy/toyota/rav4/2023/xle) with "Find me this car", and twins for financing, detailing and body shop work with their own request: a name, an email or phone, and when.

1. The lead is in **Buyer leads** (customer service: **Owners and enquiries**), Buyer leads (kind buyer, finance, detailing or body shop), with the car and what they asked, and a To do line for Sales: A buyer asked us to find a car, Someone asked about financing or leasing a car, A detailing request, or A body shop request.
2. If one of our cars of that kind is for sale (an Admin flags it with its price), offer it. If not, offer to rent them the car for a week first, and say what we can find. We do not lend or lease: on a financing question, say so and offer the rental. For detailing or body shop work, give a time and a price, and always offer a rental while their car is in (an insurance replacement rental when it is a claim). For mechanical work (a "Mechanical work to arrange" task: an oil change, brakes, tires, a tow and the like), CarmaCars does not do the work: book it with a trusted shop or recommend one, never promise the shop''s price or time, and offer a rental while their car is in.
3. Press **Take it**, then **Update** as you go: contacted, qualified, converted or closed with the reason.

> Tip: We mostly rent cars. Never say a car is for sale unless an Admin flagged it; the page shows it with its price when one is.

## Send an offer to a caller

Open **Send an offer** (or **Send an offer** beside a car in Find a car). No request needed: one screen, and the renter has the link.

1. Find the customer by name, phone or email, or press **Add a new customer**: full legal name, mobile, email and date of birth. Already on file with that email or phone? Use them: never a second record.
2. Choose the car (by car code, plate or name; each says Free or Not free), the dates and the places.
3. The price: the rate sheet, a total or a rate per day, with the reason for a price you type. The deposit, discounts and fees are set by an Admin; customer service sets the Protection Plan price. Amounts I type, at the top of the price: Before tax, or After tax (HST included) to type what the renter pays, worked back to before tax for you. Or type the Total the renter pays (after tax): the rental charge is worked out from it.
4. How the rental and the deposit are paid (card online, e-Transfer, cash, platform payout, the insurer; deposit by card hold, cash or e-Transfer), who found this client, the message, how long it is open (48 hours at most) and Email, Text or both.
5. Check the offer as the renter will see it on the right, then press **Send the offer**.

> Tip: An offer that is out is changed in place: **More actions** > **Edit the offer**, change it, then **Save and send the update** or **Save without telling the renter**. No need to withdraw it first.

## New quote for a caller

1. Open **New quote**. Choose the Car, the Pickup and Return (at least 2 hours from now).
2. Choose how the lead came in, then the caller''s Full legal name, Email, Mobile and Date of birth.
3. Set the Licence class and Damage cover, and note places, extras and what they asked.
4. Press **Create the request**. It opens like any request; send the offer from there.

![](/guides/img/va-cs-05-new-quote-desktop-4e386b1c.jpg "desktop; size: 1220 1260; address: carmacars.ca/va/quotes/new; pins: 1 72.1 15.6, 2 72.1 41.7, 3 72.1 72.7, 4 63.9 85.5")

## Edit a booking, a fee or the renter

A booking that is confirmed, on trip or returned is edited directly; the renter''s details are corrected from the booking.

1. Overview, **Edit the booking**: the return (extend or shorten), the car, the rental charge, each fee, the kilometres and the note. Tick **Email the renter what changed**, or leave it off for a silent correction.
2. Money tab, Fees, **Change or add a fee**: a fee forgotten (the young driver fee shows its price for the dates) or a charge of its own.
3. What is open shows at once: **Email a pay link** or **Text a pay link** for exactly that amount, or record cash or an e-Transfer (Rental charges, Collect (the amount) rental, **Cash, e-Transfer or another way (record it)**).
4. **Edit renter**: a wrong email, phone, name, licence or address. A new email is their sign-in at once.
5. The same renter twice? Under the renter, Possible duplicates: **Merge into this record** moves everything of the other record here.

> Good to know: Each edit is recorded with your name, the time, the reason and the before and after.

## Renter messages and Find a renter

1. **Renter messages** lists the latest messages with their booking. Open the booking to reply, then press **Send**.
2. **Find a renter**: search by name, email, phone or booking number.
3. To open a renter''s private details, press **Open with a reason**. The reason is kept in the access log.

![](/guides/img/va-cs-06-messages-desktop-3441fa91.jpg "desktop; size: 1440 260; address: carmacars.ca/va/messages; pins: 1 32.6 48.5")

## Add a car for an owner

Open **Owners** > **Add a car for an owner** (fleet: under Cars). You enter everything for the owner; they never fill in the application.

1. The owner: find them by name, email or phone, or choose New owner and enter the name, email, phone and address.
2. The car: type the VIN. The car is looked up at once and shown in one line with the year, make, model, trim and details (Edit if something is wrong). No VIN at hand: add it by its plate and choose the year, make and model. Tap the colour and check the class. Upload the ownership permit, the insurance slip and the lender''s information if you have them. Photos are optional.
3. Terms and first invoice: what was agreed with the owner, to the cent. An Admin checks them before anything is sent.
4. Who sourced the owner: Entered for CarmaCars, or I sourced this owner. The owner signs in the owner portal after one email (no paper signature).
5. Press **Add the car and send to an Admin**. The application waits in the Admin''s Applications, marked Entered by staff with your name. When the Admin approves, the owner gets one email to review and sign.

> Good to know: A fleet supplier (a corporation leasing its cars to CarmaCars): choose New owner, **A corporation**, then Route **Fleet supplier: leases the cars to CarmaCars**. The default lease terms are set at once. For the car, enter the VIN, the plate and the ownership copy, choose its tier, **Regular** or **Troubled** (it is set once), and who it is registered to now (for a car moving in or bought, the name and address on the ownership and the date). Its ServiceOntario forms are filled in at once. No terms, no invoices and no paper signing: the supplier signs in the owner portal. The car goes on the lease when an Admin approves it.

## Owners: the checklist, the photos and the forms (release 34)

Open **Owners** (customer service and fleet), then an owner. Search finds any owner by name, email, plate or VIN.

1. The **Onboarding checklist**: per car, each step done, to do (and who it waits on), blocked (and why) or not needed, with the one button to press.
2. **Onboarding photos**: **Replace** or **Remove** (with a reason) a wrong ownership permit, insurance slip or lender''s letter, or **Approve** or mark it **Not accepted** (the owner reads why). A replaced photo is checked again.
3. **Government forms**: each ServiceOntario form the car needs, made by themselves, with its status, the date it was made and its download.
4. **Add cars from a list of VINs** for the owner: paste or upload, **Preview**, **Add**.

## Owner forms (Forms C and D)

1. Open **Owner forms**. Each row is a scan an owner uploaded before November 2026 (Forms C and D are signed on screen since then), with the witnesses and the status.
2. Press Open to read the scan. Check every page is there and signed, with each witness''s signature and name.
3. Press **Approve**, or **Send back** with What to fix (the owner reads this).

![](/guides/img/va-cs-08-owner-forms-desktop-eceaee0b.jpg "desktop; size: 1440 300; address: carmacars.ca/va/owner-forms; pins: 2 68.6 36.7, 3 76.7 36.7")

## Rental agreements are signed online only

A rental agreement, or a booking change, is signed by the renter in their portal or on the phone at the handover (the e-signature). A copy signed on paper is not accepted or recorded: send the renter the link again from the booking. One recorded before November 2026 stays readable under Signed on paper.

## Signatures on the spot, or by link

A renter or an additional driver who has not signed yet.

1. On the booking, press **Sign now on this device**. Confirm the name and that you saw the original licence, then **Hand the device to** the signer.
2. Or press **Email the signing link** or **Text the signing link**: they sign on their own phone.
3. The licence comes first: the renter uploads it from the request, and the offer cannot be accepted without it.

## The booking''s rental agreements

The Rental agreements card keeps both agreements in step with the booking.

1. Any change after signing makes a new version by itself. A change to the dates, the price, the car, the drivers or the coverage waits for the renter''s signature: they get the link by email and text, and the card says "Agreement v3 waiting for signature".
2. **Resend the signing links**, or press the button with their first name beside it to have them sign on your device.
3. Fields still blank (a licence expiry, an insurer''s policy number) are listed: type them and press **Save the missing fields**. Check-in stops on a field a claim needs until it is filled or an Admin overrides.
4. Every signature: a code to the signer''s phone or email, the key terms initialled, three consents, a drawn signature.

## Check renter documents

The renter''s licence photos, selfie and proof of coverage, before the handover.

1. Open the task "identity documents or coverage proof to review", or open the booking: **Review** shows the documents of any booking being arranged or under way, with no task needed.
2. Every licence image, selfie and proof of coverage of the booking is on one screen, with what to check written once above them: the selfie matches, no alteration, the coverage is active to the return date.
3. Under each driver, the licence reader lists what it read (from the back''s barcode, else the photo) and one line per check, Pass or Flag: photos sharp and whole, valid to the return, class accepted, old enough at pickup, name and date of birth match the driver, the Ontario number, front and back the same licence, and the main driver''s Ontario licence. Look closely at each Flag.
4. One is wrong? Open **Reject this one** under it, type the reason the renter reads and press **Reject**.
5. Then press **Approve all**: everything still waiting is approved at once (the Protection Plan too). A document the system refuses is named with the reason; the rest are approved.

> Tip: Each opening is logged. An Admin can do the same from Admin > To do. Field staff review the licence images (not the coverage) of bookings on their own jobs in the next 7 days from their My jobs: the booking history says the role, field.

> Good to know: Main driver: Ontario licence needed. When the main driver''s licence is from elsewhere, they are moved to additional driver (their photos and checks stay; you still review them) and pickup is blocked until a driver with an Ontario licence is the main driver. The renter adds one from their booking. Only an Admin can undo the swap or let it go with a reason.

## Which credit cards include rental car coverage?

Renters ask this often. **Renters** > **Card coverage** (every function has it under Rentals or Bookings) is your quick reference: what to say, what to check, and the list.

1. Send the renter `carmacars.ca/credit-card-rental-coverage`: each card''s car value limit (MSRP), longest rental, key exclusions, its official guide and the day we last checked it.
2. Ask which car they want. Most Canadian cards stop at a car priced $65,000 or $85,000, and many luxury models are priced higher. Give them the car''s model year and trim so they can check.
3. Never tell a renter they are covered. Their card''s issuer decides that: ask them to call the number on the back of their card about this car and these dates. CarmaCars does not decide claims.
4. Over the limit, an excluded make, a debit card or a longer rental than the card allows: offer OPCF 27 on their own auto policy or the CarmaCars Protection Plan.

> Tip: A card marked Unverified came from a published summary, not the issuer''s guide. Something wrong or out of date in the list? Tell an Admin: they correct it in Settings > Card coverage.

## Review requests

Renters are asked for a review by email and text after each trip. **Renters** > **Review requests** shows the ones on hold and the Google reviews to match.

1. On hold: the booking has a charge that is not settled or waived yet (late return, kilometres, fuel, cleaning, smoking, damage, tolls) or an open incident. It leaves the list by itself once the charges are settled or waived.
2. The renter should be asked now anyway? Press **Send anyway**. Should never be asked? Press **Do not ask**.
3. Google reviews: a possible match to a renter shows "possible match". Press **Confirm** if it is them, **Not this renter** if not, or **Match to a booking** with the booking number.
4. A review that came another way (Turo, a text, a call, email): press **Add a customer review** and type the customer''s first name and last initial, the source, the date received, the rating and their words exactly as received, with a screenshot if you have one. It shows on the site with its source. Never write or change a review for a customer.
5. On a booking, the card Review requests has **Ask for a review** (for example after a call that went well) and **Mark reviewed** when the renter says they already left one.

> Tip: Never offer anything for a review and never ask only happy renters: everyone gets the same message and the same Google link.

## A change to a confirmed booking

On a booking''s Changes tab you can propose new dates, times or another car, as an Admin does: set the change, write the reason, press **Preview the price**, then **Send to the renter**. The renter has 48 hours to accept and sign the amendment. You also send a new signing link to an additional driver from the booking screen.

## A late return

A booking past its return time shows the late return panel. The renter can still extend in their booking while they have the car: the extension counts from the original return time, it is approved at once when the car is free, and paying it stops the late notices. Point them to **Extend** first. Otherwise work it in order:

| Button | When |
| --- | --- |
| **Log a call** | Record each call to the renter and what they said. |
| **Send T13** | The first late notice email. |
| **Send T14 (final notice)** | The final notice. |
| **Request disable** | Ask an Admin to approve disabling the car. |
| **Open an incident** | When the car is not coming back as planned. |

## Booked when the renter accepts (release 28)

A renter who approves the offer has booked the car, even before paying: the booking shows **Booked, payment due** and holds the car everywhere. Collect the payment before the pickup (a **Booked, payment due** To do comes 48 hours before). When you send an offer, the renter''s view is right under **Send the offer**.

## When a check stops the pickup or the return (release 33)
On the booking page, **What stops the pickup now** (or the return) lists each check that stops it, in plain words. When the trip must go ahead anyway, press **Ask an Admin to override the pickup** (or the return), give the actual time, the km and fuel if you know them, and why. An Admin gets an alert and approves in one tap; the pickup (or the return) is then recorded with the time you entered, and the booking''s history says who asked and who approved. You can cancel your request while it waits. A trip that happened and was never recorded: **Ask to record a past trip** with both times; once an Admin approves, the booking lands in Returned so the deposit can be settled.

## Book it now (release 33)
When you send an offer, tick **Book it now (no renter approval)** when the renter has already agreed. The offer goes out and an Admin approves it in one tap: the booking then waits for payment, the car is held, and the renter gets one link to sign and pay. You can also have them sign and pay with you: open the booking, **Sign now on this device**, then take the card on this device.
Already sent the offer? Ask the assistant: "Book the offer of CC-10482 now, the customer agreed by phone". It shows a card; **Confirm** sends the same request to an Admin, who approves in one tap.

## Switch a booking between card coverage and the Protection Plan (release 35)

When a renter''s card does not cover the car, or they want the plan instead, switch the booking yourself. On the booking page, open the **Coverage** card.

1. Press **Switch to the Protection Plan**. You see the plan''s price with HST and the new total before you confirm.
2. Write the reason (the renter reads it). On a confirmed booking or a rental in progress you can type the plan''s price for this booking, for example for the days left.
3. Press the button. An offer is sent again with the new price. A confirmed booking gets the plan line and the extra is open to collect on the Money tab: Collect sends the pay link. The renter is emailed what changed.

The card coverage proof and its review task are cleared for you. **Switch to card coverage** puts them back, or gives you a task to get the proof from the renter. Sales switches requests and offers only.

## Unanswered

**More customer service** > **Unanswered**: every customer text with no reply and every missed call not called back, oldest first. Reply or call back from the row; **Mark answered** when it was answered another way. After 15 minutes the team is alerted. Check WhatsApp by hand each morning.

## The request as sent and every offer (release 35)

On a request or a booking, **Original request, as the renter sent it** shows the car, dates, places, coverage, add-ons, note and the price the renter saw, exactly as sent; staff changes never touch it. **Offer history** lists every offer version, newest first: its status, who sent it and when, the car and dates, the message, how the total moved, and the price breakdown.

1. To go back to an old version, press **Revert to this offer** on it. Its car, dates, price, deposit, discount and fees load into the review as a new offer, highlighted.
2. Check the price, then send it in step 3. Nothing changes until you send.

The **Coverage** line at the top says what the renter chose (own insurance OPCF 27, credit card, Protection Plan) and its proof: not sent yet, waiting for review, confirmed, or rejected with the reason.

## Send an offer in three steps (release 35)

1. **Car and dates**: the renter, the dates, the car and where they pick it up and return it.
2. **Price**: filled in from the rate sheet with the checkout''s fees and discounts. Change it only if you agreed another price.
3. **Review and send**: what changed, the message and how the link goes.

Rarely used options (billing an insurer, how it is paid, the calendar) are under **More options**. Send waits while the price is being worked out again after a date change, and one tap sends once.

## The owner''s own trip, instant bookings and Book it now (release 35)

- **Owner''s own trip ($0)**: the owner booked their own car. There is nothing to price or send; get the car ready.
- **Instant (repeat renter)**: a renter with a completed rental, a verified licence and nothing owing booked an available car at once and went straight to sign and pay. An Admin can take a renter''s instant booking away from the booking page.
- **Book it now** pressed by staff waits for an Admin''s one-tap approval.

## Secondary contact and rideshare documents (release 35)

The booking shows the renter''s **Secondary contact** when they gave one: call them when the renter cannot be reached. Rideshare and delivery driving are welcome (rental agreement, section 10.3): never tell a renter it is not allowed. When a renter makes **rideshare documents** (Uber, Lyft, DoorDash and others), you get an alert and the booking shows the letters they made.

## Automatic answers (release 36)

Common questions by text, email, WhatsApp, Facebook and Instagram are answered by themselves from the FAQ. **Renter messages** > **Automatic answers** shows what was answered and what was left for a person. A question the FAQ does not answer stays for you: texts in Messages, emails and Meta messages as a To do, **Answer** and the question. Once you text someone, no automatic answer goes to them for 2 hours.

## The card the renter picked, and the two OPCF 27 pages (release 35)

On **Review documents** for a booking:

1. **Option 2**: **Card picked** names the card the renter chose from the list (or typed when it was not listed), and **Card check** says whether it covers this car: *Covers this car*, *Check it* (a card not on the list, a card whose coverage or value limit we do not know, or a car with no value on file) or *Does NOT cover this car* with the reason. **Approve** is refused while the card does not cover the car.
2. **Option 1**: each page says what it is: **pink slip** or **OPCF 27 endorsement**. **Approve** is refused until both are in. **Reject** needs the reason the renter sees.
3. A renter on OPCF 27 cannot pay until both pages are uploaded, so you see them before the booking is confirmed.

> Tip: Uploading a renter''s insurance yourself? In **Upload a document**, choose **Which page**: Pink slip or OPCF 27 endorsement page.

## Calls, auto-replies and coverage (releases 35 and 36)

- Calls from the Call button are recorded; the transcript, summary and Play recording are on the renter''s, lead''s and booking''s history. Quo calls show their transcript and summary there too.
- Automatic answers reply to common questions on every channel from our FAQ. A question they cannot answer becomes your To do: answer it yourself.
- Card coverage: the renter picks their card and the page checks it against the car. Approve OPCF 27 only with both the pink slip and the endorsement page.
- Rideshare and delivery work is allowed with the documents the renter makes on their booking; the secondary contact is on the booking.
- The mid-trip message asks the renter how the trip is going; a problem reported becomes your To do.', 'Customer service', 'Requests and offers, new quotes, renter messages, find a renter, owner forms, late returns.',
  'You answer requests with offers, quote callers, reply to renters, look renters up, and review owner forms. You are often the renter''s first person. There is no commission for customer service, but your help is credited on the booking (Helped by) and on your scorecard.

Your rail: Queue, Today, Requests, New quote, Renter messages, Find a renter, Calendar, Listings, Similar cars, Owners and enquiries, Owner forms and Scorecard.

## Answer a request

1. Open **Requests and offers**: one queue (the numbers at the top are filters; **Active** always shows everything), the most urgent first, with how long each renter has waited, the countdown to the 2 hours the site promises, the car''s photo, the renter with **Call** and **Text**, the licence and one button (**Send offer**, **Follow up** or **Open**). Filter by Active, New, Asked the renter, Changes asked, Offer out, Not paid or Expired; an expired offer moves to Expired after 48 hours.
2. Waiting shows how long the renter has waited. Open the booking number.

![](/guides/img/va-cs-03-requests-desktop-b3c66d25.jpg "desktop; size: 1440 640; address: carmacars.ca/va/requests; pins: 1 27.1 17.5, 2 52.8 32.8")

3. On the Review tab, check the request: the car is free, the renter, the places.
4. Press **Adjust the booking** to change the car, dates, places, price or extras, then **Save changes**.
5. Add a message and press **Send the offer**. Within your limit you can also use **Approve (within my limit)** or **Approve and send the pay link**.
6. Can''t do it? **Decline** with Reason and any alternative. Need to know more? **Ask the renter**.

![](/guides/img/va-cs-04-booking-review-desktop-52c68a73.jpg "desktop; size: 1440 1000; address: carmacars.ca/va/bookings/CC-10069?tab=review; pins: 3 69.4 24.0, 4 95.8 98.0")

> Tip: Reply within 5 minutes: send the offer, or ask the renter what you need. That is the "First reply in opening hours" measure on your scorecard. Requests waiting longer show in red.

Opening a request takes it for you: the others see "Being answered by" your name and cannot answer it until you send, decline or leave (20 minutes, renewed while you work). One someone else holds shows who, with the buttons off; it opens to you when their claim runs out, or ask an Admin to take it over. Sales: a request from the website shows "Opens to you at" a time for its first 15 minutes, and a To do task says when it opens; after that whoever opens it first answers it, customer service included.

## An enquiry on an example car

Some cars on the site are marked "Example car": samples that show the kind of cars we rent. A request on one is an enquiry, never a booking.

1. The task Suggest a similar real car comes to To do with the enquiry number (EQ-1001 and up), the car asked for, the dates and the contact. When a real car was free for those dates, the task names it after **Free:** (the same make and model first, else the same class and body at a similar price), and the person was told we have a similar car and will confirm it within 2 hours.
2. Check the named car is still right for them (or find a real car of the same kind and price that is free for those dates), and make a **New quote** for it.
3. Call or email the person with the car and the price, then mark the task done.

> Tip: Reply within the first reply target, as for any request. Never offer the example car itself: it does not exist.

## A request from a vehicle page

Every make, model, year and trim page (carmacars.ca/cars/toyota/rav4/2023/xle, for example) has Request it, for the exact car the person wants.

1. The request arrives as an enquiry with the car named in the message ("About the car: 2023 Toyota RAV4 XLE") and an Enquiry task in To do.
2. If we have that car, or one close to it, free for their dates, make a **New quote** for it. If not, suggest the nearest car of the same kind and price.
3. Reply by email or phone, then mark the task done.

> Tip: The pages say only what the data says: EPA fuel use, the Canadian trims and our own cars. Never promise equipment the page does not list.

## A buyer lead from a /buy page

Every vehicle page has a for-sale twin (carmacars.ca/buy/toyota/rav4/2023/xle) with "Find me this car", and twins for financing, detailing and body shop work with their own request: a name, an email or phone, and when.

1. The lead is in **Buyer leads** (customer service: **Owners and enquiries**), Buyer leads (kind buyer, finance, detailing or body shop), with the car and what they asked, and a To do line for Sales: A buyer asked us to find a car, Someone asked about financing or leasing a car, A detailing request, or A body shop request.
2. If one of our cars of that kind is for sale (an Admin flags it with its price), offer it. If not, offer to rent them the car for a week first, and say what we can find. We do not lend or lease: on a financing question, say so and offer the rental. For detailing or body shop work, give a time and a price, and always offer a rental while their car is in (an insurance replacement rental when it is a claim). For mechanical work (a "Mechanical work to arrange" task: an oil change, brakes, tires, a tow and the like), CarmaCars does not do the work: book it with a trusted shop or recommend one, never promise the shop''s price or time, and offer a rental while their car is in.
3. Press **Take it**, then **Update** as you go: contacted, qualified, converted or closed with the reason.

> Tip: We mostly rent cars. Never say a car is for sale unless an Admin flagged it; the page shows it with its price when one is.

## Send an offer to a caller

Open **Send an offer** (or **Send an offer** beside a car in Find a car). No request needed: one screen, and the renter has the link.

1. Find the customer by name, phone or email, or press **Add a new customer**: full legal name, mobile, email and date of birth. Already on file with that email or phone? Use them: never a second record.
2. Choose the car (by car code, plate or name; each says Free or Not free), the dates and the places.
3. The price: the rate sheet, a total or a rate per day, with the reason for a price you type. The deposit, discounts and fees are set by an Admin; customer service sets the Protection Plan price. Amounts I type, at the top of the price: Before tax, or After tax (HST included) to type what the renter pays, worked back to before tax for you. Or type the Total the renter pays (after tax): the rental charge is worked out from it.
4. How the rental and the deposit are paid (card online, e-Transfer, cash, platform payout, the insurer; deposit by card hold, cash or e-Transfer), who found this client, the message, how long it is open (48 hours at most) and Email, Text or both.
5. Check the offer as the renter will see it on the right, then press **Send the offer**.

> Tip: An offer that is out is changed in place: **More actions** > **Edit the offer**, change it, then **Save and send the update** or **Save without telling the renter**. No need to withdraw it first.

## New quote for a caller

1. Open **New quote**. Choose the Car, the Pickup and Return (at least 2 hours from now).
2. Choose how the lead came in, then the caller''s Full legal name, Email, Mobile and Date of birth.
3. Set the Licence class and Damage cover, and note places, extras and what they asked.
4. Press **Create the request**. It opens like any request; send the offer from there.

![](/guides/img/va-cs-05-new-quote-desktop-4e386b1c.jpg "desktop; size: 1220 1260; address: carmacars.ca/va/quotes/new; pins: 1 72.1 15.6, 2 72.1 41.7, 3 72.1 72.7, 4 63.9 85.5")

## Edit a booking, a fee or the renter

A booking that is confirmed, on trip or returned is edited directly; the renter''s details are corrected from the booking.

1. Overview, **Edit the booking**: the return (extend or shorten), the car, the rental charge, each fee, the kilometres and the note. Tick **Email the renter what changed**, or leave it off for a silent correction.
2. Money tab, Fees, **Change or add a fee**: a fee forgotten (the young driver fee shows its price for the dates) or a charge of its own.
3. What is open shows at once: **Email a pay link** or **Text a pay link** for exactly that amount, or record cash or an e-Transfer (Rental charges, Collect (the amount) rental, **Cash, e-Transfer or another way (record it)**).
4. **Edit renter**: a wrong email, phone, name, licence or address. A new email is their sign-in at once.
5. The same renter twice? Under the renter, Possible duplicates: **Merge into this record** moves everything of the other record here.

> Good to know: Each edit is recorded with your name, the time, the reason and the before and after.

## Renter messages and Find a renter

1. **Renter messages** lists the latest messages with their booking. Open the booking to reply, then press **Send**.
2. **Find a renter**: search by name, email, phone or booking number.
3. To open a renter''s private details, press **Open with a reason**. The reason is kept in the access log.

![](/guides/img/va-cs-06-messages-desktop-3441fa91.jpg "desktop; size: 1440 260; address: carmacars.ca/va/messages; pins: 1 32.6 48.5")

## Add a car for an owner

Open **Owners** > **Add a car for an owner** (fleet: under Cars). You enter everything for the owner; they never fill in the application.

1. The owner: find them by name, email or phone, or choose New owner and enter the name, email, phone and address.
2. The car: type the VIN. The car is looked up at once and shown in one line with the year, make, model, trim and details (Edit if something is wrong). No VIN at hand: add it by its plate and choose the year, make and model. Tap the colour and check the class. Upload the ownership permit, the insurance slip and the lender''s information if you have them. Photos are optional.
3. Terms and first invoice: what was agreed with the owner, to the cent. An Admin checks them before anything is sent.
4. Who sourced the owner: Entered for CarmaCars, or I sourced this owner. The owner signs in the owner portal after one email (no paper signature).
5. Press **Add the car and send to an Admin**. The application waits in the Admin''s Applications, marked Entered by staff with your name. When the Admin approves, the owner gets one email to review and sign.

> Good to know: A fleet supplier (a corporation leasing its cars to CarmaCars): choose New owner, **A corporation**, then Route **Fleet supplier: leases the cars to CarmaCars**. The default lease terms are set at once. For the car, enter the VIN, the plate and the ownership copy, choose its tier, **Regular** or **Troubled** (it is set once), and who it is registered to now (for a car moving in or bought, the name and address on the ownership and the date). Its ServiceOntario forms are filled in at once. No terms, no invoices and no paper signing: the supplier signs in the owner portal. The car goes on the lease when an Admin approves it.

## Owners: the checklist, the photos and the forms (release 34)

Open **Owners** (customer service and fleet), then an owner. Search finds any owner by name, email, plate or VIN.

1. The **Onboarding checklist**: per car, each step done, to do (and who it waits on), blocked (and why) or not needed, with the one button to press.
2. **Onboarding photos**: **Replace** or **Remove** (with a reason) a wrong ownership permit, insurance slip or lender''s letter, or **Approve** or mark it **Not accepted** (the owner reads why). A replaced photo is checked again.
3. **Government forms**: each ServiceOntario form the car needs, made by themselves, with its status, the date it was made and its download.
4. **Add cars from a list of VINs** for the owner: paste or upload, **Preview**, **Add**.

## Owner forms (Forms C and D)

1. Open **Owner forms**. Each row is a scan an owner uploaded before November 2026 (Forms C and D are signed on screen since then), with the witnesses and the status.
2. Press Open to read the scan. Check every page is there and signed, with each witness''s signature and name.
3. Press **Approve**, or **Send back** with What to fix (the owner reads this).

![](/guides/img/va-cs-08-owner-forms-desktop-eceaee0b.jpg "desktop; size: 1440 300; address: carmacars.ca/va/owner-forms; pins: 2 68.6 36.7, 3 76.7 36.7")

## Rental agreements are signed online only

A rental agreement, or a booking change, is signed by the renter in their portal or on the phone at the handover (the e-signature). A copy signed on paper is not accepted or recorded: send the renter the link again from the booking. One recorded before November 2026 stays readable under Signed on paper.

## Signatures on the spot, or by link

A renter or an additional driver who has not signed yet.

1. On the booking, press **Sign now on this device**. Confirm the name and that you saw the original licence, then **Hand the device to** the signer.
2. Or press **Email the signing link** or **Text the signing link**: they sign on their own phone.
3. The licence comes first: the renter uploads it from the request, and the offer cannot be accepted without it.

## The booking''s rental agreements

The Rental agreements card keeps both agreements in step with the booking.

1. Any change after signing makes a new version by itself. A change to the dates, the price, the car, the drivers or the coverage waits for the renter''s signature: they get the link by email and text, and the card says "Agreement v3 waiting for signature".
2. **Resend the signing links**, or press the button with their first name beside it to have them sign on your device.
3. Fields still blank (a licence expiry, an insurer''s policy number) are listed: type them and press **Save the missing fields**. Check-in stops on a field a claim needs until it is filled or an Admin overrides.
4. Every signature: a code to the signer''s phone or email, the key terms initialled, three consents, a drawn signature.

## Check renter documents

The renter''s licence photos, selfie and proof of coverage, before the handover.

1. Open the task "identity documents or coverage proof to review", or open the booking: **Review** shows the documents of any booking being arranged or under way, with no task needed.
2. Every licence image, selfie and proof of coverage of the booking is on one screen, with what to check written once above them: the selfie matches, no alteration, the coverage is active to the return date.
3. Under each driver, the licence reader lists what it read (from the back''s barcode, else the photo) and one line per check, Pass or Flag: photos sharp and whole, valid to the return, class accepted, old enough at pickup, name and date of birth match the driver, the Ontario number, front and back the same licence, and the main driver''s Ontario licence. Look closely at each Flag.
4. One is wrong? Open **Reject this one** under it, type the reason the renter reads and press **Reject**.
5. Then press **Approve all**: everything still waiting is approved at once (the Protection Plan too). A document the system refuses is named with the reason; the rest are approved.

> Tip: Each opening is logged. An Admin can do the same from Admin > To do. Field staff review the licence images (not the coverage) of bookings on their own jobs in the next 7 days from their My jobs: the booking history says the role, field.

> Good to know: Main driver: Ontario licence needed. When the main driver''s licence is from elsewhere, they are moved to additional driver (their photos and checks stay; you still review them) and pickup is blocked until a driver with an Ontario licence is the main driver. The renter adds one from their booking. Only an Admin can undo the swap or let it go with a reason.

## Which credit cards include rental car coverage?

Renters ask this often. **Renters** > **Card coverage** (every function has it under Rentals or Bookings) is your quick reference: what to say, what to check, and the list.

1. Send the renter `carmacars.ca/credit-card-rental-coverage`: each card''s car value limit (MSRP), longest rental, key exclusions, its official guide and the day we last checked it.
2. Ask which car they want. Most Canadian cards stop at a car priced $65,000 or $85,000, and many luxury models are priced higher. Give them the car''s model year and trim so they can check.
3. Never tell a renter they are covered. Their card''s issuer decides that: ask them to call the number on the back of their card about this car and these dates. CarmaCars does not decide claims.
4. Over the limit, an excluded make, a debit card or a longer rental than the card allows: offer OPCF 27 on their own auto policy or the CarmaCars Protection Plan.

> Tip: A card marked Unverified came from a published summary, not the issuer''s guide. Something wrong or out of date in the list? Tell an Admin: they correct it in Settings > Card coverage.

## Review requests

Renters are asked for a review by email and text after each trip. **Renters** > **Review requests** shows the ones on hold and the Google reviews to match.

1. On hold: the booking has a charge that is not settled or waived yet (late return, kilometres, fuel, cleaning, smoking, damage, tolls) or an open incident. It leaves the list by itself once the charges are settled or waived.
2. The renter should be asked now anyway? Press **Send anyway**. Should never be asked? Press **Do not ask**.
3. Google reviews: a possible match to a renter shows "possible match". Press **Confirm** if it is them, **Not this renter** if not, or **Match to a booking** with the booking number.
4. A review that came another way (Turo, a text, a call, email): press **Add a customer review** and type the customer''s first name and last initial, the source, the date received, the rating and their words exactly as received, with a screenshot if you have one. It shows on the site with its source. Never write or change a review for a customer.
5. On a booking, the card Review requests has **Ask for a review** (for example after a call that went well) and **Mark reviewed** when the renter says they already left one.

> Tip: Never offer anything for a review and never ask only happy renters: everyone gets the same message and the same Google link.

## A change to a confirmed booking

On a booking''s Changes tab you can propose new dates, times or another car, as an Admin does: set the change, write the reason, press **Preview the price**, then **Send to the renter**. The renter has 48 hours to accept and sign the amendment. You also send a new signing link to an additional driver from the booking screen.

## A late return

A booking past its return time shows the late return panel. The renter can still extend in their booking while they have the car: the extension counts from the original return time, it is approved at once when the car is free, and paying it stops the late notices. Point them to **Extend** first. Otherwise work it in order:

| Button | When |
| --- | --- |
| **Log a call** | Record each call to the renter and what they said. |
| **Send T13** | The first late notice email. |
| **Send T14 (final notice)** | The final notice. |
| **Request disable** | Ask an Admin to approve disabling the car. |
| **Open an incident** | When the car is not coming back as planned. |

## Booked when the renter accepts (release 28)

A renter who approves the offer has booked the car, even before paying: the booking shows **Booked, payment due** and holds the car everywhere. Collect the payment before the pickup (a **Booked, payment due** To do comes 48 hours before). When you send an offer, the renter''s view is right under **Send the offer**.

## When a check stops the pickup or the return (release 33)
On the booking page, **What stops the pickup now** (or the return) lists each check that stops it, in plain words. When the trip must go ahead anyway, press **Ask an Admin to override the pickup** (or the return), give the actual time, the km and fuel if you know them, and why. An Admin gets an alert and approves in one tap; the pickup (or the return) is then recorded with the time you entered, and the booking''s history says who asked and who approved. You can cancel your request while it waits. A trip that happened and was never recorded: **Ask to record a past trip** with both times; once an Admin approves, the booking lands in Returned so the deposit can be settled.

## Book it now (release 33)
When you send an offer, tick **Book it now (no renter approval)** when the renter has already agreed. The offer goes out and an Admin approves it in one tap: the booking then waits for payment, the car is held, and the renter gets one link to sign and pay. You can also have them sign and pay with you: open the booking, **Sign now on this device**, then take the card on this device.
Already sent the offer? Ask the assistant: "Book the offer of CC-10482 now, the customer agreed by phone". It shows a card; **Confirm** sends the same request to an Admin, who approves in one tap.

## Switch a booking between card coverage and the Protection Plan (release 35)

When a renter''s card does not cover the car, or they want the plan instead, switch the booking yourself. On the booking page, open the **Coverage** card.

1. Press **Switch to the Protection Plan**. You see the plan''s price with HST and the new total before you confirm.
2. Write the reason (the renter reads it). On a confirmed booking or a rental in progress you can type the plan''s price for this booking, for example for the days left.
3. Press the button. An offer is sent again with the new price. A confirmed booking gets the plan line and the extra is open to collect on the Money tab: Collect sends the pay link. The renter is emailed what changed.

The card coverage proof and its review task are cleared for you. **Switch to card coverage** puts them back, or gives you a task to get the proof from the renter. Sales switches requests and offers only.

## Unanswered

**More customer service** > **Unanswered**: every customer text with no reply and every missed call not called back, oldest first. Reply or call back from the row; **Mark answered** when it was answered another way. After 15 minutes the team is alerted. Check WhatsApp by hand each morning.

## The request as sent and every offer (release 35)

On a request or a booking, **Original request, as the renter sent it** shows the car, dates, places, coverage, add-ons, note and the price the renter saw, exactly as sent; staff changes never touch it. **Offer history** lists every offer version, newest first: its status, who sent it and when, the car and dates, the message, how the total moved, and the price breakdown.

1. To go back to an old version, press **Revert to this offer** on it. Its car, dates, price, deposit, discount and fees load into the review as a new offer, highlighted.
2. Check the price, then send it in step 3. Nothing changes until you send.

The **Coverage** line at the top says what the renter chose (own insurance OPCF 27, credit card, Protection Plan) and its proof: not sent yet, waiting for review, confirmed, or rejected with the reason.

## Send an offer in three steps (release 35)

1. **Car and dates**: the renter, the dates, the car and where they pick it up and return it.
2. **Price**: filled in from the rate sheet with the checkout''s fees and discounts. Change it only if you agreed another price.
3. **Review and send**: what changed, the message and how the link goes.

Rarely used options (billing an insurer, how it is paid, the calendar) are under **More options**. Send waits while the price is being worked out again after a date change, and one tap sends once.

## The owner''s own trip, instant bookings and Book it now (release 35)

- **Owner''s own trip ($0)**: the owner booked their own car. There is nothing to price or send; get the car ready.
- **Instant (repeat renter)**: a renter with a completed rental, a verified licence and nothing owing booked an available car at once and went straight to sign and pay. An Admin can take a renter''s instant booking away from the booking page.
- **Book it now** pressed by staff waits for an Admin''s one-tap approval.

## Secondary contact and rideshare documents (release 35)

The booking shows the renter''s **Secondary contact** when they gave one: call them when the renter cannot be reached. Rideshare and delivery driving are welcome (rental agreement, section 10.3): never tell a renter it is not allowed. When a renter makes **rideshare documents** (Uber, Lyft, DoorDash and others), you get an alert and the booking shows the letters they made.

## Automatic answers (release 36)

Common questions by text, email, WhatsApp, Facebook and Instagram are answered by themselves from the FAQ. **Renter messages** > **Automatic answers** shows what was answered and what was left for a person. A question the FAQ does not answer stays for you: texts in Messages, emails and Meta messages as a To do, **Answer** and the question. Once you text someone, no automatic answer goes to them for 2 hours.

## The card the renter picked, and the two OPCF 27 pages (release 35)

On **Review documents** for a booking:

1. **Option 2**: **Card picked** names the card the renter chose from the list (or typed when it was not listed), and **Card check** says whether it covers this car: *Covers this car*, *Check it* (a card not on the list, a card whose coverage or value limit we do not know, or a car with no value on file) or *Does NOT cover this car* with the reason. **Approve** is refused while the card does not cover the car.
2. **Option 1**: each page says what it is: **pink slip** or **OPCF 27 endorsement**. **Approve** is refused until both are in. **Reject** needs the reason the renter sees.
3. A renter on OPCF 27 cannot pay until both pages are uploaded, so you see them before the booking is confirmed.

> Tip: Uploading a renter''s insurance yourself? In **Upload a document**, choose **Which page**: Pink slip or OPCF 27 endorsement page.

## Calls, auto-replies and coverage (releases 35 and 36)

- Calls from the Call button are recorded; the transcript, summary and Play recording are on the renter''s, lead''s and booking''s history. Quo calls show their transcript and summary there too.
- Automatic answers reply to common questions on every channel from our FAQ. A question they cannot answer becomes your To do: answer it yourself.
- Card coverage: the renter picks their card and the page checks it against the car. Approve OPCF 27 only with both the pink slip and the endorsement page.
- Rideshare and delivery work is allowed with the documents the renter makes on their booking; the secondary contact is on the booking.
- The mid-trip message asks the renter how the trip is going; a problem reported becomes your To do.

## Calls first, texts after (release 37)

Your main priority is always to be on the phone with people.

1. Answer a ringing call before anything else, and return a missed call at once.
2. **Call before you text.** On a lead, a renter or a booking, **Call** is the first button and **Text** the second.
3. A text is a follow-up: after a call attempt (no answer, a voicemail left), or when the person asked for a text.
4. On your To do and on **Unanswered**, missed calls and call-backs are listed above unanswered texts.

## A lead you handle on a call (release 37)

When you answer or place a call with a lead, add a note on it, or create it from a call, the lead is yours for a limited time (15 minutes, as a Sales claim; an Admin can change it in **Settings** > **Sales**). Every call you handle adds the time again.

- Sales see **Being handled by** your first name and your function with the time, on the lead and in every list. They cannot claim it, call, text or email it, or set an outcome meanwhile, and **Next lead** skips it.
- Another customer service or Fleet person can still work it; their call or note takes the hold over.
- When it ends, the lead goes back to the salesperson who had a claim on it or who brought it, else to the open list. An Admin can **Release hold** earlier.
- A booking made from the lead is credited as always: customer service and Fleet get no sales commission for it.
- Nobody who has not finished onboarding holds a lead.',
  '<p class="gd-p">You answer requests with offers, quote callers, reply to renters, look renters up, and review owner forms. You are often the renter&#39;s first person. There is no commission for customer service, but your help is credited on the booking (Helped by) and on your scorecard.</p><p class="gd-p">Your rail: Queue, Today, Requests, New quote, Renter messages, Find a renter, Calendar, Listings, Similar cars, Owners and enquiries, Owner forms and Scorecard.</p><section class="gd-task" id="customer-service-answer-a-request" data-gd-task><h2 class="gd-h2">Answer a request</h2><div class="gd-stepblock gd-stepblock--below"><div class="gd-stepcol"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">Open <b class="gd-ui">Requests and offers</b>: one queue (the numbers at the top are filters; <b class="gd-ui">Active</b> always shows everything), the most urgent first, with how long each renter has waited, the countdown to the 2 hours the site promises, the car&#39;s photo, the renter with <b class="gd-ui">Call</b> and <b class="gd-ui">Text</b>, the licence and one button (<b class="gd-ui">Send offer</b>, <b class="gd-ui">Follow up</b> or <b class="gd-ui">Open</b>). Filter by Active, New, Asked the renter, Changes asked, Offer out, Not paid or Expired; an expired offer moves to Expired after 48 hours.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Waiting shows how long the renter has waited. Open the booking number.</div></li></ol></div><figure class="gd-fig gd-fig--desk"><div class="gd-browser"><div class="gd-bar" aria-hidden="true"><i></i><i></i><i></i><span class="gd-addr">carmacars.ca/va/requests</span></div><div class="gd-imgwrap" style="aspect-ratio:1440/640"><img src="/guides/img/va-cs-03-requests-desktop-b3c66d25.jpg" alt="" loading="lazy" decoding="async" width="1440" height="640"><span class="gd-pin" style="left:27.1%;top:17.5%" aria-hidden="true">1</span><span class="gd-pin" style="left:52.8%;top:32.8%" aria-hidden="true">2</span></div></div></figure></div><div class="gd-stepblock gd-stepblock--below"><div class="gd-stepcol"><ol class="gd-ol" start="3"><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">On the Review tab, check the request: the car is free, the renter, the places.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t">Press <b class="gd-ui">Adjust the booking</b> to change the car, dates, places, price or extras, then <b class="gd-ui">Save changes</b>.</div></li><li><span class="gd-n" aria-hidden="true">5</span><div class="gd-t">Add a message and press <b class="gd-ui">Send the offer</b>. Within your limit you can also use <b class="gd-ui">Approve (within my limit)</b> or <b class="gd-ui">Approve and send the pay link</b>.</div></li><li><span class="gd-n" aria-hidden="true">6</span><div class="gd-t">Can&#39;t do it? <b class="gd-ui">Decline</b> with Reason and any alternative. Need to know more? <b class="gd-ui">Ask the renter</b>.</div></li></ol></div><figure class="gd-fig gd-fig--desk"><div class="gd-browser"><div class="gd-bar" aria-hidden="true"><i></i><i></i><i></i><span class="gd-addr">carmacars.ca/va/bookings/CC-10069?tab=review</span></div><div class="gd-imgwrap" style="aspect-ratio:1440/1000"><img src="/guides/img/va-cs-04-booking-review-desktop-52c68a73.jpg" alt="" loading="lazy" decoding="async" width="1440" height="1000"><span class="gd-pin" style="left:69.4%;top:24%" aria-hidden="true">3</span><span class="gd-pin" style="left:95.8%;top:98%" aria-hidden="true">4</span></div></div></figure></div><aside class="gd-box"><span class="gd-lbl">Tip</span><div>Reply within 5 minutes: send the offer, or ask the renter what you need. That is the &quot;First reply in opening hours&quot; measure on your scorecard. Requests waiting longer show in red.</div></aside><p class="gd-p">Opening a request takes it for you: the others see &quot;Being answered by&quot; your name and cannot answer it until you send, decline or leave (20 minutes, renewed while you work). One someone else holds shows who, with the buttons off; it opens to you when their claim runs out, or ask an Admin to take it over. Sales: a request from the website shows &quot;Opens to you at&quot; a time for its first 15 minutes, and a To do task says when it opens; after that whoever opens it first answers it, customer service included.</p></section><section class="gd-task" id="customer-service-an-enquiry-on-an-example-car" data-gd-task><h2 class="gd-h2">An enquiry on an example car</h2><p class="gd-p">Some cars on the site are marked &quot;Example car&quot;: samples that show the kind of cars we rent. A request on one is an enquiry, never a booking.</p><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">The task Suggest a similar real car comes to To do with the enquiry number (EQ-1001 and up), the car asked for, the dates and the contact. When a real car was free for those dates, the task names it after <b class="gd-ui">Free:</b> (the same make and model first, else the same class and body at a similar price), and the person was told we have a similar car and will confirm it within 2 hours.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Check the named car is still right for them (or find a real car of the same kind and price that is free for those dates), and make a <b class="gd-ui">New quote</b> for it.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Call or email the person with the car and the price, then mark the task done.</div></li></ol></div><aside class="gd-box"><span class="gd-lbl">Tip</span><div>Reply within the first reply target, as for any request. Never offer the example car itself: it does not exist.</div></aside></section><section class="gd-task" id="customer-service-a-request-from-a-vehicle-page" data-gd-task><h2 class="gd-h2">A request from a vehicle page</h2><p class="gd-p">Every make, model, year and trim page (carmacars.ca/cars/toyota/rav4/2023/xle, for example) has Request it, for the exact car the person wants.</p><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">The request arrives as an enquiry with the car named in the message (&quot;About the car: 2023 Toyota RAV4 XLE&quot;) and an Enquiry task in To do.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">If we have that car, or one close to it, free for their dates, make a <b class="gd-ui">New quote</b> for it. If not, suggest the nearest car of the same kind and price.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Reply by email or phone, then mark the task done.</div></li></ol></div><aside class="gd-box"><span class="gd-lbl">Tip</span><div>The pages say only what the data says: EPA fuel use, the Canadian trims and our own cars. Never promise equipment the page does not list.</div></aside></section><section class="gd-task" id="customer-service-a-buyer-lead-from-a-buy-page" data-gd-task><h2 class="gd-h2">A buyer lead from a /buy page</h2><p class="gd-p">Every vehicle page has a for-sale twin (carmacars.ca/buy/toyota/rav4/2023/xle) with &quot;Find me this car&quot;, and twins for financing, detailing and body shop work with their own request: a name, an email or phone, and when.</p><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">The lead is in <b class="gd-ui">Buyer leads</b> (customer service: <b class="gd-ui">Owners and enquiries</b>), Buyer leads (kind buyer, finance, detailing or body shop), with the car and what they asked, and a To do line for Sales: A buyer asked us to find a car, Someone asked about financing or leasing a car, A detailing request, or A body shop request.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">If one of our cars of that kind is for sale (an Admin flags it with its price), offer it. If not, offer to rent them the car for a week first, and say what we can find. We do not lend or lease: on a financing question, say so and offer the rental. For detailing or body shop work, give a time and a price, and always offer a rental while their car is in (an insurance replacement rental when it is a claim). For mechanical work (a &quot;Mechanical work to arrange&quot; task: an oil change, brakes, tires, a tow and the like), CarmaCars does not do the work: book it with a trusted shop or recommend one, never promise the shop&#39;s price or time, and offer a rental while their car is in.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Press <b class="gd-ui">Take it</b>, then <b class="gd-ui">Update</b> as you go: contacted, qualified, converted or closed with the reason.</div></li></ol></div><aside class="gd-box"><span class="gd-lbl">Tip</span><div>We mostly rent cars. Never say a car is for sale unless an Admin flagged it; the page shows it with its price when one is.</div></aside></section><section class="gd-task" id="customer-service-send-an-offer-to-a-caller" data-gd-task><h2 class="gd-h2">Send an offer to a caller</h2><p class="gd-p">Open <b class="gd-ui">Send an offer</b> (or <b class="gd-ui">Send an offer</b> beside a car in Find a car). No request needed: one screen, and the renter has the link.</p><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">Find the customer by name, phone or email, or press <b class="gd-ui">Add a new customer</b>: full legal name, mobile, email and date of birth. Already on file with that email or phone? Use them: never a second record.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Choose the car (by car code, plate or name; each says Free or Not free), the dates and the places.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">The price: the rate sheet, a total or a rate per day, with the reason for a price you type. The deposit, discounts and fees are set by an Admin; customer service sets the Protection Plan price. Amounts I type, at the top of the price: Before tax, or After tax (HST included) to type what the renter pays, worked back to before tax for you. Or type the Total the renter pays (after tax): the rental charge is worked out from it.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t">How the rental and the deposit are paid (card online, e-Transfer, cash, platform payout, the insurer; deposit by card hold, cash or e-Transfer), who found this client, the message, how long it is open (48 hours at most) and Email, Text or both.</div></li><li><span class="gd-n" aria-hidden="true">5</span><div class="gd-t">Check the offer as the renter will see it on the right, then press <b class="gd-ui">Send the offer</b>.</div></li></ol></div><aside class="gd-box"><span class="gd-lbl">Tip</span><div>An offer that is out is changed in place: <b class="gd-ui">More actions</b> &gt; <b class="gd-ui">Edit the offer</b>, change it, then <b class="gd-ui">Save and send the update</b> or <b class="gd-ui">Save without telling the renter</b>. No need to withdraw it first.</div></aside></section><section class="gd-task" id="customer-service-new-quote-for-a-caller" data-gd-task><h2 class="gd-h2">New quote for a caller</h2><div class="gd-stepblock gd-stepblock--below"><div class="gd-stepcol"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">Open <b class="gd-ui">New quote</b>. Choose the Car, the Pickup and Return (at least 2 hours from now).</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Choose how the lead came in, then the caller&#39;s Full legal name, Email, Mobile and Date of birth.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Set the Licence class and Damage cover, and note places, extras and what they asked.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t">Press <b class="gd-ui">Create the request</b>. It opens like any request; send the offer from there.</div></li></ol></div><figure class="gd-fig gd-fig--desk"><div class="gd-browser"><div class="gd-bar" aria-hidden="true"><i></i><i></i><i></i><span class="gd-addr">carmacars.ca/va/quotes/new</span></div><div class="gd-imgwrap" style="aspect-ratio:1220/1260"><img src="/guides/img/va-cs-05-new-quote-desktop-4e386b1c.jpg" alt="" loading="lazy" decoding="async" width="1220" height="1260"><span class="gd-pin" style="left:72.1%;top:15.6%" aria-hidden="true">1</span><span class="gd-pin" style="left:72.1%;top:41.7%" aria-hidden="true">2</span><span class="gd-pin" style="left:72.1%;top:72.7%" aria-hidden="true">3</span><span class="gd-pin" style="left:63.9%;top:85.5%" aria-hidden="true">4</span></div></div></figure></div></section><section class="gd-task" id="customer-service-edit-a-booking-a-fee-or-the-renter" data-gd-task><h2 class="gd-h2">Edit a booking, a fee or the renter</h2><p class="gd-p">A booking that is confirmed, on trip or returned is edited directly; the renter&#39;s details are corrected from the booking.</p><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">Overview, <b class="gd-ui">Edit the booking</b>: the return (extend or shorten), the car, the rental charge, each fee, the kilometres and the note. Tick <b class="gd-ui">Email the renter what changed</b>, or leave it off for a silent correction.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Money tab, Fees, <b class="gd-ui">Change or add a fee</b>: a fee forgotten (the young driver fee shows its price for the dates) or a charge of its own.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">What is open shows at once: <b class="gd-ui">Email a pay link</b> or <b class="gd-ui">Text a pay link</b> for exactly that amount, or record cash or an e-Transfer (Rental charges, Collect (the amount) rental, <b class="gd-ui">Cash, e-Transfer or another way (record it)</b>).</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t"><b class="gd-ui">Edit renter</b>: a wrong email, phone, name, licence or address. A new email is their sign-in at once.</div></li><li><span class="gd-n" aria-hidden="true">5</span><div class="gd-t">The same renter twice? Under the renter, Possible duplicates: <b class="gd-ui">Merge into this record</b> moves everything of the other record here.</div></li></ol></div><aside class="gd-box"><span class="gd-lbl">Good to know</span><div>Each edit is recorded with your name, the time, the reason and the before and after.</div></aside></section><section class="gd-task" id="customer-service-renter-messages-and-find-a-renter" data-gd-task><h2 class="gd-h2">Renter messages and Find a renter</h2><div class="gd-stepblock gd-stepblock--below"><div class="gd-stepcol"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t"><b class="gd-ui">Renter messages</b> lists the latest messages with their booking. Open the booking to reply, then press <b class="gd-ui">Send</b>.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t"><b class="gd-ui">Find a renter</b>: search by name, email, phone or booking number.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">To open a renter&#39;s private details, press <b class="gd-ui">Open with a reason</b>. The reason is kept in the access log.</div></li></ol></div><figure class="gd-fig gd-fig--desk"><div class="gd-browser"><div class="gd-bar" aria-hidden="true"><i></i><i></i><i></i><span class="gd-addr">carmacars.ca/va/messages</span></div><div class="gd-imgwrap" style="aspect-ratio:1440/260"><img src="/guides/img/va-cs-06-messages-desktop-3441fa91.jpg" alt="" loading="lazy" decoding="async" width="1440" height="260"><span class="gd-pin" style="left:32.6%;top:48.5%" aria-hidden="true">1</span></div></div></figure></div></section><section class="gd-task" id="customer-service-add-a-car-for-an-owner" data-gd-task><h2 class="gd-h2">Add a car for an owner</h2><p class="gd-p">Open <b class="gd-ui">Owners</b> &gt; <b class="gd-ui">Add a car for an owner</b> (fleet: under Cars). You enter everything for the owner; they never fill in the application.</p><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">The owner: find them by name, email or phone, or choose New owner and enter the name, email, phone and address.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">The car: type the VIN. The car is looked up at once and shown in one line with the year, make, model, trim and details (Edit if something is wrong). No VIN at hand: add it by its plate and choose the year, make and model. Tap the colour and check the class. Upload the ownership permit, the insurance slip and the lender&#39;s information if you have them. Photos are optional.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Terms and first invoice: what was agreed with the owner, to the cent. An Admin checks them before anything is sent.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t">Who sourced the owner: Entered for CarmaCars, or I sourced this owner. The owner signs in the owner portal after one email (no paper signature).</div></li><li><span class="gd-n" aria-hidden="true">5</span><div class="gd-t">Press <b class="gd-ui">Add the car and send to an Admin</b>. The application waits in the Admin&#39;s Applications, marked Entered by staff with your name. When the Admin approves, the owner gets one email to review and sign.</div></li></ol></div><aside class="gd-box"><span class="gd-lbl">Good to know</span><div>A fleet supplier (a corporation leasing its cars to CarmaCars): choose New owner, <b class="gd-ui">A corporation</b>, then Route <b class="gd-ui">Fleet supplier: leases the cars to CarmaCars</b>. The default lease terms are set at once. For the car, enter the VIN, the plate and the ownership copy, choose its tier, <b class="gd-ui">Regular</b> or <b class="gd-ui">Troubled</b> (it is set once), and who it is registered to now (for a car moving in or bought, the name and address on the ownership and the date). Its ServiceOntario forms are filled in at once. No terms, no invoices and no paper signing: the supplier signs in the owner portal. The car goes on the lease when an Admin approves it.</div></aside></section><section class="gd-task" id="customer-service-owners-the-checklist-the-photos-and-the-forms-release-34" data-gd-task><h2 class="gd-h2">Owners: the checklist, the photos and the forms (release 34)</h2><p class="gd-p">Open <b class="gd-ui">Owners</b> (customer service and fleet), then an owner. Search finds any owner by name, email, plate or VIN.</p><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">The <b class="gd-ui">Onboarding checklist</b>: per car, each step done, to do (and who it waits on), blocked (and why) or not needed, with the one button to press.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t"><b class="gd-ui">Onboarding photos</b>: <b class="gd-ui">Replace</b> or <b class="gd-ui">Remove</b> (with a reason) a wrong ownership permit, insurance slip or lender&#39;s letter, or <b class="gd-ui">Approve</b> or mark it <b class="gd-ui">Not accepted</b> (the owner reads why). A replaced photo is checked again.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t"><b class="gd-ui">Government forms</b>: each ServiceOntario form the car needs, made by themselves, with its status, the date it was made and its download.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t"><b class="gd-ui">Add cars from a list of VINs</b> for the owner: paste or upload, <b class="gd-ui">Preview</b>, <b class="gd-ui">Add</b>.</div></li></ol></div></section><section class="gd-task" id="customer-service-owner-forms-forms-c-and-d" data-gd-task><h2 class="gd-h2">Owner forms (Forms C and D)</h2><div class="gd-stepblock gd-stepblock--below"><div class="gd-stepcol"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">Open <b class="gd-ui">Owner forms</b>. Each row is a scan an owner uploaded before November 2026 (Forms C and D are signed on screen since then), with the witnesses and the status.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Press Open to read the scan. Check every page is there and signed, with each witness&#39;s signature and name.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Press <b class="gd-ui">Approve</b>, or <b class="gd-ui">Send back</b> with What to fix (the owner reads this).</div></li></ol></div><figure class="gd-fig gd-fig--desk"><div class="gd-browser"><div class="gd-bar" aria-hidden="true"><i></i><i></i><i></i><span class="gd-addr">carmacars.ca/va/owner-forms</span></div><div class="gd-imgwrap" style="aspect-ratio:1440/300"><img src="/guides/img/va-cs-08-owner-forms-desktop-eceaee0b.jpg" alt="" loading="lazy" decoding="async" width="1440" height="300"><span class="gd-pin" style="left:68.6%;top:36.7%" aria-hidden="true">2</span><span class="gd-pin" style="left:76.7%;top:36.7%" aria-hidden="true">3</span></div></div></figure></div></section><section class="gd-task" id="customer-service-rental-agreements-are-signed-online-only" data-gd-task><h2 class="gd-h2">Rental agreements are signed online only</h2><p class="gd-p">A rental agreement, or a booking change, is signed by the renter in their portal or on the phone at the handover (the e-signature). A copy signed on paper is not accepted or recorded: send the renter the link again from the booking. One recorded before November 2026 stays readable under Signed on paper.</p></section><section class="gd-task" id="customer-service-signatures-on-the-spot-or-by-link" data-gd-task><h2 class="gd-h2">Signatures on the spot, or by link</h2><p class="gd-p">A renter or an additional driver who has not signed yet.</p><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">On the booking, press <b class="gd-ui">Sign now on this device</b>. Confirm the name and that you saw the original licence, then <b class="gd-ui">Hand the device to</b> the signer.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Or press <b class="gd-ui">Email the signing link</b> or <b class="gd-ui">Text the signing link</b>: they sign on their own phone.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">The licence comes first: the renter uploads it from the request, and the offer cannot be accepted without it.</div></li></ol></div></section><section class="gd-task" id="customer-service-the-booking-s-rental-agreements" data-gd-task><h2 class="gd-h2">The booking&#39;s rental agreements</h2><p class="gd-p">The Rental agreements card keeps both agreements in step with the booking.</p><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">Any change after signing makes a new version by itself. A change to the dates, the price, the car, the drivers or the coverage waits for the renter&#39;s signature: they get the link by email and text, and the card says &quot;Agreement v3 waiting for signature&quot;.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t"><b class="gd-ui">Resend the signing links</b>, or press the button with their first name beside it to have them sign on your device.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Fields still blank (a licence expiry, an insurer&#39;s policy number) are listed: type them and press <b class="gd-ui">Save the missing fields</b>. Check-in stops on a field a claim needs until it is filled or an Admin overrides.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t">Every signature: a code to the signer&#39;s phone or email, the key terms initialled, three consents, a drawn signature.</div></li></ol></div></section><section class="gd-task" id="customer-service-check-renter-documents" data-gd-task><h2 class="gd-h2">Check renter documents</h2><p class="gd-p">The renter&#39;s licence photos, selfie and proof of coverage, before the handover.</p><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">Open the task &quot;identity documents or coverage proof to review&quot;, or open the booking: <b class="gd-ui">Review</b> shows the documents of any booking being arranged or under way, with no task needed.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Every licence image, selfie and proof of coverage of the booking is on one screen, with what to check written once above them: the selfie matches, no alteration, the coverage is active to the return date.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Under each driver, the licence reader lists what it read (from the back&#39;s barcode, else the photo) and one line per check, Pass or Flag: photos sharp and whole, valid to the return, class accepted, old enough at pickup, name and date of birth match the driver, the Ontario number, front and back the same licence, and the main driver&#39;s Ontario licence. Look closely at each Flag.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t">One is wrong? Open <b class="gd-ui">Reject this one</b> under it, type the reason the renter reads and press <b class="gd-ui">Reject</b>.</div></li><li><span class="gd-n" aria-hidden="true">5</span><div class="gd-t">Then press <b class="gd-ui">Approve all</b>: everything still waiting is approved at once (the Protection Plan too). A document the system refuses is named with the reason; the rest are approved.</div></li></ol></div><aside class="gd-box"><span class="gd-lbl">Tip</span><div>Each opening is logged. An Admin can do the same from Admin &gt; To do. Field staff review the licence images (not the coverage) of bookings on their own jobs in the next 7 days from their My jobs: the booking history says the role, field.</div></aside><aside class="gd-box"><span class="gd-lbl">Good to know</span><div>Main driver: Ontario licence needed. When the main driver&#39;s licence is from elsewhere, they are moved to additional driver (their photos and checks stay; you still review them) and pickup is blocked until a driver with an Ontario licence is the main driver. The renter adds one from their booking. Only an Admin can undo the swap or let it go with a reason.</div></aside></section><section class="gd-task" id="customer-service-which-credit-cards-include-rental-car-coverage" data-gd-task><h2 class="gd-h2">Which credit cards include rental car coverage?</h2><p class="gd-p">Renters ask this often. <b class="gd-ui">Renters</b> &gt; <b class="gd-ui">Card coverage</b> (every function has it under Rentals or Bookings) is your quick reference: what to say, what to check, and the list.</p><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">Send the renter <span class="gd-url">carmacars.ca/credit-card-rental-coverage</span>: each card&#39;s car value limit (MSRP), longest rental, key exclusions, its official guide and the day we last checked it.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Ask which car they want. Most Canadian cards stop at a car priced $65,000 or $85,000, and many luxury models are priced higher. Give them the car&#39;s model year and trim so they can check.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Never tell a renter they are covered. Their card&#39;s issuer decides that: ask them to call the number on the back of their card about this car and these dates. CarmaCars does not decide claims.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t">Over the limit, an excluded make, a debit card or a longer rental than the card allows: offer OPCF 27 on their own auto policy or the CarmaCars Protection Plan.</div></li></ol></div><aside class="gd-box"><span class="gd-lbl">Tip</span><div>A card marked Unverified came from a published summary, not the issuer&#39;s guide. Something wrong or out of date in the list? Tell an Admin: they correct it in Settings &gt; Card coverage.</div></aside></section><section class="gd-task" id="customer-service-review-requests" data-gd-task><h2 class="gd-h2">Review requests</h2><p class="gd-p">Renters are asked for a review by email and text after each trip. <b class="gd-ui">Renters</b> &gt; <b class="gd-ui">Review requests</b> shows the ones on hold and the Google reviews to match.</p><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">On hold: the booking has a charge that is not settled or waived yet (late return, kilometres, fuel, cleaning, smoking, damage, tolls) or an open incident. It leaves the list by itself once the charges are settled or waived.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">The renter should be asked now anyway? Press <b class="gd-ui">Send anyway</b>. Should never be asked? Press <b class="gd-ui">Do not ask</b>.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Google reviews: a possible match to a renter shows &quot;possible match&quot;. Press <b class="gd-ui">Confirm</b> if it is them, <b class="gd-ui">Not this renter</b> if not, or <b class="gd-ui">Match to a booking</b> with the booking number.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t">A review that came another way (Turo, a text, a call, email): press <b class="gd-ui">Add a customer review</b> and type the customer&#39;s first name and last initial, the source, the date received, the rating and their words exactly as received, with a screenshot if you have one. It shows on the site with its source. Never write or change a review for a customer.</div></li><li><span class="gd-n" aria-hidden="true">5</span><div class="gd-t">On a booking, the card Review requests has <b class="gd-ui">Ask for a review</b> (for example after a call that went well) and <b class="gd-ui">Mark reviewed</b> when the renter says they already left one.</div></li></ol></div><aside class="gd-box"><span class="gd-lbl">Tip</span><div>Never offer anything for a review and never ask only happy renters: everyone gets the same message and the same Google link.</div></aside></section><section class="gd-task" id="customer-service-a-change-to-a-confirmed-booking" data-gd-task><h2 class="gd-h2">A change to a confirmed booking</h2><p class="gd-p">On a booking&#39;s Changes tab you can propose new dates, times or another car, as an Admin does: set the change, write the reason, press <b class="gd-ui">Preview the price</b>, then <b class="gd-ui">Send to the renter</b>. The renter has 48 hours to accept and sign the amendment. You also send a new signing link to an additional driver from the booking screen.</p></section><section class="gd-task" id="customer-service-a-late-return" data-gd-task><h2 class="gd-h2">A late return</h2><p class="gd-p">A booking past its return time shows the late return panel. The renter can still extend in their booking while they have the car: the extension counts from the original return time, it is approved at once when the car is free, and paying it stops the late notices. Point them to <b class="gd-ui">Extend</b> first. Otherwise work it in order:</p><div class="gd-tablewrap"><table class="gd-table"><thead><tr><th scope="col">Button</th><th scope="col">When</th></tr></thead><tbody><tr><td><b class="gd-ui">Log a call</b></td><td>Record each call to the renter and what they said.</td></tr><tr><td><b class="gd-ui">Send T13</b></td><td>The first late notice email.</td></tr><tr><td><b class="gd-ui">Send T14 (final notice)</b></td><td>The final notice.</td></tr><tr><td><b class="gd-ui">Request disable</b></td><td>Ask an Admin to approve disabling the car.</td></tr><tr><td><b class="gd-ui">Open an incident</b></td><td>When the car is not coming back as planned.</td></tr></tbody></table></div></section><section class="gd-task" id="customer-service-booked-when-the-renter-accepts-release-28" data-gd-task><h2 class="gd-h2">Booked when the renter accepts (release 28)</h2><p class="gd-p">A renter who approves the offer has booked the car, even before paying: the booking shows <b class="gd-ui">Booked, payment due</b> and holds the car everywhere. Collect the payment before the pickup (a <b class="gd-ui">Booked, payment due</b> To do comes 48 hours before). When you send an offer, the renter&#39;s view is right under <b class="gd-ui">Send the offer</b>.</p></section><section class="gd-task" id="customer-service-when-a-check-stops-the-pickup-or-the-return-release-33" data-gd-task><h2 class="gd-h2">When a check stops the pickup or the return (release 33)</h2><p class="gd-p">On the booking page, <b class="gd-ui">What stops the pickup now</b> (or the return) lists each check that stops it, in plain words. When the trip must go ahead anyway, press <b class="gd-ui">Ask an Admin to override the pickup</b> (or the return), give the actual time, the km and fuel if you know them, and why. An Admin gets an alert and approves in one tap; the pickup (or the return) is then recorded with the time you entered, and the booking&#39;s history says who asked and who approved. You can cancel your request while it waits. A trip that happened and was never recorded: <b class="gd-ui">Ask to record a past trip</b> with both times; once an Admin approves, the booking lands in Returned so the deposit can be settled.</p></section><section class="gd-task" id="customer-service-book-it-now-release-33" data-gd-task><h2 class="gd-h2">Book it now (release 33)</h2><p class="gd-p">When you send an offer, tick <b class="gd-ui">Book it now (no renter approval)</b> when the renter has already agreed. The offer goes out and an Admin approves it in one tap: the booking then waits for payment, the car is held, and the renter gets one link to sign and pay. You can also have them sign and pay with you: open the booking, <b class="gd-ui">Sign now on this device</b>, then take the card on this device. Already sent the offer? Ask the assistant: &quot;Book the offer of CC-10482 now, the customer agreed by phone&quot;. It shows a card; <b class="gd-ui">Confirm</b> sends the same request to an Admin, who approves in one tap.</p></section><section class="gd-task" id="customer-service-switch-a-booking-between-card-coverage-and-the-protection-pl" data-gd-task><h2 class="gd-h2">Switch a booking between card coverage and the Protection Plan (release 35)</h2><p class="gd-p">When a renter&#39;s card does not cover the car, or they want the plan instead, switch the booking yourself. On the booking page, open the <b class="gd-ui">Coverage</b> card.</p><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">Press <b class="gd-ui">Switch to the Protection Plan</b>. You see the plan&#39;s price with HST and the new total before you confirm.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Write the reason (the renter reads it). On a confirmed booking or a rental in progress you can type the plan&#39;s price for this booking, for example for the days left.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Press the button. An offer is sent again with the new price. A confirmed booking gets the plan line and the extra is open to collect on the Money tab: Collect sends the pay link. The renter is emailed what changed.</div></li></ol></div><p class="gd-p">The card coverage proof and its review task are cleared for you. <b class="gd-ui">Switch to card coverage</b> puts them back, or gives you a task to get the proof from the renter. Sales switches requests and offers only.</p></section><section class="gd-task" id="customer-service-unanswered" data-gd-task><h2 class="gd-h2">Unanswered</h2><p class="gd-p"><b class="gd-ui">More customer service</b> &gt; <b class="gd-ui">Unanswered</b>: every customer text with no reply and every missed call not called back, oldest first. Reply or call back from the row; <b class="gd-ui">Mark answered</b> when it was answered another way. After 15 minutes the team is alerted. Check WhatsApp by hand each morning.</p></section><section class="gd-task" id="customer-service-the-request-as-sent-and-every-offer-release-35" data-gd-task><h2 class="gd-h2">The request as sent and every offer (release 35)</h2><p class="gd-p">On a request or a booking, <b class="gd-ui">Original request, as the renter sent it</b> shows the car, dates, places, coverage, add-ons, note and the price the renter saw, exactly as sent; staff changes never touch it. <b class="gd-ui">Offer history</b> lists every offer version, newest first: its status, who sent it and when, the car and dates, the message, how the total moved, and the price breakdown.</p><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">To go back to an old version, press <b class="gd-ui">Revert to this offer</b> on it. Its car, dates, price, deposit, discount and fees load into the review as a new offer, highlighted.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Check the price, then send it in step 3. Nothing changes until you send.</div></li></ol></div><p class="gd-p">The <b class="gd-ui">Coverage</b> line at the top says what the renter chose (own insurance OPCF 27, credit card, Protection Plan) and its proof: not sent yet, waiting for review, confirmed, or rejected with the reason.</p></section><section class="gd-task" id="customer-service-send-an-offer-in-three-steps-release-35" data-gd-task><h2 class="gd-h2">Send an offer in three steps (release 35)</h2><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t"><b class="gd-ui">Car and dates</b>: the renter, the dates, the car and where they pick it up and return it.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t"><b class="gd-ui">Price</b>: filled in from the rate sheet with the checkout&#39;s fees and discounts. Change it only if you agreed another price.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t"><b class="gd-ui">Review and send</b>: what changed, the message and how the link goes.</div></li></ol></div><p class="gd-p">Rarely used options (billing an insurer, how it is paid, the calendar) are under <b class="gd-ui">More options</b>. Send waits while the price is being worked out again after a date change, and one tap sends once.</p></section><section class="gd-task" id="customer-service-the-owner-s-own-trip-instant-bookings-and-book-it-now-releas" data-gd-task><h2 class="gd-h2">The owner&#39;s own trip, instant bookings and Book it now (release 35)</h2><ul class="gd-ul"><li><b class="gd-ui">Owner&#39;s own trip ($0)</b>: the owner booked their own car. There is nothing to price or send; get the car ready.</li><li><b class="gd-ui">Instant (repeat renter)</b>: a renter with a completed rental, a verified licence and nothing owing booked an available car at once and went straight to sign and pay. An Admin can take a renter&#39;s instant booking away from the booking page.</li><li><b class="gd-ui">Book it now</b> pressed by staff waits for an Admin&#39;s one-tap approval.</li></ul></section><section class="gd-task" id="customer-service-secondary-contact-and-rideshare-documents-release-35" data-gd-task><h2 class="gd-h2">Secondary contact and rideshare documents (release 35)</h2><p class="gd-p">The booking shows the renter&#39;s <b class="gd-ui">Secondary contact</b> when they gave one: call them when the renter cannot be reached. Rideshare and delivery driving are welcome (rental agreement, section 10.3): never tell a renter it is not allowed. When a renter makes <b class="gd-ui">rideshare documents</b> (Uber, Lyft, DoorDash and others), you get an alert and the booking shows the letters they made.</p></section><section class="gd-task" id="customer-service-automatic-answers-release-36" data-gd-task><h2 class="gd-h2">Automatic answers (release 36)</h2><p class="gd-p">Common questions by text, email, WhatsApp, Facebook and Instagram are answered by themselves from the FAQ. <b class="gd-ui">Renter messages</b> &gt; <b class="gd-ui">Automatic answers</b> shows what was answered and what was left for a person. A question the FAQ does not answer stays for you: texts in Messages, emails and Meta messages as a To do, <b class="gd-ui">Answer</b> and the question. Once you text someone, no automatic answer goes to them for 2 hours.</p></section><section class="gd-task" id="customer-service-the-card-the-renter-picked-and-the-two-opcf-27-pages-release" data-gd-task><h2 class="gd-h2">The card the renter picked, and the two OPCF 27 pages (release 35)</h2><p class="gd-p">On <b class="gd-ui">Review documents</b> for a booking:</p><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t"><b class="gd-ui">Option 2</b>: <b class="gd-ui">Card picked</b> names the card the renter chose from the list (or typed when it was not listed), and <b class="gd-ui">Card check</b> says whether it covers this car: <em>Covers this car</em>, <em>Check it</em> (a card not on the list, a card whose coverage or value limit we do not know, or a car with no value on file) or <em>Does NOT cover this car</em> with the reason. <b class="gd-ui">Approve</b> is refused while the card does not cover the car.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t"><b class="gd-ui">Option 1</b>: each page says what it is: <b class="gd-ui">pink slip</b> or <b class="gd-ui">OPCF 27 endorsement</b>. <b class="gd-ui">Approve</b> is refused until both are in. <b class="gd-ui">Reject</b> needs the reason the renter sees.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">A renter on OPCF 27 cannot pay until both pages are uploaded, so you see them before the booking is confirmed.</div></li></ol></div><aside class="gd-box"><span class="gd-lbl">Tip</span><div>Uploading a renter&#39;s insurance yourself? In <b class="gd-ui">Upload a document</b>, choose <b class="gd-ui">Which page</b>: Pink slip or OPCF 27 endorsement page.</div></aside></section><section class="gd-task" id="customer-service-calls-auto-replies-and-coverage-releases-35-and-36" data-gd-task><h2 class="gd-h2">Calls, auto-replies and coverage (releases 35 and 36)</h2><ul class="gd-ul"><li>Calls from the Call button are recorded; the transcript, summary and Play recording are on the renter&#39;s, lead&#39;s and booking&#39;s history. Quo calls show their transcript and summary there too.</li><li>Automatic answers reply to common questions on every channel from our FAQ. A question they cannot answer becomes your To do: answer it yourself.</li><li>Card coverage: the renter picks their card and the page checks it against the car. Approve OPCF 27 only with both the pink slip and the endorsement page.</li><li>Rideshare and delivery work is allowed with the documents the renter makes on their booking; the secondary contact is on the booking.</li><li>The mid-trip message asks the renter how the trip is going; a problem reported becomes your To do.</li></ul></section><section class="gd-task" id="customer-service-calls-first-texts-after-release-37" data-gd-task><h2 class="gd-h2">Calls first, texts after (release 37)</h2><p class="gd-p">Your main priority is always to be on the phone with people.</p><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">Answer a ringing call before anything else, and return a missed call at once.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t"><b class="gd-ui">Call before you text.</b> On a lead, a renter or a booking, <b class="gd-ui">Call</b> is the first button and <b class="gd-ui">Text</b> the second.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">A text is a follow-up: after a call attempt (no answer, a voicemail left), or when the person asked for a text.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t">On your To do and on <b class="gd-ui">Unanswered</b>, missed calls and call-backs are listed above unanswered texts.</div></li></ol></div></section><section class="gd-task" id="customer-service-a-lead-you-handle-on-a-call-release-37" data-gd-task><h2 class="gd-h2">A lead you handle on a call (release 37)</h2><p class="gd-p">When you answer or place a call with a lead, add a note on it, or create it from a call, the lead is yours for a limited time (15 minutes, as a Sales claim; an Admin can change it in <b class="gd-ui">Settings</b> &gt; <b class="gd-ui">Sales</b>). Every call you handle adds the time again.</p><ul class="gd-ul"><li>Sales see <b class="gd-ui">Being handled by</b> your first name and your function with the time, on the lead and in every list. They cannot claim it, call, text or email it, or set an outcome meanwhile, and <b class="gd-ui">Next lead</b> skips it.</li><li>Another customer service or Fleet person can still work it; their call or note takes the hold over.</li><li>When it ends, the lead goes back to the salesperson who had a claim on it or who brought it, else to the open list. An Admin can <b class="gd-ui">Release hold</b> earlier.</li><li>A booking made from the lead is credited as always: customer service and Fleet get no sales commission for it.</li><li>Nobody who has not finished onboarding holds a lead.</li></ul></section>');
select app.guide_release_section('va', 'finance', 'chapter', 'chauffeur-requests', 'You keep the money right: payments, deposits and refunds, toll notices, processor payouts and Turo trips.

Your rail: Queue, Today, Money, Tolls and tickets, Turo trips, Find a renter, Calendar and Scorecard. **Money** opens with a row of tabs on top, as in Admin: **To handle** (payments, deposits, refunds), **By day** (with Today, 7 days, 30 days and 90 days), **All payments**, **Refunds**, **Deposits**, **Reconciliation** and **Unlinked Stripe** (the Stripe payments of the last 60 days that no booking knows, checked every night, with a best guess of the booking: an Admin links one from the booking''s Money tab; put one aside with the reason when it is not a booking''s payment). **Owner money** lists every owner invoice and owner statement. The old Payments by day and Reconciliation addresses open their tabs.

## Your queue

Finance tasks include failed owner debits, toll notices with no match, statements to review and refunds to issue.

![The lanes show what Finance handles: payments to fix, refunds waiting, tolls and tickets, deposits to settle and owner statements. Money today counts them below.](/guides/img/va-finance-01-queue-desktop-2f37513d.jpg "desktop; size: 1230 940; address: carmacars.ca/va; pins: 1 20.3 24.3")

## Payments by day

**Money**, the **By day** tab, is your day in one screen: every payment and refund, by method, with the cash drawer and the refunds to decide.

1. Choose From and To (today by default) and tick the methods you want (card, e-Transfer, cash, cheque, platform payout, insurer and others; none ticked shows all), then press **Show**.
2. Totals by method: received, refunded and net. Each day: the same by method, the cash expected in the drawer (cash received less cash given back) and the cash counted.
3. At the end of the day count the drawer and press **Record the count**. The difference shows "balanced", or "over" or "short" with the amount.
4. Refunds waiting: every refund asked for anywhere (a cancellation, a booking, Finance), with the policy maths (paid, the tier, the percentage back, what is kept). Press **Approve** or **Decline** with the reason in the same row; above your limit it says an Admin approves. Approved: **Issue the refund**.
5. **Export CSV** gives the same rows for the bank or the bookkeeper: refunds as negative amounts, holds marked as not money in.

## Payments, deposits, refunds

**Money**, the **To handle** tab.

1. Failed payments: each with the purpose, amount and the bank''s reason.
2. Deposits to take before pickup, and deposits due back.
3. Refunds in progress. Press **Request the refund** and choose What it refunds (the rental charge, delivery or pickup, kilometres, add-ons or other charges); above your limit it waits for an Admin. Then **Issue the refund**.
4. Owner invoices that failed, and owner statements to prepare.

![](/guides/img/va-finance-02-money-desktop-486a8fbc.jpg "desktop; size: 1230 865; address: carmacars.ca/va/money; pins: 1 10.6 60.3, 2 72.4 21.6, 3 73.2 33.8, 4 11.0 45.9")

## A payment received another way

An owner or renter paid by e-Transfer, cheque, cash or bank transfer.

1. Owner invoice: on **Payments, deposits, refunds**, find it under Owner invoices owing and press **Record payment**.
2. Renter: beside the failed payment, press **Paid another way**. Or open the booking''s Money tab: in Rental charges press Collect (the amount) rental, or in Security deposit Collect (the amount) deposit, choose **Cash, e-Transfer or another way (record it)** and how it was paid, then record it. Each panel collects its own part only.
3. Choose Paid by, the Date received and the Reference (the cheque number for a cheque). Leave Amount empty for the full balance; type less for a partial payment.
4. Add the proof if you have it (a screenshot or a photo of the cheque), then press **Record payment**.

The invoice is marked paid or partly paid, the automatic debit stops for that amount and the owner gets a receipt. Above your single limit the payment needs an Admin. Recorded something wrong? Ask an Admin to void it; you cannot void a payment.

Each month''s payments recorded by hand are listed under Reconciliation, with the totals by method, to check against the bank.

## Cards, holds and deposits given back

On the booking''s Money tab.

1. After the return, **Charge the renter**: the Reason from the list (Other with its note), the Amount, and the line that says where the money comes from (the deposit hold while it is valid, else the card on file, else a pay link) before you press **Charge $...**. Before the return, Rental charges, **A later charge**, with the same reason list on the renter''s receipt. A deposit that cannot be held: Security deposit, **Charge the card on file as the deposit**.
2. A deposit hold, in the Security deposit panel: **Keep part (damage/fees)** with the amount and the reason from the list (the rest is released), or **Release**. **Hold expired**: nothing can be kept from it; press **Charge the card on file instead** (the amount and the reason are filled in). While the car is out, inside the toll window or while something is open, both wait for the settlement; an Admin may do it with the reason.
3. A deposit taken in cash or by e-Transfer is given back the same way: the task Give the deposit back the way it came; then press **Returned** with the reference or receipt number.

## Settle a deposit

The deposit is never given back by itself. Finance or an Admin settles it after the return: on the booking''s Money tab, under Deposit, press **Settle the deposit**. Issue the Check-out statement first.

1. The form shows the deposit, what is still available, the charges owed from the statement and what is taken from the deposit for them. What the deposit does not cover is charged to the card on file; with no card (or a card declined), the renter gets a pay link by email and text, and Finance has a task until it is paid.
2. Tolls and tickets can take up to 7 days to come in. Inside that window the whole rest of the deposit is filled in as the hold-back, until the window ends. To give it back sooner, tick Release now anyway: a toll that comes in later is charged to the card on file.
3. Something still open keeps the whole deposit: an incident, a claim, new damage at the return not priced, damage found later not billed, a toll or ticket on the car during the rental not matched or not charged, a card dispute, or charges not on a statement yet. The form lists them. Only an Admin can release part of it, with the reason; it is recorded.
4. Damage: an Admin keeps the whole deposit (**Keep the whole deposit (damage)**) or bills a damage charge up to the $2,500 deductible. Ask an Admin, with the photos.
5. Press **Settle**. The money moves at Stripe at once: the charges are collected and what is not owed is refunded or the hold released. A step Stripe refuses is tried again by itself, and Finance gets a task if it keeps failing.

> Good to know: A card hold lapses after about 7 days. While the car is out, or returned and not settled, the hold is collected in full a day and a half before it lapses: that keeps the money, and the settlement refunds what is not owed. A hold that lapses anyway is charged to the saved card, and Finance is told at once.

## Read a toll notice

1. Open **Tolls and tickets** and press **Read a notice**.
2. Choose the file: a PDF, a photo or a CSV, under 15 MB. Leave the reading profile to find it from the text.
3. Press **Read it**. Then check each line beside the notice and fix what was read wrong.
4. Press **Checked against the notice** on each line (**Leave out** to skip one), then **Save as checked** and **Confirm and import**.

![](/guides/img/va-finance-04-tolls-read-desktop-aa04a6b2.jpg "desktop; size: 1230 580; address: carmacars.ca/va/tolls/read; pins: 2 19.5 44.1, 3 4.1 64.8, 4 4.1 89.7")

> Tip: In the work queue, **Match again** retries the match after a fix, and **Dispute** marks a notice you think is wrong. Renters matched with high confidence are charged at import, with the notice and our fee.

![The work queue: Unmatched, Needs review, Matched not charged and Disputed, with each notice''s plate, date, amount and match.](/guides/img/va-finance-03-tolls-desktop-37b6f99c.jpg "desktop; size: 1230 540; address: carmacars.ca/va/tolls; pins: 1 23.6 12.2")

## Reconciliation and Turo trips

1. **Money**, the **Reconciliation** tab: press **Record a processor payout**, then **Match** it to the payments it contains. Anything still unmatched at the closing check goes to an Admin.
2. **Turo trips**: press **Add a trip** for one trip, or paste CSV rows and press **Import**.

![](/guides/img/va-finance-06-turo-desktop-b59cc7f9.jpg "desktop; size: 1230 540; address: carmacars.ca/va/turo; pins: 2 95.1 14.8")

## Deposits to release

A deposit is never released by itself. Each morning the system puts one task in your queue for every deposit due back: "Release the deposit for" the booking, with the amount and the day it is due (7 business days after the check-out, or after the return when no check-out was recorded). On the day, and every day after, you and the Admins also get a notice in the portal. Nothing is emailed.

1. Open the task: it opens the booking''s **Money** tab.
2. Settle the deposit: apply what is owed, hold back what an open item needs, release the rest.
3. The task closes by itself once nothing is left to give back.

### Card payments outside the site and the card reader
On a booking''s **Money** tab: **Record card payment** records a card taken in the Stripe Dashboard or on a reader (the last 4 digits always; a Stripe payment id, pi_..., checks it, and a deposit hold needs it). **Charge on reader** and **Hold deposit on reader** send the amount to the S700; the renter taps the card and the screen updates by itself. On a credit card coverage rental the whole rental is paid on the same card: another card is refused with the reason, and only an Admin can allow another one.

## Deposit holds and partner invoices (release 28)

Deposits stay as holds with Stripe and are never captured by itself. A job re-authorizes a hold by itself about 24 hours before it expires; when it cannot, you get the alert **Deposit hold not re-authorized**. A **The deposit hold expires soon** To do opens the booking: **Re-authorize the hold** places a new hold on the saved card and releases the old one; or **Keep part (damage/fees)** for only what is owed. A deposit not taken yet: in the Security deposit panel, **Hold on the card on file**. Under **Money** > **Partner invoices** you write invoices to body shops, tow trucks and storage yards for their kickback, send them, record the cheques and e-Transfers that come in, and export the CSV for the bookkeeper.

## Kickbacks and repairs

**Money** > **Kickbacks and repairs**: the kickbacks received on partner invoices (before HST) and the repair costs paid by CarmaCars for a period, by owner and by car, with the CSV. An invoice with no car counts nowhere until you choose it: open the invoice under **Partner invoices** and press **Choose the car**. Add a repair cost with **Add a repair cost**; Fleet adds them on the car''s page too.

### A debit deposit''s card fee
A deposit charged (not held) on a debit or prepaid card carries the non-refundable **Card processing fee for a debit deposit**, shown on its line in the history and on the receipt. The deposit refund returns the deposit only.

## Partners, the timesheet and ended trips

1. **More finance** > **Partners**: the rental partners (their pages, cars, rates, invoices) and the referral partners (kickbacks, payments), with every action an Admin has there.
2. **Hours** > **Timesheet**: the hours customer service, Fleet and Finance clocked. Add forgotten hours or void a wrong entry, with the reason.
3. **Close ended trips**: mark trips that ended and were never closed, and choose the deposit decision. An Admin presses Release; nothing is released by itself.


## Deposit review: double-check, tolls and tickets, then bill or release

Once Fleet signed every item of a returned booking you get a To do to double-check the deposit review. The deposit stays held until you signed every item too; only an Admin can release it earlier, with the reason.

1. Open **Money** > **Deposit reviews** and open the booking.
2. Press **Double-check** on each item: read Fleet''s finding and the photos, then **OK** or **Issue** with the amount to bill. Someone else double-checks an item you signed for Fleet.
3. **Highway tolls**: open the toll operator''s site from the review, search the plate for the rental dates, then double-check the item.
4. **Tickets**: open each place in the list (its official lookup link), search the plate, and press **None found** or **A ticket**. A ticket is logged in **Tolls and tickets** with the place and the plate and matched to the booking there. The Tickets item waits until every place is checked.
5. Then open **Money** on the booking: bill what is owed with the charge after the return, or release the deposit.

### The sweep, Monday, Wednesday and Friday
On each sweep day a To do **Deposit check sweep** lists every plate returned since the last sweep and every booking still inside the toll and ticket window. **Deposit reviews** > **This sweep** shows them by plate with every link, so you check them in one go. The days are in Program settings.

### Countdowns
**Money** > **Countdowns** (and the top of **To handle**, and each booking) shows the time left before each deposit hold expires (with when the automatic re-authorization runs, 24 hours before), before each deposit is due back to the renter, and before the next payment of a weekly, biweekly or monthly plan. Red is within 24 hours or late, amber within 48. Sort by any column. You get an alert at 48 and 24 hours, and the counts are in your morning digest.

### Do sales too
Under **My numbers** > **Do sales too**, press **I want to do sales too**: the Sales path is added to your academy (your Finance work is never held by it), and the Sales pages open once you pass it.


## The fuel line on the deposit review (release 35)

The fuel item shows **Suggested** with its working: the tank x the fuel missing x the pump price x 1.25, plus the $20 refuelling fee. It is a line on the return charges, never charged by itself: sign the item, then bill it with the rest from the booking''s Money. A pump receipt still wins: enter it when the car was filled up.

## Statements and payroll (release 35)

- Statements cover the 8th to the 7th, paid on the 10th; amounts not yet collected from the renter are listed apart and paid on the statement after they come in.
- Payroll every two weeks: prepare the run with any bonus or deduction and its reason, then send it for approval. An Admin approves and records the payments.
- Email: Settings, Usage shows the real daily capacity of our sending services together; nothing to count by hand.', 'Finance', 'Payments, deposits and refunds, tolls and tickets, reconciliation and Turo trips.',
  'You keep the money right: payments, deposits and refunds, toll notices, processor payouts and Turo trips. There is no commission for Finance, but your help is credited on the booking (Helped by) and on your scorecard.

Your rail: Queue, Today, Money, Tolls and tickets, Turo trips, Find a renter, Calendar and Scorecard. **Money** opens with a row of tabs on top, as in Admin: **To handle** (payments, deposits, refunds), **By day** (with Today, 7 days, 30 days and 90 days), **All payments**, **Refunds**, **Deposits**, **Reconciliation** and **Unlinked Stripe** (the Stripe payments of the last 60 days that no booking knows, checked every night, with a best guess of the booking: an Admin links one from the booking''s Money tab; put one aside with the reason when it is not a booking''s payment). **Owner money** lists every owner invoice and owner statement. The old Payments by day and Reconciliation addresses open their tabs.

## Your queue

Finance tasks include failed owner debits, toll notices with no match, statements to review and refunds to issue.

![The lanes show what Finance handles: payments to fix, refunds waiting, tolls and tickets, deposits to settle and owner statements. Money today counts them below.](/guides/img/va-finance-01-queue-desktop-2f37513d.jpg "desktop; size: 1230 940; address: carmacars.ca/va; pins: 1 20.3 24.3")

## Payments by day

**Money**, the **By day** tab, is your day in one screen: every payment and refund, by method, with the cash drawer and the refunds to decide.

1. Choose From and To (today by default) and tick the methods you want (card, e-Transfer, cash, cheque, platform payout, insurer and others; none ticked shows all), then press **Show**.
2. Totals by method: received, refunded and net. Each day: the same by method, the cash expected in the drawer (cash received less cash given back) and the cash counted.
3. At the end of the day count the drawer and press **Record the count**. The difference shows "balanced", or "over" or "short" with the amount.
4. Refunds waiting: every refund asked for anywhere (a cancellation, a booking, Finance), with the policy maths (paid, the tier, the percentage back, what is kept). Press **Approve** or **Decline** with the reason in the same row; above your limit it says an Admin approves. Approved: **Issue the refund**.
5. **Export CSV** gives the same rows for the bank or the bookkeeper: refunds as negative amounts, holds marked as not money in.

## Payments, deposits, refunds

**Money**, the **To handle** tab.

1. Failed payments: each with the purpose, amount and the bank''s reason.
2. Deposits to take before pickup, and deposits due back.
3. Refunds in progress. Press **Request the refund** and choose What it refunds (the rental charge, delivery or pickup, kilometres, add-ons or other charges); above your limit it waits for an Admin. Then **Issue the refund**.
4. Owner invoices that failed, and owner statements to prepare.

![](/guides/img/va-finance-02-money-desktop-486a8fbc.jpg "desktop; size: 1230 865; address: carmacars.ca/va/money; pins: 1 10.6 60.3, 2 72.4 21.6, 3 73.2 33.8, 4 11.0 45.9")

## A payment received another way

An owner or renter paid by e-Transfer, cheque, cash or bank transfer.

1. Owner invoice: on **Payments, deposits, refunds**, find it under Owner invoices owing and press **Record payment**.
2. Renter: beside the failed payment, press **Paid another way**. Or open the booking''s Money tab: in Rental charges press Collect (the amount) rental, or in Security deposit Collect (the amount) deposit, choose **Cash, e-Transfer or another way (record it)** and how it was paid, then record it. Each panel collects its own part only.
3. Choose Paid by, the Date received and the Reference (the cheque number for a cheque). Leave Amount empty for the full balance; type less for a partial payment.
4. Add the proof if you have it (a screenshot or a photo of the cheque), then press **Record payment**.

The invoice is marked paid or partly paid, the automatic debit stops for that amount and the owner gets a receipt. Above your single limit the payment needs an Admin. Recorded something wrong? Ask an Admin to void it; you cannot void a payment.

Each month''s payments recorded by hand are listed under Reconciliation, with the totals by method, to check against the bank.

## Cards, holds and deposits given back

On the booking''s Money tab.

1. After the return, **Charge the renter**: the Reason from the list (Other with its note), the Amount, and the line that says where the money comes from (the deposit hold while it is valid, else the card on file, else a pay link) before you press **Charge $...**. Before the return, Rental charges, **A later charge**, with the same reason list on the renter''s receipt. A deposit that cannot be held: Security deposit, **Charge the card on file as the deposit**.
2. A deposit hold, in the Security deposit panel: **Keep part (damage/fees)** with the amount and the reason from the list (the rest is released), or **Release**. **Hold expired**: nothing can be kept from it; press **Charge the card on file instead** (the amount and the reason are filled in). While the car is out, inside the toll window or while something is open, both wait for the settlement; an Admin may do it with the reason.
3. A deposit taken in cash or by e-Transfer is given back the same way: the task Give the deposit back the way it came; then press **Returned** with the reference or receipt number.

## Settle a deposit

The deposit is never given back by itself. Finance or an Admin settles it after the return: on the booking''s Money tab, under Deposit, press **Settle the deposit**. Issue the Check-out statement first.

1. The form shows the deposit, what is still available, the charges owed from the statement and what is taken from the deposit for them. What the deposit does not cover is charged to the card on file; with no card (or a card declined), the renter gets a pay link by email and text, and Finance has a task until it is paid.
2. Tolls and tickets can take up to 7 days to come in. Inside that window the whole rest of the deposit is filled in as the hold-back, until the window ends. To give it back sooner, tick Release now anyway: a toll that comes in later is charged to the card on file.
3. Something still open keeps the whole deposit: an incident, a claim, new damage at the return not priced, damage found later not billed, a toll or ticket on the car during the rental not matched or not charged, a card dispute, or charges not on a statement yet. The form lists them. Only an Admin can release part of it, with the reason; it is recorded.
4. Damage: an Admin keeps the whole deposit (**Keep the whole deposit (damage)**) or bills a damage charge up to the $2,500 deductible. Ask an Admin, with the photos.
5. Press **Settle**. The money moves at Stripe at once: the charges are collected and what is not owed is refunded or the hold released. A step Stripe refuses is tried again by itself, and Finance gets a task if it keeps failing.

> Good to know: A card hold lapses after about 7 days. While the car is out, or returned and not settled, the hold is collected in full a day and a half before it lapses: that keeps the money, and the settlement refunds what is not owed. A hold that lapses anyway is charged to the saved card, and Finance is told at once.

## Read a toll notice

1. Open **Tolls and tickets** and press **Read a notice**.
2. Choose the file: a PDF, a photo or a CSV, under 15 MB. Leave the reading profile to find it from the text.
3. Press **Read it**. Then check each line beside the notice and fix what was read wrong.
4. Press **Checked against the notice** on each line (**Leave out** to skip one), then **Save as checked** and **Confirm and import**.

![](/guides/img/va-finance-04-tolls-read-desktop-aa04a6b2.jpg "desktop; size: 1230 580; address: carmacars.ca/va/tolls/read; pins: 2 19.5 44.1, 3 4.1 64.8, 4 4.1 89.7")

> Tip: In the work queue, **Match again** retries the match after a fix, and **Dispute** marks a notice you think is wrong. Renters matched with high confidence are charged at import, with the notice and our fee.

![The work queue: Unmatched, Needs review, Matched not charged and Disputed, with each notice''s plate, date, amount and match.](/guides/img/va-finance-03-tolls-desktop-37b6f99c.jpg "desktop; size: 1230 540; address: carmacars.ca/va/tolls; pins: 1 23.6 12.2")

## Reconciliation and Turo trips

1. **Money**, the **Reconciliation** tab: press **Record a processor payout**, then **Match** it to the payments it contains. Anything still unmatched at the closing check goes to an Admin.
2. **Turo trips**: press **Add a trip** for one trip, or paste CSV rows and press **Import**.

![](/guides/img/va-finance-06-turo-desktop-b59cc7f9.jpg "desktop; size: 1230 540; address: carmacars.ca/va/turo; pins: 2 95.1 14.8")

## Deposits to release

A deposit is never released by itself. Each morning the system puts one task in your queue for every deposit due back: "Release the deposit for" the booking, with the amount and the day it is due (7 business days after the check-out, or after the return when no check-out was recorded). On the day, and every day after, you and the Admins also get a notice in the portal. Nothing is emailed.

1. Open the task: it opens the booking''s **Money** tab.
2. Settle the deposit: apply what is owed, hold back what an open item needs, release the rest.
3. The task closes by itself once nothing is left to give back.

### Card payments outside the site and the card reader
On a booking''s **Money** tab: **Record card payment** records a card taken in the Stripe Dashboard or on a reader (the last 4 digits always; a Stripe payment id, pi_..., checks it, and a deposit hold needs it). **Charge on reader** and **Hold deposit on reader** send the amount to the S700; the renter taps the card and the screen updates by itself. On a credit card coverage rental the whole rental is paid on the same card: another card is refused with the reason, and only an Admin can allow another one.

## Deposit holds and partner invoices (release 28)

Deposits stay as holds with Stripe and are never captured by itself. A job re-authorizes a hold by itself about 24 hours before it expires; when it cannot, you get the alert **Deposit hold not re-authorized**. A **The deposit hold expires soon** To do opens the booking: **Re-authorize the hold** places a new hold on the saved card and releases the old one; or **Keep part (damage/fees)** for only what is owed. A deposit not taken yet: in the Security deposit panel, **Hold on the card on file**. Under **Money** > **Partner invoices** you write invoices to body shops, tow trucks and storage yards for their kickback, send them, record the cheques and e-Transfers that come in, and export the CSV for the bookkeeper.

## Kickbacks and repairs

**Money** > **Kickbacks and repairs**: the kickbacks received on partner invoices (before HST) and the repair costs paid by CarmaCars for a period, by owner and by car, with the CSV. An invoice with no car counts nowhere until you choose it: open the invoice under **Partner invoices** and press **Choose the car**. Add a repair cost with **Add a repair cost**; Fleet adds them on the car''s page too.

### A debit deposit''s card fee
A deposit charged (not held) on a debit or prepaid card carries the non-refundable **Card processing fee for a debit deposit**, shown on its line in the history and on the receipt. The deposit refund returns the deposit only.

## Partners, the timesheet and ended trips

1. **More finance** > **Partners**: the rental partners (their pages, cars, rates, invoices) and the referral partners (kickbacks, payments), with every action an Admin has there.
2. **Hours** > **Timesheet**: the hours customer service, Fleet and Finance clocked. Add forgotten hours or void a wrong entry, with the reason.
3. **Close ended trips**: mark trips that ended and were never closed, and choose the deposit decision. An Admin presses Release; nothing is released by itself.


## Deposit review: double-check, tolls and tickets, then bill or release

Once Fleet signed every item of a returned booking you get a To do to double-check the deposit review. The deposit stays held until you signed every item too; only an Admin can release it earlier, with the reason.

1. Open **Money** > **Deposit reviews** and open the booking.
2. Press **Double-check** on each item: read Fleet''s finding and the photos, then **OK** or **Issue** with the amount to bill. Someone else double-checks an item you signed for Fleet.
3. **Highway tolls**: open the toll operator''s site from the review, search the plate for the rental dates, then double-check the item.
4. **Tickets**: open each place in the list (its official lookup link), search the plate, and press **None found** or **A ticket**. A ticket is logged in **Tolls and tickets** with the place and the plate and matched to the booking there. The Tickets item waits until every place is checked.
5. Then open **Money** on the booking: bill what is owed with the charge after the return, or release the deposit.

### The sweep, Monday, Wednesday and Friday
On each sweep day a To do **Deposit check sweep** lists every plate returned since the last sweep and every booking still inside the toll and ticket window. **Deposit reviews** > **This sweep** shows them by plate with every link, so you check them in one go. The days are in Program settings.

### Countdowns
**Money** > **Countdowns** (and the top of **To handle**, and each booking) shows the time left before each deposit hold expires (with when the automatic re-authorization runs, 24 hours before), before each deposit is due back to the renter, and before the next payment of a weekly, biweekly or monthly plan. Red is within 24 hours or late, amber within 48. Sort by any column. You get an alert at 48 and 24 hours, and the counts are in your morning digest.

### Do sales too
Under **My numbers** > **Do sales too**, press **I want to do sales too**: the Sales path is added to your academy (your Finance work is never held by it), and the Sales pages open once you pass it.


## The fuel line on the deposit review (release 35)

The fuel item shows **Suggested** with its working: the tank x the fuel missing x the pump price x 1.25, plus the $20 refuelling fee. It is a line on the return charges, never charged by itself: sign the item, then bill it with the rest from the booking''s Money. A pump receipt still wins: enter it when the car was filled up.

## Statements and payroll (release 35)

- Statements cover the 8th to the 7th, paid on the 10th; amounts not yet collected from the renter are listed apart and paid on the statement after they come in.
- Payroll every two weeks: prepare the run with any bonus or deduction and its reason, then send it for approval. An Admin approves and records the payments.
- Email: Settings, Usage shows the real daily capacity of our sending services together; nothing to count by hand.

## Calls first, texts after (release 37)

Your main priority is always to be on the phone with people.

1. Answer a ringing call before anything else, and return a missed call at once.
2. **Call before you text.** On a lead, a renter or a booking, **Call** is the first button and **Text** the second.
3. A text is a follow-up: after a call attempt (no answer, a voicemail left), or when the person asked for a text.
4. On your To do and on **Unanswered**, missed calls and call-backs are listed above unanswered texts.',
  '<p class="gd-p">You keep the money right: payments, deposits and refunds, toll notices, processor payouts and Turo trips. There is no commission for Finance, but your help is credited on the booking (Helped by) and on your scorecard.</p><p class="gd-p">Your rail: Queue, Today, Money, Tolls and tickets, Turo trips, Find a renter, Calendar and Scorecard. <b class="gd-ui">Money</b> opens with a row of tabs on top, as in Admin: <b class="gd-ui">To handle</b> (payments, deposits, refunds), <b class="gd-ui">By day</b> (with Today, 7 days, 30 days and 90 days), <b class="gd-ui">All payments</b>, <b class="gd-ui">Refunds</b>, <b class="gd-ui">Deposits</b>, <b class="gd-ui">Reconciliation</b> and <b class="gd-ui">Unlinked Stripe</b> (the Stripe payments of the last 60 days that no booking knows, checked every night, with a best guess of the booking: an Admin links one from the booking&#39;s Money tab; put one aside with the reason when it is not a booking&#39;s payment). <b class="gd-ui">Owner money</b> lists every owner invoice and owner statement. The old Payments by day and Reconciliation addresses open their tabs.</p><section class="gd-task" id="finance-your-queue" data-gd-task><h2 class="gd-h2">Your queue</h2><p class="gd-p">Finance tasks include failed owner debits, toll notices with no match, statements to review and refunds to issue.</p><div class="gd-figblock"><figure class="gd-fig gd-fig--desk"><div class="gd-browser"><div class="gd-bar" aria-hidden="true"><i></i><i></i><i></i><span class="gd-addr">carmacars.ca/va</span></div><div class="gd-imgwrap" style="aspect-ratio:1230/940"><img src="/guides/img/va-finance-01-queue-desktop-2f37513d.jpg" alt="The lanes show what Finance handles: payments to fix, refunds waiting, tolls and tickets, deposits to settle and owner statements. Money today counts them below." loading="lazy" decoding="async" width="1230" height="940"><span class="gd-pin" style="left:20.3%;top:24.3%" aria-hidden="true">1</span></div></div><figcaption>The lanes show what Finance handles: payments to fix, refunds waiting, tolls and tickets, deposits to settle and owner statements. Money today counts them below.</figcaption></figure></div></section><section class="gd-task" id="finance-payments-by-day" data-gd-task><h2 class="gd-h2">Payments by day</h2><p class="gd-p"><b class="gd-ui">Money</b>, the <b class="gd-ui">By day</b> tab, is your day in one screen: every payment and refund, by method, with the cash drawer and the refunds to decide.</p><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">Choose From and To (today by default) and tick the methods you want (card, e-Transfer, cash, cheque, platform payout, insurer and others; none ticked shows all), then press <b class="gd-ui">Show</b>.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Totals by method: received, refunded and net. Each day: the same by method, the cash expected in the drawer (cash received less cash given back) and the cash counted.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">At the end of the day count the drawer and press <b class="gd-ui">Record the count</b>. The difference shows &quot;balanced&quot;, or &quot;over&quot; or &quot;short&quot; with the amount.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t">Refunds waiting: every refund asked for anywhere (a cancellation, a booking, Finance), with the policy maths (paid, the tier, the percentage back, what is kept). Press <b class="gd-ui">Approve</b> or <b class="gd-ui">Decline</b> with the reason in the same row; above your limit it says an Admin approves. Approved: <b class="gd-ui">Issue the refund</b>.</div></li><li><span class="gd-n" aria-hidden="true">5</span><div class="gd-t"><b class="gd-ui">Export CSV</b> gives the same rows for the bank or the bookkeeper: refunds as negative amounts, holds marked as not money in.</div></li></ol></div></section><section class="gd-task" id="finance-payments-deposits-refunds" data-gd-task><h2 class="gd-h2">Payments, deposits, refunds</h2><p class="gd-p"><b class="gd-ui">Money</b>, the <b class="gd-ui">To handle</b> tab.</p><div class="gd-stepblock gd-stepblock--below"><div class="gd-stepcol"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">Failed payments: each with the purpose, amount and the bank&#39;s reason.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Deposits to take before pickup, and deposits due back.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Refunds in progress. Press <b class="gd-ui">Request the refund</b> and choose What it refunds (the rental charge, delivery or pickup, kilometres, add-ons or other charges); above your limit it waits for an Admin. Then <b class="gd-ui">Issue the refund</b>.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t">Owner invoices that failed, and owner statements to prepare.</div></li></ol></div><figure class="gd-fig gd-fig--desk"><div class="gd-browser"><div class="gd-bar" aria-hidden="true"><i></i><i></i><i></i><span class="gd-addr">carmacars.ca/va/money</span></div><div class="gd-imgwrap" style="aspect-ratio:1230/865"><img src="/guides/img/va-finance-02-money-desktop-486a8fbc.jpg" alt="" loading="lazy" decoding="async" width="1230" height="865"><span class="gd-pin" style="left:10.6%;top:60.3%" aria-hidden="true">1</span><span class="gd-pin" style="left:72.4%;top:21.6%" aria-hidden="true">2</span><span class="gd-pin" style="left:73.2%;top:33.8%" aria-hidden="true">3</span><span class="gd-pin" style="left:11%;top:45.9%" aria-hidden="true">4</span></div></div></figure></div></section><section class="gd-task" id="finance-a-payment-received-another-way" data-gd-task><h2 class="gd-h2">A payment received another way</h2><p class="gd-p">An owner or renter paid by e-Transfer, cheque, cash or bank transfer.</p><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">Owner invoice: on <b class="gd-ui">Payments, deposits, refunds</b>, find it under Owner invoices owing and press <b class="gd-ui">Record payment</b>.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Renter: beside the failed payment, press <b class="gd-ui">Paid another way</b>. Or open the booking&#39;s Money tab: in Rental charges press Collect (the amount) rental, or in Security deposit Collect (the amount) deposit, choose <b class="gd-ui">Cash, e-Transfer or another way (record it)</b> and how it was paid, then record it. Each panel collects its own part only.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Choose Paid by, the Date received and the Reference (the cheque number for a cheque). Leave Amount empty for the full balance; type less for a partial payment.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t">Add the proof if you have it (a screenshot or a photo of the cheque), then press <b class="gd-ui">Record payment</b>.</div></li></ol></div><p class="gd-p">The invoice is marked paid or partly paid, the automatic debit stops for that amount and the owner gets a receipt. Above your single limit the payment needs an Admin. Recorded something wrong? Ask an Admin to void it; you cannot void a payment.</p><p class="gd-p">Each month&#39;s payments recorded by hand are listed under Reconciliation, with the totals by method, to check against the bank.</p></section><section class="gd-task" id="finance-cards-holds-and-deposits-given-back" data-gd-task><h2 class="gd-h2">Cards, holds and deposits given back</h2><p class="gd-p">On the booking&#39;s Money tab.</p><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">After the return, <b class="gd-ui">Charge the renter</b>: the Reason from the list (Other with its note), the Amount, and the line that says where the money comes from (the deposit hold while it is valid, else the card on file, else a pay link) before you press <b class="gd-ui">Charge $...</b>. Before the return, Rental charges, <b class="gd-ui">A later charge</b>, with the same reason list on the renter&#39;s receipt. A deposit that cannot be held: Security deposit, <b class="gd-ui">Charge the card on file as the deposit</b>.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">A deposit hold, in the Security deposit panel: <b class="gd-ui">Keep part (damage/fees)</b> with the amount and the reason from the list (the rest is released), or <b class="gd-ui">Release</b>. <b class="gd-ui">Hold expired</b>: nothing can be kept from it; press <b class="gd-ui">Charge the card on file instead</b> (the amount and the reason are filled in). While the car is out, inside the toll window or while something is open, both wait for the settlement; an Admin may do it with the reason.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">A deposit taken in cash or by e-Transfer is given back the same way: the task Give the deposit back the way it came; then press <b class="gd-ui">Returned</b> with the reference or receipt number.</div></li></ol></div></section><section class="gd-task" id="finance-settle-a-deposit" data-gd-task><h2 class="gd-h2">Settle a deposit</h2><p class="gd-p">The deposit is never given back by itself. Finance or an Admin settles it after the return: on the booking&#39;s Money tab, under Deposit, press <b class="gd-ui">Settle the deposit</b>. Issue the Check-out statement first.</p><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">The form shows the deposit, what is still available, the charges owed from the statement and what is taken from the deposit for them. What the deposit does not cover is charged to the card on file; with no card (or a card declined), the renter gets a pay link by email and text, and Finance has a task until it is paid.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Tolls and tickets can take up to 7 days to come in. Inside that window the whole rest of the deposit is filled in as the hold-back, until the window ends. To give it back sooner, tick Release now anyway: a toll that comes in later is charged to the card on file.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Something still open keeps the whole deposit: an incident, a claim, new damage at the return not priced, damage found later not billed, a toll or ticket on the car during the rental not matched or not charged, a card dispute, or charges not on a statement yet. The form lists them. Only an Admin can release part of it, with the reason; it is recorded.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t">Damage: an Admin keeps the whole deposit (<b class="gd-ui">Keep the whole deposit (damage)</b>) or bills a damage charge up to the $2,500 deductible. Ask an Admin, with the photos.</div></li><li><span class="gd-n" aria-hidden="true">5</span><div class="gd-t">Press <b class="gd-ui">Settle</b>. The money moves at Stripe at once: the charges are collected and what is not owed is refunded or the hold released. A step Stripe refuses is tried again by itself, and Finance gets a task if it keeps failing.</div></li></ol></div><aside class="gd-box"><span class="gd-lbl">Good to know</span><div>A card hold lapses after about 7 days. While the car is out, or returned and not settled, the hold is collected in full a day and a half before it lapses: that keeps the money, and the settlement refunds what is not owed. A hold that lapses anyway is charged to the saved card, and Finance is told at once.</div></aside></section><section class="gd-task" id="finance-read-a-toll-notice" data-gd-task><h2 class="gd-h2">Read a toll notice</h2><div class="gd-stepblock gd-stepblock--below"><div class="gd-stepcol"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">Open <b class="gd-ui">Tolls and tickets</b> and press <b class="gd-ui">Read a notice</b>.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Choose the file: a PDF, a photo or a CSV, under 15 MB. Leave the reading profile to find it from the text.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Press <b class="gd-ui">Read it</b>. Then check each line beside the notice and fix what was read wrong.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t">Press <b class="gd-ui">Checked against the notice</b> on each line (<b class="gd-ui">Leave out</b> to skip one), then <b class="gd-ui">Save as checked</b> and <b class="gd-ui">Confirm and import</b>.</div></li></ol></div><figure class="gd-fig gd-fig--desk"><div class="gd-browser"><div class="gd-bar" aria-hidden="true"><i></i><i></i><i></i><span class="gd-addr">carmacars.ca/va/tolls/read</span></div><div class="gd-imgwrap" style="aspect-ratio:1230/580"><img src="/guides/img/va-finance-04-tolls-read-desktop-aa04a6b2.jpg" alt="" loading="lazy" decoding="async" width="1230" height="580"><span class="gd-pin" style="left:19.5%;top:44.1%" aria-hidden="true">2</span><span class="gd-pin" style="left:4.1%;top:64.8%" aria-hidden="true">3</span><span class="gd-pin" style="left:4.1%;top:89.7%" aria-hidden="true">4</span></div></div></figure></div><aside class="gd-box"><span class="gd-lbl">Tip</span><div>In the work queue, <b class="gd-ui">Match again</b> retries the match after a fix, and <b class="gd-ui">Dispute</b> marks a notice you think is wrong. Renters matched with high confidence are charged at import, with the notice and our fee.</div></aside><div class="gd-figblock"><figure class="gd-fig gd-fig--desk"><div class="gd-browser"><div class="gd-bar" aria-hidden="true"><i></i><i></i><i></i><span class="gd-addr">carmacars.ca/va/tolls</span></div><div class="gd-imgwrap" style="aspect-ratio:1230/540"><img src="/guides/img/va-finance-03-tolls-desktop-37b6f99c.jpg" alt="The work queue: Unmatched, Needs review, Matched not charged and Disputed, with each notice&#39;s plate, date, amount and match." loading="lazy" decoding="async" width="1230" height="540"><span class="gd-pin" style="left:23.6%;top:12.2%" aria-hidden="true">1</span></div></div><figcaption>The work queue: Unmatched, Needs review, Matched not charged and Disputed, with each notice&#39;s plate, date, amount and match.</figcaption></figure></div></section><section class="gd-task" id="finance-reconciliation-and-turo-trips" data-gd-task><h2 class="gd-h2">Reconciliation and Turo trips</h2><div class="gd-stepblock gd-stepblock--below"><div class="gd-stepcol"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t"><b class="gd-ui">Money</b>, the <b class="gd-ui">Reconciliation</b> tab: press <b class="gd-ui">Record a processor payout</b>, then <b class="gd-ui">Match</b> it to the payments it contains. Anything still unmatched at the closing check goes to an Admin.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t"><b class="gd-ui">Turo trips</b>: press <b class="gd-ui">Add a trip</b> for one trip, or paste CSV rows and press <b class="gd-ui">Import</b>.</div></li></ol></div><figure class="gd-fig gd-fig--desk"><div class="gd-browser"><div class="gd-bar" aria-hidden="true"><i></i><i></i><i></i><span class="gd-addr">carmacars.ca/va/turo</span></div><div class="gd-imgwrap" style="aspect-ratio:1230/540"><img src="/guides/img/va-finance-06-turo-desktop-b59cc7f9.jpg" alt="" loading="lazy" decoding="async" width="1230" height="540"><span class="gd-pin" style="left:95.1%;top:14.8%" aria-hidden="true">2</span></div></div></figure></div></section><section class="gd-task" id="finance-deposits-to-release" data-gd-task><h2 class="gd-h2">Deposits to release</h2><p class="gd-p">A deposit is never released by itself. Each morning the system puts one task in your queue for every deposit due back: &quot;Release the deposit for&quot; the booking, with the amount and the day it is due (7 business days after the check-out, or after the return when no check-out was recorded). On the day, and every day after, you and the Admins also get a notice in the portal. Nothing is emailed.</p><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">Open the task: it opens the booking&#39;s <b class="gd-ui">Money</b> tab.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Settle the deposit: apply what is owed, hold back what an open item needs, release the rest.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">The task closes by itself once nothing is left to give back.</div></li></ol></div><h3 class="gd-h3">Card payments outside the site and the card reader</h3><p class="gd-p">On a booking&#39;s <b class="gd-ui">Money</b> tab: <b class="gd-ui">Record card payment</b> records a card taken in the Stripe Dashboard or on a reader (the last 4 digits always; a Stripe payment id, pi_..., checks it, and a deposit hold needs it). <b class="gd-ui">Charge on reader</b> and <b class="gd-ui">Hold deposit on reader</b> send the amount to the S700; the renter taps the card and the screen updates by itself. On a credit card coverage rental the whole rental is paid on the same card: another card is refused with the reason, and only an Admin can allow another one.</p></section><section class="gd-task" id="finance-deposit-holds-and-partner-invoices-release-28" data-gd-task><h2 class="gd-h2">Deposit holds and partner invoices (release 28)</h2><p class="gd-p">Deposits stay as holds with Stripe and are never captured by itself. A job re-authorizes a hold by itself about 24 hours before it expires; when it cannot, you get the alert <b class="gd-ui">Deposit hold not re-authorized</b>. A <b class="gd-ui">The deposit hold expires soon</b> To do opens the booking: <b class="gd-ui">Re-authorize the hold</b> places a new hold on the saved card and releases the old one; or <b class="gd-ui">Keep part (damage/fees)</b> for only what is owed. A deposit not taken yet: in the Security deposit panel, <b class="gd-ui">Hold on the card on file</b>. Under <b class="gd-ui">Money</b> &gt; <b class="gd-ui">Partner invoices</b> you write invoices to body shops, tow trucks and storage yards for their kickback, send them, record the cheques and e-Transfers that come in, and export the CSV for the bookkeeper.</p></section><section class="gd-task" id="finance-kickbacks-and-repairs" data-gd-task><h2 class="gd-h2">Kickbacks and repairs</h2><p class="gd-p"><b class="gd-ui">Money</b> &gt; <b class="gd-ui">Kickbacks and repairs</b>: the kickbacks received on partner invoices (before HST) and the repair costs paid by CarmaCars for a period, by owner and by car, with the CSV. An invoice with no car counts nowhere until you choose it: open the invoice under <b class="gd-ui">Partner invoices</b> and press <b class="gd-ui">Choose the car</b>. Add a repair cost with <b class="gd-ui">Add a repair cost</b>; Fleet adds them on the car&#39;s page too.</p><h3 class="gd-h3">A debit deposit&#39;s card fee</h3><p class="gd-p">A deposit charged (not held) on a debit or prepaid card carries the non-refundable <b class="gd-ui">Card processing fee for a debit deposit</b>, shown on its line in the history and on the receipt. The deposit refund returns the deposit only.</p></section><section class="gd-task" id="finance-partners-the-timesheet-and-ended-trips" data-gd-task><h2 class="gd-h2">Partners, the timesheet and ended trips</h2><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t"><b class="gd-ui">More finance</b> &gt; <b class="gd-ui">Partners</b>: the rental partners (their pages, cars, rates, invoices) and the referral partners (kickbacks, payments), with every action an Admin has there.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t"><b class="gd-ui">Hours</b> &gt; <b class="gd-ui">Timesheet</b>: the hours customer service, Fleet and Finance clocked. Add forgotten hours or void a wrong entry, with the reason.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t"><b class="gd-ui">Close ended trips</b>: mark trips that ended and were never closed, and choose the deposit decision. An Admin presses Release; nothing is released by itself.</div></li></ol></div></section><section class="gd-task" id="finance-deposit-review-double-check-tolls-and-tickets-then-bill-or-r" data-gd-task><h2 class="gd-h2">Deposit review: double-check, tolls and tickets, then bill or release</h2><p class="gd-p">Once Fleet signed every item of a returned booking you get a To do to double-check the deposit review. The deposit stays held until you signed every item too; only an Admin can release it earlier, with the reason.</p><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">Open <b class="gd-ui">Money</b> &gt; <b class="gd-ui">Deposit reviews</b> and open the booking.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Press <b class="gd-ui">Double-check</b> on each item: read Fleet&#39;s finding and the photos, then <b class="gd-ui">OK</b> or <b class="gd-ui">Issue</b> with the amount to bill. Someone else double-checks an item you signed for Fleet.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t"><b class="gd-ui">Highway tolls</b>: open the toll operator&#39;s site from the review, search the plate for the rental dates, then double-check the item.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t"><b class="gd-ui">Tickets</b>: open each place in the list (its official lookup link), search the plate, and press <b class="gd-ui">None found</b> or <b class="gd-ui">A ticket</b>. A ticket is logged in <b class="gd-ui">Tolls and tickets</b> with the place and the plate and matched to the booking there. The Tickets item waits until every place is checked.</div></li><li><span class="gd-n" aria-hidden="true">5</span><div class="gd-t">Then open <b class="gd-ui">Money</b> on the booking: bill what is owed with the charge after the return, or release the deposit.</div></li></ol></div><h3 class="gd-h3">The sweep, Monday, Wednesday and Friday</h3><p class="gd-p">On each sweep day a To do <b class="gd-ui">Deposit check sweep</b> lists every plate returned since the last sweep and every booking still inside the toll and ticket window. <b class="gd-ui">Deposit reviews</b> &gt; <b class="gd-ui">This sweep</b> shows them by plate with every link, so you check them in one go. The days are in Program settings.</p><h3 class="gd-h3">Countdowns</h3><p class="gd-p"><b class="gd-ui">Money</b> &gt; <b class="gd-ui">Countdowns</b> (and the top of <b class="gd-ui">To handle</b>, and each booking) shows the time left before each deposit hold expires (with when the automatic re-authorization runs, 24 hours before), before each deposit is due back to the renter, and before the next payment of a weekly, biweekly or monthly plan. Red is within 24 hours or late, amber within 48. Sort by any column. You get an alert at 48 and 24 hours, and the counts are in your morning digest.</p><h3 class="gd-h3">Do sales too</h3><p class="gd-p">Under <b class="gd-ui">My numbers</b> &gt; <b class="gd-ui">Do sales too</b>, press <b class="gd-ui">I want to do sales too</b>: the Sales path is added to your academy (your Finance work is never held by it), and the Sales pages open once you pass it.</p></section><section class="gd-task" id="finance-the-fuel-line-on-the-deposit-review-release-35" data-gd-task><h2 class="gd-h2">The fuel line on the deposit review (release 35)</h2><p class="gd-p">The fuel item shows <b class="gd-ui">Suggested</b> with its working: the tank x the fuel missing x the pump price x 1.25, plus the $20 refuelling fee. It is a line on the return charges, never charged by itself: sign the item, then bill it with the rest from the booking&#39;s Money. A pump receipt still wins: enter it when the car was filled up.</p></section><section class="gd-task" id="finance-statements-and-payroll-release-35" data-gd-task><h2 class="gd-h2">Statements and payroll (release 35)</h2><ul class="gd-ul"><li>Statements cover the 8th to the 7th, paid on the 10th; amounts not yet collected from the renter are listed apart and paid on the statement after they come in.</li><li>Payroll every two weeks: prepare the run with any bonus or deduction and its reason, then send it for approval. An Admin approves and records the payments.</li><li>Email: Settings, Usage shows the real daily capacity of our sending services together; nothing to count by hand.</li></ul></section><section class="gd-task" id="finance-calls-first-texts-after-release-37" data-gd-task><h2 class="gd-h2">Calls first, texts after (release 37)</h2><p class="gd-p">Your main priority is always to be on the phone with people.</p><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">Answer a ringing call before anything else, and return a missed call at once.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t"><b class="gd-ui">Call before you text.</b> On a lead, a renter or a booking, <b class="gd-ui">Call</b> is the first button and <b class="gd-ui">Text</b> the second.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">A text is a follow-up: after a call attempt (no answer, a voicemail left), or when the person asked for a text.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t">On your To do and on <b class="gd-ui">Unanswered</b>, missed calls and call-backs are listed above unanswered texts.</div></li></ol></div></section>');
select app.guide_release_section('va', 'fleet', 'chapter', 'finance', 'You keep the cars moving: field jobs, daily checks, photo reviews after returns, and the listings with their duplicate check and plate covering.

Your rail: Queue, Today, Field jobs, Field hours, Daily checks, Photo reviews, Calendar, Listings, Similar cars, Find a renter and Scorecard.

## Schedule field jobs

Every confirmed booking gets its handover (or delivery) and return (or pickup) jobs by itself, at the booking''s times and place, and put on a shift: the shift covering its time, or that day''s (see Shifts and who gets a job). The people on the shift share its jobs, least busy first. You check and change them.

1. Jobs, next three days: each with its place, its shift, its field staff and whether they acknowledged it. "Made from the booking" marks the ones made by themselves; when the booking moves, they move too, unless you changed them.
2. Change a job with **To a shift** (another shift), **Assign** or **Reassign** (a field person on a shift that day when the day has shifts, or an Admin), **Move** (time and place) or **Cancel**.
3. Handovers and returns without a job (when the automatic jobs are off, or one was cancelled) are listed first: press **Schedule**, the place filled in from the booking.
4. An Admin turns the automatic jobs or the assignment off in Settings > Program.

![](/guides/img/va-fleet-02-field-jobs-desktop-8e721230.jpg "desktop; size: 1230 565; address: carmacars.ca/va/fleet; pins: 1 17.9 51.3")

## Shifts and who gets a job

Field staff take their shifts from a schedule you publish, ideally a week ahead. A job is given by itself only to a field person who passed the academy and holds a shift that day, and work lands only on days with shifts.

1. On **Field jobs**, **Shifts, next seven days** shows each day and how many people are on a shift, and each shift its jobs (**Jobs on it**). A shift with jobs and nobody on it is marked; within 24 hours of its start you get an alert and a To do, once.
2. Press **Publish shifts**: the first day''s start and end, how many people, and for how many days the same hours repeat. Field staff take them on their phones.
3. **Add a person** puts someone on a shift and **Remove** takes them off. A person who has not passed the academy cannot take shifts or be given a job.
4. A shift nobody claimed keeps its jobs: field staff see them when they look for shifts to claim, and the one who claims it gets them. A shift given up or swapped takes its jobs along; a cancelled shift sends them to another shift.
5. Work due on a day with no shifts moves to the day before when it is known in advance, or to the next day with shifts when it comes in on the day. The job shows its planned day and keeps the booking''s real time; the renter''s times never change. A booking whose handover or return falls on a day with no shifts shows a warning: cover it, or move the booking time.
6. **Unassign** takes a job off its person and its shift; tick **Tell them** only if they should know. The Admins can be given a job too (no shift needed).

## Fleet map

At the top of **Field jobs**: every car on the map with its renter, booking, due-back time and state, the alerts, and the trips by booking, the same as the Admin''s. Only Admins and fleet staff see positions.

1. Press a car for its card: last report, odometer, fuel, tracker battery and the trip under way.
2. An alert (speeding, left Ontario or the zone, still driving after the return time, low or unplugged tracker, not reporting) also comes to your bell and as an urgent phone alert. Call the renter, then press **Seen**.
3. A car still driving after its return time: call, send the late notice and offer a paid extension, as for any late return.

## Field hours

Field staff clock in and out on their phones. You see who is clocked in and every shift of the two-week pay period, and you fix what they cannot.

1. Open **Field hours**. **Clocked in now** lists who is on, since when. **Earlier period** and **Later period** move between pay periods.
2. Someone forgot to clock out: press **Clock out for them**, set the time they finished and write the reason.
3. Someone forgot to clock in, or a time is wrong: **Add hours** enters a shift, **Change** fixes one and **Remove** takes one out. Each needs a reason; the change is kept in a log with what it was before.
4. Once an Admin approves the pay run of a period, its shifts are locked: ask the Admin. You see hours only, not rates or pay.

### Where they clocked in
The hours list shows where each person clocked in and out: a map link and the distance from the lot. A clock in or out over 500 m away, or with the location refused, is shown in bold with the reason the person wrote. Their location is asked only at those two moments, never in between.

## Daily checks

Twice a day: the opening check by 9:00 and the closing check by 18:00.

1. Open **Daily checks** and choose **Opening check** or **Closing check**.
2. Each line shows what was found. Tick OK, or Problem with a note.
3. Press **Save the opening check** (or **Save the closing check**). You can save it again.

![](/guides/img/va-fleet-03-daily-checks-desktop-be06d6c0.jpg "desktop; size: 1230 820; address: carmacars.ca/va/checks; pins: 1 6.5 15.4, 2 44.7 42.0, 3 64.2 94.0")

## Check a car out or in

Fleet, Sales and Customer service check cars out and in from the booking.

1. On a confirmed booking press **Check in (pickup)**; on a booking on rent, **Check out (return)**. Today lists the ones due, each with its button.
2. The checklist field staff use opens: readings (km and fuel or charge), the photo set with the plate and the gauges, damage close-ups and both signatures.
3. Afterwards press **Photo report**: times, Late by, kilometres, fuel, photos and the return charges. Fleet waives a charge with **Waive** and a reason.

## Photo reviews after a return

After each return, the field photo set waits under **Photo reviews**. Compare it with the pickup set. Press **Review done**, or **Ask for a re-shoot** if a photo is missing or unclear.

## Similar cars

A possible duplicate never keeps a car off the site: it shows on the car''s checklist until you decide. Only Same car takes it off.

1. Each flag shows the car, what it looks like (same VIN, plate, photo or specs) and the other car.
2. Compare the permit, the plate and the photos.
3. Press **Not a duplicate** with a note when they are different cars, or **Same car** when they are.

![](/guides/img/va-fleet-06-similar-cars-desktop-562b0382.jpg "desktop; size: 1230 460; address: carmacars.ca/va/similar-cars; pins: 1 23.6 30.4, 3 94.8 30.4")

## Rates and kilometres

From a listing, press **The car and its rates**, or open the car from Field jobs and its **Rates & fees** tab.

1. Type the rates an Admin set. Only the daily rate is needed; the others follow from it when empty. The weekend rate is a price per day for each day that starts on a Friday or Saturday.
2. Keep **Use the defaults** for the kilometres, or choose **Custom for this car**.
3. Check What renters pay under the fields, then press **Save the rates**. Rates, kilometres and deposit save together.
4. **Price limits**, below: the lowest and highest daily rate the owner accepts, read only. Offers, promo codes and lead-time pricing stay between them; an Admin or the owner changes them, and only an Admin allows one booking outside them.

## Listings and covering plates

1. Open **Listings**. A draft waiting shows Needs review. Open it.
2. The copy is written by itself (change a line only if you must: it is then kept). Check the photos: on each public photo, cover the plate or mark it not visible.

![](/guides/img/va-fleet-05-listings-desktop-d2672e0a.jpg "desktop; size: 1230 340; address: carmacars.ca/va/listings; pins: 1 54.5 49.1")

3. The listing''s Steps to go live says what is next: 1 Photos, 2 Cover plates, 3 Review, 4 Live on the site, each with its button. The plate box is suggested by itself on every outside photo as the listing opens (Box suggested). Press **Cover the plate** and check it; **Suggest the plate** asks again. A photo filed under the wrong shot: **Remove** under it on the Photos card, then take the right one.
4. Drag over a plate to draw a box; drag a box to move it, its corner to resize it.
5. Keep **The CARMA Ontario plate** on a rear plate or **Edit the front plate out** on a front photo (or choose **A CarmaCars plate**, **Pixelation** or **Blur**), then **Save the covered photo**.
6. No plate in the shot? **No plate visible on this photo**.

![](/guides/img/admin-11-plate-editor-phone-95d5afd2.jpg "phone; size: 390 776; pins: 3 52.6 78.9, 4 50.0 43.8, 5 61.5 62.1, 6 43.1 92.3")

> Watch out: The plate check never holds a car back: a photo whose plate is not checked stays private, and goes public by itself once it is covered or marked. The covered photo replaces the public one; the original is kept privately.

## Missing angles and short videos

On a listing, below First photo (Sales: in the Marketplace kit of the car).

1. A required angle with no photo? Fleet and Sales press **Make** and the angle (for example **Make Rear**): the image model makes the view from the car''s photos, within its free daily use. Check it is the same car, then **Approve** or **Reject**.
2. Press **Make a short video** for a 9:16 video of the car''s approved photos with the price and the call to action. Keep the tab in front until it says Saved, then **Download** it or schedule it on your Marketing page (Scheduled posts).

> Watch out: An AI view shows on the site after the real photos, labelled AI view. It is never the cover and never damage or condition evidence. A real photo always replaces it.

## Publish now

Customer service and fleet publish a car themselves; nothing has to be finished first.

1. Open the car from Listings or Field jobs. Its listing says why it is not on the site yet; press **Publish now**. With no rates yet it uses the suggested rates (similar cars, else the class defaults).
2. What is still open (paperwork, details, photos, No VIN yet for a car added by its plate, a possible duplicate) shows as warnings after Publish now and on the car. None of them stops publishing.
3. New cars with their rates usually go on the site by themselves (Publish new cars automatically, on by default). A car taken off the site by staff waits for Publish now.

> Tip: A car not on the fleet insurance policy yet can be requested, offered and paid for, but never handed over until the insurer confirms it. Requests and offers for such a car show a warning.

## Calendar sync with Turo and other platforms

**Cars** > **Calendar sync**: a car listed on Turo or Getaround must never be booked twice.

1. Turo has no calendar link: Turo''s trip emails come in by themselves, find their car by themselves (Turo car number, plate, VIN, year, make, model, trim, colour, what earlier emails taught) and block it with the turnaround. Nothing to set up per car.
2. An email the reader cannot place waits as "Which car is this?": press **Which car is this?** and press the right car (best guesses first). It is remembered for that car''s next emails. If the dates or trip number are missing: **Add as a Turo trip** (choose the car, check the dates) or **Dismiss**. A trip whose email did not come: **Add a Turo trip** on the car.
3. Each Turo trip shows the guest''s name and phone when Turo''s email includes them. Contact a Turo guest only about their trip, never with promotions.
4. Turo cannot read our calendar: under "Block on Turo", block each CarmaCars booking on the car''s Turo calendar, then press **Done on Turo**. Dates that changed or a booking cancelled here show the dates to free on Turo.
5. Getaround, Google Calendar or another platform with a calendar (iCal) link: open **Add a calendar link**, choose the platform, paste it and press **Add the link**. Copy the car''s CarmaCars link for that platform with **Copy** and paste it into the platform''s calendar import.
6. A double booking raises an urgent task for you and an email: move, swap or cancel one trip. A link that stops working raises a task after 3 failed reads: copy it from the platform again.

### Add the photos and readings
A pickup or return recorded with the details later gives Fleet the task **Add the photos and readings for CC-...**. Open the booking and press **Add the check-in (or check-out) photos and readings**: the usual checklist opens without the ready check or the renter''s signature. Take the photos, the odometer, fuel, keys (and cleanliness at a return), sign and save. The task closes by itself; it cannot be closed by hand before.

## Bookings now

**Rentals** > **Bookings** opens on Now for fleet and customer service: the cars out with their renter and due-back countdown, coming back today and tomorrow (overdue first, in red), going out in the next 72 hours with what is ready, the money due in 7 days and the free cars. It refreshes by itself every 30 seconds. A booking listed as **Out (pickup not recorded)** left without a check-in: press **Mark picked up**, then add the photos, km and fuel from the task. A car overdue or due back today has **Returned** (here, on Today and at the top of the booking): give the return time (now, or earlier; the late charges follow it) and the km and fuel if known. The overdue messages stop and the task for the photos is yours. The search above it finds any booking.

### The renter says the car is back

An urgent To do "The renter says the car is back" means the renter pressed **I''ve returned the car** on an overdue booking. Their overdue notices are paused. Open the booking, check the car (place, tracker, the renter''s photos), then press **Confirm** (correct the odometer, fuel or time first if needed; the trip is completed) or **Deny** with the reason (the renter is told and the notices start again).

**Start a listing** takes the VIN from the car: **Scan the barcode** in the door frame or under the windshield, or **Photo of the VIN**.

**Add photos** on a listing takes any number of photos at once, in any order: each is sorted to its shot. A photo that fits no shot goes in with **Extra outside photos** or **Extra inside and detail photos**; drag the extras into their order in the review and press **Save the order**. 10 photos and one outside photo complete the listing. Outside photos are framed big on the studio floor with a shadow under the tyres; a watermark or caption at a photo''s edge is cut off by itself. **Cover the plate** opens with the plate box suggested: check it and save. A car small in the frame, or no model name behind it: press **Frame the outside photos again** (then check the plates again). A bad cut-out (a mirror missing, background left): press **Edit the cut-out**, erase or restore with the brush, move or size the car on the studio, then **Save as a new version**. The version before is kept; if the car did not move, the plate check carries over. Every photo gets a light touch-up by itself; tick **Use original colours** under a photo to make it again without it. Outside photos go in the dark CarmaCars showroom (the logo on the wall, the model''s name behind the car on the cover). A car still on the black studio: press **Apply showroom to this car**; **Listings** > **Apply showroom to every car** does every car. Under a photo, **Redo** makes it again and **Back to the original** puts back the version before. **Marketing photos** on a listing makes copies in other scenes for Marketplace and social posts (choose a scene or **Mix: a different scene on each photo**, then **Make the marketing set**); the website''s photos stay as they are. **First photo** on a listing chooses what shows first on the site and in the Marketplace kit: **Plain car**, **With a model** (the image model''s car-show photo, a fully clothed adult model beside the car) or **Flyer** (the price a day from the live rates, the call to action and the logo on the cover). Switch any time; until the chosen one is made the plain cover shows.
## One screen, many photos (release 28)

**Import photos from a Google Drive link** on a listing adds the photos of a public Drive folder to the car, sorted and processed like Add photos. **Listings** > **Import photos from Drive** reads a whole folder of folders (one per make, then per car), proposes the car for each folder, and imports once you confirm the table. The page follows the import and ends with what was imported, skipped and failed, and why. The same Drive file is never added twice. Customer service can import into a car whose listing is already started; Fleet and Admin can start one.

Check-in and check-out are one screen on the booking page: the time, km, fuel, many photos at once (tag angles if you like) and a note. The renter''s own photos join the same report; each photo shows who took it. On a car''s page, record **Pickup from owner** and **Return to owner** with photos: the owner sees them.

## Repair costs on a car

On a car''s page, **Kickbacks and repairs** lists its repair costs and the kickbacks partners paid on it. **Add a repair cost**: the date, the shop or another vendor, what was done, the amount and tax, who paid (CarmaCars, the owner or the insurer), the claim and a photo or PDF of the receipt.

## When a check stops the pickup or the return (release 33)
On the booking page, **What stops the pickup now** (or the return) lists each check that stops it, in plain words. When the trip must go ahead anyway, press **Ask an Admin to override the pickup** (or the return), give the actual time, the km and fuel if you know them, and why. An Admin gets an alert and approves in one tap; the pickup (or the return) is then recorded with the time you entered, and the booking''s history says who asked and who approved. You can cancel your request while it waits. A trip that happened and was never recorded: **Ask to record a past trip** with both times; once an Admin approves, the booking lands in Returned so the deposit can be settled.

## Incident cards (release 34)
**Cars**, then **Incident cards**, prints the card for the visor or the glovebox: what to do in an accident or a breakdown, our support and roadside numbers, a QR code to report it in the app, and the fleet insurance slip. On a car''s page, **Incident card** prints that car; on the list, **Print all cars** prints every car, two cards to a Letter page with crop marks. Laminate it and put one in each car. The insurance policy on the card is set by an Admin; until it is, the card tells the renter to ask for the slip. No price is ever printed on it.

## Government forms (release 35)
The official ServiceOntario forms of each owner''s car are on the owner''s page and the car''s page, under **Government forms**. Open a form, press **Change a value**, choose the box, type the value and the reason, and **Save**: the form is made again as a new version, and the earlier versions stay under **Versions** with their downloads. **Back to the records** undoes a change. A form signed in ink or filed is never changed. **Make again** keeps the values changed by hand unless you tick **Discard the values changed by hand**. **Owners**, then **Government forms**, opens the forms'' mapping (which value goes in which box): preview it on a sample car, write what you changed and save; every save is kept under **Earlier mappings**. Only the boxes are filled: the form''s own text and layout never change.

## Odometer and fuel at every check-in and check-out

Every check-in and check-out on one screen asks for two photos besides the others:

1. **Photo of the dashboard**: the odometer and the fuel gauge, from the camera roll or the camera. The site reads it and asks, for example, "Odometer 45,210 km, fuel 3/4: correct?". Press **Yes, correct**, or **No, I will type it** and type the odometer and pick the fuel in eighths.
2. **Selfie in front of the car**: taken now with the camera, never from the camera roll. A selfie without a fresh capture time is noted on the report for you to check; it never stops the check-in.

At the return the site compares with the pickup: km driven, km over the included allowance and the fuel difference. The extra km (the booking''s rate per km) are added to the booking by themselves. The fuel is prepared as a suggested line: the car''s tank x the fuel missing x the local pump price of its grade x 1.25, plus the $20 refuelling fee (an electric car: battery kWh x the charge missing x $0.40, plus the fee). You and Finance confirm it on the deposit review; no card is charged by it. The photo report shows both dashboard photos side by side with the readings and these charges.

## Change the car of a confirmed booking

A car with a problem before pickup? On the booking, press **Change the car**, choose a car free for the dates and say why. The price comes from the new car''s rate sheet; more to pay is left open for the renter, less becomes a refund for approval. The jobs move to the new car and the renter gets one email.

## An accident reported by a renter

A renter can report an accident from the accident card on their booking. It opens the incident with its first-response steps and your To do, and sends you an urgent alert (on duty) and to Admins: what happened, where, the photos and videos, the other party, the police report number, whether anyone is hurt and whether the car can be driven. Call the renter at once; a car that cannot be driven is already out of service with its calendar blocked.
## Payments and calls (release 35)
Fleet takes payments on a booking''s **Money** tab: text or email a pay link, charge the saved card when the renter agreed, hold the deposit, or record cash or an e-Transfer received (within your single limit; Finance gets a To do to check it). Refunds, captures and voids stay with Finance and the Admins.

Calls and texts about pickups, returns, deliveries and cars on rent come to Fleet first: the caller pop-up shows them, and **More fleet** > **Calls and texts** is your inbox. A car late back has **Returning now** on its late panel: press it when the renter says they are on the way, and they get no more overdue reminders for that return time.

The official ServiceOntario forms of each owner''s car are on the owner''s page and the car''s page, under **Government forms**. Open a form, press **Change a value**, choose the box, type the value and the reason, and **Save**: the form is made again as a new version, and the earlier versions stay under **Versions** with their downloads. **Back to the records** undoes a change. A form signed in ink or filed is never changed. **Make again** keeps the values changed by hand unless you tick **Discard the values changed by hand**. **Owners**, then **Government forms**, opens the forms'' mapping (which value goes in which box): preview it on a sample car, write what you changed and save; every save is kept under **Earlier mappings**. Only the boxes are filled: the form''s own text and layout never change. The owner signs each form on screen: the page shows **Owner''s signature** beside the form (who, when, the version) and **Download the print-ready form** has no signature on it. A value changed after signing shows **Changed since signed** and the owner is asked to sign again.

## Close ended trips

A back-dated close sends the renter no email or text. Fleet gets a To do when a trip is still open 2 hours after its return time, and the morning digest lists how many are open.

**Field jobs** > **Close ended trips**: tick the trips that ended and were never closed, mark them returned on time or late (with the time), choose the deposit decision (deduct the balance owed, deduct the late fee, or release in full) and press **Close**. An expired card hold is settled by expiry at once. An Admin presses Release for the rest. On a booking, an expired hold after the return has **Mark settled (released by expiry)**.

## Field applicant calls (release 35)

Field applicants who pass the AI interview book a 10-minute live call in the hour before the weekly townhall. **Field applicant calls** on your home page lists the six slots and who took each one.

## Value and fuel on the car page (release 35)

**Cars** > the car > **Overview** > **Value and fuel**:

- **Canadian Black Book value** (with the date checked) or an **Estimated value (when no Black Book)**: renters on credit card coverage are checked against it. With neither, they go to staff review.
- **Tank (litres)** and **Fuel grade** (regular, premium or diesel; empty uses the class), or **Battery (kWh)** for an electric car. Empty uses the default in Program settings.

Press **Save**. Customer service sees the card; only Fleet and an Admin change it.

## Shifts, delivery and fuel (release 35)

- The shift board shows each field person''s availability, the standing weekly shifts, who is under the minimum, and for each slot the people to ask. A shift nobody claimed 48 hours ahead alerts you.
- You can approve new staff at the fourth onboarding step, or reject with a reason.
- Delivery is priced by distance from 1570 Midland Ave; the fuel line at the return is a suggestion from the tank and the pump price for you to check on the deposit review.
- An Admin can delete a car that has only test bookings; a car with a real booking stays.', 'Fleet', 'Field jobs, daily checks, photo reviews, similar cars and listings.',
  'You keep the cars moving: field jobs, daily checks, photo reviews after returns, and the listings with their duplicate check and plate covering. There is no commission for Fleet, but your help is credited on the booking (Helped by) and on your scorecard.

Your rail: Queue, Today, Field jobs, Field hours, Daily checks, Photo reviews, Calendar, Listings, Similar cars, Find a renter and Scorecard.

## Schedule field jobs

Every confirmed booking gets its handover (or delivery) and return (or pickup) jobs by itself, at the booking''s times and place, and put on a shift: the shift covering its time, or that day''s (see Shifts and who gets a job). The people on the shift share its jobs, least busy first. You check and change them.

1. Jobs, next three days: each with its place, its shift, its field staff and whether they acknowledged it. "Made from the booking" marks the ones made by themselves; when the booking moves, they move too, unless you changed them.
2. Change a job with **To a shift** (another shift), **Assign** or **Reassign** (a field person on a shift that day when the day has shifts, or an Admin), **Move** (time and place) or **Cancel**.
3. Handovers and returns without a job (when the automatic jobs are off, or one was cancelled) are listed first: press **Schedule**, the place filled in from the booking.
4. An Admin turns the automatic jobs or the assignment off in Settings > Program.

![](/guides/img/va-fleet-02-field-jobs-desktop-8e721230.jpg "desktop; size: 1230 565; address: carmacars.ca/va/fleet; pins: 1 17.9 51.3")

## Shifts and who gets a job

Field staff take their shifts from a schedule you publish, ideally a week ahead. A job is given by itself only to a field person who passed the academy and holds a shift that day, and work lands only on days with shifts.

1. On **Field jobs**, **Shifts, next seven days** shows each day and how many people are on a shift, and each shift its jobs (**Jobs on it**). A shift with jobs and nobody on it is marked; within 24 hours of its start you get an alert and a To do, once.
2. Press **Publish shifts**: the first day''s start and end, how many people, and for how many days the same hours repeat. Field staff take them on their phones.
3. **Add a person** puts someone on a shift and **Remove** takes them off. A person who has not passed the academy cannot take shifts or be given a job.
4. A shift nobody claimed keeps its jobs: field staff see them when they look for shifts to claim, and the one who claims it gets them. A shift given up or swapped takes its jobs along; a cancelled shift sends them to another shift.
5. Work due on a day with no shifts moves to the day before when it is known in advance, or to the next day with shifts when it comes in on the day. The job shows its planned day and keeps the booking''s real time; the renter''s times never change. A booking whose handover or return falls on a day with no shifts shows a warning: cover it, or move the booking time.
6. **Unassign** takes a job off its person and its shift; tick **Tell them** only if they should know. The Admins can be given a job too (no shift needed).

## Fleet map

At the top of **Field jobs**: every car on the map with its renter, booking, due-back time and state, the alerts, and the trips by booking, the same as the Admin''s. Only Admins and fleet staff see positions.

1. Press a car for its card: last report, odometer, fuel, tracker battery and the trip under way.
2. An alert (speeding, left Ontario or the zone, still driving after the return time, low or unplugged tracker, not reporting) also comes to your bell and as an urgent phone alert. Call the renter, then press **Seen**.
3. A car still driving after its return time: call, send the late notice and offer a paid extension, as for any late return.

## Field hours

Field staff clock in and out on their phones. You see who is clocked in and every shift of the two-week pay period, and you fix what they cannot.

1. Open **Field hours**. **Clocked in now** lists who is on, since when. **Earlier period** and **Later period** move between pay periods.
2. Someone forgot to clock out: press **Clock out for them**, set the time they finished and write the reason.
3. Someone forgot to clock in, or a time is wrong: **Add hours** enters a shift, **Change** fixes one and **Remove** takes one out. Each needs a reason; the change is kept in a log with what it was before.
4. Once an Admin approves the pay run of a period, its shifts are locked: ask the Admin. You see hours only, not rates or pay.

### Where they clocked in
The hours list shows where each person clocked in and out: a map link and the distance from the lot. A clock in or out over 500 m away, or with the location refused, is shown in bold with the reason the person wrote. Their location is asked only at those two moments, never in between.

## Daily checks

Twice a day: the opening check by 9:00 and the closing check by 18:00.

1. Open **Daily checks** and choose **Opening check** or **Closing check**.
2. Each line shows what was found. Tick OK, or Problem with a note.
3. Press **Save the opening check** (or **Save the closing check**). You can save it again.

![](/guides/img/va-fleet-03-daily-checks-desktop-be06d6c0.jpg "desktop; size: 1230 820; address: carmacars.ca/va/checks; pins: 1 6.5 15.4, 2 44.7 42.0, 3 64.2 94.0")

## Check a car out or in

Fleet, Sales and Customer service check cars out and in from the booking.

1. On a confirmed booking press **Check in (pickup)**; on a booking on rent, **Check out (return)**. Today lists the ones due, each with its button.
2. The checklist field staff use opens: readings (km and fuel or charge), the photo set with the plate and the gauges, damage close-ups and both signatures.
3. Afterwards press **Photo report**: times, Late by, kilometres, fuel, photos and the return charges. Fleet waives a charge with **Waive** and a reason.

## Photo reviews after a return

After each return, the field photo set waits under **Photo reviews**. Compare it with the pickup set. Press **Review done**, or **Ask for a re-shoot** if a photo is missing or unclear.

## Similar cars

A possible duplicate never keeps a car off the site: it shows on the car''s checklist until you decide. Only Same car takes it off.

1. Each flag shows the car, what it looks like (same VIN, plate, photo or specs) and the other car.
2. Compare the permit, the plate and the photos.
3. Press **Not a duplicate** with a note when they are different cars, or **Same car** when they are.

![](/guides/img/va-fleet-06-similar-cars-desktop-562b0382.jpg "desktop; size: 1230 460; address: carmacars.ca/va/similar-cars; pins: 1 23.6 30.4, 3 94.8 30.4")

## Rates and kilometres

From a listing, press **The car and its rates**, or open the car from Field jobs and its **Rates & fees** tab.

1. Type the rates an Admin set. Only the daily rate is needed; the others follow from it when empty. The weekend rate is a price per day for each day that starts on a Friday or Saturday.
2. Keep **Use the defaults** for the kilometres, or choose **Custom for this car**.
3. Check What renters pay under the fields, then press **Save the rates**. Rates, kilometres and deposit save together.
4. **Price limits**, below: the lowest and highest daily rate the owner accepts, read only. Offers, promo codes and lead-time pricing stay between them; an Admin or the owner changes them, and only an Admin allows one booking outside them.

## Listings and covering plates

1. Open **Listings**. A draft waiting shows Needs review. Open it.
2. The copy is written by itself (change a line only if you must: it is then kept). Check the photos: on each public photo, cover the plate or mark it not visible.

![](/guides/img/va-fleet-05-listings-desktop-d2672e0a.jpg "desktop; size: 1230 340; address: carmacars.ca/va/listings; pins: 1 54.5 49.1")

3. The listing''s Steps to go live says what is next: 1 Photos, 2 Cover plates, 3 Review, 4 Live on the site, each with its button. The plate box is suggested by itself on every outside photo as the listing opens (Box suggested). Press **Cover the plate** and check it; **Suggest the plate** asks again. A photo filed under the wrong shot: **Remove** under it on the Photos card, then take the right one.
4. Drag over a plate to draw a box; drag a box to move it, its corner to resize it.
5. Keep **The CARMA Ontario plate** on a rear plate or **Edit the front plate out** on a front photo (or choose **A CarmaCars plate**, **Pixelation** or **Blur**), then **Save the covered photo**.
6. No plate in the shot? **No plate visible on this photo**.

![](/guides/img/admin-11-plate-editor-phone-95d5afd2.jpg "phone; size: 390 776; pins: 3 52.6 78.9, 4 50.0 43.8, 5 61.5 62.1, 6 43.1 92.3")

> Watch out: The plate check never holds a car back: a photo whose plate is not checked stays private, and goes public by itself once it is covered or marked. The covered photo replaces the public one; the original is kept privately.

## Missing angles and short videos

On a listing, below First photo (Sales: in the Marketplace kit of the car).

1. A required angle with no photo? Fleet and Sales press **Make** and the angle (for example **Make Rear**): the image model makes the view from the car''s photos, within its free daily use. Check it is the same car, then **Approve** or **Reject**.
2. Press **Make a short video** for a 9:16 video of the car''s approved photos with the price and the call to action. Keep the tab in front until it says Saved, then **Download** it or schedule it on your Marketing page (Scheduled posts).

> Watch out: An AI view shows on the site after the real photos, labelled AI view. It is never the cover and never damage or condition evidence. A real photo always replaces it.

## Publish now

Customer service and fleet publish a car themselves; nothing has to be finished first.

1. Open the car from Listings or Field jobs. Its listing says why it is not on the site yet; press **Publish now**. With no rates yet it uses the suggested rates (similar cars, else the class defaults).
2. What is still open (paperwork, details, photos, No VIN yet for a car added by its plate, a possible duplicate) shows as warnings after Publish now and on the car. None of them stops publishing.
3. New cars with their rates usually go on the site by themselves (Publish new cars automatically, on by default). A car taken off the site by staff waits for Publish now.

> Tip: A car not on the fleet insurance policy yet can be requested, offered and paid for, but never handed over until the insurer confirms it. Requests and offers for such a car show a warning.

## Calendar sync with Turo and other platforms

**Cars** > **Calendar sync**: a car listed on Turo or Getaround must never be booked twice.

1. Turo has no calendar link: Turo''s trip emails come in by themselves, find their car by themselves (Turo car number, plate, VIN, year, make, model, trim, colour, what earlier emails taught) and block it with the turnaround. Nothing to set up per car.
2. An email the reader cannot place waits as "Which car is this?": press **Which car is this?** and press the right car (best guesses first). It is remembered for that car''s next emails. If the dates or trip number are missing: **Add as a Turo trip** (choose the car, check the dates) or **Dismiss**. A trip whose email did not come: **Add a Turo trip** on the car.
3. Each Turo trip shows the guest''s name and phone when Turo''s email includes them. Contact a Turo guest only about their trip, never with promotions.
4. Turo cannot read our calendar: under "Block on Turo", block each CarmaCars booking on the car''s Turo calendar, then press **Done on Turo**. Dates that changed or a booking cancelled here show the dates to free on Turo.
5. Getaround, Google Calendar or another platform with a calendar (iCal) link: open **Add a calendar link**, choose the platform, paste it and press **Add the link**. Copy the car''s CarmaCars link for that platform with **Copy** and paste it into the platform''s calendar import.
6. A double booking raises an urgent task for you and an email: move, swap or cancel one trip. A link that stops working raises a task after 3 failed reads: copy it from the platform again.

### Add the photos and readings
A pickup or return recorded with the details later gives Fleet the task **Add the photos and readings for CC-...**. Open the booking and press **Add the check-in (or check-out) photos and readings**: the usual checklist opens without the ready check or the renter''s signature. Take the photos, the odometer, fuel, keys (and cleanliness at a return), sign and save. The task closes by itself; it cannot be closed by hand before.

## Bookings now

**Rentals** > **Bookings** opens on Now for fleet and customer service: the cars out with their renter and due-back countdown, coming back today and tomorrow (overdue first, in red), going out in the next 72 hours with what is ready, the money due in 7 days and the free cars. It refreshes by itself every 30 seconds. A booking listed as **Out (pickup not recorded)** left without a check-in: press **Mark picked up**, then add the photos, km and fuel from the task. A car overdue or due back today has **Returned** (here, on Today and at the top of the booking): give the return time (now, or earlier; the late charges follow it) and the km and fuel if known. The overdue messages stop and the task for the photos is yours. The search above it finds any booking.

### The renter says the car is back

An urgent To do "The renter says the car is back" means the renter pressed **I''ve returned the car** on an overdue booking. Their overdue notices are paused. Open the booking, check the car (place, tracker, the renter''s photos), then press **Confirm** (correct the odometer, fuel or time first if needed; the trip is completed) or **Deny** with the reason (the renter is told and the notices start again).

**Start a listing** takes the VIN from the car: **Scan the barcode** in the door frame or under the windshield, or **Photo of the VIN**.

**Add photos** on a listing takes any number of photos at once, in any order: each is sorted to its shot. A photo that fits no shot goes in with **Extra outside photos** or **Extra inside and detail photos**; drag the extras into their order in the review and press **Save the order**. 10 photos and one outside photo complete the listing. Outside photos are framed big on the studio floor with a shadow under the tyres; a watermark or caption at a photo''s edge is cut off by itself. **Cover the plate** opens with the plate box suggested: check it and save. A car small in the frame, or no model name behind it: press **Frame the outside photos again** (then check the plates again). A bad cut-out (a mirror missing, background left): press **Edit the cut-out**, erase or restore with the brush, move or size the car on the studio, then **Save as a new version**. The version before is kept; if the car did not move, the plate check carries over. Every photo gets a light touch-up by itself; tick **Use original colours** under a photo to make it again without it. Outside photos go in the dark CarmaCars showroom (the logo on the wall, the model''s name behind the car on the cover). A car still on the black studio: press **Apply showroom to this car**; **Listings** > **Apply showroom to every car** does every car. Under a photo, **Redo** makes it again and **Back to the original** puts back the version before. **Marketing photos** on a listing makes copies in other scenes for Marketplace and social posts (choose a scene or **Mix: a different scene on each photo**, then **Make the marketing set**); the website''s photos stay as they are. **First photo** on a listing chooses what shows first on the site and in the Marketplace kit: **Plain car**, **With a model** (the image model''s car-show photo, a fully clothed adult model beside the car) or **Flyer** (the price a day from the live rates, the call to action and the logo on the cover). Switch any time; until the chosen one is made the plain cover shows.
## One screen, many photos (release 28)

**Import photos from a Google Drive link** on a listing adds the photos of a public Drive folder to the car, sorted and processed like Add photos. **Listings** > **Import photos from Drive** reads a whole folder of folders (one per make, then per car), proposes the car for each folder, and imports once you confirm the table. The page follows the import and ends with what was imported, skipped and failed, and why. The same Drive file is never added twice. Customer service can import into a car whose listing is already started; Fleet and Admin can start one.

Check-in and check-out are one screen on the booking page: the time, km, fuel, many photos at once (tag angles if you like) and a note. The renter''s own photos join the same report; each photo shows who took it. On a car''s page, record **Pickup from owner** and **Return to owner** with photos: the owner sees them.

## Repair costs on a car

On a car''s page, **Kickbacks and repairs** lists its repair costs and the kickbacks partners paid on it. **Add a repair cost**: the date, the shop or another vendor, what was done, the amount and tax, who paid (CarmaCars, the owner or the insurer), the claim and a photo or PDF of the receipt.

## When a check stops the pickup or the return (release 33)
On the booking page, **What stops the pickup now** (or the return) lists each check that stops it, in plain words. When the trip must go ahead anyway, press **Ask an Admin to override the pickup** (or the return), give the actual time, the km and fuel if you know them, and why. An Admin gets an alert and approves in one tap; the pickup (or the return) is then recorded with the time you entered, and the booking''s history says who asked and who approved. You can cancel your request while it waits. A trip that happened and was never recorded: **Ask to record a past trip** with both times; once an Admin approves, the booking lands in Returned so the deposit can be settled.

## Incident cards (release 34)
**Cars**, then **Incident cards**, prints the card for the visor or the glovebox: what to do in an accident or a breakdown, our support and roadside numbers, a QR code to report it in the app, and the fleet insurance slip. On a car''s page, **Incident card** prints that car; on the list, **Print all cars** prints every car, two cards to a Letter page with crop marks. Laminate it and put one in each car. The insurance policy on the card is set by an Admin; until it is, the card tells the renter to ask for the slip. No price is ever printed on it.

## Government forms (release 35)
The official ServiceOntario forms of each owner''s car are on the owner''s page and the car''s page, under **Government forms**. Open a form, press **Change a value**, choose the box, type the value and the reason, and **Save**: the form is made again as a new version, and the earlier versions stay under **Versions** with their downloads. **Back to the records** undoes a change. A form signed in ink or filed is never changed. **Make again** keeps the values changed by hand unless you tick **Discard the values changed by hand**. **Owners**, then **Government forms**, opens the forms'' mapping (which value goes in which box): preview it on a sample car, write what you changed and save; every save is kept under **Earlier mappings**. Only the boxes are filled: the form''s own text and layout never change.

## Odometer and fuel at every check-in and check-out

Every check-in and check-out on one screen asks for two photos besides the others:

1. **Photo of the dashboard**: the odometer and the fuel gauge, from the camera roll or the camera. The site reads it and asks, for example, "Odometer 45,210 km, fuel 3/4: correct?". Press **Yes, correct**, or **No, I will type it** and type the odometer and pick the fuel in eighths.
2. **Selfie in front of the car**: taken now with the camera, never from the camera roll. A selfie without a fresh capture time is noted on the report for you to check; it never stops the check-in.

At the return the site compares with the pickup: km driven, km over the included allowance and the fuel difference. The extra km (the booking''s rate per km) are added to the booking by themselves. The fuel is prepared as a suggested line: the car''s tank x the fuel missing x the local pump price of its grade x 1.25, plus the $20 refuelling fee (an electric car: battery kWh x the charge missing x $0.40, plus the fee). You and Finance confirm it on the deposit review; no card is charged by it. The photo report shows both dashboard photos side by side with the readings and these charges.

## Change the car of a confirmed booking

A car with a problem before pickup? On the booking, press **Change the car**, choose a car free for the dates and say why. The price comes from the new car''s rate sheet; more to pay is left open for the renter, less becomes a refund for approval. The jobs move to the new car and the renter gets one email.

## An accident reported by a renter

A renter can report an accident from the accident card on their booking. It opens the incident with its first-response steps and your To do, and sends you an urgent alert (on duty) and to Admins: what happened, where, the photos and videos, the other party, the police report number, whether anyone is hurt and whether the car can be driven. Call the renter at once; a car that cannot be driven is already out of service with its calendar blocked.
## Payments and calls (release 35)
Fleet takes payments on a booking''s **Money** tab: text or email a pay link, charge the saved card when the renter agreed, hold the deposit, or record cash or an e-Transfer received (within your single limit; Finance gets a To do to check it). Refunds, captures and voids stay with Finance and the Admins.

Calls and texts about pickups, returns, deliveries and cars on rent come to Fleet first: the caller pop-up shows them, and **More fleet** > **Calls and texts** is your inbox. A car late back has **Returning now** on its late panel: press it when the renter says they are on the way, and they get no more overdue reminders for that return time.

The official ServiceOntario forms of each owner''s car are on the owner''s page and the car''s page, under **Government forms**. Open a form, press **Change a value**, choose the box, type the value and the reason, and **Save**: the form is made again as a new version, and the earlier versions stay under **Versions** with their downloads. **Back to the records** undoes a change. A form signed in ink or filed is never changed. **Make again** keeps the values changed by hand unless you tick **Discard the values changed by hand**. **Owners**, then **Government forms**, opens the forms'' mapping (which value goes in which box): preview it on a sample car, write what you changed and save; every save is kept under **Earlier mappings**. Only the boxes are filled: the form''s own text and layout never change. The owner signs each form on screen: the page shows **Owner''s signature** beside the form (who, when, the version) and **Download the print-ready form** has no signature on it. A value changed after signing shows **Changed since signed** and the owner is asked to sign again.

## Close ended trips

A back-dated close sends the renter no email or text. Fleet gets a To do when a trip is still open 2 hours after its return time, and the morning digest lists how many are open.

**Field jobs** > **Close ended trips**: tick the trips that ended and were never closed, mark them returned on time or late (with the time), choose the deposit decision (deduct the balance owed, deduct the late fee, or release in full) and press **Close**. An expired card hold is settled by expiry at once. An Admin presses Release for the rest. On a booking, an expired hold after the return has **Mark settled (released by expiry)**.

## Field applicant calls (release 35)

Field applicants who pass the AI interview book a 10-minute live call in the hour before the weekly townhall. **Field applicant calls** on your home page lists the six slots and who took each one.

## Value and fuel on the car page (release 35)

**Cars** > the car > **Overview** > **Value and fuel**:

- **Canadian Black Book value** (with the date checked) or an **Estimated value (when no Black Book)**: renters on credit card coverage are checked against it. With neither, they go to staff review.
- **Tank (litres)** and **Fuel grade** (regular, premium or diesel; empty uses the class), or **Battery (kWh)** for an electric car. Empty uses the default in Program settings.

Press **Save**. Customer service sees the card; only Fleet and an Admin change it.

## Shifts, delivery and fuel (release 35)

- The shift board shows each field person''s availability, the standing weekly shifts, who is under the minimum, and for each slot the people to ask. A shift nobody claimed 48 hours ahead alerts you.
- You can approve new staff at the fourth onboarding step, or reject with a reason.
- Delivery is priced by distance from 1570 Midland Ave; the fuel line at the return is a suggestion from the tank and the pump price for you to check on the deposit review.
- An Admin can delete a car that has only test bookings; a car with a real booking stays.

## Calls first, texts after (release 37)

Your main priority is always to be on the phone with people.

1. Answer a ringing call before anything else, and return a missed call at once.
2. **Call before you text.** On a lead, a renter or a booking, **Call** is the first button and **Text** the second.
3. A text is a follow-up: after a call attempt (no answer, a voicemail left), or when the person asked for a text.
4. On your To do and on **Unanswered**, missed calls and call-backs are listed above unanswered texts.

## A lead you handle on a call (release 37)

When you answer or place a call with a lead, add a note on it, or create it from a call, the lead is yours for a limited time (15 minutes, as a Sales claim; an Admin can change it in **Settings** > **Sales**). Every call you handle adds the time again.

- Sales see **Being handled by** your first name and your function with the time, on the lead and in every list. They cannot claim it, call, text or email it, or set an outcome meanwhile, and **Next lead** skips it.
- Another customer service or Fleet person can still work it; their call or note takes the hold over.
- When it ends, the lead goes back to the salesperson who had a claim on it or who brought it, else to the open list. An Admin can **Release hold** earlier.
- A booking made from the lead is credited as always: customer service and Fleet get no sales commission for it.
- Nobody who has not finished onboarding holds a lead.',
  '<p class="gd-p">You keep the cars moving: field jobs, daily checks, photo reviews after returns, and the listings with their duplicate check and plate covering. There is no commission for Fleet, but your help is credited on the booking (Helped by) and on your scorecard.</p><p class="gd-p">Your rail: Queue, Today, Field jobs, Field hours, Daily checks, Photo reviews, Calendar, Listings, Similar cars, Find a renter and Scorecard.</p><section class="gd-task" id="fleet-schedule-field-jobs" data-gd-task><h2 class="gd-h2">Schedule field jobs</h2><p class="gd-p">Every confirmed booking gets its handover (or delivery) and return (or pickup) jobs by itself, at the booking&#39;s times and place, and put on a shift: the shift covering its time, or that day&#39;s (see Shifts and who gets a job). The people on the shift share its jobs, least busy first. You check and change them.</p><div class="gd-stepblock gd-stepblock--below"><div class="gd-stepcol"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">Jobs, next three days: each with its place, its shift, its field staff and whether they acknowledged it. &quot;Made from the booking&quot; marks the ones made by themselves; when the booking moves, they move too, unless you changed them.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Change a job with <b class="gd-ui">To a shift</b> (another shift), <b class="gd-ui">Assign</b> or <b class="gd-ui">Reassign</b> (a field person on a shift that day when the day has shifts, or an Admin), <b class="gd-ui">Move</b> (time and place) or <b class="gd-ui">Cancel</b>.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Handovers and returns without a job (when the automatic jobs are off, or one was cancelled) are listed first: press <b class="gd-ui">Schedule</b>, the place filled in from the booking.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t">An Admin turns the automatic jobs or the assignment off in Settings &gt; Program.</div></li></ol></div><figure class="gd-fig gd-fig--desk"><div class="gd-browser"><div class="gd-bar" aria-hidden="true"><i></i><i></i><i></i><span class="gd-addr">carmacars.ca/va/fleet</span></div><div class="gd-imgwrap" style="aspect-ratio:1230/565"><img src="/guides/img/va-fleet-02-field-jobs-desktop-8e721230.jpg" alt="" loading="lazy" decoding="async" width="1230" height="565"><span class="gd-pin" style="left:17.9%;top:51.3%" aria-hidden="true">1</span></div></div></figure></div></section><section class="gd-task" id="fleet-shifts-and-who-gets-a-job" data-gd-task><h2 class="gd-h2">Shifts and who gets a job</h2><p class="gd-p">Field staff take their shifts from a schedule you publish, ideally a week ahead. A job is given by itself only to a field person who passed the academy and holds a shift that day, and work lands only on days with shifts.</p><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">On <b class="gd-ui">Field jobs</b>, <b class="gd-ui">Shifts, next seven days</b> shows each day and how many people are on a shift, and each shift its jobs (<b class="gd-ui">Jobs on it</b>). A shift with jobs and nobody on it is marked; within 24 hours of its start you get an alert and a To do, once.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Press <b class="gd-ui">Publish shifts</b>: the first day&#39;s start and end, how many people, and for how many days the same hours repeat. Field staff take them on their phones.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t"><b class="gd-ui">Add a person</b> puts someone on a shift and <b class="gd-ui">Remove</b> takes them off. A person who has not passed the academy cannot take shifts or be given a job.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t">A shift nobody claimed keeps its jobs: field staff see them when they look for shifts to claim, and the one who claims it gets them. A shift given up or swapped takes its jobs along; a cancelled shift sends them to another shift.</div></li><li><span class="gd-n" aria-hidden="true">5</span><div class="gd-t">Work due on a day with no shifts moves to the day before when it is known in advance, or to the next day with shifts when it comes in on the day. The job shows its planned day and keeps the booking&#39;s real time; the renter&#39;s times never change. A booking whose handover or return falls on a day with no shifts shows a warning: cover it, or move the booking time.</div></li><li><span class="gd-n" aria-hidden="true">6</span><div class="gd-t"><b class="gd-ui">Unassign</b> takes a job off its person and its shift; tick <b class="gd-ui">Tell them</b> only if they should know. The Admins can be given a job too (no shift needed).</div></li></ol></div></section><section class="gd-task" id="fleet-fleet-map" data-gd-task><h2 class="gd-h2">Fleet map</h2><p class="gd-p">At the top of <b class="gd-ui">Field jobs</b>: every car on the map with its renter, booking, due-back time and state, the alerts, and the trips by booking, the same as the Admin&#39;s. Only Admins and fleet staff see positions.</p><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">Press a car for its card: last report, odometer, fuel, tracker battery and the trip under way.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">An alert (speeding, left Ontario or the zone, still driving after the return time, low or unplugged tracker, not reporting) also comes to your bell and as an urgent phone alert. Call the renter, then press <b class="gd-ui">Seen</b>.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">A car still driving after its return time: call, send the late notice and offer a paid extension, as for any late return.</div></li></ol></div></section><section class="gd-task" id="fleet-field-hours" data-gd-task><h2 class="gd-h2">Field hours</h2><p class="gd-p">Field staff clock in and out on their phones. You see who is clocked in and every shift of the two-week pay period, and you fix what they cannot.</p><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">Open <b class="gd-ui">Field hours</b>. <b class="gd-ui">Clocked in now</b> lists who is on, since when. <b class="gd-ui">Earlier period</b> and <b class="gd-ui">Later period</b> move between pay periods.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Someone forgot to clock out: press <b class="gd-ui">Clock out for them</b>, set the time they finished and write the reason.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Someone forgot to clock in, or a time is wrong: <b class="gd-ui">Add hours</b> enters a shift, <b class="gd-ui">Change</b> fixes one and <b class="gd-ui">Remove</b> takes one out. Each needs a reason; the change is kept in a log with what it was before.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t">Once an Admin approves the pay run of a period, its shifts are locked: ask the Admin. You see hours only, not rates or pay.</div></li></ol></div><h3 class="gd-h3">Where they clocked in</h3><p class="gd-p">The hours list shows where each person clocked in and out: a map link and the distance from the lot. A clock in or out over 500 m away, or with the location refused, is shown in bold with the reason the person wrote. Their location is asked only at those two moments, never in between.</p></section><section class="gd-task" id="fleet-daily-checks" data-gd-task><h2 class="gd-h2">Daily checks</h2><p class="gd-p">Twice a day: the opening check by 9:00 and the closing check by 18:00.</p><div class="gd-stepblock gd-stepblock--below"><div class="gd-stepcol"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">Open <b class="gd-ui">Daily checks</b> and choose <b class="gd-ui">Opening check</b> or <b class="gd-ui">Closing check</b>.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Each line shows what was found. Tick OK, or Problem with a note.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Press <b class="gd-ui">Save the opening check</b> (or <b class="gd-ui">Save the closing check</b>). You can save it again.</div></li></ol></div><figure class="gd-fig gd-fig--desk"><div class="gd-browser"><div class="gd-bar" aria-hidden="true"><i></i><i></i><i></i><span class="gd-addr">carmacars.ca/va/checks</span></div><div class="gd-imgwrap" style="aspect-ratio:1230/820"><img src="/guides/img/va-fleet-03-daily-checks-desktop-be06d6c0.jpg" alt="" loading="lazy" decoding="async" width="1230" height="820"><span class="gd-pin" style="left:6.5%;top:15.4%" aria-hidden="true">1</span><span class="gd-pin" style="left:44.7%;top:42%" aria-hidden="true">2</span><span class="gd-pin" style="left:64.2%;top:94%" aria-hidden="true">3</span></div></div></figure></div></section><section class="gd-task" id="fleet-check-a-car-out-or-in" data-gd-task><h2 class="gd-h2">Check a car out or in</h2><p class="gd-p">Fleet, Sales and Customer service check cars out and in from the booking.</p><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">On a confirmed booking press <b class="gd-ui">Check in (pickup)</b>; on a booking on rent, <b class="gd-ui">Check out (return)</b>. Today lists the ones due, each with its button.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">The checklist field staff use opens: readings (km and fuel or charge), the photo set with the plate and the gauges, damage close-ups and both signatures.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Afterwards press <b class="gd-ui">Photo report</b>: times, Late by, kilometres, fuel, photos and the return charges. Fleet waives a charge with <b class="gd-ui">Waive</b> and a reason.</div></li></ol></div></section><section class="gd-task" id="fleet-photo-reviews-after-a-return" data-gd-task><h2 class="gd-h2">Photo reviews after a return</h2><p class="gd-p">After each return, the field photo set waits under <b class="gd-ui">Photo reviews</b>. Compare it with the pickup set. Press <b class="gd-ui">Review done</b>, or <b class="gd-ui">Ask for a re-shoot</b> if a photo is missing or unclear.</p></section><section class="gd-task" id="fleet-similar-cars" data-gd-task><h2 class="gd-h2">Similar cars</h2><p class="gd-p">A possible duplicate never keeps a car off the site: it shows on the car&#39;s checklist until you decide. Only Same car takes it off.</p><div class="gd-stepblock gd-stepblock--below"><div class="gd-stepcol"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">Each flag shows the car, what it looks like (same VIN, plate, photo or specs) and the other car.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Compare the permit, the plate and the photos.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Press <b class="gd-ui">Not a duplicate</b> with a note when they are different cars, or <b class="gd-ui">Same car</b> when they are.</div></li></ol></div><figure class="gd-fig gd-fig--desk"><div class="gd-browser"><div class="gd-bar" aria-hidden="true"><i></i><i></i><i></i><span class="gd-addr">carmacars.ca/va/similar-cars</span></div><div class="gd-imgwrap" style="aspect-ratio:1230/460"><img src="/guides/img/va-fleet-06-similar-cars-desktop-562b0382.jpg" alt="" loading="lazy" decoding="async" width="1230" height="460"><span class="gd-pin" style="left:23.6%;top:30.4%" aria-hidden="true">1</span><span class="gd-pin" style="left:94.8%;top:30.4%" aria-hidden="true">3</span></div></div></figure></div></section><section class="gd-task" id="fleet-rates-and-kilometres" data-gd-task><h2 class="gd-h2">Rates and kilometres</h2><p class="gd-p">From a listing, press <b class="gd-ui">The car and its rates</b>, or open the car from Field jobs and its <b class="gd-ui">Rates &amp; fees</b> tab.</p><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">Type the rates an Admin set. Only the daily rate is needed; the others follow from it when empty. The weekend rate is a price per day for each day that starts on a Friday or Saturday.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Keep <b class="gd-ui">Use the defaults</b> for the kilometres, or choose <b class="gd-ui">Custom for this car</b>.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Check What renters pay under the fields, then press <b class="gd-ui">Save the rates</b>. Rates, kilometres and deposit save together.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t"><b class="gd-ui">Price limits</b>, below: the lowest and highest daily rate the owner accepts, read only. Offers, promo codes and lead-time pricing stay between them; an Admin or the owner changes them, and only an Admin allows one booking outside them.</div></li></ol></div></section><section class="gd-task" id="fleet-listings-and-covering-plates" data-gd-task><h2 class="gd-h2">Listings and covering plates</h2><div class="gd-stepblock gd-stepblock--below"><div class="gd-stepcol"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">Open <b class="gd-ui">Listings</b>. A draft waiting shows Needs review. Open it.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">The copy is written by itself (change a line only if you must: it is then kept). Check the photos: on each public photo, cover the plate or mark it not visible.</div></li></ol></div><figure class="gd-fig gd-fig--desk"><div class="gd-browser"><div class="gd-bar" aria-hidden="true"><i></i><i></i><i></i><span class="gd-addr">carmacars.ca/va/listings</span></div><div class="gd-imgwrap" style="aspect-ratio:1230/340"><img src="/guides/img/va-fleet-05-listings-desktop-d2672e0a.jpg" alt="" loading="lazy" decoding="async" width="1230" height="340"><span class="gd-pin" style="left:54.5%;top:49.1%" aria-hidden="true">1</span></div></div></figure></div><div class="gd-stepblock gd-stepblock--side"><div class="gd-stepcol"><ol class="gd-ol" start="3"><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">The listing&#39;s Steps to go live says what is next: 1 Photos, 2 Cover plates, 3 Review, 4 Live on the site, each with its button. The plate box is suggested by itself on every outside photo as the listing opens (Box suggested). Press <b class="gd-ui">Cover the plate</b> and check it; <b class="gd-ui">Suggest the plate</b> asks again. A photo filed under the wrong shot: <b class="gd-ui">Remove</b> under it on the Photos card, then take the right one.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t">Drag over a plate to draw a box; drag a box to move it, its corner to resize it.</div></li><li><span class="gd-n" aria-hidden="true">5</span><div class="gd-t">Keep <b class="gd-ui">The CARMA Ontario plate</b> on a rear plate or <b class="gd-ui">Edit the front plate out</b> on a front photo (or choose <b class="gd-ui">A CarmaCars plate</b>, <b class="gd-ui">Pixelation</b> or <b class="gd-ui">Blur</b>), then <b class="gd-ui">Save the covered photo</b>.</div></li><li><span class="gd-n" aria-hidden="true">6</span><div class="gd-t">No plate in the shot? <b class="gd-ui">No plate visible on this photo</b>.</div></li></ol></div><figure class="gd-fig gd-fig--phone"><div class="gd-phone"><div class="gd-imgwrap" style="aspect-ratio:390/776"><img src="/guides/img/admin-11-plate-editor-phone-95d5afd2.jpg" alt="" loading="lazy" decoding="async" width="390" height="776"><span class="gd-pin" style="left:52.6%;top:78.9%" aria-hidden="true">3</span><span class="gd-pin" style="left:50%;top:43.8%" aria-hidden="true">4</span><span class="gd-pin" style="left:61.5%;top:62.1%" aria-hidden="true">5</span><span class="gd-pin" style="left:43.1%;top:92.3%" aria-hidden="true">6</span></div></div></figure></div><aside class="gd-box gd-box--warn"><span class="gd-lbl">Watch out</span><div>The plate check never holds a car back: a photo whose plate is not checked stays private, and goes public by itself once it is covered or marked. The covered photo replaces the public one; the original is kept privately.</div></aside></section><section class="gd-task" id="fleet-missing-angles-and-short-videos" data-gd-task><h2 class="gd-h2">Missing angles and short videos</h2><p class="gd-p">On a listing, below First photo (Sales: in the Marketplace kit of the car).</p><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">A required angle with no photo? Fleet and Sales press <b class="gd-ui">Make</b> and the angle (for example <b class="gd-ui">Make Rear</b>): the image model makes the view from the car&#39;s photos, within its free daily use. Check it is the same car, then <b class="gd-ui">Approve</b> or <b class="gd-ui">Reject</b>.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Press <b class="gd-ui">Make a short video</b> for a 9:16 video of the car&#39;s approved photos with the price and the call to action. Keep the tab in front until it says Saved, then <b class="gd-ui">Download</b> it or schedule it on your Marketing page (Scheduled posts).</div></li></ol></div><aside class="gd-box gd-box--warn"><span class="gd-lbl">Watch out</span><div>An AI view shows on the site after the real photos, labelled AI view. It is never the cover and never damage or condition evidence. A real photo always replaces it.</div></aside></section><section class="gd-task" id="fleet-publish-now" data-gd-task><h2 class="gd-h2">Publish now</h2><p class="gd-p">Customer service and fleet publish a car themselves; nothing has to be finished first.</p><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">Open the car from Listings or Field jobs. Its listing says why it is not on the site yet; press <b class="gd-ui">Publish now</b>. With no rates yet it uses the suggested rates (similar cars, else the class defaults).</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">What is still open (paperwork, details, photos, No VIN yet for a car added by its plate, a possible duplicate) shows as warnings after Publish now and on the car. None of them stops publishing.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">New cars with their rates usually go on the site by themselves (Publish new cars automatically, on by default). A car taken off the site by staff waits for Publish now.</div></li></ol></div><aside class="gd-box"><span class="gd-lbl">Tip</span><div>A car not on the fleet insurance policy yet can be requested, offered and paid for, but never handed over until the insurer confirms it. Requests and offers for such a car show a warning.</div></aside></section><section class="gd-task" id="fleet-calendar-sync-with-turo-and-other-platforms" data-gd-task><h2 class="gd-h2">Calendar sync with Turo and other platforms</h2><p class="gd-p"><b class="gd-ui">Cars</b> &gt; <b class="gd-ui">Calendar sync</b>: a car listed on Turo or Getaround must never be booked twice.</p><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">Turo has no calendar link: Turo&#39;s trip emails come in by themselves, find their car by themselves (Turo car number, plate, VIN, year, make, model, trim, colour, what earlier emails taught) and block it with the turnaround. Nothing to set up per car.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">An email the reader cannot place waits as &quot;Which car is this?&quot;: press <b class="gd-ui">Which car is this?</b> and press the right car (best guesses first). It is remembered for that car&#39;s next emails. If the dates or trip number are missing: <b class="gd-ui">Add as a Turo trip</b> (choose the car, check the dates) or <b class="gd-ui">Dismiss</b>. A trip whose email did not come: <b class="gd-ui">Add a Turo trip</b> on the car.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Each Turo trip shows the guest&#39;s name and phone when Turo&#39;s email includes them. Contact a Turo guest only about their trip, never with promotions.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t">Turo cannot read our calendar: under &quot;Block on Turo&quot;, block each CarmaCars booking on the car&#39;s Turo calendar, then press <b class="gd-ui">Done on Turo</b>. Dates that changed or a booking cancelled here show the dates to free on Turo.</div></li><li><span class="gd-n" aria-hidden="true">5</span><div class="gd-t">Getaround, Google Calendar or another platform with a calendar (iCal) link: open <b class="gd-ui">Add a calendar link</b>, choose the platform, paste it and press <b class="gd-ui">Add the link</b>. Copy the car&#39;s CarmaCars link for that platform with <b class="gd-ui">Copy</b> and paste it into the platform&#39;s calendar import.</div></li><li><span class="gd-n" aria-hidden="true">6</span><div class="gd-t">A double booking raises an urgent task for you and an email: move, swap or cancel one trip. A link that stops working raises a task after 3 failed reads: copy it from the platform again.</div></li></ol></div><h3 class="gd-h3">Add the photos and readings</h3><p class="gd-p">A pickup or return recorded with the details later gives Fleet the task <b class="gd-ui">Add the photos and readings for CC-...</b>. Open the booking and press <b class="gd-ui">Add the check-in (or check-out) photos and readings</b>: the usual checklist opens without the ready check or the renter&#39;s signature. Take the photos, the odometer, fuel, keys (and cleanliness at a return), sign and save. The task closes by itself; it cannot be closed by hand before.</p></section><section class="gd-task" id="fleet-bookings-now" data-gd-task><h2 class="gd-h2">Bookings now</h2><p class="gd-p"><b class="gd-ui">Rentals</b> &gt; <b class="gd-ui">Bookings</b> opens on Now for fleet and customer service: the cars out with their renter and due-back countdown, coming back today and tomorrow (overdue first, in red), going out in the next 72 hours with what is ready, the money due in 7 days and the free cars. It refreshes by itself every 30 seconds. A booking listed as <b class="gd-ui">Out (pickup not recorded)</b> left without a check-in: press <b class="gd-ui">Mark picked up</b>, then add the photos, km and fuel from the task. A car overdue or due back today has <b class="gd-ui">Returned</b> (here, on Today and at the top of the booking): give the return time (now, or earlier; the late charges follow it) and the km and fuel if known. The overdue messages stop and the task for the photos is yours. The search above it finds any booking.</p><h3 class="gd-h3">The renter says the car is back</h3><p class="gd-p">An urgent To do &quot;The renter says the car is back&quot; means the renter pressed <b class="gd-ui">I&#39;ve returned the car</b> on an overdue booking. Their overdue notices are paused. Open the booking, check the car (place, tracker, the renter&#39;s photos), then press <b class="gd-ui">Confirm</b> (correct the odometer, fuel or time first if needed; the trip is completed) or <b class="gd-ui">Deny</b> with the reason (the renter is told and the notices start again).</p><p class="gd-p"><b class="gd-ui">Start a listing</b> takes the VIN from the car: <b class="gd-ui">Scan the barcode</b> in the door frame or under the windshield, or <b class="gd-ui">Photo of the VIN</b>.</p><p class="gd-p"><b class="gd-ui">Add photos</b> on a listing takes any number of photos at once, in any order: each is sorted to its shot. A photo that fits no shot goes in with <b class="gd-ui">Extra outside photos</b> or <b class="gd-ui">Extra inside and detail photos</b>; drag the extras into their order in the review and press <b class="gd-ui">Save the order</b>. 10 photos and one outside photo complete the listing. Outside photos are framed big on the studio floor with a shadow under the tyres; a watermark or caption at a photo&#39;s edge is cut off by itself. <b class="gd-ui">Cover the plate</b> opens with the plate box suggested: check it and save. A car small in the frame, or no model name behind it: press <b class="gd-ui">Frame the outside photos again</b> (then check the plates again). A bad cut-out (a mirror missing, background left): press <b class="gd-ui">Edit the cut-out</b>, erase or restore with the brush, move or size the car on the studio, then <b class="gd-ui">Save as a new version</b>. The version before is kept; if the car did not move, the plate check carries over. Every photo gets a light touch-up by itself; tick <b class="gd-ui">Use original colours</b> under a photo to make it again without it. Outside photos go in the dark CarmaCars showroom (the logo on the wall, the model&#39;s name behind the car on the cover). A car still on the black studio: press <b class="gd-ui">Apply showroom to this car</b>; <b class="gd-ui">Listings</b> &gt; <b class="gd-ui">Apply showroom to every car</b> does every car. Under a photo, <b class="gd-ui">Redo</b> makes it again and <b class="gd-ui">Back to the original</b> puts back the version before. <b class="gd-ui">Marketing photos</b> on a listing makes copies in other scenes for Marketplace and social posts (choose a scene or <b class="gd-ui">Mix: a different scene on each photo</b>, then <b class="gd-ui">Make the marketing set</b>); the website&#39;s photos stay as they are. <b class="gd-ui">First photo</b> on a listing chooses what shows first on the site and in the Marketplace kit: <b class="gd-ui">Plain car</b>, <b class="gd-ui">With a model</b> (the image model&#39;s car-show photo, a fully clothed adult model beside the car) or <b class="gd-ui">Flyer</b> (the price a day from the live rates, the call to action and the logo on the cover). Switch any time; until the chosen one is made the plain cover shows.</p></section><section class="gd-task" id="fleet-one-screen-many-photos-release-28" data-gd-task><h2 class="gd-h2">One screen, many photos (release 28)</h2><p class="gd-p"><b class="gd-ui">Import photos from a Google Drive link</b> on a listing adds the photos of a public Drive folder to the car, sorted and processed like Add photos. <b class="gd-ui">Listings</b> &gt; <b class="gd-ui">Import photos from Drive</b> reads a whole folder of folders (one per make, then per car), proposes the car for each folder, and imports once you confirm the table. The page follows the import and ends with what was imported, skipped and failed, and why. The same Drive file is never added twice. Customer service can import into a car whose listing is already started; Fleet and Admin can start one.</p><p class="gd-p">Check-in and check-out are one screen on the booking page: the time, km, fuel, many photos at once (tag angles if you like) and a note. The renter&#39;s own photos join the same report; each photo shows who took it. On a car&#39;s page, record <b class="gd-ui">Pickup from owner</b> and <b class="gd-ui">Return to owner</b> with photos: the owner sees them.</p></section><section class="gd-task" id="fleet-repair-costs-on-a-car" data-gd-task><h2 class="gd-h2">Repair costs on a car</h2><p class="gd-p">On a car&#39;s page, <b class="gd-ui">Kickbacks and repairs</b> lists its repair costs and the kickbacks partners paid on it. <b class="gd-ui">Add a repair cost</b>: the date, the shop or another vendor, what was done, the amount and tax, who paid (CarmaCars, the owner or the insurer), the claim and a photo or PDF of the receipt.</p></section><section class="gd-task" id="fleet-when-a-check-stops-the-pickup-or-the-return-release-33" data-gd-task><h2 class="gd-h2">When a check stops the pickup or the return (release 33)</h2><p class="gd-p">On the booking page, <b class="gd-ui">What stops the pickup now</b> (or the return) lists each check that stops it, in plain words. When the trip must go ahead anyway, press <b class="gd-ui">Ask an Admin to override the pickup</b> (or the return), give the actual time, the km and fuel if you know them, and why. An Admin gets an alert and approves in one tap; the pickup (or the return) is then recorded with the time you entered, and the booking&#39;s history says who asked and who approved. You can cancel your request while it waits. A trip that happened and was never recorded: <b class="gd-ui">Ask to record a past trip</b> with both times; once an Admin approves, the booking lands in Returned so the deposit can be settled.</p></section><section class="gd-task" id="fleet-incident-cards-release-34" data-gd-task><h2 class="gd-h2">Incident cards (release 34)</h2><p class="gd-p"><b class="gd-ui">Cars</b>, then <b class="gd-ui">Incident cards</b>, prints the card for the visor or the glovebox: what to do in an accident or a breakdown, our support and roadside numbers, a QR code to report it in the app, and the fleet insurance slip. On a car&#39;s page, <b class="gd-ui">Incident card</b> prints that car; on the list, <b class="gd-ui">Print all cars</b> prints every car, two cards to a Letter page with crop marks. Laminate it and put one in each car. The insurance policy on the card is set by an Admin; until it is, the card tells the renter to ask for the slip. No price is ever printed on it.</p></section><section class="gd-task" id="fleet-government-forms-release-35" data-gd-task><h2 class="gd-h2">Government forms (release 35)</h2><p class="gd-p">The official ServiceOntario forms of each owner&#39;s car are on the owner&#39;s page and the car&#39;s page, under <b class="gd-ui">Government forms</b>. Open a form, press <b class="gd-ui">Change a value</b>, choose the box, type the value and the reason, and <b class="gd-ui">Save</b>: the form is made again as a new version, and the earlier versions stay under <b class="gd-ui">Versions</b> with their downloads. <b class="gd-ui">Back to the records</b> undoes a change. A form signed in ink or filed is never changed. <b class="gd-ui">Make again</b> keeps the values changed by hand unless you tick <b class="gd-ui">Discard the values changed by hand</b>. <b class="gd-ui">Owners</b>, then <b class="gd-ui">Government forms</b>, opens the forms&#39; mapping (which value goes in which box): preview it on a sample car, write what you changed and save; every save is kept under <b class="gd-ui">Earlier mappings</b>. Only the boxes are filled: the form&#39;s own text and layout never change.</p></section><section class="gd-task" id="fleet-odometer-and-fuel-at-every-check-in-and-check-out" data-gd-task><h2 class="gd-h2">Odometer and fuel at every check-in and check-out</h2><p class="gd-p">Every check-in and check-out on one screen asks for two photos besides the others:</p><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t"><b class="gd-ui">Photo of the dashboard</b>: the odometer and the fuel gauge, from the camera roll or the camera. The site reads it and asks, for example, &quot;Odometer 45,210 km, fuel 3/4: correct?&quot;. Press <b class="gd-ui">Yes, correct</b>, or <b class="gd-ui">No, I will type it</b> and type the odometer and pick the fuel in eighths.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t"><b class="gd-ui">Selfie in front of the car</b>: taken now with the camera, never from the camera roll. A selfie without a fresh capture time is noted on the report for you to check; it never stops the check-in.</div></li></ol></div><p class="gd-p">At the return the site compares with the pickup: km driven, km over the included allowance and the fuel difference. The extra km (the booking&#39;s rate per km) are added to the booking by themselves. The fuel is prepared as a suggested line: the car&#39;s tank x the fuel missing x the local pump price of its grade x 1.25, plus the $20 refuelling fee (an electric car: battery kWh x the charge missing x $0.40, plus the fee). You and Finance confirm it on the deposit review; no card is charged by it. The photo report shows both dashboard photos side by side with the readings and these charges.</p></section><section class="gd-task" id="fleet-change-the-car-of-a-confirmed-booking" data-gd-task><h2 class="gd-h2">Change the car of a confirmed booking</h2><p class="gd-p">A car with a problem before pickup? On the booking, press <b class="gd-ui">Change the car</b>, choose a car free for the dates and say why. The price comes from the new car&#39;s rate sheet; more to pay is left open for the renter, less becomes a refund for approval. The jobs move to the new car and the renter gets one email.</p></section><section class="gd-task" id="fleet-an-accident-reported-by-a-renter" data-gd-task><h2 class="gd-h2">An accident reported by a renter</h2><p class="gd-p">A renter can report an accident from the accident card on their booking. It opens the incident with its first-response steps and your To do, and sends you an urgent alert (on duty) and to Admins: what happened, where, the photos and videos, the other party, the police report number, whether anyone is hurt and whether the car can be driven. Call the renter at once; a car that cannot be driven is already out of service with its calendar blocked.</p></section><section class="gd-task" id="fleet-payments-and-calls-release-35" data-gd-task><h2 class="gd-h2">Payments and calls (release 35)</h2><p class="gd-p">Fleet takes payments on a booking&#39;s <b class="gd-ui">Money</b> tab: text or email a pay link, charge the saved card when the renter agreed, hold the deposit, or record cash or an e-Transfer received (within your single limit; Finance gets a To do to check it). Refunds, captures and voids stay with Finance and the Admins.</p><p class="gd-p">Calls and texts about pickups, returns, deliveries and cars on rent come to Fleet first: the caller pop-up shows them, and <b class="gd-ui">More fleet</b> &gt; <b class="gd-ui">Calls and texts</b> is your inbox. A car late back has <b class="gd-ui">Returning now</b> on its late panel: press it when the renter says they are on the way, and they get no more overdue reminders for that return time.</p><p class="gd-p">The official ServiceOntario forms of each owner&#39;s car are on the owner&#39;s page and the car&#39;s page, under <b class="gd-ui">Government forms</b>. Open a form, press <b class="gd-ui">Change a value</b>, choose the box, type the value and the reason, and <b class="gd-ui">Save</b>: the form is made again as a new version, and the earlier versions stay under <b class="gd-ui">Versions</b> with their downloads. <b class="gd-ui">Back to the records</b> undoes a change. A form signed in ink or filed is never changed. <b class="gd-ui">Make again</b> keeps the values changed by hand unless you tick <b class="gd-ui">Discard the values changed by hand</b>. <b class="gd-ui">Owners</b>, then <b class="gd-ui">Government forms</b>, opens the forms&#39; mapping (which value goes in which box): preview it on a sample car, write what you changed and save; every save is kept under <b class="gd-ui">Earlier mappings</b>. Only the boxes are filled: the form&#39;s own text and layout never change. The owner signs each form on screen: the page shows <b class="gd-ui">Owner&#39;s signature</b> beside the form (who, when, the version) and <b class="gd-ui">Download the print-ready form</b> has no signature on it. A value changed after signing shows <b class="gd-ui">Changed since signed</b> and the owner is asked to sign again.</p></section><section class="gd-task" id="fleet-close-ended-trips" data-gd-task><h2 class="gd-h2">Close ended trips</h2><p class="gd-p">A back-dated close sends the renter no email or text. Fleet gets a To do when a trip is still open 2 hours after its return time, and the morning digest lists how many are open.</p><p class="gd-p"><b class="gd-ui">Field jobs</b> &gt; <b class="gd-ui">Close ended trips</b>: tick the trips that ended and were never closed, mark them returned on time or late (with the time), choose the deposit decision (deduct the balance owed, deduct the late fee, or release in full) and press <b class="gd-ui">Close</b>. An expired card hold is settled by expiry at once. An Admin presses Release for the rest. On a booking, an expired hold after the return has <b class="gd-ui">Mark settled (released by expiry)</b>.</p></section><section class="gd-task" id="fleet-field-applicant-calls-release-35" data-gd-task><h2 class="gd-h2">Field applicant calls (release 35)</h2><p class="gd-p">Field applicants who pass the AI interview book a 10-minute live call in the hour before the weekly townhall. <b class="gd-ui">Field applicant calls</b> on your home page lists the six slots and who took each one.</p></section><section class="gd-task" id="fleet-value-and-fuel-on-the-car-page-release-35" data-gd-task><h2 class="gd-h2">Value and fuel on the car page (release 35)</h2><p class="gd-p"><b class="gd-ui">Cars</b> &gt; the car &gt; <b class="gd-ui">Overview</b> &gt; <b class="gd-ui">Value and fuel</b>:</p><ul class="gd-ul"><li><b class="gd-ui">Canadian Black Book value</b> (with the date checked) or an <b class="gd-ui">Estimated value (when no Black Book)</b>: renters on credit card coverage are checked against it. With neither, they go to staff review.</li><li><b class="gd-ui">Tank (litres)</b> and <b class="gd-ui">Fuel grade</b> (regular, premium or diesel; empty uses the class), or <b class="gd-ui">Battery (kWh)</b> for an electric car. Empty uses the default in Program settings.</li></ul><p class="gd-p">Press <b class="gd-ui">Save</b>. Customer service sees the card; only Fleet and an Admin change it.</p></section><section class="gd-task" id="fleet-shifts-delivery-and-fuel-release-35" data-gd-task><h2 class="gd-h2">Shifts, delivery and fuel (release 35)</h2><ul class="gd-ul"><li>The shift board shows each field person&#39;s availability, the standing weekly shifts, who is under the minimum, and for each slot the people to ask. A shift nobody claimed 48 hours ahead alerts you.</li><li>You can approve new staff at the fourth onboarding step, or reject with a reason.</li><li>Delivery is priced by distance from 1570 Midland Ave; the fuel line at the return is a suggestion from the tank and the pump price for you to check on the deposit review.</li><li>An Admin can delete a car that has only test bookings; a car with a real booking stays.</li></ul></section><section class="gd-task" id="fleet-calls-first-texts-after-release-37" data-gd-task><h2 class="gd-h2">Calls first, texts after (release 37)</h2><p class="gd-p">Your main priority is always to be on the phone with people.</p><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">Answer a ringing call before anything else, and return a missed call at once.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t"><b class="gd-ui">Call before you text.</b> On a lead, a renter or a booking, <b class="gd-ui">Call</b> is the first button and <b class="gd-ui">Text</b> the second.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">A text is a follow-up: after a call attempt (no answer, a voicemail left), or when the person asked for a text.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t">On your To do and on <b class="gd-ui">Unanswered</b>, missed calls and call-backs are listed above unanswered texts.</div></li></ol></div></section><section class="gd-task" id="fleet-a-lead-you-handle-on-a-call-release-37" data-gd-task><h2 class="gd-h2">A lead you handle on a call (release 37)</h2><p class="gd-p">When you answer or place a call with a lead, add a note on it, or create it from a call, the lead is yours for a limited time (15 minutes, as a Sales claim; an Admin can change it in <b class="gd-ui">Settings</b> &gt; <b class="gd-ui">Sales</b>). Every call you handle adds the time again.</p><ul class="gd-ul"><li>Sales see <b class="gd-ui">Being handled by</b> your first name and your function with the time, on the lead and in every list. They cannot claim it, call, text or email it, or set an outcome meanwhile, and <b class="gd-ui">Next lead</b> skips it.</li><li>Another customer service or Fleet person can still work it; their call or note takes the hold over.</li><li>When it ends, the lead goes back to the salesperson who had a claim on it or who brought it, else to the open list. An Admin can <b class="gd-ui">Release hold</b> earlier.</li><li>A booking made from the lead is credited as always: customer service and Fleet get no sales commission for it.</li><li>Nobody who has not finished onboarding holds a lead.</li></ul></section>');
select app.guide_release_section('va', 'sales', 'chapter', 'fleet', 'You turn enquiries into bookings and owners into fleet: requests and offers, quotes for callers, and owner leads.

Your menu: To do, Today, My scorecard and My sales, then Requests and offers, Send an offer, Add a rental, New quote, Calendar and Buyer leads. The owners you bring in are on My sales.

## Requests, offers and new quotes

1. **Requests and offers**: the same queue customer service works, showing only what you can answer now. A request still with customer service is folded under "more not open to you yet", with the time it opens to you.
2. **Rentals** > **Bookings**: **My bookings**, every booking credited to you, offered by you or added by you, from the offer to the return, with its status, money and your commission (counting this month, waiting for approval, approved, paid).
3. **Send an offer**: one screen for a caller, sent at once, as in chapter 2. **New quote** still makes a request to offer later.
3. An offer that is out: **More actions** > **Edit the offer**, then **Save and send the update**.

![](/guides/img/va-sales-02-requests-desktop-2ab1d17d.jpg "desktop; size: 1230 580; address: carmacars.ca/va/requests; pins: 1 39.8 59.5")

> Tip: Your first reply target is 5 minutes, the "Quote sent" measure on your scorecard. Follow every offer out before it expires.

## Check the renter''s licence

Sales approve the renter''s licence like customer service: the licence front, the licence back and the selfie. The proof of coverage and the Protection Plan stay with customer service and Admins.

1. On **To do**, **Licences to check** lists each booking with an image waiting, the longest wait first. Press **Review the licence**.
2. On a booking, the card **Renter licence** has the same: press **Review the licence**.
3. Look at each image and each Flag line of the licence reader under the driver: no alteration, the selfie matches the licence photo.
4. One is wrong? Open **Reject this one** under it, type the reason the renter reads and press **Reject**. The renter is told and asked for a new image.
5. Then press **Approve all**: every image still waiting is approved at once. An image the system refuses is named with the reason.

> Tip: The booking history says who decided and the role, sales. Each opening of the images is logged and the links last one minute.

## In person or remote

Every Sales person works in one of two modes, on the same Sales screens. An Admin sets yours; it shows at the top of To do and on My sales.

|  | In person (Toronto) | Remote (anywhere) |
| --- | --- | --- |
| Commission | Under 50 rental days in the month 10%, from 50 days 15%, from 100 days 20% | Under 50 rental days 5%, from 50 days 10%, from 100 days 15% |
| Credit | Walk-ins, handovers you close, partner visits and the rentals you source | Only the rentals you source. A website request you answer with the first offer during one of your blocks counts as yours. Walk-ins and partner deals earn nothing |
| Hours | You choose | At least 20 hours a week of Thursday to Sunday afternoons (noon to 6 pm, Toronto time), replying within 15 minutes to the chats, texts and calls assigned to you |
| Every day | Nothing set | Marketplace and classified reposts, social media DM replies, three follow-ups on every quote, long-term and business outreach |
| Every month | Nothing set | 400 touches. Under 400 when the month ends, the month''s rate is one tier lower: 15% becomes 10%, 10% becomes 5%, 5% becomes 2.5% |

## Remote: your duties

On **To do**, **Remote duties** shows this month''s touches against 400, today''s checklist, the peak hours you scheduled this week and your reply time.

1. Most touches count by themselves: an offer you send, a message or text you send from the portal, a live chat you answer (once a day for each chat), a call or text from the phone line, an ad you post, a call or message to a car owner.
2. For anything else press **Log a touch**: choose the type and add the link of the post, profile or listing if there is one.
3. The checklist ticks itself as the day''s touches come in. Three follow-ups on every quote stays open while a deal of yours has fewer than three.
4. Under My availability choose this week or next, press **Add a block** for each time you will be on, then **Save the week**. Days already past stay as they were.
5. A website request you answer with the first offer during a block is credited to you as sourced, even if you chose Entered for CarmaCars. Off your blocks it stays a claim for an Admin.

> Tip: An Admin can void a touch logged by mistake. Once an Admin approves a month, its mode, its rates and its touches no longer change; a refund can still lower the tier, as for everyone.

## My sales

Open **Me**, the **My sales** tab. It shows your own sales and commissions only.

1. Commissions comes first. Your rate depends on your mode and the rental days of the month: in person 10%, 15% from 50 days, 20% from 100; remote 5%, 10% and 15%. The bar shows your days against the target of 100, and says when your rate rises. By month gives each month in one line: the mode, the days, the rate and, for remote, the touches and any drop.
2. The tiles show this week: quotes created, offers sent, rentals added, bookings confirmed, conversion, booked revenue and follow-ups due. Press **By month** for months, **By week** for weeks.
3. By week (or By month) lists each period with the same figures, newest first.
4. Follow-ups due lists your open deals with what to do next: send the offer, follow up before the offer expires, or follow up while the renter signs and pays. Red means it is past due.
5. Deals lists every booking you created, added or sent an offer on in the last 180 days, with its status and what it counts. Open a request, an offer or a rental you added from its number.

| Figure | How it is counted |
| --- | --- |
| Credited to you | A quote you created, a rental you added, or a website request whose first offer you sent. An Admin can give a deal to someone else. |
| Quotes created, offers sent, rentals added | Counted on the day they happened. |
| Bookings confirmed, booked revenue | Counted on the day the booking was confirmed. |
| Conversion | Of the deals credited to you in the period, the share confirmed so far. |
| Booked revenue | The rental charge before tax, after discounts. A cancelled booking counts only what was kept; refunds come off. |
| Rental days (Sales) | The days of the completed, paid rentals you sourced that end in the month. The month''s tier applies to all of that month''s rentals. |

> Tip: Sales commissions are approved after the month ends, when the month''s tier is known. A refund that drops the month under a tier lowers every commission of that month; anything already paid comes off your next payment.

## Owners you bring in

Bring in car owners on **My work** > **My sales**, card **Owners you bring in**. Every owner you bring in is credited to you as "sourced by", with their cars. Only an Admin can change that later.

1. **Invite an owner**: enter their name, email and phone, tick **The owner asked me to send it**, then press **Send the invitation**. They get an email with your link to apply.
2. **Copy my owner link**: your own link to the application, for a message or a post. Anyone who applies with it is credited to you.
3. **Start an application**: you fill in the owner and the car for them, with **Take a photo** (or **Choose a photo**) of the ownership permit to fill in the car. It goes to an Admin as an application to approve. The terms and invoices are the Admin''s. A corporation that leases its cars to CarmaCars: choose **A corporation**, then Route **Fleet supplier: leases the cars to CarmaCars**, and each car''s tier (**Regular** or **Troubled**). A fleet supplier can also apply himself from `carmacars.ca/list-your-car`: your owner link works for it too.
4. The row of five figures follows your owners: **Invited**, **Applied**, **Approved**, **Car live** and **First paid rental**. Below, each owner shows their stage and their cars.

5. Someone who starts the application on the website and stops for 30 minutes comes to you: a task "Unfinished owner application" and their row on My sales (Lead). Call or text them; the follow-up emails go by themselves until they finish.

> Tip: An owner already on file, or invited first by another salesperson, cannot be invited again. Ask an Admin if you brought them in.

## Ask for your commission on an owner

There is no set amount. For each owner you bring in, you ask for one, and an Admin decides.

1. On the owner''s row press **Ask for a commission**.
2. Choose **A flat amount** and type it, or **A percent**: type the percent, choose what it is of (the company''s share of their cars'' rentals, or their cars'' rental revenue) and for how long (a number of months, or as long as the car is with us).
3. Add a note for the Admin if you like, then press **Send to an Admin**.
4. While it waits you can press **Change my request**. Once an Admin approves, changes or declines it, the row says so, with their note.

| Approved as | When it is earned |
| --- | --- |
| A flat amount | Once, at the owner''s first paid rental: the first completed rental of any of their cars, paid in full |
| A percent | On each completed, paid rental of their cars that ends after the approval, from the month of the first one, for the months approved |

> Tip: Nothing is earned before an Admin approves the request, and nothing on CarmaCars'' own cars, a partner''s, a shareholder''s or your own. Each commission then goes through the usual steps on My sales: pending approval, approved, paid.

## Buyer leads

1. **Buyer leads**: each request from the /buy pages, with the car, budget and timing.
2. Press **Take it** to make it yours, then call them.
3. Press **Update** to set the status. When you close a lead, say why.

> Tip: Owner leads are not here. The owners you invite or add are on **My sales**, **Owners you bring in**, and you see only your own. Customer service works the full owner pipeline.

An offer that has been expired for 7 days leaves Requests and offers and becomes a renter lead: you get the To do "Expired offer: win the renter back" (the lead goes to the Sales person with the fewest open leads) with the renter''s contact, the car and the dates they wanted. Call or text them, then mark the lead contacted or closed.

**Reopen offer** on an expired booking (or the **Expired** filter of Requests) sends the offer again in one click, open 24 hours unless you set the hours; a pickup time that has passed asks for new dates first. "Renter wants expired offer reopened" To dos come from the renter''s own button. The offer screens block **Send** with **Pickup time has passed: update it** until the pickup is moved.

## Book it now (release 33)
When you send an offer, tick **Book it now (no renter approval)** when the renter has already agreed. The offer goes out and an Admin approves it in one tap: the booking then waits for payment, the car is held, and the renter gets one link to sign and pay. You can also have them sign and pay with you: open the booking, **Sign now on this device**, then take the card on this device.
Already sent the offer? Ask the assistant: "Book the offer of CC-10482 now, the customer agreed by phone". It shows a card; **Confirm** sends the same request to an Admin, who approves in one tap.

## When a check stops the pickup or the return (release 33)
On the booking page, **What stops the pickup now** (or the return) lists each check that stops it, in plain words. When the trip must go ahead anyway, press **Ask an Admin to override the pickup** (or the return), give the actual time, the km and fuel if you know them, and why. An Admin gets an alert and approves in one tap; the pickup (or the return) is then recorded with the time you entered, and the booking''s history says who asked and who approved. You can cancel your request while it waits. A trip that happened and was never recorded: **Ask to record a past trip** with both times; once an Admin approves, the booking lands in Returned so the deposit can be settled.

## Leads and claims

Open **Leads**. Every lead is there: renter leads (forms, live chat, the phone number box, games, expired offers, requests not sent, missed calls, Live visitors), owner leads and partner leads, new and hot first. A new-lead alert on your phone opens that lead.

1. Press **Next lead**, or **Claim** on a card. The lead is yours for 15 minutes.
2. Press **Call**, **Text** or **Email**: your phone or mail app opens and the contact is logged. Each contact (or **Note**) adds 15 minutes, up to 60 minutes from your claim.
3. Press **Outcome**: Contacted, Call booked, Applied, Won or Lost (say why). Or **Mark handled** when there is nothing more to do.
4. Can''t finish? Press **Unclaim** so someone else can take it. A claim that runs out goes back to the pool by itself.

You hold at most 25 leads at once. Your numbers are on To do under **My leads**: leads claimed, won, close rate (won out of claimed), contacted, time to first contact and claims that ran out, today, this week and this month. Owner leads are also under **Owners** > **Leads**.
## Call minutes (release 35)
Your home shows **My call minutes**: today, this week and this month, for connected calls made with the site''s **Call** button. Customer numbers are hidden for Sales; call and text with the buttons on the page.


## Get a renter ready for the pickup (release 35)
Your work does not stop at the offer. Until the car is handed over you can do everything that gets the renter good to go:
- **Payment**: send a pay link or a deposit link on Money (text or email), or take the card on this device, also on a confirmed booking.
- **The offer**: edit it, send it again with a later expiry, withdraw it or record that the renter approved by phone, also while it waits for payment.
- **ID and coverage**: approve or reject the licence, the selfie and the proof of coverage, with the reason the renter sees.
- **Drivers and agreement**: send each additional driver their signing link, or the agreement again.
- **Name change asked for**: when a verified renter asks for a name or date of birth correction, it shows on the booking; check it against the licence, then **Approve** or **Decline**.

The booking page shows **Ready for the rental**: one line for each thing the pickup needs (offer accepted, paid, licence and selfie, coverage, deposit, drivers, agreement, add-ons in the car), green when done, with what to press when not. Refunds, cancellations, deposit releases and removing a paid add-on stay with customer service, Finance and Admins.

## The Prepare checklist (release 35)
On a booking with add-ons, **Prepare for the pickup** shows each add-on with its quantity, ticked or not by field staff, who ticked it and when, and the pickup or delivery job with its field person. It is on the booking and on the car page, for Sales, customer service, Fleet and Finance.

## Rebooking, intent and offers (release 35)

- A returning renter''s new request comes straight to you when you had their last booking, with the usual claim time.
- Each lead shows its intent (hot, warm or cold) and what the person said they want, read from calls with their transcripts, texts, emails, chat and visits. Call hot leads first.
- Offers are three steps: car and dates, price, review and send. Every version is kept; you can load an old one as a new offer.
- Prices stay between the owner''s daily minimum and maximum; only an Admin allows one outside them.
- Repeat renters who are verified can book instantly; their booking is marked Instant (repeat renter).
- Rewards: tell renters they earn points for a photo with their review and every rental after the first.', 'Sales', 'Requests and offers, new quotes and owner leads.',
  'You turn enquiries into bookings and owners into fleet: requests and offers, quotes for callers, and owner leads.

Your menu: To do, Today, My scorecard and My sales, then Requests and offers, Send an offer, Add a rental, New quote, Calendar and Buyer leads. The owners you bring in are on My sales.

## Requests, offers and new quotes

1. **Requests and offers**: the same queue customer service works, showing only what you can answer now. A request still with customer service is folded under "more not open to you yet", with the time it opens to you.
2. **Rentals** > **Bookings**: **My bookings**, every booking credited to you, offered by you or added by you, from the offer to the return, with its status, money and your commission (counting this month, waiting for approval, approved, paid).
3. **Send an offer**: one screen for a caller, sent at once, as in chapter 2. **New quote** still makes a request to offer later.
3. An offer that is out: **More actions** > **Edit the offer**, then **Save and send the update**.

![](/guides/img/va-sales-02-requests-desktop-2ab1d17d.jpg "desktop; size: 1230 580; address: carmacars.ca/va/requests; pins: 1 39.8 59.5")

> Tip: Your first reply target is 5 minutes, the "Quote sent" measure on your scorecard. Follow every offer out before it expires.

## Check the renter''s licence

Sales approve the renter''s licence like customer service: the licence front, the licence back and the selfie. The proof of coverage and the Protection Plan stay with customer service and Admins.

1. On **To do**, **Licences to check** lists each booking with an image waiting, the longest wait first. Press **Review the licence**.
2. On a booking, the card **Renter licence** has the same: press **Review the licence**.
3. Look at each image and each Flag line of the licence reader under the driver: no alteration, the selfie matches the licence photo.
4. One is wrong? Open **Reject this one** under it, type the reason the renter reads and press **Reject**. The renter is told and asked for a new image.
5. Then press **Approve all**: every image still waiting is approved at once. An image the system refuses is named with the reason.

> Tip: The booking history says who decided and the role, sales. Each opening of the images is logged and the links last one minute.

## In person or remote

Every Sales person works in one of two modes, on the same Sales screens. An Admin sets yours; it shows at the top of To do and on My sales.

|  | In person (Toronto) | Remote (anywhere) |
| --- | --- | --- |
| Commission | Under 50 rental days in the month 10%, from 50 days 15%, from 100 days 20% | Under 50 rental days 5%, from 50 days 10%, from 100 days 15% |
| Credit | Walk-ins, handovers you close, partner visits and the rentals you source | Only the rentals you source. A website request you answer with the first offer during one of your blocks counts as yours. Walk-ins and partner deals earn nothing |
| Hours | You choose | At least 20 hours a week of Thursday to Sunday afternoons (noon to 6 pm, Toronto time), replying within 15 minutes to the chats, texts and calls assigned to you |
| Every day | Nothing set | Marketplace and classified reposts, social media DM replies, three follow-ups on every quote, long-term and business outreach |
| Every month | Nothing set | 400 touches. Under 400 when the month ends, the month''s rate is one tier lower: 15% becomes 10%, 10% becomes 5%, 5% becomes 2.5% |

## Remote: your duties

On **To do**, **Remote duties** shows this month''s touches against 400, today''s checklist, the peak hours you scheduled this week and your reply time.

1. Most touches count by themselves: an offer you send, a message or text you send from the portal, a live chat you answer (once a day for each chat), a call or text from the phone line, an ad you post, a call or message to a car owner.
2. For anything else press **Log a touch**: choose the type and add the link of the post, profile or listing if there is one.
3. The checklist ticks itself as the day''s touches come in. Three follow-ups on every quote stays open while a deal of yours has fewer than three.
4. Under My availability choose this week or next, press **Add a block** for each time you will be on, then **Save the week**. Days already past stay as they were.
5. A website request you answer with the first offer during a block is credited to you as sourced, even if you chose Entered for CarmaCars. Off your blocks it stays a claim for an Admin.

> Tip: An Admin can void a touch logged by mistake. Once an Admin approves a month, its mode, its rates and its touches no longer change; a refund can still lower the tier, as for everyone.

## My sales

Open **Me**, the **My sales** tab. It shows your own sales and commissions only.

1. Commissions comes first. Your rate depends on your mode and the rental days of the month: in person 10%, 15% from 50 days, 20% from 100; remote 5%, 10% and 15%. The bar shows your days against the target of 100, and says when your rate rises. By month gives each month in one line: the mode, the days, the rate and, for remote, the touches and any drop.
2. The tiles show this week: quotes created, offers sent, rentals added, bookings confirmed, conversion, booked revenue and follow-ups due. Press **By month** for months, **By week** for weeks.
3. By week (or By month) lists each period with the same figures, newest first.
4. Follow-ups due lists your open deals with what to do next: send the offer, follow up before the offer expires, or follow up while the renter signs and pays. Red means it is past due.
5. Deals lists every booking you created, added or sent an offer on in the last 180 days, with its status and what it counts. Open a request, an offer or a rental you added from its number.

| Figure | How it is counted |
| --- | --- |
| Credited to you | A quote you created, a rental you added, or a website request whose first offer you sent. An Admin can give a deal to someone else. |
| Quotes created, offers sent, rentals added | Counted on the day they happened. |
| Bookings confirmed, booked revenue | Counted on the day the booking was confirmed. |
| Conversion | Of the deals credited to you in the period, the share confirmed so far. |
| Booked revenue | The rental charge before tax, after discounts. A cancelled booking counts only what was kept; refunds come off. |
| Rental days (Sales) | The days of the completed, paid rentals you sourced that end in the month. The month''s tier applies to all of that month''s rentals. |

> Tip: Sales commissions are approved after the month ends, when the month''s tier is known. A refund that drops the month under a tier lowers every commission of that month; anything already paid comes off your next payment.

## Owners you bring in

Bring in car owners on **My work** > **My sales**, card **Owners you bring in**. Every owner you bring in is credited to you as "sourced by", with their cars. Only an Admin can change that later.

1. **Invite an owner**: enter their name, email and phone, tick **The owner asked me to send it**, then press **Send the invitation**. They get an email with your link to apply.
2. **Copy my owner link**: your own link to the application, for a message or a post. Anyone who applies with it is credited to you.
3. **Start an application**: you fill in the owner and the car for them, with **Take a photo** (or **Choose a photo**) of the ownership permit to fill in the car. It goes to an Admin as an application to approve. The terms and invoices are the Admin''s. A corporation that leases its cars to CarmaCars: choose **A corporation**, then Route **Fleet supplier: leases the cars to CarmaCars**, and each car''s tier (**Regular** or **Troubled**). A fleet supplier can also apply himself from `carmacars.ca/list-your-car`: your owner link works for it too.
4. The row of five figures follows your owners: **Invited**, **Applied**, **Approved**, **Car live** and **First paid rental**. Below, each owner shows their stage and their cars.

5. Someone who starts the application on the website and stops for 30 minutes comes to you: a task "Unfinished owner application" and their row on My sales (Lead). Call or text them; the follow-up emails go by themselves until they finish.

> Tip: An owner already on file, or invited first by another salesperson, cannot be invited again. Ask an Admin if you brought them in.

## Ask for your commission on an owner

There is no set amount. For each owner you bring in, you ask for one, and an Admin decides.

1. On the owner''s row press **Ask for a commission**.
2. Choose **A flat amount** and type it, or **A percent**: type the percent, choose what it is of (the company''s share of their cars'' rentals, or their cars'' rental revenue) and for how long (a number of months, or as long as the car is with us).
3. Add a note for the Admin if you like, then press **Send to an Admin**.
4. While it waits you can press **Change my request**. Once an Admin approves, changes or declines it, the row says so, with their note.

| Approved as | When it is earned |
| --- | --- |
| A flat amount | Once, at the owner''s first paid rental: the first completed rental of any of their cars, paid in full |
| A percent | On each completed, paid rental of their cars that ends after the approval, from the month of the first one, for the months approved |

> Tip: Nothing is earned before an Admin approves the request, and nothing on CarmaCars'' own cars, a partner''s, a shareholder''s or your own. Each commission then goes through the usual steps on My sales: pending approval, approved, paid.

## Buyer leads

1. **Buyer leads**: each request from the /buy pages, with the car, budget and timing.
2. Press **Take it** to make it yours, then call them.
3. Press **Update** to set the status. When you close a lead, say why.

> Tip: Owner leads are not here. The owners you invite or add are on **My sales**, **Owners you bring in**, and you see only your own. Customer service works the full owner pipeline.

An offer that has been expired for 7 days leaves Requests and offers and becomes a renter lead: you get the To do "Expired offer: win the renter back" (the lead goes to the Sales person with the fewest open leads) with the renter''s contact, the car and the dates they wanted. Call or text them, then mark the lead contacted or closed.

**Reopen offer** on an expired booking (or the **Expired** filter of Requests) sends the offer again in one click, open 24 hours unless you set the hours; a pickup time that has passed asks for new dates first. "Renter wants expired offer reopened" To dos come from the renter''s own button. The offer screens block **Send** with **Pickup time has passed: update it** until the pickup is moved.

## Book it now (release 33)
When you send an offer, tick **Book it now (no renter approval)** when the renter has already agreed. The offer goes out and an Admin approves it in one tap: the booking then waits for payment, the car is held, and the renter gets one link to sign and pay. You can also have them sign and pay with you: open the booking, **Sign now on this device**, then take the card on this device.
Already sent the offer? Ask the assistant: "Book the offer of CC-10482 now, the customer agreed by phone". It shows a card; **Confirm** sends the same request to an Admin, who approves in one tap.

## When a check stops the pickup or the return (release 33)
On the booking page, **What stops the pickup now** (or the return) lists each check that stops it, in plain words. When the trip must go ahead anyway, press **Ask an Admin to override the pickup** (or the return), give the actual time, the km and fuel if you know them, and why. An Admin gets an alert and approves in one tap; the pickup (or the return) is then recorded with the time you entered, and the booking''s history says who asked and who approved. You can cancel your request while it waits. A trip that happened and was never recorded: **Ask to record a past trip** with both times; once an Admin approves, the booking lands in Returned so the deposit can be settled.

## Leads and claims

Open **Leads**. Every lead is there: renter leads (forms, live chat, the phone number box, games, expired offers, requests not sent, missed calls, Live visitors), owner leads and partner leads, new and hot first. A new-lead alert on your phone opens that lead.

1. Press **Next lead**, or **Claim** on a card. The lead is yours for 15 minutes.
2. Press **Call**, **Text** or **Email**: your phone or mail app opens and the contact is logged. Each contact (or **Note**) adds 15 minutes, up to 60 minutes from your claim.
3. Press **Outcome**: Contacted, Call booked, Applied, Won or Lost (say why). Or **Mark handled** when there is nothing more to do.
4. Can''t finish? Press **Unclaim** so someone else can take it. A claim that runs out goes back to the pool by itself.

You hold at most 25 leads at once. Your numbers are on To do under **My leads**: leads claimed, won, close rate (won out of claimed), contacted, time to first contact and claims that ran out, today, this week and this month. Owner leads are also under **Owners** > **Leads**.
## Call minutes (release 35)
Your home shows **My call minutes**: today, this week and this month, for connected calls made with the site''s **Call** button. Customer numbers are hidden for Sales; call and text with the buttons on the page.


## Get a renter ready for the pickup (release 35)
Your work does not stop at the offer. Until the car is handed over you can do everything that gets the renter good to go:
- **Payment**: send a pay link or a deposit link on Money (text or email), or take the card on this device, also on a confirmed booking.
- **The offer**: edit it, send it again with a later expiry, withdraw it or record that the renter approved by phone, also while it waits for payment.
- **ID and coverage**: approve or reject the licence, the selfie and the proof of coverage, with the reason the renter sees.
- **Drivers and agreement**: send each additional driver their signing link, or the agreement again.
- **Name change asked for**: when a verified renter asks for a name or date of birth correction, it shows on the booking; check it against the licence, then **Approve** or **Decline**.

The booking page shows **Ready for the rental**: one line for each thing the pickup needs (offer accepted, paid, licence and selfie, coverage, deposit, drivers, agreement, add-ons in the car), green when done, with what to press when not. Refunds, cancellations, deposit releases and removing a paid add-on stay with customer service, Finance and Admins.

## The Prepare checklist (release 35)
On a booking with add-ons, **Prepare for the pickup** shows each add-on with its quantity, ticked or not by field staff, who ticked it and when, and the pickup or delivery job with its field person. It is on the booking and on the car page, for Sales, customer service, Fleet and Finance.

## Rebooking, intent and offers (release 35)

- A returning renter''s new request comes straight to you when you had their last booking, with the usual claim time.
- Each lead shows its intent (hot, warm or cold) and what the person said they want, read from calls with their transcripts, texts, emails, chat and visits. Call hot leads first.
- Offers are three steps: car and dates, price, review and send. Every version is kept; you can load an old one as a new offer.
- Prices stay between the owner''s daily minimum and maximum; only an Admin allows one outside them.
- Repeat renters who are verified can book instantly; their booking is marked Instant (repeat renter).
- Rewards: tell renters they earn points for a photo with their review and every rental after the first.

## Calls first, texts after (release 37)

Your main priority is always to be on the phone with people.

1. Answer a ringing call before anything else, and return a missed call at once.
2. **Call before you text.** On a lead, a renter or a booking, **Call** is the first button and **Text** the second.
3. A text is a follow-up: after a call attempt (no answer, a voicemail left), or when the person asked for a text.
4. On your To do and on **Unanswered**, missed calls and call-backs are listed above unanswered texts.

## A lead customer service is handling (release 37)

When customer service or Fleet are on a call with a lead, the lead and the lists say **Being handled by** their first name, their function and the time. Leave it alone: you cannot claim it, call, text or email it, or set an outcome, and **Next lead** skips it. When their time ends, the lead returns to you if you had a claim on it or brought it, else to the open list. The booking credit rules do not change.',
  '<p class="gd-p">You turn enquiries into bookings and owners into fleet: requests and offers, quotes for callers, and owner leads.</p><p class="gd-p">Your menu: To do, Today, My scorecard and My sales, then Requests and offers, Send an offer, Add a rental, New quote, Calendar and Buyer leads. The owners you bring in are on My sales.</p><section class="gd-task" id="sales-requests-offers-and-new-quotes" data-gd-task><h2 class="gd-h2">Requests, offers and new quotes</h2><div class="gd-stepblock gd-stepblock--below"><div class="gd-stepcol"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t"><b class="gd-ui">Requests and offers</b>: the same queue customer service works, showing only what you can answer now. A request still with customer service is folded under &quot;more not open to you yet&quot;, with the time it opens to you.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t"><b class="gd-ui">Rentals</b> &gt; <b class="gd-ui">Bookings</b>: <b class="gd-ui">My bookings</b>, every booking credited to you, offered by you or added by you, from the offer to the return, with its status, money and your commission (counting this month, waiting for approval, approved, paid).</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t"><b class="gd-ui">Send an offer</b>: one screen for a caller, sent at once, as in chapter 2. <b class="gd-ui">New quote</b> still makes a request to offer later.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t">An offer that is out: <b class="gd-ui">More actions</b> &gt; <b class="gd-ui">Edit the offer</b>, then <b class="gd-ui">Save and send the update</b>.</div></li></ol></div><figure class="gd-fig gd-fig--desk"><div class="gd-browser"><div class="gd-bar" aria-hidden="true"><i></i><i></i><i></i><span class="gd-addr">carmacars.ca/va/requests</span></div><div class="gd-imgwrap" style="aspect-ratio:1230/580"><img src="/guides/img/va-sales-02-requests-desktop-2ab1d17d.jpg" alt="" loading="lazy" decoding="async" width="1230" height="580"><span class="gd-pin" style="left:39.8%;top:59.5%" aria-hidden="true">1</span></div></div></figure></div><aside class="gd-box"><span class="gd-lbl">Tip</span><div>Your first reply target is 5 minutes, the &quot;Quote sent&quot; measure on your scorecard. Follow every offer out before it expires.</div></aside></section><section class="gd-task" id="sales-check-the-renter-s-licence" data-gd-task><h2 class="gd-h2">Check the renter&#39;s licence</h2><p class="gd-p">Sales approve the renter&#39;s licence like customer service: the licence front, the licence back and the selfie. The proof of coverage and the Protection Plan stay with customer service and Admins.</p><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">On <b class="gd-ui">To do</b>, <b class="gd-ui">Licences to check</b> lists each booking with an image waiting, the longest wait first. Press <b class="gd-ui">Review the licence</b>.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">On a booking, the card <b class="gd-ui">Renter licence</b> has the same: press <b class="gd-ui">Review the licence</b>.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Look at each image and each Flag line of the licence reader under the driver: no alteration, the selfie matches the licence photo.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t">One is wrong? Open <b class="gd-ui">Reject this one</b> under it, type the reason the renter reads and press <b class="gd-ui">Reject</b>. The renter is told and asked for a new image.</div></li><li><span class="gd-n" aria-hidden="true">5</span><div class="gd-t">Then press <b class="gd-ui">Approve all</b>: every image still waiting is approved at once. An image the system refuses is named with the reason.</div></li></ol></div><aside class="gd-box"><span class="gd-lbl">Tip</span><div>The booking history says who decided and the role, sales. Each opening of the images is logged and the links last one minute.</div></aside></section><section class="gd-task" id="sales-in-person-or-remote" data-gd-task><h2 class="gd-h2">In person or remote</h2><p class="gd-p">Every Sales person works in one of two modes, on the same Sales screens. An Admin sets yours; it shows at the top of To do and on My sales.</p><div class="gd-tablewrap"><table class="gd-table"><thead><tr><th scope="col"></th><th scope="col">In person (Toronto)</th><th scope="col">Remote (anywhere)</th></tr></thead><tbody><tr><td>Commission</td><td>Under 50 rental days in the month 10%, from 50 days 15%, from 100 days 20%</td><td>Under 50 rental days 5%, from 50 days 10%, from 100 days 15%</td></tr><tr><td>Credit</td><td>Walk-ins, handovers you close, partner visits and the rentals you source</td><td>Only the rentals you source. A website request you answer with the first offer during one of your blocks counts as yours. Walk-ins and partner deals earn nothing</td></tr><tr><td>Hours</td><td>You choose</td><td>At least 20 hours a week of Thursday to Sunday afternoons (noon to 6 pm, Toronto time), replying within 15 minutes to the chats, texts and calls assigned to you</td></tr><tr><td>Every day</td><td>Nothing set</td><td>Marketplace and classified reposts, social media DM replies, three follow-ups on every quote, long-term and business outreach</td></tr><tr><td>Every month</td><td>Nothing set</td><td>400 touches. Under 400 when the month ends, the month&#39;s rate is one tier lower: 15% becomes 10%, 10% becomes 5%, 5% becomes 2.5%</td></tr></tbody></table></div></section><section class="gd-task" id="sales-remote-your-duties" data-gd-task><h2 class="gd-h2">Remote: your duties</h2><p class="gd-p">On <b class="gd-ui">To do</b>, <b class="gd-ui">Remote duties</b> shows this month&#39;s touches against 400, today&#39;s checklist, the peak hours you scheduled this week and your reply time.</p><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">Most touches count by themselves: an offer you send, a message or text you send from the portal, a live chat you answer (once a day for each chat), a call or text from the phone line, an ad you post, a call or message to a car owner.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">For anything else press <b class="gd-ui">Log a touch</b>: choose the type and add the link of the post, profile or listing if there is one.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">The checklist ticks itself as the day&#39;s touches come in. Three follow-ups on every quote stays open while a deal of yours has fewer than three.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t">Under My availability choose this week or next, press <b class="gd-ui">Add a block</b> for each time you will be on, then <b class="gd-ui">Save the week</b>. Days already past stay as they were.</div></li><li><span class="gd-n" aria-hidden="true">5</span><div class="gd-t">A website request you answer with the first offer during a block is credited to you as sourced, even if you chose Entered for CarmaCars. Off your blocks it stays a claim for an Admin.</div></li></ol></div><aside class="gd-box"><span class="gd-lbl">Tip</span><div>An Admin can void a touch logged by mistake. Once an Admin approves a month, its mode, its rates and its touches no longer change; a refund can still lower the tier, as for everyone.</div></aside></section><section class="gd-task" id="sales-my-sales" data-gd-task><h2 class="gd-h2">My sales</h2><p class="gd-p">Open <b class="gd-ui">Me</b>, the <b class="gd-ui">My sales</b> tab. It shows your own sales and commissions only.</p><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">Commissions comes first. Your rate depends on your mode and the rental days of the month: in person 10%, 15% from 50 days, 20% from 100; remote 5%, 10% and 15%. The bar shows your days against the target of 100, and says when your rate rises. By month gives each month in one line: the mode, the days, the rate and, for remote, the touches and any drop.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">The tiles show this week: quotes created, offers sent, rentals added, bookings confirmed, conversion, booked revenue and follow-ups due. Press <b class="gd-ui">By month</b> for months, <b class="gd-ui">By week</b> for weeks.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">By week (or By month) lists each period with the same figures, newest first.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t">Follow-ups due lists your open deals with what to do next: send the offer, follow up before the offer expires, or follow up while the renter signs and pays. Red means it is past due.</div></li><li><span class="gd-n" aria-hidden="true">5</span><div class="gd-t">Deals lists every booking you created, added or sent an offer on in the last 180 days, with its status and what it counts. Open a request, an offer or a rental you added from its number.</div></li></ol></div><div class="gd-tablewrap"><table class="gd-table"><thead><tr><th scope="col">Figure</th><th scope="col">How it is counted</th></tr></thead><tbody><tr><td>Credited to you</td><td>A quote you created, a rental you added, or a website request whose first offer you sent. An Admin can give a deal to someone else.</td></tr><tr><td>Quotes created, offers sent, rentals added</td><td>Counted on the day they happened.</td></tr><tr><td>Bookings confirmed, booked revenue</td><td>Counted on the day the booking was confirmed.</td></tr><tr><td>Conversion</td><td>Of the deals credited to you in the period, the share confirmed so far.</td></tr><tr><td>Booked revenue</td><td>The rental charge before tax, after discounts. A cancelled booking counts only what was kept; refunds come off.</td></tr><tr><td>Rental days (Sales)</td><td>The days of the completed, paid rentals you sourced that end in the month. The month&#39;s tier applies to all of that month&#39;s rentals.</td></tr></tbody></table></div><aside class="gd-box"><span class="gd-lbl">Tip</span><div>Sales commissions are approved after the month ends, when the month&#39;s tier is known. A refund that drops the month under a tier lowers every commission of that month; anything already paid comes off your next payment.</div></aside></section><section class="gd-task" id="sales-owners-you-bring-in" data-gd-task><h2 class="gd-h2">Owners you bring in</h2><p class="gd-p">Bring in car owners on <b class="gd-ui">My work</b> &gt; <b class="gd-ui">My sales</b>, card <b class="gd-ui">Owners you bring in</b>. Every owner you bring in is credited to you as &quot;sourced by&quot;, with their cars. Only an Admin can change that later.</p><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t"><b class="gd-ui">Invite an owner</b>: enter their name, email and phone, tick <b class="gd-ui">The owner asked me to send it</b>, then press <b class="gd-ui">Send the invitation</b>. They get an email with your link to apply.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t"><b class="gd-ui">Copy my owner link</b>: your own link to the application, for a message or a post. Anyone who applies with it is credited to you.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t"><b class="gd-ui">Start an application</b>: you fill in the owner and the car for them, with <b class="gd-ui">Take a photo</b> (or <b class="gd-ui">Choose a photo</b>) of the ownership permit to fill in the car. It goes to an Admin as an application to approve. The terms and invoices are the Admin&#39;s. A corporation that leases its cars to CarmaCars: choose <b class="gd-ui">A corporation</b>, then Route <b class="gd-ui">Fleet supplier: leases the cars to CarmaCars</b>, and each car&#39;s tier (<b class="gd-ui">Regular</b> or <b class="gd-ui">Troubled</b>). A fleet supplier can also apply himself from <span class="gd-url">carmacars.ca/list-your-car</span>: your owner link works for it too.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t">The row of five figures follows your owners: <b class="gd-ui">Invited</b>, <b class="gd-ui">Applied</b>, <b class="gd-ui">Approved</b>, <b class="gd-ui">Car live</b> and <b class="gd-ui">First paid rental</b>. Below, each owner shows their stage and their cars.</div></li></ol></div><div class="gd-stepblock"><ol class="gd-ol" start="5"><li><span class="gd-n" aria-hidden="true">5</span><div class="gd-t">Someone who starts the application on the website and stops for 30 minutes comes to you: a task &quot;Unfinished owner application&quot; and their row on My sales (Lead). Call or text them; the follow-up emails go by themselves until they finish.</div></li></ol></div><aside class="gd-box"><span class="gd-lbl">Tip</span><div>An owner already on file, or invited first by another salesperson, cannot be invited again. Ask an Admin if you brought them in.</div></aside></section><section class="gd-task" id="sales-ask-for-your-commission-on-an-owner" data-gd-task><h2 class="gd-h2">Ask for your commission on an owner</h2><p class="gd-p">There is no set amount. For each owner you bring in, you ask for one, and an Admin decides.</p><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">On the owner&#39;s row press <b class="gd-ui">Ask for a commission</b>.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Choose <b class="gd-ui">A flat amount</b> and type it, or <b class="gd-ui">A percent</b>: type the percent, choose what it is of (the company&#39;s share of their cars&#39; rentals, or their cars&#39; rental revenue) and for how long (a number of months, or as long as the car is with us).</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Add a note for the Admin if you like, then press <b class="gd-ui">Send to an Admin</b>.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t">While it waits you can press <b class="gd-ui">Change my request</b>. Once an Admin approves, changes or declines it, the row says so, with their note.</div></li></ol></div><div class="gd-tablewrap"><table class="gd-table"><thead><tr><th scope="col">Approved as</th><th scope="col">When it is earned</th></tr></thead><tbody><tr><td>A flat amount</td><td>Once, at the owner&#39;s first paid rental: the first completed rental of any of their cars, paid in full</td></tr><tr><td>A percent</td><td>On each completed, paid rental of their cars that ends after the approval, from the month of the first one, for the months approved</td></tr></tbody></table></div><aside class="gd-box"><span class="gd-lbl">Tip</span><div>Nothing is earned before an Admin approves the request, and nothing on CarmaCars&#39; own cars, a partner&#39;s, a shareholder&#39;s or your own. Each commission then goes through the usual steps on My sales: pending approval, approved, paid.</div></aside></section><section class="gd-task" id="sales-buyer-leads" data-gd-task><h2 class="gd-h2">Buyer leads</h2><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t"><b class="gd-ui">Buyer leads</b>: each request from the /buy pages, with the car, budget and timing.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Press <b class="gd-ui">Take it</b> to make it yours, then call them.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Press <b class="gd-ui">Update</b> to set the status. When you close a lead, say why.</div></li></ol></div><aside class="gd-box"><span class="gd-lbl">Tip</span><div>Owner leads are not here. The owners you invite or add are on <b class="gd-ui">My sales</b>, <b class="gd-ui">Owners you bring in</b>, and you see only your own. Customer service works the full owner pipeline.</div></aside><p class="gd-p">An offer that has been expired for 7 days leaves Requests and offers and becomes a renter lead: you get the To do &quot;Expired offer: win the renter back&quot; (the lead goes to the Sales person with the fewest open leads) with the renter&#39;s contact, the car and the dates they wanted. Call or text them, then mark the lead contacted or closed.</p><p class="gd-p"><b class="gd-ui">Reopen offer</b> on an expired booking (or the <b class="gd-ui">Expired</b> filter of Requests) sends the offer again in one click, open 24 hours unless you set the hours; a pickup time that has passed asks for new dates first. &quot;Renter wants expired offer reopened&quot; To dos come from the renter&#39;s own button. The offer screens block <b class="gd-ui">Send</b> with <b class="gd-ui">Pickup time has passed: update it</b> until the pickup is moved.</p></section><section class="gd-task" id="sales-book-it-now-release-33" data-gd-task><h2 class="gd-h2">Book it now (release 33)</h2><p class="gd-p">When you send an offer, tick <b class="gd-ui">Book it now (no renter approval)</b> when the renter has already agreed. The offer goes out and an Admin approves it in one tap: the booking then waits for payment, the car is held, and the renter gets one link to sign and pay. You can also have them sign and pay with you: open the booking, <b class="gd-ui">Sign now on this device</b>, then take the card on this device. Already sent the offer? Ask the assistant: &quot;Book the offer of CC-10482 now, the customer agreed by phone&quot;. It shows a card; <b class="gd-ui">Confirm</b> sends the same request to an Admin, who approves in one tap.</p></section><section class="gd-task" id="sales-when-a-check-stops-the-pickup-or-the-return-release-33" data-gd-task><h2 class="gd-h2">When a check stops the pickup or the return (release 33)</h2><p class="gd-p">On the booking page, <b class="gd-ui">What stops the pickup now</b> (or the return) lists each check that stops it, in plain words. When the trip must go ahead anyway, press <b class="gd-ui">Ask an Admin to override the pickup</b> (or the return), give the actual time, the km and fuel if you know them, and why. An Admin gets an alert and approves in one tap; the pickup (or the return) is then recorded with the time you entered, and the booking&#39;s history says who asked and who approved. You can cancel your request while it waits. A trip that happened and was never recorded: <b class="gd-ui">Ask to record a past trip</b> with both times; once an Admin approves, the booking lands in Returned so the deposit can be settled.</p></section><section class="gd-task" id="sales-leads-and-claims" data-gd-task><h2 class="gd-h2">Leads and claims</h2><p class="gd-p">Open <b class="gd-ui">Leads</b>. Every lead is there: renter leads (forms, live chat, the phone number box, games, expired offers, requests not sent, missed calls, Live visitors), owner leads and partner leads, new and hot first. A new-lead alert on your phone opens that lead.</p><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">Press <b class="gd-ui">Next lead</b>, or <b class="gd-ui">Claim</b> on a card. The lead is yours for 15 minutes.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Press <b class="gd-ui">Call</b>, <b class="gd-ui">Text</b> or <b class="gd-ui">Email</b>: your phone or mail app opens and the contact is logged. Each contact (or <b class="gd-ui">Note</b>) adds 15 minutes, up to 60 minutes from your claim.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Press <b class="gd-ui">Outcome</b>: Contacted, Call booked, Applied, Won or Lost (say why). Or <b class="gd-ui">Mark handled</b> when there is nothing more to do.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t">Can&#39;t finish? Press <b class="gd-ui">Unclaim</b> so someone else can take it. A claim that runs out goes back to the pool by itself.</div></li></ol></div><p class="gd-p">You hold at most 25 leads at once. Your numbers are on To do under <b class="gd-ui">My leads</b>: leads claimed, won, close rate (won out of claimed), contacted, time to first contact and claims that ran out, today, this week and this month. Owner leads are also under <b class="gd-ui">Owners</b> &gt; <b class="gd-ui">Leads</b>.</p></section><section class="gd-task" id="sales-call-minutes-release-35" data-gd-task><h2 class="gd-h2">Call minutes (release 35)</h2><p class="gd-p">Your home shows <b class="gd-ui">My call minutes</b>: today, this week and this month, for connected calls made with the site&#39;s <b class="gd-ui">Call</b> button. Customer numbers are hidden for Sales; call and text with the buttons on the page.</p></section><section class="gd-task" id="sales-get-a-renter-ready-for-the-pickup-release-35" data-gd-task><h2 class="gd-h2">Get a renter ready for the pickup (release 35)</h2><p class="gd-p">Your work does not stop at the offer. Until the car is handed over you can do everything that gets the renter good to go:</p><ul class="gd-ul"><li><b class="gd-ui">Payment</b>: send a pay link or a deposit link on Money (text or email), or take the card on this device, also on a confirmed booking.</li><li><b class="gd-ui">The offer</b>: edit it, send it again with a later expiry, withdraw it or record that the renter approved by phone, also while it waits for payment.</li><li><b class="gd-ui">ID and coverage</b>: approve or reject the licence, the selfie and the proof of coverage, with the reason the renter sees.</li><li><b class="gd-ui">Drivers and agreement</b>: send each additional driver their signing link, or the agreement again.</li><li><b class="gd-ui">Name change asked for</b>: when a verified renter asks for a name or date of birth correction, it shows on the booking; check it against the licence, then <b class="gd-ui">Approve</b> or <b class="gd-ui">Decline</b>.</li></ul><p class="gd-p">The booking page shows <b class="gd-ui">Ready for the rental</b>: one line for each thing the pickup needs (offer accepted, paid, licence and selfie, coverage, deposit, drivers, agreement, add-ons in the car), green when done, with what to press when not. Refunds, cancellations, deposit releases and removing a paid add-on stay with customer service, Finance and Admins.</p></section><section class="gd-task" id="sales-the-prepare-checklist-release-35" data-gd-task><h2 class="gd-h2">The Prepare checklist (release 35)</h2><p class="gd-p">On a booking with add-ons, <b class="gd-ui">Prepare for the pickup</b> shows each add-on with its quantity, ticked or not by field staff, who ticked it and when, and the pickup or delivery job with its field person. It is on the booking and on the car page, for Sales, customer service, Fleet and Finance.</p></section><section class="gd-task" id="sales-rebooking-intent-and-offers-release-35" data-gd-task><h2 class="gd-h2">Rebooking, intent and offers (release 35)</h2><ul class="gd-ul"><li>A returning renter&#39;s new request comes straight to you when you had their last booking, with the usual claim time.</li><li>Each lead shows its intent (hot, warm or cold) and what the person said they want, read from calls with their transcripts, texts, emails, chat and visits. Call hot leads first.</li><li>Offers are three steps: car and dates, price, review and send. Every version is kept; you can load an old one as a new offer.</li><li>Prices stay between the owner&#39;s daily minimum and maximum; only an Admin allows one outside them.</li><li>Repeat renters who are verified can book instantly; their booking is marked Instant (repeat renter).</li><li>Rewards: tell renters they earn points for a photo with their review and every rental after the first.</li></ul></section><section class="gd-task" id="sales-calls-first-texts-after-release-37" data-gd-task><h2 class="gd-h2">Calls first, texts after (release 37)</h2><p class="gd-p">Your main priority is always to be on the phone with people.</p><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">Answer a ringing call before anything else, and return a missed call at once.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t"><b class="gd-ui">Call before you text.</b> On a lead, a renter or a booking, <b class="gd-ui">Call</b> is the first button and <b class="gd-ui">Text</b> the second.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">A text is a follow-up: after a call attempt (no answer, a voicemail left), or when the person asked for a text.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t">On your To do and on <b class="gd-ui">Unanswered</b>, missed calls and call-backs are listed above unanswered texts.</div></li></ol></div></section><section class="gd-task" id="sales-a-lead-customer-service-is-handling-release-37" data-gd-task><h2 class="gd-h2">A lead customer service is handling (release 37)</h2><p class="gd-p">When customer service or Fleet are on a call with a lead, the lead and the lists say <b class="gd-ui">Being handled by</b> their first name, their function and the time. Leave it alone: you cannot claim it, call, text or email it, or set an outcome, and <b class="gd-ui">Next lead</b> skips it. When their time ends, the lead returns to you if you had a claim on it or brought it, else to the open list. The booking credit rules do not change.</p></section>');
select app.guide_release_section('va', 'commissions', 'chapter', 'add-a-rental-by-hand', 'Every function earns a commission on the rentals it sources: a renter you found yourself. Say so when you enter the rental, the quote or the offer.

## Mark who found the client

Every rental, quote and offer you enter asks: **I sourced this client** or **Entered for CarmaCars**.

1. Choose **I sourced this client** when you found the renter yourself: someone you know, your own post or your own outreach.
2. Choose **Entered for CarmaCars** when the renter came to CarmaCars: the website, the phone line, a walk-in, a partner.
3. A website request earns nothing by itself. If you sourced it anyway, choose I sourced this client on its offer: an Admin decides.

|  | Commission |
| --- | --- |
| Sales | Commission only, with no base pay. By the rental days of the month, on all of that month''s rentals: in person under 50 days 10%, from 50 days 15%, from 100 days 20%; remote 5%, 10% and 15%, one tier lower in a month under 400 touches (chapter Sales) |
| Customer service, finance, fleet | 10% |
| An owner you bring in (Sales) | What you ask for and an Admin approves: a flat amount at the owner''s first paid rental, or a percent of their cars'' rentals for a time (chapter Sales). A CarmaCars expense: it never changes the owner''s revenue |
| How much | The rate on the rental charge before tax, after discounts, with late extra days, plus the add-ons (release 35: the same rate on each confirmed add-on''s own charge before tax; not prepaid fuel). Never on delivery, kilometres, young driver, the Protection Plan or other fees. Only a refund of the rental charge, or an add-on removed after booking, comes off |
| When earned | When the rental is completed and paid in full. Never on a cancelled, refunded, unpaid or charged-back rental, or on your own or a household rental |
| Your home address | It must be in your profile. Until it is, a commission waits as not earned yet, and you cannot add a rental or mark I sourced this client |
| Paid | After an Admin approves it, by transfer or on your pay statement. My sales shows each step: not earned yet, pending approval, approved, paid, reversed |

> Tip: A refund or chargeback after a commission was paid comes off your next payment. Your staff agreement has the full rule.
', 'Commissions', 'I sourced this client, your rate, when it is earned, approved and paid.',
  'Sales (and field staff) earn a commission on the rentals they source: a renter you found yourself. Say so when you enter the rental, the quote or the offer. Customer service, Fleet and Finance earn no commission and no sales credit: your help is credited on the booking (Helped by) and on your scorecard.

## Mark who found the client

Every rental, quote and offer you enter asks: **I sourced this client** or **Entered for CarmaCars**.

1. Choose **I sourced this client** when you found the renter yourself: someone you know, your own post or your own outreach.
2. Choose **Entered for CarmaCars** when the renter came to CarmaCars: the website, the phone line, a walk-in, a partner.
3. A website request earns nothing by itself. If you sourced it anyway, choose I sourced this client on its offer: an Admin decides.

|  | Commission |
| --- | --- |
| Sales | Commission only, with no base pay. By the rental days of the month, on all of that month''s rentals: in person under 50 days 10%, from 50 days 15%, from 100 days 20%; remote 5%, 10% and 15%, one tier lower in a month under 400 touches (chapter Sales) |
| Customer service, Fleet, Finance | No commission and no sales credit, whichever you choose above. Your help is credited as Helped by on the booking and counted on your scorecard |
| An owner you bring in (Sales) | What you ask for and an Admin approves: a flat amount at the owner''s first paid rental, or a percent of their cars'' rentals for a time (chapter Sales). A CarmaCars expense: it never changes the owner''s revenue |
| How much | The rate on the rental charge before tax, after discounts, with late extra days, plus the add-ons (release 35: the same rate on each confirmed add-on''s own charge before tax; not prepaid fuel). Never on delivery, kilometres, young driver, the Protection Plan or other fees. Only a refund of the rental charge, or an add-on removed after booking, comes off |
| When earned | When the rental is completed and paid in full. Never on a cancelled, refunded, unpaid or charged-back rental, or on your own or a household rental |
| Your home address | It must be in your profile. Until it is, a commission waits as not earned yet, and you cannot add a rental or mark I sourced this client |
| Paid | After an Admin approves it, by transfer or on your pay statement. My sales shows each step: not earned yet, pending approval, approved, paid, reversed |

> Tip: A refund or chargeback after a commission was paid comes off your next payment. Your staff agreement has the full rule.
',
  '<p class="gd-p">Sales (and field staff) earn a commission on the rentals they source: a renter you found yourself. Say so when you enter the rental, the quote or the offer. Customer service, Fleet and Finance earn no commission and no sales credit: your help is credited on the booking (Helped by) and on your scorecard.</p><section class="gd-task" id="commissions-mark-who-found-the-client" data-gd-task><h2 class="gd-h2">Mark who found the client</h2><p class="gd-p">Every rental, quote and offer you enter asks: <b class="gd-ui">I sourced this client</b> or <b class="gd-ui">Entered for CarmaCars</b>.</p><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">Choose <b class="gd-ui">I sourced this client</b> when you found the renter yourself: someone you know, your own post or your own outreach.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Choose <b class="gd-ui">Entered for CarmaCars</b> when the renter came to CarmaCars: the website, the phone line, a walk-in, a partner.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">A website request earns nothing by itself. If you sourced it anyway, choose I sourced this client on its offer: an Admin decides.</div></li></ol></div><div class="gd-tablewrap"><table class="gd-table"><thead><tr><th scope="col"></th><th scope="col">Commission</th></tr></thead><tbody><tr><td>Sales</td><td>Commission only, with no base pay. By the rental days of the month, on all of that month&#39;s rentals: in person under 50 days 10%, from 50 days 15%, from 100 days 20%; remote 5%, 10% and 15%, one tier lower in a month under 400 touches (chapter Sales)</td></tr><tr><td>Customer service, Fleet, Finance</td><td>No commission and no sales credit, whichever you choose above. Your help is credited as Helped by on the booking and counted on your scorecard</td></tr><tr><td>An owner you bring in (Sales)</td><td>What you ask for and an Admin approves: a flat amount at the owner&#39;s first paid rental, or a percent of their cars&#39; rentals for a time (chapter Sales). A CarmaCars expense: it never changes the owner&#39;s revenue</td></tr><tr><td>How much</td><td>The rate on the rental charge before tax, after discounts, with late extra days, plus the add-ons (release 35: the same rate on each confirmed add-on&#39;s own charge before tax; not prepaid fuel). Never on delivery, kilometres, young driver, the Protection Plan or other fees. Only a refund of the rental charge, or an add-on removed after booking, comes off</td></tr><tr><td>When earned</td><td>When the rental is completed and paid in full. Never on a cancelled, refunded, unpaid or charged-back rental, or on your own or a household rental</td></tr><tr><td>Your home address</td><td>It must be in your profile. Until it is, a commission waits as not earned yet, and you cannot add a rental or mark I sourced this client</td></tr><tr><td>Paid</td><td>After an Admin approves it, by transfer or on your pay statement. My sales shows each step: not earned yet, pending approval, approved, paid, reversed</td></tr></tbody></table></div><aside class="gd-box"><span class="gd-lbl">Tip</span><div>A refund or chargeback after a commission was paid comes off your next payment. Your staff agreement has the full rule.</div></aside></section>');
select app.guide_release_section('va', 'texts-and-calls', 'chapter', 'live-visitors-and-live-chat', 'Customer service and Sales answer texts to the CarmaCars number in the same place as live chat. Every call and text is kept with the renter, owner or lead it belongs to.

## Answer a text

1. Open **Visitors**, the **Chat** tab, and press **Texts and calls**. Unread texts and missed calls are counted on each number.
2. Choose a number: calls and texts in order, and beside them who it is, with their bookings.
3. Write the text and press **Send text**. It goes from the CarmaCars number.
4. **Suggest a reply** writes a draft into the box. Read it and change it: it is never sent until you press Send text.

## Unknown callers

Press **Unknown callers**. Type the name if they told you and press **Create lead**, or find the renter and press **Link to** their name.

Quo''s contacts follow the site: everyone on the site with a phone number is a contact in Quo under the same name, added or updated within about five minutes. Change a name or number on the site, not in Quo: the site''s version is sent again.

## Missed calls

A missed call gives you the task "Missed call from ..." when you have Live chat or Texts and calls open; otherwise it waits in the customer service queue. Call back with the Call button, or text, then mark the task done. Quo itself texts the caller back, so do not send the same message again.

> Tip: A number that texted STOP gets no texts from us, booking texts included, until they text START. Prices go in a quote, never in a text from memory.

## Email, text or both

Each renter and owner chooses how we reach them. Their page in Admin shows it under How we reach them; ask an Admin, or change it there if you can open the page. Texts need a phone they verified with a code. Your own choice is on your Profile, under Messages.


## Call and Text buttons

Every Call and Text button in the staff portal (a booking, a renter, the Now view, the map''s cards, Visitors, the field jobs) goes through Quo, from the CarmaCars number.

1. Press **Text**: a small window opens with the person and the number. Write the text (sign it CarmaCars) and press **Send**. It goes out from the CarmaCars number at once and is kept in the person''s conversation under **Visitors** > **Chat** > **Texts and calls** (customer service and Sales); press **Open the conversation** to see it there. A number that asked for no texts is refused with the reason.
2. Press **Call**: on a phone the Quo app opens with the number in its dialer; press call there. On a computer the Quo web app opens in a new tab and the number is copied: open the dialer (Alt+C, or Ctrl+C on a Mac) and paste it. If Quo''s desktop app is your computer''s calling app, tick **On this computer, call with the Quo desktop app** once: Call then opens it straight away. Every call is noted on the conversation as Call started from the site, and Quo adds the call itself when it ends.
3. Fleet, finance and field staff can call and text the people of their work (renters, owners, leads and staff); customer service and Sales any number.
4. An Admin can switch the buttons back to the phone''s own apps in Program settings. With Phone and texts off, the buttons use the phone''s own apps too.

## Who is calling: the caller pop-up (release 34)

Customer service: when someone calls the CarmaCars number, a panel opens at the bottom right of every page of your portal (across the bottom on a phone) while the phone rings, and stays while the call goes on and for 3 minutes after it ends.

1. A renter: their name, the booking on rent (or the next one coming) with the car, the balance they owe now (**overdue** when a payment is late), the deposit (held, waived, released, or not taken yet), what they are waiting on (a request, an offer, a change, a question to them, an open To do) and the last three notes.
2. Write what the call was about in **Note about this call** and press **Add note**. It is kept on the renter with the time, your name and the booking.
3. **Open the renter''s page** opens their record. If it is outside your window, opening it from their call is logged as an opening for 24 hours with the reason Incoming call, as **Open with a reason** is.
4. An unknown number shows **Unknown caller**: press **Create lead** to keep it as a phone lead.
5. Press the cross to close a call; it stays closed in this browser.

## Renter notes (release 34)

A renter''s record (**Find a renter**, then Open) has **Add a note**, and the notes are in its Activity log (chip **Notes**), newest first, each with the date and time, who wrote it and their role. Add a note for every situation: what they asked, what you told them, what happens next. Notes cannot be changed or removed by staff, so write a new note to correct one; an Admin can remove a note with a reason. The notes also show on the caller pop-up and on a renter''s conversation in Texts and calls.

## Lanes, the Call button and hidden numbers (release 35)
1. Each conversation has a lane: **Fleet** for a car on rent, or a pickup, return, delivery or collection within a day; **Customer service** for the rest. The inbox has a tab for each. The caller pop-up rings for Fleet first on Fleet''s calls; customer service gets them when no Fleet staff member is on duty or nobody answered within 20 seconds.
2. **Call** rings your own phone first (the cell number in your profile). Answer it and we connect the customer, who sees the CarmaCars number. The call is noted on their history with its length. Until calling from the site is set up, **Call** opens Quo as before and says why.
3. Sales sees customer numbers hidden, like (647) •••-••00. Use **Call** and **Text** on the page: the number is found on our side. Search by phone still works.
', 'Texts and calls', 'Reading and answering texts, suggestions, unknown callers and missed calls.',
  'Customer service and Sales answer texts to the CarmaCars number in the same place as live chat. Every call and text is kept with the renter, owner or lead it belongs to.

## Answer a text

1. Open **Visitors**, the **Chat** tab, and press **Texts and calls**. Unread texts and missed calls are counted on each number.
2. Choose a number: calls and texts in order, and beside them who it is, with their bookings.
3. Write the text and press **Send text**. It goes from the CarmaCars number.
4. **Suggest a reply** writes a draft into the box. Read it and change it: it is never sent until you press Send text.

## Unknown callers

Press **Unknown callers**. Type the name if they told you and press **Create lead**, or find the renter and press **Link to** their name.

Quo''s contacts follow the site: everyone on the site with a phone number is a contact in Quo under the same name, added or updated within about five minutes. Change a name or number on the site, not in Quo: the site''s version is sent again.

## Missed calls

A missed call gives you the task "Missed call from ..." when you have Live chat or Texts and calls open; otherwise it waits in the customer service queue. Call back with the Call button, or text, then mark the task done. Quo itself texts the caller back, so do not send the same message again.

> Tip: A number that texted STOP gets no texts from us, booking texts included, until they text START. Prices go in a quote, never in a text from memory.

## Email, text or both

Each renter and owner chooses how we reach them. Their page in Admin shows it under How we reach them; ask an Admin, or change it there if you can open the page. Texts need a phone they verified with a code. Your own choice is on your Profile, under Messages.


## Call and Text buttons

Every Call and Text button in the staff portal (a booking, a renter, the Now view, the map''s cards, Visitors, the field jobs) goes through Quo, from the CarmaCars number.

1. Press **Text**: a small window opens with the person and the number. Write the text (sign it CarmaCars) and press **Send**. It goes out from the CarmaCars number at once and is kept in the person''s conversation under **Visitors** > **Chat** > **Texts and calls** (customer service and Sales); press **Open the conversation** to see it there. A number that asked for no texts is refused with the reason.
2. Press **Call**: on a phone the Quo app opens with the number in its dialer; press call there. On a computer the Quo web app opens in a new tab and the number is copied: open the dialer (Alt+C, or Ctrl+C on a Mac) and paste it. If Quo''s desktop app is your computer''s calling app, tick **On this computer, call with the Quo desktop app** once: Call then opens it straight away. Every call is noted on the conversation as Call started from the site, and Quo adds the call itself when it ends.
3. Fleet, finance and field staff can call and text the people of their work (renters, owners, leads and staff); customer service and Sales any number.
4. An Admin can switch the buttons back to the phone''s own apps in Program settings. With Phone and texts off, the buttons use the phone''s own apps too.

## Who is calling: the caller pop-up (release 34)

Customer service: when someone calls the CarmaCars number, a panel opens at the bottom right of every page of your portal (across the bottom on a phone) while the phone rings, and stays while the call goes on and for 3 minutes after it ends.

1. A renter: their name, the booking on rent (or the next one coming) with the car, the balance they owe now (**overdue** when a payment is late), the deposit (held, waived, released, or not taken yet), what they are waiting on (a request, an offer, a change, a question to them, an open To do) and the last three notes.
2. Write what the call was about in **Note about this call** and press **Add note**. It is kept on the renter with the time, your name and the booking.
3. **Open the renter''s page** opens their record. If it is outside your window, opening it from their call is logged as an opening for 24 hours with the reason Incoming call, as **Open with a reason** is.
4. An unknown number shows **Unknown caller**: press **Create lead** to keep it as a phone lead.
5. Press the cross to close a call; it stays closed in this browser.

## Renter notes (release 34)

A renter''s record (**Find a renter**, then Open) has **Add a note**, and the notes are in its Activity log (chip **Notes**), newest first, each with the date and time, who wrote it and their role. Add a note for every situation: what they asked, what you told them, what happens next. Notes cannot be changed or removed by staff, so write a new note to correct one; an Admin can remove a note with a reason. The notes also show on the caller pop-up and on a renter''s conversation in Texts and calls.

## Lanes, the Call button and hidden numbers (release 35)
1. Each conversation has a lane: **Fleet** for a car on rent, or a pickup, return, delivery or collection within a day; **Customer service** for the rest. The inbox has a tab for each. The caller pop-up rings for Fleet first on Fleet''s calls; customer service gets them when no Fleet staff member is on duty or nobody answered within 20 seconds.
2. **Call** rings your own phone first (the cell number in your profile). Answer it and we connect the customer, who sees the CarmaCars number. The call is noted on their history with its length. Until calling from the site is set up, **Call** opens Quo as before and says why.
3. Sales sees customer numbers hidden, like (647) •••-••00. Use **Call** and **Text** on the page: the number is found on our side. Search by phone still works.

## Calls first, texts after (release 37)

Your main priority is always to be on the phone with people.

1. Answer a ringing call before anything else, and return a missed call at once.
2. **Call before you text.** On a lead, a renter or a booking, **Call** is the first button and **Text** the second.
3. A text is a follow-up: after a call attempt (no answer, a voicemail left), or when the person asked for a text.
4. On your To do and on **Unanswered**, missed calls and call-backs are listed above unanswered texts.

## A lead you handle on a call (release 37)

When you answer or place a call with a lead, add a note on it, or create it from a call, the lead is yours for a limited time (15 minutes, as a Sales claim; an Admin can change it in **Settings** > **Sales**). Every call you handle adds the time again.

- Sales see **Being handled by** your first name and your function with the time, on the lead and in every list. They cannot claim it, call, text or email it, or set an outcome meanwhile, and **Next lead** skips it.
- Another customer service or Fleet person can still work it; their call or note takes the hold over.
- When it ends, the lead goes back to the salesperson who had a claim on it or who brought it, else to the open list. An Admin can **Release hold** earlier.
- A booking made from the lead is credited as always: customer service and Fleet get no sales commission for it.
- Nobody who has not finished onboarding holds a lead.
',
  '<p class="gd-p">Customer service and Sales answer texts to the CarmaCars number in the same place as live chat. Every call and text is kept with the renter, owner or lead it belongs to.</p><section class="gd-task" id="texts-and-calls-answer-a-text" data-gd-task><h2 class="gd-h2">Answer a text</h2><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">Open <b class="gd-ui">Visitors</b>, the <b class="gd-ui">Chat</b> tab, and press <b class="gd-ui">Texts and calls</b>. Unread texts and missed calls are counted on each number.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Choose a number: calls and texts in order, and beside them who it is, with their bookings.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Write the text and press <b class="gd-ui">Send text</b>. It goes from the CarmaCars number.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t"><b class="gd-ui">Suggest a reply</b> writes a draft into the box. Read it and change it: it is never sent until you press Send text.</div></li></ol></div></section><section class="gd-task" id="texts-and-calls-unknown-callers" data-gd-task><h2 class="gd-h2">Unknown callers</h2><p class="gd-p">Press <b class="gd-ui">Unknown callers</b>. Type the name if they told you and press <b class="gd-ui">Create lead</b>, or find the renter and press <b class="gd-ui">Link to</b> their name.</p><p class="gd-p">Quo&#39;s contacts follow the site: everyone on the site with a phone number is a contact in Quo under the same name, added or updated within about five minutes. Change a name or number on the site, not in Quo: the site&#39;s version is sent again.</p></section><section class="gd-task" id="texts-and-calls-missed-calls" data-gd-task><h2 class="gd-h2">Missed calls</h2><p class="gd-p">A missed call gives you the task &quot;Missed call from ...&quot; when you have Live chat or Texts and calls open; otherwise it waits in the customer service queue. Call back with the Call button, or text, then mark the task done. Quo itself texts the caller back, so do not send the same message again.</p><aside class="gd-box"><span class="gd-lbl">Tip</span><div>A number that texted STOP gets no texts from us, booking texts included, until they text START. Prices go in a quote, never in a text from memory.</div></aside></section><section class="gd-task" id="texts-and-calls-email-text-or-both" data-gd-task><h2 class="gd-h2">Email, text or both</h2><p class="gd-p">Each renter and owner chooses how we reach them. Their page in Admin shows it under How we reach them; ask an Admin, or change it there if you can open the page. Texts need a phone they verified with a code. Your own choice is on your Profile, under Messages.</p></section><section class="gd-task" id="texts-and-calls-call-and-text-buttons" data-gd-task><h2 class="gd-h2">Call and Text buttons</h2><p class="gd-p">Every Call and Text button in the staff portal (a booking, a renter, the Now view, the map&#39;s cards, Visitors, the field jobs) goes through Quo, from the CarmaCars number.</p><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">Press <b class="gd-ui">Text</b>: a small window opens with the person and the number. Write the text (sign it CarmaCars) and press <b class="gd-ui">Send</b>. It goes out from the CarmaCars number at once and is kept in the person&#39;s conversation under <b class="gd-ui">Visitors</b> &gt; <b class="gd-ui">Chat</b> &gt; <b class="gd-ui">Texts and calls</b> (customer service and Sales); press <b class="gd-ui">Open the conversation</b> to see it there. A number that asked for no texts is refused with the reason.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Press <b class="gd-ui">Call</b>: on a phone the Quo app opens with the number in its dialer; press call there. On a computer the Quo web app opens in a new tab and the number is copied: open the dialer (Alt+C, or Ctrl+C on a Mac) and paste it. If Quo&#39;s desktop app is your computer&#39;s calling app, tick <b class="gd-ui">On this computer, call with the Quo desktop app</b> once: Call then opens it straight away. Every call is noted on the conversation as Call started from the site, and Quo adds the call itself when it ends.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Fleet, finance and field staff can call and text the people of their work (renters, owners, leads and staff); customer service and Sales any number.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t">An Admin can switch the buttons back to the phone&#39;s own apps in Program settings. With Phone and texts off, the buttons use the phone&#39;s own apps too.</div></li></ol></div></section><section class="gd-task" id="texts-and-calls-who-is-calling-the-caller-pop-up-release-34" data-gd-task><h2 class="gd-h2">Who is calling: the caller pop-up (release 34)</h2><p class="gd-p">Customer service: when someone calls the CarmaCars number, a panel opens at the bottom right of every page of your portal (across the bottom on a phone) while the phone rings, and stays while the call goes on and for 3 minutes after it ends.</p><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">A renter: their name, the booking on rent (or the next one coming) with the car, the balance they owe now (<b class="gd-ui">overdue</b> when a payment is late), the deposit (held, waived, released, or not taken yet), what they are waiting on (a request, an offer, a change, a question to them, an open To do) and the last three notes.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Write what the call was about in <b class="gd-ui">Note about this call</b> and press <b class="gd-ui">Add note</b>. It is kept on the renter with the time, your name and the booking.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t"><b class="gd-ui">Open the renter&#39;s page</b> opens their record. If it is outside your window, opening it from their call is logged as an opening for 24 hours with the reason Incoming call, as <b class="gd-ui">Open with a reason</b> is.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t">An unknown number shows <b class="gd-ui">Unknown caller</b>: press <b class="gd-ui">Create lead</b> to keep it as a phone lead.</div></li><li><span class="gd-n" aria-hidden="true">5</span><div class="gd-t">Press the cross to close a call; it stays closed in this browser.</div></li></ol></div></section><section class="gd-task" id="texts-and-calls-renter-notes-release-34" data-gd-task><h2 class="gd-h2">Renter notes (release 34)</h2><p class="gd-p">A renter&#39;s record (<b class="gd-ui">Find a renter</b>, then Open) has <b class="gd-ui">Add a note</b>, and the notes are in its Activity log (chip <b class="gd-ui">Notes</b>), newest first, each with the date and time, who wrote it and their role. Add a note for every situation: what they asked, what you told them, what happens next. Notes cannot be changed or removed by staff, so write a new note to correct one; an Admin can remove a note with a reason. The notes also show on the caller pop-up and on a renter&#39;s conversation in Texts and calls.</p></section><section class="gd-task" id="texts-and-calls-lanes-the-call-button-and-hidden-numbers-release-35" data-gd-task><h2 class="gd-h2">Lanes, the Call button and hidden numbers (release 35)</h2><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">Each conversation has a lane: <b class="gd-ui">Fleet</b> for a car on rent, or a pickup, return, delivery or collection within a day; <b class="gd-ui">Customer service</b> for the rest. The inbox has a tab for each. The caller pop-up rings for Fleet first on Fleet&#39;s calls; customer service gets them when no Fleet staff member is on duty or nobody answered within 20 seconds.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t"><b class="gd-ui">Call</b> rings your own phone first (the cell number in your profile). Answer it and we connect the customer, who sees the CarmaCars number. The call is noted on their history with its length. Until calling from the site is set up, <b class="gd-ui">Call</b> opens Quo as before and says why.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Sales sees customer numbers hidden, like (647) •••-••00. Use <b class="gd-ui">Call</b> and <b class="gd-ui">Text</b> on the page: the number is found on our side. Search by phone still works.</div></li></ol></div></section><section class="gd-task" id="texts-and-calls-calls-first-texts-after-release-37" data-gd-task><h2 class="gd-h2">Calls first, texts after (release 37)</h2><p class="gd-p">Your main priority is always to be on the phone with people.</p><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">Answer a ringing call before anything else, and return a missed call at once.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t"><b class="gd-ui">Call before you text.</b> On a lead, a renter or a booking, <b class="gd-ui">Call</b> is the first button and <b class="gd-ui">Text</b> the second.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">A text is a follow-up: after a call attempt (no answer, a voicemail left), or when the person asked for a text.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t">On your To do and on <b class="gd-ui">Unanswered</b>, missed calls and call-backs are listed above unanswered texts.</div></li></ol></div></section><section class="gd-task" id="texts-and-calls-a-lead-you-handle-on-a-call-release-37" data-gd-task><h2 class="gd-h2">A lead you handle on a call (release 37)</h2><p class="gd-p">When you answer or place a call with a lead, add a note on it, or create it from a call, the lead is yours for a limited time (15 minutes, as a Sales claim; an Admin can change it in <b class="gd-ui">Settings</b> &gt; <b class="gd-ui">Sales</b>). Every call you handle adds the time again.</p><ul class="gd-ul"><li>Sales see <b class="gd-ui">Being handled by</b> your first name and your function with the time, on the lead and in every list. They cannot claim it, call, text or email it, or set an outcome meanwhile, and <b class="gd-ui">Next lead</b> skips it.</li><li>Another customer service or Fleet person can still work it; their call or note takes the hold over.</li><li>When it ends, the lead goes back to the salesperson who had a claim on it or who brought it, else to the open list. An Admin can <b class="gd-ui">Release hold</b> earlier.</li><li>A booking made from the lead is credited as always: customer service and Fleet get no sales commission for it.</li><li>Nobody who has not finished onboarding holds a lead.</li></ul></section>');
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
