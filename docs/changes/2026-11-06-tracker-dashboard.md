# Fleet tracking: the tracker dashboard, ready for the hardware (0400, 0401)

The owner's brief: "fully custom tracker dashboard", and for the Live map "the map also layers every car's real road position
with a visual per vehicle". CarmaCars' trackers are its own, made in China, and not ready yet: everything is built for them
and fed by a simulator until they report. Before this, the tracker module had only a `none` adapter, the Tracker Fee from the
installation (0239) and "Tracker seen" on the cars list.

## What changed

- **Ingest** (`/api/tracker/ingest`): signed HTTPS batches of the generic JSON (device, time, position, speed, heading,
  ignition, odometer, battery, power, fuel). HMAC-SHA256 with the ingest key, checked in the Worker before the database is
  touched, refused after 5 minutes. One database call per batch (`app.tracker_ingest`). Format, answers and the relay plan:
  `docs/tracker-ingest.md`.
- **Cheap writes**: one hot row per device updated in place once per batch (no index touched, no row audit); the history
  thinned as it arrives (a moving car one point a minute, ignition changes, a parked car one an hour) into a compact table
  with no row audit; trips written once when they end; "Tracker seen" reads the hot row, so the audited device row is no
  longer written on every report. Retention: history 90 days and trips and alerts 365 by default (Admin settings, at most 365),
  deleted by the hourly job in slices.
- **Adapters**: the endpoint stays generic. GT06 is decoded by `web/src/integrations/tracker/gt06.ts` for the relay
  (`infra/vps/tracker-relay/`, a TCP server with its systemd unit, not started); JT808 is described for when it is needed;
  a vendor's HTTP push gets an entry in `adapters` (`?format=`).
- **Devices**: Admin pairs a tracker with a car (a reporting tracker shows under "Reporting, not on a car yet"); the install
  date starts the Tracker Fee (0239) when the car has none yet; a replacement keeps the first date and takes the old tracker
  off; Remove (or faulty). Last report and battery per tracker.
- **Dashboard**: Cars > **Fleet tracking** (a tab beside Vehicles, and in the Cars menu; no new top-level page). The Live
  map's dark panel: on rent, moving, parked and open alerts; every car's photo marker on the same self-hosted map (ring
  colour its state, arrow its heading) beside the list with the renter, booking, due-back time (late in red) and state; a
  car's card (last report, odometer, fuel, battery, power, trip under way). Alerts (speeding, left Ontario, left the
  optional zone, still driving after the return time, low tracker battery, unplugged, not reporting), each once, in the bell
  for Admins (`staff_tracker_alert`) and fleet staff (`staff_tracker_alert_fleet`), push topic `alerts`, with Show and Seen.
  Trips by booking with km and top speed; a trip's route drawn on the map. Fleet staff get the same panel at the top of
  Field jobs (`/staff/fleet#tracking`), without the trackers and settings.
- **Live map**: the Fleet layer (its toggle) shows the real positions with the car photo markers as soon as trackers
  report, and the demo cars in demo mode ("Fleet (6, demo)").
- **Privacy**: positions are for Admins and fleet staff only. The owner's read of `tracker_status` (0012, "keeps live
  location") and Finance's are removed; the new tables are Admin and fleet only. Retention is a setting.
- **Simulator** (`web/src/features/tracking/sim.ts`): cars on the GTA's highways; `web/scripts/tracker-sim.mjs` posts signed
  batches to a local site; the tests use it; Admin **demo mode** (off) draws it in the browser with nothing written.
- The car page's Tracker card shows the last report, battery and odometer and links to Fleet tracking (the "Coming soon"
  line is gone).

## The rental agreement and the privacy policy (for the lawyer)

The agreement already covers tracking: 12.1 (consent to GPS tracking for the whole Rental Period, location, speed, distance,
ignition and tampering), 12.2 (Tracker data as evidence), 12.3 ground 5 (stops reporting), 10.1 (the car stays in Ontario),
13 (Tracker data among the personal information). The privacy policy lists Tracker data and keeps it 12 months. Two points to
pass to the lawyer, no change made:

1. Agreement 12.1 and 13, privacy policy Part 2 and consent 1 say the car's owner can see its location during the rental.
   The platform now shows positions to Admins and fleet staff only. Narrower than disclosed, so allowed as written; the
   lawyer may want the wording to match (or the owner may want owners to see location again later).
2. The alerts (speeding, leaving Ontario or a zone, driving after the return time) use the data "to manage the rental and
   enforce the Rental Agreement" as disclosed. Confirm that is enough for the speeding alert, and whether the agreement should
   name the battery and power readings (the policy lists "tampering alerts").

## What the owner still needs to give

- The tracker's **protocol document** (GT06, JT808 or the maker's own) and whether it pushes over TCP or through the maker's
  cloud; the device clock's time zone; how ACC, battery and power are reported.
- Each tracker's **device ID** (IMEI or serial) and which car it goes in; then: make the ingest key, start the relay, set each
  tracker to the server's address and port, pair each tracker in Admin (steps in `docs/tracker-ingest.md`).

## Code and tests

- Migrations: `0400_tracker_dashboard.sql`, `0401_tracker_guides.sql` (`supabase/seed/0401_gen_guides.mjs`).
- Code: `web/src/integrations/tracker/ingest.ts`, `gt06.ts`; `web/src/server/tracker.ts`; `web/src/app/api/tracker/ingest/route.ts`;
  `web/src/app/api/staff/tracking/route.ts`; `web/src/features/tracking/` (model, sim, FleetTracking, IngestKey, CSS);
  `web/src/app/admin/vehicles/tracking/page.tsx`; `web/src/app/staff/fleet/page.tsx`; `web/src/features/live-map/engine.ts`
  (a car can be chosen, a trip's route, the zone); `web/src/server/admin/live-map.ts` (demo fleet); `web/scripts/tracker-sim.mjs`;
  `infra/vps/tracker-relay/`.
- Tests: `supabase/tests/99_tracker_dashboard.sql` (ingest, thinning, trips, replay, every alert once, notices, pairing and
  the fee date, the read's roles, settings, the job, retention, privacy); `03_flows`, `04_rls`, `07_notifications`,
  `99_push_alerts` updated; unit `ingest.test.ts`, `gt06.test.ts`, `sim.test.ts`, `model.test.ts`; e2e
  `web/tests/e2e/tracker-dashboard.spec.ts` (signed batches from the simulator, the dashboard, pairing, alerts, demo mode,
  the Live map layer, axe at 375 and 1440).

## Guides

- `admin/fleet-and-listings`: Fleet tracking, Pair a tracker with a car, Tracking settings (the "Coming soon" note removed).
- `va/fleet`: Fleet tracking on Field jobs.
