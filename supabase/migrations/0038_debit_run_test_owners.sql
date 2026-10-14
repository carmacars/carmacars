-- 0038_debit_run_test_owners.sql
-- Three fixes to 0037 found by its live run (docs/changes/2026-10-14-owner-debit.md, section 7):
--   1. The debit run's summary (staff_owner_debit_run) is about a run, not an owner, so 0037's test-owner rule did
--      not apply: a run of test owners only was emailed to every Admin. A run whose debits are all test owners'
--      now goes only to the verification accounts, as every other staff notice about a test owner does.
--   2. A debit sent again after a passing error kept that error's message once Stripe accepted it.
--   3. A webhook that came before the run recorded the PaymentIntent was dropped (below).
--   4. A failed invoice whose retry could not be sent was never noticed again (below).
-- No earlier migration is edited.
set local check_function_bodies = off;

-- Whether an event concerns test data only: its owner is a test owner, or it is a debit run whose debits are all
-- test owners'.
create or replace function app.event_is_test(p_event app_events) returns boolean
language sql stable security definer set search_path = public, app as $$
  select case
    when p_event.entity = 'owner_debit_run' then
      exists (select 1 from owner_debit_attempts a where a.run_id = p_event.entity_id)
      and not exists (select 1 from owner_debit_attempts a join owners o on o.id = a.owner_id where a.run_id = p_event.entity_id and not o.is_test)
    else coalesce((select o.is_test from owners o where o.id = app.event_owner(p_event)), false)
  end
$$;

create or replace function app.notification_recipients(p_event app_events, p_c notification_catalogue)
returns table (audience text, user_id uuid, email text, name text, renter_id uuid, owner_id uuid, immediate boolean)
language plpgsql stable security definer set search_path = public, app as $$
begin
  if p_c.audience not like 'staff_%' or not app.event_is_test(p_event) then
    return query select * from app.notification_recipients_0032(p_event, p_c);
    return;
  end if;
  return query select r.audience, r.user_id, r.email, r.name, r.renter_id, r.owner_id, true
                 from app.notification_recipients_0032(p_event, p_c) r
                where lower(coalesce(r.email, '')) like 'verify-%@carmacars.ca';
end $$;

-- 0037's submitted, with the earlier passing error cleared once Stripe accepts the debit.
alter function app.owner_debit_submitted(uuid, jsonb) rename to owner_debit_submitted_0037;
create or replace function app.owner_debit_submitted(p_attempt uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  r jsonb := app.owner_debit_submitted_0037(p_attempt, p);
begin
  update owner_debit_attempts set failure_code = null, failure_message = null
   where id = p_attempt and status in ('processing', 'succeeded') and failure_code is not null;
  return r;
end $$;

revoke execute on function app.event_is_test(app_events), app.owner_debit_submitted(uuid, jsonb) from public, anon, authenticated;
grant execute on function app.event_is_test(app_events), app.owner_debit_submitted(uuid, jsonb) to service_role;

-- 3. A webhook that comes before the debit run has recorded the PaymentIntent (Stripe can answer within seconds) is
--    no longer lost: with the attempt from the PaymentIntent's metadata, the submission is recorded first, then the
--    result.
alter function app.owner_debit_result(text, jsonb) rename to owner_debit_result_0037;
create or replace function app.owner_debit_result(p_intent text, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  v_attempt uuid := nullif(p ->> 'attempt_id', '')::uuid;
begin
  if v_attempt is not null
     and not exists (select 1 from owner_debit_attempts a where a.processor_intent_id = p_intent)
     and exists (select 1 from owner_debit_attempts a where a.id = v_attempt and a.status = 'submitting' and a.processor_intent_id is null) then
    return app.owner_debit_submitted(v_attempt, p || jsonb_build_object('intent_id', p_intent));
  end if;
  return app.owner_debit_result_0037(p_intent, p);
end $$;
revoke execute on function app.owner_debit_result(text, jsonb) from public, anon, authenticated;
grant execute on function app.owner_debit_result(text, jsonb) to service_role;

-- 4. A failed invoice whose retry could not be sent (no mandate, paused) is listed on the next notice again, like an
--    issued one; its returned debits still count towards owner_debit_max_attempts.
create or replace function app.owner_debit_candidates(p_owner uuid, p_debit_on date) returns setof owner_invoices
language sql stable security definer set search_path = public, app as $$
  select i.* from owner_invoices i
   where i.owner_id = p_owner and i.status in ('issued', 'failed') and i.balance_cents > 0 and i.billing_date <= p_debit_on
     and app.owner_debit_block(i.id) is null
     and not exists (select 1 from owner_debit_attempts a where a.owner_invoice_id = i.id and a.status in ('scheduled', 'submitting', 'processing'))
   order by i.billing_date, i.invoice_number
$$;

-- and the notice job looks at those owners too (0037's job, with failed invoices in its owner list)
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
                where i.status in ('issued', 'failed') and i.balance_cents > 0 and i.billing_date <= v_debit and not o.auto_debit_paused
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
