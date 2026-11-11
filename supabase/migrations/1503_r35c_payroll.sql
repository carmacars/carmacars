-- 1503_r35c_payroll.sql
-- Release 35, part C (item 1): one payroll every two weeks for the salaried office staff (customer service, Fleet,
-- Finance) and the field staff, on the field pay periods of 0165 (app.fp_period).
--   * A salaried staff member's pay for a period is their monthly salary x 12 / 26 (a biweekly amount), by the days they
--     were employed in the period (started_on, ended_on). The monthly salary is their own (staff_profiles.monthly_salary_cents,
--     set by an Admin with a reason) or their role's default (Program settings va_salary_defaults {cs, fleet, finance}: empty
--     until an Admin sets it), in salary_currency (Program settings va_salary_currency, USD). Their clocked hours of the
--     period (staff_clock_entries) are on the line and the stub for the record; the salary does not depend on them.
--   * Field staff keep 0165's line: hours x rate, overtime and vacation pay when switched on, the approved commissions.
--   * Adjustments (a bonus or a deduction, with the reason) by Finance or an Admin, kept per run and person
--     (pay_adjustments) so a refresh keeps them.
--   * Finance prepares the run (start, refresh, adjust, Send for approval); only an Admin (a partner) approves it and
--     records the payments (one by one or all at once, by hand: nothing is ever paid automatically). Each staff member sees
--     their pay stubs in their portal (VA: Hours > My hours; field: My pay) once the run is approved.
-- No applied migration is edited: app.fp_run_refresh, app.field_pay_run_start and app.field_pay_run_refresh are replaced
-- (Finance may now call the last two), app.pdf_facts and app.door are wrapped.
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

alter table program_settings
  add column if not exists va_salary_defaults jsonb not null default '{}'::jsonb check (jsonb_typeof(va_salary_defaults) = 'object'),
  add column if not exists va_salary_currency text not null default 'USD' check (va_salary_currency in ('USD', 'CAD'));
comment on column program_settings.va_salary_defaults is 'Payroll (1503): the monthly salary in cents of each office role ({"cs": 35000, "fleet": 40000, "finance": 20000}); a person''s own salary replaces it. Paid every two weeks: monthly x 12 / 26.';
comment on column program_settings.va_salary_currency is 'Payroll (1503): the currency of the office staff''s salaries (USD or CAD); a person may have their own.';

alter table staff_profiles
  add column if not exists monthly_salary_cents integer check (monthly_salary_cents is null or monthly_salary_cents between 100 and 5000000),
  add column if not exists salary_currency text check (salary_currency is null or salary_currency in ('USD', 'CAD'));
comment on column staff_profiles.monthly_salary_cents is 'Payroll (1503): this office staff member''s monthly salary in cents; empty: their role''s default (va_salary_defaults).';

alter table field_pay_runs
  add column if not exists prepared_by uuid references users (id),
  add column if not exists prepared_at timestamptz;
comment on column field_pay_runs.prepared_at is 'Payroll (1503): Finance sent the draft for an Admin''s approval.';

alter table field_pay_lines
  add column if not exists salary_cents bigint not null default 0,
  add column if not exists monthly_salary_cents bigint,
  add column if not exists salary_days integer,
  add column if not exists adjustment_cents bigint not null default 0,
  add column if not exists adjustment_note text,
  add column if not exists clock_minutes integer not null default 0,
  add column if not exists currency text not null default 'CAD' check (currency in ('CAD', 'USD'));
comment on column field_pay_lines.salary_cents is 'Payroll (1503): a salaried staff member''s pay for the period: monthly x 12 / 26, by the days employed in the 14.';
comment on column field_pay_lines.clock_minutes is 'Payroll (1503): an office staff member''s clocked minutes in the period, for the record.';

create table if not exists pay_adjustments (
  id          uuid primary key default gen_random_uuid(),
  run_id      uuid not null references field_pay_runs (id),
  staff_id    uuid not null references users (id),
  amount_cents bigint not null check (amount_cents <> 0 and abs(amount_cents) <= 10000000),
  reason      text not null check (length(btrim(reason)) between 3 and 300),
  created_by  uuid not null references users (id),
  created_at  timestamptz not null default now(),
  removed_at  timestamptz,
  removed_by  uuid references users (id)
);
comment on table pay_adjustments is 'Payroll (1503): a bonus (positive) or deduction (negative) on a person''s line of a draft run, with the reason; removed, never deleted.';
create index if not exists pay_adjustments_run_idx on pay_adjustments (run_id, staff_id);
alter table pay_adjustments enable row level security;
revoke all on pay_adjustments from anon, authenticated;
grant all on pay_adjustments to service_role;
create policy admin_all on pay_adjustments for select to authenticated using (app.is_admin());
drop trigger if exists audit_pay_adjustments on pay_adjustments;
create trigger audit_pay_adjustments after insert or update or delete on pay_adjustments for each row execute function app.audit_row();

-- ================================================================ the salary
create function app.pay_salary_monthly(p_staff uuid) returns integer
language sql stable security definer set search_path = public, app as $$
  select coalesce(sp.monthly_salary_cents,
           (select max((s.va_salary_defaults ->> f)::integer) from unnest(sp.functions) f, (select (app.settings()).va_salary_defaults) s
             where f in ('cs', 'fleet', 'finance') and (s.va_salary_defaults ->> f) ~ '^[0-9]+$'))
    from staff_profiles sp where sp.user_id = p_staff and sp.staff_type = 'va'
$$;

create function app.pay_salary_currency(p_staff uuid) returns text
language sql stable security definer set search_path = public, app as $$
  select coalesce((select sp.salary_currency from staff_profiles sp where sp.user_id = p_staff), (app.settings()).va_salary_currency)
$$;

-- the salary of a period: monthly x 12 / 26, by the days employed among the 14
create function app.pay_salary_period(p_staff uuid, p_start date, p_end date) returns jsonb
language sql stable security definer set search_path = public, app as $$
  with sp as (select x.*, app.pay_salary_monthly(x.user_id) m from staff_profiles x where x.user_id = p_staff and x.staff_type = 'va'),
       d as (select sp.m, greatest(0, (least(p_end, coalesce(sp.ended_on, p_end)) - greatest(p_start, coalesce(sp.started_on, p_start)) + 1)) days
               from sp where sp.m is not null and (sp.is_active or sp.ended_on >= p_start))
  select coalesce((select jsonb_build_object('monthly_cents', d.m, 'days', least(d.days, p_end - p_start + 1),
                    'cents', round(d.m * 12 / 26.0 * least(d.days, p_end - p_start + 1) / (p_end - p_start + 1))::bigint, 'currency', app.pay_salary_currency(p_staff)) from d),
                  jsonb_build_object('monthly_cents', null, 'days', 0, 'cents', 0, 'currency', app.pay_salary_currency(p_staff)))
$$;

-- an office staff member's clocked minutes in a period (Toronto days)
create function app.pay_clock_minutes(p_staff uuid, p_start date, p_end date) returns integer
language sql stable security definer set search_path = public, app as $$
  select coalesce(sum(app.va_clock_minutes(e)), 0)::integer from staff_clock_entries e
   where e.user_id = p_staff and e.voided_at is null and app.local_date(e.started_at) between p_start and p_end
$$;

-- ================================================================ the run: field lines as before, plus the salaried staff
create or replace function app.fp_run_refresh(p_run uuid) returns integer
language plpgsql security definer set search_path = public, app as $$
declare
  r field_pay_runs;
  u record;
  v jsonb;
  sal jsonb;
  v_adj bigint;
  v_note text;
  v_clock integer;
  n integer := 0;
begin
  select * into r from field_pay_runs where id = p_run for update;
  if r.status <> 'draft' then raise exception 'Only a draft pay run is recalculated' using errcode = '23514'; end if;
  delete from field_pay_lines where run_id = r.id;
  for u in select sp.user_id as id, sp.staff_type from staff_profiles sp
            where sp.staff_type = 'field' or (sp.staff_type = 'va' and sp.functions && array['cs', 'fleet', 'finance'] and (sp.is_active or sp.ended_on >= r.period_start))
               or exists (select 1 from pay_adjustments a where a.run_id = r.id and a.staff_id = sp.user_id and a.removed_at is null)
            order by (select coalesce(us.full_name, us.email) from users us where us.id = sp.user_id) loop
    select coalesce(sum(a.amount_cents), 0), string_agg(a.reason, '; ' order by a.created_at) into v_adj, v_note
      from pay_adjustments a where a.run_id = r.id and a.staff_id = u.id and a.removed_at is null;
    if u.staff_type = 'field' then
      v := app.fp_line_values(u.id, r.period_start, r.period_end);
      continue when (v ->> 'minutes_total')::integer = 0 and (v ->> 'commission_cents')::bigint = 0 and v_adj = 0;
      insert into field_pay_lines (run_id, staff_id, rate_cents, minutes_total, minutes_regular, minutes_overtime, overtime_bps, wage_cents, overtime_cents,
                                   commission_cents, commission_ids, vacation_cents, adjustment_cents, adjustment_note, gross_cents, currency)
      values (r.id, u.id, (v ->> 'rate_cents')::integer, (v ->> 'minutes_total')::integer, (v ->> 'minutes_regular')::integer, (v ->> 'minutes_overtime')::integer,
              (v ->> 'overtime_bps')::integer, (v ->> 'wage_cents')::bigint, (v ->> 'overtime_cents')::bigint, (v ->> 'commission_cents')::bigint,
              array(select (jsonb_array_elements_text(v -> 'commission_ids'))::uuid), (v ->> 'vacation_cents')::bigint, v_adj, v_note,
              (v ->> 'gross_cents')::bigint + v_adj, 'CAD');
    else
      sal := app.pay_salary_period(u.id, r.period_start, r.period_end);
      v_clock := app.pay_clock_minutes(u.id, r.period_start, r.period_end);
      continue when (sal ->> 'cents')::bigint = 0 and v_adj = 0;
      insert into field_pay_lines (run_id, staff_id, rate_cents, minutes_total, minutes_regular, clock_minutes, salary_cents, monthly_salary_cents, salary_days,
                                   adjustment_cents, adjustment_note, gross_cents, currency)
      values (r.id, u.id, 0, v_clock, v_clock, v_clock, (sal ->> 'cents')::bigint, nullif(sal ->> 'monthly_cents', '')::bigint, (sal ->> 'days')::integer,
              v_adj, v_note, (sal ->> 'cents')::bigint + v_adj, sal ->> 'currency');
    end if;
    n := n + 1;
  end loop;
  update field_pay_runs set updated_at = now() where id = r.id;
  return n;
end $$;

-- Finance or an Admin prepares the run
create function app.payroll_may_prepare(p_user uuid) returns boolean
language sql stable security definer set search_path = public, app as $$ select app.user_runs_finance(p_user) $$;

create or replace function app.field_pay_run_start(p_by uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  v_on date := coalesce(nullif(p ->> 'date', '')::date, app.today());
  per record;
  r field_pay_runs;
begin
  if not app.payroll_may_prepare(p_by) then raise exception 'Only Finance or an Admin prepare the payroll' using errcode = '42501'; end if;
  select * into per from app.fp_period(v_on);
  if per.period_start > app.today() then raise exception 'That pay period has not started' using errcode = '23514'; end if;
  select * into r from field_pay_runs where period_start = per.period_start and status <> 'void';
  if r.id is null then
    insert into field_pay_runs (period_start, period_end, created_by) values (per.period_start, per.period_end, p_by) returning * into r;
    insert into audit_log (actor_user_id, action, entity_table, entity_id, after)
    values (p_by, 'field_pay_run_start', 'field_pay_runs', r.id::text, jsonb_build_object('period_start', r.period_start));
  end if;
  if r.status = 'draft' then perform app.fp_run_refresh(r.id); end if;
  return jsonb_build_object('run_id', r.id, 'status', r.status, 'period_start', r.period_start);
end $$;

create or replace function app.field_pay_run_refresh(p_by uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  r field_pay_runs := (select x from field_pay_runs x where x.id = nullif(p ->> 'run_id', '')::uuid);
begin
  if not app.payroll_may_prepare(p_by) then raise exception 'Only Finance or an Admin prepare the payroll' using errcode = '42501'; end if;
  if r.id is null then raise exception 'Pay run not found' using errcode = 'P0002'; end if;
  return jsonb_build_object('run_id', r.id, 'lines', app.fp_run_refresh(r.id));
end $$;

-- p: {run_id, staff, amount_cents (negative: a deduction), reason}, or {id, remove: true}
create function app.payroll_adjust(p_by uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  r field_pay_runs;
  a pay_adjustments;
  v_amt bigint := nullif(p ->> 'amount_cents', '')::bigint;
begin
  if not app.payroll_may_prepare(p_by) then raise exception 'Only Finance or an Admin prepare the payroll' using errcode = '42501'; end if;
  if coalesce((p ->> 'remove')::boolean, false) then
    select * into a from pay_adjustments where id = nullif(p ->> 'id', '')::uuid and removed_at is null;
    if a.id is null then raise exception 'Adjustment not found' using errcode = 'P0002'; end if;
    select * into r from field_pay_runs where id = a.run_id for update;
    if r.status <> 'draft' then raise exception 'The pay run is %: adjustments change only on a draft', r.status using errcode = '23514'; end if;
    update pay_adjustments set removed_at = now(), removed_by = p_by where id = a.id;
  else
    select * into r from field_pay_runs where id = nullif(p ->> 'run_id', '')::uuid for update;
    if r.id is null then raise exception 'Pay run not found' using errcode = 'P0002'; end if;
    if r.status <> 'draft' then raise exception 'The pay run is %: adjustments change only on a draft', r.status using errcode = '23514'; end if;
    if not exists (select 1 from staff_profiles sp where sp.user_id = nullif(p ->> 'staff', '')::uuid) then raise exception 'Choose the staff member' using errcode = '22023'; end if;
    if v_amt is null or v_amt = 0 then raise exception 'Give the amount (a deduction is negative)' using errcode = '22023'; end if;
    if length(btrim(coalesce(p ->> 'reason', ''))) < 3 then raise exception 'Give the reason' using errcode = '22023'; end if;
    insert into pay_adjustments (run_id, staff_id, amount_cents, reason, created_by)
    values (r.id, (p ->> 'staff')::uuid, v_amt, left(btrim(p ->> 'reason'), 300), p_by) returning * into a;
  end if;
  perform app.fp_run_refresh(r.id);
  update field_pay_runs set prepared_at = null, prepared_by = null where id = r.id;
  return jsonb_build_object('run_id', r.id, 'adjustment', a.id);
end $$;

-- Finance: the draft is ready for an Admin's approval (the Admins get a To do in their alerts)
create function app.payroll_submit(p_by uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  r field_pay_runs;
  v_total text;
begin
  if not app.payroll_may_prepare(p_by) then raise exception 'Only Finance or an Admin prepare the payroll' using errcode = '42501'; end if;
  select * into r from field_pay_runs where id = nullif(p ->> 'run_id', '')::uuid for update;
  if r.id is null then raise exception 'Pay run not found' using errcode = 'P0002'; end if;
  if r.status <> 'draft' then raise exception 'This pay run is already %', r.status using errcode = '23514'; end if;
  if r.period_end >= app.today() then raise exception 'The pay period ends on %: send it after that day', app.fmt_day(r.period_end) using errcode = '23514'; end if;
  perform app.fp_run_refresh(r.id);
  if not exists (select 1 from field_pay_lines where run_id = r.id) then raise exception 'There is nobody to pay in this period' using errcode = '23514'; end if;
  update field_pay_runs set prepared_by = p_by, prepared_at = now() where id = r.id;
  select string_agg(x, ', ') into v_total from (select currency || ' ' || to_char(sum(gross_cents) / 100.0, 'FM999,999,990.00') x from field_pay_lines where run_id = r.id group by currency order by currency) q;
  perform app.staff_alert('payroll_ready', 'field_pay_run', r.id, 'ready:' || r.id || ':' || floor(extract(epoch from now())),
    'Payroll ready for approval: ' || app.fp_period_label(r.period_start), coalesce(v_total, '') || '. Approve it, then record the payments.',
    jsonb_build_object('path_admin', '/admin/money/field-pay'));
  insert into audit_log (actor_user_id, action, entity_table, entity_id, after)
  values (p_by, 'payroll_submit', 'field_pay_runs', r.id::text, jsonb_build_object('period_start', r.period_start, 'total', v_total));
  return jsonb_build_object('run_id', r.id, 'prepared', true);
end $$;

insert into staff_alert_rules (rule, label, grp, who, tier, topic, wired, fixed, hint, sort) values
  ('payroll_ready', 'Payroll ready for approval', 'Staff', '{admin}', 'normal', 'alerts', true, false, 'Finance sent the two-week payroll for approval (1503).', 167)
on conflict (rule) do nothing;

-- An Admin: every pending line of an approved run recorded as paid by hand, the same method, the reference followed by
-- each statement number. p: {run_id, method, reference, paid_on}
create function app.payroll_pay_all(p_by uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  r field_pay_runs;
  l field_pay_lines;
  n integer := 0;
begin
  perform app.assert_admin(p_by);
  select * into r from field_pay_runs where id = nullif(p ->> 'run_id', '')::uuid;
  if r.id is null then raise exception 'Pay run not found' using errcode = 'P0002'; end if;
  if r.status <> 'approved' then raise exception 'Approve the pay run before recording the payments' using errcode = '23514'; end if;
  for l in select * from field_pay_lines where run_id = r.id and status = 'pending' and gross_cents > 0 order by statement_number loop
    perform app.field_pay_line_paid(p_by, jsonb_build_object('line_id', l.id, 'method', p ->> 'method', 'paid_on', p ->> 'paid_on', 'note', p ->> 'note',
      'reference', case when nullif(btrim(coalesce(p ->> 'reference', '')), '') is null then null else btrim(p ->> 'reference') || ' ' || l.statement_number end));
    n := n + 1;
  end loop;
  return jsonb_build_object('run_id', r.id, 'paid', n);
end $$;

-- An Admin sets a person's monthly salary (empty: the role's default). p: {staff, monthly_cents, currency, reason}
create function app.payroll_salary_set(p_by uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  v_staff uuid := nullif(p ->> 'staff', '')::uuid;
  v_amt integer := nullif(p ->> 'monthly_cents', '')::integer;
  v_cur text := nullif(p ->> 'currency', '');
  b staff_profiles;
begin
  perform app.assert_admin(p_by);
  select * into b from staff_profiles where user_id = v_staff and staff_type = 'va';
  if b.user_id is null then raise exception 'Choose an office staff member' using errcode = '22023'; end if;
  if v_amt is not null and (v_amt < 100 or v_amt > 5000000) then raise exception 'A monthly salary is between 1.00 and 50,000.00' using errcode = '22023'; end if;
  if v_cur is not null and v_cur not in ('USD', 'CAD') then raise exception 'The currency is USD or CAD' using errcode = '22023'; end if;
  if length(btrim(coalesce(p ->> 'reason', ''))) < 3 then raise exception 'Say why the salary changes' using errcode = '22023'; end if;
  update staff_profiles set monthly_salary_cents = v_amt, salary_currency = v_cur where user_id = v_staff;
  insert into audit_log (actor_user_id, action, entity_table, entity_id, before, after)
  values (p_by, 'payroll_salary_set', 'staff_profiles', v_staff::text, jsonb_build_object('monthly_salary_cents', b.monthly_salary_cents, 'salary_currency', b.salary_currency),
          jsonb_build_object('monthly_salary_cents', v_amt, 'salary_currency', v_cur, 'reason', btrim(p ->> 'reason')));
  return jsonb_build_object('staff', v_staff, 'monthly_cents', app.pay_salary_monthly(v_staff), 'currency', app.pay_salary_currency(v_staff));
end $$;

-- ================================================================ reads
create function app.payroll_line_json(l field_pay_lines) returns jsonb
language sql stable security definer set search_path = public, app as $$
  select jsonb_build_object('id', l.id, 'staff_id', l.staff_id, 'name', (select coalesce(u.full_name, u.email) from users u where u.id = l.staff_id),
    'kind', case when l.salary_cents > 0 or l.monthly_salary_cents is not null then 'salary' else 'hourly' end, 'currency', l.currency,
    'rate_cents', l.rate_cents, 'minutes_total', l.minutes_total, 'clock_minutes', l.clock_minutes, 'wage_cents', l.wage_cents + l.overtime_cents,
    'salary_cents', l.salary_cents, 'monthly_salary_cents', l.monthly_salary_cents, 'salary_days', l.salary_days,
    'commission_cents', l.commission_cents, 'vacation_cents', l.vacation_cents, 'adjustment_cents', l.adjustment_cents, 'adjustment_note', l.adjustment_note,
    'gross_cents', l.gross_cents, 'status', l.status, 'statement_number', l.statement_number, 'paid_on', l.paid_on, 'method', l.method, 'reference', l.reference,
    'emailed_at', l.emailed_at)
$$;

-- Finance and Admin: the payroll of the period holding p.date (default the last finished period)
create function app.payroll_read(p_by uuid, p jsonb) returns jsonb
language plpgsql stable security definer set search_path = public, app as $$
declare
  v_on date := coalesce(nullif(p ->> 'date', '')::date, app.today() - 14);
  per record;
  r field_pay_runs;
  s program_settings := app.settings();
begin
  if not app.payroll_may_prepare(p_by) then raise exception 'Only Finance or an Admin see the payroll' using errcode = '42501'; end if;
  select * into per from app.fp_period(v_on);
  select * into r from field_pay_runs where period_start = per.period_start and status <> 'void';
  return jsonb_build_object('today', app.today(), 'admin', app.user_is_admin(p_by),
    'period', jsonb_build_object('start', per.period_start, 'end', per.period_end, 'label', app.fp_period_label(per.period_start), 'ended', per.period_end < app.today(),
                                 'prev', per.period_start - 14, 'next', case when per.period_start + 14 <= app.today() then per.period_start + 14 end),
    'run', case when r.id is not null then jsonb_build_object('id', r.id, 'status', r.status, 'approved_at', r.approved_at, 'prepared_at', r.prepared_at,
             'approved_by', (select coalesce(u.full_name, u.email) from users u where u.id = r.approved_by),
             'prepared_by', (select coalesce(u.full_name, u.email) from users u where u.id = r.prepared_by)) end,
    'lines', coalesce((select jsonb_agg(app.payroll_line_json(l) order by (select coalesce(u.full_name, u.email) from users u where u.id = l.staff_id)) from field_pay_lines l where l.run_id = r.id), '[]'::jsonb),
    'totals', coalesce((select jsonb_agg(jsonb_build_object('currency', l.currency, 'gross_cents', sum_g, 'people', n) order by l.currency)
                          from (select currency, sum(gross_cents) sum_g, count(*) n from field_pay_lines where run_id = r.id group by currency) l), '[]'::jsonb),
    'adjustments', coalesce((select jsonb_agg(jsonb_build_object('id', a.id, 'staff_id', a.staff_id, 'name', (select coalesce(u.full_name, u.email) from users u where u.id = a.staff_id),
                    'amount_cents', a.amount_cents, 'reason', a.reason, 'by', (select coalesce(u.full_name, u.email) from users u where u.id = a.created_by), 'at', a.created_at) order by a.created_at)
                    from pay_adjustments a where a.run_id = r.id and a.removed_at is null), '[]'::jsonb),
    'salaried', coalesce((select jsonb_agg(jsonb_build_object('id', sp.user_id, 'name', coalesce(u.full_name, u.email),
                    'functions', to_jsonb(array(select f from unnest(sp.functions) f where f in ('cs', 'fleet', 'finance'))),
                    'monthly_cents', app.pay_salary_monthly(sp.user_id), 'own', sp.monthly_salary_cents is not null, 'currency', app.pay_salary_currency(sp.user_id),
                    'biweekly_cents', round(app.pay_salary_monthly(sp.user_id) * 12 / 26.0)::bigint) order by coalesce(u.full_name, u.email))
                    from staff_profiles sp join users u on u.id = sp.user_id
                   where sp.staff_type = 'va' and sp.is_active and sp.functions && array['cs', 'fleet', 'finance']), '[]'::jsonb),
    'staff', coalesce((select jsonb_agg(jsonb_build_object('id', sp.user_id, 'name', coalesce(u.full_name, u.email)) order by coalesce(u.full_name, u.email))
                    from staff_profiles sp join users u on u.id = sp.user_id where sp.is_active), '[]'::jsonb),
    'settings', jsonb_build_object('va_salary_defaults', s.va_salary_defaults, 'va_salary_currency', s.va_salary_currency),
    'periods', (select coalesce(jsonb_agg(jsonb_build_object('start', g.s, 'label', app.fp_period_label(g.s),
                    'run_status', (select z.status from field_pay_runs z where z.period_start = g.s and z.status <> 'void'),
                    'prepared', (select z.prepared_at is not null from field_pay_runs z where z.period_start = g.s and z.status <> 'void')) order by g.s desc), '[]'::jsonb)
                  from (select per.period_start - 14 * k as s from generate_series(-1, 7) k) g where g.s <= app.today()));
end $$;

-- a staff member's own pay stubs (approved and paid runs), for every portal
create function app.my_pay_stubs(p_by uuid, p jsonb default '{}'::jsonb) returns jsonb
language sql stable security definer set search_path = public, app as $$
  select jsonb_build_object('stubs', coalesce((select jsonb_agg(app.payroll_line_json(l) || jsonb_build_object('period_label', app.fp_period_label(r.period_start),
             'period_start', r.period_start, 'run_status', r.status) order by r.period_start desc)
           from field_pay_lines l join field_pay_runs r on r.id = l.run_id where l.staff_id = p_by and r.status in ('approved', 'paid')), '[]'::jsonb),
    'salary', case when exists (select 1 from staff_profiles sp where sp.user_id = p_by and sp.staff_type = 'va') then
      jsonb_build_object('monthly_cents', app.pay_salary_monthly(p_by), 'currency', app.pay_salary_currency(p_by),
                         'biweekly_cents', round(app.pay_salary_monthly(p_by) * 12 / 26.0)::bigint) end,
    'period', (select jsonb_build_object('start', x.period_start, 'end', x.period_end, 'label', app.fp_period_label(x.period_start)) from app.fp_period(app.today()) x))
$$;

-- the pay statement (PDF): the salary, the adjustments, the currency and an office staff member's clocked hours
alter function app.pdf_facts(text, text, uuid) rename to pdf_facts_pre1503;
create function app.pdf_facts(p_kind text, p_key text, p_user uuid default null) returns jsonb
language plpgsql stable security definer set search_path = public, app as $$
declare
  v jsonb := app.pdf_facts_pre1503(p_kind, p_key, p_user);
  l field_pay_lines;
  r field_pay_runs;
begin
  if p_kind <> 'pay_statement' or v is null then return v; end if;
  select * into l from field_pay_lines where id = app.file_key_id(p_key);
  if l.id is null then return v; end if;
  select * into r from field_pay_runs where id = l.run_id;
  v := v || jsonb_build_object('currency', l.currency, 'salary_cents', l.salary_cents, 'monthly_salary_cents', l.monthly_salary_cents, 'salary_days', l.salary_days,
    'adjustment_cents', l.adjustment_cents, 'adjustment_note', l.adjustment_note, 'clock_minutes', l.clock_minutes,
    'adjustments', coalesce((select jsonb_agg(jsonb_build_object('amount_cents', a.amount_cents, 'reason', a.reason) order by a.created_at)
                               from pay_adjustments a where a.run_id = l.run_id and a.staff_id = l.staff_id and a.removed_at is null), '[]'::jsonb));
  if l.salary_cents > 0 or l.monthly_salary_cents is not null then
    v := v || jsonb_build_object('shifts', coalesce((select jsonb_agg(jsonb_build_object('day', app.local_date(e.started_at), 'from', e.started_at, 'to', e.ended_at,
                  'minutes', app.va_clock_minutes(e), 'note', e.note) order by e.started_at)
                  from staff_clock_entries e where e.user_id = l.staff_id and e.voided_at is null and e.ended_at is not null
                   and app.local_date(e.started_at) between r.period_start and r.period_end), '[]'::jsonb));
  end if;
  return v;
end $$;
select pg_temp.copy_grants('app.pdf_facts(text, text, uuid)'::regprocedure, 'app.pdf_facts_pre1503(text, text, uuid)'::regprocedure);


-- the pay statement email: an office staff member too (0165 sent it to field staff only), with the salary, the adjustments
-- and the currency in its lines
alter function app.notification_recipients(app_events, notification_catalogue) rename to notification_recipients_pre1503;
create function app.notification_recipients(p_event app_events, p_c notification_catalogue)
returns table (audience text, user_id uuid, email text, name text, renter_id uuid, owner_id uuid, immediate boolean)
language plpgsql stable security definer set search_path = public, app as $$
begin
  if p_c.code = 'staff_pay_statement' and exists (select 1 from staff_profiles sp where sp.user_id = (p_event.payload ->> 'staff_id')::uuid and sp.staff_type = 'va') then
    return query select 'staff_field'::text, u.id, u.email, u.full_name, null::uuid, null::uuid, true
                   from users u where u.id = (p_event.payload ->> 'staff_id')::uuid and u.email is not null;
    return;
  end if;
  return query select * from app.notification_recipients_pre1503(p_event, p_c);
end $$;
select pg_temp.copy_grants('app.notification_recipients(app_events, notification_catalogue)'::regprocedure, 'app.notification_recipients_pre1503(app_events, notification_catalogue)'::regprocedure);

create function app.pay_money(p_cents bigint, p_currency text) returns text
language sql stable security definer set search_path = public, app as $$
  select case when p_currency = 'USD' then 'US' else '' end || app.fmt_money(p_cents)
$$;

alter function app.notification_payload(text, app_events, jsonb) rename to ntf_payload_pre1503;
create function app.notification_payload(p_code text, p_event app_events, p_to jsonb) returns jsonb
language plpgsql stable security definer set search_path = public, app as $$
declare
  x jsonb := app.ntf_payload_pre1503(p_code, p_event, p_to);
  l field_pay_lines;
begin
  if p_code <> 'staff_pay_statement' then return x; end if;
  select * into l from field_pay_lines where id = p_event.entity_id;
  if l.id is null or (l.salary_cents = 0 and l.monthly_salary_cents is null and l.adjustment_cents = 0 and l.currency = 'CAD') then return x; end if;
  return coalesce(x, '{}'::jsonb) || jsonb_build_object('gross_total', app.pay_money(l.gross_cents, l.currency),
    'hours_total', app.fp_hours_text(greatest(l.minutes_total, l.clock_minutes)),
    'pay_lines', (select jsonb_agg(z) from (
        select jsonb_build_object('what', 'Salary for the two weeks (monthly ' || app.pay_money(l.monthly_salary_cents, l.currency) || ' x 12 / 26'
                 || case when coalesce(l.salary_days, 14) < 14 then ', ' || l.salary_days || ' of 14 days' else '' end || ')', 'amount', app.pay_money(l.salary_cents, l.currency)) as z
         where l.salary_cents > 0
        union all select jsonb_build_object('what', 'Hours: ' || app.fp_hours_text(l.minutes_regular) || ' at ' || app.fmt_money(l.rate_cents), 'amount', app.pay_money(l.wage_cents, l.currency)) where l.wage_cents > 0
        union all select jsonb_build_object('what', 'Overtime: ' || app.fp_hours_text(l.minutes_overtime), 'amount', app.pay_money(l.overtime_cents, l.currency)) where l.minutes_overtime > 0
        union all select jsonb_build_object('what', 'Commissions', 'amount', app.pay_money(l.commission_cents, l.currency)) where l.commission_cents > 0
        union all select jsonb_build_object('what', 'Vacation pay', 'amount', app.pay_money(l.vacation_cents, l.currency)) where l.vacation_cents > 0
        union all select jsonb_build_object('what', 'Adjustment: ' || coalesce(l.adjustment_note, ''), 'amount', app.pay_money(l.adjustment_cents, l.currency)) where l.adjustment_cents <> 0) q));
end $$;
select pg_temp.copy_grants('app.notification_payload(text, app_events, jsonb)'::regprocedure, 'app.ntf_payload_pre1503(text, app_events, jsonb)'::regprocedure);

alter function app.door(uuid, text, text, text, jsonb) rename to door_pre1503;
create function app.door(p_user uuid, p_aal text, p_call text, p_name text, p jsonb default '{}'::jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare p_ jsonb := coalesce(p, '{}'::jsonb) - '_va';
begin
  if (p_call in ('ops_read', 'admin_read') and p_name in ('payroll', 'my_pay_stubs'))
     or (p_call in ('ops_do', 'admin_do') and p_name in ('payroll_adjust', 'payroll_submit', 'payroll_pay_all', 'payroll_salary_set')) then
    perform app.door_begin(p_user, p_aal);
    return case p_name when 'payroll' then app.payroll_read(p_user, p_) when 'my_pay_stubs' then app.my_pay_stubs(p_user, p_)
                       when 'payroll_adjust' then app.payroll_adjust(p_user, p_) when 'payroll_submit' then app.payroll_submit(p_user, p_)
                       when 'payroll_pay_all' then app.payroll_pay_all(p_user, p_) else app.payroll_salary_set(p_user, p_) end;
  end if;
  return app.door_pre1503(p_user, p_aal, p_call, p_name, p);
end $$;

do $$
declare f record;
begin
  for f in select p.oid::regprocedure as sig from pg_proc p join pg_namespace n on n.oid = p.pronamespace
            where n.nspname = 'app' and p.proname = any (array['pay_salary_monthly', 'pay_salary_currency', 'pay_salary_period', 'pay_clock_minutes', 'payroll_may_prepare',
                    'payroll_adjust', 'payroll_submit', 'payroll_pay_all', 'payroll_salary_set', 'payroll_line_json', 'payroll_read', 'my_pay_stubs', 'pay_money', 'door_pre1503', 'door'])
  loop
    execute format('revoke all on function %s from public, anon, authenticated', f.sig);
    execute format('grant execute on function %s to service_role', f.sig);
  end loop;
end $$;
