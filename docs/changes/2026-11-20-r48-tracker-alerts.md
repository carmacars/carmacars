# Release 48, part TRK: tracker alerts and the pound database

Migrations `3320_r48trk_tracker_events.sql`, `3321_r48trk_notifications.sql` (catalogue block: `supabase/seed/3321_gen_catalogue.mjs`),
`3322_r48trk_guides_academy.sql` (guides block: `supabase/seed/3322_gen_guides.mjs`), `3323_r48trk_speeding_one_charge.sql`, `3326_r48trk_border_alerts.sql` (catalogue block: `supabase/seed/3326_gen_catalogue.mjs`). Schema marker 3326. Built on r48-fe (b9c07da1).

The owner (Nov 20): tracker events (speeding, harsh driving, geofence exit, after-hours, tamper or unplug, a pound) create alerts,
deduplicated; the renter is told plainly what happened, the fee and the clause, calm and firm; the car's owner is told through
their own preferences; Admin and Fleet get an evidence record per event that goes into the evidence registry and the dispute kit;
a pound database, editable in Admin, flags a booking when a tracker parks at a pound and opens the recovery fee path.

**The trackers are not installed yet, so all of it is behind one setting, off by default**: Admin > Cars > Fleet tracking >
Tracker event settings > **Tracker events** (`tracker_settings.events_on`). Off, the ingest and the alerts are exactly those of
0400 (staff only). Nothing was duplicated: the fleet tracking of 0400 (alerts, the signed ingest, the simulator), the speeding
charges of 3102, the return charges and the evidence registry of 3190 and the dispute kit of 3192 are extended.

## What was built

### Events, one alert per window

- `app.tracker_ingest` is wrapped. On, `app.tracker_events_scan` reads the new readings of paired trackers before the batch moves
  the hot rows (a replayed or late reading is never read twice):
  - **Speeding record**, over 180, 220 or 300 km/h (rental agreement 10.5): one per car and window, at the highest limit passed,
    taken from the fastest reading. A higher limit passed later in the same window **raises the same record** (it keeps what it
    was first: `facts.raised_from`, `first_speed_kmh`) and tells the renter the new charge; it never makes a second alert. A
    record already charged is left as it is, and a higher limit after the charge is a record of its own. The 140 km/h alert
    level of 0400 stays (a heads-up, no charge) and does not double a record of a limit.
  - **Harsh driving**: the tracker's own alarm (`"event": "harsh_brake" | "harsh_accel" | "harsh_turn"` on a reading), or a change
    of speed of 14 km/h a second between two readings 1 to 10 seconds apart. Three in the window make one alert.
  - **Tampering**: the tracker's own alarm (`"event": "tamper"`). Unplugged (0400) stays as it is.
  - **Driving at night**: off by default, with its hours; once per car and night, to staff and the owner only (the agreement sets
    no curfew, so the renter is not told).
  - **Geofence exit** is 0400's left Ontario and left the zone; **after the return time** is 0400's overdue driving. They now get
    evidence records and notices.
- The window is `tracker_settings.event_window_minutes` (30): one alert per car and kind in it. The state-based alerts of 0400
  (left Ontario, the zone, once per trip or booking) keep their own once-only rules.
- New `tracker_alerts` columns: `tier`, `source` (reading, device_event, derived, job), `fee_code`, `clause`, `facts`,
  `renter_notice_at`, `owner_notice_at`, `line_item_id`. New kinds: `harsh_driving`, `after_hours`, `tamper`, `pound`.

### Leaving the province and leaving the country (3326)

- **Province**: 0400's Ontario alert (once per crossing into any other province or a state) now reaches Admins and on-duty Fleet
  at once by a locked staff alert (`tracker_province`: in-app and push), the urgent email `staff_border_alert` and a text; the
  owner (`owner_tracker_alert`, on by default, theirs to mute) and the renter (`renter_tracker_notice`, clause 10.1) as before.
- **Country**: the new kind `left_canada`, once per crossing (`tracker_status.outside_canada`), with its evidence record, the
  same staff alert (`tracker_canada`, locked), email and text, an urgent Fleet To do (`left_canada`), the owner's alert and the
  renter's notice. `app.tracker_in_canada` is rough (Ontario's outline, the 49th parallel west, the 45th east): a prompt to call.
- **Clause**: 10.1 now says that taking the car out of Canada always needs written approval (text version
  `rental-v3-25c8821e64`), published to accept as `rental-v3-r48trk2` with the speeding wording in the same summary.
- The staff texts go to the Admins and on-duty Fleet who have a valid mobile number on file; staff had no texts before this.

### The evidence record

- `tracker_evidence`: one per alert (a trigger, so every source is covered): the map point, speed, time, source and device, the
  fee and the clause, the readings 5 minutes each side, and a SHA-256 of the record. Filled after each batch and sealed 10 minutes
  after the event (`app.tracker_evidence_fill`, also hourly). It is kept when the alert is deleted by retention.
- **Charge** (`ops_do tracker_alert_charge`, an Admin or Finance): a speeding record becomes its speeding charge through
  `app.speeding_charge_add` (3102), with the record linked to the fee line (`supporting_refs.tracker_evidence_id`, a `fee_evidence`
  row). One charge per record; an event with no set charge is refused with its clause.
- **Evidence registry** (3190): `app.fee_evidence_have` finds the record on a line (`tracker_event`, `speed_series`, `tracker_map`).
- **Dispute kit** (3192): `public.server_dispute_evidence` carries `tracker_events`: every event of the booking, charged or not,
  with its readings, seal and the notice the renter got; the PDF (`web/src/server/agreements/dispute-pack.ts`) has a Tracker events
  section.

### Notices (definition of done: email, in-app and push, text, a preferences entry)

| Code | To | When | Preferences |
| --- | --- | --- | --- |
| `renter_tracker_notice` | renter | a charge or a breach: a speeding record, outside Ontario, past the return time, the Tracker unplugged or tampered with, at a pound | always sent (money and the agreement); its text is urgent |
| `renter_driving_notice` | renter | a heads-up with no charge: over the alert level, harsh driving | the renter may mute it |
| `owner_tracker_alert` | the car's owner | every event of their car but the tracker's battery and "not reporting" | the owner may mute it |
| `staff_pound_flag` | Fleet and Admins | a car at a pound | urgent: sent at once, not in the staff digest |

- Each is a branded CarmaCars email (`emails/src/emails/*.mjs`), an in-app notice and a push (topic `alerts`), and a text
  (`sms_templates`, the same words). The words are built in the database (`app.tracker_event_words`) from the settings, so a
  changed fee changes the notice.
- The renter's notice says what the Tracker recorded, the charge, the clause, and what we ask ("Please slow down."). The owner's
  says the event, the time and the place, never the renter or the booking (rental agreement 12.1).
- Staff keep `staff_tracker_alert` and `staff_tracker_alert_fleet` (0400, in-app and push, topic alerts) for every kind. Each new
  kind has its switch in Settings > Alerts beside the tracker rules of 0462 (`tracker_pound`, `tracker_tamper`, `tracker_harsh`,
  `tracker_night`): off, the alert, its evidence record and its To do are still made, and staff get no notice (nor the pound email).

### The pound database

- `pound_lots`: name, address, city, phone, hours, who tows there, pin, radius, checked. An Admin adds, edits and removes them on
  Cars > Fleet tracking > Pound lots (`ops_do pound_lot_save`); a lot a flag names is switched off, not deleted.
- Seeded with the seven lots the Toronto Police Service and Peel Regional Police publish (name, address, phone, source link), **with
  no pins and not checked**: **Find the pins from the addresses** fills them through the site's address lookup, or an Admin types
  them. A lot with no pin flags nothing. Hours are not published and are empty.
- A tracker parked (ignition off, under 3 km/h) inside a lot's radius (150 m unless the lot has its own) for 20 minutes: one `pound`
  alert with its evidence record, a `pound_flags` row on the booking, a line in the booking's history, an urgent Fleet To do
  (`pound_recovery`), the staff alert (in-app and push) and email, and the renter's and owner's notices. The hourly job catches a car that stopped
  reporting there.
- **Record the path** (`ops_do pound_flag_resolve`, an Admin, Finance or Fleet): the non-return charge or the theft recovery charge
  with the tow, impound and storage costs, through `app.return_charge_add` (3190) with the tracker's record attached; recovered with
  nothing to charge; or not a pound. A charge still waits for its other evidence (the final late notice, the police report, the
  receipt) as every fee does.

### The ingest

- `POST /api/tracker/ingest` was already signed (HMAC-SHA256 of the timestamp and the body, 5 minutes of tolerance, constant-time
  comparison). New: **replay protection** (the signature of each accepted request is kept 10 minutes; the same signed request again
  is 409), a **rate limit** (`tracker_settings.ingest_per_minute`, 240: more is 429 and the relay retries), and a sender that fails
  the signature 20 times in a minute is refused in the Worker for the rest of it (keyed on Cloudflare's `cf-connecting-ip`, never
  X-Forwarded-For). One database call per request (`public.server_tracker_ingest_signed`).
- **Fake provider** (`web/src/integrations/tracker/fake.ts`): the readings of each scenario (three speeding limits, the heads-up,
  harsh driving, tampering, unplugged, a pound, outside Ontario) in the ingest's JSON, for the unit, database and end-to-end tests.
- The GT06 relay passes the alarm of an alarm frame as the reading's event (`alarmEvent`: tamper, harsh acceleration, braking and
  turns). The codes are the Concox family's; check them against the hardware's protocol document before the relay starts.

### Screens (Admin, mirrored to staff, and the owner)

- **Admin > Cars > Fleet tracking**, below the map: Tracker events (the evidence table with Charge), Pound flags (Record the path),
  Pound lots (add, edit, remove, find the pins), Tracker event settings (the switch, the window, harsh driving, night hours, the
  pound radius and minutes, the ingest rate; the charges shown with a link to Settings > Program).
- **Staff Fleet map** (every staff function, as 3041): the same panel; Fleet records the path of a pound flag, Finance charges a
  speeding record, everyone else reads. The pound lots and the settings are Admin's.
- **Owner > a car's page**: Tracker alerts, the events of the last 30 days with the time and the place.
- The renter sees the notice in their portal's notifications and on their phone; the booking page is unchanged.
- The kit only (Card, Table, Act, badges, alerts; `tracking.css` for the stacked-cell helpers). Empty and error states in plain
  words; every button is the kit's Act (pressed, busy, done). Below 768 each row is a card; from 768 a stacked cell keeps a
  readable measure (the kit lets a table cell shrink to nothing, which broke a long lot name letter by letter), so the tables
  fit the card at 1280 and 1440 and scroll sideways at 768. No overflow and no crushed cell at 320, 375, 768, 1280 and 1440,
  with a long lot name and car name (the e2e test checks both).
- Loading skeletons: these are server-rendered parts of two existing routes; the route skeletons of release 48 part PF
  (`loading.tsx` on every portal route) cover them once merged. No `loading.tsx` was added here, so the two parts do not collide.

## Decisions

- **Speeding: one event is one charge, at the highest limit reached** (the owner confirmed it on Nov 20; 226 km/h is $1,000, not
  $500 plus $1,000). Rental agreement 10.5 and its three Fee Schedule lines say exactly that now (`docs/source/v2_rental.md`,
  text version `rental-v3-2948304058`; an event is the readings above 180 km/h within 30 minutes of each other). Migration
  `3323_r48trk_speeding_one_charge.sql` publishes the wording to accept (`terms_versions` `rental-v3-r48trk`), so the "We've
  updated our terms" pop-up opens once for every renter. The notice words, the guides, the academy and the Program settings hints
  say the same, and Charge refuses a second record of an event already charged. The amounts stay Program settings (3102).
- **"After-hours"** was read two ways and both are covered: driving after the return time (0400's alert, now with the renter's
  notice and the late return clause), and driving at night (new, off, staff and owner only because the agreement has no curfew).
- **No charge is taken automatically.** An event tells the renter the charge that applies; a person presses Charge.
- **The zone** (0400's optional circle) is CarmaCars' own watch area, not in the agreement: the owner and staff are told, not the renter.

## Security checklist (security-checklist-reel.md)

- 5 (rate limit per operation): the ingest is limited per signed request and per failing sender. 6 (replay): each signed request is
  single-use. 11 (spoofed IP): the sender key is `cf-connecting-ip`. 12 (views and RLS): no view; the five new tables have RLS
  (Admin all, staff read; the replay table has no policy), every new function is `security definer` with `search_path`, revoked
  from `public`, `anon` and `authenticated`. 13 (random tokens): the ingest key is `gen_random_uuid` (0400). 14 (timing): the
  signature comparison is constant-time (0400). 16 (prototype pollution): readings are read field by field. 17 (template
  injection): notice words are values, never templates; `<` and `>` are refused in a lot's text.
- Not applicable: 1, 9, 10 (the proxy and cache, unchanged), 2 to 4, 20 (no sign-in change), 7 (no new regular expression on user
  text beyond the device id pattern of 0400), 8 (no JWT), 15, 18, 19 (no crypto mode, XML or socket).

## Tests

- Database: `supabase/tests/99_r48trk_tracker_events.sql` (the gate, the settings, one record per limit and window, the evidence
  record and its seal, the notices to renter, owner and staff with their texts and preferences, harsh driving, tampering, night,
  Charge with the registry and the dispute kit, the pound lots, the flag, the To do, the path, the reads per role, the replay
  guard and the rate, privileges and retention). `99_tracker_dashboard.sql` passes unchanged after it; `99_staff_alerts.sql` counts
  the four new tracker rules.
- Base tests updated: `71_text_alerts.sql` (the three new texts), `07_notifications.sql` (the four emails and the new link path;
  the tracker emails are built in this part's suite, as tracker events are off for the base suites), `03_flows.sql` (the harsh
  driving marks are telemetry, with the position history).
- Unit: `integrations/tracker/ingest.test.ts` (the event field, the signature returned for the replay guard, the failing sender),
  `fake.test.ts`, `gt06.test.ts` (alarm events), `features/tracking/events.test.ts`.
- End to end: `web/tests/e2e/r48trk-tracker-events.spec.ts` at 375 and 1440 (the fake provider's signed readings, the event and its
  evidence on Admin and on the staff map, the renter's and owner's notices queued, Charge, a pound flag and its path, the owner's
  page, a replay refused; axe and no overflow), and the screens at 320, 375, 768, 1280 and 1440.

## Guides

- `admin/fleet-and-listings`: Tracker events, evidence and pound flags (release 48).
- `va/fleet`: Tracker events and pound flags (release 48).
- `owner/home-and-your-vehicles`: Tracker alerts (3355: the switches are under Account > Notifications).
- `owner/notices-profile-and-leaving`: Tracker alerts (release 48): the owner's set, on and off to start with (3355).
- `admin/settings`: Owner tracker alerts follow Tracker events; the auto shops and shipping ports watched; impound lots are the pound lots (3355).
- `renter/during-your-trip`: Notices from the car's Tracker (release 48).
- Academy: the section "Tracker events and pound flags" (two lessons, five questions) on the fleet, finance, customer service and
  admin paths; staff who had passed everything get 7 days for it. The guide PDFs were not re-rendered.

## Integration note (3325)

One speeding event is one charge also when an Admin or the connector adds it by hand: `app.speeding_charge_add` refuses a speeding charge within the tracker's event window of one already on the booking, at any limit. Void the first to bill another.

## Not done

- **Tracker events are off.** Turn them on once the trackers are installed and the points below are confirmed.
- The pound lots have no pins and no hours yet (see above); none was checked with the lot. Only Toronto and Peel are seeded: York,
  Durham, Halton, Hamilton and the OPP's contracted pounds are to add.
- The native apps have no screen for this (the push alerts reach them through the same topics).
- No kill switch command is sent by any of this: disabling stays the Admin-approved flow of 0020.
- The renter's booking page does not list the notices (they are in the portal's notifications).
- The booking page has no pound banner: the flag is in the booking's history and on Fleet's To do.
- A pound cost with no non-return or theft (a tow for a parking offence, the car then returned normally) is not one of the paths:
  Finance bills it as a ticket or a recovery cost on the Money tab.
- The lawyer has not reviewed the notice wording; the fees and clauses quoted are those of the rental agreement already in force.

## For the owner to confirm

1. Confirmed Nov 20: one speeding event bills only the highest limit passed. Still to confirm: the amounts ($500, $1,000, $2,500).
2. The heads-up level: 140 km/h (Tracking settings), a message with no charge.
3. The wording of the renter's notices ("Please slow down." and the others in `app.tracker_event_words`).
4. Harsh driving as a heads-up only (no charge), 3 events in 30 minutes.
5. What "after-hours" should mean: after the return time (on), driving at night (off). If a curfew is wanted, the agreement needs it.
6. The pound list: the seven lots seeded, their pins once found, the 150 m radius and 20 minutes; and which path is the default
   when a car is at a pound for a reason that is neither non-return nor theft.
7. Whether the car's owner should be told about every event (on) or only the serious ones.

## Owner alerts (3353), the integration of RW

RW (3264) and TRK (3320 to 3326) both built tracker events and the owner's tracker alert. TRK's pipeline is the base (the
signed, replay-protected, rate-limited ingest, the event table with its 30-minute window, the sealed evidence records, the
pound lots, the province and country exits); 3264 is gone and 3353 layers RW's extras on it:

- New kinds: `impact` (a crash) and `health` from the tracker's own events (with a `detail`, `web/src/integrations/tracker/ingest.ts`),
  `place` (an auto shop or shipping port of `tracker_places`, Settings > Notification preferences) and `theft` (moving with no
  booking, no Owner Booking and no staff job), each with its evidence record, once per car, kind and window.
- The owner's own set, in real time: an impound lot, auto shop or shipping port; possible theft (also out of Ontario or Canada);
  the tracker unplugged, offline or tampered with; a crash; a health warning; over 180 km/h. Each carries its notify type
  (3260): theft, tamper, crash and place on by default; health and speed off (the speed notice stays in the portal). Harsh
  driving and night driving are no longer an owner alert: they are in the weekly driving summary (off by default), with
  kilometres against the allowance.
- One `owner_tracker_alert` template: RW's copy with TRK's event variables. The owner's text is urgent.
- Everything waits for Tracker events and Owner notices (Tracking settings); the Program settings of 3264 are not added.

3354 delivers the owner's new-booking emails (still off in the catalogue) to an owner who turned "New bookings on your
cars" on, and registers the alert targets of dispute packs and To dos. 3355 publishes the guide chapters in their merged text.
