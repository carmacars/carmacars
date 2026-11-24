-- 3800: sign first, then cars (Release 50, owners). docs/changes/2026-11-24-r50-sign-first.md. SCHEMA_MARKER 3820 (with the
-- guides of 3801 and the owner fixes of 3810 and 3820). No applied migration is edited: the functions it changes are wrapped (renamed with the suffix _pre3800).
--
-- Abbas, November 24, 2026: "The agreements should be signed before cars get transferred over ... make this process for
-- owners much more straightforward." Until now the Fleet Supplier Lease Agreement (and every owner's Enrollment Agreement)
-- was only made when an Admin set the terms of a first car: a supplier who signed up had nothing to sign.
--   1. Agreement at signup. Once the owner's profile has what the agreement needs (the legal or corporation name, the
--      address, the email and, for a corporation, the signing officer and title), the master agreement of their route is
--      made from it (app.owner_master_ensure): the Fleet Supplier Lease Agreement with the Title-Holding and Lease
--      Agreement for a fleet supplier (the default lease terms of Program settings, 0710), the Vehicle Enrollment
--      Agreement of the owner's pay model otherwise. No car is needed. The owner e-signs it in the portal at once (the
--      e-signature rules of 0193); CarmaCars countersigns automatically with the signing officer of Settings.
--   2. Cars go on Schedule A. A fleet supplier's car gets its numbered schedule entry the moment it is added (one at a
--      time, or the VIN list, which suppliers may now use with a tier and plate per row), and its ServiceOntario forms are
--      made then. A car added after the master is signed is confirmed by a short schedule confirmation (the Additional
--      Vehicle Schedule), e-signed per batch by both parties. A program owner's car gets its entry when an Admin sets its
--      terms (its fees are set then), as before.
--   3. Gates (Program setting owner_sign_first, on). A car cannot be approved (a supplier's application), delivered (go on
--      the lease) or rented (go live: available or on rent) until the master agreement and its schedule entry are signed.
--      An Admin's approval of a supplier's car that waits for a signature is kept and goes through by itself the moment
--      the supplier signs (approval, delivery and handover then just happen). app.owner_sign_status says exactly what is
--      missing; Send reminder (Admin, customer service, Fleet) emails it with the in-app notice and the push.
--   4. The owner portal's guided path reads app.owner_sign_status (the website draws the six steps).
--   5. Backfill: every owner without a master agreement whose profile is complete gets one now, waiting for the
--      signature, and is told. A supplier's cars still in intake get their schedule entries and forms.
--   6. Notices (email, in-app, push): owner_master_agreement_ready, owner_schedule_ready, owner_sign_reminder,
--      owner_car_delivered (the owner) and staff_owner_signed (Fleet and the Admins).
--   7. The Admin connector: owner_agreements (read) and send_owner_agreement_reminder (preview, then confirm).
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

-- ================================================================ 1. settings and records
alter table program_settings add column if not exists owner_sign_first boolean not null default true;
comment on column program_settings.owner_sign_first is 'Sign first (3800): an owner''s master agreement is made as soon as their profile is complete, and a car is approved, delivered or rented only once the master agreement and its Schedule A entry are signed. On by default.';

alter table owner_applications add column if not exists sign_wait_at timestamptz,
  add column if not exists sign_wait_by uuid references users (id) on delete set null,
  add column if not exists sign_wait_args jsonb check (sign_wait_args is null or jsonb_typeof(sign_wait_args) = 'object');
comment on column owner_applications.sign_wait_at is 'Sign first (3800): an Admin approved this fleet supplier application before the supplier signed; it goes through by itself (as sign_wait_by, with sign_wait_args) the moment the master agreement and every car''s schedule entry are signed.';

insert into task_rules (task_type, queue, title, priority, due_kind, due_amount, procedure_no, completion_rule, description) values
  ('owner_sign_release_failed', 'admin', 'Approve a signed supplier''s cars', 'high', 'opening_minutes', 120, 2, null,
   'A fleet supplier signed (3800, sign first) and the approval an Admin made before the signature could not go through by itself. Open the application and approve it again: the reason is in the To do.')
on conflict (task_type) do nothing;

-- ================================================================ 2. the route's agreement set
-- A fleet supplier's cars are all on the fleet lease, from signup: the agreement set is the fleet lease one before any car is
-- on the lease (0640's pay model looked at the lease periods only, so a supplier's first agreement was made standard).
alter function app.owner_pay_model(uuid) rename to owner_pay_model_pre3800;
create function app.owner_pay_model(p_owner uuid) returns text
language sql stable security definer set search_path = public, app, pg_temp as $$
  select case when app.fleet_supplier(p_owner) then 'fleet_lease' else app.owner_pay_model_pre3800(p_owner) end
$$;
select pg_temp.copy_grants('app.owner_pay_model(uuid)'::regprocedure, 'app.owner_pay_model_pre3800(uuid)'::regprocedure);

create function app.agreement_title(p_kind text, p_variant text) returns text
language sql immutable set search_path = public, app, pg_temp as $$
  select case when p_kind = 'title_holding' then 'Title-Holding and Lease Agreement'
              when p_variant = 'fleet_lease' then 'Fleet Supplier Lease Agreement'
              when p_variant = 'flat_rate' then 'Flat-Rate Vehicle Enrollment Agreement' else 'Vehicle Enrollment Agreement' end
$$;

-- What the master agreement needs from the profile (the cover page): the parties, the address, the notice email, and who
-- signs for a corporation. The licence and date of birth are asked later (the government forms), never here.
create function app.owner_master_missing(p_owner uuid) returns text[]
language sql stable security definer set search_path = public, app, pg_temp as $$
  select coalesce(array_agg(x.label order by x.ord) filter (where x.missing), '{}')
    from owners o,
         lateral (values
           (1, 'Legal name', nullif(btrim(o.legal_name), '') is null),
           (2, 'Street address', nullif(btrim(o.address_line1), '') is null),
           (3, 'City', nullif(btrim(o.city), '') is null),
           (4, 'Postal code', nullif(btrim(o.postal_code), '') is null),
           (5, 'Email', nullif(btrim(o.email), '') is null),
           (6, 'Corporation name', o.owner_type = 'corporation' and nullif(btrim(o.corporation_name), '') is null),
           (7, 'Signing officer name', o.owner_type = 'corporation' and nullif(btrim(o.signing_officer_name), '') is null),
           (8, 'Signing officer title', o.owner_type = 'corporation' and nullif(btrim(o.signing_officer_title), '') is null)
         ) x(ord, label, missing)
   where o.id = p_owner
$$;

create function app.owner_first_name(o owners) returns text
language sql immutable set search_path = public, app, pg_temp as $$
  select coalesce(nullif(btrim(o.first_name), ''), nullif(split_part(btrim(coalesce(o.signing_officer_name, o.legal_name, '')), ' ', 1), ''), 'there')
$$;

-- ================================================================ 3. the master agreement at signup
-- Made once the profile is complete, for an owner of the program (not a partner, not CarmaCars' own record, not one who
-- left). Idempotent: an existing agreement is kept (its set follows the pay model, 0205). The owner is told once per agreement.
create function app.owner_master_ensure(p_owner uuid, p_by uuid default null) returns jsonb
language plpgsql security definer set search_path = public, app, pg_temp as $$
declare
  o owners;
  ea owner_agreements;
  ta owner_agreements;
  v_fleet boolean;
  v_missing text[];
  v_made boolean := false;
  v_model text;
  v_base text := rtrim(coalesce((app.settings()).notify_base_url, 'https://carmacars.ca'), '/');
begin
  select * into o from owners where id = p_owner;
  if o.id is null or coalesce(o.kind, 'program') <> 'program' or o.status = 'exited' then
    return jsonb_build_object('made', false, 'reason', 'not an owner of the program');
  end if;
  if not coalesce((app.settings()).owner_sign_first, true) then return jsonb_build_object('made', false, 'reason', 'sign first is off'); end if;
  v_missing := app.owner_master_missing(o.id);
  if cardinality(v_missing) > 0 then return jsonb_build_object('made', false, 'missing', to_jsonb(v_missing)); end if;
  v_fleet := app.fleet_supplier(o.id);
  if v_fleet then
    -- the lease terms the agreement shows: the defaults of Program settings (kept when the supplier has terms)
    begin
      perform app.fleet_supplier_setup(o.id, p_by);
    exception when others then
      raise notice 'fleet supplier setup of %: %', o.id, sqlerrm;
    end;
  end if;
  v_model := app.owner_pay_model(o.id);
  select * into ea from owner_agreements where owner_id = o.id and kind = 'enrollment' and status in ('draft', 'sent', 'signed') for update;
  if ea.id is null then
    insert into owner_agreements (owner_id, kind, agreement_number, status, variant, corporate_signatory_name, corporate_signatory_title)
    values (o.id, 'enrollment', 'EA-' || nextval('owner_agreement_number_seq'), 'draft', v_model,
            case when o.owner_type = 'corporation' then o.signing_officer_name end, case when o.owner_type = 'corporation' then o.signing_officer_title end)
    returning * into ea;
    v_made := true;
  elsif ea.status <> 'signed' and ea.variant is distinct from v_model then
    perform app.owner_agreement_set_sync(o.id);
    select * into ea from owner_agreements where owner_id = o.id and kind = 'enrollment' and status in ('draft', 'sent', 'signed');
    -- the set changed before the owner signed (the route chosen after the profile): the notice names the right agreement
    if ea.status <> 'signed' and exists (select 1 from app_events e where e.code = 'owner_master_agreement_ready' and e.entity_id = o.id) then
      update app_events set processed_at = now(), process_note = 'replaced: the agreement set changed before it was sent (3800)'
       where code = 'owner_master_agreement_ready' and entity_id = o.id and processed_at is null;
      v_made := true;
    end if;
  end if;
  if ea.status <> 'signed' and o.owner_type = 'corporation'
     and (ea.corporate_signatory_name, ea.corporate_signatory_title) is distinct from (o.signing_officer_name, o.signing_officer_title) then
    update owner_agreements set corporate_signatory_name = o.signing_officer_name, corporate_signatory_title = o.signing_officer_title where id = ea.id;
  end if;
  -- a supplier's fleet lease relies on the Title-Holding and Lease Agreement (every car Managed, held by the corporation)
  if v_fleet then
    select * into ta from owner_agreements where owner_id = o.id and kind = 'title_holding' and status in ('draft', 'sent', 'signed');
    if ta.id is null then
      insert into owner_agreements (owner_id, kind, agreement_number, status, corporate_signatory_name, corporate_signatory_title)
      values (o.id, 'title_holding', 'TA-' || nextval('owner_agreement_number_seq'), 'draft', o.signing_officer_name, o.signing_officer_title)
      returning * into ta;
    end if;
  end if;
  if v_made then
    perform app.ntf_emit('owner_master_agreement_ready', 'owner', o.id, ea.id || ':' || ea.variant, jsonb_build_object('owner_id', o.id,
      'first_name', app.owner_first_name(o), 'agreement_title', app.agreement_title('enrollment', ea.variant), 'agreement_number', ea.agreement_number,
      'signer', case when o.owner_type = 'corporation' then concat_ws(', ', o.signing_officer_name, o.signing_officer_title) || ', for ' || coalesce(o.corporation_name, o.legal_name) else o.legal_name end,
      'sign_url', v_base || '/owner/sign'));
    insert into audit_log (actor_user_id, action, entity_table, entity_id, after)
    values (p_by, 'owner_master_agreement_made', 'owner_agreements', ea.id::text, jsonb_build_object('owner_id', o.id, 'variant', ea.variant,
            'number', ea.agreement_number, 'title_holding', ta.agreement_number, 'reason', 'Sign first (3800): the profile is complete'));
  end if;
  return jsonb_build_object('made', v_made, 'agreement_id', ea.id, 'number', ea.agreement_number, 'variant', ea.variant, 'status', ea.status,
                            'title_holding', ta.agreement_number);
end $$;

-- At the end of the transaction that made or changed the owner (deferred: the application sets the route after the owner
-- row, so the agreement is made of the final record). Never fails the change it follows.
create function app.owner_master_trg() returns trigger
language plpgsql security definer set search_path = public, app, pg_temp as $$
begin
  begin
    perform app.owner_master_ensure(new.id, null);
  exception when others then
    raise warning 'sign first: the master agreement of owner % was not made: %', new.id, sqlerrm;
  end;
  return null;
end $$;
create constraint trigger owners_master_agreement
  after insert or update of legal_name, corporation_name, address_line1, city, postal_code, email, signing_officer_name, signing_officer_title,
                            onboarding_route, owner_type, kind, status on owners
  deferrable initially deferred for each row execute function app.owner_master_trg();

-- ================================================================ 4. a supplier's car on Schedule A at once
-- Each car of a fleet supplier still in intake gets its schedule entry (Managed, no fees, the lease at its tier) and its
-- forms. Internal: called where cars are added and by the backfill.
create function app.fleet_schedule_cars(p_owner uuid, p_by uuid default null) returns integer
language plpgsql security definer set search_path = public, app, pg_temp as $$
declare
  r record;
  n integer := 0;
begin
  if not app.fleet_supplier(p_owner) or not coalesce((app.settings()).owner_sign_first, true) then return 0; end if;
  perform app.owner_master_ensure(p_owner, p_by);
  for r in select v.id, ob.lease_tier from vehicles v join vehicle_onboardings ob on ob.vehicle_id = v.id
            where v.owner_id = p_owner and ob.status = 'intake' and ob.lease_tier is not null
              and v.status not in ('declined', 'exited', 'total_loss')
              and not exists (select 1 from vehicle_schedules s where s.vehicle_id = v.id and s.superseded_by is null)
            order by v.created_at loop
    perform app.apply_vehicle_terms(r.id, jsonb_build_object('management_mode', 'managed', 'onboarding_method', 'lease_existing_corporation',
      'insurance_fee_cents', 0, 'tracker_fee_cents', 0, 'revenue_share_bps', 0, 'install_fee_cents', 0,
      'special_terms', 'Fleet Supplier Lease Agreement: leased at the ' || initcap(r.lease_tier) || ' rate; no fees'), p_by, null);
    perform app.fleet_supplier_car_forms(r.id);
    n := n + 1;
  end loop;
  return n;
end $$;

alter function app.submit_owner_application(jsonb, uuid) rename to submit_owner_application_pre3800;
create function app.submit_owner_application(p jsonb, p_by uuid default null) returns jsonb
language plpgsql security definer set search_path = public, app, pg_temp as $$
declare
  v_out jsonb := app.submit_owner_application_pre3800(p, p_by);
  v_owner uuid := coalesce(nullif(v_out ->> 'owner_id', '')::uuid, (select a.owner_id from owner_applications a where a.id = nullif(v_out ->> 'application_id', '')::uuid));
  n integer;
begin
  if v_owner is null then return v_out; end if;
  perform app.owner_master_ensure(v_owner, p_by);
  n := app.fleet_schedule_cars(v_owner, p_by);
  return v_out || jsonb_build_object('scheduled', n);
end $$;
select pg_temp.copy_grants('app.submit_owner_application(jsonb, uuid)'::regprocedure, 'app.submit_owner_application_pre3800(jsonb, uuid)'::regprocedure);

-- The VIN list (0824) for a fleet supplier too: each row with its tier and plate. The cars are registered to the
-- supplier's corporation (a car moving in from a person or a seller is added one at a time, with the transfer).
alter function app.owner_add_vins(uuid, jsonb) rename to owner_add_vins_pre3800;
create function app.owner_add_vins(p_by uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app, pg_temp as $$
declare
  o owners;
  x jsonb;
  v_vin text;
  v_seen text[] := '{}';
  d vin_decodes;
  v_why text;
  v_taken text;
  v_tier text;
  v_plate text;
  v_rows jsonb := '[]'::jsonb;
  v_cars jsonb := '[]'::jsonb;
  v_staff boolean;
  res jsonb;
  n integer := 0;
begin
  select * into o from owners where id = nullif(p ->> 'owner_id', '')::uuid;
  if o.id is null or not app.fleet_supplier(o.id) then return app.owner_add_vins_pre3800(p_by, p); end if;
  v_staff := app.user_is_admin(p_by) or app.user_va_has(p_by, 'cs', 'fleet');
  if not v_staff and not app.user_is_owner_of(p_by, o.id) then
    raise exception 'Not permitted: an owner adds cars to their own account; staff add them on the owner''s page' using errcode = '42501';
  end if;
  if jsonb_typeof(coalesce(p -> 'cars', 'null')) <> 'array' or jsonb_array_length(p -> 'cars') = 0 then raise exception 'Paste or upload at least one VIN' using errcode = '22023'; end if;
  if jsonb_array_length(p -> 'cars') > 50 then raise exception 'At most 50 VINs at a time' using errcode = '22023'; end if;
  for x in select * from jsonb_array_elements(p -> 'cars') loop
    v_vin := app.clean_vin(upper(regexp_replace(coalesce(x ->> 'vin', ''), '[\s-]', '', 'g')));
    v_tier := nullif(lower(btrim(coalesce(x ->> 'lease_tier', ''))), '');
    v_plate := nullif(upper(btrim(coalesce(x ->> 'plate', ''))), '');
    v_why := null; v_taken := null; d := null;
    if v_vin is null then v_why := 'Not a VIN: 17 letters and digits, never I, O or Q';
    elsif not app.vin_check_ok(v_vin) then v_why := 'The check digit (the 9th character) does not match: check the VIN for a typo';
    elsif v_vin = any (v_seen) then v_why := 'Listed twice';
    else
      select app.vehicle_name(z.id) into v_taken from vehicles z where upper(z.vin) = v_vin limit 1;
      select * into d from vin_decodes z where z.vin = v_vin and z.ok order by z.decoded_at desc limit 1;
      if v_taken is not null then v_why := 'Already with CarmaCars: ' || v_taken;
      elsif d.id is null or d.year is null or nullif(btrim(coalesce(d.make, '')), '') is null or nullif(btrim(coalesce(d.model, '')), '') is null then
        v_why := 'The year, make and model could not be read from this VIN: add the car with Add a car';
      elsif not coalesce((p ->> 'preview')::boolean, false) and (v_tier is null or v_tier not in ('regular', 'troubled')) then v_why := 'Mark it Regular or Troubled';
      elsif not coalesce((p ->> 'preview')::boolean, false) and v_plate is null then v_why := 'Enter its plate';
      end if;
    end if;
    if v_vin is not null then v_seen := v_seen || v_vin; end if;
    v_rows := v_rows || jsonb_build_array(jsonb_strip_nulls(jsonb_build_object('vin', coalesce(v_vin, x ->> 'vin'), 'ok', v_why is null, 'why', v_why,
      'year', d.year, 'make', d.make, 'model', d.model, 'trim', app.decode_trim(d.trim), 'lease_tier', v_tier, 'plate', v_plate)));
    if v_why is null then
      v_cars := v_cars || jsonb_build_array(jsonb_strip_nulls(jsonb_build_object('vin', v_vin, 'year', d.year, 'make', d.make, 'model', d.model,
        'trim', app.decode_trim(d.trim), 'plate', v_plate, 'lease_tier', v_tier, 'fleet_transfer', jsonb_build_object('registered_to', 'corporation'))));
      n := n + 1;
    end if;
  end loop;
  if coalesce((p ->> 'preview')::boolean, false) or n = 0 then
    return jsonb_build_object('preview', true, 'fleet', true, 'rows', v_rows, 'good', n, 'bad', jsonb_array_length(v_rows) - n);
  end if;
  res := app.submit_owner_application(jsonb_build_object('owner_id', o.id, 'vehicles', v_cars, 'source', case when v_staff then 'staff' else 'web' end,
           'note', format('Added from a VIN list (%s car%s)', n, case when n = 1 then '' else 's' end)), p_by);
  if v_staff then
    update owner_applications set entered_by = p_by, entered_by_name = (select coalesce(u.full_name, u.email) from users u where u.id = p_by)
     where id = (res ->> 'application_id')::uuid;
  end if;
  insert into audit_log (actor_user_id, action, entity_table, entity_id, after)
  values (p_by, 'owner_add_vins', 'owner_applications', res ->> 'application_id', jsonb_build_object('owner_id', o.id, 'made', n, 'fleet', true,
          'vins', (select jsonb_agg(c ->> 'vin') from jsonb_array_elements(v_cars) c)));
  return jsonb_build_object('preview', false, 'fleet', true, 'rows', v_rows, 'good', n, 'bad', jsonb_array_length(v_rows) - n,
    'application_id', res ->> 'application_id', 'application_number', res ->> 'application_number',
    'vehicles', (select coalesce(jsonb_agg(jsonb_build_object('vehicle_id', z ->> 'vehicle_id', 'vin', z ->> 'vin')), '[]'::jsonb) from jsonb_array_elements(res -> 'vehicles') z));
end $$;
select pg_temp.copy_grants('app.owner_add_vins(uuid, jsonb)'::regprocedure, 'app.owner_add_vins_pre3800(uuid, jsonb)'::regprocedure);

-- ================================================================ 5. what is missing, and the gates
-- Each thing still missing before the owner's cars can move: [{code, label, who (owner | carmacars), vehicle_id}].
-- p_vehicle: that car only (with the master); null: every car still onboarding.
create function app.owner_sign_missing(p_owner uuid, p_vehicle uuid default null) returns jsonb
language plpgsql stable security definer set search_path = public, app, pg_temp as $$
declare
  o owners;
  ea owner_agreements;
  ta owner_agreements;
  v_out jsonb := '[]'::jsonb;
  v_missing text[];
  v_ta_needed boolean;
  r record;
begin
  select * into o from owners where id = p_owner;
  if o.id is null then return v_out; end if;
  select * into ea from owner_agreements where owner_id = o.id and kind = 'enrollment' and status in ('draft', 'sent', 'signed');
  select * into ta from owner_agreements where owner_id = o.id and kind = 'title_holding' and status in ('draft', 'sent', 'signed');
  if ea.id is null then
    v_missing := app.owner_master_missing(o.id);
    v_out := v_out || jsonb_build_array(case when cardinality(v_missing) > 0
      then jsonb_build_object('code', 'profile', 'who', 'owner', 'label', 'Complete the profile: ' || array_to_string(v_missing, ', '))
      else jsonb_build_object('code', 'master', 'who', 'carmacars', 'label', 'The ' || app.agreement_title('enrollment', app.owner_pay_model(o.id)) || ' is not made yet') end);
  elsif ea.status <> 'signed' then
    v_out := v_out || jsonb_build_array(jsonb_build_object('code', 'master', 'who', 'owner', 'number', ea.agreement_number,
      'label', format('Sign the %s (%s)', app.agreement_title('enrollment', ea.variant), ea.agreement_number)));
  end if;
  v_ta_needed := app.fleet_supplier(o.id) or exists (
    select 1 from vehicles v left join vehicle_schedules s on s.vehicle_id = v.id and s.superseded_by is null
     where v.owner_id = o.id and (p_vehicle is null or v.id = p_vehicle) and v.status not in ('declined', 'exited', 'total_loss')
       and coalesce(s.management_mode, v.management_mode) <> 'turo_only');
  if v_ta_needed and ta.id is not null and ta.status <> 'signed' then
    v_out := v_out || jsonb_build_array(jsonb_build_object('code', 'title_holding', 'who', 'owner', 'number', ta.agreement_number,
      'label', format('Sign the Title-Holding and Lease Agreement (%s)', ta.agreement_number)));
  end if;
  for r in select v.id, app.vehicle_name(v.id) as name, v.plate, s.schedule_number, s.signed_at, s.id as sid, ob.status as ob_status
             from vehicles v left join vehicle_onboardings ob on ob.vehicle_id = v.id
             left join vehicle_schedules s on s.vehicle_id = v.id and s.superseded_by is null and s.withdrawn_at is null
            where v.owner_id = o.id and (p_vehicle is null or v.id = p_vehicle)
              and v.status not in ('declined', 'exited', 'total_loss') and coalesce(ob.status::text, '') not in ('declined', 'withdrawn')
              and (p_vehicle is not null or coalesce(ob.status::text, 'enrolled') <> 'enrolled')
            order by v.created_at loop
    if r.sid is null then
      v_out := v_out || jsonb_build_array(jsonb_build_object('code', 'schedule', 'who', 'carmacars', 'vehicle_id', r.id,
        'label', format('%s%s: its Schedule A entry is made when its terms are set', r.name, coalesce(' (' || r.plate || ')', ''))));
    elsif r.signed_at is null then
      v_out := v_out || jsonb_build_array(jsonb_build_object('code', 'schedule', 'who', 'owner', 'vehicle_id', r.id, 'number', r.schedule_number,
        'label', format('Confirm %s%s on Schedule A (%s)', r.name, coalesce(' (' || r.plate || ')', ''), r.schedule_number)));
    end if;
  end loop;
  return v_out;
end $$;

-- The gate of one car: null when it may move, else the reason. Only cars of the owner program (not CarmaCars' own, not a
-- partner's, not a sample) and only while the setting is on.
create function app.owner_sign_gate(p_vehicle uuid) returns text
language plpgsql stable security definer set search_path = public, app, pg_temp as $$
declare
  v vehicles;
  o owners;
  m jsonb;
begin
  if not coalesce((app.settings()).owner_sign_first, true) then return null; end if;
  select * into v from vehicles where id = p_vehicle;
  if v.id is null or coalesce(v.is_sample, false) or coalesce(v.supply_type::text, 'program_owner') <> 'program_owner' then return null; end if;
  select * into o from owners where id = v.owner_id;
  if o.id is null or coalesce(o.kind, 'program') <> 'program' then return null; end if;
  m := app.owner_sign_missing(o.id, v.id);
  if jsonb_array_length(m) = 0 then return null; end if;
  return format('%s waits for the owner''s signature: %s', app.vehicle_name(v.id), (select string_agg(x ->> 'label', '; ') from jsonb_array_elements(m) x));
end $$;

-- rented: a car of the program goes live (available or on rent) only once signed
create function app.vehicles_sign_gate_trg() returns trigger
language plpgsql security definer set search_path = public, app, pg_temp as $$
declare v_why text;
begin
  if old.status in ('onboarding', 'ready_to_list') and new.status in ('available', 'on_rent') then
    v_why := app.owner_sign_gate(new.id);
    if v_why is not null then raise exception '%', v_why using errcode = '23514'; end if;
  end if;
  return new;
end $$;
create trigger vehicles_sign_gate before update of status on vehicles for each row execute function app.vehicles_sign_gate_trg();

-- delivered: a fleet supplier's car goes on the lease only once signed
alter function app.fleet_lease_car_set(uuid, jsonb) rename to fleet_lease_car_set_pre3800;
create function app.fleet_lease_car_set(p_by uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app, pg_temp as $$
declare
  v vehicles;
  v_why text;
  v_out jsonb;
  o owners;
  t owner_fleet_lease_terms;
begin
  select * into v from vehicles where id = nullif(p ->> 'vehicle_id', '')::uuid;
  if v.id is not null and app.fleet_supplier(v.owner_id) and app.fleet_delivered_on(v.id) is null then
    v_why := app.owner_sign_gate(v.id);
    if v_why is not null then raise exception '%', v_why using errcode = '23514'; end if;
  end if;
  v_out := app.fleet_lease_car_set_pre3800(p_by, p);
  if coalesce((v_out ->> 'done')::boolean, false) and app.fleet_supplier(v.owner_id) then
    select * into o from owners where id = v.owner_id;
    t := app.fleet_terms_on(v.owner_id, (v_out ->> 'from')::date);
    perform app.ntf_emit('owner_car_delivered', 'vehicle', v.id, 'lease', jsonb_build_object('owner_id', o.id, 'vehicle_id', v.id,
      'first_name', app.owner_first_name(o), 'vehicle_name', app.vehicle_name(v.id), 'tier', initcap(v_out ->> 'tier'),
      'monthly_amount', app.fmt_money((v_out ->> 'monthly_cents')::bigint), 'delivered_on', app.fmt_day((v_out ->> 'from')::date),
      'first_payment_on', app.fmt_day(app.payout_date(app.fleet_first_pay_month((v_out ->> 'from')::date)))));
  end if;
  return v_out;
end $$;
select pg_temp.copy_grants('app.fleet_lease_car_set(uuid, jsonb)'::regprocedure, 'app.fleet_lease_car_set_pre3800(uuid, jsonb)'::regprocedure);

-- approved: a supplier's application is approved only once signed. An Admin's approval before the signature is kept and
-- goes through by itself when the supplier signs (app.sign_first_release). Its cars then go on the lease at their tier.
alter function app.application_approve(uuid, jsonb) rename to application_approve_pre3800;
create function app.application_approve(p_admin uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app, pg_temp as $$
declare
  a owner_applications;
  m jsonb := '[]'::jsonb;
  r record;
  c jsonb;
  v_out jsonb;
  v_lease jsonb := '[]'::jsonb;
  v_on text;
begin
  select * into a from owner_applications where id = nullif(p ->> 'id', '')::uuid;
  if a.id is null or a.status in ('approved', 'declined') or not app.fleet_supplier(a.owner_id) or not coalesce((app.settings()).owner_sign_first, true) then
    return app.application_approve_pre3800(p_admin, p);
  end if;
  perform app.assert_admin(p_admin);
  perform app.fleet_schedule_cars(a.owner_id, p_admin);
  for r in select v.id from vehicles v join vehicle_onboardings ob on ob.vehicle_id = v.id
            where v.owner_id = a.owner_id and (ob.application_id = a.id or (ob.status = 'intake' and ob.application_id is null))
              and v.status not in ('declined', 'exited', 'total_loss') order by v.created_at loop
    m := m || app.owner_sign_missing(a.owner_id, r.id);
  end loop;
  m := (select coalesce(jsonb_agg(distinct x), '[]'::jsonb) from jsonb_array_elements(m) x);
  -- only a step of CarmaCars missing (a car without its tier): the approval says what (0710's checks)
  if exists (select 1 from jsonb_array_elements(m) x where x ->> 'who' = 'owner') then
    update owner_applications set sign_wait_at = now(), sign_wait_by = p_admin, sign_wait_args = p - 'confirm' where id = a.id;
    insert into owner_application_notes (application_id, body, kind, created_by)
    values (a.id, 'Approved, waiting for the supplier''s signature: it goes through by itself once signed. Missing: '
                  || (select string_agg(x ->> 'label', '; ') from jsonb_array_elements(m) x), 'note', p_admin);
    return jsonb_build_object('id', a.id, 'status', a.status, 'waiting_for_signature', true, 'missing', m,
      'message', 'Approved: it goes through by itself the moment the supplier signs. Still missing: ' || (select string_agg(x ->> 'label', '; ') from jsonb_array_elements(m) x));
  end if;
  v_out := app.application_approve_pre3800(p_admin, p);
  update owner_applications set sign_wait_at = null, sign_wait_by = null, sign_wait_args = null where id = a.id and sign_wait_at is not null;
  -- the cars of the application that are not on the lease yet (their schedule entry was made when they were added)
  for r in select v.id, ob.lease_tier from vehicles v join vehicle_onboardings ob on ob.vehicle_id = v.id
            where ob.application_id = a.id and ob.lease_tier is not null and v.status not in ('declined', 'exited', 'total_loss') order by v.created_at loop
    continue when app.fleet_delivered_on(r.id) is not null;
    c := (select x from jsonb_array_elements(coalesce(p -> 'cars', '[]'::jsonb)) x where x ->> 'vehicle_id' = r.id::text limit 1);
    v_on := coalesce(nullif(c ->> 'delivered_on', ''), nullif(p ->> 'delivered_on', ''), app.today()::text);
    v_lease := v_lease || jsonb_build_array(app.fleet_lease_car_set(p_admin, jsonb_build_object('vehicle_id', r.id, 'tier', r.lease_tier,
      'delivered_on', v_on, 'reason', 'Onboarded: approved')) || jsonb_build_object('vehicle_id', r.id));
    perform app.fleet_supplier_car_forms(r.id);
  end loop;
  return v_out || jsonb_build_object('fleet_lease', coalesce(v_out -> 'fleet_lease', '[]'::jsonb) || v_lease);
end $$;
select pg_temp.copy_grants('app.application_approve(uuid, jsonb)'::regprocedure, 'app.application_approve_pre3800(uuid, jsonb)'::regprocedure);

-- the approval page says what still waits for the supplier
alter function app.application_approve_plan(uuid, jsonb) rename to application_approve_plan_pre3800;
create function app.application_approve_plan(p_by uuid, p jsonb) returns jsonb
language plpgsql stable security definer set search_path = public, app, pg_temp as $$
declare
  v jsonb := app.application_approve_plan_pre3800(p_by, p);
  a owner_applications;
begin
  select * into a from owner_applications where id = nullif(p ->> 'id', '')::uuid;
  if a.id is null then return v; end if;
  return v || jsonb_build_object('sign_missing', app.owner_sign_missing(a.owner_id), 'sign_wait_at', a.sign_wait_at);
end $$;
select pg_temp.copy_grants('app.application_approve_plan(uuid, jsonb)'::regprocedure, 'app.application_approve_plan_pre3800(uuid, jsonb)'::regprocedure);

-- ================================================================ 6. after a signature
-- At the end of the transaction that signed (deferred): Fleet and the Admins hear what was signed and what comes next,
-- and an approval waiting for this signature goes through. A failed approval becomes an Admin To do; the signature stands.
create function app.sign_first_release(p_owner uuid) returns jsonb
language plpgsql security definer set search_path = public, app, pg_temp as $$
declare
  a owner_applications;
  v_done jsonb := '[]'::jsonb;
begin
  for a in select * from owner_applications where owner_id = p_owner and sign_wait_at is not null and status not in ('approved', 'declined') order by created_at loop
    begin
      if not app.user_is_admin(a.sign_wait_by) then raise exception 'the Admin who approved it is no longer an Admin'; end if;
      perform app.application_approve(a.sign_wait_by, coalesce(a.sign_wait_args, '{}'::jsonb) || jsonb_build_object('id', a.id));
      if (select status from owner_applications where id = a.id) = 'approved' then v_done := v_done || to_jsonb(a.application_number); end if;
    exception when others then
      update owner_applications set sign_wait_at = null where id = a.id;
      perform app.raise_task(p_type => 'owner_sign_release_failed', p_queue => 'admin', p_owner => a.owner_id,
        p_title => format('Approve %s again: the supplier signed', a.application_number),
        p_detail => format('The supplier signed; the approval you made before could not go through by itself: %s', sqlerrm),
        p_related_table => 'owner_applications', p_related_id => a.id, p_dedupe => 'owner_sign_release_failed:' || a.id);
    end;
  end loop;
  return v_done;
end $$;

create function app.sign_first_after(p_owner uuid) returns void
language plpgsql security definer set search_path = public, app, pg_temp as $$
declare
  o owners;
  v_what text;
  v_done jsonb;
  m jsonb;
  v_disc text := 'tx' || txid_current();
begin
  select * into o from owners where id = p_owner;
  if o.id is null then return; end if;
  select string_agg(x, ', ') into v_what from (
    select format('%s %s', app.agreement_title(a.kind, a.variant), a.agreement_number) as x from owner_agreements a
     where a.owner_id = o.id and a.status = 'signed' and a.updated_at >= now() - interval '1 second'
    union all
    select format('Schedule A: %s', string_agg(app.vehicle_name(s.vehicle_id), ', ')) from vehicle_schedules s join vehicles v on v.id = s.vehicle_id
     where v.owner_id = o.id and s.signed_at >= now() - interval '1 second' and s.superseded_by is null
    having count(*) > 0) z;
  if v_what is null then return; end if;
  v_done := app.sign_first_release(o.id);
  m := app.owner_sign_missing(o.id);
  perform app.ntf_emit('staff_owner_signed', 'owner', o.id, v_disc, jsonb_build_object('owner_id', o.id,
    'owner_name', coalesce(o.corporation_name, o.legal_name), 'what', v_what,
    'next_step', case when jsonb_array_length(v_done) > 0 then format('Approved by itself (%s): the cars are on the lease.', (select string_agg(x #>> '{}', ', ') from jsonb_array_elements(v_done) x))
                      when exists (select 1 from jsonb_array_elements(m) x where x ->> 'who' = 'owner') then 'Still to sign: ' || (select string_agg(x ->> 'label', '; ') from jsonb_array_elements(m) x where x ->> 'who' = 'owner')
                      when not exists (select 1 from vehicles v where v.owner_id = o.id and v.status not in ('declined', 'exited', 'total_loss')) then 'No car yet: the owner adds them next.'
                      else 'Check the photos and approve the cars.' end));
end $$;

create function app.sign_first_signed_trg() returns trigger
language plpgsql security definer set search_path = public, app, pg_temp as $$
declare v_owner uuid;
begin
  if tg_table_name = 'owner_agreements' then
    if new.status <> 'signed' then return null; end if;
    v_owner := new.owner_id;
  else
    if new.signed_at is null then return null; end if;
    select owner_id into v_owner from vehicles where id = new.vehicle_id;
  end if;
  begin
    perform app.sign_first_after(v_owner);
  exception when others then
    raise warning 'sign first: after the signature of owner %: %', v_owner, sqlerrm;
  end;
  return null;
end $$;
create constraint trigger owner_agreements_sign_first after update of status on owner_agreements
  deferrable initially deferred for each row when (new.status = 'signed' and old.status is distinct from 'signed')
  execute function app.sign_first_signed_trg();
create constraint trigger vehicle_schedules_sign_first after update of signed_at on vehicle_schedules
  deferrable initially deferred for each row when (new.signed_at is not null and old.signed_at is null)
  execute function app.sign_first_signed_trg();

-- new cars on Schedule A after the master is signed: the owner confirms the batch (one notice a transaction)
create function app.sign_first_schedule_trg() returns trigger
language plpgsql security definer set search_path = public, app, pg_temp as $$
declare
  o owners;
  ea owner_agreements;
  v_list text;
  n integer;
begin
  begin
    select ow.* into o from owners ow join vehicles v on v.owner_id = ow.id where v.id = new.vehicle_id;
    select * into ea from owner_agreements where id = new.owner_agreement_id;
    if o.id is null or ea.status <> 'signed' or not coalesce((app.settings()).owner_sign_first, true) then return null; end if;
    select string_agg(app.vehicle_name(s.vehicle_id) || coalesce(' (' || v.plate || ')', ''), ', ' order by s.vehicle_number), count(*) into v_list, n
      from vehicle_schedules s join vehicles v on v.id = s.vehicle_id
     where v.owner_id = o.id and s.is_additional and s.signed_at is null and s.superseded_by is null and s.withdrawn_at is null;
    if coalesce(n, 0) = 0 then return null; end if;
    perform app.ntf_emit('owner_schedule_ready', 'owner', o.id, 'tx' || txid_current(), jsonb_build_object('owner_id', o.id,
      'first_name', app.owner_first_name(o), 'car_count', n || case when n = 1 then ' car' else ' cars' end, 'car_list', v_list,
      'agreement_title', app.agreement_title('enrollment', ea.variant), 'agreement_number', ea.agreement_number,
      'sign_url', rtrim(coalesce((app.settings()).notify_base_url, 'https://carmacars.ca'), '/') || '/owner/sign'));
  exception when others then
    raise warning 'sign first: the schedule notice of owner %: %', o.id, sqlerrm;
  end;
  return null;
end $$;
create constraint trigger vehicle_schedules_added after insert on vehicle_schedules
  deferrable initially deferred for each row when (new.is_additional) execute function app.sign_first_schedule_trg();

-- ================================================================ 7. the status, and Send reminder
-- Everything the guided path, the owner pages of Admin and staff, and the connector show. Who reads it: the owner (their
-- own), an Admin, customer service and Fleet (any owner), Sales (the owners they brought in).
create function app.owner_sign_status(p_by uuid, p jsonb) returns jsonb
language plpgsql stable security definer set search_path = public, app, pg_temp as $$
declare
  o owners;
  v_viewer text;
  ea owner_agreements;
  ta owner_agreements;
  m jsonb;
begin
  select * into o from owners where id = nullif(p ->> 'owner_id', '')::uuid;
  if o.id is null then raise exception 'Owner not found' using errcode = 'P0002'; end if;
  v_viewer := case when app.user_is_admin(p_by) then 'admin'
                   when app.user_va_has(p_by, 'cs', 'fleet') or (app.user_va_has(p_by, 'sales') and o.recruited_by = p_by) then 'staff'
                   when app.user_is_owner_of(p_by, o.id) then 'owner' end;
  if v_viewer is null then raise exception 'Not permitted' using errcode = '42501'; end if;
  select * into ea from owner_agreements where owner_id = o.id and kind = 'enrollment' and status in ('draft', 'sent', 'signed');
  select * into ta from owner_agreements where owner_id = o.id and kind = 'title_holding' and status in ('draft', 'sent', 'signed');
  m := app.owner_sign_missing(o.id);
  return jsonb_build_object('viewer', v_viewer, 'owner_id', o.id, 'name', coalesce(o.corporation_name, o.legal_name), 'email', o.email,
    'has_login', o.user_id is not null, 'fleet_supplier', app.fleet_supplier(o.id), 'sign_first', coalesce((app.settings()).owner_sign_first, true),
    'profile_missing', to_jsonb(app.owner_master_missing(o.id)),
    'master', case when ea.id is not null then jsonb_build_object('id', ea.id, 'title', app.agreement_title('enrollment', ea.variant), 'number', ea.agreement_number,
                'variant', ea.variant, 'status', ea.status, 'signed_on', ea.agreement_date) end,
    'title_holding', case when ta.id is not null then jsonb_build_object('number', ta.agreement_number, 'status', ta.status) end,
    'cars', (select coalesce(jsonb_agg(jsonb_build_object('vehicle_id', v.id, 'name', app.vehicle_name(v.id), 'plate', v.plate, 'status', v.status,
               'onboarding_status', ob.status, 'tier', ob.lease_tier, 'schedule_number', s.schedule_number, 'vehicle_number', s.vehicle_number,
               'schedule_signed', s.signed_at is not null, 'scheduled', s.id is not null,
               'photos_done', coalesce((select c.status in ('done', 'not_applicable') from app.onboarding_checklist(v.id) c where c.code = 'documents' limit 1), false),
               'approved', coalesce(ob.status::text <> 'intake' and (not app.fleet_supplier(o.id) or app.fleet_delivered_on(v.id) is not null
                             or exists (select 1 from owner_applications x where x.id = ob.application_id and x.status = 'approved')), false),
               'waiting_approval', exists (select 1 from owner_applications x where x.id = ob.application_id and x.sign_wait_at is not null and x.status not in ('approved', 'declined')),
               'delivered_on', app.fleet_delivered_on(v.id),
               'delivered', app.fleet_delivered_on(v.id) is not null or coalesce(ob.status::text, '') = 'enrolled' or v.status not in ('onboarding', 'ready_to_list'),
               'gate', app.owner_sign_gate(v.id)) order by v.created_at), '[]'::jsonb)
               from vehicles v left join vehicle_onboardings ob on ob.vehicle_id = v.id
               left join vehicle_schedules s on s.vehicle_id = v.id and s.superseded_by is null and s.withdrawn_at is null
              where v.owner_id = o.id and v.status not in ('declined', 'exited', 'total_loss') and coalesce(ob.status::text, '') not in ('declined', 'withdrawn')),
    'missing', m,
    'owner_missing', (select coalesce(jsonb_agg(x), '[]'::jsonb) from jsonb_array_elements(m) x where x ->> 'who' = 'owner'),
    'last_reminder_at', (select max(s.sent_at) from owner_agreement_sends s where s.owner_id = o.id),
    'can_remind', v_viewer in ('admin', 'staff') and (app.user_is_admin(p_by) or app.user_va_has(p_by, 'cs', 'fleet')) and o.user_id is not null
                  and nullif(btrim(coalesce(o.email, '')), '') is not null and exists (select 1 from jsonb_array_elements(m) x where x ->> 'who' = 'owner'));
end $$;

-- Send reminder: the owner hears what still waits for them (email, in-app, push). p: owner_id, preview (true: say what
-- would be sent, send nothing). An Admin, customer service or Fleet; at most once in 10 minutes per owner.
create function app.owner_sign_reminder(p_by uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app, pg_temp as $$
declare
  o owners;
  m jsonb;
  v_text text;
  v_what text;
  v_last timestamptz;
  v_base text := rtrim(coalesce((app.settings()).notify_base_url, 'https://carmacars.ca'), '/');
  v_profile boolean;
begin
  if not (app.user_is_admin(p_by) or app.user_va_has(p_by, 'cs', 'fleet')) then
    raise exception 'Only an Admin, customer service or Fleet sends an owner a reminder' using errcode = '42501';
  end if;
  select * into o from owners where id = nullif(p ->> 'owner_id', '')::uuid;
  if o.id is null then raise exception 'Owner not found' using errcode = 'P0002'; end if;
  if nullif(btrim(coalesce(o.email, '')), '') is null then raise exception 'This owner has no email: add one on the owner''s page' using errcode = '23514'; end if;
  if o.user_id is null then raise exception 'This owner has no sign-in yet: press Invite on the owner''s page first (the invitation leads to the same place)' using errcode = '23514'; end if;
  select coalesce(jsonb_agg(x), '[]'::jsonb) into m from jsonb_array_elements(app.owner_sign_missing(o.id)) x where x ->> 'who' = 'owner';
  if jsonb_array_length(m) = 0 then raise exception 'Nothing waits for the owner: every agreement and schedule entry is signed (or CarmaCars has a step to do)' using errcode = '23514'; end if;
  v_text := (select string_agg(x ->> 'label', E'\n') from jsonb_array_elements(m) x);
  v_profile := exists (select 1 from jsonb_array_elements(m) x where x ->> 'code' = 'profile');
  v_what := case when v_profile then 'Your profile'
                 when exists (select 1 from jsonb_array_elements(m) x where x ->> 'code' = 'master') then 'Your ' || (select app.agreement_title('enrollment', a.variant) from owner_agreements a where a.owner_id = o.id and a.kind = 'enrollment' and a.status in ('draft', 'sent'))
                 else 'Your Schedule A confirmation' end;
  select max(sent_at) into v_last from owner_agreement_sends where owner_id = o.id;
  if coalesce((p ->> 'preview')::boolean, false) then
    return jsonb_build_object('preview', true, 'to', o.email, 'name', coalesce(o.corporation_name, o.legal_name), 'missing', m, 'last_sent_at', v_last,
      'will_do', format('Email %s (with the in-app notice and the push): %s', o.email, replace(v_text, E'\n', '; ')));
  end if;
  if v_last > now() - interval '10 minutes' then raise exception 'A reminder went to this owner less than 10 minutes ago' using errcode = '23514'; end if;
  perform app.ntf_emit('owner_sign_reminder', 'owner', o.id, 'r' || extract(epoch from clock_timestamp())::bigint, jsonb_build_object('owner_id', o.id,
    'first_name', app.owner_first_name(o), 'what', v_what, 'missing_text', v_text,
    'cta', case when v_profile then 'Complete my profile' else 'Read and sign' end,
    'sign_url', v_base || case when v_profile then '/owner/account' else '/owner/sign' end));
  insert into owner_agreement_sends (owner_id, doc_key, to_address, sent_by) values (o.id, 'packet', o.email, p_by);
  insert into audit_log (actor_user_id, action, entity_table, entity_id, after)
  values (p_by, 'owner_sign_reminder', 'owners', o.id::text, jsonb_build_object('missing', m));
  return jsonb_build_object('sent', true, 'to', o.email, 'missing', m);
end $$;

-- Admin > Owners > Agreements (0640) lists the Schedule A entries still to confirm and the profile the agreement waits for
alter function app.owner_agreements_checklist(uuid, jsonb) rename to owner_agreements_checklist_pre3800;
create function app.owner_agreements_checklist(p_by uuid, p jsonb) returns jsonb
language plpgsql stable security definer set search_path = public, app, pg_temp as $$
declare
  v jsonb := app.owner_agreements_checklist_pre3800(p_by, p);
begin
  return (select coalesce(jsonb_agg(r || jsonb_build_object('items', (
             select coalesce(jsonb_agg(case when i ->> 'status' = 'missing' and cardinality(app.owner_master_missing((r ->> 'owner_id')::uuid)) > 0
                                            then i || jsonb_build_object('why', 'The owner''s profile misses: ' || array_to_string(app.owner_master_missing((r ->> 'owner_id')::uuid), ', '))
                                            else i end), '[]'::jsonb)
               from jsonb_array_elements(r -> 'items') i)) order by n), '[]'::jsonb)
            from jsonb_array_elements(v) with ordinality t(r, n));
end $$;
select pg_temp.copy_grants('app.owner_agreements_checklist(uuid, jsonb)'::regprocedure, 'app.owner_agreements_checklist_pre3800(uuid, jsonb)'::regprocedure);

-- ================================================================ 8. the door
alter function app.door(uuid, text, text, text, jsonb) rename to door_pre3800;
create function app.door(p_user uuid, p_aal text, p_call text, p_name text, p jsonb default '{}'::jsonb) returns jsonb
language plpgsql security definer set search_path = public, app, pg_temp as $$
begin
  if (p_call in ('ops_read', 'va_read', 'admin_read') and p_name = 'owner_sign_status')
     or (p_call in ('ops_do', 'va_do', 'admin_do') and p_name = 'owner_sign_reminder') then
    if coalesce(p, '{}'::jsonb) ? '_va' then perform set_config('app.va_active', coalesce(p ->> '_va', ''), true); end if;
    perform app.door_begin(p_user, p_aal);
    p := coalesce(p, '{}'::jsonb) - '_va';
    return case p_name when 'owner_sign_status' then app.owner_sign_status(p_user, p) else app.owner_sign_reminder(p_user, p) end;
  end if;
  return app.door_pre3800(p_user, p_aal, p_call, p_name, p);
end $$;
select pg_temp.copy_grants('app.door(uuid, text, text, text, jsonb)'::regprocedure, 'app.door_pre3800(uuid, text, text, text, jsonb)'::regprocedure);

-- ================================================================ 9. the Admin connector
-- owner_agreements {owner_id | query}: each owner's master agreement, title agreement, cars on Schedule A, what is missing
-- and the portal link to sign (admin:read). send_owner_agreement_reminder {owner_id}: previewed, then confirmed (admin:write).
alter function app.api_call(text, text, jsonb, text) rename to api_call_pre3800;
create function app.api_call(p_hash text, p_tool text, p_args jsonb, p_client text default null) returns jsonb
language plpgsql security definer set search_path = public, app, pg_temp as $$
declare
  a jsonb := case when jsonb_typeof(p_args) = 'object' then p_args else '{}'::jsonb end;
  chk jsonb;
  k api_keys;
  v_args jsonb;
  v_confirm boolean;
  pv api_previews;
  v_result jsonb;
  v_q text;
  v_target text := left(coalesce(nullif(a ->> 'owner_id', ''), nullif(a ->> 'query', ''), p_tool), 200);
  v_base text := rtrim(coalesce((app.settings()).notify_base_url, 'https://carmacars.ca'), '/');
begin
  if p_tool not in ('owner_agreements', 'send_owner_agreement_reminder') then return app.api_call_pre3800(p_hash, p_tool, p_args, p_client); end if;
  chk := app.api_key_check(p_hash, case p_tool when 'owner_agreements' then 'admin:read' else 'admin:write' end, p_tool, a, p_client);
  if not (chk ->> 'ok')::boolean then return chk; end if;
  k := jsonb_populate_record(null::api_keys, chk -> 'key');
  perform app.door_begin(k.user_id, 'aal2');
  v_confirm := coalesce((a ->> 'confirm')::boolean, false);
  v_args := a - 'confirm' - 'preview_id';
  begin
    if p_tool = 'owner_agreements' then
      if not app.user_is_admin(k.user_id) then raise exception 'Only an Admin reads the owner agreements here' using errcode = '42501'; end if;
      v_q := lower(nullif(btrim(coalesce(v_args ->> 'query', '')), ''));
      v_result := jsonb_build_object('owners', (select coalesce(jsonb_agg(app.owner_sign_status(k.user_id, jsonb_build_object('owner_id', o.id))
                      || jsonb_build_object('sign_url', v_base || '/owner/sign', 'admin_url', v_base || '/admin/owners/' || o.id || '?tab=terms') order by o.created_at desc), '[]'::jsonb)
        from (select * from owners o
               where coalesce(o.kind, 'program') = 'program' and o.status <> 'exited'
                 and (nullif(v_args ->> 'owner_id', '') is null or o.id = (v_args ->> 'owner_id')::uuid)
                 and (v_q is null or lower(coalesce(o.corporation_name, '') || ' ' || o.legal_name || ' ' || coalesce(o.email, '')) like '%' || v_q || '%')
                 and (coalesce((v_args ->> 'include_test')::boolean, false) or not coalesce(o.is_test, false))
                 and (nullif(v_args ->> 'owner_id', '') is not null or v_q is not null or coalesce((v_args ->> 'all')::boolean, false)
                      or jsonb_array_length(app.owner_sign_missing(o.id)) > 0)
               order by o.created_at desc limit least(greatest(coalesce(nullif(v_args ->> 'limit', '')::integer, 20), 1), 200)) o));
    else
      if nullif(v_args ->> 'owner_id', '') is null then raise exception 'owner_id: the owner to remind (owner_agreements lists them)' using errcode = '22023'; end if;
      if not v_confirm then
        v_result := app.owner_sign_reminder(k.user_id, v_args || jsonb_build_object('preview', true));
        insert into api_previews (key_id, user_id, tool, args, before, after)
        values (k.id, k.user_id, p_tool, v_args, jsonb_build_object('last_sent_at', v_result -> 'last_sent_at'), jsonb_build_object('send_to', v_result -> 'to', 'missing', v_result -> 'missing'))
        returning * into pv;
        v_result := v_result || jsonb_build_object('preview_id', pv.id, 'tool', p_tool, 'expires_at', pv.created_at + interval '10 minutes',
          'next', 'Nothing was sent. To send it, call this tool again with exactly the same arguments plus "confirm": true and "preview_id": "' || pv.id || '".');
      else
        select * into pv from api_previews where id = nullif(a ->> 'preview_id', '')::uuid for update;
        if pv.id is null or pv.key_id <> k.id or pv.tool <> p_tool then raise exception 'Preview first: call without confirm, then confirm with its preview_id' using errcode = '22023'; end if;
        if pv.used_at is not null then raise exception 'This preview was already used: preview again' using errcode = '22023'; end if;
        if pv.created_at < now() - interval '10 minutes' then raise exception 'This preview is more than 10 minutes old: preview again' using errcode = '22023'; end if;
        if pv.args is distinct from v_args then raise exception 'The arguments differ from the preview: preview again with these' using errcode = '22023'; end if;
        update api_previews set used_at = now() where id = pv.id;
        v_result := app.owner_sign_reminder(k.user_id, v_args) || jsonb_build_object('done', true);
      end if;
    end if;
  exception when others then
    insert into api_calls (key_id, user_id, tool, target, args, ok, error, client) values (k.id, k.user_id, p_tool, v_target, v_args, false, left(sqlerrm, 500), left(p_client, 64));
    return jsonb_build_object('ok', false, 'status', case sqlstate when 'P0002' then 404 when '42501' then 403 else 400 end, 'error', regexp_replace(sqlerrm, '^.*?ERROR:\s*', ''));
  end;
  insert into api_calls (key_id, user_id, tool, target, args, ok, client)
  values (k.id, k.user_id, case when p_tool = 'send_owner_agreement_reminder' and not v_confirm then p_tool || ':preview' else p_tool end, v_target, v_args, true, left(p_client, 64));
  return jsonb_build_object('ok', true, 'result', v_result);
end $$;
select pg_temp.copy_grants('app.api_call(text, text, jsonb, text)'::regprocedure, 'app.api_call_pre3800(text, text, jsonb, text)'::regprocedure);

-- ================================================================ 10. the notices
-- CATALOGUE 3800 START (generated by supabase/seed/3800_gen_catalogue.mjs; do not edit by hand)
insert into notification_catalogue (code, audience, also_sent_to, category, is_digest, digest_slot, from_address, reply_to,
    subject, preheader, timing, trigger_text, replaces_template, link_path, variables, template_html, template_text) values
  ('owner_master_agreement_ready', 'owner', '{}'::text[], 'transactional', false, null, 'CarmaCars <owners@carmacars.ca>', 'owners@carmacars.ca', 'Sign your {{agreement_title}}: your first step with CarmaCars', 'It is filled in from your profile. Sign it now; then add your cars.', 'Immediate', 'Sign first (r50, migration 3800, app.owner_master_ensure): the owner''s profile is complete (the legal or corporation name, the address and, for a corporation, the signing officer) and their master agreement is made from it: the Fleet Supplier Lease Agreement with the Title-Holding and Lease Agreement for a fleet supplier, the Vehicle Enrollment Agreement (or the Flat-Rate one) for a program owner. No car is needed. Once per agreement; the backfill of 3800 sends it to every owner it made one for.', null, null, '[{"name":"agreement_number","type":"string"},{"name":"agreement_title","type":"string"},{"name":"company_address","type":"string","global":true},{"name":"contact_email","type":"string","global":true},{"name":"first_name","type":"string"},{"name":"instagram_url","type":"url","global":true},{"name":"opening_hours","type":"string","global":true},{"name":"reply_time","type":"string","global":true},{"name":"sign_url","type":"url"},{"name":"signer","type":"string"},{"name":"support_phone","type":"string","global":true},{"name":"tiktok_url","type":"url","global":true}]'::jsonb, 'templates/owner_master_agreement_ready.html', 'templates/owner_master_agreement_ready.txt'),
  ('owner_schedule_ready', 'owner', '{}'::text[], 'transactional', false, null, 'CarmaCars <owners@carmacars.ca>', 'owners@carmacars.ca', 'Confirm {{car_count}} added to your Schedule A', '{{car_list}}. One signature confirms them.', 'Immediate', 'Sign first (r50, migration 3800): cars an owner (or staff for them) added after the master agreement was signed are on Schedule A as new numbered entries, and the short schedule confirmation (the Additional Vehicle Schedule) waits for the owner''s e-signature. Once per batch of cars added together; the government forms of each car are made at the same moment.', null, null, '[{"name":"agreement_number","type":"string"},{"name":"agreement_title","type":"string"},{"name":"car_count","type":"string"},{"name":"car_list","type":"string"},{"name":"company_address","type":"string","global":true},{"name":"contact_email","type":"string","global":true},{"name":"first_name","type":"string"},{"name":"instagram_url","type":"url","global":true},{"name":"opening_hours","type":"string","global":true},{"name":"reply_time","type":"string","global":true},{"name":"sign_url","type":"url"},{"name":"support_phone","type":"string","global":true},{"name":"tiktok_url","type":"url","global":true}]'::jsonb, 'templates/owner_schedule_ready.html', 'templates/owner_schedule_ready.txt'),
  ('owner_sign_reminder', 'owner', '{}'::text[], 'transactional', false, null, 'CarmaCars <owners@carmacars.ca>', 'owners@carmacars.ca', 'Reminder: {{what}} waits for your signature', 'Your cars move once it is signed. About two minutes, on screen.', 'When staff press Send reminder', 'Sign first (r50, migration 3800): an Admin or Fleet presses Send reminder where the owner''s page lists what is missing (or the Admin connector''s send_owner_agreement_reminder is confirmed). Lists what still waits for the owner: the master agreement, a Schedule A confirmation, or the profile values the agreement needs. At most once in 10 minutes per owner.', null, null, '[{"name":"company_address","type":"string","global":true},{"name":"contact_email","type":"string","global":true},{"name":"cta","type":"string"},{"name":"first_name","type":"string"},{"name":"instagram_url","type":"url","global":true},{"name":"missing_text","type":"string"},{"name":"opening_hours","type":"string","global":true},{"name":"reply_time","type":"string","global":true},{"name":"sign_url","type":"url"},{"name":"support_phone","type":"string","global":true},{"name":"tiktok_url","type":"url","global":true},{"name":"what","type":"string"}]'::jsonb, 'templates/owner_sign_reminder.html', 'templates/owner_sign_reminder.txt'),
  ('owner_car_delivered', 'owner', '{}'::text[], 'transactional', false, null, 'CarmaCars <owners@carmacars.ca>', 'owners@carmacars.ca', 'Approved: your {{vehicle_name}} is on the lease from {{delivered_on}}', '{{tier}} car, {{monthly_amount}} a month. First payment {{first_payment_on}}.', 'Immediate', 'Sign first (r50, migration 3800): a fleet supplier''s car is approved and goes on the lease (app.fleet_lease_car_set), by an Admin or by itself when the supplier signed after an Admin approved it. Once per car.', null, '/owner', '[{"name":"company_address","type":"string","global":true},{"name":"contact_email","type":"string","global":true},{"name":"delivered_on","type":"string"},{"name":"first_name","type":"string"},{"name":"first_payment_on","type":"string"},{"name":"instagram_url","type":"url","global":true},{"name":"monthly_amount","type":"string"},{"name":"opening_hours","type":"string","global":true},{"name":"reply_time","type":"string","global":true},{"name":"support_phone","type":"string","global":true},{"name":"tier","type":"string"},{"name":"tiktok_url","type":"url","global":true},{"name":"vehicle_name","type":"string"}]'::jsonb, 'templates/owner_car_delivered.html', 'templates/owner_car_delivered.txt'),
  ('staff_owner_signed', 'staff_va_fleet', array['staff_admin']::text[], 'transactional', false, null, 'CarmaCars <owners@carmacars.ca>', 'contact@carmacars.ca', '{{owner_name}} signed: {{what}}', '{{next_step}}', 'Immediate', 'Sign first (r50, migration 3800): an owner e-signed their master agreement or a Schedule A confirmation (CarmaCars countersigned at once). Tells Fleet and the Admins what comes next: approve the cars, or that an approval waiting for this signature went through by itself. Immediate.', null, '/staff/owners/{{owner_id}}', '[{"name":"company_address","type":"string","global":true},{"name":"next_step","type":"string"},{"name":"owner_id","type":"string"},{"name":"owner_name","type":"string"},{"name":"what","type":"string"}]'::jsonb, 'templates/staff_owner_signed.html', 'templates/staff_owner_signed.txt')
on conflict (code) do update set
  audience = excluded.audience, also_sent_to = excluded.also_sent_to, category = excluded.category,
  is_digest = excluded.is_digest, digest_slot = excluded.digest_slot, from_address = excluded.from_address,
  reply_to = excluded.reply_to, subject = excluded.subject, preheader = excluded.preheader, timing = excluded.timing,
  trigger_text = excluded.trigger_text, replaces_template = excluded.replaces_template, link_path = excluded.link_path,
  variables = excluded.variables, template_html = excluded.template_html, template_text = excluded.template_text,
  in_catalogue = true, updated_at = now();
select app.notification_catalogue_refresh();
-- CATALOGUE 3800 END
update notification_catalogue set emitted_by = 'app.owner_master_ensure (3800): the profile is complete, the master agreement is made' where code = 'owner_master_agreement_ready';
update notification_catalogue set emitted_by = 'vehicle_schedules_added (3800): cars added to Schedule A after the master agreement was signed' where code = 'owner_schedule_ready';
update notification_catalogue set emitted_by = 'app.owner_sign_reminder (3800): Send reminder on the owner''s page, or the connector' where code = 'owner_sign_reminder';
update notification_catalogue set emitted_by = 'app.fleet_lease_car_set (3800): a supplier''s car goes on the lease' where code = 'owner_car_delivered';
update notification_catalogue set emitted_by = 'app.sign_first_after (3800): the owner signed the master agreement or a Schedule A confirmation' where code = 'staff_owner_signed';
update notification_catalogue set push_topic = 'documents' where code in ('owner_master_agreement_ready', 'owner_schedule_ready', 'owner_sign_reminder', 'owner_car_delivered');
update notification_catalogue set push_topic = 'requests' where code = 'staff_owner_signed';
insert into sms_templates (code, label, body, urgent, sort_order) values
  ('owner_master_agreement_ready', 'Owner master agreement ready', 'CarmaCars: your {{agreement_title}} is ready to sign in your owner portal, before your cars come over: {{link}}', false, 101),
  ('owner_schedule_ready', 'Owner Schedule A to confirm', 'CarmaCars: confirm the {{car_count}} added to your Schedule A in your owner portal: {{link}}', false, 102),
  ('owner_sign_reminder', 'Owner signature reminder', 'CarmaCars reminder: {{what}} waits for your signature. Your cars move once it is signed: {{link}}', false, 103)
on conflict (code) do nothing;
update notification_catalogue set no_text = true where code = 'owner_car_delivered';

-- ================================================================ 11. privileges
do $$
declare f record;
begin
  for f in select p.oid::regprocedure as sig from pg_proc p join pg_namespace n on n.oid = p.pronamespace
            where n.nspname = 'app' and p.proname = any (array['agreement_title', 'owner_master_missing', 'owner_first_name', 'owner_master_ensure', 'owner_master_trg',
              'fleet_schedule_cars', 'owner_sign_missing', 'owner_sign_gate', 'vehicles_sign_gate_trg', 'sign_first_release', 'sign_first_after',
              'sign_first_signed_trg', 'sign_first_schedule_trg', 'owner_sign_status', 'owner_sign_reminder',
              'owner_pay_model_pre3800', 'submit_owner_application_pre3800', 'owner_add_vins_pre3800', 'fleet_lease_car_set_pre3800', 'application_approve_pre3800',
              'application_approve_plan_pre3800', 'owner_agreements_checklist_pre3800', 'door_pre3800', 'api_call_pre3800']) loop
    execute format('revoke all on function %s from public, anon, authenticated', f.sig);
    execute format('grant execute on function %s to service_role', f.sig);
  end loop;
end $$;

-- ================================================================ 12. backfill: every owner gets their master agreement now
-- Owners of the program without one whose profile is complete: made now, waiting for the signature, and told
-- (owner_master_agreement_ready). A supplier's cars still in intake get their Schedule A entries and forms.
do $$
declare
  o record;
  n integer := 0;
  c integer := 0;
begin
  for o in select x.id from owners x
            where coalesce(x.kind, 'program') = 'program' and x.status <> 'exited'
              and not exists (select 1 from owner_agreements a where a.owner_id = x.id and a.kind = 'enrollment' and a.status in ('draft', 'sent', 'signed'))
            order by x.created_at loop
    begin
      if coalesce((app.owner_master_ensure(o.id, null) ->> 'made')::boolean, false) then n := n + 1; end if;
    exception when others then
      raise warning 'sign first backfill: owner %: %', o.id, sqlerrm;
    end;
  end loop;
  for o in select x.id from owners x where x.onboarding_route = 'fleet_supplier' and x.status <> 'exited' loop
    begin
      c := c + app.fleet_schedule_cars(o.id, null);
    exception when others then
      raise warning 'sign first backfill: supplier %: %', o.id, sqlerrm;
    end;
  end loop;
  insert into audit_log (action, entity_table, entity_id, after)
  values ('sign_first_backfill', 'owner_agreements', '3800', jsonb_build_object('agreements_made', n, 'supplier_cars_scheduled', c));
end $$;
