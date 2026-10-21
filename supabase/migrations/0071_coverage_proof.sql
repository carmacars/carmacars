-- 0071_coverage_proof.sql
-- Proof of coverage (the owner's request of October 20, 2026): "Renters must be able to upload their insurance policy
-- if using OPCF 27 coverage, and if using credit card rental coverage, they must be paying with a credit card that
-- actually has rental car coverage." Rental Agreement section 8.2 and 8.3; 02-booking-and-renter.md section 7.3;
-- 05-va.md section 4.2.
--
--   1. The card's funding (credit, debit, prepaid, unknown) and country, kept from Stripe on the Card on File.
--   2. Coverage option 1, OPCF 27: the renter sends the policy document or the OPCF 27 endorsement as a PDF or as
--      photos (several pages, phone camera), with the insurer, the policy number and the expiry date, which must be
--      after the return date. Each file is a page of one proof; staff approve or reject the proof as a whole.
--   3. Coverage option 2, credit card coverage: only on the card that paid for the booking, which must be a credit
--      card (funding "credit", never debit or prepaid) in the renter's name. The renter ticks that the card includes
--      rental car coverage for this class of car and this length of rental and agrees to claim on it; the card's
--      benefit document is optional (encouraged). Staff see the brand, the last four and the funding.
--   4. Changing the option before pickup (1 or 2), or asking for the Protection Plan (a task for customer service).
--   5. Staff review: the coverage proof beside the licence checks (Approve, or Reject with a reason the renter sees);
--      the Protection Plan's activation confirmed by staff. Handover stays blocked until coverage is confirmed
--      (app.booking_before_write and app.complete_handover already refuse it).
--   6. Reminders 48 and 24 hours before pickup while the proof is missing or was declined (renter_coverage_needed).
--   7. Privacy: proofs are private files (signed links of one minute), rental records kept 7 years after the return;
--      every private file whose retention has passed is listed for the Worker's purge job (licence images and
--      selfies at 90 days, as the privacy policy says), never one on legal hold or under an open claim or dispute.
--   8. The field ready check names the confirmed coverage.

-- ================================================================ 1. the card's funding
alter table payment_methods
  add column if not exists funding text check (funding in ('credit', 'debit', 'prepaid', 'unknown')),
  add column if not exists card_country text check (card_country ~ '^[A-Z]{2}$');
comment on column payment_methods.funding is 'The card''s funding as Stripe reports it (credit, debit, prepaid, unknown). Credit card rental coverage needs credit.';
comment on column payment_methods.card_country is 'The issuing country of the card, as Stripe reports it (ISO 3166 two letters).';
update payment_methods set funding = case when is_credit then 'credit' else 'unknown' end where funding is null and is_credit is not null;

alter function app.save_card_on_file(uuid, jsonb, jsonb) rename to save_card_on_file_pre0071;
create or replace function app.save_card_on_file(p_renter uuid, p_card jsonb, p_processor jsonb) returns uuid
language plpgsql security definer set search_path = public, app as $$
declare
  v_id uuid := app.save_card_on_file_pre0071(p_renter, p_card, p_processor);
  v_funding text;
begin
  if v_id is not null and p_card is not null and jsonb_typeof(p_card) = 'object' then
    v_funding := case when p_card ->> 'funding' in ('credit', 'debit', 'prepaid', 'unknown') then p_card ->> 'funding'
                      when (p_card ->> 'is_credit') = 'true' then 'credit' when (p_card ->> 'is_credit') = 'false' then 'unknown' end;
    update payment_methods
       set funding = coalesce(v_funding, funding),
           is_credit = case when v_funding is null then is_credit else v_funding = 'credit' end,
           card_country = coalesce(case when upper(coalesce(p_card ->> 'country', '')) ~ '^[A-Z]{2}$' then upper(p_card ->> 'country') end, card_country)
     where id = v_id;
  end if;
  return v_id;
end $$;

-- ================================================================ 2. the proof's new facts
alter table coverage_proofs
  add column if not exists payment_method_id   uuid references payment_methods (id),
  add column if not exists card_brand          text,
  add column if not exists card_funding        text,
  add column if not exists cardholder_name     text,
  add column if not exists name_matches        boolean,
  add column if not exists renter_confirmed_at timestamptz,
  add column if not exists renter_confirmed_by uuid references users (id),
  add column if not exists confirmation_text   text,
  add column if not exists vehicle_class_label text,
  add column if not exists rental_days         integer,
  add column if not exists submitted_by        uuid references users (id),
  add column if not exists submitted_at        timestamptz,
  add column if not exists reviewed_checks     jsonb;
comment on column coverage_proofs.renter_confirmed_at is 'Option 2: when the renter ticked that their card includes rental car coverage for this class and length and that they will claim on it.';
comment on column coverage_proofs.confirmation_text is 'Option 2: the words the renter ticked, as shown.';
comment on column coverage_proofs.reviewed_checks is 'The checks the reviewer ticked when approving.';

-- A proof of option 1 may have several pages (a PDF, or photos of each page): one current upload per kind holds for
-- the licence images and the selfie only.
drop index if exists verification_uploads_one_current;
create unique index verification_uploads_one_current on verification_uploads (booking_id, coalesce(driver_id, booking_id), kind)
  where status in ('submitted', 'approved') and kind <> 'coverage_proof';
create index if not exists verification_uploads_proof_idx on verification_uploads (coverage_proof_id) where coverage_proof_id is not null;

alter table program_settings
  add column if not exists coverage_proof_max_pages integer not null default 6 check (coverage_proof_max_pages between 1 and 20),
  add column if not exists coverage_reminder_hours integer[] not null default array[48, 24];
comment on column program_settings.coverage_proof_max_pages is 'The most files (pages) one proof of coverage may have.';
comment on column program_settings.coverage_reminder_hours is 'Hours before pickup at which renter_coverage_needed is sent while the proof is missing or was declined.';

-- ================================================================ helpers
create or replace function app.coverage_option_label(p_option integer) returns text
language sql immutable as $$
  select case p_option when 1 then 'OPCF 27 on your own auto policy' when 2 then 'rental coverage on your credit card'
                       when 3 then 'the CarmaCars Protection Plan' else 'no option chosen yet' end
$$;

create or replace function app.same_person_name(a text, b text) returns boolean
language sql immutable as $$
  select coalesce(nullif(lower(regexp_replace(coalesce(a, ''), '[^[:alnum:]]+', '', 'g')), '')
                  = nullif(lower(regexp_replace(coalesce(b, ''), '[^[:alnum:]]+', '', 'g')), ''), false)
$$;

create or replace function app.booking_class_label(p_booking uuid) returns text
language sql stable security definer set search_path = public, app as $$
  select coalesce((select c.label from vehicle_classes c where c.code = v.class::text), initcap(replace(v.class::text, '_', ' ')))
    from bookings b join vehicles v on v.id = b.vehicle_id where b.id = p_booking
$$;

-- The card that paid for the booking (the Card on File), checked for credit card rental coverage.
--   problem: null (eligible), 'no_card' (not paid by card yet), 'not_credit' (debit, prepaid or unknown),
--            'name_mismatch' (the cardholder is not the renter)
create or replace function app.card_coverage_check(p_booking uuid) returns jsonb
language plpgsql stable security definer set search_path = public, app as $$
declare
  b bookings;
  r renters;
  pm payment_methods;
  v_funding text;
  v_match boolean;
  v_problem text;
begin
  select * into b from bookings where id = p_booking;
  if b.id is null then return null; end if;
  select * into r from renters where id = b.renter_id;
  select * into pm from payment_methods where id = b.card_on_file_id;
  v_funding := coalesce(pm.funding, case when pm.is_credit then 'credit' when pm.is_credit = false then 'unknown' end);
  v_match := app.same_person_name(pm.cardholder_name, r.legal_name);
  if pm.id is null then v_problem := 'no_card';
  elsif coalesce(v_funding, 'unknown') <> 'credit' then v_problem := 'not_credit';
  elsif not v_match then v_problem := 'name_mismatch';
  end if;
  return jsonb_build_object(
    'eligible', v_problem is null, 'problem', v_problem,
    'payment_method_id', pm.id, 'brand', pm.card_brand, 'last4', pm.card_last4, 'funding', v_funding, 'country', pm.card_country,
    'cardholder_name', pm.cardholder_name, 'renter_name', r.legal_name, 'name_matches', pm.id is not null and v_match,
    'vehicle_class', app.booking_class_label(b.id), 'rental_days', b.billable_days,
    'message', case v_problem
      when 'no_card' then 'Pay for the booking with the credit card that has the rental car coverage first.'
      when 'not_credit' then format('The card you paid with (%s ending %s) is a %s card. Rental coverage counts only on a credit card: choose OPCF 27 on your own auto policy or the Protection Plan instead.',
                                    coalesce(initcap(pm.card_brand), 'card'), coalesce(pm.card_last4, '????'), case v_funding when 'debit' then 'debit' when 'prepaid' then 'prepaid' else 'non-credit' end)
      when 'name_mismatch' then 'The card you paid with is not in your name. Credit card rental coverage must be on a card in the renter''s name: choose OPCF 27 on your own auto policy or the Protection Plan instead.'
    end);
end $$;

-- the booking may still change its coverage: a paid or awaiting-payment booking that is not an Owner Booking
create or replace function app.coverage_assert_open(b bookings) returns void
language plpgsql stable as $$
begin
  if b.id is null then raise exception 'Booking not found' using errcode = 'P0002'; end if;
  if b.booking_type = 'owner' then raise exception 'An Owner Booking needs no Coverage Option' using errcode = '23514'; end if;
  if b.status not in ('pending_payment', 'confirmed') then
    raise exception 'Booking % is %: coverage is sent between the approved offer and pickup', b.booking_number, b.status using errcode = '23514';
  end if;
end $$;

create or replace function app.coverage_assert_actor(p_booking uuid, p_by uuid) returns void
language plpgsql stable security definer set search_path = public, app as $$
begin
  if p_by is not null and not (app.is_booking_renter(p_booking, p_by) or app.user_is_admin(p_by) or app.user_va_has(p_by, 'cs')) then
    raise exception 'Not permitted' using errcode = '42501';
  end if;
end $$;

-- ================================================================ 4. changing the option, asking for the Protection Plan
create or replace function app.set_coverage_option(p_booking uuid, p_by uuid, p_option integer) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  b bookings;
  v_check jsonb;
begin
  perform app.coverage_assert_actor(p_booking, p_by);
  select * into b from bookings where id = p_booking for update;
  perform app.coverage_assert_open(b);
  if p_option is null or p_option not in (1, 2) then
    raise exception 'Choose option 1 (OPCF 27 on your own auto policy) or option 2 (credit card coverage). For the Protection Plan, ask us and we add it.' using errcode = '22023';
  end if;
  if b.coverage_option = p_option then return app.renter_coverage(p_booking); end if;
  if b.coverage_option = 3 then
    raise exception 'Your booking includes the Protection Plan. To change that, message us.' using errcode = '23514';
  end if;
  if p_option = 2 then
    v_check := app.card_coverage_check(p_booking);
    if v_check ->> 'problem' in ('not_credit', 'name_mismatch') then
      raise exception '%', v_check ->> 'message' using errcode = '23514';
    end if;
  end if;
  update coverage_proofs set status = 'lapsed' where booking_id = p_booking and status in ('submitted', 'confirmed');
  update verification_uploads set status = 'replaced' where booking_id = p_booking and kind = 'coverage_proof' and status in ('submitted', 'approved');
  update bookings set coverage_option = p_option, coverage_confirmed_at = null where id = p_booking;
  perform app.log_booking_event(p_booking, 'verification', b.status::text, b.status::text, null,
    format('Coverage option changed from %s to %s', coalesce(b.coverage_option::text, 'none'), p_option), p_by,
    case when app.is_booking_renter(p_booking, p_by) then 'renter' else 'staff' end,
    jsonb_build_object('coverage_option_from', b.coverage_option, 'coverage_option_to', p_option));
  return app.renter_coverage(p_booking);
end $$;

insert into task_rules (task_type, queue, title, priority, due_kind, due_amount, procedure_no, completion_rule, description) values
  ('protection_plan_request', 'cs', 'The renter asks for the Protection Plan', 'high', 'opening_minutes', 120, 2, null,
   'Price the Protection Plan for this booking and propose the change to the renter (Change booking). Coverage is confirmed once it is paid and activated.')
on conflict (task_type) do nothing;

create or replace function app.request_protection_plan(p_booking uuid, p_by uuid, p_note text default null) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  b bookings;
  v_task uuid;
begin
  perform app.coverage_assert_actor(p_booking, p_by);
  select * into b from bookings where id = p_booking;
  perform app.coverage_assert_open(b);
  if b.coverage_option = 3 then raise exception 'Your booking already includes the Protection Plan' using errcode = '23514'; end if;
  v_task := app.raise_task(p_type => 'protection_plan_request',
    p_title => format('Booking %s: the renter asks for the Protection Plan', b.booking_number),
    p_detail => 'The renter cannot use option 1 or 2 and asks for the Protection Plan. Price it and propose the change before pickup.'
                || coalesce(' Their note: ' || nullif(left(btrim(p_note), 500), ''), ''),
    p_booking => b.id, p_vehicle => b.vehicle_id, p_renter => b.renter_id,
    p_due_at => least(greatest(b.pickup_at - interval '24 hours', now() + interval '1 hour'), now() + interval '24 hours'),
    p_dedupe => 'protection_plan_request:' || b.id);
  perform app.log_booking_event(p_booking, 'verification', b.status::text, b.status::text, null, 'The renter asked for the Protection Plan', p_by,
    case when app.is_booking_renter(p_booking, p_by) then 'renter' else 'staff' end, jsonb_build_object('protection_plan_request', true));
  return jsonb_build_object('task_id', v_task);
end $$;

-- ================================================================ 3. option 2: the renter's confirmation
create or replace function app.submit_card_coverage(p_booking uuid, p_by uuid, p_confirm boolean, p_text text default null) returns uuid
language plpgsql security definer set search_path = public, app as $$
declare
  b bookings;
  v_check jsonb;
  cp coverage_proofs;
  v_id uuid;
begin
  perform app.coverage_assert_actor(p_booking, p_by);
  select * into b from bookings where id = p_booking for update;
  perform app.coverage_assert_open(b);
  if b.coverage_option is distinct from 2 then
    raise exception 'This booking is not covered by credit card coverage (option 2). Change the option first.' using errcode = '23514';
  end if;
  v_check := app.card_coverage_check(p_booking);
  if not (v_check ->> 'eligible')::boolean then raise exception '%', v_check ->> 'message' using errcode = '23514'; end if;
  if p_confirm is not true then
    raise exception 'Tick that your card includes rental car coverage for this car and this length of rental, and that you will claim on it' using errcode = '22023';
  end if;
  select * into cp from coverage_proofs where booking_id = p_booking and coverage_option = 2 and status in ('submitted', 'confirmed')
   order by created_at desc limit 1;
  if cp.status = 'confirmed' then return cp.id; end if;
  if cp.id is null then
    insert into coverage_proofs (booking_id, coverage_option, status) values (p_booking, 2, 'submitted') returning * into cp;
  end if;
  update coverage_proofs
     set payment_method_id = (v_check ->> 'payment_method_id')::uuid, card_brand = v_check ->> 'brand', card_funding = v_check ->> 'funding',
         card_issuer = coalesce(initcap(v_check ->> 'brand'), 'Card'), card_last4 = v_check ->> 'last4',
         cardholder_name = v_check ->> 'cardholder_name', name_matches = (v_check ->> 'name_matches')::boolean,
         renter_confirmed_at = now(), renter_confirmed_by = p_by,
         confirmation_text = coalesce(nullif(left(btrim(p_text), 600), ''),
           format('My card ending %s includes rental car coverage for a %s for %s days, and I will claim on it for any damage to the car.',
                  v_check ->> 'last4', lower(v_check ->> 'vehicle_class'), v_check ->> 'rental_days')),
         vehicle_class_label = v_check ->> 'vehicle_class', rental_days = (v_check ->> 'rental_days')::integer,
         submitted_by = p_by, submitted_at = now(), rejection_reason = null
   where id = cp.id
  returning id into v_id;
  perform app.emit_event('staff_identity_review', 'booking', p_booking,
    jsonb_build_object('booking_id', p_booking, 'booking_number', b.booking_number, 'kind', 'coverage', 'driver_id', null,
                       'driver_name', (select r.legal_name from renters r where r.id = b.renter_id), 'pickup_at', b.pickup_at),
    'staff_identity_review:' || p_booking || ':cp:' || v_id);
  return v_id;
end $$;

-- ================================================================ 2. uploads: licence, selfie, and the pages of a proof
-- 0019's function with the proof of coverage reworked:
--   * option 1 needs the insurer, the policy number and an expiry after the return date (kept from an earlier page);
--   * option 2 takes the card from the Card on File (a credit card in the renter's name) after the renter's tick;
--   * each file is a page of the current proof (up to coverage_proof_max_pages); a declined proof starts a new one;
--   * the file is a rental record: kept 7 years after the return, then purged.
create or replace function app.register_verification_upload(p_booking uuid, p_by uuid, p_kind text, p_driver uuid, p_storage_path text,
                                                            p_sha256 text default null, p_mime_type text default null,
                                                            p_details jsonb default null, p_storage_bucket text default null)
returns uuid language plpgsql security definer set search_path = public, app as $$
declare
  b bookings;
  v_set program_settings := app.settings();
  v_id_kind boolean := p_kind in ('licence_front', 'licence_back', 'selfie');
  d jsonb := coalesce(p_details, '{}'::jsonb);
  v_doc uuid;
  v_iv uuid;
  cp coverage_proofs;
  v_option integer;
  v_purge timestamptz;
  v_id uuid;
  v_name text;
  v_insurer text;
  v_policy text;
  v_expiry date;
  v_check jsonb;
  v_pages integer;
  v_first boolean := false;
begin
  select * into b from bookings where id = p_booking for update;
  if b.id is null then raise exception 'Booking % not found', p_booking; end if;
  if p_kind is null or p_kind not in ('licence_front', 'licence_back', 'selfie', 'coverage_proof') then
    raise exception 'Unknown kind of upload "%"', p_kind using errcode = '22023';
  end if;
  if p_by is not null and not (app.is_booking_renter(p_booking, p_by) or app.user_is_staff(p_by)
       or exists (select 1 from drivers x where x.id = p_driver and x.user_id = p_by)
       or exists (select 1 from staff_profiles sp join users u on u.id = sp.user_id
                   where sp.user_id = p_by and sp.staff_type = 'field' and sp.is_active and u.status = 'active')) then
    raise exception 'Not permitted' using errcode = '42501';
  end if;
  if b.status not in ('pending_payment', 'confirmed') then
    raise exception 'Booking % is %: documents are uploaded once the offer is approved', b.booking_number, b.status using errcode = '23514';
  end if;
  if nullif(btrim(coalesce(p_storage_path, '')), '') is null then
    raise exception 'An upload needs the key of its file in private storage' using errcode = '22023';
  end if;
  if v_id_kind then
    select x.full_name into v_name from booking_drivers x where x.booking_id = p_booking and x.driver_id = p_driver;
    if v_name is null then raise exception 'That driver is not on this booking' using errcode = '23514'; end if;
    v_purge := greatest(b.return_at, now()) + make_interval(days => v_set.retention_id_face_days);
  else
    if p_driver is not null then
      raise exception 'The proof of coverage belongs to the booking, not to one driver' using errcode = '22023';
    elsif b.booking_type = 'owner' then
      raise exception 'An Owner Booking needs no Coverage Option' using errcode = '23514';
    end if;
    v_option := coalesce(nullif(d ->> 'coverage_option', '')::integer, b.coverage_option);
    if v_option is null or v_option not in (1, 2) then
      raise exception 'Proof is uploaded for coverage option 1 (OPCF 27 on your own auto policy) or 2 (credit card coverage)' using errcode = '22023';
    end if;
    if b.coverage_option is distinct from v_option then
      raise exception 'Your booking is set to coverage option %. Change the option first.', coalesce(b.coverage_option::text, 'none') using errcode = '23514';
    end if;
    -- the current proof (a declined one is kept as it is and a new one starts)
    select * into cp from coverage_proofs where booking_id = p_booking and coverage_option = v_option and status in ('submitted', 'confirmed')
     order by created_at desc limit 1;
    if cp.status = 'confirmed' then
      raise exception 'Your coverage is already confirmed. To change it, message us.' using errcode = '23514';
    end if;
    if v_option = 1 then
      v_insurer := coalesce(nullif(left(btrim(d ->> 'insurer_name'), 120), ''), cp.insurer_name);
      v_policy := coalesce(nullif(left(btrim(d ->> 'policy_number'), 60), ''), cp.policy_number);
      v_expiry := coalesce(nullif(d ->> 'policy_expiry', '')::date, cp.policy_expiry);
      if v_insurer is null or v_policy is null or v_expiry is null then
        raise exception 'Add the insurer, the policy number and the policy expiry date first' using errcode = '22023';
      end if;
      if v_expiry <= app.local_date(b.return_at) then
        raise exception 'The policy must still be active after your return date (%). Its expiry date is %.', app.fmt_day(app.local_date(b.return_at)), app.fmt_day(v_expiry)
          using errcode = '23514';
      end if;
    else
      v_check := app.card_coverage_check(p_booking);
      if not (v_check ->> 'eligible')::boolean then raise exception '%', v_check ->> 'message' using errcode = '23514'; end if;
      if cp.id is null or cp.renter_confirmed_at is null then
        raise exception 'Confirm that your card includes rental car coverage first, then add its benefit document' using errcode = '23514';
      end if;
    end if;
    if cp.id is not null then
      select count(*) into v_pages from verification_uploads u where u.coverage_proof_id = cp.id and u.status in ('submitted', 'approved');
      if v_pages >= v_set.coverage_proof_max_pages then
        raise exception 'A proof can have up to % pages. Combine them into one PDF, or message us.', v_set.coverage_proof_max_pages using errcode = '23514';
      end if;
    end if;
    -- a rental record (privacy policy section 6): 7 years after the return
    v_purge := greatest(b.return_at, now()) + interval '7 years';
  end if;

  insert into documents (kind, title, storage_bucket, storage_path, mime_type, sha256, retention, purge_after, uploaded_by, renter_id, booking_id)
  values (case p_kind when 'licence_front' then 'id_front' when 'licence_back' then 'id_back' when 'selfie' then 'face_photo' else 'coverage_proof' end::document_kind,
          case p_kind when 'licence_front' then 'Licence, front: ' || v_name when 'licence_back' then 'Licence, back: ' || v_name
                      when 'selfie' then 'Face photo: ' || v_name
                      else case v_option when 1 then 'OPCF 27 policy, booking ' else 'Card benefit document, booking ' end || b.booking_number end,
          coalesce(p_storage_bucket, case when v_id_kind then 'identity' else 'documents' end), p_storage_path, p_mime_type,
          lower(nullif(btrim(coalesce(p_sha256, '')), '')), case when v_id_kind then 'id_face_90d' else 'records_7y' end::retention_class,
          v_purge, p_by, b.renter_id, p_booking)
  returning id into v_doc;

  if v_id_kind then
    update verification_uploads set status = 'replaced'
     where booking_id = p_booking and driver_id is not distinct from p_driver and kind = p_kind and status in ('submitted', 'approved');
    -- one staff review per driver and booking, reopened by a new upload
    select iv.id into v_iv from identity_verifications iv
     where iv.driver_id = p_driver and iv.booking_id = p_booking and iv.method = 'staff_review' and iv.purged_at is null
     order by iv.created_at desc limit 1;
    if v_iv is null then
      insert into identity_verifications (driver_id, booking_id, method, status, purge_after)
      values (p_driver, p_booking, 'staff_review', 'pending', v_purge) returning id into v_iv;
    end if;
    update identity_verifications
       set status = 'pending', failure_reason = null, verified_by = null, verified_at = null, purge_after = v_purge,
           id_front_document_id = case when p_kind = 'licence_front' then v_doc else id_front_document_id end,
           id_back_document_id = case when p_kind = 'licence_back' then v_doc else id_back_document_id end,
           face_document_id = case when p_kind = 'selfie' then v_doc else face_document_id end
     where id = v_iv;
    update booking_drivers set identity_verified_on = null, identity_method = null where booking_id = p_booking and driver_id = p_driver;
    update drivers set identity_status = 'pending' where id = p_driver and identity_status <> 'verified';
  else
    if cp.id is null then
      v_first := true;
      insert into coverage_proofs (booking_id, coverage_option, status, insurer_name, policy_number, policy_expiry, proof_document_id, submitted_by, submitted_at)
      values (p_booking, v_option, 'submitted', v_insurer, v_policy, v_expiry, v_doc, p_by, now())
      returning * into cp;
    elsif v_option = 1 then
      update coverage_proofs set insurer_name = v_insurer, policy_number = v_policy, policy_expiry = v_expiry,
             proof_document_id = coalesce(proof_document_id, v_doc), submitted_at = now()
       where id = cp.id;
    else
      v_first := not exists (select 1 from verification_uploads u where u.coverage_proof_id = cp.id and u.status in ('submitted', 'approved'));
      update coverage_proofs set proof_document_id = coalesce(proof_document_id, v_doc) where id = cp.id;
    end if;
  end if;

  insert into verification_uploads (booking_id, driver_id, kind, document_id, identity_verification_id, coverage_proof_id, uploaded_by)
  values (p_booking, p_driver, p_kind, v_doc, v_iv, cp.id, p_by)
  returning id into v_id;

  -- ready for review: a proof at its first page; a driver's identity once all three images are in
  if (not v_id_kind and v_first) or (v_id_kind and (select count(distinct u.kind) from verification_uploads u
                        where u.booking_id = p_booking and u.driver_id = p_driver and u.status in ('submitted', 'approved')) = 3) then
    perform app.emit_event('staff_identity_review', 'booking', p_booking,
      jsonb_build_object('booking_id', p_booking, 'booking_number', b.booking_number, 'kind', case when v_id_kind then 'identity' else 'coverage' end,
                         'driver_id', p_driver, 'driver_name', coalesce(v_name, (select r.legal_name from renters r where r.id = b.renter_id)),
                         'pickup_at', b.pickup_at),
      'staff_identity_review:' || p_booking || ':' || case when v_id_kind then v_id::text else 'cp:' || cp.id end);
  end if;
  return v_id;
end $$;

-- ================================================================ 5. staff review of a proof, as a whole
-- Customer service (or an Admin) approves or rejects the proof: every page with it. Approval checks again what the
-- renter could not change since: the policy runs past the return date (an extension moves it); the card is still the
-- Card on File, a credit card in the renter's name, and the renter ticked the confirmation.
create or replace function app.review_coverage_proof(p_proof uuid, p_by uuid, p_approve boolean, p_reason text default null, p_checks jsonb default null)
returns jsonb language plpgsql security definer set search_path = public, app as $$
declare
  cp coverage_proofs;
  b bookings;
  v_reason text := nullif(btrim(coalesce(p_reason, '')), '');
  v_check jsonb;
  v_ready jsonb;
begin
  if not (app.user_is_admin(p_by) or app.user_va_has(p_by, 'cs')) then
    raise exception 'Only customer service or an Admin reviews identity and coverage documents' using errcode = '42501';
  end if;
  select * into cp from coverage_proofs where id = p_proof for update;
  if cp.id is null then raise exception 'Proof % not found', p_proof using errcode = 'P0002'; end if;
  select * into b from bookings where id = cp.booking_id for update;
  if cp.status <> 'submitted' then raise exception 'This proof is % and is not waiting for review', cp.status using errcode = '23514'; end if;
  if p_approve is null then raise exception 'Approve or reject' using errcode = '22023'; end if;
  if not p_approve and v_reason is null then
    raise exception 'Rejecting a proof needs a reason the renter can act on' using errcode = '22023';
  end if;
  if p_approve then
    if cp.coverage_option is distinct from b.coverage_option then
      raise exception 'The booking is now on coverage option %; this proof is for option %', b.coverage_option, cp.coverage_option using errcode = '23514';
    end if;
    if cp.coverage_option = 1 then
      if cp.insurer_name is null or cp.policy_number is null or cp.policy_expiry is null then
        raise exception 'The proof cannot be confirmed without the insurer, the policy number and the expiry date' using errcode = '23514';
      end if;
      if cp.policy_expiry <= app.local_date(b.return_at) then
        raise exception 'The policy ends on %, not after the return date (%)', app.fmt_day(cp.policy_expiry), app.fmt_day(app.local_date(b.return_at)) using errcode = '23514';
      end if;
      if not exists (select 1 from verification_uploads u where u.coverage_proof_id = cp.id and u.status = 'submitted') then
        raise exception 'The renter has not sent the policy document yet' using errcode = '23514';
      end if;
    elsif cp.coverage_option = 2 then
      v_check := app.card_coverage_check(b.id);
      if not (v_check ->> 'eligible')::boolean then raise exception '%', v_check ->> 'message' using errcode = '23514'; end if;
      if cp.payment_method_id is distinct from b.card_on_file_id then
        raise exception 'The card on this proof is no longer the Card on File' using errcode = '23514';
      end if;
      if cp.renter_confirmed_at is null then
        raise exception 'The renter has not confirmed that the card includes rental car coverage' using errcode = '23514';
      end if;
    end if;
  end if;
  update verification_uploads
     set status = case when p_approve then 'approved' else 'rejected' end, reject_reason = case when not p_approve then v_reason end,
         reviewed_by = p_by, reviewed_at = now()
   where coverage_proof_id = cp.id and status = 'submitted';
  if p_approve then
    update coverage_proofs set status = 'confirmed', confirmed_by = p_by, confirmed_at = now(), covers_vehicle_and_drivers = true,
           rejection_reason = null, reviewed_checks = p_checks where id = cp.id;
    update bookings set coverage_confirmed_at = now() where id = b.id;
  else
    update coverage_proofs set status = 'rejected', rejection_reason = v_reason, reviewed_checks = p_checks where id = cp.id;
  end if;
  perform app.log_booking_event(b.id, 'verification', b.status::text, b.status::text, null, v_reason, p_by, 'staff',
    jsonb_build_object('coverage_proof_id', cp.id, 'kind', 'coverage_proof', 'coverage_option', cp.coverage_option,
                       'decision', case when p_approve then 'approved' else 'rejected' end));
  v_ready := app.booking_readiness(b.id);
  if not p_approve then
    perform app.emit_event('renter_identity_rejected', 'booking', b.id,
      jsonb_build_object('booking_id', b.id, 'booking_number', b.booking_number, 'kind', 'coverage_proof', 'driver_id', null,
                         'driver_name', (select r.legal_name from renters r where r.id = b.renter_id), 'reject_reason', v_reason),
      'renter_identity_rejected:' || b.id || ':cp:' || cp.id);
  elsif (v_ready ->> 'identity_and_coverage_confirmed')::boolean then
    perform app.emit_event('renter_identity_approved', 'booking', b.id,
      jsonb_build_object('booking_id', b.id, 'booking_number', b.booking_number, 'pickup_at', b.pickup_at),
      'renter_identity_approved:' || b.id || ':verified');
  end if;
  return v_ready;
end $$;

-- An upload of a proof is decided with its proof.
alter function app.review_verification_upload(uuid, uuid, boolean, text) rename to review_verification_upload_pre0071;
create or replace function app.review_verification_upload(p_upload uuid, p_by uuid, p_approve boolean, p_reason text default null)
returns jsonb language plpgsql security definer set search_path = public, app as $$
declare
  u verification_uploads;
begin
  select * into u from verification_uploads where id = p_upload;
  if u.id is not null and u.kind = 'coverage_proof' and u.coverage_proof_id is not null then
    if u.status <> 'submitted' then raise exception 'This upload is % and is not waiting for review', u.status using errcode = '23514'; end if;
    return app.review_coverage_proof(u.coverage_proof_id, p_by, p_approve, p_reason);
  end if;
  return app.review_verification_upload_pre0071(p_upload, p_by, p_approve, p_reason);
end $$;

-- The Protection Plan (option 3) is bought with the booking: staff confirm its activation, which releases the car.
create or replace function app.confirm_protection_plan(p_booking uuid, p_by uuid, p_ref text default null) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  b bookings;
  v_ready jsonb;
begin
  if not (app.user_is_admin(p_by) or app.user_va_has(p_by, 'cs')) then
    raise exception 'Only customer service or an Admin confirms the Protection Plan' using errcode = '42501';
  end if;
  select * into b from bookings where id = p_booking for update;
  if b.id is null then raise exception 'Booking not found' using errcode = 'P0002'; end if;
  if b.coverage_option is distinct from 3 then raise exception 'This booking is not on the Protection Plan (option 3)' using errcode = '23514'; end if;
  if b.status <> 'confirmed' then raise exception 'Booking % is %: the Protection Plan is confirmed on a paid booking', b.booking_number, b.status using errcode = '23514'; end if;
  if not exists (select 1 from booking_line_items li where li.booking_id = b.id and li.charge_type = 'coverage_sold' and li.voided_at is null) then
    raise exception 'The booking has no Protection Plan line: price it and have the renter pay for it first' using errcode = '23514';
  end if;
  if exists (select 1 from coverage_proofs c where c.booking_id = b.id and c.coverage_option = 3 and c.status = 'confirmed') then
    return app.booking_readiness(b.id);
  end if;
  insert into coverage_proofs (booking_id, coverage_option, status, terms_sent_at, activation_ref, activated_at, confirmed_by, confirmed_at,
                               covers_vehicle_and_drivers, submitted_by, submitted_at)
  values (b.id, 3, 'confirmed', b.confirmed_at, nullif(left(btrim(coalesce(p_ref, '')), 120), ''), now(), p_by, now(), true, p_by, now());
  update bookings set coverage_confirmed_at = now() where id = b.id;
  perform app.log_booking_event(b.id, 'verification', b.status::text, b.status::text, null, 'Protection Plan activation confirmed', p_by, 'staff',
    jsonb_build_object('kind', 'protection_plan', 'decision', 'approved'));
  v_ready := app.booking_readiness(b.id);
  if (v_ready ->> 'identity_and_coverage_confirmed')::boolean then
    perform app.emit_event('renter_identity_approved', 'booking', b.id,
      jsonb_build_object('booking_id', b.id, 'booking_number', b.booking_number, 'pickup_at', b.pickup_at),
      'renter_identity_approved:' || b.id || ':verified');
  end if;
  return v_ready;
end $$;

-- ================================================================ what the renter and staff see
-- The current proof: the latest that is submitted, confirmed or rejected, for the booking's option.
create or replace function app.current_coverage_proof(p_booking uuid) returns coverage_proofs
language sql stable security definer set search_path = public, app as $$
  select c.* from coverage_proofs c join bookings b on b.id = c.booking_id
   where c.booking_id = p_booking and c.status in ('submitted', 'confirmed', 'rejected') and c.coverage_option = b.coverage_option
   order by (c.status = 'confirmed') desc, c.created_at desc limit 1
$$;

create or replace function app.renter_coverage(p_booking uuid) returns jsonb
language plpgsql stable security definer set search_path = public, app as $$
declare
  b bookings;
  cp coverage_proofs;
  v_return date;
begin
  select * into b from bookings where id = p_booking;
  if b.id is null then return null; end if;
  cp := app.current_coverage_proof(p_booking);
  v_return := app.local_date(b.return_at);
  return jsonb_build_object(
    'option', b.coverage_option, 'option_label', app.coverage_option_label(b.coverage_option),
    'confirmed', b.coverage_confirmed_at is not null, 'confirmed_at', b.coverage_confirmed_at,
    'booking_status', b.status, 'return_date', v_return, 'min_policy_expiry', v_return + 1, 'pickup_at', b.pickup_at,
    'vehicle_class', app.booking_class_label(b.id), 'rental_days', b.billable_days,
    'can_change', b.status in ('pending_payment', 'confirmed') and b.booking_type <> 'owner' and coalesce(b.coverage_option, 0) <> 3,
    'protection_plan_line', exists (select 1 from booking_line_items li where li.booking_id = b.id and li.charge_type = 'coverage_sold' and li.voided_at is null),
    'protection_plan_requested', exists (select 1 from tasks t where t.booking_id = b.id and t.task_type = 'protection_plan_request' and t.status in ('open', 'in_progress', 'waiting')),
    'card', app.card_coverage_check(b.id) - 'renter_name',
    'max_pages', (app.settings()).coverage_proof_max_pages,
    'proof', case when cp.id is null then null else jsonb_build_object(
      'id', cp.id, 'option', cp.coverage_option, 'status', cp.status, 'rejection_reason', cp.rejection_reason,
      'insurer_name', cp.insurer_name, 'policy_number', cp.policy_number, 'policy_expiry', cp.policy_expiry,
      'card_brand', cp.card_brand, 'card_last4', cp.card_last4, 'renter_confirmed_at', cp.renter_confirmed_at, 'confirmation_text', cp.confirmation_text,
      'pages', coalesce((select jsonb_agg(jsonb_build_object('id', u.id, 'status', u.status, 'uploaded_at', u.uploaded_at, 'mime_type', d.mime_type) order by u.uploaded_at)
                           from verification_uploads u join documents d on d.id = u.document_id
                          where u.coverage_proof_id = cp.id and u.status in ('submitted', 'approved', 'rejected')), '[]'::jsonb)) end);
end $$;

-- staff: the proof with its pages (private file keys, for one-minute links), the card facts, and what to check
create or replace function app.coverage_review_facts(p_booking uuid) returns jsonb
language plpgsql stable security definer set search_path = public, app as $$
declare
  b bookings;
  cp coverage_proofs;
  v_return date;
begin
  select * into b from bookings where id = p_booking;
  if b.id is null then return null; end if;
  cp := app.current_coverage_proof(p_booking);
  v_return := app.local_date(b.return_at);
  return jsonb_build_object(
    'option', b.coverage_option, 'option_label', app.coverage_option_label(b.coverage_option), 'confirmed', b.coverage_confirmed_at is not null,
    'return_date', v_return, 'vehicle_class', app.booking_class_label(b.id), 'rental_days', b.billable_days, 'booking_status', b.status,
    'card', app.card_coverage_check(b.id),
    'protection_plan_line', exists (select 1 from booking_line_items li where li.booking_id = b.id and li.charge_type = 'coverage_sold' and li.voided_at is null),
    'proof', case when cp.id is null then null else to_jsonb(cp) || jsonb_build_object(
      'policy_valid', cp.policy_expiry is not null and cp.policy_expiry > v_return,
      'card_is_card_on_file', cp.payment_method_id is not distinct from b.card_on_file_id,
      'pages', coalesce((select jsonb_agg(jsonb_build_object('id', u.id, 'status', u.status, 'uploaded_at', u.uploaded_at, 'reject_reason', u.reject_reason,
                                 'bucket', d.storage_bucket, 'path', d.storage_path, 'mime_type', d.mime_type) order by u.uploaded_at)
                           from verification_uploads u join documents d on d.id = u.document_id
                          where u.coverage_proof_id = cp.id and u.status in ('submitted', 'approved', 'rejected') and d.purged_at is null), '[]'::jsonb)) end);
end $$;

-- the coverage in words, for the field ready check and the booking pages
create or replace function app.coverage_summary(p_booking uuid) returns text
language sql stable security definer set search_path = public, app as $$
  select case when b.booking_type = 'owner' then 'Not needed (Owner Booking)'
              when b.coverage_confirmed_at is null then 'Not confirmed'
              else case b.coverage_option
                     when 1 then 'Own policy with OPCF 27' || coalesce(', ' || cp.insurer_name, '') || coalesce(', valid to ' || app.fmt_day(cp.policy_expiry), '')
                     when 2 then 'Credit card coverage' || coalesce(', ' || initcap(cp.card_brand), '') || coalesce(' ending ' || cp.card_last4, '')
                     when 3 then 'Protection Plan'
                     else 'Confirmed' end end
    from bookings b left join lateral (select * from app.current_coverage_proof(b.id)) cp on true
   where b.id = p_booking
$$;

-- ================================================================ the doors
-- the renter's own (server only, after checking the session; each asserts the booking is theirs)
create or replace function public.server_renter_coverage(p_booking uuid, p_by uuid) returns jsonb
language plpgsql stable security definer set search_path = public, app as $$
begin
  perform app.assert_booking_renter(p_booking, p_by);
  return app.renter_coverage(p_booking);
end $$;
create or replace function public.renter_set_coverage_option(p_booking uuid, p_by uuid, p_option integer) returns jsonb
language plpgsql security definer set search_path = public, app as $$
begin
  perform app.assert_booking_renter(p_booking, p_by);
  return app.set_coverage_option(p_booking, p_by, p_option);
end $$;
create or replace function public.renter_submit_card_coverage(p_booking uuid, p_by uuid, p_confirm boolean, p_text text default null) returns jsonb
language plpgsql security definer set search_path = public, app as $$
begin
  perform app.assert_booking_renter(p_booking, p_by);
  return jsonb_build_object('proof_id', app.submit_card_coverage(p_booking, p_by, p_confirm, p_text));
end $$;
create or replace function public.renter_request_protection_plan(p_booking uuid, p_by uuid, p_note text default null) returns jsonb
language plpgsql security definer set search_path = public, app as $$
begin
  perform app.assert_booking_renter(p_booking, p_by);
  if not app.rate_limit('protection_plan:user:' || p_by, 5, interval '1 day') then
    raise exception 'You asked already. We will be in touch.' using errcode = '54000';
  end if;
  return app.request_protection_plan(p_booking, p_by, p_note);
end $$;

-- the assistants' screen and actions: the coverage beside the licence checks
alter function app.va_read(uuid, text, jsonb) rename to va_read_pre0071;
create or replace function app.va_read(p_user uuid, p_what text, p jsonb default '{}'::jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  x jsonb := app.va_read_pre0071(p_user, p_what, p);
begin
  if p_what = 'verification' and x is not null and x ? 'booking_id' then
    x := x || jsonb_build_object('coverage', app.coverage_review_facts((x ->> 'booking_id')::uuid));
  end if;
  return x;
end $$;

alter function app.va_do(uuid, text, jsonb) rename to va_do_pre0071;
create or replace function app.va_do(p_user uuid, p_action text, p jsonb default '{}'::jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  p_ jsonb := coalesce(p, '{}'::jsonb);
  v_b uuid;
begin
  if p_action in ('coverage_review', 'protection_plan_confirm') then
    if app.va_fn(p_user) <> 'cs' then raise exception 'Coverage is reviewed by customer service' using errcode = '42501'; end if;
    if p_action = 'coverage_review' then
      select c.booking_id into v_b from coverage_proofs c where c.id = (p_ ->> 'proof')::uuid;
    else
      select b.id into v_b from bookings b where b.id::text = p_ ->> 'booking' or b.booking_number = p_ ->> 'booking';
    end if;
    if v_b is null or not exists (select 1 from tasks t where t.booking_id = v_b and t.status in ('open', 'in_progress', 'waiting')
                                     and t.task_type in ('verify_renter', 'chase_verification', 'offer_approved_paid') and t.queue = 'cs') then
      raise exception 'Coverage is reviewed from an open review task on this booking' using errcode = '42501';
    end if;
    if p_action = 'coverage_review' then
      return app.review_coverage_proof((p_ ->> 'proof')::uuid, p_user, (p_ ->> 'approve')::boolean, nullif(btrim(p_ ->> 'reason'), ''), p_ -> 'checks');
    end if;
    return app.confirm_protection_plan(v_b, p_user, p_ ->> 'ref');
  end if;
  return app.va_do_pre0071(p_user, p_action, p);
end $$;

-- the verification screen opens for a Protection Plan booking too (its review task is the booking's first one)
alter function app.va_read_pre0071(uuid, text, jsonb) rename to va_read_pre0071_inner;
create or replace function app.va_read_pre0071(p_user uuid, p_what text, p jsonb default '{}'::jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  p_ jsonb := coalesce(p, '{}'::jsonb);
  v_b uuid;
begin
  if p_what = 'verification' and app.va_fn(p_user) = 'cs' then
    select b.id into v_b from bookings b where b.id::text = p_ ->> 'booking' or b.booking_number = p_ ->> 'booking';
    if v_b is not null and not exists (select 1 from tasks t where t.booking_id = v_b and t.status in ('open', 'in_progress', 'waiting')
                                         and t.task_type in ('verify_renter', 'chase_verification') and t.queue = 'cs')
       and exists (select 1 from tasks t where t.booking_id = v_b and t.status in ('open', 'in_progress', 'waiting')
                     and t.task_type = 'offer_approved_paid' and t.queue = 'cs') then
      insert into data_access_log (user_id, action, renter_id, reason, results)
      select p_user, 'open', b.renter_id, 'coverage review, booking ' || b.booking_number, 0 from bookings b where b.id = v_b;
      return (select jsonb_build_object('booking_id', b.id, 'booking_number', b.booking_number, 'return_at', b.return_at, 'coverage_option', b.coverage_option,
                'readiness', app.booking_readiness(b.id),
                'drivers', coalesce((select jsonb_agg(jsonb_build_object('driver_id', d.driver_id, 'full_name', d.full_name, 'role', d.role, 'date_of_birth', d.date_of_birth,
                                       'licence_number', d.licence_number, 'licence_class', d.licence_class, 'licence_expiry', d.licence_expiry, 'verified_on', d.identity_verified_on)
                                       order by d.role desc, d.full_name) from booking_drivers d where d.booking_id = b.id), '[]'::jsonb),
                'uploads', '[]'::jsonb)
                from bookings b where b.id = v_b);
    end if;
  end if;
  return app.va_read_pre0071_inner(p_user, p_what, p);
end $$;

-- the field ready check names the coverage
alter function app.field_read(uuid, text, jsonb) rename to field_read_pre0071;
create or replace function app.field_read(p_user uuid, p_what text, p jsonb default '{}'::jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  x jsonb := app.field_read_pre0071(p_user, p_what, p);
begin
  if p_what = 'job' and x is not null and jsonb_typeof(x -> 'ready') = 'object' and (x #>> '{booking,id}') is not null then
    x := jsonb_set(x, '{ready,coverage_label}', to_jsonb(app.coverage_summary((x #>> '{booking,id}')::uuid)));
  end if;
  return x;
end $$;

-- ================================================================ 6. reminders before pickup
-- renter_coverage_needed at 48 and 24 hours (program_settings.coverage_reminder_hours) while option 1 or 2 has no
-- proof in review and none confirmed. The 48-hour reminder of identity (renter_identity_needed, "chase") already
-- lists the proof while a licence is missing too; when only the proof is missing, this email takes its place.
create or replace function app.job_coverage_reminders(p_now timestamptz default now()) returns text
language plpgsql security definer set search_path = public, app as $$
declare
  ps program_settings := app.settings();
  r record;
  h integer;
  v_hours integer[];
  n integer := 0;
begin
  select array_agg(x order by x desc) into v_hours from unnest(ps.coverage_reminder_hours) x where x > 0;
  if v_hours is null then return '0 reminders'; end if;
  for r in select b.id, b.pickup_at,
                  exists (select 1 from booking_drivers d where d.booking_id = b.id and d.identity_verified_on is null
                            and not exists (select 1 from identity_verifications iv where iv.driver_id = d.driver_id and iv.booking_id = b.id and iv.status = 'pending')) as identity_missing
             from bookings b
            where b.status = 'confirmed' and b.booking_type <> 'owner' and b.coverage_option in (1, 2) and b.coverage_confirmed_at is null
              and b.pickup_at > p_now and b.pickup_at <= p_now + make_interval(hours => v_hours[1])
              and not exists (select 1 from coverage_proofs c where c.booking_id = b.id and c.coverage_option = b.coverage_option and c.status = 'submitted'
                                and (c.coverage_option = 1 or c.renter_confirmed_at is not null)) loop
    -- the smallest threshold already reached: one email per threshold, never a 48-hour one inside 24 hours
    select min(x) into h from unnest(v_hours) x where r.pickup_at <= p_now + make_interval(hours => x);
    if h is null then continue; end if;
    if h = v_hours[1] and array_length(v_hours, 1) > 1 and r.identity_missing then continue; end if;
    if app.emit_event('renter_coverage_needed', 'booking', r.id, jsonb_build_object('booking_id', r.id, 'hours', h),
                      'renter_coverage_needed:' || r.id || ':h' || h) is not null then
      n := n + 1;
    end if;
  end loop;
  return format('%s reminders', n);
end $$;

do $$
begin
  if to_regclass('cron.job') is not null then
    perform cron.schedule('carmacars-coverage-reminders', '7,22,37,52 * * * *', $q$select app.job_coverage_reminders()$q$);
  end if;
end $$;

alter function app.notification_recipients(app_events, notification_catalogue) rename to notification_recipients_pre0071;
create or replace function app.notification_recipients(p_event app_events, p_c notification_catalogue)
returns table (audience text, user_id uuid, email text, name text, renter_id uuid, owner_id uuid, immediate boolean)
language plpgsql stable security definer set search_path = public, app as $$
begin
  -- the identity chase when only the proof of coverage is missing: renter_coverage_needed says it instead
  if p_c.code = 'renter_identity_needed' and p_event.dedupe_key like '%:chase' and p_event.entity = 'booking'
     and exists (select 1 from bookings b where b.id = p_event.entity_id and b.coverage_option in (1, 2))
     and not exists (select 1 from booking_drivers d where d.booking_id = p_event.entity_id and d.identity_verified_on is null) then
    return;
  end if;
  return query select * from app.notification_recipients_pre0071(p_event, p_c);
end $$;

alter function app.notification_payload(text, app_events, jsonb) rename to ntf_payload_pre0071;
create or replace function app.notification_payload(p_code text, p_event app_events, p_to jsonb) returns jsonb
language plpgsql stable security definer set search_path = public, app as $$
declare
  x jsonb := app.ntf_payload_pre0071(p_code, p_event, p_to);
  b bookings;
  cp coverage_proofs;
  v_h integer;
begin
  if p_code = 'renter_coverage_needed' then
    select * into b from bookings where id = p_event.entity_id;
    select * into cp from coverage_proofs c where c.booking_id = b.id and c.coverage_option = b.coverage_option and c.status = 'rejected'
     order by c.created_at desc limit 1;
    v_h := coalesce((p_event.payload ->> 'hours')::integer, 24);
    x := x || jsonb_build_object(
      '_url', app.ntf_link('booking_verify', x),
      'hours_left', v_h || ' hours',
      'coverage_choice', app.coverage_option_label(b.coverage_option),
      'coverage_what_to_send', case b.coverage_option
        when 1 then format('A PDF or photos of your policy document or the OPCF 27 endorsement, with the insurer, the policy number and the expiry date. The policy must still be active after your return date, %s.', app.fmt_day(app.local_date(b.return_at)))
        else format('Confirm that the credit card you paid with includes rental car coverage for this car for %s days, and add the card''s benefit document if you have it. Debit and prepaid cards do not qualify.', b.billable_days) end,
      'has_reject_reason', cp.id is not null and cp.rejection_reason is not null,
      'reject_reason', coalesce(cp.rejection_reason, ''));
  end if;
  return x;
end $$;

-- ================================================================ 7. retention: the files whose time has come
-- The Worker's purge job (/api/jobs/purge, hourly) lists them, deletes each file from private storage, then marks it.
-- Never a file on legal hold, nor one of a booking with an open claim or chargeback (privacy policy section 6).
create or replace function app.documents_due_for_purge(p_limit integer default 200, p_now timestamptz default now()) returns jsonb
language sql stable security definer set search_path = public, app as $$
  select coalesce(jsonb_agg(jsonb_build_object('id', d.id, 'bucket', d.storage_bucket, 'path', d.storage_path, 'retention', d.retention) order by d.purge_after), '[]'::jsonb)
    from (select d.* from documents d
           where d.purged_at is null and d.storage_path is not null and not d.legal_hold and d.purge_after <= p_now
             and d.retention in ('id_face_90d', 'records_7y')
             and not exists (select 1 from disputes x where x.booking_id = d.booking_id and x.status in ('open', 'evidence_submitted'))
             and not exists (select 1 from claims x where x.booking_id = d.booking_id and x.status not in ('closed', 'withdrawn', 'denied', 'distributed'))
           order by d.purge_after limit least(greatest(coalesce(p_limit, 200), 1), 1000)) d
$$;

create or replace function app.mark_documents_purged(p_ids uuid[]) returns integer
language plpgsql security definer set search_path = public, app as $$
declare
  n integer;
begin
  update documents set purged_at = now(), storage_path = null
   where id = any (p_ids) and purged_at is null and not legal_hold and purge_after <= now();
  get diagnostics n = row_count;
  update identity_verifications set purged_at = now()
   where purged_at is null and purge_after <= now()
     and (id_front_document_id = any (p_ids) or id_back_document_id = any (p_ids) or face_document_id = any (p_ids));
  return n;
end $$;

create or replace function public.server_documents_due_for_purge(p_limit integer default 200) returns jsonb
language sql stable security definer set search_path = public, app as $$ select app.documents_due_for_purge(p_limit) $$;
create or replace function public.server_mark_documents_purged(p_ids uuid[]) returns integer
language sql security definer set search_path = public, app as $$ select app.mark_documents_purged(p_ids) $$;

-- ================================================================ privileges
do $$
declare
  f record;
begin
  for f in
    select p.oid::regprocedure as sig from pg_proc p join pg_namespace n on n.oid = p.pronamespace
     where (n.nspname = 'app' and p.proname = any (array[
              'save_card_on_file', 'coverage_option_label', 'booking_class_label', 'card_coverage_check', 'coverage_assert_open',
              'coverage_assert_actor', 'set_coverage_option', 'request_protection_plan', 'submit_card_coverage', 'register_verification_upload',
              'review_coverage_proof', 'review_verification_upload', 'confirm_protection_plan', 'current_coverage_proof', 'renter_coverage',
              'coverage_review_facts', 'coverage_summary', 'va_read', 'va_read_pre0071', 'va_do', 'field_read', 'job_coverage_reminders',
              'notification_recipients', 'notification_payload', 'documents_due_for_purge', 'mark_documents_purged']))
        or (n.nspname = 'public' and p.proname = any (array[
              'server_renter_coverage', 'renter_set_coverage_option', 'renter_submit_card_coverage', 'renter_request_protection_plan',
              'server_documents_due_for_purge', 'server_mark_documents_purged']))
  loop
    execute format('revoke all on function %s from public, anon, authenticated', f.sig);
    execute format('grant execute on function %s to service_role', f.sig);
  end loop;
  -- a name check, harmless and pure: the policies and views may use it
  grant execute on function app.same_person_name(text, text) to authenticated, service_role;
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
             join (values ('save_card_on_file_pre0071', 'save_card_on_file'), ('review_verification_upload_pre0071', 'review_verification_upload'),
                          ('va_read_pre0071_inner', 'va_read'), ('va_do_pre0071', 'va_do'), ('field_read_pre0071', 'field_read'),
                          ('notification_recipients_pre0071', 'notification_recipients'), ('ntf_payload_pre0071', 'notification_payload')) m(old_name, new_name)
               on m.old_name = p.proname
            where n.nspname = 'app' loop
    v_new := format('app.%I(%s)', r.new_name, r.args)::regprocedure;
    foreach g in array array['anon', 'authenticated', 'service_role'] loop
      if has_function_privilege(g, r.oid, 'execute') then execute format('grant execute on function %s to %I', v_new, g); end if;
    end loop;
  end loop;
end $$;

-- ================================================================ the email catalogue
-- CATALOGUE COVERAGE START (generated by supabase/seed/coverage_gen_catalogue.mjs; do not edit by hand)
insert into notification_catalogue (code, audience, also_sent_to, category, is_digest, digest_slot, from_address, reply_to,
    subject, preheader, timing, trigger_text, replaces_template, link_path, variables, template_html, template_text) values
  ('renter_coverage_needed', 'renter', '{}'::text[], 'transactional', false, null, 'CarmaCars <bookings@carmacars.ca>', 'bookings@carmacars.ca', 'Pickup in {{hours_left}}: we still need your proof of coverage', 'Without it we cannot hand over the car. It takes a few minutes on your phone.', '48 hours and 24 hours before pickup, while the proof is missing or was declined', 'A confirmed booking whose Coverage Option is 1 (OPCF 27 on the renter''s own policy) or 2 (credit card rental coverage) has no proof waiting for review and none confirmed: sent 48 hours before pickup and again 24 hours before pickup (app.job_coverage_reminders, every 15 minutes). Not sent while a proof is in review, nor for the Protection Plan. The 48-hour one is skipped while a driver''s licence is also missing (renter_identity_needed then lists the proof too).', null, '/account/bookings/{{booking_number}}/verify', '[{"name":"booking_number","type":"string"},{"name":"company_address","type":"string","global":true},{"name":"contact_email","type":"string","global":true},{"name":"coverage_choice","type":"string"},{"name":"coverage_what_to_send","type":"string"},{"name":"first_name","type":"string"},{"name":"has_reject_reason","type":"boolean"},{"name":"hours_left","type":"string"},{"name":"instagram_url","type":"url","global":true},{"name":"opening_hours","type":"string","global":true},{"name":"reject_reason","type":"string"},{"name":"reply_time","type":"string","global":true},{"name":"support_phone","type":"string","global":true},{"name":"tiktok_url","type":"url","global":true},{"name":"vehicle_name","type":"string"},{"name":"verify_by","type":"string"}]'::jsonb, 'templates/renter_coverage_needed.html', 'templates/renter_coverage_needed.txt')
on conflict (code) do update set
  audience = excluded.audience, also_sent_to = excluded.also_sent_to, category = excluded.category,
  is_digest = excluded.is_digest, digest_slot = excluded.digest_slot, from_address = excluded.from_address,
  reply_to = excluded.reply_to, subject = excluded.subject, preheader = excluded.preheader, timing = excluded.timing,
  trigger_text = excluded.trigger_text, replaces_template = excluded.replaces_template, link_path = excluded.link_path,
  variables = excluded.variables, template_html = excluded.template_html, template_text = excluded.template_text,
  in_catalogue = true, updated_at = now();
select app.notification_catalogue_refresh();
-- CATALOGUE COVERAGE END
update notification_catalogue set emitted_by = 'app.job_coverage_reminders (coverage proof)' where code = 'renter_coverage_needed';

-- ================================================================ the guides for this release
-- GUIDES COVERAGE START (generated by supabase/seed/coverage_gen_guides.mjs from docs/guides/content; do not edit by hand)
-- GUIDES COVERAGE END
