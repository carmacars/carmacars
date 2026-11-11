-- 2253: when Cloudflare's last answer since its last success said the Worker has no EMAIL binding, Cloudflare cannot send, so
-- the day's email capacity is Resend's alone (the rule 0900 set and its test checks); otherwise as 1750: what Cloudflare
-- sent today, what is left of its day, then Resend's day.
create or replace function app.email_day_cap(p_now timestamptz default now()) returns integer
language sql stable security definer set search_path = public, app as $$
  select (case when exists (select 1 from email_provider_state e where e.cf_error ilike '%binding%' and e.cf_failed_at > coalesce(e.cf_ok_at, '-infinity'::timestamptz)) then 0
               else app.cf_emails_between(app.local_midnight(app.local_date(p_now)), p_now + interval '1 second') + app.cf_email_left(p_now) end
          + greatest(0, least(s.notify_daily_cap, s.notify_resend_daily_budget)))::integer
    from app.settings_base(app.local_date(p_now)) s
$$;
