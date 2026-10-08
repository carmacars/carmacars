# 0026: reply-to alignment and email footer contact details

- `app.email_reply_to_for` now takes, in order: an admin's per-email override in `email_reply_to`, the desk named for that email in the email catalogue (contact@, bookings@, owners@, billing@, privacy@, investors@), the audience default, then contact@carmacars.ca. This supersedes the note in 0025 that the catalogue kept info@; info@ is no longer used anywhere.
- `app.ntf_contact` now supplies the footer values the refreshed catalogue needs: contact email, opening hours, reply promise, Instagram and TikTok links, and phone numbers shown as 647-575-3377 rather than the stored +16475753377 (`app.phone_display`).
- The embedded email catalogue in 0018 was regenerated from emails/catalogue.json (`node supabase/seed/0018_gen_catalogue.mjs --embed`).
- docs/source/website_terms_policies.md: the cancellation section now says the deposit is taken about 1 hour before pickup, matching the booking rules.
- Tests: two assertions added to 13_owner_answers.sql.
