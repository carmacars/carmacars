-- 0871: a missed owner debit is recovered from the owner's next revenue statement, by itself (Release 35, part S;
-- docs/changes/2026-11-08-r35-missed-debit-statement.md). No applied migration is edited.
--
-- The rule (the owner, November 8, 2026): every owner is debited on the 15th; a debit that is missed (failed or returned)
-- comes off the owner's next monthly revenue statement, without anyone doing anything.
-- What was checked, end to end: a debit returned for insufficient funds is retried once (0056); when the retry is returned
-- too, the invoice is in arrears and the next statement takes it (0007, 0021: arrears lines on the car, then from the
-- owner's other cars, the rest carried). The gaps: a debit returned for any other reason (a closed account, a revoked
-- mandate), or for insufficient funds too late for a retry, left the invoice "failed" with its debit paused, and a
-- retry still waiting when the statement was built kept the invoice out of it: no statement took them, an Admin had
-- to act. The fix: when an owner's statement is built (the statements-draft job, 5 days before the payout date, or an
-- Admin), each invoice of that owner still failed and not being debited right now is put in arrears (the waiting retry is
-- cancelled, the owner gets the usual in-arrears email saying it comes off the next payout), so the statement takes it.
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

-- the owner's missed debits, in arrears for the statement; returns how many
create function app.owner_missed_debits_to_statement(p_owner uuid) returns integer
language plpgsql security definer set search_path = public, app as $$
declare
  i owner_invoices;
  v_n integer := 0;
begin
  for i in select x.* from owner_invoices x
            where x.owner_id = p_owner and x.status = 'failed' and x.balance_cents > 0
              and exists (select 1 from owner_debit_attempts a where a.owner_invoice_id = x.id and a.status = 'failed')
              and not exists (select 1 from owner_debit_attempts a where a.owner_invoice_id = x.id and a.status in ('submitting', 'processing'))
              and not exists (select 1 from payments p where p.owner_invoice_id = x.id and p.status = 'pending')
            order by x.billing_date, x.invoice_number
            for update
  loop
    update owner_debit_attempts set status = 'canceled', skip_reason = 'recovered from the revenue statement'
     where owner_invoice_id = i.id and status = 'scheduled';
    perform set_config('app.debit_no_retry', i.id::text, true);
    update owner_invoices set status = 'in_arrears', retry_on = null, debit_on = null where id = i.id;
    perform set_config('app.debit_no_retry', '', true);
    insert into audit_log (action, entity_table, entity_id, before, after)
    values ('owner_missed_debit_to_statement', 'owner_invoices', i.id::text, jsonb_build_object('status', i.status, 'retry_on', i.retry_on, 'auto_debit_paused', i.auto_debit_paused),
            jsonb_build_object('status', 'in_arrears', 'balance_cents', i.balance_cents));
    v_n := v_n + 1;
  end loop;
  return v_n;
end $$;

alter function app.build_owner_statement(uuid, date, uuid) rename to build_owner_statement_pre0871;
create function app.build_owner_statement(p_owner uuid, p_month date, p_by uuid default null) returns uuid
language plpgsql security definer set search_path = public, app as $$
begin
  perform app.owner_missed_debits_to_statement(p_owner);
  return app.build_owner_statement_pre0871(p_owner, p_month, p_by);
end $$;
select pg_temp.copy_grants('app.build_owner_statement(uuid, date, uuid)'::regprocedure, 'app.build_owner_statement_pre0871(uuid, date, uuid)'::regprocedure);

revoke all on function app.owner_missed_debits_to_statement(uuid) from public, anon, authenticated;
grant execute on function app.owner_missed_debits_to_statement(uuid) to service_role;
revoke all on function app.build_owner_statement_pre0871(uuid, date, uuid) from public, anon, authenticated;
grant execute on function app.build_owner_statement_pre0871(uuid, date, uuid) to service_role;
