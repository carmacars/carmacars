-- 5090 (R50 hotfix 2, comms; tests: supabase/tests/99_r50h2_texts_recover.sql): texts recover by themselves once Quo has
-- credits again.
-- What went wrong (production, Nov 25): Admin > Site health showed "Sign-in codes by text" failing since Nov 24 00:42
-- with "Quo 402: ... not enough prepaid credits" (498 checks in a row) after the owner topped up, while texts sent
-- through Quo's API went again (CC-10654, Nov 25 16:19, delivered).
--   1. app.sms_signin_failing (3410) read only the last 3 sign-in texts of 7 days. The site check repeated that
--      verdict every 5 minutes, and while it was failing the sign-in page put the password form first, so few new
--      sign-in texts were tried: the check could stay red for up to 7 days after the credits came back. Now any text
--      that went through Quo's API after the newest failure (a booking or staff text, or a sign-in code) clears it.
--   2. A sign-in code that Quo refuses for its account (402, credits) pauses texts like any other text (3113), and one
--      that goes ends the pause. Before, the two never met: sign-in codes neither paused nor resumed the other texts.
--   3. While texts are paused, a due text waits for the pause to end for up to text_retry_paused_minutes (30) instead
--      of falling back to email at once; the probe (one text every text_retry_paused_minutes) that goes ends the pause
--      and the waiting texts go on the next run. A text that waited that long falls back to email as before.
-- No applied migration is edited: functions are replaced with the same signatures (grants kept) or wrapped (_pre5090).
-- Re-run safe: create or replace, and the rename to _pre5090 happens only once.
-- SCHEMA_MARKER 5090.
set local check_function_bodies = off;

create or replace function pg_temp.copy_grants(p_new regprocedure, p_old regprocedure) returns void
language plpgsql as $$
declare g text;
begin
  execute format('revoke all on function %s from public, anon, authenticated', p_new);
  foreach g in array array['anon', 'authenticated', 'service_role'] loop
    if has_function_privilege(g, p_old, 'execute') then execute format('grant execute on function %s to %I', p_new, g); end if;
  end loop;
end $$;

-- the texts that went, newest first (the check below reads the newest one)
create index if not exists phone_outbox_sent_at_idx on phone_outbox (sent_at) where status = 'sent';
create index if not exists auth_sms_log_sent_idx on app.auth_sms_log (created_at) where status = 'sent';

-- ================================================================ 1. the newest text Quo's API took
create or replace function app.quo_last_sent(p_now timestamptz default now()) returns timestamptz
language sql stable security definer set search_path = public, app, pg_temp as $$
  select greatest(
    (select max(o.sent_at) from phone_outbox o where o.status = 'sent' and o.sent_at > p_now - interval '7 days' and o.sent_at <= p_now),
    (select max(s.created_at) from app.auth_sms_log s where s.status = 'sent' and s.created_at > p_now - interval '7 days' and s.created_at <= p_now),
    (select q.quo_ok_at from phone_provider_state q where q.id and q.quo_ok_at <= p_now))
$$;
comment on function app.quo_last_sent(timestamptz) is 'R50 hotfix 2 (5090): the newest text that Quo''s API took (a booking or staff text, a sign-in code) in the last 7 days.';

-- failing: the last 3 sign-in texts failed and no text has gone through Quo since the newest of them
create or replace function app.sms_signin_failing(p_now timestamptz default now()) returns jsonb
language sql stable security definer set search_path = public, app, pg_temp as $$
  with l as (select s.status, s.reason, s.created_at from app.auth_sms_log s
              where s.status in ('sent', 'failed') and s.created_at > p_now - interval '7 days' and s.created_at <= p_now
              order by s.created_at desc limit 3),
       t as (select app.quo_last_sent(p_now) as sent_at)
  select jsonb_build_object(
    'failing', (select count(*) from l) = 3 and not exists (select 1 from l where l.status = 'sent')
               and coalesce((select t.sent_at from t) < (select max(l.created_at) from l), true),
    'reason', (select l.reason from l order by l.created_at desc limit 1),
    'last_failed_at', (select max(l.created_at) from l where l.status = 'failed'),
    'last_sent_at', (select t.sent_at from t))
$$;

-- ================================================================ 2. sign-in codes pause and resume the texts too
do $$
begin
  if to_regprocedure('app.server_auth_sms_result_pre5090(jsonb)') is null then
    alter function app.server_auth_sms_result(jsonb) rename to server_auth_sms_result_pre5090;
  end if;
end $$;
create or replace function app.server_auth_sms_result(p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app, pg_temp as $$
declare
  r jsonb := app.server_auth_sms_result_pre5090(p);
  v_err text := left(p ->> 'error', 300);
begin
  if not coalesce((r ->> 'ok')::boolean, false) then return r; end if;
  if coalesce((p ->> 'ok')::boolean, false) then
    update phone_provider_state set quo_ok_at = now(), updated_at = now() where id and app.quo_paused();
  elsif app.quo_account_error(v_err) then
    update phone_provider_state set quo_failed_at = now(), quo_error = v_err, updated_at = now() where id;
    perform app.texts_alert(v_err);
  end if;
  return r;
end $$;
select pg_temp.copy_grants('app.server_auth_sms_result(jsonb)'::regprocedure, 'app.server_auth_sms_result_pre5090(jsonb)'::regprocedure);

-- ================================================================ 3. while paused, due texts wait for the probe
-- (3113's version with one change: only a text that waited text_retry_paused_minutes falls back to email)
create or replace function app.server_phone_due(p_limit integer default 20) returns jsonb
language plpgsql security definer set search_path = public, app, pg_temp as $$
declare
  s program_settings := app.settings();
  o phone_outbox;
  v_why text;
  v_probe boolean := false;
  v_dropped integer := 0;
  v_fell integer := 0;
  v_wait interval := make_interval(mins => s.text_retry_paused_minutes);
  r jsonb;
begin
  for o in select * from phone_outbox where status = 'queued' and send_after <= now() order by send_after limit greatest(p_limit, 1) * 5 for update skip locked loop
    v_why := app.text_drop_reason(o);
    if v_why is not null then
      update phone_outbox set status = 'skipped', locked_at = null, status_reason = left(v_why, 300) where id = o.id;
      v_dropped := v_dropped + 1;
    end if;
  end loop;
  if app.quo_paused() then
    select coalesce(q.quo_probe_at, '-infinity') < now() - v_wait into v_probe from phone_provider_state q;
    -- the probe takes the oldest due text (server_phone_due_pre3113 claims by send_after): it is never the one that falls back
    for o in select * from phone_outbox where status = 'queued' and send_after <= now() - v_wait and kind <> 'staff'
              and (not v_probe or id <> (select x.id from phone_outbox x where x.status = 'queued' and x.send_after <= now() order by x.send_after limit 1))
              order by send_after limit greatest(p_limit, 1) * 5 for update skip locked loop
      perform app.text_fall_back(o.id, 'Quo is refusing texts: ' || coalesce((select quo_error from phone_provider_state), 'its account'));
      v_fell := v_fell + 1;
    end loop;
    if not v_probe then
      return jsonb_build_object('texts', '[]'::jsonb, 'summaries', '[]'::jsonb, 'ai', app.phone_ai_budget(), 'from', app.phone_our_number(), 'paused', true, 'dropped', v_dropped, 'fell_back', v_fell,
        'waiting', (select count(*) from phone_outbox where status = 'queued' and send_after <= now()));
    end if;
    update phone_provider_state set quo_probe_at = now() where id;
    r := app.server_phone_due_pre3113(1);
    return r || jsonb_build_object('paused', true, 'probe', true, 'dropped', v_dropped, 'fell_back', v_fell);
  end if;
  return app.server_phone_due_pre3113(p_limit) || jsonb_build_object('dropped', v_dropped);
end $$;

do $$
declare f record;
begin
  for f in select p.oid::regprocedure sig from pg_proc p join pg_namespace n on n.oid = p.pronamespace
            where n.nspname = 'app' and p.proname = any (array['quo_last_sent', 'server_auth_sms_result_pre5090']) loop
    execute format('revoke all on function %s from public, anon, authenticated', f.sig);
    execute format('grant execute on function %s to service_role', f.sig);
  end loop;
end $$;
