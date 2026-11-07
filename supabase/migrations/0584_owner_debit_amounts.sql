-- 0584_owner_debit_amounts.sql
-- Release 29, C4 (docs/changes/2026-11-06-plain-staff-emails.md): the owner asked what the "random amounts" in the debit
-- emails are.
--   1. Every owner-debit email, the owner's and the staff's, gives each amount one plain line: the car, the fee as the
--      owner's agreement words it (monthly fee, first and last month, tracker install, adjustment, late fee), the period,
--      how it was worked out ("prorated: 20 of 30 days") and the invoice link (app.owner_invoice_plain).
--   2. The fee check (app.owner_fee_audit, read only): a month's owner invoices against each car's signed terms (no fees on
--      a flat monthly payment, Turo-Only, a shareholder's car, a company or partner car; nothing before the Enrollment
--      Date or after the fees end; the amount the terms give). The production deploy prints it as an annotation
--      (scripts/deploy/fee-audit.sh: owners by a short reference, never a name). No invoice is changed here: one that does
--      not match is listed first, for an Admin to decide.
--   3. Admin > Money > Owner money > Debits, "Debit preview": before the debit day, each owner's invoices, the amount, why
--      it is charged, whether a bank debit is set up, and Hold (pauses that owner's automatic debit, with a reason).

create function pg_temp.copy_grants(p_new regprocedure, p_old regprocedure) returns void
language plpgsql as $$
declare g text;
begin
  execute format('revoke all on function %s from public, anon, authenticated', p_new);
  foreach g in array array['anon', 'authenticated', 'service_role'] loop
    if has_function_privilege(g, p_old, 'execute') then execute format('grant execute on function %s to %I', p_new, g); end if;
  end loop;
end $$;

-- ================================================================ 1. one plain line per amount
-- p_amount: the amount the email shows for this invoice (the notice's, the attempt's); null: what is owing now
create or replace function app.owner_invoice_plain(p_inv uuid, p_staff boolean default false, p_amount text default null) returns jsonb
language sql stable security definer set search_path = public, app as $$
  with i as (select * from owner_invoices where id = p_inv),
  l as (
    select coalesce(sum(amount_cents) filter (where kind in ('insurance_fee', 'tracker_fee')), 0) as fee_cents,
           coalesce(-sum(amount_cents) filter (where kind = 'prepaid_credit'), 0) as prepaid_cents,
           max(substring(description from 'none for the ([0-9]+) days on a flat monthly payment'))::integer as flat_days,
           bool_or(description ~ '[0-9]+ days at ') as terms_changed,
           string_agg(coalesce(nullif(description, ''), initcap(replace(kind, '_', ' '))) || ' ' || app.fmt_money(amount_cents), ' + ' order by created_at)
             filter (where kind not in ('late_fee')) as parts
      from owner_invoice_lines where owner_invoice_id = p_inv),
  x as (
    select i.*, l.*,
      case when i.kind = 'monthly' and i.late_fee_cents > 0 and i.balance_cents > 0 and i.balance_cents <= i.late_fee_cents then 'late fee'
           else case i.kind when 'monthly' then 'monthly fee' when 'upfront' then 'first and last month' when 'tracker_install' then 'tracker install'
                            when 'adjustment' then 'adjustment' when 'credit_note' then 'credit' else 'one-off charge' end end as fee,
      case when i.kind = 'monthly' then to_char(i.period_month, 'FMMonth YYYY')
           when i.kind = 'upfront' then 'paid ahead, kept until the car leaves'
           when i.period_month is not null then to_char(i.period_month, 'FMMonth YYYY')
           else 'one time' end as period
      from i, l)
  select jsonb_build_object(
    'invoice_number', x.invoice_number,
    'car', coalesce(app.vehicle_name(x.vehicle_id), 'your car'),
    'fee', x.fee,
    'period', x.period,
    'amount', coalesce(p_amount, app.fmt_money(x.balance_cents)),
    'how', case
      when x.kind = 'monthly' and x.fee = 'late fee' then 'the fees are paid; the late fee for a payment the bank sent back is left'
      when x.kind = 'monthly' then
        case when x.terms_changed then 'new terms during the month, each part by its days'
             when x.days_billed is not null and x.days_in_month is not null and x.days_billed < x.days_in_month
               then format('prorated: %s of %s days', x.days_billed, x.days_in_month)
             else 'full month' end
        || case when x.flat_days > 0 then format(', none for the %s days on a flat monthly payment', x.flat_days) else '' end
        || case when x.prepaid_cents > 0 then format(', less %s of the prepaid first month', app.fmt_money(x.prepaid_cents)) else '' end
        || case when x.hst_cents <> 0 then ', plus HST' else '' end
        || case when x.late_fee_cents > 0 then format(', plus the %s late fee', app.fmt_money(x.late_fee_cents)) else '' end
      else coalesce(x.parts, x.fee) || case when x.hst_cents <> 0 then ', plus HST' else '' end
        || case when x.late_fee_cents > 0 then format(', plus the %s late fee', app.fmt_money(x.late_fee_cents)) else '' end end,
    'url', case when p_staff then rtrim((app.settings()).notify_base_url, '/') || '/admin/owners/' || x.owner_id || '#inv-' || x.invoice_number
                else app.ntf_link('owner_invoice', jsonb_build_object('invoice_number', x.invoice_number)) end,
    'line', format('%s: %s, %s, %s', coalesce(p_amount, app.fmt_money(x.balance_cents)), coalesce(app.vehicle_name(x.vehicle_id), 'your car'), x.fee, x.period))
  from x
$$;

-- each entry of a list gains the plain line (matched by invoice number)
create or replace function app.owner_invoice_plain_list(p_items jsonb, p_staff boolean) returns jsonb
language sql stable security definer set search_path = public, app as $$
  select coalesce(jsonb_agg(case when i.id is null then e else e || app.owner_invoice_plain(i.id, p_staff, e ->> 'amount') end order by o), '[]'::jsonb)
    from jsonb_array_elements(coalesce(p_items, '[]'::jsonb)) with ordinality t(e, o)
    left join owner_invoices i on i.invoice_number = e ->> 'invoice_number'
$$;

alter function app.notification_payload(text, app_events, jsonb) rename to ntf_payload_pre0584;
create function app.notification_payload(p_code text, p_event app_events, p_to jsonb) returns jsonb
language plpgsql stable security definer set search_path = public, app as $$
declare
  x jsonb := app.ntf_payload_pre0584(p_code, p_event, p_to);
  v_staff boolean := p_code like 'staff\_%';
  v_inv uuid;
begin
  if x is null then return x; end if;
  if p_code in ('owner_debit_notice', 'owner_debit_setup_needed', 'staff_owner_debit_exception') and jsonb_typeof(x -> 'debit_items') = 'array' then
    x := jsonb_set(x, '{debit_items}', app.owner_invoice_plain_list(x -> 'debit_items', v_staff));
  elsif p_code = 'staff_owner_debit_run' and jsonb_typeof(x -> 'run_items') = 'array' then
    x := jsonb_set(x, '{run_items}', app.owner_invoice_plain_list(x -> 'run_items', true));
  elsif p_code in ('owner_debit_returned', 'owner_payment_failed', 'owner_in_arrears', 'staff_owner_invoice_failed') and x ? 'invoice_number' then
    select id into v_inv from owner_invoices where invoice_number = x ->> 'invoice_number';
    if v_inv is not null then
      x := x || jsonb_build_object('amount_items', jsonb_build_array(app.owner_invoice_plain(v_inv, v_staff, x ->> 'amount')));
    end if;
  end if;
  return x;
end $$;
select pg_temp.copy_grants('app.notification_payload(text, app_events, jsonb)'::regprocedure, 'app.ntf_payload_pre0584(text, app_events, jsonb)'::regprocedure);

-- ================================================================ 2. the fee check (read only)
-- A month's owner invoices (monthly by their month; the others billed in it) against the car's signed terms. Each row:
-- the owner by a short reference (never a name), the invoice, the car's fleet number, the amount, and what does not match.
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
  v_billed bigint;
begin
  for r in
    select i.*, v.fleet_number, v.supply_type::text as supply, v.billing_case, v.enrollment_date, app.vehicle_fee_end(v.id) as fee_end,
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
        v_expect := public.calc_prorated_fee(t.insurance_fee_cents, v_days, v_dim) + public.calc_prorated_fee(t.tracker_fee_cents, v_days, v_dim);
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

-- the deploy's read (scripts/deploy/fee-audit.sh), with the service key
create or replace function public.server_owner_fee_audit(p_month date default null) returns jsonb
language sql stable security definer set search_path = public, app as $$ select app.owner_fee_audit(p_month) $$;

-- ================================================================ 3. the debit preview
-- The coming debit day: the earliest debit still scheduled, or the next debit day. Each owner with something to debit:
-- the invoices with their plain line, the amount, whether a bank debit is set up, whether a notice went, paused.
create or replace function app.owner_debit_preview(p_on date default null) returns jsonb
language sql stable security definer set search_path = public, app as $$
  with d as (
    select coalesce(p_on, (select min(a.debit_on) from owner_debit_attempts a where a.status = 'scheduled' and a.debit_on >= app.today()),
                    app.owner_debit_next_date(app.today())) as on_day),
  inv as (
    select i.*, d.on_day,
           exists (select 1 from owner_debit_attempts a where a.owner_invoice_id = i.id and a.status = 'scheduled' and a.debit_on = d.on_day) as scheduled
      from owner_invoices i, d
     where i.status in ('issued', 'failed') and i.balance_cents > 0 and i.collect_by = 'bank_debit'
       and i.kind = any ((app.settings()).owner_debit_kinds) and i.billing_date <= d.on_day),
  o as (
    select inv.owner_id, ow.legal_name, ow.is_test, ow.auto_debit_paused,
           app.owner_debit_mandate(inv.owner_id) as mandate,
           sum(inv.balance_cents) as total_cents,
           bool_or(inv.scheduled) as noticed,
           jsonb_agg(app.owner_invoice_plain(inv.id, true) || jsonb_build_object('id', inv.id, 'scheduled', inv.scheduled, 'paused', inv.auto_debit_paused,
                                                                                 'balance_cents', inv.balance_cents)
                     order by inv.billing_date, inv.invoice_number) as invoices
      from inv join owners ow on ow.id = inv.owner_id
     group by inv.owner_id, ow.legal_name, ow.is_test, ow.auto_debit_paused)
  select jsonb_build_object(
    'debit_on', (select on_day from d),
    'owners', coalesce((select jsonb_agg(jsonb_build_object(
        'id', o.owner_id, 'name', o.legal_name, 'is_test', o.is_test, 'paused', o.auto_debit_paused,
        'debit_set_up', o.mandate is not null, 'bank_last4', o.mandate ->> 'last4', 'noticed', o.noticed,
        'total_cents', o.total_cents, 'invoices', o.invoices) order by o.legal_name) from o), '[]'::jsonb))
$$;

alter function app.door(uuid, text, text, text, jsonb) rename to door_pre0584;
create function app.door(p_user uuid, p_aal text, p_call text, p_name text, p jsonb default '{}'::jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
begin
  if p_call in ('ops_read', 'admin_read') and p_name in ('owner_debit_preview', 'owner_fee_audit') then
    if coalesce(p, '{}'::jsonb) ? '_va' then perform set_config('app.va_active', coalesce(p ->> '_va', ''), true); end if;
    perform app.door_begin(p_user, p_aal);
    if not (app.user_is_admin(p_user) or app.user_runs_finance(p_user)) then raise exception 'Not permitted' using errcode = '42501'; end if;
    if p_name = 'owner_debit_preview' then return app.owner_debit_preview(nullif(p ->> 'on', '')::date); end if;
    return app.owner_fee_audit(nullif(p ->> 'month', '')::date);
  end if;
  return app.door_pre0584(p_user, p_aal, p_call, p_name, p);
end $$;
select pg_temp.copy_grants('app.door(uuid, text, text, text, jsonb)'::regprocedure, 'app.door_pre0584(uuid, text, text, text, jsonb)'::regprocedure);

revoke all on function app.owner_invoice_plain(uuid, boolean, text), app.owner_invoice_plain_list(jsonb, boolean), app.owner_fee_audit(date),
  public.server_owner_fee_audit(date), app.owner_debit_preview(date) from public, anon, authenticated;
grant execute on function app.owner_invoice_plain(uuid, boolean, text), app.owner_invoice_plain_list(jsonb, boolean), app.owner_fee_audit(date),
  public.server_owner_fee_audit(date), app.owner_debit_preview(date) to service_role;
