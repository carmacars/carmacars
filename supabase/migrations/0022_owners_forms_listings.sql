-- 0022_owners_forms_listings.sql
-- Part A: form drafts, leads, the owner application and onboarding (one owner, many vehicles,
--         six ownership situations, terms, schedules, estimates, government form pre-fill,
--         the onboarding checklist, exit, fee changes, bank changes, owner portal reads).
-- Part B: the listing pipeline (intakes, VIN decodes, the job queue, provider calls, photos,
--         review, publishing, slugs, redirects and the public reads for the website).
--
-- Sources: docs/source/v2_enrollment.md, v2_title_holding.md, owner_billing_spec.md,
-- operating_procedures.md (12 to 17), and docs/blueprint 01, 04, 08, 09, 14 and 99 section 3.
-- Relies on migrations 0001 to 0017, 0019 and 0020 (app.user_va_has and app.rate_limit of 0019;
-- app.user_is_field, task_rules, app.raise_task and the onboarding, invoice and exit task
-- triggers of 0020). It does not need 0018 or 0021.
--
-- Part C (last): site settings and editable content for the public website, the owner
-- checklist, exit, fee and bank changes, the owner portal reads, row-level security and grants.
--
-- Rules kept throughout:
--   * Registry costs are estimates. The owner pays the registry and other third parties
--     directly. CarmaCars collects only the tracker Install Fee and the Insurance Fees.
--   * Renters, owners and field staff change nothing directly: the server calls the functions
--     here, naming the user it acts for (p_by). Each function checks what that user may do.
--   * Events are emitted only for things that start in this file. Status changes on tables
--     that already existed are turned into events elsewhere.

-- ---------------------------------------------------------------- settings
-- Every number the functions below use is a column here (dated rows, an Admin adds a row to
-- change one) or a row in an editable table. Nothing below types a price, fee, period or limit.
alter table program_settings
  add column company_rin                  text,          -- CarmaCars' registrant identification number, for the registry forms
  add column signing_officer_name         text,          -- who signs registry forms for CarmaCars
  add column signing_officer_title        text,
  add column listing_review_required_roles text[] not null default array['owner', 'field']
    check (listing_review_required_roles <@ array['owner', 'field', 'va', 'admin']),   -- whose listings a reviewer must approve before publishing
  add column listing_min_photos           integer not null default 10 check (listing_min_photos > 0),
  add column listing_job_max_attempts     integer not null default 4 check (listing_job_max_attempts between 1 and 20),
  add column listing_job_backoff_minutes  integer[] not null default array[1, 5, 30],   -- wait before the 2nd, 3rd, 4th ... attempt (the last value repeats)
  add column listing_job_lock_minutes     integer not null default 10 check (listing_job_lock_minutes > 0),   -- a claimed job not finished in this time is claimed again
  add column photo_daily_budget_microusd  bigint not null default 10000000 check (photo_daily_budget_microusd >= 0),
  add column listing_default_home_area    text not null default 'Toronto',
  add column listing_headline_chars       int4range not null default int4range(40, 70, '[]'),
  add column listing_description_words    int4range not null default int4range(120, 220, '[]'),
  add column listing_features_count       int4range not null default int4range(6, 14, '[]'),
  add column listing_faq_count            int4range not null default int4range(3, 8, '[]'),
  add column listing_banned_phrases       text[] not null default array['look no further', 'elevate', 'seamless', 'whether you are', 'unparalleled', 'best in class'],
  add column form_draft_days              integer not null default 30 check (form_draft_days > 0),
  add column form_resume_link_hours       integer not null default 72 check (form_resume_link_hours > 0),
  add column form_submitted_keep_days     integer not null default 7 check (form_submitted_keep_days >= 0),
  add column lead_hourly_limit            integer not null default 5 check (lead_hourly_limit > 0),   -- website enquiries per network address per hour
  add column fee_change_notice_days       integer not null default 30 check (fee_change_notice_days >= 30);   -- written notice before a Fee change (the 0002 table check keeps 30 as the floor)

-- ---------------------------------------------------------------- who is acting (by user id)
-- The server acts for a named user, so these take the user's id (as app.user_is_staff() in 0016).
-- app.user_va_has(user, functions) is defined in 0019 and app.user_is_field(user) in 0020.
create or replace function app.user_is_owner_of(p_user uuid, p_owner uuid) returns boolean
language sql stable security definer set search_path = public, app as $$
  select exists (
    select 1 from owners o join users u on u.id = o.user_id join user_roles r on r.user_id = u.id and r.role = 'owner'
     where o.id = p_owner and o.user_id = p_user and u.status = 'active')
$$;

create or replace function app.user_owns_vehicle(p_user uuid, p_vehicle uuid) returns boolean
language sql stable security definer set search_path = public, app as $$
  select exists (select 1 from vehicles v where v.id = p_vehicle and app.user_is_owner_of(p_user, v.owner_id))
$$;

-- Field staff reach a vehicle only through a job assigned to them (same window as app.field_has_job()).
create or replace function app.user_field_has_job(p_user uuid, p_vehicle uuid) returns boolean
language sql stable security definer set search_path = public, app as $$
  select app.user_is_field(p_user) and exists (
    select 1 from field_jobs j
     where j.assigned_to = p_user and j.status <> 'cancelled' and j.vehicle_id = p_vehicle
       and j.scheduled_at <= now() + interval '36 hours'
       and (j.completed_at is null or j.completed_at > now() - interval '24 hours'))
$$;

-- The role a user acts in when working on onboarding or a listing: the highest they hold.
create or replace function app.acting_role(p_user uuid) returns text
language sql stable security definer set search_path = public, app as $$
  select case when p_user is null then null
              when app.user_is_admin(p_user) then 'admin'
              when app.user_va_has(p_user) then 'va'
              when app.user_is_field(p_user) then 'field'
              when exists (select 1 from owners o join users u on u.id = o.user_id
                             join user_roles r on r.user_id = u.id and r.role = 'owner'
                            where o.user_id = p_user and u.status = 'active') then 'owner'
         end
$$;

create or replace function app.vehicle_name(p_vehicle uuid) returns text
language sql stable security definer set search_path = public, app as $$
  select concat_ws(' ', v.year::text, v.make, v.model, nullif(v.trim, '')) from vehicles v where v.id = p_vehicle
$$;

-- A VIN as stored: upper case, no spaces or hyphens. Null when it is not a possible VIN
-- (17 characters, never the letters I, O or Q). The check digit is verified in the browser.
create or replace function app.clean_vin(p_vin text) returns text
language sql immutable as $$
  select case when x ~ '^[A-HJ-NPR-Z0-9]{17}$' then x end
    from (select upper(regexp_replace(coalesce(p_vin, ''), '[\s-]', '', 'g')) as x) q
$$;

-- ================================================================ PART A
-- ---------------------------------------------------------------- form drafts
-- Autosaved drafts for any form: the booking request, the owner application, the vehicle intake
-- and staff forms. A draft belongs to a signed-in user, or to a visitor who holds a token.
-- Tokens are stored hashed only. Values that must never sit in a draft (bank account numbers,
-- licence numbers, card data) are removed on every write, whoever writes.
create table form_drafts (
  id             uuid primary key default gen_random_uuid(),
  form_code      text not null check (form_code ~ '^[a-z][a-z0-9_]*$'),
  schema_version integer not null default 1 check (schema_version > 0),
  user_id        uuid references users (id) on delete cascade,
  token_hashes   text[] not null default '{}',     -- sha256 of each device token a visitor holds
  entity_table   text,                             -- the record the form edits, when there is one
  entity_id      uuid,
  step           text,
  data           jsonb not null default '{}'::jsonb check (jsonb_typeof(data) = 'object'),
  device_label   text,                             -- "phone", "laptop": shown as "Continuing from your phone"
  resume_email   text,                             -- where the last resume link was sent
  resume_link_hash text,                           -- sha256 of the emailed one-time link token
  resume_link_expires_at timestamptz,
  submitted_at   timestamptz,
  result         jsonb,                            -- what the submit returned, so a second press gets the same answer
  expires_at     timestamptz not null,               -- set from program_settings.form_draft_days on every save
  created_at     timestamptz not null default now(),
  updated_at     timestamptz not null default now(),
  check (user_id is not null or cardinality(token_hashes) > 0)
);
comment on table form_drafts is 'Autosaved form drafts. Owned by a user or by a visitor holding a token (stored hashed). Never holds bank, licence or card numbers.';
create unique index form_drafts_one_open_per_user on form_drafts
  (user_id, form_code, coalesce(entity_table, ''), coalesce(entity_id, '00000000-0000-0000-0000-000000000000'::uuid))
  where user_id is not null and submitted_at is null;
create index form_drafts_tokens_idx on form_drafts using gin (token_hashes);
create unique index form_drafts_resume_link_idx on form_drafts (resume_link_hash) where resume_link_hash is not null;
create index form_drafts_expiry_idx on form_drafts (expires_at);

create or replace function app.token_hash(p_token text) returns text
language sql immutable as $$ select encode(sha256(convert_to(p_token, 'UTF8')), 'hex') $$;

create or replace function app.new_token() returns text
language sql volatile as $$ select replace(gen_random_uuid()::text || gen_random_uuid()::text, '-', '') $$;

-- Remove the keys that must never be stored in a draft, at any depth.
create or replace function app.strip_transient(p_data jsonb) returns jsonb
language plpgsql immutable as $$
declare
  v_out jsonb;
  r record;
begin
  if p_data is null then return null; end if;
  if jsonb_typeof(p_data) = 'object' then
    v_out := '{}'::jsonb;
    for r in select key, value from jsonb_each(p_data) loop
      if lower(r.key) ~ '(account_?(no|number)|licen[cs]e_?(no|number)|card_?(no|number)|cvv|cvc|social_insurance|^sin$)' then
        continue;
      end if;
      v_out := v_out || jsonb_build_object(r.key, app.strip_transient(r.value));
    end loop;
    return v_out;
  elsif jsonb_typeof(p_data) = 'array' then
    return coalesce((select jsonb_agg(app.strip_transient(e.value) order by e.ord)
                       from jsonb_array_elements(p_data) with ordinality e(value, ord)), '[]'::jsonb);
  end if;
  return p_data;
end $$;

create or replace function app.form_draft_before_write() returns trigger
language plpgsql security definer set search_path = public, app as $$
begin
  new.data := app.strip_transient(new.data);
  new.updated_at := now();
  if tg_op = 'UPDATE' and old.submitted_at is not null and new.data is distinct from old.data and new.data <> '{}'::jsonb then
    raise exception 'This form was already submitted' using errcode = '23514';
  end if;
  return new;
end $$;
create trigger form_drafts_before_write before insert or update on form_drafts
  for each row execute function app.form_draft_before_write();

-- Save (create or update) a draft. For a signed-in user pass p_user; one open draft is kept per
-- user, form and record. For a visitor pass p_token; with neither, a new visitor draft is made
-- and its token is returned once. Saving pushes the expiry out again.
create or replace function app.save_form_draft(
  p_form_code text, p_data jsonb, p_step text default null, p_schema_version integer default 1,
  p_user uuid default null, p_token text default null,
  p_entity_table text default null, p_entity_id uuid default null, p_device_label text default null)
returns jsonb language plpgsql security definer set search_path = public, app as $$
declare
  d form_drafts;
  v_token text;
  v_expires timestamptz := now() + make_interval(days => (app.settings()).form_draft_days);
begin
  if p_data is null or jsonb_typeof(p_data) <> 'object' then
    raise exception 'A draft is a JSON object of the form''s fields' using errcode = '22023';
  end if;
  if p_user is not null then
    select * into d from form_drafts f
     where f.user_id = p_user and f.form_code = p_form_code and f.submitted_at is null
       and coalesce(f.entity_table, '') = coalesce(p_entity_table, '')
       and f.entity_id is not distinct from p_entity_id
     for update;
  elsif p_token is not null then
    select * into d from form_drafts f
     where f.token_hashes @> array[app.token_hash(p_token)] and f.form_code = p_form_code and f.submitted_at is null
     for update;
    if d.id is null then
      raise exception 'This draft is no longer available' using errcode = 'P0002';
    end if;
  end if;

  if d.id is null then
    if p_user is null then v_token := app.new_token(); end if;
    insert into form_drafts (form_code, schema_version, user_id, token_hashes, entity_table, entity_id, step, data, device_label, expires_at)
    values (p_form_code, p_schema_version, p_user,
            case when v_token is not null then array[app.token_hash(v_token)] else '{}'::text[] end,
            p_entity_table, p_entity_id, p_step, p_data, p_device_label, v_expires)
    returning * into d;
  else
    update form_drafts
       set data = p_data, step = coalesce(p_step, step), schema_version = p_schema_version,
           device_label = coalesce(p_device_label, device_label), expires_at = v_expires
     where id = d.id returning * into d;
  end if;
  return jsonb_build_object('draft_id', d.id, 'token', v_token, 'saved_at', d.updated_at, 'expires_at', d.expires_at, 'step', d.step);
end $$;

-- Load a draft: by user (and form and record), or by a visitor's token. Null when there is
-- none, it has expired or it was submitted.
create or replace function app.load_form_draft(
  p_form_code text, p_user uuid default null, p_token text default null,
  p_entity_table text default null, p_entity_id uuid default null)
returns jsonb language sql stable security definer set search_path = public, app as $$
  select jsonb_build_object('draft_id', f.id, 'form_code', f.form_code, 'schema_version', f.schema_version, 'step', f.step,
                            'data', f.data, 'device_label', f.device_label, 'saved_at', f.updated_at, 'expires_at', f.expires_at)
    from form_drafts f
   where f.form_code = p_form_code and f.submitted_at is null and f.expires_at > now()
     and ((p_user is not null and f.user_id = p_user
           and coalesce(f.entity_table, '') = coalesce(p_entity_table, '') and f.entity_id is not distinct from p_entity_id)
          or (p_user is null and p_token is not null and f.token_hashes @> array[app.token_hash(p_token)]))
   order by f.updated_at desc limit 1
$$;

-- Ask for a link to carry on with a draft on another device. Returns the one-time link token
-- for the server to email; only its hash is kept. The caller proves the draft is theirs with
-- their user id or their device token.
create or replace function app.request_draft_resume_link(p_draft uuid, p_email text, p_user uuid default null, p_token text default null)
returns text language plpgsql security definer set search_path = public, app as $$
declare
  d form_drafts;
  v_link text := app.new_token();
begin
  select * into d from form_drafts where id = p_draft for update;
  if d.id is null or d.submitted_at is not null or d.expires_at <= now()
     or not ((p_user is not null and d.user_id = p_user)
             or (p_token is not null and d.token_hashes @> array[app.token_hash(p_token)])) then
    raise exception 'This draft is no longer available' using errcode = 'P0002';
  end if;
  if coalesce(p_email, '') !~ '^[^@\s]+@[^@\s]+\.[^@\s]+$' then
    raise exception 'Enter the email address to send the link to' using errcode = '22023';
  end if;
  update form_drafts
     set resume_email = lower(btrim(p_email)), resume_link_hash = app.token_hash(v_link),
         resume_link_expires_at = now() + make_interval(hours => (app.settings()).form_resume_link_hours)
   where id = d.id;
  return v_link;
end $$;

-- Open an emailed link on another device. The link works once. A signed-in user takes the
-- draft into their account; a visitor's new device gets its own token, and the first device
-- keeps working.
create or replace function app.resume_form_draft(p_link_token text, p_user uuid default null, p_device_label text default null)
returns jsonb language plpgsql security definer set search_path = public, app as $$
declare
  d form_drafts;
  v_token text;
begin
  select * into d from form_drafts where resume_link_hash = app.token_hash(coalesce(p_link_token, '')) for update;
  if d.id is null or d.submitted_at is not null or d.expires_at <= now()
     or d.resume_link_expires_at is null or d.resume_link_expires_at <= now() then
    raise exception 'This link has expired or was already used' using errcode = 'P0002';
  end if;
  if p_user is not null and (d.user_id is null or d.user_id = p_user) then
    update form_drafts set user_id = p_user, resume_link_hash = null, resume_link_expires_at = null,
           device_label = coalesce(p_device_label, device_label)
     where id = d.id returning * into d;
  elsif p_user is not null then
    raise exception 'This draft belongs to another account' using errcode = '42501';
  else
    v_token := app.new_token();
    update form_drafts set token_hashes = token_hashes || app.token_hash(v_token), resume_link_hash = null,
           resume_link_expires_at = null, device_label = coalesce(p_device_label, device_label)
     where id = d.id returning * into d;
  end if;
  return jsonb_build_object('draft_id', d.id, 'token', v_token, 'form_code', d.form_code, 'schema_version', d.schema_version,
                            'step', d.step, 'data', d.data, 'saved_at', d.updated_at, 'expires_at', d.expires_at);
end $$;

-- Mark a draft as submitted and keep the result. A second press returns the first result.
-- The answers are cleared: the submitted records hold them now.
create or replace function app.submit_form_draft(p_draft uuid, p_result jsonb default '{}'::jsonb)
returns jsonb language plpgsql security definer set search_path = public, app as $$
declare
  d form_drafts;
begin
  select * into d from form_drafts where id = p_draft for update;
  if d.id is null then
    raise exception 'This draft is no longer available' using errcode = 'P0002';
  end if;
  if d.submitted_at is not null then
    return d.result;
  end if;
  update form_drafts set submitted_at = now(), result = coalesce(p_result, '{}'::jsonb), data = '{}'::jsonb,
         resume_link_hash = null, resume_link_expires_at = null
   where id = d.id;
  return coalesce(p_result, '{}'::jsonb);
end $$;

-- Delete drafts nobody came back to, and submitted drafts once their result is no longer
-- needed for a repeated press. Called by the retention job.
create or replace function app.purge_form_drafts(p_now timestamptz default now()) returns integer
language plpgsql security definer set search_path = public, app as $$
declare
  n integer;
begin
  delete from form_drafts
   where (submitted_at is null and expires_at <= p_now)
      or (submitted_at is not null and submitted_at <= p_now - make_interval(days => (app.settings(app.local_date(p_now))).form_submitted_keep_days));
  get diagnostics n = row_count;
  return n;
end $$;

-- ---------------------------------------------------------------- leads
-- People who wrote to us without an account: owner program enquiries and general contact.
create table leads (
  id            uuid primary key default gen_random_uuid(),
  kind          text not null check (kind in ('owner_program', 'contact', 'insurer', 'launch_notice', 'other')),
  name          text,
  email         text,
  phone         text,
  message       text,
  payload       jsonb not null default '{}'::jsonb,   -- the form's other answers (topic, vehicle, insurer, claim number)
  source        text not null default 'web',          -- web, phone, email, referral, event ...
  source_url    text,
  referrer      text,
  utm_source    text,
  utm_medium    text,
  utm_campaign  text,
  utm_term      text,
  utm_content   text,
  consent_marketing boolean not null default false,
  consent_text  text,                                  -- the exact wording the person agreed to
  consent_at    timestamptz,
  status        text not null default 'new' check (status in ('new', 'contacted', 'qualified', 'converted', 'closed', 'spam')),
  assigned_to   uuid references users (id),
  owner_id      uuid references owners (id),           -- set when the enquiry became an owner
  closed_reason text,
  created_at    timestamptz not null default now(),
  updated_at    timestamptz not null default now(),
  check (email is not null or phone is not null),
  check (not consent_marketing or (consent_text is not null and consent_at is not null))
);
create index leads_status_idx on leads (status, created_at);
create index leads_assignee_idx on leads (assigned_to, status);
create index leads_email_idx on leads (lower(email));
create trigger leads_updated before update on leads for each row execute function app.set_updated_at();

-- The public submit, called by the server for a visitor (bot check done there). Limited per
-- network address with app.rate_limit (0019): over the limit it returns {ok: false, error:
-- 'rate_limited'} and stores nothing but the count. An owner program enquiry goes to the sales
-- assistant with the fewest open leads; anything else goes to the customer service queue.
-- Returns {ok, lead_id}.
create or replace function app.submit_lead(p jsonb, p_ip text default null) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  v_id uuid := gen_random_uuid();
  v_kind text := coalesce(p ->> 'kind', 'contact');
  v_email text := nullif(lower(btrim(p ->> 'email')), '');
  v_phone text := nullif(btrim(p ->> 'phone'), '');
  v_name text := nullif(btrim(p ->> 'name'), '');
  v_consent boolean := coalesce((p ->> 'consent_marketing')::boolean, false);
  v_assignee uuid;
  v_utm jsonb := coalesce(p -> 'utm', '{}'::jsonb);
  v_set program_settings := app.settings();
  v_task uuid;
begin
  if nullif(btrim(p_ip), '') is not null
     and not app.rate_limit('lead:ip:' || btrim(p_ip), v_set.lead_hourly_limit, interval '1 hour') then
    return jsonb_build_object('ok', false, 'error', 'rate_limited');
  end if;
  if v_kind not in ('owner_program', 'contact', 'insurer', 'launch_notice', 'other') then
    raise exception 'Unknown kind of enquiry: %', v_kind using errcode = '22023';
  end if;
  if v_email is null and v_phone is null then
    raise exception 'Give an email address or a phone number so we can reply' using errcode = '22023';
  end if;
  if v_email is not null and v_email !~ '^[^@\s]+@[^@\s]+\.[^@\s]+$' then
    raise exception 'Enter a full email address, for example name@example.com' using errcode = '22023';
  end if;
  if v_consent and nullif(p ->> 'consent_text', '') is null then
    raise exception 'Marketing consent needs the wording the person agreed to' using errcode = '22023';
  end if;

  if v_kind = 'owner_program' then
    select sp.user_id into v_assignee
      from staff_profiles sp join users u on u.id = sp.user_id and u.status = 'active'
      join user_roles r on r.user_id = sp.user_id and r.role = 'va'
     where sp.staff_type = 'va' and sp.va_function = 'sales' and sp.is_active
     order by (select count(*) from leads l where l.assigned_to = sp.user_id and l.status in ('new', 'contacted', 'qualified')),
              sp.created_at, sp.user_id
     limit 1;
  end if;

  insert into leads (id, kind, name, email, phone, message, payload, source, source_url, referrer,
                     utm_source, utm_medium, utm_campaign, utm_term, utm_content,
                     consent_marketing, consent_text, consent_at, assigned_to)
  values (v_id, v_kind, v_name, v_email, v_phone, nullif(btrim(p ->> 'message'), ''),
          app.strip_transient(coalesce(p -> 'payload', '{}'::jsonb)), coalesce(nullif(p ->> 'source', ''), 'web'),
          p ->> 'source_url', p ->> 'referrer',
          coalesce(v_utm ->> 'source', p ->> 'utm_source'), coalesce(v_utm ->> 'medium', p ->> 'utm_medium'),
          coalesce(v_utm ->> 'campaign', p ->> 'utm_campaign'), coalesce(v_utm ->> 'term', p ->> 'utm_term'),
          coalesce(v_utm ->> 'content', p ->> 'utm_content'),
          v_consent, case when v_consent then p ->> 'consent_text' end, case when v_consent then now() end, v_assignee);

  -- queue, title, priority and due time come from the task rule (task_rules, editable)
  v_task := app.raise_task(p_type => case when v_kind = 'owner_program' then 'owner_lead' else 'enquiry' end,
                           p_detail => concat_ws(' ', coalesce(v_name, 'Someone'), 'wrote to us.', nullif(btrim(p ->> 'message'), '')),
                           p_related_table => 'leads', p_related_id => v_id, p_dedupe => 'lead:' || v_id);
  if v_assignee is not null then
    update tasks set assigned_to = v_assignee where id = v_task;
  end if;

  if v_kind = 'owner_program' then
    perform app.emit_event('owner_application_received', 'lead', v_id,
      jsonb_build_object('first_name', split_part(coalesce(v_name, ''), ' ', 1), 'email', v_email, 'phone', v_phone,
                         'vehicle_name', p -> 'payload' ->> 'vehicle', 'ownership_summary', p -> 'payload' ->> 'ownership',
                         'is_enquiry', true),
      'owner_application_received:' || v_id || ':lead');
    perform app.emit_event('staff_owner_application_received', 'lead', v_id,
      jsonb_build_object('owner_name', v_name, 'email', v_email, 'phone', v_phone, 'assigned_to', v_assignee,
                         'vehicle_name', p -> 'payload' ->> 'vehicle', 'is_enquiry', true),
      'staff_owner_application_received:' || v_id || ':lead');
  end if;
  return jsonb_build_object('ok', true, 'lead_id', v_id);
end $$;

-- ---------------------------------------------------------------- owners: what the agreements and registry forms need
alter table owners
  add column first_name               text,
  add column middle_name              text,
  add column last_name                text,
  add column signing_officer_name     text,      -- corporation: who signs for it
  add column signing_officer_title    text,
  add column mailing_address_line1    text,      -- only when mail goes somewhere other than the address above
  add column mailing_address_line2    text,
  add column mailing_city             text,
  add column mailing_province         text,
  add column mailing_postal_code      text;

-- The owner's driver's licence number and date of birth go on the registry forms. Three
-- assistant roles can read the owners table, and row-level security hides rows, not columns,
-- so these two values live in their own table: the owner and an Admin only.
create table owner_private_details (
  owner_id       uuid primary key references owners (id) on delete cascade,
  licence_number text,
  licence_province text default 'ON',
  date_of_birth  date check (date_of_birth is null or date_of_birth < current_date),
  updated_by     uuid references users (id),
  created_at     timestamptz not null default now(),
  updated_at     timestamptz not null default now()
);
comment on table owner_private_details is 'Licence number and date of birth of an individual owner, for the registry forms. The owner and an Admin only.';
create trigger owner_private_details_updated before update on owner_private_details for each row execute function app.set_updated_at();
-- logged without its values, like the bank tables
create trigger audit_owner_private_details after insert or update or delete on owner_private_details
  for each row execute function app.audit_row('redact');

-- Payout account changes: who sent the new details in, and how an Admin checked them.
alter table owner_payout_accounts
  add column submitted_by        uuid references users (id),
  add column verified_by         uuid references users (id),
  add column verification_method text;

-- ---------------------------------------------------------------- vehicles and onboarding: intake facts
alter table vehicles
  add column body_type           text,          -- sedan, SUV, coupe, pickup ...
  add column registration_status text check (registration_status in ('plated', 'unplated', 'unfit', 'out_of_province', 'never_registered')),
  add column spec_sources        jsonb not null default '{}'::jsonb;   -- per fact: {"source": "person" | "decoded", "by": user, "at": time}
comment on column vehicles.spec_sources is 'Where each vehicle fact came from. A fact a person entered or confirmed is never overwritten by a VIN decode.';

create sequence owner_application_number_seq start 1001;
create sequence owner_agreement_number_seq start 1001;
create sequence vehicle_schedule_number_seq start 1001;

-- One application can carry many vehicles; each vehicle then runs its own onboarding.
create table owner_applications (
  id                 uuid primary key default gen_random_uuid(),
  application_number text not null unique default ('OA-' || nextval('owner_application_number_seq')),
  owner_id           uuid not null references owners (id),
  lead_id            uuid references leads (id),
  form_draft_id      uuid references form_drafts (id) on delete set null,
  source             text not null default 'web' check (source in ('web', 'staff', 'field', 'phone', 'email', 'referral')),
  submitted_by       uuid references users (id),
  vehicle_count      integer not null default 0 check (vehicle_count >= 0),
  note               text,
  created_at         timestamptz not null default now()
);
create index owner_applications_owner_idx on owner_applications (owner_id);

alter table vehicle_onboardings
  add column application_id       uuid references owner_applications (id),
  add column held_by              owner_type,
  add column title_status         title_status,
  add column finance_party_name   text,            -- the lender (lienholder) or the lease company
  add column finance_party_account text,
  add column finance_permission   finance_permission,
  add column proposed_management_mode management_mode,
  add column proposed_onboarding_method onboarding_method,
  add column owners_lien_elected  boolean not null default false,
  add column situation            text,            -- onboarding_situations (foreign key added below)
  add column government_forms     text[] not null default '{}',
  add column sign_back_on_permit  boolean not null default false,
  add column estimate_cents       bigint check (estimate_cents >= 0),   -- information only: paid by the owner to third parties
  add column estimate_plus_tax    boolean not null default false,
  add column disclosures          jsonb,           -- open recall, structural, flood or fire damage
  add column new_corporation      jsonb,           -- Lease through a new Owner Corporation: the proposed corporation
  add column safety_certificate_document_id uuid references documents (id),
  add column appraisal_document_id uuid references documents (id),
  -- terms: the standard grid is the default; anything else needs an Admin
  add column pending_terms        jsonb,           -- terms a VA entered that are off the grid, waiting for an Admin
  add column terms_off_grid       boolean not null default false,
  add column terms_proposed_by    uuid references users (id),
  add column terms_proposed_at    timestamptz,
  add column terms_approved_by    uuid references users (id),
  add column terms_approved_at    timestamptz;
comment on column vehicle_onboardings.estimate_cents is 'Estimate only. The owner pays the registry, the safety inspection, the appraisal and other third parties directly. CarmaCars never bills it.';

-- ---------------------------------------------------------------- the six ownership situations
-- Which onboarding methods are open to a vehicle, and for each: the situation (S1 to S6 of
-- docs/blueprint/04-owner.md section 3), the registry forms and the CarmaCars forms. One row
-- per situation, editable by an Admin. Labels, estimates and the default form list come from
-- onboarding_method_info (0002, 0014). government_forms null means "the method's list"; an
-- empty list means no form to pre-fill (operating procedure 12: a Transfer of a vehicle that is
-- not leased is done by the sign-back on the ownership permit).
create table onboarding_situations (
  situation         text primary key check (situation ~ '^[A-Za-z0-9_]+$'),
  method            onboarding_method not null references onboarding_method_info (method),
  held_by           owner_type,                          -- null: an individual or a corporation
  title_statuses    title_status[] not null,
  management_modes  management_mode[] not null,
  recommended       boolean not null default false,
  government_forms  text[],                              -- null: onboarding_method_info.government_forms
  sign_back_on_permit boolean not null default false,
  carmacars_forms   text[] not null default '{}',        -- Title Agreement forms A, B, D for every vehicle of this situation
  finance_forms     text[] not null default '{}',        -- added when the vehicle is financed or leased (Form C)
  owners_lien_available boolean not null default false,
  sort_order        integer not null default 0,
  description       text,
  updated_at        timestamptz not null default now()
);
comment on table onboarding_situations is 'The six ownership situations and Turo-Only: which method, forms and lien option apply. Editable by an Admin; estimates stay in onboarding_method_info.';
create trigger onboarding_situations_updated before update on onboarding_situations for each row execute function app.set_updated_at();
alter table vehicle_onboardings add constraint vehicle_onboardings_situation_fkey
  foreign key (situation) references onboarding_situations (situation) on update cascade;

insert into onboarding_situations (situation, method, held_by, title_statuses, management_modes, recommended, government_forms,
                                   sign_back_on_permit, carmacars_forms, finance_forms, owners_lien_available, sort_order, description) values
  ('turo_only', 'none', null, '{owned_outright,financed,leased}', '{turo_only}', true, '{}', false, '{}', '{}', false, 0,
     'Turo-Only: no registry change; Enrollment Agreement and Vehicle Schedule only'),
  ('S1', 'lease_existing_corporation', 'corporation', '{owned_outright,financed}', '{managed,self_managed}', true, null, false, '{B,D}', '{C}', false, 1,
     'Held by a corporation, not leased: Lease (recommended)'),
  ('S2', 'lease_new_owner_corporation', 'individual', '{owned_outright,financed}', '{managed,self_managed}', false, null, false, '{B,D}', '{C}', false, 2,
     'Held personally, not leased: Lease through a new Owner Corporation'),
  ('S3', 'co_registrant', 'individual', '{owned_outright,financed}', '{managed,self_managed}', false, null, false, '{A,D}', '{C}', false, 3,
     'Held personally, not leased: Co-Registrant'),
  ('S4', 'transfer', null, '{owned_outright}', '{managed,self_managed}', false, '{}', true, '{A,D}', '{}', true, 4,
     'Owned outright: Transfer by sign-back on the permit, with the optional Owner''s Lien'),
  ('S5', 'transfer', null, '{financed}', '{managed,self_managed}', false, '{}', true, '{A,D}', '{C}', false, 5,
     'Financed: Transfer by sign-back on the permit'),
  ('S6', 'transfer', null, '{leased}', '{managed,self_managed}', true, null, false, '{A,D}', '{C}', false, 6,
     'Leased: Transfer, the only method');

create or replace function app.onboarding_options(p_held_by owner_type, p_title_status title_status, p_mode management_mode)
returns table (situation text, method onboarding_method, label text, recommended boolean, estimate_cents bigint,
               estimate_with_lien_cents bigint, plus_tax boolean, typical_items jsonb, government_forms text[],
               sign_back_on_permit boolean, carmacars_forms text[])
language sql stable security definer set search_path = public, app as $$
  select x.situation, x.method, i.label, x.recommended, i.estimate_cents,
         case when x.owners_lien_available then i.estimate_with_lien_cents end,
         i.plus_tax, i.typical_items, coalesce(x.government_forms, i.government_forms), x.sign_back_on_permit,
         x.carmacars_forms || case when p_title_status <> 'owned_outright' then x.finance_forms else '{}'::text[] end
    from onboarding_situations x join onboarding_method_info i on i.method = x.method
   where (x.held_by is null or x.held_by = p_held_by)
     and p_title_status = any (x.title_statuses) and p_mode = any (x.management_modes)
   order by x.sort_order, x.situation
$$;

-- The plan for one vehicle once its method is known. Refuses a method that is not open to it.
create or replace function app.onboarding_plan(p_held_by owner_type, p_title_status title_status, p_mode management_mode,
                                               p_method onboarding_method, p_owners_lien boolean default false)
returns jsonb language plpgsql stable security definer set search_path = public, app as $$
declare
  o record;
begin
  select * into o from app.onboarding_options(p_held_by, p_title_status, p_mode) x where x.method = p_method;
  if not found then
    raise exception 'The method "%" is not open to a vehicle held by % that is %', p_method,
      case p_held_by when 'corporation' then 'a corporation' else 'an individual' end, replace(p_title_status::text, '_', ' ')
      using errcode = '23514';
  end if;
  if coalesce(p_owners_lien, false)
     and not exists (select 1 from onboarding_situations x where x.situation = o.situation and x.owners_lien_available) then
    raise exception 'The Owner''s Lien exists only on a vehicle owned outright under the Transfer method' using errcode = '23514';
  end if;
  return jsonb_build_object(
    'situation', o.situation, 'method', o.method, 'label', o.label, 'recommended', o.recommended,
    'government_forms', to_jsonb(o.government_forms), 'sign_back_on_permit', o.sign_back_on_permit,
    'carmacars_forms', to_jsonb(o.carmacars_forms),
    'estimate_cents', case when coalesce(p_owners_lien, false) then coalesce(o.estimate_with_lien_cents, o.estimate_cents) else o.estimate_cents end,
    'estimate_plus_tax', o.plus_tax, 'typical_items', o.typical_items, 'owners_lien', coalesce(p_owners_lien, false),
    'owners_lien_available', exists (select 1 from onboarding_situations x where x.situation = o.situation and x.owners_lien_available),
    'estimate_note', 'Estimate only. You pay ServiceOntario, the safety inspection, the appraiser and other third parties directly. CarmaCars does not collect these amounts, and they may vary.');
end $$;

-- The standard grid for an owner (Enrollment Agreement Schedule B Part 2), by how many vehicles
-- the owner has in or entering the program. A starting point only: the signed schedule governs.
create or replace function app.standard_terms(p_owner uuid, p_mode management_mode, p_on date default null)
returns table (insurance_fee_cents bigint, tracker_fee_cents bigint, revenue_share_bps integer, install_fee_cents bigint, vehicle_count integer)
language sql stable security definer set search_path = public, app as $$
  with n as (
    select greatest(1, count(*))::integer as n from vehicles v
     where v.owner_id = p_owner and v.status not in ('declined', 'exited', 'total_loss')),
  g as (
    select g.* from owner_fee_grid g, n
     where g.effective_from <= coalesce(p_on, app.today()) and g.min_vehicles <= n.n and (g.max_vehicles is null or n.n <= g.max_vehicles)
     order by g.effective_from desc limit 1)
  select case when p_mode = 'turo_only' then 0 else g.insurance_fee_cents end,
         case when p_mode = 'turo_only' then 0 else g.tracker_fee_cents end,
         case when p_mode = 'self_managed' then 0 else g.revenue_share_bps end,
         case when p_mode = 'turo_only' then 0 else (app.settings(coalesce(p_on, app.today()))).install_fee_cents end,
         n.n
    from g, n
$$;

-- What is still missing on the owner's record before the agreements and registry forms can be filled.
create or replace function app.owner_missing_fields(p_owner uuid) returns text[]
language sql stable security definer set search_path = public, app as $$
  select coalesce(array_agg(x.label order by x.ord) filter (where x.missing), '{}')
    from owners o left join owner_private_details d on d.owner_id = o.id,
         lateral (values
           (1, 'Legal name', nullif(btrim(o.legal_name), '') is null),
           (2, 'Street address', nullif(btrim(o.address_line1), '') is null),
           (3, 'City', nullif(btrim(o.city), '') is null),
           (4, 'Province', nullif(btrim(o.province), '') is null),
           (5, 'Postal code', nullif(btrim(o.postal_code), '') is null),
           (6, 'Email', nullif(btrim(o.email), '') is null),
           (7, 'Phone', nullif(btrim(o.phone), '') is null),
           (8, 'Driver''s licence number', o.owner_type = 'individual' and nullif(btrim(d.licence_number), '') is null),
           (9, 'Date of birth', o.owner_type = 'individual' and d.date_of_birth is null),
           (10, 'Corporation name', o.owner_type = 'corporation' and nullif(btrim(o.corporation_name), '') is null),
           (11, 'Corporation number', o.owner_type = 'corporation' and nullif(btrim(o.corporation_number), '') is null),
           (12, 'Signing officer name', o.owner_type = 'corporation' and nullif(btrim(o.signing_officer_name), '') is null),
           (13, 'Signing officer title', o.owner_type = 'corporation' and nullif(btrim(o.signing_officer_title), '') is null)
         ) x(ord, label, missing)
   where o.id = p_owner
$$;

-- ---------------------------------------------------------------- VIN decodes (used by the application and by the listing pipeline)
-- What the VIN decoder answered, kept so a VIN is decoded once: the raw response and the
-- fields we use, in our own terms.
create table vin_decodes (
  id           uuid primary key default gen_random_uuid(),
  vin          text not null check (vin ~ '^[A-HJ-NPR-Z0-9]{17}$'),
  provider     text not null,
  ok           boolean not null,
  error_code   text,
  raw          jsonb not null default '{}'::jsonb,
  year         smallint check (year between 1980 and 2100),
  make         text,
  model        text,
  trim         text,
  body_class   text,
  fuel         fuel_type,
  drivetrain   text,
  transmission text,
  doors        smallint,
  seats        smallint,
  engine       text,
  decoded_at   timestamptz not null default now()
);
create index vin_decodes_vin_idx on vin_decodes (vin, decoded_at desc);

-- ---------------------------------------------------------------- the owner application
-- Create the owner, or fill in what is still empty on an existing one. Facts are asked once:
-- a value already on file is kept unless the caller is staff or sends a new one explicitly.
create or replace function app.save_application_owner(p_owner_id uuid, p_o jsonb, p_by uuid default null)
returns uuid language plpgsql security definer set search_path = public, app as $$
declare
  o owners;
  v_id uuid := p_owner_id;
  v_type owner_type := nullif(p_o ->> 'owner_type', '')::owner_type;
  v_user uuid := nullif(p_o ->> 'user_id', '')::uuid;
  v_recruiter uuid;
begin
  p_o := coalesce(p_o, '{}'::jsonb);
  if v_user is not null and not exists (select 1 from users u where u.id = v_user) then
    raise exception 'The account for this owner does not exist yet' using errcode = '23503';
  end if;
  if nullif(p_o ->> 'referred_by', '') is not null then
    select sp.user_id into v_recruiter from staff_profiles sp where sp.referral_code = upper(btrim(p_o ->> 'referred_by'));
  end if;

  if v_id is null then
    if v_type is null then
      raise exception 'Say whether the owner is an individual or a corporation' using errcode = '22023';
    end if;
    if nullif(btrim(p_o ->> 'legal_name'), '') is null then
      raise exception 'Enter the owner''s full legal name' using errcode = '22023';
    end if;
    if nullif(btrim(p_o ->> 'email'), '') is null and nullif(btrim(p_o ->> 'phone'), '') is null then
      raise exception 'Give an email address or a phone number for the owner' using errcode = '22023';
    end if;
    if v_type = 'corporation' and nullif(btrim(p_o ->> 'corporation_name'), '') is null then
      raise exception 'Enter the corporation''s name' using errcode = '22023';
    end if;
    insert into owners (user_id, owner_type, legal_name, status, recruited_by)
    values (v_user, v_type, btrim(p_o ->> 'legal_name'), 'lead', v_recruiter)
    returning id into v_id;
  end if;

  select * into o from owners where id = v_id for update;
  if o.id is null then
    raise exception 'Owner not found' using errcode = 'P0002';
  end if;
  update owners set
    user_id = coalesce(o.user_id, v_user),
    legal_name = coalesce(nullif(btrim(p_o ->> 'legal_name'), ''), o.legal_name),
    first_name = coalesce(nullif(btrim(p_o ->> 'first_name'), ''), o.first_name),
    middle_name = coalesce(nullif(btrim(p_o ->> 'middle_name'), ''), o.middle_name),
    last_name = coalesce(nullif(btrim(p_o ->> 'last_name'), ''), o.last_name),
    corporation_name = coalesce(nullif(btrim(p_o ->> 'corporation_name'), ''), o.corporation_name),
    corporation_number = coalesce(nullif(btrim(p_o ->> 'corporation_number'), ''), o.corporation_number),
    registrant_identification_number = coalesce(nullif(btrim(p_o ->> 'registrant_identification_number'), ''), o.registrant_identification_number),
    signing_officer_name = coalesce(nullif(btrim(p_o ->> 'signing_officer_name'), ''), o.signing_officer_name),
    signing_officer_title = coalesce(nullif(btrim(p_o ->> 'signing_officer_title'), ''), o.signing_officer_title),
    address_line1 = coalesce(nullif(btrim(p_o ->> 'address_line1'), ''), o.address_line1),
    address_line2 = coalesce(nullif(btrim(p_o ->> 'address_line2'), ''), o.address_line2),
    city = coalesce(nullif(btrim(p_o ->> 'city'), ''), o.city),
    province = coalesce(nullif(upper(btrim(p_o ->> 'province')), ''), o.province),
    postal_code = coalesce(nullif(upper(btrim(p_o ->> 'postal_code')), ''), o.postal_code),
    country = coalesce(nullif(upper(btrim(p_o ->> 'country')), ''), o.country),
    mailing_address_line1 = coalesce(nullif(btrim(p_o ->> 'mailing_address_line1'), ''), o.mailing_address_line1),
    mailing_address_line2 = coalesce(nullif(btrim(p_o ->> 'mailing_address_line2'), ''), o.mailing_address_line2),
    mailing_city = coalesce(nullif(btrim(p_o ->> 'mailing_city'), ''), o.mailing_city),
    mailing_province = coalesce(nullif(upper(btrim(p_o ->> 'mailing_province')), ''), o.mailing_province),
    mailing_postal_code = coalesce(nullif(upper(btrim(p_o ->> 'mailing_postal_code')), ''), o.mailing_postal_code),
    email = coalesce(nullif(lower(btrim(p_o ->> 'email')), ''), o.email),
    phone = coalesce(nullif(btrim(p_o ->> 'phone'), ''), o.phone),
    hst_number = coalesce(nullif(upper(btrim(p_o ->> 'hst_number')), ''), o.hst_number),
    recruited_by = coalesce(o.recruited_by, v_recruiter)
  where id = v_id;

  if nullif(btrim(p_o ->> 'licence_number'), '') is not null or nullif(p_o ->> 'date_of_birth', '') is not null then
    insert into owner_private_details (owner_id, licence_number, licence_province, date_of_birth, updated_by)
    values (v_id, nullif(upper(btrim(p_o ->> 'licence_number')), ''), coalesce(nullif(upper(btrim(p_o ->> 'licence_province')), ''), 'ON'),
            nullif(p_o ->> 'date_of_birth', '')::date, p_by)
    on conflict (owner_id) do update
      set licence_number = coalesce(excluded.licence_number, owner_private_details.licence_number),
          licence_province = coalesce(excluded.licence_province, owner_private_details.licence_province),
          date_of_birth = coalesce(excluded.date_of_birth, owner_private_details.date_of_birth),
          updated_by = excluded.updated_by;
  end if;

  -- the owner's login reaches the owner portal
  if coalesce(o.user_id, v_user) is not null then
    insert into user_roles (user_id, role, granted_by) values (coalesce(o.user_id, v_user), 'owner', p_by)
    on conflict (user_id, role) do nothing;
  end if;
  return v_id;
end $$;

-- Add one vehicle to an owner: the vehicle row, its onboarding row at "intake" with the facts
-- the wizard collected, the situation that applies, the registry forms it needs and the
-- estimate. p_v carries: vin, plate, year, make, model, trim, colour, odometer_km, body_type,
-- fuel, registration_status, held_by, title_status, finance_party_name, finance_party_account,
-- finance_permission, management_mode, onboarding_method, owners_lien, title_brand_clear,
-- disclosures, new_corporation, current_insurer.
create or replace function app.add_owner_vehicle(p_owner uuid, p_v jsonb, p_by uuid default null, p_application uuid default null)
returns jsonb language plpgsql security definer set search_path = public, app as $$
declare
  o owners;
  d vin_decodes;
  v_vin text := app.clean_vin(p_v ->> 'vin');
  v_id uuid := gen_random_uuid();
  v_onb uuid := gen_random_uuid();
  v_mode management_mode := coalesce(nullif(p_v ->> 'management_mode', '')::management_mode, 'managed');
  v_held owner_type;
  v_title title_status := nullif(p_v ->> 'title_status', '')::title_status;
  v_method onboarding_method := nullif(p_v ->> 'onboarding_method', '')::onboarding_method;
  v_lien boolean := coalesce((p_v ->> 'owners_lien')::boolean, false);
  v_perm finance_permission := nullif(p_v ->> 'finance_permission', '')::finance_permission;
  v_party text := nullif(btrim(p_v ->> 'finance_party_name'), '');
  v_plan jsonb;
  v_options jsonb;
  v_year smallint; v_make text; v_model text; v_trim text; v_fuel fuel_type; v_body text;
  v_sources jsonb := '{}'::jsonb;
  v_src jsonb := jsonb_build_object('source', 'person', 'by', p_by, 'at', now());
  v_dec jsonb := jsonb_build_object('source', 'decoded', 'at', now());
  v_clear boolean := coalesce((p_v ->> 'title_brand_clear')::boolean, true);
  v_flag boolean;
begin
  select * into o from owners where id = p_owner;
  if o.id is null then
    raise exception 'Owner not found' using errcode = 'P0002';
  end if;
  if p_by is not null and not app.user_is_admin(p_by) and not app.user_va_has(p_by, 'cs', 'fleet')
     and not app.user_is_owner_of(p_by, p_owner) and o.user_id is distinct from p_by then
    raise exception 'Not permitted: an owner adds vehicles only to their own account' using errcode = '42501';
  end if;
  if v_vin is null then
    raise exception 'Enter the 17-character VIN. It is on the ownership permit and the driver''s door frame.' using errcode = '22023';
  end if;
  if exists (select 1 from vehicles v where upper(v.vin) = v_vin) then
    raise exception 'This vehicle is already with CarmaCars. If it is yours, contact us.' using errcode = '23505';
  end if;
  if v_title is null then
    raise exception 'Say whether the vehicle is owned outright, financed or leased' using errcode = '22023';
  end if;
  v_held := coalesce(nullif(p_v ->> 'held_by', '')::owner_type, o.owner_type);
  if v_held = 'corporation' and nullif(btrim(o.corporation_name), '') is null then
    raise exception 'Add the corporation''s name before a vehicle held by a corporation' using errcode = '22023';
  end if;
  if v_title <> 'owned_outright' and v_party is null then
    raise exception 'Enter the name of the %', case v_title when 'leased' then 'lease company' else 'lender' end using errcode = '22023';
  end if;
  if v_title = 'owned_outright' then
    v_party := null; v_perm := 'not_applicable';
  else
    v_perm := coalesce(nullif(v_perm, 'not_applicable'), 'not_obtained');
  end if;

  -- facts typed by a person win; anything left empty is taken from a VIN decode already on file
  select * into d from vin_decodes x where x.vin = v_vin and x.ok order by x.decoded_at desc limit 1;
  v_year := coalesce(nullif(p_v ->> 'year', '')::smallint, d.year);
  v_make := coalesce(nullif(btrim(p_v ->> 'make'), ''), d.make);
  v_model := coalesce(nullif(btrim(p_v ->> 'model'), ''), d.model);
  v_trim := coalesce(nullif(btrim(p_v ->> 'trim'), ''), d.trim);
  v_fuel := coalesce(nullif(p_v ->> 'fuel', '')::fuel_type, d.fuel, 'gasoline');
  v_body := coalesce(nullif(btrim(p_v ->> 'body_type'), ''), d.body_class);
  if v_year is null or v_make is null or v_model is null then
    raise exception 'Enter the year, make and model from the ownership permit' using errcode = '22023';
  end if;
  v_sources := jsonb_strip_nulls(jsonb_build_object(
    'year', case when nullif(p_v ->> 'year', '') is not null then v_src when d.year is not null then v_dec end,
    'make', case when nullif(btrim(p_v ->> 'make'), '') is not null then v_src when d.make is not null then v_dec end,
    'model', case when nullif(btrim(p_v ->> 'model'), '') is not null then v_src when d.model is not null then v_dec end,
    'trim', case when nullif(btrim(p_v ->> 'trim'), '') is not null then v_src when d.trim is not null then v_dec end,
    'fuel', case when nullif(p_v ->> 'fuel', '') is not null then v_src when d.fuel is not null then v_dec end,
    'body_type', case when nullif(btrim(p_v ->> 'body_type'), '') is not null then v_src when d.body_class is not null then v_dec end,
    'colour', case when nullif(btrim(p_v ->> 'colour'), '') is not null then v_src end));

  -- the method: the one chosen, else the recommended one, else the only one open
  select jsonb_agg(to_jsonb(x)) into v_options from app.onboarding_options(v_held, v_title, v_mode) x;
  if v_method is null then
    select x.method into v_method from app.onboarding_options(v_held, v_title, v_mode) x
     where x.recommended or (select count(*) from app.onboarding_options(v_held, v_title, v_mode)) = 1
     order by x.recommended desc limit 1;
  end if;
  if v_method is not null then
    v_plan := app.onboarding_plan(v_held, v_title, v_mode, v_method, v_lien);
  elsif v_lien then
    raise exception 'Choose the Transfer method to elect the Owner''s Lien' using errcode = '23514';
  end if;

  insert into vehicles (id, owner_id, year, make, model, trim, colour, fuel, vin, plate, odometer_km, status, management_mode,
                        onboarding_method, title_brand_clear, home_location, body_type, registration_status, spec_sources)
  values (v_id, p_owner, v_year, v_make, v_model, v_trim, nullif(btrim(p_v ->> 'colour'), ''), v_fuel, v_vin,
          nullif(upper(regexp_replace(coalesce(p_v ->> 'plate', ''), '\s', '', 'g')), ''), nullif(p_v ->> 'odometer_km', '')::integer,
          'onboarding', v_mode, v_method, v_clear, o.city, v_body, nullif(p_v ->> 'registration_status', ''), v_sources);

  insert into vehicle_onboardings (id, vehicle_id, application_id, current_insurer, held_by, title_status, finance_party_name,
      finance_party_account, finance_permission, proposed_management_mode, proposed_onboarding_method, owners_lien_elected,
      situation, government_forms, sign_back_on_permit, estimate_cents, estimate_plus_tax, disclosures, new_corporation)
  values (v_onb, v_id, p_application, nullif(btrim(p_v ->> 'current_insurer'), ''), v_held, v_title, v_party,
      nullif(btrim(p_v ->> 'finance_party_account'), ''), v_perm, v_mode, v_method, v_lien,
      v_plan ->> 'situation',
      coalesce((select array_agg(f) from jsonb_array_elements_text(v_plan -> 'government_forms') f), '{}'),
      coalesce((v_plan ->> 'sign_back_on_permit')::boolean, false),
      (v_plan ->> 'estimate_cents')::bigint, coalesce((v_plan ->> 'estimate_plus_tax')::boolean, false),
      p_v -> 'disclosures', p_v -> 'new_corporation');

  if not v_clear then
    -- Enrollment Agreement 3.1: a rebuilt, salvage or irreparable brand is not eligible
    update vehicle_onboardings set status = 'declined',
           decline_reason = 'Rebuilt, salvage or irreparable brand: not eligible (Enrollment Agreement 3.1)'
     where id = v_onb;
  else
    v_flag := coalesce((p_v -> 'disclosures' ->> 'open_recall')::boolean, false)
           or coalesce((p_v -> 'disclosures' ->> 'damage')::boolean, false);
    if v_flag then
      perform app.raise_task(p_type => 'onboarding_disclosure',
          p_detail => format('%s: the owner answered yes to an open recall or to structural, flood or fire damage. Read the details before terms are set.', app.vehicle_name(v_id)),
          p_vehicle => v_id, p_owner => p_owner, p_related_table => 'vehicle_onboardings', p_related_id => v_onb,
          p_created_by => p_by, p_escalation_reason => 'recall or damage disclosed', p_dedupe => 'onboarding_disclosure:' || v_onb);
    end if;
    perform app.emit_event('owner_application_received', 'vehicle_onboarding', v_onb,
      jsonb_build_object('owner_id', p_owner, 'vehicle_id', v_id, 'first_name', coalesce(o.first_name, split_part(o.legal_name, ' ', 1)),
                         'vehicle_name', app.vehicle_name(v_id), 'vehicle_plate', nullif(upper(p_v ->> 'plate'), ''), 'vehicle_vin', v_vin,
                         'ownership_summary', concat_ws(', ', case v_held when 'corporation' then 'held by a corporation' else 'held personally' end,
                                                        replace(v_title::text, '_', ' '), v_plan ->> 'label')),
      'owner_application_received:' || v_onb || ':intake');
    perform app.emit_event('staff_owner_application_received', 'vehicle_onboarding', v_onb,
      jsonb_build_object('owner_id', p_owner, 'vehicle_id', v_id, 'owner_name', o.legal_name, 'vehicle_name', app.vehicle_name(v_id),
                         'situation', v_plan ->> 'situation', 'management_mode', v_mode),
      'staff_owner_application_received:' || v_onb || ':intake');
  end if;

  return jsonb_build_object('vehicle_id', v_id, 'onboarding_id', v_onb, 'vin', v_vin, 'declined', not v_clear,
                            'management_mode', v_mode, 'method', v_method, 'method_needed', v_method is null and v_clear,
                            'plan', v_plan, 'options', coalesce(v_options, '[]'::jsonb));
end $$;

-- The whole application in one call: the owner (new, or the one already on file) and one or
-- many vehicles. p = {owner_id?, owner: {...}, vehicles: [{...}, ...], lead_id?, draft_id?,
-- source?, note?}. Returns the ids, and per vehicle the situation, forms and estimate.
create or replace function app.submit_owner_application(p jsonb, p_by uuid default null) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  v_owner uuid := nullif(p ->> 'owner_id', '')::uuid;
  v_app uuid := gen_random_uuid();
  v_number text;
  v_staff boolean := p_by is not null and (app.user_is_admin(p_by) or app.user_va_has(p_by, 'cs', 'fleet'));
  v_vehicles jsonb := '[]'::jsonb;
  v_one jsonb;
  v_count integer := 0;
  v_result jsonb;
  v_draft uuid := nullif(p ->> 'draft_id', '')::uuid;
  e jsonb;
begin
  if p is null or jsonb_typeof(coalesce(p -> 'vehicles', 'null'::jsonb)) <> 'array' or jsonb_array_length(p -> 'vehicles') = 0 then
    raise exception 'An application needs at least one vehicle' using errcode = '22023';
  end if;
  if v_draft is not null and exists (select 1 from form_drafts f where f.id = v_draft and f.submitted_at is not null) then
    return (select f.result from form_drafts f where f.id = v_draft);   -- a second press of "Submit"
  end if;
  -- someone who is not staff applies for themselves only
  if p_by is not null and not v_staff then
    if v_owner is null then
      select o.id into v_owner from owners o where o.user_id = p_by order by o.created_at limit 1;
    elsif not exists (select 1 from owners o where o.id = v_owner and o.user_id = p_by) then
      raise exception 'Not permitted: an owner adds vehicles only to their own account' using errcode = '42501';
    end if;
  end if;
  if not v_staff and p_by is not null then
    p := jsonb_set(p, '{owner}', coalesce(p -> 'owner', '{}'::jsonb) || jsonb_build_object('user_id', p_by));
  end if;
  v_owner := app.save_application_owner(v_owner, p -> 'owner', p_by);

  insert into owner_applications (id, owner_id, lead_id, form_draft_id, source, submitted_by, note)
  values (v_app, v_owner, nullif(p ->> 'lead_id', '')::uuid, v_draft,
          coalesce(nullif(p ->> 'source', ''), case when v_staff then 'staff' else 'web' end), p_by, nullif(p ->> 'note', ''))
  returning application_number into v_number;

  for e in select value from jsonb_array_elements(p -> 'vehicles') loop
    v_one := app.add_owner_vehicle(v_owner, e, p_by, v_app);
    v_vehicles := v_vehicles || jsonb_build_array(v_one);
    v_count := v_count + 1;
  end loop;
  update owner_applications set vehicle_count = v_count where id = v_app;

  -- each vehicle's onboarding row raises its own owner_intake task (trigger of 0020)

  if nullif(p ->> 'lead_id', '') is not null then
    update leads set status = 'converted', owner_id = v_owner where id = (p ->> 'lead_id')::uuid;
  end if;

  v_result := jsonb_build_object('application_id', v_app, 'application_number', v_number, 'owner_id', v_owner,
                                 'owner_missing', to_jsonb(app.owner_missing_fields(v_owner)), 'vehicles', v_vehicles);
  if v_draft is not null then
    perform app.submit_form_draft(v_draft, v_result);
  end if;
  return v_result;
end $$;

-- The owner (or staff for the owner) picks the method when more than one is open.
create or replace function app.choose_onboarding_method(p_vehicle uuid, p_method onboarding_method, p_by uuid default null,
                                                        p_owners_lien boolean default false)
returns jsonb language plpgsql security definer set search_path = public, app as $$
declare
  ob vehicle_onboardings;
  v_plan jsonb;
begin
  select * into ob from vehicle_onboardings where vehicle_id = p_vehicle for update;
  if ob.id is null then
    raise exception 'This vehicle has no onboarding record' using errcode = 'P0002';
  end if;
  if p_by is not null and not app.user_is_admin(p_by) and not app.user_va_has(p_by, 'cs', 'fleet')
     and not app.user_owns_vehicle(p_by, p_vehicle) then
    raise exception 'Not permitted' using errcode = '42501';
  end if;
  if ob.status <> 'intake' then
    raise exception 'The method is fixed once terms are set; an Admin changes it with the terms' using errcode = '23514';
  end if;
  v_plan := app.onboarding_plan(ob.held_by, ob.title_status, ob.proposed_management_mode, p_method, p_owners_lien);
  update vehicle_onboardings
     set proposed_onboarding_method = p_method, owners_lien_elected = coalesce(p_owners_lien, false),
         situation = v_plan ->> 'situation',
         government_forms = coalesce((select array_agg(f) from jsonb_array_elements_text(v_plan -> 'government_forms') f), '{}'),
         sign_back_on_permit = (v_plan ->> 'sign_back_on_permit')::boolean,
         estimate_cents = (v_plan ->> 'estimate_cents')::bigint, estimate_plus_tax = (v_plan ->> 'estimate_plus_tax')::boolean
   where id = ob.id;
  update vehicles set onboarding_method = p_method where id = p_vehicle;
  return v_plan;
end $$;

-- ---------------------------------------------------------------- terms and the Vehicle Schedule
-- Write the terms: the owner's agreements if they do not exist yet, and the Vehicle Schedule
-- entry (an Additional Vehicle Schedule once the Enrollment Agreement is signed). Internal:
-- called by app.set_vehicle_terms() and app.approve_vehicle_terms() after their checks.
create or replace function app.apply_vehicle_terms(p_vehicle uuid, p_t jsonb, p_set_by uuid, p_approved_by uuid default null)
returns jsonb language plpgsql security definer set search_path = public, app as $$
declare
  v vehicles;
  ob vehicle_onboardings;
  o owners;
  ea owner_agreements;
  ta owner_agreements;
  s vehicle_schedules;
  v_mode management_mode := (p_t ->> 'management_mode')::management_mode;
  v_method onboarding_method := (p_t ->> 'onboarding_method')::onboarding_method;
  v_lien boolean := coalesce((p_t ->> 'owners_lien')::boolean, false);
  v_ins bigint := (p_t ->> 'insurance_fee_cents')::bigint;
  v_trk bigint := (p_t ->> 'tracker_fee_cents')::bigint;
  v_share integer := (p_t ->> 'revenue_share_bps')::integer;
  v_install bigint := (p_t ->> 'install_fee_cents')::bigint;
  v_plan jsonb;
  v_no integer;
  v_additional boolean;
  v_hst integer := (app.settings()).hst_bps;
begin
  select * into v from vehicles where id = p_vehicle for update;
  select * into ob from vehicle_onboardings where vehicle_id = p_vehicle for update;
  select * into o from owners where id = v.owner_id;
  v_plan := app.onboarding_plan(ob.held_by, ob.title_status, v_mode, v_method, v_lien);
  if v_mode = 'self_managed' and v_share <> 0 then
    raise exception 'A Self-Managed vehicle has no Revenue Share: the owner is paid 100%% of Owner Revenue' using errcode = '23514';
  end if;
  if v_mode = 'turo_only' and (v_ins, v_trk, v_install) is distinct from (0::bigint, 0::bigint, 0::bigint) then
    raise exception 'A Turo-Only vehicle has no Fees and no Tracker' using errcode = '23514';
  end if;

  -- one Enrollment Agreement per owner covers all of that owner's vehicles
  select * into ea from owner_agreements a
   where a.owner_id = v.owner_id and a.kind = 'enrollment' and a.status in ('draft', 'sent', 'signed') for update;
  if ea.id is null then
    insert into owner_agreements (owner_id, kind, agreement_number, status, corporate_signatory_name, corporate_signatory_title)
    values (v.owner_id, 'enrollment', 'EA-' || nextval('owner_agreement_number_seq'), 'draft',
            case when o.owner_type = 'corporation' then o.signing_officer_name end,
            case when o.owner_type = 'corporation' then o.signing_officer_title end)
    returning * into ea;
  end if;
  -- the Title-Holding and Lease Agreement: not used for Turo-Only
  if v_mode <> 'turo_only' then
    select * into ta from owner_agreements a
     where a.owner_id = v.owner_id and a.kind = 'title_holding' and a.status in ('draft', 'sent', 'signed') for update;
    if ta.id is null then
      insert into owner_agreements (owner_id, kind, agreement_number, status, corporate_signatory_name, corporate_signatory_title)
      values (v.owner_id, 'title_holding', 'TA-' || nextval('owner_agreement_number_seq'), 'draft',
              case when o.owner_type = 'corporation' or ob.held_by = 'corporation' then o.signing_officer_name end,
              case when o.owner_type = 'corporation' or ob.held_by = 'corporation' then o.signing_officer_title end)
      returning * into ta;
    end if;
  end if;

  select * into s from vehicle_schedules x where x.vehicle_id = p_vehicle and x.superseded_by is null for update;
  if s.id is not null and s.signed_at is not null then
    raise exception 'This vehicle''s Vehicle Schedule is signed. A Fee changes by written notice (app.give_fee_change_notice) and a Revenue Share by a new signed Vehicle Schedule (app.propose_schedule_change).'
      using errcode = '23514';
  end if;
  -- a vehicle added after the Enrollment Agreement is signed comes in by an Additional Vehicle Schedule
  v_additional := ea.status = 'signed';
  if s.id is null then
    select coalesce(max(x.vehicle_number), 0) + 1 into v_no from vehicle_schedules x
     where x.owner_agreement_id = ea.id and x.superseded_by is null;
    insert into vehicle_schedules (vehicle_id, owner_agreement_id, title_agreement_id, schedule_number, vehicle_number, is_additional,
        odometer_km, held_by, title_status, finance_party_name, finance_party_account, finance_permission,
        management_mode, onboarding_method, insurance_fee_cents, tracker_fee_cents, install_fee_cents, revenue_share_bps,
        special_terms, owners_lien, onboarding_estimate_cents, created_by)
    values (p_vehicle, ea.id, ta.id, 'VS-' || nextval('vehicle_schedule_number_seq'), v_no, v_additional,
        v.odometer_km, ob.held_by, ob.title_status, ob.finance_party_name, ob.finance_party_account, ob.finance_permission,
        v_mode, v_method, v_ins, v_trk, v_install, v_share, nullif(p_t ->> 'special_terms', ''),
        case when (v_plan ->> 'owners_lien_available')::boolean then case when v_lien then 'elected' else 'declined' end else 'not_available' end::owners_lien,
        (v_plan ->> 'estimate_cents')::bigint, p_set_by)
    returning * into s;
  else
    update vehicle_schedules
       set title_agreement_id = ta.id, odometer_km = v.odometer_km, held_by = ob.held_by, title_status = ob.title_status,
           finance_party_name = ob.finance_party_name, finance_party_account = ob.finance_party_account,
           finance_permission = ob.finance_permission, management_mode = v_mode, onboarding_method = v_method,
           insurance_fee_cents = v_ins, tracker_fee_cents = v_trk, install_fee_cents = v_install, revenue_share_bps = v_share,
           special_terms = nullif(p_t ->> 'special_terms', ''),
           owners_lien = case when (v_plan ->> 'owners_lien_available')::boolean then case when v_lien then 'elected' else 'declined' end else 'not_available' end::owners_lien,
           onboarding_estimate_cents = (v_plan ->> 'estimate_cents')::bigint
     where id = s.id returning * into s;
  end if;

  update vehicles set management_mode = v_mode, onboarding_method = v_method where id = p_vehicle;
  update vehicle_onboardings
     set proposed_management_mode = v_mode, proposed_onboarding_method = v_method, owners_lien_elected = v_lien,
         situation = v_plan ->> 'situation',
         government_forms = coalesce((select array_agg(f) from jsonb_array_elements_text(v_plan -> 'government_forms') f), '{}'),
         sign_back_on_permit = (v_plan ->> 'sign_back_on_permit')::boolean,
         estimate_cents = (v_plan ->> 'estimate_cents')::bigint, estimate_plus_tax = (v_plan ->> 'estimate_plus_tax')::boolean,
         pending_terms = null, terms_off_grid = coalesce((p_t ->> 'off_grid')::boolean, false),
         terms_approved_by = p_approved_by, terms_approved_at = case when p_approved_by is not null then now() end,
         terms_set_by = p_set_by, status = case when status = 'intake' then 'terms_set'::vehicle_onboarding_status else status end
   where id = ob.id;

  return jsonb_build_object(
    'status', 'terms_set', 'vehicle_id', p_vehicle, 'schedule_id', s.id, 'schedule_number', s.schedule_number,
    'vehicle_number', s.vehicle_number, 'is_additional', s.is_additional,
    'enrollment_agreement_id', ea.id, 'title_agreement_id', ta.id,
    'management_mode', v_mode, 'onboarding_method', v_method, 'situation', v_plan ->> 'situation',
    'insurance_fee_cents', v_ins, 'tracker_fee_cents', v_trk, 'revenue_share_bps', v_share, 'install_fee_cents', v_install,
    'off_grid', coalesce((p_t ->> 'off_grid')::boolean, false),
    -- what CarmaCars itself will bill before the Enrollment Date: nothing else
    'upfront_cents', case when v_mode = 'turo_only' or v.is_shareholder_owned then 0 else v_install + 2 * v_ins end,
    'upfront_hst_cents', case when v_mode = 'turo_only' or v.is_shareholder_owned then 0
                              else public.calc_hst(v_install, v_hst) + 2 * public.calc_hst(v_ins, v_hst) end,
    'plan', v_plan);
end $$;

-- Record the terms negotiated for one vehicle. Nothing given: the standard grid for this
-- owner's number of vehicles, and the mode and method the owner asked for. Terms on the grid
-- take effect at once. Anything off the grid (a fee, the Revenue Share, the Install Fee, or a
-- Management Mode other than the one the owner asked for) is an Admin's decision: entered by
-- an Admin it takes effect; entered by an assistant it waits for app.approve_vehicle_terms().
-- p_terms keys: management_mode, onboarding_method, owners_lien, insurance_fee_cents,
-- tracker_fee_cents, revenue_share_bps, install_fee_cents, special_terms.
create or replace function app.set_vehicle_terms(p_vehicle uuid, p_by uuid, p_terms jsonb default '{}'::jsonb)
returns jsonb language plpgsql security definer set search_path = public, app as $$
declare
  v vehicles;
  ob vehicle_onboardings;
  std record;
  v_admin boolean := app.user_is_admin(p_by);
  v_mode management_mode;
  v_method onboarding_method;
  v_t jsonb;
  v_off boolean;
begin
  p_terms := coalesce(p_terms, '{}'::jsonb);
  if not (v_admin or app.user_va_has(p_by, 'cs', 'fleet')) then
    raise exception 'Only an Admin, or a customer service or fleet assistant, records a vehicle''s terms' using errcode = '42501';
  end if;
  select * into v from vehicles where id = p_vehicle;
  select * into ob from vehicle_onboardings where vehicle_id = p_vehicle;
  if v.id is null or ob.id is null then
    raise exception 'This vehicle has no onboarding record' using errcode = 'P0002';
  end if;
  if ob.held_by is null or ob.title_status is null then
    raise exception 'Complete the vehicle intake (who holds it, and whether it is owned, financed or leased) before terms' using errcode = '23514';
  end if;
  if ob.status not in ('intake', 'terms_set') then
    raise exception 'Terms are fixed once the documents are sent. A Fee changes by written notice (app.give_fee_change_notice) and a Revenue Share by a new signed Vehicle Schedule (app.propose_schedule_change).'
      using errcode = '23514';
  end if;
  v_mode := coalesce(nullif(p_terms ->> 'management_mode', '')::management_mode, ob.proposed_management_mode, v.management_mode);
  v_method := coalesce(nullif(p_terms ->> 'onboarding_method', '')::onboarding_method,
                       case when v_mode = 'turo_only' then 'none'::onboarding_method end, ob.proposed_onboarding_method);
  if v_method = 'none' and v_mode <> 'turo_only' then v_method := null; end if;
  if v_method is null then
    raise exception 'Choose the onboarding method first' using errcode = '23514';
  end if;

  if v.is_shareholder_owned then
    -- a vehicle owned by a Principal: 90/10, no Fees, no upfront charges, no Vehicle Schedule entry
    if not v_admin then
      raise exception 'Only an Admin sets the terms of a shareholder-owned vehicle' using errcode = '42501';
    end if;
    perform app.onboarding_plan(ob.held_by, ob.title_status, 'managed', v_method, false);
    update vehicles set onboarding_method = v_method where id = p_vehicle;
    update vehicle_onboardings set proposed_onboarding_method = v_method, terms_set_by = p_by, terms_approved_by = p_by, terms_approved_at = now(),
           status = case when status = 'intake' then 'terms_set'::vehicle_onboarding_status else status end
     where id = ob.id;
    return jsonb_build_object('status', 'terms_set', 'vehicle_id', p_vehicle, 'shareholder_owned', true, 'upfront_cents', 0);
  end if;

  select * into std from app.standard_terms(v.owner_id, v_mode);
  if std.vehicle_count is null then
    raise exception 'No standard fee grid is in force' using errcode = '23514';
  end if;
  v_t := jsonb_build_object(
    'management_mode', v_mode, 'onboarding_method', v_method,
    'owners_lien', coalesce((p_terms ->> 'owners_lien')::boolean, ob.owners_lien_elected),
    'insurance_fee_cents', coalesce((p_terms ->> 'insurance_fee_cents')::bigint, std.insurance_fee_cents),
    'tracker_fee_cents', coalesce((p_terms ->> 'tracker_fee_cents')::bigint, std.tracker_fee_cents),
    'revenue_share_bps', coalesce((p_terms ->> 'revenue_share_bps')::integer, std.revenue_share_bps),
    'install_fee_cents', coalesce((p_terms ->> 'install_fee_cents')::bigint, std.install_fee_cents),
    'special_terms', nullif(p_terms ->> 'special_terms', ''),
    'standard', jsonb_build_object('insurance_fee_cents', std.insurance_fee_cents, 'tracker_fee_cents', std.tracker_fee_cents,
                                   'revenue_share_bps', std.revenue_share_bps, 'install_fee_cents', std.install_fee_cents,
                                   'vehicle_count', std.vehicle_count));
  v_off := ((v_t ->> 'insurance_fee_cents')::bigint, (v_t ->> 'tracker_fee_cents')::bigint,
            (v_t ->> 'revenue_share_bps')::integer, (v_t ->> 'install_fee_cents')::bigint)
           is distinct from (std.insurance_fee_cents, std.tracker_fee_cents, std.revenue_share_bps, std.install_fee_cents)
        or v_mode is distinct from coalesce(ob.proposed_management_mode, v.management_mode)
        or nullif(p_terms ->> 'special_terms', '') is not null;
  v_t := v_t || jsonb_build_object('off_grid', v_off);
  -- validate before anything is stored, so a bad combination is refused whoever enters it
  perform app.onboarding_plan(ob.held_by, ob.title_status, v_mode, v_method, (v_t ->> 'owners_lien')::boolean);

  if v_off and not v_admin then
    update vehicle_onboardings set pending_terms = v_t, terms_off_grid = true, terms_proposed_by = p_by, terms_proposed_at = now()
     where id = ob.id;
    perform app.raise_task(p_type => 'approve_vehicle_terms',
        p_detail => format('%s: Insurance Fee $%s, Tracker Fee $%s, Revenue Share %s%%, Install Fee $%s, %s. The grid for %s vehicle(s) is $%s, $%s, %s%%.',
                   app.vehicle_name(p_vehicle), (v_t ->> 'insurance_fee_cents')::bigint / 100, (v_t ->> 'tracker_fee_cents')::bigint / 100,
                   (v_t ->> 'revenue_share_bps')::numeric / 100, (v_t ->> 'install_fee_cents')::bigint / 100, replace(v_mode::text, '_', ' '),
                   std.vehicle_count, std.insurance_fee_cents / 100, std.tracker_fee_cents / 100, std.revenue_share_bps::numeric / 100),
        p_vehicle => p_vehicle, p_owner => v.owner_id, p_related_table => 'vehicle_onboardings', p_related_id => ob.id,
        p_created_by => p_by, p_escalation_reason => 'fee off the grid', p_dedupe => 'approve_vehicle_terms:' || ob.id);
    return jsonb_build_object('status', 'needs_admin_approval', 'vehicle_id', p_vehicle, 'terms', v_t);
  end if;
  return app.apply_vehicle_terms(p_vehicle, v_t, p_by, case when v_off then p_by end);
end $$;

-- An Admin approves (or refuses) terms an assistant entered off the grid.
create or replace function app.approve_vehicle_terms(p_vehicle uuid, p_admin uuid, p_approve boolean default true)
returns jsonb language plpgsql security definer set search_path = public, app as $$
declare
  ob vehicle_onboardings;
  v_result jsonb;
begin
  if not app.user_is_admin(p_admin) then
    raise exception 'Only an Admin approves terms off the standard grid' using errcode = '42501';
  end if;
  select * into ob from vehicle_onboardings where vehicle_id = p_vehicle for update;
  if ob.pending_terms is null then
    raise exception 'No terms are waiting for approval on this vehicle' using errcode = 'P0002';
  end if;
  if p_approve then
    v_result := app.apply_vehicle_terms(p_vehicle, ob.pending_terms, ob.terms_proposed_by, p_admin);
  else
    update vehicle_onboardings set pending_terms = null, terms_off_grid = false where id = ob.id;
    v_result := jsonb_build_object('status', 'refused', 'vehicle_id', p_vehicle);
  end if;
  update tasks set status = 'done', completed_by = p_admin, completed_at = now()
   where task_type = 'approve_vehicle_terms' and related_id = ob.id and status in ('open', 'in_progress', 'waiting');
  return v_result;
end $$;

-- ---------------------------------------------------------------- the upfront invoice
-- For every vehicle of the owner whose documents are signed and that has no upfront invoice
-- yet: issue it with the existing owner billing function (the Install Fee and the first and
-- last month's Insurance Fee, with HST; one invoice per vehicle). Never for a Turo-Only or
-- shareholder-owned vehicle. Registry costs are not on it: the owner pays those directly.
create or replace function app.issue_upfront_invoices(p_owner uuid, p_by uuid default null)
returns table (vehicle_id uuid, invoice_id uuid, invoice_number text, fees_cents bigint, hst_cents bigint, total_cents bigint)
language plpgsql security definer set search_path = public, app as $$
declare
  r record;
  v_inv uuid;
begin
  for r in
    select v.id from vehicles v join vehicle_onboardings ob on ob.vehicle_id = v.id
     where v.owner_id = p_owner and ob.status = 'documents_signed' and ob.upfront_invoice_id is null
       and v.billing_case in ('managed', 'self_managed')
     order by v.created_at, v.id
  loop
    v_inv := app.issue_upfront_invoice(r.id, p_by);
    update owner_invoices set status = 'issued' where id = v_inv;
    return query select i.vehicle_id, i.id, i.invoice_number, i.fees_cents, i.hst_cents, i.total_cents from owner_invoices i where i.id = v_inv;
  end loop;
end $$;

-- ---------------------------------------------------------------- government forms: templates and pre-fill
-- A template is one version of one official PDF. field_map maps a field in that PDF to a
-- value: either a path into the data ("vehicle.vin") or an object
-- {"source": "owner.postal_code", "transform": "postal", "when": "method.is_lease",
--  "type": "checkbox", "required": true}. A template is used to fill a PDF only once a person
-- has verified its map against the official file.
create table pdf_templates (
  id             uuid primary key default gen_random_uuid(),
  form_code      text not null,
  version        text not null,
  title          text,
  kind           text not null default 'acroform' check (kind in ('acroform', 'overlay', 'generated')),
  file_key       text,                          -- the blank PDF in file storage; null until it is loaded
  sha256         text,
  page_count     integer,
  field_map      jsonb not null default '{}'::jsonb check (jsonb_typeof(field_map) = 'object'),
  verified       boolean not null default false,
  verified_by    uuid references users (id),
  verified_at    timestamptz,
  is_current     boolean not null default true,
  effective_from date not null default app.today(),
  notes          text,
  uploaded_by    uuid references users (id),
  created_at     timestamptz not null default now(),
  updated_at     timestamptz not null default now(),
  unique (form_code, version),
  check (not verified or (verified_by is not null and verified_at is not null and file_key is not null))
);
create unique index pdf_templates_one_current on pdf_templates (form_code) where is_current;
create trigger pdf_templates_updated before update on pdf_templates for each row execute function app.set_updated_at();

-- The values a registry form needs, as label and value rows. This is the data sheet staff
-- copy from by hand when a form's PDF map is not verified. form_code null: the row is on
-- every form. applies_when is a data path that must be true for the row to appear.
create table government_form_fields (
  id           uuid primary key default gen_random_uuid(),
  form_code    text,
  seq          integer not null,
  section      text not null,
  label        text not null,
  source       text not null,                   -- data path, for example "vehicle.vin"
  transform    text,
  required     boolean not null default true,
  applies_when text,
  created_at   timestamptz not null default now()
);
create unique index government_form_fields_key on government_form_fields (coalesce(form_code, ''), seq);

create table government_form_fills (
  id              uuid primary key default gen_random_uuid(),
  form_code       text not null,
  pdf_template_id uuid not null references pdf_templates (id),
  template_version text not null,
  vehicle_id      uuid not null references vehicles (id),
  owner_id        uuid not null references owners (id),
  mode            text not null check (mode in ('pdf', 'data_sheet')),   -- data_sheet: the template is not verified
  field_values    jsonb not null default '{}'::jsonb,                    -- PDF field name to resolved value
  data_sheet      jsonb not null default '[]'::jsonb,                    -- label and value rows
  missing         text[] not null default '{}',                          -- required values still empty
  status          text not null default 'draft' check (status in ('draft', 'ready', 'printed', 'signed', 'filed')),
  file_key        text,                                                  -- the generated file
  document_id     uuid references documents (id),
  generated_by    uuid references users (id),
  generated_at    timestamptz not null default now(),
  printed_by      uuid references users (id),
  printed_at      timestamptz,
  signed_recorded_by uuid references users (id),
  signed_at       timestamptz,
  filed_by        uuid references users (id),
  filed_at        timestamptz,
  superseded_at   timestamptz,                                           -- replaced by a later fill of the same form
  check (status = 'draft' or cardinality(missing) = 0)
);
create unique index government_form_fills_current on government_form_fills (vehicle_id, form_code) where superseded_at is null;
create index government_form_fills_owner_idx on government_form_fills (owner_id);

create or replace function app.apply_transform(p_value text, p_transform text) returns text
language sql immutable as $$
  select case
    when p_value is null or btrim(p_value) = '' then null
    when p_transform is null or p_transform = '' then p_value
    when p_transform = 'upper' then upper(p_value)
    when p_transform = 'lower' then lower(p_value)
    when p_transform = 'postal' then
      case when upper(regexp_replace(p_value, '\s', '', 'g')) ~ '^[A-Z][0-9][A-Z][0-9][A-Z][0-9]$'
           then substr(upper(regexp_replace(p_value, '\s', '', 'g')), 1, 3) || ' ' || substr(upper(regexp_replace(p_value, '\s', '', 'g')), 4, 3)
           else upper(p_value) end
    when p_transform = 'phone' then
      case when length(regexp_replace(p_value, '\D', '', 'g')) = 10
           then regexp_replace(regexp_replace(p_value, '\D', '', 'g'), '^(\d{3})(\d{3})(\d{4})$', '(\1) \2-\3')
           else p_value end
    when p_transform = 'yesno' then case when lower(p_value) in ('true', 't', 'yes', 'y', '1') then 'Yes' else 'No' end
    when p_transform = 'money' then '$' || btrim(to_char(p_value::numeric / 100, 'FM999,999,990.00'))
    when p_transform like 'date:%' then to_char(p_value::date, substr(p_transform, 6))
    else p_value end
$$;

-- Everything a registry form can ask for, read once from the owner, the vehicle and CarmaCars'
-- own record, so nothing is typed twice. Built by the database, never from the browser.
create or replace function app.registry_context(p_vehicle uuid) returns jsonb
language sql stable security definer set search_path = public, app as $$
  select jsonb_build_object(
    'today', to_char(app.today(), 'YYYY-MM-DD'),
    'owner', jsonb_build_object(
      'legal_name', o.legal_name, 'first_name', o.first_name, 'middle_name', o.middle_name, 'last_name', o.last_name,
      'owner_type', o.owner_type, 'is_individual', o.owner_type = 'individual', 'is_corporation', o.owner_type = 'corporation',
      'address_line1', o.address_line1, 'address_line2', o.address_line2, 'city', o.city, 'province', o.province,
      'postal_code', o.postal_code, 'country', o.country,
      'full_address', nullif(concat_ws(', ', nullif(o.address_line1, ''), nullif(o.address_line2, ''), nullif(o.city, ''), nullif(o.province, ''), nullif(o.postal_code, '')), ''),
      'mailing_address', nullif(concat_ws(', ', nullif(o.mailing_address_line1, ''), nullif(o.mailing_address_line2, ''), nullif(o.mailing_city, ''),
                                          nullif(o.mailing_province, ''), nullif(o.mailing_postal_code, '')), ''),
      'email', o.email, 'phone', o.phone, 'hst_number', o.hst_number,
      'licence_number', d.licence_number, 'licence_province', d.licence_province, 'date_of_birth', d.date_of_birth),
    'corporation', jsonb_build_object(
      'applies', o.owner_type = 'corporation' or x.held_by = 'corporation' or x.method in ('lease_existing_corporation', 'lease_new_owner_corporation'),
      'name', o.corporation_name, 'number', o.corporation_number, 'rin', o.registrant_identification_number,
      'rin_needed', x.method = 'lease_existing_corporation',
      'is_new_owner_corporation', x.method = 'lease_new_owner_corporation',
      'signing_officer_name', o.signing_officer_name, 'signing_officer_title', o.signing_officer_title),
    'vehicle', jsonb_build_object(
      'vin', upper(v.vin), 'plate', v.plate, 'year', v.year, 'make', v.make, 'model', v.model, 'trim', v.trim, 'colour', v.colour,
      'fuel', v.fuel, 'body_type', v.body_type, 'odometer_km', v.odometer_km, 'registration_status', v.registration_status,
      'name', concat_ws(' ', v.year::text, v.make, v.model)),
    'registrant', jsonb_build_object(
      'legal_name', ps.company_legal_name, 'trade_name', ps.company_trade_name, 'rin', ps.company_rin,
      'address', ps.company_address, 'phone', ps.company_phone, 'email', ps.company_email,
      'signing_officer_name', ps.signing_officer_name, 'signing_officer_title', ps.signing_officer_title),
    'method', jsonb_build_object(
      'code', x.method, 'label', i.label, 'situation', ob.situation,
      'is_lease', x.method in ('lease_existing_corporation', 'lease_new_owner_corporation'),
      'is_co_registrant', x.method = 'co_registrant', 'is_transfer', x.method = 'transfer',
      'sign_back_on_permit', coalesce(ob.sign_back_on_permit, false),
      'registered_as', case when x.method in ('lease_existing_corporation', 'lease_new_owner_corporation') then 'Lessee and plate registrant'
                            when x.method = 'co_registrant' then 'Co-registrant beside the owner'
                            when x.method = 'transfer' and x.title_status = 'leased' then 'Lessee, in place of the owner'
                            when x.method = 'transfer' then 'Registered owner, as nominee and bare trustee for the owner' end),
    'title', jsonb_build_object('held_by', x.held_by, 'status', x.title_status),
    'lender', jsonb_build_object(
      'applies', x.title_status is not null and x.title_status <> 'owned_outright',
      'name', x.finance_party_name, 'account', x.finance_party_account,
      'permission', case x.finance_permission when 'attached' then 'Attached' when 'not_obtained' then 'Not obtained (Form C)' end,
      'kind', case x.title_status when 'financed' then 'Lender' when 'leased' then 'Lease company' end))
    from vehicles v
    join owners o on o.id = v.owner_id
    left join owner_private_details d on d.owner_id = o.id
    left join vehicle_onboardings ob on ob.vehicle_id = v.id
    left join vehicle_schedules s on s.vehicle_id = v.id and s.superseded_by is null
    cross join lateral (select coalesce(s.onboarding_method, ob.proposed_onboarding_method, v.onboarding_method) as method,
                               coalesce(s.held_by, ob.held_by) as held_by, coalesce(s.title_status, ob.title_status) as title_status,
                               coalesce(s.finance_party_name, ob.finance_party_name) as finance_party_name,
                               coalesce(s.finance_party_account, ob.finance_party_account) as finance_party_account,
                               coalesce(s.finance_permission, ob.finance_permission) as finance_permission) x
    left join onboarding_method_info i on i.method = x.method
    cross join app.settings() ps
   where v.id = p_vehicle
$$;

create or replace function app.context_value(p_ctx jsonb, p_path text) returns text
language sql immutable as $$ select nullif(btrim(p_ctx #>> string_to_array(p_path, '.')), '') $$;

-- Pre-fill one registry form for one vehicle. Every mapped PDF field and every data sheet row
-- is resolved from the records. The data sheet is always produced, so a form whose PDF map is
-- not verified can still be completed by hand from it. A required value that is empty keeps
-- the fill in "draft" and is named in "missing"; when nothing is missing the fill is "ready".
-- Filling again replaces the earlier fill unless that one is already signed or filed.
create or replace function app.fill_government_form(p_vehicle uuid, p_form_code text, p_by uuid default null)
returns uuid language plpgsql security definer set search_path = public, app as $$
declare
  ctx jsonb := app.registry_context(p_vehicle);
  t pdf_templates;
  cur government_form_fills;
  v_owner uuid;
  v_sheet jsonb;
  v_missing text[];
  v_values jsonb := '{}'::jsonb;
  v_spec jsonb;
  v_val text;
  r record;
  v_id uuid;
begin
  if p_by is not null and not app.user_is_admin(p_by) and not app.user_va_has(p_by, 'cs', 'fleet')
     and not app.user_owns_vehicle(p_by, p_vehicle) then
    raise exception 'Not permitted' using errcode = '42501';
  end if;
  select owner_id into v_owner from vehicles where id = p_vehicle;
  if ctx is null or v_owner is null then
    raise exception 'Vehicle not found' using errcode = 'P0002';
  end if;
  select * into t from pdf_templates x where x.form_code = p_form_code and x.is_current;
  if t.id is null then
    raise exception 'No template is registered for form %', p_form_code using errcode = 'P0002';
  end if;

  select coalesce(jsonb_agg(jsonb_build_object('seq', q.seq, 'section', q.section, 'label', q.label, 'value', q.val,
                                               'required', q.required, 'missing', q.required and q.val is null) order by q.seq), '[]'::jsonb),
         coalesce(array_agg(q.label order by q.seq) filter (where q.required and q.val is null), '{}')
    into v_sheet, v_missing
    from (select f.seq, f.section, f.label, f.required, app.apply_transform(app.context_value(ctx, f.source), f.transform) as val
            from government_form_fields f
           where (f.form_code is null or f.form_code = p_form_code)
             and (f.applies_when is null or coalesce(app.context_value(ctx, f.applies_when)::boolean, false))) q;

  for r in select key, value from jsonb_each(t.field_map) loop
    v_spec := case when jsonb_typeof(r.value) = 'string' then jsonb_build_object('source', r.value #>> '{}') else r.value end;
    if v_spec ? 'when' and not coalesce(app.context_value(ctx, v_spec ->> 'when')::boolean, false) then
      continue;
    end if;
    v_val := app.apply_transform(app.context_value(ctx, v_spec ->> 'source'), v_spec ->> 'transform');
    if v_spec ->> 'type' = 'checkbox' then
      v_val := case when lower(coalesce(v_val, 'false')) in ('true', 't', 'yes') then 'Yes' else 'Off' end;
    end if;
    v_values := v_values || jsonb_build_object(r.key, v_val);
    if coalesce((v_spec ->> 'required')::boolean, false) and v_val is null then
      v_missing := v_missing || ('PDF field ' || r.key);
    end if;
  end loop;

  select * into cur from government_form_fills f where f.vehicle_id = p_vehicle and f.form_code = p_form_code and f.superseded_at is null for update;
  if cur.status in ('signed', 'filed') then
    raise exception 'Form % for this vehicle is already %; it cannot be filled again', p_form_code, cur.status using errcode = '23514';
  end if;
  if cur.id is not null then
    update government_form_fills set superseded_at = now() where id = cur.id;
  end if;
  insert into government_form_fills (form_code, pdf_template_id, template_version, vehicle_id, owner_id, mode, field_values, data_sheet,
                                     missing, status, generated_by)
  values (p_form_code, t.id, t.version, p_vehicle, v_owner,
          case when t.verified and t.field_map <> '{}'::jsonb then 'pdf' else 'data_sheet' end,
          v_values, v_sheet, v_missing, case when cardinality(v_missing) = 0 then 'ready' else 'draft' end, p_by)
  returning id into v_id;
  return v_id;
end $$;

-- Pre-fill every registry form the vehicle's situation needs.
create or replace function app.fill_vehicle_government_forms(p_vehicle uuid, p_by uuid default null)
returns table (form_code text, fill_id uuid, status text, mode text, missing text[])
language plpgsql security definer set search_path = public, app as $$
declare
  v_forms text[];
  f text;
  v_id uuid;
begin
  select ob.government_forms into v_forms from vehicle_onboardings ob where ob.vehicle_id = p_vehicle;
  if v_forms is null then
    raise exception 'This vehicle has no onboarding record' using errcode = 'P0002';
  end if;
  foreach f in array v_forms loop
    v_id := app.fill_government_form(p_vehicle, f, p_by);
    return query select g.form_code, g.id, g.status, g.mode, g.missing from government_form_fills g where g.id = v_id;
  end loop;
end $$;

-- Move a filled form on: printed, signed, filed, in that order; and record the generated file.
-- The owner may record that they printed or signed their own form; filing is recorded by staff.
create or replace function app.set_government_form_status(p_fill uuid, p_status text, p_by uuid,
                                                          p_file_key text default null, p_document_id uuid default null)
returns void language plpgsql security definer set search_path = public, app as $$
declare
  g government_form_fills;
  v_staff boolean := app.user_is_admin(p_by) or app.user_va_has(p_by, 'cs', 'fleet');
  v_rank constant text[] := array['draft', 'ready', 'printed', 'signed', 'filed'];
begin
  select * into g from government_form_fills where id = p_fill for update;
  if g.id is null or g.superseded_at is not null then
    raise exception 'This form fill is no longer current' using errcode = 'P0002';
  end if;
  if not v_staff and not app.user_owns_vehicle(p_by, g.vehicle_id) then
    raise exception 'Not permitted' using errcode = '42501';
  end if;
  if p_status is not null then
    if p_status not in ('printed', 'signed', 'filed') then
      raise exception 'A form moves to printed, signed or filed' using errcode = '22023';
    end if;
    if g.status = 'draft' then
      raise exception 'Complete the missing values first: %', array_to_string(g.missing, ', ') using errcode = '23514';
    end if;
    if array_position(v_rank, p_status) <= array_position(v_rank, g.status) then
      raise exception 'This form is already %', g.status using errcode = '23514';
    end if;
    if p_status = 'filed' and not v_staff then
      raise exception 'Filing at the registry is recorded by CarmaCars staff' using errcode = '42501';
    end if;
  end if;
  update government_form_fills
     set status = coalesce(p_status, status),
         file_key = coalesce(p_file_key, file_key), document_id = coalesce(p_document_id, document_id),
         printed_by = case when p_status = 'printed' then p_by else printed_by end,
         printed_at = case when p_status = 'printed' then now() else printed_at end,
         signed_recorded_by = case when p_status = 'signed' then p_by else signed_recorded_by end,
         signed_at = case when p_status = 'signed' then now() else signed_at end,
         filed_by = case when p_status = 'filed' then p_by else filed_by end,
         filed_at = case when p_status = 'filed' then now() else filed_at end
   where id = g.id;
end $$;

-- The five ServiceOntario forms named in onboarding_method_info and operating procedure 12.
-- No official file is loaded and no map is verified yet, so every fill is a data sheet until
-- an Admin loads the PDF and verifies its map. The SR-LV-006 keys are the example keys of
-- docs/blueprint/08-forms.md section 9.2; they are not checked against the official PDF.
insert into pdf_templates (form_code, version, title, kind, field_map, verified, notes) values
  ('SR-LV-006', 'unverified-1', 'SR-LV-006 Application for Vehicle Registration', 'acroform',
     '{"VIN": "vehicle.vin",
       "RegistrantName": {"source": "registrant.legal_name", "transform": "upper"},
       "PostalCode": {"source": "owner.postal_code", "transform": "postal"},
       "IsLease": {"source": "method.is_lease", "type": "checkbox"},
       "LessorRIN": {"source": "corporation.rin", "when": "method.is_lease"}}'::jsonb,
     false, 'Field names are the blueprint''s examples. Load the official PDF and verify the map before use.'),
  ('SR-LV-012', 'unverified-1', 'SR-LV-012 (official title to be confirmed when the PDF is loaded)', 'acroform', '{}'::jsonb, false, 'No map yet.'),
  ('ON00453', 'unverified-1', 'ON00453 (official title to be confirmed when the PDF is loaded)', 'acroform', '{}'::jsonb, false, 'No map yet.'),
  ('013-0169', 'unverified-1', '013-0169 (official title to be confirmed when the PDF is loaded)', 'acroform', '{}'::jsonb, false, 'No map yet.'),
  ('013-1155', 'unverified-1', '013-1155 (official title to be confirmed when the PDF is loaded)', 'acroform', '{}'::jsonb, false, 'No map yet.');

-- The data sheet rows, the same on every form until a form gets rows of its own.
insert into government_form_fields (form_code, seq, section, label, source, transform, required, applies_when) values
  (null, 10, 'Vehicle', 'VIN', 'vehicle.vin', 'upper', true, null),
  (null, 20, 'Vehicle', 'Plate', 'vehicle.plate', 'upper', true, null),
  (null, 30, 'Vehicle', 'Year', 'vehicle.year', null, true, null),
  (null, 40, 'Vehicle', 'Make', 'vehicle.make', null, true, null),
  (null, 50, 'Vehicle', 'Model', 'vehicle.model', null, true, null),
  (null, 60, 'Vehicle', 'Body type', 'vehicle.body_type', null, true, null),
  (null, 70, 'Vehicle', 'Colour', 'vehicle.colour', null, true, null),
  (null, 80, 'Vehicle', 'Fuel', 'vehicle.fuel', null, true, null),
  (null, 90, 'Vehicle', 'Odometer (km)', 'vehicle.odometer_km', null, true, null),
  (null, 100, 'Vehicle', 'Registration status', 'vehicle.registration_status', null, false, null),
  (null, 200, 'Owner', 'Owner legal name', 'owner.legal_name', null, true, null),
  (null, 210, 'Owner', 'Driver''s licence number', 'owner.licence_number', 'upper', true, 'owner.is_individual'),
  (null, 220, 'Owner', 'Date of birth', 'owner.date_of_birth', null, true, 'owner.is_individual'),
  (null, 230, 'Owner', 'Street address', 'owner.address_line1', null, true, null),
  (null, 240, 'Owner', 'Unit or suite', 'owner.address_line2', null, false, null),
  (null, 250, 'Owner', 'City', 'owner.city', null, true, null),
  (null, 260, 'Owner', 'Province', 'owner.province', 'upper', true, null),
  (null, 270, 'Owner', 'Postal code', 'owner.postal_code', 'postal', true, null),
  (null, 280, 'Owner', 'Mailing address, if different', 'owner.mailing_address', null, false, null),
  (null, 290, 'Owner', 'Phone', 'owner.phone', 'phone', true, null),
  (null, 300, 'Owner', 'Email', 'owner.email', null, false, null),
  (null, 400, 'Corporation', 'Corporation name', 'corporation.name', null, true, 'corporation.applies'),
  (null, 410, 'Corporation', 'Corporation number', 'corporation.number', null, true, 'corporation.applies'),
  (null, 420, 'Corporation', 'Corporation''s registrant identification number', 'corporation.rin', null, true, 'corporation.rin_needed'),
  (null, 430, 'Corporation', 'Signing officer', 'corporation.signing_officer_name', null, true, 'corporation.applies'),
  (null, 440, 'Corporation', 'Signing officer''s title', 'corporation.signing_officer_title', null, true, 'corporation.applies'),
  (null, 500, 'CarmaCars', 'CarmaCars legal name', 'registrant.legal_name', null, true, null),
  (null, 510, 'CarmaCars', 'Operating name', 'registrant.trade_name', null, true, null),
  (null, 520, 'CarmaCars', 'CarmaCars registrant identification number', 'registrant.rin', null, true, null),
  (null, 530, 'CarmaCars', 'CarmaCars address', 'registrant.address', null, true, null),
  (null, 540, 'CarmaCars', 'CarmaCars signing officer', 'registrant.signing_officer_name', null, false, null),
  (null, 600, 'Registration', 'Onboarding method', 'method.label', null, true, null),
  (null, 610, 'Registration', 'How CarmaCars appears at the registry', 'method.registered_as', null, true, null),
  (null, 700, 'Lender or lessor', 'Lender or lease company', 'lender.name', null, true, 'lender.applies'),
  (null, 710, 'Lender or lessor', 'Loan or lease account', 'lender.account', null, false, 'lender.applies'),
  (null, 720, 'Lender or lessor', 'Written permission', 'lender.permission', null, true, 'lender.applies');

-- ================================================================ PART B: the listing pipeline
-- A VA, field staff member, Admin or the car's owner starts an intake, uploads the photos of the
-- shot list, and submits. The worker (an Edge Function) claims jobs from listing_jobs: decode the
-- VIN, draft the copy, process each photo to the CarmaCars background, make the sizes. The
-- database records every result and cost, moves the intake on, and asks a reviewer when the
-- starter's role needs one. app.publish_listing() puts the car on the website.

-- ---------------------------------------------------------------- the shot list (editable)
-- The photos a listing needs, in order. code is what the capture screen and the worker use;
-- photo_angle is the value stored in vehicle_photos.angle (0002 keeps a fixed list there, so a
-- new code an Admin adds is stored as "other" with its own shot_type).
create table listing_shot_types (
  code          text primary key check (code ~ '^[a-z][a-z0-9_]*$'),
  label         text not null,
  seq           integer not null check (seq > 0),
  required      boolean not null default true,
  is_public     boolean not null default true,      -- false: kept for the record, never on the website (odometer)
  rebackground  boolean not null default false,     -- placed on the CarmaCars backdrop by the photo provider
  is_cover      boolean not null default false,     -- the default cover photo
  max_count     integer not null default 1 check (max_count between 1 and 20),
  photo_angle   text not null default 'other' check (photo_angle in (
                  'front', 'front_left', 'left', 'rear_left', 'rear', 'rear_right', 'right', 'front_right',
                  'dashboard', 'front_seats', 'rear_seats', 'trunk', 'wheel', 'odometer', 'other')),
  guide         text,
  is_active     boolean not null default true,
  updated_at    timestamptz not null default now()
);
comment on table listing_shot_types is 'The listing photo list (procedure 17, docs/blueprint/09 section 4). Editable by an Admin.';
create trigger listing_shot_types_updated before update on listing_shot_types for each row execute function app.set_updated_at();
create unique index listing_shot_types_one_cover on listing_shot_types (is_cover) where is_cover;

insert into listing_shot_types (code, label, seq, required, is_public, rebackground, is_cover, max_count, photo_angle, guide) values
  ('front_left', 'Front left', 1, true, true, true, true, 1, 'front_left', 'Three-quarter front, whole car in frame'),
  ('front', 'Front', 2, true, true, true, false, 1, 'front', null),
  ('left', 'Left side', 3, true, true, true, false, 1, 'left', null),
  ('rear_left', 'Rear left', 4, true, true, true, false, 1, 'rear_left', null),
  ('rear', 'Rear', 5, true, true, true, false, 1, 'rear', null),
  ('rear_right', 'Rear right', 6, true, true, true, false, 1, 'rear_right', null),
  ('right', 'Right side', 7, true, true, true, false, 1, 'right', null),
  ('front_right', 'Front right', 8, true, true, true, false, 1, 'front_right', null),
  ('dashboard', 'Dashboard', 9, true, true, false, false, 1, 'dashboard', null),
  ('front_seats', 'Front seats', 10, true, true, false, false, 1, 'front_seats', null),
  ('rear_seats', 'Rear seats', 11, true, true, false, false, 1, 'rear_seats', null),
  ('trunk', 'Trunk', 12, true, true, false, false, 1, 'trunk', null),
  ('wheel', 'Wheel', 13, true, true, false, false, 1, 'wheel', null),
  ('odometer', 'Odometer', 14, true, false, false, false, 1, 'odometer', 'Not published; kept for the record'),
  ('other', 'Other detail', 15, false, true, false, false, 6, 'other', 'Sunroof, screen, charging port, third row');

-- ---------------------------------------------------------------- website fields on the listing
alter table vehicle_listings
  add column specs               jsonb not null default '{}'::jsonb check (jsonb_typeof(specs) = 'object'),
  add column body_style          text,
  add column drivetrain          text,
  add column doors               smallint check (doors between 1 and 6),
  add column luggage             text,              -- for example "2 large suitcases"
  add column faq                 jsonb not null default '[]'::jsonb check (jsonb_typeof(faq) = 'array'),
  add column home_area           text,
  add column seo_title           text,
  add column seo_description     text,
  add column staff_note          text,              -- the short note from the person who shot or reviewed the car (public)
  add column is_featured         boolean not null default false,
  add column canonical_vehicle_id uuid references vehicles (id),   -- an identical twin points at the car that ranks
  add column publish_at          timestamptz,
  add column first_published_at  timestamptz,       -- the slug is locked from this moment
  add column unpublished_at      timestamptz,
  add column unpublished_reason  text,
  add column redirect_to         text,
  add column needs_rewrite       boolean not null default false,
  add column spec_sources        jsonb not null default '{}'::jsonb,
  add column draft_id            uuid,              -- the AI draft the copy started from
  add column content_updated_at  timestamptz not null default now(),   -- sitemap lastmod: changes only with public content
  add constraint vehicle_listings_not_own_canonical check (canonical_vehicle_id is distinct from vehicle_id),
  add constraint vehicle_listings_slug_format check (slug is null or slug ~ '^[a-z0-9]+(-[a-z0-9]+)*$');

-- The slug is fixed once the car has been published, and lastmod moves only with content.
create or replace function app.vehicle_listing_before_update() returns trigger
language plpgsql security definer set search_path = public, app as $$
begin
  if old.first_published_at is not null and new.slug is distinct from old.slug then
    raise exception 'The web address of a car that has been published does not change' using errcode = '23514';
  end if;
  if (new.headline, new.description, new.features, new.seats, new.transmission, new.specs, new.body_style, new.drivetrain,
      new.doors, new.luggage, new.faq, new.home_area, new.seo_title, new.seo_description, new.staff_note, new.status,
      new.canonical_vehicle_id)
     is distinct from
     (old.headline, old.description, old.features, old.seats, old.transmission, old.specs, old.body_style, old.drivetrain,
      old.doors, old.luggage, old.faq, old.home_area, old.seo_title, old.seo_description, old.staff_note, old.status,
      old.canonical_vehicle_id) then
    new.content_updated_at := now();
  end if;
  return new;
end $$;
create trigger vehicle_listings_guard before update on vehicle_listings
  for each row execute function app.vehicle_listing_before_update();

-- Old web addresses: a 301 to where the car's value went, or 410 when nothing relevant remains
-- (docs/blueprint/14-seo.md section 11). Read by the server for the middleware and the build.
create table listing_redirects (
  from_path   text primary key check (from_path ~ '^/[a-z0-9/-]+$'),
  to_path     text check (to_path is null or to_path ~ '^/[a-z0-9/-]*$'),
  status_code smallint not null check (status_code in (301, 410)),
  reason      text,
  vehicle_id  uuid references vehicles (id),
  created_by  uuid references users (id),
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now(),
  check ((status_code = 410) = (to_path is null)),
  check (from_path is distinct from to_path)
);
create index listing_redirects_to_idx on listing_redirects (to_path);
create trigger listing_redirects_updated before update on listing_redirects for each row execute function app.set_updated_at();

-- ---------------------------------------------------------------- intakes, jobs, drafts, costs
create table listing_intakes (
  id             uuid primary key default gen_random_uuid(),
  vehicle_id     uuid not null references vehicles (id),
  started_by     uuid references users (id),
  started_role   text not null check (started_role in ('owner', 'field', 'va', 'admin')),
  state          text not null default 'started' check (state in (
                   'started', 'decoding', 'photos_uploaded', 'drafting', 'processing_photos',
                   'needs_review', 'approved', 'published', 'failed', 'cancelled')),
  reason         text,                         -- why it failed, or what the reviewer asked for
  retries        integer not null default 0 check (retries >= 0),
  review_required boolean not null,
  decode_failed  boolean not null default false,
  draft_failed   boolean not null default false,
  colour         text,
  odometer_km    integer check (odometer_km >= 0),
  notes          text,                         -- for the reviewer
  submitted_at   timestamptz,
  reviewed_by    uuid references users (id),
  reviewed_at    timestamptz,
  approved_by    uuid references users (id),
  approved_at    timestamptz,
  published_at   timestamptz,
  failed_at      timestamptz,
  created_at     timestamptz not null default now(),
  updated_at     timestamptz not null default now()
);
create unique index listing_intakes_one_open on listing_intakes (vehicle_id) where state not in ('published', 'cancelled');
create index listing_intakes_state_idx on listing_intakes (state, updated_at);
create trigger listing_intakes_updated before update on listing_intakes for each row execute function app.set_updated_at();

create table listing_drafts (
  id              uuid primary key default gen_random_uuid(),
  intake_id       uuid references listing_intakes (id) on delete cascade,
  vehicle_id      uuid not null references vehicles (id),
  source          text not null default 'ai' check (source in ('ai', 'person')),
  model           text,
  prompt_version  text,
  headline        text,
  description     text,
  features        text[] not null default '{}',
  faq             jsonb not null default '[]'::jsonb check (jsonb_typeof(faq) = 'array'),
  seo_title       text,
  seo_description text,
  lint_problems   text[] not null default '{}',
  needs_rewrite   boolean not null default false,
  created_by      uuid references users (id),
  created_at      timestamptz not null default now()
);
create index listing_drafts_vehicle_idx on listing_drafts (vehicle_id, created_at desc);
alter table vehicle_listings add constraint vehicle_listings_draft_fkey foreign key (draft_id) references listing_drafts (id) on delete set null;

-- per-photo work stays in photo_jobs (0002): one row per photo, linked to its queue job
alter table photo_jobs
  add column vehicle_photo_id uuid references vehicle_photos (id) on delete cascade,
  add column intake_id        uuid references listing_intakes (id) on delete set null,
  add column provider         text,
  add column next_attempt_at  timestamptz,
  add column cost_microusd    bigint not null default 0 check (cost_microusd >= 0);

alter table vehicle_photos
  add column intake_id         uuid references listing_intakes (id) on delete set null,
  add column shot_type         text references listing_shot_types (code) on update cascade,
  add column alt_text          text,
  add column width             integer check (width > 0),
  add column height            integer check (height > 0),
  add column byte_size         bigint check (byte_size > 0),
  add column mime_type         text,
  add column variants          jsonb not null default '[]'::jsonb,   -- sizes and formats written by the resize step
  add column background_status text not null default 'pending'
                               check (background_status in ('not_needed', 'pending', 'processing', 'done', 'failed', 'original_used')),
  add column is_public         boolean not null default false,
  add column approved_at       timestamptz,
  add column replaced_at       timestamptz,     -- a retake of the same shot replaced it
  add column quality_flags     jsonb not null default '[]'::jsonb,
  add column provider          text,
  add column preset_version    text;
create index vehicle_photos_intake_idx on vehicle_photos (intake_id);

create table listing_jobs (
  id               uuid primary key default gen_random_uuid(),
  intake_id        uuid not null references listing_intakes (id) on delete cascade,
  vehicle_id       uuid not null references vehicles (id),
  kind             text not null check (kind in ('decode_vin', 'draft_copy', 'process_photo', 'resize', 'publish')),
  vehicle_photo_id uuid references vehicle_photos (id) on delete cascade,
  photo_job_id     uuid references photo_jobs (id) on delete set null,
  status           text not null default 'queued' check (status in ('queued', 'running', 'succeeded', 'failed', 'cancelled')),
  attempts         integer not null default 0 check (attempts >= 0),
  max_attempts     integer not null check (max_attempts > 0),
  next_attempt_at  timestamptz not null default now(),
  locked_at        timestamptz,
  locked_by        text,
  provider         text,
  cost_microusd    bigint not null default 0 check (cost_microusd >= 0),
  input            jsonb not null default '{}'::jsonb,
  output           jsonb,
  error            text,
  created_at       timestamptz not null default now(),
  started_at       timestamptz,
  finished_at      timestamptz,
  check (kind not in ('process_photo', 'resize') or vehicle_photo_id is not null)
);
create unique index listing_jobs_one_open on listing_jobs (intake_id, kind, coalesce(vehicle_photo_id, '00000000-0000-0000-0000-000000000000'::uuid))
  where status in ('queued', 'running');
create index listing_jobs_ready_idx on listing_jobs (next_attempt_at) where status = 'queued';
create index listing_jobs_intake_idx on listing_jobs (intake_id, status);

-- Every call to an outside provider, with its cost, so the cost per car can be reported.
create table provider_calls (
  id             uuid primary key default gen_random_uuid(),
  provider       text not null,
  purpose        text not null,                 -- decode_vin, draft_copy, process_photo, resize, publish ...
  listing_job_id uuid references listing_jobs (id) on delete set null,
  intake_id      uuid references listing_intakes (id) on delete set null,
  vehicle_id     uuid references vehicles (id),
  ok             boolean not null,
  error          text,
  duration_ms    integer check (duration_ms >= 0),
  cost_microusd  bigint not null default 0 check (cost_microusd >= 0),
  created_at     timestamptz not null default now()
);
create index provider_calls_vehicle_idx on provider_calls (vehicle_id, created_at);
create index provider_calls_day_idx on provider_calls (created_at);

-- ---------------------------------------------------------------- helpers
create or replace function app.slugify(p text) returns text
language sql immutable as $$
  select nullif(btrim(regexp_replace(lower(translate(coalesce(p, ''), 'ÀÁÂÃÄÅàáâãäåÈÉÊËèéêëÌÍÎÏìíîïÒÓÔÕÖòóôõöÙÚÛÜùúûüÇçÑñ',
                                                    'AAAAAAaaaaaaEEEEeeeeIIIIiiiiOOOOOoooooUUUUuuuuCcNn')),
                                     '[^a-z0-9]+', '-', 'g'), '-'), '')
$$;

-- A stable, unique slug: year-make-model-trim-colour and four characters from the vehicle id
-- (more when needed). Never one that belonged to another car, live or redirected.
create or replace function app.listing_slug(p_vehicle uuid) returns text
language plpgsql stable security definer set search_path = public, app as $$
declare
  v vehicles;
  v_base text;
  v_n integer := 4;
  v_try text;
begin
  select * into v from vehicles where id = p_vehicle;
  v_base := app.slugify(concat_ws(' ', v.year::text, v.make, v.model, v.trim, v.colour));
  loop
    v_try := v_base || '-' || substr(md5(v.id::text), 1, v_n);
    exit when not exists (select 1 from vehicle_listings l where l.slug = v_try and l.vehicle_id <> v.id)
          and not exists (select 1 from listing_redirects r where r.from_path = '/cars/' || v_try and r.vehicle_id is distinct from v.id);
    v_n := v_n + 1;
  end loop;
  return v_try;
end $$;

create or replace function app.model_hub_path(p_make text, p_model text) returns text
language sql immutable as $$ select '/rent/' || app.slugify(p_make || ' ' || p_model) $$;

-- The listing row of a vehicle, made when first needed.
create or replace function app.ensure_listing(p_vehicle uuid) returns uuid
language plpgsql security definer set search_path = public, app as $$
declare
  v_id uuid;
begin
  select id into v_id from vehicle_listings where vehicle_id = p_vehicle;
  if v_id is null then
    insert into vehicle_listings (vehicle_id, status, home_area, channels)
    select v.id, 'draft', coalesce(v.home_location, (app.settings()).listing_default_home_area), array['website']
      from vehicles v where v.id = p_vehicle
    returning id into v_id;
  end if;
  return v_id;
end $$;

create or replace function app.photo_alt_text(p_vehicle uuid, p_shot text) returns text
language sql stable security definer set search_path = public, app as $$
  select concat_ws(' ', v.year::text, v.make, v.model, nullif(v.trim, ''))
         || coalesce(' in ' || lower(nullif(v.colour, '')), '') || ', ' || lower(s.label) || ' view'
    from vehicles v, listing_shot_types s where v.id = p_vehicle and s.code = p_shot
$$;

-- The current photo set of a vehicle: not replaced, not rejected.
create or replace function app.listing_missing_shots(p_vehicle uuid) returns text[]
language sql stable security definer set search_path = public, app as $$
  select coalesce(array_agg(s.label order by s.seq), '{}')
    from listing_shot_types s
   where s.is_active and s.required
     and not exists (select 1 from vehicle_photos p where p.vehicle_id = p_vehicle and p.shot_type = s.code
                        and p.replaced_at is null and p.status <> 'rejected')
$$;

-- What stops the photos from going public.
create or replace function app.listing_photo_problems(p_vehicle uuid) returns text[]
language plpgsql stable security definer set search_path = public, app as $$
declare
  v_out text[] := '{}';
  v_min integer := (app.settings()).listing_min_photos;
  v_count integer;
  r record;
begin
  for r in select s.code, s.label from listing_shot_types s where s.is_active and s.required and s.is_public order by s.seq loop
    if not exists (select 1 from vehicle_photos p where p.vehicle_id = p_vehicle and p.shot_type = r.code and p.replaced_at is null
                     and p.status = 'approved' and p.processed_path is not null) then
      v_out := v_out || format('%s photo is not processed and approved', r.label);
    end if;
  end loop;
  select count(*) into v_count from vehicle_photos p
   where p.vehicle_id = p_vehicle and p.replaced_at is null and p.status = 'approved' and p.is_public and p.processed_path is not null;
  if v_count < v_min then
    v_out := v_out || format('%s approved public photos, at least %s needed', v_count, v_min);
  end if;
  if not exists (select 1 from vehicle_photos p where p.vehicle_id = p_vehicle and p.replaced_at is null and p.status = 'approved'
                   and p.is_public and p.is_cover) then
    v_out := v_out || 'No cover photo'::text;
  end if;
  return v_out;
end $$;

create or replace function app.listing_spec_problems(p_vehicle uuid) returns text[]
language sql stable security definer set search_path = public, app as $$
  select coalesce(array_agg(x.label order by x.ord) filter (where x.missing), '{}')
    from vehicles v left join vehicle_listings l on l.vehicle_id = v.id,
         lateral (values (1, 'Year', v.year is null), (2, 'Make', nullif(btrim(v.make), '') is null),
                         (3, 'Model', nullif(btrim(v.model), '') is null), (4, 'Colour', nullif(btrim(v.colour), '') is null),
                         (5, 'Fuel', v.fuel is null), (6, 'Body style', coalesce(nullif(btrim(l.body_style), ''), nullif(btrim(v.body_type), '')) is null),
                         (7, 'Seats', l.seats is null), (8, 'Transmission', nullif(btrim(l.transmission), '') is null)) x(ord, label, missing)
   where v.id = p_vehicle
$$;

-- The copy rules (lengths and banned phrases from program_settings; no em or en dash).
create or replace function app.listing_copy_problems(p_headline text, p_description text, p_features text[], p_faq jsonb)
returns text[] language plpgsql stable security definer set search_path = public, app as $$
declare
  ps program_settings := app.settings();
  v_out text[] := '{}';
  v_words integer := coalesce(array_length(regexp_split_to_array(btrim(coalesce(p_description, '')), '\s+'), 1), 0);
  v_all text := lower(concat_ws(' ', p_headline, p_description, array_to_string(p_features, ' '), p_faq::text));
  v_phrase text;
begin
  if nullif(btrim(p_description), '') is null then v_words := 0; end if;
  if not (coalesce(length(btrim(p_headline)), 0) <@ ps.listing_headline_chars) then
    v_out := v_out || format('Headline must be %s to %s characters', lower(ps.listing_headline_chars), upper(ps.listing_headline_chars) - 1);
  end if;
  if not (v_words <@ ps.listing_description_words) then
    v_out := v_out || format('Description must be %s to %s words', lower(ps.listing_description_words), upper(ps.listing_description_words) - 1);
  end if;
  if not (coalesce(cardinality(p_features), 0) <@ ps.listing_features_count) then
    v_out := v_out || format('List %s to %s features', lower(ps.listing_features_count), upper(ps.listing_features_count) - 1);
  end if;
  if not (coalesce(jsonb_array_length(p_faq), 0) <@ ps.listing_faq_count) then
    v_out := v_out || format('Give %s to %s questions and answers', lower(ps.listing_faq_count), upper(ps.listing_faq_count) - 1);
  end if;
  if exists (select 1 from jsonb_array_elements(coalesce(p_faq, '[]'::jsonb)) e where coalesce((e.value ->> 'check')::boolean, false)) then
    v_out := v_out || 'A question is still marked "check"'::text;
  end if;
  if position(chr(8212) in v_all) > 0 or position(' ' || chr(8211) || ' ' in v_all) > 0 then
    v_out := v_out || 'Remove the long dash'::text;
  end if;
  foreach v_phrase in array ps.listing_banned_phrases loop
    if position(lower(v_phrase) in v_all) > 0 then
      v_out := v_out || format('Remove the phrase "%s"', v_phrase);
    end if;
  end loop;
  return v_out;
end $$;

-- The facts the copy is written from (no VIN, plate or owner).
create or replace function app.listing_facts(p_vehicle uuid) returns jsonb
language sql stable security definer set search_path = public, app as $$
  select jsonb_strip_nulls(jsonb_build_object(
    'year', v.year, 'make', v.make, 'model', v.model, 'trim', v.trim, 'colour', v.colour, 'fuel', v.fuel, 'class', v.class,
    'body_style', coalesce(l.body_style, v.body_type), 'seats', l.seats, 'transmission', l.transmission, 'doors', l.doors,
    'drivetrain', l.drivetrain, 'specs', l.specs, 'home_area', l.home_area, 'allows_18_to_20', v.allows_18_to_20))
    from vehicles v left join vehicle_listings l on l.vehicle_id = v.id where v.id = p_vehicle
$$;

-- May this user work on this vehicle's listing? 'start': start an intake and upload photos;
-- 'review': edit and approve.
create or replace function app.user_may_list(p_user uuid, p_vehicle uuid, p_what text default 'start') returns boolean
language sql stable security definer set search_path = public, app as $$
  select case p_what
    when 'review' then app.user_is_admin(p_user) or app.user_va_has(p_user, 'cs', 'fleet')
    else app.user_is_admin(p_user) or app.user_va_has(p_user, 'fleet') or app.user_field_has_job(p_user, p_vehicle)
         or app.user_owns_vehicle(p_user, p_vehicle) end
$$;

-- ---------------------------------------------------------------- VIN decode results
-- Apply a decode to the vehicle and its listing. A value a person entered or confirmed
-- (spec_sources.<field>.source = 'person') is never overwritten. Returns the fields applied.
create or replace function app.apply_vin_decode(p_vehicle uuid, p_decode uuid) returns text[]
language plpgsql security definer set search_path = public, app as $$
declare
  d vin_decodes;
  v vehicles;
  l vehicle_listings;
  v_src jsonb;
  v_lsrc jsonb;
  v_applied text[] := '{}';
  v_mark jsonb := jsonb_build_object('source', 'decoded', 'decode_id', p_decode, 'at', now());
  v_specs jsonb;
begin
  select * into d from vin_decodes where id = p_decode;
  select * into v from vehicles where id = p_vehicle for update;
  if d.id is null or v.id is null or not d.ok then return v_applied; end if;
  perform app.ensure_listing(p_vehicle);
  select * into l from vehicle_listings where vehicle_id = p_vehicle for update;
  v_src := coalesce(v.spec_sources, '{}'::jsonb);
  v_lsrc := coalesce(l.spec_sources, '{}'::jsonb);

  if d.year is not null and coalesce(v_src -> 'year' ->> 'source', '') <> 'person' and v.year is distinct from d.year then
    v.year := d.year; v_applied := v_applied || 'year'::text; v_src := v_src || jsonb_build_object('year', v_mark); end if;
  if d.make is not null and coalesce(v_src -> 'make' ->> 'source', '') <> 'person' and v.make is distinct from d.make then
    v.make := d.make; v_applied := v_applied || 'make'::text; v_src := v_src || jsonb_build_object('make', v_mark); end if;
  if d.model is not null and coalesce(v_src -> 'model' ->> 'source', '') <> 'person' and v.model is distinct from d.model then
    v.model := d.model; v_applied := v_applied || 'model'::text; v_src := v_src || jsonb_build_object('model', v_mark); end if;
  if d.trim is not null and coalesce(v_src -> 'trim' ->> 'source', '') <> 'person' and v.trim is distinct from d.trim then
    v.trim := d.trim; v_applied := v_applied || 'trim'::text; v_src := v_src || jsonb_build_object('trim', v_mark); end if;
  if d.fuel is not null and coalesce(v_src -> 'fuel' ->> 'source', '') <> 'person' and v.fuel is distinct from d.fuel then
    v.fuel := d.fuel; v_applied := v_applied || 'fuel'::text; v_src := v_src || jsonb_build_object('fuel', v_mark); end if;
  if d.body_class is not null and coalesce(v_src -> 'body_type' ->> 'source', '') <> 'person' and v.body_type is distinct from d.body_class then
    v.body_type := d.body_class; v_applied := v_applied || 'body_type'::text; v_src := v_src || jsonb_build_object('body_type', v_mark); end if;
  update vehicles set year = v.year, make = v.make, model = v.model, trim = v.trim, fuel = v.fuel, body_type = v.body_type,
         spec_sources = v_src where id = p_vehicle;

  if d.seats is not null and coalesce(v_lsrc -> 'seats' ->> 'source', '') <> 'person' and l.seats is distinct from d.seats then
    l.seats := d.seats; v_applied := v_applied || 'seats'::text; v_lsrc := v_lsrc || jsonb_build_object('seats', v_mark); end if;
  if d.transmission is not null and coalesce(v_lsrc -> 'transmission' ->> 'source', '') <> 'person' and l.transmission is distinct from d.transmission then
    l.transmission := d.transmission; v_applied := v_applied || 'transmission'::text; v_lsrc := v_lsrc || jsonb_build_object('transmission', v_mark); end if;
  if d.doors is not null and coalesce(v_lsrc -> 'doors' ->> 'source', '') <> 'person' and l.doors is distinct from d.doors then
    l.doors := d.doors; v_applied := v_applied || 'doors'::text; v_lsrc := v_lsrc || jsonb_build_object('doors', v_mark); end if;
  if d.drivetrain is not null and coalesce(v_lsrc -> 'drivetrain' ->> 'source', '') <> 'person' and l.drivetrain is distinct from d.drivetrain then
    l.drivetrain := d.drivetrain; v_applied := v_applied || 'drivetrain'::text; v_lsrc := v_lsrc || jsonb_build_object('drivetrain', v_mark); end if;
  if d.body_class is not null and coalesce(v_lsrc -> 'body_style' ->> 'source', '') <> 'person' and l.body_style is distinct from d.body_class then
    l.body_style := d.body_class; v_lsrc := v_lsrc || jsonb_build_object('body_style', v_mark); end if;
  v_specs := l.specs;
  if d.engine is not null and coalesce(v_lsrc -> 'engine' ->> 'source', '') <> 'person' then
    v_specs := v_specs || jsonb_build_object('engine', d.engine);
  end if;
  update vehicle_listings set seats = l.seats, transmission = l.transmission, doors = l.doors, drivetrain = l.drivetrain,
         body_style = l.body_style, specs = v_specs, spec_sources = v_lsrc
   where id = l.id;
  return v_applied;
end $$;

-- A person enters or confirms facts. Each value given is marked as a person's, so no later
-- decode changes it. The class sets the Deposit, so only an Admin or Fleet changes it.
create or replace function app.confirm_vehicle_specs(p_by uuid, p_vehicle uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  v_mark jsonb := jsonb_build_object('source', 'person', 'by', p_by, 'at', now());
  v_src jsonb := '{}'::jsonb;
  v_lsrc jsonb := '{}'::jsonb;
  k text;
begin
  if not (app.user_may_list(p_by, p_vehicle, 'start') or app.user_may_list(p_by, p_vehicle, 'review')) then
    raise exception 'Not permitted to change this vehicle''s details' using errcode = '42501';
  end if;
  if p ? 'class' and not (app.user_is_admin(p_by) or app.user_va_has(p_by, 'fleet')) then
    raise exception 'Only an Admin or Fleet sets the vehicle class (it sets the Deposit)' using errcode = '42501';
  end if;
  perform app.ensure_listing(p_vehicle);
  foreach k in array array['year', 'make', 'model', 'trim', 'colour', 'fuel', 'body_type', 'odometer_km', 'class'] loop
    if p ? k then v_src := v_src || jsonb_build_object(k, v_mark); end if;
  end loop;
  foreach k in array array['seats', 'transmission', 'doors', 'drivetrain', 'body_style', 'luggage', 'engine'] loop
    if p ? k then v_lsrc := v_lsrc || jsonb_build_object(k, v_mark); end if;
  end loop;
  update vehicles set
    year = coalesce((p ->> 'year')::smallint, year), make = coalesce(nullif(btrim(p ->> 'make'), ''), make),
    model = coalesce(nullif(btrim(p ->> 'model'), ''), model),
    trim = case when p ? 'trim' then nullif(btrim(p ->> 'trim'), '') else trim end,
    colour = case when p ? 'colour' then nullif(btrim(p ->> 'colour'), '') else colour end,
    fuel = coalesce((p ->> 'fuel')::fuel_type, fuel), body_type = case when p ? 'body_type' then nullif(btrim(p ->> 'body_type'), '') else body_type end,
    odometer_km = coalesce((p ->> 'odometer_km')::integer, odometer_km), class = coalesce((p ->> 'class')::vehicle_class, class),
    spec_sources = spec_sources || v_src
   where id = p_vehicle;
  update vehicle_listings set
    seats = coalesce((p ->> 'seats')::smallint, seats), transmission = coalesce(nullif(btrim(p ->> 'transmission'), ''), transmission),
    doors = coalesce((p ->> 'doors')::smallint, doors), drivetrain = coalesce(nullif(btrim(p ->> 'drivetrain'), ''), drivetrain),
    body_style = coalesce(nullif(btrim(p ->> 'body_style'), ''), body_style), luggage = coalesce(nullif(btrim(p ->> 'luggage'), ''), luggage),
    specs = case when p ? 'engine' then specs || jsonb_build_object('engine', p ->> 'engine') else specs end
            || coalesce(case when jsonb_typeof(p -> 'specs') = 'object' then p -> 'specs' end, '{}'::jsonb),
    spec_sources = spec_sources || v_lsrc
   where vehicle_id = p_vehicle;
  return jsonb_build_object('vehicle_id', p_vehicle, 'confirmed', (select coalesce(jsonb_agg(x), '[]'::jsonb) from (select jsonb_object_keys(v_src || v_lsrc) x) q));
end $$;

-- ---------------------------------------------------------------- drafts
-- Store a draft of the copy (AI or person) with the model and prompt version, and its lint
-- result. Fields of the listing that are still empty are filled from it; copy already on the
-- listing (a person's, or a published car's) is never overwritten by a draft.
create or replace function app.store_listing_draft(p_intake uuid, p jsonb, p_model text default null,
                                                   p_prompt_version text default null, p_by uuid default null)
returns uuid language plpgsql security definer set search_path = public, app as $$
declare
  i listing_intakes;
  v_features text[] := coalesce((select array_agg(btrim(e)) from jsonb_array_elements_text(coalesce(p -> 'features', '[]'::jsonb)) e where btrim(e) <> ''), '{}');
  v_faq jsonb := coalesce(case when jsonb_typeof(p -> 'faq') = 'array' then p -> 'faq' end, '[]'::jsonb);
  v_problems text[];
  v_id uuid;
begin
  select * into i from listing_intakes where id = p_intake;
  if i.id is null then raise exception 'Listing intake not found' using errcode = 'P0002'; end if;
  v_problems := app.listing_copy_problems(p ->> 'headline', p ->> 'description', v_features, v_faq);
  insert into listing_drafts (intake_id, vehicle_id, source, model, prompt_version, headline, description, features, faq,
                              seo_title, seo_description, lint_problems, needs_rewrite, created_by)
  values (i.id, i.vehicle_id, case when p_by is null then 'ai' else 'person' end, coalesce(p_model, p ->> 'model'),
          coalesce(p_prompt_version, p ->> 'prompt_version'), nullif(btrim(p ->> 'headline'), ''), nullif(btrim(p ->> 'description'), ''),
          v_features, v_faq, nullif(btrim(p ->> 'seo_title'), ''), nullif(btrim(p ->> 'seo_description'), ''),
          v_problems, cardinality(v_problems) > 0, p_by)
  returning id into v_id;
  perform app.ensure_listing(i.vehicle_id);
  update vehicle_listings l set
    headline = coalesce(l.headline, nullif(btrim(p ->> 'headline'), '')),
    description = coalesce(l.description, nullif(btrim(p ->> 'description'), '')),
    features = case when cardinality(l.features) = 0 then v_features else l.features end,
    faq = case when jsonb_array_length(l.faq) = 0 then v_faq else l.faq end,
    seo_title = coalesce(l.seo_title, nullif(btrim(p ->> 'seo_title'), '')),
    seo_description = coalesce(l.seo_description, nullif(btrim(p ->> 'seo_description'), '')),
    draft_id = v_id, needs_rewrite = cardinality(v_problems) > 0
   where l.vehicle_id = i.vehicle_id;
  return v_id;
end $$;

-- ---------------------------------------------------------------- the queue
create or replace function app.enqueue_listing_job(p_intake uuid, p_kind text, p_photo uuid default null, p_input jsonb default '{}'::jsonb)
returns uuid language plpgsql security definer set search_path = public, app as $$
declare
  i listing_intakes;
  v_id uuid;
  v_photo_job uuid;
  s listing_shot_types;
begin
  select * into i from listing_intakes where id = p_intake;
  select id into v_id from listing_jobs
   where intake_id = p_intake and kind = p_kind and vehicle_photo_id is not distinct from p_photo and status in ('queued', 'running');
  if v_id is not null then return v_id; end if;
  if p_kind = 'process_photo' then
    select st.* into s from vehicle_photos ph join listing_shot_types st on st.code = ph.shot_type where ph.id = p_photo;
    insert into photo_jobs (vehicle_id, vehicle_photo_id, intake_id, status, preset, requested_by)
    values (i.vehicle_id, p_photo, p_intake, 'queued', case when s.rebackground then 'brand_background_v1' else 'normalize_v1' end, i.started_by)
    returning id into v_photo_job;
    p_input := p_input || jsonb_build_object('rebackground', coalesce(s.rebackground, false),
                                            'source', (select original_path from vehicle_photos where id = p_photo));
  end if;
  insert into listing_jobs (intake_id, vehicle_id, kind, vehicle_photo_id, photo_job_id, max_attempts, input)
  values (p_intake, i.vehicle_id, p_kind, p_photo, v_photo_job, (app.settings()).listing_job_max_attempts, coalesce(p_input, '{}'::jsonb))
  returning id into v_id;
  return v_id;
end $$;

-- Work out the intake's state from its jobs. Called after every step.
create or replace function app.advance_listing_intake(p_intake uuid) returns text
language plpgsql security definer set search_path = public, app as $$
declare
  i listing_intakes;
  v_state text;
  v_reason text;
  v_failed text;
begin
  select * into i from listing_intakes where id = p_intake for update;
  if i.id is null or i.state in ('needs_review', 'approved', 'published', 'cancelled') then return i.state; end if;
  select string_agg(j.kind || coalesce(' (' || st.label || ')', '') || ': ' || coalesce(j.error, 'failed'), '; ' order by j.created_at)
    into v_failed
    from listing_jobs j left join vehicle_photos p on p.id = j.vehicle_photo_id left join listing_shot_types st on st.code = p.shot_type
   where j.intake_id = i.id and j.status = 'failed' and j.kind in ('process_photo', 'resize', 'publish');
  if v_failed is not null then
    v_state := 'failed'; v_reason := v_failed;
  elsif i.submitted_at is null then
    if exists (select 1 from listing_jobs j where j.intake_id = i.id and j.kind = 'decode_vin' and j.status in ('queued', 'running')) then
      v_state := 'decoding';
    elsif cardinality(app.listing_missing_shots(i.vehicle_id)) = 0 then
      v_state := 'photos_uploaded';
    else
      v_state := 'started';
    end if;
  elsif exists (select 1 from listing_jobs j where j.intake_id = i.id and j.kind in ('decode_vin', 'draft_copy') and j.status in ('queued', 'running')) then
    v_state := 'drafting';
  elsif exists (select 1 from listing_jobs j where j.intake_id = i.id and j.kind in ('process_photo', 'resize') and j.status in ('queued', 'running')) then
    v_state := 'processing_photos';
  elsif i.review_required then
    v_state := 'needs_review';
  else
    v_state := 'approved';
  end if;

  update listing_intakes
     set state = v_state, reason = case when v_state = 'failed' then v_reason else reason end,
         failed_at = case when v_state = 'failed' then coalesce(failed_at, now()) else null end
   where id = i.id;

  if v_state = 'failed' and i.state <> 'failed' then
    perform app.raise_task(p_type => 'listing_failed', p_title => format('Listing stopped: %s', app.vehicle_name(i.vehicle_id)),
        p_detail => v_reason, p_vehicle => i.vehicle_id, p_related_table => 'listing_intakes', p_related_id => i.id,
        p_dedupe => 'listing_failed:' || i.id || ':' || i.retries);
  elsif v_state = 'needs_review' then
    update tasks set status = 'done', completed_at = now(), completion_note = 'retried'
     where related_id = i.id and task_type = 'listing_failed' and status in ('open', 'in_progress', 'waiting');
    perform app.raise_task(p_type => 'review_listing', p_title => format('Review the listing: %s', app.vehicle_name(i.vehicle_id)),
        p_vehicle => i.vehicle_id, p_related_table => 'listing_intakes', p_related_id => i.id,
        p_dedupe => 'review_listing:' || i.id);
    perform app.emit_event('staff_listing_ready_for_review', 'listing_intake', i.id,
      jsonb_build_object('vehicle_id', i.vehicle_id, 'vehicle_name', app.vehicle_name(i.vehicle_id), 'started_role', i.started_role,
                         'decode_failed', i.decode_failed, 'draft_failed', i.draft_failed,
                         'needs_rewrite', (select l.needs_rewrite from vehicle_listings l where l.vehicle_id = i.vehicle_id)),
      'staff_listing_ready_for_review:' || i.id || ':' || i.retries);
  elsif v_state = 'approved' then
    -- the starter's role needs no review: publish now if every requirement is met; otherwise
    -- the intake waits as approved and app.publish_listing() is run when the last one is met
    update listing_intakes set approved_at = now(), approved_by = started_by where id = i.id;
    update vehicle_photos ph set status = 'approved', approved_by = i.started_by, approved_at = now(), is_public = st.is_public
      from listing_shot_types st
     where st.code = ph.shot_type and ph.vehicle_id = i.vehicle_id and ph.replaced_at is null
       and ph.status = 'processed' and ph.processed_path is not null;
    begin
      perform app.publish_listing(i.vehicle_id, i.started_by);
    exception when sqlstate '23514' or sqlstate '42501' then
      get stacked diagnostics v_reason = message_text;
      update listing_intakes set reason = v_reason where id = i.id;
    end;
  end if;
  return (select state from listing_intakes where id = i.id);
end $$;

-- ---------------------------------------------------------------- start, upload, submit
-- p: {vehicle_id} or {vin} or {plate}, and optional colour, odometer_km, notes.
create or replace function app.start_listing_intake(p_by uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  v vehicles;
  i listing_intakes;
  v_role text := app.acting_role(p_by);
  d vin_decodes;
  ps program_settings := app.settings();
begin
  p := coalesce(p, '{}'::jsonb);
  if nullif(p ->> 'vehicle_id', '') is not null then
    select * into v from vehicles where id = (p ->> 'vehicle_id')::uuid;
  elsif app.clean_vin(p ->> 'vin') is not null then
    select * into v from vehicles where upper(vin) = app.clean_vin(p ->> 'vin');
  elsif nullif(btrim(p ->> 'plate'), '') is not null then
    select * into v from vehicles where upper(plate) = upper(regexp_replace(p ->> 'plate', '\s', '', 'g'));
  end if;
  if v.id is null then
    raise exception 'We do not have this car yet. Add it with the owner application first, then list it.' using errcode = 'P0002';
  end if;
  if p_by is null or not app.user_may_list(p_by, v.id, 'start') then
    raise exception 'Not permitted: an owner lists only their own car, and field staff only a car of their assigned job' using errcode = '42501';
  end if;
  if app.user_owns_vehicle(p_by, v.id) and not app.user_is_admin(p_by) and not app.user_va_has(p_by) then
    v_role := 'owner';
  end if;
  if v.status in ('exited', 'total_loss', 'declined') or v.management_mode = 'turo_only' then
    raise exception 'This vehicle cannot be listed on the CarmaCars website' using errcode = '23514';
  end if;
  select * into i from listing_intakes where vehicle_id = v.id and state not in ('published', 'cancelled');
  if i.id is not null then
    return jsonb_build_object('intake_id', i.id, 'state', i.state, 'existing', true, 'missing', to_jsonb(app.listing_missing_shots(v.id)));
  end if;

  perform app.ensure_listing(v.id);
  insert into listing_intakes (vehicle_id, started_by, started_role, review_required, colour, odometer_km, notes)
  values (v.id, p_by, v_role, v_role = any (ps.listing_review_required_roles),
          nullif(btrim(p ->> 'colour'), ''), nullif(p ->> 'odometer_km', '')::integer, nullif(btrim(p ->> 'notes'), ''))
  returning * into i;
  if i.colour is not null or i.odometer_km is not null then
    perform app.confirm_vehicle_specs(p_by, v.id, jsonb_strip_nulls(jsonb_build_object('colour', i.colour, 'odometer_km', i.odometer_km)));
  end if;

  select * into d from vin_decodes x where x.vin = upper(v.vin) and x.ok order by x.decoded_at desc limit 1;
  if d.id is not null then
    perform app.apply_vin_decode(v.id, d.id);
  else
    perform app.enqueue_listing_job(i.id, 'decode_vin', null, jsonb_build_object('vin', upper(v.vin)));
  end if;
  return jsonb_build_object('intake_id', i.id, 'state', app.advance_listing_intake(i.id), 'existing', false,
                            'review_required', i.review_required,
                            'shots', (select jsonb_agg(jsonb_build_object('code', s.code, 'label', s.label, 'seq', s.seq, 'required', s.required,
                                                                          'max_count', s.max_count, 'guide', s.guide) order by s.seq)
                                        from listing_shot_types s where s.is_active),
                            'missing', to_jsonb(app.listing_missing_shots(v.id)));
end $$;

-- Record one uploaded photo (the file is already in storage). A second photo of a shot that
-- allows one replaces the first. Returns what is still missing.
create or replace function app.record_listing_upload(p_by uuid, p_intake uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  i listing_intakes;
  s listing_shot_types;
  v_id uuid;
  v_n integer;
  v_missing text[];
begin
  select * into i from listing_intakes where id = p_intake for update;
  if i.id is null then raise exception 'Listing intake not found' using errcode = 'P0002'; end if;
  if p_by is null or not (app.user_may_list(p_by, i.vehicle_id, 'start') or app.user_may_list(p_by, i.vehicle_id, 'review')) then
    raise exception 'Not permitted' using errcode = '42501';
  end if;
  if i.state in ('published', 'cancelled', 'approved') then
    raise exception 'This listing intake is %; start a new one for new photos', i.state using errcode = '23514';
  end if;
  select * into s from listing_shot_types where code = p ->> 'shot_type' and is_active;
  if s.code is null then
    raise exception 'Unknown photo: %', p ->> 'shot_type' using errcode = '22023';
  end if;
  if nullif(btrim(p ->> 'original_path'), '') is null then
    raise exception 'The photo''s storage path is missing' using errcode = '22023';
  end if;
  select count(*) into v_n from vehicle_photos ph where ph.vehicle_id = i.vehicle_id and ph.shot_type = s.code and ph.replaced_at is null and ph.status <> 'rejected';
  if s.max_count = 1 then
    update vehicle_photos set replaced_at = now(), is_public = false, is_cover = false
     where vehicle_id = i.vehicle_id and shot_type = s.code and replaced_at is null;
    update listing_jobs set status = 'cancelled', finished_at = now()
     where intake_id = i.id and status in ('queued', 'running')
       and vehicle_photo_id in (select id from vehicle_photos where vehicle_id = i.vehicle_id and shot_type = s.code and replaced_at is not null);
  elsif v_n >= s.max_count then
    raise exception 'At most % photos of "%"', s.max_count, s.label using errcode = '23514';
  end if;
  -- the alt text is written when the photo is processed, after the VIN decode has settled the facts
  insert into vehicle_photos (vehicle_id, intake_id, angle, shot_type, original_path, status, sort_order, uploaded_by, width, height,
                              byte_size, mime_type, background_status, alt_text, is_cover)
  values (i.vehicle_id, i.id, s.photo_angle, s.code, btrim(p ->> 'original_path'), 'uploaded', s.seq * 100 + v_n, p_by,
          nullif(p ->> 'width', '')::integer, nullif(p ->> 'height', '')::integer, nullif(p ->> 'byte_size', '')::bigint, p ->> 'mime_type',
          case when s.rebackground then 'pending' else 'not_needed' end, null, s.is_cover)
  returning id into v_id;
  -- a retake after submission is processed straight away
  if i.submitted_at is not null then
    perform app.enqueue_listing_job(i.id, 'process_photo', v_id);
    if i.state in ('needs_review', 'failed') then
      update listing_intakes set state = 'processing_photos', reason = null where id = i.id;
    end if;
  end if;
  v_missing := app.listing_missing_shots(i.vehicle_id);
  return jsonb_build_object('photo_id', v_id, 'missing', to_jsonb(v_missing), 'complete', cardinality(v_missing) = 0,
                            'state', app.advance_listing_intake(i.id));
end $$;

-- "Submit for listing": every required photo is there. Queues the copy draft and the photo
-- processing.
create or replace function app.submit_listing_intake(p_by uuid, p_intake uuid) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  i listing_intakes;
  v_missing text[];
  r record;
begin
  select * into i from listing_intakes where id = p_intake for update;
  if i.id is null then raise exception 'Listing intake not found' using errcode = 'P0002'; end if;
  if p_by is null or not (app.user_may_list(p_by, i.vehicle_id, 'start') or app.user_may_list(p_by, i.vehicle_id, 'review')) then
    raise exception 'Not permitted' using errcode = '42501';
  end if;
  if i.submitted_at is not null then
    return jsonb_build_object('intake_id', i.id, 'state', i.state, 'already_submitted', true);
  end if;
  v_missing := app.listing_missing_shots(i.vehicle_id);
  if cardinality(v_missing) > 0 then
    raise exception 'Photos still needed: %', array_to_string(v_missing, ', ') using errcode = '23514';
  end if;
  update listing_intakes set submitted_at = now() where id = i.id;
  perform app.enqueue_listing_job(i.id, 'draft_copy', null,
    jsonb_build_object('facts', app.listing_facts(i.vehicle_id), 'notes', i.notes));
  for r in select ph.id from vehicle_photos ph
            where ph.vehicle_id = i.vehicle_id and ph.replaced_at is null and ph.status in ('uploaded', 'processing')
            order by ph.sort_order loop
    perform app.enqueue_listing_job(i.id, 'process_photo', r.id);
  end loop;
  return jsonb_build_object('intake_id', i.id, 'state', app.advance_listing_intake(i.id));
end $$;

-- ---------------------------------------------------------------- the worker's side
-- Claim up to p_limit jobs that are due, with skip locked so two workers never take the same
-- job. A job claimed earlier and not finished within listing_job_lock_minutes is claimed again.
-- Photo work stops for the day once the day's provider cost reaches photo_daily_budget_microusd.
create or replace function app.claim_listing_jobs(p_worker text, p_limit integer default 4, p_kinds text[] default null,
                                                  p_now timestamptz default now())
returns setof listing_jobs language plpgsql security definer set search_path = public, app as $$
declare
  ps program_settings := app.settings(app.local_date(p_now));
  v_spent bigint;
  j listing_jobs;
begin
  select coalesce(sum(cost_microusd), 0) into v_spent from provider_calls
   where created_at >= app.local_midnight(app.local_date(p_now)) and created_at < app.local_midnight(app.local_date(p_now) + 1);
  for j in
    select * from listing_jobs x
     where ((x.status = 'queued' and x.next_attempt_at <= p_now)
            or (x.status = 'running' and x.locked_at < p_now - make_interval(mins => ps.listing_job_lock_minutes)))
       and (p_kinds is null or x.kind = any (p_kinds))
       and (x.kind not in ('process_photo', 'resize') or v_spent < ps.photo_daily_budget_microusd)
     order by x.next_attempt_at, x.created_at
     limit greatest(coalesce(p_limit, 1), 1)
     for update skip locked
  loop
    update listing_jobs set status = 'running', locked_at = p_now, locked_by = p_worker, attempts = attempts + 1,
           started_at = coalesce(started_at, p_now)
     where id = j.id returning * into j;
    if j.photo_job_id is not null then
      update photo_jobs set status = 'processing', started_at = coalesce(started_at, p_now), attempts = j.attempts where id = j.photo_job_id;
      update vehicle_photos set status = 'processing',
             background_status = case when background_status = 'pending' then 'processing' else background_status end
       where id = j.vehicle_photo_id and status = 'uploaded';
    end if;
    return next j;
  end loop;
end $$;

create or replace function app.log_provider_call(p_job listing_jobs, p_provider text, p_ok boolean, p_error text,
                                                 p_cost bigint, p_duration_ms integer)
returns void language sql security definer set search_path = public, app as $$
  insert into provider_calls (provider, purpose, listing_job_id, intake_id, vehicle_id, ok, error, duration_ms, cost_microusd)
  select p_provider, p_job.kind, p_job.id, p_job.intake_id, p_job.vehicle_id, p_ok, p_error, p_duration_ms, coalesce(p_cost, 0)
   where p_provider is not null
$$;

-- The worker reports a result. Outputs by kind:
--   decode_vin    {ok, provider, year, make, model, trim, body_class, fuel, drivetrain, transmission, doors, seats, engine, error_code, raw}
--   draft_copy    {headline, description, features[], faq[], seo_title, seo_description, model, prompt_version}
--   process_photo {processed_path, width, height, flags[], used_original}
--   resize        {variants: [{width, format, path}]}
create or replace function app.complete_listing_job(p_job uuid, p_output jsonb default '{}'::jsonb, p_provider text default null,
                                                    p_cost_microusd bigint default 0, p_duration_ms integer default null)
returns jsonb language plpgsql security definer set search_path = public, app as $$
declare
  j listing_jobs;
  i listing_intakes;
  v_vin text;
  v_dec uuid;
  v_ok boolean;
begin
  select * into j from listing_jobs where id = p_job for update;
  if j.id is null then raise exception 'Listing job not found' using errcode = 'P0002'; end if;
  if j.status = 'succeeded' then return jsonb_build_object('job_id', j.id, 'status', j.status, 'repeat', true); end if;
  if j.status <> 'running' then
    raise exception 'This job is % and cannot be completed', j.status using errcode = '23514';
  end if;
  p_output := coalesce(p_output, '{}'::jsonb);
  select * into i from listing_intakes where id = j.intake_id;
  perform app.log_provider_call(j, coalesce(p_provider, p_output ->> 'provider'), true, null, p_cost_microusd, p_duration_ms);

  if j.kind = 'decode_vin' then
    select upper(vin) into v_vin from vehicles where id = j.vehicle_id;
    v_ok := coalesce((p_output ->> 'ok')::boolean, false) and nullif(p_output ->> 'year', '') is not null
            and nullif(p_output ->> 'make', '') is not null and nullif(p_output ->> 'model', '') is not null;
    insert into vin_decodes (vin, provider, ok, error_code, raw, year, make, model, trim, body_class, fuel, drivetrain, transmission, doors, seats, engine)
    values (v_vin, coalesce(p_provider, p_output ->> 'provider', 'unknown'), v_ok, p_output ->> 'error_code', coalesce(p_output -> 'raw', '{}'::jsonb),
            nullif(p_output ->> 'year', '')::smallint, nullif(p_output ->> 'make', ''), nullif(p_output ->> 'model', ''), nullif(p_output ->> 'trim', ''),
            nullif(p_output ->> 'body_class', ''), nullif(p_output ->> 'fuel', '')::fuel_type, nullif(p_output ->> 'drivetrain', ''),
            nullif(p_output ->> 'transmission', ''), nullif(p_output ->> 'doors', '')::smallint, nullif(p_output ->> 'seats', '')::smallint,
            nullif(p_output ->> 'engine', ''))
    returning id into v_dec;
    if v_ok then
      perform app.apply_vin_decode(j.vehicle_id, v_dec);
    else
      update listing_intakes set decode_failed = true where id = i.id;
    end if;
  elsif j.kind = 'draft_copy' then
    perform app.store_listing_draft(i.id, p_output, p_output ->> 'model', p_output ->> 'prompt_version', null);
  elsif j.kind = 'process_photo' then
    if nullif(p_output ->> 'processed_path', '') is null and not coalesce((p_output ->> 'used_original')::boolean, false) then
      raise exception 'A processed photo needs its storage path' using errcode = '22023';
    end if;
    update vehicle_photos ph set
      processed_path = coalesce(nullif(p_output ->> 'processed_path', ''), ph.original_path),
      status = 'processed',
      background_status = case when coalesce((p_output ->> 'used_original')::boolean, false) then 'original_used'
                               when ph.background_status in ('pending', 'processing') then 'done' else ph.background_status end,
      width = coalesce(nullif(p_output ->> 'width', '')::integer, ph.width), height = coalesce(nullif(p_output ->> 'height', '')::integer, ph.height),
      quality_flags = coalesce(p_output -> 'flags', ph.quality_flags), provider = coalesce(p_provider, ph.provider),
      preset_version = coalesce(p_output ->> 'preset_version', ph.preset_version),
      -- written from the facts as they stand after the decode (a reviewer may reword it)
      alt_text = coalesce(ph.alt_text, app.photo_alt_text(ph.vehicle_id, ph.shot_type))
     where ph.id = j.vehicle_photo_id;
    update photo_jobs set status = 'succeeded', finished_at = now(), provider = p_provider, error = null,
           cost_microusd = cost_microusd + coalesce(p_cost_microusd, 0), next_attempt_at = null
     where id = j.photo_job_id;
    perform app.enqueue_listing_job(i.id, 'resize', j.vehicle_photo_id,
      jsonb_build_object('source', (select processed_path from vehicle_photos where id = j.vehicle_photo_id)));
  elsif j.kind = 'resize' then
    update vehicle_photos set variants = coalesce(p_output -> 'variants', '[]'::jsonb) where id = j.vehicle_photo_id;
  elsif j.kind = 'publish' then
    perform app.publish_listing(j.vehicle_id, null);
  end if;

  update listing_jobs set status = 'succeeded', output = p_output, provider = coalesce(p_provider, provider),
         cost_microusd = cost_microusd + coalesce(p_cost_microusd, 0), finished_at = now(), locked_at = null, error = null
   where id = j.id;
  return jsonb_build_object('job_id', j.id, 'status', 'succeeded', 'intake_state', app.advance_listing_intake(i.id));
end $$;

-- The worker reports a failure. A retryable failure is queued again after the next back-off
-- step (listing_job_backoff_minutes) until listing_job_max_attempts; then the job fails. A
-- failed decode or draft does not stop the listing (the reviewer types the facts or the copy);
-- a failed photo step stops it until someone retries (app.retry_listing_intake).
create or replace function app.fail_listing_job(p_job uuid, p_error text, p_retryable boolean default true,
                                                p_provider text default null, p_cost_microusd bigint default 0,
                                                p_now timestamptz default now())
returns jsonb language plpgsql security definer set search_path = public, app as $$
declare
  j listing_jobs;
  v_backoff integer[] := (app.settings(app.local_date(p_now))).listing_job_backoff_minutes;
  v_next timestamptz;
begin
  select * into j from listing_jobs where id = p_job for update;
  if j.id is null then raise exception 'Listing job not found' using errcode = 'P0002'; end if;
  if j.status <> 'running' then
    raise exception 'This job is % and cannot fail', j.status using errcode = '23514';
  end if;
  perform app.log_provider_call(j, p_provider, false, p_error, p_cost_microusd, null);
  if coalesce(p_retryable, true) and j.attempts < j.max_attempts then
    v_next := p_now + make_interval(mins => coalesce(v_backoff[least(j.attempts, cardinality(v_backoff))], 0));
    update listing_jobs set status = 'queued', next_attempt_at = v_next, error = p_error, locked_at = null, locked_by = null,
           provider = coalesce(p_provider, provider), cost_microusd = cost_microusd + coalesce(p_cost_microusd, 0)
     where id = j.id;
    update photo_jobs set status = 'queued', next_attempt_at = v_next, error = p_error, attempts = j.attempts,
           cost_microusd = cost_microusd + coalesce(p_cost_microusd, 0)
     where id = j.photo_job_id;
  else
    update listing_jobs set status = 'failed', finished_at = p_now, error = p_error, locked_at = null,
           provider = coalesce(p_provider, provider), cost_microusd = cost_microusd + coalesce(p_cost_microusd, 0)
     where id = j.id;
    update photo_jobs set status = 'failed', finished_at = p_now, error = p_error, attempts = j.attempts where id = j.photo_job_id;
    if j.kind = 'process_photo' then
      update vehicle_photos set background_status = 'failed', status = 'uploaded' where id = j.vehicle_photo_id;
    elsif j.kind = 'decode_vin' then
      update listing_intakes set decode_failed = true where id = j.intake_id;
    elsif j.kind = 'draft_copy' then
      update listing_intakes set draft_failed = true where id = j.intake_id;
    end if;
  end if;
  return jsonb_build_object('job_id', j.id, 'status', (select status from listing_jobs where id = j.id), 'next_attempt_at', v_next,
                            'intake_state', app.advance_listing_intake(j.intake_id));
end $$;

-- Start the failed steps again.
create or replace function app.retry_listing_intake(p_by uuid, p_intake uuid) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  i listing_intakes;
begin
  select * into i from listing_intakes where id = p_intake for update;
  if i.id is null then raise exception 'Listing intake not found' using errcode = 'P0002'; end if;
  if not (app.user_may_list(p_by, i.vehicle_id, 'review') or app.user_is_admin(p_by) or app.user_va_has(p_by, 'fleet')
          or i.started_by = p_by) then
    raise exception 'Not permitted' using errcode = '42501';
  end if;
  if i.state <> 'failed' then
    raise exception 'Only a failed listing intake is retried (this one is %)', i.state using errcode = '23514';
  end if;
  update listing_jobs set status = 'queued', attempts = 0, next_attempt_at = now(), error = null, finished_at = null, locked_at = null
   where intake_id = i.id and status = 'failed';
  update photo_jobs set status = 'queued', attempts = 0, next_attempt_at = now(), error = null, finished_at = null
   where id in (select photo_job_id from listing_jobs where intake_id = i.id and status = 'queued');
  update vehicle_photos set background_status = 'pending'
   where id in (select vehicle_photo_id from listing_jobs where intake_id = i.id and status = 'queued' and kind = 'process_photo')
     and background_status = 'failed';
  update listing_intakes set retries = retries + 1, reason = null, failed_at = null, state = 'processing_photos' where id = i.id;
  return jsonb_build_object('intake_id', i.id, 'state', app.advance_listing_intake(i.id), 'retries', i.retries + 1);
end $$;

-- ---------------------------------------------------------------- review
-- The reviewer (an Admin, or a customer service or fleet assistant) edits and decides.
-- p: {listing: {headline, description, features, faq, seo_title, seo_description, home_area,
--     staff_note, slug, is_featured, canonical_vehicle_id, channels, luggage},
--     specs: {...as app.confirm_vehicle_specs...},
--     photos: [{photo_id, decision: approve | reject | use_original, alt_text, sort_order, cover}],
--     publish: true}
-- Approving approves every processed current photo not rejected. Sending back needs a note and
-- returns the intake to "started" for the retakes or details asked for.
create or replace function app.review_listing(p_by uuid, p_intake uuid, p_approve boolean, p jsonb default '{}'::jsonb,
                                              p_note text default null)
returns jsonb language plpgsql security definer set search_path = public, app as $$
declare
  i listing_intakes;
  l vehicle_listings;
  e jsonb;
  v_problems text[];
  v_cover uuid;
begin
  p := coalesce(p, '{}'::jsonb);
  select * into i from listing_intakes where id = p_intake for update;
  if i.id is null then raise exception 'Listing intake not found' using errcode = 'P0002'; end if;
  if not app.user_may_list(p_by, i.vehicle_id, 'review') then
    raise exception 'Only an Admin or a customer service or fleet assistant reviews a listing' using errcode = '42501';
  end if;
  if i.state not in ('needs_review', 'approved') then
    raise exception 'This listing is not waiting for review (it is %)', i.state using errcode = '23514';
  end if;
  if p ? 'specs' then perform app.confirm_vehicle_specs(p_by, i.vehicle_id, p -> 'specs'); end if;
  if p ? 'listing' then
    e := p -> 'listing';
    if (e ? 'is_featured' or e ? 'canonical_vehicle_id') and not app.user_is_admin(p_by) and not app.user_va_has(p_by, 'fleet') then
      raise exception 'Only an Admin or Fleet features a car or sets its canonical twin' using errcode = '42501';
    end if;
    update vehicle_listings set
      headline = case when e ? 'headline' then nullif(btrim(e ->> 'headline'), '') else headline end,
      description = case when e ? 'description' then nullif(btrim(e ->> 'description'), '') else description end,
      features = case when e ? 'features' then coalesce((select array_agg(btrim(x)) from jsonb_array_elements_text(e -> 'features') x where btrim(x) <> ''), '{}') else features end,
      faq = case when e ? 'faq' then coalesce(e -> 'faq', '[]'::jsonb) else faq end,
      seo_title = case when e ? 'seo_title' then nullif(btrim(e ->> 'seo_title'), '') else seo_title end,
      seo_description = case when e ? 'seo_description' then nullif(btrim(e ->> 'seo_description'), '') else seo_description end,
      home_area = coalesce(nullif(btrim(e ->> 'home_area'), ''), home_area),
      staff_note = case when e ? 'staff_note' then nullif(btrim(e ->> 'staff_note'), '') else staff_note end,
      slug = case when e ? 'slug' then nullif(app.slugify(e ->> 'slug'), '') else slug end,
      is_featured = coalesce((e ->> 'is_featured')::boolean, is_featured),
      canonical_vehicle_id = case when e ? 'canonical_vehicle_id' then nullif(e ->> 'canonical_vehicle_id', '')::uuid else canonical_vehicle_id end,
      channels = case when e ? 'channels' then array(select jsonb_array_elements_text(e -> 'channels')) else channels end,
      luggage = case when e ? 'luggage' then nullif(btrim(e ->> 'luggage'), '') else luggage end
     where vehicle_id = i.vehicle_id;
  end if;
  for e in select value from jsonb_array_elements(coalesce(p -> 'photos', '[]'::jsonb)) loop
    update vehicle_photos ph set
      status = case e ->> 'decision' when 'reject' then 'rejected' when 'approve' then case when ph.processed_path is not null then 'approved' else ph.status end
                                     when 'use_original' then 'approved' else ph.status end,
      processed_path = case when e ->> 'decision' = 'use_original' then ph.original_path else ph.processed_path end,
      background_status = case when e ->> 'decision' = 'use_original' then 'original_used' else ph.background_status end,
      approved_by = case when e ->> 'decision' in ('approve', 'use_original') then p_by else ph.approved_by end,
      approved_at = case when e ->> 'decision' in ('approve', 'use_original') then now() else ph.approved_at end,
      is_public = case when e ->> 'decision' = 'reject' then false else ph.is_public end,
      alt_text = coalesce(nullif(btrim(e ->> 'alt_text'), ''), ph.alt_text, app.photo_alt_text(ph.vehicle_id, ph.shot_type)),
      sort_order = coalesce((e ->> 'sort_order')::integer, ph.sort_order)
     where ph.id = (e ->> 'photo_id')::uuid and ph.vehicle_id = i.vehicle_id;
    if coalesce((e ->> 'cover')::boolean, false) then v_cover := (e ->> 'photo_id')::uuid; end if;
  end loop;
  if v_cover is not null then
    update vehicle_photos set is_cover = (id = v_cover) where vehicle_id = i.vehicle_id and replaced_at is null;
  end if;

  if not p_approve then
    if nullif(btrim(p_note), '') is null then
      raise exception 'Say what needs to change' using errcode = '22023';
    end if;
    update listing_intakes set state = 'started', submitted_at = null, reason = 'Changes requested: ' || btrim(p_note),
           reviewed_by = p_by, reviewed_at = now()
     where id = i.id;
    update tasks set status = 'done', completed_at = now(), completed_by = p_by, completion_note = 'changes requested'
     where related_id = i.id and task_type = 'review_listing' and status in ('open', 'in_progress', 'waiting');
    return jsonb_build_object('intake_id', i.id, 'state', 'started');
  end if;

  -- every processed current photo the reviewer did not reject goes public as its shot allows
  update vehicle_photos ph set status = 'approved', approved_by = coalesce(ph.approved_by, p_by), approved_at = coalesce(ph.approved_at, now()),
         is_public = st.is_public
    from listing_shot_types st
   where st.code = ph.shot_type and ph.vehicle_id = i.vehicle_id and ph.replaced_at is null
     and ph.status in ('processed', 'approved') and ph.processed_path is not null;
  select * into l from vehicle_listings where vehicle_id = i.vehicle_id;
  v_problems := app.listing_copy_problems(l.headline, l.description, l.features, l.faq);
  if cardinality(v_problems) > 0 then
    raise exception 'The copy needs work: %', array_to_string(v_problems, '; ') using errcode = '23514';
  end if;
  update vehicle_listings set needs_rewrite = false where id = l.id;
  update listing_intakes set state = 'approved', reviewed_by = p_by, reviewed_at = now(), approved_by = p_by, approved_at = now(),
         reason = null
   where id = i.id;
  update tasks set status = 'done', completed_at = now(), completed_by = p_by
   where related_id = i.id and task_type = 'review_listing' and status in ('open', 'in_progress', 'waiting');
  if coalesce((p ->> 'publish')::boolean, true) then
    return app.publish_listing(i.vehicle_id, p_by) || jsonb_build_object('intake_id', i.id);
  end if;
  return jsonb_build_object('intake_id', i.id, 'state', 'approved');
end $$;

-- ---------------------------------------------------------------- publish and unlist
-- Put the car on the website. Refuses, naming the first thing missing: the vehicle's status,
-- Turo-Only, the rates, the specifications, the photos, the copy. Who may publish: an Admin or
-- a customer service or fleet assistant; anyone whose role is in
-- program_settings.listing_review_required_roles only through an approved intake. p_by null is
-- the system (an approved intake publishing itself).
create or replace function app.publish_listing(p_vehicle uuid, p_by uuid) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  v vehicles;
  l vehicle_listings;
  i listing_intakes;
  ps program_settings := app.settings();
  v_role text := app.acting_role(p_by);
  v_problems text[];
  v_slug text;
  v_first boolean;
begin
  select * into v from vehicles where id = p_vehicle for update;
  if v.id is null then raise exception 'Vehicle not found' using errcode = 'P0002'; end if;
  perform app.ensure_listing(p_vehicle);
  select * into l from vehicle_listings where vehicle_id = p_vehicle for update;
  select * into i from listing_intakes where vehicle_id = p_vehicle and state not in ('published', 'cancelled') order by created_at desc limit 1;

  if p_by is null then
    if i.id is null or i.state <> 'approved' then
      raise exception 'Cannot publish: nobody approved this listing' using errcode = '42501';
    end if;
  else
    if app.user_owns_vehicle(p_by, p_vehicle) and not app.user_is_admin(p_by) and not app.user_va_has(p_by) then v_role := 'owner'; end if;
    if v_role is null or (v_role = 'va' and not app.user_va_has(p_by, 'cs', 'fleet'))
       or (v_role = 'owner' and not app.user_owns_vehicle(p_by, p_vehicle))
       or (v_role = 'field' and not app.user_field_has_job(p_by, p_vehicle)) then
      raise exception 'Not permitted to publish this listing' using errcode = '42501';
    end if;
    if v_role = any (ps.listing_review_required_roles) and (i.id is null or i.state <> 'approved') then
      raise exception 'Cannot publish: a % listing is published after a CarmaCars review', v_role using errcode = '42501';
    end if;
  end if;

  if v.status not in ('ready_to_list', 'available', 'on_rent', 'cleaning') then
    raise exception 'Cannot publish: the vehicle is not enrolled yet (status %)', v.status using errcode = '23514';
  end if;
  if v.management_mode = 'turo_only' then
    raise exception 'Cannot publish: a Turo-Only vehicle is not listed on the CarmaCars website' using errcode = '23514';
  end if;
  if not exists (select 1 from rate_cards rc where rc.vehicle_id = v.id and rc.effective_from <= now()
                   and (rc.effective_to is null or rc.effective_to > now())) then
    raise exception 'Cannot publish: no rates are set' using errcode = '23514';
  end if;
  v_problems := app.listing_spec_problems(v.id);
  if cardinality(v_problems) > 0 then
    raise exception 'Cannot publish: details missing: %', array_to_string(v_problems, ', ') using errcode = '23514';
  end if;
  v_problems := app.listing_photo_problems(v.id);
  if cardinality(v_problems) > 0 then
    raise exception 'Cannot publish: photos: %', array_to_string(v_problems, '; ') using errcode = '23514';
  end if;
  v_problems := app.listing_copy_problems(l.headline, l.description, l.features, l.faq);
  if cardinality(v_problems) > 0 then
    raise exception 'Cannot publish: copy: %', array_to_string(v_problems, '; ') using errcode = '23514';
  end if;
  if l.canonical_vehicle_id is not null and not exists (
       select 1 from vehicle_listings c where c.vehicle_id = l.canonical_vehicle_id and c.status in ('published', 'paused') and c.canonical_vehicle_id is null) then
    raise exception 'Cannot publish: the canonical twin is not a live listing' using errcode = '23514';
  end if;

  v_slug := coalesce(l.slug, app.listing_slug(v.id));
  v_first := l.first_published_at is null;
  update vehicle_listings
     set slug = v_slug, status = 'published', published_at = now(), first_published_at = coalesce(first_published_at, now()),
         published_by = p_by, unpublished_at = null, unpublished_reason = null, redirect_to = null, needs_rewrite = false,
         channels = case when 'website' = any (channels) then channels else channels || 'website'::text end
   where id = l.id;
  -- the same address comes back when a car returns: its redirect goes
  delete from listing_redirects where from_path = '/cars/' || v_slug;
  update vehicle_photos set is_public = st.is_public
    from listing_shot_types st
   where st.code = vehicle_photos.shot_type and vehicle_photos.vehicle_id = v.id and vehicle_photos.replaced_at is null
     and vehicle_photos.status = 'approved';
  if v.status = 'ready_to_list' then
    update vehicles set status = 'available' where id = v.id;
  end if;
  if i.id is not null then
    update listing_intakes set state = 'published', published_at = now() where id = i.id;
  end if;
  update tasks set status = 'done', completed_at = now(), completed_by = p_by, completion_note = 'listing published'
   where vehicle_id = v.id and task_type in ('list_vehicle', 'review_listing', 'listing_failed') and status in ('open', 'in_progress', 'waiting');
  perform app.emit_event('owner_vehicle_listed', 'vehicle', v.id,
    jsonb_build_object('owner_id', v.owner_id, 'vehicle_name', app.vehicle_name(v.id), 'listing_path', '/cars/' || v_slug,
                       'first_time', v_first),
    'owner_vehicle_listed:' || v.id || ':' || coalesce(i.id::text, to_char(now(), 'YYYYMMDDHH24MISS')));
  return jsonb_build_object('status', 'published', 'vehicle_id', v.id, 'slug', v_slug, 'path', '/cars/' || v_slug, 'first_time', v_first);
end $$;

-- Take a car off the website, keeping what its address earned (docs/blueprint/14-seo.md
-- section 11): a twin that ranked hands over to the remaining twin; otherwise a 301 to the
-- model hub while other cars of the model are live; otherwise 410. Earlier redirects that
-- pointed here follow, so no redirect is ever two hops.
create or replace function app.unlist_listing(p_vehicle uuid, p_by uuid, p_reason text, p_to_path text default null)
returns jsonb language plpgsql security definer set search_path = public, app as $$
declare
  v vehicles;
  l vehicle_listings;
  v_new uuid;
  v_to text := nullif(btrim(p_to_path), '');
  v_from text;
begin
  if p_by is not null and not (app.user_is_admin(p_by) or app.user_va_has(p_by, 'cs', 'fleet')) then
    raise exception 'Only an Admin or a customer service or fleet assistant takes a car off the website' using errcode = '42501';
  end if;
  select * into v from vehicles where id = p_vehicle;
  select * into l from vehicle_listings where vehicle_id = p_vehicle for update;
  if l.id is null or l.status not in ('published', 'paused') or l.slug is null then
    return jsonb_build_object('status', coalesce(l.status, 'none'), 'changed', false);
  end if;
  v_from := '/cars/' || l.slug;
  update vehicle_listings set status = 'unpublished', unpublished_at = now(), unpublished_reason = nullif(btrim(p_reason), '') where id = l.id;

  -- twins that pointed at this car: the earliest published becomes the canonical one
  select c.vehicle_id into v_new from vehicle_listings c
   where c.canonical_vehicle_id = p_vehicle and c.status in ('published', 'paused')
   order by c.first_published_at nulls last, c.vehicle_id limit 1;
  if v_new is not null then
    update vehicle_listings set canonical_vehicle_id = null where vehicle_id = v_new;
    update vehicle_listings set canonical_vehicle_id = v_new where canonical_vehicle_id = p_vehicle and vehicle_id <> v_new;
  end if;
  if v_to is null then
    v_to := coalesce(
      (select '/cars/' || c.slug from vehicle_listings c where c.vehicle_id = v_new),
      (select '/cars/' || c.slug from vehicle_listings c where c.vehicle_id = l.canonical_vehicle_id and c.status in ('published', 'paused')),
      (select app.model_hub_path(v.make, v.model) where exists (
          select 1 from vehicle_listings o join vehicles ov on ov.id = o.vehicle_id
           where o.status in ('published', 'paused') and o.vehicle_id <> p_vehicle
             and app.slugify(ov.make || ' ' || ov.model) = app.slugify(v.make || ' ' || v.model))));
  end if;
  insert into listing_redirects (from_path, to_path, status_code, reason, vehicle_id, created_by)
  values (v_from, v_to, case when v_to is null then 410 else 301 end, nullif(btrim(p_reason), ''), p_vehicle, p_by)
  on conflict (from_path) do update set to_path = excluded.to_path, status_code = excluded.status_code, reason = excluded.reason,
                                        created_by = excluded.created_by;
  -- single hop: older redirects to this address now go where this one goes
  update listing_redirects set to_path = v_to, status_code = case when v_to is null then 410 else 301 end
   where to_path = v_from;
  delete from listing_redirects where from_path = to_path;
  -- the model hub has no live car left: addresses sent there are gone too
  if not exists (select 1 from vehicle_listings o join vehicles ov on ov.id = o.vehicle_id
                  where o.status in ('published', 'paused') and app.slugify(ov.make || ' ' || ov.model) = app.slugify(v.make || ' ' || v.model)) then
    update listing_redirects set to_path = null, status_code = 410 where to_path = app.model_hub_path(v.make, v.model);
  end if;
  update vehicle_listings set redirect_to = v_to where id = l.id;
  return jsonb_build_object('status', 'unpublished', 'changed', true, 'from_path', v_from, 'to_path', v_to,
                            'status_code', case when v_to is null then 410 else 301 end, 'new_canonical_vehicle_id', v_new);
end $$;

-- ---------------------------------------------------------------- what the public website reads
-- Anonymous reads. Never a VIN, plate, fleet number, owner, staff, cost, draft or private field.
-- Prices come from the public listings view (0012) and the current rate card; availability and
-- quotes stay with 0019's public_vehicle_calendar, quote_booking and search_available, which the
-- page calls with the vehicle_id given here.
create or replace function app.public_listing_photos(p_vehicle uuid) returns jsonb
language sql stable security definer set search_path = public, app as $$
  select coalesce(jsonb_agg(jsonb_build_object('path', ph.processed_path, 'variants', ph.variants, 'alt', ph.alt_text,
                                               'width', ph.width, 'height', ph.height, 'shot', st.code, 'label', st.label,
                                               'is_cover', ph.is_cover)
                            order by ph.is_cover desc, ph.sort_order), '[]'::jsonb)
    from vehicle_photos ph join listing_shot_types st on st.code = ph.shot_type
   where ph.vehicle_id = p_vehicle and ph.replaced_at is null and ph.status = 'approved' and ph.is_public and st.is_public
     and ph.processed_path is not null
$$;

create or replace function app.public_listing_row(p_vehicle uuid) returns jsonb
language sql stable security definer set search_path = public, app as $$
  select jsonb_build_object(
    'vehicle_id', v.id, 'slug', l.slug, 'path', '/cars/' || l.slug,
    'canonical_path', '/cars/' || coalesce((select c.slug from vehicle_listings c where c.vehicle_id = l.canonical_vehicle_id), l.slug),
    'headline', l.headline, 'year', v.year, 'make', v.make, 'model', v.model, 'trim', v.trim, 'colour', v.colour,
    'fuel', v.fuel, 'class', v.class, 'body_style', coalesce(l.body_style, v.body_type), 'seats', l.seats,
    'transmission', l.transmission, 'doors', l.doors, 'drivetrain', l.drivetrain, 'luggage', l.luggage,
    'home_area', l.home_area, 'allows_18_to_20', v.allows_18_to_20, 'is_featured', l.is_featured,
    'taking_requests', l.status = 'published' and pv.vehicle_id is not null,
    'model_hub_path', app.model_hub_path(v.make, v.model),
    'daily_rate_cents', rc.daily_rate_cents, 'weekend_rate_cents', rc.weekend_rate_cents, 'weekly_rate_cents', rc.weekly_rate_cents,
    'monthly_rate_cents', rc.monthly_rate_cents, 'km_allowance_per_day', rc.km_allowance_per_day,
    'overage_cents_per_km', rc.overage_cents_per_km, 'deposit_cents', rc.deposit_cents,
    'delivery_fee_cents', rc.delivery_fee_cents, 'pickup_fee_cents', rc.pickup_fee_cents,
    'cover', (select jsonb_build_object('path', ph.processed_path, 'variants', ph.variants, 'alt', ph.alt_text)
                from vehicle_photos ph where ph.vehicle_id = v.id and ph.is_cover and ph.is_public and ph.status = 'approved'
                 and ph.replaced_at is null limit 1),
    'published_at', l.first_published_at, 'updated_at', l.content_updated_at)
    from vehicle_listings l join vehicles v on v.id = l.vehicle_id
    left join public_vehicle_listings pv on pv.vehicle_id = v.id
    left join rate_cards rc on rc.vehicle_id = v.id and rc.effective_from <= now() and (rc.effective_to is null or rc.effective_to > now())
   where l.vehicle_id = p_vehicle and l.status in ('published', 'paused') and v.management_mode <> 'turo_only'
$$;

-- The car page: the listing, or {redirect, status_code} for an address that moved or is gone,
-- or null.
create or replace function app.public_car_page(p_slug text) returns jsonb
language sql stable security definer set search_path = public, app as $$
  select coalesce(
    (select app.public_listing_row(l.vehicle_id) || jsonb_build_object(
              'description', l.description, 'features', to_jsonb(l.features),
              'faq', coalesce((select jsonb_agg(jsonb_build_object('question', e ->> 'question', 'answer', e ->> 'answer'))
                                 from jsonb_array_elements(l.faq) e), '[]'::jsonb),
              'specs', l.specs - array['vin', 'plate', 'owner', 'fleet_number'], 'staff_note', l.staff_note,
              'seo_title', l.seo_title, 'seo_description', l.seo_description,
              'indexable', l.canonical_vehicle_id is null, 'photos', app.public_listing_photos(l.vehicle_id))
       from vehicle_listings l join vehicles v on v.id = l.vehicle_id
      where l.slug = lower(btrim(p_slug)) and l.status in ('published', 'paused') and v.management_mode <> 'turo_only'),
    (select jsonb_build_object('redirect', r.to_path, 'status_code', r.status_code)
       from listing_redirects r where r.from_path = '/cars/' || lower(btrim(p_slug))))
$$;

-- Any old path: where it goes now. Null when nothing is stored.
create or replace function app.resolve_listing_path(p_path text) returns jsonb
language sql stable security definer set search_path = public, app as $$
  select jsonb_build_object('to_path', r.to_path, 'status_code', r.status_code)
    from listing_redirects r where r.from_path = lower(rtrim(btrim(p_path), '/'))
$$;

-- The fleet: one row per live car (twins included), featured first then cheapest. No totals.
-- Filters: class, make, model, fuel, body_style, featured.
create or replace function app.public_fleet(p_filters jsonb default '{}'::jsonb) returns setof jsonb
language sql stable security definer set search_path = public, app as $$
  select r from (
    select app.public_listing_row(l.vehicle_id) r, l.is_featured, l.first_published_at
      from vehicle_listings l join vehicles v on v.id = l.vehicle_id
     where l.status = 'published' and v.management_mode <> 'turo_only'
       and (p_filters ->> 'class' is null or v.class::text = p_filters ->> 'class')
       and (p_filters ->> 'make' is null or app.slugify(v.make) = app.slugify(p_filters ->> 'make'))
       and (p_filters ->> 'model' is null or app.slugify(v.model) = app.slugify(p_filters ->> 'model'))
       and (p_filters ->> 'fuel' is null or v.fuel::text = p_filters ->> 'fuel')
       and (p_filters ->> 'body_style' is null or lower(coalesce(l.body_style, v.body_type)) = lower(p_filters ->> 'body_style'))
       and (not coalesce((p_filters ->> 'featured')::boolean, false) or l.is_featured)) q
   where r is not null
   order by q.is_featured desc, (r ->> 'daily_rate_cents')::bigint nulls last, q.first_published_at
$$;

-- Model hubs with at least one live car.
create or replace function app.public_model_hubs() returns setof jsonb
language sql stable security definer set search_path = public, app as $$
  select h from (
    select jsonb_build_object('make', min(v.make), 'model', min(v.model), 'path', app.model_hub_path(min(v.make), min(v.model)),
                              'min_daily_rate_cents', min(rc.daily_rate_cents), 'updated_at', max(l.content_updated_at)) h,
           min(v.make) mk, min(v.model) md
      from vehicle_listings l join vehicles v on v.id = l.vehicle_id
      left join rate_cards rc on rc.vehicle_id = v.id and rc.effective_from <= now() and (rc.effective_to is null or rc.effective_to > now())
     where l.status = 'published' and v.management_mode <> 'turo_only'
     group by app.slugify(v.make || ' ' || v.model)) q
   order by q.mk, q.md
$$;

-- One model hub by its path segment ("toyota-corolla"): every live unit. Null with no car.
create or replace function app.public_model_hub(p_hub text) returns jsonb
language sql stable security definer set search_path = public, app as $$
  select case when count(*) = 0 then null else
    jsonb_build_object('make', min(v.make), 'model', min(v.model), 'path', '/rent/' || lower(btrim(p_hub)),
                       'min_daily_rate_cents', min((app.public_listing_row(l.vehicle_id) ->> 'daily_rate_cents')::bigint),
                       'cars', jsonb_agg(app.public_listing_row(l.vehicle_id) order by l.first_published_at)) end
    from vehicle_listings l join vehicles v on v.id = l.vehicle_id
   where l.status = 'published' and v.management_mode <> 'turo_only'
     and app.slugify(v.make || ' ' || v.model) = lower(btrim(p_hub))
$$;

create or replace function app.public_vehicle_photos(p_slug text) returns jsonb
language sql stable security definer set search_path = public, app as $$
  select app.public_listing_photos(l.vehicle_id)
    from vehicle_listings l join vehicles v on v.id = l.vehicle_id
   where l.slug = lower(btrim(p_slug)) and l.status in ('published', 'paused') and v.management_mode <> 'turo_only'
$$;

-- Sitemap rows: canonical car pages (twins left out) and model hubs, with a lastmod that moves
-- only with content, photos or rates.
create or replace function app.public_sitemap() returns table (path text, kind text, lastmod timestamptz)
language sql stable security definer set search_path = public, app as $$
  with cars as (
    select l.slug, v.make, v.model, l.canonical_vehicle_id,
           greatest(l.content_updated_at,
                    (select max(ph.approved_at) from vehicle_photos ph where ph.vehicle_id = v.id and ph.is_public and ph.status = 'approved' and ph.replaced_at is null),
                    (select max(rc.created_at) from rate_cards rc where rc.vehicle_id = v.id and rc.effective_from <= now())) as lastmod
      from vehicle_listings l join vehicles v on v.id = l.vehicle_id
     where l.status in ('published', 'paused') and v.management_mode <> 'turo_only' and l.slug is not null)
  select '/cars/' || slug, 'car', lastmod from cars where canonical_vehicle_id is null
  union all
  select app.model_hub_path(min(make), min(model)), 'model_hub', max(lastmod) from cars group by app.slugify(make || ' ' || model)
  order by 2, 1
$$;

-- Cost per car from the provider log (Admin and Finance).
create or replace function app.listing_cost_report(p_by uuid, p_from date default null, p_to date default null)
returns table (vehicle_id uuid, vehicle_name text, calls bigint, failed_calls bigint, cost_microusd bigint)
language plpgsql stable security definer set search_path = public, app as $$
begin
  if not (app.user_is_admin(p_by) or app.user_va_has(p_by, 'finance')) then
    raise exception 'Not permitted' using errcode = '42501';
  end if;
  return query
    select c.vehicle_id, app.vehicle_name(c.vehicle_id), count(*), count(*) filter (where not c.ok), sum(c.cost_microusd)::bigint
      from provider_calls c
     where (p_from is null or c.created_at >= app.local_midnight(p_from)) and (p_to is null or c.created_at < app.local_midnight(p_to + 1))
     group by c.vehicle_id order by 5 desc;
end $$;

-- ================================================================ PART C
-- ---------------------------------------------------------------- site settings (one row)
-- Everything the public website shows about the business, edited in Admin > Settings. Covers
-- prototype/tools/src/site.mjs and the "Admin-editable content" table of prototype/DESIGN.md.
-- The legal company name lives in program_settings.company_legal_name (it goes on invoices and
-- registry forms) and is never returned to the public site: legal_name_displayed can only be
-- false. Every change is in audit_log with the row before and after (the version history).
create table site_settings (
  id                   uuid primary key default gen_random_uuid(),
  singleton            boolean not null default true unique check (singleton),
  brand_name           text not null,
  site_url             text not null check (site_url ~ '^https://'),
  tagline              text,
  logo_light_file_key  text,                 -- logo for light backgrounds; null shows the text wordmark
  logo_dark_file_key   text,                 -- logo for dark backgrounds
  logo_width           integer check (logo_width > 0),
  logo_height          integer check (logo_height > 0),
  logo_alt             text,
  wordmark_text        text not null,        -- the text wordmark used when no logo file is set
  favicon_file_key     text,
  og_image_file_key    text,                 -- default social sharing image
  city                 text,
  region               text,
  service_area         text,                 -- copy and structured data (areaServed)
  delivery_area_text   text,                 -- null: "confirmed with your booking"
  delivery_areas       jsonb not null default '[]'::jsonb check (jsonb_typeof(delivery_areas) = 'array'),   -- [{"area": "Toronto", "fee_cents": 5000 or null}]
  airport_delivery     boolean,              -- null: not decided
  phone                text,
  whatsapp             text,
  roadside_phone       text,                 -- the 24-hour line
  public_email         text,
  owners_email         text,
  mailing_address      text,                 -- required in marketing emails
  street_address       text,
  show_street_address  boolean not null default false,   -- service-area business until a storefront is confirmed
  opening_hours_text   text,                 -- "Every day, 9 a.m. to 6 p.m." (the task clock uses program_settings.opening_hours)
  handover_slots       text[] not null default '{}',     -- "09:00", "09:30" ...: times offered for a handover
  social_links         jsonb not null default '{}'::jsonb check (jsonb_typeof(social_links) = 'object'),
  review_source        text,
  reply_wording        text,
  seo_default_title    text,
  seo_title_suffix     text,
  seo_default_description text,
  legal_name_displayed boolean not null default false check (not legal_name_displayed),
  updated_by           uuid references users (id),
  created_at           timestamptz not null default now(),
  updated_at           timestamptz not null default now()
);
comment on table site_settings is 'Public website settings (Admin > Settings). One row. The legal company name is not here and is never public.';

create or replace function app.site_settings_before_write() returns trigger
language plpgsql security definer set search_path = public, app as $$
begin
  if exists (select 1 from jsonb_array_elements(new.delivery_areas) e
              where jsonb_typeof(e.value) <> 'object' or nullif(btrim(e.value ->> 'area'), '') is null
                 or (e.value ? 'fee_cents' and jsonb_typeof(e.value -> 'fee_cents') <> 'null'
                     and (jsonb_typeof(e.value -> 'fee_cents') <> 'number' or (e.value ->> 'fee_cents')::numeric < 0))) then
    raise exception 'Each delivery area needs a name and, if it has a fee, an amount in cents of 0 or more' using errcode = '23514';
  end if;
  if exists (select 1 from unnest(new.handover_slots) t where t !~ '^([01][0-9]|2[0-3]):[0-5][0-9]$') then
    raise exception 'Handover times are written HH:MM, for example 09:30' using errcode = '23514';
  end if;
  new.updated_at := now();
  new.updated_by := coalesce(app.uid(), new.updated_by);
  return new;
end $$;
create trigger site_settings_before_write before insert or update on site_settings
  for each row execute function app.site_settings_before_write();

-- the values of site.mjs today; null means "not confirmed yet" and the page shows its marker
insert into site_settings (brand_name, site_url, tagline, logo_alt, wordmark_text, city, region, service_area, public_email, reply_wording)
values ('CarmaCars', 'https://carmacars.ca', 'What goes around, drives around.', 'CarmaCars', 'CarmaCars', 'Toronto', 'Ontario',
        'Toronto, Ontario', 'info@carmacars.ca', 'We reply as fast as we can during opening hours');

-- Marketing copy that changes without a deploy: headings, paragraphs, FAQs.
create table site_content_blocks (
  id           uuid primary key default gen_random_uuid(),
  block_key    text not null unique check (block_key ~ '^[a-z0-9_.-]+$'),   -- for example "home.hero.heading"
  page         text not null check (page ~ '^[a-z0-9_/-]+$'),
  kind         text not null default 'text' check (kind in ('text', 'rich_text', 'faq', 'list')),
  body         text,
  data         jsonb not null default '{}'::jsonb,     -- FAQ items, list items
  sort_order   integer not null default 0,
  is_published boolean not null default true,
  updated_by   uuid references users (id),
  created_at   timestamptz not null default now(),
  updated_at   timestamptz not null default now(),
  check (body is not null or data <> '{}'::jsonb)
);
create index site_content_blocks_page_idx on site_content_blocks (page, sort_order);

create or replace function app.content_block_before_write() returns trigger
language plpgsql security definer set search_path = public, app as $$
begin
  new.updated_at := now();
  new.updated_by := coalesce(app.uid(), new.updated_by);
  return new;
end $$;
create trigger site_content_blocks_before_write before insert or update on site_content_blocks
  for each row execute function app.content_block_before_write();

-- What the public website reads. Never the legal company name, never who edited.
create or replace function app.public_site_settings() returns jsonb
language sql stable security definer set search_path = public, app as $$
  select jsonb_build_object(
    'brand_name', s.brand_name, 'site_url', s.site_url, 'tagline', s.tagline,
    'logo', jsonb_build_object('light', s.logo_light_file_key, 'dark', s.logo_dark_file_key, 'width', s.logo_width,
                               'height', s.logo_height, 'alt', s.logo_alt, 'wordmark', s.wordmark_text),
    'favicon', s.favicon_file_key, 'og_image', s.og_image_file_key,
    'city', s.city, 'region', s.region, 'service_area', s.service_area,
    'delivery_area_text', s.delivery_area_text, 'delivery_areas', s.delivery_areas, 'airport_delivery', s.airport_delivery,
    'phone', s.phone, 'whatsapp', s.whatsapp, 'roadside_phone', s.roadside_phone,
    'public_email', s.public_email, 'owners_email', s.owners_email, 'mailing_address', s.mailing_address,
    'street_address', case when s.show_street_address then s.street_address end,
    'opening_hours_text', s.opening_hours_text, 'opening_hours', ps.opening_hours, 'handover_slots', to_jsonb(s.handover_slots),
    'social_links', s.social_links, 'review_source', s.review_source, 'reply_wording', s.reply_wording,
    'seo', jsonb_build_object('default_title', s.seo_default_title, 'title_suffix', s.seo_title_suffix,
                              'default_description', s.seo_default_description),
    'hst_number', ps.company_hst_number, 'updated_at', s.updated_at)
    from site_settings s cross join app.settings() ps
   where s.singleton
$$;

create or replace function app.public_site_content(p_page text default null) returns jsonb
language sql stable security definer set search_path = public, app as $$
  select coalesce(jsonb_agg(jsonb_build_object('key', b.block_key, 'page', b.page, 'kind', b.kind, 'body', b.body, 'data', b.data)
                            order by b.page, b.sort_order, b.block_key), '[]'::jsonb)
    from site_content_blocks b
   where b.is_published and (p_page is null or b.page = p_page)
$$;

-- ---------------------------------------------------------------- task rules for the work raised here (0020's table, editable)
insert into task_rules (task_type, queue, title, priority, due_kind, due_amount, procedure_no, completion_rule, description) values
  ('owner_lead',            'sales', 'New owner program enquiry',                  'normal', 'business_days', 1, 12, null, 'Reply in 1 business day'),
  ('enquiry',               'cs',    'New enquiry from the website',               'normal', 'business_days', 1, null, null, 'Reply in 1 business day'),
  ('onboarding_disclosure', 'admin', 'Owner disclosed a recall or damage',          'high',   'business_days', 1, 12, null, 'Read the details before terms are set'),
  ('approve_vehicle_terms', 'admin', 'Vehicle terms off the standard grid',         'high',   'business_days', 1, 12, null, 'Only an Admin approves terms off the grid'),
  ('verify_payout_account', 'admin', 'Verify new owner payout details',             'high',   'business_days', 1, 14, null, 'Confirm by phone on the number on file before use'),
  ('review_listing',        'cs',    'Review a listing',                            'normal', 'business_days', 1, 17, null, 'Live in 2 business days'),
  ('listing_failed',        'fleet', 'A listing step failed',                       'high',   'business_days', 1, 17, null, 'Retry, use the original photo, or ask for a retake')
on conflict (task_type) do nothing;

-- ---------------------------------------------------------------- the onboarding checklist
-- The items each vehicle's onboarding goes through, with who it waits on and the next action
-- in plain words. The labels, wording, order and who it waits on are an Admin's to edit; the
-- code says how the item is worked out from the records.
create table onboarding_checklist_items (
  code          text primary key check (code in ('owner_details', 'documents', 'government_forms', 'signatures', 'upfront_payment',
                                                 'tracker_install', 'registry_visit', 'insurer_confirmation', 'photos', 'listing')),
  label         text not null,
  sort_order    integer not null,
  waits_on      text not null check (waits_on in ('owner', 'carmacars', 'third_party')),
  owner_action  text,          -- shown to the owner while the item is open
  staff_action  text,          -- shown to staff while the item is open
  is_active     boolean not null default true,
  updated_at    timestamptz not null default now()
);
create trigger onboarding_checklist_items_updated before update on onboarding_checklist_items for each row execute function app.set_updated_at();
insert into onboarding_checklist_items (code, label, sort_order, waits_on, owner_action, staff_action) values
  ('owner_details', 'Your details', 1, 'owner', 'Complete your details', 'Ask the owner for the missing details'),
  ('documents', 'Ownership permit', 2, 'owner', 'Upload a photo of both sides of the ownership permit', 'Check the ownership permit'),
  ('government_forms', 'Registry forms', 3, 'carmacars', 'Print and sign the pre-filled forms', 'Pre-fill the registry forms'),
  ('signatures', 'Agreements signed', 4, 'owner', 'Sign your agreements', 'Send the agreements for signature'),
  ('upfront_payment', 'Upfront payment', 5, 'owner', 'Pay the Install Fee and the first and last month''s Insurance Fee', 'Collect the upfront invoice'),
  ('registry_visit', 'Registry visit', 6, 'carmacars', 'Confirm the registry visit time', 'Book the registry visit'),
  ('tracker_install', 'Tracker installed', 7, 'carmacars', null, 'Install and test the Tracker'),
  ('insurer_confirmation', 'Insurer confirmation', 8, 'carmacars', 'Keep your own insurance until we confirm in writing', 'Add the vehicle to the fleet policy'),
  ('photos', 'Listing photos', 9, 'carmacars', null, 'Shoot and process the listing photos'),
  ('listing', 'Listed on the website', 10, 'carmacars', null, 'Review and publish the listing');

alter table vehicle_onboardings
  add column checklist_marks jsonb not null default '{}'::jsonb check (jsonb_typeof(checklist_marks) = 'object');   -- {code: {status, by, at, note}} set by staff

-- The checklist for one vehicle: status (done, open, not_applicable), who it waits on now, and
-- the next action. A staff mark (app.mark_onboarding_item) overrides what the records say.
create or replace function app.onboarding_checklist(p_vehicle uuid)
returns table (code text, label text, sort_order integer, status text, waits_on text, next_action text, owner_action text, staff_action text)
language plpgsql stable security definer set search_path = public, app as $$
declare
  v vehicles;
  ob vehicle_onboardings;
  v_missing text[];
  v_forms text[];
  v_signed boolean;
  r onboarding_checklist_items;
  v_status text;
  v_wait text;
  v_next text;
  v_turo boolean;
begin
  select * into v from vehicles where id = p_vehicle;
  select * into ob from vehicle_onboardings where vehicle_id = p_vehicle;
  if v.id is null or ob.id is null then return; end if;
  v_turo := v.management_mode = 'turo_only';
  v_missing := app.owner_missing_fields(v.owner_id);
  v_signed := ob.status in ('documents_signed', 'upfront_paid', 'registry_booked', 'registered', 'tracker_installed', 'on_fleet_policy', 'enrolled');
  for r in select * from onboarding_checklist_items i where i.is_active order by i.sort_order loop
    v_wait := r.waits_on; v_next := null;
    if r.code = 'owner_details' then
      v_status := case when cardinality(v_missing) = 0 then 'done' else 'open' end;
      if v_status = 'open' then v_next := r.owner_action || ': ' || array_to_string(v_missing, ', '); end if;
    elsif r.code = 'documents' then
      v_status := case when exists (select 1 from documents d where d.vehicle_id = v.id and d.kind = 'ownership_permit' and d.purged_at is null)
                       then 'done' else 'open' end;
    elsif r.code = 'government_forms' then
      v_forms := ob.government_forms;
      if v_turo or cardinality(v_forms) = 0 then
        v_status := 'not_applicable';
      elsif not exists (select 1 from unnest(v_forms) f
                         where not exists (select 1 from government_form_fills g where g.vehicle_id = v.id and g.form_code = f
                                              and g.superseded_at is null and g.status <> 'draft')) then
        v_status := 'done';
      else
        v_status := 'open';
        if exists (select 1 from government_form_fills g where g.vehicle_id = v.id and g.superseded_at is null and g.status = 'draft') then
          v_wait := 'owner';
          v_next := 'Complete the missing values: ' || (select string_agg(distinct m, ', ') from government_form_fills g, unnest(g.missing) m
                                                         where g.vehicle_id = v.id and g.superseded_at is null and g.status = 'draft');
        end if;
      end if;
    elsif r.code = 'signatures' then
      v_status := case when v_signed then 'done' else 'open' end;
      if not v_signed and ob.status in ('intake', 'terms_set') then v_wait := 'carmacars'; v_next := r.staff_action; end if;
    elsif r.code = 'upfront_payment' then
      v_status := case when v.billing_case in ('turo_only', 'shareholder') then 'not_applicable'
                       when ob.upfront_paid_at is not null or exists (select 1 from owner_invoices i where i.id = ob.upfront_invoice_id and i.status = 'paid') then 'done'
                       else 'open' end;
      if v_status = 'open' and ob.upfront_invoice_id is null then v_wait := 'carmacars'; v_next := 'Issue the upfront invoice once the agreements are signed'; end if;
    elsif r.code = 'registry_visit' then
      v_status := case when v_turo then 'not_applicable'
                       when ob.permit_filed_at is not null or ob.status in ('registered', 'tracker_installed', 'on_fleet_policy', 'enrolled') then 'done'
                       else 'open' end;
      if v_status = 'open' and ob.registry_visit_at is not null then
        v_wait := 'owner'; v_next := format('Attend the registry visit on %s', to_char(ob.registry_visit_at at time zone 'America/Toronto', 'YYYY-MM-DD HH24:MI'));
      end if;
    elsif r.code = 'tracker_install' then
      v_status := case when v_turo then 'not_applicable' when ob.tracker_installed_at is not null then 'done' else 'open' end;
    elsif r.code = 'insurer_confirmation' then
      v_status := case when v_turo then case when ob.insurer_permits_turo_confirmed_at is not null then 'done' else 'open' end
                       when ob.on_fleet_policy_at is not null or ob.insurer_confirmation_document_id is not null then 'done' else 'open' end;
      if v_turo and v_status = 'open' then v_wait := 'owner'; v_next := 'Confirm that your insurer permits Turo rentals'; end if;
    elsif r.code = 'photos' then
      v_status := case when v_turo then 'not_applicable' when cardinality(app.listing_photo_problems(v.id)) = 0 then 'done' else 'open' end;
    elsif r.code = 'listing' then
      v_status := case when v_turo then 'not_applicable'
                       when exists (select 1 from vehicle_listings l where l.vehicle_id = v.id and l.status = 'published') then 'done' else 'open' end;
    end if;
    if ob.checklist_marks ? r.code then
      v_status := ob.checklist_marks -> r.code ->> 'status';
    end if;
    if ob.status in ('declined', 'withdrawn') and v_status = 'open' then
      v_status := 'not_applicable';
    end if;
    if v_status = 'open' and v_next is null then
      v_next := case when v_wait = 'owner' then coalesce(r.owner_action, r.staff_action) else coalesce(r.staff_action, r.owner_action) end;
    end if;
    code := r.code; label := r.label; sort_order := r.sort_order; status := v_status;
    waits_on := case when v_status = 'open' then v_wait end; next_action := case when v_status = 'open' then v_next end;
    owner_action := r.owner_action; staff_action := r.staff_action;
    return next;
  end loop;
end $$;

-- Staff record an item done (or not applicable) by hand, with a note; null clears the mark.
create or replace function app.mark_onboarding_item(p_vehicle uuid, p_code text, p_status text, p_by uuid, p_note text default null)
returns void language plpgsql security definer set search_path = public, app as $$
begin
  if not (app.user_is_admin(p_by) or app.user_va_has(p_by, 'cs', 'fleet')) then
    raise exception 'Only an Admin or a customer service or fleet assistant marks an onboarding item' using errcode = '42501';
  end if;
  if not exists (select 1 from onboarding_checklist_items where code = p_code) then
    raise exception 'Unknown checklist item %', p_code using errcode = '22023';
  end if;
  if p_status is not null and p_status not in ('done', 'not_applicable', 'open') then
    raise exception 'An item is marked done, not_applicable or open' using errcode = '22023';
  end if;
  update vehicle_onboardings
     set checklist_marks = case when p_status is null then checklist_marks - p_code
                                else checklist_marks || jsonb_build_object(p_code, jsonb_build_object('status', p_status, 'by', p_by, 'at', now(), 'note', p_note)) end
   where vehicle_id = p_vehicle;
  if not found then raise exception 'This vehicle has no onboarding record' using errcode = 'P0002'; end if;
end $$;

-- ---------------------------------------------------------------- exit notice and completion
alter table vehicle_exits
  add column given_by      uuid references users (id),
  add column withdrawn_by  uuid references users (id),
  add column withdrawn_at  timestamptz,
  add column completed_by  uuid references users (id),
  add column completed_at  timestamptz;

-- The owner (or staff for the owner) gives notice on one vehicle; the owner's other vehicles are
-- not affected. Notice period, free transfer-back months and the re-transfer deadline come from
-- program_settings. The Exit Date is the end of the notice or, if later, the end of a rental in
-- progress then. p: {reason, return_registration_to, notice_received_at, initiated_by (staff only)}.
create or replace function app.give_exit_notice(p_vehicle uuid, p_by uuid, p jsonb default '{}'::jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  v vehicles;
  o owners;
  ps program_settings := app.settings();
  v_staff boolean := app.user_is_admin(p_by) or app.user_va_has(p_by, 'cs', 'fleet');
  v_received timestamptz := coalesce(nullif(p ->> 'notice_received_at', '')::timestamptz, now());
  v_notice_ends date;
  v_exit date;
  v_months integer;
  v_payer text;
  v_id uuid;
begin
  p := coalesce(p, '{}'::jsonb);
  select * into v from vehicles where id = p_vehicle for update;
  if v.id is null then raise exception 'Vehicle not found' using errcode = 'P0002'; end if;
  if not v_staff and not app.user_owns_vehicle(p_by, p_vehicle) then
    raise exception 'Not permitted: an owner gives notice only on their own vehicle' using errcode = '42501';
  end if;
  if v.status = 'onboarding' then
    raise exception 'This vehicle is still being onboarded: withdraw it instead of giving notice' using errcode = '23514';
  end if;
  if v.status not in ('ready_to_list', 'available', 'on_rent', 'cleaning', 'out_of_service') then
    raise exception 'Notice cannot be given on a vehicle that is %', v.status using errcode = '23514';
  end if;
  ps := app.settings(app.local_date(v_received));
  v_notice_ends := app.local_date(v_received) + ps.notice_period_days;
  select greatest(v_notice_ends, max(app.local_date(b.return_at))) into v_exit
    from bookings b
   where b.vehicle_id = v.id and b.status in ('confirmed', 'on_rent')
     and b.pickup_at < app.local_midnight(v_notice_ends + 1) and b.return_at > app.local_midnight(v_notice_ends);
  v_exit := coalesce(v_exit, v_notice_ends);
  v_months := case when v.fleet_policy_added_on is null then 0
                   else (extract(year from age(v_exit, v.fleet_policy_added_on)) * 12 + extract(month from age(v_exit, v.fleet_policy_added_on)))::integer end;
  v_payer := public.calc_retransfer_payer(v_months, false, false, false, ps.free_retransfer_months);

  insert into vehicle_exits (vehicle_id, initiated_by, reason, notice_received_at, notice_ends_on, exit_date, months_on_fleet_policy,
                             retransfer_fees_paid_by, retransfer_due_on, retransferred_to, given_by)
  values (v.id, case when v_staff and nullif(p ->> 'initiated_by', '') is not null then p ->> 'initiated_by' else 'owner' end,
          nullif(btrim(p ->> 'reason'), ''), v_received, v_notice_ends, v_exit, v_months, v_payer,
          app.add_business_days(v_exit, ps.retransfer_business_days), nullif(btrim(p ->> 'return_registration_to'), ''), p_by)
  returning id into v_id;
  update vehicles set status = 'exit_notice', exit_date = v_exit where id = v.id;
  insert into vehicle_calendar_blocks (vehicle_id, reason, starts_at, ends_at, note, created_by)
  values (v.id, 'exit', app.local_midnight(v_exit), null, 'Exit Date', p_by);

  select * into o from owners where id = v.owner_id;
  perform app.emit_event('owner_exit_notice_received', 'vehicle_exit', v_id,
    jsonb_build_object('owner_id', o.id, 'first_name', coalesce(o.first_name, split_part(o.legal_name, ' ', 1)), 'vehicle_id', v.id,
                       'vehicle_name', app.vehicle_name(v.id), 'exit_date', v_exit, 'notice_ends_on', v_notice_ends,
                       'retransfer_fees_paid_by', v_payer),
    'owner_exit_notice_received:' || v_id || ':notice');
  perform app.emit_event('staff_exit_notice_received', 'vehicle_exit', v_id,
    jsonb_build_object('owner_id', o.id, 'owner_name', o.legal_name, 'vehicle_id', v.id, 'vehicle_name', app.vehicle_name(v.id),
                       'exit_date', v_exit, 'retransfer_fees_paid_by', v_payer),
    'staff_exit_notice_received:' || v_id || ':notice');
  return jsonb_build_object('exit_id', v_id, 'notice_ends_on', v_notice_ends, 'exit_date', v_exit, 'months_on_fleet_policy', v_months,
                            'retransfer_fees_paid_by', v_payer, 'retransfer_due_on', app.add_business_days(v_exit, ps.retransfer_business_days));
end $$;

-- Withdraw a notice before the Exit Date.
create or replace function app.withdraw_exit_notice(p_exit uuid, p_by uuid) returns void
language plpgsql security definer set search_path = public, app as $$
declare
  e vehicle_exits;
begin
  select * into e from vehicle_exits where id = p_exit for update;
  if e.id is null then raise exception 'Exit not found' using errcode = 'P0002'; end if;
  if not (app.user_is_admin(p_by) or app.user_va_has(p_by, 'cs', 'fleet') or app.user_owns_vehicle(p_by, e.vehicle_id)) then
    raise exception 'Not permitted' using errcode = '42501';
  end if;
  if e.status <> 'notice' or app.today() >= e.exit_date then
    raise exception 'A notice is withdrawn only before the Exit Date' using errcode = '23514';
  end if;
  update vehicle_exits set status = 'cancelled', withdrawn_by = p_by, withdrawn_at = now() where id = e.id;
  delete from vehicle_calendar_blocks where vehicle_id = e.vehicle_id and reason = 'exit' and starts_at = app.local_midnight(e.exit_date);
  update vehicles set status = 'available', exit_date = null where id = e.vehicle_id and status = 'exit_notice';
  update tasks set status = 'cancelled', completed_at = now(), completed_by = p_by, completion_note = 'notice withdrawn'
   where related_id = e.id and task_type = 'owner_exit' and status in ('open', 'in_progress', 'waiting');
end $$;

-- Fleet or an Admin completes the exit on or after the Exit Date: the hand-back facts, the
-- vehicle leaves the fleet, its listing comes off the website with its redirect.
-- p: {tracker_removed_at, exit_odometer_km, policy_removed_at, retransferred_to, retransfer_completed_at, retransfer_fees_cents}
create or replace function app.complete_exit(p_exit uuid, p_by uuid, p jsonb default '{}'::jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  e vehicle_exits;
  o owners;
  v_unlist jsonb;
begin
  p := coalesce(p, '{}'::jsonb);
  if not (app.user_is_admin(p_by) or app.user_va_has(p_by, 'fleet')) then
    raise exception 'Only an Admin or Fleet completes an exit' using errcode = '42501';
  end if;
  select * into e from vehicle_exits where id = p_exit for update;
  if e.id is null then raise exception 'Exit not found' using errcode = 'P0002'; end if;
  if e.status <> 'notice' then raise exception 'This exit is already %', e.status using errcode = '23514'; end if;
  if app.today() < e.exit_date then
    raise exception 'The Exit Date is %; complete the exit on or after it', e.exit_date using errcode = '23514';
  end if;
  update vehicle_exits set
    status = case when nullif(p ->> 'retransfer_completed_at', '') is not null then 'retransferred' else 'exited' end,
    tracker_removed_at = coalesce(nullif(p ->> 'tracker_removed_at', '')::timestamptz, tracker_removed_at),
    exit_odometer_km = coalesce(nullif(p ->> 'exit_odometer_km', '')::integer, exit_odometer_km),
    policy_removed_at = coalesce(nullif(p ->> 'policy_removed_at', '')::timestamptz, policy_removed_at),
    retransferred_to = coalesce(nullif(btrim(p ->> 'retransferred_to'), ''), retransferred_to),
    retransfer_completed_at = coalesce(nullif(p ->> 'retransfer_completed_at', '')::timestamptz, retransfer_completed_at),
    retransfer_fees_cents = coalesce(nullif(p ->> 'retransfer_fees_cents', '')::bigint, retransfer_fees_cents),
    completed_by = p_by, completed_at = now()
   where id = e.id;
  update vehicles set status = 'exited', exit_date = e.exit_date where id = e.vehicle_id and status = 'exit_notice';
  v_unlist := app.unlist_listing(e.vehicle_id, null, 'Left the fleet');
  update tasks set status = 'done', completed_at = now(), completed_by = p_by
   where related_id = e.id and task_type = 'owner_exit' and status in ('open', 'in_progress', 'waiting');
  select o2.* into o from owners o2 join vehicles v on v.owner_id = o2.id where v.id = e.vehicle_id;
  perform app.emit_event('owner_exit_completed', 'vehicle_exit', e.id,
    jsonb_build_object('owner_id', o.id, 'first_name', coalesce(o.first_name, split_part(o.legal_name, ' ', 1)), 'vehicle_id', e.vehicle_id,
                       'vehicle_name', app.vehicle_name(e.vehicle_id), 'exit_date', e.exit_date, 'retransfer_fees_paid_by', e.retransfer_fees_paid_by),
    'owner_exit_completed:' || e.id || ':completed');
  return jsonb_build_object('exit_id', e.id, 'status', (select status from vehicle_exits where id = e.id), 'listing', v_unlist);
end $$;

-- ---------------------------------------------------------------- fee changes and schedule changes
-- A Fee changes by written notice (program_settings.fee_change_notice_days; the table check of
-- 0002 keeps 30 days as the floor). A Revenue Share changes only by a new signed Vehicle
-- Schedule. Both are recorded here; the effective terms stay in vehicle_fee_history.
create table vehicle_term_changes (
  id                  uuid primary key default gen_random_uuid(),
  vehicle_id          uuid not null references vehicles (id),
  kind                text not null check (kind in ('fee_notice', 'new_schedule')),
  status              text not null check (status in ('noticed', 'awaiting_signature', 'applied', 'cancelled')),
  insurance_fee_cents bigint not null check (insurance_fee_cents >= 0),
  tracker_fee_cents   bigint not null check (tracker_fee_cents >= 0),
  revenue_share_bps   integer not null check (revenue_share_bps between 0 and 10000),
  previous            jsonb not null,
  notice_sent_on      date,
  effective_from      date not null,
  reason              text,
  fee_history_id      uuid references vehicle_fee_history (id),
  new_schedule_id     uuid references vehicle_schedules (id),
  document_id         uuid references documents (id),
  created_by          uuid references users (id),
  applied_by          uuid references users (id),
  applied_at          timestamptz,
  created_at          timestamptz not null default now()
);
create index vehicle_term_changes_vehicle_idx on vehicle_term_changes (vehicle_id, effective_from);

create or replace function app.give_fee_change_notice(p_vehicle uuid, p_admin uuid, p_insurance_fee_cents bigint, p_tracker_fee_cents bigint,
                                                      p_effective_from date, p_reason text default null, p_notice_on date default null)
returns jsonb language plpgsql security definer set search_path = public, app as $$
declare
  t vehicle_fee_history;
  v_notice date := coalesce(p_notice_on, app.today());
  v_days integer := (app.settings(v_notice)).fee_change_notice_days;
  v_hist uuid;
  v_id uuid;
  v vehicles;
begin
  if not app.user_is_admin(p_admin) then
    raise exception 'Only an Admin changes a vehicle''s Fees' using errcode = '42501';
  end if;
  select * into v from vehicles where id = p_vehicle;
  if v.billing_case in ('turo_only', 'shareholder') then
    raise exception 'A % vehicle has no Fees to change', v.billing_case using errcode = '23514';
  end if;
  t := app.vehicle_terms(p_vehicle, app.today());
  if t.id is null then
    raise exception 'This vehicle has no Fees in force yet: change the terms before enrollment with app.set_vehicle_terms' using errcode = '23514';
  end if;
  if p_effective_from < v_notice + v_days then
    raise exception 'A Fee change needs % days'' written notice: the earliest date is %', v_days, v_notice + v_days using errcode = '23514';
  end if;
  if exists (select 1 from vehicle_fee_history h where h.vehicle_id = p_vehicle and h.effective_from >= p_effective_from) then
    raise exception 'Terms already start on or after %; cancel those first', p_effective_from using errcode = '23514';
  end if;
  update vehicle_fee_history set effective_to = p_effective_from
   where vehicle_id = p_vehicle and effective_to is null and effective_from < p_effective_from;
  insert into vehicle_fee_history (vehicle_id, vehicle_schedule_id, source, insurance_fee_cents, tracker_fee_cents, revenue_share_bps,
                                   effective_from, notice_sent_on, created_by)
  values (p_vehicle, t.vehicle_schedule_id, 'fee_notice', p_insurance_fee_cents, p_tracker_fee_cents, t.revenue_share_bps,
          p_effective_from, v_notice, p_admin)
  returning id into v_hist;
  insert into vehicle_term_changes (vehicle_id, kind, status, insurance_fee_cents, tracker_fee_cents, revenue_share_bps, previous,
                                    notice_sent_on, effective_from, reason, fee_history_id, created_by, applied_by, applied_at)
  values (p_vehicle, 'fee_notice', 'noticed', p_insurance_fee_cents, p_tracker_fee_cents, t.revenue_share_bps,
          jsonb_build_object('insurance_fee_cents', t.insurance_fee_cents, 'tracker_fee_cents', t.tracker_fee_cents, 'revenue_share_bps', t.revenue_share_bps),
          v_notice, p_effective_from, nullif(btrim(p_reason), ''), v_hist, p_admin, p_admin, now())
  returning id into v_id;
  perform app.emit_event('owner_fee_change_notice', 'vehicle_term_change', v_id,
    jsonb_build_object('owner_id', v.owner_id, 'vehicle_id', v.id, 'vehicle_name', app.vehicle_name(v.id), 'effective_from', p_effective_from,
                       'old_insurance_fee_cents', t.insurance_fee_cents, 'new_insurance_fee_cents', p_insurance_fee_cents,
                       'old_tracker_fee_cents', t.tracker_fee_cents, 'new_tracker_fee_cents', p_tracker_fee_cents, 'reason', p_reason),
    'owner_fee_change_notice:' || v_id || ':notice');
  return jsonb_build_object('change_id', v_id, 'fee_history_id', v_hist, 'effective_from', p_effective_from, 'notice_sent_on', v_notice);
end $$;

-- A Revenue Share (or any term) change by a new Vehicle Schedule: proposed by an Admin, in force
-- only once the owner signs it (app.record_schedule_change_signed).
create or replace function app.propose_schedule_change(p_vehicle uuid, p_admin uuid, p_terms jsonb) returns uuid
language plpgsql security definer set search_path = public, app as $$
declare
  s vehicle_schedules;
  v_id uuid;
begin
  if not app.user_is_admin(p_admin) then
    raise exception 'Only an Admin proposes a new Vehicle Schedule' using errcode = '42501';
  end if;
  select * into s from vehicle_schedules where vehicle_id = p_vehicle and superseded_by is null;
  if s.id is null or s.signed_at is null then
    raise exception 'This vehicle has no signed Vehicle Schedule; set its terms with app.set_vehicle_terms' using errcode = '23514';
  end if;
  if nullif(p_terms ->> 'effective_from', '') is null then
    raise exception 'Give the date the new schedule takes effect' using errcode = '22023';
  end if;
  if s.management_mode = 'self_managed' and coalesce((p_terms ->> 'revenue_share_bps')::integer, 0) <> 0 then
    raise exception 'A Self-Managed vehicle has no Revenue Share' using errcode = '23514';
  end if;
  insert into vehicle_term_changes (vehicle_id, kind, status, insurance_fee_cents, tracker_fee_cents, revenue_share_bps, previous,
                                    effective_from, reason, created_by)
  values (p_vehicle, 'new_schedule', 'awaiting_signature',
          coalesce((p_terms ->> 'insurance_fee_cents')::bigint, s.insurance_fee_cents), coalesce((p_terms ->> 'tracker_fee_cents')::bigint, s.tracker_fee_cents),
          coalesce((p_terms ->> 'revenue_share_bps')::integer, s.revenue_share_bps),
          jsonb_build_object('schedule_id', s.id, 'insurance_fee_cents', s.insurance_fee_cents, 'tracker_fee_cents', s.tracker_fee_cents,
                             'revenue_share_bps', s.revenue_share_bps),
          (p_terms ->> 'effective_from')::date, nullif(btrim(p_terms ->> 'reason'), ''), p_admin)
  returning id into v_id;
  return v_id;
end $$;

-- The owner signed the new schedule: it supersedes the old one and its terms run from the date.
create or replace function app.record_schedule_change_signed(p_change uuid, p_admin uuid, p_signed_at timestamptz default now(),
                                                             p_document uuid default null)
returns uuid language plpgsql security definer set search_path = public, app as $$
declare
  c vehicle_term_changes;
  s vehicle_schedules;
  v_new uuid := gen_random_uuid();
  v_hist uuid;
begin
  if not app.user_is_admin(p_admin) then
    raise exception 'Only an Admin records a signed Vehicle Schedule' using errcode = '42501';
  end if;
  select * into c from vehicle_term_changes where id = p_change for update;
  if c.id is null or c.status <> 'awaiting_signature' then
    raise exception 'This change is not waiting for a signature' using errcode = '23514';
  end if;
  select * into s from vehicle_schedules where vehicle_id = c.vehicle_id and superseded_by is null for update;
  if exists (select 1 from vehicle_fee_history h where h.vehicle_id = c.vehicle_id and h.effective_from >= c.effective_from) then
    raise exception 'Terms already start on or after %', c.effective_from using errcode = '23514';
  end if;
  -- the old row steps aside (pointing at itself for a moment) so the new one can be current
  update vehicle_schedules set superseded_by = id where id = s.id;
  insert into vehicle_schedules (id, vehicle_id, owner_agreement_id, title_agreement_id, schedule_number, vehicle_number, is_additional,
      odometer_km, held_by, title_status, finance_party_name, finance_party_account, finance_permission, finance_permission_document_id,
      management_mode, onboarding_method, insurance_fee_cents, tracker_fee_cents, install_fee_cents, revenue_share_bps, enrollment_date,
      special_terms, owners_lien, ppsa_registration_number, onboarding_estimate_cents, document_id, signed_at, created_by)
  values (v_new, s.vehicle_id, s.owner_agreement_id, s.title_agreement_id, 'VS-' || nextval('vehicle_schedule_number_seq'), s.vehicle_number, s.is_additional,
      s.odometer_km, s.held_by, s.title_status, s.finance_party_name, s.finance_party_account, s.finance_permission, s.finance_permission_document_id,
      s.management_mode, s.onboarding_method, c.insurance_fee_cents, c.tracker_fee_cents, s.install_fee_cents, c.revenue_share_bps, s.enrollment_date,
      s.special_terms, s.owners_lien, s.ppsa_registration_number, s.onboarding_estimate_cents, p_document, p_signed_at, p_admin);
  update vehicle_schedules set superseded_by = v_new, superseded_at = now() where id = s.id;
  if exists (select 1 from vehicle_fee_history h where h.vehicle_id = c.vehicle_id) then
    update vehicle_fee_history set effective_to = c.effective_from
     where vehicle_id = c.vehicle_id and effective_to is null and effective_from < c.effective_from;
    insert into vehicle_fee_history (vehicle_id, vehicle_schedule_id, source, insurance_fee_cents, tracker_fee_cents, revenue_share_bps, effective_from, created_by)
    values (c.vehicle_id, v_new, 'signed_schedule', c.insurance_fee_cents, c.tracker_fee_cents, c.revenue_share_bps, c.effective_from, p_admin)
    returning id into v_hist;
  end if;
  update vehicle_term_changes set status = 'applied', new_schedule_id = v_new, fee_history_id = v_hist, document_id = coalesce(p_document, document_id),
         applied_by = p_admin, applied_at = now()
   where id = c.id;
  return v_new;
end $$;

-- ---------------------------------------------------------------- bank and payment method changes
alter table owner_payout_accounts add column account_key_version integer;   -- which application key encrypted account_no

-- New payout details from the owner (or an Admin for the owner). Stored not current and not
-- verified: an Admin verifies them (by phone on the number on file) before any payout uses
-- them. The owner is told at once at the email on file, as a security notice.
-- p: {method, account_holder, institution_no, transit_no, account_no (already encrypted), account_last4, e_transfer_email, key_version}
create or replace function app.submit_payout_account(p_owner uuid, p_by uuid, p jsonb) returns uuid
language plpgsql security definer set search_path = public, app as $$
declare
  o owners;
  v_id uuid;
  v_method text := coalesce(p ->> 'method', 'bank_transfer');
begin
  select * into o from owners where id = p_owner;
  if o.id is null then raise exception 'Owner not found' using errcode = 'P0002'; end if;
  if not (app.user_is_admin(p_by) or app.user_is_owner_of(p_by, p_owner)) then
    raise exception 'Only the owner or an Admin changes payout details' using errcode = '42501';
  end if;
  if v_method = 'bank_transfer' and (coalesce(p ->> 'institution_no', '') !~ '^\d{3}$' or coalesce(p ->> 'transit_no', '') !~ '^\d{5}$'
                                     or coalesce(p ->> 'account_last4', '') !~ '^\d{4}$' or nullif(p ->> 'account_no', '') is null) then
    raise exception 'Enter the 3-digit institution number, the 5-digit transit number and the account number' using errcode = '22023';
  end if;
  if v_method = 'e_transfer' and coalesce(p ->> 'e_transfer_email', '') !~ '^[^@\s]+@[^@\s]+\.[^@\s]+$' then
    raise exception 'Enter the e-Transfer email address' using errcode = '22023';
  end if;
  insert into owner_payout_accounts (owner_id, method, account_holder, institution_no, transit_no, account_no, account_last4,
                                     e_transfer_email, is_current, submitted_by, account_key_version)
  values (p_owner, v_method, coalesce(nullif(btrim(p ->> 'account_holder'), ''), o.legal_name), p ->> 'institution_no', p ->> 'transit_no',
          p ->> 'account_no', p ->> 'account_last4', lower(nullif(btrim(p ->> 'e_transfer_email'), '')), false, p_by,
          nullif(p ->> 'key_version', '')::integer)
  returning id into v_id;
  perform app.raise_task(p_type => 'verify_payout_account', p_title => format('Verify new payout details: %s', o.legal_name),
      p_owner => p_owner, p_related_table => 'owner_payout_accounts', p_related_id => v_id, p_created_by => p_by,
      p_dedupe => 'verify_payout_account:' || v_id);
  perform app.emit_event('owner_bank_details_changed', 'owner', p_owner,
    jsonb_build_object('owner_id', p_owner, 'first_name', coalesce(o.first_name, split_part(o.legal_name, ' ', 1)), 'email', o.email,
                       'change_summary', case v_method when 'e_transfer' then 'New e-Transfer payout email submitted'
                                                       else 'New payout bank account ending ' || (p ->> 'account_last4') || ' submitted' end,
                       'changed_at', now(), 'changed_by', case when p_by = o.user_id then 'you' else 'CarmaCars staff' end),
    'owner_bank_details_changed:' || v_id || ':submitted');
  return v_id;
end $$;

create or replace function app.verify_payout_account(p_account uuid, p_admin uuid, p_method text) returns void
language plpgsql security definer set search_path = public, app as $$
declare
  a owner_payout_accounts;
  o owners;
begin
  if not app.user_is_admin(p_admin) then
    raise exception 'Only an Admin verifies payout details' using errcode = '42501';
  end if;
  if nullif(btrim(p_method), '') is null then
    raise exception 'Say how the details were verified' using errcode = '22023';
  end if;
  select * into a from owner_payout_accounts where id = p_account for update;
  if a.id is null then raise exception 'Payout account not found' using errcode = 'P0002'; end if;
  update owner_payout_accounts set is_current = false where owner_id = a.owner_id and is_current and id <> a.id;
  update owner_payout_accounts set is_current = true, verified_at = now(), verified_by = p_admin, verification_method = btrim(p_method)
   where id = a.id;
  update owners set payout_method = a.method where id = a.owner_id;
  update tasks set status = 'done', completed_at = now(), completed_by = p_admin
   where related_id = a.id and task_type = 'verify_payout_account' and status in ('open', 'in_progress', 'waiting');
  select * into o from owners where id = a.owner_id;
  perform app.emit_event('owner_bank_details_changed', 'owner', a.owner_id,
    jsonb_build_object('owner_id', a.owner_id, 'first_name', coalesce(o.first_name, split_part(o.legal_name, ' ', 1)), 'email', o.email,
                       'change_summary', 'Payout account ending ' || coalesce(a.account_last4, '') || ' is now in use',
                       'changed_at', now(), 'changed_by', 'CarmaCars staff'),
    'owner_bank_details_changed:' || a.id || ':verified');
end $$;

-- The server records a debit authorization or card the processor confirmed. The previous
-- default of the same kind stops being the default.
-- p: {kind, brand_or_bank, last4, authorized_at, authorization_document_id, processor_customer_id, processor_method_id, processor_mandate_id}
create or replace function app.record_owner_payment_method(p_owner uuid, p_by uuid, p jsonb) returns uuid
language plpgsql security definer set search_path = public, app as $$
declare
  o owners;
  v_id uuid;
begin
  select * into o from owners where id = p_owner;
  if o.id is null then raise exception 'Owner not found' using errcode = 'P0002'; end if;
  if p_by is not null and not (app.user_is_admin(p_by) or app.user_is_owner_of(p_by, p_owner)) then
    raise exception 'Not permitted' using errcode = '42501';
  end if;
  update owner_payment_methods set is_default = false where owner_id = p_owner and kind = p ->> 'kind' and is_default;
  insert into owner_payment_methods (owner_id, kind, status, brand_or_bank, last4, authorization_document_id, authorized_at, is_default)
  values (p_owner, p ->> 'kind', 'active', p ->> 'brand_or_bank', p ->> 'last4', nullif(p ->> 'authorization_document_id', '')::uuid,
          coalesce(nullif(p ->> 'authorized_at', '')::timestamptz, now()), true)
  returning id into v_id;
  if nullif(p ->> 'processor_method_id', '') is not null then
    insert into owner_payment_method_secrets (owner_payment_method_id, processor_customer_id, processor_method_id, processor_mandate_id)
    values (v_id, p ->> 'processor_customer_id', p ->> 'processor_method_id', p ->> 'processor_mandate_id');
  end if;
  perform app.emit_event('owner_bank_details_changed', 'owner', p_owner,
    jsonb_build_object('owner_id', p_owner, 'first_name', coalesce(o.first_name, split_part(o.legal_name, ' ', 1)), 'email', o.email,
                       'change_summary', case p ->> 'kind' when 'card' then 'New card on file ending ' else 'New pre-authorized debit account ending ' end
                                         || coalesce(p ->> 'last4', ''),
                       'changed_at', now(), 'changed_by', case when p_by = o.user_id then 'you' else 'CarmaCars staff' end),
    'owner_bank_details_changed:' || v_id || ':payment_method');
  return v_id;
end $$;

-- ---------------------------------------------------------------- the owner portal
-- What the server shows an owner. Each takes the owner's user id and returns only that owner's
-- records; renter contact details only on a Self-Managed rental or an Owner Booking.
create or replace function app.portal_owner_id(p_by uuid) returns uuid
language plpgsql stable security definer set search_path = public, app as $$
declare
  v_id uuid;
begin
  select o.id into v_id from owners o join users u on u.id = o.user_id
    join user_roles r on r.user_id = u.id and r.role = 'owner'
   where o.user_id = p_by and u.status = 'active' order by o.created_at limit 1;
  if v_id is null then raise exception 'Not an owner account' using errcode = '42501'; end if;
  return v_id;
end $$;

create or replace function app.owner_portal_vehicles(p_by uuid) returns jsonb
language sql stable security definer set search_path = public, app as $$
  select coalesce(jsonb_agg(jsonb_build_object(
      'vehicle_id', v.id, 'name', app.vehicle_name(v.id), 'plate', v.plate, 'status', v.status, 'management_mode', v.management_mode,
      'onboarding_status', ob.status, 'enrollment_date', v.enrollment_date, 'exit_date', v.exit_date,
      'insurance_fee_cents', s.insurance_fee_cents, 'tracker_fee_cents', s.tracker_fee_cents, 'revenue_share_bps', s.revenue_share_bps,
      'listing_status', l.status, 'listing_path', case when l.status in ('published', 'paused') then '/cars/' || l.slug end,
      'estimate_cents', ob.estimate_cents, 'government_forms', to_jsonb(ob.government_forms),
      'next', (select jsonb_build_object('item', c.label, 'waits_on', c.waits_on, 'action', c.next_action)
                 from app.onboarding_checklist(v.id) c where c.status = 'open' order by c.sort_order limit 1),
      'checklist', (select jsonb_agg(jsonb_build_object('code', c.code, 'label', c.label, 'status', c.status, 'waits_on', c.waits_on,
                                                        'next_action', c.next_action) order by c.sort_order)
                      from app.onboarding_checklist(v.id) c))
    order by v.created_at), '[]'::jsonb)
    from vehicles v
    left join vehicle_onboardings ob on ob.vehicle_id = v.id
    left join vehicle_schedules s on s.vehicle_id = v.id and s.superseded_by is null
    left join vehicle_listings l on l.vehicle_id = v.id
   where v.owner_id = app.portal_owner_id(p_by)
$$;

create or replace function app.owner_portal_bookings(p_by uuid, p_from timestamptz default null, p_to timestamptz default null)
returns table (booking_id uuid, booking_number text, booking_type booking_type, status booking_status, vehicle_id uuid, vehicle_name text,
               pickup_at timestamptz, return_at timestamptz, rental_charge_cents bigint, renter_name text, renter_mobile text)
language sql stable security definer set search_path = public, app as $$
  select b.id, b.booking_number, b.booking_type, b.status, b.vehicle_id, app.vehicle_name(b.vehicle_id), b.pickup_at, b.return_at,
         b.rental_charge_cents - b.discount_cents - b.staff_discount_cents - b.promo_discount_cents,
         case when b.management_mode = 'self_managed' or b.booking_type = 'owner' then r.legal_name end,
         case when b.management_mode = 'self_managed' or b.booking_type = 'owner' then r.mobile end
    from bookings b join vehicles v on v.id = b.vehicle_id join renters r on r.id = b.renter_id
   where v.owner_id = app.portal_owner_id(p_by)
     and b.status::text not in ('requested', 'offered', 'tentative', 'expired', 'declined')
     and (p_from is null or b.return_at > p_from) and (p_to is null or b.pickup_at < p_to)
   order by b.pickup_at
$$;

create or replace function app.owner_portal_money(p_by uuid) returns jsonb
language sql stable security definer set search_path = public, app as $$
  with o as (select app.portal_owner_id(p_by) as id)
  select jsonb_build_object(
    'invoices', (select coalesce(jsonb_agg(jsonb_build_object('id', i.id, 'invoice_number', i.invoice_number, 'vehicle_id', i.vehicle_id,
                   'kind', i.kind, 'period_month', i.period_month, 'billing_date', i.billing_date, 'status', i.status, 'fees_cents', i.fees_cents,
                   'hst_cents', i.hst_cents, 'late_fee_cents', i.late_fee_cents, 'total_cents', i.total_cents, 'balance_cents', i.balance_cents)
                   order by i.billing_date desc), '[]'::jsonb)
                   from owner_invoices i, o where i.owner_id = o.id and i.status <> 'draft'),
    'statements', (select coalesce(jsonb_agg(jsonb_build_object('id', s.id, 'statement_number', s.statement_number, 'statement_month', s.statement_month,
                     'payout_date', s.payout_date, 'status', s.status, 'payout_cents', s.payout_cents) order by s.statement_month desc), '[]'::jsonb)
                     from owner_statements s, o where s.owner_id = o.id and s.status in ('approved', 'paid')),
    'payouts', (select coalesce(jsonb_agg(jsonb_build_object('id', p.id, 'kind', p.kind, 'amount_cents', p.amount_cents, 'method', p.method,
                  'scheduled_for', p.scheduled_for, 'status', p.status) order by p.scheduled_for desc), '[]'::jsonb)
                  from payouts p, o where p.owner_id = o.id and p.payee_type = 'owner'))
$$;

create or replace function app.owner_portal_documents(p_by uuid) returns jsonb
language sql stable security definer set search_path = public, app as $$
  with o as (select app.portal_owner_id(p_by) as id)
  select coalesce(jsonb_agg(jsonb_build_object('id', d.id, 'kind', d.kind, 'title', d.title, 'vehicle_id', d.vehicle_id, 'created_at', d.created_at)
                            order by d.created_at desc), '[]'::jsonb)
    from documents d, o
   where (d.owner_id = o.id or d.vehicle_id in (select v.id from vehicles v where v.owner_id = o.id))
     and d.renter_id is null and d.booking_id is null and d.investor_id is null and d.incident_id is null and d.claim_id is null
     and d.purged_at is null
     and d.kind not in ('staff_agreement', 'investment_agreement', 'investment_schedule_a', 'investment_schedule_c', 'investment_schedule_d',
                        'investor_statement', 'securities_form', 'id_front', 'id_back', 'face_photo')
     and (d.condition_report_id is null or exists (select 1 from condition_reports c where c.id = d.condition_report_id and c.kind in ('baseline', 'exit')))
$$;

-- The owner books their own car (an Owner Booking: no price, no Deposit) through 0016's
-- app.request_booking. The owner's renter record is made the first time.
create or replace function app.owner_book_own_vehicle(p_by uuid, p_vehicle uuid, p_pickup timestamptz, p_return timestamptz,
                                                      p_note text default null, p_pickup_place text default null, p_return_place text default null)
returns uuid language plpgsql security definer set search_path = public, app as $$
declare
  o owners;
  v_renter uuid;
begin
  if not app.user_owns_vehicle(p_by, p_vehicle) then
    raise exception 'Not permitted: an owner books only their own vehicle' using errcode = '42501';
  end if;
  select o2.* into o from owners o2 join vehicles v on v.owner_id = o2.id where v.id = p_vehicle;
  if exists (select 1 from vehicles v where v.id = p_vehicle and v.status not in ('available', 'ready_to_list', 'cleaning', 'exit_notice')) then
    raise exception 'This vehicle cannot be booked now' using errcode = '23514';
  end if;
  select id into v_renter from renters where user_id = p_by;
  if v_renter is null then
    insert into renters (user_id, legal_name, mobile, email, is_owner_account)
    values (p_by, o.legal_name, o.phone, o.email, true) returning id into v_renter;
  end if;
  return app.request_booking(v_renter, p_vehicle, p_pickup, p_return, 'owner', p_note, 'owner', p_by, null, null,
                             'collected', 'returned', p_pickup_place, p_return_place);
end $$;

-- ---------------------------------------------------------------- browser access (wrappers in public, invoker)
-- The website's anonymous reads. Each passes the call to an app function above that returns
-- only public fields.
create or replace function public.site_settings_public() returns jsonb
language sql stable security invoker set search_path = public, app as $$ select app.public_site_settings() $$;
create or replace function public.site_content(p_page text default null) returns jsonb
language sql stable security invoker set search_path = public, app as $$ select app.public_site_content(p_page) $$;
create or replace function public.car_page(p_slug text) returns jsonb
language sql stable security invoker set search_path = public, app as $$ select app.public_car_page(p_slug) $$;
create or replace function public.fleet(p_filters jsonb default '{}'::jsonb) returns setof jsonb
language sql stable security invoker set search_path = public, app as $$ select * from app.public_fleet(p_filters) $$;
create or replace function public.model_hubs() returns setof jsonb
language sql stable security invoker set search_path = public, app as $$ select * from app.public_model_hubs() $$;
create or replace function public.model_hub(p_hub text) returns jsonb
language sql stable security invoker set search_path = public, app as $$ select app.public_model_hub(p_hub) $$;
create or replace function public.vehicle_photos_public(p_slug text) returns jsonb
language sql stable security invoker set search_path = public, app as $$ select app.public_vehicle_photos(p_slug) $$;
create or replace function public.sitemap_rows() returns table (path text, kind text, lastmod timestamptz)
language sql stable security invoker set search_path = public, app as $$ select * from app.public_sitemap() $$;
create or replace function public.resolve_path(p_path text) returns jsonb
language sql stable security invoker set search_path = public, app as $$ select app.resolve_listing_path(p_path) $$;
-- the server, for a visitor
create or replace function public.submit_lead(p jsonb, p_ip text default null) returns jsonb
language sql security invoker set search_path = public, app as $$ select app.submit_lead(p, p_ip) $$;

-- ---------------------------------------------------------------- row-level security
do $$
declare
  t text;
begin
  foreach t in array array['site_settings', 'site_content_blocks', 'form_drafts', 'leads', 'owner_private_details', 'owner_applications',
                           'onboarding_situations', 'onboarding_checklist_items', 'vin_decodes', 'pdf_templates', 'government_form_fields',
                           'government_form_fills', 'vehicle_term_changes', 'listing_shot_types', 'listing_redirects', 'listing_intakes',
                           'listing_drafts', 'listing_jobs', 'provider_calls'] loop
    execute format('alter table public.%I enable row level security', t);
    execute format('create policy admin_all on public.%I for all to authenticated using (app.is_admin()) with check (app.is_admin())', t);
  end loop;
end $$;

-- reference data an Admin edits: staff and owners read it (the situations, checklist wording and
-- shot list appear in the owner wizard and the capture screens)
create policy read_all on onboarding_situations for select to authenticated using (true);
create policy read_all on onboarding_checklist_items for select to authenticated using (true);
create policy read_all on listing_shot_types for select to authenticated using (true);
create policy staff_read on site_settings for select to authenticated using (app.is_va() or app.is_field());
create policy staff_read on site_content_blocks for select to authenticated using (app.is_va());
create policy va_read on pdf_templates for select to authenticated using (app.va_has('cs', 'fleet'));
create policy va_read on government_form_fields for select to authenticated using (app.va_has('cs', 'fleet'));
create policy va_read on listing_redirects for select to authenticated using (app.va_has('cs', 'fleet'));

-- a signed-in user reads their own drafts (writes go through the server's functions)
create policy self_read on form_drafts for select to authenticated using (user_id = app.uid());

-- leads: Sales works owner enquiries, customer service the rest
create policy sales_read on leads for select to authenticated using (app.va_has('sales'));
create policy sales_update on leads for update to authenticated using (app.va_has('sales')) with check (app.va_has('sales'));
create policy cs_read on leads for select to authenticated using (app.va_has('cs') and kind <> 'owner_program');
create policy cs_update on leads for update to authenticated using (app.va_has('cs') and kind <> 'owner_program') with check (app.va_has('cs') and kind <> 'owner_program');

-- the owner's licence number and date of birth: the owner and an Admin only
create policy owner_read on owner_private_details for select to authenticated using (app.is_my_owner(owner_id));

-- onboarding records follow the matrix row "Onboarding, registration, exit": Finance, Fleet and
-- customer service read; the owner reads their own
create policy va_read on owner_applications for select to authenticated using (app.va_has('finance', 'fleet', 'cs'));
create policy owner_read on owner_applications for select to authenticated using (app.is_my_owner(owner_id));
create policy va_read on vin_decodes for select to authenticated using (app.va_has('fleet', 'cs'));
create policy va_read on government_form_fills for select to authenticated using (app.va_has('fleet', 'cs', 'finance'));
create policy owner_read on government_form_fills for select to authenticated using (app.is_my_owner(owner_id));
create policy va_read on vehicle_term_changes for select to authenticated using (app.va_has('finance', 'fleet', 'cs'));
create policy owner_read on vehicle_term_changes for select to authenticated using (app.owns_vehicle(vehicle_id));

-- the listing pipeline: Fleet and customer service work it; the owner and the field staff
-- member who started an intake see it; Finance reads the provider costs
create policy va_read on listing_intakes for select to authenticated using (app.va_has('fleet', 'cs'));
create policy owner_read on listing_intakes for select to authenticated using (app.owns_vehicle(vehicle_id));
create policy starter_read on listing_intakes for select to authenticated using (started_by = app.uid() and app.is_field());
create policy va_read on listing_drafts for select to authenticated using (app.va_has('fleet', 'cs'));
create policy va_read on listing_jobs for select to authenticated using (app.va_has('fleet', 'cs'));
create policy finance_read on provider_calls for select to authenticated using (app.va_has('finance', 'fleet'));

-- ---------------------------------------------------------------- privileges
revoke all on site_settings, site_content_blocks, form_drafts, leads, owner_private_details, owner_applications, onboarding_situations,
  onboarding_checklist_items, vin_decodes, pdf_templates, government_form_fields, government_form_fills, vehicle_term_changes,
  listing_shot_types, listing_redirects, listing_intakes, listing_drafts, listing_jobs, provider_calls
  from anon, authenticated;
-- what an Admin edits in the portal (the policies leave every write to an Admin, and Sales or
-- customer service update their leads)
grant select, insert, update on site_settings, site_content_blocks, onboarding_situations, onboarding_checklist_items,
  pdf_templates, government_form_fields, listing_shot_types, listing_redirects to authenticated;
grant select, update on leads to authenticated;
-- written by the server's functions only
grant select on form_drafts, owner_private_details, owner_applications, vin_decodes, government_form_fills, vehicle_term_changes,
  listing_intakes, listing_drafts, listing_jobs, provider_calls to authenticated;
grant all on site_settings, site_content_blocks, form_drafts, leads, owner_private_details, owner_applications, onboarding_situations,
  onboarding_checklist_items, vin_decodes, pdf_templates, government_form_fields, government_form_fills, vehicle_term_changes,
  listing_shot_types, listing_redirects, listing_intakes, listing_drafts, listing_jobs, provider_calls to service_role;
grant usage on sequence owner_application_number_seq, owner_agreement_number_seq, vehicle_schedule_number_seq to service_role;

-- Functions: every function of this migration is closed, then opened one by one.
do $$
declare
  f record;
begin
  for f in select p.oid::regprocedure as sig from pg_proc p join pg_namespace n on n.oid = p.pronamespace
            where (n.nspname = 'app' and p.proname = any (array[
              'acting_role', 'add_owner_vehicle', 'advance_listing_intake', 'apply_transform', 'apply_vehicle_terms',
              'apply_vin_decode', 'approve_vehicle_terms', 'choose_onboarding_method', 'claim_listing_jobs', 'clean_vin',
              'complete_exit', 'complete_listing_job', 'confirm_vehicle_specs', 'content_block_before_write', 'context_value',
              'enqueue_listing_job', 'ensure_listing', 'fail_listing_job', 'fill_government_form', 'fill_vehicle_government_forms',
              'form_draft_before_write', 'give_exit_notice', 'give_fee_change_notice', 'issue_upfront_invoices',
              'listing_copy_problems', 'listing_cost_report', 'listing_facts', 'listing_missing_shots', 'listing_photo_problems',
              'listing_slug', 'listing_spec_problems', 'load_form_draft', 'log_provider_call', 'mark_onboarding_item',
              'model_hub_path', 'new_token', 'onboarding_checklist', 'onboarding_options', 'onboarding_plan',
              'owner_book_own_vehicle', 'owner_missing_fields', 'owner_portal_bookings', 'owner_portal_documents',
              'owner_portal_money', 'owner_portal_vehicles', 'photo_alt_text', 'portal_owner_id', 'propose_schedule_change',
              'public_car_page', 'public_fleet', 'public_listing_photos', 'public_listing_row', 'public_model_hub',
              'public_model_hubs', 'public_site_content', 'public_site_settings', 'public_sitemap', 'public_vehicle_photos',
              'publish_listing', 'purge_form_drafts', 'record_listing_upload', 'record_owner_payment_method',
              'record_schedule_change_signed', 'registry_context', 'request_draft_resume_link', 'resolve_listing_path',
              'resume_form_draft', 'retry_listing_intake', 'review_listing', 'save_application_owner', 'save_form_draft',
              'set_government_form_status', 'set_vehicle_terms', 'site_settings_before_write', 'slugify', 'standard_terms',
              'start_listing_intake', 'store_listing_draft', 'strip_transient', 'submit_form_draft', 'submit_lead',
              'submit_listing_intake', 'submit_owner_application', 'submit_payout_account', 'token_hash', 'unlist_listing',
              'user_field_has_job', 'user_is_owner_of', 'user_may_list', 'user_owns_vehicle', 'vehicle_listing_before_update',
              'vehicle_name', 'verify_payout_account', 'withdraw_exit_notice']))
               or (n.nspname = 'public' and p.proname = any (array['site_settings_public', 'site_content', 'car_page', 'fleet', 'model_hubs',
                                                                   'model_hub', 'vehicle_photos_public', 'sitemap_rows', 'resolve_path', 'submit_lead']))
  loop
    execute format('revoke all on function %s from public, anon, authenticated', f.sig);
  end loop;
end $$;
grant execute on all functions in schema app to service_role;
-- anyone: the public website's reads
grant execute on function app.public_site_settings(), app.public_site_content(text), app.public_car_page(text), app.public_fleet(jsonb),
  app.public_model_hubs(), app.public_model_hub(text), app.public_vehicle_photos(text), app.public_sitemap(), app.resolve_listing_path(text),
  app.public_listing_row(uuid), app.public_listing_photos(uuid), app.slugify(text), app.model_hub_path(text, text)
  to anon, authenticated;
grant execute on function public.site_settings_public(), public.site_content(text), public.car_page(text), public.fleet(jsonb),
  public.model_hubs(), public.model_hub(text), public.vehicle_photos_public(text), public.sitemap_rows(), public.resolve_path(text)
  to anon, authenticated, service_role;
grant execute on function public.submit_lead(jsonb, text) to service_role;
-- signed-in users: the reference reads behind the owner wizard
grant execute on function app.onboarding_options(owner_type, title_status, management_mode), app.clean_vin(text) to authenticated;

-- ---------------------------------------------------------------- audit
-- form drafts are logged without their answers (the audit trigger is named as attach_audit names
-- it, so attach_audit leaves it alone)
create trigger audit_form_drafts after insert or update or delete on form_drafts
  for each row execute function app.audit_row('redact');
do $$ begin perform app.attach_audit(); end $$;
