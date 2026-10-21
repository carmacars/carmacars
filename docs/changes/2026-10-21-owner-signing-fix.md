# Owner signing that never crashes; the first and last month invoice only by choice (October 21, 2026; migration 0077)

Migration `supabase/migrations/0077_owner_signing_light.sql`, tests `supabase/tests/54_owner_signing_light.sql`,
`web/src/server/signing/content.test.ts`, end to end `web/tests/e2e/owner-signing.spec.ts` (3 tests, 375 and 1440). No
earlier migration was edited; the functions it changes are wrapped (renamed with the suffix `_pre0077`) or replaced with
the same signature.

## 1. What happened

An owner pressed "Check and sign" on /owner. /owner/sign rendered every document to PDF in the Worker on every page
load (`openOwnerPacket`: the Vehicle Enrollment Agreement and the Title-Holding and Lease Agreement, then Forms A and B
and the partner agreement, one after another), stored them, then opened them in the database. The two PDFs were
stored at 17:01:23 UTC, but `owner_open_agreements` never ran: the Worker was stopped after the uploads
("exceededResources", the CPU or 128 MB memory limit; 238 such requests in 24 hours, CPU around 2,000 ms). The page
then failed. Rendering is the heaviest thing the site does (about 0.9 to 1.0 s of CPU for the two agreements in Node,
more in a cold Worker isolate), and it ran on a page view, all in one request, every time. Signing had the same shape:
the signed copies were rendered inside the Sign request.

## 2. The fix

| Part | Before | Now |
| --- | --- | --- |
| Sign page | Rendered, stored and opened every PDF on each view | Shows every document from its text at once; never makes a PDF. Each document gets a content key (SHA-256 of its text blocks, title, footer, fixed date and the renderer's version), kept on its `documents` row; one database call finds the open request with the same key |
| Opening | All documents in the page's request | Only a document not open yet, one per request: the browser posts `/api/sign/prepare` for it (its own Worker invocation, one PDF at most), which renders it exactly as before, stores it, opens it with the same database function and records the content key. Idempotent: the same content answers at once |
| Signed document integrity | The SHA-256 of the unsigned PDF | Unchanged: the same blocks, the same renderer, the same bytes, the same SHA-256 recorded on the signature records, the same signature requests and records. Checked: the Title-Holding and Lease Agreement re-rendered from the owner's facts gives the SHA-256 of the file stored at 17:01:23 (`4943fc28e39f8199...`) |
| Sign (submit) | Recorded the signatures, then rendered every signed copy in the same request | Records the signatures first (the legal act, as before), queues one job per signed copy (`pdf_jobs`), and shows the success screen at once. The jobs run in their own requests (`/api/jobs/pdf`, two renders at most each, started right after the response through the Worker's own service binding; the five-minute cron runs what is left), with retries after 1, 2, 5, 15 and 60 minutes, then a high-priority task for an Admin ("A signed copy could not be made"; the signature stays recorded) |
| The owner's "Signed" email | Sent when the car's documents were signed, linking to Documents | Waits for the signed copies (at most 15 minutes) and carries them as attachments |
| Errors | A server error crashed the page | The page catches and logs any error and shows "Your documents did not load" with Try again (and an error boundary as a last line); a failed preparation says "The documents are not ready yet ... nothing was signed" with Try again |

Why this design: the PDF must exist before signing, because the signature records keep the SHA-256 of the PDF opened.
Rendering it lazily or after signing would change what is recorded. A background job alone would make the owner wait for
a queue (the cron runs every five minutes). A separate request per document, started by the page while the owner reads,
keeps the existing records exactly, bounds each Worker request to one PDF, is idempotent and retries by itself, and the
owner sees the documents at once and the Sign button within a second or two.

### Request-path PDF rendering found, and what changed

| Where | When | Now |
| --- | --- | --- |
| /owner/sign: owner agreements and schedules, Forms A and B, partner agreement | Page load | Text only; prepared one per request |
| /owner/partner-agreement, /owner/documents/screen/a and b, /owner/documents/form-c/(car) | Page load | Text only; prepared one per request |
| Owner package Sign (agreements, Forms A and B, partner agreement), investor and staff packages, Form C, the other Owners' signing link, the older owner Sign action | Submit | Signed copies and signed records are jobs |
| Renter: Accept and sign a rental staff added; payment confirmed (the pay page and the Stripe webhook); a booking amendment signed or its payment retried | Submit | Signed copies are jobs |
| Renter: the agreement opened when an offer is accepted, or the first time a staff-added rental's sign page opens; an amendment opened on submit | Action or first page view (one document) | Unchanged (one smaller PDF per request) |
| Admin: investment and staff agreements prepared, partner agreement download, data sheets, witnessed forms, invoices and statements under /files | Admin action or download | Unchanged (rendered on demand; invoices and statements are stored once final) |

## 3. Measurements (local; the PDF code is the Worker's)

The renderer alone, in Node, with the owner's own facts (`process.cpuUsage`, heap growth; three runs each, cold):

| | Before (page renders both agreements) | After (page computes both content keys) |
| --- | --- | --- |
| CPU | 929 to 1,035 ms | 21 to 29 ms |
| Heap | 22 to 28 MB | 0.5 MB |
| One document in its own prepare request | n/a | Enrollment Agreement 809 to 903 ms, 19 to 22 MB; Title-Holding 593 to 641 ms, 17 MB |

Server CPU per request on the built site (`next start`, the server process's CPU time read from /proc around each
request; a fresh individual owner with one car, so three documents: the two agreements and Form A; two runs, warm):

| Request | After | Before (the same work, all in that request) |
| --- | --- | --- |
| GET /owner/sign, documents not open yet | 140 to 230 ms | Page plus three PDFs rendered and opened: about 0.5 to 1.4 s (the page plus the three prepare rows below; up to 0.9 s more on a cold start) |
| POST /api/sign/prepare, Enrollment Agreement | 230 to 320 ms (920 ms the first time after a start) | In the page request |
| POST /api/sign/prepare, Title-Holding and Lease Agreement | 130 to 150 ms | In the page request |
| POST /api/sign/prepare, Form A | 20 to 30 ms | In the page request |
| POST /api/sign/prepare, already open | 10 to 20 ms | Every page view rendered again |
| GET /owner/sign, documents open | 120 to 200 ms | Every page view rendered again |
| Sign (the server action) | 240 to 550 ms, the success page in 2.1 to 2.5 s (a heavily loaded test machine) | Plus the three signed copies (the job row below) in the same request |
| POST /api/jobs/pdf (two signed copies) | 470 to 840 ms, in its own request; all three copies attached 3 to 4.6 s after Sign | n/a |

End to end at 375 and 1440 (local, `owner-signing.spec.ts`): the documents readable 0.3 to 0.6 s after "Check and sign";
the Sign button ready 2.4 to 2.6 s after it for a fresh owner (three documents prepared), at once when they are open;
Sign to the success screen in 0.5 to 1.5 s.

## 4. The first and last month invoice: only by an Admin's choice

The owner, October 21, 2026: CarmaCars must never issue the "first and last month" owner invoice automatically.

| Item | Now |
| --- | --- |
| Signing | Never makes or issues an invoice (0077 wraps `owner_sign_agreements`; tested) |
| The choice | Each car carries the Admin's choice (`vehicle_onboardings.first_last_choice`): the amount (exact; default 2 x the Insurance Fee) and Send invoice now, Draft only, Already paid (method, date, reference) or No invoice |
| Where it is set | Approve (the "First and last month" choice now has No invoice), "Add a car for an owner" (0067's `staff_add_owner_car`), and the owner's Terms tab (each car: the choice, its invoice, or "not decided") |
| Defaults | Approve and "Add a car for an owner" start the first and last month choice on Draft only: nothing is sent unless the Admin picks Send invoice now |
| Wording on staff screens | "Management fee (Revenue Share, %)" on Approve, Add a car for an owner, the Terms tab and the owner page's terms form; the legal documents keep "Revenue Share" |
| No choice | Nothing is invoiced; a task "Decide the first and last month invoice for (car)" opens, and Admin > Today shows "First and last month invoices to decide" with the count and a link to the owner's Terms tab, until it is decided (Today also shows "Signed copies that could not be made") |
| No invoice | The car moves past "upfront paid" once signed (nothing to wait for) |
| The owner page's Issue | Now "Apply the choices made": it only makes the invoice a choice asks for (for example after that invoice was voided); a car without a choice gets the to-do |
| The invoice screens | The Admin's explicit Issue stays as it is |
| A car that already has the invoice | Its invoice is kept; the Terms tab says to change it on the invoice screen (void, then a corrected one) |
| Existing data | The migration changes and voids no invoice. Cars past intake with no first and last month invoice and no choice get the to-do. The issued first and last month invoices of three owners (no emails sent, no debits) stay as they are for the owner to decide |

## 5. Tests

| Suite | Result |
| --- | --- |
| Database, full (`scripts/test.sh`, rebased on main with 0072 and 0073) | 4,635 passed, 0 failed; new suite 54 (36 assertions): approve without a choice, the bulk path, the to-do, opening by content key (one per request, idempotent, other users see nothing), signing records the signature against the opened SHA-256 for a corporation and makes no invoice, the jobs (enqueue, claim, retry, already attached, failure task, the email held and released, attachments), each choice (send, draft, paid with its reference, none, from the Terms tab, after a void), privileges. Suites 11, 16 and 28 now choose the first and last month invoice before the owner page's Issue; 03 lists `pdf_jobs` with the work lists; 34 counts the two new Admin > Today items |
| Unit | `content.test.ts`: the content key is deterministic, changes with every input, carries the renderer version; prepare targets accept only known documents |
| End to end | `owner-signing.spec.ts` at 375 and 1440: an individual owner, a corporation owner whose car staff added (No invoice), an owner with custom terms (and a failed preparation with Try again). Updated: `owner.spec.ts`, `guides-manual.spec.ts`, `legal-admin-redesign.spec.ts`, `supply-rentals.spec.ts`, `debit.spec.ts`, `portal.spec.ts`, `ops.spec.ts` (they wait for the background copies, and choose the first and last month invoice) |

## 6. Deploy notes

Apply 0077, then deploy the Worker. The Worker's service binding to itself (`WORKER_SELF_REFERENCE`) already exists. Owners
who opened /owner/sign before the deploy have no content key on their documents: their first visit prepares them again,
which finds the same SHA-256 and keeps the request already open.
