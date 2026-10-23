-- 0127_second_rental_agreement.sql
-- The second rental agreement of every booking: Blind Spot Car Rental's own agreement (CarmaCars rents under Blind
-- Spot's insurance), filled from the booking and signed by the renter with the same signature as CarmaCars' rental
-- agreement (docs/changes/2026-10-23-second-rental-agreement.md). The owner's request of October 23, 2026: "In addition
-- to the current rental agreement, this one needs to be filled out and in there as well, in accordance to each rental.
-- The address needs to be changed ... to the mailing address we have. And the signature needs to be changed from SAM to
-- AHMAD." Blind Spot's instruction (relayed the same day): the representative's name written in a script hand, unless
-- an image of the signature is uploaded; and CarmaCars' own HST number in box 1.
--
-- 1. The template is a form of Admin > Settings > Forms of a new kind, 'booking_overlay' (Blind Spot's PDF has no
--    fillable field: the server draws each value in its box). Uploaded by an Admin into the private documents bucket
--    with its SHA-256, used for bookings once an Admin presses "Checked: use for bookings". Never in the repository.
-- 2. The company representative: the name written on the form (Ahmad) and, optionally, an image of the signature.
-- 3. A booking's second agreement (rental_agreement_companions): opened with CarmaCars' agreement, signed in the same
--    step (the renter's one signature covers both documents; each document's SHA-256 is checked), its signed copy
--    stored with the booking.
-- 4. The facts the form needs beyond the rental agreement's: the mailing address in its parts, the HST number, the car's
--    fleet number and odometer, the insurer of an insurance replacement rental.
-- 5. The renter's "Your signed rental agreement" email carries the signed second agreement.
-- 6. Admin > Today: the HST number, the template and its check, until they are done.
-- 7. The guides.

-- ================================================================ 1. the template
do $$
declare
  c record;
begin
  for c in select conname from pg_constraint where conrelid = 'pdf_templates'::regclass and contype = 'c' and pg_get_constraintdef(oid) like '%acroform%' loop
    execute format('alter table pdf_templates drop constraint %I', c.conname);
  end loop;
end $$;
alter table pdf_templates add constraint pdf_templates_kind_check check (kind in ('acroform', 'overlay', 'generated', 'booking_overlay'));
comment on column pdf_templates.kind is 'acroform: fillable fields mapped in Admin; overlay: values drawn in boxes (0047, retired); generated: made by the site; booking_overlay: a form filled per booking by the server at measured places (0127: Blind Spot''s rental agreement)';

insert into pdf_templates (form_code, version, title, kind, file_key, sha256, page_count, verified, is_current, notes)
select 'BLINDSPOT-RA', 'blindspot-0', 'Blind Spot Car Rental agreement', 'booking_overlay', null, null, 2, false, true,
       'Blind Spot Car Rental''s own rental agreement, the second agreement of every booking. Upload Blind Spot''s blank PDF (2 pages, A4), download a filled sample, then press "Checked: use for bookings".'
 where not exists (select 1 from pdf_templates where form_code = 'BLINDSPOT-RA');

-- ================================================================ 2. the company representative
create table if not exists rental_form_settings (
  form_code           text primary key,
  rep_name            text not null default 'Ahmad' check (length(btrim(rep_name)) between 1 and 60),
  rep_full_name       text,
  signature_key       text check (signature_key is null or signature_key ~ '^forms/signatures/'),
  signature_sha256    text check (signature_sha256 is null or signature_sha256 ~ '^[0-9a-f]{64}$'),
  signature_by        uuid references users (id),
  signature_at        timestamptz,
  updated_by          uuid references users (id),
  updated_at          timestamptz not null default now(),
  check ((signature_key is null) = (signature_sha256 is null))
);
comment on table rental_form_settings is 'The signature of the authorized company representative on a per-booking form (0127): the name written in a script hand, or the uploaded image of the signature when there is one';
insert into rental_form_settings (form_code, rep_name) values ('BLINDSPOT-RA', 'Ahmad') on conflict (form_code) do nothing;
alter table rental_form_settings enable row level security;
create policy admin_all on rental_form_settings for all to authenticated using (app.is_admin()) with check (app.is_admin());
revoke all on rental_form_settings from anon, authenticated;
grant select on rental_form_settings to authenticated;
grant all on rental_form_settings to service_role;
create trigger audit_rental_form_settings after insert or update or delete on rental_form_settings for each row execute function app.audit_row();

-- ================================================================ 3. a booking's second agreement
create table if not exists rental_agreement_companions (
  id                    uuid primary key default gen_random_uuid(),
  booking_id            uuid not null references bookings (id) on delete cascade,
  rental_agreement_id   uuid not null references rental_agreements (id) on delete cascade,
  form_code             text not null default 'BLINDSPOT-RA',
  template_id           uuid not null references pdf_templates (id),
  template_sha256       text not null check (template_sha256 ~ '^[0-9a-f]{64}$'),
  document_id           uuid not null references documents (id),
  document_sha256       text not null check (document_sha256 ~ '^[0-9a-f]{64}$'),
  status                text not null default 'open' check (status in ('open', 'signed', 'completed', 'superseded')),
  renter_signed_at      timestamptz,
  renter_record_id      uuid references signature_records (id),
  signed_document_id    uuid references documents (id),
  signed_sha256         text check (signed_sha256 is null or signed_sha256 ~ '^[0-9a-f]{64}$'),
  completed_at          timestamptz,
  superseded_at         timestamptz,
  created_by            uuid references users (id),
  created_at            timestamptz not null default now(),
  check (status not in ('signed', 'completed') or renter_signed_at is not null),
  check (status <> 'completed' or signed_document_id is not null),
  check (status <> 'superseded' or superseded_at is not null)
);
create unique index if not exists rental_agreement_companions_live on rental_agreement_companions (rental_agreement_id, form_code) where status <> 'superseded';
create index if not exists rental_agreement_companions_booking on rental_agreement_companions (booking_id);
comment on table rental_agreement_companions is 'The second rental agreement of a booking (0127): Blind Spot''s form filled for the booking, signed with the rental agreement''s one signature (both SHA-256 checked), and its signed copy';
alter table rental_agreement_companions enable row level security;
create policy admin_all on rental_agreement_companions for all to authenticated using (app.is_admin()) with check (app.is_admin());
create policy renter_read on rental_agreement_companions for select to authenticated using (app.is_my_booking(booking_id));
revoke all on rental_agreement_companions from anon, authenticated;
grant select on rental_agreement_companions to authenticated;
grant all on rental_agreement_companions to service_role;
create trigger audit_rental_agreement_companions after insert or update or delete on rental_agreement_companions for each row execute function app.audit_row();

-- The template in use for bookings: the current version of the form, checked, with its file.
create or replace function app.blindspot_template() returns pdf_templates
language sql stable security definer set search_path = public, app as $$
  select t.* from pdf_templates t where t.form_code = 'BLINDSPOT-RA' and t.is_current and t.verified and t.file_key is not null and t.sha256 is not null limit 1
$$;

-- ================================================================ 4. the facts of the form
-- What Blind Spot's form needs beyond the rental agreement's facts (public.server_agreement_facts): the mailing address
-- in its parts, CarmaCars' HST number, the car's fleet number and odometer, the 3+ day rate, the insurer of an insurance
-- replacement rental, the template and the company representative.
create or replace function app.blindspot_extra(p_booking uuid) returns jsonb
language plpgsql stable security definer set search_path = public, app as $$
declare
  b bookings;
  v_mail text := (select nullif(btrim(s.mailing_address), '') from site_settings s where s.singleton limit 1);
  m jsonb;
  t pdf_templates := app.blindspot_template();
  r rental_form_settings;
begin
  select * into b from bookings where id = p_booking;
  if b.id is null then raise exception 'Booking % not found', p_booking using errcode = 'P0002'; end if;
  m := app.split_ca_address(v_mail);
  select * into r from rental_form_settings where form_code = 'BLINDSPOT-RA';
  return jsonb_build_object(
    'mailing', jsonb_build_object('line', v_mail, 'street', m ->> 'address_line1', 'unit', m ->> 'unit', 'city', m ->> 'city',
                                  'province', m ->> 'province', 'postal_code', m ->> 'postal_code'),
    'hst_number', nullif(btrim(coalesce((app.settings()).company_hst_number, '')), ''),
    'fleet_number', (select nullif(btrim(v.fleet_number), '') from vehicles v where v.id = b.vehicle_id),
    'odometer_out_km', b.odometer_out_km,
    'multi_day_rate_cents', b.multi_day_rate_cents,
    'insurer', case when b.bill_to <> 'renter' and b.insurer_id is not null then
      (select jsonb_build_object('name', i.name, 'claim_number', nullif(btrim(b.insurer_claim_number), ''), 'adjuster_name', nullif(btrim(b.insurer_adjuster_name), ''),
                                 'adjuster_phone', nullif(btrim(b.insurer_adjuster_phone), ''), 'authorized_days', b.insurer_authorized_days,
                                 'authorized_daily_rate_cents', b.insurer_authorized_daily_rate_cents)
         from insurers i where i.id = b.insurer_id) end,
    'template', case when t.id is not null then jsonb_build_object('id', t.id, 'version', t.version, 'file_key', t.file_key, 'sha256', t.sha256) end,
    'rep', jsonb_build_object('name', coalesce(r.rep_name, 'Ahmad'), 'full_name', r.rep_full_name, 'signature_key', r.signature_key, 'signature_sha256', r.signature_sha256));
end $$;

create or replace function public.server_blindspot_facts(p_booking uuid, p_by uuid) returns jsonb
language plpgsql stable security definer set search_path = public, app as $$
begin
  if p_by is null or not (coalesce(app.is_booking_renter(p_booking, p_by), false) or app.user_is_staff(p_by)) then
    raise exception 'Only the renter of this booking, or staff, reads its agreement' using errcode = '42501';
  end if;
  return app.blindspot_extra(p_booking);
end $$;

-- The second agreement of the booking's agreement (open, signed or completed), with its documents.
create or replace function public.server_agreement_companion(p_booking uuid) returns jsonb
language sql stable security definer set search_path = public, app as $$
  select jsonb_build_object('id', c.id, 'status', c.status, 'document_id', c.document_id, 'document_sha256', c.document_sha256,
           'signed_document_id', c.signed_document_id, 'template_id', c.template_id, 'template_sha256', c.template_sha256,
           'renter_signed_at', c.renter_signed_at, 'agreement_number', a.agreement_number, 'agreement_status', a.status,
           'document', (select jsonb_build_object('bucket', d.storage_bucket, 'path', d.storage_path) from documents d where d.id = c.document_id),
           'renter_record', (select jsonb_build_object('signer_name', s.signer_name, 'method', s.method, 'signed_at', s.signed_at, 'ip_address', host(s.ip_address),
                                                       'user_agent', s.user_agent, 'provider_signature', s.provider_signature, 'typed_name', s.typed_name)
                               from signature_records s where s.id = c.renter_record_id))
    from rental_agreements a join rental_agreement_companions c on c.rental_agreement_id = a.id and c.status <> 'superseded'
   where a.booking_id = p_booking and a.status in ('open', 'signed', 'completed')
   order by a.opened_at desc limit 1
$$;

-- The second agreement rendered for the open agreement (the file is stored by the server). The same document returns
-- the same row; a changed one (the renter's details, a new template or signature) replaces it while unsigned.
create or replace function public.server_open_agreement_companion(p_booking uuid, p_by uuid, p_template uuid, p_storage_path text, p_sha256 text) returns uuid
language plpgsql security definer set search_path = public, app as $$
declare
  a rental_agreements;
  b bookings;
  t pdf_templates := app.blindspot_template();
  c rental_agreement_companions;
  v_sha text := lower(btrim(coalesce(p_sha256, '')));
  v_doc uuid;
  v_id uuid;
begin
  if p_by is null or not (coalesce(app.is_booking_renter(p_booking, p_by), false) or app.user_is_staff(p_by)) then
    raise exception 'Only the renter of this booking, or staff, opens its agreement' using errcode = '42501';
  end if;
  if t.id is null or t.id is distinct from p_template then
    raise exception 'The Blind Spot agreement is not in use for bookings (Admin > Settings > Forms)' using errcode = '23514';
  end if;
  if v_sha !~ '^[0-9a-f]{64}$' or nullif(btrim(coalesce(p_storage_path, '')), '') is null or p_storage_path !~ ('^bookings/' || p_booking || '/') then
    raise exception 'The second agreement needs its file and the SHA-256 of the rendered document' using errcode = '22023';
  end if;
  select * into b from bookings where id = p_booking;
  select * into a from rental_agreements where booking_id = p_booking and status in ('open', 'signed', 'completed') order by opened_at desc limit 1 for update;
  if a.id is null then raise exception 'Booking % has no rental agreement open', b.booking_number using errcode = '23514'; end if;
  select * into c from rental_agreement_companions where rental_agreement_id = a.id and form_code = 'BLINDSPOT-RA' and status <> 'superseded';
  if c.id is not null and (c.status <> 'open' or (c.document_sha256 = v_sha and c.template_id = t.id)) then return c.id; end if;
  if a.status <> 'open' then return null; end if; -- signed without it (before it was in use): nothing to add afterwards
  if c.id is not null then update rental_agreement_companions set status = 'superseded', superseded_at = now() where id = c.id; end if;
  insert into documents (kind, title, storage_bucket, storage_path, mime_type, sha256, template_version, retention, uploaded_by, renter_id, booking_id)
  values ('rental_agreement', format('Blind Spot rental agreement %s', b.booking_number), 'agreements', p_storage_path, 'application/pdf', v_sha,
          t.version, 'records_7y', p_by, b.renter_id, p_booking)
  returning id into v_doc;
  insert into rental_agreement_companions (booking_id, rental_agreement_id, template_id, template_sha256, document_id, document_sha256, created_by)
  values (p_booking, a.id, t.id, t.sha256, v_doc, v_sha, p_by)
  returning id into v_id;
  return v_id;
end $$;

-- The renter signs: the one signature covers both documents. The second agreement's SHA-256 is checked first (a page
-- opened before it changed is refused, nothing is signed), then the rental agreement is signed as before
-- (app.renter_sign_agreement_pre0127), then the second agreement records the same signature.
alter function public.renter_sign_agreement(uuid, uuid, text, text, jsonb, text, text, inet, text) rename to renter_sign_agreement_pre0127;
alter function public.renter_sign_agreement_pre0127(uuid, uuid, text, text, jsonb, text, text, inet, text) set schema app;
create or replace function public.renter_sign_agreement(p_booking uuid, p_by uuid, p_consent_text text, p_document_sha256 text, p_consents jsonb,
                                                        p_typed_name text default null, p_drawn_signature text default null,
                                                        p_ip inet default null, p_user_agent text default null,
                                                        p_companion_sha256 text default null) returns uuid
language plpgsql security definer set search_path = public, app as $$
declare
  a rental_agreements;
  c rental_agreement_companions;
  v_id uuid;
  v_rec uuid;
begin
  select * into a from rental_agreements where booking_id = p_booking and status = 'open' order by opened_at desc limit 1;
  if a.id is not null then
    select * into c from rental_agreement_companions where rental_agreement_id = a.id and status = 'open' for update;
    if c.id is not null and lower(btrim(coalesce(p_companion_sha256, ''))) is distinct from c.document_sha256 then
      raise exception 'The Blind Spot rental agreement changed since this page was opened. Reload the page and sign again' using errcode = '40001';
    end if;
  end if;
  v_id := app.renter_sign_agreement_pre0127(p_booking, p_by, p_consent_text, p_document_sha256, p_consents, p_typed_name, p_drawn_signature, p_ip, p_user_agent);
  if c.id is not null then
    select s.id into v_rec from rental_agreements x join signature_records s on s.signature_request_id = x.signature_request_id
     where x.id = a.id and s.signer_role = 'renter' and s.status = 'signed' order by s.signed_at desc limit 1;
    update rental_agreement_companions set status = 'signed', renter_signed_at = now(), renter_record_id = v_rec where id = c.id;
  end if;
  return v_id;
end $$;

-- The signed copy of the second agreement (rendered by the server once the rental agreement is completed). Stored once.
create or replace function public.server_attach_companion_signed(p_companion uuid, p_storage_path text, p_sha256 text) returns uuid
language plpgsql security definer set search_path = public, app as $$
declare
  c rental_agreement_companions;
  b bookings;
  v_doc uuid;
begin
  select * into c from rental_agreement_companions where id = p_companion for update;
  if c.id is null then raise exception 'That second agreement is not there' using errcode = 'P0002'; end if;
  if c.status = 'completed' then return c.signed_document_id; end if;
  if c.status <> 'signed' then raise exception 'The second agreement is stored signed once the renter has signed it' using errcode = '23514'; end if;
  if not exists (select 1 from rental_agreements a where a.id = c.rental_agreement_id and a.status = 'completed') then
    raise exception 'The second agreement is stored signed once the rental agreement is countersigned' using errcode = '23514';
  end if;
  if nullif(btrim(coalesce(p_storage_path, '')), '') is null or lower(btrim(coalesce(p_sha256, ''))) !~ '^[0-9a-f]{64}$' then
    raise exception 'The signed copy needs its file and its SHA-256' using errcode = '22023';
  end if;
  select * into b from bookings where id = c.booking_id;
  insert into documents (kind, title, storage_bucket, storage_path, mime_type, sha256, template_version, retention, renter_id, booking_id)
  values ('rental_agreement', format('Blind Spot rental agreement %s, signed', b.booking_number), 'agreements', p_storage_path, 'application/pdf',
          lower(btrim(p_sha256)), (select t.version from pdf_templates t where t.id = c.template_id), 'records_7y', b.renter_id, b.id)
  returning id into v_doc;
  update rental_agreement_companions set status = 'completed', completed_at = now(), signed_document_id = v_doc, signed_sha256 = lower(btrim(p_sha256)) where id = c.id;
  return v_doc;
end $$;

-- ================================================================ Admin > Settings > Forms: the per-booking forms
create or replace function app.rental_forms_state() returns jsonb
language sql stable security definer set search_path = public, app as $$
  select coalesce(jsonb_agg(jsonb_build_object(
           'form_code', c.form_code,
           'current', (select jsonb_build_object('id', t.id, 'version', t.version, 'title', t.title, 'notes', t.notes, 'file_name', t.file_name,
                                                 'has_file', t.file_key is not null, 'sha256', t.sha256, 'page_count', t.page_count, 'verified', t.verified,
                                                 'verified_at', t.verified_at, 'verified_by_name', (select u.full_name from users u where u.id = t.verified_by),
                                                 'uploaded_at', case when t.file_key is not null then t.created_at end,
                                                 'uploaded_by_name', (select u.full_name from users u where u.id = t.uploaded_by))
                         from pdf_templates t where t.form_code = c.form_code and t.is_current),
           'versions', (select count(*) from pdf_templates t where t.form_code = c.form_code and t.file_key is not null),
           'rep', (select jsonb_build_object('name', r.rep_name, 'full_name', r.rep_full_name, 'has_signature', r.signature_key is not null,
                                             'signature_at', r.signature_at, 'signature_by_name', (select u.full_name from users u where u.id = r.signature_by))
                     from rental_form_settings r where r.form_code = c.form_code),
           'bookings', (select jsonb_build_object('open', count(*) filter (where x.status = 'open'), 'signed', count(*) filter (where x.status in ('signed', 'completed')))
                          from rental_agreement_companions x where x.form_code = c.form_code),
           'mailing_address', (select nullif(btrim(s.mailing_address), '') from site_settings s where s.singleton limit 1),
           'hst_number', nullif(btrim(coalesce((app.settings()).company_hst_number, '')), '')) order by c.form_code), '[]'::jsonb)
    from (select distinct form_code from pdf_templates where kind = 'booking_overlay') c
$$;

alter function app.form_templates(uuid) rename to form_templates_pre0127;
create or replace function app.form_templates(p_by uuid) returns jsonb
language plpgsql stable security definer set search_path = public, app as $$
declare
  v jsonb := app.form_templates_pre0127(p_by);
begin
  -- the registry forms' list keeps the forms mapped field by field; the per-booking forms have their own card
  return jsonb_set(v, '{forms}', coalesce((select jsonb_agg(f) from jsonb_array_elements(v -> 'forms') f
                                             where not exists (select 1 from pdf_templates t where t.form_code = f ->> 'form_code' and t.kind = 'booking_overlay')), '[]'::jsonb))
         || jsonb_build_object('rental_forms', app.rental_forms_state());
end $$;

create or replace function app.rental_form_upload(p_by uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  cur pdf_templates;
  v_id uuid;
  v_sha text := lower(btrim(coalesce(p ->> 'sha256', '')));
begin
  perform app.assert_admin(p_by);
  select * into cur from pdf_templates where form_code = p ->> 'form_code' and kind = 'booking_overlay' and is_current for update;
  if cur.id is null then raise exception 'Unknown form' using errcode = 'P0002'; end if;
  if coalesce(p ->> 'file_key', '') !~ ('^forms/templates/' || cur.form_code || '/') then raise exception 'Unknown file' using errcode = '22023'; end if;
  if v_sha !~ '^[0-9a-f]{64}$' then raise exception 'The file needs its SHA-256' using errcode = '22023'; end if;
  if cur.sha256 = v_sha then return jsonb_build_object('id', cur.id, 'same', true); end if;
  update pdf_templates set is_current = false where id = cur.id;
  insert into pdf_templates (form_code, version, title, kind, file_key, sha256, page_count, field_map, verified, is_current, notes, uploaded_by, file_name)
  values (cur.form_code, 'blindspot-' || to_char(now() at time zone 'America/Toronto', 'YYYYMMDD') || '-' || ((select count(*) from pdf_templates x where x.form_code = cur.form_code) + 1),
          cur.title, 'booking_overlay', p ->> 'file_key', v_sha, nullif(p ->> 'page_count', '')::integer, '{}'::jsonb, false, true, cur.notes, p_by, left(p ->> 'file_name', 200))
  returning id into v_id;
  return jsonb_build_object('id', v_id, 'same', false);
end $$;

create or replace function app.rental_form_check(p_by uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  t pdf_templates;
  v_on boolean := coalesce((p ->> 'checked')::boolean, true);
begin
  perform app.assert_admin(p_by);
  select * into t from pdf_templates where id = (p ->> 'template')::uuid and kind = 'booking_overlay' for update;
  if t.id is null then raise exception 'That template is not there' using errcode = 'P0002'; end if;
  if not t.is_current then raise exception 'Only the current version of a form is checked' using errcode = '23514'; end if;
  if v_on and t.file_key is null then raise exception 'Upload the PDF first' using errcode = '23514'; end if;
  update pdf_templates set verified = v_on, verified_by = case when v_on then p_by end, verified_at = case when v_on then now() end where id = t.id;
  return jsonb_build_object('id', t.id, 'verified', v_on);
end $$;

create or replace function app.rental_form_rep(p_by uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  r rental_form_settings;
  v_key text := nullif(btrim(coalesce(p ->> 'signature_key', '')), '');
begin
  perform app.assert_admin(p_by);
  select * into r from rental_form_settings where form_code = p ->> 'form_code' for update;
  if r.form_code is null then raise exception 'Unknown form' using errcode = 'P0002'; end if;
  if p ? 'rep_name' then
    if length(btrim(coalesce(p ->> 'rep_name', ''))) not between 1 and 60 then raise exception 'Write the name signed on the form' using errcode = '22023'; end if;
    if btrim(p ->> 'rep_name') !~ '^[A-Za-z][A-Za-z .''-]*$' then raise exception 'The name is written with letters, spaces, hyphens and apostrophes only' using errcode = '22023'; end if;
    update rental_form_settings set rep_name = btrim(p ->> 'rep_name') where form_code = r.form_code;
  end if;
  if p ? 'rep_full_name' then update rental_form_settings set rep_full_name = nullif(btrim(p ->> 'rep_full_name'), '') where form_code = r.form_code; end if;
  if v_key is not null then
    if v_key !~ ('^forms/signatures/' || r.form_code || '/') or lower(coalesce(p ->> 'signature_sha256', '')) !~ '^[0-9a-f]{64}$' then
      raise exception 'Unknown file' using errcode = '22023';
    end if;
    update rental_form_settings set signature_key = v_key, signature_sha256 = lower(p ->> 'signature_sha256'), signature_by = p_by, signature_at = now() where form_code = r.form_code;
  elsif coalesce((p ->> 'clear_signature')::boolean, false) then
    update rental_form_settings set signature_key = null, signature_sha256 = null, signature_by = p_by, signature_at = now() where form_code = r.form_code;
  end if;
  update rental_form_settings set updated_by = p_by, updated_at = now() where form_code = r.form_code;
  return (select jsonb_build_object('name', x.rep_name, 'full_name', x.rep_full_name, 'has_signature', x.signature_key is not null) from rental_form_settings x where x.form_code = r.form_code);
end $$;

-- The Admin's sample: the template file, the representative's signature and what the settings give the form.
create or replace function app.rental_form_preview(p_by uuid, p jsonb) returns jsonb
language plpgsql stable security definer set search_path = public, app as $$
declare
  t pdf_templates;
  r rental_form_settings;
  v_mail text := (select nullif(btrim(s.mailing_address), '') from site_settings s where s.singleton limit 1);
  m jsonb := app.split_ca_address((select nullif(btrim(s.mailing_address), '') from site_settings s where s.singleton limit 1));
begin
  perform app.assert_admin(p_by);
  select * into t from pdf_templates where id = (p ->> 'template')::uuid and kind = 'booking_overlay';
  if t.id is null or t.file_key is null then raise exception 'That template has no file' using errcode = 'P0002'; end if;
  select * into r from rental_form_settings where form_code = t.form_code;
  return jsonb_build_object('file_key', t.file_key, 'sha256', t.sha256, 'form_code', t.form_code, 'version', t.version,
    'mailing', jsonb_build_object('line', v_mail, 'street', m ->> 'address_line1', 'unit', m ->> 'unit', 'city', m ->> 'city', 'province', m ->> 'province', 'postal_code', m ->> 'postal_code'),
    'hst_number', nullif(btrim(coalesce((app.settings()).company_hst_number, '')), ''),
    'rep', jsonb_build_object('name', r.rep_name, 'signature_key', r.signature_key));
end $$;

create or replace function app.ops0127(p_user uuid, p_call text, p_name text, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
begin
  case p_name
  when 'rental_form_preview' then return app.rental_form_preview(p_user, p);
  when 'rental_form_upload' then return app.rental_form_upload(p_user, p);
  when 'rental_form_check' then return app.rental_form_check(p_user, p);
  when 'rental_form_rep' then return app.rental_form_rep(p_user, p);
  else raise exception 'Unknown action %', p_name using errcode = '22023';
  end case;
end $$;

alter function app.door(uuid, text, text, text, jsonb) rename to door_pre0127;
create or replace function app.door(p_user uuid, p_aal text, p_call text, p_name text, p jsonb default '{}'::jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
begin
  if p_call in ('ops_read', 'ops_do') and p_name in ('rental_form_preview', 'rental_form_upload', 'rental_form_check', 'rental_form_rep') then
    if p_call = 'ops_read' and p_name <> 'rental_form_preview' then raise exception 'Unknown read %', p_name using errcode = '22023'; end if;
    perform app.door_begin(p_user, p_aal);
    return app.ops0127(p_user, p_call, p_name, coalesce(p, '{}'::jsonb) - '_va');
  end if;
  -- a per-booking form is not mapped field by field
  if p_call = 'ops_do' and p_name in ('form_template_upload', 'form_template_map')
     and exists (select 1 from pdf_templates t where t.kind = 'booking_overlay' and (t.form_code = p ->> 'form_code' or t.id::text = p ->> 'template')) then
    raise exception 'This form is filled for each booking: upload it on its own card' using errcode = '22023';
  end if;
  return app.door_pre0127(p_user, p_aal, p_call, p_name, p);
end $$;

-- ================================================================ 5. the renter's email carries the signed second agreement
alter function app.outbox_attachments(uuid) rename to outbox_attachments_pre0127;
create or replace function app.outbox_attachments(p_outbox uuid) returns jsonb
language plpgsql stable security definer set search_path = public, app as $$
declare
  o notification_outbox;
begin
  select * into o from notification_outbox where id = p_outbox;
  if o.id is null or o.code <> 'renter_agreement_signed' or o.entity <> 'rental_agreement' then return app.outbox_attachments_pre0127(p_outbox); end if;
  return app.outbox_attachments_pre0127(p_outbox) || coalesce((
    select jsonb_agg(jsonb_build_object('k', 'document', 'key', d.id::text, 'filename', d.title || '.pdf'))
      from rental_agreement_companions c join documents d on d.id = c.signed_document_id
     where c.rental_agreement_id = o.entity_id and c.status = 'completed'), '[]'::jsonb);
end $$;

-- ... and waits a few minutes for it (its signed copy is rendered right after the countersignature)
create or replace function app.outbox_wait_companion() returns trigger
language plpgsql security definer set search_path = public, app as $$
begin
  if new.code = 'renter_agreement_signed' and new.entity = 'rental_agreement'
     and exists (select 1 from rental_agreement_companions c where c.rental_agreement_id = new.entity_id and c.status = 'signed') then
    new.send_after := greatest(coalesce(new.send_after, now()), now() + interval '5 minutes');
  end if;
  return new;
end $$;
drop trigger if exists outbox_wait_companion on notification_outbox;
create trigger outbox_wait_companion before insert on notification_outbox for each row execute function app.outbox_wait_companion();

-- ================================================================ 6. Admin > Today until it is all set
alter function app.site_setup_problems() rename to site_setup_problems_pre0127;
create or replace function app.site_setup_problems() returns jsonb
language sql stable security definer set search_path = public, app as $$
  select coalesce(app.site_setup_problems_pre0127(), '[]'::jsonb) || coalesce((select jsonb_agg(x) from (
    select jsonb_build_object('field', 'company_hst_number', 'blocks', null, 'href', '/admin/settings/program',
                              'message', 'Enter CarmaCars'' HST number (Program settings, Company HST number): the Blind Spot rental agreement prints it in box 1, and stays blank there until it is entered') as x
     where nullif(btrim(coalesce((app.settings()).company_hst_number, '')), '') is null
    union all
    select jsonb_build_object('field', 'rental_form', 'blocks', null, 'href', '/admin/settings/forms',
                              'message', case when t.file_key is null then 'Upload Blind Spot''s rental agreement PDF (Settings > Forms): every booking then gets it as its second agreement, filled and signed with the first'
                                              else 'Check the Blind Spot rental agreement (Settings > Forms): download the filled sample, then press "Checked: use for bookings"' end)
      from pdf_templates t where t.form_code = 'BLINDSPOT-RA' and t.is_current and not t.verified) q), '[]'::jsonb)
$$;

-- ================================================================ privileges
do $$
declare
  f record;
begin
  for f in
    select p.oid::regprocedure as sig from pg_proc p join pg_namespace n on n.oid = p.pronamespace
     where (n.nspname = 'app' and p.proname = any (array['blindspot_template', 'blindspot_extra', 'rental_forms_state', 'form_templates', 'form_templates_pre0127',
              'rental_form_upload', 'rental_form_check', 'rental_form_rep', 'rental_form_preview', 'ops0127', 'door', 'door_pre0127',
              'outbox_attachments', 'outbox_attachments_pre0127', 'outbox_wait_companion', 'renter_sign_agreement_pre0127']))
        or (n.nspname = 'public' and p.proname = any (array['server_blindspot_facts', 'server_agreement_companion', 'server_open_agreement_companion',
              'server_attach_companion_signed', 'renter_sign_agreement']))
  loop
    execute format('revoke all on function %s from public, anon, authenticated', f.sig);
    execute format('grant execute on function %s to service_role', f.sig);
  end loop;
end $$;
-- Admin > Today and Settings read the setup list as before
revoke all on function app.site_setup_problems(), app.site_setup_problems_pre0127() from public, anon;
grant execute on function app.site_setup_problems(), app.site_setup_problems_pre0127() to authenticated, service_role;

-- ================================================================ 7. the guides
-- GUIDES 0127 START (generated by supabase/seed/0127_gen_guides.mjs from docs/guides/content; do not edit by hand)
select app.guide_release_section('renter', 'sign-and-pay', 'chapter', 'your-offer', 'After you approve, you sign the rental agreement on screen and pay. It takes a few minutes on a phone or a computer; the signing itself is three taps.

## Sign the rental agreement

1. Fill in your home address and licence details. You do this once; we keep them for next time.
2. Press **Save details**. The agreement then shows your details.

![](/guides/img/renter-04-sign-details-desktop-bd193670.jpg "desktop; size: 1440 1052; address: carmacars.ca/account/bookings/CC-10057/sign; pins: 1 44.4 25.9, 2 16.3 96.4")

3. Check the key values at the top: the car, the dates, the deposit and the deductible. Open **Read the full rental agreement** to read it word for word, or press **Download PDF** to keep a copy.
4. Under Sign, tap **All four**: it ticks the four statements, which stay on screen to read.
5. Your full legal name is your signature. Prefer to sign with your finger or the mouse? Press **Draw instead**.
6. Press **Sign and continue to payment**.

![](/guides/img/renter-06-sign-ready-desktop-1eee20a4.jpg "desktop; size: 1440 1212; address: carmacars.ca/account/bookings/CC-10057/sign; pins: 3 59.0 8.9, 4 69.4 18.2, 5 90.3 78.5, 6 96.9 87.1")

## Pay to confirm

1. Check What you pay now. The refundable deposit is taken at pickup, not today.
2. Enter the Name on the card and the card details. Use a credit card in your own name.
3. Press **Pay $...** (the button shows the amount).

![](/guides/img/renter-07-pay-desktop-705896d6.jpg "desktop; size: 1440 1082; address: carmacars.ca/account/bookings/CC-10057/pay; pins: 7 70.5 21.9, 8 64.6 16.5, 9 64.6 96.4")

> Tip: Your card is authorized now and charged once the booking is confirmed. It becomes your Card on File for the deposit at pickup and any later charges you agreed to when you signed.

> Watch out: See "This car was just taken"? Someone confirmed the same car first. The authorization on your card is released, and we offer you another car or other dates.

## A rental we booked for you

Booked by phone, in person or through a partner? We add the rental and you sign it online.

1. You get an email: "Read and sign your rental agreement; your card is charged when you sign."
2. Open it. Check the car, the dates and the price, and read the agreement.
3. Press **Accept and sign**. If we have your card on file, it is charged at that moment, not before, and the agreement is countersigned by CarmaCars as soon as you sign.
', 'Sign and pay', 'Sign the rental agreement on screen and pay with your card.',
  'After you approve, you sign the rental agreement on screen and pay. It takes a few minutes on a phone or a computer; the signing itself is three taps.

## Sign the rental agreement

1. Fill in your home address and licence details. You do this once; we keep them for next time.
2. Press **Save details**. The agreement then shows your details.

![](/guides/img/renter-04-sign-details-desktop-bd193670.jpg "desktop; size: 1440 1052; address: carmacars.ca/account/bookings/CC-10057/sign; pins: 1 44.4 25.9, 2 16.3 96.4")

3. Check the key values at the top: the car, the dates, the deposit and the deductible. Open **Read the full rental agreement** to read it word for word, or press **Download PDF** to keep a copy. Below it is the Blind Spot Car Rental agreement, filled in with the same booking: we rent under Blind Spot''s insurance, so it is part of your rental too. Press its **Download PDF** to read it.
4. Under Sign, tap **All four**: it ticks the four statements, which stay on screen to read.
5. Your full legal name is your signature. Prefer to sign with your finger or the mouse? Press **Draw instead**.
6. Press **Sign and continue to payment**. Your one signature signs both agreements; the signed copies are in Documents and in the email that confirms your booking.

![](/guides/img/renter-06-sign-ready-desktop-1eee20a4.jpg "desktop; size: 1440 1212; address: carmacars.ca/account/bookings/CC-10057/sign; pins: 3 59.0 8.9, 4 69.4 18.2, 5 90.3 78.5, 6 96.9 87.1")

## Pay to confirm

1. Check What you pay now. The refundable deposit is taken at pickup, not today.
2. Enter the Name on the card and the card details. Use a credit card in your own name.
3. Press **Pay $...** (the button shows the amount).

![](/guides/img/renter-07-pay-desktop-705896d6.jpg "desktop; size: 1440 1082; address: carmacars.ca/account/bookings/CC-10057/pay; pins: 7 70.5 21.9, 8 64.6 16.5, 9 64.6 96.4")

> Tip: Your card is authorized now and charged once the booking is confirmed. It becomes your Card on File for the deposit at pickup and any later charges you agreed to when you signed.

> Watch out: See "This car was just taken"? Someone confirmed the same car first. The authorization on your card is released, and we offer you another car or other dates.

## A rental we booked for you

Booked by phone, in person or through a partner? We add the rental and you sign it online.

1. You get an email: "Read and sign your rental agreement; your card is charged when you sign."
2. Open it. Check the car, the dates and the price, and read the agreement.
3. Press **Accept and sign**. If we have your card on file, it is charged at that moment, not before, and the agreement is countersigned by CarmaCars as soon as you sign.
',
  '<p class="gd-p">After you approve, you sign the rental agreement on screen and pay. It takes a few minutes on a phone or a computer; the signing itself is three taps.</p><section class="gd-task" id="sign-and-pay-sign-the-rental-agreement" data-gd-task><h2 class="gd-h2">Sign the rental agreement</h2><div class="gd-stepblock gd-stepblock--below"><div class="gd-stepcol"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">Fill in your home address and licence details. You do this once; we keep them for next time.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Press <b class="gd-ui">Save details</b>. The agreement then shows your details.</div></li></ol></div><figure class="gd-fig gd-fig--desk"><div class="gd-browser"><div class="gd-bar" aria-hidden="true"><i></i><i></i><i></i><span class="gd-addr">carmacars.ca/account/bookings/CC-10057/sign</span></div><div class="gd-imgwrap" style="aspect-ratio:1440/1052"><img src="/guides/img/renter-04-sign-details-desktop-bd193670.jpg" alt="" loading="lazy" decoding="async" width="1440" height="1052"><span class="gd-pin" style="left:44.4%;top:25.9%" aria-hidden="true">1</span><span class="gd-pin" style="left:16.3%;top:96.4%" aria-hidden="true">2</span></div></div></figure></div><div class="gd-stepblock gd-stepblock--below"><div class="gd-stepcol"><ol class="gd-ol" start="3"><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Check the key values at the top: the car, the dates, the deposit and the deductible. Open <b class="gd-ui">Read the full rental agreement</b> to read it word for word, or press <b class="gd-ui">Download PDF</b> to keep a copy. Below it is the Blind Spot Car Rental agreement, filled in with the same booking: we rent under Blind Spot&#39;s insurance, so it is part of your rental too. Press its <b class="gd-ui">Download PDF</b> to read it.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t">Under Sign, tap <b class="gd-ui">All four</b>: it ticks the four statements, which stay on screen to read.</div></li><li><span class="gd-n" aria-hidden="true">5</span><div class="gd-t">Your full legal name is your signature. Prefer to sign with your finger or the mouse? Press <b class="gd-ui">Draw instead</b>.</div></li><li><span class="gd-n" aria-hidden="true">6</span><div class="gd-t">Press <b class="gd-ui">Sign and continue to payment</b>. Your one signature signs both agreements; the signed copies are in Documents and in the email that confirms your booking.</div></li></ol></div><figure class="gd-fig gd-fig--desk"><div class="gd-browser"><div class="gd-bar" aria-hidden="true"><i></i><i></i><i></i><span class="gd-addr">carmacars.ca/account/bookings/CC-10057/sign</span></div><div class="gd-imgwrap" style="aspect-ratio:1440/1212"><img src="/guides/img/renter-06-sign-ready-desktop-1eee20a4.jpg" alt="" loading="lazy" decoding="async" width="1440" height="1212"><span class="gd-pin" style="left:59%;top:8.9%" aria-hidden="true">3</span><span class="gd-pin" style="left:69.4%;top:18.2%" aria-hidden="true">4</span><span class="gd-pin" style="left:90.3%;top:78.5%" aria-hidden="true">5</span><span class="gd-pin" style="left:96.9%;top:87.1%" aria-hidden="true">6</span></div></div></figure></div></section><section class="gd-task" id="sign-and-pay-pay-to-confirm" data-gd-task><h2 class="gd-h2">Pay to confirm</h2><div class="gd-stepblock gd-stepblock--below"><div class="gd-stepcol"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">Check What you pay now. The refundable deposit is taken at pickup, not today.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Enter the Name on the card and the card details. Use a credit card in your own name.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Press <b class="gd-ui">Pay $...</b> (the button shows the amount).</div></li></ol></div><figure class="gd-fig gd-fig--desk"><div class="gd-browser"><div class="gd-bar" aria-hidden="true"><i></i><i></i><i></i><span class="gd-addr">carmacars.ca/account/bookings/CC-10057/pay</span></div><div class="gd-imgwrap" style="aspect-ratio:1440/1082"><img src="/guides/img/renter-07-pay-desktop-705896d6.jpg" alt="" loading="lazy" decoding="async" width="1440" height="1082"><span class="gd-pin" style="left:70.5%;top:21.9%" aria-hidden="true">7</span><span class="gd-pin" style="left:64.6%;top:16.5%" aria-hidden="true">8</span><span class="gd-pin" style="left:64.6%;top:96.4%" aria-hidden="true">9</span></div></div></figure></div><aside class="gd-box"><span class="gd-lbl">Tip</span><div>Your card is authorized now and charged once the booking is confirmed. It becomes your Card on File for the deposit at pickup and any later charges you agreed to when you signed.</div></aside><aside class="gd-box gd-box--warn"><span class="gd-lbl">Watch out</span><div>See &quot;This car was just taken&quot;? Someone confirmed the same car first. The authorization on your card is released, and we offer you another car or other dates.</div></aside></section><section class="gd-task" id="sign-and-pay-a-rental-we-booked-for-you" data-gd-task><h2 class="gd-h2">A rental we booked for you</h2><p class="gd-p">Booked by phone, in person or through a partner? We add the rental and you sign it online.</p><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">You get an email: &quot;Read and sign your rental agreement; your card is charged when you sign.&quot;</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Open it. Check the car, the dates and the price, and read the agreement.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Press <b class="gd-ui">Accept and sign</b>. If we have your card on file, it is charged at that moment, not before, and the agreement is countersigned by CarmaCars as soon as you sign.</div></li></ol></div></section>');
select app.guide_release_section('admin', 'settings', 'chapter', 'search-car-pages-landing-pages-and-guides', 'Settings change the public site and the rules of the program at once. Program settings are kept as dated rows, so earlier values stay on record.

## The Settings page

1. Site setup lists what is still missing on the public site, with **Open site settings**.
2. Site settings: contact details, hours, tagline, logo, socials, Google place id and featured cars.
3. Program settings: every timing and policy value.
4. Forms: the official ServiceOntario PDFs and what goes in each field.
5. Insurers: insurance companies billed for bookings.

![](/guides/img/admin-24-settings-desktop-89b31691.jpg "desktop; size: 1440 900; address: carmacars.ca/admin/settings; pins: 1 32.6 33.0, 2 25.8 40.2, 3 77.4 40.2, 4 25.8 73.2, 5 25.8 84.9")

The other tiles: Site content (headings, FAQs, legal text), Fee defaults, Deposit tiers, Kilometre choices, Vehicle classes, Airports and delivery, Coverage prices, Email aliases and reply-to, Staff and roles, Promo codes and Quick replies.

## Program settings

1. Turnaround between trips: the time held between two trips. The cleaning block after a trip is this time.
2. Settings come in groups such as Company, Booking requests and offers, Owner debits and statement emails, Deposits, Delivery, Owners and fleet, and Tolls and damage. Open one to see its fields.
3. First reply target for customer service and sales (minutes), under Booking requests and offers: 5 by default. New booking requests, enquiries, changes renters ask for and renter messages are due that many minutes after they come in; the scorecard and the staff screens use it. What renters are told (Reply wording, in Site settings) is separate.
4. Staff commissions and prices typed by hand: the commission outside Sales (10%), the three Sales tiers and their days (10%, 15% from 50 days, 20% from 100 days, the month''s target), the price floor a day (empty: none) and the discount from the rate sheet that flags a price (20%). The owner confirmed these values in October 2026.
5. Staff agreement defaults by function, at the bottom: pay (a month, an hour or commission only), the rate, the schedule (full time, part time or flexible), days a week and hours a day for Customer service, Fleet, Finance and Sales, the values every assistant shares, and the field staff wage. Sales is commission only: no rate and a flexible schedule. Press **Save the defaults**.
6. Live visitors and live chat: recording visits, the signal thresholds, follow-up tasks, the chat and its assistant, and how long visits and chats are kept.
7. Discount games: the same values as Settings, Discount games (the prize table and the games are easier to change there).
8. Sign-in by phone: codes by text from the CarmaCars number (on), US numbers (off until the Quo number is registered for US texting, A2P 10DLC), codes per number and per connection an hour, and whether a verified phone confirms an account like a confirmed email. Accepting an offer, signing and paying need a confirmed account; an account made by phone gives its email on the pay page before its first payment.
9. Calendar sync, Turo by email, Booking recovery emails and Site check: how often calendar links are read, the Turo inbound address and who may forward to it, the reminder delays and sending hours, and the site check with the address its alerts go to (rent@carmacars.ca), the minutes before an email, the daily limit and the quiet hours.
10. Change a value and press **Save**. It is saved as a new row from today; the rows before stay as they were.

![](/guides/img/admin-25-program-settings-desktop-d16b066c.jpg "desktop; size: 1440 1000; address: carmacars.ca/admin/settings/program; pins: 1 25.8 22.0, 2 27.8 49.0")

## Official ServiceOntario forms

The five official forms are loaded with a mapping to the owner, car, company and lender details. Each is the form exactly as ServiceOntario publishes it: only its empty text boxes are filled. Its checkboxes, drop-downs and signatures are done by hand at the counter, in ink. Until you check a form, owners get a data sheet with the values.

1. Open **Settings** > **Forms**. Each form shows "Mapping to check" (a draft is ready) or "Official PDF in use". Its notes say what the form is for and which boxes are left blank on purpose.
2. Press **Download a filled preview** for one car and check each value against the form.
3. Change a field if needed: What goes in it (or "Signed here by hand, in ink"), a Format (for example YYYY/MM/DD) and Only when. Press Save the mapping.
4. Press **Checked: use for owners**. Every owner''s form of that kind is filled again, except ones already signed or filed. Owners download it, print it and sign it in ink; record it with **Record paper signature**. Each form not checked yet is also a line on To do with the same button and Preview it.
5. A new version from ServiceOntario? Press **Upload the official fillable PDF**: the fields of the same name keep their mapping.

> Good to know: SR-LV-006 (registration), SR-LV-012 (two registrants), ON00453 (a company''s RIN), 013-1155 and 013-0169 (the tax-exempt transfer into an owner''s corporation). 013-1155 is sworn before a commissioner, so it is printed and signed in person. ON00453 is an Adobe form: it opens in Adobe Acrobat Reader. Each form''s notes list what to tick or choose at the counter.

## Agreements to sign: investors and staff

Investment agreements and staff agreements are made from the person''s record and signed in their own portal, or on paper.

1. Investor: open **People** > **Investors** and the investor. Under Investment agreement, press **Send the agreement to sign**. Check the values it is filled with (amount, yearly percentage, dates, exemption) and press **Send to sign**.
2. Once the investor signs, the agreement shows **Awaiting countersignature** on the investor''s page and on To do. It is not countersigned automatically: check it and press **Countersign**. CarmaCars is bound once it has countersigned and the funds clear.
3. Staff: open **People** > **Staff**. Under Staff agreements, press **Send the agreement to sign** beside the person. Pay, schedule, hours and the other values start from the staff profile and the defaults of their function in Program settings; change any before sending. For Sales the Pay is Commission only: the agreement then has no rate, schedule or hours, and pays the commission of section 3.4.
4. A field staff member''s agreement prints the home address they entered themselves. Staff enter their home address at their first sign-in, before they sign, or in their profile.
5. They get a notice, check the key values and sign in their portal in a few taps (their name is the signature, or they draw it). The signed copy is filed with their documents.
6. Your own PDF instead? **Send a PDF to sign** still works.
7. Signed on paper instead? Press **Record paper signature** in the same place and upload the scan.
8. Sent by mistake? Press **Withdraw** and give the reason.

## The user guides

**Settings** > **Guides**. The guide of each portal, as people read it under Guide.

1. Each guide shows its version, when it was published and whether there are unpublished changes.
2. Open a guide and press a section. Change its text and press **Show the preview** to see it as people will. Press **Save the draft**; each save is kept in the section''s history.
3. Move a section with the arrows, hide it, or press **Add a chapter**. Upload a screenshot under Screenshots and paste the line it gives you.
4. Press **Publish version** (the next number). The portals show the new version at once.
5. The stored PDF is printed again by the guides-pdf workflow. Until then the guide says the web guide has newer edits.

## The guides keep up by themselves

After every update of the site that changes the portals, the guides are checked without anyone asking.

1. Every screenshot is taken again on the new version of the site. One whose screen changed replaces the old one in the guide.
2. The text of each section whose screen changed, or that names a button the portals no longer show, is rewritten from the portal''s own labels and menu, checked, and published. The PDFs of those guides are printed again.
3. Such a section says **Changed automatically on** and the date, in the list of guides and in the guide''s editor. Not right? Open the section and press **Revert**: the text it replaced comes back, published at once.
4. This includes sections you edited: the newest automatic text is published, and every earlier version stays in the section''s history. There is nothing to review.
5. A rewrite that does not pass the checks is asked again, more strictly. If it still does not pass, the screenshots and button names are updated, the rest of the text stays as it was, and the next run tries again.

> Tip: The card "The guides keep up by themselves" at the top of Guides lists the last runs: when, how many screenshots were replaced, how many sections were rewritten, and how many PDFs were printed.

## Insurers and the other lists

1. Open Insurers. Each insurer on file opens to edit its billing contact, email, phone, address and notes.
2. To add one, fill in the Add form (Name, Billing contact, Billing email and the rest) and press **Add**.
3. Deposit tiers, Kilometre choices, Vehicle classes, Airports, Promo codes and Quick replies work the same way.
', 'Settings', 'Site, program settings, official forms mapping, insurers and the other lists.',
  'Settings change the public site and the rules of the program at once. Program settings are kept as dated rows, so earlier values stay on record.

## The Settings page

1. Site setup lists what is still missing on the public site, with **Open site settings**.
2. Site settings: contact details, hours, tagline, logo, socials, Google place id and featured cars.
3. Program settings: every timing and policy value.
4. Forms: Blind Spot''s rental agreement for every booking, and the official ServiceOntario PDFs and what goes in each field.
5. Insurers: insurance companies billed for bookings.

![](/guides/img/admin-24-settings-desktop-89b31691.jpg "desktop; size: 1440 900; address: carmacars.ca/admin/settings; pins: 1 32.6 33.0, 2 25.8 40.2, 3 77.4 40.2, 4 25.8 73.2, 5 25.8 84.9")

The other tiles: Site content (headings, FAQs, legal text), Fee defaults, Deposit tiers, Kilometre choices, Vehicle classes, Airports and delivery, Coverage prices, Email aliases and reply-to, Staff and roles, Promo codes and Quick replies.

## Program settings

1. Turnaround between trips: the time held between two trips. The cleaning block after a trip is this time.
2. Settings come in groups such as Company, Booking requests and offers, Owner debits and statement emails, Deposits, Delivery, Owners and fleet, and Tolls and damage. Open one to see its fields.
3. First reply target for customer service and sales (minutes), under Booking requests and offers: 5 by default. New booking requests, enquiries, changes renters ask for and renter messages are due that many minutes after they come in; the scorecard and the staff screens use it. What renters are told (Reply wording, in Site settings) is separate.
4. Staff commissions and prices typed by hand: the commission outside Sales (10%), the three Sales tiers and their days (10%, 15% from 50 days, 20% from 100 days, the month''s target), the price floor a day (empty: none) and the discount from the rate sheet that flags a price (20%). The owner confirmed these values in October 2026.
5. Staff agreement defaults by function, at the bottom: pay (a month, an hour or commission only), the rate, the schedule (full time, part time or flexible), days a week and hours a day for Customer service, Fleet, Finance and Sales, the values every assistant shares, and the field staff wage. Sales is commission only: no rate and a flexible schedule. Press **Save the defaults**.
6. Live visitors and live chat: recording visits, the signal thresholds, follow-up tasks, the chat and its assistant, and how long visits and chats are kept.
7. Discount games: the same values as Settings, Discount games (the prize table and the games are easier to change there).
8. Sign-in by phone: codes by text from the CarmaCars number (on), US numbers (off until the Quo number is registered for US texting, A2P 10DLC), codes per number and per connection an hour, and whether a verified phone confirms an account like a confirmed email. Accepting an offer, signing and paying need a confirmed account; an account made by phone gives its email on the pay page before its first payment.
9. Calendar sync, Turo by email, Booking recovery emails and Site check: how often calendar links are read, the Turo inbound address and who may forward to it, the reminder delays and sending hours, and the site check with the address its alerts go to (rent@carmacars.ca), the minutes before an email, the daily limit and the quiet hours.
10. Change a value and press **Save**. It is saved as a new row from today; the rows before stay as they were.

![](/guides/img/admin-25-program-settings-desktop-d16b066c.jpg "desktop; size: 1440 1000; address: carmacars.ca/admin/settings/program; pins: 1 25.8 22.0, 2 27.8 49.0")

## Official ServiceOntario forms

The five official forms are loaded with a mapping to the owner, car, company and lender details. Each is the form exactly as ServiceOntario publishes it: only its empty text boxes are filled. Its checkboxes, drop-downs and signatures are done by hand at the counter, in ink. Until you check a form, owners get a data sheet with the values.

1. Open **Settings** > **Forms**. Each form shows "Mapping to check" (a draft is ready) or "Official PDF in use". Its notes say what the form is for and which boxes are left blank on purpose.
2. Press **Download a filled preview** for one car and check each value against the form.
3. Change a field if needed: What goes in it (or "Signed here by hand, in ink"), a Format (for example YYYY/MM/DD) and Only when. Press Save the mapping.
4. Press **Checked: use for owners**. Every owner''s form of that kind is filled again, except ones already signed or filed. Owners download it, print it and sign it in ink; record it with **Record paper signature**. Each form not checked yet is also a line on To do with the same button and Preview it.
5. A new version from ServiceOntario? Press **Upload the official fillable PDF**: the fields of the same name keep their mapping.

> Good to know: SR-LV-006 (registration), SR-LV-012 (two registrants), ON00453 (a company''s RIN), 013-1155 and 013-0169 (the tax-exempt transfer into an owner''s corporation). 013-1155 is sworn before a commissioner, so it is printed and signed in person. ON00453 is an Adobe form: it opens in Adobe Acrobat Reader. Each form''s notes list what to tick or choose at the counter.

## Blind Spot rental agreement

We rent under Blind Spot Car Rental''s insurance, so every booking has two agreements: CarmaCars'' rental agreement and Blind Spot''s own. Blind Spot''s is filled in from the booking, the renter and the car, and the renter signs both with one signature. Its PDF is stored privately, never on the website.

1. Open **Settings** > **Forms**. The Blind Spot Car Rental agreement card is first. Press **Upload Blind Spot''s PDF** and choose Blind Spot''s blank form (2 pages, A4).
2. Press **Download the filled sample**: a made-up booking on the form. **Sample billed to an insurer** also fills the claim number, the adjuster and the insurance company. Check every box.
3. On the form the old address (top left and twice in box 15) is replaced by the mailing address of Site settings, box 1 by CarmaCars'' HST number (Program settings, Company HST number; blank until it is entered), and box 21 has the representative''s signature instead of Sam''s.
4. Press **Checked: use for bookings**. From then on each booking gets it when its rental agreement is made; a renter whose agreement is already open gets it the next time they open the signing page.
5. Box 21: Ahmad is written in a script hand, as Blind Spot asked. To use a real signature instead, upload a PNG under Authorized company representative; Remove the image goes back to the written name. Full name is for the signature record page.
6. A new version of Blind Spot''s form? Upload it the same way: it waits for **Checked: use for bookings**, and bookings keep the version in use until then.

> Good to know: Each box is filled only when the booking has the value: the renter and their licence, the additional drivers, the car (plate, make and model, the fleet number as vehicle number), the pickup as time and date out, the due-back date and time, the kilometres allowed, the daily rate and the rental charge, the underage fee, the Protection Plan as CDW, winter tires, the subtotal, HST, total and deposit, and for a booking billed to an insurer the insurer, claim number and adjuster. Other charges, such as delivery, are listed in box 14. Initials, fuel and the boxes filled at return stay blank.

The renter''s signature goes in boxes 16, 17 and 20 of the signed copy, with a signature record page. Both agreements are in the booking''s Drivers and documents tab, in the renter''s Documents, and the signed Blind Spot agreement is attached to the "Your signed rental agreement" email. Admin > Today lists the HST number, the upload and the check until they are done.

## Agreements to sign: investors and staff

Investment agreements and staff agreements are made from the person''s record and signed in their own portal, or on paper.

1. Investor: open **People** > **Investors** and the investor. Under Investment agreement, press **Send the agreement to sign**. Check the values it is filled with (amount, yearly percentage, dates, exemption) and press **Send to sign**.
2. Once the investor signs, the agreement shows **Awaiting countersignature** on the investor''s page and on To do. It is not countersigned automatically: check it and press **Countersign**. CarmaCars is bound once it has countersigned and the funds clear.
3. Staff: open **People** > **Staff**. Under Staff agreements, press **Send the agreement to sign** beside the person. Pay, schedule, hours and the other values start from the staff profile and the defaults of their function in Program settings; change any before sending. For Sales the Pay is Commission only: the agreement then has no rate, schedule or hours, and pays the commission of section 3.4.
4. A field staff member''s agreement prints the home address they entered themselves. Staff enter their home address at their first sign-in, before they sign, or in their profile.
5. They get a notice, check the key values and sign in their portal in a few taps (their name is the signature, or they draw it). The signed copy is filed with their documents.
6. Your own PDF instead? **Send a PDF to sign** still works.
7. Signed on paper instead? Press **Record paper signature** in the same place and upload the scan.
8. Sent by mistake? Press **Withdraw** and give the reason.

## The user guides

**Settings** > **Guides**. The guide of each portal, as people read it under Guide.

1. Each guide shows its version, when it was published and whether there are unpublished changes.
2. Open a guide and press a section. Change its text and press **Show the preview** to see it as people will. Press **Save the draft**; each save is kept in the section''s history.
3. Move a section with the arrows, hide it, or press **Add a chapter**. Upload a screenshot under Screenshots and paste the line it gives you.
4. Press **Publish version** (the next number). The portals show the new version at once.
5. The stored PDF is printed again by the guides-pdf workflow. Until then the guide says the web guide has newer edits.

## The guides keep up by themselves

After every update of the site that changes the portals, the guides are checked without anyone asking.

1. Every screenshot is taken again on the new version of the site. One whose screen changed replaces the old one in the guide.
2. The text of each section whose screen changed, or that names a button the portals no longer show, is rewritten from the portal''s own labels and menu, checked, and published. The PDFs of those guides are printed again.
3. Such a section says **Changed automatically on** and the date, in the list of guides and in the guide''s editor. Not right? Open the section and press **Revert**: the text it replaced comes back, published at once.
4. This includes sections you edited: the newest automatic text is published, and every earlier version stays in the section''s history. There is nothing to review.
5. A rewrite that does not pass the checks is asked again, more strictly. If it still does not pass, the screenshots and button names are updated, the rest of the text stays as it was, and the next run tries again.

> Tip: The card "The guides keep up by themselves" at the top of Guides lists the last runs: when, how many screenshots were replaced, how many sections were rewritten, and how many PDFs were printed.

## Insurers and the other lists

1. Open Insurers. Each insurer on file opens to edit its billing contact, email, phone, address and notes.
2. To add one, fill in the Add form (Name, Billing contact, Billing email and the rest) and press **Add**.
3. Deposit tiers, Kilometre choices, Vehicle classes, Airports, Promo codes and Quick replies work the same way.
',
  '<p class="gd-p">Settings change the public site and the rules of the program at once. Program settings are kept as dated rows, so earlier values stay on record.</p><section class="gd-task" id="settings-the-settings-page" data-gd-task><h2 class="gd-h2">The Settings page</h2><div class="gd-stepblock gd-stepblock--below"><div class="gd-stepcol"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">Site setup lists what is still missing on the public site, with <b class="gd-ui">Open site settings</b>.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Site settings: contact details, hours, tagline, logo, socials, Google place id and featured cars.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Program settings: every timing and policy value.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t">Forms: Blind Spot&#39;s rental agreement for every booking, and the official ServiceOntario PDFs and what goes in each field.</div></li><li><span class="gd-n" aria-hidden="true">5</span><div class="gd-t">Insurers: insurance companies billed for bookings.</div></li></ol></div><figure class="gd-fig gd-fig--desk"><div class="gd-browser"><div class="gd-bar" aria-hidden="true"><i></i><i></i><i></i><span class="gd-addr">carmacars.ca/admin/settings</span></div><div class="gd-imgwrap" style="aspect-ratio:1440/900"><img src="/guides/img/admin-24-settings-desktop-89b31691.jpg" alt="" loading="lazy" decoding="async" width="1440" height="900"><span class="gd-pin" style="left:32.6%;top:33%" aria-hidden="true">1</span><span class="gd-pin" style="left:25.8%;top:40.2%" aria-hidden="true">2</span><span class="gd-pin" style="left:77.4%;top:40.2%" aria-hidden="true">3</span><span class="gd-pin" style="left:25.8%;top:73.2%" aria-hidden="true">4</span><span class="gd-pin" style="left:25.8%;top:84.9%" aria-hidden="true">5</span></div></div></figure></div><p class="gd-p">The other tiles: Site content (headings, FAQs, legal text), Fee defaults, Deposit tiers, Kilometre choices, Vehicle classes, Airports and delivery, Coverage prices, Email aliases and reply-to, Staff and roles, Promo codes and Quick replies.</p></section><section class="gd-task" id="settings-program-settings" data-gd-task><h2 class="gd-h2">Program settings</h2><div class="gd-stepblock gd-stepblock--below"><div class="gd-stepcol"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">Turnaround between trips: the time held between two trips. The cleaning block after a trip is this time.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Settings come in groups such as Company, Booking requests and offers, Owner debits and statement emails, Deposits, Delivery, Owners and fleet, and Tolls and damage. Open one to see its fields.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">First reply target for customer service and sales (minutes), under Booking requests and offers: 5 by default. New booking requests, enquiries, changes renters ask for and renter messages are due that many minutes after they come in; the scorecard and the staff screens use it. What renters are told (Reply wording, in Site settings) is separate.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t">Staff commissions and prices typed by hand: the commission outside Sales (10%), the three Sales tiers and their days (10%, 15% from 50 days, 20% from 100 days, the month&#39;s target), the price floor a day (empty: none) and the discount from the rate sheet that flags a price (20%). The owner confirmed these values in October 2026.</div></li><li><span class="gd-n" aria-hidden="true">5</span><div class="gd-t">Staff agreement defaults by function, at the bottom: pay (a month, an hour or commission only), the rate, the schedule (full time, part time or flexible), days a week and hours a day for Customer service, Fleet, Finance and Sales, the values every assistant shares, and the field staff wage. Sales is commission only: no rate and a flexible schedule. Press <b class="gd-ui">Save the defaults</b>.</div></li><li><span class="gd-n" aria-hidden="true">6</span><div class="gd-t">Live visitors and live chat: recording visits, the signal thresholds, follow-up tasks, the chat and its assistant, and how long visits and chats are kept.</div></li><li><span class="gd-n" aria-hidden="true">7</span><div class="gd-t">Discount games: the same values as Settings, Discount games (the prize table and the games are easier to change there).</div></li><li><span class="gd-n" aria-hidden="true">8</span><div class="gd-t">Sign-in by phone: codes by text from the CarmaCars number (on), US numbers (off until the Quo number is registered for US texting, A2P 10DLC), codes per number and per connection an hour, and whether a verified phone confirms an account like a confirmed email. Accepting an offer, signing and paying need a confirmed account; an account made by phone gives its email on the pay page before its first payment.</div></li><li><span class="gd-n" aria-hidden="true">9</span><div class="gd-t">Calendar sync, Turo by email, Booking recovery emails and Site check: how often calendar links are read, the Turo inbound address and who may forward to it, the reminder delays and sending hours, and the site check with the address its alerts go to (rent@carmacars.ca), the minutes before an email, the daily limit and the quiet hours.</div></li><li><span class="gd-n" aria-hidden="true">10</span><div class="gd-t">Change a value and press <b class="gd-ui">Save</b>. It is saved as a new row from today; the rows before stay as they were.</div></li></ol></div><figure class="gd-fig gd-fig--desk"><div class="gd-browser"><div class="gd-bar" aria-hidden="true"><i></i><i></i><i></i><span class="gd-addr">carmacars.ca/admin/settings/program</span></div><div class="gd-imgwrap" style="aspect-ratio:1440/1000"><img src="/guides/img/admin-25-program-settings-desktop-d16b066c.jpg" alt="" loading="lazy" decoding="async" width="1440" height="1000"><span class="gd-pin" style="left:25.8%;top:22%" aria-hidden="true">1</span><span class="gd-pin" style="left:27.8%;top:49%" aria-hidden="true">2</span></div></div></figure></div></section><section class="gd-task" id="settings-official-serviceontario-forms" data-gd-task><h2 class="gd-h2">Official ServiceOntario forms</h2><p class="gd-p">The five official forms are loaded with a mapping to the owner, car, company and lender details. Each is the form exactly as ServiceOntario publishes it: only its empty text boxes are filled. Its checkboxes, drop-downs and signatures are done by hand at the counter, in ink. Until you check a form, owners get a data sheet with the values.</p><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">Open <b class="gd-ui">Settings</b> &gt; <b class="gd-ui">Forms</b>. Each form shows &quot;Mapping to check&quot; (a draft is ready) or &quot;Official PDF in use&quot;. Its notes say what the form is for and which boxes are left blank on purpose.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Press <b class="gd-ui">Download a filled preview</b> for one car and check each value against the form.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Change a field if needed: What goes in it (or &quot;Signed here by hand, in ink&quot;), a Format (for example YYYY/MM/DD) and Only when. Press Save the mapping.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t">Press <b class="gd-ui">Checked: use for owners</b>. Every owner&#39;s form of that kind is filled again, except ones already signed or filed. Owners download it, print it and sign it in ink; record it with <b class="gd-ui">Record paper signature</b>. Each form not checked yet is also a line on To do with the same button and Preview it.</div></li><li><span class="gd-n" aria-hidden="true">5</span><div class="gd-t">A new version from ServiceOntario? Press <b class="gd-ui">Upload the official fillable PDF</b>: the fields of the same name keep their mapping.</div></li></ol></div><aside class="gd-box"><span class="gd-lbl">Good to know</span><div>SR-LV-006 (registration), SR-LV-012 (two registrants), ON00453 (a company&#39;s RIN), 013-1155 and 013-0169 (the tax-exempt transfer into an owner&#39;s corporation). 013-1155 is sworn before a commissioner, so it is printed and signed in person. ON00453 is an Adobe form: it opens in Adobe Acrobat Reader. Each form&#39;s notes list what to tick or choose at the counter.</div></aside></section><section class="gd-task" id="settings-blind-spot-rental-agreement" data-gd-task><h2 class="gd-h2">Blind Spot rental agreement</h2><p class="gd-p">We rent under Blind Spot Car Rental&#39;s insurance, so every booking has two agreements: CarmaCars&#39; rental agreement and Blind Spot&#39;s own. Blind Spot&#39;s is filled in from the booking, the renter and the car, and the renter signs both with one signature. Its PDF is stored privately, never on the website.</p><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">Open <b class="gd-ui">Settings</b> &gt; <b class="gd-ui">Forms</b>. The Blind Spot Car Rental agreement card is first. Press <b class="gd-ui">Upload Blind Spot&#39;s PDF</b> and choose Blind Spot&#39;s blank form (2 pages, A4).</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Press <b class="gd-ui">Download the filled sample</b>: a made-up booking on the form. <b class="gd-ui">Sample billed to an insurer</b> also fills the claim number, the adjuster and the insurance company. Check every box.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">On the form the old address (top left and twice in box 15) is replaced by the mailing address of Site settings, box 1 by CarmaCars&#39; HST number (Program settings, Company HST number; blank until it is entered), and box 21 has the representative&#39;s signature instead of Sam&#39;s.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t">Press <b class="gd-ui">Checked: use for bookings</b>. From then on each booking gets it when its rental agreement is made; a renter whose agreement is already open gets it the next time they open the signing page.</div></li><li><span class="gd-n" aria-hidden="true">5</span><div class="gd-t">Box 21: Ahmad is written in a script hand, as Blind Spot asked. To use a real signature instead, upload a PNG under Authorized company representative; Remove the image goes back to the written name. Full name is for the signature record page.</div></li><li><span class="gd-n" aria-hidden="true">6</span><div class="gd-t">A new version of Blind Spot&#39;s form? Upload it the same way: it waits for <b class="gd-ui">Checked: use for bookings</b>, and bookings keep the version in use until then.</div></li></ol></div><aside class="gd-box"><span class="gd-lbl">Good to know</span><div>Each box is filled only when the booking has the value: the renter and their licence, the additional drivers, the car (plate, make and model, the fleet number as vehicle number), the pickup as time and date out, the due-back date and time, the kilometres allowed, the daily rate and the rental charge, the underage fee, the Protection Plan as CDW, winter tires, the subtotal, HST, total and deposit, and for a booking billed to an insurer the insurer, claim number and adjuster. Other charges, such as delivery, are listed in box 14. Initials, fuel and the boxes filled at return stay blank.</div></aside><p class="gd-p">The renter&#39;s signature goes in boxes 16, 17 and 20 of the signed copy, with a signature record page. Both agreements are in the booking&#39;s Drivers and documents tab, in the renter&#39;s Documents, and the signed Blind Spot agreement is attached to the &quot;Your signed rental agreement&quot; email. Admin &gt; Today lists the HST number, the upload and the check until they are done.</p></section><section class="gd-task" id="settings-agreements-to-sign-investors-and-staff" data-gd-task><h2 class="gd-h2">Agreements to sign: investors and staff</h2><p class="gd-p">Investment agreements and staff agreements are made from the person&#39;s record and signed in their own portal, or on paper.</p><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">Investor: open <b class="gd-ui">People</b> &gt; <b class="gd-ui">Investors</b> and the investor. Under Investment agreement, press <b class="gd-ui">Send the agreement to sign</b>. Check the values it is filled with (amount, yearly percentage, dates, exemption) and press <b class="gd-ui">Send to sign</b>.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Once the investor signs, the agreement shows <b class="gd-ui">Awaiting countersignature</b> on the investor&#39;s page and on To do. It is not countersigned automatically: check it and press <b class="gd-ui">Countersign</b>. CarmaCars is bound once it has countersigned and the funds clear.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Staff: open <b class="gd-ui">People</b> &gt; <b class="gd-ui">Staff</b>. Under Staff agreements, press <b class="gd-ui">Send the agreement to sign</b> beside the person. Pay, schedule, hours and the other values start from the staff profile and the defaults of their function in Program settings; change any before sending. For Sales the Pay is Commission only: the agreement then has no rate, schedule or hours, and pays the commission of section 3.4.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t">A field staff member&#39;s agreement prints the home address they entered themselves. Staff enter their home address at their first sign-in, before they sign, or in their profile.</div></li><li><span class="gd-n" aria-hidden="true">5</span><div class="gd-t">They get a notice, check the key values and sign in their portal in a few taps (their name is the signature, or they draw it). The signed copy is filed with their documents.</div></li><li><span class="gd-n" aria-hidden="true">6</span><div class="gd-t">Your own PDF instead? <b class="gd-ui">Send a PDF to sign</b> still works.</div></li><li><span class="gd-n" aria-hidden="true">7</span><div class="gd-t">Signed on paper instead? Press <b class="gd-ui">Record paper signature</b> in the same place and upload the scan.</div></li><li><span class="gd-n" aria-hidden="true">8</span><div class="gd-t">Sent by mistake? Press <b class="gd-ui">Withdraw</b> and give the reason.</div></li></ol></div></section><section class="gd-task" id="settings-the-user-guides" data-gd-task><h2 class="gd-h2">The user guides</h2><p class="gd-p"><b class="gd-ui">Settings</b> &gt; <b class="gd-ui">Guides</b>. The guide of each portal, as people read it under Guide.</p><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">Each guide shows its version, when it was published and whether there are unpublished changes.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Open a guide and press a section. Change its text and press <b class="gd-ui">Show the preview</b> to see it as people will. Press <b class="gd-ui">Save the draft</b>; each save is kept in the section&#39;s history.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Move a section with the arrows, hide it, or press <b class="gd-ui">Add a chapter</b>. Upload a screenshot under Screenshots and paste the line it gives you.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t">Press <b class="gd-ui">Publish version</b> (the next number). The portals show the new version at once.</div></li><li><span class="gd-n" aria-hidden="true">5</span><div class="gd-t">The stored PDF is printed again by the guides-pdf workflow. Until then the guide says the web guide has newer edits.</div></li></ol></div></section><section class="gd-task" id="settings-the-guides-keep-up-by-themselves" data-gd-task><h2 class="gd-h2">The guides keep up by themselves</h2><p class="gd-p">After every update of the site that changes the portals, the guides are checked without anyone asking.</p><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">Every screenshot is taken again on the new version of the site. One whose screen changed replaces the old one in the guide.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">The text of each section whose screen changed, or that names a button the portals no longer show, is rewritten from the portal&#39;s own labels and menu, checked, and published. The PDFs of those guides are printed again.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Such a section says <b class="gd-ui">Changed automatically on</b> and the date, in the list of guides and in the guide&#39;s editor. Not right? Open the section and press <b class="gd-ui">Revert</b>: the text it replaced comes back, published at once.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t">This includes sections you edited: the newest automatic text is published, and every earlier version stays in the section&#39;s history. There is nothing to review.</div></li><li><span class="gd-n" aria-hidden="true">5</span><div class="gd-t">A rewrite that does not pass the checks is asked again, more strictly. If it still does not pass, the screenshots and button names are updated, the rest of the text stays as it was, and the next run tries again.</div></li></ol></div><aside class="gd-box"><span class="gd-lbl">Tip</span><div>The card &quot;The guides keep up by themselves&quot; at the top of Guides lists the last runs: when, how many screenshots were replaced, how many sections were rewritten, and how many PDFs were printed.</div></aside></section><section class="gd-task" id="settings-insurers-and-the-other-lists" data-gd-task><h2 class="gd-h2">Insurers and the other lists</h2><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">Open Insurers. Each insurer on file opens to edit its billing contact, email, phone, address and notes.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">To add one, fill in the Add form (Name, Billing contact, Billing email and the rest) and press <b class="gd-ui">Add</b>.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Deposit tiers, Kilometre choices, Vehicle classes, Airports, Promo codes and Quick replies work the same way.</div></li></ol></div></section>');
-- GUIDES 0127 END
