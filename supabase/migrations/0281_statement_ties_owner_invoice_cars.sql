-- 0281: the company statement counts a car whose only money in the month is an owner invoice payment
-- (docs/changes/2026-11-04-statement-ties-owner-invoice-cars.md).
--
-- The cash tie compares every payment of the month with the cash collected on the vehicle lines. A vehicle line is
-- built for an enrolled car, a car with rentals, fees, Turo trips, expenses or tolls in the month, or a car with a
-- booking payment in the month, but not for a car whose owner paid an owner invoice (for example the upfront invoice of
-- a car signed but not yet enrolled). That payment had no vehicle line to land on, so the statement said "not tied to a
-- booking or an owner invoice" although it was tied to one. Now a car with an owner invoice payment in the month has its
-- vehicle line too. No applied migration is edited.
set local check_function_bodies = off;

create function pg_temp.patch_fn(p_sig regprocedure, p_old text, p_new text) returns void
language plpgsql as $$
declare
  d text := pg_get_functiondef(p_sig);
begin
  if position(p_old in d) = 0 then
    raise exception '0281: the text to change was not found in %: %', p_sig, left(p_old, 120);
  end if;
  execute replace(d, p_old, p_new);
end $$;

select pg_temp.patch_fn('app.build_company_statement_0021(date, uuid)'::regprocedure,
  $o$        or v.id in (select bk.vehicle_id from payments p join bookings bk on bk.id = p.booking_id
                     where p.status = 'succeeded' and p.processed_at >= t0 and p.processed_at < t1))$o$,
  $n$        or v.id in (select bk.vehicle_id from payments p join bookings bk on bk.id = p.booking_id
                     where p.status = 'succeeded' and p.processed_at >= t0 and p.processed_at < t1)
        or v.id in (select oi.vehicle_id from payments p join owner_invoices oi on oi.id = p.owner_invoice_id
                     where p.booking_id is null and p.status = 'succeeded' and p.processed_at >= t0 and p.processed_at < t1))$n$);
