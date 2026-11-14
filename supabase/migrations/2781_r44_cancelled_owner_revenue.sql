-- 2781_r44_cancelled_owner_revenue.sql
-- Release 44. A cancelled booking with nothing paid put its whole Owner Revenue on the owner's statement ($409.50 on a
-- booking where $0 was paid): app.owner_period_rentals (1155, patched by 2480) treats a cancelled or no-show booking as
-- final and pays the split's full Owner Revenue, and the split counts the rental line whether or not it was ever paid.
-- Now a cancelled or no-show booking is on the statement only for the rental charge actually kept:
--   kept       = what was collected on the booking (charges, not the deposit) less what was refunded (the split's own
--                collected_cents and refunded_cents);
--   before tax = kept in the proportion of what was collected that was not HST;
--   owner part = the kept amount up to the split's rental and mileage (the Owner Revenue base), as a share of it, applied to
--                the rental charge, mileage, kickback, Owner Revenue, the company's share and the payout alike.
-- Nothing kept: no line (the split stays open, so a charge collected later still reaches a later statement). A booking kept
-- off the owner's revenue (2480: hidden insurance replacements, off the calendar, switched off) stays off as before.
-- Returned, closed and on-rent bookings are unchanged (an insurer-billed rental is counted before it is paid, 1155).
-- No applied migration is edited: the function is wrapped (_pre2781).
set local check_function_bodies = off;

alter function app.owner_period_rentals(uuid, uuid, date) rename to owner_period_rentals_pre2781;
create function app.owner_period_rentals(p_owner uuid, p_vehicle uuid, p_end date)
returns table (booking_id uuid, booking_number text, starts_on date, ends_on date, partial boolean, days_through integer, prior_days integer, total_days integer,
               rental_charge_cents bigint, mileage_overage_cents bigint, refunds_cents bigint, chargebacks_cents bigint, kickback_cents bigint,
               owner_revenue_cents bigint, revenue_share_cents bigint, amount_cents bigint)
language sql stable security definer set search_path = public, app as $$
  with o as (select x.*, row_number() over () as k from app.owner_period_rentals_pre2781(p_owner, p_vehicle, p_end) x),
  s as (
    -- the open split each row came from, and for a cancellation or a no-show the share of its Owner Revenue base kept
    select o.k, b.status::text in ('cancelled', 'no_show') as cancelled, sp.*,
           least(1::numeric, greatest(0::numeric,
             (greatest(0, sp.collected_cents - sp.refunded_cents)::numeric
               * greatest(0, sp.collected_cents - sp.hst_cents) / nullif(sp.collected_cents, 0))
             / nullif(sp.rental_charge_cents + sp.mileage_overage_cents, 0))) as kept
      from o join bookings b on b.id = o.booking_id
      left join lateral (select x.* from booking_splits x where x.booking_id = o.booking_id and x.vehicle_id = p_vehicle and x.owner_id = p_owner
                            and x.owner_statement_id is null and x.status <> 'reversed' order by x.computed_at desc nulls last limit 1) sp on true
  ),
  a as (
    -- the scaled totals less what earlier statements already carried (the row is the total less those)
    select o.*, s.cancelled and s.booking_id is not null as scale, coalesce(s.kept, 0) as kept,
           round(s.rental_charge_cents * coalesce(s.kept, 0))::bigint - (s.rental_charge_cents - o.rental_charge_cents) as n_rental,
           round(s.mileage_overage_cents * coalesce(s.kept, 0))::bigint as n_mileage,
           round(s.kickback_cents * coalesce(s.kept, 0))::bigint - (s.kickback_cents - o.kickback_cents) as n_kick,
           round(s.owner_revenue_cents * coalesce(s.kept, 0))::bigint - (s.owner_revenue_cents - o.owner_revenue_cents) as n_rev,
           round(s.company_share_cents * coalesce(s.kept, 0))::bigint - (s.company_share_cents - o.revenue_share_cents) as n_share,
           (round(s.owner_revenue_cents * coalesce(s.kept, 0))::bigint - round(s.company_share_cents * coalesce(s.kept, 0))::bigint)
             - (s.owner_payout_cents - o.amount_cents) as n_pay
      from o join s on s.k = o.k
  )
  select a.booking_id, a.booking_number, a.starts_on, a.ends_on, a.partial, a.days_through, a.prior_days, a.total_days,
         case when a.scale then a.n_rental else a.rental_charge_cents end,
         case when a.scale then a.n_mileage else a.mileage_overage_cents end,
         a.refunds_cents, a.chargebacks_cents,
         case when a.scale then a.n_kick else a.kickback_cents end,
         case when a.scale then a.n_rev else a.owner_revenue_cents end,
         case when a.scale then a.n_share else a.revenue_share_cents end,
         case when a.scale then a.n_pay else a.amount_cents end
    from a
   -- a cancellation with nothing kept (and nothing on an earlier statement to take back) is not on the statement
   where not a.scale or a.kept > 0 or a.n_rev <> 0 or a.n_pay <> 0
   order by a.k
$$;
comment on function app.owner_period_rentals(uuid, uuid, date) is 'The rental lines of an owner statement (1155, 2480, 2781): a cancelled or no-show booking counts only the rental charge actually kept (collected less refunded, before HST); nothing kept, no line.';
revoke all on function app.owner_period_rentals(uuid, uuid, date), app.owner_period_rentals_pre2781(uuid, uuid, date) from public, anon, authenticated;
grant execute on function app.owner_period_rentals(uuid, uuid, date), app.owner_period_rentals_pre2781(uuid, uuid, date) to service_role;
