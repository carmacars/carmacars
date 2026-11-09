# Release 35, part Y: renter records of one person merged by themselves (migrations 0955, 0969)

Branch `r35-y`. SCHEMA_MARKER 0969.

The owner, November 8 (item 11): when two renter records or accounts are the same person (the same verified phone, or the
same name, date of birth and phone), merge them automatically into the record with the most history; the person signs in
with ANY of their emails, or their phone number with a code. Weak matches stay a staff task. Audited and reversible by an
Admin; bookings, licences, cards, payments, documents and messages move; one short note to the renter. Run once for today's
duplicates.

## What changed

1. **One merge path.** `app.renter_merge` (Merge into this record, 0148) is now a wrapper (`renter_merge_do`) that records,
   in `renter_merges`, every row the 0148 merge moves (by its key), the account holder drivers it demotes, a reward account it
   removes (one a renter: the kept one stays, the points move), and both records and sign-ins as they were.
2. **Sign-in.** When both records had a sign-in, the other sign-in's email becomes an alias of the kept account
   (`user_email_aliases`), the other account points at it (`users.merged_into`), and a verified phone moves to the kept
   account when it has none. `public.server_sign_in_alias` (the server only) answers the kept account; the password sign-in
   tries the kept address with the password, then the other address with its own password and goes on to the kept account by
   a one-time link; the phone code sign-in does the same. Nothing tells a person whether an address has an account.
3. **Strong match** (`app.rm_strength`): the same verified phone on both records, or the same name, date of birth and phone.
   Never a phone on three records or more, a blocked record, a test address or a staff, owner or investor account. The kept
   record has more bookings, then more payments, then a confirmed sign-in, then is older (`app.rm_keep`). A name alone is
   weak and stays the usual task.
4. **When.** `app.renter_auto_merge` with the 15-minute job and once in the migration for today's duplicates (data-driven).
   A merge the database refuses becomes a staff task. The "check they are the same person" tasks of a merged pair close.
5. **Undo** (Admins, `renter_merge_undo`): every moved row back, both records and both sign-ins as they were, the aliases
   gone, both change histories say so. A later merge of the record is undone first.
6. **The note.** `renter_accounts_merged` (email, `emails/src/emails/renter_accounts_merged.mjs`): "Your CarmaCars accounts
   are now one", naming the emails they can sign in with. Nothing else is sent about a merge.
7. **The renter page** lists Merged records (automatic or by staff, what moved, the sign-in emails) with Undo for an Admin.

Tests: DB suite `99_r35y_leads_merge.sql` (strong and weak matches, the kept record, what moved, the alias sign-in for an
email in any case and for the merged account, the phone, the note, Undo, the staff path recorded). Catalogue edits: the
email catalogue gains one renter email (`emails/catalogue.json`, `emails/README.md`, the `account` link).

## Guides

Published by `supabase/seed/0969_gen_guides.mjs` into `0969_r35y_guides.sql`: `admin/people-and-access`.
