-- 2980 (release 48): texts and emails within a second or two of being queued, and live staff pages
-- (docs/changes/2026-11-14-r48-instant-send.md).
--
-- The owner (Nov 14): "Emails and texts still aren't anywhere near instant ... Did u implement realtime?" A write through
-- the site already asked the database at once (0670, server_notify_kick), but what the database queued by itself (a
-- timer, a reminder coming due, a webhook handled in SQL) waited for the minute tick, and an email that was not urgent
-- waited for the sender's next minute.
--   1. A NOTIFY on the channel carmacars_send (payload `table:id`, nothing else) after a row is queued: phone_outbox,
--      notification_outbox, push_outbox (inserted queued, or put back to queued), notifications and app_events (new,
--      not processed). The site on the company's server LISTENs (web/src/lib/platform/db-listen.ts) and runs the same
--      kick as a write. The login it uses, carmacars_listen, may connect and listen and nothing else: no table, no
--      function of the site is granted to it; its password is set on the server by the deploy (never in this file).
--   2. Every email at once: the kick asks the email sender whenever any email is due (not only an urgent one), at most
--      every 5 seconds (was 20, urgent only). The day's budgets and the class order of the claim still hold.
--   3. The time from queued to sent, per message: due_at (when it was first due: created, or its later send time) and
--      send_ms (sent_at minus due_at) on the three queues, set by a trigger. server_send_latency: the last 24 hours'
--      count, average and 95th percentile per channel, for Admin > Logs.
--   4. Live pages: the To do lists (tasks) and the phone conversations bump the live topics (2522); a new staff area,
--      staff:tasks, for Admin and every staff member (the bump carries nothing: the page reads again through its own
--      checked reads).
-- No applied migration is edited: server_notify_kick and server_live_topics are wrapped (_pre2980).
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

-- ================================================================ 1. the listen login and the notify
do $$
begin
  if not exists (select 1 from pg_roles where rolname = 'carmacars_listen') then
    -- no password here: none until the server's deploy sets one (scripts/deploy/web-vps-remote.sh listen_env)
    create role carmacars_listen login noinherit nocreatedb nocreaterole connection limit 4;
  end if;
end $$;
comment on role carmacars_listen is 'r48 (2980): the site''s LISTEN on carmacars_send (web/src/lib/platform/db-listen.ts). Connects and listens; no table or function of the site is granted to it.';

create function app.send_notify() returns trigger
language plpgsql security definer set search_path = public, app as $$
declare
  r jsonb := to_jsonb(new);
begin
  begin
    if tg_table_name = 'app_events' then
      if new.processed_at is not null then return null; end if;
    elsif r ? 'status' then
      if r ->> 'status' <> 'queued' then return null; end if;
      if tg_op = 'UPDATE' and (to_jsonb(old) ->> 'status') = 'queued' then return null; end if;
    end if;
    perform pg_notify('carmacars_send', tg_table_name || ':' || (r ->> 'id'));
  exception when others then
    null; -- a notify is never worth a failed write: the minute tick sends it anyway
  end;
  return null;
end $$;
comment on function app.send_notify() is 'r48 (2980): NOTIFY carmacars_send with table:id when a text, email or push is queued, a notice written or an event raised; the site''s listen sends it at once.';

do $$
declare t text;
begin
  foreach t in array array['phone_outbox', 'notification_outbox', 'push_outbox'] loop
    execute format('create trigger send_notify_ins after insert on %I for each row execute function app.send_notify()', t);
    execute format('create trigger send_notify_upd after update of status on %I for each row when (new.status = ''queued'' and old.status is distinct from new.status) execute function app.send_notify()', t);
  end loop;
  create trigger send_notify_ins after insert on notifications for each row execute function app.send_notify();
  create trigger send_notify_ins after insert on app_events for each row execute function app.send_notify();
end $$;

-- ================================================================ 3. queued to sent
do $$
declare t text;
begin
  foreach t in array array['phone_outbox', 'notification_outbox', 'push_outbox'] loop
    execute format('alter table %I add column if not exists due_at timestamptz', t);
    execute format('alter table %I add column if not exists send_ms integer', t);
    execute format('comment on column %I.due_at is %L', t, 'r48 (2980): when the message was first due (queued, or its later send time when it was written for later). The latency is measured from here.');
    execute format('comment on column %I.send_ms is %L', t, 'r48 (2980): milliseconds from due_at to sent_at (Admin > Logs).');
  end loop;
end $$;

create function app.send_latency() returns trigger
language plpgsql security definer set search_path = public, app as $$
begin
  if tg_op = 'INSERT' then
    new.due_at := greatest(coalesce(new.created_at, now()), coalesce(new.send_after, now()));
  elsif new.status = 'sent' and new.sent_at is not null and new.send_ms is null and new.due_at is not null then
    new.send_ms := least(2147483647, greatest(0, round(extract(epoch from (new.sent_at - new.due_at)) * 1000)))::integer;
  end if;
  return new;
end $$;
do $$
declare t text;
begin
  foreach t in array array['phone_outbox', 'notification_outbox', 'push_outbox'] loop
    execute format('create trigger send_latency before insert or update of status, sent_at on %I for each row execute function app.send_latency()', t);
  end loop;
end $$;
create index if not exists phone_outbox_sent_recent on phone_outbox (sent_at) where send_ms is not null;
create index if not exists notification_outbox_sent_recent on notification_outbox (sent_at) where send_ms is not null;
create index if not exists push_outbox_sent_recent on push_outbox (sent_at) where send_ms is not null;

create function app.send_latency_stats(p_hours integer default 24) returns jsonb
language sql stable security definer set search_path = public, app as $$
  with s as (
    select 'text' as ch, send_ms from phone_outbox where send_ms is not null and sent_at > now() - make_interval(hours => greatest(1, least(p_hours, 720)))
    union all
    select 'email', send_ms from notification_outbox where send_ms is not null and sent_at > now() - make_interval(hours => greatest(1, least(p_hours, 720)))
    union all
    select 'push', send_ms from push_outbox where send_ms is not null and sent_at > now() - make_interval(hours => greatest(1, least(p_hours, 720))))
  select jsonb_build_object('hours', greatest(1, least(p_hours, 720))) || coalesce(jsonb_object_agg(ch, jsonb_build_object('n', n, 'avg_ms', avg_ms, 'p95_ms', p95_ms)), '{}'::jsonb)
    from (select ch, count(*) as n, round(avg(send_ms))::integer as avg_ms,
                 (percentile_cont(0.95) within group (order by send_ms))::integer as p95_ms
            from s group by ch) x
$$;
create function public.server_send_latency(p_hours integer default 24) returns jsonb
language sql stable security definer set search_path = public, app as $$ select app.send_latency_stats(p_hours) $$;

-- ================================================================ 2. every email at once
alter function app.server_notify_kick(text[]) rename to server_notify_kick_pre2980;
create function app.server_notify_kick(p_kinds text[] default null) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  v jsonb := app.server_notify_kick_pre2980(p_kinds);
  v_email boolean;
  v_cmd text;
begin
  v_email := exists (select 1 from notification_outbox o where o.status = 'queued' and o.send_after <= now() and coalesce(o.channel, 'email') = 'email');
  if v_email then
    begin
      -- the first call above asked already when an urgent email waited (and moved the time): never twice in 5 seconds
      update app.notify_kick_state set at = now() where k = 'email' and at < now() - interval '5 seconds';
      if found then
        select j.command into v_cmd from cron.job j where j.jobname = 'carmacars-send-outbox' and j.active;
        if v_cmd is not null then execute v_cmd; end if;
      end if;
    exception when others then
      raise warning 'notify kick: the email sender was not asked: %', sqlerrm;
    end;
  end if;
  return v || jsonb_build_object('email', v_email);
end $$;
comment on function app.server_notify_kick(text[]) is 'r48 (2980): 0670''s kick, and the email sender asked whenever any email is due (at most every 5 seconds). Called by the site after a write, by its listen on every queued message, and every minute.';
select pg_temp.copy_grants('app.server_notify_kick(text[])'::regprocedure, 'app.server_notify_kick_pre2980(text[])'::regprocedure);

-- ================================================================ 4. live pages
do $$
begin
  perform app.live_watch('public.tasks'::regclass, 'tasks', 'booking_id', 'assigned_to');
  if to_regclass('public.phone_threads') is not null then
    perform app.live_watch('public.phone_threads'::regclass, 'messages', '-', '-');
  end if;
end $$;

alter function app.server_live_topics(uuid, text[]) rename to server_live_topics_pre2980;
create function app.server_live_topics(p_user uuid, p_scopes text[]) returns jsonb
language plpgsql stable security definer set search_path = public, app as $$
declare
  out jsonb := app.server_live_topics_pre2980(p_user, array(select s from unnest(coalesce(p_scopes, '{}')) s where s is distinct from 'staff:tasks'));
begin
  if 'staff:tasks' = any (coalesce(p_scopes, '{}'))
     and exists (select 1 from users u where u.id = p_user and u.status = 'active')
     and exists (select 1 from user_roles r where r.user_id = p_user and r.role in ('admin', 'va', 'field')) then
    out := out || jsonb_build_object('staff:tasks', app.live_topic('staff:tasks'));
  end if;
  return out;
end $$;
select pg_temp.copy_grants('app.server_live_topics(uuid, text[])'::regprocedure, 'app.server_live_topics_pre2980(uuid, text[])'::regprocedure);

-- ================================================================ privileges
revoke all on function app.send_notify(), app.send_latency(), app.send_latency_stats(integer), public.server_send_latency(integer) from public, anon, authenticated;
grant execute on function app.send_notify(), app.send_latency(), app.send_latency_stats(integer), public.server_send_latency(integer),
  app.server_notify_kick_pre2980(text[]), app.server_live_topics_pre2980(uuid, text[]) to service_role;
revoke all on function app.server_notify_kick_pre2980(text[]), app.server_live_topics_pre2980(uuid, text[]) from public, anon, authenticated;
