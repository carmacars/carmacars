-- 0053_legal_review.sql
-- The owner's final legal review, "CarmaCars: legal text changes before launch" (October 16, 2026), applied as approved
-- (docs/changes/2026-10-16-legal-review-admin-redesign.md):
--   1. billing and pre-authorized debit: the payee "<legal name>, operating as CarmaCars" in the PAD agreement, its
--      confirmation, Stripe's mandate description and every owner billing email; a returned debit is retried only for
--      insufficient funds, once, for the original amount, on the later of the 18th and 3 business days after the return,
--      never more than 30 days after the original debit; any other return: no retry, the invoice's automatic debit
--      paused, an Admin alerted and the owner emailed; the Late Fee its own invoice line, listed in the next pre-debit
--      notice and collected with the next scheduled debit, never added to the retry; the new Late Fee rule; the new
--      mandate description; the confirmation carries the full agreement; the failed-debit email and the void notice
--   2. signatures: every automatic countersignature in the signing officer's name with the new wording; staff recorded as
--      "Proposed by" or "Added by", never as the signer; investment agreements countersigned by the signing officer in
--      Admin ("Awaiting countersignature" until then); staff and partner agreements countersigned automatically, paper
--      records too; every Owner named in the Title Schedule signs with their own link and the agreements take effect
--      when the last one signs; paper records keep the date only; Form C's witness may sign on screen in person
--   3. rentals added by staff: the saved card is charged only when the renter signs ("Accept and sign")
--   4. the renter's protection bought through CarmaCars is the "Protection Plan" everywhere renters read it
-- No applied migration is edited. Functions changed are wrapped (renamed _00NN and called from a new function of the
-- same name) or replaced with the same signature. Function bodies are checked when called.

-- ================================================================ 1. settings
alter table program_settings add column if not exists signing_officer_user_id uuid references users (id);
comment on column program_settings.signing_officer_user_id is
  'The signing officer''s own account (0053). When set, only this Admin may press Countersign on an investment agreement; when empty any Admin may, and who pressed it is recorded.';
-- the signing officer's account: the Admin who signs in as rent@carmacars.ca, the only Admin address (when it exists here)
update program_settings set signing_officer_user_id = (select u.id from users u where lower(u.email) = 'rent@carmacars.ca' limit 1)
 where signing_officer_user_id is null and exists (select 1 from users u where lower(u.email) = 'rent@carmacars.ca');
comment on column program_settings.owner_debit_show_legal_name is
  'No longer used (0053): the payee of the PAD agreement, its confirmation, Stripe''s mandate and the owner billing emails is always "<company_legal_name>, operating as <company_trade_name>".';
update program_settings set owner_debit_show_legal_name = true where not owner_debit_show_legal_name;
-- one retry at most (the legal review): attempts per invoice is 1 or 2
update program_settings set owner_debit_max_attempts = 2 where owner_debit_max_attempts > 2;
do $$
declare
  c text;
begin
  for c in select conname from pg_constraint
            where conrelid = 'public.program_settings'::regclass and contype = 'c' and pg_get_constraintdef(oid) like '%owner_debit_max_attempts%' loop
    execute format('alter table program_settings drop constraint %I', c);
  end loop;
end $$;
alter table program_settings add constraint program_settings_owner_debit_max_attempts_check check (owner_debit_max_attempts between 1 and 2);
comment on column program_settings.owner_debit_max_attempts is
  'Debit attempts per invoice, the first included: 2 (one retry, for insufficient funds only) or 1 (no retry: the Late Fee and the amount are deducted from the next payout)';
comment on column program_settings.owner_debit_retry_gap_days is
  'Business days after the bank reports a returned debit before it is tried again (3 by default); never before retry_day, never more than 30 days after the original debit';

-- Every Owner named in the Title Schedule signs (the legal review): the owner who has the portal signs there; each other
-- Owner (a co-owner, or the individual beside an Owner Corporation) gets their own signing link by email. The program
-- agreements take effect when the last Owner signs.
create table owner_cosigners (
  id            uuid primary key default gen_random_uuid(),
  owner_id      uuid not null references owners (id),
  name          text not null check (length(btrim(name)) between 2 and 200),
  email         text not null check (email ~ '^[^@\s]+@[^@\s]+\.[^@\s]+$'),
  status        text not null default 'pending' check (status in ('pending', 'signed', 'removed')),
  token         text not null unique default (replace(gen_random_uuid()::text, '-', '') || replace(gen_random_uuid()::text, '-', '')),
  link_sent_at  timestamptz,
  link_sent_count integer not null default 0,
  signed_at     timestamptz,
  signature_record_ids uuid[] not null default '{}',
  added_by      uuid references users (id),
  removed_by    uuid references users (id),
  removed_reason text,
  created_at    timestamptz not null default now(),
  updated_at    timestamptz not null default now()
);
create index owner_cosigners_owner_idx on owner_cosigners (owner_id) where status <> 'removed';
create unique index owner_cosigners_one_email on owner_cosigners (owner_id, lower(email)) where status <> 'removed';
create trigger owner_cosigners_updated before update on owner_cosigners for each row execute function app.set_updated_at();
comment on table owner_cosigners is 'The other Owners named in the Title Schedule (0053): each signs the program agreements with their own link; the agreements take effect when the last one signs.';
alter table owner_cosigners enable row level security;
create policy admin_all on owner_cosigners for all to authenticated using (app.is_admin()) with check (app.is_admin());
revoke all on owner_cosigners from anon, authenticated;
grant select on owner_cosigners to authenticated;
grant all on owner_cosigners to service_role;

-- ================================================================ 2. the payee, the Late Fee rule, the agreement, the mandate
create or replace function app.owner_payee_name() returns text
language sql stable security definer set search_path = public, app as $$
  select case when nullif(btrim(s.company_legal_name), '') is not null and s.company_legal_name is distinct from s.company_trade_name
              then s.company_legal_name || ', operating as ' || s.company_trade_name else s.company_trade_name end
    from app.settings() s
$$;

create or replace function app.owner_debit_payee() returns jsonb
language sql stable security definer set search_path = public, app as $$
  select jsonb_build_object('name', app.owner_payee_name(), 'address', coalesce(c ->> 'company_address', ''),
                            'phone', coalesce(c ->> 'support_phone', ''), 'email', 'billing@carmacars.ca')
    from (select app.ntf_contact() as c) k
$$;

-- The one Late Fee rule, word for word as approved. With one attempt per invoice there is no retry: the Late Fee and the
-- amount owed come off the next payout (section 4.4 of the Enrollment Agreement allows both).
create or replace function app.owner_late_fee_rule() returns text
language sql stable security definer set search_path = public, app as $$
  select case when s.owner_debit_max_attempts > 1
              then format('If your bank returns the automatic debit of an invoice for insufficient funds, we add the %s Late Fee to that invoice once and try the original amount again within 30 days, as section 4.4 of your Enrollment Agreement sets out. The Late Fee is collected with your next debit.',
                          app.fmt_money(s.owner_late_fee_cents))
              else format('If your bank returns the automatic debit of an invoice for insufficient funds, we add the %s Late Fee to that invoice once, as section 4.4 of your Enrollment Agreement sets out. The Late Fee and the amount owed are deducted from your next payout.',
                          app.fmt_money(s.owner_late_fee_cents)) end
    from app.settings() s
$$;

-- The recurring pre-authorized debit agreement (the 1.2 text with the payee and the Late Fee rule), one string per
-- paragraph. The Banking page, the invoice page's second box and the confirmation email print exactly these.
create or replace function app.owner_pad_agreement(p_kind text) returns jsonb
language sql stable security definer set search_path = public, app as $$
  select jsonb_build_array(
    format('You authorize %s to debit the bank account you give for the fees on your %s invoices: the monthly fees of your vehicles enrolled with %s (the Insurance Fee, and the Tracker Fee once a tracker is installed, plus HST, as set in your Vehicle Schedule), the first and last month''s Insurance Fee, the Tracker Install Fee and other amounts invoiced to you, on the %s of each month.',
           app.owner_payee_name() || case when app.owner_payee_name() like '%, operating as %' then ',' else '' end,
           s.company_trade_name, s.company_trade_name, app.ordinal(s.billing_day)),
    app.owner_late_fee_rule(),
    format('The amount can change from month to month with your vehicles and their fees. We email you a notice listing every invoice and the total %s days before each debit, and each invoice is in your owner portal. We also email you a confirmation of this agreement once your bank account is set up.',
           s.owner_debit_notice_days),
    format('This authorization is for %s purposes and stays in effect until you cancel it. You may cancel it at any time by writing to billing@carmacars.ca; cancelling it does not end your agreement or the fees you owe. You have certain recourse rights if a debit does not comply with this agreement: for example, the right to be reimbursed for a debit that was not authorized or is not consistent with this agreement. For more information on your recourse rights, contact your financial institution or visit payments.ca.',
           case when p_kind = 'business' then 'business' else 'personal' end))
    from app.settings() s
$$;

-- Stripe's mandate description, as approved.
create or replace function app.owner_mandate_description() returns text
language sql stable security definer set search_path = public, app as $$
  select format('%s o/a %s: fees on your %s invoices on the %s of each month, with notice %s days before.',
                coalesce(nullif(btrim(s.company_legal_name), ''), s.company_trade_name), s.company_trade_name, s.company_trade_name,
                app.ordinal(s.billing_day), s.owner_debit_notice_days)
         || case when s.owner_debit_max_attempts > 1 then ' A debit returned for insufficient funds is retried once for the same amount.' else '' end
    from app.settings() s
$$;

create or replace function app.owner_debit_terms() returns jsonb
language sql stable security definer set search_path = public, app as $$
  select jsonb_build_object('debit_day', s.billing_day, 'retry_day', s.retry_day, 'notice_days', s.owner_debit_notice_days,
    'max_attempts', s.owner_debit_max_attempts, 'retry_gap_days', s.owner_debit_retry_gap_days, 'late_fee_cents', s.owner_late_fee_cents,
    'late_fee', app.fmt_money(s.owner_late_fee_cents), 'debit_day_text', app.ordinal(s.billing_day), 'retry_day_text', app.ordinal(s.retry_day),
    'payout_day_text', app.ordinal(s.payout_day),
    'interval_description', app.owner_mandate_description(),
    'late_fee_rule', app.owner_late_fee_rule(),
    'own_debit_rule', 'A debit you start yourself from an invoice page that your bank returns adds no Late Fee: the invoice stays due and you can pay it again from its page.',
    'agreement', jsonb_build_object('personal', app.owner_pad_agreement('personal'), 'business', app.owner_pad_agreement('business')),
    'payee', app.owner_debit_payee())
    from app.settings() s
$$;

-- ================================================================ 3. a returned debit: insufficient funds, or anything else
alter table owner_debit_attempts add column if not exists is_retry boolean not null default false;
alter table owner_debit_attempts add column if not exists original_debit_on date;
comment on column owner_debit_attempts.is_retry is 'The one retry of a debit returned for insufficient funds (0053): for the original amount only, never the Late Fee';
comment on column owner_debit_attempts.original_debit_on is 'The retry: the day of the debit that was returned (the retry is never more than 30 days after it)';

-- Insufficient funds, as the bank reports it through Stripe (failure code, decline code, or the message).
create or replace function app.owner_debit_is_nsf(p_code text, p_message text) returns boolean
language sql immutable as $$
  select coalesce(lower(p_code), '') in ('insufficient_funds', 'nsf', 'insufficient_funds_in_account')
      or coalesce(lower(p_message), '') ~ '(insufficient|non-sufficient|not sufficient) funds'
$$;

-- The Late Fee line (0007's trigger adds it when an invoice fails): its own line, "Late Fee". A debit returned for any
-- reason other than insufficient funds adds none: app.owner_debit_fail names the invoice in app.debit_no_late_fee.
create or replace function app.owner_invoice_lines_late_fee_guard() returns trigger
language plpgsql security definer set search_path = public, app as $$
begin
  if new.kind = 'late_fee' and new.description = 'Late Fee: missed payment' then
    if coalesce(current_setting('app.debit_no_late_fee', true), '') = new.owner_invoice_id::text then
      return null;
    end if;
    new.description := 'Late Fee';
  end if;
  return new;
end $$;
create trigger owner_invoice_lines_late_fee_guard before insert on owner_invoice_lines
  for each row execute function app.owner_invoice_lines_late_fee_guard();

-- the status flow: a returned debit not retried waits on the invoice page; a cleared retry leaves the Late Fee issued
insert into status_transitions (entity, from_status, to_status, note) values
  ('owner_invoice', 'retry_processing', 'issued', 'the retry cleared the original amount; the Late Fee waits for the next scheduled debit (0053)'),
  ('owner_invoice', 'failed', 'issued', 'the invoice''s fees are paid; the Late Fee waits for the next scheduled debit (0053)')
on conflict do nothing;

-- A failed debit (0037's, rewritten for the legal review):
--   insufficient funds, first attempt, retries allowed: the Late Fee once (its own line), one retry for the original
--     amount on the later of the retry day of the debit's month and 3 business days after today, if that is within 30
--     days of the original debit; otherwise no retry (as below, with the Late Fee)
--   insufficient funds on the retry, or attempts per invoice 1: in arrears, as before (the amount and the Late Fee come
--     off the next payout)
--   any other reason: no retry, no Late Fee, the invoice's automatic debit paused, an Admin task and email, and the
--     owner's own email (owner_debit_returned)
create or replace function app.owner_debit_fail(p_attempt uuid, p_code text, p_message text) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  a owner_debit_attempts;
  i owner_invoices;
  s program_settings := app.settings();
  v_next date;
  v_new uuid;
  v_msg text := coalesce(nullif(btrim(p_message), ''), 'The debit was returned by the bank.');
  v_nsf boolean := app.owner_debit_is_nsf(p_code, p_message);
  v_original date;
  v_failed integer;
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
  v_original := coalesce(a.original_debit_on, a.debit_on);

  if a.is_retry or (v_nsf and s.owner_debit_max_attempts < 2) then
    -- the retry was returned too (for any reason), or no retry is allowed: in arrears, without a second "we retry"
    -- email; the Late Fee (added once, on its own line) and the amount come off the next payout
    perform set_config('app.debit_no_retry', i.id::text, true);
    if i.status in ('processing', 'issued') then
      update owner_invoices set status = 'failed', retry_on = null, debit_on = null where id = i.id;
    end if;
    update owner_invoices set status = 'in_arrears', debit_on = null where id = i.id;
    perform set_config('app.debit_no_retry', '', true);
    return jsonb_build_object('ok', true, 'status', 'failed', 'invoice_status', 'in_arrears', 'nsf', v_nsf);
  end if;

  if not v_nsf then
    -- any other return reason: no retry, no Late Fee; the invoice waits on its page, its automatic debit paused
    perform set_config('app.debit_no_retry', i.id::text, true);
    perform set_config('app.debit_no_late_fee', i.id::text, true);
    update owner_invoices set status = 'failed', retry_on = null, debit_on = null, auto_debit_paused = true where id = i.id;
    perform set_config('app.debit_no_late_fee', '', true);
    perform set_config('app.debit_no_retry', '', true);
    update owner_debit_attempts set status = 'canceled', skip_reason = 'not retried: the debit was returned for another reason than insufficient funds'
     where owner_invoice_id = i.id and status = 'scheduled';
    perform app.ntf_emit('owner_debit_returned', 'owner_debit_attempt', a.id, 'returned', jsonb_build_object('owner_id', i.owner_id, 'vehicle_id', i.vehicle_id));
    perform app.ntf_emit('staff_owner_debit_exception', 'owner_debit_attempt', a.id, 'returned',
      jsonb_build_object('owner_id', i.owner_id, 'exception', 'returned', 'reason', v_msg,
                         '_immediate_roles', jsonb_build_array('staff_admin')));
    if not exists (select 1 from tasks t where t.related_id = i.id and t.task_type = 'owner_debit_returned' and t.status in ('open', 'in_progress', 'waiting')) then
      insert into tasks (queue, task_type, title, detail, priority, owner_id, vehicle_id, related_table, related_id, escalated, escalated_at, escalation_reason)
      values ('admin', 'owner_debit_returned', format('Debit returned for invoice %s: not retried', i.invoice_number),
              format('The bank returned the debit of %s (%s): %s. It is not retried and the automatic debit of this invoice is paused. The owner was emailed to pay from the invoice page or update the bank account.',
                     app.fmt_day(a.debit_on), app.fmt_money(a.amount_cents), v_msg),
              'high', i.owner_id, i.vehicle_id, 'owner_invoices', i.id, true, now(), 'debit returned, not insufficient funds');
    end if;
    return jsonb_build_object('ok', true, 'status', 'failed', 'invoice_status', 'failed', 'retry', false, 'paused', true, 'nsf', false);
  end if;

  -- insufficient funds, the first debit: the Late Fee once, on its own line, and one retry
  v_next := greatest(app.retry_date(v_original), app.add_business_days(app.local_date(now()), greatest(s.owner_debit_retry_gap_days, 1)));
  if v_next > v_original + 30 then
    -- too late for a retry within 30 days of the original debit: the Late Fee stays, no retry, the owner pays from the page
    perform set_config('app.debit_no_retry', i.id::text, true);
    update owner_invoices set status = 'failed', retry_on = null, debit_on = null, auto_debit_paused = true where id = i.id;
    perform set_config('app.debit_no_retry', '', true);
    perform app.ntf_emit('owner_debit_returned', 'owner_debit_attempt', a.id, 'returned', jsonb_build_object('owner_id', i.owner_id, 'vehicle_id', i.vehicle_id));
    perform app.ntf_emit('staff_owner_debit_exception', 'owner_debit_attempt', a.id, 'retry_window',
      jsonb_build_object('owner_id', i.owner_id, 'exception', 'retry_window', 'reason', v_msg, '_immediate_roles', jsonb_build_array('staff_admin')));
    return jsonb_build_object('ok', true, 'status', 'failed', 'invoice_status', 'failed', 'retry', false, 'paused', true, 'nsf', true);
  end if;

  perform set_config('app.debit_attempt_no', v_failed::text, true);
  insert into owner_debit_attempts (owner_invoice_id, owner_id, notice_id, run_id, attempt_no, debit_on, amount_cents, idempotency_key, bank_last4,
                                    is_retry, original_debit_on)
  values (i.id, i.owner_id, a.notice_id, null, a.attempt_no + 1, v_next, a.amount_cents, 'owner-debit:' || gen_random_uuid(), a.bank_last4,
          true, v_original)
  returning id into v_new;
  if i.status <> 'failed' then
    update owner_invoices set status = 'failed', retry_on = v_next, debit_on = v_next where id = i.id;
  else
    update owner_invoices set retry_on = v_next, debit_on = v_next where id = i.id;
  end if;
  perform set_config('app.debit_attempt_no', '', true);
  return jsonb_build_object('ok', true, 'status', 'failed', 'invoice_status', 'failed', 'retry_on', v_next, 'next_attempt', v_new,
                            'retry_amount_cents', a.amount_cents, 'nsf', true);
end $$;

-- The attempts due now (0037's claim): the retry debits its original amount, never the Late Fee; a first debit never more
-- than its notice said. Rewritten from 0037 with that one difference.
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
  v_due bigint;
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
      v_out := v_out || jsonb_build_array(app.owner_debit_request(a, i, o));
      continue;
    end if;
    -- what this attempt may take: a retry, the original amount less anything paid since, never the Late Fee
    v_due := case when a.is_retry then least(a.amount_cents, greatest(i.balance_cents - i.late_fee_cents, 0)) else i.balance_cents end;
    v_block := app.owner_debit_block(i.id);
    if (v_block is not null and (i.status in ('paid', 'deducted', 'void') or i.balance_cents <= 0)) or (a.is_retry and v_due <= 0) then
      update owner_debit_attempts set status = 'canceled', skip_reason = coalesce(v_block, 'only the Late Fee is left: it goes with the next scheduled debit'), run_id = v_run where id = a.id;
      update owner_invoices set debit_on = null where id = i.id and debit_on = a.debit_on;
      if a.is_retry and v_due <= 0 and i.status = 'failed' then update owner_invoices set status = 'issued', retry_on = null where id = i.id; end if;
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
    if not a.is_retry and i.balance_cents > a.amount_cents then
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
       set status = 'submitting', run_id = v_run, amount_cents = v_due,
           processor_customer_id = m ->> 'customer_id', processor_method_id = m ->> 'processor_method_id',
           processor_mandate_id = m ->> 'mandate_id', bank_last4 = coalesce(m ->> 'last4', bank_last4)
     where id = a.id returning * into a;
    v_out := v_out || jsonb_build_array(app.owner_debit_request(a, i, o));
  end loop;
  return v_out;
end $$;

-- A cleared retry pays the original amount; the Late Fee left on the invoice is issued, so the next notice lists it
-- and the next scheduled debit collects it.
alter function app.owner_debit_result(text, jsonb) rename to owner_debit_result_0038;
create or replace function app.owner_debit_result(p_intent text, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  v_out jsonb := app.owner_debit_result_0038(p_intent, p);
  a owner_debit_attempts;
  i owner_invoices;
begin
  if v_out ->> 'status' = 'succeeded' and not coalesce((v_out ->> 'repeat')::boolean, false) then
    select * into a from owner_debit_attempts where processor_intent_id = p_intent;
    select * into i from owner_invoices where id = a.owner_invoice_id for update;
    if i.status in ('retry_processing', 'processing', 'failed') and i.balance_cents > 0 and i.balance_cents <= i.late_fee_cents then
      update owner_invoices set status = 'issued', retry_on = null, debit_on = null where id = i.id;
      v_out := v_out || jsonb_build_object('invoice_status', 'issued', 'late_fee_left_cents', i.balance_cents);
    end if;
  end if;
  return v_out;
end $$;

-- ================================================================ 4. the emails' values
-- every owner billing email names the payee; the failed debit names the original amount and the retry; the returned
-- debit not retried; the notice lists a Late Fee left on an invoice; the void notice names the debit; the confirmation
-- carries the whole agreement; a rental added by staff with the saved card says the card is charged on signing
alter function app.notification_payload(text, app_events, jsonb) rename to ntf_payload_0051;
create or replace function app.notification_payload(p_code text, p_event app_events, p_to jsonb) returns jsonb
language plpgsql stable security definer set search_path = public, app as $$
declare
  x jsonb := app.ntf_payload_0051(p_code, p_event, p_to);
  a owner_debit_attempts;
  nx owner_debit_attempts;
  inv owner_invoices;
  o owners;
  m owner_payment_methods;
  b bookings;
  co owner_cosigners;
  v_ids uuid[];
  v_agree jsonb;
begin
  if p_code like 'owner\_%' then
    x := x || jsonb_build_object('payee_name', app.owner_payee_name());
  end if;
  if p_code = 'owner_payment_failed' then
    select * into inv from owner_invoices where id = p_event.entity_id;
    select * into a from owner_debit_attempts where owner_invoice_id = inv.id and status = 'failed' order by settled_at desc nulls last, attempt_no desc limit 1;
    select * into nx from owner_debit_attempts where owner_invoice_id = inv.id and status = 'scheduled' and is_retry order by attempt_no desc limit 1;
    if a.id is not null then
      x := x || jsonb_build_object('amount', app.fmt_money(a.amount_cents), 'retry_amount', app.fmt_money(coalesce(nx.amount_cents, a.amount_cents)),
                                   'retry_date', app.fmt_day(coalesce(nx.debit_on, inv.retry_on, a.debit_on)),
                                   'late_fee', app.fmt_money(coalesce(nullif(inv.late_fee_cents, 0), (app.settings()).owner_late_fee_cents)));
    end if;
  elsif p_code = 'owner_debit_returned' then
    select * into a from owner_debit_attempts where id = p_event.entity_id;
    select * into inv from owner_invoices where id = a.owner_invoice_id;
    select * into o from owners where id = inv.owner_id;
    x := x || jsonb_build_object(
      'first_name', coalesce(nullif(x ->> 'first_name', ''), o.first_name, split_part(o.legal_name, ' ', 1)),
      'invoice_number', inv.invoice_number, 'vehicle_name', app.vehicle_name(inv.vehicle_id),
      'debit_date', app.fmt_day(a.debit_on), 'amount', app.fmt_money(a.amount_cents), 'balance', app.fmt_money(inv.balance_cents),
      'bank_reason', coalesce(nullif(a.failure_message, ''), 'returned by the bank'),
      'has_late_fee', inv.late_fee_cents > 0, 'late_fee', app.fmt_money(inv.late_fee_cents),
      '_url', app.ntf_link('owner_invoice', jsonb_build_object('invoice_number', inv.invoice_number)));
  elsif p_code = 'staff_owner_debit_exception' and p_event.payload ->> 'exception' in ('returned', 'retry_window') then
    select * into a from owner_debit_attempts where id = p_event.entity_id;
    select * into inv from owner_invoices where id = a.owner_invoice_id;
    x := x || jsonb_build_object(
      'exception_title', case p_event.payload ->> 'exception' when 'returned' then 'Debit returned, not retried' else 'Debit returned too late for a retry' end,
      'exception_detail', format('The bank returned the debit of %s for invoice %s (%s): %s. %s The automatic debit of this invoice is paused and the owner was emailed to pay it from the invoice page or update the bank account.',
                                 app.fmt_day(a.debit_on), inv.invoice_number, app.fmt_money(a.amount_cents), coalesce(nullif(a.failure_message, ''), 'returned'),
                                 case p_event.payload ->> 'exception' when 'returned' then 'Only a debit returned for insufficient funds is retried.'
                                      else 'A retry would fall more than 30 days after the original debit.' end));
  elsif p_code in ('owner_debit_notice', 'owner_debit_setup_needed') and jsonb_typeof(x -> 'debit_items') = 'array' then
    -- an invoice whose fees are paid and only its Late Fee is left reads "Late Fee"
    x := jsonb_set(x, '{debit_items}', coalesce((
      select jsonb_agg(case when i.id is not null and i.late_fee_cents > 0 and i.balance_cents <= i.late_fee_cents
                            then e || jsonb_build_object('covers', 'Late Fee') else e end order by o2)
        from jsonb_array_elements(x -> 'debit_items') with ordinality t(e, o2)
        left join owner_invoices i on i.invoice_number = e ->> 'invoice_number'), '[]'::jsonb));
  elsif p_code = 'owner_payment_reversed' then
    select i.* into inv from manual_payments mp join owner_invoices i on i.id = mp.owner_invoice_id where mp.payment_id = p_event.entity_id or mp.id = p_event.entity_id limit 1;
    if inv.id is null then select * into inv from owner_invoices where id = (p_event.payload ->> 'owner_invoice_id')::uuid; end if;
    x := x || jsonb_build_object('debit_date', app.fmt_day(coalesce(inv.debit_on, app.owner_debit_next_date(app.today()))),
                                 'balance', coalesce(x ->> 'balance', app.fmt_money(inv.balance_cents)));
  elsif p_code = 'owner_pad_confirmed' then
    select * into m from owner_payment_methods where id = p_event.entity_id;
    select * into o from owners where id = m.owner_id;
    v_agree := app.owner_pad_agreement(case when o.owner_type = 'corporation' then 'business' else 'personal' end);
    x := x || jsonb_build_object('agreement_1', v_agree ->> 0, 'agreement_2', v_agree ->> 1, 'agreement_3', v_agree ->> 2, 'agreement_4', v_agree ->> 3,
                                 'agreement_kind', case when o.owner_type = 'corporation' then 'business' else 'personal' end);
  elsif p_code = 'renter_rental_added' then
    select * into b from bookings where id = p_event.entity_id;
    if b.payment_mode = 'card' and not exists (select 1 from payments p where p.booking_id = b.id and p.purpose = 'booking_total' and p.status = 'succeeded') then
      x := x || jsonb_build_object('payment_line', 'Your card is charged when you sign.',
                                   'sign_line', 'Read and sign your rental agreement; your card is charged when you sign.');
    else
      x := x || jsonb_build_object('sign_line', 'Please read and sign your rental agreement before pickup.');
    end if;
  elsif p_code = 'owner_cosigner_sign' then
    select * into co from owner_cosigners where id = p_event.entity_id;
    select * into o from owners where id = co.owner_id;
    x := x || jsonb_build_object('first_name', split_part(btrim(co.name), ' ', 1), 'cosigner_name', co.name, 'owner_name', o.legal_name, 'token', co.token,
                                 'sign_url', app.ntf_link('owner_cosign', jsonb_build_object('token', co.token)),
                                 '_url', app.ntf_link('owner_cosign', jsonb_build_object('token', co.token)));
  end if;
  return x;
end $$;

-- ================================================================ 5. signatures
alter table signature_records add column if not exists staff_attribution text;
alter table signature_records add column if not exists attributed_user_id uuid references users (id);
alter table signature_records add column if not exists signed_on date;
comment on column signature_records.staff_attribution is
  '"Proposed by: <staff name>" or "Added by: <staff name>" (0053): the staff member who sent the offer, added the rental, or proposed or approved the amendment. Staff are never the signer.';
comment on column signature_records.signed_on is 'A paper signature: the date it was signed, with no time of day (0053); signed_at is then empty.';
alter table signature_records drop constraint if exists signature_records_check;
alter table signature_records add constraint signature_records_signed_when check (status <> 'signed' or signed_at is not null or signed_on is not null);

-- The countersignature wording, as approved, for every automatic countersignature.
create or replace function app.corporate_signature_text() returns text
language sql stable security definer set search_path = public, app as $$
  select case when nullif(btrim(s.signing_officer_name), '') is not null
              then format('Signed electronically for %s, operating as %s, by %s, %s, under a standing authorization dated %s.',
                          coalesce(nullif(btrim(s.company_legal_name), ''), s.company_trade_name), s.company_trade_name, s.signing_officer_name,
                          coalesce(nullif(btrim(s.signing_officer_title), ''), 'Director'),
                          to_char(coalesce(s.signing_officer_authorized_on, app.today()), 'FMMonth FMDD, YYYY'))
              else format('Signed electronically for %s, operating as %s.', coalesce(nullif(btrim(s.company_legal_name), ''), s.company_trade_name), s.company_trade_name) end
    from app.settings() s
$$;

-- The standing authorization is dated the day the signing officer is set: a new officer (or a first one) takes today's
-- date unless the same change gives a date.
create or replace function app.program_settings_officer_date() returns trigger
language plpgsql security definer set search_path = public, app as $$
begin
  if nullif(btrim(coalesce(new.signing_officer_name, '')), '') is null then return new; end if;
  if tg_op = 'INSERT' then
    new.signing_officer_authorized_on := coalesce(new.signing_officer_authorized_on, app.today());
  elsif new.signing_officer_name is distinct from old.signing_officer_name
        and new.signing_officer_authorized_on is not distinct from old.signing_officer_authorized_on then
    new.signing_officer_authorized_on := app.today();
  elsif new.signing_officer_authorized_on is null then
    new.signing_officer_authorized_on := app.today();
  end if;
  return new;
end $$;
create trigger program_settings_officer_date before insert or update on program_settings
  for each row execute function app.program_settings_officer_date();

-- Every automatic countersignature (rental agreements, amendments, owner documents, Forms A and B, partner and staff
-- agreements, paper records): the signing officer signs for the company with the approved wording. A staff member the
-- calling function named (the one who sent the offer, added the rental, or proposed or approved the amendment) is kept
-- as "Proposed by" or "Added by", never as the signer.
create or replace function app.signature_records_corporate() returns trigger
language plpgsql security definer set search_path = public, app as $$
declare
  s program_settings := app.settings();
  v_label text;
  v_staff text;
begin
  if new.signer_role <> 'carmacars' or coalesce(new.method, '') <> 'automatic' then return new; end if;
  -- an Owner of the Title Schedule has not signed yet: the agreements are countersigned when the last one signs
  if coalesce(current_setting('app.cosign_defer', true), '') <> '' then return null; end if;
  if new.signer_user_id is not null and app.user_is_staff(new.signer_user_id) then
    v_staff := nullif(btrim(new.signer_name), '');
    new.attributed_user_id := new.signer_user_id;
  end if;
  v_label := case
    when exists (select 1 from booking_amendments x where x.signature_request_id = new.signature_request_id) then 'Proposed by'
    when exists (select 1 from rental_agreements ra join bookings b on b.id = ra.booking_id
                  where ra.signature_request_id = new.signature_request_id and b.added_by_staff) then 'Added by'
    when exists (select 1 from rental_agreements ra where ra.signature_request_id = new.signature_request_id) then 'Proposed by' end;
  if v_staff is not null and v_label is not null then new.staff_attribution := v_label || ': ' || v_staff; end if;
  new.signer_user_id := s.signing_officer_user_id;
  new.signer_name := coalesce(nullif(btrim(s.signing_officer_name), ''), s.company_trade_name);
  new.signer_title := coalesce(nullif(btrim(s.signing_officer_title), ''), 'for ' || s.company_trade_name);
  new.typed_name := new.signer_name;
  new.consent_text := app.corporate_signature_text();
  return new;
end $$;
create trigger signature_records_corporate before insert on signature_records
  for each row execute function app.signature_records_corporate();

-- Paper records keep the signing date only, no time of day.
create or replace function app.signature_records_paper_date() returns trigger
language plpgsql security definer set search_path = public, app as $$
begin
  if new.method = 'paper' then
    new.signed_on := coalesce(new.signed_on, app.local_date(new.signed_at));
    new.signed_at := null;
  end if;
  return new;
end $$;
create trigger signature_records_paper_date before insert on signature_records
  for each row execute function app.signature_records_paper_date();
-- the paper records already on file: the date they carry, no time
update signature_records set signed_on = coalesce(signed_on, app.local_date(signed_at)), signed_at = null where method = 'paper' and signed_at is not null;

-- The amendment: CarmaCars signs at the moment the Renter signs; the signing officer, not a staff member, signs.
create or replace function app.amendment_countersigner(p_request uuid) returns jsonb
language sql stable security definer set search_path = public, app as $$
  select jsonb_build_object('user_id', s.signing_officer_user_id,
           'name', coalesce(nullif(btrim(s.signing_officer_name), ''), s.company_trade_name),
           'title', coalesce(nullif(btrim(s.signing_officer_title), ''), 'for ' || s.company_trade_name),
           'proposed_by', (select u.full_name from booking_change_requests c
                             join users u on u.id = coalesce(case when c.requested_by_role <> 'renter' then c.requested_by end, c.decided_by)
                            where c.id = p_request))
    from app.settings() s
$$;

-- 0051's amendment signing passed the staff member as the countersigner; the trigger above signs in the officer's name.
-- The staff member who proposed or approved the change is named to the trigger through signer_user_id.
alter function app.sign_booking_amendment(uuid, uuid, text, text, text, text, inet, text) rename to sign_booking_amendment_0051;
create or replace function app.sign_booking_amendment(p_amendment uuid, p_by uuid, p_consent_text text, p_document_sha256 text,
    p_typed_name text default null, p_drawn_signature text default null, p_ip inet default null, p_user_agent text default null)
returns jsonb language plpgsql security definer set search_path = public, app as $$
declare
  v_out jsonb := app.sign_booking_amendment_0040(p_amendment, p_by, p_consent_text, p_document_sha256, p_typed_name, p_drawn_signature, p_ip, p_user_agent);
  am booking_amendments;
  s program_settings := app.settings();
  u users;
  v_rec uuid;
begin
  select * into am from booking_amendments where id = p_amendment for update;
  if am.status = 'signed' and am.countersignature_record_id is null then
    -- the staff member who proposed the change, or approved the renter's request: recorded as "Proposed by", never the signer
    select u2.* into u from booking_change_requests c
      join users u2 on u2.id = coalesce(case when c.requested_by_role <> 'renter' then c.requested_by end, c.decided_by)
     where c.id = am.change_request_id;
    insert into signature_records (signature_request_id, signer_role, signer_user_id, signer_name, signer_email, status, signed_at,
                                   method, document_sha256)
    values (am.signature_request_id, 'carmacars', u.id, coalesce(u.full_name, s.company_trade_name), s.company_email, 'signed', now(),
            'automatic', am.document_sha256)
    returning id into v_rec;
    update booking_amendments set countersignature_record_id = v_rec where id = am.id;
  end if;
  return (select to_jsonb(x) from booking_amendments x where x.id = p_amendment);
end $$;

create or replace function public.server_amendment_record(p_amendment uuid) returns jsonb
language sql stable security definer set search_path = public, app as $$
  select jsonb_build_object('amendment', to_jsonb(a),
           'record', (select jsonb_build_object('signer_name', r.signer_name, 'method', r.method, 'signed_at', r.signed_at, 'ip_address', host(r.ip_address),
                                                'user_agent', r.user_agent, 'provider_signature', r.provider_signature, 'typed_name', r.typed_name,
                                                'consent_text', r.consent_text, 'document_sha256', r.document_sha256)
                        from signature_records r where r.id = a.signature_record_id),
           'countersign', (select jsonb_build_object('signer_name', r.signer_name, 'signer_title', r.signer_title, 'method', r.method, 'signed_at', r.signed_at,
                                                     'consent_text', r.consent_text, 'document_sha256', r.document_sha256, 'staff_attribution', r.staff_attribution)
                             from signature_records r where r.id = a.countersignature_record_id),
           'document', (select jsonb_build_object('bucket', d.storage_bucket, 'path', d.storage_path) from documents d where d.id = a.document_id))
    from booking_amendments a where a.id = p_amendment $$;

-- What a signed PDF prints for the company and the staff attribution: every record of a signature request, with its
-- wording. The server adds these lines to the signature record page of each signed copy.
create or replace function public.server_signature_lines(p_request uuid) returns jsonb
language sql stable security definer set search_path = public, app as $$
  select coalesce(jsonb_agg(jsonb_build_object('signer_role', r.signer_role, 'signer_name', r.signer_name, 'signer_title', r.signer_title, 'method', r.method,
                                               'signed_at', r.signed_at, 'signed_on', r.signed_on, 'consent_text', r.consent_text,
                                               'staff_attribution', r.staff_attribution) order by r.created_at), '[]'::jsonb)
    from signature_records r where r.signature_request_id = p_request
$$;

-- Investment agreements: no automatic countersignature. The signing officer countersigns in Admin ("Countersign"); the
-- agreement is fully signed only then, "Awaiting countersignature" until then.
create or replace function app.investment_awaiting_countersignature(p_agreement uuid) returns boolean
language sql stable security definer set search_path = public, app as $$
  select coalesce((select a.status = 'signed' and a.company_signed_at is null from investment_agreements a where a.id = p_agreement), false)
$$;

create or replace function app.investment_countersign(p_admin uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  s program_settings := app.settings();
  a investment_agreements;
  r sign_requests;
  v_sha text;
  v_rec uuid;
begin
  perform app.assert_admin(p_admin);
  if nullif(btrim(s.signing_officer_name), '') is null then
    raise exception 'Set the signing officer in Admin > Settings > Program settings first' using errcode = '23514';
  end if;
  if s.signing_officer_user_id is not null and s.signing_officer_user_id <> p_admin then
    raise exception 'Only the signing officer (%) countersigns an investment agreement', s.signing_officer_name using errcode = '42501';
  end if;
  select * into a from investment_agreements where id = coalesce(nullif(p ->> 'agreement_id', '')::uuid,
                     (select x.investment_agreement_id from sign_requests x where x.id = nullif(p ->> 'sign_request_id', '')::uuid)) for update;
  if a.id is null then raise exception 'Investment agreement not found' using errcode = 'P0002'; end if;
  if a.status <> 'signed' then raise exception 'The investor has not signed agreement % yet', a.agreement_number using errcode = '23514'; end if;
  if a.company_signed_at is not null then
    return jsonb_build_object('agreement_id', a.id, 'repeat', true, 'company_signed_at', a.company_signed_at);
  end if;
  select * into r from sign_requests where investment_agreement_id = a.id and status = 'signed' order by signed_at desc limit 1;
  v_sha := coalesce(r.document_sha256, (select d.sha256 from documents d where d.id = a.document_id));
  insert into signature_records (signature_request_id, signer_role, signer_user_id, signer_name, signer_title, signer_email, status, signed_at,
                                 method, typed_name, consent_text, document_sha256)
  values (coalesce(r.signature_request_id, a.signature_request_id), 'carmacars', p_admin, s.signing_officer_name, coalesce(nullif(btrim(s.signing_officer_title), ''), 'Director'),
          s.company_email, 'signed', now(), 'typed', s.signing_officer_name,
          format('Signed electronically for %s, operating as %s, by %s, %s.', coalesce(nullif(btrim(s.company_legal_name), ''), s.company_trade_name), s.company_trade_name,
                 s.signing_officer_name, coalesce(nullif(btrim(s.signing_officer_title), ''), 'Director')),
          v_sha)
  returning id into v_rec;
  update investment_agreements set company_signed_at = now() where id = a.id;
  update signature_requests set status = 'completed', completed_at = now() where id = coalesce(r.signature_request_id, a.signature_request_id) and status <> 'completed';
  insert into audit_log (actor_user_id, action, entity_table, entity_id, after)
  values (p_admin, 'investment_countersign', 'investment_agreements', a.id::text,
          jsonb_build_object('agreement_number', a.agreement_number, 'signature_record_id', v_rec, 'signing_officer', s.signing_officer_name));
  return jsonb_build_object('agreement_id', a.id, 'signature_record_id', v_rec, 'company_signed_at', now(), 'sign_request_id', r.id);
end $$;

-- The person's documents (0044's my_sign_requests): a signed investment agreement says whether it awaits the
-- countersignature.
alter function app.my_sign_requests(uuid) rename to my_sign_requests_0044;
create or replace function app.my_sign_requests(p_user uuid) returns jsonb
language sql stable security definer set search_path = public, app as $$
  select r || jsonb_build_object('signed', coalesce((
      select jsonb_agg(x || jsonb_build_object('awaiting_countersignature',
               coalesce((select app.investment_awaiting_countersignature(s.investment_agreement_id) from sign_requests s
                          where s.id::text = x ->> 'id' and s.doc_type = 'investment_agreement'), false)) order by o)
        from jsonb_array_elements(r -> 'signed') with ordinality t(x, o)), '[]'::jsonb))
    from app.my_sign_requests_0044(p_user) r
$$;

-- The partner's portal signature (0046) and the staff member's (0044): the automatic countersignature, as for the
-- owner documents (the trigger gives it the officer's name and the approved wording).
alter function app.sign_request_sign(uuid, uuid, jsonb) rename to sign_request_sign_0046;
create or replace function app.sign_request_sign(p_user uuid, p_id uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  r sign_requests;
  v_out jsonb;
  v_rec uuid;
  v_wit uuid;
  v_form uuid;
  v_witness text := nullif(btrim(coalesce(p ->> 'witness_name', '')), '');
  o owners;
begin
  select * into r from sign_requests where id = p_id;
  if r.doc_type = 'form_c' then
    -- Form C on screen: the owner signs and initials, and the witness, beside them on the same device, types their name
    -- and the statement
    if r.id is null or r.signer_user_id is distinct from p_user then raise exception 'Not found' using errcode = 'P0002'; end if;
    select * into o from owners where id = r.owner_id;
    if v_witness is null or length(v_witness) < 3 then raise exception 'The witness types their full name' using errcode = '22023'; end if;
    if lower(regexp_replace(v_witness, '\s+', '', 'g')) = lower(regexp_replace(r.signer_name, '\s+', '', 'g')) then
      raise exception 'The witness is another adult, not the owner' using errcode = '23514';
    end if;
    if coalesce(p ->> 'witness_statement', '') <> format('I witnessed %s sign in my presence.', r.signer_name) then
      raise exception 'The witness ticks the statement "I witnessed % sign in my presence."', r.signer_name using errcode = '22023';
    end if;
    if jsonb_typeof(p -> 'acknowledgments') is distinct from 'array' or jsonb_array_length(p -> 'acknowledgments') < 3
       or nullif(btrim(coalesce(p ->> 'initials', '')), '') is null then
      raise exception 'Initial each of the three acknowledgments' using errcode = '22023';
    end if;
  end if;
  v_out := app.sign_request_sign_0046(p_user, p_id, p);
  select * into r from sign_requests where id = p_id;
  if r.doc_type = 'staff_agreement' and r.status = 'signed' then
    insert into signature_records (signature_request_id, signer_role, signer_name, signer_email, status, signed_at, method, document_sha256)
    select r.signature_request_id, 'carmacars', s.company_trade_name, s.company_email, 'signed', now(), 'automatic', r.document_sha256 from app.settings() s
    returning id into v_rec;
    update signature_requests set status = 'completed', completed_at = coalesce(completed_at, now()) where id = r.signature_request_id;
  elsif r.doc_type = 'form_c' and r.status = 'signed' then
    insert into signature_records (signature_request_id, signer_role, signer_name, status, signed_at, method, ip_address, user_agent, typed_name, consent_text, document_sha256)
    values (r.signature_request_id, 'witness', v_witness, 'signed', now(), 'typed', nullif(p ->> 'ip', '')::inet, nullif(p ->> 'user_agent', ''), v_witness,
            format('I witnessed %s sign in my presence.', r.signer_name), r.document_sha256)
    returning id into v_wit;
    update signature_records set initials = jsonb_build_object('read_warning', upper(btrim(p ->> 'initials')), 'no_advice', upper(btrim(p ->> 'initials')),
                                                               'bears_consequences', upper(btrim(p ->> 'initials')))
     where id = r.signature_record_id;
    update signature_requests set status = 'completed', completed_at = now() where id = r.signature_request_id;
    update owner_agreement_forms set status = 'replaced' where owner_id = r.owner_id and form_code = 'C' and vehicle_id is not distinct from r.vehicle_id and status = 'uploaded';
    insert into owner_agreement_forms (owner_agreement_id, owner_id, form_code, vehicle_id, document_id, signature_request_id, signed_at, witness_1_name,
                                       finance_permission, ack_read_warning_at, ack_no_advice_at, ack_bears_consequences_at,
                                       status, signed_method, uploaded_by, reviewed_by, reviewed_at)
    values ((select id from owner_agreements where owner_id = r.owner_id and kind = 'title_holding' and status <> 'void' order by created_at desc limit 1),
            r.owner_id, 'C', r.vehicle_id, r.document_id, r.signature_request_id, now(), v_witness,
            (select s.finance_permission from vehicle_schedules s where s.vehicle_id = r.vehicle_id and s.superseded_by is null),
            now(), now(), now(), 'approved', 'screen', p_user, p_user, now())
    returning id into v_form;
    update tasks set status = 'done', completed_at = now(), completion_note = 'Signed on screen with a witness'
     where task_type = 'owner_form_review' and owner_id = r.owner_id and status in ('open', 'in_progress', 'waiting')
       and related_id in (select f.id from owner_agreement_forms f where f.owner_id = r.owner_id and f.form_code = 'C' and f.vehicle_id is not distinct from r.vehicle_id);
    v_out := v_out || jsonb_build_object('form_id', v_form, 'witness_record_id', v_wit);
  end if;
  return v_out;
end $$;

-- Paper records of staff and partner agreements: the countersignature, as for the owner documents on paper (the
-- signer's record keeps the date signed on paper; the company's is dated when staff recorded it).
alter function app.record_paper_signature(uuid, jsonb) rename to record_paper_signature_0051;
create or replace function app.record_paper_signature(p_by uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  v_out jsonb := app.record_paper_signature_0051(p_by, p);
  ps paper_signatures;
  v_req uuid;
  v_doc documents;
  pr partners;
begin
  if p ->> 'doc_type' not in ('staff_agreement', 'partner_agreement') then return v_out; end if;
  select * into ps from paper_signatures where id = (v_out ->> 'id')::uuid for update;
  select * into v_doc from documents where id = ps.document_id;
  perform set_config('app.paper_recording', 'on', true);
  if ps.doc_type = 'staff_agreement' then
    v_req := nullif(ps.effect ->> 'request', '')::uuid;
  else
    select * into pr from partners where id = ps.target_id;
    insert into signature_requests (document_id, provider, status, sent_at, completed_at, signed_document_id, created_by)
    values (ps.document_id, 'paper', 'completed', now(), now(), ps.document_id, p_by) returning id into v_req;
    perform app.paper_records(v_req, 'partner', null, ps.signer_name, pr.email, ps.signed_on, ps.document_id, v_doc.sha256);
    update paper_signatures set effect = effect || jsonb_build_object('request', v_req) where id = ps.id;
  end if;
  if v_req is not null and not exists (select 1 from signature_records x where x.signature_request_id = v_req and x.signer_role = 'carmacars') then
    insert into signature_records (signature_request_id, signer_role, signer_name, status, signed_at, method, document_sha256)
    select v_req, 'carmacars', s.company_trade_name, 'signed', now(), 'automatic', v_doc.sha256 from app.settings() s;
  end if;
  perform set_config('app.paper_recording', '', true);
  return v_out || jsonb_build_object('request', v_req);
end $$;

-- ================================================================ 6. every Owner in the Title Schedule signs
-- While another Owner has not signed, the portal owner's signature is recorded but the agreements are not completed:
-- 0029's signing runs with app.cosign_defer set, and these guards keep what it would complete open. The countersignature
-- (skipped by app.signature_records_corporate) comes when the last Owner signs (app.owner_agreements_finalize).
create or replace function app.cosign_defer_requests() returns trigger
language plpgsql security definer set search_path = public, app as $$
begin
  if coalesce(current_setting('app.cosign_defer', true), '') <> '' and new.status = 'completed' and old.status = 'sent' then
    new.status := 'partially_signed'; new.completed_at := null;
  end if;
  return new;
end $$;
create trigger signature_requests_cosign_defer before update of status on signature_requests
  for each row execute function app.cosign_defer_requests();

create or replace function app.cosign_defer_agreements() returns trigger
language plpgsql security definer set search_path = public, app as $$
begin
  if coalesce(current_setting('app.cosign_defer', true), '') = new.owner_id::text and new.status = 'signed' and old.status = 'sent' then
    new.status := 'sent'; new.agreement_date := old.agreement_date;
  end if;
  return new;
end $$;
create trigger owner_agreements_cosign_defer before update on owner_agreements
  for each row execute function app.cosign_defer_agreements();

create or replace function app.cosign_defer_schedules() returns trigger
language plpgsql security definer set search_path = public, app as $$
begin
  if coalesce(current_setting('app.cosign_defer', true), '') <> '' and old.signed_at is null and new.signed_at is not null then
    new.signed_at := null;
  end if;
  return new;
end $$;
create trigger vehicle_schedules_cosign_defer before update of signed_at on vehicle_schedules
  for each row execute function app.cosign_defer_schedules();

-- The signature requests of an owner's program documents waiting for signatures: the two agreements and an Additional
-- Vehicle Schedule.
create or replace function app.owner_open_requests(p_owner uuid) returns table (key text, agreement_id uuid, agreement_number text, signature_request_id uuid, sha256 text, status text)
language sql stable security definer set search_path = public, app as $$
  select a.kind, a.id, a.agreement_number, r.id, d.sha256, r.status
    from owner_agreements a join signature_requests r on r.id = a.signature_request_id join documents d on d.id = r.document_id
   where a.owner_id = p_owner and a.kind in ('enrollment', 'title_holding') and a.status = 'sent' and r.status in ('sent', 'partially_signed')
  union all
  select distinct 'additional', null::uuid, null::text, r.id, d.sha256, r.status
    from vehicle_schedules s join vehicles v on v.id = s.vehicle_id join signature_requests r on r.id = s.signature_request_id join documents d on d.id = r.document_id
   where v.owner_id = p_owner and s.is_additional and s.signed_at is null and s.superseded_by is null and r.status in ('sent', 'partially_signed')
$$;

create or replace function app.owner_cosigners_json(p_owner uuid) returns jsonb
language sql stable security definer set search_path = public, app as $$
  select coalesce(jsonb_agg(jsonb_build_object('id', c.id, 'name', c.name, 'email', c.email, 'status', c.status, 'link_sent_at', c.link_sent_at,
                                               'link_sent_count', c.link_sent_count, 'signed_at', c.signed_at) order by c.created_at), '[]'::jsonb)
    from owner_cosigners c where c.owner_id = p_owner and c.status <> 'removed'
$$;

-- The portal owner has signed every open document (their own records are on each request).
create or replace function app.owner_primary_signed(p_owner uuid) returns boolean
language sql stable security definer set search_path = public, app as $$
  select exists (select 1 from app.owner_open_requests(p_owner))
     and not exists (select 1 from app.owner_open_requests(p_owner) q
                      where not exists (select 1 from signature_records x where x.signature_request_id = q.signature_request_id
                                          and x.signer_role in ('owner_individual', 'owner_corporation') and x.status = 'signed'
                                          and x.signer_user_id is not distinct from (select o.user_id from owners o where o.id = p_owner)))
$$;

-- The last Owner signed: CarmaCars countersigns each document, the agreements take effect, the schedules are signed and
-- the vehicles move on (0044's rule). Returns what the server needs to file the signed copies.
create or replace function app.owner_agreements_finalize(p_owner uuid) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  q record;
  v_out jsonb := '[]'::jsonb;
begin
  if exists (select 1 from owner_cosigners c where c.owner_id = p_owner and c.status = 'pending') or not app.owner_primary_signed(p_owner) then
    return jsonb_build_object('complete', false, 'signed', '[]'::jsonb);
  end if;
  for q in select * from app.owner_open_requests(p_owner) loop
    insert into signature_records (signature_request_id, signer_role, signer_name, status, signed_at, method, document_sha256)
    select q.signature_request_id, 'carmacars', s.company_trade_name, 'signed', now(), 'automatic', q.sha256 from app.settings() s;
    update signature_requests set status = 'completed', completed_at = now() where id = q.signature_request_id;
    if q.agreement_id is not null then
      update owner_agreements set status = 'signed', agreement_date = coalesce(agreement_date, app.today()),
             confirm_own_insurance_at = case when kind = 'enrollment' then coalesce(confirm_own_insurance_at, now()) else confirm_own_insurance_at end,
             confirm_fees_no_income_at = case when kind = 'enrollment' then coalesce(confirm_fees_no_income_at, now()) else confirm_fees_no_income_at end,
             confirm_tracker_downtime_at = case when kind = 'enrollment' then coalesce(confirm_tracker_downtime_at, now()) else confirm_tracker_downtime_at end
       where id = q.agreement_id;
    end if;
    update vehicle_schedules set signed_at = now() where signature_request_id = q.signature_request_id and signed_at is null and superseded_by is null;
    v_out := v_out || jsonb_build_array(jsonb_build_object('key', q.key, 'agreement_id', q.agreement_id, 'agreement_number', q.agreement_number,
      'signature_request_id', q.signature_request_id,
      'records', (select jsonb_agg(jsonb_build_object('signer_role', x.signer_role, 'signer_name', x.signer_name, 'signer_title', x.signer_title, 'method', x.method,
                                   'signed_at', x.signed_at, 'ip_address', host(x.ip_address), 'user_agent', x.user_agent, 'provider_signature', x.provider_signature,
                                   'typed_name', x.typed_name, 'initials', x.initials) order by x.created_at)
                    from signature_records x where x.signature_request_id = q.signature_request_id)));
  end loop;
  return jsonb_build_object('complete', true, 'signed', v_out, 'vehicles_signed', coalesce(cardinality(app.owner_vehicles_signed(p_owner)), 0));
end $$;

-- Emails one Owner their signing link (each send is its own email; the link stays the same until they sign).
create or replace function app.owner_cosigner_send(p_cosigner uuid, p_by uuid default null) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  c owner_cosigners;
begin
  select * into c from owner_cosigners where id = p_cosigner for update;
  if c.id is null or c.status <> 'pending' then raise exception 'This Owner has nothing to sign' using errcode = '23514'; end if;
  if not exists (select 1 from app.owner_open_requests(c.owner_id)) then
    raise exception 'The documents are not open for signature yet: they open when the owner opens them, or when an Admin sends them' using errcode = '23514';
  end if;
  update owner_cosigners set link_sent_at = now(), link_sent_count = link_sent_count + 1 where id = c.id returning * into c;
  perform app.ntf_emit('owner_cosigner_sign', 'owner_cosigner', c.id, 'sent:' || c.link_sent_count,
    jsonb_build_object('owner_id', c.owner_id, 'signer_email', c.email, 'signer_name', c.name));
  if p_by is not null then
    insert into audit_log (actor_user_id, action, entity_table, entity_id, after)
    values (p_by, 'owner_cosigner_send', 'owner_cosigners', c.id::text, jsonb_build_object('owner_id', c.owner_id, 'count', c.link_sent_count));
  end if;
  return jsonb_build_object('id', c.id, 'sent_to', c.email, 'count', c.link_sent_count);
end $$;

-- Admin > Owners > an owner: the Owners of the Title Schedule besides the portal owner.
create or replace function app.owner_cosigner_add(p_admin uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  o owners;
  c owner_cosigners;
begin
  perform app.assert_admin(p_admin);
  select * into o from owners where id = (p ->> 'owner_id')::uuid for update;
  if o.id is null then raise exception 'Owner not found' using errcode = 'P0002'; end if;
  if exists (select 1 from owner_agreements a where a.owner_id = o.id and a.kind = 'enrollment' and a.status = 'signed') then
    raise exception 'The agreements of % are already signed: an Owner is added with new agreements', o.legal_name using errcode = '23514';
  end if;
  insert into owner_cosigners (owner_id, name, email, added_by)
  values (o.id, btrim(p ->> 'name'), lower(btrim(p ->> 'email')), p_admin) returning * into c;
  insert into audit_log (actor_user_id, action, entity_table, entity_id, after)
  values (p_admin, 'owner_cosigner_add', 'owner_cosigners', c.id::text, jsonb_build_object('owner_id', o.id, 'name', c.name));
  if exists (select 1 from app.owner_open_requests(o.id)) then perform app.owner_cosigner_send(c.id, p_admin); end if;
  return app.owner_cosigners_json(o.id);
end $$;

create or replace function app.owner_cosigner_remove(p_admin uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  c owner_cosigners;
begin
  perform app.assert_admin(p_admin);
  if nullif(btrim(coalesce(p ->> 'reason', '')), '') is null then raise exception 'Give the reason' using errcode = '22023'; end if;
  update owner_cosigners set status = 'removed', removed_by = p_admin, removed_reason = btrim(p ->> 'reason')
   where id = (p ->> 'id')::uuid and status = 'pending' returning * into c;
  if c.id is null then raise exception 'Only an Owner who has not signed yet is removed' using errcode = '23514'; end if;
  insert into audit_log (actor_user_id, action, entity_table, entity_id, after)
  values (p_admin, 'owner_cosigner_remove', 'owner_cosigners', c.id::text, jsonb_build_object('owner_id', c.owner_id, 'reason', c.removed_reason));
  return app.owner_cosigners_json(c.owner_id) || '[]'::jsonb;
end $$;

-- The portal owner opens the documents: 0029's opening, except while they wait for other Owners (their own signature
-- is on the documents: nothing is opened again); then each Owner gets their link.
alter function app.owner_open_agreements(uuid, uuid, jsonb) rename to owner_open_agreements_0029;
create or replace function app.owner_open_agreements(p_owner uuid, p_by uuid, p_docs jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  v_out jsonb;
  c owner_cosigners;
begin
  if exists (select 1 from app.owner_open_requests(p_owner) q where q.status = 'partially_signed') then
    return jsonb_build_object('requests', (select coalesce(jsonb_agg(jsonb_build_object('key', q.key, 'agreement_id', q.agreement_id, 'signature_request_id', q.signature_request_id)), '[]'::jsonb)
                                             from app.owner_open_requests(p_owner) q), 'waiting_for_owners', true);
  end if;
  v_out := app.owner_open_agreements_0029(p_owner, p_by, p_docs);
  for c in select * from owner_cosigners where owner_id = p_owner and status in ('pending', 'signed') loop
    -- an Owner who signed documents that were replaced signs the new ones
    if c.status = 'signed' and exists (select 1 from unnest(c.signature_record_ids) rid join signature_records x on x.id = rid
                                        join signature_requests r on r.id = x.signature_request_id where r.status = 'voided') then
      update owner_cosigners set status = 'pending', signed_at = null, signature_record_ids = '{}' where id = c.id returning * into c;
    end if;
    if c.status = 'pending' and (c.link_sent_at is null or c.link_sent_at < now() - interval '1 hour') then
      perform app.owner_cosigner_send(c.id, null);
    end if;
  end loop;
  return v_out;
end $$;

-- The portal owner signs (0029): with another Owner still to sign, the signature is recorded and the documents wait.
alter function app.owner_sign_agreements(uuid, uuid, jsonb) rename to owner_sign_agreements_0029;
create or replace function app.owner_sign_agreements(p_owner uuid, p_by uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  v_out jsonb;
  v_waiting jsonb := (select coalesce(jsonb_agg(c.name order by c.created_at), '[]'::jsonb) from owner_cosigners c where c.owner_id = p_owner and c.status = 'pending');
begin
  if jsonb_array_length(v_waiting) = 0 then
    return app.owner_sign_agreements_0029(p_owner, p_by, p) || jsonb_build_object('complete', true, 'waiting_for', '[]'::jsonb);
  end if;
  perform set_config('app.cosign_defer', p_owner::text, true);
  v_out := app.owner_sign_agreements_0029(p_owner, p_by, p);
  perform set_config('app.cosign_defer', '', true);
  return v_out || jsonb_build_object('complete', false, 'waiting_for', v_waiting);
end $$;

-- What the signing page of another Owner shows: who they are, the owner, the documents and their SHA-256.
create or replace function app.owner_cosigner_facts(p_token text) returns jsonb
language sql stable security definer set search_path = public, app as $$
  select jsonb_build_object('cosigner', jsonb_build_object('id', c.id, 'name', c.name, 'email', c.email, 'status', c.status, 'signed_at', c.signed_at),
           'owner', jsonb_build_object('id', o.id, 'legal_name', o.legal_name, 'user_id', o.user_id, 'owner_type', o.owner_type, 'corporation_name', o.corporation_name),
           'documents', (select coalesce(jsonb_agg(jsonb_build_object('key', q.key, 'agreement_number', q.agreement_number, 'signature_request_id', q.signature_request_id,
                                                                    'sha256', q.sha256, 'status', q.status,
                                                                    'path', (select d.storage_path from signature_requests r join documents d on d.id = r.document_id where r.id = q.signature_request_id))
                                         order by q.key), '[]'::jsonb) from app.owner_open_requests(o.id) q),
           'waiting_for', (select coalesce(jsonb_agg(x.name order by x.created_at), '[]'::jsonb) from owner_cosigners x where x.owner_id = o.id and x.status = 'pending' and x.id <> c.id),
           'owner_signed', app.owner_primary_signed(o.id))
    from owner_cosigners c join owners o on o.id = c.owner_id
   where c.token = p_token and c.status <> 'removed'
$$;

-- Another Owner signs with their link: their own signature record on each open document (typed name, or a drawn
-- signature), the statement, their initials on the Enrollment Agreement's confirmations. The last Owner completes them.
-- p: {typed_name, drawn_signature, ip, user_agent, consent_text, initials, documents: [{signature_request_id, sha256}]}
create or replace function app.owner_cosigner_sign(p_token text, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  c owner_cosigners;
  q record;
  v_typed text := nullif(btrim(coalesce(p ->> 'typed_name', '')), '');
  v_drawn text := nullif(btrim(coalesce(p ->> 'drawn_signature', '')), '');
  v_ids uuid[] := '{}';
  v_rec uuid;
  v_n integer := 0;
begin
  select * into c from owner_cosigners where token = p_token and status <> 'removed' for update;
  if c.id is null then raise exception 'This link is not valid any more' using errcode = 'P0002'; end if;
  if c.status = 'signed' then return jsonb_build_object('repeat', true, 'complete', false); end if;
  if v_typed is null and v_drawn is null then raise exception 'Sign by typing your full legal name or by drawing your signature' using errcode = '22023'; end if;
  if v_drawn is null and lower(regexp_replace(v_typed, '\s+', '', 'g')) <> lower(regexp_replace(c.name, '\s+', '', 'g')) then
    raise exception 'The typed name must be your full legal name (%)', c.name using errcode = '23514';
  end if;
  if coalesce(p ->> 'consent_text', '') not like 'I have read these documents and I sign them electronically.%' then
    raise exception 'Tick the statement to sign' using errcode = '22023';
  end if;
  for q in select * from app.owner_open_requests(c.owner_id) loop
    if not exists (select 1 from jsonb_array_elements(coalesce(p -> 'documents', '[]'::jsonb)) d
                    where (d ->> 'signature_request_id')::uuid = q.signature_request_id and lower(d ->> 'sha256') = q.sha256) then
      raise exception 'The documents changed after you opened them: reload and sign the current version' using errcode = '23514';
    end if;
    insert into signature_records (signature_request_id, signer_role, signer_name, signer_email, status, signed_at, method, ip_address, user_agent,
                                   provider_signature, initials, typed_name, consent_text, document_sha256)
    values (q.signature_request_id, 'owner_individual', c.name, c.email, 'signed', now(), case when v_drawn is not null then 'drawn' else 'typed' end,
            nullif(p ->> 'ip', '')::inet, nullif(p ->> 'user_agent', ''), v_drawn,
            case when q.key = 'enrollment' and nullif(btrim(coalesce(p ->> 'initials', '')), '') is not null
                 then jsonb_build_object('own_insurance', upper(btrim(p ->> 'initials')), 'fees_no_income', upper(btrim(p ->> 'initials')), 'tracker_downtime', upper(btrim(p ->> 'initials'))) end,
            v_typed, p ->> 'consent_text', q.sha256)
    returning id into v_rec;
    v_ids := v_ids || v_rec; v_n := v_n + 1;
  end loop;
  if v_n = 0 then raise exception 'Nothing is waiting for your signature' using errcode = '23514'; end if;
  update owner_cosigners set status = 'signed', signed_at = now(), signature_record_ids = v_ids where id = c.id;
  insert into audit_log (action, entity_table, entity_id, after)
  values ('owner_cosigner_sign', 'owner_cosigners', c.id::text, jsonb_build_object('owner_id', c.owner_id, 'documents', v_n, 'records', to_jsonb(v_ids)));
  return jsonb_build_object('signed', v_n, 'owner_id', c.owner_id) || app.owner_agreements_finalize(c.owner_id);
end $$;

-- The owner portal's signing state: who of the Owners still has to sign.
alter function app.owner_signing_needed(uuid) rename to owner_signing_needed_0029;
create or replace function app.owner_signing_needed(p_owner uuid) returns jsonb
language sql stable security definer set search_path = public, app as $$
  select app.owner_signing_needed_0029(p_owner)
         || jsonb_build_object('owners', app.owner_cosigners_json(p_owner),
                               'waiting_for_owners', exists (select 1 from app.owner_open_requests(p_owner) q where q.status = 'partially_signed'),
                               'waiting_for', (select coalesce(jsonb_agg(c.name order by c.created_at), '[]'::jsonb) from owner_cosigners c where c.owner_id = p_owner and c.status = 'pending'))
$$;

-- What the agreements print (0029's facts): every Owner of the Title Schedule signs, so the documents list the other
-- Owners, and the page knows when the portal owner has signed and waits for them.
alter function app.owner_agreement_facts(uuid, uuid) rename to owner_agreement_facts_0029;
create or replace function app.owner_agreement_facts(p_owner uuid, p_by uuid) returns jsonb
language sql stable security definer set search_path = public, app as $$
  select app.owner_agreement_facts_0029(p_owner, p_by)
         || jsonb_build_object('cosigners', app.owner_cosigners_json(p_owner),
                               'waiting_for_owners', exists (select 1 from app.owner_open_requests(p_owner) q where q.status = 'partially_signed'))
$$;

-- ================================================================ 7. Form C on screen, with a witness beside the owner
alter table sign_requests add column if not exists vehicle_id uuid references vehicles (id);
alter table sign_requests drop constraint if exists sign_requests_doc_type_check;
alter table sign_requests add constraint sign_requests_doc_type_check
  check (doc_type in ('form_a', 'form_b', 'form_c', 'investment_agreement', 'staff_agreement', 'partner_agreement'));
alter table sign_requests drop constraint if exists sign_requests_check2;
alter table sign_requests add constraint sign_requests_form_c_vehicle check (doc_type <> 'form_c' or (owner_id is not null and vehicle_id is not null));

create or replace function app.owner_form_c_open(p_by uuid, p_vehicle uuid, p_sha256 text, p_path text, p_template_version text) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  o owners;
  v_owner uuid := app.portal_owner_id(p_by);
  r sign_requests;
  v_doc uuid;
  v_req uuid;
begin
  select * into o from owners where id = v_owner;
  if not exists (select 1 from jsonb_array_elements(app.owner_witnessed_forms(o.id)) x
                  where x ->> 'code' = 'C' and (x ->> 'vehicle_id')::uuid = p_vehicle and x ->> 'status' in ('needed', 'rejected')) then
    raise exception 'Form C for this car is not waiting for your signature' using errcode = '23514';
  end if;
  if lower(coalesce(p_sha256, '')) !~ '^[0-9a-f]{64}$' or coalesce(p_path, '') !~ ('^owners/' || o.id || '/') then
    raise exception 'The form document is missing' using errcode = '22023';
  end if;
  select * into r from sign_requests where owner_id = o.id and doc_type = 'form_c' and vehicle_id = p_vehicle and status = 'sent' for update;
  if r.id is not null and r.document_sha256 = lower(p_sha256) then return to_jsonb(r); end if;
  if r.id is not null then
    update sign_requests set status = 'voided', voided_at = now(), voided_by = p_by, void_reason = 'The form was made again' where id = r.id;
    update signature_requests set status = 'voided' where id = r.signature_request_id;
  end if;
  insert into documents (kind, title, storage_bucket, storage_path, mime_type, sha256, template_version, owner_id, vehicle_id, uploaded_by)
  values ('form_c_finance_permission_ack', 'Form C, lender or lessor permission acknowledgment', 'agreements', p_path, 'application/pdf',
          lower(p_sha256), p_template_version, o.id, p_vehicle, p_by)
  returning id into v_doc;
  insert into signature_requests (document_id, provider, status, sent_at, created_by) values (v_doc, 'builtin', 'sent', now(), p_by) returning id into v_req;
  insert into sign_requests (doc_type, owner_id, vehicle_id, signer_user_id, signer_name, signer_email, signer_role, title, document_id, document_sha256, template_version,
                             signature_request_id, sent_by)
  values ('form_c', o.id, p_vehicle, p_by, o.legal_name, o.email, 'owner_individual',
          'Form C, lender or lessor permission acknowledgment', v_doc, lower(p_sha256), p_template_version, v_req, p_by)
  returning * into r;
  return to_jsonb(r);
end $$;

-- ================================================================ 8. rentals added by staff: the card is charged when the renter signs
-- Adding the rental no longer charges the saved card: the result carries no charge. The renter's "Accept and sign"
-- charges it (the server, with the key manual-rental:<booking>), as the amendment does, and records the result here.
alter function app.manual_rental_create(uuid, jsonb) rename to manual_rental_create_0046;
create or replace function app.manual_rental_create(p_by uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  v_out jsonb := app.manual_rental_create_0046(p_by, p);
begin
  if v_out -> 'charge' is not null and v_out -> 'charge' <> 'null'::jsonb then
    v_out := (v_out - 'charge') || jsonb_build_object('charge', null, 'charge_on_sign', true);
  end if;
  return v_out;
end $$;

-- Staff never charge the saved card of a rental they added (0046's charge path): the renter's signature does.
alter function app.manual_rental_card_result(uuid, jsonb) rename to manual_rental_card_result_0046;
create or replace function app.manual_rental_card_result(p_by uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
begin
  if exists (select 1 from bookings b where b.id = nullif(p ->> 'booking', '')::uuid and b.added_by_staff and b.payment_mode = 'card'
               and not exists (select 1 from payments x where x.booking_id = b.id and x.purpose = 'booking_total' and x.status = 'succeeded')) then
    raise exception 'The saved card is charged when the renter signs the rental agreement, not before' using errcode = '23514';
  end if;
  return app.manual_rental_card_result_0046(p_by, p);
end $$;

-- What the renter's signing page charges: a rental added by staff, with the saved card, not paid yet.
create or replace function app.manual_rental_sign_charge(p_booking uuid, p_by uuid) returns jsonb
language sql stable security definer set search_path = public, app as $$
  select case when b.added_by_staff and b.payment_mode = 'card' and b.status = 'confirmed' and b.renter_due_at_booking_cents > 0
                   and not exists (select 1 from payments x where x.booking_id = b.id and x.purpose = 'booking_total' and x.status = 'succeeded')
              then jsonb_build_object('booking_id', b.id, 'booking_number', b.booking_number, 'amount_cents', b.renter_due_at_booking_cents,
                                      'customer_id', sc.processor_customer_id, 'method_id', sc.processor_method_id, 'brand', pm.card_brand, 'last4', pm.card_last4) end
    from bookings b join renters r on r.id = b.renter_id
    left join payment_methods pm on pm.id = b.card_on_file_id
    left join payment_method_secrets sc on sc.payment_method_id = pm.id
   where b.id = p_booking and (r.user_id = p_by or p_by is null)
$$;

-- The charge made when the renter signed: recorded as staff's charge was (0046), in the renter's name.
create or replace function app.manual_rental_sign_charged(p_booking uuid, p_by uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  b bookings;
  pm payment_methods;
  v_pay uuid;
begin
  select * into b from bookings where id = p_booking for update;
  if b.id is null or not b.added_by_staff or b.payment_mode <> 'card' then raise exception 'Booking not found' using errcode = 'P0002'; end if;
  if not exists (select 1 from renters r where r.id = b.renter_id and r.user_id = p_by) then raise exception 'Not permitted' using errcode = '42501'; end if;
  select id into v_pay from payments where booking_id = b.id and purpose = 'booking_total' and status = 'succeeded' limit 1;
  if v_pay is not null then return jsonb_build_object('payment_id', v_pay, 'repeat', true, 'ok', true); end if;
  select * into pm from payment_methods where id = b.card_on_file_id;
  if coalesce((p ->> 'ok')::boolean, false) then
    insert into payments (booking_id, renter_id, purpose, kind, method, amount_cents, status, payment_method_id, card_brand, card_last4, processed_at, created_by)
    values (b.id, b.renter_id, 'booking_total', 'charge', 'card', (p ->> 'amount_cents')::bigint, 'succeeded', pm.id, pm.card_brand, pm.card_last4, now(), p_by)
    returning id into v_pay;
    insert into payment_processor_details (payment_id, processor, processor_payment_id, processor_charge_id, raw)
    values (v_pay, 'stripe', p #>> '{processor,payment_id}', p #>> '{processor,charge_id}', jsonb_build_object('manual_rental', true, 'charged_on_signing', true));
    update booking_line_items set payment_id = v_pay where booking_id = b.id and stage = 'booking' and charged_to_renter and voided_at is null and payment_id is null;
  else
    insert into payments (booking_id, renter_id, purpose, kind, method, amount_cents, status, payment_method_id, card_brand, card_last4, decline_count,
                          last_decline_code, processed_at, created_by)
    values (b.id, b.renter_id, 'booking_total', 'charge', 'card', greatest(coalesce((p ->> 'amount_cents')::bigint, b.renter_due_at_booking_cents), 1), 'failed',
            pm.id, pm.card_brand, pm.card_last4, 1, left(coalesce(p ->> 'error', 'declined'), 200), now(), p_by)
    returning id into v_pay;
    perform app.raise_task(p_type => 'manual_rental_unpaid', p_title => format('The saved card was declined when the renter signed %s', b.booking_number),
        p_detail => coalesce(p ->> 'error', 'The card was declined') || '. Send a payment link or record a payment received another way.',
        p_booking => b.id, p_queue => 'finance', p_created_by => p_by, p_dedupe => 'manual_rental_unpaid:' || b.id);
  end if;
  insert into audit_log (actor_user_id, action, entity_table, entity_id, after)
  values (p_by, 'manual_rental_sign_charged', 'bookings', b.id::text, jsonb_build_object('ok', coalesce((p ->> 'ok')::boolean, false), 'payment_id', v_pay));
  return jsonb_build_object('payment_id', v_pay, 'ok', coalesce((p ->> 'ok')::boolean, false));
end $$;

-- ================================================================ 9. who gets the co-owner's email
alter function app.notification_recipients(app_events, notification_catalogue) rename to notification_recipients_0040;
create or replace function app.notification_recipients(p_event app_events, p_c notification_catalogue)
returns table (audience text, user_id uuid, email text, name text, renter_id uuid, owner_id uuid, immediate boolean)
language plpgsql stable security definer set search_path = public, app as $$
begin
  if p_c.code = 'owner_cosigner_sign' then
    return query select 'owner'::text, null::uuid, c.email, c.name, null::uuid, c.owner_id, true from owner_cosigners c where c.id = p_event.entity_id and c.status = 'pending';
    return;
  end if;
  return query select * from app.notification_recipients_0040(p_event, p_c);
end $$;

insert into notification_link_paths (key, path) values ('owner_cosign', '/sign/owner/{{token}}') on conflict (key) do update set path = excluded.path;

-- ================================================================ 10. the protection sold to renters is the "Protection Plan"
-- The charge renters see on new bookings, and the site's own copy (the seed writes a row only where none exists, so the
-- rows already on the live site are changed here, only where they still carry the old words).
update fee_types set label = 'Protection Plan' where code = 'coverage_sold' and label is distinct from 'Protection Plan';
do $$
declare
  pairs text[][] := array[
    array['Yes. Coverage bought through CarmaCars is priced in your offer', 'Yes. The Protection Plan is priced in your offer'],
    array['Coverage bought through CarmaCars', 'The CarmaCars Protection Plan'],
    array['Can I buy coverage from you?', 'Can I buy a Protection Plan from you?'],
    array['or coverage bought through CarmaCars', 'or the CarmaCars Protection Plan'],
    array['coverage bought through CarmaCars', 'the CarmaCars Protection Plan'],
    array['the provider of optional rental coverage if you buy it', 'the provider of the optional Protection Plan if you buy it'],
    array['messaging and optional rental coverage on their own terms', 'messaging and the optional Protection Plan on their own terms'],
    array['or payment for coverage through CarmaCars', 'or payment for the Protection Plan'],
    array['coverage purchased through CarmaCars', 'the Protection Plan bought through CarmaCars'],
    array['or coverage bought through us.', 'or the CarmaCars Protection Plan.'],
    array['add coverage to your booking.', 'add the Protection Plan to your booking.']];
  i integer;
begin
  for i in 1 .. array_length(pairs, 1) loop
    update site_content_blocks set data = replace(data::text, pairs[i][1], pairs[i][2])::jsonb where data::text like '%' || pairs[i][1] || '%';
    update site_content_blocks set body = replace(body, pairs[i][1], pairs[i][2]) where body like '%' || pairs[i][1] || '%';
  end loop;
end $$;

-- ================================================================ 11. the doors
create or replace function app.ops53(p_user uuid, p_call text, p_name text, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
begin
  case p_name
  when 'investment_countersign' then return app.investment_countersign(p_user, p);
  when 'owner_cosigners' then perform app.assert_admin(p_user); return app.owner_cosigners_json((p ->> 'owner_id')::uuid);
  when 'owner_cosigner_add' then return app.owner_cosigner_add(p_user, p);
  when 'owner_cosigner_remove' then return app.owner_cosigner_remove(p_user, p);
  when 'owner_cosigner_send' then perform app.assert_admin(p_user); return app.owner_cosigner_send((p ->> 'id')::uuid, p_user);
  when 'investment_countersign_state' then
    perform app.assert_admin(p_user);
    return (select coalesce(jsonb_agg(jsonb_build_object('agreement_id', a.id, 'agreement_number', a.agreement_number, 'status', a.status,
                    'company_signed_at', a.company_signed_at, 'awaiting_countersignature', app.investment_awaiting_countersignature(a.id),
                    'signing_officer', (app.settings()).signing_officer_name,
                    'may_countersign', (app.settings()).signing_officer_user_id is null or (app.settings()).signing_officer_user_id = p_user)), '[]'::jsonb)
              from investment_agreements a where a.investor_id = (p ->> 'investor_id')::uuid and a.status in ('sent', 'signed'));
  else raise exception 'Unknown action %', p_name using errcode = '22023';
  end case;
end $$;

alter function app.door(uuid, text, text, text, jsonb) rename to door_0049;
create or replace function app.door(p_user uuid, p_aal text, p_call text, p_name text, p jsonb default '{}'::jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
begin
  if p_call in ('ops_read', 'ops_do') and p_name in ('investment_countersign', 'owner_cosigners', 'owner_cosigner_add', 'owner_cosigner_remove',
                                                      'owner_cosigner_send', 'investment_countersign_state') then
    perform app.door_begin(p_user, p_aal);
    if p_call = 'ops_read' and p_name not in ('owner_cosigners', 'investment_countersign_state') then raise exception 'Unknown read %', p_name using errcode = '22023'; end if;
    if p_call = 'ops_do' and p_name in ('owner_cosigners', 'investment_countersign_state') then raise exception 'Unknown action %', p_name using errcode = '22023'; end if;
    return app.ops53(p_user, p_call, p_name, coalesce(p, '{}'::jsonb) - '_va');
  end if;
  return app.door_0049(p_user, p_aal, p_call, p_name, p);
end $$;

-- The server's own calls (as the service role).
create or replace function public.server_owner_cosigner_facts(p_token text) returns jsonb
language sql stable security invoker set search_path = public, app as $$ select app.owner_cosigner_facts(p_token) $$;
create or replace function public.server_owner_cosigner_sign(p_token text, p jsonb) returns jsonb
language sql volatile security invoker set search_path = public, app as $$ select app.owner_cosigner_sign(p_token, p) $$;
create or replace function public.owner_form_c_open(p_by uuid, p_vehicle uuid, p_sha256 text, p_path text, p_template_version text) returns jsonb
language sql volatile security invoker set search_path = public, app as $$ select app.owner_form_c_open(p_by, p_vehicle, p_sha256, p_path, p_template_version) $$;
create or replace function public.server_manual_rental_sign_charge(p_booking uuid, p_by uuid) returns jsonb
language sql stable security invoker set search_path = public, app as $$ select app.manual_rental_sign_charge(p_booking, p_by) $$;
create or replace function public.server_manual_rental_sign_charged(p_booking uuid, p_by uuid, p jsonb) returns jsonb
language sql volatile security invoker set search_path = public, app as $$ select app.manual_rental_sign_charged(p_booking, p_by, p) $$;
create or replace function public.server_owner_agreement_extras(p_owner uuid) returns jsonb
language sql stable security invoker set search_path = public, app as $$
  select jsonb_build_object('cosigners', app.owner_cosigners_json(p_owner), 'signing', app.owner_signing_needed(p_owner))
$$;

-- ================================================================ 12. privileges
do $$
declare
  f record;
begin
  for f in
    select p.oid::regprocedure as sig from pg_proc p join pg_namespace n on n.oid = p.pronamespace
     where (n.nspname = 'app' and p.proname = any (array[
              'owner_payee_name', 'owner_debit_payee', 'owner_late_fee_rule', 'owner_pad_agreement', 'owner_mandate_description', 'owner_debit_terms',
              'owner_debit_is_nsf', 'owner_invoice_lines_late_fee_guard', 'owner_debit_fail', 'owner_debit_claim', 'corporate_signature_text',
              'signature_records_corporate', 'signature_records_paper_date', 'program_settings_officer_date', 'amendment_countersigner', 'investment_awaiting_countersignature',
              'investment_countersign', 'cosign_defer_requests', 'cosign_defer_agreements', 'cosign_defer_schedules', 'owner_open_requests',
              'owner_cosigners_json', 'owner_primary_signed', 'owner_agreements_finalize', 'owner_cosigner_send', 'owner_cosigner_add',
              'owner_cosigner_remove', 'owner_cosigner_facts', 'owner_cosigner_sign', 'owner_form_c_open', 'manual_rental_sign_charge',
              'manual_rental_sign_charged', 'ops53', 'door']))
        or (n.nspname = 'public' and p.proname = any (array['server_owner_cosigner_facts', 'server_owner_cosigner_sign', 'owner_form_c_open',
              'server_manual_rental_sign_charge', 'server_manual_rental_sign_charged', 'server_owner_agreement_extras', 'server_signature_lines',
              'server_amendment_record']))
  loop
    execute format('revoke all on function %s from public, anon, authenticated', f.sig);
    execute format('grant execute on function %s to service_role', f.sig);
  end loop;
end $$;

-- Each renamed function keeps its privileges; the function in its place gets the same.
do $$
declare
  r record;
  v_new regprocedure;
  g text;
begin
  for r in select p.oid, m.new_name, oidvectortypes(p.proargtypes) as args
             from pg_proc p join pg_namespace n on n.oid = p.pronamespace
             join (values ('ntf_payload_0051', 'notification_payload'), ('owner_debit_result_0038', 'owner_debit_result'),
                          ('sign_booking_amendment_0051', 'sign_booking_amendment'), ('my_sign_requests_0044', 'my_sign_requests'),
                          ('sign_request_sign_0046', 'sign_request_sign'), ('record_paper_signature_0051', 'record_paper_signature'),
                          ('owner_open_agreements_0029', 'owner_open_agreements'), ('owner_sign_agreements_0029', 'owner_sign_agreements'),
                          ('owner_signing_needed_0029', 'owner_signing_needed'), ('manual_rental_create_0046', 'manual_rental_create'),
                          ('notification_recipients_0040', 'notification_recipients'), ('door_0049', 'door'),
                          ('owner_agreement_facts_0029', 'owner_agreement_facts'), ('manual_rental_card_result_0046', 'manual_rental_card_result')) m(old_name, new_name)
               on m.old_name = p.proname
            where n.nspname = 'app' loop
    v_new := format('app.%I(%s)', r.new_name, r.args)::regprocedure;
    execute format('revoke all on function %s from public, anon, authenticated', v_new);
    foreach g in array array['anon', 'authenticated', 'service_role'] loop
      if has_function_privilege(g, r.oid, 'execute') then execute format('grant execute on function %s to %I', v_new, g); end if;
    end loop;
  end loop;
end $$;

-- ================================================================ 13. the email catalogue
-- CATALOGUE 0053 START (generated by supabase/seed/0053_gen_catalogue.mjs; do not edit by hand)
insert into notification_catalogue (code, audience, also_sent_to, category, is_digest, digest_slot, from_address, reply_to,
    subject, preheader, timing, trigger_text, replaces_template, link_path, variables, template_html, template_text) values
  ('renter_rental_added', 'renter', '{}'::text[], 'transactional', false, null, 'CarmaCars <bookings@carmacars.ca>', 'bookings@carmacars.ca', 'Booked: {{vehicle_name}}, {{pickup_date}}', 'Booking {{booking_number}}. {{payment_line}} Next: sign your rental agreement.', 'Immediate', 'CarmaCars staff add a rental by hand (Admin > Bookings > Add a rental, or the VA equivalent) and it is confirmed at once: paid another way, to be charged to the saved card when the renter signs, or to be invoiced later. Not sent when staff tick "Do not email the renter", for a past rental, or for a payment link (the offer email carries the link).', null, '/account/bookings/{{booking_number}}/sign', '[{"name":"balance_line","type":"string"},{"name":"booking_number","type":"string"},{"name":"company_address","type":"string","global":true},{"name":"contact_email","type":"string","global":true},{"name":"deposit_amount","type":"string"},{"name":"first_name","type":"string"},{"name":"has_balance","type":"boolean"},{"name":"instagram_url","type":"url","global":true},{"name":"km_allowance","type":"string"},{"name":"line_items","type":"list","fields":["label","amount"]},{"name":"needs_verification","type":"boolean"},{"name":"opening_hours","type":"string","global":true},{"name":"overage_rate","type":"string"},{"name":"payment_line","type":"string"},{"name":"pickup_date","type":"string"},{"name":"pickup_place","type":"string"},{"name":"pickup_time","type":"string"},{"name":"reply_time","type":"string","global":true},{"name":"return_date","type":"string"},{"name":"return_place","type":"string"},{"name":"return_time","type":"string"},{"name":"sign_line","type":"string"},{"name":"support_phone","type":"string","global":true},{"name":"tiktok_url","type":"url","global":true},{"name":"total_amount","type":"string"},{"name":"vehicle_image_url","type":"url"},{"name":"vehicle_name","type":"string"},{"name":"verify_by","type":"string"}]'::jsonb, 'templates/renter_rental_added.html', 'templates/renter_rental_added.txt'),
  ('owner_cosigner_sign', 'owner', '{}'::text[], 'transactional', false, null, 'CarmaCars <owners@carmacars.ca>', 'owners@carmacars.ca', 'Your CarmaCars owner documents are ready to sign', 'You are named as an Owner. Read the documents and sign them with your own link.', 'Immediate', 'Every Owner named in the Title Schedule signs the program agreements. The documents of an owner are opened for signature (or an Admin adds an Owner, or sends the link again): each Owner besides the one with the portal account gets their own signing link. The agreements take effect when the last Owner signs.', null, '/sign/owner/{{token}}', '[{"name":"company_address","type":"string","global":true},{"name":"contact_email","type":"string","global":true},{"name":"first_name","type":"string"},{"name":"instagram_url","type":"url","global":true},{"name":"opening_hours","type":"string","global":true},{"name":"owner_name","type":"string"},{"name":"reply_time","type":"string","global":true},{"name":"support_phone","type":"string","global":true},{"name":"tiktok_url","type":"url","global":true},{"name":"token","type":"string"}]'::jsonb, 'templates/owner_cosigner_sign.html', 'templates/owner_cosigner_sign.txt'),
  ('owner_debit_notice', 'owner', '{}'::text[], 'transactional', false, null, 'CarmaCars <billing@carmacars.ca>', 'billing@carmacars.ca', 'Pre-authorized debit on {{debit_date}}: {{debit_total}}', '{{debit_count_text}} from your account ending {{bank_last4}}. Nothing to do if your account is up to date.', 'The notice days before the debit day (the 5th for the 15th by default)', 'Owner debit notice job, on the notice day (the debit day less the notice days in Program settings, 10 by default): the owner has issued invoices that will be debited automatically on the debit day from their pre-authorized debit account. One email per owner, listing every invoice in the debit. Required notice under the pre-authorized debit agreement.', null, '/owner/billing', '[{"name":"bank_last4","type":"string"},{"name":"company_address","type":"string","global":true},{"name":"contact_email","type":"string","global":true},{"name":"debit_count_text","type":"string"},{"name":"debit_date","type":"string"},{"name":"debit_items","type":"list","fields":["invoice_number","vehicle","covers","amount"]},{"name":"debit_total","type":"string"},{"name":"first_name","type":"string"},{"name":"instagram_url","type":"url","global":true},{"name":"late_fee_rule","type":"string"},{"name":"notice_days","type":"string"},{"name":"opening_hours","type":"string","global":true},{"name":"payee_name","type":"string"},{"name":"reply_time","type":"string","global":true},{"name":"support_phone","type":"string","global":true},{"name":"tiktok_url","type":"url","global":true}]'::jsonb, 'templates/owner_debit_notice.html', 'templates/owner_debit_notice.txt'),
  ('owner_debit_returned', 'owner', '{}'::text[], 'transactional', false, null, 'CarmaCars <billing@carmacars.ca>', 'billing@carmacars.ca', 'The debit for invoice {{invoice_number}} was returned', 'We will not debit this invoice again. Pay it from its page or update your bank account.', 'The day the bank reports the returned debit', 'The bank returns the automatic debit of an owner invoice for a reason other than insufficient funds (for example the account is closed), or for insufficient funds too late for a retry within 30 days of the original debit. The debit is not retried: the automatic debit of that invoice is paused and an Admin is alerted at the same time. One email per returned debit.', null, '/owner/invoices/{{invoice_number}}', '[{"name":"amount","type":"string"},{"name":"balance","type":"string"},{"name":"bank_reason","type":"string"},{"name":"company_address","type":"string","global":true},{"name":"contact_email","type":"string","global":true},{"name":"debit_date","type":"string"},{"name":"first_name","type":"string"},{"name":"has_late_fee","type":"boolean"},{"name":"instagram_url","type":"url","global":true},{"name":"invoice_number","type":"string"},{"name":"late_fee","type":"string"},{"name":"opening_hours","type":"string","global":true},{"name":"payee_name","type":"string"},{"name":"reply_time","type":"string","global":true},{"name":"support_phone","type":"string","global":true},{"name":"tiktok_url","type":"url","global":true},{"name":"vehicle_name","type":"string"}]'::jsonb, 'templates/owner_debit_returned.html', 'templates/owner_debit_returned.txt'),
  ('owner_debit_setup_needed', 'owner', '{}'::text[], 'transactional', false, null, 'CarmaCars <billing@carmacars.ca>', 'billing@carmacars.ca', 'Set up your bank debit for {{debit_total}} due {{debit_date}}', 'We have no pre-authorized debit for your account, so nothing was scheduled. It takes two minutes.', 'The notice day, or the debit day when the agreement was cancelled since the notice', 'Owner debit notice job (or the debit run itself): the owner has invoices due for the automatic debit but no active pre-authorized debit agreement on file, or it was cancelled at the bank. Nothing is debited. One email per owner per debit date. An Admin gets the exception at the same time.', null, '/owner/banking', '[{"name":"company_address","type":"string","global":true},{"name":"contact_email","type":"string","global":true},{"name":"debit_date","type":"string"},{"name":"debit_day","type":"string"},{"name":"debit_items","type":"list","fields":["invoice_number","vehicle","covers","amount"]},{"name":"debit_total","type":"string"},{"name":"first_name","type":"string"},{"name":"instagram_url","type":"url","global":true},{"name":"late_fee_rule","type":"string"},{"name":"notice_days","type":"string"},{"name":"opening_hours","type":"string","global":true},{"name":"payee_name","type":"string"},{"name":"reply_time","type":"string","global":true},{"name":"support_phone","type":"string","global":true},{"name":"tiktok_url","type":"url","global":true}]'::jsonb, 'templates/owner_debit_setup_needed.html', 'templates/owner_debit_setup_needed.txt'),
  ('owner_fee_invoice', 'owner', '{}'::text[], 'transactional', false, null, 'CarmaCars <billing@carmacars.ca>', 'billing@carmacars.ca', 'Invoice {{invoice_number}}: {{invoice_month}} fees for your {{vehicle_name}}, {{invoice_total}}', 'Due on {{due_date}}. Pay from the invoice page by card or pre-authorized debit.', '15th of each month', 'Owner-billing job on the 15th: a monthly owner invoice for a vehicle is issued and its pre-authorized debit is submitted. One invoice and one email per vehicle. Not sent for Turo-Only vehicles or vehicles owned personally by the two principals. (Message template T24.)', 'T24', '/owner/invoices/{{invoice_number}}', '[{"name":"bank_last4","type":"string"},{"name":"company_address","type":"string","global":true},{"name":"contact_email","type":"string","global":true},{"name":"due_date","type":"string"},{"name":"first_name","type":"string"},{"name":"instagram_url","type":"url","global":true},{"name":"invoice_lines","type":"list","fields":["label","amount"]},{"name":"invoice_month","type":"string"},{"name":"invoice_number","type":"string"},{"name":"invoice_period","type":"string"},{"name":"invoice_total","type":"string"},{"name":"late_fee_rule","type":"string"},{"name":"opening_hours","type":"string","global":true},{"name":"payee_name","type":"string"},{"name":"reply_time","type":"string","global":true},{"name":"support_phone","type":"string","global":true},{"name":"tiktok_url","type":"url","global":true},{"name":"vehicle_name","type":"string"},{"name":"vehicle_plate","type":"string"}]'::jsonb, 'templates/owner_fee_invoice.html', 'templates/owner_fee_invoice.txt'),
  ('owner_in_arrears', 'owner', '{}'::text[], 'transactional', false, null, 'CarmaCars <billing@carmacars.ca>', 'billing@carmacars.ca', 'In arrears: {{arrears_amount}} owing on your {{vehicle_name}}', 'The retry failed. Pay by {{removal_date}} to keep the vehicle in the program.', 'The day the bank reports the failed retry (18th or after)', 'Debit-retry job on the 18th: the retry of a failed owner invoice also fails and the invoice status becomes in_arrears (the vehicle''s arrears flag is set).', null, '/owner/invoices/{{invoice_number}}', '[{"name":"amount","type":"string"},{"name":"arrears_amount","type":"string"},{"name":"arrears_removal_days","type":"string"},{"name":"company_address","type":"string","global":true},{"name":"contact_email","type":"string","global":true},{"name":"first_name","type":"string"},{"name":"instagram_url","type":"url","global":true},{"name":"invoice_number","type":"string"},{"name":"is_self_managed","type":"boolean"},{"name":"late_fee","type":"string"},{"name":"next_payout_date","type":"string"},{"name":"opening_hours","type":"string","global":true},{"name":"payee_name","type":"string"},{"name":"removal_date","type":"string"},{"name":"reply_time","type":"string","global":true},{"name":"support_phone","type":"string","global":true},{"name":"tiktok_url","type":"url","global":true},{"name":"vehicle_name","type":"string"}]'::jsonb, 'templates/owner_in_arrears.html', 'templates/owner_in_arrears.txt'),
  ('owner_pad_confirmed', 'owner', '{}'::text[], 'transactional', false, null, 'CarmaCars <billing@carmacars.ca>', 'billing@carmacars.ca', 'Your pre-authorized debit agreement with {{payee_name}}', 'Your confirmation for the account ending {{bank_last4}}. Keep it for your records.', 'Immediate, when the debit mandate becomes active', 'An owner''s pre-authorized debit mandate becomes active (set up under Banking, confirmed by micro-deposits, or saved with a debit paid from an invoice page). CarmaCars'' own confirmation of the pre-authorized debit agreement (Payments Canada Rule H1): the agreement, the payee and how to reach it, the account, the timing, how to cancel and the recourse rights. Sent once per debit mandate. An automatic debit is scheduled only with its notice, the notice days ahead, so this confirmation comes before the first automatic debit.', null, '/owner/banking', '[{"name":"accepted_on","type":"string"},{"name":"agreement_1","type":"string"},{"name":"agreement_2","type":"string"},{"name":"agreement_3","type":"string"},{"name":"agreement_4","type":"string"},{"name":"agreement_kind","type":"string"},{"name":"agreement_type","type":"string"},{"name":"bank_last4","type":"string"},{"name":"bank_name","type":"string"},{"name":"company_address","type":"string","global":true},{"name":"contact_email","type":"string","global":true},{"name":"debit_day","type":"string"},{"name":"first_debit_date","type":"string"},{"name":"first_name","type":"string"},{"name":"instagram_url","type":"url","global":true},{"name":"late_fee_rule","type":"string"},{"name":"notice_days","type":"string"},{"name":"opening_hours","type":"string","global":true},{"name":"payee_address","type":"string"},{"name":"payee_email","type":"string"},{"name":"payee_name","type":"string"},{"name":"payee_phone","type":"string"},{"name":"reply_time","type":"string","global":true},{"name":"support_phone","type":"string","global":true},{"name":"tiktok_url","type":"url","global":true}]'::jsonb, 'templates/owner_pad_confirmed.html', 'templates/owner_pad_confirmed.txt'),
  ('owner_payment_failed', 'owner', '{}'::text[], 'transactional', false, null, 'CarmaCars <billing@carmacars.ca>', 'billing@carmacars.ca', 'Your {{amount}} payment for the {{vehicle_name}} failed', 'A {{late_fee}} late fee is added to your next debit. We retry {{amount}} on or after {{retry_date}}.', 'The day the bank reports the failed debit', 'The bank returns the automatic debit of an owner invoice for insufficient funds (the first debit): the invoice status becomes failed, the Late Fee is added once as its own line, and one retry of the original amount is scheduled on the later of the retry day and 3 business days after the return, within 30 days of the original debit. One email per vehicle. A debit returned for another reason sends owner_debit_returned instead. (Message template T25.)', 'T25', '/owner/billing', '[{"name":"amount","type":"string"},{"name":"company_address","type":"string","global":true},{"name":"contact_email","type":"string","global":true},{"name":"first_name","type":"string"},{"name":"instagram_url","type":"url","global":true},{"name":"invoice_month","type":"string"},{"name":"invoice_number","type":"string"},{"name":"late_fee","type":"string"},{"name":"late_fee_rule","type":"string"},{"name":"opening_hours","type":"string","global":true},{"name":"payee_name","type":"string"},{"name":"reply_time","type":"string","global":true},{"name":"retry_amount","type":"string"},{"name":"retry_date","type":"string"},{"name":"support_phone","type":"string","global":true},{"name":"tiktok_url","type":"url","global":true},{"name":"vehicle_name","type":"string"}]'::jsonb, 'templates/owner_payment_failed.html', 'templates/owner_payment_failed.txt'),
  ('owner_payment_received', 'owner', '{}'::text[], 'transactional', false, null, 'CarmaCars <billing@carmacars.ca>', 'billing@carmacars.ca', 'Payment received: {{amount}} for invoice {{invoice_number}}', 'For your {{vehicle_name}}. Nothing more to do.', 'Immediate', 'An owner invoice changes to paid: the debit for a monthly invoice clears (including a cleared retry), or the upfront invoice is paid by card or e-Transfer.', null, '/owner/invoices/{{invoice_number}}', '[{"name":"amount","type":"string"},{"name":"company_address","type":"string","global":true},{"name":"contact_email","type":"string","global":true},{"name":"first_name","type":"string"},{"name":"instagram_url","type":"url","global":true},{"name":"invoice_number","type":"string"},{"name":"opening_hours","type":"string","global":true},{"name":"payee_name","type":"string"},{"name":"payment_date","type":"string"},{"name":"payment_method","type":"string"},{"name":"reply_time","type":"string","global":true},{"name":"support_phone","type":"string","global":true},{"name":"tiktok_url","type":"url","global":true},{"name":"vehicle_name","type":"string"}]'::jsonb, 'templates/owner_payment_received.html', 'templates/owner_payment_received.txt'),
  ('owner_payment_recorded', 'owner', '{}'::text[], 'transactional', false, null, 'CarmaCars <billing@carmacars.ca>', 'billing@carmacars.ca', 'Receipt: {{amount}} received for invoice {{invoice_number}}', 'Paid by {{payment_method}} on {{payment_date}}. {{balance_line}}', 'Immediate', 'An Admin or Finance records a payment received outside the card processor (e-Transfer, cheque, cash, bank transfer or another way) on an owner invoice, in full or in part. The receipt for that payment; the automatic debit stops, or debits only what is still owing.', null, '/owner/invoices/{{invoice_number}}', '[{"name":"amount","type":"string"},{"name":"balance","type":"string"},{"name":"balance_line","type":"string"},{"name":"company_address","type":"string","global":true},{"name":"contact_email","type":"string","global":true},{"name":"debit_line","type":"string"},{"name":"first_name","type":"string"},{"name":"has_reference","type":"boolean"},{"name":"instagram_url","type":"url","global":true},{"name":"invoice_number","type":"string"},{"name":"is_paid_in_full","type":"boolean"},{"name":"opening_hours","type":"string","global":true},{"name":"payee_name","type":"string"},{"name":"payment_date","type":"string"},{"name":"payment_method","type":"string"},{"name":"reference","type":"string"},{"name":"reply_time","type":"string","global":true},{"name":"support_phone","type":"string","global":true},{"name":"tiktok_url","type":"url","global":true},{"name":"vehicle_name","type":"string"}]'::jsonb, 'templates/owner_payment_recorded.html', 'templates/owner_payment_recorded.txt'),
  ('owner_payment_reversed', 'owner', '{}'::text[], 'transactional', false, null, 'CarmaCars <billing@carmacars.ca>', 'billing@carmacars.ca', 'Payment for invoice {{invoice_number}} was not received', '{{amount}} by {{payment_method}} on {{payment_date}}. {{balance}} is owing.', 'Immediate', 'An Admin voids a payment that was recorded by hand on an owner invoice (for example a cheque that was returned, or a payment recorded on the wrong invoice), with the reason. The invoice owes that amount again.', null, '/owner/invoices/{{invoice_number}}', '[{"name":"amount","type":"string"},{"name":"balance","type":"string"},{"name":"company_address","type":"string","global":true},{"name":"contact_email","type":"string","global":true},{"name":"debit_date","type":"string"},{"name":"instagram_url","type":"url","global":true},{"name":"invoice_number","type":"string"},{"name":"opening_hours","type":"string","global":true},{"name":"payee_name","type":"string"},{"name":"payment_date","type":"string"},{"name":"payment_method","type":"string"},{"name":"reply_time","type":"string","global":true},{"name":"support_phone","type":"string","global":true},{"name":"tiktok_url","type":"url","global":true},{"name":"vehicle_name","type":"string"},{"name":"void_reason","type":"string"}]'::jsonb, 'templates/owner_payment_reversed.html', 'templates/owner_payment_reversed.txt'),
  ('owner_payout_sent', 'owner', '{}'::text[], 'transactional', false, null, 'CarmaCars <billing@carmacars.ca>', 'billing@carmacars.ca', 'Payout sent: {{payout_amount}} for {{statement_month}}', 'By bank transfer to your account ending {{bank_last4}}.', '10th of each month, when the transfer is sent', 'A payout row for an owner changes to paid (an admin sent the bank transfer and recorded its reference). Normally the 10th. Not sent when the statement shows a balance owing instead of a payout. (Message template T26, payment part.)', 'T26', '/owner/statements/{{statement_number}}', '[{"name":"bank_last4","type":"string"},{"name":"company_address","type":"string","global":true},{"name":"contact_email","type":"string","global":true},{"name":"first_name","type":"string"},{"name":"instagram_url","type":"url","global":true},{"name":"opening_hours","type":"string","global":true},{"name":"payee_name","type":"string"},{"name":"payment_date","type":"string"},{"name":"payout_amount","type":"string"},{"name":"payout_day","type":"string"},{"name":"payout_reference","type":"string"},{"name":"reply_time","type":"string","global":true},{"name":"statement_month","type":"string"},{"name":"statement_number","type":"string"},{"name":"support_phone","type":"string","global":true},{"name":"tiktok_url","type":"url","global":true}]'::jsonb, 'templates/owner_payout_sent.html', 'templates/owner_payout_sent.txt'),
  ('owner_statement_ready', 'owner', '{}'::text[], 'transactional', false, null, 'CarmaCars <billing@carmacars.ca>', 'billing@carmacars.ca', 'Your {{statement_month}} statement: {{payout_amount}}', 'Owner Revenue {{owner_revenue_total}}. {{payout_summary}}', '10th of each month', 'An owner statement changes to issued: on the 10th of the month, after an admin approves the payout run, for the previous month. One statement and one email per owner, covering all their vehicles. (Message template T26, statement part.)', 'T26', '/owner/statements/{{statement_number}}', '[{"name":"balance_forward","type":"string"},{"name":"company_address","type":"string","global":true},{"name":"contact_email","type":"string","global":true},{"name":"deductions_total","type":"string"},{"name":"first_name","type":"string"},{"name":"has_balance_forward","type":"boolean"},{"name":"has_payout_hst","type":"boolean"},{"name":"instagram_url","type":"url","global":true},{"name":"kickbacks_deducted","type":"string"},{"name":"kickbacks_earned","type":"string"},{"name":"link_expiry","type":"string"},{"name":"opening_hours","type":"string","global":true},{"name":"owner_revenue_total","type":"string"},{"name":"payee_name","type":"string"},{"name":"payout_amount","type":"string"},{"name":"payout_hst","type":"string"},{"name":"payout_label","type":"string"},{"name":"payout_summary","type":"string"},{"name":"rentals_total","type":"string"},{"name":"reply_time","type":"string","global":true},{"name":"revenue_share_total","type":"string"},{"name":"statement_month","type":"string"},{"name":"statement_number","type":"string"},{"name":"statement_url","type":"url"},{"name":"statement_vehicles","type":"list","fields":["name","owner_revenue","payable"]},{"name":"support_phone","type":"string","global":true},{"name":"tiktok_url","type":"url","global":true}]'::jsonb, 'templates/owner_statement_ready.html', 'templates/owner_statement_ready.txt'),
  ('owner_toll_ticket', 'owner', '{}'::text[], 'transactional', false, null, 'CarmaCars <billing@carmacars.ca>', 'billing@carmacars.ca', '{{notice_type}} for your {{vehicle_name}}, {{notice_amount}}', '{{notice_action_short}}', 'Immediate, when Finance matches the notice', 'A toll or ticket is matched to the owner rather than a renter. is_forwarded true: the owner had the car outside the program, or the car is Turo-Only, and the notice is forwarded for the owner to pay. is_forwarded false: the owner had the car on an Owner Booking, CarmaCars paid it and an owner deduction is created at cost with no fee.', null, null, '[{"name":"company_address","type":"string","global":true},{"name":"contact_email","type":"string","global":true},{"name":"first_name","type":"string"},{"name":"instagram_url","type":"url","global":true},{"name":"is_forwarded","type":"boolean"},{"name":"notice_action_short","type":"string"},{"name":"notice_amount","type":"string"},{"name":"notice_description","type":"string"},{"name":"notice_due_date","type":"string"},{"name":"notice_event_date","type":"string"},{"name":"notice_number","type":"string"},{"name":"notice_type","type":"string"},{"name":"notice_type_lower","type":"string"},{"name":"opening_hours","type":"string","global":true},{"name":"payee_name","type":"string"},{"name":"reply_time","type":"string","global":true},{"name":"support_phone","type":"string","global":true},{"name":"supporting_document_url","type":"url"},{"name":"tiktok_url","type":"url","global":true},{"name":"vehicle_name","type":"string"}]'::jsonb, 'templates/owner_toll_ticket.html', 'templates/owner_toll_ticket.txt'),
  ('owner_upfront_invoice', 'owner', '{}'::text[], 'transactional', false, null, 'CarmaCars <billing@carmacars.ca>', 'billing@carmacars.ca', 'Upfront invoice {{invoice_number}} for the {{vehicle_name}}: {{invoice_total}}', 'Pay by card or e-Transfer to start registration. No security deposit.', 'Immediate', 'The upfront owner invoice for a vehicle is issued after documents_signed: the Install Fee plus the first and last month''s Insurance Fee, with HST. Not issued for Turo-Only or shareholder-owned vehicles.', null, '/owner/invoices/{{invoice_number}}', '[{"name":"company_address","type":"string","global":true},{"name":"contact_email","type":"string","global":true},{"name":"first_name","type":"string"},{"name":"instagram_url","type":"url","global":true},{"name":"invoice_lines","type":"list","fields":["label","amount"]},{"name":"invoice_number","type":"string"},{"name":"invoice_total","type":"string"},{"name":"opening_hours","type":"string","global":true},{"name":"payee_name","type":"string"},{"name":"reply_time","type":"string","global":true},{"name":"support_phone","type":"string","global":true},{"name":"tiktok_url","type":"url","global":true},{"name":"vehicle_name","type":"string"}]'::jsonb, 'templates/owner_upfront_invoice.html', 'templates/owner_upfront_invoice.txt')
on conflict (code) do update set
  audience = excluded.audience, also_sent_to = excluded.also_sent_to, category = excluded.category,
  is_digest = excluded.is_digest, digest_slot = excluded.digest_slot, from_address = excluded.from_address,
  reply_to = excluded.reply_to, subject = excluded.subject, preheader = excluded.preheader, timing = excluded.timing,
  trigger_text = excluded.trigger_text, replaces_template = excluded.replaces_template, link_path = excluded.link_path,
  variables = excluded.variables, template_html = excluded.template_html, template_text = excluded.template_text,
  in_catalogue = true, updated_at = now();
select app.notification_catalogue_refresh();
-- CATALOGUE 0053 END
update notification_catalogue set emitted_by = 'app.owner_debit_fail (0053)' where code = 'owner_debit_returned';
update notification_catalogue set emitted_by = 'app.owner_cosigner_send (0053)' where code = 'owner_cosigner_sign';
select app.attach_audit();
