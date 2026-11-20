# r48-trk: where this stands (helper hand-over note)

Done and pushed (439aebbb): tracker events, evidence, notices, pound database, screens, guides, tests (see
docs/changes/2026-11-20-r48-tracker-alerts.md).

In progress (this WIP commit): the owner confirmed one speeding event = one charge at the highest limit reached.
- Done: docs/source/v2_rental.md 10.5 and Fee Schedule lines; web/src/features/agreement/source.generated.ts
  (node web/scripts/gen-agreement.mjs, version rental-v3-2948304058); migration 3323 (terms_versions rental-v3-r48trk, so
  the terms pop-up fires); notice words in 3320; guides, academy (3322 regenerated); emails rebuilt; fields.ts hint;
  schema marker 3323; Charge refuses a second record of an event already charged; release note and change doc.
- Unit tests and the generator checks pass.

Next steps:
1. DB suites on the final migrations: /home/claude/r48trk-logs/db.sh supabase/tests/99_r48trk_tracker_events.sql
   supabase/tests/99_tracker_dashboard.sql (clones cc_fe_full3 on port 54322, applies 33xx). Expect 0 failed.
2. If green: commit without the WIP prefix ([skip ci], trailers), delete this file, push origin r48-trk, drop database cc_trk.
3. Not done on purpose: app.speeding_charge_add (3102, r48-mr) still lets Finance add a lower limit by hand for the same
   event; r48-mr's suite tests separate charges, so that guard belongs to the integration step.
