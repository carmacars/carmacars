-- 3820: the owner documents, right for every owner and every car (Release 50, owners). docs/changes/2026-11-24-r50-sign-first.md.
-- SCHEMA_MARKER 3820. No applied migration is edited.
-- Abbas, November 24, 2026: fix these for every owner and every vehicle, not only the one who reported them.
--   1. The signing officer's title is a role (Director, President, Owner ...), never a person's name (a trigger refuses a
--      name; the ones on record become empty where the agreement is not signed yet, so the owner is asked for it).
--   2. The Onboarding Method agrees with how the car is held: on a Vehicle Schedule not signed yet it is one of the methods
--      open to its holder, title and mode (app.onboarding_options); the screens no longer fall back to the first option
--      (Co-Registrant or a new Owner Corporation for a car held personally) but to Transfer, the method that needs no
--      CarmaCars registration (src/features/owner-billing/ApproveStep.tsx, src/features/admin/AdminForms.tsx).
--   3. First and last month follows the program rule (two months of the Insurance Fee) unless an Admin agreed otherwise:
--      when an unsigned Vehicle Schedule's Insurance Fee changes, a first and last amount that was two of the old fee
--      follows the new one; unsigned schedules whose amount is two of an earlier fee (no first and last invoice issued) are
--      set back to the rule.
--   4. Insurance never carries HST (Program setting insurance_fee_hst, off): a draft invoice line of insurance with HST is
--      corrected; an issued one is listed for Finance.
--   5. Admin > Owners > Document check (app.owner_documents_check, door owner_documents_check, the connector's
--      owner_documents_check): everything still inconsistent on an owner's documents, by owner and by issue.
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

-- ================================================================ 1. the signing officer's title is a role
create function app.title_is_name(p_title text, p_officer text, p_legal text, p_first text, p_last text) returns boolean
language sql immutable set search_path = public, app, pg_temp as $$
  select nullif(btrim(p_title), '') is not null
     and lower(regexp_replace(btrim(p_title), '\s+', ' ', 'g')) in (
           lower(regexp_replace(btrim(coalesce(p_officer, '')), '\s+', ' ', 'g')),
           lower(regexp_replace(btrim(coalesce(p_legal, '')), '\s+', ' ', 'g')),
           lower(regexp_replace(btrim(coalesce(p_first, '') || ' ' || coalesce(p_last, '')), '\s+', ' ', 'g')))
$$;

create function app.owners_title_trg() returns trigger
language plpgsql security definer set search_path = public, app, pg_temp as $$
begin
  if new.owner_type = 'corporation' and app.title_is_name(new.signing_officer_title, new.signing_officer_name, new.legal_name, new.first_name, new.last_name)
     and (tg_op = 'INSERT' or new.signing_officer_title is distinct from old.signing_officer_title) then
    raise exception 'The signing officer''s title is a role, such as Director, President or Owner, not a name' using errcode = '22023';
  end if;
  return new;
end $$;
create trigger owners_title_role before insert or update of signing_officer_title on owners for each row execute function app.owners_title_trg();

-- ================================================================ 2 and 3. the method and the first and last month of a schedule
create function app.vehicle_schedules_terms_trg() returns trigger
language plpgsql security definer set search_path = public, app, pg_temp as $$
declare ob vehicle_onboardings;
begin
  if new.signed_at is not null then return new; end if;
  -- the first and last month that was two of the old Insurance Fee follows the new one (the rule)
  if tg_op = 'UPDATE' and new.insurance_fee_cents is distinct from old.insurance_fee_cents
     and new.first_last_cents is not null and new.first_last_cents = 2 * old.insurance_fee_cents then
    new.first_last_cents := null;
  end if;
  -- the method agrees with how the car is held
  if new.onboarding_method <> 'none' and (tg_op = 'INSERT' or new.onboarding_method is distinct from old.onboarding_method)
     and coalesce(current_setting('app.method_check', true), '') <> 'off' then
    select * into ob from vehicle_onboardings where vehicle_id = new.vehicle_id;
    if ob.id is not null and not exists (select 1 from app.onboarding_options(coalesce(ob.held_by, new.held_by), coalesce(ob.title_status, new.title_status), new.management_mode) x
                                          where x.method = new.onboarding_method) then
      raise exception '% is not a method for a car held by % (%, %): choose one of %', replace(new.onboarding_method::text, '_', ' '), coalesce(ob.held_by, new.held_by),
        replace(coalesce(ob.title_status, new.title_status)::text, '_', ' '), replace(new.management_mode::text, '_', ' '),
        (select string_agg(replace(x.method::text, '_', ' '), ', ') from app.onboarding_options(coalesce(ob.held_by, new.held_by), coalesce(ob.title_status, new.title_status), new.management_mode) x)
        using errcode = '23514';
    end if;
  end if;
  return new;
end $$;
create trigger vehicle_schedules_terms_rules before insert or update of insurance_fee_cents, onboarding_method on vehicle_schedules
  for each row execute function app.vehicle_schedules_terms_trg();

-- The method a car starts with when none was chosen: the recommended one, else Transfer (no CarmaCars registration), else
-- the only one open. Used by the screens' defaults (their copy in TypeScript) and the check below.
create function app.default_onboarding_method(p_held owner_type, p_title title_status, p_mode management_mode) returns onboarding_method
language sql stable security definer set search_path = public, app, pg_temp as $$
  select x.method from app.onboarding_options(p_held, p_title, p_mode) x
   order by x.recommended desc, (x.method = 'transfer') desc limit 1
$$;

-- ================================================================ 5. the Document check
-- Every inconsistency on an owner's documents, read from the records the documents are made of. p: owner_id (one owner).
create function app.owner_documents_check(p_by uuid, p jsonb default '{}'::jsonb) returns jsonb
language plpgsql stable security definer set search_path = public, app, pg_temp as $$
declare
  v_owner uuid := nullif(p ->> 'owner_id', '')::uuid;
  v_items jsonb;
begin
  if not app.user_is_admin(p_by) then raise exception 'Only an Admin runs the Document check' using errcode = '42501'; end if;
  with own as (
    select o.* from owners o where coalesce(o.kind, 'program') = 'program' and o.status <> 'exited' and not coalesce(o.is_test, false)
       and (v_owner is null or o.id = v_owner)),
  sched as (
    select s.*, v.owner_id, app.vehicle_name(v.id) as car, v.vin as v_vin, v.plate as v_plate, ob.held_by as ob_held, ob.title_status as ob_title
      from vehicle_schedules s join vehicles v on v.id = s.vehicle_id left join vehicle_onboardings ob on ob.vehicle_id = v.id
     where s.superseded_by is null and s.withdrawn_at is null and v.status not in ('declined', 'exited', 'total_loss') and v.owner_id in (select id from own)),
  issues as (
    -- the signing officer's title is a name, or missing
    select o.id as owner_id, null::uuid as vehicle_id, 'title_is_name' as code,
           format('The signing officer''s title is "%s", a name, not a role', o.signing_officer_title) as label, null::text as fix
      from own o where o.owner_type = 'corporation' and app.title_is_name(o.signing_officer_title, o.signing_officer_name, o.legal_name, o.first_name, o.last_name)
    union all
    select o.id, null, 'profile_missing', 'The agreements miss: ' || array_to_string(app.owner_master_missing(o.id), ', '), 'Ask the owner to complete the profile (Send reminder)'
      from own o where cardinality(app.owner_master_missing(o.id)) > 0
       and exists (select 1 from owner_agreements a where a.owner_id = o.id and a.status in ('draft', 'sent', 'signed'))
    union all
    select o.id, null, 'corporation_number', 'No corporation number on the agreements', 'Add it on the owner''s page'
      from own o where o.owner_type = 'corporation' and nullif(btrim(o.corporation_number), '') is null
       and exists (select 1 from owner_agreements a where a.owner_id = o.id and a.status in ('draft', 'sent', 'signed'))
    union all
    -- the method does not fit how the car is held
    select s.owner_id, s.vehicle_id, 'method_mismatch',
           format('%s (%s): %s does not fit a car held by %s (%s)', s.car, s.schedule_number, replace(s.onboarding_method::text, '_', ' '),
                  coalesce(s.ob_held, s.held_by), replace(coalesce(s.ob_title, s.title_status)::text, '_', ' ')),
           case when s.signed_at is null then 'Change the method (owner page, Terms)' else 'Signed: a corrected Vehicle Schedule needs the owner''s signature' end
      from sched s where s.onboarding_method <> 'none'
       and not exists (select 1 from app.onboarding_options(coalesce(s.ob_held, s.held_by), coalesce(s.ob_title, s.title_status), s.management_mode) x where x.method = s.onboarding_method)
    union all
    -- Co-Registrant: CarmaCars is added to the ownership; flagged while not signed so an Admin confirms it is meant
    select s.owner_id, s.vehicle_id, 'co_registrant_check',
           format('%s (%s): Co-Registrant means CarmaCars is added to the ownership at the registry. Confirm it, or change it to Transfer', s.car, s.schedule_number),
           'Change the method (owner page, Terms) if it is not meant'
      from sched s where s.onboarding_method = 'co_registrant' and s.signed_at is null
    union all
    -- first and last month off the rule (two months of the Insurance Fee)
    select s.owner_id, s.vehicle_id, 'first_last_rule',
           format('%s (%s): first and last month %s, the rule gives %s (two months of %s)', s.car, s.schedule_number, app.fmt_money(s.first_last_cents),
                  app.fmt_money(2 * s.insurance_fee_cents), app.fmt_money(s.insurance_fee_cents)),
           case when s.signed_at is null then 'Set it on the Terms tab (or leave it: it was agreed)' else 'Signed: as agreed' end
      from sched s where s.management_mode <> 'turo_only' and s.first_last_cents is not null and s.first_last_cents <> 2 * s.insurance_fee_cents
    union all
    -- a value the Vehicle Schedule prints empty
    select s.owner_id, s.vehicle_id, 'schedule_empty',
           format('%s (%s): no %s on the Vehicle Schedule', s.car, s.schedule_number, concat_ws(', ', case when nullif(btrim(s.v_plate), '') is null then 'plate' end,
                  case when s.odometer_km is null then 'odometer' end)),
           'Add it on the car''s page'
      from sched s where s.signed_at is null and (nullif(btrim(s.v_plate), '') is null or s.odometer_km is null)
    union all
    -- a signed Form D whose copy still waits to be filed again (3810)
    select r.owner_id, null, 'countersignature',
           format('%s: the signed copy is being filed again with the CarmaCars countersignature', r.title), 'Nothing to do: it is filed within minutes'
      from sign_requests r join own o on o.id = r.owner_id
     where r.doc_type = 'form_d' and r.status = 'signed' and r.signed_document_id is null
    union all
    -- insurance with HST on an issued invoice
    select i.owner_id, i.vehicle_id, 'insurance_hst',
           format('Invoice %s: HST on the Insurance Fee (%s)', i.invoice_number, app.fmt_money(l.hst_cents)), 'Finance: a credit note for the HST'
      from owner_invoices i join owner_invoice_lines l on l.owner_invoice_id = i.id join own o on o.id = i.owner_id
     where l.kind in ('insurance_fee', 'first_month_insurance', 'last_month_insurance') and coalesce(l.hst_cents, 0) <> 0 and i.status not in ('void', 'draft')
       and not coalesce((app.settings()).insurance_fee_hst, false))
  select coalesce(jsonb_agg(jsonb_build_object('owner_id', i.owner_id, 'name', coalesce(o.corporation_name, o.legal_name), 'vehicle_id', i.vehicle_id,
           'code', i.code, 'label', i.label, 'fix', i.fix) order by coalesce(o.corporation_name, o.legal_name), i.code), '[]'::jsonb)
    into v_items from issues i join owners o on o.id = i.owner_id;
  return jsonb_build_object('items', v_items, 'count', jsonb_array_length(v_items),
    'by_issue', (select coalesce(jsonb_object_agg(k, n), '{}'::jsonb) from (select x ->> 'code' k, count(*) n from jsonb_array_elements(v_items) x group by 1) z),
    'by_owner', (select coalesce(jsonb_agg(jsonb_build_object('owner_id', oid, 'name', nm, 'count', n) order by n desc, nm), '[]'::jsonb)
                   from (select x ->> 'owner_id' oid, x ->> 'name' nm, count(*) n from jsonb_array_elements(v_items) x group by 1, 2) z));
end $$;

-- ================================================================ the door and the connector
alter function app.door(uuid, text, text, text, jsonb) rename to door_pre3820;
create function app.door(p_user uuid, p_aal text, p_call text, p_name text, p jsonb default '{}'::jsonb) returns jsonb
language plpgsql security definer set search_path = public, app, pg_temp as $$
begin
  if p_call in ('ops_read', 'admin_read') and p_name = 'owner_documents_check' then
    perform app.door_begin(p_user, p_aal);
    return app.owner_documents_check(p_user, coalesce(p, '{}'::jsonb) - '_va');
  end if;
  return app.door_pre3820(p_user, p_aal, p_call, p_name, p);
end $$;
select pg_temp.copy_grants('app.door(uuid, text, text, text, jsonb)'::regprocedure, 'app.door_pre3820(uuid, text, text, text, jsonb)'::regprocedure);

alter function app.api_call(text, text, jsonb, text) rename to api_call_pre3820;
create function app.api_call(p_hash text, p_tool text, p_args jsonb, p_client text default null) returns jsonb
language plpgsql security definer set search_path = public, app, pg_temp as $$
declare
  a jsonb := case when jsonb_typeof(p_args) = 'object' then p_args else '{}'::jsonb end;
  chk jsonb;
  k api_keys;
  v_result jsonb;
begin
  if p_tool <> 'owner_documents_check' then return app.api_call_pre3820(p_hash, p_tool, p_args, p_client); end if;
  chk := app.api_key_check(p_hash, 'admin:read', p_tool, a, p_client);
  if not (chk ->> 'ok')::boolean then return chk; end if;
  k := jsonb_populate_record(null::api_keys, chk -> 'key');
  perform app.door_begin(k.user_id, 'aal2');
  begin
    v_result := app.owner_documents_check(k.user_id, a);
  exception when others then
    insert into api_calls (key_id, user_id, tool, target, args, ok, error, client) values (k.id, k.user_id, p_tool, p_tool, a, false, left(sqlerrm, 500), left(p_client, 64));
    return jsonb_build_object('ok', false, 'status', case sqlstate when 'P0002' then 404 when '42501' then 403 else 400 end, 'error', regexp_replace(sqlerrm, '^.*?ERROR:\s*', ''));
  end;
  insert into api_calls (key_id, user_id, tool, target, args, ok, client) values (k.id, k.user_id, p_tool, coalesce(a ->> 'owner_id', p_tool), a, true, left(p_client, 64));
  return jsonb_build_object('ok', true, 'result', v_result);
end $$;
select pg_temp.copy_grants('app.api_call(text, text, jsonb, text)'::regprocedure, 'app.api_call_pre3820(text, text, jsonb, text)'::regprocedure);

do $$
declare f record;
begin
  for f in select p.oid::regprocedure as sig from pg_proc p join pg_namespace n on n.oid = p.pronamespace
            where n.nspname = 'app' and p.proname = any (array['title_is_name', 'owners_title_trg', 'vehicle_schedules_terms_trg', 'default_onboarding_method',
              'owner_documents_check', 'door_pre3820', 'api_call_pre3820']) loop
    execute format('revoke all on function %s from public, anon, authenticated', f.sig);
    execute format('grant execute on function %s to service_role', f.sig);
  end loop;
end $$;

-- ================================================================ data fixes (every owner, every car)
-- the audit before the fixes, kept in the audit log
insert into audit_log (action, entity_table, entity_id, after)
select 'owner_documents_audit', 'owners', '3820', jsonb_build_object('before',
  (select jsonb_build_object('title_is_name', count(*) filter (where o.owner_type = 'corporation' and app.title_is_name(o.signing_officer_title, o.signing_officer_name, o.legal_name, o.first_name, o.last_name)))
     from owners o where coalesce(o.kind, 'program') = 'program'),
  'schedules', (select jsonb_build_object(
       'first_last_off_rule', count(*) filter (where s.first_last_cents is not null and s.first_last_cents <> 2 * s.insurance_fee_cents and s.management_mode <> 'turo_only'),
       'method_mismatch', count(*) filter (where s.onboarding_method <> 'none' and not exists (select 1 from vehicle_onboardings ob, app.onboarding_options(coalesce(ob.held_by, s.held_by), coalesce(ob.title_status, s.title_status), s.management_mode) x
                                                                                            where ob.vehicle_id = s.vehicle_id and x.method = s.onboarding_method)),
       'co_registrant_unsigned', count(*) filter (where s.onboarding_method = 'co_registrant' and s.signed_at is null))
     from vehicle_schedules s where s.superseded_by is null and s.withdrawn_at is null));

-- 1. a title that is a name: emptied where the agreement is not signed yet (the owner is asked for it)
update owners o set signing_officer_title = null
 where o.owner_type = 'corporation' and app.title_is_name(o.signing_officer_title, o.signing_officer_name, o.legal_name, o.first_name, o.last_name)
   and not exists (select 1 from owner_agreements a where a.owner_id = o.id and a.status = 'signed');
update owner_agreements a set corporate_signatory_title = null from owners o
 where o.id = a.owner_id and a.status in ('draft', 'sent') and o.signing_officer_title is null and app.title_is_name(a.corporate_signatory_title, o.signing_officer_name, o.legal_name, o.first_name, o.last_name);

-- 3. unsigned schedules: a first and last month off the rule with no first and last invoice issued follows the rule
update vehicle_schedules s set first_last_cents = null
 where s.superseded_by is null and s.signed_at is null and s.first_last_cents is not null and s.first_last_cents <> 2 * s.insurance_fee_cents
   and not exists (select 1 from owner_invoices i join owner_invoice_lines l on l.owner_invoice_id = i.id
                    where i.vehicle_id = s.vehicle_id and i.status <> 'void' and l.kind in ('first_month_insurance', 'last_month_insurance'));

-- 4. a draft invoice line of insurance with HST: no HST (the invoice's totals are made from its lines when it is issued)
update owner_invoice_lines l set hst_applies = false, hst_cents = 0 from owner_invoices i
 where i.id = l.owner_invoice_id and i.status = 'draft' and l.kind in ('insurance_fee', 'first_month_insurance', 'last_month_insurance')
   and coalesce(l.hst_cents, 0) <> 0 and not coalesce((app.settings()).insurance_fee_hst, false);
