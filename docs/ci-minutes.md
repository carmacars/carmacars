# GitHub Actions minutes

**Since October 16, 2026 the repository is public, and GitHub does not bill Actions minutes for public repositories.**
The workflows keep the shape below all the same (short runs, quick answers), and there is no `pull_request` trigger:
a pull request from a fork would run the fork's code (`docs/changes/2026-10-16-one-confirmation-email.md`, section 4).
Run logs are public too, so no step prints a secret or personal data. The budget below applies again if the repository
goes back to private.

The repository is private, so GitHub bills Actions by the minute: the free plan has **2,000 minutes a month** on
Linux runners, and each job is rounded up to the next whole minute. In October 2026 the month's minutes ran out
because every push ran the whole suite (about 33 billed minutes a push: the database job 2, the end-to-end job 18
and the audit job 13, in parallel). The workflows now spend minutes only where they buy something.

## What runs when

| Workflow | Trigger | What runs | Billed minutes (estimate) |
| --- | --- | --- | --- |
| `ci` | push | One job, `fast`: database suite (every migration and test), text check, lint, types, unit tests, generated types | about 7 |
| `ci` | push that changes only `docs/**`, `*.md`, email previews | Nothing (paths-ignore) | 0 |
| `ci` | a newer push to the same branch | The older run is cancelled (concurrency) | only what ran |
| `ci` | Run workflow, `deploy` | `fast`, and the full suite in 8 parallel jobs (each: its own stack and Worker build, a quarter of the end-to-end tests at 375 or 1440 with axe, then against the data its tests left the emails with database values and its share of links, copy lint, crawl as every role with Admin in 4 parts, SEO), the gate job `full`, then `deploy`; about 25 minutes until `deploy` starts (one job in turn took 2.5 to 3.7 hours) | about 175 (7 + 8 x 20 + 5; not billed while public) |
| `ci` | Run workflow, `deploy`, `checks` off | `deploy` only (a commit that already passed) | about 5 |
| `ci` | Run workflow, `full` (no deploy) | `fast` and the full suite (8 parallel jobs and `full`) | about 170 (not billed while public) |
| `verify` | Run workflow | Slim: public pages, headers and nonce, console errors, statement emails job, Worker analytics | about 5 |
| `verify` | Run workflow, `full` | Adds sign-in as every portal, view as, invitation, reset, live SEO audit | about 12 |
| `backup` | nightly | Encrypted database and storage backup | about 2 |
| `backup` | Monday | The weekly restore check | about 5 |
| `guides` | Run workflow | Screenshots for the user guides, then the guide upkeep (each screenshot compared with the live guide's; a changed one replaced and its sections flagged for review; `upkeep` on by default) | about 20 |
| `guides` | after each successful deploy (`auto`, started by the deploy job) | A one-minute check first: nothing under `web/src` or `docs/guides/src` changed since the last finished run, and it stops there. Otherwise the screenshots, the replacement of changed ones, the rewrite of the sections that changed or name missing buttons (at most 15), the PDFs of the guides that changed, and the record of the run | 1 (nothing changed) or about 25 |
| `forms-fetch` | Run workflow | Downloads the official ServiceOntario PDFs, reads their fields, stores them | about 1 |
| `guides-pdf` | Run workflow | Prints each published guide and stores its PDF | about 4 (1 with `committed`) |

The site check of migration 0062 (pages, emails, jobs, backup and Stripe every 5 minutes) runs inside Supabase with
pg_cron and pg_net, and calendar sync in a Supabase Edge Function: neither uses Actions minutes.

Caches keep the repeat cost down: npm (`actions/setup-node`), the Playwright browser (`~/.cache/ms-playwright`,
keyed on the lock file) and the Next.js build cache (`web/.next/cache`). The database suite uses the PostgreSQL 16
that the runner image already has.

## A month's estimate

The busy month the plan is sized for: 40 pushes, 10 deploys, 10 verifies, 30 nightly backups.

| Item | Count | Minutes each | Minutes |
| --- | ---: | ---: | ---: |
| Push (fast gates) | 40 | 7 | 280 |
| Deploy (fast, full, deploy) | 10 | 43 | 430 |
| Verify (slim) | 10 | 5 | 50 |
| Nightly backup | 30 | 2 | 60 |
| Weekly restore check | 4 | 5 | 20 |
| Guides after a deploy (6 that changed screens, 4 that did not) | 10 | 25 or 1 | 154 |
| **Total** | | | **994** |

Since October 16, 2026 (migration 0055) the guides keep up by themselves: the deploy job starts `guides` with `auto`
after every successful production deploy. Its first job (about a minute) compares the deployed commit with the commit
of the last finished run and stops when nothing under `web/src` or `docs/guides/src` changed, so a deploy of a database
or email change costs one minute. A run that does the work prints only the PDFs of the guides that changed, and
rewrites at most 15 sections (the rest wait for the next run).

That leaves about 1,000 minutes for the occasional extra: a `full` verify (12), a guides run (20), a guide PDF
print (4), or a deploy that has to be run twice. The same month under the old workflows was about 40 x 33 + 10 x 36
+ 10 x 10 + 30 x 2 + 20 = 1,860 minutes, which is how October ran out.

If the minutes run low again: deploy with `checks` off when the commit's push already passed and nothing about the
build changed since a full run; push documentation in its own commits (they cost nothing); and keep `verify` slim
unless a sign-in or SEO change needs the full check.

## Checking the real numbers

GitHub shows the minutes used in Settings > Billing and plans (the organisation's) and each run's billable time on
its summary page (or `gh api repos/carmacars/carmacars/actions/runs/<run id>/timing`). Update the estimates above
when the real numbers differ by more than a few minutes.
