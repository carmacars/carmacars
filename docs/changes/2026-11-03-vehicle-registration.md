# A car's registration in Admin (0237)

The owner, Release 23: on a car (Cars, the car, Owner, documents, tracker), set or correct the VIN, year and body style;
the Ontario permit number and the plate sticker expiry with reminders; the car's documents, the ownership permit first.

- **Registration** card: the VIN (17 characters without I, O or Q, the check digit, refused when it is on another car;
  decoded again with vPIC, which fills the body style, trim and year left empty), the year, the body style, the Ontario
  permit number and the plate sticker (validation) expiry (`vehicles.permit_number`, `vehicles.sticker_expires_on`).
  Admins and fleet; each change is in the audit log.
- **Plate sticker:** a fleet task 30 days and again 7 days before it expires (`sticker_renewal`, from the daily expiry
  watch). A staff task only: no service record, nothing billed to the owner. Saving a new date closes it.
- **Documents:** upload the ownership permit, the safety certificate, the owner's insurance or another document (a photo
  or a PDF, private storage). The ownership permit clears "Ownership permit" on the owner's checklist and is kept on the
  car's registration record. The card lists the car's documents (open each from Admin).
- **Safety Standards Certificate:** uploaded as a document with its number, issue date and expiry (`vehicles.ssc_number`,
  `ssc_issued_on`, `ssc_expires_on`; also on the car's onboarding record). Not a service record and never billed. A fleet
  task 30 days and again 7 days before it expires (`ssc_renewal`); a new certificate with its dates closes it.
- **Add a car** takes the ownership permit and the Safety Standards Certificate (with its dates) under Documents
  (optional): they are uploaded to the car right after it is added.
- **A car added under the wrong owner** (`app.vehicle_move_owner`, Admins; Overview, Who supplies the car, **Move to
  another owner**): to another owner, or to CarmaCars when the owner is not known yet (a company car, with no owner
  schedule or terms). The car's unsigned owner application is withdrawn (status `withdrawn`, kept), its unsigned vehicle
  schedule withdrawn (`vehicle_schedules.withdrawn_at`, kept), its draft owner invoices deleted, and its onboarding
  forgets them; nobody is notified, so no owner notice and no "record first and last paid" task. Refused once a schedule
  is signed, an owner invoice issued or paid, or the car has revenue on a statement. Audited.
- Code: `web/src/features/vehicles/Registration.tsx`, `web/src/server/actions/vehicle-registration.ts`.
- Tests: `supabase/tests/99_release_23.sql` sections 11 and 14, `web/tests/e2e/release-23.spec.ts`.

## Guides

- `admin/fleet-and-listings`: A car's registration and documents; A car added under the wrong owner.
