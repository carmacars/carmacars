-- 0601_outbox_stale.sql
-- Release 30 follow-up (docs/changes/2026-11-07-outbox-stale.md): the owner, November 7: the email backlog is about a
-- week old. An email still waiting (queued or delayed) that is too old for what it says is skipped with status_reason
-- 'stale: <age>' (or what made it stale), never sent:
--   * staff and Admin alerts (audience staff_%, the digests): older than 12 hours. They are in the in-app notices.
--   * customer, owner, investor, hiring and partner emails tied to an event: as soon as the event is no longer current
--     (an offer that is not open any more, a pickup or return reminder after that time, a payment asked for that is paid,
--     an interview invitation after the link expired); otherwise older than 72 hours.
--   * records always go: receipts, signed agreements and copies, statements, invoices, payouts and refunds.
-- The rule runs in the claim (every send) and once here on the backlog; the deploy prints the counts skipped as stale in
-- the last day by audience and code (scripts/deploy/outbox-stale.sh, counts only).

create function pg_temp.copy_grants(p_new regprocedure, p_old regprocedure) returns void
language plpgsql as $$
declare g text;
begin
  execute format('revoke all on function %s from public, anon, authenticated', p_new);
  foreach g in array array['anon', 'authenticated', 'service_role'] loop
    if has_function_privilege(g, p_old, 'execute') then execute format('grant execute on function %s to %I', p_new, g); end if;
  end loop;
end $$;

-- a record: always sent, whatever its age
create or replace function app.outbox_is_record(p_code text) returns boolean
language sql immutable as $$
  select p_code ~ '(receipt|statement|agreement_signed|signed_copy|invoice|payout_sent|refund_issued|payment_recorded|payment_received|return_paid|pad_confirmed|exit_completed|chat_transcript)'
$$;

-- the age in plain words: hours under two days, days after
create or replace function app.outbox_age_words(p interval) returns text
language sql immutable as $$
  select case when p < interval '48 hours' then floor(extract(epoch from p) / 3600)::int || ' hours'
              else floor(extract(epoch from p) / 86400)::int || ' days' end
$$;

-- why a waiting email is stale now (null: it may still go)
create or replace function app.outbox_stale_reason(o notification_outbox, p_now timestamptz default now()) returns text
language plpgsql stable security definer set search_path = public, app as $$
declare
  -- a claim played at another time (the tests' future days) never ages an email: the clock is the earlier of the two
  v_now timestamptz := least(p_now, now());
  v_age interval := least(p_now, now()) - o.created_at;
  b bookings;
  v_iv ai_interviews;
begin
  if o.status not in ('queued', 'delayed') then return null; end if;
  if app.outbox_is_record(o.code) then return null; end if;
  if o.audience like 'staff\_%' then
    return case when v_age > interval '12 hours' then 'stale: ' || app.outbox_age_words(v_age) end;
  end if;
  if o.booking_id is not null then
    select * into b from bookings where id = o.booking_id;
    if b.id is not null then
      if o.code in ('renter_offer_ready', 'renter_offer_reminder') and b.status::text <> 'offered' then return 'stale: the offer is no longer open'; end if;
      if o.code in ('renter_pickup_soon', 'renter_pickup_details', 'renter_booking_reminder', 'renter_identity_needed', 'renter_coverage_needed', 'renter_driver_link')
         and b.pickup_at < v_now then return 'stale: after the pickup time'; end if;
      if o.code in ('renter_return_soon', 'renter_return_reminder', 'renter_return_due', 'renter_late_return_first', 'renter_late_return_final')
         and (b.return_at < v_now - interval '1 day' or b.status::text not in ('on_rent', 'confirmed')) then return 'stale: after the return'; end if;
      if o.code in ('renter_balance_overdue', 'renter_payment_failed', 'renter_recovery_pay')
         and coalesce(app.booking_part_open(b.id, 'rental'), 0) + coalesce(app.booking_part_open(b.id, 'fees'), 0) <= 0 then return 'stale: already paid'; end if;
    end if;
  end if;
  if o.code in ('applicant_ai_interview', 'applicant_ai_interview_sorry') then
    select i.* into v_iv from ai_interviews i join job_applications a on a.id = i.application_id
     where lower(a.email) = lower(o.to_address) order by i.sent_at desc nulls last limit 1;
    if v_iv.id is not null and (v_iv.expires_at <= v_now or v_iv.state not in ('sent', 'started')) then return 'stale: the interview link expired'; end if;
  end if;
  return case when v_age > interval '72 hours' then 'stale: ' || app.outbox_age_words(v_age) end;
end $$;

-- skip every waiting email that is stale now; the count
create or replace function app.outbox_skip_stale(p_now timestamptz default now()) returns integer
language plpgsql security definer set search_path = public, app as $$
declare v integer;
begin
  with s as (select o.id, app.outbox_stale_reason(o, p_now) as why from notification_outbox o where o.status in ('queued', 'delayed') and o.created_at < least(p_now, now()) - interval '12 hours'),
       u as (update notification_outbox o set status = 'skipped', status_reason = left(s.why, 120), locked_at = null
               from s where o.id = s.id and s.why is not null returning 1)
  select count(*)::int into v from u;
  return v;
end $$;

-- the claim: stale ones first go, then the claim of 0583
alter function app.outbox_claim(integer, timestamptz) rename to outbox_claim_pre0601;
create function app.outbox_claim(p_limit integer default 20, p_now timestamptz default now())
returns table (id uuid, code text, category text, to_address text, to_name text, from_address text, reply_to text,
               subject text, payload jsonb, attempts integer, unsubscribe_url text, template_html text, template_text text)
language plpgsql security definer set search_path = public, app as $$
begin
  perform app.outbox_skip_stale(p_now);
  return query select * from app.outbox_claim_pre0601(p_limit, p_now);
end $$;
select pg_temp.copy_grants('app.outbox_claim(integer, timestamptz)'::regprocedure, 'app.outbox_claim_pre0601(integer, timestamptz)'::regprocedure);

-- the deploy's read: emails skipped as stale since a time, by audience and code (counts only)
create or replace function public.server_outbox_stale_report(p_since timestamptz default now() - interval '1 day') returns jsonb
language sql stable security definer set search_path = public, app as $$
  select jsonb_build_object(
    'since', p_since,
    'total', (select count(*) from notification_outbox where status = 'skipped' and status_reason like 'stale:%' and updated_at >= p_since),
    'waiting', (select count(*) from notification_outbox where status in ('queued', 'delayed')),
    'by_audience', coalesce((select jsonb_object_agg(audience, n) from (select coalesce(audience, '-') audience, count(*) n from notification_outbox
                     where status = 'skipped' and status_reason like 'stale:%' and updated_at >= p_since group by 1) x), '{}'::jsonb),
    'by_code', coalesce((select jsonb_agg(jsonb_build_object('code', code, 'n', n) order by n desc, code) from (select code, count(*) n from notification_outbox
                     where status = 'skipped' and status_reason like 'stale:%' and updated_at >= p_since group by 1) x), '[]'::jsonb))
$$;

do $$
declare f text;
begin
  foreach f in array array['app.outbox_is_record(text)', 'app.outbox_age_words(interval)', 'app.outbox_stale_reason(notification_outbox, timestamptz)',
    'app.outbox_skip_stale(timestamptz)', 'public.server_outbox_stale_report(timestamptz)'] loop
    execute format('revoke all on function %s from public, anon, authenticated', f);
    execute format('grant execute on function %s to service_role', f);
  end loop;
end $$;

-- ================================================================ the backlog, once
do $$
declare n integer := app.outbox_skip_stale(now());
begin
  raise notice '0601: % waiting emails skipped as stale', n;
end $$;
