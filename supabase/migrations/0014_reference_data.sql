-- 0014_reference_data.sql
-- Reference data the platform cannot run without: program settings, the charge catalogue with
-- its admin defaults, the owner fee grid and onboarding estimates (information only), and the
-- message template codes. Every number comes from docs/source: renter_billing_spec.md section 1,
-- owner_billing_spec.md section 1 and Enrollment Agreement Schedule B. Admins change amounts by
-- adding a new dated row, never by editing history.

insert into program_settings (effective_from) values (date '2026-01-01');   -- column defaults carry the standard numbers

-- ---------------------------------------------------------------- charge catalogue (renter spec section 1)
-- change_default / change_vehicle / change_booking are the spec's D / V / B. in_master_spec = false is "Company*".
insert into fee_types (code, label, family, unit, per_what, revenue_class, hst_applies, hst_as_invoiced, stage,
                       refundable_by_tier, change_default, change_vehicle, change_booking, in_master_spec, sort_order) values
  ('rental_charge',           'Rental charge (daily, weekend, weekly or monthly rate)', 'rental', 'per_day', 'rental', 'owner_revenue', true,  false, 'booking',      true,  false, true,  true,  true,  10),
  ('non_refundable_discount', 'Non-refundable discount, 10% of the rental charge',     'rental', 'percent', 'rental', 'owner_revenue', true,  false, 'booking',      false, false, false, false, true,  20),
  ('deposit',                 'Deposit',                                                'deposit','flat',    'rental', null,            false, false, 'pickup',       false, true,  true,  true,  true,  30),
  ('delivery',                'Delivery',                                               'fee',    'flat',    'rental', 'company_only',  true,  false, 'booking',      true,  false, true,  true,  true,  40),
  ('pickup',                  'Pickup',                                                 'fee',    'flat',    'rental', 'company_only',  true,  false, 'booking',      true,  false, true,  true,  true,  50),
  ('young_driver_18_20',      'Young driver, 18 to 20',                                 'fee',    'per_day', 'driver', 'company_only',  true,  false, 'booking',      true,  true,  false, true,  true,  60),
  ('young_driver_21_25',      'Young driver, 21 to 25',                                 'fee',    'per_day', 'driver', 'company_only',  true,  false, 'booking',      true,  true,  false, true,  true,  70),
  ('additional_driver',       'Additional driver',                                      'fee',    'per_day', 'driver', 'company_only',  true,  false, 'booking',      true,  true,  false, true,  false, 80),
  ('winter_tire',             'Winter tire',                                            'fee',    'per_day', 'rental', 'company_only',  true,  false, 'booking',      true,  true,  false, true,  false, 90),
  ('baby_seat',               'Baby seat',                                              'fee',    'per_day', 'seat',   'company_only',  true,  false, 'booking',      true,  true,  false, true,  false, 100),
  ('coverage_sold',           'Coverage sold (Option 3)',                               'fee',    'flat',    'rental', 'company_only',  true,  false, 'booking',      true,  true,  true,  true,  true,  110),
  ('mileage_overage',         'Mileage overage',                                        'fee',    'per_km',  'km',     'owner_revenue', true,  false, 'check_in',     false, true,  true,  true,  true,  120),
  ('late_return_fee',         'Late return fee',                                        'fee',    'per_hour','rental', 'company_only',  true,  false, 'check_in',     false, true,  false, true,  true,  130),
  ('late_return_extra_days',  'Rental charge for extra days after a late return',       'rental', 'per_day', 'day',    'owner_revenue', true,  false, 'check_in',     false, true,  false, true,  true,  135),
  ('fuel',                    'Fuel: pump price plus 25%',                              'fee',    'at_cost', 'rental', 'company_only',  true,  false, 'check_in',     false, true,  false, true,  true,  140),
  ('recharging',              'Recharging: per 10% of battery',                         'fee',    'per_item','item',   'company_only',  true,  false, 'check_in',     false, true,  false, true,  true,  141),
  ('fuel_service_fee',        'Fuel or recharging service fee',                         'fee',    'flat',    'rental', 'company_only',  true,  false, 'check_in',     false, true,  false, true,  true,  142),
  ('cleaning',                'Cleaning',                                               'fee',    'flat',    'rental', 'company_only',  true,  false, 'check_in',     false, true,  false, true,  true,  150),
  ('cleaning_heavy',          'Cleaning, heavy soiling or odour',                       'fee',    'flat',    'rental', 'company_only',  true,  false, 'check_in',     false, true,  false, true,  true,  151),
  ('pet_cleaning',            'Pet cleaning',                                           'fee',    'flat',    'rental', 'company_only',  true,  false, 'check_in',     false, true,  false, true,  true,  160),
  ('smoking',                 'Smoking',                                                'fee',    'flat',    'rental', 'company_only',  true,  false, 'check_in',     false, true,  false, true,  true,  170),
  ('lost_key_cost',           'Lost key or fob: replacement cost',                      'pass_through','at_cost','item','pass_through', true,  false, 'after_return', false, false, false, true,  true,  180),
  ('lost_key_fee',            'Lost key or fob: fee',                                   'fee',    'flat',    'item',   'company_only',  true,  false, 'after_return', false, true,  false, true,  false, 181),
  ('toll_amount',             'Toll: amount',                                           'pass_through','at_cost','invoice','pass_through', false, false, 'after_return', false, false, false, true, true, 190),
  ('toll_admin_fee',          'Toll: administration fee per toll invoice',              'fee',    'flat',    'invoice','company_only',  true,  false, 'after_return', false, true,  false, true,  true,  191),
  ('ticket_amount',           'Ticket, fine, towing or impound: amount',                'pass_through','at_cost','item','pass_through', false, false, 'after_return', false, false, false, true,  true,  200),
  ('ticket_admin_fee',        'Ticket, fine, towing or impound: administration fee',    'fee',    'flat',    'item',   'company_only',  true,  false, 'after_return', false, true,  false, true,  true,  201),
  ('admin_fee_claim',         'Administration: fleet policy Damage claim',              'fee',    'flat',    'item',   'company_only',  true,  false, 'after_return', false, true,  false, true,  false, 210),
  ('admin_fee_other',         'Administration: other chargeable matter',                'fee',    'flat',    'item',   'company_only',  true,  false, 'after_return', false, true,  false, true,  false, 211),
  ('declined_payment',        'Declined payment',                                       'fee',    'flat',    'charge', 'company_only',  true,  false, 'on_decline',   false, true,  false, true,  false, 220),
  ('damage_at_cost',          'Damage under $2,500, at actual cost',                    'damage', 'at_cost', 'item',   'pass_through',  false, true,  'after_return', false, false, false, false, true,  230),
  ('deductible',              'Deductible',                                             'damage', 'flat',    'item',   'claim_funds',   false, false, 'after_return', false, false, false, false, true,  240),
  ('loss_of_use',             'Loss of use',                                            'damage', 'per_day', 'day',    'claim_funds',   false, false, 'after_return', false, false, false, false, true,  250),
  ('interest',                'Interest on overdue Charges',                            'fee',    'percent', 'charge', 'company_only',  false, false, 'monthly',      false, true,  false, false, false, 260),
  ('roadside_callout',        'Roadside call-out, renter''s cause: cost',               'pass_through','at_cost','item','pass_through', false, true,  'after_return', false, false, false, false, true,  270),
  ('recovery_cost',           'Recovery and repossession costs',                        'pass_through','at_cost','item','pass_through', false, true,  'after_return', false, false, false, false, true,  271),
  ('collection_cost',         'Collection and legal costs',                             'pass_through','at_cost','item','pass_through', false, true,  'after_return', false, false, false, false, true,  272),
  ('referral_kickback',       'Referral Kickback (deducted before Owner Revenue)',      'expense','percent', 'rental', 'booking_expense', false, false, 'split',     false, false, false, false, true,  300);

-- ---------------------------------------------------------------- admin defaults (D)
insert into fee_defaults (fee_type_code, vehicle_class, amount_cents, cap_cents, percent_bps, min_cents, max_cents, grace_minutes, note, effective_from) values
  ('deposit', 'economy',  50000, null, null, null, null, null, null, date '2026-01-01'),
  ('deposit', 'standard', 50000, null, null, null, null, null, null, date '2026-01-01'),
  ('deposit', 'premium', 100000, null, null, null, null, null, null, date '2026-01-01'),
  ('deposit', 'suv',     100000, null, null, null, null, null, null, date '2026-01-01'),
  ('deposit', 'luxury',  250000, null, null, null, null, null, null, date '2026-01-01'),
  ('deposit', 'exotic',  250000, null, null, null, null, null, null, date '2026-01-01'),
  ('delivery', null, null, null, null, 7500, 20000, null, 'set per vehicle, $75 to $200', date '2026-01-01'),
  ('pickup',   null, null, null, null, 7500, 20000, null, 'set per vehicle, $75 to $200', date '2026-01-01'),
  ('young_driver_18_20', null, 3500, 35000, null, null, null, null, 'per day, per driver; cap per rental', date '2026-01-01'),
  ('young_driver_21_25', null, 2000, 20000, null, null, null, null, 'per day, per driver; cap per rental', date '2026-01-01'),
  ('additional_driver',  null, 1000,  7000, null, null, null, null, 'per day, per driver; cap per rental', date '2026-01-01'),
  ('winter_tire',        null, 1500, 15000, null, null, null, null, 'per day; cap per rental', date '2026-01-01'),
  ('baby_seat',          null, 1200,  7000, null, null, null, null, 'per day, per seat; cap per rental', date '2026-01-01'),
  ('coverage_sold',      null, null,  null, null, null, null, null, 'price not set: cannot be sold until an admin sets it', date '2026-01-01'),
  ('mileage_overage',    null,   35,  null, null, null, null, null, 'per km', date '2026-01-01'),
  ('mileage_overage', 'luxury', null, null, null,   75,  150, null, 'per km, set per vehicle, $0.75 to $1.50', date '2026-01-01'),
  ('mileage_overage', 'exotic', null, null, null,   75,  150, null, 'per km, set per vehicle, $0.75 to $1.50', date '2026-01-01'),
  ('late_return_fee',    null, 2500,  null, 15000, null, null, 30, 'per started hour from the return time once over 30 minutes late; max 1.5 x daily rate per 24 hours', date '2026-01-01'),
  ('fuel',               null, null,  null,  2500, null, null, null, 'pump price plus 25%', date '2026-01-01'),
  ('recharging',         null, 1000,  null, null, null, null, null, 'per 10% of battery', date '2026-01-01'),
  ('fuel_service_fee',   null, 2500,  null, null, null, null, null, null, date '2026-01-01'),
  ('cleaning',           null, 7500,  null, null, null, null, null, null, date '2026-01-01'),
  ('cleaning_heavy',     null, 25000, null, null, null, null, null, null, date '2026-01-01'),
  ('pet_cleaning',       null, 15000, null, null, null, null, null, null, date '2026-01-01'),
  ('smoking',            null, 30000, null, null, null, null, null, null, date '2026-01-01'),
  ('lost_key_fee',       null, 5000,  null, null, null, null, null, 'plus replacement cost', date '2026-01-01'),
  ('toll_admin_fee',     null, 1500,  null, null, null, null, null, 'per toll invoice', date '2026-01-01'),
  ('ticket_admin_fee',   null, 4000,  null, null, null, null, null, 'per item', date '2026-01-01'),
  ('admin_fee_claim',    null, 7500,  null, null, null, null, null, null, date '2026-01-01'),
  ('admin_fee_other',    null, 5000,  null, null, null, null, null, null, date '2026-01-01'),
  ('declined_payment',   null, 4000,  null, null, null, null, null, 'once per charge; retries after 1, 3 and 7 days', date '2026-01-01'),
  ('deductible',         null, 250000, null, null, null, null, null, 'per incident', date '2026-01-01'),
  ('loss_of_use',        null, null,  null, null, null, null, null, 'daily rate per day out of service, max 30 days', date '2026-01-01'),
  ('interest',           null, null,  null,   150, null, null, null, '1.5% per month (19.56% per year), compounding monthly from 7 days after the statement', date '2026-01-01'),
  ('non_refundable_discount', null, null, null, 1000, null, null, null, 'fixed', date '2026-01-01'),
  ('referral_kickback',  null, null,  null,  2000, null, null, null, 'first rental only', date '2026-01-01');

-- ---------------------------------------------------------------- owner fee grid (starting point only)
insert into owner_fee_grid (min_vehicles, max_vehicles, insurance_fee_cents, revenue_share_bps, tracker_fee_cents, effective_from) values
  (1,  2,    45000, 3500, 2500, date '2026-01-01'),
  (3,  9,    40000, 3000, 2000, date '2026-01-01'),
  (10, null, 35000, 2500, 1500, date '2026-01-01');

-- ---------------------------------------------------------------- onboarding methods (information only; never billed by CarmaCars)
insert into onboarding_method_info (method, label, open_to, typical_items, estimate_cents, estimate_with_lien_cents, plus_tax, government_forms) values
  ('lease_existing_corporation', 'Lease, existing corporation', 'Corporation; not Leased',
     '[{"item": "Registration", "cents": 5000}]', 5000, null, false, array['SR-LV-006', 'SR-LV-012']),
  ('lease_new_owner_corporation', 'Lease, new Owner Corporation', 'Individual; not Leased',
     '[{"item": "Numbered corporation", "cents": 20000}, {"item": "Notarized letterhead", "cents": 10000}, {"item": "Registrant identification number", "cents": 5000}, {"item": "Safety", "cents": 15000}, {"item": "Tax exemption form", "cents": 1000}, {"item": "Sworn statement", "cents": 1000}, {"item": "Registration", "cents": 5000}]',
     57000, null, false, array['SR-LV-006', 'SR-LV-012', 'ON00453', '013-0169', '013-1155']),
  ('co_registrant', 'Co-Registrant', 'Individual; not Leased',
     '[{"item": "Registration", "cents": 5000}, {"item": "Safety", "cents": 15000}, {"item": "Appraisal", "cents": 5000}]',
     25000, null, true, array['SR-LV-006', 'SR-LV-012']),
  ('transfer', 'Transfer (the only method for a Leased Vehicle)', 'Any Vehicle',
     '[{"item": "Sign-back or registration", "cents": 5000}, {"item": "Safety", "cents": 15000}, {"item": "Appraisal", "cents": 5000}, {"item": "Optional Owner''s Lien if Owned Outright", "cents": 1000}]',
     25000, 26000, true, array['SR-LV-006', 'SR-LV-012']),
  ('none', 'None (Turo-Only)', 'Turo-Only', '[]', 0, null, false, array[]::text[]);

-- ---------------------------------------------------------------- message templates (wording: docs/source/operating_procedures.md)
insert into message_templates (code, purpose, audience) values
  ('T1', 'Quote', 'renter'), ('T2', 'Confirmed', 'renter'), ('T3', 'Verify', 'renter'), ('T4', 'Verified', 'renter'),
  ('T5', 'Pickup reminder', 'renter'), ('T6', 'Return reminder', 'renter'), ('T7', 'Findings', 'internal'),
  ('T8', 'Late-found damage', 'renter'), ('T9', 'Statement', 'renter'), ('T10', 'Declined payment', 'renter'),
  ('T11', 'Extension confirmed', 'renter'), ('T12', 'Cancellation', 'renter'), ('T13', 'Late, first', 'renter'),
  ('T14', 'Late, final', 'renter'), ('T15', 'Car disabled', 'renter'), ('T16', 'Accident', 'renter'),
  ('T17', 'Owner incident', 'owner'), ('T18', 'Breakdown', 'renter'), ('T19', 'Toll or ticket', 'renter'),
  ('T20', 'Owner intake', 'owner'), ('T21', 'Registry visit', 'owner'), ('T22', 'Enrolled', 'owner'),
  ('T23', 'Turo-Only expiry', 'owner'), ('T24', 'Owner invoice', 'owner'), ('T25', 'Missed payment', 'owner'),
  ('T26', 'Payout', 'owner');
