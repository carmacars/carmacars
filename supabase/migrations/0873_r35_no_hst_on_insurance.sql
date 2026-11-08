-- 0873_r35_no_hst_on_insurance.sql
-- Release 35 (docs/changes/2026-11-08-r35-no-hst-on-insurance.md). The owner, November 8: "don't charge HST on insurance
-- payments" and "All the registration cost per car were also not HST applicable either". Owner invoice lines for the
-- Insurance Fee (monthly, first month, last month), the prepaid credit that offsets it and the Registration Fee carry no
-- HST unless Program settings say otherwise (insurance_fee_hst, off by default). Tracker, install and custom lines keep
-- their HST. "Nobody has paid HST": the payments recorded by hand were the amounts without HST.
--  1. program_settings.insurance_fee_hst (default false).
--  2. A trigger on owner_invoice_lines: an insurance line (or a prepaid credit) is saved with hst_applies false and no
--     HST while the setting is off, however the line is made (monthly run, upfront invoice, Admin's new invoice, recalc).
--  3. Every invoice that is not void loses the HST on those lines now; totals follow through app.owner_invoice_recalc.
--     The prepaids they made too.
--     Lines typed by hand (custom, adjustment) that are the Insurance Fee, registration or plates count too.
--  4. A payment recorded by hand (manual_payments) that paid the old total is corrected to the new total (the owner paid
--     the amount without HST): manual payment, payment and the invoice's paid amount, audited. Payments through the
--     processor or taken from a payout are not touched; app.insurance_hst_charged lists anything left for an Admin.

alter table program_settings add column if not exists insurance_fee_hst boolean not null default false;
comment on column program_settings.insurance_fee_hst is 'Charge HST on the owner Insurance Fee lines (monthly, first and last month) and their prepaid credit (0873). Off by default: the owner, November 8, 2026.';

-- the lines that carry no HST: by kind, and (for lines typed by hand as custom or adjustment) by what they say
create or replace function app.owner_line_no_hst(p_kind text, p_description text) returns boolean
language sql immutable set search_path = public, app as $$
  select p_kind in ('insurance_fee', 'first_month_insurance', 'last_month_insurance', 'prepaid_credit', 'registration_fee')
      or (p_kind in ('custom', 'adjustment')
          and (coalesce(p_description, '') ~* 'insurance fee|registration|plates|taxes and plates'))
$$;
revoke all on function app.owner_line_no_hst(text, text) from public;

create or replace function app.owner_line_insurance_hst() returns trigger
language plpgsql security definer set search_path = public, app as $$
begin
  if app.owner_line_no_hst(new.kind, new.description)
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

-- every invoice that is not void: the old totals first, then the lines lose their HST (the trigger above and the recalc
-- trigger follow), then a payment recorded by hand that paid the old total is brought to the new total
create temporary table t0873 on commit drop as
  select i.id, i.total_cents as old_total, i.paid_cents as old_paid
    from owner_invoices i
   where i.status <> 'void'
     and exists (select 1 from owner_invoice_lines l where l.owner_invoice_id = i.id and l.hst_cents <> 0
                   and app.owner_line_no_hst(l.kind, l.description));

update owner_invoice_lines l set hst_applies = false, hst_cents = 0
  from t0873 t
 where l.owner_invoice_id = t.id
   and app.owner_line_no_hst(l.kind, l.description);

update vehicle_prepaids p set hst_cents = 0 where p.hst_cents <> 0;

do $$
declare r record; v_diff bigint; m record;
begin
  for r in select t.id, t.old_total, t.old_paid, i.total_cents as new_total, i.invoice_number
             from t0873 t join owner_invoices i on i.id = t.id
            where t.old_paid = t.old_total and i.total_cents < t.old_total loop
    v_diff := r.old_total - r.new_total;
    -- the largest hand-recorded payment on the invoice absorbs the difference (one payment each in practice)
    select mp.* into m from manual_payments mp
     where mp.owner_invoice_id = r.id and mp.voided_at is null and mp.amount_cents > v_diff
     order by mp.amount_cents desc limit 1;
    if m.id is null then continue; end if;
    update manual_payments set amount_cents = amount_cents - v_diff,
           note = concat_ws(' ', nullif(note, ''), format('(0873: %s HST removed, no HST on the Insurance or Registration Fee)', app.fmt_money(v_diff)))
     where id = m.id;
    update payments set amount_cents = amount_cents - v_diff where id = m.payment_id;
    update owner_invoices set paid_cents = paid_cents - v_diff where id = r.id;
    insert into audit_log (actor_user_id, action, entity_table, entity_id, before, after)
    values (null, 'owner_payment_hst_corrected', 'owner_invoices', r.id::text,
            jsonb_build_object('invoice', r.invoice_number, 'total_cents', r.old_total, 'paid_cents', r.old_paid),
            jsonb_build_object('total_cents', r.new_total, 'paid_cents', r.old_paid - v_diff, 'migration', '0873'));
  end loop;
end $$;

-- what was already charged and paid: for an Admin to credit or refund (Owner money shows it; nothing moves by itself)
create or replace function app.insurance_hst_charged() returns table (owner_invoice_id uuid, invoice_number text, owner_id uuid, status text, hst_cents bigint)
language sql stable security definer set search_path = public, app as $$
  select i.id, i.invoice_number, i.owner_id, i.status, sum(l.hst_cents)::bigint
    from owner_invoices i
    join owner_invoice_lines l on l.owner_invoice_id = i.id
   where app.owner_line_no_hst(l.kind, l.description)
     and l.hst_cents <> 0 and i.status <> 'void'
   group by i.id, i.invoice_number, i.owner_id, i.status
   order by i.invoice_number
$$;
revoke all on function app.insurance_hst_charged() from public;
grant execute on function app.insurance_hst_charged() to service_role;

insert into audit_log (actor_user_id, action, entity_table, entity_id, after)
values (null, 'insurance_fee_hst_off', 'program_settings', null, jsonb_build_object('migration', '0873'));
