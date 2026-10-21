-- 0079: the audit fixes of October 21, 2026 (docs/changes/2026-10-21-audit-fixes.md).
--   1. The company address: Program settings had none, so the owner Enrollment Agreement's notice clause, the staff and
--      investor agreements and the ServiceOntario registry context printed no CarmaCars address. The owner's mailing
--      address goes in Program settings, and those four read app.company_address() (Program settings, else the site's
--      mailing address). The street address gets its postal code.
--   2. Every real car has its listing row from the moment it is added (a draft until it is published), so it shows in
--      Admin > Cars > Listings with Publish now. Real cars added before 0070 without one get it now (none expected live).
--   3. The commission base: commissions and kickbacks apply only to the rental charge after discounts, before tax; never
--      to delivery, kilometres, add-ons or anything else bought; late extra days count. A refund now comes off the base
--      only for the part of it that refunds the rental charge.
--   4. Add-on photos: a studio illustration for each of the 9 add-ons (web/public/addon-photos), replaceable in Admin.
--   5. The guides of releases 0070 and 0071 (and this one).

-- ================================================================ 1. the company address
update program_settings set company_address = '2967 Dundas St W, Unit 208B, Toronto, ON M6P 1Z2'
 where nullif(btrim(company_address), '') is null;
-- the street address with its postal code (Canada Post: 1570 Midland Ave, Scarborough, M1P 3C3); it will change
update site_settings set street_address = '1570 Midland Ave, Toronto, ON M1P 3C3'
 where singleton and street_address = '1570 Midland Ave, Toronto, ON';

-- The address CarmaCars' documents print: Program settings, else the site's mailing address.
create or replace function app.company_address() returns text
language sql stable security definer set search_path = public, app as $$
  select coalesce(nullif(btrim((app.settings()).company_address), ''),
                  (select nullif(btrim(ss.mailing_address), '') from site_settings ss where ss.singleton limit 1))
$$;
revoke all on function app.company_address() from public, anon, authenticated;
grant execute on function app.company_address() to service_role;

-- The four documents that read Program settings' address with no fallback (the rest of each body unchanged).
CREATE OR REPLACE FUNCTION app.owner_agreement_facts_0029(p_owner uuid, p_by uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'app'
AS $function$
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
    'company', jsonb_build_object('trade_name', ps.company_trade_name, 'address', app.company_address(), 'email', ps.company_email,
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
end $function$

;

CREATE OR REPLACE FUNCTION app.staff_agreement_prepare_0057(p_by uuid, p_user uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'app'
AS $function$
declare
  u users;
  sp staff_profiles;
  s program_settings := app.settings();
  v_defaults jsonb;
begin
  perform app.assert_admin(p_by);
  select * into u from users where id = p_user;
  select * into sp from staff_profiles where user_id = p_user;
  if u.id is null or sp.user_id is null then raise exception 'Staff member not found' using errcode = 'P0002'; end if;
  v_defaults := case when sp.staff_type = 'va'
                     then (coalesce(s.staff_agreement_defaults -> 'va', '{}'::jsonb) - 'by_function')
                          || coalesce(s.staff_agreement_defaults #> array['va', 'by_function', sp.va_function::text], '{}'::jsonb)
                     else coalesce(s.staff_agreement_defaults -> 'field', '{}'::jsonb) end;
  return jsonb_build_object(
    'staff', jsonb_build_object('user_id', u.id, 'full_name', coalesce(u.full_name, u.email), 'email', u.email, 'phone', u.phone, 'staff_type', sp.staff_type,
                                'va_function', sp.va_function, 'field_function', sp.field_function, 'started_on', sp.started_on, 'referral_code', sp.referral_code,
                                'single_limit_cents', sp.single_limit_cents, 'dual_approval_threshold_cents', sp.dual_approval_threshold_cents,
                                'has_signed', exists (select 1 from sign_requests r where r.staff_user_id = u.id and r.doc_type = 'staff_agreement' and r.status = 'signed')),
    'defaults', v_defaults,
    'company', jsonb_build_object('legal_name', s.company_legal_name, 'brand', coalesce(s.company_trade_name, 'CarmaCars'), 'address', app.company_address(),
                                  'email', s.company_email, 'phone', s.company_phone, 'signing_officer_name', s.signing_officer_name, 'signing_officer_title', s.signing_officer_title));
end $function$

;

CREATE OR REPLACE FUNCTION app.investor_agreement_prepare(p_by uuid, p_investor uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'app'
AS $function$
declare
  inv investors;
  a investment_agreements;
  s program_settings := app.settings();
begin
  perform app.assert_admin(p_by);
  select * into inv from investors where id = p_investor;
  if inv.id is null then raise exception 'Investor not found' using errcode = 'P0002'; end if;
  select * into a from investment_agreements where investor_id = inv.id and status in ('draft', 'sent', 'signed') order by created_at desc limit 1;
  if a.status = 'signed' then raise exception 'The agreement of % is already signed', inv.legal_name using errcode = '23514'; end if;
  if a.id is null then
    insert into investment_agreements (investor_id, agreement_number, status)
    values (inv.id, 'IA-' || nextval('investment_agreement_number_seq'), 'draft') returning * into a;
  end if;
  return jsonb_build_object(
    'investor', jsonb_build_object('id', inv.id, 'legal_name', inv.legal_name, 'investor_type', inv.investor_type, 'address', inv.address, 'email', inv.email,
                                   'phone', inv.phone, 'tax_resident_canada', inv.tax_resident_canada, 'tax_country', inv.tax_country, 'has_portal', inv.user_id is not null),
    'agreement_number', a.agreement_number,
    'investments', coalesce((select jsonb_agg(jsonb_build_object('principal_cents', i.principal_cents, 'yearly_bps', i.yearly_bps, 'investment_date', i.investment_date,
                                   'lockup_end_date', i.lockup_end_date, 'is_initial', i.is_initial) order by i.is_initial desc, i.investment_date)
                              from investments i where i.investor_id = inv.id and i.status not in ('cancelled', 'transferred')), '[]'::jsonb),
    'terms', jsonb_build_object('min_cents', s.investor_min_cents, 'lockup_months', s.investor_lockup_months),
    'company', jsonb_build_object('legal_name', s.company_legal_name, 'brand', coalesce(s.company_trade_name, 'CarmaCars'), 'address', app.company_address(),
                                  'email', s.company_email, 'phone', s.company_phone, 'signing_officer_name', s.signing_officer_name, 'signing_officer_title', s.signing_officer_title));
end $function$

;

CREATE OR REPLACE FUNCTION app.registry_context_0022(p_vehicle uuid)
 RETURNS jsonb
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'app'
AS $function$
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
      'address', app.company_address(), 'phone', ps.company_phone, 'email', ps.company_email,
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
$function$

;

-- ================================================================ 2. every real car has its listing row
-- Until 0079 the row was made only when someone first opened the listing, wrote its copy or published it, so cars added
-- before 0070's automatic publishing (the KIA Forte, the three Jettas, the CTS and the Macan on October 21) were in no
-- listing list and nothing prompted anyone. Now the row is made when the car is added: a draft, with Publish now.
create or replace function app.vehicle_listing_row() returns trigger
language plpgsql security definer set search_path = public, app as $$
begin
  if not coalesce(new.is_sample, false) then perform app.ensure_listing(new.id); end if;
  return null;
end $$;
drop trigger if exists vehicles_listing_row on vehicles;
create trigger vehicles_listing_row after insert on vehicles for each row execute function app.vehicle_listing_row();

-- A listing written in full for a car (an import, a sample car) replaces the empty draft made above, never a listing
-- anyone has worked on.
create or replace function app.vehicle_listing_replace_draft() returns trigger
language plpgsql security definer set search_path = public, app as $$
begin
  delete from vehicle_listings l
   where l.vehicle_id = new.vehicle_id and l.status = 'draft' and l.slug is null and l.first_published_at is null and l.published_at is null
     and l.publish_at is null and nullif(btrim(l.headline), '') is null and nullif(btrim(l.description), '') is null
     and cardinality(l.features) = 0 and l.faq = '[]'::jsonb and l.staff_note is null;
  return new;
end $$;
drop trigger if exists vehicle_listings_replace_draft on vehicle_listings;
create trigger vehicle_listings_replace_draft before insert on vehicle_listings for each row execute function app.vehicle_listing_replace_draft();
revoke all on function app.vehicle_listing_row() from public, anon, authenticated;
revoke all on function app.vehicle_listing_replace_draft() from public, anon, authenticated;

-- the real cars without one (retired and exited cars too: their listing stays a draft)
select app.ensure_listing(v.id) from vehicles v
 where not coalesce(v.is_sample, false) and not exists (select 1 from vehicle_listings l where l.vehicle_id = v.id);

-- ================================================================ 3. the commission base
-- The owner (October 19, 2026): "commissions / kickbacks are only collected on (daily rate revenue minus any
-- discounts), not on deliveries or extra kms"; October 21: the rental charge after discounts, before tax, excluding
-- delivery, kilometres, add-ons and anything else purchased; late extra days count.
-- Before 0079 every refund (except a removed add-on and a change's refund) came off the base in full, so a refunded
-- delivery or kilometre charge lowered the commission on money that was never in it. Now each refund says what it
-- refunds: a refund spread over the booking's lines (a cancellation, a removed add-on) counts only its rental lines; a
-- refund staff enter says what it is for (the rental charge, delivery or pickup, kilometres, add-ons, other charges); a
-- refund made by a change of booking whose new price is already in the booking counts nothing (it was counted twice).
alter table refunds add column if not exists refund_of text
  check (refund_of in ('rental', 'delivery', 'kilometres', 'addons', 'other_charges', 'booking_change'));
comment on column refunds.refund_of is 'What the refund gives back (0079): rental (the rental charge, the commission base), delivery, kilometres, addons, other_charges, or booking_change (made by a change of booking whose new price is already in the booking). Null on an older refund: treated as rental. A refund spread over line items (refund_allocations) is read from its lines instead.';

-- a change of booking's refund (app.calendar_apply_change and its earlier versions write it with this note)
create or replace function app.refund_kind_default() returns trigger
language plpgsql security definer set search_path = public, app as $$
begin
  if new.refund_of is null and new.reason = 'other' and coalesce(new.note, '') like 'Change of booking: %' then
    new.refund_of := 'booking_change';
  elsif new.refund_of is null and new.reason = 'addon_removed' then
    new.refund_of := 'addons';
  end if;
  return new;
end $$;
drop trigger if exists refunds_kind_default on refunds;
create trigger refunds_kind_default before insert on refunds for each row execute function app.refund_kind_default();
revoke all on function app.refund_kind_default() from public, anon, authenticated;
update refunds set refund_of = 'booking_change' where refund_of is null and reason = 'other' and coalesce(note, '') like 'Change of booking: %';
update refunds set refund_of = 'addons' where refund_of is null and reason = 'addon_removed';

-- The line items that make the commission base: the rental charge, its discounts and late extra days.
create or replace function app.commission_line_types() returns text[]
language sql immutable as $$ select array['rental_charge', 'non_refundable_discount', 'staff_discount', 'promo_discount', 'late_return_extra_days'] $$;

-- The part of one refund that gives back the rental charge, before tax.
create or replace function app.refund_rental_part_cents(p_refund uuid, p_hst_bps integer) returns bigint
language sql stable security definer set search_path = public, app as $$
  select case
    when exists (select 1 from refund_allocations ra where ra.refund_id = r.id) then
      (select coalesce(sum(ra.amount_cents), 0) from refund_allocations ra join booking_line_items li on li.id = ra.line_item_id
        where ra.refund_id = r.id and li.charge_type = any (app.commission_line_types()))
    when coalesce(r.refund_of, 'rental') = 'rental' then round(r.amount_cents * 10000.0 / (10000 + coalesce(p_hst_bps, 0)))
    else 0 end::bigint
    from refunds r where r.id = p_refund
$$;

-- Late extra days charged at the return (their own line, not in the booking's rental charge).
create or replace function app.late_extra_days_cents(p_booking uuid) returns bigint
language sql stable security definer set search_path = public, app as $$
  select coalesce(sum(li.amount_cents), 0)::bigint from booking_line_items li
   where li.booking_id = p_booking and li.charge_type = 'late_return_extra_days' and li.voided_at is null and li.charged_to_renter
$$;

-- Booked revenue and the commission base (0057, 0058) with the rule above.
create or replace function app.sales_revenue_cents(p_booking uuid) returns bigint
language plpgsql stable security definer set search_path = public, app as $$
declare
  b bookings;
  c booking_cancellations;
  v_net bigint;
  v_other bigint;
begin
  select * into b from bookings where id = p_booking;
  if b.id is null or b.confirmed_at is null then return 0; end if;
  v_net := greatest(b.rental_charge_cents - b.discount_cents - b.staff_discount_cents - b.promo_discount_cents, 0);
  if b.status = 'cancelled' then
    select * into c from booking_cancellations where booking_id = b.id;
    v_net := case when c.booking_id is null then 0 else round(v_net * (10000 - c.refund_bps) / 10000.0)::bigint end;
  end if;
  v_net := v_net + app.late_extra_days_cents(b.id);
  select coalesce(sum(app.refund_rental_part_cents(r.id, b.hst_bps)), 0)::bigint into v_other
    from refunds r
   where r.booking_id = b.id and r.status in ('approved', 'processing', 'paid')
     and r.id is distinct from c.refund_id
     and not (b.status = 'cancelled' and r.reason in ('cancellation', 'carmacars_cancelled'))
     and not exists (select 1 from booking_change_requests q where q.refund_id = r.id) and r.reason <> 'addon_removed'
     and coalesce(r.refund_of, '') <> 'booking_change';
  return greatest(v_net - v_other, 0);
end $$;

create or replace function app.commission_base_cents(p_booking uuid) returns bigint
language plpgsql stable security definer set search_path = public, app as $$
declare
  b bookings;
  v_net bigint;
  v_other bigint;
begin
  select * into b from bookings where id = p_booking;
  if b.id is null then return 0; end if;
  if b.confirmed_at is not null then return app.sales_revenue_cents(p_booking); end if;
  if b.status not in ('confirmed', 'on_rent', 'returned', 'closed') then return 0; end if;
  v_net := greatest(b.rental_charge_cents - b.discount_cents - b.staff_discount_cents - b.promo_discount_cents, 0) + app.late_extra_days_cents(b.id);
  select coalesce(sum(app.refund_rental_part_cents(r.id, b.hst_bps)), 0)::bigint into v_other
    from refunds r where r.booking_id = b.id and r.status in ('approved', 'processing', 'paid')
     and not exists (select 1 from booking_change_requests q where q.refund_id = r.id) and r.reason <> 'addon_removed'
     and coalesce(r.refund_of, '') <> 'booking_change';
  return greatest(v_net - v_other, 0);
end $$;
revoke all on function app.refund_rental_part_cents(uuid, integer) from public, anon, authenticated;
revoke all on function app.late_extra_days_cents(uuid) from public, anon, authenticated;
grant execute on function app.refund_rental_part_cents(uuid, integer) to service_role;
grant execute on function app.late_extra_days_cents(uuid) to service_role;

-- Staff say what a refund is for (Admin booking page and Finance): p.refund_of, kept on the refund.
create or replace function app.refund_of_check(p jsonb) returns text
language plpgsql immutable as $$
declare
  v text := nullif(btrim(coalesce(p ->> 'refund_of', '')), '');
begin
  if v is not null and v not in ('rental', 'delivery', 'kilometres', 'addons', 'other_charges') then
    raise exception 'Say what the refund is for: the rental charge, delivery or pickup, kilometres, add-ons or other charges' using errcode = '22023';
  end if;
  return v;
end $$;

alter function app.admin_do(uuid, text, jsonb) rename to admin_do_pre0079;
create or replace function app.admin_do(p_admin uuid, p_action text, p jsonb default '{}'::jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  v_of text;
  v_out jsonb;
begin
  if p_action <> 'request_refund' then return app.admin_do_pre0079(p_admin, p_action, p); end if;
  v_of := app.refund_of_check(p);
  v_out := app.admin_do_pre0079(p_admin, p_action, p);
  if v_of is not null and (v_out ->> 'id') is not null then update refunds set refund_of = v_of where id = (v_out ->> 'id')::uuid; end if;
  return v_out;
end $$;

alter function app.va_do(uuid, text, jsonb) rename to va_do_pre0079;
create or replace function app.va_do(p_user uuid, p_action text, p jsonb default '{}'::jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  v_of text;
  v_out jsonb;
begin
  if p_action <> 'request_refund' then return app.va_do_pre0079(p_user, p_action, p); end if;
  v_of := app.refund_of_check(p);
  v_out := app.va_do_pre0079(p_user, p_action, p);
  if v_of is not null and (v_out ->> 'id') is not null then update refunds set refund_of = v_of where id = (v_out ->> 'id')::uuid; end if;
  return v_out;
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
             join (values ('admin_do_pre0079', 'admin_do'), ('va_do_pre0079', 'va_do')) m(old_name, new_name) on m.old_name = p.proname
            where n.nspname = 'app' loop
    v_new := format('app.%I(%s)', r.new_name, r.args)::regprocedure;
    execute format('revoke all on function %s from public, anon, authenticated', v_new);
    foreach g in array array['anon', 'authenticated', 'service_role'] loop
      if has_function_privilege(g, r.oid, 'execute') then execute format('grant execute on function %s to %I', v_new, g); end if;
    end loop;
  end loop;
end $$;
revoke all on function app.refund_of_check(jsonb) from public, anon, authenticated;
grant execute on function app.refund_of_check(jsonb) to service_role;

-- ================================================================ 4. add-on photos
-- A studio illustration for each add-on, served by the site (web/public/addon-photos); an Admin's own photo replaces it
-- (Settings > Add-ons > Replace photo) and is never overwritten here.
update addons set photo_path = '/addon-photos/' || code || '.svg'
 where photo_path is null
   and code in ('flowers', 'baby_seat', 'child_seat', 'booster_seat', 'chauffeur', 'umbrella', 'phone_charger', 'full_tank', 'winter_tire');

-- ================================================================ 5. the guides of 0070, 0071 and this release
create or replace function app.guide_release_0079(p_portal text, p_slug text, p_kind text, p_after text, p_base_md text, p_title text, p_blurb text,
                                                  p_md text, p_html text) returns text
language sql security definer set search_path = public, app as $$
  select app.guide_release_section(p_portal, p_slug, p_kind, p_after, p_base_md, p_title, p_blurb, p_md, p_html)
$$;
revoke all on function app.guide_release_0079(text, text, text, text, text, text, text, text, text) from public, anon, authenticated;
grant execute on function app.guide_release_0079(text, text, text, text, text, text, text, text, text) to service_role;

-- GUIDES 0079 START (generated by supabase/seed/0079_gen_guides.mjs from docs/guides/content; do not edit by hand)
-- GUIDES 0079 END
