# A booking request fills itself from the renter's profile (Release 45: 2860)

Migration `2860_r45b_request_profile.sql`.

- **The request form**: a signed-in renter's request was filled with the phone and the email only. It now fills every empty field the account holds: the first and last name, the date of birth, the licence class (a licence from elsewhere as Other licence with its issuer, when those are reviewed), and the contact channel the account chose. What the renter typed, or a saved draft, always wins; drafts keep working as before. The drivers named on earlier bookings are offered with one tap under Additional drivers (not added by themselves, since each one may add a fee).
- **Out of date**: a licence on file that has expired, or expires before the return, and a home address older than the new Program setting `profile_address_max_months` (12) are flagged for the renter to update in their profile. `renters.address_updated_at` dates the address (a trigger keeps it).
- **Privacy**: `public.server_request_profile` is server only and answers only for the signed-in person's own renter record; nobody who is not signed in gets anything. The renter's own browser gets only the last 4 characters of the licence number.
- **Staff**: on Send an offer and Add a rental, picking a renter on file shows their licence (class, number, expiry), home address and drivers named before, with the same flags worded for staff; on Add a rental **Add them** fills the additional drivers (`ops_read renter_profile_fill`, an Admin, customer service or Sales).
- The request form, Admin and staff pages share `web/src/features/booking/profile-fill.ts` (unit tests in `profile-fill.test.ts`). The request form has no licence number, expiry or home address fields: those show as information with their flags.

## Guides

`renter/find-a-car-and-send-a-request`, `admin/requests-offers-and-bookings`, `admin/partners-company-cars-and-rentals-added-by-hand`, `va/add-a-rental-by-hand` (migration 2865).
