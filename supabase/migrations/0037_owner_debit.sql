-- 0037_owner_debit.sql
-- The automatic monthly owner debit, statement emails with the PDFs attached, and the missing sections of
-- CarmaCars' own monthly statement (docs/changes/2026-10-14-owner-debit.md):
--   1. settings: the debit day is the billing day (15th) of 0001; the notice days, retry policy, run hour,
--      invoice kinds, and the statement email days are new program settings an Admin edits
--   2. pauses (per owner and per invoice), the debit run log, the pre-debit notices and one attempt row per
--      PaymentIntent (one PaymentIntent per invoice and attempt; the idempotency key is the attempt's)
--   3. the notice job (pg_cron, SQL): issues the month's invoices, sends the pre-debit notice N days before
--      the debit day and schedules one attempt per invoice; no mandate: the owner is asked to set up banking
--      and an Admin gets the exception
--   4. what the owner-debit Edge Function calls: claim, submitted, submit error, poll, result, run close;
--      the Stripe webhook (on the Worker) calls the same result function
--   5. failure and retry: the Late Fee once (0007), the next attempt after the retry day and the gap, in
--      arrears after the last attempt; canceled and returned debits
--   6. reads: the owner portal (next debit, status per invoice), Admin > Owner debits, pause and resume
--   7. test owners: staff notices about an owner marked is_test go only to the verification accounts
--   8. emails: the catalogue rows, merge values, attachments (statement PDFs), the statement email days,
--      the company statements emailed with their PDFs
--   9. CarmaCars' monthly statement: income by account, held for others, HST, receivables, cash, fleet,
--      bookings funnel, investors, owner debits and adjustments to earlier months, stored with the statement
-- No earlier migration is edited. Function bodies are checked when called.
set local check_function_bodies = off;

-- ================================================================ 1. settings
alter table program_settings
  add column owner_debit_enabled boolean not null default true,
  add column owner_debit_notice_days smallint not null default 10 check (owner_debit_notice_days between 1 and 30),
  add column owner_debit_max_attempts smallint not null default 2 check (owner_debit_max_attempts between 1 and 5),
  add column owner_debit_retry_gap_days smallint not null default 3 check (owner_debit_retry_gap_days between 1 and 15),
  add column owner_debit_run_hour smallint not null default 6 check (owner_debit_run_hour between 0 and 23),
  add column owner_debit_poll_hours smallint not null default 24 check (owner_debit_poll_hours between 1 and 168),
  add column owner_debit_kinds text[] not null default array['monthly', 'upfront', 'tracker_install', 'adjustment']
    check (owner_debit_kinds <@ array['monthly', 'upfront', 'tracker_install', 'adjustment']),
  add column owner_statement_email_day smallint not null default 10 check (owner_statement_email_day between 1 and 28),
  add column company_statement_email_day smallint not null default 10 check (company_statement_email_day between 1 and 28);
comment on column program_settings.owner_debit_enabled is 'Owner invoices are debited automatically on the billing day (billing_day) by pre-authorized debit';
comment on column program_settings.owner_debit_notice_days is 'Days between the pre-debit notice email and the debit (Payments Canada Rule H1 asks for at least 10)';
comment on column program_settings.owner_debit_max_attempts is 'Debit attempts per invoice, the first one included; after the last one fails the invoice is in arrears';
comment on column program_settings.owner_debit_retry_gap_days is 'Days after a failed debit before the next attempt (never before retry_day for the first retry)';
comment on column program_settings.owner_statement_email_day is 'Day of the month the approved owner statements are emailed with their PDF';
comment on column program_settings.company_statement_email_day is 'Day of the month the company statements (total, per owner, per vehicle) are emailed to the Admins with their PDFs';

-- ================================================================ 2. tables and columns
alter table owners
  add column auto_debit_paused boolean not null default false,
  add column auto_debit_paused_reason text,
  add column auto_debit_paused_at timestamptz,
  add column auto_debit_paused_by uuid references users (id),
  add column is_test boolean not null default false;
comment on column owners.is_test is 'A test or verification owner: staff notices about it go only to the verification accounts, never to real staff';

alter table owner_invoices
  add column auto_debit_paused boolean not null default false,
  add column auto_debit_paused_reason text,
  add column auto_debit_paused_at timestamptz,
  add column auto_debit_paused_by uuid references users (id),
  add column debit_on date;
comment on column owner_invoices.debit_on is 'The day the pre-authorized debit of this invoice is scheduled (its notice was sent)';

create table owner_debit_runs (
  id            uuid primary key default gen_random_uuid(),
  run_on        date not null,
  kind          text not null check (kind in ('notice', 'debit')),
  status        text not null default 'running' check (status in ('running', 'succeeded', 'failed')),
  started_at    timestamptz not null default now(),
  finished_at   timestamptz,
  notices_sent  integer not null default 0,
  no_mandate    integer not null default 0,
  scheduled     integer not null default 0,
  submitted     integer not null default 0,
  succeeded     integer not null default 0,
  failed        integer not null default 0,
  skipped       integer not null default 0,
  submitted_cents bigint not null default 0,
  summary       jsonb not null default '{}'::jsonb,
  error         text,
  summary_sent_at timestamptz,
  unique (run_on, kind)
);

create table owner_debit_notices (
  id            uuid primary key default gen_random_uuid(),
  owner_id      uuid not null references owners (id),
  debit_on      date not null,
  run_id        uuid references owner_debit_runs (id),
  invoice_ids   uuid[] not null,
  total_cents   bigint not null,
  bank_last4    text,
  mandate_missing boolean not null default false,
  sent_at       timestamptz not null default now(),
  sent_by       uuid references users (id)
);
create index owner_debit_notices_owner_idx on owner_debit_notices (owner_id, debit_on);

create table owner_debit_attempts (
  id                  uuid primary key default gen_random_uuid(),
  owner_invoice_id    uuid not null references owner_invoices (id),
  owner_id            uuid not null references owners (id),
  notice_id           uuid references owner_debit_notices (id),
  run_id              uuid references owner_debit_runs (id),
  attempt_no          smallint not null check (attempt_no >= 1),
  debit_on            date not null,
  amount_cents        bigint not null check (amount_cents > 0),
  status              text not null default 'scheduled'
                      check (status in ('scheduled', 'submitting', 'processing', 'succeeded', 'failed', 'skipped', 'canceled')),
  skip_reason         text,
  idempotency_key     text not null unique,
  processor_intent_id text unique,
  processor_customer_id text,
  processor_method_id text,
  processor_mandate_id text,
  bank_last4          text,
  payment_id          uuid references payments (id),
  failure_code        text,
  failure_message     text,
  submitted_at        timestamptz,
  settled_at          timestamptz,
  last_checked_at     timestamptz,
  created_at          timestamptz not null default now(),
  updated_at          timestamptz not null default now(),
  unique (owner_invoice_id, attempt_no)
);
create index owner_debit_attempts_due_idx on owner_debit_attempts (status, debit_on);
create index owner_debit_attempts_owner_idx on owner_debit_attempts (owner_id, created_at);
create trigger owner_debit_attempts_updated before update on owner_debit_attempts for each row execute function app.set_updated_at();

do $$
declare
  t text;
begin
  foreach t in array array['owner_debit_runs', 'owner_debit_notices', 'owner_debit_attempts'] loop
    execute format('alter table public.%I enable row level security', t);
    execute format('create policy admin_all on public.%I for all to authenticated using (app.is_admin()) with check (app.is_admin())', t);
    execute format('create policy finance_read on public.%I for select to authenticated using (app.va_has(''finance''))', t);
  end loop;
end $$;
do $$ begin perform app.attach_audit(); end $$;

-- the status flow: a canceled debit goes back; a retry that fails while more attempts are allowed is failed again
insert into status_transitions (entity, from_status, to_status, note) values
  ('owner_invoice', 'processing', 'issued', 'the debit was canceled before it settled'),
  ('owner_invoice', 'retry_processing', 'failed', 'a retry fails and another attempt is allowed (owner_debit_max_attempts)')
on conflict do nothing;

-- ================================================================ 3. helpers
-- The debit day of a month: the billing day (program_settings.billing_day, the 15th).
create or replace function app.owner_debit_date(p_month date) returns date
language sql stable security definer set search_path = public, app as $$ select app.billing_date(app.month_start(p_month)) $$;

-- The next debit day whose notice can still go out on time, seen from a day: the debit day of this month if
-- its notice day has not passed, else next month's.
create or replace function app.owner_debit_next_date(p_from date default app.today()) returns date
language sql stable security definer set search_path = public, app as $$
  select case when app.owner_debit_date(p_from) - (app.settings(p_from)).owner_debit_notice_days >= p_from
              then app.owner_debit_date(p_from)
              else app.owner_debit_date((app.month_start(p_from) + interval '1 month')::date) end
$$;

-- The owner's pre-authorized debit mandate in force: the newest active debit method with a processor mandate.
create or replace function app.owner_debit_mandate(p_owner uuid) returns jsonb
language sql stable security definer set search_path = public, app as $$
  select jsonb_build_object('method_id', m.id, 'bank', m.brand_or_bank, 'last4', m.last4,
                            'customer_id', s.processor_customer_id, 'processor_method_id', s.processor_method_id, 'mandate_id', s.processor_mandate_id)
    from owner_payment_methods m join owner_payment_method_secrets s on s.owner_payment_method_id = m.id
   where m.owner_id = p_owner and m.kind = 'pre_authorized_debit' and m.status = 'active'
     and nullif(s.processor_mandate_id, '') is not null and nullif(s.processor_method_id, '') is not null
     and nullif(s.processor_customer_id, '') is not null
   order by m.is_default desc, m.authorized_at desc nulls last, m.created_at desc
   limit 1
$$;

-- Why an invoice cannot be debited automatically now (null when it can).
create or replace function app.owner_debit_block(p_invoice uuid) returns text
language sql stable security definer set search_path = public, app as $$
  select case
    when i.id is null then 'not found'
    when not s.owner_debit_enabled then 'automatic debits are off in settings'
    when o.auto_debit_paused then 'paused for this owner'
    when i.auto_debit_paused then 'paused for this invoice'
    when i.kind <> all (s.owner_debit_kinds) then 'this kind of invoice is not debited automatically'
    when i.status not in ('issued', 'failed') then 'the invoice is ' || replace(i.status, '_', ' ')
    when i.balance_cents <= 0 then 'nothing is owing'
    when exists (select 1 from payments p where p.owner_invoice_id = i.id and p.status = 'pending') then 'a payment is already processing'
    when v.billing_case not in ('managed', 'self_managed') then 'not billed for this vehicle'
  end
    from (select 1) one
    left join owner_invoices i on i.id = p_invoice
    left join owners o on o.id = i.owner_id
    left join vehicles v on v.id = i.vehicle_id
    cross join lateral (select * from app.settings()) s
$$;

-- The run of a day (created on first use).
create or replace function app.owner_debit_run(p_kind text, p_day date) returns uuid
language plpgsql security definer set search_path = public, app as $$
declare
  v_id uuid;
begin
  insert into owner_debit_runs (run_on, kind) values (p_day, p_kind)
  on conflict (run_on, kind) do update set status = case when owner_debit_runs.status = 'failed' then 'running' else owner_debit_runs.status end
  returning id into v_id;
  return v_id;
end $$;

-- The invoices one notice covers: issued, owing, debitable, billed on or before the debit day, not already scheduled.
create or replace function app.owner_debit_candidates(p_owner uuid, p_debit_on date) returns setof owner_invoices
language sql stable security definer set search_path = public, app as $$
  select i.* from owner_invoices i
   where i.owner_id = p_owner and i.status = 'issued' and i.balance_cents > 0 and i.billing_date <= p_debit_on
     and app.owner_debit_block(i.id) is null
     and not exists (select 1 from owner_debit_attempts a where a.owner_invoice_id = i.id and a.status in ('scheduled', 'submitting', 'processing'))
   order by i.billing_date, i.invoice_number
$$;

-- ================================================================ 4. the notice: schedule one owner's debits for a day
-- Sends the pre-debit notice (or, without a mandate, the request to set up banking and the Admin exception)
-- and schedules one attempt per invoice. Returns what it did. p_by: an Admin sending it by hand.
create or replace function app.owner_debit_schedule(p_owner uuid, p_debit_on date, p_run uuid default null, p_by uuid default null,
                                                    p_today date default app.today())
returns jsonb language plpgsql security definer set search_path = public, app as $$
declare
  o owners;
  m jsonb := app.owner_debit_mandate(p_owner);
  s program_settings := app.settings(p_today);
  v_ids uuid[];
  v_total bigint;
  v_notice uuid;
  i owner_invoices;
  v_n integer := 0;
begin
  select * into o from owners where id = p_owner;
  if o.id is null then raise exception 'Owner not found' using errcode = 'P0002'; end if;
  if p_debit_on - p_today < s.owner_debit_notice_days then
    raise exception 'A debit on % needs its notice % days before; the earliest debit day now is %',
      p_debit_on, s.owner_debit_notice_days, p_today + s.owner_debit_notice_days using errcode = '23514';
  end if;
  select array_agg(c.id order by c.billing_date, c.invoice_number), sum(c.balance_cents) into v_ids, v_total
    from app.owner_debit_candidates(p_owner, p_debit_on) c;
  if v_ids is null then return jsonb_build_object('owner_id', p_owner, 'invoices', 0); end if;

  insert into owner_debit_notices (owner_id, debit_on, run_id, invoice_ids, total_cents, bank_last4, mandate_missing, sent_by)
  values (p_owner, p_debit_on, p_run, v_ids, v_total, m ->> 'last4', m is null, p_by)
  returning id into v_notice;

  if m is null then
    -- no mandate: the owner is asked to set up banking; an Admin sees the exception; nothing is scheduled
    perform app.ntf_emit('owner_debit_setup_needed', 'owner_debit_notice', v_notice, 'sent', jsonb_build_object('owner_id', p_owner));
    perform app.ntf_emit('staff_owner_debit_exception', 'owner_debit_notice', v_notice, 'no_mandate',
      jsonb_build_object('owner_id', p_owner, 'exception', 'no_mandate'));
    if not exists (select 1 from tasks t where t.owner_id = p_owner and t.task_type = 'owner_debit_no_mandate' and t.status in ('open', 'in_progress', 'waiting')) then
      insert into tasks (queue, task_type, title, detail, priority, owner_id, related_table, related_id, due_at)
      values ('admin', 'owner_debit_no_mandate', format('%s has no pre-authorized debit set up', o.legal_name),
              format('%s invoice(s), %s, could not be scheduled for the debit on %s. The owner was asked to set up banking. Follow up, or record a payment.',
                     cardinality(v_ids), app.fmt_money(v_total), app.fmt_day(p_debit_on)),
              'high', p_owner, 'owner_debit_notices', v_notice, app.local_midnight(p_debit_on));
    end if;
    if p_run is not null then update owner_debit_runs set no_mandate = no_mandate + 1 where id = p_run; end if;
    return jsonb_build_object('owner_id', p_owner, 'invoices', cardinality(v_ids), 'notice_id', v_notice, 'mandate', false, 'total_cents', v_total);
  end if;

  for i in select * from owner_invoices where id = any (v_ids) order by billing_date, invoice_number loop
    insert into owner_debit_attempts (owner_invoice_id, owner_id, notice_id, run_id, attempt_no, debit_on, amount_cents, idempotency_key, bank_last4)
    values (i.id, p_owner, v_notice, p_run,
            coalesce((select max(a.attempt_no) from owner_debit_attempts a where a.owner_invoice_id = i.id), 0) + 1,
            p_debit_on, i.balance_cents, 'owner-debit:' || gen_random_uuid(), m ->> 'last4');
    update owner_invoices set debit_on = p_debit_on, payment_method = 'pre_authorized_debit' where id = i.id;
    v_n := v_n + 1;
  end loop;
  perform app.ntf_emit('owner_debit_notice', 'owner_debit_notice', v_notice, 'sent', jsonb_build_object('owner_id', p_owner));
  if p_run is not null then update owner_debit_runs set notices_sent = notices_sent + 1, scheduled = scheduled + v_n where id = p_run; end if;
  if p_by is not null then
    insert into audit_log (actor_user_id, action, entity_table, entity_id, after)
    values (p_by, 'owner_debit_schedule', 'owner_debit_notices', v_notice::text,
            jsonb_build_object('owner_id', p_owner, 'debit_on', p_debit_on, 'invoices', v_ids, 'total_cents', v_total));
  end if;
  return jsonb_build_object('owner_id', p_owner, 'invoices', v_n, 'notice_id', v_notice, 'mandate', true, 'total_cents', v_total);
end $$;

-- The notice day (the debit day less owner_debit_notice_days) from 06:00: issue the month's invoices, then
-- notify and schedule every owner. Hourly from pg_cron; the run key is the debit day.
create or replace function app.job_owner_debit_notices(p_now timestamptz default now()) returns text
language plpgsql security definer set search_path = public, app as $$
declare
  v_day date := app.local_date(p_now);
  s program_settings := app.settings(app.local_date(p_now));
  v_debit date := app.owner_debit_date(app.local_date(p_now));
  v_run uuid;
  v_log uuid;
  v_issued integer;
  v_created integer;
  r record;
  v_out jsonb := '[]'::jsonb;
  v_res jsonb;
begin
  -- the notice for this month's debit day, or (late in the month) next month's
  if v_debit - s.owner_debit_notice_days < v_day then
    v_debit := app.owner_debit_date((app.month_start(v_day) + interval '1 month')::date);
  end if;
  if v_debit - s.owner_debit_notice_days <> v_day or app.local_hour(p_now) < s.owner_debit_run_hour then return 'not_due'; end if;
  v_run := app.job_claim('owner-debit-notices', v_debit::text);
  if v_run is null then return 'already_run'; end if;
  begin
    -- the month's fee invoices exist and are issued now, so the notice lists them (0015's job on the 15th
    -- still makes any it missed)
    v_created := app.generate_owner_invoices(app.month_start(v_debit));
    update owner_invoices set status = 'issued' where status = 'draft' and kind = 'monthly' and billing_date <= v_debit;
    get diagnostics v_issued = row_count;
    v_log := app.owner_debit_run('notice', v_day);
    if s.owner_debit_enabled then
      for r in select distinct i.owner_id from owner_invoices i join owners o on o.id = i.owner_id
                where i.status = 'issued' and i.balance_cents > 0 and i.billing_date <= v_debit and not o.auto_debit_paused
                order by i.owner_id loop
        begin
          v_res := app.owner_debit_schedule(r.owner_id, v_debit, v_log, null, v_day);
          if (v_res ->> 'invoices')::integer > 0 then v_out := v_out || jsonb_build_array(v_res); end if;
        exception when others then
          v_out := v_out || jsonb_build_array(jsonb_build_object('owner_id', r.owner_id, 'error', sqlerrm));
        end;
      end loop;
    end if;
    update owner_debit_runs set status = 'succeeded', finished_at = now(),
           summary = jsonb_build_object('debit_on', v_debit, 'invoices_created', v_created, 'invoices_issued', v_issued,
                                        'enabled', s.owner_debit_enabled, 'owners', v_out)
     where id = v_log;
    perform app.job_succeed(v_run, jsonb_build_object('debit_on', v_debit, 'invoices_created', v_created, 'invoices_issued', v_issued,
                                                      'owners', jsonb_array_length(v_out), 'enabled', s.owner_debit_enabled));
    return 'succeeded';
  exception when others then
    perform app.job_fail(v_run, sqlerrm);
    return 'failed';
  end;
end $$;

-- ================================================================ 5. what the owner-debit Edge Function calls
-- The attempts due now, claimed for submission (status submitting). An attempt is re-checked first: a paid,
-- paused or changed invoice, or one without a mandate, is not sent. An attempt left in submitting for 30
-- minutes (the function stopped) is claimed again; its idempotency key makes a second request the same one.
create or replace function app.owner_debit_claim(p_now timestamptz default now(), p_limit integer default 25) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  v_day date := app.local_date(p_now);
  s program_settings := app.settings(app.local_date(p_now));
  a owner_debit_attempts;
  i owner_invoices;
  o owners;
  m jsonb;
  v_block text;
  v_run uuid;
  v_out jsonb := '[]'::jsonb;
begin
  if not s.owner_debit_enabled or app.local_hour(p_now) < s.owner_debit_run_hour then return v_out; end if;
  for a in select * from owner_debit_attempts
            where (status = 'scheduled' and debit_on <= v_day)
               or (status = 'submitting' and updated_at < now() - interval '30 minutes')
            order by debit_on, created_at limit greatest(p_limit, 1) for update skip locked loop
    v_run := coalesce(v_run, app.owner_debit_run('debit', v_day));
    select * into i from owner_invoices where id = a.owner_invoice_id for update;
    select * into o from owners where id = a.owner_id;
    if a.status = 'submitting' then
      -- already checked once; send the same request again
      v_out := v_out || jsonb_build_array(app.owner_debit_request(a, i, o));
      continue;
    end if;
    v_block := app.owner_debit_block(i.id);
    if v_block is not null and (i.status in ('paid', 'deducted', 'void') or i.balance_cents <= 0) then
      update owner_debit_attempts set status = 'canceled', skip_reason = v_block, run_id = v_run where id = a.id;
      update owner_invoices set debit_on = null where id = i.id and debit_on = a.debit_on;
      update owner_debit_runs set skipped = skipped + 1 where id = v_run;
      continue;
    elsif v_block is not null then
      update owner_debit_attempts set status = 'skipped', skip_reason = v_block, run_id = v_run where id = a.id;
      update owner_invoices set debit_on = null where id = i.id and debit_on = a.debit_on;
      update owner_debit_runs set skipped = skipped + 1 where id = v_run;
      if v_block not like 'paused%' then
        perform app.ntf_emit('staff_owner_debit_exception', 'owner_debit_attempt', a.id, 'blocked',
          jsonb_build_object('owner_id', a.owner_id, 'exception', 'blocked', 'reason', v_block));
      end if;
      continue;
    end if;
    -- never more than the notice said (PAD rules): a larger balance waits for a new notice
    if i.balance_cents > a.amount_cents then
      update owner_debit_attempts set status = 'skipped', skip_reason = 'the balance is more than the notice', run_id = v_run where id = a.id;
      update owner_invoices set debit_on = null where id = i.id;
      update owner_debit_runs set skipped = skipped + 1 where id = v_run;
      perform app.ntf_emit('staff_owner_debit_exception', 'owner_debit_attempt', a.id, 'amount_changed',
        jsonb_build_object('owner_id', a.owner_id, 'exception', 'amount_changed',
                           'reason', format('The balance is %s and the notice said %s. It is debited after a new notice.', app.fmt_money(i.balance_cents), app.fmt_money(a.amount_cents))));
      continue;
    end if;
    m := app.owner_debit_mandate(a.owner_id);
    if m is null then
      update owner_debit_attempts set status = 'skipped', skip_reason = 'no pre-authorized debit mandate', run_id = v_run where id = a.id;
      update owner_invoices set debit_on = null where id = i.id;
      update owner_debit_runs set skipped = skipped + 1, no_mandate = no_mandate + 1 where id = v_run;
      perform app.ntf_emit('owner_debit_setup_needed', 'owner_debit_attempt', a.id, 'no_mandate', jsonb_build_object('owner_id', a.owner_id));
      perform app.ntf_emit('staff_owner_debit_exception', 'owner_debit_attempt', a.id, 'no_mandate',
        jsonb_build_object('owner_id', a.owner_id, 'exception', 'no_mandate'));
      continue;
    end if;
    update owner_debit_attempts
       set status = 'submitting', run_id = v_run, amount_cents = i.balance_cents,
           processor_customer_id = m ->> 'customer_id', processor_method_id = m ->> 'processor_method_id',
           processor_mandate_id = m ->> 'mandate_id', bank_last4 = coalesce(m ->> 'last4', bank_last4)
     where id = a.id returning * into a;
    v_out := v_out || jsonb_build_array(app.owner_debit_request(a, i, o));
  end loop;
  return v_out;
end $$;

-- What the Edge Function sends to Stripe for one attempt.
create or replace function app.owner_debit_request(a owner_debit_attempts, i owner_invoices, o owners) returns jsonb
language sql stable security definer set search_path = public, app as $$
  select jsonb_build_object(
    'attempt_id', a.id, 'attempt_no', a.attempt_no, 'idempotency_key', a.idempotency_key, 'amount_cents', a.amount_cents, 'currency', 'cad',
    'customer_id', a.processor_customer_id, 'payment_method_id', a.processor_method_id, 'mandate_id', a.processor_mandate_id,
    'description', format('CarmaCars invoice %s, %s', i.invoice_number, app.vehicle_name(i.vehicle_id)),
    'metadata', jsonb_build_object('purpose', 'owner_invoice', 'owner_invoice_id', i.id, 'invoice_number', i.invoice_number,
                                   'owner_id', o.id, 'debit_attempt_id', a.id, 'attempt_no', a.attempt_no::text))
$$;

-- Stripe accepted the PaymentIntent. p: {intent_id, status, customer_id, method_id, mandate_id, charge_id,
-- bank: {name, last4}, error_code, error_message}. The payment is recorded pending and the invoice is
-- processing; a PaymentIntent already final is settled at once.
create or replace function app.owner_debit_submitted(p_attempt uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  a owner_debit_attempts;
  i owner_invoices;
  v_pi text := nullif(p ->> 'intent_id', '');
  v_status text := p ->> 'status';
  r jsonb;
begin
  select * into a from owner_debit_attempts where id = p_attempt for update;
  if a.id is null then raise exception 'Debit attempt not found' using errcode = 'P0002'; end if;
  if v_pi is null then raise exception 'The PaymentIntent id is missing' using errcode = '22023'; end if;
  if a.status not in ('submitting', 'scheduled') then
    return jsonb_build_object('ok', true, 'repeat', true, 'status', a.status);
  end if;
  select * into i from owner_invoices where id = a.owner_invoice_id for update;
  update owner_debit_attempts set processor_intent_id = v_pi, submitted_at = coalesce(submitted_at, now()), status = 'processing',
         processor_mandate_id = coalesce(nullif(p ->> 'mandate_id', ''), processor_mandate_id), last_checked_at = now()
   where id = a.id returning * into a;
  r := app.record_owner_invoice_payment(i.id, jsonb_build_object(
         'status', 'pending', 'method', 'pre_authorized_debit', 'amount_cents', a.amount_cents, 'currency', 'cad',
         'processor', jsonb_build_object('processor', 'stripe', 'payment_id', v_pi, 'charge_id', p ->> 'charge_id',
                                         'customer_id', a.processor_customer_id, 'method_id', a.processor_method_id, 'mandate_id', a.processor_mandate_id),
         'bank', jsonb_build_object('name', p #>> '{bank,name}', 'last4', coalesce(p #>> '{bank,last4}', a.bank_last4)), 'save_method', false), null);
  update owner_debit_attempts set payment_id = (r ->> 'payment_id')::uuid where id = a.id;
  if i.status = 'issued' then update owner_invoices set status = 'processing' where id = i.id;
  elsif i.status = 'failed' then update owner_invoices set status = 'retry_processing' where id = i.id;
  end if;
  update owner_debit_runs set submitted = submitted + 1, submitted_cents = submitted_cents + a.amount_cents where id = a.run_id;
  if v_status in ('succeeded', 'requires_payment_method', 'canceled') then
    return app.owner_debit_result(v_pi, p);
  end if;
  return jsonb_build_object('ok', true, 'status', 'processing', 'payment_id', r ->> 'payment_id');
end $$;

-- Stripe refused the request. A permanent refusal (the mandate is inactive, the method is gone) is a failed
-- debit; anything else leaves the attempt to be sent again on the next run with the same key.
create or replace function app.owner_debit_submit_error(p_attempt uuid, p_code text, p_message text, p_permanent boolean) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  a owner_debit_attempts;
begin
  select * into a from owner_debit_attempts where id = p_attempt for update;
  if a.id is null then raise exception 'Debit attempt not found' using errcode = 'P0002'; end if;
  if a.status <> 'submitting' then return jsonb_build_object('ok', true, 'repeat', true, 'status', a.status); end if;
  if not coalesce(p_permanent, false) then
    update owner_debit_attempts set failure_code = left(p_code, 100), failure_message = left(p_message, 500) where id = a.id;
    return jsonb_build_object('ok', true, 'status', 'submitting', 'retry', true);
  end if;
  if p_code in ('resource_missing', 'payment_method_unactivated', 'mandate_invalid', 'payment_intent_mandate_invalid') then
    update owner_payment_methods m set status = 'revoked'
      from owner_payment_method_secrets s
     where s.owner_payment_method_id = m.id and m.owner_id = a.owner_id and s.processor_mandate_id = a.processor_mandate_id and m.status = 'active';
  end if;
  return app.owner_debit_fail(a.id, p_code, p_message);
end $$;

-- A failed debit: the payment is failed, the invoice is failed (0007 adds the Late Fee once) with the next
-- attempt scheduled after the retry day and the gap, or in arrears once owner_debit_max_attempts debits of this
-- invoice have been returned (a debit skipped or canceled is not an attempt that counts).
create or replace function app.owner_debit_fail(p_attempt uuid, p_code text, p_message text) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  a owner_debit_attempts;
  i owner_invoices;
  s program_settings := app.settings();
  v_next date;
  v_new uuid;
  v_failed integer;
  v_msg text := coalesce(nullif(btrim(p_message), ''), 'The debit was returned by the bank.');
begin
  select * into a from owner_debit_attempts where id = p_attempt for update;
  if a.status in ('failed', 'succeeded', 'canceled', 'skipped') then return jsonb_build_object('ok', true, 'repeat', true, 'status', a.status); end if;
  update owner_debit_attempts set status = 'failed', failure_code = left(p_code, 100), failure_message = left(v_msg, 500), settled_at = now()
   where id = a.id;
  update payments set status = 'failed', decline_count = decline_count + 1, last_decline_code = left(v_msg, 200), processed_at = now()
   where id = a.payment_id and status = 'pending';
  update owner_debit_runs set failed = failed + 1 where id = a.run_id;
  select count(*) into v_failed from owner_debit_attempts where owner_invoice_id = a.owner_invoice_id and status = 'failed';
  select * into i from owner_invoices where id = a.owner_invoice_id for update;
  if i.status not in ('processing', 'retry_processing', 'issued', 'failed') then
    return jsonb_build_object('ok', true, 'status', 'failed', 'invoice_status', i.status);
  end if;

  if v_failed < s.owner_debit_max_attempts then
    v_next := greatest(app.local_date(now()) + s.owner_debit_retry_gap_days,
                       case when v_failed = 1 then app.retry_date(a.debit_on) else a.debit_on end);
    perform set_config('app.debit_attempt_no', v_failed::text, true);
    if i.status <> 'failed' then
      update owner_invoices set status = 'failed', retry_on = v_next, debit_on = v_next where id = i.id;
    else
      update owner_invoices set retry_on = v_next, debit_on = v_next where id = i.id;
    end if;
    perform set_config('app.debit_attempt_no', '', true);
    select * into i from owner_invoices where id = i.id;
    if i.balance_cents > 0 then
      insert into owner_debit_attempts (owner_invoice_id, owner_id, notice_id, run_id, attempt_no, debit_on, amount_cents, idempotency_key, bank_last4)
      values (i.id, i.owner_id, a.notice_id, null, a.attempt_no + 1, v_next, i.balance_cents, 'owner-debit:' || gen_random_uuid(), a.bank_last4)
      returning id into v_new;
    end if;
    return jsonb_build_object('ok', true, 'status', 'failed', 'invoice_status', 'failed', 'retry_on', v_next, 'next_attempt', v_new);
  end if;

  -- the last attempt: in arrears (from processing through failed, without the "we retry" email)
  perform set_config('app.debit_no_retry', i.id::text, true);
  if i.status in ('processing', 'issued') then
    update owner_invoices set status = 'failed', retry_on = null, debit_on = null where id = i.id;
  end if;
  update owner_invoices set status = 'in_arrears', debit_on = null where id = i.id;
  perform set_config('app.debit_no_retry', '', true);
  return jsonb_build_object('ok', true, 'status', 'failed', 'invoice_status', 'in_arrears');
end $$;

-- What Stripe says about a debit's PaymentIntent (the webhook, the poll, or the submission itself).
-- p: {status (Stripe's), charge_id, error_code, error_message, bank: {name, last4}, mandate_id}. Idempotent.
create or replace function app.owner_debit_result(p_intent text, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  a owner_debit_attempts;
  i owner_invoices;
  v_status text := p ->> 'status';
  r jsonb;
begin
  select * into a from owner_debit_attempts where processor_intent_id = p_intent for update;
  if a.id is null then return jsonb_build_object('ok', false, 'reason', 'not_a_debit'); end if;
  update owner_debit_attempts set last_checked_at = now() where id = a.id;
  if a.status in ('succeeded', 'failed', 'canceled') then return jsonb_build_object('ok', true, 'repeat', true, 'status', a.status); end if;
  select * into i from owner_invoices where id = a.owner_invoice_id;
  if v_status = 'succeeded' then
    r := app.record_owner_invoice_payment(i.id, jsonb_build_object(
           'status', 'succeeded', 'method', 'pre_authorized_debit', 'amount_cents', a.amount_cents, 'currency', 'cad',
           'processor', jsonb_build_object('processor', 'stripe', 'payment_id', p_intent, 'charge_id', p ->> 'charge_id',
                                           'customer_id', a.processor_customer_id, 'method_id', a.processor_method_id, 'mandate_id', a.processor_mandate_id),
           'bank', jsonb_build_object('name', p #>> '{bank,name}', 'last4', coalesce(p #>> '{bank,last4}', a.bank_last4)), 'save_method', false), null);
    update owner_debit_attempts set status = 'succeeded', settled_at = now(), payment_id = coalesce(payment_id, (r ->> 'payment_id')::uuid) where id = a.id;
    update owner_invoices set debit_on = null where id = i.id and status = 'paid';
    update owner_debit_runs set succeeded = succeeded + 1 where id = a.run_id;
    return jsonb_build_object('ok', true, 'status', 'succeeded', 'invoice_status', r ->> 'invoice_status');
  elsif v_status = 'requires_payment_method' then
    return app.owner_debit_fail(a.id, coalesce(p ->> 'error_code', 'debit_failed'), p ->> 'error_message');
  elsif v_status = 'canceled' then
    update owner_debit_attempts set status = 'canceled', skip_reason = 'canceled at the processor', settled_at = now() where id = a.id;
    update payments set status = 'cancelled', processed_at = now() where id = a.payment_id and status = 'pending';
    update owner_invoices set status = case status when 'processing' then 'issued' when 'retry_processing' then 'failed' else status end,
           debit_on = null where id = i.id;
    return jsonb_build_object('ok', true, 'status', 'canceled');
  end if;
  return jsonb_build_object('ok', true, 'status', 'processing');
end $$;

-- Debits still processing after owner_debit_poll_hours (and not checked since): the Edge Function asks
-- Stripe again, in case a webhook was missed.
create or replace function app.owner_debit_poll(p_now timestamptz default now(), p_limit integer default 25) returns jsonb
language sql stable security definer set search_path = public, app as $$
  select coalesce(jsonb_agg(jsonb_build_object('attempt_id', a.id, 'intent_id', a.processor_intent_id) order by a.submitted_at), '[]'::jsonb)
    from (select * from owner_debit_attempts a
           where a.status = 'processing' and a.processor_intent_id is not null
             and a.submitted_at < p_now - make_interval(hours => (app.settings(app.local_date(p_now))).owner_debit_poll_hours)
             and coalesce(a.last_checked_at, a.submitted_at) < p_now - make_interval(hours => (app.settings(app.local_date(p_now))).owner_debit_poll_hours)
           order by a.submitted_at limit greatest(p_limit, 1)) a
$$;

-- End of one Edge Function call: each debit run whose debits were all sent (none still due, none waiting to be sent
-- again) closes, and the Admins get one summary of it.
create or replace function app.owner_debit_run_close(p_now timestamptz default now()) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  v_day date := app.local_date(p_now);
  r owner_debit_runs;
  v_open integer := 0;
  v_closed integer := 0;
begin
  for r in select * from owner_debit_runs where kind = 'debit' and status = 'running' and run_on <= v_day order by run_on for update loop
    if exists (select 1 from owner_debit_attempts a where a.run_id = r.id and a.status = 'submitting')
       or (r.run_on = v_day and exists (select 1 from owner_debit_attempts a where a.status = 'scheduled' and a.debit_on <= v_day)) then
      v_open := v_open + 1;
      continue;
    end if;
    update owner_debit_runs set status = 'succeeded', finished_at = now() where id = r.id returning * into r;
    if r.summary_sent_at is null and (r.submitted + r.skipped + r.failed) > 0 then
      perform app.ntf_emit('staff_owner_debit_run', 'owner_debit_run', r.id, 'summary', '{}'::jsonb);
      update owner_debit_runs set summary_sent_at = now() where id = r.id;
    end if;
    v_closed := v_closed + 1;
  end loop;
  return jsonb_build_object('open', v_open > 0, 'open_runs', v_open, 'closed_runs', v_closed);
end $$;

-- Stripe says a mandate is no longer active (mandate.updated): the debit method is revoked and the owner
-- and an Admin are told; scheduled debits will ask for banking.
create or replace function app.owner_mandate_inactive(p_mandate text) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  v_owner uuid;
  v_n integer;
begin
  update owner_payment_methods m set status = 'revoked', is_default = false
    from owner_payment_method_secrets s
   where s.owner_payment_method_id = m.id and s.processor_mandate_id = p_mandate and m.status = 'active'
  returning m.owner_id into v_owner;
  get diagnostics v_n = row_count;
  if v_n = 0 then return jsonb_build_object('ok', true, 'revoked', 0); end if;
  perform app.emit_event('owner_bank_details_changed', 'owner', v_owner,
    jsonb_build_object('owner_id', v_owner, 'change_summary', 'Your pre-authorized debit authorization was cancelled at your bank',
                       'changed_at', now(), 'changed_by', 'your bank'),
    'owner_bank_details_changed:' || v_owner || ':mandate:' || p_mandate);
  perform app.ntf_emit('staff_owner_debit_exception', 'owner', v_owner, 'mandate:' || p_mandate,
    jsonb_build_object('owner_id', v_owner, 'exception', 'mandate_revoked'));
  return jsonb_build_object('ok', true, 'revoked', v_n, 'owner_id', v_owner);
end $$;

-- The owner set up a pre-authorized debit from the Banking page (a SetupIntent): the method and its mandate are
-- saved as the owner's debit method. p: {status (succeeded | processing | requires_action), customer_id,
-- method_id, mandate_id, bank: {name, last4}}. A verification still to come (micro-deposits) is saved pending.
create or replace function app.owner_record_debit_setup(p_by uuid, p_owner uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  v_id uuid;
  v_active boolean := p ->> 'status' = 'succeeded';
begin
  if nullif(p ->> 'method_id', '') is null or nullif(p ->> 'mandate_id', '') is null or nullif(p ->> 'customer_id', '') is null then
    raise exception 'The bank setup did not finish' using errcode = '22023';
  end if;
  select m.id into v_id from owner_payment_methods m join owner_payment_method_secrets s on s.owner_payment_method_id = m.id
   where m.owner_id = p_owner and s.processor_method_id = p ->> 'method_id';
  if v_id is not null then
    update owner_payment_methods set status = case when v_active then 'active' else status end where id = v_id;
    update owner_payment_method_secrets set processor_mandate_id = p ->> 'mandate_id' where owner_payment_method_id = v_id;
    return jsonb_build_object('ok', true, 'repeat', true, 'method_id', v_id, 'active', v_active);
  end if;
  v_id := app.record_owner_payment_method(p_owner, p_by, jsonb_build_object('kind', 'pre_authorized_debit', 'brand_or_bank', p #>> '{bank,name}',
            'last4', p #>> '{bank,last4}', 'processor_customer_id', p ->> 'customer_id', 'processor_method_id', p ->> 'method_id',
            'processor_mandate_id', p ->> 'mandate_id'));
  if not v_active then update owner_payment_methods set status = 'pending' where id = v_id; end if;
  update tasks set status = 'done', completed_at = now()
   where owner_id = p_owner and task_type = 'owner_debit_no_mandate' and status in ('open', 'in_progress', 'waiting') and v_active;
  return jsonb_build_object('ok', true, 'method_id', v_id, 'active', v_active);
end $$;

-- A SetupIntent verified later (setup_intent.succeeded): the pending debit method becomes active.
create or replace function app.owner_debit_setup_verified(p_method text, p_mandate text) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  v_owner uuid;
begin
  update owner_payment_methods m set status = 'active'
    from owner_payment_method_secrets s
   where s.owner_payment_method_id = m.id and s.processor_method_id = p_method and m.status = 'pending'
  returning m.owner_id into v_owner;
  if v_owner is not null then
    update owner_payment_method_secrets s set processor_mandate_id = coalesce(nullif(p_mandate, ''), s.processor_mandate_id)
      from owner_payment_methods m where m.id = s.owner_payment_method_id and s.processor_method_id = p_method;
    update tasks set status = 'done', completed_at = now()
     where owner_id = v_owner and task_type = 'owner_debit_no_mandate' and status in ('open', 'in_progress', 'waiting');
  end if;
  return jsonb_build_object('ok', true, 'owner_id', v_owner);
end $$;

-- What the Banking page needs to start a debit setup: the owner, the processor customer on file, the agreement's
-- values from settings.
create or replace function app.owner_debit_setup_facts(p_by uuid) returns jsonb
language sql stable security definer set search_path = public, app as $$
  select jsonb_build_object('owner_id', o.id, 'owner_type', o.owner_type, 'name', o.legal_name, 'email', o.email,
    'customer_id', coalesce(
      (select s.processor_customer_id from owner_payment_methods m join owner_payment_method_secrets s on s.owner_payment_method_id = m.id
        where m.owner_id = o.id and nullif(s.processor_customer_id, '') is not null order by m.created_at desc limit 1),
      (select d.raw ->> 'customer_id' from payments p join payment_processor_details d on d.payment_id = p.id
        where p.owner_id = o.id and d.processor = 'stripe' and d.raw ->> 'customer_id' is not null order by p.created_at desc limit 1)),
    'terms', app.owner_debit_terms())
    from owners o where o.id = app.portal_owner_id(p_by)
$$;

-- The agreement's schedule in words, from settings (the pay page, the setup page and the Stripe mandate).
create or replace function app.owner_debit_terms() returns jsonb
language sql stable security definer set search_path = public, app as $$
  select jsonb_build_object('debit_day', s.billing_day, 'retry_day', s.retry_day, 'notice_days', s.owner_debit_notice_days,
    'max_attempts', s.owner_debit_max_attempts, 'retry_gap_days', s.owner_debit_retry_gap_days, 'late_fee_cents', s.owner_late_fee_cents,
    'late_fee', app.fmt_money(s.owner_late_fee_cents), 'debit_day_text', app.ordinal(s.billing_day), 'retry_day_text', app.ordinal(s.retry_day),
    'interval_description', format('On the %s of each month for the fees on your CarmaCars invoices, with notice %s days before; a returned debit is tried again from the %s',
                                   app.ordinal(s.billing_day), s.owner_debit_notice_days, app.ordinal(s.retry_day)))
    from app.settings() s
$$;

create or replace function app.ordinal(p integer) returns text
language sql immutable as $$
  select p || case when p % 100 in (11, 12, 13) then 'th' when p % 10 = 1 then 'st' when p % 10 = 2 then 'nd' when p % 10 = 3 then 'rd' else 'th' end
$$;

-- ================================================================ 6. reads and Admin actions
-- One invoice's automatic debit, for the owner and for staff.
create or replace function app.owner_invoice_debit(p_invoice uuid) returns jsonb
language sql stable security definer set search_path = public, app as $$
  select jsonb_build_object(
    'debit_on', i.debit_on, 'paused', i.auto_debit_paused or o.auto_debit_paused,
    'paused_reason', coalesce(i.auto_debit_paused_reason, o.auto_debit_paused_reason),
    'blocked', app.owner_debit_block(i.id),
    'attempt', (select jsonb_build_object('attempt_no', a.attempt_no, 'status', a.status, 'debit_on', a.debit_on, 'amount_cents', a.amount_cents,
                  'bank_last4', a.bank_last4, 'failure_message', a.failure_message, 'skip_reason', a.skip_reason, 'submitted_at', a.submitted_at,
                  'settled_at', a.settled_at)
                  from owner_debit_attempts a where a.owner_invoice_id = i.id order by a.attempt_no desc limit 1),
    'attempts', (select count(*) from owner_debit_attempts a where a.owner_invoice_id = i.id and a.status in ('processing', 'succeeded', 'failed')))
    from owner_invoices i join owners o on o.id = i.owner_id where i.id = p_invoice
$$;

-- The owner's automatic debit in one block: mandate on file, paused, the next debit (date, total, invoices),
-- the date of the next notice.
create or replace function app.owner_debit_summary(p_owner uuid) returns jsonb
language sql stable security definer set search_path = public, app as $$
  with m as (select app.owner_debit_mandate(p_owner) j),
       nxt as (select min(a.debit_on) d from owner_debit_attempts a where a.owner_id = p_owner and a.status = 'scheduled')
  select jsonb_build_object(
    'enabled', s.owner_debit_enabled,
    'mandate', (select j is not null from m),
    'bank', (select j ->> 'bank' from m), 'bank_last4', (select j ->> 'last4' from m),
    'pending_setup', exists (select 1 from owner_payment_methods pm where pm.owner_id = p_owner and pm.kind = 'pre_authorized_debit' and pm.status = 'pending'),
    'paused', o.auto_debit_paused, 'paused_reason', o.auto_debit_paused_reason,
    'next_debit_on', (select d from nxt),
    'next_debit_cents', (select coalesce(sum(a.amount_cents), 0) from owner_debit_attempts a, nxt where a.owner_id = p_owner and a.status = 'scheduled' and a.debit_on = nxt.d),
    'next_debit_invoices', (select coalesce(jsonb_agg(i.invoice_number order by i.invoice_number), '[]'::jsonb) from owner_debit_attempts a join owner_invoices i on i.id = a.owner_invoice_id, nxt
                             where a.owner_id = p_owner and a.status = 'scheduled' and a.debit_on = nxt.d),
    'processing_cents', (select coalesce(sum(a.amount_cents), 0) from owner_debit_attempts a where a.owner_id = p_owner and a.status in ('submitting', 'processing')),
    'next_notice_on', app.owner_debit_next_date(app.today()) - s.owner_debit_notice_days,
    'next_cycle_on', app.owner_debit_next_date(app.today()),
    'notice_days', s.owner_debit_notice_days, 'terms', app.owner_debit_terms())
    from owners o cross join lateral (select * from app.settings()) s where o.id = p_owner
$$;

-- The owner portal: 0029's invoices and invoice, each with its debit; the home with the debit block.
alter function app.owner_portal_invoices(uuid) rename to owner_portal_invoices_0029;
create or replace function app.owner_portal_invoices(p_by uuid) returns jsonb
language sql stable security definer set search_path = public, app as $$
  select coalesce(jsonb_agg(x || jsonb_build_object('debit', app.owner_invoice_debit((x ->> 'id')::uuid))), '[]'::jsonb)
    from jsonb_array_elements(app.owner_portal_invoices_0029(p_by)) x
$$;
alter function app.owner_invoice_view(uuid) rename to owner_invoice_view_0029;
create or replace function app.owner_invoice_view(p_invoice uuid) returns jsonb
language sql stable security definer set search_path = public, app as $$
  select app.owner_invoice_view_0029(p_invoice) || jsonb_build_object('debit', app.owner_invoice_debit(p_invoice))
$$;
alter function app.owner_portal_home(uuid) rename to owner_portal_home_0029;
create or replace function app.owner_portal_home(p_by uuid) returns jsonb
language sql stable security definer set search_path = public, app as $$
  select h || jsonb_build_object('auto_debit', app.owner_debit_summary((h #>> '{owner,id}')::uuid),
                                 'next_billing_date', app.owner_debit_next_date(app.today()))
    from app.owner_portal_home_0029(p_by) h
$$;

-- Admin > Owner debits: settings, the next cycle, what is scheduled, processing and done, the runs, pauses and
-- the owners without a mandate.
create or replace function app.admin_owner_debits(p jsonb default '{}'::jsonb) returns jsonb
language sql stable security definer set search_path = public, app as $$
  with s as (select * from app.settings()),
  att as (select a.*, i.invoice_number, i.status as invoice_status, i.kind as invoice_kind, o.legal_name as owner_name,
                 app.vehicle_name(i.vehicle_id) as vehicle_name
            from owner_debit_attempts a join owner_invoices i on i.id = a.owner_invoice_id join owners o on o.id = a.owner_id)
  select jsonb_build_object(
    'settings', (select jsonb_build_object('enabled', s.owner_debit_enabled, 'debit_day', s.billing_day, 'retry_day', s.retry_day,
                   'notice_days', s.owner_debit_notice_days, 'max_attempts', s.owner_debit_max_attempts, 'retry_gap_days', s.owner_debit_retry_gap_days,
                   'run_hour', s.owner_debit_run_hour, 'kinds', s.owner_debit_kinds, 'late_fee_cents', s.owner_late_fee_cents) from s),
    'next_debit_on', app.owner_debit_next_date(app.today()),
    'next_notice_on', app.owner_debit_next_date(app.today()) - (select owner_debit_notice_days from s),
    'counts', (select jsonb_build_object('scheduled', count(*) filter (where status = 'scheduled'), 'processing', count(*) filter (where status in ('submitting', 'processing')),
                 'failed_30d', count(*) filter (where status = 'failed' and settled_at > now() - interval '30 days'),
                 'succeeded_30d', count(*) filter (where status = 'succeeded' and settled_at > now() - interval '30 days'),
                 'scheduled_cents', coalesce(sum(amount_cents) filter (where status = 'scheduled'), 0),
                 'processing_cents', coalesce(sum(amount_cents) filter (where status in ('submitting', 'processing')), 0)) from att),
    'upcoming', (select coalesce(jsonb_agg(jsonb_build_object('id', a.id, 'invoice_id', a.owner_invoice_id, 'invoice_number', a.invoice_number,
                   'owner_id', a.owner_id, 'owner_name', a.owner_name, 'vehicle_name', a.vehicle_name, 'attempt_no', a.attempt_no, 'debit_on', a.debit_on,
                   'amount_cents', a.amount_cents, 'status', a.status, 'bank_last4', a.bank_last4) order by a.debit_on, a.owner_name), '[]'::jsonb)
                   from att a where a.status in ('scheduled', 'submitting', 'processing')),
    'recent', (select coalesce(jsonb_agg(x order by x ->> 'at' desc), '[]'::jsonb) from (
                 select jsonb_build_object('id', a.id, 'invoice_id', a.owner_invoice_id, 'invoice_number', a.invoice_number, 'owner_id', a.owner_id,
                   'owner_name', a.owner_name, 'vehicle_name', a.vehicle_name, 'attempt_no', a.attempt_no, 'debit_on', a.debit_on, 'amount_cents', a.amount_cents,
                   'status', a.status, 'reason', coalesce(a.failure_message, a.skip_reason), 'intent', a.processor_intent_id,
                   'at', coalesce(a.settled_at, a.updated_at)) x
                   from att a where a.status in ('succeeded', 'failed', 'skipped', 'canceled') order by coalesce(a.settled_at, a.updated_at) desc limit 100) q),
    'runs', (select coalesce(jsonb_agg(jsonb_build_object('id', r.id, 'run_on', r.run_on, 'kind', r.kind, 'status', r.status, 'notices_sent', r.notices_sent,
               'no_mandate', r.no_mandate, 'scheduled', r.scheduled, 'submitted', r.submitted, 'succeeded', r.succeeded, 'failed', r.failed, 'skipped', r.skipped,
               'submitted_cents', r.submitted_cents, 'started_at', r.started_at, 'finished_at', r.finished_at, 'error', r.error, 'summary', r.summary)
               order by r.run_on desc, r.kind), '[]'::jsonb)
               from (select * from owner_debit_runs order by run_on desc, kind limit 60) r),
    'notices', (select coalesce(jsonb_agg(jsonb_build_object('id', n.id, 'owner_id', n.owner_id, 'owner_name', o.legal_name, 'debit_on', n.debit_on,
                  'invoices', cardinality(n.invoice_ids), 'total_cents', n.total_cents, 'bank_last4', n.bank_last4, 'mandate_missing', n.mandate_missing,
                  'sent_at', n.sent_at) order by n.sent_at desc), '[]'::jsonb)
                  from (select * from owner_debit_notices order by sent_at desc limit 60) n join owners o on o.id = n.owner_id),
    'paused_owners', (select coalesce(jsonb_agg(jsonb_build_object('id', o.id, 'name', o.legal_name, 'reason', o.auto_debit_paused_reason, 'at', o.auto_debit_paused_at)
                        order by o.legal_name), '[]'::jsonb) from owners o where o.auto_debit_paused),
    'paused_invoices', (select coalesce(jsonb_agg(jsonb_build_object('id', i.id, 'invoice_number', i.invoice_number, 'owner_name', o.legal_name,
                          'reason', i.auto_debit_paused_reason, 'at', i.auto_debit_paused_at, 'balance_cents', i.balance_cents) order by i.invoice_number), '[]'::jsonb)
                          from owner_invoices i join owners o on o.id = i.owner_id where i.auto_debit_paused and i.status not in ('paid', 'void', 'deducted')),
    'owners', (select coalesce(jsonb_agg(jsonb_build_object('id', o.id, 'name', o.legal_name, 'is_test', o.is_test, 'paused', o.auto_debit_paused,
                 'mandate', app.owner_debit_mandate(o.id) is not null, 'bank_last4', app.owner_debit_mandate(o.id) ->> 'last4',
                 'open_cents', (select coalesce(sum(i.balance_cents), 0) from owner_invoices i where i.owner_id = o.id and i.status in ('issued', 'failed', 'processing', 'retry_processing', 'in_arrears', 'partially_deducted')),
                 'open_invoices', (select count(*) from owner_invoices i where i.owner_id = o.id and i.status in ('issued', 'failed', 'processing', 'retry_processing', 'in_arrears', 'partially_deducted')))
                 order by o.legal_name), '[]'::jsonb)
                 from owners o where o.status in ('lead', 'active', 'in_default', 'exited')
                   and exists (select 1 from owner_invoices i where i.owner_id = o.id and i.status <> 'void')))
$$;

-- Pause or resume the automatic debit for an owner or one invoice (an Admin, with the reason; audited).
-- A paused invoice can still be paid by the owner or recorded by an Admin; scheduled attempts are skipped.
create or replace function app.owner_debit_set_pause(p_admin uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  v_pause boolean := coalesce((p ->> 'paused')::boolean, true);
  v_reason text := nullif(btrim(coalesce(p ->> 'reason', '')), '');
  v_owner uuid := nullif(p ->> 'owner', '')::uuid;
  v_invoice uuid := nullif(p ->> 'invoice', '')::uuid;
  v_n integer;
begin
  perform app.assert_admin(p_admin);
  if v_pause and v_reason is null then raise exception 'Give the reason for the pause' using errcode = '22023'; end if;
  if (v_owner is null) = (v_invoice is null) then raise exception 'Choose an owner or an invoice' using errcode = '22023'; end if;
  if v_owner is not null then
    update owners set auto_debit_paused = v_pause, auto_debit_paused_reason = case when v_pause then v_reason end,
           auto_debit_paused_at = case when v_pause then now() end, auto_debit_paused_by = case when v_pause then p_admin end
     where id = v_owner;
  else
    update owner_invoices set auto_debit_paused = v_pause, auto_debit_paused_reason = case when v_pause then v_reason end,
           auto_debit_paused_at = case when v_pause then now() end, auto_debit_paused_by = case when v_pause then p_admin end
     where id = v_invoice;
  end if;
  get diagnostics v_n = row_count;
  if v_n = 0 then raise exception 'Not found' using errcode = 'P0002'; end if;
  insert into audit_log (actor_user_id, action, entity_table, entity_id, after)
  values (p_admin, case when v_pause then 'owner_debit_pause' else 'owner_debit_resume' end,
          case when v_owner is not null then 'owners' else 'owner_invoices' end, coalesce(v_owner, v_invoice)::text,
          jsonb_build_object('paused', v_pause, 'reason', v_reason));
  return jsonb_build_object('ok', true, 'paused', v_pause);
end $$;

-- An Admin schedules an owner's open invoices now for the first debit day the notice allows (or a later day given).
create or replace function app.owner_debit_schedule_now(p_admin uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  v_on date := coalesce(nullif(p ->> 'debit_on', '')::date, app.today() + (app.settings()).owner_debit_notice_days);
begin
  perform app.assert_admin(p_admin);
  if not (app.settings()).owner_debit_enabled then raise exception 'Automatic debits are off in Program settings' using errcode = '23514'; end if;
  return app.owner_debit_schedule((p ->> 'owner')::uuid, v_on, app.owner_debit_run('notice', app.today()), p_admin);
end $$;

-- The Admin portal's reads and actions: two names in front of 0030's and 0035's lists.
alter function app.admin_read(uuid, text, jsonb) rename to admin_read_0030;
create or replace function app.admin_read(p_admin uuid, p_what text, p jsonb default '{}'::jsonb)
returns jsonb language plpgsql security definer set search_path = public, app as $$
begin
  if p_what = 'owner_debits' then
    perform app.admin_begin(p_admin);
    return app.admin_owner_debits(coalesce(p, '{}'::jsonb));
  elsif p_what = 'company_sections' then
    perform app.admin_begin(p_admin);
    return (select cs.sections from company_statements cs where cs.statement_month = app.month_start((p ->> 'month')::date));
  end if;
  return app.admin_read_0030(p_admin, p_what, p);
end $$;
alter function app.admin_do(uuid, text, jsonb) rename to admin_do_0035;
create or replace function app.admin_do(p_admin uuid, p_action text, p jsonb default '{}'::jsonb)
returns jsonb language plpgsql security definer set search_path = public, app as $$
begin
  if p_action in ('owner_debit_pause', 'owner_debit_resume') then
    perform app.admin_begin(p_admin);
    return app.owner_debit_set_pause(p_admin, coalesce(p, '{}'::jsonb) || jsonb_build_object('paused', p_action = 'owner_debit_pause'));
  elsif p_action = 'owner_debit_schedule' then
    perform app.admin_begin(p_admin);
    return app.owner_debit_schedule_now(p_admin, coalesce(p, '{}'::jsonb));
  elsif p_action = 'company_statement_email' then
    -- the month's company statements, to the Admin asking (PDFs attached by the sender)
    perform app.admin_begin(p_admin);
    return app.company_statement_email(app.month_start((p ->> 'month')::date), p_admin);
  end if;
  return app.admin_do_0035(p_admin, p_action, p);
end $$;

-- ================================================================ 7. emails: who, what, when
-- Staff notices about a test owner go only to the verification accounts, at once (never a digest line that
-- a real Admin's digest would carry).
alter function app.notification_recipients(app_events, notification_catalogue) rename to notification_recipients_0032;
create or replace function app.notification_recipients(p_event app_events, p_c notification_catalogue)
returns table (audience text, user_id uuid, email text, name text, renter_id uuid, owner_id uuid, immediate boolean)
language plpgsql stable security definer set search_path = public, app as $$
declare
  v_owner uuid := app.event_owner(p_event);
  v_test boolean := coalesce((select o.is_test from owners o where o.id = v_owner), false);
begin
  if not v_test or p_c.audience not like 'staff_%' then
    return query select * from app.notification_recipients_0032(p_event, p_c);
    return;
  end if;
  return query select r.audience, r.user_id, r.email, r.name, r.renter_id, r.owner_id, true
                 from app.notification_recipients_0032(p_event, p_c) r
                where lower(coalesce(r.email, '')) like 'verify-%@carmacars.ca';
end $$;

-- The owner an event is about, where it is about one.
create or replace function app.event_owner(p_event app_events) returns uuid
language sql stable security definer set search_path = public, app as $$
  select coalesce((p_event.payload ->> 'owner_id')::uuid,
    case p_event.entity
      when 'owner' then p_event.entity_id
      when 'owner_invoice' then (select i.owner_id from owner_invoices i where i.id = p_event.entity_id)
      when 'owner_statement' then (select s.owner_id from owner_statements s where s.id = p_event.entity_id)
      when 'owner_debit_notice' then (select n.owner_id from owner_debit_notices n where n.id = p_event.entity_id)
      when 'owner_debit_attempt' then (select a.owner_id from owner_debit_attempts a where a.id = p_event.entity_id)
      when 'payout' then (select p.owner_id from payouts p where p.id = p_event.entity_id)
    end)
$$;

-- 0023's owner invoice emails, with two changes for the automatic debit: a failure after a retry is emailed again
-- (the discriminator carries the attempt), and the last failure goes straight to "in arrears" without "we retry".
create or replace function app.ntf_owner_invoices_after() returns trigger
language plpgsql security definer set search_path = public, app as $$
declare
  pl jsonb := jsonb_build_object('owner_id', new.owner_id, 'vehicle_id', new.vehicle_id);
  v_att text := nullif(current_setting('app.debit_attempt_no', true), '');
begin
  if tg_op = 'UPDATE' and new.status is not distinct from old.status then return null; end if;
  if new.status = 'issued' and new.kind = 'upfront' then
    perform app.ntf_emit('owner_upfront_invoice', 'owner_invoice', new.id, 'issued', pl);
  elsif new.status = 'issued' and new.kind = 'monthly' and (tg_op = 'INSERT' or old.status = 'draft') then
    perform app.ntf_emit('owner_fee_invoice', 'owner_invoice', new.id, 'issued', pl);
  elsif new.status = 'paid' then
    perform app.ntf_emit('owner_payment_received', 'owner_invoice', new.id, 'paid', pl);
  elsif new.status = 'failed' then
    if coalesce(current_setting('app.debit_no_retry', true), '') = new.id::text then return null; end if;
    perform app.ntf_emit('owner_payment_failed', 'owner_invoice', new.id, 'failed' || case when coalesce(v_att, '1') <> '1' then ':' || v_att else '' end, pl);
    perform app.ntf_emit('staff_owner_invoice_failed', 'owner_invoice', new.id, 'failed' || case when coalesce(v_att, '1') <> '1' then ':' || v_att else '' end, pl);
  elsif new.status = 'in_arrears' then
    perform app.ntf_emit('owner_in_arrears', 'owner_invoice', new.id, 'in_arrears', pl);
    perform app.ntf_emit('staff_owner_invoice_failed', 'owner_invoice', new.id, 'in_arrears',
                         pl || jsonb_build_object('_immediate_roles', jsonb_build_array('staff_admin')));
  end if;
  return null;
end $$;

-- The merge values of the new emails, and the debit wording of the existing invoice emails.
alter function app.notification_payload(text, app_events, jsonb) rename to ntf_payload_0035;
create or replace function app.notification_payload(p_code text, p_event app_events, p_to jsonb) returns jsonb
language plpgsql stable security definer set search_path = public, app as $$
declare
  x jsonb := app.ntf_payload_0035(p_code, p_event, p_to);
  n owner_debit_notices;
  a owner_debit_attempts;
  r owner_debit_runs;
  o owners;
  inv owner_invoices;
  cs company_statements;
  s program_settings := app.settings();
  v_ids uuid[];
  v_owner uuid;
  v_debit date;
begin
  if p_code in ('owner_debit_notice', 'owner_debit_setup_needed', 'staff_owner_debit_exception') then
    if p_event.entity = 'owner_debit_notice' then
      select * into n from owner_debit_notices where id = p_event.entity_id;
      v_ids := n.invoice_ids; v_owner := n.owner_id; v_debit := n.debit_on;
    elsif p_event.entity = 'owner_debit_attempt' then
      select * into a from owner_debit_attempts where id = p_event.entity_id;
      v_ids := array[a.owner_invoice_id]; v_owner := a.owner_id; v_debit := a.debit_on;
    else
      v_owner := coalesce((p_event.payload ->> 'owner_id')::uuid, p_event.entity_id);
      select array_agg(i.id) into v_ids from owner_invoices i
       where i.owner_id = v_owner and i.status in ('issued', 'failed') and i.balance_cents > 0;
      v_debit := app.owner_debit_next_date(app.today());
    end if;
    select * into o from owners where id = v_owner;
    x := x || jsonb_build_object(
      'first_name', coalesce(x ->> 'first_name', o.first_name, split_part(o.legal_name, ' ', 1)),
      'owner_name', o.legal_name,
      'debit_date', app.fmt_day(v_debit),
      'debit_total', app.fmt_money(coalesce(n.total_cents, a.amount_cents,
                                            (select sum(i.balance_cents) from owner_invoices i where i.id = any (coalesce(v_ids, '{}'))), 0)),
      'debit_count_text', coalesce(cardinality(v_ids), 0) || case when coalesce(cardinality(v_ids), 0) = 1 then ' invoice' else ' invoices' end,
      'debit_items', coalesce((select jsonb_agg(jsonb_build_object('invoice_number', i.invoice_number, 'vehicle', app.vehicle_name(i.vehicle_id),
                                 'covers', case i.kind when 'monthly' then to_char(i.period_month, 'FMMonth YYYY') when 'upfront' then 'First and last month'
                                                when 'tracker_install' then 'Tracker install' else coalesce(nullif(to_char(i.period_month, 'FMMonth YYYY'), ''), 'Other charges') end,
                                 'amount', app.fmt_money(i.balance_cents)) order by i.billing_date, i.invoice_number)
                                 from owner_invoices i where i.id = any (coalesce(v_ids, '{}'))), '[]'::jsonb),
      'bank_last4', coalesce(n.bank_last4, a.bank_last4, app.owner_debit_mandate(v_owner) ->> 'last4', 'not set up'),
      'notice_days', s.owner_debit_notice_days::text,
      'late_fee', app.fmt_money(s.owner_late_fee_cents),
      'retry_text', case when s.owner_debit_max_attempts > 1
                         then format('we try again from the %s', app.ordinal(s.retry_day))
                         else 'the amount is deducted from your next payout' end,
      'exception_title', case p_event.payload ->> 'exception'
                           when 'no_mandate' then 'No pre-authorized debit on file'
                           when 'mandate_revoked' then 'Debit authorization cancelled at the bank'
                           when 'amount_changed' then 'Balance changed after the notice'
                           else 'Debit not sent' end,
      'exception_detail', case p_event.payload ->> 'exception'
                           when 'no_mandate' then 'The owner has no active pre-authorized debit. They were emailed a link to set it up in Banking. Nothing is debited until they do; they can also pay from each invoice page.'
                           when 'mandate_revoked' then 'Stripe reports the owner''s debit mandate is no longer active. Scheduled debits will ask the owner to set up banking again.'
                           else coalesce(nullif(p_event.payload ->> 'reason', ''), 'The scheduled debit was not sent.') end,
      '_url', case when p_code like 'staff_%' then app.ntf_link('admin_debits') else app.ntf_link(case when p_code = 'owner_debit_setup_needed' then 'owner_banking' else 'owner_billing' end) end);
  elsif p_code = 'staff_owner_debit_run' then
    select * into r from owner_debit_runs where id = p_event.entity_id;
    x := x || jsonb_build_object(
      'run_date', app.fmt_day(r.run_on), 'submitted_count', r.submitted::text, 'submitted_total', app.fmt_money(r.submitted_cents),
      'skipped_count', r.skipped::text, 'failed_count', r.failed::text, 'no_mandate_count', r.no_mandate::text,
      'run_items', coalesce((select jsonb_agg(jsonb_build_object('owner', o2.legal_name, 'invoice_number', i.invoice_number, 'amount', app.fmt_money(a2.amount_cents),
                               'status', case a2.status when 'processing' then 'Sent, processing' when 'succeeded' then 'Paid' when 'failed' then 'Failed'
                                                        when 'skipped' then 'Not sent: ' || coalesce(a2.skip_reason, '') when 'canceled' then 'Not needed: ' || coalesce(a2.skip_reason, '')
                                                        else initcap(a2.status) end) order by o2.legal_name, i.invoice_number)
                               from owner_debit_attempts a2 join owner_invoices i on i.id = a2.owner_invoice_id join owners o2 on o2.id = a2.owner_id
                              where a2.run_id = r.id), '[]'::jsonb),
      '_url', app.ntf_link('admin_debits'));
  elsif p_code in ('owner_fee_invoice', 'owner_upfront_invoice') then
    select * into inv from owner_invoices where id = p_event.entity_id;
    if s.owner_debit_enabled and inv.kind = any (s.owner_debit_kinds) and app.owner_debit_mandate(inv.owner_id) is not null then
      x := x || jsonb_build_object('bank_last4', format('By pre-authorized debit on %s from your account ending %s (notice %s days before). You can also pay from the invoice page.',
                                                         app.fmt_day(coalesce(inv.debit_on, app.owner_debit_next_date(app.today()))),
                                                         app.owner_debit_mandate(inv.owner_id) ->> 'last4', s.owner_debit_notice_days));
    end if;
  elsif p_code = 'owner_payment_failed' then
    select * into inv from owner_invoices where id = p_event.entity_id;
    x := x || jsonb_build_object('retry_amount', app.fmt_money(inv.balance_cents));
  elsif p_code = 'staff_monthly_statements_pdfs' then
    select * into cs from company_statements where id = p_event.entity_id;
    x := x || app.company_statement_mail_values(cs);
  end if;
  return x;
end $$;

-- ================================================================ 8. statements by email, with the PDFs attached
alter table company_statements
  add column sections jsonb not null default '[]'::jsonb,
  add column emailed_at timestamptz,
  add column emailed_version integer;

-- The generated documents gain the three company statement PDFs: the total with every section, one page per
-- owner and one block per vehicle. Their key is the statement id and its version, so a rebuild is a new file.
alter table generated_documents drop constraint generated_documents_kind_check;
alter table generated_documents add constraint generated_documents_kind_check check (kind in ('owner_statement', 'renter_statement', 'receipt',
  'insurer_invoice', 'investor_statement', 'investor_year', 'company_statement', 'company_owners', 'company_vehicles'));
alter type document_kind add value if not exists 'company_statement';

create or replace function app.company_doc_key(cs company_statements) returns text
language sql immutable as $$ select cs.id::text || ':' || lpad(least(cs.version, 9999)::text, 4, '0') $$;

alter function app.file_access(uuid, text, text) rename to file_access_0032;
create or replace function app.file_access(p_user uuid, p_kind text, p_key text) returns boolean
language plpgsql stable security definer set search_path = public, app as $$
begin
  if p_kind in ('company_statement', 'company_owners', 'company_vehicles') then
    return p_user is not null and app.user_is_admin(p_user);
  end if;
  return app.file_access_0032(p_user, p_kind, p_key);
end $$;

alter function app.file_record(text, text, text, text, text, text) rename to file_record_0032;
create or replace function app.file_record(p_kind text, p_key text, p_bucket text, p_path text, p_sha256 text, p_title text) returns uuid
language plpgsql security definer set search_path = public, app as $$
declare
  v_doc uuid;
begin
  if p_kind not in ('company_statement', 'company_owners', 'company_vehicles') then
    return app.file_record_0032(p_kind, p_key, p_bucket, p_path, p_sha256, p_title);
  end if;
  select document_id into v_doc from generated_documents where kind = p_kind and entity_key = p_key;
  if v_doc is not null then return v_doc; end if;
  if nullif(btrim(p_path), '') is null or nullif(btrim(p_sha256), '') is null then
    raise exception 'A stored document needs its path and SHA-256' using errcode = '22023';
  end if;
  insert into documents (kind, title, storage_bucket, storage_path, mime_type, sha256)
  values ('company_statement'::text::document_kind, left(p_title, 200), p_bucket, p_path, 'application/pdf', p_sha256)
  returning id into v_doc;
  insert into generated_documents (kind, entity_key, document_id, sha256) values (p_kind, p_key, v_doc, p_sha256);
  update company_statements set document_id = coalesce(document_id, v_doc) where id = app.file_key_id(p_key) and p_kind = 'company_statement';
  return v_doc;
end $$;

-- What the company statement PDFs print. A versioned key is stored once rendered (final or not): the version keeps
-- a rebuilt draft apart.
alter function app.pdf_facts(text, text, uuid) rename to pdf_facts_0032;
create or replace function app.pdf_facts(p_kind text, p_key text, p_user uuid default null) returns jsonb
language plpgsql stable security definer set search_path = public, app as $$
declare
  cs company_statements;
  v_month text;
  v_out jsonb;
begin
  if p_kind not in ('company_statement', 'company_owners', 'company_vehicles') then
    v_out := app.pdf_facts_0032(p_kind, p_key, p_user);
    return case when v_out is null then null else v_out || jsonb_build_object('company', app.doc_company_brand()) end;
  end if;
  -- '<id>:<version>' is that version, stored once (the email); '<id>' alone is the current version, rendered for the screen
  select * into cs from company_statements where id = app.file_key_id(p_key);
  if cs.id is null or (p_key like '%:%' and app.company_doc_key(cs) <> p_key) then return null; end if;
  v_month := to_char(cs.statement_month, 'FMMonth YYYY');
  return jsonb_build_object(
    'final', true, 'store', p_key like '%:%', 'draft', cs.status <> 'final', 'status', cs.status, 'version', cs.version,
    'title', case p_kind when 'company_statement' then 'CarmaCars statement, ' || v_month
                         when 'company_owners' then 'Statement by owner, ' || v_month else 'Statement by vehicle, ' || v_month end,
    'file_name', 'carmacars-' || replace(p_kind, '_', '-') || '-' || to_char(cs.statement_month, 'YYYY-MM') || '-v' || cs.version || '.pdf',
    'statement_month', cs.statement_month, 'built_at', cs.built_at, 'finalized_at', cs.finalized_at, 'ties_ok', cs.ties_ok, 'tie_problems', cs.tie_problems,
    'issued_at', coalesce(cs.finalized_at, cs.built_at),
    'total', (select to_jsonb(l) from company_statement_lines l where l.statement_id = cs.id and l.level = 'total' limit 1),
    'owners', case when p_kind = 'company_owners' then (select coalesce(jsonb_agg(to_jsonb(l) || jsonb_build_object('owner_name', o.legal_name) order by o.legal_name), '[]'::jsonb)
                from company_statement_lines l join owners o on o.id = l.owner_id where l.statement_id = cs.id and l.level = 'owner') end,
    'vehicles', case when p_kind = 'company_vehicles' then (select coalesce(jsonb_agg(to_jsonb(l) || jsonb_build_object('vehicle_name', app.vehicle_name(l.vehicle_id),
                  'plate', v.plate, 'owner_name', o.legal_name) order by o.legal_name, app.vehicle_name(l.vehicle_id)), '[]'::jsonb)
                from company_statement_lines l join vehicles v on v.id = l.vehicle_id left join owners o on o.id = l.owner_id
               where l.statement_id = cs.id and l.level = 'vehicle') end,
    'sections', case when p_kind = 'company_statement' then cs.sections end,
    'company', app.doc_company_brand());
end $$;

-- The company block with the logo the site uses (site_settings), for the branded PDFs.
create or replace function app.doc_company_brand() returns jsonb
language sql stable security definer set search_path = public, app as $$
  select app.doc_company() || jsonb_build_object('logo_key', (select coalesce(nullif(ss.logo_light_file_key, ''), null) from site_settings ss order by ss.created_at limit 1))
$$;

-- Due statement emails: approved owner statements on the owner statement email day of the month after the
-- statement month (never before the statement is approved), investor statements as before, and the
-- company statements on their email day. Never older than 45 days, so a first run sends no backlog.
create or replace function app.statement_mail_due(p_now timestamptz default now()) returns jsonb
language sql stable security definer set search_path = public, app as $$
  select coalesce(jsonb_agg(x order by x ->> 'due'), '[]'::jsonb) from (
    select jsonb_build_object('kind', 'owner_statement', 'key', s.id::text, 'due', d.due) x
      from owner_statements s
      cross join lateral (select (app.month_start(s.statement_month) + interval '1 month')::date
                                 + ((app.settings((app.month_start(s.statement_month) + interval '1 month')::date)).owner_statement_email_day - 1) as due) d
     where s.status in ('approved', 'paid') and s.sent_at is null
       and d.due <= app.local_date(p_now) and d.due > app.local_date(p_now) - 45
    union all
    select jsonb_build_object('kind', 'investor_statement', 'key', r.id::text, 'due', r.payment_date)
      from investment_returns r join investments i on i.id = r.investment_id join investors v on v.id = i.investor_id
     where r.status in ('paid', 'reinvested') and r.statement_sent_at is null and v.status in ('active', 'exited')
       and r.payment_date <= app.local_date(p_now) and r.payment_date > app.local_date(p_now) - 45
    union all
    select jsonb_build_object('kind', k.kind, 'key', app.company_doc_key(cs), 'due', d.due, 'group', 'company:' || cs.id)
      from company_statements cs
      cross join lateral (select (cs.statement_month + interval '1 month')::date
                                 + ((app.settings((cs.statement_month + interval '1 month')::date)).company_statement_email_day - 1) as due) d
      cross join (values ('company_statement'), ('company_owners'), ('company_vehicles')) k(kind)
     where cs.emailed_at is null and d.due <= app.local_date(p_now) and d.due > app.local_date(p_now) - 45
    limit 60) q
$$;

-- Sends one statement email once its PDF is stored. The company statements go together, when all three of
-- the current version are stored.
alter function app.statement_mail_release(text, text) rename to statement_mail_release_0033;
create or replace function app.statement_mail_release(p_kind text, p_key text) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  cs company_statements;
begin
  if p_kind not in ('company_statement', 'company_owners', 'company_vehicles') then
    return app.statement_mail_release_0033(p_kind, p_key);
  end if;
  select * into cs from company_statements where id = app.file_key_id(p_key) for update;
  if cs.id is null or app.company_doc_key(cs) <> p_key then return jsonb_build_object('sent', false, 'reason', 'rebuilt since'); end if;
  if cs.emailed_at is not null then return jsonb_build_object('sent', false, 'reason', 'already sent'); end if;
  if (select count(*) from generated_documents g where g.entity_key = p_key and g.kind in ('company_statement', 'company_owners', 'company_vehicles')) < 3 then
    if not exists (select 1 from generated_documents g where g.entity_key = p_key and g.kind = p_kind) then
      raise exception 'Render and store the PDF first' using errcode = '23514';
    end if;
    return jsonb_build_object('sent', false, 'reason', 'waiting for the other PDFs');
  end if;
  update company_statements set emailed_at = now(), emailed_version = version where id = cs.id;
  perform app.emit_event('staff_monthly_statements_pdfs', 'company_statement', cs.id, jsonb_build_object('version', cs.version),
                         'staff_monthly_statements_pdfs:' || cs.id || ':v' || cs.version);
  return jsonb_build_object('sent', true, 'kind', p_kind, 'key', p_key);
end $$;

-- An Admin asks for the month's company statements by email (to themselves only). The PDFs are rendered by the
-- server first when they are not stored yet (the sender attaches them).
create or replace function app.company_statement_email(p_month date, p_admin uuid) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  cs company_statements;
begin
  select * into cs from company_statements where statement_month = app.month_start(p_month);
  if cs.id is null then raise exception 'Build the statement for this month first' using errcode = 'P0002'; end if;
  perform app.emit_event('staff_monthly_statements_pdfs', 'company_statement', cs.id,
                         jsonb_build_object('version', cs.version, 'recipient_user_id', p_admin),
                         'staff_monthly_statements_pdfs:' || cs.id || ':v' || cs.version || ':to:' || p_admin || ':' || extract(epoch from now())::bigint);
  return jsonb_build_object('ok', true, 'key', app.company_doc_key(cs));
end $$;

-- The summary values the company statements email shows.
create or replace function app.company_statement_mail_values(cs company_statements) returns jsonb
language sql stable security definer set search_path = public, app as $$
  select jsonb_build_object(
    'statement_month', to_char(cs.statement_month, 'FMMonth YYYY'),
    'statement_status', case when cs.status = 'final' then 'Final' else 'Draft, version ' || cs.version end,
    'ties_text', case when cs.ties_ok then 'All checks tie out' else 'Some checks do not tie: ' || coalesce(cs.tie_problems, 'see the statement') end,
    'rental_revenue', app.fmt_money(coalesce(t.rental_revenue_cents, 0)), 'revenue_share', app.fmt_money(coalesce(t.revenue_share_cents, 0) + coalesce(t.turo_revenue_share_cents, 0)),
    'company_fees', app.fmt_money(coalesce(t.company_fees_cents, 0)),
    'owner_fees', app.fmt_money(coalesce(t.insurance_fees_cents, 0) + coalesce(t.tracker_fees_cents, 0) + coalesce(t.install_fees_cents, 0) + coalesce(t.other_owner_fees_cents, 0)),
    'company_net', app.fmt_money(coalesce(t.company_net_cents, 0)),
    'owner_count', (select count(*) from company_statement_lines l where l.statement_id = cs.id and l.level = 'owner')::text,
    'vehicle_count', (select count(*) from company_statement_lines l where l.statement_id = cs.id and l.level = 'vehicle')::text,
    '_url', app.ntf_link('admin_reports'))
    from (select 1) one left join company_statement_lines t on t.statement_id = cs.id and t.level = 'total'
$$;

-- Files a sent email carries as attachments: each by its kind and key (the sender fetches the stored PDF
-- through the site's signed link) and the file name.
create or replace function app.outbox_attachments(p_outbox uuid) returns jsonb
language plpgsql stable security definer set search_path = public, app as $$
declare
  o notification_outbox;
  cs company_statements;
  v_key text;
begin
  select * into o from notification_outbox where id = p_outbox;
  if o.id is null then return '[]'::jsonb; end if;
  if o.code = 'owner_statement_ready' and o.entity = 'owner_statement' then
    return jsonb_build_array(jsonb_build_object('k', 'owner_statement', 'key', o.entity_id::text,
      'filename', (select 'CarmaCars statement ' || s.statement_number || '.pdf' from owner_statements s where s.id = o.entity_id)));
  elsif o.code = 'investor_statement_ready' then
    return coalesce((select jsonb_build_array(jsonb_build_object('k', 'investor_statement', 'key', r.id::text,
      'filename', 'CarmaCars investor statement ' || to_char(r.return_month, 'YYYY-MM') || '.pdf'))
      from investment_returns r where r.id = o.entity_id), '[]'::jsonb);
  elsif o.code in ('staff_monthly_statements_pdfs', 'staff_monthly_statements_ready') and o.entity = 'company_statement' then
    select * into cs from company_statements where id = o.entity_id;
    if cs.id is null then return '[]'::jsonb; end if;
    v_key := app.company_doc_key(cs);
    return jsonb_build_array(
      jsonb_build_object('k', 'company_statement', 'key', v_key, 'filename', 'CarmaCars statement ' || to_char(cs.statement_month, 'YYYY-MM') || '.pdf'),
      jsonb_build_object('k', 'company_owners', 'key', v_key, 'filename', 'CarmaCars statement by owner ' || to_char(cs.statement_month, 'YYYY-MM') || '.pdf'),
      jsonb_build_object('k', 'company_vehicles', 'key', v_key, 'filename', 'CarmaCars statement by vehicle ' || to_char(cs.statement_month, 'YYYY-MM') || '.pdf'));
  end if;
  return '[]'::jsonb;
end $$;

-- The company statement emails link to the statement PDF as well (7 days).
alter function app.outbox_file_refs(uuid) rename to outbox_file_refs_0033;
create or replace function app.outbox_file_refs(p_outbox uuid) returns jsonb
language plpgsql stable security definer set search_path = public, app as $$
declare
  o notification_outbox;
  cs company_statements;
begin
  select * into o from notification_outbox where id = p_outbox;
  if o.code in ('staff_monthly_statements_pdfs') and o.entity = 'company_statement' then
    select * into cs from company_statements where id = o.entity_id;
    return jsonb_build_object('statement_url', jsonb_build_object('k', 'company_statement', 'key', app.company_doc_key(cs)));
  end if;
  return app.outbox_file_refs_0033(p_outbox);
end $$;

-- ================================================================ 9. CarmaCars' statement: the sections of blueprint 11 section 3.3
-- Stored on the statement at each build (so a final month keeps what it showed): each section is
-- {key, title, note, rows: [{label, cents | count | text | bps, account, strong}]}.
create or replace function app.company_section(p_key text, p_title text, p_rows jsonb, p_note text default null) returns jsonb
language sql immutable as $$
  select jsonb_build_object('key', p_key, 'title', p_title, 'note', p_note, 'rows', coalesce(p_rows, '[]'::jsonb))
$$;
create or replace function app.csr(p_label text, p_cents numeric, p_account text default null, p_strong boolean default false) returns jsonb
language sql immutable as $$ select jsonb_strip_nulls(jsonb_build_object('label', p_label, 'cents', coalesce(p_cents, 0)::bigint, 'account', p_account, 'strong', nullif(p_strong, false))) $$;
create or replace function app.csn(p_label text, p_count numeric, p_unit text default null) returns jsonb
language sql immutable as $$ select jsonb_strip_nulls(jsonb_build_object('label', p_label, 'count', coalesce(p_count, 0), 'unit', p_unit)) $$;

create or replace function app.company_statement_sections(p_month date) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  m0 date := app.month_start(p_month);
  m1 date := (app.month_start(p_month) + interval '1 month')::date;
  t0 timestamptz := app.local_midnight(app.month_start(p_month));
  t1 timestamptz := app.local_midnight((app.month_start(p_month) + interval '1 month')::date);
  cs company_statements;
  t company_statement_lines;
  v jsonb := '[]'::jsonb;
  v_rows jsonb;
  v_fees jsonb;
  v_rev bigint;
  v_cost bigint;
begin
  select * into cs from company_statements where statement_month = m0;
  if cs.id is null then return '[]'::jsonb; end if;
  select * into t from company_statement_lines where statement_id = cs.id and level = 'total' limit 1;

  -- company-only renter fees by account (fee_types.gl_account, 0021)
  select coalesce(jsonb_object_agg(acct, amt), '{}'::jsonb) into v_fees from (
    select coalesce(ft.gl_account, '4100') as acct, sum((e.value)::bigint) as amt
      from company_statement_lines l cross join lateral jsonb_each_text(l.company_fees_by_type) e
      left join fee_types ft on ft.code = e.key
     where l.statement_id = cs.id and l.level = 'vehicle' group by 1) q;

  -- 1. income summary by account
  v_rev := coalesce(t.revenue_share_cents, 0) + coalesce(t.turo_revenue_share_cents, 0)
         + coalesce(t.insurance_fees_cents, 0) + coalesce(t.tracker_fees_cents, 0) + coalesce(t.install_fees_cents, 0) + coalesce(t.other_owner_fees_cents, 0)
         + coalesce(t.late_fees_cents, 0) + coalesce(t.company_fees_cents, 0) + coalesce(t.turo_extras_cents, 0) + greatest(coalesce(t.claim_surplus_cents, 0), 0);
  v_cost := coalesce(t.processing_fees_cents, 0) + greatest(-coalesce(t.claim_surplus_cents, 0), 0) + coalesce(t.company_paid_tolls_cents, 0)
          + coalesce(t.expenses_cents, 0) + coalesce(t.investor_returns_cents, 0);
  v := v || app.company_section('income', 'Income summary', jsonb_build_array(
    app.csr('Revenue Share on rentals', t.revenue_share_cents, '4000'),
    app.csr('Revenue Share on Turo trips', t.turo_revenue_share_cents, '4000'),
    app.csr('Owner fees: Insurance Fee', t.insurance_fees_cents, '4010'),
    app.csr('Owner fees: Tracker Fee', t.tracker_fees_cents, '4010'),
    app.csr('Owner fees: Tracker Install Fee', t.install_fees_cents, '4010'),
    app.csr('Owner fees: other', t.other_owner_fees_cents, '4010'),
    app.csr('Owner Late Fees', t.late_fees_cents, '4020'),
    app.csr('Renter service fees', coalesce((v_fees ->> '4100')::bigint, 0) + coalesce(t.turo_extras_cents, 0), '4100'),
    app.csr('Coverage sold', (v_fees ->> '4110')::bigint, '4110'),
    app.csr('Administration fees', (v_fees ->> '4120')::bigint, '4120'),
    app.csr('Interest on overdue charges', (v_fees ->> '4130')::bigint, '4130'),
    app.csr('Claim surplus', greatest(coalesce(t.claim_surplus_cents, 0), 0), '4140'),
    app.csr('Total revenue', v_rev, null, true),
    app.csr('Processing fees', -coalesce(t.processing_fees_cents, 0), '5000'),
    app.csr('Claim shortfalls borne by CarmaCars', -greatest(-coalesce(t.claim_surplus_cents, 0), 0), '5200'),
    app.csr('Tolls and tickets CarmaCars pays', -coalesce(t.company_paid_tolls_cents, 0), '5110'),
    app.csr('Costs entered', -coalesce(t.expenses_cents, 0)),
    app.csr('Investor returns', -coalesce(t.investor_returns_cents, 0), '5010'),
    app.csr('Total costs', -v_cost, null, true),
    app.csr('Contribution before costs not in the platform', t.company_net_cents, null, true))
    || coalesce((select jsonb_agg(app.csr('Costs entered: ' || c.label, -sum_amt, c.gl_account) order by c.label)
                   from (select ec.label, ec.gl_account, sum(e.amount_cents) sum_amt from company_expenses e join company_expense_categories ec on ec.code = e.category
                          where e.expense_on >= m0 and e.expense_on < m1 and e.voided_at is null group by ec.label, ec.gl_account) c), '[]'::jsonb),
    'Earned basis: rentals in the month they end, owner fees in the month they cover.');

  -- 2. rentals and fleet
  v := v || app.company_section('fleet', 'Fleet and rentals', jsonb_build_array(
    app.csn('Vehicles on the program at the start', (select count(*) from vehicles x where x.enrollment_date < m0 and coalesce(app.vehicle_fee_end(x.id), m0) >= m0)),
    app.csn('Vehicles added', (select count(*) from vehicles x where x.enrollment_date >= m0 and x.enrollment_date < m1)),
    app.csn('Vehicles removed', (select count(*) from vehicles x where app.vehicle_fee_end(x.id) >= m0 and app.vehicle_fee_end(x.id) < m1)),
    app.csn('Vehicles on the program at the end', (select count(*) from vehicles x where x.enrollment_date < m1 and coalesce(app.vehicle_fee_end(x.id), m1) >= m1)),
    app.csn('Days in the program', t.days_in_program, 'days'), app.csn('Days available', t.days_available, 'days'),
    app.csn('Days rented', t.days_rented, 'days'), app.csn('Owner days', t.owner_days, 'days'),
    jsonb_build_object('label', 'Utilization', 'bps', coalesce(t.utilization_bps, 0)),
    app.csn('Rentals ended', t.rentals_ended), app.csn('Billable days', t.billable_days, 'days'),
    app.csn('Average rental length', case when coalesce(t.rentals_ended, 0) > 0 then round(t.billable_days::numeric / t.rentals_ended, 1) else 0 end, 'days'),
    app.csr('Average daily rate', t.avg_daily_rate_cents), app.csr('Revenue per available day', t.revpad_cents),
    app.csr('Rental Charge', t.rental_revenue_cents), app.csr('Mileage overage', t.mileage_cents),
    app.csr('Referral kickbacks deducted', -coalesce(t.kickbacks_cents, 0)), app.csr('Owner Revenue', t.owner_revenue_cents, null, true),
    app.csr('Owners'' share of rentals', t.owner_share_out_cents, '2110'),
    app.csr('Discounts given', t.discounts_cents), app.csr('Discounts borne by owners', t.discounts_owner_cents),
    app.csr('Discounts borne by CarmaCars', t.discounts_company_cents),
    app.csr('Turo gross', t.turo_gross_cents), app.csr('Turo fees', -coalesce(t.turo_fees_cents, 0)), app.csr('Turo owners'' part', t.turo_owner_cents)));

  -- 3. insurer bookings, tolls and damage recovered
  v := v || app.company_section('recoveries', 'Insurer bookings, tolls and damage', jsonb_build_array(
    app.csn('Insurer-billed bookings ended', (select count(*) from bookings b join insurer_invoices ii on ii.booking_id = b.id
                                               where b.checked_in_at >= t0 and b.checked_in_at < t1)),
    app.csr('Billed to insurers', t.insurer_billed_cents), app.csr('Collected from insurers', t.insurer_collected_cents),
    app.csn('Toll and ticket notices received', (select count(*) from toll_tickets tt where tt.received_on >= m0 and tt.received_on < m1)),
    app.csr('Tolls and tickets charged to renters', (select coalesce(sum(tt.amount_cents), 0) from toll_tickets tt where tt.charged_at >= t0 and tt.charged_at < t1 and tt.matched_to = 'renter')),
    app.csr('Toll and ticket administration fees', (select coalesce(sum(tt.admin_fee_cents), 0) from toll_tickets tt where tt.charged_at >= t0 and tt.charged_at < t1)),
    app.csr('Tolls and tickets billed to owners', (select coalesce(sum(d.amount_cents), 0) from owner_deductions d
                                                     where d.kind in ('owner_booking_toll', 'owner_booking_ticket') and d.incurred_on >= m0 and d.incurred_on < m1)),
    app.csr('Pass-through collected (tolls, tickets, damage at cost)', t.pass_through_in_cents, '2150'),
    app.csr('Pass-through paid to authorities', -coalesce(t.pass_through_out_cents, 0), '2150'),
    app.csn('Damage reports logged', (select count(*) from damage_intakes di where di.created_at >= t0 and di.created_at < t1)),
    app.csr('Claim money received', t.claim_money_in_cents), app.csr('Repairs paid', -coalesce(t.repairs_out_cents, 0)),
    app.csr('Claim result to CarmaCars', t.claim_surplus_cents, '4140')));

  -- 4. held for others (as at the build)
  v := v || app.company_section('held', 'Held for others', jsonb_build_array(
    app.csr('Owner payouts approved, not yet paid', (select coalesce(sum(p.amount_cents + p.hst_cents), 0) from payouts p
                                                       where p.payee_type = 'owner' and p.status in ('draft', 'pending_approval', 'approved', 'sent')), '2110'),
    app.csr('Renter deposits held', t.deposits_held_cents, '2100'),
    app.csr('Prepaid last month''s Insurance Fee', (select coalesce(sum(vp.remaining_cents), 0) from vehicle_prepaids vp), '2120'),
    app.csr('Referral kickbacks payable', (select coalesce(sum(k.amount_cents), 0) from referral_kickbacks k where k.status = 'earned'), '2130'),
    app.csr('Claim funds held', t.claim_balance_cents, '2140'),
    app.csr('Pass-through clearing this month', coalesce(t.pass_through_in_cents, 0) - coalesce(t.pass_through_out_cents, 0), '2150')),
    'Balances as at ' || app.fmt_date(cs.built_at) || '.');

  -- 5. HST
  v := v || app.company_section('hst', 'HST', jsonb_build_array(
    app.csr('HST collected (renters and owner fees)', t.hst_collected_cents, '2200'),
    app.csr('HST on refunds', -coalesce(t.hst_refunded_cents, 0), '2200'),
    app.csr('HST paid (owner payouts and costs)', -coalesce(t.hst_paid_cents, 0), '2210'),
    app.csr('Net HST for the month', coalesce(t.hst_collected_cents, 0) - coalesce(t.hst_refunded_cents, 0) - coalesce(t.hst_paid_cents, 0), null, true)),
    'For the HST return: confirm with the accountant before filing.');

  -- 6. receivables (as at the build)
  v := v || app.company_section('receivables', 'Receivables', jsonb_build_array(
    app.csr('Owner invoices failed or in arrears', (select coalesce(sum(i.balance_cents), 0) from owner_invoices i where i.status in ('failed', 'in_arrears', 'partially_deducted')), '1200'),
    app.csr('Owner invoices issued, not yet due', (select coalesce(sum(i.balance_cents), 0) from owner_invoices i where i.status in ('issued', 'processing', 'retry_processing')), '1200'),
    app.csr('Owner costs to deduct', (select coalesce(sum(d.amount_cents), 0) from owner_deductions d where d.status = 'open'), '1200'),
    app.csr('Owner balances carried forward', (select coalesce(sum(-o.balance_carried_forward_cents), 0) from owners o where o.balance_carried_forward_cents < 0), '1200'),
    app.csr('Renter card payments failed, retry pending', (select coalesce(sum(p.amount_cents), 0) from payments p where p.status = 'failed' and p.booking_id is not null and p.next_retry_at is not null), '1210'),
    app.csr('Insurers: under 30 days', (select coalesce(sum(ii.balance_cents), 0) from insurer_invoices ii where ii.status in ('sent', 'part_paid') and ii.sent_at >= now() - interval '30 days')),
    app.csr('Insurers: 30 to 59 days', (select coalesce(sum(ii.balance_cents), 0) from insurer_invoices ii where ii.status in ('sent', 'part_paid') and ii.sent_at < now() - interval '30 days' and ii.sent_at >= now() - interval '60 days')),
    app.csr('Insurers: 60 to 89 days', (select coalesce(sum(ii.balance_cents), 0) from insurer_invoices ii where ii.status in ('sent', 'part_paid') and ii.sent_at < now() - interval '60 days' and ii.sent_at >= now() - interval '90 days')),
    app.csr('Insurers: 90 days and over', (select coalesce(sum(ii.balance_cents), 0) from insurer_invoices ii where ii.status in ('sent', 'part_paid') and ii.sent_at < now() - interval '90 days'))),
    'Balances as at ' || app.fmt_date(cs.built_at) || '.');

  -- 7. cash: collected by method and purpose, refunds, paid out by kind, processor payouts
  select coalesce(jsonb_agg(app.csr('Collected by ' || replace(method, '_', ' '), amt) order by method), '[]'::jsonb) into v_rows
    from (select p.method, sum(p.amount_cents) amt from payments p
           where p.status = 'succeeded' and p.kind in ('charge', 'capture') and p.processed_at >= t0 and p.processed_at < t1 group by p.method) q;
  v_rows := v_rows || coalesce((select jsonb_agg(app.csr('Collected for ' || replace(purpose, '_', ' '), amt) order by purpose)
    from (select p.purpose, sum(p.amount_cents) amt from payments p
           where p.status = 'succeeded' and p.kind in ('charge', 'capture') and p.processed_at >= t0 and p.processed_at < t1 group by p.purpose) q), '[]'::jsonb);
  v_rows := v_rows || jsonb_build_array(
    app.csr('Total collected', t.cash_collected_cents, null, true),
    app.csr('Refunded', -coalesce(t.cash_refunded_cents, 0)),
    app.csr('Deposits released', -(select coalesce(sum(p.amount_cents), 0) from payments p where p.kind = 'release' and p.status = 'succeeded' and p.processed_at >= t0 and p.processed_at < t1)));
  v_rows := v_rows || coalesce((select jsonb_agg(app.csr('Paid out: ' || replace(kind, '_', ' '), -amt) order by kind)
    from (select p.kind, sum(p.amount_cents + p.hst_cents) amt from payouts p where p.status = 'paid' and p.paid_at >= t0 and p.paid_at < t1 group by p.kind) q), '[]'::jsonb);
  v_rows := v_rows || jsonb_build_array(
    app.csr('Processor payouts received', (select coalesce(sum(r.amount_cents), 0) from payout_reconciliations r where r.paid_on >= m0 and r.paid_on < m1)),
    app.csr('Processor fees on those payouts', -(select coalesce(sum(r.fees_cents), 0) from payout_reconciliations r where r.paid_on >= m0 and r.paid_on < m1)),
    app.csn('Processor payouts not fully matched', (select count(*) from payout_reconciliations r where r.paid_on >= m0 and r.paid_on < m1 and coalesce(r.unmatched_cents, 0) <> 0)));
  v := v || app.company_section('cash', 'Cash', v_rows, 'Cash basis: by the day the money moved.');

  -- 8. owner fees and debits
  v := v || app.company_section('owner_fees', 'Owner fees and debits', jsonb_build_array(
    app.csr('Owner fees billed for the month', coalesce(t.insurance_fees_cents, 0) + coalesce(t.tracker_fees_cents, 0) + coalesce(t.install_fees_cents, 0) + coalesce(t.other_owner_fees_cents, 0), '4010'),
    app.csr('HST on owner fees', t.owner_fees_hst_cents, '2200'),
    app.csr('Prepaid last month billed', t.prepaid_last_month_cents, '2120'),
    app.csr('Collected', t.owner_fees_collected_cents), app.csr('Deducted from payouts', t.owner_fees_deducted_cents),
    app.csr('Outstanding', t.owner_fees_outstanding_cents),
    app.csn('Pre-debit notices sent', (select count(*) from owner_debit_notices n where n.sent_at >= t0 and n.sent_at < t1 and not n.mandate_missing)),
    app.csn('Owners asked to set up a debit', (select count(*) from owner_debit_notices n where n.sent_at >= t0 and n.sent_at < t1 and n.mandate_missing)),
    app.csr('Debited and cleared', (select coalesce(sum(a.amount_cents), 0) from owner_debit_attempts a where a.status = 'succeeded' and a.settled_at >= t0 and a.settled_at < t1)),
    app.csr('Debits returned', -(select coalesce(sum(a.amount_cents), 0) from owner_debit_attempts a where a.status = 'failed' and a.settled_at >= t0 and a.settled_at < t1)),
    app.csn('Debits returned (count)', (select count(*) from owner_debit_attempts a where a.status = 'failed' and a.settled_at >= t0 and a.settled_at < t1)),
    app.csr('Debits still processing', (select coalesce(sum(a.amount_cents), 0) from owner_debit_attempts a where a.status in ('submitting', 'processing')))));

  -- 9. the bookings funnel (requests made in the month)
  v := v || app.company_section('funnel', 'Bookings funnel', jsonb_build_array(
    app.csn('Requests', (select count(distinct e.booking_id) from booking_events e where e.kind = 'requested' and e.created_at >= t0 and e.created_at < t1)),
    app.csn('Offers sent', (select count(*) from booking_events e where e.kind = 'offer_sent' and e.created_at >= t0 and e.created_at < t1)),
    app.csn('Offers approved', (select count(*) from booking_events e where e.kind = 'offer_approved' and e.created_at >= t0 and e.created_at < t1)),
    app.csn('Confirmed', (select count(*) from booking_events e where e.kind = 'confirmed' and e.created_at >= t0 and e.created_at < t1)),
    app.csn('Offers expired', (select count(*) from booking_offers bo where bo.status = 'expired' and bo.expires_at >= t0 and bo.expires_at < t1)),
    app.csn('Pushed back to staff', (select count(*) from booking_events e where e.kind = 'pushed_back' and e.created_at >= t0 and e.created_at < t1)),
    app.csn('Declined', (select count(*) from bookings b where b.status = 'declined' and b.updated_at >= t0 and b.updated_at < t1)),
    app.csn('Cancelled', (select count(*) from booking_events e where e.kind = 'cancelled' and e.created_at >= t0 and e.created_at < t1)),
    app.csn('No-shows', (select count(*) from bookings b where b.status = 'no_show' and b.pickup_at >= t0 and b.pickup_at < t1)),
    app.csn('Median time from request to first offer', coalesce((select round((percentile_cont(0.5) within group (order by extract(epoch from o.first_offer - r.requested_at) / 3600.0))::numeric, 1)
       from (select e.booking_id, min(e.created_at) requested_at from booking_events e where e.kind = 'requested' and e.created_at >= t0 and e.created_at < t1 group by e.booking_id) r
       join (select e.booking_id, min(e.created_at) first_offer from booking_events e where e.kind = 'offer_sent' group by e.booking_id) o on o.booking_id = r.booking_id), 0), 'hours')));

  -- 10. investors
  v := v || app.company_section('investors', 'Investor capital', jsonb_build_array(
    app.csr('Invested at the start of the month', (select coalesce(sum(r.opening_invested_cents), 0) from investment_returns r where r.return_month = m0), '2300'),
    app.csr('New investments', (select coalesce(sum(x.principal_cents), 0) from investments x where x.investment_date >= m0 and x.investment_date < m1), '2300'),
    app.csr('Returns reinvested', (select coalesce(sum(r.return_cents), 0) from investment_returns r where r.return_month = m0 and r.disposition = 'reinvest'), '2300'),
    app.csr('Returns paid', -(select coalesce(sum(r.return_cents), 0) from investment_returns r where r.return_month = m0 and r.disposition = 'pay'), '5010'),
    app.csr('Redemptions paid', -(select coalesce(sum(p.amount_cents), 0) from payouts p where p.payee_type = 'investor' and p.kind like '%redemption%' and p.status = 'paid' and p.paid_at >= t0 and p.paid_at < t1), '2300'),
    app.csr('Invested at the end of the month', (select coalesce(sum(r.closing_invested_cents), 0) from investment_returns r where r.return_month = m0), '2300', true)));

  -- 11. reconciliation checks, as words
  v := v || app.company_section('checks', 'Reconciliation checks',
    coalesce((select jsonb_agg(jsonb_build_object('label', initcap(replace(split_part(coalesce(c ->> 'check', 'check'), ':', 1), '_', ' '))
                                                           || coalesce(': ' || replace(nullif(split_part(c ->> 'check', ':', 2), ''), '_cents', ''), ''),
                 'text', case when coalesce((c ->> 'ok')::boolean, false) then 'Ties'
                              else 'Off by ' || app.fmt_money(coalesce((c ->> 'difference_cents')::bigint, 0)) end))
                from jsonb_array_elements(case when jsonb_typeof(cs.checks) = 'array' then cs.checks else '[]'::jsonb end) c), '[]'::jsonb),
    case when cs.ties_ok then 'Every check ties.' else 'Not every check ties: ' || coalesce(cs.tie_problems, '') end);

  -- 12. adjustments to earlier months (added by app.company_statement_adjustments when the statement is built)
  return v;
end $$;

-- Adjustments to earlier months: for each final month of the last 12, the statement is built again inside a
-- savepoint (and rolled back) and compared with what was frozen; the difference not shown on an earlier
-- statement is listed here.
create or replace function app.company_statement_adjustments(p_month date) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  m0 date := app.month_start(p_month);
  f company_statements;
  frozen company_statement_lines;
  fresh jsonb;
  v_cols text[] := array['rental_revenue_cents', 'revenue_share_cents', 'owner_revenue_cents', 'company_fees_cents', 'insurance_fees_cents',
                         'tracker_fees_cents', 'late_fees_cents', 'refunds_cents', 'hst_collected_cents', 'company_net_cents'];
  c text;
  v_rows jsonb := '[]'::jsonb;
  v_before bigint;
  v_diff bigint;
begin
  for f in select * from company_statements where status = 'final' and statement_month < m0 and statement_month >= (m0 - interval '12 months')::date
           order by statement_month loop
    select * into frozen from company_statement_lines where statement_id = f.id and level = 'total' limit 1;
    fresh := null;
    begin
      update company_statements set status = 'draft' where id = f.id;
      perform app.build_company_statement(f.statement_month, null);
      select to_jsonb(l) into fresh from company_statement_lines l where l.statement_id = f.id and l.level = 'total' limit 1;
      raise exception using errcode = 'P0001', message = 'carmacars_adjustment_probe';
    exception when others then
      if sqlerrm <> 'carmacars_adjustment_probe' then fresh := null; end if;
    end;
    if fresh is null then continue; end if;
    foreach c in array v_cols loop
      v_diff := coalesce((fresh ->> c)::bigint, 0) - coalesce((to_jsonb(frozen) ->> c)::bigint, 0);
      -- what earlier statements already reported for that month and column
      select coalesce(sum((r ->> 'cents')::bigint), 0) into v_before
        from company_statements e cross join lateral jsonb_array_elements(e.sections) sec cross join lateral jsonb_array_elements(sec -> 'rows') r
       where e.statement_month > f.statement_month and e.statement_month < m0 and sec ->> 'key' = 'adjustments'
         and r ->> 'month' = to_char(f.statement_month, 'YYYY-MM') and r ->> 'column' = c;
      if v_diff - v_before <> 0 then
        v_rows := v_rows || jsonb_build_array(jsonb_build_object('label', to_char(f.statement_month, 'FMMonth YYYY') || ': ' || replace(replace(c, '_cents', ''), '_', ' '),
                                                                 'cents', v_diff - v_before, 'month', to_char(f.statement_month, 'YYYY-MM'), 'column', c));
      end if;
    end loop;
  end loop;
  return app.company_section('adjustments', 'Adjustments to earlier months', v_rows,
    case when jsonb_array_length(v_rows) = 0 then 'No change to a closed month since it was frozen.'
         else 'Changes to closed months found when this statement was built; the closed months themselves are not changed.' end);
end $$;

-- The builder of 0021 stores the sections with each build.
alter function app.build_company_statement(date, uuid) rename to build_company_statement_0021;
create or replace function app.build_company_statement(p_month date, p_by uuid default null)
returns uuid language plpgsql security definer set search_path = public, app as $$
declare
  v_id uuid := app.build_company_statement_0021(p_month, p_by);
  v_adj jsonb := '{}'::jsonb;
begin
  -- the probe of earlier months calls this builder again: only the outer build adds the adjustments
  if coalesce(current_setting('app.company_probe', true), '') <> 'on' then
    perform set_config('app.company_probe', 'on', true);
    begin
      v_adj := app.company_statement_adjustments(p_month);
    exception when others then
      v_adj := app.company_section('adjustments', 'Adjustments to earlier months', '[]'::jsonb, 'Could not be worked out: ' || sqlerrm);
    end;
    perform set_config('app.company_probe', '', true);
    update company_statements set sections = app.company_statement_sections(p_month) || jsonb_build_array(v_adj) where id = v_id;
  end if;
  return v_id;
end $$;

-- ================================================================ 10. the email catalogue
insert into notification_link_paths (key, path) values
  ('owner_banking', '/owner/banking'), ('admin_debits', '/admin/debits'), ('admin_reports', '/admin/reports')
on conflict (key) do update set path = excluded.path;

-- the rows of the new emails (their templates are loaded by the deploy's templates step)
-- CATALOGUE 0037 START (generated by supabase/seed/0037_gen_catalogue.mjs; do not edit by hand)
insert into notification_catalogue (code, audience, also_sent_to, category, is_digest, digest_slot, from_address, reply_to,
    subject, preheader, timing, trigger_text, replaces_template, link_path, variables, template_html, template_text) values
  ('owner_debit_notice', 'owner', '{}'::text[], 'transactional', false, null, 'CarmaCars <billing@carmacars.ca>', 'billing@carmacars.ca', 'Pre-authorized debit on {{debit_date}}: {{debit_total}}', '{{debit_count_text}} from your account ending {{bank_last4}}. Nothing to do if your account is up to date.', 'The notice days before the debit day (the 5th for the 15th by default)', 'Owner debit notice job, on the notice day (the debit day less the notice days in Program settings, 10 by default): the owner has issued invoices that will be debited automatically on the debit day from their pre-authorized debit account. One email per owner, listing every invoice in the debit. Required notice under the pre-authorized debit agreement.', null, '/owner/billing', '[{"name":"bank_last4","type":"string"},{"name":"company_address","type":"string","global":true},{"name":"contact_email","type":"string","global":true},{"name":"debit_count_text","type":"string"},{"name":"debit_date","type":"string"},{"name":"debit_items","type":"list","fields":["invoice_number","vehicle","covers","amount"]},{"name":"debit_total","type":"string"},{"name":"first_name","type":"string"},{"name":"instagram_url","type":"url","global":true},{"name":"late_fee","type":"string"},{"name":"notice_days","type":"string"},{"name":"opening_hours","type":"string","global":true},{"name":"reply_time","type":"string","global":true},{"name":"retry_text","type":"string"},{"name":"support_phone","type":"string","global":true},{"name":"tiktok_url","type":"url","global":true}]'::jsonb, 'templates/owner_debit_notice.html', 'templates/owner_debit_notice.txt'),
  ('owner_debit_setup_needed', 'owner', '{}'::text[], 'transactional', false, null, 'CarmaCars <billing@carmacars.ca>', 'billing@carmacars.ca', 'Set up your bank debit for {{debit_total}} due {{debit_date}}', 'We have no pre-authorized debit for your account, so nothing was scheduled. It takes two minutes.', 'The notice day, or the debit day when the agreement was cancelled since the notice', 'Owner debit notice job (or the debit run itself): the owner has invoices due for the automatic debit but no active pre-authorized debit agreement on file, or it was cancelled at the bank. Nothing is debited. One email per owner per debit date. An Admin gets the exception at the same time.', null, '/owner/banking', '[{"name":"company_address","type":"string","global":true},{"name":"contact_email","type":"string","global":true},{"name":"debit_date","type":"string"},{"name":"debit_items","type":"list","fields":["invoice_number","vehicle","covers","amount"]},{"name":"debit_total","type":"string"},{"name":"first_name","type":"string"},{"name":"instagram_url","type":"url","global":true},{"name":"late_fee","type":"string"},{"name":"notice_days","type":"string"},{"name":"opening_hours","type":"string","global":true},{"name":"reply_time","type":"string","global":true},{"name":"support_phone","type":"string","global":true},{"name":"tiktok_url","type":"url","global":true}]'::jsonb, 'templates/owner_debit_setup_needed.html', 'templates/owner_debit_setup_needed.txt'),
  ('staff_owner_debit_exception', 'staff_admin', '{}'::text[], 'transactional', false, null, 'CarmaCars <billing@carmacars.ca>', 'contact@carmacars.ca', 'Owner debit exception: {{owner_name}}, {{exception_title}}', '{{debit_count_text}}, {{debit_total}}, due {{debit_date}}.', 'Immediate', 'An owner''s automatic debit cannot go ahead: no active pre-authorized debit on file at the notice or on the debit day, the agreement was cancelled at the bank (Stripe mandate inactive), the balance grew after the notice, or the invoice is blocked for another reason. Paused invoices are not reported. Immediate to the Admins; an Admin task opens for a missing debit agreement.', null, '/admin/debits', '[{"name":"company_address","type":"string","global":true},{"name":"debit_count_text","type":"string"},{"name":"debit_date","type":"string"},{"name":"debit_items","type":"list","fields":["invoice_number","vehicle","amount"]},{"name":"debit_total","type":"string"},{"name":"exception_detail","type":"string"},{"name":"exception_title","type":"string"},{"name":"owner_name","type":"string"}]'::jsonb, 'templates/staff_owner_debit_exception.html', 'templates/staff_owner_debit_exception.txt'),
  ('staff_owner_debit_run', 'staff_admin', '{}'::text[], 'transactional', false, null, 'CarmaCars <billing@carmacars.ca>', 'contact@carmacars.ca', 'Owner debits sent {{run_date}}: {{submitted_count}} for {{submitted_total}}', '{{skipped_count}} not sent, {{failed_count}} refused at once. Bank results follow over the next days.', 'The debit day (the 15th by default), after the run', 'The owner-debit run of a day is done (every scheduled debit due that day was sent, skipped or cancelled): one summary to the Admins with each debit and its status. Results that come back days later are in Owner debits; a returned debit also sends the owner invoice failure notice to finance.', null, '/admin/debits', '[{"name":"company_address","type":"string","global":true},{"name":"failed_count","type":"string"},{"name":"no_mandate_count","type":"string"},{"name":"run_date","type":"string"},{"name":"run_items","type":"list","fields":["owner","invoice_number","amount","status"]},{"name":"skipped_count","type":"string"},{"name":"submitted_count","type":"string"},{"name":"submitted_total","type":"string"}]'::jsonb, 'templates/staff_owner_debit_run.html', 'templates/staff_owner_debit_run.txt'),
  ('staff_monthly_statements_pdfs', 'staff_admin', '{}'::text[], 'transactional', false, null, 'CarmaCars <billing@carmacars.ca>', 'contact@carmacars.ca', '{{statement_month}} company statements: net {{company_net}}', '{{statement_status}}. {{ties_text}}. Three PDFs attached.', 'The company statement email day (the 10th by default)', 'Statement emails job, on the company statement email day in Program settings (the 10th by default): the company statement for last month exists (draft or final). One email to each Admin with three PDFs attached: the company total with every section, the statement by owner and the statement by vehicle. An Admin can also send it to themselves from Company statements.', null, '/admin/reports', '[{"name":"company_address","type":"string","global":true},{"name":"company_fees","type":"string"},{"name":"company_net","type":"string"},{"name":"first_name","type":"string"},{"name":"link_expiry","type":"string"},{"name":"owner_count","type":"string"},{"name":"owner_fees","type":"string"},{"name":"rental_revenue","type":"string"},{"name":"revenue_share","type":"string"},{"name":"statement_month","type":"string"},{"name":"statement_status","type":"string"},{"name":"statement_url","type":"url"},{"name":"ties_text","type":"string"},{"name":"vehicle_count","type":"string"}]'::jsonb, 'templates/staff_monthly_statements_pdfs.html', 'templates/staff_monthly_statements_pdfs.txt')
on conflict (code) do update set
  audience = excluded.audience, also_sent_to = excluded.also_sent_to, category = excluded.category,
  is_digest = excluded.is_digest, digest_slot = excluded.digest_slot, from_address = excluded.from_address,
  reply_to = excluded.reply_to, subject = excluded.subject, preheader = excluded.preheader, timing = excluded.timing,
  trigger_text = excluded.trigger_text, replaces_template = excluded.replaces_template, link_path = excluded.link_path,
  variables = excluded.variables, template_html = excluded.template_html, template_text = excluded.template_text,
  in_catalogue = true, updated_at = now();
select app.notification_catalogue_refresh();
-- CATALOGUE 0037 END

update notification_catalogue set emitted_by = 'app.owner_debit_schedule (0037)' where code = 'owner_debit_notice';
update notification_catalogue set emitted_by = 'app.owner_debit_schedule and app.owner_debit_claim (0037)' where code = 'owner_debit_setup_needed';
update notification_catalogue set emitted_by = 'app.owner_debit_schedule, app.owner_debit_claim, app.owner_mandate_inactive (0037)' where code = 'staff_owner_debit_exception';
update notification_catalogue set emitted_by = 'app.owner_debit_run_close (0037)' where code = 'staff_owner_debit_run';
update notification_catalogue set emitted_by = 'app.statement_mail_release and app.company_statement_email (0037)' where code = 'staff_monthly_statements_pdfs';
update notification_catalogue set emitted_by = 'owner_invoices_notify (0023, 0037)' where code in ('owner_fee_invoice', 'owner_payment_failed');

-- ================================================================ 11. schedule and privileges

create or replace function public.server_owner_debit_result(p_intent text, p jsonb) returns jsonb
language sql security invoker set search_path = public, app as $$ select app.owner_debit_result(p_intent, p) $$;
create or replace function public.server_owner_mandate_inactive(p_mandate text) returns jsonb
language sql security invoker set search_path = public, app as $$ select app.owner_mandate_inactive(p_mandate) $$;
create or replace function public.server_owner_debit_setup_facts(p_by uuid) returns jsonb
language sql security invoker set search_path = public, app as $$ select app.owner_debit_setup_facts(p_by) $$;
create or replace function public.server_owner_record_debit_setup(p_by uuid, p jsonb) returns jsonb
language sql security invoker set search_path = public, app as $$ select app.owner_record_debit_setup(p_by, app.portal_owner_id(p_by), p) $$;
create or replace function public.server_owner_debit_setup_verified(p_method text, p_mandate text) returns jsonb
language sql security invoker set search_path = public, app as $$ select app.owner_debit_setup_verified(p_method, p_mandate) $$;
create or replace function public.server_owner_debit_terms() returns jsonb
language sql stable security invoker set search_path = public, app as $$ select app.owner_debit_terms() $$;

revoke execute on function
  app.owner_debit_date(date), app.owner_debit_next_date(date), app.owner_debit_mandate(uuid), app.owner_debit_block(uuid), app.owner_debit_run(text, date),
  app.owner_debit_candidates(uuid, date), app.owner_debit_schedule(uuid, date, uuid, uuid, date), app.job_owner_debit_notices(timestamptz),
  app.owner_debit_claim(timestamptz, integer), app.owner_debit_request(owner_debit_attempts, owner_invoices, owners), app.owner_debit_submitted(uuid, jsonb),
  app.owner_debit_submit_error(uuid, text, text, boolean), app.owner_debit_fail(uuid, text, text), app.owner_debit_result(text, jsonb),
  app.owner_debit_poll(timestamptz, integer), app.owner_debit_run_close(timestamptz), app.owner_mandate_inactive(text),
  app.owner_record_debit_setup(uuid, uuid, jsonb), app.owner_debit_setup_verified(text, text), app.owner_debit_setup_facts(uuid), app.owner_debit_terms(),
  app.owner_invoice_debit(uuid), app.owner_debit_summary(uuid), app.admin_owner_debits(jsonb), app.owner_debit_set_pause(uuid, jsonb),
  app.owner_debit_schedule_now(uuid, jsonb), app.event_owner(app_events), app.company_doc_key(company_statements), app.doc_company_brand(),
  app.statement_mail_due(timestamptz), app.statement_mail_release(text, text), app.company_statement_email(date, uuid),
  app.company_statement_mail_values(company_statements), app.outbox_attachments(uuid), app.company_statement_sections(date),
  app.company_statement_adjustments(date),
  public.server_owner_debit_result(text, jsonb), public.server_owner_mandate_inactive(text), public.server_owner_debit_setup_facts(uuid),
  public.server_owner_record_debit_setup(uuid, jsonb), public.server_owner_debit_setup_verified(text, text), public.server_owner_debit_terms()
  from public, anon, authenticated;
grant execute on function
  app.owner_debit_date(date), app.owner_debit_next_date(date), app.owner_debit_mandate(uuid), app.owner_debit_block(uuid), app.owner_debit_run(text, date),
  app.owner_debit_candidates(uuid, date), app.owner_debit_schedule(uuid, date, uuid, uuid, date), app.job_owner_debit_notices(timestamptz),
  app.owner_debit_claim(timestamptz, integer), app.owner_debit_request(owner_debit_attempts, owner_invoices, owners), app.owner_debit_submitted(uuid, jsonb),
  app.owner_debit_submit_error(uuid, text, text, boolean), app.owner_debit_fail(uuid, text, text), app.owner_debit_result(text, jsonb),
  app.owner_debit_poll(timestamptz, integer), app.owner_debit_run_close(timestamptz), app.owner_mandate_inactive(text),
  app.owner_record_debit_setup(uuid, uuid, jsonb), app.owner_debit_setup_verified(text, text), app.owner_debit_setup_facts(uuid), app.owner_debit_terms(),
  app.owner_invoice_debit(uuid), app.owner_debit_summary(uuid), app.admin_owner_debits(jsonb), app.owner_debit_set_pause(uuid, jsonb),
  app.owner_debit_schedule_now(uuid, jsonb), app.event_owner(app_events), app.company_doc_key(company_statements), app.doc_company_brand(),
  app.statement_mail_due(timestamptz), app.statement_mail_release(text, text), app.company_statement_email(date, uuid),
  app.company_statement_mail_values(company_statements), app.outbox_attachments(uuid), app.company_statement_sections(date),
  app.company_statement_adjustments(date),
  public.server_owner_debit_result(text, jsonb), public.server_owner_mandate_inactive(text), public.server_owner_debit_setup_facts(uuid),
  public.server_owner_record_debit_setup(uuid, jsonb), public.server_owner_debit_setup_verified(text, text), public.server_owner_debit_terms()
  to service_role;

-- the notice job: hourly, the wrapper decides the Toronto day and hour (0015's pattern). The owner-debit Edge
-- Function itself is scheduled by the deploy (scripts/deploy/supabase.sh debit), as send-outbox is.
do $$
begin
  if to_regclass('cron.job') is null then
    raise notice 'pg_cron is not available here: the owner debit notice job is not scheduled';
    return;
  end if;
  perform cron.schedule('carmacars-owner-debit-notices', '26 * * * *', 'select app.job_owner_debit_notices()');
end $$;

-- Each wrapper keeps the privileges of the function it wraps (a new function would otherwise be open to everyone).
do $$
declare
  r record;
  v_new regprocedure;
  g text;
begin
  for r in select p.oid, m.new_name, oidvectortypes(p.proargtypes) as args
             from pg_proc p join pg_namespace n on n.oid = p.pronamespace
             join (values ('owner_portal_invoices_0029', 'owner_portal_invoices'), ('owner_invoice_view_0029', 'owner_invoice_view'),
                          ('owner_portal_home_0029', 'owner_portal_home'), ('admin_read_0030', 'admin_read'), ('admin_do_0035', 'admin_do'),
                          ('notification_recipients_0032', 'notification_recipients'), ('ntf_payload_0035', 'notification_payload'),
                          ('file_access_0032', 'file_access'), ('file_record_0032', 'file_record'), ('pdf_facts_0032', 'pdf_facts'),
                          ('statement_mail_release_0033', 'statement_mail_release'), ('outbox_file_refs_0033', 'outbox_file_refs'),
                          ('build_company_statement_0021', 'build_company_statement')) m(old_name, new_name) on m.old_name = p.proname
            where n.nspname = 'app' loop
    v_new := format('app.%I(%s)', r.new_name, r.args)::regprocedure;
    execute format('revoke execute on function %s from public, anon, authenticated', v_new);
    foreach g in array array['anon', 'authenticated', 'service_role'] loop
      if has_function_privilege(g, r.oid, 'execute') then execute format('grant execute on function %s to %I', v_new, g); end if;
    end loop;
  end loop;
end $$;
