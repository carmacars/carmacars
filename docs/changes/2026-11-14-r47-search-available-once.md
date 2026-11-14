# The cars list for chosen dates loads again (Release 47: 2903)

Migration `2903_r47_search_available_once.sql`.

With dates chosen, /cars showed "Live availability is not loading" for every visitor. `public.search_available` priced each free car with `app.price_quote` and then read seven fields of that quote; Postgres copied the price_quote call into each read, so each car was priced seven times. About 120 cars took 3.5 s on an idle database and over 5 s on the live one, where the visitor's read is cancelled at 5 s (0111).

- The inner query is kept as its own step (`offset 0`), so each car is priced once. The answer is the same.
- The cars list and a car's calendar retry once, quietly, before a visitor is told anything did not load.
- On a phone, the menu (and the date pickers) locked scrolling on `<body>`; with the page clipped sideways, body became its own scroll box and the sticky header scrolled away under the open menu. They lock `<html>` now (`tests/e2e/menu-header.spec.ts`).
- Every booking page shows the deposit beside the status for every role (Sales could not easily tell whether a hold was taken): held with the amount and how, collected, no hold yet, failed, or waived (`web/src/features/money/deposit-words.ts`, `deposit-chip.test.ts`).
- Test: `supabase/tests/99_r47_search_once.sql` (price_quote runs once a car listed).

## Guides

No guide change: nothing a person does changes.
