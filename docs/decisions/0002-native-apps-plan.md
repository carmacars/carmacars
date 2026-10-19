# Decision 0002: native apps after the web build is finished

Date: 2026-10-19. Decided by: Abbas. Status: planned, start when the web build is finished.

## Decision

Ship CarmaCars to the App Store and Google Play by wrapping the existing website in a native shell (Capacitor), not by
rebuilding it natively. No installable web app (PWA) step first.

## Scope

| Item | Detail |
| --- | --- |
| Apps | One app, "CarmaCars", iOS and Android. The signed-in role decides the portal (renter, owner, staff, field, investor, admin) |
| Shell | Capacitor loading carmacars.ca, with offline and error screens bundled in the app |
| Native features (needed to pass Apple guideline 4.2, "minimum functionality") | Push notifications (new request, offer, offer accepted, payment, pickup and return reminders, chat replies, staff tasks, field jobs); camera for licence, selfie and condition-report photos; Face ID / fingerprint sign-in; deep links from emails into the app (universal links / app links); share sheet for listings |
| Push delivery | Firebase Cloud Messaging (free) for both platforms, sent from the existing outbox: every notification the catalogue sends by email can also go by push, per person's preferences |
| Payments | Stripe in the web view as today (rentals are real-world services, so Apple and Google in-app purchase rules do not apply) |
| Accounts | Apple developer account (US$99 a year) and Google Play console (US$25 once), both in the company's name |
| Store listing | Screenshots from the guides workflow, privacy labels from the privacy policy, account deletion inside the app (Apple requirement) |

## Preparation already in place (keep it that way)

- Every screen is responsive and tested at 375 px; keep phone-first layouts.
- Camera capture already runs in the browser (field photo shoot, licence and condition photos); the shell maps it to the native camera.
- All notifications go through one outbox and catalogue; adding a push channel is one sender, not per-feature work.
- Sign-in uses Supabase Auth with token-hash links; deep links must route `/auth/callback` into the app.
- Do not add browser-only features that cannot run in a WebView (for example `window.open` popups for payments).

## Estimate

About 1 to 2 weeks of build plus store review (Apple usually 1 to 3 days per review).
