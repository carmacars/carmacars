-- 0237: a car's registration in Admin (docs/changes/2026-11-03-vehicle-registration.md). The owner, Release 23: on a car
-- (Cars, the car), set or correct the VIN, the year and the body style; the Ontario permit number and the plate sticker
-- (validation) expiry, with a staff task 30 and 7 days before the sticker expires; and the car's documents, the ownership
-- permit first, uploaded on the car.
--
-- 1. vehicles.permit_number and vehicles.sticker_expires_on. app.vehicle_registration_save (an Admin or fleet): the VIN
--    (17 characters without I, O or Q, the check digit, never a VIN already on another car; the site decodes it again
--    with vPIC and passes the body style and trim it finds), the year, the body style, the trim, the permit number and the
--    sticker expiry. Each change is in the audit log.
-- 2. The sticker: a fleet task 30 days and again 7 days before it expires ("sticker_renewal"), raised by the daily expiry
--    watch (app.job_expiry_watch, 0020). A staff task only: no service record, nothing billed to the owner.
-- 3. A car's documents uploaded on the car (app.vehicle_document_register): the ownership permit (it clears "Ownership
--    permit" on the owner's checklist, which looks for that document, and is kept on the car's registration), the safety
--    certificate, the owner's insurance, or another document. Admins and fleet. ops_read vehicle_documents lists them.
-- 4. The Safety Standards Certificate on the car: its number, issue date and expiry, saved with its document (a document,
--    not a billable service record), and the same fleet tasks 30 and 7 days before it expires.
-- 5. A car added to the wrong owner moves to another owner (app.vehicle_move_owner, Admin): its unsigned owner
--    application is withdrawn (status withdrawn, kept in the history), its unsigned vehicle schedule withdrawn
--    (withdrawn_at, kept), its draft owner invoices deleted (never issued: no owner notice, no first and last task), and the
--    car's onboarding forgets them. Refused once anything for the car is signed, issued, paid or on a statement. A car
--    whose owner is not known yet moves to CarmaCars itself (p.to = 'company'): a company car (supply_type company, the
--    company's owners row), with no owner schedule or terms. Nobody is notified.
-- No applied migration is edited.

create function pg_temp.copy_grants(p_new regprocedure, p_old regprocedure) returns void
language plpgsql as $$
declare g text;
begin
  execute format('revoke all on function %s from public, anon, authenticated', p_new);
  foreach g in array array['anon', 'authenticated', 'service_role'] loop
    if has_function_privilege(g, p_old, 'execute') then execute format('grant execute on function %s to %I', p_new, g); end if;
  end loop;
end $$;

alter table vehicles
  add column if not exists ssc_number text check (ssc_number is null or length(ssc_number) between 3 and 30),
  add column if not exists ssc_issued_on date,
  add column if not exists ssc_expires_on date,
  add column if not exists permit_number text check (permit_number is null or permit_number ~ '^[A-Za-z0-9 -]{4,20}$'),
  add column if not exists sticker_expires_on date;
comment on column vehicles.permit_number is 'The Ontario vehicle permit (ownership) number (0237).';
comment on column vehicles.ssc_number is 'The Safety Standards Certificate on file (0237): its number, issue date (ssc_issued_on) and expiry (ssc_expires_on), with its document.';
comment on column vehicles.sticker_expires_on is 'The plate sticker (validation) expiry (0237): a fleet task 30 and 7 days before.';

insert into task_rules (task_type, queue, title, priority, due_kind, due_amount, procedure_no, completion_rule, description)
values ('sticker_renewal', 'fleet', 'Plate sticker renewal due', 'normal', 'none', null, 14, null, 'Plate sticker expires within 30 days (then 7)'),
       ('ssc_renewal', 'fleet', 'Safety Standards Certificate expiring', 'normal', 'none', null, 14, null, 'Safety Standards Certificate expires within 30 days (then 7)')
on conflict (task_type) do nothing;

alter table owner_applications drop constraint if exists owner_applications_status_check;
alter table owner_applications add constraint owner_applications_status_check check (status in ('new', 'waiting_on_owner', 'approved', 'declined', 'account_only', 'withdrawn'));
alter table vehicle_schedules add column if not exists withdrawn_at timestamptz;
comment on column vehicle_schedules.withdrawn_at is 'An unsigned schedule withdrawn when its car moved to another owner (0237); kept in the history.';

create or replace function app.vehicle_registration_save(p_by uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  v vehicles;
  a vehicles;
  v_vin text := upper(regexp_replace(coalesce(p ->> 'vin', ''), '\s', '', 'g'));
  v_year integer;
begin
  if not (app.user_is_admin(p_by) or app.user_va_has(p_by, 'fleet')) then
    raise exception 'An Admin or fleet changes a car''s registration' using errcode = '42501';
  end if;
  select * into v from vehicles where id::text = p ->> 'vehicle_id' for update;
  if v.id is null then raise exception 'Car not found' using errcode = 'P0002'; end if;
  if p ? 'vin' and v_vin <> '' then
    if v_vin !~ '^[A-HJ-NPR-Z0-9]{17}$' then raise exception 'A VIN is 17 letters and digits, never I, O or Q' using errcode = '22023'; end if;
    if not app.vin_check_ok(v_vin) then raise exception 'That VIN''s check digit does not match: check each character' using errcode = '22023'; end if;
    if exists (select 1 from vehicles x where upper(x.vin) = v_vin and x.id <> v.id) then
      raise exception 'That VIN is already on another car' using errcode = '23505';
    end if;
  end if;
  if nullif(p ->> 'year', '') is not null then
    v_year := (p ->> 'year')::integer;
    if v_year < 1950 or v_year > extract(year from now())::integer + 1 then raise exception 'Check the year' using errcode = '22023'; end if;
  end if;
  if nullif(p ->> 'sticker_expires_on', '') is not null and (p ->> 'sticker_expires_on')::date < current_date - 365 then
    raise exception 'Check the sticker expiry date' using errcode = '22023';
  end if;
  if nullif(btrim(coalesce(p ->> 'permit_number', '')), '') is not null and btrim(p ->> 'permit_number') !~ '^[A-Za-z0-9 -]{4,20}$' then
    raise exception 'The permit number is 4 to 20 letters and digits' using errcode = '22023';
  end if;
  update vehicles set
    vin = case when p ? 'vin' and v_vin <> '' then v_vin else vin end,
    year = coalesce(v_year, year),
    body_type = case when p ? 'body_type' then coalesce(nullif(btrim(p ->> 'body_type'), ''), body_type) else body_type end,
    trim = case when p ? 'trim' then coalesce(nullif(btrim(p ->> 'trim'), ''), trim) else trim end,
    permit_number = case when p ? 'permit_number' then nullif(upper(btrim(p ->> 'permit_number')), '') else permit_number end,
    sticker_expires_on = case when p ? 'sticker_expires_on' then nullif(p ->> 'sticker_expires_on', '')::date else sticker_expires_on end,
    updated_at = now()
  where id = v.id returning * into a;
  insert into audit_log (actor_user_id, action, entity_table, entity_id, before, after)
  values (p_by, 'vehicle_registration_save', 'vehicles', v.id::text,
          jsonb_build_object('vin', v.vin, 'year', v.year, 'body_type', v.body_type, 'trim', v.trim, 'permit_number', v.permit_number, 'sticker_expires_on', v.sticker_expires_on),
          jsonb_build_object('vin', a.vin, 'year', a.year, 'body_type', a.body_type, 'trim', a.trim, 'permit_number', a.permit_number, 'sticker_expires_on', a.sticker_expires_on));
  -- a sticker renewed: its reminders are done
  if a.sticker_expires_on is distinct from v.sticker_expires_on then
    update tasks set status = 'done', completed_at = now(), completed_by = p_by, completion_note = 'Closed by itself: the new sticker date was saved'
     where vehicle_id = v.id and task_type = 'sticker_renewal' and status in ('open', 'in_progress', 'waiting');
  end if;
  return jsonb_build_object('vehicle_id', a.id, 'vin', a.vin, 'year', a.year, 'body_type', a.body_type, 'trim', a.trim, 'permit_number', a.permit_number,
                            'sticker_expires_on', a.sticker_expires_on, 'vin_changed', a.vin is distinct from v.vin);
end $$;

create or replace function app.vehicle_document_register(p_by uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  v vehicles;
  v_kind text := p ->> 'kind';
  v_doc uuid;
begin
  if not (app.user_is_admin(p_by) or app.user_va_has(p_by, 'fleet')) then
    raise exception 'An Admin or fleet uploads a car''s documents' using errcode = '42501';
  end if;
  if v_kind not in ('ownership_permit', 'safety_certificate', 'owner_insurance_proof', 'other') then raise exception 'Choose what the document is' using errcode = '22023'; end if;
  if nullif(p ->> 'path', '') is null then raise exception 'An upload needs the key of its file in private storage' using errcode = '22023'; end if;
  select * into v from vehicles where id::text = p ->> 'vehicle_id';
  if v.id is null then raise exception 'Car not found' using errcode = 'P0002'; end if;
  insert into documents (kind, title, storage_bucket, storage_path, mime_type, sha256, retention, uploaded_by, vehicle_id, owner_id)
  values (v_kind::document_kind,
          coalesce(nullif(btrim(p ->> 'title'), ''), case v_kind when 'ownership_permit' then 'Ownership permit'
                                                                when 'safety_certificate' then 'Safety Standards Certificate' || coalesce(' ' || nullif(upper(btrim(p ->> 'number')), ''), '')
                                                                when 'owner_insurance_proof' then 'Owner''s insurance' else 'Car document' end || ' (uploaded by staff)'),
          'documents', p ->> 'path', nullif(p ->> 'mime', ''), nullif(p ->> 'sha256', ''), 'records_7y', p_by, v.id, v.owner_id)
  returning id into v_doc;
  if v_kind = 'safety_certificate' then
    if nullif(p ->> 'expires_on', '') is not null and nullif(p ->> 'issued_on', '') is not null and (p ->> 'expires_on')::date <= (p ->> 'issued_on')::date then
      raise exception 'The expiry is after the issue date' using errcode = '22023';
    end if;
    update vehicles set ssc_number = coalesce(nullif(upper(btrim(p ->> 'number')), ''), ssc_number), ssc_issued_on = coalesce(nullif(p ->> 'issued_on', '')::date, ssc_issued_on),
           ssc_expires_on = coalesce(nullif(p ->> 'expires_on', '')::date, ssc_expires_on), updated_at = now()
     where id = v.id;
    update vehicle_onboardings set safety_certificate_document_id = v_doc, safety_certificate_on = coalesce(nullif(p ->> 'issued_on', '')::date, safety_certificate_on),
           safety_certificate_expires_on = coalesce(nullif(p ->> 'expires_on', '')::date, safety_certificate_expires_on)
     where vehicle_id = v.id;
    update tasks set status = 'done', completed_at = now(), completed_by = p_by, completion_note = 'Closed by itself: a new certificate was uploaded'
     where vehicle_id = v.id and task_type = 'ssc_renewal' and status in ('open', 'in_progress', 'waiting') and nullif(p ->> 'expires_on', '') is not null;
  end if;
  if v_kind = 'ownership_permit' then
    update vehicle_registrations g set permit_document_id = v_doc
     where g.id = (select x.id from vehicle_registrations x where x.vehicle_id = v.id and x.retransferred_on is null order by x.registered_on desc limit 1);
  end if;
  insert into audit_log (actor_user_id, action, entity_table, entity_id, after)
  values (p_by, 'vehicle_document_register', 'vehicles', v.id::text, jsonb_build_object('kind', v_kind, 'document_id', v_doc));
  return jsonb_build_object('document_id', v_doc, 'kind', v_kind);
end $$;

create or replace function app.vehicle_documents_read(p_by uuid, p jsonb) returns jsonb
language plpgsql stable security definer set search_path = public, app as $$
begin
  if not (app.user_is_admin(p_by) or app.user_va_has(p_by, 'fleet')) then raise exception 'Not permitted' using errcode = '42501'; end if;
  return coalesce((select jsonb_agg(jsonb_build_object('id', d.id, 'kind', d.kind, 'title', d.title, 'created_at', d.created_at,
            'by', (select u.full_name from users u where u.id = d.uploaded_by)) order by d.created_at desc)
           from documents d where d.vehicle_id::text = p ->> 'vehicle_id' and d.purged_at is null
             and d.kind::text in ('ownership_permit', 'safety_certificate', 'owner_insurance_proof', 'other', 'insurer_confirmation')), '[]'::jsonb);
end $$;

-- a car added to the wrong owner moves to another owner (5)
create or replace function app.vehicle_move_owner(p_by uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  v vehicles;
  ob vehicle_onboardings;
  v_company boolean := 'company' in (coalesce(p ->> 'to', ''), coalesce(p ->> 'owner_id', ''));
  v_to uuid := case when 'company' in (coalesce(p ->> 'to', ''), coalesce(p ->> 'owner_id', '')) then app.company_owner_id() else nullif(p ->> 'owner_id', '')::uuid end;
  v_apps integer := 0;
  v_scheds integer := 0;
  v_drafts integer := 0;
  v_ids uuid[];
begin
  perform app.assert_admin(p_by);
  select * into v from vehicles where id::text = p ->> 'vehicle_id' for update;
  if v.id is null then raise exception 'Car not found' using errcode = 'P0002'; end if;
  if v_to is null then raise exception 'Choose the owner the car belongs to, or CarmaCars' using errcode = '22023'; end if;
  if v_to = v.owner_id then raise exception 'The car is already with that owner' using errcode = '23514'; end if;
  if not v_company and not exists (select 1 from owners o where o.id = v_to and o.kind not in ('company', 'partner')) then
    raise exception 'Owner not found' using errcode = 'P0002';
  end if;
  if v.supply_type <> 'program_owner' then raise exception 'Only a program owner''s car moves between owners' using errcode = '23514'; end if;
  if exists (select 1 from vehicle_schedules s where s.vehicle_id = v.id and s.signed_at is not null and s.withdrawn_at is null) then
    raise exception 'The car''s vehicle schedule is signed: it cannot move' using errcode = '23514';
  end if;
  if exists (select 1 from owner_invoices i where i.vehicle_id = v.id and i.status not in ('draft', 'void')) then
    raise exception 'An owner invoice of this car was issued or paid: it cannot move' using errcode = '23514';
  end if;
  if exists (select 1 from owner_statement_vehicles sv where sv.vehicle_id = v.id) or exists (select 1 from booking_splits s where s.vehicle_id = v.id and s.owner_id = v.owner_id) then
    raise exception 'The car has revenue on the owner''s statements: it cannot move' using errcode = '23514';
  end if;
  select * into ob from vehicle_onboardings where vehicle_id = v.id for update;
  -- the unsigned schedules: withdrawn, kept
  update vehicle_schedules set withdrawn_at = now() where vehicle_id = v.id and signed_at is null and withdrawn_at is null;
  get diagnostics v_scheds = row_count;
  -- the draft invoices: deleted (never issued), with their open tasks
  select coalesce(array_agg(id), '{}') into v_ids from owner_invoices where vehicle_id = v.id and status = 'draft';
  update vehicle_onboardings set upfront_invoice_id = null, first_last_choice = null, first_last_choice_cents = null, first_last_choice_payment = null,
         first_last_choice_by = null, first_last_choice_at = null, application_id = null, updated_at = now()
   where vehicle_id = v.id;
  update tasks set status = 'cancelled', completed_at = now(), completed_by = p_by, completion_note = 'The car moved to another owner'
   where status in ('open', 'in_progress', 'waiting') and (vehicle_id = v.id and (related_id = any (v_ids) or task_type like 'first\_last%' or task_type in ('record_first_last', 'collect_upfront')));
  delete from owner_invoices where id = any (v_ids);
  v_drafts := cardinality(v_ids);
  -- the owner application of this car alone: withdrawn, kept
  if ob.application_id is not null and not exists (select 1 from vehicle_onboardings o2 where o2.application_id = ob.application_id and o2.vehicle_id <> v.id) then
    update owner_applications set status = 'withdrawn', decided_at = now(), decided_by = p_by, updated_at = now()
     where id = ob.application_id and status in ('new', 'waiting_on_owner', 'approved', 'account_only');
    get diagnostics v_apps = row_count;
  end if;
  update vehicles set owner_id = v_to, supply_type = case when v_company then 'company' else supply_type end, updated_at = now() where id = v.id;
  insert into audit_log (actor_user_id, action, entity_table, entity_id, before, after)
  values (p_by, 'vehicle_move_owner', 'vehicles', v.id::text, jsonb_build_object('owner_id', v.owner_id),
          jsonb_build_object('owner_id', v_to, 'company', v_company, 'applications_withdrawn', v_apps, 'schedules_withdrawn', v_scheds, 'draft_invoices_deleted', v_drafts));
  return jsonb_build_object('vehicle_id', v.id, 'owner_id', v_to, 'company', v_company, 'applications_withdrawn', v_apps, 'schedules_withdrawn', v_scheds, 'draft_invoices_deleted', v_drafts);
end $$;

-- the daily expiry watch: the plate sticker, 30 and 7 days before
alter function app.job_expiry_watch(timestamptz) rename to job_expiry_watch_pre0237;
create function app.job_expiry_watch(p_now timestamptz default now()) returns text
language plpgsql security definer set search_path = public, app as $$
declare
  v text := app.job_expiry_watch_pre0237(p_now);
  r record;
  n integer := 0;
  v_day date := app.local_date(p_now);
begin
  for r in select x.id, x.owner_id, x.sticker_expires_on, x.sticker_expires_on - v_day as left_days, app.vehicle_name(x.id) as label
             from vehicles x
            where x.sticker_expires_on is not null and x.sticker_expires_on - v_day between 0 and 30 and x.retired_at is null
              and x.status::text not in ('exited', 'declined', 'total_loss') loop
    perform app.raise_task(p_type => 'sticker_renewal', p_queue => 'fleet',
      p_title => format('%s: the plate sticker expires %s', r.label, to_char(r.sticker_expires_on, 'FMMon FMDD, YYYY')),
      p_detail => 'Renew the plate sticker (ServiceOntario), then save the new expiry date on the car (Cars, the car, Registration).',
      p_vehicle => r.id, p_due_at => app.local_midnight(r.sticker_expires_on),
      p_dedupe => 'sticker_renewal:' || r.id || ':' || r.sticker_expires_on || case when r.left_days <= 7 then ':7' else ':30' end);
    n := n + 1;
  end loop;
  for r in select x.id, x.ssc_expires_on, x.ssc_expires_on - v_day as left_days, app.vehicle_name(x.id) as label
             from vehicles x
            where x.ssc_expires_on is not null and x.ssc_expires_on - v_day between 0 and 30 and x.retired_at is null
              and x.status::text not in ('exited', 'declined', 'total_loss') loop
    perform app.raise_task(p_type => 'ssc_renewal', p_queue => 'fleet',
      p_title => format('%s: the Safety Standards Certificate expires %s', r.label, to_char(r.ssc_expires_on, 'FMMon FMDD, YYYY')),
      p_detail => 'Book the safety inspection, then upload the new certificate on the car (Cars, the car, Registration, Documents) with its dates.',
      p_vehicle => r.id, p_due_at => app.local_midnight(r.ssc_expires_on),
      p_dedupe => 'ssc_renewal:' || r.id || ':' || r.ssc_expires_on || case when r.left_days <= 7 then ':7' else ':30' end);
    n := n + 1;
  end loop;
  if n = 0 then return v; end if;
  return concat_ws('; ', v, format('%s plate sticker and safety certificate tasks', n));
end $$;
select pg_temp.copy_grants('app.job_expiry_watch(timestamptz)'::regprocedure, 'app.job_expiry_watch_pre0237(timestamptz)'::regprocedure);

alter function app.door(uuid, text, text, text, jsonb) rename to door_pre0237;
create function app.door(p_user uuid, p_aal text, p_call text, p_name text, p jsonb default '{}'::jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
begin
  if p_call in ('ops_do', 'admin_do') and p_name in ('vehicle_registration_save', 'vehicle_document_register') then
    perform app.door_begin(p_user, p_aal);
    return case p_name when 'vehicle_registration_save' then app.vehicle_registration_save(p_user, coalesce(p, '{}'::jsonb))
                       else app.vehicle_document_register(p_user, coalesce(p, '{}'::jsonb)) end;
  end if;
  if p_call = 'admin_do' and p_name = 'vehicle_move_owner' then
    perform app.door_begin(p_user, p_aal);
    return app.vehicle_move_owner(p_user, coalesce(p, '{}'::jsonb));
  end if;
  if p_call = 'ops_read' and p_name = 'vehicle_documents' then
    perform app.door_begin(p_user, p_aal);
    return app.vehicle_documents_read(p_user, coalesce(p, '{}'::jsonb));
  end if;
  return app.door_pre0237(p_user, p_aal, p_call, p_name, p);
end $$;
select pg_temp.copy_grants('app.door(uuid, text, text, text, jsonb)'::regprocedure, 'app.door_pre0237(uuid, text, text, text, jsonb)'::regprocedure);

do $$
declare f record;
begin
  for f in select p.oid::regprocedure as sig from pg_proc p join pg_namespace n on n.oid = p.pronamespace
            where n.nspname = 'app' and p.proname in ('vehicle_registration_save', 'vehicle_document_register', 'vehicle_documents_read', 'job_expiry_watch_pre0237', 'door_pre0237', 'vehicle_move_owner') loop
    execute format('revoke all on function %s from public, anon, authenticated', f.sig);
    execute format('grant execute on function %s to service_role', f.sig);
  end loop;
end $$;
