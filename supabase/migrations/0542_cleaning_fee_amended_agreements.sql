-- 0542: the cleaning fee for an excessively dirty car, and amended agreements without a new signature
-- (docs/changes/2026-11-07-r28-operations.md, A7 and A8).
--
-- A7. "Cleaning fee: $300 default for an excessively dirty or smoked-in car; editable in Admin fees (never hard coded);
--     in the rental terms and the fees list; billable from the booking/deposit."
--     The heavy cleaning fee (cleaning_heavy: heavy soiling or odour) becomes $300 from today, as a new fee default
--     (Admin > Settings > Fees keeps changing it); the smoking fee is already $300. The check-in assessment charges it
--     from the cleanliness answer as before, and the statement takes it from the deposit like every check-in charge.
--     The rental terms' schedule of fees (docs/source/v2_rental.md) says $300.
--
-- A8. "Agreement amendments without re-signature": the rental terms' new section 15.4 lets CarmaCars update a booking's
--     details (extensions, adjustments, fees, dates, car swaps) and the signed agreement keeps applying to the updated
--     booking. A change after signing makes a new version of the agreement marked "Amended <date>", carrying the
--     original signature, and the renter is sent it (renter_agreement_version, needs_signature false). Nobody is asked
--     to sign again, except an Additional Driver who never signed this booking's agreement (they sign before driving).
--     A change of the agreement's wording itself (an Admin's wording override) still asks for signatures.
-- No applied migration is edited.

-- ================================================================ A7
update fee_types set label = 'Cleaning, excessively dirty (heavy soiling or odour)' where code = 'cleaning_heavy';
do $$
declare v_from date := app.today();
begin
  if exists (select 1 from fee_defaults d where d.fee_type_code = 'cleaning_heavy' and d.vehicle_class is null
              and d.effective_from <= v_from and (d.effective_to is null or d.effective_to > v_from) and d.amount_cents <> 30000) then
    update fee_defaults d set effective_to = v_from
     where d.fee_type_code = 'cleaning_heavy' and d.vehicle_class is null and d.effective_from < v_from and (d.effective_to is null or d.effective_to > v_from);
    delete from fee_defaults d where d.fee_type_code = 'cleaning_heavy' and d.vehicle_class is null and d.effective_from = v_from;
    insert into fee_defaults (fee_type_code, vehicle_class, amount_cents, note, effective_from)
    values ('cleaning_heavy', null, 30000, 'Release 28: $300 for an excessively dirty vehicle (the owner, November 6)', v_from);
  end if;
end $$;

-- ================================================================ A8
alter function app.agreement_plan(uuid) rename to agreement_plan_pre0542;
create function app.agreement_plan(p_booking uuid) returns jsonb
language plpgsql stable security definer set search_path = public, app as $$
declare
  pl jsonb := app.agreement_plan_pre0542(p_booking);
  v_signers jsonb;
begin
  if pl ->> 'state' <> 'version' or not coalesce((pl ->> 'material')::boolean, false) or coalesce((pl ->> 'wording_changed')::boolean, false) then
    return pl;
  end if;
  -- section 15.4: the signed agreement applies to the updated booking; only a driver who never signed it signs
  select coalesce(jsonb_agg(s), '[]'::jsonb) into v_signers
    from jsonb_array_elements(coalesce(pl -> 'signers', '[]'::jsonb)) s
   where s ->> 'role' = 'additional_driver'
     and not exists (select 1 from rental_agreement_signers g join rental_agreements a on a.id = g.agreement_id
                      where a.booking_id = p_booking and g.booking_driver_id = nullif(s ->> 'booking_driver_id', '')::uuid and g.signed_at is not null)
     and not exists (select 1 from agreement_version_signers g join agreement_versions v on v.id = g.version_id
                      where v.booking_id = p_booking and g.booking_driver_id = nullif(s ->> 'booking_driver_id', '')::uuid and g.signed_at is not null);
  return pl || jsonb_build_object('material', jsonb_array_length(v_signers) > 0, 'signers', v_signers, 'amended', true,
                                  'amended_on', to_char(app.today(), 'YYYY-MM-DD'));
end $$;
revoke all on function app.agreement_plan(uuid) from public, anon, authenticated;
grant execute on function app.agreement_plan(uuid) to service_role;
comment on function app.agreement_plan(uuid) is 'What the agreement job does next (0154). 0542: a change after signing is an amendment under section 15.4 of the rental terms: a version marked amended, not signed again (only a driver who never signed signs).';
