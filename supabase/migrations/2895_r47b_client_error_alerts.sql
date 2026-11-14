-- 2895 (release 47, part B): website crash alerts that mean something. 0433 opened an urgent Admin To do "Website crash
-- on ..." for the first report of each page and message a day, whatever it was, and the Admin's To do filled with things
-- that are not crashes. Every report is still kept 30 days in client_errors, now with its kind:
--   network      the connection dropped ("Failed to fetch", "network error", "Load failed", "NetworkError")
--   transition   a page change animation the browser cut short ("Transition was aborted", skipTransition())
--   stale_build  a tab of the previous deploy (a server action or script the new build does not have): the page reloads
--                itself (r46, lib/client-error/recover.ts)
--   translation  the browser's own translation (or an extension) moved React's text: NotFoundError, "removeChild",
--                "insertBefore", WebKit's "The object can not be found here." (r47's lib/client-error/dom-guard.ts stops it)
--   foreign      not our code: "Script error." (another origin), extensions, MetaMask, and a "Maximum call stack size
--                exceeded" whose stack has no frame of ours (Chrome on iPhone's injected scripts)
--   crash        everything else: a real error of the site
-- Only a crash opens a To do: one per page and message a day (the To do's key), written again on every report with how
-- many times and how many people (signed-in account, else the browser's visitor id) hit it today and which browsers.
-- One person: priority high; three or more people the same day: urgent. A To do closed today is written again, never
-- reopened. The Admins' morning digest line (0532) stays once per kind a day.
-- Once: open "Website crash" To do's whose report is now noise, or whose cause r47 fixed, are closed with a note.
-- docs/changes/2026-11-14-r47b-crash-alerts-photo-standard.md. SCHEMA_MARKER 2895.

-- ================================================================ 1. the kind of a report
alter table client_errors add column if not exists kind text not null default 'crash'
  check (kind in ('crash', 'network', 'transition', 'stale_build', 'translation', 'foreign'));
alter table client_errors add column if not exists visitor text check (char_length(visitor) <= 64);
comment on column client_errors.kind is 'What the report is (2895): crash (a real error: an Admin To do), or noise kept for the record only (network, transition, stale_build, translation, foreign).';
comment on column client_errors.visitor is 'The browser''s visitor id (cookie cc_vid) when nobody was signed in (2895): counts people, not reports.';
create index if not exists client_errors_kind_created on client_errors (kind, created_at desc);

create or replace function app.client_error_kind(p_message text, p_stack text default null) returns text
language sql immutable set search_path = public, app as $$
  select case
    when m ~* '(failed to fetch|network ?error|(^|: )load failed|networkerror|network connection was lost|internet connection appears to be offline|connection closed)' then 'network'
    when m ~* '(transition was aborted|skiptransition\(\)|skipping view transition)' then 'transition'
    when m ~* '(failed to find server action|server action .* was not found|unrecognizedactionerror|older or newer deployment|chunkloaderror|loading (css )?chunk|failed to load chunk|dynamically imported module|importing a module script failed)' then 'stale_build'
    when m ~* '(removechild|insertbefore|the object can not be found here|notfounderror|is not a child of this node)' then 'translation'
    when m ~* '(^script error\.?$|chrome-extension:|moz-extension:|safari-web-extension:|metamask)' then 'foreign'
    when m ~* 'maximum call stack size exceeded' and coalesce(p_stack, '') !~ '/_next/' then 'foreign'
    else 'crash' end
  from (select coalesce(btrim(p_message), '') m) x
$$;
comment on function app.client_error_kind(text, text) is 'r47 (2895): the kind of a browser error report: crash, or one of the noise kinds that never open a To do.';

-- "Chrome 157 on Android", "Safari 26 on iPhone", "Samsung Internet 30 on Android"
create or replace function app.ua_browser(p_ua text) returns text
language sql immutable set search_path = public, app as $$
  select case when coalesce(u, '') = '' then 'unknown browser' else
    coalesce(
      (select 'Samsung Internet ' || (regexp_match(u, 'SamsungBrowser/(\d+)'))[1] where u ~ 'SamsungBrowser/'),
      (select 'Edge ' || (regexp_match(u, 'Edg[A-Za-z]*/(\d+)'))[1] where u ~ 'Edg[A-Za-z]*/'),
      (select 'Chrome ' || (regexp_match(u, 'CriOS/(\d+)'))[1] where u ~ 'CriOS/'),
      (select 'Firefox ' || (regexp_match(u, '(?:Firefox|FxiOS)/(\d+)'))[1] where u ~ '(Firefox|FxiOS)/'),
      (select 'Chrome ' || (regexp_match(u, 'Chrome/(\d+)'))[1] where u ~ 'Chrome/'),
      (select 'Safari ' || (regexp_match(u, 'Version/(\d+)'))[1] where u ~ 'Version/\d+.*Safari'),
      'other browser')
    || coalesce(' on ' || case when u ~ 'iPhone' then 'iPhone' when u ~ 'iPad' then 'iPad' when u ~ 'Android' then 'Android'
                               when u ~ 'Windows' then 'Windows' when u ~ 'Mac OS X' then 'Mac' when u ~ 'CrOS' then 'ChromeOS' when u ~ 'Linux' then 'Linux' end, '')
  end
  from (select btrim(p_ua) u) x
$$;
comment on function app.ua_browser(text) is 'r47 (2895): a browser''s user agent in a few words for the crash To do.';

-- ================================================================ 2. the report
-- One function in place of the 0433 / 2340 / 0532 chain (their bodies stay, unused): keep the report with its kind and
-- person; a crash writes its To do and the digest line.
create or replace function public.server_client_error(p jsonb) returns text
language plpgsql security definer set search_path = public, app as $$
declare
  v_msg   text := left(coalesce(nullif(btrim(p ->> 'message'), ''), 'Unknown error'), 500);
  v_path  text := left(coalesce(nullif(btrim(p ->> 'path'), ''), '/'), 300);
  v_stack text := left(p ->> 'stack', 4000);
  v_ua    text := left(p ->> 'ua', 300);
  v_user  uuid := case when coalesce(p ->> 'user_id', '') ~ '^[0-9a-f-]{36}$' then (p ->> 'user_id')::uuid end;
  v_vid   text := case when coalesce(p ->> 'visitor', '') ~ '^[0-9A-Za-z-]{8,64}$' then p ->> 'visitor' end;
  v_kind  text := app.client_error_kind(v_msg, v_stack);
  v_page  text := regexp_replace(v_path, '/[A-Za-z0-9_-]{8,}', '/x', 'g');
  v_day   date := app.local_date(now());
  v_key   text;
  v_task  uuid;
  v_open  boolean;
  v_n     integer;
  v_people integer;
  v_browsers text;
  v_first timestamptz;
  v_title text;
  v_detail text;
  v_prio  text;
begin
  -- a flood (a loop in one browser, a bot) is cut at 300 an hour
  if (select count(*) from client_errors where created_at > now() - interval '1 hour') >= 300 then return 'limited'; end if;
  delete from client_errors where created_at < now() - interval '30 days';
  if v_user is not null and not exists (select 1 from users where id = v_user) then v_user := null; end if;
  insert into client_errors (path, message, stack, ua, digest, user_id, kind, visitor)
  values (v_path, v_msg, v_stack, v_ua, left(p ->> 'digest', 100), v_user, v_kind, v_vid);
  if v_kind <> 'crash' then return 'noise'; end if;

  -- today's reports of this page and message: how many, how many people, which browsers
  select count(*), count(distinct coalesce(e.user_id::text, e.visitor, md5(coalesce(e.ua, '')))), min(e.created_at),
         string_agg(distinct app.ua_browser(e.ua), ', ')
    into v_n, v_people, v_first, v_browsers
    from client_errors e
   where e.kind = 'crash' and e.created_at > now() - interval '26 hours' and app.local_date(e.created_at) = v_day
     and e.message = v_msg and regexp_replace(e.path, '/[A-Za-z0-9_-]{8,}', '/x', 'g') = v_page;
  v_prio := case when v_people >= 3 then 'urgent' else 'high' end;
  v_title := left('Website crash on ' || v_path || case when v_n > 1 then format(' (%s times, %s %s)', v_n, v_people, case when v_people = 1 then 'person' else 'people' end) else '' end
                  || ': ' || v_msg, 200);
  v_detail := left(format('A page of the site failed in the browser. Page: %s. Error: %s. Today: %s %s, %s %s (first at %s). Browsers: %s.',
                    v_path, v_msg, v_n, case when v_n = 1 then 'time' else 'times' end, v_people, case when v_people = 1 then 'person' else 'people' end,
                    to_char(v_first at time zone 'America/Toronto', 'HH12:MI AM'), coalesce(v_browsers, 'unknown'))
                  || ' Every report is kept 30 days in client_errors (with its stack). Network drops, stale tabs after a deploy and browser translation are kept there but never open a To do.', 2000);

  v_key := 'client_error:' || md5(v_msg || '|' || v_page) || ':' || to_char(v_day, 'YYYY-MM-DD');
  select id, status in ('open', 'in_progress', 'waiting') into v_task, v_open from tasks where dedupe_key = v_key order by created_at desc limit 1;
  if v_task is null then
    perform app.raise_task(p_type => 'site_alert', p_title => v_title, p_detail => v_detail, p_priority => v_prio, p_dedupe => v_key);
  else
    -- the same To do, written again (a closed one stays closed: it was looked at today)
    update tasks set title = v_title, detail = v_detail,
                     priority = case when v_open and v_prio = 'urgent' then 'urgent' else priority end
     where id = v_task;
  end if;

  insert into staff_digest_items (role, code, digest_slot, line, meta, url, dedupe_key)
  values ('admin', 'staff_site_alert', 'morning', left('Website crash on ' || left(v_path, 120) || ': ' || left(v_msg, 200), 300), 'Kept 30 days in client_errors',
          rtrim((app.settings()).notify_base_url, '/') || '/admin/todo',
          'client_error_digest:' || md5(v_msg || '|' || v_page) || ':' || to_char(v_day, 'YYYY-MM-DD'))
  on conflict (dedupe_key) do nothing;
  return 'ok';
end $$;
revoke all on function public.server_client_error(jsonb) from public, anon, authenticated;
grant execute on function public.server_client_error(jsonb) to service_role;
revoke all on function app.client_error_kind(text, text), app.ua_browser(text) from public, anon, authenticated;
grant execute on function app.client_error_kind(text, text), app.ua_browser(text) to service_role;

-- ================================================================ 3. once: the reports kept, and the open To do's
update client_errors set kind = app.client_error_kind(message, stack) where kind = 'crash';

do $$
declare
  t record;
  v_kind text;
  v_note text;
  n_noise integer := 0;
  n_fixed integer := 0;
begin
  for t in
    select x.id, x.p, x.m from (
      select id, substring(title from '^Website crash on (\S+)(?: \(\d+ times[^)]*\))?: ') p,
             substring(title from '^Website crash on \S+(?: \(\d+ times[^)]*\))?: (.*)$') m
        from tasks where task_type = 'site_alert' and status in ('open', 'in_progress', 'waiting') and title like 'Website crash on %') x
     where x.m is not null
  loop
    v_kind := app.client_error_kind(t.m, (select e.stack from client_errors e where e.path = t.p and left(e.message, length(t.m)) = t.m order by e.created_at desc limit 1));
    v_note := case
      when v_kind = 'network' then 'Closed by release 47 (2895): a dropped connection, not a crash. Still kept in client_errors; it no longer opens a To do.'
      when v_kind = 'transition' then 'Closed by release 47 (2895): a page change animation the browser cut short, not a crash. Still kept in client_errors; it no longer opens a To do.'
      when v_kind = 'stale_build' then 'Closed by release 47 (2895): a tab of the previous deploy; since release 46 the page reloads itself. Still kept in client_errors; it no longer opens a To do.'
      when v_kind = 'translation' then 'Closed by release 47 (2895): the browser''s translation moved the page''s text (NotFoundError). Release 47 makes the page survive it; still kept in client_errors, it no longer opens a To do.'
      when v_kind = 'foreign' then 'Closed by release 47 (2895): an error of a script that is not ours (another origin, an extension, or a stack with no frame of the site). Still kept in client_errors; it no longer opens a To do.'
      when t.m ~ '#441' and t.p ~ '^/([a-z]{2}/)?car-rental/' then 'Closed by release 47 (2895): fixed. The place and landing pages'' metadata (streamed after the page) failed on a busy read; it now falls back to plain metadata, and so does the site''s own (every page''s).'
      when t.m ~ '#441' and t.p ~ '^/careers/[^/]+/apply$' then 'Closed by release 47 (2895): fixed. The site''s own metadata (every page''s, streamed after the page) failed on a busy settings read; it now falls back to plain metadata. The apply page''s reads already had fallbacks.'
      when t.m ~ '#441' and t.p ~ '^/(staff|admin)/visitors$' then 'Closed by release 47 (2895): fixed. Visitors'' Live now, History and Chat reads had no fallback (the page now says which part did not load), and the site''s metadata falls back too.'
      when t.m ~ '#441' and t.p ~ '^/staff/game-leads$' then 'Closed by release 47 (2895): fixed in release 46 (the game leads read''s fallback); the site''s metadata falls back too since release 47.'
    end;
    continue when v_note is null;
    update tasks set status = 'done', completed_at = now(), completion_note = v_note where id = t.id;
    if v_kind = 'crash' then n_fixed := n_fixed + 1; else n_noise := n_noise + 1; end if;
  end loop;
  raise notice '2895: % website crash To do''s closed as noise, % as fixed', n_noise, n_fixed;
end $$;
