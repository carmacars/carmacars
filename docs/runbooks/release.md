# Release runbook

The steps of a release, from the merged branch to the owner's last click. Release 35 (part M) added steps 5 and 6.

1. Merge the release branch and let `ci` run once (the whole suite in one run; `docs/ci-minutes.md`).
2. Run `ci` with `deploy`: the database migrations, then the Worker (`web/README.md`, Deploy).
3. The deploy job starts `guides` (`auto`) and `gsc` with `submit=true`, `warm=3000` and `indexnow_rounds=10`.
4. Check Admin > Settings > Search: IndexNow's last answers and back-off, and the index coverage sample (indexed of the
   addresses Google knows, the priority pages, and the long tail's unknown ones apart).
5. The `gsc` run resubmits every planned sitemap (`submit=true`: `web/scripts/gsc.mjs` submits the whole plan again).
   Each page's `lastmod` moves when its content does: its own date, or the content epoch when the facts every page
   shows or the templates change (migration 1100, `public.seo_content_epoch`).
6. **Owner, by hand: Validate fix.** In Search Console, Indexing > Pages, open "Crawled - currently not indexed" and
   press **Validate fix**. Google has no API for this button, so no workflow can press it; the `gsc` run's summary
   reminds you with this step. Press it once per release that changes the programmatic pages, after step 5 has run.
   Validation takes Google up to a few weeks; its progress shows on the same page.
7. When the sourced page data should be refreshed outside its weekly run (a new car model in the fleet, a corrected
   spec table), run `seo-data` by hand (`gtfs osm specs`, or `csv` with a curated table's https address).
