-- 2673 (release 42 hotfix): switching a booking to the Protection Plan was refused with "no price for this car yet" whenever the
-- Fees table had no flat Protection Plan amount, although the dialog already quoted the plan from the car's own pricing
-- (app.coverage_plan_line). The check now asks the same function the dialog and the switch use. SCHEMA_MARKER 2673.
create function pg_temp.patch_fn(p_sig regprocedure, p_old text, p_new text) returns void
language plpgsql as $$
declare d text := pg_get_functiondef(p_sig);
begin
  if position(p_old in d) = 0 then raise exception '2673: the text to change was not found in %: %', p_sig, left(p_old, 160); end if;
  execute replace(d, p_old, p_new);
end $$;

create function app.protection_plan_priced(p_booking uuid) returns boolean
language plpgsql stable security definer set search_path = public, app as $$
begin
  return coalesce((app.coverage_plan_line(p_booking) ->> 'amount_cents')::bigint, 0) > 0;
exception when others then
  return false;
end $$;
revoke all on function app.protection_plan_priced(uuid) from public;
grant execute on function app.protection_plan_priced(uuid) to service_role;

select pg_temp.patch_fn('app.protection_block(bookings, integer, text)'::regprocedure,
  'if coalesce((select t.amount_cents from app.fee_term(''coverage_sold'', b.vehicle_id, app.local_date(coalesce(b.booked_at, now())), b.id) t), 0) <= 0 then',
  'if not app.protection_plan_priced(b.id) then');
