# Approve all names what it approves, the readiness lines, and every greyed-out button says why (Release 48 part 2: 3055)

Migration `3055_r48_identity_ready.sql`.

- **Approve all** names what it approves ("Approve the proof of coverage", "Approve all 3: licence front, licence back and selfie") instead of a bare count that included a proof of coverage or a Protection Plan waiting (`web/src/features/admin/doc-approve.ts`). With nothing it can approve, the dialog says it waits for the renter.
- **"Additional drivers: done" with one driver**: the checklist reads **No additional drivers** when the booking has none (`readiness.ts`).
- **"Licence and selfie verified" stayed unticked after approval**: a driver became verified only when the third image was approved on this booking, so a licence or selfie approved on an earlier booking left them unverified while the review screen showed every image approved. `app.booking_driver_verify_sync` marks the driver verified as soon as each image is approved (here, or on the driver's earlier booking when this one has none of that kind) and none here waits or was rejected; it runs on every approval, and the migration runs it for the bookings still to be picked up. The checklist, the review screen and the pickup read the same `booking_drivers.identity_verified_on`.
- **Every greyed-out button says what to do first**, on every portal (Admin, every staff role, owner, renter, the public pages): 171 buttons now name a hint (`aria-describedby` to a `WhyDisabled` line, the pattern of Propose a change's Send), or a title on compact controls (paging arrows, game buttons, the calendar's opener). A button greyed out only while its own action runs ("Working") needs none. `web/src/lib/a11y/disabled-hints.test.ts` scans every `.tsx` and fails on a greyed-out button without one. `Act` takes `disabledWhy`.
- **The Worker smoke's `/cars` 503** (deploy run 43743996484, not reproduced here: it needs the Worker build, which this change does not run). The log: `/`, `/sign-in` answered in seconds, then `/cars` took 104 seconds and gave 503 ("The service is no longer running"), with `unhandledRejection: TypeError: This socket has been closed` from the Worker's database driver. The cause: `/cars` is the heaviest first render (the fleet, the classes, the studio photo slots and both make lists read in parallel); on a cold `wrangler dev` it passes the smoke's 60-second timeout, the smoke aborts it, workerd cancels the request and closes its database sockets, and the retry reuses the closed sockets from the isolate's pool and fails. Not a production fault (the deployed Worker answers `/cars`); the fix to make in the next release: the database client drops a closed socket instead of reusing it (`web/src/lib/db/repo.ts`), and the smoke warms `/cars` with one request it does not abort.

## Tests

- `supabase/tests/99_r48_review_readiness.sql`: a selfie approved on an earlier booking and the licence approved here: verified and the readiness ticks; one driver needs no acceptance; a rejected image keeps the driver unverified.
- Unit: `doc-approve.test.ts`, `readiness.test.ts` (No additional drivers), `disabled-hints.test.ts`.

## Guides

- `admin/requests-offers-and-bookings`: Approve names what it approves; No additional drivers; greyed-out buttons say why.
