-- 0052_owner_settings.sql
-- The owner's settings of October 16, 2026 (docs/changes/2026-10-16-legal-review-admin-redesign.md). Only these fields:
--   site_settings.mailing_address  "2967 Dundas St W, Unit 208B, Toronto, ON M6P 1Z2" (one text field: the site settings keep
--                                  the address as one line, so there are no separate street, city or postal code fields)
--   site_settings.street_address   "1570 Midland Ave, Toronto, ON" (no postal code was given: none is added; it will change, so
--                                  nothing hard-codes it, every page reads the setting, and show_street_address is left as it is)
--   program_settings.signing_officer_name / _title   "Abbas Al-Mashita", "Director"
--   program_settings.signing_officer_authorized_on   new column: the date of the standing authorization, the day this
--                                  migration runs (Toronto), kept on a second run
-- The company's legal name stays the one in program_settings.company_legal_name. The record of this change is
-- docs/changes/2026-10-16-legal-review-admin-redesign.md. Idempotent: running it again changes
-- nothing. Marketing emails held while the mailing address was empty (0035) go out again under the rules that held
-- them: outbox_claim releases them on its next run, inside the marketing window and the daily cap.

alter table program_settings add column if not exists signing_officer_authorized_on date;
comment on column program_settings.signing_officer_authorized_on is
  'The date of the standing authorization under which the signing officer signs automatically for the company (0052). Printed in every automatic countersignature.';

update site_settings
   set mailing_address = '2967 Dundas St W, Unit 208B, Toronto, ON M6P 1Z2'
 where singleton and mailing_address is distinct from '2967 Dundas St W, Unit 208B, Toronto, ON M6P 1Z2';
update site_settings
   set street_address = '1570 Midland Ave, Toronto, ON'
 where singleton and street_address is distinct from '1570 Midland Ave, Toronto, ON';

-- The row in force today and any row dated after it (program settings are dated rows; app.settings() reads the newest
-- one in force). The authorization date is set once: a second run keeps the first date.
update program_settings p
   set signing_officer_name = 'Abbas Al-Mashita',
       signing_officer_title = 'Director',
       signing_officer_authorized_on = coalesce(p.signing_officer_authorized_on, (now() at time zone 'America/Toronto')::date)
 where p.effective_from >= coalesce((select max(x.effective_from) from program_settings x
                                      where x.effective_from <= (now() at time zone 'America/Toronto')::date), '-infinity'::date)
   and (p.signing_officer_name is distinct from 'Abbas Al-Mashita' or p.signing_officer_title is distinct from 'Director'
        or p.signing_officer_authorized_on is null);
