# 0027: what the website needs

Migration `supabase/migrations/0027_web_app.sql`, tests `supabase/tests/14_web_app.sql`. Written with the first build of the Next.js app (`web/`), for the reads and server calls the public site makes that 0016 to 0026 did not provide.

## Added

| Object | Who may call it | Why |
| --- | --- | --- |
| `public.site_facts()` (wraps `app.public_site_facts()`) | anon, authenticated, service_role | The policy numbers and fee catalogue the pages print: minimum age, notice and turnaround, deposit tiers, kilometre choices, airports, the public fee defaults (amount, cap, percentage, grace), young driver bands, offer and verification hours, payout and billing days, receiving aliases. The weekly-rate threshold and the four cancellation tiers are read back from `calc_rental_charge` and `calc_refund_bps`, so a page can never disagree with the rule |
| `public.handover_places(vehicle)` | anon, authenticated, service_role | Whether a listed car may be handed over at its Owner's location (Self-Managed, or an Owner address set) and its neighbourhood. Never the address |
| `public.save_form_draft`, `public.load_form_draft`, `public.submit_form_draft` | service_role | Server wrappers for 0022's drafts: the `app` schema is not exposed through the API |
| `public.register_account(user, email, full_name, phone)` | service_role | Makes the `users` row (and the renter role) for a new sign-in account with the sign-in account's id (0001: `users.id` equals `auth.users.id`). An email already on record from an earlier request is not taken over: it returns `email_on_record` and staff link the two |
| `public.delivery_origin()` | service_role | The coordinates delivery distance is measured from, for the server's maps call (0025 section 10). Not public: CarmaCars is a service-area business |

Nothing else changes: no table, no policy, no existing function. Every new function is revoked from public, anon and authenticated, then granted as above; `app` functions are granted to service_role (08's check "the server may run every function in the app schema" holds).

## Tests (14_web_app.sql)

The facts match the settings and catalogue rows (age, notice, tiers, kilometres, bands, fees, the cancellation tiers of renter billing section 4, the weekly threshold of section 2), internal fee lines are absent, the payload holds neither the numbered company name nor "Canada Inc"; handover places for a managed car, a Self-Managed car and a car with an Owner address (without the address), and nothing for an unlisted car; the anonymous and signed-in roles cannot call the server wrappers; a visitor draft round trip with the licence number removed on write; account registration, idempotent, refusing to take over an email on record.

## Not done

- Linking a sign-in account to an earlier request made with the same email (staff do it by hand).
- Accident call hours and the owner reply time have no column in `program_settings`; the site reads them from the editable content block `policy.extra`.
