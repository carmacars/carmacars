# Insurers' adjusters, and what was billed by class, car and adjuster (0234)

The owner: "it'll be a different contact for each adjuster ... an option to add an adjuster and insurance company and they
get added to our database and that helps build a ratesheet of everything we've billed to each insurance company by class
and by car".

- `insurer_adjusters` (insurer, name, email, phone, notes). A booking keeps its adjuster (`insurer_adjuster_id`) and the
  details it was billed under (0016's columns). Every way a booking gets an adjuster adds or finds them (a trigger: within
  the insurer, by email, else by name; the latest email and phone kept); one picked by id fills the booking's details.
- The booking's Insurance claim card: the insurer picked or added by name; the adjuster picked from the insurer's saved
  ones or added. Add a rental: Saved adjuster fills the fields.
- Existing bookings' adjusters were added (deduplicated per insurer by email, else name); the bookings keep their text.
- An insurer invoice goes to the booking's adjuster (email and name), else the insurer's billing email, which is optional.
- Insurer rates: Billed by insurer and class. An insurer's page: Charged by class, Billing by car, Billing by adjuster
  (bookings, days, average daily rate, rental, each charge such as VLF and LDW, HST, the insurer's total, billed,
  outstanding), the bookings with car, adjuster and charges, and Adjusters (Add, Change).
- Tests: `supabase/tests/99_release_23.sql` section 8.

## Guides

- `admin/insurance-replacements-rates-and-billing`: Adjusters, What was billed.
