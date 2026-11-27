-- 5115 (r50 hotfix2): four connector writes an Admin needed for a car that went out before it was paid (CC-10673). Each is
-- one door action of the screens, previewed then confirmed and logged with the before and after like every connector write
-- (0732), so the database refuses exactly what the screens refuse.
--   add_rental              ops_do manual_rental_create (Bookings > Add a rental): a pickup already passed with the return
--                           ahead is recorded on trip from that pickup in the same step (0072); payment "unpaid" or "link"
--                           leaves the money owed.
--   change_coverage         ops_do protection_change (2540): Protection Plan (3), the renter's own insurance with OPCF 27 (1)
--                           or card coverage (2), with a reason, on a request, an offer, a confirmed booking or a rental in
--                           progress.
--   confirm_pay_later       admin_do booking_pay_later (5114): a booking waiting for payment is confirmed with the money owed.
--   start_rental_pay_later  admin_do booking_start_pay_later (5114): an offer or a booking waiting for payment is booked,
--                           confirmed pay later and its pickup recorded at the real (past) time, in one step.

alter function app.api_action(text) rename to api_action_pre5115;
create function app.api_action(p_tool text) returns jsonb
language sql immutable as $$
  select case p_tool
    when 'add_rental'             then '{"call":"ops_do","name":"manual_rental_create","target":"new_booking"}'::jsonb
    when 'change_coverage'        then '{"call":"ops_do","name":"protection_change","target":"booking"}'::jsonb
    when 'confirm_pay_later'      then '{"call":"admin_do","name":"booking_pay_later","target":"booking"}'::jsonb
    when 'start_rental_pay_later' then '{"call":"admin_do","name":"booking_start_pay_later","target":"booking"}'::jsonb
    else app.api_action_pre5115(p_tool) end
$$;

do $$
declare g text;
begin
  execute 'revoke all on function app.api_action(text) from public, anon, authenticated';
  foreach g in array array['anon', 'authenticated', 'service_role'] loop
    if has_function_privilege(g, 'app.api_action_pre5115(text)'::regprocedure, 'execute') then execute format('grant execute on function app.api_action(text) to %I', g); end if;
  end loop;
end $$;
