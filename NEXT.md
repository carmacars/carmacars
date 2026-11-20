# r48-trk: where this stands (helper hand-over note)

Pushed and checked: tracker events, evidence, notices, pound database, one-charge speeding wording (3320 to 3323).
In progress (WIP commit): province and country exit alerts, migration 3324_r48trk_border_alerts.sql, clause 10.1,
terms version rental-v3-r48trk2, email staff_border_alert, guides, tests section 7b in supabase/tests/99_r48trk_tracker_events.sql.

Next steps:
1. /home/claude/r48trk-logs/db.sh supabase/tests/99_r48trk_tracker_events.sql supabase/tests/99_tracker_dashboard.sql
   (clones cc_fe_full3 on port 54322 and applies 33xx): fix until 0 failed.
2. cd web && node --test --experimental-strip-types --no-warnings src/integrations/tracker/*.test.ts src/features/tracking/*.test.ts
   src/features/agreement/*.test.ts src/lib/schema-marker.test.ts; then npx tsc --noEmit.
3. Regenerate types only if a public table or function changed (3324 adds tracker_status.outside_canada: run
   DATABASE_URL=...cc_trk node web/scripts/gen-types.mjs after step 1 and commit the diff).
4. Commit ([skip ci], trailers), push origin r48-trk, drop database cc_trk.
Left for integration: app.speeding_charge_add (r48-mr) still allows a hand-added lower limit; one combined CI run.
