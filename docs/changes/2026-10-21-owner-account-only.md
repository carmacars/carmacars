# An owner account without a car (October 21, 2026; migration 0088)

The owner: car owners can create an account without a car.

## What changed

- `app.submit_owner_application` (0022) also takes `account_only: true` with no vehicles: it creates the owner record (and the sign-in, from the website), an application in the new status `account_only` ("Account only: no car yet"), no per-car intake task, and one light Admin task "New owner signed up without a car: follow up" (on To do). A second submit keeps the one application and the one task. Without the flag and without a car it is refused as before.
- The owner's first car later (the same application form, VIN-first) is an ordinary new application; the follow-up task closes and the account-only row leaves the Applications inbox.
- The application wizard: "I'll add my car later" on the vehicle step skips the vehicle and plan steps; the review shows "No car yet" and the button "Open my owner account". The done screen and the owner portal say "Your owner account is open"; the owner portal home shows "Add your first car".
- Admin > Applications: the chip "Account only: no car yet" and "No car yet" in the Car column.

## Tests

Suite 59 (`supabase/tests/59_owner_account_only.sql`); e2e `web/tests/e2e/owner-account-only.spec.ts` at 375 and 1440 (account without a car, the Admin's inbox, then the first car from the owner portal). The path with cars stays covered by `owner.spec.ts`.

## Guides

- `owner/apply-and-get-your-car-listed`
