# Address autofill everywhere; every official form field accounted for (no migration)

Release 21b, item 8. Code: `web/src/features/manual/SignRequests.tsx`, `web/src/features/referral/PartnerSignupForm.tsx`,
`web/src/features/forms/address-coverage.test.ts`, `web/src/features/official-forms/not-mapped.ts` (and its test in
`official.test.ts`), `web/src/features/blindspot/boxes.ts` and `boxes.test.ts`.

- Address lookup: the two address fields without it now have it: a staff or investor agreement's Home address (Admin >
  agreements to sign) and the referral partner sign-up (Find your business address fills the street, city and postal code).
  `address-coverage.test.ts` fails on a form with a street-address input and no lookup, and on an address column of a field
  list that is not of type address.
- ServiceOntario forms (SR-LV-006, SR-LV-012, ON00453, 013-0169, 013-1155): every field of the publisher's PDF is either
  mapped (0122) or listed in `not-mapped.ts` with the reason it is left empty (checkboxes and signatures done at the
  counter, sections that do not apply, office use, the mailing address when it is the same). The test fails on a field that
  is neither, on a rule that matches nothing and on a rule that matches a mapped field. No field with data on record was
  found unmapped.
- Blind Spot's form (no fillable fields; drawn box by box): `boxes.ts` lists every box layout.ts draws, what fills it, the
  signature and initial boxes, and the boxes left blank on purpose with the reason. The test fails on a box drawn that is
  not on the list, on a box neither drawn (a value or N/A) in a sample booking nor blank on purpose, and on a "blank" box
  that is drawn.

## Guides

No guide change: the address lookup fills the same fields the guides already name.
