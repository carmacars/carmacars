-- 4511 (release 50, owner pipeline; docs/changes/2026-11-24-r50-owner-pipeline.md): owner onboarding as one guided
-- pipeline per owner and car, with one next action for the right person, and the incorporation referral.
--
-- The owner (Nov 24): an owner does not just get "accepted": the car's title moves into CarmaCars' name under the
-- Title-Holding Agreement and Forms A to E (or, for a corporation, the car is leased to CarmaCars). Make it one clear
-- pipeline. Built on what exists, nothing duplicated:
--   the facts          app.onboarding_checklist (0022 and its wrappers: signatures, government forms, Forms C and D,
--                      listing photos, listing), app.owner_sign_missing (3800: the master agreement and Schedule A),
--                      vehicle_schedules.onboarding_method (and the application's proposed one, 0022), the onboarding
--                      photos and their review (0821), vehicle_onboardings' registry visit, permit and fleet policy dates
--                      (0002), the Safety Standards Certificate on the car (0237), app.confirm_fleet_policy (0078)
--   the stages         owner_stage_defs: Application, Terms approved, (Incorporate), Agreements signed, Documents
--                      uploaded, Ownership transfer, New registration, Plate and insurance on the fleet policy, Inspected
--                      and photographed, Listed. The route decides which apply (app.owner_stage_route): Transfer (title to
--                      the company), Co-Registrant (still supported by the code: CarmaCars is added beside the owner),
--                      Lease of an existing corporation (no title transfer: corporate documents and the lease instead) and
--                      Lease through a new Owner Corporation (Incorporate first, with the referral link of part B)
--   one next action    app.owner_stage_track: per stage done, current, later or not needed; the current one names its
--                      actor (owner, sales, Admin, Fleet), its one action, what to bring, where to go and the expected
--                      time, and its blockers in plain words. Admin overrides or advances a stage (audited)
--   the pipeline       owner_pipeline: one row a car, the stage and since when (days in stage), who was told; kept by
--                      app.owner_stage_sweep (pg_cron, every 15 minutes) and after every action here. The owner is
--                      emailed and texted when it becomes their turn (owner_stage_your_turn), Admin and Fleet get a To do
--                      when it is theirs, and a stage that waits longer than Program settings' owner_stage_stall_days (3)
--                      alerts the Admins (staff_owner_stage_stalled) and gives the owner's salesperson a To do
--   Sales              the Owner pipeline board (app.owner_stage_board): every owner and car by stage, days in stage, the
--                      next action and whose it is, one-tap nudges (owner_stage_nudge: branded email and text) and a call
--                      script per stage; a salesperson sees the owners they brought in
-- B. Incorporation referral: incorporation_affiliate (one row: the provider, the affiliate link template, the commission
--    note; off until Abbas pastes his link) and incorporation_referrals (who was referred and when, by owner and car, for
--    reconciling the commission), shown in Admin > Settings > Incorporation referral and on Admin > Referral partners.
-- Doors: ops_read/va_read/admin_read owner_stages, va_read/admin_read owner_stage_board, ops_do/va_do/admin_do
-- owner_stage_do; admin_read incorporation_referral, admin_do incorporation_referral_save and incorporation_referral_mark.
-- Server: public.server_incorporation_click (the /go/incorporate redirect, for the signed-in owner).
-- New tables: row-level security with admin_all, the audit trigger. No applied migration is edited: the door,
-- owner_register_document, vehicle_document_register and staff_register_vehicle_document are wrapped (_pre4511); onboarding_photo_kind and _label are
-- replaced (immutable, the same three kinds plus the new five). SCHEMA_MARKER 4513.
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

-- ================================================================ 1. settings
alter table program_settings
  add column if not exists owner_stage_enabled boolean not null default true,
  add column if not exists owner_stage_stall_days integer not null default 3 check (owner_stage_stall_days between 1 and 60),
  add column if not exists owner_stage_finder_url text not null default 'https://www.ontario.ca/locations/serviceontario' check (owner_stage_finder_url ~ '^https://[^[:space:]]+$'),
  add column if not exists owner_stage_uvip_url text not null default 'https://www.ontario.ca/page/used-vehicle-information-package' check (owner_stage_uvip_url ~ '^https://[^[:space:]]+$');
comment on column program_settings.owner_stage_enabled is 'r50 owner pipeline (4511): the stage tracker''s notices (the owner''s turn, the To dos, the stall alert). On by default.';
comment on column program_settings.owner_stage_stall_days is 'r50 owner pipeline (4511): a stage that waits this many days alerts the Admins and gives the owner''s salesperson a To do (3 by default).';
comment on column program_settings.owner_stage_finder_url is 'r50 owner pipeline (4511): the ServiceOntario centre finder the Ownership transfer stage links to.';
comment on column program_settings.owner_stage_uvip_url is 'r50 owner pipeline (4511): where an owner gets the Used Vehicle Information Package.';

-- ================================================================ 2. the stages (wording an Admin may change: a table, not code)
create table if not exists owner_stage_defs (
  code          text primary key check (code in ('application', 'terms', 'incorporate', 'agreements', 'documents', 'transfer', 'registration', 'fleet_policy', 'inspection', 'listed')),
  label         text not null check (char_length(label) between 3 and 80),
  sort_order    integer not null,
  actor         text not null check (actor in ('owner', 'sales', 'admin', 'fleet')),
  owner_action  text not null,
  staff_action  text not null,
  bring         text,
  where_text    text,
  expected      text not null,
  call_script   text not null,
  updated_at    timestamptz not null default now()
);
comment on table owner_stage_defs is 'r50 owner pipeline (4511): the stages of an owner''s car, with who acts, the action in the owner''s and in staff''s words, what to bring, where to go, the expected time and the salesperson''s call script. The rules that decide a stage is done are in app.owner_stage_track.';
insert into owner_stage_defs (code, label, sort_order, actor, owner_action, staff_action, bring, where_text, expected, call_script) values
  ('application', 'Application', 1, 'owner', 'Finish your application', 'Help the owner finish the application', null, null, 'About 10 minutes',
   'Hi {{first_name}}, it''s {{agent}} from CarmaCars. I saw you started listing your {{car}}. Do you have 10 minutes now to finish it together? I can stay on the line.'),
  ('terms', 'Terms approved', 2, 'admin', 'CarmaCars approves your terms, usually within 1 business day. Nothing to do on your side.', 'Approve the car''s terms', null, null, 'Within 1 business day',
   'Hi {{first_name}}, {{agent}} from CarmaCars. Your {{car}} is with our team for approval; it usually takes one business day. Any question about the fees or how the pay works while you wait?'),
  ('incorporate', 'Set up your corporation', 3, 'owner', 'Incorporate now', 'The owner sets up their Owner Corporation', 'Your legal name, home address and a name for the corporation (a number is fine).', 'Online, from your phone or computer.', 'About 20 minutes online; 1 to 2 business days to receive the certificate',
   'Hi {{first_name}}, {{agent}} from CarmaCars. For the lease route your {{car}} goes through a corporation you own. The online incorporation takes about 20 minutes: the link is in your portal. Shall I walk you through it now?'),
  ('agreements', 'Agreements signed', 4, 'owner', 'Sign your agreements', 'Send the owner a signing reminder', null, 'On screen, in your owner portal.', 'About 10 minutes, on screen',
   'Hi {{first_name}}, {{agent}} from CarmaCars. Your agreements are filled in from your application and ready to sign in your portal, about 10 minutes on screen. Can I stay on the line while you open it?'),
  ('documents', 'Documents uploaded', 5, 'owner', 'Upload your documents', 'Review the uploaded documents', 'Photos of your driver''s licence, both sides of the ownership permit, your insurance slip and, if the car is financed, the lender''s payout letter.', 'From your phone, on the car''s page.', 'About 5 minutes with your phone',
   'Hi {{first_name}}, {{agent}} from CarmaCars. We just need a few photos for your {{car}}: {{missing}}. You can take them with your phone on the car''s page. Want me to text you the link?'),
  ('transfer', 'Ownership transfer', 6, 'owner', 'Book a ServiceOntario appointment', 'Help the owner book the ServiceOntario visit', 'Your driver''s licence, the original ownership permit, proof of insurance, the filled Form A and transfer documents (printed from Documents), the Used Vehicle Information Package and the Safety Standards Certificate when needed, the lender''s letter if financed, and for a corporation proof of signing authority.', 'Any ServiceOntario centre that does vehicle registration.', '30 to 60 minutes at the counter',
   'Hi {{first_name}}, {{agent}} from CarmaCars. Next is the ownership transfer at ServiceOntario: about 30 to 60 minutes. Your forms are filled in. Which day this week works for you? I can help you find the closest centre.'),
  ('registration', 'New registration uploaded', 7, 'owner', 'Upload the new ownership permit', 'Get the new ownership permit from the owner', 'A photo of both sides of the new ownership permit ServiceOntario gave you.', 'From your phone, on the car''s page.', 'About 2 minutes',
   'Hi {{first_name}}, {{agent}} from CarmaCars. Thanks for doing the transfer. Last thing from you: a photo of the new ownership permit, both sides, on the car''s page. Can you do it now while we''re on the phone?'),
  ('fleet_policy', 'Plate and insurance on the fleet policy', 8, 'fleet', 'CarmaCars adds the car and its plate to the fleet insurance policy. Keep your own insurance until we confirm in writing.', 'Add the car and its plate to the fleet policy', null, null, '1 to 2 business days (the insurer)',
   'Hi {{first_name}}, {{agent}} from CarmaCars. Your {{car}} is being added to our fleet policy. Please keep your own insurance until we confirm in writing; it takes one to two business days.'),
  ('inspection', 'Inspected and photographed', 9, 'fleet', 'Bring the car in for its inspection and photos.', 'Inspect and photograph the car', 'The car, both keys, and the car clean inside.', 'At the CarmaCars office, 1570 Midland Ave, Scarborough.', 'About 45 minutes at the office',
   'Hi {{first_name}}, {{agent}} from CarmaCars. We''re ready to inspect and photograph your {{car}}, about 45 minutes at our office. When can you bring it in?'),
  ('listed', 'Listed', 10, 'admin', 'CarmaCars publishes your car''s listing. Nothing to do on your side.', 'Review and publish the listing', null, null, 'The same business day',
   'Hi {{first_name}}, {{agent}} from CarmaCars. Good news: your {{car}} is about to go live on the site. Anything you want renters to know about it?')
on conflict (code) do nothing;

-- ================================================================ 3. the pipeline: one row a car
create table if not exists owner_pipeline (
  vehicle_id          uuid primary key references vehicles (id) on delete cascade,
  owner_id            uuid not null references owners (id) on delete cascade,
  route               text not null check (route in ('transfer', 'co_registrant', 'lease', 'lease_new_corporation')),
  stage               text not null references owner_stage_defs (code),
  actor               text check (actor is null or actor in ('owner', 'sales', 'admin', 'fleet')),
  stage_since         timestamptz not null default now(),
  turn_notified_stage text,
  turn_notified_at    timestamptz,
  stalled_stage       text,
  stalled_at          timestamptz,
  last_nudge_at       timestamptz,
  last_nudge_by       uuid references users (id) on delete set null,
  nudges              integer not null default 0 check (nudges >= 0),
  visited_at          timestamptz,
  visited_by          uuid references users (id) on delete set null,
  fees_paid_at        timestamptz,
  fees_note           text check (fees_note is null or char_length(fees_note) <= 300),
  uvip_needed         boolean,
  ssc_needed          boolean,
  inspected_at        timestamptz,
  inspected_by        uuid references users (id) on delete set null,
  inspection_note     text check (inspection_note is null or char_length(inspection_note) <= 1000),
  overrides           jsonb not null default '{}'::jsonb check (jsonb_typeof(overrides) = 'object'),
  finished_at         timestamptz,
  created_at          timestamptz not null default now(),
  updated_at          timestamptz not null default now()
);
create index if not exists owner_pipeline_owner_idx on owner_pipeline (owner_id);
create index if not exists owner_pipeline_open_idx on owner_pipeline (stage, stage_since) where finished_at is null;
create index if not exists owner_pipeline_stage_idx on owner_pipeline (stage);
comment on table owner_pipeline is 'r50 owner pipeline (4511): each owner''s car on its way to being listed: the route, the current stage and since when, who acts, who was told, the facts no other record holds (the registry visit and its fees, whether a UVIP or a safety certificate is needed, the inspection) and an Admin''s overrides {stage: {status, by, at, note}}.';
create trigger owner_pipeline_updated before update on owner_pipeline for each row execute function app.set_updated_at();
create trigger owner_stage_defs_updated before update on owner_stage_defs for each row execute function app.set_updated_at();

-- ================================================================ 4. B: the incorporation referral
create table if not exists incorporation_affiliate (
  singleton       boolean primary key default true check (singleton),
  provider_name   text not null default 'Ownr' check (char_length(btrim(provider_name)) between 2 and 60),
  link_template   text check (link_template is null or link_template ~ '^https://[^[:space:]]+$'),
  commission_note text not null default 'Ownr (PartnerStack): $50 per incorporation, 90-day cookie, paid by PartnerStack.' check (char_length(commission_note) <= 500),
  signup_url      text not null default 'https://www.ownr.co/affiliates' check (signup_url ~ '^https://[^[:space:]]+$'),
  enabled         boolean not null default false,
  updated_by      uuid references users (id) on delete set null,
  updated_at      timestamptz not null default now()
);
insert into incorporation_affiliate (singleton) values (true) on conflict do nothing;
comment on table incorporation_affiliate is 'r50 owner pipeline (4511): the online incorporation provider an owner who needs a corporation is referred to, with its affiliate link ({ref} in it becomes the referral''s code, for reconciling) and the commission. Off until the affiliate link is pasted: the owner is then shown no provider.';

create table if not exists incorporation_referrals (
  id               uuid primary key default gen_random_uuid(),
  owner_id         uuid not null references owners (id) on delete cascade,
  vehicle_id       uuid references vehicles (id) on delete set null,
  provider_name    text not null,
  ref_code         text not null unique check (ref_code ~ '^CC[0-9A-Z]{6,12}$'),
  clicks           integer not null default 1 check (clicks > 0),
  first_clicked_at timestamptz not null default now(),
  last_clicked_at  timestamptz not null default now(),
  status           text not null default 'clicked' check (status in ('clicked', 'incorporated', 'commission_received', 'void')),
  incorporated_on  date,
  commission_cents bigint check (commission_cents is null or commission_cents >= 0),
  commission_on    date,
  note             text check (note is null or char_length(note) <= 500),
  updated_by       uuid references users (id) on delete set null,
  updated_at       timestamptz not null default now(),
  unique (owner_id, provider_name)
);
create index if not exists incorporation_referrals_vehicle_idx on incorporation_referrals (vehicle_id);
comment on table incorporation_referrals is 'r50 owner pipeline (4511): an owner who opened the incorporation link (Incorporate now): who, for which car, when first and last, and the code sent with the link, so the provider''s commission report can be matched; the Admin marks the incorporation and the commission received.';
create trigger incorporation_referrals_updated before update on incorporation_referrals for each row execute function app.set_updated_at();

do $$
declare t text;
begin
  foreach t in array array['owner_stage_defs', 'owner_pipeline', 'incorporation_affiliate', 'incorporation_referrals'] loop
    execute format('alter table %I enable row level security', t);
    execute format('revoke all on %I from public, anon, authenticated', t);
    execute format('grant select on %I to authenticated', t);
    execute format('grant all on %I to service_role', t);
    execute format('drop policy if exists admin_all on %I', t);
    execute format('create policy admin_all on %I for all to authenticated using (app.is_admin()) with check (app.is_admin())', t);
    execute format('drop trigger if exists audit_%s on %I', t, t);
    execute format('create trigger audit_%s after insert or update or delete on %I for each row execute function app.audit_row()', t, t);
  end loop;
end $$;

insert into task_rules (task_type, queue, title, priority, due_kind, due_amount, description) values
  ('owner_stage_turn', 'admin', 'Owner pipeline: your step', 'normal', 'business_days', 1,
   'An owner''s car reached a stage that waits on CarmaCars (4511): approve the terms, review the documents, add it to the fleet policy, inspect and photograph it, or publish the listing. Closed by itself when the stage moves.'),
  ('owner_stage_stalled', 'sales', 'Owner pipeline: stalled', 'high', 'business_days', 1,
   'An owner''s car has waited in one stage longer than Program settings allow (4511, owner_stage_stall_days). Call the owner with the stage''s call script, nudge them, or move it forward. Closed by itself when the stage moves.')
on conflict (task_type) do nothing;

-- ================================================================ 5. documents: the new kinds count as onboarding photos (review, replace, remove)
create or replace function app.onboarding_photo_kind(p_kind text) returns boolean
language sql immutable as $$ select p_kind in ('ownership_permit', 'owner_insurance_proof', 'finance_party_permission', 'owner_id', 'lien_payout_letter', 'uvip', 'new_registration', 'corporate_documents') $$;
create or replace function app.onboarding_photo_label(p_kind text) returns text
language sql immutable as $$
  select case p_kind when 'ownership_permit' then 'Ownership permit' when 'owner_insurance_proof' then 'Insurance slip'
                     when 'finance_party_permission' then 'Lender or lessor permission' when 'owner_id' then 'Driver''s licence'
                     when 'lien_payout_letter' then 'Lender''s payout letter' when 'uvip' then 'Used Vehicle Information Package'
                     when 'new_registration' then 'New ownership permit' when 'corporate_documents' then 'Corporate documents' else 'Photo' end $$;

alter function app.owner_register_document(uuid, uuid, text, text, text, text) rename to owner_register_document_pre4511;
create function app.owner_register_document(p_by uuid, p_vehicle uuid, p_kind text, p_path text, p_sha256 text, p_mime text) returns uuid
language plpgsql security definer set search_path = public, app, pg_temp as $$
declare
  v vehicles;
  v_id uuid;
begin
  if p_kind not in ('owner_id', 'lien_payout_letter', 'uvip', 'new_registration', 'corporate_documents', 'safety_certificate') then
    return app.owner_register_document_pre4511(p_by, p_vehicle, p_kind, p_path, p_sha256, p_mime);
  end if;
  select * into v from vehicles where id = p_vehicle;
  if v.id is null or not app.user_owns_vehicle(p_by, p_vehicle) then raise exception 'Not permitted: an owner uploads only for their own vehicle' using errcode = '42501'; end if;
  if coalesce(p_mime, '') not in ('image/jpeg', 'image/png', 'application/pdf') or coalesce(lower(p_sha256), '') !~ '^[0-9a-f]{64}$' or nullif(btrim(coalesce(p_path, '')), '') is null then
    raise exception 'An upload needs its file, its type and its SHA-256' using errcode = '22023';
  end if;
  if (select count(*) from documents d where d.vehicle_id = p_vehicle and d.uploaded_by = p_by and d.created_at > now() - interval '1 hour') >= 30 then
    raise exception 'Too many uploads in the last hour. Try again later.' using errcode = '54000';
  end if;
  insert into documents (kind, title, storage_bucket, storage_path, mime_type, sha256, retention, uploaded_by, owner_id, vehicle_id)
  values (p_kind::document_kind, format('%s, %s', case when p_kind = 'safety_certificate' then 'Safety Standards Certificate' else app.onboarding_photo_label(p_kind) end, app.vehicle_name(p_vehicle)),
          'documents', p_path, p_mime, lower(p_sha256), 'records_7y', p_by, v.owner_id, p_vehicle)
  returning id into v_id;
  if p_kind = 'safety_certificate' then update vehicle_onboardings set safety_certificate_document_id = v_id where vehicle_id = v.id; end if;
  perform app.owner_stage_refresh(v.id);
  return v_id;
end $$;
select pg_temp.copy_grants('app.owner_register_document(uuid, uuid, text, text, text, text)'::regprocedure, 'app.owner_register_document_pre4511(uuid, uuid, text, text, text, text)'::regprocedure);

alter function app.vehicle_document_register(uuid, jsonb) rename to vehicle_document_register_pre4511;
create function app.vehicle_document_register(p_by uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app, pg_temp as $$
declare
  v vehicles;
  v_kind text := p ->> 'kind';
  v_doc uuid;
  r jsonb;
begin
  if v_kind not in ('owner_id', 'lien_payout_letter', 'uvip', 'new_registration', 'corporate_documents') then
    r := app.vehicle_document_register_pre4511(p_by, p);
    perform app.owner_stage_refresh(nullif(p ->> 'vehicle_id', '')::uuid);
    return r;
  end if;
  if not (app.user_is_admin(p_by) or app.user_va_has(p_by, 'fleet', 'cs')) then raise exception 'An Admin, Fleet or customer service uploads a car''s documents' using errcode = '42501'; end if;
  if nullif(p ->> 'path', '') is null then raise exception 'An upload needs the key of its file in private storage' using errcode = '22023'; end if;
  select * into v from vehicles where id::text = p ->> 'vehicle_id';
  if v.id is null then raise exception 'Car not found' using errcode = 'P0002'; end if;
  insert into documents (kind, title, storage_bucket, storage_path, mime_type, sha256, retention, uploaded_by, vehicle_id, owner_id)
  values (v_kind::document_kind, coalesce(nullif(btrim(p ->> 'title'), ''), app.onboarding_photo_label(v_kind) || ' (uploaded by staff)'),
          'documents', p ->> 'path', nullif(p ->> 'mime', ''), nullif(p ->> 'sha256', ''), 'records_7y', p_by, v.id, v.owner_id)
  returning id into v_doc;
  insert into audit_log (actor_user_id, action, entity_table, entity_id, after)
  values (p_by, 'vehicle_document_register', 'vehicles', v.id::text, jsonb_build_object('kind', v_kind, 'document_id', v_doc));
  perform app.owner_stage_refresh(v.id);
  return jsonb_build_object('document_id', v_doc, 'kind', v_kind);
end $$;
select pg_temp.copy_grants('app.vehicle_document_register(uuid, jsonb)'::regprocedure, 'app.vehicle_document_register_pre4511(uuid, jsonb)'::regprocedure);

-- staff's "Add a photo" on the owner page (0067's staff_vehicle_document): the new kinds too
alter function app.staff_register_vehicle_document(uuid, jsonb) rename to staff_register_vehicle_document_pre4511;
create function app.staff_register_vehicle_document(p_by uuid, p jsonb) returns uuid
language plpgsql security definer set search_path = public, app, pg_temp as $$
declare
  v vehicles;
  v_id uuid;
  v_kind text := p ->> 'kind';
begin
  if v_kind not in ('owner_id', 'lien_payout_letter', 'uvip', 'new_registration', 'corporate_documents') then
    v_id := app.staff_register_vehicle_document_pre4511(p_by, p);
    perform app.owner_stage_refresh(nullif(p ->> 'vehicle_id', '')::uuid);
    return v_id;
  end if;
  if not (app.user_is_admin(p_by) or app.user_va_has(p_by, 'cs', 'fleet')) then raise exception 'Not permitted' using errcode = '42501'; end if;
  select * into v from vehicles where id = nullif(p ->> 'vehicle_id', '')::uuid;
  if v.id is null then raise exception 'Car not found' using errcode = 'P0002'; end if;
  if coalesce(p ->> 'mime', '') not in ('image/jpeg', 'image/png', 'application/pdf') or coalesce(lower(p ->> 'sha256'), '') !~ '^[0-9a-f]{64}$' or coalesce(p ->> 'path', '') !~ '^owners/' then
    raise exception 'An upload needs its file, its type and its SHA-256' using errcode = '22023';
  end if;
  insert into documents (kind, title, storage_bucket, storage_path, mime_type, sha256, retention, uploaded_by, owner_id, vehicle_id)
  values (v_kind::document_kind, format('%s, %s', app.onboarding_photo_label(v_kind), app.vehicle_name(v.id)), 'documents', p ->> 'path', p ->> 'mime', lower(p ->> 'sha256'), 'records_7y', p_by, v.owner_id, v.id)
  returning id into v_id;
  perform app.owner_stage_refresh(v.id);
  return v_id;
end $$;
select pg_temp.copy_grants('app.staff_register_vehicle_document(uuid, jsonb)'::regprocedure, 'app.staff_register_vehicle_document_pre4511(uuid, jsonb)'::regprocedure);

-- ================================================================ 6. the route, the documents, the track
-- The route of a car from its onboarding method: the current schedule's, else the application's, else the recommended one.
create function app.owner_stage_method(p_vehicle uuid) returns text
language sql stable security definer set search_path = public, app, pg_temp as $$
  select coalesce(s.onboarding_method::text, ob.proposed_onboarding_method::text,
                  app.default_onboarding_method(coalesce(ob.held_by, o.owner_type), coalesce(ob.title_status, 'owned_outright'::title_status),
                                                coalesce(ob.proposed_management_mode, v.management_mode))::text)
    from vehicles v join owners o on o.id = v.owner_id left join vehicle_onboardings ob on ob.vehicle_id = v.id
    left join vehicle_schedules s on s.vehicle_id = v.id and s.superseded_by is null and s.withdrawn_at is null
   where v.id = p_vehicle
$$;
create function app.owner_stage_route(p_method text) returns text
language sql immutable as $$
  select case p_method when 'transfer' then 'transfer' when 'co_registrant' then 'co_registrant'
                       when 'lease_existing_corporation' then 'lease' when 'lease_new_owner_corporation' then 'lease_new_corporation' end
$$;
create function app.owner_stage_route_label(p_route text) returns text
language sql immutable as $$
  select case p_route when 'transfer' then 'Transfer: the title moves to CarmaCars' when 'co_registrant' then 'Co-Registrant: CarmaCars is added beside you'
                      when 'lease' then 'Lease: your corporation leases the car to CarmaCars' when 'lease_new_corporation' then 'Lease through a new Owner Corporation' end
$$;
-- A car is in the pipeline while it is onboarding in the owner program (not Turo-only, not a sample, not CarmaCars' own).
create function app.owner_stage_applies(p_vehicle uuid) returns boolean
language sql stable security definer set search_path = public, app, pg_temp as $$
  select exists (select 1 from vehicles v join owners o on o.id = v.owner_id join vehicle_onboardings ob on ob.vehicle_id = v.id
                  where v.id = p_vehicle and not coalesce(v.is_sample, false) and coalesce(v.supply_type::text, 'program_owner') = 'program_owner'
                    and coalesce(o.kind, 'program') = 'program' and v.status not in ('declined', 'exited', 'total_loss')
                    and ob.status not in ('declined', 'withdrawn') and coalesce(ob.proposed_management_mode, v.management_mode) <> 'turo_only')
     and app.owner_stage_route(app.owner_stage_method(p_vehicle)) is not null
$$;

-- One document kind for a car: missing, waiting (for review), rejected (with the reason) or ok.
create function app.owner_stage_doc(p_vehicle uuid, p_owner uuid, p_kind text) returns jsonb
language sql stable security definer set search_path = public, app, pg_temp as $$
  select coalesce((select jsonb_build_object('state', case when d.review_status = 'rejected' then 'rejected' when d.review_status = 'waiting' then 'waiting' else 'ok' end,
                                              'note', d.review_note, 'id', d.id)
                     from documents d
                    where d.kind::text = p_kind and d.removed_at is null and d.purged_at is null
                      and (d.vehicle_id = p_vehicle or (p_kind in ('owner_id', 'corporate_documents') and d.owner_id = p_owner))
                    order by (d.review_status is distinct from 'rejected') desc, (d.review_status is distinct from 'waiting') desc, d.created_at desc limit 1),
                  jsonb_build_object('state', 'missing'))
$$;

-- The track of one car: every stage of its route with its state, and for the current one its actor, its one action, what
-- to bring, where to go, the expected time and the blockers. The facts are the records'; an Admin's override wins.
create function app.owner_stage_track(p_vehicle uuid) returns jsonb
language plpgsql stable security definer set search_path = public, app, pg_temp as $$
declare
  v vehicles;
  o owners;
  ob vehicle_onboardings;
  s vehicle_schedules;
  pl owner_pipeline;
  st program_settings := app.settings();
  d owner_stage_defs;
  v_method text := app.owner_stage_method(p_vehicle);
  v_route text := app.owner_stage_route(v_method);
  v_base text;
  v_ck jsonb;
  v_sign jsonb;
  v_stages jsonb := '[]'::jsonb;
  v_current jsonb;
  v_done boolean;
  v_na boolean;
  v_actor text;
  v_action jsonb;
  v_items jsonb;
  v_block text[];
  v_kinds text[];
  v_k text;
  v_doc jsonb;
  v_missing text[];
  v_waiting text[];
  v_financed boolean;
  v_corp jsonb;
  v_ref jsonb;
  v_ov jsonb;
  v_state text;
  v_n integer := 0;
  v_count_done integer := 0;
  v_payer text;
  v_gov_ok boolean;
  v_signed_ok boolean;
  v_ssc boolean;
  v_uvip boolean;
  v_has_reg boolean;
  v_listed boolean;
  v_photos boolean;
  v_owner_wait boolean;
begin
  select * into v from vehicles where id = p_vehicle;
  if v.id is null or v_route is null then return null; end if;
  select * into o from owners where id = v.owner_id;
  select * into ob from vehicle_onboardings where vehicle_id = v.id;
  select * into s from vehicle_schedules where vehicle_id = v.id and superseded_by is null and withdrawn_at is null;
  select * into pl from owner_pipeline where vehicle_id = v.id;
  v_base := rtrim(coalesce(st.notify_base_url, 'https://carmacars.ca'), '/');
  select coalesce(jsonb_object_agg(c.code, c.status), '{}'::jsonb) into v_ck from app.onboarding_checklist(v.id) c;
  v_sign := app.owner_sign_missing(o.id, v.id);
  v_financed := coalesce(s.title_status, ob.title_status, 'owned_outright') <> 'owned_outright';
  v_gov_ok := coalesce(v_ck ->> 'government_forms', 'not_applicable') <> 'open';
  v_signed_ok := jsonb_array_length(v_sign) = 0 and coalesce(v_ck ->> 'signatures', 'not_applicable') <> 'open'
                 and coalesce(v_ck ->> 'witnessed_forms', 'not_applicable') <> 'open' and v_gov_ok;
  v_has_reg := ob.permit_filed_at is not null or (app.owner_stage_doc(v.id, o.id, 'new_registration') ->> 'state') in ('ok', 'waiting')
               or exists (select 1 from vehicle_registrations g where g.vehicle_id = v.id and g.retransferred_on is null);
  v_listed := coalesce(v_ck ->> 'listing', 'open') = 'done' or exists (select 1 from vehicle_listings l where l.vehicle_id = v.id and l.status = 'published');
  v_photos := coalesce(v_ck ->> 'photos', 'open') in ('done', 'not_applicable');
  v_ssc := v.ssc_number is not null or ob.safety_certificate_document_id is not null
           or (app.owner_stage_doc(v.id, o.id, 'safety_certificate') ->> 'state') in ('ok', 'waiting');
  v_uvip := (app.owner_stage_doc(v.id, o.id, 'uvip') ->> 'state') in ('ok', 'waiting');
  -- the registry's charges and any tax: the owner pays them at the counter (Title-Holding Agreement 8.2) unless the
  -- Vehicle Schedule lists an onboarding cost CarmaCars pays for the owner (Enrollment Agreement 4.2: on the upfront invoice).
  -- vehicle_schedules.onboarding_estimate_cents is information only (the owner pays third parties directly), so it is not read here.
  v_payer := 'You pay the registry''s charges and any tax at the counter (Title-Holding Agreement, section 8.2), unless your Vehicle Schedule lists them as an onboarding cost CarmaCars pays for you';

  for d in select * from owner_stage_defs x
            where x.code in ('application', 'terms', 'agreements', 'documents', 'fleet_policy', 'inspection', 'listed')
               or (x.code = 'incorporate' and v_route = 'lease_new_corporation')
               or (x.code in ('transfer', 'registration') and v_route in ('transfer', 'co_registrant'))
            order by x.sort_order loop
    v_done := false; v_na := false; v_actor := d.actor; v_action := null; v_items := '[]'::jsonb; v_block := '{}';
    if d.code = 'application' then
      v_done := ob.id is not null;
      v_action := jsonb_build_object('owner', jsonb_build_object('label', d.owner_action, 'href', '/list-your-car/apply'));
    elsif d.code = 'terms' then
      v_done := ob.id is not null and ob.status not in ('intake') and s.id is not null;
      if ob.pending_terms is not null then v_block := v_block || 'Terms off the standard grid wait for an Admin''s approval'::text; end if;
      v_action := jsonb_build_object('admin', jsonb_build_object('label', d.staff_action,
        'href', case when ob.application_id is not null then '/admin/applications/' || ob.application_id else '/admin/owners/' || o.id || '?tab=terms' end));
    elsif d.code = 'incorporate' then
      v_corp := coalesce(ob.new_corporation, '{}'::jsonb);
      v_done := nullif(v_corp ->> 'corporation_number', '') is not null or (app.owner_stage_doc(v.id, o.id, 'corporate_documents') ->> 'state') in ('ok', 'waiting');
      select jsonb_build_object('status', r.status, 'clicked_at', r.last_clicked_at) into v_ref from incorporation_referrals r where r.owner_id = o.id order by r.last_clicked_at desc limit 1;
      v_items := jsonb_build_array(
        jsonb_build_object('label', 'Incorporate online' || coalesce(' (opened ' || app.fmt_date(nullif(v_ref ->> 'clicked_at', '')::timestamptz) || ')', ''), 'done', v_done or v_ref is not null),
        jsonb_build_object('label', 'Upload the certificate or articles of incorporation', 'done', v_done));
      v_action := jsonb_build_object('owner', case when (select app.incorporation_usable(a) from incorporation_affiliate a)
                    then jsonb_build_object('label', d.owner_action, 'href', '/go/incorporate?v=' || v.id, 'external', true, 'provider', (select provider_name from incorporation_affiliate))
                    else jsonb_build_object('label', 'Upload your corporate documents', 'href', '/owner/vehicles/' || v.id || '#documents') end,
                  'staff', jsonb_build_object('label', 'Nudge the owner to incorporate', 'op', 'nudge'));
    elsif d.code = 'agreements' then
      v_done := v_signed_ok;
      v_items := (select coalesce(jsonb_agg(jsonb_build_object('label', x ->> 'label', 'done', false, 'who', x ->> 'who')), '[]'::jsonb) from jsonb_array_elements(v_sign) x);
      if coalesce(v_ck ->> 'government_forms', '') = 'open' then v_items := v_items || jsonb_build_object('label', 'Sign the government forms (Form A and the transfer forms)', 'done', false, 'who', 'owner'); end if;
      if coalesce(v_ck ->> 'witnessed_forms', '') = 'open' then v_items := v_items || jsonb_build_object('label', 'Forms C and D signed with witnesses', 'done', false, 'who', 'owner'); end if;
      if coalesce(v_ck ->> 'signatures', '') = 'open' and jsonb_array_length(v_sign) = 0 then v_items := v_items || jsonb_build_object('label', 'The agreements are sent for signature', 'done', false, 'who', 'carmacars'); end if;
      v_owner_wait := exists (select 1 from jsonb_array_elements(v_items) x where x ->> 'who' = 'owner');
      if not v_done and not v_owner_wait then v_actor := 'admin'; v_block := v_block || 'CarmaCars still has to make or send the agreements'::text; end if;
      v_action := jsonb_build_object('owner', jsonb_build_object('label', d.owner_action,
                    'href', case when jsonb_array_length(v_sign) = 0 and coalesce(v_ck ->> 'government_forms', '') = 'open' then '/owner/sign/forms/' || v.id else '/owner/sign' end),
                  'staff', jsonb_build_object('label', d.staff_action, 'op', 'nudge'),
                  'admin', jsonb_build_object('label', 'Open the agreements', 'href', '/admin/owners/' || o.id || '?tab=terms'));
    elsif d.code = 'documents' then
      v_kinds := case when v_route in ('lease', 'lease_new_corporation') then array['corporate_documents', 'ownership_permit', 'owner_insurance_proof'] else array['owner_id', 'ownership_permit', 'owner_insurance_proof'] end;
      if v_financed then v_kinds := v_kinds || (case when v_route = 'transfer' then 'lien_payout_letter' else 'finance_party_permission' end); end if;
      v_missing := '{}'; v_waiting := '{}';
      foreach v_k in array v_kinds loop
        v_doc := app.owner_stage_doc(v.id, o.id, v_k);
        -- a financed car under Transfer: the lender's permission (Form C, 0022) is as good as the payout letter
        if v_k = 'lien_payout_letter' and v_doc ->> 'state' = 'missing' then v_doc := app.owner_stage_doc(v.id, o.id, 'finance_party_permission'); end if;
        v_items := v_items || jsonb_build_object('label', app.onboarding_photo_label(v_k), 'kind', v_k, 'done', v_doc ->> 'state' = 'ok', 'state', v_doc ->> 'state');
        if v_doc ->> 'state' in ('missing', 'rejected') then v_missing := v_missing || app.onboarding_photo_label(v_k); end if;
        if v_doc ->> 'state' = 'rejected' then v_block := v_block || format('%s not accepted: %s. Upload it again.', app.onboarding_photo_label(v_k), coalesce(nullif(v_doc ->> 'note', ''), 'see the note on the photo')); end if;
        if v_doc ->> 'state' = 'waiting' then v_waiting := v_waiting || app.onboarding_photo_label(v_k); end if;
      end loop;
      v_done := cardinality(v_missing) = 0 and cardinality(v_waiting) = 0;
      if not v_done and cardinality(v_missing) = 0 then v_actor := 'fleet'; end if;
      v_action := jsonb_build_object('owner', jsonb_build_object('label', case when cardinality(v_missing) > 0 then 'Upload: ' || array_to_string(v_missing, ', ') else 'Uploaded: CarmaCars is checking them' end,
                    'href', case when cardinality(v_missing) > 0 then '/owner/vehicles/' || v.id || '#documents' end),
                  'staff', case when cardinality(v_missing) > 0 then jsonb_build_object('label', 'Nudge the owner to upload ' || array_to_string(v_missing, ', '), 'op', 'nudge')
                                else jsonb_build_object('label', d.staff_action || ': ' || array_to_string(v_waiting, ', '), 'href', '{base}/owners/' || o.id || '#photos') end);
    elsif d.code = 'transfer' then
      v_items := jsonb_build_array(
        jsonb_build_object('label', 'The filled Form A and transfer documents (Documents > Government forms)', 'done', v_gov_ok),
        jsonb_build_object('label', case when ob.registry_visit_at is not null then format('Appointment: %s%s', app.fmt_at(ob.registry_visit_at), coalesce(', ' || ob.registry_place, '')) else 'A ServiceOntario appointment or visit' end, 'done', ob.registry_visit_at is not null or pl.visited_at is not null));
      if v_route = 'transfer' and coalesce(pl.uvip_needed, true) then
        v_items := v_items || jsonb_build_object('label', 'The Used Vehicle Information Package', 'done', v_uvip, 'kind', 'uvip', 'href', st.owner_stage_uvip_url);
      end if;
      if v_route = 'transfer' and coalesce(pl.ssc_needed, true) then
        v_items := v_items || jsonb_build_object('label', 'The Safety Standards Certificate (a licensed inspection station)', 'done', v_ssc, 'kind', 'safety_certificate');
      end if;
      v_items := v_items || jsonb_build_object('label', 'Fees paid: ' || v_payer, 'done', pl.fees_paid_at is not null)
                         || jsonb_build_object('label', 'The transfer is filed at ServiceOntario', 'done', pl.visited_at is not null);
      v_done := pl.visited_at is not null or v_has_reg;
      if not v_gov_ok then v_block := v_block || 'Sign the government forms first: they are printed for the counter'::text; end if;
      if v_route = 'transfer' and coalesce(pl.uvip_needed, true) and not v_uvip then v_block := v_block || 'Get the Used Vehicle Information Package before the visit (ServiceOntario, online or at the counter)'::text; end if;
      if v_route = 'transfer' and coalesce(pl.ssc_needed, true) and not v_ssc then v_block := v_block || 'Get a Safety Standards Certificate at a licensed inspection station (about 1 hour)'::text; end if;
      v_action := jsonb_build_object('owner', case when ob.registry_visit_at is null
                      then jsonb_build_object('label', d.owner_action, 'op', 'appointment', 'href', st.owner_stage_finder_url, 'external', true)
                      else jsonb_build_object('label', format('Go to ServiceOntario %s, then press Transfer done', app.fmt_at(ob.registry_visit_at)), 'op', 'visited') end,
                  'staff', case when ob.registry_visit_at is null then jsonb_build_object('label', d.staff_action, 'op', 'appointment')
                                else jsonb_build_object('label', 'Record the visit: transfer filed', 'op', 'visited') end);
    elsif d.code = 'registration' then
      v_done := v_has_reg;
      v_action := jsonb_build_object('owner', jsonb_build_object('label', d.owner_action, 'href', '/owner/vehicles/' || v.id || '#documents'),
                  'staff', jsonb_build_object('label', d.staff_action, 'op', 'nudge'));
    elsif d.code = 'fleet_policy' then
      v_done := coalesce(v.on_fleet_policy, false) or ob.on_fleet_policy_at is not null;
      v_items := jsonb_build_array(jsonb_build_object('label', 'Plate' || coalesce(': ' || v.plate, ''), 'done', v.plate is not null),
                                   jsonb_build_object('label', 'On the fleet insurance policy', 'done', v_done));
      if v.plate is null then v_block := v_block || 'The plate number is not on the car yet: add it on the car''s page'::text; end if;
      v_action := jsonb_build_object('fleet', jsonb_build_object('label', d.staff_action, 'op', 'insure'));
    elsif d.code = 'inspection' then
      v_done := pl.inspected_at is not null and v_photos;
      v_items := jsonb_build_array(jsonb_build_object('label', 'Inspected' || coalesce(' ' || app.fmt_date(pl.inspected_at), ''), 'done', pl.inspected_at is not null),
                                   jsonb_build_object('label', 'Listing photos', 'done', v_photos));
      v_action := jsonb_build_object('fleet', case when pl.inspected_at is null then jsonb_build_object('label', d.staff_action, 'op', 'inspected')
                                                   else jsonb_build_object('label', 'Shoot and process the listing photos', 'href', '{base}/listings') end);
    elsif d.code = 'listed' then
      v_done := v_listed;
      v_action := jsonb_build_object('admin', jsonb_build_object('label', d.staff_action, 'href', '/admin/listings'));
    end if;
    -- an Admin's override wins over the records
    v_ov := pl.overrides -> d.code;
    if v_ov is not null then
      if v_ov ->> 'status' = 'done' then v_done := true; elsif v_ov ->> 'status' = 'not_needed' then v_na := true; elsif v_ov ->> 'status' = 'open' then v_done := false; end if;
    end if;
    v_state := case when v_na then 'not_needed' when v_done then 'done' when v_current is null then 'current' else 'todo' end;
    v_n := v_n + 1;
    if v_state in ('done', 'not_needed') then v_count_done := v_count_done + 1; end if;
    v_stages := v_stages || jsonb_build_object('code', d.code, 'label', d.label, 'state', v_state, 'actor', v_actor, 'items', v_items,
      'override', v_ov,
      'action', case when v_state = 'current' then v_action end,
      'blockers', case when v_state = 'current' then to_jsonb(v_block) else '[]'::jsonb end,
      'bring', case when v_state = 'current' then d.bring end, 'where', case when v_state = 'current' then d.where_text end,
      'where_url', case when v_state = 'current' and d.code = 'transfer' then st.owner_stage_finder_url end,
      'expected', d.expected, 'call_script', d.call_script,
      'owner_text', d.owner_action, 'staff_text', d.staff_action);
    if v_state = 'current' then v_current := v_stages -> -1; end if;
  end loop;
  return jsonb_build_object('vehicle_id', v.id, 'name', app.vehicle_name(v.id), 'plate', v.plate, 'owner_id', o.id,
    'owner_name', coalesce(o.corporation_name, o.legal_name), 'route', v_route, 'route_label', app.owner_stage_route_label(v_route), 'method', v_method,
    'stages', v_stages, 'current', v_current, 'stage', v_current ->> 'code', 'actor', v_current ->> 'actor', 'done', v_count_done, 'total', v_n,
    'stage_since', pl.stage_since, 'days_in_stage', case when pl.stage_since is not null and pl.stage = v_current ->> 'code' then (app.today() - app.local_date(pl.stage_since)) end,
    'last_nudge_at', pl.last_nudge_at, 'nudges', coalesce(pl.nudges, 0), 'fees_payer', v_payer,
    'uvip_needed', coalesce(pl.uvip_needed, v_route = 'transfer'), 'ssc_needed', coalesce(pl.ssc_needed, v_route = 'transfer'),
    'appointment_at', ob.registry_visit_at, 'appointment_place', ob.registry_place);
end $$;

-- ================================================================ 7. keeping the pipeline: the row, the notices, the To dos
create function app.owner_stage_first_name(o owners) returns text
language sql stable as $$ select coalesce(nullif(btrim(o.first_name), ''), split_part(coalesce(o.signing_officer_name, o.legal_name), ' ', 1)) $$;

create function app.owner_stage_refresh(p_vehicle uuid, p_quiet boolean default false) returns jsonb
language plpgsql security definer set search_path = public, app, pg_temp as $$
declare
  t jsonb;
  pl owner_pipeline;
  o owners;
  st program_settings := app.settings();
  v_stage text;
  v_actor text;
  v_moved boolean;
  v_task uuid;
  v_base text := rtrim(coalesce(st.notify_base_url, 'https://carmacars.ca'), '/');
  v_queue text;
  v_sales uuid;
begin
  if p_vehicle is null then return null; end if;
  if not app.owner_stage_applies(p_vehicle) then
    update owner_pipeline set finished_at = coalesce(finished_at, now()) where vehicle_id = p_vehicle and finished_at is null;
    return null;
  end if;
  t := app.owner_stage_track(p_vehicle);
  if t is null then return null; end if;
  v_stage := coalesce(t ->> 'stage', 'listed');
  v_actor := t ->> 'actor';
  select * into pl from owner_pipeline where vehicle_id = p_vehicle for update;
  if pl.vehicle_id is null then
    insert into owner_pipeline (vehicle_id, owner_id, route, stage, actor, turn_notified_stage, finished_at)
    values (p_vehicle, (t ->> 'owner_id')::uuid, t ->> 'route', v_stage, v_actor, case when p_quiet then v_stage end,
            case when t ->> 'stage' is null then now() end)
    returning * into pl;
    v_moved := not p_quiet;
  else
    v_moved := pl.stage is distinct from v_stage or pl.actor is distinct from v_actor;
    -- only a real change is written (the sweep runs every 15 minutes; the audit log keeps changes, not reads)
    if v_moved or pl.route is distinct from t ->> 'route' or (pl.finished_at is null) <> (t ->> 'stage' is not null) then
      update owner_pipeline set route = t ->> 'route', stage = v_stage, actor = v_actor,
             stage_since = case when pl.stage is distinct from v_stage then now() else stage_since end,
             stalled_stage = case when pl.stage is distinct from v_stage then null else stalled_stage end,
             finished_at = case when t ->> 'stage' is null then coalesce(finished_at, now()) else null end
       where vehicle_id = p_vehicle returning * into pl;
    end if;
  end if;
  if not v_moved then return t; end if;
  -- the To dos of earlier stages close by themselves
  update tasks set status = 'done', completed_at = now(), completion_note = 'Closed by itself: the owner pipeline moved on'
   where vehicle_id = p_vehicle and task_type in ('owner_stage_turn', 'owner_stage_stalled') and status in ('open', 'in_progress', 'waiting')
     and dedupe_key is distinct from 'owner_stage:' || p_vehicle || ':' || v_stage || ':' || coalesce(v_actor, '');
  if p_quiet or not st.owner_stage_enabled or t ->> 'stage' is null then return t; end if;
  select * into o from owners where id = pl.owner_id;
  if v_actor = 'owner' then
    if pl.turn_notified_stage is distinct from v_stage and o.user_id is not null then
      perform app.ntf_emit('owner_stage_your_turn', 'owner', o.id, 'stage:' || p_vehicle || ':' || v_stage, app.owner_stage_payload(t, o, v_base));
      update owner_pipeline set turn_notified_stage = v_stage, turn_notified_at = now() where vehicle_id = p_vehicle;
    end if;
  elsif v_actor in ('admin', 'fleet', 'sales') then
    v_queue := v_actor;
    v_sales := case when v_actor = 'sales' and app.user_va_has(o.recruited_by, 'sales') then o.recruited_by end;
    v_task := app.raise_task(p_type => 'owner_stage_turn', p_title => format('Owner pipeline: %s, %s', t #>> '{current,label}', t ->> 'name'),
      p_detail => format('%s (%s). Next: %s. Expected: %s.', t ->> 'owner_name', t ->> 'route_label', t #>> '{current,staff_text}', t #>> '{current,expected}'),
      p_vehicle => p_vehicle, p_owner => o.id, p_related_table => 'owner_pipeline', p_queue => v_queue,
      p_dedupe => 'owner_stage:' || p_vehicle || ':' || v_stage || ':' || v_actor);
    if v_sales is not null then update tasks set assigned_to = v_sales where id = v_task and assigned_to is null; end if;
  end if;
  return t;
end $$;

create function app.owner_stage_payload(t jsonb, o owners, p_base text) returns jsonb
language sql stable security definer set search_path = public, app, pg_temp as $$
  select jsonb_build_object('owner_id', o.id, 'vehicle_id', t ->> 'vehicle_id', 'first_name', app.owner_stage_first_name(o), 'vehicle_name', t ->> 'name',
    'stage_label', t #>> '{current,label}', 'step_number', ((t ->> 'done')::integer + 1)::text, 'step_total', t ->> 'total',
    'action_text', coalesce(t #>> '{current,action,owner,label}', t #>> '{current,owner_text}'),
    'bring_text', coalesce(t #>> '{current,bring}', ''), 'where_text', coalesce(t #>> '{current,where}', ''),
    'expected', coalesce(t #>> '{current,expected}', ''),
    'blockers_text', coalesce((select string_agg(x #>> '{}', E'\n') from jsonb_array_elements(t #> '{current,blockers}') x), ''),
    'has_blockers', jsonb_array_length(coalesce(t #> '{current,blockers}', '[]'::jsonb)) > 0,
    'stage_url', p_base || '/owner/vehicles/' || (t ->> 'vehicle_id') || '#stages')
$$;

-- Every 15 minutes: every onboarding car of the program is in the pipeline, each row is brought up to date, and a stage
-- waiting longer than the stall days alerts the Admins (once per stage) and gives the salesperson (else an Admin) a To do.
create function app.owner_stage_sweep() returns jsonb
language plpgsql security definer set search_path = public, app, pg_temp as $$
declare
  r record;
  st program_settings := app.settings();
  n integer := 0;
  v_stalled integer := 0;
  t jsonb;
  o owners;
  v_task uuid;
  v_sales uuid;
begin
  for r in select v.id from vehicles v join vehicle_onboardings ob on ob.vehicle_id = v.id
            where v.status in ('onboarding', 'ready_to_list') and ob.status not in ('declined', 'withdrawn', 'enrolled')
              and not exists (select 1 from owner_pipeline p where p.vehicle_id = v.id)
           union
           select p.vehicle_id from owner_pipeline p where p.finished_at is null loop
    begin
      perform app.owner_stage_refresh(r.id);
      n := n + 1;
    exception when others then
      insert into audit_log (action, entity_table, entity_id, after) values ('owner_stage_refresh_failed', 'vehicles', r.id::text, jsonb_build_object('error', left(sqlerrm, 300)));
    end;
  end loop;
  if not st.owner_stage_enabled then return jsonb_build_object('cars', n, 'stalled', 0); end if;
  for r in select p.* from owner_pipeline p
            where p.finished_at is null and p.stalled_stage is distinct from p.stage
              and app.today() - app.local_date(p.stage_since) >= st.owner_stage_stall_days loop
    t := app.owner_stage_track(r.vehicle_id);
    continue when t is null or t ->> 'stage' is null;
    select * into o from owners where id = r.owner_id;
    perform app.ntf_emit('staff_owner_stage_stalled', 'owner', o.id, 'stall:' || r.vehicle_id || ':' || r.stage, jsonb_build_object('owner_id', o.id, 'vehicle_id', r.vehicle_id,
      'owner_name', t ->> 'owner_name', 'vehicle_name', t ->> 'name', 'stage_label', t #>> '{current,label}', 'days', (app.today() - app.local_date(r.stage_since))::text,
      'waits_on', case t ->> 'actor' when 'owner' then 'the owner' when 'sales' then 'Sales' when 'fleet' then 'Fleet' else 'an Admin' end,
      'next_step', coalesce(t #>> '{current,staff_text}', ''),
      'salesperson', coalesce((select u.full_name from users u where u.id = o.recruited_by), 'nobody (CarmaCars)')));
    v_sales := case when app.user_va_has(o.recruited_by, 'sales') then o.recruited_by end;
    v_task := app.raise_task(p_type => 'owner_stage_stalled', p_title => format('Stalled %s days: %s, %s', app.today() - app.local_date(r.stage_since), t #>> '{current,label}', t ->> 'name'),
      p_detail => format('%s has waited in "%s" since %s (waiting on %s). Call them with the stage''s call script on the Owner pipeline, nudge them, or move it forward.',
                         t ->> 'owner_name', t #>> '{current,label}', app.fmt_date(r.stage_since), coalesce(t ->> 'actor', 'CarmaCars')),
      p_vehicle => r.vehicle_id, p_owner => o.id, p_related_table => 'owner_pipeline', p_queue => case when v_sales is not null then 'sales' else 'admin' end,
      p_priority => 'high', p_dedupe => 'owner_stage_stalled:' || r.vehicle_id || ':' || r.stage);
    if v_sales is not null then update tasks set assigned_to = v_sales where id = v_task and assigned_to is null; end if;
    update owner_pipeline set stalled_stage = r.stage, stalled_at = now() where vehicle_id = r.vehicle_id;
    v_stalled := v_stalled + 1;
  end loop;
  return jsonb_build_object('cars', n, 'stalled', v_stalled);
end $$;

-- ================================================================ 8. who sees and does what
-- admin; staff (customer service, Fleet: every owner); sales (the owners they brought in); owner (their own)
create function app.owner_stage_viewer(p_by uuid, p_owner uuid) returns text
language sql stable security definer set search_path = public, app, pg_temp as $$
  select case when app.user_is_admin(p_by) then 'admin'
              when app.user_va_has(p_by, 'cs', 'fleet') then 'staff'
              when app.user_va_has(p_by, 'sales') and exists (select 1 from owners o where o.id = p_owner and o.recruited_by = p_by) then 'sales'
              when app.user_is_owner_of(p_by, p_owner) then 'owner' end
$$;

-- p: {owner_id} or {vehicle_id}: the tracks of the owner's cars (or the one car) for the viewer
create function app.owner_stages(p_by uuid, p jsonb) returns jsonb
language plpgsql stable security definer set search_path = public, app, pg_temp as $$
declare
  v_owner uuid := coalesce(nullif(p ->> 'owner_id', '')::uuid, (select owner_id from vehicles where id = nullif(p ->> 'vehicle_id', '')::uuid));
  v_viewer text;
  st program_settings := app.settings();
  a incorporation_affiliate;
begin
  if v_owner is null or not exists (select 1 from owners where id = v_owner) then raise exception 'Owner not found' using errcode = 'P0002'; end if;
  v_viewer := app.owner_stage_viewer(p_by, v_owner);
  if v_viewer is null then raise exception 'Not permitted' using errcode = '42501'; end if;
  select * into a from incorporation_affiliate;
  return jsonb_build_object('viewer', v_viewer, 'owner_id', v_owner, 'can_override', v_viewer = 'admin',
    'can_nudge', v_viewer in ('admin', 'staff', 'sales'), 'can_record', v_viewer in ('admin', 'staff'),
    'stall_days', st.owner_stage_stall_days, 'finder_url', st.owner_stage_finder_url,
    'agent', (select split_part(coalesce(nullif(btrim(u.full_name), ''), 'CarmaCars'), ' ', 1) from users u where u.id = p_by),
    'incorporation', jsonb_build_object('usable', app.incorporation_usable(a), 'provider', a.provider_name),
    'cars', (select coalesce(jsonb_agg(t order by x.created_at), '[]'::jsonb) from (
               select v.created_at, app.owner_stage_track(v.id) as t from vehicles v
                where v.owner_id = v_owner and (nullif(p ->> 'vehicle_id', '') is null or v.id = (p ->> 'vehicle_id')::uuid)
                  and app.owner_stage_applies(v.id)
                  and (exists (select 1 from vehicle_onboardings ob where ob.vehicle_id = v.id and ob.status <> 'enrolled')
                       or exists (select 1 from owner_pipeline pl where pl.vehicle_id = v.id and pl.finished_at is null))) x where x.t is not null));
end $$;

-- The Owner pipeline board: every car in the pipeline (a salesperson: the owners they brought in), by stage
create function app.owner_stage_board(p_by uuid, p jsonb) returns jsonb
language plpgsql stable security definer set search_path = public, app, pg_temp as $$
declare
  v_all boolean := app.user_is_admin(p_by) or app.user_va_has(p_by, 'cs', 'fleet');
  v_sales boolean := app.user_va_has(p_by, 'sales');
  st program_settings := app.settings();
begin
  if not (v_all or v_sales) then raise exception 'Not permitted' using errcode = '42501'; end if;
  return jsonb_build_object('viewer', case when app.user_is_admin(p_by) then 'admin' when v_all then 'staff' else 'sales' end, 'stall_days', st.owner_stage_stall_days,
    'stages', (select jsonb_agg(jsonb_build_object('code', d.code, 'label', d.label, 'call_script', d.call_script, 'expected', d.expected) order by d.sort_order) from owner_stage_defs d),
    'agent', (select split_part(coalesce(u.full_name, 'CarmaCars'), ' ', 1) from users u where u.id = p_by),
    'cars', (select coalesce(jsonb_agg(c order by (c ->> 'days_in_stage')::integer desc nulls last, c ->> 'owner_name'), '[]'::jsonb) from (
      select jsonb_build_object('vehicle_id', pl.vehicle_id, 'owner_id', pl.owner_id, 'owner_name', coalesce(o.corporation_name, o.legal_name), 'first_name', app.owner_stage_first_name(o),
        'phone', case when v_all or o.recruited_by = p_by then o.phone end, 'email', case when v_all or o.recruited_by = p_by then o.email end,
        'car', app.vehicle_name(pl.vehicle_id), 'plate', v.plate, 'route', pl.route, 'route_label', app.owner_stage_route_label(pl.route),
        'stage', pl.stage, 'stage_label', d.label, 'actor', pl.actor, 'days_in_stage', app.today() - app.local_date(pl.stage_since), 'stage_since', pl.stage_since,
        'stalled', app.today() - app.local_date(pl.stage_since) >= st.owner_stage_stall_days,
        'next_action', case when pl.actor = 'owner' then d.owner_action else d.staff_action end,
        'salesperson', (select u.full_name from users u where u.id = o.recruited_by),
        'last_nudge_at', pl.last_nudge_at, 'nudges', pl.nudges, 'has_login', o.user_id is not null) as c
        from owner_pipeline pl join owners o on o.id = pl.owner_id join vehicles v on v.id = pl.vehicle_id join owner_stage_defs d on d.code = pl.stage
       where pl.finished_at is null and (v_all or o.recruited_by = p_by)
       limit 500) y));
end $$;

-- p: {vehicle_id, op, ...}
--   appointment {at, place}            the ServiceOntario appointment (the owner, staff, the owner's salesperson)
--   visited {fees_paid, fees_note}     the transfer is filed at the counter (the owner, staff)
--   needs {uvip_needed, ssc_needed}    whether this transfer needs a UVIP or a safety certificate (an Admin, Fleet)
--   inspected {note}                   the car was inspected (an Admin, Fleet)
--   nudge {preview}                    a branded email and text to the owner about their step (staff, the salesperson; once in 10 minutes a car)
--   set {stage, status, note}          an Admin overrides a stage: done, not_needed, open, or null to follow the records again
--   advance {note}                     an Admin marks the current stage done
create function app.owner_stage_do(p_by uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app, pg_temp as $$
declare
  v_op text := coalesce(p ->> 'op', '');
  v vehicles;
  o owners;
  pl owner_pipeline;
  t jsonb;
  v_viewer text;
  v_at timestamptz;
  v_place text := nullif(left(btrim(coalesce(p ->> 'place', '')), 200), '');
  v_note text := nullif(left(btrim(coalesce(p ->> 'note', '')), 500), '');
  v_stage text;
  v_status text;
  v_before jsonb;
  v_base text := rtrim(coalesce((app.settings()).notify_base_url, 'https://carmacars.ca'), '/');
begin
  select * into v from vehicles where id = nullif(p ->> 'vehicle_id', '')::uuid;
  if v.id is null then raise exception 'Car not found' using errcode = 'P0002'; end if;
  select * into o from owners where id = v.owner_id;
  v_viewer := app.owner_stage_viewer(p_by, o.id);
  if v_viewer is null then raise exception 'Not permitted' using errcode = '42501'; end if;
  if not app.owner_stage_applies(v.id) then raise exception '% is not onboarding in the owner program', app.vehicle_name(v.id) using errcode = '23514'; end if;
  perform app.owner_stage_refresh(v.id, true);
  select * into pl from owner_pipeline where vehicle_id = v.id for update;
  t := app.owner_stage_track(v.id);
  if v_op = 'appointment' then
    v_at := nullif(p ->> 'at', '')::timestamptz;
    if v_at is null then raise exception 'Enter the date and time of the appointment' using errcode = '22023'; end if;
    if v_at < now() - interval '30 days' or v_at > now() + interval '120 days' then raise exception 'Check the date of the appointment' using errcode = '22023'; end if;
    if v_place is null then raise exception 'Which ServiceOntario centre? (its name or address)' using errcode = '22023'; end if;
    update vehicle_onboardings set registry_visit_at = v_at, registry_place = v_place where vehicle_id = v.id;
    insert into audit_log (actor_user_id, action, entity_table, entity_id, after) values (p_by, 'owner_stage_appointment', 'vehicles', v.id::text, jsonb_build_object('at', v_at, 'place', v_place));
  elsif v_op = 'visited' then
    if v_viewer = 'sales' then raise exception 'The owner or Fleet records the visit' using errcode = '42501'; end if;
    if not exists (select 1 from jsonb_array_elements(t -> 'stages') x where x ->> 'code' = 'transfer') then raise exception 'This car''s route has no ownership transfer' using errcode = '23514'; end if;
    if coalesce((p ->> 'fees_paid')::boolean, false) is not true then raise exception 'Confirm the registry''s fees are paid (%)', t ->> 'fees_payer' using errcode = '22023'; end if;
    update owner_pipeline set visited_at = now(), visited_by = p_by, fees_paid_at = coalesce(fees_paid_at, now()), fees_note = coalesce(nullif(left(btrim(coalesce(p ->> 'fees_note', '')), 300), ''), fees_note)
     where vehicle_id = v.id;
    update vehicle_onboardings set registry_attended_by = coalesce(registry_attended_by, case when v_viewer <> 'owner' then p_by end) where vehicle_id = v.id;
    insert into audit_log (actor_user_id, action, entity_table, entity_id, after) values (p_by, 'owner_stage_visited', 'vehicles', v.id::text, jsonb_build_object('fees_note', p ->> 'fees_note'));
  elsif v_op = 'needs' then
    if v_viewer <> 'admin' and not app.user_va_has(p_by, 'fleet') then raise exception 'An Admin or Fleet decides what the transfer needs' using errcode = '42501'; end if;
    v_before := jsonb_build_object('uvip_needed', pl.uvip_needed, 'ssc_needed', pl.ssc_needed);
    update owner_pipeline set uvip_needed = case when p ? 'uvip_needed' then (p ->> 'uvip_needed')::boolean else uvip_needed end,
                              ssc_needed = case when p ? 'ssc_needed' then (p ->> 'ssc_needed')::boolean else ssc_needed end
     where vehicle_id = v.id returning * into pl;
    insert into audit_log (actor_user_id, action, entity_table, entity_id, before, after)
    values (p_by, 'owner_stage_needs', 'vehicles', v.id::text, v_before, jsonb_build_object('uvip_needed', pl.uvip_needed, 'ssc_needed', pl.ssc_needed, 'note', v_note));
  elsif v_op = 'inspected' then
    if v_viewer <> 'admin' and not app.user_va_has(p_by, 'fleet') then raise exception 'An Admin or Fleet records the inspection' using errcode = '42501'; end if;
    update owner_pipeline set inspected_at = now(), inspected_by = p_by, inspection_note = v_note where vehicle_id = v.id;
    insert into audit_log (actor_user_id, action, entity_table, entity_id, after) values (p_by, 'owner_stage_inspected', 'vehicles', v.id::text, jsonb_build_object('note', v_note));
  elsif v_op = 'nudge' then
    if v_viewer = 'owner' then raise exception 'Not permitted' using errcode = '42501'; end if;
    if o.user_id is null then raise exception 'This owner has no sign-in yet: invite them first' using errcode = '23514'; end if;
    if nullif(btrim(coalesce(o.email, '')), '') is null then raise exception 'This owner has no email: add one on the owner''s page' using errcode = '23514'; end if;
    if t ->> 'stage' is null then raise exception 'Nothing is left to do for this car' using errcode = '23514'; end if;
    if coalesce((p ->> 'preview')::boolean, false) then
      return jsonb_build_object('preview', true, 'to', o.email, 'phone', o.phone, 'will_do', format('Email %s and text %s: %s, %s', o.email, coalesce(o.phone, '(no phone)'), t #>> '{current,label}', coalesce(t #>> '{current,action,owner,label}', t #>> '{current,owner_text}')));
    end if;
    if pl.last_nudge_at > now() - interval '10 minutes' then raise exception 'A reminder went for this car less than 10 minutes ago' using errcode = '23514'; end if;
    perform app.ntf_emit('owner_stage_nudge', 'owner', o.id, 'n' || v.id || ':' || extract(epoch from clock_timestamp())::bigint,
      app.owner_stage_payload(t, o, v_base) || jsonb_build_object('agent', coalesce((select split_part(u.full_name, ' ', 1) from users u where u.id = p_by), 'CarmaCars')));
    update owner_pipeline set last_nudge_at = now(), last_nudge_by = p_by, nudges = nudges + 1 where vehicle_id = v.id;
    insert into audit_log (actor_user_id, action, entity_table, entity_id, after) values (p_by, 'owner_stage_nudge', 'vehicles', v.id::text, jsonb_build_object('stage', t ->> 'stage'));
    return jsonb_build_object('sent', true, 'to', o.email, 'track', app.owner_stage_track(v.id));
  elsif v_op in ('set', 'advance') then
    if v_viewer <> 'admin' then raise exception 'Only an Admin overrides a stage' using errcode = '42501'; end if;
    if v_note is null then raise exception 'Say why (it is kept in the audit log)' using errcode = '22023'; end if;
    v_stage := case when v_op = 'advance' then t ->> 'stage' else nullif(p ->> 'stage', '') end;
    v_status := case when v_op = 'advance' then 'done' else nullif(p ->> 'status', '') end;
    if v_stage is null then raise exception 'Nothing is left to advance for this car' using errcode = '23514'; end if;
    if not exists (select 1 from jsonb_array_elements(t -> 'stages') x where x ->> 'code' = v_stage) then raise exception 'This car''s route has no stage %', v_stage using errcode = '22023'; end if;
    if v_status is not null and v_status not in ('done', 'not_needed', 'open') then raise exception 'A stage is set to done, not needed or open' using errcode = '22023'; end if;
    v_before := pl.overrides -> v_stage;
    update owner_pipeline set overrides = case when v_status is null then overrides - v_stage
                                               else overrides || jsonb_build_object(v_stage, jsonb_build_object('status', v_status, 'by', p_by, 'at', now(), 'note', v_note)) end
     where vehicle_id = v.id;
    insert into audit_log (actor_user_id, action, entity_table, entity_id, before, after)
    values (p_by, 'owner_stage_override', 'vehicles', v.id::text, jsonb_build_object('stage', v_stage, 'override', v_before, 'current', t ->> 'stage'),
            jsonb_build_object('stage', v_stage, 'status', v_status, 'note', v_note));
  else
    raise exception 'Unknown owner pipeline operation' using errcode = '22023';
  end if;
  return jsonb_build_object('ok', true, 'track', app.owner_stage_refresh(v.id));
end $$;

-- ================================================================ 9. B: the incorporation referral
create function app.incorporation_usable(a incorporation_affiliate) returns boolean
language sql immutable as $$ select coalesce(a.enabled and a.link_template is not null, false) $$;

-- the /go/incorporate redirect, for the signed-in owner of the car: the referral is recorded, the link returned
create function public.server_incorporation_click(p_by uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app, pg_temp as $$
declare
  a incorporation_affiliate;
  v vehicles;
  r incorporation_referrals;
  v_code text;
begin
  select * into a from incorporation_affiliate;
  if not app.incorporation_usable(a) then return jsonb_build_object('ok', false); end if;
  select * into v from vehicles where id = nullif(p ->> 'vehicle_id', '')::uuid;
  if v.id is null or not app.user_owns_vehicle(p_by, v.id) then return jsonb_build_object('ok', false); end if;
  if not app.rate_limit('inc:' || p_by, 30, interval '1 hour') then return jsonb_build_object('ok', false); end if;
  select * into r from incorporation_referrals where owner_id = v.owner_id and provider_name = a.provider_name for update;
  if r.id is null then
    v_code := 'CC' || upper(substr(replace(v.owner_id::text, '-', ''), 1, 8));
    insert into incorporation_referrals (owner_id, vehicle_id, provider_name, ref_code) values (v.owner_id, v.id, a.provider_name, v_code)
    on conflict (owner_id, provider_name) do update set clicks = incorporation_referrals.clicks + 1, last_clicked_at = now()
    returning * into r;
  else
    update incorporation_referrals set clicks = clicks + 1, last_clicked_at = now(), vehicle_id = coalesce(vehicle_id, v.id) where id = r.id returning * into r;
  end if;
  return jsonb_build_object('ok', true, 'url', replace(a.link_template, '{ref}', r.ref_code), 'ref', r.ref_code, 'provider', a.provider_name);
end $$;

create function app.incorporation_referral_read(p_by uuid, p jsonb) returns jsonb
language plpgsql stable security definer set search_path = public, app, pg_temp as $$
declare a incorporation_affiliate;
begin
  perform app.assert_admin(p_by);
  select * into a from incorporation_affiliate;
  return jsonb_build_object('today', app.today(),
    'settings', jsonb_build_object('provider_name', a.provider_name, 'link_template', a.link_template, 'commission_note', a.commission_note, 'signup_url', a.signup_url,
                                   'enabled', a.enabled, 'usable', app.incorporation_usable(a), 'updated_at', a.updated_at),
    'totals', jsonb_build_object('referred', (select count(*) from incorporation_referrals where status <> 'void'),
      'incorporated', (select count(*) from incorporation_referrals where status in ('incorporated', 'commission_received')),
      'received_cents', (select coalesce(sum(commission_cents), 0) from incorporation_referrals where status = 'commission_received'),
      'waiting', (select count(*) from owner_pipeline where finished_at is null and stage = 'incorporate')),
    'referrals', (select coalesce(jsonb_agg(jsonb_build_object('id', r.id, 'owner_id', r.owner_id, 'owner', coalesce(o.corporation_name, o.legal_name), 'car', app.vehicle_name(r.vehicle_id),
                     'provider', r.provider_name, 'ref_code', r.ref_code, 'clicks', r.clicks, 'first_clicked_at', r.first_clicked_at, 'last_clicked_at', r.last_clicked_at,
                     'status', r.status, 'incorporated_on', r.incorporated_on, 'commission_cents', r.commission_cents, 'commission_on', r.commission_on, 'note', r.note)
                     order by r.first_clicked_at desc), '[]'::jsonb)
                    from incorporation_referrals r join owners o on o.id = r.owner_id));
end $$;

-- p: {provider_name, link_template, commission_note, enabled}. A link pasted for the first time turns it on unless enabled is false.
create function app.incorporation_referral_save(p_by uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app, pg_temp as $$
declare
  a incorporation_affiliate;
  o incorporation_affiliate;
  v_url text := case when p ? 'link_template' then nullif(btrim(coalesce(p ->> 'link_template', '')), '') end;
  v_on boolean;
begin
  perform app.assert_admin(p_by);
  select * into o from incorporation_affiliate for update;
  if v_url is not null and v_url !~ '^https://[^[:space:]]+$' then raise exception 'Paste the affiliate link exactly as the provider gives it: it starts with https://' using errcode = '22023'; end if;
  v_on := coalesce((p ->> 'enabled')::boolean, case when v_url is not null and o.link_template is null then true else o.enabled end);
  if v_on and coalesce(case when p ? 'link_template' then v_url else o.link_template end, '') = '' then raise exception 'Paste the affiliate link before turning the referral on' using errcode = '22023'; end if;
  update incorporation_affiliate set
    provider_name = coalesce(nullif(btrim(coalesce(p ->> 'provider_name', '')), ''), provider_name),
    link_template = case when p ? 'link_template' then v_url else link_template end,
    commission_note = coalesce(nullif(btrim(coalesce(p ->> 'commission_note', '')), ''), commission_note),
    enabled = v_on, updated_by = p_by, updated_at = now()
   returning * into a;
  insert into audit_log (actor_user_id, action, entity_table, entity_id, before, after)
  values (p_by, 'incorporation_referral_save', 'incorporation_affiliate', 'singleton', jsonb_build_object('provider', o.provider_name, 'enabled', o.enabled, 'has_link', o.link_template is not null),
          jsonb_build_object('provider', a.provider_name, 'enabled', a.enabled, 'has_link', a.link_template is not null));
  return jsonb_build_object('enabled', a.enabled, 'usable', app.incorporation_usable(a));
end $$;

-- p: {id, status: incorporated | commission_received | void | clicked, incorporated_on, commission_cents, commission_on, note}
create function app.incorporation_referral_mark(p_by uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app, pg_temp as $$
declare
  r incorporation_referrals;
  v_status text := nullif(p ->> 'status', '');
  v_cents bigint := nullif(p ->> 'commission_cents', '')::bigint;
begin
  perform app.assert_admin(p_by);
  select * into r from incorporation_referrals where id = nullif(p ->> 'id', '')::uuid for update;
  if r.id is null then raise exception 'Referral not found' using errcode = 'P0002'; end if;
  if v_status not in ('clicked', 'incorporated', 'commission_received', 'void') then raise exception 'Choose incorporated, commission received, clicked or void' using errcode = '22023'; end if;
  if v_status = 'commission_received' and (v_cents is null or v_cents <= 0) then raise exception 'Enter the commission received' using errcode = '22023'; end if;
  update incorporation_referrals set status = v_status,
    incorporated_on = case when v_status in ('incorporated', 'commission_received') then coalesce(nullif(p ->> 'incorporated_on', '')::date, incorporated_on, app.today()) else incorporated_on end,
    commission_cents = case when v_status = 'commission_received' then v_cents else commission_cents end,
    commission_on = case when v_status = 'commission_received' then coalesce(nullif(p ->> 'commission_on', '')::date, app.today()) else commission_on end,
    note = coalesce(nullif(left(btrim(coalesce(p ->> 'note', '')), 500), ''), note), updated_by = p_by
   where id = r.id returning * into r;
  return jsonb_build_object('id', r.id, 'status', r.status);
end $$;

-- ================================================================ 10. the door
alter function app.door(uuid, text, text, text, jsonb) rename to door_pre4511;
create function app.door(p_user uuid, p_aal text, p_call text, p_name text, p jsonb default '{}'::jsonb) returns jsonb
language plpgsql security definer set search_path = public, app, pg_temp as $$
begin
  if (p_call in ('ops_read', 'va_read', 'admin_read') and p_name in ('owner_stages', 'owner_stage_board'))
     or (p_call in ('ops_do', 'va_do', 'admin_do') and p_name = 'owner_stage_do') then
    if coalesce(p, '{}'::jsonb) ? '_va' then perform set_config('app.va_active', coalesce(p ->> '_va', ''), true); end if;
    perform app.door_begin(p_user, p_aal);
    p := coalesce(p, '{}'::jsonb) - '_va';
    return case p_name when 'owner_stages' then app.owner_stages(p_user, p) when 'owner_stage_board' then app.owner_stage_board(p_user, p) else app.owner_stage_do(p_user, p) end;
  end if;
  if (p_call = 'admin_read' and p_name = 'incorporation_referral') or (p_call = 'admin_do' and p_name in ('incorporation_referral_save', 'incorporation_referral_mark')) then
    perform app.door_begin(p_user, p_aal);
    return case p_name when 'incorporation_referral' then app.incorporation_referral_read(p_user, p) when 'incorporation_referral_save' then app.incorporation_referral_save(p_user, p)
                       else app.incorporation_referral_mark(p_user, p) end;
  end if;
  return app.door_pre4511(p_user, p_aal, p_call, p_name, p);
end $$;
select pg_temp.copy_grants('app.door(uuid, text, text, text, jsonb)'::regprocedure, 'app.door_pre4511(uuid, text, text, text, jsonb)'::regprocedure);

-- ================================================================ 11. the job (pg_cron, every 15 minutes, where available)
do $$
begin
  if not exists (select 1 from pg_available_extensions where name = 'pg_cron') then
    raise notice 'pg_cron is not available here: the owner pipeline job is not scheduled';
    return;
  end if;
  begin
    create extension if not exists pg_cron;
  exception when others then
    raise warning 'pg_cron could not be created in this database (%): the owner pipeline job is not scheduled', sqlerrm;
    return;
  end;
  perform cron.schedule('carmacars-owner-pipeline', '*/15 * * * *', $q$select app.owner_stage_sweep()$q$);
end $$;

-- ================================================================ 12. privileges: the server only
do $$
declare f record;
begin
  for f in select p.oid::regprocedure as sig from pg_proc p join pg_namespace n on n.oid = p.pronamespace
            where (n.nspname = 'app' and p.proname in ('owner_stage_method', 'owner_stage_route', 'owner_stage_route_label', 'owner_stage_applies', 'owner_stage_doc',
                     'owner_stage_track', 'owner_stage_first_name', 'owner_stage_refresh', 'owner_stage_payload', 'owner_stage_sweep', 'owner_stage_viewer', 'owner_stages',
                     'owner_stage_board', 'owner_stage_do', 'incorporation_usable', 'incorporation_referral_read', 'incorporation_referral_save', 'incorporation_referral_mark',
                     'owner_register_document_pre4511', 'vehicle_document_register_pre4511', 'staff_register_vehicle_document_pre4511', 'door_pre4511'))
               or (n.nspname = 'public' and p.proname = 'server_incorporation_click') loop
    execute format('revoke all on function %s from public, anon, authenticated', f.sig);
    execute format('grant execute on function %s to service_role', f.sig);
  end loop;
end $$;

-- ================================================================ 13. backfill: every onboarding car gets its row now, quietly
-- (the owner already had the notices of the step they are on); the days in stage count from today.
do $$
declare r record; n integer := 0;
begin
  for r in select v.id from vehicles v join vehicle_onboardings ob on ob.vehicle_id = v.id
            where v.status in ('onboarding', 'ready_to_list') and ob.status not in ('declined', 'withdrawn', 'enrolled') loop
    begin
      if app.owner_stage_refresh(r.id, true) is not null then n := n + 1; end if;
    exception when others then
      raise warning 'owner pipeline backfill: car %: %', r.id, sqlerrm;
    end;
  end loop;
  insert into audit_log (action, entity_table, entity_id, after) values ('owner_pipeline_backfill', 'owner_pipeline', '4511', jsonb_build_object('cars', n));
end $$;
