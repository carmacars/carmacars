-- 0670_instant_notifications.sql
-- Release 32, part A (docs/changes/2026-11-07-r32-edge-cpu-notify.md): urgent alerts, texts and phone pushes at once.
--   1. public.server_notify_kick(p_kinds): the Worker asks it right after a write (any POST that reached the app) and on
--      every minute of the cron: the waiting events become notices now (app.process_events, as the minute job does; skip
--      locked, so the two never clash), and it answers what is due: a push (for the kinds the Worker can send), a text, an
--      urgent email. When an urgent email waits, the email sender is asked at once (the pg_cron job's own call,
--      carmacars-send-outbox, at most every 20 seconds) instead of on its next minute.
--   2. Urgent emails skip the hour's pace: a staff or Admin alert marked urgent (0583: a payment declined, documents to
--      review for a pickup within 2 hours, the site down; still at most 3 an hour per person) and a customer email of the
--      first class written in the last 15 minutes (a confirmation, a signing link) are claimed first and on top of the
--      hour's pace. The day's cap (the providers' budgets together) still applies; digests and other emails keep the pace.
--   3. A phone push never waits for its email's due time: it is due when its notice is written (customers' quiet hours
--      and each staff member's own quiet hours still hold the alerts that are not urgent).
-- No applied migration is edited.

create function pg_temp.patch_fn(p_sig regprocedure, p_old text, p_new text) returns void
language plpgsql as $$
declare
  d text := pg_get_functiondef(p_sig);
begin
  if position(p_old in d) = 0 then
    raise exception '0670: the text to change was not found in %: %', p_sig, left(p_old, 120);
  end if;
  execute replace(d, p_old, p_new);
end $$;

-- ================================================================ 2. urgent emails
create or replace function app.outbox_urgent(p_reason text, p_priority smallint, p_created timestamptz, p_now timestamptz default now()) returns boolean
language sql immutable as $$
  select coalesce(p_reason, '') = 'urgent' or (p_priority = 1 and p_created > p_now - interval '15 minutes')
$$;
comment on function app.outbox_urgent(text, smallint, timestamptz, timestamptz) is 'An email that skips the hour''s pace (0670): a staff alert marked urgent (0583) or a first-class customer email written in the last 15 minutes.';

-- the urgent emails due now (at most 50: the claim takes them on top of the hour's pace)
create or replace function app.outbox_urgent_waiting(p_now timestamptz default now()) returns integer
language sql stable security definer set search_path = public, app as $$
  select count(*)::integer from (select 1 from notification_outbox o
   where o.status = 'queued' and o.send_after <= p_now and coalesce(o.channel, 'email') = 'email'
     and app.outbox_urgent(o.status_reason, o.priority, o.created_at, p_now) limit 50) x
$$;

-- the pace layer (0583, now app.outbox_claim_pre0601): the hour's room grows by the urgent emails waiting
select pg_temp.patch_fn('app.outbox_claim_pre0601(integer, timestamptz)'::regprocedure,
  $o$v_hour_left := (ceil(v_cap / 24.0)::integer + 30) - app.emails_since(p_now - interval '1 hour', p_now);$o$,
  $n$v_hour_left := greatest(0, (ceil(v_cap / 24.0)::integer + 30) - app.emails_since(p_now - interval '1 hour', p_now)) + app.outbox_urgent_waiting(p_now);$n$);

-- the claim itself (0018's, patched by 0222 and 0535): the urgent emails first, whatever their class
do $$
declare f regprocedure; n integer := 0;
begin
  for f in select p.oid::regprocedure from pg_proc p join pg_namespace s on s.oid = p.pronamespace
            where s.nspname = 'app' and p.proname like 'outbox\_claim%' and p.prosrc like '%order by o.priority, o.send_after, o.created_at%' loop
    perform pg_temp.patch_fn(f, 'order by o.priority, o.send_after, o.created_at',
      'order by app.outbox_urgent(o.status_reason, o.priority, o.created_at, p_now) desc, o.priority, o.send_after, o.created_at');
    n := n + 1;
  end loop;
  if n = 0 then raise exception '0670: the claim''s order was not found'; end if;
end $$;

-- ================================================================ 3. pushes at once
select pg_temp.patch_fn('app.push_from_notice()'::regprocedure,
  $o$v_after := greatest(coalesce((v_payload ->> '_send_after')::timestamptz, now()), now());$o$,
  $n$v_after := now();  -- 0670: never the email's due time$n$);

-- ================================================================ 1. the kick
create table if not exists app.notify_kick_state (k text primary key, at timestamptz not null default '-infinity');
insert into app.notify_kick_state (k) values ('email') on conflict do nothing;
comment on table app.notify_kick_state is 'Instant notifications (0670): when the email sender was last asked outside its minute (at most every 20 seconds).';
revoke all on app.notify_kick_state from public, anon, authenticated;

create or replace function app.server_notify_kick(p_kinds text[] default null) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  v_events integer := 0;
  v_email boolean;
  v_cmd text;
begin
  if exists (select 1 from app_events where processed_at is null) then
    begin
      v_events := app.process_events(null, now());
    exception when others then
      raise warning 'notify kick: events not processed: %', sqlerrm;
    end;
  end if;
  v_email := exists (select 1 from notification_outbox o where o.status = 'queued' and o.send_after <= now() and coalesce(o.channel, 'email') = 'email'
                       and app.outbox_urgent(o.status_reason, o.priority, o.created_at, now()));
  if v_email then
    begin
      update app.notify_kick_state set at = now() where k = 'email' and at < now() - interval '20 seconds';
      if found then
        -- the sender's own call (scheduled by the deploy, scripts/deploy/supabase.sh outbox): the same address and token
        select j.command into v_cmd from cron.job j where j.jobname = 'carmacars-send-outbox' and j.active;
        if v_cmd is not null then execute v_cmd; end if;
      end if;
    exception when others then
      raise warning 'notify kick: the email sender was not asked: %', sqlerrm;
    end;
  end if;
  return jsonb_build_object('events', v_events, 'email', v_email,
    'push', coalesce(cardinality(p_kinds), 0) > 0 and app.server_push_waiting(p_kinds),
    'phone', exists (select 1 from phone_outbox where status = 'queued' and send_after <= now()));
end $$;
comment on function app.server_notify_kick(text[]) is 'Instant notifications (0670): the waiting events become notices now; what is due (push, text, urgent email). Called by the Worker after a write and every minute.';

create or replace function public.server_notify_kick(p_kinds text[] default null) returns jsonb
language sql volatile security invoker set search_path = public, app as $$ select app.server_notify_kick(p_kinds) $$;

revoke all on function app.outbox_urgent(text, smallint, timestamptz, timestamptz), app.outbox_urgent_waiting(timestamptz),
  app.server_notify_kick(text[]), public.server_notify_kick(text[]) from public, anon, authenticated;
grant execute on function app.outbox_urgent(text, smallint, timestamptz, timestamptz), app.outbox_urgent_waiting(timestamptz),
  app.server_notify_kick(text[]), public.server_notify_kick(text[]) to service_role;
grant select, update on app.notify_kick_state to service_role;
