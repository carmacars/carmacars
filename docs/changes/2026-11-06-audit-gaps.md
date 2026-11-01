# Five gaps from the audit of November 6, 2026 (0321, 0322)

## 1. Invoices, receipts and statements: the legal name alone

- **Cause:** the PDF builder's "Company" row (web/src/features/documents/pdf.ts, the header of invoices and receipts and
  the company statement) printed "18122211 Canada Inc. (operating as CarmaCars)". The rule (an insurance requirement):
  legal documents and card charges name only "18122211 Canada Inc.".
- **Now:** both rows use `companyParty` (src/lib/format.ts), the legal name alone (the brand only when no legal name is
  set), as the agreements already do. A test fails if any document builder writes "operating as" again.
- **Left as it is, on purpose:** the pre-authorized debit agreement and the owner billing emails name the payee
  "18122211 Canada Inc., operating as CarmaCars" (the legal review, 0053, 0128: Payments Canada Rule H1 asks for the name
  the owner recognizes on the bank statement). They are bank debits, not card charges; change them only with the lawyer.

## 2. The vehicle photos' address at deploy

- `scripts/deploy/cloudflare.sh resources` always set `NEXT_PUBLIC_VEHICLE_PHOTOS_URL` to `/media` (or Supabase Storage).
  It now keeps the build variable when it is set (the repository variable `NEXT_PUBLIC_VEHICLE_PHOTOS_URL`, passed to that
  step in ci.yml), with `/media` as the default on R2, and the deploy's annotation says which was used and why.

## 3. Push alerts: where the VAPID keys go

- The docs and Admin > Alerts said "Supabase Project settings, Vault". The deploy reads them from the vault of the live
  database (`scripts/deploy/supabase.sh secrets`, the live backend's `vault.decrypted_secrets`), which since the move is
  the company server's database. The docs (docs/changes/2026-11-05-push-alerts.md), the hint on Admin > Alerts and the
  guide now say so, with the step: Studio through the server's SSH tunnel, SQL editor,
  `select vault.create_secret('<value>', 'deploy_vapid_public_key');` and the same for `deploy_vapid_private_key`.

## 4. Apple Wallet: the five secrets reach the Worker

- The deploy never passed `WALLET_PASS_CERT`, `WALLET_PASS_KEY`, `WALLET_WWDR_CERT`, `WALLET_PASS_TYPE_ID` and
  `WALLET_TEAM_ID` to the Worker. `supabase.sh secrets` now reads `deploy_wallet_pass_cert`, `deploy_wallet_pass_key`,
  `deploy_wallet_wwdr_cert`, `deploy_wallet_pass_type_id` and `deploy_wallet_team_id` from the same vault (each line of a
  certificate masked), and the Worker gets all five only when all five are there. The feature stays off and hidden until
  then; the deploy says how many of the five it found.

## 5. Every feature waiting on an owner step, in every deploy

- A production deploy now ends with one annotation, "owner steps (N waiting)", listing each feature that waits on the
  owner with the exact step (scripts/deploy/owner-steps.sh, the step "Waiting on an owner step" in ci.yml; the same list
  in the run's summary): the Cloudflare email binding (`CF_EMAIL_BINDING`), the VAPID keys, the Apple Wallet certificate,
  the Meta Page token, partner CRM links without their GoHighLevel token, and the RentalCoverage affiliate link. The
  database's part is `public.server_owner_steps()` (0321; service role only; names, never a value). Nothing waiting: a
  notice says so. It never fails a deploy.

## Tests

- Unit: `web/src/features/documents/pdf-company.test.ts` (no "operating as" in any document builder),
  `web/src/lib/deploy-scripts.test.ts` (the owner-step annotation, offline).
- DB: `supabase/tests/99_owner_todo_usage_noise.sql` section 8 (the owner steps: each with its step, never a value,
  service role only).

## Guides

- `admin/text-alerts-email-text-or-both`: the VAPID keys go in the vault of the live database, on the company's server.
