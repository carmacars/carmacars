# Every box of the Blind Spot agreement (0178)

The owner: "Every box needs to be filled out." With the HST account, and: the insurance boxes are "used in every
instance. When booking is using OPCF 27, their insurer details go there. When booking is using credit card coverage,
their coverage details go there (usually Assurant is the coverage provider for most credit cards). And when booking is
using rental coverage, that goes there as well."

## What changes
- **Box 1, HST registration number**: CarmaCars' GST/HST account `76339 9177 RT0001` is set in Program settings (only
  where it was blank), so every agreement prints it.
- **Boxes 12 (insurance company) and 13 (policy)** carry the coverage of every booking:
  - an insurance replacement rental: the insurer, its policy, province and expiry (as before, with the claim and adjuster);
  - OPCF 27: the renter's insurer and policy (as before);
  - card coverage: the coverage provider ("Assurant (credit card rental coverage)") and the card ("Visa card ending 4242");
  - the CarmaCars Protection Plan: "CarmaCars Protection Plan (rental coverage)" and its activation reference (else
    "With agreement RA-...");
  - insurance included with the car: said so in box 12.
- **The card coverage provider** is a new field of the coverage proof (`coverage_proofs.coverage_provider`). A booking
  on card coverage without it lists "Card coverage: the coverage provider (usually Assurant ...)" on its Agreement card,
  where staff fill it like the card issuer; it is required for check-out (an Admin can override with a reason, 0154).
  Filling it files a corrected copy of both agreements (not signed again: the coverage option itself is what is signed).
- The Admin's sample (Settings > Forms) is now a card-coverage booking, so it shows boxes 1, 12 and 13 filled.
- Unchanged and already automatic (0154): the pickup copy fills time out, K/M out and fuel out from the check-out; the
  closing copy fills time and date in, K/M in, driven, charged, fuel in, late hours, damages and the return charges from
  the check-in. The renter's cell phone is in box 3.
- **N/A in every box that does not apply** (the owner chose N/A over collecting more): P.O. number, home and office
  phone, employer, box 8 (new or temporary address), destination; boxes 10 and 11 without an additional driver; the
  replacement vehicle column without a swap; the insured vehicle, claim and adjuster when not an insurance replacement;
  box 13's province and expiry for card coverage, the plan and included insurance; and the charges not on the rental
  (underage, CDW, VLF, winter tires, LDW, T&LDW, PAP/PEC, Waiver Saver). A value the rental should have and lacks still
  stays blank, so the Agreement card asks for it; the pickup and return boxes fill on the pickup and closing copies.

## Guides
No guide change: the Agreement card already lists each missing field by its label; the coverage provider appears there
the same way, and no screen's steps change.
