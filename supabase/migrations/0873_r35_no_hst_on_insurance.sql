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
grant execute on function app.owner_line_no_hst(text, text) to service_role;

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
grant execute on function app.owner_line_insurance_hst() to service_role;

drop trigger if exists owner_invoice_lines_insurance_hst on owner_invoice_lines;
create trigger owner_invoice_lines_insurance_hst before insert or update on owner_invoice_lines
  for each row execute function app.owner_line_insurance_hst();

-- 0067's guard (an issued invoice's lines never change) lets the one-time corrections of 0873 and 0874 through, and
-- nothing else: they set app.owner_line_correction for their own statements only
create or replace function app.owner_invoice_lines_draft_only() returns trigger
language plpgsql security definer set search_path = public, app as $$
declare
  v_status text;
begin
  if coalesce(current_setting('app.owner_line_correction', true), '') = 'on' then
    return case when tg_op = 'DELETE' then old else new end;
  end if;
  select status into v_status from owner_invoices where id = old.owner_invoice_id;
  if v_status is not null and v_status <> 'draft' then
    raise exception 'This invoice is %: its lines cannot change. Void it with a reason and issue a corrected one.', replace(v_status, '_', ' ') using errcode = '23514';
  end if;
  return case when tg_op = 'DELETE' then old else new end;
end $$;

-- the one-time correction, as a function so the tests can run it on their own fixtures: every invoice that is not void
-- loses the HST on those lines. A payment recorded by hand that paid the old total is lowered first (an invoice may
-- never be paid past its total), then the lines change (issued invoices are otherwise never edited: 0067's guard is
-- let through for this correction only), then the prepaid months lose their HST. Returns the invoices corrected.
create or replace function app.r35_remove_owner_hst(p_owner uuid default null) returns integer
language plpgsql security definer set search_path = public, app as $$
declare r record; m record; v_n integer := 0;
begin
  for r in
    select i.id, i.invoice_number, i.total_cents as old_total, i.paid_cents as old_paid,
           (select sum(l.hst_cents) from owner_invoice_lines l
             where l.owner_invoice_id = i.id and l.hst_cents <> 0 and app.owner_line_no_hst(l.kind, l.description))::bigint as diff
      from owner_invoices i
     where i.status <> 'void' and (p_owner is null or i.owner_id = p_owner)
       and exists (select 1 from owner_invoice_lines l where l.owner_invoice_id = i.id and l.hst_cents <> 0
                     and app.owner_line_no_hst(l.kind, l.description))
  loop
    if r.old_paid = r.old_total and r.old_paid > 0 then
      -- the largest hand-recorded payment absorbs the difference (one payment each in practice)
      m := null;
      select mp.* into m from manual_payments mp
       where mp.owner_invoice_id = r.id and mp.voided_at is null and mp.amount_cents > r.diff
       order by mp.amount_cents desc limit 1;
      if m.id is not null then
        update manual_payments set amount_cents = amount_cents - r.diff,
               note = concat_ws(' ', nullif(note, ''), format('(0873: %s HST removed; no HST on the Insurance or Registration Fee)', app.fmt_money(r.diff)))
         where id = m.id;
        update payments set amount_cents = amount_cents - r.diff where id = m.payment_id;
        update owner_invoices set paid_cents = paid_cents - r.diff where id = r.id;
        insert into audit_log (actor_user_id, action, entity_table, entity_id, before, after)
        values (null, 'owner_payment_hst_corrected', 'owner_invoices', r.id::text,
                jsonb_build_object('invoice', r.invoice_number, 'total_cents', r.old_total, 'paid_cents', r.old_paid),
                jsonb_build_object('total_cents', r.old_total - r.diff, 'paid_cents', r.old_paid - r.diff, 'migration', '0873'));
      end if;
    end if;
    -- an invoice paid past its new total (by card, from a payout) keeps its lines as they are, for an Admin
    if exists (select 1 from owner_invoices i where i.id = r.id and i.paid_cents + i.deducted_cents <= r.old_total - r.diff) then
      perform set_config('app.owner_line_correction', 'on', true);
      update owner_invoice_lines l set hst_applies = false, hst_cents = 0
       where l.owner_invoice_id = r.id and app.owner_line_no_hst(l.kind, l.description);
      perform set_config('app.owner_line_correction', '', true);
      v_n := v_n + 1;
    end if;
  end loop;
  update vehicle_prepaids p set hst_cents = 0 where p.hst_cents <> 0 and (p_owner is null or p.owner_id = p_owner);
  return v_n;
end $$;
revoke all on function app.r35_remove_owner_hst(uuid) from public;
grant execute on function app.r35_remove_owner_hst(uuid) to service_role;

select app.r35_remove_owner_hst();

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
