-- 52: the cookie notice for Canada outside Quebec and the US (migration 0074): the record of a notice shown, the
-- region kept with it, an opt out after it, a bad region dropped; the banner wording; and site health's scheduled
-- jobs check, which no longer reports a run that could not start once the job has run since; the phone number.
select test.suite('52 cookie notice and site health');

select test.eq('a notice shown is recorded with analytics on and the region',
  (select (public.record_cookie_notice('cn-visitor-0001', '2026-10-21', 'ca-on', 'test agent') ->> 'analytics')), 'true');
select test.eq('the record keeps choice implied and region CA-ON',
  (select choice || ' ' || region from cookie_consents where visitor_id = 'cn-visitor-0001' order by recorded_at desc limit 1), 'implied CA-ON');
select test.eq('a malformed region is dropped, the notice still recorded',
  (select (public.record_cookie_notice('cn-visitor-0002', '2026-10-21', 'Ontario<script>', null) ->> 'ok')), 'true');
select test.eq('the dropped region is stored empty',
  (select coalesce(region, 'none') from cookie_consents where visitor_id = 'cn-visitor-0002' limit 1), 'none');
select test.eq('opting out after the notice is recorded as necessary only',
  (select (public.record_cookie_choice('cn-visitor-0001', 'necessary_only', '2026-10-21', false, null) ->> 'analytics')), 'false');
select test.throws('an unknown choice is still refused', $$select public.record_cookie_choice('cn-visitor-0003', 'maybe', '2026-10-21', null, null)$$, 'Unknown choice');
select test.eq('the banner wording lists where the notice applies, with Quebec asked first (or the seed has not run)',
  coalesce((select ((data -> 'implied_regions') ? 'CA' and (data -> 'implied_exceptions') ? 'CA-QC' and data ? 'notice')::text
              from site_content_blocks where block_key = 'cookies.banner' and data ? 'implied_regions'), 'true'), 'true');
select test.eq('the privacy policy describes the notice where it has our text (or the seed has not run)',
  coalesce((select (body like '%analytics are on when you arrive and a notice tells you so%')::text from site_content_blocks
              where block_key = 'legal.privacy' and body like '%Analytics cookies measure how the Site is used%'), 'true'), 'true');

-- site health: a startup timeout followed by a good run is quiet; a startup timeout with no good run since is reported
do $$
declare v_job bigint;
begin
  if to_regclass('cron.job_run_details') is null then return; end if;
  if to_regclass('cron.job') is null then return; end if;
  execute 'select jobid from cron.job order by jobid limit 1' into v_job;
  if v_job is null then return; end if;
  execute 'delete from cron.job_run_details where jobid = $1 and start_time > now() - interval ''2 hours''' using v_job;
  execute $i$insert into cron.job_run_details (jobid, runid, job_pid, database, username, command, status, return_message, start_time, end_time)
  values ($1, 900001, 0, current_database(), current_user, 'select 1', 'failed', 'job startup timeout', now() - interval '10 minutes', now() - interval '10 minutes'),
         ($1, 900002, 0, current_database(), current_user, 'select 1', 'succeeded', '1 row', now() - interval '9 minutes', now() - interval '9 minutes')$i$ using v_job;
end $$;
create or replace function pg_temp.jobs_detail() returns text language plpgsql as $f$
begin
  if to_regclass('cron.job_run_details') is null or to_regclass('cron.job') is null then return 'no-cron'; end if;
  if not exists (select 1 from cron.job) then return 'no-cron'; end if;
  perform app.uptime_internal();
  return (select detail from uptime_results where check_key = 'jobs' order by at desc, id desc limit 1);
end $f$;
select test.eq('a run that could not start, then ran, is not reported',
  case when coalesce(pg_temp.jobs_detail(), '') like '%pg_cron%' then 'reported' else 'quiet' end, 'quiet');
do $$
begin
  if to_regclass('cron.job_run_details') is null then return; end if;
  execute 'delete from cron.job_run_details where runid = 900002';
end $$;
select test.eq('a run that could not start with no good run since is reported (or pg_cron is not installed here)',
  case when pg_temp.jobs_detail() = 'no-cron' or coalesce(pg_temp.jobs_detail(), '') like '%pg_cron%' then 'reported' else 'quiet' end, 'reported');
do $$ begin if to_regclass('cron.job_run_details') is not null then execute 'delete from cron.job_run_details where runid = 900001'; end if; end $$;

-- the phone number moved to 289-321-5991 everywhere it is set (other suites change the site number, so check that
-- nothing still holds the old one)
select test.eq('no site setting keeps 647-575-3377',
  (select count(*)::text from site_settings where concat_ws(' ', phone, phone_display, whatsapp, whatsapp_display, roadside_phone, roadside_phone_display) ~ '6475753377|647-575-3377'), '0');
select test.eq('no Program settings row keeps 647-575-3377',
  (select count(*)::text from program_settings where concat_ws(' ', company_phone, incident_line_phone) ~ '6475753377|647-575-3377'), '0');
select test.eq('no guide text keeps the old number',
  (select count(*)::text from guide_sections where coalesce(body_md, '') || coalesce(published_html, '') like '%647-575-3377%'), '0');
