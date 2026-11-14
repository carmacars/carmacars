# The cars that rent least come first on the site (Release 47: 2891)

Migration `2891_r47_fleet_low_occupancy_first.sql`.

The website's fleet ("Featured" on /cars and the lists that read the same order) now puts first the cars with the lowest occupancy, and a partner's sheet fleet (01 Motors) after our own cars.

- Order: a pinned car, real cars before sample cars (both as before), our own cars before a partner set to show after them (`partners.site_priority = 'low'`, set once for 01 Motors), the lowest occupancy first, then the trending score as before.
- Occupancy: the share of the last 30 and the next 30 days covered by the car's confirmed, on-rent, returned or closed bookings that its owner can see. A booking hidden from the owner (an insurer replacement) is not counted.
- `program_settings.fleet_low_occupancy_first` (on by default) switches the occupancy step off.
- Test: `supabase/tests/99_r47_fleet_occupancy.sql`.

## Guides

No guide change: the guides do not describe the order of the cars on the site.
