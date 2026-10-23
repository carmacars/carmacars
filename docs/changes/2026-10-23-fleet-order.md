# The public fleet in one order, October 23, 2026

CI failed on suite 47: "snapshot: an unchanged fleet changes no page", the second `app.seo_snapshot_refresh()` in a row
rewrote 19 pages. The cause: `app.public_fleet` sorted the cars by featured, daily rate and first publication time
only. Cars published in the same transaction share that time, so cars at the same rate came out in whatever order the
query plan read them. When the plan changed between two refreshes (new statistics, for example), those cars swapped
places, and every landing page and place term listing them looked changed: its snapshot was rewritten, its sitemap date
(`cars_changed_at`) moved and it was queued for IndexNow, with no change to the fleet. In production that churned page
dates for nothing.

Migration `supabase/migrations/0126_fleet_order.sql` (SCHEMA_MARKER `0126`): the car's id breaks the last tie. The
fleet, the snapshots and the live pages all sort that same input, so they agree every time. After the deploy, the first
refresh puts the pages whose cars were tied into the new order once; after that a refresh changes a page only when its
cars change.

Test: suite 47 now also refreshes under two other query plans (hash and merge joins off, then nested loops and
sequential scans off) and expects no page to change. With the old order those refreshes rewrote 19 and 18 pages.

## Guides

No guide change: the order of the cars on a page is the same for renters; only cars at the same price and published
together keep one order.
