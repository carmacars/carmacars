# Reviewed renter documents stay viewable to staff (Release 48: 3071)

Migration `3071_r48_reviewed_documents_view.sql`.

The licence images, the selfie and the pages of the proof of coverage (pink slip, OPCF 27 endorsement page) showed only
while waiting for review: once approved or rejected, nobody could look at them again before the 90-day removal.

- **View** beside every approved or rejected document and every page of the proof of coverage, in the renter documents
  pop-up (Admin, customer service, Sales on the booking and To do), on the staff review screen (`/staff/verify`) and in
  field staff's licence review. Each press asks for a link that lasts one minute (`web/src/server/actions/doc-view.ts`,
  `web/src/features/docs-view/DocView.tsx`); the view is written to the audit log (`document_view`, the document, booking,
  kind and status) and the data access log.
- Who may view is who may review: Admin and customer service every kind, Sales and field staff the licence front, back
  and selfie (`app.doc_view_can`). Owners never.
- After the 90-day removal the document is still listed, reading **Removed on** and the date, with nothing to open.
- The coverage pages are no longer all signed when the pop-up opens: each opens with its own View.
- Tests: `supabase/tests/99_r48_doc_view.sql` (who views, the logs, a refused view writes nothing, the purge),
  `web/tests/e2e/doc-view.spec.ts` (View on an approved licence, Removed on after the purge).

## Guides

- `admin/requests-offers-and-bookings`: View on a decided document and on each coverage page; Removed on after 90 days.
- `va/customer-service`: View a decided document or a page of the proof of coverage.
- `va/sales`: View an image already approved or rejected.
- `field/my-jobs`: View an image already approved or rejected.
