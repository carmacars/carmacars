# Release 48 integration: money fixes and the off-Cloudflare work together, and the follow-ups (3072)

Branch `r48-int` = `r48-m` (3051-3056: money fixes, tips, readiness, disabled-button hints) + `r48-n` (3070-3071: off-Cloudflare automation, the reviewed-document View button). The conflicts were only in `docs/releases/r48.md`, `docs/guides/content/admin.json` (the chapter `requests-offers-and-bookings` kept both sides' new lines) and `web/src/lib/schema-marker.ts` (now 3072). `web/src/generated/whats-new.json` was regenerated (`node scripts/whats-new.mjs`), not merged by hand.

## Follow-ups

- **Field checklist**: a booking with one driver reads **No additional drivers** in the Ready check, the same as Admin (`Checklist.tsx`; two or more drivers still read "Additional drivers accepted").
- **The tip link in the text** (migration `3072_r48_tip_text.sql`): the Returned text ends with `Add a tip: https://carmacars.ca/account/bookings/<number>/tip`, as the email does. The channel policy (2971) still decides which of the two the renter gets. An Admin's own wording is kept (the line is added once, only where the text has room). Test: `supabase/tests/99_r48_tip_text.sql`.
- **Greyed-out button hints**: the generic ones now say the specific thing to do first (`Act`'s default, "Finish the steps above first" in 8 places, "Change something first" in 4, "Choose one first" on the four card forms, which really meant "wait for the card form to load", "Choose at least one first" in 6, "Type it first", "Connect it first", the field Complete button, which now lists what is still to do). The three Act buttons of the late-return panel pass their own reason.
- **The Worker smoke `/cars` 503**: `scripts/worker-smoke.mjs` warms `/cars` first with one request that is not aborted at 60 seconds (240 seconds at most); the checks then hit a warm route. `web/src/lib/db/local.ts` finds workerd by any of its markers (not `navigator.userAgent` alone), and a connection closed under a call (`isClosedConnection`, `closed.ts`) drops the shared pool, so the next call, or the smoke's retry, opens fresh connections; a read (the function lookup) is run again once, a write never. Unit: `closed.test.ts`. Not run against the Worker build here (it is not built in this change).
- **DB tests that depended on the UTC date** (after 19:00 Toronto the UTC date is the next day): see the test list in the release notes of the run; each now uses `app.today()` (Toronto).

## Guides

No guide change: the wording of greyed-out hints, the field checklist line and the text of the return add no step to any chapter (the Admin chapter already names "No additional drivers" and the tip link).
