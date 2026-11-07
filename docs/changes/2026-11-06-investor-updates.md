# Investor Updates page: every release and what it added (release 29, migration 0580)

Branch `r29`. SCHEMA_MARKER 0580 (the guide chapters only; no schema change).

## What changed

- **Updates** in the investor menu (`/investor/updates`, `features/investor/UpdatesView.tsx`): every release, newest
  first, with the day it went live, a one-line summary and its items by area (Renters, Owners, Staff tools, Partners,
  Website & search, Reliability & security), a search box and an area filter. Investors and Admins (preview); Admin >
  Investors has **Updates (as investors see it)**. Static: nothing is read from the database.
- **Release notes for investors**: `docs/releases/<release>.md` (frontmatter `release`, `title`, `date` or `pending`,
  optional `seq` for releases on the same day, `summary`, `changes`: the change records it shipped; then `## <area>`
  and `- ` items). `scripts/gen-release-notes.mjs` builds `web/src/features/investor/updates-data.json` (`--check`).
- **Every release adds its section**: `scripts/check-release-notes.mjs`, run by `scripts/check-text.sh`, fails when a
  change record belongs to no release note (or two), a note names a record that does not exist, the data is out of
  date, or a note says something on the deny list (`features/investor/updates.ts` `DENY`: other businesses and
  vendors, personal names and contact details, fleet size, utilization, insurance details, costs, margins, pay, security
  weak points, incident details, migration numbers). A unit test runs the deny list over the generated data.
- **Backfill**: 29 releases and 245 items from the 245 change records. From main's history (the commit that added each
  record and the release branches merged): Releases 21a to 27b and three fixes released on their own. The history before
  October 30, 2026 is one snapshot: its records dated October 30 are Release 20; the rest are grouped by the date of the
  record as "Update <date>" (the numbered records of the first build: October 12 to 14). Incidents are written as
  "Reliability improvements", audits as "Security hardening".
- This release's own note is `docs/releases/r29.md` with `date: pending` (not shown until the date is set at deploy).

## For each future release

Add `docs/releases/<release>.md` listing its change records and its items in plain language; set `date` on the day it
goes live and run `node scripts/gen-release-notes.mjs`.

## Guides

- `investor/quick-reference`
- `admin/the-investor-deck`

Published by migration 0580 (`supabase/seed/0580_gen_guides.mjs`).
