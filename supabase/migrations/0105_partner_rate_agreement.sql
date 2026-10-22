-- 0105: the partner agreement on the partner's own rates (0093's partner_rate basis, 01 Motors).
--
-- The agreement (web/src/features/partner/agreement.ts, partner-v3-2026-10-22) describes the commercial basis a
-- partner on its own rate sheet is actually paid on: the renter pays the sheet rate plus the markup, CarmaCars keeps
-- the markup plus its cut of the sheet rate, and the partner is paid the rest of its sheet rate per completed rental.
-- Its facts now carry the payout basis, the partner's markup and each car's sheet rates and markup, so the cars table
-- shows the guideline rates the agreement refers to. Each car's name carries its colour, so two cars of one model on the
-- sheet (the C43 AMG in blue, white and grey) are told apart. A partner on the renter_price basis gets the same agreement as
-- before (the new fields are ignored).

create or replace function app.partner_agreement_facts(p_owner uuid) returns jsonb
language sql stable security definer set search_path = public, app as $$
  select jsonb_build_object('owner_id', r.owner_id, 'partner_id', r.id, 'partner_number', r.partner_number,
    'partner', jsonb_build_object('business_name', r.business_name, 'legal_name', coalesce(r.legal_name, r.business_name),
                                  'signer_name', coalesce(r.contact_name, r.legal_name, r.business_name), 'signer_title', r.contact_title,
                                  'address', concat_ws(', ', nullif(r.address_line1, ''), nullif(r.city, ''), nullif(r.province, ''), nullif(r.postal_code, '')),
                                  'email', r.email, 'phone', r.phone, 'hst_number', r.hst_number),
    'commission_bps', coalesce(r.commission_bps, (app.settings()).partner_commission_bps),
    'payout_basis', r.payout_basis,
    'markup_bps', coalesce(r.markup_bps, (app.settings()).partner_markup_bps),
    'insurance', jsonb_build_object('company', r.insurance_company, 'policy', r.insurance_policy, 'expiry', r.insurance_expiry),
    'payout_day', (select extract(day from app.payout_date(app.month_start(app.today())))::integer),
    'cars', coalesce((select jsonb_agg(jsonb_build_object('name', app.vehicle_name(v.id) || coalesce(', ' || nullif(btrim(v.colour), ''), ''), 'plate', v.plate, 'vin', v.vin,
                        'commission_bps', app.partner_commission_bps(v.id), 'markup_bps', app.partner_markup_bps(v.id),
                        'sheet', case when pr.vehicle_id is not null then jsonb_build_object('base_cents', pr.base_cents,
                                   'multi_day_cents', pr.multi_day_cents, 'long_term_cents', pr.long_term_cents) end)
                        order by v.make, v.model, app.vehicle_name(v.id), v.colour)
                      from vehicles v left join partner_rates pr on pr.vehicle_id = v.id
                     where v.partner_id = r.id and v.retired_at is null), '[]'::jsonb),
    'company', app.doc_company_brand())
    from partners r where r.owner_id = p_owner
$$;
