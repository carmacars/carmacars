-- 0432: the Nov 6 production hotfix (docs/changes/2026-11-06-hotfix-load-email.md)
--   1. the email backlog: transactional first (hiring included), old reminders and marketing expire, the low classes are
--      paced across the day so a midnight backlog cannot spend the day's quota
--   2. website and job error alerts go to the in-app notices and the morning digest, one line per fingerprint

-- ================================================================ 1. the email outbox
-- 2.1 reminders are not first: a queued reminder (not a hiring one) is a priority 4 email like the digests
-- 2.2 a reminder, digest or marketing email still waiting 48 hours after it was due is skipped, not sent late
-- 2.3 pacing: those low classes may take at most half of the day's cap, released with the clock (a few at once at the
--     start of the day), so the rest of the cap stays for customer, owner and hiring emails
-- The claim itself (priority order, class limits, the daily and monthly caps) is the one of 0018 to 0043.
alter function app.outbox_claim(integer, timestamptz) rename to outbox_claim_0432;

create or replace function app.outbox_claim(p_limit integer default 20, p_now timestamptz default now())
returns table (id uuid, code text, category text, to_address text, to_name text, from_address text, reply_to text,
               subject text, payload jsonb, attempts integer, unsubscribe_url text, template_html text, template_text text)
language plpgsql security definer set search_path = public, app as $$
declare
  s program_settings := app.settings(app.local_date(p_now));
  v_from timestamptz := app.local_midnight(app.local_date(p_now));
  v_frac numeric := least(1, greatest(0, extract(epoch from (p_now - v_from)) / 86400.0));
  v_allow integer := ceil(s.notify_daily_cap * 0.5 * least(1, v_frac + 0.04))::integer;
  v_used integer;
  v_free integer;
  v_prio integer;
  r record;
begin
  update notification_outbox o set priority = 4
   where o.status in ('queued', 'delayed') and o.priority < 4 and o.audience not like 'staff\_%'
     and o.code like '%\_reminder%' and o.code not like 'applicant\_%';
  update notification_outbox o set status = 'skipped', status_reason = 'expired: still waiting 48 hours after it was due'
   where o.status in ('queued', 'delayed') and o.send_after < p_now - interval '48 hours'
     and (o.category = 'marketing' or o.priority >= 4 or o.code like '%\_reminder%');
  select count(*)::integer into v_used from notification_outbox o
   where (o.category = 'marketing' or o.priority >= 4) and ((o.status = 'sent' and o.sent_at >= v_from) or (o.status = 'sending' and o.locked_at >= p_now - make_interval(mins => s.notify_sending_lock_minutes)));
  v_free := greatest(v_allow - v_used, 0);
  -- the claim of 0018 to 0043 decides what may go (caps, class limits, marketing hours); the low classes it hands back
  -- beyond today's pace are put back for 30 minutes, attempts untouched
  for r in select * from app.outbox_claim_0432(p_limit, p_now) loop
    select o.priority into v_prio from notification_outbox o where o.id = r.id;
    if (r.category = 'marketing' or v_prio >= 4) and v_free <= 0 then
      update notification_outbox o set status = 'delayed', status_reason = 'paced across the day', attempts = greatest(o.attempts - 1, 0),
             locked_at = null, send_after = p_now + interval '30 minutes' where o.id = r.id;
      continue;
    end if;
    if r.category = 'marketing' or v_prio >= 4 then v_free := v_free - 1; end if;
    id := r.id; code := r.code; category := r.category; to_address := r.to_address; to_name := r.to_name; from_address := r.from_address;
    reply_to := r.reply_to; subject := r.subject; payload := r.payload; attempts := r.attempts; unsubscribe_url := r.unsubscribe_url;
    template_html := r.template_html; template_text := r.template_text;
    return next;
  end loop;
end $$;
revoke all on function app.outbox_claim(integer, timestamptz), app.outbox_claim_0432(integer, timestamptz) from public, anon, authenticated;
grant execute on function app.outbox_claim(integer, timestamptz), app.outbox_claim_0432(integer, timestamptz) to service_role;

-- ================================================================ 2. error alerts: in-app and one digest line each
-- The site check's alerts and recoveries, a failed job and a usage alert are no longer emailed one by one: the admins get
-- the in-app notice (and the push of 0300) at once and one line each in the morning digest. A line already waiting in
-- the digest with the same text (the fingerprint) is not added again.
update notification_catalogue
   set is_digest = true, digest_slot = 'morning',
       trigger_text = trigger_text || ' Migration 0432: not emailed one by one; the admins get the in-app notice at once and one line in the morning digest (the same line is added once).',
       updated_at = now()
 where code in ('staff_site_alert', 'staff_site_recovered', 'staff_job_failed', 'staff_usage_alert');

create or replace function app.digest_fingerprint() returns trigger
language plpgsql security definer set search_path = public, app as $$
begin
  if new.code in ('staff_site_alert', 'staff_site_recovered', 'staff_job_failed', 'staff_usage_alert')
     and exists (select 1 from staff_digest_items d
                  where d.role = new.role and d.code = new.code and d.digested_at is null and md5(d.line) = md5(new.line)) then
    return null;
  end if;
  return new;
end $$;
drop trigger if exists staff_digest_items_fingerprint on staff_digest_items;
create trigger staff_digest_items_fingerprint before insert on staff_digest_items for each row execute function app.digest_fingerprint();
