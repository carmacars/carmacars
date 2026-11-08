-- 0873_r35_no_hst_on_insurance.sql
-- Release 35 (docs/changes/2026-11-08-r35-no-hst-on-insurance.md). The owner, November 8: "don't charge HST on insurance
-- payments". Owner invoice lines for the Insurance Fee (monthly, first month, last month) and the prepaid credit that
-- offsets it carry no HST unless Program settings say otherwise (insurance_fee_hst, off by default). Tracker, install,
-- registration and custom lines keep their HST.
--  1. program_settings.insurance_fee_hst (default false).
--  2. A trigger on owner_invoice_lines: an insurance line (or a prepaid credit) is saved with hst_applies false and no
--     HST while the setting is off, however the line is made (monthly run, upfront invoice, Admin's new invoice, recalc).
--  3. Open invoices nothing has been paid on yet (draft, issued, failed, in arrears; no payment or deduction) lose the
--     HST on their insurance lines now; their totals follow through app.owner_invoice_recalc. The prepaids they made too.
--  4. Invoices already paid or deducted keep what was charged; app.insurance_hst_charged lists them for an Admin to
--     credit (a credit note) or refund. Nothing is refunded by this migration.

alter table program_settings add column if not exists insurance_fee_hst boolean not null default false;
comment on column program_settings.insurance_fee_hst is 'Charge HST on the owner Insurance Fee lines (monthly, first and last month) and their prepaid credit (0873). Off by default: the owner, November 8, 2026.';

create or replace function app.owner_line_insurance_hst() returns trigger
language plpgsql security definer set search_path = public, app as $$
begin
  if new.kind in ('insurance_fee', 'first_month_insurance', 'last_month_insurance', 'prepaid_credit')
     and not coalesce((app.settings()).insurance_fee_hst, false) then
    new.hst_applies := false;
    new.hst_cents := 0;
  end if;
  return new;
end $$;
revoke all on function app.owner_line_insurance_hst() from public;

drop trigger if exists owner_invoice_lines_insurance_hst on owner_invoice_lines;
create trigger owner_invoice_lines_insurance_hst before insert or update on owner_invoice_lines
  for each row execute function app.owner_line_insurance_hst();

-- open invoices with nothing paid yet: the insurance lines lose their HST now (the update fires the trigger above and
-- the existing recalc trigger, so the invoice totals follow)
update owner_invoice_lines l set hst_applies = false, hst_cents = 0
  from owner_invoices i
 where i.id = l.owner_invoice_id
   and i.status in ('draft', 'issued', 'failed', 'in_arrears')
   and i.paid_cents = 0 and i.deducted_cents = 0
   and l.kind in ('insurance_fee', 'first_month_insurance', 'last_month_insurance', 'prepaid_credit')
   and (l.hst_cents <> 0 or l.hst_applies);

update vehicle_prepaids p set hst_cents = 0
  from owner_invoices i
 where i.id = p.source_invoice_id
   and i.status in ('draft', 'issued', 'failed', 'in_arrears')
   and i.paid_cents = 0 and i.deducted_cents = 0
   and p.hst_cents <> 0;

-- what was already charged and paid: for an Admin to credit or refund (Owner money shows it; nothing moves by itself)
create or replace function app.insurance_hst_charged() returns table (owner_invoice_id uuid, invoice_number text, owner_id uuid, status text, hst_cents bigint)
language sql stable security definer set search_path = public, app as $$
  select i.id, i.invoice_number, i.owner_id, i.status, sum(l.hst_cents)::bigint
    from owner_invoices i
    join owner_invoice_lines l on l.owner_invoice_id = i.id
   where l.kind in ('insurance_fee', 'first_month_insurance', 'last_month_insurance', 'prepaid_credit')
     and l.hst_cents <> 0 and i.status <> 'void'
   group by i.id, i.invoice_number, i.owner_id, i.status
   order by i.invoice_number
$$;
revoke all on function app.insurance_hst_charged() from public;
grant execute on function app.insurance_hst_charged() to service_role;

insert into audit_log (actor_user_id, action, entity_table, entity_id, after)
values (null, 'insurance_fee_hst_off', 'program_settings', null, jsonb_build_object('migration', '0873'));
