-- 0874_r35_last_month_one_and_half.sql
-- Release 35 (docs/changes/2026-11-08-r35-no-hst-on-insurance.md). The owner, November 8, on an owner who paid 2.5
-- months up front: "not just first and last. 1.5 months for last". Such a prepayment was entered as the first and last
-- month (one month each) on the upfront invoice plus a separate "Insurance Fee, half of <month>" line on another
-- invoice. It is one first month and a last month of 1.5 months: the half month moves into the last month's line of
-- the upfront invoice (quantity 1.5), the prepaid last month grows by it, and the hand-recorded payments move with it,
-- so each invoice is still paid in full and the owner's total paid is unchanged. Runs after 0873 (no HST on either).
-- SCHEMA_MARKER 0874. No applied migration is edited.

create or replace function app.r35_last_month_one_and_half(p_owner uuid default null) returns integer
language plpgsql security definer set search_path = public, app as $$
declare r record; mc record; mu record; v_n integer := 0;
begin
  for r in
    select h.id as half_id, h.amount_cents as half, c.id as c_id, c.invoice_number as c_no,
           u.id as u_id, u.invoice_number as u_no, ll.id as last_id, ll.amount_cents as last_amount, c.vehicle_id
      from owner_invoice_lines h
      join owner_invoices c on c.id = h.owner_invoice_id
      join owner_invoices u on u.vehicle_id = c.vehicle_id and u.id <> c.id and u.kind = 'upfront' and u.status = 'paid'
      join owner_invoice_lines ll on ll.owner_invoice_id = u.id and ll.kind = 'last_month_insurance' and ll.quantity = 1
     where h.kind in ('insurance_fee', 'custom', 'adjustment')
       and h.description ilike 'Insurance Fee, half of %'
       and h.hst_cents = 0 and ll.hst_cents = 0
       and c.status = 'paid' and c.paid_cents = c.total_cents and u.paid_cents = u.total_cents
       and h.amount_cents * 2 = ll.amount_cents
       and (p_owner is null or c.owner_id = p_owner)
  loop
    mc := null; mu := null;
    select mp.* into mc from manual_payments mp where mp.owner_invoice_id = r.c_id and mp.voided_at is null and mp.amount_cents > r.half
     order by mp.amount_cents desc limit 1;
    select mp.* into mu from manual_payments mp where mp.owner_invoice_id = r.u_id and mp.voided_at is null
     order by mp.amount_cents desc limit 1;
    continue when mc.id is null or mu.id is null;

    perform set_config('app.owner_line_correction', 'on', true);
    -- the other invoice first: its payment and the half month leave it (it may never be paid past its total)
    update manual_payments set amount_cents = amount_cents - r.half,
           note = concat_ws(' ', nullif(note, ''), format('(0874: %s moved to %s, the last month of 1.5 months)', app.fmt_money(r.half), r.u_no))
     where id = mc.id;
    update payments set amount_cents = amount_cents - r.half where id = mc.payment_id;
    update owner_invoices set paid_cents = paid_cents - r.half where id = r.c_id;
    delete from owner_invoice_lines where id = r.half_id;
    -- then the upfront invoice: the last month is 1.5 months, paid by the same money
    update owner_invoice_lines set quantity = 1.5, amount_cents = amount_cents + r.half,
           description = 'Last month''s Insurance Fee (1.5 months)'
     where id = r.last_id;
    perform set_config('app.owner_line_correction', '', true);
    update manual_payments set amount_cents = amount_cents + r.half,
           note = concat_ws(' ', nullif(note, ''), format('(0874: %s from %s, the last month of 1.5 months)', app.fmt_money(r.half), r.c_no))
     where id = mu.id;
    update payments set amount_cents = amount_cents + r.half where id = mu.payment_id;
    update owner_invoices set paid_cents = paid_cents + r.half where id = r.u_id;
    update vehicle_prepaids set amount_cents = amount_cents + r.half
     where vehicle_id = r.vehicle_id and kind = 'last_month_insurance' and source_invoice_id = r.u_id;

    insert into audit_log (actor_user_id, action, entity_table, entity_id, before, after)
    values (null, 'owner_last_month_one_and_half', 'owner_invoices', r.u_id::text,
            jsonb_build_object('upfront', r.u_no, 'last_month_cents', r.last_amount, 'half_month_on', r.c_no, 'half_cents', r.half),
            jsonb_build_object('last_month_cents', r.last_amount + r.half, 'months', 1.5, 'migration', '0874'));
    v_n := v_n + 1;
  end loop;
  return v_n;
end $$;
revoke all on function app.r35_last_month_one_and_half(uuid) from public;

select app.r35_last_month_one_and_half();
