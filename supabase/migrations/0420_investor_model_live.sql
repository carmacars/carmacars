-- 0420: the model spreadsheets, live (Release 27, "investor sheets"). SCHEMA_MARKER 0420. docs/changes/2026-11-01-live-model-sheets.md.
--   The owner's request: "Can u have these spreadsheets as live and auto updating on the investor portal? Downloadable but on
--   the website it's viewable as live." The CarmaCars model workbook's investor-safe tabs become the investor portal's
--   Model page (their own investment from their records, the calculator, how it works, fund a car; Excel and PDF
--   downloads); its internal tabs become Admin > Money > Company model (actuals, forecast, pro forma; Excel download).
--
--   1. finance_model_actuals: one row per month, filled by a cheap hourly job (pg_cron) instead of on every page view
--      (the site is over its CPU allowance). Each month: rental revenue earned (accrual: each booking's rental lines spread
--      evenly over its days, each day in the month its pickup-time day starts in; before HST; insurer-billed and
--      renter-billed apart; placeholders, cancelled and unconfirmed bookings left out), fees by kind (the same spread),
--      rented days, rentals, cars on the fleet, owner and partner shares, staff commissions, referral kickbacks, owner
--      payouts paid, processing fees, Admin > Expenses by category, investor payouts paid and capital received, and cash
--      received and refunded by method.
--   2. finance_model_settings: the forecast assumptions an Admin edits (growth, utilization ramp, rates, costs, hires,
--      capital raises, the fleet insurance premium, blank until entered, and tax), one row.
--   3. The door: admin_read finance_model, admin_save finance_model_inputs, admin_do finance_model_refresh (Admins only:
--      no staff permission says Finance sees company statements, so Finance does not see this either); investor_read
--      model_terms (the investment terms and the headline figure an investor's sheets need, nothing about the fleet).
--   Both tables: row level security on, Admins only for a signed-in session; the server reads through the door.
set local check_function_bodies = off;

-- ================================================================ 1. tables
create table if not exists finance_model_actuals (
  month        date primary key check (extract(day from month) = 1),
  complete     boolean not null,
  data         jsonb not null,
  computed_at  timestamptz not null default now()
);
comment on table finance_model_actuals is 'The company model''s actuals by month (0420), computed by app.finance_model_refresh from bookings, payments, payouts, expenses and investments each hour (pg_cron). Internal: Admins only.';

create table if not exists finance_model_settings (
  id          boolean primary key default true check (id),
  inputs      jsonb not null default '{}'::jsonb check (jsonb_typeof(inputs) = 'object'),
  updated_at  timestamptz,
  updated_by  uuid references users (id)
);
comment on table finance_model_settings is 'The company model''s forecast assumptions (0420), saved from Admin > Money > Company model. The fleet insurance premium stays blank until an Admin enters it. Internal: Admins only.';
insert into finance_model_settings (id) values (true) on conflict do nothing;

-- ================================================================ 2. one month's actuals
-- The accrual: a booking's rental lines (family rental: the rental charge, extra days, discounts) and fee lines (company
-- fees and mileage overage; tolls and tickets at cost, deductibles and the kickback line are not revenue) are spread evenly
-- over its billable days; day i starts at pickup + i x 24 hours and belongs to the month that local date is in.
create or replace function app.finance_model_month(p_month date) returns jsonb
language plpgsql stable security definer set search_path = public, app as $$
declare
  m0 date := app.month_start(p_month);
  m1 date := (app.month_start(p_month) + interval '1 month')::date;
  t0 timestamptz := app.local_midnight(app.month_start(p_month));
  t1 timestamptz := app.local_midnight((app.month_start(p_month) + interval '1 month')::date);
  v jsonb;
begin
  with b as (
    select bk.id, bk.billable_days, bk.company_share_bps, bk.bill_to, bk.insurer_id, bk.insurer_share_cents, bk.subtotal_at_booking_cents, bk.is_shareholder_vehicle,
           o.kind as owner_kind,
           (select count(*) from generate_series(0, bk.billable_days - 1) g(i)
             where app.local_date(bk.pickup_at + g.i * interval '1 day') >= m0 and app.local_date(bk.pickup_at + g.i * interval '1 day') < m1)::numeric as days_in
      from bookings bk join owners o on o.id = bk.owner_id
     where bk.status in ('confirmed', 'on_rent', 'returned', 'closed')
       and bk.booking_type <> 'owner'
       and not coalesce(app.booking_is_placeholder(bk.id), false)
       and bk.pickup_at < t1 and bk.pickup_at + bk.billable_days * interval '1 day' > t0
  ), x as (
    select b.*, b.days_in / b.billable_days as share,
           coalesce((select sum(li.amount_cents) from booking_line_items li join fee_types ft on ft.code = li.charge_type
                      where li.booking_id = b.id and li.voided_at is null and ft.family = 'rental'), 0) as rental_total,
           coalesce((select sum(li.amount_cents) from booking_line_items li join fee_types ft on ft.code = li.charge_type
                      where li.booking_id = b.id and li.voided_at is null and li.charged_to_renter and ft.family = 'fee' and li.revenue_class in ('company_only', 'owner_revenue')), 0) as fee_total,
           coalesce((select sum(li.amount_cents) from booking_line_items li
                      where li.booking_id = b.id and li.voided_at is null and li.charged_to_renter and li.revenue_class = 'owner_revenue' and li.charge_type = 'mileage_overage'), 0) as owner_fee_total,
           coalesce((select sum(k.amount_cents) from referral_kickbacks k where k.booking_id = b.id and k.status <> 'reversed'), 0) as kick_total,
           coalesce((select sum(c.amount_cents) from staff_commissions c where c.booking_id = b.id and c.status not in ('void', 'reversed')), 0) as comm_total,
           case when coalesce(b.bill_to, 'renter') = 'renter' or b.insurer_id is null then 0::numeric
                when b.bill_to = 'insurer' then 1::numeric
                else least(1, greatest(0, b.insurer_share_cents::numeric / nullif(b.subtotal_at_booking_cents, 0))) end as insurer_frac
      from b where b.days_in > 0
  ), y as (
    select x.*,
           x.rental_total * x.share as rental_m,
           x.fee_total * x.share as fee_m,
           x.kick_total * x.share as kick_m,
           x.comm_total * x.share as comm_m,
           case when x.owner_kind = 'company' then 0
                else greatest(0, x.rental_total + x.owner_fee_total - x.kick_total - x.comm_total) * (10000 - x.company_share_bps) / 10000.0 * x.share end as owner_m,
           case when x.owner_kind = 'company' then 'company' when x.owner_kind = 'partner' then 'partner' when x.is_shareholder_vehicle then 'shareholder' else 'program' end as segment
      from x
  )
  select jsonb_build_object(
    'rental_cents', coalesce(round(sum(y.rental_m)), 0)::bigint,
    'rental_insurer_cents', coalesce(round(sum(y.rental_m * y.insurer_frac)), 0)::bigint,
    'rental_renter_cents', coalesce(round(sum(y.rental_m)) - round(sum(y.rental_m * y.insurer_frac)), 0)::bigint,
    'rented_days', coalesce(sum(y.days_in), 0),
    'rentals', count(*),
    'fees_cents', coalesce(round(sum(y.fee_m)), 0)::bigint,
    'owner_share_cents', coalesce(round(sum(y.owner_m) filter (where y.segment <> 'partner')), 0)::bigint,
    'partner_share_cents', coalesce(round(sum(y.owner_m) filter (where y.segment = 'partner')), 0)::bigint,
    'commissions_cents', coalesce(round(sum(y.comm_m)), 0)::bigint,
    'kickbacks_cents', coalesce(round(sum(y.kick_m)), 0)::bigint,
    'rental_by_segment', coalesce((select jsonb_object_agg(s.segment, s.cents) from (select y2.segment, round(sum(y2.rental_m))::bigint as cents from y y2 group by 1) s), '{}'::jsonb),
    'fees_by_kind', coalesce((select jsonb_object_agg(f.code, jsonb_build_object('label', f.label, 'cents', f.cents))
                                from (select li.charge_type as code, ft.label, round(sum(li.amount_cents * y3.share))::bigint as cents
                                        from y y3 join booking_line_items li on li.booking_id = y3.id join fee_types ft on ft.code = li.charge_type
                                       where li.voided_at is null and li.charged_to_renter and ft.family = 'fee' and li.revenue_class in ('company_only', 'owner_revenue')
                                       group by 1, 2 having round(sum(li.amount_cents * y3.share)) <> 0) f), '{}'::jsonb))
    into v from y;

  v := v || jsonb_build_object(
    'month', m0,
    'complete', m1 <= app.month_start(app.today()),
    'cars', (select count(*) from vehicles ve
              where not ve.is_sample and ve.created_at < t1 and (ve.retired_at is null or ve.retired_at >= t1)
                and (ve.status::text in ('available', 'on_rent', 'cleaning', 'out_of_service', 'exit_notice')
                     or (ve.status::text in ('exited', 'total_loss') and coalesce(ve.fleet_policy_removed_on, ve.total_loss_decided_on, m0) >= m1))),
    'owner_payouts_paid_cents', coalesce((select sum(p.amount_cents) from payouts p where p.payee_type = 'owner' and p.status = 'paid' and p.paid_at >= t0 and p.paid_at < t1), 0),
    'investor_payouts_cents', coalesce((select sum(p.amount_cents) from payouts p where p.payee_type = 'investor' and p.status = 'paid' and p.paid_at >= t0 and p.paid_at < t1), 0),
    'investor_capital_cents', coalesce((select sum(i.principal_cents) from investments i where i.transferred_from_investment_id is null and i.investment_date >= m0 and i.investment_date < m1), 0),
    'expenses_cents', coalesce((select sum(e.amount_cents) from company_expenses e where e.voided_at is null and e.expense_on >= m0 and e.expense_on < m1), 0),
    'expenses_by_category', coalesce((select jsonb_object_agg(s.category, jsonb_build_object('label', s.label, 'cents', s.cents))
                                        from (select e.category, c.label, sum(e.amount_cents) as cents from company_expenses e join company_expense_categories c on c.code = e.category
                                               where e.voided_at is null and e.expense_on >= m0 and e.expense_on < m1 group by 1, 2) s), '{}'::jsonb),
    'processing_cents', coalesce((select sum(d.processor_fee_cents) from payments p join payment_processor_details d on d.payment_id = p.id
                                   where p.status = 'succeeded' and coalesce(p.processed_at, p.created_at) >= t0 and coalesce(p.processed_at, p.created_at) < t1), 0)
                        + coalesce((select sum(e.amount_cents) from company_expenses e where e.voided_at is null and e.category = 'processing_fees' and e.expense_on >= m0 and e.expense_on < m1), 0),
    'cash_by_method', coalesce((select jsonb_object_agg(s.channel, jsonb_build_object('label', app.payment_channel_label(s.channel), 'in_cents', s.amt_in, 'out_cents', s.amt_out, 'count', s.n))
                                  from (select app.payment_channel(p.method, p.purpose, p.booking_id) as channel,
                                               sum(case when p.kind in ('charge', 'capture') then p.amount_cents else 0 end) as amt_in,
                                               sum(case when p.kind = 'refund' then p.amount_cents else 0 end) as amt_out, count(*) as n
                                          from payments p
                                         where p.status = 'succeeded' and p.kind in ('charge', 'capture', 'refund')
                                           and coalesce(p.processed_at, p.created_at) >= t0 and coalesce(p.processed_at, p.created_at) < t1
                                         group by 1) s), '{}'::jsonb));
  return v;
end $$;

-- Recompute months (all from the launch month, or the last two) into the summary table.
create or replace function app.finance_model_refresh(p_full boolean default true) returns integer
language plpgsql security definer set search_path = public, app as $$
declare
  v_first date := app.month_start(least(coalesce((select min(app.local_date(b.pickup_at)) from bookings b where b.status in ('confirmed', 'on_rent', 'returned', 'closed')), app.today()), date '2026-10-01'));
  v_now date := app.month_start(app.today());
  v_from date := case when p_full or not exists (select 1 from finance_model_actuals) then v_first else greatest(v_first, (v_now - interval '1 month')::date) end;
  m date;
  n integer := 0;
  v jsonb;
begin
  m := v_from;
  while m <= v_now loop
    v := app.finance_model_month(m);
    insert into finance_model_actuals (month, complete, data, computed_at) values (m, (v ->> 'complete')::boolean, v, now())
      on conflict (month) do update set complete = excluded.complete, data = excluded.data, computed_at = excluded.computed_at;
    n := n + 1;
    m := (m + interval '1 month')::date;
  end loop;
  return n;
end $$;

-- The hourly job: the month in progress and the one before each hour; every month once a night (3 a.m. Toronto).
create or replace function app.job_finance_model(p_at timestamptz default now()) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  v_full boolean := app.local_hour(p_at) = 3 or not exists (select 1 from finance_model_actuals);
begin
  return jsonb_build_object('months', app.finance_model_refresh(v_full), 'full', v_full);
exception when others then
  -- never let the model block anything else on the schedule
  return jsonb_build_object('error', sqlerrm);
end $$;

-- ================================================================ 3. reads and saves
create or replace function app.finance_model_read(p_user uuid) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  s program_settings := app.settings();
begin
  if not app.user_is_admin(p_user) then raise exception 'The company model is for Admins only' using errcode = '42501'; end if;
  if not exists (select 1 from finance_model_actuals) then perform app.finance_model_refresh(true); end if;
  return jsonb_build_object(
    'actuals', coalesce((select jsonb_agg(a.data || jsonb_build_object('month', a.month, 'complete', a.complete) order by a.month) from finance_model_actuals a), '[]'::jsonb),
    'computed_at', (select max(a.computed_at) from finance_model_actuals a),
    'inputs', (select f.inputs from finance_model_settings f where f.id),
    'updated_at', (select f.updated_at from finance_model_settings f where f.id),
    'updated_by', (select u.full_name from finance_model_settings f join users u on u.id = f.updated_by where f.id),
    'investors', coalesce((select jsonb_agg(jsonb_build_object('invested_cents', i.invested_amount_cents, 'yearly_bps', i.yearly_bps, 'lockup_end_date', i.lockup_end_date, 'status', i.status))
                             from investments i where i.status = 'active'), '[]'::jsonb),
    'terms', jsonb_build_object('min_cents', s.investor_min_cents, 'lockup_months', s.investor_lockup_months, 'payment_day', s.investor_payment_day,
                                'offer_bps', (select d.deck_return_bps from deck_settings d limit 1), 'multiplier', (select d.deck_multiplier from deck_settings d limit 1)),
    'company', s.company_legal_name,
    'today', app.today());
end $$;

create or replace function app.finance_model_save(p_user uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  v jsonb := coalesce(p -> 'inputs', p -> 'values', '{}'::jsonb);   -- adminSaveRow sends { key, values }
begin
  if not app.user_is_admin(p_user) then raise exception 'The company model is for Admins only' using errcode = '42501'; end if;
  if jsonb_typeof(v) <> 'object' then raise exception 'The assumptions are a set of named values' using errcode = '22023'; end if;
  if length(v::text) > 20000 then raise exception 'Too many assumptions' using errcode = '22023'; end if;
  update finance_model_settings set inputs = v, updated_at = now(), updated_by = p_user where id;
  return jsonb_build_object('saved', true, 'updated_at', now());
end $$;

-- What an investor's sheets need: the investment terms and the company's headline figure, never a fleet fact.
create or replace function app.investor_model_terms(p_user uuid) returns jsonb
language plpgsql stable security definer set search_path = public, app as $$
declare
  i investors := app.investor_of(p_user);
  s program_settings := app.settings();
begin
  return jsonb_build_object('legal_name', i.legal_name, 'min_cents', s.investor_min_cents, 'lockup_months', s.investor_lockup_months, 'payment_day', s.investor_payment_day,
    'offer_bps', coalesce(i.offered_yearly_bps, (select d.deck_return_bps from deck_settings d limit 1)),
    'multiplier', (select d.deck_multiplier from deck_settings d limit 1),
    'company', s.company_legal_name,
    'today', app.today());
end $$;

-- ================================================================ 4. the door
alter function app.door(uuid, text, text, text, jsonb) rename to door_pre0420;
create function app.door(p_user uuid, p_aal text, p_call text, p_name text, p jsonb default '{}'::jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
begin
  if p_call = 'admin_read' and p_name = 'finance_model' then
    perform app.door_begin(p_user, p_aal);
    return app.finance_model_read(p_user);
  elsif p_call = 'admin_save' and p_name = 'finance_model_inputs' then
    perform app.door_begin(p_user, p_aal);
    return app.finance_model_save(p_user, coalesce(p, '{}'::jsonb));
  elsif p_call = 'admin_do' and p_name = 'finance_model_refresh' then
    perform app.door_begin(p_user, p_aal);
    if not app.user_is_admin(p_user) then raise exception 'The company model is for Admins only' using errcode = '42501'; end if;
    return jsonb_build_object('months', app.finance_model_refresh(true));
  elsif p_call = 'investor_read' and p_name = 'model_terms' then
    perform app.door_begin(p_user, p_aal);
    return app.investor_model_terms(p_user);
  end if;
  return app.door_pre0420(p_user, p_aal, p_call, p_name, p);
end $$;

-- ================================================================ 5. the schedule (pg_cron where it exists)
do $$
begin
  if to_regclass('cron.job') is not null then
    perform cron.schedule('carmacars-finance-model', '17 * * * *', $q$select app.job_finance_model()$q$);
  end if;
end $$;

-- ================================================================ 6. privileges and row level security
do $$
declare t text;
begin
  foreach t in array array['finance_model_actuals', 'finance_model_settings'] loop
    execute format('alter table %I enable row level security', t);
    execute format('revoke all on %I from anon, authenticated', t);
    execute format('grant all on %I to service_role', t);
    execute format('create policy admin_all on %I for all to authenticated using (app.is_admin()) with check (app.is_admin())', t);
  end loop;
end $$;
-- the assumptions an Admin saves are audited (the actuals are a summary the job recomputes from audited rows)
drop trigger if exists audit_finance_model_settings on finance_model_settings;
create trigger audit_finance_model_settings after insert or update or delete on finance_model_settings for each row execute function app.audit_row();
-- an Admin's own session may read and change them (the policy decides); nobody else
grant select on finance_model_actuals to authenticated;
grant select, update on finance_model_settings to authenticated;

do $$
declare g text; f record;
begin
  foreach g in array array['anon', 'authenticated', 'service_role'] loop
    execute format('revoke all on function app.door(uuid, text, text, text, jsonb) from %I', g);
    if has_function_privilege(g, 'app.door_pre0420(uuid, text, text, text, jsonb)', 'execute') then execute format('grant execute on function app.door(uuid, text, text, text, jsonb) to %I', g); end if;
  end loop;
  execute 'revoke all on function app.door(uuid, text, text, text, jsonb) from public';
  for f in select p.oid::regprocedure as sig from pg_proc p join pg_namespace n on n.oid = p.pronamespace
            where n.nspname = 'app' and p.proname in ('finance_model_month', 'finance_model_refresh', 'job_finance_model', 'finance_model_read', 'finance_model_save', 'investor_model_terms', 'door_pre0420') loop
    execute format('revoke all on function %s from public, anon, authenticated', f.sig);
    execute format('grant execute on function %s to service_role', f.sig);
  end loop;
end $$;

-- the first fill
do $$ begin perform app.finance_model_refresh(true); end $$;
