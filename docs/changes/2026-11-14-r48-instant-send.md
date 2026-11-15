# Texts and emails within seconds, and live staff pages (Release 48: 2980)

Migration `2980_r48_instant_send.sql`.

The owner: "Emails and texts still aren't anywhere near instant ... Did u implement realtime?" A write through the site already asked the database at once (0670), but what the database queued by itself (a timer, a reminder coming due, a webhook handled in SQL) waited for the minute tick, and an email that was not urgent waited for the sender's next minute.

- A NOTIFY on `carmacars_send` (payload `table:id`, nothing else) when a row is queued in `phone_outbox`, `notification_outbox` or `push_outbox` (inserted, or put back to queued), and on every new notice and event. The site on the company's server keeps one LISTEN connection (`web/src/lib/platform/db-listen.ts`, started by `scripts/vps-server.mjs` with the cron): a notify runs the same kick as a write, debounced 250 ms, one at a time, at most one start a second; the connection comes back by itself (1, 2, 5, 10, 30 s) and every reconnect kicks once for what was queued while it was down. The minute tick stays as the safety net. The phone job runs only its texts from the listen (`{"only": "texts"}`).
- The listen logs in as `carmacars_listen`: it may connect and listen, nothing else. The deploy (`scripts/deploy/web-vps-remote.sh listen_env`) makes its password once on the server, sets it, and adds `DATABASE_LISTEN_URL` to the site's settings; without the role (migration not applied yet) the site runs as before. The Docker image carries the `postgres` module for it. The Cloudflare Worker build keeps the kick after a write and the minute tick (no long-lived connection there).
- Every email at once: the kick asks the email sender whenever any email is due, not only an urgent one, at most every 5 seconds (was 20). The day's budgets and the class order still hold.
- Queued to sent, per message: `due_at` (when it was first due) and `send_ms` on the three queues, set by a trigger. Admin > Logs > Emails shows **Took** on each email and the last 24 hours' average and 95th percentile for emails, texts and phone alerts (`server_send_latency`).
- Live staff pages: the To do lists (`tasks`) and the phone conversations now bump the live topics; a new area `staff:tasks` for Admin and every staff member. The Alerts bell and page, chat and messages, the Admin and staff booking lists, Today and To do refresh within about a second when Realtime is joined, else within 2 seconds by polling; nothing changes when the socket is down.
- `web/scripts/listen-check.mjs`: on a test database, queues a test text (for tomorrow, so nothing sends it), checks the LISTEN receives it and prints how long it took, then marks it skipped.
- Tests: `supabase/tests/99_r48_instant_send.sql`; unit: `lib/platform/db-listen.test.ts`, `features/live/realtime/areas.test.ts`.

## Guides

No guide change: nothing a person does changes; messages only go out sooner and the To do lists update by themselves.
