# The connector approves owner cars and puts cars on the fleet lease (Release 50: 3730)

Migrations `3730_r50_connector_owner_cars.sql` and `3740_r50_connector_add_car.sql`. The coordinator (Nov 24): the Admin connector could not approve an owner's car or put a fleet supplier's car on the lease, so Abbas had to open the portal.

## What it does

- `approve_owner_car` {application, cars?} (admin:write, preview then confirm): approves the application through the door's `application_approve`, as Approve on `/admin/applications/<id>`. A fleet supplier's car goes on the fleet lease at the tier the supplier asked for, which makes the Fleet Supplier Lease Agreement and the ServiceOntario forms for e-signing (0710). Without `cars`, each car with the terms the page proposes (`application_approve_plan`); the preview shows the plan. The owner's set-up email is sent as the page sends it (`web/src/server/owner-setup-email.ts`, moved out of the owner-billing actions so no browser can call it).
- `fleet_lease_car_set` {vehicle (id or plate), tier, delivered_on?, reason?} (admin:write): the preview is `app.fleet_lease_car_set` in its preview mode (the monthly rate); the confirm runs it through the door and fills the car's forms.
- `add_car` {owner (id or email; the company fleet too), vin, year, make, model, trim, plate, odometer_km, colour, class, title_status, finance_party_name, tier, terms} (admin:write, preview then confirm): the VIN is decoded with the site's vPIC decoder first (recorded in `vin_decodes`), its check digit checked, a duplicate refused; the confirm runs the door's `staff_add_owner_car`, the path of Add a car for an owner (onboarding, photo jobs, default rates, every gate). A fleet supplier's car needs its tier and is approved on the lease; with terms it is approved at once, else its terms wait for an Admin.
- Admins only (`app.assert_admin`), the same checks as the pages; every call logged in `api_calls`; functions with `search_path = public, app, pg_temp`, server role only.

## Guides

No guide change: the Admin pages are unchanged; the connector lists its own tools.
