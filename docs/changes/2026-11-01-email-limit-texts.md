# When the email limit is hit, booking and pickup messages go by text (0212)

Production, October 30, 2026: the email provider's daily limit was used up and renters picking up cars did not get their
emails. Migration `supabase/migrations/0212_email_limit_texts.sql`. Code: `web/src/app/api/email-status/route.ts`,
`web/src/features/forms/AuthForms.tsx`, `web/src/features/signing/EsignFlow.tsx`, `web/src/app/admin/messages/page.tsx`,
`web/src/app/admin/settings/[section]/page.tsx`. Tests: `supabase/tests/99_email_limit_texts.sql`, `web/tests/e2e/release-21b.spec.ts`.

- An email held for the daily or monthly limit (ours, `app.outbox_claim`, or the provider's, `app.outbox_defer` from the
  send-outbox function) whose code is booking- or pickup-critical (`site_settings.email_limit_text_codes`: the confirmation
  and its reminder, the agreement and signing links, a rental added, the driver link, pickup details, the handover, the
  offer, the payment links, the signing codes) goes at once by text (`app.outbox_text`, trigger
  `notification_outbox_limit_text`) through the phone line (`phone_outbox`, kind booking, urgent, sent by the five-minute
  phone job through Quo). The text is the email's text template (or the generic one: its subject and page), the renter's
  portal links tagged with the email's `?m=` like the email's own links; a signing code is texted as the code. The number
  is the person's verified phone, else the mobile on the signing session or the renter record; never one that opted out.
  Once per email (`notification_outbox.limit_text_id`, `limit_texted_at`, the audit log); the email still goes when the
  limit lifts. The emails held when the migration runs are texted then.
- On by default: Admin > Settings > Site settings, **Email limit** (`email_limit_texts`, and the list of codes).
- While email is at the limit (`app.email_capped`: today's emails at the daily cap, the month's at the monthly cap, or
  emails held by the provider's limit) the sign-in page opens on the phone option with a note (`/api/email-status`,
  `public.server_email_capped`), and the signing code is offered by text first (`app.esign_view`: `default_channel`,
  `email_held`; the email choice says it is delayed).
- Admin > Email: **Text it instead** on a held or queued email (`admin_do` `outbox_text`, Admins only, once per email).
- The link in the text opens the person's page behind sign-in (as the email's does); sign-in by phone needs no email.

## Guides

- `admin/email-backups-and-site-health`: Text it instead, and the texts sent while the limit is reached.
