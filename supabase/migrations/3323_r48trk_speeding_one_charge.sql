-- 3323 (release 48, part TRK; docs/changes/2026-11-20-r48-tracker-alerts.md): one speeding event is one charge.
-- The owner (Nov 20) confirmed that a speeding event bills only the highest limit passed: 226 km/h is the charge over 220
-- km/h ($1,000), not that and the charge over 180. Rental agreement 10.5 and the three Fee Schedule lines say so now
-- (docs/source/v2_rental.md, a new text version in web/src/features/agreement/source.generated.ts; agreements already
-- signed keep theirs), and the new wording is published to accept: the "We've updated our terms" pop-up (0721, 3198)
-- opens once for every renter. The notice words (3320), the guides and the academy (3322) say the same. SCHEMA_MARKER 3323.
insert into terms_versions (doc_key, version, title, summary, body, body_sha256, requires_acceptance, published_by)
select 'rental_agreement', 'rental-v3-r48trk', 'Rental agreement',
       'Speeding charges, made clearer: one speeding event is one charge, at the highest limit reached ($500 over 180 km/h, $1,000 over 220, $2,500 over 300). The limits are not added together.',
       x.body, encode(sha256(convert_to(x.body, 'UTF8')), 'hex'), true, app.system_admin()
  from (values (E'10.5 Speeding charges. Driving faster than 180 km/h is never allowed. If the Tracker records the Vehicle above 180 km/h, 220 km/h or 300 km/h during the Rental Period, you owe one speeding charge for that event, at the highest limit reached, in the Fee Schedule (Part 3): one event is one charge. An event is the readings above 180 km/h within 30 minutes of each other; a later event is a new charge. The Tracker''s record is the evidence (section 12.2), and we give you its time, place and speed with the charge. We take the charge from the Deposit first, then from the Card on File (section 5).\n\nFee Schedule: speeding charge, $500 when the highest limit reached is 180 km/h, $1,000 when it is 220 km/h, $2,500 when it is 300 km/h.')) x(body)
on conflict (doc_key, version) do nothing;

comment on column program_settings.speeding_180_fee_cents is 'Speeding charge when the highest limit a speeding event reached is 180 km/h (3102, 3323), before HST: one event is one charge, billed from the deposit (rental agreement 10.5)';
comment on column program_settings.speeding_220_fee_cents is 'Speeding charge when the highest limit a speeding event reached is 220 km/h (3102, 3323), before HST: one event is one charge, billed from the deposit (rental agreement 10.5)';
comment on column program_settings.speeding_300_fee_cents is 'Speeding charge when the highest limit a speeding event reached is 300 km/h (3102, 3323), before HST: one event is one charge, billed from the deposit (rental agreement 10.5)';
