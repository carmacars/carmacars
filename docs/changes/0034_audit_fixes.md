# 0034: what the handover audit fixed in the database

Migration `supabase/migrations/0034_audit_fixes.sql`, tests `supabase/tests/21_audit_fixes.sql`. The audit itself is
`docs/audit/2026-10-13-audit.md`.

## What was added or changed

| Part | Why | Built |
| --- | --- | --- |
| One-click unsubscribe | Every marketing email (come-back offers, review requests) linked to `/email/unsubscribe`, a page the website did not serve: the link answered 404, and the `List-Unsubscribe-Post` request mail apps send went nowhere | `public.server_unsubscribe_info(token)` and `public.server_unsubscribe(token)` (service role) over 0018's `app.unsubscribe_token_info` and `app.unsubscribe`. The link path is now `/unsubscribe` (`program_settings.notify_unsubscribe_path`); the website redirects the old path. The website serves `/unsubscribe` (opening it changes nothing; the button unsubscribes) and `POST /api/unsubscribe` (RFC 8058 one-click, which `send-outbox` now puts in the `List-Unsubscribe` header) |
| The renter's review | The review request email asked for a review but the renter portal had no way to leave one | `public.renter_review_state(booking, by)` and `public.renter_submit_review(booking, by, rating, title, body, publish_consent)` (service role) over 0016's `app.submit_review` (closed bookings, one per booking, pending until staff publish it); the consent to publish fills `reviews.publish_consent_at`. Page `/account/bookings/[number]/review`, linked from a closed booking |
| Disable approval without a booking | A disable asked for on suspected theft has no booking: the booking number and renter were left empty, the email could not be rendered and the admins were never told | `app.notification_payload` fills them with "No booking" and "No renter" (or reads them from the booking when the event lacks them) |
| Renter portal documents | `public.my_documents` listed every document row-level security allowed, so a staff member opening `/account/documents` saw the whole company's files there, licence images included | It lists the caller's own renter and booking documents; staff screens are unchanged |
| Digest lines | Staff digests showed raw codes ("Claim_Open") and "Due not set" | `app.ntf_item` turns underscores into spaces and a missing date into "No due date" |

## Tests

`21_audit_fixes.sql`: the unsubscribe page data, the click (twice), an unknown token, the suppression, the waiting
marketing email suppressed, the account's marketing consent withdrawn, the anonymous role refused; the review state
before and after closing, another renter refused, the rating range, the consent recorded, one review per booking,
nothing public before staff publish, the authenticated role refused; the disable approval email without a booking
has every variable; the renter portal lists only the caller's documents and an Admin's lists none; digest lines.

## Not done

- Review moderation (`/admin/reviews`) shows the consent as "May publish"; publishing a review without it is not blocked in the database (0016's tests publish reviews written before the consent existed).
- The marketing senders still do not refuse to send while the mailing address is empty (0025 item 8): the address is
  the owner's to give (`prototype/UNCONFIRMED.md` item 1).
