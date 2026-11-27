# R50 hotfix 2: CI doctor (5075 to 5077)

Migrations `5075_r50h2_import_cap_own_server.sql`, `5076_r50h2_townhall_missing_real_staff.sql`, `5077_r50h2_cifix_guides.sql`. The owner on Nov 27: "make sure you're not doing things systematically wrong; that's what's causing the long CI runs and test fails". Root cause and numbers: hotfix-notes/ci-root-cause-2026-11-27.md. REQ-117 (new), REQ-070, REQ-001, REQ-004.

## Changes

- The integration branch is green again: the stale 3701 photo assertions follow 5064 (REQ-004: a car with no render shows its own photos or the full sample set, REQ-001: every sample angle in the samples' order); the townhall test reads the configured time (18:30 since 5072) instead of 13:00; the Google Meet test sets an outside link for link mode (5072); the academy test no longer reads a setting another 99_ file leaves; the schema marker is 5077.
- 5076 (REQ-070): the townhall status lists as missing only real staff with a tracked KPI that the KPI slide does not show; a test or Verify account is never missing from the team slide.
- 5075: the catalog and places import cap is 16 GB (our own server's disk), and the database allowance of Settings > Usage 16 GB. The scheduled catalog import failed every day since Nov 22 on the old Supabase Pro cap (6,144 MB), and self-heal failed with it.
- CI (REQ-117): push runs only on main, r50-hotfix2 and release/**, plus pull requests into them and Run workflow. The database suite runs the migrations and the base tests once (db-base, pg_dump artifact); 6 slices restore it and run their release tests, split by recorded timings (scripts/test-slices.mjs, supabase/tests/timings.json, refreshed through the Actions cache).
- vps-health: an outside probe that answers 000 names curl's reason (the Nov 22 to 27 alerts were a certificate only Cloudflare trusts).

## Guides

- `admin/search-car-pages-landing-pages-and-guides`: the database cap is our own server's, 16,384 MB by default.
