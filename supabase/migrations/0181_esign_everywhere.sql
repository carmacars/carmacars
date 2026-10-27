-- 0181_esign_everywhere.sql
-- Every signature on the site goes through the signing session of 0154 (docs/changes/2026-10-27-esign-everywhere.md).
-- The owner: "do it for every signature across the site, even owner agreements and staff agreements."
--
-- 0154 gave the rental agreements a signature that holds up: a one-time code to the signer's phone or email, the
-- documents read, initials on the key terms, the consents, a drawn signature (typed only with the Admin's accessibility
-- fallback), each step with its time, IP address, device and place (esign_sessions, esign_events), a certificate of
-- completion on every signed PDF and its SHA-256 checked on /verify. This migration uses the same tables and steps for
-- every other signature:
--   1. The owner's documents (the Enrollment and Title-Holding Agreements, the Vehicle Schedules, Forms A and B, the
--      partner agreement): context 'documents', signer_ref the signer's user. One session covers a signing package
--      (several documents, one signature); each document is checked against the session (its SHA-256) when it is signed.
--   2. Another Owner named in the Title Schedule signing with their link: context 'owner_cosigner' (the code by email).
--   3. Form C on screen (the owner's part; the witness beside them still types their name), the investment agreement,
--      the staff agreements (VA and field), an updated Vehicle Schedule: context 'documents'.
--   The key terms initialled come from the documents (app.esign_doc_initials): the Enrollment Agreement's three
--   confirmations, Form C's three acknowledgments, the investment agreement's Schedule C, the staff agreement's
--   confidentiality, rules and ending, the partner agreement's money, insurance and ending, the updated schedule's terms.
--   The consents: to sign electronically and to receive the records electronically.
-- The signing functions refuse a signature without a complete session (esign_strict, on): app.sign_request_sign,
-- app.owner_sign_agreements, app.owner_cosigner_sign, app.schedule_change_sign. Each signature record names its session
-- (signature_records.esign_session_id); a session is closed once every document it covered is signed.
-- The signed copies get the certificate of completion (public.server_esign_certificate_for_request) and /verify finds
-- every signed copy (public.server_verify_sha). An updated Vehicle Schedule now has a signed PDF too.
-- The code by email for these signers is its own email, document_signing_code (the renter's names the booking).
-- Not changed: the condition reports signed by the renter and the staff member on the staff device at check-out and
-- check-in (both present, the staff member signed in), and CarmaCars' automatic countersignatures.
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

-- ================================================================ 1. the sessions of documents
alter table esign_sessions drop constraint if exists esign_sessions_context_check;
alter table esign_sessions add constraint esign_sessions_context_check
  check (context in ('rental_agreement', 'amendment', 'agreement_version', 'documents', 'owner_cosigner'));
alter table esign_sessions add column if not exists signer_user_id uuid references users (id);
alter table esign_sessions add column if not exists owner_id uuid references owners (id);
alter table esign_sessions add column if not exists signed_refs text[] not null default '{}';
comment on column esign_sessions.signed_refs is 'Documents of the session signed so far (0181), as kind:ref; the session is closed when every document it covered is signed.';
comment on column esign_sessions.documents is 'What the signer was shown: [{title, sha256}] (0154); for documents and co-owners (0181) also {kind: packet | request | schedule_change, ref}.';
create index if not exists esign_sessions_user on esign_sessions (signer_user_id) where signer_user_id is not null;

alter table signature_records add column if not exists esign_session_id uuid references esign_sessions (id);
create index if not exists signature_records_esign on signature_records (esign_session_id) where esign_session_id is not null;
comment on column signature_records.esign_session_id is 'The signing session (identity code, initials, consents, drawn signature) of this signature (0181).';
alter table vehicle_term_changes add column if not exists esign_session_id uuid references esign_sessions (id);
comment on column vehicle_term_changes.esign_session_id is 'The signing session of the owner''s signature of the updated Vehicle Schedule (0181).';

-- The key terms each document asks to initial (codes of web/src/features/signing/terms.ts).
create or replace function app.esign_doc_initials(p_kind text, p_ref text, p_doc_type text default null, p_generated boolean default false) returns text[]
language sql immutable as $$
  select case
    when p_kind = 'packet' and p_ref = 'enrollment' then array['own_insurance', 'fees_no_income', 'tracker_downtime']
    when p_kind = 'schedule_change' then array['schedule_terms']
    when p_kind = 'request' and p_doc_type = 'form_c' then array['read_warning', 'no_advice', 'bears_consequences']
    when p_kind = 'request' and p_doc_type = 'investment_agreement' then array['schedule_c']
    when p_kind = 'request' and p_doc_type = 'staff_agreement' and p_generated then array['staff_confidentiality', 'staff_rules', 'staff_ending']
    when p_kind = 'request' and p_doc_type = 'partner_agreement' then array['partner_money', 'partner_insurance', 'partner_ending']
    else '{}'::text[] end
$$;

-- The text of an updated Vehicle Schedule and its SHA-256 (what the owner signs, 0067).
create or replace function app.schedule_change_sha(p_change uuid) returns text
language sql stable security definer set search_path = public, app as $$
  select encode(sha256(convert_to(app.schedule_change_text(p_change) ->> 'text', 'UTF8')), 'hex')
$$;

-- Start (or pick up) a session of documents or of a co-owner. p: context, signer_ref (the user, or owner_cosigners.id),
-- owner_id (with the owner's own documents), documents [{kind, ref, title, sha256}], ip, user_agent. Every document is
-- checked here against the records: open, the signer's, the same SHA-256. The name and the contact come from the records.
create or replace function app.esign_start_documents(p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  v_ctx text := p ->> 'context';
  v_ref uuid := (p ->> 'signer_ref')::uuid;
  v_docs jsonb := coalesce(p -> 'documents', '[]'::jsonb);
  d jsonb;
  s esign_sessions;
  o owners;
  c owner_cosigners;
  r sign_requests;
  tc vehicle_term_changes;
  u users;
  v_name text; v_email text; v_mobile text; v_owner uuid;
  v_ini text[] := '{}';
  x text;
  v_kind text; v_dref text; v_sha text;
begin
  if jsonb_typeof(v_docs) <> 'array' or jsonb_array_length(v_docs) = 0 then raise exception 'Nothing to sign here' using errcode = 'P0002'; end if;
  if v_ctx = 'owner_cosigner' then
    select * into c from owner_cosigners where id = v_ref and status = 'pending';
    if c.id is null then raise exception 'Nothing is waiting for your signature' using errcode = 'P0002'; end if;
    -- every open document of the owner, each with the SHA-256 the signer was shown
    if exists (select 1 from app.owner_open_requests(c.owner_id) q
                where not exists (select 1 from jsonb_array_elements(v_docs) y where y ->> 'ref' = q.key and lower(y ->> 'sha256') = q.sha256))
       or jsonb_array_length(v_docs) <> (select count(*) from app.owner_open_requests(c.owner_id)) then
      raise exception 'The documents changed after you opened them: reload and sign the current version' using errcode = '23514';
    end if;
    v_name := c.name; v_email := c.email; v_owner := c.owner_id;
    if exists (select 1 from jsonb_array_elements(v_docs) y where y ->> 'ref' = 'enrollment') then v_ini := app.esign_doc_initials('packet', 'enrollment'); end if;
  else
    select * into u from users where id = v_ref;
    if u.id is null then raise exception 'Sign in first' using errcode = '42501'; end if;
    for d in select value from jsonb_array_elements(v_docs) loop
      v_kind := d ->> 'kind'; v_dref := d ->> 'ref'; v_sha := lower(btrim(coalesce(d ->> 'sha256', '')));
      if v_kind = 'packet' then
        if o.id is null then
          select * into o from owners where id = nullif(p ->> 'owner_id', '')::uuid;
          if o.id is null or not (app.user_is_owner_of(v_ref, o.id) or o.user_id = v_ref) then
            raise exception 'Only the owner signs the owner''s agreements' using errcode = '42501';
          end if;
        end if;
        if not exists (select 1 from app.owner_open_requests(o.id) q where q.key = v_dref and q.sha256 = v_sha) then
          raise exception 'The documents changed after you opened them: reload and sign the current version' using errcode = '23514';
        end if;
        v_owner := o.id;
        v_name := coalesce(v_name, case when o.owner_type = 'corporation' then coalesce(o.signing_officer_name, o.legal_name) else o.legal_name end);
        foreach x in array app.esign_doc_initials('packet', v_dref) loop if not x = any (v_ini) then v_ini := v_ini || x; end if; end loop;
      elsif v_kind = 'request' then
        select * into r from sign_requests where id = nullif(v_dref, '')::uuid;
        if r.id is null or r.signer_user_id is distinct from v_ref then raise exception 'Not found' using errcode = 'P0002'; end if;
        if r.status <> 'sent' then raise exception 'This document is % and is not waiting for your signature', r.status using errcode = '23514'; end if;
        if r.document_sha256 <> v_sha then raise exception 'The document changed after it was opened: reload and sign the current version' using errcode = '23514'; end if;
        v_owner := coalesce(v_owner, r.owner_id);
        v_name := coalesce(v_name, r.signer_name);
        foreach x in array app.esign_doc_initials('request', v_dref, r.doc_type, coalesce((r.extra ->> 'generated')::boolean, false)) loop
          if not x = any (v_ini) then v_ini := v_ini || x; end if;
        end loop;
      elsif v_kind = 'schedule_change' then
        select * into tc from vehicle_term_changes where id = nullif(v_dref, '')::uuid;
        if tc.id is null or not app.user_owns_vehicle(v_ref, tc.vehicle_id) then raise exception 'Not found' using errcode = 'P0002'; end if;
        if tc.status <> 'awaiting_signature' then raise exception 'This Vehicle Schedule is not waiting for your signature' using errcode = '23514'; end if;
        if app.schedule_change_sha(tc.id) <> v_sha then raise exception 'The schedule changed since you opened it. Open it again and sign.' using errcode = '23514'; end if;
        select * into o from owners where id = (select v.owner_id from vehicles v where v.id = tc.vehicle_id);
        v_owner := o.id;
        v_name := coalesce(v_name, case when o.owner_type = 'corporation' then coalesce(o.signing_officer_name, o.legal_name) else o.legal_name end);
        foreach x in array app.esign_doc_initials('schedule_change', v_dref) loop if not x = any (v_ini) then v_ini := v_ini || x; end if; end loop;
      else
        raise exception 'Unknown document' using errcode = '22023';
      end if;
    end loop;
    v_email := coalesce(nullif(u.email, ''), (select nullif(x2.email, '') from owners x2 where x2.id = v_owner));
    v_mobile := coalesce(nullif(u.phone, ''), (select nullif(x2.phone, '') from owners x2 where x2.id = v_owner));
    v_name := coalesce(v_name, u.full_name);
  end if;
  select * into s from esign_sessions where context = v_ctx and signer_ref = v_ref and method = 'remote' and signed_at is null
     and created_at > now() - interval '2 hours' and documents = v_docs
   order by created_at desc limit 1;
  if s.id is null then
    insert into esign_sessions (context, signer_ref, signer_role, signer_name, signer_user_id, owner_id, method, documents, email, mobile,
                                required_initials, required_consents, ip_address, user_agent)
    values (v_ctx, v_ref, case when v_ctx = 'owner_cosigner' then 'owner' else coalesce(nullif(p ->> 'role', ''), 'signer') end, v_name,
            case when v_ctx = 'documents' then v_ref end, v_owner, 'remote', v_docs, nullif(v_email, ''), nullif(v_mobile, ''),
            v_ini, array['esign', 'erecords'], nullif(p ->> 'ip', '')::inet, p ->> 'user_agent')
    returning * into s;
    insert into esign_events (session_id, kind, detail, ip_address, user_agent)
    values (s.id, 'started', jsonb_build_object('method', 'remote', 'documents', (select jsonb_agg(jsonb_build_object('title', y ->> 'title', 'sha256', y ->> 'sha256')) from jsonb_array_elements(v_docs) y)),
            nullif(p ->> 'ip', '')::inet, p ->> 'user_agent');
  end if;
  return app.esign_view(s.id);
end $$;

alter function public.server_esign_start(jsonb) rename to server_esign_start_pre0181;
alter function public.server_esign_start_pre0181(jsonb) set schema app;
create or replace function public.server_esign_start(p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
begin
  if p ->> 'context' in ('documents', 'owner_cosigner') then return app.esign_start_documents(p); end if;
  return app.server_esign_start_pre0181(p);
end $$;

-- The newest complete session of a signer that covers this document (not signed with it yet).
create or replace function app.esign_ready_doc(p_context text, p_ref uuid, p_kind text, p_doc text, p_sha text) returns esign_sessions
language sql stable security definer set search_path = public, app as $$
  select s.* from esign_sessions s
   where s.context = p_context and s.signer_ref = p_ref and app.esign_is_ready(s)
     and exists (select 1 from jsonb_array_elements(s.documents) d where d ->> 'kind' = p_kind and d ->> 'ref' = p_doc and lower(d ->> 'sha256') = lower(btrim(coalesce(p_sha, ''))))
     and not ((p_kind || ':' || p_doc) = any (s.signed_refs))
   order by s.created_at desc limit 1
$$;

-- The signature sent with the signing call is the session's: the drawn one stored by the drawing step, or a typed name
-- only when the Admin's fallback is on (esign_is_ready checks it).
create or replace function app.esign_signature_matches(s esign_sessions, p_drawn text, p_typed text) returns void
language plpgsql stable as $$
begin
  if s.signature_method = 'drawn' and nullif(btrim(coalesce(p_drawn, '')), '') is distinct from s.signature_path then
    raise exception 'The signature does not match the one drawn: sign again' using errcode = '23514';
  end if;
  if s.signature_method = 'typed' and nullif(btrim(coalesce(p_typed, '')), '') is null then
    raise exception 'Type your full legal name' using errcode = '22023';
  end if;
end $$;

-- Documents of the session signed: recorded; once every one is signed the session is closed with the last record.
create or replace function app.esign_mark(p_session uuid, p_refs text[], p_record uuid, p_ip inet, p_user_agent text) returns void
language plpgsql security definer set search_path = public, app as $$
declare
  s esign_sessions;
begin
  if p_session is null then return; end if;
  update esign_sessions set signed_refs = array(select distinct unnest(signed_refs || p_refs)), updated_at = now() where id = p_session and signed_at is null returning * into s;
  if s.id is not null and not exists (select 1 from jsonb_array_elements(s.documents) d where not ((d ->> 'kind') || ':' || (d ->> 'ref')) = any (s.signed_refs)) then
    perform app.esign_close(s.id, p_record, p_ip, p_user_agent);
  end if;
end $$;

-- ================================================================ 2. the signing functions refuse a signature without its session
-- (the same words as 0154's refusals)

-- 2a. a document sent to sign in a portal: Forms A, B and C, the partner agreement, the investment and staff agreements
alter function app.sign_request_sign(uuid, uuid, jsonb) rename to sign_request_sign_pre0181;
create or replace function app.sign_request_sign(p_user uuid, p_id uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  r sign_requests;
  s esign_sessions;
  v jsonb;
  v_rec uuid;
begin
  select * into r from sign_requests where id = p_id;
  if r.id is not null and r.signer_user_id = p_user and r.status = 'sent' then
    s := app.esign_ready_doc('documents', p_user, 'request', p_id::text, r.document_sha256);
    if coalesce((app.settings()).esign_strict, true) then
      if s.id is null then
        raise exception 'Confirm your identity with the code, initial the key terms, give the consents and draw your signature before signing' using errcode = '23514';
      end if;
      perform app.esign_signature_matches(s, p ->> 'drawn_signature', p ->> 'typed_name');
    end if;
  end if;
  v := app.sign_request_sign_pre0181(p_user, p_id, p);
  if s.id is not null then
    v_rec := coalesce(nullif(v ->> 'signature_record_id', '')::uuid, (select x.signature_record_id from sign_requests x where x.id = p_id));
    update signature_records set esign_session_id = s.id where id = v_rec;
    perform app.esign_mark(s.id, array['request:' || p_id::text], v_rec, nullif(p ->> 'ip', '')::inet, p ->> 'user_agent');
  end if;
  return v;
end $$;
select pg_temp.copy_grants('app.sign_request_sign(uuid, uuid, jsonb)'::regprocedure, 'app.sign_request_sign_pre0181(uuid, uuid, jsonb)'::regprocedure);

-- 2b. the owner's agreements and schedules (the portal owner)
alter function app.owner_sign_agreements(uuid, uuid, jsonb) rename to owner_sign_agreements_pre0181;
create or replace function app.owner_sign_agreements(p_owner uuid, p_by uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  s esign_sessions;
  v jsonb;
  v_docs jsonb := case when jsonb_typeof(p -> 'documents') = 'array' then p -> 'documents' else '[]'::jsonb end;
begin
  select x.* into s from esign_sessions x
   where x.context = 'documents' and x.signer_ref = p_by and app.esign_is_ready(x) and jsonb_array_length(v_docs) > 0
     and not exists (select 1 from jsonb_array_elements(v_docs) d
                      where ('packet:' || (d ->> 'key')) = any (x.signed_refs)
                         or not exists (select 1 from jsonb_array_elements(x.documents) y
                                         where y ->> 'kind' = 'packet' and y ->> 'ref' = d ->> 'key' and lower(y ->> 'sha256') = lower(btrim(coalesce(d ->> 'sha256', '')))))
   order by x.created_at desc limit 1;
  if coalesce((app.settings()).esign_strict, true) then
    if s.id is null then
      raise exception 'Confirm your identity with the code, initial the key terms, give the consents and draw your signature before signing' using errcode = '23514';
    end if;
    perform app.esign_signature_matches(s, p ->> 'drawn_signature', p ->> 'typed_name');
  end if;
  v := app.owner_sign_agreements_pre0181(p_owner, p_by, p);
  if s.id is not null then
    -- the owner's own records made by this call (the countersignature is CarmaCars')
    update signature_records x set esign_session_id = s.id
     where x.signer_user_id = p_by and x.signer_role in ('owner_individual', 'owner_corporation') and x.signed_at = now() and x.esign_session_id is null;
    perform app.esign_mark(s.id, array(select 'packet:' || (d ->> 'key') from jsonb_array_elements(v_docs) d), null, nullif(p ->> 'ip', '')::inet, p ->> 'user_agent');
  end if;
  return v;
end $$;
select pg_temp.copy_grants('app.owner_sign_agreements(uuid, uuid, jsonb)'::regprocedure, 'app.owner_sign_agreements_pre0181(uuid, uuid, jsonb)'::regprocedure);

-- 2c. another Owner named in the Title Schedule, with their link
alter function app.owner_cosigner_sign(text, jsonb) rename to owner_cosigner_sign_pre0181;
create or replace function app.owner_cosigner_sign(p_token text, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  c owner_cosigners;
  s esign_sessions;
  v jsonb;
begin
  select * into c from owner_cosigners where token = p_token and status <> 'removed';
  if c.id is not null and c.status = 'pending' then
    select x.* into s from esign_sessions x
     where x.context = 'owner_cosigner' and x.signer_ref = c.id and app.esign_is_ready(x)
       and not exists (select 1 from app.owner_open_requests(c.owner_id) q
                        where not exists (select 1 from jsonb_array_elements(x.documents) y where y ->> 'ref' = q.key and lower(y ->> 'sha256') = q.sha256))
     order by x.created_at desc limit 1;
    if coalesce((app.settings()).esign_strict, true) then
      if s.id is null then
        raise exception 'Confirm your identity with the code, initial the key terms, give the consents and draw your signature before signing' using errcode = '23514';
      end if;
      perform app.esign_signature_matches(s, p ->> 'drawn_signature', p ->> 'typed_name');
    end if;
  end if;
  v := app.owner_cosigner_sign_pre0181(p_token, p);
  if s.id is not null then
    update signature_records set esign_session_id = s.id where id in (select unnest(x.signature_record_ids) from owner_cosigners x where x.id = c.id);
    update esign_sessions set signed_refs = array(select (d ->> 'kind') || ':' || (d ->> 'ref') from jsonb_array_elements(documents) d) where id = s.id;
    perform app.esign_close(s.id, (select x.signature_record_ids[1] from owner_cosigners x where x.id = c.id), nullif(p ->> 'ip', '')::inet, p ->> 'user_agent');
  end if;
  return v;
end $$;
select pg_temp.copy_grants('app.owner_cosigner_sign(text, jsonb)'::regprocedure, 'app.owner_cosigner_sign_pre0181(text, jsonb)'::regprocedure);

-- 2d. an updated Vehicle Schedule: the name recorded is the session's signer
alter function app.schedule_change_sign(uuid, jsonb) rename to schedule_change_sign_pre0181;
create or replace function app.schedule_change_sign(p_by uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  c vehicle_term_changes;
  s esign_sessions;
  v jsonb;
  q jsonb := p;
begin
  select * into c from vehicle_term_changes where id = nullif(p ->> 'change_id', '')::uuid;
  if c.id is not null and c.status = 'awaiting_signature' and app.user_owns_vehicle(p_by, c.vehicle_id) then
    s := app.esign_ready_doc('documents', p_by, 'schedule_change', c.id::text, p ->> 'sha256');
    if coalesce((app.settings()).esign_strict, true) then
      if s.id is null then
        raise exception 'Confirm your identity with the code, initial the key terms, give the consents and draw your signature before signing' using errcode = '23514';
      end if;
      perform app.esign_signature_matches(s, p ->> 'drawn_signature', p ->> 'typed_name');
    end if;
    if s.id is not null then q := p || jsonb_build_object('name', s.signer_name, 'agree', true); end if;
  end if;
  v := app.schedule_change_sign_pre0181(p_by, q);
  if s.id is not null then
    update vehicle_term_changes set esign_session_id = s.id where id = c.id;
    perform app.esign_mark(s.id, array['schedule_change:' || c.id::text], null, nullif(p ->> 'ip', '')::inet, p ->> 'user_agent');
  end if;
  return v;
end $$;
select pg_temp.copy_grants('app.schedule_change_sign(uuid, jsonb)'::regprocedure, 'app.schedule_change_sign_pre0181(uuid, jsonb)'::regprocedure);

-- What the signed copy of an updated Vehicle Schedule prints, and filing it (its SHA-256 is found on /verify).
create or replace function public.server_schedule_change_signed_facts(p_change uuid) returns jsonb
language sql stable security definer set search_path = public, app as $$
  select app.schedule_change_text(c.id) || jsonb_build_object('sha256', app.schedule_change_sha(c.id), 'owner_id', v.owner_id,
           'schedule_number', (select s.schedule_number from vehicle_schedules s where s.id = c.new_schedule_id), 'document_id', c.document_id,
           'esign_session_id', c.esign_session_id, 'signature_path', (select s.signature_path from esign_sessions s where s.id = c.esign_session_id),
           'signature_method', (select s.signature_method from esign_sessions s where s.id = c.esign_session_id))
    from vehicle_term_changes c join vehicles v on v.id = c.vehicle_id
   where c.id = p_change and c.status = 'applied'
$$;
create or replace function public.server_schedule_change_attach(p_change uuid, p_path text, p_sha256 text) returns uuid
language plpgsql security definer set search_path = public, app as $$
declare
  c vehicle_term_changes;
  v_doc uuid;
begin
  select * into c from vehicle_term_changes where id = p_change for update;
  if c.id is null or c.status <> 'applied' then raise exception 'Only a signed schedule gets its signed copy' using errcode = '23514'; end if;
  if c.document_id is not null then return c.document_id; end if;
  insert into documents (kind, title, storage_bucket, storage_path, mime_type, sha256, retention, owner_id)
  values ('vehicle_schedule', format('Updated Vehicle Schedule %s, signed', coalesce((select s.schedule_number from vehicle_schedules s where s.id = c.new_schedule_id), '')),
          'agreements', p_path, 'application/pdf', lower(btrim(p_sha256)), 'records_7y', (select v.owner_id from vehicles v where v.id = c.vehicle_id))
  returning id into v_doc;
  update vehicle_term_changes set document_id = v_doc where id = c.id;
  update vehicle_schedules set document_id = v_doc where id = c.new_schedule_id and document_id is null;
  return v_doc;
end $$;

-- ================================================================ 3. the certificate of completion of these documents
-- One signer's session as the certificate prints it (the same keys as public.server_esign_certificate, 0154).
create or replace function app.esign_cert_json(p_session uuid) returns jsonb
language sql stable security definer set search_path = public, app as $$
  select jsonb_build_object('session_id', s.id, 'signer_name', s.signer_name, 'signer_role', s.signer_role, 'method', s.method,
           'collected_by', (select u.full_name from users u where u.id = s.collected_by),
           'documents', (select coalesce(jsonb_agg(jsonb_build_object('title', d ->> 'title', 'sha256', d ->> 'sha256')), '[]'::jsonb) from jsonb_array_elements(s.documents) d),
           'otp_channel', s.otp_channel, 'otp_to', case s.otp_channel when 'sms' then app.esign_mask_phone(s.otp_to) else app.esign_mask_email(s.otp_to) end,
           'otp_verified_at', s.otp_verified_at, 'viewed_at', s.viewed_at, 'initials', s.initials, 'consents', s.consents, 'geo', s.geo,
           'ip_address', host(s.ip_address), 'user_agent', s.user_agent, 'signature_method', s.signature_method, 'signature_path', s.signature_path,
           'typed_fallback', s.typed_fallback,
           'signed_at', coalesce(s.signed_at, (select max(e.at) from esign_events e where e.session_id = s.id)),
           'licence', null,
           'events', coalesce((select jsonb_agg(jsonb_build_object('at', e.at, 'kind', e.kind, 'detail', e.detail, 'ip_address', host(e.ip_address), 'user_agent', e.user_agent) order by e.at, e.id)
                                 from esign_events e where e.session_id = s.id), '[]'::jsonb))
    from esign_sessions s where s.id = p_session
$$;

-- The certificate of a signed document (a signature_requests row: an owner agreement or schedule, a form, a partner,
-- investment or staff agreement): the SHA-256 of the document signed and each signer with a session.
create or replace function public.server_esign_certificate_for_request(p_request uuid) returns jsonb
language sql stable security definer set search_path = public, app as $$
  select jsonb_build_object('sha256', (select d.sha256 from signature_requests r join documents d on d.id = r.document_id where r.id = p_request),
           'signers', coalesce((select jsonb_agg(app.esign_cert_json(x.esign_session_id) order by x.signed_at, x.created_at)
                                  from signature_records x where x.signature_request_id = p_request and x.esign_session_id is not null), '[]'::jsonb))
$$;
create or replace function public.server_esign_certificate_sessions(p_sessions uuid[]) returns jsonb
language sql stable security definer set search_path = public, app as $$
  select coalesce(jsonb_agg(app.esign_cert_json(s.id) order by s.created_at), '[]'::jsonb) from esign_sessions s where s.id = any (p_sessions)
$$;

-- /verify finds every signed copy CarmaCars recorded: the rental documents (0154), the signed owner, partner, investment
-- and staff documents and forms, and the updated Vehicle Schedules (no personal data in the answer).
create or replace function public.server_verify_sha(p_sha text) returns jsonb
language sql stable security definer set search_path = public, app as $$
  select coalesce((select jsonb_build_object('found', true, 'kind', d.kind, 'title', regexp_replace(coalesce(d.title, 'Document'), '\s*\(.*\)$', ''),
                                             'recorded_at', d.created_at)
                     from documents d where d.sha256 = lower(btrim(p_sha)) and d.purged_at is null
                       and (d.kind in ('rental_agreement', 'rental_amendment', 'dispute_evidence')
                            or exists (select 1 from signature_requests r where r.signed_document_id = d.id)
                            or exists (select 1 from sign_requests r where r.signed_document_id = d.id)
                            or exists (select 1 from vehicle_term_changes c where c.document_id = d.id and c.status = 'applied'))
                     order by d.created_at limit 1),
                  jsonb_build_object('found', false))
$$;

-- ================================================================ 4. the code by email for these signers
alter function app.esign_code_email(uuid, text) rename to esign_code_email_pre0181;
create or replace function app.esign_code_email(p_session uuid, p_code text) returns void
language plpgsql security definer set search_path = public, app as $$
declare
  s esign_sessions;
  n integer;
begin
  select * into s from esign_sessions where id = p_session;
  if s.id is null or s.context not in ('documents', 'owner_cosigner') then perform app.esign_code_email_pre0181(p_session, p_code); return; end if;
  if s.otp_channel <> 'email' or s.email is null then raise exception 'Ask for the code by email first' using errcode = '23514'; end if;
  n := jsonb_array_length(s.documents);
  perform app.emit_event('document_signing_code', 'esign_session', s.id,
    jsonb_build_object('signer_email', s.email, 'signer_name', s.signer_name, 'code', p_code,
                       'document_label', case when n = 1 then 'your document: ' || (s.documents -> 0 ->> 'title') else format('your %s documents', n) end),
    'document_signing_code:' || s.id || ':' || s.otp_sends);
end $$;
select pg_temp.copy_grants('app.esign_code_email(uuid, text)'::regprocedure, 'app.esign_code_email_pre0181(uuid, text)'::regprocedure);

-- CATALOGUE 0181 START (generated by supabase/seed/0181_gen_catalogue.mjs; do not edit by hand)
insert into notification_catalogue (code, audience, also_sent_to, category, is_digest, digest_slot, from_address, reply_to,
    subject, preheader, timing, trigger_text, replaces_template, link_path, variables, template_html, template_text) values
  ('document_signing_code', 'owner', '{}'::text[], 'transactional', false, null, 'CarmaCars <owners@carmacars.ca>', 'owners@carmacars.ca', 'Your CarmaCars signing code: {{code}}', 'Enter it on the signing page within {{minutes}} minutes.', 'Immediate', 'Someone about to sign documents other than a rental agreement asks for the identity code by email (migration 0181): an owner signing the program agreements, a schedule or a form, another Owner signing with their link, a partner, an investor or a staff member signing their agreement. The code proves the signer controls the email on file; it is never stored in clear.', null, null, '[{"name":"code","type":"string"},{"name":"company_address","type":"string","global":true},{"name":"contact_email","type":"string","global":true},{"name":"document_label","type":"string"},{"name":"instagram_url","type":"url","global":true},{"name":"minutes","type":"string"},{"name":"opening_hours","type":"string","global":true},{"name":"reply_time","type":"string","global":true},{"name":"support_phone","type":"string","global":true},{"name":"tiktok_url","type":"url","global":true}]'::jsonb, 'templates/document_signing_code.html', 'templates/document_signing_code.txt')
on conflict (code) do update set
  audience = excluded.audience, also_sent_to = excluded.also_sent_to, category = excluded.category,
  is_digest = excluded.is_digest, digest_slot = excluded.digest_slot, from_address = excluded.from_address,
  reply_to = excluded.reply_to, subject = excluded.subject, preheader = excluded.preheader, timing = excluded.timing,
  trigger_text = excluded.trigger_text, replaces_template = excluded.replaces_template, link_path = excluded.link_path,
  variables = excluded.variables, template_html = excluded.template_html, template_text = excluded.template_text,
  in_catalogue = true, updated_at = now();
select app.notification_catalogue_refresh();
-- CATALOGUE 0181 END

-- the catalogue refresh above recomputes each marketing email's consent rule: keep express consent where 0161 and 0167 set it (as 0173 does)
update notification_catalogue set consent_rule = 'express' where code in ('renter_promo_expiry_3d', 'renter_promo_expiry_1d', 'owner_recruit_outreach');
update notification_catalogue set emitted_by = 'the signing pages'' identity step for documents (0181)', no_text = true, always_email = true where code = 'document_signing_code';

-- the signer's own email on file (an owner, a co-owner, an investor, a staff member), never a booking's renter
alter function app.notification_recipients(app_events, notification_catalogue) rename to notification_recipients_pre0181;
create function app.notification_recipients(p_event app_events, p_c notification_catalogue)
returns table (audience text, user_id uuid, email text, name text, renter_id uuid, owner_id uuid, immediate boolean)
language plpgsql stable security definer set search_path = public, app as $$
begin
  if p_c.code = 'document_signing_code' then
    return query select 'owner'::text, null::uuid, p_event.payload ->> 'signer_email', p_event.payload ->> 'signer_name', null::uuid, null::uuid, true
                  where nullif(p_event.payload ->> 'signer_email', '') is not null;
    return;
  end if;
  return query select * from app.notification_recipients_pre0181(p_event, p_c);
end $$;
select pg_temp.copy_grants('app.notification_recipients(app_events, notification_catalogue)'::regprocedure, 'app.notification_recipients_pre0181(app_events, notification_catalogue)'::regprocedure);

alter function app.notification_payload(text, app_events, jsonb) rename to ntf_payload_pre0181;
create function app.notification_payload(p_code text, p_event app_events, p_to jsonb) returns jsonb
language plpgsql stable security definer set search_path = public, app as $$
declare
  x jsonb := app.ntf_payload_pre0181(p_code, p_event, p_to);
begin
  if p_code = 'document_signing_code' then
    x := coalesce(x, '{}'::jsonb) || jsonb_build_object('code', coalesce(p_event.payload ->> 'code', ''), 'document_label', coalesce(p_event.payload ->> 'document_label', 'your documents'),
                                                         'minutes', coalesce((app.settings()).esign_code_minutes, 10)::text);
  end if;
  return x;
end $$;
select pg_temp.copy_grants('app.notification_payload(text, app_events, jsonb)'::regprocedure, 'app.ntf_payload_pre0181(text, app_events, jsonb)'::regprocedure);

-- ================================================================ 5. privileges
do $$
declare
  f record;
begin
  for f in
    select p.oid::regprocedure as sig from pg_proc p join pg_namespace n on n.oid = p.pronamespace
     where (n.nspname = 'app' and p.proname = any (array['esign_doc_initials', 'schedule_change_sha', 'esign_start_documents', 'server_esign_start_pre0181',
              'esign_ready_doc', 'esign_signature_matches', 'esign_mark', 'sign_request_sign_pre0181', 'owner_sign_agreements_pre0181',
              'owner_cosigner_sign_pre0181', 'schedule_change_sign_pre0181', 'esign_cert_json', 'esign_code_email_pre0181',
              'notification_recipients_pre0181', 'ntf_payload_pre0181']))
        or (n.nspname = 'public' and p.proname = any (array['server_esign_start', 'server_schedule_change_signed_facts', 'server_schedule_change_attach',
              'server_esign_certificate_for_request', 'server_esign_certificate_sessions', 'server_verify_sha']))
  loop
    execute format('revoke all on function %s from public, anon, authenticated', f.sig);
    execute format('grant execute on function %s to service_role', f.sig);
  end loop;
end $$;

-- ================================================================ the guides
-- GUIDES 0181 START (generated by supabase/seed/0181_gen_guides.mjs from docs/guides/content; do not edit by hand)
select app.guide_release_section('owner', 'apply-and-get-your-car-listed', 'chapter', 'start-here', 'You apply online in about ten minutes. We reply within one business day, set your terms, and walk you through the rest.

## Apply to list your car

1. Go to `carmacars.ca/list-your-car` and press **Apply to list your car**.
2. About you: individual or corporation, your address, licence and date of birth. Press **Continue to vehicles**.
3. For each car, type the VIN: your car is found as you type the last character (Edit if anything is wrong), then tap its colour and answer the rest. Use **Add another vehicle** for more cars.
4. Read how it will work, press **Continue**, then **Review**.
5. Press **Submit application**, then **Go to your owner portal**.

![](/guides/img/public-13-list-your-car-desktop-48bf4cb0.jpg "desktop; size: 1440 800; address: carmacars.ca/list-your-car; pins: 1 20.1 74.9")

> Tip: Need a break? **Email me a link** saves your application and sends you a link to finish later.

> Good to know: No car to add yet? On the vehicle step press **I''ll add my car later**, choose your password and press **Open my owner account**. Your owner portal opens with **Add your first car**: press it when you are ready, starting with the VIN.

## What happens next

Five steps take your car from your driveway to its first rental.

:::flow
Tell us about the car | We confirm fees and set your terms
Sign the agreements | Online, one for all your cars
One registry visit | We fill in the forms and come with you
Tracker and insurance | We install it and add the car
Photos and listing | Live within 1 business day
:::

1. When your terms are ready, Home shows **Check and sign**. Everything is filled in from your application: check the short list of key values (each has a **Fix** link) and open any document to read it in full.
2. Tap **All of these** for the three confirmations (your initials are filled in), then press **Sign all**. Your name on file is your signature; prefer to draw it? Press **Draw instead**. One signature covers every document, in about a minute.
3. Pay the upfront invoice: the first and last month''s insurance fee for each car (see chapter 4).
4. Upload what each car''s checklist asks for: the ownership permit, the lender''s permission if it is financed or leased, and insurance.
5. Sign Forms C and D (filled in for you) with witnesses: Form C on screen with your witness beside you, or on paper; Form D on paper, with a photo of each page from your phone (see chapter 5).

## If we need a little more

Sometimes we need one more document before we can approve your application, for example the ownership permit or the insurance slip.

1. You get an email, and Home shows "We need a little more" with the list and any note from our team.
2. Upload what is asked, or write Your answer, and press **Send my answer**.
3. We review it within 1 business day. Once we approve your application, you get an email and Home shows Check and sign.
', 'Apply and get your car listed', 'Apply online, sign, pay the upfront invoice and get your car on the site.',
  'You apply online in about ten minutes. We reply within one business day, set your terms, and walk you through the rest.

## Apply to list your car

1. Go to `carmacars.ca/list-your-car` and press **Apply to list your car**.
2. About you: individual or corporation, your address, licence and date of birth. Press **Continue to vehicles**.
3. For each car, type the VIN: your car is found as you type the last character (Edit if anything is wrong), then tap its colour and answer the rest. Use **Add another vehicle** for more cars.
4. Read how it will work, press **Continue**, then **Review**.
5. Press **Submit application**, then **Go to your owner portal**.

![](/guides/img/public-13-list-your-car-desktop-48bf4cb0.jpg "desktop; size: 1440 800; address: carmacars.ca/list-your-car; pins: 1 20.1 74.9")

> Tip: Need a break? **Email me a link** saves your application and sends you a link to finish later.

> Good to know: No car to add yet? On the vehicle step press **I''ll add my car later**, choose your password and press **Open my owner account**. Your owner portal opens with **Add your first car**: press it when you are ready, starting with the VIN.

## What happens next

Five steps take your car from your driveway to its first rental.

:::flow
Tell us about the car | We confirm fees and set your terms
Sign the agreements | Online, one for all your cars
One registry visit | We fill in the forms and come with you
Tracker and insurance | We install it and add the car
Photos and listing | Live within 1 business day
:::

1. When your terms are ready, Home shows **Check and sign**. Everything is filled in from your application: check the short list of key values (each has a **Fix** link) and open any document to read it in full.
2. Sign in a few steps: confirm it is you with the 6-digit code we send to your phone or email, say you read the documents, initial the three confirmations, tick the two consents and draw your signature. Then press **Sign all**. One signature covers every document, in about two minutes.
3. Pay the upfront invoice: the first and last month''s insurance fee for each car (see chapter 4).
4. Upload what each car''s checklist asks for: the ownership permit, the lender''s permission if it is financed or leased, and insurance.
5. Sign Forms C and D (filled in for you) with witnesses: Form C on screen with your witness beside you, or on paper; Form D on paper, with a photo of each page from your phone (see chapter 5).

## If we need a little more

Sometimes we need one more document before we can approve your application, for example the ownership permit or the insurance slip.

1. You get an email, and Home shows "We need a little more" with the list and any note from our team.
2. Upload what is asked, or write Your answer, and press **Send my answer**.
3. We review it within 1 business day. Once we approve your application, you get an email and Home shows Check and sign.
',
  '<p class="gd-p">You apply online in about ten minutes. We reply within one business day, set your terms, and walk you through the rest.</p><section class="gd-task" id="apply-and-get-your-car-listed-apply-to-list-your-car" data-gd-task><h2 class="gd-h2">Apply to list your car</h2><div class="gd-stepblock gd-stepblock--below"><div class="gd-stepcol"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">Go to <span class="gd-url">carmacars.ca/list-your-car</span> and press <b class="gd-ui">Apply to list your car</b>.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">About you: individual or corporation, your address, licence and date of birth. Press <b class="gd-ui">Continue to vehicles</b>.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">For each car, type the VIN: your car is found as you type the last character (Edit if anything is wrong), then tap its colour and answer the rest. Use <b class="gd-ui">Add another vehicle</b> for more cars.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t">Read how it will work, press <b class="gd-ui">Continue</b>, then <b class="gd-ui">Review</b>.</div></li><li><span class="gd-n" aria-hidden="true">5</span><div class="gd-t">Press <b class="gd-ui">Submit application</b>, then <b class="gd-ui">Go to your owner portal</b>.</div></li></ol></div><figure class="gd-fig gd-fig--desk"><div class="gd-browser"><div class="gd-bar" aria-hidden="true"><i></i><i></i><i></i><span class="gd-addr">carmacars.ca/list-your-car</span></div><div class="gd-imgwrap" style="aspect-ratio:1440/800"><img src="/guides/img/public-13-list-your-car-desktop-48bf4cb0.jpg" alt="" loading="lazy" decoding="async" width="1440" height="800"><span class="gd-pin" style="left:20.1%;top:74.9%" aria-hidden="true">1</span></div></div></figure></div><aside class="gd-box"><span class="gd-lbl">Tip</span><div>Need a break? <b class="gd-ui">Email me a link</b> saves your application and sends you a link to finish later.</div></aside><aside class="gd-box"><span class="gd-lbl">Good to know</span><div>No car to add yet? On the vehicle step press <b class="gd-ui">I&#39;ll add my car later</b>, choose your password and press <b class="gd-ui">Open my owner account</b>. Your owner portal opens with <b class="gd-ui">Add your first car</b>: press it when you are ready, starting with the VIN.</div></aside></section><section class="gd-task" id="apply-and-get-your-car-listed-what-happens-next" data-gd-task><h2 class="gd-h2">What happens next</h2><p class="gd-p">Five steps take your car from your driveway to its first rental.</p><ol class="gd-flow"><li><b>1</b><span>Tell us about the car</span><em>We confirm fees and set your terms</em></li><li><b>2</b><span>Sign the agreements</span><em>Online, one for all your cars</em></li><li><b>3</b><span>One registry visit</span><em>We fill in the forms and come with you</em></li><li><b>4</b><span>Tracker and insurance</span><em>We install it and add the car</em></li><li><b>5</b><span>Photos and listing</span><em>Live within 1 business day</em></li></ol><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">When your terms are ready, Home shows <b class="gd-ui">Check and sign</b>. Everything is filled in from your application: check the short list of key values (each has a <b class="gd-ui">Fix</b> link) and open any document to read it in full.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Sign in a few steps: confirm it is you with the 6-digit code we send to your phone or email, say you read the documents, initial the three confirmations, tick the two consents and draw your signature. Then press <b class="gd-ui">Sign all</b>. One signature covers every document, in about two minutes.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Pay the upfront invoice: the first and last month&#39;s insurance fee for each car (see chapter 4).</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t">Upload what each car&#39;s checklist asks for: the ownership permit, the lender&#39;s permission if it is financed or leased, and insurance.</div></li><li><span class="gd-n" aria-hidden="true">5</span><div class="gd-t">Sign Forms C and D (filled in for you) with witnesses: Form C on screen with your witness beside you, or on paper; Form D on paper, with a photo of each page from your phone (see chapter 5).</div></li></ol></div></section><section class="gd-task" id="apply-and-get-your-car-listed-if-we-need-a-little-more" data-gd-task><h2 class="gd-h2">If we need a little more</h2><p class="gd-p">Sometimes we need one more document before we can approve your application, for example the ownership permit or the insurance slip.</p><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">You get an email, and Home shows &quot;We need a little more&quot; with the list and any note from our team.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Upload what is asked, or write Your answer, and press <b class="gd-ui">Send my answer</b>.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">We review it within 1 business day. Once we approve your application, you get an email and Home shows Check and sign.</div></li></ol></div></section>');
select app.guide_release_section('owner', 'documents-and-forms', 'chapter', 'fees-payments-and-payouts', 'Your signed agreements, uploads and government forms are under Documents. Some forms are filled for you; Forms C and D are signed with witnesses.

## Sign everything at once

Everything you sign on screen is in one place: Home shows how many are signed ("2 of 5 signed") and opens it with Check and sign.

1. Press **Check and sign** on Home (or open `carmacars.ca/owner/sign`). The list at the top shows each document: signed, in this package, or done elsewhere (Forms C and D, the bank debit).
2. Check the key values: your name, address, each car with its VIN and plate, your fees and Revenue Share. Something wrong? Press **Fix** next to it, change it, and come back.
3. Open any document to read it word for word: the agreements, the schedules and Forms A and B. The official registry forms are not in it: they are printed and signed in ink.
4. Tap **All of these** for the statements the agreement asks you to initial (your initials are filled in), then press **Sign all**.
5. Your name on file is your signature. One signature is applied to each document; CarmaCars countersigns at the same moment and every signed copy is in Documents.

> Two owners: A car with a second owner on its ownership? Each owner named in the Title Schedule signs. The other owner gets their own link by email and signs the same documents on their phone or computer. The agreements take effect when the last owner signs; CarmaCars countersigns then.

> Good to know: Form A (the trust declaration) is for cars under the Co-Registrant or Transfer method; Form B (the lease summary) for cars under a Lease method. No witness is needed: they are in the same package. You can also sign one on its own page from Documents.

> Tip: Signed one of your documents on paper instead? Send us the scan. Once we record it, Documents shows it as Signed on paper and we do not ask again.

## We set up your car for you

When our team enters your car for you, you get one email: review the details and sign.

1. No sign-in yet? The email has a link to choose your password. It works once, for 24 hours; after that use Forgot password on the sign-in page.
2. Open `carmacars.ca/owner/review` (Home has **Review or correct your details**). Check your phone and address, and each car: plate, colour, odometer, your insurer and your lender. The terms we agreed are shown too.
3. Something wrong? Correct it and press **Save corrections**. Your documents are filled in again and we are told. A term you did not agree to: message us before you sign.
4. Everything right? Press **Everything is right: sign** and sign once.

## Sign an updated Vehicle Schedule

When we agree new terms for a car you already signed for, you sign an updated Vehicle Schedule. Home shows it first.

1. Open it from Home or the email. It shows what changes (now and updated) and the date it applies from.
2. Read the text, tick that you agree, type your full legal name and press **Sign**.
3. Your current terms stay until you sign. After that, your invoices and statements use the new ones from the date.

## Form C on screen, with your witness beside you

Form C is the lender or lessor permission for a financed or leased car. It needs one witness, and you can sign it on screen when your witness is with you.

1. Open Documents. Under Forms to sign with witnesses, press Sign Form C on screen instead.
2. Initial each of the three acknowledgments, and type Your initials.
3. Sign: draw your signature in the box, or use your name.
4. Hand the device to your witness, another adult. They type their full name and tick the statement "I witnessed (your name) sign in my presence." Press **Sign Form C**.

![](/guides/img/owner-16-form-c-screen-desktop-faa92983.jpg "desktop; size: 790 980; address: carmacars.ca/owner/documents/form-c/4898eb96-0cce-4efc-9fdd-740b4b4e9ad3; pins: 2 5.7 13.6, 3 32.9 55.1, 4 6.3 82.2")

## Forms C and D on paper, signed with witnesses

Form D is a limited power of attorney (two witnesses), signed on paper. Form C can be signed on paper too, with one witness.

1. Open Documents. Under Forms to sign with witnesses, press **Print the form**. It is filled in, and every spot to sign or initial is marked SIGN HERE or INITIAL HERE.
2. Sign it in front of your witnesses. They sign and print their names in their spots.
3. Type each witness''s full name in the boxes.
4. On your phone, press **Take a photo of the signed page**: one photo of each page. A PDF scan works too (**Or choose a file**).

![](/guides/img/owner-12-forms-c-d-desktop-21fbbe79.jpg "desktop; size: 1440 742; address: carmacars.ca/owner/documents; pins: 1 21.5 32.5, 3 69.4 50.7, 4 69.4 60.4")

> Tip: We check the photo and approve it, or send it back with what to fix. You get an email either way, and the page shows the status.

> Good to know: Why paper for Form D? It is a power of attorney, which cannot be signed electronically in Ontario, and its two witnesses sign in person.

## Government forms filled for you

Each car''s registry forms are prepared from your records. Until we load the official PDF, you get a data sheet with the values.

1. Open Documents and choose a form marked "Official form, filled for you".
2. Press **Download the filled form** and check each value.
3. Print it and sign it in ink. It is the official ServiceOntario form exactly as ServiceOntario publishes it, with only its empty text boxes filled in. Its boxes to tick and its signatures are done by hand, at the registry office or before you go, as we tell you.

![](/guides/img/owner-13-official-form-desktop-48614913.jpg "desktop; size: 1440 732; address: carmacars.ca/owner/documents/forms/4d54a524-c28d-4bc4-8ad3-dd9558100a81/official; pins: 2 22.2 29.5")

> Good to know: ON00453 (a company''s registrant number) is an Adobe form: open it in Adobe Acrobat Reader (free) to see and print it. Other PDF viewers show a blank page, as they do with the form downloaded from ServiceOntario.

> Watch out: Official registry forms are never signed on screen. You pay ServiceOntario, the inspection station and the appraiser directly.
', 'Documents and forms', 'Agreements, government forms, Forms C and D, and official forms filled for you.',
  'Your signed agreements, uploads and government forms are under Documents. Some forms are filled for you; Forms C and D are signed with witnesses.

## Sign everything at once

Everything you sign on screen is in one place: Home shows how many are signed ("2 of 5 signed") and opens it with Check and sign.

1. Press **Check and sign** on Home (or open `carmacars.ca/owner/sign`). The list at the top shows each document: signed, in this package, or done elsewhere (Forms C and D, the bank debit).
2. Check the key values: your name, address, each car with its VIN and plate, your fees and Revenue Share. Something wrong? Press **Fix** next to it, change it, and come back.
3. Open any document to read it word for word: the agreements, the schedules and Forms A and B. The official registry forms are not in it: they are printed and signed in ink.
4. Press **Send the code**: a 6-digit code goes to your phone (or your email, if you choose it). Type it and press **Confirm**.
5. Tick that you read the documents, draw your initials in the box beside each confirmation the Enrollment Agreement asks for, and tick the two consents (to sign electronically, to get your records electronically).
6. Draw your signature in the box with your finger, a pen or the mouse, then press **Sign all**. One signature is applied to each document; CarmaCars countersigns at the same moment and every signed copy is in Documents.
7. Each signed copy ends with a certificate of completion: when and where each step was done, and the code that confirmed it was you. Anyone holding a copy can check it at carmacars.ca/verify.

> Two owners: A car with a second owner on its ownership? Each owner named in the Title Schedule signs. The other owner gets their own link by email and signs the same documents on their phone or computer, the same way: the code (sent to their email), the confirmations initialled, the consents and their drawn signature. The agreements take effect when the last owner signs; CarmaCars countersigns then.

> Good to know: Cannot draw a signature (for example with a disability)? Call us: an Admin can let you type your name instead.

> Good to know: Form A (the trust declaration) is for cars under the Co-Registrant or Transfer method; Form B (the lease summary) for cars under a Lease method. No witness is needed: they are in the same package. You can also sign one on its own page from Documents.

> Tip: Signed one of your documents on paper instead? Send us the scan. Once we record it, Documents shows it as Signed on paper and we do not ask again.

## We set up your car for you

When our team enters your car for you, you get one email: review the details and sign.

1. No sign-in yet? The email has a link to choose your password. It works once, for 24 hours; after that use Forgot password on the sign-in page.
2. Open `carmacars.ca/owner/review` (Home has **Review or correct your details**). Check your phone and address, and each car: plate, colour, odometer, your insurer and your lender. The terms we agreed are shown too.
3. Something wrong? Correct it and press **Save corrections**. Your documents are filled in again and we are told. A term you did not agree to: message us before you sign.
4. Everything right? Press **Everything is right: sign** and sign once.

## Sign an updated Vehicle Schedule

When we agree new terms for a car you already signed for, you sign an updated Vehicle Schedule. Home shows it first.

1. Open it from Home or the email. It shows what changes (now and updated) and the date it applies from.
2. Read the text, then sign the same way as your agreements: the code to your phone or email, tick that you read it, initial the updated terms, tick the two consents, draw your signature and press **Sign**.
3. Your current terms stay until you sign. After that, your invoices and statements use the new ones from the date. The signed copy, with its certificate of completion, is in Documents.

## Form C on screen, with your witness beside you

Form C is the lender or lessor permission for a financed or leased car. It needs one witness, and you can sign it on screen when your witness is with you.

1. Open Documents. Under Forms to sign with witnesses, press Sign Form C on screen instead.
2. Confirm it is you with the code sent to your phone or email, and tick that you read the form.
3. Draw your initials beside each of the three acknowledgments, tick the two consents and draw your signature.
4. Hand the device to your witness, another adult. They type their full name and tick the statement "I witnessed (your name) sign in my presence." Press **Sign Form C**.

![](/guides/img/owner-16-form-c-screen-desktop-faa92983.jpg "desktop; size: 790 980; address: carmacars.ca/owner/documents/form-c/4898eb96-0cce-4efc-9fdd-740b4b4e9ad3; pins: 2 5.7 13.6, 3 32.9 55.1, 4 6.3 82.2")

## Forms C and D on paper, signed with witnesses

Form D is a limited power of attorney (two witnesses), signed on paper. Form C can be signed on paper too, with one witness.

1. Open Documents. Under Forms to sign with witnesses, press **Print the form**. It is filled in, and every spot to sign or initial is marked SIGN HERE or INITIAL HERE.
2. Sign it in front of your witnesses. They sign and print their names in their spots.
3. Type each witness''s full name in the boxes.
4. On your phone, press **Take a photo of the signed page**: one photo of each page. A PDF scan works too (**Or choose a file**).

![](/guides/img/owner-12-forms-c-d-desktop-21fbbe79.jpg "desktop; size: 1440 742; address: carmacars.ca/owner/documents; pins: 1 21.5 32.5, 3 69.4 50.7, 4 69.4 60.4")

> Tip: We check the photo and approve it, or send it back with what to fix. You get an email either way, and the page shows the status.

> Good to know: Why paper for Form D? It is a power of attorney, which cannot be signed electronically in Ontario, and its two witnesses sign in person.

## Government forms filled for you

Each car''s registry forms are prepared from your records. Until we load the official PDF, you get a data sheet with the values.

1. Open Documents and choose a form marked "Official form, filled for you".
2. Press **Download the filled form** and check each value.
3. Print it and sign it in ink. It is the official ServiceOntario form exactly as ServiceOntario publishes it, with only its empty text boxes filled in. Its boxes to tick and its signatures are done by hand, at the registry office or before you go, as we tell you.

![](/guides/img/owner-13-official-form-desktop-48614913.jpg "desktop; size: 1440 732; address: carmacars.ca/owner/documents/forms/4d54a524-c28d-4bc4-8ad3-dd9558100a81/official; pins: 2 22.2 29.5")

> Good to know: ON00453 (a company''s registrant number) is an Adobe form: open it in Adobe Acrobat Reader (free) to see and print it. Other PDF viewers show a blank page, as they do with the form downloaded from ServiceOntario.

> Watch out: Official registry forms are never signed on screen. You pay ServiceOntario, the inspection station and the appraiser directly.
',
  '<p class="gd-p">Your signed agreements, uploads and government forms are under Documents. Some forms are filled for you; Forms C and D are signed with witnesses.</p><section class="gd-task" id="documents-and-forms-sign-everything-at-once" data-gd-task><h2 class="gd-h2">Sign everything at once</h2><p class="gd-p">Everything you sign on screen is in one place: Home shows how many are signed (&quot;2 of 5 signed&quot;) and opens it with Check and sign.</p><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">Press <b class="gd-ui">Check and sign</b> on Home (or open <span class="gd-url">carmacars.ca/owner/sign</span>). The list at the top shows each document: signed, in this package, or done elsewhere (Forms C and D, the bank debit).</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Check the key values: your name, address, each car with its VIN and plate, your fees and Revenue Share. Something wrong? Press <b class="gd-ui">Fix</b> next to it, change it, and come back.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Open any document to read it word for word: the agreements, the schedules and Forms A and B. The official registry forms are not in it: they are printed and signed in ink.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t">Press <b class="gd-ui">Send the code</b>: a 6-digit code goes to your phone (or your email, if you choose it). Type it and press <b class="gd-ui">Confirm</b>.</div></li><li><span class="gd-n" aria-hidden="true">5</span><div class="gd-t">Tick that you read the documents, draw your initials in the box beside each confirmation the Enrollment Agreement asks for, and tick the two consents (to sign electronically, to get your records electronically).</div></li><li><span class="gd-n" aria-hidden="true">6</span><div class="gd-t">Draw your signature in the box with your finger, a pen or the mouse, then press <b class="gd-ui">Sign all</b>. One signature is applied to each document; CarmaCars countersigns at the same moment and every signed copy is in Documents.</div></li><li><span class="gd-n" aria-hidden="true">7</span><div class="gd-t">Each signed copy ends with a certificate of completion: when and where each step was done, and the code that confirmed it was you. Anyone holding a copy can check it at carmacars.ca/verify.</div></li></ol></div><aside class="gd-box"><div>Two owners: A car with a second owner on its ownership? Each owner named in the Title Schedule signs. The other owner gets their own link by email and signs the same documents on their phone or computer, the same way: the code (sent to their email), the confirmations initialled, the consents and their drawn signature. The agreements take effect when the last owner signs; CarmaCars countersigns then.</div></aside><aside class="gd-box"><span class="gd-lbl">Good to know</span><div>Cannot draw a signature (for example with a disability)? Call us: an Admin can let you type your name instead.</div></aside><aside class="gd-box"><span class="gd-lbl">Good to know</span><div>Form A (the trust declaration) is for cars under the Co-Registrant or Transfer method; Form B (the lease summary) for cars under a Lease method. No witness is needed: they are in the same package. You can also sign one on its own page from Documents.</div></aside><aside class="gd-box"><span class="gd-lbl">Tip</span><div>Signed one of your documents on paper instead? Send us the scan. Once we record it, Documents shows it as Signed on paper and we do not ask again.</div></aside></section><section class="gd-task" id="documents-and-forms-we-set-up-your-car-for-you" data-gd-task><h2 class="gd-h2">We set up your car for you</h2><p class="gd-p">When our team enters your car for you, you get one email: review the details and sign.</p><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">No sign-in yet? The email has a link to choose your password. It works once, for 24 hours; after that use Forgot password on the sign-in page.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Open <span class="gd-url">carmacars.ca/owner/review</span> (Home has <b class="gd-ui">Review or correct your details</b>). Check your phone and address, and each car: plate, colour, odometer, your insurer and your lender. The terms we agreed are shown too.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Something wrong? Correct it and press <b class="gd-ui">Save corrections</b>. Your documents are filled in again and we are told. A term you did not agree to: message us before you sign.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t">Everything right? Press <b class="gd-ui">Everything is right: sign</b> and sign once.</div></li></ol></div></section><section class="gd-task" id="documents-and-forms-sign-an-updated-vehicle-schedule" data-gd-task><h2 class="gd-h2">Sign an updated Vehicle Schedule</h2><p class="gd-p">When we agree new terms for a car you already signed for, you sign an updated Vehicle Schedule. Home shows it first.</p><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">Open it from Home or the email. It shows what changes (now and updated) and the date it applies from.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Read the text, then sign the same way as your agreements: the code to your phone or email, tick that you read it, initial the updated terms, tick the two consents, draw your signature and press <b class="gd-ui">Sign</b>.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Your current terms stay until you sign. After that, your invoices and statements use the new ones from the date. The signed copy, with its certificate of completion, is in Documents.</div></li></ol></div></section><section class="gd-task" id="documents-and-forms-form-c-on-screen-with-your-witness-beside-you" data-gd-task><h2 class="gd-h2">Form C on screen, with your witness beside you</h2><p class="gd-p">Form C is the lender or lessor permission for a financed or leased car. It needs one witness, and you can sign it on screen when your witness is with you.</p><div class="gd-stepblock gd-stepblock--below"><div class="gd-stepcol"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">Open Documents. Under Forms to sign with witnesses, press Sign Form C on screen instead.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Confirm it is you with the code sent to your phone or email, and tick that you read the form.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Draw your initials beside each of the three acknowledgments, tick the two consents and draw your signature.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t">Hand the device to your witness, another adult. They type their full name and tick the statement &quot;I witnessed (your name) sign in my presence.&quot; Press <b class="gd-ui">Sign Form C</b>.</div></li></ol></div><figure class="gd-fig gd-fig--desk"><div class="gd-browser"><div class="gd-bar" aria-hidden="true"><i></i><i></i><i></i><span class="gd-addr">carmacars.ca/owner/documents/form-c/4898eb96-0cce-4efc-9fdd-740b4b4e9ad3</span></div><div class="gd-imgwrap" style="aspect-ratio:790/980"><img src="/guides/img/owner-16-form-c-screen-desktop-faa92983.jpg" alt="" loading="lazy" decoding="async" width="790" height="980"><span class="gd-pin" style="left:5.7%;top:13.6%" aria-hidden="true">2</span><span class="gd-pin" style="left:32.9%;top:55.1%" aria-hidden="true">3</span><span class="gd-pin" style="left:6.3%;top:82.2%" aria-hidden="true">4</span></div></div></figure></div></section><section class="gd-task" id="documents-and-forms-forms-c-and-d-on-paper-signed-with-witnesses" data-gd-task><h2 class="gd-h2">Forms C and D on paper, signed with witnesses</h2><p class="gd-p">Form D is a limited power of attorney (two witnesses), signed on paper. Form C can be signed on paper too, with one witness.</p><div class="gd-stepblock gd-stepblock--below"><div class="gd-stepcol"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">Open Documents. Under Forms to sign with witnesses, press <b class="gd-ui">Print the form</b>. It is filled in, and every spot to sign or initial is marked SIGN HERE or INITIAL HERE.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Sign it in front of your witnesses. They sign and print their names in their spots.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Type each witness&#39;s full name in the boxes.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t">On your phone, press <b class="gd-ui">Take a photo of the signed page</b>: one photo of each page. A PDF scan works too (<b class="gd-ui">Or choose a file</b>).</div></li></ol></div><figure class="gd-fig gd-fig--desk"><div class="gd-browser"><div class="gd-bar" aria-hidden="true"><i></i><i></i><i></i><span class="gd-addr">carmacars.ca/owner/documents</span></div><div class="gd-imgwrap" style="aspect-ratio:1440/742"><img src="/guides/img/owner-12-forms-c-d-desktop-21fbbe79.jpg" alt="" loading="lazy" decoding="async" width="1440" height="742"><span class="gd-pin" style="left:21.5%;top:32.5%" aria-hidden="true">1</span><span class="gd-pin" style="left:69.4%;top:50.7%" aria-hidden="true">3</span><span class="gd-pin" style="left:69.4%;top:60.4%" aria-hidden="true">4</span></div></div></figure></div><aside class="gd-box"><span class="gd-lbl">Tip</span><div>We check the photo and approve it, or send it back with what to fix. You get an email either way, and the page shows the status.</div></aside><aside class="gd-box"><span class="gd-lbl">Good to know</span><div>Why paper for Form D? It is a power of attorney, which cannot be signed electronically in Ontario, and its two witnesses sign in person.</div></aside></section><section class="gd-task" id="documents-and-forms-government-forms-filled-for-you" data-gd-task><h2 class="gd-h2">Government forms filled for you</h2><p class="gd-p">Each car&#39;s registry forms are prepared from your records. Until we load the official PDF, you get a data sheet with the values.</p><div class="gd-stepblock gd-stepblock--below"><div class="gd-stepcol"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">Open Documents and choose a form marked &quot;Official form, filled for you&quot;.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Press <b class="gd-ui">Download the filled form</b> and check each value.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Print it and sign it in ink. It is the official ServiceOntario form exactly as ServiceOntario publishes it, with only its empty text boxes filled in. Its boxes to tick and its signatures are done by hand, at the registry office or before you go, as we tell you.</div></li></ol></div><figure class="gd-fig gd-fig--desk"><div class="gd-browser"><div class="gd-bar" aria-hidden="true"><i></i><i></i><i></i><span class="gd-addr">carmacars.ca/owner/documents/forms/4d54a524-c28d-4bc4-8ad3-dd9558100a81/official</span></div><div class="gd-imgwrap" style="aspect-ratio:1440/732"><img src="/guides/img/owner-13-official-form-desktop-48614913.jpg" alt="" loading="lazy" decoding="async" width="1440" height="732"><span class="gd-pin" style="left:22.2%;top:29.5%" aria-hidden="true">2</span></div></div></figure></div><aside class="gd-box"><span class="gd-lbl">Good to know</span><div>ON00453 (a company&#39;s registrant number) is an Adobe form: open it in Adobe Acrobat Reader (free) to see and print it. Other PDF viewers show a blank page, as they do with the form downloaded from ServiceOntario.</div></aside><aside class="gd-box gd-box--warn"><span class="gd-lbl">Watch out</span><div>Official registry forms are never signed on screen. You pay ServiceOntario, the inspection station and the appraiser directly.</div></aside></section>');
select app.guide_release_section('admin', 'requests-offers-and-bookings', 'chapter', 'people-and-access', 'A booking starts as a request from the website, or as an offer you send yourself to a customer on the phone. You check it, adjust it and send the offer; an offer that is out is changed in place. After that, the booking page holds the money, documents, changes and history.

## The request queue

Open **Bookings** > **Requests**. The oldest waiting request is at the top.

1. Filter by New, Waiting on the renter, Pushed back, Offer out, Signing and payment, or Offer expired.
2. Waiting shows how long the renter has waited; red means past the first reply target (5 minutes, set in Program settings). Open a booking number to answer it.

![](/guides/img/admin-02-requests-desktop-6521282d.jpg "desktop; size: 1440 820; address: carmacars.ca/admin/requests; pins: 1 38.9 29.9, 2 22.2 43.3")

> Good to know: A request whose pickup time passes without an offer expires by itself, with a note in its history. The renter is not emailed unless "Email the renter when their request expires that way" is on in Program settings.

## Answer a request with an offer

1. The Review and offer tab shows the request as the renter sent it.
2. Adjust the car, the dates, the rate type, the places, the rates and fees, the deposit and extras.
3. Price on the right updates as you change things.
4. Add a message, choose how long the offer stays open, then press **Send the offer**.

![](/guides/img/admin-03-booking-review-desktop-353f3707.jpg "desktop; size: 1200 1550; address: carmacars.ca/admin/bookings/CC-10069?tab=review; pins: 1 5.0 6.5, 2 7.5 45.8, 3 74.2 42.6, 4 76.7 98.1")

5. Changed fields but not ready to send? Press **Save changes**. The panel "The offer as the renter sees it" shows the result.
6. Can''t do it? Press **Decline** and fill in Reason and any alternative.
7. Need an answer first? Press **Ask the renter** to send a question.

![](/guides/img/admin-03-booking-review-desktop-4dd4ed06.jpg "desktop; size: 500 80; address: carmacars.ca/admin/bookings/CC-10069?tab=review; pins: 6 41.2 52.5, 7 18.0 52.5")

Opening a request takes it for you: everyone else sees "Being answered by" your name and since when, with Send the offer and Decline off, until you send, decline or leave (20 minutes, renewed while you work; Program settings). Press **Take over** to answer one someone else holds; it is noted in the history. A second answer is refused with who answered and when. A request from the website opens to Sales after 15 minutes (Program settings); until then Admins, customer service and fleet answer it.

## Send an offer without a request

**Bookings** > **Send an offer**, or **Send an offer** on Bookings and on Requests. For a customer on the phone, by text or at the counter: no request needed.

1. The customer: type a name, phone or email and choose them. Not on file? Press **Add a new customer**: full legal name, mobile, email (the offer link goes there) and date of birth. A customer already on file with the same email or phone is shown with Use: one person, one record.
2. The car and the dates: type the car code, plate or name, or choose from the list; each car says Free or Not free for the dates. Then the pickup and return places (our location, delivery with the address and distance, airport).
3. The price: the Rate sheet, A total for the whole rental, or A rate per day (times the days). A price typed by hand needs its reason. At the top of the price, Amounts I type: Before tax, or After tax (HST included) to type what the renter pays for each line, worked back to the amount before tax for you (a line without HST stays as typed; the choice is remembered on this device). Or type the Total the renter pays (after tax): the rental charge is worked out so the total comes to it exactly, the other lines kept. Set the kilometres, a promo code, the deposit, a discount and each fee (an Admin), and how damage is covered: with option 3 the Protection Plan price is the one the renter pays.
4. How it is paid: the rental by card online (the usual way), e-Transfer, cash, cheque, bank transfer, platform payout or the insurer; the deposit by card hold, cash, e-Transfer or no deposit (an Admin).
5. Who found this client, the message to the renter, how long the offer is open, and how the link goes: Email, Text, both or neither.
6. The right side is the offer as the renter will see it, priced by the database as you type. Press **Send the offer**. **Save without sending** keeps it as a request for later.

> Good to know: It makes the same request and offer the website makes: the renter approves, signs and pays (or you record the payment), and only then is the car on the calendar. No "request received" email goes to the renter for an offer you send. Staff commissions and statements count it like any other booking.

## Change an offer that is out

The renter has the offer (Offered), or approved it and has not paid (Signing and payment). Press **Edit the offer** on the booking.

1. Change anything: the car, the dates, the places, the price, fees, the deposit, add-ons, how it is paid. Each changed field is highlighted and the before and after are listed. Amounts I type (Before tax or After tax) and the Total the renter pays (after tax) work as on Send an offer.
2. Write what changed in Message to the renter and choose how long the offer is open.
3. Press **Save and send the update**: the renter gets the new version by email or text (ticked), and the old version no longer counts. Or press **Save without telling the renter** and tell them yourself.
4. A confirmed booking is changed with **Change the booking** (Propose a change, below).

> Tip: No need to withdraw first. **Withdraw the offer** is only for taking it back for good; **Send again, later expiry** gives the renter more time, and **Renter approved by phone** records a yes given on a call.

## Edit a booking that has started

On a confirmed, on-trip or returned booking (an Admin: a closed one too), Overview, **Edit the booking**, **Edit**.

1. Change the pickup or the return (extend or shorten: the rental charge is worked out again at this booking''s rates), the car (on trip: the car it leaves goes to Out of service for Fleet to check), the rental charge for the trip, each fee, the kilometres a day, the deposit (an Admin) and the note.
2. Type why, if you like, and tick **Email the renter what changed**, or leave it off for a silent correction. Press **Save the changes**.
3. What is open now shows at once: **Email a pay link** or **Text a pay link** for exactly that amount, **Charge** the saved card (the renter agreed), or record cash or an e-Transfer on the Money tab.

> Good to know: Each edit is kept with who, when, why, before and after (Edits, under the form) and in the booking''s history. A closed booking''s owner split and the staff commission follow. To have the renter accept and sign first, use Propose a change instead.

## Fees, a forgotten fee and the balance

On the booking''s Money tab, Fees lists each fee. Press **Change or add a fee**.

1. Type a new amount (for the whole trip, before HST) beside any fee, or choose one not on the booking (the young driver fee shows its price for these dates), or add a charge of its own with or without HST.
2. Press **Save the fees**. The balance shows by part (rental, fees) with the pay link, the saved card and Record a payment beside it.
3. The renter sees the balance on their booking with a Pay button, and pays by card on Stripe''s form.

> Good to know: Every change is recorded (Changes to the fees): the amount before and after, who and why. Customer service and sales may change fees while Program settings, Staff may change fees, is on.

## Correct a renter''s details

On the renter''s page (People, Renters) or on any of their bookings, **Edit renter**.

1. Correct the name, email, phone, date of birth, licence, home address (start typing to find it) or the staff note.
2. A new email also becomes their sign-in at once (no confirmation needed for a typo you correct); tick **Email the renter a link to set a password** to send one there. Unsigned agreements and offers go to the new address.
3. Press **Save the renter**. An email that another renter has is refused with their name; the same phone is a warning.
4. The same person entered twice? Possible duplicates (same email, same phone, or same name and date of birth) shows under the renter. **Merge into this record** moves the other record''s bookings, licences, cards, payments, documents and messages here and fills any detail missing here; the other record stays, blocked, with the merge in both histories.

## Payments by part: the rental, the deposit and later charges

On the booking''s Money tab, Money by part shows what is still open for the rental, the fees and later charges, the deposit and the card on file. Each part is paid its own way, in any mix: for example the deposit in cash and the rental by card.

1. **Record a payment**: choose what it is for (the rental, fees, the deposit or a later charge) and how it was paid (e-Transfer, cash, cheque, bank transfer, platform payout, the insurer). An e-Transfer, cheque or transfer needs its reference. Press **Record it**. The renter gets a receipt; **Print** prints one to hand over.
2. **Collect a card**: a payment (Everything open by default: the rental, the fees and any later charge in one), the deposit hold or saving the card. The renter types the card in Stripe''s secure form: on this device (**Open the card form**, then hand it over) or by a link texted or emailed to them (**Send the link**). Staff never type a card number.
3. A deposit hold lasts about 7 days and shows the days left; while the car is out it is collected by itself before it lapses. After the return, settle the deposit (below). **Capture the hold** for all of it keeps the money; a part capture or **Release the hold** waits for the settlement while the car is out or something is open (an Admin may do it with the reason).
4. **Charge the saved card** (Finance or an Admin): extra kilometres, fuel, damage or a late return, with the reason the renter''s receipt shows. For a rental over 7 days, save the card and charge the deposit this way.
5. An offer paid another way: once the renter approved and signed and the money is recorded, the booking is confirmed (or press **Confirm the booking**).
6. A deposit taken in cash or by e-Transfer is given back the same way after the return: Finance gets a task; press **Returned** with the reference or receipt number.

> Good to know: Statements, reconciliation and the deposit settlement read each payment with its method: a cash deposit is never refunded to a card.

## Settle the deposit

The deposit is never given back by itself. Finance or an Admin settles it after the return: on the booking''s Money tab, under Deposit, press **Settle the deposit**. Issue the Check-in statement first.

1. The form shows the deposit, what is still available, the charges owed from the statement and what is taken from the deposit for them. What the deposit does not cover is charged to the card on file; with no card (or a card declined), the renter gets a pay link by email and text, and Finance has a task until it is paid.
2. Tolls and tickets can take up to 7 days to come in. Inside that window the whole rest of the deposit is filled in as the hold-back, until the window ends. To give it back sooner, tick Release now anyway: a toll that comes in later is charged to the card on file.
3. Something still open keeps the whole deposit: an incident, a claim, new damage at the return not priced, damage found later not billed, a toll or ticket on the car during the rental not matched or not charged, a card dispute, or charges not on a statement yet. The form lists them. Only an Admin can release part of it, with the reason; it is recorded.
4. Damage: **Keep the whole deposit (damage)** turns what is left of the deposit into a damage charge, with what was damaged and the photos; the renter is told. **Bill damage** adds a damage charge up to the $2,500 deductible (more goes through a claim): the deposit pays first, then the card on file.
5. Press **Settle**. The money moves at Stripe at once: the charges are collected and what is not owed is refunded or the hold released. A step Stripe refuses is tried again by itself, and Finance gets a task if it keeps failing.

> Good to know: A card hold lapses after about 7 days. While the car is out, or returned and not settled, the hold is collected in full a day and a half before it lapses: that keeps the money, and the settlement refunds what is not owed. A hold that lapses anyway is charged to the saved card, and Finance is told at once.

## A booking

Open **Bookings** > **Bookings**, then a booking number. Or type the number in the search box.

1. Tabs: Overview, Money, Changes, History, and Drivers and documents.
2. Overview shows the trip, the renter, what is still missing for the handover, and the price.
3. Open tasks for this booking, with the queue and the due time.
4. Top right: **Stop blocking the calendar**, **Cancel for the renter** and **Cancel by CarmaCars**.
5. Under the booking number: where the booking is on its way, from Request to Closed, with the dates, the days, the total and who pays.

![](/guides/img/admin-04-booking-desktop-b56b668a.jpg "desktop; size: 1440 960; address: carmacars.ca/admin/bookings/CC-10065; pins: 2 50.0 46.6, 4 85.4 14.5, 5 22.9 26.8")

## Check a car out or in

From the booking, with your phone or a tablet: the same checklist field staff use.

1. A confirmed booking shows **Check out (pickup)** under Check-out, check-in and signing; a booking on rent shows **Check in (return)**. Today lists the check-outs and check-ins due, each with **Check out** or **Check in**.
2. The checklist opens: the ready check, the renter and their licence and card, the odometer (km) and fuel or charge, the keys, the photo set (every side, the wheels, the interior, the odometer and fuel gauge, the plate), damage marks with close-ups, then the renter and you sign.
3. Photos wait on the device without a connection and upload in the background. Each keeps its time, and the place when the device allows location.
4. A field job of the booking is taken over (the history says so); with no job, one is made for you. When done, press **See the photo report**.

> Tip: Fleet, Sales and Customer service check cars out and in the same way from their own booking page.

## The photo report, late returns and the return charges

Under Check-out, check-in and signing, press **Photo report**.

1. The report shows the due-back time, the actual check-out and check-in, Late by (or Overdue by while the car is out), the odometer and kilometres over the allowance, the fuel or charge out and in, every photo with its time and place, and the damage.
2. At check-in the late return (after the grace period of the fee defaults), the mileage overage and the fuel or recharging are written to the return charges at once. A gas car with no pump receipt is priced at the refill price per eighth (Program settings) plus the markup until the receipt is entered.
3. Not charging one? Press **Waive** beside it and give the reason: it stays waived if the charges are worked out again.
4. The time was wrong? Press **Correct the check-in time** (or the check-out time) with the reason: lateness and the late charges follow, and the history keeps both times.
5. The renter gets the same report (without these buttons) by email and in their Documents. Late by shows on the booking and in the Bookings list.

## Signatures on the spot, or by link

The renter or an additional driver signs the rental agreement on your device, or on their own phone.

1. While a signature is missing, the booking shows **Sign now on this device**, **Email the signing link** and **Text the signing link**.
2. No agreement made yet (the renter has not saved their details at home)? **Sign now on this device** still shows: press **Prepare the agreement to sign now** and it is made on the spot.
3. **Sign now on this device**: confirm the name matches their licence and that you saw the original licence (photograph it if none is on file), then press **Hand the device to** and their name.
4. They read both agreements (CarmaCars'' and Blind Spot''s), tick the statements and sign. Then **Back to the staff view** for the next signer.
5. The record is the same as signing online, and says it was signed in person, collected by you, on your device. It is printed on the signed copy''s signature record page.

## Rental agreements: every version, every field

The booking''s Rental agreements card: the current version of CarmaCars'' and Blind Spot''s agreements, every earlier one, and what is still blank.

1. Once the agreement is signed and countersigned, any change to what it prints makes a new version of both documents by itself: the dates, the price lines, the car, a driver added or corrected, the coverage, the deposit or how it was paid, an address.
2. A change to the dates, the price, the car, the drivers or the coverage option is signed again: the renter (and each driver it affects) gets their link by email and text, and the card shows "Agreement v3 waiting for signature". A correction (a typo in an address, a plate written differently) is filed without signing; the renter gets the corrected copy by email.
3. Check-out makes the "as picked up" copy (time out, km out, fuel out, the car''s plate and VIN, the check-out report), countersigned by whoever checked the car out; check-in makes the closing copy (time in, km in, driven and charged, fuel in, late hours, damage, the return charges, the final totals). Both go to the renter by email.
4. **Every version** lists each one with what changed and both PDFs. **Resend the signing links**, or press the button with their first name beside it to have them sign on your phone or tablet.
5. The card lists what the agreements still print blank (a licence expiry, the insurer''s policy number, the insured vehicle, a VIN). Type the values and press **Save the missing fields**: the agreements follow.
6. Check-out stops while a field a claim needs is blank. An Admin can let it go ahead: type the reason and press **Override**; the reason is in the booking''s history.
7. **Make the agreements again** checks both against the booking at once (they also follow every change by themselves).

## Signing that holds up in a dispute

Every signature of a rental agreement, an amendment or a new version is made the same way, remotely or on your device.

1. The signer confirms it is them with a 6-digit code sent to their phone or email on file; the licence on file is shown.
2. They say they read the documents, initial the key terms (damage and the deductible, the deposit and later charges, fuel, kilometres and late returns, their coverage, cancellation), give three consents (to sign electronically, to receive records electronically, to card charges under the agreement) and draw their signature.
3. Each step is recorded with its time, IP address and device, and the place when the device shares it. The signed PDFs end with a certificate of completion; anyone can check a signed file at `carmacars.ca/verify`.
4. Typed names are off. For a signer who cannot draw, an Admin can turn on the accessibility fallback: **Settings** > **Program**, Esign typed fallback.

## Card disputes: the evidence pack

Everything that proves the rental, in one PDF for Stripe.

1. When a card payment is disputed, the evidence pack is built by itself: the signed agreements with their certificates, the check-out and check-in reports with photos, kilometres and fuel, the licence, the payments and charges, every message to the renter, and the card checks from Stripe. It is staged in Stripe as the dispute''s evidence, and To do gets an urgent task.
2. Open the booking: the Rental agreements card shows the pack. Press **Download** to check it, then **Submit to Stripe** before the evidence date.
3. **Build the dispute evidence pack** makes one at any time (an Admin or Finance).

## The licence before an offer is accepted

Front, back and a selfie, from the request on.

1. After sending a request the renter is asked for their licence. A licence already on file from an earlier booking is used again while it is valid after the return.
2. The offer cannot be accepted (by the renter, or by you on their word) and nothing is paid until the licence and its expiry date are on file.
3. Review the images as usual with **Review documents**: the card Renter documents is on Review and offer too.
4. The switch is in **Settings** > **Program**, Booking requests and offers: Booking licence required (on), with the selfie (on).

## Renter documents: licence and proof of coverage

A renter''s licence photos, selfie and proof of coverage (OPCF 27 or a credit card''s rental coverage) are checked before the handover. You check them yourself; no task is needed.

1. A booking with documents waiting is a line on To do: "Check ''s documents for booking ", marked Now when the pickup is within two days. Press **Review documents**.
2. The pop-up shows each driver''s images and the coverage: the insurer, policy number and expiry, or the card, its type and whether the name matches.
3. What to check is written once at the top. One wrong? Open **Reject this one** under it, type the reason the renter reads and press **Reject**: they are asked for a new one.
4. Then press **Approve all**: every image, the proof of coverage and the Protection Plan still waiting are approved in one step. Anything the system refuses is named with the reason.
5. The same pop-up is on the booking: the card Renter documents (**Review documents**) on Overview and on Drivers and documents.

> Tip: Each opening of a renter''s documents is logged. The links to the images last one minute. Field staff can also check a licence in person at the check-out (photos and four checks): the history says "checked in person". Field staff also review the licence images (not the coverage) of bookings on their own jobs in the next 7 days from My jobs, with the same Approve all or a reason to reject: the history says the reviewer''s role, field. Sales review the licence images (not the coverage) of any booking being arranged or under way from their To do or the booking, with the same Approve all or a reason to reject: the history says the role, sales.

## Payments by day

**Money** > **Payments by day**: every payment and refund of a day or a range, by method, the cash drawer and the refunds waiting. Finance has the same screen.

1. Choose From and To and the methods (card, e-Transfer, cash, cheque, platform payout, insurer, bank transfer, pre-authorized debit, other), then press **Show**.
2. Totals by method and for each day; cards read as the card and its last four digits, never a code.
3. The cash drawer: expected (cash in less cash given back) against the count Finance records with **Record the count**; a difference shows over or short.
4. Refunds waiting: every refund asked for anywhere with the policy maths. **Approve** or **Decline** with the reason in the row, then **Issue the refund**.
5. **Export CSV** for the bookkeeper.

## Propose a change to a confirmed booking

The renter gets an email and answers on their booking. The calendar moves only when they accept.

1. Open the booking''s Changes tab. Under Propose a change, set the new pickup, return or car.
2. To price it by hand, type a New rental charge before tax. Leave it empty to use the car''s rates.
3. Write the Reason, for the renter. They read it.
4. Press **Preview the price**, then **Send to the renter**.

![](/guides/img/admin-05-booking-changes-desktop-97008b21.jpg "desktop; size: 1200 520; address: carmacars.ca/admin/bookings/CC-10065?tab=changes; pins: 1 17.5 33.7, 2 9.2 50.0, 3 38.3 71.2, 4 12.9 91.9")

## Who a booking is credited to

Overview (and Review and offer) shows the Sales credit: the staff member the booking counts for in their sales.

1. A quote or a rental is credited to whoever created or added it. A request from the website is credited to whoever sent its first offer.
2. To give it to someone else, press **Reassign**, choose who (or Nobody), say whether they sourced the client and write the reason. The booking''s history and the audit log keep it, and the deal stays in the same week and month.
3. Sourced means the staff member chose I sourced this client when they entered it, it came with a field staff referral link, or you credited it. Only a sourced booking earns a staff commission. A website request earns none unless you credit someone.
4. Someone said they sourced a website request? The credit line shows the claim: press **Credit them** or **Not theirs**, with a reason.
5. A price typed by hand shows beside the rate-sheet price, with the reason. A price under the floor or past the discount limit is flagged: press **Mark reviewed** once you have looked at it.

> Tip: The renter has 48 hours to accept (and sign the amendment) or decline, with one reminder. Any extra is charged to their Card on File; a lower price raises a refund for your approval.

## Review requests

Every renter is asked for a review by email and text, as they chose, only from 9 am to 9 pm Toronto time. Nothing needs setting up.

| Message | When |
| --- | --- |
| Mid-trip check-in | Rentals of 2 days or more, 24 hours after the pickup: "How is the car? Reply or call if anything is off." No review ask. |
| Review request | 1 hour after the check-in. It links the review page: the renter taps what they liked, adds a sentence, and gets a short draft to copy and post on Google. |
| Reminder | 24 hours after the request. |
| Final follow-up | 7 days after the request. Nothing more after it. |

1. The booking page has the card Review requests: each message with when it went or when it will go, and why it stopped.
2. **Ask for a review** sends the request now (or at 9 am if it is later than 9 pm), on any booking on a trip, returned or closed. Not twice in 24 hours.
3. On hold: a return or later charge (late return, kilometres, fuel, cleaning, smoking, damage, tolls and tickets) is not settled or waived, or an incident or dispute is open. The request goes by itself once they are. Press **Send anyway** to send it now.
4. **Mark reviewed** stops the messages when the renter tells you they already reviewed.

The messages also stop by themselves when the renter presses "I already left a review", leaves a review on the site, unsubscribes, or a Google review is matched to them. **Bookings** > **Reviews** has the numbers (requests sent, on hold, reviews detected, the average rating), the hold list and the Google reviews to match.

> Tip: The draft is made only from what the renter picked and wrote, and from the booking (the car, how long, delivery or pickup). Everyone gets the Google link, whatever their stars; a renter who gives 3 stars or fewer also sees "Something wasn''t right? Tell us directly".

## What the owner sees, and owner deductions

Each booking on an owner''s or partner''s car shows the card What the owner sees at the top of its page.

1. **Hide from the owner** keeps the booking''s revenue from the owner until the car is returned, or until the owner statement covering it is approved. The owner sees the booking as Booked with its dates, and the calendar still shows the car busy. Add a reason if you like: it is kept in the history.
2. **Show to the owner** shows it now. Approving the statement shows every hidden booking on it by itself.
3. Not shown to the owner is for a booking with no owner revenue (an insurance placeholder, a shareholder''s or the owner''s own use at no charge): the owner sees only that the car is unavailable for those dates. A booking with revenue cannot be set this way.
4. Add a rental and Send an offer have What the owner sees. It starts from Settings > Program, Owners and fleet: Owners see a booking''s revenue (right away by default).
5. On the Money tab, Owner deductions on this booking: **Add a booking expense** (cleaning, repair, fuel, platform fee or other, the amount, the reason the owner reads, a receipt number) comes off before Owner Revenue.
6. **Set the Revenue Share for this booking** applies within the car''s signed terms. Above the terms only an Admin can, with Above the signed terms ticked and the reason. **Back to the car''s terms** undoes it.
7. Add a rental has the same under The car''s owner.

> Good to know: The owner''s statement always includes every booking at its true amounts and lists each deduction with its reason, so the payout is always right. Customer service and sales add deductions only while Program settings let them change fees.
', 'Requests, offers and bookings', 'Send an offer with or without a request, change it in place, take payments by part, run a booking, propose a change.',
  'A booking starts as a request from the website, or as an offer you send yourself to a customer on the phone. You check it, adjust it and send the offer; an offer that is out is changed in place. After that, the booking page holds the money, documents, changes and history.

## The request queue

Open **Bookings** > **Requests**. The oldest waiting request is at the top.

1. Filter by New, Waiting on the renter, Pushed back, Offer out, Signing and payment, or Offer expired.
2. Waiting shows how long the renter has waited; red means past the first reply target (5 minutes, set in Program settings). Open a booking number to answer it.

![](/guides/img/admin-02-requests-desktop-6521282d.jpg "desktop; size: 1440 820; address: carmacars.ca/admin/requests; pins: 1 38.9 29.9, 2 22.2 43.3")

> Good to know: A request whose pickup time passes without an offer expires by itself, with a note in its history. The renter is not emailed unless "Email the renter when their request expires that way" is on in Program settings.

## Answer a request with an offer

1. The Review and offer tab shows the request as the renter sent it.
2. Adjust the car, the dates, the rate type, the places, the rates and fees, the deposit and extras.
3. Price on the right updates as you change things.
4. Add a message, choose how long the offer stays open, then press **Send the offer**.

![](/guides/img/admin-03-booking-review-desktop-353f3707.jpg "desktop; size: 1200 1550; address: carmacars.ca/admin/bookings/CC-10069?tab=review; pins: 1 5.0 6.5, 2 7.5 45.8, 3 74.2 42.6, 4 76.7 98.1")

5. Changed fields but not ready to send? Press **Save changes**. The panel "The offer as the renter sees it" shows the result.
6. Can''t do it? Press **Decline** and fill in Reason and any alternative.
7. Need an answer first? Press **Ask the renter** to send a question.

![](/guides/img/admin-03-booking-review-desktop-4dd4ed06.jpg "desktop; size: 500 80; address: carmacars.ca/admin/bookings/CC-10069?tab=review; pins: 6 41.2 52.5, 7 18.0 52.5")

Opening a request takes it for you: everyone else sees "Being answered by" your name and since when, with Send the offer and Decline off, until you send, decline or leave (20 minutes, renewed while you work; Program settings). Press **Take over** to answer one someone else holds; it is noted in the history. A second answer is refused with who answered and when. A request from the website opens to Sales after 15 minutes (Program settings); until then Admins, customer service and fleet answer it.

## Send an offer without a request

**Bookings** > **Send an offer**, or **Send an offer** on Bookings and on Requests. For a customer on the phone, by text or at the counter: no request needed.

1. The customer: type a name, phone or email and choose them. Not on file? Press **Add a new customer**: full legal name, mobile, email (the offer link goes there) and date of birth. A customer already on file with the same email or phone is shown with Use: one person, one record.
2. The car and the dates: type the car code, plate or name, or choose from the list; each car says Free or Not free for the dates. Then the pickup and return places (our location, delivery with the address and distance, airport).
3. The price: the Rate sheet, A total for the whole rental, or A rate per day (times the days). A price typed by hand needs its reason. At the top of the price, Amounts I type: Before tax, or After tax (HST included) to type what the renter pays for each line, worked back to the amount before tax for you (a line without HST stays as typed; the choice is remembered on this device). Or type the Total the renter pays (after tax): the rental charge is worked out so the total comes to it exactly, the other lines kept. Set the kilometres, a promo code, the deposit, a discount and each fee (an Admin), and how damage is covered: with option 3 the Protection Plan price is the one the renter pays.
4. How it is paid: the rental by card online (the usual way), e-Transfer, cash, cheque, bank transfer, platform payout or the insurer; the deposit by card hold, cash, e-Transfer or no deposit (an Admin).
5. Who found this client, the message to the renter, how long the offer is open, and how the link goes: Email, Text, both or neither.
6. The right side is the offer as the renter will see it, priced by the database as you type. Press **Send the offer**. **Save without sending** keeps it as a request for later.

> Good to know: It makes the same request and offer the website makes: the renter approves, signs and pays (or you record the payment), and only then is the car on the calendar. No "request received" email goes to the renter for an offer you send. Staff commissions and statements count it like any other booking.

## Change an offer that is out

The renter has the offer (Offered), or approved it and has not paid (Signing and payment). Press **Edit the offer** on the booking.

1. Change anything: the car, the dates, the places, the price, fees, the deposit, add-ons, how it is paid. Each changed field is highlighted and the before and after are listed. Amounts I type (Before tax or After tax) and the Total the renter pays (after tax) work as on Send an offer.
2. Write what changed in Message to the renter and choose how long the offer is open.
3. Press **Save and send the update**: the renter gets the new version by email or text (ticked), and the old version no longer counts. Or press **Save without telling the renter** and tell them yourself.
4. A confirmed booking is changed with **Change the booking** (Propose a change, below).

> Tip: No need to withdraw first. **Withdraw the offer** is only for taking it back for good; **Send again, later expiry** gives the renter more time, and **Renter approved by phone** records a yes given on a call.

## Edit a booking that has started

On a confirmed, on-trip or returned booking (an Admin: a closed one too), Overview, **Edit the booking**, **Edit**.

1. Change the pickup or the return (extend or shorten: the rental charge is worked out again at this booking''s rates), the car (on trip: the car it leaves goes to Out of service for Fleet to check), the rental charge for the trip, each fee, the kilometres a day, the deposit (an Admin) and the note.
2. Type why, if you like, and tick **Email the renter what changed**, or leave it off for a silent correction. Press **Save the changes**.
3. What is open now shows at once: **Email a pay link** or **Text a pay link** for exactly that amount, **Charge** the saved card (the renter agreed), or record cash or an e-Transfer on the Money tab.

> Good to know: Each edit is kept with who, when, why, before and after (Edits, under the form) and in the booking''s history. A closed booking''s owner split and the staff commission follow. To have the renter accept and sign first, use Propose a change instead.

## Fees, a forgotten fee and the balance

On the booking''s Money tab, Fees lists each fee. Press **Change or add a fee**.

1. Type a new amount (for the whole trip, before HST) beside any fee, or choose one not on the booking (the young driver fee shows its price for these dates), or add a charge of its own with or without HST.
2. Press **Save the fees**. The balance shows by part (rental, fees) with the pay link, the saved card and Record a payment beside it.
3. The renter sees the balance on their booking with a Pay button, and pays by card on Stripe''s form.

> Good to know: Every change is recorded (Changes to the fees): the amount before and after, who and why. Customer service and sales may change fees while Program settings, Staff may change fees, is on.

## Correct a renter''s details

On the renter''s page (People, Renters) or on any of their bookings, **Edit renter**.

1. Correct the name, email, phone, date of birth, licence, home address (start typing to find it) or the staff note.
2. A new email also becomes their sign-in at once (no confirmation needed for a typo you correct); tick **Email the renter a link to set a password** to send one there. Unsigned agreements and offers go to the new address.
3. Press **Save the renter**. An email that another renter has is refused with their name; the same phone is a warning.
4. The same person entered twice? Possible duplicates (same email, same phone, or same name and date of birth) shows under the renter. **Merge into this record** moves the other record''s bookings, licences, cards, payments, documents and messages here and fills any detail missing here; the other record stays, blocked, with the merge in both histories.

## Payments by part: the rental, the deposit and later charges

On the booking''s Money tab, Money by part shows what is still open for the rental, the fees and later charges, the deposit and the card on file. Each part is paid its own way, in any mix: for example the deposit in cash and the rental by card.

1. **Record a payment**: choose what it is for (the rental, fees, the deposit or a later charge) and how it was paid (e-Transfer, cash, cheque, bank transfer, platform payout, the insurer). An e-Transfer, cheque or transfer needs its reference. Press **Record it**. The renter gets a receipt; **Print** prints one to hand over.
2. **Collect a card**: a payment (Everything open by default: the rental, the fees and any later charge in one), the deposit hold or saving the card. The renter types the card in Stripe''s secure form: on this device (**Open the card form**, then hand it over) or by a link texted or emailed to them (**Send the link**). Staff never type a card number.
3. A deposit hold lasts about 7 days and shows the days left; while the car is out it is collected by itself before it lapses. After the return, settle the deposit (below). **Capture the hold** for all of it keeps the money; a part capture or **Release the hold** waits for the settlement while the car is out or something is open (an Admin may do it with the reason).
4. **Charge the saved card** (Finance or an Admin): extra kilometres, fuel, damage or a late return, with the reason the renter''s receipt shows. For a rental over 7 days, save the card and charge the deposit this way.
5. An offer paid another way: once the renter approved and signed and the money is recorded, the booking is confirmed (or press **Confirm the booking**).
6. A deposit taken in cash or by e-Transfer is given back the same way after the return: Finance gets a task; press **Returned** with the reference or receipt number.

> Good to know: Statements, reconciliation and the deposit settlement read each payment with its method: a cash deposit is never refunded to a card.

## Settle the deposit

The deposit is never given back by itself. Finance or an Admin settles it after the return: on the booking''s Money tab, under Deposit, press **Settle the deposit**. Issue the Check-in statement first.

1. The form shows the deposit, what is still available, the charges owed from the statement and what is taken from the deposit for them. What the deposit does not cover is charged to the card on file; with no card (or a card declined), the renter gets a pay link by email and text, and Finance has a task until it is paid.
2. Tolls and tickets can take up to 7 days to come in. Inside that window the whole rest of the deposit is filled in as the hold-back, until the window ends. To give it back sooner, tick Release now anyway: a toll that comes in later is charged to the card on file.
3. Something still open keeps the whole deposit: an incident, a claim, new damage at the return not priced, damage found later not billed, a toll or ticket on the car during the rental not matched or not charged, a card dispute, or charges not on a statement yet. The form lists them. Only an Admin can release part of it, with the reason; it is recorded.
4. Damage: **Keep the whole deposit (damage)** turns what is left of the deposit into a damage charge, with what was damaged and the photos; the renter is told. **Bill damage** adds a damage charge up to the $2,500 deductible (more goes through a claim): the deposit pays first, then the card on file.
5. Press **Settle**. The money moves at Stripe at once: the charges are collected and what is not owed is refunded or the hold released. A step Stripe refuses is tried again by itself, and Finance gets a task if it keeps failing.

> Good to know: A card hold lapses after about 7 days. While the car is out, or returned and not settled, the hold is collected in full a day and a half before it lapses: that keeps the money, and the settlement refunds what is not owed. A hold that lapses anyway is charged to the saved card, and Finance is told at once.

## A booking

Open **Bookings** > **Bookings**, then a booking number. Or type the number in the search box.

1. Tabs: Overview, Money, Changes, History, and Drivers and documents.
2. Overview shows the trip, the renter, what is still missing for the handover, and the price.
3. Open tasks for this booking, with the queue and the due time.
4. Top right: **Stop blocking the calendar**, **Cancel for the renter** and **Cancel by CarmaCars**.
5. Under the booking number: where the booking is on its way, from Request to Closed, with the dates, the days, the total and who pays.

![](/guides/img/admin-04-booking-desktop-b56b668a.jpg "desktop; size: 1440 960; address: carmacars.ca/admin/bookings/CC-10065; pins: 2 50.0 46.6, 4 85.4 14.5, 5 22.9 26.8")

## Check a car out or in

From the booking, with your phone or a tablet: the same checklist field staff use.

1. A confirmed booking shows **Check out (pickup)** under Check-out, check-in and signing; a booking on rent shows **Check in (return)**. Today lists the check-outs and check-ins due, each with **Check out** or **Check in**.
2. The checklist opens: the ready check, the renter and their licence and card, the odometer (km) and fuel or charge, the keys, the photo set (every side, the wheels, the interior, the odometer and fuel gauge, the plate), damage marks with close-ups, then the renter and you sign.
3. Photos wait on the device without a connection and upload in the background. Each keeps its time, and the place when the device allows location.
4. A field job of the booking is taken over (the history says so); with no job, one is made for you. When done, press **See the photo report**.

> Tip: Fleet, Sales and Customer service check cars out and in the same way from their own booking page.

## The photo report, late returns and the return charges

Under Check-out, check-in and signing, press **Photo report**.

1. The report shows the due-back time, the actual check-out and check-in, Late by (or Overdue by while the car is out), the odometer and kilometres over the allowance, the fuel or charge out and in, every photo with its time and place, and the damage.
2. At check-in the late return (after the grace period of the fee defaults), the mileage overage and the fuel or recharging are written to the return charges at once. A gas car with no pump receipt is priced at the refill price per eighth (Program settings) plus the markup until the receipt is entered.
3. Not charging one? Press **Waive** beside it and give the reason: it stays waived if the charges are worked out again.
4. The time was wrong? Press **Correct the check-in time** (or the check-out time) with the reason: lateness and the late charges follow, and the history keeps both times.
5. The renter gets the same report (without these buttons) by email and in their Documents. Late by shows on the booking and in the Bookings list.

## Signatures on the spot, or by link

The renter or an additional driver signs the rental agreement on your device, or on their own phone.

1. While a signature is missing, the booking shows **Sign now on this device**, **Email the signing link** and **Text the signing link**.
2. No agreement made yet (the renter has not saved their details at home)? **Sign now on this device** still shows: press **Prepare the agreement to sign now** and it is made on the spot.
3. **Sign now on this device**: confirm the name matches their licence and that you saw the original licence (photograph it if none is on file), then press **Hand the device to** and their name.
4. They read both agreements (CarmaCars'' and Blind Spot''s), tick the statements and sign. Then **Back to the staff view** for the next signer.
5. The record is the same as signing online, and says it was signed in person, collected by you, on your device. It is printed on the signed copy''s signature record page.

## Rental agreements: every version, every field

The booking''s Rental agreements card: the current version of CarmaCars'' and Blind Spot''s agreements, every earlier one, and what is still blank.

1. Once the agreement is signed and countersigned, any change to what it prints makes a new version of both documents by itself: the dates, the price lines, the car, a driver added or corrected, the coverage, the deposit or how it was paid, an address.
2. A change to the dates, the price, the car, the drivers or the coverage option is signed again: the renter (and each driver it affects) gets their link by email and text, and the card shows "Agreement v3 waiting for signature". A correction (a typo in an address, a plate written differently) is filed without signing; the renter gets the corrected copy by email.
3. Check-out makes the "as picked up" copy (time out, km out, fuel out, the car''s plate and VIN, the check-out report), countersigned by whoever checked the car out; check-in makes the closing copy (time in, km in, driven and charged, fuel in, late hours, damage, the return charges, the final totals). Both go to the renter by email.
4. **Every version** lists each one with what changed and both PDFs. **Resend the signing links**, or press the button with their first name beside it to have them sign on your phone or tablet.
5. The card lists what the agreements still print blank (a licence expiry, the insurer''s policy number, the insured vehicle, a VIN). Type the values and press **Save the missing fields**: the agreements follow.
6. Check-out stops while a field a claim needs is blank. An Admin can let it go ahead: type the reason and press **Override**; the reason is in the booking''s history.
7. **Make the agreements again** checks both against the booking at once (they also follow every change by themselves).

## Signing that holds up in a dispute

Every signature on the site is made the same way: rental agreements, amendments and new versions (remotely or on your device), and the owner agreements, schedules and forms, a co-owner''s link, the partner, investment and staff agreements.

1. The signer confirms it is them with a 6-digit code sent to their phone or email on file; the licence on file is shown.
2. They say they read the documents, initial the key terms (damage and the deductible, the deposit and later charges, fuel, kilometres and late returns, their coverage, cancellation), give three consents (to sign electronically, to receive records electronically, to card charges under the agreement) and draw their signature.
3. Owners, partners, investors and staff do the same for their documents: the code, the reading, the key terms of their documents initialled (for example the Enrollment Agreement''s three confirmations, Form C''s acknowledgments, Schedule C, the staff agreement''s confidentiality), two consents and the drawn signature. Form C''s witness still types their name beside the owner.
4. Each step is recorded with its time, IP address and device, and the place when the device shares it. The signed PDFs end with a certificate of completion; anyone can check a signed file at `carmacars.ca/verify`.
5. Typed names are off. For a signer who cannot draw, an Admin can turn on the accessibility fallback: **Settings** > **Program**, Esign typed fallback.

## Card disputes: the evidence pack

Everything that proves the rental, in one PDF for Stripe.

1. When a card payment is disputed, the evidence pack is built by itself: the signed agreements with their certificates, the check-out and check-in reports with photos, kilometres and fuel, the licence, the payments and charges, every message to the renter, and the card checks from Stripe. It is staged in Stripe as the dispute''s evidence, and To do gets an urgent task.
2. Open the booking: the Rental agreements card shows the pack. Press **Download** to check it, then **Submit to Stripe** before the evidence date.
3. **Build the dispute evidence pack** makes one at any time (an Admin or Finance).

## The licence before an offer is accepted

Front, back and a selfie, from the request on.

1. After sending a request the renter is asked for their licence. A licence already on file from an earlier booking is used again while it is valid after the return.
2. The offer cannot be accepted (by the renter, or by you on their word) and nothing is paid until the licence and its expiry date are on file.
3. Review the images as usual with **Review documents**: the card Renter documents is on Review and offer too.
4. The switch is in **Settings** > **Program**, Booking requests and offers: Booking licence required (on), with the selfie (on).

## Renter documents: licence and proof of coverage

A renter''s licence photos, selfie and proof of coverage (OPCF 27 or a credit card''s rental coverage) are checked before the handover. You check them yourself; no task is needed.

1. A booking with documents waiting is a line on To do: "Check ''s documents for booking ", marked Now when the pickup is within two days. Press **Review documents**.
2. The pop-up shows each driver''s images and the coverage: the insurer, policy number and expiry, or the card, its type and whether the name matches.
3. What to check is written once at the top. One wrong? Open **Reject this one** under it, type the reason the renter reads and press **Reject**: they are asked for a new one.
4. Then press **Approve all**: every image, the proof of coverage and the Protection Plan still waiting are approved in one step. Anything the system refuses is named with the reason.
5. The same pop-up is on the booking: the card Renter documents (**Review documents**) on Overview and on Drivers and documents.

> Tip: Each opening of a renter''s documents is logged. The links to the images last one minute. Field staff can also check a licence in person at the check-out (photos and four checks): the history says "checked in person". Field staff also review the licence images (not the coverage) of bookings on their own jobs in the next 7 days from My jobs, with the same Approve all or a reason to reject: the history says the reviewer''s role, field. Sales review the licence images (not the coverage) of any booking being arranged or under way from their To do or the booking, with the same Approve all or a reason to reject: the history says the role, sales.

## Payments by day

**Money** > **Payments by day**: every payment and refund of a day or a range, by method, the cash drawer and the refunds waiting. Finance has the same screen.

1. Choose From and To and the methods (card, e-Transfer, cash, cheque, platform payout, insurer, bank transfer, pre-authorized debit, other), then press **Show**.
2. Totals by method and for each day; cards read as the card and its last four digits, never a code.
3. The cash drawer: expected (cash in less cash given back) against the count Finance records with **Record the count**; a difference shows over or short.
4. Refunds waiting: every refund asked for anywhere with the policy maths. **Approve** or **Decline** with the reason in the row, then **Issue the refund**.
5. **Export CSV** for the bookkeeper.

## Propose a change to a confirmed booking

The renter gets an email and answers on their booking. The calendar moves only when they accept.

1. Open the booking''s Changes tab. Under Propose a change, set the new pickup, return or car.
2. To price it by hand, type a New rental charge before tax. Leave it empty to use the car''s rates.
3. Write the Reason, for the renter. They read it.
4. Press **Preview the price**, then **Send to the renter**.

![](/guides/img/admin-05-booking-changes-desktop-97008b21.jpg "desktop; size: 1200 520; address: carmacars.ca/admin/bookings/CC-10065?tab=changes; pins: 1 17.5 33.7, 2 9.2 50.0, 3 38.3 71.2, 4 12.9 91.9")

## Who a booking is credited to

Overview (and Review and offer) shows the Sales credit: the staff member the booking counts for in their sales.

1. A quote or a rental is credited to whoever created or added it. A request from the website is credited to whoever sent its first offer.
2. To give it to someone else, press **Reassign**, choose who (or Nobody), say whether they sourced the client and write the reason. The booking''s history and the audit log keep it, and the deal stays in the same week and month.
3. Sourced means the staff member chose I sourced this client when they entered it, it came with a field staff referral link, or you credited it. Only a sourced booking earns a staff commission. A website request earns none unless you credit someone.
4. Someone said they sourced a website request? The credit line shows the claim: press **Credit them** or **Not theirs**, with a reason.
5. A price typed by hand shows beside the rate-sheet price, with the reason. A price under the floor or past the discount limit is flagged: press **Mark reviewed** once you have looked at it.

> Tip: The renter has 48 hours to accept (and sign the amendment) or decline, with one reminder. Any extra is charged to their Card on File; a lower price raises a refund for your approval.

## Review requests

Every renter is asked for a review by email and text, as they chose, only from 9 am to 9 pm Toronto time. Nothing needs setting up.

| Message | When |
| --- | --- |
| Mid-trip check-in | Rentals of 2 days or more, 24 hours after the pickup: "How is the car? Reply or call if anything is off." No review ask. |
| Review request | 1 hour after the check-in. It links the review page: the renter taps what they liked, adds a sentence, and gets a short draft to copy and post on Google. |
| Reminder | 24 hours after the request. |
| Final follow-up | 7 days after the request. Nothing more after it. |

1. The booking page has the card Review requests: each message with when it went or when it will go, and why it stopped.
2. **Ask for a review** sends the request now (or at 9 am if it is later than 9 pm), on any booking on a trip, returned or closed. Not twice in 24 hours.
3. On hold: a return or later charge (late return, kilometres, fuel, cleaning, smoking, damage, tolls and tickets) is not settled or waived, or an incident or dispute is open. The request goes by itself once they are. Press **Send anyway** to send it now.
4. **Mark reviewed** stops the messages when the renter tells you they already reviewed.

The messages also stop by themselves when the renter presses "I already left a review", leaves a review on the site, unsubscribes, or a Google review is matched to them. **Bookings** > **Reviews** has the numbers (requests sent, on hold, reviews detected, the average rating), the hold list and the Google reviews to match.

> Tip: The draft is made only from what the renter picked and wrote, and from the booking (the car, how long, delivery or pickup). Everyone gets the Google link, whatever their stars; a renter who gives 3 stars or fewer also sees "Something wasn''t right? Tell us directly".

## What the owner sees, and owner deductions

Each booking on an owner''s or partner''s car shows the card What the owner sees at the top of its page.

1. **Hide from the owner** keeps the booking''s revenue from the owner until the car is returned, or until the owner statement covering it is approved. The owner sees the booking as Booked with its dates, and the calendar still shows the car busy. Add a reason if you like: it is kept in the history.
2. **Show to the owner** shows it now. Approving the statement shows every hidden booking on it by itself.
3. Not shown to the owner is for a booking with no owner revenue (an insurance placeholder, a shareholder''s or the owner''s own use at no charge): the owner sees only that the car is unavailable for those dates. A booking with revenue cannot be set this way.
4. Add a rental and Send an offer have What the owner sees. It starts from Settings > Program, Owners and fleet: Owners see a booking''s revenue (right away by default).
5. On the Money tab, Owner deductions on this booking: **Add a booking expense** (cleaning, repair, fuel, platform fee or other, the amount, the reason the owner reads, a receipt number) comes off before Owner Revenue.
6. **Set the Revenue Share for this booking** applies within the car''s signed terms. Above the terms only an Admin can, with Above the signed terms ticked and the reason. **Back to the car''s terms** undoes it.
7. Add a rental has the same under The car''s owner.

> Good to know: The owner''s statement always includes every booking at its true amounts and lists each deduction with its reason, so the payout is always right. Customer service and sales add deductions only while Program settings let them change fees.
',
  '<p class="gd-p">A booking starts as a request from the website, or as an offer you send yourself to a customer on the phone. You check it, adjust it and send the offer; an offer that is out is changed in place. After that, the booking page holds the money, documents, changes and history.</p><section class="gd-task" id="requests-offers-and-bookings-the-request-queue" data-gd-task><h2 class="gd-h2">The request queue</h2><p class="gd-p">Open <b class="gd-ui">Bookings</b> &gt; <b class="gd-ui">Requests</b>. The oldest waiting request is at the top.</p><div class="gd-stepblock gd-stepblock--below"><div class="gd-stepcol"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">Filter by New, Waiting on the renter, Pushed back, Offer out, Signing and payment, or Offer expired.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Waiting shows how long the renter has waited; red means past the first reply target (5 minutes, set in Program settings). Open a booking number to answer it.</div></li></ol></div><figure class="gd-fig gd-fig--desk"><div class="gd-browser"><div class="gd-bar" aria-hidden="true"><i></i><i></i><i></i><span class="gd-addr">carmacars.ca/admin/requests</span></div><div class="gd-imgwrap" style="aspect-ratio:1440/820"><img src="/guides/img/admin-02-requests-desktop-6521282d.jpg" alt="" loading="lazy" decoding="async" width="1440" height="820"><span class="gd-pin" style="left:38.9%;top:29.9%" aria-hidden="true">1</span><span class="gd-pin" style="left:22.2%;top:43.3%" aria-hidden="true">2</span></div></div></figure></div><aside class="gd-box"><span class="gd-lbl">Good to know</span><div>A request whose pickup time passes without an offer expires by itself, with a note in its history. The renter is not emailed unless &quot;Email the renter when their request expires that way&quot; is on in Program settings.</div></aside></section><section class="gd-task" id="requests-offers-and-bookings-answer-a-request-with-an-offer" data-gd-task><h2 class="gd-h2">Answer a request with an offer</h2><div class="gd-stepblock gd-stepblock--below"><div class="gd-stepcol"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">The Review and offer tab shows the request as the renter sent it.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Adjust the car, the dates, the rate type, the places, the rates and fees, the deposit and extras.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Price on the right updates as you change things.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t">Add a message, choose how long the offer stays open, then press <b class="gd-ui">Send the offer</b>.</div></li></ol></div><figure class="gd-fig gd-fig--desk"><div class="gd-browser"><div class="gd-bar" aria-hidden="true"><i></i><i></i><i></i><span class="gd-addr">carmacars.ca/admin/bookings/CC-10069?tab=review</span></div><div class="gd-imgwrap" style="aspect-ratio:1200/1550"><img src="/guides/img/admin-03-booking-review-desktop-353f3707.jpg" alt="" loading="lazy" decoding="async" width="1200" height="1550"><span class="gd-pin" style="left:5%;top:6.5%" aria-hidden="true">1</span><span class="gd-pin" style="left:7.5%;top:45.8%" aria-hidden="true">2</span><span class="gd-pin" style="left:74.2%;top:42.6%" aria-hidden="true">3</span><span class="gd-pin" style="left:76.7%;top:98.1%" aria-hidden="true">4</span></div></div></figure></div><div class="gd-stepblock gd-stepblock--below"><div class="gd-stepcol"><ol class="gd-ol" start="5"><li><span class="gd-n" aria-hidden="true">5</span><div class="gd-t">Changed fields but not ready to send? Press <b class="gd-ui">Save changes</b>. The panel &quot;The offer as the renter sees it&quot; shows the result.</div></li><li><span class="gd-n" aria-hidden="true">6</span><div class="gd-t">Can&#39;t do it? Press <b class="gd-ui">Decline</b> and fill in Reason and any alternative.</div></li><li><span class="gd-n" aria-hidden="true">7</span><div class="gd-t">Need an answer first? Press <b class="gd-ui">Ask the renter</b> to send a question.</div></li></ol></div><figure class="gd-fig gd-fig--desk"><div class="gd-browser"><div class="gd-bar" aria-hidden="true"><i></i><i></i><i></i><span class="gd-addr">carmacars.ca/admin/bookings/CC-10069?tab=review</span></div><div class="gd-imgwrap" style="aspect-ratio:500/80"><img src="/guides/img/admin-03-booking-review-desktop-4dd4ed06.jpg" alt="" loading="lazy" decoding="async" width="500" height="80"><span class="gd-pin" style="left:41.2%;top:52.5%" aria-hidden="true">6</span><span class="gd-pin" style="left:18%;top:52.5%" aria-hidden="true">7</span></div></div></figure></div><p class="gd-p">Opening a request takes it for you: everyone else sees &quot;Being answered by&quot; your name and since when, with Send the offer and Decline off, until you send, decline or leave (20 minutes, renewed while you work; Program settings). Press <b class="gd-ui">Take over</b> to answer one someone else holds; it is noted in the history. A second answer is refused with who answered and when. A request from the website opens to Sales after 15 minutes (Program settings); until then Admins, customer service and fleet answer it.</p></section><section class="gd-task" id="requests-offers-and-bookings-send-an-offer-without-a-request" data-gd-task><h2 class="gd-h2">Send an offer without a request</h2><p class="gd-p"><b class="gd-ui">Bookings</b> &gt; <b class="gd-ui">Send an offer</b>, or <b class="gd-ui">Send an offer</b> on Bookings and on Requests. For a customer on the phone, by text or at the counter: no request needed.</p><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">The customer: type a name, phone or email and choose them. Not on file? Press <b class="gd-ui">Add a new customer</b>: full legal name, mobile, email (the offer link goes there) and date of birth. A customer already on file with the same email or phone is shown with Use: one person, one record.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">The car and the dates: type the car code, plate or name, or choose from the list; each car says Free or Not free for the dates. Then the pickup and return places (our location, delivery with the address and distance, airport).</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">The price: the Rate sheet, A total for the whole rental, or A rate per day (times the days). A price typed by hand needs its reason. At the top of the price, Amounts I type: Before tax, or After tax (HST included) to type what the renter pays for each line, worked back to the amount before tax for you (a line without HST stays as typed; the choice is remembered on this device). Or type the Total the renter pays (after tax): the rental charge is worked out so the total comes to it exactly, the other lines kept. Set the kilometres, a promo code, the deposit, a discount and each fee (an Admin), and how damage is covered: with option 3 the Protection Plan price is the one the renter pays.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t">How it is paid: the rental by card online (the usual way), e-Transfer, cash, cheque, bank transfer, platform payout or the insurer; the deposit by card hold, cash, e-Transfer or no deposit (an Admin).</div></li><li><span class="gd-n" aria-hidden="true">5</span><div class="gd-t">Who found this client, the message to the renter, how long the offer is open, and how the link goes: Email, Text, both or neither.</div></li><li><span class="gd-n" aria-hidden="true">6</span><div class="gd-t">The right side is the offer as the renter will see it, priced by the database as you type. Press <b class="gd-ui">Send the offer</b>. <b class="gd-ui">Save without sending</b> keeps it as a request for later.</div></li></ol></div><aside class="gd-box"><span class="gd-lbl">Good to know</span><div>It makes the same request and offer the website makes: the renter approves, signs and pays (or you record the payment), and only then is the car on the calendar. No &quot;request received&quot; email goes to the renter for an offer you send. Staff commissions and statements count it like any other booking.</div></aside></section><section class="gd-task" id="requests-offers-and-bookings-change-an-offer-that-is-out" data-gd-task><h2 class="gd-h2">Change an offer that is out</h2><p class="gd-p">The renter has the offer (Offered), or approved it and has not paid (Signing and payment). Press <b class="gd-ui">Edit the offer</b> on the booking.</p><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">Change anything: the car, the dates, the places, the price, fees, the deposit, add-ons, how it is paid. Each changed field is highlighted and the before and after are listed. Amounts I type (Before tax or After tax) and the Total the renter pays (after tax) work as on Send an offer.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Write what changed in Message to the renter and choose how long the offer is open.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Press <b class="gd-ui">Save and send the update</b>: the renter gets the new version by email or text (ticked), and the old version no longer counts. Or press <b class="gd-ui">Save without telling the renter</b> and tell them yourself.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t">A confirmed booking is changed with <b class="gd-ui">Change the booking</b> (Propose a change, below).</div></li></ol></div><aside class="gd-box"><span class="gd-lbl">Tip</span><div>No need to withdraw first. <b class="gd-ui">Withdraw the offer</b> is only for taking it back for good; <b class="gd-ui">Send again, later expiry</b> gives the renter more time, and <b class="gd-ui">Renter approved by phone</b> records a yes given on a call.</div></aside></section><section class="gd-task" id="requests-offers-and-bookings-edit-a-booking-that-has-started" data-gd-task><h2 class="gd-h2">Edit a booking that has started</h2><p class="gd-p">On a confirmed, on-trip or returned booking (an Admin: a closed one too), Overview, <b class="gd-ui">Edit the booking</b>, <b class="gd-ui">Edit</b>.</p><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">Change the pickup or the return (extend or shorten: the rental charge is worked out again at this booking&#39;s rates), the car (on trip: the car it leaves goes to Out of service for Fleet to check), the rental charge for the trip, each fee, the kilometres a day, the deposit (an Admin) and the note.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Type why, if you like, and tick <b class="gd-ui">Email the renter what changed</b>, or leave it off for a silent correction. Press <b class="gd-ui">Save the changes</b>.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">What is open now shows at once: <b class="gd-ui">Email a pay link</b> or <b class="gd-ui">Text a pay link</b> for exactly that amount, <b class="gd-ui">Charge</b> the saved card (the renter agreed), or record cash or an e-Transfer on the Money tab.</div></li></ol></div><aside class="gd-box"><span class="gd-lbl">Good to know</span><div>Each edit is kept with who, when, why, before and after (Edits, under the form) and in the booking&#39;s history. A closed booking&#39;s owner split and the staff commission follow. To have the renter accept and sign first, use Propose a change instead.</div></aside></section><section class="gd-task" id="requests-offers-and-bookings-fees-a-forgotten-fee-and-the-balance" data-gd-task><h2 class="gd-h2">Fees, a forgotten fee and the balance</h2><p class="gd-p">On the booking&#39;s Money tab, Fees lists each fee. Press <b class="gd-ui">Change or add a fee</b>.</p><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">Type a new amount (for the whole trip, before HST) beside any fee, or choose one not on the booking (the young driver fee shows its price for these dates), or add a charge of its own with or without HST.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Press <b class="gd-ui">Save the fees</b>. The balance shows by part (rental, fees) with the pay link, the saved card and Record a payment beside it.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">The renter sees the balance on their booking with a Pay button, and pays by card on Stripe&#39;s form.</div></li></ol></div><aside class="gd-box"><span class="gd-lbl">Good to know</span><div>Every change is recorded (Changes to the fees): the amount before and after, who and why. Customer service and sales may change fees while Program settings, Staff may change fees, is on.</div></aside></section><section class="gd-task" id="requests-offers-and-bookings-correct-a-renter-s-details" data-gd-task><h2 class="gd-h2">Correct a renter&#39;s details</h2><p class="gd-p">On the renter&#39;s page (People, Renters) or on any of their bookings, <b class="gd-ui">Edit renter</b>.</p><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">Correct the name, email, phone, date of birth, licence, home address (start typing to find it) or the staff note.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">A new email also becomes their sign-in at once (no confirmation needed for a typo you correct); tick <b class="gd-ui">Email the renter a link to set a password</b> to send one there. Unsigned agreements and offers go to the new address.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Press <b class="gd-ui">Save the renter</b>. An email that another renter has is refused with their name; the same phone is a warning.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t">The same person entered twice? Possible duplicates (same email, same phone, or same name and date of birth) shows under the renter. <b class="gd-ui">Merge into this record</b> moves the other record&#39;s bookings, licences, cards, payments, documents and messages here and fills any detail missing here; the other record stays, blocked, with the merge in both histories.</div></li></ol></div></section><section class="gd-task" id="requests-offers-and-bookings-payments-by-part-the-rental-the-deposit-and-later-charges" data-gd-task><h2 class="gd-h2">Payments by part: the rental, the deposit and later charges</h2><p class="gd-p">On the booking&#39;s Money tab, Money by part shows what is still open for the rental, the fees and later charges, the deposit and the card on file. Each part is paid its own way, in any mix: for example the deposit in cash and the rental by card.</p><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t"><b class="gd-ui">Record a payment</b>: choose what it is for (the rental, fees, the deposit or a later charge) and how it was paid (e-Transfer, cash, cheque, bank transfer, platform payout, the insurer). An e-Transfer, cheque or transfer needs its reference. Press <b class="gd-ui">Record it</b>. The renter gets a receipt; <b class="gd-ui">Print</b> prints one to hand over.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t"><b class="gd-ui">Collect a card</b>: a payment (Everything open by default: the rental, the fees and any later charge in one), the deposit hold or saving the card. The renter types the card in Stripe&#39;s secure form: on this device (<b class="gd-ui">Open the card form</b>, then hand it over) or by a link texted or emailed to them (<b class="gd-ui">Send the link</b>). Staff never type a card number.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">A deposit hold lasts about 7 days and shows the days left; while the car is out it is collected by itself before it lapses. After the return, settle the deposit (below). <b class="gd-ui">Capture the hold</b> for all of it keeps the money; a part capture or <b class="gd-ui">Release the hold</b> waits for the settlement while the car is out or something is open (an Admin may do it with the reason).</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t"><b class="gd-ui">Charge the saved card</b> (Finance or an Admin): extra kilometres, fuel, damage or a late return, with the reason the renter&#39;s receipt shows. For a rental over 7 days, save the card and charge the deposit this way.</div></li><li><span class="gd-n" aria-hidden="true">5</span><div class="gd-t">An offer paid another way: once the renter approved and signed and the money is recorded, the booking is confirmed (or press <b class="gd-ui">Confirm the booking</b>).</div></li><li><span class="gd-n" aria-hidden="true">6</span><div class="gd-t">A deposit taken in cash or by e-Transfer is given back the same way after the return: Finance gets a task; press <b class="gd-ui">Returned</b> with the reference or receipt number.</div></li></ol></div><aside class="gd-box"><span class="gd-lbl">Good to know</span><div>Statements, reconciliation and the deposit settlement read each payment with its method: a cash deposit is never refunded to a card.</div></aside></section><section class="gd-task" id="requests-offers-and-bookings-settle-the-deposit" data-gd-task><h2 class="gd-h2">Settle the deposit</h2><p class="gd-p">The deposit is never given back by itself. Finance or an Admin settles it after the return: on the booking&#39;s Money tab, under Deposit, press <b class="gd-ui">Settle the deposit</b>. Issue the Check-in statement first.</p><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">The form shows the deposit, what is still available, the charges owed from the statement and what is taken from the deposit for them. What the deposit does not cover is charged to the card on file; with no card (or a card declined), the renter gets a pay link by email and text, and Finance has a task until it is paid.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Tolls and tickets can take up to 7 days to come in. Inside that window the whole rest of the deposit is filled in as the hold-back, until the window ends. To give it back sooner, tick Release now anyway: a toll that comes in later is charged to the card on file.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Something still open keeps the whole deposit: an incident, a claim, new damage at the return not priced, damage found later not billed, a toll or ticket on the car during the rental not matched or not charged, a card dispute, or charges not on a statement yet. The form lists them. Only an Admin can release part of it, with the reason; it is recorded.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t">Damage: <b class="gd-ui">Keep the whole deposit (damage)</b> turns what is left of the deposit into a damage charge, with what was damaged and the photos; the renter is told. <b class="gd-ui">Bill damage</b> adds a damage charge up to the $2,500 deductible (more goes through a claim): the deposit pays first, then the card on file.</div></li><li><span class="gd-n" aria-hidden="true">5</span><div class="gd-t">Press <b class="gd-ui">Settle</b>. The money moves at Stripe at once: the charges are collected and what is not owed is refunded or the hold released. A step Stripe refuses is tried again by itself, and Finance gets a task if it keeps failing.</div></li></ol></div><aside class="gd-box"><span class="gd-lbl">Good to know</span><div>A card hold lapses after about 7 days. While the car is out, or returned and not settled, the hold is collected in full a day and a half before it lapses: that keeps the money, and the settlement refunds what is not owed. A hold that lapses anyway is charged to the saved card, and Finance is told at once.</div></aside></section><section class="gd-task" id="requests-offers-and-bookings-a-booking" data-gd-task><h2 class="gd-h2">A booking</h2><p class="gd-p">Open <b class="gd-ui">Bookings</b> &gt; <b class="gd-ui">Bookings</b>, then a booking number. Or type the number in the search box.</p><div class="gd-stepblock gd-stepblock--below"><div class="gd-stepcol"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">Tabs: Overview, Money, Changes, History, and Drivers and documents.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Overview shows the trip, the renter, what is still missing for the handover, and the price.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Open tasks for this booking, with the queue and the due time.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t">Top right: <b class="gd-ui">Stop blocking the calendar</b>, <b class="gd-ui">Cancel for the renter</b> and <b class="gd-ui">Cancel by CarmaCars</b>.</div></li><li><span class="gd-n" aria-hidden="true">5</span><div class="gd-t">Under the booking number: where the booking is on its way, from Request to Closed, with the dates, the days, the total and who pays.</div></li></ol></div><figure class="gd-fig gd-fig--desk"><div class="gd-browser"><div class="gd-bar" aria-hidden="true"><i></i><i></i><i></i><span class="gd-addr">carmacars.ca/admin/bookings/CC-10065</span></div><div class="gd-imgwrap" style="aspect-ratio:1440/960"><img src="/guides/img/admin-04-booking-desktop-b56b668a.jpg" alt="" loading="lazy" decoding="async" width="1440" height="960"><span class="gd-pin" style="left:50%;top:46.6%" aria-hidden="true">2</span><span class="gd-pin" style="left:85.4%;top:14.5%" aria-hidden="true">4</span><span class="gd-pin" style="left:22.9%;top:26.8%" aria-hidden="true">5</span></div></div></figure></div></section><section class="gd-task" id="requests-offers-and-bookings-check-a-car-out-or-in" data-gd-task><h2 class="gd-h2">Check a car out or in</h2><p class="gd-p">From the booking, with your phone or a tablet: the same checklist field staff use.</p><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">A confirmed booking shows <b class="gd-ui">Check out (pickup)</b> under Check-out, check-in and signing; a booking on rent shows <b class="gd-ui">Check in (return)</b>. Today lists the check-outs and check-ins due, each with <b class="gd-ui">Check out</b> or <b class="gd-ui">Check in</b>.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">The checklist opens: the ready check, the renter and their licence and card, the odometer (km) and fuel or charge, the keys, the photo set (every side, the wheels, the interior, the odometer and fuel gauge, the plate), damage marks with close-ups, then the renter and you sign.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Photos wait on the device without a connection and upload in the background. Each keeps its time, and the place when the device allows location.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t">A field job of the booking is taken over (the history says so); with no job, one is made for you. When done, press <b class="gd-ui">See the photo report</b>.</div></li></ol></div><aside class="gd-box"><span class="gd-lbl">Tip</span><div>Fleet, Sales and Customer service check cars out and in the same way from their own booking page.</div></aside></section><section class="gd-task" id="requests-offers-and-bookings-the-photo-report-late-returns-and-the-return-charges" data-gd-task><h2 class="gd-h2">The photo report, late returns and the return charges</h2><p class="gd-p">Under Check-out, check-in and signing, press <b class="gd-ui">Photo report</b>.</p><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">The report shows the due-back time, the actual check-out and check-in, Late by (or Overdue by while the car is out), the odometer and kilometres over the allowance, the fuel or charge out and in, every photo with its time and place, and the damage.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">At check-in the late return (after the grace period of the fee defaults), the mileage overage and the fuel or recharging are written to the return charges at once. A gas car with no pump receipt is priced at the refill price per eighth (Program settings) plus the markup until the receipt is entered.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Not charging one? Press <b class="gd-ui">Waive</b> beside it and give the reason: it stays waived if the charges are worked out again.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t">The time was wrong? Press <b class="gd-ui">Correct the check-in time</b> (or the check-out time) with the reason: lateness and the late charges follow, and the history keeps both times.</div></li><li><span class="gd-n" aria-hidden="true">5</span><div class="gd-t">The renter gets the same report (without these buttons) by email and in their Documents. Late by shows on the booking and in the Bookings list.</div></li></ol></div></section><section class="gd-task" id="requests-offers-and-bookings-signatures-on-the-spot-or-by-link" data-gd-task><h2 class="gd-h2">Signatures on the spot, or by link</h2><p class="gd-p">The renter or an additional driver signs the rental agreement on your device, or on their own phone.</p><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">While a signature is missing, the booking shows <b class="gd-ui">Sign now on this device</b>, <b class="gd-ui">Email the signing link</b> and <b class="gd-ui">Text the signing link</b>.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">No agreement made yet (the renter has not saved their details at home)? <b class="gd-ui">Sign now on this device</b> still shows: press <b class="gd-ui">Prepare the agreement to sign now</b> and it is made on the spot.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t"><b class="gd-ui">Sign now on this device</b>: confirm the name matches their licence and that you saw the original licence (photograph it if none is on file), then press <b class="gd-ui">Hand the device to</b> and their name.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t">They read both agreements (CarmaCars&#39; and Blind Spot&#39;s), tick the statements and sign. Then <b class="gd-ui">Back to the staff view</b> for the next signer.</div></li><li><span class="gd-n" aria-hidden="true">5</span><div class="gd-t">The record is the same as signing online, and says it was signed in person, collected by you, on your device. It is printed on the signed copy&#39;s signature record page.</div></li></ol></div></section><section class="gd-task" id="requests-offers-and-bookings-rental-agreements-every-version-every-field" data-gd-task><h2 class="gd-h2">Rental agreements: every version, every field</h2><p class="gd-p">The booking&#39;s Rental agreements card: the current version of CarmaCars&#39; and Blind Spot&#39;s agreements, every earlier one, and what is still blank.</p><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">Once the agreement is signed and countersigned, any change to what it prints makes a new version of both documents by itself: the dates, the price lines, the car, a driver added or corrected, the coverage, the deposit or how it was paid, an address.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">A change to the dates, the price, the car, the drivers or the coverage option is signed again: the renter (and each driver it affects) gets their link by email and text, and the card shows &quot;Agreement v3 waiting for signature&quot;. A correction (a typo in an address, a plate written differently) is filed without signing; the renter gets the corrected copy by email.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Check-out makes the &quot;as picked up&quot; copy (time out, km out, fuel out, the car&#39;s plate and VIN, the check-out report), countersigned by whoever checked the car out; check-in makes the closing copy (time in, km in, driven and charged, fuel in, late hours, damage, the return charges, the final totals). Both go to the renter by email.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t"><b class="gd-ui">Every version</b> lists each one with what changed and both PDFs. <b class="gd-ui">Resend the signing links</b>, or press the button with their first name beside it to have them sign on your phone or tablet.</div></li><li><span class="gd-n" aria-hidden="true">5</span><div class="gd-t">The card lists what the agreements still print blank (a licence expiry, the insurer&#39;s policy number, the insured vehicle, a VIN). Type the values and press <b class="gd-ui">Save the missing fields</b>: the agreements follow.</div></li><li><span class="gd-n" aria-hidden="true">6</span><div class="gd-t">Check-out stops while a field a claim needs is blank. An Admin can let it go ahead: type the reason and press <b class="gd-ui">Override</b>; the reason is in the booking&#39;s history.</div></li><li><span class="gd-n" aria-hidden="true">7</span><div class="gd-t"><b class="gd-ui">Make the agreements again</b> checks both against the booking at once (they also follow every change by themselves).</div></li></ol></div></section><section class="gd-task" id="requests-offers-and-bookings-signing-that-holds-up-in-a-dispute" data-gd-task><h2 class="gd-h2">Signing that holds up in a dispute</h2><p class="gd-p">Every signature on the site is made the same way: rental agreements, amendments and new versions (remotely or on your device), and the owner agreements, schedules and forms, a co-owner&#39;s link, the partner, investment and staff agreements.</p><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">The signer confirms it is them with a 6-digit code sent to their phone or email on file; the licence on file is shown.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">They say they read the documents, initial the key terms (damage and the deductible, the deposit and later charges, fuel, kilometres and late returns, their coverage, cancellation), give three consents (to sign electronically, to receive records electronically, to card charges under the agreement) and draw their signature.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Owners, partners, investors and staff do the same for their documents: the code, the reading, the key terms of their documents initialled (for example the Enrollment Agreement&#39;s three confirmations, Form C&#39;s acknowledgments, Schedule C, the staff agreement&#39;s confidentiality), two consents and the drawn signature. Form C&#39;s witness still types their name beside the owner.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t">Each step is recorded with its time, IP address and device, and the place when the device shares it. The signed PDFs end with a certificate of completion; anyone can check a signed file at <span class="gd-url">carmacars.ca/verify</span>.</div></li><li><span class="gd-n" aria-hidden="true">5</span><div class="gd-t">Typed names are off. For a signer who cannot draw, an Admin can turn on the accessibility fallback: <b class="gd-ui">Settings</b> &gt; <b class="gd-ui">Program</b>, Esign typed fallback.</div></li></ol></div></section><section class="gd-task" id="requests-offers-and-bookings-card-disputes-the-evidence-pack" data-gd-task><h2 class="gd-h2">Card disputes: the evidence pack</h2><p class="gd-p">Everything that proves the rental, in one PDF for Stripe.</p><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">When a card payment is disputed, the evidence pack is built by itself: the signed agreements with their certificates, the check-out and check-in reports with photos, kilometres and fuel, the licence, the payments and charges, every message to the renter, and the card checks from Stripe. It is staged in Stripe as the dispute&#39;s evidence, and To do gets an urgent task.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Open the booking: the Rental agreements card shows the pack. Press <b class="gd-ui">Download</b> to check it, then <b class="gd-ui">Submit to Stripe</b> before the evidence date.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t"><b class="gd-ui">Build the dispute evidence pack</b> makes one at any time (an Admin or Finance).</div></li></ol></div></section><section class="gd-task" id="requests-offers-and-bookings-the-licence-before-an-offer-is-accepted" data-gd-task><h2 class="gd-h2">The licence before an offer is accepted</h2><p class="gd-p">Front, back and a selfie, from the request on.</p><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">After sending a request the renter is asked for their licence. A licence already on file from an earlier booking is used again while it is valid after the return.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">The offer cannot be accepted (by the renter, or by you on their word) and nothing is paid until the licence and its expiry date are on file.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Review the images as usual with <b class="gd-ui">Review documents</b>: the card Renter documents is on Review and offer too.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t">The switch is in <b class="gd-ui">Settings</b> &gt; <b class="gd-ui">Program</b>, Booking requests and offers: Booking licence required (on), with the selfie (on).</div></li></ol></div></section><section class="gd-task" id="requests-offers-and-bookings-renter-documents-licence-and-proof-of-coverage" data-gd-task><h2 class="gd-h2">Renter documents: licence and proof of coverage</h2><p class="gd-p">A renter&#39;s licence photos, selfie and proof of coverage (OPCF 27 or a credit card&#39;s rental coverage) are checked before the handover. You check them yourself; no task is needed.</p><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">A booking with documents waiting is a line on To do: &quot;Check &#39;s documents for booking &quot;, marked Now when the pickup is within two days. Press <b class="gd-ui">Review documents</b>.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">The pop-up shows each driver&#39;s images and the coverage: the insurer, policy number and expiry, or the card, its type and whether the name matches.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">What to check is written once at the top. One wrong? Open <b class="gd-ui">Reject this one</b> under it, type the reason the renter reads and press <b class="gd-ui">Reject</b>: they are asked for a new one.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t">Then press <b class="gd-ui">Approve all</b>: every image, the proof of coverage and the Protection Plan still waiting are approved in one step. Anything the system refuses is named with the reason.</div></li><li><span class="gd-n" aria-hidden="true">5</span><div class="gd-t">The same pop-up is on the booking: the card Renter documents (<b class="gd-ui">Review documents</b>) on Overview and on Drivers and documents.</div></li></ol></div><aside class="gd-box"><span class="gd-lbl">Tip</span><div>Each opening of a renter&#39;s documents is logged. The links to the images last one minute. Field staff can also check a licence in person at the check-out (photos and four checks): the history says &quot;checked in person&quot;. Field staff also review the licence images (not the coverage) of bookings on their own jobs in the next 7 days from My jobs, with the same Approve all or a reason to reject: the history says the reviewer&#39;s role, field. Sales review the licence images (not the coverage) of any booking being arranged or under way from their To do or the booking, with the same Approve all or a reason to reject: the history says the role, sales.</div></aside></section><section class="gd-task" id="requests-offers-and-bookings-payments-by-day" data-gd-task><h2 class="gd-h2">Payments by day</h2><p class="gd-p"><b class="gd-ui">Money</b> &gt; <b class="gd-ui">Payments by day</b>: every payment and refund of a day or a range, by method, the cash drawer and the refunds waiting. Finance has the same screen.</p><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">Choose From and To and the methods (card, e-Transfer, cash, cheque, platform payout, insurer, bank transfer, pre-authorized debit, other), then press <b class="gd-ui">Show</b>.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Totals by method and for each day; cards read as the card and its last four digits, never a code.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">The cash drawer: expected (cash in less cash given back) against the count Finance records with <b class="gd-ui">Record the count</b>; a difference shows over or short.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t">Refunds waiting: every refund asked for anywhere with the policy maths. <b class="gd-ui">Approve</b> or <b class="gd-ui">Decline</b> with the reason in the row, then <b class="gd-ui">Issue the refund</b>.</div></li><li><span class="gd-n" aria-hidden="true">5</span><div class="gd-t"><b class="gd-ui">Export CSV</b> for the bookkeeper.</div></li></ol></div></section><section class="gd-task" id="requests-offers-and-bookings-propose-a-change-to-a-confirmed-booking" data-gd-task><h2 class="gd-h2">Propose a change to a confirmed booking</h2><p class="gd-p">The renter gets an email and answers on their booking. The calendar moves only when they accept.</p><div class="gd-stepblock gd-stepblock--below"><div class="gd-stepcol"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">Open the booking&#39;s Changes tab. Under Propose a change, set the new pickup, return or car.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">To price it by hand, type a New rental charge before tax. Leave it empty to use the car&#39;s rates.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Write the Reason, for the renter. They read it.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t">Press <b class="gd-ui">Preview the price</b>, then <b class="gd-ui">Send to the renter</b>.</div></li></ol></div><figure class="gd-fig gd-fig--desk"><div class="gd-browser"><div class="gd-bar" aria-hidden="true"><i></i><i></i><i></i><span class="gd-addr">carmacars.ca/admin/bookings/CC-10065?tab=changes</span></div><div class="gd-imgwrap" style="aspect-ratio:1200/520"><img src="/guides/img/admin-05-booking-changes-desktop-97008b21.jpg" alt="" loading="lazy" decoding="async" width="1200" height="520"><span class="gd-pin" style="left:17.5%;top:33.7%" aria-hidden="true">1</span><span class="gd-pin" style="left:9.2%;top:50%" aria-hidden="true">2</span><span class="gd-pin" style="left:38.3%;top:71.2%" aria-hidden="true">3</span><span class="gd-pin" style="left:12.9%;top:91.9%" aria-hidden="true">4</span></div></div></figure></div></section><section class="gd-task" id="requests-offers-and-bookings-who-a-booking-is-credited-to" data-gd-task><h2 class="gd-h2">Who a booking is credited to</h2><p class="gd-p">Overview (and Review and offer) shows the Sales credit: the staff member the booking counts for in their sales.</p><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">A quote or a rental is credited to whoever created or added it. A request from the website is credited to whoever sent its first offer.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">To give it to someone else, press <b class="gd-ui">Reassign</b>, choose who (or Nobody), say whether they sourced the client and write the reason. The booking&#39;s history and the audit log keep it, and the deal stays in the same week and month.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Sourced means the staff member chose I sourced this client when they entered it, it came with a field staff referral link, or you credited it. Only a sourced booking earns a staff commission. A website request earns none unless you credit someone.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t">Someone said they sourced a website request? The credit line shows the claim: press <b class="gd-ui">Credit them</b> or <b class="gd-ui">Not theirs</b>, with a reason.</div></li><li><span class="gd-n" aria-hidden="true">5</span><div class="gd-t">A price typed by hand shows beside the rate-sheet price, with the reason. A price under the floor or past the discount limit is flagged: press <b class="gd-ui">Mark reviewed</b> once you have looked at it.</div></li></ol></div><aside class="gd-box"><span class="gd-lbl">Tip</span><div>The renter has 48 hours to accept (and sign the amendment) or decline, with one reminder. Any extra is charged to their Card on File; a lower price raises a refund for your approval.</div></aside></section><section class="gd-task" id="requests-offers-and-bookings-review-requests" data-gd-task><h2 class="gd-h2">Review requests</h2><p class="gd-p">Every renter is asked for a review by email and text, as they chose, only from 9 am to 9 pm Toronto time. Nothing needs setting up.</p><div class="gd-tablewrap"><table class="gd-table"><thead><tr><th scope="col">Message</th><th scope="col">When</th></tr></thead><tbody><tr><td>Mid-trip check-in</td><td>Rentals of 2 days or more, 24 hours after the pickup: &quot;How is the car? Reply or call if anything is off.&quot; No review ask.</td></tr><tr><td>Review request</td><td>1 hour after the check-in. It links the review page: the renter taps what they liked, adds a sentence, and gets a short draft to copy and post on Google.</td></tr><tr><td>Reminder</td><td>24 hours after the request.</td></tr><tr><td>Final follow-up</td><td>7 days after the request. Nothing more after it.</td></tr></tbody></table></div><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">The booking page has the card Review requests: each message with when it went or when it will go, and why it stopped.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t"><b class="gd-ui">Ask for a review</b> sends the request now (or at 9 am if it is later than 9 pm), on any booking on a trip, returned or closed. Not twice in 24 hours.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">On hold: a return or later charge (late return, kilometres, fuel, cleaning, smoking, damage, tolls and tickets) is not settled or waived, or an incident or dispute is open. The request goes by itself once they are. Press <b class="gd-ui">Send anyway</b> to send it now.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t"><b class="gd-ui">Mark reviewed</b> stops the messages when the renter tells you they already reviewed.</div></li></ol></div><p class="gd-p">The messages also stop by themselves when the renter presses &quot;I already left a review&quot;, leaves a review on the site, unsubscribes, or a Google review is matched to them. <b class="gd-ui">Bookings</b> &gt; <b class="gd-ui">Reviews</b> has the numbers (requests sent, on hold, reviews detected, the average rating), the hold list and the Google reviews to match.</p><aside class="gd-box"><span class="gd-lbl">Tip</span><div>The draft is made only from what the renter picked and wrote, and from the booking (the car, how long, delivery or pickup). Everyone gets the Google link, whatever their stars; a renter who gives 3 stars or fewer also sees &quot;Something wasn&#39;t right? Tell us directly&quot;.</div></aside></section><section class="gd-task" id="requests-offers-and-bookings-what-the-owner-sees-and-owner-deductions" data-gd-task><h2 class="gd-h2">What the owner sees, and owner deductions</h2><p class="gd-p">Each booking on an owner&#39;s or partner&#39;s car shows the card What the owner sees at the top of its page.</p><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t"><b class="gd-ui">Hide from the owner</b> keeps the booking&#39;s revenue from the owner until the car is returned, or until the owner statement covering it is approved. The owner sees the booking as Booked with its dates, and the calendar still shows the car busy. Add a reason if you like: it is kept in the history.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t"><b class="gd-ui">Show to the owner</b> shows it now. Approving the statement shows every hidden booking on it by itself.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Not shown to the owner is for a booking with no owner revenue (an insurance placeholder, a shareholder&#39;s or the owner&#39;s own use at no charge): the owner sees only that the car is unavailable for those dates. A booking with revenue cannot be set this way.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t">Add a rental and Send an offer have What the owner sees. It starts from Settings &gt; Program, Owners and fleet: Owners see a booking&#39;s revenue (right away by default).</div></li><li><span class="gd-n" aria-hidden="true">5</span><div class="gd-t">On the Money tab, Owner deductions on this booking: <b class="gd-ui">Add a booking expense</b> (cleaning, repair, fuel, platform fee or other, the amount, the reason the owner reads, a receipt number) comes off before Owner Revenue.</div></li><li><span class="gd-n" aria-hidden="true">6</span><div class="gd-t"><b class="gd-ui">Set the Revenue Share for this booking</b> applies within the car&#39;s signed terms. Above the terms only an Admin can, with Above the signed terms ticked and the reason. <b class="gd-ui">Back to the car&#39;s terms</b> undoes it.</div></li><li><span class="gd-n" aria-hidden="true">7</span><div class="gd-t">Add a rental has the same under The car&#39;s owner.</div></li></ol></div><aside class="gd-box"><span class="gd-lbl">Good to know</span><div>The owner&#39;s statement always includes every booking at its true amounts and lists each deduction with its reason, so the payout is always right. Customer service and sales add deductions only while Program settings let them change fees.</div></aside></section>');
select app.guide_release_section('va', 'your-workday', 'chapter', 'start-here', 'Every function works the same way: start on To do, take the oldest task, finish it, and check Today for pickups and returns. The menu keeps your own work first, then the screens of your function in a few groups.

## The menu

My work comes first: To do, Today at a glance, My scorecard and My sales. Customer service and Sales then have Live: Live chat, Live visitors and Game leads. Then the groups of your function. The current group is open; press another to open it. On a phone the whole menu sits behind one Menu button.

| Function | Groups and pages |
| --- | --- |
| Customer service | Bookings (Requests, Chauffeur, Send an offer, Add a rental, New quote, Calendar, Find a car), Renters (Messages, Find a renter, Review requests, Card coverage), Cars (Listings, Similar cars), Owners (Owners and enquiries, Add a car for an owner, Owner forms) |
| Sales | Bookings (Requests and offers, Chauffeur, Send an offer, Add a rental, New quote, Calendar, Find a car, Card coverage), Owners (Owner leads) |
| Finance | Money (Payments by day, Payments, deposits and refunds, Tolls and tickets, Reconciliation, Turo trips), Renters and bookings (Find a renter, Calendar), Rentals (Add a rental, New quote, Find a car, Card coverage) |
| Fleet | Field work (Field jobs, Field hours, Daily checks, Photo reviews), Cars (Listings, Similar cars, Calendar, Calendar sync, Add a car for an owner), Renters (Find a renter), Rentals (Add a rental, New quote, Find a car, Card coverage) |

## To do

Tasks come to your function on their own: new requests, renter replies, failed payments, toll notices and more. To do puts the most urgent first.

1. The top shows your function, today''s date, how many things need you, your open, overdue and done-today figures, and your quickest actions.
2. **Next up** is the one task to do now. Press its button to do it, or **Take it** to make it yours.
3. Your lanes group the work, for example Booking requests, Renter messages, Texts and calls, Live chat and Offers out. Each shows how many are waiting and how long the oldest has waited. Replies are timed against the 5-minute first reply target: past it the time turns red and says late. The most urgent lane comes first; press a lane to open it.
4. Customer service and Sales: **Waiting for a reply** lists every request, renter message, missed call and chat, the longest wait first, each with its reply button. Sales also sees the commission ring and Follow-ups due, Fleet today''s handovers, returns and moves and the cars right now, Finance Money today.
5. **Every open task**: filter All, Mine, Unassigned or Waiting. Under More filters: Any time, Overdue, Due today or Escalated, and by type. Each row has a priority, the task, its record, when it is due and a live timer of how long it has waited.
6. Press **Take it** to make it yours. Pressing the task opens the screen where it is done: a chat waiting for a person opens that chat, documents to check open the review, a request opens the booking. **Sheet** opens the step-by-step procedure.
7. Tasks close by themselves when their work is done elsewhere (an invoice paid or voided, a chat answered or closed); a day''s opening and closing checks close at the end of that day.
8. On a computer, press **/** to search (Find a renter; Sales: Find a car).

![](/guides/img/va-cs-01-queue-desktop-702d7c14.jpg "desktop; size: 1440 940; address: carmacars.ca/va; pins: 1 48.6 20.2, 2 31.9 52.1, 3 41.7 72.3")

## Work a task

Open the task. The buttons along the top move it on.

| Button | What it does |
| --- | --- |
| **Open the working screen** | Jumps to the booking, car or owner the task is about. |
| **Done** | You finished it. It leaves the queue. |
| **Waiting** | You are waiting on someone (a renter, an owner). It stays yours. |
| **Escalate** | It needs an Admin. Add why. |
| **Hand over** | Give it to someone else on the team. |
| **Add a note** | Leave a note for whoever looks next. |

> Tip: Work oldest due first. A task meets its target when it is done by its due time; that is what your scorecard counts.

## Today

1. Today lists pickups and returns, and what is due, for your function.
2. Press a booking number to open it. **To do** takes you back to your tasks.

![](/guides/img/va-cs-02-today-desktop-dfd277b7.jpg "desktop; size: 1440 700; address: carmacars.ca/va/today; pins: 1 22.9 24.6")

## Documents to sign

Your staff agreement, when CarmaCars sends it.

1. The queue shows "You have a document to sign". Press **Read and sign**.
2. Check the key values at the top (your role, hours, rate and start date), then press **Read the PDF** and read it.
3. Press **Sign**. Your full legal name is your signature (or press **Draw instead**). Several documents? One signature covers all of them. The signed copy stays on the same page.

## Several functions? Switch with Working as

If you cover more than one function, **Working as** above the menu lists them: Customer service, Finance, Fleet and Sales. Choose one; the menu, To do and Today change to that function.

## Your scorecard

1. Open **My work** > **My scorecard**.
2. By week shows each measure, its target and your result for each week.
3. A task meets its target when done by its due time. Daily checks count when done by 9:00 and 18:00.
4. The first reply target is 5 minutes: a new booking request, an enquiry, a change the renter asked for or a renter message is due 5 minutes after it comes in. An Admin sets it in Program settings, and the target column shows the one in force.

![](/guides/img/va-sales-05-scorecard-desktop-78ec1b03.jpg "desktop; size: 1440 360; address: carmacars.ca/va/scorecard; pins: 1 4.2 39.7, 2 62.5 58.3")
', 'Your workday', 'The menu, To do, task actions, Today, switching functions and your scorecard.',
  'Every function works the same way: start on To do, take the oldest task, finish it, and check Today for pickups and returns. The menu keeps your own work first, then the screens of your function in a few groups.

## The menu

My work comes first: To do, Today at a glance, My scorecard and My sales. Customer service and Sales then have Live: Live chat, Live visitors and Game leads. Then the groups of your function. The current group is open; press another to open it. On a phone the whole menu sits behind one Menu button.

| Function | Groups and pages |
| --- | --- |
| Customer service | Bookings (Requests, Chauffeur, Send an offer, Add a rental, New quote, Calendar, Find a car), Renters (Messages, Find a renter, Review requests, Card coverage), Cars (Listings, Similar cars), Owners (Owners and enquiries, Add a car for an owner, Owner forms) |
| Sales | Bookings (Requests and offers, Chauffeur, Send an offer, Add a rental, New quote, Calendar, Find a car, Card coverage), Owners (Owner leads) |
| Finance | Money (Payments by day, Payments, deposits and refunds, Tolls and tickets, Reconciliation, Turo trips), Renters and bookings (Find a renter, Calendar), Rentals (Add a rental, New quote, Find a car, Card coverage) |
| Fleet | Field work (Field jobs, Field hours, Daily checks, Photo reviews), Cars (Listings, Similar cars, Calendar, Calendar sync, Add a car for an owner), Renters (Find a renter), Rentals (Add a rental, New quote, Find a car, Card coverage) |

## To do

Tasks come to your function on their own: new requests, renter replies, failed payments, toll notices and more. To do puts the most urgent first.

1. The top shows your function, today''s date, how many things need you, your open, overdue and done-today figures, and your quickest actions.
2. **Next up** is the one task to do now. Press its button to do it, or **Take it** to make it yours.
3. Your lanes group the work, for example Booking requests, Renter messages, Texts and calls, Live chat and Offers out. Each shows how many are waiting and how long the oldest has waited. Replies are timed against the 5-minute first reply target: past it the time turns red and says late. The most urgent lane comes first; press a lane to open it.
4. Customer service and Sales: **Waiting for a reply** lists every request, renter message, missed call and chat, the longest wait first, each with its reply button. Sales also sees the commission ring and Follow-ups due, Fleet today''s handovers, returns and moves and the cars right now, Finance Money today.
5. **Every open task**: filter All, Mine, Unassigned or Waiting. Under More filters: Any time, Overdue, Due today or Escalated, and by type. Each row has a priority, the task, its record, when it is due and a live timer of how long it has waited.
6. Press **Take it** to make it yours. Pressing the task opens the screen where it is done: a chat waiting for a person opens that chat, documents to check open the review, a request opens the booking. **Sheet** opens the step-by-step procedure.
7. Tasks close by themselves when their work is done elsewhere (an invoice paid or voided, a chat answered or closed); a day''s opening and closing checks close at the end of that day.
8. On a computer, press **/** to search (Find a renter; Sales: Find a car).

![](/guides/img/va-cs-01-queue-desktop-702d7c14.jpg "desktop; size: 1440 940; address: carmacars.ca/va; pins: 1 48.6 20.2, 2 31.9 52.1, 3 41.7 72.3")

## Work a task

Open the task. The buttons along the top move it on.

| Button | What it does |
| --- | --- |
| **Open the working screen** | Jumps to the booking, car or owner the task is about. |
| **Done** | You finished it. It leaves the queue. |
| **Waiting** | You are waiting on someone (a renter, an owner). It stays yours. |
| **Escalate** | It needs an Admin. Add why. |
| **Hand over** | Give it to someone else on the team. |
| **Add a note** | Leave a note for whoever looks next. |

> Tip: Work oldest due first. A task meets its target when it is done by its due time; that is what your scorecard counts.

## Today

1. Today lists pickups and returns, and what is due, for your function.
2. Press a booking number to open it. **To do** takes you back to your tasks.

![](/guides/img/va-cs-02-today-desktop-dfd277b7.jpg "desktop; size: 1440 700; address: carmacars.ca/va/today; pins: 1 22.9 24.6")

## Documents to sign

Your staff agreement, when CarmaCars sends it.

1. The queue shows "You have a document to sign". Press **Read and sign**.
2. Check the key values at the top (your role, hours, rate and start date), then press **Read the PDF** and read it.
3. Sign in a few steps: press **Send the code** and type the 6-digit code from your phone or email, tick that you read it, draw your initials beside the key terms (confidentiality, the rules on money, keys and cars, ending the agreement), tick the two consents and draw your signature.
4. Press **Sign**. Several documents? One signature covers all of them. The signed copy, with its certificate of completion, stays on the same page.

## Several functions? Switch with Working as

If you cover more than one function, **Working as** above the menu lists them: Customer service, Finance, Fleet and Sales. Choose one; the menu, To do and Today change to that function.

## Your scorecard

1. Open **My work** > **My scorecard**.
2. By week shows each measure, its target and your result for each week.
3. A task meets its target when done by its due time. Daily checks count when done by 9:00 and 18:00.
4. The first reply target is 5 minutes: a new booking request, an enquiry, a change the renter asked for or a renter message is due 5 minutes after it comes in. An Admin sets it in Program settings, and the target column shows the one in force.

![](/guides/img/va-sales-05-scorecard-desktop-78ec1b03.jpg "desktop; size: 1440 360; address: carmacars.ca/va/scorecard; pins: 1 4.2 39.7, 2 62.5 58.3")
',
  '<p class="gd-p">Every function works the same way: start on To do, take the oldest task, finish it, and check Today for pickups and returns. The menu keeps your own work first, then the screens of your function in a few groups.</p><section class="gd-task" id="your-workday-the-menu" data-gd-task><h2 class="gd-h2">The menu</h2><p class="gd-p">My work comes first: To do, Today at a glance, My scorecard and My sales. Customer service and Sales then have Live: Live chat, Live visitors and Game leads. Then the groups of your function. The current group is open; press another to open it. On a phone the whole menu sits behind one Menu button.</p><div class="gd-tablewrap"><table class="gd-table"><thead><tr><th scope="col">Function</th><th scope="col">Groups and pages</th></tr></thead><tbody><tr><td>Customer service</td><td>Bookings (Requests, Chauffeur, Send an offer, Add a rental, New quote, Calendar, Find a car), Renters (Messages, Find a renter, Review requests, Card coverage), Cars (Listings, Similar cars), Owners (Owners and enquiries, Add a car for an owner, Owner forms)</td></tr><tr><td>Sales</td><td>Bookings (Requests and offers, Chauffeur, Send an offer, Add a rental, New quote, Calendar, Find a car, Card coverage), Owners (Owner leads)</td></tr><tr><td>Finance</td><td>Money (Payments by day, Payments, deposits and refunds, Tolls and tickets, Reconciliation, Turo trips), Renters and bookings (Find a renter, Calendar), Rentals (Add a rental, New quote, Find a car, Card coverage)</td></tr><tr><td>Fleet</td><td>Field work (Field jobs, Field hours, Daily checks, Photo reviews), Cars (Listings, Similar cars, Calendar, Calendar sync, Add a car for an owner), Renters (Find a renter), Rentals (Add a rental, New quote, Find a car, Card coverage)</td></tr></tbody></table></div></section><section class="gd-task" id="your-workday-to-do" data-gd-task><h2 class="gd-h2">To do</h2><p class="gd-p">Tasks come to your function on their own: new requests, renter replies, failed payments, toll notices and more. To do puts the most urgent first.</p><div class="gd-stepblock gd-stepblock--below"><div class="gd-stepcol"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">The top shows your function, today&#39;s date, how many things need you, your open, overdue and done-today figures, and your quickest actions.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t"><b class="gd-ui">Next up</b> is the one task to do now. Press its button to do it, or <b class="gd-ui">Take it</b> to make it yours.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Your lanes group the work, for example Booking requests, Renter messages, Texts and calls, Live chat and Offers out. Each shows how many are waiting and how long the oldest has waited. Replies are timed against the 5-minute first reply target: past it the time turns red and says late. The most urgent lane comes first; press a lane to open it.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t">Customer service and Sales: <b class="gd-ui">Waiting for a reply</b> lists every request, renter message, missed call and chat, the longest wait first, each with its reply button. Sales also sees the commission ring and Follow-ups due, Fleet today&#39;s handovers, returns and moves and the cars right now, Finance Money today.</div></li><li><span class="gd-n" aria-hidden="true">5</span><div class="gd-t"><b class="gd-ui">Every open task</b>: filter All, Mine, Unassigned or Waiting. Under More filters: Any time, Overdue, Due today or Escalated, and by type. Each row has a priority, the task, its record, when it is due and a live timer of how long it has waited.</div></li><li><span class="gd-n" aria-hidden="true">6</span><div class="gd-t">Press <b class="gd-ui">Take it</b> to make it yours. Pressing the task opens the screen where it is done: a chat waiting for a person opens that chat, documents to check open the review, a request opens the booking. <b class="gd-ui">Sheet</b> opens the step-by-step procedure.</div></li><li><span class="gd-n" aria-hidden="true">7</span><div class="gd-t">Tasks close by themselves when their work is done elsewhere (an invoice paid or voided, a chat answered or closed); a day&#39;s opening and closing checks close at the end of that day.</div></li><li><span class="gd-n" aria-hidden="true">8</span><div class="gd-t">On a computer, press <b class="gd-ui">/</b> to search (Find a renter; Sales: Find a car).</div></li></ol></div><figure class="gd-fig gd-fig--desk"><div class="gd-browser"><div class="gd-bar" aria-hidden="true"><i></i><i></i><i></i><span class="gd-addr">carmacars.ca/va</span></div><div class="gd-imgwrap" style="aspect-ratio:1440/940"><img src="/guides/img/va-cs-01-queue-desktop-702d7c14.jpg" alt="" loading="lazy" decoding="async" width="1440" height="940"><span class="gd-pin" style="left:48.6%;top:20.2%" aria-hidden="true">1</span><span class="gd-pin" style="left:31.9%;top:52.1%" aria-hidden="true">2</span><span class="gd-pin" style="left:41.7%;top:72.3%" aria-hidden="true">3</span></div></div></figure></div></section><section class="gd-task" id="your-workday-work-a-task" data-gd-task><h2 class="gd-h2">Work a task</h2><p class="gd-p">Open the task. The buttons along the top move it on.</p><div class="gd-tablewrap"><table class="gd-table"><thead><tr><th scope="col">Button</th><th scope="col">What it does</th></tr></thead><tbody><tr><td><b class="gd-ui">Open the working screen</b></td><td>Jumps to the booking, car or owner the task is about.</td></tr><tr><td><b class="gd-ui">Done</b></td><td>You finished it. It leaves the queue.</td></tr><tr><td><b class="gd-ui">Waiting</b></td><td>You are waiting on someone (a renter, an owner). It stays yours.</td></tr><tr><td><b class="gd-ui">Escalate</b></td><td>It needs an Admin. Add why.</td></tr><tr><td><b class="gd-ui">Hand over</b></td><td>Give it to someone else on the team.</td></tr><tr><td><b class="gd-ui">Add a note</b></td><td>Leave a note for whoever looks next.</td></tr></tbody></table></div><aside class="gd-box"><span class="gd-lbl">Tip</span><div>Work oldest due first. A task meets its target when it is done by its due time; that is what your scorecard counts.</div></aside></section><section class="gd-task" id="your-workday-today" data-gd-task><h2 class="gd-h2">Today</h2><div class="gd-stepblock gd-stepblock--below"><div class="gd-stepcol"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">Today lists pickups and returns, and what is due, for your function.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Press a booking number to open it. <b class="gd-ui">To do</b> takes you back to your tasks.</div></li></ol></div><figure class="gd-fig gd-fig--desk"><div class="gd-browser"><div class="gd-bar" aria-hidden="true"><i></i><i></i><i></i><span class="gd-addr">carmacars.ca/va/today</span></div><div class="gd-imgwrap" style="aspect-ratio:1440/700"><img src="/guides/img/va-cs-02-today-desktop-dfd277b7.jpg" alt="" loading="lazy" decoding="async" width="1440" height="700"><span class="gd-pin" style="left:22.9%;top:24.6%" aria-hidden="true">1</span></div></div></figure></div></section><section class="gd-task" id="your-workday-documents-to-sign" data-gd-task><h2 class="gd-h2">Documents to sign</h2><p class="gd-p">Your staff agreement, when CarmaCars sends it.</p><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">The queue shows &quot;You have a document to sign&quot;. Press <b class="gd-ui">Read and sign</b>.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Check the key values at the top (your role, hours, rate and start date), then press <b class="gd-ui">Read the PDF</b> and read it.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Sign in a few steps: press <b class="gd-ui">Send the code</b> and type the 6-digit code from your phone or email, tick that you read it, draw your initials beside the key terms (confidentiality, the rules on money, keys and cars, ending the agreement), tick the two consents and draw your signature.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t">Press <b class="gd-ui">Sign</b>. Several documents? One signature covers all of them. The signed copy, with its certificate of completion, stays on the same page.</div></li></ol></div></section><section class="gd-task" id="your-workday-several-functions-switch-with-working-as" data-gd-task><h2 class="gd-h2">Several functions? Switch with Working as</h2><p class="gd-p">If you cover more than one function, <b class="gd-ui">Working as</b> above the menu lists them: Customer service, Finance, Fleet and Sales. Choose one; the menu, To do and Today change to that function.</p></section><section class="gd-task" id="your-workday-your-scorecard" data-gd-task><h2 class="gd-h2">Your scorecard</h2><div class="gd-stepblock gd-stepblock--below"><div class="gd-stepcol"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">Open <b class="gd-ui">My work</b> &gt; <b class="gd-ui">My scorecard</b>.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">By week shows each measure, its target and your result for each week.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">A task meets its target when done by its due time. Daily checks count when done by 9:00 and 18:00.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t">The first reply target is 5 minutes: a new booking request, an enquiry, a change the renter asked for or a renter message is due 5 minutes after it comes in. An Admin sets it in Program settings, and the target column shows the one in force.</div></li></ol></div><figure class="gd-fig gd-fig--desk"><div class="gd-browser"><div class="gd-bar" aria-hidden="true"><i></i><i></i><i></i><span class="gd-addr">carmacars.ca/va/scorecard</span></div><div class="gd-imgwrap" style="aspect-ratio:1440/360"><img src="/guides/img/va-sales-05-scorecard-desktop-78ec1b03.jpg" alt="" loading="lazy" decoding="async" width="1440" height="360"><span class="gd-pin" style="left:4.2%;top:39.7%" aria-hidden="true">1</span><span class="gd-pin" style="left:62.5%;top:58.3%" aria-hidden="true">2</span></div></div></figure></div></section>');
select app.guide_release_section('field', 'my-jobs', 'chapter', 'start-here', 'Your day, in order: handovers, returns, deliveries, moves and photo shoots. Each job card has the car, the plate, the place and the time.

## Your job list

1. The menu: **My jobs**, **Report a problem**, **My hours**, **Add a rental**, **My sales**, **Referrals** and **Profile**. **Sign out** is top right.
2. Switch between **Today** and **Tomorrow**. Jobs are in time order.
3. The next job is the big card at the top: its time and how long until it, the car and its plate, the place with **Open in maps** and a button to call the renter, and what to put in the car. The rest of the day follows in time order.
4. A handover or a return has its own button: **Check out (pickup)** or **Check in (return)**. One tap acknowledges and starts the job and opens its photo checklist. Other jobs: press **Open the job**.
5. Moving a car that has no job? Use Vehicle moves (see below).

![](/guides/img/field-01-today-phone-b31e25fb.jpg "phone; size: 390 1530; pins: 1 91.0 15.0, 2 89.7 53.3, 3 89.7 61.4, 4 89.7 88.2")

> Tip: Need help on a job? Call CarmaCars at 289-312-5991. The link is at the bottom of My jobs.

## Open a job

1. The card shows the kind, the time, the car, the plate and colour.
2. The address, with **Open in maps** for directions, and a button to call the renter.
3. For a handover: the booking, the renter''s name and phone, the Card on File and the licence on file.
4. Press **Acknowledge** so the office knows you have it. Then press **Start** when you are with the car.

![](/guides/img/field-02-job-phone-c6780f54.jpg "phone; size: 390 1530; pins: 1 94.9 34.0, 2 94.9 44.1, 3 94.9 52.6, 4 94.9 95.8")

## Check the renter''s licence

The renter''s licence photos and selfie are checked before the handover. You can check them yourself, for a booking on one of your own jobs today or in the next 7 days. Everything you do is recorded with your name and "field staff".

1. My jobs shows **Licences to check** when the licence front, back or selfie of a renter on one of your jobs waits for a decision. The same check is on the job itself, under **Check the licence**.
2. Press **Review the licence**. The images open with the name, date of birth and licence details on the booking.
3. Look at each image: the name and date of birth match the booking, class G2 or G and valid past the return date with no sign of alteration, and the selfie matches the licence photo.
4. One is wrong? Open **Reject this one** under it, type the reason the renter reads and press **Reject**. The renter is told why and sends a new one.
5. Then press **Approve all**: everything still waiting is approved at once.

> Tip: The renter''s proof of coverage stays with the office. Meeting the renter at the handover? You can still check the original licence in person from the ready check (see A handover).

## Move a car

1. Under Vehicle moves, press **Start a move**. Choose the Car and Why (for example Reposition).
2. Fill in From and the Odometer (km), then press **Start the move now**.
3. When you arrive, press **End the move**, fill in Now at and the odometer, then press **End the move now**.

## Documents to sign

Your staff agreement, when CarmaCars sends it.

1. My jobs shows "You have a document to sign". Press **Read and sign**.
2. Check the key values at the top (your role, wage and start date), then press **Read the PDF** and read it.
3. Press **Sign**. Your full legal name is your signature (or press **Draw instead**).
', 'My jobs', 'Your job list, a job card, maps and car moves.',
  'Your day, in order: handovers, returns, deliveries, moves and photo shoots. Each job card has the car, the plate, the place and the time.

## Your job list

1. The menu: **My jobs**, **Report a problem**, **My hours**, **Add a rental**, **My sales**, **Referrals** and **Profile**. **Sign out** is top right.
2. Switch between **Today** and **Tomorrow**. Jobs are in time order.
3. The next job is the big card at the top: its time and how long until it, the car and its plate, the place with **Open in maps** and a button to call the renter, and what to put in the car. The rest of the day follows in time order.
4. A handover or a return has its own button: **Check out (pickup)** or **Check in (return)**. One tap acknowledges and starts the job and opens its photo checklist. Other jobs: press **Open the job**.
5. Moving a car that has no job? Use Vehicle moves (see below).

![](/guides/img/field-01-today-phone-b31e25fb.jpg "phone; size: 390 1530; pins: 1 91.0 15.0, 2 89.7 53.3, 3 89.7 61.4, 4 89.7 88.2")

> Tip: Need help on a job? Call CarmaCars at 289-312-5991. The link is at the bottom of My jobs.

## Open a job

1. The card shows the kind, the time, the car, the plate and colour.
2. The address, with **Open in maps** for directions, and a button to call the renter.
3. For a handover: the booking, the renter''s name and phone, the Card on File and the licence on file.
4. Press **Acknowledge** so the office knows you have it. Then press **Start** when you are with the car.

![](/guides/img/field-02-job-phone-c6780f54.jpg "phone; size: 390 1530; pins: 1 94.9 34.0, 2 94.9 44.1, 3 94.9 52.6, 4 94.9 95.8")

## Check the renter''s licence

The renter''s licence photos and selfie are checked before the handover. You can check them yourself, for a booking on one of your own jobs today or in the next 7 days. Everything you do is recorded with your name and "field staff".

1. My jobs shows **Licences to check** when the licence front, back or selfie of a renter on one of your jobs waits for a decision. The same check is on the job itself, under **Check the licence**.
2. Press **Review the licence**. The images open with the name, date of birth and licence details on the booking.
3. Look at each image: the name and date of birth match the booking, class G2 or G and valid past the return date with no sign of alteration, and the selfie matches the licence photo.
4. One is wrong? Open **Reject this one** under it, type the reason the renter reads and press **Reject**. The renter is told why and sends a new one.
5. Then press **Approve all**: everything still waiting is approved at once.

> Tip: The renter''s proof of coverage stays with the office. Meeting the renter at the handover? You can still check the original licence in person from the ready check (see A handover).

## Move a car

1. Under Vehicle moves, press **Start a move**. Choose the Car and Why (for example Reposition).
2. Fill in From and the Odometer (km), then press **Start the move now**.
3. When you arrive, press **End the move**, fill in Now at and the odometer, then press **End the move now**.

## Documents to sign

Your staff agreement, when CarmaCars sends it.

1. My jobs shows "You have a document to sign". Press **Read and sign**.
2. Check the key values at the top (your role, wage and start date), then press **Read the PDF** and read it.
3. Sign in a few steps: press **Send the code** and type the 6-digit code from your phone or email, tick that you read it, draw your initials beside the key terms (confidentiality, the rules on money, keys and cars, ending the agreement), tick the two consents and draw your signature.
4. Press **Sign**. The signed copy, with its certificate of completion, stays on the same page.
',
  '<p class="gd-p">Your day, in order: handovers, returns, deliveries, moves and photo shoots. Each job card has the car, the plate, the place and the time.</p><section class="gd-task" id="my-jobs-your-job-list" data-gd-task><h2 class="gd-h2">Your job list</h2><div class="gd-stepblock gd-stepblock--side"><div class="gd-stepcol"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">The menu: <b class="gd-ui">My jobs</b>, <b class="gd-ui">Report a problem</b>, <b class="gd-ui">My hours</b>, <b class="gd-ui">Add a rental</b>, <b class="gd-ui">My sales</b>, <b class="gd-ui">Referrals</b> and <b class="gd-ui">Profile</b>. <b class="gd-ui">Sign out</b> is top right.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Switch between <b class="gd-ui">Today</b> and <b class="gd-ui">Tomorrow</b>. Jobs are in time order.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">The next job is the big card at the top: its time and how long until it, the car and its plate, the place with <b class="gd-ui">Open in maps</b> and a button to call the renter, and what to put in the car. The rest of the day follows in time order.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t">A handover or a return has its own button: <b class="gd-ui">Check out (pickup)</b> or <b class="gd-ui">Check in (return)</b>. One tap acknowledges and starts the job and opens its photo checklist. Other jobs: press <b class="gd-ui">Open the job</b>.</div></li><li><span class="gd-n" aria-hidden="true">5</span><div class="gd-t">Moving a car that has no job? Use Vehicle moves (see below).</div></li></ol></div><figure class="gd-fig gd-fig--phone"><div class="gd-phone"><div class="gd-imgwrap" style="aspect-ratio:390/1530"><img src="/guides/img/field-01-today-phone-b31e25fb.jpg" alt="" loading="lazy" decoding="async" width="390" height="1530"><span class="gd-pin" style="left:91%;top:15%" aria-hidden="true">1</span><span class="gd-pin" style="left:89.7%;top:53.3%" aria-hidden="true">2</span><span class="gd-pin" style="left:89.7%;top:61.4%" aria-hidden="true">3</span><span class="gd-pin" style="left:89.7%;top:88.2%" aria-hidden="true">4</span></div></div></figure></div><aside class="gd-box"><span class="gd-lbl">Tip</span><div>Need help on a job? Call CarmaCars at 289-312-5991. The link is at the bottom of My jobs.</div></aside></section><section class="gd-task" id="my-jobs-open-a-job" data-gd-task><h2 class="gd-h2">Open a job</h2><div class="gd-stepblock gd-stepblock--side"><div class="gd-stepcol"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">The card shows the kind, the time, the car, the plate and colour.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">The address, with <b class="gd-ui">Open in maps</b> for directions, and a button to call the renter.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">For a handover: the booking, the renter&#39;s name and phone, the Card on File and the licence on file.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t">Press <b class="gd-ui">Acknowledge</b> so the office knows you have it. Then press <b class="gd-ui">Start</b> when you are with the car.</div></li></ol></div><figure class="gd-fig gd-fig--phone"><div class="gd-phone"><div class="gd-imgwrap" style="aspect-ratio:390/1530"><img src="/guides/img/field-02-job-phone-c6780f54.jpg" alt="" loading="lazy" decoding="async" width="390" height="1530"><span class="gd-pin" style="left:94.9%;top:34%" aria-hidden="true">1</span><span class="gd-pin" style="left:94.9%;top:44.1%" aria-hidden="true">2</span><span class="gd-pin" style="left:94.9%;top:52.6%" aria-hidden="true">3</span><span class="gd-pin" style="left:94.9%;top:95.8%" aria-hidden="true">4</span></div></div></figure></div></section><section class="gd-task" id="my-jobs-check-the-renter-s-licence" data-gd-task><h2 class="gd-h2">Check the renter&#39;s licence</h2><p class="gd-p">The renter&#39;s licence photos and selfie are checked before the handover. You can check them yourself, for a booking on one of your own jobs today or in the next 7 days. Everything you do is recorded with your name and &quot;field staff&quot;.</p><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">My jobs shows <b class="gd-ui">Licences to check</b> when the licence front, back or selfie of a renter on one of your jobs waits for a decision. The same check is on the job itself, under <b class="gd-ui">Check the licence</b>.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Press <b class="gd-ui">Review the licence</b>. The images open with the name, date of birth and licence details on the booking.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Look at each image: the name and date of birth match the booking, class G2 or G and valid past the return date with no sign of alteration, and the selfie matches the licence photo.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t">One is wrong? Open <b class="gd-ui">Reject this one</b> under it, type the reason the renter reads and press <b class="gd-ui">Reject</b>. The renter is told why and sends a new one.</div></li><li><span class="gd-n" aria-hidden="true">5</span><div class="gd-t">Then press <b class="gd-ui">Approve all</b>: everything still waiting is approved at once.</div></li></ol></div><aside class="gd-box"><span class="gd-lbl">Tip</span><div>The renter&#39;s proof of coverage stays with the office. Meeting the renter at the handover? You can still check the original licence in person from the ready check (see A handover).</div></aside></section><section class="gd-task" id="my-jobs-move-a-car" data-gd-task><h2 class="gd-h2">Move a car</h2><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">Under Vehicle moves, press <b class="gd-ui">Start a move</b>. Choose the Car and Why (for example Reposition).</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Fill in From and the Odometer (km), then press <b class="gd-ui">Start the move now</b>.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">When you arrive, press <b class="gd-ui">End the move</b>, fill in Now at and the odometer, then press <b class="gd-ui">End the move now</b>.</div></li></ol></div></section><section class="gd-task" id="my-jobs-documents-to-sign" data-gd-task><h2 class="gd-h2">Documents to sign</h2><p class="gd-p">Your staff agreement, when CarmaCars sends it.</p><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">My jobs shows &quot;You have a document to sign&quot;. Press <b class="gd-ui">Read and sign</b>.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Check the key values at the top (your role, wage and start date), then press <b class="gd-ui">Read the PDF</b> and read it.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Sign in a few steps: press <b class="gd-ui">Send the code</b> and type the 6-digit code from your phone or email, tick that you read it, draw your initials beside the key terms (confidentiality, the rules on money, keys and cars, ending the agreement), tick the two consents and draw your signature.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t">Press <b class="gd-ui">Sign</b>. The signed copy, with its certificate of completion, stays on the same page.</div></li></ol></div></section>');
select app.guide_release_section('investor', 'your-investments', 'chapter', 'start-here', 'Investments shows each of your investments: what you put in, what it earns, and when it pays.

## Read an investment

1. The tabs: **Investments**, **Statements**, **Documents to sign**, **Investor deck** (while CarmaCars shares it) and **Profile and notices**. **Guide** and **Sign out** are at the top.
2. Your agreement number and name, your Invested Amount, the Returns paid to date (or reinvested) and the next payment, with a chart of your account month by month.
3. Each investment: its Invested Amount, how far the lockup period has run, the Yearly Percentage, how Returns are handled (Paid monthly or Reinvested) and the Next Payment Date. Principal, what was reinvested and redeemed to date, the Investment Date and the Lockup End Date are under "Principal, dates and amounts to date".
4. Payment schedule: the last Returns on your statements and the next ones. An amount that is not on a statement yet is marked Estimated.
5. Latest statement, with **Open**.

![](/guides/img/investor-01-investments-phone-16342025.jpg "phone; size: 390 1605; pins: 1 25.6 15.3, 2 38.5 34.9, 3 51.3 72.6, 5 51.3 95.0")

> Tip: This area shows your records under your Investment Agreement. It is not an offer or a solicitation.

## Sign your investment agreement

When CarmaCars sends your agreement, it is under Documents to sign.

1. Press **Documents to sign** in the menu. The top shows what is signed ("0 of 1 signed").
2. Check the key values: your name and address, the Invested Amount, the Yearly Percentage and the dates. The agreement is filled in from your record.
3. Press **Read the PDF** and read it, with its schedules.
4. Say whether you got independent legal advice, and tick the risk acknowledgment (Schedule C). Your initials are filled in.
5. Press **Sign**. Your full legal name is your signature (or press **Draw instead**). The signed copy is on the same page.

Once you sign, the agreement shows "Awaiting countersignature by CarmaCars" under Signed. CarmaCars''s signing officer countersigns it; the agreement binds CarmaCars once it is countersigned and your funds have cleared. You get the countersigned copy on the same page.

> Tip: Signed on paper instead? Once we record it, it shows under Signed with the scan.
', 'Your investments', 'Each investment, its returns and the latest statement.',
  'Investments shows each of your investments: what you put in, what it earns, and when it pays.

## Read an investment

1. The tabs: **Investments**, **Statements**, **Documents to sign**, **Investor deck** (while CarmaCars shares it) and **Profile and notices**. **Guide** and **Sign out** are at the top.
2. Your agreement number and name, your Invested Amount, the Returns paid to date (or reinvested) and the next payment, with a chart of your account month by month.
3. Each investment: its Invested Amount, how far the lockup period has run, the Yearly Percentage, how Returns are handled (Paid monthly or Reinvested) and the Next Payment Date. Principal, what was reinvested and redeemed to date, the Investment Date and the Lockup End Date are under "Principal, dates and amounts to date".
4. Payment schedule: the last Returns on your statements and the next ones. An amount that is not on a statement yet is marked Estimated.
5. Latest statement, with **Open**.

![](/guides/img/investor-01-investments-phone-16342025.jpg "phone; size: 390 1605; pins: 1 25.6 15.3, 2 38.5 34.9, 3 51.3 72.6, 5 51.3 95.0")

> Tip: This area shows your records under your Investment Agreement. It is not an offer or a solicitation.

## Sign your investment agreement

When CarmaCars sends your agreement, it is under Documents to sign.

1. Press **Documents to sign** in the menu. The top shows what is signed ("0 of 1 signed").
2. Check the key values: your name and address, the Invested Amount, the Yearly Percentage and the dates. The agreement is filled in from your record.
3. Press **Read the PDF** and read it, with its schedules.
4. Say whether you got independent legal advice.
5. Sign in a few steps: press **Send the code** and type the 6-digit code from your phone or email, tick that you read it, draw your initials beside the risk acknowledgment (Schedule C), tick the two consents and draw your signature.
6. Press **Sign**. The signed copy, with its certificate of completion, is on the same page.

Once you sign, the agreement shows "Awaiting countersignature by CarmaCars" under Signed. CarmaCars''s signing officer countersigns it; the agreement binds CarmaCars once it is countersigned and your funds have cleared. You get the countersigned copy on the same page.

> Tip: Signed on paper instead? Once we record it, it shows under Signed with the scan.
',
  '<p class="gd-p">Investments shows each of your investments: what you put in, what it earns, and when it pays.</p><section class="gd-task" id="your-investments-read-an-investment" data-gd-task><h2 class="gd-h2">Read an investment</h2><div class="gd-stepblock gd-stepblock--side"><div class="gd-stepcol"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">The tabs: <b class="gd-ui">Investments</b>, <b class="gd-ui">Statements</b>, <b class="gd-ui">Documents to sign</b>, <b class="gd-ui">Investor deck</b> (while CarmaCars shares it) and <b class="gd-ui">Profile and notices</b>. <b class="gd-ui">Guide</b> and <b class="gd-ui">Sign out</b> are at the top.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Your agreement number and name, your Invested Amount, the Returns paid to date (or reinvested) and the next payment, with a chart of your account month by month.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Each investment: its Invested Amount, how far the lockup period has run, the Yearly Percentage, how Returns are handled (Paid monthly or Reinvested) and the Next Payment Date. Principal, what was reinvested and redeemed to date, the Investment Date and the Lockup End Date are under &quot;Principal, dates and amounts to date&quot;.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t">Payment schedule: the last Returns on your statements and the next ones. An amount that is not on a statement yet is marked Estimated.</div></li><li><span class="gd-n" aria-hidden="true">5</span><div class="gd-t">Latest statement, with <b class="gd-ui">Open</b>.</div></li></ol></div><figure class="gd-fig gd-fig--phone"><div class="gd-phone"><div class="gd-imgwrap" style="aspect-ratio:390/1605"><img src="/guides/img/investor-01-investments-phone-16342025.jpg" alt="" loading="lazy" decoding="async" width="390" height="1605"><span class="gd-pin" style="left:25.6%;top:15.3%" aria-hidden="true">1</span><span class="gd-pin" style="left:38.5%;top:34.9%" aria-hidden="true">2</span><span class="gd-pin" style="left:51.3%;top:72.6%" aria-hidden="true">3</span><span class="gd-pin" style="left:51.3%;top:95%" aria-hidden="true">5</span></div></div></figure></div><aside class="gd-box"><span class="gd-lbl">Tip</span><div>This area shows your records under your Investment Agreement. It is not an offer or a solicitation.</div></aside></section><section class="gd-task" id="your-investments-sign-your-investment-agreement" data-gd-task><h2 class="gd-h2">Sign your investment agreement</h2><p class="gd-p">When CarmaCars sends your agreement, it is under Documents to sign.</p><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">Press <b class="gd-ui">Documents to sign</b> in the menu. The top shows what is signed (&quot;0 of 1 signed&quot;).</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Check the key values: your name and address, the Invested Amount, the Yearly Percentage and the dates. The agreement is filled in from your record.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Press <b class="gd-ui">Read the PDF</b> and read it, with its schedules.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t">Say whether you got independent legal advice.</div></li><li><span class="gd-n" aria-hidden="true">5</span><div class="gd-t">Sign in a few steps: press <b class="gd-ui">Send the code</b> and type the 6-digit code from your phone or email, tick that you read it, draw your initials beside the risk acknowledgment (Schedule C), tick the two consents and draw your signature.</div></li><li><span class="gd-n" aria-hidden="true">6</span><div class="gd-t">Press <b class="gd-ui">Sign</b>. The signed copy, with its certificate of completion, is on the same page.</div></li></ol></div><p class="gd-p">Once you sign, the agreement shows &quot;Awaiting countersignature by CarmaCars&quot; under Signed. CarmaCars&#39;s signing officer countersigns it; the agreement binds CarmaCars once it is countersigned and your funds have cleared. You get the countersigned copy on the same page.</p><aside class="gd-box"><span class="gd-lbl">Tip</span><div>Signed on paper instead? Once we record it, it shows under Signed with the scan.</div></aside></section>');
-- GUIDES 0181 END
