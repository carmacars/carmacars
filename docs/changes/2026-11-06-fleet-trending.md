# The fleet page opens on Trending (0352)

The owner, November 1, 2026: the default sort of /cars, "Our order" (0126: featured, then the daily rate), showed plain
cars first; he wants it "trending" or "hot", with impressive cars leading.

- The default sort is now **Trending**. The others stay (price low to high and high to low, seats, name and the rest).
- Every car on the site has a score, worked out once an hour by `app.job_fleet_trending` (pg_cron at :23) into
  `app.fleet_trend`, never per request:
  views x 1 + photos looked through x 0.5 + prices seen x 2 + booking requests x 8 + offers x 10 + bookings x 15, over
  the last 14 days, plus 25 for a premium, luxury or exotic car and 15 with real photos, minus 40 with sample photos only
  and minus 30 when it cannot be booked in the next 7 days. Weights, days and the badge count are Program settings
  (`fleet_trending_weights`, `fleet_trending_days`, `fleet_hot_count`; Settings > Program).
- The first 4 cars with a score carry a small red **Hot** badge on their card (0 turns it off).
- An Admin pins a car to the top: Admin > Cars > the car, **Pin to the top of /cars** (1 first; empty unpins). It
  replaces the manual featured order of the fleet page. Pins are in the audit log.
- Only the website's fleet read (`public.fleet`) follows the Trending order. `app.public_fleet`, which the search pages'
  snapshots read, keeps 0126's order, so an hourly change of score never rewrites a landing page or its sitemap date. The
  scores live in their own table, so the hourly job never touches the listings (whose triggers refresh the cached rows
  and the partner CRM).
- Saves or shares are not recorded on the site yet, so they are not signals.

`supabase/tests/99_fleet_trending.sql`: the score by signals and the premium boost, signals past the 14 days left out,
the job writes only what changed, the order and the Hot badge, the search pages' order unchanged, a pin leads and only
an Admin pins, the weights are a setting.

## Guides

No guide change: the fleet page's order and the pin are new controls that explain themselves on the car's page; the
fleet chapter's steps did not change.
