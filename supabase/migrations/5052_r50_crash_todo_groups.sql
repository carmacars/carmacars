-- 5052: one website crash To do per error, not per page (release 50; docs/changes/2026-11-25-r50-admin-email-quiet.md). SCHEMA_MARKER 5052.
-- The owner (Nov 25): the Admin's To do's and alerts are cluttered. Production had about 151 open "site_alert" To do's,
-- almost all "Website crash on /cars/... (or /buy/...): Minified React error #441" or "#418": the same error, one To do
-- per page and day (2895's key: message, page, day). No applied migration is edited.
--   1. app.client_error_signature(message): the message with addresses, page paths and numbers taken out, so the same
--      error on every page is one signature. A "#NNN" error code is kept: React's #441 and #418 are different errors.
--   2. crash_groups: one row per open crash To do (its signature, reports, the first 10 pages, first and last seen).
--      public.server_client_error (2895) is replaced: a crash adds to the open To do of its signature (the count, the
--      page list and the last-seen time are written again in its title and detail) instead of opening a new one.
--      A crash To do stays at priority high (2895 raised it to urgent at 3 people): it never emails the Admins (5051).
--   3. app.crash_todos_sweep: an open crash To do (not one someone is working on) whose error has not come back for 24
--      hours closes by itself with the note "No new reports for 24 hours" (pg_cron, every hour, as 2897's digests). A
--      later report opens a new one.
--   4. Once: the open crash To do's are folded into one per signature: the newest is kept with the others' counts and
--      pages added, the rest close with the note "Merged into <title>". No priority changes, so the deploy sends no email.
set local check_function_bodies = off;

-- ================================================================ 1. the signature
create function app.client_error_signature(p_message text) returns text
language sql immutable set search_path = public, app, pg_temp as $$
  select left(btrim(regexp_replace(regexp_replace(regexp_replace(regexp_replace(coalesce(p_message, ''),
           'https?://\S+', '<url>', 'g'),
           '(^|[\s(''"`])/[^\s)''"`]*', '\1<path>', 'g'),
           '(?<![#\d])\d+', 'N', 'g'),
           '\s+', ' ', 'g')), 300)
$$;
comment on function app.client_error_signature(text) is 'r50 (5052): a browser error''s message with addresses, page paths and numbers taken out (an error code like #441 kept): one website crash To do per signature.';

-- ================================================================ 2. the groups
create table if not exists crash_groups (
  task_id    uuid primary key references tasks (id) on delete cascade,
  signature  text not null,
  message    text not null,
  reports    integer not null default 0 check (reports >= 0),
  pages      text[] not null default '{}',
  first_at   timestamptz not null default now(),
  last_at    timestamptz not null default now()
);
create index if not exists crash_groups_signature on crash_groups (signature);
create index if not exists crash_groups_last on crash_groups (last_at);
comment on table crash_groups is 'Website crash To do''s grouped by error (5052): one row per To do with its signature, how many reports, the first 10 pages and when it was first and last seen. Closed by app.crash_todos_sweep after 24 hours with no new report.';
alter table crash_groups enable row level security;
revoke all on crash_groups from public, anon, authenticated;
grant all on crash_groups to service_role;
drop policy if exists admin_all on crash_groups;
create policy admin_all on crash_groups for all to authenticated using (app.is_admin()) with check (app.is_admin());

-- the To do's words from its group
create function app.crash_todo_write(p_task uuid) returns void
language plpgsql security definer set search_path = public, app, pg_temp as $$
declare
  g crash_groups;
  v_people integer;
  v_browsers text;
begin
  select * into g from crash_groups where task_id = p_task;
  if g.task_id is null then return; end if;
  select count(distinct coalesce(e.user_id::text, e.visitor, md5(coalesce(e.ua, '')))), string_agg(distinct app.ua_browser(e.ua), ', ')
    into v_people, v_browsers
    from client_errors e
   where e.kind = 'crash' and e.created_at >= g.first_at and app.client_error_signature(e.message) = g.signature;
  update tasks set
    title = left('Website crash' || case when g.reports > 1 then format(' (%s times on %s %s)', g.reports, cardinality(g.pages), case when cardinality(g.pages) = 1 then 'page' else 'pages' end) else '' end
                 || ': ' || g.message, 200),
    detail = left(format('A page of the site failed in the browser. Error: %s. Reports: %s since %s, last at %s; %s %s. Pages (first 10): %s. Browsers: %s.',
                    g.message, g.reports, to_char(g.first_at at time zone 'America/Toronto', 'Mon FMDD HH12:MI AM'), to_char(g.last_at at time zone 'America/Toronto', 'Mon FMDD HH12:MI AM'),
                    coalesce(v_people, 0), case when v_people = 1 then 'person' else 'people' end, array_to_string(g.pages, ', '), coalesce(v_browsers, 'unknown'))
                  || ' One To do for this error on every page. It closes by itself after 24 hours with no new report. Every report is kept 30 days in client_errors (with its stack).', 2000)
   where id = p_task;
end $$;

create or replace function public.server_client_error(p jsonb) returns text
language plpgsql security definer set search_path = public, app, pg_temp as $$
declare
  v_msg   text := left(coalesce(nullif(btrim(p ->> 'message'), ''), 'Unknown error'), 500);
  v_path  text := left(coalesce(nullif(btrim(p ->> 'path'), ''), '/'), 300);
  v_stack text := left(p ->> 'stack', 4000);
  v_ua    text := left(p ->> 'ua', 300);
  v_user  uuid := case when coalesce(p ->> 'user_id', '') ~ '^[0-9a-f-]{36}$' then (p ->> 'user_id')::uuid end;
  v_vid   text := case when coalesce(p ->> 'visitor', '') ~ '^[0-9A-Za-z-]{8,64}$' then p ->> 'visitor' end;
  v_kind  text := app.client_error_kind(v_msg, v_stack);
  v_sig   text := app.client_error_signature(v_msg);
  v_key   text;
  v_task  uuid;
begin
  -- a flood (a loop in one browser, a bot) is cut at 300 an hour
  if (select count(*) from client_errors where created_at > now() - interval '1 hour') >= 300 then return 'limited'; end if;
  delete from client_errors where created_at < now() - interval '30 days';
  if v_user is not null and not exists (select 1 from users where id = v_user) then v_user := null; end if;
  insert into client_errors (path, message, stack, ua, digest, user_id, kind, visitor)
  values (v_path, v_msg, v_stack, v_ua, left(p ->> 'digest', 100), v_user, v_kind, v_vid);
  if v_kind <> 'crash' then return 'noise'; end if;

  -- 5052: the open To do of this error (any page), else a new one
  v_key := 'client_error_sig:' || md5(v_sig);
  select t.id into v_task from tasks t where t.dedupe_key = v_key and t.status in ('open', 'in_progress', 'waiting') order by t.created_at desc limit 1;
  if v_task is null then
    v_task := app.raise_task(p_type => 'site_alert', p_title => left('Website crash: ' || v_msg, 200), p_priority => 'high', p_dedupe => v_key);
    if v_task is null then return 'ok'; end if;
    insert into crash_groups (task_id, signature, message) values (v_task, v_sig, v_msg) on conflict (task_id) do nothing;
  end if;
  update crash_groups set reports = reports + 1, last_at = now(), message = v_msg,
         pages = case when v_path = any (pages) or cardinality(pages) >= 10 then pages else pages || v_path end
   where task_id = v_task;
  perform app.crash_todo_write(v_task);

  insert into staff_digest_items (role, code, digest_slot, line, meta, url, dedupe_key)
  values ('admin', 'staff_site_alert', 'morning', left('Website crash: ' || left(v_msg, 200), 300), 'Kept 30 days in client_errors',
          rtrim((app.settings()).notify_base_url, '/') || '/admin/tasks',
          'client_error_digest:' || md5(v_sig) || ':' || to_char(app.local_date(now()), 'YYYY-MM-DD'))
  on conflict (dedupe_key) do nothing;
  return 'ok';
end $$;
revoke all on function public.server_client_error(jsonb) from public, anon, authenticated;
grant execute on function public.server_client_error(jsonb) to service_role;

-- ================================================================ 3. closed after 24 quiet hours
create function app.crash_todos_sweep(p_now timestamptz default now()) returns integer
language plpgsql security definer set search_path = public, app, pg_temp as $$
declare v_n integer;
begin
  update tasks t set status = 'done', completed_at = p_now, completion_note = 'No new reports for 24 hours'
    from crash_groups g
   where g.task_id = t.id and t.status = 'open' and g.last_at < p_now - interval '24 hours';
  get diagnostics v_n = row_count;
  return v_n;
end $$;
do $$
begin
  if to_regclass('cron.job') is not null then
    perform cron.schedule('carmacars-crash-todos', '41 * * * *', $q$select app.crash_todos_sweep()$q$);
  end if;
end $$;

-- ================================================================ 4. once: the open crash To do's, one per error
-- 2895's words: detail "Page: <path>. Error: <message>. Today: <n> time(s), ...", title "Website crash on <path> (<n> times, ...): <message>"
create function app.crash_todos_fold() returns integer
language plpgsql security definer set search_path = public, app, pg_temp as $$
declare v_n integer;
begin
  create temp table c5052 on commit drop as
  select x.*, app.client_error_signature(x.message) as sig from (
    select t.id, t.created_at, t.updated_at,
           coalesce(substring(t.detail from 'Page: (.*?)\. Error: '), substring(t.title from '^Website crash on (\S+)')) as page,
           coalesce(substring(t.detail from 'Error: (.*?)\. Today: '), substring(t.title from '^Website crash on \S+(?: \(\d+ times[^)]*\))?: (.*)$')) as message,
           coalesce(substring(t.detail from 'Today: (\d+) time')::integer, substring(t.title from '^Website crash on \S+ \((\d+) times')::integer, 1) as reports
      from tasks t
     where t.task_type = 'site_alert' and t.status in ('open', 'in_progress', 'waiting') and t.title like 'Website crash on %') x
   where x.message is not null;
  create temp table k5052 on commit drop as
  select distinct on (sig) sig, id as keep_id from c5052 order by sig, created_at desc, id;
  insert into crash_groups (task_id, signature, message, reports, pages, first_at, last_at)
  select k.keep_id, k.sig, (select c.message from c5052 c where c.id = k.keep_id), sum(c.reports)::integer,
         coalesce((array_agg(distinct c.page) filter (where c.page is not null))[1:10], '{}'), min(c.created_at), max(greatest(c.updated_at, c.created_at))
    from k5052 k join c5052 c on c.sig = k.sig
   group by k.keep_id, k.sig
  on conflict (task_id) do nothing;
  -- (a grouped To do already open for the signature keeps the key; the kept one then stays as it was keyed)
  update tasks t set dedupe_key = 'client_error_sig:' || md5(k.sig)
    from k5052 k
   where t.id = k.keep_id and t.status in ('open', 'in_progress', 'waiting')
     and not exists (select 1 from tasks x where x.dedupe_key = 'client_error_sig:' || md5(k.sig) and x.status in ('open', 'in_progress', 'waiting'));
  perform app.crash_todo_write(k.keep_id) from k5052 k;
  update tasks t set status = 'done', completed_at = now(), completion_note = left('Merged into ' || kt.title, 1000)
    from c5052 c join k5052 k on k.sig = c.sig join tasks kt on kt.id = k.keep_id
   where t.id = c.id and c.id <> k.keep_id and t.status in ('open', 'in_progress', 'waiting');
  get diagnostics v_n = row_count;
  drop table c5052; drop table k5052;
  return v_n;
end $$;
select app.crash_todos_fold();

-- ================================================================ privileges
revoke all on function app.client_error_signature(text), app.crash_todo_write(uuid), app.crash_todos_sweep(timestamptz), app.crash_todos_fold() from public, anon, authenticated;
grant execute on function app.client_error_signature(text), app.crash_todo_write(uuid), app.crash_todos_sweep(timestamptz), app.crash_todos_fold() to service_role;
