# r48-seo: where this branch stands (helper hand-over note)

Done and pushed on `r48-seo`:
- The Release 48 SEO overhaul (docs/changes/2026-11-20-r48-seo.md).
- Follow-up, Nov 20: tracker pricing (owners free; free for the first 100 pre-orders said publicly, real cap 250 in
  `tracker_free_preorder_cap`; $90 pre-order; $175 after launch; $150 install), all Program settings in migration 3231;
  pages, Product JSON-LD (one Offer, PreOrder), waitlist form with the owner box, tier and owner flag on the lead,
  confirmation email, llms.txt, guides, academy, What's new, tests. Privacy policy names the `cc_src` cookie (3230).
- Checked: tsc, eslint, unit tests, DB suite 99_r48seo_leads_trackers (89 pass on a fresh database), e2e r48-seo.spec.ts
  against `next dev` (8 at 375; the 5 tracker tests at 1440). No `next build` (memory).

- Monthly service restored for everyone (owner confirmed): $25/$20/$15 a car by number of cars, shown beside the tracker
  price and install everywhere. If this line is the last thing here, re-run tsc and the fresh-database run of
  supabase/tests/99_r48seo_leads_trackers.sql to confirm, then report the head SHA.

Next steps: none for the build. Open questions for the owner are listed in section 4 of the change doc
("For the owner to confirm"). Delete this file before the branch is merged if it is not wanted in the repo.
