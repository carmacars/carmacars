-- 19: the listing pipeline's worker, generated documents and signed file links, refunds through the
-- payments module, the guided Deposit settlement, a document on a toll, the insurer invoice email
-- (migration 0032). Every fixture label starts with "pd".
select test.suite('19 pipeline documents');

select test.mk_user('pd_admin', 'admin');
select test.mk_user('pd_cs', 'va', 'cs');
select test.mk_user('pd_fin', 'va', 'finance');
select test.mk_user('pd_fleet', 'va', 'fleet');
select test.mk_user('pd_sales', 'va', 'sales');
select test.mk_owner('pd_o');
select test.mk_owner('pd_o2');
select test.mk_vehicle('pdV', 'pd_o');
select test.mk_vehicle('pdW', 'pd_o');
select test.mk_vehicle('pdX', 'pd_o2');
select test.mk_renter('pd_r');
select test.mk_renter('pd_r2');
select test.mk_booking('PD1', 'pdV', 'pd_r', '2026-09-01 10:00', '2026-09-04 10:00');
select test.mk_booking('PD2', 'pdX', 'pd_r2', '2026-09-05 10:00', '2026-09-07 10:00');

-- the fake worker: claims through the worker's function and answers each kind as the adapters would
create function test.pd_answer(j jsonb) returns jsonb language sql as $$
  select case j ->> 'kind'
    when 'decode_vin' then jsonb_build_object('ok', true, 'provider', 'fake', 'units', 1, 'unit', 'requests', 'output',
      '{"ok": true, "year": 2023, "make": "Mercedes-Benz", "model": "C 300", "trim": "4MATIC", "body_class": "Sedan", "fuel": "gasoline",
        "seats": 5, "transmission": "automatic", "doors": 4, "drivetrain": "AWD", "engine": "2.0 L, 4 cylinders"}'::jsonb)
    when 'draft_copy' then jsonb_build_object('ok', true, 'provider', 'workers-ai', 'units', 250, 'unit', 'neurons', 'cost_microusd', 0,
      'output', jsonb_build_object(
        'headline', 'A 2023 Mercedes-Benz C 300 4MATIC sedan with all-wheel drive',
        'description', (select string_agg('word' || g, ' ') from generate_series(1, 140) g),
        'features', jsonb_build_array('All-wheel drive', 'Automatic transmission', 'Five seats', 'Four doors', 'Gasoline engine', 'Sedan body', 'Two-litre engine', 'Rear seats'),
        'faq', jsonb_build_array(jsonb_build_object('question', 'How many seats?', 'answer', 'Five.'), jsonb_build_object('question', 'Which fuel?', 'answer', 'Gasoline.'),
                                 jsonb_build_object('question', 'Is it all-wheel drive?', 'answer', 'Yes.'), jsonb_build_object('question', 'Automatic?', 'answer', 'Yes.')),
        'seo_title', '2023 Mercedes-Benz C 300 rental in Toronto', 'seo_description', 'Rent a 2023 Mercedes-Benz C 300 sedan in Toronto.',
        'classes', jsonb_build_array('premium', 'sedan', 'not_a_class'), 'model', '@cf/meta/llama-3.3-70b-instruct-fp8-fast', 'prompt_version', 'listing-draft-v1'))
    when 'process_photo' then jsonb_build_object('ok', true, 'provider', 'cloudflare-images', 'units', 2, 'unit', 'transformations',
      'output', jsonb_build_object('processed_path', 'vehicles/' || (j ->> 'vehicle_id') || '/' || (j -> 'photo' ->> 'file_base') || '.jpg',
                                   'width', 1800, 'height', 1200, 'preset_version', 'brand_background_v1', 'flags', '[]'::jsonb))
    when 'resize' then jsonb_build_object('ok', true, 'provider', 'cloudflare-images', 'units', 3, 'unit', 'transformations',
      'output', jsonb_build_object('variants', jsonb_build_array(jsonb_build_object('width', 480, 'format', 'webp', 'path', 'v/480.webp'))))
    else jsonb_build_object('ok', true, 'output', '{}'::jsonb) end
$$;
create function test.pd_work(p_limit integer default 100) returns integer language plpgsql as $$
declare
  c jsonb;
  j jsonb;
  n integer := 0;
begin
  for k in 1..20 loop
    c := public.server_listing_claim('pd-worker', p_limit);
    exit when jsonb_array_length(c -> 'jobs') = 0;
    for j in select value from jsonb_array_elements(c -> 'jobs') loop
      perform public.server_listing_result((j ->> 'id')::uuid, test.pd_answer(j));
      n := n + 1;
    end loop;
  end loop;
  return n;
end $$;

-- ---------------------------------------------------------------- 1. capture through the door
create temp table pd_start as select public.door(test.id('pd_fleet'), null, 'ops_do', 'listing_start', jsonb_build_object('vehicle_id', test.id('vehicle:pdV'), 'colour', 'Grey', 'notes', 'Panoramic roof')) r;
create function test.pd_i() returns uuid language sql as $$ select ((select r from pd_start) ->> 'intake_id')::uuid $$;
select test.eq('capture: Fleet starts a listing through the door, and the VIN decode is queued',
  (select state from listing_intakes where id = test.pd_i()) || '/' || (select string_agg(kind, ',') from listing_jobs where intake_id = test.pd_i()), 'decoding/decode_vin');
select test.throws('capture: an owner of another car cannot see the capture screen',
  format($$select public.door(%L, null, 'ops_read', 'listing_capture', jsonb_build_object('intake', %L))$$, test.id('pd_o2'), test.pd_i()), 'Not permitted');
select test.eq('capture: the owner of the car sees the shot list and what is missing',
  (select jsonb_array_length(c -> 'shots') > 10 and jsonb_array_length(c -> 'missing') > 10
     from public.door(test.id('pd_o'), null, 'ops_read', 'listing_capture', jsonb_build_object('intake', test.pd_i())) c), true);
select test.eq('capture: the owner finds the open listing of the car',
  (public.door(test.id('pd_o'), null, 'ops_read', 'listing_current', jsonb_build_object('vehicle', test.id('vehicle:pdV'))) ->> 'intake_id'), test.pd_i()::text);
select test.throws('capture: another owner does not', format($$select public.door(%L, null, 'ops_read', 'listing_current', jsonb_build_object('vehicle', %L))$$, test.id('pd_o2'), test.id('vehicle:pdV')), 'Not permitted');
select public.door(test.id('pd_fleet'), null, 'ops_do', 'listing_upload',
         jsonb_build_object('intake', test.pd_i(), 'shot_type', s.code, 'original_path', 'vehicles/' || test.id('vehicle:pdV') || '/original/' || s.code || '.jpg',
                            'width', 3000, 'height', 2000, 'byte_size', 800000, 'mime_type', 'image/jpeg'))
  from listing_shot_types s where s.required and s.is_active order by s.seq;
select test.eq('capture: every required photo uploaded through the door',
  jsonb_array_length(public.door(test.id('pd_fleet'), null, 'ops_read', 'listing_capture', jsonb_build_object('intake', test.pd_i())) -> 'missing'), 0);
create temp table pd_sub as select public.door(test.id('pd_fleet'), null, 'ops_do', 'listing_submit', jsonb_build_object('intake', test.pd_i())) r;
select test.eq('capture: submitting queues the copy draft and one job per photo',
  (select r ->> 'state' from pd_sub)
  || '/' || (select count(*) from listing_jobs where intake_id = test.pd_i() and kind = 'process_photo')
  || '/' || (select count(*) from listing_jobs where intake_id = test.pd_i() and kind = 'draft_copy'),
  'drafting/' || (select count(*) from listing_shot_types where required and is_active) || '/1');

-- ---------------------------------------------------------------- 2. the worker's claim
create temp table pd_c1 as select public.server_listing_claim('pd-worker', 100) c;
select test.eq('worker: the decode comes first and the copy draft waits for it',
  (select (c -> 'jobs' -> 0 ->> 'kind') || '/' || (select count(*) from jsonb_array_elements(c -> 'jobs') x where x ->> 'kind' = 'draft_copy') from pd_c1), 'decode_vin/0');
select test.eq('worker: a decode job carries the VIN; a photo job carries the original, the backdrop rule and a file name',
  (select (x ->> 'vin') is not null from pd_c1, jsonb_array_elements(c -> 'jobs') x where x ->> 'kind' = 'decode_vin')
  || '/' || (select count(*) from pd_c1, jsonb_array_elements(c -> 'jobs') x where x ->> 'kind' = 'process_photo' and (x -> 'photo' ->> 'rebackground')::boolean
              and x -> 'photo' ->> 'original_path' like 'vehicles/%' and x -> 'photo' ->> 'file_base' like '2023-mercedes-benz-c-300-pdv-%'),
  'true/8');
select public.server_listing_result((x ->> 'id')::uuid, test.pd_answer(x)) from pd_c1, jsonb_array_elements(c -> 'jobs') x;
create temp table pd_c2 as select public.server_listing_claim('pd-worker', 100) c;
select test.eq('worker: after the decode the draft is claimed with the decoded facts, the staff notes and the copy rules',
  (select (x -> 'facts' ->> 'trim') || '/' || (x ->> 'staff_notes') || '/' || (x -> 'copy_rules' -> 'headline_chars' ->> 0) || '/' || (x -> 'classes' ? 'premium')
     from pd_c2, jsonb_array_elements(c -> 'jobs') x where x ->> 'kind' = 'draft_copy'), '4MATIC/Panoramic roof/20/true');  -- 0061: headings from 20 characters
select test.eq('worker: the draft job never carries the VIN, plate or owner',
  (select (x ? 'vin' and x ->> 'vin' is not null)::text || '/' || (x::text like '%' || (select plate from vehicles where id = test.id('vehicle:pdV')) || '%')::text
     from pd_c2, jsonb_array_elements(c -> 'jobs') x where x ->> 'kind' = 'draft_copy'), 'false/false');
select public.server_listing_result((x ->> 'id')::uuid, test.pd_answer(x)) from pd_c2, jsonb_array_elements(c -> 'jobs') x;
select test.eq('worker: the draft is stored with its model and prompt version, and only listed classes are proposed',
  (select model || '/' || prompt_version || '/' || array_to_string(proposed_classes, ',') || '/' || needs_rewrite from listing_drafts where intake_id = test.pd_i()),
  '@cf/meta/llama-3.3-70b-instruct-fp8-fast/listing-draft-v1/premium,sedan/false');
select test.eq('worker: the neurons and transformations used are kept with each provider call',
  (select sum(units) filter (where unit = 'neurons') || '/' || (sum(units) filter (where unit = 'transformations') > 0)::text
     from provider_calls where intake_id = test.pd_i()), '250/true');
select test.pd_work();
select test.eq('worker: every step done, a listing Fleet started needs no review: it is approved or already live',
  (select state in ('approved', 'published') from listing_intakes where id = test.pd_i()), true);
select test.eq('worker: progress counts every step as done',
  (select (p ->> 'done') = (p ->> 'total') and (p ->> 'failed')::int = 0 from app.listing_progress(test.pd_i()) p), true);
select test.eq('worker: processed photos carry the size variants for the site',
  (select count(*) from vehicle_photos where intake_id = test.pd_i() and replaced_at is null and jsonb_array_length(variants) = 1),
  (select count(*) from listing_shot_types where required and is_active));

-- ---------------------------------------------------------------- 3. budgets
select test.mk_vehicle('pdY', 'pd_o');
insert into vin_decodes (vin, provider, ok, raw, year, make, model) select upper(vin), 'fake', true, '{}', 2023, 'Mercedes-Benz', 'C 300' from vehicles where id = test.id('vehicle:pdY');
create temp table pd_s2 as select app.start_listing_intake(test.id('pd_admin'), jsonb_build_object('vehicle_id', test.id('vehicle:pdY'), 'colour', 'Black')) r;
create function test.pd_i2() returns uuid language sql as $$ select ((select r from pd_s2) ->> 'intake_id')::uuid $$;
select app.record_listing_upload(test.id('pd_admin'), test.pd_i2(), jsonb_build_object('shot_type', s.code, 'original_path', 'o/' || s.code || '.jpg'))
  from listing_shot_types s where s.required and s.is_active order by s.seq;
select app.submit_listing_intake(test.id('pd_admin'), test.pd_i2());
update program_settings set listing_ai_daily_neurons = 100;
create temp table pd_c3 as select public.server_listing_claim('pd-worker', 100) c;
select test.eq('budget: past the day''s neurons the copy draft is held and the photos go on',
  (select (c -> 'held' ->> 'copy') || '/' || (select count(*) from jsonb_array_elements(c -> 'jobs') x where x ->> 'kind' = 'draft_copy')
          || '/' || ((select count(*) from jsonb_array_elements(c -> 'jobs') x where x ->> 'kind' = 'process_photo') > 0) from pd_c3), 'true/0/true');
update program_settings set listing_ai_daily_neurons = 9000;

-- ---------------------------------------------------------------- 4. failures and retry
select public.server_listing_result((x ->> 'id')::uuid,
         case when x -> 'photo' ->> 'shot_type' = 'front' then '{"ok": false, "provider": "cloudflare-images", "error": "Image transformations are not enabled on the zone", "retryable": true}'::jsonb
              else test.pd_answer(x) end)
  from pd_c3, jsonb_array_elements(c -> 'jobs') x;
create function test.pd_front() returns uuid language sql as $$
  select j.id from listing_jobs j join vehicle_photos ph on ph.id = j.vehicle_photo_id where j.intake_id = test.pd_i2() and j.kind = 'process_photo' and ph.shot_type = 'front' $$;
select test.eq('retry: a provider failure is queued again with its error, and progress shows it',
  (select status || '/' || attempts || '/' || (next_attempt_at > now()) from listing_jobs where id = test.pd_front())
  || '/' || (select count(*) from jsonb_array_elements(app.listing_progress(test.pd_i2()) -> 'problems') x where x ->> 'error' like '%not enabled%'),
  'queued/1/true/1');
select test.throws('retry: a renter cannot retry a step', format($$select public.door(%L, null, 'ops_do', 'listing_job_retry', jsonb_build_object('job', %L))$$, test.id('pd_r'), test.pd_front()), 'Not permitted');
create temp table pd_rt as select public.door(test.id('pd_cs'), null, 'ops_do', 'listing_job_retry', jsonb_build_object('job', test.pd_front())) r;
select test.eq('retry: customer service makes the step due now',
  (select r ->> 'status' from pd_rt) || '/' || (select (next_attempt_at <= now())::text from listing_jobs where id = test.pd_front()), 'queued/true');
-- the draft fails for good: the listing goes on, and the draft can be retried
create temp table pd_c4 as select public.server_listing_claim('pd-worker', 100) c;
select public.server_listing_result((x ->> 'id')::uuid,
         case when x ->> 'kind' = 'draft_copy' then '{"ok": false, "provider": "workers-ai", "error": "invalid_output", "retryable": false}'::jsonb else test.pd_answer(x) end)
  from pd_c4, jsonb_array_elements(c -> 'jobs') x;
select test.pd_work();
create function test.pd_draft2() returns uuid language sql as $$ select id from listing_jobs where intake_id = test.pd_i2() and kind = 'draft_copy' $$;
select test.eq('retry: a failed draft does not stop the listing',
  (select status from listing_jobs where id = test.pd_draft2()) || '/' || (select draft_failed from listing_intakes where id = test.pd_i2()), 'failed/true');
create temp table pd_rt2 as select public.door(test.id('pd_admin'), null, 'ops_do', 'listing_job_retry', jsonb_build_object('job', test.pd_draft2())) r;
select test.eq('retry: the failed draft is queued again with fresh attempts',
  (select r ->> 'status' from pd_rt2)
  || '/' || (select attempts || '/' || (select draft_failed from listing_intakes where id = test.pd_i2()) from listing_jobs where id = test.pd_draft2()), 'queued/0/false');
select test.pd_work();
select test.eq('retry: the second draft is stored', (select count(*) from listing_drafts where intake_id = test.pd_i2()), 1::bigint);
select test.throws('retry: a step that is done is not retried',
  format($$select public.door(%L, null, 'ops_do', 'listing_job_retry', jsonb_build_object('job', %L))$$, test.id('pd_admin'), test.pd_draft2()), 'This step is done');

-- ---------------------------------------------------------------- 5. intake to published
create temp table pd_k as select app.start_listing_intake(test.id('pd_o'), jsonb_build_object('vehicle_id', test.id('vehicle:pdW'), 'colour', 'White')) r;
create function test.pd_k() returns uuid language sql as $$ select ((select r from pd_k) ->> 'intake_id')::uuid $$;
select public.door(test.id('pd_o'), null, 'ops_do', 'listing_upload',
         jsonb_build_object('intake', test.pd_k(), 'shot_type', s.code, 'original_path', 'vehicles/' || test.id('vehicle:pdW') || '/original/' || s.code || '.jpg'))
  from listing_shot_types s where s.required and s.is_active order by s.seq;
select public.door(test.id('pd_o'), null, 'ops_do', 'listing_submit', jsonb_build_object('intake', test.pd_k()));
select test.pd_work();
select test.eq('end to end: an owner''s listing waits for staff review with its draft', (select state from listing_intakes where id = test.pd_k()), 'needs_review');
select test.eq('end to end: the car is not on the website before the review', (public.car_page((select coalesce(slug, 'none') from vehicle_listings where vehicle_id = test.id('vehicle:pdW'))) is null), true);
create temp table pd_rv as select app.review_listing(test.id('pd_cs'), test.pd_k(), true) r;
select test.eq('end to end: customer service approves; the car is published through app.publish_listing',
  (select r ->> 'status' from pd_rv) || '/' || (select status from vehicle_listings where vehicle_id = test.id('vehicle:pdW'))
  || '/' || (select state from listing_intakes where id = test.pd_k()), 'published/published/published');
select test.eq('end to end: the public car page shows the drafted headline and the processed photos',
  (select (c ->> 'headline') || '/' || (jsonb_array_length(c -> 'photos') >= 10)::text
     from public.car_page((select slug from vehicle_listings where vehicle_id = test.id('vehicle:pdW'))) c),
  'A 2023 Mercedes-Benz C 300 4MATIC sedan with all-wheel drive/true');
select test.eq('end to end: the public page carries no plate, VIN or original path',
  (select c::text not like '%' || v.plate || '%' and c::text not like '%' || v.vin || '%' and c::text not like '%/original/%'
     from public.car_page((select slug from vehicle_listings where vehicle_id = test.id('vehicle:pdW'))) c, vehicles v where v.id = test.id('vehicle:pdW')), true);

-- ---------------------------------------------------------------- 6. who may download what
insert into owner_statements (id, owner_id, statement_month, payout_date, status, approved_by, approved_at, payout_cents, owner_revenue_cents)
values (test.id('st:pd1'), test.id('owner:pd_o'), date '2026-09-01', date '2026-10-10', 'approved', test.id('pd_admin'), now(), 50000, 60000),
       (test.id('st:pd2'), test.id('owner:pd_o'), date '2026-08-01', date '2026-09-10', 'draft', null, null, 0, 0);
insert into investors (id, user_id, legal_name, investor_type, status, email) values
  (test.id('inv:pd1'), test.id('pd_r'), 'Petra Investor', 'individual', 'active', 'pd_r@example.test');
insert into documents (id, kind, storage_bucket, storage_path) values (test.id('doc:pdc'), 'other', 'documents', 'x/pdc.pdf');
insert into investment_agreements (id, investor_id, agreement_number, status, schedule_c_document_id, schedule_d_document_id, exemption_category, legal_advice_choice)
values (test.id('agr:pd1'), test.id('inv:pd1'), 'IA-PD-1', 'signed', test.id('doc:pdc'), test.id('doc:pdc'), 'accredited_investor', 'declined');
insert into investments (id, investor_id, agreement_id, is_initial, principal_cents, yearly_bps, investment_date, lockup_end_date)
values (test.id('ivt:pd1'), test.id('inv:pd1'), test.id('agr:pd1'), true, 1000000, 1200, date '2025-01-05', date '2025-07-05');
insert into investment_returns (id, investment_id, return_month, opening_invested_cents, yearly_bps, days_earning, days_in_month, return_cents, disposition, payment_date, closing_invested_cents)
values (test.id('ir:pd1'), test.id('ivt:pd1'), date '2025-11-01', 1000000, 1200, 30, 30, 9863, 'pay', date '2025-12-15', 1000000),
       (test.id('ir:pd2'), test.id('ivt:pd1'), date '2025-12-01', 1000000, 1200, 31, 31, 10192, 'reinvest', date '2026-01-15', 1010192);
insert into insurers (id, name, billing_contact_name, billing_email) values (test.id('ins:pd'), 'Pd Mutual', 'Clara Claims', 'claims@pdmutual.test');
insert into insurer_invoices (id, booking_id, insurer_id, claim_number, period_start, period_end, amount_cents, hst_cents, lines)
values (test.id('ii:pd'), test.id('booking:PD1'), test.id('ins:pd'), 'CL-77', date '2026-09-01', date '2026-09-04', 30000, 3900,
        '[{"label": "Rental, 3 days at $100.00", "amount_cents": 30000}]');

select test.eq('files: an owner downloads their approved statement, not a draft, not another owner''s',
  app.file_access(test.id('pd_o'), 'owner_statement', test.id('st:pd1')::text)::text || '/' || app.file_access(test.id('pd_o'), 'owner_statement', test.id('st:pd2')::text)
  || '/' || app.file_access(test.id('pd_o2'), 'owner_statement', test.id('st:pd1')::text), 'true/false/false');
select test.eq('files: a renter downloads the receipt of their own payment only',
  app.file_access(test.id('pd_r'), 'receipt', test.id('payment:PD1')::text)::text || '/' || app.file_access(test.id('pd_r2'), 'receipt', test.id('payment:PD1')::text), 'true/false');
select test.eq('files: an insurer invoice is for Finance and Admins only',
  app.file_access(test.id('pd_fin'), 'insurer_invoice', test.id('ii:pd')::text)::text || '/' || app.file_access(test.id('pd_admin'), 'insurer_invoice', test.id('ii:pd')::text)
  || '/' || app.file_access(test.id('pd_cs'), 'insurer_invoice', test.id('ii:pd')::text) || '/' || app.file_access(test.id('pd_r'), 'insurer_invoice', test.id('ii:pd')::text),
  'true/true/false/false');
select test.eq('files: an investor reads their own statements and yearly summary; Finance does not',
  app.file_access(test.id('pd_r'), 'investor_statement', test.id('ir:pd1')::text)::text || '/' || app.file_access(test.id('pd_r'), 'investor_year', test.id('inv:pd1') || ':2025')
  || '/' || app.file_access(test.id('pd_r2'), 'investor_year', test.id('inv:pd1') || ':2025') || '/' || app.file_access(test.id('pd_fin'), 'investor_statement', test.id('ir:pd1')::text),
  'true/true/false/false');
select test.eq('files: nobody without a session', app.file_access(null, 'receipt', test.id('payment:PD1')::text), false);

select test.eq('pdf: an approved owner statement is final and prints the legal name',
  (select (f ->> 'final') || '/' || (f -> 'company' ->> 'legal_name') || '/' || (f -> 'totals' ->> 'payout_cents') from app.pdf_facts('owner_statement', test.id('st:pd1')::text) f),
  'true/18122211 Canada Inc./50000');
select test.eq('pdf: a draft insurer invoice is not final; its lines and total print',
  (select (f ->> 'final') || '/' || (f ->> 'total_cents') || '/' || (f -> 'lines' -> 0 ->> 'label') || '/' || (f -> 'insurer' ->> 'name') from app.pdf_facts('insurer_invoice', test.id('ii:pd')::text) f),
  'false/33900/Rental, 3 days at $100.00/Pd Mutual');
select test.eq('pdf: the yearly summary adds up the months; a past year is final',
  (select (f ->> 'final') || '/' || jsonb_array_length(f -> 'months') || '/' || (f -> 'totals' ->> 'return_cents') || '/' || (f -> 'totals' ->> 'reinvested_cents')
     from app.pdf_facts('investor_year', test.id('inv:pd1') || ':2025') f), 'true/2/20055/10192');
select test.eq('pdf: a receipt lists the lines it paid', (select jsonb_array_length(f -> 'lines') >= 1 from app.pdf_facts('receipt', test.id('payment:PD1')::text) f), true);
select test.throws('pdf: an unknown kind is refused', $$select app.pdf_facts('payslip', 'x')$$, 'Unknown document');

create temp table pd_doc as select public.server_file_record('owner_statement', test.id('st:pd1')::text, 'documents', 'owners/x/statements/2026-09.pdf', 'abc123', 'Owner statement') d;
select test.eq('pdf: a stored statement is a document of the owner, linked to the statement',
  (select kind || '/' || (owner_id = test.id('owner:pd_o'))::text from documents where id = (select d from pd_doc))
  || '/' || (select (document_id = (select d from pd_doc))::text from owner_statements where id = test.id('st:pd1')), 'owner_statement/true/true');
select test.eq('pdf: storing it again returns the same document',
  (public.server_file_record('owner_statement', test.id('st:pd1')::text, 'documents', 'other.pdf', 'zzz', 'x') = (select d from pd_doc)), true);
select test.eq('pdf: the stored copy is found by kind and record', (public.server_file_stored('owner_statement', test.id('st:pd1')::text) ->> 'path'), 'owners/x/statements/2026-09.pdf');
select test.eq('files: the booking''s documents for its renter are the receipts and statements, not the insurer invoice',
  (select string_agg(x ->> 'kind', ',') from jsonb_array_elements(public.door(test.id('pd_r'), null, 'ops_read', 'files', jsonb_build_object('for', 'booking', 'id', test.id('booking:PD1')))) x), 'receipt');
select test.eq('files: Finance sees the insurer invoice in the same list',
  (select count(*) from jsonb_array_elements(public.door(test.id('pd_fin'), null, 'ops_read', 'files', jsonb_build_object('for', 'booking', 'id', test.id('booking:PD1')))) x where x ->> 'kind' = 'insurer_invoice'), 1::bigint);
select test.throws('files: the wrappers are for the server only', $$set local role authenticated; select public.server_pdf_facts('receipt', 'x')$$, 'permission denied');

-- ---------------------------------------------------------------- 7. refunds through the payments module
insert into payment_processor_details (payment_id, processor, processor_payment_id, processor_charge_id)
values (test.id('payment:PD1'), 'stripe', 'pi_pd1', 'ch_pd1');
create temp table pd_rf as select public.door(test.id('pd_admin'), null, 'admin_do', 'request_refund', jsonb_build_object('booking', test.id('booking:PD1'), 'amount_cents', 2500, 'reason', 'goodwill')) r;
create function test.pd_rf() returns uuid language sql as $$ select ((select r from pd_rf) ->> 'id')::uuid $$;
select test.throws('refund: a refund still waiting for approval is not issued',
  format($$select public.door(%L, null, 'ops_do', 'refund_issue_begin', jsonb_build_object('id', %L))$$, test.id('pd_admin'), test.pd_rf()), 'Only an approved refund');
select public.door(test.id('pd_admin'), null, 'admin_do', 'refund_approve', jsonb_build_object('id', test.pd_rf()));
select test.throws('refund: customer service does not issue money',
  format($$select public.door(%L, null, 'ops_do', 'refund_issue_begin', jsonb_build_object('id', %L))$$, test.id('pd_cs'), test.pd_rf()), 'Finance or an Admin');
create temp table pd_b1 as select public.door(test.id('pd_admin'), null, 'ops_do', 'refund_issue_begin', jsonb_build_object('id', test.pd_rf())) r;
select test.eq('refund: begin gives the processor ids, the amount and a key that is the same every time',
  (select (r ->> 'payment_intent') || '/' || (r ->> 'amount_cents') || '/' || (r ->> 'idempotency_key') from pd_b1)
  || '/' || (select status from refunds where id = test.pd_rf()), 'pi_pd1/2500/refund:' || test.pd_rf() || '/processing');
select test.eq('refund: begun again after a crash, the same key comes back',
  (public.door(test.id('pd_admin'), null, 'ops_do', 'refund_issue_begin', jsonb_build_object('id', test.pd_rf())) ->> 'idempotency_key'), 'refund:' || test.pd_rf());
select public.door(test.id('pd_admin'), null, 'ops_do', 'refund_issue_finish', jsonb_build_object('id', test.pd_rf(), 'ok', true, 'status', 'succeeded', 'processor_refund_id', 're_pd1'));
select test.eq('refund: finished, the refund is paid with one refund transaction pointing at the charge',
  (select status || '/' || (refund_payment_id is not null)::text from refunds where id = test.pd_rf())
  || '/' || (select kind || ':' || status || ':' || amount_cents || ':' || (parent_payment_id = test.id('payment:PD1'))::text from payments where id = (select refund_payment_id from refunds where id = test.pd_rf()))
  || '/' || (select processor_refund_id from payment_processor_details where payment_id = (select refund_payment_id from refunds where id = test.pd_rf())),
  'paid/true/refund:succeeded:2500:true/re_pd1');
select test.eq('refund: a repeated begin or finish changes nothing',
  (public.door(test.id('pd_admin'), null, 'ops_do', 'refund_issue_begin', jsonb_build_object('id', test.pd_rf())) ->> 'already')
  || '/' || (public.door(test.id('pd_admin'), null, 'ops_do', 'refund_issue_finish', jsonb_build_object('id', test.pd_rf(), 'ok', true, 'processor_refund_id', 're_pd1')) ->> 'already')
  || '/' || (select count(*) from payments where parent_payment_id = test.id('payment:PD1') and kind = 'refund'), 'true/true/1');
create temp table pd_rf2 as select public.door(test.id('pd_admin'), null, 'admin_do', 'request_refund', jsonb_build_object('booking', test.id('booking:PD1'), 'amount_cents', 10000000, 'reason', 'goodwill')) r;
select public.door(test.id('pd_admin'), null, 'admin_do', 'refund_approve', jsonb_build_object('id', (select (r ->> 'id')::uuid from pd_rf2)));
select test.throws('refund: never more than what is left of the payment',
  format($$select public.door(%L, null, 'ops_do', 'refund_issue_begin', jsonb_build_object('id', %L))$$, test.id('pd_admin'), (select (r ->> 'id')::uuid from pd_rf2)), 'more than what is left');
create temp table pd_rf3 as select public.door(test.id('pd_admin'), null, 'admin_do', 'request_refund', jsonb_build_object('booking', test.id('booking:PD1'), 'amount_cents', 100, 'reason', 'goodwill')) r;
select public.door(test.id('pd_admin'), null, 'admin_do', 'refund_approve', jsonb_build_object('id', (select (r ->> 'id')::uuid from pd_rf3)));
select public.door(test.id('pd_admin'), null, 'ops_do', 'refund_issue_begin', jsonb_build_object('id', (select (r ->> 'id')::uuid from pd_rf3)));
create temp table pd_f3 as select public.door(test.id('pd_admin'), null, 'ops_do', 'refund_issue_finish', jsonb_build_object('id', (select (r ->> 'id')::uuid from pd_rf3), 'ok', false, 'error', 'charge_disputed')) r;
select test.eq('refund: a refusal from the processor is recorded as failed with the reason',
  (select r ->> 'status' from pd_f3) || '/' || (select (note like '%charge_disputed%')::text from refunds where id = (select (r ->> 'id')::uuid from pd_rf3)), 'failed/true');
select test.eq('refund: a failed refund can be issued again with the same key',
  (public.door(test.id('pd_admin'), null, 'ops_do', 'refund_issue_begin', jsonb_build_object('id', (select (r ->> 'id')::uuid from pd_rf3))) ->> 'idempotency_key'),
  'refund:' || (select r ->> 'id' from pd_rf3));

-- ---------------------------------------------------------------- 8. Deposit preview, toll document
select test.eq('deposit: the preview says what is due and what may be held back',
  (select (p ->> 'booking_number') || '/' || (p ->> 'due_cents') || '/' || (p ->> 'holdback_days') is not null
     from public.door(test.id('pd_fin'), null, 'ops_read', 'deposit_preview', jsonb_build_object('booking', test.id('booking:PD1'))) p), true);
select test.throws('deposit: Fleet does not settle Deposits',
  format($$select public.door(%L, null, 'ops_read', 'deposit_preview', jsonb_build_object('booking', %L))$$, test.id('pd_fleet'), test.id('booking:PD1')), 'Finance or an Admin');
select test.throws('deposit: the settlement is 0020''s, with its rules (a Check-in statement first)',
  format($$select public.door(%L, null, 'ops_do', 'deposit_settle', jsonb_build_object('booking', %L, 'hold_back_cents', 0))$$, test.id('pd_fin'), test.id('booking:PD1')), 'Check-in statement');

insert into documents (id, kind, title, storage_bucket, storage_path) values (test.id('doc:pdnotice'), 'toll_ticket_notice', 'Notice', 'documents', 'admin/toll_ticket_notice/x.pdf'),
  (test.id('doc:pdother'), 'other', 'Other', 'documents', 'admin/other/x.pdf');
create temp table pd_toll as select app.log_toll_ticket(jsonb_build_object('kind', 'parking', 'authority', 'City of Toronto', 'notice_number', 'PD-1',
  'plate', (select plate from vehicles where id = test.id('vehicle:pdV')), 'occurred_at', '2026-09-02T15:00:00-04:00', 'amount_cents', 3000,
  'document_id', test.id('doc:pdnotice')), test.id('pd_fin')) t;
select test.eq('toll: single entry keeps the uploaded notice', (select document_id from toll_tickets where id = (select t from pd_toll)), test.id('doc:pdnotice'));
select test.throws('toll: only a notice document is attached',
  format($$select public.door(%L, null, 'ops_do', 'toll_document', jsonb_build_object('toll', %L, 'document', %L))$$, test.id('pd_fin'), (select t from pd_toll), test.id('doc:pdother')), 'Upload the notice first');

-- ---------------------------------------------------------------- 9. the insurer invoice email
select test.throws('insurer: customer service does not send invoices',
  format($$select public.door(%L, null, 'ops_do', 'insurer_invoice_email', jsonb_build_object('id', %L))$$, test.id('pd_cs'), test.id('ii:pd')), 'Finance or an Admin');
create temp table pd_ie as select public.door(test.id('pd_fin'), null, 'ops_do', 'insurer_invoice_email', jsonb_build_object('id', test.id('ii:pd'))) r;
select test.eq('insurer: a draft is sent and the email is queued for the insurer''s billing address',
  (select (r ->> 'status') || '/' || (r ->> 'to') from pd_ie), 'sent/claims@pdmutual.test');
select app.process_events();
create function test.pd_ob() returns notification_outbox language sql as $$ select * from notification_outbox where code = 'insurer_invoice' and entity_id = test.id('ii:pd') order by created_at limit 1 $$;
select test.eq('insurer: one email to the insurer, from billing, with every value but the signed link',
  (select o.to_address || '/' || o.audience || '/' || (o.payload ->> 'invoice_number') || '/' || (o.payload ->> 'invoice_total') || '/' || (o.payload ->> 'first_name')
          || '/' || array_to_string(o.missing_variables, ',') from test.pd_ob() o),
  'claims@pdmutual.test/insurer/' || (select invoice_number from insurer_invoices where id = test.id('ii:pd')) || '/$339.00/Clara/');
select test.eq('insurer: the sender adds a 7-day link to the invoice PDF', (app.outbox_file_refs((test.pd_ob()).id) -> 'invoice_url' ->> 'k'), 'insurer_invoice');
select test.eq('insurer: sending again is a second email', (public.door(test.id('pd_fin'), null, 'ops_do', 'insurer_invoice_email', jsonb_build_object('id', test.id('ii:pd'))) ->> 'sends'), '2');
update insurers set billing_email = null where id = test.id('ins:pd');
select test.throws('insurer: no billing email, no send', format($$select public.door(%L, null, 'ops_do', 'insurer_invoice_email', jsonb_build_object('id', %L))$$, test.id('pd_fin'), test.id('ii:pd')), 'no billing email');
select test.eq('catalogue: invoice_url is a sender value, like the other signed links',
  (select 'invoice_url' = any (sender_supplied) from notification_catalogue where code = 'insurer_invoice'), true);

-- ---------------------------------------------------------------- 10. signed links in other emails, privileges
insert into notification_outbox (id, code, category, priority, audience, to_address, entity, entity_id, dedupe_key)
values (test.id('ob:pd1'), 'renter_payment_receipt', 'transactional', 1, 'renter', 'pd_r@example.test', 'payment', test.id('payment:PD1'), 'pd:test:1'),
       (test.id('ob:pd2'), 'investor_statement_ready', 'transactional', 2, 'investor', 'pd_r@example.test', 'investment_return', test.id('ir:pd1'), 'pd:test:2');
select test.eq('links: a receipt email links to the receipt, an investor statement email to the statement',
  (app.outbox_file_refs(test.id('ob:pd1')) -> 'receipt_url' ->> 'k') || '/' || (app.outbox_file_refs(test.id('ob:pd2')) -> 'statement_url' ->> 'key'),
  'receipt/' || test.id('ir:pd1'));
select test.eq('privileges: every new function is for the server only',
  (select count(*) from pg_proc p join pg_namespace n on n.oid = p.pronamespace
    where n.nspname in ('app', 'public') and p.proname in ('worker_claim_listing_jobs', 'worker_listing_result', 'pdf_facts', 'file_record', 'ops_do', 'ops_read',
                                                         'server_listing_claim', 'server_file_record', 'refund_issue_begin')
      and (has_function_privilege('authenticated', p.oid, 'execute') or has_function_privilege('anon', p.oid, 'execute'))), 0::bigint);
select test.eq('rls: the new table has row-level security', (select relrowsecurity from pg_class where relname = 'generated_documents'), true);
