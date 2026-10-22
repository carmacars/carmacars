# Live visitors: a heartbeat, so people reading a page stay live (October 22, 2026)

The owner's report: Live visitors showed 0 while there were visitors on the site.

Migration `0103_live_visitors_heartbeat.sql` (0102 is taken by the performance branch). Tests
`supabase/tests/69_live_visitors_heartbeat.sql`, `web/src/features/live/heartbeat.test.ts`, `web/src/lib/track/shared.test.ts`,
end to end `web/tests/e2e/live-heartbeat.spec.ts` (375 and 1440). Guides generator `supabase/seed/0103_gen_guides.mjs`.
No applied migration was edited. Schema marker `0103`.

## 1. Cause

Read from production (read only) on October 22: 35 visits today, 1 shown as live.

- "On the site now" meant seen in the last 3 minutes. The tab's keep-alive every 30 seconds went through the full
  beacon (`app.track_ingest`: rate-limit rows, the chat lookup, the renter links, the settings), so it was as heavy as
  a page view, and only some sessions kept it up: several sessions show `last_seen_at` 2 to 10 minutes after their last
  event, many show none at all. A visitor reading one page for more than 3 minutes dropped off the list.
- Earlier the same day `/api/t` answered 502 after waiting 20 seconds while the database was overloaded. The Worker
  waited for the database on every beacon and turned a slow answer into a 502, so those batches and keep-alives were lost.
- No session was ever marked ended (`ended_at` was never set), so closing a tab did not take anyone off the list either;
  they only aged out.

## 2. Change

**The heartbeat (database).** `app.track_beat` (public wrapper `public.track_beat`, for anon and signed-in callers): one
UPDATE of the session by its id: last seen, the page (with analytics consent only), and ended or not. No event row, no
signal recomputed, no rate-limit row: the UPDATE's own WHERE clause writes a session at most once every 10 seconds (an
end, or a session coming back after it ended, always writes). It never creates a session, so it follows the consent the
page beacon already decided. It returns a staff invite to chat if one is waiting (as the beacon did, so an invite still
reaches a visitor who only reads), and whether the database has the session at all.

**The tracker (`web/src/features/live/beacon.ts`, `heartbeat.ts`).** While the page is visible: a heartbeat every
45 seconds (Admin setting), restarted by any other send so a busy page sends no extra one. It stops while the tab is
hidden and beats at once when it is shown again. On `pagehide`, `navigator.sendBeacon` sends the page's last events
with `end`, or an end heartbeat, and the session ends after its events are stored. Back from the back-forward cache, it
beats again and the session lives again. A batch the network lost (a network error or a 5xx) is sent once more with the
next; a heartbeat that finds no session (its first batch was lost) sends the page view once more.

**Consent: unchanged.** Heartbeats go only for a visitor who may be shown: analytics consent (implied in Canada outside
Quebec and the US, asked first elsewhere), a known customer on their own booking page, or an open chat. The page is
recorded with analytics consent only.

**`/api/t` never holds the browser (`custom-worker.ts`, and `src/app/api/t/route.ts` for `next start`).** The database
call runs in the background (`ctx.waitUntil` on the Worker, `after()` in the app) and gives up after 10 seconds. A
batch waits for it at most 2 seconds (its answer can carry a staff invite and the chat settings), a heartbeat 1.5 seconds;
after that the answer is 204 and the call completes in the background. The last batch of a page and an end heartbeat
are answered 204 at once. A slow or failing database now gives a 204, never a 502.

**Settings.**

| Setting (Admin > Settings > Program, "Live visitors and live chat") | Before | Now |
| --- | --- | --- |
| "On the site now" means seen in the last (minutes), `visitor_live_minutes` | 3 | 5 (default and the live row) |
| An open page says the visitor is still there every (seconds), `visitor_heartbeat_seconds` | (30, fixed) | 45 (15 to 300) |

The interval reaches the browser with the chat settings (`app.chat_public_cfg`, key `beat`).

**Admin > Today > Live visitors (and My work > Live visitors).** Refreshes every 15 seconds while visible (was 5, which
cost the database more than it showed) and at once when the tab is shown again. The first tiles are **Live now** and
**Visitors today** (people, with their visits, known and hot below). A line says how many visitors chose necessary
cookies only today (their latest cookie choice; never recorded, so in no count); visitors who have not answered the
banner where we ask first cannot be counted. With tracking off, the page says nothing is recorded, so nobody is counted.
`app.live_visitors` returns `today.visitors`, `today.untracked` and `beat_seconds`; an index on `cookie_consents(recorded_at)`
keeps the count cheap.

## 3. Cost

A heartbeat is one primary-key UPDATE (at most one write per session per 10 seconds) and an indexed look for a staff
invite. At 45 seconds it is fewer calls than the old 30-second keep-alive, each far lighter. The Live visitors page reads
a third as often.

## 4. Tests

- Database (`69_live_visitors_heartbeat.sql`, 40 checks): the settings and defaults; a heartbeat-only visitor whose last
  page view is 10 minutes old is live again, with no new event and page views unchanged; the 10-second limit; end and
  coming back; no session created, another browser's id refused, bad ids; consent (no session without it; an essential
  session's page not recorded); the staff invite; tracking off; visitors and untracked today; privileges. 39, 48, 56,
  67 and 68 pass unchanged.
- Unit: the timer on a fake clock (interval, hidden and shown, reset, stop and start, a new interval), the beat parser,
  the end flag, and the bounded wait.
- End to end at 375 and 1440 (`live-heartbeat.spec.ts`, the heartbeat lowered to 15 seconds): a visitor on one car page
  has their last page view made 10 minutes old, is not live, then the page's heartbeat brings them back on the Admin
  page (open before, refreshing by itself) with no new event; Live now and Visitors today show; closing the tab ends the
  visit and the row goes. Axe, overflow and copy checked.

## Guides

Admin and VA guides, chapter "Live visitors and live chat": "Live now" and "Visitors today", the 5-minute window and the
45-second heartbeat, the 15-second refresh, the line about necessary cookies, and where the two settings are
(`docs/guides/src/guides/admin.py`, `va.py`, exported to `docs/guides/content/*.json`, published by the migration). The
PDFs are printed again by the guides-pdf workflow.
