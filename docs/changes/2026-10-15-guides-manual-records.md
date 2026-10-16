# User guides in every portal, payments recorded by hand, signatures on paper, signing in every portal, fewer Actions minutes, October 15, 2026

Migration `supabase/migrations/0044_guides_manual_records.sql`, tests `supabase/tests/28_guides_manual_records.sql` (129
assertions), end to end `web/tests/e2e/guides-manual.spec.ts`, unit tests `web/src/features/guides/markdown.test.ts`,
emails `emails/src/emails/owner_payment_recorded.mjs` and `owner_payment_reversed.mjs`. No earlier migration was edited;
the functions it changes are wrapped (`door`, `owner_invoice_view`, `notification_payload`, `my_roles`) or replaced with
the same signature (`record_owner_offline_payment`, `ntf_owner_invoices_after`, `investor_of`), as 0029 to 0043 did.

## 1. What was asked, and what there is now

| # | Asked | Now |
| --- | --- | --- |
| A1 | A "Guide" entry at the top of every portal; a dismissible first-visit banner, dismissal kept per person on the server | `Guide` in the frame of `/account`, `/owner`, `/admin`, `/va`, `/field` and `/investor`. "New here? Read the <Portal> guide" until the person opens the guide or presses "Not now"; both are kept in `guide_reads` (and a cookie on the device so the frame stops asking) |
| A2 | The guide page in the portal: chapters, numbered steps, screenshots, tips, quick reference, contents (sidebar on a desktop, collapsible on a phone), search within the guide, "Download PDF" | `/<portal>/guide` (Admins: `/admin/guide/<portal>` for any guide). Search hides the steps that do not match. Static HTML stored at publish, nothing rendered per view |
| A3 | Guides in the database, seeded from `docs/guides/src`; images as static assets or public storage; Admin > Settings > Guides editor | `guides`, `guide_sections` (draft and published), `guide_section_versions`, `guide_images`. Seeded from `docs/guides/content/*.json` (written by `docs/guides/src/export.py`). Screenshots served from `/guides/img/` (static assets, copied at build) or uploaded to the public bucket. Editor: Markdown with preview, history, reorder, hide, add, delete (never published only), screenshots, publish |
| A4 | PDF both ways: print stylesheet matching the PDFs, and a stored PDF regenerated from the database; committed PDFs as the fallback; "PDF updated <date>; the web guide has newer edits" | "Print or save as PDF" (print layout in `web/src/styles/guide.css`, the same cover, numbering and type as the PDFs). `web/scripts/guides-pdf.mjs` prints the published guide with Playwright and stores it (workflow `guides-pdf`); `--committed` uploads `docs/guides/pdf` where none is stored (the deploy runs it). The page says when the PDF is older than the published guide |
| A5 | Optional: the version each person last opened | Admin > Settings > Guides > a guide: who opened it, which version, when, how often, and who dismissed the banner |
| B1 | Record a manual payment on any owner invoice: e-Transfer, cheque, cash, bank transfer, other; partial; date; reference; proof; note | "Record payment" on the owner's page, Admin > Owner invoices, the checklist, and Finance's Payments page. Paid or partly paid; the scheduled debit is cancelled or reduced; the owner's invoice says "Paid by e-Transfer on <date>"; a receipt email; audited; Void with a reason (Admins) sends the owner a notice and the invoice owes the amount again |
| B2 | Renter charges (lower priority) | "Paid another way" beside a failed renter charge (it settles that charge and closes its task) and "Record a payment received another way" on the booking's Money tab (Admin, Finance) |
| B3 | Statements and reconciliation | The payment is a `payments` row like any other (owner statements and the company statement pick it up as before). Reconciliation lists the month's payments recorded by hand with totals by method |
| B4 | Paper signatures for every signable document; counts as signed everywhere; scan private in the person's documents; audited, voidable | `paper_signatures` and `app.record_paper_signature()` for the owner agreements and schedules, the debit agreement, Forms A to D, registry forms, the rental agreement and its amendments, investment agreements and staff agreements. The same effects as signing in the portal; a void undoes exactly what it changed |
| B5 | Portal signing for everyone: owners, renters, investors, staff | Owners: agreements (0029), Forms C and D (0040), registry forms (0042), and now Forms A and B on screen. Renters: the rental agreement and amendments (0019, 0040). Investors and staff: an Admin sends a PDF, they sign it in `/investor/sign`, `/va/sign` or `/field/sign` |
| B6 | Admin > Owners bulk view with paid and signed status and method, quick actions | Admin > Owners > "Paid and signed": every owner with open and done counts, the checklist and the two actions. The same checklist heads each owner's page |
| C | Fewer Actions minutes | Push: fast gates only; docs-only pushes skip; full suite only on Run workflow; superseded runs cancelled; caches; verify slim by default. Estimate in `docs/ci-minutes.md` (section 6) |

## 2. Guides

**Data.** `guides` (one row per portal: title, promise, sign-in address, where people land, version, published at and by),
`guide_sections` (kind `start`, `chapter` or `reference`, order, slug, the draft title, blurb and Markdown, hidden, and the
published copy with its HTML), `guide_section_versions` (every save and every publish), `guide_images`, `guide_pdfs` (one
current per portal: path, bytes, pages, source `committed`, `generated` or `uploaded`, the guide version it was printed
from), `guide_reads` (person, portal, first and last opened, last version, opens, banner dismissed).

**Who reads what.** `app.guide_access()`: renters the renter guide, owners the owner guide, VA staff the VA guide, field
staff the field guide, investors (including a prospect invited to sign) the investor guide, Admins every guide.

**Publishing.** The Admin's Publish renders every visible section with `web/src/features/guides/markdown.ts` (the same
renderer as the seed), and `app.guide_publish()` refuses unless each visible section has its HTML. The guide page reads
the stored HTML only: no Markdown rendered in the Worker per view (the admin guide renders in about 1.4 ms at publish).

**Screenshots.** The 119 cropped JPEGs the guides use are copied from `docs/guides/src/img` to `web/public/guides/img` by
`web/scripts/guide-assets.mjs` before every build and served as Cloudflare static assets (no Worker time). An Admin's
upload goes to the public bucket under `guides/<portal>/<sha>.<ext>` and is served from `/media/`; "Replace" rewrites every
draft that showed the old image.

**PDF.** `web/scripts/guides-pdf.mjs --base https://carmacars.ca` reads each published guide through
`/api/jobs/guide-content` (bearer token from `LINK_SIGNING_KEY`, like the listing worker), prints it in the print layout
with Chromium (footer with the guide and version, page numbers, the outline) and posts it to `/api/jobs/guide-pdf`, which
stores it in the private `documents` bucket under `guides/<portal>/` and records it. `--committed` uploads the six
October 2026 PDFs of `docs/guides/pdf` where no PDF is stored; a stored PDF is never replaced by the committed one.
`/guide-pdf/<portal>` serves the current PDF to the people of that portal.

**Content updates.** The guide sources (`docs/guides/src/guides/*.py`) now describe the new screens: Admin (Paid and signed,
Record payment, Record paper signature, Void, agreements to sign for investors and staff, the guide editor), Owner (Forms A
and B on screen, payments recorded by hand), VA (payments received another way, rental agreements signed on paper,
documents to sign), Field and Investor (documents to sign). `docs/guides/content/*.json` is exported from them. The
committed PDFs are the October 14 edition; run the `guides-pdf` workflow after the first deploy to print the current one.

## 3. Payments recorded by hand

`app.record_manual_payment(p_by, p)`:

- **Who.** Admins; Finance up to `staff_profiles.single_limit_cents` (above it: "needs an Admin").
- **Checks.** The method; a reference for e-Transfer, cheque and bank transfer; a note for "other"; the date not in the
  future and not more than 400 days back; the invoice owing (`issued`, `failed`, `in_arrears`, `partially_deducted`) and
  not processing a debit; the amount (empty: the balance).
- **Replay.** The same method and reference on the same invoice or booking returns the payment already recorded.
- **Owner invoice.** A succeeded `payments` row (method as chosen) through 0023's `owner_invoice_apply_payment`; paid in
  full: every scheduled debit attempt cancelled ("paid by e-Transfer on <date>") and `debit_on` cleared; in part: a
  scheduled attempt never debits more than the balance. Upfront invoices move onboarding on as a card payment does. The
  owner gets `owner_payment_recorded` (not 0023's `owner_payment_received`).
- **Renter booking.** A succeeded payment with a purpose; with `settles_payment` it settles that failed charge (no more
  retries, its task done).
- **Void** (`app.void_manual_payment`, Admins, a reason): the payment reversed; the invoice back to what it owed
  (`issued`, `failed` or `in_arrears`, with `paid_cents` reduced); an upfront invoice moves onboarding back; the owner gets
  `owner_payment_reversed` with the reason.
- **0029's `record_owner_offline_payment`** now records through `record_manual_payment` (existing offline payments are
  copied into `manual_payments`).

## 4. Signatures on paper

`app.record_paper_signature(p_by, p)`: the document type and whose it is, the signer, the date signed, witnesses (Form C
one, Form D two), a note and the scan (stored by the server under `paper/` in the private `agreements` bucket and filed as
the person's document). Admins record every type; customer service also records the rental agreement and amendments.

| Document | What it does |
| --- | --- |
| Owner program agreement with its schedules | The open agreements and every open schedule signed (method `paper`), CarmaCars countersigned automatically, onboarding moved on as after the portal signature |
| Pre-authorized debit agreement | Recorded as signed on paper (the automatic debit still needs the bank account set up in the portal or by the processor) |
| Form A, Form B | An approved form, method `paper` |
| Form C, Form D | An approved form with its witnesses, method `paper` |
| Registry form | The form `signed`, the scan its document |
| Rental agreement | The renter's signature recorded (the agreement opened first if the renter never opened it) |
| Booking amendment | The amendment signed and the change accepted (applied when nothing is owed) |
| Investment agreement | Signed by the investor, as in the portal; CarmaCars is bound once funds clear |
| Staff agreement | The scan is the agreement on file |

A void (Admins, a reason) undoes what that record changed (`paper_signatures.effect`).

## 5. Signing in the portals

- **Forms A and B** (owners): `/owner/documents/screen/a` and `/b`, filled from the owner's records (`app.owner_form_ab_facts`)
  and rendered as a PDF by the server; the owner signs by drawing or typing their legal name; CarmaCars countersigns
  automatically; the signed copy is filed and replaces the form's document.
- **Investment and staff agreements**: Admin > Investors > an investor, and Admin > Settings > Staff and roles > Staff
  agreements: "Send a PDF to sign". The person gets a portal notice, opens `/investor/sign`, `/va/sign` or `/field/sign`,
  reads the PDF and signs (investors also choose legal advice and initial Schedule C). The VA queue and the field job list
  say when a document is waiting. A new version withdraws the one before; an Admin can withdraw with a reason.
- A prospect investor invited to sign reaches the investor portal (`my_roles` and `investor_of` wrapped).
- Paper signatures show as signed in the same lists, with the scan; nothing is asked again unless a new version is sent.

## 6. Actions minutes

`.github/workflows/ci.yml`: push and pull request run one job (`fast`): database suite, text check, lint, types, unit
tests, generated types (about 7 minutes). Documentation-only pushes (`docs/**`, `**/*.md`, email previews) do not run. A
newer push cancels the older run. Run workflow with `deploy` runs `fast`, then `full` (Worker build, end to end at 375 and
1440 with axe, links, copy lint, crawl, SEO, emails with database values, optional Lighthouse), then the deploy;
`full` alone checks without deploying; `checks` off re-deploys a commit that already passed. npm, Playwright browsers and
the Next.js build cache are cached. `verify.yml` is slim by default (`full` adds the sign-ins and the SEO audit).
`backup.yml` is unchanged. Estimate: about 840 minutes for 40 pushes, 10 deploys, 10 verifies and 30 backups
(`docs/ci-minutes.md`).

## 7. Tests

- `supabase/tests/28_guides_manual_records.sql`: 129 assertions.
- Changed assertions in earlier suites:
  - `07_notifications.sql`: the catalogue count `142/3` becomes `144/4` (the two new emails and the in-portal notice
    `person_document_to_sign`); the completeness block gets a manual payment and the two new emails.
  - `16_owner_portal.sql`: 0029's offline payment is now audited as `record_manual_payment` (was `record_offline_payment`).
  - `web/tests/e2e/owner.spec.ts`: the offline payment uses the new form ("Record payment"); that invoice's receipt is
    `owner_payment_recorded`, so `owner_payment_received` counts 2 (the two paid online), not 3.
- `web/tests/e2e/guides-manual.spec.ts` (375 and 1440): the guide of every portal (link, banner, dismissal kept on the
  server, contents, search, PDF, axe, overflow, the version recorded); a partial e-Transfer and a cheque, the owner's
  "Paid by", the void and its notice, reconciliation; the debit agreement recorded on paper from the checklist and voided;
  Forms A and B on screen with the countersign, an investment agreement and a staff agreement signed in their portals.

## 8. Deploy

1. Run workflow `ci` with `deploy`: it applies 0044, seeds the guides from `docs/guides/content` (only where a guide has
   no sections), copies the screenshots into the build, deploys, then uploads the committed guide PDFs where none is stored.
2. Run workflow `guides-pdf` once: it prints the current published guides (with the new text) and stores them.
3. Check Admin > Settings > Guides (six guides, version 1, PDFs stored), and Admin > Owners > Paid and signed.
