-- 2820 (release 44): a card payment settled twice at the same moment no longer cancels itself.
--
-- The renter's browser (back from the card form) and the processor's webhook both settle the same authorized payment, often
-- within the same second. The first records the payment and confirms the booking; the second was refused ("Booking ... is
-- already confirmed"), and its refusal cancelled the authorization at the processor while the first was about to capture
-- it. The capture then failed, the payment was marked failed and the renter was asked to pay again (CC-10139, CC-10468,
-- Nov 12 and 13, 2026).
--
-- Now a second settlement of a payment this booking already recorded (same processor payment id) is answered as done
-- (ok, duplicate): nothing is recorded twice, nothing is cancelled, and the first settlement captures as before.
-- web/src/server/portal/payment.ts skips the capture on a duplicate and, when a capture fails, asks the processor whether
-- the payment was in fact captured before marking it failed.

create function pg_temp.copy_grants(p_new regprocedure, p_old regprocedure) returns void
language plpgsql as $$
declare g text;
begin
  execute format('revoke all on function %s from public, anon, authenticated', p_new);
  foreach g in array array['anon', 'authenticated', 'service_role'] loop
    if has_function_privilege(g, p_old, 'execute') then execute format('grant execute on function %s to %I', p_new, g); end if;
  end loop;
end $$;

alter function app.record_booking_payment(uuid, jsonb, bigint, integer, jsonb, text, uuid) rename to record_booking_payment_pre2820;
create function app.record_booking_payment(p_booking uuid, p_processor jsonb, p_amount_cents bigint, p_offer_version integer,
                                           p_card jsonb default null, p_event_id text default null, p_by uuid default null) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  v_proc text := coalesce(nullif(p_processor ->> 'processor', ''), 'stripe');
  v_pp text := nullif(p_processor ->> 'payment_id', '');
  v_number text;
begin
  if v_pp is not null then
    -- wait for a settlement of the same booking running now, then look for the payment it recorded
    select booking_number into v_number from bookings where id = p_booking for update;
    if exists (select 1 from payments p join payment_processor_details d on d.payment_id = p.id
                where p.booking_id = p_booking and p.purpose = 'booking_total' and p.status = 'succeeded'
                  and d.processor = v_proc and d.processor_payment_id = v_pp) then
      return jsonb_build_object('ok', true, 'duplicate', true, 'booking_number', v_number);
    end if;
  end if;
  return app.record_booking_payment_pre2820(p_booking, p_processor, p_amount_cents, p_offer_version, p_card, p_event_id, p_by);
end $$;
comment on function app.record_booking_payment(uuid, jsonb, bigint, integer, jsonb, text, uuid) is
  'r44 (2820): a payment this booking already recorded (same processor payment id) is answered ok with duplicate = true, so a second settlement never refuses and cancels it; otherwise as before (2610).';
select pg_temp.copy_grants('app.record_booking_payment(uuid, jsonb, bigint, integer, jsonb, text, uuid)'::regprocedure,
                           'app.record_booking_payment_pre2820(uuid, jsonb, bigint, integer, jsonb, text, uuid)'::regprocedure);
-- the wrapped function is reached only through the new one
revoke all on function app.record_booking_payment_pre2820(uuid, jsonb, bigint, integer, jsonb, text, uuid) from public, anon, authenticated;
grant execute on function app.record_booking_payment_pre2820(uuid, jsonb, bigint, integer, jsonb, text, uuid) to service_role;
