-- 2253: when the site's Worker has no Cloudflare EMAIL binding (cf_email_setup state 'absent'), Cloudflare cannot send, so
-- the day's email capacity is Resend's alone (the rule 0900 set and its test checks); otherwise as 1750: what Cloudflare
-- sent today, what is left of its day, then Resend's day.
create or replace function app.email_day_cap(p_now timestamptz default now()) returns integer
language sql stable security definer set search_path = public, app as $$
  select (case when (app.cf_email_setup(p_now) ->> 'state') = 'absent' then 0
               else app.cf_emails_between(app.local_midnight(app.local_date(p_now)), p_now + interval '1 second') + app.cf_email_left(p_now) end
          + greatest(0, least(s.notify_daily_cap, s.notify_resend_daily_budget)))::integer
    from app.settings_base(app.local_date(p_now)) s
$$;
