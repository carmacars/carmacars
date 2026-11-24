-- 3480 (release 49, finance): the Finance dashboard and bank reconciliation (docs/finance/bank-data.md,
-- docs/changes/2026-11-23-r49-finance.md). The owner (Nov 20): "RBC new account may have API access for payouts and
-- balances: check, then build a finance dashboard."
--
-- 1. The bank: bank_accounts (only the last four digits and a SHA-256 of the full number are kept), bank_imports (one row
--    per file or feed pull), bank_balances (the balance from an OFX file, a CSV balance column, typed in, or a feed) and
--    bank_lines (each transaction once). app.bank_import takes the lines the browser read from RBC's CSV or OFX download
--    (web/src/features/finance/bank-file.ts) or a feed (web/src/integrations/bank), and keeps each line once:
--    the key is the day, the amount and the line's place among the same day's lines of that amount in the file, so the
--    same file twice, two overlapping downloads, or a CSV after an OFX of the same days add nothing.
-- 2. Reconciliation: a new line is matched when exactly one record fits (app.bank_candidates): money in to a Stripe payout
--    or a payment received by e-Transfer, bank transfer or cheque, or an insurer invoice; money out to an owner payout, a
--    staff commission payout, a referral partner payout, an expense or a refund sent by transfer. Each record is matched to
--    one line at most. The rest is matched by hand (bank_line_match) or set aside with a reason (a bank fee, a transfer
--    between CarmaCars accounts). A line still unmatched after finance_bank_unmatched_days is a To do for Finance
--    (bank_unmatched) and the staff notice staff_bank_line_unmatched (the Finance morning digest and the staff bell; Admins
--    as well). Matching or setting it aside closes the To do.
-- 3. The dashboard (finance_dashboard): cash position (bank and, from the server, Stripe), money in, money out, HST
--    collected against HST paid (an Insurance Fee never carries HST: a line that does is listed as a problem), deposits
--    held, renter balances overdue, insurer invoices unpaid by age, twelve months of money in and out, and the
--    reconciliation. Admin and Finance only (app.user_runs_finance); every table is read only to them by row-level
--    security, written only through these functions, and audited.
-- SCHEMA_MARKER 3480. No applied migration is edited.
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

-- ================================================================ settings
alter table program_settings add column if not exists finance_bank_unmatched_days integer not null default 2 check (finance_bank_unmatched_days between 0 and 30);
alter table program_settings add column if not exists finance_bank_todo_window_days integer not null default 60 check (finance_bank_todo_window_days between 1 and 400);
alter table program_settings add column if not exists finance_match_window_days integer not null default 4 check (finance_match_window_days between 0 and 30);
alter table program_settings add column if not exists bank_data_provider text not null default 'file'
  check (bank_data_provider in ('file', 'fake', 'rbc_api', 'flinks', 'plaid', 'cdb'));
comment on column program_settings.finance_bank_unmatched_days is 'Finance (3480): a bank line still unmatched this many days after it posted is a To do for Finance.';
comment on column program_settings.finance_bank_todo_window_days is 'Finance (3480): only lines posted within this many days become To dos (an old history import does not flood the list).';
comment on column program_settings.finance_match_window_days is 'Finance (3480): a bank line matches a record dated up to this many days before or after it.';
comment on column program_settings.bank_data_provider is 'Finance (3480): where bank lines come from. file: CSV or OFX downloads from online banking (always available). The others are live feeds (docs/finance/bank-data.md).';

-- ================================================================ tables
create table if not exists bank_accounts (
  id            uuid primary key default gen_random_uuid(),
  institution   text not null default 'rbc' check (institution ~ '^[a-z0-9_]{2,20}$'),
  nickname      text not null check (length(btrim(nickname)) between 1 and 60),
  account_last4 text not null check (account_last4 ~ '^[0-9]{3,4}$'),
  account_hash  text check (account_hash ~ '^[0-9a-f]{64}$'),
  currency      text not null default 'CAD' check (currency in ('CAD', 'USD')),
  provider      text not null default 'file' check (provider in ('file', 'fake', 'rbc_api', 'flinks', 'plaid', 'cdb')),
  provider_ref  text check (provider_ref is null or length(provider_ref) <= 200),
  active        boolean not null default true,
  created_by    uuid references users (id),
  created_at    timestamptz not null default now(),
  unique (institution, account_hash, currency)
);
comment on table bank_accounts is 'A CarmaCars bank account (3480). Only the last four digits and a SHA-256 of the full number are kept; provider_ref is a feed''s account id, never a credential.';

create table if not exists bank_imports (
  id              uuid primary key default gen_random_uuid(),
  bank_account_id uuid not null references bank_accounts (id),
  source          text not null check (source in ('csv', 'ofx', 'api')),
  file_name       text check (file_name is null or length(file_name) <= 200),
  file_sha256     text check (file_sha256 is null or file_sha256 ~ '^[0-9a-f]{64}$'),
  lines_in        integer not null default 0,
  lines_new       integer not null default 0,
  lines_duplicate integer not null default 0,
  lines_matched   integer not null default 0,
  first_on        date,
  last_on         date,
  imported_by     uuid references users (id),
  created_at      timestamptz not null default now(),
  unique (bank_account_id, file_sha256)
);
create index if not exists bank_imports_account_idx on bank_imports (bank_account_id, created_at desc);
comment on table bank_imports is 'One bank file or feed pull (3480): how many lines it had, how many were new, duplicates and matched at once.';

create table if not exists bank_balances (
  id              uuid primary key default gen_random_uuid(),
  bank_account_id uuid not null references bank_accounts (id),
  as_of           date not null,
  balance_cents   bigint not null,
  available_cents bigint,
  source          text not null check (source in ('ofx', 'csv', 'typed', 'api')),
  import_id       uuid references bank_imports (id),
  recorded_by     uuid references users (id),
  created_at      timestamptz not null default now()
);
create index if not exists bank_balances_account_idx on bank_balances (bank_account_id, as_of desc, created_at desc);
create index if not exists bank_balances_import_idx on bank_balances (import_id);
comment on table bank_balances is 'A bank balance as at a day (3480): from an OFX file, a CSV balance column, typed in from online banking, or a feed.';

create table if not exists bank_lines (
  id              uuid primary key default gen_random_uuid(),
  bank_account_id uuid not null references bank_accounts (id),
  import_id       uuid not null references bank_imports (id),
  posted_on       date not null,
  amount_cents    bigint not null check (amount_cents <> 0),
  description     text not null default '' check (length(description) <= 300),
  cheque_number   text check (cheque_number is null or length(cheque_number) <= 30),
  fit_id          text check (fit_id is null or length(fit_id) <= 120),
  running_balance_cents bigint,
  dedupe_key      text not null,
  status          text not null default 'unmatched' check (status in ('unmatched', 'matched', 'ignored')),
  match_kind      text check (match_kind in ('stripe_payout', 'payment', 'insurer_invoice', 'owner_payout', 'commission_payout', 'partner_payout', 'expense', 'refund')),
  matched_table   text check (matched_table in ('payout_reconciliations', 'manual_payments', 'insurer_invoices', 'payouts', 'staff_commission_payouts', 'referral_partner_payouts', 'company_expenses', 'payments')),
  matched_id      uuid,
  matched_auto    boolean not null default false,
  matched_by      uuid references users (id),
  matched_at      timestamptz,
  note            text check (note is null or length(note) <= 500),
  todo_task_id    uuid references tasks (id),
  created_at      timestamptz not null default now(),
  unique (bank_account_id, dedupe_key),
  check ((status = 'matched') = (matched_id is not null)),
  check ((matched_id is null) = (matched_table is null) and (matched_id is null) = (match_kind is null)),
  check (status <> 'ignored' or nullif(btrim(coalesce(note, '')), '') is not null)
);
create index if not exists bank_lines_account_idx on bank_lines (bank_account_id, posted_on desc);
create index if not exists bank_lines_import_idx on bank_lines (import_id);
create index if not exists bank_lines_todo_idx on bank_lines (todo_task_id);
create index if not exists bank_lines_open_idx on bank_lines (posted_on) where status = 'unmatched';
create unique index if not exists bank_lines_target_once on bank_lines (matched_table, matched_id) where status = 'matched';
comment on table bank_lines is 'A bank transaction (3480), once. Positive is money in. Matched to the record it is, set aside with a reason, or a To do for Finance.';

do $$
declare t text;
begin
  foreach t in array array['bank_accounts', 'bank_imports', 'bank_balances', 'bank_lines'] loop
    execute format('create trigger audit_%1$s after insert or update or delete on %1$I for each row execute function app.audit_row()', t);
    execute format('alter table %I enable row level security', t);
    execute format('create policy admin_all on %I for select to authenticated using (app.is_admin())', t);
    execute format('create policy finance_read on %I for select to authenticated using (app.va_has(''finance''))', t);
    execute format('revoke all on %I from public, anon, authenticated', t);
    execute format('grant select on %I to authenticated', t);
    execute format('grant all on %I to service_role', t);
  end loop;
end $$;

insert into task_rules (task_type, queue, title, priority, due_kind, due_amount, procedure_no, completion_rule, description) values
  ('bank_unmatched', 'finance', 'A bank line has no match', 'normal', 'business_days', 1, 2, 'bank_line_matched_or_set_aside',
   'A line on the bank statement matches no payout, payment, invoice or expense (3480). Finance: Money > Finance, Bank lines: match it to its record, record what it is, or set it aside with the reason (a bank fee, a transfer between CarmaCars accounts).')
on conflict (task_type) do nothing;

-- ================================================================ the records a bank line may be
create or replace function app.bank_candidates(p_line uuid, p_window integer default null) returns table (
  kind text, tbl text, id uuid, label text, amount_cents bigint, on_date date)
language plpgsql stable security definer set search_path = public, app, pg_temp as $$
declare
  l bank_lines;
  w integer;
  a bigint;
begin
  select * into l from bank_lines x where x.id = p_line;
  if l.id is null then return; end if;
  w := coalesce(p_window, (app.settings()).finance_match_window_days, 4);
  a := abs(l.amount_cents);
  if l.amount_cents > 0 then
    return query
    select 'stripe_payout', 'payout_reconciliations', pr.id, 'Stripe payout ' || pr.processor_payout_ref, pr.amount_cents, pr.paid_on
      from payout_reconciliations pr
     where pr.amount_cents = a and abs(pr.paid_on - l.posted_on) <= w
    union all
    select 'payment', 'manual_payments', mp.id,
           initcap(replace(mp.method, '_', '-')) || coalesce(' ' || mp.reference, '') || ' · ' ||
             coalesce((select 'booking ' || b.booking_number from bookings b where b.id = mp.booking_id),
                      (select 'invoice ' || oi.invoice_number from owner_invoices oi where oi.id = mp.owner_invoice_id), 'payment'),
           mp.amount_cents, mp.received_on
      from manual_payments mp
     where mp.voided_at is null and mp.method in ('e_transfer', 'bank_transfer', 'cheque') and mp.amount_cents = a
       and abs(mp.received_on - l.posted_on) <= w
    union all
    select 'insurer_invoice', 'insurer_invoices', ii.id, 'Insurer invoice ' || ii.invoice_number || ' · ' || coalesce(ins.name, 'insurer'),
           ii.total_cents, app.local_date(ii.sent_at)
      from insurer_invoices ii left join insurers ins on ins.id = ii.insurer_id
     where ii.status in ('sent', 'part_paid', 'paid') and ii.sent_at is not null and app.local_date(ii.sent_at) <= l.posted_on
       and (ii.balance_cents = a or (ii.status = 'paid' and ii.total_cents = a) or (ii.status = 'part_paid' and ii.paid_cents = a));
  else
    return query
    select 'owner_payout', 'payouts', po.id,
           initcap(replace(po.payee_type, '_', ' ')) || ' payout · ' ||
             coalesce((select o.legal_name from owners o where o.id = po.owner_id), (select u.full_name from users u where u.id = po.staff_user_id), 'payee'),
           po.amount_cents, coalesce(app.local_date(po.paid_at), po.scheduled_for)
      from payouts po
     where po.status in ('approved', 'sent', 'paid') and po.amount_cents = a
       and abs(coalesce(app.local_date(po.paid_at), po.scheduled_for) - l.posted_on) <= w
    union all
    select 'commission_payout', 'staff_commission_payouts', sc.id, 'Commission payout · ' || coalesce(u.full_name, 'staff'), sc.amount_cents, sc.paid_on
      from staff_commission_payouts sc left join users u on u.id = sc.staff_id
     where sc.method in ('e_transfer', 'bank_transfer') and sc.amount_cents = a and abs(sc.paid_on - l.posted_on) <= w
    union all
    select 'partner_payout', 'referral_partner_payouts', rp.id, 'Referral partner payout' || coalesce(' · ' || rp.reference, ''), rp.amount_cents, rp.paid_on
      from referral_partner_payouts rp
     where rp.method in ('e_transfer', 'bank_transfer', 'cheque') and rp.amount_cents = a and abs(rp.paid_on - l.posted_on) <= w
    union all
    select 'expense', 'company_expenses', ce.id, 'Expense · ' || ce.description, ce.amount_cents + ce.hst_cents, ce.expense_on
      from company_expenses ce
     where ce.voided_at is null and ce.amount_cents + ce.hst_cents = a and abs(ce.expense_on - l.posted_on) <= w
    union all
    select 'refund', 'payments', p.id, 'Refund by ' || replace(p.method, '_', '-') || coalesce(' · booking ' || b.booking_number, ''), p.amount_cents, app.local_date(p.processed_at)
      from payments p left join bookings b on b.id = p.booking_id
     where p.kind = 'refund' and p.status = 'succeeded' and p.method in ('e_transfer', 'bank_transfer') and p.amount_cents = a
       and p.processed_at is not null and abs(app.local_date(p.processed_at) - l.posted_on) <= w;
  end if;
end $$;

-- the candidates no other line is matched to, nearest date first
create or replace function app.bank_free_candidates(p_line uuid) returns jsonb
language sql stable security definer set search_path = public, app, pg_temp as $$
  select coalesce(jsonb_agg(jsonb_build_object('kind', c.kind, 'table', c.tbl, 'id', c.id, 'label', c.label, 'amount_cents', c.amount_cents, 'on', c.on_date)
                            order by abs(c.on_date - l.posted_on), c.label), '[]'::jsonb)
    from bank_lines l, app.bank_candidates(l.id) c
   where l.id = p_line
     and not exists (select 1 from bank_lines o where o.status = 'matched' and o.matched_table = c.tbl and o.matched_id = c.id and o.id <> l.id)
$$;

-- a line matched when exactly one record fits
create or replace function app.bank_auto_match(p_line uuid) returns boolean
language plpgsql security definer set search_path = public, app, pg_temp as $$
declare
  c jsonb := app.bank_free_candidates(p_line);
begin
  if jsonb_array_length(c) <> 1 then return false; end if;
  update bank_lines set status = 'matched', match_kind = c -> 0 ->> 'kind', matched_table = c -> 0 ->> 'table', matched_id = (c -> 0 ->> 'id')::uuid,
                        matched_auto = true, matched_at = now(), matched_by = null
   where id = p_line and status = 'unmatched';
  return found;
exception when unique_violation then
  return false;
end $$;

-- a matched or set-aside line closes its To do
create or replace function app.bank_line_close_todo(p_line uuid, p_by uuid, p_note text) returns void
language sql security definer set search_path = public, app, pg_temp as $$
  update tasks set status = 'done', completed_at = now(), completed_by = p_by, completion_note = p_note, wake_at = null
   where id = (select todo_task_id from bank_lines where id = p_line) and status in ('open', 'in_progress', 'waiting')
$$;

-- ================================================================ import
create or replace function app.bank_account_find(p_by uuid, p jsonb) returns bank_accounts
language plpgsql security definer set search_path = public, app, pg_temp as $$
declare
  a bank_accounts;
  v_last4 text := nullif(regexp_replace(coalesce(p ->> 'last4', ''), '\D', '', 'g'), '');
  v_hash text := nullif(lower(coalesce(p ->> 'hash', '')), '');
  v_cur text := upper(coalesce(nullif(p ->> 'currency', ''), 'CAD'));
begin
  if nullif(p ->> 'id', '') is not null then
    select * into a from bank_accounts where id = (p ->> 'id')::uuid;
    if a.id is null then raise exception 'Bank account not found' using errcode = 'P0002'; end if;
    return a;
  end if;
  if v_hash is not null then select * into a from bank_accounts where account_hash = v_hash and currency = v_cur and institution = coalesce(nullif(p ->> 'institution', ''), 'rbc'); end if;
  if a.id is null and v_hash is null and v_last4 is not null then
    select * into a from bank_accounts where account_last4 = right(v_last4, 4) and currency = v_cur and active order by created_at limit 1;
  end if;
  if a.id is null then
    if v_last4 is null then raise exception 'The file does not name the account: choose it, or give its last four digits' using errcode = '22023'; end if;
    insert into bank_accounts (institution, nickname, account_last4, account_hash, currency, created_by)
    values (coalesce(nullif(p ->> 'institution', ''), 'rbc'), coalesce(nullif(btrim(p ->> 'nickname'), ''), 'RBC ' || v_cur || ' ' || right(v_last4, 4)),
            right(v_last4, 4), v_hash, v_cur, p_by)
    returning * into a;
  end if;
  return a;
end $$;

-- p: {account: {id | last4, hash, currency, nickname}, source: csv | ofx | api, file_name, file_sha256,
--     balance_cents, balance_on, balance_source, lines: [{posted_on, amount_cents, description, cheque_number, fit_id, balance_cents}]}
create or replace function app.bank_import(p_by uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app, pg_temp as $$
declare
  a bank_accounts;
  v_src text := coalesce(nullif(p ->> 'source', ''), 'csv');
  v_sha text := nullif(lower(coalesce(p ->> 'file_sha256', '')), '');
  v_imp bank_imports;
  v_n integer;
  v_new integer := 0;
  v_matched integer := 0;
  v_bal bigint := nullif(p ->> 'balance_cents', '')::bigint;
  v_bal_on date := nullif(p ->> 'balance_on', '')::date;
  r record;
begin
  if not app.user_runs_finance(p_by) then raise exception 'Finance or an Admin imports bank lines' using errcode = '42501'; end if;
  if v_src not in ('csv', 'ofx', 'api') then raise exception 'Unknown source %', v_src using errcode = '22023'; end if;
  if jsonb_typeof(p -> 'lines') is distinct from 'array' then raise exception 'No lines in the file' using errcode = '22023'; end if;
  v_n := jsonb_array_length(p -> 'lines');
  if v_n > 5000 then raise exception 'At most 5,000 lines at a time: download a shorter period' using errcode = '22023'; end if;
  a := app.bank_account_find(p_by, coalesce(p -> 'account', '{}'::jsonb));
  if v_sha is not null then
    select * into v_imp from bank_imports where bank_account_id = a.id and file_sha256 = v_sha;
    if v_imp.id is not null then
      return jsonb_build_object('ok', true, 'repeat', true, 'import_id', v_imp.id, 'account_id', a.id, 'lines_in', v_imp.lines_in, 'lines_new', 0, 'lines_duplicate', v_imp.lines_in, 'lines_matched', 0);
    end if;
  end if;
  -- every line is checked before anything is written
  if exists (select 1 from jsonb_array_elements(p -> 'lines') x
              where nullif(x ->> 'posted_on', '') is null or (x ->> 'posted_on') !~ '^\d{4}-\d{2}-\d{2}$'
                 or coalesce(x ->> 'amount_cents', '') !~ '^-?\d{1,12}$' or (x ->> 'amount_cents')::bigint = 0) then
    raise exception 'A line has no date or no amount: check the file is the account''s transaction download' using errcode = '22023';
  end if;
  if exists (select 1 from jsonb_array_elements(p -> 'lines') x where (x ->> 'posted_on')::date > app.today() + 1) then
    raise exception 'A line is dated in the future' using errcode = '22023';
  end if;
  insert into bank_imports (bank_account_id, source, file_name, file_sha256, lines_in, imported_by,
                            first_on, last_on)
  values (a.id, v_src, left(nullif(btrim(p ->> 'file_name'), ''), 200), v_sha, v_n, p_by,
          (select min((x ->> 'posted_on')::date) from jsonb_array_elements(p -> 'lines') x),
          (select max((x ->> 'posted_on')::date) from jsonb_array_elements(p -> 'lines') x))
  returning * into v_imp;
  for r in
    with x as (
      select e.v, e.o, (e.v ->> 'posted_on')::date as d, (e.v ->> 'amount_cents')::bigint as amt
        from jsonb_array_elements(p -> 'lines') with ordinality e(v, o))
    select x.*, row_number() over (partition by x.d, x.amt order by x.o) as k from x order by x.o
  loop
    insert into bank_lines (bank_account_id, import_id, posted_on, amount_cents, description, cheque_number, fit_id, running_balance_cents, dedupe_key)
    values (a.id, v_imp.id, r.d, r.amt, left(btrim(regexp_replace(coalesce(r.v ->> 'description', ''), '\s+', ' ', 'g')), 300),
            left(nullif(btrim(r.v ->> 'cheque_number'), ''), 30), left(nullif(btrim(r.v ->> 'fit_id'), ''), 120),
            nullif(r.v ->> 'balance_cents', '')::bigint, r.d || ':' || r.amt || ':' || r.k)
    on conflict (bank_account_id, dedupe_key) do nothing;
    if found then v_new := v_new + 1; end if;
  end loop;
  -- the balance: given by the file or typed; else a CSV's balance column on the last line
  if v_bal is null then
    select (x ->> 'balance_cents')::bigint, (x ->> 'posted_on')::date into v_bal, v_bal_on
      from jsonb_array_elements(p -> 'lines') with ordinality e(x, o)
     where nullif(x ->> 'balance_cents', '') is not null
     order by (x ->> 'posted_on')::date desc, o desc limit 1;
    if v_bal is not null then p := p || jsonb_build_object('balance_source', 'csv'); end if;
  end if;
  if v_bal is not null then
    insert into bank_balances (bank_account_id, as_of, balance_cents, available_cents, source, import_id, recorded_by)
    values (a.id, coalesce(v_bal_on, v_imp.last_on, app.today()), v_bal, nullif(p ->> 'available_cents', '')::bigint,
            case when p ->> 'balance_source' in ('ofx', 'csv', 'typed', 'api') then p ->> 'balance_source' when v_src = 'ofx' then 'ofx' when v_src = 'api' then 'api' else 'typed' end,
            v_imp.id, p_by);
  end if;
  for r in select id from bank_lines where import_id = v_imp.id and status = 'unmatched' order by posted_on, amount_cents loop
    if app.bank_auto_match(r.id) then v_matched := v_matched + 1; end if;
  end loop;
  update bank_imports set lines_new = v_new, lines_duplicate = v_n - v_new, lines_matched = v_matched where id = v_imp.id;
  insert into audit_log (actor_user_id, action, entity_table, entity_id, after)
  values (p_by, 'bank_import', 'bank_imports', v_imp.id::text,
          jsonb_build_object('account', a.id, 'source', v_src, 'lines_in', v_n, 'lines_new', v_new, 'matched', v_matched, 'balance_cents', v_bal));
  perform app.bank_unmatched_scan();
  return jsonb_build_object('ok', true, 'import_id', v_imp.id, 'account_id', a.id, 'account', a.nickname, 'lines_in', v_n, 'lines_new', v_new,
    'lines_duplicate', v_n - v_new, 'lines_matched', v_matched,
    'lines_unmatched', (select count(*) from bank_lines where import_id = v_imp.id and status = 'unmatched'),
    'balance_cents', v_bal, 'first_on', v_imp.first_on, 'last_on', v_imp.last_on);
end $$;

-- p: {account: {id}, balance_cents, as_of}: the balance typed from online banking
create or replace function app.bank_balance_set(p_by uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app, pg_temp as $$
declare
  a bank_accounts;
  v_on date := coalesce(nullif(p ->> 'as_of', '')::date, app.today());
  v_id uuid;
begin
  if not app.user_runs_finance(p_by) then raise exception 'Finance or an Admin records the balance' using errcode = '42501'; end if;
  if coalesce(p ->> 'balance_cents', '') !~ '^-?\d{1,12}$' then raise exception 'Enter the balance' using errcode = '22023'; end if;
  if v_on > app.today() then raise exception 'The balance date cannot be in the future' using errcode = '22023'; end if;
  a := app.bank_account_find(p_by, coalesce(p -> 'account', jsonb_build_object('id', p ->> 'account_id')));
  insert into bank_balances (bank_account_id, as_of, balance_cents, source, recorded_by)
  values (a.id, v_on, (p ->> 'balance_cents')::bigint, 'typed', p_by) returning id into v_id;
  insert into audit_log (actor_user_id, action, entity_table, entity_id, after)
  values (p_by, 'bank_balance_set', 'bank_balances', v_id::text, jsonb_build_object('account', a.id, 'as_of', v_on, 'balance_cents', (p ->> 'balance_cents')::bigint));
  return jsonb_build_object('ok', true, 'id', v_id);
end $$;

-- ================================================================ match by hand
-- p: {line, table, id, note} matches; {line, ignore: true, note} sets it aside; {line, unmatch: true, note} undoes either
create or replace function app.bank_line_match(p_by uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app, pg_temp as $$
declare
  l bank_lines;
  c jsonb;
  v_note text := nullif(btrim(coalesce(p ->> 'note', '')), '');
  v_hit jsonb;
begin
  if not app.user_runs_finance(p_by) then raise exception 'Finance or an Admin matches bank lines' using errcode = '42501'; end if;
  select * into l from bank_lines where id = nullif(p ->> 'line', '')::uuid for update;
  if l.id is null then raise exception 'Bank line not found' using errcode = 'P0002'; end if;
  if coalesce((p ->> 'unmatch')::boolean, false) then
    if l.status = 'unmatched' then return jsonb_build_object('ok', true, 'repeat', true); end if;
    if v_note is null then raise exception 'Say why it is undone' using errcode = '22023'; end if;
    -- undone, it is a To do again at the next scan (the closed one stays in the history)
    update bank_lines set status = 'unmatched', match_kind = null, matched_table = null, matched_id = null, matched_auto = false,
                          matched_by = p_by, matched_at = now(), note = v_note, todo_task_id = null where id = l.id;
    insert into audit_log (actor_user_id, action, entity_table, entity_id, before, after)
    values (p_by, 'bank_line_unmatch', 'bank_lines', l.id::text, jsonb_build_object('status', l.status, 'table', l.matched_table, 'id', l.matched_id), jsonb_build_object('note', v_note));
    return jsonb_build_object('ok', true, 'status', 'unmatched');
  end if;
  if l.status <> 'unmatched' then raise exception 'This line is already %: undo it first', l.status using errcode = '23514'; end if;
  if coalesce((p ->> 'ignore')::boolean, false) then
    if v_note is null or length(v_note) < 3 then raise exception 'Say what the line is (a bank fee, a transfer between CarmaCars accounts...)' using errcode = '22023'; end if;
    update bank_lines set status = 'ignored', matched_by = p_by, matched_at = now(), matched_auto = false, note = v_note where id = l.id;
  else
    c := app.bank_free_candidates(l.id);
    -- the record as {table, id}, or as one value "table:id" (the screen's list of the records that fit)
    select x into v_hit from jsonb_array_elements(c) x
     where x ->> 'table' = coalesce(nullif(p ->> 'table', ''), split_part(coalesce(p ->> 'pick', ''), ':', 1))
       and x ->> 'id' = coalesce(nullif(p ->> 'id', ''), split_part(coalesce(p ->> 'pick', ''), ':', 2));
    if v_hit is null then
      raise exception 'That record does not fit this line (amount, date, or it is matched to another line)' using errcode = '23514';
    end if;
    update bank_lines set status = 'matched', match_kind = v_hit ->> 'kind', matched_table = v_hit ->> 'table', matched_id = (v_hit ->> 'id')::uuid,
                          matched_auto = false, matched_by = p_by, matched_at = now(), note = coalesce(v_note, note) where id = l.id;
  end if;
  perform app.bank_line_close_todo(l.id, p_by, coalesce(v_note, 'Matched'));
  insert into audit_log (actor_user_id, action, entity_table, entity_id, before, after)
  values (p_by, case when coalesce((p ->> 'ignore')::boolean, false) then 'bank_line_ignore' else 'bank_line_match' end, 'bank_lines', l.id::text,
          jsonb_build_object('status', l.status), (select jsonb_build_object('status', x.status, 'table', x.matched_table, 'id', x.matched_id, 'note', x.note) from bank_lines x where x.id = l.id));
  return (select jsonb_build_object('ok', true, 'status', x.status, 'match_kind', x.match_kind) from bank_lines x where x.id = l.id);
end $$;

-- ================================================================ To dos and the staff notice
create or replace function app.bank_unmatched_scan(p_now timestamptz default now()) returns integer
language plpgsql security definer set search_path = public, app, pg_temp as $$
declare
  s program_settings := app.settings();
  v_today date := app.local_date(p_now);
  l record;
  v_task uuid;
  n integer := 0;
begin
  -- a record recorded after the import (a Stripe payout synced in the evening) matches now
  for l in select x.id from bank_lines x where x.status = 'unmatched' and x.posted_on >= v_today - coalesce(s.finance_bank_todo_window_days, 60) loop
    perform app.bank_auto_match(l.id);
  end loop;
  for l in
    select x.*, a.nickname, a.account_last4 from bank_lines x join bank_accounts a on a.id = x.bank_account_id
     where x.status = 'unmatched' and x.todo_task_id is null
       and x.posted_on <= v_today - coalesce(s.finance_bank_unmatched_days, 2)
       and x.posted_on >= v_today - coalesce(s.finance_bank_todo_window_days, 60)
     order by x.posted_on limit 200
  loop
    v_task := app.raise_task(p_type => 'bank_unmatched',
      p_title => format('Bank line with no match: %s %s on %s', case when l.amount_cents > 0 then 'in' else 'out' end, app.fmt_money(abs(l.amount_cents)), app.fmt_day(l.posted_on)),
      p_detail => format('%s (%s, ending %s). Money > Finance, Bank lines: match it, or set it aside with the reason.', nullif(l.description, ''), l.nickname, l.account_last4),
      p_related_table => 'bank_lines', p_related_id => l.id, p_dedupe => 'bank_unmatched:' || l.id, p_queue => 'finance');
    update bank_lines set todo_task_id = v_task where id = l.id;
    perform app.emit_event('staff_bank_line_unmatched', 'bank_line', l.id,
      jsonb_build_object('bank_line_id', l.id, 'amount_cents', l.amount_cents, 'posted_on', l.posted_on, 'description', l.description,
                         'account_name', l.nickname || ' ending ' || l.account_last4,
                         'candidate_count', jsonb_array_length(app.bank_free_candidates(l.id))),
      'staff_bank_line_unmatched:' || l.id);
    n := n + 1;
  end loop;
  return n;
end $$;

create or replace function app.job_bank_unmatched() returns text
language plpgsql security definer set search_path = public, app, pg_temp as $$
declare n integer := app.bank_unmatched_scan();
begin
  return format('%s bank line(s) raised as To dos', n);
end $$;

do $$
begin
  if exists (select 1 from pg_extension where extname = 'pg_cron') then
    perform cron.schedule('carmacars-bank-unmatched', '35 10 * * *', $q$select app.job_bank_unmatched()$q$);
  end if;
end $$;

-- the staff notice for 'bank_line' opens the Finance bank lines list (kind 'list'), as the other staff notices about a list
alter function app.alert_entity_kind(text) rename to alert_entity_kind_pre3480;
create function app.alert_entity_kind(p_entity text) returns text
language sql immutable set search_path = public, app, pg_temp as $$
  select case p_entity when 'bank_line' then 'list' else app.alert_entity_kind_pre3480(p_entity) end
$$;
select pg_temp.copy_grants('app.alert_entity_kind(text)'::regprocedure, 'app.alert_entity_kind_pre3480(text)'::regprocedure);

-- ================================================================ the notice's values
insert into notification_catalogue (code, audience, also_sent_to, category, is_digest, digest_slot, from_address, reply_to, subject, preheader, timing, trigger_text,
    link_path, variables, template_html, template_text, emitted_by)
values ('staff_bank_line_unmatched', 'staff_va_finance', array['staff_admin']::text[], 'transactional', true, 'morning',
        'CarmaCars <billing@carmacars.ca>', 'contact@carmacars.ca',
        'Bank line with no match: {{bank_direction}} {{bank_amount}} on {{bank_posted_on}}',
        '{{bank_description}}. {{bank_hint}}',
        'Morning digest, once per line, two days after it posted',
        'Daily check and every bank import (3480): a line on the bank statement still matches no payout, payment, invoice or expense finance_bank_unmatched_days after it posted. A To do for Finance is raised with it; matching the line closes it.',
        '/staff/finance?tab=bank',
        '[{"name":"bank_account","type":"string"},{"name":"bank_amount","type":"string"},{"name":"bank_description","type":"string"},{"name":"bank_direction","type":"string"},{"name":"bank_hint","type":"string"},{"name":"bank_posted_on","type":"string"},{"name":"company_address","type":"string","global":true}]'::jsonb,
        'templates/staff_bank_line_unmatched.html', 'templates/staff_bank_line_unmatched.txt', 'app.bank_unmatched_scan (3480)')
on conflict (code) do update set audience = excluded.audience, also_sent_to = excluded.also_sent_to, subject = excluded.subject, preheader = excluded.preheader,
  timing = excluded.timing, trigger_text = excluded.trigger_text, link_path = excluded.link_path, variables = excluded.variables,
  template_html = excluded.template_html, template_text = excluded.template_text, emitted_by = excluded.emitted_by, updated_at = now();
select app.notification_catalogue_refresh();
update notification_catalogue set no_text = true, push_topic = 'alerts', hold_to_merge = false, priority = 3 where code = 'staff_bank_line_unmatched';
insert into notification_link_paths (key, path) values ('va_finance_bank', '/staff/finance?tab=bank') on conflict (key) do update set path = excluded.path;

alter function app.notification_payload(text, app_events, jsonb) rename to ntf_payload_pre3480;
create function app.notification_payload(p_code text, p_event app_events, p_to jsonb) returns jsonb
language plpgsql stable security definer set search_path = public, app, pg_temp as $$
declare
  x jsonb := app.ntf_payload_pre3480(p_code, p_event, p_to);
  p jsonb := coalesce(p_event.payload, '{}'::jsonb);
  v_amt bigint := nullif(p ->> 'amount_cents', '')::bigint;
  v_c integer := coalesce(nullif(p ->> 'candidate_count', '')::integer, 0);
begin
  if p_code = 'staff_bank_line_unmatched' then
    x := coalesce(x, '{}'::jsonb) || jsonb_build_object(
      'bank_direction', case when v_amt > 0 then 'in' else 'out' end,
      'bank_amount', app.fmt_money(abs(coalesce(v_amt, 0))),
      'bank_posted_on', app.fmt_day(nullif(p ->> 'posted_on', '')::date),
      'bank_description', coalesce(nullif(p ->> 'description', ''), 'No description'),
      'bank_account', coalesce(p ->> 'account_name', 'the bank account'),
      'bank_hint', case when v_c > 1 then format('%s records fit: pick the right one.', v_c)
                        when v_c = 1 then 'One record fits: confirm it.'
                        else 'Nothing recorded fits: record what it is, or set it aside with the reason.' end,
      '_url', (app.settings()).notify_base_url || '/staff/finance?tab=bank');
  end if;
  return x;
end $$;
select pg_temp.copy_grants('app.notification_payload(text, app_events, jsonb)'::regprocedure, 'app.ntf_payload_pre3480(text, app_events, jsonb)'::regprocedure);

-- ================================================================ reads
-- the bank lines, newest first: p {status: unmatched | matched | ignored | all, account, limit}
create or replace function app.bank_lines_view(p_user uuid, p jsonb) returns jsonb
language plpgsql stable security definer set search_path = public, app, pg_temp as $$
declare
  v_status text := coalesce(nullif(p ->> 'status', ''), 'unmatched');
  v_acct uuid := nullif(p ->> 'account', '')::uuid;
  v_limit integer := least(greatest(coalesce(nullif(p ->> 'limit', '')::integer, 200), 1), 500);
begin
  if not app.user_runs_finance(p_user) then raise exception 'Finance or an Admin sees the bank lines' using errcode = '42501'; end if;
  if v_status not in ('unmatched', 'matched', 'ignored', 'all') then v_status := 'unmatched'; end if;
  return jsonb_build_object('status', v_status, 'provider', (app.settings()).bank_data_provider,
    'accounts', coalesce((select jsonb_agg(jsonb_build_object('id', a.id, 'nickname', a.nickname, 'last4', a.account_last4, 'currency', a.currency, 'provider', a.provider) order by a.created_at)
                            from bank_accounts a where a.active), '[]'::jsonb),
    'counts', (select jsonb_build_object('unmatched', count(*) filter (where status = 'unmatched'), 'matched', count(*) filter (where status = 'matched'),
                                         'ignored', count(*) filter (where status = 'ignored'), 'all', count(*))
                 from bank_lines where v_acct is null or bank_account_id = v_acct),
    'imports', coalesce((select jsonb_agg(to_jsonb(i) || jsonb_build_object('by', u.full_name, 'account', a.nickname) order by i.created_at desc)
                           from (select * from bank_imports where v_acct is null or bank_account_id = v_acct order by created_at desc limit 5) i
                           join bank_accounts a on a.id = i.bank_account_id left join users u on u.id = i.imported_by), '[]'::jsonb),
    'rows', coalesce((select jsonb_agg(jsonb_build_object('id', l.id, 'posted_on', l.posted_on, 'amount_cents', l.amount_cents, 'description', l.description,
                       'cheque_number', l.cheque_number, 'status', l.status, 'match_kind', l.match_kind, 'matched_auto', l.matched_auto, 'note', l.note,
                       'account', a.nickname, 'last4', a.account_last4,
                       'matched_label', case when l.status = 'matched' then (select c.label from app.bank_candidates(l.id, 400) c where c.tbl = l.matched_table and c.id = l.matched_id limit 1) end,
                       'candidates', case when l.status = 'unmatched' then app.bank_free_candidates(l.id) else '[]'::jsonb end)
                       order by l.posted_on desc, l.created_at desc)
                       from (select * from bank_lines where (v_status = 'all' or status = v_status) and (v_acct is null or bank_account_id = v_acct)
                              order by posted_on desc, created_at desc limit v_limit) l
                       join bank_accounts a on a.id = l.bank_account_id), '[]'::jsonb));
end $$;

create or replace function app.finance_dashboard(p_user uuid, p jsonb) returns jsonb
language plpgsql stable security definer set search_path = public, app, pg_temp as $$
declare
  s program_settings := app.settings();
  v_today date := app.today();
  v_month date := coalesce(nullif(p ->> 'month', '')::date, date_trunc('month', app.today())::date);
  v_mend date;
  v_q0 date;
  v_q1 date;
  v_hst jsonb;
  v_out jsonb;
begin
  if not app.user_runs_finance(p_user) then raise exception 'Finance or an Admin sees the finance dashboard' using errcode = '42501'; end if;
  v_month := date_trunc('month', v_month)::date;
  v_mend := (v_month + interval '1 month')::date;
  v_q0 := date_trunc('quarter', v_month)::date;
  v_q1 := (v_q0 + interval '3 months')::date;

  -- HST of the quarter: collected on renter lines (rentals that ended in it), owner invoices and insurer invoices; paid on
  -- expenses and on payouts to registered owners. An Insurance Fee never carries HST.
  with hc as (
    select
      coalesce((select sum(l.hst_cents) from booking_line_items l join bookings b on b.id = l.booking_id
                 where l.voided_at is null and l.charged_to_renter and not b.is_test and not b.is_placeholder
                   and b.status::text in ('returned', 'closed') and app.local_date(b.return_at) >= v_q0 and app.local_date(b.return_at) < v_q1), 0) as renters,
      coalesce((select sum(il.hst_cents) from owner_invoice_lines il join owner_invoices oi on oi.id = il.owner_invoice_id join owners o on o.id = oi.owner_id
                 where oi.status not in ('draft', 'void') and not o.is_test and oi.billing_date >= v_q0 and oi.billing_date < v_q1
                   and il.kind not in ('insurance_fee', 'first_month_insurance', 'last_month_insurance')), 0) as owners,
      coalesce((select sum(ii.hst_cents) from insurer_invoices ii
                 where ii.status <> 'draft' and ii.sent_at is not null and app.local_date(ii.sent_at) >= v_q0 and app.local_date(ii.sent_at) < v_q1), 0) as insurers,
      coalesce((select sum(ce.hst_cents) from company_expenses ce where ce.voided_at is null and ce.expense_on >= v_q0 and ce.expense_on < v_q1), 0) as on_expenses,
      coalesce((select sum(po.hst_cents) from payouts po where po.status = 'paid' and app.local_date(po.paid_at) >= v_q0 and app.local_date(po.paid_at) < v_q1), 0) as on_payouts)
  select jsonb_build_object('from', v_q0, 'to', (v_q1 - 1),
    'collected_cents', hc.renters + hc.owners + hc.insurers,
    'collected', jsonb_build_object('renters', hc.renters, 'owners', hc.owners, 'insurers', hc.insurers),
    'paid_cents', hc.on_expenses + hc.on_payouts,
    'paid', jsonb_build_object('expenses', hc.on_expenses, 'payouts', hc.on_payouts),
    'owed_cents', hc.renters + hc.owners + hc.insurers - hc.on_expenses - hc.on_payouts,
    'insurance_with_hst', coalesce((select jsonb_agg(jsonb_build_object('invoice_number', oi.invoice_number, 'hst_cents', il.hst_cents) order by oi.invoice_number)
                                      from owner_invoice_lines il join owner_invoices oi on oi.id = il.owner_invoice_id
                                     where il.kind in ('insurance_fee', 'first_month_insurance', 'last_month_insurance') and il.hst_cents <> 0
                                       and oi.status not in ('draft', 'void')), '[]'::jsonb))
    into v_hst from hc;

  select jsonb_build_object(
    'owner_payouts', (select jsonb_build_object(
        'due_cents', coalesce(sum(po.amount_cents) filter (where po.status in ('draft', 'pending_approval', 'approved', 'sent')), 0),
        'due_count', count(*) filter (where po.status in ('draft', 'pending_approval', 'approved', 'sent')),
        'next_on', min(po.scheduled_for) filter (where po.status in ('draft', 'pending_approval', 'approved', 'sent')),
        'paid_month_cents', coalesce(sum(po.amount_cents) filter (where po.status = 'paid' and app.local_date(po.paid_at) >= v_month and app.local_date(po.paid_at) < v_mend), 0),
        'failed_count', count(*) filter (where po.status = 'failed'))
       from payouts po where po.payee_type = 'owner'),
    'other_payouts_month_cents', coalesce((select sum(po.amount_cents) from payouts po where po.payee_type <> 'owner' and po.status = 'paid'
                                            and app.local_date(po.paid_at) >= v_month and app.local_date(po.paid_at) < v_mend), 0),
    'commissions', jsonb_build_object(
        'due_cents', coalesce((select sum(c.amount_cents) from staff_commissions c where c.status = 'approved'), 0),
        'accruing_cents', coalesce((select sum(c.amount_cents) from staff_commissions c where c.status in ('accruing', 'pending_approval')), 0),
        'paid_month_cents', coalesce((select sum(x.amount_cents) from staff_commission_payouts x where x.paid_on >= v_month and x.paid_on < v_mend), 0),
        'partners_paid_month_cents', coalesce((select sum(x.amount_cents) from referral_partner_payouts x where x.paid_on >= v_month and x.paid_on < v_mend), 0)),
    'expenses_month_cents', coalesce((select sum(ce.amount_cents + ce.hst_cents) from company_expenses ce where ce.voided_at is null and ce.expense_on >= v_month and ce.expense_on < v_mend), 0),
    'refunds', jsonb_build_object(
        'paid_month_cents', coalesce((select sum(r.amount_cents) from refunds r join bookings b on b.id = r.booking_id
                                       where r.status = 'paid' and not b.is_test and app.local_date(r.paid_at) >= v_month and app.local_date(r.paid_at) < v_mend), 0),
        'owed_cents', coalesce((select sum(r.amount_cents) from refunds r join bookings b on b.id = r.booking_id where r.status in ('pending_approval', 'approved', 'processing', 'failed') and not b.is_test), 0),
        'owed_count', (select count(*) from refunds r join bookings b on b.id = r.booking_id where r.status in ('pending_approval', 'approved', 'processing', 'failed') and not b.is_test)))
    into v_out;

  return jsonb_build_object(
    'as_of', now(), 'today', v_today, 'month', v_month, 'provider', s.bank_data_provider, 'unmatched_days', s.finance_bank_unmatched_days,
    'bank', jsonb_build_object(
      'accounts', coalesce((select jsonb_agg(jsonb_build_object('id', a.id, 'nickname', a.nickname, 'last4', a.account_last4, 'currency', a.currency, 'provider', a.provider,
                    'balance_cents', bb.balance_cents, 'as_of', bb.as_of, 'source', bb.source, 'days_old', v_today - bb.as_of,
                    'last_import_at', (select max(i.created_at) from bank_imports i where i.bank_account_id = a.id)) order by a.created_at)
                  from bank_accounts a
                  left join lateral (select x.* from bank_balances x where x.bank_account_id = a.id order by x.as_of desc, x.created_at desc limit 1) bb on true
                 where a.active), '[]'::jsonb),
      'total_cad_cents', coalesce((select sum(bb.balance_cents) from bank_accounts a
                  join lateral (select x.balance_cents from bank_balances x where x.bank_account_id = a.id order by x.as_of desc, x.created_at desc limit 1) bb on true
                 where a.active and a.currency = 'CAD'), 0),
      'stripe_payouts_open', coalesce((select jsonb_agg(jsonb_build_object('ref', pr.processor_payout_ref, 'paid_on', pr.paid_on, 'amount_cents', pr.amount_cents) order by pr.paid_on desc)
                  from (select * from payout_reconciliations x where x.processor = 'stripe' and x.paid_on >= v_today - 14
                          and not exists (select 1 from bank_lines l where l.status = 'matched' and l.matched_table = 'payout_reconciliations' and l.matched_id = x.id)
                        order by x.paid_on desc limit 10) pr), '[]'::jsonb)),
    'money_in', jsonb_build_object(
      'month_rentals_cents', coalesce((select sum(py.amount_cents) from payments py join bookings b on b.id = py.booking_id
                  where py.status = 'succeeded' and py.kind in ('charge', 'capture') and py.purpose not in ('deposit', 'tip', 'owner_upfront', 'owner_fees')
                    and not b.is_test and not b.is_placeholder and app.local_date(py.processed_at) >= v_month and app.local_date(py.processed_at) < v_mend), 0),
      'month_owner_fees_cents', coalesce((select sum(py.amount_cents) from payments py left join owners o on o.id = py.owner_id
                  where py.status = 'succeeded' and py.kind = 'charge' and py.purpose in ('owner_upfront', 'owner_fees') and not coalesce(o.is_test, false)
                    and app.local_date(py.processed_at) >= v_month and app.local_date(py.processed_at) < v_mend), 0),
      'month_insurers_cents', coalesce((select sum(ii.paid_cents) from insurer_invoices ii where ii.paid_at is not null
                  and app.local_date(ii.paid_at) >= v_month and app.local_date(ii.paid_at) < v_mend), 0),
      'month_tips_cents', coalesce((select sum(t.amount_cents) from tips t where t.status = 'paid' and app.local_date(t.paid_at) >= v_month and app.local_date(t.paid_at) < v_mend), 0)),
    'deposits', (select jsonb_build_object(
        'cash_cents', coalesce(sum(greatest(0, greatest(dp.captured_cents, case when dp.method = 'charged' then dp.amount_cents else 0 end) - dp.applied_cents - dp.released_cents))
                                 filter (where dp.method <> 'card_hold' or dp.status = 'captured'), 0),
        'holds_cents', coalesce(sum(dp.amount_cents) filter (where dp.method = 'card_hold' and dp.status = 'held'), 0),
        'held_back_cents', coalesce(sum(dp.held_back_cents), 0),
        'count', count(*),
        'release_late', count(*) filter (where dp.release_due_on < v_today))
       from deposits dp join bookings b on b.id = dp.booking_id
      where dp.status in ('held', 'captured') and not b.is_test and not b.is_placeholder),
    'insurers', (select jsonb_build_object(
        'total_cents', coalesce(sum(x.balance_cents), 0), 'count', count(*),
        'buckets', jsonb_build_object(
          'd0_30', coalesce(sum(x.balance_cents) filter (where x.days <= 30), 0), 'd31_60', coalesce(sum(x.balance_cents) filter (where x.days between 31 and 60), 0),
          'd61_90', coalesce(sum(x.balance_cents) filter (where x.days between 61 and 90), 0), 'd90', coalesce(sum(x.balance_cents) filter (where x.days > 90), 0)),
        'rows', coalesce(jsonb_agg(jsonb_build_object('id', x.id, 'invoice_number', x.invoice_number, 'insurer', x.insurer, 'booking_number', x.booking_number,
                   'claim_number', x.claim_number, 'total_cents', x.total_cents, 'balance_cents', x.balance_cents, 'sent_on', x.sent_on, 'days', x.days) order by x.days desc), '[]'::jsonb))
       from (select ii.id, ii.invoice_number, ins.name as insurer, b.booking_number, ii.claim_number, ii.total_cents, ii.balance_cents,
                    app.local_date(ii.sent_at) as sent_on, v_today - app.local_date(ii.sent_at) as days
               from insurer_invoices ii join insurers ins on ins.id = ii.insurer_id join bookings b on b.id = ii.booking_id
              where ii.status in ('sent', 'part_paid') and ii.balance_cents > 0 and not b.is_test) x),
    'renters_overdue', (select jsonb_build_object('total_cents', coalesce(sum(y.open_cents), 0), 'count', count(*),
        'rows', coalesce(jsonb_agg(jsonb_build_object('booking_number', y.booking_number, 'renter', y.renter, 'open_cents', y.open_cents, 'since', y.since, 'days', v_today - y.since) order by y.since), '[]'::jsonb))
       from (select b.booking_number, r.legal_name as renter, app.booking_balance_open(b.id) as open_cents,
                    min(bs.interest_starts_on) as since
               from booking_statements bs join bookings b on b.id = bs.booking_id join renters r on r.id = b.renter_id
              where bs.paid_at is null and bs.interest_starts_on is not null and bs.interest_starts_on <= v_today and not b.is_test and not b.is_placeholder
              group by b.id, b.booking_number, r.legal_name) y
      where y.open_cents > 0),
    'money_out', v_out,
    'hst', v_hst,
    'pnl', (select coalesce(jsonb_agg(jsonb_build_object('month', m.m,
        'in_cents', m.in_c, 'refunds_cents', m.ref_c, 'payouts_cents', m.po_c, 'commissions_cents', m.com_c, 'expenses_cents', m.exp_c,
        'net_cents', m.in_c - m.ref_c - m.po_c - m.com_c - m.exp_c, 'statement_net_cents', m.st_c) order by m.m), '[]'::jsonb)
       from (select g.m,
               coalesce((select sum(py.amount_cents) from payments py left join bookings b on b.id = py.booking_id left join owners o on o.id = py.owner_id
                          where py.status = 'succeeded' and py.kind in ('charge', 'capture') and py.purpose not in ('deposit', 'tip')
                            and not coalesce(b.is_test, false) and not coalesce(b.is_placeholder, false) and not coalesce(o.is_test, false)
                            and py.processed_at >= app.local_midnight(g.m) and py.processed_at < app.local_midnight((g.m + interval '1 month')::date)), 0)
               + coalesce((select sum(ii.paid_cents) from insurer_invoices ii where ii.paid_at >= app.local_midnight(g.m) and ii.paid_at < app.local_midnight((g.m + interval '1 month')::date)), 0) as in_c,
               coalesce((select sum(r.amount_cents) from refunds r join bookings b on b.id = r.booking_id where r.status = 'paid' and not b.is_test
                          and r.paid_at >= app.local_midnight(g.m) and r.paid_at < app.local_midnight((g.m + interval '1 month')::date)), 0) as ref_c,
               coalesce((select sum(po.amount_cents) from payouts po where po.status = 'paid'
                          and po.paid_at >= app.local_midnight(g.m) and po.paid_at < app.local_midnight((g.m + interval '1 month')::date)), 0) as po_c,
               coalesce((select sum(x.amount_cents) from staff_commission_payouts x where x.paid_on >= g.m and x.paid_on < (g.m + interval '1 month')::date), 0)
               + coalesce((select sum(x.amount_cents) from referral_partner_payouts x where x.paid_on >= g.m and x.paid_on < (g.m + interval '1 month')::date), 0) as com_c,
               coalesce((select sum(ce.amount_cents + ce.hst_cents) from company_expenses ce where ce.voided_at is null and ce.expense_on >= g.m and ce.expense_on < (g.m + interval '1 month')::date), 0) as exp_c,
               (select csl.company_net_cents from company_statements cs join company_statement_lines csl on csl.statement_id = cs.id and csl.level = 'total'
                 where cs.statement_month = g.m limit 1) as st_c
             from (select (v_month - make_interval(months => k))::date as m from generate_series(0, 11) k) g) m),
    'reconciliation', (select jsonb_build_object('total', count(*), 'matched', count(*) filter (where status = 'matched'),
        'auto', count(*) filter (where status = 'matched' and matched_auto), 'ignored', count(*) filter (where status = 'ignored'),
        'unmatched', count(*) filter (where status = 'unmatched'),
        'unmatched_in_cents', coalesce(sum(amount_cents) filter (where status = 'unmatched' and amount_cents > 0), 0),
        'unmatched_out_cents', coalesce(-sum(amount_cents) filter (where status = 'unmatched' and amount_cents < 0), 0),
        'oldest_unmatched', min(posted_on) filter (where status = 'unmatched'))
       from bank_lines));
end $$;

-- ================================================================ the door
alter function app.door(uuid, text, text, text, jsonb) rename to door_pre3480;
create function app.door(p_user uuid, p_aal text, p_call text, p_name text, p jsonb default '{}'::jsonb) returns jsonb
language plpgsql security definer set search_path = public, app, pg_temp as $$
declare
  p_ jsonb := coalesce(p, '{}'::jsonb);
begin
  if (p_call in ('admin_read', 'va_read', 'ops_read') and p_name in ('finance_dashboard', 'bank_lines'))
     or (p_call in ('admin_do', 'va_do', 'ops_do') and p_name in ('bank_import', 'bank_line_match', 'bank_balance_set')) then
    if p_ ? '_va' then perform set_config('app.va_active', coalesce(p_ ->> '_va', ''), true); end if;
    p_ := p_ - '_va';
    perform app.door_begin(p_user, p_aal);
    return case p_name
      when 'finance_dashboard' then app.finance_dashboard(p_user, p_)
      when 'bank_lines' then app.bank_lines_view(p_user, p_)
      when 'bank_import' then app.bank_import(p_user, p_)
      when 'bank_balance_set' then app.bank_balance_set(p_user, p_)
      else app.bank_line_match(p_user, p_) end;
  end if;
  return app.door_pre3480(p_user, p_aal, p_call, p_name, p);
end $$;
select pg_temp.copy_grants('app.door(uuid, text, text, text, jsonb)'::regprocedure, 'app.door_pre3480(uuid, text, text, text, jsonb)'::regprocedure);

-- ================================================================ privileges: the server only
do $$
declare f record;
begin
  for f in select p.oid::regprocedure as sig from pg_proc p join pg_namespace n on n.oid = p.pronamespace
            where n.nspname = 'app' and p.proname in ('bank_candidates', 'bank_free_candidates', 'bank_auto_match', 'bank_line_close_todo', 'bank_account_find',
              'bank_import', 'bank_balance_set', 'bank_line_match', 'bank_unmatched_scan', 'job_bank_unmatched', 'bank_lines_view', 'finance_dashboard',
              'ntf_payload_pre3480', 'door_pre3480') loop
    execute format('revoke all on function %s from public, anon, authenticated', f.sig);
    execute format('grant execute on function %s to service_role', f.sig);
  end loop;
end $$;
