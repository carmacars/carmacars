# The assistant portal redesign, October 25, 2026

The owner: "need to make each staff portal extremely easy to use and extremely good UI. Attractive, appealing and
interactive." This record covers the assistant portal (`/va/**`: customer service, Sales, Fleet and Finance). Assistants
work 10-hour shifts on laptops and sometimes phones, so every function now lands on one place that says what to do next,
ordered by urgency, with live timers against the 5-minute first reply target.

No business logic, server action, database function or permission changed. Every page reads what it read before (or a
read its function already had: `requests`, `chat_counts`, `my_sales`, `finance_board`, `fleet_board`, `calendar`,
`ops_read reply_target`). Every route and `data-testid` is kept; the To do heading is still "To do".

Migration `supabase/migrations/0158_va_portal_design.sql` (SCHEMA_MARKER `0158`) carries only the guides block, generated
by `supabase/seed/0158_gen_guides.mjs`.

## 1. To do (`/va`), every function

- A dark header (portal-ui `PortalHero`): the function, today's date (Toronto time), how many things need you and how
  many lanes run late, Open, Overdue and Done today, and the function's quickest actions.
- **Next up**: the single most urgent task (escalated and overdue first, then priority, then the longest wait; replies
  past the target lead), its live timer, the action named for what it does ("Reply to the renter", "Review and send an
  offer") and **Take it**.
- **Your lanes, most urgent first**: the open tasks sorted into a few lanes per function, each a big tile with the count,
  what to do, the oldest item's live timer and how many are overdue. Reply lanes are timed against the first reply
  target (Program settings, 5 minutes by default): amber in the last minute, red with the word "late" past it. A lane
  past the target or overdue is outlined red; urgent and late, it turns black.

  | Function | Lanes |
  | --- | --- |
  | Customer service | Booking requests, Renter messages, Texts and calls, Live chat, Offers out, Signing and payment, Follow-ups |
  | Sales | Live chat, Booking requests, Offers out, Follow-ups, Texts and calls, Signing and payment |
  | Finance | Payments to fix, Deposits to settle, Refunds waiting, Owner statements, Tolls and tickets |
  | Fleet | Incidents and breakdowns, Handovers and returns, Checks and photos, Car paperwork and service |

  A task type no lane takes shows under Other tasks. Lanes without a screen of their own open the list filtered to the
  lane (`/va?lane=phone`).
- Customer service and Sales: **Waiting for a reply**, every booking request, renter message, missed call and chat, the
  longest wait first, each with its timer and its reply button (red once late).
- Sales: the month's commission ring in the header (rental days toward 100, the rate now and the days to the next tier)
  and **Follow-ups due**.
- Fleet: **Today: handovers, returns and moves** by the clock (who has each job, not acknowledged, nobody assigned, past
  its time) and **Cars right now** (return late, goes out today, back today, on rent, on Turo, blocked, available).
- Finance: **Money today**, the counts of failed payments, deposits to take and due back, refunds to request and
  waiting, and owner statements, each opening its list on the money board.
- A Find box on every home (Find a renter; Sales: Find a car) that `/` focuses; the keyboard shortcuts in one line on a
  computer.
- **Every open task**: the previous table, filters and actions, with a live "Waiting" timer.

The lanes are pure functions (`web/src/features/va/lanes.ts`, tested in `lanes.test.ts`); the car states too
(`carboard.ts`, `carboard.test.ts`).

## 2. Other pages

- Requests: four figures (waiting for an offer, past the target, offers out, offers expired), counts on the state filters,
  the requests waiting first with the longest wait on top, a live timer per row and a "Review and offer" button.
- Renter messages: a conversation list (who, which way and by what, the booking, two lines of the message), with a
  "From renters" filter.
- My sales: a header with Earned, Approved and the period's booked revenue, and for Sales the ring with the tier ladder
  (10% under 50 days, 15% from 50, 20% from 100, the current tier marked). The commissions, tiles and tables below are
  unchanged.
- Field jobs (Fleet): today's timeline and every car's state above the job tables.
- Payments, deposits, refunds (Finance): eight figures at the top, each jumping to its list.
- Find a renter: a hint before the first search, a larger search box.
- Every `/va` page: a loading skeleton while it reads (`web/src/app/va/loading.tsx`), and the shared admin tables, tiles,
  cards and empty states get rounded, lifted frames, scoped to `.va` so the admin portal is untouched
  (`web/src/styles/va.css`).

## 3. Components

- `web/src/components/portal-ui/WaitTimer.tsx` (new, with `queue.css`): how long something has waited, ticking every
  second, against a target; says the state in words for screen readers. No existing portal-ui file or prop changed.
- `web/src/features/va/QueueHome.tsx`, `FleetDay.tsx`: Next up, the lane board, the replies, figure links, the day
  timeline and the car board.

Motion: Next up rises once on arrival and lanes lift on hover, both only under `prefers-reduced-motion: no-preference`;
timers change their text only.

## Guides

`docs/guides/src/guides/va.py`, `docs/guides/content/va.json` and `docs/guides/src/va.html` changed by hand (export.py
did not run here; the PDF and the screenshots are rebuilt by the guides run after the deploy):

- `va/your-workday`, To do: the steps now describe the header, **Next up**, the lanes and their timers against the
  5-minute target, **Waiting for a reply** and the function panels, **Every open task**, and `/` to search.
- `va/quick-reference`: To do is "Next up, your lanes with their timers, then every open task" (was "Your function's
  tasks, oldest due first").

0158 publishes the two chapters where the live text is still ours and keeps them as suggestions where an Admin edited one.
