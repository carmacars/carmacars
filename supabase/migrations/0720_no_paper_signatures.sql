-- 0720: no paper signatures for anyone, and Form D signed on screen (Release 33, part F). SCHEMA_MARKER 0722 (with
-- 0721 and the guides of 0722). Record: docs/changes/2026-11-07-r33-signatures-terms.md. No applied migration is
-- edited; the functions it changes are wrapped (renamed with the suffix _pre0720).
--
-- The owner, November 7, 2026:
-- 1. Every agreement on the platform (rental agreements and their changes, owner agreements of every route, investor,
--    staff and contractor, partner) is signed only through the full e-signature flow (the signing session, the IP
--    address, the audit trail). The database refuses a new signature recorded on paper: a paper record, a paper
--    signature record or request, a Vehicle Schedule marked signed on paper, a partner agreement on paper, a rental
--    added "signed on paper", an owner added to sign on paper, and a Form C or D uploaded as a photo of a paper copy.
--    The records already on file stay as they are and stay readable (and voidable).
--    The official ServiceOntario forms the government requires in ink are not our agreements: they stay printable as
--    today, and the copy signed in ink is still recorded (paper_signatures.doc_type registry_form).
-- 2. Form D of the Title Agreement (the limited power of attorney) is signed on screen like Form C: the owner signs with
--    the signing steps of every signature, and the two witnesses, beside the owner on the same device, type their names
--    and the statement. Part 2 (from CarmaCars) is signed for CarmaCars from the stored signatures: the signing officer
--    (program_settings.signing_officer_name, the automatic countersignature) and, as CarmaCars' witness, the second
--    signing officer (program_settings.second_signing_officer_name, new here; empty until an Admin sets it in Program
--    settings).
-- 3. The fleet supplier route (0710) gets Form D in its packet after all (0710 left Forms C and D out): Form C stays out.
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

-- ================================================================ 1. the database refuses a new paper signature
-- The database tests build records signed on paper before this release as fixtures: a superuser session (the test
-- runner, never the website, whose database API signs in as a role without that right) may set app.paper_fixture.
create function app.paper_fixture() returns boolean
language sql stable security invoker set search_path = public, app as $$
  select coalesce(current_setting('app.paper_fixture', true), '') = 'on'
     and exists (select 1 from pg_roles r where r.rolname = session_user and r.rolsuper)
$$;

create function app.paper_message() returns text
language sql immutable as $$
  select 'Every agreement is signed in the portal only (the e-signature with its audit trail): a signature on paper is no longer recorded. Send the person their signing link instead'::text
$$;

create function app.no_paper_guard() returns trigger
language plpgsql security definer set search_path = public, app as $$
begin
  if app.paper_fixture() then return new; end if;
  if tg_table_name = 'paper_signatures' then
    -- the official ServiceOntario forms are signed in ink (the government's rule): that copy is still recorded
    if new.doc_type = 'registry_form' then return new; end if;
    raise exception '%', app.paper_message() using errcode = '23514';
  elsif tg_table_name = 'signature_records' then
    if new.method = 'paper' then raise exception '%', app.paper_message() using errcode = '23514'; end if;
  elsif tg_table_name = 'signature_requests' then
    if new.provider = 'paper' then raise exception '%', app.paper_message() using errcode = '23514'; end if;
  elsif tg_table_name = 'vehicle_term_changes' then
    if new.signed_method = 'paper' and (tg_op = 'INSERT' or old.signed_method is distinct from 'paper') then
      raise exception 'The owner signs the updated Vehicle Schedule in the owner portal only (the e-signature with its audit trail): it is no longer marked signed on paper' using errcode = '23514';
    end if;
  elsif tg_table_name = 'partners' then
    if new.agreement_method = 'paper' and (tg_op = 'INSERT' or old.agreement_method is distinct from 'paper') then
      raise exception '%', app.paper_message() using errcode = '23514';
    end if;
  elsif tg_table_name = 'bookings' then
    if new.agreement_on_paper and (tg_op = 'INSERT' or not old.agreement_on_paper) then
      raise exception 'The renter signs the rental agreement in the portal only (the e-signature with its audit trail): choose "Email the renter the link to sign"' using errcode = '23514';
    end if;
  elsif tg_table_name = 'owner_agreement_forms' then
    if new.form_code in ('C', 'D1') and coalesce(new.signed_method, 'upload') <> 'screen' then
      raise exception 'Forms C and D are signed on screen in the owner portal, with the witnesses beside the owner on the same device: a photo of a paper copy is no longer accepted' using errcode = '23514';
    end if;
  end if;
  return new;
end $$;

create trigger paper_signatures_no_paper before insert on paper_signatures for each row execute function app.no_paper_guard();
create trigger signature_records_no_paper before insert on signature_records for each row execute function app.no_paper_guard();
create trigger signature_requests_no_paper before insert on signature_requests for each row execute function app.no_paper_guard();
create trigger vehicle_term_changes_no_paper before insert or update of signed_method on vehicle_term_changes for each row execute function app.no_paper_guard();
create trigger partners_no_paper before insert or update of agreement_method on partners for each row execute function app.no_paper_guard();
create trigger bookings_no_paper before insert or update of agreement_on_paper on bookings for each row execute function app.no_paper_guard();
create trigger owner_agreement_forms_no_paper before insert on owner_agreement_forms for each row execute function app.no_paper_guard();

-- Staff add an owner and a car: the owner always gets the email to review and sign (no "signs on paper").
alter function app.staff_add_owner_car(uuid, jsonb) rename to staff_add_owner_car_pre0720;
create function app.staff_add_owner_car(p_by uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
begin
  if coalesce(p ->> 'signing', 'email') = 'paper' and not app.paper_fixture() then
    raise exception 'The owner signs in the owner portal only (the e-signature with its audit trail): choose "Email the owner to review and sign"' using errcode = '22023';
  end if;
  return app.staff_add_owner_car_pre0720(p_by, p);
end $$;
select pg_temp.copy_grants('app.staff_add_owner_car(uuid, jsonb)'::regprocedure, 'app.staff_add_owner_car_pre0720(uuid, jsonb)'::regprocedure);

-- The Admin to-do no longer asks to "record a paper signature" (0078's kind paper): the owner is waiting to sign in the
-- portal, and the line says so (send the signing link again).
alter function app.todo_prompts(uuid) rename to todo_prompts_pre0720;
create function app.todo_prompts(p_by uuid) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  v jsonb := app.todo_prompts_pre0720(p_by);
begin
  if jsonb_typeof(v -> 'prompts') = 'array' then
    v := jsonb_set(v, '{prompts}', (select coalesce(jsonb_agg(case when x ->> 'kind' = 'paper'
        then x || jsonb_build_object('title', regexp_replace(x ->> 'title', ': record a paper signature if they signed on paper$', ': waiting for their signature in the owner portal'),
                                     'why', 'Their cars stay in onboarding until the agreements are signed in the owner portal (a signature on paper is not recorded). Open the owner to send the link again.')
        else x end order by n), '[]'::jsonb) from jsonb_array_elements(v -> 'prompts') with ordinality t(x, n)));
  end if;
  return v;
end $$;
select pg_temp.copy_grants('app.todo_prompts(uuid)'::regprocedure, 'app.todo_prompts_pre0720(uuid)'::regprocedure);

comment on function app.no_paper_guard() is 'No new signature on paper (0720): every agreement is signed through the e-signature flow. Records already on file stay readable. The ServiceOntario forms signed in ink (paper_signatures.doc_type registry_form) are still recorded.';

-- ================================================================ 2. the second CarmaCars signer
alter table program_settings
  add column if not exists second_signing_officer_name text check (second_signing_officer_name is null or length(btrim(second_signing_officer_name)) between 2 and 120),
  add column if not exists second_signing_officer_title text check (second_signing_officer_title is null or length(btrim(second_signing_officer_title)) between 2 and 80);
comment on column program_settings.second_signing_officer_name is 'The second person who signs for CarmaCars (0720): CarmaCars'' witness on Part 2 of Form D (the limited power of attorney), applied from this setting when the owner signs. Empty: Part 2 carries the signing officer''s signature only and the witness spot says it is to be added.';
comment on column program_settings.second_signing_officer_title is 'The second signing officer''s title (0720), printed under the signature.';

-- ================================================================ 3. Form D on screen
alter table sign_requests drop constraint if exists sign_requests_doc_type_check;
alter table sign_requests add constraint sign_requests_doc_type_check
  check (doc_type in ('form_a', 'form_b', 'form_c', 'form_d', 'investment_agreement', 'staff_agreement', 'partner_agreement', 'referral_agreement'));
alter table sign_requests add constraint sign_requests_form_d_owner check (doc_type <> 'form_d' or owner_id is not null);

-- The fleet supplier's packet (0710 left Forms C and D out): Form D, once per supplier. Form C stays out.
alter function app.owner_witnessed_forms(uuid) rename to owner_witnessed_forms_pre0720;
create function app.owner_witnessed_forms(p_owner uuid) returns jsonb
language sql stable security definer set search_path = public, app as $$
  select case when app.fleet_supplier(p_owner)
              then coalesce((select jsonb_agg(x) from jsonb_array_elements(app.owner_witnessed_forms_pre0710(p_owner)) x where x ->> 'code' = 'D1'), '[]'::jsonb)
              else app.owner_witnessed_forms_pre0720(p_owner) end
$$;
select pg_temp.copy_grants('app.owner_witnessed_forms(uuid)'::regprocedure, 'app.owner_witnessed_forms_pre0720(uuid)'::regprocedure);

create function app.owner_form_d_open(p_by uuid, p_sha256 text, p_path text, p_template_version text) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  o owners;
  v_owner uuid := app.portal_owner_id(p_by);
  r sign_requests;
  v_doc uuid;
  v_req uuid;
begin
  select * into o from owners where id = v_owner;
  if o.id is null then raise exception 'This account is not an owner account' using errcode = '42501'; end if;
  if not exists (select 1 from jsonb_array_elements(app.owner_witnessed_forms(o.id)) x
                  where x ->> 'code' = 'D1' and x ->> 'status' in ('needed', 'rejected')) then
    raise exception 'Form D is not waiting for your signature' using errcode = '23514';
  end if;
  if lower(coalesce(p_sha256, '')) !~ '^[0-9a-f]{64}$' or coalesce(p_path, '') !~ ('^owners/' || o.id || '/') then
    raise exception 'The form document is missing' using errcode = '22023';
  end if;
  select * into r from sign_requests where owner_id = o.id and doc_type = 'form_d' and status = 'sent' for update;
  if r.id is not null and r.document_sha256 = lower(p_sha256) then return to_jsonb(r); end if;
  if r.id is not null then
    update sign_requests set status = 'voided', voided_at = now(), voided_by = p_by, void_reason = 'The form was made again' where id = r.id;
    update signature_requests set status = 'voided' where id = r.signature_request_id;
  end if;
  insert into documents (kind, title, storage_bucket, storage_path, mime_type, sha256, template_version, owner_id, uploaded_by)
  values ('form_d_power_of_attorney', 'Form D, limited power of attorney', 'agreements', p_path, 'application/pdf', lower(p_sha256), p_template_version, o.id, p_by)
  returning id into v_doc;
  insert into signature_requests (document_id, provider, status, sent_at, created_by) values (v_doc, 'builtin', 'sent', now(), p_by) returning id into v_req;
  insert into sign_requests (doc_type, owner_id, signer_user_id, signer_name, signer_email, signer_role, title, document_id, document_sha256, template_version,
                             signature_request_id, sent_by)
  values ('form_d', o.id, p_by, o.legal_name, o.email, case when o.owner_type = 'corporation' then 'owner_corporation' else 'owner_individual' end,
          'Form D, limited power of attorney', v_doc, lower(p_sha256), p_template_version, v_req, p_by)
  returning * into r;
  return to_jsonb(r);
end $$;

create function public.owner_form_d_open(p_by uuid, p_sha256 text, p_path text, p_template_version text) returns jsonb
language sql volatile security invoker set search_path = public, app as $$ select app.owner_form_d_open(p_by, p_sha256, p_path, p_template_version) $$;

-- Signing Form D: the two witnesses (typed on screen, in person), then Part 2 for CarmaCars from the stored signatures.
alter function app.sign_request_sign(uuid, uuid, jsonb) rename to sign_request_sign_pre0720;
create function app.sign_request_sign(p_user uuid, p_id uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  r sign_requests;
  v_out jsonb;
  v_w1 text := nullif(btrim(coalesce(p ->> 'witness_name', '')), '');
  v_w2 text := nullif(btrim(coalesce(p ->> 'witness_2_name', '')), '');
  v_stmt text;
  v_form uuid;
  v_wit uuid[] := '{}';
  v_id uuid;
  s program_settings := app.settings();
  norm text;
begin
  select * into r from sign_requests where id = p_id;
  if r.doc_type is distinct from 'form_d' then return app.sign_request_sign_pre0720(p_user, p_id, p); end if;
  if r.id is null or r.signer_user_id is distinct from p_user then raise exception 'Not found' using errcode = 'P0002'; end if;
  v_stmt := format('I witnessed %s sign in my presence.', r.signer_name);
  norm := lower(regexp_replace(r.signer_name, '\s+', '', 'g'));
  if v_w1 is null or length(v_w1) < 3 or v_w2 is null or length(v_w2) < 3 then raise exception 'Both witnesses type their full names' using errcode = '22023'; end if;
  if lower(regexp_replace(v_w1, '\s+', '', 'g')) = norm or lower(regexp_replace(v_w2, '\s+', '', 'g')) = norm then
    raise exception 'Each witness is another adult, not the owner' using errcode = '23514';
  end if;
  if lower(regexp_replace(v_w1, '\s+', '', 'g')) = lower(regexp_replace(v_w2, '\s+', '', 'g')) then
    raise exception 'The two witnesses are two different people' using errcode = '23514';
  end if;
  if coalesce(p ->> 'witness_statement', '') <> v_stmt or coalesce(p ->> 'witness_2_statement', '') <> v_stmt then
    raise exception 'Each witness ticks the statement "%"', v_stmt using errcode = '22023';
  end if;
  v_out := app.sign_request_sign_pre0720(p_user, p_id, p);
  select * into r from sign_requests where id = p_id;
  if r.status <> 'signed' then return v_out; end if;
  -- Part 1: the owner's two witnesses
  insert into signature_records (signature_request_id, signer_role, signer_name, status, signed_at, method, ip_address, user_agent, typed_name, consent_text, document_sha256)
  values (r.signature_request_id, 'witness', v_w1, 'signed', now(), 'typed', nullif(p ->> 'ip', '')::inet, nullif(p ->> 'user_agent', ''), v_w1, v_stmt, r.document_sha256)
  returning id into v_id;
  v_wit := v_wit || v_id;
  insert into signature_records (signature_request_id, signer_role, signer_name, status, signed_at, method, ip_address, user_agent, typed_name, consent_text, document_sha256)
  values (r.signature_request_id, 'witness', v_w2, 'signed', now(), 'typed', nullif(p ->> 'ip', '')::inet, nullif(p ->> 'user_agent', ''), v_w2, v_stmt, r.document_sha256)
  returning id into v_id;
  v_wit := v_wit || v_id;
  -- Part 2: CarmaCars signs (the signing officer, the automatic countersignature; the trigger gives it the officer's name
  -- and the approved wording) and its witness signs (the second signing officer, from Program settings)
  insert into signature_records (signature_request_id, signer_role, signer_name, signer_email, status, signed_at, method, document_sha256)
  values (r.signature_request_id, 'carmacars', s.company_trade_name, s.company_email, 'signed', now(), 'automatic', r.document_sha256);
  if nullif(btrim(s.second_signing_officer_name), '') is not null then
    insert into signature_records (signature_request_id, signer_role, signer_name, signer_title, status, signed_at, method, typed_name, consent_text, document_sha256)
    values (r.signature_request_id, 'witness', btrim(s.second_signing_officer_name), nullif(btrim(s.second_signing_officer_title), ''), 'signed', now(), 'stored_signature',
            btrim(s.second_signing_officer_name),
            format('Witnessed for %s, by %s%s, from the stored signature, when the owner signed.', coalesce(nullif(btrim(s.company_legal_name), ''), s.company_trade_name),
                   btrim(s.second_signing_officer_name), coalesce(', ' || nullif(btrim(s.second_signing_officer_title), ''), '')),
            r.document_sha256);
  end if;
  update signature_requests set status = 'completed', completed_at = coalesce(completed_at, now()) where id = r.signature_request_id;
  update owner_agreement_forms set status = 'replaced' where owner_id = r.owner_id and form_code = 'D1' and status = 'uploaded';
  insert into owner_agreement_forms (owner_agreement_id, owner_id, form_code, vehicle_id, document_id, signature_request_id, signed_at, witness_1_name, witness_2_name,
                                     status, signed_method, uploaded_by, reviewed_by, reviewed_at)
  values ((select id from owner_agreements where owner_id = r.owner_id and kind = 'title_holding' and status <> 'void' order by created_at desc limit 1),
          r.owner_id, 'D1', null, r.document_id, r.signature_request_id, now(), v_w1, v_w2, 'approved', 'screen', p_user, p_user, now())
  returning id into v_form;
  update tasks set status = 'done', completed_at = now(), completion_note = 'Signed on screen with two witnesses'
   where task_type = 'owner_form_review' and owner_id = r.owner_id and status in ('open', 'in_progress', 'waiting')
     and related_id in (select f.id from owner_agreement_forms f where f.owner_id = r.owner_id and f.form_code = 'D1');
  return v_out || jsonb_build_object('form_id', v_form, 'witness_record_ids', to_jsonb(v_wit));
end $$;
select pg_temp.copy_grants('app.sign_request_sign(uuid, uuid, jsonb)'::regprocedure, 'app.sign_request_sign_pre0720(uuid, uuid, jsonb)'::regprocedure);

alter function app.sign_request_attach(uuid, text, text) rename to sign_request_attach_pre0720;
create function app.sign_request_attach(p_id uuid, p_path text, p_sha256 text) returns uuid
language plpgsql security definer set search_path = public, app as $$
declare
  v_doc uuid := app.sign_request_attach_pre0720(p_id, p_path, p_sha256);
  r sign_requests;
begin
  select * into r from sign_requests where id = p_id;
  if r.doc_type = 'form_d' then
    update owner_agreement_forms set document_id = v_doc where signature_request_id = r.signature_request_id and status = 'approved';
  end if;
  return v_doc;
end $$;
select pg_temp.copy_grants('app.sign_request_attach(uuid, text, text)'::regprocedure, 'app.sign_request_attach_pre0720(uuid, text, text)'::regprocedure);

-- The signatures of Part 2 and the witnesses, for the signed copy (the server renders it).
create function public.server_form_d_signers(p_request uuid) returns jsonb
language sql stable security definer set search_path = public, app as $$
  select coalesce(jsonb_agg(jsonb_build_object('role', x.signer_role, 'name', x.signer_name, 'title', x.signer_title, 'method', x.method,
                                               'signed_at', x.signed_at, 'consent_text', x.consent_text) order by x.created_at, x.id), '[]'::jsonb)
    from signature_records x join sign_requests r on r.signature_request_id = x.signature_request_id
   where r.id = p_request and r.doc_type = 'form_d' and x.signer_role in ('witness', 'carmacars')
$$;

-- What Form D's Part 2 shows before signing: who signs for CarmaCars.
create function public.server_company_signers() returns jsonb
language sql stable security definer set search_path = public, app as $$
  select jsonb_build_object('officer', nullif(btrim(s.signing_officer_name), ''), 'officer_title', nullif(btrim(s.signing_officer_title), ''),
                            'second', nullif(btrim(s.second_signing_officer_name), ''), 'second_title', nullif(btrim(s.second_signing_officer_title), ''))
    from app.settings() s
$$;

-- ================================================================ 4. privileges
do $$
declare
  f record;
begin
  for f in
    select p.oid::regprocedure as sig from pg_proc p join pg_namespace n on n.oid = p.pronamespace
     where (n.nspname = 'app' and p.proname = any (array['paper_fixture', 'paper_message', 'no_paper_guard', 'staff_add_owner_car_pre0720', 'todo_prompts_pre0720', 'owner_witnessed_forms_pre0720',
              'owner_form_d_open', 'sign_request_sign_pre0720', 'sign_request_attach_pre0720']))
        or (n.nspname = 'public' and p.proname = any (array['owner_form_d_open', 'server_form_d_signers', 'server_company_signers']))
  loop
    execute format('revoke all on function %s from public, anon, authenticated', f.sig);
    execute format('grant execute on function %s to service_role', f.sig);
  end loop;
end $$;
