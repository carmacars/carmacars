# The AI budget by feature, and the assistant adds rentals and offers (October 24, 2026)

Migration 0133. The owner, October 24, 2026: "How r we running out of workers ai credits every single day like this? I haven't been able to use the staff ai assistant once." and "Can rentals be added in by the ai chatbot?" Then: keep the usage limits as a hard stop, with no paid Workers AI overage. Reserve most of the free daily allowance for the staff assistant, visitor chat next, and the SEO writer only from what is left late in the day or a small fixed share, never eating the staff share. Show staff a clear message when the day's allowance is gone and when it resets.

## Why the allowance ran out every day

The free allowance is 10,000 Workers AI neurons a day. Every feature had its own daily ceiling, but all of them drew on that one pool, first come, first served:

| Feature (purpose in `provider_calls`) | Its own ceiling | When it runs | Cost of one item |
| --- | --- | --- | --- |
| Listing copy of new cars (`draft_copy`) | 9,000 | when a car is added | up to 2 attempts, 1,400 output tokens each (about 300 neurons an attempt) |
| Visitor live chat (`chat`) | 6,000 | visitors | about 100 a reply |
| Search copy: car pages, landing pages, articles (`seo_car`, `seo_page`, `seo_article`) | 4,000 | every 5 minutes, day and night, 2 items a tick | up to 3 attempts of 1,800 to 3,500 output tokens: 300 to 2,400 neurons an item |
| Guide upkeep after every deploy (`guide_rewrite`) | none of its own (the day's total) | after each deploy (`guides.yml`, `auto`) | up to 3 attempts of 4,000 output tokens per changed section: about 600 neurons an attempt |
| Staff assistant (`staff_assistant`) | 3,000 | staff | about 50 to 150 a question |
| Toll reader, plate finder (`toll_read`, `plate_detect`) | 3,000 | staff | about 100 to 300 |
| Phone line (`phone_draft`, `phone_summary`) | 1,500 | texts and calls | about 100 |

The ceilings add up to 26,500 on a pool of 10,000. Each gate also checked only "used so far < ceiling" before a call that can cost hundreds, so a claim made at 3,999 of the search job's 4,000 could spend another 4,800. The background jobs ran first: the search writer from midnight every five minutes, and the guide upkeep after each deploy. The guides run of the release 4 deploy (October 24, 6 am Toronto) rewrote 6 sections and kept 28 for the next run; the runs of October 23 at 11 am and 9 am Toronto found Workers AI already paused ("next run: ... (paused): Workers AI is paused for today"). The assistant could only run while the whole day was under 10,000 (and under its own 3,000), so by the time staff opened it the pool was gone. The guide rewrite also did not record the neurons of attempts made before a pause or of attempts that failed, so part of its use showed only in Cloudflare's count (the ~13,000 against the 10,000), never in the app's own record.

## The fix: one budget for the day, in three tiers

`app.ai_budget()` splits the day's included neurons by the purpose each call is recorded with (`app.ai_tier`):

- **Staff assistant**: 70% of the day is kept for it alone (`ai_assistant_reserve_bps` 7000), and it may use anything the others leave. Its own ceiling (`assistant_daily_neurons`) is now the whole allowance (10,000).
- **Live** (someone is waiting): visitor chat, the phone line, the toll reader, the plate finder, guide suggestions. They share what is not reserved (3,000 by default).
- **Background** (nobody is waiting): search copy, listing copy, guide rewrites, Turo email reading, the colour reader, and any use Cloudflare counts beyond the app's record ("unmetered"). A fixed 10% (`ai_background_bps` 1000, 1,000 neurons), and from 9 pm Toronto (`ai_release_hour` 21) what is left of the day, less 500 always kept for the assistant (`ai_assistant_cushion`).

`app.ai_allow(purpose, estimate)` answers whether a call may run now and the words to show when not. A call is refused when its estimate does not fit its tier's room, so no tier runs past its room by more than one small call. Every gate asks it: the assistant's usage gate (`app.usage_gate`), live chat (`app.chat_budget`), the phone line (`app.phone_ai_budget`), the readers (`app.ai_vision_gate`), the Turo matcher (`app.turo_match_keys`) and the search job (`app.server_seo_claim`, which claims nothing to write while the background share has no room for an item and says why in `ai_wait`; IndexNow goes on). The Worker's adapters check too, before every Workers AI call (`web/src/integrations/ai/guard.ts`: the estimate is the prompt plus half the output a call may write; the budget is read every 20 seconds and kept current by what each call spent), so the guide upkeep and the listing copy stop at their share as well.

**Hard stop**: Workers AI never runs into paid usage. `app.usage_decide` refuses "allow" for Workers AI (with the reason), an allowance in force on the day of the deploy is withdrawn with a note, and To do shows "Stopped for today, never paid" with no Allow button. Images and Claude keep their "Allow paid usage" question.

**Claude**: when Workers AI has no room for the assistant and the Worker has `ANTHROPIC_API_KEY`, the assistant uses Claude only while Claude's own budget in Settings > Usage allows it (US$0 included by default: no new spend unless an Admin allows a budget). Workers AI comes first now (it was Claude first whenever the key was set). `ANTHROPIC_API_KEY` is not set in the Worker today (Settings > Usage shows Claude unused).

**Staff's words** when the day is gone: "Today's free AI allowance is used up (10,412 of 10,000 neurons). The assistant is back at midnight, Toronto time. Everything still works from the screens and pop-ups." The gate also returns `resets_at`.

**Metering**: every Workers AI call was already recorded with its purpose and neurons in `provider_calls` (the chat, the search job, the listing worker, the guides, the phone line, the readers, Turo emails, the assistant). The guide rewrite now records the attempts before a pause and the failed attempts too.

## What Admin sees

- **Settings > Usage > Workers AI by feature** (top of the page): neurons used of the day; each tier's use and what it has left now; Unmetered (Cloudflare's count beyond the app's record, counted as background); a table of each feature with its tier, neurons today, calls today (and failed), the last 7 days and calls over 7 days; the 7 days by tier with Cloudflare's figure; **Change the shares** (the assistant's reserve, the background share, the release hour, the cushion; `admin_do 'ai_shares_save'`, on the Program settings row in force, audited). Workers AI's Paid usage row reads "Never: a hard stop at the free allowance each day".
- **To do**: Workers AI used up reads "Stopped for today, never paid" and what pauses.

## The assistant adds rentals and offers

New and changed tools (`web/src/features/assistant/tools.ts`, `agent.ts`). Every change is a card with the full summary that runs only on Confirm, through the same door function as the screen, as the staff member (their role decides; the database refuses what the screen refuses):

- **create_offer** (Admin, customer service, sales): the car, the dates, the customer (one on file by name, email or phone through the offer screen's customer search, `find_customers`; or a new customer's name, email, mobile and date of birth, asked for when missing; more than one match lists them), an agreed rental price before tax with its reason, the Protection Plan option, how the rental and the deposit are paid, how the offer is sent (email, text, both, not sent), the message, how long it stays open, "I found this client". Before the card it is priced by the offer screen's preview (`offer_preview`, made and rolled back): a refusal (the car not free, a blocked customer, a missing detail) is said and no card is made. The card's details: Offer (customer, on file or new; car; pickup; return; days; client), Price (each line before tax, HST, due at booking, the refundable deposit), Payments (rental, deposit, how it is sent). Confirm runs `ops_do 'offer_create'` (`app.staff_offer_create`, 0129).
- **add_rental** (as before, plus): the customer on file through the same search, the deposit method (card, cash, e-Transfer), the agreement (sent or on paper). The card shows the same price lines (from the preview; field staff, who have no offer screen, see "worked out from the car's rates when it is added") and the payments. Confirm runs `ops_do 'manual_rental_create'` (0129's wrapper).
- **booking_balance** (Admin, customer service, sales, finance): "What does booking R-000123 owe?" or "What does Jane Doe owe?": each open booking's rental, fees and later charges still open and the deposit, from `ops_read 'booking_money'`, with a link to the booking's Money tab.
- **availability**: for Admin and assistants, every bookable car (published or not) with whether it is free and its rates, from the offer screen's list (`offer_form`); field staff keep the public search.
- **record_payment** on a booking is recorded by part (`covers`: rental, deposit, fees, later) through `ops_do 'record_booking_payment'`; on an owner invoice as before.
- **send_payment_link** (as before): sends a booking's offer link again, after Confirm.

`assistant_actions.details` keeps the card's details. A booking the assistant made or paid gets a booking event: "Offer made with the staff assistant by <name>: <summary>" (also "Rental added", "Payment recorded"), with the action's id; the audit log has the action under the staff member's name, "via assistant", as since 0080.

## Search copy: written by a daily Claude batch, not Workers AI

The owner approved: the search text is written by a daily scheduled Claude session. The website's Workers AI writer is off by default (`program_settings.seo_ai_writer_enabled`, labelled in Program settings; turned on again it writes within the background share), so the whole free Workers AI allowance goes to the staff assistant first and live chat next. `app.server_seo_claim` claims nothing to write while it is off (`ai_wait` says why) and goes on sending IndexNow.

- **`.github/workflows/seo-queue.yml`** (daily 09:10 UTC and on demand, input `limit`, default 500): `app.seo_batch_queue(limit)` through `scripts/deploy/sb.sh` (hosted or own server) -> `web/scripts/seo-queue.mjs` -> `seo/queue/latest.json`, force-pushed to the branch `seo-queue` (main untouched). Most valuable first: landing pages (places, then uses), car pages of published cars (asked for first), guides. Each item: kind, id, url, priority, page type, name, the facts the Workers AI prompt is given, locked fields, the current text and its source, what to write, the word target, the introductions to avoid, the Workers AI writer's own system prompt and prompt, the output schema.
- **`.github/workflows/seo-import.yml`** (push to main touching `seo/batches/**.json`, and on demand, input `files`): `app.seo_batch_context` (the live facts) -> `web/scripts/seo-import.mjs check` with `web/src/features/seo/batch.ts` (the website's own checks of `copy.ts`, as the search job applies them, plus no service promises and every page unlike the others and the batch's earlier items) -> `app.seo_batch_publish` (source `claude-batch`; a car through `app.car_copy_apply`, so the database checks it again and the listing follows; locked fields kept; IndexNow queued) -> `/api/jobs/public-rebuild` -> notices: published (count and addresses) and each rejected item with its reasons.
- Precedence: hand-written (`claude-batch`, `ai`, staff) before the writing kit (`kit`, accepted by the source checks) before the template. The queue never offers a page whose `claude-batch` or `ai` text still matches its facts.
- The JSON shapes: `docs/seo-batches.md`. Unit tests: `web/src/features/seo/batch.test.ts`. Suite 85 (section 5) and suites 40 and 52 (they turn the writer on to test it).
- Not in the queue: the place, colour, term, detailing, body shop and vehicle (make, model, trim) pages, which have no written-text store; the writing kit covers them.

## The database

`program_settings`: `ai_assistant_reserve_bps`, `ai_background_bps`, `ai_release_hour`, `ai_assistant_cushion`; `assistant_daily_neurons` raised to 10,000. `assistant_actions.details`. `program_settings.seo_ai_writer_enabled`; `car_copy`, `seo_pages`, `articles` sources `claude-batch` and `kit`; `app.seo_batch_queue`, `app.seo_batch_context`, `app.seo_batch_publish`; `app.ai_tier`, `app.ai_feature_label`, `app.ai_budget`, `app.ai_allow`, `app.ai_usage`, `app.ai_shares_save`, `app.ops133`, `public.server_ai_budget`, `public.server_ai_allow`. Wrapped (`_pre0133`): `usage_gate`, `chat_budget`, `phone_ai_budget`, `ai_vision_gate`, `turo_match_keys`, `server_seo_claim`, `usage_decide`, `usage_apply`, `usage_state`, `usage_page`, `assistant_action_door`, `assistant_propose`, `assistant_confirm`, `door`. `SCHEMA_MARKER` 0133. Suite 85 (`supabase/tests/85_ai_budget_assistant_tools.sql`); suite 60 shows paid usage on images now. End to end: `web/tests/e2e/assistant-offers.spec.ts` (the offer card, Cancel, Confirm, the history, the balance, the used-up words, Settings > Usage by feature, the shares) and `assistant-usage.spec.ts` (Workers AI never paid; images' Allow paid usage).

## Not changed

The long rentals work (branch longrent, migration 0132) is not touched: the assistant calls the offer and rental functions of 0129 through the door and does not change the quick rental form, the offer composer or the pricing code. Cloudflare's free neurons reset at midnight UTC (8 pm Toronto in summer, 7 pm in winter), while the guard counts Toronto days. The guard stops at the included neurons per Toronto day; a Cloudflare day spans the evening of one Toronto day and most of the next, so on a heavy evening Cloudflare may refuse first (its 4006 answer reads as the same used-up message, never an error).

## Guides

- `admin/assistant`: Offers, rentals and what is owed (send an offer, the card, add a rental, free cars, what is owed, payments by part, the booking's history); the 70% reserve and the used-up words.
- `admin/usage-and-paid-usage`: Workers AI never paid; Workers AI by feature, the three shares, Change the shares; Allow paid usage for photos.
- `va/assistant`: Offers, rentals and what is owed for customer service and sales; the 70% reserve and the used-up words.
- `admin/search-car-pages-landing-pages-and-guides`: the text is written by the daily Claude batch; who wrote a car's text.

Published by migration 0133 (generated by `supabase/seed/0133_gen_guides.mjs`).
