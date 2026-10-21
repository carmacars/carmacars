-- 0075_site_health_quiet.sql
-- Site health, scheduled jobs: a pg_cron run that failed only because it could not start for a moment ('job startup
-- timeout', when every database connection was briefly busy, for example during a full live check) no longer shows as
-- an error once the same job has run successfully after it. A job that keeps failing, or fails for any other reason,
-- is still reported. Only the scheduled jobs query of app.uptime_internal changes.

CREATE OR REPLACE FUNCTION app.uptime_internal(p_now timestamp with time zone DEFAULT now())
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'app'
AS $function$
declare
  ps program_settings := app.settings(app.local_date(p_now));
  v_failed integer;
  v_stuck integer;
  v_cron text;
  v_jobs text;
  b job_runs;
  v_ok_at timestamptz;
  v_stripe integer;
  v_out jsonb := '{}'::jsonb;
  v_detail text;
begin
  -- emails: failures in the last hour, or emails due 15 minutes ago and still waiting (the sender is not running)
  select count(*) into v_failed from notification_outbox where status = 'failed' and updated_at > p_now - interval '1 hour';
  select count(*) into v_stuck from notification_outbox where status = 'queued' and send_after < p_now - interval '15 minutes';
  v_detail := case when v_failed >= ps.uptime_email_failures then format('%s emails failed in the last hour', v_failed)
                   when v_stuck > 0 then format('%s emails waiting more than 15 minutes (the sender may have stopped)', v_stuck) end;
  v_out := v_out || jsonb_build_object('email', app.uptime_record('email', v_detail is null, null, null, coalesce(v_detail, 'Sending normally'), p_now));
  -- scheduled jobs: a pg_cron run that failed in the last hour, or a job run marked failed
  if to_regclass('cron.job_run_details') is not null then
    begin
      execute $q$select string_agg(distinct j.jobname, ', ') from cron.job_run_details d join cron.job j on j.jobid = d.jobid
                  where d.status = 'failed' and d.start_time > $1 - interval '1 hour'
                    -- a run pg_cron could not start (no free connection for a moment) is only a problem if the job has
                    -- not run successfully since: the next minute's run catches up (0075)
                    and not (coalesce(d.return_message, '') ilike '%startup timeout%' and exists (
                      select 1 from cron.job_run_details n where n.jobid = d.jobid and n.status = 'succeeded' and n.start_time > d.start_time))$q$ into v_cron using p_now;
    exception when others then v_cron := null;
    end;
  end if;
  select string_agg(distinct job_name, ', ') into v_jobs from job_runs where status = 'failed' and coalesce(finished_at, started_at) > p_now - interval '1 hour';
  v_detail := nullif(concat_ws('; ', 'pg_cron: ' || v_cron, 'failed runs: ' || v_jobs), '');
  v_out := v_out || jsonb_build_object('jobs', app.uptime_record('jobs', v_detail is null, null, null, coalesce(v_detail, 'No failed run in the last hour'), p_now));
  -- the nightly backup: the last run failed, or the last good one is too old (only once a backup has run)
  select * into b from job_runs where job_name = 'backup-nightly' order by started_at desc limit 1;
  select max(coalesce(finished_at, started_at)) into v_ok_at from job_runs where job_name = 'backup-nightly' and status = 'succeeded';
  if b.id is null then
    v_out := v_out || jsonb_build_object('backup', app.uptime_record('backup', true, null, null, 'No backup recorded yet on this database', p_now));
  else
    v_detail := case when b.status = 'failed' then 'The last nightly backup failed: ' || coalesce(left(b.error, 200), 'see the backup workflow')
                     when v_ok_at is null or v_ok_at < p_now - make_interval(hours => ps.uptime_backup_max_hours)
                       then format('No good backup for more than %s hours (last: %s)', ps.uptime_backup_max_hours, coalesce(app.fmt_at(v_ok_at), 'never')) end;
    v_out := v_out || jsonb_build_object('backup', app.uptime_record('backup', v_detail is null, null, null,
      coalesce(v_detail, 'Last good backup ' || app.fmt_at(v_ok_at)), p_now));
  end if;
  -- Stripe: events that failed to process in the last hour (Stripe retries; a later success clears the error)
  select count(*) into v_stripe from webhook_events where provider = 'stripe' and error is not null and received_at > p_now - interval '1 hour';
  v_out := v_out || jsonb_build_object('stripe', app.uptime_record('stripe', v_stripe = 0, null, null,
    case when v_stripe = 0 then 'No failed Stripe event in the last hour' else format('%s Stripe events failed to process in the last hour', v_stripe) end, p_now));
  return v_out;
end $function$;


-- ================================================================ cookies: notice and opt out in Canada outside Quebec and the US
-- Approved by the owner and the company's lawyer (October 21, 2026). Analytics are on with a notice for visitors from
-- the regions in cookies.banner.implied_regions (country codes, or country-region) except implied_exceptions; everyone
-- else (and a visitor whose location is unknown) is asked first, as before. The Worker gives the browser its location
-- as the cookie cc_geo (country-region, for example CA-ON); nothing about it is stored except the region on the record
-- of what the visitor was shown.
alter table cookie_consents add column if not exists region text check (region is null or region ~ '^[A-Z]{2}(-[A-Z0-9]{1,3})?$');
alter table cookie_consents drop constraint if exists cookie_consents_choice_check;
alter table cookie_consents add constraint cookie_consents_choice_check check (choice in ('accept_all', 'necessary_only', 'custom', 'implied'));
comment on column cookie_consents.region is 'Where the visitor was visiting from when shown the notice (0075), country-region; null when asked first';

-- The notice was shown and the visitor did not opt out (yet): analytics on, recorded with the region and wording.
create or replace function app.record_cookie_notice(p_visitor_id text, p_wording_version text, p_region text default null, p_user_agent text default null)
returns jsonb language plpgsql security definer set search_path = public, app as $$
declare
  v_id uuid;
  v_region text := nullif(upper(btrim(coalesce(p_region, ''))), '');
begin
  perform app.public_rate_check('cookie_choice');
  if v_region is not null and v_region !~ '^[A-Z]{2}(-[A-Z0-9]{1,3})?$' then v_region := null; end if;
  insert into cookie_consents (visitor_id, user_id, choice, analytics, consent_codes, wording_version, user_agent, region)
  values (p_visitor_id, app.uid(), 'implied', true, array['necessary_cookies', 'analytics_cookies'], btrim(p_wording_version), left(p_user_agent, 300), v_region)
  returning id into v_id;
  return jsonb_build_object('ok', true, 'id', v_id, 'analytics', true);
end $$;
create or replace function public.record_cookie_notice(p_visitor_id text, p_wording_version text, p_region text default null, p_user_agent text default null)
returns jsonb language sql set search_path = public, app as $$
  select app.record_cookie_notice(p_visitor_id, p_wording_version, p_region, p_user_agent)
$$;
revoke all on function app.record_cookie_notice(text, text, text, text), public.record_cookie_notice(text, text, text, text) from public;
grant execute on function app.record_cookie_notice(text, text, text, text), public.record_cookie_notice(text, text, text, text) to anon, authenticated, service_role;

update site_content_blocks
   set data = data || jsonb_build_object('version', '2026-10-21',
     'notice', 'We use cookies to keep the site working and to measure visits ourselves, so our team can help you while you browse. No third-party analytics.',
     'ok', 'OK', 'optout', 'Opt out', 'notice_seconds', 10,
     'implied_regions', jsonb_build_array('CA', 'US'), 'implied_exceptions', jsonb_build_array('CA-QC'))
 where block_key = 'cookies.banner' and coalesce(data ->> 'version', '') < '2026-10-21';
update site_content_blocks
   set body = replace(replace(body, 'Essential cookies keep you signed in and keep bookings secure. Analytics cookies measure how the Site is used and are set only if you accept them. You can block cookies in your browser, but parts of the Site may then not work.', 'Essential cookies keep you signed in and keep bookings secure. Analytics cookies measure how the Site is used. If you visit from Canada outside Quebec or from the United States, analytics are on when you arrive and a notice tells you so; you can opt out on that notice or at any time with "Cookie choices" at the bottom of every page, and we then stop at once. If you visit from Quebec or from anywhere else, analytics are set only if you accept them. We work out where you are visiting from with your connection''s approximate location, which we do not store for this. You can also block cookies in your browser, but parts of the Site may then not work.'), 'Without your consent we record none of it, except what follows.', 'If you opt out, or if you visit from a place where we ask first and you do not accept, we record none of it, except what follows.')
 where block_key = 'legal.privacy' and body like '%Essential cookies keep you signed in and keep bookings secure. Analytics cookies measure how the Site is used and are set only if you accept them. You can block cookies in your browser, but parts of the Site may then not work.%';
update site_content_blocks set data = data || jsonb_build_object('last_updated', 'October 21, 2026')
 where block_key = 'legal.meta' and (data ->> 'last_updated') in ('October 19, 2026');

-- ================================================================ the phone number (October 21, 2026: 289-321-5991)
-- The company's number moves from 647-575-3377 to 289-321-5991 everywhere it is set: the site (phone, WhatsApp,
-- roadside), Program settings (company and incident line, used in agreements, emails and notices) and the text of the
-- guides. Only fields still holding the old number change; a number set to something else is left alone. History (sent
-- emails, chat messages, the audit log, earlier guide versions) keeps what was true when it was written.
update site_settings set phone = '+12893215991' where phone = '+16475753377';
update site_settings set phone_display = '289-321-5991' where phone_display = '647-575-3377';
update site_settings set whatsapp = '+12893215991' where whatsapp = '+16475753377';
update site_settings set whatsapp_display = '289-321-5991' where whatsapp_display = '647-575-3377';
update site_settings set roadside_phone = '+12893215991' where roadside_phone = '+16475753377';
update site_settings set roadside_phone_display = '289-321-5991' where roadside_phone_display = '647-575-3377';
update program_settings set company_phone = '+12893215991' where company_phone = '+16475753377';
update program_settings set incident_line_phone = '+12893215991' where incident_line_phone = '+16475753377';
update guide_sections
   set body_md = replace(replace(body_md, '647-575-3377', '289-321-5991'), '+16475753377', '+12893215991'),
       published_md = replace(replace(published_md, '647-575-3377', '289-321-5991'), '+16475753377', '+12893215991'),
       published_html = replace(replace(published_html, '647-575-3377', '289-321-5991'), '+16475753377', '+12893215991'),
       auto_prev = case when auto_prev is null then null else replace(replace(auto_prev::text, '647-575-3377', '289-321-5991'), '+16475753377', '+12893215991')::jsonb end
 where body_md like '%647-575-3377%' or published_md like '%647-575-3377%' or published_html like '%647-575-3377%'
    or auto_prev::text like '%647-575-3377%' or published_html like '%+16475753377%';
update site_content_blocks set body = replace(replace(body, '647-575-3377', '289-321-5991'), '+16475753377', '+12893215991')
 where body like '%647-575-3377%' or body like '%+16475753377%';
update site_content_blocks set data = replace(replace(data::text, '647-575-3377', '289-321-5991'), '+16475753377', '+12893215991')::jsonb
 where data::text like '%647-575-3377%' or data::text like '%+16475753377%';
