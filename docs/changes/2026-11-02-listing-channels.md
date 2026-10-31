# Listing channels (0216)

Abbas's request (Release 22, item 3): CarmaCars' cars on other car rental sites. Migration
`supabase/migrations/0216_listing_channels.sql`. Code: `web/src/app/admin/marketing/channels/page.tsx`,
`web/src/app/api/feeds/[token]/route.ts`, `web/src/features/channels/`. Tests: `supabase/tests/99_listing_channels.sql`,
`web/src/features/channels/feed.test.ts`, `web/tests/e2e/release-22.spec.ts`.

- Admin > Marketing > Listing channels: a checklist seeded with Turo, Getaround, Google Business Profile, Google Merchant
  Center (vehicle listings), the Meta catalog, Kijiji, Facebook Marketplace, KAYAK, Expedia Group, Discover Cars,
  Rentalcars.com, AutoTrader.ca (not for us: no rental category), Craigslist, Bing Places, Apple Business Connect, Yelp
  and YellowPages, each with status, login owner, notes and how listing works there. No integration is claimed: each is
  applied for on its own site.
- Each channel has its own feed address (JSON, CSV, Google vehicle-listings style XML), on by default, with New key.
  CarmaCars' own and co-hosted (program owner) cars on the site only: never a partner car (01 Motors or any other), a
  sample, a retired car or one kept out (`vehicles.channel_feed_opt_out`). Car links carry `utm_source=<channel>`.
- At most `program_settings.channel_feed_hourly_max` (60) fetches an hour per channel (429 after), each answer cached
  15 minutes.

## Guides

- `admin/advertising-and-owner-recruitment`: Listing channels.
