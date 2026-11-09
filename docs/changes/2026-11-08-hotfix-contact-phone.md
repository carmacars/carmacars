# Hotfix: a contact number from any country (0843)

Staff abroad could not finish their profile: the profile step needs a phone number and the only way to add one was a
texted code, which reaches Canadian (and, when allowed, US) mobile numbers only.

- Profile pages (staff, field, renter, owner): "Number outside Canada? Save it as your contact number". Any number with
  its country code is saved without a code (`app.account_set_contact_phone`, audited). It is not verified, so it never
  signs in; a verified number on file is never replaced this way.
- The staff profile step counts it, so new staff abroad can go on to the academy.

Checks: `supabase/tests/99_hotfix_contact_phone.sql`.

## Guides

No guide change: the profile page explains the field itself.
