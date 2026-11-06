# Hotfix r27b, part 1: scrapers no longer render the long-tail pages

The database server at load 26 (vps-health 16:33 UTC, the anonymous PostgREST read timing out). Workers Observability,
two hours before: 165,000 invocations, 138,000 from no verified bot; the largest groups were agents posing as Windows
Chrome 150 to 154 from RapidSeedbox Ltd (21,000 invocations, a third of the Worker's CPU) and from a residential proxy pool
in about 40 countries, each long-tail place page asked for about 12 times an hour over `http://` and `https://`.

## What changed

- `web/custom-worker.ts`: `http://` on the site's hosts is a 301 to `https://` before anything renders.
- `web/src/lib/edge/scraper-guard.ts`: a long-tail page (place and term pages, the vehicle tree, for sale, the term trees)
  asked for from a hosting or proxy network, or by an agent posing as a browser that keeps none of the site's cookies,
  gets the page's kept copy (up to a week old), else 429 (hosting networks) or a tiny page that sets a cookie and
  reloads (a person passes at once); never a render, so never a database query. Verified search and AI crawlers, every
  agent that names itself (GPTBot, Claude-User, Googlebot and the others), the site's own checks and scripts always
  pass. Nothing is noindexed, disallowed or removed from a sitemap.

## Part 1b: the reads every page makes, kept in the database (migration 0533)

At 16:30 UTC the scrapers had tripled (119,700 Worker invocations in an hour from the Windows Chrome lookalikes) and
PostgREST's 20 connections were all busy, most of them with three reads every public page makes and that answer the
same for every page: `public.seo_links()` (1,313 ms a call, 619,000 calls), `public.seo_hub_links()` (1,134 ms, 611,000)
and `public.site_facts()` (about 650 ms, 531,000). The Worker keeps them 5 minutes per isolate, but scrapers spread over
hundreds of data centres keep starting cold isolates. No pg_cron job was heavy (each 15 s or less).

- `app.public_read_cache`: pg_cron works the three out every 3 minutes (`app.job_public_read_cache`); the functions
  answer from that copy in a few milliseconds (seo_links and seo_hub_links up to an hour old, site_facts 15 minutes),
  else work it out as before. An edit of the site or program settings drops the copy, so it shows at once.
- The database suites switch the copy off (helpers.sql), as they change data and read it back at once.

## Part 1c (migration 0534)

0533's trigger emptied the kept copy with a DELETE without a WHERE clause, which pg_safeupdate refuses on the company
server, so every save of the site or program settings failed. The delete names its rows now (the suite
`99_safeupdate_usage_server` caught it).

## Guides

No guide change: no screen changes; only scrapers see the check page.
