# CarmaCars automated emails

Every email the platform sends to renters, owners, investors and staff: 121 in all. Hand-written, table-based, inline-styled HTML that works in Gmail, Apple Mail and Outlook, with a plain-text alternative for each. No packages are installed; the build uses Node 22 built-ins only.

The business rules in the copy come from `docs/source/` (operating procedures and templates T1 to T26, the renter and owner billing specifications, the website terms and policies) and `docs/architecture.md`. Amounts that can differ per booking, vehicle or owner are merge variables, never typed into the copy.

## Build

```bash
node emails/build.mjs                                            # templates, sample renders, catalogue, gallery, the table below
PLAYWRIGHT_BROWSERS_PATH=/opt/pw-browsers node emails/shots.mjs  # screenshots, 640 and 375 wide
node emails/check.mjs                                            # 14 checks; exits 1 on any failure
```

`shots.mjs` takes optional codes to shoot only those emails, and `--dark` to add a dark-mode pair. It uses the globally installed Playwright.

| Path | What | Edit by hand |
| --- | --- | --- |
| `src/emails/<code>.mjs` | One file per email: trigger, subject, preheader, copy and structure | Yes |
| `src/emails/_digest.mjs` | Shared builder for the per-role digests (each role still has its own file) | Yes |
| `src/components.mjs` | The component set: hero, vehicle photo slot, key facts, figure, detail table, price table, before and after table, generic table, linked rows, button, link, notice, list, steps, optional section, loop | Yes |
| `src/layout.mjs` | Shared layout: header with the wordmark, hero band, body, help line, footer. Renders each component to HTML and to plain text | Yes |
| `src/snippets.mjs` | Blocks several emails share (pickup and return facts, places, booking price) | Yes |
| `src/brand.mjs` | Colours, font stack, sender addresses, values every email receives | Yes |
| `src/links.mjs` | Every path on carmacars.ca an email may link to | Yes |
| `src/variables.mjs` | Shared merge variables with a sample value each | Yes |
| `src/engine.mjs` | The template engine. The application imports this file to fill a template | Yes |
| `templates/<code>.html`, `.txt` | Templates with `{{variable}}` tags left in, for the application | No, generated |
| `dist/<code>.html`, `.txt` | The same, filled with sample values, for review | No, generated |
| `catalogue.json` | The catalogue, generated from the email files so it cannot drift | No, generated |
| `preview/index.html` | Gallery of every rendered email, grouped by audience | No, generated |
| `shots/<code>.desktop.png`, `.phone.png` | Screenshots | No, generated |

To add an email: copy a file in `src/emails/`, give it a new `code` that matches the file name, write the copy, and build. The build fails with a clear message if a variable has no sample value, if a sample is unused, if a link is not in `src/links.mjs`, or if there is more than one primary button.

## Sending an email from the application

```js
import { render, renderText } from './emails/src/engine.mjs';

const entry = catalogue.emails.find((e) => e.code === 'renter_offer_ready');
const values = { ...globals, first_name: 'Maya', booking_number: 'CC-10482', /* every name in entry.variables */ };

send({
  from: entry.from,
  reply_to: entry.reply_to,                      // the desk's alias, see reply_to_rule
  subject: renderText(entry.subject, values),
  html: render(readFile(entry.template_html), values),
  text: renderText(readFile(entry.template_text), values),
});
```

- `render` escapes every value for HTML. `renderText` does not escape and tidies blank lines.
- Both throw on a missing value, so a half-filled email is never sent. Pass an empty string for an optional value.
- The preheader is already inside the HTML template. It is in the catalogue for inbox previews in the admin portal.
- For a `marketing` email also set the `List-Unsubscribe` and `List-Unsubscribe-Post` headers to the same `unsubscribe_url`.
- Where the copy says a record or document is linked, the link is a merge variable holding a signed file link. Keep those links valid for at least 7 days; the copy says so.

## Template syntax

Three tags, and nothing else.

| Tag | Meaning |
| --- | --- |
| `{{name}}` | A value. HTML-escaped in the HTML template, raw in the text template |
| `{{#if name}} A {{else}} B {{/if}}` | Optional section. `{{else}}` is optional. False when the value is missing, an empty string, `false`, `0` or an empty list |
| `{{#each name}} ... {{/each}}` | Repeat for each object in a list. Inside, `{{field}}` reads the item first, then the values outside the loop |

Names use lower-case letters, digits and underscores. Sections nest. A section tag alone on its line leaves no blank line. There are no expressions, comparisons, filters or partials: the application works out a flag or a formatted string and passes it in.

Value conventions (also at the top of `src/variables.mjs`):

| Kind | Format |
| --- | --- |
| Money | Formatted with the dollar sign, Canadian dollars: `$468.95` |
| Dates and times | `Fri, Oct 23, 2026` and `10:00 am`, Toronto time. No periods in am and pm, so a time can end a sentence |
| Lists | Arrays of objects. The field names are in `catalogue.json` under `fields` |
| Flags | `true` or `false` |
| Links | Full https URLs |

In the copy inside `src/emails/`, three shorthands are turned into HTML and text by the layout: `**bold**`, `[label](@link_name)` for a path in `src/links.mjs`, and `[label]({{url_variable}})` for a signed or tokenised link.

## Catalogue format

`catalogue.json` holds `reply_to_aliases` (the six receiving aliases), `reply_to_rule`, `global_variables` (values every email receives: `support_phone`, `contact_email`, `opening_hours`, `reply_time`, `instagram_url`, `tiktok_url`, `company_address`), `count`, and `emails`. Each entry:

| Field | Meaning |
| --- | --- |
| `code` | Stable snake_case id. Also the event key, and the file name of the source, the templates and the outputs |
| `audience` | `renter`, `owner`, `investor`, `staff_admin`, `staff_va_finance`, `staff_va_fleet`, `staff_va_cs`, `staff_va_sales` or `staff_field` |
| `also_sent_to` | Other audiences that receive the same email, where there are any |
| `category` | `transactional` or `marketing`. Marketing emails carry the unsubscribe link, the sender name (CarmaCars) and the mailing address, and are sent only where the trigger's consent condition holds |
| `trigger` | The exact event or schedule, with its conditions |
| `timing` | The short form of when it goes out |
| `digest` | `true` when the notice is queued for the role's next digest in place of being sent by itself |
| `digest_slot` | `next` (whichever digest comes first) or `morning` |
| `source` | The message template (T1 to T26) the email replaces, where there is one |
| `from` | `bookings@`, `owners@`, `billing@` or `hello@` at `carmacars.ca`, display name CarmaCars; the insurance emails (`insurer_invoice`, `insurance_staff_message`) from `blindspotcarrental@carmacars.ca`, display name Blind Spot Car Rental (migration 0187) |
| `reply_to` | The alias of the desk that handles it: `blindspotcarrental@` for the emails sent as Blind Spot Car Rental, `investors@` for investors, `contact@` for staff notices, `billing@` for emails sent from billing, `owners@` for owners, `bookings@` for renter booking emails, `contact@` for other renter emails (`privacy@` for the account security notice). All at carmacars.ca; the list and what each alias is for are in `docs/email-aliases.md`. `emails/check.mjs` enforces the rule. |
| `subject`, `preheader` | With merge tags |
| `sample_subject` | The subject filled with sample values |
| `variables` | Every merge variable the email reads: `name`, `type` (`string`, `url`, `boolean`, `list`), `sample`, `fields` for a list, and a `note` where the name is not obvious |
| `template_html`, `template_text` | Paths of the two templates |

## Digests and the sending limit

The free sending plan allows 100 emails a day. Staff notices are the easiest volume to save, so:

- A staff notice with `digest: true` is not sent when its event happens. The application writes a row to a digest queue (role, code, one line, a link, the time) and the role's next digest lists it. The trigger text of each one names the exception that makes it immediate, for example a pickup within 24 hours.
- Each role has a morning digest at 07:30 and an end-of-day digest at 18:15, Toronto time. Field staff get their job list at 07:00 for today and at 18:00 for tomorrow. A digest also carries standing lists worked out at send time (deposits near their limit, offers expiring, opening and closing checks). The trigger of each digest names its lists.
- The standalone template of a digested notice still exists. It is used for the immediate exception, and can be sent directly if the plan is upgraded.
- These stay immediate, always: new booking request, request waiting over 2 hours, extension request, late return, disable approval, incident, breakdown, dispute, job assigned or changed, owner application, failed scheduled job.

Rough daily volume at the planning figure of 50 bookings a month: about 25 renter emails, 5 owner emails, 16 staff digests (8 people, twice a day) and 10 immediate staff notices. That is near 55 a day, with the 15th (owner invoices) and the 10th (statements and payouts) as the busy days. If the cap is close, send in this order and hold the rest for the next day: safety and late-return emails, offers and confirmations, money, staff immediate, digests, marketing.

Two pairs of renter emails are deliberately not doubled up: `renter_booking_confirmed` carries the receipt for the booking payment, so `renter_payment_receipt` is not sent for it; and `renter_return_reminder` carries the return details, so `renter_return_details` is sent only if they change afterwards.

## Booking statuses and events the triggers use

As built in `supabase/migrations/0016_request_to_book.sql` and `docs/changes/0016_request_to_book.md`:

| Status | Meaning |
| --- | --- |
| `requested` | The renter asked. No card is taken. Staff review and may adjust |
| `offered` | An offer is with the renter (`booking_offers.status = 'sent'`, with `offer_expires_at`) |
| `pending_payment` | The offer is approved; signing and payment are in progress. It does not expire and does not block the car |
| `confirmed` | Signed and paid. Only now is the car booked |
| `on_rent`, `returned`, `closed` | The rental itself |
| `cancelled`, `no_show`, `declined`, `expired` | Ends |

- **An offer does not hold the car.** It stays open until its expiry. If another renter pays for the same car and dates first, the offer is withdrawn and the booking goes back to `requested` (`renter_offer_withdrawn`). The offer, reminder, expiry and payment-failed emails all say this plainly.
- **An expired offer returns the booking to `requested`**, not to `expired`. `renter_offer_expired` fires when the offer row is marked expired and tells the renter the request is still on file.
- **There is no `needs_info` status.** `renter_request_needs_info` fires when staff send a "more information needed" message on a `requested` booking. It is an event; the status does not change.
- **A revised offer** is a new offer version. `renter_offer_ready` covers it with `is_revised` true; there is no separate `renter_offer_revised`.
- **Event key.** The event key of every email is its catalogue `code`, emitted with `app.emit_event(code, entity, entity_id, payload, dedupe_key)`. The payload carries the values in the entry's `variables`. Use the dedupe key for the "sent once" conditions in the trigger text (for example one reminder per offer version).

## Design

Values follow the site prototype (`prototype/DESIGN.md`, `prototype/assets/css/tokens.css`). All of them are in `src/brand.mjs`.

- Red `#D0111B` for the top rule, buttons, key figures and "Cars" in the wordmark; `#A30C14` (the hover red) as the button border; `#FF4D52` is defined for small red text on black. Black `#000000` header and hero band, white body, the site's neutral greys for secondary text, rules and quiet surfaces. No other hue.
- The wordmark is the exact text CarmaCars, as on the site: "Carma" in the surface's text colour and "Cars" in red, bold italic, condensed. No web font is loaded. The stack is Heros Condensed, Helvetica Neue Condensed Bold, Arial Narrow, Roboto Condensed, Liberation Sans Narrow, then Arial, so a client with no condensed face shows Arial bold italic in the same two colours. It is never placed inside an upper-case label, and it reads as one word when tags are stripped.
- Text is the site's text stack: Inter, Helvetica Neue, Helvetica, Segoe UI, Roboto, Arial. Outlook is pinned to Arial. The site's condensed capitals are not used for email headings, because most mail clients would fall back to a wide face and reflow them.
- Single column, 600px at most, 36px gutters that drop to 22px on a phone. Buttons have the site's 6px radius, are full width on a phone and about 56px tall.
- Dark mode: the head declares both colour schemes and a `prefers-color-scheme` block restyles the body, rules and notices with the site's dark greys. The black bands and the red stay as they are.
- Vehicle photo: `vehicle_image_url`. When it is empty the slot shows a dark block with the vehicle name, which is what the sample renders show.

## Copy rules the checker enforces

No em dash or en dash; no spaced hyphen standing in for one; no exclamation marks; no emoji; the brand name spelled exactly CarmaCars; a list of banned words; plain ASCII punctuation; one primary button per email; the coverage provider is never named (there is no name anywhere in this folder). Investor emails are checked for promotional wording and must carry the line that they are not an offer or a solicitation.

## Links for the web team

Every `href` is either a path below or a pure merge variable. `check.mjs` fails on anything else. Paths that need sign-in should send the person to sign-in and back to the same path.

**Public site**

| Path | Key in links.mjs |
| --- | --- |
| `/` | `home` |
| `/cars` | `cars` |
| `/terms` | `terms` |
| `/privacy` | `privacy` |
| `/terms#cancellation` | `cancellation_policy` |

**Renter portal**

| Path | Key in links.mjs |
| --- | --- |
| `/account/bookings/{{booking_number}}` | `booking` |
| `/account/bookings/{{booking_number}}/offer` | `booking_offer` |
| `/account/bookings/{{booking_number}}/request` | `booking_request` |
| `/account/bookings/{{booking_number}}/agreement` | `booking_agreement` |
| `/account/bookings/{{booking_number}}/verify` | `booking_verify` |
| `/account/bookings/{{booking_number}}/pickup` | `booking_pickup` |
| `/account/bookings/{{booking_number}}/condition-report` | `booking_condition_report` |
| `/account/bookings/{{booking_number}}/return` | `booking_return` |
| `/account/bookings/{{booking_number}}/extend` | `booking_extend` |
| `/account/bookings/{{booking_number}}/change` | `booking_change` |
| `/account/bookings/{{booking_number}}/statement` | `booking_statement` |
| `/account/bookings/{{booking_number}}/pay` | `booking_pay` |
| `/account/bookings/{{booking_number}}/incident` | `booking_incident` |
| `/account/bookings/{{booking_number}}/review` | `booking_review` |

**Owner portal**

| Path | Key in links.mjs |
| --- | --- |
| `/owner` | `owner` |
| `/owner/application` | `owner_application` |
| `/owner/agreements` | `owner_agreements` |
| `/owner/billing` | `owner_billing` |
| `/owner/documents` | `owner_documents` |
| `/owner/vehicles/{{vehicle_id}}` | `owner_vehicle` |
| `/owner/vehicles/{{vehicle_id}}/onboarding` | `owner_vehicle_onboarding` |
| `/owner/vehicles/{{vehicle_id}}/calendar` | `owner_vehicle_calendar` |
| `/owner/vehicles/{{vehicle_id}}/exit` | `owner_vehicle_exit` |
| `/owner/bookings/{{booking_number}}` | `owner_booking` |
| `/owner/invoices/{{invoice_number}}` | `owner_invoice` |
| `/owner/statements/{{statement_number}}` | `owner_statement` |
| `/owner/claims/{{incident_number}}` | `owner_claim` |

**Admin portal**

| Path | Key in links.mjs |
| --- | --- |
| `/admin` | `admin` |
| `/admin/approvals` | `admin_approvals` |
| `/admin/statements` | `admin_statements` |
| `/admin/payouts` | `admin_payouts` |
| `/admin/disputes/{{dispute_id}}` | `admin_dispute` |
| `/admin/incidents/{{incident_number}}` | `admin_incident` |
| `/admin/fleet` | `admin_fleet` |
| `/admin/jobs` | `admin_jobs` |
| `/admin/reports/weekly` | `admin_weekly` |

**VA portal**

| Path | Key in links.mjs |
| --- | --- |
| `/va/cs` | `va_cs` |
| `/va/cs/bookings/{{booking_number}}` | `va_cs_booking` |
| `/va/cs/bookings/{{booking_number}}/identity` | `va_cs_identity` |
| `/va/cs/reviews` | `va_cs_reviews` |
| `/va/finance` | `va_finance` |
| `/va/finance/bookings/{{booking_number}}` | `va_finance_booking` |
| `/va/finance/tolls-tickets/{{toll_ticket_id}}` | `va_finance_toll` |
| `/va/finance/owner-invoices/{{invoice_number}}` | `va_finance_invoice` |
| `/va/fleet` | `va_fleet` |
| `/va/fleet/bookings/{{booking_number}}` | `va_fleet_booking` |
| `/va/fleet/listings/{{vehicle_id}}` | `va_fleet_listing` |
| `/va/fleet/expiries` | `va_fleet_expiries` |
| `/va/fleet/vehicles/{{vehicle_id}}` | `va_fleet_vehicle` |
| `/va/sales` | `va_sales` |
| `/va/sales/applications/{{application_id}}` | `va_sales_application` |

**Field portal**

| Path | Key in links.mjs |
| --- | --- |
| `/field` | `field` |
| `/field/jobs/{{job_id}}` | `field_job` |

Signed or tokenised links, passed as merge variables: `verify_url`, `reset_url`, `sign_in_url` (from the sign-in service), `unsubscribe_url` (one-click, per recipient), `signed_agreement_url`, `receipt_url`, `supporting_document_url`, `statement_url` (signed file links), and `vehicle_image_url` (public listing photo). In the digests and the weekly summary each line carries its own `url`, which the application builds from the same paths.

## Every email

Generated by the build from the email files. Do not edit between the markers.

<!-- EMAIL TABLE START -->
### Renter (77)

| Code | Trigger | Timing | Digest | Category |
| --- | --- | --- | --- | --- |
| `account_password_reset` | A password reset is requested for any account (the sign-in service recovery event). One template for every account type. | Immediate | No | transactional |
| `account_security_notice` | A security event on any account: a sign-in from a device or browser not seen before on that account, a password change, or a change of the account email address. One template for every account type. For an email change it is sent to both the old and the new address. Never batched. | Immediate | No | transactional |
| `account_sign_in_link` | A one-time sign-in link is requested for any account (the sign-in service magic link event). Also used as the invitation when an admin creates an owner, investor or staff account. | Immediate | No | transactional |
| `insurance_staff_message` | A staff member writes from a booking billed to an insurer and sends it as Blind Spot Car Rental (insurance): Email the adjuster (to the adjuster's email on the booking), or Email the renter with Blind Spot Car Rental chosen as the sender (migration 0187). The subject is the one they typed. The message is kept on the booking with who sent it. One email per message. | Immediate | No | transactional |
| `renter_accident_instructions` | An incident of type accident, theft or vandalism is opened on an on_rent booking (Fleet logs the renter's call). (Message template T16.) | Immediate | No | transactional |
| `renter_account_created` | The person confirms their email address for the first time (the confirmation link from the sign-in service, or a password link for an address already on file from a booking request) and has the renter role only. Sent once per account. Accounts already confirmed before October 16, 2026 do not get it. | Immediate | No | transactional |
| `renter_agreement_ready` | A signature request is opened for a signer who is not in the middle of checkout: each additional driver on the booking, or the renter when the agreement is reissued (accepted change, extension or renewal) or left unsigned for 1 hour while the booking is pending_payment (offer approved, signing and payment in progress). | Immediate | No | transactional |
| `renter_agreement_signed` | A rental agreement signature request is completed (every signer has signed and CarmaCars has countersigned). Sent to the renter and to each additional driver who signed. | Immediate | No | transactional |
| `renter_agreement_version` | A new version of the booking's two rental agreements (CarmaCars' and Blind Spot's) is made after the agreement was signed (migration 0154): the car checked out (the "as picked up" copy), checked in (the closing copy), a correction, or a material change (dates, price, car, drivers, coverage option) that the renter and the affected drivers sign again with their own link. Also sent with the signed copies once every signature of a changed version is in. Both PDFs are attached. | Immediate | No | transactional |
| `renter_balance_overdue` | Daily check: a renter statement was sent 7 days ago and a balance on it is still unpaid (all card retries failed or are pending). Sent once at 7 days, then with each monthly interest posting on the 1st while a balance remains. | 7 days after the statement, then monthly on the 1st | No | transactional |
| `renter_booking_cancelled` | Booking status changes from confirmed to cancelled or no_show with a booking cancellation row where cancelled_by is renter (the database computes the tier, percent and refund). (Message template T12.) | Immediate | No | transactional |
| `renter_booking_cancelled_by_us` | Booking status changes from confirmed to cancelled with a booking cancellation row where the cancelling party is CarmaCars (no car or accepted substitute), or where the reason is that a driver could not be verified. The refund is 100%, including non-refundable bookings. | Immediate | No | transactional |
| `renter_booking_confirmed` | Booking status changes from pending_payment to confirmed (the offer was approved, the agreement signed, the booking total paid and the car still free for the dates). | Immediate | No | transactional |
| `renter_booking_reminder` | Hourly reminders job: booking status is confirmed and the pickup time is 24 hours away. Sent once. (Message template T5.) | 24 hours before pickup | No | transactional |
| `renter_breakdown_help` | An incident of type breakdown on an on_rent booking has roadside dispatched (dispatched_at is set by Fleet). (Message template T18.) | Immediate | No | transactional |
| `renter_change_applied` | A change to a confirmed booking is applied: the renter accepted online (signed the amendment and any difference was charged), or an Admin recorded the renter's agreement by phone. Carries what changed, the money, and the signed amendment when there is one. | Immediate | No | transactional |
| `renter_change_proposal_expired` | Booking change job: a change waiting for the renter passed its deadline without being accepted. The change is closed as expired; the booking keeps its dates, car and price. Customer service is told at the same time. | At the deadline | No | transactional |
| `renter_change_proposal_reminder` | Booking change job (every 15 minutes): a change staff proposed (or a change the renter asked for and staff approved) has not been accepted, and its deadline is within booking_change_reminder_hours (Program settings, 12 by default). Sent once per change, and not when the change was made inside that window. | Once, the reminder hours before the deadline | No | transactional |
| `renter_change_proposed` | Staff (customer service, Fleet or an Admin) propose a change to a confirmed booking: new pickup or return times, another car, or a new rental charge. Sent once the proposal is saved, unless the change was agreed by phone and applied at once. The booking stays as it is until the renter accepts by the deadline (Program settings: booking_change_accept_hours, never later than the pickup less booking_change_lead_hours). | Immediate | No | transactional |
| `renter_change_request_approved` | Staff approve a change request on a confirmed booking. Sent when the change request status becomes approved. (A change to a booking that is still offered is sent as a revised offer with renter_offer_ready instead.) | Immediate | No | transactional |
| `renter_change_request_declined` | Staff decline a change request. Sent when the change request status becomes declined; staff enter the reason. | Immediate | No | transactional |
| `renter_change_request_received` | The renter asks for a change: on an open offer the current booking_offers row becomes change_requested (booking status offered); on a booking with status confirmed a change request is logged. | Immediate | No | transactional |
| `renter_chat_transcript` | A live chat on the site closes (the visitor ends it, a staff member closes it, or the visitor left contact details after hours and asked for a copy) and the visitor gave an email address in it. One email to that address with the conversation. Transactional: it is the copy the visitor asked for. | Immediate | No | transactional |
| `renter_comeback_1m` | 30 days after booking status becomes closed, only if the renter's marketing consent is true, they have not unsubscribed, no booking or request was created since that booking closed, the renter is not blocked and has no unpaid balance. A new single-use discount code is generated at send time. This is the last automated offer for that booking. | 30 days after the booking closes | No | marketing |
| `renter_comeback_1w` | 7 days after booking status becomes closed, only if the renter's marketing consent is true, they have not unsubscribed, no future booking or open request exists, the renter is not blocked and has no unpaid balance. A single-use discount code is generated for the renter at send time. | 7 days after the booking closes | No | marketing |
| `renter_continue_request` | Contact capture (migration 0090): someone typed their email into a booking request, a contact form, the owner application, the discount game or the live chat. One email per account, ever. A new account opened for that address: sent by the capture job (every 15 minutes) capture_continue_minutes (30) after they stopped typing without sending the form, only within the hours set for booking recovery emails. An address that already has an account: sent at once, as the sign-in link the site says it sent. The button opens /continue, which signs the person in and confirms the email in one step and lands on their draft or request. Transactional: it is about the account opened in their name; never with offers. | Some minutes after a form was left unfinished (new account), or at once (an existing account) | No | transactional |
| `renter_coverage_needed` | A confirmed booking whose Coverage Option is 1 (OPCF 27 on the renter's own policy) or 2 (credit card rental coverage) has no proof waiting for review and none confirmed: sent 48 hours before pickup and again 24 hours before pickup (app.job_coverage_reminders, every 15 minutes). Not sent while a proof is in review, nor for the Protection Plan. The 48-hour one is skipped while a driver's licence is also missing (renter_identity_needed then lists the proof too). | 48 hours and 24 hours before pickup, while the proof is missing or was declined | No | transactional |
| `renter_damage_found` | An incident of type damage is recorded on a returned booking from the photo review after hand-back (damage not noted on the signed return report). Must be sent within 48 hours of check-in. (Message template T8.) | Immediate, within 48 hours of return | No | transactional |
| `renter_deposit_declined` | The security deposit attempt at pickup fails: a payment of kind hold (rental of 7 days or less) or charge (longer rental) for the booking deposit is declined while the booking is confirmed and the pickup job is in progress. Sent on each failed attempt. The car is not released. | Immediate | No | transactional |
| `renter_deposit_released` | A deposit amount that was held back after the final statement is released or applied (deposit released_at is set, or the hold-back is applied to a charge). Happens within 30 days of check-in. | Immediate | No | transactional |
| `renter_driver_link` | The signing link of an additional driver is sent: when the renter's agreement is opened, or when the renter or customer service sends a new link from the booking. Sent to the additional driver's own email address. The link is valid for booking_driver_link_hours (Program settings, 72 by default); a newer link replaces it. | Immediate | No | transactional |
| `renter_extension_approved` | Booking extension status changes from requested to approved (staff checked the calendar, unpaid charges and coverage to the new return date). Payment is still outstanding. | Immediate | No | transactional |
| `renter_extension_confirmed` | Booking extension status changes to confirmed (the extension payment succeeded before the return time and the booking return time was moved). This is the written confirmation. (Message template T11.) | Immediate | No | transactional |
| `renter_extension_declined` | Booking extension status changes from requested to declined. Staff choose the reason. | Immediate | No | transactional |
| `renter_extension_requested` | A booking extension row is created with status requested by the renter on an on_rent or confirmed booking. | Immediate | No | transactional |
| `renter_extra_charge` | A charge is billed to a renter after the final statement: a toll or ticket matched to the booking and charged, or a damage, fuel, cleaning, mileage, lost key or other line added by Finance with its supporting record. One email per charge event. The supporting document is required; the charge cannot be sent without it. (Message template T19 for tolls and tickets.) | Immediate, when the charge is taken | No | transactional |
| `renter_final_statement` | A renter statement for a returned booking is issued (statement sent_at is set by Finance), which captures charges from the deposit and releases the balance. Due within 7 business days of check-in. (Message template T9.) | When the statement is issued, within 7 business days of check-in | No | transactional |
| `renter_game_code` | A visitor plays a discount game on the site (spin the wheel, scratch to reveal, quick blackjack, cup shuffle or Plinko) and claims the prize with their first name and email. One email to that address with the single-use code. Transactional: it is the code they asked for, sent with or without marketing consent. | Immediate | No | transactional |
| `renter_game_code_reminder` | A code won in a discount game on the site has not been used and its last day is tomorrow (promo_reminder_1d_on; since migration 0161 the game reminder is one of the promo code expiry reminders, with the same day rule). Sent once per code, to the address that claimed it. Transactional: a reminder of the code they asked for. Not sent once the code is on a booking request. | The day before the last day of the code | No | transactional |
| `renter_game_code_reminder_3d` | Promo code expiry (migration 0161): a code won in a discount game on the site has not been used and its last day is promo_reminder_3d_days days away (3 by default). Sent once per code, to the address that claimed it. Transactional: a reminder of the code they asked for, like the day-before reminder (renter_game_code_reminder). Not sent once the code is on a booking request. | promo_reminder_3d_days (3) days before the last day of the code | No | transactional |
| `renter_google_review_request` | Program settings google_review_delay_days (3 by default) after booking status becomes closed, only when the Google place id is set in Site settings (app.notify_google_reviews, migration 0061). The same rules as renter_review_request: not unsubscribed, nothing unpaid or open on the renter, and a booking that had a problem (an incident, a dispute, an unpaid balance or a damage charge) is sent only after a staff member answers yes to the review request decision. Never depends on the rating the renter gave, and offers nothing for a review. One per booking. Relies on the existing business relationship for consent, so it carries the unsubscribe link and mailing address. | google_review_delay_days after the booking closes | No | marketing |
| `renter_identity_approved` | Every driver on a confirmed booking has identity_status verified and the booking coverage proof is marked confirmed (whichever happens last). | Immediate | No | transactional |
| `renter_identity_needed` | Booking status becomes confirmed while any driver has identity_status other than verified or the booking has no confirmed coverage option (skipped when renter_booking_confirmed already carried the notice in the same minute). Sent again 48 hours before pickup if anything is still missing. | On confirmation, then 48 hours before pickup if still missing | No | transactional |
| `renter_identity_rejected` | Staff reject an identity document, selfie or coverage proof on a confirmed booking (identity verification or coverage proof status becomes rejected). Staff choose the reason; it fills reject_reason. | Immediate | No | transactional |
| `renter_late_return_final` | Late-returns job: the booking is 2 hours past its return time, still on_rent, with no paid extension. The deadline shown is 1 hour after this email is sent. (Message template T14.) | 2 hours after the return time | No | transactional |
| `renter_late_return_first` | Late-returns job (every 5 minutes): the return time has passed, booking status is still on_rent and no paid extension covers the time. Sent once, at 0 minutes late. (Message template T13.) | At the return time | No | transactional |
| `renter_named_to_authority` | An admin names the renter to the issuing authority for a ticket or offence notice matched to the renter's booking (toll ticket status becomes named_to_authority). The authority will send its notice to the renter directly; CarmaCars does not pay it and adds no charge for it. | Immediate, when the admin names the renter | No | transactional |
| `renter_offer_expired` | The offers-expire job (every 5 minutes, app.expire_offers) marks the current booking_offers row expired because offer_expires_at passed without approval. The booking becomes expired (the request is closed), and customer service gets an offer_expired task to reopen it with a new offer or leave it closed. Sent once per offer version. | Immediate | No | transactional |
| `renter_offer_ready` | A booking_offers row is created with status sent by app.send_offer(), which moves the booking from requested to offered. Fires for every offer version: is_revised is true when the version is greater than 1 or an earlier offer was superseded, so this email also serves as the revised offer (there is no separate renter_offer_revised). has_adjustments is true when the offer differs from what the renter asked for; adjustments lists each difference. | Immediate | No | transactional |
| `renter_offer_reminder` | Scheduled check: booking status is offered, its current booking_offers row is still sent, and offer_expires_at is 6 hours away (for an offer window shorter than 12 hours, at the halfway point). Sent once per offer. | 6 hours before the offer expires | No | transactional |
| `renter_offer_withdrawn` | A booking_offers row becomes withdrawn: staff take the offer back (booking event offer_withdrawn), or the system pushes the booking back from offered or pending_payment to requested because another booking was confirmed for the same car on overlapping dates (booking event pushed_back). Not sent when staff replace the offer with a revised one in the same action; renter_offer_ready covers that. | Immediate | No | transactional |
| `renter_payment_failed` | A renter payment attempt fails. Two cases, set by is_booking_payment: (true) the checkout payment for an approved offer fails, no fee, the booking stays pending_payment and does not block the car; (false) a charge to the Card on File is declined, the declined payment fee is added once per charge and retries are scheduled after 1, 3 and 7 days. Sent on the first decline and again after each failed retry. (Message template T10.) | Immediate | No | transactional |
| `renter_payment_receipt` | A renter payment of kind charge or capture succeeds, except the payment that confirms a booking (renter_booking_confirmed carries that receipt). Covers extensions, accepted changes, extra charges paid by link and retried payments. | Immediate | No | transactional |
| `renter_pickup_details` | The pickup field job for a confirmed booking has an assigned staff member and the pickup is 3 hours away. Sent earlier, at once, if the job is assigned inside that window, and sent again if the place, time or staff member changes after sending. | 3 hours before pickup | No | transactional |
| `renter_promo_expiry_1d` | Promo code expiry (migration 0161): a discount code issued to a person (a come-back offer, a Live visitors code, a code made for one renter) has not been used and its last day is tomorrow (promo_reminder_1d_on). Sent once per code, to the renter it was issued to, only while they have agreed to get offers and have not unsubscribed, never once the code is on a booking request, and only inside the sending hours. Discount game codes have their own transactional reminder (renter_game_code_reminder). | The day before the last day of the code | No | marketing |
| `renter_promo_expiry_3d` | Promo code expiry (migration 0161): a discount code issued to a person (a come-back offer, a Live visitors code, a code made for one renter) has not been used and its last day is promo_reminder_3d_days days away (3 by default). Sent once per code, to the renter it was issued to, only while they have agreed to get offers and have not unsubscribed, never once the code is on a booking request, and only inside the sending hours. Discount game codes have their own transactional reminder (renter_game_code_reminder_3d). | promo_reminder_3d_days (3) days before the last day of the code | No | marketing |
| `renter_recovery_change` | Booking recovery job (every 15 minutes): the renter opened a change staff proposed to their booking and has not answered it after recovery_change_hours (Program settings, 4 by default). At most recovery_max_emails (2), the second after recovery_second_hours (24). Not sent when the deadline is within the change reminder hours (that reminder covers it), outside the hours set for these emails, to a renter who unsubscribed or turned these reminders off, or while a staff member is already handling the renter. Stops once the change is accepted, declined or expires. | Some hours after the proposal was opened | No | transactional |
| `renter_recovery_offer` | Booking recovery job (every 15 minutes): the renter opened their offer (page or email link) and has not answered it after recovery_offer_hours (Program settings, 4 by default). At most recovery_max_emails (2) per offer, the second after recovery_second_hours (24). Not sent when the offer expires within 7 hours (the expiry reminder covers it) or an expiry reminder went in the last 12 hours, outside the hours set for these emails, to a renter who unsubscribed or turned these reminders off, or while a staff member is already handling the renter (an assigned task, a chat with a person, a message from staff). Stops once the offer is answered, expires or is withdrawn. | Some hours after the offer was opened | No | transactional |
| `renter_recovery_pay` | Booking recovery job (every 15 minutes): the renter left the pay page of their approved booking (pending_payment) without paying, recovery_pay_minutes ago (Program settings, 60 by default). At most recovery_max_emails (2), the second after recovery_second_hours (24). Not sent outside the hours set for these emails, to a renter who unsubscribed or turned these reminders off, or while a staff member is already handling the renter. Stops once they pay or the booking leaves pending_payment. | An hour after the pay page was left | No | transactional |
| `renter_recovery_request` | Booking recovery job (every 15 minutes): a signed-in or known renter started a booking request on the site and stopped without sending it, recovery_request_hours ago (Program settings, 2 by default), and has sent no request since. Marketing: only with the renter's express marketing consent and never after they unsubscribed. At most recovery_max_emails (2), the second after recovery_second_hours (24), and one such reminder series per renter in 7 days. Not sent outside the hours set for these emails or while a staff member is already handling the renter. Stops once they send a request. | Some hours after a request was started | No | marketing |
| `renter_refund_issued` | A refund row reaches status succeeded at the processor, for any refund except one already reported by a cancellation email sent in the same hour. Covers refunds for unused time after a breakdown, corrections and a charged deposit returned. | Immediate | No | transactional |
| `renter_rental_added` | CarmaCars staff add a rental by hand (Admin > Bookings > Add a rental, or the VA equivalent) and it is confirmed at once: paid another way, to be charged to the saved card when the renter signs, or to be invoiced later. Not sent when staff tick "Do not email the renter", for a past rental, or for a payment link (the offer email carries the link). | Immediate | No | transactional |
| `renter_rental_started` | Booking status changes to on_rent (deposit taken, pickup condition report signed, keys handed over). | Immediate | No | transactional |
| `renter_request_declined` | Booking status changes from requested to declined. Staff choose a reason; it fills decline_reason. | Immediate | No | transactional |
| `renter_request_needs_info` | Staff send a "more information needed" message on a booking with status requested. This is an event, not a status: the booking stays requested. Staff must enter the question (info_request) and a reply-by time (reply_by). | Immediate | No | transactional |
| `renter_request_received` | A booking row is created with status requested (booking event requested; the renter submitted the request form). | Immediate | No | transactional |
| `renter_return_complete` | Booking status changes to returned (keys taken, return condition report signed). | Immediate | No | transactional |
| `renter_return_details` | The return field job of an on_rent booking has its place, time or assigned staff member changed after renter_return_reminder was sent, or is first assigned inside the last 24 hours before return. | Immediate, only inside the 24 hours before return | No | transactional |
| `renter_return_reminder` | Hourly reminders job: booking status is on_rent and the return time is 24 hours away. Sent once per return time, so it is sent again after an extension moves the return. (Message template T6.) | 24 hours before return | No | transactional |
| `renter_review_ask` | Review requests (migration 0138, app.job_review_requests every 10 minutes): review_ask_after_minutes (60 by default) after the car is checked in (booking status returned or closed). Only from 9 am to 9 pm Toronto time (Program settings). Never while a return or later charge (late, kilometres, fuel, cleaning, smoking, damage, tolls) is not settled or waived, nor with an open incident or dispute: the booking waits on the hold list and is released by itself, or by staff with Send anyway. Not sent when the renter already reviewed (on the site, on Google matched by name, "I already left a review", or marked by staff) or unsubscribed. Staff can also send it from the booking (Ask for a review). Never depends on a rating and offers nothing for a review. Relies on the existing business relationship for consent, so it carries the unsubscribe link and mailing address. | 1 hour after the check-in, 9 am to 9 pm | No | marketing |
| `renter_review_final` | Review requests (migration 0138): review_final_days (7 by default) after renter_review_ask, the last message of the sequence, with the same rules: 9 am to 9 pm Toronto time, held while a charge is open, stopped once the renter reviewed (on the site, on Google, "I already left a review", or marked by staff) or unsubscribed. Once per booking. Relies on the existing business relationship for consent, so it carries the unsubscribe link and mailing address. | 7 days after the review request | No | marketing |
| `renter_review_reminder` | Review requests (migration 0138): review_reminder_hours (24 by default) after renter_review_ask, with the same rules: 9 am to 9 pm Toronto time, held while a charge is open, stopped once the renter reviewed (on the site, on Google, "I already left a review", or marked by staff) or unsubscribed. Once per booking. Relies on the existing business relationship for consent, so it carries the unsubscribe link and mailing address. | 24 hours after the review request | No | marketing |
| `renter_review_request` | 2 days after booking status becomes closed. Only if the renter has not unsubscribed and no review exists for it. A booking that had a problem (an incident, a dispute, an unpaid balance or a damage charge) is not sent automatically: it waits for a staff member to approve it (review_request_decision task, app.decide_review_request). Only an approval sends it, at once; a refusal means it is never sent. Relies on the existing business relationship for consent, so it carries the unsubscribe link and mailing address. | 2 days after the booking closes | No | marketing |
| `renter_signing_code` | A renter or driver about to sign a rental agreement, an amendment or a new version asks for the identity code by email (migration 0154). The code proves the signer controls the email on file; it is never stored in clear. | Immediate | No | transactional |
| `renter_staff_message` | A staff member (customer service, Sales, Fleet, Finance or an Admin) writes to the renter from the booking (Email the renter, or a reply in the booking's messages), sent as CarmaCars. The subject is the one they typed. The message is kept on the booking and shown in the renter's account; this email carries it with a link to reply there. One email per message. | Immediate | No | transactional |
| `renter_trip_checkin` | Review requests (migration 0138, app.job_review_requests every 10 minutes): booking status is on_rent, the rental is at least review_checkin_min_days long (2 by default) and review_checkin_after_hours (24 by default) have passed since the pickup, never in the last 6 hours before the return. Only from review_send_from_hour to review_send_until_hour Toronto time (9 am to 9 pm by default). A service message about the rental in progress: it asks for no review. Once per booking. | 24 hours after the pickup, rentals of 2 days or more | No | transactional |
| `renter_vehicle_disabled` | A tracker command of type engine disable for a booking is confirmed by the tracker (status confirmed), after admin approval. (Message template T15.) | Immediate | No | transactional |

### Owner (45)

| Code | Trigger | Timing | Digest | Category |
| --- | --- | --- | --- | --- |
| `owner_account_created` | The person confirms their email address for the first time (the confirmation link from the sign-in service, an invitation or a password link) and has the owner role. Sent once per account. Accounts already confirmed before October 16, 2026 do not get it. | Immediate | No | transactional |
| `owner_agreement_ready` | Vehicle onboarding status changes to documents_sent (a signature request for the owner documents is opened): the Enrollment Agreement and Title Agreement for a first vehicle, or an Additional Vehicle Schedule for a later one, with the forms that vehicle needs. | Immediate | No | transactional |
| `owner_agreement_signed` | Vehicle onboarding status changes to documents_signed (every owner document for the vehicle is signed by the owner and countersigned by CarmaCars, and witnessed forms are uploaded). | Immediate | No | transactional |
| `owner_application_approved` | An Admin approves an owner application the owner sent themselves (Admin > Owners and partners > Applications > Approve): the owner is active, each car has the terms the Admin confirmed, the agreements open for one signature in the owner portal, and only the invoices the Admin chose are sent (their own emails go too). An application staff entered for the owner gets owner_car_set_up instead. | Immediate | No | transactional |
| `owner_application_declined` | Vehicle onboarding status changes to declined at any step before enrolled. Staff choose the reason. | Immediate | No | transactional |
| `owner_application_info_requested` | An Admin presses "Ask for something" on an owner application (Admin > Owners and partners > Applications) and chooses what is needed. The owner also sees it as a task in the owner portal until they answer. One email per request. | Immediate | No | transactional |
| `owner_application_received` | An owner vehicle application is submitted (vehicle onboarding row created with status intake), for a first vehicle or an added vehicle. | Immediate | No | transactional |
| `owner_bank_details_changed` | An owner's payout account, pre-authorized debit authorization or card on file is added, changed or removed, by the owner or by staff. Sent to the owner's email address on file before the change, and never batched. Security notice. | Immediate | No | transactional |
| `owner_booking_changed` | A change to a confirmed booking on the owner's car is applied (new dates, another car, or a new rental charge). One email to each owner whose car or income the change touches: the owner of the car it left and, if different, the owner of the car it moved to. Not sent for Owner Bookings, nor for a booking not shown to the owner (0156). show_amounts is false while staff hide the booking's revenue from the owner: the shares are left out. | Immediate | No | transactional |
| `owner_booking_confirmed` | A booking of type owner (an Owner Booking: the owner driving their own vehicle) changes to confirmed, after the owner signs the Owner Rental agreement and staff confirm the licence is valid. | Immediate | No | transactional |
| `owner_car_set_up` | Staff added a car for the owner (Admin, customer service or fleet: Add a car for this owner) and an Admin approved it with its terms and first invoices. The owner's one email: review the details and sign. Not sent when the owner signs on paper. For an owner with no sign-in yet it carries the link to choose a password. | Immediate, after approval | No | transactional |
| `owner_cosigner_sign` | Every Owner named in the Title Schedule signs the program agreements. The documents of an owner are opened for signature (or an Admin adds an Owner, or sends the link again): each Owner besides the one with the portal account gets their own signing link. The agreements take effect when the last Owner signs. | Immediate | No | transactional |
| `owner_debit_notice` | Owner debit notice job, on the notice day (the debit day less the notice days in Program settings, 10 by default): the owner has issued invoices that will be debited automatically on the debit day from their pre-authorized debit account. One email per owner, listing every invoice in the debit. Required notice under the pre-authorized debit agreement. | The notice days before the debit day (the 5th for the 15th by default) | No | transactional |
| `owner_debit_returned` | The bank returns the automatic debit of an owner invoice for a reason other than insufficient funds (for example the account is closed), or for insufficient funds too late for a retry within 30 days of the original debit. The debit is not retried: the automatic debit of that invoice is paused and an Admin is alerted at the same time. One email per returned debit. | The day the bank reports the returned debit | No | transactional |
| `owner_debit_setup_needed` | Owner debit notice job (or the debit run itself): the owner has invoices due for the automatic debit but no active pre-authorized debit agreement on file, or it was cancelled at the bank. Nothing is debited. One email per owner per debit date. An Admin gets the exception at the same time. | The notice day, or the debit day when the agreement was cancelled since the notice | No | transactional |
| `owner_document_due` | Expiry-watch job (daily 06:00): a document or registration item on the owner's vehicle expires in 14 days: plate renewal, or for a Turo-Only vehicle the owner's insurance proof. Sent once at 14 days and again at 3 days if still open. (Message template T23 for Turo-Only insurance.) | 14 days before the expiry, again at 3 days | No | transactional |
| `owner_exit_completed` | Vehicle status changes from exit_notice to exited (Form E signed by both sides, tracker removed, registration returned). | Immediate | No | transactional |
| `owner_exit_notice_received` | Vehicle status changes to exit_notice (the owner's written notice naming the vehicle is logged, or an admin decides to remove it) and the Exit Date is set. This email confirms the Exit Date in writing. | Immediate | No | transactional |
| `owner_fee_change_cancelled` | An Admin cancels a change to a car's terms that had not started yet (migration 0165; History on the car page or the owner's terms): a higher or lower Insurance Fee, Tracker Fee or management fee noticed in writing, a Management Mode change, or an updated Vehicle Schedule that was waiting for the owner's signature. One email per cancelled change, saying what was going to change and that the terms stay as they are. | Immediate | No | transactional |
| `owner_fee_change_notice` | An admin changes a vehicle's terms after its Vehicle Schedule is signed: a higher Insurance Fee or Tracker Fee (a fee history row at least 30 days ahead), a higher Revenue Share (the same notice, and a new Vehicle Schedule opened for signature), or lower amounts (in force from today or a chosen date, no notice period). One email per change. is_share_change is true when a higher Revenue Share needs the owner's signature; is_decrease is true for lower amounts. | Immediate: at least 30 days before the effective date of a higher amount; on the day a lower amount is set | No | transactional |
| `owner_fee_invoice` | Owner-billing job on the 15th: a monthly owner invoice for a vehicle is issued and its pre-authorized debit is submitted. One invoice and one email per vehicle. Not sent for Turo-Only vehicles or vehicles owned personally by the two principals. (Message template T24.) | 15th of each month | No | transactional |
| `owner_form_approved` | Customer service or an Admin approves a Form C or Form D the owner uploaded. | Immediate | No | transactional |
| `owner_form_rejected` | Customer service or an Admin sends back a Form C or Form D the owner uploaded, with the reason. The owner uploads it again from the owner portal. | Immediate | No | transactional |
| `owner_in_arrears` | Debit-retry job on the 18th: the retry of a failed owner invoice also fails and the invoice status becomes in_arrears (the vehicle's arrears flag is set). | The day the bank reports the failed retry (18th or after) | No | transactional |
| `owner_incident_opened` | An incident (accident, theft, vandalism, or damage found at return) is opened on a vehicle that belongs to a third-party owner, or a claim is opened for it. (Message template T17.) | Immediate, the day the incident is opened | No | transactional |
| `owner_incident_update` | A claim on a third-party owner's vehicle changes status (submitted, accepted, in_repair, repaired, settling, closed), or staff post an incident event marked visible to the owner. | Immediate | No | transactional |
| `owner_invoice_issued` | An Admin issues an owner invoice made by hand (a registration fee or any other amount agreed with the owner, Admin > Money > Owner invoices, the owner page or the application), or a credit note, or presses Resend on one. Not sent for an invoice recorded as already paid (the receipt goes instead). | Immediate | No | transactional |
| `owner_invoice_voided` | An Admin voids an issued owner invoice with a reason (nothing was paid on it). Its scheduled debit is cancelled. When a corrected invoice replaces it, that invoice has its own email once it is issued. | Immediate | No | transactional |
| `owner_mode_change_notice` | An Admin changes the Management Mode of a car whose Vehicle Schedule is signed (migration 0165; the car page, Management Mode). When the change is against the owner (a higher fee or management fee, or a change CarmaCars starts) the owner signs an updated Vehicle Schedule and the date is at least the Notice Period ahead (needs_signature is true); when the owner asked for it and no amount is higher, the change is dated and applied by CarmaCars on that date. One email per change. | Immediate: at least the Notice Period (30 days by default) before the date of a change against the owner; on the day it is made for a change the owner asked for | No | transactional |
| `owner_new_booking` | A standard or non-refundable booking on the owner's vehicle changes to confirmed. Not sent for Owner Bookings or for Turo trips, nor for a booking not shown to the owner (0156). is_self_managed is true when the vehicle's management mode is Self-Managed; only then are the renter's name and mobile number included. show_amounts is false while staff hide the booking's revenue from the owner (until the return or the statement): the rental charge is left out. | Immediate | No | transactional |
| `owner_onboarding_steps` | Vehicle onboarding status changes to upfront_paid (or straight from documents_signed for a shareholder-owned vehicle). Lists the steps and documents for that vehicle's onboarding method. | Immediate | No | transactional |
| `owner_pad_confirmed` | An owner's pre-authorized debit mandate becomes active (set up under Banking, confirmed by micro-deposits, or saved with a debit paid from an invoice page). CarmaCars' own confirmation of the pre-authorized debit agreement (Payments Canada Rule H1): the agreement, the payee and how to reach it, the account, the timing, how to cancel and the recourse rights. Sent once per debit mandate. An automatic debit is scheduled only with its notice, the notice days ahead, so this confirmation comes before the first automatic debit. | Immediate, when the debit mandate becomes active | No | transactional |
| `owner_payment_failed` | The bank returns the automatic debit of an owner invoice for insufficient funds (the first debit): the invoice status becomes failed, the Late Fee is added once as its own line, and one retry of the original amount is scheduled on the later of the retry day and 3 business days after the return, within 30 days of the original debit. One email per vehicle. A debit returned for another reason sends owner_debit_returned instead. (Message template T25.) | The day the bank reports the failed debit | No | transactional |
| `owner_payment_received` | An owner invoice changes to paid: the debit for a monthly invoice clears (including a cleared retry), or the upfront invoice is paid by card or e-Transfer. | Immediate | No | transactional |
| `owner_payment_recorded` | An Admin or Finance records a payment received outside the card processor (e-Transfer, cheque, cash, bank transfer or another way) on an owner invoice, in full or in part. The receipt for that payment; the automatic debit stops, or debits only what is still owing. | Immediate | No | transactional |
| `owner_payment_reversed` | An Admin voids a payment that was recorded by hand on an owner invoice (for example a cheque that was returned, or a payment recorded on the wrong invoice), with the reason. The invoice owes that amount again. | Immediate | No | transactional |
| `owner_payout_sent` | A payout row for an owner changes to paid (an admin sent the bank transfer and recorded its reference). Normally the 10th. Not sent when the statement shows a balance owing instead of a payout. (Message template T26, payment part.) | 10th of each month, when the transfer is sent | No | transactional |
| `owner_recruit_outreach` | An Admin sends a message to a prospective owner from Admin > Marketing > Owner recruitment (migration 0167). It is sent only when the consent log allows email for that person: express consent (a yes on a call, a form or a reply), implied consent from their inquiry (6 months) or a business relationship (2 years), a business address published with no "no solicitation" note, or one message after a referral. The message is a template the Admin may edit; the footer names CarmaCars, its mailing address and the reason for the email, and carries the unsubscribe link. One email per send. | Immediate, when the Admin sends it | No | marketing |
| `owner_registry_visit` | Vehicle onboarding status changes to registry_booked (Fleet booked the registry visit), and again if the date, time or place changes. (Message template T21.) | Immediate | No | transactional |
| `owner_schedule_resign` | An Admin changes the terms of a car whose Vehicle Schedule is signed and confirms that the owner must sign an updated one (Admin > the owner > Terms). The new terms apply from their date only once the owner signs; until then the signed terms stay in place. | Immediate | No | transactional |
| `owner_statement_ready` | An owner statement changes to issued: on the 10th of the month, after an admin approves the payout run, for the previous month. One statement and one email per owner, covering all their vehicles. (Message template T26, statement part.) | 10th of each month | No | transactional |
| `owner_toll_ticket` | A toll or ticket is matched to the owner rather than a renter. is_forwarded true: the owner had the car outside the program, or the car is Turo-Only, and the notice is forwarded for the owner to pay. is_forwarded false: the owner had the car on an Owner Booking, CarmaCars paid it and an owner deduction is created at cost with no fee. | Immediate, when Finance matches the notice | No | transactional |
| `owner_upfront_invoice` | The upfront owner invoice for a vehicle is issued after documents_signed: the Install Fee plus the first and last month's Insurance Fee, with HST. Not issued for Turo-Only or shareholder-owned vehicles. | Immediate | No | transactional |
| `owner_vehicle_enrolled` | Vehicle onboarding status changes to enrolled (the insurer's confirmation is filed and the vehicle is on the fleet policy). This email is the written confirmation that sets the Enrollment Date. (Message template T22.) | Immediate | No | transactional |
| `owner_vehicle_listed` | Vehicle status changes from ready_to_list to available and its listing is published (staff approved the listing). | Immediate | No | transactional |

### Investor (3)

| Code | Trigger | Timing | Digest | Category |
| --- | --- | --- | --- | --- |
| `investor_notice_received` | An admin logs a written notice received from an existing investor (change of bank account, change of the pay or reinvest election, change of contact details, or another notice under the Investment Agreement). | Immediate, when the notice is logged | No | transactional |
| `investor_return_paid` | An investor monthly return row changes to paid (an admin sent the transfer on the Payment Date, the 15th of the month after the Return Month, and recorded its reference). Not sent for a reinvested return. | 15th of each month, when the transfer is sent | No | transactional |
| `investor_statement_ready` | An investor monthly statement for a Return Month is issued by an admin (after the returns accrual on the 1st). Sent only to existing investors with an active investment. Neutral servicing notice. | Monthly, when the statement is issued | No | transactional |

### Staff: admin (18)

| Code | Trigger | Timing | Digest | Category |
| --- | --- | --- | --- | --- |
| `staff_approval_needed` | A task that only an admin can approve is raised, other than a tracker disable: a refund outside the tier table or over the VA limit, a deposit release with a hold-back, a price override, a fee off the grid, or a write-off. Queued for the next admin digest. Sent immediately instead when its due time is within 4 hours. | Next digest. Immediate if due within 4 hours | Yes | transactional |
| `staff_digest_eod_admin` | Scheduled digest for Admin. Sent every day at 18:15 Toronto time (after the 18:00 reconcile job) to each active staff member with this role. Skipped when there is nothing to report. It carries every notice queued for this role with digest true since the last digest, plus these lists computed at send time: bookings confirmed today, money collected today, approvals still open, incidents updated today, anything a VA escalated that is not closed, tomorrow's pickups and returns. Each line links to the item. One email replaces the separate notices. | Daily 18:15 | No | transactional |
| `staff_digest_morning_admin` | Scheduled digest for Admin. Sent every day at 07:30 Toronto time to each active staff member with this role, even when nothing is waiting, so a missing digest is itself a warning sign. It carries every notice queued for this role with digest true since the last digest, plus these lists computed at send time: approvals waiting, open incidents and claims, open disputes, late returns, charges unpaid over 24 hours, owners in arrears, requests waiting over 2 hours, failed jobs. Each line links to the item. One email replaces the separate notices. | Daily 07:30 | No | transactional |
| `staff_disable_approval_needed` | A tracker command of type engine disable is created with status requested (Fleet asks after the final notice deadline passes, or on another ground in procedure 8). Sent to both admins. Immediate. The car is never disabled by a job. | Immediate | No | transactional |
| `staff_dispute_opened` | A dispute row is created from the payment processor webhook (a card dispute or chargeback is opened on a renter payment, or a debit dispute on an owner invoice). Sent to both admins and finance. Immediate. | Immediate | No | transactional |
| `staff_fleet_count_warning` | Fleet-recount job (Monday 08:00): vehicles on the fleet policy, less those under exit notice, number 11 or fewer. Also sent at once when an exit notice or removal would take the count to 11 or fewer. Turo-Only cars are not counted. | Monday 08:00, or at once on an exit notice | No | transactional |
| `staff_incident_reported` | An incident row is created of type accident, theft, vandalism or damage (including damage recorded on a return condition report or found in the photo review). Sent to both admins and Fleet. Immediate. | Immediate | No | transactional |
| `staff_job_failed` | A scheduled job run is marked failed in job_runs (which also raises one urgent admin task). Sent to both admins once per job per day. Immediate. | Immediate | No | transactional |
| `staff_monthly_statements_pdfs` | Statement emails job, on the company statement email day in Program settings (the 10th by default): the company statement for last month exists (draft or final). One email to each Admin with three PDFs attached: the company total with every section, the statement by owner and the statement by vehicle. An Admin can also send it to themselves from Company statements. | The company statement email day (the 10th by default) | No | transactional |
| `staff_monthly_statements_ready` | The company statement for a month is finalized (company statement status becomes final): the company statement and the owner statements for that month are drafted and need an admin's review before the owner statements are approved and issued. One email to each admin. | Immediate, when the company statement is finalized | No | transactional |
| `staff_owner_debit_exception` | An owner's automatic debit cannot go ahead: no active pre-authorized debit on file at the notice or on the debit day, the agreement was cancelled at the bank (Stripe mandate inactive), the balance grew after the notice, or the invoice is blocked for another reason. Paused invoices are not reported. Immediate to the Admins; an Admin task opens for a missing debit agreement. | Immediate | No | transactional |
| `staff_owner_debit_run` | The owner-debit run of a day is done (every scheduled debit due that day was sent, skipped or cancelled): one summary to the Admins with each debit and its status. Results that come back days later are in Owner debits; a returned debit also sends the owner invoice failure notice to finance. | The debit day (the 15th by default), after the run | No | transactional |
| `staff_payouts_due` | Payouts job on the 10th at 08:00: approved owner payouts are due to be sent by bank transfer that day. Also on the 15th at 08:00 for investor returns due on the Payment Date. One email to both admins and finance. If the run is not approved yet, the email says so. | 10th (owners) and 15th (investor returns), 08:00 | No | transactional |
| `staff_site_alert` | Site check (every 5 minutes, from the database): a page or service failed its check repeatedly (the home page, a car page, sign-in or the site's health check answers an error or Error 1102, or does not answer), emails are failing or stuck, a scheduled job failed, the nightly backup failed or is late, or Stripe webhooks are failing. Sent to the alert address in Program settings (uptime_alert_email), once per problem; a second problem of the same kind within the cooldown is shown on Admin > To do without another email. Immediate. | Immediate | No | transactional |
| `staff_site_recovered` | Site check: a problem that sent a site alert passed its check again. One email per alert that was emailed, to the same address. Immediate. | Immediate | No | transactional |
| `staff_statements_ready_for_approval` | Statements-draft job on the 5th at 06:00: the draft owner statements for last month are built and an approval task is raised. One email to both admins. A reminder is sent on the 8th at 09:00 if the run is still not approved. | 5th of each month, reminder on the 8th | No | transactional |
| `staff_usage_alert` | Usage guard (every hour, from the database): a metered service (Workers AI, Worker requests and CPU, image transformations, Resend emails, the database and file storage on our server, R2 storage, the Claude assistant) reached 80% of its included allowance for the period, or used all of it. Sent to the alert address in Program settings (uptime_alert_email), once per service, level and period, never from uptime_quiet_from_hour to uptime_quiet_until_hour (it waits for the morning). The same alert shows on Admin > To do. | Immediate | No | transactional |
| `staff_weekly_summary` | Scheduled: every Monday at 07:45 Toronto time, for the week that ended Sunday at midnight. One email to each of the two admins. Always sent, even with no activity. | Monday 07:45 | No | transactional |

### Staff: VA finance (9)

| Code | Trigger | Timing | Digest | Category |
| --- | --- | --- | --- | --- |
| `staff_cancellation_received` | A booking cancellation row is created (booking status becomes cancelled or no_show). Queued for the next finance and customer service digests. Sent immediately to the admins instead when the refund is over $500 or outside the tier table, because it needs approval. | Next digest. Immediate to admins when approval is needed | Yes | transactional |
| `staff_digest_eod_va_finance` | Scheduled digest for Finance. Sent every day at 18:15 Toronto time (after the 18:00 reconcile job) to each active staff member with this role. Skipped when there is nothing to report. It carries every notice queued for this role with digest true since the last digest, plus these lists computed at send time: processor payouts not matched by the 18:00 reconcile job, today's returns not yet billed, refunds still open, cancellations received today, payments that failed today. Each line links to the item. One email replaces the separate notices. | Daily 18:15 | No | transactional |
| `staff_digest_morning_va_finance` | Scheduled digest for Finance. Sent every day at 07:30 Toronto time to each active staff member with this role, even when nothing is waiting, so a missing digest is itself a warning sign. It carries every notice queued for this role with digest true since the last digest, plus these lists computed at send time: returns waiting for a statement, deposits near 7 business days since check-in, hold-backs near 30 days, card retries due today, declined payments, tolls and tickets to match and charge, refunds to process, owner invoices failed. Each line links to the item. One email replaces the separate notices. | Daily 07:30 | No | transactional |
| `staff_insurer_invoice_due` | Daily check at 06:00: an insurer_invoices row with status sent or part_paid has a balance and sent_at is 30 days ago. Queued once for the finance morning digest, then listed again every 7 days while the balance remains. At 60 days it is also queued for the admin digest. | Morning digest, 30 days after the invoice was sent, then weekly | Yes | transactional |
| `staff_owner_invoice_failed` | An owner invoice changes to failed (first debit returned) or in_arrears (retry on the 18th returned). Queued for the next finance digest. The in_arrears case is also sent immediately to both admins. | Next digest. Immediate to admins when the retry fails | Yes | transactional |
| `staff_payment_failed` | A charge to a renter's Card on File is declined (payment attempt fails, not a checkout attempt on an offer). Queued for the next finance digest. Sent immediately to finance and admins instead when the booking is on_rent and the charge is still unpaid 24 hours after the request. | Next digest. Immediate at 24 hours unpaid during a rental | Yes | transactional |
| `staff_return_findings` | Fleet completes the review of a return (the return condition report is reviewed and the findings are saved on the booking). Queued for the next finance digest. Sent immediately to the admins as well when damage is recorded. (Message template T7, internal.) | Next digest, same day as the return | Yes | transactional |
| `staff_toll_ticket_logged` | A toll or ticket row is created (a notice is logged) and the automatic match has run. Queued for the next finance digest with the match result. | Next digest | Yes | transactional |
| `staff_toll_ticket_unmatched` | Daily check at 06:00: a toll or ticket row has had no match for 2 business days since it was logged. Queued for the morning digest of finance and the admins, once per notice. | Morning digest, 2 business days after logging | Yes | transactional |

### Staff: VA fleet (10)

| Code | Trigger | Timing | Digest | Category |
| --- | --- | --- | --- | --- |
| `staff_breakdown_reported` | An incident row of type breakdown is created (a call to the 24-hour line is logged, or the renter reports it in the portal). Sent to the on-call Fleet person. Immediate. | Immediate | No | transactional |
| `staff_calendar_conflict` | Calendar sync (every 10 minutes by default): a trip or block imported from another platform (Turo, Getaround or another calendar link) overlaps a confirmed or on-rent CarmaCars booking of the same car, turnaround included. One email per imported event and booking; it also raises an urgent Fleet task and shows on the Admin To do. Immediate. | Immediate | No | transactional |
| `staff_calendar_feed_failing` | Calendar sync: an imported calendar link (Turo, Getaround or another platform) failed this many times in a row (calendar_feed_alert_failures in Program settings, 3 by default). Sent once per run of failures; it also raises a Fleet task. The trips already imported stay on the calendar until the link works again. Immediate. | Immediate | No | transactional |
| `staff_digest_eod_va_fleet` | Scheduled digest for Fleet. Sent every day at 18:15 Toronto time (after the 18:00 reconcile job) to each active staff member with this role. Skipped when there is nothing to report. It carries every notice queued for this role with digest true since the last digest, plus these lists computed at send time: the closing checks of procedure 19: handovers and returns without a signed condition report or full photo set, returns with no findings sent to Finance, calendar statuses that do not match, tomorrow's cars not cleaned, incidents updated, the handover note for the on-call person. Each line links to the item. One email replaces the separate notices. | Daily 18:15 | No | transactional |
| `staff_digest_morning_va_fleet` | Scheduled digest for Fleet. Sent every day at 07:30 Toronto time to each active staff member with this role, even when nothing is waiting, so a missing digest is itself a warning sign. It carries every notice queued for this role with digest true since the last digest, plus these lists computed at send time: the opening checks of procedure 19: trackers not reporting, overnight movement or tamper alerts, today's handovers and returns with their field person and acknowledgement, tomorrow's pickups not ready, late returns, the expiry watch, listings to review, cars due for cleaning. Each line links to the item. One email replaces the separate notices. | Daily 07:30 | No | transactional |
| `staff_exit_notice_received` | Vehicle status changes to exit_notice. Queued for the next Fleet, finance and admin digests. Sent immediately to the admins instead when the fleet count after the exit would be below 10. | Next digest. Immediate to admins if the fleet would fall below 10 | Yes | transactional |
| `staff_expiry_watch` | Expiry-watch job (daily 06:00) finds at least one item inside its window: plate renewal within 30 days, an insurance document within 14 days, a safety certificate inside its 36-day window with no registry visit booked, or arrears older than 30 days. The list is included in the Fleet morning digest; sent as its own email to Fleet and admins only when an item expires within 3 days. | Morning digest. Own email when an item is within 3 days | Yes | transactional |
| `staff_late_return_alert` | Late-returns job (every 5 minutes): an on_rent booking passes its return time with no paid extension. Sent to Fleet at 0 minutes and at 30 minutes, and to Fleet and both admins at 2 hours. Immediate. The stage fills late_stage. | At 0 and 30 minutes late (Fleet); at 2 hours (Fleet and admins) | No | transactional |
| `staff_listing_ready_for_review` | The AI drafting step finishes for a vehicle listing (photos processed, description and details drafted) and the vehicle status becomes ready_to_list. Queued for the next Fleet digest. Nothing is published until a person approves. | Next digest | Yes | transactional |
| `staff_listing_similarity` | The listing similarity check finds a likely duplicate that stops publishing: a VIN one character from another car, the same plate, the same listing photo as a listed car, listing text very like a listed car (listing_similarity_copy_bps in Program settings), Queued for the next Fleet digest; a Fleet task is raised with it. | Next digest | Yes | transactional |

### Staff: VA customer service (13)

| Code | Trigger | Timing | Digest | Category |
| --- | --- | --- | --- | --- |
| `staff_booking_request_new` | A booking row is created with status requested (booking event requested). Sent to every active customer service VA. Immediate, never batched. | Immediate | No | transactional |
| `staff_change_proposal_answered` | A change staff proposed to a confirmed booking ends: the renter accepted it online (amendment signed, difference settled, booking updated), declined it, or did not answer by the deadline. Queued for the next customer service digest. Staff notices about a test owner's car go only to the verification accounts. | Next digest | Yes | transactional |
| `staff_change_request_received` | A booking change request row is created by a renter. Queued for the next customer service digest. Sent immediately instead when the pickup is less than 48 hours away or the booking is on_rent. | Next digest. Immediate if pickup is within 48 hours or the car is on rent | Yes | transactional |
| `staff_chat_waiting` | A visitor in live chat needs a person (they asked, or the assistant handed over: a complaint, damage, an accident, a payment, a question it could not answer, or the day's AI allowance is used). Sent only to staff on shift (Live chat or Live visitors open in the last minutes) who turned on "Email me when a chat waits" in Live chat. Immediate. | Immediate | No | transactional |
| `staff_digest_eod_va_cs` | Scheduled digest for Customer service. Sent every day at 18:15 Toronto time (after the 18:00 reconcile job) to each active staff member with this role. Skipped when there is nothing to report. It carries every notice queued for this role with digest true since the last digest, plus these lists computed at send time: requests still unanswered, offers sent today and still open, documents still to review, change requests open, tomorrow's pickups and their verification status, reviews received today. Each line links to the item. One email replaces the separate notices. | Daily 18:15 | No | transactional |
| `staff_digest_morning_va_cs` | Scheduled digest for Customer service. Sent every day at 07:30 Toronto time to each active staff member with this role, even when nothing is waiting, so a missing digest is itself a warning sign. It carries every notice queued for this role with digest true since the last digest, plus these lists computed at send time: requests waiting for an offer, requests waiting on the renter, offers open and when each expires, identity and coverage documents to review, change requests, tomorrow's pickups with verification incomplete, reviews to moderate, bookings confirmed since the last digest. Each line links to the item. One email replaces the separate notices. | Daily 07:30 | No | transactional |
| `staff_extension_requested` | A booking extension row is created with status requested. Immediate, because an extension must be confirmed in writing and paid before the current return time. | Immediate | No | transactional |
| `staff_identity_review` | A renter or additional driver uploads identity documents (licence front, back and selfie) or coverage proof, creating a verification in status pending review. Queued for the next customer service digest. Sent immediately instead when the booking's pickup is less than 48 hours away. | Next digest. Immediate if pickup is within 48 hours | Yes | transactional |
| `staff_offer_approved_paid` | Booking status changes from pending_payment to confirmed (offer approved, agreement signed, total paid). Queued for the next digest of customer service and fleet. Sent immediately instead when the pickup is less than 24 hours away. | Next digest. Immediate if pickup is within 24 hours | Yes | transactional |
| `staff_owner_form_uploaded` | An owner uploads a signed and witnessed Form C (lender or lessor permission acknowledgment, per financed or leased car) or Form D (limited power of attorney). Queued for the next customer service digest; a review task is raised with it. | Next digest | Yes | transactional |
| `staff_renter_replied` | A renter writes in the messages of their booking from their account. A "Renter replied" task opens in the customer service queue (one per booking while it is open). Queued for the next customer service digest; sent immediately instead when the car is out or the pickup is less than 48 hours away. | Next digest. Immediate if the car is out or pickup is within 48 hours | Yes | transactional |
| `staff_request_waiting` | Scheduled check every 5 minutes: a booking has had status requested for more than 2 hours since requested_at with no offer sent, no more-information message and no decline. Not raised for a booking that returned to requested from an expired or withdrawn offer. Sent once per request, to customer service and both admins. Immediate. | 2 hours after an unanswered request | No | transactional |
| `staff_review_received` | A renter submits a review for a closed booking (review row created, status pending moderation). Queued for the next customer service digest. A rating of 2 stars or lower is sent immediately to customer service and both admins instead. | Next digest. Immediate for 2 stars or lower | Yes | transactional |

### Staff: VA sales (5)

| Code | Trigger | Timing | Digest | Category |
| --- | --- | --- | --- | --- |
| `staff_commission_approved` | An Admin approves one or more of a staff member's commissions (Admin > Money > Staff commissions). One email to that staff member, at their own address, for each approval. A Sales commission is approved after its month ends. Nothing is paid yet: the payment is recorded separately. | Immediate | No | transactional |
| `staff_commission_paid` | An Admin records the payment of a staff member's approved commissions (Admin > Money > Staff commissions > Record a payment): e-Transfer, bank transfer, Wise, cash, another way, or the monthly pay statement. One email to that staff member, at their own address, for each payment recorded. | Immediate | No | transactional |
| `staff_digest_eod_va_sales` | Scheduled digest for Sales. Sent every day at 18:15 Toronto time (after the 18:00 reconcile job) to each active staff member with this role. Skipped when there is nothing to report. It carries every notice queued for this role with digest true since the last digest, plus these lists computed at send time: applications received today and whether each was answered, documents signed today, upfront invoices paid today, applications with no contact for 3 days. Each line links to the item. One email replaces the separate notices. | Daily 18:15 | No | transactional |
| `staff_digest_morning_va_sales` | Scheduled digest for Sales. Sent every day at 07:30 Toronto time to each active staff member with this role, even when nothing is waiting, so a missing digest is itself a warning sign. It carries every notice queued for this role with digest true since the last digest, plus these lists computed at send time: owner applications not yet answered, owners with documents sent but not signed, upfront invoices unpaid, onboardings waiting on an owner document, registry visits in the next 7 days. Each line links to the item. One email replaces the separate notices. | Daily 07:30 | No | transactional |
| `staff_owner_application_received` | An owner vehicle application is submitted (vehicle onboarding row created with status intake), from a new owner or an enrolled owner adding a vehicle. Sent to every active sales VA. Immediate. | Immediate | No | transactional |

### Staff: field (5)

| Code | Trigger | Timing | Digest | Category |
| --- | --- | --- | --- | --- |
| `staff_field_job_assigned` | A field job (pickup handover, return, tracker install, detail or photo shoot) is assigned to a field staff member, or reassigned to a new one. Sent to the new assignee. Immediate. | Immediate | No | transactional |
| `staff_field_job_changed` | An assigned field job has its time, place or vehicle changed, or is cancelled or taken away from the assignee. Sent to the staff member who held the job. Immediate. | Immediate | No | transactional |
| `staff_field_jobs_today` | Scheduled digest for field staff: every day at 07:00 Toronto time, one email to each field staff member who has at least one job that day. Skipped for a person with no jobs. Lists the same jobs as the evening digest, with any changes made overnight. | Daily 07:00 | No | transactional |
| `staff_field_jobs_tomorrow` | Scheduled digest for field staff: every day at 18:00 Toronto time, one email to each field staff member who has at least one job assigned for the next day (pickup handovers, returns, tracker installs, details, photo shoots). Skipped for a person with no jobs. Jobs assigned or changed after it is sent go out at once with staff_field_job_assigned or staff_field_job_changed. | Daily 18:00 | No | transactional |
| `staff_pay_statement` | An Admin records the payment of a field staff member's pay for a two-week pay period (Admin > Money > Field pay > Pay run > Record the payment; migration 0165), or sends the statement again. One email to that staff member, at their own address, with the figures of their pay statement (the PDF is in My hours). | Immediate | No | transactional |

### Insurer (billing contact) (1)

| Code | Trigger | Timing | Digest | Category |
| --- | --- | --- | --- | --- |
| `insurer_invoice` | An insurer invoice is sent from the admin portal (Send by email): the invoice for a replacement rental billed to an insurer, with a 7-day link to the PDF. Sending again sends a new email. | When Finance or an Admin sends the invoice | No | transactional |

### Job applicant (7)

| Code | Trigger | Timing | Digest | Category |
| --- | --- | --- | --- | --- |
| `applicant_booked` | A candidate books, or moves, their interview call from their booking link on carmacars.ca/careers/book (migration 0173). By phone, CarmaCars calls the number on the application; by video, the email has the Jitsi Meet link made for this booking. One email per booking or move. | Immediate | No | transactional |
| `applicant_cancelled` | A candidate cancels their interview call from their booking link on carmacars.ca/careers/book (migration 0173). The invitation stays open: the same link books another time. One email per cancellation. | Immediate | No | transactional |
| `applicant_declined` | A candidate's answers on carmacars.ca/careers include a knock-out (a requirement of the role they do not meet) and the role offers no other role instead, or an Admin presses Decline in Admin > People > Hiring with the email left on (migration 0173). One email per decision. | Immediate | No | transactional |
| `applicant_invited` | A candidate's screening score on carmacars.ca/careers reaches the role's pass mark with no knock-out, or an Admin presses Invite anyway in Admin > People > Hiring (migration 0173). The email has the candidate's personal booking link for a short interview call; for a remote assistant role it also describes the paid test task. One email per invitation. | Immediate | No | transactional |
| `applicant_received` | A candidate sends an application on carmacars.ca/careers and the screening score is below the role's pass mark, with no knock-out and no other open role to offer (migration 0173). The application waits for the owner's review. One email per application; invited, declined and referred candidates get their own email instead. | Immediate | No | transactional |
| `applicant_referred` | A candidate does not qualify for the role they applied for on carmacars.ca/careers (a knock-out or a score below the pass mark for Field staff; a score below the pass mark for a remote assistant role) and another open role suits them: Field staff to Sales and Customer Relations (In person, Toronto), with Remote Sales named as the other choice; Sales in person to Remote Sales; or the best matching other open role (migration 0173). Not sent when they already applied for that role. The link opens that role's application with their name, email and phone filled in. One email per application. | Immediate | No | transactional |
| `applicant_reminder` | A booked interview call is the next day (sent at 6 pm Toronto time the evening before) or about an hour away (migration 0173, app.job_hiring every 15 minutes). Not sent when the call was booked after that moment. When phone and texts are on, a text goes with the reminder an hour before. One email per reminder. | The evening before (6 pm Toronto time) and about an hour before the call | No | transactional |
<!-- EMAIL TABLE END -->
