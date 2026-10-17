-- 0056_debit_return_checks.sql
-- Found by the Stripe test-mode run of the legal review's section 6 tests (docs/changes/2026-10-16-legal-review-applied.md):
--   1. a debit returned for another reason than insufficient funds kept a retry date on the invoice (the status trigger
--      of 0007 filled it in when the invoice failed), although it is never retried; the trigger now leaves it empty
--      whenever app.owner_debit_fail says there is no retry, and invoices already in that state lose it
--   2. the Admin task of such a return printed the bank's reason with a second full stop
--   3. the finance task "Owner debit failed" still said "Late Fee added; retry on the 18th"
-- Idempotent. Function signatures unchanged.

create or replace function app.owner_invoice_status_stamp() returns trigger
language plpgsql security definer set search_path = public, app as $$
declare
  v_set program_settings := app.settings(coalesce(new.billing_date, app.today()));
begin
  if new.status = old.status then return new; end if;
  if new.status = 'issued' and new.issued_at is null then new.issued_at := now(); end if;
  if new.status = 'failed' then
    new.first_failed_on := coalesce(new.first_failed_on, app.today());
    -- a debit not retried (another return reason, the retry window passed, or in arrears) keeps no retry date (0056)
    if coalesce(current_setting('app.debit_no_retry', true), '') <> new.id::text then
      new.retry_on := coalesce(new.retry_on, app.retry_date(new.billing_date));
    end if;
    new.paid_cents := 0;          -- a debit returned after it showed as paid
    new.paid_at := null;
  end if;
  if new.status = 'in_arrears' then
    new.retry_failed_on := coalesce(new.retry_failed_on, app.today());
    new.removal_allowed_on := new.retry_failed_on + v_set.owner_arrears_removal_days;
  end if;
  if new.status in ('paid', 'deducted') then
    new.paid_at := coalesce(new.paid_at, now());
    -- (generated columns are not yet computed in a BEFORE trigger, so the total is spelled out)
    if new.status = 'paid' then
      new.paid_cents := new.fees_cents + new.hst_cents + new.late_fee_cents - new.deducted_cents;
    end if;
  end if;
  return new;
end $$;

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
                     app.fmt_day(a.debit_on), app.fmt_money(a.amount_cents), rtrim(btrim(v_msg), '.')),
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

-- invoices whose debit was returned and not retried (paused, no retry scheduled) keep no retry date
update owner_invoices i set retry_on = null
 where i.status = 'failed' and i.auto_debit_paused and i.retry_on is not null
   and not exists (select 1 from owner_debit_attempts a where a.owner_invoice_id = i.id and a.status in ('scheduled', 'submitting', 'processing'));

update task_rules
   set description = 'Insufficient funds: the Late Fee is added and the original amount is tried once more within 30 days. Any other reason: not retried, the automatic debit is paused and an Admin has a task.'
 where task_type = 'debit_failed'
   and description is distinct from 'Insufficient funds: the Late Fee is added and the original amount is tried once more within 30 days. Any other reason: not retried, the automatic debit is paused and an Admin has a task.';
