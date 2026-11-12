-- 2600_r41_email_route.sql
-- Release 41 (docs/changes/2026-11-12-r41-email-route.md). The owner (November 12, 2026): "We're stopping paying for
-- Cloudflare; every email goes through Amazon; cancel Resend", then, told that SES forbids unsolicited marketing: "keep a
-- free marketing sender". The rule:
--   1. Transactional and system email (every category but 'marketing'): Amazon SES first; when SES is not set up, is resting
--      or refuses that email, Resend's free plan sends it (never a paid plan). Cloudflare Email is not used.
--   2. Marketing email: Resend's free plan only (never SES unless email_ses_marketing, off; never Cloudflare). The day's
--      marketing allowance is Resend's free capacity of the day less what transactional email already used of it through
--      the fallback (app.marketing_daily_max); never a paid plan.
--   3. Program setting email_cloudflare_enabled (off by default) switches Cloudflare sending off: the database sees no
--      Cloudflare budget (app.cf_email_left is 0, so the claim, the day's capacity and the sender's budgets leave it out) and
--      the banner says so. The code path stays for now; the whole site leaves Cloudflare in a later release.
-- 2570 is not edited; its functions are wrapped (renamed _pre2600).
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

-- ================================================================ 1. settings
alter table program_settings add column if not exists email_cloudflare_enabled boolean not null default false;
comment on column program_settings.email_cloudflare_enabled is 'Cloudflare Email Service may send (2600). Off (default): no email goes through Cloudflare; booking and system email go through Amazon SES, then Resend''s free plan, and marketing through Resend''s free plan.';
comment on column program_settings.email_ses_enabled is 'Send booking, payment, sign-in, staff and owner email through Amazon SES first when its keys are set (2570, 2600); Resend''s free plan sends what SES cannot. SES is paid per use (owner approved).';
comment on column program_settings.email_ses_marketing is 'Marketing emails may go through Amazon SES too (2570). Off (default, 2600): marketing goes through Resend''s free plan only; SES production access is for transactional email.';

-- ================================================================ 2. Cloudflare off
alter function app.cf_email_left(timestamptz) rename to cf_email_left_pre2600;
create function app.cf_email_left(p_now timestamptz default now()) returns integer
language sql stable security definer set search_path = public, app as $$
  select case when coalesce((select s.email_cloudflare_enabled from app.settings_base(app.local_date(p_now)) s), false)
              then app.cf_email_left_pre2600(p_now) else 0 end::integer
$$;
select pg_temp.copy_grants('app.cf_email_left(timestamptz)'::regprocedure, 'app.cf_email_left_pre2600(timestamptz)'::regprocedure);

-- the banner (Settings > Usage, Logs > Emails): Cloudflare reads as off, with the owner's reason
alter function app.cf_email_setup(timestamptz) rename to cf_email_setup_pre2600;
create function app.cf_email_setup(p_now timestamptz default now()) returns jsonb
language sql stable security definer set search_path = public, app as $$
  select case when coalesce((select s.email_cloudflare_enabled from app.settings_base(app.local_date(p_now)) s), false)
              then app.cf_email_setup_pre2600(p_now)
              else app.cf_email_setup_pre2600(p_now) || jsonb_build_object('state', 'off', 'enabled', false,
                     'reason', 'Cloudflare Email Service is turned off in Program settings (Cloudflare email): booking and system email go through Amazon SES, then Resend''s free plan, and marketing through Resend''s free plan') end
$$;
select pg_temp.copy_grants('app.cf_email_setup(timestamptz)'::regprocedure, 'app.cf_email_setup_pre2600(timestamptz)'::regprocedure);

-- ================================================================ 3. the marketing allowance: Resend's free capacity
alter function app.marketing_daily_max(timestamptz) rename to marketing_daily_max_pre2600;
create function app.marketing_daily_max(p_now timestamptz default now()) returns integer
language sql stable security definer set search_path = public, app as $$
  with v as (
    select s,
           greatest(0, least(s.notify_daily_cap, s.notify_resend_daily_budget)) resend_cap,
           -- what transactional email already used of Resend's day (the fallback after SES), so marketing gets the rest
           (select count(*)::integer from notification_outbox o
             where o.status in ('sent', 'sending') and o.category <> 'marketing' and o.sent_at >= app.local_midnight(app.local_date(p_now))
               and coalesce(o.provider_id, '') not like 'cf:%' and coalesce(o.provider_id, '') not like 'ses:%') trans_used,
           app.ses_emails_between(app.local_midnight(app.local_date(p_now)), p_now + interval '1 second') + app.ses_email_left(p_now) ses_day
      from app.settings(app.local_date(p_now)) s)
  select case when not (v.s).marketing_auto_volume then (v.s).notify_marketing_daily_max
              else greatest(0, v.resend_cap - v.trans_used) + case when coalesce((v.s).email_ses_marketing, false) then v.ses_day else 0 end end::integer
    from v
$$;
select pg_temp.copy_grants('app.marketing_daily_max(timestamptz)'::regprocedure, 'app.marketing_daily_max_pre2600(timestamptz)'::regprocedure);

-- ================================================================ 4. grants
do $$
declare f record;
begin
  for f in
    select p.oid::regprocedure as sig from pg_proc p join pg_namespace n on n.oid = p.pronamespace
     where n.nspname = 'app' and p.proname = any (array['cf_email_left_pre2600', 'cf_email_setup_pre2600', 'marketing_daily_max_pre2600'])
  loop
    execute format('revoke all on function %s from public, anon, authenticated', f.sig);
    execute format('grant execute on function %s to service_role', f.sig);
  end loop;
end $$;

-- ================================================================ 5. the guide (Admin, Email, backups and site health: who sends what)
-- generated from docs/guides/content/admin.json (this chapter only); published as 0059 does
select app.guide_release_section('admin', 'email-backups-and-site-health', 'chapter', 'maintenance-and-service', 'Keep an eye on email use against the daily limit, the nightly backup and the occasional error page.

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

Every 15 minutes self-heal checks the site, the server, email, the certificates, backups and the scheduled jobs. A known failure gets its known safe action (wait, a server reboot at most once in 6 hours, free backup space, re-run a failed job, start a backup) and no issue. An unknown one opens a GitHub issue labelled **self-heal**: when you close it, add a line like `self-heal: server_health => apply_retention` and self-heal does that next time. Every incident is in the GitHub issue labelled self-heal-ledger. It never runs SQL.', 'Email, backups and site health', 'The email outbox and daily limit, suppressions, backups, the site check and its alerts, and Error 1102.',
  'Keep an eye on email use against the daily limit, the nightly backup and the occasional error page.

## Email

**Settings** > **Logs**, the **Emails** tab

1. The banner shows today''s emails against the daily limit and why it is that number: Amazon SES''s day counts only while it sends, and Resend''s free plan carries marketing and anything SES refuses ("98 of 300 today: Amazon SES sends booking and system email, Resend the marketing"). The booking page''s Email the renter box and **Settings** > **Usage** say the same. From 80% of the limit, Admins get a notice; near it, digests and marketing wait first and booking and sign-in emails are held last.
2. Filter the Outbox: All, Queued, Held, Sent, Sent combined, Repeats held back, Failed or Skipped. The Why column says why an email was held back or combined, or that Resend sent it after an Amazon SES refusal. The Sent by column says who sent each email: Amazon SES or Resend.

> Tip: Booking, payment, sign-in, staff and owner email go through Amazon SES first once its keys are set (paid per use, approved by the owner); if SES is not set up or refuses an email, Resend''s free plan sends it. Marketing email goes through Resend''s free plan only, within what is left of its day after those fallbacks, and never through a paid plan. Cloudflare Email is switched off. In **Settings**, Program settings, Email and notifications: turn SES off, or raise the emails a day (200 while SES is in the sandbox) after AWS grants production access.
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
  '<p class="gd-p">Keep an eye on email use against the daily limit, the nightly backup and the occasional error page.</p><section class="gd-task" id="email-backups-and-site-health-email" data-gd-task><h2 class="gd-h2">Email</h2><p class="gd-p"><b class="gd-ui">Settings</b> &gt; <b class="gd-ui">Logs</b>, the <b class="gd-ui">Emails</b> tab</p><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">The banner shows today&#39;s emails against the daily limit and why it is that number: Amazon SES&#39;s day counts only while it sends, and Resend&#39;s free plan carries marketing and anything SES refuses (&quot;98 of 300 today: Amazon SES sends booking and system email, Resend the marketing&quot;). The booking page&#39;s Email the renter box and <b class="gd-ui">Settings</b> &gt; <b class="gd-ui">Usage</b> say the same. From 80% of the limit, Admins get a notice; near it, digests and marketing wait first and booking and sign-in emails are held last.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Filter the Outbox: All, Queued, Held, Sent, Sent combined, Repeats held back, Failed or Skipped. The Why column says why an email was held back or combined, or that Resend sent it after an Amazon SES refusal. The Sent by column says who sent each email: Amazon SES or Resend.</div></li></ol></div><aside class="gd-box"><span class="gd-lbl">Tip</span><div>Booking, payment, sign-in, staff and owner email go through Amazon SES first once its keys are set (paid per use, approved by the owner); if SES is not set up or refuses an email, Resend&#39;s free plan sends it. Marketing email goes through Resend&#39;s free plan only, within what is left of its day after those fallbacks, and never through a paid plan. Cloudflare Email is switched off. In <b class="gd-ui">Settings</b>, Program settings, Email and notifications: turn SES off, or raise the emails a day (200 while SES is in the sandbox) after AWS grants production access.</div></aside><div class="gd-stepblock"><ol class="gd-ol" start="3"><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Emails to the same person for the same booking queued within 2 minutes go as one email (&quot;Update on your booking CC-10080: confirmed, receipt and agreement&quot;), each with its own section, buttons and attachments; their texts go as one text. The same email to the same person for the same booking is not sent twice within 30 minutes; receipts, signed copies, staff messages and codes always go. Both times are in <b class="gd-ui">Settings</b>, Program settings. Cancelled owner invoices go as one email per owner per day.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t">Open an email to <b class="gd-ui">Resend</b> or <b class="gd-ui">Cancel</b> it.</div></li><li><span class="gd-n" aria-hidden="true">5</span><div class="gd-t">Suppressions: <b class="gd-ui">Suppress an address</b> stops all mail to it; <b class="gd-ui">Lift</b> undoes it.</div></li><li><span class="gd-n" aria-hidden="true">6</span><div class="gd-t"><b class="gd-ui">Text it instead</b> on a held or queued email sends it at once by text to the person&#39;s mobile, with the link to their page. The email still goes when the limit lifts.</div></li></ol></div><aside class="gd-box"><span class="gd-lbl">Tip</span><div>When the limit is reached, booking and pickup emails (the confirmation, the agreement and signing links, pickup details, the handover, payment links and signing codes) go by text on their own, once each. Sign-in then opens on the phone option, and signing codes are offered by text first. Turn it off in <b class="gd-ui">Settings</b>, then Site settings, Email limit.</div></aside><div class="gd-figblock"><figure class="gd-fig gd-fig--desk"><div class="gd-browser"><div class="gd-bar" aria-hidden="true"><i></i><i></i><i></i><span class="gd-addr">carmacars.ca/admin/messages</span></div><div class="gd-imgwrap" style="aspect-ratio:1440/760"><img src="/guides/img/admin-23-email-desktop-dad31712.jpg" alt="" loading="lazy" decoding="async" width="1440" height="760"><span class="gd-pin" style="left:56.5%;top:31.7%" aria-hidden="true">1</span><span class="gd-pin" style="left:35.5%;top:41.8%" aria-hidden="true">2</span><span class="gd-pin" style="left:81.9%;top:52.6%" aria-hidden="true">3</span><span class="gd-pin" style="left:26.6%;top:22.9%" aria-hidden="true">4</span></div></div></figure></div></section><section class="gd-task" id="email-backups-and-site-health-backups" data-gd-task><h2 class="gd-h2">Backups</h2><ul class="gd-ul"><li>The database is backed up every night, encrypted and test-restored on the spot. Kept: the last 7 nights and each Sunday of the last 4 weeks, with point-in-time recovery for the last week. Every night the retention keeps the backup storage under 70% of its free 10 GB.</li><li>Every Monday the newest backup is checked again: it must be under 30 hours old and restore cleanly.</li><li>A failed backup, or none for 30 hours, opens a site alert: an email (outside the quiet hours), a task and a line on To do. Tell your developer the same day.</li><li>Keep a copy of the backup key in the company password manager. Without it no backup can be read.</li></ul></section><section class="gd-task" id="email-backups-and-site-health-site-health-and-alerts" data-gd-task><h2 class="gd-h2">Site health and alerts</h2><p class="gd-p"><b class="gd-ui">Today</b> &gt; <b class="gd-ui">To do</b>, the Site health card at the bottom.</p><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">Every 5 minutes the site checks itself: the home page, a car page, the sign-in page and the site&#39;s health check, and also emails, scheduled jobs, the nightly backup and Stripe payments.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Each line shows Working, Problem, Waiting for the website deploy or Not checked yet, what was found and how many checks failed in the last 24 hours.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Short problems, such as a single Error 1102, only show here and in your morning digest (&quot;Site check: 6 failed checks in the last 24 hours, no alert email&quot;).</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t">An email goes to rent@carmacars.ca only for a real outage: a page failing every check for 15 minutes, emails failing for 30 minutes, the nightly backup failing, or Stripe failing for 30 minutes. It also raises an urgent task and &quot;Site problems found by the site check&quot; first on To do. A failed scheduled job is never emailed.</div></li><li><span class="gd-n" aria-hidden="true">5</span><div class="gd-t">At most 3 alert emails a day, and none from 11 pm to 7 am unless the whole site has been down for an hour. An outage held overnight is emailed at 7 am if it lasts. One &quot;Recovered&quot; email follows each alert, and the task closes by itself.</div></li><li><span class="gd-n" aria-hidden="true">6</span><div class="gd-t">&quot;Waiting for the website deploy&quot; on the health check means the database was updated before the website: nothing is wrong, and it turns to Working after the deploy.</div></li></ol></div><aside class="gd-box"><span class="gd-lbl">Good to know</span><div>The alert address, the minutes before an email, the daily limit and the quiet hours are in Program settings, &quot;Site check&quot;.</div></aside></section><section class="gd-task" id="email-backups-and-site-health-when-a-page-shows-error-1102" data-gd-task><h2 class="gd-h2">When a page shows &quot;Error 1102&quot;</h2><p class="gd-p">Our web host&#39;s free plan sometimes stops a page that takes too long. Reload the page; you are still signed in. Moving to the Workers Paid plan removes it.</p><h3 class="gd-h3">Self-heal learns</h3><p class="gd-p">Every 15 minutes self-heal checks the site, the server, email, the certificates, backups and the scheduled jobs. A known failure gets its known safe action (wait, a server reboot at most once in 6 hours, free backup space, re-run a failed job, start a backup) and no issue. An unknown one opens a GitHub issue labelled <b class="gd-ui">self-heal</b>: when you close it, add a line like <span class="gd-url">self-heal: server_health =&gt; apply_retention</span> and self-heal does that next time. Every incident is in the GitHub issue labelled self-heal-ledger. It never runs SQL.</p></section>');
