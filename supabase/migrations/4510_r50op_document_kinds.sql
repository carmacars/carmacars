-- 4510 (release 50, owner pipeline; docs/changes/2026-11-24-r50-owner-pipeline.md): the document kinds the owner
-- pipeline's "Documents uploaded" and "New registration" stages ask for that the enum did not have yet. Alone in its
-- migration: a value added to an enum is usable only once the transaction that added it is committed (4511 uses them).
--   lien_payout_letter   the lender's payout letter of a financed car (Transfer method)
--   uvip                 the Used Vehicle Information Package, when the transfer needs one
--   new_registration     the new ownership permit in CarmaCars' name (Transfer) or with CarmaCars added (Co-Registrant)
--   corporate_documents  a corporation's articles or certificate and proof of signing authority (Lease method)
--   owner_id             the owner's (or signing officer's) driver's licence, for the registry visit (section 8.1)
-- SCHEMA_MARKER 4513.
alter type document_kind add value if not exists 'lien_payout_letter';
alter type document_kind add value if not exists 'uvip';
alter type document_kind add value if not exists 'new_registration';
alter type document_kind add value if not exists 'corporate_documents';
alter type document_kind add value if not exists 'owner_id';
