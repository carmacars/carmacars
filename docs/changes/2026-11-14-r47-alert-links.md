# Alerts open the right page (Release 47: 2904)

Migration `2904_r47_alert_links.sql`.

Clicking an alert (the bell, Alerts, a phone alert) often opened the wrong page. Each alert's address was written once for every person it went to, so an Admin got staff pages (and "no access"), staff got Admin pages (disputes, incidents, payouts), alerts from the alert rules sent staff to their home page, the toll alerts carried a ticket id no page reads, booking alerts opened the overview instead of the section they were about, and a link written with the other host (www.) opened the site's home page.

- `app.alert_path_for` maps the address to the same page in the viewer's own portal (only pages that exist), and adds the booking section the alert is about (Money, Car & handovers, Drivers & documents, Claims & extras, Messages & history).
- When the address is no page, only the home page, or a page the viewer's portal does not have, the alert opens its record: the booking, lead, car, owner, field job, toll or application it is about.
- The Alerts feed (`server_alert_feed`) and phone alerts (`push_from_notice`) both use it; renters', owners' and investors' notices are unchanged.
- Alerts from the alert rules that name only the Admin page now give staff the same page in the staff portal.
- Test: `supabase/tests/99_r47_alert_links.sql` (each family, for an Admin and for staff).

## Guides

No guide change: alerts open where the guides already say they do.
