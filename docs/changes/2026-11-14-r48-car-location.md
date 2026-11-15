# Every staff member sees where the cars are; owners see their own (Release 48: 3041)

Migration `3041_r48_car_location.sql`.

The owner: all CarmaCars staff should see the location of the cars once the trackers are in, and car owners should see the location of their own vehicles.

- **Every staff role.** Fleet tracking was for Admins and fleet staff (field staff: the cars of their jobs). Customer service, Sales, Finance and field staff now read the whole map and every trip (`app.tracker_fleet`, `app.tracker_trip_path`), read only: a read outside Admin and Fleet carries no device serial or IMEI and no trackers waiting to be paired, and has no **Seen** buttons. Pairing, removing, the settings and the ingest key stay Admin's; marking alerts as seen stays Admin's and Fleet's (`app.tracker_alert_ack`). The map: Fleet's **Fleet map**, **Car map** on **Find a car** for the other office roles, **Map** for field staff, Fleet tracking for Admins.
- **Each car and booking page** shows **Where the car is** (`app.tracker_car`, by car or booking number): moving with its speed or parked, when it last reported, **Open on the map**, and a link to the car map; **No tracker yet** when the car has none (also on the map when no car reports).
- **Owners** (`app.owner_car_location`): a car's page in the owner portal shows **Where your car is** and its trips of the last 30 days (when, km, where each started and ended). The location only: no booking, renter or booking dates, so a booking hidden from the owner stays hidden. Another owner's car is refused. Row level security: the position history (`tracker_points`) is readable by every staff member and by the car's owner (`staff_read`, `owner_read`); owners still read no trips, devices or status rows.
- **Renters are told.** The privacy policy (section 2 and Who we share with) and the rental agreement (section 12.1 and consent 1; template `rental-v3-24e8c1a9c6`) say that CarmaCars staff and the car's owner see its location, the owner the location only. The lawyer's review is on the owner's setup list (`app.owner_steps`, `tracker_visibility`) until `legal.meta` carries `tracker_visibility_reviewed`.
- Tests: `supabase/tests/99_r48_car_location.sql` (every role, read only, Admin and Fleet only for alerts and trackers, one car, owner isolation, nothing of a booking, row level security, the lawyer's step); `99_tracker_dashboard.sql` and `99_consolidation.sql` follow the wider read; unit: `web/src/features/tracking/location.test.ts`.

## Guides

- `va/fleet`: every staff member sees the map (Car map on Find a car), Where the car is on car and booking pages, only Fleet marks alerts as seen.
- `admin/fleet-and-listings`: who sees the positions now, Where the car is, owners see their own cars.
- `owner/home-and-your-vehicles`: Where your car is and its trips, No tracker yet, the location only.
