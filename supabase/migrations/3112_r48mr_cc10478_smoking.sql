-- 3112 (release 48, part MR; docs/changes/2026-11-20-r48-money-rules.md): the smoking fee of CC-10478. The car (a Kia
-- Forte) came back on November 16, 2026 smelling of cannabis and cigarettes; the connector could not add the fee
-- (3102 fixes change_booking_fees). The $300 smoking fee (plus HST) is added the way change_booking_fees now adds a
-- named fee, and is billed from the booking's $600 deposit: at once when the Check-out statement is issued, else on
-- that statement. Runs once and again without change; does nothing on a database without that booking.
set local check_function_bodies = off;

do $$
declare
  b bookings;
  v_by uuid;
  r jsonb;
begin
  select * into b from bookings where booking_number = 'CC-10478';
  if b.id is null then return; end if;
  if exists (select 1 from booking_line_items li where li.booking_id = b.id and li.charge_type = 'smoking' and li.voided_at is null) then return; end if;
  if b.status::text not in ('returned', 'closed') then raise notice '3112: CC-10478 is %, not returned; left as it is', b.status; return; end if;
  select r2.user_id into v_by from user_roles r2 join owners o on o.user_id = r2.user_id
   where r2.role = 'admin' and o.id = '47c906a8-009a-4163-a25f-4836d56960af';
  if v_by is null then select x.approved_by into v_by from owner_statements x where x.approved_by is not null and app.user_is_admin(x.approved_by) order by x.approved_at desc limit 1; end if;
  if v_by is null then select r3.user_id into v_by from user_roles r3 where r3.role = 'admin' order by r3.user_id limit 1; end if;
  if v_by is null then raise notice '3112: no Admin to record it as; left as it is'; return; end if;
  r := app.booking_fees_change(v_by, jsonb_build_object('booking', b.id,
         'lines', jsonb_build_array(jsonb_build_object('op', 'add', 'fee', 'smoking', 'amount_cents', 30000,
                                                      'note', 'The car came back on November 16, 2026 smelling of cannabis and cigarettes')),
         'reason', 'Smoking in the car (rental agreement: no smoking or vaping); billed from the deposit'));
  raise notice '3112: CC-10478 smoking fee: %', r ->> 'billed';
end $$;
