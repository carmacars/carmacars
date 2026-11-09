# The accident card of a booking, and Report an accident (Release 35, part W: 0910, 0911, 0912)

Branch `r35-w`. Migrations `0910_r35w_booking_ops.sql` (part 2) and `0912_r35w_accident_report.sql`. SCHEMA_MARKER 0912. Test:
`supabase/tests/99_r35w_booking_ops.sql` (sections 4 and 8); unit tests `web/src/features/accident-card/model.test.ts` and `report.test.ts`.

The owner, November 8: each renter has an accident card per booking, on their booking page and printable, with the steps after an
accident and the coverage that booking uses; never our own fleet slip on a renter's card. Staff see the same card.

| Item | What changed |
| --- | --- |
| Data | `app.accident_card(booking)`: the support and roadside numbers (as the car's card of 0813), the car, the renter and the coverage of the booking's option: OPCF 27 (insurer, policy number and expiry from the renter's proof), credit card coverage (card brand, last four, issuer, coverage provider, cardholder from the proof), Protection Plan (provider, policy number, claims phone from Program settings, the renter's activation reference). The fleet policy is never read |
| Settings | Program settings `accident_plan_provider_name` (RentalCover), `accident_plan_policy_number`, `accident_plan_claims_phone` (Tolls and damage) |
| Who | `public.server_accident_card` (the booking's renter or staff); door `ops_read accident_card` (staff) |
| Pages | Renter booking page: **Accident card** with **Print it**, `/account/bookings/[number]/accident-card` (Letter, the card's size, the r34 steps and QR code). Staff booking page: the same card with **Print the card** (`/admin` and `/staff/bookings/[number]/accident-card`) |

| Report an accident | The owner's addition: on the renter's booking while on rent, **Report an accident** on the accident card (phone first, the draft kept on the phone as they type): what happened, when, where (typed or the phone's location), photos and videos from the camera roll (`/api/accident-media`: JPEG, PNG, MP4, QuickTime, WebM up to 25 MB, the renter of the booking only), the other party (name, phone, plate, their coverage), the police report number, anyone hurt, can the car be driven. `app.renter_accident_report` opens the incident of 0020 (`app.open_incident`, reported by the renter: its first-response steps, the Fleet and Admin To dos, a car that cannot be driven out of service with its calendar blocked), files each photo and video as a document of the incident, sends the urgent alert `accident_reported` to Admins and Fleet on duty, and shows the renter the next steps and our phone number; more photos or videos can be added after (`app.renter_accident_media`) |

## Guides

- `admin/requests-offers-and-bookings`: The accident card of a booking.
- `renter/before-pickup`: Your accident card.
- `renter/during-your-trip`: Report an accident.
- `va/fleet`: An accident reported by a renter.
