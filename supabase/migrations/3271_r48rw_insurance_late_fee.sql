-- 3271 (release 48, part RW; docs/changes/2026-11-20-r48-rewards-calendar-notify.md): the owner's Late Fee on unpaid
-- insurance is 5% of the insurance that was not paid on time.
--
-- The owner (Nov 20): the flat owner_late_fee_cents ($50 per vehicle per failed charge) is replaced, for insurance, by
-- owner_insurance_late_fee_bps (500: 5%) of the unpaid Insurance Fee of the invoice.
-- 1. When: the debit of the 15th fails (owner_invoices.status failed; app.owner_invoice_status_effects is patched to call
--    app.owner_late_fee_add), or the invoice is still unpaid the day after its due date (app.job_owner_insurance_late,
--    daily: the due date is due_on, else the debit day of its month).
--    It applies to invoices billed from owner_insurance_late_fee_from (2026-11-20, the day the updated agreement is
--    published); an earlier invoice keeps the flat fee.
-- 2. The fee is its own line on the invoice (kind late_fee: "Late Fee: 5% of the unpaid insurance ($x)"). An invoice with
--    no insurance line keeps the flat owner_late_fee_cents.
-- 3. HST. The Insurance Fee itself carries no HST (insurance_fee_hst false). The Late Fee is a penalty for paying late,
--    not insurance, so it carries HST by default: Program setting owner_insurance_late_fee_hst (on). The check that a
--    late_fee line never has HST is dropped. FOR THE ACCOUNTANT: whether a late-payment charge on an exempt supply is
--    itself exempt (a financial penalty) is a tax question; turn the setting off if the accountant says so.
-- 4. Both the unpaid insurance and the fee are deducted from the next statement by themselves: an invoice past its due
--    date is handed to the statements (collect_by payout); after a failed debit the existing retry runs first and an
--    invoice in arrears is deducted as before. On the statement they are two lines: "Invoice INV-n, paid from statement"
--    and "Late Fee, invoice INV-n" (app.owner_statement_take_fees and the first deduction of app.build_owner_statement
--    are patched).
-- 5. The owner is told: owner_insurance_late_fee (branded email, in-app notice and phone alert) when the fee is applied,
--    and a reminder owner_insurance_late_reminder_days (3) before the due date while the invoice is unpaid.
-- 6. The agreement: Schedule B's Late Fee row and 4.4 are updated (docs/source/v2_enrollment.md) and published as
--    owner_agreement owner-v4-r48rw to accept in the "We've updated our terms" box (0721, 3198): no signing again.
-- No applied migration is edited: functions are patched from their current definition.
set local check_function_bodies = off;

create function pg_temp.patch_fn(p_sig regprocedure, p_old text, p_new text) returns void
language plpgsql as $$
declare d text := pg_get_functiondef(p_sig);
begin
  if position(p_old in d) = 0 then raise exception '3271: the text to change was not found in %: %', p_sig, left(p_old, 160); end if;
  execute replace(d, p_old, p_new);
end $$;

alter table program_settings
  add column if not exists owner_insurance_late_fee_bps integer not null default 500 check (owner_insurance_late_fee_bps between 0 and 5000),
  add column if not exists owner_insurance_late_fee_from date not null default date '2026-11-20',
  add column if not exists owner_insurance_late_fee_hst boolean not null default true,
  add column if not exists owner_insurance_late_reminder_days integer not null default 3 check (owner_insurance_late_reminder_days between 0 and 14);
comment on column program_settings.owner_insurance_late_fee_bps is 'Owner Late Fee on unpaid insurance (3271): basis points of the unpaid Insurance Fee of an invoice whose debit failed or that is past its due date (500: 5%). Replaces the flat owner_late_fee_cents for invoices with an insurance line.';
comment on column program_settings.owner_insurance_late_fee_from is 'The Late Fee on unpaid insurance (3271) applies to invoices due (a monthly invoice: its debit day) on or after this date (the day the updated owner agreement was published); an earlier invoice keeps the flat Late Fee.';
comment on column program_settings.owner_insurance_late_fee_hst is 'Whether the Late Fee on unpaid insurance carries HST (3271; on: it is a penalty, not insurance). The Insurance Fee itself follows insurance_fee_hst.';
comment on column program_settings.owner_insurance_late_reminder_days is 'Days before an insurance invoice''s due date that the owner is reminded a Late Fee is added if it is not paid on time (3271; 0: no reminder).';

alter table owner_invoice_lines drop constraint if exists owner_invoice_lines_check1;
alter table owner_invoices add column if not exists late_fee_reminded_at timestamptz;
comment on column owner_invoices.late_fee_reminded_at is 'When the owner was reminded, before the due date, that a Late Fee is added if this invoice is not paid on time (3271).';

-- the unpaid insurance of an invoice (what the Late Fee is a share of)
create function app.owner_invoice_unpaid_insurance(p_invoice uuid) returns bigint
language sql stable security definer set search_path = public, app as $$
  select least(greatest(i.balance_cents - i.late_fee_cents, 0),
               coalesce((select sum(l.amount_cents) from owner_invoice_lines l
                          where l.owner_invoice_id = i.id and l.kind in ('insurance_fee', 'first_month_insurance', 'last_month_insurance')), 0))
    from owner_invoices i where i.id = p_invoice
$$;

create function app.owner_insurance_late_notify(p_invoice uuid, p_state text) returns void
language plpgsql security definer set search_path = public, app as $$
declare
  i owner_invoices;
  s program_settings := app.settings();
  v_first text;
  v_ins bigint := app.owner_invoice_unpaid_insurance(p_invoice);
  v_fee bigint;
  v_hst bigint;
  v_due date;
  v_pct text := trim(to_char(s.owner_insurance_late_fee_bps / 100.0, 'FM990.##'), '.') || '%';
begin
  select * into i from owner_invoices where id = p_invoice;
  if i.id is null then return; end if;
  select coalesce(nullif(split_part(btrim(coalesce(u.full_name, o.legal_name, '')), ' ', 1), ''), 'there') into v_first
    from owners o left join users u on u.id = o.user_id where o.id = i.owner_id;
  v_due := coalesce(i.due_on, i.debit_on, case when i.period_month is not null then app.owner_debit_date(i.period_month) end, i.billing_date);
  if p_state = 'applied' then
    select coalesce(sum(l.amount_cents), 0), coalesce(sum(l.hst_cents), 0) into v_fee, v_hst from owner_invoice_lines l where l.owner_invoice_id = i.id and l.kind = 'late_fee';
    perform app.emit_event('owner_insurance_late_fee', 'owner_invoice', i.id, jsonb_build_object('owner_id', i.owner_id, 'vehicle_id', i.vehicle_id,
      'first_name', v_first, 'invoice_number', i.invoice_number, 'vehicle_name', app.vehicle_name(i.vehicle_id), 'applied', true,
      'late_title', format('A Late Fee of %s was added to invoice %s', app.fmt_money(v_fee + v_hst), i.invoice_number),
      'late_text', format('The insurance for your %s was not paid on time. The Late Fee is %s of the unpaid insurance of %s: %s%s.',
        app.vehicle_name(i.vehicle_id), v_pct, app.fmt_money(v_ins), app.fmt_money(v_fee), case when v_hst > 0 then ' plus ' || app.fmt_money(v_hst) || ' HST' else '' end),
      'late_how', 'The unpaid insurance and the Late Fee are deducted from your next statement, as two separate lines. There is nothing to do. You can also pay the invoice now from its page.',
      'insurance_amount', app.fmt_money(v_ins), 'late_fee_amount', app.fmt_money(v_fee + v_hst), 'balance', app.fmt_money(greatest(i.balance_cents, 0))),
      'owner_insurance_late_fee:' || i.id || ':applied');
  else
    v_fee := round(v_ins * s.owner_insurance_late_fee_bps / 10000.0);
    perform app.emit_event('owner_insurance_late_fee', 'owner_invoice', i.id, jsonb_build_object('owner_id', i.owner_id, 'vehicle_id', i.vehicle_id,
      'first_name', v_first, 'invoice_number', i.invoice_number, 'vehicle_name', app.vehicle_name(i.vehicle_id), 'applied', false,
      'late_title', format('Your insurance of %s is due %s', app.fmt_money(v_ins), app.fmt_day(v_due)),
      'late_text', format('Invoice %s for your %s is not paid yet. If the insurance is not paid on time, a Late Fee of %s of the unpaid insurance (%s%s) is added.',
        i.invoice_number, app.vehicle_name(i.vehicle_id), v_pct, app.fmt_money(v_fee), case when s.owner_insurance_late_fee_hst then ' plus HST' else '' end),
      'late_how', case when app.owner_debit_mandate(i.owner_id) is not null
        then 'Your pre-authorized debit takes it on the due date: please make sure the funds are in the account. You can also pay it now from the invoice page.'
        else 'Please pay it from the invoice page before the due date, or set up your pre-authorized debit under Account, Banking.' end,
      'insurance_amount', app.fmt_money(v_ins), 'late_fee_amount', app.fmt_money(v_fee), 'balance', app.fmt_money(greatest(i.balance_cents, 0))),
      'owner_insurance_late_fee:' || i.id || ':reminder');
  end if;
end $$;

-- the Late Fee of an invoice, once: a share of the unpaid insurance, or the flat fee when the invoice has no insurance
create function app.owner_late_fee_add(p_invoice uuid) returns bigint
language plpgsql security definer set search_path = public, app as $$
declare
  i owner_invoices;
  s program_settings;
  v_ins bigint;
  v_fee bigint;
  v_hst bigint := 0;
begin
  select * into i from owner_invoices where id = p_invoice;
  if i.id is null or exists (select 1 from owner_invoice_lines l where l.owner_invoice_id = i.id and l.kind = 'late_fee') then return 0; end if;
  s := app.settings(coalesce(i.billing_date, app.today()));
  v_ins := case when coalesce(case when i.period_month is not null then app.owner_debit_date(i.period_month) end, i.due_on, i.billing_date) >= s.owner_insurance_late_fee_from and s.owner_insurance_late_fee_bps > 0 then app.owner_invoice_unpaid_insurance(i.id) else 0 end;
  if coalesce(v_ins, 0) <= 0 then
    -- no insurance on it: the flat Late Fee, as before (the guard of 0204 drops it when the return was not for insufficient funds)
    insert into owner_invoice_lines (owner_invoice_id, kind, description, amount_cents, hst_applies)
    values (i.id, 'late_fee', 'Late Fee: missed payment', s.owner_late_fee_cents, false);
    return s.owner_late_fee_cents;
  end if;
  if coalesce(current_setting('app.debit_no_late_fee', true), '') = i.id::text then return 0; end if;
  v_fee := round(v_ins * s.owner_insurance_late_fee_bps / 10000.0);
  if v_fee <= 0 then return 0; end if;
  if s.owner_insurance_late_fee_hst then v_hst := round(v_fee * s.hst_bps / 10000.0); end if;
  insert into owner_invoice_lines (owner_invoice_id, kind, description, amount_cents, hst_applies, hst_cents, note)
  values (i.id, 'late_fee', format('Late Fee: %s%% of the unpaid insurance (%s)', trim(to_char(s.owner_insurance_late_fee_bps / 100.0, 'FM990.##'), '.'), app.fmt_money(v_ins)),
          v_fee, v_hst > 0, v_hst, 'The insurance was not paid on time.');
  perform app.owner_insurance_late_notify(i.id, 'applied');
  return v_fee + v_hst;
end $$;

select pg_temp.patch_fn('app.owner_invoice_status_effects()'::regprocedure,
$o$    insert into owner_invoice_lines (owner_invoice_id, kind, description, amount_cents, hst_applies)
    values (new.id, 'late_fee', 'Late Fee: missed payment', v_set.owner_late_fee_cents, false);$o$,
$n$    perform app.owner_late_fee_add(new.id);$n$);

-- daily: the reminder before the due date, and the fee the day after it
create function app.job_owner_insurance_late(p_now timestamptz default now()) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  s program_settings := app.settings();
  i owner_invoices;
  v_today date := app.local_date(p_now);
  v_due date;
  v_reminded integer := 0;
  v_applied integer := 0;
begin
  if s.owner_insurance_late_fee_bps <= 0 then return jsonb_build_object('off', true); end if;
  for i in select x.* from owner_invoices x
            where x.status = 'issued' and x.balance_cents > 0 and x.kind <> 'credit_note' and x.owner_use_booking_id is null
              and coalesce(case when x.period_month is not null then app.owner_debit_date(x.period_month) end, x.due_on, x.billing_date) >= s.owner_insurance_late_fee_from
              and app.owner_debit_block(x.id) is null
              and exists (select 1 from owner_invoice_lines l where l.owner_invoice_id = x.id and l.kind in ('insurance_fee', 'first_month_insurance', 'last_month_insurance') and l.amount_cents > 0)
              and not exists (select 1 from owner_invoice_lines l where l.owner_invoice_id = x.id and l.kind = 'late_fee')
              and not exists (select 1 from owner_debit_attempts a where a.owner_invoice_id = x.id and a.status in ('submitting', 'processing'))
            for update skip locked loop
    v_due := coalesce(i.due_on, i.debit_on, case when i.period_month is not null then app.owner_debit_date(i.period_month) end, i.billing_date);
    if v_today > v_due and not exists (select 1 from owner_debit_attempts a where a.owner_invoice_id = i.id and a.status = 'scheduled' and a.debit_on >= v_today) then
      if app.owner_late_fee_add(i.id) > 0 then
        update owner_debit_attempts set status = 'canceled', skip_reason = 'past due: deducted from the statement' where owner_invoice_id = i.id and status = 'scheduled';
        update owner_invoices set collect_by = 'payout', debit_on = null where id = i.id;
        insert into audit_log (action, entity_table, entity_id, after)
        values ('owner_insurance_late_fee', 'owner_invoices', i.id::text, jsonb_build_object('due', v_due, 'bps', s.owner_insurance_late_fee_bps));
        v_applied := v_applied + 1;
      end if;
    elsif s.owner_insurance_late_reminder_days > 0 and i.late_fee_reminded_at is null and v_today <= v_due and v_today >= v_due - s.owner_insurance_late_reminder_days then
      update owner_invoices set late_fee_reminded_at = p_now where id = i.id;
      perform app.owner_insurance_late_notify(i.id, 'reminder');
      v_reminded := v_reminded + 1;
    end if;
  end loop;
  return jsonb_build_object('reminded', v_reminded, 'applied', v_applied);
end $$;

-- the statement: the unpaid amount and the Late Fee as two lines
select pg_temp.patch_fn('app.owner_statement_take_fees(uuid)'::regprocedure,
$o$      insert into owner_statement_lines (owner_statement_id, vehicle_id, line_type, description, owner_invoice_id, fee_cents, late_fee_cents, amount_cents)
      values (st.id, sv.vehicle_id, 'fees_deducted', 'Invoice ' || inv.invoice_number || ', paid from statement', inv.id, v_fee, v_take - v_fee, -v_take);$o$,
$n$      if v_fee > 0 or v_take - v_fee <= 0 then
        insert into owner_statement_lines (owner_statement_id, vehicle_id, line_type, description, owner_invoice_id, fee_cents, late_fee_cents, amount_cents)
        values (st.id, sv.vehicle_id, 'fees_deducted', 'Invoice ' || inv.invoice_number || ', paid from statement', inv.id, v_fee, 0, -v_fee);
      end if;
      if v_take - v_fee > 0 then
        insert into owner_statement_lines (owner_statement_id, vehicle_id, line_type, description, owner_invoice_id, fee_cents, late_fee_cents, amount_cents)
        values (st.id, sv.vehicle_id, 'fees_deducted', 'Late Fee, invoice ' || inv.invoice_number, inv.id, 0, v_take - v_fee, -(v_take - v_fee));
      end if;$n$);
select pg_temp.patch_fn('app.build_owner_statement_0025(uuid, date, uuid)'::regprocedure,
$o$        values (v_id, r.vehicle_id, 'fees_deducted', 'Invoice ' || inv.invoice_number, inv.id, v_fee_part, v_late_part, -v_take);$o$,
$n$        values (v_id, r.vehicle_id, 'fees_deducted', 'Invoice ' || inv.invoice_number, inv.id, v_fee_part, 0, -v_fee_part);
        if v_late_part > 0 then
          insert into owner_statement_lines (owner_statement_id, vehicle_id, line_type, description, owner_invoice_id, fee_cents, late_fee_cents, amount_cents)
          values (v_id, r.vehicle_id, 'fees_deducted', 'Late Fee, invoice ' || inv.invoice_number, inv.id, 0, v_late_part, -v_late_part);
        end if;$n$);

-- the rule in words, where the owner reads it (Account, Banking; the debit notice)
create or replace function app.owner_late_fee_rule() returns text
language sql stable security definer set search_path = public, app as $$
  select case when s.owner_debit_max_attempts > 1
    then format('If your insurance is not paid on time (your bank returns the automatic debit of an invoice for insufficient funds, or the invoice is unpaid after its due date), we add a Late Fee of %s%% of the unpaid insurance%s to that invoice once and try a returned debit again for the original amount within 30 days, as section 4.4 of your Enrollment Agreement sets out. The unpaid insurance and the Late Fee are deducted from your next payout as two lines.',
                trim(to_char(s.owner_insurance_late_fee_bps / 100.0, 'FM990.##'), '.'), case when s.owner_insurance_late_fee_hst then ', plus HST,' else '' end)
    else format('If your insurance is not paid on time (your bank returns the automatic debit of an invoice for insufficient funds, or the invoice is unpaid after its due date), we add a Late Fee of %s%% of the unpaid insurance%s to that invoice once, as section 4.4 of your Enrollment Agreement sets out. The Late Fee and the amount owed are deducted from your next payout.',
                trim(to_char(s.owner_insurance_late_fee_bps / 100.0, 'FM990.##'), '.'), case when s.owner_insurance_late_fee_hst then ', plus HST,' else '' end) end
    from app.settings() s
$$;

insert into terms_versions (doc_key, version, title, summary, body, body_sha256, requires_acceptance, published_by)
select x.doc_key, x.version, x.title, x.summary, x.body, encode(sha256(convert_to(x.body, 'UTF8')), 'hex'), true, app.system_admin()
  from (values
  ('owner_agreement', 'owner-v4-r48rw', 'Owner program agreement',
   'The Late Fee on unpaid insurance is now 5% of the insurance that was not paid on time (it was $50 per vehicle), plus HST; the unpaid insurance and the Late Fee are deducted from your next statement as two lines. Charges during a booking you make of your own car are due at once: charged to your payment method on file, or invoiced, and deducted from your next statement if still unpaid.',
   E'4.4 If the Insurance Fee of an invoice is not paid on time (an automatic pre-authorized debit is returned, or the invoice is unpaid after its due date), CarmaCars adds the Late Fee to that invoice once: 5% of the unpaid Insurance Fee, plus HST on the Late Fee. CarmaCars may re-present a returned debit once, for the original amount, within 30 days. The unpaid Insurance Fee and the Late Fee are deducted from the Owner''s next payout and shown as separate lines on the statement. An invoice with no Insurance Fee on it has the flat Late Fee of the Fee Schedule.\n\n9.3 (added) The charges of an Owner Booking are due when billed. CarmaCars charges the Owner''s payment method on file at once (a card, otherwise the pre-authorized debit, without waiting for the Billing Date); if there is none or the charge fails, CarmaCars invoices the Owner, payable at once; an invoice still unpaid 7 days after it is issued, or at the next statement cut-off if that is sooner, is deducted from the Owner''s next payout.\n\nFee Schedule: Late Fee, 5% of the unpaid Insurance Fee per invoice, plus HST (from November 20, 2026); $50 per Vehicle per failed charge for an invoice with no Insurance Fee.')
  ) x(doc_key, version, title, summary, body)
on conflict (doc_key, version) do nothing;

insert into notification_catalogue (code, audience, category, subject, preheader, timing, trigger_text, link_path, variables, template_html, template_text, emitted_by, pref_type, priority, push_topic)
values ('owner_insurance_late_fee', 'owner', 'transactional', '{{late_title}}', '{{late_how}}', 'Once before the due date (reminder) and once when the Late Fee is added',
        'Owner Late Fee on unpaid insurance (3271): a reminder a few days before an unpaid insurance invoice is due, and the notice when the Late Fee (5% of the unpaid insurance) is added because the debit failed or the invoice is past its due date.',
        '/owner/invoices/{{invoice_number}}',
        '[{"name":"first_name","type":"string"},{"name":"late_title","type":"string"},{"name":"late_text","type":"string"},{"name":"late_how","type":"string"},{"name":"invoice_number","type":"string"},{"name":"vehicle_name","type":"string"},{"name":"insurance_amount","type":"string"},{"name":"late_fee_amount","type":"string"},{"name":"balance","type":"string"},{"name":"applied","type":"boolean"}]'::jsonb,
        'templates/owner_insurance_late_fee.html', 'templates/owner_insurance_late_fee.txt', 'app.owner_insurance_late_notify (3271)', 'charges', 1, 'payments')
on conflict (code) do update set emitted_by = excluded.emitted_by, pref_type = excluded.pref_type, priority = excluded.priority, push_topic = excluded.push_topic;

insert into sms_templates (code, label, body, urgent, sort_order) values
  ('owner_insurance_late_fee', 'Late Fee on unpaid insurance', 'CarmaCars: {{late_title}}. {{link}}', false, 412)
on conflict (code) do nothing;

do $$
begin
  if exists (select 1 from pg_extension where extname = 'pg_cron') then
    perform cron.schedule('carmacars-owner-insurance-late', '20 13 * * *', $q$select app.job_owner_insurance_late()$q$);
  end if;
end $$;

do $$
declare f record;
begin
  for f in select p.oid::regprocedure as sig from pg_proc p join pg_namespace n on n.oid = p.pronamespace
            where n.nspname = 'app' and p.proname in ('owner_invoice_unpaid_insurance', 'owner_insurance_late_notify', 'owner_late_fee_add', 'job_owner_insurance_late') loop
    execute format('revoke all on function %s from public, anon, authenticated', f.sig);
    execute format('grant execute on function %s to service_role', f.sig);
  end loop;
end $$;
