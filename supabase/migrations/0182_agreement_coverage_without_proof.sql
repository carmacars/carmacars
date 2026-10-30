-- 0182: staff can type the renter's coverage details on the Agreement card before any proof is uploaded
-- (Mahad, October 28: an OPCF 27 renter whose pink card was shown in person could not get an agreement). SCHEMA_MARKER 0182.
-- Before: agreement_fill refused coverage fields with "There is no coverage proof on this booking yet". Now, when the
-- booking has no coverage_proofs row, filling them creates one (status submitted, no document, the booking's coverage
-- option, or 1 for policy details and 2 for card details), records who entered it, and goes on. The proof still shows
-- as not confirmed until someone reviews a document, as before. app.agreement_fill keeps its signature.

alter function app.agreement_fill(uuid, jsonb) rename to agreement_fill_pre0182;
create or replace function app.agreement_fill(p_by uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  x jsonb := coalesce(p -> 'coverage', '{}'::jsonb);
  v_booking uuid := nullif(p ->> 'booking', '')::uuid;
  v_opt smallint;
begin
  if x <> '{}'::jsonb and v_booking is not null
     and not exists (select 1 from coverage_proofs where booking_id = v_booking) then
    if not app.user_may_handover(p_by) then raise exception 'Not permitted' using errcode = '42501'; end if;
    select coalesce(b.coverage_option,
                    case when nullif(btrim(coalesce(x ->> 'card_issuer', x ->> 'card_last4', x ->> 'coverage_provider', '')), '') is not null then 2 else 1 end)
      into v_opt from bookings b where b.id = v_booking;
    if v_opt is null then raise exception 'Booking not found' using errcode = 'P0002'; end if;
    insert into coverage_proofs (booking_id, coverage_option, status) values (v_booking, v_opt, 'submitted');
    insert into audit_log (actor_user_id, action, entity_table, entity_id, after)
    values (p_by, 'coverage_entered_without_proof', 'bookings', v_booking::text, jsonb_build_object('coverage_option', v_opt));
  end if;
  return app.agreement_fill_pre0182(p_by, p);
end $$;

revoke all on function app.agreement_fill(uuid, jsonb) from public, anon, authenticated;
revoke all on function app.agreement_fill_pre0182(uuid, jsonb) from public, anon, authenticated;
grant execute on function app.agreement_fill(uuid, jsonb) to service_role;
grant execute on function app.agreement_fill_pre0182(uuid, jsonb) to service_role;
