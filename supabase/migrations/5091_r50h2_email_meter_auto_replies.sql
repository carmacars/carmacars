-- 5091 (R50 hotfix 2, comms; tests: supabase/tests/99_r50h2_email_meter_auto_replies.sql). SCHEMA_MARKER 5091.
-- 1. False "almost out of email" warnings while Amazon SES sends (owner, Nov 27). app.email_usage (0043) compared every
--    email of the day, SES's included, with Resend's free 100 (notify_daily_cap): past 80 sends it warned (Admin > Logs >
--    Emails, Admin > Today) and past 100 app.email_capped (0212) said email was capped, so the sign-in page and the signing
--    codes switched to texts and held booking emails were texted. The month test of app.email_capped counted SES too
--    against Resend's 3,000. Now the day's limit is the whole day's capacity (app.email_day_cap: SES, Cloudflare and
--    Resend, 2570), the month test counts Resend's emails only, and the portal warning "Email use is at N% of today's
--    limit" (Resend's count) stays quiet while SES sends, as it already did while Cloudflare sends (1750).
-- 2. AI auto-replies stopped on texts, email, WhatsApp, Messenger and Instagram (owner, Nov 27; every auto_reply_* on).
--    public.server_auto_reply_gate (2110) still refused when Workers AI's live share of the day was under 400 neurons,
--    while every other AI gate lets a free provider answer once that share is used (app.ai_allow, 3095: the server's own
--    model, or Gemini for what is not private). The live share is used most days by the photo and copy work, so every
--    question was skipped ("the free Workers AI allowance of the day is used"). The gate now asks app.ai_allow('faq_reply').
-- No applied migration is edited: functions are replaced with the same signatures (grants kept) or patched in place.
set local check_function_bodies = off;

create function pg_temp.patch_fn(p_sig regprocedure, p_old text, p_new text) returns void
language plpgsql as $$
declare d text := pg_get_functiondef(p_sig);
begin
  if position(p_old in d) = 0 then raise exception '5091: the text to change was not found in %: %', p_sig, left(p_old, 160); end if;
  execute replace(d, p_old, p_new);
end $$;

-- ================================================================ 1. the email meter counts SES as capacity
select pg_temp.patch_fn('app.email_usage(timestamptz)'::regprocedure,
  $o$'cap', s.notify_daily_cap, 'warn_at', ceil(s.notify_daily_cap * s.notify_cap_warn_bps / 10000.0)::integer,$o$,
  $n$'cap', greatest(s.notify_daily_cap, app.email_day_cap(p_now)), 'warn_at', ceil(greatest(s.notify_daily_cap, app.email_day_cap(p_now)) * s.notify_cap_warn_bps / 10000.0)::integer,$n$);

select pg_temp.patch_fn('app.email_capped(timestamptz)'::regprocedure,
  $o$or (select count(*) from notification_outbox o where o.status = 'sent' and o.sent_at >= app.local_midnight(app.month_start(app.local_date(p_now)))) >= s.notify_monthly_cap$o$,
  $n$or (select count(*) from notification_outbox o where o.status = 'sent' and o.sent_at >= app.local_midnight(app.month_start(app.local_date(p_now)))
            and coalesce(o.provider_id, '') not like 'cf:%' and coalesce(o.provider_id, '') not like 'ses:%') >= s.notify_monthly_cap$n$);

select pg_temp.patch_fn('app.outbox_claim_pre0530(integer, timestamptz)'::regprocedure,
  $o$if v_used >= v_warn and not app.cf_email_try(p_now) then$o$,
  $n$if v_used >= v_warn and not app.cf_email_try(p_now) and not app.ses_email_try(p_now) then$n$);

-- ================================================================ 2. auto-replies: any free AI provider may answer
select pg_temp.patch_fn('public.server_auto_reply_gate(jsonb)'::regprocedure,
  $o$  v_b := app.ai_budget();
  if v_b is null or coalesce((v_b ->> 'paused')::boolean, false) or coalesce((v_b #>> '{room,live}')::numeric, 0) < 400 then$o$,
  $n$  -- 5091: Workers AI's live share, or a free provider when that share is used (app.ai_allow, 3095)
  v_b := app.ai_allow('faq_reply', 400);
  if v_b is null or not coalesce((v_b ->> 'ok')::boolean, false) then$n$);
