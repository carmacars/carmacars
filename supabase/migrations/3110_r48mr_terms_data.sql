-- 3110 (release 48, part MR; docs/changes/2026-11-20-r48-money-rules.md): every car's terms put to what was agreed with
-- its owner (the owner's notes of November 20, 2026), recorded in owner_terms_agreed and checked by app.owner_terms_audit.
-- Runs once and again without change (each step checks what is there first); does nothing on a database without these
-- owners. Owners are named by id only (the repository is public).
--
--   owner                                   management fee   Insurance Fee per car a month   costs out of earnings
--   6484ba68 (refers 16f187b8)              not in the notes: left as it is (flagged by the audit)   $284
--   95a30580 (GLA)                          30%              $350
--   42fb4ec9 (Civic)                        30%              $350
--   9f112d3c (Jeep)                         30%              $300
--   86c12980 (Beetle)                       30%              $300                            yes
--   c0f92065 (Outlander)                    30%              $350                            yes
--   4390af3a (every car)                    30% (owner 70%)  $300                            yes
--   16f187b8 (Jetta S, Macan, CTS)          40%              $350; the 10 points above 30% go to 6484ba68 (owner referral share)
--   47c906a8, 8f32cc8f                      shareholders: 90/10 of everything charged, no Insurance Fee
--
-- A management fee or Insurance Fee that differs is corrected from the car's start (app.car_terms_correct: the periods
-- replaced are kept; an owner who gets less is sent an updated Vehicle Schedule to sign, confirming the agreed terms).
-- Costs out of earnings: the owner's Fees are taken from the revenue statement (owners.fees_paid_from = statement).
-- 6484ba68 gets an owner referral link to 16f187b8 (10 points of the revenue base, sees every car of 16f187b8).
-- 3111 recomputes the approved statements not paid out on the corrected terms.
set local check_function_bodies = off;

create or replace function app.owner_terms_audit_fix(p_by uuid) returns jsonb
language plpgsql security definer set search_path = public, app as $f$
declare
  v_by uuid := p_by;
  a record;
  c record;
  n jsonb;
  v_start date;
  v_p jsonb;
  v_reason constant text := 'Agreed terms from the owner''s notes (release 48 terms audit)';
  v_link uuid;
  v_fixed integer := 0;
begin
  perform app.assert_admin(p_by);
  -- 2. every car of these owners to its agreed management fee and Insurance Fee, from the car's start
  for c in select v.id as vehicle_id, v.owner_id, t.revenue_share_bps as share, t.insurance_fee_cents as ins
             from vehicles v join owner_terms_agreed t on t.owner_id = v.owner_id and t.vehicle_id is null
            where not t.shareholder and v.supply_type = 'program_owner' and v.retired_at is null and v.status::text not in ('declined', 'exited', 'total_loss')
            order by v.owner_id, v.created_at loop
    n := app.ct_now(c.vehicle_id);
    v_p := jsonb_build_object('vehicle_id', c.vehicle_id, 'reason', v_reason);
    if c.share is not null and (n ->> 'revenue_share_bps')::integer is distinct from c.share then v_p := v_p || jsonb_build_object('revenue_share_bps', c.share); end if;
    if c.ins is not null and (n ->> 'insurance_fee_cents')::bigint is distinct from c.ins then v_p := v_p || jsonb_build_object('insurance_fee_cents', c.ins); end if;
    -- periods that started later can differ from today's terms: compare every period too
    if not (v_p ? 'revenue_share_bps') and c.share is not null and exists (select 1 from vehicle_fee_history h where h.vehicle_id = c.vehicle_id and h.revenue_share_bps <> c.share) then
      v_p := v_p || jsonb_build_object('revenue_share_bps', c.share);
    end if;
    if not (v_p ? 'insurance_fee_cents') and c.ins is not null and exists (select 1 from vehicle_fee_history h where h.vehicle_id = c.vehicle_id and h.insurance_fee_cents <> c.ins) then
      v_p := v_p || jsonb_build_object('insurance_fee_cents', c.ins);
    end if;
    if not (v_p ? 'revenue_share_bps' or v_p ? 'insurance_fee_cents') then continue; end if;
    begin
      perform app.car_terms_correct(v_by, v_p);
      v_fixed := v_fixed + 1;
    exception when others then
      raise notice '3110: car % left as it is: %', c.vehicle_id, sqlerrm;
      insert into audit_log (actor_user_id, action, entity_table, entity_id, after)
      values (v_by, 'owner_terms_audit_fix_failed', 'vehicles', c.vehicle_id::text, jsonb_build_object('wanted', v_p, 'error', sqlerrm));
    end;
  end loop;

  -- the monthly invoices still drafts of the cars whose Insurance Fee was corrected: made again on the agreed amount
  for c in select distinct i.id, i.vehicle_id, i.period_month from owner_invoices i
             join vehicle_terms_corrections k on k.vehicle_id = i.vehicle_id and k.reason = v_reason and k.values_set ? 'insurance_fee_cents'
            where i.kind = 'monthly' and i.status = 'draft' and i.period_month >= app.month_start(k.effective_from) loop
    begin
      perform app.owner_invoice_void(v_by, jsonb_build_object('id', c.id, 'reason', 'Insurance Fee corrected to the agreed amount (release 48 terms audit)'));
      perform app.generate_owner_invoice(c.vehicle_id, c.period_month, v_by);
    exception when others then
      raise notice '3110: the draft invoice % was left as it is: %', c.id, sqlerrm;
    end;
  end loop;

  -- 3. costs out of earnings: the Fees are taken from the revenue statement
  for a in select t.owner_id from owner_terms_agreed t join owners o on o.id = t.owner_id
            where t.vehicle_id is null and t.costs_from_earnings and o.fees_paid_from <> 'statement' and o.kind = 'program' loop
    perform app.owner_fees_paid_from_set(v_by, jsonb_build_object('owner', a.owner_id, 'fees_paid_from', 'statement'));
  end loop;

  -- 4. shareholders: no Insurance Fee on their cars
  for c in select h.id, h.vehicle_id, h.insurance_fee_cents from vehicle_fee_history h join vehicles v on v.id = h.vehicle_id
            join owner_terms_agreed t on t.owner_id = v.owner_id and t.vehicle_id is null and t.shareholder
           where h.insurance_fee_cents <> 0 loop
    update vehicle_fee_history set insurance_fee_cents = 0, source = 'correction' where id = c.id;
    insert into audit_log (actor_user_id, action, entity_table, entity_id, before, after)
    values (v_by, 'owner_terms_audit_fix', 'vehicle_fee_history', c.id::text, jsonb_build_object('insurance_fee_cents', c.insurance_fee_cents),
            jsonb_build_object('insurance_fee_cents', 0, 'reason', 'Shareholder car: no Insurance Fee (release 48 terms audit)'));
  end loop;

  -- 5. the owner referral share: 10 points of the referred owner's revenue base, and the referrer sees those cars
  for a in select t.owner_id, t.referrer_owner_id, t.referral_share_bps from owner_terms_agreed t
            where t.vehicle_id is null and t.referrer_owner_id is not null and exists (select 1 from owners o where o.id = t.referrer_owner_id) loop
    if exists (select 1 from owner_referral_links l where l.referrer_owner_id = a.referrer_owner_id and l.referred_owner_id = a.owner_id and l.effective_to is null) then continue; end if;
    select coalesce(min(h.effective_from), (select app.local_date(o.created_at) from owners o where o.id = a.owner_id)) into v_start
      from vehicle_fee_history h join vehicles v on v.id = h.vehicle_id where v.owner_id = a.owner_id;
    insert into owner_referral_links (referrer_owner_id, referred_owner_id, share_bps, sees_cars, effective_from, note, created_by)
    values (a.referrer_owner_id, a.owner_id, a.referral_share_bps, true, v_start,
            'The 10 points of the 40% management fee above the standard 30% (release 48 terms audit)', v_by)
    returning id into v_link;
    insert into audit_log (actor_user_id, action, entity_table, entity_id, after)
    values (v_by, 'owner_referral_link', 'owner_referral_links', v_link::text, jsonb_build_object('referrer', a.referrer_owner_id, 'referred', a.owner_id, 'share_bps', a.referral_share_bps, 'from', v_start));
  end loop;

  return jsonb_build_object('cars_corrected', v_fixed);
end $f$;
revoke all on function app.owner_terms_audit_fix(uuid) from public, anon, authenticated;
grant execute on function app.owner_terms_audit_fix(uuid) to service_role;
comment on function app.owner_terms_audit_fix(uuid) is 'Release 48 MR (3110): every car of the owners in owner_terms_agreed put to the agreed management fee and Insurance Fee from its start (app.car_terms_correct), their draft monthly invoices made again, costs out of earnings, no Insurance Fee on shareholder cars, the owner referral links. scripts/owner-terms-audit.mjs --fix runs it.';

do $$
declare
  v_by uuid;
  a record;
  c record;
  n jsonb;
  v_start date;
  v_p jsonb;
  v_reason constant text := 'Agreed terms from the owner''s notes (release 48 terms audit)';
  v_link uuid;
begin
  if not exists (select 1 from owners where id = '16f187b8-db2b-42fa-aeda-ba5195e76209') then
    raise notice '3110: the owners of the notes are not in this database; nothing to do';
    return;
  end if;
  -- who records it: the Admin who approved the statements of November, else the first Admin
  select st.approved_by into v_by from owner_statements st where st.approved_by is not null and app.user_is_admin(st.approved_by) order by st.approved_at desc limit 1;
  if v_by is null then select r.user_id into v_by from user_roles r where r.role = 'admin' order by r.user_id limit 1; end if;
  if v_by is null then raise notice '3110: no Admin to record it as; left as it is'; return; end if;

  -- 1. the agreed terms
  insert into owner_terms_agreed (owner_id, revenue_share_bps, insurance_fee_cents, costs_from_earnings, shareholder, referrer_owner_id, referral_share_bps, note)
  select x.owner_id, x.share, x.ins, x.costs, x.sh, x.ref, x.ref_bps, x.note
    from (values
      ('6484ba68-0624-473a-abbf-c40fb164e2a3'::uuid, null::integer, 28400::bigint, null::boolean, false, null::uuid, null::integer, 'Insurance $284 per car; management fee not in the notes'),
      ('95a30580-9858-417d-a858-38feb8dfd37a', 3000, 35000, null, false, null, null, 'GLA: $350, 30%'),
      ('42fb4ec9-b108-43c3-aa45-39aafe1e233a', 3000, 35000, null, false, null, null, 'Civic: $350, 30%'),
      ('9f112d3c-e766-4fd2-bc3f-7d6666323d70', 3000, 30000, null, false, null, null, 'Jeep: $300, 30%'),
      ('86c12980-63f2-4674-8d9f-80f60ae9aa9e', 3000, 30000, true, false, null, null, 'Beetle: $300, 30%, costs out of earnings'),
      ('c0f92065-ac6f-477f-a7d4-8c3caf47e04c', 3000, 35000, true, false, null, null, 'Outlander: $350, 30%, costs out of earnings'),
      ('4390af3a-e080-4922-bdac-9c953879a709', 3000, 30000, true, false, null, null, '30% (the owner gets 70%), $300 per car, costs out of earnings'),
      ('16f187b8-db2b-42fa-aeda-ba5195e76209', 4000, 35000, null, false, '6484ba68-0624-473a-abbf-c40fb164e2a3', 1000, '40%, $350; 10 points above 30% to the referring owner'),
      ('47c906a8-009a-4163-a25f-4836d56960af', null, 0, null, true, null, null, 'Shareholder: 90/10, no insurance'),
      ('8f32cc8f-5211-4343-aeac-d291b82bad4c', null, 0, null, true, null, null, 'Shareholder: 90/10, no insurance')
    ) as x(owner_id, share, ins, costs, sh, ref, ref_bps, note)
   where exists (select 1 from owners o where o.id = x.owner_id)
     and not exists (select 1 from owner_terms_agreed t where t.owner_id = x.owner_id and t.vehicle_id is null);

  perform app.owner_terms_audit_fix(v_by);

  -- 6. the audit as it stands after the fixes, kept with the release
  insert into audit_log (actor_user_id, action, entity_table, entity_id, after)
  select v_by, 'owner_terms_audit', 'owner_terms_agreed', 'release 48',
         jsonb_build_object('cars', coalesce(jsonb_agg(to_jsonb(x) order by x.owner, x.car), '[]'::jsonb))
    from app.owner_terms_audit() x
   where not exists (select 1 from audit_log l where l.action = 'owner_terms_audit' and l.entity_id = 'release 48');
end $$;
