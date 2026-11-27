# R50 hotfix 2: offers on every search page, Search Console fixes, rental software page, interview reminders, traction

Migrations 5160 to 5165. Branch r50-hotfix2-seo.

## What and why

1. **Nobody contacted us about trackers.** Evidence (list_leads, Nov 17 to 27): no tracker or chauffeur lead. The tracker
   pages exist and answer, but `/sitemap-families.xml`, their only sitemap, answered an empty file whenever its read
   failed (Search Console: error, 0 addresses, read Nov 26). Fixes: a failed families read answers 503 (Google retries);
   the tracker's own pages and the new software page are in `/sitemap-pages.xml`, which needs no slow read
   (`web/src/features/seo/sitemap-paths.ts`). Every SEO page family now leads its services module with the tracker
   (opens the waitlist form), the owner program (the application), the chauffeur (the request) and a car rental
   (`catalog.ts` `LEAD_KEYS`); `/buy`, `/t/<term>` and `/places` pages had no module and have it now.
2. **Search Console auto-correct.** Evidence: heal_status shows the two gsc playbooks never ran (0 successes, 0
   failures); the coverage sample inspects sitemap addresses, which never 404; Search Console's Pages report has no API;
   the rewrite queue (gsc_rewrite_on) improves ranking copy, it does not fix errors; Admin's sitemap list showed files
   the property dropped weeks ago. Fixes: the gsc workflow checks the pages Google shows in search on the live site and
   stores a 404, 410 or 5xx as an error the self-healing matches (`gsc-coverage.mjs`, `coverage.ts`); the latest
   sitemaps view holds the last run only (5160); the searches are readable through the connector
   (`search_console_queries`) and in each run's summary. Keyword research: `docs/seo/keywords-2026-11.md`; new page
   `/car-rental/opcf-27` (5163), linked from the requirements and coverage pages.
3. **Rental software page** `/rental-software`: every portal and feature, no pricing, no technology named, a form that
   makes a contact lead (topic "Rental software (white label)"). Indexable, in the pages sitemap and llms.txt, in no menu.
4. **Applicants who never interview.** Evidence (list_applicants, the newest 200): 29 invited and never interviewed, 116
   referred; one email, no reminder, held behind the email cap (site_health email_cap failed 60 times in 24 hours) and
   skipped as stale after the link expired. Fixes (5161): reminders at 1 and 3 days and the day before expiry, with a
   text to Canadian and US numbers; an expired link opens a new one with one tap and starts at once; a waiting reminder
   that no longer applies is skipped. The root cause outside the code: the daily email cap (Amazon SES not on).
5. **Traction** (5162): monthly active users (website, app) and days rented on the deck and the investor Home, from a
   model the same for every business (`traction_metrics`, `traction_monthly`).

6. **Every family carries every offer and its details** (the owner, repeated): the services module now always leads
   with the tracker, owner program, chauffeur, rental, long-term, insurance replacement, body shop and detailing (less
   the page's own), each opening its form; place pages list the chauffeur, owner and tracker pages too; Ontario place
   pages state the fuel prices the site uses; car pages with a tank or battery size show a full tank or charge and its
   range; catalog pages show an EV's full charge. Tank and tire sizes show only where vehicle_specs has them (no free
   catalog source publishes them). `families-offers.test.ts` fails when a family loses the module or its detail block.
7. **Search Console and crawl** (`docs/seo/gsc-fixes-2026-11.md`): IndexNow had 8,580 changed pages waiting and 0 sent
   in a day; the gsc workflow now sends them itself (5165).

## Guides

- `admin/hiring`: interview reminders and the one-tap new link.
- `admin/the-investor-deck`: Traction.
- `admin/search-car-pages-landing-pages-and-guides`: the offers on every search page, the rental software and OPCF 27 pages, the Search Console checks.
- `investor/your-investments`: How the business is growing.
