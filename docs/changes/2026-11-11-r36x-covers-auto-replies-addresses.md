# The listing's first photo, AI auto-replies, the Canadian address database, SOPS secrets, booking motion (Release 36, helper X: 2100, 2110, 2120, 2130)

Branch `r36-x`. Migrations `2100_r36x_listing_covers.sql`, `2110_r36x_auto_replies.sql`, `2120_r36x_ca_addresses.sql`,
`2130_r36x_guides.sql` (SCHEMA_MARKER left to the integrator). Tests: `supabase/tests/99_r36x_listing_covers.sql`,
`99_r36x_auto_replies.sql`, `99_r36x_addresses.sql`; unit tests `web/src/features/listing/flyer.test.ts`, `showroom.test.ts`
(first photo), `web/src/features/auto-reply/faq.test.ts`, `web/src/integrations/meta-messaging.test.ts`,
`web/src/features/addresses/oda.test.ts`, `web/src/integrations/maps/address-book.test.ts`.

## 1. The listing's first photo (2100)

| Item | What changed |
| --- | --- |
| Choice | `vehicle_listings.cover_style`: `plain` (default), `model` or `flyer`, on the listing's **First photo** card (Admin and staff listing page, `features/listing/Cover.tsx`); `ops_do`/`va_do` `listing_cover_set` {vehicle, style, remake} for Admin, Fleet, customer service and Sales (`app.marketing_may`); `ops_read`/`va_read` `listing_cover` |
| With a model | Listing job `cover_model`: the car from its kept cut-out in the showroom, then the image model (Gemini, 0990's gate and daily limit) with Program settings `listing_cover_model_prompt` inside the site's fixed rules (`coverModelPrompt`: one clearly adult model, fully clothed, nothing revealing or explicit, the car unchanged and never covered). An answer that changes the car is refused (0990's same-car check); without the image model the cover says "needs the image model" and the plain cover shows |
| Flyer | Listing job `cover_flyer`: drawn by the site on the cover photo (`features/listing/flyer.ts`, Inter Display ExtraBold outlines `presets/flyer-glyphs.json`, the logo): the band, the headline, the offer, the call to action, a badge, the logo, all from Program settings `listing_cover_flyer` filled by `app.cover_flyer_spec` ({car}, {price}, {weekly}, {monthly} from `app.ad_snapshot`, the live price). A price line with no live price is left out |
| Current only | `listing_covers` keeps each made cover with the cover photo it was drawn on and, for a flyer, the key of its words (`app.cover_flyer_key`). `app.listing_cover_shown` gives the newest current one; a changed price, words or cover photo means the plain cover shows and `app.job_listing_covers` (pg_cron every 10 minutes) makes it again |
| Site and Marketplace | `app.public_listing_photos` and `app.public_listing_row` (wrapped) put the made cover first and keep the plain cover right after it: every car card, the car page, the Marketplace kit and the partner feed |

## 2. AI auto-replies (2110)

| Item | What changed |
| --- | --- |
| Settings | Program settings group **AI auto-replies**: one switch a channel (texts, email, chat, WhatsApp, Messenger, Instagram; on), quiet hours 1 to 5 (texts held until 5 am), 5 answers a sender a day, 70% sure, the Workers AI model (the small Llama 3.1 8B), the email inboxes (`help`), the hand-off text (empty), the Meta verify token, the WhatsApp number id |
| Gate | `public.server_auto_reply_gate`: the channel on, the sender's daily cap, no staff text to them in 2 hours, not opted out, not a staff number, and the free allowance (`app.ai_budget` live room at least 400 neurons). The Worker treats an unreadable gate as "no" (never past the free tier); the usage guard (0080, 0133) also applies, purpose `faq_reply` (a live feature) |
| Answers | `server/auto-reply.ts`: only the 4 FAQ entries closest to the question (the FAQ page and the owners' FAQ, tokens filled) go to the model; it must name the entries it used and be sure; `readAnswer` drops anything else. `public.server_auto_reply_record` logs it in `auto_replies` and `provider_calls`; a sure text goes out through the phone outbox (kind `auto_reply`, opt-outs and the quiet hours applied); an unsure email or Meta message is a To do for customer service (`auto_reply_handoff`, one a sender a day) |
| Texts | The Quo webhook answers Quo first, then (`after()`) the FAQ answer for an incoming text |
| Email | The Worker's email handler sends mail for in.carmacars.ca (not `trips@`) to `/api/inbound/ask` first; an inbox of the settings gets the answer with `message.reply` (In-Reply-To, `Auto-Submitted: auto-replied`); robots, lists, bounces and our own domain never get one; any other address goes to the Turo reader as before |
| Meta | `/api/webhooks/meta`: GET verification with the verify token; POST checked with `META_APP_SECRET` (X-Hub-Signature-256); Messenger and Instagram answered with the Page token of Meta publishing (0167), WhatsApp with `WHATSAPP_TOKEN` and the number id. Both secrets optional (deploy job, or the SOPS file) |
| Chat | The live chat's own assistant (0060, 0370) answers only while `auto_reply_chat` is on as well |
| TikTok | Not possible: TikTok has no inbound message (DM) API for business accounts of this kind; comments and messages stay in the TikTok app |
| Screens | **AI auto-replies: the last answers** on Settings > Program; **Automatic answers** under the staff portal's Renter messages (customer service) |

## 3. The Canadian address database (2120)

| Item | What changed |
| --- | --- |
| Table | `ca_addresses`: number, street, unit, city, province, postal code, the point as two reals; no stored search column: the key (`app.addr_norm`: lower case, accents folded, punctuation out, street types and directions shortened) lives only in its `text_pattern_ops` index |
| Search | `public.server_address_search(q, limit)`: a civic number and the start of the street, one index range read in index order and stopped at the limit; `public.server_address_get('ca-<n>')`: the parts and the point. Service role only |
| Import | `.github/workflows/addresses.yml` (Run workflow; provinces in order, ON by default, or all): Statistics Canada's ODA v1 zips, `web/scripts/addresses/load.mjs` COPYs 50,000 rows a transaction with the import pacing (0106), then deletes the province's older rows in id ranges; the places' size cap (`place_db_cap_mb`) skips a province that would pass it. `address_imports` records each run. The ODA has no file for NL, YT and NU |
| Site | `integrations/maps/address-book.ts` in front of the maps adapter: every address field (`/api/address`) asks the database first; Google (when its key is set, within its daily cap) or the sample landmarks only when it has nothing; a chosen `ca-` address is read from the database, never sent to Place Details |

## 4. SOPS secrets

`.sops.yaml` (age), `secrets/deploy.sops.yaml` (to be made by the owner), `.github/actions/sops-env` (sops 3.9.4 pinned by
checksum; decrypts with `SOPS_AGE_KEY`, masks every value, fills only empty variables through `BASH_ENV`, so the GitHub secrets
keep working until deleted), the deploy job's first step. `scripts/secrets/sops-init.sh` does the setup; `docs/runbooks/sops-secrets.md`.

## 5. Booking and renter portal motion

`features/motion/Progress.tsx`: `ChecklistProgress` (Before pickup on the verify page, Sign and pay on the checkout) and
`ConfirmedOnce` (the confirmed moment once a booking on a device when it was confirmed without the pay page). `styles/motion.css`:
the bar fills, the ticks pop one after the other, the step to do now breathes once, the success panels rise with their rule drawn
across. All under `prefers-reduced-motion: no-preference`, transform and opacity only.

## Guides

- `admin/fleet-and-listings`: the listing's first photo.
- `admin/settings`: the auto-reply and address settings.
- `va/customer-service`: automatic answers.
- `va/fleet`: the listing's first photo.
