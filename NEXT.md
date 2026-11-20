# r48-rw: where this branch stands (handover note; delete before merging)

Branch `r48-rw` (worktree /home/claude/cc-r48rw), based on r48-int with origin/r48-int and origin/r48-fe merged in.
Change doc: docs/changes/2026-11-20-r48-rewards-calendar-notify.md. Migrations 3260 to 3265, 3269 (generated blocks:
supabase/seed/3269_gen.mjs), 3270 (owner-use charges), 3271 (Late Fee on unpaid insurance).

## Done
- Staff rewards, owner rewards, content calendar, notification preferences, owner tracker alerts: DB, web, native API,
  emails, guides, academy, What's new. DB tests supabase/tests/99_r48rw_rewards_calendar_notify.sql (150 pass).
- Owner-use charges billed to the owner (card on file, same-day bank debit, pay link and reminders, statement at the
  first of 7 days and the cut-off) and the 5% Late Fee on unpaid insurance: supabase/tests/99_r48rw_owner_money.sql.
- Base tests updated for the intended changes: 02, 07, 24, 25, 32, 33, 71, 99_push_alerts, 99_r35s_missed_debit_statement.
- tsc clean; eslint clean on changed files; web unit tests pass (2403, the 4 failures found were fixed).
- Local Postgres of this helper: port 54377, dir /var/lib/postgresql/cc-rw (CARMACARS_LOCAL_PORT / CARMACARS_LOCAL_DIR).
  Database `carmacars_test` holds every migration and the test files up to where the run got.

## Not done / next steps, in order
1. Finish the DB suite: the run was cut by time. Files after 99_r35y were being run one by one into
   /home/claude/r48rw-logs/suite2.log. Re-run from a fresh database when the machine is quiet:
   `CARMACARS_TEST_PGURL=postgres://postgres@127.0.0.1:54377/postgres scripts/test.sh` (about an hour here).
2. Failures seen that come from r48-fe, not from this branch (the files were not touched by r48-fe): 99_academy
   (section r48-whatsapp-tag has 3 questions, 5 needed), 99_r33f_signatures_terms (lines 77 to 84, the new terms
   versions), 99_r34n_academy_gate (line 74, agreement before academy), 99_r35sec_security line 124 (FK indexes missing on
   fee_evidence, booking_line_items.evidence_override_by, data_check_answers, terms_declines), and
   scripts/check-change-guides.mjs (2026-11-20-r48-fees-evidence-hiring.md has no "## Guides" section).
3. e2e and screenshots were NOT run (disk under the 2 GB floor, load over 10 at times). Spec:
   web/tests/e2e/r48-rewards-calendar-notify.spec.ts (written, never executed; expect selector fixes). To run:
   build a dev database (`web/scripts/local-db.sh reset` with the two env vars above), web/.env.local pointing at it,
   `npm run build`, then `BASE_URL=... RW_SHOTS=/home/claude/r48rw-logs/shots npx playwright test r48-rewards-calendar-notify`.
   RW_SHOTS saves each screen at 320, 375, 768, 1280 and 1440. Never run `playwright install`.
4. No screen yet shows owner-use charges on the booking's Money tab (app.owner_use_charges_read(booking) is ready for it).
   The owner sees the invoice on the existing invoice page; no e2e for 3270 and 3271.
5. Generators 3113_gen, 3153_gen_guides, 3194_gen_guides report their guide blocks out of date after the merges (not run
   by CI); the integrator regenerates them when r48-rw is merged into r48-int.
6. For the owner to confirm (in the change doc): HST on the Late Fee (on by default), the same-day bank debit without the
   notice days, the reworded Late Fee sentence that tests 32 and 33 hold word for word.

## Commits
Every commit: `[skip ci]` in the subject, then the two trailer lines used by the earlier commits of this branch.
