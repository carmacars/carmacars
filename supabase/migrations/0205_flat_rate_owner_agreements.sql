-- 0205: the flat-rate owner agreement set (Release 21, item 6). SCHEMA_MARKER 0205.
-- docs/changes/2026-10-31-flat-rate-owner-agreements.md.
--   Owners paid a flat monthly amount per car (0196) sign the Flat-Rate Vehicle Enrollment Agreement
--   (docs/source/v2_flat_rate_enrollment.md, web/src/features/owner-agreement/flat-rate.generated.ts) instead of the
--   standard Vehicle Enrollment Agreement; the Title-Holding and Lease Agreement and Forms A to D are the same. The set is
--   picked by the owner's pay model: flat_rate when every car of the owner in the program is on a flat monthly payment (in
--   force or starting later), standard otherwise. A change of pay model ends the signed Enrollment Agreement of the other
--   set and opens a new one of the right set: the owner signs again (the cars keep running meanwhile).
--   Program settings: "Flat-rate agreements awaiting lawyer OK" (owner_flat_agreements_awaiting_lawyer, on by default)
--   flags the set in Admin until Abbas turns it off; signing works either way.
set local check_function_bodies = off;

create function pg_temp.copy_grants(p_new regprocedure, p_old regprocedure) returns void
language plpgsql as $$
declare g text;
begin
  execute format('revoke all on function %s from public, anon, authenticated', p_new);
  foreach g in array array['anon', 'authenticated', 'service_role'] loop
    if has_function_privilege(g, p_old, 'execute') then execute format('grant execute on function %s to %I', p_new, g); end if;
  end loop;
end $$;

alter table owner_agreements add column if not exists variant text not null default 'standard' check (variant in ('standard', 'flat_rate'));
comment on column owner_agreements.variant is 'The agreement set (0205): standard (revenue share and fees) or flat_rate (a flat monthly amount per car, 0196). Only an Enrollment Agreement is flat_rate.';
alter table owner_agreements add constraint owner_agreements_variant_kind check (variant = 'standard' or kind = 'enrollment');
alter table program_settings add column if not exists owner_flat_agreements_awaiting_lawyer boolean not null default true;
comment on column program_settings.owner_flat_agreements_awaiting_lawyer is 'Flat-rate agreements awaiting lawyer OK (0205): shown in Admin until turned off; owners can sign meanwhile.';

-- ================================================================ 1. the pay model
create function app.owner_pay_model(p_owner uuid) returns text
language sql stable security definer set search_path = public, app as $$
  select case when count(*) > 0 and bool_and(exists (
                 select 1 from vehicle_owner_arrangements a
                  where a.vehicle_id = v.id and a.kind = 'flat_monthly' and a.cancelled_at is null and (a.ends_on is null or a.ends_on >= app.today())))
              then 'flat_rate' else 'standard' end
    from vehicles v
   where v.owner_id = p_owner and v.status not in ('exited', 'declined', 'total_loss') and coalesce(v.supply_type::text, 'program_owner') = 'program_owner'
$$;

-- The owner's Enrollment Agreement follows the pay model: an open one changes set; a signed one of the other set ends and a
-- new one of the right set is opened for signature (the schedules move to it).
create function app.owner_agreement_set_sync(p_owner uuid) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  ea owner_agreements;
  prev owner_agreements;
  v_model text := app.owner_pay_model(p_owner);
  v_new uuid;
begin
  select * into ea from owner_agreements where owner_id = p_owner and kind = 'enrollment' and status in ('draft', 'sent', 'signed') for update;
  if ea.id is null or ea.variant = v_model then return jsonb_build_object('changed', false, 'pay_model', v_model); end if;
  -- changed back before the new one was signed: the agreement the owner signed is in force again
  select * into prev from owner_agreements e
   where e.owner_id = p_owner and e.kind = 'enrollment' and e.status = 'ended' and e.variant = v_model and e.ended_at >= ea.created_at - interval '1 minute'
   order by e.ended_at desc limit 1;
  if prev.id is not null and ea.status in ('draft', 'sent') then
    update owner_agreements set status = 'void' where id = ea.id;
    update signature_requests set status = 'voided' where id = ea.signature_request_id and status in ('draft', 'sent', 'partially_signed');
    update owner_agreements set status = 'signed', ended_at = null where id = prev.id;
    update vehicle_schedules set owner_agreement_id = prev.id where owner_agreement_id = ea.id and superseded_by is null;
    return jsonb_build_object('changed', true, 'agreement_id', prev.id, 'pay_model', v_model, 'resign', false, 'restored', true);
  end if;
  if ea.status in ('draft', 'sent') then
    update owner_agreements set variant = v_model where id = ea.id;
    return jsonb_build_object('changed', true, 'agreement_id', ea.id, 'pay_model', v_model, 'resign', false);
  end if;
  update owner_agreements set status = 'ended', ended_at = now() where id = ea.id;
  insert into owner_agreements (owner_id, kind, agreement_number, status, variant, corporate_signatory_name, corporate_signatory_title)
  values (p_owner, 'enrollment', 'EA-' || nextval('owner_agreement_number_seq'), 'draft', v_model, ea.corporate_signatory_name, ea.corporate_signatory_title)
  returning id into v_new;
  update vehicle_schedules set owner_agreement_id = v_new where owner_agreement_id = ea.id and superseded_by is null;
  insert into audit_log (action, entity_table, entity_id, before, after)
  values ('owner_agreement_set_changed', 'owner_agreements', v_new::text, jsonb_build_object('agreement_id', ea.id, 'variant', ea.variant),
          jsonb_build_object('agreement_id', v_new, 'variant', v_model, 'reason', 'The owner''s pay model changed: the owner signs the new Enrollment Agreement'));
  return jsonb_build_object('changed', true, 'agreement_id', v_new, 'pay_model', v_model, 'resign', true);
end $$;

create function app.owner_agreement_set_sync_trg() returns trigger
language plpgsql security definer set search_path = public, app as $$
begin
  perform app.owner_agreement_set_sync(coalesce(new.owner_id, old.owner_id));
  return null;
end $$;
create trigger vehicle_owner_arrangements_agreement_set after insert or update on vehicle_owner_arrangements
  for each row execute function app.owner_agreement_set_sync_trg();

-- a new Enrollment Agreement (terms set for a first car) starts in the owner's set
alter function app.apply_vehicle_terms(uuid, jsonb, uuid, uuid) rename to apply_vehicle_terms_pre0205;
create function app.apply_vehicle_terms(p_vehicle uuid, p_t jsonb, p_set_by uuid, p_approved_by uuid) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  v jsonb := app.apply_vehicle_terms_pre0205(p_vehicle, p_t, p_set_by, p_approved_by);
begin
  perform app.owner_agreement_set_sync((select owner_id from vehicles where id = p_vehicle));
  return v;
end $$;
select pg_temp.copy_grants('app.apply_vehicle_terms(uuid, jsonb, uuid, uuid)'::regprocedure, 'app.apply_vehicle_terms_pre0205(uuid, jsonb, uuid, uuid)'::regprocedure);

-- ================================================================ 2. the facts the documents are built from
alter function app.owner_agreement_facts(uuid, uuid) rename to owner_agreement_facts_pre0205;
create function app.owner_agreement_facts(p_owner uuid, p_by uuid) returns jsonb
language sql stable security definer set search_path = public, app as $$
  select f || jsonb_build_object(
      'pay_model', app.owner_pay_model(p_owner),
      'flat_rate_review', (app.settings()).owner_flat_agreements_awaiting_lawyer,
      'agreements', coalesce((select jsonb_agg(x || jsonb_build_object('variant', a.variant,
                        'replaces', exists (select 1 from owner_agreements e where e.owner_id = p_owner and e.kind = a.kind and e.status = 'ended' and e.created_at < a.created_at)))
                      from jsonb_array_elements(f -> 'agreements') x left join owner_agreements a on a.id::text = x ->> 'id'), '[]'::jsonb),
      'schedules', coalesce((select jsonb_agg(x || jsonb_build_object('monthly_cents', (select ar.monthly_cents from vehicle_owner_arrangements ar
                        where ar.vehicle_id::text = x ->> 'vehicle_id' and ar.kind = 'flat_monthly' and ar.cancelled_at is null and (ar.ends_on is null or ar.ends_on >= app.today())
                        order by ar.starts_on limit 1)))
                      from jsonb_array_elements(f -> 'schedules') x), '[]'::jsonb))
    from app.owner_agreement_facts_pre0205(p_owner, p_by) f
$$;
select pg_temp.copy_grants('app.owner_agreement_facts(uuid, uuid)'::regprocedure, 'app.owner_agreement_facts_pre0205(uuid, uuid)'::regprocedure);

-- Admin: the owner's agreement set, and the lawyer flag
create function app.owner_agreement_set(p_by uuid, p jsonb) returns jsonb
language sql stable security definer set search_path = public, app as $$
  select jsonb_build_object('pay_model', app.owner_pay_model(o.id),
           'variant', (select a.variant from owner_agreements a where a.owner_id = o.id and a.kind = 'enrollment' and a.status in ('draft', 'sent', 'signed')),
           'status', (select a.status from owner_agreements a where a.owner_id = o.id and a.kind = 'enrollment' and a.status in ('draft', 'sent', 'signed')),
           'awaiting_lawyer', (app.settings()).owner_flat_agreements_awaiting_lawyer)
    from owners o where o.id::text = p ->> 'owner' and (app.user_is_admin(p_by) or app.user_is_staff(p_by))
$$;

-- ================================================================ 3. the door, privileges
alter function app.door(uuid, text, text, text, jsonb) rename to door_pre0205;
create function app.door(p_user uuid, p_aal text, p_call text, p_name text, p jsonb default '{}'::jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
begin
  if p_call = 'ops_read' and p_name = 'owner_agreement_set' then
    perform app.door_begin(p_user, p_aal);
    return app.owner_agreement_set(p_user, coalesce(p, '{}'::jsonb) - '_va');
  end if;
  return app.door_pre0205(p_user, p_aal, p_call, p_name, p);
end $$;
select pg_temp.copy_grants('app.door(uuid, text, text, text, jsonb)'::regprocedure, 'app.door_pre0205(uuid, text, text, text, jsonb)'::regprocedure);

do $$
declare
  f record;
begin
  for f in
    select p.oid::regprocedure as sig from pg_proc p join pg_namespace n on n.oid = p.pronamespace
     where n.nspname = 'app' and p.proname = any (array['owner_pay_model', 'owner_agreement_set_sync', 'owner_agreement_set_sync_trg', 'apply_vehicle_terms_pre0205',
             'owner_agreement_facts_pre0205', 'owner_agreement_set', 'door_pre0205'])
  loop
    execute format('revoke all on function %s from public, anon, authenticated', f.sig);
    execute format('grant execute on function %s to service_role', f.sig);
  end loop;
end $$;

-- the owners already on a flat monthly payment (0196) get the set now
select app.owner_agreement_set_sync(o.id) from owners o where exists (select 1 from vehicle_owner_arrangements a where a.owner_id = o.id);
