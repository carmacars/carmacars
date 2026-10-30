# Add an investor (0210)

Release 21b, extra item. Migration `supabase/migrations/0210_investor_create.sql`. Code:
`web/src/features/admin/AddInvestor.tsx`, `web/src/app/admin/investors/page.tsx`. Tests: `supabase/tests/99_investor_create.sql`,
`web/tests/e2e/release-21b.spec.ts`.

- Admin > Investors had no way to make an investor record, and Invite (Investor on file) needs one. **Add an investor**: the
  legal name, Individual or Corporation (with the person who signs for it, `investors.signatory_name`), email, phone,
  address (with the address lookup), and optionally the amount committed (`committed_amount_cents`) and the yearly return
  offered (`offered_yearly_bps`, the investor offer's `deck_settings.deck_return_bps`, 30%, unless typed; the "i" says the
  agreement sets the one that applies).
- `admin_do` `investor_create` (`app.investor_create`): Admins only; one record per email; a corporation names its
  signatory; the record starts as a prospect.
- **Invite now** (on by default) then sends the invitation through the existing path (`inviteAccount`, role investor,
  `investor_id`), so the sign-in is linked to the new record: one step from nothing to an invited investor.

## Guides

- `admin/people-and-access`: Add an investor.
