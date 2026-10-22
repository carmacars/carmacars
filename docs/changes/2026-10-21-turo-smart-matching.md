# Turo emails find their car by themselves (migration 0088)

The owner, October 21, 2026: "I want this to be smart enough to match the names to the cars by itself, I don't want to
be finicking with it every single time." And: pull the guest's name and phone from Turo's emails into our system, for
the trip only, never for marketing.

Before (0063): each car on Turo needed staff to type its "name on Turo" (and optionally its Turo car number) in Calendar
sync; an email went to the car by Turo car number, VIN, plate, that name, then make and model only when unique; any tie
went to "Turo emails to check". Only the guest's first name was kept.

Now: no setup per car. Every active real car is a candidate, each email is scored against all of them, every match
teaches the car what Turo calls it, the model picks between a short list, and only a truly unclear email asks a person,
once, with one click.

## 1. Candidates

Every car that is not retired, exited, a total loss or declined, and not a sample (`app.turo_candidate`). A sample car is
a candidate only when someone typed its name on Turo or confirmed an email for it. Onboarding cars count: they are often
on Turo already. Nothing has to be marked "on Turo".

## 2. Scores (web/src/features/turo/match.ts)

What the email says about the car (`signalsOf`): Turo car ids in its links and image addresses (`/car-rental/.../2711093`,
`/vehicles/2711093`, `/vehicle/images/2711093/...`, `vehicleId=`; never the trip's own number), the car's name as Turo
writes it (the listing link's text, an image's alt text, a "Car" or "Vehicle" line, "your <car>"), VINs, colour words
(in the car's name, alt text or a "Colour:" line), the trip number, the guest and the dates.

Points per car, added up:

| Signal | Points |
| --- | --- |
| A Turo car id known for the car (learned, or typed as the override) | +100 |
| VIN | +100 |
| The trip is already on this car (a change or extension email) | +100 |
| Plate (spaces and dashes ignored) | +90 |
| The typed "name on Turo" override appears in the email | +80 |
| A learned Turo name, only when it tells this car apart (identical cars share Turo's "Make Model Year") | +35 |
| Make (aliases: Mercedes, Benz, VW, Chevy; any case) | +10 |
| Model written as ours (C300 = C 300, Model3 = Model 3, CR-V = CRV) | +30 |
| Model's family (C-Class for a C 300, GLC for a GLC 300, 3 Series for a 330i, RX for an RX 350) | +22 |
| Year | +10 |
| Each trim word in the name (SEL, R-Line, Comfortline), at most 2 | +15 |
| Colour | +12 |
| The guest had a trip in this car around these dates | +8 |
| A Turo car id other than the car's own | -40 |
| Another make named | -40 |
| Another year named | -25 |
| Another colour named | -15 |
| The make but not the model | -10 |
| The car is busy then (another Turo trip or a confirmed booking) | -15 |

A winner: 90 or more and 30 ahead of the next car, or 40 or more and 15 ahead. Otherwise the cars within 30 points of
the best (and at least 20) are the short list. The reasons are kept in words ("+10 Volkswagen, +30 Jetta, +10 2021").

Real fleet check (production, October 21): three Volkswagen Jettas, two of them black 2021s (SEL and S / SE / R-Line).
"Volkswagen Jetta 2021" alone ties them (Turo writes the same name for both), so the first email for each waits once;
"Jetta SEL" or "R-Line" in the name, a plate or a Turo car id decides; after one answer each, their Turo car ids decide.

## 3. Learning (turo_identities)

Every match, automatic or chosen by staff, stores on the car the Turo car ids the email carried and the exact Turo name
(`app.turo_learn`). The next email with that Turo car id matches at once (+100).

- A Turo car id belongs to one car (unique). Staff choosing another car moves it (audit log); an automatic match never
  takes it from another car.
- A car that already has a Turo car id gets -40 for an email with a different one: the second identical car's first
  email goes to the car without an id.
- A learned name helps only when it tells the car apart, so two identical cars are never decided by a name alone.
- Learning a Turo car id resolves at once the other emails still waiting with the same id (`app.turo_review_relearn`).
- Each car in Calendar sync lists what it learned, with Forget for a wrong one. The overrides typed before 0088 were
  learned as staff identities.

## 4. The model's pick (Workers AI)

When the rules leave two or more cars, the Worker asks Workers AI with the email's car text and the short list (id,
year, make, model, trim, colour, the plate's last 3), the answer constrained by the schema to one of those ids or
"unsure" (`AI_CAR_SYSTEM`, `aiCarSchema`; "never guess between identical cars"). The answer counts only if it is one of
the short list (`acceptAiCar`). Same budget as before: `turo_email_ai` and the day's shared neurons
(`chat_ai_total_daily_neurons`, `turo_match_keys.ai_ok`), logged in `provider_calls` (`purpose = 'turo_email'`). The
usage guard of the assistant branch (0080) is not on main yet; when it lands, this call goes through it like the other
`turo_email` call. The general reading's "car" answer (0063's `mergeAi`) now counts only when it is on the short list.

## 5. Which car is this?

Only an email whose car is still unclear waits ("Which car: matches 2 cars (...)", a Fleet task "Which car is this?
Turo email: ..."). Admin > Today shows "Turo emails: which car is this?" with **Choose the car**, which opens Calendar
sync with the pop-up (`?pick=`): what Turo calls the car and the trip, the best guesses first (colour, plate's last 3),
one click each, then "Another car" for any candidate. The answer applies the trip, checks the email, closes the task and
teaches the car (3). An email missing more than the car (dates, trip number) keeps "Add as a Turo trip", which now
teaches the car too. Admin > Today prompts (branch guided's `TASK_PROMPTS`) were not on main when this was finished, so
this uses the existing To do line and the Calendar sync list.

## 6. The guest

The email's guest as shown (`guestOf` in match.ts): the full name ("Ayesha K.", "Priya Shah"; the longest form the email
uses), a phone (North American, toll-free excluded) and an email only on a line about the guest (their name, "guest",
"renter", "driver"), never a masked number (`(***) ***-0177`, `+1 ••• ••• 0101`, `01XX`) and never Turo's own support
line or a turo.com address. Nothing is guessed.

- Kept on the Turo trip (`turo_calendar_trips.guest_name`, `guest_phone`, `guest_email`); a later email adds, never
  erases. Shown on the trip in Calendar sync (with Call) and on the car's calendar block ("Turo trip 48211907 · Ayesha K.
  · 416-555-0199"; blocks are staff-only, and the exports to other platforms still say only "Booked").
- One contact record per guest: a lead of kind `turo_guest`, source `turo`, matched by phone, then email, then the name
  on the same trip, with its trips and cars (`app.turo_trip_guest`). Never a renter account, never an email or text sent
  by itself. A check refuses marketing consent on these records (`leads_turo_guest_no_marketing`).
- Admin note on each record and on Calendar sync: "Turo guest: details from Turo's trip email, used only to contact
  them about that trip. Never add them to a marketing list or send promotions (CASL, and Turo's rules on taking guests
  off the platform)."
- Recognised when they reach us: Live chat names a conversation whose phone or email is a Turo guest's "Priya Shah
  (Turo guest)" (`app.visitor_chat_name`); `app.turo_guest_by_phone` gives the guest, trip and car for a number. The Quo
  phone branch (0085, not on main yet) matches callers through `leads` by phone, so a Turo guest's call is recognised as
  that lead with no further change.
- The email row keeps the guest's phone and email only while it waits for a person (cleared once the trip has them, on
  dismissal, and after 14 days). Turo guest records are deleted 24 months after their last trip.

## 7. Privacy policy (for the lawyer)

Two rows added to the privacy policy (`legal.privacy`, by the migration; `docs/source/website_terms_policies.md` for the
seed), exact wording:

- Section 1, "What we collect and why": "| Trips booked through another platform (such as Turo): the name, and the phone
  or email if the platform gives them to us, of the guest who booked one of our cars there | To manage that trip with
  the guest, never for marketing |"
- Section 6, "How long we keep it": "| Details of guests who booked through another platform | 24 months after their
  last trip |"

## 8. Backfill

The migration resolves the waiting emails it can (learned Turo car ids, trips already on a car) and resets
`rematched_at`, so the Worker's five-minute cron (the gate's new `turo` flag, `public.server_jobs_due`) runs
`/api/jobs/turo-rematch`: every email waiting for its car is scored again from what the database kept (subject, Turo's
car name, its Turo car ids, the redacted excerpt), with the model once per email, and applied when clear
(`app.turo_rematch_due`, `app.turo_rematch_result`). The same job runs again whenever a candidate car, a typed
override or a learned identity changes. Production had no Turo email stored on October 21.

## 9. Files

| Where | What |
| --- | --- |
| `supabase/migrations/0088_turo_smart_matching.sql` | `turo_identities`; new columns on `turo_inbound_emails` (Turo car ids, Turo's car name, candidates, the reasons, the guest, `rematched_at`) and `turo_calendar_trips` (the guest, `lead_id`); `leads.kind` `turo_guest` with no marketing; `app.turo_candidate`, `turo_match_keys` (every candidate with trim, colour, identities, busy times; known trips), `turo_learn`, `turo_email_set_car`, `turo_review_relearn`, `turo_trip_guest`, `turo_guest_by_phone`, `turo_feed_refresh` (the guest on the block), `turo_email_receive` (learns, keeps the guest, the car of a change from its trip, "Which car" reasons and task), `turo_rematch_due` and `turo_rematch_result`, `server_jobs_due` (turo), Calendar sync read (identities, guests, guesses, candidates, the note) and actions (`turo_review_pick`, `turo_identity_remove`; Add as a Turo trip teaches), To do, the door, Live chat names, the privacy rows, the backfill, the guides |
| `web/src/features/turo/match.ts` | Signals, scores, decision, the model's prompt and schema, the guest's details |
| `web/src/features/turo/email.ts` | `parseMime` keeps the HTML; `parseTuroEmail` uses match.ts and returns the guest, the Turo identifiers, the guesses |
| `web/src/app/api/inbound/turo/route.ts`, `web/src/server/turo-ai.ts` | The model's pick between the short list; the new fields to the database |
| `web/src/app/api/jobs/turo-rematch/route.ts`, `web/src/lib/edge/cron-gate.ts`, `web/custom-worker.ts` | The rematch job and its gate |
| `web/src/features/calendar/TuroSync.tsx`, `web/src/styles/admin.css` | "Which car is this?" pop-up; each car's learned names and Turo car numbers with Forget; the override optional; the guest on each trip |
| `web/src/lib/schema-marker.ts` | `0088` |

## 10. Tests

- Unit (`web/src/features/turo/match.test.ts`, 14 tests, and the 13 of `email.test.ts` unchanged): no setup per car on a
  fleet shaped like the real one; aliases (C-Class, C 300, Model3, 3 Series, GLC, Mercedes); another year or make never
  wins; the two black 2021 Jettas tie, then a learned Turo car id decides and the other Jetta gets any new id; a learned
  name decides only when it tells the car apart; plate, VIN, override; colour (alt text, "Colour:"), trim and year tell
  two of a model apart; a change email without the car by its trip; a busy car; alt text and image ids; the model's short
  list and refusals; the reasons in words; the guest (full name, phone variants, masked numbers, Turo's own number, an
  email next to the guest); the 0063 samples with no names typed. New samples: `booked-jetta-link.eml`,
  `booked-alt-malibu.eml`, `booked-masked.eml`, `changed-no-car.eml`. All unit tests: 229 passed.
- Database: `supabase/tests/55_turo_smart_matching.sql` (44 assertions: candidates, learning, one car per Turo id, the
  guest and the contact record, no marketing, "Which car is this?" and its To do link, the relearn, a change by its
  trip, the rematch backfill and the cron gate, Add as a Turo trip teaches, Live chat). Suite 42 now expects the guest on
  the block and "Which car" reasons. Suite 03 lists `turo_identities` among the tables audited by their functions. Full suite
  (`scripts/test.sh`): 4,719 assertions passed, 0 failed.
- End to end: `web/tests/e2e/turo-smart.spec.ts` at 375 and 1440 (two identical cars, To do, the pop-up with axe and no
  overflow, one click, learned, the next email applied by itself, the guest on the trip); `turo-email.spec.ts` follows
  the optional override and the guest on the block. Run locally at both widths with `calendar-sync.spec.ts` and `gaps.spec.ts`: all passed.
  The rematch job was also run by hand against the local server: a waiting email for a unique car was applied ("Matched
  again").

## Guides

`admin/calendar-sync-with-turo-and-other-platforms` (set up once, "How Turo emails find their car (automatic)", the guest,
"Which car is this?") and `va/fleet` (Calendar sync with Turo: automatic, the pop-up, the guest), published by the
migration (`supabase/seed/0088_gen_guides.mjs`).

## Not done

- Admin > Today prompts: branch guided's `TASK_PROMPTS` registry is not on main; the To do line and the Calendar sync
  pop-up are used.
- Quo: the phone branch (0085) is not on main; its caller matching finds Turo guests through `leads` once merged.
