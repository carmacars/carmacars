# IndexNow: the changed pages first, on their own back-off (0220)

The owner: Settings > Search showed "133 addresses waiting, 0 sent in 7 days".

**Why.** The changed pages (a car, a landing page, a guide) and the sweep of the vehicle and place pages shared one
back-off. The sweep sent batches of 10,000 machine-made addresses until Bing answered 429 TooManyRequests; with no
Retry-After that held everything until 00:05 the next day, and the first batch of the new day was refused again (live on
October 31: the last 429 at 00:05, the back-off to the next midnight, the sweep at place file 314). The 133 real pages never
had a turn.

- `indexnow_sweep.q_*`: the changed pages' own back-off. A 429 waits its Retry-After, else an hour, doubling to 24 hours;
  403 or 422 until tomorrow; another failure 10 minutes. The sweep's back-off and daily ceiling do not hold them back.
- The sweep waits while changed pages wait (they go first, alone). After a 429 without Retry-After it waits until tomorrow
  and a day more for each 429 in a row (at most a week); it sends the priority list only, inside the crawl scope, then waits
  a week for the next round.
- The five-minute tick runs the search job when the changed pages may go, or the sweep may.
- Settings > Search: "IndexNow: changed pages" and "IndexNow: sweep", each with the last answer, Bing's message and how
  long it waits. Addresses of the queue outside the crawl scope are dropped.
- Tests: `supabase/tests/99_release_23.sql` section 1 (and the earlier suites 40, 72, 81 and 99 safeupdate follow the new rules).

## Guides

- `admin/search-car-pages-landing-pages-and-guides`: IndexNow.
