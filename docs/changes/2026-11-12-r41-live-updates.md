# Live updates on every portal (Release 41: 2522)

The owner, November 12: "I need real time or whatever it's called. Because currently not everything is loading right
away." Branch `r41-realtime`. Migration `2500_r41_live_updates.sql`; SCHEMA_MARKER 2522. Tests:
`supabase/tests/99_live_updates.sql`; unit tests `web/src/features/live/realtime/hub.test.ts`, `socket.test.ts`,
`areas.test.ts`; e2e `web/tests/e2e/live-updates.spec.ts`.

## 1. What changes for people

| Portal | Screens that now update by themselves (about 2 seconds, no reload, typed text kept) |
| --- | --- |
| Admin and office staff | Bookings (list, Now, past trips, payments, deposit reviews, money), one booking and its sub pages (handover, report, deposit review, signing), requests, offers, quotes, unanswered, leads and the Sales pages, messages and chat, the calendar, Today and the live boards, field jobs, schedules and hours, the home page; the alerts bell and its toast on every page |
| Field staff | The field pages (jobs, shifts, hours, checks) and the alerts bell |
| Renter | Every page of the renter portal: a booking's status, payment, agreement and checklist, the trips list, alerts |
| Owner | Every page of the owner portal: the dashboard, bookings, money, alerts |

A refresh waits while someone types in a field (until they leave it, at most 8 seconds), and changes close together make one
refresh. Hidden tabs read nothing; a tab shown again catches up at once.

## 2. How it works

| Item | What changed |
| --- | --- |
| Topics | `app.live_versions` keeps a version per topic: `staff:bookings`, `staff:requests`, `staff:leads`, `staff:messages`, `staff:field`, `booking:<id>`, `renter:<user>`, `owner:<user>`, `user:<user>`. The names given out are keyed hashes (`app.live_topic`, random key in `app.live_key`), 32 hex characters |
| Bumps | `app.live_watch` puts three statement triggers (transition tables) on 34 tables (bookings and their payments, deposits, agreements, signing, condition reports, verifications, calendar blocks; offers, request claims, info and change requests; leads and their claims, contacts, holds; messages and chat; field jobs, shifts, offers, slots, plans, availability; notifications). A statement adds its scopes to a transaction-local list; a deferred constraint trigger on `app.live_flush` bumps them at commit in sorted order (an instant's row lock, never a cycle) and, when Supabase Realtime is installed, calls `realtime.send` on a public channel of the same name. A bump never fails a write |
| Who may watch | `public.server_live_topics(p_user, p_scopes)` (service role): staff areas for Admin and office staff, the field area also for field staff, a booking for staff, its renter, drivers, owner or the field person on one of its jobs, the person's own `user:`, `renter:`, `owner:` topics. The frames (`app/admin`, `app/staff`, `app/account`, `app/owner` layouts) ask once per render, with their other reads; the booking layouts (`app/admin|staff/bookings/[number]/layout.tsx`, `LiveBooking`) ask for the booking |
| Reading | `public.live_poll(p_topics)` (anon): the versions of up to 24 names, straight from the browser to the database API (`publicRead`), never the Worker. `features/live/realtime/hub.ts`: every 2 s while visible and Realtime is not joined, every 60 s as a safety net while it is, nothing while hidden, longer waits after failures (to 30 s) |
| Realtime | `features/live/realtime/socket.ts` speaks the Realtime websocket (Phoenix 1.0.0) directly, so no page carries the Supabase client: public broadcast channels named by the topics. A server without Realtime fails twice and the tab stops trying for 10 minutes (sessionStorage) |
| Screens | `LivePortal` (the frames: areas by path, `areas.ts`), `LiveRefresh` (`router.refresh`, the typing wait, one refresh per burst), `AlertPulse` (moved to `features/motion/AlertPulse.tsx`): reads the newest alert when the person's topic moves, every 5 minutes otherwise (was 30 seconds) |
| Server | Kong routes `/realtime/v1/` to the Realtime container; the container is in `infra/vps/supabase/docker-compose.yml` behind the profile `realtime` (off); 2522 makes the `_realtime` schema it needs. `infra/vps/CUTOVER.md` has the one step to switch it on |

No data travels through a topic: a bump only makes the screen read again through its usual checked reads.

## Guides

No guide change: no screen's steps change; screens show changes by themselves instead of on reload.
