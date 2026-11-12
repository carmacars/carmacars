-- 2570_r41_ses.sql
-- Release 41 (docs/changes/2026-11-12-r41-ses.md). The owner: Amazon SES (region ca-central-1) as the main email sender once
-- it is live (cheap, high volume), Cloudflare Email and Resend's free plan kept after it.
--   1. Two Program settings: email_ses_enabled (on) and email_ses_daily_max (200 a Toronto day while the SES account is in
--      the sandbox; the owner raises it after AWS grants production access).
--   2. SES is paid per use (about USD 0.10 per 1,000 emails): the one approved exception to "never a paid send" (the owner,
--      2026-11-12), held at email_ses_daily_max a day.
--   3. The send-outbox Edge Function says it has SES keys (email_provider_state.ses_seen_at, each run) and reports account
--      level refusals (ses_failed_at, ses_error: SES rests 15 minutes). The database tries SES only while its keys were
--      seen in the last hour: without the keys nothing changes (Cloudflare first, then Resend, as before).
--   4. An email SES sent keeps provider_id 'ses:<MessageId>' (messages.provider 'ses'). It is never counted as Resend's.
--   5. The day's capacity (app.email_day_cap, which the marketing allowance of 2520 reads) is SES's day + Cloudflare's day +
--      Resend's free plan; the marketing allowance stays that capacity less the reserve for booking, payment and sign-in.
--   6. The claim: while SES or Cloudflare may send, it claims at most what they have left today, with no Resend caps.
--   7. Marketing never goes through SES (the owner, 2026-11-12: SES production access is requested as transactional, and
--      AWS's terms want recipients who asked for the email): email_ses_marketing (off) keeps category 'marketing' on
--      Cloudflare and Resend. SES's day then frees the free capacity for marketing instead: the marketing allowance is the
--      free capacity less what of the reserve SES does not already cover (with email_ses_marketing on: the whole capacity,
--      SES's included, less the reserve).
-- No applied migration is edited: functions are wrapped (renamed _pre2570) or patched in place.
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

create function pg_temp.patch_fn(p_sig regprocedure, p_old text, p_new text) returns void
language plpgsql as $$
declare
  d text := pg_get_functiondef(p_sig);
begin
  if position(p_old in d) = 0 then
    raise exception '2570: the text to change was not found in %: %', p_sig, left(p_old, 160);
  end if;
  execute replace(d, p_old, p_new);
end $$;

-- every "not Cloudflare" count (Resend's) leaves SES out too
create function pg_temp.not_ses(p_sig regprocedure) returns void
language plpgsql as $$
declare
  d text := pg_get_functiondef(p_sig);
  n text := regexp_replace(d, $r$coalesce\(((o\.)?)provider_id, ''\) not like 'cf:%'$r$, $s$coalesce(\1provider_id, '') not like 'cf:%' and coalesce(\1provider_id, '') not like 'ses:%'$s$, 'g');
begin
  if n = d then raise exception '2570: no Resend count found in %', p_sig; end if;
  execute n;
end $$;

-- ================================================================ 1. settings and the provider row
alter table program_settings
  add column if not exists email_ses_enabled boolean not null default true,
  add column if not exists email_ses_daily_max integer not null default 200 check (email_ses_daily_max >= 0),
  add column if not exists email_ses_marketing boolean not null default false;
comment on column program_settings.email_ses_enabled is 'Send emails through Amazon SES first when its keys are set (2570); then Cloudflare Email, then Resend''s free plan. SES is paid per use (owner approved).';
comment on column program_settings.email_ses_marketing is 'Marketing emails may go through Amazon SES too (2570). Off (default): marketing stays on Cloudflare and Resend; SES sends booking, payment, sign-in, staff and owner email only (SES production access is for transactional email).';
comment on column program_settings.email_ses_daily_max is 'Amazon SES emails a Toronto day at most (2570): 200 while the SES account is in the sandbox; raise it after AWS grants production access.';

alter table email_provider_state
  add column if not exists ses_seen_at timestamptz,
  add column if not exists ses_ok_at timestamptz,
  add column if not exists ses_failed_at timestamptz,
  add column if not exists ses_error text;
comment on column email_provider_state.ses_seen_at is 'Last run of the sender with Amazon SES keys set (2570): SES is tried only while this is within the hour.';
comment on column email_provider_state.ses_failed_at is 'Last account-level SES refusal (bad keys, paused, quota, outage): SES rests 15 minutes after it (2570).';
insert into email_provider_state default values on conflict do nothing;

-- ================================================================ 2. SES's day
create function app.ses_emails_between(p_from timestamptz, p_to timestamptz) returns integer
language sql stable security definer set search_path = public, app as $$
  select count(*)::integer from notification_outbox o
   where o.status in ('sent', 'sending') and coalesce(o.provider_id, '') like 'ses:%' and o.sent_at >= p_from and o.sent_at < p_to
$$;
-- what SES may still send today: on, its keys seen in the last hour, the day's maximum less today's SES sends
create function app.ses_email_left(p_now timestamptz default now()) returns integer
language sql stable security definer set search_path = public, app as $$
  select case when not coalesce(s.email_ses_enabled, false)
                or not coalesce((select e.ses_seen_at > p_now - interval '1 hour' from email_provider_state e limit 1), false) then 0
              else greatest(0, s.email_ses_daily_max - app.ses_emails_between(app.local_midnight(app.local_date(p_now)), p_now + interval '1 second')) end::integer
    from app.settings_base(app.local_date(p_now)) s
$$;
-- may the sender try SES now: budget left today, no account-level refusal in the last 15 minutes
create function app.ses_email_try(p_now timestamptz default now()) returns boolean
language sql stable security definer set search_path = public, app as $$
  select app.ses_email_left(p_now) > 0
     and not coalesce((select e.ses_failed_at > p_now - interval '15 minutes' from email_provider_state e limit 1), false)
$$;

-- the sender's reports: {seen: true} each run with keys, {ok: true} after a send, {ok: false, error} after an account-level refusal
create function app.server_ses_email_result(p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
begin
  insert into email_provider_state default values on conflict do nothing;
  if coalesce((p ->> 'seen')::boolean, false) then
    update email_provider_state set ses_seen_at = now(), updated_at = now() where id;
  elsif coalesce((p ->> 'ok')::boolean, false) then
    update email_provider_state set ses_ok_at = now(), ses_seen_at = now(), updated_at = now() where id;
  else
    update email_provider_state set ses_failed_at = now(), ses_error = left(p ->> 'error', 300), updated_at = now() where id;
  end if;
  return (select jsonb_build_object('ses_left', app.ses_email_left(now()), 'ses_try', app.ses_email_try(now())));
end $$;
create function public.server_ses_email_result(p jsonb) returns jsonb
language sql security definer set search_path = public, app as $$ select app.server_ses_email_result(p) $$;

-- an email another provider sent because SES refused it says so (Admin > Logs > Emails, "Why")
create function app.outbox_note_ses_fallback(p_id uuid, p_error text) returns void
language sql security definer set search_path = public, app as $$
  update notification_outbox set status_reason = left('sent through ' || case when coalesce(provider_id, '') like 'cf:%' then 'Cloudflare' else 'Resend' end
           || ' after an SES refusal: ' || coalesce(nullif(btrim(p_error), ''), 'no reason given'), 300)
   where id = p_id and status = 'sent' and coalesce(provider_id, '') not like 'ses:%' and status_reason is null
$$;
create function public.server_outbox_note_ses_fallback(p_id uuid, p_error text) returns void
language sql security definer set search_path = public, app as $$ select app.outbox_note_ses_fallback(p_id, p_error) $$;

-- ================================================================ 3. Resend's counts leave SES out
select pg_temp.not_ses('app.outbox_sent_today(timestamptz)'::regprocedure);
select pg_temp.not_ses('app.usage_emails_on(date, timestamptz)'::regprocedure);
select pg_temp.not_ses('app.outbox_claim_0018(integer, timestamptz)'::regprocedure);
select pg_temp.not_ses('app.email_pace(timestamptz)'::regprocedure);

-- an SES send is recorded as provider 'ses' on its message
select pg_temp.patch_fn('app.outbox_mark_sent_pre0900(uuid, text, text, timestamptz)'::regprocedure,
  $o$case when coalesce(p_provider_id, '') like 'cf:%' then 'cloudflare' else 'resend' end$o$,
  $n$case when coalesce(p_provider_id, '') like 'cf:%' then 'cloudflare' when coalesce(p_provider_id, '') like 'ses:%' then 'ses' else 'resend' end$n$);

-- ================================================================ 4. the day's capacity and the claim
-- SES's day on top of Cloudflare's and Resend's (the marketing allowance of 2520 reads this)
alter function app.email_day_cap(timestamptz) rename to email_day_cap_pre2570;
create function app.email_day_cap(p_now timestamptz default now()) returns integer
language sql stable security definer set search_path = public, app as $$
  select (app.email_day_cap_pre2570(p_now) + app.ses_emails_between(app.local_midnight(app.local_date(p_now)), p_now + interval '1 second')
          + app.ses_email_left(p_now))::integer
$$;
select pg_temp.copy_grants('app.email_day_cap(timestamptz)'::regprocedure, 'app.email_day_cap_pre2570(timestamptz)'::regprocedure);

-- the marketing allowance (2520): marketing goes through SES only with email_ses_marketing; otherwise SES's day takes the
-- reserve for booking, payment and sign-in email off the free capacity, and marketing may use the free capacity it frees
alter function app.marketing_daily_max(timestamptz) rename to marketing_daily_max_pre2570;
create function app.marketing_daily_max(p_now timestamptz default now()) returns integer
language sql stable security definer set search_path = public, app as $$
  with v as (
    select s, app.email_day_cap_pre2570(p_now) free_cap,
           app.ses_emails_between(app.local_midnight(app.local_date(p_now)), p_now + interval '1 second') + app.ses_email_left(p_now) ses_day,
           greatest(s.marketing_transactional_reserve,
             2 * ceil((select count(*) from notification_outbox o
                        where o.status = 'sent' and o.category <> 'marketing'
                          and o.sent_at >= p_now - interval '14 days' and o.sent_at < p_now) / 14.0)::integer) reserve
      from app.settings(app.local_date(p_now)) s)
  select case when not (v.s).marketing_auto_volume then (v.s).notify_marketing_daily_max
              when coalesce((v.s).email_ses_marketing, false) then greatest((v.s).notify_marketing_daily_max, v.free_cap + v.ses_day - v.reserve)
              else greatest((v.s).notify_marketing_daily_max, v.free_cap - greatest(0, v.reserve - v.ses_day)) end::integer
    from v
$$;
select pg_temp.copy_grants('app.marketing_daily_max(timestamptz)'::regprocedure, 'app.marketing_daily_max_pre2570(timestamptz)'::regprocedure);

-- the claim of 0018 lifts Resend's limits while SES or Cloudflare may send
create or replace function app.cf_email_available(p_now timestamptz default now()) returns boolean
language sql stable security definer set search_path = public, app as $$
  select app.cf_email_try(p_now) or app.ses_email_try(p_now)
$$;
-- SES's and Cloudflare's turn: no more than what they have left today together
select pg_temp.patch_fn('app.outbox_claim_pre0601(integer, timestamptz)'::regprocedure,
  E'  if app.cf_email_try(p_now) then\n    return query select * from app.outbox_claim_pre0583(least(coalesce(p_limit, 20), app.cf_email_left(p_now)), p_now);',
  E'  if app.cf_email_try(p_now) or app.ses_email_try(p_now) then\n'
  || E'    return query select * from app.outbox_claim_pre0583(least(coalesce(p_limit, 20), app.cf_email_left(p_now) + case when app.ses_email_try(p_now) then app.ses_email_left(p_now) else 0 end), p_now);');
-- held by Resend's limits: back in 15 minutes while SES or Cloudflare has budget left today
create or replace function app.email_hold_until(p_now timestamptz, p_midnight timestamptz) returns timestamptz
language sql stable security definer set search_path = public, app as $$
  select case when app.cf_email_left(p_now) + app.ses_email_left(p_now) > 0 then least(p_midnight, p_now + interval '15 minutes') else p_midnight end
$$;

-- the sender's budgets: SES's left today too; Resend's count without SES
create or replace function public.server_email_budgets() returns jsonb
language sql stable security definer set search_path = public, app as $$
  with x as (
    select s, (select count(*)::integer from notification_outbox o where o.status = 'sent' and o.provider_id like 'cf:%' and o.sent_at >= app.local_midnight(app.local_date(now()))) cf_used,
           app.cf_email_left(now()) cf_left,
           app.ses_emails_between(app.local_midnight(app.local_date(now())), now() + interval '1 second') ses_used, app.ses_email_left(now()) ses_left
      from app.settings() s)
  select jsonb_build_object('cf_budget', x.cf_used + x.cf_left, 'cf_used', x.cf_used, 'cf_left', x.cf_left,
    'ses_enabled', coalesce((x.s).email_ses_enabled, false), 'ses_marketing', coalesce((x.s).email_ses_marketing, false), 'ses_budget', (x.s).email_ses_daily_max, 'ses_used', x.ses_used, 'ses_left', x.ses_left,
    'ses_resting', coalesce((select e.ses_failed_at > now() - interval '15 minutes' from email_provider_state e limit 1), false),
    'resend_budget', (x.s).notify_resend_daily_budget,
    'resend_used', (select count(*) from notification_outbox o where o.sent_at >= app.local_midnight(app.local_date(now()))
                      and o.status in ('sent', 'sending') and coalesce(o.provider_id, '') not like 'cf:%' and coalesce(o.provider_id, '') not like 'ses:%'),
    'midnight', app.local_midnight(app.local_date(now()) + 1))
  from x
$$;

-- Settings > Usage and the booking page's email box: SES's day and which provider sends now
alter function app.email_pace(timestamptz) rename to email_pace_pre2570;
create function app.email_pace(p_now timestamptz default now()) returns jsonb
language sql stable security definer set search_path = public, app as $$
  select app.email_pace_pre2570(p_now) || jsonb_build_object(
    'ses_today', app.ses_emails_between(app.local_midnight(app.local_date(p_now)), p_now + interval '1 second'),
    'ses_day_budget', (select s.email_ses_daily_max from app.settings_base(app.local_date(p_now)) s),
    'ses_left', app.ses_email_left(p_now), 'ses_open', app.ses_email_try(p_now),
    'ses_error', (select e.ses_error from email_provider_state e where e.ses_failed_at > coalesce(e.ses_ok_at, '-infinity'::timestamptz) limit 1))
  || case when app.ses_email_try(p_now) then jsonb_build_object('limited_by', 'ses') else '{}'::jsonb end
$$;
select pg_temp.copy_grants('app.email_pace(timestamptz)'::regprocedure, 'app.email_pace_pre2570(timestamptz)'::regprocedure);

create or replace function app.email_capacity(p_now timestamptz default now()) returns jsonb
language sql stable security definer set search_path = public, app as $$
  select jsonb_build_object('capacity', app.email_day_cap(p_now),
    'limited_by', case when app.ses_email_try(p_now) then 'ses' when app.cf_email_try(p_now) then 'cloudflare' else 'resend' end,
    'cf_reason', app.email_cf_reason(p_now))
$$;

-- ================================================================ 5. grants
do $$
declare f record;
begin
  for f in
    select p.oid::regprocedure as sig from pg_proc p join pg_namespace n on n.oid = p.pronamespace
     where (n.nspname = 'app' and p.proname = any (array['ses_emails_between', 'ses_email_left', 'ses_email_try', 'server_ses_email_result',
              'outbox_note_ses_fallback', 'email_day_cap_pre2570', 'email_pace_pre2570', 'marketing_daily_max_pre2570']))
        or (n.nspname = 'public' and p.proname = any (array['server_ses_email_result', 'server_outbox_note_ses_fallback']))
  loop
    execute format('revoke all on function %s from public, anon, authenticated', f.sig);
    execute format('grant execute on function %s to service_role', f.sig);
  end loop;
end $$;

-- ================================================================ 6. the guide (Admin, Email, backups and site health: the Sent by column and SES)
-- generated by supabase/seed/2521_gen_guides.mjs from docs/guides/content/admin.json (this chapter only); published as 0059 does
select app.guide_release_section('admin', 'email-backups-and-site-health', 'chapter', 'maintenance-and-service', 'Keep an eye on email use against the daily limit, the nightly backup and the occasional error page.

## Email

**Settings** > **Logs**, the **Emails** tab

1. The banner shows today''s emails against the daily limit and why it is that number: Cloudflare Email Service''s budget counts only while it sends ("98 of 100 today: only Resend is sending (Cloudflare Email Service is not set up, which adds 200)"). The booking page''s Email the renter box and **Settings** > **Usage** say the same. From 80% of the limit, Admins get a notice; near it, digests and marketing wait first and booking and sign-in emails are held last.
2. Filter the Outbox: All, Queued, Held, Sent, Sent combined, Repeats held back, Failed or Skipped. The Why column says why an email was held back or combined.
3. Emails to the same person for the same booking queued within 2 minutes go as one email ("Update on your booking CC-10080: confirmed, receipt and agreement"), each with its own section, buttons and attachments; their texts go as one text. The same email to the same person for the same booking is not sent twice within 30 minutes; receipts, signed copies, staff messages and codes always go. Both times are in **Settings**, Program settings. Cancelled owner invoices go as one email per owner per day.
4. Open an email to **Resend** or **Cancel** it.
5. Suppressions: **Suppress an address** stops all mail to it; **Lift** undoes it.
6. **Text it instead** on a held or queued email sends it at once by text to the person''s mobile, with the link to their page. The email still goes when the limit lifts.

> Tip: When the limit is reached, booking and pickup emails (the confirmation, the agreement and signing links, pickup details, the handover, payment links and signing codes) go by text on their own, once each. Sign-in then opens on the phone option, and signing codes are offered by text first. Turn it off in **Settings**, then Site settings, Email limit.

![](/guides/img/admin-23-email-desktop-dad31712.jpg "desktop; size: 1440 760; address: carmacars.ca/admin/messages; pins: 1 56.5 31.7, 2 35.5 41.8, 3 81.9 52.6, 4 26.6 22.9")

## Backups

- The database is backed up every night, encrypted and test-restored on the spot. Kept: the last 7 nights and each Sunday of the last 4 weeks, with point-in-time recovery for the last week. Every night the retention keeps the backup storage under 70% of its free 10 GB.
- Every Monday the newest backup is checked again: it must be under 30 hours old and restore cleanly.
- A failed backup, or none for 30 hours, opens a site alert: an email (outside the quiet hours), a task and a line on To do. Tell your developer the same day.
- Keep a copy of the backup key in the company password manager. Without it no backup can be read.

## Site health and alerts

**Today** > **To do**, the Site health card at the bottom.

1. Every 5 minutes the site checks itself: the home page, a car page, the sign-in page and the site''s health check, and also emails, scheduled jobs, the nightly backup and Stripe payments.
2. Each line shows Working, Problem, Waiting for the website deploy or Not checked yet, what was found and how many checks failed in the last 24 hours.
3. Short problems, such as a single Error 1102, only show here and in your morning digest ("Site check: 6 failed checks in the last 24 hours, no alert email").
4. An email goes to rent@carmacars.ca only for a real outage: a page failing every check for 15 minutes, emails failing for 30 minutes, the nightly backup failing, or Stripe failing for 30 minutes. It also raises an urgent task and "Site problems found by the site check" first on To do. A failed scheduled job is never emailed.
5. At most 3 alert emails a day, and none from 11 pm to 7 am unless the whole site has been down for an hour. An outage held overnight is emailed at 7 am if it lasts. One "Recovered" email follows each alert, and the task closes by itself.
6. "Waiting for the website deploy" on the health check means the database was updated before the website: nothing is wrong, and it turns to Working after the deploy.

> Good to know: The alert address, the minutes before an email, the daily limit and the quiet hours are in Program settings, "Site check".

## When a page shows "Error 1102"

Our web host''s free plan sometimes stops a page that takes too long. Reload the page; you are still signed in. Moving to the Workers Paid plan removes it.

### Self-heal learns

Every 15 minutes self-heal checks the site, the server, email, the certificates, backups and the scheduled jobs. A known failure gets its known safe action (wait, a server reboot at most once in 6 hours, free backup space, re-run a failed job, start a backup) and no issue. An unknown one opens a GitHub issue labelled **self-heal**: when you close it, add a line like `self-heal: server_health => apply_retention` and self-heal does that next time. Every incident is in the GitHub issue labelled self-heal-ledger. It never runs SQL.', 'Email, backups and site health', 'The email outbox and daily limit, suppressions, backups, the site check and its alerts, and Error 1102.',
  'Keep an eye on email use against the daily limit, the nightly backup and the occasional error page.

## Email

**Settings** > **Logs**, the **Emails** tab

1. The banner shows today''s emails against the daily limit and why it is that number: Cloudflare Email Service''s budget counts only while it sends ("98 of 100 today: only Resend is sending (Cloudflare Email Service is not set up, which adds 200)"). The booking page''s Email the renter box and **Settings** > **Usage** say the same. From 80% of the limit, Admins get a notice; near it, digests and marketing wait first and booking and sign-in emails are held last.
2. Filter the Outbox: All, Queued, Held, Sent, Sent combined, Repeats held back, Failed or Skipped. The Why column says why an email was held back or combined, or which provider it went through after an Amazon SES refusal. The Sent by column says who sent each email: Amazon SES, Cloudflare or Resend.

> Tip: Amazon SES sends first once its keys are set (paid per use, approved by the owner). In **Settings**, Program settings, Email and notifications: turn it off, or raise the emails a day (200 while SES is in the sandbox) after AWS grants production access. Cloudflare and then Resend send the rest.
3. Emails to the same person for the same booking queued within 2 minutes go as one email ("Update on your booking CC-10080: confirmed, receipt and agreement"), each with its own section, buttons and attachments; their texts go as one text. The same email to the same person for the same booking is not sent twice within 30 minutes; receipts, signed copies, staff messages and codes always go. Both times are in **Settings**, Program settings. Cancelled owner invoices go as one email per owner per day.
4. Open an email to **Resend** or **Cancel** it.
5. Suppressions: **Suppress an address** stops all mail to it; **Lift** undoes it.
6. **Text it instead** on a held or queued email sends it at once by text to the person''s mobile, with the link to their page. The email still goes when the limit lifts.

> Tip: When the limit is reached, booking and pickup emails (the confirmation, the agreement and signing links, pickup details, the handover, payment links and signing codes) go by text on their own, once each. Sign-in then opens on the phone option, and signing codes are offered by text first. Turn it off in **Settings**, then Site settings, Email limit.

![](/guides/img/admin-23-email-desktop-dad31712.jpg "desktop; size: 1440 760; address: carmacars.ca/admin/messages; pins: 1 56.5 31.7, 2 35.5 41.8, 3 81.9 52.6, 4 26.6 22.9")

## Backups

- The database is backed up every night, encrypted and test-restored on the spot. Kept: the last 7 nights and each Sunday of the last 4 weeks, with point-in-time recovery for the last week. Every night the retention keeps the backup storage under 70% of its free 10 GB.
- Every Monday the newest backup is checked again: it must be under 30 hours old and restore cleanly.
- A failed backup, or none for 30 hours, opens a site alert: an email (outside the quiet hours), a task and a line on To do. Tell your developer the same day.
- Keep a copy of the backup key in the company password manager. Without it no backup can be read.

## Site health and alerts

**Today** > **To do**, the Site health card at the bottom.

1. Every 5 minutes the site checks itself: the home page, a car page, the sign-in page and the site''s health check, and also emails, scheduled jobs, the nightly backup and Stripe payments.
2. Each line shows Working, Problem, Waiting for the website deploy or Not checked yet, what was found and how many checks failed in the last 24 hours.
3. Short problems, such as a single Error 1102, only show here and in your morning digest ("Site check: 6 failed checks in the last 24 hours, no alert email").
4. An email goes to rent@carmacars.ca only for a real outage: a page failing every check for 15 minutes, emails failing for 30 minutes, the nightly backup failing, or Stripe failing for 30 minutes. It also raises an urgent task and "Site problems found by the site check" first on To do. A failed scheduled job is never emailed.
5. At most 3 alert emails a day, and none from 11 pm to 7 am unless the whole site has been down for an hour. An outage held overnight is emailed at 7 am if it lasts. One "Recovered" email follows each alert, and the task closes by itself.
6. "Waiting for the website deploy" on the health check means the database was updated before the website: nothing is wrong, and it turns to Working after the deploy.

> Good to know: The alert address, the minutes before an email, the daily limit and the quiet hours are in Program settings, "Site check".

## When a page shows "Error 1102"

Our web host''s free plan sometimes stops a page that takes too long. Reload the page; you are still signed in. Moving to the Workers Paid plan removes it.

### Self-heal learns

Every 15 minutes self-heal checks the site, the server, email, the certificates, backups and the scheduled jobs. A known failure gets its known safe action (wait, a server reboot at most once in 6 hours, free backup space, re-run a failed job, start a backup) and no issue. An unknown one opens a GitHub issue labelled **self-heal**: when you close it, add a line like `self-heal: server_health => apply_retention` and self-heal does that next time. Every incident is in the GitHub issue labelled self-heal-ledger. It never runs SQL.',
  '<p class="gd-p">Keep an eye on email use against the daily limit, the nightly backup and the occasional error page.</p><section class="gd-task" id="email-backups-and-site-health-email" data-gd-task><h2 class="gd-h2">Email</h2><p class="gd-p"><b class="gd-ui">Settings</b> &gt; <b class="gd-ui">Logs</b>, the <b class="gd-ui">Emails</b> tab</p><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">The banner shows today&#39;s emails against the daily limit and why it is that number: Cloudflare Email Service&#39;s budget counts only while it sends (&quot;98 of 100 today: only Resend is sending (Cloudflare Email Service is not set up, which adds 200)&quot;). The booking page&#39;s Email the renter box and <b class="gd-ui">Settings</b> &gt; <b class="gd-ui">Usage</b> say the same. From 80% of the limit, Admins get a notice; near it, digests and marketing wait first and booking and sign-in emails are held last.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Filter the Outbox: All, Queued, Held, Sent, Sent combined, Repeats held back, Failed or Skipped. The Why column says why an email was held back or combined, or which provider it went through after an Amazon SES refusal. The Sent by column says who sent each email: Amazon SES, Cloudflare or Resend.</div></li></ol></div><aside class="gd-box"><span class="gd-lbl">Tip</span><div>Amazon SES sends first once its keys are set (paid per use, approved by the owner). In <b class="gd-ui">Settings</b>, Program settings, Email and notifications: turn it off, or raise the emails a day (200 while SES is in the sandbox) after AWS grants production access. Cloudflare and then Resend send the rest.</div></aside><div class="gd-stepblock"><ol class="gd-ol" start="3"><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Emails to the same person for the same booking queued within 2 minutes go as one email (&quot;Update on your booking CC-10080: confirmed, receipt and agreement&quot;), each with its own section, buttons and attachments; their texts go as one text. The same email to the same person for the same booking is not sent twice within 30 minutes; receipts, signed copies, staff messages and codes always go. Both times are in <b class="gd-ui">Settings</b>, Program settings. Cancelled owner invoices go as one email per owner per day.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t">Open an email to <b class="gd-ui">Resend</b> or <b class="gd-ui">Cancel</b> it.</div></li><li><span class="gd-n" aria-hidden="true">5</span><div class="gd-t">Suppressions: <b class="gd-ui">Suppress an address</b> stops all mail to it; <b class="gd-ui">Lift</b> undoes it.</div></li><li><span class="gd-n" aria-hidden="true">6</span><div class="gd-t"><b class="gd-ui">Text it instead</b> on a held or queued email sends it at once by text to the person&#39;s mobile, with the link to their page. The email still goes when the limit lifts.</div></li></ol></div><aside class="gd-box"><span class="gd-lbl">Tip</span><div>When the limit is reached, booking and pickup emails (the confirmation, the agreement and signing links, pickup details, the handover, payment links and signing codes) go by text on their own, once each. Sign-in then opens on the phone option, and signing codes are offered by text first. Turn it off in <b class="gd-ui">Settings</b>, then Site settings, Email limit.</div></aside><div class="gd-figblock"><figure class="gd-fig gd-fig--desk"><div class="gd-browser"><div class="gd-bar" aria-hidden="true"><i></i><i></i><i></i><span class="gd-addr">carmacars.ca/admin/messages</span></div><div class="gd-imgwrap" style="aspect-ratio:1440/760"><img src="/guides/img/admin-23-email-desktop-dad31712.jpg" alt="" loading="lazy" decoding="async" width="1440" height="760"><span class="gd-pin" style="left:56.5%;top:31.7%" aria-hidden="true">1</span><span class="gd-pin" style="left:35.5%;top:41.8%" aria-hidden="true">2</span><span class="gd-pin" style="left:81.9%;top:52.6%" aria-hidden="true">3</span><span class="gd-pin" style="left:26.6%;top:22.9%" aria-hidden="true">4</span></div></div></figure></div></section><section class="gd-task" id="email-backups-and-site-health-backups" data-gd-task><h2 class="gd-h2">Backups</h2><ul class="gd-ul"><li>The database is backed up every night, encrypted and test-restored on the spot. Kept: the last 7 nights and each Sunday of the last 4 weeks, with point-in-time recovery for the last week. Every night the retention keeps the backup storage under 70% of its free 10 GB.</li><li>Every Monday the newest backup is checked again: it must be under 30 hours old and restore cleanly.</li><li>A failed backup, or none for 30 hours, opens a site alert: an email (outside the quiet hours), a task and a line on To do. Tell your developer the same day.</li><li>Keep a copy of the backup key in the company password manager. Without it no backup can be read.</li></ul></section><section class="gd-task" id="email-backups-and-site-health-site-health-and-alerts" data-gd-task><h2 class="gd-h2">Site health and alerts</h2><p class="gd-p"><b class="gd-ui">Today</b> &gt; <b class="gd-ui">To do</b>, the Site health card at the bottom.</p><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">Every 5 minutes the site checks itself: the home page, a car page, the sign-in page and the site&#39;s health check, and also emails, scheduled jobs, the nightly backup and Stripe payments.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Each line shows Working, Problem, Waiting for the website deploy or Not checked yet, what was found and how many checks failed in the last 24 hours.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Short problems, such as a single Error 1102, only show here and in your morning digest (&quot;Site check: 6 failed checks in the last 24 hours, no alert email&quot;).</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t">An email goes to rent@carmacars.ca only for a real outage: a page failing every check for 15 minutes, emails failing for 30 minutes, the nightly backup failing, or Stripe failing for 30 minutes. It also raises an urgent task and &quot;Site problems found by the site check&quot; first on To do. A failed scheduled job is never emailed.</div></li><li><span class="gd-n" aria-hidden="true">5</span><div class="gd-t">At most 3 alert emails a day, and none from 11 pm to 7 am unless the whole site has been down for an hour. An outage held overnight is emailed at 7 am if it lasts. One &quot;Recovered&quot; email follows each alert, and the task closes by itself.</div></li><li><span class="gd-n" aria-hidden="true">6</span><div class="gd-t">&quot;Waiting for the website deploy&quot; on the health check means the database was updated before the website: nothing is wrong, and it turns to Working after the deploy.</div></li></ol></div><aside class="gd-box"><span class="gd-lbl">Good to know</span><div>The alert address, the minutes before an email, the daily limit and the quiet hours are in Program settings, &quot;Site check&quot;.</div></aside></section><section class="gd-task" id="email-backups-and-site-health-when-a-page-shows-error-1102" data-gd-task><h2 class="gd-h2">When a page shows &quot;Error 1102&quot;</h2><p class="gd-p">Our web host&#39;s free plan sometimes stops a page that takes too long. Reload the page; you are still signed in. Moving to the Workers Paid plan removes it.</p><h3 class="gd-h3">Self-heal learns</h3><p class="gd-p">Every 15 minutes self-heal checks the site, the server, email, the certificates, backups and the scheduled jobs. A known failure gets its known safe action (wait, a server reboot at most once in 6 hours, free backup space, re-run a failed job, start a backup) and no issue. An unknown one opens a GitHub issue labelled <b class="gd-ui">self-heal</b>: when you close it, add a line like <span class="gd-url">self-heal: server_health =&gt; apply_retention</span> and self-heal does that next time. Every incident is in the GitHub issue labelled self-heal-ledger. It never runs SQL.</p></section>');
