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
-- Also: the fee check of 0584 charges the Tracker Fee only from the tracker's installation, as the invoices do (0239).

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

-- ================================================================ the fee check (0584) and the Tracker Fee
-- The first production fee check (November 7) flagged 29 invoices "billed less than the terms": each car has no tracker
-- installed yet, and the Tracker Fee runs only from the installation (0239). The check now follows the same rule; the
-- invoices were right and nothing is changed.
create or replace function app.owner_fee_audit(p_month date default null) returns jsonb
language plpgsql stable security definer set search_path = public, app as $$
declare
  v_month date := app.month_start(coalesce(p_month, app.today()));
  v_last date := (app.month_start(coalesce(p_month, app.today())) + interval '1 month - 1 day')::date;
  r record;
  v_rows jsonb := '[]'::jsonb;
  v_problems jsonb := '[]'::jsonb;
  v_problem text;
  v_start date;
  v_end date;
  v_days integer;
  v_dim integer := app.days_in_month(coalesce(p_month, app.today()));
  v_flat integer;
  v_terms integer;
  t vehicle_fee_history;
  v_expect bigint;
  v_trk_start date;
  v_trk_days integer;
  v_billed bigint;
begin
  for r in
    select i.*, v.fleet_number, v.supply_type::text as supply, v.billing_case, v.enrollment_date, app.vehicle_fee_end(v.id) as fee_end,
           v.tracker_installed_on, v.tracker_install_pending,
           'owner ' || left(md5(i.owner_id::text), 6) as owner_ref,
           (select coalesce(sum(l.amount_cents), 0) from owner_invoice_lines l where l.owner_invoice_id = i.id and l.kind in ('insurance_fee', 'tracker_fee')) as fee_lines,
           exists (select 1 from owner_agreements a where a.owner_id = i.owner_id and a.kind = 'enrollment' and a.variant = 'flat_rate' and a.status = 'signed') as flat_agreement
      from owner_invoices i join vehicles v on v.id = i.vehicle_id
     where i.status <> 'void'
       and ((i.kind = 'monthly' and i.period_month = v_month) or (i.kind <> 'monthly' and i.billing_date between v_month and v_last))
     order by i.owner_id, i.invoice_number
  loop
    v_problem := null;
    v_billed := r.fee_lines;
    if r.kind = 'monthly' then
      v_start := greatest(v_month, r.enrollment_date);
      v_end := least(v_last, coalesce(r.fee_end, v_last));
      v_days := case when r.enrollment_date is null then 0 else greatest((v_end - v_start) + 1, 0) end;
      v_flat := case when v_days > 0 then app.flat_days(r.vehicle_id, v_start, v_end) else 0 end;
      select count(*) into v_terms from vehicle_fee_history f
       where f.vehicle_id = r.vehicle_id and f.effective_from <= v_end and (f.effective_to is null or f.effective_to > v_start);
      if r.supply in ('company', 'partner') then v_problem := 'a company or partner car pays no fees';
      elsif r.billing_case in ('turo_only', 'shareholder') then v_problem := format('no fees on this car''s plan (%s)', replace(r.billing_case, '_', '-'));
      elsif v_days <= 0 then v_problem := 'billed for a month the car was not enrolled (before the Enrollment Date or after the fees end)';
      elsif v_flat >= v_days and v_billed > 0 then v_problem := 'every day on a flat monthly payment: no monthly fee';
      elsif r.flat_agreement and v_flat = 0 and v_billed > 0 then v_problem := 'the owner signed the flat-rate agreement: check this car is meant to pay fees';
      elsif v_terms = 1 then
        t := app.vehicle_terms(r.vehicle_id, v_start);
        -- the Tracker Fee only from the tracker's installation (0239): none before it, none while it is pending
        v_trk_start := case when r.tracker_install_pending or r.tracker_installed_on is null then v_end + 1
                            when r.tracker_installed_on > v_start then r.tracker_installed_on else v_start end;
        v_trk_days := greatest((v_end - v_trk_start) + 1, 0);
        v_expect := public.calc_prorated_fee(t.insurance_fee_cents, v_days, v_dim) + public.calc_prorated_fee(t.tracker_fee_cents, v_trk_days, v_dim);
        if v_flat > 0 then v_expect := round(v_expect::numeric * (v_days - v_flat) / v_days)::bigint; end if;
        if abs(v_expect - v_billed) > 2 then
          v_problem := format('billed %s before HST, the terms give %s (%s of %s days)', app.fmt_money(v_billed), app.fmt_money(v_expect), v_days - v_flat, v_dim);
        end if;
      end if;
    elsif r.supply in ('company', 'partner') and r.kind in ('upfront', 'tracker_install') then
      v_problem := 'a company or partner car pays no fees';
    elsif r.billing_case in ('turo_only', 'shareholder') and r.kind = 'upfront' then
      v_problem := format('no upfront charges on this car''s plan (%s)', replace(r.billing_case, '_', '-'));
    end if;
    v_rows := v_rows || jsonb_build_object('owner', r.owner_ref, 'invoice', r.invoice_number, 'car', r.fleet_number, 'kind', r.kind,
                                           'status', r.status, 'total_cents', r.total_cents, 'total', app.fmt_money(r.total_cents), 'problem', v_problem);
    if v_problem is not null then
      v_problems := v_problems || jsonb_build_object('owner', r.owner_ref, 'invoice', r.invoice_number, 'car', r.fleet_number,
                                                     'total', app.fmt_money(r.total_cents), 'problem', v_problem);
    end if;
  end loop;
  return jsonb_build_object(
    'month', to_char(v_month, 'FMMonth YYYY'),
    'invoices', jsonb_array_length(v_rows),
    'owners', (select count(distinct e ->> 'owner') from jsonb_array_elements(v_rows) e),
    'total', app.fmt_money(coalesce((select sum((e ->> 'total_cents')::bigint) from jsonb_array_elements(v_rows) e), 0)),
    'by_owner', coalesce((select jsonb_agg(jsonb_build_object('owner', o, 'invoices', n, 'total', app.fmt_money(c)) order by o)
                            from (select e ->> 'owner' o, count(*) n, sum((e ->> 'total_cents')::bigint) c from jsonb_array_elements(v_rows) e group by 1) g), '[]'::jsonb),
    'rows', v_rows,
    'problems', v_problems);
end $$;

-- ================================================================ the backlog, once
do $$
declare n integer := app.outbox_skip_stale(now());
begin
  raise notice '0601: % waiting emails skipped as stale', n;
end $$;
