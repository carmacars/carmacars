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

## Guides

No guide change: no screen changes; only scrapers see the check page.
