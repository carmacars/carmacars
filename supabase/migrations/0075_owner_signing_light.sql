-- 0075_owner_signing_light.sql
-- Owner signing that never crashes (October 21, 2026), and the first and last month invoice only by an Admin's choice.
--
--   1. Opening without rendering. The sign pages render the documents from their text (HTML) and never make a PDF
--      while the page is shown. Each document is identified by a content key (the SHA-256 of what the PDF is made
--      from: the text blocks, the title, the footer, the fixed date and the renderer's version), kept on its
--      documents row. A page that finds an open request for the same content key uses it; otherwise the browser asks
--      for each document to be prepared, one request per document (rendered, stored and opened exactly as before:
--      the same bytes, the same SHA-256, the same signature requests).
--   2. Signed copies in the background. Signing records the signatures in the database first (the legal act), then
--      queues a job per signed copy (pdf_jobs). The Worker runs the jobs in their own requests, with retries and
--      backoff; a job that keeps failing raises a task for an Admin. The owner's "Signed" email waits (up to 15
--      minutes) for the signed copies and carries them as attachments.
--   3. The first and last month invoice (kind upfront) is never made or issued by itself. Each car carries an Admin's
--      choice, set on Approve, on "Add a car for an owner" and on the owner's Terms tab: the amount (exact, default
--      2 x the Insurance Fee) and Send invoice now, Draft only, Already paid (method, date, reference) or No invoice.
--      With no choice nothing is invoiced and Admin > Today shows "Decide the first and last month invoice for
--      <car>". The older bulk path (the owner page's Issue) only follows a choice. Existing invoices are not changed.
-- No earlier migration is edited; the functions this changes are wrapped (renamed with the suffix _pre0075) or
-- replaced with the same signature.

-- ================================================================ 1. documents identified by their content
alter table documents add column if not exists content_key text check (content_key ~ '^[0-9a-f]{64}$');
comment on column documents.content_key is 'SHA-256 of what the unsigned PDF is made from (text blocks, title, footer, date, renderer version), 0075: the sign page finds the open request for the same content without rendering the PDF again';
create index if not exists documents_content_key on documents (content_key) where content_key is not null;

-- The owner a signed-in person signs for (0022's app.portal_owner_id), or null for anyone else.
create or replace function app.portal_owner_or_null(p_by uuid) returns uuid
language plpgsql stable security definer set search_path = public, app as $$
begin
  return app.portal_owner_id(p_by);
exception when others then
  return null;
end $$;

-- The open requests for these content keys, for the signed-in owner (or partner) only.
create or replace function app.open_by_content(p_by uuid, p_keys text[]) returns jsonb
language sql stable security definer set search_path = public, app as $$
  with me as (select app.portal_owner_or_null(p_by) as owner_id)
  select coalesce(jsonb_agg(x), '[]'::jsonb) from (
    select distinct on (d.content_key) d.content_key, d.sha256, d.storage_path, r.id as signature_request_id, sr.id as sign_request_id
      from documents d join signature_requests r on r.document_id = d.id
      left join sign_requests sr on sr.signature_request_id = r.id
     where d.content_key = any (p_keys) and r.status = 'sent' and (sr.id is null or sr.status = 'sent')
       and (d.owner_id = (select owner_id from me) or d.uploaded_by = p_by)
     order by d.content_key, r.created_at desc) x
$$;

-- After a document is opened: its content key, on the row the opening made (found by its file).
create or replace function app.document_content_key(p_by uuid, p_path text, p_key text) returns integer
language plpgsql security definer set search_path = public, app as $$
declare
  n integer;
begin
  if coalesce(p_key, '') !~ '^[0-9a-f]{64}$' then raise exception 'A content key is a SHA-256' using errcode = '22023'; end if;
  update documents set content_key = p_key
   where storage_bucket = 'agreements' and storage_path = p_path and content_key is distinct from p_key
     and (owner_id = app.portal_owner_or_null(p_by) or uploaded_by = p_by);
  get diagnostics n = row_count;
  return n;
end $$;

-- ================================================================ 2. signed copies in the background
create table if not exists pdf_jobs (
  id              uuid primary key default gen_random_uuid(),
  kind            text not null check (kind in ('owner_signed_copy', 'sign_request_record', 'renter_signed_copy', 'amendment_signed_copy')),
  ref             uuid not null,           -- the signature request (owner), the sign request, the booking or the amendment
  owner_id        uuid references owners (id),
  user_id         uuid references users (id),
  payload         jsonb not null default '{}'::jsonb,
  status          text not null default 'queued' check (status in ('queued', 'running', 'done', 'failed')),
  attempts        integer not null default 0,
  max_attempts    integer not null default 6,
  next_attempt_at timestamptz not null default now(),
  locked_at       timestamptz,
  locked_by       text,
  last_error      text,
  created_at      timestamptz not null default now(),
  done_at         timestamptz,
  unique (kind, ref)
);
comment on table pdf_jobs is 'Signed copies made after signing (0075): the signature is recorded first, the PDF is rendered here in its own Worker request, with retries';
alter table pdf_jobs enable row level security;
create index if not exists pdf_jobs_due on pdf_jobs (next_attempt_at) where status in ('queued', 'running');

-- p: [{kind, ref, owner_id?, user_id?, payload?}]. A job already queued for the same document is kept (its payload refreshed).
create or replace function app.pdf_jobs_enqueue(p jsonb) returns integer
language plpgsql security definer set search_path = public, app as $$
declare
  j jsonb;
  n integer := 0;
begin
  for j in select value from jsonb_array_elements(coalesce(p, '[]'::jsonb)) loop
    insert into pdf_jobs (kind, ref, owner_id, user_id, payload)
    values (j ->> 'kind', (j ->> 'ref')::uuid, nullif(j ->> 'owner_id', '')::uuid, nullif(j ->> 'user_id', '')::uuid, coalesce(j -> 'payload', '{}'::jsonb))
    on conflict (kind, ref) do update set payload = excluded.payload,
      status = case when pdf_jobs.status = 'done' then 'done' else 'queued' end,
      attempts = case when pdf_jobs.status = 'failed' then 0 else pdf_jobs.attempts end,
      next_attempt_at = case when pdf_jobs.status = 'done' then pdf_jobs.next_attempt_at else now() end;
    n := n + 1;
  end loop;
  return n;
end $$;

-- Is the copy this job makes already there? (A copy attached by an earlier run, or by hand.)
create or replace function app.pdf_job_already_done(j pdf_jobs) returns boolean
language sql stable security definer set search_path = public, app as $$
  select case j.kind
    when 'owner_signed_copy' then exists (select 1 from signature_requests r where r.id = j.ref and r.signed_document_id is not null)
    when 'sign_request_record' then exists (select 1 from sign_requests s where s.id = j.ref and s.signed_document_id is not null)
    else false end
$$;

-- Claim due jobs (skipping locked ones); a job running for more than 5 minutes is taken as lost and claimed again.
create or replace function app.pdf_jobs_claim(p_worker text, p_limit integer default 1) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  j pdf_jobs;
  v_out jsonb := '[]'::jsonb;
begin
  for j in select * from pdf_jobs
            where (status = 'queued' and next_attempt_at <= now()) or (status = 'running' and locked_at < now() - interval '5 minutes')
            order by next_attempt_at, created_at limit greatest(1, least(coalesce(p_limit, 1), 10)) for update skip locked loop
    if app.pdf_job_already_done(j) then
      update pdf_jobs set status = 'done', done_at = now(), locked_at = null, last_error = null where id = j.id;
      perform app.pdf_job_after(j.id);
      continue;
    end if;
    update pdf_jobs set status = 'running', attempts = attempts + 1, locked_at = now(), locked_by = p_worker where id = j.id returning * into j;
    v_out := v_out || jsonb_build_array(to_jsonb(j));
  end loop;
  return v_out;
end $$;

-- What follows a finished job: the owner's "Signed" email goes once every signed copy of the signing is attached.
create or replace function app.pdf_job_after(p_job uuid) returns void
language plpgsql security definer set search_path = public, app as $$
declare
  j pdf_jobs;
begin
  select * into j from pdf_jobs where id = p_job;
  if j.owner_id is null or j.kind <> 'owner_signed_copy' then return; end if;
  if not exists (select 1 from pdf_jobs x where x.owner_id = j.owner_id and x.kind = 'owner_signed_copy' and x.status in ('queued', 'running')) then
    update notification_outbox set send_after = now()
     where code = 'owner_agreement_signed' and status = 'queued' and send_after > now() and app.outbox_owner(notification_outbox) = j.owner_id;
  end if;
end $$;

create or replace function app.pdf_job_done(p_job uuid) returns void
language plpgsql security definer set search_path = public, app as $$
begin
  update pdf_jobs set status = 'done', done_at = now(), locked_at = null, last_error = null where id = p_job;
  perform app.pdf_job_after(p_job);
end $$;

-- A failed run: tried again after 1, 2, 5, 15 and 60 minutes; after the last attempt an Admin gets a task.
create or replace function app.pdf_job_fail(p_job uuid, p_error text) returns void
language plpgsql security definer set search_path = public, app as $$
declare
  j pdf_jobs;
begin
  update pdf_jobs set locked_at = null, last_error = left(coalesce(p_error, 'failed'), 1000),
         status = case when attempts >= max_attempts then 'failed' else 'queued' end,
         next_attempt_at = now() + (array[interval '1 minute', interval '2 minutes', interval '5 minutes', interval '15 minutes', interval '60 minutes'])[least(greatest(attempts, 1), 5)]
   where id = p_job returning * into j;
  if j.status = 'failed' then
    perform app.raise_task(p_type => 'signed_copy_failed', p_queue => 'admin', p_priority => 'high',
        p_title => 'A signed copy could not be made',
        p_detail => format('The signature is recorded; only the PDF copy is missing (%s, %s). Last error: %s. Press "Try again" on Admin > Tasks or ask for a fix.', j.kind, j.ref, j.last_error),
        p_owner => j.owner_id, p_related_table => 'pdf_jobs', p_related_id => j.id, p_dedupe => 'signed_copy_failed:' || j.id);
    perform app.pdf_job_after(p_job);
  end if;
end $$;

-- The owner of an outbox row (its own column, its car, or the onboarding it is about).
create or replace function app.outbox_owner(o notification_outbox) returns uuid
language sql stable security definer set search_path = public, app as $$
  select coalesce(o.owner_id, (select v.owner_id from vehicles v where v.id = o.vehicle_id),
                  (select v.owner_id from vehicle_onboardings ob join vehicles v on v.id = ob.vehicle_id where ob.id = o.entity_id))
$$;

-- The owner's "Signed" email waits for the signed copies (at most 15 minutes; then it goes, linking to Documents).
create or replace function app.outbox_wait_signed_copies() returns trigger
language plpgsql security definer set search_path = public, app as $$
declare
  v_owner uuid;
begin
  if new.code <> 'owner_agreement_signed' then return new; end if;
  v_owner := app.outbox_owner(new);
  if v_owner is not null and (
       exists (select 1 from pdf_jobs j where j.owner_id = v_owner and j.kind = 'owner_signed_copy' and j.status in ('queued', 'running'))
       or exists (select 1 from owner_agreements a join signature_requests r on r.id = a.signature_request_id
                   where a.owner_id = v_owner and r.status = 'completed' and r.signed_document_id is null and r.completed_at > now() - interval '1 hour')) then
    new.send_after := greatest(new.send_after, now() + interval '15 minutes');
  end if;
  return new;
end $$;
drop trigger if exists outbox_wait_signed_copies on notification_outbox;
create trigger outbox_wait_signed_copies before insert on notification_outbox for each row execute function app.outbox_wait_signed_copies();

-- ... and carries them (the signed copies of the requests completed around the event).
alter function app.outbox_attachments(uuid) rename to outbox_attachments_pre0075;
create or replace function app.outbox_attachments(p_outbox uuid) returns jsonb
language plpgsql stable security definer set search_path = public, app as $$
declare
  o notification_outbox;
  v_owner uuid;
begin
  select * into o from notification_outbox where id = p_outbox;
  if o.id is null or o.code <> 'owner_agreement_signed' then return app.outbox_attachments_pre0075(p_outbox); end if;
  v_owner := app.outbox_owner(o);
  return (select coalesce(jsonb_agg(jsonb_build_object('k', 'document', 'key', d.id::text, 'filename', 'CarmaCars ' || coalesce(d.title, 'signed agreement') || '.pdf')
                                    order by d.created_at), '[]'::jsonb)
            from documents d join signature_requests r on r.signed_document_id = d.id
           where r.completed_at between o.created_at - interval '1 hour' and o.created_at + interval '5 minutes'
             and (r.id in (select a.signature_request_id from owner_agreements a where a.owner_id = v_owner)
                  or r.id in (select s.signature_request_id from vehicle_schedules s join vehicles v on v.id = s.vehicle_id where v.owner_id = v_owner)));
end $$;

-- ================================================================ 3. the first and last month invoice: an Admin's choice per car
alter table vehicle_onboardings
  add column if not exists first_last_choice text check (first_last_choice in ('send', 'draft', 'paid', 'none')),
  add column if not exists first_last_choice_cents bigint check (first_last_choice_cents is null or first_last_choice_cents > 0),
  add column if not exists first_last_choice_payment jsonb,
  add column if not exists first_last_choice_by uuid references users (id),
  add column if not exists first_last_choice_at timestamptz;
comment on column vehicle_onboardings.first_last_choice is 'The Admin''s choice for the first and last month invoice (0075): send, draft, paid or none. Null: not decided; nothing is invoiced and Admin > Today asks for it';

-- What the car's first and last month invoice is now: the choice, the amount, the invoice made.
create or replace function app.first_last_state(p_vehicle uuid) returns jsonb
language sql stable security definer set search_path = public, app as $$
  select jsonb_build_object('choice', ob.first_last_choice, 'amount_cents', ob.first_last_choice_cents, 'payment', ob.first_last_choice_payment,
           'at', ob.first_last_choice_at, 'by', (select coalesce(u.full_name, u.email) from users u where u.id = ob.first_last_choice_by),
           'default_cents', coalesce(s.first_last_cents, 2 * s.insurance_fee_cents, ((app.owner_terms_resolve(v.id)) ->> 'first_last_cents')::bigint),
           'needed', v.billing_case in ('managed', 'self_managed') and not coalesce(v.is_shareholder_owned, false),
           'invoice', (select app.oi_row(i) from owner_invoices i where i.vehicle_id = v.id and i.kind = 'upfront' and i.status <> 'void' order by i.created_at desc limit 1))
    from vehicles v left join vehicle_onboardings ob on ob.vehicle_id = v.id
    left join vehicle_schedules s on s.vehicle_id = v.id and s.superseded_by is null
   where v.id = p_vehicle
$$;

-- Ask an Admin to decide (once per car), or close the question.
create or replace function app.first_last_todo(p_vehicle uuid, p_by uuid default null) returns void
language plpgsql security definer set search_path = public, app as $$
declare
  v vehicles;
  ob vehicle_onboardings;
begin
  select * into v from vehicles where id = p_vehicle;
  select * into ob from vehicle_onboardings where vehicle_id = p_vehicle;
  if v.id is null or ob.id is null then return; end if;
  if ob.first_last_choice is null and v.billing_case in ('managed', 'self_managed') and not coalesce(v.is_shareholder_owned, false)
     and ob.status not in ('intake', 'declined', 'withdrawn')
     and not exists (select 1 from owner_invoices i where i.vehicle_id = v.id and i.kind = 'upfront' and i.status <> 'void') then
    perform app.raise_task(p_type => 'first_last_decide', p_queue => 'admin',
        p_title => format('Decide the first and last month invoice for %s', app.vehicle_name(v.id)),
        p_detail => 'Nothing is invoiced until you choose: Send invoice now, Draft only, Already paid or No invoice (Admin > the owner > Terms).',
        p_owner => v.owner_id, p_vehicle => v.id, p_related_table => 'vehicle_onboardings', p_related_id => ob.id,
        p_dedupe => 'first_last_decide:' || v.id);
  else
    update tasks set status = 'done', completed_at = now(), completed_by = p_by, completion_note = coalesce(completion_note, 'Decided')
     where task_type = 'first_last_decide' and vehicle_id = v.id and status in ('open', 'in_progress', 'waiting');
  end if;
end $$;

-- The Admin's choice for one car. p: {vehicle_id, action: send | draft | paid | none, amount_cents?, payment?: {method,
-- received_on, reference, amount_cents, note}, application_id?}. Send, draft and paid make the invoice now (0067's
-- app.oi_plan_invoice: sent and emailed, kept as a draft, or issued quietly and recorded as paid); none makes nothing.
-- A car that already has a first and last month invoice keeps it: change it on the invoice screen (void, corrected copy).
create or replace function app.first_last_choose(p_by uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  v vehicles;
  ob vehicle_onboardings;
  v_action text := nullif(p ->> 'action', '');
  v_amount bigint;
  v_existing owner_invoices;
  v_inv jsonb;
begin
  perform app.assert_admin(p_by);
  select * into v from vehicles where id = nullif(p ->> 'vehicle_id', '')::uuid;
  if v.id is null then raise exception 'Car not found' using errcode = 'P0002'; end if;
  select * into ob from vehicle_onboardings where vehicle_id = v.id for update;
  if ob.id is null then raise exception 'This car has no onboarding record' using errcode = 'P0002'; end if;
  if v_action is null or v_action not in ('send', 'draft', 'paid', 'none') then
    raise exception 'Choose Send invoice now, Draft only, Already paid or No invoice' using errcode = '22023';
  end if;
  if v_action <> 'none' and (v.billing_case not in ('managed', 'self_managed') or coalesce(v.is_shareholder_owned, false)) then
    raise exception 'No first and last month invoice applies to this car' using errcode = '23514';
  end if;
  v_amount := coalesce(nullif(p ->> 'amount_cents', '')::bigint, (app.first_last_state(v.id) ->> 'default_cents')::bigint);
  if v_action <> 'none' and (v_amount is null or v_amount <= 0) then raise exception 'Enter the first and last month amount' using errcode = '22023'; end if;
  select * into v_existing from owner_invoices i where i.vehicle_id = v.id and i.kind = 'upfront' and i.status <> 'void' order by i.created_at desc limit 1;
  if v_existing.id is not null and v_action <> 'none' then
    raise exception 'This car already has the first and last month invoice %: change it on the invoice screen (void it, then make a corrected one)', v_existing.invoice_number using errcode = '23505';
  end if;
  if v_existing.id is not null and v_action = 'none' then
    raise exception 'This car already has the first and last month invoice %: void it on the invoice screen first', v_existing.invoice_number using errcode = '23514';
  end if;
  if v_action = 'paid' and ((p #>> '{payment,method}') in ('e_transfer', 'cheque', 'bank_transfer')) and length(btrim(coalesce(p #>> '{payment,reference}', ''))) < 3 then
    raise exception 'Enter the reference of the payment' using errcode = '22023';
  end if;
  if v_action <> 'none' then
    v_inv := app.oi_plan_invoice(p_by, v.id, jsonb_build_object('first_last_cents', v_amount),
               jsonb_strip_nulls(jsonb_build_object('type', 'first_last', 'amount_cents', v_amount, 'action', v_action, 'payment', p -> 'payment')),
               coalesce(nullif(p ->> 'application_id', '')::uuid, ob.application_id));
  end if;
  update vehicle_onboardings set first_last_choice = v_action, first_last_choice_cents = case when v_action = 'none' then null else v_amount end,
         first_last_choice_payment = case when v_action = 'paid' then p -> 'payment' end, first_last_choice_by = p_by, first_last_choice_at = now()
   where id = ob.id returning * into ob;
  -- No invoice: nothing to wait for after signing
  if v_action = 'none' and ob.status = 'documents_signed' then
    update vehicle_onboardings set status = 'upfront_paid' where id = ob.id;
  end if;
  perform app.first_last_todo(v.id, p_by);
  insert into audit_log (actor_user_id, action, entity_table, entity_id, after)
  values (p_by, 'first_last_choose', 'vehicle_onboardings', ob.id::text, jsonb_build_object('vehicle_id', v.id, 'action', v_action, 'amount_cents', v_amount, 'invoice', v_inv));
  return jsonb_build_object('vehicle_id', v.id, 'choice', v_action, 'amount_cents', case when v_action = 'none' then null else v_amount end, 'invoice', v_inv);
end $$;

-- A car with No invoice moves past "upfront paid" (0011's check, plus the choice; otherwise unchanged).
create or replace function app.vehicle_onboarding_before_status() returns trigger
language plpgsql security definer set search_path = public, app as $$
declare
  v vehicles;
begin
  if new.status = old.status then return new; end if;
  select * into v from vehicles where id = new.vehicle_id;

  if new.status = 'terms_set' then
    new.terms_set_at := coalesce(new.terms_set_at, now());
  elsif new.status = 'documents_sent' then
    new.documents_sent_at := coalesce(new.documents_sent_at, now());
  elsif new.status = 'documents_signed' then
    if not v.is_shareholder_owned and not exists (
         select 1 from vehicle_schedules s where s.vehicle_id = v.id and s.superseded_by is null and s.signed_at is not null) then
      raise exception 'The vehicle''s Vehicle Schedule is not signed' using errcode = '23514';
    end if;
    new.documents_signed_at := coalesce(new.documents_signed_at, now());
  elsif new.status = 'upfront_paid' then
    if new.first_last_choice is distinct from 'none'
       and not exists (select 1 from owner_invoices i where i.id = new.upfront_invoice_id and i.status = 'paid') then
      raise exception 'The Install Fee and first and last month''s Insurance Fee are not paid' using errcode = '23514';
    end if;
    new.upfront_paid_at := coalesce(new.upfront_paid_at, now());
  elsif new.status = 'registry_booked' then
    if old.status = 'documents_signed' and not v.is_shareholder_owned then
      raise exception 'Only a shareholder-owned vehicle skips the upfront charges' using errcode = '23514';
    end if;
  elsif new.status = 'tracker_installed' then
    if not exists (select 1 from tracker_devices t where t.vehicle_id = v.id and t.status = 'installed' and t.tested_at is not null) then
      raise exception 'A Tracker must be installed and tested before the vehicle joins the Fleet Policy' using errcode = '23514';
    end if;
    new.tracker_installed_at := coalesce(new.tracker_installed_at, now());
  elsif new.status = 'on_fleet_policy' then
    new.on_fleet_policy_at := coalesce(new.on_fleet_policy_at, now());
  elsif new.status = 'enrolled' then
    if old.status = 'documents_signed' and v.management_mode <> 'turo_only' then
      raise exception 'Only a Turo-Only vehicle is enrolled straight after signature' using errcode = '23514';
    end if;
    new.enrolled_confirmed_at := coalesce(new.enrolled_confirmed_at, now());
  end if;
  return new;
end $$;

-- Approve (0067's, wrapped): a first and last month entry of a car is the Admin's choice for that car ("none" is
-- taken out before 0067's approve, which only knows invoices); a car left without a choice gets the to-do.
alter function app.application_approve(uuid, jsonb) rename to application_approve_pre0075;
create or replace function app.application_approve(p_admin uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  a owner_applications;
  c jsonb;
  fl jsonb;
  v_cars jsonb := '[]'::jsonb;
  v_choices jsonb := '[]'::jsonb;
  v_out jsonb;
  res jsonb;
  r record;
begin
  select * into a from owner_applications where id = nullif(p ->> 'id', '')::uuid;
  for c in select value from jsonb_array_elements(coalesce(p -> 'cars', '[]'::jsonb)) loop
    fl := coalesce(c -> 'first_last',
                   (select x from jsonb_array_elements(coalesce(c -> 'invoices', '[]'::jsonb)) x where x ->> 'type' = 'first_last' limit 1));
    if fl is not null then
      v_choices := v_choices || jsonb_build_array(jsonb_strip_nulls(jsonb_build_object('vehicle_id', c ->> 'vehicle_id', 'action', coalesce(nullif(fl ->> 'action', ''), 'draft'),
                                                   'amount_cents', fl -> 'amount_cents', 'payment', fl -> 'payment', 'application_id', a.id)));
    end if;
    v_cars := v_cars || jsonb_build_array((c - 'first_last') || jsonb_build_object('invoices',
                (select coalesce(jsonb_agg(x), '[]'::jsonb) from jsonb_array_elements(coalesce(c -> 'invoices', '[]'::jsonb)) x where x ->> 'type' is distinct from 'first_last')));
  end loop;
  v_out := app.application_approve_pre0075(p_admin, case when p ? 'cars' then jsonb_set(p, '{cars}', v_cars) else p end);
  if coalesce((v_out ->> 'repeat')::boolean, false) then return v_out; end if;
  for c in select value from jsonb_array_elements(v_choices) loop
    res := app.first_last_choose(p_admin, c);
    if jsonb_typeof(res -> 'invoice') = 'object' then
      v_out := jsonb_set(v_out, '{invoices}', coalesce(v_out -> 'invoices', '[]'::jsonb) || jsonb_build_array(res -> 'invoice'));
    end if;
  end loop;
  for r in select v.id from vehicles v join vehicle_onboardings ob on ob.vehicle_id = v.id where v.owner_id = a.owner_id and ob.application_id = a.id loop
    perform app.first_last_todo(r.id, p_admin);
  end loop;
  return v_out || jsonb_build_object('first_last', (select coalesce(jsonb_agg(jsonb_build_object('vehicle_id', v.id, 'name', app.vehicle_name(v.id)) || app.first_last_state(v.id)), '[]'::jsonb)
                                                      from vehicles v join vehicle_onboardings ob on ob.vehicle_id = v.id where ob.application_id = a.id));
end $$;

-- The owner page's Issue (0029's bulk path): only what an Admin chose. A car without a choice gets the to-do and no
-- invoice; a car whose choice was made already has its invoice (made at the choice).
create or replace function app.admin_issue_upfront_invoices(p_owner uuid, p_admin uuid, p_vehicles uuid[] default null) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  r record;
  v_out jsonb := '[]'::jsonb;
  v_res jsonb;
begin
  perform app.assert_admin(p_admin);
  for r in
    select v.id, ob.first_last_choice, ob.first_last_choice_cents, ob.first_last_choice_payment from vehicles v join vehicle_onboardings ob on ob.vehicle_id = v.id
     where v.owner_id = p_owner and v.billing_case in ('managed', 'self_managed')
       and ob.status in ('terms_set', 'documents_sent', 'documents_signed')
       and not exists (select 1 from owner_invoices i where i.vehicle_id = v.id and i.kind = 'upfront' and i.status <> 'void')
       and (p_vehicles is null or v.id = any (p_vehicles))
     order by v.created_at, v.id
  loop
    if r.first_last_choice in ('send', 'draft', 'paid') then
      -- the choice stands; its invoice was voided since: made again the same way
      v_res := app.oi_plan_invoice(p_admin, r.id, jsonb_build_object('first_last_cents', r.first_last_choice_cents),
                 jsonb_strip_nulls(jsonb_build_object('type', 'first_last', 'amount_cents', r.first_last_choice_cents, 'action', r.first_last_choice, 'payment', r.first_last_choice_payment)), null);
      v_out := v_out || jsonb_build_array(jsonb_build_object('vehicle_id', r.id, 'invoice_id', v_res ->> 'id', 'invoice_number', v_res ->> 'invoice_number', 'total_cents', v_res -> 'total_cents'));
    elsif r.first_last_choice is null then
      perform app.first_last_todo(r.id, p_admin);
    end if;
  end loop;
  return v_out;
end $$;

-- 0022's automatic path: never issues by itself any more (kept for its callers; returns nothing).
create or replace function app.issue_upfront_invoices(p_owner uuid, p_by uuid default null)
returns table (vehicle_id uuid, invoice_id uuid, invoice_number text, fees_cents bigint, hst_cents bigint, total_cents bigint)
language plpgsql security definer set search_path = public, app as $$
declare
  r record;
begin
  for r in select v.id from vehicles v join vehicle_onboardings ob on ob.vehicle_id = v.id where v.owner_id = p_owner and ob.first_last_choice is null loop
    perform app.first_last_todo(r.id, p_by);
  end loop;
  return;
end $$;

-- Signing (0053's, wrapped): never makes an invoice; a signed car still without a choice gets the to-do.
alter function app.owner_sign_agreements(uuid, uuid, jsonb) rename to owner_sign_agreements_pre0075;
create or replace function app.owner_sign_agreements(p_owner uuid, p_by uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  v_out jsonb := app.owner_sign_agreements_pre0075(p_owner, p_by, p);
  r record;
begin
  for r in select v.id, ob.id as ob_id, ob.status, ob.first_last_choice from vehicles v join vehicle_onboardings ob on ob.vehicle_id = v.id where v.owner_id = p_owner loop
    if r.first_last_choice = 'none' and r.status = 'documents_signed' then
      update vehicle_onboardings set status = 'upfront_paid' where id = r.ob_id;
    end if;
    perform app.first_last_todo(r.id, null);
  end loop;
  return v_out;
end $$;

-- The Terms tab shows each car's first and last month choice (0067's read, wrapped).
alter function app.owner_terms_read(uuid, jsonb) rename to owner_terms_read_pre0075;
create or replace function app.owner_terms_read(p_by uuid, p jsonb) returns jsonb
language plpgsql stable security definer set search_path = public, app as $$
declare
  v_out jsonb := app.owner_terms_read_pre0075(p_by, p);
begin
  return jsonb_set(v_out, '{cars}', (select coalesce(jsonb_agg(c || jsonb_build_object('first_last', app.first_last_state((c ->> 'vehicle_id')::uuid)) order by n), '[]'::jsonb)
                                       from jsonb_array_elements(coalesce(v_out -> 'cars', '[]'::jsonb)) with ordinality as e(c, n)));
end $$;

-- Existing cars: nothing is voided or changed. A car past intake with no first and last month invoice and no choice
-- gets the to-do; a car that already has one is left as it is (the Admin decides on its invoice screen).
do $$
declare
  r record;
begin
  for r in select v.id from vehicles v join vehicle_onboardings ob on ob.vehicle_id = v.id
            where ob.status in ('terms_set', 'documents_sent', 'documents_signed') and ob.first_last_choice is null loop
    perform app.first_last_todo(r.id, null);
  end loop;
end $$;

-- ================================================================ 4. calls
create or replace function app.ops_0075(p_user uuid, p_call text, p_name text, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
begin
  case p_name
  when 'first_last_choose' then return app.first_last_choose(p_user, p);
  when 'first_last_state' then perform app.assert_admin(p_user); return app.first_last_state(nullif(p ->> 'vehicle_id', '')::uuid);
  when 'pdf_job_retry' then
    perform app.assert_admin(p_user);
    update pdf_jobs set status = 'queued', attempts = 0, next_attempt_at = now(), last_error = null where id = nullif(p ->> 'id', '')::uuid and status = 'failed';
    return jsonb_build_object('ok', true);
  else raise exception 'Unknown action %', p_name using errcode = '22023';
  end case;
end $$;

alter function app.door(uuid, text, text, text, jsonb) rename to door_pre0075;
create or replace function app.door(p_user uuid, p_aal text, p_call text, p_name text, p jsonb default '{}'::jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
begin
  if (p_call in ('ops_do', 'admin_do') and p_name in ('first_last_choose', 'pdf_job_retry'))
     or (p_call in ('ops_read', 'admin_read') and p_name = 'first_last_state') then
    perform app.door_begin(p_user, p_aal);
    return app.ops_0075(p_user, p_call, p_name, coalesce(p, '{}'::jsonb));
  end if;
  return app.door_pre0075(p_user, p_aal, p_call, p_name, p);
end $$;

-- The server's own calls (service role).
create or replace function public.server_open_by_content(p_by uuid, p_keys text[]) returns jsonb
language sql stable security invoker set search_path = public, app as $$ select app.open_by_content(p_by, p_keys) $$;
create or replace function public.server_document_content_key(p_by uuid, p_path text, p_key text) returns integer
language sql volatile security invoker set search_path = public, app as $$ select app.document_content_key(p_by, p_path, p_key) $$;
create or replace function public.server_pdf_jobs_enqueue(p jsonb) returns integer
language sql volatile security invoker set search_path = public, app as $$ select app.pdf_jobs_enqueue(p) $$;
create or replace function public.server_pdf_jobs_claim(p_worker text, p_limit integer default 1) returns jsonb
language sql volatile security invoker set search_path = public, app as $$ select app.pdf_jobs_claim(p_worker, p_limit) $$;
create or replace function public.server_pdf_job_done(p_job uuid) returns void
language sql volatile security invoker set search_path = public, app as $$ select app.pdf_job_done(p_job) $$;
create or replace function public.server_pdf_job_fail(p_job uuid, p_error text) returns void
language sql volatile security invoker set search_path = public, app as $$ select app.pdf_job_fail(p_job, p_error) $$;
create or replace function public.server_pdf_jobs_pending(p_owner uuid) returns integer
language sql stable security invoker set search_path = public, app as $$
  select count(*)::integer from pdf_jobs where owner_id = p_owner and status in ('queued', 'running')
$$;

-- ================================================================ 5. privileges
do $$
declare
  f record;
begin
  for f in
    select p.oid::regprocedure as sig from pg_proc p join pg_namespace n on n.oid = p.pronamespace
     where (n.nspname = 'app' and (p.proname like '%\_pre0075' or p.proname = any (array[
              'portal_owner_or_null', 'open_by_content', 'document_content_key', 'pdf_jobs_enqueue', 'pdf_job_already_done', 'pdf_jobs_claim', 'pdf_job_after', 'pdf_job_done',
              'pdf_job_fail', 'outbox_owner', 'outbox_wait_signed_copies', 'outbox_attachments', 'first_last_state', 'first_last_todo', 'first_last_choose',
              'vehicle_onboarding_before_status', 'application_approve', 'admin_issue_upfront_invoices', 'issue_upfront_invoices', 'owner_sign_agreements',
              'owner_terms_read', 'ops_0075', 'door'])))
        or (n.nspname = 'public' and p.proname = any (array['server_open_by_content', 'server_document_content_key', 'server_pdf_jobs_enqueue',
              'server_pdf_jobs_claim', 'server_pdf_job_done', 'server_pdf_job_fail', 'server_pdf_jobs_pending']))
  loop
    execute format('revoke all on function %s from public, anon, authenticated', f.sig);
    execute format('grant execute on function %s to service_role', f.sig);
  end loop;
end $$;
revoke all on pdf_jobs from public, anon, authenticated;
grant select, insert, update, delete on pdf_jobs to service_role;
