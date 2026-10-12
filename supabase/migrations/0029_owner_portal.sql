-- 0029: what the owner onboarding wizard, the owner portal, owner agreement signing, owner invoice
-- payment and the first admin screens need (docs/changes/0029_owner_portal.md).
-- No table is added. Two check constraints gain 'cheque' (an offline payment); everything else is
-- functions: app.* holds the rules, public.* wraps them for the server (service_role) only.

-- Function bodies refer to functions defined further down; they are checked when called.
set local check_function_bodies = off;

-- ================================================================ offline payments may be cheques
alter table payments drop constraint if exists payments_method_check;
alter table payments add constraint payments_method_check
  check (method in ('card', 'pre_authorized_debit', 'e_transfer', 'bank_transfer', 'cheque'));
alter table owner_invoices drop constraint if exists owner_invoices_payment_method_check;
alter table owner_invoices add constraint owner_invoices_payment_method_check
  check (payment_method in ('pre_authorized_debit', 'card', 'e_transfer', 'bank_transfer', 'cheque'));

-- ================================================================ the wizard
-- The numbers the wizard shows: the standard grid (a starting point only), the Install Fee, HST,
-- and each onboarding method's third-party estimate (information only; the owner pays those).
create or replace function app.owner_program_facts() returns jsonb
language sql stable security definer set search_path = public, app as $$
  select jsonb_build_object(
    'install_fee_cents', (app.settings()).install_fee_cents,
    'hst_bps', (app.settings()).hst_bps,
    'late_fee_cents', (app.settings()).owner_late_fee_cents,
    'grid', (select coalesce(jsonb_agg(jsonb_build_object('min_vehicles', g.min_vehicles, 'max_vehicles', g.max_vehicles,
                    'insurance_fee_cents', g.insurance_fee_cents, 'tracker_fee_cents', g.tracker_fee_cents, 'revenue_share_bps', g.revenue_share_bps)
                    order by g.min_vehicles), '[]'::jsonb)
               from owner_fee_grid g
              where g.effective_from = (select max(x.effective_from) from owner_fee_grid x where x.effective_from <= app.today())),
    'methods', (select coalesce(jsonb_agg(jsonb_build_object('method', i.method, 'label', i.label, 'open_to', i.open_to,
                    'estimate_cents', i.estimate_cents, 'estimate_with_lien_cents', i.estimate_with_lien_cents, 'plus_tax', i.plus_tax,
                    'typical_items', i.typical_items) order by i.estimate_cents), '[]'::jsonb) from onboarding_method_info i))
$$;

-- The methods open to one vehicle (app.onboarding_options) as JSON, for a visitor's wizard.
create or replace function app.onboarding_options_json(p_held_by text, p_title_status text, p_mode text) returns jsonb
language sql stable security definer set search_path = public, app as $$
  select coalesce(jsonb_agg(to_jsonb(x)), '[]'::jsonb)
    from app.onboarding_options(p_held_by::owner_type, p_title_status::title_status, coalesce(nullif(p_mode, ''), 'managed')::management_mode) x
$$;

-- A VIN typed in the wizard: cleaned, whether it is already with CarmaCars (no detail about that
-- record), and the newest successful decode on file, so a VIN is decoded once.
create or replace function app.vin_lookup(p_vin text) returns jsonb
language sql stable security definer set search_path = public, app as $$
  with c as (select app.clean_vin(p_vin) as vin)
  select jsonb_build_object(
    'vin', c.vin, 'valid', c.vin is not null,
    'taken', c.vin is not null and exists (select 1 from vehicles v where upper(v.vin) = c.vin),
    'decode', (select jsonb_build_object('year', d.year, 'make', d.make, 'model', d.model, 'trim', d.trim, 'body_class', d.body_class,
                                         'fuel', d.fuel, 'drivetrain', d.drivetrain, 'transmission', d.transmission, 'doors', d.doors,
                                         'seats', d.seats, 'provider', d.provider)
                 from vin_decodes d where d.vin = c.vin and d.ok order by d.decoded_at desc limit 1))
  from c
$$;

-- What a VIN decoder answered, stored the way the listing worker stores it (complete_listing_job).
create or replace function app.record_vin_decode(p_vin text, p_provider text, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  v_vin text := app.clean_vin(p_vin);
  v_ok boolean;
  v_fuel fuel_type;
begin
  if v_vin is null then raise exception 'Enter the 17-character VIN' using errcode = '22023'; end if;
  p := coalesce(p, '{}'::jsonb);
  v_ok := coalesce((p ->> 'ok')::boolean, false) and nullif(p ->> 'year', '') is not null
          and nullif(p ->> 'make', '') is not null and nullif(p ->> 'model', '') is not null;
  begin
    v_fuel := nullif(p ->> 'fuel', '')::fuel_type;
  exception when invalid_text_representation then v_fuel := null;
  end;
  insert into vin_decodes (vin, provider, ok, error_code, raw, year, make, model, trim, body_class, fuel, drivetrain, transmission, doors, seats, engine)
  values (v_vin, coalesce(nullif(p_provider, ''), 'unknown'), v_ok, p ->> 'error_code', coalesce(p -> 'raw', '{}'::jsonb),
          case when v_ok then (p ->> 'year')::smallint end, nullif(p ->> 'make', ''), nullif(p ->> 'model', ''), nullif(p ->> 'trim', ''),
          nullif(p ->> 'body_class', ''), v_fuel, nullif(p ->> 'drivetrain', ''), nullif(p ->> 'transmission', ''),
          nullif(p ->> 'doors', '')::smallint, nullif(p ->> 'seats', '')::smallint, nullif(p ->> 'engine', ''));
  return app.vin_lookup(v_vin);
end $$;

-- Links sent by email (a draft's resume link, an invitation, a sign-in link for the owner portal)
-- go out through the outbox as the catalogue's account_sign_in_link.
create or replace function app.send_link_email(p_email text, p_name text, p_url text, p_expiry text, p_key text) returns bigint
language plpgsql security definer set search_path = public, app as $$
begin
  if coalesce(p_email, '') !~ '^[^@\s]+@[^@\s]+\.[^@\s]+$' then
    raise exception 'Enter the email address to send the link to' using errcode = '22023';
  end if;
  if coalesce(p_url, '') !~ '^https?://' then
    raise exception 'A link must be a full address' using errcode = '22023';
  end if;
  return app.emit_event('account_sign_in_link', 'user', null,
    jsonb_build_object('signer_email', lower(btrim(p_email)), 'signer_name', nullif(btrim(p_name), ''),
                       'sign_in_url', p_url, 'link_expiry', coalesce(nullif(p_expiry, ''), '24 hours')),
    'account_sign_in_link:' || coalesce(nullif(p_key, ''), md5(p_url)));
end $$;

-- ================================================================ the owner portal: reads
create or replace function app.owner_portal_home(p_by uuid) returns jsonb
language sql stable security definer set search_path = public, app as $$
  with o as (select * from owners where id = app.portal_owner_id(p_by))
  select jsonb_build_object(
    'owner', (select jsonb_build_object('id', o.id, 'owner_type', o.owner_type, 'legal_name', o.legal_name,
                'first_name', coalesce(o.first_name, split_part(o.legal_name, ' ', 1)), 'corporation_name', o.corporation_name,
                'corporation_number', o.corporation_number, 'email', o.email, 'phone', o.phone, 'hst_number', o.hst_number,
                'address_line1', o.address_line1, 'address_line2', o.address_line2, 'city', o.city, 'province', o.province,
                'postal_code', o.postal_code, 'country', o.country, 'signing_officer_name', o.signing_officer_name,
                'signing_officer_title', o.signing_officer_title, 'balance_carried_forward_cents', o.balance_carried_forward_cents,
                'missing', to_jsonb(app.owner_missing_fields(o.id)))),
    'vehicles', app.owner_portal_vehicles(p_by),
    'invoices', app.owner_portal_invoices(p_by),
    'statements', app.owner_portal_money(p_by) -> 'statements',
    'payouts', app.owner_portal_money(p_by) -> 'payouts',
    'signing', app.owner_signing_needed(o.id),
    'payment_methods', (select coalesce(jsonb_agg(jsonb_build_object('id', m.id, 'kind', m.kind, 'status', m.status,
                          'brand_or_bank', m.brand_or_bank, 'last4', m.last4, 'is_default', m.is_default, 'authorized_at', m.authorized_at)
                          order by m.created_at desc), '[]'::jsonb) from owner_payment_methods m where m.owner_id = o.id and m.status <> 'revoked'),
    'payout_accounts', (select coalesce(jsonb_agg(jsonb_build_object('id', a.id, 'method', a.method, 'account_last4', a.account_last4,
                          'institution_no', a.institution_no, 'e_transfer_email', a.e_transfer_email, 'is_current', a.is_current,
                          'verified_at', a.verified_at, 'submitted_at', a.created_at) order by a.created_at desc), '[]'::jsonb)
                          from owner_payout_accounts a where a.owner_id = o.id),
    'exits', (select coalesce(jsonb_agg(jsonb_build_object('id', e.id, 'vehicle_id', e.vehicle_id, 'status', e.status, 'exit_date', e.exit_date,
                'notice_ends_on', e.notice_ends_on, 'retransfer_fees_paid_by', e.retransfer_fees_paid_by)), '[]'::jsonb)
                from vehicle_exits e join vehicles v on v.id = e.vehicle_id where v.owner_id = o.id and e.withdrawn_at is null),
    'next_payout_date', app.payout_date(app.month_start(app.today())),
    'next_billing_date', case when extract(day from app.today()) <= 15 then app.billing_date(app.month_start(app.today()))
                              else app.billing_date((app.month_start(app.today()) + interval '1 month')::date) end)
  from o
$$;

-- Every issued invoice of the owner with its vehicle, and whether a payment is on its way.
create or replace function app.owner_portal_invoices(p_by uuid) returns jsonb
language sql stable security definer set search_path = public, app as $$
  select coalesce(jsonb_agg(jsonb_build_object('id', i.id, 'invoice_number', i.invoice_number, 'vehicle_id', i.vehicle_id,
           'vehicle_name', app.vehicle_name(i.vehicle_id), 'kind', i.kind, 'period_month', i.period_month, 'billing_date', i.billing_date,
           'retry_on', i.retry_on, 'status', i.status, 'fees_cents', i.fees_cents, 'hst_cents', i.hst_cents, 'late_fee_cents', i.late_fee_cents,
           'total_cents', i.total_cents, 'balance_cents', i.balance_cents, 'paid_at', i.paid_at, 'payment_method', i.payment_method,
           'pending', exists (select 1 from payments p where p.owner_invoice_id = i.id and p.status = 'pending'),
           'payable', i.status in ('issued', 'failed', 'in_arrears', 'partially_deducted') and i.balance_cents > 0
                      and not exists (select 1 from payments p where p.owner_invoice_id = i.id and p.status = 'pending'))
           order by i.billing_date desc, i.invoice_number desc), '[]'::jsonb)
    from owner_invoices i
   where i.owner_id = app.portal_owner_id(p_by) and i.status <> 'draft'
$$;

-- One invoice, with its lines and payments. Null when it is not this owner's (a 404 for the page).
create or replace function app.owner_invoice_view(p_invoice uuid) returns jsonb
language sql stable security definer set search_path = public, app as $$
  select jsonb_build_object('id', i.id, 'invoice_number', i.invoice_number, 'owner_id', i.owner_id, 'vehicle_id', i.vehicle_id,
    'vehicle_name', app.vehicle_name(i.vehicle_id), 'plate', v.plate, 'kind', i.kind, 'period_month', i.period_month,
    'days_billed', i.days_billed, 'days_in_month', i.days_in_month, 'billing_date', i.billing_date, 'retry_on', i.retry_on,
    'status', i.status, 'payment_method', i.payment_method, 'fees_cents', i.fees_cents, 'hst_cents', i.hst_cents,
    'late_fee_cents', i.late_fee_cents, 'total_cents', i.total_cents, 'paid_cents', i.paid_cents, 'deducted_cents', i.deducted_cents,
    'balance_cents', i.balance_cents, 'issued_at', i.issued_at, 'paid_at', i.paid_at,
    'owner_name', o.legal_name, 'owner_email', o.email, 'company_hst_number', (app.settings()).company_hst_number,
    'pending', exists (select 1 from payments p where p.owner_invoice_id = i.id and p.status = 'pending'),
    'payable', i.status in ('issued', 'failed', 'in_arrears', 'partially_deducted') and i.balance_cents > 0
               and not exists (select 1 from payments p where p.owner_invoice_id = i.id and p.status = 'pending'),
    'lines', (select coalesce(jsonb_agg(jsonb_build_object('kind', l.kind, 'description', l.description, 'amount_cents', l.amount_cents,
                'hst_cents', l.hst_cents) order by l.created_at, l.id), '[]'::jsonb) from owner_invoice_lines l where l.owner_invoice_id = i.id),
    'payments', (select coalesce(jsonb_agg(jsonb_build_object('id', p.id, 'method', p.method, 'status', p.status, 'amount_cents', p.amount_cents,
                   'card_brand', p.card_brand, 'card_last4', p.card_last4, 'decline', p.last_decline_code, 'created_at', p.created_at,
                   'processed_at', p.processed_at,
                   'reference', case when d.processor = 'offline' then d.raw ->> 'reference' end) order by p.created_at desc), '[]'::jsonb)
                   from payments p left join payment_processor_details d on d.payment_id = p.id where p.owner_invoice_id = i.id),
    'saved_methods', (select coalesce(jsonb_agg(jsonb_build_object('kind', m.kind, 'brand_or_bank', m.brand_or_bank, 'last4', m.last4,
                        'is_default', m.is_default)), '[]'::jsonb)
                        from owner_payment_methods m where m.owner_id = i.owner_id and m.status = 'active'))
    from owner_invoices i join owners o on o.id = i.owner_id join vehicles v on v.id = i.vehicle_id
   where i.id = p_invoice
$$;

create or replace function app.owner_portal_invoice(p_by uuid, p_number text) returns jsonb
language sql stable security definer set search_path = public, app as $$
  select app.owner_invoice_view(i.id) from owner_invoices i
   where i.invoice_number = upper(btrim(p_number)) and i.owner_id = app.portal_owner_id(p_by) and i.status <> 'draft'
$$;

-- An approved statement exactly as stored: owner totals, a block per vehicle with each line and the
-- booking or invoice behind it, and the owner-level lines.
create or replace function app.owner_portal_statement(p_by uuid, p_statement uuid) returns jsonb
language sql stable security definer set search_path = public, app as $$
  select jsonb_build_object(
    'statement', to_jsonb(s) - 'built_by' - 'approved_by',
    'vehicles', (select coalesce(jsonb_agg(jsonb_build_object(
                   'vehicle_id', sv.vehicle_id, 'name', app.vehicle_name(sv.vehicle_id), 'plate', v.plate, 'management_mode', v.management_mode,
                   'totals', to_jsonb(sv) - 'id' - 'owner_statement_id',
                   'lines', (select coalesce(jsonb_agg(app.statement_line_json(l) order by l.starts_on nulls last, l.line_type, l.id), '[]'::jsonb)
                               from owner_statement_lines l where l.owner_statement_id = s.id and l.vehicle_id = sv.vehicle_id))
                   order by v.created_at), '[]'::jsonb)
                   from owner_statement_vehicles sv join vehicles v on v.id = sv.vehicle_id where sv.owner_statement_id = s.id),
    'owner_lines', (select coalesce(jsonb_agg(app.statement_line_json(l) order by l.line_type, l.id), '[]'::jsonb)
                      from owner_statement_lines l where l.owner_statement_id = s.id and l.vehicle_id is null),
    'payout', (select jsonb_build_object('amount_cents', p.amount_cents, 'status', p.status, 'method', p.method, 'paid_at', p.paid_at,
                 'reference', p.reference, 'scheduled_for', p.scheduled_for)
                 from payouts p where p.owner_statement_id = s.id and p.status <> 'cancelled' limit 1))
    from owner_statements s
   where s.id = p_statement and s.owner_id = app.portal_owner_id(p_by) and s.status in ('approved', 'paid')
$$;

create or replace function app.statement_line_json(l owner_statement_lines) returns jsonb
language sql stable security definer set search_path = public, app as $$
  select jsonb_strip_nulls(to_jsonb(l) - 'owner_statement_id')
         || jsonb_strip_nulls(jsonb_build_object(
              'booking_number', (select b.booking_number from bookings b where b.id = l.booking_id),
              'invoice_number', (select i.invoice_number from owner_invoices i where i.id = l.owner_invoice_id),
              'from_vehicle_name', case when l.from_vehicle_id is not null then app.vehicle_name(l.from_vehicle_id) end))
$$;

-- A document the owner may open (owner_portal_documents decides), with where it is stored.
create or replace function app.owner_portal_document(p_by uuid, p_document uuid) returns jsonb
language sql stable security definer set search_path = public, app as $$
  select jsonb_build_object('id', d.id, 'title', d.title, 'kind', d.kind, 'bucket', d.storage_bucket, 'path', d.storage_path, 'mime_type', d.mime_type)
    from documents d
   where d.id = p_document and d.storage_path is not null
     and exists (select 1 from jsonb_array_elements(app.owner_portal_documents(p_by)) x where (x ->> 'id')::uuid = d.id)
$$;

-- The government forms pre-filled for the owner's vehicles: the data sheet always, the PDF file
-- when a verified template produced one.
create or replace function app.owner_portal_forms(p_by uuid) returns jsonb
language sql stable security definer set search_path = public, app as $$
  select coalesce(jsonb_agg(jsonb_build_object('id', g.id, 'form_code', g.form_code, 'title', t.title, 'vehicle_id', g.vehicle_id,
           'vehicle_name', app.vehicle_name(g.vehicle_id), 'mode', g.mode, 'status', g.status, 'missing', to_jsonb(g.missing),
           'data_sheet', g.data_sheet, 'has_pdf', g.file_key is not null, 'generated_at', g.generated_at)
           order by g.vehicle_id, g.form_code), '[]'::jsonb)
    from government_form_fills g join pdf_templates t on t.id = g.pdf_template_id
   where g.owner_id = app.portal_owner_id(p_by) and g.superseded_at is null
$$;

create or replace function app.owner_portal_bookings_json(p_by uuid, p_from timestamptz default null, p_to timestamptz default null) returns jsonb
language sql stable security definer set search_path = public, app as $$
  select coalesce(jsonb_agg(to_jsonb(x) order by x.pickup_at), '[]'::jsonb) from app.owner_portal_bookings(p_by, p_from, p_to) x
$$;

-- The owner changes contact details; the legal name and corporation details are a request to
-- customer service because they are on the agreements.
create or replace function app.owner_save_profile(p_by uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  v_owner uuid := app.portal_owner_id(p_by);
begin
  p := coalesce(p, '{}'::jsonb) - 'legal_name' - 'first_name' - 'middle_name' - 'last_name' - 'corporation_name' - 'corporation_number'
       - 'owner_type' - 'user_id' - 'referred_by' - 'licence_number' - 'date_of_birth';
  if nullif(p ->> 'hst_number', '') is not null and upper(btrim(p ->> 'hst_number')) !~ '^\d{9}RT\d{4}$' then
    raise exception 'An HST number looks like 123456789RT0001' using errcode = '22023';
  end if;
  if nullif(p ->> 'postal_code', '') is not null and upper(regexp_replace(p ->> 'postal_code', '\s', '', 'g')) !~ '^[A-Z]\d[A-Z]\d[A-Z]\d$' then
    raise exception 'A postal code looks like M5V 1A1' using errcode = '22023';
  end if;
  perform app.save_application_owner(v_owner, p, p_by);
  return app.owner_portal_home(p_by) -> 'owner';
end $$;

-- ================================================================ owner agreements: the packet to sign
-- What still needs the owner's signature: the Enrollment Agreement, the Title-Holding and Lease
-- Agreement (when a vehicle that is not Turo-Only needs it) and Vehicle Schedule entries.
create or replace function app.owner_signing_needed(p_owner uuid) returns jsonb
language sql stable security definer set search_path = public, app as $$
  with s as (
    select x.*, ob.status as ob_status from vehicle_schedules x
      join vehicles v on v.id = x.vehicle_id join vehicle_onboardings ob on ob.vehicle_id = v.id
     where v.owner_id = p_owner and x.superseded_by is null and ob.status not in ('declined', 'withdrawn'))
  select jsonb_build_object(
    'needed', exists (select 1 from s where s.signed_at is null),
    'enrollment', (select a.status from owner_agreements a where a.owner_id = p_owner and a.kind = 'enrollment' and a.status in ('draft', 'sent', 'signed')),
    'title_holding', (select a.status from owner_agreements a where a.owner_id = p_owner and a.kind = 'title_holding' and a.status in ('draft', 'sent', 'signed')),
    'unsigned_schedules', (select count(*) from s where s.signed_at is null),
    'signed_schedules', (select count(*) from s where s.signed_at is not null))
$$;

-- Everything the agreements print, for the server to render them: the owner, CarmaCars (trade name,
-- address, signing officer), both agreements and every current schedule entry. Owner or staff.
create or replace function app.owner_agreement_facts(p_owner uuid, p_by uuid) returns jsonb
language plpgsql stable security definer set search_path = public, app as $$
declare
  o owners;
  ps program_settings := app.settings();
begin
  select * into o from owners where id = p_owner;
  if o.id is null then raise exception 'Owner not found' using errcode = 'P0002'; end if;
  if p_by is null or not (app.user_is_owner_of(p_by, p_owner) or o.user_id = p_by or app.user_is_staff(p_by)) then
    raise exception 'Only the owner, or staff, reads the owner''s agreements' using errcode = '42501';
  end if;
  return jsonb_build_object(
    'owner', jsonb_build_object('id', o.id, 'owner_type', o.owner_type, 'legal_name', o.legal_name, 'corporation_name', o.corporation_name,
               'corporation_number', o.corporation_number, 'email', o.email, 'phone', o.phone, 'hst_number', o.hst_number,
               'address', nullif(concat_ws(', ', nullif(o.address_line1, ''), nullif(o.address_line2, ''), nullif(o.city, ''),
                                           nullif(concat_ws(' ', nullif(o.province, ''), nullif(o.postal_code, '')), '')), ''),
               'signing_officer_name', o.signing_officer_name, 'signing_officer_title', o.signing_officer_title,
               'signer_name', case when o.owner_type = 'corporation' then coalesce(o.signing_officer_name, o.legal_name) else o.legal_name end,
               'signer_role', case when o.owner_type = 'corporation' then 'owner_corporation' else 'owner_individual' end,
               'payout', (select concat_ws(' ', case a.method when 'e_transfer' then 'e-Transfer to ' || a.e_transfer_email
                                                     else 'Bank transfer to the account ending ' || a.account_last4 end,
                                          case when a.verified_at is null then '(being verified)' end)
                            from owner_payout_accounts a where a.owner_id = o.id order by a.is_current desc, a.created_at desc limit 1)),
    'company', jsonb_build_object('trade_name', ps.company_trade_name, 'address', ps.company_address, 'email', ps.company_email,
               'phone', ps.company_phone, 'signing_officer_name', coalesce(ps.signing_officer_name, ps.company_trade_name),
               'signing_officer_title', ps.signing_officer_title, 'install_fee_cents', ps.install_fee_cents, 'hst_bps', ps.hst_bps),
    'agreements', (select coalesce(jsonb_agg(jsonb_build_object('id', a.id, 'kind', a.kind, 'agreement_number', a.agreement_number,
                     'status', a.status, 'agreement_date', a.agreement_date, 'signature_request_id', a.signature_request_id,
                     'document_sha256', (select d.sha256 from signature_requests r join documents d on d.id = r.document_id where r.id = a.signature_request_id),
                     'corporate_signatory_name', a.corporate_signatory_name, 'corporate_signatory_title', a.corporate_signatory_title)
                     order by a.kind), '[]'::jsonb)
                     from owner_agreements a where a.owner_id = p_owner and a.status in ('draft', 'sent', 'signed')),
    'schedules', (select coalesce(jsonb_agg(jsonb_build_object('id', s.id, 'vehicle_id', s.vehicle_id, 'schedule_number', s.schedule_number,
                    'vehicle_number', s.vehicle_number, 'is_additional', s.is_additional, 'year', v.year, 'make', v.make, 'model', v.model,
                    'trim', v.trim, 'colour', v.colour, 'vin', upper(v.vin), 'plate', v.plate, 'odometer_km', s.odometer_km,
                    'held_by', s.held_by, 'title_status', s.title_status, 'finance_party_name', s.finance_party_name,
                    'finance_permission', s.finance_permission, 'management_mode', s.management_mode, 'onboarding_method', s.onboarding_method,
                    'insurance_fee_cents', s.insurance_fee_cents, 'tracker_fee_cents', s.tracker_fee_cents, 'install_fee_cents', s.install_fee_cents,
                    'revenue_share_bps', s.revenue_share_bps, 'enrollment_date', s.enrollment_date, 'special_terms', s.special_terms,
                    'owners_lien', s.owners_lien, 'signed_at', s.signed_at, 'signature_request_id', s.signature_request_id,
                    'title_agreement_id', s.title_agreement_id, 'onboarding_status', ob.status)
                    order by s.vehicle_number), '[]'::jsonb)
                    from vehicle_schedules s join vehicles v on v.id = s.vehicle_id join vehicle_onboardings ob on ob.vehicle_id = v.id
                   where v.owner_id = p_owner and s.superseded_by is null and ob.status not in ('declined', 'withdrawn')));
end $$;

-- The server rendered the documents to sign and stored them; this opens them for signature.
-- p_docs: [{key: enrollment | title_holding | additional, template_version, sha256, storage_path}].
-- The same document (same SHA-256) returns the request already open; a different one replaces it.
-- Vehicles whose schedule is in the packet move from terms_set to documents_sent.
create or replace function app.owner_open_agreements(p_owner uuid, p_by uuid, p_docs jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  o owners;
  d jsonb;
  a owner_agreements;
  v_key text;
  v_sha text;
  v_doc uuid;
  v_req uuid;
  v_out jsonb := '[]'::jsonb;
  v_ea owner_agreements;
  v_vehicle uuid;
begin
  select * into o from owners where id = p_owner for update;
  if o.id is null then raise exception 'Owner not found' using errcode = 'P0002'; end if;
  if p_by is null or not (app.user_is_owner_of(p_by, p_owner) or o.user_id = p_by or app.user_is_staff(p_by)) then
    raise exception 'Only the owner, or staff, opens the owner''s agreements' using errcode = '42501';
  end if;
  if jsonb_typeof(p_docs) <> 'array' or jsonb_array_length(p_docs) = 0 then
    raise exception 'Nothing to open' using errcode = '22023';
  end if;
  select * into v_ea from owner_agreements where owner_id = p_owner and kind = 'enrollment' and status in ('draft', 'sent', 'signed');
  for d in select value from jsonb_array_elements(p_docs) loop
    v_key := d ->> 'key';
    v_sha := lower(btrim(coalesce(d ->> 'sha256', '')));
    if v_sha !~ '^[0-9a-f]{64}$' or nullif(d ->> 'storage_path', '') is null or nullif(d ->> 'template_version', '') is null then
      raise exception 'A document needs its text version, its file and its SHA-256' using errcode = '22023';
    end if;
    v_req := null;
    if v_key in ('enrollment', 'title_holding') then
      select * into a from owner_agreements where owner_id = p_owner and kind = v_key and status in ('draft', 'sent', 'signed') for update;
      if a.id is null then raise exception 'The owner has no % agreement yet: set the terms first', replace(v_key, '_', ' ') using errcode = '23514'; end if;
      if a.status = 'signed' then raise exception 'The % agreement is already signed', replace(v_key, '_', ' ') using errcode = '23514'; end if;
      if a.signature_request_id is not null
         and exists (select 1 from signature_requests r join documents x on x.id = r.document_id
                      where r.id = a.signature_request_id and r.status = 'sent' and x.sha256 = v_sha) then
        v_req := a.signature_request_id;
      else
        if a.signature_request_id is not null then
          update signature_requests set status = 'voided' where id = a.signature_request_id and status in ('draft', 'sent', 'partially_signed');
        end if;
        insert into documents (kind, title, storage_bucket, storage_path, mime_type, sha256, template_version, retention, uploaded_by, owner_id)
        values (case v_key when 'enrollment' then 'enrollment_agreement' else 'title_agreement' end::document_kind,
                format('%s %s', case v_key when 'enrollment' then 'Vehicle Enrollment Agreement' else 'Title-Holding and Lease Agreement' end, a.agreement_number),
                'agreements', d ->> 'storage_path', 'application/pdf', v_sha, d ->> 'template_version', 'records_7y', p_by, p_owner)
        returning id into v_doc;
        insert into signature_requests (document_id, provider, provider_envelope, status, sent_at, created_by)
        values (v_doc, 'builtin', gen_random_uuid()::text, 'sent', now(), p_by) returning id into v_req;
        update owner_agreements set status = 'sent', document_id = v_doc, signature_request_id = v_req where id = a.id;
      end if;
      if v_key = 'enrollment' then
        -- the first schedule entries are part of the Enrollment Agreement (Schedule A)
        update vehicle_schedules s set signature_request_id = v_req
          from vehicles v where v.id = s.vehicle_id and v.owner_id = p_owner and s.owner_agreement_id = a.id
           and s.superseded_by is null and s.signed_at is null and not s.is_additional;
      end if;
      v_out := v_out || jsonb_build_array(jsonb_build_object('key', v_key, 'agreement_id', a.id, 'signature_request_id', v_req));
    elsif v_key = 'additional' then
      if v_ea.status is distinct from 'signed' then
        raise exception 'An Additional Vehicle Schedule follows a signed Enrollment Agreement' using errcode = '23514';
      end if;
      select s.signature_request_id into v_req from vehicle_schedules s join vehicles v on v.id = s.vehicle_id
        join signature_requests r on r.id = s.signature_request_id join documents x on x.id = r.document_id
       where v.owner_id = p_owner and s.is_additional and s.signed_at is null and s.superseded_by is null and r.status = 'sent' and x.sha256 = v_sha
       limit 1;
      if v_req is null then
        insert into documents (kind, title, storage_bucket, storage_path, mime_type, sha256, template_version, retention, uploaded_by, owner_id)
        values ('additional_vehicle_schedule', 'Additional Vehicle Schedule', 'agreements', d ->> 'storage_path', 'application/pdf', v_sha,
                d ->> 'template_version', 'records_7y', p_by, p_owner)
        returning id into v_doc;
        insert into signature_requests (document_id, provider, provider_envelope, status, sent_at, created_by)
        values (v_doc, 'builtin', gen_random_uuid()::text, 'sent', now(), p_by) returning id into v_req;
        update signature_requests r set status = 'voided'
          from vehicle_schedules s join vehicles v on v.id = s.vehicle_id
         where r.id = s.signature_request_id and v.owner_id = p_owner and s.is_additional and s.signed_at is null and r.status = 'sent';
        update vehicle_schedules s set signature_request_id = v_req, document_id = v_doc
          from vehicles v where v.id = s.vehicle_id and v.owner_id = p_owner and s.is_additional and s.signed_at is null and s.superseded_by is null;
      end if;
      v_out := v_out || jsonb_build_array(jsonb_build_object('key', v_key, 'signature_request_id', v_req));
    else
      raise exception 'Unknown document %', v_key using errcode = '22023';
    end if;
  end loop;
  -- vehicles in the packet: their documents are with the owner now
  for v_vehicle in
    select s.vehicle_id from vehicle_schedules s join vehicles v on v.id = s.vehicle_id join vehicle_onboardings ob on ob.vehicle_id = v.id
     where v.owner_id = p_owner and s.superseded_by is null and s.signed_at is null and ob.status = 'terms_set'
  loop
    update vehicle_onboardings set status = 'documents_sent', documents_sent_at = coalesce(documents_sent_at, now()) where vehicle_id = v_vehicle;
  end loop;
  return jsonb_build_object('requests', v_out);
end $$;

-- The owner signs the open packet in one sitting: one signature (drawn or typed), the three
-- initialled confirmations of the Enrollment Agreement, and the SHA-256 of each document on
-- screen. Each request gets the owner's signature record and CarmaCars' countersignature (in the
-- name of the signing officer in program_settings), and is completed. Schedules are signed; every
-- vehicle whose documents are now all signed moves to documents_signed, and on to upfront_paid
-- when its upfront invoice is already paid.
-- p: {typed_name, drawn_signature, ip, user_agent, consent_text, initials: {own_insurance, fees_no_income, tracker_downtime},
--     documents: [{key, sha256}]}
create or replace function app.owner_sign_agreements(p_owner uuid, p_by uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  o owners;
  ps program_settings := app.settings();
  d jsonb;
  a owner_agreements;
  v_key text;
  v_sha text;
  v_req uuid;
  v_typed text := nullif(btrim(coalesce(p ->> 'typed_name', '')), '');
  v_drawn text := nullif(btrim(coalesce(p ->> 'drawn_signature', '')), '');
  v_signer text;
  v_role text;
  v_ip inet := nullif(p ->> 'ip', '')::inet;
  v_rec uuid;
  v_out jsonb := '[]'::jsonb;
  v_initials jsonb := coalesce(p -> 'initials', '{}'::jsonb);
  r record;
  v_moved integer := 0;
begin
  select * into o from owners where id = p_owner for update;
  if o.id is null then raise exception 'Owner not found' using errcode = 'P0002'; end if;
  if p_by is null or not (app.user_is_owner_of(p_by, p_owner) or o.user_id = p_by) then
    raise exception 'Only the owner signs the owner''s agreements' using errcode = '42501';
  end if;
  v_signer := case when o.owner_type = 'corporation' then coalesce(o.signing_officer_name, o.legal_name) else o.legal_name end;
  v_role := case when o.owner_type = 'corporation' then 'owner_corporation' else 'owner_individual' end;
  if v_typed is null and v_drawn is null then
    raise exception 'Sign by drawing a signature or by typing your full legal name' using errcode = '22023';
  end if;
  if v_drawn is null and lower(regexp_replace(v_typed, '\s+', '', 'g')) <> lower(regexp_replace(v_signer, '\s+', '', 'g')) then
    raise exception 'The typed name must be the signer''s full legal name (%)', v_signer using errcode = '23514';
  end if;
  if nullif(btrim(coalesce(p ->> 'consent_text', '')), '') is null then
    raise exception 'The statement the signer agreed to is recorded with the signature' using errcode = '22023';
  end if;
  if jsonb_typeof(p -> 'documents') <> 'array' or jsonb_array_length(p -> 'documents') = 0 then
    raise exception 'Nothing to sign' using errcode = '22023';
  end if;

  for d in select value from jsonb_array_elements(p -> 'documents') loop
    v_key := d ->> 'key';
    v_sha := lower(btrim(coalesce(d ->> 'sha256', '')));
    a := null; v_req := null;
    if v_key in ('enrollment', 'title_holding') then
      select * into a from owner_agreements where owner_id = p_owner and kind = v_key and status in ('draft', 'sent', 'signed') for update;
      if a.id is null or a.status <> 'sent' then
        raise exception 'The % agreement is not open for signature. Reload the page.', replace(v_key, '_', ' ') using errcode = '23514';
      end if;
      v_req := a.signature_request_id;
      if v_key = 'enrollment' and (nullif(btrim(v_initials ->> 'own_insurance'), '') is null
                                   or nullif(btrim(v_initials ->> 'fees_no_income'), '') is null
                                   or nullif(btrim(v_initials ->> 'tracker_downtime'), '') is null) then
        raise exception 'Initial each of the three confirmations of the Enrollment Agreement' using errcode = '22023';
      end if;
    elsif v_key = 'additional' then
      select s.signature_request_id into v_req from vehicle_schedules s join vehicles v on v.id = s.vehicle_id
       where v.owner_id = p_owner and s.is_additional and s.signed_at is null and s.superseded_by is null and s.signature_request_id is not null
       limit 1;
    else
      raise exception 'Unknown document %', v_key using errcode = '22023';
    end if;
    if v_req is null or not exists (select 1 from signature_requests x join documents y on y.id = x.document_id
                                     where x.id = v_req and x.status = 'sent' and y.sha256 = v_sha) then
      raise exception 'The document changed after it was opened: reload and sign the current version' using errcode = '23514';
    end if;

    insert into signature_records (signature_request_id, signer_role, signer_user_id, signer_name, signer_title, signer_email, status, signed_at,
                                   method, ip_address, user_agent, provider_signature, initials, typed_name, consent_text, document_sha256)
    values (v_req, v_role, p_by, v_signer, case when o.owner_type = 'corporation' then o.signing_officer_title end, o.email, 'signed', now(),
            case when v_drawn is not null then 'drawn' else 'typed' end, v_ip, nullif(p ->> 'user_agent', ''), v_drawn,
            case when v_key = 'enrollment' then v_initials end, v_typed, p ->> 'consent_text', v_sha)
    returning id into v_rec;
    insert into signature_records (signature_request_id, signer_role, signer_name, signer_title, signer_email, status, signed_at, method,
                                   typed_name, consent_text, document_sha256)
    values (v_req, 'carmacars', coalesce(ps.signing_officer_name, ps.company_trade_name), coalesce(ps.signing_officer_title, 'for ' || ps.company_trade_name),
            ps.company_email, 'signed', now(), 'automatic', coalesce(ps.signing_officer_name, ps.company_trade_name),
            format('Countersigned for %s automatically when the owner signed.', ps.company_trade_name), v_sha);
    update signature_requests set status = 'completed', completed_at = now() where id = v_req;
    if a.id is not null then
      update owner_agreements
         set status = 'signed', agreement_date = coalesce(agreement_date, app.today()),
             confirm_own_insurance_at = case when v_key = 'enrollment' then now() else confirm_own_insurance_at end,
             confirm_fees_no_income_at = case when v_key = 'enrollment' then now() else confirm_fees_no_income_at end,
             confirm_tracker_downtime_at = case when v_key = 'enrollment' then now() else confirm_tracker_downtime_at end
       where id = a.id;
    end if;
    update vehicle_schedules set signed_at = now() where signature_request_id = v_req and signed_at is null and superseded_by is null;
    v_out := v_out || jsonb_build_array(jsonb_build_object('key', v_key, 'agreement_id', a.id, 'agreement_number', a.agreement_number,
                                                           'signature_request_id', v_req, 'signature_record_id', v_rec,
                                                           'records', (select jsonb_agg(jsonb_build_object('signer_role', x.signer_role, 'signer_name', x.signer_name,
                                                                         'signer_title', x.signer_title, 'method', x.method, 'signed_at', x.signed_at,
                                                                         'ip_address', host(x.ip_address), 'user_agent', x.user_agent,
                                                                         'provider_signature', x.provider_signature, 'typed_name', x.typed_name,
                                                                         'initials', x.initials) order by x.created_at)
                                                                         from signature_records x where x.signature_request_id = v_req)));
  end loop;

  -- every vehicle whose documents are now all signed
  for r in
    select ob.id, ob.status, v.management_mode, ob.upfront_invoice_id, ob.upfront_paid_at, v.billing_case
      from vehicles v join vehicle_onboardings ob on ob.vehicle_id = v.id
      join vehicle_schedules s on s.vehicle_id = v.id and s.superseded_by is null
     where v.owner_id = p_owner and s.signed_at is not null and ob.status in ('terms_set', 'documents_sent')
       and exists (select 1 from owner_agreements e where e.owner_id = p_owner and e.kind = 'enrollment' and e.status = 'signed')
       and (v.management_mode = 'turo_only'
            or exists (select 1 from owner_agreements t where t.owner_id = p_owner and t.kind = 'title_holding' and t.status = 'signed'))
  loop
    if r.status = 'terms_set' then
      update vehicle_onboardings set status = 'documents_sent', documents_sent_at = coalesce(documents_sent_at, now()) where id = r.id;
    end if;
    update vehicle_onboardings set status = 'documents_signed', documents_signed_at = coalesce(documents_signed_at, now()) where id = r.id;
    if r.billing_case in ('managed', 'self_managed')
       and (r.upfront_paid_at is not null or exists (select 1 from owner_invoices i where i.id = r.upfront_invoice_id and i.status = 'paid')) then
      update vehicle_onboardings set status = 'upfront_paid', upfront_paid_at = coalesce(upfront_paid_at, now()) where id = r.id;
    end if;
    v_moved := v_moved + 1;
  end loop;
  return jsonb_build_object('signed', v_out, 'vehicles_signed', v_moved, 'signer_name', v_signer);
end $$;

-- The signed copy (every signature and the signature record printed on it) is attached once.
create or replace function app.attach_owner_signed_copy(p_request uuid, p_path text, p_sha256 text) returns uuid
language plpgsql security definer set search_path = public, app as $$
declare
  r signature_requests;
  d documents;
  v_doc uuid;
begin
  select * into r from signature_requests where id = p_request for update;
  if r.id is null or r.status <> 'completed' then raise exception 'This document is not fully signed' using errcode = '23514'; end if;
  if r.signed_document_id is not null then return r.signed_document_id; end if;
  select * into d from documents where id = r.document_id;
  insert into documents (kind, title, storage_bucket, storage_path, mime_type, sha256, template_version, retention, owner_id)
  values (d.kind, coalesce(d.title, 'Agreement') || ', signed', 'agreements', p_path, 'application/pdf', lower(btrim(p_sha256)),
          d.template_version, 'records_7y', d.owner_id)
  returning id into v_doc;
  update signature_requests set signed_document_id = v_doc where id = r.id;
  update owner_agreements set document_id = v_doc where signature_request_id = r.id;
  update vehicle_schedules set document_id = v_doc where signature_request_id = r.id;
  return v_doc;
end $$;

-- ================================================================ owner invoice payments
-- What the pay page needs, after checking the caller is the invoice's owner (or staff).
create or replace function app.owner_invoice_payment_facts(p_invoice uuid, p_by uuid) returns jsonb
language plpgsql stable security definer set search_path = public, app as $$
declare
  i owner_invoices;
begin
  select * into i from owner_invoices where id = p_invoice;
  if i.id is null then raise exception 'Invoice not found' using errcode = 'P0002'; end if;
  if p_by is null or not (app.user_is_owner_of(p_by, i.owner_id) or app.user_is_staff(p_by)) then
    raise exception 'Only the owner of this invoice, or staff, may pay it' using errcode = '42501';
  end if;
  return app.owner_invoice_view(i.id) || jsonb_build_object(
    'customer_id', (select d.raw ->> 'customer_id' from payments p join payment_processor_details d on d.payment_id = p.id
                     where p.owner_id = i.owner_id and d.processor = 'stripe' and d.raw ->> 'customer_id' is not null
                     order by p.created_at desc limit 1),
    'saved', (select coalesce(jsonb_agg(jsonb_build_object('kind', m.kind, 'brand_or_bank', m.brand_or_bank, 'last4', m.last4,
                'customer_id', s.processor_customer_id, 'method_id', s.processor_method_id, 'mandate_id', s.processor_mandate_id)
                order by m.created_at desc), '[]'::jsonb)
                from owner_payment_methods m join owner_payment_method_secrets s on s.owner_payment_method_id = m.id
               where m.owner_id = i.owner_id and m.status = 'active'));
end $$;

-- What a received payment does to the invoice (shared by the processor path and the offline path):
-- the balance paid marks it paid (0007's triggers fund the prepaid months and send the receipt);
-- an upfront invoice moves its vehicle on; a payment on an invoice already paid goes to an Admin.
create or replace function app.owner_invoice_apply_payment(p_invoice uuid, p_amount bigint, p_method text, p_payment uuid) returns text
language plpgsql security definer set search_path = public, app as $$
declare
  i owner_invoices;
begin
  select * into i from owner_invoices where id = p_invoice for update;
  if i.status in ('paid', 'deducted', 'void') or i.balance_cents <= 0 then
    insert into tasks (queue, task_type, title, detail, priority, vehicle_id, owner_id, related_table, related_id, escalated, escalated_at, escalation_reason)
    values ('admin', 'owner_payment_unapplied', format('Payment received on invoice %s, which is %s', i.invoice_number, i.status),
            format('A payment of $%s arrived for invoice %s after it was %s. Refund it or apply it to another invoice.',
                   to_char(p_amount / 100.0, 'FM999,999,990.00'), i.invoice_number, i.status),
            'high', i.vehicle_id, i.owner_id, 'payments', p_payment, true, now(), 'payment on a settled invoice');
    return i.status;
  end if;
  if p_amount >= i.balance_cents then
    update owner_invoices set status = 'paid', paid_at = now(),
           payment_method = case when p_method in ('pre_authorized_debit', 'card', 'e_transfer', 'bank_transfer', 'cheque') then p_method else payment_method end
     where id = i.id;
    if p_amount > i.balance_cents then
      insert into tasks (queue, task_type, title, detail, priority, vehicle_id, owner_id, related_table, related_id)
      values ('finance', 'owner_overpayment', format('Overpayment on invoice %s', i.invoice_number),
              format('$%s received for a balance of $%s.', to_char(p_amount / 100.0, 'FM999,999,990.00'), to_char(i.balance_cents / 100.0, 'FM999,999,990.00')),
              'normal', i.vehicle_id, i.owner_id, 'payments', p_payment);
    end if;
    if i.kind = 'upfront' then
      update vehicle_onboardings set upfront_paid_at = coalesce(upfront_paid_at, now()) where upfront_invoice_id = i.id;
      update vehicle_onboardings set status = 'upfront_paid' where upfront_invoice_id = i.id and status = 'documents_signed';
    end if;
    update tasks set status = 'done', completed_at = now()
     where related_id = i.id and task_type in ('collect_upfront', 'debit_failed') and status in ('open', 'in_progress', 'waiting');
  else
    update owner_invoices set paid_cents = paid_cents + p_amount where id = i.id;
  end if;
  return (select status from owner_invoices where id = i.id);
end $$;

-- A processor payment on an owner invoice: pending (a pre-authorized debit submitted), succeeded
-- or failed. Called by the server after the browser confirms and by the webhook; idempotent on the
-- processor's payment id (the webhook also claims each event with app.webhook_event_claim).
-- p: {status, method (card | pre_authorized_debit), amount_cents, currency,
--     processor: {processor, payment_id, charge_id, customer_id, method_id, mandate_id},
--     card: {brand, last4} | bank: {name, last4}, failure_message, save_method}
create or replace function app.record_owner_invoice_payment(p_invoice uuid, p jsonb, p_by uuid default null) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  i owner_invoices;
  x payments;
  v_status text := p ->> 'status';
  v_method text := coalesce(nullif(p ->> 'method', ''), 'card');
  v_amount bigint := (p ->> 'amount_cents')::bigint;
  v_proc text := coalesce(nullif(p #>> '{processor,processor}', ''), 'stripe');
  v_pid text := nullif(p #>> '{processor,payment_id}', '');
  v_last4 text := coalesce(p #>> '{card,last4}', p #>> '{bank,last4}');
  v_brand text := coalesce(p #>> '{card,brand}', p #>> '{bank,name}');
  v_invoice_status text;
  v_saved uuid;
begin
  select * into i from owner_invoices where id = p_invoice for update;
  if i.id is null then raise exception 'Invoice not found' using errcode = 'P0002'; end if;
  if p_by is not null and not (app.user_is_owner_of(p_by, i.owner_id) or app.user_is_admin(p_by)) then
    raise exception 'Only the owner of this invoice, or an Admin, records its payment' using errcode = '42501';
  end if;
  if v_status not in ('pending', 'succeeded', 'failed') then raise exception 'Unknown payment status %', v_status using errcode = '22023'; end if;
  if v_method not in ('card', 'pre_authorized_debit') then raise exception 'Unknown payment method %', v_method using errcode = '22023'; end if;
  if v_pid is null or v_amount is null or v_amount <= 0 then
    raise exception 'A processor payment needs its id and amount' using errcode = '22023';
  end if;
  if coalesce(lower(p ->> 'currency'), 'cad') <> 'cad' then raise exception 'Owner invoices are paid in Canadian dollars' using errcode = '22023'; end if;

  select pay.* into x from payments pay join payment_processor_details d on d.payment_id = pay.id
   where pay.owner_invoice_id = i.id and d.processor = v_proc and d.processor_payment_id = v_pid and d.processor_refund_id is null
   for update of pay;

  if x.id is not null then
    if x.status = 'succeeded' or (x.status = v_status) then
      return jsonb_build_object('ok', true, 'repeat', true, 'payment_id', x.id, 'status', x.status, 'invoice_status', i.status);
    end if;
    update payments set status = v_status, method = v_method, card_brand = coalesce(v_brand, card_brand), card_last4 = coalesce(v_last4, card_last4),
           decline_count = decline_count + case when v_status = 'failed' then 1 else 0 end,
           last_decline_code = case when v_status = 'failed' then left(p ->> 'failure_message', 200) else last_decline_code end,
           processed_at = case when v_status <> 'pending' then now() else processed_at end
     where id = x.id returning * into x;
  else
    -- a new payment starts only on an invoice that can be paid; money that did arrive is always recorded
    if v_status = 'pending' and i.status not in ('issued', 'failed', 'in_arrears', 'partially_deducted', 'processing', 'retry_processing') then
      raise exception 'Invoice % is % and cannot be paid', i.invoice_number, i.status using errcode = '23514';
    end if;
    insert into payments (owner_id, owner_invoice_id, purpose, kind, method, amount_cents, status, card_brand, card_last4,
                          decline_count, last_decline_code, processed_at, created_by)
    values (i.owner_id, i.id, case when i.kind = 'upfront' then 'owner_upfront' else 'owner_fees' end, 'charge', v_method, v_amount, v_status,
            v_brand, v_last4, case when v_status = 'failed' then 1 else 0 end,
            case when v_status = 'failed' then left(p ->> 'failure_message', 200) end,
            case when v_status <> 'pending' then now() end, p_by)
    returning * into x;
    insert into payment_processor_details (payment_id, processor, processor_payment_id, processor_charge_id, raw)
    values (x.id, v_proc, v_pid, nullif(p #>> '{processor,charge_id}', ''),
            jsonb_strip_nulls(jsonb_build_object('customer_id', p #>> '{processor,customer_id}', 'method_id', p #>> '{processor,method_id}',
                                                 'mandate_id', p #>> '{processor,mandate_id}')));
  end if;

  v_invoice_status := i.status;
  if v_status = 'succeeded' then
    v_invoice_status := app.owner_invoice_apply_payment(i.id, v_amount, v_method, x.id);
    -- saving the method: the card or the debit authorization becomes the owner's method on file,
    -- which the monthly debit on the 15th uses
    if coalesce((p ->> 'save_method')::boolean, false) and nullif(p #>> '{processor,method_id}', '') is not null
       and not exists (select 1 from owner_payment_method_secrets s join owner_payment_methods m on m.id = s.owner_payment_method_id
                        where m.owner_id = i.owner_id and s.processor_method_id = p #>> '{processor,method_id}' and m.status = 'active') then
      v_saved := app.record_owner_payment_method(i.owner_id, null, jsonb_build_object(
        'kind', case v_method when 'card' then 'card' else 'pre_authorized_debit' end, 'brand_or_bank', v_brand, 'last4', v_last4,
        'processor_customer_id', p #>> '{processor,customer_id}', 'processor_method_id', p #>> '{processor,method_id}',
        'processor_mandate_id', p #>> '{processor,mandate_id}'));
    end if;
  elsif v_status = 'failed' and v_method = 'pre_authorized_debit' then
    perform app.ntf_emit('staff_owner_invoice_failed', 'owner_invoice', i.id, 'debit_returned:' || x.id,
      jsonb_build_object('owner_id', i.owner_id, 'vehicle_id', i.vehicle_id, 'failure_stage', 'returned',
                         'bank_reason', coalesce(p ->> 'failure_message', 'Returned by the bank'),
                         'failure_next_step', 'The owner was asked to pay again from the invoice page.'));
  end if;
  return jsonb_build_object('ok', true, 'payment_id', x.id, 'status', x.status, 'invoice_status', v_invoice_status, 'saved_method_id', v_saved);
end $$;

-- An Admin records a payment received outside the processor (e-Transfer, cheque or bank transfer),
-- with its reference. Audited. A second call with the same reference returns the first.
-- p: {method, reference, received_on, amount_cents (default the balance), note}
create or replace function app.record_owner_offline_payment(p_invoice uuid, p_admin uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  i owner_invoices;
  v_method text := coalesce(nullif(p ->> 'method', ''), 'e_transfer');
  v_ref text := nullif(btrim(coalesce(p ->> 'reference', '')), '');
  v_on date := coalesce(nullif(p ->> 'received_on', '')::date, app.today());
  v_amount bigint;
  v_pay uuid;
  v_status text;
begin
  if not app.user_is_admin(p_admin) then
    raise exception 'Only an Admin records a payment received outside the card processor' using errcode = '42501';
  end if;
  if v_method not in ('e_transfer', 'cheque', 'bank_transfer') then
    raise exception 'An offline payment is an e-Transfer, a cheque or a bank transfer' using errcode = '22023';
  end if;
  if v_ref is null or length(v_ref) < 3 then
    raise exception 'Enter the reference (e-Transfer reference number or cheque number)' using errcode = '22023';
  end if;
  if v_on > app.today() then raise exception 'The date received cannot be in the future' using errcode = '22023'; end if;
  select * into i from owner_invoices where id = p_invoice for update;
  if i.id is null then raise exception 'Invoice not found' using errcode = 'P0002'; end if;
  select pay.id into v_pay from payments pay join payment_processor_details d on d.payment_id = pay.id
   where pay.owner_invoice_id = i.id and d.processor = 'offline' and d.processor_payment_id = v_method || ':' || v_ref;
  if v_pay is not null then
    return jsonb_build_object('ok', true, 'repeat', true, 'payment_id', v_pay, 'invoice_status', i.status);
  end if;
  if i.status not in ('issued', 'failed', 'in_arrears', 'partially_deducted') then
    raise exception 'Invoice % is % and cannot take a payment', i.invoice_number, i.status using errcode = '23514';
  end if;
  v_amount := coalesce(nullif(p ->> 'amount_cents', '')::bigint, i.balance_cents);
  if v_amount <= 0 then raise exception 'Enter the amount received' using errcode = '22023'; end if;
  insert into payments (owner_id, owner_invoice_id, purpose, kind, method, amount_cents, status, processed_at, created_by)
  values (i.owner_id, i.id, case when i.kind = 'upfront' then 'owner_upfront' else 'owner_fees' end, 'charge', v_method, v_amount, 'succeeded',
          app.local_midnight(v_on) + interval '12 hours', p_admin)
  returning id into v_pay;
  insert into payment_processor_details (payment_id, processor, processor_payment_id, raw)
  values (v_pay, 'offline', v_method || ':' || v_ref,
          jsonb_build_object('reference', v_ref, 'received_on', v_on, 'note', nullif(btrim(p ->> 'note'), ''), 'recorded_by', p_admin));
  v_status := app.owner_invoice_apply_payment(i.id, v_amount, v_method, v_pay);
  insert into audit_log (actor_user_id, action, entity_table, entity_id, before, after)
  values (p_admin, 'record_offline_payment', 'owner_invoices', i.id::text,
          jsonb_build_object('status', i.status, 'balance_cents', i.balance_cents),
          jsonb_build_object('status', v_status, 'payment_id', v_pay, 'method', v_method, 'reference', v_ref, 'received_on', v_on,
                             'amount_cents', v_amount, 'note', nullif(btrim(p ->> 'note'), '')));
  return jsonb_build_object('ok', true, 'payment_id', v_pay, 'invoice_status', v_status);
end $$;

-- ================================================================ admin
create or replace function app.admin_gate(p_user uuid) returns jsonb
language sql stable security definer set search_path = public, app as $$
  select jsonb_build_object('admin', app.user_is_admin(p_user), 'staff', app.user_is_staff(p_user),
                            'two_step_required', coalesce((app.settings()).require_staff_two_step, false),
                            'name', (select u.full_name from users u where u.id = p_user))
$$;

create or replace function app.assert_admin(p_admin uuid) returns void
language plpgsql stable security definer set search_path = public, app as $$
begin
  if p_admin is null or not app.user_is_admin(p_admin) then
    raise exception 'Only an Admin may do this' using errcode = '42501';
  end if;
end $$;

-- Owners with applications, newest first, with the state of their vehicles and invoices.
create or replace function app.admin_owner_applications(p_admin uuid) returns jsonb
language plpgsql stable security definer set search_path = public, app as $$
begin
  perform app.assert_admin(p_admin);
  return (select coalesce(jsonb_agg(x order by x ->> 'last_at' desc), '[]'::jsonb) from (
    select jsonb_build_object('owner_id', o.id, 'legal_name', o.legal_name, 'owner_type', o.owner_type, 'email', o.email, 'phone', o.phone,
             'has_account', o.user_id is not null,
             'applications', (select jsonb_agg(a.application_number order by a.created_at) from owner_applications a where a.owner_id = o.id),
             'last_at', (select max(a.created_at) from owner_applications a where a.owner_id = o.id),
             'vehicles', (select count(*) from vehicles v where v.owner_id = o.id),
             'statuses', (select jsonb_object_agg(s, n) from (select ob.status::text s, count(*) n from vehicles v join vehicle_onboardings ob on ob.vehicle_id = v.id
                                                                where v.owner_id = o.id group by ob.status) q),
             'pending_terms', (select count(*) from vehicles v join vehicle_onboardings ob on ob.vehicle_id = v.id where v.owner_id = o.id and ob.pending_terms is not null),
             'invoices_open', (select count(*) from owner_invoices i where i.owner_id = o.id and i.status in ('issued', 'failed', 'in_arrears', 'processing')),
             'invoices_paid', (select count(*) from owner_invoices i where i.owner_id = o.id and i.status = 'paid')) as x
      from owners o where exists (select 1 from owner_applications a where a.owner_id = o.id)) q);
end $$;

-- One owner: everything the admin needs to set terms, issue invoices and take payments.
create or replace function app.admin_owner_detail(p_admin uuid, p_owner uuid) returns jsonb
language plpgsql stable security definer set search_path = public, app as $$
declare
  o owners;
begin
  perform app.assert_admin(p_admin);
  select * into o from owners where id = p_owner;
  if o.id is null then return null; end if;
  return jsonb_build_object(
    'owner', to_jsonb(o) || jsonb_build_object('missing', to_jsonb(app.owner_missing_fields(o.id)),
               'private', (select jsonb_build_object('licence_number', d.licence_number, 'licence_province', d.licence_province, 'date_of_birth', d.date_of_birth)
                             from owner_private_details d where d.owner_id = o.id),
               'user_email', (select u.email from users u where u.id = o.user_id)),
    'applications', (select coalesce(jsonb_agg(jsonb_build_object('application_number', a.application_number, 'source', a.source,
                       'vehicle_count', a.vehicle_count, 'created_at', a.created_at, 'note', a.note) order by a.created_at), '[]'::jsonb)
                       from owner_applications a where a.owner_id = o.id),
    'signing', app.owner_signing_needed(o.id),
    'vehicles', (select coalesce(jsonb_agg(jsonb_build_object(
        'vehicle_id', v.id, 'name', app.vehicle_name(v.id), 'vin', upper(v.vin), 'plate', v.plate, 'colour', v.colour, 'odometer_km', v.odometer_km,
        'status', v.status, 'billing_case', v.billing_case, 'is_shareholder_owned', v.is_shareholder_owned,
        'onboarding', jsonb_build_object('status', ob.status, 'held_by', ob.held_by, 'title_status', ob.title_status,
            'finance_party_name', ob.finance_party_name, 'finance_permission', ob.finance_permission, 'current_insurer', ob.current_insurer,
            'proposed_management_mode', ob.proposed_management_mode, 'proposed_onboarding_method', ob.proposed_onboarding_method,
            'situation', ob.situation, 'estimate_cents', ob.estimate_cents, 'estimate_plus_tax', ob.estimate_plus_tax,
            'government_forms', to_jsonb(ob.government_forms), 'owners_lien_elected', ob.owners_lien_elected,
            'disclosures', ob.disclosures, 'new_corporation', ob.new_corporation, 'decline_reason', ob.decline_reason,
            'pending_terms', ob.pending_terms, 'terms_off_grid', ob.terms_off_grid, 'terms_approved_at', ob.terms_approved_at,
            'upfront_paid_at', ob.upfront_paid_at),
        'standard', (select jsonb_build_object('insurance_fee_cents', st.insurance_fee_cents, 'tracker_fee_cents', st.tracker_fee_cents,
                       'revenue_share_bps', st.revenue_share_bps, 'install_fee_cents', st.install_fee_cents, 'vehicle_count', st.vehicle_count)
                       from app.standard_terms(o.id, coalesce(ob.proposed_management_mode, v.management_mode)) st),
        'options', app.onboarding_options_json(ob.held_by::text, ob.title_status::text, coalesce(ob.proposed_management_mode, v.management_mode)::text),
        'schedule', (select jsonb_build_object('schedule_number', s.schedule_number, 'management_mode', s.management_mode, 'onboarding_method', s.onboarding_method,
                       'insurance_fee_cents', s.insurance_fee_cents, 'tracker_fee_cents', s.tracker_fee_cents, 'install_fee_cents', s.install_fee_cents,
                       'revenue_share_bps', s.revenue_share_bps, 'special_terms', s.special_terms, 'signed_at', s.signed_at)
                       from vehicle_schedules s where s.vehicle_id = v.id and s.superseded_by is null),
        'upfront_invoice', (select jsonb_build_object('id', i.id, 'invoice_number', i.invoice_number, 'status', i.status, 'total_cents', i.total_cents,
                              'balance_cents', i.balance_cents) from owner_invoices i where i.id = ob.upfront_invoice_id))
        order by v.created_at), '[]'::jsonb)
        from vehicles v join vehicle_onboardings ob on ob.vehicle_id = v.id where v.owner_id = o.id),
    'invoices', (select coalesce(jsonb_agg(app.owner_invoice_view(i.id) order by i.billing_date desc, i.invoice_number desc), '[]'::jsonb)
                   from owner_invoices i where i.owner_id = o.id and i.status <> 'draft'));
end $$;

create or replace function app.admin_owner_invoices(p_admin uuid, p_status text default null) returns jsonb
language plpgsql stable security definer set search_path = public, app as $$
begin
  perform app.assert_admin(p_admin);
  return (select coalesce(jsonb_agg(jsonb_build_object('id', i.id, 'invoice_number', i.invoice_number, 'owner_id', i.owner_id, 'owner_name', o.legal_name,
            'vehicle_name', app.vehicle_name(i.vehicle_id), 'kind', i.kind, 'period_month', i.period_month, 'status', i.status,
            'total_cents', i.total_cents, 'balance_cents', i.balance_cents, 'billing_date', i.billing_date, 'paid_at', i.paid_at,
            'payment_method', i.payment_method,
            'pending', exists (select 1 from payments p where p.owner_invoice_id = i.id and p.status = 'pending'))
            order by i.billing_date desc, i.invoice_number desc), '[]'::jsonb)
            from owner_invoices i join owners o on o.id = i.owner_id
           where i.status <> 'draft'
             and (p_status is null or p_status = '' or i.status = p_status
                  or (p_status = 'open' and i.status in ('issued', 'failed', 'in_arrears', 'processing', 'retry_processing', 'partially_deducted'))));
end $$;

-- Terms: set by an Admin (the grid by default, anything off the grid is the Admin's decision),
-- then the government forms the method needs are pre-filled for the vehicle.
create or replace function app.admin_set_vehicle_terms(p_vehicle uuid, p_admin uuid, p_terms jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  v_out jsonb;
begin
  perform app.assert_admin(p_admin);
  v_out := app.set_vehicle_terms(p_vehicle, p_admin, coalesce(p_terms, '{}'::jsonb));
  if v_out ->> 'status' = 'terms_set' then
    perform app.fill_vehicle_government_forms(p_vehicle, p_admin);
  end if;
  return v_out;
end $$;

create or replace function app.admin_approve_vehicle_terms(p_vehicle uuid, p_admin uuid, p_approve boolean) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  v_out jsonb;
begin
  perform app.assert_admin(p_admin);
  v_out := app.approve_vehicle_terms(p_vehicle, p_admin, p_approve);
  if v_out ->> 'status' = 'terms_set' then
    perform app.fill_vehicle_government_forms(p_vehicle, p_admin);
  end if;
  return v_out;
end $$;

-- The upfront invoice of each chosen vehicle (all of the owner's when none are named) whose terms
-- are set: the Install Fee and the first and last month's Insurance Fee with HST, through 0007's
-- app.issue_upfront_invoice. An Admin may issue it before the agreements are signed (owner
-- billing specification section 1: before the Enrollment Date); 0022's app.issue_upfront_invoices
-- keeps issuing on signature for the automatic path.
create or replace function app.admin_issue_upfront_invoices(p_owner uuid, p_admin uuid, p_vehicles uuid[] default null) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  r record;
  v_inv uuid;
  v_out jsonb := '[]'::jsonb;
begin
  perform app.assert_admin(p_admin);
  for r in
    select v.id from vehicles v join vehicle_onboardings ob on ob.vehicle_id = v.id
     where v.owner_id = p_owner and ob.upfront_invoice_id is null and v.billing_case in ('managed', 'self_managed')
       and ob.status in ('terms_set', 'documents_sent', 'documents_signed')
       and exists (select 1 from vehicle_schedules s where s.vehicle_id = v.id and s.superseded_by is null)
       and (p_vehicles is null or v.id = any (p_vehicles))
     order by v.created_at, v.id
  loop
    v_inv := app.issue_upfront_invoice(r.id, p_admin);
    update owner_invoices set status = 'issued' where id = v_inv;
    v_out := v_out || jsonb_build_array((select jsonb_build_object('vehicle_id', i.vehicle_id, 'invoice_id', i.id, 'invoice_number', i.invoice_number,
                                                 'fees_cents', i.fees_cents, 'hst_cents', i.hst_cents, 'total_cents', i.total_cents)
                                           from owner_invoices i where i.id = v_inv));
  end loop;
  return v_out;
end $$;

-- ================================================================ wrappers for the server (service_role only)
create or replace function public.server_owner_program_facts() returns jsonb
language sql stable security invoker set search_path = public, app as $$ select app.owner_program_facts() $$;
create or replace function public.server_onboarding_options(p_held_by text, p_title_status text, p_mode text default 'managed') returns jsonb
language sql stable security invoker set search_path = public, app as $$ select app.onboarding_options_json(p_held_by, p_title_status, p_mode) $$;
create or replace function public.server_vin_lookup(p_vin text) returns jsonb
language sql stable security invoker set search_path = public, app as $$ select app.vin_lookup(p_vin) $$;
create or replace function public.server_record_vin_decode(p_vin text, p_provider text, p_output jsonb) returns jsonb
language sql volatile security invoker set search_path = public, app as $$ select app.record_vin_decode(p_vin, p_provider, p_output) $$;
create or replace function public.server_draft_resume_link(p_draft uuid, p_email text, p_user uuid default null, p_token text default null) returns text
language sql volatile security invoker set search_path = public, app as $$ select app.request_draft_resume_link(p_draft, p_email, p_user, p_token) $$;
create or replace function public.server_resume_form_draft(p_link_token text, p_user uuid default null, p_device_label text default null) returns jsonb
language sql volatile security invoker set search_path = public, app as $$ select app.resume_form_draft(p_link_token, p_user, p_device_label) $$;
create or replace function public.server_send_link_email(p_email text, p_name text, p_url text, p_expiry text default null, p_key text default null) returns bigint
language sql volatile security invoker set search_path = public, app as $$ select app.send_link_email(p_email, p_name, p_url, p_expiry, p_key) $$;
create or replace function public.server_submit_owner_application(p jsonb, p_by uuid default null) returns jsonb
language sql volatile security invoker set search_path = public, app as $$ select app.submit_owner_application(p, p_by) $$;

create or replace function public.owner_portal_home(p_by uuid) returns jsonb
language sql stable security invoker set search_path = public, app as $$ select app.owner_portal_home(p_by) $$;
create or replace function public.owner_portal_invoice(p_by uuid, p_number text) returns jsonb
language sql stable security invoker set search_path = public, app as $$ select app.owner_portal_invoice(p_by, p_number) $$;
create or replace function public.owner_portal_statement(p_by uuid, p_statement uuid) returns jsonb
language sql stable security invoker set search_path = public, app as $$ select app.owner_portal_statement(p_by, p_statement) $$;
create or replace function public.owner_portal_documents(p_by uuid) returns jsonb
language sql stable security invoker set search_path = public, app as $$ select app.owner_portal_documents(p_by) $$;
create or replace function public.owner_portal_document(p_by uuid, p_document uuid) returns jsonb
language sql stable security invoker set search_path = public, app as $$ select app.owner_portal_document(p_by, p_document) $$;
create or replace function public.owner_portal_forms(p_by uuid) returns jsonb
language sql stable security invoker set search_path = public, app as $$ select app.owner_portal_forms(p_by) $$;
create or replace function public.owner_portal_bookings(p_by uuid, p_from timestamptz default null, p_to timestamptz default null) returns jsonb
language sql stable security invoker set search_path = public, app as $$ select app.owner_portal_bookings_json(p_by, p_from, p_to) $$;
create or replace function public.owner_save_profile(p_by uuid, p jsonb) returns jsonb
language sql volatile security invoker set search_path = public, app as $$ select app.owner_save_profile(p_by, p) $$;
create or replace function public.owner_submit_payout_account(p_by uuid, p jsonb) returns uuid
language sql volatile security invoker set search_path = public, app as $$ select app.submit_payout_account(app.portal_owner_id(p_by), p_by, p) $$;
create or replace function public.owner_give_exit_notice(p_by uuid, p_vehicle uuid, p jsonb default '{}') returns jsonb
language sql volatile security invoker set search_path = public, app as $$ select app.give_exit_notice(p_vehicle, p_by, p) $$;
create or replace function public.owner_withdraw_exit_notice(p_by uuid, p_exit uuid) returns void
language sql volatile security invoker set search_path = public, app as $$ select app.withdraw_exit_notice(p_exit, p_by) $$;
create or replace function public.owner_book_own_vehicle(p_by uuid, p_vehicle uuid, p_pickup timestamptz, p_return timestamptz, p_note text default null) returns uuid
language sql volatile security invoker set search_path = public, app as $$ select app.owner_book_own_vehicle(p_by, p_vehicle, p_pickup, p_return, p_note) $$;
create or replace function public.owner_id_for(p_by uuid) returns uuid
language sql stable security invoker set search_path = public, app as $$ select app.portal_owner_id(p_by) $$;

create or replace function public.server_owner_agreement_facts(p_owner uuid, p_by uuid) returns jsonb
language sql stable security invoker set search_path = public, app as $$ select app.owner_agreement_facts(p_owner, p_by) $$;
create or replace function public.owner_open_agreements(p_owner uuid, p_by uuid, p_docs jsonb) returns jsonb
language sql volatile security invoker set search_path = public, app as $$ select app.owner_open_agreements(p_owner, p_by, p_docs) $$;
create or replace function public.owner_sign_agreements(p_owner uuid, p_by uuid, p jsonb) returns jsonb
language sql volatile security invoker set search_path = public, app as $$ select app.owner_sign_agreements(p_owner, p_by, p) $$;
create or replace function public.server_attach_owner_signed_copy(p_request uuid, p_path text, p_sha256 text) returns uuid
language sql volatile security invoker set search_path = public, app as $$ select app.attach_owner_signed_copy(p_request, p_path, p_sha256) $$;

create or replace function public.server_owner_invoice_payment_facts(p_invoice uuid, p_by uuid) returns jsonb
language sql stable security invoker set search_path = public, app as $$ select app.owner_invoice_payment_facts(p_invoice, p_by) $$;
create or replace function public.server_owner_invoice_id(p_number text) returns uuid
language sql stable security invoker set search_path = public, app as $$
  select id from owner_invoices where invoice_number = upper(btrim(p_number)) $$;
create or replace function public.server_record_owner_invoice_payment(p_invoice uuid, p jsonb, p_by uuid default null) returns jsonb
language sql volatile security invoker set search_path = public, app as $$ select app.record_owner_invoice_payment(p_invoice, p, p_by) $$;

create or replace function public.admin_gate(p_user uuid) returns jsonb
language sql stable security invoker set search_path = public, app as $$ select app.admin_gate(p_user) $$;
create or replace function public.admin_owner_applications(p_admin uuid) returns jsonb
language sql stable security invoker set search_path = public, app as $$ select app.admin_owner_applications(p_admin) $$;
create or replace function public.admin_owner_detail(p_admin uuid, p_owner uuid) returns jsonb
language sql stable security invoker set search_path = public, app as $$ select app.admin_owner_detail(p_admin, p_owner) $$;
create or replace function public.admin_owner_invoices(p_admin uuid, p_status text default null) returns jsonb
language sql stable security invoker set search_path = public, app as $$ select app.admin_owner_invoices(p_admin, p_status) $$;
create or replace function public.admin_set_vehicle_terms(p_vehicle uuid, p_admin uuid, p_terms jsonb default '{}') returns jsonb
language sql volatile security invoker set search_path = public, app as $$ select app.admin_set_vehicle_terms(p_vehicle, p_admin, p_terms) $$;
create or replace function public.admin_approve_vehicle_terms(p_vehicle uuid, p_admin uuid, p_approve boolean default true) returns jsonb
language sql volatile security invoker set search_path = public, app as $$ select app.admin_approve_vehicle_terms(p_vehicle, p_admin, p_approve) $$;
create or replace function public.admin_issue_upfront_invoices(p_owner uuid, p_admin uuid, p_vehicles uuid[] default null) returns jsonb
language sql volatile security invoker set search_path = public, app as $$ select app.admin_issue_upfront_invoices(p_owner, p_admin, p_vehicles) $$;
create or replace function public.admin_record_owner_offline_payment(p_invoice uuid, p_admin uuid, p jsonb) returns jsonb
language sql volatile security invoker set search_path = public, app as $$ select app.record_owner_offline_payment(p_invoice, p_admin, p) $$;

-- ================================================================ privileges
do $$
declare
  f record;
begin
  for f in
    select p.oid::regprocedure as sig, n.nspname from pg_proc p join pg_namespace n on n.oid = p.pronamespace
     where (n.nspname = 'app' and p.proname = any (array[
              'owner_program_facts', 'onboarding_options_json', 'vin_lookup', 'record_vin_decode', 'send_link_email',
              'owner_portal_home', 'owner_portal_invoices', 'owner_invoice_view', 'owner_portal_invoice', 'owner_portal_statement',
              'statement_line_json', 'owner_portal_document', 'owner_portal_forms', 'owner_portal_bookings_json', 'owner_save_profile',
              'owner_signing_needed', 'owner_agreement_facts', 'owner_open_agreements', 'owner_sign_agreements', 'attach_owner_signed_copy',
              'owner_invoice_payment_facts', 'owner_invoice_apply_payment', 'record_owner_invoice_payment', 'record_owner_offline_payment',
              'admin_gate', 'assert_admin', 'admin_owner_applications', 'admin_owner_detail', 'admin_owner_invoices',
              'admin_set_vehicle_terms', 'admin_approve_vehicle_terms', 'admin_issue_upfront_invoices']))
        or (n.nspname = 'public' and p.proname = any (array[
              'server_owner_program_facts', 'server_onboarding_options', 'server_vin_lookup', 'server_record_vin_decode',
              'server_draft_resume_link', 'server_resume_form_draft', 'server_send_link_email', 'server_submit_owner_application',
              'owner_portal_home', 'owner_portal_invoice', 'owner_portal_statement', 'owner_portal_documents', 'owner_portal_document',
              'owner_portal_forms', 'owner_portal_bookings', 'owner_save_profile', 'owner_submit_payout_account', 'owner_give_exit_notice',
              'owner_withdraw_exit_notice', 'owner_book_own_vehicle', 'owner_id_for',
              'server_owner_agreement_facts', 'owner_open_agreements', 'owner_sign_agreements', 'server_attach_owner_signed_copy',
              'server_owner_invoice_payment_facts', 'server_owner_invoice_id', 'server_record_owner_invoice_payment',
              'admin_gate', 'admin_owner_applications', 'admin_owner_detail', 'admin_owner_invoices', 'admin_set_vehicle_terms',
              'admin_approve_vehicle_terms', 'admin_issue_upfront_invoices', 'admin_record_owner_offline_payment']))
  loop
    execute format('revoke all on function %s from public, anon, authenticated', f.sig);
    execute format('grant execute on function %s to service_role', f.sig);
  end loop;
end $$;
