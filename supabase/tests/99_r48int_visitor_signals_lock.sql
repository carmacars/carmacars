-- 99: the 5-minute visitor signals job never overlaps itself and never waits behind a beacon (migration 3328; the deadlock of
-- the carmacars-visitor-signals cron job). Two connections through dblink where it is installed. Fixtures start with "vsl".
select test.suite('99 r48int visitor signals job locks (3328)');

select public.track_ingest(jsonb_build_object('sid', md5('vsl-sid:a')::uuid, 'vid', md5('vsl-vid:a')::uuid, 'consent', 'analytics', 'device', 'desktop',
  'landing', '/', 'events', jsonb_build_array(jsonb_build_object('k', 'page_view', 'path', '/'))), '{"city": "Toronto", "region": "ON", "country": "CA"}');
-- eligible for the job: seen recently, not scored in the last 4 minutes
update visitor_sessions set score_at = null, last_seen_at = now() where id = md5('vsl-sid:a')::uuid;

create or replace function pg_temp.vsl() returns text language plpgsql as $$
declare
  c text := format('host=%s port=%s dbname=%s user=%s', split_part(current_setting('unix_socket_directories'), ',', 1), current_setting('port'), current_database(), current_user);
  busy text; skipped text; plain text;
begin
  begin
    create extension if not exists dblink with schema test;
    perform test.dblink_connect('vsl1', c);
  exception when others then return 'skipped';
  end;
  -- another run holds the advisory lock
  perform test.dblink_exec('vsl1', 'begin');
  perform * from test.dblink('vsl1', 'select count(*)::text from (select pg_advisory_xact_lock(hashtext(''app.job_visitor_signals''))) q') as t(x text);
  busy := app.job_visitor_signals(now());
  perform test.dblink_exec('vsl1', 'commit');
  -- a beacon holds the session row
  perform test.dblink_exec('vsl1', 'begin');
  perform * from test.dblink('vsl1', format('select count(*)::text from (select 1 from visitor_sessions where id = %L for update) q', md5('vsl-sid:a')::uuid)) as t(x text);
  skipped := app.job_visitor_signals(now()) || ' score_at ' || coalesce((select score_at::text from visitor_sessions where id = md5('vsl-sid:a')::uuid), 'none');
  perform test.dblink_exec('vsl1', 'commit');
  plain := app.job_visitor_signals(now()) || ' score_at ' || (select (score_at is not null)::text from visitor_sessions where id = md5('vsl-sid:a')::uuid);
  perform test.dblink_disconnect('vsl1');
  return busy || ' | ' || skipped || ' | ' || plain;
end $$;
create temp table vsl_res as select pg_temp.vsl() as r;
select test.ok('while another run holds the lock the job returns busy',
  (select r = 'skipped' or split_part(r, ' | ', 1) = 'busy' from vsl_res));
select test.eq('a session a beacon holds is left alone (not evaluated), and evaluated by the next run',
  (select case when r = 'skipped' or (split_part(r, ' | ', 2) like 'evaluated % score_at none' and split_part(r, ' | ', 3) like 'evaluated % score_at true') then 'ok' else r end from vsl_res), 'ok');
select test.ok('the lock is released with the transaction: the job runs again', app.job_visitor_signals(now() + interval '2 hours') like 'evaluated %');
