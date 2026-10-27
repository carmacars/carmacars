-- 0178: every box of the Blind Spot agreement filled (docs/changes/2026-10-27-agreement-every-box.md).
--
-- The owner (October 27, 2026): "Every box needs to be filled out." Box 1 takes CarmaCars' GST/HST account; boxes 12 and
-- 13 (insurance company, policy) carry the coverage of every booking, not only an insurance replacement: OPCF 27 the
-- renter's insurer and policy (as before), card coverage the card's coverage provider (usually Assurant) and the card,
-- the CarmaCars Protection Plan the plan and its activation reference. The card coverage provider is a new field of the
-- coverage proof, asked on the booking's Agreement card like the card issuer (listed until filled; check-out does not wait for it).
-- The pickup copy and the closing copy (0154) already fill K/M out and fuel out from the check-out, and K/M in, driven,
-- charged and fuel in from the check-in. SCHEMA_MARKER 0178.

-- ================================================================ 1. CarmaCars' GST/HST account (box 1)
alter table program_settings alter column company_hst_number set default '76339 9177 RT0001';
update program_settings set company_hst_number = '76339 9177 RT0001'
 where nullif(btrim(coalesce(company_hst_number, '')), '') is null;

-- ================================================================ 2. the card coverage provider
alter table coverage_proofs add column if not exists coverage_provider text;
comment on column coverage_proofs.coverage_provider is 'Card coverage (option 2, 0178): the insurer behind the card''s rental coverage (usually Assurant), printed in box 12 of the Blind Spot agreement.';

-- The coverage details the agreements print beyond the booking's facts (0028): the card coverage provider and the
-- protection plan's activation reference.
create or replace function app.coverage_detail(p_booking uuid) returns jsonb
language sql stable security definer set search_path = public, app as $$
  select coalesce((select jsonb_build_object('coverage_provider', nullif(btrim(coalesce(c.coverage_provider, '')), ''),
                                             'activation_ref', nullif(btrim(coalesce(c.activation_ref, '')), ''))
                     from coverage_proofs c where c.booking_id = p_booking order by c.created_at desc limit 1),
                  jsonb_build_object('coverage_provider', null, 'activation_ref', null))
$$;
create or replace function public.server_coverage_detail(p_booking uuid) returns jsonb
language sql stable security definer set search_path = public, app as $$ select app.coverage_detail(p_booking) $$;

-- The snapshot a version compares (0154): the provider and the activation reference too, so filling them files a
-- corrected copy (not material: the coverage option itself is what is signed again).
alter function app.agreement_snapshot(uuid) rename to agreement_snapshot_pre0178;
create or replace function app.agreement_snapshot(p_booking uuid) returns jsonb
language plpgsql stable security definer set search_path = public, app as $$
declare
  s jsonb := app.agreement_snapshot_pre0178(p_booking);
  d jsonb := app.coverage_detail(p_booking);
begin
  if s is null then return s; end if;
  return jsonb_set(s, '{coverage}', coalesce(s -> 'coverage', '{}'::jsonb)
    || jsonb_build_object('provider', d ->> 'coverage_provider', 'activation_ref', d ->> 'activation_ref'));
end $$;

-- What an agreement still prints blank (0154): card coverage without its provider.
alter function app.agreement_missing(uuid) rename to agreement_missing_pre0178;
create or replace function app.agreement_missing(p_booking uuid) returns jsonb
language plpgsql stable security definer set search_path = public, app as $$
declare
  out jsonb := app.agreement_missing_pre0178(p_booking);
  b bookings;
begin
  select * into b from bookings where id = p_booking;
  if b.id is null then return out; end if;
  if b.coverage_option = 2 and (app.coverage_detail(b.id) ->> 'coverage_provider') is null then
    out := out || jsonb_build_array(jsonb_build_object('key', 'coverage.coverage_provider',
      'label', 'Card coverage: the coverage provider (usually Assurant; on the card''s benefits guide)', 'where', 'coverage', 'required', false));
  end if;
  return out;
end $$;

-- Staff fill it on the Agreement card with the rest (0154's agreement_fill does the other fields).
alter function app.agreement_fill(uuid, jsonb) rename to agreement_fill_pre0178;
create or replace function app.agreement_fill(p_by uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  v_prov text := nullif(btrim(coalesce(p #>> '{coverage,coverage_provider}', '')), '');
  v_cp uuid;
begin
  if v_prov is not null then
    if not app.user_may_handover(p_by) then raise exception 'Not permitted' using errcode = '42501'; end if;
    select id into v_cp from coverage_proofs where booking_id = (p ->> 'booking')::uuid order by created_at desc limit 1;
    if v_cp is null then raise exception 'There is no coverage proof on this booking yet: record it on Drivers and documents' using errcode = '23514'; end if;
    if length(v_prov) > 80 then raise exception 'The coverage provider''s name, up to 80 characters' using errcode = '22023'; end if;
    update coverage_proofs set coverage_provider = v_prov where id = v_cp;
  end if;
  return app.agreement_fill_pre0178(p_by, p);
end $$;

-- ================================================================ 3. privileges
do $$
declare
  f record;
begin
  for f in
    select p.oid::regprocedure as sig from pg_proc p join pg_namespace n on n.oid = p.pronamespace
     where (n.nspname = 'app' and p.proname = any (array['coverage_detail', 'agreement_snapshot', 'agreement_snapshot_pre0178', 'agreement_missing',
              'agreement_missing_pre0178', 'agreement_fill', 'agreement_fill_pre0178']))
        or (n.nspname = 'public' and p.proname = 'server_coverage_detail')
  loop
    execute format('revoke all on function %s from public, anon, authenticated', f.sig);
    execute format('grant execute on function %s to service_role', f.sig);
  end loop;
end $$;
