# Phone alerts and the installable site (0300, 0301)

The owner, November 1, 2026, answering "Go" to the next release's list, which had "Browser push notifications, with the
web manifest". The original brief: "A responsive website with a phone layout and a desktop layout. Not an iOS app."
Decision 0002 still stands (the store apps come later, in a Capacitor shell, with push through Firebase from the same
outbox): this release is the web half of it and uses the same topics and the same one send path, so the native app adds
one more sender and nothing else.

- **Installable:** `/manifest.webmanifest` (CarmaCars, black, the CC mark of the staff portal's icons in 192, 512 and
  maskable 512, an Apple touch icon) on every page, start `/app` (a signed-in person goes to their portal, anyone else to
  the home page), scope `/`. The field pages keep their own manifest. iOS gets its Home Screen name and full-screen mode.
- **Service worker for alerts only:** `/push-sw.js` shows an alert and opens its page on a tap (only pages of this site).
  No fetch handler and no cache: every page always comes from the site and nothing personal is kept on the device. It is
  registered only when someone turns alerts on.
- **Content security policy:** `worker-src 'self'` and `manifest-src 'self'` are now named. Both were already allowed
  (`worker-src` falls back to `script-src`, `manifest-src` to `default-src 'self'`); naming them keeps any future
  `script-src` origin (Stripe, Turnstile) from ever running a worker here. The MapLibre worker of the live map is a file
  of this site, so it is unaffected. Nothing else changed.
- **Turning alerts on:** a "Phone alerts" card on Profile in the renter, owner, investor and staff portals (field staff
  too) and Admin > Settings > **My phone alerts**: Turn on alerts (the browser asks once), Send a test alert, Turn off on
  this device, the topics, and the person's other devices with Remove. The first page of each portal invites once
  ("Get alerts on this device", Turn on, Not now for 30 days). Never while an Admin views a portal as someone else, and
  never to automation. iPhone and iPad outside the Home Screen app get three steps (Share, Add to Home Screen, open it
  from there) instead of a button; a blocked permission and a browser without push say what to do.
- **Topics and defaults** (`notification_catalogue.push_topic`, 93 notices): new requests and offers, booking changes,
  payments, pickups and returns (field jobs), messages, urgent alerts, documents. Renters everything; owners new
  bookings, changes, payments, incidents and documents; investors payments, documents and messages; staff requests,
  changes, messages and urgent alerts; field staff their jobs and pay; Admins requests, payments, messages and urgent
  alerts. One choice a person, for all their devices. Sign-in links and codes, digests, marketing and hiring never go by
  push.
- **Send path:** every in-app notice that `app.process_events` writes (one per recipient with an account, digests
  included) queues one alert per device of that person when the topic is kept (`push_outbox`, trigger on
  `notifications`), due with its email. A failure there never stops the notice, its email or its text. Customers' alerts
  that are not urgent wait for the end of the text quiet hours; urgent ones and staff alerts go at once. An alert read in
  the portal before it went is skipped. The Worker's five-minute tick runs `/api/jobs/push` only with the keys and only
  when something is due (`server_push_waiting`, one small call; none without the keys); "Send a test alert" sends at
  once. Encryption (RFC 8291, aes128gcm) and the VAPID signature (RFC 8292) use WebCrypto in the Worker
  (`web/src/lib/push/webpush.ts`, checked byte for byte against RFC 8291's example).
- **Pruning:** a push service answering 404 or 410 deletes the subscription; 429 and 5xx retry in 5 minutes (5 tries);
  other refusals are counted and the third in a row (a key change) deletes it. Alerts are kept 30 days. At most 10
  devices a person (the oldest goes). A browser that replaced its push address is re-sent the next time the card opens.
- **Keys (owner, once):** the VAPID key pair lives only in the vault of the live database, as `deploy_vapid_public_key` and
  `deploy_vapid_private_key`; the deploy passes them to the Worker as `VAPID_PUBLIC_KEY` and `VAPID_PRIVATE_KEY`. Until
  both are there, alerts are off: no card, no invitation, no job call, and My phone alerts says what is missing. Make
  them on any computer with Node 18 or later (prints both values; nothing is saved):
  `node -e "const k=require('crypto').generateKeyPairSync('ec',{namedCurve:'prime256v1'}).privateKey.export({format:'jwk'});const b=s=>Buffer.from(s,'base64url');console.log('deploy_vapid_public_key='+Buffer.concat([Buffer.from([4]),b(k.x),b(k.y)]).toString('base64url'));console.log('deploy_vapid_private_key='+k.d)"`
  then add each to the vault of the live database and deploy. Since the move to the company's server
  (infra/vps/CUTOVER.md) that is the server's database, not a Supabase project: open Studio through the SSH tunnel
  (`ssh -L 3000:127.0.0.1:3000 ubuntu@<server>`, then http://localhost:3000), SQL editor,
  `select vault.create_secret('<value>', 'deploy_vapid_public_key');` and the same for `deploy_vapid_private_key`. The
  deploy's "Secrets" step reads them there (scripts/deploy/supabase.sh secrets, the live backend's vault) and says
  "Phone alerts: on"; each deploy's "Waiting on an owner step" annotation lists them until then (0321).
  Changing the keys later ends every subscription (people turn alerts on again).
- **Off switch:** Settings > Text alerts, "Phone alerts" (`program_settings.push_enabled`, on).
- **Privacy policy:** one paragraph after the text alerts paragraph: the push address and two keys of a device, used
  only for alerts, encrypted, deleted when alerts are turned off or the device stops accepting them.
- **Local and tests:** `PUSH_PROVIDER=fake` (in `.env.example`) turns the cards on with a key pair made in memory for
  the process and records alerts as sent. Never in production; no key is in the repository.
- Code: `web/src/lib/push/`, `web/src/features/push/`, `web/src/server/push.ts`, `web/src/server/actions/push.ts`,
  `web/src/app/api/jobs/push/route.ts`, `web/src/app/manifest.webmanifest/route.ts`, `web/src/app/app/route.ts`,
  `web/src/app/admin/alerts/page.tsx`, `web/public/push-sw.js`, `web/public/icons/` (`web/scripts/gen-app-icons.mjs`),
  `web/custom-worker.ts`, `web/src/lib/edge/cron-gate.ts`, `web/src/lib/security/csp.ts`, `scripts/deploy/supabase.sh`,
  `.github/workflows/ci.yml`.
- Tests: `supabase/tests/99_push_alerts.sql`, `web/src/lib/push/webpush.test.ts`, `web/src/features/push/topics.test.ts`,
  `web/src/lib/edge/cron-gate-push.test.ts`, `web/tests/e2e/push-alerts.spec.ts`.

## Guides

- `renter/after-your-trip`, `owner/notices-profile-and-leaving`, `investor/profile-and-notices`, `va/shared-tools`,
  `field/report-rentals-referrals-and-profile`: a "Phone alerts" part (turn on, topics, test, iPhone Home Screen).
- `admin/text-alerts-email-text-or-both`: "Phone alerts" (who gets what, My phone alerts, the switch, the two vault keys).
