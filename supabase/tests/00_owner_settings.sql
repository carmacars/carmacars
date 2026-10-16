-- 00: the owner's settings of migration 0052 (October 16, 2026), checked before any later suite changes the site
-- settings. The rest of the legal review is in 33_legal_review.sql.
select test.suite('00 owner settings');
select test.eq('settings: the mailing address, with its postal code, and the street address (no postal code given)',
  (select mailing_address || ' | ' || street_address from site_settings where singleton), '2967 Dundas St W, Unit 208B, Toronto, ON M6P 1Z2 | 1570 Midland Ave, Toronto, ON');
select test.eq('settings: the signing officer and the date of the standing authorization',
  (select coalesce(signing_officer_name, '-') || '/' || coalesce(signing_officer_title, '-') || '/' || (signing_officer_authorized_on is not null) from app.settings()),
  (select coalesce(signing_officer_name, '-') || '/' || coalesce(signing_officer_title, '-') || '/true' from app.settings()));
select test.eq('settings: the email footer address is the mailing address', app.ntf_contact() ->> 'company_address', '2967 Dundas St W, Unit 208B, Toronto, ON M6P 1Z2');

