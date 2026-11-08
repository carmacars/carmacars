-- 0813_r34o_incident_cards.sql
-- Release 34 part O, section B: the printable incident card for the car (what to do in an accident or a breakdown, with the
-- fleet insurance slip). The fleet insurance policy was not stored anywhere as data (only "Insurer confirmed" per car), so
-- fleet_insurance_policies holds the one current policy: insurer, policy number, dates, named insured, the roadside number
-- on the slip and, when one is uploaded, the slip itself. No premium or any amount is stored or shown. The card page reads
-- app.incident_cards (an Admin or Fleet staff).
set local check_function_bodies = off;

create table fleet_insurance_policies (
  id uuid primary key default gen_random_uuid(),
  insurer_name text not null check (length(btrim(insurer_name)) >= 2),
  policy_number text not null check (length(btrim(policy_number)) >= 2),
  effective_on date not null,
  expires_on date not null,
  named_insured text not null default '18122211 Canada Inc.',
  roadside_phone text,
  claims_phone text,
  slip_document_id uuid references documents (id),
  is_current boolean not null default true,
  created_by uuid references users (id),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  check (expires_on > effective_on)
);
comment on table fleet_insurance_policies is 'The fleet insurance policy printed on the incident card (0813). One row is current. Never holds a premium or any amount. slip_document_id: the uploaded pink slip (a stored file) shown on the card instead of the typed fields.';
create unique index fleet_insurance_policies_one_current on fleet_insurance_policies (is_current) where is_current;
alter table fleet_insurance_policies enable row level security;
create policy admin_all on fleet_insurance_policies for all to authenticated using (app.is_admin()) with check (app.is_admin());
revoke all on fleet_insurance_policies from anon;
grant select, insert, update on fleet_insurance_policies to authenticated;
grant all on fleet_insurance_policies to service_role;
create trigger fleet_insurance_policies_updated before update on fleet_insurance_policies for each row execute function app.set_updated_at();
create trigger audit_fleet_insurance_policies after insert or update or delete on fleet_insurance_policies for each row execute function app.audit_row();

create function app.incident_cards_allowed(p_by uuid) returns boolean
language sql stable security definer set search_path = public, app as $$
  select app.user_is_admin(p_by) or coalesce(((app.my_roles(p_by) ->> 'va') = 'fleet') or ((app.my_roles(p_by) -> 'va_functions') ? 'fleet'), false)
$$;

-- p {vehicle_id?}: the cards of one car or of every car in the fleet
create function app.incident_cards(p_by uuid, p jsonb default '{}'::jsonb) returns jsonb
language plpgsql stable security definer set search_path = public, app as $$
declare
  s program_settings := app.settings();
  ss site_settings;
  pol fleet_insurance_policies;
  v_slip documents;
  v_vehicle uuid := nullif(p ->> 'vehicle_id', '')::uuid;
begin
  if not app.incident_cards_allowed(p_by) then raise exception 'Admin or Fleet only' using errcode = '42501'; end if;
  select * into ss from site_settings limit 1;
  select * into pol from fleet_insurance_policies where is_current;
  if pol.slip_document_id is not null then select * into v_slip from documents where id = pol.slip_document_id and purged_at is null; end if;
  return jsonb_build_object(
    'company', jsonb_build_object('trade_name', s.company_trade_name, 'support_phone', coalesce(ss.phone_display, s.company_phone),
                'roadside_phone', coalesce(pol.roadside_phone, ss.roadside_phone_display, s.incident_line_phone), 'incident_line', coalesce(ss.roadside_phone_display, s.incident_line_phone)),
    'policy', case when pol.id is null then null else jsonb_build_object('insurer_name', pol.insurer_name, 'policy_number', pol.policy_number, 'effective_on', pol.effective_on,
                'expires_on', pol.expires_on, 'named_insured', pol.named_insured, 'claims_phone', pol.claims_phone, 'expired', pol.expires_on < app.today(),
                'slip_document_id', v_slip.id, 'slip_mime', v_slip.mime_type) end,
    'cars', coalesce((select jsonb_agg(jsonb_build_object('vehicle_id', v.id, 'year', v.year, 'make', v.make, 'model', v.model, 'plate', v.plate, 'vin', v.vin) order by v.make, v.model, v.plate)
                        from vehicles v where v.retired_at is null and not coalesce(v.is_sample, false) and (v_vehicle is null or v.id = v_vehicle)), '[]'::jsonb));
end $$;

-- an Admin saves the current policy (a new policy replaces it; the old row is kept, not current)
create function app.fleet_policy_save(p_by uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  r fleet_insurance_policies;
  v_slip uuid := nullif(p ->> 'slip_document_id', '')::uuid;
begin
  perform app.assert_admin(p_by);
  if p ? 'premium' or p ? 'premium_cents' then raise exception 'The incident card never shows a premium: it is not stored' using errcode = '22023'; end if;
  if v_slip is not null and not exists (select 1 from documents where id = v_slip and purged_at is null) then raise exception 'That document was not found' using errcode = 'P0002'; end if;
  select * into r from fleet_insurance_policies where is_current for update;
  if r.id is not null and r.policy_number is not distinct from btrim(p ->> 'policy_number') then
    update fleet_insurance_policies set insurer_name = btrim(p ->> 'insurer_name'), effective_on = (p ->> 'effective_on')::date, expires_on = (p ->> 'expires_on')::date,
           named_insured = coalesce(nullif(btrim(p ->> 'named_insured'), ''), named_insured), roadside_phone = nullif(btrim(coalesce(p ->> 'roadside_phone', '')), ''),
           claims_phone = nullif(btrim(coalesce(p ->> 'claims_phone', '')), ''), slip_document_id = v_slip
     where id = r.id returning * into r;
  else
    update fleet_insurance_policies set is_current = false where is_current;
    insert into fleet_insurance_policies (insurer_name, policy_number, effective_on, expires_on, named_insured, roadside_phone, claims_phone, slip_document_id, created_by)
    values (btrim(p ->> 'insurer_name'), btrim(p ->> 'policy_number'), (p ->> 'effective_on')::date, (p ->> 'expires_on')::date,
            coalesce(nullif(btrim(p ->> 'named_insured'), ''), (app.settings()).company_legal_name), nullif(btrim(coalesce(p ->> 'roadside_phone', '')), ''),
            nullif(btrim(coalesce(p ->> 'claims_phone', '')), ''), v_slip, p_by) returning * into r;
  end if;
  return jsonb_build_object('ok', true, 'id', r.id);
end $$;

-- the documents an Admin may attach as the slip: insurer confirmations and insurance proofs, newest first (titles only)
create function app.fleet_policy_slip_choices(p_by uuid) returns jsonb
language plpgsql stable security definer set search_path = public, app as $$
begin
  perform app.assert_admin(p_by);
  return coalesce((select jsonb_agg(jsonb_build_object('id', d.id, 'title', coalesce(d.title, d.kind::text), 'plate', (select v.plate from vehicles v where v.id = d.vehicle_id), 'created_at', d.created_at) order by d.created_at desc)
                     from (select * from documents x where x.kind in ('insurer_confirmation', 'owner_insurance_proof') and x.purged_at is null order by x.created_at desc limit 50) d), '[]'::jsonb);
end $$;

alter function app.door(uuid, text, text, text, jsonb) rename to door_pre0813;
create function app.door(p_user uuid, p_aal text, p_call text, p_name text, p jsonb default '{}'::jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
begin
  if p_name in ('incident_cards', 'fleet_policy_save', 'fleet_policy_slip_choices') and p_call in ('ops_read', 'ops_do') then
    if coalesce(p, '{}'::jsonb) ? '_va' then perform set_config('app.va_active', coalesce(p ->> '_va', ''), true); end if;
    perform app.door_begin(p_user, p_aal);
    p := coalesce(p, '{}'::jsonb) - '_va';
    return case p_name when 'incident_cards' then app.incident_cards(p_user, p) when 'fleet_policy_save' then app.fleet_policy_save(p_user, p) else app.fleet_policy_slip_choices(p_user) end;
  end if;
  return app.door_pre0813(p_user, p_aal, p_call, p_name, p);
end $$;

create function pg_temp.copy_grants(p_new regprocedure, p_old regprocedure) returns void
language plpgsql as $$
declare g text;
begin
  execute format('revoke all on function %s from public, anon, authenticated', p_new);
  foreach g in array array['anon', 'authenticated', 'service_role'] loop
    if has_function_privilege(g, p_old, 'execute') then execute format('grant execute on function %s to %I', p_new, g); end if;
  end loop;
end $$;
select pg_temp.copy_grants('app.door(uuid, text, text, text, jsonb)'::regprocedure, 'app.door_pre0813(uuid, text, text, text, jsonb)'::regprocedure);
do $$
declare f record;
begin
  for f in
    select p.oid::regprocedure as sig from pg_proc p join pg_namespace n on n.oid = p.pronamespace
     where n.nspname = 'app' and p.proname = any (array['incident_cards_allowed', 'incident_cards', 'fleet_policy_save', 'fleet_policy_slip_choices', 'door_pre0813'])
  loop
    execute format('revoke all on function %s from public, anon, authenticated', f.sig);
    execute format('grant execute on function %s to service_role', f.sig);
  end loop;
end $$;
