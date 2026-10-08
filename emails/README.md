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
  reply_to: entry.reply_to,                      // always info@carmacars.ca
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

`catalogue.json` holds `reply_to`, `global_variables` (values every email receives: `support_phone`, `company_address`), `count`, and `emails`. Each entry:

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
| `from` | `bookings@`, `owners@`, `billing@` or `hello@` at `mail.carmacars.ca`, display name CarmaCars |
| `reply_to` | `info@carmacars.ca` |
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
### Renter (50)

| Code | Trigger | Timing | Digest | Category |
| --- | --- | --- | --- | --- |
| `account_password_reset` | A password reset is requested for any account (the sign-in service recovery event). One template for every account type. | Immediate | No | transactional |
| `account_security_notice` | A security event on any account: a sign-in from a device or browser not seen before on that account, a password change, or a change of the account email address. One template for every account type. For an email change it is sent to both the old and the new address. Never batched. | Immediate | No | transactional |
| `account_sign_in_link` | A one-time sign-in link is requested for any account (the sign-in service magic link event). Also used as the invitation when an admin creates an owner, investor or staff account. | Immediate | No | transactional |
| `renter_accident_instructions` | An incident of type accident, theft or vandalism is opened on an on_rent booking (Fleet logs the renter's call). (Message template T16.) | Immediate | No | transactional |
| `renter_account_created` | A user with the renter role is created (sign-up form, or the account made with a first booking request) and the email address is not yet verified. | Immediate | No | transactional |
| `renter_agreement_ready` | A signature request is opened for a signer who is not in the middle of checkout: each additional driver on the booking, or the renter when the agreement is reissued (accepted change, extension or renewal) or left unsigned for 1 hour while the booking is pending_payment (offer approved, signing and payment in progress). | Immediate | No | transactional |
| `renter_agreement_signed` | A rental agreement signature request is completed (every signer has signed and CarmaCars has countersigned). Sent to the renter and to each additional driver who signed. | Immediate | No | transactional |
| `renter_balance_overdue` | Daily check: a renter statement was sent 7 days ago and a balance on it is still unpaid (all card retries failed or are pending). Sent once at 7 days, then with each monthly interest posting on the 1st while a balance remains. | 7 days after the statement, then monthly on the 1st | No | transactional |
| `renter_booking_cancelled` | Booking status changes from confirmed to cancelled or no_show with a booking cancellation row where cancelled_by is renter (the database computes the tier, percent and refund). (Message template T12.) | Immediate | No | transactional |
| `renter_booking_cancelled_by_us` | Booking status changes from confirmed to cancelled with a booking cancellation row where the cancelling party is CarmaCars (no car or accepted substitute), or where the reason is that a driver could not be verified. The refund is 100%, including non-refundable bookings. | Immediate | No | transactional |
| `renter_booking_confirmed` | Booking status changes from pending_payment to confirmed (the offer was approved, the agreement signed, the booking total paid and the car still free for the dates). | Immediate | No | transactional |
| `renter_booking_reminder` | Hourly reminders job: booking status is confirmed and the pickup time is 24 hours away. Sent once. (Message template T5.) | 24 hours before pickup | No | transactional |
| `renter_breakdown_help` | An incident of type breakdown on an on_rent booking has roadside dispatched (dispatched_at is set by Fleet). (Message template T18.) | Immediate | No | transactional |
| `renter_change_request_approved` | Staff approve a change request on a confirmed booking. Sent when the change request status becomes approved. (A change to a booking that is still offered is sent as a revised offer with renter_offer_ready instead.) | Immediate | No | transactional |
| `renter_change_request_declined` | Staff decline a change request. Sent when the change request status becomes declined; staff enter the reason. | Immediate | No | transactional |
| `renter_change_request_received` | The renter asks for a change: on an open offer the current booking_offers row becomes change_requested (booking status offered); on a booking with status confirmed a change request is logged. | Immediate | No | transactional |
| `renter_comeback_1m` | 30 days after booking status becomes closed, only if the renter's marketing consent is true, they have not unsubscribed, no booking or request was created since that booking closed, the renter is not blocked and has no unpaid balance. A new single-use discount code is generated at send time. This is the last automated offer for that booking. | 30 days after the booking closes | No | marketing |
| `renter_comeback_1w` | 7 days after booking status becomes closed, only if the renter's marketing consent is true, they have not unsubscribed, no future booking or open request exists, the renter is not blocked and has no unpaid balance. A single-use discount code is generated for the renter at send time. | 7 days after the booking closes | No | marketing |
| `renter_damage_found` | An incident of type damage is recorded on a returned booking from the photo review after hand-back (damage not noted on the signed return report). Must be sent within 48 hours of check-in. (Message template T8.) | Immediate, within 48 hours of return | No | transactional |
| `renter_deposit_declined` | The security deposit attempt at pickup fails: a payment of kind hold (rental of 7 days or less) or charge (longer rental) for the booking deposit is declined while the booking is confirmed and the pickup job is in progress. Sent on each failed attempt. The car is not released. | Immediate | No | transactional |
| `renter_deposit_released` | A deposit amount that was held back after the final statement is released or applied (deposit released_at is set, or the hold-back is applied to a charge). Happens within 30 days of check-in. | Immediate | No | transactional |
| `renter_extension_approved` | Booking extension status changes from requested to approved (staff checked the calendar, unpaid charges and coverage to the new return date). Payment is still outstanding. | Immediate | No | transactional |
| `renter_extension_confirmed` | Booking extension status changes to confirmed (the extension payment succeeded before the return time and the booking return time was moved). This is the written confirmation. (Message template T11.) | Immediate | No | transactional |
| `renter_extension_declined` | Booking extension status changes from requested to declined. Staff choose the reason. | Immediate | No | transactional |
| `renter_extension_requested` | A booking extension row is created with status requested by the renter on an on_rent or confirmed booking. | Immediate | No | transactional |
| `renter_extra_charge` | A charge is billed to a renter after the final statement: a toll or ticket matched to the booking and charged, or a damage, fuel, cleaning, mileage, lost key or other line added by Finance with its supporting record. One email per charge event. The supporting document is required; the charge cannot be sent without it. (Message template T19 for tolls and tickets.) | Immediate, when the charge is taken | No | transactional |
| `renter_final_statement` | A renter statement for a returned booking is issued (statement sent_at is set by Finance), which captures charges from the deposit and releases the balance. Due within 7 business days of check-in. (Message template T9.) | When the statement is issued, within 7 business days of check-in | No | transactional |
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
| `renter_refund_issued` | A refund row reaches status succeeded at the processor, for any refund except one already reported by a cancellation email sent in the same hour. Covers refunds for unused time after a breakdown, corrections and a charged deposit returned. | Immediate | No | transactional |
| `renter_rental_started` | Booking status changes to on_rent (deposit taken, pickup condition report signed, keys handed over). | Immediate | No | transactional |
| `renter_request_declined` | Booking status changes from requested to declined. Staff choose a reason; it fills decline_reason. | Immediate | No | transactional |
| `renter_request_needs_info` | Staff send a "more information needed" message on a booking with status requested. This is an event, not a status: the booking stays requested. Staff must enter the question (info_request) and a reply-by time (reply_by). | Immediate | No | transactional |
| `renter_request_received` | A booking row is created with status requested (booking event requested; the renter submitted the request form). | Immediate | No | transactional |
| `renter_return_complete` | Booking status changes to returned (keys taken, return condition report signed). | Immediate | No | transactional |
| `renter_return_details` | The return field job of an on_rent booking has its place, time or assigned staff member changed after renter_return_reminder was sent, or is first assigned inside the last 24 hours before return. | Immediate, only inside the 24 hours before return | No | transactional |
| `renter_return_reminder` | Hourly reminders job: booking status is on_rent and the return time is 24 hours away. Sent once per return time, so it is sent again after an extension moves the return. (Message template T6.) | 24 hours before return | No | transactional |
| `renter_review_request` | 2 days after booking status becomes closed. Only if the renter has not unsubscribed and no review exists for it. A booking that had a problem (an incident, a dispute, an unpaid balance or a damage charge) is held for a staff decision (review_request_decision task): only a yes sends it, at once. Relies on the existing business relationship for consent, so it carries the unsubscribe link and mailing address. | 2 days after the booking closes | No | marketing |
| `renter_vehicle_disabled` | A tracker command of type engine disable for a booking is confirmed by the tracker (status confirmed), after admin approval. (Message template T15.) | Immediate | No | transactional |

### Owner (26)

| Code | Trigger | Timing | Digest | Category |
| --- | --- | --- | --- | --- |
| `owner_account_created` | A user with the owner role is created (owner sign-up, or created by staff from an application) and the email address is not yet verified. | Immediate | No | transactional |
| `owner_agreement_ready` | Vehicle onboarding status changes to documents_sent (a signature request for the owner documents is opened): the Enrollment Agreement and Title Agreement for a first vehicle, or an Additional Vehicle Schedule for a later one, with the forms that vehicle needs. | Immediate | No | transactional |
| `owner_agreement_signed` | Vehicle onboarding status changes to documents_signed (every owner document for the vehicle is signed by the owner and countersigned by CarmaCars, and witnessed forms are uploaded). | Immediate | No | transactional |
| `owner_application_declined` | Vehicle onboarding status changes to declined at any step before enrolled. Staff choose the reason. | Immediate | No | transactional |
| `owner_application_received` | An owner vehicle application is submitted (vehicle onboarding row created with status intake), for a first vehicle or an added vehicle. | Immediate | No | transactional |
| `owner_bank_details_changed` | An owner's payout account, pre-authorized debit authorization or card on file is added, changed or removed, by the owner or by staff. Sent to the owner's email address on file before the change, and never batched. Security notice. | Immediate | No | transactional |
| `owner_booking_confirmed` | A booking of type owner (an Owner Booking: the owner driving their own vehicle) changes to confirmed, after the owner signs the Owner Rental agreement and staff confirm the licence is valid. | Immediate | No | transactional |
| `owner_document_due` | Expiry-watch job (daily 06:00): a document or registration item on the owner's vehicle expires in 14 days: plate renewal, or for a Turo-Only vehicle the owner's insurance proof. Sent once at 14 days and again at 3 days if still open. (Message template T23 for Turo-Only insurance.) | 14 days before the expiry, again at 3 days | No | transactional |
| `owner_exit_completed` | Vehicle status changes from exit_notice to exited (Form E signed by both sides, tracker removed, registration returned). | Immediate | No | transactional |
| `owner_exit_notice_received` | Vehicle status changes to exit_notice (the owner's written notice naming the vehicle is logged, or an admin decides to remove it) and the Exit Date is set. This email confirms the Exit Date in writing. | Immediate | No | transactional |
| `owner_fee_change_notice` | An admin schedules a change to a vehicle's Insurance Fee or Tracker Fee (a fee history row with a future effective date), or proposes a new Revenue Share (a new Vehicle Schedule opened for signature). One email per vehicle. A fee change must be sent at least 30 days before its effective date. is_share_change is true when the Revenue Share changes, which needs the owner's signature. | Immediate, at least 30 days before the effective date | No | transactional |
| `owner_fee_invoice` | Owner-billing job on the 15th: a monthly owner invoice for a vehicle is issued and its pre-authorized debit is submitted. One invoice and one email per vehicle. Not sent for Turo-Only vehicles or vehicles owned personally by the two principals. (Message template T24.) | 15th of each month | No | transactional |
| `owner_in_arrears` | Debit-retry job on the 18th: the retry of a failed owner invoice also fails and the invoice status becomes in_arrears (the vehicle's arrears flag is set). | The day the bank reports the failed retry (18th or after) | No | transactional |
| `owner_incident_opened` | An incident (accident, theft, vandalism, or damage found at return) is opened on a vehicle that belongs to a third-party owner, or a claim is opened for it. (Message template T17.) | Immediate, the day the incident is opened | No | transactional |
| `owner_incident_update` | A claim on a third-party owner's vehicle changes status (submitted, accepted, in_repair, repaired, settling, closed), or staff post an incident event marked visible to the owner. | Immediate | No | transactional |
| `owner_new_booking` | A standard or non-refundable booking on the owner's vehicle changes to confirmed. Not sent for Owner Bookings or for Turo trips. is_self_managed is true when the vehicle's management mode is Self-Managed; only then are the renter's name and mobile number included. | Immediate | No | transactional |
| `owner_onboarding_steps` | Vehicle onboarding status changes to upfront_paid (or straight from documents_signed for a shareholder-owned vehicle). Lists the steps and documents for that vehicle's onboarding method. | Immediate | No | transactional |
| `owner_payment_failed` | Debit-results job (15th to 25th, daily): the debit for a monthly owner invoice is returned and the invoice status becomes failed, which adds the Late Fee to that vehicle. One email per vehicle. (Message template T25.) | The day the bank reports the failed debit | No | transactional |
| `owner_payment_received` | An owner invoice changes to paid: the debit for a monthly invoice clears (including a cleared retry), or the upfront invoice is paid by card or e-Transfer. | Immediate | No | transactional |
| `owner_payout_sent` | A payout row for an owner changes to paid (an admin sent the bank transfer and recorded its reference). Normally the 10th. Not sent when the statement shows a balance owing instead of a payout. (Message template T26, payment part.) | 10th of each month, when the transfer is sent | No | transactional |
| `owner_registry_visit` | Vehicle onboarding status changes to registry_booked (Fleet booked the registry visit), and again if the date, time or place changes. (Message template T21.) | Immediate | No | transactional |
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

### Staff: admin (12)

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
| `staff_monthly_statements_ready` | The company statement for a month is finalized (company statement status becomes final): the company statement and the owner statements for that month are drafted and need an admin's review before the owner statements are approved and issued. One email to each admin. | Immediate, when the company statement is finalized | No | transactional |
| `staff_payouts_due` | Payouts job on the 10th at 08:00: approved owner payouts are due to be sent by bank transfer that day. Also on the 15th at 08:00 for investor returns due on the Payment Date. One email to both admins and finance. If the run is not approved yet, the email says so. | 10th (owners) and 15th (investor returns), 08:00 | No | transactional |
| `staff_statements_ready_for_approval` | Statements-draft job on the 5th at 06:00: the draft owner statements for last month are built and an approval task is raised. One email to both admins. A reminder is sent on the 8th at 09:00 if the run is still not approved. | 5th of each month, reminder on the 8th | No | transactional |
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

### Staff: VA fleet (7)

| Code | Trigger | Timing | Digest | Category |
| --- | --- | --- | --- | --- |
| `staff_breakdown_reported` | An incident row of type breakdown is created (a call to the 24-hour line is logged, or the renter reports it in the portal). Sent to the on-call Fleet person. Immediate. | Immediate | No | transactional |
| `staff_digest_eod_va_fleet` | Scheduled digest for Fleet. Sent every day at 18:15 Toronto time (after the 18:00 reconcile job) to each active staff member with this role. Skipped when there is nothing to report. It carries every notice queued for this role with digest true since the last digest, plus these lists computed at send time: the closing checks of procedure 19: handovers and returns without a signed condition report or full photo set, returns with no findings sent to Finance, calendar statuses that do not match, tomorrow's cars not cleaned, incidents updated, the handover note for the on-call person. Each line links to the item. One email replaces the separate notices. | Daily 18:15 | No | transactional |
| `staff_digest_morning_va_fleet` | Scheduled digest for Fleet. Sent every day at 07:30 Toronto time to each active staff member with this role, even when nothing is waiting, so a missing digest is itself a warning sign. It carries every notice queued for this role with digest true since the last digest, plus these lists computed at send time: the opening checks of procedure 19: trackers not reporting, overnight movement or tamper alerts, today's handovers and returns with their field person and acknowledgement, tomorrow's pickups not ready, late returns, the expiry watch, listings to review, cars due for cleaning. Each line links to the item. One email replaces the separate notices. | Daily 07:30 | No | transactional |
| `staff_exit_notice_received` | Vehicle status changes to exit_notice. Queued for the next Fleet, finance and admin digests. Sent immediately to the admins instead when the fleet count after the exit would be below 10. | Next digest. Immediate to admins if the fleet would fall below 10 | Yes | transactional |
| `staff_expiry_watch` | Expiry-watch job (daily 06:00) finds at least one item inside its window: plate renewal within 30 days, an insurance document within 14 days, a safety certificate inside its 36-day window with no registry visit booked, or arrears older than 30 days. The list is included in the Fleet morning digest; sent as its own email to Fleet and admins only when an item expires within 3 days. | Morning digest. Own email when an item is within 3 days | Yes | transactional |
| `staff_late_return_alert` | Late-returns job (every 5 minutes): an on_rent booking passes its return time with no paid extension. Sent to Fleet at 0 minutes and at 30 minutes, and to Fleet and both admins at 2 hours. Immediate. The stage fills late_stage. | At 0 and 30 minutes late (Fleet); at 2 hours (Fleet and admins) | No | transactional |
| `staff_listing_ready_for_review` | The AI drafting step finishes for a vehicle listing (photos processed, description and details drafted) and the vehicle status becomes ready_to_list. Queued for the next Fleet digest. Nothing is published until a person approves. | Next digest | Yes | transactional |

### Staff: VA customer service (9)

| Code | Trigger | Timing | Digest | Category |
| --- | --- | --- | --- | --- |
| `staff_booking_request_new` | A booking row is created with status requested (booking event requested). Sent to every active customer service VA. Immediate, never batched. | Immediate | No | transactional |
| `staff_change_request_received` | A booking change request row is created by a renter. Queued for the next customer service digest. Sent immediately instead when the pickup is less than 48 hours away or the booking is on_rent. | Next digest. Immediate if pickup is within 48 hours or the car is on rent | Yes | transactional |
| `staff_digest_eod_va_cs` | Scheduled digest for Customer service. Sent every day at 18:15 Toronto time (after the 18:00 reconcile job) to each active staff member with this role. Skipped when there is nothing to report. It carries every notice queued for this role with digest true since the last digest, plus these lists computed at send time: requests still unanswered, offers sent today and still open, documents still to review, change requests open, tomorrow's pickups and their verification status, reviews received today. Each line links to the item. One email replaces the separate notices. | Daily 18:15 | No | transactional |
| `staff_digest_morning_va_cs` | Scheduled digest for Customer service. Sent every day at 07:30 Toronto time to each active staff member with this role, even when nothing is waiting, so a missing digest is itself a warning sign. It carries every notice queued for this role with digest true since the last digest, plus these lists computed at send time: requests waiting for an offer, requests waiting on the renter, offers open and when each expires, identity and coverage documents to review, change requests, tomorrow's pickups with verification incomplete, reviews to moderate, bookings confirmed since the last digest. Each line links to the item. One email replaces the separate notices. | Daily 07:30 | No | transactional |
| `staff_extension_requested` | A booking extension row is created with status requested. Immediate, because an extension must be confirmed in writing and paid before the current return time. | Immediate | No | transactional |
| `staff_identity_review` | A renter or additional driver uploads identity documents (licence front, back and selfie) or coverage proof, creating a verification in status pending review. Queued for the next customer service digest. Sent immediately instead when the booking's pickup is less than 48 hours away. | Next digest. Immediate if pickup is within 48 hours | Yes | transactional |
| `staff_offer_approved_paid` | Booking status changes from pending_payment to confirmed (offer approved, agreement signed, total paid). Queued for the next digest of customer service and fleet. Sent immediately instead when the pickup is less than 24 hours away. | Next digest. Immediate if pickup is within 24 hours | Yes | transactional |
| `staff_request_waiting` | Scheduled check every 5 minutes: a booking has had status requested for more than 2 hours since requested_at with no offer sent, no more-information message and no decline. Not raised for a booking that returned to requested from an expired or withdrawn offer. Sent once per request, to customer service and both admins. Immediate. | 2 hours after an unanswered request | No | transactional |
| `staff_review_received` | A renter submits a review for a closed booking (review row created, status pending moderation). Queued for the next customer service digest. A rating of 2 stars or lower is sent immediately to customer service and both admins instead. | Next digest. Immediate for 2 stars or lower | Yes | transactional |

### Staff: VA sales (3)

| Code | Trigger | Timing | Digest | Category |
| --- | --- | --- | --- | --- |
| `staff_digest_eod_va_sales` | Scheduled digest for Sales. Sent every day at 18:15 Toronto time (after the 18:00 reconcile job) to each active staff member with this role. Skipped when there is nothing to report. It carries every notice queued for this role with digest true since the last digest, plus these lists computed at send time: applications received today and whether each was answered, documents signed today, upfront invoices paid today, applications with no contact for 3 days. Each line links to the item. One email replaces the separate notices. | Daily 18:15 | No | transactional |
| `staff_digest_morning_va_sales` | Scheduled digest for Sales. Sent every day at 07:30 Toronto time to each active staff member with this role, even when nothing is waiting, so a missing digest is itself a warning sign. It carries every notice queued for this role with digest true since the last digest, plus these lists computed at send time: owner applications not yet answered, owners with documents sent but not signed, upfront invoices unpaid, onboardings waiting on an owner document, registry visits in the next 7 days. Each line links to the item. One email replaces the separate notices. | Daily 07:30 | No | transactional |
| `staff_owner_application_received` | An owner vehicle application is submitted (vehicle onboarding row created with status intake), from a new owner or an enrolled owner adding a vehicle. Sent to every active sales VA. Immediate. | Immediate | No | transactional |

### Staff: field (4)

| Code | Trigger | Timing | Digest | Category |
| --- | --- | --- | --- | --- |
| `staff_field_job_assigned` | A field job (pickup handover, return, tracker install, detail or photo shoot) is assigned to a field staff member, or reassigned to a new one. Sent to the new assignee. Immediate. | Immediate | No | transactional |
| `staff_field_job_changed` | An assigned field job has its time, place or vehicle changed, or is cancelled or taken away from the assignee. Sent to the staff member who held the job. Immediate. | Immediate | No | transactional |
| `staff_field_jobs_today` | Scheduled digest for field staff: every day at 07:00 Toronto time, one email to each field staff member who has at least one job that day. Skipped for a person with no jobs. Lists the same jobs as the evening digest, with any changes made overnight. | Daily 07:00 | No | transactional |
| `staff_field_jobs_tomorrow` | Scheduled digest for field staff: every day at 18:00 Toronto time, one email to each field staff member who has at least one job assigned for the next day (pickup handovers, returns, tracker installs, details, photo shoots). Skipped for a person with no jobs. Jobs assigned or changed after it is sent go out at once with staff_field_job_assigned or staff_field_job_changed. | Daily 18:00 | No | transactional |
<!-- EMAIL TABLE END -->
