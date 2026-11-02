-- 0490: the phone number box asks after 4 photos of a car, not 6 (the owner, November 2026). The setting
-- (program_settings.phone_gate_free_photos, Settings > Phone number box) keeps its range of 1 to 30; only the starting
-- value changes: every row now says 4, and a new row starts at 4. A car with 4 photos or fewer is never asked.
alter table program_settings alter column phone_gate_free_photos set default 4;
update program_settings set phone_gate_free_photos = 4;
comment on column program_settings.phone_gate_free_photos is 'Phone number box (0280, 4 from 0490): photos shown before the number is asked.';
