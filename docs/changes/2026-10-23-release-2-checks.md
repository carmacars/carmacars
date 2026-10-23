# Release 2 of October 23: the full suite

## What changed

- Text check: suite 77's "no long dash in what a page says" wrote the dashes themselves in its pattern; it now names them with `chr()`, as the other suites do.
- Migration 0119: the vehicle sitemap shape (0110) is stored with the Admin switches it was made under (`vpage_*_index`, `vpage_index_mode`). When an Admin turns off the city and colour pages or the /buy tree, `public.vehicle_sitemap_shape` reads the shape live until the job stores it again, so their files leave /sitemap.xml at once instead of up to 30 minutes later. Suite 55 checks it.
- The sitemaps keep the site's rows, the vehicle shape and the place files per Worker for 5 minutes on the live site (Googlebot's bursts); the local stack (`DATA_BACKEND=local`) reads them every time, as the anon shared reads already do.
- The local stack (`web/scripts/local-db.sh`): after loading the test places it runs the place roots, priority sitemap and place directory jobs that pg_cron runs in production, so /sitemap-priority.xml and /places list the test places (the priority sitemap was stored by migration 0115 before the places were loaded, so a production build listed no rental place page but the GTA). The seed now uses the script's own database address (`CARMACARS_LOCAL_PORT`).
- End to end, visitor history: the test waits for the FAQ's view before making the visit two hours old, checks that the day's rollup counts /faq (or already holds its 20 pages), and checks that the Top pages card shows the dates' first page; it no longer depends on /faq being in the top 10 of a day of the whole suite's visits.

## Guides

No guide change: nothing a person sees or does changes; the sitemaps follow the Admin switches sooner.
