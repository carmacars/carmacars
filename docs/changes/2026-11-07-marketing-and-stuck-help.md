# Sales Marketing tab and "Stuck?" help (migrations 0510, 0511)

## Why

The owner (November 2, 2026): "Sales should have access to the FB Marketplace listing tool and auto-responder setup, their
own marketing tab with everything you've given me, but make sure none of us are posting the exact same ad/copy twice. They
can use their own Claude with instructions, maybe in the academy." And: when someone stays on a page without getting
anywhere, offer them the guide and the Academy lesson for that page.

## What changed

### Sales > Marketing (`/staff/marketing`)

- The Sales menu's Marketplace link is now **Marketing** (still five links; `/staff/marketplace` redirects there).
- Today (take down, update the price, finish a claim, renew, post: within the person's own posts a day), the kit in the
  person's own copy variant with its photo ZIP (`/staff/marketing/photos/<car>?v=<n>`), the auto-reply steps and text,
  the inbox replies, **Log an inbox session** (numbers become leads assigned to the salesperson, with the 15-minute
  call-back task), **Your Claude in Chrome** (copyable instructions mirroring docs/runbooks/marketplace.md) and **My
  listings and log**.
- No ad twice: `marketplace_claims` per person, car and variant. Variant 1 is the owner's; the team claims 2 and up. Not
  ended, a claim's variant, title, description and cover are unique for the car (unique indexes); one listing of a car a
  person; at most `marketplace_max_live_per_car` (5) live a car, the owner's included. A claim not posted within a day
  ends; a listing ends `marketplace_listing_days` (30) after posting or renewal, or when taken down.
- `features/marketplace/variants.ts`: the variants (title, block order and closing lines, photo order and cover,
  `utm_content=v<n>`); every variant keeps "Daily and weekly bookings only, not for sale" and never says rent.
- Admin > Marketing > Marketplace: **The team's listings** (who posted what, status, end, address). The owner's own day
  counts his own posts only. The kit cards are one component (`KitCards.tsx`) for both pages.
- Settings > Program settings > Facebook Marketplace: the two new settings.

### "Stuck?" help in every portal

- `features/help/routes.ts`: every page under `web/src/app` maps to its guide chapter and Academy section (by route and
  tab), or is off (public pages, checkout, payment and signing steps). The unit test fails when a page has no entry or
  names a chapter or section that does not exist.
- `features/help/stuck.ts`: the detector (active with no successful action for the set minutes, the set number of
  validation errors, or back and forth between two steps). `StuckHelp.tsx` in the Admin, staff, field, owner, renter and
  investor frames shows "Need a hand with <page>?" with **Open the guide section** (a side panel, a bottom sheet on a
  phone, at that chapter; **Back to what I was doing** closes it with the page untouched), **Open the Academy lesson**
  (staff and Admin) and **Not now** (quiet on that page for a day).
- `/api/help`: the settings, a chapter's HTML, and the events (`help_stuck_events`). Settings > Program settings > Stuck?
  help: on or off, minutes (3), errors (3); **Where people get stuck** lists the pages it showed on most in 30 days.
- `Act` and `SaveForm` tell the help when an action worked or failed (`cc:progress`, `cc:error`).

## Guides

- `va/marketing-on-facebook-marketplace` (new), `va/start-here`
- `admin/advertising-and-owner-recruitment`, `admin/settings`, `admin/start-here`
- `field/start-here`, `owner/start-here`, `renter/start-here`, `investor/start-here`
- Academy: "Marketplace with your own Claude" (two lessons, five questions), last on both Sales paths. Published by
  0511 (`supabase/seed/0511_gen_guides.mjs`).

## Tests

- DB: `supabase/tests/99_marketing_team.sql` (claims, variants, the limit, expiry, the inbox credit, the help events
  and report, the Academy section).
- Unit: `features/marketplace/team.test.ts`, `features/help/help.test.ts`, `features/staff/nav.test.ts`.
- End to end: `web/tests/e2e/marketing-stuck.spec.ts` at 375 and 1440 with axe.

## Needs the owner

Nothing to set up. With the Academy gate on, Sales must pass the new section too.
