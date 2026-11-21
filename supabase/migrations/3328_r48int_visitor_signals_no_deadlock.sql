-- 3328 (release 48, integration; production alert, pg_cron job carmacars-visitor-signals, "deadlock detected" at 19:30): app.job_visitor_signals (0086)
-- evaluated up to 300 sessions in one transaction while the beacon door (track_ingest) updated the same session rows and vehicle_interest_daily
-- and then evaluated that session, so the two took the same rows in different orders. Now:
--   1. one run at a time: a transaction-level advisory lock, 'busy' for a run that starts while another is going;
--   2. lock_timeout 2s, so a run never waits long behind a beacon;
--   3. the loop takes its sessions FOR UPDATE SKIP LOCKED: a session a beacon is writing is left for the next run (5 minutes later);
--   4. an evaluation that still deadlocks or times out on a lock is skipped and counted, never fails the run.
-- The text is 'evaluated N' as before, with ', skipped M' added when some were skipped. Grants and security definer are unchanged.
-- SCHEMA_MARKER 3328.
create or replace function app.job_visitor_signals(p_now timestamptz default now()) returns text
language plpgsql security definer set search_path = public, app as $$
declare
  x uuid;
  v_n integer := 0;
  v_skipped integer := 0;
begin
  if not (app.settings(app.local_date(p_now))).visitor_tracking_enabled then return 'off'; end if;
  if not pg_try_advisory_xact_lock(hashtext('app.job_visitor_signals')) then return 'busy'; end if;
  set local lock_timeout = '2s';
  for x in select s.id from visitor_sessions s
            where s.last_seen_at > p_now - interval '60 minutes' and (s.score_at is null or s.score_at < p_now - interval '4 minutes')
            order by s.last_seen_at desc limit 300 for update of s skip locked loop
    begin
      perform app.visitor_live_eval(x, p_now);
      v_n := v_n + 1;
    exception when deadlock_detected or lock_not_available then
      v_skipped := v_skipped + 1;
    end;
  end loop;
  return 'evaluated ' || v_n || case when v_skipped > 0 then ', skipped ' || v_skipped else '' end;
end $$;
