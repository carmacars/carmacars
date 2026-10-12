# 0028: what the renter portal needs

Migration `supabase/migrations/0028_renter_portal.sql`, tests `supabase/tests/15_renter_portal.sql`. Written with the renter portal of the web app (`web/src/app/account`). No table, policy or existing function changes.

## Added

| Object | Who may call it | Why |
| --- | --- | --- |
| `public.my_bookings()`, `my_booking(number)`, `my_profile()`, `my_documents()`, `my_document(id)` | authenticated, service_role | Security invoker: every row passes row-level security (`renter_bookings`, offers, lines, payments, drivers, agreements and signers, questions, uploads, documents, changes, extensions, cancellation, refunds, statements). `my_document` returns the storage key only when the caller may read the `documents` row; the server then signs a short link |
| `app.my_request_snapshot(booking)` | authenticated (through `my_booking`), service_role | Definer, after `app.is_my_booking()`: the request as sent (`bookings.request_details` is not readable by renters), for the offer's "what changed" list |
| `public.my_notifications`, `mark_notifications_read`, `my_notification_preferences`, `set_notification_preference` | authenticated, service_role | Wrappers for 0018's functions (the `app` schema is not exposed) |
| `public.server_agreement_facts(booking, by)` | service_role | Everything the agreement prints, including plate and VIN; renter of the booking or staff |
| `public.server_signing_record(booking)` | service_role | Signature records for the signed copy |
| `public.renter_open_agreement`, `renter_sign_agreement` | service_role | `app.open_rental_agreement` and `app.record_signature`, after checking that `p_by` is the renter (record_signature itself does not check who calls) |
| `public.driver_signing(signer)`, `driver_sign_agreement(signer, ...)` | service_role | An additional driver's signing link (the server signs the signer id; 72 hours) |
| `public.server_booking_payment_facts`, `server_record_booking_payment`, `server_booking_payment_capture_failed`, `server_complete_signature_request`, `server_webhook_event_claim`, `server_webhook_event_finish` | service_role | Payment settlement and the Stripe webhook |
| `public.server_extension_payment_facts`, `server_confirm_extension_payment` | service_role | Paying an approved extension with the Card on File |
| `public.renter_register_upload` | service_role | `app.register_verification_upload` after the renter check, limited to 60 uploads an hour per user (`app.rate_limit`, 13-security.md section 6) |
| `public.renter_save_details(by, details, booking)` | service_role | Part A of signing and the profile: address, mobile (E.164), licence number (Ontario format), issuer, expiry (valid to the return date); copied to the booking's driver row before pickup. Never the legal name |
| `public.renter_set_marketing(by, opt_in, text, version, ip, ua)` | service_role | Marketing emails on or off; a `consents` row with the words shown when turned on |

## Test assertion changed

| File | Assertion | Was | Now | Why |
| --- | --- | --- | --- | --- |
| `08_booking_app.sql` | "S a signed-in session may also call the five read-only previews ..." | the five previews | the five previews plus `my_booking`, `my_bookings`, `my_document`, `my_documents`, `my_notification_preferences`, `my_notifications`, `my_profile` | The new reads are open to signed-in sessions by design; all are read-only and invoker (row-level security). Still no wrapper that changes anything is open to them |

## Not done

- `payments (status = 'pending')` is not inserted when the PaymentIntent is created (02 section 6): `app.record_booking_payment` writes the payment when the card is authorized; no function inserts the pending row.
- "Resend link" for additional drivers (limit 3 a day) and `requestOfferRenewal`: the renter copies the driver's link from the booking page; the email is sent by `open_rental_agreement`.
