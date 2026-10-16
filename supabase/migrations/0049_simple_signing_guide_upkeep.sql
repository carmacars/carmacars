-- 0049_simple_signing_guide_upkeep.sql
-- Simple signing, partner insurance reminders and guide upkeep (docs/changes/2026-10-16-supply-manual-rentals-signing.md).
--
--   1. partner insurance: the daily check raises an Admin task when a partner's insurance expires within the warning
--      days of the settings (or has expired, or has no expiry on file while the partner has cars), once per expiry date.
--   2. signing packages: one signature for several documents. Each document keeps its own signature record (time, IP
--      address, device, the SHA-256 of the document signed, its consent text), exactly as when it was signed alone;
--      the package adds the evidence that one signature was given for all of them, which documents they were, the
--      consent shown for each, and how long the signer took from opening the page.
--   3. the signer's own checklist (owner portal): what is signed and what is left, for "2 of 3 signed".
--   4. agreements generated from the records: an investor's investment agreement and a staff member's agreement are
--      rendered from docs/source (filled from the investor's investment, or the staff profile and the settings'
--      defaults) and sent to sign in one click; uploading a PDF stays possible.
--   5. guide upkeep: a screenshot that changed replaces the old one in every draft and published copy of the guides, the
--      sections that show it are flagged "needs review" with the old and new image, an Admin can ask Workers AI for a
--      suggested text, and approves it (or marks the section reviewed).
-- No earlier migration is edited; changed functions are wrapped (renamed with the migration they came from).

-- ================================================================ 1. partner insurance reminders
alter function app.notify_daily_checks(timestamptz) rename to notify_daily_checks_0023;
create or replace function app.notify_daily_checks(p_now timestamptz default now()) returns integer
language plpgsql security definer set search_path = public, app as $$
declare
  v_n integer := app.notify_daily_checks_0023(p_now);
begin
  return v_n + app.partner_insurance_check(p_now);
end $$;

-- One Admin task per partner and expiry date (or per missing expiry): never raised again once done for that date.
create or replace function app.partner_insurance_check(p_now timestamptz default now()) returns integer
language plpgsql security definer set search_path = public, app as $$
declare
  v_today date := app.local_date(p_now);
  v_warn integer := (app.settings(v_today)).partner_insurance_warn_days;
  r record;
  v_key text;
  v_n integer := 0;
begin
  for r in select p.id, p.business_name, p.insurance_expiry, p.insurance_company, p.owner_id
             from partners p
            where p.status = 'active'
              and exists (select 1 from vehicles v where v.partner_id = p.id and v.retired_at is null and v.status not in ('exited', 'declined'))
              and (p.insurance_expiry is null or p.insurance_expiry <= v_today + v_warn) loop
    v_key := 'partner_insurance:' || r.id || ':' || coalesce(r.insurance_expiry::text, 'none');
    continue when exists (select 1 from tasks t where t.dedupe_key = v_key);
    perform app.raise_task(p_type => 'partner_insurance', p_queue => 'admin', p_priority => case when r.insurance_expiry is null or r.insurance_expiry < v_today then 'high' else 'normal' end,
      p_title => case when r.insurance_expiry is null then format('Ask %s for their insurance: no expiry on file', r.business_name)
                      when r.insurance_expiry < v_today then format('%s''s insurance expired %s: get the new certificate', r.business_name, app.fmt_day(r.insurance_expiry))
                      else format('%s''s insurance expires %s: ask for the renewal', r.business_name, app.fmt_day(r.insurance_expiry)) end,
      p_detail => 'Partner rental companies insure their own cars. Record the new company, policy and expiry on the partner''s page (Admin > Partners) and upload the certificate.',
      p_owner => r.owner_id, p_related_table => 'partners', p_related_id => r.id, p_dedupe => v_key,
      p_due_at => app.local_midnight(coalesce(least(r.insurance_expiry, v_today + 7), v_today + 1)));
    v_n := v_n + 1;
  end loop;
  return v_n;
end $$;

-- A new expiry saved on the partner closes the open reminder of the old one.
create or replace function app.partners_insurance_resolve() returns trigger
language plpgsql security definer set search_path = public, app as $$
begin
  if new.insurance_expiry is distinct from old.insurance_expiry then
    update tasks set status = 'done', completed_at = now(), completion_note = 'New insurance expiry recorded'
     where related_table = 'partners' and related_id = new.id and task_type = 'partner_insurance' and status in ('open', 'in_progress', 'waiting');
  end if;
  return new;
end $$;
create trigger partners_insurance_resolve after update of insurance_expiry on partners for each row execute function app.partners_insurance_resolve();

-- ================================================================ 2. signing packages
create table signing_packages (
  id               uuid primary key default gen_random_uuid(),
  signer_user_id   uuid not null references users (id),
  portal           text not null check (portal in ('owner', 'partner', 'renter', 'investor', 'staff')),
  signer_name      text not null,
  method           text not null check (method in ('typed', 'drawn')),
  consent_text     text not null,
  ip_address       inet,
  user_agent       text,
  seconds_to_sign  integer check (seconds_to_sign is null or seconds_to_sign >= 0),
  signed_at        timestamptz not null default now(),
  created_at       timestamptz not null default now()
);
comment on table signing_packages is 'One signature given once for several documents (0049). Each document keeps its own signature record; signing_package_documents links them.';
comment on column signing_packages.seconds_to_sign is 'From opening the signing page to pressing Sign, as the browser measured it (the "under a minute" target)';
create index signing_packages_signer_idx on signing_packages (signer_user_id, signed_at desc);

create table signing_package_documents (
  id                   bigint generated always as identity primary key,
  package_id           uuid not null references signing_packages (id) on delete cascade,
  signature_request_id uuid not null references signature_requests (id),
  signature_record_id  uuid not null references signature_records (id),
  title                text not null,
  document_sha256      text not null check (document_sha256 ~ '^[0-9a-f]{64}$'),
  consent_text         text not null,
  unique (package_id, signature_record_id)
);
comment on table signing_package_documents is 'Each document of a signing package (0049): its own signature record, the document''s SHA-256 and the consent shown for it.';
create index signing_package_documents_request_idx on signing_package_documents (signature_request_id);

-- The server records the package after each document was signed (the documents' own functions recorded each signature).
-- p: {portal, consent_text, method, ip, user_agent, seconds_to_sign, documents: [{signature_request_id, title, consent_text}]}.
-- Each document must carry a signature by this person from the last half hour, with the method of the package.
create or replace function app.signing_package_record(p_by uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  v_id uuid;
  d jsonb;
  rec signature_records;
  v_name text;
  v_n integer := 0;
begin
  if jsonb_typeof(p -> 'documents') is distinct from 'array' or jsonb_array_length(p -> 'documents') = 0 then
    raise exception 'No documents in the package' using errcode = '22023';
  end if;
  if coalesce(p ->> 'method', '') not in ('typed', 'drawn') then raise exception 'Unknown signing method' using errcode = '22023'; end if;
  for d in select value from jsonb_array_elements(p -> 'documents') loop
    select * into rec from signature_records r
     where r.signature_request_id = (d ->> 'signature_request_id')::uuid and r.signer_user_id = p_by and r.status = 'signed'
       and r.method = p ->> 'method' and r.signed_at > now() - interval '30 minutes'
     order by r.signed_at desc limit 1;
    if rec.id is null then raise exception 'A document of the package has no signature from you yet' using errcode = '23514'; end if;
    v_name := coalesce(v_name, rec.signer_name);
    if v_id is null then
      insert into signing_packages (signer_user_id, portal, signer_name, method, consent_text, ip_address, user_agent, seconds_to_sign)
      values (p_by, p ->> 'portal', rec.signer_name, p ->> 'method', coalesce(nullif(btrim(p ->> 'consent_text'), ''), 'One signature for every document listed'),
              nullif(p ->> 'ip', '')::inet, left(p ->> 'user_agent', 400), nullif(p ->> 'seconds_to_sign', '')::integer)
      returning id into v_id;
    end if;
    insert into signing_package_documents (package_id, signature_request_id, signature_record_id, title, document_sha256, consent_text)
    values (v_id, rec.signature_request_id, rec.id, coalesce(nullif(btrim(d ->> 'title'), ''), 'Document'), coalesce(rec.document_sha256,
            (select x.document_sha256 from signature_records x where x.signature_request_id = rec.signature_request_id and x.document_sha256 is not null limit 1)),
            coalesce(nullif(btrim(d ->> 'consent_text'), ''), rec.consent_text, p ->> 'consent_text'))
    on conflict do nothing;
    v_n := v_n + 1;
  end loop;
  insert into audit_log (actor_user_id, action, entity_table, entity_id, after)
  values (p_by, 'signing_package', 'signing_packages', v_id::text, jsonb_build_object('documents', v_n, 'portal', p ->> 'portal', 'seconds_to_sign', p ->> 'seconds_to_sign'));
  return jsonb_build_object('id', v_id, 'documents', v_n, 'signer_name', v_name);
end $$;

-- Admin: the packages signed, newest first (owner, investor or staff page), with their documents.
create or replace function app.signing_packages_for(p_by uuid, p_user uuid) returns jsonb
language plpgsql stable security definer set search_path = public, app as $$
begin
  perform app.assert_admin(p_by);
  return coalesce((select jsonb_agg(jsonb_build_object('id', k.id, 'portal', k.portal, 'signer_name', k.signer_name, 'method', k.method, 'signed_at', k.signed_at,
           'seconds_to_sign', k.seconds_to_sign, 'ip_address', host(k.ip_address),
           'documents', (select jsonb_agg(jsonb_build_object('title', d.title, 'sha256', d.document_sha256) order by d.id) from signing_package_documents d where d.package_id = k.id))
           order by k.signed_at desc)
         from signing_packages k where k.signer_user_id = p_user), '[]'::jsonb);
end $$;

-- ================================================================ 3. the signer's own checklist (owner portal)
-- What the owner (or partner) signs, from 0044's list for Admins, with the partner agreement for a partner. Items not
-- needed are left out; payments are left out (they have their own pages).
create or replace function app.my_signing_checklist(p_by uuid) returns jsonb
language plpgsql stable security definer set search_path = public, app as $$
declare
  v_owner uuid := (select o.id from owners o join users u on u.id = o.user_id join user_roles r on r.user_id = u.id and r.role = 'owner'
                    where o.user_id = p_by and u.status = 'active' order by o.created_at limit 1);
  o owners;
  p partners;
  v_items jsonb := '[]'::jsonb;
begin
  if v_owner is null then return jsonb_build_object('items', v_items, 'done', 0, 'total', 0); end if;
  select * into o from owners where id = v_owner;
  if o.kind = 'partner' then
    select * into p from partners where owner_id = o.id;
    v_items := jsonb_build_array(jsonb_build_object('code', 'partner_agreement', 'label', 'Partner agreement', 'status', case when p.agreement_status = 'signed' then 'done' else 'open' end,
      'method', p.agreement_method, 'date', app.local_date(p.agreement_signed_at), 'how', 'screen'));
  else
    select coalesce(jsonb_agg(i || jsonb_build_object('how', case when i ->> 'code' in ('form_c', 'form_d') then 'paper'
                                                                  when i ->> 'code' = 'debit_agreement' then 'banking'
                                                                  when i ->> 'code' = 'registry_form' then 'registry' else 'screen' end)
                              order by ord), '[]'::jsonb)
      into v_items
      from jsonb_array_elements(app.owner_signables(o.id)) with ordinality t(i, ord)
     where i ->> 'group' = 'sign' and i ->> 'status' <> 'not_needed';
  end if;
  return jsonb_build_object('items', v_items,
    'done', (select count(*) from jsonb_array_elements(v_items) i where i ->> 'status' = 'done'),
    'total', jsonb_array_length(v_items));
end $$;

-- ================================================================ 4. agreements generated from the records
alter table program_settings
  add column staff_agreement_defaults jsonb not null default
    '{"va": {"country": "Philippines", "currency": "USD", "rate": "", "coverage": "Monday to Friday, 9:00 to 17:00", "hours_per_week": "40", "platform": "OnlineJobs.ph", "pay_timing": "every two weeks", "trial_days": "30"},
      "field": {"wage": "", "vehicle_types": "Cars, SUVs and minivans in the CarmaCars fleet", "pay_dates": "every two weeks", "licence_years": "3"}}'::jsonb
    check (jsonb_typeof(staff_agreement_defaults) = 'object');
comment on column program_settings.staff_agreement_defaults is 'What a staff agreement generated from the record starts with where the staff profile has no value (0049): VA {country, currency, rate, coverage, hours_per_week, platform, pay_timing, trial_days}, Field {wage, vehicle_types, pay_dates, licence_years}. The Admin sees and can change each value before sending.';

-- An investor's agreement, prepared: the facts of the investor and their first investment, and the agreement number
-- (a draft agreement is made when there is none yet, as sending does).
create or replace function app.investor_agreement_prepare(p_by uuid, p_investor uuid) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  inv investors;
  a investment_agreements;
  s program_settings := app.settings();
begin
  perform app.assert_admin(p_by);
  select * into inv from investors where id = p_investor;
  if inv.id is null then raise exception 'Investor not found' using errcode = 'P0002'; end if;
  select * into a from investment_agreements where investor_id = inv.id and status in ('draft', 'sent', 'signed') order by created_at desc limit 1;
  if a.status = 'signed' then raise exception 'The agreement of % is already signed', inv.legal_name using errcode = '23514'; end if;
  if a.id is null then
    insert into investment_agreements (investor_id, agreement_number, status)
    values (inv.id, 'IA-' || nextval('investment_agreement_number_seq'), 'draft') returning * into a;
  end if;
  return jsonb_build_object(
    'investor', jsonb_build_object('id', inv.id, 'legal_name', inv.legal_name, 'investor_type', inv.investor_type, 'address', inv.address, 'email', inv.email,
                                   'phone', inv.phone, 'tax_resident_canada', inv.tax_resident_canada, 'tax_country', inv.tax_country, 'has_portal', inv.user_id is not null),
    'agreement_number', a.agreement_number,
    'investments', coalesce((select jsonb_agg(jsonb_build_object('principal_cents', i.principal_cents, 'yearly_bps', i.yearly_bps, 'investment_date', i.investment_date,
                                   'lockup_end_date', i.lockup_end_date, 'is_initial', i.is_initial) order by i.is_initial desc, i.investment_date)
                              from investments i where i.investor_id = inv.id and i.status not in ('cancelled', 'transferred')), '[]'::jsonb),
    'terms', jsonb_build_object('min_cents', s.investor_min_cents, 'lockup_months', s.investor_lockup_months),
    'company', jsonb_build_object('legal_name', s.company_legal_name, 'brand', coalesce(s.company_trade_name, 'CarmaCars'), 'address', s.company_address,
                                  'email', s.company_email, 'phone', s.company_phone, 'signing_officer_name', s.signing_officer_name, 'signing_officer_title', s.signing_officer_title));
end $$;

-- A staff member's agreement, prepared: the person, the staff profile and the settings' defaults.
create or replace function app.staff_agreement_prepare(p_by uuid, p_user uuid) returns jsonb
language plpgsql stable security definer set search_path = public, app as $$
declare
  u users;
  sp staff_profiles;
  s program_settings := app.settings();
begin
  perform app.assert_admin(p_by);
  select * into u from users where id = p_user;
  select * into sp from staff_profiles where user_id = p_user;
  if u.id is null or sp.user_id is null then raise exception 'Staff member not found' using errcode = 'P0002'; end if;
  return jsonb_build_object(
    'staff', jsonb_build_object('user_id', u.id, 'full_name', coalesce(u.full_name, u.email), 'email', u.email, 'phone', u.phone, 'staff_type', sp.staff_type,
                                'va_function', sp.va_function, 'field_function', sp.field_function, 'started_on', sp.started_on, 'referral_code', sp.referral_code,
                                'single_limit_cents', sp.single_limit_cents, 'dual_approval_threshold_cents', sp.dual_approval_threshold_cents,
                                'has_signed', exists (select 1 from sign_requests r where r.staff_user_id = u.id and r.doc_type = 'staff_agreement' and r.status = 'signed')),
    'defaults', coalesce(s.staff_agreement_defaults -> (case when sp.staff_type = 'va' then 'va' else 'field' end), '{}'::jsonb),
    'company', jsonb_build_object('legal_name', s.company_legal_name, 'brand', coalesce(s.company_trade_name, 'CarmaCars'), 'address', s.company_address,
                                  'email', s.company_email, 'phone', s.company_phone, 'signing_officer_name', s.signing_officer_name, 'signing_officer_title', s.signing_officer_title));
end $$;

-- 0044's send, with the template version and what a generated agreement records (generated, its summary of the filled
-- values shown before signing, and the Schedule A values the Admin confirmed).
alter function app.sign_request_create(uuid, jsonb) rename to sign_request_create_0044;
create or replace function app.sign_request_create(p_by uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  v_out jsonb := app.sign_request_create_0044(p_by, p);
begin
  if nullif(p ->> 'template_version', '') is not null or jsonb_typeof(p -> 'extra') = 'object' then
    update sign_requests set template_version = coalesce(nullif(p ->> 'template_version', ''), template_version),
           extra = extra || coalesce(case when jsonb_typeof(p -> 'extra') = 'object' then p -> 'extra' end, '{}'::jsonb)
     where id = (v_out ->> 'id')::uuid;
  end if;
  return v_out;
end $$;

-- ================================================================ 5. guide upkeep
alter table guide_sections
  add column needs_review      boolean not null default false,
  add column review_note       text,
  add column review_images     jsonb not null default '[]'::jsonb check (jsonb_typeof(review_images) = 'array'),
  add column review_flagged_at timestamptz,
  add column suggestion_md     text check (length(suggestion_md) <= 200000),
  add column suggestion_at     timestamptz,
  add column suggestion_model  text;
comment on column guide_sections.needs_review is 'A screenshot this section shows changed on the last guide upkeep run (0049): read the text against the new image, then mark it reviewed';
comment on column guide_sections.review_images is '[{old_url, new_url, diff, at}] the screenshots that changed in this section';

-- The upkeep run (the guides workflow, through the site's job endpoint): each changed screenshot, already stored in the
-- public bucket. p: {run, images: [{old_url, new_url, storage_key, width, height, bytes, diff, portal}]}. The new image
-- takes the old one's place in every draft and published copy that shows it (a guide whose published copy changed gets
-- a new version, so its PDF shows as older), and the sections are flagged for review.
create or replace function app.guide_upkeep_apply(p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  img jsonb;
  s guide_sections;
  v_old text;
  v_new text;
  v_sections integer := 0;
  v_images integer := 0;
  v_portals text[] := '{}';
begin
  if jsonb_typeof(p -> 'images') is distinct from 'array' then raise exception 'No images' using errcode = '22023'; end if;
  for img in select value from jsonb_array_elements(p -> 'images') loop
    v_old := img ->> 'old_url'; v_new := img ->> 'new_url';
    if coalesce(v_old, '') !~ '^(/|https://)' or coalesce(v_new, '') !~ '^(/|https://)' or v_old = v_new then continue; end if;
    -- an image replaced before is found by its latest address
    insert into guide_images (portal, url, storage_key, alt, width, height, bytes, replaces_url)
    values (nullif(img ->> 'portal', ''), v_new, nullif(img ->> 'storage_key', ''), 'Screenshot retaken by the guide upkeep', nullif(img ->> 'width', '')::integer,
            nullif(img ->> 'height', '')::integer, nullif(img ->> 'bytes', '')::integer, v_old);
    v_images := v_images + 1;
    for s in select * from guide_sections x
              where position(v_old in x.body_md) > 0 or position(v_old in coalesce(x.published_md, '')) > 0 or position(v_old in coalesce(x.published_html, '')) > 0
              for update loop
      update guide_sections
         set body_md = replace(body_md, v_old, v_new),
             published_md = replace(published_md, v_old, v_new),
             published_html = replace(published_html, v_old, v_new),
             needs_review = true, review_flagged_at = now(),
             review_note = 'A screenshot in this section changed: check that the steps and labels still match it.',
             review_images = (select coalesce(jsonb_agg(e), '[]'::jsonb) from jsonb_array_elements(s.review_images) e where e ->> 'new_url' <> v_new)
                             || jsonb_build_array(jsonb_build_object('old_url', v_old, 'new_url', v_new, 'diff', img -> 'diff', 'at', now(), 'run', p ->> 'run'))
       where id = s.id;
      if position(v_old in s.body_md) > 0 then
        insert into guide_section_versions (section_id, version, title, blurb, body_md, is_hidden, published)
        values (s.id, s.draft_version, s.title, s.blurb, replace(s.body_md, v_old, v_new), s.is_hidden, false)
        on conflict (section_id, version, published) do update set body_md = excluded.body_md, saved_at = now();
      end if;
      if position(v_old in coalesce(s.published_html, '')) > 0 then v_portals := array_append(v_portals, s.portal); end if;
      v_sections := v_sections + 1;
    end loop;
  end loop;
  update guides set version = version + 1, published_at = now() where portal = any (v_portals) and version > 0;
  insert into audit_log (action, entity_table, entity_id, after)
  values ('guide_upkeep', 'guides', coalesce(p ->> 'run', 'manual'), jsonb_build_object('images', v_images, 'sections', v_sections, 'portals', to_jsonb(v_portals)));
  return jsonb_build_object('images', v_images, 'sections', v_sections, 'portals', to_jsonb((select array_agg(distinct x) from unnest(v_portals) x)));
end $$;

-- A suggested text from Workers AI (made by the server for an Admin who asked), kept beside the draft until approved.
create or replace function app.guide_suggestion_record(p_by uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
begin
  perform app.assert_admin(p_by);
  if length(coalesce(p ->> 'body_md', '')) < 10 then raise exception 'The suggestion is empty' using errcode = '22023'; end if;
  update guide_sections set suggestion_md = p ->> 'body_md', suggestion_at = now(), suggestion_model = left(p ->> 'model', 120)
   where id = (p ->> 'id')::uuid;
  if not found then raise exception 'Section not found' using errcode = 'P0002'; end if;
  return jsonb_build_object('id', p ->> 'id', 'suggestion_at', now());
end $$;

-- The Admin's answer: apply the suggestion (it becomes the draft, published with the next publish), or mark reviewed.
create or replace function app.guide_review_resolve(p_by uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  s guide_sections;
begin
  perform app.assert_admin(p_by);
  select * into s from guide_sections where id = (p ->> 'id')::uuid for update;
  if s.id is null then raise exception 'Section not found' using errcode = 'P0002'; end if;
  if p ->> 'action' = 'apply_suggestion' then
    if s.suggestion_md is null then raise exception 'There is no suggestion to apply' using errcode = '23514'; end if;
    perform app.guide_section_save(p_by, jsonb_build_object('id', s.id, 'body_md', s.suggestion_md));
  elsif coalesce(p ->> 'action', '') not in ('reviewed', 'dismiss_suggestion') then
    raise exception 'Unknown action' using errcode = '22023';
  end if;
  if p ->> 'action' = 'dismiss_suggestion' then
    update guide_sections set suggestion_md = null, suggestion_at = null, suggestion_model = null where id = s.id;
  else
    update guide_sections set needs_review = false, review_note = null, review_images = '[]'::jsonb, suggestion_md = null, suggestion_at = null, suggestion_model = null
     where id = s.id;
  end if;
  insert into audit_log (actor_user_id, action, entity_table, entity_id, after)
  values (p_by, 'guide_review_' || (p ->> 'action'), 'guide_sections', s.id::text, jsonb_build_object('portal', s.portal, 'slug', s.slug));
  return (select jsonb_build_object('id', x.id, 'needs_review', x.needs_review, 'draft_version', x.draft_version) from guide_sections x where x.id = s.id);
end $$;

-- 0044's reads with the review state: each section's flag, images and suggestion; each guide's count to review.
alter function app.guide_admin(uuid, text) rename to guide_admin_0044;
create or replace function app.guide_admin(p_by uuid, p_portal text) returns jsonb
language sql stable security definer set search_path = public, app as $$
  select r || jsonb_build_object('sections', coalesce((
      select jsonb_agg(x || coalesce((select jsonb_build_object('needs_review', s.needs_review, 'review_note', s.review_note, 'review_images', s.review_images,
                                                               'review_flagged_at', s.review_flagged_at, 'suggestion_md', s.suggestion_md, 'suggestion_at', s.suggestion_at,
                                                               'suggestion_model', s.suggestion_model)
                                        from guide_sections s where s.id = (x ->> 'id')::uuid), '{}'::jsonb) order by o)
        from jsonb_array_elements(r -> 'sections') with ordinality t(x, o)), '[]'::jsonb))
    from app.guide_admin_0044(p_by, p_portal) r
$$;

alter function app.guides_admin(uuid) rename to guides_admin_0044;
create or replace function app.guides_admin(p_by uuid) returns jsonb
language sql stable security definer set search_path = public, app as $$
  select coalesce(jsonb_agg(g || jsonb_build_object('needs_review', (select count(*) from guide_sections s where s.portal = g ->> 'portal' and s.needs_review)) order by o), '[]'::jsonb)
    from jsonb_array_elements(app.guides_admin_0044(p_by)) with ordinality t(g, o)
$$;

-- The vision model for a suggested text (an Admin asks, on one section): the same daily allowance as 0042's reads.
alter function app.ai_vision_gate(uuid, text) rename to ai_vision_gate_0042;
create or replace function app.ai_vision_gate(p_by uuid, p_purpose text) returns jsonb
language plpgsql stable security definer set search_path = public, app as $$
declare
  b jsonb;
begin
  if p_purpose is distinct from 'guide_review' then return app.ai_vision_gate_0042(p_by, p_purpose); end if;
  perform app.assert_admin(p_by);
  b := app.ai_vision_budget();
  if not coalesce((b ->> 'enabled')::boolean, false) then
    return b || jsonb_build_object('allowed', false, 'reason', 'The vision model is off in Program settings');
  end if;
  if (b ->> 'all_used')::bigint >= (b ->> 'all_limit')::bigint then
    return b || jsonb_build_object('allowed', false, 'reason', 'Today''s allowance for the vision model is used up; it starts again at midnight, Toronto time');
  end if;
  return b || jsonb_build_object('allowed', true);
end $$;

alter function app.ai_call_record(uuid, jsonb) rename to ai_call_record_0042;
create or replace function app.ai_call_record(p_by uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  v_id uuid;
begin
  if p ->> 'purpose' is distinct from 'guide_review' then return app.ai_call_record_0042(p_by, p); end if;
  perform app.assert_admin(p_by);
  insert into provider_calls (provider, purpose, ok, error, duration_ms, cost_microusd, units, unit)
  values (left(coalesce(p ->> 'model', 'workers-ai'), 120), 'guide_review', coalesce((p ->> 'ok')::boolean, false), left(p ->> 'error', 500),
          greatest(coalesce((p ->> 'duration_ms')::integer, 0), 0), 0, greatest(coalesce((p ->> 'neurons')::integer, 0), 0), 'neurons')
  returning id into v_id;
  return jsonb_build_object('id', v_id);
end $$;

-- The chapters whose text changed with this migration (docs/guides/src, exported to docs/guides/content). A chapter
-- still showing the text CarmaCars shipped (its MD5 matches, no draft waiting) gets the new text, published; a chapter an
-- Admin edited keeps the Admin's text and gets the new one as a suggestion to review. A guide whose published text
-- changed gets a new version once, so its PDF shows as older. A fresh database has no chapters yet: the seed adds them.
create or replace function app.guide_update_published_section(p_portal text, p_slug text, p_old_md5 text, p_title text, p_blurb text,
                                                               p_md text, p_html text) returns text
language plpgsql security definer set search_path = public, app as $$
declare
  s guide_sections;
  v_new integer;
begin
  select * into s from guide_sections where portal = p_portal and slug = p_slug for update;
  if s.id is null then return 'missing'; end if;
  if s.body_md = p_md and s.published_md = p_md then return 'same'; end if;
  if md5(coalesce(s.published_md, '')) = p_old_md5 and s.body_md = s.published_md and s.published_version = s.draft_version then
    v_new := s.draft_version + 1;
    update guide_sections set title = p_title, blurb = p_blurb, body_md = p_md, draft_version = v_new,
           published_title = p_title, published_blurb = p_blurb, published_md = p_md, published_html = p_html, published_version = v_new, published_at = now()
     where id = s.id;
    insert into guide_section_versions (section_id, version, title, blurb, body_md, is_hidden, published)
    select s.id, v_new, p_title, p_blurb, p_md, s.is_hidden, b from (values (false), (true)) v(b)
    on conflict (section_id, version, published) do nothing;
    update guides set version = version + 1, published_at = now() where portal = p_portal and published_at is distinct from now();
    return 'updated';
  end if;
  update guide_sections set needs_review = true, review_flagged_at = now(), suggestion_md = p_md, suggestion_at = now(), suggestion_model = 'CarmaCars (migration 0049)',
         review_note = 'CarmaCars updated this chapter for the new signing, forms and guide features. Your edited text was kept: compare it with the suggested text and use it, or keep yours.'
   where id = s.id;
  return 'suggested';
end $$;
revoke all on function app.guide_update_published_section(text, text, text, text, text, text, text) from public, anon, authenticated;
grant execute on function app.guide_update_published_section(text, text, text, text, text, text, text) to service_role;

-- GUIDES 0049 START (generated by supabase/seed/0049_gen_guides.mjs from docs/guides/content; do not edit by hand)
select app.guide_update_published_section('renter', 'sign-and-pay', 'd4afb41747c9aa7b7e479ccb910740ad', 'Sign and pay', 'Sign the rental agreement on screen and pay with your card.',
  'After you approve, you sign the rental agreement on screen and pay. It takes a few minutes on a phone or a computer; the signing itself is three taps.

## Sign the rental agreement

1. Fill in your home address and licence details. You do this once; we keep them for next time.
2. Press **Save details**. The agreement then shows your details.

![](/guides/img/renter-04-sign-details-desktop-bd193670.jpg "desktop; size: 1440 1052; address: carmacars.ca/account/bookings/CC-10021/sign; pins: 1 44.4 25.9, 2 16.3 96.4")

3. Check the key values at the top: the car, the dates, the deposit and the deductible. Open **Read the full rental agreement** to read it word for word, or press **Download PDF** to keep a copy.
4. Under Sign, tap **All four**: it ticks the four statements, which stay on screen to read.
5. Your full legal name is your signature. Prefer to sign with your finger or the mouse? Press **Draw instead**.
6. Press **Sign and continue to payment**.

![](/guides/img/renter-06-sign-ready-desktop-1eee20a4.jpg "desktop; size: 1440 1212; address: carmacars.ca/account/bookings/CC-10021/sign; pins: 3 59.0 8.9, 4 69.4 18.2, 5 90.3 78.5, 6 96.9 87.1")

## Pay to confirm

1. Check What you pay now. The refundable deposit is taken at pickup, not today.
2. Enter the Name on the card and the card details. Use a credit card in your own name.
3. Press **Pay $...** (the button shows the amount).

![](/guides/img/renter-07-pay-desktop-705896d6.jpg "desktop; size: 1440 1082; address: carmacars.ca/account/bookings/CC-10021/pay; pins: 7 70.5 21.9, 8 64.6 16.5, 9 64.6 96.4")

> Tip: Your card is authorized now and charged once the booking is confirmed. It becomes your Card on File for the deposit at pickup and any later charges you agreed to when you signed.

> Watch out: See "This car was just taken"? Someone confirmed the same car first. The authorization on your card is released, and we offer you another car or other dates.
',
  '<p class="gd-p">After you approve, you sign the rental agreement on screen and pay. It takes a few minutes on a phone or a computer; the signing itself is three taps.</p><section class="gd-task" id="sign-and-pay-sign-the-rental-agreement" data-gd-task><h2 class="gd-h2">Sign the rental agreement</h2><div class="gd-stepblock gd-stepblock--below"><div class="gd-stepcol"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">Fill in your home address and licence details. You do this once; we keep them for next time.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Press <b class="gd-ui">Save details</b>. The agreement then shows your details.</div></li></ol></div><figure class="gd-fig gd-fig--desk"><div class="gd-browser"><div class="gd-bar" aria-hidden="true"><i></i><i></i><i></i><span class="gd-addr">carmacars.ca/account/bookings/CC-10021/sign</span></div><div class="gd-imgwrap" style="aspect-ratio:1440/1052"><img src="/guides/img/renter-04-sign-details-desktop-bd193670.jpg" alt="" loading="lazy" decoding="async" width="1440" height="1052"><span class="gd-pin" style="left:44.4%;top:25.9%" aria-hidden="true">1</span><span class="gd-pin" style="left:16.3%;top:96.4%" aria-hidden="true">2</span></div></div></figure></div><div class="gd-stepblock gd-stepblock--below"><div class="gd-stepcol"><ol class="gd-ol" start="3"><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Check the key values at the top: the car, the dates, the deposit and the deductible. Open <b class="gd-ui">Read the full rental agreement</b> to read it word for word, or press <b class="gd-ui">Download PDF</b> to keep a copy.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t">Under Sign, tap <b class="gd-ui">All four</b>: it ticks the four statements, which stay on screen to read.</div></li><li><span class="gd-n" aria-hidden="true">5</span><div class="gd-t">Your full legal name is your signature. Prefer to sign with your finger or the mouse? Press <b class="gd-ui">Draw instead</b>.</div></li><li><span class="gd-n" aria-hidden="true">6</span><div class="gd-t">Press <b class="gd-ui">Sign and continue to payment</b>.</div></li></ol></div><figure class="gd-fig gd-fig--desk"><div class="gd-browser"><div class="gd-bar" aria-hidden="true"><i></i><i></i><i></i><span class="gd-addr">carmacars.ca/account/bookings/CC-10021/sign</span></div><div class="gd-imgwrap" style="aspect-ratio:1440/1212"><img src="/guides/img/renter-06-sign-ready-desktop-1eee20a4.jpg" alt="" loading="lazy" decoding="async" width="1440" height="1212"><span class="gd-pin" style="left:59%;top:8.9%" aria-hidden="true">3</span><span class="gd-pin" style="left:69.4%;top:18.2%" aria-hidden="true">4</span><span class="gd-pin" style="left:90.3%;top:78.5%" aria-hidden="true">5</span><span class="gd-pin" style="left:96.9%;top:87.1%" aria-hidden="true">6</span></div></div></figure></div></section><section class="gd-task" id="sign-and-pay-pay-to-confirm" data-gd-task><h2 class="gd-h2">Pay to confirm</h2><div class="gd-stepblock gd-stepblock--below"><div class="gd-stepcol"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">Check What you pay now. The refundable deposit is taken at pickup, not today.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Enter the Name on the card and the card details. Use a credit card in your own name.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Press <b class="gd-ui">Pay $...</b> (the button shows the amount).</div></li></ol></div><figure class="gd-fig gd-fig--desk"><div class="gd-browser"><div class="gd-bar" aria-hidden="true"><i></i><i></i><i></i><span class="gd-addr">carmacars.ca/account/bookings/CC-10021/pay</span></div><div class="gd-imgwrap" style="aspect-ratio:1440/1082"><img src="/guides/img/renter-07-pay-desktop-705896d6.jpg" alt="" loading="lazy" decoding="async" width="1440" height="1082"><span class="gd-pin" style="left:70.5%;top:21.9%" aria-hidden="true">7</span><span class="gd-pin" style="left:64.6%;top:16.5%" aria-hidden="true">8</span><span class="gd-pin" style="left:64.6%;top:96.4%" aria-hidden="true">9</span></div></div></figure></div><aside class="gd-box"><span class="gd-lbl">Tip</span><div>Your card is authorized now and charged once the booking is confirmed. It becomes your Card on File for the deposit at pickup and any later charges you agreed to when you signed.</div></aside><aside class="gd-box gd-box--warn"><span class="gd-lbl">Watch out</span><div>See &quot;This car was just taken&quot;? Someone confirmed the same car first. The authorization on your card is released, and we offer you another car or other dates.</div></aside></section>');
select app.guide_update_published_section('renter', 'quick-reference', 'd560cbb3b5cdbe4ce90235424317eeb2', 'Quick reference', 'One page with the essentials.',
  '### Where things are

| Item | What it is for |
| --- | --- |
| **Trips** | Your next step first, then current, upcoming and past trips |
| **Documents** | Agreements, receipts, statements, uploads |
| **Notifications** | Notices and your email choices |
| **Profile** | Contact details, drivers, Card on File |

### Top tasks

1. **Request a car** ›*a car›*Request to book
2. **Approve an offer** ›*Review offer›*Approve and continue
3. **Sign and pay** **All four**, **Sign and continue to payment**, then **Pay $...**
4. **Upload documents** ›*Licence and coverage
5. **Extend or change dates** **Extend** or **Ask to change dates**
6. **Answer a change we suggest** **Review and answer**
7. **Cancel** ›*Cancel booking
8. **Review your trip** **Review your rental**

### If something goes wrong

| What you see | What to do |
| --- | --- |
| **A link says it expired** | Links in our emails work for 24 hours, once. Press **Send me a new link** on that page. |
| **"Error 1102" on a page** | A short limit on our web host. Reload the page. You are still signed in. |
| **"That email and password do not match an account."** | Check the address, or use **Set a new password** on the sign-in page. |
| **"This car was just taken"** | Someone confirmed first. Your card is released; pick from the car or dates we offer. |
| **No confirmation email** | Check spam, then use **Send the confirmation link again** on the sign-in form. |
',
  '<h3 class="gd-h3">Where things are</h3><div class="gd-tablewrap"><table class="gd-table"><thead><tr><th scope="col">Item</th><th scope="col">What it is for</th></tr></thead><tbody><tr><td><b class="gd-ui">Trips</b></td><td>Your next step first, then current, upcoming and past trips</td></tr><tr><td><b class="gd-ui">Documents</b></td><td>Agreements, receipts, statements, uploads</td></tr><tr><td><b class="gd-ui">Notifications</b></td><td>Notices and your email choices</td></tr><tr><td><b class="gd-ui">Profile</b></td><td>Contact details, drivers, Card on File</td></tr></tbody></table></div><h3 class="gd-h3">Top tasks</h3><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t"><b class="gd-ui">Request a car</b> ›*a car›*Request to book</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t"><b class="gd-ui">Approve an offer</b> ›*Review offer›*Approve and continue</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t"><b class="gd-ui">Sign and pay</b> <b class="gd-ui">All four</b>, <b class="gd-ui">Sign and continue to payment</b>, then <b class="gd-ui">Pay $...</b></div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t"><b class="gd-ui">Upload documents</b> ›*Licence and coverage</div></li><li><span class="gd-n" aria-hidden="true">5</span><div class="gd-t"><b class="gd-ui">Extend or change dates</b> <b class="gd-ui">Extend</b> or <b class="gd-ui">Ask to change dates</b></div></li><li><span class="gd-n" aria-hidden="true">6</span><div class="gd-t"><b class="gd-ui">Answer a change we suggest</b> <b class="gd-ui">Review and answer</b></div></li><li><span class="gd-n" aria-hidden="true">7</span><div class="gd-t"><b class="gd-ui">Cancel</b> ›*Cancel booking</div></li><li><span class="gd-n" aria-hidden="true">8</span><div class="gd-t"><b class="gd-ui">Review your trip</b> <b class="gd-ui">Review your rental</b></div></li></ol></div><h3 class="gd-h3">If something goes wrong</h3><div class="gd-tablewrap"><table class="gd-table"><thead><tr><th scope="col">What you see</th><th scope="col">What to do</th></tr></thead><tbody><tr><td><b class="gd-ui">A link says it expired</b></td><td>Links in our emails work for 24 hours, once. Press <b class="gd-ui">Send me a new link</b> on that page.</td></tr><tr><td><b class="gd-ui">&quot;Error 1102&quot; on a page</b></td><td>A short limit on our web host. Reload the page. You are still signed in.</td></tr><tr><td><b class="gd-ui">&quot;That email and password do not match an account.&quot;</b></td><td>Check the address, or use <b class="gd-ui">Set a new password</b> on the sign-in page.</td></tr><tr><td><b class="gd-ui">&quot;This car was just taken&quot;</b></td><td>Someone confirmed first. Your card is released; pick from the car or dates we offer.</td></tr><tr><td><b class="gd-ui">No confirmation email</b></td><td>Check spam, then use <b class="gd-ui">Send the confirmation link again</b> on the sign-in form.</td></tr></tbody></table></div>');
select app.guide_update_published_section('owner', 'apply-and-get-your-car-listed', 'e58087e18ad38c10f8a99b9c224458da', 'Apply and get your car listed', 'Apply online, sign, pay the upfront invoice and get your car on the site.',
  'You apply online in about ten minutes. We reply within one business day, set your terms, and walk you through the rest.

## Apply to list your car

1. Go to `carmacars.ca/list-your-car` and press **Apply to list your car**.
2. About you: individual or corporation, your address, licence and date of birth. Press **Continue to vehicles**.
3. For each car, type the VIN and press **Look up**. Use **Add another vehicle** for more cars.
4. Read how it will work, press **Continue**, then **Review**.
5. Press **Submit application**, then **Go to your owner portal**.

![](/guides/img/public-13-list-your-car-desktop-48bf4cb0.jpg "desktop; size: 1440 800; address: carmacars.ca/list-your-car; pins: 1 20.1 74.9")

> Tip: Need a break? **Email me a link** saves your application and sends you a link to finish later.

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
5. Print Forms C and D (filled in for you), sign them in front of witnesses and take a photo of each page with your phone (see chapter 5).
',
  '<p class="gd-p">You apply online in about ten minutes. We reply within one business day, set your terms, and walk you through the rest.</p><section class="gd-task" id="apply-and-get-your-car-listed-apply-to-list-your-car" data-gd-task><h2 class="gd-h2">Apply to list your car</h2><div class="gd-stepblock gd-stepblock--below"><div class="gd-stepcol"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">Go to <span class="gd-url">carmacars.ca/list-your-car</span> and press <b class="gd-ui">Apply to list your car</b>.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">About you: individual or corporation, your address, licence and date of birth. Press <b class="gd-ui">Continue to vehicles</b>.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">For each car, type the VIN and press <b class="gd-ui">Look up</b>. Use <b class="gd-ui">Add another vehicle</b> for more cars.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t">Read how it will work, press <b class="gd-ui">Continue</b>, then <b class="gd-ui">Review</b>.</div></li><li><span class="gd-n" aria-hidden="true">5</span><div class="gd-t">Press <b class="gd-ui">Submit application</b>, then <b class="gd-ui">Go to your owner portal</b>.</div></li></ol></div><figure class="gd-fig gd-fig--desk"><div class="gd-browser"><div class="gd-bar" aria-hidden="true"><i></i><i></i><i></i><span class="gd-addr">carmacars.ca/list-your-car</span></div><div class="gd-imgwrap" style="aspect-ratio:1440/800"><img src="/guides/img/public-13-list-your-car-desktop-48bf4cb0.jpg" alt="" loading="lazy" decoding="async" width="1440" height="800"><span class="gd-pin" style="left:20.1%;top:74.9%" aria-hidden="true">1</span></div></div></figure></div><aside class="gd-box"><span class="gd-lbl">Tip</span><div>Need a break? <b class="gd-ui">Email me a link</b> saves your application and sends you a link to finish later.</div></aside></section><section class="gd-task" id="apply-and-get-your-car-listed-what-happens-next" data-gd-task><h2 class="gd-h2">What happens next</h2><p class="gd-p">Five steps take your car from your driveway to its first rental.</p><ol class="gd-flow"><li><b>1</b><span>Tell us about the car</span><em>We confirm fees and set your terms</em></li><li><b>2</b><span>Sign the agreements</span><em>Online, one for all your cars</em></li><li><b>3</b><span>One registry visit</span><em>We fill in the forms and come with you</em></li><li><b>4</b><span>Tracker and insurance</span><em>We install it and add the car</em></li><li><b>5</b><span>Photos and listing</span><em>Live within 1 business day</em></li></ol><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">When your terms are ready, Home shows <b class="gd-ui">Check and sign</b>. Everything is filled in from your application: check the short list of key values (each has a <b class="gd-ui">Fix</b> link) and open any document to read it in full.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Tap <b class="gd-ui">All of these</b> for the three confirmations (your initials are filled in), then press <b class="gd-ui">Sign all</b>. Your name on file is your signature; prefer to draw it? Press <b class="gd-ui">Draw instead</b>. One signature covers every document, in about a minute.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Pay the upfront invoice: the first and last month&#39;s insurance fee for each car (see chapter 4).</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t">Upload what each car&#39;s checklist asks for: the ownership permit, the lender&#39;s permission if it is financed or leased, and insurance.</div></li><li><span class="gd-n" aria-hidden="true">5</span><div class="gd-t">Print Forms C and D (filled in for you), sign them in front of witnesses and take a photo of each page with your phone (see chapter 5).</div></li></ol></div></section>');
select app.guide_update_published_section('owner', 'documents-and-forms', '07aa553f8bc742ab3c1caa870ab437c3', 'Documents and forms', 'Agreements, government forms, Forms C and D, and official forms filled for you.',
  'Your signed agreements, uploads and government forms are under Documents. Some forms are filled for you; Forms C and D are signed on paper with witnesses.

## Sign everything at once

Everything you sign on screen is in one place: Home shows how many are signed ("2 of 5 signed") and opens it with Check and sign.

1. Press **Check and sign** on Home (or open `carmacars.ca/owner/sign`). The list at the top shows each document: signed, in this package, or done elsewhere (Forms C and D, the bank debit).
2. Check the key values: your name, address, each car with its VIN and plate, your fees and Revenue Share. Something wrong? Press **Fix** next to it, change it, and come back.
3. Open any document to read it word for word: the agreements, the schedules, Forms A and B, and the official registry forms that are ready.
4. Tap **All of these** for the statements the agreement asks you to initial (your initials are filled in), then press **Sign all**.
5. Your name on file is your signature. One signature is applied to each document; CarmaCars countersigns at once and every signed copy is in Documents.

> Good to know: Form A (the trust declaration) is for cars under the Co-Registrant or Transfer method; Form B (the lease summary) for cars under a Lease method. No witness is needed: they are in the same package. You can also sign one on its own page from Documents.

> Tip: Signed one of your documents on paper instead? Send us the scan. Once we record it, Documents shows it as Signed on paper and we do not ask again.

## Forms C and D, signed with witnesses

Form D is a limited power of attorney (two witnesses). Form C is the lender or lessor permission for a financed or leased car (one witness).

1. Open Documents. Under Forms to sign with witnesses, press **Print the form**. It is filled in, and every spot to sign or initial is marked SIGN HERE or INITIAL HERE.
2. Sign it in front of your witnesses. They sign and print their names in their spots.
3. Type each witness''s full name in the boxes.
4. On your phone, press **Take a photo of the signed page**: one photo of each page. A PDF scan works too (**Or choose a file**).

![](/guides/img/owner-12-forms-c-d-desktop-21fbbe79.jpg "desktop; size: 1440 742; address: carmacars.ca/owner/documents; pins: 1 21.5 32.5, 3 69.4 50.7, 4 69.4 60.4")

> Tip: We check the photo and approve it, or send it back with what to fix. You get an email either way, and the page shows the status.

> Good to know: Why paper for these two? The forms need witnesses who sign in person, and Form D is a power of attorney, which cannot be signed electronically in Ontario.

## Government forms filled for you

Each car''s registry forms are prepared from your records. Until we load the official PDF, you get a data sheet with the values.

1. Open Documents and choose a form marked "Official form, filled for you".
2. Press **Download the filled form** and check each value.
3. To sign it on screen, draw your signature in the box, then press **Sign and save**. Forms ready to sign are also in the package on **Check and sign**, signed with the same one signature. The signed copy is kept with your documents.

![](/guides/img/owner-13-official-form-desktop-48614913.jpg "desktop; size: 1440 732; address: carmacars.ca/owner/documents/forms/e85d4214-54c8-49af-87e0-7776a5901810/official; pins: 2 22.2 29.5, 3 50.0 95.5")

> Watch out: If the registry office asks for an ink signature, print the filled form and sign it there. You pay ServiceOntario, the inspection station and the appraiser directly.
',
  '<p class="gd-p">Your signed agreements, uploads and government forms are under Documents. Some forms are filled for you; Forms C and D are signed on paper with witnesses.</p><section class="gd-task" id="documents-and-forms-sign-everything-at-once" data-gd-task><h2 class="gd-h2">Sign everything at once</h2><p class="gd-p">Everything you sign on screen is in one place: Home shows how many are signed (&quot;2 of 5 signed&quot;) and opens it with Check and sign.</p><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">Press <b class="gd-ui">Check and sign</b> on Home (or open <span class="gd-url">carmacars.ca/owner/sign</span>). The list at the top shows each document: signed, in this package, or done elsewhere (Forms C and D, the bank debit).</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Check the key values: your name, address, each car with its VIN and plate, your fees and Revenue Share. Something wrong? Press <b class="gd-ui">Fix</b> next to it, change it, and come back.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Open any document to read it word for word: the agreements, the schedules, Forms A and B, and the official registry forms that are ready.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t">Tap <b class="gd-ui">All of these</b> for the statements the agreement asks you to initial (your initials are filled in), then press <b class="gd-ui">Sign all</b>.</div></li><li><span class="gd-n" aria-hidden="true">5</span><div class="gd-t">Your name on file is your signature. One signature is applied to each document; CarmaCars countersigns at once and every signed copy is in Documents.</div></li></ol></div><aside class="gd-box"><span class="gd-lbl">Good to know</span><div>Form A (the trust declaration) is for cars under the Co-Registrant or Transfer method; Form B (the lease summary) for cars under a Lease method. No witness is needed: they are in the same package. You can also sign one on its own page from Documents.</div></aside><aside class="gd-box"><span class="gd-lbl">Tip</span><div>Signed one of your documents on paper instead? Send us the scan. Once we record it, Documents shows it as Signed on paper and we do not ask again.</div></aside></section><section class="gd-task" id="documents-and-forms-forms-c-and-d-signed-with-witnesses" data-gd-task><h2 class="gd-h2">Forms C and D, signed with witnesses</h2><p class="gd-p">Form D is a limited power of attorney (two witnesses). Form C is the lender or lessor permission for a financed or leased car (one witness).</p><div class="gd-stepblock gd-stepblock--below"><div class="gd-stepcol"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">Open Documents. Under Forms to sign with witnesses, press <b class="gd-ui">Print the form</b>. It is filled in, and every spot to sign or initial is marked SIGN HERE or INITIAL HERE.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Sign it in front of your witnesses. They sign and print their names in their spots.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Type each witness&#39;s full name in the boxes.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t">On your phone, press <b class="gd-ui">Take a photo of the signed page</b>: one photo of each page. A PDF scan works too (<b class="gd-ui">Or choose a file</b>).</div></li></ol></div><figure class="gd-fig gd-fig--desk"><div class="gd-browser"><div class="gd-bar" aria-hidden="true"><i></i><i></i><i></i><span class="gd-addr">carmacars.ca/owner/documents</span></div><div class="gd-imgwrap" style="aspect-ratio:1440/742"><img src="/guides/img/owner-12-forms-c-d-desktop-21fbbe79.jpg" alt="" loading="lazy" decoding="async" width="1440" height="742"><span class="gd-pin" style="left:21.5%;top:32.5%" aria-hidden="true">1</span><span class="gd-pin" style="left:69.4%;top:50.7%" aria-hidden="true">3</span><span class="gd-pin" style="left:69.4%;top:60.4%" aria-hidden="true">4</span></div></div></figure></div><aside class="gd-box"><span class="gd-lbl">Tip</span><div>We check the photo and approve it, or send it back with what to fix. You get an email either way, and the page shows the status.</div></aside><aside class="gd-box"><span class="gd-lbl">Good to know</span><div>Why paper for these two? The forms need witnesses who sign in person, and Form D is a power of attorney, which cannot be signed electronically in Ontario.</div></aside></section><section class="gd-task" id="documents-and-forms-government-forms-filled-for-you" data-gd-task><h2 class="gd-h2">Government forms filled for you</h2><p class="gd-p">Each car&#39;s registry forms are prepared from your records. Until we load the official PDF, you get a data sheet with the values.</p><div class="gd-stepblock gd-stepblock--below"><div class="gd-stepcol"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">Open Documents and choose a form marked &quot;Official form, filled for you&quot;.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Press <b class="gd-ui">Download the filled form</b> and check each value.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">To sign it on screen, draw your signature in the box, then press <b class="gd-ui">Sign and save</b>. Forms ready to sign are also in the package on <b class="gd-ui">Check and sign</b>, signed with the same one signature. The signed copy is kept with your documents.</div></li></ol></div><figure class="gd-fig gd-fig--desk"><div class="gd-browser"><div class="gd-bar" aria-hidden="true"><i></i><i></i><i></i><span class="gd-addr">carmacars.ca/owner/documents/forms/e85d4214-54c8-49af-87e0-7776a5901810/official</span></div><div class="gd-imgwrap" style="aspect-ratio:1440/732"><img src="/guides/img/owner-13-official-form-desktop-48614913.jpg" alt="" loading="lazy" decoding="async" width="1440" height="732"><span class="gd-pin" style="left:22.2%;top:29.5%" aria-hidden="true">2</span><span class="gd-pin" style="left:50%;top:95.5%" aria-hidden="true">3</span></div></div></figure></div><aside class="gd-box gd-box--warn"><span class="gd-lbl">Watch out</span><div>If the registry office asks for an ink signature, print the filled form and sign it there. You pay ServiceOntario, the inspection station and the appraiser directly.</div></aside></section>');
select app.guide_update_published_section('owner', 'quick-reference', '45987d27ffb07f33d7f9a364d34aa3fc', 'Quick reference', 'One page with the essentials.',
  '### Where things are

| Item | What it is for |
| --- | --- |
| **Home** | Next thing to do, your cars, money, next debit |
| **Vehicles** | Each car: terms, checklist, uploads, photos, Leaving |
| **Bookings** | Calendar, all bookings, Book my own car |
| **Invoices** | Fee invoices and Pay $... |
| **Statements** | One a month, Download PDF |
| **Payouts** | What was paid and when |
| **Documents** | Agreements, forms, Forms C and D |
| **Banking** | Automatic debit, where we pay you |
| **Notifications** | Our messages |
| **Profile** | Contact details, password |

### Top tasks

1. **Sign everything at once** ›*Check and sign
2. **Set up the monthly debit** ›*Set up pre-authorized debit
3. **Pay an invoice now** ›*the invoice›*Pay $...
4. **Payout details** ›*Where we pay you
5. **Forms C and D** ›*Take a photo of the signed page
6. **Book your own car** ›*Book my own car
7. **New listing photos** ›*the car›*Take new photos
8. **Leave the program** ›*the car›*Give notice

### If something goes wrong

| What you see | What to do |
| --- | --- |
| **A link says it expired** | Links in our emails work for 24 hours, once. Press **Send me a new link** on that page. |
| **"Error 1102" on a page** | A short limit on our web host. Reload the page. You are still signed in. |
| **"That email and password do not match an account."** | Check the address, or use **Set a new password** on the sign-in page. |
| **A debit was returned** | You get an email with the reason. Pay the invoice from its page, or keep money in the account for the retry. |
',
  '<h3 class="gd-h3">Where things are</h3><div class="gd-tablewrap"><table class="gd-table"><thead><tr><th scope="col">Item</th><th scope="col">What it is for</th></tr></thead><tbody><tr><td><b class="gd-ui">Home</b></td><td>Next thing to do, your cars, money, next debit</td></tr><tr><td><b class="gd-ui">Vehicles</b></td><td>Each car: terms, checklist, uploads, photos, Leaving</td></tr><tr><td><b class="gd-ui">Bookings</b></td><td>Calendar, all bookings, Book my own car</td></tr><tr><td><b class="gd-ui">Invoices</b></td><td>Fee invoices and Pay $...</td></tr><tr><td><b class="gd-ui">Statements</b></td><td>One a month, Download PDF</td></tr><tr><td><b class="gd-ui">Payouts</b></td><td>What was paid and when</td></tr><tr><td><b class="gd-ui">Documents</b></td><td>Agreements, forms, Forms C and D</td></tr><tr><td><b class="gd-ui">Banking</b></td><td>Automatic debit, where we pay you</td></tr><tr><td><b class="gd-ui">Notifications</b></td><td>Our messages</td></tr><tr><td><b class="gd-ui">Profile</b></td><td>Contact details, password</td></tr></tbody></table></div><h3 class="gd-h3">Top tasks</h3><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t"><b class="gd-ui">Sign everything at once</b> ›*Check and sign</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t"><b class="gd-ui">Set up the monthly debit</b> ›*Set up pre-authorized debit</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t"><b class="gd-ui">Pay an invoice now</b> ›*the invoice›*Pay $...</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t"><b class="gd-ui">Payout details</b> ›*Where we pay you</div></li><li><span class="gd-n" aria-hidden="true">5</span><div class="gd-t"><b class="gd-ui">Forms C and D</b> ›*Take a photo of the signed page</div></li><li><span class="gd-n" aria-hidden="true">6</span><div class="gd-t"><b class="gd-ui">Book your own car</b> ›*Book my own car</div></li><li><span class="gd-n" aria-hidden="true">7</span><div class="gd-t"><b class="gd-ui">New listing photos</b> ›*the car›*Take new photos</div></li><li><span class="gd-n" aria-hidden="true">8</span><div class="gd-t"><b class="gd-ui">Leave the program</b> ›*the car›*Give notice</div></li></ol></div><h3 class="gd-h3">If something goes wrong</h3><div class="gd-tablewrap"><table class="gd-table"><thead><tr><th scope="col">What you see</th><th scope="col">What to do</th></tr></thead><tbody><tr><td><b class="gd-ui">A link says it expired</b></td><td>Links in our emails work for 24 hours, once. Press <b class="gd-ui">Send me a new link</b> on that page.</td></tr><tr><td><b class="gd-ui">&quot;Error 1102&quot; on a page</b></td><td>A short limit on our web host. Reload the page. You are still signed in.</td></tr><tr><td><b class="gd-ui">&quot;That email and password do not match an account.&quot;</b></td><td>Check the address, or use <b class="gd-ui">Set a new password</b> on the sign-in page.</td></tr><tr><td><b class="gd-ui">A debit was returned</b></td><td>You get an email with the reason. Pay the invoice from its page, or keep money in the account for the retry.</td></tr></tbody></table></div>');
select app.guide_update_published_section('admin', 'owners-and-onboarding', 'f7b3cab84783aa4c2161198c2c3854ca', 'Owners and onboarding', 'Applications, terms, an owner''s page, sign-in help and Forms C and D.',
  'Owners apply on the site. You approve them, set their terms, and check their forms. Their page shows everything about them in one place.

## Owner applications

›*Owners

1. Each owner shows their application, how many cars, and where onboarding stands.
2. **View as (owner portal)** shows their portal. **Send password link** helps them sign in.
3. Invite an owner on file: fill in Name and Email under Invite an owner, then press **Send invitation**.

![](/guides/img/admin-12-owners-desktop-3a54d505.jpg "desktop; size: 1440 560; address: carmacars.ca/admin/owners; pins: 1 41.0 42.9, 2 37.4 49.3, 3 77.4 82.5")

## Approve an application and set terms

1. Open the application and press **Approve and set terms** (or **Set terms (standard grid)**).
2. The owner signs everything at once in their portal (Check and sign: the agreements, schedules, Forms A and B and the official forms that are ready, with one signature) and pays the upfront invoice.
3. Paid another way? On the invoice, press **Record payment** (see Paid and signed, below).

## An owner''s page

Open an owner from Owners. The details are in the right-hand column.

1. Upfront invoices: issue the first and last month''s insurance fee for each car whose terms are set.
2. Owner: address, sign-in, agreements, and what is still missing for the registry forms.
3. Statements and payouts for this owner.
4. Forms C and D, with a link to the review queue.
5. Further down: **View as (owner portal)**, **Send password link** and **Send a sign-in link to the owner portal**.

![](/guides/img/admin-13-owner-desktop-819a9f8b.jpg "desktop; size: 410 1030; address: carmacars.ca/admin/owners/628a3315-6335-4e85-a396-f180565d5af5; pins: 1 24.6 4.4, 2 16.1 32.9, 3 31.5 73.2, 4 21.2 98.1")

## Paid and signed

›*Owners, then **Paid and signed**. What each owner still has to pay or sign, and how each item was done.

1. Each owner shows how many items are open and how many are done. Owners with nothing left are hidden; press Show every owner to see them.
2. Open **Checklist and quick actions**. Each line says Signed in the portal, Signed on paper, Paid by e-Transfer, Not signed, and so on.
3. Paid by e-Transfer, cheque, cash or bank transfer? Press **Record payment**. Choose Paid by, the Date received and the Reference (the cheque number for a cheque). Leave Amount empty for the full balance, or type less for a partial payment. Add a photo of the cheque or a screenshot if you have one.
4. Signed on paper? Press **Record paper signature**. Choose the Document, check Signed by and Date signed, add the witnesses where the form needs them, and upload the scan of every signed page.
5. The same checklist sits at the top of each owner''s page.

A recorded payment marks the invoice paid (or partly paid), stops the automatic debit for that amount, sends the owner a receipt, and shows "Paid by e-Transfer on " in their portal. A paper signature counts as signed everywhere: the checklist, onboarding and the owner portal. The scan is kept privately with the owner''s documents.

> Watch out: Recorded the wrong thing, or a cheque bounced? Press **Void** beside it and give the reason. The invoice owes that amount again and the owner is told; a voided signature makes the item open again. Only an Admin can void.

## Forms C and D

›*Owner forms. Owners print them filled in, sign in front of witnesses and send a photo of each page from their phone.

1. Each row shows the owner, the form, the witnesses and when it was uploaded.
2. Press Open to read the photo or scan. Check each marked spot is signed or initialled.
3. Press **Approve**, or **Send back** with What to fix (the owner reads this).

![](/guides/img/admin-22-owner-forms-desktop-c20ad300.jpg "desktop; size: 1440 470; address: carmacars.ca/admin/owner-forms; pins: 1 29.2 52.3, 2 57.6 52.3, 3 76.7 52.3")
',
  '<p class="gd-p">Owners apply on the site. You approve them, set their terms, and check their forms. Their page shows everything about them in one place.</p><section class="gd-task" id="owners-and-onboarding-owner-applications" data-gd-task><h2 class="gd-h2">Owner applications</h2><p class="gd-p">›*Owners</p><div class="gd-stepblock gd-stepblock--below"><div class="gd-stepcol"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">Each owner shows their application, how many cars, and where onboarding stands.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t"><b class="gd-ui">View as (owner portal)</b> shows their portal. <b class="gd-ui">Send password link</b> helps them sign in.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Invite an owner on file: fill in Name and Email under Invite an owner, then press <b class="gd-ui">Send invitation</b>.</div></li></ol></div><figure class="gd-fig gd-fig--desk"><div class="gd-browser"><div class="gd-bar" aria-hidden="true"><i></i><i></i><i></i><span class="gd-addr">carmacars.ca/admin/owners</span></div><div class="gd-imgwrap" style="aspect-ratio:1440/560"><img src="/guides/img/admin-12-owners-desktop-3a54d505.jpg" alt="" loading="lazy" decoding="async" width="1440" height="560"><span class="gd-pin" style="left:41%;top:42.9%" aria-hidden="true">1</span><span class="gd-pin" style="left:37.4%;top:49.3%" aria-hidden="true">2</span><span class="gd-pin" style="left:77.4%;top:82.5%" aria-hidden="true">3</span></div></div></figure></div></section><section class="gd-task" id="owners-and-onboarding-approve-an-application-and-set-terms" data-gd-task><h2 class="gd-h2">Approve an application and set terms</h2><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">Open the application and press <b class="gd-ui">Approve and set terms</b> (or <b class="gd-ui">Set terms (standard grid)</b>).</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">The owner signs everything at once in their portal (Check and sign: the agreements, schedules, Forms A and B and the official forms that are ready, with one signature) and pays the upfront invoice.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Paid another way? On the invoice, press <b class="gd-ui">Record payment</b> (see Paid and signed, below).</div></li></ol></div></section><section class="gd-task" id="owners-and-onboarding-an-owner-s-page" data-gd-task><h2 class="gd-h2">An owner&#39;s page</h2><p class="gd-p">Open an owner from Owners. The details are in the right-hand column.</p><div class="gd-stepblock gd-stepblock--below"><div class="gd-stepcol"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">Upfront invoices: issue the first and last month&#39;s insurance fee for each car whose terms are set.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Owner: address, sign-in, agreements, and what is still missing for the registry forms.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Statements and payouts for this owner.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t">Forms C and D, with a link to the review queue.</div></li><li><span class="gd-n" aria-hidden="true">5</span><div class="gd-t">Further down: <b class="gd-ui">View as (owner portal)</b>, <b class="gd-ui">Send password link</b> and <b class="gd-ui">Send a sign-in link to the owner portal</b>.</div></li></ol></div><figure class="gd-fig gd-fig--desk"><div class="gd-browser"><div class="gd-bar" aria-hidden="true"><i></i><i></i><i></i><span class="gd-addr">carmacars.ca/admin/owners/628a3315-6335-4e85-a396-f180565d5af5</span></div><div class="gd-imgwrap" style="aspect-ratio:410/1030"><img src="/guides/img/admin-13-owner-desktop-819a9f8b.jpg" alt="" loading="lazy" decoding="async" width="410" height="1030"><span class="gd-pin" style="left:24.6%;top:4.4%" aria-hidden="true">1</span><span class="gd-pin" style="left:16.1%;top:32.9%" aria-hidden="true">2</span><span class="gd-pin" style="left:31.5%;top:73.2%" aria-hidden="true">3</span><span class="gd-pin" style="left:21.2%;top:98.1%" aria-hidden="true">4</span></div></div></figure></div></section><section class="gd-task" id="owners-and-onboarding-paid-and-signed" data-gd-task><h2 class="gd-h2">Paid and signed</h2><p class="gd-p">›*Owners, then <b class="gd-ui">Paid and signed</b>. What each owner still has to pay or sign, and how each item was done.</p><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">Each owner shows how many items are open and how many are done. Owners with nothing left are hidden; press Show every owner to see them.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Open <b class="gd-ui">Checklist and quick actions</b>. Each line says Signed in the portal, Signed on paper, Paid by e-Transfer, Not signed, and so on.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Paid by e-Transfer, cheque, cash or bank transfer? Press <b class="gd-ui">Record payment</b>. Choose Paid by, the Date received and the Reference (the cheque number for a cheque). Leave Amount empty for the full balance, or type less for a partial payment. Add a photo of the cheque or a screenshot if you have one.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t">Signed on paper? Press <b class="gd-ui">Record paper signature</b>. Choose the Document, check Signed by and Date signed, add the witnesses where the form needs them, and upload the scan of every signed page.</div></li><li><span class="gd-n" aria-hidden="true">5</span><div class="gd-t">The same checklist sits at the top of each owner&#39;s page.</div></li></ol></div><p class="gd-p">A recorded payment marks the invoice paid (or partly paid), stops the automatic debit for that amount, sends the owner a receipt, and shows &quot;Paid by e-Transfer on &quot; in their portal. A paper signature counts as signed everywhere: the checklist, onboarding and the owner portal. The scan is kept privately with the owner&#39;s documents.</p><aside class="gd-box gd-box--warn"><span class="gd-lbl">Watch out</span><div>Recorded the wrong thing, or a cheque bounced? Press <b class="gd-ui">Void</b> beside it and give the reason. The invoice owes that amount again and the owner is told; a voided signature makes the item open again. Only an Admin can void.</div></aside></section><section class="gd-task" id="owners-and-onboarding-forms-c-and-d" data-gd-task><h2 class="gd-h2">Forms C and D</h2><p class="gd-p">›*Owner forms. Owners print them filled in, sign in front of witnesses and send a photo of each page from their phone.</p><div class="gd-stepblock gd-stepblock--below"><div class="gd-stepcol"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">Each row shows the owner, the form, the witnesses and when it was uploaded.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Press Open to read the photo or scan. Check each marked spot is signed or initialled.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Press <b class="gd-ui">Approve</b>, or <b class="gd-ui">Send back</b> with What to fix (the owner reads this).</div></li></ol></div><figure class="gd-fig gd-fig--desk"><div class="gd-browser"><div class="gd-bar" aria-hidden="true"><i></i><i></i><i></i><span class="gd-addr">carmacars.ca/admin/owner-forms</span></div><div class="gd-imgwrap" style="aspect-ratio:1440/470"><img src="/guides/img/admin-22-owner-forms-desktop-c20ad300.jpg" alt="" loading="lazy" decoding="async" width="1440" height="470"><span class="gd-pin" style="left:29.2%;top:52.3%" aria-hidden="true">1</span><span class="gd-pin" style="left:57.6%;top:52.3%" aria-hidden="true">2</span><span class="gd-pin" style="left:76.7%;top:52.3%" aria-hidden="true">3</span></div></div></figure></div></section>');
select app.guide_update_published_section('admin', 'settings', '5957675b3e080880481b7b3c739cdc19', 'Settings', 'Site, program settings, official forms mapping, insurers and the other lists.',
  'Settings change the public site and the rules of the program at once. Program settings are kept as dated rows, so earlier values stay on record.

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
3. Change a value and press **Save**. It is saved as a new row from today; the rows before stay as they were.

![](/guides/img/admin-25-program-settings-desktop-d16b066c.jpg "desktop; size: 1440 1000; address: carmacars.ca/admin/settings/program; pins: 1 25.8 22.0, 2 27.8 49.0")

## Official ServiceOntario forms

The five official forms are loaded with a draft mapping to the owner, car, company and lender details. Until you check a form, owners get a data sheet with the values.

1. Open ›*Forms. Each form shows "Mapping to check" (a draft is ready) or "Official PDF in use". Its notes say what the form is for and which boxes are left blank on purpose.
2. Press **Download a filled preview** for one car and check each value against the form.
3. Change a field if needed: What goes in it (or "The owner signs here"), a Format (for example YYYY/MM/DD) and Only when. Press Save the mapping.
4. Press **Checked: use for owners**. Every owner''s form of that kind is filled again, except ones already signed or filed, and owners sign it with their other documents.
5. A new version from ServiceOntario? Press **Upload the official fillable PDF**: the fields of the same name keep their mapping.

> Good to know: SR-LV-006 (registration), SR-LV-012 (two registrants), ON00453 (a company''s RIN), 013-1155 and 013-0169 (the tax-exempt transfer into an owner''s corporation). 013-1155 is sworn before a commissioner, so it is printed and signed in person.

## Agreements to sign: investors and staff

Investment agreements and staff agreements are made from the person''s record and signed in their own portal, or on paper.

1. Investor: open ›*Investors and the investor. Under Investment agreement, press **Send the agreement to sign**. Check the values it is filled with (amount, yearly percentage, dates, exemption) and press **Send to sign**.
2. Staff: open ›*Staff and roles. Under Staff agreements, press **Send the agreement to sign** beside the person. Rate, hours and the other values start from the staff profile and Program settings; change any before sending.
3. They get a notice, check the key values and sign in their portal in a few taps (their name is the signature, or they draw it). The signed copy is filed with their documents.
4. Your own PDF instead? **Send a PDF to sign** still works.
5. Signed on paper instead? Press **Record paper signature** in the same place and upload the scan.
6. Sent by mistake? Press **Withdraw** and give the reason.

## The user guides

›*Guides. The guide of each portal, as people read it under Guide.

1. Each guide shows its version, when it was published and whether there are unpublished changes.
2. Open a guide and press a section. Change its text and press **Show the preview** to see it as people will. Press **Save the draft**; each save is kept in the section''s history.
3. Move a section with the arrows, hide it, or press **Add a chapter**. Upload a screenshot under Screenshots and paste the line it gives you.
4. Press **Publish version** (the next number). The portals show the new version at once.
5. The stored PDF is printed again by the guides-pdf workflow. Until then the guide says the web guide has newer edits.

## Keeping the screenshots current

The guides workflow retakes every screenshot and replaces the ones whose screen changed.

1. A guide with screens that changed shows **To review**; the section shows **Needs review** with the screenshot before and now (the new one is already in the guide).
2. Read the text against the new screenshot. Press **Suggest a text update** for a suggestion from Workers AI, then **Use this text as the draft** or **Dismiss the suggestion**.
3. Press **Mark reviewed**, then **Publish version** when the text is right, and run guides-pdf for the PDFs.

## Insurers and the other lists

1. Open Insurers. Each insurer on file opens to edit its billing contact, email, phone, address and notes.
2. To add one, fill in the Add form (Name, Billing contact, Billing email and the rest) and press **Add**.
3. Deposit tiers, Kilometre choices, Vehicle classes, Airports, Promo codes and Quick replies work the same way.
',
  '<p class="gd-p">Settings change the public site and the rules of the program at once. Program settings are kept as dated rows, so earlier values stay on record.</p><section class="gd-task" id="settings-the-settings-page" data-gd-task><h2 class="gd-h2">The Settings page</h2><div class="gd-stepblock gd-stepblock--below"><div class="gd-stepcol"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">Site setup lists what is still missing on the public site, with <b class="gd-ui">Open site settings</b>.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Site settings: contact details, hours, tagline, logo, socials, Google place id and featured cars.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Program settings: every timing and policy value.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t">Forms: the official ServiceOntario PDFs and what goes in each field.</div></li><li><span class="gd-n" aria-hidden="true">5</span><div class="gd-t">Insurers: insurance companies billed for bookings.</div></li></ol></div><figure class="gd-fig gd-fig--desk"><div class="gd-browser"><div class="gd-bar" aria-hidden="true"><i></i><i></i><i></i><span class="gd-addr">carmacars.ca/admin/settings</span></div><div class="gd-imgwrap" style="aspect-ratio:1440/900"><img src="/guides/img/admin-24-settings-desktop-89b31691.jpg" alt="" loading="lazy" decoding="async" width="1440" height="900"><span class="gd-pin" style="left:32.6%;top:33%" aria-hidden="true">1</span><span class="gd-pin" style="left:25.8%;top:40.2%" aria-hidden="true">2</span><span class="gd-pin" style="left:77.4%;top:40.2%" aria-hidden="true">3</span><span class="gd-pin" style="left:25.8%;top:73.2%" aria-hidden="true">4</span><span class="gd-pin" style="left:25.8%;top:84.9%" aria-hidden="true">5</span></div></div></figure></div><p class="gd-p">The other tiles: Site content (headings, FAQs, legal text), Fee defaults, Deposit tiers, Kilometre choices, Vehicle classes, Airports and delivery, Coverage prices, Email aliases and reply-to, Staff and roles, Promo codes and Quick replies.</p></section><section class="gd-task" id="settings-program-settings" data-gd-task><h2 class="gd-h2">Program settings</h2><div class="gd-stepblock gd-stepblock--below"><div class="gd-stepcol"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">Turnaround between trips: the time held between two trips. The cleaning block after a trip is this time.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Settings come in groups such as Company, Booking requests and offers, Owner debits and statement emails, Deposits, Delivery, Owners and fleet, and Tolls and damage. Open one to see its fields.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Change a value and press <b class="gd-ui">Save</b>. It is saved as a new row from today; the rows before stay as they were.</div></li></ol></div><figure class="gd-fig gd-fig--desk"><div class="gd-browser"><div class="gd-bar" aria-hidden="true"><i></i><i></i><i></i><span class="gd-addr">carmacars.ca/admin/settings/program</span></div><div class="gd-imgwrap" style="aspect-ratio:1440/1000"><img src="/guides/img/admin-25-program-settings-desktop-d16b066c.jpg" alt="" loading="lazy" decoding="async" width="1440" height="1000"><span class="gd-pin" style="left:25.8%;top:22%" aria-hidden="true">1</span><span class="gd-pin" style="left:27.8%;top:49%" aria-hidden="true">2</span></div></div></figure></div></section><section class="gd-task" id="settings-official-serviceontario-forms" data-gd-task><h2 class="gd-h2">Official ServiceOntario forms</h2><p class="gd-p">The five official forms are loaded with a draft mapping to the owner, car, company and lender details. Until you check a form, owners get a data sheet with the values.</p><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">Open ›*Forms. Each form shows &quot;Mapping to check&quot; (a draft is ready) or &quot;Official PDF in use&quot;. Its notes say what the form is for and which boxes are left blank on purpose.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Press <b class="gd-ui">Download a filled preview</b> for one car and check each value against the form.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Change a field if needed: What goes in it (or &quot;The owner signs here&quot;), a Format (for example YYYY/MM/DD) and Only when. Press Save the mapping.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t">Press <b class="gd-ui">Checked: use for owners</b>. Every owner&#39;s form of that kind is filled again, except ones already signed or filed, and owners sign it with their other documents.</div></li><li><span class="gd-n" aria-hidden="true">5</span><div class="gd-t">A new version from ServiceOntario? Press <b class="gd-ui">Upload the official fillable PDF</b>: the fields of the same name keep their mapping.</div></li></ol></div><aside class="gd-box"><span class="gd-lbl">Good to know</span><div>SR-LV-006 (registration), SR-LV-012 (two registrants), ON00453 (a company&#39;s RIN), 013-1155 and 013-0169 (the tax-exempt transfer into an owner&#39;s corporation). 013-1155 is sworn before a commissioner, so it is printed and signed in person.</div></aside></section><section class="gd-task" id="settings-agreements-to-sign-investors-and-staff" data-gd-task><h2 class="gd-h2">Agreements to sign: investors and staff</h2><p class="gd-p">Investment agreements and staff agreements are made from the person&#39;s record and signed in their own portal, or on paper.</p><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">Investor: open ›*Investors and the investor. Under Investment agreement, press <b class="gd-ui">Send the agreement to sign</b>. Check the values it is filled with (amount, yearly percentage, dates, exemption) and press <b class="gd-ui">Send to sign</b>.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Staff: open ›*Staff and roles. Under Staff agreements, press <b class="gd-ui">Send the agreement to sign</b> beside the person. Rate, hours and the other values start from the staff profile and Program settings; change any before sending.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">They get a notice, check the key values and sign in their portal in a few taps (their name is the signature, or they draw it). The signed copy is filed with their documents.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t">Your own PDF instead? <b class="gd-ui">Send a PDF to sign</b> still works.</div></li><li><span class="gd-n" aria-hidden="true">5</span><div class="gd-t">Signed on paper instead? Press <b class="gd-ui">Record paper signature</b> in the same place and upload the scan.</div></li><li><span class="gd-n" aria-hidden="true">6</span><div class="gd-t">Sent by mistake? Press <b class="gd-ui">Withdraw</b> and give the reason.</div></li></ol></div></section><section class="gd-task" id="settings-the-user-guides" data-gd-task><h2 class="gd-h2">The user guides</h2><p class="gd-p">›*Guides. The guide of each portal, as people read it under Guide.</p><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">Each guide shows its version, when it was published and whether there are unpublished changes.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Open a guide and press a section. Change its text and press <b class="gd-ui">Show the preview</b> to see it as people will. Press <b class="gd-ui">Save the draft</b>; each save is kept in the section&#39;s history.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Move a section with the arrows, hide it, or press <b class="gd-ui">Add a chapter</b>. Upload a screenshot under Screenshots and paste the line it gives you.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t">Press <b class="gd-ui">Publish version</b> (the next number). The portals show the new version at once.</div></li><li><span class="gd-n" aria-hidden="true">5</span><div class="gd-t">The stored PDF is printed again by the guides-pdf workflow. Until then the guide says the web guide has newer edits.</div></li></ol></div></section><section class="gd-task" id="settings-keeping-the-screenshots-current" data-gd-task><h2 class="gd-h2">Keeping the screenshots current</h2><p class="gd-p">The guides workflow retakes every screenshot and replaces the ones whose screen changed.</p><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">A guide with screens that changed shows <b class="gd-ui">To review</b>; the section shows <b class="gd-ui">Needs review</b> with the screenshot before and now (the new one is already in the guide).</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Read the text against the new screenshot. Press <b class="gd-ui">Suggest a text update</b> for a suggestion from Workers AI, then <b class="gd-ui">Use this text as the draft</b> or <b class="gd-ui">Dismiss the suggestion</b>.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Press <b class="gd-ui">Mark reviewed</b>, then <b class="gd-ui">Publish version</b> when the text is right, and run guides-pdf for the PDFs.</div></li></ol></div></section><section class="gd-task" id="settings-insurers-and-the-other-lists" data-gd-task><h2 class="gd-h2">Insurers and the other lists</h2><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">Open Insurers. Each insurer on file opens to edit its billing contact, email, phone, address and notes.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">To add one, fill in the Add form (Name, Billing contact, Billing email and the rest) and press <b class="gd-ui">Add</b>.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Deposit tiers, Kilometre choices, Vehicle classes, Airports, Promo codes and Quick replies work the same way.</div></li></ol></div></section>');
select app.guide_update_published_section('va', 'your-workday', '6328004a35668c260b0452528b37c3fb', 'Your workday', 'The queue, task actions, Today, switching functions and your scorecard.',
  'Every function works the same way: start on Queue, take the oldest task, finish it, and check Today for pickups and returns.

## The queue

Tasks come to your function on their own: new requests, renter replies, failed payments, toll notices and more.

1. The top line shows your function and how many tasks are open.
2. Filter: All, Mine, Unassigned or Waiting; Any time, Overdue, Due today or Escalated; and by type.
3. Each row has a priority, the task, its record, when it is due and how long it has waited. The oldest due is first.
4. Press **Take it** to make it yours. **Sheet** opens the step-by-step procedure.

![](/guides/img/va-cs-01-queue-desktop-c36a8e2d.jpg "desktop; size: 1440 640; address: carmacars.ca/va; pins: 1 13.9 5.0, 2 36.1 17.5, 3 31.9 43.8, 4 91.7 52.3")

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
2. Press a booking number to open it. **Queue** takes you back to your tasks.

![](/guides/img/va-cs-02-today-desktop-dfd277b7.jpg "desktop; size: 1440 700; address: carmacars.ca/va/today; pins: 1 20.8 14.3")

## Documents to sign

Your staff agreement, when CarmaCars sends it.

1. The queue shows "You have a document to sign". Press **Read and sign**.
2. Check the key values at the top (your role, hours, rate and start date), then press **Read the PDF** and read it.
3. Press **Sign**. Your full legal name is your signature (or press **Draw instead**). Several documents? One signature covers all of them. The signed copy stays on the same page.

## Several functions? Switch with Working as

If you cover more than one function, **Working as** at the top of the rail lists them: Customer service, Finance, Fleet and Sales. Choose one; the rail, the queue and Today change to that function.

## Your scorecard

1. Open **Scorecard** at the bottom of the rail.
2. By week shows each measure, its target and your result for each week.
3. A task meets its target when done by its due time. Daily checks count when done by 9:00 and 18:00.

![](/guides/img/va-sales-05-scorecard-desktop-78ec1b03.jpg "desktop; size: 1440 360; address: carmacars.ca/va/scorecard; pins: 1 4.2 39.7, 2 62.5 58.3")
',
  '<p class="gd-p">Every function works the same way: start on Queue, take the oldest task, finish it, and check Today for pickups and returns.</p><section class="gd-task" id="your-workday-the-queue" data-gd-task><h2 class="gd-h2">The queue</h2><p class="gd-p">Tasks come to your function on their own: new requests, renter replies, failed payments, toll notices and more.</p><div class="gd-stepblock gd-stepblock--below"><div class="gd-stepcol"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">The top line shows your function and how many tasks are open.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Filter: All, Mine, Unassigned or Waiting; Any time, Overdue, Due today or Escalated; and by type.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Each row has a priority, the task, its record, when it is due and how long it has waited. The oldest due is first.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t">Press <b class="gd-ui">Take it</b> to make it yours. <b class="gd-ui">Sheet</b> opens the step-by-step procedure.</div></li></ol></div><figure class="gd-fig gd-fig--desk"><div class="gd-browser"><div class="gd-bar" aria-hidden="true"><i></i><i></i><i></i><span class="gd-addr">carmacars.ca/va</span></div><div class="gd-imgwrap" style="aspect-ratio:1440/640"><img src="/guides/img/va-cs-01-queue-desktop-c36a8e2d.jpg" alt="" loading="lazy" decoding="async" width="1440" height="640"><span class="gd-pin" style="left:13.9%;top:5%" aria-hidden="true">1</span><span class="gd-pin" style="left:36.1%;top:17.5%" aria-hidden="true">2</span><span class="gd-pin" style="left:31.9%;top:43.8%" aria-hidden="true">3</span><span class="gd-pin" style="left:91.7%;top:52.3%" aria-hidden="true">4</span></div></div></figure></div></section><section class="gd-task" id="your-workday-work-a-task" data-gd-task><h2 class="gd-h2">Work a task</h2><p class="gd-p">Open the task. The buttons along the top move it on.</p><div class="gd-tablewrap"><table class="gd-table"><thead><tr><th scope="col">Button</th><th scope="col">What it does</th></tr></thead><tbody><tr><td><b class="gd-ui">Open the working screen</b></td><td>Jumps to the booking, car or owner the task is about.</td></tr><tr><td><b class="gd-ui">Done</b></td><td>You finished it. It leaves the queue.</td></tr><tr><td><b class="gd-ui">Waiting</b></td><td>You are waiting on someone (a renter, an owner). It stays yours.</td></tr><tr><td><b class="gd-ui">Escalate</b></td><td>It needs an Admin. Add why.</td></tr><tr><td><b class="gd-ui">Hand over</b></td><td>Give it to someone else on the team.</td></tr><tr><td><b class="gd-ui">Add a note</b></td><td>Leave a note for whoever looks next.</td></tr></tbody></table></div><aside class="gd-box"><span class="gd-lbl">Tip</span><div>Work oldest due first. A task meets its target when it is done by its due time; that is what your scorecard counts.</div></aside></section><section class="gd-task" id="your-workday-today" data-gd-task><h2 class="gd-h2">Today</h2><div class="gd-stepblock gd-stepblock--below"><div class="gd-stepcol"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">Today lists pickups and returns, and what is due, for your function.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Press a booking number to open it. <b class="gd-ui">Queue</b> takes you back to your tasks.</div></li></ol></div><figure class="gd-fig gd-fig--desk"><div class="gd-browser"><div class="gd-bar" aria-hidden="true"><i></i><i></i><i></i><span class="gd-addr">carmacars.ca/va/today</span></div><div class="gd-imgwrap" style="aspect-ratio:1440/700"><img src="/guides/img/va-cs-02-today-desktop-dfd277b7.jpg" alt="" loading="lazy" decoding="async" width="1440" height="700"><span class="gd-pin" style="left:20.8%;top:14.3%" aria-hidden="true">1</span></div></div></figure></div></section><section class="gd-task" id="your-workday-documents-to-sign" data-gd-task><h2 class="gd-h2">Documents to sign</h2><p class="gd-p">Your staff agreement, when CarmaCars sends it.</p><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">The queue shows &quot;You have a document to sign&quot;. Press <b class="gd-ui">Read and sign</b>.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Check the key values at the top (your role, hours, rate and start date), then press <b class="gd-ui">Read the PDF</b> and read it.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Press <b class="gd-ui">Sign</b>. Your full legal name is your signature (or press <b class="gd-ui">Draw instead</b>). Several documents? One signature covers all of them. The signed copy stays on the same page.</div></li></ol></div></section><section class="gd-task" id="your-workday-several-functions-switch-with-working-as" data-gd-task><h2 class="gd-h2">Several functions? Switch with Working as</h2><p class="gd-p">If you cover more than one function, <b class="gd-ui">Working as</b> at the top of the rail lists them: Customer service, Finance, Fleet and Sales. Choose one; the rail, the queue and Today change to that function.</p></section><section class="gd-task" id="your-workday-your-scorecard" data-gd-task><h2 class="gd-h2">Your scorecard</h2><div class="gd-stepblock gd-stepblock--below"><div class="gd-stepcol"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">Open <b class="gd-ui">Scorecard</b> at the bottom of the rail.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">By week shows each measure, its target and your result for each week.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">A task meets its target when done by its due time. Daily checks count when done by 9:00 and 18:00.</div></li></ol></div><figure class="gd-fig gd-fig--desk"><div class="gd-browser"><div class="gd-bar" aria-hidden="true"><i></i><i></i><i></i><span class="gd-addr">carmacars.ca/va/scorecard</span></div><div class="gd-imgwrap" style="aspect-ratio:1440/360"><img src="/guides/img/va-sales-05-scorecard-desktop-78ec1b03.jpg" alt="" loading="lazy" decoding="async" width="1440" height="360"><span class="gd-pin" style="left:4.2%;top:39.7%" aria-hidden="true">1</span><span class="gd-pin" style="left:62.5%;top:58.3%" aria-hidden="true">2</span></div></div></figure></div></section>');
select app.guide_update_published_section('field', 'my-jobs', 'df8c0ed22d35a5a884d545e2e17c919e', 'My jobs', 'Your job list, a job card, maps and car moves.',
  'Your day, in order: handovers, returns, deliveries, moves and photo shoots. Each job card has the car, the plate, the place and the time.

## Your job list

1. The menu: **My jobs**, **Report**, **Referrals** and **Profile**. **Sign out** is top right.
2. Switch between **Today** and **Tomorrow**. Jobs are in time order.
3. Each card: the kind, the time, the status, the car and plate.
4. Press **Open the job** to start.
5. Moving a car that has no job? Use Vehicle moves (see below).

![](/guides/img/field-01-today-phone-421eca90.jpg "phone; size: 390 945; pins: 1 7.7 19.6, 2 76.9 27.5, 3 89.7 37.0, 4 88.5 46.6, 5 76.9 56.3")

> Tip: Need help on a job? Call CarmaCars at 647-575-3377. The link is at the bottom of My jobs.

## Open a job

1. The card shows the kind, the time, the car, the plate and colour.
2. The address, with **Open in maps** for directions.
3. For a handover: the booking, the renter''s name and phone, the Card on File and the licence on file.
4. Press **Acknowledge** so the office knows you have it. Then press **Start** when you are with the car.

![](/guides/img/field-02-job-phone-a0feec93.jpg "phone; size: 390 635; pins: 1 94.9 51.2, 2 94.9 64.3, 3 94.9 79.5, 4 94.9 93.9")

## Move a car

1. Under Vehicle moves, choose the Car and Why (for example Reposition).
2. Fill in From and the Odometer (km).
3. Press **Start a move**. When you arrive, press **End the move** and enter the odometer again.

![](/guides/img/field-01-today-phone-27dfe7af.jpg "phone; size: 390 450; pins: 1 87.2 22.2, 2 87.2 60.4, 3 87.2 93.3")

## Documents to sign

Your staff agreement, when CarmaCars sends it.

1. My jobs shows "You have a document to sign". Press **Read and sign**.
2. Check the key values at the top (your role, wage and start date), then press **Read the PDF** and read it.
3. Press **Sign**. Your full legal name is your signature (or press **Draw instead**).
',
  '<p class="gd-p">Your day, in order: handovers, returns, deliveries, moves and photo shoots. Each job card has the car, the plate, the place and the time.</p><section class="gd-task" id="my-jobs-your-job-list" data-gd-task><h2 class="gd-h2">Your job list</h2><div class="gd-stepblock gd-stepblock--side"><div class="gd-stepcol"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">The menu: <b class="gd-ui">My jobs</b>, <b class="gd-ui">Report</b>, <b class="gd-ui">Referrals</b> and <b class="gd-ui">Profile</b>. <b class="gd-ui">Sign out</b> is top right.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Switch between <b class="gd-ui">Today</b> and <b class="gd-ui">Tomorrow</b>. Jobs are in time order.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Each card: the kind, the time, the status, the car and plate.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t">Press <b class="gd-ui">Open the job</b> to start.</div></li><li><span class="gd-n" aria-hidden="true">5</span><div class="gd-t">Moving a car that has no job? Use Vehicle moves (see below).</div></li></ol></div><figure class="gd-fig gd-fig--phone"><div class="gd-phone"><div class="gd-imgwrap" style="aspect-ratio:390/945"><img src="/guides/img/field-01-today-phone-421eca90.jpg" alt="" loading="lazy" decoding="async" width="390" height="945"><span class="gd-pin" style="left:7.7%;top:19.6%" aria-hidden="true">1</span><span class="gd-pin" style="left:76.9%;top:27.5%" aria-hidden="true">2</span><span class="gd-pin" style="left:89.7%;top:37%" aria-hidden="true">3</span><span class="gd-pin" style="left:88.5%;top:46.6%" aria-hidden="true">4</span><span class="gd-pin" style="left:76.9%;top:56.3%" aria-hidden="true">5</span></div></div></figure></div><aside class="gd-box"><span class="gd-lbl">Tip</span><div>Need help on a job? Call CarmaCars at 647-575-3377. The link is at the bottom of My jobs.</div></aside></section><section class="gd-task" id="my-jobs-open-a-job" data-gd-task><h2 class="gd-h2">Open a job</h2><div class="gd-stepblock gd-stepblock--side"><div class="gd-stepcol"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">The card shows the kind, the time, the car, the plate and colour.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">The address, with <b class="gd-ui">Open in maps</b> for directions.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">For a handover: the booking, the renter&#39;s name and phone, the Card on File and the licence on file.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t">Press <b class="gd-ui">Acknowledge</b> so the office knows you have it. Then press <b class="gd-ui">Start</b> when you are with the car.</div></li></ol></div><figure class="gd-fig gd-fig--phone"><div class="gd-phone"><div class="gd-imgwrap" style="aspect-ratio:390/635"><img src="/guides/img/field-02-job-phone-a0feec93.jpg" alt="" loading="lazy" decoding="async" width="390" height="635"><span class="gd-pin" style="left:94.9%;top:51.2%" aria-hidden="true">1</span><span class="gd-pin" style="left:94.9%;top:64.3%" aria-hidden="true">2</span><span class="gd-pin" style="left:94.9%;top:79.5%" aria-hidden="true">3</span><span class="gd-pin" style="left:94.9%;top:93.9%" aria-hidden="true">4</span></div></div></figure></div></section><section class="gd-task" id="my-jobs-move-a-car" data-gd-task><h2 class="gd-h2">Move a car</h2><div class="gd-stepblock gd-stepblock--side"><div class="gd-stepcol"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">Under Vehicle moves, choose the Car and Why (for example Reposition).</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Fill in From and the Odometer (km).</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Press <b class="gd-ui">Start a move</b>. When you arrive, press <b class="gd-ui">End the move</b> and enter the odometer again.</div></li></ol></div><figure class="gd-fig gd-fig--phone"><div class="gd-phone"><div class="gd-imgwrap" style="aspect-ratio:390/450"><img src="/guides/img/field-01-today-phone-27dfe7af.jpg" alt="" loading="lazy" decoding="async" width="390" height="450"><span class="gd-pin" style="left:87.2%;top:22.2%" aria-hidden="true">1</span><span class="gd-pin" style="left:87.2%;top:60.4%" aria-hidden="true">2</span><span class="gd-pin" style="left:87.2%;top:93.3%" aria-hidden="true">3</span></div></div></figure></div></section><section class="gd-task" id="my-jobs-documents-to-sign" data-gd-task><h2 class="gd-h2">Documents to sign</h2><p class="gd-p">Your staff agreement, when CarmaCars sends it.</p><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">My jobs shows &quot;You have a document to sign&quot;. Press <b class="gd-ui">Read and sign</b>.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Check the key values at the top (your role, wage and start date), then press <b class="gd-ui">Read the PDF</b> and read it.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Press <b class="gd-ui">Sign</b>. Your full legal name is your signature (or press <b class="gd-ui">Draw instead</b>).</div></li></ol></div></section>');
select app.guide_update_published_section('investor', 'your-investments', '3b6bd6a3e7848a02d1a62b55dacae10e', 'Your investments', 'Each investment, its returns and the latest statement.',
  'Investments shows each of your investments: what you put in, what it earns, and when it pays.

## Read an investment

1. The menu: **Investments**, **Statements** and **Profile and notices**. **Sign out** is on the right.
2. Your agreement number and name.
3. Invested Amount, Principal, what was reinvested and redeemed to date, and the Yearly Percentage.
4. Investment Date, Lockup End Date, how Returns are handled (Paid monthly or Reinvested) and the Next Payment Date.
5. Latest statement, with **Open**.

![](/guides/img/investor-01-investments-phone-d7251016.jpg "phone; size: 390 795; pins: 1 97.0 14.5, 2 76.9 28.3, 3 92.3 37.1, 4 92.3 71.7, 5 92.3 96.2")

> Tip: This area shows your records under your Investment Agreement. It is not an offer or a solicitation.

## Sign your investment agreement

When CarmaCars sends your agreement, it is under Documents to sign.

1. Press **Documents to sign** in the menu. The top shows what is signed ("0 of 1 signed").
2. Check the key values: your name and address, the Invested Amount, the Yearly Percentage and the dates. The agreement is filled in from your record.
3. Press **Read the PDF** and read it, with its schedules.
4. Say whether you got independent legal advice, and tick the risk acknowledgment (Schedule C). Your initials are filled in.
5. Press **Sign**. Your full legal name is your signature (or press **Draw instead**). The signed copy is on the same page.

> Tip: Signed on paper instead? Once we record it, it shows under Signed with the scan.
',
  '<p class="gd-p">Investments shows each of your investments: what you put in, what it earns, and when it pays.</p><section class="gd-task" id="your-investments-read-an-investment" data-gd-task><h2 class="gd-h2">Read an investment</h2><div class="gd-stepblock gd-stepblock--side"><div class="gd-stepcol"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">The menu: <b class="gd-ui">Investments</b>, <b class="gd-ui">Statements</b> and <b class="gd-ui">Profile and notices</b>. <b class="gd-ui">Sign out</b> is on the right.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Your agreement number and name.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Invested Amount, Principal, what was reinvested and redeemed to date, and the Yearly Percentage.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t">Investment Date, Lockup End Date, how Returns are handled (Paid monthly or Reinvested) and the Next Payment Date.</div></li><li><span class="gd-n" aria-hidden="true">5</span><div class="gd-t">Latest statement, with <b class="gd-ui">Open</b>.</div></li></ol></div><figure class="gd-fig gd-fig--phone"><div class="gd-phone"><div class="gd-imgwrap" style="aspect-ratio:390/795"><img src="/guides/img/investor-01-investments-phone-d7251016.jpg" alt="" loading="lazy" decoding="async" width="390" height="795"><span class="gd-pin" style="left:97%;top:14.5%" aria-hidden="true">1</span><span class="gd-pin" style="left:76.9%;top:28.3%" aria-hidden="true">2</span><span class="gd-pin" style="left:92.3%;top:37.1%" aria-hidden="true">3</span><span class="gd-pin" style="left:92.3%;top:71.7%" aria-hidden="true">4</span><span class="gd-pin" style="left:92.3%;top:96.2%" aria-hidden="true">5</span></div></div></figure></div><aside class="gd-box"><span class="gd-lbl">Tip</span><div>This area shows your records under your Investment Agreement. It is not an offer or a solicitation.</div></aside></section><section class="gd-task" id="your-investments-sign-your-investment-agreement" data-gd-task><h2 class="gd-h2">Sign your investment agreement</h2><p class="gd-p">When CarmaCars sends your agreement, it is under Documents to sign.</p><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">Press <b class="gd-ui">Documents to sign</b> in the menu. The top shows what is signed (&quot;0 of 1 signed&quot;).</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Check the key values: your name and address, the Invested Amount, the Yearly Percentage and the dates. The agreement is filled in from your record.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Press <b class="gd-ui">Read the PDF</b> and read it, with its schedules.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t">Say whether you got independent legal advice, and tick the risk acknowledgment (Schedule C). Your initials are filled in.</div></li><li><span class="gd-n" aria-hidden="true">5</span><div class="gd-t">Press <b class="gd-ui">Sign</b>. Your full legal name is your signature (or press <b class="gd-ui">Draw instead</b>). The signed copy is on the same page.</div></li></ol></div><aside class="gd-box"><span class="gd-lbl">Tip</span><div>Signed on paper instead? Once we record it, it shows under Signed with the scan.</div></aside></section>');
-- GUIDES 0049 END

-- ================================================================ 6. the doors
create or replace function app.ops49(p_user uuid, p_call text, p_name text, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
begin
  case p_name
  when 'signing_packages' then return app.signing_packages_for(p_user, (p ->> 'user_id')::uuid);
  when 'investor_agreement_prepare' then return app.investor_agreement_prepare(p_user, (p ->> 'investor_id')::uuid);
  when 'staff_agreement_prepare' then return app.staff_agreement_prepare(p_user, (p ->> 'staff_user_id')::uuid);
  when 'guide_suggestion_record' then return app.guide_suggestion_record(p_user, p);
  when 'guide_review_resolve' then return app.guide_review_resolve(p_user, p);
  else raise exception 'Unknown action %', p_name using errcode = '22023';
  end case;
end $$;

alter function app.door(uuid, text, text, text, jsonb) rename to door_0046;
create or replace function app.door(p_user uuid, p_aal text, p_call text, p_name text, p jsonb default '{}'::jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
begin
  if p_call in ('ops_read', 'ops_do') and p_name in ('signing_packages', 'investor_agreement_prepare', 'staff_agreement_prepare', 'guide_suggestion_record', 'guide_review_resolve') then
    perform app.door_begin(p_user, p_aal);
    if p_call = 'ops_read' and p_name not in ('signing_packages', 'staff_agreement_prepare') then raise exception 'Unknown read %', p_name using errcode = '22023'; end if;
    if p_call = 'ops_do' and p_name in ('signing_packages', 'staff_agreement_prepare') then raise exception 'Unknown action %', p_name using errcode = '22023'; end if;
    return app.ops49(p_user, p_call, p_name, coalesce(p, '{}'::jsonb) - '_va');
  end if;
  return app.door_0046(p_user, p_aal, p_call, p_name, p);
end $$;

-- The server's own calls (as the service role, with the signed-in person's id; each checks the person).
create or replace function public.server_signing_package_record(p_by uuid, p jsonb) returns jsonb
language sql volatile security invoker set search_path = public, app as $$ select app.signing_package_record(p_by, p) $$;
create or replace function public.server_my_signing_checklist(p_by uuid) returns jsonb
language sql stable security invoker set search_path = public, app as $$ select app.my_signing_checklist(p_by) $$;
create or replace function public.server_guide_upkeep_apply(p jsonb) returns jsonb
language sql volatile security invoker set search_path = public, app as $$ select app.guide_upkeep_apply(p) $$;
-- The screenshots replaced so far (oldest first), so the upkeep run compares a new screenshot with the image the guide
-- shows now, not with the committed one it replaced.
create or replace function public.server_guide_images_replaced() returns jsonb
language sql stable security invoker set search_path = public, app as $$
  select coalesce(jsonb_agg(jsonb_build_object('url', i.url, 'replaces_url', i.replaces_url) order by i.created_at, i.id), '[]'::jsonb)
    from guide_images i where i.replaces_url is not null
$$;

-- ================================================================ 7. row-level security, privileges, audit
alter table signing_packages enable row level security;
create policy admin_all on signing_packages for all to authenticated using (app.is_admin()) with check (app.is_admin());
create policy own_read on signing_packages for select to authenticated using (signer_user_id = app.uid());
revoke all on signing_packages from anon, authenticated;
grant select on signing_packages to authenticated;
grant all on signing_packages to service_role;

alter table signing_package_documents enable row level security;
create policy admin_all on signing_package_documents for all to authenticated using (app.is_admin()) with check (app.is_admin());
create policy own_read on signing_package_documents for select to authenticated
  using (exists (select 1 from signing_packages k where k.id = package_id and k.signer_user_id = app.uid()));
revoke all on signing_package_documents from anon, authenticated;
grant select on signing_package_documents to authenticated;
grant all on signing_package_documents to service_role;

do $$
declare
  f record;
begin
  for f in
    select p.oid::regprocedure as sig from pg_proc p join pg_namespace n on n.oid = p.pronamespace
     where (n.nspname = 'app' and p.proname = any (array[
              'notify_daily_checks', 'partner_insurance_check', 'partners_insurance_resolve', 'signing_package_record', 'signing_packages_for', 'my_signing_checklist',
              'investor_agreement_prepare', 'staff_agreement_prepare', 'sign_request_create', 'guide_upkeep_apply', 'guide_suggestion_record',
              'guide_review_resolve', 'guide_admin', 'guides_admin', 'ops49', 'door', 'ai_vision_gate', 'ai_call_record']))
        or (n.nspname = 'public' and p.proname = any (array['server_signing_package_record', 'server_my_signing_checklist', 'server_guide_upkeep_apply', 'server_guide_images_replaced']))
  loop
    execute format('revoke all on function %s from public, anon, authenticated', f.sig);
    execute format('grant execute on function %s to service_role', f.sig);
  end loop;
end $$;

-- Each renamed function keeps its privileges; the function in its place gets the same.
do $$
declare
  r record;
  v_new regprocedure;
  g text;
begin
  for r in select p.oid, m.new_name, oidvectortypes(p.proargtypes) as args
             from pg_proc p join pg_namespace n on n.oid = p.pronamespace
             join (values ('notify_daily_checks_0023', 'notify_daily_checks'), ('sign_request_create_0044', 'sign_request_create'),
                          ('ai_vision_gate_0042', 'ai_vision_gate'), ('ai_call_record_0042', 'ai_call_record'),
                          ('guide_admin_0044', 'guide_admin'), ('guides_admin_0044', 'guides_admin'), ('door_0046', 'door')) m(old_name, new_name)
               on m.old_name = p.proname
            where n.nspname = 'app' loop
    v_new := format('app.%I(%s)', r.new_name, r.args)::regprocedure;
    foreach g in array array['anon', 'authenticated', 'service_role'] loop
      if has_function_privilege(g, r.oid, 'execute') then execute format('grant execute on function %s to %I', v_new, g); end if;
    end loop;
  end loop;
end $$;
select app.attach_audit();
