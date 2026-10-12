-- 0028: what the renter portal needs (web/src/app/account).
--
-- Two kinds of function, following 0019 section 1:
--   * Reads for a signed-in renter, opened to `authenticated` and SECURITY INVOKER, so every row
--     they return passes row-level security (renter_bookings, booking_offers, booking_line_items,
--     payments, booking_drivers, rental_agreements and their signers, documents, ...). The one
--     helper that reads a table renters cannot read (the request as sent, bookings.request_details)
--     is a definer that first checks app.is_my_booking().
--   * Server wrappers for the signing, payment, upload and profile functions of 0019, granted to
--     service_role only. Each renter action checks that p_by is the renter of the booking before it
--     calls the app function, so they cannot be used to act for somebody else.
-- Nothing here changes a table, a policy or an existing function. Notes: docs/changes/0028_renter_portal.md.

-- ------------------------------------------------------------------ reads for the signed-in renter

-- The request as sent, without dates of birth or other people's contact details (already removed
-- by submit_booking_request), plus the requested car's public name.
create or replace function app.my_request_snapshot(p_booking uuid) returns jsonb
language plpgsql stable security definer set search_path = public, app as $$
declare
  b bookings;
begin
  if not coalesce(app.is_my_booking(p_booking), false) then
    raise exception 'Not your booking' using errcode = '42501';
  end if;
  select * into b from bookings where id = p_booking;
  return coalesce(b.request_details, '{}'::jsonb) - 'drivers'
    || jsonb_build_object(
         'vehicle', (select jsonb_build_object('vehicle_id', v.id, 'year', v.year, 'make', v.make, 'model', v.model)
                       from vehicles v where v.id = coalesce((b.request_details ->> 'vehicle_id')::uuid, b.vehicle_id)),
         'drivers', coalesce((select jsonb_agg(jsonb_build_object('role', d ->> 'role', 'full_name', d ->> 'full_name'))
                                from jsonb_array_elements(coalesce(b.request_details -> 'drivers', '[]'::jsonb)) d), '[]'::jsonb));
end $$;

create or replace function public.my_bookings() returns setof jsonb
language sql stable security invoker set search_path = public, app as $$
  select to_jsonb(rb) || jsonb_build_object('slug', l.slug)
    from renter_bookings rb
    left join public_vehicle_listings l on l.vehicle_id = rb.vehicle_id
   order by rb.pickup_at desc
$$;

create or replace function public.my_booking(p_number text) returns jsonb
language plpgsql stable security invoker set search_path = public, app as $$
declare
  rb record;
  v_agreement jsonb;
begin
  select * into rb from renter_bookings where booking_number = p_number;
  if rb.id is null then return null; end if;

  select jsonb_build_object('id', a.id, 'status', a.status, 'agreement_number', a.agreement_number, 'offer_version', a.offer_version,
                            'template_version', a.template_version, 'document_id', a.document_id, 'document_sha256', a.document_sha256,
                            'signature_request_id', a.signature_request_id, 'renter_signed_at', a.renter_signed_at,
                            'countersigner_name', a.countersigner_name, 'opened_at', a.opened_at, 'completed_at', a.completed_at,
                            'signed_document_id', (select s.signed_document_id from signature_requests s where s.id = a.signature_request_id),
                            'signers', coalesce((select jsonb_agg(jsonb_build_object('id', g.id, 'role', g.signer_role, 'name', g.signer_name,
                                                   'booking_driver_id', g.booking_driver_id, 'signed_at', g.signed_at,
                                                   'required_before_payment', g.required_before_payment) order by g.signer_role desc, g.signer_name)
                                                   from rental_agreement_signers g where g.agreement_id = a.id), '[]'::jsonb))
    into v_agreement
    from rental_agreements a
   where a.booking_id = rb.id and a.status in ('open', 'signed', 'completed')
   order by a.opened_at desc limit 1;

  return to_jsonb(rb)
    || jsonb_build_object(
      'slug', (select l.slug from public_vehicle_listings l where l.vehicle_id = rb.vehicle_id),
      'request', app.my_request_snapshot(rb.id),
      'offers', coalesce((select jsonb_agg(jsonb_build_object(
                   'version', o.version, 'status', o.status, 'sent_at', o.sent_at, 'expires_at', o.expires_at, 'message', o.message,
                   'vehicle_id', o.vehicle_id, 'pickup_at', o.pickup_at, 'return_at', o.return_at, 'billable_days', o.billable_days,
                   'rental_charge_cents', o.rental_charge_cents, 'discount_cents', o.discount_cents, 'deposit_cents', o.deposit_cents,
                   'subtotal_cents', o.subtotal_cents, 'hst_cents', o.hst_cents, 'total_cents', o.total_cents,
                   'insurer_share_cents', o.insurer_share_cents, 'renter_due_cents', o.renter_due_cents, 'terms', o.terms,
                   'line_items', o.line_items, 'responded_at', o.responded_at, 'response_note', o.response_note,
                   'vehicle', (select jsonb_build_object('slug', l.slug, 'year', l.year, 'make', l.make, 'model', l.model)
                                 from public_vehicle_listings l where l.vehicle_id = o.vehicle_id)) order by o.version)
                   from booking_offers o where o.booking_id = rb.id), '[]'::jsonb),
      'lines', coalesce((select jsonb_agg(jsonb_build_object('id', li.id, 'charge_type', li.charge_type, 'description', li.description,
                   'quantity', li.quantity, 'unit_amount_cents', li.unit_amount_cents, 'amount_cents', li.amount_cents, 'hst_cents', li.hst_cents,
                   'stage', li.stage, 'payment_id', li.payment_id, 'created_at', li.created_at) order by li.created_at, li.charge_type)
                   from booking_line_items li where li.booking_id = rb.id), '[]'::jsonb),
      'payments', coalesce((select jsonb_agg(jsonb_build_object('id', p.id, 'purpose', p.purpose, 'kind', p.kind, 'amount_cents', p.amount_cents,
                   'status', p.status, 'card_brand', p.card_brand, 'card_last4', p.card_last4, 'processed_at', p.processed_at,
                   'created_at', p.created_at) order by p.created_at)
                   from payments p where p.booking_id = rb.id), '[]'::jsonb),
      'drivers', coalesce((select jsonb_agg(jsonb_build_object('id', d.id, 'driver_id', d.driver_id, 'role', d.role, 'full_name', d.full_name,
                   'licence_class', d.licence_class, 'licence_issuer', d.licence_issuer, 'licence_expiry', d.licence_expiry,
                   'has_licence_number', d.licence_number is not null, 'age_band', d.age_band,
                   'identity_verified_on', d.identity_verified_on, 'accepted_at', d.accepted_at) order by d.role desc, d.full_name)
                   from booking_drivers d where d.booking_id = rb.id), '[]'::jsonb),
      'agreement', v_agreement,
      'info_requests', coalesce((select jsonb_agg(jsonb_build_object('id', q.id, 'question', q.question, 'asked_at', q.asked_at,
                   'reply_by', q.reply_by, 'status', q.status, 'reply', q.reply, 'replied_at', q.replied_at) order by q.asked_at)
                   from booking_info_requests q where q.booking_id = rb.id), '[]'::jsonb),
      'uploads', coalesce((select jsonb_agg(jsonb_build_object('id', u.id, 'driver_id', u.driver_id, 'kind', u.kind, 'status', u.status,
                   'reject_reason', u.reject_reason, 'document_id', u.document_id, 'uploaded_at', u.uploaded_at) order by u.uploaded_at)
                   from verification_uploads u where u.booking_id = rb.id and u.status <> 'replaced'), '[]'::jsonb),
      'documents', coalesce((select jsonb_agg(jsonb_build_object('id', dc.id, 'kind', dc.kind, 'title', dc.title, 'mime_type', dc.mime_type,
                   'created_at', dc.created_at, 'purge_after', dc.purge_after, 'purged', dc.purged_at is not null) order by dc.created_at)
                   from documents dc where dc.booking_id = rb.id), '[]'::jsonb),
      'change_requests', coalesce((select jsonb_agg(to_jsonb(c) - 'requested_by' - 'agreed_ip' - 'agreed_user_agent' order by c.created_at)
                   from booking_change_requests c where c.booking_id = rb.id), '[]'::jsonb),
      'extensions', coalesce((select jsonb_agg(jsonb_build_object('id', e.id, 'seq', e.seq, 'status', e.status, 'requested_at', e.requested_at,
                   'previous_return_at', e.previous_return_at, 'new_return_at', e.new_return_at, 'new_days', e.new_days,
                   'total_cents', e.total_cents, 'hst_cents', e.hst_cents, 'paid_at', e.paid_at, 'decline_reason', e.decline_reason,
                   'note', e.note) order by e.seq)
                   from booking_extensions e where e.booking_id = rb.id), '[]'::jsonb),
      'cancellation', (select to_jsonb(x) from booking_cancellations x where x.booking_id = rb.id order by x.received_at desc limit 1),
      'refunds', coalesce((select jsonb_agg(jsonb_build_object('id', r.id, 'amount_cents', r.amount_cents, 'status', r.status, 'created_at', r.created_at))
                   from refunds r where r.booking_id = rb.id), '[]'::jsonb),
      'statements', coalesce((select jsonb_agg(to_jsonb(s) order by s.id) from booking_statements s where s.booking_id = rb.id), '[]'::jsonb),
      'readiness', case when rb.status in ('confirmed', 'on_rent') then public.my_booking_readiness(rb.id) end);
end $$;

-- The profile: sign-in record, renter record, saved drivers and the Card on File (display fields only).
create or replace function public.my_profile() returns jsonb
language sql stable security invoker set search_path = public, app as $$
  select jsonb_build_object(
    'user', (select jsonb_build_object('id', u.id, 'email', u.email, 'phone', u.phone, 'full_name', u.full_name,
                                       'marketing_opt_in', u.marketing_opt_in, 'marketing_opt_in_at', u.marketing_opt_in_at)
               from users u where u.id = app.uid()),
    'renter', (select jsonb_build_object('id', r.id, 'legal_name', r.legal_name, 'mobile', r.mobile, 'email', r.email,
                                         'address_line1', r.address_line1, 'address_line2', r.address_line2, 'city', r.city,
                                         'province', r.province, 'postal_code', r.postal_code, 'country', r.country,
                                         'identity_status', r.identity_status)
                 from renters r where r.id = app.my_renter_id()),
    'drivers', coalesce((select jsonb_agg(jsonb_build_object('id', d.id, 'full_name', d.full_name, 'is_account_holder', d.is_account_holder,
                                                             'licence_class', d.licence_class, 'licence_issuer', d.licence_issuer,
                                                             'licence_expiry', d.licence_expiry, 'identity_status', d.identity_status)
                                           order by d.is_account_holder desc, d.full_name)
                           from drivers d where d.renter_id = app.my_renter_id()), '[]'::jsonb),
    'cards', coalesce((select jsonb_agg(jsonb_build_object('id', p.id, 'brand', p.card_brand, 'last4', p.card_last4, 'exp_month', p.exp_month,
                                                           'exp_year', p.exp_year, 'cardholder_name', p.cardholder_name) order by p.created_at desc)
                         from payment_methods p where p.renter_id = app.my_renter_id() and p.status = 'active'), '[]'::jsonb))
$$;

-- Every document the renter may read, across bookings (row-level security decides).
create or replace function public.my_documents() returns setof jsonb
language sql stable security invoker set search_path = public, app as $$
  select jsonb_build_object('id', d.id, 'kind', d.kind, 'title', d.title, 'mime_type', d.mime_type, 'created_at', d.created_at,
                            'purge_after', d.purge_after, 'purged', d.purged_at is not null,
                            'booking_number', (select rb.booking_number from renter_bookings rb where rb.id = d.booking_id))
    from documents d
   order by d.created_at desc
$$;

-- Where a document lives, only when row-level security lets the caller read its row. The server
-- signs a short-lived link only after this returns a row (13-security.md section 7).
create or replace function public.my_document(p_document uuid) returns jsonb
language sql stable security invoker set search_path = public, app as $$
  select jsonb_build_object('id', d.id, 'kind', d.kind, 'title', d.title, 'bucket', d.storage_bucket, 'path', d.storage_path,
                            'mime_type', d.mime_type, 'purged', d.purged_at is not null)
    from documents d where d.id = p_document
$$;

-- Notification centre (0018's app functions read the session's user).
create or replace function public.my_notifications(p_limit integer default 50, p_unread_only boolean default false) returns setof jsonb
language sql stable security invoker set search_path = public, app as $$
  select jsonb_build_object('id', n.id, 'code', n.code, 'title', n.title, 'body', n.body, 'url', n.url, 'created_at', n.created_at, 'read_at', n.read_at)
    from app.my_notifications(p_limit, p_unread_only) n
$$;

create or replace function public.mark_notifications_read(p_ids uuid[] default null) returns integer
language sql security invoker set search_path = public, app as $$ select app.mark_notifications_read(p_ids) $$;

create or replace function public.my_notification_preferences() returns setof jsonb
language sql stable security invoker set search_path = public, app as $$
  select to_jsonb(p) from app.my_notification_preferences() p
$$;

create or replace function public.set_notification_preference(p_code text, p_email boolean, p_in_app boolean) returns void
language sql security invoker set search_path = public, app as $$ select app.set_notification_preference(p_code, p_email, p_in_app) $$;

-- ------------------------------------------------------------------ server wrappers (service_role only)

-- Everything the agreement prints for a booking: the renter's own records, the drivers, the car
-- (plate and VIN, which a renter cannot read from the vehicle table), the lines, the Card on File and
-- CarmaCars' contact details. For the renter of the booking or staff.
create or replace function public.server_agreement_facts(p_booking uuid, p_by uuid) returns jsonb
language plpgsql stable security definer set search_path = public, app as $$
declare
  b bookings;
  s program_settings := app.settings();
  ss site_settings;
begin
  select * into b from bookings where id = p_booking;
  if b.id is null then raise exception 'Booking % not found', p_booking using errcode = 'P0002'; end if;
  if p_by is null or not (coalesce(app.is_booking_renter(p_booking, p_by), false) or app.user_is_staff(p_by)) then
    raise exception 'Only the renter of this booking, or staff, reads its agreement' using errcode = '42501';
  end if;
  select * into ss from site_settings limit 1;
  return jsonb_build_object(
    'booking', jsonb_build_object('id', b.id, 'booking_number', b.booking_number, 'agreement_number', b.agreement_number,
      'booking_type', b.booking_type, 'status', b.status, 'booked_at', b.booked_at, 'requested_at', b.requested_at,
      'pickup_at', b.pickup_at, 'return_at', b.return_at, 'pickup_place', b.pickup_place, 'return_place', b.return_place,
      'pickup_method', b.pickup_method, 'return_method', b.return_method, 'billable_days', b.billable_days,
      'rate_applied', b.rate_applied, 'daily_days', b.daily_days, 'weekend_days', b.weekend_days,
      'daily_rate_cents', b.daily_rate_cents, 'weekend_rate_cents', b.weekend_rate_cents, 'weekly_rate_cents', b.weekly_rate_cents,
      'monthly_rate_cents', b.monthly_rate_cents, 'rental_charge_cents', b.rental_charge_cents,
      'km_allowance_per_day', b.km_allowance_per_day, 'km_allowance_total', b.km_allowance_total, 'overage_cents_per_km', b.overage_cents_per_km,
      'deposit_cents', b.deposit_cents, 'deductible_cents', b.deductible_cents, 'coverage_option', b.coverage_option,
      'subtotal_at_booking_cents', b.subtotal_at_booking_cents, 'hst_at_booking_cents', b.hst_at_booking_cents,
      'total_due_at_booking_cents', b.total_due_at_booking_cents, 'renter_due_at_booking_cents', b.renter_due_at_booking_cents,
      'offer_approved_version', b.offer_approved_version, 'offer_approved_at', b.offer_approved_at,
      'renews_booking_id', b.renews_booking_id),
    'renter', (select jsonb_build_object('legal_name', r.legal_name, 'date_of_birth', r.date_of_birth, 'mobile', r.mobile,
                 'email', coalesce(r.email, (select u.email from users u where u.id = r.user_id)),
                 'address_line1', r.address_line1, 'address_line2', r.address_line2, 'city', r.city, 'province', r.province,
                 'postal_code', r.postal_code, 'country', r.country)
                 from renters r where r.id = b.renter_id),
    'drivers', coalesce((select jsonb_agg(jsonb_build_object('id', d.id, 'driver_id', d.driver_id, 'role', d.role, 'full_name', d.full_name,
                 'date_of_birth', d.date_of_birth, 'licence_number', coalesce(d.licence_number, dv.licence_number),
                 'licence_class', coalesce(d.licence_class, dv.licence_class), 'licence_issuer', coalesce(d.licence_issuer, dv.licence_issuer),
                 'licence_expiry', coalesce(d.licence_expiry, dv.licence_expiry), 'identity_method', d.identity_method,
                 'identity_verified_on', d.identity_verified_on) order by d.role desc, d.full_name)
                 from booking_drivers d join drivers dv on dv.id = d.driver_id where d.booking_id = p_booking), '[]'::jsonb),
    'vehicle', (select jsonb_build_object('year', v.year, 'make', v.make, 'model', v.model, 'trim', v.trim, 'colour', v.colour,
                 'fuel', v.fuel, 'plate', v.plate, 'vin', v.vin) from vehicles v where v.id = b.vehicle_id),
    'lines', coalesce((select jsonb_agg(jsonb_build_object('charge_type', li.charge_type, 'description', li.description,
                 'amount_cents', li.amount_cents, 'hst_cents', li.hst_cents, 'stage', li.stage) order by li.created_at, li.charge_type)
                 from booking_line_items li where li.booking_id = p_booking and li.charged_to_renter and li.voided_at is null
                   and li.stage = 'booking'), '[]'::jsonb),
    'card', (select jsonb_build_object('brand', pm.card_brand, 'last4', pm.card_last4, 'cardholder_name', pm.cardholder_name)
               from payment_methods pm where pm.id = b.card_on_file_id),
    'coverage', (select jsonb_build_object('coverage_option', c.coverage_option, 'insurer_name', c.insurer_name, 'policy_number', c.policy_number,
                   'policy_expiry', c.policy_expiry, 'card_issuer', c.card_issuer, 'card_last4', c.card_last4, 'status', c.status)
                   from coverage_proofs c where c.booking_id = p_booking order by c.created_at desc limit 1),
    'company', jsonb_build_object('legal_name', s.company_legal_name, 'trade_name', s.company_trade_name, 'email', s.company_email,
                 'phone', coalesce(ss.phone_display, s.company_phone), 'address', coalesce(s.company_address, ss.mailing_address),
                 'incident_line', coalesce(ss.roadside_phone_display, s.incident_line_phone), 'deductible_cents', s.deductible_cents));
end $$;

-- Everything the signed copy prints: the agreement, its document and each signature record.
create or replace function public.server_signing_record(p_booking uuid) returns jsonb
language sql stable security definer set search_path = public, app as $$
  select jsonb_build_object('agreement_id', a.id, 'agreement_number', a.agreement_number, 'status', a.status,
           'template_version', a.template_version, 'document_sha256', a.document_sha256, 'signature_request_id', a.signature_request_id,
           'offer_version', a.offer_version,
           'document', (select jsonb_build_object('bucket', d.storage_bucket, 'path', d.storage_path) from documents d where d.id = a.document_id),
           'signed_document_id', (select s.signed_document_id from signature_requests s where s.id = a.signature_request_id),
           'records', coalesce((select jsonb_agg(jsonb_build_object('signer_role', r.signer_role, 'signer_name', r.signer_name, 'method', r.method,
                          'signed_at', r.signed_at, 'ip_address', host(r.ip_address), 'user_agent', r.user_agent,
                          'provider_signature', r.provider_signature, 'typed_name', r.typed_name) order by r.signed_at)
                          from signature_records r where r.signature_request_id = a.signature_request_id and r.status = 'signed'), '[]'::jsonb))
    from rental_agreements a
   where a.booking_id = p_booking and a.status in ('open', 'signed', 'completed')
   order by a.opened_at desc limit 1
$$;

create or replace function public.renter_open_agreement(p_booking uuid, p_by uuid, p_template_version text, p_document_sha256 text,
                                                        p_storage_path text) returns uuid
language plpgsql security invoker set search_path = public, app as $$
begin
  perform app.assert_booking_renter(p_booking, p_by);
  return app.open_rental_agreement(p_booking, p_by, p_template_version, p_document_sha256, p_storage_path, 'agreements');
end $$;

-- The renter signs the agreement open for the approved offer of their booking.
create or replace function public.renter_sign_agreement(p_booking uuid, p_by uuid, p_consent_text text, p_document_sha256 text, p_consents jsonb,
                                                        p_typed_name text default null, p_drawn_signature text default null,
                                                        p_ip inet default null, p_user_agent text default null)
returns uuid
language plpgsql security invoker set search_path = public, app as $$
declare
  v_req uuid;
  v_signer uuid;
begin
  perform app.assert_booking_renter(p_booking, p_by);
  select a.signature_request_id, g.id into v_req, v_signer
    from rental_agreements a join rental_agreement_signers g on g.agreement_id = a.id and g.signer_role = 'renter'
   where a.booking_id = p_booking and a.status = 'open'
   order by a.opened_at desc limit 1;
  if v_req is null then
    raise exception 'There is no agreement waiting for your signature on this booking' using errcode = '23514';
  end if;
  return app.record_signature(v_req, v_signer, p_typed_name, p_drawn_signature, p_ip, p_user_agent, p_consent_text, p_document_sha256, p_consents);
end $$;

-- An additional driver's signing link carries their signer id, signed by the server. What the link page shows.
create or replace function public.driver_signing(p_signer uuid) returns jsonb
language sql stable security definer set search_path = public, app as $$
  select jsonb_build_object('signer_id', g.id, 'signer_name', g.signer_name, 'signed_at', g.signed_at, 'signer_role', g.signer_role,
           'agreement_status', a.status, 'agreement_number', a.agreement_number, 'document_sha256', a.document_sha256,
           'template_version', a.template_version, 'booking_id', b.id, 'booking_number', b.booking_number, 'booking_status', b.status,
           'document', (select jsonb_build_object('id', d.id, 'bucket', d.storage_bucket, 'path', d.storage_path) from documents d where d.id = a.document_id))
    from rental_agreement_signers g
    join rental_agreements a on a.id = g.agreement_id
    join bookings b on b.id = a.booking_id
   where g.id = p_signer
$$;

create or replace function public.driver_sign_agreement(p_signer uuid, p_consent_text text, p_document_sha256 text, p_consents jsonb,
                                                        p_typed_name text default null, p_drawn_signature text default null,
                                                        p_ip inet default null, p_user_agent text default null) returns uuid
language plpgsql security invoker set search_path = public, app as $$
declare
  g rental_agreement_signers;
begin
  select * into g from rental_agreement_signers where id = p_signer;
  if g.id is null or g.signer_role <> 'additional_driver' then
    raise exception 'This link is for an additional driver' using errcode = '42501';
  end if;
  return app.record_signature((select a.signature_request_id from rental_agreements a where a.id = g.agreement_id), g.id,
                              p_typed_name, p_drawn_signature, p_ip, p_user_agent, p_consent_text, p_document_sha256, p_consents);
end $$;

-- What the server checks before and after the card is authorized.
create or replace function public.server_booking_payment_facts(p_booking uuid) returns jsonb
language sql stable security definer set search_path = public, app as $$
  select jsonb_build_object('booking_id', b.id, 'booking_number', b.booking_number, 'status', b.status, 'booking_type', b.booking_type,
           'renter_due_at_booking_cents', b.renter_due_at_booking_cents, 'offer_approved_version', b.offer_approved_version,
           'current_offer_version', b.current_offer_version, 'vehicle_id', b.vehicle_id, 'pickup_at', b.pickup_at, 'return_at', b.return_at,
           'renter_id', b.renter_id, 'renter_user_id', r.user_id, 'legal_name', r.legal_name,
           'email', coalesce(r.email, (select u.email from users u where u.id = r.user_id)),
           'agreement_signed', exists (select 1 from rental_agreements a where a.booking_id = b.id and a.status in ('signed', 'completed')
                                         and a.offer_version is not distinct from b.offer_approved_version),
           'vehicle_free', app.vehicle_is_available(b.vehicle_id, b.pickup_at, b.return_at, b.id),
           'customer_id', (select s.processor_customer_id from payment_methods pm join payment_method_secrets s on s.payment_method_id = pm.id
                            where pm.renter_id = b.renter_id and s.processor_customer_id is not null order by pm.created_at desc limit 1),
           'card_on_file', (select jsonb_build_object('method_id', s.processor_method_id, 'customer_id', s.processor_customer_id,
                                                      'brand', pm.card_brand, 'last4', pm.card_last4)
                              from payment_methods pm join payment_method_secrets s on s.payment_method_id = pm.id where pm.id = b.card_on_file_id))
    from bookings b join renters r on r.id = b.renter_id
   where b.id = p_booking
$$;

create or replace function public.server_record_booking_payment(p_booking uuid, p_processor jsonb, p_amount_cents bigint, p_offer_version integer,
                                                                p_card jsonb, p_event_id text, p_by uuid) returns jsonb
language sql security invoker set search_path = public, app as $$
  select app.record_booking_payment(p_booking, p_processor, p_amount_cents, p_offer_version, p_card, p_event_id, p_by)
$$;

create or replace function public.server_booking_payment_capture_failed(p_booking uuid, p_processor jsonb, p_error text) returns void
language sql security invoker set search_path = public, app as $$ select app.booking_payment_capture_failed(p_booking, p_processor, p_error) $$;

create or replace function public.server_complete_signature_request(p_request uuid, p_signed_storage_path text, p_signed_sha256 text) returns uuid
language sql security invoker set search_path = public, app as $$
  select app.complete_signature_request(p_request, null, p_signed_storage_path, p_signed_sha256)
$$;

create or replace function public.server_webhook_event_claim(p_provider text, p_event_id text, p_event_type text default null,
                                                             p_booking uuid default null, p_summary jsonb default '{}')
returns jsonb
language sql security invoker set search_path = public, app as $$ select app.webhook_event_claim(p_provider, p_event_id, p_event_type, p_booking, p_summary) $$;

create or replace function public.server_webhook_event_finish(p_provider text, p_event_id text, p_result jsonb default null, p_error text default null) returns void
language sql security invoker set search_path = public, app as $$ select app.webhook_event_finish(p_provider, p_event_id, p_result, p_error) $$;

-- An approved extension and the Card on File it is charged to.
create or replace function public.server_extension_payment_facts(p_extension uuid, p_by uuid) returns jsonb
language plpgsql stable security definer set search_path = public, app as $$
declare
  e booking_extensions;
begin
  select * into e from booking_extensions where id = p_extension;
  if e.id is null then raise exception 'Extension not found' using errcode = 'P0002'; end if;
  perform app.assert_booking_renter(e.booking_id, p_by);
  return jsonb_build_object('extension_id', e.id, 'booking_id', e.booking_id, 'status', e.status, 'total_cents', e.total_cents,
           'previous_return_at', e.previous_return_at, 'new_return_at', e.new_return_at,
           'booking_number', (select b.booking_number from bookings b where b.id = e.booking_id),
           'card_on_file', (select jsonb_build_object('method_id', s.processor_method_id, 'customer_id', s.processor_customer_id,
                                                      'brand', pm.card_brand, 'last4', pm.card_last4)
                              from bookings b join payment_methods pm on pm.id = b.card_on_file_id
                              join payment_method_secrets s on s.payment_method_id = pm.id where b.id = e.booking_id));
end $$;

create or replace function public.server_confirm_extension_payment(p_extension uuid, p_processor jsonb, p_amount_cents bigint, p_by uuid) returns jsonb
language plpgsql security invoker set search_path = public, app as $$
begin
  perform app.assert_booking_renter((select e.booking_id from booking_extensions e where e.id = p_extension), p_by);
  return app.confirm_extension_payment(p_extension, p_processor, p_amount_cents, now(), p_by);
end $$;

-- Licence images, selfie and coverage proof, after the server has checked the file. Uploads are
-- limited to 60 an hour per user (13-security.md section 6).
create or replace function public.renter_register_upload(p_booking uuid, p_by uuid, p_kind text, p_storage_path text, p_sha256 text,
                                                         p_mime_type text, p_storage_bucket text, p_driver uuid default null,
                                                         p_details jsonb default null) returns jsonb
language plpgsql security invoker set search_path = public, app as $$
begin
  perform app.assert_booking_renter(p_booking, p_by);
  if not app.rate_limit('upload:user:' || p_by, 60, interval '1 hour') then
    return jsonb_build_object('ok', false, 'error', 'rate_limited');
  end if;
  return jsonb_build_object('ok', true, 'upload_id',
    app.register_verification_upload(p_booking, p_by, p_kind, p_driver, p_storage_path, p_sha256, p_mime_type, p_details, p_storage_bucket));
end $$;

-- "Your details" before signing (02 section 5 part A), and the profile page: the renter's address and
-- mobile, and licence details for the renter's own driver record. The legal name is not changed here.
create or replace function public.renter_save_details(p_by uuid, p_details jsonb, p_booking uuid default null) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  r renters;
  d jsonb := coalesce(p_details, '{}'::jsonb);
  v_driver uuid;
  v_expiry date;
  v_issuer text;
  v_number text;
begin
  select * into r from renters where user_id = p_by;
  if r.id is null then raise exception 'No renter record for this account' using errcode = '42501'; end if;
  if p_booking is not null then perform app.assert_booking_renter(p_booking, p_by); end if;

  if d ? 'address_line1' then
    if nullif(btrim(coalesce(d ->> 'address_line1', '')), '') is null or nullif(btrim(coalesce(d ->> 'city', '')), '') is null
       or nullif(btrim(coalesce(d ->> 'province', '')), '') is null or nullif(btrim(coalesce(d ->> 'postal_code', '')), '') is null
       or nullif(btrim(coalesce(d ->> 'country', '')), '') is null then
      raise exception 'Give the full home address: street, city, province or state, postal code and country' using errcode = '22023';
    end if;
    update renters set address_line1 = btrim(d ->> 'address_line1'), address_line2 = nullif(btrim(coalesce(d ->> 'address_line2', '')), ''),
                       city = btrim(d ->> 'city'), province = btrim(d ->> 'province'), postal_code = upper(btrim(d ->> 'postal_code')),
                       country = btrim(d ->> 'country'), updated_at = now()
     where id = r.id;
  end if;
  if d ? 'mobile' then
    if coalesce(d ->> 'mobile', '') !~ '^\+[1-9][0-9]{7,14}$' then
      raise exception 'Give the mobile number with its country code' using errcode = '22023';
    end if;
    update renters set mobile = d ->> 'mobile', updated_at = now() where id = r.id;
    update users set phone = d ->> 'mobile', updated_at = now() where id = p_by;
  end if;
  if d ? 'licence_number' then
    v_number := upper(regexp_replace(coalesce(d ->> 'licence_number', ''), '\s', '', 'g'));
    v_issuer := nullif(btrim(coalesce(d ->> 'licence_issuer', '')), '');
    v_expiry := nullif(d ->> 'licence_expiry', '')::date;
    if v_issuer is null or v_expiry is null then
      raise exception 'Give the licence number, who issued it and its expiry date' using errcode = '22023';
    end if;
    if v_issuer = 'ON' and v_number !~ '^[A-Z][0-9]{4}-?[0-9]{5}-?[0-9]{5}$' then
      raise exception 'An Ontario licence number looks like A1234-12345-12345' using errcode = '22023';
    end if;
    if v_issuer <> 'ON' and length(v_number) not between 5 and 25 then
      raise exception 'The licence number should be 5 to 25 characters' using errcode = '22023';
    end if;
    if v_expiry <= current_date then raise exception 'This licence has expired' using errcode = '23514'; end if;
    if p_booking is not null and v_expiry < (select app.local_date(b.return_at) from bookings b where b.id = p_booking) then
      raise exception 'The licence must be valid until the return date' using errcode = '23514';
    end if;
    select id into v_driver from drivers where renter_id = r.id and is_account_holder order by created_at limit 1;
    if v_driver is null then raise exception 'No driver record for this account' using errcode = 'P0002'; end if;
    update drivers set licence_number = v_number, licence_issuer = v_issuer, licence_expiry = v_expiry,
                       licence_class = coalesce(nullif(d ->> 'licence_class', ''), licence_class), updated_at = now()
     where id = v_driver;
    -- the booking's copy, while it is still before pickup
    update booking_drivers bd set licence_number = v_number, licence_issuer = v_issuer, licence_expiry = v_expiry,
                                  licence_class = coalesce(nullif(d ->> 'licence_class', ''), bd.licence_class)
      from bookings b
     where bd.driver_id = v_driver and b.id = bd.booking_id and b.status in ('requested', 'offered', 'pending_payment', 'confirmed');
  end if;
  return jsonb_build_object('ok', true);
end $$;

-- Marketing emails on or off from the notification page: express consent is recorded on turning on.
create or replace function public.renter_set_marketing(p_by uuid, p_opt_in boolean, p_text text default null, p_version text default null,
                                                       p_ip inet default null, p_user_agent text default null)
returns jsonb
language plpgsql security definer set search_path = public, app as $$
begin
  if not exists (select 1 from users where id = p_by) then raise exception 'Unknown user' using errcode = '42501'; end if;
  if p_opt_in then
    if nullif(btrim(coalesce(p_text, '')), '') is null or nullif(btrim(coalesce(p_version, '')), '') is null then
      raise exception 'Consent is recorded with the words shown and their version' using errcode = '22023';
    end if;
    insert into consents (user_id, consent_code, text_version, text_shown, ip_address, user_agent)
    values (p_by, 'marketing', p_version, p_text, p_ip, p_user_agent);
    update users set marketing_opt_in = true, marketing_opt_in_at = now(), marketing_unsubscribed_at = null, updated_at = now() where id = p_by;
  else
    update users set marketing_opt_in = false, marketing_unsubscribed_at = now(), updated_at = now() where id = p_by;
  end if;
  return jsonb_build_object('ok', true, 'marketing_opt_in', p_opt_in);
end $$;

-- ------------------------------------------------------------------ privileges
do $$
declare
  f text;
begin
  foreach f in array array[
    'app.my_request_snapshot(uuid)',
    'public.my_bookings()', 'public.my_booking(text)', 'public.my_profile()', 'public.my_documents()', 'public.my_document(uuid)',
    'public.my_notifications(integer, boolean)', 'public.mark_notifications_read(uuid[])', 'public.my_notification_preferences()',
    'public.set_notification_preference(text, boolean, boolean)',
    'public.server_agreement_facts(uuid, uuid)', 'public.server_signing_record(uuid)',
    'public.renter_open_agreement(uuid, uuid, text, text, text)',
    'public.renter_sign_agreement(uuid, uuid, text, text, jsonb, text, text, inet, text)',
    'public.driver_signing(uuid)', 'public.driver_sign_agreement(uuid, text, text, jsonb, text, text, inet, text)',
    'public.server_booking_payment_facts(uuid)',
    'public.server_record_booking_payment(uuid, jsonb, bigint, integer, jsonb, text, uuid)',
    'public.server_booking_payment_capture_failed(uuid, jsonb, text)',
    'public.server_complete_signature_request(uuid, text, text)',
    'public.server_webhook_event_claim(text, text, text, uuid, jsonb)', 'public.server_webhook_event_finish(text, text, jsonb, text)',
    'public.server_extension_payment_facts(uuid, uuid)', 'public.server_confirm_extension_payment(uuid, jsonb, bigint, uuid)',
    'public.renter_register_upload(uuid, uuid, text, text, text, text, text, uuid, jsonb)',
    'public.renter_save_details(uuid, jsonb, uuid)',
    'public.renter_set_marketing(uuid, boolean, text, text, inet, text)']
  loop
    execute format('revoke all on function %s from public, anon, authenticated', f);
    execute format('grant execute on function %s to service_role', f);
  end loop;
  -- the reads for a signed-in renter (row-level security applies)
  foreach f in array array[
    'app.my_request_snapshot(uuid)',
    'public.my_bookings()', 'public.my_booking(text)', 'public.my_profile()', 'public.my_documents()', 'public.my_document(uuid)',
    'public.my_notifications(integer, boolean)', 'public.mark_notifications_read(uuid[])', 'public.my_notification_preferences()',
    'public.set_notification_preference(text, boolean, boolean)']
  loop
    execute format('grant execute on function %s to authenticated', f);
  end loop;
end $$;
