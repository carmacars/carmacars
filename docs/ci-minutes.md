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
| `ci` | Run workflow, `deploy` | `fast`, then `full` (Worker build, end to end at 375 and 1440 with axe, links, copy lint, crawl as every role, SEO, emails with database values), then `deploy` | about 43 (7 + 31 + 5) |
| `ci` | Run workflow, `deploy`, `checks` off | `deploy` only (a commit that already passed) | about 5 |
| `ci` | Run workflow, `full` (no deploy) | `fast` and `full` | about 38 |
| `verify` | Run workflow | Slim: public pages, headers and nonce, console errors, statement emails job, Worker analytics | about 5 |
| `verify` | Run workflow, `full` | Adds sign-in as every portal, view as, invitation, reset, live SEO audit | about 12 |
| `backup` | nightly | Encrypted database and storage backup | about 2 |
| `backup` | Monday | The weekly restore check | about 5 |
| `guides` | Run workflow | Screenshots for the user guides | about 19 |
| `guides-pdf` | Run workflow | Prints each published guide and stores its PDF | about 4 (1 with `committed`) |

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
| **Total** | | | **840** |

That leaves about 1,160 minutes for the occasional extra: a `full` verify (12), a guides run (19), a guide PDF
print (4), or a deploy that has to be run twice. The same month under the old workflows was about 40 x 33 + 10 x 36
+ 10 x 10 + 30 x 2 + 20 = 1,860 minutes, which is how October ran out.

If the minutes run low again: deploy with `checks` off when the commit's push already passed and nothing about the
build changed since a full run; push documentation in its own commits (they cost nothing); and keep `verify` slim
unless a sign-in or SEO change needs the full check.

## Checking the real numbers

GitHub shows the minutes used in Settings > Billing and plans (the organisation's) and each run's billable time on
its summary page (or `gh api repos/carmacars/carmacars/actions/runs/<run id>/timing`). Update the estimates above
when the real numbers differ by more than a few minutes.
