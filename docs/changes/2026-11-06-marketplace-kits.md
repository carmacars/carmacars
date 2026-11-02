# Facebook Marketplace kits, and the investor deck and video brought up to date (0410, 0411)

Release 27. The owner's decision (October 24, 2026) is to use Meta's built-in Marketplace auto-replies, and to have Claude
post the listings and answer the Marketplace inbox through his own Chrome. Listings go up from his personal profile,
because business Pages cannot post vehicles to Marketplace. Before this release the server only wrote text ready to paste.
The investor deck and the video script are also updated to match the platform as it is today.

Migrations: `supabase/migrations/0410_marketplace_kits.sql` and `0411_marketplace_guides.sql` (made by
`supabase/seed/0411_gen_guides.mjs`). Code: `web/src/features/marketplace/` (`kit.ts`, `plan.ts`, `replies.ts`,
`MarketplaceView.tsx`, `CopyValue.tsx`), `web/src/app/admin/marketing/marketplace/` (the page and `photos/[vehicle]`, the
ZIP), and the booking request (`schema.ts`, `RequestWizard.tsx`, `server/actions/booking.ts`). The playbook is
`docs/runbooks/marketplace.md`. Tests: `supabase/tests/99_marketplace_kits.sql`,
`web/src/features/marketplace/marketplace.test.ts` and `web/tests/e2e/marketplace.spec.ts` (axe at 375 and 1440).

## 1. Marketplace kits (Admin > Marketing > Marketplace)

- **A kit for every published car**, built when the page opens from the car's record (`app.ads_facts` of 0167 and the
  extra facts of `app.marketplace_read`), so its prices are always today's. A kit holds:
  - the vehicle form's fields in order: Car/Truck, location, year, make, model and trim, mileage (the highest odometer
    reading rounded up to the next thousand), the daily rate in whole dollars, body style, colours, condition, fuel and
    transmission;
  - a description in Marketplace style. It opens "Book this <car> by the day, from $X/day." and then "Daily and weekly
    bookings only, not for sale.", says "Free this weekend: drive it today." when the car is free, and gives the rates,
    km, delivery, coverage, requirements, deposit, the tracked link and "message your phone number";
  - a second version without the link;
  - the 10 best photos: the cover first, then the shots buyers look for, never a sample. **Download the photos (ZIP)**
    names them 01 to 10;
  - the link, tagged `utm_source=fb_marketplace&utm_medium=marketplace&utm_campaign=<car code>`.
  A car that is not taking requests, has no daily rate, or has only sample photos says **Do not post yet**.
- **The rotation** (`plan.ts`). **Today** shows price updates and take-downs first; they are always due and do not count
  toward the day. Then it shows up to `marketplace_posts_per_day` (4) new posts and renewals. New posts come first, our
  own and co-hosted cars before partner cars. Renewals come `marketplace_renew_days` (7) after a car was posted or last
  renewed. Anything posted or renewed today counts. **Coming up** shows the next 7 days. The settings are under
  **Rotation settings** and in Program settings.
- **Logging** (`admin_do marketplace_log`): **Posted**, **Renewed**, **Updated** or **Taken down**.
  - Posted and Updated go through 0167's `ad_posting_save`, so there is one live Marketplace ad per car, and a later
    price change opens the usual `ad_update` task and marks the listing **Update the price**.
  - Posting a car again under a new address ends the old ad.
  - `ad_postings.renewed_on` holds the last renewal.
  - Each action is a row in `marketplace_log`.
- **Inbox replies for this car** (`replies.ts`): "is this available", price, availability, requirements, deposit,
  delivery, "send your number", and a reply for after they send it. Each is filled in for the car and ends with the
  link (with `utm_content=reply`) or a request for a phone number.
- **Log an inbox session** (`admin_do marketplace_inbox`): the chats and replies, plus the numbers collected, one per
  line (`name, phone, car code`).
  - Each new number becomes a lead: kind `contact`, source and `utm_source` `fb_marketplace`, and the car code as the
    campaign.
  - Each new lead gets a `marketplace_callback` task for customer service, due in 15 minutes.
  - The same number within 30 days is the same lead.
- The **tiles** show live listings, what is left today, this week's chats and numbers, and the last 30 days'
  Marketplace requests and call-back leads.
- Marketing now opens on Marketplace, which is the first tab and the first item in the menu.

## 1b. No "rent" on Marketplace (the owner, November 1, 2026)

Nothing a buyer reads on Marketplace says "rent", "rental" or "for rent". The kit title is "Book this <car> by the day,
from $X/day", the description keeps the line "Daily and weekly bookings only, not for sale", the Price box is the price
for one day, and the requirements say "To book" and "a credit card with collision damage cover". The replies say "book
by the day or week (not for sale)" and "Longer bookings cost less a day", and the auto-reply text in the runbook was
changed the same way. The Facebook Marketplace text on Listings (0167, `writeListing`) follows the same rule: its title
and first line changed, and "Rentals up to" reads "Bookings up to". Kijiji, Craigslist and the other channels are
unchanged. Unit tests check that no buyer-facing Marketplace text contains "rent" or "rental" and that each listing and
the first reply say "not for sale".

## 2. "How did you hear about us?"

- The booking request (step 2) has an optional "How did you hear about us?" question. The answers are Facebook
  Marketplace, Instagram, TikTok, Facebook, Google, Kijiji, a friend or family, "I rented before", or somewhere else.
- The answer is stored in `bookings.heard_about` through `public.server_booking_heard_about`. That function is for the
  service role only, accepts a request less than one hour old, and records the answer once.
- `app.booking_channel` counts staff's source first, then a tracked visit, then this answer, then a referral code. So a
  Marketplace renter who typed carmacars.ca by hand is still counted for Marketplace.
- TikTok now has a label in the channel report.

## 3. The investor deck and the video

The deck uses only the allowed figures: the 3.2x multiplier, in the wording the lawyer approved ("CarmaCars' figure: a
3.2x multiplier on the money we invest in the fleet", footnoted as internal and not audited), and the current offer of
30% a year, paid monthly after the 6-month lockup. Both come from the deck settings and Program settings as before. The
deck shows no fleet insurance premium, fleet size, utilization or internal cost.

- **New feature slides**, with no screen. Instead each has a "How it works" panel: numbered steps on a dark panel,
  replacing the grey card.
  - For renters: the rental walkthrough, CarmaCars Rewards, and Add to calendar and Apple Wallet.
  - For owners: revenue share or a flat monthly payment.
  - For the team: one staff portal, the training academy, card payments at the car and at the desk, and insurance
    replacement rentals.
  - Admin and automation: e-signatures everywhere, phone and browser alerts, and the live map. The live map slide gives
    no numbers.
  - Growth: our cars on other rental sites, Facebook Marketplace kits, and owner recruitment.
- **Corrected wording**:
  - The portals are renter, owner, investor, staff and Admin. Field work and the assistant workspaces are now one staff
    portal.
  - Partner fleets earn us "a commission on the partner's rates". The old text said "a markup plus a cut", which no
    longer matches the November 1 terms for partner pricing.
  - The owner program mentions the flat monthly option.
  - The team slide says one staff portal and the academy.
  - The roadmap: native apps (the site already installs and sends alerts), GPS trackers with their dashboard, every
    rental site, and more partner fleets.
- **The platform at a glance** now gives each group's feature count and its first four features. Listing all of them
  overflowed the slide.
- **Video**: `docs/investor-video/script.md` follows the new slides. The scenes for the platform, the six groups, the
  team and the roadmap were rewritten; there are still 30 scenes and no scene has more than 4 sentences. The video's
  plan builds and checks against the deck: 92 slides, about 4:20 estimated, within the workflow's 2 to 5.5 minutes,
  and every slide fits 1920x1080. `docs/investor-video/storyboard.md` is new: scene by scene, the time, the slides on
  screen, the transition and the narration, plus how to make the video. The video is not rendered here. It renders on
  GitHub with `gh workflow run investor-video.yml -R carmacars/carmacars --ref main -f upload=true -f checks=true` after
  the merge, and the workflow also runs by itself on the 1st of each month.

## Guides

- `admin/advertising-and-owner-recruitment`: the new section Facebook Marketplace.
- `admin/the-investor-deck`: the feature slides as they are now.
