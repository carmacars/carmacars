-- 1000: the owner signs each government (ServiceOntario) form on screen (Release 35, part Q;
-- docs/changes/2026-11-08-r35-form-signing.md). No applied migration is edited.
--
-- The owner's rule: the car owner signs each government form that applies to them during onboarding; staff see the same
-- form field by field and print ready, without the owner's signature, with the signature kept beside it (off the form).
-- The forms stay the publisher's PDFs byte for byte (0870): the on-screen signature is a record of the owner's agreement
-- to the values on the form, never stamped on the PDF; the form itself is still printed and signed in ink at the registry.
--   1. government_form_signatures: one row per form signed, with the signer, the way (drawn or typed), the date, the IP
--      address and device, the version of the form and the values signed, and the signing session (the same session as the
--      agreements: esign_sessions and esign_events, 0154 and 0193).
--   2. app.government_form_sign_state: unsigned, signed, changed (the values changed after signing) or ink (signed in ink
--      or filed); the values are compared by SHA-256 (app.government_form_values_sha).
--   3. the session of an owner's forms (context documents, kind govform, ref the form's id) is started and checked like the
--      agreements' (app.esign_start_documents); app.owner_gov_forms_sign records the signatures, one per form.
--   4. the owner's reads: the forms of a car with their state, the form to show (public.owner_gov_forms_to_sign); the
--      staff read of one form carries its state, the signature and every signature.
--   5. the Onboarding checklist's government forms step is done only when every form is signed (app.onboarding_checklist);
--      the overview counts them (app.onboarding_overview).
--   6. one reminder email to the owner (the signing email, owner_agreement_to_sign) when forms wait for the signature, or
--      a form changed after it was signed; one per state of the car's forms, the earlier waiting one replaced (daily job).
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

-- ================================================================ 1. the signatures
create table government_form_signatures (
  id               uuid primary key default gen_random_uuid(),
  vehicle_id       uuid not null references vehicles (id),
  owner_id         uuid not null references owners (id),
  form_code        text not null,
  fill_id          uuid references government_form_fills (id) on delete set null,
  form_version     integer,
  values_sha       text not null check (values_sha ~ '^[0-9a-f]{64}$'),
  signed_values    jsonb not null default '{}'::jsonb,           -- what the owner signed: the filled boxes, or the rows of the data sheet
  signer_user_id   uuid not null references users (id),
  signer_name      text not null,
  method           text not null check (method in ('drawn', 'typed')),
  signature_path   text,                                          -- the drawn signature (private storage); never stamped on the form
  typed_name       text,
  signed_at        timestamptz not null default now(),
  ip_address       inet,
  user_agent       text,
  esign_session_id uuid references esign_sessions (id),
  consent_text     text,
  check ((method = 'drawn' and signature_path is not null) or (method = 'typed' and nullif(btrim(typed_name), '') is not null))
);
comment on table government_form_signatures is 'The owner''s on-screen signature of one government form (1000): a record kept beside the form, never printed on the official PDF.';
create index government_form_signatures_form on government_form_signatures (vehicle_id, form_code, signed_at desc);
create index government_form_signatures_owner on government_form_signatures (owner_id);
alter table government_form_signatures enable row level security;
create policy admin_all on government_form_signatures for all to authenticated using (app.is_admin()) with check (app.is_admin());
revoke all on government_form_signatures from anon, authenticated;
grant select on government_form_signatures to authenticated;
grant select, insert on government_form_signatures to service_role;
create trigger audit_government_form_signatures after insert or update or delete on government_form_signatures for each row execute function app.audit_row();
create function app.government_form_signatures_append_only() returns trigger
language plpgsql as $$ begin raise exception 'A signature is never changed or removed' using errcode = '42501'; end $$;
create trigger government_form_signatures_append_only before update or delete on government_form_signatures for each row execute function app.government_form_signatures_append_only();

-- ================================================================ 2. the state of a form's signature
-- The values the owner signs: the filled boxes of the official form (or the rows of the data sheet), with the template.
create function app.government_form_values_sha(p_fill uuid) returns text
language sql stable security definer set search_path = public, app as $$
  select encode(sha256(convert_to(jsonb_build_object('form', g.form_code, 'mode', g.mode, 'template', coalesce(t.sha256, ''),
           'values', case when g.mode = 'pdf' then g.field_values else g.data_sheet end)::text, 'UTF8')), 'hex')
    from government_form_fills g left join pdf_templates t on t.id = g.pdf_template_id where g.id = p_fill $$;

-- unsigned | signed | changed (signed before, the values differ now) | ink (signed in ink or filed: no signature on screen is asked)
create function app.government_form_sign_state(p_fill uuid) returns text
language sql stable security definer set search_path = public, app as $$
  select case
    when g.id is null then null
    when g.status in ('signed', 'filed') then 'ink'
    when s.id is null then 'unsigned'
    when s.values_sha = app.government_form_values_sha(g.id) then 'signed'
    else 'changed' end
    from (select 1) one
    left join government_form_fills g on g.id = p_fill
    left join lateral (select x.* from government_form_signatures x where x.vehicle_id = g.vehicle_id and x.form_code = g.form_code
                        order by x.signed_at desc, x.id desc limit 1) s on true $$;

-- the forms of a car that apply and are made now: [{id, form_code, state, signable}]
create function app.gov_forms_sign_rows(p_vehicle uuid) returns table (id uuid, form_code text, state text, signable boolean, signed_at timestamptz)
language sql stable security definer set search_path = public, app as $$
  select g.id, g.form_code, app.government_form_sign_state(g.id),
         g.status not in ('signed', 'filed') and cardinality(g.missing) = 0,
         (select max(x.signed_at) from government_form_signatures x where x.vehicle_id = g.vehicle_id and x.form_code = g.form_code)
    from government_form_fills g join vehicle_onboardings ob on ob.vehicle_id = g.vehicle_id
   where g.vehicle_id = p_vehicle and g.superseded_at is null and app.registry_forms_due(p_vehicle) and g.form_code = any (coalesce(ob.government_forms, '{}')) $$;

create function app.gov_forms_sign_counts(p_vehicle uuid) returns jsonb
language sql stable security definer set search_path = public, app as $$
  select jsonb_build_object('signed', count(*) filter (where r.state in ('signed', 'ink')),
                            'to_sign', count(*) filter (where r.state in ('unsigned', 'changed') and r.signable),
                            'changed', count(*) filter (where r.state = 'changed'))
    from app.gov_forms_sign_rows(p_vehicle) r $$;

-- ================================================================ 3. the signing session of an owner's forms
alter function app.esign_start_documents(jsonb) rename to esign_start_documents_pre1000;
create function app.esign_start_documents(p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  v_docs jsonb := coalesce(p -> 'documents', '[]'::jsonb);
  v_ref uuid := nullif(p ->> 'signer_ref', '')::uuid;
  v_gov integer;
  v_all integer;
  d jsonb;
  g government_form_fills;
  o owners;
  u users;
  s esign_sessions;
begin
  if coalesce(p ->> 'context', '') <> 'documents' or jsonb_typeof(v_docs) <> 'array' then return app.esign_start_documents_pre1000(p); end if;
  select count(*) filter (where x ->> 'kind' = 'govform'), count(*) into v_gov, v_all from jsonb_array_elements(v_docs) x;
  if v_gov = 0 then return app.esign_start_documents_pre1000(p); end if;
  if v_gov <> v_all then raise exception 'The government forms are signed on their own page' using errcode = '22023'; end if;
  select * into u from users where id = v_ref;
  if u.id is null then raise exception 'Sign in first' using errcode = '42501'; end if;
  for d in select value from jsonb_array_elements(v_docs) loop
    select * into g from government_form_fills where id = nullif(d ->> 'ref', '')::uuid;
    if g.id is null or not app.user_is_owner_of(v_ref, g.owner_id) then raise exception 'Not found' using errcode = 'P0002'; end if;
    if o.id is null then select * into o from owners where id = g.owner_id; end if;
    if g.owner_id <> o.id then raise exception 'Sign one owner''s forms at a time' using errcode = '22023'; end if;
    if g.superseded_at is not null then raise exception 'This form was made again: reload the page and sign the current version' using errcode = '23514'; end if;
    if g.status in ('signed', 'filed') then raise exception 'This form is signed in ink already' using errcode = '23514'; end if;
    if cardinality(g.missing) > 0 then raise exception 'Some values are still missing on this form: add them first' using errcode = '23514'; end if;
    if app.government_form_values_sha(g.id) <> lower(btrim(coalesce(d ->> 'sha256', ''))) then
      raise exception 'The form changed after you opened it: reload and sign the current version' using errcode = '23514';
    end if;
  end loop;
  select * into s from esign_sessions where context = 'documents' and signer_ref = v_ref and method = 'remote' and signed_at is null
     and created_at > now() - interval '2 hours' and documents = v_docs
   order by created_at desc limit 1;
  if s.id is null then
    insert into esign_sessions (context, signer_ref, signer_role, signer_name, signer_user_id, owner_id, method, documents, email, mobile,
                                required_initials, required_consents, ip_address, user_agent)
    values ('documents', v_ref, 'owner', case when o.owner_type = 'corporation' then coalesce(o.signing_officer_name, o.legal_name) else o.legal_name end, v_ref, o.id, 'remote', v_docs,
            coalesce(nullif(u.email, ''), nullif(o.email, '')), coalesce(nullif(u.phone, ''), nullif(o.phone, '')),
            '{}', array['esign', 'erecords'], nullif(p ->> 'ip', '')::inet, p ->> 'user_agent')
    returning * into s;
    insert into esign_events (session_id, kind, detail, ip_address, user_agent)
    values (s.id, 'started', jsonb_build_object('method', 'remote', 'documents', (select jsonb_agg(jsonb_build_object('title', y ->> 'title', 'sha256', y ->> 'sha256')) from jsonb_array_elements(v_docs) y)),
            nullif(p ->> 'ip', '')::inet, p ->> 'user_agent');
  end if;
  return app.esign_view(s.id);
end $$;
select pg_temp.copy_grants('app.esign_start_documents(jsonb)'::regprocedure, 'app.esign_start_documents_pre1000(jsonb)'::regprocedure);

-- p: forms [{fill, sha256}], drawn_signature | typed_name, ip, user_agent, consent_text. One signature row per form; each
-- form is checked against the session (its SHA-256) and against the records (the owner's, current, complete).
create function app.owner_gov_forms_sign(p_by uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  v_owner uuid := app.portal_owner_id(p_by);
  d jsonb;
  g government_form_fills;
  s esign_sessions;
  u users;
  o owners;
  v_forms jsonb := case when jsonb_typeof(p -> 'forms') = 'array' then p -> 'forms' else '[]'::jsonb end;
  v_sha text;
  v_method text;
  v_path text;
  v_typed text;
  v_sig uuid;
  v_out jsonb := '[]'::jsonb;
  v_strict boolean := coalesce((app.settings()).esign_strict, true);
begin
  if jsonb_array_length(v_forms) = 0 then raise exception 'Nothing to sign' using errcode = '22023'; end if;
  select * into u from users where id = p_by;
  select * into o from owners where id = v_owner;
  for d in select value from jsonb_array_elements(v_forms) loop
    select * into g from government_form_fills where id = nullif(d ->> 'fill', '')::uuid;
    if g.id is null or g.owner_id <> v_owner then raise exception 'That form is not yours to sign' using errcode = '42501'; end if;
    if g.superseded_at is not null then raise exception 'This form was made again: reload the page and sign the current version' using errcode = '23514'; end if;
    if g.status in ('signed', 'filed') then raise exception 'This form is signed in ink already' using errcode = '23514'; end if;
    if cardinality(g.missing) > 0 then raise exception 'Some values are still missing on this form: add them first' using errcode = '23514'; end if;
    v_sha := app.government_form_values_sha(g.id);
    if v_sha <> lower(btrim(coalesce(d ->> 'sha256', ''))) then
      raise exception 'The form changed after you opened it: reload and sign the current version' using errcode = '23514';
    end if;
    s := app.esign_ready_doc('documents', p_by, 'govform', g.id::text, v_sha);
    if v_strict then
      if s.id is null then raise exception '%', app.esign_documents_incomplete_message() using errcode = '23514'; end if;
      perform app.esign_signature_matches(s, p ->> 'drawn_signature', p ->> 'typed_name');
    end if;
    v_method := coalesce(s.signature_method, case when nullif(btrim(coalesce(p ->> 'drawn_signature', '')), '') is not null then 'drawn' else 'typed' end);
    v_path := case when v_method = 'drawn' then coalesce(s.signature_path, nullif(btrim(coalesce(p ->> 'drawn_signature', '')), '')) end;
    v_typed := case when v_method = 'typed' then coalesce(nullif(btrim(coalesce(s.signature_path, '')), ''), nullif(btrim(coalesce(p ->> 'typed_name', '')), '')) end;
    insert into government_form_signatures (vehicle_id, owner_id, form_code, fill_id, form_version, values_sha, signed_values, signer_user_id, signer_name, method,
                                            signature_path, typed_name, ip_address, user_agent, esign_session_id, consent_text)
    values (g.vehicle_id, g.owner_id, g.form_code, g.id, app.government_form_version(g.id), v_sha, case when g.mode = 'pdf' then g.field_values else g.data_sheet end,
            p_by, coalesce(s.signer_name, case when o.owner_type = 'corporation' then coalesce(o.signing_officer_name, o.legal_name) else o.legal_name end, u.full_name),
            v_method, v_path, v_typed, nullif(p ->> 'ip', '')::inet, p ->> 'user_agent', s.id, left(p ->> 'consent_text', 2000))
    returning id into v_sig;
    if s.id is not null then
      insert into esign_events (session_id, kind, detail, ip_address, user_agent)
      values (s.id, 'document_opened', jsonb_build_object('title', g.form_code, 'signature', v_sig), nullif(p ->> 'ip', '')::inet, p ->> 'user_agent');
      perform app.esign_mark(s.id, array['govform:' || g.id::text], null, nullif(p ->> 'ip', '')::inet, p ->> 'user_agent');
    end if;
    v_out := v_out || jsonb_build_array(jsonb_build_object('signature', v_sig, 'fill', g.id, 'form_code', g.form_code));
  end loop;
  return jsonb_build_object('signed', jsonb_array_length(v_out), 'forms', v_out);
end $$;

-- ================================================================ 4. the reads
-- The forms of one of the owner's cars, to show and to sign (the owner's own cars only).
create function app.owner_gov_forms_to_sign(p_by uuid, p jsonb) returns jsonb
language plpgsql stable security definer set search_path = public, app as $$
declare
  v_owner uuid := app.portal_owner_id(p_by);
  v vehicles;
  o owners;
begin
  select * into v from vehicles where id = nullif(p ->> 'vehicle_id', '')::uuid and owner_id = v_owner;
  if v.id is null then return null; end if;
  select * into o from owners where id = v_owner;
  return jsonb_build_object('vehicle_id', v.id, 'vehicle_name', app.vehicle_name(v.id), 'plate', v.plate,
    'signer_name', case when o.owner_type = 'corporation' then coalesce(o.signing_officer_name, o.legal_name) else o.legal_name end,
    'due', app.registry_forms_due(v.id),
    'forms', (select coalesce(jsonb_agg(jsonb_build_object('fill', g.id, 'form_code', g.form_code, 'title', t.title, 'status', g.status, 'mode', g.mode,
                'official', g.mode = 'pdf' and t.file_key is not null, 'missing', to_jsonb(g.missing), 'sha256', app.government_form_values_sha(g.id),
                'state', r.state, 'signable', r.signable, 'signed_at', r.signed_at, 'generated_at', g.generated_at,
                'field_values', case when g.mode = 'pdf' then g.field_values else '{}'::jsonb end, 'field_map', case when g.mode = 'pdf' then t.field_map else '{}'::jsonb end,
                'data_sheet', case when g.mode = 'pdf' then '[]'::jsonb else g.data_sheet end) order by g.form_code), '[]'::jsonb)
                from app.gov_forms_sign_rows(v.id) r join government_form_fills g on g.id = r.id join pdf_templates t on t.id = g.pdf_template_id));
end $$;

-- the forms list: each form's signature state (owner and staff)
alter function app.government_forms_list(uuid, jsonb) rename to government_forms_list_pre1000;
create function app.government_forms_list(p_by uuid, p jsonb) returns jsonb
language plpgsql stable security definer set search_path = public, app as $$
declare
  v jsonb := app.government_forms_list_pre1000(p_by, p);
begin
  if v is null then return v; end if;
  return v || jsonb_build_object('cars', (select coalesce(jsonb_agg(c || jsonb_build_object(
      'to_sign', coalesce((app.gov_forms_sign_counts((c ->> 'vehicle_id')::uuid) ->> 'to_sign')::integer, 0),
      'forms', (select coalesce(jsonb_agg(f || jsonb_build_object('sign_state', app.government_form_sign_state((f ->> 'id')::uuid),
                  'signable', coalesce((select r.signable from app.gov_forms_sign_rows((c ->> 'vehicle_id')::uuid) r where r.id = (f ->> 'id')::uuid), false),
                  'signed_at', (select x.signed_at from government_form_signatures x where x.vehicle_id = (c ->> 'vehicle_id')::uuid and x.form_code = f ->> 'form_code'
                                 order by x.signed_at desc, x.id desc limit 1)) order by m), '[]'::jsonb)
                  from jsonb_array_elements(c -> 'forms') with ordinality e2(f, m))) order by n), '[]'::jsonb)
           from jsonb_array_elements(v -> 'cars') with ordinality e(c, n)));
end $$;
select pg_temp.copy_grants('app.government_forms_list(uuid, jsonb)'::regprocedure, 'app.government_forms_list_pre1000(uuid, jsonb)'::regprocedure);

-- the staff read of one form: its signature state, the signature beside it (not on it) and every signature
alter function app.government_form_fill_read(uuid, jsonb) rename to government_form_fill_read_pre1000;
create function app.government_form_fill_read(p_by uuid, p jsonb) returns jsonb
language plpgsql stable security definer set search_path = public, app as $$
declare
  v jsonb := app.government_form_fill_read_pre1000(p_by, p);
  g government_form_fills;
  s government_form_signatures;
  v_now jsonb;
begin
  if v is null then return v; end if;
  select * into g from government_form_fills where id = (v ->> 'id')::uuid;
  select * into s from government_form_signatures x where x.vehicle_id = g.vehicle_id and x.form_code = g.form_code order by x.signed_at desc, x.id desc limit 1;
  v_now := case when g.mode = 'pdf' then g.field_values else g.data_sheet end;
  return v || jsonb_build_object(
    'sign_state', app.government_form_sign_state(g.id), 'values_sha', app.government_form_values_sha(g.id),
    'signature', case when s.id is null then null else jsonb_build_object('id', s.id, 'signer_name', s.signer_name, 'method', s.method, 'typed_name', s.typed_name,
        'signature_path', case when s.method = 'drawn' then s.signature_path end, 'signed_at', s.signed_at, 'ip', host(s.ip_address), 'user_agent', s.user_agent,
        'form_version', s.form_version, 'current_version', app.government_form_version(g.id), 'session', s.esign_session_id,
        'same_values', s.values_sha = app.government_form_values_sha(g.id),
        'changed', case when g.mode = 'pdf' and jsonb_typeof(s.signed_values) = 'object' then
            (select coalesce(jsonb_agg(k order by k), '[]'::jsonb) from (select e.key k from jsonb_each(s.signed_values) e where (v_now -> e.key) is distinct from e.value
                                                                          union select e.key from jsonb_each(v_now) e where not s.signed_values ? e.key) q)
          else '[]'::jsonb end) end,
    'signatures', (select coalesce(jsonb_agg(jsonb_build_object('id', x.id, 'signer_name', x.signer_name, 'method', x.method, 'signed_at', x.signed_at, 'form_version', x.form_version,
                     'ip', host(x.ip_address)) order by x.signed_at desc, x.id desc), '[]'::jsonb)
                     from government_form_signatures x where x.vehicle_id = g.vehicle_id and x.form_code = g.form_code));
end $$;
select pg_temp.copy_grants('app.government_form_fill_read(uuid, jsonb)'::regprocedure, 'app.government_form_fill_read_pre1000(uuid, jsonb)'::regprocedure);

-- ================================================================ 5. the checklist step and the overview
alter function app.onboarding_checklist(uuid) rename to onboarding_checklist_pre1000;
create function app.onboarding_checklist(p_vehicle uuid)
returns table (code text, label text, sort_order integer, status text, waits_on text, next_action text, owner_action text, staff_action text)
language plpgsql stable security definer set search_path = public, app as $$
declare
  ob vehicle_onboardings;
  v_to_sign integer;
begin
  select * into ob from vehicle_onboardings where vehicle_id = p_vehicle;
  for code, label, sort_order, status, waits_on, next_action, owner_action, staff_action in
    select * from app.onboarding_checklist_pre1000(p_vehicle) c loop
    -- the step is done when every form that applies is signed (a form signed in ink counts)
    if code = 'government_forms' and status = 'done' and not (coalesce(ob.checklist_marks, '{}'::jsonb) ? 'government_forms') then
      select count(*) into v_to_sign from app.gov_forms_sign_rows(p_vehicle) r where r.state in ('unsigned', 'changed');
      if v_to_sign > 0 then
        status := 'open'; waits_on := 'owner';
        next_action := case when exists (select 1 from app.gov_forms_sign_rows(p_vehicle) r where r.state = 'changed') then 'Sign the government forms again: a value changed after you signed' else 'Sign your government forms' end;
      end if;
    end if;
    return next;
  end loop;
end $$;
select pg_temp.copy_grants('app.onboarding_checklist(uuid)'::regprocedure, 'app.onboarding_checklist_pre1000(uuid)'::regprocedure);

alter function app.onboarding_overview(uuid, jsonb) rename to onboarding_overview_pre1000;
create function app.onboarding_overview(p_by uuid, p jsonb) returns jsonb
language plpgsql stable security definer set search_path = public, app as $$
declare
  v jsonb := app.onboarding_overview_pre1000(p_by, p);
begin
  if v is null then return v; end if;
  return v || jsonb_build_object('cars', (select coalesce(jsonb_agg(c || jsonb_build_object('forms', (c -> 'forms') || app.gov_forms_sign_counts((c ->> 'vehicle_id')::uuid)) order by n), '[]'::jsonb)
                                           from jsonb_array_elements(v -> 'cars') with ordinality e(c, n)));
end $$;
select pg_temp.copy_grants('app.onboarding_overview(uuid, jsonb)'::regprocedure, 'app.onboarding_overview_pre1000(uuid, jsonb)'::regprocedure);

-- ================================================================ 6. one reminder email
-- Forms that wait for the owner's signature for a day, or a form changed after it was signed: the signing email, once per
-- state of the car's forms (the dedupe key names the forms and who signed last); an earlier reminder still waiting is replaced.
create function app.government_forms_sign_nudge(p_now timestamptz default now()) returns integer
language plpgsql security definer set search_path = public, app as $$
declare
  r record;
  v_state text;
  v_changed boolean;
  v_old boolean;
  v_n integer := 0;
  v_cnt integer;
  v_key text;
  v_base text := rtrim(coalesce((app.settings()).notify_base_url, 'https://carmacars.ca'), '/');
begin
  for r in select v.id as vehicle_id, o.id as owner_id, o.email, o.first_name, o.legal_name, o.signing_officer_name
             from vehicles v join vehicle_onboardings ob on ob.vehicle_id = v.id join owners o on o.id = v.owner_id
            where v.status not in ('declined', 'exited', 'total_loss') and ob.status not in ('declined', 'withdrawn')
              and o.user_id is not null and nullif(btrim(coalesce(o.email, '')), '') is not null
              and exists (select 1 from app.gov_forms_sign_rows(v.id) x where x.state in ('unsigned', 'changed') and x.signable) loop
    select string_agg(x.form_code || ':' || x.state || ':' || coalesce((select max(s.id::text) from government_form_signatures s where s.vehicle_id = r.vehicle_id and s.form_code = x.form_code), ''), ',' order by x.form_code),
           bool_or(x.state = 'changed'), count(*),
           bool_or(x.state = 'unsigned' and (select min(f.generated_at) from government_form_fills f where f.vehicle_id = r.vehicle_id and f.form_code = x.form_code) <= p_now - interval '1 day')
      into v_state, v_changed, v_cnt, v_old
      from app.gov_forms_sign_rows(r.vehicle_id) x where x.state in ('unsigned', 'changed') and x.signable;
    continue when not (v_changed or v_old);
    v_key := 'owner_forms_to_sign:' || r.vehicle_id || ':' || md5(v_state);
    continue when exists (select 1 from notification_outbox where dedupe_key = v_key);
    update notification_outbox set status = 'skipped', status_reason = 'Replaced by a newer reminder'
     where dedupe_key like 'owner_forms_to_sign:' || r.vehicle_id || ':%' and status in ('queued', 'delayed');
    insert into notification_outbox (code, category, priority, audience, to_address, to_name, owner_id, vehicle_id, entity, entity_id, payload, missing_variables, dedupe_key, status, send_after)
    values ('owner_agreement_to_sign', 'transactional', 3, 'owner', r.email, coalesce(r.legal_name, r.signing_officer_name), r.owner_id, r.vehicle_id, 'vehicle', r.vehicle_id,
            jsonb_build_object('first_name', coalesce(nullif(r.first_name, ''), split_part(coalesce(r.signing_officer_name, r.legal_name), ' ', 1)),
                               'agreement_title', 'registration paperwork for your ' || app.vehicle_name(r.vehicle_id),
                               'note', case when v_changed then 'A value on a government form changed after you signed it, so the form needs your signature again. '
                                        else '' end
                                    || format('%s government form%s waiting for your signature. Open each form, check it and sign it on screen; you still print them and sign in ink at the registry.', v_cnt, case when v_cnt = 1 then ' is' else 's are' end),
                               'sign_url', v_base || '/owner/sign/forms/' || r.vehicle_id),
            '{}'::text[], v_key, 'queued', p_now);
    v_n := v_n + 1;
  end loop;
  return v_n;
end $$;

alter function app.notify_daily_checks(timestamptz) rename to notify_daily_checks_pre1000;
create function app.notify_daily_checks(p_now timestamptz default now()) returns integer
language plpgsql security definer set search_path = public, app as $$
declare
  v_n integer := app.notify_daily_checks_pre1000(p_now);
begin
  begin
    v_n := v_n + app.government_forms_sign_nudge(p_now);
  exception when others then
    insert into audit_log (action, entity_table, entity_id, after) values ('government_forms_sign_nudge_failed', 'vehicles', null, jsonb_build_object('error', sqlerrm));
  end;
  return v_n;
end $$;
select pg_temp.copy_grants('app.notify_daily_checks(timestamptz)'::regprocedure, 'app.notify_daily_checks_pre1000(timestamptz)'::regprocedure);

-- ================================================================ the server's calls and privileges
create function public.owner_gov_forms_sign(p_by uuid, p jsonb) returns jsonb
language sql volatile security invoker set search_path = public, app as $$ select app.owner_gov_forms_sign(p_by, p) $$;
create function public.owner_gov_forms_to_sign(p_by uuid, p jsonb) returns jsonb
language sql stable security invoker set search_path = public, app as $$ select app.owner_gov_forms_to_sign(p_by, p) $$;

do $$
declare f record;
begin
  for f in select p.oid::regprocedure as sig from pg_proc p join pg_namespace n on n.oid = p.pronamespace
            where (n.nspname = 'app' and p.proname = any (array['government_form_values_sha', 'government_form_sign_state', 'gov_forms_sign_rows', 'gov_forms_sign_counts',
              'esign_start_documents_pre1000', 'owner_gov_forms_sign', 'owner_gov_forms_to_sign', 'government_forms_list_pre1000', 'government_form_fill_read_pre1000',
              'onboarding_checklist_pre1000', 'onboarding_overview_pre1000', 'government_forms_sign_nudge', 'notify_daily_checks_pre1000', 'government_form_signatures_append_only']))
               or (n.nspname = 'public' and p.proname in ('owner_gov_forms_sign', 'owner_gov_forms_to_sign'))
  loop
    execute format('revoke all on function %s from public, anon, authenticated', f.sig);
    execute format('grant execute on function %s to service_role', f.sig);
  end loop;
end $$;
