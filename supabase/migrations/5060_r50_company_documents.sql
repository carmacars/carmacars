-- 5060 (release 50; docs/changes/2026-11-25-r50-company-documents.md): Admin > Company documents. SCHEMA_MARKER 5062.
--
-- The owner (Nov 25): "make sure the shareholder agreement is in the carmacars admin page", then: the Shareholder Agreement
-- is not signed yet, and both shareholders sign it in Admin. Nothing in Admin held the company's own corporate papers: the
-- investor library (4300) is shown to investors and Owner forms hold owners' Forms C and D. Built on what exists:
--   documents          company_documents: a title, its kind (shareholder_agreement, articles, franchise_agreement,
--                      insurance_policy, lease, other), notes, the version shown, archived or not
--   versions           company_document_versions: every version kept, never overwritten. A version is a PDF (filed, at
--                      most 20 MB, in the private documents bucket under company-documents/<document>/) or a document to
--                      sign: its Markdown body with {{placeholders}}, the fill-ins (fields, a jsonb of key and value) and
--                      the required signers (company_document_signers: an Admin each, with a role label such as
--                      "Principal of Side A, and for Holdco A"). Draft, then to_sign, then signed.
--   the text           never in the repository: the body is given at run time (Admin > Company documents, or the
--                      connector) and stored here only. The tests use dummy text.
--   signing            the platform's own e-signature (0044, 0193): when every placeholder is filled, the server renders
--                      the body as a PDF (the agreements bucket), and company_document_send opens one sign request per
--                      signer (sign_requests doc_type company_document, signature_requests, the documents row of kind
--                      company_document). Each signer signs on /admin/company-documents/<id> with the signing session of
--                      every signature (the reading, the consents, the drawn or typed signature; name, role, time, IP,
--                      device and the document's SHA-256 in signature_records), after ticking "I have read it and had
--                      the chance to get legal advice" (company_ack). Only the listed signers sign, and only Admins.
--                      Once the first signature is in, the body and the fill-ins are frozen (a trigger): a change is a
--                      new version and the signing starts again (the open requests of the older version are voided).
--   the signed copy    when everyone has signed, the server renders the body, the fill-ins and each signature block
--                      (image or typed name, date, IP, hash) into the agreements bucket (company-documents/<document>/
--                      <version>-signed.pdf) and company_document_attach_signed files it as the version's PDF.
--   notices            admin_company_document_to_sign (each signer, when a version is ready to sign) and
--                      admin_company_document_signed (each signer, with the signed copy): 5061.
--   who                Admins only. Row-level security admin_all and the audit trigger on the three tables; the documents
--                      rows of kind company_document are hidden from the VA read policy; no staff function, investor,
--                      owner or renter reads them (99_r50_company_documents.sql)
--   the door           admin_read company_documents, company_document, company_document_file, company_document_sign_facts;
--                      admin_do company_document_save, company_document_fields, company_document_send,
--                      company_document_attach_signed, company_document_archive
--   the connector      list_company_documents (admin:read); company_document_upload (title, kind, pdf_base64 or body_md,
--                      signers, fields, notes) and company_document_fields (document, fields), each previewed, then
--                      confirmed. The PDF's bytes and the body never reach the log or the preview, only their
--                      fingerprint and length.
-- The door, the connector and sign_request_sign are wrapped (_pre5060).
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

-- ================================================================ 1. tables
alter type document_kind add value if not exists 'company_document';

create table if not exists company_documents (
  id               uuid primary key default gen_random_uuid(),
  kind             text not null check (kind in ('shareholder_agreement', 'articles', 'franchise_agreement', 'insurance_policy', 'lease', 'other')),
  title            text not null check (char_length(btrim(title)) between 3 and 120),
  notes            text check (char_length(notes) <= 2000),
  current_version  integer not null default 0 check (current_version >= 0),
  archived_at      timestamptz,
  created_by       uuid references users (id) on delete set null,
  created_at       timestamptz not null default now(),
  updated_at       timestamptz not null default now()
);
create index if not exists company_documents_kind_idx on company_documents (kind, title);
create index if not exists company_documents_created_by_idx on company_documents (created_by) where created_by is not null;
comment on table company_documents is 'r50 (5060): one of CarmaCars''s own corporate documents (shareholder agreement, articles, franchise agreement, insurance policy, lease, other). Admins only; read and written through the door.';

create table if not exists company_document_versions (
  id                   uuid primary key default gen_random_uuid(),
  document_id          uuid not null references company_documents (id) on delete cascade,
  version              integer not null check (version >= 1),
  file_kind            text not null default 'pdf' check (file_kind in ('pdf', 'signable')),
  status               text not null default 'filed' check (status in ('filed', 'draft', 'to_sign', 'signed')),
  bucket               text check (bucket in ('documents', 'agreements')),
  path                 text check (path ~ '^company-documents/[0-9a-f-]{36}/[0-9a-f-]{36}(-signed)?\.pdf$'),
  size_bytes           integer check (size_bytes between 1 and 20971520),
  sha256               text check (sha256 ~ '^[0-9a-f]{64}$'),
  body_md              text check (char_length(body_md) between 1 and 200000),
  fields               jsonb not null default '{}'::jsonb check (jsonb_typeof(fields) = 'object'),
  to_sign_document_id  uuid references documents (id) on delete set null,
  to_sign_sha256       text check (to_sign_sha256 ~ '^[0-9a-f]{64}$'),
  sent_at              timestamptz,
  signed_at            timestamptz,
  signed_document_id   uuid references documents (id) on delete set null,
  note                 text check (char_length(note) <= 500),
  uploaded_by          uuid references users (id) on delete set null,
  created_at           timestamptz not null default now(),
  unique (document_id, version),
  check ((file_kind = 'pdf' and status = 'filed' and bucket = 'documents' and path is not null and size_bytes is not null and body_md is null)
      or (file_kind = 'signable' and status in ('draft', 'to_sign', 'signed') and body_md is not null
          and (status <> 'signed' or signed_at is not null) and (path is null or bucket = 'agreements')))
);
create index if not exists company_document_versions_uploaded_by_idx on company_document_versions (uploaded_by) where uploaded_by is not null;
create index if not exists company_document_versions_to_sign_idx on company_document_versions (to_sign_document_id) where to_sign_document_id is not null;
create index if not exists company_document_versions_signed_idx on company_document_versions (signed_document_id) where signed_document_id is not null;
comment on table company_document_versions is 'r50 (5060): every version of a company document, never overwritten: a PDF (documents bucket, company-documents/...) or a document to sign (body_md with {{placeholders}}, fields, signers; its signed copy in the agreements bucket). Admins only.';

create table if not exists company_document_signers (
  id               uuid primary key default gen_random_uuid(),
  version_id       uuid not null references company_document_versions (id) on delete cascade,
  user_id          uuid not null references users (id),
  role_label       text not null check (char_length(btrim(role_label)) between 2 and 160),
  sort_order       integer not null default 1,
  sign_request_id  uuid references sign_requests (id) on delete set null,
  created_at       timestamptz not null default now(),
  unique (version_id, user_id)
);
create index if not exists company_document_signers_user_idx on company_document_signers (user_id);
create index if not exists company_document_signers_request_idx on company_document_signers (sign_request_id) where sign_request_id is not null;
comment on table company_document_signers is 'r50 (5060): who signs a company document version (an Admin each), with the role printed in the signature block, and their sign request.';

create trigger company_documents_updated before update on company_documents for each row execute function app.set_updated_at();
create trigger audit_company_documents after insert or update or delete on company_documents for each row execute function app.audit_row();
-- the body and the fill-ins never reach the audit log (redact: the change is logged, not the values, as 0380)
create trigger audit_company_document_versions after insert or update or delete on company_document_versions for each row execute function app.audit_row('redact');
create trigger audit_company_document_signers after insert or update or delete on company_document_signers for each row execute function app.audit_row();

-- once the first signature is in, the body, the fill-ins and the signers of the version cannot change
create function app.company_document_frozen(p_version uuid) returns boolean
language sql stable security definer set search_path = public, app, pg_temp as $$
  select exists (select 1 from company_document_signers s join sign_requests r on r.id = s.sign_request_id
                  where s.version_id = p_version and r.status = 'signed')
$$;
create function app.company_document_versions_freeze() returns trigger
language plpgsql security definer set search_path = public, app, pg_temp as $$
begin
  if (new.body_md is distinct from old.body_md or new.fields is distinct from old.fields or new.document_id is distinct from old.document_id)
     and app.company_document_frozen(old.id) then
    raise exception 'Signing has started on this version: make a new version to change it' using errcode = '23514';
  end if;
  return new;
end $$;
create trigger company_document_versions_freeze before update on company_document_versions for each row execute function app.company_document_versions_freeze();
create function app.company_document_signers_freeze() returns trigger
language plpgsql security definer set search_path = public, app, pg_temp as $$
begin
  if tg_op = 'DELETE' then
    if app.company_document_frozen(old.version_id) then raise exception 'Signing has started on this version: make a new version to change it' using errcode = '23514'; end if;
    return old;
  end if;
  if (tg_op = 'INSERT' or new.user_id is distinct from old.user_id or new.role_label is distinct from old.role_label) and app.company_document_frozen(new.version_id) then
    raise exception 'Signing has started on this version: make a new version to change it' using errcode = '23514';
  end if;
  return new;
end $$;
create trigger company_document_signers_freeze before insert or update or delete on company_document_signers for each row execute function app.company_document_signers_freeze();

alter table company_documents enable row level security;
alter table company_document_versions enable row level security;
alter table company_document_signers enable row level security;
create policy admin_all on company_documents for all to authenticated using (app.is_admin()) with check (app.is_admin());
create policy admin_all on company_document_versions for all to authenticated using (app.is_admin()) with check (app.is_admin());
create policy admin_all on company_document_signers for all to authenticated using (app.is_admin()) with check (app.is_admin());
revoke all on company_documents, company_document_versions, company_document_signers from public, anon, authenticated;
grant select on company_documents, company_document_versions, company_document_signers to authenticated;
grant all on company_documents, company_document_versions, company_document_signers to service_role;

-- the documents rows of a company document (the PDF to sign, the signed copies) are Admins' only: the VA read policy, the
-- one policy that reads documents by exclusion, leaves them out (the others list the kinds they read)
do $$
declare q text;
begin
  select qual into q from pg_policies where schemaname = 'public' and tablename = 'documents' and policyname = 'va_read';
  if q is not null then
    execute 'drop policy va_read on documents';
    execute format('create policy va_read on documents for select to authenticated using ((%s) and kind::text <> %L)', q, 'company_document');
  end if;
end $$;

-- the sign requests of a company document: one per signer, signed in Admin
alter table sign_requests drop constraint if exists sign_requests_doc_type_check;
alter table sign_requests add constraint sign_requests_doc_type_check check (doc_type in ('form_a', 'form_b', 'form_c', 'form_d', 'investment_agreement', 'staff_agreement',
  'partner_agreement', 'referral_agreement', 'company_document'));
alter table sign_requests drop constraint if exists sign_requests_signer_role_check;
alter table sign_requests add constraint sign_requests_signer_role_check check (signer_role in ('owner_individual', 'owner_corporation', 'investor', 'staff', 'partner', 'company_signer'));
alter table signature_records drop constraint if exists signature_records_signer_role_check;
alter table signature_records add constraint signature_records_signer_role_check check (signer_role in ('renter', 'additional_driver', 'carmacars', 'owner_individual',
  'owner_corporation', 'lessor', 'investor', 'witness', 'staff', 'partner', 'company_signer'));

-- the two company document emails go to the signer on their own, never into the staff email digest (0583)
alter function app.staff_email_own(text) rename to staff_email_own_pre5060;
create function app.staff_email_own(p_code text) returns boolean
language sql immutable set search_path = public, app, pg_temp as $$
  select app.staff_email_own_pre5060(p_code) or p_code in ('admin_company_document_to_sign', 'admin_company_document_signed')
$$;
select pg_temp.copy_grants('app.staff_email_own(text)'::regprocedure, 'app.staff_email_own_pre5060(text)'::regprocedure);

insert into notification_link_paths (key, path) values ('admin_company_document', '/admin/company-documents/{{company_document_id}}'),
  ('admin_company_document_file', '/admin/company-documents/file/{{company_document_version_id}}') on conflict (key) do update set path = excluded.path;

-- ================================================================ 2. reading (Admins)
create function app.company_document_kinds() returns table (key text, label text, sort_order integer)
language sql immutable set search_path = public, app, pg_temp as $$
  values ('shareholder_agreement', 'Shareholder agreement', 10), ('articles', 'Articles of incorporation', 20),
         ('franchise_agreement', 'Franchise agreement', 30), ('insurance_policy', 'Insurance policy', 40),
         ('lease', 'Lease', 50), ('other', 'Other', 60)
$$;

-- the {{placeholders}} of a body (the renderer's own pattern, web/src/features/agreement/model.ts markdown()), in order
create function app.company_document_placeholders(p_body text) returns text[]
language sql immutable set search_path = public, app, pg_temp as $$
  select coalesce(array_agg(k order by first), '{}'::text[])
    from (select m[1] as k, min(n) as first from regexp_matches(coalesce(p_body, ''), '\{\{([A-Za-z0-9_]+)\}\}', 'g') with ordinality as x(m, n) group by m[1]) y
$$;

-- the placeholders still without a value
create function app.company_document_missing(p_body text, p_fields jsonb) returns text[]
language sql immutable set search_path = public, app, pg_temp as $$
  select coalesce(array_agg(k order by i), '{}'::text[]) from unnest(app.company_document_placeholders(p_body)) with ordinality as x(k, i)
   where nullif(btrim(coalesce(p_fields ->> k, '')), '') is null
$$;

-- what a signer signs, as a hash: the body and the fill-ins (sendForSigning renders from these and sends this back)
create function app.company_document_content_sha(p_body text, p_fields jsonb) returns text
language sql immutable set search_path = public, app, pg_temp as $$
  select encode(sha256(convert_to(coalesce(p_body, '') || chr(10) || coalesce(p_fields, '{}'::jsonb)::text, 'UTF8')), 'hex')
$$;

-- the signers of a version with their state (never the signature itself)
create function app.company_document_signers_json(p_version uuid) returns jsonb
language sql stable security definer set search_path = public, app, pg_temp as $$
  select coalesce(jsonb_agg(jsonb_build_object('user_id', s.user_id, 'name', u.full_name, 'email', u.email, 'role_label', s.role_label,
           'request_id', s.sign_request_id, 'signed', r.status = 'signed', 'signed_at', r.signed_at, 'method', r.method) order by s.sort_order, u.full_name), '[]'::jsonb)
    from company_document_signers s join users u on u.id = s.user_id left join sign_requests r on r.id = s.sign_request_id
   where s.version_id = p_version
$$;

-- one version as the list shows it (never a storage path, never the body)
create function app.company_document_version_json(v company_document_versions) returns jsonb
language sql stable security definer set search_path = public, app, pg_temp as $$
  select jsonb_build_object('id', v.id, 'version', v.version, 'file_kind', v.file_kind, 'status', v.status, 'has_file', v.path is not null,
           'size_bytes', v.size_bytes, 'note', v.note, 'created_at', v.created_at, 'sent_at', v.sent_at, 'signed_at', v.signed_at,
           'uploaded_by', (select u.full_name from users u where u.id = v.uploaded_by))
         || case when v.file_kind = 'signable' then jsonb_build_object('signers', app.company_document_signers_json(v.id),
              'placeholders', to_jsonb(app.company_document_placeholders(v.body_md)), 'missing', to_jsonb(app.company_document_missing(v.body_md, v.fields)),
              'frozen', app.company_document_frozen(v.id)) else '{}'::jsonb end
$$;

-- every kind in order, each with its documents (the latest version and the history), and the Admins who may sign
create function app.company_documents_json() returns jsonb
language sql stable security definer set search_path = public, app, pg_temp as $$
  select jsonb_build_object(
    'kinds', (select jsonb_agg(jsonb_build_object('key', k.key, 'label', k.label, 'documents', coalesce((
      select jsonb_agg(jsonb_build_object('id', d.id, 'title', d.title, 'kind', d.kind, 'notes', d.notes, 'archived', d.archived_at is not null,
               'version', d.current_version, 'updated_at', v.created_at, 'updated_on', app.local_date(v.created_at),
               'current', app.company_document_version_json(v),
               'history', (select coalesce(jsonb_agg(app.company_document_version_json(h) order by h.version desc), '[]'::jsonb)
                             from company_document_versions h where h.document_id = d.id))
             order by d.archived_at is not null, d.title)
        from company_documents d
        join company_document_versions v on v.document_id = d.id and v.version = d.current_version
       where d.kind = k.key), '[]'::jsonb)) order by k.sort_order) from app.company_document_kinds() k),
    'admins', (select coalesce(jsonb_agg(jsonb_build_object('id', u.id, 'name', u.full_name, 'email', u.email) order by u.full_name), '[]'::jsonb)
                 from users u where u.status = 'active' and app.user_is_admin(u.id)))
$$;

-- one document with its current version's body and fill-ins (the page of one document), and whether p_user signs it
create function app.company_document_json(p_user uuid, p_document uuid) returns jsonb
language plpgsql stable security definer set search_path = public, app, pg_temp as $$
declare
  d company_documents;
  v company_document_versions;
  s company_document_signers;
  r sign_requests;
begin
  perform app.assert_admin(p_user);
  select * into d from company_documents where id = p_document;
  if d.id is null then raise exception 'No such document' using errcode = 'P0002'; end if;
  select * into v from company_document_versions where document_id = d.id and version = d.current_version;
  select * into s from company_document_signers where version_id = v.id and user_id = p_user;
  select * into r from sign_requests where id = s.sign_request_id;
  return jsonb_build_object('id', d.id, 'title', d.title, 'kind', d.kind, 'kind_label', (select k.label from app.company_document_kinds() k where k.key = d.kind),
    'notes', d.notes, 'archived', d.archived_at is not null,
    'current', app.company_document_version_json(v) || jsonb_build_object('body_md', v.body_md, 'fields', v.fields),
    'history', (select coalesce(jsonb_agg(app.company_document_version_json(h) order by h.version desc), '[]'::jsonb) from company_document_versions h where h.document_id = d.id),
    'me', case when s.id is null then null else jsonb_build_object('role_label', s.role_label, 'request_id', r.id, 'status', r.status, 'sha256', r.document_sha256,
            'signer_name', r.signer_name, 'title', r.title, 'signed_at', r.signed_at) end);
end $$;

-- the bucket and path of one version's file, for the server's 5-minute signed link
create function app.company_document_file(p_user uuid, p_version uuid) returns jsonb
language plpgsql stable security definer set search_path = public, app, pg_temp as $$
declare
  v company_document_versions;
  t text;
begin
  perform app.assert_admin(p_user);
  select * into v from company_document_versions where id = p_version;
  if v.id is null or v.path is null then raise exception 'No such document' using errcode = 'P0002'; end if;
  select title into t from company_documents where id = v.document_id;
  return jsonb_build_object('bucket', v.bucket, 'path', v.path, 'title', t, 'version', v.version, 'signed', v.status = 'signed');
end $$;

-- what the server renders: the PDF to sign (before sending) and the signed copy (when everyone signed)
create function app.company_document_sign_facts(p_user uuid, p_version uuid) returns jsonb
language plpgsql stable security definer set search_path = public, app, pg_temp as $$
declare
  v company_document_versions;
  d company_documents;
begin
  perform app.assert_admin(p_user);
  select * into v from company_document_versions where id = p_version and file_kind = 'signable';
  if v.id is null then raise exception 'No such document to sign' using errcode = 'P0002'; end if;
  select * into d from company_documents where id = v.document_id;
  return jsonb_build_object('document_id', d.id, 'version_id', v.id, 'title', d.title, 'version', v.version, 'status', v.status,
    'kind_label', (select k.label from app.company_document_kinds() k where k.key = d.kind),
    'body_md', v.body_md, 'fields', v.fields, 'missing', to_jsonb(app.company_document_missing(v.body_md, v.fields)), 'to_sign_sha256', v.to_sign_sha256,
    'content_sha256', app.company_document_content_sha(v.body_md, v.fields),
    'has_signed_copy', v.path is not null,
    'signers', (select coalesce(jsonb_agg(jsonb_build_object('user_id', s.user_id, 'name', coalesce(r.signer_name, u.full_name), 'role_label', s.role_label,
                  'request_id', r.id, 'status', r.status, 'signed_at', x.signed_at, 'method', x.method, 'typed_name', x.typed_name,
                  'drawn_path', x.provider_signature, 'ip_address', host(x.ip_address), 'user_agent', x.user_agent, 'document_sha256', x.document_sha256)
                  order by s.sort_order, u.full_name), '[]'::jsonb)
                  from company_document_signers s join users u on u.id = s.user_id
                  left join sign_requests r on r.id = s.sign_request_id
                  left join signature_records x on x.id = r.signature_record_id
                 where s.version_id = v.id));
end $$;

-- ================================================================ 3. writing (Admins)
-- void the open sign requests of a version (a new version, or fill-ins changed before anyone signed)
create function app.company_document_void_requests(p_user uuid, p_version uuid, p_reason text) returns integer
language plpgsql security definer set search_path = public, app, pg_temp as $$
declare
  v_ids uuid[];
  v_srs uuid[];
begin
  -- only the requests still open: a signature already in stays linked to its signer
  with x as (
    update sign_requests r set status = 'voided', voided_at = now(), voided_by = p_user, void_reason = p_reason
     where r.status = 'sent' and r.id in (select s.sign_request_id from company_document_signers s where s.version_id = p_version and s.sign_request_id is not null)
    returning r.id, r.signature_request_id)
  select coalesce(array_agg(id), '{}'), coalesce(array_agg(signature_request_id), '{}') into v_ids, v_srs from x;
  update signature_requests set status = 'voided' where id = any (v_srs) and status in ('sent', 'partially_signed');
  update company_document_signers set sign_request_id = null where version_id = p_version and sign_request_id = any (v_ids);
  return cardinality(v_ids);
end $$;

-- the signers given as [{user_id or email, role_label or role}]: each an active Admin, once
create function app.company_document_signers_set(p_version uuid, p_signers jsonb) returns integer
language plpgsql security definer set search_path = public, app, pg_temp as $$
declare
  g jsonb;
  u users;
  n integer := 0;
  v_role text;
begin
  if jsonb_typeof(p_signers) <> 'array' or jsonb_array_length(p_signers) = 0 then raise exception 'Name who signs it: at least one Admin' using errcode = '22023'; end if;
  if jsonb_array_length(p_signers) > 10 then raise exception 'At most 10 signers' using errcode = '22023'; end if;
  delete from company_document_signers where version_id = p_version;
  for g in select value from jsonb_array_elements(p_signers) loop
    if jsonb_typeof(g) = 'string' then g := jsonb_build_object('email', g #>> '{}'); end if;
    u := null;
    if nullif(g ->> 'user_id', '') is not null then select * into u from users where id = (g ->> 'user_id')::uuid;
    else select * into u from users where lower(email) = lower(btrim(coalesce(g ->> 'email', ''))) order by created_at limit 1; end if;
    if u.id is null or u.status <> 'active' or not app.user_is_admin(u.id) then
      raise exception 'Signer %: only an active Admin signs a company document', coalesce(g ->> 'email', g ->> 'user_id', '?') using errcode = '22023';
    end if;
    v_role := coalesce(nullif(btrim(coalesce(g ->> 'role_label', g ->> 'role', '')), ''), 'Signer');
    n := n + 1;
    insert into company_document_signers (version_id, user_id, role_label, sort_order) values (p_version, u.id, left(v_role, 160), n)
    on conflict (version_id, user_id) do nothing;
  end loop;
  return n;
end $$;

-- the fill-ins given: an object of key and text (null or empty removes one)
create function app.company_document_fields_merge(p_fields jsonb, p_new jsonb) returns jsonb
language plpgsql immutable set search_path = public, app, pg_temp as $$
declare
  k text;
  v jsonb;
  out jsonb := coalesce(p_fields, '{}'::jsonb);
begin
  if p_new is null then return out; end if;
  if jsonb_typeof(p_new) <> 'object' then raise exception 'fields: an object of placeholder and value, for example {"holdco_a": "Example Holdings Inc."}' using errcode = '22023'; end if;
  for k, v in select key, value from jsonb_each(p_new) loop
    if k !~ '^[A-Za-z0-9_]{1,60}$' then raise exception 'fields: % is not a placeholder name (letters, digits and _)', k using errcode = '22023'; end if;
    if v is null or jsonb_typeof(v) = 'null' or btrim(v #>> '{}') = '' then out := out - k;
    elsif jsonb_typeof(v) in ('string', 'number') then
      if char_length(v #>> '{}') > 2000 then raise exception 'fields: % is over 2000 characters', k using errcode = '22023'; end if;
      out := out || jsonb_build_object(k, btrim(v #>> '{}'));
    else raise exception 'fields: % must be text', k using errcode = '22023';
    end if;
  end loop;
  return out;
end $$;

-- p: document (a new version of it) or kind + title (a new document); then either a PDF (path, size_bytes, sha256 from the
-- server's upload) or a document to sign (body_md, signers, fields); notes (the document's notes), note (this version).
-- A new version voids the open sign requests of the one before (the signing starts again on the new one).
create function app.company_document_save(p_user uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app, pg_temp as $$
declare
  p_ jsonb := coalesce(p, '{}'::jsonb);
  d company_documents;
  v company_document_versions;
  prev company_document_versions;
  v_kind text := nullif(btrim(p_ ->> 'kind'), '');
  v_title text := nullif(btrim(p_ ->> 'title'), '');
  v_notes text := nullif(btrim(coalesce(p_ ->> 'notes', '')), '');
  v_body text := nullif(p_ ->> 'body_md', '');
  v_signable boolean := p_ ? 'body_md';
  v_size integer;
  v_ver integer;
  v_new boolean := false;
begin
  perform app.assert_admin(p_user);
  if v_signable then
    if v_body is null or btrim(v_body) = '' then raise exception 'body_md: the text of the document' using errcode = '22023'; end if;
    if char_length(v_body) > 200000 then raise exception 'body_md: at most 200000 characters' using errcode = '22023'; end if;
  else
    if coalesce(p_ ->> 'path', '') !~ '^company-documents/[0-9a-f-]{36}/[0-9a-f-]{36}\.pdf$' then raise exception 'Upload the PDF first' using errcode = '22023'; end if;
    v_size := (p_ ->> 'size_bytes')::integer;
    if v_size is null or v_size not between 1 and 20971520 then raise exception 'The PDF must be under 20 MB' using errcode = '22023'; end if;
  end if;
  if char_length(v_notes) > 2000 then raise exception 'Keep the notes under 2000 characters' using errcode = '22023'; end if;
  if v_title is not null and char_length(v_title) not between 3 and 120 then raise exception 'Give the document a title of 3 to 120 characters' using errcode = '22023'; end if;
  if p_ ? 'document' then
    select * into d from company_documents where id = (p_ ->> 'document')::uuid for update;
    if d.id is null then raise exception 'No such document' using errcode = 'P0002'; end if;
  else
    if v_title is null then raise exception 'Give the document a title' using errcode = '22023'; end if;
    if v_kind is null or not exists (select 1 from app.company_document_kinds() k where k.key = v_kind) then
      raise exception 'Choose the kind: shareholder_agreement, articles, franchise_agreement, insurance_policy, lease or other' using errcode = '22023';
    end if;
    insert into company_documents (kind, title, notes, created_by) values (v_kind, v_title, v_notes, p_user) returning * into d;
    v_new := true;
  end if;
  -- the version before: its open signing stops (a signed one stays signed)
  select * into prev from company_document_versions where document_id = d.id and version = d.current_version;
  if prev.id is not null and prev.status = 'to_sign' then
    perform app.company_document_void_requests(p_user, prev.id, format('Replaced by version %s', prev.version + 1));
    -- it waits for nothing more: back to draft (never sent again: only the latest version is). A signature already in stays
    -- linked to its signer and frozen with the version.
    update company_document_versions set status = 'draft' where id = prev.id and status = 'to_sign';
  end if;
  v_ver := (select coalesce(max(version), 0) + 1 from company_document_versions where document_id = d.id);
  if v_signable then
    insert into company_document_versions (document_id, version, file_kind, status, body_md, fields, note, uploaded_by)
    values (d.id, v_ver, 'signable', 'draft', v_body, app.company_document_fields_merge('{}'::jsonb, p_ -> 'fields'),
            nullif(left(btrim(coalesce(p_ ->> 'note', '')), 500), ''), p_user)
    returning * into v;
    perform app.company_document_signers_set(v.id, p_ -> 'signers');
  else
    insert into company_document_versions (document_id, version, file_kind, status, bucket, path, size_bytes, sha256, note, uploaded_by)
    values (d.id, v_ver, 'pdf', 'filed', 'documents', p_ ->> 'path', v_size, nullif(p_ ->> 'sha256', ''), nullif(left(btrim(coalesce(p_ ->> 'note', '')), 500), ''), p_user)
    returning * into v;
  end if;
  update company_documents
     set current_version = v_ver, archived_at = null,
         title = case when not v_new and v_title is not null then v_title else title end,
         notes = case when not v_new and p_ ? 'notes' then v_notes else notes end
   where id = d.id returning * into d;
  return jsonb_build_object('document', d.id, 'title', d.title, 'version', v_ver, 'version_id', v.id, 'new', v_new, 'file_kind', v.file_kind, 'status', v.status,
    'missing', case when v_signable then to_jsonb(app.company_document_missing(v.body_md, v.fields)) else '[]'::jsonb end,
    'ready', v_signable and cardinality(app.company_document_missing(v.body_md, v.fields)) = 0);
end $$;

-- p: document (its current version) or version; fields (an object; null or empty removes one). Allowed until the first
-- signature; a version already sent goes back to draft (its open requests voided) and is sent again once complete.
create function app.company_document_fields(p_user uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app, pg_temp as $$
declare
  v company_document_versions;
  n integer := 0;
begin
  perform app.assert_admin(p_user);
  if p ? 'version' then select * into v from company_document_versions where id = (p ->> 'version')::uuid for update;
  else select x.* into v from company_document_versions x join company_documents d on d.id = x.document_id and x.version = d.current_version
        where d.id = nullif(p ->> 'document', '')::uuid for update of x; end if;
  if v.id is null then raise exception 'No such document' using errcode = 'P0002'; end if;
  if v.version <> (select d.current_version from company_documents d where d.id = v.document_id) then
    raise exception 'Only the latest version''s fill-ins change: version % is kept as it was', v.version using errcode = '23514';
  end if;
  if v.file_kind <> 'signable' then raise exception 'This version is a PDF: it has no fill-ins' using errcode = '22023'; end if;
  if v.status = 'signed' or app.company_document_frozen(v.id) then raise exception 'Signing has started on this version: make a new version to change it' using errcode = '23514'; end if;
  if v.status = 'to_sign' then
    n := app.company_document_void_requests(p_user, v.id, 'The fill-ins changed before anyone signed');
  end if;
  update company_document_versions set fields = app.company_document_fields_merge(fields, p -> 'fields'), status = 'draft', sent_at = null,
         to_sign_document_id = null, to_sign_sha256 = null
   where id = v.id returning * into v;
  return jsonb_build_object('document', v.document_id, 'version_id', v.id, 'version', v.version, 'status', v.status, 'fields', v.fields,
    'missing', to_jsonb(app.company_document_missing(v.body_md, v.fields)), 'ready', cardinality(app.company_document_missing(v.body_md, v.fields)) = 0, 'voided', n);
end $$;

-- p: version, path (the PDF the server rendered, in the agreements bucket), sha256, content_sha256 (of the body and fill-ins it
-- was rendered from). Every placeholder filled, every signer
-- an active Admin: one sign request per signer, and each is told (in Admin and by email).
create function app.company_document_send(p_user uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app, pg_temp as $$
declare
  v company_document_versions;
  d company_documents;
  s record;
  v_doc uuid;
  v_sr uuid;
  v_req uuid;
  v_sha text := lower(btrim(coalesce(p ->> 'sha256', '')));
  v_title text;
  v_names text;
  n integer := 0;
begin
  perform app.assert_admin(p_user);
  select * into v from company_document_versions where id = (p ->> 'version')::uuid for update;
  if v.id is null or v.file_kind <> 'signable' then raise exception 'No such document to sign' using errcode = 'P0002'; end if;
  select * into d from company_documents where id = v.document_id;
  if v.version <> d.current_version then raise exception 'Only the latest version is signed' using errcode = '23514'; end if;
  if v.status <> 'draft' then raise exception 'This version is % already', replace(v.status, '_', ' ') using errcode = '23514'; end if;
  -- the PDF was rendered from this text and these fill-ins: anything changed since (under this row's lock) is refused
  if coalesce(p ->> 'content_sha256', '') <> app.company_document_content_sha(v.body_md, v.fields) then
    raise exception 'The text or the fill-ins changed while the PDF was made: send it again' using errcode = '23514';
  end if;
  if cardinality(app.company_document_missing(v.body_md, v.fields)) > 0 then
    raise exception 'Fill in first: %', array_to_string(app.company_document_missing(v.body_md, v.fields), ', ') using errcode = '23514';
  end if;
  if coalesce(p ->> 'path', '') !~ ('^company-documents/' || d.id || '/[0-9a-f-]{36}\.pdf$') then raise exception 'Render the PDF first' using errcode = '22023'; end if;
  if v_sha !~ '^[0-9a-f]{64}$' then raise exception 'The PDF''s fingerprint is missing' using errcode = '22023'; end if;
  if not exists (select 1 from company_document_signers where version_id = v.id) then raise exception 'Name who signs it' using errcode = '23514'; end if;
  if exists (select 1 from company_document_signers x join users u on u.id = x.user_id where x.version_id = v.id and (u.status <> 'active' or not app.user_is_admin(u.id))) then
    raise exception 'Every signer must be an active Admin' using errcode = '23514';
  end if;
  v_title := format('%s, version %s', d.title, v.version);
  insert into documents (kind, title, storage_bucket, storage_path, mime_type, sha256, template_version)
  values ('company_document', v_title, 'agreements', p ->> 'path', 'application/pdf', v_sha, 'company_document:' || v.id)
  returning id into v_doc;
  select string_agg(u.full_name || ' (' || x.role_label || ')', ', ' order by x.sort_order) into v_names
    from company_document_signers x join users u on u.id = x.user_id where x.version_id = v.id;
  for s in select x.id, x.user_id, x.role_label, u.full_name, u.email from company_document_signers x join users u on u.id = x.user_id
            where x.version_id = v.id order by x.sort_order loop
    insert into signature_requests (document_id, provider, status, sent_at, created_by) values (v_doc, 'builtin', 'sent', now(), p_user) returning id into v_sr;
    insert into sign_requests (doc_type, signer_user_id, signer_name, signer_email, signer_role, title, document_id, document_sha256, template_version,
                               signature_request_id, status, extra, sent_by)
    values ('company_document', s.user_id, s.full_name, s.email, 'company_signer', v_title, v_doc, v_sha, 'company_document:' || v.id,
            v_sr, 'sent', jsonb_build_object('company_document_id', d.id, 'company_document_version_id', v.id, 'role_label', s.role_label), p_user)
    returning id into v_req;
    update company_document_signers set sign_request_id = v_req where id = s.id;
    perform app.ntf_emit('admin_company_document_to_sign', 'company_document', d.id, 'sign:' || v_req,
      jsonb_build_object('recipient_user_id', s.user_id, 'company_document_id', d.id, 'document_title', d.title, 'document_version', v.version::text,
        'signer_role_label', s.role_label, 'signers_text', v_names, '_url', app.ntf_link('admin_company_document', jsonb_build_object('company_document_id', d.id))));
    n := n + 1;
  end loop;
  update company_document_versions set status = 'to_sign', sent_at = now(), to_sign_document_id = v_doc, to_sign_sha256 = v_sha where id = v.id;
  return jsonb_build_object('document', d.id, 'version_id', v.id, 'version', v.version, 'status', 'to_sign', 'signers', n, 'admin_path', '/admin/company-documents/' || d.id);
end $$;

-- p: version, path (the signed copy the server rendered, agreements bucket), sha256, size_bytes. Once, when everyone signed:
-- the version's PDF, and each signer gets it.
create function app.company_document_attach_signed(p_user uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app, pg_temp as $$
declare
  v company_document_versions;
  d company_documents;
  v_doc uuid;
  s record;
  v_names text;
begin
  perform app.assert_admin(p_user);
  select * into v from company_document_versions where id = (p ->> 'version')::uuid for update;
  if v.id is null or v.file_kind <> 'signable' then raise exception 'No such document to sign' using errcode = 'P0002'; end if;
  if v.status <> 'signed' then raise exception 'Not everyone has signed yet' using errcode = '23514'; end if;
  if v.path is not null then return jsonb_build_object('document', v.document_id, 'version_id', v.id, 'already', true); end if;
  if coalesce(p ->> 'path', '') <> ('company-documents/' || v.document_id || '/' || v.id || '-signed.pdf') then raise exception 'Unexpected path' using errcode = '22023'; end if;
  if coalesce(p ->> 'sha256', '') !~ '^[0-9a-f]{64}$' then raise exception 'The signed copy''s fingerprint is missing' using errcode = '22023'; end if;
  select * into d from company_documents where id = v.document_id;
  insert into documents (kind, title, storage_bucket, storage_path, mime_type, sha256, template_version)
  values ('company_document', format('%s, version %s, signed', d.title, v.version), 'agreements', p ->> 'path', 'application/pdf', p ->> 'sha256', 'company_document:' || v.id)
  returning id into v_doc;
  update company_document_versions set bucket = 'agreements', path = p ->> 'path', sha256 = p ->> 'sha256', size_bytes = nullif(p ->> 'size_bytes', '')::integer,
         signed_document_id = v_doc where id = v.id;
  select string_agg(u.full_name || ' (' || x.role_label || ')', ', ' order by x.sort_order) into v_names
    from company_document_signers x join users u on u.id = x.user_id where x.version_id = v.id;
  for s in select x.user_id from company_document_signers x where x.version_id = v.id loop
    perform app.ntf_emit('admin_company_document_signed', 'company_document', d.id, 'signed:' || v.id || ':' || s.user_id,
      jsonb_build_object('recipient_user_id', s.user_id, 'company_document_id', d.id, 'document_title', d.title, 'document_version', v.version::text,
        'signed_at', app.fmt_datetime(v.signed_at), 'signers_text', v_names, 'company_document_version_id', v.id,
        '_url', app.ntf_link('admin_company_document', jsonb_build_object('company_document_id', d.id))));
  end loop;
  return jsonb_build_object('document', d.id, 'version_id', v.id, 'signed_document_id', v_doc);
end $$;

-- p: document, archived (true moves it to the archive; false brings it back). Nothing is deleted.
create function app.company_document_archive(p_user uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app, pg_temp as $$
declare d company_documents;
begin
  perform app.assert_admin(p_user);
  update company_documents set archived_at = case when coalesce((p ->> 'archived')::boolean, true) then now() end
   where id = (p ->> 'document')::uuid returning * into d;
  if d.id is null then raise exception 'No such document' using errcode = 'P0002'; end if;
  return jsonb_build_object('document', d.id, 'archived', d.archived_at is not null);
end $$;

-- ================================================================ 4. signing: the platform's own (sign_request_sign)
-- A company document is signed only by its listed signer (the request's own check), only by an Admin, only with the
-- tick "I have read it and had the chance to get legal advice" (company_ack), only while its version waits for signatures.
-- The last signature marks the version signed.
alter function app.sign_request_sign(uuid, uuid, jsonb) rename to sign_request_sign_pre5060;
create function app.sign_request_sign(p_user uuid, p_id uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app, pg_temp as $$
declare
  r sign_requests;
  v company_document_versions;
  v_out jsonb;
  v_all boolean;
begin
  select * into r from sign_requests where id = p_id;
  if r.doc_type is distinct from 'company_document' then return app.sign_request_sign_pre5060(p_user, p_id, p); end if;
  if r.signer_user_id is distinct from p_user then raise exception 'Not found' using errcode = 'P0002'; end if;
  if not app.user_is_admin(p_user) then raise exception 'Only an Admin signs a company document' using errcode = '42501'; end if;
  if coalesce((p ->> 'company_ack')::boolean, false) is not true then
    raise exception 'Tick "I have read it and had the chance to get legal advice" first' using errcode = '22023';
  end if;
  select x.* into v from company_document_versions x join company_document_signers s on s.version_id = x.id where s.sign_request_id = r.id for update of x;
  if v.id is null or v.status <> 'to_sign' then raise exception 'This document is not waiting for signatures' using errcode = '23514'; end if;
  v_out := app.sign_request_sign_pre5060(p_user, p_id, p);
  select bool_and(q.status = 'signed') into v_all from company_document_signers s join sign_requests q on q.id = s.sign_request_id where s.version_id = v.id;
  if v_all and (select count(*) from company_document_signers s where s.version_id = v.id and s.sign_request_id is null) = 0 then
    update company_document_versions set status = 'signed', signed_at = now() where id = v.id;
  end if;
  return v_out || jsonb_build_object('company_document_id', v.document_id, 'company_document_version_id', v.id, 'all_signed', coalesce(v_all, false));
end $$;
select pg_temp.copy_grants('app.sign_request_sign(uuid, uuid, jsonb)'::regprocedure, 'app.sign_request_sign_pre5060(uuid, uuid, jsonb)'::regprocedure);

-- ================================================================ 5. the door
alter function app.door(uuid, text, text, text, jsonb) rename to door_pre5060;
create function app.door(p_user uuid, p_aal text, p_call text, p_name text, p jsonb default '{}'::jsonb) returns jsonb
language plpgsql security definer set search_path = public, app, pg_temp as $$
begin
  if p_call = 'admin_read' and p_name in ('company_documents', 'company_document', 'company_document_file', 'company_document_sign_facts') then
    perform app.door_begin(p_user, p_aal);
    perform app.assert_admin(p_user);
    if p_name = 'company_document_file' then return app.company_document_file(p_user, (p ->> 'version')::uuid); end if;
    if p_name = 'company_document' then return app.company_document_json(p_user, (p ->> 'document')::uuid); end if;
    if p_name = 'company_document_sign_facts' then return app.company_document_sign_facts(p_user, (p ->> 'version')::uuid); end if;
    return app.company_documents_json();
  elsif p_call = 'admin_do' and p_name in ('company_document_save', 'company_document_fields', 'company_document_send', 'company_document_attach_signed', 'company_document_archive') then
    perform app.door_begin(p_user, p_aal);
    if p_name = 'company_document_save' then return app.company_document_save(p_user, p); end if;
    if p_name = 'company_document_fields' then return app.company_document_fields(p_user, p); end if;
    if p_name = 'company_document_send' then return app.company_document_send(p_user, p); end if;
    if p_name = 'company_document_attach_signed' then return app.company_document_attach_signed(p_user, p); end if;
    return app.company_document_archive(p_user, p);
  end if;
  return app.door_pre5060(p_user, p_aal, p_call, p_name, p);
end $$;
select pg_temp.copy_grants('app.door(uuid, text, text, text, jsonb)'::regprocedure, 'app.door_pre5060(uuid, text, text, text, jsonb)'::regprocedure);

-- ================================================================ 6. the connector
-- list_company_documents (admin:read): what admin_read company_documents gives (never a body or a path).
-- company_document_upload (admin:write): title, kind, notes and either pdf_base64 (a PDF under 15 MB) or body_md (the text to
-- sign) with signers ([{email, role}] or emails; each an active Admin) and fields (the fill-ins). A title and kind that match
-- a document already there add a version. The confirm of a PDF hands the web layer the checked arguments (run company_doc),
-- which stores the bytes and records them below; the confirm of a text saves it, and when every fill-in is there hands the
-- web layer the version to render and send (run company_doc_send).
-- company_document_fields (admin:write): document, fields; the same send when it completes them.
alter function app.api_call(text, text, jsonb, text) rename to api_call_pre5060;
create function app.api_call(p_hash text, p_tool text, p_args jsonb, p_client text default null) returns jsonb
language plpgsql security definer set search_path = public, app, pg_temp as $$
declare
  a jsonb := case when jsonb_typeof(p_args) = 'object' then p_args else '{}'::jsonb end;
  chk jsonb;
  k api_keys;
  v_args jsonb;
  v_fields jsonb := case when jsonb_typeof(p_args) = 'object' then p_args -> 'fields' end;
  v_confirm boolean;
  pv api_previews;
  v_before jsonb;
  v_target text;
  v_result jsonb;
  v_kind text;
  v_title text;
  v_label text;
  v_body boolean;
  v_r jsonb;
  d company_documents;
  cv company_document_versions;
  v_missing text[];
  g jsonb;
begin
  if p_tool not in ('list_company_documents', 'company_document_upload', 'company_document_fields') then return app.api_call_pre5060(p_hash, p_tool, p_args, p_client); end if;
  if p_tool = 'list_company_documents' then
    chk := app.api_key_check(p_hash, 'admin:read', p_tool, a, p_client);
    if not (chk ->> 'ok')::boolean then return chk; end if;
    k := jsonb_populate_record(null::api_keys, chk -> 'key');
    perform app.door_begin(k.user_id, 'aal2');
    begin
      if not app.user_is_admin(k.user_id) then raise exception 'Only an Admin reads company documents' using errcode = '42501'; end if;
      v_result := app.company_documents_json();
    exception when others then
      insert into api_calls (key_id, user_id, tool, target, args, ok, error, client) values (k.id, k.user_id, p_tool, p_tool, a, false, left(sqlerrm, 500), left(p_client, 64));
      return jsonb_build_object('ok', false, 'status', case sqlstate when 'P0002' then 404 when '42501' then 403 else 400 end, 'error', regexp_replace(sqlerrm, '^.*?ERROR:\s*', ''));
    end;
    insert into api_calls (key_id, user_id, tool, target, args, ok, client) values (k.id, k.user_id, p_tool, p_tool, a, true, left(p_client, 64));
    return jsonb_build_object('ok', true, 'result', v_result);
  end if;

  -- the writes: the bytes and the body stay out of the log and the preview; their fingerprint and length go in
  chk := app.api_key_check(p_hash, 'admin:write', p_tool, a - 'pdf_base64' - 'body_md' - 'fields', p_client);
  if not (chk ->> 'ok')::boolean then return chk; end if;
  k := jsonb_populate_record(null::api_keys, chk -> 'key');
  perform app.door_begin(k.user_id, 'aal2');
  v_confirm := coalesce((a ->> 'confirm')::boolean, false);
  -- the log and the preview keep the fill-ins' names and a hash, never their values
  v_args := a - 'confirm' - 'preview_id' - 'pdf_base64' - 'body_md' - 'fields'
            || case when a ? 'fields' then jsonb_build_object('field_keys', (select coalesce(jsonb_agg(fk order by fk), '[]'::jsonb) from jsonb_object_keys(case when jsonb_typeof(v_fields) = 'object' then v_fields else '{}'::jsonb end) fk),
                                                             'fields_sha256', encode(sha256(convert_to(coalesce(v_fields, 'null'::jsonb)::text, 'UTF8')), 'hex')) else '{}'::jsonb end
            || case when a ? 'pdf_base64' then jsonb_build_object('pdf_sha256', encode(sha256(convert_to(coalesce(a ->> 'pdf_base64', ''), 'UTF8')), 'hex'),
                                                                 'pdf_chars', length(coalesce(a ->> 'pdf_base64', ''))) else '{}'::jsonb end
            || case when a ? 'body_md' then jsonb_build_object('body_sha256', encode(sha256(convert_to(coalesce(a ->> 'body_md', ''), 'UTF8')), 'hex'),
                                                              'body_chars', length(coalesce(a ->> 'body_md', ''))) else '{}'::jsonb end;
  begin
    if not app.user_is_admin(k.user_id) then raise exception 'Only an Admin changes company documents' using errcode = '42501'; end if;
    if a ? 'fields' and jsonb_typeof(v_fields) is distinct from 'object' then raise exception 'fields: an object of placeholder and value' using errcode = '22023'; end if;
    if p_tool = 'company_document_fields' then
      select * into d from company_documents where id = nullif(v_args ->> 'document', '')::uuid;
      if d.id is null then raise exception 'document: the id from list_company_documents' using errcode = 'P0002'; end if;
      select * into cv from company_document_versions where document_id = d.id and version = d.current_version;
      if cv.file_kind <> 'signable' then raise exception 'The latest version of "%" is a PDF: it has no fill-ins', d.title using errcode = '22023'; end if;
      if not (a ? 'fields') then raise exception 'fields: an object of placeholder and value' using errcode = '22023'; end if;
      if cv.status = 'signed' or app.company_document_frozen(cv.id) then raise exception 'Signing has started on version % of "%": upload a new version to change it', cv.version, d.title using errcode = '23514'; end if;
      v_target := left(d.title, 200);
      cv.fields := app.company_document_fields_merge(cv.fields, v_fields);
      v_missing := app.company_document_missing(cv.body_md, cv.fields);
      v_before := jsonb_build_object('document', d.id, 'title', d.title, 'version', cv.version, 'status', cv.status,
                                     'placeholders', to_jsonb(app.company_document_placeholders(cv.body_md)),
                                     'filled_before', (select coalesce(jsonb_agg(fk order by fk), '[]'::jsonb) from company_document_versions x, jsonb_object_keys(x.fields) fk where x.id = cv.id));
      if not v_confirm then
        insert into api_previews (key_id, user_id, tool, args, before, after) values (k.id, k.user_id, p_tool, v_args, v_before, null) returning * into pv;
        v_result := jsonb_build_object('preview', true, 'preview_id', pv.id, 'tool', p_tool, 'expires_at', pv.created_at + interval '10 minutes', 'before', v_before,
          'after', jsonb_build_object('filled', (select coalesce(jsonb_agg(fk order by fk), '[]'::jsonb) from jsonb_object_keys(cv.fields) fk), 'missing', to_jsonb(v_missing)),
          'will_do', format('Set the fill-ins of "%s", version %s.%s', d.title, cv.version,
                            case when cardinality(v_missing) > 0 then ' Still to fill in: ' || array_to_string(v_missing, ', ') || '.'
                                 else ' Every fill-in is there: the document is rendered and each signer is asked to sign in Admin (an in-app notice and an email).' end)
                     || case when cv.status = 'to_sign' then ' The signing requests already sent are withdrawn first.' else '' end,
          'next', 'Nothing was changed. To do it, call this tool again with exactly the same arguments plus "confirm": true and "preview_id": "' || pv.id || '".');
      else
        select * into pv from api_previews where id = nullif(a ->> 'preview_id', '')::uuid for update;
        if pv.id is null or pv.key_id <> k.id or pv.tool <> p_tool then raise exception 'Preview first: call without confirm, then confirm with its preview_id' using errcode = '22023'; end if;
        if pv.used_at is not null then raise exception 'This preview was already used: preview again' using errcode = '22023'; end if;
        if pv.created_at < now() - interval '10 minutes' then raise exception 'This preview is more than 10 minutes old: preview again' using errcode = '22023'; end if;
        if pv.args is distinct from v_args then raise exception 'The arguments differ from the preview: preview again with these' using errcode = '22023'; end if;
        update api_previews set used_at = now() where id = pv.id;
        v_r := app.company_document_fields(k.user_id, jsonb_build_object('version', cv.id, 'fields', v_fields)) - 'fields';
        v_result := case when (v_r ->> 'ready')::boolean then jsonb_build_object('run', 'company_doc_send', 'actor', k.user_id, 'params', v_r)
                         else jsonb_build_object('done', true, 'tool', p_tool) || v_r || jsonb_build_object('admin_path', '/admin/company-documents/' || d.id) end;
      end if;
    else
      -- company_document_upload
      v_body := a ? 'body_md';
      if v_body = (a ? 'pdf_base64') then raise exception 'Give either pdf_base64 (a signed or finished PDF) or body_md (the text to sign), not both' using errcode = '22023'; end if;
      v_kind := nullif(btrim(coalesce(v_args ->> 'kind', '')), '');
      v_title := nullif(btrim(coalesce(v_args ->> 'title', '')), '');
      select x.label into v_label from app.company_document_kinds() x where x.key = v_kind;
      if v_label is null then raise exception 'kind: shareholder_agreement, articles, franchise_agreement, insurance_policy, lease or other' using errcode = '22023'; end if;
      if v_title is null or char_length(v_title) not between 3 and 120 then raise exception 'title: the document''s name, 3 to 120 characters' using errcode = '22023'; end if;
      if char_length(coalesce(v_args ->> 'notes', '')) > 2000 then raise exception 'notes: at most 2000 characters' using errcode = '22023'; end if;
      if v_body then
        if (v_args ->> 'body_chars')::integer = 0 or btrim(a ->> 'body_md') = '' then raise exception 'body_md: the text of the document, in Markdown' using errcode = '22023'; end if;
        if (v_args ->> 'body_chars')::integer > 200000 then raise exception 'body_md: at most 200000 characters' using errcode = '22023'; end if;
        if jsonb_typeof(v_args -> 'signers') is distinct from 'array' or jsonb_array_length(v_args -> 'signers') = 0 then
          raise exception 'signers: who signs it, [{"email": "...", "role": "..."}]; each an active Admin' using errcode = '22023';
        end if;
        for g in select value from jsonb_array_elements(v_args -> 'signers') loop
          if not exists (select 1 from users u where lower(u.email) = lower(btrim(coalesce(case when jsonb_typeof(g) = 'string' then g #>> '{}' else g ->> 'email' end, '')))
                            and u.status = 'active' and app.user_is_admin(u.id)) then
            raise exception 'signers: % is not an active Admin', coalesce(case when jsonb_typeof(g) = 'string' then g #>> '{}' else g ->> 'email' end, '?') using errcode = '22023';
          end if;
        end loop;
        v_missing := app.company_document_missing(a ->> 'body_md', app.company_document_fields_merge('{}'::jsonb, v_fields));
      else
        -- a PDF under 15 MB is at most 20971520 characters of base64 (a data: prefix allowed)
        if (v_args ->> 'pdf_chars')::integer = 0 then raise exception 'pdf_base64: the PDF, base64' using errcode = '22023'; end if;
        if (v_args ->> 'pdf_chars')::integer > 20971600 then raise exception 'pdf_base64: the PDF must be under 15 MB' using errcode = '22023'; end if;
      end if;
      v_target := left(v_title, 200);
      select * into d from company_documents x where x.kind = v_kind and lower(x.title) = lower(v_title) order by x.archived_at is not null, x.created_at desc limit 1;
      v_before := jsonb_build_object('document', d.id, 'kind', v_kind, 'kind_label', v_label, 'title', coalesce(d.title, v_title),
                                     'versions', coalesce(d.current_version, 0), 'archived', d.archived_at is not null);
      if not v_confirm then
        insert into api_previews (key_id, user_id, tool, args, before, after) values (k.id, k.user_id, p_tool, v_args, v_before, null) returning * into pv;
        v_result := jsonb_build_object('preview', true, 'preview_id', pv.id, 'tool', p_tool, 'expires_at', pv.created_at + interval '10 minutes', 'before', v_before,
          'will_do', case when d.id is null then format('Add "%s" (%s) to Admin > Company documents as a new document, version 1.', v_title, v_label)
                          else format('Save version %s of "%s" (%s) in Admin > Company documents; the earlier versions are kept.', d.current_version + 1, d.title, v_label) end
                     || case when not v_body then ' Only Admins can open it.'
                             when cardinality(v_missing) > 0 then ' It is a document to sign; still to fill in (company_document_fields): ' || array_to_string(v_missing, ', ') || '.'
                             else ' It is a document to sign: every fill-in is there, so it is rendered and each signer is asked to sign in Admin (an in-app notice and an email).' end,
          'next', 'Nothing was changed. To do it, call this tool again with exactly the same arguments plus "confirm": true and "preview_id": "' || pv.id || '".');
        if v_body then v_result := v_result || jsonb_build_object('missing', to_jsonb(v_missing)); end if;
      else
        select * into pv from api_previews where id = nullif(a ->> 'preview_id', '')::uuid for update;
        if pv.id is null or pv.key_id <> k.id or pv.tool <> p_tool then raise exception 'Preview first: call without confirm, then confirm with its preview_id' using errcode = '22023'; end if;
        if pv.used_at is not null then raise exception 'This preview was already used: preview again' using errcode = '22023'; end if;
        if pv.created_at < now() - interval '10 minutes' then raise exception 'This preview is more than 10 minutes old: preview again' using errcode = '22023'; end if;
        if pv.args is distinct from v_args then raise exception 'The arguments differ from the preview: preview again with these' using errcode = '22023'; end if;
        update api_previews set used_at = now() where id = pv.id;
        if v_body then
          v_r := app.company_document_save(k.user_id,
            case when d.id is not null then jsonb_build_object('document', d.id, 'note', v_args ->> 'notes')
                 else jsonb_build_object('kind', v_kind, 'title', v_title, 'notes', v_args ->> 'notes') end
            || jsonb_build_object('body_md', a ->> 'body_md', 'signers', v_args -> 'signers', 'fields', coalesce(v_fields, '{}'::jsonb)));
          v_result := case when (v_r ->> 'ready')::boolean then jsonb_build_object('run', 'company_doc_send', 'actor', k.user_id, 'params', v_r)
                           else jsonb_build_object('done', true, 'tool', p_tool) || v_r || jsonb_build_object('admin_path', '/admin/company-documents/' || (v_r ->> 'document')) end;
        else
          v_result := jsonb_build_object('run', 'company_doc', 'actor', k.user_id, 'params', v_args || jsonb_build_object('document_id', pv.before ->> 'document'));
        end if;
      end if;
    end if;
  exception when others then
    insert into api_calls (key_id, user_id, tool, target, args, ok, error, client) values (k.id, k.user_id, p_tool, left(coalesce(v_target, p_tool), 200), v_args, false, left(sqlerrm, 500), left(p_client, 64));
    return jsonb_build_object('ok', false, 'status', case sqlstate when 'P0002' then 404 when '42501' then 403 else 400 end, 'error', regexp_replace(sqlerrm, '^.*?ERROR:\s*', ''));
  end;
  insert into api_calls (key_id, user_id, tool, target, args, before, ok, client)
  values (k.id, k.user_id, case when v_confirm then p_tool else p_tool || ':preview' end, left(v_target, 200), v_args, v_before, true, left(p_client, 64));
  return jsonb_build_object('ok', true, 'result', v_result);
end $$;
select pg_temp.copy_grants('app.api_call(text, text, jsonb, text)'::regprocedure, 'app.api_call_pre5060(text, text, jsonb, text)'::regprocedure);

-- the web layer stored the PDF: record it (the key and the confirmed preview checked again, once)
create function app.api_company_document_record(p_hash text, p_preview uuid, p_path text, p_size integer, p_sha text, p_client text default null) returns jsonb
language plpgsql security definer set search_path = public, app, pg_temp as $$
declare
  k api_keys;
  pv api_previews;
  v_doc uuid;
  v_out jsonb;
begin
  select * into k from api_keys where key_hash = p_hash and revoked_at is null;
  select * into pv from api_previews where id = p_preview;
  if k.id is null or pv.id is null or pv.key_id <> k.id or pv.tool <> 'company_document_upload' or not (pv.args ? 'pdf_sha256') or pv.used_at is null or pv.used_at < now() - interval '5 minutes' then
    raise exception 'Not a confirmed company document upload' using errcode = '42501';
  end if;
  if exists (select 1 from api_calls x where x.key_id = k.id and x.tool = 'company_document_upload:stored' and x.target = p_preview::text) then raise exception 'Already stored' using errcode = '23505'; end if;
  perform app.door_begin(k.user_id, 'aal2');
  if coalesce(p_sha, '') !~ '^[0-9a-f]{64}$' then raise exception 'Unexpected fingerprint' using errcode = '22023'; end if;
  v_doc := nullif(pv.before ->> 'document', '')::uuid;
  v_out := app.company_document_save(k.user_id,
    case when v_doc is not null and exists (select 1 from company_documents where id = v_doc)
         then jsonb_build_object('document', v_doc, 'note', pv.args ->> 'notes')
         else jsonb_build_object('kind', pv.args ->> 'kind', 'title', pv.args ->> 'title', 'notes', pv.args ->> 'notes') end
    || jsonb_build_object('path', p_path, 'size_bytes', p_size, 'sha256', p_sha));
  insert into api_calls (key_id, user_id, tool, target, args, after, ok, client)
  values (k.id, k.user_id, 'company_document_upload:stored', p_preview::text, pv.args, v_out || jsonb_build_object('path', p_path), true, left(p_client, 64));
  return jsonb_build_object('done', true, 'tool', 'company_document_upload') || v_out || jsonb_build_object('admin_path', '/admin/company-documents/' || (v_out ->> 'document'));
end $$;
create function public.server_api_company_document_record(p_hash text, p_preview uuid, p_path text, p_size integer, p_sha text, p_client text default null) returns jsonb
language sql security definer set search_path = public, app, pg_temp as $$ select app.api_company_document_record(p_hash, p_preview, p_path, p_size, p_sha, p_client) $$;

-- ================================================================ 7. privileges: the server only
do $$
declare f record;
begin
  for f in select p.oid::regprocedure as sig from pg_proc p join pg_namespace n on n.oid = p.pronamespace
            where (n.nspname = 'app' and (p.proname like 'company\_document%' or p.proname in ('api_company_document_record', 'door_pre5060', 'api_call_pre5060', 'sign_request_sign_pre5060')))
               or (n.nspname = 'public' and p.proname = 'server_api_company_document_record') loop
    execute format('revoke all on function %s from public, anon, authenticated', f.sig);
    execute format('grant execute on function %s to service_role', f.sig);
  end loop;
end $$;
