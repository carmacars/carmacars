# The App Store and Google Play app (0390, 0391)

The owner, October 19, 2026 (decision 0002): "real App Store and Google Play apps once the entire web build is
finished", for renters, owners and staff, in a native shell around the site. This release is the start: the app project,
everything the site needs to work inside it, native push from the same outbox as the web alerts, the store listing drafts
and the owner's steps to publish (docs/apps/publish.md). Native builds run in GitHub Actions once the owner has made the
accounts and keys; nothing native is built in this release.

## The split: one app

One app, **CarmaCars** (bundle and package id `ca.carmacars.app`), iOS and Android, for every role: the signed-in
account opens its portal, as the site's `/app` already does. Decision 0002 says so, and Apple's guideline 4.3 refuses
near-identical wrapper apps; one listing also gathers every review and needs one Firebase project and one review.
docs/apps/store-listing.md, "One app, every role".

## The app project: apps/carmacars

- **Capacitor 8** (MIT licensed, like every plugin used except Firebase Messaging, Apache-2.0): `package.json`,
  `capacitor.config.ts`, `www/` (the bundled offline screen and a fallback start page). The app opens
  `https://carmacars.ca/app`; the site's pages are the app's screens, so each site release reaches the app at once. Pages
  of carmacars.ca and Stripe's payment pages stay inside the app; any other link opens the browser.
- **Native value** (Apple 4.2): push alerts through Firebase Cloud Messaging (APNs on iPhone), the native camera for the
  licence, selfie and condition photos, Face ID, Touch ID or fingerprint unlock, universal links and app links, the share
  sheet on car pages, haptics, a black status bar and splash screen, and the offline screen (no connection, or the site
  did not answer: **Try again**, and it reloads by itself when the phone is back online).
- **Icons and splash** from the brand (the CC mark of the site's icons in the site's display face):
  `scripts/gen-assets.mjs` renders `assets/` (iOS icon without transparency, Android adaptive foreground and background,
  2732 px splash, the white alert icon in five densities) and the Play Store icon and feature graphic. The release build
  makes every native size from them (`@capacitor/assets`). When the logo arrives, change the mark there and run it again.
- **Native projects are not committed.** Each build makes them (`npx cap add`) and fits them
  (`scripts/native-setup.mjs`, with `scripts/ios-project.rb` on the Mac): the permission texts, push and universal links
  entitlements, the Firebase hooks and files, app links for carmacars.ca, the alert icon, colour and channel, release
  signing from the environment and the version. Running it twice changes nothing.
- **Builds:** `.github/workflows/apps.yml`, Run workflow only (never on a push): Android, a signed App Bundle (artifact,
  and Internal testing when the Play key is set); iPhone, archived with Xcode's cloud signing and uploaded to TestFlight.
  A platform whose secrets are missing is skipped with a notice. Not run yet: its first run needs the owner's keys.
- **Store listing drafts:** `store/ios/en-CA/*.txt` and `store/android/en-CA/*.txt` (the stores' upload layout), and
  docs/apps/store-listing.md: privacy nutrition labels, Play data safety, age rating, the screenshots plan, review notes.
- **Check on every push** (ci.yml fast job, no install, about a second): `scripts/check-app.mjs`: the config (id, live
  site over https, the user agent token, no web inspector), the offline screen, every plugin the site calls is in
  `package.json`, icon and splash sizes (no transparency on the iOS and Play icons), the listing text against each store's
  limits and the text rules, and no key or Firebase file in the folder.

## The site inside the app

- **Detection:** the shell adds `CarmaCarsApp/1 ios` or `CarmaCarsApp/1 android` to the user agent
  (`web/src/lib/native/shell.ts`). A small script at the top of every page sets `<html data-shell="app">` before the first
  paint (pages stay static); dynamic pages read it on the server (`web/src/server/app-shell.ts`).
- **Web-only parts hidden in the app:** the footer's long place, service and make link lists and the giant wordmark (the
  footer keeps contact, company and legal links); "Continue with Google" and the other provider buttons (Google refuses
  its sign-in inside an app's web view; the app signs in by email, phone or a saved password, and so needs no Sign in
  with Apple); the iPhone "Add to Home Screen" steps of the alerts card. `.web-only` and `.app-only` for later.
- **The app layer** (`web/src/features/app-shell/AppShell.tsx`, loaded only in the app): hides the splash once the page
  painted; deep links and tapped alerts open their page (pages of carmacars.ca only, `appPathOf`); a tap on a photo field
  (`capture`, or an image-only field) opens the phone's camera and puts the photo back into the same field, so every
  form works unchanged (`web/src/lib/native/camera.ts`); App lock; a bar when the connection drops; an alert that arrives
  while the app is open shows as a banner with Open. The plugins are called through the shell's own bridge
  (`web/src/lib/native/bridge.ts`), so the site adds no package.
- **App lock** (Profile, all portals, in the app only, on phones with Face ID, Touch ID or a fingerprint): **Unlock with
  Face ID**; asked when the app opens and after 5 minutes away; the screen is veiled in the app switcher; **Sign out
  instead**. The setting stays on the phone.
- **Share** on car pages, in the app only: the phone's share sheet with the car's page.
- **Universal links and app links:** `/.well-known/apple-app-site-association` (every page but files and feeds, and
  shared passwords) and `/.well-known/assetlinks.json`, from the repository variables `APP_APPLE_TEAM_ID` and
  `APP_ANDROID_CERT_SHA256` (deploy step). Until they are set the files answer 404.

## Push in the app: the same outbox (0390)

- A device is still one `push_subscriptions` row, now of a **kind**: `web` (a browser, as in 0300) or `fcm` (the app:
  endpoint `fcm:<token>`, no keys, its platform). One check per kind replaces 0300's column checks. Every in-app notice
  still queues one alert per device by 0300's trigger, with the same topics, quiet hours and urgency.
- **Sending by kind:** `server_push_due(p_limit, p_kinds)` and `server_push_waiting(p_kinds)` claim only the kinds the
  Worker can send: browsers with the VAPID keys, the app with the Firebase service account. The Worker's tick asks only
  about its kinds. An alert not sent within 3 days is dropped as stale.
- **The Firebase sender** (`web/src/lib/push/fcm.ts`): FCM HTTP v1; the Worker signs in as the service account (an RS256
  JWT with WebCrypto, one access token an hour), one message per device: the title and text, the page in `data.url`, high
  priority, grouped by notice, time-sensitive on iPhone when urgent. Answers: 404, UNREGISTERED and SENDER_ID_MISMATCH
  delete the device; 400 counts as a refusal (three in a row end it); 401, 429 and 5xx retry in 5 minutes.
- **Off until the key exists:** the vault secret `deploy_fcm_service_account` (the Firebase service account JSON) becomes
  the Worker secret `FCM_SERVICE_ACCOUNT` (one line of base64, masked in the logs). Without it the app shows no alerts card
  and no invitation, and app devices are never claimed; browser alerts are unaffected. `PUSH_PROVIDER=fake` turns the
  app's card on locally and in the tests.
- **The card in the app:** the same Phone alerts card and invitation; Turn on asks the phone, Android gets the "CarmaCars
  alerts" channel, the device is listed as "CarmaCars app on iPhone" or "on Android". A token Firebase replaces is sent
  again by itself.

## Delete my account (0390)

Apple requires that an app with sign-up lets people start deleting their account inside it. Renters, owners and
investors have **Delete my account** at the end of Profile, in the app and on the site: a confirmation with an optional
reason, then "We settle anything still open, delete your account and email you within 30 days", with **Keep my
account**. The request (`account_deletion_requests`) opens a high Admin task on Today, due in 14 days, with what to settle,
delete and keep (rental agreements, receipts, statements and tax records); **Done** on the task marks the request done.
Admins cannot ask (another Admin closes their account). Staff accounts are closed by the Admin when they leave.

## Owner, still to do

docs/apps/publish.md, in order: D-U-N-S number; Apple Developer (US$99 a year) and Google Play Console (US$25 once), both
as the company; the Firebase project; the Android upload key; the GitHub secrets and variables and the vault secret; the
first builds, testing on both phones, the listings and the reviews. Also: the demo account for the reviewers, and the
deletion itself is done by hand from the Admin task until a one-step tool exists.

- Code: `apps/carmacars/`, `.github/workflows/apps.yml`, `web/src/lib/native/`, `web/src/lib/push/fcm.ts`,
  `web/src/features/app-shell/`, `web/src/server/app-shell.ts`, `web/src/server/push.ts`, `web/src/server/actions/push.ts`,
  `web/src/server/actions/account-deletion.ts`, `web/src/features/push/`, `web/src/app/api/app-links/`,
  `web/src/app/layout.tsx`, the five profile pages and Admin > My phone alerts, `web/src/app/cars/[slug]/page.tsx`,
  `web/src/features/forms/OAuthButtons.tsx`, `web/src/styles/core.css`, `web/src/styles/app-shell.css`,
  `web/src/lib/edge/cron-gate.ts`, `web/next.config.ts`, `web/src/lib/env.ts`, `web/.env.example`,
  `scripts/deploy/supabase.sh`, `.github/workflows/ci.yml`.
- Tests: `supabase/tests/99_native_apps.sql`, `web/src/lib/push/fcm.test.ts`, `web/src/lib/native/shell.test.ts`,
  `web/src/lib/native/camera.test.ts`, `web/src/features/app-shell/app-shell.test.ts`,
  `web/src/lib/edge/cron-gate-push.test.ts`, `web/tests/e2e/native-apps.spec.ts` (the app's bridge stood in, at 375 and
  1440 with axe), `apps/carmacars/scripts/check-app.mjs`.

## Guides

- `renter/after-your-trip`, `owner/notices-profile-and-leaving`, `investor/profile-and-notices`: a "Delete my account"
  part (migration 0391). The app's own parts (App lock, alerts in the app) join the guides when the app is in the stores.
