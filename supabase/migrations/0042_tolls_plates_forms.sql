-- 0042_tolls_plates_forms.sql
-- Tolls, plates and forms (docs/changes/2026-10-14-tolls-plates-forms.md):
--   1. reading toll notices and statements: what a person or the browser read from an uploaded file (CSV,
--      a PDF's text, or a scanned page read by a vision model) is kept as a "read" with one line per trip or
--      offence; staff check and correct the lines beside the file, then confirm: the lines go through 0021's
--      import (validation, duplicates, matching), renters matched with high confidence are charged when the
--      setting says so, and every line that could not be imported stays as an exception for Finance.
--      The import profiles of 0021 gain reading rules (label words per field, the trip line, the issuer's
--      words), editable in Admin without code.
--   2. covering licence plates on listing photos: each public photo records whether its plate is covered or
--      not visible, the boxes and the style; the covered file replaces the public one, the uncovered copy is
--      kept privately; publishing waits until every public photo is checked (a setting).
--   3. official ServiceOntario PDFs: an Admin uploads the fillable PDF, the field names are read in the
--      browser and mapped to the data each form needs; owners then get the official form filled, to sign
--      or download; until a mapping is checked the data sheet stays.
--   4. one turnaround between trips: the 2-hour buffer of 0025 and the cleaning block of 0040 are the same
--      time, read from one setting (turnaround_buffer_minutes, a car may have its own); the block holds the
--      time after a trip, so removing it frees that time.
--   5. AI calls (vision) are recorded with their neurons and capped per day.
-- No earlier migration is edited. Functions it changes are wrapped (renamed _00NN and called from a new function
-- of the same name) or replaced with the same signature. Function bodies are checked when called.
set local check_function_bodies = off;

-- ================================================================ 1. settings
alter table program_settings
  add column toll_read_min_confidence smallint not null default 80 check (toll_read_min_confidence between 0 and 100),
  add column toll_read_auto_charge boolean not null default true,
  add column toll_read_max_pages smallint not null default 6 check (toll_read_max_pages between 1 and 30),
  add column ai_vision_enabled boolean not null default true,
  add column ai_vision_model text not null default '@cf/meta/llama-4-scout-17b-16e-instruct',
  add column ai_vision_fallback_model text default '@cf/meta/llama-3.2-11b-vision-instruct',
  add column ai_vision_daily_neurons integer not null default 3000 check (ai_vision_daily_neurons between 0 and 1000000),
  add column listing_plate_check_required boolean not null default true,
  add column plate_cover_style text not null default 'cover' check (plate_cover_style in ('cover', 'pixelate', 'blur')),
  add column plate_cover_text text,
  add column plate_detect_enabled boolean not null default true;
comment on column program_settings.toll_read_min_confidence is 'A line read from a notice at or above this confidence (0 to 100) with nothing missing is imported when the read is confirmed; below it, a person checks it first';
comment on column program_settings.toll_read_auto_charge is 'When a read is confirmed, renters matched with high confidence are charged straight away (the notice plus the administration fee); off: Finance charges from the work queue';
comment on column program_settings.toll_read_max_pages is 'Pages of a scanned notice or statement sent to the vision model';
comment on column program_settings.ai_vision_enabled is 'Scanned notices and listing photos may be read by the vision model (Cloudflare Workers AI)';
comment on column program_settings.ai_vision_model is 'Workers AI model that reads scanned notices and suggests plate boxes';
comment on column program_settings.ai_vision_fallback_model is 'Model tried when the first one is not available (empty: none)';
comment on column program_settings.ai_vision_daily_neurons is 'Workers AI neurons the vision reads may use per Toronto day (the free allowance is shared with listing copy)';
comment on column program_settings.listing_plate_check_required is 'Every public listing photo must be marked "plate covered" or "plate not visible" before the listing is published';
comment on column program_settings.plate_cover_style is 'The default way to cover a plate: cover (a CarmaCars plate), pixelate or blur';
comment on column program_settings.plate_cover_text is 'Text on the plate cover (empty: the brand name in Site settings)';
comment on column program_settings.plate_detect_enabled is 'Suggest the plate box on a listing photo with the vision model (staff always confirm or draw it)';

-- one turnaround: turnaround_buffer_minutes (0025) is the time between trips; the cleaning block of 0040 holds it.
-- turnaround_block_minutes stays as a column for earlier readers and always equals the buffer.
comment on column program_settings.turnaround_buffer_minutes is 'Turnaround between trips, in minutes (default 120): no trip may start within it after another ends; after each trip it shows on the calendar as the cleaning block, which staff may remove to free the time';
comment on column program_settings.turnaround_block_minutes is 'Kept equal to turnaround_buffer_minutes (0042): there is one turnaround';
comment on column program_settings.turnaround_block_enabled is 'The turnaround after a trip shows on the calendar as a cleaning block (off: the same time is held without a block)';
comment on column vehicles.turnaround_block_minutes is 'This car''s turnaround between trips, in minutes; empty uses Program settings (0042)';
update program_settings set turnaround_block_minutes = least(turnaround_buffer_minutes, 2880) where turnaround_block_minutes is distinct from least(turnaround_buffer_minutes, 2880);
create or replace function app.program_settings_one_turnaround() returns trigger
language plpgsql as $$
begin
  new.turnaround_block_minutes := least(greatest(coalesce(new.turnaround_buffer_minutes, 0), 0), 2880);
  return new;
end $$;
create trigger program_settings_one_turnaround before insert or update on program_settings
  for each row execute function app.program_settings_one_turnaround();

-- ================================================================ 2. AI calls: budget and record
-- provider_calls (0022, units 0032) holds every outside call. Vision reads are capped per Toronto day on
-- their own; the listing copy budget (0032) counts every neuron, so both share the free allowance.
create or replace function app.ai_vision_budget(p_now timestamptz default now()) returns jsonb
language sql stable security definer set search_path = public, app as $$
  with ps as (select * from app.settings(app.local_date(p_now))),
       day as (select app.local_midnight(app.local_date(p_now)) as t0, app.local_midnight(app.local_date(p_now) + 1) as t1)
  select jsonb_build_object(
    'enabled', (select ai_vision_enabled from ps),
    'model', (select ai_vision_model from ps), 'fallback_model', (select ai_vision_fallback_model from ps),
    'used', (select coalesce(sum(c.units), 0) from provider_calls c, day where c.unit = 'neurons' and c.purpose in ('toll_read', 'plate_detect')
                and c.created_at >= day.t0 and c.created_at < day.t1),
    'limit', (select ai_vision_daily_neurons from ps),
    'all_used', (select coalesce(sum(c.units), 0) from provider_calls c, day where c.unit = 'neurons' and c.created_at >= day.t0 and c.created_at < day.t1),
    'all_limit', (select listing_ai_daily_neurons from ps),
    'resets_at', (select t1 from day))
$$;

create or replace function app.ai_call_record(p_by uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  v_id uuid;
begin
  if p_by is null or not (app.user_is_admin(p_by) or app.user_is_staff(p_by)) then
    raise exception 'Not permitted' using errcode = '42501';
  end if;
  if coalesce(p ->> 'purpose', '') not in ('toll_read', 'plate_detect') then
    raise exception 'Unknown purpose' using errcode = '22023';
  end if;
  insert into provider_calls (provider, purpose, vehicle_id, ok, error, duration_ms, cost_microusd, units, unit)
  values (left(coalesce(p ->> 'model', 'workers-ai'), 120), p ->> 'purpose', nullif(p ->> 'vehicle', '')::uuid, coalesce((p ->> 'ok')::boolean, false),
          left(p ->> 'error', 500), greatest(coalesce((p ->> 'duration_ms')::integer, 0), 0), 0,
          greatest(coalesce((p ->> 'neurons')::integer, 0), 0), 'neurons')
  returning id into v_id;
  return jsonb_build_object('id', v_id, 'budget', app.ai_vision_budget());
end $$;

-- May this person ask the vision model for this purpose now? The answer names the model and what is left.
create or replace function app.ai_vision_gate(p_by uuid, p_purpose text) returns jsonb
language plpgsql stable security definer set search_path = public, app as $$
declare
  b jsonb := app.ai_vision_budget();
begin
  if p_purpose = 'toll_read' then
    if not app.user_runs_finance(p_by) then raise exception 'Finance or an Admin reads notices' using errcode = '42501'; end if;
  elsif p_purpose = 'plate_detect' then
    if not (app.user_is_admin(p_by) or app.user_va_has(p_by, 'fleet', 'cs')) then raise exception 'Fleet, customer service or an Admin edits listing photos' using errcode = '42501'; end if;
    if not (app.settings()).plate_detect_enabled then
      return b || jsonb_build_object('allowed', false, 'reason', 'Plate suggestions are off in Program settings');
    end if;
  else
    raise exception 'Unknown purpose' using errcode = '22023';
  end if;
  if not coalesce((b ->> 'enabled')::boolean, false) then
    return b || jsonb_build_object('allowed', false, 'reason', 'Reading with the vision model is off in Program settings');
  end if;
  if (b ->> 'used')::bigint >= (b ->> 'limit')::bigint or (b ->> 'all_used')::bigint >= (b ->> 'all_limit')::bigint then
    return b || jsonb_build_object('allowed', false, 'reason', 'Today''s allowance for the vision model is used up; it starts again at midnight, Toronto time');
  end if;
  return b || jsonb_build_object('allowed', true);
end $$;

-- ================================================================ 3. reading toll notices and statements
-- 3.1 the import profiles of 0021 gain reading rules
alter table toll_import_profiles
  add column source text not null default 'csv' check (source in ('csv', 'pdf_text')),
  add column notice_kind text not null default 'toll_invoice' check (notice_kind in ('toll_invoice', 'ticket', 'camera_offence', 'parking', 'fine', 'tow', 'impound')),
  add column rules jsonb not null default '{}'::jsonb check (jsonb_typeof(rules) = 'object'),
  add column is_active boolean not null default true,
  add column priority smallint not null default 100,
  add column notes text,
  add column sample_text text;
comment on column toll_import_profiles.source is 'csv: a column mapping for a header row (0021); pdf_text: reading rules for the text of a PDF notice or statement (0042)';
comment on column toll_import_profiles.rules is 'pdf_text: {layout statement|single, detect [words], authority, date_order, fields {field: [label words]}, trip {skip_words, statement_fee_words}}';

insert into toll_import_profiles (operator, name, header_signature, mapping, source, notice_kind, priority, notes, rules) values
  ('407 ETR', '407 ETR statement', 'text:407-etr-statement', '{}'::jsonb, 'pdf_text', 'toll_invoice', 10,
   'Built from the public layout of 407 ETR statements (account summary, then one line per trip with date, time, entry and exit, distance, plate or transponder and charges). Check it against the first real statement and adjust the words below.',
   '{"layout": "statement", "detect": ["407 ETR", "407etr", "Express Toll Route"], "authority": "407 ETR", "date_order": "auto",
     "fields": {"statement_number": ["Statement Number", "Statement No", "Invoice Number", "Invoice No", "Bill Number"],
                "account_number": ["Account Number", "Account No", "Account #"],
                "statement_date": ["Statement Date", "Invoice Date", "Bill Date"],
                "due_on": ["Payment Due Date", "Payment Due", "Due Date", "Please Pay By"],
                "total": ["Total Amount Due", "Amount Due", "New Balance", "Balance Due"]},
     "trip": {"skip_words": ["Previous Balance", "Payment Received", "Payments", "Subtotal", "Sub-total", "Total", "Balance", "Interest", "Thank you"],
              "statement_fee_words": ["Account Fee", "Monthly Account Fee", "Late Payment", "Administration Fee", "Collection Fee", "Annual Transponder", "Transponder Lease"]}}'::jsonb),
  ('Ontario camera notice', 'Red light or speed camera (Ontario)', 'text:ontario-camera', '{}'::jsonb, 'pdf_text', 'camera_offence', 20,
   'Red light camera and automated speed enforcement notices and penalty orders mailed to the plate holder in Ontario.',
   '{"layout": "single", "detect": ["Red Light Camera", "Automated Speed Enforcement", "Speed Camera", "ASE", "Camera Offence"], "date_order": "auto",
     "fields": {"authority": ["Municipality", "Issued by", "Court"],
                "notice_number": ["Offence Notice Number", "Offence Number", "Notice Number", "Penalty Order Number", "Penalty Notice Number", "Notice No", "Ticket Number"],
                "plate": ["Licence Plate Number", "License Plate Number", "Plate Number", "Licence Plate", "Plate"],
                "date": ["Date of Offence", "Offence Date", "Date of Contravention", "Date"],
                "time": ["Time of Offence", "Offence Time", "Time"],
                "place": ["Location of Offence", "Location", "At"],
                "amount": ["Total Payable", "Amount Payable", "Total Amount", "Penalty Amount", "Set Fine"],
                "due_on": ["Due Date", "Payment Due", "Pay By"]}}'::jsonb),
  ('Ontario parking or penalty notice', 'Parking or administrative penalty (Ontario)', 'text:ontario-parking', '{}'::jsonb, 'pdf_text', 'parking', 30,
   'Parking violation notices and administrative penalty notices of Ontario municipalities (for example Toronto, Mississauga, Ottawa).',
   '{"layout": "single", "detect": ["Parking", "Penalty Notice", "Administrative Penalty", "Parking Violation", "Infraction"], "date_order": "auto",
     "fields": {"authority": ["Municipality", "City of", "Issued by"],
                "notice_number": ["Penalty Notice Number", "Penalty Notice No", "Violation Notice Number", "Parking Violation Notice", "Notice Number", "Tag Number", "PN"],
                "plate": ["Licence Plate Number", "License Plate Number", "Plate Number", "Licence Plate", "Plate"],
                "date": ["Date of Infraction", "Infraction Date", "Date of Contravention", "Date Issued", "Date"],
                "time": ["Time of Infraction", "Time Issued", "Time"],
                "place": ["Location", "Address", "At"],
                "amount": ["Penalty Amount", "Amount Due", "Total Due", "Set Fine", "Amount"],
                "due_on": ["Due Date", "Payment Due", "Pay By"]}}'::jsonb),
  ('Ontario offence notice', 'Provincial offence notice (Ontario)', 'text:ontario-offence', '{}'::jsonb, 'pdf_text', 'ticket', 40,
   'Provincial Offences Act notices (a ticket from the police or a provincial officer) sent to the owner of the plate.',
   '{"layout": "single", "detect": ["Provincial Offences Act", "Offence Notice", "Certificate of Offence", "Highway Traffic Act", "Ontario Court of Justice"], "date_order": "auto",
     "fields": {"authority": ["Police Service", "Issued by", "Court"],
                "notice_number": ["Offence Number", "Offence Notice Number", "Notice Number", "Ticket Number", "Certificate Number"],
                "plate": ["Plate Number", "Licence Plate", "License Plate", "Plate"],
                "date": ["Date of Offence", "Offence Date", "On", "Date"],
                "time": ["Time", "At Time"],
                "place": ["Location", "At"],
                "amount": ["Total Payable", "Set Fine", "Amount Payable", "Total"],
                "due_on": ["Due Date", "Pay By"]}}'::jsonb),
  ('Other issuer', 'Any notice (general reading)', 'text:generic', '{}'::jsonb, 'pdf_text', 'fine', 900,
   'Used when no other profile matches: reads the common labels and any line with a date and an amount.',
   '{"layout": "auto", "detect": [], "date_order": "auto",
     "fields": {"authority": ["Issued by", "Municipality", "Authority"],
                "notice_number": ["Notice Number", "Notice No", "Ticket Number", "Invoice Number", "Reference Number", "Penalty Notice Number", "Offence Number"],
                "statement_number": ["Statement Number", "Invoice Number"],
                "plate": ["Licence Plate Number", "License Plate Number", "Plate Number", "Licence Plate", "Plate"],
                "date": ["Date of Offence", "Date of Contravention", "Date of Infraction", "Trip Date", "Date"],
                "time": ["Time"], "place": ["Location", "Address"],
                "amount": ["Amount Due", "Total Due", "Total Payable", "Amount"],
                "due_on": ["Due Date", "Payment Due", "Pay By"], "total": ["Total Amount Due", "Amount Due"]},
     "trip": {"skip_words": ["Previous Balance", "Payment", "Subtotal", "Total", "Balance"], "statement_fee_words": ["Account Fee", "Late", "Administration Fee"]}}'::jsonb)
on conflict (operator, header_signature) do nothing;

-- 3.2 a read and its lines
create sequence toll_notice_read_number_seq start 1001;
create table toll_notice_reads (
  id              uuid primary key default gen_random_uuid(),
  read_number     text not null unique default ('TR-' || nextval('toll_notice_read_number_seq')),
  document_id     uuid references documents (id),
  file_name       text,
  mime_type       text,
  method          text not null check (method in ('csv', 'pdf_text', 'vision', 'manual')),
  profile_id      uuid references toll_import_profiles (id) on delete set null,
  authority       text,
  kind            text not null default 'toll_invoice' check (kind in ('toll_invoice', 'ticket', 'camera_offence', 'parking', 'fine', 'tow', 'impound')),
  statement_number text,
  account_number  text,
  statement_date  date,
  due_on          date,
  total_cents     bigint check (total_cents >= 0),
  page_count      integer check (page_count >= 0),
  model           text,
  neurons         integer not null default 0 check (neurons >= 0),
  header          jsonb not null default '{}'::jsonb,
  problems        text[] not null default '{}',
  status          text not null default 'in_review' check (status in ('in_review', 'confirmed', 'discarded')),
  batch_ids       uuid[] not null default '{}',
  result          jsonb,
  created_by      uuid references users (id),
  created_at      timestamptz not null default now(),
  updated_at      timestamptz not null default now(),
  confirmed_by    uuid references users (id),
  confirmed_at    timestamptz,
  discarded_by    uuid references users (id),
  discarded_at    timestamptz,
  discard_reason  text
);
create trigger toll_notice_reads_updated before update on toll_notice_reads for each row execute function app.set_updated_at();
create index toll_notice_reads_status_idx on toll_notice_reads (status, created_at desc);
comment on table toll_notice_reads is 'A toll notice or statement as read (CSV, PDF text or vision): lines checked by staff before import (0042)';

create table toll_notice_read_lines (
  id              uuid primary key default gen_random_uuid(),
  read_id         uuid not null references toll_notice_reads (id) on delete cascade,
  line_no         integer not null check (line_no > 0),
  kind            text check (kind in ('toll_invoice', 'ticket', 'camera_offence', 'parking', 'fine', 'tow', 'impound')),
  authority       text,
  notice_number   text,
  plate           text,
  transponder     text,
  occurred_at     timestamptz,
  time_unknown    boolean not null default false,
  place           text,
  entry           text,
  exit            text,
  amount_cents    bigint check (amount_cents >= 0),
  fees_cents      bigint check (fees_cents >= 0),
  due_on          date,
  confidence      smallint not null default 0 check (confidence between 0 and 100),
  problems        text[] not null default '{}',
  source_text     text,
  page            integer check (page > 0),
  box             jsonb,
  vehicle_id      uuid references vehicles (id),
  vehicle_found_by text,
  status          text not null default 'pending' check (status in ('pending', 'checked', 'excluded', 'imported', 'duplicate', 'exception')),
  result_reason   text,
  toll_ticket_id  uuid references toll_tickets (id) on delete set null,
  edited          boolean not null default false,
  checked_by      uuid references users (id),
  checked_at      timestamptz,
  updated_at      timestamptz not null default now(),
  unique (read_id, line_no)
);
create trigger toll_notice_read_lines_updated before update on toll_notice_read_lines for each row execute function app.set_updated_at();
create index toll_notice_read_lines_status_idx on toll_notice_read_lines (status) where status in ('pending', 'exception');
comment on column toll_notice_read_lines.confidence is 'How sure the reading is, 0 to 100: the model''s own figure for a vision read, lowered for anything missing or not in the fleet';

insert into task_rules (task_type, queue, title, priority, due_kind, due_amount, procedure_no, completion_rule, description) values
  ('toll_read_review', 'finance', 'Check the lines read from a notice', 'normal', 'business_days', 1, 11, null,
   'Open the read, compare each line with the notice beside it, correct what was misread, then confirm'),
  ('toll_read_exceptions', 'finance', 'Lines from a notice were not imported', 'high', 'business_days', 1, 11, null,
   'Each line names why: fix it and import it, or exclude it with the reason')
on conflict (task_type) do nothing;

-- The fleet's plates and transponders, for the browser's reading (Finance and Admins).
create or replace function app.toll_read_context(p_by uuid) returns jsonb
language plpgsql stable security definer set search_path = public, app as $$
begin
  if not app.user_runs_finance(p_by) then raise exception 'Finance or an Admin reads notices' using errcode = '42501'; end if;
  return jsonb_build_object(
    'profiles', coalesce((select jsonb_agg(jsonb_build_object('id', p.id, 'operator', p.operator, 'name', p.name, 'source', p.source, 'notice_kind', p.notice_kind,
                                   'rules', p.rules, 'priority', p.priority, 'header_signature', p.header_signature, 'mapping', p.mapping, 'date_format', p.date_format,
                                   'amount_unit', p.amount_unit) order by p.priority, p.name)
                            from toll_import_profiles p where p.is_active), '[]'::jsonb),
    'plates', coalesce((select jsonb_agg(distinct x.p) from (
                select app.norm_plate(v.plate) as p from vehicles v where v.plate is not null
                union select app.norm_plate(h.plate) from vehicle_plate_history h) x where x.p is not null), '[]'::jsonb),
    'transponders', coalesce((select jsonb_agg(distinct upper(btrim(t.transponder_number))) from vehicle_transponders t), '[]'::jsonb),
    'settings', (select jsonb_build_object('min_confidence', s.toll_read_min_confidence, 'auto_charge', s.toll_read_auto_charge,
                                           'max_pages', s.toll_read_max_pages, 'vision', s.ai_vision_enabled) from app.settings() s),
    'vision', app.ai_vision_budget());
end $$;

-- A notice file uploaded by Finance or an Admin (the reader's first step): one documents row.
create or replace function app.toll_read_document(p_by uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  v_id uuid;
begin
  if not app.user_runs_finance(p_by) then raise exception 'Finance or an Admin uploads notices' using errcode = '42501'; end if;
  if coalesce(p ->> 'storage_path', '') !~ '^tolls/' then raise exception 'Unknown file' using errcode = '22023'; end if;
  insert into documents (kind, title, storage_bucket, storage_path, mime_type, sha256, uploaded_by)
  values ('toll_ticket_notice', left(coalesce(p ->> 'title', 'Notice'), 200), 'documents', p ->> 'storage_path', p ->> 'mime_type', p ->> 'sha256', p_by)
  returning id into v_id;
  return jsonb_build_object('id', v_id);
end $$;

-- What is wrong with one line, and the car it belongs to. Problems are said the way staff read them.
create or replace function app.toll_read_line_refresh(p_line uuid) returns void
language plpgsql security definer set search_path = public, app as $$
declare
  l toll_notice_read_lines;
  r toll_notice_reads;
  v record;
  v_kind text;
  v_problems text[] := '{}';
  v_dup text;
  v_min smallint := (app.settings()).toll_read_min_confidence;
begin
  select * into l from toll_notice_read_lines where id = p_line;
  select * into r from toll_notice_reads where id = l.read_id;
  v_kind := coalesce(l.kind, r.kind);
  if nullif(btrim(coalesce(l.plate, '')), '') is null and nullif(btrim(coalesce(l.transponder, '')), '') is null then
    v_problems := v_problems || 'Plate missing'::text;
  end if;
  if l.occurred_at is null then v_problems := v_problems || 'Date missing'::text;
  elsif l.occurred_at > now() then v_problems := v_problems || 'Date in the future'::text;
  elsif l.occurred_at < now() - interval '3 years' then v_problems := v_problems || 'Date more than 3 years ago'::text;
  end if;
  if l.time_unknown and l.occurred_at is not null then v_problems := v_problems || 'Time not stated'::text; end if;
  if l.amount_cents is null then v_problems := v_problems || 'Amount missing'::text; end if;
  if v_kind <> 'toll_invoice' and nullif(btrim(coalesce(l.notice_number, '')), '') is null then
    v_problems := v_problems || 'Notice number missing'::text;
  end if;
  if nullif(btrim(coalesce(l.authority, r.authority, '')), '') is null then v_problems := v_problems || 'Issuer missing'::text; end if;
  select * into v from app.resolve_toll_vehicle(app.norm_plate(l.plate), nullif(btrim(l.transponder), ''), app.local_date(coalesce(l.occurred_at, now())));
  if v.vehicle_id is null and (l.plate is not null or l.transponder is not null) then
    v_problems := v_problems || 'Plate not in the fleet'::text;
  end if;
  select t.notice_number into v_dup from toll_tickets t
   where (nullif(btrim(l.notice_number), '') is not null and t.authority = coalesce(nullif(btrim(l.authority), ''), r.authority) and t.notice_number = btrim(l.notice_number))
      or (app.norm_plate(l.plate) is not null and app.norm_plate(t.plate) = app.norm_plate(l.plate) and t.occurred_at = l.occurred_at and t.amount_cents = l.amount_cents)
   limit 1;
  if found then v_problems := v_problems || ('Already logged' || coalesce(' as ' || v_dup, ''))::text; end if;
  if l.confidence < v_min and l.status not in ('checked') and not l.edited then
    v_problems := v_problems || format('Read with %s%% confidence', l.confidence);
  end if;
  update toll_notice_read_lines set problems = v_problems, vehicle_id = v.vehicle_id, vehicle_found_by = v.found_by where id = p_line;
end $$;

-- Save what was read. p: method, document_id, file_name, mime_type, profile_id, authority, kind, statement_number,
-- account_number, statement_date, due_on, total_cents, page_count, model, neurons, header, problems, lines [{line_no?,
-- kind, authority, notice_number, plate, transponder, occurred_at (ISO; no zone = Toronto), time_unknown, place, entry,
-- exit, amount_cents, fees_cents, due_on, confidence, source_text, page, box}].
create or replace function app.toll_read_save(p_by uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  v_id uuid;
  x jsonb;
  n integer := 0;
  v_line uuid;
  v_at timestamptz;
begin
  if not app.user_runs_finance(p_by) then raise exception 'Finance or an Admin reads notices' using errcode = '42501'; end if;
  if coalesce(p ->> 'method', '') not in ('csv', 'pdf_text', 'vision', 'manual') then raise exception 'Unknown reading method' using errcode = '22023'; end if;
  if jsonb_typeof(p -> 'lines') is distinct from 'array' then raise exception 'No lines were read' using errcode = '22023'; end if;
  if jsonb_array_length(p -> 'lines') > 2000 then raise exception 'At most 2,000 lines per read' using errcode = '22023'; end if;
  if (p ->> 'document_id') is not null and not exists (select 1 from documents d where d.id = (p ->> 'document_id')::uuid and d.kind = 'toll_ticket_notice') then
    raise exception 'The notice file is not on record' using errcode = 'P0002';
  end if;
  insert into toll_notice_reads (document_id, file_name, mime_type, method, profile_id, authority, kind, statement_number, account_number,
                                 statement_date, due_on, total_cents, page_count, model, neurons, header, problems, created_by)
  values ((p ->> 'document_id')::uuid, left(p ->> 'file_name', 200), p ->> 'mime_type', p ->> 'method',
          (select id from toll_import_profiles where id = nullif(p ->> 'profile_id', '')::uuid),
          nullif(btrim(p ->> 'authority'), ''), coalesce(nullif(p ->> 'kind', ''), 'toll_invoice'), nullif(btrim(p ->> 'statement_number'), ''),
          nullif(btrim(p ->> 'account_number'), ''), nullif(p ->> 'statement_date', '')::date, nullif(p ->> 'due_on', '')::date,
          nullif(p ->> 'total_cents', '')::bigint, nullif(p ->> 'page_count', '')::integer, left(p ->> 'model', 120),
          greatest(coalesce(nullif(p ->> 'neurons', '')::integer, 0), 0), coalesce(p -> 'header', '{}'::jsonb),
          coalesce((select array_agg(left(e, 300)) from jsonb_array_elements_text(coalesce(p -> 'problems', '[]'::jsonb)) e), '{}'),
          p_by)
  returning id into v_id;
  for x in select * from jsonb_array_elements(p -> 'lines') loop
    n := n + 1;
    begin
      v_at := case when nullif(x ->> 'occurred_at', '') is null then null
                   when (x ->> 'occurred_at') ~ '(Z|[+-][0-9]{2}(:?[0-9]{2})?)$' then (x ->> 'occurred_at')::timestamptz
                   else (x ->> 'occurred_at')::timestamp at time zone 'America/Toronto' end;
    exception when others then v_at := null;
    end;
    insert into toll_notice_read_lines (read_id, line_no, kind, authority, notice_number, plate, transponder, occurred_at, time_unknown, place,
                                        entry, exit, amount_cents, fees_cents, due_on, confidence, source_text, page, box)
    values (v_id, n, nullif(x ->> 'kind', ''), nullif(btrim(x ->> 'authority'), ''), nullif(btrim(x ->> 'notice_number'), ''),
            nullif(upper(btrim(x ->> 'plate')), ''), nullif(upper(btrim(x ->> 'transponder')), ''), v_at,
            coalesce((x ->> 'time_unknown')::boolean, false), nullif(btrim(x ->> 'place'), ''), nullif(btrim(x ->> 'entry'), ''),
            nullif(btrim(x ->> 'exit'), ''), case when (x ->> 'amount_cents') ~ '^[0-9]+$' then (x ->> 'amount_cents')::bigint end,
            case when (x ->> 'fees_cents') ~ '^[0-9]+$' then (x ->> 'fees_cents')::bigint end,
            case when (x ->> 'due_on') ~ '^\d{4}-\d{2}-\d{2}$' then (x ->> 'due_on')::date end,
            least(greatest(coalesce(round((x ->> 'confidence')::numeric)::integer, 0), 0), 100), left(x ->> 'source_text', 1000),
            nullif(x ->> 'page', '')::integer, x -> 'box')
    returning id into v_line;
    perform app.toll_read_line_refresh(v_line);
  end loop;
  perform app.raise_task(p_type => 'toll_read_review', p_title => format('Check the lines read from %s', coalesce(nullif(p ->> 'file_name', ''), 'a notice')),
      p_related_table => 'toll_notice_reads', p_related_id => v_id, p_created_by => p_by, p_dedupe => 'toll_read_review:' || v_id,
      p_due_at => app.add_business_days(app.today(), 1)::timestamptz);
  return app.toll_read_get(p_by, v_id);
end $$;

-- One read for the review screen: the lines, their cars and problems, the document, the profile.
create or replace function app.toll_read_get(p_by uuid, p_read uuid) returns jsonb
language plpgsql stable security definer set search_path = public, app as $$
begin
  if not app.user_runs_finance(p_by) then raise exception 'Finance or an Admin reads notices' using errcode = '42501'; end if;
  return (select to_jsonb(r) || jsonb_build_object(
      'profile_name', (select p.name from toll_import_profiles p where p.id = r.profile_id),
      'created_by_name', (select u.full_name from users u where u.id = r.created_by),
      'confirmed_by_name', (select u.full_name from users u where u.id = r.confirmed_by),
      'min_confidence', (app.settings()).toll_read_min_confidence,
      'auto_charge', (app.settings()).toll_read_auto_charge,
      'lines', coalesce((select jsonb_agg(to_jsonb(l) || jsonb_build_object(
                    'vehicle_name', app.vehicle_name(l.vehicle_id),
                    'ticket', (select jsonb_build_object('id', t.id, 'status', t.status, 'matched_to', t.matched_to, 'match_confidence', t.match_confidence,
                                                         'booking_number', (select b.booking_number from bookings b where b.id = t.booking_id), 'charged_at', t.charged_at)
                                 from toll_tickets t where t.id = l.toll_ticket_id)) order by l.line_no)
                  from toll_notice_read_lines l where l.read_id = r.id), '[]'::jsonb))
    from toll_notice_reads r where r.id = p_read);
end $$;

-- Correct one line (any field), or mark it checked or excluded.
create or replace function app.toll_read_line_save(p_by uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  l toll_notice_read_lines;
  r toll_notice_reads;
  v jsonb := coalesce(p -> 'values', '{}'::jsonb);
  v_at timestamptz;
  v_status text := nullif(p ->> 'status', '');
begin
  if not app.user_runs_finance(p_by) then raise exception 'Finance or an Admin reads notices' using errcode = '42501'; end if;
  select * into l from toll_notice_read_lines where id = (p ->> 'line')::uuid for update;
  if l.id is null then raise exception 'That line is not there' using errcode = 'P0002'; end if;
  select * into r from toll_notice_reads where id = l.read_id;
  if r.status = 'discarded' then raise exception 'This read was discarded' using errcode = '23514'; end if;
  if l.status in ('imported', 'duplicate') then raise exception 'This line is already imported' using errcode = '23514'; end if;
  if v_status is not null and v_status not in ('pending', 'checked', 'excluded') then raise exception 'A line is checked, excluded or back to pending' using errcode = '22023'; end if;
  if v_status = 'excluded' and nullif(btrim(coalesce(p ->> 'reason', '')), '') is null then
    raise exception 'Say why this line is left out' using errcode = '22023';
  end if;
  if v ? 'occurred_at' then
    begin
      v_at := case when nullif(v ->> 'occurred_at', '') is null then null
                   when (v ->> 'occurred_at') ~ '(Z|[+-][0-9]{2}(:?[0-9]{2})?)$' then (v ->> 'occurred_at')::timestamptz
                   else (v ->> 'occurred_at')::timestamp at time zone 'America/Toronto' end;
    exception when others then raise exception 'Unreadable date and time' using errcode = '22023';
    end;
  end if;
  if v ? 'amount_cents' and v ->> 'amount_cents' is not null and (v ->> 'amount_cents') !~ '^[0-9]+$' then raise exception 'Unreadable amount' using errcode = '22023'; end if;
  if v ? 'fees_cents' and v ->> 'fees_cents' is not null and (v ->> 'fees_cents') !~ '^[0-9]+$' then raise exception 'Unreadable fees' using errcode = '22023'; end if;
  if v ? 'kind' and v ->> 'kind' is not null and v ->> 'kind' not in ('toll_invoice', 'ticket', 'camera_offence', 'parking', 'fine', 'tow', 'impound') then
    raise exception 'Unknown kind' using errcode = '22023';
  end if;
  update toll_notice_read_lines set
    kind = case when v ? 'kind' then nullif(v ->> 'kind', '') else kind end,
    authority = case when v ? 'authority' then nullif(btrim(v ->> 'authority'), '') else authority end,
    notice_number = case when v ? 'notice_number' then nullif(btrim(v ->> 'notice_number'), '') else notice_number end,
    plate = case when v ? 'plate' then nullif(upper(btrim(v ->> 'plate')), '') else plate end,
    transponder = case when v ? 'transponder' then nullif(upper(btrim(v ->> 'transponder')), '') else transponder end,
    occurred_at = case when v ? 'occurred_at' then v_at else occurred_at end,
    time_unknown = case when v ? 'time_unknown' then coalesce((v ->> 'time_unknown')::boolean, false) else time_unknown end,
    place = case when v ? 'place' then nullif(btrim(v ->> 'place'), '') else place end,
    entry = case when v ? 'entry' then nullif(btrim(v ->> 'entry'), '') else entry end,
    exit = case when v ? 'exit' then nullif(btrim(v ->> 'exit'), '') else exit end,
    amount_cents = case when v ? 'amount_cents' then (v ->> 'amount_cents')::bigint else amount_cents end,
    fees_cents = case when v ? 'fees_cents' then (v ->> 'fees_cents')::bigint else fees_cents end,
    due_on = case when v ? 'due_on' then nullif(v ->> 'due_on', '')::date else due_on end,
    edited = edited or v <> '{}'::jsonb,
    status = coalesce(v_status, case when status = 'exception' then 'pending' else status end),
    result_reason = case when v_status = 'excluded' then btrim(p ->> 'reason') when v_status is not null then null else result_reason end,
    checked_by = case when v_status = 'checked' then p_by else checked_by end,
    checked_at = case when v_status = 'checked' then now() else checked_at end
   where id = l.id;
  perform app.toll_read_line_refresh(l.id);
  -- nothing left to fix on a confirmed read: its exceptions task is done
  if r.status = 'confirmed' and not exists (select 1 from toll_notice_read_lines x where x.read_id = r.id and x.status in ('exception', 'pending', 'checked')) then
    update tasks set status = 'done', completed_at = now(), completed_by = p_by, completion_note = 'every line imported or excluded'
     where dedupe_key = 'toll_read_exceptions:' || r.id and status in ('open', 'in_progress', 'waiting');
  end if;
  return (select to_jsonb(x) || jsonb_build_object('vehicle_name', app.vehicle_name(x.vehicle_id)) from toll_notice_read_lines x where x.id = l.id);
end $$;

-- Import the given lines of a read through 0021's import, one batch per issuer and kind; record each line's
-- result; charge renters matched with high confidence when asked. Returns the summary.
create or replace function app.toll_read_import_lines(p_by uuid, p_read uuid, p_lines uuid[], p_charge boolean) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  r toll_notice_reads;
  g record;
  res jsonb;
  x jsonb;
  v_batches uuid[] := '{}';
  v_out jsonb := '[]'::jsonb;
  v_ids uuid[];
  v_charge jsonb;
  n_imp integer := 0; n_dup integer := 0; n_exc integer := 0;
begin
  select * into r from toll_notice_reads where id = p_read for update;
  for g in
    select coalesce(l.kind, r.kind) as kind, coalesce(l.authority, r.authority) as authority,
           jsonb_agg(jsonb_build_object('row_no', l.line_no, 'plate', l.plate, 'transponder', l.transponder,
                                        'occurred_at', to_char(l.occurred_at at time zone 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS"Z"'),
                                        'time_unknown', l.time_unknown, 'amount_cents', l.amount_cents, 'notice_number', l.notice_number,
                                        'place', l.place, 'entry', l.entry, 'exit', l.exit, 'due_on', coalesce(l.due_on, r.due_on),
                                        'note', case when coalesce(l.fees_cents, 0) > 0 then format('Includes %s in fees on the notice', '$' || btrim(to_char(l.fees_cents / 100.0, 'FM999,990.00'))) end,
                                        'ocr_raw', jsonb_build_object('read', r.read_number, 'line_no', l.line_no, 'method', r.method, 'confidence', l.confidence,
                                                                      'fees_cents', l.fees_cents, 'source_text', l.source_text, 'edited', l.edited))
                     order by l.line_no) as rows
      from toll_notice_read_lines l
     where l.read_id = r.id and l.id = any (p_lines)
     group by 1, 2
  loop
    if nullif(btrim(coalesce(g.authority, '')), '') is null then
      update toll_notice_read_lines set status = 'exception', result_reason = 'Issuer missing'
       where read_id = r.id and id = any (p_lines) and coalesce(authority, r.authority) is null;
      n_exc := n_exc + (select count(*) from jsonb_array_elements(g.rows));
      continue;
    end if;
    res := app.import_toll_batch(jsonb_build_object('operator', g.authority, 'kind', g.kind, 'statement_number', r.statement_number,
             'statement_date', r.statement_date, 'due_on', r.due_on, 'document_id', r.document_id, 'profile_id', r.profile_id,
             'confirm_difference', true, 'rows', g.rows), p_by);
    v_batches := v_batches || (res ->> 'batch_id')::uuid;
    for x in select * from jsonb_array_elements(res -> 'results') loop
      update toll_notice_read_lines
         set status = case x ->> 'result' when 'imported' then 'imported' when 'duplicate' then 'duplicate' else 'exception' end,
             result_reason = x ->> 'reason', toll_ticket_id = coalesce((x ->> 'toll_ticket_id')::uuid, toll_ticket_id)
       where read_id = r.id and line_no = (x ->> 'row_no')::integer;
      if x ->> 'result' = 'imported' then n_imp := n_imp + 1; elsif x ->> 'result' = 'duplicate' then n_dup := n_dup + 1; else n_exc := n_exc + 1; end if;
    end loop;
    v_out := v_out || jsonb_build_object('batch_id', res ->> 'batch_id', 'authority', g.authority, 'kind', g.kind, 'imported', res -> 'imported',
                                         'duplicates', res -> 'duplicates', 'invalid', res -> 'invalid', 'matched', res -> 'matched');
  end loop;
  -- renters matched with high confidence: the notice and the administration fee go on a later-charge statement (0021)
  if p_charge then
    select array_agg(t.id) into v_ids from toll_tickets t join toll_notice_read_lines l on l.toll_ticket_id = t.id
     where l.read_id = r.id and l.id = any (p_lines) and l.status = 'imported' and t.status = 'matched' and t.matched_to = 'renter'
       and t.match_confidence = 'high' and t.booking_id is not null and t.charged_at is null;
    if cardinality(v_ids) > 0 then
      v_charge := app.charge_toll_ticket(v_ids, p_by, now());
    end if;
  end if;
  update toll_notice_reads set batch_ids = batch_ids || v_batches where id = r.id;
  return jsonb_build_object('batches', v_out, 'imported', n_imp, 'duplicates', n_dup, 'exceptions', n_exc,
                            'charged', coalesce(cardinality(v_ids), 0), 'charge_result', v_charge);
end $$;

-- Confirm a read: every line checked (or read with enough confidence and nothing missing) is imported;
-- every other line not excluded becomes an exception for Finance. p: read, charge (default: the setting).
create or replace function app.toll_read_confirm(p_by uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  r toll_notice_reads;
  v_go uuid[];
  v_res jsonb;
  v_exc integer;
  v_charge boolean := coalesce((p ->> 'charge')::boolean, (app.settings()).toll_read_auto_charge);
begin
  if not app.user_runs_finance(p_by) then raise exception 'Finance or an Admin confirms a read' using errcode = '42501'; end if;
  select * into r from toll_notice_reads where id = (p ->> 'read')::uuid for update;
  if r.id is null then raise exception 'That read is not there' using errcode = 'P0002'; end if;
  if r.status <> 'in_review' then raise exception 'This read is already %', r.status using errcode = '23514'; end if;
  perform app.toll_read_line_refresh(l.id) from toll_notice_read_lines l where l.read_id = r.id and l.status in ('pending', 'checked');
  select array_agg(l.id order by l.line_no) into v_go from toll_notice_read_lines l
   where l.read_id = r.id and (l.status = 'checked' or (l.status = 'pending' and cardinality(l.problems) = 0));
  update toll_notice_read_lines l set status = 'exception', result_reason = array_to_string(l.problems, '; ')
   where l.read_id = r.id and l.status = 'pending' and cardinality(l.problems) > 0;
  if not exists (select 1 from toll_notice_read_lines l where l.read_id = r.id and l.status <> 'excluded') then
    raise exception 'Every line is excluded: discard the read instead' using errcode = '23514';
  end if;
  v_res := app.toll_read_import_lines(p_by, r.id, coalesce(v_go, '{}'), v_charge);
  select count(*) into v_exc from toll_notice_read_lines l where l.read_id = r.id and l.status = 'exception';
  update toll_notice_reads set status = 'confirmed', confirmed_by = p_by, confirmed_at = now(),
         result = v_res || jsonb_build_object('exceptions', v_exc) where id = r.id;
  update tasks set status = 'done', completed_at = now(), completed_by = p_by, completion_note = 'confirmed'
   where dedupe_key = 'toll_read_review:' || r.id and status in ('open', 'in_progress', 'waiting');
  if v_exc > 0 then
    perform app.raise_task(p_type => 'toll_read_exceptions', p_title => format('%s line(s) of %s were not imported', v_exc, r.read_number),
        p_detail => (select string_agg(format('Line %s: %s', l.line_no, l.result_reason), E'\n' order by l.line_no)
                       from toll_notice_read_lines l where l.read_id = r.id and l.status = 'exception'),
        p_related_table => 'toll_notice_reads', p_related_id => r.id, p_created_by => p_by, p_dedupe => 'toll_read_exceptions:' || r.id,
        p_due_at => app.add_business_days(app.today(), 1)::timestamptz);
  end if;
  return app.toll_read_get(p_by, r.id) || jsonb_build_object('summary', v_res || jsonb_build_object('exceptions', v_exc));
end $$;

-- An exception fixed after the read was confirmed: import that one line.
create or replace function app.toll_read_line_import(p_by uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  l toll_notice_read_lines;
  r toll_notice_reads;
  v_res jsonb;
begin
  if not app.user_runs_finance(p_by) then raise exception 'Finance or an Admin imports a line' using errcode = '42501'; end if;
  select * into l from toll_notice_read_lines where id = (p ->> 'line')::uuid for update;
  if l.id is null then raise exception 'That line is not there' using errcode = 'P0002'; end if;
  select * into r from toll_notice_reads where id = l.read_id;
  if r.status <> 'confirmed' then raise exception 'Confirm the read first' using errcode = '23514'; end if;
  if l.status not in ('exception', 'pending', 'checked') then raise exception 'This line is already %', l.status using errcode = '23514'; end if;
  v_res := app.toll_read_import_lines(p_by, r.id, array[l.id], coalesce((p ->> 'charge')::boolean, (app.settings()).toll_read_auto_charge));
  if not exists (select 1 from toll_notice_read_lines x where x.read_id = r.id and x.status in ('exception', 'pending', 'checked')) then
    update tasks set status = 'done', completed_at = now(), completed_by = p_by, completion_note = 'every line imported or excluded'
     where dedupe_key = 'toll_read_exceptions:' || r.id and status in ('open', 'in_progress', 'waiting');
  end if;
  return v_res || jsonb_build_object('line', (select to_jsonb(x) from toll_notice_read_lines x where x.id = l.id));
end $$;

create or replace function app.toll_read_discard(p_by uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  r toll_notice_reads;
begin
  if not app.user_runs_finance(p_by) then raise exception 'Finance or an Admin discards a read' using errcode = '42501'; end if;
  select * into r from toll_notice_reads where id = (p ->> 'read')::uuid for update;
  if r.id is null then raise exception 'That read is not there' using errcode = 'P0002'; end if;
  if r.status <> 'in_review' then raise exception 'Only a read waiting for review is discarded' using errcode = '23514'; end if;
  if nullif(btrim(coalesce(p ->> 'reason', '')), '') is null then raise exception 'Say why it is discarded' using errcode = '22023'; end if;
  update toll_notice_reads set status = 'discarded', discarded_by = p_by, discarded_at = now(), discard_reason = btrim(p ->> 'reason') where id = r.id;
  update tasks set status = 'cancelled', completed_at = now(), completed_by = p_by, completion_note = 'discarded'
   where dedupe_key in ('toll_read_review:' || r.id, 'toll_read_exceptions:' || r.id) and status in ('open', 'in_progress', 'waiting');
  return jsonb_build_object('id', r.id, 'status', 'discarded');
end $$;

-- The reads waiting for review, the recent ones, and every line still an exception.
create or replace function app.toll_read_queue(p_by uuid) returns jsonb
language plpgsql stable security definer set search_path = public, app as $$
begin
  if not app.user_runs_finance(p_by) then raise exception 'Finance or an Admin reads notices' using errcode = '42501'; end if;
  return jsonb_build_object(
    'reads', coalesce((select jsonb_agg(jsonb_build_object('id', r.id, 'read_number', r.read_number, 'file_name', r.file_name, 'method', r.method,
                          'authority', r.authority, 'kind', r.kind, 'status', r.status, 'created_at', r.created_at, 'confirmed_at', r.confirmed_at,
                          'lines', (select count(*) from toll_notice_read_lines l where l.read_id = r.id),
                          'imported', (select count(*) from toll_notice_read_lines l where l.read_id = r.id and l.status = 'imported'),
                          'exceptions', (select count(*) from toll_notice_read_lines l where l.read_id = r.id and l.status = 'exception'),
                          'low', (select count(*) from toll_notice_read_lines l where l.read_id = r.id and l.status = 'pending' and cardinality(l.problems) > 0))
                        order by (r.status = 'in_review') desc, r.created_at desc)
                       from (select * from toll_notice_reads x where x.status = 'in_review' or x.created_at > now() - interval '60 days'
                              order by x.created_at desc limit 200) r), '[]'::jsonb),
    'exceptions', coalesce((select jsonb_agg(to_jsonb(l) || jsonb_build_object('read_number', r.read_number, 'vehicle_name', app.vehicle_name(l.vehicle_id))
                              order by r.created_at desc, l.line_no)
                             from toll_notice_read_lines l join toll_notice_reads r on r.id = l.read_id
                            where l.status = 'exception' and r.status = 'confirmed'), '[]'::jsonb));
end $$;

-- The reading profiles, for the Admin screen (Finance reads them too).
create or replace function app.toll_profiles(p_by uuid) returns jsonb
language plpgsql stable security definer set search_path = public, app as $$
begin
  if not app.user_runs_finance(p_by) then raise exception 'Finance or an Admin manages profiles' using errcode = '42501'; end if;
  return coalesce((select jsonb_agg(to_jsonb(p) || jsonb_build_object('reads', (select count(*) from toll_notice_reads r where r.profile_id = p.id))
                     order by p.source desc, p.priority, p.name) from toll_import_profiles p), '[]'::jsonb);
end $$;

-- Add or change a reading profile (pdf_text) or a CSV mapping's details. p: id (empty: new), operator, name,
-- source, notice_kind, rules, mapping, date_format, amount_unit, priority, is_active, notes, sample_text.
create or replace function app.toll_profile_upsert(p_by uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  v_id uuid := nullif(p ->> 'id', '')::uuid;
  v_src text := coalesce(nullif(p ->> 'source', ''), 'pdf_text');
  v_rules jsonb := coalesce(p -> 'rules', '{}'::jsonb);
  k text;
begin
  if not app.user_runs_finance(p_by) then raise exception 'Finance or an Admin manages profiles' using errcode = '42501'; end if;
  if nullif(btrim(coalesce(p ->> 'operator', '')), '') is null or nullif(btrim(coalesce(p ->> 'name', '')), '') is null then
    raise exception 'A profile needs the issuer and a name' using errcode = '22023';
  end if;
  if jsonb_typeof(v_rules) <> 'object' then raise exception 'The rules are not readable' using errcode = '22023'; end if;
  if v_src = 'pdf_text' then
    if coalesce(v_rules ->> 'layout', 'auto') not in ('statement', 'single', 'auto') then raise exception 'Layout is statement, single or auto' using errcode = '22023'; end if;
    if v_rules ? 'fields' and jsonb_typeof(v_rules -> 'fields') <> 'object' then raise exception 'Fields are label words per field' using errcode = '22023'; end if;
    for k in select jsonb_object_keys(coalesce(v_rules -> 'fields', '{}'::jsonb)) loop
      if k not in ('statement_number', 'account_number', 'statement_date', 'due_on', 'total', 'authority', 'notice_number', 'plate', 'transponder', 'date', 'time', 'place', 'amount', 'fees') then
        raise exception 'Unknown field "%"', k using errcode = '22023';
      end if;
    end loop;
  end if;
  if v_id is null then
    insert into toll_import_profiles (operator, name, header_signature, mapping, source, notice_kind, rules, date_format, amount_unit, priority, is_active, notes, sample_text, created_by)
    values (btrim(p ->> 'operator'), btrim(p ->> 'name'),
            case when v_src = 'pdf_text' then 'text:' || coalesce(app.slugify(p ->> 'name'), 'profile') || ':' || substr(gen_random_uuid()::text, 1, 6) else coalesce(p ->> 'header_signature', '') end,
            coalesce(p -> 'mapping', '{}'::jsonb), v_src, coalesce(nullif(p ->> 'notice_kind', ''), 'toll_invoice'), v_rules, nullif(p ->> 'date_format', ''),
            coalesce(nullif(p ->> 'amount_unit', ''), 'dollars'), coalesce(nullif(p ->> 'priority', '')::smallint, 100), coalesce((p ->> 'is_active')::boolean, true),
            p ->> 'notes', p ->> 'sample_text', p_by)
    returning id into v_id;
  else
    update toll_import_profiles set operator = btrim(p ->> 'operator'), name = btrim(p ->> 'name'),
           notice_kind = coalesce(nullif(p ->> 'notice_kind', ''), notice_kind),
           rules = case when p ? 'rules' then v_rules else rules end,
           mapping = case when p ? 'mapping' and jsonb_typeof(p -> 'mapping') = 'object' then p -> 'mapping' else mapping end,
           date_format = case when p ? 'date_format' then nullif(p ->> 'date_format', '') else date_format end,
           amount_unit = coalesce(nullif(p ->> 'amount_unit', ''), amount_unit),
           priority = coalesce(nullif(p ->> 'priority', '')::smallint, priority),
           is_active = coalesce((p ->> 'is_active')::boolean, is_active),
           notes = case when p ? 'notes' then p ->> 'notes' else notes end,
           sample_text = case when p ? 'sample_text' then p ->> 'sample_text' else sample_text end
     where id = v_id;
    if not found then raise exception 'That profile is not there' using errcode = 'P0002'; end if;
  end if;
  return (select to_jsonb(x) from toll_import_profiles x where x.id = v_id);
end $$;

-- ================================================================ 4. licence plates on listing photos
alter table vehicle_photos
  add column plate_status text not null default 'unchecked' check (plate_status in ('unchecked', 'covered', 'not_visible')),
  add column plate_boxes jsonb not null default '[]'::jsonb check (jsonb_typeof(plate_boxes) = 'array'),
  add column plate_style text check (plate_style in ('cover', 'pixelate', 'blur')),
  add column plate_checked_by uuid references users (id),
  add column plate_checked_at timestamptz,
  add column uncovered_path text,
  add column plate_suggestion jsonb;
comment on column vehicle_photos.plate_status is 'unchecked; covered (the public file has the plate covered); not_visible (no plate to cover). Publishing waits for every public photo (0042)';
comment on column vehicle_photos.uncovered_path is 'The public file as it was before the plate was covered, now kept in the private vehicle-originals bucket';

-- What the plate editor needs for one photo, and whether this person may change it.
create or replace function app.photo_plate_context(p_by uuid, p_photo uuid) returns jsonb
language plpgsql stable security definer set search_path = public, app as $$
begin
  if not (app.user_is_admin(p_by) or app.user_va_has(p_by, 'fleet', 'cs')) then
    raise exception 'Fleet, customer service or an Admin edits listing photos' using errcode = '42501';
  end if;
  return (select jsonb_build_object('id', ph.id, 'vehicle_id', ph.vehicle_id, 'shot_type', ph.shot_type, 'shot_label', st.label,
            'is_public_shot', coalesce(st.is_public, true), 'processed_path', ph.processed_path, 'original_path', ph.original_path,
            'variants', ph.variants, 'width', ph.width, 'height', ph.height, 'status', ph.status, 'plate_status', ph.plate_status,
            'plate_boxes', ph.plate_boxes, 'plate_style', ph.plate_style, 'plate_suggestion', ph.plate_suggestion,
            'replaced', ph.replaced_at is not null,
            'cover_text', coalesce(nullif(btrim(ps.plate_cover_text), ''), (select s.brand_name from site_settings s limit 1), 'CarmaCars'),
            'default_style', ps.plate_cover_style, 'detect', ps.plate_detect_enabled and ps.ai_vision_enabled)
    from vehicle_photos ph left join listing_shot_types st on st.code = ph.shot_type cross join app.settings() ps
   where ph.id = p_photo);
end $$;

-- Record the plate decision. p: photo, status (covered | not_visible | unchecked), boxes [{x, y, w, h} as fractions],
-- style, processed_path, variants, uncovered_path, width, height, byte_size (the new public file, written first by the server).
create or replace function app.photo_plate_record(p_by uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  ph vehicle_photos;
  v_status text := p ->> 'status';
  b jsonb;
begin
  if not (app.user_is_admin(p_by) or app.user_va_has(p_by, 'fleet', 'cs')) then
    raise exception 'Fleet, customer service or an Admin edits listing photos' using errcode = '42501';
  end if;
  select * into ph from vehicle_photos where id = (p ->> 'photo')::uuid for update;
  if ph.id is null or ph.replaced_at is not null then raise exception 'That photo is not current' using errcode = 'P0002'; end if;
  if v_status not in ('covered', 'not_visible', 'unchecked') then raise exception 'A plate is covered, not visible or not checked' using errcode = '22023'; end if;
  if v_status = 'covered' then
    if ph.processed_path is null then raise exception 'The photo is still being processed' using errcode = '23514'; end if;
    if jsonb_typeof(p -> 'boxes') is distinct from 'array' or jsonb_array_length(p -> 'boxes') = 0 then
      raise exception 'Draw at least one box over the plate' using errcode = '22023';
    end if;
    for b in select * from jsonb_array_elements(p -> 'boxes') loop
      if (b ->> 'x')::numeric < 0 or (b ->> 'y')::numeric < 0 or (b ->> 'w')::numeric <= 0 or (b ->> 'h')::numeric <= 0
         or (b ->> 'x')::numeric + (b ->> 'w')::numeric > 1.0001 or (b ->> 'y')::numeric + (b ->> 'h')::numeric > 1.0001 then
        raise exception 'A box is outside the photo' using errcode = '22023';
      end if;
    end loop;
    if coalesce(p ->> 'style', '') not in ('cover', 'pixelate', 'blur') then raise exception 'Choose cover, pixelate or blur' using errcode = '22023'; end if;
    if coalesce(p ->> 'processed_path', '') !~ ('^vehicles/' || ph.vehicle_id || '/') then raise exception 'The covered file is not this car''s' using errcode = '22023'; end if;
  end if;
  update vehicle_photos set
    plate_status = v_status,
    plate_boxes = case when v_status = 'covered' then p -> 'boxes' else '[]'::jsonb end,
    plate_style = case when v_status = 'covered' then p ->> 'style' end,
    plate_checked_by = case when v_status = 'unchecked' then null else p_by end,
    plate_checked_at = case when v_status = 'unchecked' then null else now() end,
    processed_path = case when v_status = 'covered' then p ->> 'processed_path' else processed_path end,
    variants = case when v_status = 'covered' then coalesce(p -> 'variants', '[]'::jsonb) else variants end,
    width = case when v_status = 'covered' and (p ->> 'width') ~ '^[0-9]+$' then (p ->> 'width')::integer else width end,
    height = case when v_status = 'covered' and (p ->> 'height') ~ '^[0-9]+$' then (p ->> 'height')::integer else height end,
    byte_size = case when v_status = 'covered' and (p ->> 'byte_size') ~ '^[0-9]+$' then (p ->> 'byte_size')::bigint else byte_size end,
    mime_type = case when v_status = 'covered' then 'image/jpeg' else mime_type end,
    uncovered_path = case when v_status = 'covered' then coalesce(uncovered_path, p ->> 'uncovered_path') else uncovered_path end
   where id = ph.id;
  return jsonb_build_object('photo', (select to_jsonb(x) from vehicle_photos x where x.id = ph.id), 'previous_path', ph.processed_path, 'previous_variants', ph.variants);
end $$;

create or replace function app.photo_plate_suggestion(p_by uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
begin
  if not (app.user_is_admin(p_by) or app.user_va_has(p_by, 'fleet', 'cs')) then
    raise exception 'Fleet, customer service or an Admin edits listing photos' using errcode = '42501';
  end if;
  update vehicle_photos set plate_suggestion = p -> 'suggestion' where id = (p ->> 'photo')::uuid;
  return jsonb_build_object('ok', true);
end $$;

-- The public photos of a car whose plate nobody checked yet.
create or replace function app.listing_plate_problems(p_vehicle uuid) returns text[]
language sql stable security definer set search_path = public, app as $$
  select coalesce(array_agg(coalesce(st.label, ph.shot_type) order by st.seq, ph.sort_order), '{}')
    from vehicle_photos ph join listing_shot_types st on st.code = ph.shot_type
   where ph.vehicle_id = p_vehicle and ph.replaced_at is null and ph.status in ('processed', 'approved') and st.is_public
     and ph.processed_path is not null and ph.plate_status = 'unchecked'
$$;

-- The plate check comes last, after every check of 0022 and 0040 passed: the publish runs, and if a photo it made
-- public has no plate decision the whole publish is undone with the list of photos (the caller's transaction, or the
-- listing pipeline's own savepoint, which keeps the reason on the intake).
alter function app.publish_listing(uuid, uuid) rename to publish_listing_0040;
create or replace function app.publish_listing(p_vehicle uuid, p_by uuid) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  v_out jsonb;
  v_open text[];
begin
  v_out := app.publish_listing_0040(p_vehicle, p_by);
  if (app.settings()).listing_plate_check_required then
    select array_agg(coalesce(st.label, ph.shot_type) order by st.seq, ph.sort_order) into v_open
      from vehicle_photos ph join listing_shot_types st on st.code = ph.shot_type
     where ph.vehicle_id = p_vehicle and ph.replaced_at is null and ph.status = 'approved' and ph.is_public and st.is_public
       and ph.processed_path is not null and ph.plate_status = 'unchecked';
    if cardinality(v_open) > 0 then
      raise exception 'Cover the licence plate or mark it not visible on every public photo first: %', array_to_string(v_open, ', ') using errcode = '23514';
    end if;
  end if;
  return v_out;
end $$;

-- ================================================================ 5. official ServiceOntario PDFs
alter table pdf_templates
  add column field_names jsonb not null default '[]'::jsonb check (jsonb_typeof(field_names) = 'array'),
  add column file_name text,
  add column mapped_by uuid references users (id),
  add column mapped_at timestamptz;
comment on column pdf_templates.field_names is 'The fillable fields read from the official PDF: [{name, type text|checkbox|dropdown|radio|signature|button, options}]';

-- Everything a registry form can take, with a label (the paths of app.registry_context).
create or replace function app.registry_sources() returns jsonb
language sql immutable as $$
  select jsonb_agg(jsonb_build_object('path', s.path, 'label', s.label, 'section', s.section) order by s.ord)
    from (values
      (1, 'owner.legal_name', 'Owner: full legal name', 'Owner'), (2, 'owner.last_name', 'Owner: last name', 'Owner'),
      (3, 'owner.first_name', 'Owner: first name', 'Owner'), (4, 'owner.middle_name', 'Owner: middle name', 'Owner'),
      (5, 'owner.address_line1', 'Owner: street address', 'Owner'), (6, 'owner.address_line2', 'Owner: apartment or unit', 'Owner'),
      (7, 'owner.city', 'Owner: city', 'Owner'), (8, 'owner.province', 'Owner: province', 'Owner'), (9, 'owner.postal_code', 'Owner: postal code', 'Owner'),
      (10, 'owner.full_address', 'Owner: full address on one line', 'Owner'), (11, 'owner.mailing_address', 'Owner: mailing address', 'Owner'),
      (12, 'owner.phone', 'Owner: phone', 'Owner'), (13, 'owner.email', 'Owner: email', 'Owner'),
      (14, 'owner.licence_number', 'Owner: driver''s licence number', 'Owner'), (15, 'owner.licence_province', 'Owner: licence province', 'Owner'),
      (16, 'owner.date_of_birth', 'Owner: date of birth', 'Owner'), (17, 'owner.is_individual', 'Owner is an individual (yes or no)', 'Owner'),
      (18, 'owner.is_corporation', 'Owner is a corporation (yes or no)', 'Owner'),
      (20, 'corporation.name', 'Corporation: name', 'Corporation'), (21, 'corporation.number', 'Corporation: number', 'Corporation'),
      (22, 'corporation.rin', 'Corporation: RIN', 'Corporation'), (23, 'corporation.signing_officer_name', 'Corporation: signing officer', 'Corporation'),
      (24, 'corporation.signing_officer_title', 'Corporation: signing officer''s title', 'Corporation'), (25, 'corporation.applies', 'A corporation is on the form (yes or no)', 'Corporation'),
      (30, 'vehicle.vin', 'Vehicle: VIN', 'Vehicle'), (31, 'vehicle.plate', 'Vehicle: plate', 'Vehicle'), (32, 'vehicle.year', 'Vehicle: year', 'Vehicle'),
      (33, 'vehicle.make', 'Vehicle: make', 'Vehicle'), (34, 'vehicle.model', 'Vehicle: model', 'Vehicle'), (35, 'vehicle.colour', 'Vehicle: colour', 'Vehicle'),
      (36, 'vehicle.body_type', 'Vehicle: body type', 'Vehicle'), (37, 'vehicle.fuel', 'Vehicle: fuel', 'Vehicle'), (38, 'vehicle.odometer_km', 'Vehicle: odometer (km)', 'Vehicle'),
      (39, 'vehicle.name', 'Vehicle: year, make and model', 'Vehicle'),
      (40, 'registrant.legal_name', 'CarmaCars company: legal name', 'Registrant'), (41, 'registrant.trade_name', 'CarmaCars company: operating name', 'Registrant'),
      (42, 'registrant.rin', 'CarmaCars company: RIN', 'Registrant'), (43, 'registrant.address', 'CarmaCars company: address', 'Registrant'),
      (44, 'registrant.phone', 'CarmaCars company: phone', 'Registrant'), (45, 'registrant.email', 'CarmaCars company: email', 'Registrant'),
      (46, 'registrant.signing_officer_name', 'CarmaCars company: signing officer', 'Registrant'), (47, 'registrant.signing_officer_title', 'CarmaCars company: signing officer''s title', 'Registrant'),
      (50, 'lender.name', 'Lender or lease company: name', 'Lender'), (51, 'lender.account', 'Lender or lease company: account', 'Lender'),
      (52, 'lender.applies', 'A lender or lease company is on the form (yes or no)', 'Lender'),
      (60, 'method.label', 'Onboarding method', 'Method'), (61, 'method.registered_as', 'How CarmaCars is registered', 'Method'),
      (62, 'method.is_lease', 'Lease (yes or no)', 'Method'), (63, 'method.is_co_registrant', 'Co-registrant (yes or no)', 'Method'),
      (64, 'method.is_transfer', 'Transfer (yes or no)', 'Method'),
      (70, 'today', 'Today''s date', 'Other')) s(ord, path, label, section)
$$;

-- The values of one template's mapped fields for one vehicle, without storing a fill (the Admin's preview).
create or replace function app.form_field_values(p_template uuid, p_vehicle uuid) returns jsonb
language plpgsql stable security definer set search_path = public, app as $$
declare
  ctx jsonb := app.registry_context(p_vehicle);
  t pdf_templates;
  r record;
  v_spec jsonb;
  v_val text;
  v_values jsonb := '{}'::jsonb;
begin
  select * into t from pdf_templates where id = p_template;
  for r in select key, value from jsonb_each(t.field_map) loop
    v_spec := case when jsonb_typeof(r.value) = 'string' then jsonb_build_object('source', r.value #>> '{}') else r.value end;
    if v_spec ? 'when' and not coalesce(app.context_value(ctx, v_spec ->> 'when')::boolean, false) then continue; end if;
    v_val := app.apply_transform(app.context_value(ctx, v_spec ->> 'source'), v_spec ->> 'transform');
    if v_spec ->> 'type' = 'checkbox' then v_val := case when lower(coalesce(v_val, 'false')) in ('true', 't', 'yes') then 'Yes' else 'Off' end; end if;
    v_values := v_values || jsonb_build_object(r.key, v_val);
  end loop;
  return v_values;
end $$;

-- Admin > Settings > Forms: every registry form, its current template, fields and mapping, and what the owners have.
create or replace function app.form_templates(p_by uuid) returns jsonb
language plpgsql stable security definer set search_path = public, app as $$
begin
  perform app.assert_admin(p_by);
  return jsonb_build_object(
    'forms', coalesce((select jsonb_agg(jsonb_build_object('form_code', c.form_code,
                 'current', (select to_jsonb(t) - 'field_map' || jsonb_build_object('field_map', t.field_map, 'mapped_by_name', (select u.full_name from users u where u.id = t.mapped_by),
                                                                                    'verified_by_name', (select u.full_name from users u where u.id = t.verified_by))
                               from pdf_templates t where t.form_code = c.form_code and t.is_current),
                 'versions', (select count(*) from pdf_templates t where t.form_code = c.form_code),
                 'fills', (select jsonb_build_object('pdf', count(*) filter (where g.mode = 'pdf'), 'data_sheet', count(*) filter (where g.mode = 'data_sheet'))
                             from government_form_fills g where g.form_code = c.form_code and g.superseded_at is null)) order by c.form_code)
                       from (select distinct form_code from pdf_templates) c), '[]'::jsonb),
    'sources', app.registry_sources(),
    'transforms', jsonb_build_array('upper', 'lower', 'postal', 'phone', 'yesno', 'date:YYYY-MM-DD', 'date:DD/MM/YYYY', 'date:MM/DD/YYYY', 'date:YYYY', 'date:MM', 'date:DD'),
    'vehicles', coalesce((select jsonb_agg(jsonb_build_object('id', v.id, 'name', app.vehicle_name(v.id), 'owner', o.legal_name) order by o.legal_name, v.plate)
                           from vehicles v join owners o on o.id = v.owner_id where not coalesce(v.is_sample, false)), '[]'::jsonb));
end $$;

-- A new official PDF for a form (the file is already stored by the server). The fields read in the browser come
-- with it; a field of the same name keeps its mapping from the version before. The new version is current but
-- unchecked: owners keep the data sheet until an Admin checks the mapping.
create or replace function app.form_template_upload(p_by uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  cur pdf_templates;
  v_id uuid;
  v_map jsonb := '{}'::jsonb;
  f jsonb;
begin
  perform app.assert_admin(p_by);
  if coalesce(p ->> 'form_code', '') = '' or not exists (select 1 from pdf_templates where form_code = p ->> 'form_code') then
    raise exception 'Unknown form' using errcode = 'P0002';
  end if;
  if coalesce(p ->> 'file_key', '') !~ '^forms/templates/' then raise exception 'Unknown file' using errcode = '22023'; end if;
  if jsonb_typeof(p -> 'fields') is distinct from 'array' then raise exception 'No fields were read from the PDF' using errcode = '22023'; end if;
  if jsonb_array_length(p -> 'fields') = 0 then
    raise exception 'This PDF has no fillable fields. Upload the fillable version of the form (ServiceOntario publishes most forms as fillable PDFs)' using errcode = '22023';
  end if;
  select * into cur from pdf_templates where form_code = p ->> 'form_code' and is_current for update;
  for f in select * from jsonb_array_elements(p -> 'fields') loop
    if cur.field_map ? (f ->> 'name') then v_map := v_map || jsonb_build_object(f ->> 'name', cur.field_map -> (f ->> 'name')); end if;
  end loop;
  update pdf_templates set is_current = false where form_code = p ->> 'form_code' and is_current;
  insert into pdf_templates (form_code, version, title, kind, file_key, sha256, page_count, field_map, verified, is_current, notes, uploaded_by, field_names, file_name)
  values (p ->> 'form_code', 'official-' || to_char(now() at time zone 'America/Toronto', 'YYYYMMDD') || '-' || ((select count(*) from pdf_templates x where x.form_code = p ->> 'form_code') + 1), coalesce(nullif(p ->> 'title', ''), cur.title), 'acroform',
          p ->> 'file_key', p ->> 'sha256', nullif(p ->> 'page_count', '')::integer, v_map, false, true, p ->> 'notes', p_by, p -> 'fields', left(p ->> 'file_name', 200))
  returning id into v_id;
  return (select to_jsonb(t) from pdf_templates t where t.id = v_id);
end $$;

-- Save the mapping of a template's fields; with verify, the template is checked and every owner's form that is
-- not signed or filed yet is filled again from it (the official PDF replaces the data sheet).
create or replace function app.form_template_map(p_by uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  t pdf_templates;
  v_map jsonb := coalesce(p -> 'field_map', '{}'::jsonb);
  r record;
  v_names text[];
  v_paths text[] := (select array_agg(x ->> 'path') from jsonb_array_elements(app.registry_sources()) x);
  n integer := 0;
  g record;
begin
  perform app.assert_admin(p_by);
  select * into t from pdf_templates where id = (p ->> 'template')::uuid for update;
  if t.id is null then raise exception 'That template is not there' using errcode = 'P0002'; end if;
  if not t.is_current then raise exception 'Only the current version of a form is mapped' using errcode = '23514'; end if;
  if jsonb_typeof(v_map) <> 'object' then raise exception 'The mapping is not readable' using errcode = '22023'; end if;
  select array_agg(x ->> 'name') into v_names from jsonb_array_elements(t.field_names) x;
  for r in select key, value from jsonb_each(v_map) loop
    if not (r.key = any (coalesce(v_names, '{}'))) then raise exception 'The PDF has no field "%"', r.key using errcode = '22023'; end if;
    if jsonb_typeof(r.value) <> 'object' then raise exception 'Field "%": the mapping is not readable', r.key using errcode = '22023'; end if;
    if coalesce(r.value ->> 'type', 'text') not in ('text', 'checkbox', 'signature', 'dropdown', 'radio') then
      raise exception 'Field "%": unknown type', r.key using errcode = '22023';
    end if;
    if r.value ->> 'type' is distinct from 'signature' and not ((r.value ->> 'source') = any (v_paths)) then
      raise exception 'Field "%": choose what goes in it', r.key using errcode = '22023';
    end if;
    if r.value ? 'when' and not ((r.value ->> 'when') = any (v_paths)) then raise exception 'Field "%": unknown condition', r.key using errcode = '22023'; end if;
    if nullif(r.value ->> 'transform', '') is not null and (r.value ->> 'transform') not in ('upper', 'lower', 'postal', 'phone', 'yesno', 'money')
       and (r.value ->> 'transform') !~ '^date:[YMD/ -]+$' then
      raise exception 'Field "%": unknown format', r.key using errcode = '22023';
    end if;
  end loop;
  if coalesce((p ->> 'verify')::boolean, false) and not exists (select 1 from jsonb_each(v_map) e where e.value ->> 'type' is distinct from 'signature') then
    raise exception 'Map at least one field before the form is used for owners' using errcode = '23514';
  end if;
  update pdf_templates set field_map = v_map, mapped_by = p_by, mapped_at = now(),
         verified = coalesce((p ->> 'verify')::boolean, false) and file_key is not null,
         verified_by = case when coalesce((p ->> 'verify')::boolean, false) then p_by end,
         verified_at = case when coalesce((p ->> 'verify')::boolean, false) then now() end
   where id = t.id;
  if coalesce((p ->> 'verify')::boolean, false) then
    for g in select f.vehicle_id from government_form_fills f where f.form_code = t.form_code and f.superseded_at is null and f.status not in ('signed', 'filed') loop
      perform app.fill_government_form(g.vehicle_id, t.form_code, p_by);
      n := n + 1;
    end loop;
  end if;
  return (select to_jsonb(x) from pdf_templates x where x.id = t.id) || jsonb_build_object('refilled', n);
end $$;

-- The Admin's preview: the template file and the values for one vehicle.
create or replace function app.form_template_preview(p_by uuid, p jsonb) returns jsonb
language plpgsql stable security definer set search_path = public, app as $$
declare
  t pdf_templates;
begin
  perform app.assert_admin(p_by);
  select * into t from pdf_templates where id = (p ->> 'template')::uuid;
  if t.id is null or t.file_key is null then raise exception 'That template has no file' using errcode = 'P0002'; end if;
  return jsonb_build_object('file_key', t.file_key, 'form_code', t.form_code, 'field_map', t.field_map,
    'values', case when nullif(p ->> 'vehicle', '') is not null then app.form_field_values(t.id, (p ->> 'vehicle')::uuid) else '{}'::jsonb end);
end $$;

-- The owner's official form: the template and the filled values (only a fill made from a checked template).
create or replace function app.owner_form_official(p_by uuid, p_fill uuid) returns jsonb
language plpgsql stable security definer set search_path = public, app as $$
declare
  v_owner uuid := app.portal_owner_id(p_by);
begin
  if v_owner is null then raise exception 'This account is not an owner account' using errcode = '42501'; end if;
  return (select jsonb_build_object('id', g.id, 'form_code', g.form_code, 'title', t.title, 'vehicle_id', g.vehicle_id, 'vehicle_name', app.vehicle_name(g.vehicle_id),
            'status', g.status, 'missing', to_jsonb(g.missing), 'file_key', t.file_key, 'field_values', g.field_values, 'field_map', t.field_map,
            'signed_document_id', g.document_id, 'owner_name', (select o.legal_name from owners o where o.id = g.owner_id))
    from government_form_fills g join pdf_templates t on t.id = g.pdf_template_id
   where g.id = p_fill and g.owner_id = v_owner and g.superseded_at is null and g.mode = 'pdf' and t.file_key is not null);
end $$;

-- The owner signed the official form on screen: the signed PDF (stored by the server) is filed and the form is signed.
create or replace function app.owner_form_signed(p_by uuid, p_fill uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  g government_form_fills;
  v_doc uuid;
begin
  select * into g from government_form_fills where id = p_fill and owner_id = app.portal_owner_id(p_by) and superseded_at is null and mode = 'pdf';
  if g.id is null then raise exception 'That form is not yours to sign' using errcode = '42501'; end if;
  if g.status not in ('ready', 'printed') then
    raise exception '%', case when g.status = 'draft' then 'Some values are still missing: ' || array_to_string(g.missing, ', ') else 'This form is already ' || g.status end using errcode = '23514';
  end if;
  if coalesce(p ->> 'storage_path', '') !~ ('^owners/' || g.owner_id || '/') then raise exception 'Unknown file' using errcode = '22023'; end if;
  insert into documents (kind, title, storage_bucket, storage_path, mime_type, sha256, uploaded_by, owner_id, vehicle_id)
  values ('registry_form', g.form_code || ' signed', 'agreements', p ->> 'storage_path', 'application/pdf', p ->> 'sha256', p_by, g.owner_id, g.vehicle_id)
  returning id into v_doc;
  perform app.set_government_form_status(g.id, 'signed', p_by, p ->> 'storage_path', v_doc);
  return jsonb_build_object('id', g.id, 'status', 'signed', 'document_id', v_doc);
end $$;

-- The owner's list of forms shows how each one is offered (0029's list, with the template's checked state).
create or replace function app.owner_portal_forms(p_by uuid) returns jsonb
language sql stable security definer set search_path = public, app as $$
  select coalesce(jsonb_agg(jsonb_build_object('id', g.id, 'form_code', g.form_code, 'title', t.title, 'vehicle_id', g.vehicle_id,
           'vehicle_name', app.vehicle_name(g.vehicle_id), 'mode', g.mode, 'status', g.status, 'missing', to_jsonb(g.missing),
           'data_sheet', g.data_sheet, 'has_pdf', g.file_key is not null, 'generated_at', g.generated_at,
           'official', g.mode = 'pdf' and t.file_key is not null, 'signed_document_id', g.document_id)
           order by g.vehicle_id, g.form_code), '[]'::jsonb)
    from government_form_fills g join pdf_templates t on t.id = g.pdf_template_id
   where g.owner_id = app.portal_owner_id(p_by) and g.superseded_at is null
$$;

-- ================================================================ 6. one turnaround between trips
-- The turnaround of a car: its own minutes, else Program settings (turnaround_buffer_minutes, 0025).
create or replace function app.turnaround_minutes(p_vehicle uuid) returns integer
language sql stable security definer set search_path = public, app as $$
  select greatest(coalesce((select v.turnaround_block_minutes from vehicles v where v.id = p_vehicle), (app.settings()).turnaround_buffer_minutes, 0), 0)
$$;

-- 0040's block after a trip, now as long as the car's turnaround (and only while the block is switched on).
create or replace function app.sync_turnaround_block(p_booking uuid) returns uuid
language plpgsql security definer set search_path = public, app as $$
declare
  b bookings;
  k vehicle_calendar_blocks;
  v_min integer;
  v_start timestamptz;
  v_end timestamptz;
  v_next timestamptz;
begin
  select * into b from bookings where id = p_booking;
  select * into k from vehicle_calendar_blocks where booking_id = p_booking and source = 'turnaround';
  if b.id is null then return null; end if;
  if k.id is not null and k.removed_at is not null then return k.id; end if;
  if b.status = 'closed' or (b.status = 'returned' and k.id is not null and k.ends_at <= now()) then return k.id; end if;
  v_min := case when (app.settings()).turnaround_block_enabled then app.turnaround_minutes(b.vehicle_id) else 0 end;
  if b.status not in ('confirmed', 'on_rent', 'returned') or not b.blocks_calendar or v_min <= 0 then
    if k.id is not null then delete from vehicle_calendar_blocks where id = k.id; end if;
    return null;
  end if;
  v_start := case when b.status = 'returned' then coalesce(b.checked_in_at, b.return_at) else greatest(b.return_at, coalesce(b.checked_in_at, b.return_at)) end;
  v_end := v_start + make_interval(mins => v_min);
  select min(x.pickup_at) into v_next from bookings x
   where x.vehicle_id = b.vehicle_id and x.id <> b.id and x.blocks_calendar and x.status in ('confirmed', 'on_rent')
     and x.pickup_at >= b.pickup_at and x.pickup_at < v_end;
  if v_next is not null then v_end := least(v_end, v_next); end if;
  if v_end <= v_start then
    if k.id is not null then delete from vehicle_calendar_blocks where id = k.id; end if;
    return null;
  end if;
  if k.id is null then
    insert into vehicle_calendar_blocks (vehicle_id, reason, starts_at, ends_at, note, booking_id, source)
    values (b.vehicle_id, 'cleaning', v_start, v_end, 'Cleaning after booking ' || b.booking_number, b.id, 'turnaround')
    returning id into k.id;
  elsif (k.vehicle_id, k.starts_at, k.ends_at) is distinct from (b.vehicle_id, v_start, v_end) then
    update vehicle_calendar_blocks set vehicle_id = b.vehicle_id, starts_at = v_start, ends_at = v_end,
           note = 'Cleaning after booking ' || b.booking_number where id = k.id;
  end if;
  return k.id;
end $$;

-- A new turnaround in Program settings moves the blocks of the trips still ahead.
create or replace function app.program_settings_turnaround_resync() returns trigger
language plpgsql security definer set search_path = public, app as $$
declare r record;
begin
  for r in select id from bookings where status in ('confirmed', 'on_rent') and blocks_calendar and return_at > now() - interval '1 day' loop
    perform app.sync_turnaround_block(r.id);
  end loop;
  return null;
end $$;
create trigger program_settings_turnaround_resync after insert or update of turnaround_buffer_minutes, turnaround_block_enabled, effective_from on program_settings
  for each statement execute function app.program_settings_turnaround_resync();

-- The time a trip holds around itself: the turnaround before its pickup, and after its return the turnaround
-- unless its cleaning block holds that time (a block staff removed frees it). The two never add up.
create or replace function app.vehicle_is_available(p_vehicle uuid, p_from timestamptz, p_to timestamptz,
                                                    p_ignore_booking uuid default null)
returns boolean language plpgsql stable security definer set search_path = public, app as $$
declare
  v_turn interval := make_interval(mins => app.turnaround_minutes(p_vehicle));
begin
  if p_vehicle is null or p_from is null or p_to is null or p_to <= p_from then
    return false;
  end if;
  return not exists (
           select 1 from bookings b
            where b.vehicle_id = p_vehicle and b.blocks_calendar and b.status in ('confirmed', 'on_rent')
              and (p_ignore_booking is null or b.id <> p_ignore_booking)
              and b.pickup_at - v_turn < p_to
              and b.return_at + case when exists (select 1 from vehicle_calendar_blocks k where k.booking_id = b.id and k.source = 'turnaround')
                                     then interval '0' else v_turn end > p_from)
     and not exists (
           select 1 from vehicle_calendar_blocks c
            where c.vehicle_id = p_vehicle and c.removed_at is null
              and (p_ignore_booking is null or c.booking_id is distinct from p_ignore_booking)
              and c.starts_at < p_to and (c.ends_at is null or c.ends_at > p_from));
end $$;

-- The public calendar with the same rule (0016's function, the turnaround per car and held once).
create or replace function app.public_vehicle_calendar(p_vehicle uuid, p_from date, p_to date)
returns table (unavailable_from timestamptz, unavailable_to timestamptz, first_date date, last_date date)
language plpgsql stable security definer set search_path = public, app as $$
declare
  v_turn interval := make_interval(mins => app.turnaround_minutes(p_vehicle));
  v_window tstzrange;
begin
  if p_from is null or p_to is null or p_to < p_from or p_to - p_from > 366 then
    raise exception 'Ask for a range of 1 to 366 days' using errcode = '22023';
  end if;
  if not exists (select 1 from public_vehicle_listings l where l.vehicle_id = p_vehicle) then
    return;
  end if;
  v_window := tstzrange(app.local_midnight(p_from), app.local_midnight(p_to + 1), '[)');
  return query
    with stays as (
      select tstzrange(b.pickup_at - v_turn,
                       b.return_at + case when exists (select 1 from vehicle_calendar_blocks k where k.booking_id = b.id and k.source = 'turnaround')
                                          then interval '0' else v_turn end, '[)') as r
        from bookings b
       where b.vehicle_id = p_vehicle and b.blocks_calendar and b.status in ('confirmed', 'on_rent')),
    busy as (
      select s.r * v_window as r from stays s where s.r && v_window
      union all
      select tstzrange(c.starts_at, c.ends_at, '[)') * v_window
        from vehicle_calendar_blocks c
       where c.vehicle_id = p_vehicle and c.removed_at is null
         and tstzrange(c.starts_at, c.ends_at, '[)') && v_window),
    merged as (select unnest(range_agg(r)) as r from busy where not isempty(r))
    select lower(m.r), upper(m.r), app.local_date(lower(m.r)), app.local_date(upper(m.r) - interval '1 microsecond')
      from merged m order by 1;
end $$;

-- ================================================================ 7. the door: names of this migration
create or replace function app.ops42(p_user uuid, p_call text, p_name text, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
begin
  case p_name
  -- toll reading
  when 'toll_read_context' then return app.toll_read_context(p_user);
  when 'toll_read_document' then return app.toll_read_document(p_user, p);
  when 'toll_read_save' then return app.toll_read_save(p_user, p);
  when 'toll_read' then return app.toll_read_get(p_user, (p ->> 'id')::uuid);
  when 'toll_read_file' then
    if not app.user_runs_finance(p_user) then raise exception 'Not permitted' using errcode = '42501'; end if;
    return (select app.document_file(r.document_id) from toll_notice_reads r where r.id = (p ->> 'id')::uuid);
  when 'toll_read_line' then return app.toll_read_line_save(p_user, p);
  when 'toll_read_confirm' then return app.toll_read_confirm(p_user, p);
  when 'toll_read_line_import' then return app.toll_read_line_import(p_user, p);
  when 'toll_read_discard' then return app.toll_read_discard(p_user, p);
  when 'toll_read_queue' then return app.toll_read_queue(p_user);
  when 'toll_profiles' then return app.toll_profiles(p_user);
  when 'toll_profile_upsert' then return app.toll_profile_upsert(p_user, p);
  -- the vision model
  when 'ai_vision_gate' then return app.ai_vision_gate(p_user, p ->> 'purpose');
  when 'ai_call_record' then return app.ai_call_record(p_user, p);
  -- plates
  when 'photo_plate_context' then return app.photo_plate_context(p_user, (p ->> 'photo')::uuid);
  when 'photo_plate_record' then return app.photo_plate_record(p_user, p);
  when 'photo_plate_suggestion' then return app.photo_plate_suggestion(p_user, p);
  -- official forms
  when 'form_templates' then return app.form_templates(p_user);
  when 'form_template_upload' then return app.form_template_upload(p_user, p);
  when 'form_template_map' then return app.form_template_map(p_user, p);
  when 'form_template_preview' then return app.form_template_preview(p_user, p);
  else
    raise exception 'Unknown action %', p_name using errcode = '22023';
  end case;
end $$;

alter function app.door(uuid, text, text, text, jsonb) rename to door_0040;
create or replace function app.door(p_user uuid, p_aal text, p_call text, p_name text, p jsonb default '{}'::jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
begin
  if p_call in ('ops_read', 'ops_do')
     and p_name in ('toll_read_context', 'toll_read_document', 'toll_read_save', 'toll_read', 'toll_read_file', 'toll_read_line', 'toll_read_confirm',
                    'toll_read_line_import', 'toll_read_discard', 'toll_read_queue', 'toll_profiles', 'toll_profile_upsert', 'ai_vision_gate', 'ai_call_record',
                    'photo_plate_context', 'photo_plate_record', 'photo_plate_suggestion', 'form_templates', 'form_template_upload', 'form_template_map',
                    'form_template_preview') then
    perform app.door_begin(p_user, p_aal);
    -- reads never change anything
    if p_call = 'ops_read' and p_name not in ('toll_read_context', 'toll_read', 'toll_read_file', 'toll_read_queue', 'toll_profiles', 'ai_vision_gate',
                                              'photo_plate_context', 'form_templates', 'form_template_preview') then
      raise exception 'Unknown read %', p_name using errcode = '22023';
    end if;
    return app.ops42(p_user, p_call, p_name, coalesce(p, '{}'::jsonb) - '_va');
  end if;
  return app.door_0040(p_user, p_aal, p_call, p_name, p);
end $$;

-- the owner's official form, for the server (service role)
create or replace function public.owner_form_official(p_by uuid, p_fill uuid) returns jsonb
language sql stable security invoker set search_path = public, app as $$ select app.owner_form_official(p_by, p_fill) $$;
create or replace function public.owner_form_signed(p_by uuid, p_fill uuid, p jsonb) returns jsonb
language sql volatile security invoker set search_path = public, app as $$ select app.owner_form_signed(p_by, p_fill, p) $$;

-- ================================================================ 8. row-level security, privileges, audit
alter table toll_notice_reads enable row level security;
alter table toll_notice_read_lines enable row level security;
create policy admin_all on toll_notice_reads for all to authenticated using (app.is_admin()) with check (app.is_admin());
create policy admin_all on toll_notice_read_lines for all to authenticated using (app.is_admin()) with check (app.is_admin());
create policy finance_read on toll_notice_reads for select to authenticated using (app.va_has('finance'));
create policy finance_read on toll_notice_read_lines for select to authenticated using (app.va_has('finance'));
revoke all on toll_notice_reads, toll_notice_read_lines from anon, authenticated;
grant select on toll_notice_reads, toll_notice_read_lines to authenticated;
grant all on toll_notice_reads, toll_notice_read_lines to service_role;
grant usage on sequence toll_notice_read_number_seq to service_role;

do $$
declare
  f record;
begin
  for f in
    select p.oid::regprocedure as sig from pg_proc p join pg_namespace n on n.oid = p.pronamespace
     where (n.nspname = 'app' and p.proname = any (array[
              'program_settings_one_turnaround', 'program_settings_turnaround_resync', 'sync_turnaround_block', 'ai_vision_budget', 'ai_call_record', 'ai_vision_gate',
              'toll_read_context', 'toll_read_document', 'toll_read_line_refresh', 'toll_read_save', 'toll_read_get', 'toll_read_line_save',
              'toll_read_import_lines', 'toll_read_confirm', 'toll_read_line_import', 'toll_read_discard', 'toll_read_queue', 'toll_profiles',
              'toll_profile_upsert', 'photo_plate_context', 'photo_plate_record', 'photo_plate_suggestion', 'listing_plate_problems',
              'form_field_values', 'form_templates', 'form_template_upload', 'form_template_map', 'form_template_preview',
              'owner_form_official', 'owner_form_signed', 'ops42']))
        or (n.nspname = 'public' and p.proname = any (array['owner_form_official', 'owner_form_signed']))
  loop
    execute format('revoke all on function %s from public, anon, authenticated', f.sig);
    execute format('grant execute on function %s to service_role', f.sig);
  end loop;
end $$;
-- a pure list: any database role may read it
grant execute on function app.registry_sources() to service_role, authenticated;

-- Each wrapper keeps the privileges of the function it wraps (a new function would otherwise be open to everyone).
do $$
declare
  r record;
  v_new regprocedure;
  g text;
begin
  for r in select p.oid, m.new_name, oidvectortypes(p.proargtypes) as args
             from pg_proc p join pg_namespace n on n.oid = p.pronamespace
             join (values ('publish_listing_0040', 'publish_listing'), ('door_0040', 'door')) m(old_name, new_name) on m.old_name = p.proname
            where n.nspname = 'app' loop
    v_new := format('app.%I(%s)', r.new_name, r.args)::regprocedure;
    execute format('revoke execute on function %s from public, anon, authenticated', v_new);
    foreach g in array array['anon', 'authenticated', 'service_role'] loop
      if has_function_privilege(g, r.oid, 'execute') then execute format('grant execute on function %s to %I', v_new, g); end if;
    end loop;
  end loop;
end $$;

select app.attach_audit();
