# Tracker ingest and the relay (migration 0400)

How positions reach CarmaCars from the trackers, and what is still needed from the tracker maker. The dashboard itself is
in `docs/changes/2026-11-06-tracker-dashboard.md`.

## The endpoint

`POST https://carmacars.ca/api/tracker/ingest` (optional `?format=` for a vendor adapter; `generic` by default).

Headers:

| Header | Value |
| --- | --- |
| `content-type` | `application/json` |
| `x-tracker-timestamp` | Unix seconds when the batch was signed (refused if more than 5 minutes off) |
| `x-tracker-signature` | `v1=` and the hex HMAC-SHA256 of `<timestamp>.<raw body>` with the ingest key |

The ingest key is made in Admin > Cars > Fleet tracking > Settings > **Make the ingest key** (shown once, kept in Supabase
Vault). `web/src/integrations/tracker/ingest.ts` has `signedHeaders()` for senders written in JavaScript.

Body (at most 5,000 points, 512 KB):

```json
{"points": [
  {"device": "860000000000001", "at": "2026-11-06T15:04:05Z", "lat": 43.6532, "lng": -79.3832,
   "speed": 54, "heading": 270, "ignition": true, "odometer": 12345.6, "battery": 87, "power": true, "fuel": 55}
]}
```

- Required: `device` (the IMEI or serial, 3 to 64 letters, digits, `.`, `-`, `:`, `_`), `at` (ISO 8601 with `Z` or an offset,
  or Unix seconds or milliseconds), `lat`, `lng`.
- Optional: `speed` km/h, `heading` degrees from north, `ignition` (ACC), `odometer` km, `battery` (the tracker's own backup
  battery, %), `power` (false: the tracker lost the car's power), `fuel` %. A field left out keeps its last value, so a
  heartbeat can carry only the battery and power with the last fix's position.
- Aliases accepted: `latitude`, `lon`/`longitude`, `time`, `course`, `acc`.

Answers: `200` with `{received, accepted, old, skipped, devices, new_devices, kept}`; `401` bad or missing signature; `400`
not JSON; `413` too large; `503` no ingest key yet; `500` retry later. A batch sent twice changes nothing (points not newer
than a device's last report are skipped), so a sender retries freely.

## What the database keeps (cheap on writes and storage)

- **One hot row per device** (`tracker_status`): updated once per device per batch, in place (no index touched,
  fillfactor 70, no row audit). The map, the "Tracker seen" column and the Live map read it.
- **History** (`tracker_points`): thinned as it arrives: a moving car keeps one point per `history_seconds` (60), an
  ignition change always, a parked car one point an hour. Integers for the coordinates, one index, no row audit. About
  60 bytes a point: a car driving 3 hours a day is about 11 KB a day, 1 MB per car over the 90 days kept.
- **Trips** (`tracker_trips`): one row when the ignition goes off (km from the odometer, else the GPS distance; top speed;
  the booking it belongs to). **Alerts** (`tracker_alerts`): one row each, deduplicated.
- **Retention**: the hourly job deletes history older than `history_days` (90) and trips and seen alerts older than
  `trip_days` (365), at most 50,000 points a run. Both are Admin settings, at most 365 days (the privacy policy keeps
  Tracker data 12 months).
- An unknown device id becomes an in-stock device (Admin pairs it); a device on no car keeps only its hot row.

## Adapters and the relay

Most low-cost Chinese trackers speak a binary TCP protocol, not HTTPS: **GT06** (Concox and clones) or **JT808** (the
Chinese national standard, JT/T 808). They keep a TCP connection to a server, log in with their IMEI, send a position every
10 to 30 seconds while moving and a heartbeat while parked, and expect an answer to some frames or they reconnect.

The plan: a small relay on CarmaCars' OVH server (`infra/vps/tracker-relay/`) holds those connections, answers the device,
decodes each frame and posts the generic JSON above in signed batches every 15 seconds. The website never holds a TCP
connection, the database gets one call per batch, and the endpoint stays the same whatever protocol a tracker speaks.

- **GT06**: written. `web/src/integrations/tracker/gt06.ts` decodes login (0x01), location (0x12, 0x22 with ACC and
  mileage), status/heartbeat (0x13: ACC, power connected, battery level) and alarm (0x16, 0x26) frames, checks the CRC
  (CRC-16/X-25, tested against the protocol document's login frame) and builds the replies. `relay.mjs` is the TCP server
  with its systemd unit `carmacars-tracker-relay.service`. Not started on the server yet.
- **JT808**: not written; the same relay gets a second decoder when the trackers turn out to speak it. Its frames start and
  end with `0x7E` (with `0x7D` escaping), carry the terminal's phone number in BCD, and need the register (0x0100, answered
  by 0x8100 with an auth code), authenticate (0x0102) and general answer (0x8001) exchange; positions are 0x0200 (alarm and
  status words, ACC in bit 0 of status, latitude and longitude times 10^6, speed in 0.1 km/h, time in BCD, China time
  UTC+8 by default).
- **A tracker company's HTTP push** (a cloud platform that posts JSON): an entry in `adapters` in `ingest.ts` maps its
  fields to a point; it posts to `/api/tracker/ingest?format=<name>` signed the same way (or through the relay).

### To start the relay (once the hardware details are in)

1. Check `gt06.ts` against CarmaCars' tracker's protocol document (frame start, protocol numbers, clock time zone, where ACC
   and the battery come) and adjust; add a test with a frame captured from a real device.
2. Make the ingest key in Admin; put `TRACKER_INGEST_URL=https://carmacars.ca/api/tracker/ingest` and
   `TRACKER_INGEST_KEY=...` in `/opt/carmacars/tracker-relay.env` on the server (mode 600).
3. Install `carmacars-tracker-relay.service`, open TCP port 5023 in the firewall, start it.
4. Set each tracker (SMS command per its manual) to the server's address and port 5023, reporting every 10 to 30 seconds.
5. Pair each tracker with its car in Admin > Cars > Fleet tracking (it shows under "Reporting, not on a car yet").

## The simulator

`web/src/features/tracking/sim.ts`: cars driving the GTA's highways (the Live map's basemap), 20 minutes driving and 4
parked, one speeding, one with a low battery, one unplugged, one parked downtown. Used three ways:

- `node --experimental-strip-types web/scripts/tracker-sim.mjs --key trk_... --url http://localhost:3000` posts signed
  batches to a local site (devices `SIM-0001`...; pair them in Admin). `--once 600` sends one batch of the last 10 minutes.
- The end-to-end test signs and posts the same points.
- Admin **demo mode** (off by default): the dashboard and the Live map draw the simulated cars over the real ones that have
  no position, in the browser, with nothing written.
