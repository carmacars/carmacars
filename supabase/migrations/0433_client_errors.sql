-- 0433: crashes in visitors' browsers were invisible (no error page of our own, nothing logged). Every crash a page
-- reports is kept here for 30 days, and the first of each kind in a day opens one Admin task "Website crash" with the
-- page, the message and the browser, so a broken step is found the same day. SCHEMA_MARKER 0433.
-- docs/changes/2026-11-02-more-listing-photos.md (section "Crashes in the browser").
create table client_errors (
  id         bigint generated always as identity primary key,
  created_at timestamptz not null default now(),
  path       text not null check (char_length(path) <= 300),
  message    text not null check (char_length(message) <= 500),
  stack      text check (char_length(stack) <= 4000),
  ua         text check (char_length(ua) <= 300),
  digest     text check (char_length(digest) <= 100)
);
create index client_errors_created on client_errors (created_at desc);
alter table client_errors enable row level security;
comment on table client_errors is 'Crashes reported by visitors'' browsers (0433): service role only, kept 30 days.';

create or replace function public.server_client_error(p jsonb) returns text
language plpgsql security definer set search_path = public, app as $$
declare
  v_msg  text := left(coalesce(nullif(btrim(p ->> 'message'), ''), 'Unknown error'), 500);
  v_path text := left(coalesce(nullif(btrim(p ->> 'path'), ''), '/'), 300);
  v_key  text;
begin
  -- a flood (a loop in one browser, a bot) is cut at 300 an hour
  if (select count(*) from client_errors where created_at > now() - interval '1 hour') >= 300 then return 'limited'; end if;
  delete from client_errors where created_at < now() - interval '30 days';
  insert into client_errors (path, message, stack, ua, digest)
  values (v_path, v_msg, left(p ->> 'stack', 4000), left(p ->> 'ua', 300), left(p ->> 'digest', 100));
  v_key := 'client_error:' || md5(v_msg || '|' || regexp_replace(v_path, '/[A-Za-z0-9_-]{8,}', '/x', 'g')) || ':' || to_char(app.local_date(now()), 'YYYY-MM-DD');
  perform app.raise_task(p_type => 'site_alert', p_title => left('Website crash on ' || v_path || ': ' || v_msg, 200),
    p_detail => left('A visitor''s browser crashed. Page: ' || v_path || '. Error: ' || v_msg || '. Browser: ' || coalesce(p ->> 'ua', 'unknown')
                     || '. Every report is kept for 30 days in client_errors.', 2000),
    p_dedupe => v_key);
  return 'ok';
end $$;
revoke all on function public.server_client_error(jsonb) from public, anon, authenticated;
grant execute on function public.server_client_error(jsonb) to service_role;
