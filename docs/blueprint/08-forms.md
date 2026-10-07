# 08. The form system

Owner: workstream E (`src/features/forms/`, `src/features/documents/`), with the visual components in `src/components/` (workstream A). Every form in the product is built with this system. The owner's requirement: form filling must be smooth and efficient, especially owner vehicle registration and the rental agreement, pre-filled and signed on a phone.

## 1. Goals, measured

| Goal | Measure (tested in `15-test-plan.md`) |
| --- | --- |
| Nothing is typed twice | An owner adding a second vehicle types only vehicle facts: at most 9 typed fields. A returning renter's request needs dates and one tap per step |
| Fast on a phone | Booking request in under 2 minutes from the car page with a new account; rental agreement read, consented and signed in under 3 minutes; owner intake for one vehicle in under 6 minutes including the permit photo |
| Never lose work | A draft survives closing the tab, a dead battery and switching from phone to laptop |
| Errors are caught where they are made | Validation on blur, in plain words, beside the field; the server repeats the same checks |
| Usable by everyone | WCAG 2.2 AA (section 11) |

## 2. One schema per form

| Piece | Rule |
| --- | --- |
| Location | `src/features/<feature>/forms/<form-id>.schema.ts`. Exports a Zod schema, the TypeScript type inferred from it, and a `meta` object: labels, help text, input kinds, autocomplete tokens, the stored column for each field, and the steps for a wizard |
| Shared use | The browser validates with the schema as the user types (React Hook Form with the Zod resolver). The server action parses the same schema again before any write. A field cannot exist in one place and not the other |
| Database agreement | Each schema has a test that inserts a valid sample through the action against a test database, so a schema that the database's constraints would reject fails in CI. Check constraints in the database remain the final guard |
| Shared field definitions | `src/features/forms/fields/`: `legalName`, `email`, `phoneE164`, `dateOfBirth(minAge)`, `addressCA`, `postalCodeCA`, `vin`, `plateON`, `ontarioLicenceNumber`, `moneyCents`, `dateTimeTO`, `hstNumber`, `institutionNumber`, `transitNumber`, `bankAccountNumber`. A form composes these; it does not redefine them |
| Money | Typed in dollars, converted once to integer cents by `moneyCents`; never floating arithmetic |
| Dates and times | Entered and shown in Toronto time (`dateTimeTO`), stored as `timestamptz`. A device in another zone sees "Toronto time" beside the field |
| Conditional fields | Expressed in the schema with discriminated unions (for example the owner type), so hidden fields are not validated and are not submitted |
| Server-only rules | Uniqueness, availability, eligibility by age and vehicle are checked by the database function and returned as `fieldErrors` in the action result, shown exactly like browser errors |
| Messages | One catalogue `src/features/forms/messages.ts`. Pattern: say what is wrong and how to fix it. "Enter the 17-character VIN. It is on the ownership permit and the driver's door frame." Never "Invalid input" |

## 3. Autosave, drafts and resume on another device

| Topic | Design |
| --- | --- |
| Local draft | Every change is written to `localStorage` under `draft:<form_code>:<entity_key>` within 300 ms. Works with no connection and before sign-in |
| Server draft | For a signed-in user, the draft is also saved to `form_drafts` **[new]** by the `saveDraft` action, debounced 2 seconds, and on every step change. Row: `id, user_id, form_code, entity_table, entity_id, step, data jsonb, schema_version, updated_at, device_label` with a unique key on `(user_id, form_code, entity_table, entity_id)` |
| Indicator | "Saved" with the time, or "Saving", or "Saved on this device only" when offline. Never a modal |
| Resume | Opening a form loads the newer of the local and server drafts. If the server draft was last saved on another device, a line says "Continuing from your phone, saved 14:02". The portal home shows "Continue" cards for open drafts |
| Visitors | A visitor's draft is local until they give an email at the last step of a public form. For the owner intake, giving an email at step 1 creates the account by link so the draft follows them to another device |
| Sensitive fields | Never stored in a draft: bank account number, licence number, card data (Stripe's frame holds it). The schema marks them `transient`; on resume the user re-enters them |
| Schema changes | A draft with an older `schema_version` is migrated by a small function per form or, failing that, loaded field by field with invalid values dropped and listed |
| Conflicts | Two devices editing: last write wins per field, with the other device shown "Updated on another device" and the new value |
| Clean-up | A draft is deleted on successful submit. Drafts untouched for 30 days are deleted by the `retention` job |
| Staff forms | Same mechanism; drafts are per staff member and per record |

## 4. Layout and input rules

| Rule | Detail |
| --- | --- |
| One column | Always on a phone; on a desktop, at most two related short fields side by side (city and postal code) |
| Wizards | Used when a form has more than about 8 fields or natural stages. One step per screen on a phone with a fixed "Continue" button; step names listed on the left on a desktop. Steps can be revisited; later steps are not locked unless they depend on earlier answers |
| Labels | Always visible above the field. No placeholder used as a label |
| Keyboards | `inputmode` and `autocomplete` set for every field: `email`, `tel`, `numeric` for odometer and amounts, `postal-code`, `given-name`, `family-name`, `street-address`, `bday`. The browser's autofill is never blocked |
| Choices | Up to 5 options: radio cards with the whole card tappable. More: a native select on a phone, a searchable list on a desktop |
| Dates | Date of birth: three selects (day, month, year). Booking dates: the availability calendar. Other dates: the native date input |
| Defaults | Every field that has a sensible default has one, listed in the route files |
| Optional fields | Marked "(optional)". Required fields are not marked with an asterisk alone |
| Progress | "Step 2 of 4" as text; a wizard's summary step lists every answer with an "Edit" link |
| Submit | The button names the result ("Send request", "Sign and continue to payment"). It is disabled only while submitting, and shows why if the form is incomplete when pressed |
| Double submit | Each submit carries an idempotency key; a second press returns the first result |

## 5. Lookups

| Lookup | Module (`src/integrations/`) | Behaviour | Fallback |
| --- | --- | --- | --- |
| Address | `address` | Type-ahead after 3 characters, restricted to Canada (Ontario first), filling line 1, city, province and postal code. Calls go from the browser to a server route that adds the key and rate-limits per session | "Enter address manually" is always visible. The form works with the lookup off. Provider: any pay-per-request Canadian address service behind the interface `suggest(query, session)` and `resolve(id)`; pricing must be confirmed before it is switched on (open question in `99-traceability.md`) |
| VIN decode | `vin` | On a complete, valid VIN (17 characters, no I, O or Q, correct check digit computed in the browser): returns year, make, model, trim, body, fuel, drive, transmission, doors, seats. Fields fill in and stay editable; changed values are flagged "edited" for the reviewer | Manual entry. Details and provider in `09-listing-pipeline.md` section 3 |
| VIN scan | browser | Camera reads the door-frame barcode or the permit's printed VIN: the browser's `BarcodeDetector` where available, otherwise a WebAssembly barcode reader loaded on demand; then the check digit is verified | Type it |
| Plate | database | A plate entered in a staff or field form looks up `vehicles` by `upper(plate)` to find a car already on record. There is no public service in Ontario that returns a VIN or owner from a plate, so a plate never decodes a new car; the VIN does | Enter the VIN |
| Referral or promo code | database | Checked on blur by a read-only function; shows the name of the code's effect, never the referrer's identity | |
| Renter by email | none | Public forms never reveal whether an email has an account beyond "we will send a sign-in link" | |
| Postal code to city | local table | Fills city and province for Canadian postal code prefixes when the address lookup is off | |

## 6. Documents and photos from a phone camera

Component `PhotoCapture` (single) and `DocumentCapture` (multi-page), used for the ownership permit, coverage proof, safety certificate, appraisal, signed paper forms, receipts and notices.

| Topic | Design |
| --- | --- |
| Capture | A button opens the camera in the page (`getUserMedia`) with a frame guide for the document shape; a second button chooses a file or photo. `capture` file inputs are the fallback where in-page camera access is denied |
| Multi-page | "Add page" builds one document; pages can be reordered and deleted before upload; the server joins them into one PDF |
| Quality checks in the browser | Minimum resolution, blur and glare detection, document edge detection with an automatic perspective crop the user can adjust. A warning, never a hard block |
| Formats | Accepts JPEG, PNG, HEIC (converted in the browser), WebP, PDF. Maximum 15 MB per file before compression |
| Compression | Images are resized to 2400 px on the long side and re-encoded in the browser, which also strips location metadata from customer uploads |
| Upload | Direct to R2 with a short-lived signed upload link issued by `createUpload` for a specific bucket, path, content type and maximum size (`13-security.md` section 7). Progress per file; automatic retry with backoff; resumable from the local queue after a reload |
| After upload | `confirmUpload` verifies the object (size, type by magic bytes), computes the SHA-256, and inserts the `documents` row with its kind, retention class and links |
| Reading fields from a document | Optional, through the `ocr` module (`extract(documentId, schemaName)`), used for toll notices (`10-tolls-tickets-damages.md` section 3.2) and offered for the ownership permit (VIN, plate, year, make). Extracted values are suggestions shown beside the image for the user to confirm; nothing extracted is saved without a person's confirmation |

## 7. Licence photo and selfie capture

Components `LicenceCapture` and `SelfieCapture`, used at `/account/bookings/[id]/verify` and at the handover.

| Topic | Design |
| --- | --- |
| Steps | Front of licence, back of licence, selfie holding the licence. One screen each with an outline to fill and an example image |
| Guidance | "Lay the licence on a dark surface. All four corners visible. No flash glare." The capture button enables when the outline is filled and the image is sharp enough; a manual capture is always possible |
| Selfie | Front camera, face oval guide, licence held beside the face. A live photo only: the file picker is not offered for the selfie on devices with a camera |
| Consent | Shown above the first screen: consent 2 was given at signing; this page repeats what is collected, why, who sees it (CarmaCars staff who verify, and our insurer where required) and that images are deleted 90 days after the rental ends |
| Storage | `identity` bucket, path `renters/{renter_id}/{verification_id}/{id_front|id_back|face}.jpg`; `documents (retention = 'id_face_90d')`; linked from `identity_verifications` |
| Access | The renter sees their own images. CS staff see them in the review window only. Field staff can upload but not view after upload. Every staff view is logged |
| Automatic check | Off at launch (`IDENTITY_PROVIDER=staff_review`). The `identity` module's second adapter can replace the staff review later without changing these screens |
| Accessibility | A renter who cannot use the camera flow can email the images; CS uploads them on their behalf from the verification screen (`uploaded_by` shows the staff member) |

## 8. Signature pad and signing

Component `SignaturePad` and flow `SignDocument`; server side in the `signing` module and the `render-document` Edge Function.

| Topic | Design |
| --- | --- |
| Pad | A canvas that fills the width of the phone in landscape or portrait, minimum 280 by 160 px, pointer events with pressure where available, smooth strokes. "Clear" and "Done". A signature with too few points is refused ("Please sign your name") |
| Typed alternative | "Type my name instead": the typed name must match the signer's legal name; shown in a script face; stored as `method = 'typed'` |
| Reuse within one sitting | When several documents are signed in sequence (owner onboarding), the signer may tick "Use this signature for the next document" on each one. Nothing is signed without an explicit tap per document |
| Initials | Each initialled confirmation is its own control with its own tap, stored with its own timestamp (`signature_records.initials` and the specific columns on `owner_agreements` and `owner_agreement_forms`) |
| Read before signing | The document is shown in full before the pad is enabled. The "Sign" button states what is being signed. Consent 3 for renters says they could read and save it first, so "Download PDF" is always available before signing |
| What is recorded | `signature_records`: `signer_role`, `signer_user_id`, `signer_name`, `signer_title`, `signer_email`, `signed_at` (server time), `method` (`drawn` or `typed`), `ip_address`, `user_agent`, `provider_signature` (the path of the signature image and stroke data in the `agreements` bucket), `initials` |
| Signer order | `signature_requests.status`: `sent`, `partially_signed`, `completed`. The order per document type is fixed in `src/features/documents/signers.ts` (for the rental agreement: renter, then CarmaCars; additional drivers accept separately) |
| The signed copy | When the last signer signs, `render-document` produces the final PDF: the document, each signature image at its place, and a last page "Signature record" listing each signer's name, role, time, method, IP address and device, the document's template version and the hash of the unsigned document. The file is stored in R2, its SHA-256 goes to `documents.sha256`, and `signature_requests.signed_document_id` points to it. The signed file is never modified; a correction is a new document |
| Countersignature | CarmaCars' signature on a rental agreement is applied automatically when payment succeeds, in the name of the staff member who sent the offer (their sending the offer is CarmaCars' acceptance). On owner documents an admin countersigns on screen. See the open question in `99-traceability.md` |
| Witnessed documents | Form C, Form D and the Shareholder Agreement are signed on paper with witnesses and uploaded. The system pre-fills them and stores the scan; it does not collect a witness's electronic signature |
| In-person signing | The Condition Report is signed by the renter on the field staff member's phone; the record stores the field staff member's device and notes `in_person = true` in the stroke data |
| Emails | Each signer receives the signed PDF by email as soon as it is complete |
| Voiding | A signature request can be voided with a reason before completion; after completion only a new document supersedes it |

## 9. Pre-filled PDFs: agreements and government forms

One mechanism serves CarmaCars' own documents and the ServiceOntario forms.

### 9.1 Template registry

`pdf_templates` **[new]**: `code, version, title, kind ('acroform' | 'overlay' | 'generated'), storage_path, sha256, field_map jsonb, page_count, is_current, effective_from, uploaded_by`. Managed at `/admin/settings/templates`.

| Kind | Used for | How it is filled |
| --- | --- | --- |
| `acroform` | A PDF that has real form fields: government forms published as fillable PDFs; CarmaCars agreements prepared once with named fields | `pdf-lib` sets each field by name from the map |
| `overlay` | A PDF with no usable fields, or a dynamic (XFA) form that libraries cannot fill. The print-only version of the government form is used as the background | Text is drawn at coordinates from the map (page, x, y, size, maximum width, alignment; tick boxes as an X at a coordinate) |
| `generated` | Documents whose length varies: statements, invoices, the signature record page, the Condition Report with photos | Drawn in code with a small layout helper (`src/features/documents/layout.ts`): header, tables with page breaks, totals |

### 9.2 Field map

Each entry maps one target in the PDF to one value in a typed context object.

```
{ "target": "VIN",                      "source": "vehicle.vin" }
{ "target": "RegistrantName",           "source": "registrant.legal_name", "transform": "upper" }
{ "target": {"page":1,"x":412,"y":655}, "source": "vehicle.year", "size": 10 }
{ "target": "PostalCode",               "source": "owner.postal_code", "transform": "postal" }
{ "target": "IsLease",                  "source": "method.is_lease", "type": "checkbox" }
{ "target": "LessorRIN",                "source": "owner.rin", "when": "method.is_lease" }
```

| Rule | Detail |
| --- | --- |
| Context | Built by one function per document family from the database, never from the browser: `buildRegistryContext(vehicleId)` returns `owner`, `corporation`, `vehicle`, `registrant` (CarmaCars' legal name, address, RIN from `program_settings`), `method`, `lender`, `today`. `buildRentalContext(bookingId)`, `buildOwnerAgreementContext(ownerId, vehicleId)` likewise |
| Transforms | A fixed list: `upper`, `date:<format>`, `postal`, `phone`, `money`, `split:<n>` (one character per box), `yesno`, `initials` |
| Situations | Each of the six situations in `04-owner.md` section 3 lists its form codes in `onboarding_method_info.government_forms`. `generateRegistryForms` renders each form's current template with the context, and prepends a cover page: what this form is for, where the owner signs, what to bring, and the estimate with "You pay these at the counter. Amounts may vary." |
| Left blank on purpose | Signatures, dates signed, and anything the registry clerk completes. Government forms are returned still fillable (not flattened) so the owner can correct a field; CarmaCars' own agreements are flattened |
| Missing data | A required source that is empty stops generation and names the wizard field to complete ("Add the owner's driver's licence number in step 1") |
| Storage | The output is stored in the `agreements` bucket, `documents (kind = 'registry_form')`, and logged in `government_form_fills` **[new]** with the data used |
| Verification | Each template version has a fixture and a stored reference rendering. A test renders the PDF, converts page 1 to an image and compares it with the reference, so a new version of a government form that moves its fields fails the test instead of misprinting |
| Form versions | An admin uploads a new official PDF as a new template version, then adjusts the map in a visual mapper (the PDF on the left, the list of sources on the right, click to place) and runs the fixture preview before setting it current |

### 9.3 The government forms

| Code | What is known | Template kind at launch |
| --- | --- | --- |
| SR-LV-006 | Application for Vehicle Registration, published by Ontario as a fillable PDF and a print-only version ([Ontario Central Forms Repository](https://forms.mgcs.gov.on.ca/dataset/sr-lv-006)) | `acroform` if the fields can be set by `pdf-lib`; otherwise `overlay` on the print-only version |
| SR-LV-012, ON00453, 013-0169, 013-1155 | Named in operating procedure 12 and `onboarding_method_info`. Their current official titles and files must be downloaded from the Ontario Central Forms Repository when the templates are loaded; this blueprint does not assume their layout | Decided per form when loaded. Budget half a day per form for the map and fixture |

If a government PDF cannot be obtained or mapped before launch, the fallback for that form is a "data sheet": a one-page PDF listing every value the owner must copy onto the form, in the form's own order. The wizard works the same either way.

### 9.4 CarmaCars documents

| Document | Template | Signed |
| --- | --- | --- |
| Rental Agreement (Parts 1 to 3, 5 when an owner rental, 6) | `generated` Part 1 plus fixed pages for Parts 2, 3, 5, 6 from the lawyer-approved text | On screen |
| Rental amendment | `generated`, one page | On screen |
| Condition Report (Part 4), pickup and return | `generated` with photo thumbnails | On screen, in person |
| Enrollment Agreement, Vehicle Schedule, Additional Vehicle Schedule | Fixed pages plus `generated` schedule | On screen |
| Title-Holding and Lease Agreement, Schedule 1, Forms A, B, E | Fixed pages plus `generated` schedule entries | On screen |
| Forms C and D | Fixed pages, pre-filled | On paper, witnessed, uploaded |
| Pre-authorized debit agreement | Fixed page, pre-filled | On screen |
| Investment Agreement and Schedules | Fixed pages; Schedule A `generated` | On screen or uploaded |
| VA and Field Staff Agreements | Fixed pages; Schedule A `generated` | On screen |
| Renter statement, receipt, owner invoice, owner statement, insurer invoice, investor statement, fleet report | `generated` | Not signed |

The legal text comes only from lawyer-approved templates loaded by an admin. The repository's `docs/source/` drafts are marked "not for signing" and are not used as templates.

## 10. Error handling

| Situation | Behaviour |
| --- | --- |
| Field invalid | Message under the field on blur; the field's border and an icon change (not colour alone); `aria-invalid` and `aria-describedby` set |
| Submit with errors | Focus moves to an error summary at the top that lists each problem as a link to its field |
| Server refuses | The action's `fieldErrors` are mapped onto fields; a general refusal shows in the summary with the database's message |
| Network failure on submit | The form stays; a banner offers "Try again"; the idempotency key makes the retry safe |
| Session expired | The draft is saved locally; the user signs in again in a dialog and the submit continues |
| Upload failed | The file row shows "Failed, retrying" then "Tap to retry"; other fields remain usable |
| Step data changed elsewhere | "This was updated on another device" with the new value |
| Unexpected error | "Something went wrong on our side. Your answers are saved." with the request id |

## 11. Accessibility

| Requirement | Implementation |
| --- | --- |
| Labels and names | Every input has a `<label>`; groups use `<fieldset>` and `<legend>`; buttons have text |
| Keyboard | Every control, including the calendar, the signature alternative (typed name), photo capture (file input) and the car damage diagram (a list alternative), works without a pointer |
| Focus | Visible 2 px red-on-white or white-on-black outline; focus is moved deliberately on step change and on errors |
| Errors | Announced with `role="alert"`; never by colour alone |
| Targets | 48 px minimum |
| Timing | The offer countdown is the only timer; it is announced, and expiry can be extended by asking staff. No form times out while being filled |
| Motion | No animated transitions between steps under reduced motion |
| Language | `lang="en-CA"`; plain words; reading level about grade 8 for customer forms |
| Signature | The typed-name method is the accessible equivalent of drawing |
| Zoom | Works at 200% zoom and 320 px width without horizontal scrolling |
| Tests | Automated axe checks on every form route plus a manual screen reader pass on the booking request, signing, payment and owner intake (`15-test-plan.md` section 5) |

## 12. Every form in the product

| ID | Form | Route | Kind | Specified in |
| --- | --- | --- | --- | --- |
| F01 | Date search | `/`, `/cars` | inline | `01` 4.1, 4.2 |
| F02 | Car page booking panel | `/cars/[slug]` | inline | `01` 4.3 |
| F03 | Booking request | `/book/[slug]` | wizard, 4 steps | `02` 3 |
| F04 | Contact | `/contact` | single | `01` 4.8 |
| F05 | Insurance replacement enquiry | `/insurance-replacement` | single | `01` 4.5 |
| F06 | Launch notice | `/` | inline | `01` 4.1 |
| F07 | Owner intake (owner, vehicle, situation) | `/list-your-car/apply`, `/owner/onboarding`, `/owner/vehicles/new` | wizard | `04` 3 |
| F08 | Sign in, sign up, reset, two-step | `/sign-in` and others | single | `13` 4 |
| F09 | Offer response (change request, decline) | `/account/bookings/[id]/offer` | sheet | `02` 4 |
| F10 | Renter details before signing | `/account/bookings/[id]/sign` | single | `02` 5 |
| F11 | Rental agreement consents and signature | same | sign | `02` 5 |
| F12 | Additional driver acceptance | `/account/driver/[id]` | single plus sign | `02` 5 |
| F13 | Payment | `/account/bookings/[id]/pay` | Stripe frame | `02` 6 |
| F14 | Verification: licence, selfie, coverage | `/account/bookings/[id]/verify` | capture | `02` 7.3 |
| F15 | Cancel booking | `/account/bookings/[id]/cancel` | confirm | `02` 7.4 |
| F16 | Extension request | `/account/bookings/[id]/extend` | single | `02` 7.5 |
| F17 | Renter photo set | `/account/bookings/[id]/photos` | capture | `02` 7.6 |
| F18 | Review | `/account/bookings/[id]/review` | single | `02` 7.7 |
| F19 | Renter message, charge question | `/account/...` | inline | `02` 7.2, 7.8 |
| F20 | Driver, card, profile, notification settings | `/account/*` | single | `02` 7.9 |
| F21 | Owner documents signing set | `/owner/onboarding/.../documents` | sign | `04` 3 step 5 |
| F22 | Owner payment set-up (upfront, debit, payout account) | `/owner/onboarding/.../payment` | mixed | `04` 3 step 6 |
| F23 | Registry visit prep (safety, appraisal, confirm time) | `/owner/onboarding/.../registry` | single | `04` 3 step 7 |
| F24 | Owner calendar block | `/owner/vehicles/[id]` | sheet | `04` 5 |
| F25 | Owner Booking; Self-Managed rental request | `/owner/bookings/new` | single | `04` 6 |
| F26 | Owner rate card (Self-Managed) | `/owner/vehicles/[id]` | single | `04` 6 |
| F27 | Owner incident report | `/owner/claims` | single | `04` 7 |
| F28 | Exit notice; buyout offer; Form E | `/owner/vehicles/[id]` | single, sign | `04` 9 |
| F29 | Owner profile, banking | `/owner/profile`, `/owner/banking` | single | `04` 7, 8 |
| F30 | Investor election change; bank change | `/investor/profile` | single | `07` 2 |
| F31 | Staff booking request (phone, email) | `/admin/bookings/new`, `/va/sales/quotes/new` | single | `03` 4, `05` 5 |
| F32 | Offer editor; decline; extend; withdraw | `/admin/bookings/[id]` | single | `03` 4.2 |
| F33 | Booking adjustment | same | single | `03` 4.5 |
| F34 | Cancel for renter, by CarmaCars, no-show | same | confirm | `03` 4.6 |
| F35 | Calendar block | `/admin/calendar` | sheet | `03` 6.2 |
| F36 | Insurer; insurer booking fields; insurer invoice; record payment | `/admin/insurers`, `/admin/insurer-invoices` | single | `03` 7 |
| F37 | Vehicle; rate card; fee override | `/admin/vehicles/[id]` | single | `03` 8 |
| F38 | Vehicle terms; onboarding staff steps; registration record | `/admin/onboarding` | single | `04` 3, 4 |
| F39 | Owner; deduction; bank change | `/admin/owners/[id]` | single | `03` 9 |
| F40 | Deposit actions; post-rental charges; statement | `/admin/money/*` | wizard | `03` 11 |
| F41 | Refund request; approvals | `/admin/money/refunds`, `/admin/approvals` | single | `03` 2, 11.4 |
| F42 | Toll or ticket single entry; import; match confirm | `/admin/tolls/*` | single, wizard | `10` |
| F43 | Incident; incident cost; claim ledger entry; total loss | `/admin/incidents`, `/admin/claims` | single | `10` 7, `03` 12 |
| F44 | Owner statement review; payout | `/admin/statements`, `/admin/payouts` | review | `11` |
| F45 | Investor register, agreement, investment, election, redemption | `/admin/investors/[id]` | single | `07` 4 |
| F46 | Staff invite, limits; settings (program, fees, holidays, templates, quick replies) | `/admin/staff`, `/admin/settings/*` | single | `03` 16 |
| F47 | Promo code; review moderation | `/admin/promo-codes`, `/admin/reviews` | single | `03` 14 |
| F48 | Tracker command request and approval | `/admin/tracker` | single | `03` 17 |
| F49 | Field job dispatch | `/va/fleet` | single | `05` 3.2 |
| F50 | Photo review and findings | `/va/fleet` | review | `05` 3.3 |
| F51 | Verification review (driver, coverage) | `/va/cs` | review | `05` 4.2 |
| F52 | Daily checks | `/va/fleet/checks` | checklist | `05` 3.5 |
| F53 | Turo trip | `/va/finance/turo` | single, import | `05` 2 |
| F54 | Handover checklist | `/field/jobs/[id]` | wizard, capture, sign | `06` 4 |
| F55 | Return checklist | same | wizard, capture, sign | `06` 5 |
| F56 | Detail, tracker install and removal, registry run, recovery | same | checklist | `06` 7 |
| F57 | Listing capture | `/field/list-a-car`, `/admin/vehicles/new`, `/owner/vehicles/new` | wizard, capture | `09` 4 |
| F58 | Listing review | `/admin/listings/[id]` | review | `09` 6 |
| F59 | Field report | `/field/report` | single | `06` 9 |
| F60 | Task notes, escalate, waiting | `/va/*` | sheet | `05` 1.2 |

## 13. Database additions needed

| Addition | Purpose |
| --- | --- |
| `form_drafts` (section 3) with policies: a user reads and writes their own rows only | Autosave and resume |
| `pdf_templates`, `government_form_fills` (section 9) | Template registry and audit of pre-fills |
| `program_settings`: `company_rin text`, `signing_officer_name text` | Registry forms name CarmaCars as registrant or lessee |
| `signature_requests.in_person boolean`, `signature_records.stroke_document_id uuid` (optional; `provider_signature` can hold the path) | Section 8 |
| `documents.page_count`, `documents.byte_size`, `documents.original_filename` | Upload verification and display |
