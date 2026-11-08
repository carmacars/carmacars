# Odometer and fuel at every check-out and check-in, with the selfie at the car (Release 35, part W: 0910, 0911)

Branch `r35-w`. Migration `0910_r35w_booking_ops.sql` (part 4). Test: `supabase/tests/99_r35w_booking_ops.sql` (sections 6 and 7);
unit tests `web/src/features/handover/reading.test.ts`, `web/src/integrations/vision/gemini.test.ts`.

The owner, November 8: a required dashboard photo at every check-out and check-in (renter and staff), read by the vision model and
confirmed, or typed with the fuel in eighths; at the return the km over the allowance and the fuel difference are charged from the
rate sheet, shown on the renter's return receipt and to staff with both photos side by side. Also: every photo may come from the
camera roll except a selfie in front of the car, taken live with the camera; a selfie without fresh capture details is a note to
staff, never a block.

| Item | What changed |
| --- | --- |
| Screens | `DashReading` on the one-screen check-in and check-out (staff and the renter's own check-in) and the renter's "I've returned the car": the dashboard photo (camera roll allowed), "Odometer 45,210 km, fuel 3/4: correct?", typed odometer and fuel in eighths when unread or rejected; the selfie input takes the front camera only (`capture="user"`), with the capture time and the place when the device gives it |
| Required | The server actions and the return route refuse a check-out or check-in without the dashboard photo, the odometer, the fuel in eighths and the selfie (`serverReadingProblem`). An Admin override or a past trip is not affected |
| Reader | `/api/handover/dash-read`: `server_dash_read_gate` (the renter, staff who hand cars over, or the return link; purpose `dash_read`, the live tier of the AI allowance), Workers AI first, Gemini only when `GEMINI_API_KEY` is set (free trial errors answer "not read" quietly; provider swappable); the call is recorded, never the reading |
| Kept | `handover_readings`: each reading with its source (read and confirmed, or typed), what the model read, the dashboard photo, the selfie and its capture details, and a note for staff when the selfie had no fresh capture time (also on the report notes) |
| Charges | Unchanged rule of 0130: the km over the included allowance at the booking's rate per km; the fuel short by the eighth at the refill price per eighth (now counted to the nearest eighth: `assess_check_in` patched) |
| Shown | The photo report: Odometer and fuel, both dashboard photos side by side with the readings and the km and fuel charges (staff and renter); the renter's booking: Your return: km and fuel |

## Guides

- `va/fleet`: Odometer and fuel at every check-in and check-out.
- `renter/after-your-trip`: Odometer and fuel at pickup and return.
