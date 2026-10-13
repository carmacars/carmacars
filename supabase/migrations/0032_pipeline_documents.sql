-- 0032: the listing pipeline's worker, generated documents (PDFs) and signed file links, and the money
-- gaps of the admin report (refund issuing, the guided Deposit settlement, a document on a single toll
-- or ticket, the insurer invoice email). Record: docs/changes/0032_pipeline_documents.md.
-- Tests: supabase/tests/19_pipeline_documents.sql.
--
-- No earlier migration is edited. Three functions are replaced with their behaviour kept and one branch
-- added: app.door (0031: the calls ops_read and ops_do), app.notification_recipients (0018: the
-- insurer audience) and app.notification_catalogue_refresh (0018: invoice_url is a sender value).
-- app.notification_payload is wrapped (as 0024 did) for the insurer_invoice email.

-- =====================================================================================
-- A. The listing pipeline's worker (docs/blueprint/09-listing-pipeline.md section 5)
-- =====================================================================================
-- The worker runs in the site's Cloudflare Worker (Workers AI and image transformations are bindings
-- there), started by a Cloudflare cron trigger and once right after a capture is submitted. It reaches
-- the queue of 0022 through the service-role functions below.

-- What a provider call used, besides money: Workers AI neurons, image transformations.
alter table provider_calls
  add column if not exists units numeric check (units >= 0),
  add column if not exists unit  text check (unit in ('neurons', 'transformations', 'requests'));
create index if not exists provider_calls_unit_day_idx on provider_calls (unit, created_at);

alter table program_settings
  add column if not exists listing_ai_daily_neurons integer not null default 9000 check (listing_ai_daily_neurons >= 0),
  add column if not exists images_free_monthly_transformations integer not null default 5000
    check (images_free_monthly_transformations >= 0);
comment on column program_settings.listing_ai_daily_neurons is
  'Copy drafts stop for the day once Workers AI calls have used this many neurons (Toronto day). The Workers Free allowance is 10,000 a day.';
comment on column program_settings.images_free_monthly_transformations is
  'Image transformations a month that cost nothing (Cloudflare Images free allowance). Above it each one is costed at the paid rate in provider_calls.';

-- Today's spending against the limits, for the worker and the admin screens.
create or replace function app.listing_budget(p_now timestamptz default now()) returns jsonb
language sql stable security definer set search_path = public, app as $$
  with ps as (select * from app.settings(app.local_date(p_now))),
       day as (select app.local_midnight(app.local_date(p_now)) as t0, app.local_midnight(app.local_date(p_now) + 1) as t1),
       month as (select app.local_midnight(date_trunc('month', app.local_date(p_now))::date) as m0)
  select jsonb_build_object(
    'photo_spent_microusd', (select coalesce(sum(c.cost_microusd), 0) from provider_calls c, day where c.created_at >= day.t0 and c.created_at < day.t1),
    'photo_budget_microusd', (select photo_daily_budget_microusd from ps),
    'ai_neurons_today', (select coalesce(sum(c.units), 0) from provider_calls c, day where c.unit = 'neurons' and c.created_at >= day.t0 and c.created_at < day.t1),
    'ai_neurons_limit', (select listing_ai_daily_neurons from ps),
    'transformations_month', (select coalesce(sum(c.units), 0) from provider_calls c, month where c.unit = 'transformations' and c.created_at >= month.m0),
    'transformations_free', (select images_free_monthly_transformations from ps),
    'resets_at', (select t1 from day))
$$;

-- What the worker needs for one job: the facts as they stand now (after the decode), the staff's input,
-- the photo, and the classes a draft may propose. Never a VIN for anything but the decode, a plate or an owner.
create or replace function app.listing_job_context(p_job uuid) returns jsonb
language sql stable security definer set search_path = public, app as $$
  select jsonb_build_object(
    'id', j.id, 'kind', j.kind, 'intake_id', j.intake_id, 'vehicle_id', j.vehicle_id, 'attempts', j.attempts,
    'max_attempts', j.max_attempts, 'input', j.input,
    'vin', case when j.kind = 'decode_vin' then (select upper(v.vin) from vehicles v where v.id = j.vehicle_id) end,
    'facts', case when j.kind = 'draft_copy' then app.listing_facts(j.vehicle_id) end,
    'staff_notes', case when j.kind = 'draft_copy' then i.notes end,
    'classes', case when j.kind = 'draft_copy' then
      (select coalesce(jsonb_agg(c.code order by c.sort_order), '[]'::jsonb) from vehicle_classes c where c.is_active) end,
    'copy_rules', case when j.kind = 'draft_copy' then
      (select jsonb_build_object('headline_chars', jsonb_build_array(lower(ps.listing_headline_chars), upper(ps.listing_headline_chars) - 1),
                                 'description_words', jsonb_build_array(lower(ps.listing_description_words), upper(ps.listing_description_words) - 1),
                                 'features', jsonb_build_array(lower(ps.listing_features_count), upper(ps.listing_features_count) - 1),
                                 'faq', jsonb_build_array(lower(ps.listing_faq_count), upper(ps.listing_faq_count) - 1),
                                 'banned_phrases', to_jsonb(ps.listing_banned_phrases))
         from app.settings() ps) end,
    'photo', case when j.vehicle_photo_id is not null then
      (select jsonb_build_object('id', ph.id, 'shot_type', ph.shot_type, 'angle', ph.angle, 'original_path', ph.original_path,
                                 'processed_path', ph.processed_path, 'rebackground', coalesce(st.rebackground, false),
                                 'is_public', coalesce(st.is_public, false), 'width', ph.width, 'height', ph.height,
                                 'alt_text', coalesce(ph.alt_text, app.photo_alt_text(ph.vehicle_id, ph.shot_type)),
                                 'file_base', app.slugify(concat_ws(' ', v.year::text, v.make, v.model, coalesce(st.code, ph.angle))) || '-' || left(ph.id::text, 8))
         from vehicle_photos ph join vehicles v on v.id = ph.vehicle_id left join listing_shot_types st on st.code = ph.shot_type
        where ph.id = j.vehicle_photo_id) end)
    from listing_jobs j join listing_intakes i on i.id = j.intake_id
   where j.id = p_job
$$;

-- Claim due jobs, as app.claim_listing_jobs (0022) does, with two more rules: a copy draft waits while the
-- intake's VIN decode is still open (the copy is written from the decoded facts), and copy drafts stop for
-- the day once the Workers AI neurons reach listing_ai_daily_neurons. Photo work still stops at
-- photo_daily_budget_microusd. Returns each job with its context.
create or replace function app.worker_claim_listing_jobs(p_worker text, p_limit integer default 4, p_now timestamptz default now())
returns jsonb language plpgsql security definer set search_path = public, app as $$
declare
  ps program_settings := app.settings(app.local_date(p_now));
  bud jsonb := app.listing_budget(p_now);
  v_photo_ok boolean := (bud ->> 'photo_spent_microusd')::bigint < ps.photo_daily_budget_microusd;
  v_ai_ok boolean := (bud ->> 'ai_neurons_today')::numeric < ps.listing_ai_daily_neurons;
  j listing_jobs;
  v_out jsonb := '[]'::jsonb;
begin
  for j in
    select * from listing_jobs x
     where ((x.status = 'queued' and x.next_attempt_at <= p_now)
            or (x.status = 'running' and x.locked_at < p_now - make_interval(mins => ps.listing_job_lock_minutes)))
       and (x.kind not in ('process_photo', 'resize') or v_photo_ok)
       and (x.kind <> 'draft_copy' or (v_ai_ok and not exists (
             select 1 from listing_jobs d where d.intake_id = x.intake_id and d.kind = 'decode_vin' and d.status in ('queued', 'running'))))
     order by case x.kind when 'decode_vin' then 0 when 'draft_copy' then 1 when 'process_photo' then 2 else 3 end, x.next_attempt_at, x.created_at
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
    v_out := v_out || jsonb_build_array(app.listing_job_context(j.id));
  end loop;
  return jsonb_build_object('jobs', v_out, 'budget', bud,
    'held', jsonb_build_object('photos', not v_photo_ok, 'copy', not v_ai_ok),
    'due', (select count(*) from listing_jobs where status = 'queued' and next_attempt_at <= p_now));
end $$;

-- The worker reports one job. p: {ok, output, provider, cost_microusd, duration_ms, units, unit, error, retryable}.
-- Success goes through app.complete_listing_job (0022), failure through app.fail_listing_job (back-off,
-- attempts, the fallback decisions of 0022). The provider call it logged gets the units used. A copy draft
-- may propose classes (0025's app.propose_listing_classes keeps only classes on the list).
create or replace function app.worker_listing_result(p_job uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  j listing_jobs;
  r jsonb;
  v_draft uuid;
  v_call uuid;
begin
  p := coalesce(p, '{}'::jsonb);
  select * into j from listing_jobs where id = p_job;
  if j.id is null then raise exception 'Listing job not found' using errcode = 'P0002'; end if;
  -- one report of an intake at a time, intake first: the photos of one car finish side by side and each
  -- report moves the intake on (0022's advance takes the intake, then the job), so the order is fixed here
  perform 1 from listing_intakes where id = j.intake_id for update;
  if coalesce((p ->> 'ok')::boolean, false) then
    r := app.complete_listing_job(p_job, coalesce(p -> 'output', '{}'::jsonb), nullif(p ->> 'provider', ''),
                                  coalesce((p ->> 'cost_microusd')::bigint, 0), (p ->> 'duration_ms')::integer);
    if j.kind = 'draft_copy' and jsonb_typeof(p -> 'output' -> 'classes') = 'array' then
      select id into v_draft from listing_drafts where intake_id = j.intake_id order by created_at desc limit 1;
      if v_draft is not null then
        perform app.propose_listing_classes(v_draft, array(select jsonb_array_elements_text(p -> 'output' -> 'classes')));
      end if;
    end if;
  else
    r := app.fail_listing_job(p_job, coalesce(nullif(btrim(p ->> 'error'), ''), 'The provider failed'),
                              coalesce((p ->> 'retryable')::boolean, true), nullif(p ->> 'provider', ''),
                              coalesce((p ->> 'cost_microusd')::bigint, 0));
  end if;
  select id into v_call from provider_calls where listing_job_id = p_job order by created_at desc limit 1;
  if v_call is not null and (p ? 'units' or p ? 'duration_ms') then
    update provider_calls set units = coalesce((p ->> 'units')::numeric, units), unit = coalesce(nullif(p ->> 'unit', ''), unit),
           duration_ms = coalesce(duration_ms, (p ->> 'duration_ms')::integer)
     where id = v_call;
  end if;
  return r;
end $$;

-- Retry one job from the screens: a failed job goes back to the queue with fresh attempts; a queued job
-- waiting out its back-off is made due now. A failed intake is retried as a whole (0022's
-- app.retry_listing_intake). Who: an Admin, Fleet or customer service, or the person who started it.
create or replace function app.retry_listing_job(p_by uuid, p_job uuid) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  j listing_jobs;
  i listing_intakes;
begin
  select * into j from listing_jobs where id = p_job for update;
  if j.id is null then raise exception 'Listing job not found' using errcode = 'P0002'; end if;
  select * into i from listing_intakes where id = j.intake_id for update;
  if not (app.user_may_list(p_by, i.vehicle_id, 'review') or app.user_is_admin(p_by) or app.user_va_has(p_by, 'fleet')
          or i.started_by = p_by) then
    raise exception 'Not permitted' using errcode = '42501';
  end if;
  if i.state in ('published', 'cancelled') then
    raise exception 'This listing is %; start a new one', i.state using errcode = '23514';
  end if;
  if j.status = 'running' then
    raise exception 'This step is running now; wait for it to finish' using errcode = '23514';
  elsif j.status = 'succeeded' then
    raise exception 'This step is done' using errcode = '23514';
  elsif j.status = 'queued' then
    update listing_jobs set next_attempt_at = now() where id = j.id;
    return jsonb_build_object('job_id', j.id, 'status', 'queued', 'state', i.state);
  end if;
  if i.state = 'failed' then
    return app.retry_listing_intake(p_by, i.id) || jsonb_build_object('job_id', j.id);
  end if;
  update listing_jobs set status = 'queued', attempts = 0, next_attempt_at = now(), error = null, finished_at = null, locked_at = null
   where id = j.id and status in ('failed', 'cancelled');
  update photo_jobs set status = 'queued', attempts = 0, next_attempt_at = now(), error = null, finished_at = null where id = j.photo_job_id;
  if j.kind = 'process_photo' then
    update vehicle_photos set background_status = 'pending' where id = j.vehicle_photo_id and background_status = 'failed';
  elsif j.kind = 'draft_copy' then
    update listing_intakes set draft_failed = false where id = i.id;
  elsif j.kind = 'decode_vin' then
    update listing_intakes set decode_failed = false where id = i.id;
  end if;
  return jsonb_build_object('job_id', j.id, 'status', 'queued', 'state', app.advance_listing_intake(i.id));
end $$;

-- Progress of an intake's run: steps by kind (done, running, waiting, failed), the failures with their
-- errors and job ids (for Retry), and what it cost.
create or replace function app.listing_progress(p_intake uuid) returns jsonb
language sql stable security definer set search_path = public, app as $$
  select jsonb_build_object(
    'intake_id', i.id, 'state', i.state, 'reason', i.reason, 'decode_failed', i.decode_failed, 'draft_failed', i.draft_failed,
    'total', (select count(*) from listing_jobs j where j.intake_id = i.id and j.status <> 'cancelled'),
    'done', (select count(*) from listing_jobs j where j.intake_id = i.id and j.status = 'succeeded'),
    'running', (select count(*) from listing_jobs j where j.intake_id = i.id and j.status = 'running'),
    'waiting', (select count(*) from listing_jobs j where j.intake_id = i.id and j.status = 'queued'),
    'failed', (select count(*) from listing_jobs j where j.intake_id = i.id and j.status = 'failed'),
    'retrying', (select count(*) from listing_jobs j where j.intake_id = i.id and j.status = 'queued' and j.attempts > 0),
    'steps', (select coalesce(jsonb_object_agg(k.kind, k.counts), '{}'::jsonb) from (
               select j.kind, jsonb_build_object('total', count(*), 'done', count(*) filter (where j.status = 'succeeded'),
                                                 'failed', count(*) filter (where j.status = 'failed')) as counts
                 from listing_jobs j where j.intake_id = i.id and j.status <> 'cancelled' group by j.kind) k),
    'problems', (select coalesce(jsonb_agg(jsonb_build_object('job_id', j.id, 'kind', j.kind, 'status', j.status, 'attempts', j.attempts,
                                                              'max_attempts', j.max_attempts, 'error', j.error, 'next_attempt_at', j.next_attempt_at,
                                                              'shot', st.label) order by j.created_at), '[]'::jsonb)
                   from listing_jobs j left join vehicle_photos ph on ph.id = j.vehicle_photo_id left join listing_shot_types st on st.code = ph.shot_type
                  where j.intake_id = i.id and (j.status = 'failed' or (j.status = 'queued' and j.error is not null))),
    'flagged_photos', (select count(*) from vehicle_photos ph where ph.intake_id = i.id and ph.replaced_at is null
                         and (ph.background_status = 'original_used' or jsonb_array_length(ph.quality_flags) > 0)),
    'cost_microusd', (select coalesce(sum(c.cost_microusd), 0) from provider_calls c where c.intake_id = i.id),
    'neurons', (select coalesce(sum(c.units), 0) from provider_calls c where c.intake_id = i.id and c.unit = 'neurons'))
    from listing_intakes i where i.id = p_intake
$$;

-- The capture screen: the shot list with what is uploaded, and what is missing.
create or replace function app.listing_capture(p_by uuid, p_intake uuid) returns jsonb
language plpgsql stable security definer set search_path = public, app as $$
declare
  i listing_intakes;
begin
  select * into i from listing_intakes where id = p_intake;
  if i.id is null then raise exception 'Listing intake not found' using errcode = 'P0002'; end if;
  if p_by is null or not (app.user_may_list(p_by, i.vehicle_id, 'start') or app.user_may_list(p_by, i.vehicle_id, 'review')) then
    raise exception 'Not permitted' using errcode = '42501';
  end if;
  return jsonb_build_object('intake_id', i.id, 'vehicle_id', i.vehicle_id, 'vehicle_name', app.vehicle_name(i.vehicle_id), 'state', i.state,
    'submitted', i.submitted_at is not null, 'reason', i.reason, 'review_required', i.review_required,
    'may_upload', i.state not in ('published', 'cancelled', 'approved'),
    'missing', to_jsonb(app.listing_missing_shots(i.vehicle_id)),
    'shots', (select coalesce(jsonb_agg(jsonb_build_object('code', s.code, 'label', s.label, 'seq', s.seq, 'required', s.required, 'max_count', s.max_count,
                'guide', s.guide, 'rebackground', s.rebackground,
                'photos', (select coalesce(jsonb_agg(jsonb_build_object('id', ph.id, 'status', ph.status, 'background_status', ph.background_status,
                              'original_path', ph.original_path, 'processed_path', ph.processed_path) order by ph.sort_order), '[]'::jsonb)
                             from vehicle_photos ph where ph.vehicle_id = i.vehicle_id and ph.shot_type = s.code and ph.replaced_at is null and ph.status <> 'rejected'))
                order by s.seq), '[]'::jsonb)
                from listing_shot_types s where s.is_active),
    'progress', app.listing_progress(i.id));
end $$;

-- =====================================================================================
-- B. Generated documents: owner statements, renter statements and receipts, insurer invoices,
--    investor statements and the yearly summary (docs/blueprint/11 sections 2, 4, 7)
-- =====================================================================================
alter type document_kind add value if not exists 'insurer_invoice';

-- One row per generated PDF that was kept: a final record (an approved statement, an issued renter
-- statement, a succeeded payment, a sent insurer invoice, an investor's month or a finished year) is
-- rendered once and stored; anything still changing is rendered for viewing and not stored.
create table generated_documents (
  kind         text not null check (kind in ('owner_statement', 'renter_statement', 'receipt', 'insurer_invoice',
                                             'investor_statement', 'investor_year')),
  entity_key   text not null check (entity_key ~ '^[0-9a-f-]{36}(:[0-9]{4})?$'),
  document_id  uuid not null references documents (id),
  sha256       text not null,
  created_at   timestamptz not null default now(),
  primary key (kind, entity_key)
);
alter table generated_documents enable row level security;
create policy admin_all on generated_documents for all to authenticated using (app.is_admin()) with check (app.is_admin());
create trigger audit_generated_documents after insert or update or delete on generated_documents
  for each row execute function app.audit_row();

-- The pieces of a key: '<uuid>' or '<investor uuid>:<year>'.
create or replace function app.file_key_id(p_key text) returns uuid
language sql immutable as $$ select case when p_key ~ '^[0-9a-f-]{36}' then left(p_key, 36)::uuid end $$;
create or replace function app.file_key_year(p_key text) returns integer
language sql immutable as $$ select case when p_key ~ ':[0-9]{4}$' then right(p_key, 4)::integer end $$;

-- Who may download a generated document: staff by function, and each customer their own final records.
create or replace function app.file_access(p_user uuid, p_kind text, p_key text) returns boolean
language plpgsql stable security definer set search_path = public, app as $$
declare
  v_id uuid := app.file_key_id(p_key);
  v_fin boolean := p_user is not null and app.user_runs_finance(p_user);
begin
  if p_user is null or v_id is null then return false; end if;
  case p_kind
  when 'owner_statement' then
    return v_fin or exists (select 1 from owner_statements s join owners o on o.id = s.owner_id
                             where s.id = v_id and o.user_id = p_user and s.status in ('approved', 'paid'));
  when 'renter_statement' then
    return v_fin or exists (select 1 from booking_statements s join bookings b on b.id = s.booking_id join renters r on r.id = b.renter_id
                             where s.id = v_id and r.user_id = p_user);
  when 'receipt' then
    return v_fin or exists (select 1 from payments p join renters r on r.id = coalesce(p.renter_id, (select b.renter_id from bookings b where b.id = p.booking_id))
                             where p.id = v_id and r.user_id = p_user and p.status = 'succeeded' and p.kind in ('charge', 'capture'))
                 or exists (select 1 from payments p join owners o on o.id = p.owner_id
                             where p.id = v_id and o.user_id = p_user and p.status = 'succeeded' and p.kind in ('charge', 'capture'));
  when 'insurer_invoice' then
    return v_fin;
  when 'investor_statement' then
    return app.user_is_admin(p_user) or exists (select 1 from investment_returns r join investments x on x.id = r.investment_id
                                                  join investors i on i.id = x.investor_id where r.id = v_id and i.user_id = p_user);
  when 'investor_year' then
    return app.user_is_admin(p_user) or exists (select 1 from investors i where i.id = v_id and i.user_id = p_user);
  else
    return false;
  end case;
end $$;

-- The company block every document prints (the legal name where the law needs it: invoices and statements).
create or replace function app.doc_company() returns jsonb
language sql stable security definer set search_path = public, app as $$
  select jsonb_build_object('brand', coalesce(ss.brand_name, 'CarmaCars'), 'legal_name', ps.company_legal_name,
    'address', coalesce(nullif(ps.company_address, ''), nullif(ss.mailing_address, ''), ''), 'hst_number', ps.company_hst_number,
    'phone', coalesce(nullif(ss.phone, ''), nullif(ps.company_phone, ''), ''), 'email', coalesce(nullif(ss.public_email, ''), 'contact@carmacars.ca'),
    'site', coalesce(nullif(ss.site_url, ''), 'https://carmacars.ca'))
    from (select 1) one
    left join lateral (select * from site_settings order by created_at limit 1) ss on true
    left join lateral (select * from app.settings()) ps on true
$$;

-- Everything a document prints, by kind. 'final' says whether the record can no longer change (then the
-- PDF is stored once). 'title' and 'file_name' name it.
create or replace function app.pdf_facts(p_kind text, p_key text, p_user uuid default null) returns jsonb
language plpgsql stable security definer set search_path = public, app as $$
declare
  v_id uuid := app.file_key_id(p_key);
  v_year integer := app.file_key_year(p_key);
  st owner_statements;
  bs booking_statements;
  pay payments;
  ii insurer_invoices;
  ir investment_returns;
  inv investors;
  b bookings;
  v_out jsonb;
begin
  case p_kind
  when 'owner_statement' then
    select * into st from owner_statements where id = v_id;
    if st.id is null then return null; end if;
    -- read as the person downloading (staff see a draft as a preview), or as the owner for a signed link
    v_out := app.owner_statement_breakdown(st.id, coalesce(p_user, (select o.user_id from owners o where o.id = st.owner_id)));
    return v_out || jsonb_build_object('final', st.status in ('approved', 'paid'), 'title', 'Owner statement ' || st.statement_number,
      'file_name', 'carmacars-statement-' || to_char(st.statement_month, 'YYYY-MM') || '-' || st.statement_number || '.pdf',
      'owner', (select jsonb_build_object('legal_name', o.legal_name, 'address', concat_ws(', ', o.address_line1, o.address_line2, o.city, o.province, o.postal_code),
                                          'hst_number', o.hst_number) from owners o where o.id = st.owner_id),
      'owner_id', st.owner_id, 'totals', jsonb_build_object('owner_revenue_cents', st.owner_revenue_cents, 'revenue_share_cents', st.revenue_share_cents,
        'net_earnings_cents', st.net_earnings_cents, 'deductions_cents', st.deductions_cents, 'vehicles_payable_cents', st.vehicles_payable_cents,
        'arrears_moved_cents', st.arrears_moved_cents, 'kickbacks_earned_cents', st.kickbacks_earned_cents, 'hst_on_payout_cents', st.hst_on_payout_cents,
        'balance_brought_forward_cents', st.balance_brought_forward_cents, 'payout_cents', st.payout_cents,
        'balance_carried_forward_cents', st.balance_carried_forward_cents),
      'paid', (select jsonb_build_object('paid_at', p.paid_at, 'method', p.method, 'reference', p.reference) from payouts p
                where p.owner_statement_id = st.id and p.status = 'paid' order by p.paid_at desc limit 1),
      'company', app.doc_company());
  when 'renter_statement' then
    select * into bs from booking_statements where id = v_id;
    if bs.id is null then return null; end if;
    select * into b from bookings where id = bs.booking_id;
    return jsonb_build_object('final', true, 'title', 'Statement ' || bs.statement_number, 'file_name', 'carmacars-statement-' || bs.statement_number || '.pdf',
      'statement_number', bs.statement_number, 'kind', bs.kind, 'issued_at', bs.issued_at, 'booking_number', b.booking_number,
      'vehicle', app.vehicle_name(b.vehicle_id), 'pickup_at', b.pickup_at, 'return_at', b.return_at,
      'handed_over_at', b.handed_over_at, 'checked_in_at', b.checked_in_at,
      'renter', (select jsonb_build_object('legal_name', r.legal_name, 'email', r.email) from renters r where r.id = b.renter_id),
      'lines', (select coalesce(jsonb_agg(jsonb_build_object('label', coalesce(nullif(btrim(l.description), ''), f.label, initcap(replace(l.charge_type, '_', ' '))),
                                 'amount_cents', l.amount_cents, 'hst_cents', l.hst_cents) order by l.created_at, l.id), '[]'::jsonb)
                  from booking_line_items l left join fee_types f on f.code = l.charge_type
                 where l.statement_id = bs.id and l.voided_at is null),
      'charges_cents', bs.charges_cents, 'hst_cents', bs.hst_cents, 'deposit_applied_cents', bs.deposit_applied_cents,
      'held_back_cents', bs.held_back_cents, 'deposit_returned_cents', bs.deposit_returned_cents, 'charged_to_card_cents', bs.charged_to_card_cents,
      'interest_starts_on', bs.interest_starts_on, 'paid_at', bs.paid_at, 'company', app.doc_company());
  when 'receipt' then
    select * into pay from payments where id = v_id;
    if pay.id is null or pay.status <> 'succeeded' or pay.kind not in ('charge', 'capture') then return null; end if;
    select * into b from bookings where id = pay.booking_id;
    return jsonb_build_object('final', true, 'title', 'Receipt ' || upper(left(pay.id::text, 8)),
      'file_name', 'carmacars-receipt-' || upper(left(pay.id::text, 8)) || '.pdf',
      'receipt_number', 'R-' || upper(left(pay.id::text, 8)), 'paid_at', coalesce(pay.processed_at, pay.updated_at), 'amount_cents', pay.amount_cents,
      'purpose', pay.purpose, 'method', pay.method, 'card_brand', pay.card_brand, 'card_last4', pay.card_last4,
      'booking_number', b.booking_number, 'vehicle', case when b.id is not null then app.vehicle_name(b.vehicle_id) end,
      'payer', coalesce((select jsonb_build_object('legal_name', r.legal_name) from renters r where r.id = coalesce(pay.renter_id, b.renter_id)),
                        (select jsonb_build_object('legal_name', o.legal_name) from owners o where o.id = pay.owner_id)),
      'invoice_number', (select oi.invoice_number from owner_invoices oi where oi.id = pay.owner_invoice_id),
      'lines', (select coalesce(jsonb_agg(jsonb_build_object('label', coalesce(nullif(btrim(l.description), ''), f.label, initcap(replace(l.charge_type, '_', ' '))),
                                 'amount_cents', l.amount_cents, 'hst_cents', l.hst_cents) order by l.created_at, l.id), '[]'::jsonb)
                  from booking_line_items l left join fee_types f on f.code = l.charge_type where l.payment_id = pay.id and l.voided_at is null),
      'company', app.doc_company());
  when 'insurer_invoice' then
    select * into ii from insurer_invoices where id = v_id;
    if ii.id is null then return null; end if;
    select * into b from bookings where id = ii.booking_id;
    return jsonb_build_object('final', ii.status <> 'draft', 'title', 'Invoice ' || ii.invoice_number, 'file_name', 'carmacars-invoice-' || ii.invoice_number || '.pdf',
      'invoice_number', ii.invoice_number, 'status', ii.status, 'sent_at', ii.sent_at, 'created_at', ii.created_at, 'claim_number', ii.claim_number,
      'period_start', ii.period_start, 'period_end', ii.period_end, 'amount_cents', ii.amount_cents, 'hst_cents', ii.hst_cents,
      'total_cents', ii.total_cents, 'paid_cents', ii.paid_cents, 'balance_cents', ii.balance_cents, 'lines', ii.lines,
      'insurer', (select jsonb_build_object('name', x.name, 'contact', x.billing_contact_name, 'email', x.billing_email, 'address', x.billing_address)
                    from insurers x where x.id = ii.insurer_id),
      'booking_number', b.booking_number, 'vehicle', app.vehicle_name(b.vehicle_id),
      'renter_name', (select r.legal_name from renters r where r.id = b.renter_id), 'company', app.doc_company());
  when 'investor_statement' then
    select * into ir from investment_returns where id = v_id;
    if ir.id is null then return null; end if;
    select i.* into inv from investors i join investments x on x.investor_id = i.id where x.id = ir.investment_id;
    return jsonb_build_object('final', true, 'title', 'Investor statement ' || to_char(ir.return_month, 'FMMonth YYYY'),
      'file_name', 'carmacars-investor-statement-' || to_char(ir.return_month, 'YYYY-MM') || '.pdf',
      'statement_number', 'IS-' || to_char(ir.return_month, 'YYYYMM') || '-' || upper(left(ir.investment_id::text, 6)),
      'investor', jsonb_build_object('legal_name', inv.legal_name, 'address', inv.address),
      'agreement_number', (select a.agreement_number from investment_agreements a join investments x on x.agreement_id = a.id where x.id = ir.investment_id),
      'return_month', ir.return_month, 'opening_invested_cents', ir.opening_invested_cents, 'yearly_bps', ir.yearly_bps,
      'days_earning', ir.days_earning, 'days_in_month', ir.days_in_month, 'return_cents', ir.return_cents, 'withheld_tax_cents', ir.withheld_tax_cents,
      'disposition', ir.disposition, 'status', ir.status, 'payment_date', ir.payment_date, 'closing_invested_cents', ir.closing_invested_cents,
      'company', app.doc_company());
  when 'investor_year' then
    select * into inv from investors where id = v_id;
    if inv.id is null or v_year is null then return null; end if;
    return jsonb_build_object('final', v_year < extract(year from app.today())::integer, 'title', 'Yearly summary ' || v_year,
      'file_name', 'carmacars-investor-summary-' || v_year || '.pdf', 'year', v_year,
      'investor', jsonb_build_object('legal_name', inv.legal_name, 'address', inv.address),
      'months', (select coalesce(jsonb_agg(jsonb_build_object('return_month', r.return_month, 'opening_invested_cents', r.opening_invested_cents,
                   'return_cents', r.return_cents, 'withheld_tax_cents', r.withheld_tax_cents, 'disposition', r.disposition, 'status', r.status,
                   'closing_invested_cents', r.closing_invested_cents) order by r.return_month, r.id), '[]'::jsonb)
                   from investment_returns r join investments x on x.id = r.investment_id
                  where x.investor_id = inv.id and extract(year from r.return_month) = v_year),
      'totals', (select jsonb_build_object('return_cents', coalesce(sum(r.return_cents), 0), 'withheld_tax_cents', coalesce(sum(r.withheld_tax_cents), 0),
                   'reinvested_cents', coalesce(sum(r.return_cents) filter (where r.disposition = 'reinvest'), 0),
                   'paid_cents', coalesce(sum(r.return_cents - r.withheld_tax_cents) filter (where r.status = 'paid'), 0))
                   from investment_returns r join investments x on x.id = r.investment_id
                  where x.investor_id = inv.id and extract(year from r.return_month) = v_year),
      'investments', (select coalesce(jsonb_agg(jsonb_build_object('investment_date', x.investment_date, 'principal_cents', x.principal_cents,
                        'invested_amount_cents', x.invested_amount_cents, 'yearly_bps', x.yearly_bps, 'status', x.status) order by x.investment_date), '[]'::jsonb)
                        from investments x where x.investor_id = inv.id),
      'company', app.doc_company());
  else
    raise exception 'Unknown document %', p_kind using errcode = '22023';
  end case;
end $$;

-- The stored copy of a generated document, if there is one.
create or replace function app.file_stored(p_kind text, p_key text) returns jsonb
language sql stable security definer set search_path = public, app as $$
  select jsonb_build_object('document_id', d.id, 'bucket', d.storage_bucket, 'path', d.storage_path, 'mime_type', d.mime_type, 'title', d.title,
                            'sha256', g.sha256)
    from generated_documents g join documents d on d.id = g.document_id
   where g.kind = p_kind and g.entity_key = p_key and d.storage_path is not null
$$;

-- Keep a generated PDF the server stored: a documents row linked to its record (owner, booking, investor,
-- and the record's own document column where it has one). A second call for the same record returns the
-- first document.
create or replace function app.file_record(p_kind text, p_key text, p_bucket text, p_path text, p_sha256 text, p_title text) returns uuid
language plpgsql security definer set search_path = public, app as $$
declare
  v_id uuid := app.file_key_id(p_key);
  v_doc uuid;
  v_owner uuid; v_booking uuid; v_investor uuid; v_renter uuid;
  v_dkind document_kind;
begin
  select document_id into v_doc from generated_documents where kind = p_kind and entity_key = p_key;
  if v_doc is not null then return v_doc; end if;
  if nullif(btrim(p_path), '') is null or nullif(btrim(p_sha256), '') is null then
    raise exception 'A stored document needs its path and SHA-256' using errcode = '22023';
  end if;
  case p_kind
  when 'owner_statement' then
    select owner_id into v_owner from owner_statements where id = v_id; v_dkind := 'owner_statement';
  -- a renter's statement and receipt are listed with the booking from the record itself (app.files_for),
  -- so their documents rows are not tied to the booking a second time
  when 'renter_statement' then
    v_dkind := 'renter_statement';
  when 'receipt' then
    select owner_id into v_owner from payments where id = v_id; v_dkind := 'receipt';
  when 'insurer_invoice' then
    -- linked through insurer_invoices.document_id only: a renter never lists the insurer's invoice
    v_dkind := 'insurer_invoice'::text::document_kind;
  when 'investor_statement' then
    select x.investor_id into v_investor from investment_returns r join investments x on x.id = r.investment_id where r.id = v_id;
    v_dkind := 'investor_statement';
  when 'investor_year' then
    v_investor := v_id; v_dkind := 'investor_statement';
  else
    raise exception 'Unknown document %', p_kind using errcode = '22023';
  end case;
  insert into documents (kind, title, storage_bucket, storage_path, mime_type, sha256, owner_id, booking_id, investor_id, renter_id)
  values (v_dkind, left(p_title, 200), p_bucket, p_path, 'application/pdf', p_sha256, v_owner, v_booking, v_investor, v_renter)
  returning id into v_doc;
  insert into generated_documents (kind, entity_key, document_id, sha256) values (p_kind, p_key, v_doc, p_sha256);
  case p_kind
  when 'owner_statement' then update owner_statements set document_id = v_doc where id = v_id and document_id is null;
  when 'renter_statement' then update booking_statements set document_id = v_doc where id = v_id and document_id is null;
  when 'insurer_invoice' then update insurer_invoices set document_id = v_doc where id = v_id and document_id is null;
  when 'investor_statement' then update investment_returns set statement_document_id = v_doc where id = v_id and statement_document_id is null;
  else null;
  end case;
  return v_doc;
end $$;

-- The documents a customer or staff member can download for a record, for the portal and admin screens.
create or replace function app.files_for(p_user uuid, p_what text, p_id uuid) returns jsonb
language plpgsql stable security definer set search_path = public, app as $$
declare
  v_out jsonb := '[]'::jsonb;
  r record;
begin
  if p_what = 'booking' then
    for r in select 'renter_statement' as kind, s.id::text as key, 'Statement ' || s.statement_number as title, s.issued_at as at
               from booking_statements s where s.booking_id = p_id
             union all
             select 'receipt', p.id::text, 'Receipt for ' || replace(p.purpose, '_', ' ') || ' ' || app.fmt_money(p.amount_cents), coalesce(p.processed_at, p.created_at)
               from payments p where p.booking_id = p_id and p.status = 'succeeded' and p.kind in ('charge', 'capture')
             union all
             select 'insurer_invoice', ii.id::text, 'Insurer invoice ' || ii.invoice_number, ii.created_at
               from insurer_invoices ii where ii.booking_id = p_id
             order by 4 loop
      if app.file_access(p_user, r.kind, r.key) then
        v_out := v_out || jsonb_build_object('kind', r.kind, 'key', r.key, 'title', r.title, 'at', r.at);
      end if;
    end loop;
  elsif p_what = 'investor' then
    for r in select distinct extract(year from rr.return_month)::integer as y
               from investment_returns rr join investments x on x.id = rr.investment_id where x.investor_id = p_id order by 1 desc loop
      if app.file_access(p_user, 'investor_year', p_id || ':' || r.y) then
        v_out := v_out || jsonb_build_object('kind', 'investor_year', 'key', p_id || ':' || r.y, 'title', 'Yearly summary ' || r.y, 'year', r.y);
      end if;
    end loop;
  else
    raise exception 'Unknown list %', p_what using errcode = '22023';
  end if;
  return v_out;
end $$;

-- The signed file links the email sender puts in an email that promises a document (7 days). Returns, per
-- link variable of the email, the record the link opens: {var: {k, key}} for a generated document, or
-- {var: {k: 'document', key: <documents.id>}} for a stored file (a signed agreement, a notice).
create or replace function app.outbox_file_refs(p_outbox uuid) returns jsonb
language plpgsql stable security definer set search_path = public, app as $$
declare
  o notification_outbox;
  v_doc uuid;
  v_out jsonb := '{}'::jsonb;
begin
  select * into o from notification_outbox where id = p_outbox;
  if o.id is null then return v_out; end if;
  case o.code
  when 'renter_payment_receipt' then
    if o.entity = 'payment' then v_out := jsonb_build_object('receipt_url', jsonb_build_object('k', 'receipt', 'key', o.entity_id::text)); end if;
  when 'investor_statement_ready', 'investor_return_paid' then
    if o.entity = 'investment_return' then v_out := jsonb_build_object('statement_url', jsonb_build_object('k', 'investor_statement', 'key', o.entity_id::text)); end if;
  when 'insurer_invoice' then
    v_out := jsonb_build_object('invoice_url', jsonb_build_object('k', 'insurer_invoice', 'key', o.entity_id::text));
  when 'renter_agreement_signed' then
    select sr.signed_document_id into v_doc from rental_agreements a join signature_requests sr on sr.id = a.signature_request_id
     where a.id = o.entity_id;
    if v_doc is not null then v_out := jsonb_build_object('signed_agreement_url', jsonb_build_object('k', 'document', 'key', v_doc::text)); end if;
  when 'renter_extra_charge' then
    if o.entity = 'booking_statement' then
      v_out := jsonb_build_object('supporting_document_url', jsonb_build_object('k', 'renter_statement', 'key', o.entity_id::text));
    end if;
  when 'owner_toll_ticket', 'renter_named_to_authority' then
    select document_id into v_doc from toll_tickets where id = o.entity_id;
    if v_doc is not null then v_out := jsonb_build_object('supporting_document_url', jsonb_build_object('k', 'document', 'key', v_doc::text)); end if;
  else
    null;
  end case;
  return v_out;
end $$;

-- A stored file by its documents row (for the signed email links of k = 'document').
create or replace function app.document_file(p_document uuid) returns jsonb
language sql stable security definer set search_path = public, app as $$
  select jsonb_build_object('bucket', d.storage_bucket, 'path', d.storage_path, 'mime_type', d.mime_type, 'title', d.title)
    from documents d where d.id = p_document and d.storage_path is not null and d.purged_at is null
$$;

-- =====================================================================================
-- C. Money: refunds through the payments module, the guided Deposit settlement, the insurer email
-- =====================================================================================
-- Issue an approved refund. The server calls 'begin', sends the refund to the processor with the
-- idempotency key it returns (refund:<id>), then 'finish' with the result. A second 'begin' of a refund
-- already paid returns {already: true}; one left in 'processing' (a crash between the two) is begun again
-- with the same key, so the processor answers with the same refund and nothing is paid twice.
create or replace function app.refund_issue_begin(p_by uuid, p_refund uuid) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  rf refunds;
  pay payments;
  pd payment_processor_details;
begin
  if not app.user_runs_finance(p_by) then raise exception 'Finance or an Admin issues a refund' using errcode = '42501'; end if;
  select * into rf from refunds where id = p_refund for update;
  if rf.id is null then raise exception 'Refund not found' using errcode = 'P0002'; end if;
  if rf.status = 'paid' then return jsonb_build_object('already', true, 'refund_id', rf.id, 'status', rf.status); end if;
  if rf.status not in ('approved', 'processing', 'failed') then
    raise exception 'Only an approved refund is issued (this one is %)', replace(rf.status, '_', ' ') using errcode = '23514';
  end if;
  if rf.amount_cents <= 0 then raise exception 'A refund of nothing is not issued' using errcode = '23514'; end if;
  select * into pay from payments where id = rf.payment_id;
  if pay.id is null or pay.status <> 'succeeded' then
    raise exception 'The payment being refunded is not on record as paid' using errcode = '23514';
  end if;
  select * into pd from payment_processor_details where payment_id = pay.id;
  if pay.method <> 'card' or coalesce(pd.processor_payment_id, pd.processor_charge_id) is null then
    raise exception 'This payment was not taken by card through the processor; send the money back by bank and mark the refund paid'
      using errcode = '23514';
  end if;
  if rf.amount_cents > pay.amount_cents - coalesce((select sum(x.amount_cents) from refunds x where x.payment_id = pay.id and x.status = 'paid' and x.id <> rf.id), 0) then
    raise exception 'The refund is more than what is left of the payment' using errcode = '23514';
  end if;
  update refunds set status = 'processing' where id = rf.id and status <> 'processing';
  return jsonb_build_object('refund_id', rf.id, 'amount_cents', rf.amount_cents, 'currency', pay.currency, 'payment_id', pay.id,
    'processor', coalesce(pd.processor, 'stripe'), 'payment_intent', pd.processor_payment_id, 'charge', pd.processor_charge_id,
    'idempotency_key', 'refund:' || rf.id, 'booking_id', rf.booking_id, 'reason', rf.reason);
end $$;

-- p: {ok, processor_refund_id, status ('succeeded' | 'pending' | 'failed'), error, raw}
create or replace function app.refund_issue_finish(p_by uuid, p_refund uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  rf refunds;
  pay payments;
  v_pay uuid;
  v_status text := coalesce(p ->> 'status', case when coalesce((p ->> 'ok')::boolean, false) then 'succeeded' else 'failed' end);
begin
  if not app.user_runs_finance(p_by) then raise exception 'Finance or an Admin issues a refund' using errcode = '42501'; end if;
  select * into rf from refunds where id = p_refund for update;
  if rf.id is null then raise exception 'Refund not found' using errcode = 'P0002'; end if;
  if rf.status = 'paid' then return jsonb_build_object('already', true, 'refund_id', rf.id, 'status', 'paid'); end if;
  if rf.status <> 'processing' then raise exception 'This refund was not being issued' using errcode = '23514'; end if;
  select * into pay from payments where id = rf.payment_id;
  if v_status = 'failed' then
    update refunds set status = 'failed', note = concat_ws(' | ', note, 'Processor: ' || coalesce(nullif(btrim(p ->> 'error'), ''), 'refused')) where id = rf.id;
    return jsonb_build_object('refund_id', rf.id, 'status', 'failed');
  end if;
  if nullif(btrim(p ->> 'processor_refund_id'), '') is null then
    raise exception 'The processor''s refund id is missing' using errcode = '22023';
  end if;
  -- one refund transaction per refund: a repeated finish finds it by the processor's id
  select pd.payment_id into v_pay from payment_processor_details pd join payments x on x.id = pd.payment_id
   where pd.processor_refund_id = p ->> 'processor_refund_id' and x.parent_payment_id = pay.id and x.kind = 'refund';
  if v_pay is null then
    insert into payments (booking_id, renter_id, owner_id, purpose, kind, method, amount_cents, currency, status, parent_payment_id,
                          card_brand, card_last4, processed_at, created_by)
    values (rf.booking_id, pay.renter_id, pay.owner_id, pay.purpose, 'refund', pay.method, rf.amount_cents, pay.currency,
            case when v_status = 'succeeded' then 'succeeded' else 'pending' end, pay.id, pay.card_brand, pay.card_last4,
            case when v_status = 'succeeded' then now() end, p_by)
    returning id into v_pay;
    insert into payment_processor_details (payment_id, processor, processor_payment_id, processor_charge_id, processor_refund_id, raw)
    select v_pay, coalesce(pd.processor, 'stripe'), pd.processor_payment_id, pd.processor_charge_id, p ->> 'processor_refund_id', p -> 'raw'
      from payment_processor_details pd where pd.payment_id = pay.id;
  end if;
  update refunds set status = case when v_status = 'succeeded' then 'paid' else 'processing' end,
         paid_at = case when v_status = 'succeeded' then now() else paid_at end, refund_payment_id = v_pay
   where id = rf.id;
  return jsonb_build_object('refund_id', rf.id, 'status', (select status from refunds where id = rf.id), 'payment_id', v_pay);
end $$;

-- The guided Deposit settlement: what the form shows before anything moves (the same arithmetic as
-- 0020's app.settle_deposit, which decides).
create or replace function app.deposit_preview(p_by uuid, p_booking uuid) returns jsonb
language plpgsql stable security definer set search_path = public, app as $$
declare
  b bookings;
  d deposits;
  s program_settings := app.settings();
  v_due bigint;
  v_available bigint := 0;
begin
  if not app.user_runs_finance(p_by) then raise exception 'Finance or an Admin settles a Deposit' using errcode = '42501'; end if;
  select * into b from bookings where id = p_booking;
  if b.id is null then raise exception 'Booking not found' using errcode = 'P0002'; end if;
  select * into d from deposits where booking_id = b.id;
  select coalesce(sum(x.open_cents), 0) into v_due from (
    select l2.amount_cents + l2.hst_cents - coalesce((select sum(e.amount_cents) from deposit_events e where e.line_item_id = l2.id and e.kind = 'applied'), 0) as open_cents
      from booking_line_items l2
     where l2.booking_id = b.id and l2.statement_id is not null and l2.payment_id is null and l2.voided_at is null and l2.charged_to_renter) x
   where x.open_cents > 0;
  if d.id is not null and d.status not in ('pending', 'failed', 'carried_forward') then
    v_available := d.amount_cents - d.applied_cents - d.released_cents;
  end if;
  return jsonb_build_object('booking_id', b.id, 'booking_number', b.booking_number, 'status', b.status,
    'has_statement', exists (select 1 from booking_statements x where x.booking_id = b.id and x.kind = 'check_in'),
    'deposit', case when d.id is not null then jsonb_build_object('status', d.status, 'method', d.method, 'amount_cents', d.amount_cents,
                 'applied_cents', d.applied_cents, 'held_back_cents', d.held_back_cents, 'held_back_reason', d.held_back_reason,
                 'held_back_until', d.held_back_until, 'released_cents', d.released_cents) end,
    'available_cents', v_available, 'due_cents', v_due, 'apply_cents', least(v_due, v_available),
    'shortfall_cents', greatest(v_due - v_available, 0),
    'hold_back_max_cents', greatest(v_available - least(v_due, v_available), 0),
    'hold_back_until_max', case when b.checked_in_at is not null then app.local_date(b.checked_in_at) + s.deposit_holdback_days end,
    'holdback_days', s.deposit_holdback_days,
    'may_release_without_approval', app.user_is_admin(p_by));
end $$;

-- The insurer invoice email (catalogue code insurer_invoice): a draft is sent first (as 0030's
-- insurer_invoice_send), then the email goes to the insurer's billing address with a 7-day link to the PDF.
-- Each send is one event; "send again" makes a new one.
create or replace function app.send_insurer_invoice_email(p_by uuid, p_invoice uuid) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  ii insurer_invoices;
  v_email text;
  v_n integer;
  v_event bigint;
begin
  if not app.user_runs_finance(p_by) then raise exception 'Finance or an Admin sends an insurer invoice' using errcode = '42501'; end if;
  select * into ii from insurer_invoices where id = p_invoice for update;
  if ii.id is null then raise exception 'Insurer invoice not found' using errcode = 'P0002'; end if;
  if ii.status in ('paid', 'written_off') then raise exception 'This invoice is %', replace(ii.status, '_', ' ') using errcode = '23514'; end if;
  select nullif(btrim(billing_email), '') into v_email from insurers where id = ii.insurer_id;
  if v_email is null then
    raise exception 'The insurer has no billing email: add it in Settings, Insurers' using errcode = '23514';
  end if;
  if ii.status = 'draft' then
    update insurer_invoices set status = 'sent', sent_at = now(), sent_by = p_by where id = ii.id;
  end if;
  select count(*) into v_n from app_events where code = 'insurer_invoice' and entity = 'insurer_invoice' and entity_id = ii.id;
  v_event := app.emit_event('insurer_invoice', 'insurer_invoice', ii.id, jsonb_build_object('insurer_id', ii.insurer_id),
                            'insurer_invoice:' || ii.id || ':send' || (v_n + 1));
  return jsonb_build_object('invoice_id', ii.id, 'status', (select status from insurer_invoices where id = ii.id), 'event_id', v_event,
                            'to', v_email, 'sends', v_n + 1);
end $$;

-- =====================================================================================
-- D. The insurer email in the notification layer
-- =====================================================================================
create or replace function app.notification_catalogue_refresh() returns integer
language plpgsql security definer set search_path = public, app as $$
declare
  n integer;
begin
  update notification_catalogue c
     set priority = case when c.category = 'marketing' then 5
                         when c.code like 'staff_digest_%' or c.code like 'staff_field_jobs_%' or c.code = 'staff_weekly_summary' then 4
                         when c.audience like 'staff_%' then 3
                         when c.audience in ('owner', 'investor', 'insurer') then 2
                         else 1 end,
         consent_rule = case when c.code in ('renter_comeback_1w', 'renter_comeback_1m') then 'express'
                             when c.category = 'marketing' then 'implied' end,
         user_can_mute = c.category = 'marketing' or c.code like 'staff_digest_%' or c.code = 'staff_weekly_summary',
         sender_supplied = coalesce((select array_agg(v ->> 'name' order by v ->> 'name')
                                       from jsonb_array_elements(c.variables) v
                                      where v ->> 'name' in ('verify_url', 'reset_url', 'sign_in_url', 'link_expiry',
                                                             'signed_agreement_url', 'receipt_url', 'statement_url', 'invoice_url',
                                                             'supporting_document_url', 'security_device', 'security_event',
                                                             'security_event_at', 'security_place')), '{}'),
         updated_at = now()
   where c.has_email;
  get diagnostics n = row_count;
  insert into message_templates (code, purpose, audience, version)
  select c.code, left(c.subject, 200),
         case when c.audience like 'staff_%' then 'internal' when c.audience in ('owner', 'investor', 'insurer') then 'owner' else 'renter' end, 1
    from notification_catalogue c
  on conflict (code) do nothing;
  return n;
end $$;

-- The catalogue row (emails/src/emails/insurer_invoice.mjs; the deploy loads the template contents).
insert into notification_catalogue (code, audience, also_sent_to, category, is_digest, digest_slot, from_address, reply_to, subject, preheader,
                                    timing, trigger_text, replaces_template, link_path, variables, template_html, template_text)
values ('insurer_invoice', 'insurer', '{}'::text[], 'transactional', false, null, 'CarmaCars <billing@carmacars.ca>', 'billing@carmacars.ca',
  'Invoice {{invoice_number}} for {{renter_name}}: {{invoice_total}}',
  'Rental of a {{vehicle_name}}, {{period}}. Claim {{claim_number}}.',
  'When Finance or an Admin sends the invoice',
  'An insurer invoice is sent from the admin portal (Send by email): the invoice for a replacement rental billed to an insurer, with a 7-day link to the PDF. Sending again sends a new email.',
  null, null,
  '[{"name":"claim_number","type":"string"},{"name":"company_address","type":"string","global":true},{"name":"contact_email","type":"string","global":true},{"name":"first_name","type":"string"},{"name":"instagram_url","type":"url","global":true},{"name":"insurer_name","type":"string"},{"name":"invoice_amount","type":"string"},{"name":"invoice_hst","type":"string"},{"name":"invoice_lines","type":"list","fields":["label","amount"]},{"name":"invoice_number","type":"string"},{"name":"invoice_total","type":"string"},{"name":"invoice_url","type":"url"},{"name":"link_expiry","type":"string"},{"name":"opening_hours","type":"string","global":true},{"name":"period","type":"string"},{"name":"renter_name","type":"string"},{"name":"reply_time","type":"string","global":true},{"name":"support_phone","type":"string","global":true},{"name":"tiktok_url","type":"url","global":true},{"name":"vehicle_name","type":"string"}]'::jsonb,
  'templates/insurer_invoice.html', 'templates/insurer_invoice.txt')
on conflict (code) do nothing;
update notification_catalogue set emitted_by = 'app.send_insurer_invoice_email (0032)' where code = 'insurer_invoice';
select app.notification_catalogue_refresh();

-- Who receives an event: as 0018, and the insurer audience (the insurer's billing email; payload insurer_id).
create or replace function app.notification_recipients(p_event app_events, p_c notification_catalogue)
returns table (audience text, user_id uuid, email text, name text, renter_id uuid, owner_id uuid, immediate boolean)
language plpgsql stable security definer set search_path = public, app as $$
declare
  p jsonb := p_event.payload;
  v_booking uuid := coalesce((p ->> 'booking_id')::uuid, case when p_event.entity = 'booking' then p_event.entity_id end);
  v_vehicle uuid := coalesce((p ->> 'vehicle_id')::uuid, case when p_event.entity = 'vehicle' then p_event.entity_id end);
  v_renter uuid;
  v_owner uuid;
  v_roles text[];
  v_role text;
begin
  if p_c.audience = 'insurer' then
    return query select 'insurer'::text, null::uuid, btrim(x.billing_email), coalesce(nullif(btrim(x.billing_contact_name), ''), x.name),
                        null::uuid, null::uuid, true
                   from insurers x where x.id = (p ->> 'insurer_id')::uuid and nullif(btrim(x.billing_email), '') is not null;
    return;
  elsif p_c.audience = 'renter' then
    if p ? 'signer_email' or p ? 'signer_user_id' then
      return query select 'renter'::text, (p ->> 'signer_user_id')::uuid,
                          coalesce(nullif(p ->> 'signer_email', ''), (select u.email from users u where u.id = (p ->> 'signer_user_id')::uuid)),
                          p ->> 'signer_name', null::uuid, null::uuid, true;
      return;
    end if;
    if jsonb_typeof(p -> 'signers') = 'array' then
      return query select 'renter'::text, (g ->> 'signer_user_id')::uuid, g ->> 'signer_email', g ->> 'signer_name',
                          null::uuid, null::uuid, true
                     from jsonb_array_elements(p -> 'signers') g
                    where coalesce(g ->> 'signer_role', '') <> 'carmacars' and nullif(g ->> 'signer_email', '') is not null;
      return;
    end if;
    v_renter := coalesce((p ->> 'renter_id')::uuid, (select b.renter_id from bookings b where b.id = v_booking),
                         case when p_event.entity = 'user' then (select r.id from renters r where r.user_id = p_event.entity_id) end);
    if v_renter is null and p_event.entity = 'user' then
      return query select 'renter'::text, u.id, u.email, u.full_name, null::uuid, null::uuid, true from users u where u.id = p_event.entity_id;
      return;
    end if;
    return query select 'renter'::text, r.user_id, coalesce(nullif(r.email, ''), u.email), r.legal_name, r.id, null::uuid, true
                   from renters r left join users u on u.id = r.user_id where r.id = v_renter;
    return;
  elsif p_c.audience = 'owner' then
    v_owner := coalesce((p ->> 'owner_id')::uuid,
                        case when p_event.entity = 'owner' then p_event.entity_id end,
                        (select b.owner_id from bookings b where b.id = v_booking),
                        (select v.owner_id from vehicles v where v.id = v_vehicle));
    if v_owner is null and p_event.entity = 'user' then
      return query select 'owner'::text, u.id, u.email, u.full_name, null::uuid, null::uuid, true from users u where u.id = p_event.entity_id;
      return;
    end if;
    if v_owner is null and nullif(p ->> 'email', '') is not null then
      return query select 'owner'::text, null::uuid, p ->> 'email', coalesce(p ->> 'owner_name', p ->> 'first_name'), null::uuid, null::uuid, true;
      return;
    end if;
    return query select 'owner'::text, o.user_id, coalesce(nullif(o.email, ''), u.email), o.legal_name, null::uuid, o.id, true
                   from owners o left join users u on u.id = o.user_id where o.id = v_owner;
    return;
  elsif p_c.audience = 'investor' then
    return query select 'investor'::text, i.user_id, coalesce(nullif(i.email, ''), u.email), i.legal_name, null::uuid, null::uuid, true
                   from investors i left join users u on u.id = i.user_id where i.id = (p ->> 'investor_id')::uuid;
    return;
  end if;

  -- staff
  if p ? 'recipient_user_id' then
    return query select coalesce(p_c.audience, 'staff'), u.id, u.email, u.full_name, null::uuid, null::uuid, true
                   from users u where u.id = (p ->> 'recipient_user_id')::uuid and u.status = 'active';
    return;
  end if;
  if jsonb_typeof(p -> '_roles') = 'array' then
    select array_agg(x) into v_roles from jsonb_array_elements_text(p -> '_roles') x;
  else
    v_roles := array[p_c.audience] || coalesce(p_c.also_sent_to, '{}');
  end if;
  foreach v_role in array v_roles loop
    if v_role not like 'staff_%' then continue; end if;
    return query
      select v_role, u.id, u.email, u.full_name, null::uuid, null::uuid,
             (not p_c.is_digest) or coalesce((p ->> '_immediate')::boolean, false)
             or coalesce(p -> '_immediate_roles' ? v_role, false)
        from users u
       where u.status = 'active'
         and case v_role
               when 'staff_admin' then exists (select 1 from user_roles r where r.user_id = u.id and r.role = 'admin')
               when 'staff_field' then exists (select 1 from user_roles r join staff_profiles sp on sp.user_id = r.user_id
                                                where r.user_id = u.id and r.role = 'field' and sp.staff_type = 'field' and sp.is_active)
               else exists (select 1 from user_roles r join staff_profiles sp on sp.user_id = r.user_id
                             where r.user_id = u.id and r.role = 'va' and sp.staff_type = 'va' and sp.is_active
                               and 'staff_va_' || sp.va_function::text = v_role)
             end;
  end loop;
end $$;

-- The insurer email's values (the rest of the payload builder is 0023 and 0024's).
alter function app.notification_payload(text, app_events, jsonb) rename to ntf_payload_0024;
create or replace function app.notification_payload(p_code text, p_event app_events, p_to jsonb) returns jsonb
language plpgsql stable security definer set search_path = public, app as $$
declare
  x jsonb;
  ii insurer_invoices;
  b bookings;
begin
  if p_code <> 'insurer_invoice' then
    return app.ntf_payload_0024(p_code, p_event, p_to);
  end if;
  select * into ii from insurer_invoices where id = p_event.entity_id;
  select * into b from bookings where id = ii.booking_id;
  x := app.ntf_contact() || jsonb_build_object(
    'first_name', coalesce(nullif(split_part(btrim(coalesce(p_to ->> 'name', '')), ' ', 1), ''), 'there'),
    'insurer_name', (select x2.name from insurers x2 where x2.id = ii.insurer_id),
    'invoice_number', ii.invoice_number, 'claim_number', coalesce(nullif(ii.claim_number, ''), 'not given'),
    'renter_name', coalesce((select r.legal_name from renters r where r.id = b.renter_id), 'the renter'),
    'vehicle_name', app.vehicle_name(b.vehicle_id),
    'period', app.fmt_day(ii.period_start) || ' to ' || app.fmt_day(ii.period_end),
    'invoice_amount', app.fmt_money(ii.amount_cents), 'invoice_hst', app.fmt_money(ii.hst_cents), 'invoice_total', app.fmt_money(ii.total_cents),
    'invoice_lines', coalesce((select jsonb_agg(jsonb_build_object('label', coalesce(e ->> 'label', e ->> 'description', 'Rental'),
                                  'amount', app.fmt_money(coalesce((e ->> 'amount_cents')::bigint, 0))))
                                 from jsonb_array_elements(case when jsonb_typeof(ii.lines) = 'array' then ii.lines else '[]'::jsonb end) e), '[]'::jsonb),
    'booking_id', b.id);
  return x;
end $$;

-- =====================================================================================
-- E. The door: two more calls (ops_read, ops_do) for the screens of this migration
-- =====================================================================================
create or replace function app.ops_read(p_user uuid, p_what text, p jsonb default '{}'::jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  p_ jsonb := coalesce(p, '{}'::jsonb);
  i listing_intakes;
  v_out jsonb;
  v_id uuid;
begin
  case p_what
  when 'listing_progress' then
    -- one intake ({intake}) or several ({intakes: [...]}); each one only if the user may see it
    v_out := '{}'::jsonb;
    for i in select * from listing_intakes x
              where x.id = any (coalesce(array(select jsonb_array_elements_text(p_ -> 'intakes'))::uuid[], '{}') || nullif(p_ ->> 'intake', '')::uuid) loop
      if app.user_may_list(p_user, i.vehicle_id, 'review') or app.user_may_list(p_user, i.vehicle_id, 'start') or i.started_by = p_user then
        v_out := v_out || jsonb_build_object(i.id::text, app.listing_progress(i.id));
      end if;
    end loop;
    return v_out;
  when 'listing_capture' then
    return app.listing_capture(p_user, (p_ ->> 'intake')::uuid);
  when 'listing_current' then
    -- the open listing of a vehicle (or the last one), for the owner's vehicle page and the field job
    v_id := (p_ ->> 'vehicle')::uuid;
    if not (app.user_may_list(p_user, v_id, 'start') or app.user_may_list(p_user, v_id, 'review')) then
      raise exception 'Not permitted' using errcode = '42501';
    end if;
    return (select jsonb_build_object('intake_id', x.id, 'state', x.state, 'open', x.state not in ('published', 'cancelled'))
              from listing_intakes x where x.vehicle_id = v_id order by (x.state not in ('published', 'cancelled')) desc, x.created_at desc limit 1);
  when 'listing_budget' then
    if not (app.user_is_admin(p_user) or app.user_va_has(p_user, 'fleet', 'cs')) then raise exception 'Not permitted' using errcode = '42501'; end if;
    return app.listing_budget(now());
  when 'deposit_preview' then
    return app.deposit_preview(p_user, (p_ ->> 'booking')::uuid);
  when 'files' then
    v_id := (p_ ->> 'id')::uuid;
    return app.files_for(p_user, p_ ->> 'for', v_id);
  else
    raise exception 'Unknown screen %', p_what using errcode = '22023';
  end case;
end $$;

create or replace function app.ops_do(p_user uuid, p_action text, p jsonb default '{}'::jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  p_ jsonb := coalesce(p, '{}'::jsonb);
begin
  case p_action
  when 'listing_start' then
    return app.start_listing_intake(p_user, p_);
  when 'listing_upload' then
    return app.record_listing_upload(p_user, (p_ ->> 'intake')::uuid, p_ - 'intake');
  when 'listing_submit' then
    return app.submit_listing_intake(p_user, (p_ ->> 'intake')::uuid);
  when 'listing_job_retry' then
    return app.retry_listing_job(p_user, (p_ ->> 'job')::uuid);
  when 'refund_issue_begin' then
    return app.refund_issue_begin(p_user, (p_ ->> 'id')::uuid);
  when 'refund_issue_finish' then
    return app.refund_issue_finish(p_user, (p_ ->> 'id')::uuid, p_ - 'id');
  when 'deposit_settle' then
    return app.settle_deposit((p_ ->> 'booking')::uuid, p_user,
      jsonb_strip_nulls(jsonb_build_object('hold_back_cents', coalesce((p_ ->> 'hold_back_cents')::bigint, 0),
                                           'hold_back_reason', nullif(btrim(p_ ->> 'hold_back_reason'), ''),
                                           'hold_back_until', nullif(p_ ->> 'hold_back_until', ''))), now());
  when 'toll_document' then
    if not app.user_runs_finance(p_user) then raise exception 'Finance or an Admin files a notice' using errcode = '42501'; end if;
    if not exists (select 1 from documents d where d.id = (p_ ->> 'document')::uuid and d.kind = 'toll_ticket_notice') then
      raise exception 'Upload the notice first' using errcode = '22023';
    end if;
    update toll_tickets set document_id = (p_ ->> 'document')::uuid where id = (p_ ->> 'toll')::uuid;
    if not found then raise exception 'Toll or ticket not found' using errcode = 'P0002'; end if;
    return jsonb_build_object('toll', p_ ->> 'toll', 'document', p_ ->> 'document');
  when 'insurer_invoice_email' then
    return app.send_insurer_invoice_email(p_user, (p_ ->> 'id')::uuid);
  else
    raise exception 'Unknown action %', p_action using errcode = '22023';
  end case;
end $$;

create or replace function app.door(p_user uuid, p_aal text, p_call text, p_name text, p jsonb default '{}'::jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
begin
  perform app.door_begin(p_user, p_aal);
  case p_call
  when 'roles' then return app.my_roles(p_user);
  when 'admin_list' then return app.admin_list(p_user, p_name, p);
  when 'admin_read' then return app.admin_read(p_user, p_name, p);
  when 'admin_save' then return app.admin_save(p_user, p_name, p);
  when 'admin_do' then return app.admin_do(p_user, p_name, p);
  when 'va_list' then return app.va_list(p_user, p_name, p);
  when 'va_read' then return app.va_read(p_user, p_name, p);
  when 'va_do' then return app.va_do(p_user, p_name, p);
  when 'field_read' then return app.field_read(p_user, p_name, p);
  when 'field_do' then return app.field_do(p_user, p_name, p);
  when 'investor_read' then return app.investor_read(p_user, p_name, p);
  when 'investor_do' then return app.investor_do(p_user, p_name, p);
  when 'ops_read' then return app.ops_read(p_user, p_name, p);
  when 'ops_do' then return app.ops_do(p_user, p_name, p);
  else raise exception 'Unknown call %', p_call using errcode = '22023';
  end case;
end $$;

-- =====================================================================================
-- F. Service-role wrappers and privileges
-- =====================================================================================
create or replace function public.server_listing_claim(p_worker text, p_limit integer default 4) returns jsonb
language sql volatile security invoker set search_path = public, app as $$ select app.worker_claim_listing_jobs(p_worker, p_limit, now()) $$;
create or replace function public.server_listing_result(p_job uuid, p jsonb) returns jsonb
language sql volatile security invoker set search_path = public, app as $$ select app.worker_listing_result(p_job, p) $$;
create or replace function public.server_listing_budget() returns jsonb
language sql stable security invoker set search_path = public, app as $$ select app.listing_budget(now()) $$;
create or replace function public.server_file_access(p_user uuid, p_kind text, p_key text) returns boolean
language sql stable security invoker set search_path = public, app as $$ select app.file_access(p_user, p_kind, p_key) $$;
create or replace function public.server_pdf_facts(p_kind text, p_key text, p_user uuid default null) returns jsonb
language sql stable security invoker set search_path = public, app as $$ select app.pdf_facts(p_kind, p_key, p_user) $$;
create or replace function public.server_file_stored(p_kind text, p_key text) returns jsonb
language sql stable security invoker set search_path = public, app as $$ select app.file_stored(p_kind, p_key) $$;
create or replace function public.server_file_record(p_kind text, p_key text, p_bucket text, p_path text, p_sha256 text, p_title text) returns uuid
language sql volatile security invoker set search_path = public, app as $$ select app.file_record(p_kind, p_key, p_bucket, p_path, p_sha256, p_title) $$;
create or replace function public.server_document_file(p_document uuid) returns jsonb
language sql stable security invoker set search_path = public, app as $$ select app.document_file(p_document) $$;

do $$
declare
  f record;
begin
  for f in
    select p.oid::regprocedure as sig from pg_proc p join pg_namespace n on n.oid = p.pronamespace
     where (n.nspname = 'app' and p.proname = any (array['listing_budget', 'listing_job_context', 'worker_claim_listing_jobs', 'worker_listing_result',
              'retry_listing_job', 'listing_progress', 'listing_capture', 'file_access', 'doc_company', 'pdf_facts', 'file_stored', 'file_record',
              'files_for', 'outbox_file_refs', 'document_file', 'refund_issue_begin', 'refund_issue_finish', 'deposit_preview',
              'send_insurer_invoice_email', 'notification_recipients', 'notification_payload', 'ntf_payload_0024', 'notification_catalogue_refresh',
              'ops_read', 'ops_do', 'door']))
        or (n.nspname = 'public' and p.proname = any (array['server_listing_claim', 'server_listing_result', 'server_listing_budget',
              'server_file_access', 'server_pdf_facts', 'server_file_stored', 'server_file_record', 'server_document_file']))
  loop
    execute format('revoke all on function %s from public, anon, authenticated', f.sig);
    execute format('grant execute on function %s to service_role', f.sig);
  end loop;
end $$;
-- pure helpers used inside checks
grant execute on function app.file_key_id(text), app.file_key_year(text) to service_role;
