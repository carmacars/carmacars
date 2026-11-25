# Company documents, signed in Admin (Release 50: 5060, 5061, 5062)

The owner, November 25: "make sure the shareholder agreement is in the carmacars admin page". Then: the Shareholder
Agreement between the two shareholders is not signed yet, and both must be able to sign it in the Admin portal.

Nothing in Admin held the company's own corporate documents: the investor library (4300) is shown to investors and Owner
forms holds owners' Forms C and D. Branch `r50-docs`. Migrations `5060_r50_company_documents.sql` (tables, door, signing,
connector), `5061_r50_company_documents_notices.sql` (the two emails) and `5062_r50_company_documents_guides.sql` (the
guide). DB test `supabase/tests/99_r50_company_documents.sql`; unit tests `web/src/features/company-documents/model.test.ts`
and `web/src/features/api-access/tools.test.ts`; e2e `web/tests/e2e/r50-company-documents.spec.ts`.

## What it is

| Part | What it does |
| --- | --- |
| Admin > Company documents (`/admin/company-documents`, Settings menu) | The six kinds (shareholder agreement, articles of incorporation, franchise agreement, insurance policy, lease, other), each with its documents, the state of the latest version, **Open** (a link that works for 5 minutes), **New version**, **Archive** and the version history. **Add a document**: a PDF to keep (under 20 MB, checked from its first bytes) or a text to sign |
| Versions (`company_document_versions`) | Every version is kept, never overwritten. A PDF is stored privately in the documents bucket under `company-documents/<document>/`. A text to sign holds its Markdown body with fill-ins written as `{{name}}`, the fill-ins (`fields`) and its signers (`company_document_signers`, each an active Admin with the role printed in the signature block) |
| A text to sign (`/admin/company-documents/<id>`) | The fill-ins (until the first signature). Once every fill-in has a value the body is rendered as a PDF with the agreement renderer (`features/agreement`), stored in the agreements bucket, and one sign request per signer is opened on the platform's own signature (`sign_requests` doc type `company_document`, `signature_requests`, a `documents` row of kind `company_document`) |
| Signing | Only the listed signer, only an Admin: the document is read to the end in its box, **I have read it and had the chance to get legal advice** is ticked, then the usual signing steps (EsignFlow: the reading, the consents, the drawn or typed signature). `signature_records` keeps the name, role, time, method, IP address, device and the document's SHA-256. No second signature system |
| Frozen | After the first signature the body, the fill-ins and the signers cannot change (a trigger on the tables, and the functions refuse). A change is a new version: the open requests of the older one are voided and the signing starts again |
| The signed copy | When everyone has signed, the server renders the body, the fill-ins and each signature block (the drawn image or the typed name, the role, the date) with the signature record (time, method, IP address, device, SHA-256) and files it in the agreements bucket at `company-documents/<document>/<version>-signed.pdf` as the version's PDF. **Make the signed copy** on the page retries it if it failed |
| Notices (5061) | `admin_company_document_to_sign`: each signer, when a version is sent for signing (the bell and an email). `admin_company_document_signed`: each signer, pointing at the signed copy in Admin (`/admin/company-documents/file/<version>`: an Admin session, then a 5-minute link; no link in the email works without sign-in). CarmaCars branding, from hello@, never a text |
| Who | Admins only: row-level security `admin_all` and the audit trigger on the three tables; the VA read policy on `documents` leaves out the kind `company_document`; the door refuses every staff function, investor, owner and renter (the DB test proves both) |

## The text is never in the repository

The repository is public until after Release 50. The agreement's text is given at run time only, through the Admin page
or the connector, and stored in the database. The tests use dummy text.

## The connector

- `list_company_documents` (admin:read): every kind with each document's versions, state, signers and missing fill-ins;
  never the text or a file path.
- `company_document_upload` (admin:write, previewed then confirmed): `title`, `kind`, `notes`, and either `pdf_base64`
  (under 15 MB; the web layer checks and stores the bytes) or `body_md` with `signers` (emails, or `{email, role}`) and
  `fields` (placeholder to value). A title and kind already there add a version. The bytes and the body are never logged,
  only their fingerprint and length.
- `company_document_fields` (admin:write, previewed then confirmed): `document`, `fields`. When every fill-in has a value
  the text is rendered and sent to the signers.

## Guides

- `admin/settings`: a Company documents section (adding a PDF or a text to sign, the fill-ins, signing, the signed copy,
  frozen after the first signature, the connector tools).

## Tests

- `supabase/tests/99_r50_company_documents.sql` (fixtures `cdoc_`): versions kept, the kinds, archiving, a text to sign
  (missing fill-ins, sent, only the listed signer signs, the tick, frozen after the first signature, signed, the signed
  copy and both told, a new version voids the older requests), Admins only through the door and the tables (every staff
  function, field staff, an investor, an owner, a renter), the three connector tools, the table and function rules.
- `supabase/tests/07_notifications.sql`: the two emails and the link counted.
