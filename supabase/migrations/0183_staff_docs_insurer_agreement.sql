-- 0183: what the desk needs for insurer-billed rentals (the owner and Mahad, October 28). SCHEMA_MARKER 0183.
--   1. The insurer and adjuster on any booking, at any status (an insurer replacement rental often starts as an ordinary
--      booking and the claim arrives after pickup): Admin > booking > Insurance claim. Switching who pays re-prices the
--      booking's lines (app.sync_booking_price) the same way the review screen does; the change is in the audit log.
-- (Sections 2 to 4 below: staff upload a renter's documents, signing without identity verification, editing the agreement.)
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

-- ================================================================ 1. the insurer and the adjuster, any status
create or replace function app.booking_insurer_save(p_by uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  b bookings;
  a bookings;
  v_bill text;
  v_ins uuid;
  v_txt text;
begin
  if not (app.user_is_admin(p_by) or app.user_va_has(p_by, 'cs', 'finance')) then
    raise exception 'An Admin, customer service or finance records the insurer' using errcode = '42501';
  end if;
  select * into b from bookings where id::text = p ->> 'booking' or booking_number = p ->> 'booking' for update;
  if b.id is null then raise exception 'Booking not found' using errcode = 'P0002'; end if;
  if b.booking_type = 'owner' then raise exception 'An Owner Booking has no insurer' using errcode = '23514'; end if;
  if b.status in ('cancelled', 'declined', 'expired') then raise exception 'This booking is closed' using errcode = '23514'; end if;

  v_bill := coalesce(nullif(p ->> 'bill_to', ''), b.bill_to);
  if v_bill not in ('renter', 'insurer', 'split') then raise exception 'Bill to: renter, insurer or split' using errcode = '22023'; end if;
  v_ins := case when p ? 'insurer_id' then nullif(p ->> 'insurer_id', '')::uuid else b.insurer_id end;
  if v_bill <> 'renter' and v_ins is null then raise exception 'Choose the insurer' using errcode = '23514'; end if;
  v_txt := nullif(btrim(coalesce(p ->> 'adjuster_email', '')), '');
  if v_txt is not null and v_txt !~ '^[^@\s]+@[^@\s]+\.[^@\s]+$' then raise exception 'The adjuster''s email' using errcode = '22023'; end if;

  if nullif(btrim(coalesce(p ->> 'reason', '')), '') is not null then perform set_config('app.insurer_rate_reason', btrim(p ->> 'reason'), true); end if;
  update bookings set
    insurer_claim_number   = case when p ? 'claim_number' then nullif(btrim(p ->> 'claim_number'), '') else insurer_claim_number end,
    insurer_adjuster_name  = case when p ? 'adjuster_name' then nullif(btrim(p ->> 'adjuster_name'), '') else insurer_adjuster_name end,
    insurer_adjuster_email = case when p ? 'adjuster_email' then v_txt else insurer_adjuster_email end,
    insurer_adjuster_phone = case when p ? 'adjuster_phone' then nullif(btrim(p ->> 'adjuster_phone'), '') else insurer_adjuster_phone end,
    insurer_policy_number  = case when p ? 'policy_number' then nullif(btrim(p ->> 'policy_number'), '') else insurer_policy_number end,
    insurer_policy_province = case when p ? 'policy_province' then nullif(upper(btrim(p ->> 'policy_province')), '') else insurer_policy_province end,
    insurer_authorized_days = case when p ? 'authorized_days' then nullif(p ->> 'authorized_days', '')::integer else insurer_authorized_days end,
    insurer_authorized_until = case when p ? 'authorized_until' then nullif(p ->> 'authorized_until', '')::date else insurer_authorized_until end,
    insurer_authorized_daily_rate_cents = case when p ? 'authorized_daily_rate_cents' then nullif(p ->> 'authorized_daily_rate_cents', '')::bigint else insurer_authorized_daily_rate_cents end,
    insurer_id = case when v_bill = 'renter' and not (p ? 'insurer_id') then insurer_id else v_ins end,
    bill_to = v_bill
  where id = b.id
  returning * into a;

  -- who pays changed: the lines are priced again (the insurer's share, the renter's share)
  if a.bill_to is distinct from b.bill_to or a.insurer_id is distinct from b.insurer_id
     or a.insurer_authorized_daily_rate_cents is distinct from b.insurer_authorized_daily_rate_cents then
    perform app.sync_booking_price(b.id);
  end if;

  insert into audit_log (actor_user_id, action, entity_table, entity_id, before, after)
  values (p_by, 'booking_insurer_save', 'bookings', b.id::text,
          jsonb_build_object('bill_to', b.bill_to, 'insurer_id', b.insurer_id, 'claim_number', b.insurer_claim_number, 'adjuster_name', b.insurer_adjuster_name,
                             'adjuster_email', b.insurer_adjuster_email, 'adjuster_phone', b.insurer_adjuster_phone, 'policy_number', b.insurer_policy_number),
          jsonb_build_object('bill_to', a.bill_to, 'insurer_id', a.insurer_id, 'claim_number', a.insurer_claim_number, 'adjuster_name', a.insurer_adjuster_name,
                             'adjuster_email', a.insurer_adjuster_email, 'adjuster_phone', a.insurer_adjuster_phone, 'policy_number', a.insurer_policy_number,
                             'reason', nullif(btrim(coalesce(p ->> 'reason', '')), '')));
  return jsonb_build_object('ok', true, 'bill_to', a.bill_to, 'insurer_id', a.insurer_id);
end $$;

-- ================================================================ 2. staff upload a renter's documents
-- The insurance policy or pink card, an insurer's authorization or claim letter, or another document, uploaded by staff
-- from the booking (the licence goes through 0130's staff_licence_register). A proof of coverage is linked to the
-- booking's coverage record, made here when there is none (with no coverage option chosen yet, option 1, OPCF 27):
-- nothing is refused for a missing coverage option, which is how an insurer-billed rental usually starts.
create or replace function app.staff_document_register(p_by uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  b bookings;
  cp coverage_proofs;
  v_kind text := p ->> 'kind';
  v_doc uuid;
  v_opt smallint;
begin
  if not (app.user_may_handover(p_by) or app.user_is_admin(p_by) or app.user_va_has(p_by, 'cs', 'finance')) then
    raise exception 'Not permitted' using errcode = '42501';
  end if;
  if v_kind not in ('coverage_proof', 'insurer_document', 'other') then raise exception 'Choose what the document is' using errcode = '22023'; end if;
  if nullif(p ->> 'path', '') is null then raise exception 'An upload needs the key of its file in private storage' using errcode = '22023'; end if;
  select * into b from bookings where id::text = p ->> 'booking' or booking_number = p ->> 'booking' for update;
  if b.id is null then raise exception 'Booking not found' using errcode = 'P0002'; end if;

  insert into documents (kind, title, storage_bucket, storage_path, mime_type, sha256, retention, uploaded_by, renter_id, booking_id)
  values ((case v_kind when 'coverage_proof' then 'coverage_proof' when 'insurer_document' then 'insurer_confirmation' else 'other' end)::document_kind,
          coalesce(nullif(btrim(p ->> 'title'), ''), case v_kind when 'coverage_proof' then 'Proof of coverage (uploaded by staff)'
                                                               when 'insurer_document' then 'Insurer document (uploaded by staff)' else 'Document (uploaded by staff)' end),
          'documents', p ->> 'path', nullif(p ->> 'mime', ''), nullif(p ->> 'sha256', ''), 'records_7y', p_by, b.renter_id, b.id)
  returning id into v_doc;

  if v_kind = 'coverage_proof' and b.booking_type <> 'owner' then
    select * into cp from coverage_proofs where booking_id = b.id and status in ('submitted', 'confirmed') order by created_at desc limit 1;
    if cp.id is null then
      v_opt := coalesce(b.coverage_option, nullif(p ->> 'coverage_option', '')::smallint, 1);
      insert into coverage_proofs (booking_id, coverage_option, status, insurer_name, policy_number, policy_expiry, proof_document_id, submitted_by, submitted_at)
      values (b.id, v_opt, 'submitted', nullif(btrim(p ->> 'insurer_name'), ''), nullif(btrim(p ->> 'policy_number'), ''), nullif(p ->> 'policy_expiry', '')::date, v_doc, p_by, now())
      returning * into cp;
    else
      update coverage_proofs set proof_document_id = coalesce(proof_document_id, v_doc),
             insurer_name = coalesce(nullif(btrim(p ->> 'insurer_name'), ''), insurer_name), policy_number = coalesce(nullif(btrim(p ->> 'policy_number'), ''), policy_number),
             policy_expiry = coalesce(nullif(p ->> 'policy_expiry', '')::date, policy_expiry)
       where id = cp.id;
    end if;
    insert into verification_uploads (booking_id, driver_id, kind, document_id, identity_verification_id, coverage_proof_id, uploaded_by)
    values (b.id, null, 'coverage_proof', v_doc, null, cp.id, p_by);
  end if;

  insert into audit_log (actor_user_id, action, entity_table, entity_id, after)
  values (p_by, 'staff_document_upload', 'bookings', b.id::text, jsonb_build_object('kind', v_kind, 'document_id', v_doc));
  return jsonb_build_object('ok', true, 'document_id', v_doc);
end $$;

-- ================================================================ 3. signing without confirming the account first
-- A renter signs the rental agreement without first confirming their email or phone (it slowed the desk down). The
-- signature itself still needs the one-time code, the initials, the consents and the drawn signature (0154's e-sign).
-- Uploading documents no longer waits for it either. Accepting an offer and paying still do.
create or replace function app.account_gate(p_user uuid, p_step text) returns jsonb
language plpgsql stable security definer set search_path = public, app as $$
declare
  u users;
  s program_settings := app.settings();
begin
  if p_step not in ('accept', 'sign', 'pay') then raise exception 'Unknown step %', p_step using errcode = '22023'; end if;
  select * into u from users where id = p_user;
  if u.id is null then return jsonb_build_object('ok', false, 'reason', 'unconfirmed'); end if;
  if p_step <> 'sign' and s.signin_confirm_required and not app.account_confirmed(u.id) then
    return jsonb_build_object('ok', false, 'reason', 'unconfirmed', 'email', u.email, 'phone', u.phone, 'by_phone', s.signin_confirm_by_phone);
  end if;
  if p_step = 'pay' and nullif(btrim(coalesce(u.email, '')), '') is null then
    return jsonb_build_object('ok', false, 'reason', 'email_needed', 'phone', u.phone);
  end if;
  return jsonb_build_object('ok', true, 'email', u.email, 'phone', u.phone);
end $$;

create or replace function app.capture_gate(p_user uuid, p_what text) returns void
language plpgsql stable security definer set search_path = public, app as $$
begin
  if p_what in ('sign', 'upload documents') then return; end if;
  if p_user is not null and app.capture_unconfirmed(p_user) then
    raise exception 'Confirm your email first: open the link in the email "Continue your request" we sent you. Then you can %.', p_what
      using errcode = '42501';
  end if;
end $$;

-- ================================================================ 4. editing the agreement by hand
-- The Agreement card shows every field of the agreement with its value, not only what is missing; staff correct any of
-- them (agreement_fill), and an Admin also the renter's legal name. A change after signing makes a new version to sign
-- (0154's plan), as before.
create or replace function app.agreement_current(p_booking uuid) returns jsonb
language sql stable security definer set search_path = public, app as $$
  select jsonb_build_object(
    'renter', (select jsonb_build_object('legal_name', r.legal_name, 'date_of_birth', r.date_of_birth, 'mobile', r.mobile, 'address_line1', r.address_line1,
                 'address_line2', r.address_line2, 'city', r.city, 'province', r.province, 'postal_code', r.postal_code) from renters r where r.id = b.renter_id),
    'drivers', coalesce((select jsonb_agg(jsonb_build_object('driver_id', bd.driver_id, 'role', bd.role, 'name', bd.full_name,
                 'licence_number', coalesce(bd.licence_number, dv.licence_number), 'licence_issuer', coalesce(bd.licence_issuer, dv.licence_issuer),
                 'licence_expiry', coalesce(bd.licence_expiry, dv.licence_expiry), 'licence_class', coalesce(bd.licence_class, dv.licence_class)) order by bd.role desc, bd.full_name)
                 from booking_drivers bd join drivers dv on dv.id = bd.driver_id where bd.booking_id = b.id), '[]'::jsonb),
    'vehicle', (select jsonb_build_object('plate', v.plate, 'vin', v.vin, 'colour', v.colour, 'fleet_number', v.fleet_number) from vehicles v where v.id = b.vehicle_id),
    'coverage', (select jsonb_build_object('option', c.coverage_option, 'insurer_name', c.insurer_name, 'policy_number', c.policy_number, 'policy_expiry', c.policy_expiry,
                 'card_issuer', c.card_issuer, 'card_last4', c.card_last4, 'coverage_provider', c.coverage_provider, 'status', c.status)
                 from coverage_proofs c where c.booking_id = b.id order by c.created_at desc limit 1),
    'insurer', case when b.bill_to <> 'renter' then jsonb_build_object('claim_number', b.insurer_claim_number, 'adjuster_name', b.insurer_adjuster_name,
                 'adjuster_phone', b.insurer_adjuster_phone, 'policy_number', b.insurer_policy_number, 'policy_province', b.insurer_policy_province,
                 'policy_expiry', b.insurer_policy_expiry, 'insured_vehicle', b.insured_vehicle) end)
    from bookings b where b.id = p_booking
$$;

alter function app.agreement_state(uuid, uuid) rename to agreement_state_pre0183;
create or replace function app.agreement_state(p_by uuid, p_booking uuid) returns jsonb
language sql stable security definer set search_path = public, app as $$
  select app.agreement_state_pre0183(p_by, p_booking) || jsonb_build_object('current', app.agreement_current(p_booking))
$$;

-- the renter's legal name, by an Admin (it is checked against the typed signature)
alter function app.agreement_fill(uuid, jsonb) rename to agreement_fill_pre0183;
create or replace function app.agreement_fill(p_by uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  v_name text := nullif(btrim(coalesce(p #>> '{renter,legal_name}', '')), '');
  v_old text;
  v_renter uuid;
begin
  if v_name is not null then
    if not app.user_is_admin(p_by) then raise exception 'An Admin corrects the renter''s legal name' using errcode = '42501'; end if;
    if length(v_name) > 120 then raise exception 'The legal name, up to 120 characters' using errcode = '22023'; end if;
    select b.renter_id, r.legal_name into v_renter, v_old from bookings b join renters r on r.id = b.renter_id where b.id = (p ->> 'booking')::uuid;
    if v_renter is not null and v_old is distinct from v_name then
      update renters set legal_name = v_name where id = v_renter;
      update booking_drivers set full_name = v_name where booking_id = (p ->> 'booking')::uuid and role = 'renter';
      insert into audit_log (actor_user_id, action, entity_table, entity_id, before, after)
      values (p_by, 'agreement_legal_name', 'renters', v_renter::text, jsonb_build_object('legal_name', v_old), jsonb_build_object('legal_name', v_name));
    end if;
  end if;
  return app.agreement_fill_pre0183(p_by, jsonb_set(p, '{renter}', coalesce(p -> 'renter', '{}'::jsonb) - 'legal_name'));
end $$;

-- ================================================================ the door
alter function app.door(uuid, text, text, text, jsonb) rename to door_pre0183;
create or replace function app.door(p_user uuid, p_aal text, p_call text, p_name text, p jsonb default '{}'::jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  p_ jsonb := coalesce(p, '{}'::jsonb) - '_va';
begin
  if p_call in ('admin_do', 'va_do', 'ops_do') and p_name in ('booking_insurer_save', 'staff_document_register') then
    if coalesce(p, '{}'::jsonb) ? '_va' then perform set_config('app.va_active', coalesce(p ->> '_va', ''), true); end if;
    perform app.door_begin(p_user, p_aal);
    return case p_name
      when 'booking_insurer_save' then app.booking_insurer_save(p_user, p_)
      else app.staff_document_register(p_user, p_) end;
  end if;
  return app.door_pre0183(p_user, p_aal, p_call, p_name, p);
end $$;
select pg_temp.copy_grants('app.door(uuid, text, text, text, jsonb)'::regprocedure, 'app.door_pre0183(uuid, text, text, text, jsonb)'::regprocedure);

-- ================================================================ privileges
do $$
declare
  f record;
begin
  for f in
    select p.oid::regprocedure as sig from pg_proc p join pg_namespace n on n.oid = p.pronamespace
     where n.nspname = 'app' and p.proname = any (array['booking_insurer_save', 'staff_document_register', 'agreement_current', 'agreement_state', 'agreement_state_pre0183',
             'agreement_fill', 'agreement_fill_pre0183', 'door_pre0183'])
  loop
    execute format('revoke all on function %s from public, anon, authenticated', f.sig);
    execute format('grant execute on function %s to service_role', f.sig);
  end loop;
end $$;

-- ================================================================ 5. a wrong phone number while signing
-- A renter who typed a wrong mobile never got the signing code and had no way to change it. The signing page now takes
-- a corrected number (the signed-in renter, or the staff member collecting the signature in person): the session sends
-- its next code there, and the renter's profile keeps the corrected number. A code already sent stops working.
create or replace function public.server_esign_set_mobile(p_session uuid, p_mobile text, p_by uuid) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  s esign_sessions;
  v_old text;
  v_renter uuid;
begin
  if p_mobile is null or p_mobile !~ '^\+1[2-9][0-9]{9}$' then raise exception 'Enter a Canadian or US mobile number' using errcode = '22023'; end if;
  select * into s from esign_sessions where id = p_session for update;
  if s.id is null or s.signed_at is not null then raise exception 'This signing has ended: reload the page' using errcode = 'P0002'; end if;
  if s.otp_verified_at is not null then raise exception 'The code is already confirmed' using errcode = '23514'; end if;
  v_old := s.mobile;
  update esign_sessions set mobile = p_mobile, otp_channel = null, otp_to = null, otp_hash = null, otp_expires_at = null, otp_attempts = 0, updated_at = now()
   where id = s.id;
  if s.signer_role = 'renter' and s.booking_id is not null then
    select renter_id into v_renter from bookings where id = s.booking_id;
    update renters set mobile = p_mobile where id = v_renter;
  end if;
  if s.driver_id is not null then update drivers set mobile = p_mobile where id = s.driver_id; end if;
  insert into audit_log (actor_user_id, action, entity_table, entity_id, before, after)
  values (p_by, 'esign_mobile_corrected', 'esign_sessions', s.id::text, jsonb_build_object('mobile', v_old), jsonb_build_object('mobile', p_mobile));
  return app.esign_view(s.id);
end $$;
revoke all on function public.server_esign_set_mobile(uuid, text, uuid) from public, anon, authenticated;
grant execute on function public.server_esign_set_mobile(uuid, text, uuid) to service_role;
