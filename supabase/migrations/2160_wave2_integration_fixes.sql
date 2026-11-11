-- Wave 2 integration fixes (2160): the join-path foreign keys the shift picker (1770) and breaks (1800) added get their indexes.
create index if not exists field_shift_plans_standing_idx on field_shift_plans (standing_id);
create index if not exists staff_breaks_clock_entry_idx on staff_breaks (clock_entry_id);
