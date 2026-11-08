-- 0851_r35r_investor_deck.sql
-- Release 35, part R (docs/changes/2026-11-08-r35-investor-deck.md). The owner, November 8: every investor-facing page
-- states the terms and numbers of the 2026 pitch deck, and the deck itself is live in the investor portal (/investor/deck,
-- its slides as responsive HTML, web/src/features/deck/pitch.ts).
--   1. The deck is shown to investors (Admin > Investors > Deck keeps the switch).
--   2. The Live sheets calculator starts, for an investor without an agreement, at the low end of the deck's Option 1
--      (10% a year), no longer at the older 30% offer. Each investor's own percentage stays the one in their agreement.
-- Only data changes; no function or table changes.
update deck_settings set show_to_investors = true, deck_return_bps = 1000, updated_at = now();
