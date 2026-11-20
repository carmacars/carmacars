-- 3323 (release 48, integration): indexes for the foreign keys of the r48-fe tables that 99_r35sec_security names as missing:
-- fee_evidence (document_id, added_by), booking_line_items (evidence_override_by), data_check_answers (check_key, by_user) and
-- terms_declines (version_id). A delete or update of the parent row would otherwise scan the child table. SCHEMA_MARKER 3323.
create index if not exists fee_evidence_document on fee_evidence (document_id) where document_id is not null;
create index if not exists fee_evidence_added_by on fee_evidence (added_by) where added_by is not null;
create index if not exists booking_line_items_evidence_override_by on booking_line_items (evidence_override_by) where evidence_override_by is not null;
create index if not exists data_check_answers_check on data_check_answers (check_key);
create index if not exists data_check_answers_by_user on data_check_answers (by_user) where by_user is not null;
create index if not exists terms_declines_version on terms_declines (version_id);
