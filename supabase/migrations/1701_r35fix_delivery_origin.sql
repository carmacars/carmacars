-- 1701_r35fix_delivery_origin.sql
-- Release 35, fix helper, task 2 (docs/changes/2026-11-11-r35fix-owner-decisions.md). The owner, November 11, 2026:
-- "Delivery distances are measured from 1570 Midland Ave, Scarborough (Toronto), ON": the delivery origin and the pickup
-- location (our lot).
-- 1403 measured every delivery from program_settings.company_latitude and company_longitude, filled for the mailing
-- address on file (2967 Dundas St W, an office unit). Those two settings are the lot's coordinates everywhere they are
-- read: the delivery fee (app.delivery_fee, 0025/1403), delivery to a point (2004), a return "at our place" (0970) and
-- staff clocking in "at the lot" (0881).
--   1. A Program setting for the origin's address, delivery_origin_address, next to its coordinates (company_latitude,
--      company_longitude, now described as the delivery origin). company_address stays the company's mailing address
--      (letterhead, official forms, email footers): it is not the place deliveries start from.
--   2. The origin: 1570 Midland Ave, Scarborough, ON at about 43.771, -79.269. APPROXIMATE (the Midland Ave and Ellesmere
--      Rd area), to be geocoded exactly once the address database is loaded: an Admin picks the address in Settings >
--      Delivery and the coordinates fill themselves.
-- The site's street address and the business address of the structured data, the contact page and the "Our location"
-- map link already read 1570 Midland Ave (0079, 0095): unchanged.
-- No applied migration is edited.

alter table program_settings add column if not exists delivery_origin_address text
  check (delivery_origin_address is null or length(btrim(delivery_origin_address)) between 5 and 200);
comment on column program_settings.delivery_origin_address is 'The delivery origin and pickup location (our lot) (1701): every delivery and pickup leg is measured from it (its coordinates: company_latitude, company_longitude). Not the mailing address (company_address).';
comment on column program_settings.company_latitude is 'The delivery origin''s latitude (the lot, delivery_origin_address) (0025, 1701): deliveries, a return at our place and clocking in at the lot are measured from it.';
comment on column program_settings.company_longitude is 'The delivery origin''s longitude (the lot, delivery_origin_address) (0025, 1701).';

-- the owner's origin, on the row in force (approximate coordinates; see above)
update program_settings
   set delivery_origin_address = '1570 Midland Ave, Scarborough, ON', company_latitude = 43.771, company_longitude = -79.269
 where id = (app.settings()).id;
