-- 1155_r35g_owner_statement_periods.sql
-- Release 35, part G: owner statements showed $0 ("No activity this month") for most owners whose cars had rentals.
-- The causes, in app.build_owner_statement (0025's core under the 0093 to 0871 wrappers):
--   a. a rental counted only once its booking was returned or closed, on the month it ended: a rental spanning the month end,
--      and a long-term (weekly or biweekly) renter on rent the whole month, gave the statement nothing;
--   b. a rental counted only when every owner-revenue line was linked to a succeeded card payment (uncollected_cents = 0):
--      an insurer-billed rental (the insurer pays later, by invoice), a "Record a past trip" booking and any rental paid
--      outside the card flow (cash, e-transfer) never reached a statement;
--   c. a car showed only when it had such a split, or was enrolled during the month: a car with rentals and no enrollment
--      date showed nothing.
--   The hidden-revenue rule (0156) never changed the build (it limits what the owner sees, and approval reveals): kept,
--   with a test.
-- The owner's rule (confirmed): statement periods cut off on the 7th. The payout on the 10th covers the revenue earned
-- through the 7th of that month: the first statement runs from the earliest booking through November 7, 2026; the next
-- November 8 to December 7; and so on. Program setting statement_cutoff_day (7); the payout day stays the 10th. A statement
-- keeps its statement_month (the month before its payout), and now carries its period (period_starts_on, period_ends_on).
-- Revenue earned in a period: a rental's split (worked out for bookings on rent too) is recognised by its rental days inside
-- the period, on the cutoff, exactly once: each statement takes what was earned through its period end less what approved
-- statements took before (a partial line); the line that completes it (the booking returned or closed by the cutoff) takes
-- the rest and marks the split paid out, as before. Revenue is recognised as earned (accrual), whoever pays and whenever:
-- a later refund or chargeback comes off the next statement as before.
-- Owner invoices: "Deduct from payouts starting" (deduct_from_payout_on): a statement whose payout is before that date
-- deducts nothing of the invoice; Admin sets it on the invoice page next to "Change how it's paid".
-- No applied migration is edited: app.build_owner_statement_0025 is replaced (same signature), the approval and the
-- statement-fees step are patched, the invoice read and the door are wrapped.
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
create function pg_temp.patch_fn(p_sig regprocedure, p_old text, p_new text) returns void
language plpgsql as $$
declare d text := pg_get_functiondef(p_sig);
begin
  if position(p_old in d) = 0 then raise exception '1155: the text to change was not found in %: %', p_sig, left(p_old, 120); end if;
  execute replace(d, p_old, p_new);
end $$;

-- ================================================================ the setting and the columns
alter table program_settings add column if not exists statement_cutoff_day integer not null default 7 check (statement_cutoff_day between 1 and 28);
comment on column program_settings.statement_cutoff_day is 'Owner statements (1155): a statement period ends on this day of the month; the payout on payout_day of that month covers the revenue earned through it.';
alter table owner_statements add column if not exists period_starts_on date, add column if not exists period_ends_on date;
comment on column owner_statements.period_starts_on is 'The first day of the period the statement covers (1155): the day after the previous statement''s period, or the earliest booking for the first one.';
comment on column owner_statements.period_ends_on is 'The last day of the period the statement covers (1155): the cutoff day (statement_cutoff_day) of the month after statement_month.';
alter table owner_statement_lines
  add column if not exists partial boolean not null default false,
  add column if not exists earned_days integer,
  add column if not exists rental_days integer;
comment on column owner_statement_lines.partial is 'A rental line for part of a rental (1155): the rental days earned in the period; the rest comes on a later statement. Approval marks the split paid out only from a line that is not partial.';
comment on column owner_statement_lines.earned_days is 'The rental days this line recognises (1155).';
comment on column owner_statement_lines.rental_days is 'The rental days of the whole rental (1155).';
alter table owner_invoices add column if not exists deduct_from_payout_on date;
comment on column owner_invoices.deduct_from_payout_on is 'Deduct from payouts starting (1155): a statement whose payout date is before this date deducts nothing of the invoice; null: from the next payout.';

-- ================================================================ the period
create function app.statement_period_end(p_month date) returns date
language sql stable security definer set search_path = public, app as $$
  select ((app.month_start(p_month) + interval '1 month')::date + (coalesce((app.settings()).statement_cutoff_day, 7) - 1))
$$;

-- the day after the previous statement's period; for the first statement the earliest booking on the owner's cars
create function app.statement_period_start(p_owner uuid, p_month date) returns date
language sql stable security definer set search_path = public, app as $$
  select coalesce(
    (select max(coalesce(s.period_ends_on, app.statement_period_end(s.statement_month))) + 1 from owner_statements s
      where s.owner_id = p_owner and s.status <> 'void' and s.statement_month < app.month_start(p_month)),
    (select min(app.local_date(b.pickup_at)) from bookings b join booking_splits x on x.booking_id = b.id where x.owner_id = p_owner),
    app.statement_period_end((app.month_start(p_month) - interval '1 month')::date) + 1)
$$;

-- the revenue a car earned for the owner through a period's last day, not yet on an approved statement: one row a split
-- (the whole rental when it ended by then, else its rental days so far), less what approved statements already took
create function app.owner_period_rentals(p_owner uuid, p_vehicle uuid, p_end date)
returns table (booking_id uuid, booking_number text, starts_on date, ends_on date, partial boolean, days_through integer, prior_days integer, total_days integer,
               rental_charge_cents bigint, mileage_overage_cents bigint, refunds_cents bigint, chargebacks_cents bigint, kickback_cents bigint,
               owner_revenue_cents bigint, revenue_share_cents bigint, amount_cents bigint)
language sql stable security definer set search_path = public, app as $$
  with s as (
    select x.*, b.booking_number, b.status::text as bstatus, b.billable_days,
           app.local_date(coalesce(x.segment_starts_at, b.pickup_at)) as start_d,
           greatest(coalesce(x.segment_days, b.billable_days, 1), 1) as total,
           (b.status::text in ('returned', 'closed', 'cancelled', 'no_show') and x.counts_on <= p_end) as final
      from booking_splits x join bookings b on b.id = x.booking_id
     where x.vehicle_id = p_vehicle and x.owner_id = p_owner and x.owner_statement_id is null and x.status <> 'reversed'
  ),
  d as (
    select s.*, case when s.final then s.total when s.bstatus in ('cancelled', 'no_show') then 0
                     else least(s.total, greatest(0, p_end - s.start_d + 1)) end as days
      from s
  ),
  c as (
    select d.*,
           case when d.final then d.owner_revenue_cents else round(d.owner_revenue_cents::numeric * d.days / d.total)::bigint end as c_rev,
           case when d.final then d.company_share_cents else round(d.company_share_cents::numeric * d.days / d.total)::bigint end as c_share,
           case when d.final then d.rental_charge_cents else round(d.rental_charge_cents::numeric * d.days / d.total)::bigint end as c_rental,
           case when d.final then d.kickback_cents else round(d.kickback_cents::numeric * d.days / d.total)::bigint end as c_kick,
           coalesce(p.rev, 0) as p_rev, coalesce(p.share, 0) as p_share, coalesce(p.pay, 0) as p_pay, coalesce(p.rental, 0) as p_rental,
           coalesce(p.kick, 0) as p_kick, coalesce(p.days, 0) as p_days
      from d
      left join lateral (select sum(l.owner_revenue_cents) rev, sum(l.revenue_share_cents) share, sum(l.amount_cents) pay, sum(l.rental_charge_cents) rental,
                                sum(l.kickback_cents) kick, sum(coalesce(l.earned_days, 0))::integer days
                           from owner_statement_lines l join owner_statements st on st.id = l.owner_statement_id
                          where l.line_type = 'rental' and l.booking_id = d.booking_id and l.vehicle_id = d.vehicle_id and st.status not in ('void', 'draft')) p on true
  )
  select c.booking_id, c.booking_number, c.start_d + c.p_days, case when c.final then c.counts_on else c.start_d + c.days - 1 end,
         not c.final, c.days, c.p_days, c.total,
         c.c_rental - c.p_rental, case when c.final then c.mileage_overage_cents else 0 end, case when c.final then c.refunded_cents else 0 end,
         case when c.final then c.chargeback_cents else 0 end, c.c_kick - c.p_kick,
         c.c_rev - c.p_rev, c.c_share - c.p_share,
         case when c.final then c.owner_payout_cents else c.c_rev - c.c_share end - c.p_pay
    from c
   where c.final or c.days > c.p_days
$$;

create or replace function app.build_owner_statement_0025(p_owner uuid, p_month date, p_by uuid DEFAULT NULL::uuid)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'app'
AS $function$
declare
  v_month date := app.month_start(p_month);
  -- 1155: the period ends on the cutoff day of the next month (the payout on the 10th covers what was earned through the 7th)
  v_month_end date := app.statement_period_end(p_month);
  v_payout_on date := app.payout_date(app.month_start(p_month));
  o owners;
  v_id uuid;
  v_status text;
  r record; inv record; other record;
  v_rev bigint; v_share bigint; v_withheld bigint; v_net bigint; v_avail bigint;
  v_take bigint; v_fee_part bigint; v_late_part bigint; v_need bigint;
  v_fees bigint; v_late bigint; v_costs bigint; v_refunds bigint;
  v_moved bigint := 0;
  v_kick bigint; v_hst bigint := 0; v_total bigint; v_payable bigint; v_net_all bigint;
  v_credits bigint; v_credits_all bigint := 0;
  v_prev owner_statements;
begin
  select * into o from owners where id = p_owner;
  if not found then raise exception 'Owner % not found', p_owner; end if;

  select id, status into v_id, v_status from owner_statements where owner_id = p_owner and statement_month = v_month and status <> 'void';
  if v_id is not null and v_status <> 'draft' then
    raise exception 'The % statement for this Owner is already %', to_char(v_month, 'YYYY-MM'), v_status using errcode = '23514';
  end if;
  if v_id is null then
    select * into v_prev from owner_statements where owner_id = p_owner and statement_month = v_month and status = 'void'
     order by version desc limit 1;
    insert into owner_statements (owner_id, statement_month, payout_date, built_by, version, supersedes_statement_id)
    values (p_owner, v_month, app.payout_date(v_month), p_by, coalesce(v_prev.version, 0) + 1, v_prev.id) returning id into v_id;
  else
    delete from owner_statement_lines where owner_statement_id = v_id;
    delete from owner_statement_vehicles where owner_statement_id = v_id;
    update owner_statements set built_at = now(), built_by = p_by, payout_date = app.payout_date(v_month) where id = v_id;
  end if;

  -- bring every finished booking's split up to date first
  -- (its own vehicles' bookings, and bookings on other vehicles whose renter this Owner referred)
  for r in select b.id from bookings b
            where (b.owner_id = p_owner or b.referrer_owner_id = p_owner
                   or exists (select 1 from booking_vehicle_swaps w where w.booking_id = b.id and w.to_owner_id = p_owner))
              and b.booking_type <> 'owner'
              and (b.status in ('returned', 'closed', 'cancelled', 'no_show')
                   or (b.status = 'on_rent' and app.local_date(b.pickup_at) <= v_month_end))
              and (not exists (select 1 from booking_splits s where s.booking_id = b.id and s.owner_statement_id is not null)
                   or exists (select 1 from booking_splits s where s.booking_id = b.id and s.owner_statement_id is null))
  loop
    perform app.compute_booking_split(r.id);
  end loop;
  -- Owner Revenue raised on bookings already paid out (gap 2)
  for r in select s.booking_id from booking_splits s join bookings b on b.id = s.booking_id
            where s.owner_id = p_owner and s.owner_statement_id is not null and b.status in ('returned', 'closed')
  loop
    perform app.sync_later_owner_revenue(r.booking_id);
  end loop;

  -- one block per vehicle with anything to show
  for r in
    select v.id as vehicle_id
      from vehicles v
     where v.owner_id = p_owner
       and (exists (select 1 from app.owner_period_rentals(p_owner, v.id, v_month_end) x)
         or exists (select 1 from turo_trips t where t.vehicle_id = v.id and t.owner_statement_id is null and t.statement_month <= v_month and t.received_at is not null)
         or exists (select 1 from owner_invoices i where i.vehicle_id = v.id and ((i.status in ('in_arrears', 'partially_deducted') or (i.collect_by = 'payout' and i.status in ('issued', 'failed'))) and (i.deduct_from_payout_on is null or i.deduct_from_payout_on <= v_payout_on)))
         or exists (select 1 from owner_deductions d where d.vehicle_id = v.id and d.owner_id = p_owner and d.status = 'open' and d.incurred_on <= v_month_end)
         or exists (select 1 from owner_credits c where c.vehicle_id = v.id and c.owner_id = p_owner and c.status = 'open' and c.incurred_on <= v_month_end)
         -- every vehicle in the program during the month, even with nothing to show (gap 1)
         or (v.enrollment_date is not null and v.enrollment_date <= v_month_end
             and (app.vehicle_fee_end(v.id) is null or app.vehicle_fee_end(v.id) >= v_month)))
     order by v.fleet_number nulls last, v.created_at, v.id
  loop
    -- each rental ended (and each cancellation that kept part of the rental charge)
    -- 1155: the revenue earned in the period: a rental spanning periods by its rental days inside each, recognised once
    insert into owner_statement_lines (owner_statement_id, vehicle_id, line_type, description, booking_id, starts_on, ends_on,
        rental_charge_cents, mileage_overage_cents, refunds_cents, chargebacks_cents, kickback_cents,
        owner_revenue_cents, revenue_share_cents, amount_cents, partial, earned_days, rental_days)
    select v_id, r.vehicle_id, 'rental',
           'Booking ' || x.booking_number || case when x.partial or x.prior_days > 0
             then format(' (%s of %s rental days%s)', x.days_through - x.prior_days, x.total_days, case when x.partial then ', the rest on a later statement' else '' end) else '' end,
           x.booking_id, x.starts_on, x.ends_on,
           x.rental_charge_cents, x.mileage_overage_cents, x.refunds_cents, x.chargebacks_cents, x.kickback_cents,
           x.owner_revenue_cents, x.revenue_share_cents, x.amount_cents, x.partial, x.days_through - x.prior_days, x.total_days
      from app.owner_period_rentals(p_owner, r.vehicle_id, v_month_end) x
     order by x.ends_on, x.booking_number;

    -- each Turo trip: the split applies to the Turo Payout
    insert into owner_statement_lines (owner_statement_id, vehicle_id, line_type, description, turo_trip_id, starts_on, ends_on,
        turo_gross_cents, turo_fees_cents, owner_revenue_cents, revenue_share_cents, amount_cents)
    select v_id, r.vehicle_id, 'turo_trip', 'Turo trip ' || t.turo_trip_ref, t.id,
           app.local_date(t.starts_at), app.local_date(t.ends_at),
           t.gross_cents, t.turo_fees_cents, t.net_payout_cents, t.revenue_share_cents, t.owner_payout_cents
      from turo_trips t
     where t.vehicle_id = r.vehicle_id and t.owner_statement_id is null and t.statement_month <= v_month and t.received_at is not null;

    select coalesce(sum(owner_revenue_cents), 0), coalesce(sum(revenue_share_cents), 0), coalesce(sum(amount_cents), 0)
      into v_rev, v_share, v_net
      from owner_statement_lines where owner_statement_id = v_id and vehicle_id = r.vehicle_id and line_type in ('rental', 'turo_trip');

    -- Owner Revenue in dispute is withheld from the payout
    select coalesce(sum(least(s.withheld_cents, s.owner_payout_cents)), 0) into v_withheld
      from booking_splits s
     where s.vehicle_id = r.vehicle_id and s.owner_id = p_owner and s.owner_statement_id is null and s.status <> 'reversed' and s.withheld_cents > 0
       and exists (select 1 from owner_statement_lines l where l.owner_statement_id = v_id and l.line_type = 'rental' and l.booking_id = s.booking_id
                      and l.vehicle_id = s.vehicle_id and not l.partial);
    if v_withheld > 0 then
      insert into owner_statement_lines (owner_statement_id, vehicle_id, line_type, description, amount_cents)
      values (v_id, r.vehicle_id, 'withheld', 'Owner Revenue in dispute, withheld', -v_withheld);
      v_net := v_net - v_withheld;
    end if;

    -- unpaid Fees and Late Fees after a failed retry: from this vehicle's revenue
    v_avail := greatest(v_net, 0);
    v_fees := 0; v_late := 0;
    for inv in select * from owner_invoices i
                where i.vehicle_id = r.vehicle_id and ((i.status in ('in_arrears', 'partially_deducted') or (i.collect_by = 'payout' and i.status in ('issued', 'failed'))) and (i.deduct_from_payout_on is null or i.deduct_from_payout_on <= v_payout_on)) and i.balance_cents > 0
                order by i.billing_date, i.invoice_number
    loop
      v_take := least(inv.balance_cents, v_avail);
      if v_take > 0 then
        -- Fees (with HST) are settled before the Late Fee
        v_fee_part := least(v_take, greatest(inv.fees_cents + inv.hst_cents - inv.paid_cents - inv.deducted_cents, 0));
        v_late_part := v_take - v_fee_part;
        insert into owner_statement_lines (owner_statement_id, vehicle_id, line_type, description, owner_invoice_id,
            fee_cents, late_fee_cents, amount_cents)
        values (v_id, r.vehicle_id, 'fees_deducted', 'Invoice ' || inv.invoice_number, inv.id, v_fee_part, v_late_part, -v_take);
        v_fees := v_fees + v_fee_part; v_late := v_late + v_late_part;
        v_avail := v_avail - v_take;
      end if;
    end loop;

    -- Owner costs CarmaCars paid, and the Owner's share of an earlier refund or chargeback
    insert into owner_statement_lines (owner_statement_id, vehicle_id, line_type, description, owner_deduction_id, booking_id, amount_cents)
    select v_id, r.vehicle_id,
           case when d.kind in ('refund_share', 'chargeback_share') then 'refund_or_chargeback' else 'owner_cost' end,
           d.description, d.id, d.booking_id, -d.amount_cents
      from owner_deductions d
     where d.vehicle_id = r.vehicle_id and d.owner_id = p_owner and d.status = 'open' and d.incurred_on <= v_month_end;
    select coalesce(-sum(amount_cents) filter (where line_type = 'owner_cost'), 0),
           coalesce(-sum(amount_cents) filter (where line_type = 'refund_or_chargeback'), 0)
      into v_costs, v_refunds
      from owner_statement_lines where owner_statement_id = v_id and vehicle_id = r.vehicle_id;

    -- Owner credits: Owner Revenue billed after the booking was paid out
    insert into owner_statement_lines (owner_statement_id, vehicle_id, line_type, description, owner_credit_id, booking_id, amount_cents)
    select v_id, r.vehicle_id, 'later_revenue', c.description, c.id, c.booking_id, c.amount_cents
      from owner_credits c
     where c.vehicle_id = r.vehicle_id and c.owner_id = p_owner and c.status = 'open' and c.incurred_on <= v_month_end;
    select coalesce(sum(amount_cents), 0) into v_credits
      from owner_statement_lines where owner_statement_id = v_id and vehicle_id = r.vehicle_id and line_type = 'later_revenue';
    v_credits_all := v_credits_all + v_credits;

    insert into owner_statement_vehicles (owner_statement_id, vehicle_id, owner_revenue_cents, revenue_share_cents,
        withheld_cents, net_earnings_cents, fees_deducted_cents, late_fees_deducted_cents,
        owner_costs_deducted_cents, refund_chargeback_deducted_cents, credits_cents, payable_cents)
    values (v_id, r.vehicle_id, v_rev, v_share, v_withheld, v_net, v_fees, v_late, v_costs, v_refunds, v_credits,
            v_net - v_fees - v_late - v_costs - v_refunds + v_credits);
  end loop;

  -- deductions not tied to a vehicle (a reversed kickback, an agreed amount)
  insert into owner_statement_lines (owner_statement_id, vehicle_id, line_type, description, owner_deduction_id, booking_id, amount_cents)
  select v_id, null, 'owner_cost', d.description, d.id, d.booking_id, -d.amount_cents
    from owner_deductions d
   where d.vehicle_id is null and d.owner_id = p_owner and d.status = 'open' and d.incurred_on <= v_month_end;

  -- Balance still left: a debt payable on demand, deducted from the Owner's other vehicles
  for inv in select i.*, i.balance_cents - coalesce((select -sum(l.amount_cents) from owner_statement_lines l
                                  where l.owner_statement_id = v_id and l.owner_invoice_id = i.id), 0) as still_owed
               from owner_invoices i
              where i.owner_id = p_owner and ((i.status in ('in_arrears', 'partially_deducted') or (i.collect_by = 'payout' and i.status in ('issued', 'failed'))) and (i.deduct_from_payout_on is null or i.deduct_from_payout_on <= v_payout_on)) and i.balance_cents > 0
              order by i.billing_date, i.invoice_number
  loop
    v_need := inv.still_owed;
    for other in select sv.vehicle_id,
                        sv.payable_cents - coalesce((select sum(-l.amount_cents) from owner_statement_lines l
                            where l.owner_statement_id = v_id and l.line_type = 'arrears_moved' and l.vehicle_id = sv.vehicle_id), 0) as free
                   from owner_statement_vehicles sv
                  where sv.owner_statement_id = v_id and sv.vehicle_id <> inv.vehicle_id
                  order by sv.payable_cents desc
    loop
      exit when v_need <= 0;
      v_take := least(v_need, greatest(other.free, 0));
      if v_take > 0 then
        insert into owner_statement_lines (owner_statement_id, vehicle_id, line_type, description, owner_invoice_id, from_vehicle_id, amount_cents)
        values (v_id, other.vehicle_id, 'arrears_moved', 'Arrears on invoice ' || inv.invoice_number, inv.id, inv.vehicle_id, -v_take);
        v_moved := v_moved + v_take;
        v_need := v_need - v_take;
      end if;
    end loop;
  end loop;

  -- Referral Kickbacks this Owner earned: paid with the next payout
  insert into owner_statement_lines (owner_statement_id, line_type, description, referral_kickback_id, booking_id,
      rental_charge_cents, amount_cents)
  select v_id, 'kickback_earned', 'Referral Kickback, booking ' || b.booking_number, k.id, k.booking_id, k.base_cents, k.amount_cents
    from referral_kickbacks k join bookings b on b.id = k.booking_id
   where k.referrer_owner_id = p_owner and k.status = 'earned' and k.owner_statement_id is null and k.earned_on <= v_month_end;
  select coalesce(sum(amount_cents), 0) into v_kick
    from owner_statement_lines where owner_statement_id = v_id and line_type = 'kickback_earned';

  select coalesce(sum(payable_cents), 0), coalesce(sum(net_earnings_cents), 0) into v_payable, v_net_all
    from owner_statement_vehicles where owner_statement_id = v_id;
  v_payable := v_payable - coalesce((select sum(-amount_cents) from owner_statement_lines
                                      where owner_statement_id = v_id and vehicle_id is null and line_type = 'owner_cost'), 0);

  -- HST is added only when the Owner's HST number is on file
  if o.hst_number is not null and btrim(o.hst_number) <> '' and v_net_all + v_credits_all > 0 then
    v_hst := public.calc_hst(v_net_all + v_credits_all, (app.settings(v_month)).hst_bps);
    insert into owner_statement_lines (owner_statement_id, line_type, description, amount_cents)
    values (v_id, 'hst_on_payout', 'HST on payout, registration ' || o.hst_number, v_hst);
  end if;
  if o.balance_carried_forward_cents <> 0 then
    insert into owner_statement_lines (owner_statement_id, line_type, description, amount_cents)
    values (v_id, 'balance_brought_forward', 'Balance brought forward', o.balance_carried_forward_cents);
  end if;

  v_total := v_payable - v_moved + v_kick + v_hst + o.balance_carried_forward_cents;

  update owner_statements st
     set owner_revenue_cents = coalesce((select sum(owner_revenue_cents) from owner_statement_vehicles where owner_statement_id = v_id), 0),
         revenue_share_cents = coalesce((select sum(revenue_share_cents) from owner_statement_vehicles where owner_statement_id = v_id), 0),
         net_earnings_cents = v_net_all,
         deductions_cents = coalesce((select sum(fees_deducted_cents + late_fees_deducted_cents + owner_costs_deducted_cents + refund_chargeback_deducted_cents)
                                        from owner_statement_vehicles where owner_statement_id = v_id), 0),
         vehicles_payable_cents = v_payable,
         credits_cents = v_credits_all,
         arrears_moved_cents = v_moved,
         kickbacks_earned_cents = v_kick,
         hst_on_payout_cents = v_hst,
         balance_brought_forward_cents = o.balance_carried_forward_cents,
         payout_cents = greatest(v_total, 0),
         balance_carried_forward_cents = least(v_total, 0),
         is_final = not exists (select 1 from vehicles v where v.owner_id = p_owner and v.status not in ('exited', 'total_loss', 'declined'))
   where st.id = v_id;
  -- 1155: the period it covers
  update owner_statements set period_starts_on = app.statement_period_start(p_owner, v_month), period_ends_on = v_month_end where id = v_id;
  return v_id;
end $function$;

-- approval: a partial line does not mark the split paid out (the rest comes on a later statement)
select pg_temp.patch_fn('app.approve_owner_statement_pre0156(uuid, uuid)'::regprocedure,
  'sl.line_type = ''rental'' and sl.booking_id = s.booking_id',
  'sl.line_type = ''rental'' and not sl.partial and sl.booking_id = s.booking_id');
-- the statement's fees (0204): not before the invoice's "deduct from payouts starting" date
select pg_temp.patch_fn('app.owner_statement_take_fees(uuid)'::regprocedure,
  'where i.owner_id = st.owner_id and i.from_statement and i.status = ''issued'' and i.balance_cents > 0',
  'where i.owner_id = st.owner_id and i.from_statement and i.status = ''issued'' and i.balance_cents > 0
                and (i.deduct_from_payout_on is null or i.deduct_from_payout_on <= st.payout_date)');

-- ================================================================ the invoice: deduct from payouts starting a date
-- p {id, date (YYYY-MM-DD, or empty for the next payout)}
create function app.owner_invoice_deduct_from(p_by uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  i owner_invoices;
  v_on date := nullif(btrim(coalesce(p ->> 'date', p ->> 'deduct_from_payout_on', '')), '')::date;
begin
  perform app.assert_admin(p_by);
  select * into i from owner_invoices where id::text = p ->> 'id' or invoice_number = upper(btrim(coalesce(p ->> 'id', ''))) for update;
  if i.id is null then raise exception 'Invoice not found' using errcode = 'P0002'; end if;
  if i.status in ('paid', 'deducted', 'void') then raise exception 'This invoice is %: nothing left to deduct', i.status using errcode = '23514'; end if;
  update owner_invoices set deduct_from_payout_on = v_on, updated_at = now() where id = i.id;
  insert into audit_log (actor_user_id, action, entity_table, entity_id, before, after)
  values (p_by, 'owner_invoice_deduct_from', 'owner_invoices', i.id::text, jsonb_build_object('deduct_from_payout_on', i.deduct_from_payout_on), jsonb_build_object('deduct_from_payout_on', v_on));
  return jsonb_build_object('id', i.id, 'deduct_from_payout_on', v_on);
end $$;

alter function app.owner_invoice_admin(uuid, jsonb) rename to owner_invoice_admin_pre1155;
create function app.owner_invoice_admin(p_by uuid, p jsonb) returns jsonb
language plpgsql stable security definer set search_path = public, app as $$
declare v jsonb := app.owner_invoice_admin_pre1155(p_by, p);
begin
  if v is null or not (v ? 'id') then return v; end if;
  return v || (select jsonb_build_object('deduct_from_payout_on', i.deduct_from_payout_on) from owner_invoices i where i.id = (v ->> 'id')::uuid);
end $$;
select pg_temp.copy_grants('app.owner_invoice_admin(uuid, jsonb)'::regprocedure, 'app.owner_invoice_admin_pre1155(uuid, jsonb)'::regprocedure);

alter function app.door(uuid, text, text, text, jsonb) rename to door_pre1155;
create function app.door(p_user uuid, p_aal text, p_call text, p_name text, p jsonb default '{}'::jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
begin
  if p_call = 'admin_do' and p_name = 'owner_invoice_deduct_from' then
    perform app.door_begin(p_user, p_aal);
    return app.owner_invoice_deduct_from(p_user, coalesce(p, '{}'::jsonb) - '_va');
  end if;
  return app.door_pre1155(p_user, p_aal, p_call, p_name, p);
end $$;
select pg_temp.copy_grants('app.door(uuid, text, text, text, jsonb)'::regprocedure, 'app.door_pre1155(uuid, text, text, text, jsonb)'::regprocedure);

-- the statements built before: their period
update owner_statements set period_ends_on = app.statement_period_end(statement_month) where period_ends_on is null;
update owner_statements s set period_starts_on = app.statement_period_start(s.owner_id, s.statement_month) where period_starts_on is null;

-- ================================================================ privileges: the server only
do $$
declare f record;
begin
  for f in select p.oid::regprocedure as sig from pg_proc p join pg_namespace n on n.oid = p.pronamespace
            where n.nspname = 'app' and p.proname = any (array['statement_period_end', 'statement_period_start', 'owner_period_rentals',
                     'owner_invoice_deduct_from', 'owner_invoice_admin_pre1155', 'door_pre1155'])
  loop
    execute format('revoke all on function %s from public, anon, authenticated', f.sig);
    execute format('grant execute on function %s to service_role', f.sig);
  end loop;
end $$;
