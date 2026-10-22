# Worker size: inlined stylesheets written once

Release 4's deploy (run 39800731430) applied its migrations, then Cloudflare refused the Worker: "Your Worker exceeded
the uncompressed size limit of 63.9 MiB" (code 10027). Production kept release 3's Worker on release 4's database.

## 1. Cause

Release 4 turned on `experimental.inlineCss` (0095 speed: the styles go inside the page). With it, every page's client
reference manifest carries the full text of each stylesheet its layouts use (`entryCSSFiles[...].content`). OpenNext
compiles every manifest into the Worker (its load-manifest plugin, `evalManifest`). It already moves identical values
out into shared constants, but only a page's whole `entryCSSFiles` object, which differs from page to page. The same 15
stylesheets (188 KB together) were repeated about 2,600 times: 117 MB of the 120 MB of manifests. The page code itself
is small; the route count multiplied the stylesheets.

## 2. Change

`web/scripts/worker-size.mjs`:

- `patch`, before `opennextjs-cloudflare build`: one more step in OpenNext's load-manifest plugin. Each inlined
  stylesheet text becomes one shared constant that every page's manifest refers to. Each page's manifest holds the same
  values as before. The plugin file is replaced, not edited in place (node_modules may be hard links). If an OpenNext
  upgrade changes the plugin, the patch stops the build instead of building the large Worker.
- `check`, after it: stops the build when the server bundle is over 40 MiB, so the e2e job reports it before a deploy
  applies migrations.

`npm run cf:build` runs patch, build and check. The CI e2e job and the deploy job both run it (`.github/workflows/ci.yml`),
as do `cf:preview` and `cf:deploy`. `next start` (`scripts/serve.mjs`, the e2e tests) reads `.next` as before and is
not affected. Nothing in the app changes, and the inlined styles stay.

## 3. Sizes (local build of deploy-rel4, `wrangler deploy --dry-run`)

| | Upload | gzip | Server bundle (handler.mjs) |
| --- | --- | --- | --- |
| Before | 130.8 MiB | 26.6 MiB | 131.7 MiB |
| After | 19.3 MiB | 4.9 MiB | 20.2 MiB |

The limit is 63.9 MiB, so 44.6 MiB is left for the vehicle pages and later routes. The OpenNext bundle step also takes
46 s instead of 159 s and much less memory.

## 4. Checks

- For all 223 pages, the patched plugin's `evalManifest` returns exactly the manifest the file defines (deep equal).
  The bundle has 15 shared stylesheet constants.
- The built Worker run locally (`wrangler dev`): the home page, a car page, `/chauffeur`, `/car-rental/toronto` and
  `/admin` render and hydrate, with the same inlined style block as `next start` and no manifest errors.
- `next start`: the same pages plus `/admin/vehicles`, `/admin/partners`, `/owner` and `/owner/documents` hydrate with
  no console errors at 375 and 1440, and the e2e subset `admin: dashboard|car page|chauffeur|partner` passes at both widths.

Branches built on release 4 (the vehicle pages) get the step through `npm run cf:build` when they merge it.

## Guides

No guide changes: a build step only; nothing a portal user sees changes.
