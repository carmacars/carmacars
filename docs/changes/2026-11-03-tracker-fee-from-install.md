# The Tracker Fee from the tracker's installation (0239)

The owner, Release 23: the Tracker Fee and the install fee are charged only once a tracker is installed, and the first
month is prorated from the installation date.

- The monthly owner invoice adds the Tracker Fee line only for a car with `vehicles.tracker_installed_on` set, prorated in
  the month of the installation (`app.generate_owner_invoice`). The install fee planned on an invoice needs the
  installation too.
- **What was charged so far** without an installation: `admin_read` `tracker_fee_audit` lists each owner and car with a
  Tracker Fee or install fee charged while no tracker is installed, and the amount. Nothing is credited by the migration:
  an Admin decides from that list.
- Tests: `supabase/tests/99_release_23.sql` section 13; `supabase/tests/helpers.sql` gives fixture cars with a Tracker Fee
  an installation on the enrolment date.

## Guides

No guide change: the fee rules are unchanged in the guides, which do not describe when the Tracker Fee starts.
