# The site reads Google Search Console and improves its own pages (Release 42: 2640)

Branch `r42-gsc`. Migration `2640_r42_search_console.sql` (tables `app.gsc_link`, `app.gsc_page_totals`,
`app.gsc_page_queries`, `app.gsc_rewrite_queue`; Program settings `gsc_sync_on`, `gsc_rewrite_on`,
`gsc_rewrite_daily_max`, `gsc_inspect_daily_max`; `public.server_gsc_sync_begin`, `public.server_gsc_sync_finish`;
wrappers of `app.door`, `app.server_jobs_due`, `app.server_seo_claim`, `app.server_seo_result` and `app.seo_data`).
Tests: `supabase/tests/99_r42_search_console.sql`, `web/src/features/seo/gsc-sync.test.ts` (the selection rule, the
parsing of Google's answers, and whole runs against a mocked fetch). Setup: `docs/setup.md`.

## Owner action

1. Google Cloud, the project of the reviews OAuth client (`GOOGLE_REVIEWS_CLIENT_ID`), APIs and Services, Credentials,
   the OAuth client: add the authorized redirect URI `https://carmacars.ca/api/google/search-console/callback`.
   In the same project, APIs and Services, Library: enable "Google Search Console API".
2. After the deploy: Admin > Marketing > SEO, press **Connect Google Search Console** and allow it with the Google
   account that owns the carmacars.ca property in Search Console. Nothing else: the sync and the rewrites are on.

## What changed

| Part | What changed |
| --- | --- |
| Connection | Admin > Marketing > SEO has a card "Google Search Console" with **Connect Google Search Console**. It is the same OAuth client and pattern as the reviews and the calendar connections (`/api/google/search-console/connect` and `/callback`, a signed state bound to the browser), with the scope `https://www.googleapis.com/auth/webmasters` (read, and submit the sitemap) and offline access. The refresh token goes to the vault as `google_search_console_refresh_token` and is in no table; a database without the vault says so. **Disconnect** removes it |
| Daily sync | The five-minute tick asks `server_jobs_due`, which says `gsc` once a day while connected and on (`gsc_sync_on`); `/api/jobs/gsc` then runs `web/src/features/seo/gsc-sync.ts`. It picks the property `sc-domain:carmacars.ca` (else `https://carmacars.ca/`), reads Search Analytics for the 28 days that end three days ago (Google's figures settle by then) as totals, by page and by page and query, and stores them (`app.gsc_page_totals`, `app.gsc_page_queries`, with the date range). A second tick in the same hour gets nothing; a failed run keeps the connection, records why, and is tried again an hour later; a connection Google no longer accepts stops the tries and asks to connect again. The first sync starts right after connecting |
| Sitemap | Each sync submits `https://carmacars.ca/sitemap.xml` (the root index). A refusal is noted on the card and the day still counts. The `gsc` workflow keeps managing the full set of sitemap files as before |
| Inspections | Landing pages, guides and car pages that had no impressions are checked with the URL Inspection API, the least recently checked first and none again within 14 days: at most `gsc_inspect_daily_max` a day (50; 30 a run on a Worker, which has less room for outgoing requests), stopping at Google's quota. The answers go to `app.gsc_url_inspection` (1860), so a page that is not indexed is sent to IndexNow on its growing schedule |
| Rewrites | A landing page (`/car-rental/<slug>`) or a guide (`/guides/<slug>`) with an average position of 8 to 20, or with at least 50 impressions and a click rate under 1%, is set to pending, which is what **Write again** does: the existing search job writes it within its own daily limits (the day's neurons, the checks on numbers and style, locked fields kept). At most `gsc_rewrite_daily_max` pages a day (5), the most shown first, and the same page at most once in 28 days. `gsc_rewrite_on` turns it off. Car pages are not rewritten for this: their search title and description are filled in by the site, not by the writer |
| Searches in the prompt | The page's best searches (up to 8, by impressions) are handed to the writer with the claim (`queries`) and reach the prompt as data: "People find this page on Google with the searches above. Answer them...". A search is typed by anyone, so only letters, digits and plain punctuation of it are kept (in the job and again in the database), it adds no fact or number, and the answer passes the same checks as any other |
| Card | Connected or not, the last sync, the 28-day clicks, impressions and average position, the top 10 searches, the pages sent to the writer (why, the searches given, and whether they are written), the sitemap, and the last sync problem. Sales > Marketing > SEO shows the same card read only (no Google account, no buttons) |
| Both hosts | Plain `fetch` and the token refresh the reviews sync uses; no new package. `web/custom-worker.ts` and `web/src/lib/platform/cron-plan.ts` both run the job |

## Guides

No guide change: the card says what it does and has one button; the setup steps are in `docs/setup.md` and above.
