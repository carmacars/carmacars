# The connector approves owner cars and the fleet lease (Release 50: 3730)

Migration `3730_r50_connector_owner_cars.sql`. The coordinator (Nov 24): the Admin connector could not approve an owner's car or put a fleet supplier's car on the lease, so Abbas had to open the portal.

## What it does

- `approve_owner_car` {application, cars?} (admin:write, preview then confirm): approves the application through the door's `application_approve`, as Approve on `/admin/applications/<id>`. A fleet supplier's car goes on the fleet lease at the tier the supplier asked for, which makes the Fleet Supplier Lease Agreement and the ServiceOntario forms for e-signing (0710). Without `cars`, each car with the terms the page proposes (`application_approve_plan`); the preview shows the plan. The owner's set-up email is sent as the page sends it (`web/src/server/owner-setup-email.ts`, moved out of the owner-billing actions so no browser can call it).
- `fleet_lease_car_set` {vehicle (id or plate), tier, delivered_on?, reason?} (admin:write): the preview is `app.fleet_lease_car_set` in its preview mode (the monthly rate); the confirm runs it through the door and fills the car's forms.
- `owner_agreements` {owner (id or email)} (admin:read): the agreements checklist, the government forms with their status, the fleet lease, and the Admin link.
- Admins only (`app.assert_admin`), the same checks as the pages; every call logged in `api_calls`; functions with `search_path = public, app, pg_temp`, server role only.

## Guides

No guide change: the Admin pages are unchanged; the connector lists its own tools.
