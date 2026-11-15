-- 3010 (release 48): a booking on a payment plan is confirmed once its first instalment is paid, and a plan never shows
-- a $0.00 payment (docs/changes/2026-11-14-r48-plan-first-instalment.md).
--
-- Live case: CC-10293, every 2 weeks at $925, stayed "waiting for payment" with its first $925 paid: the confirmation
-- (app.confirm_when_paid after a pay link or a card charge, app.confirm_offline_booking after a payment recorded by hand)
-- and CarmaCars' countersignature (app.complete_signature_request) waited for the whole total.
--   1. app.booking_plan_first_paid(booking): the booking is on a weekly, every 2 weeks or monthly plan (set, a fixed
--      amount, or the monthly periods of a long rental) with more than one payment, and what the renter paid covers the
--      first one. Then the three steps above go ahead as for a booking paid in full; the rest is collected by the plan.
--   2. app.booking_pay_schedule: an instalment of $0 (a fixed amount that covers the total before the last period, or a
--      monthly period already covered) is folded into the one before it: $1,850 at $925 every 2 weeks is exactly 2
--      payments, the second one running to the return.
--   3. The bookings already stuck that way are confirmed now (the same step a payment runs).
-- No applied migration is edited: the functions are patched (pg_temp.patch_fn).
set local check_function_bodies = off;

create function pg_temp.patch_fn(p_sig regprocedure, p_old text, p_new text) returns void
language plpgsql as $$
declare d text := pg_get_functiondef(p_sig);
begin
  if position(p_old in d) = 0 then raise exception '3010: the text to change was not found in %: %', p_sig, left(p_old, 160); end if;
  execute replace(d, p_old, p_new);
end $$;

-- ================================================================ 2. no $0 instalment
select pg_temp.patch_fn('app.booking_pay_schedule(uuid, timestamptz)'::regprocedure,
  $o$  r record;
$o$,
  $n$  r record;
  v_fold jsonb;
  v_x jsonb;
$n$);
select pg_temp.patch_fn('app.booking_pay_schedule(uuid, timestamptz)'::regprocedure,
  $o$  -- the next payment: the first instalment not covered by what was paid$o$,
  $n$  -- 3010: an instalment of $0 is folded into the one before it (its period too): never a $0.00 payment
  if jsonb_array_length(v_rows) > 1 then
    v_fold := '[]'::jsonb;
    for v_x in select x from jsonb_array_elements(v_rows) x order by (x ->> 'seq')::integer loop
      if (v_x ->> 'cents')::bigint <= 0 and jsonb_array_length(v_fold) > 0 then
        v_fold := jsonb_set(v_fold, array[(jsonb_array_length(v_fold) - 1)::text, 'ends_at'], v_x -> 'ends_at');
      else
        v_fold := v_fold || jsonb_build_array(v_x || jsonb_build_object('seq', jsonb_array_length(v_fold) + 1));
      end if;
    end loop;
    v_rows := v_fold;
  end if;

  -- the next payment: the first instalment not covered by what was paid$n$);

-- ================================================================ 1. the first instalment paid
create or replace function app.booking_plan_first_paid(p_booking uuid) returns boolean
language plpgsql stable security definer set search_path = public, app as $$
declare
  ps jsonb := app.booking_pay_schedule(p_booking);
begin
  return ps is not null and ps ->> 'plan' in ('weekly', 'biweekly', 'monthly')
     and coalesce((ps ->> 'count')::integer, 0) > 1
     and coalesce((ps ->> 'per_cents')::bigint, 0) > 0
     and coalesce((ps ->> 'paid_cents')::bigint, 0) >= (ps ->> 'per_cents')::bigint;
end $$;
comment on function app.booking_plan_first_paid(uuid) is '3010: on a weekly, every 2 weeks or monthly plan of more than one payment, the first payment is paid: the booking is confirmed (and countersigned) as if paid in full.';
revoke all on function app.booking_plan_first_paid(uuid) from public, anon, authenticated;
grant execute on function app.booking_plan_first_paid(uuid) to service_role;

select pg_temp.patch_fn('app.confirm_when_paid(uuid, uuid)'::regprocedure,
  $o$  if app.booking_part_open(b.id, 'rental') + app.booking_part_open(b.id, 'fees') > 0 then return null; end if;$o$,
  $n$  if app.booking_part_open(b.id, 'rental') + app.booking_part_open(b.id, 'fees') > 0 and not app.booking_plan_first_paid(b.id) then return null; end if;$n$);

select pg_temp.patch_fn('app.confirm_offline_booking(uuid, uuid, boolean)'::regprocedure,
  $o$    if v_open > 0 then v_problem$o$,
  $n$    if v_open > 0 and not app.booking_plan_first_paid(b.id) then v_problem$n$);

select pg_temp.patch_fn('app.complete_signature_request(uuid, uuid, text, text)'::regprocedure,
  $o$     and app.booking_part_open(b.id, 'rental') + app.booking_part_open(b.id, 'fees') > 0 then
    raise exception 'CarmaCars countersigns once the amount due at booking is paid'$o$,
  $n$     and app.booking_part_open(b.id, 'rental') + app.booking_part_open(b.id, 'fees') > 0 and not app.booking_plan_first_paid(b.id) then
    raise exception 'CarmaCars countersigns once the amount due at booking is paid'$n$);

-- ================================================================ 3. the bookings already stuck
do $$
declare r record; v jsonb;
begin
  for r in select b.id from bookings b
            where b.status = 'pending_payment' and b.booking_type <> 'owner' and b.pickup_at > now() - interval '30 days'
              and b.offer_approved_version is not null and b.offer_approved_version = b.current_offer_version
              and app.booking_plan_first_paid(b.id) loop
    v := app.confirm_when_paid(r.id, null);
    raise notice '3010: % %', r.id, coalesce(v ->> 'ok', 'skipped');
  end loop;
end $$;
