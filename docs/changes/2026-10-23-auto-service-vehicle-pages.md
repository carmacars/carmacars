# The mechanical work we arrange on the per car pages (October 23, 2026)

Migration 0123. The owner: "Include them in the per car pages."

## What changed

- 0121 left the 20 terms of the mechanical work we arrange (mechanic, oil change, brake repair, tire change, tire shop, winter tires, tire repair, towing, car battery replacement, battery boost, wheel alignment, transmission repair, engine repair, car diagnostics, car inspection, safety certificate, emissions test, car AC repair, exhaust repair, suspension repair) out of the vehicle page trees. `app.vpage_terms` lists them again, so each has its tree like the other body shop terms: `/t/<term>/<make>/<model>/<year>/<trim>`, with its place and colour pages, under the "Index the body shop pages" switch, and in the vehicle sitemaps. Synonyms still have no tree.
- The pages say what the place pages say (`web/src/features/vehicles/twin.tsx`, `content.ts`): "CarmaCars does not do this work itself. Request it and we arrange it with a trusted shop or connect you with one, and we can deliver a rental car to you while yours is in." The rental offered is the one for a car in the shop (`/t/rental-car-while-car-is-in-the-shop/...`), not the insurance replacement. No questions (no FAQ block, no FAQPage), no price, no rating, no Service markup; the reply line says the shop sets its own price and time.
- The request ("Request it") is an `auto_service` place request (`public.submit_place_lead`, 0121): a lead with a "Mechanical work to arrange" task for customer service. It asks no marketing consent.
- Sitemaps: each tree's files are the same make and tier files as the /cars tree (each at most 50,000 addresses: `app.vpage_tier_shape` sizes the tier files by pairs per file, 0097), and the index pages hold 50,000 files each, so 20 more trees add files, never a larger file. The stored shape of the index (0110) is stamped with the trees as well as the Admin switches (`app.vehicle_sitemap_switches`, 0119's stamp): a term added, removed or switched off changes the stamp, and the shape is read live until the job stores it again. The migration stores it at once (`app.vehicle_sitemap_shape_refresh`), so the new trees are listed without a manual step. The stored page lists (0109) hold the /cars pages only and do not change.
- SCHEMA_MARKER 0123. The database types do not change (no function signature changed).

## Tests

Suite 78 (the trees, the switch, the index arithmetic, the stamp), a unit test of the page description, and the seo-coverage end-to-end test (a per car page, its request, its sitemap file).

## Guides

- `admin/search-car-pages-landing-pages-and-guides`: the mechanical work's per car pages. Published by migration 0123 (`supabase/seed/0123_gen_guides.mjs`).
