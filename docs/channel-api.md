# CarmaCars Channel API (for rental distribution partners)

Release 37, migration `2304_r37_channel_api.sql`. For brokers and aggregators (VIPCars, EconomyBookings,
Rentalcars.com / Booking.com Cars, CarTrawler, Kayak through a connector). This is not the Admin API (Settings > API
access): a channel key sees only our public cars and public prices.

## What to send a partner

1. The base address: `https://carmacars.ca/api/channel/v1`
2. Their key (Admin > Settings > Channel partners > Make a key). It is shown once; send it by a private channel.
3. This page.

## Authentication and limits

- Send the key on every call: `Authorization: Bearer cc_chan_...` (or `X-Api-Key: cc_chan_...`).
- Each key has scopes: `availability:read` (locations, cars), `rates:read` (availability and prices) and, only when we
  turn them on, `bookings:create` and `bookings:cancel`.
- Each partner has a limit of calls a minute (60 unless agreed). Over it: HTTP 429, `code: "rate"`.
- Errors: `{"ok": false, "code": "...", "message": "..."}` with HTTP 401 (key), 403 (scope or paused), 429 (rate),
  503 (the channel is switched off), 400 (refused request).
- Every call is logged with the partner and the outcome.

## Calls (JSON)

| Call | Scope | Answer |
| --- | --- | --- |
| `GET /locations` | availability:read | our base (Toronto, Scarborough) and the airports we deliver to; any address is quoted with `lat` and `lng` |
| `GET /vehicles` | availability:read | each car: `ref`, class, make, model, year, trim, body style, seats, doors, transmission, luggage, features, photo URLs |
| `GET /availability?pickup_at=2031-03-02T10:00:00-05:00&return_at=2031-03-04T10:00:00-05:00[&ref=][&lat=&lng=][&coverage=]` | rates:read | per car: `available`, `problems`, `currency` (CAD), `billable_days`, `rental_cents`, `subtotal_cents`, `hst_cents`, `total_cents` (your markup included), `deposit_cents`, `km_per_day`, `km_total`, `extra_km_cents`, delivery fees, the Protection Plan option, driver age bands and add-ons |
| `POST /bookings` | bookings:create | a booking request: `{ref, pickup_at, return_at, pickup_method, return_method, pickup_place, return_place, coverage_option, renter: {email, full_name, mobile, date_of_birth, licence_class, licence_issuer}, additional_drivers, consents, partner_ref, note}`. Answer: `{booking_number, status: "requested"}`. We confirm the car and the price; the renter verifies their licence and pays the deposit before the booking is confirmed. |
| `DELETE /bookings/<booking_number>` | bookings:cancel | cancels a request you sent (only yours) |

Prices are the same quote the website shows (rates, weekend rule, delivery from our base, deposit, kilometres, young
driver and Protection Plan options), plus your agreed markup on the rental and its HST.

## OTA XML

`POST /ota` with an `OTA_VehAvailRateRQ` (OpenTravel 2003/05) body; we read `VehRentalCore PickUpDateTime` and
`ReturnDateTime` and answer `OTA_VehAvailRateRS` with one `VehAvail` per available car (`Vehicle Code` = our `ref`,
`VehMakeModel`, `PictureURL`, `RentalRate` per day with the kilometres, `TotalCharge` rate and estimated totals, the
deposit as a fee). Errors come back as `<Errors><Error Code="...">`. DOCTYPE and entities are refused.

## What a partner never sees

No renter or owner data, no plates or VINs, no costs, owner payouts, utilization or calendars, and nothing of another
partner. A paused partner or a revoked key is refused at once. The whole channel switches off with Program setting
`channel_api_enabled`.
