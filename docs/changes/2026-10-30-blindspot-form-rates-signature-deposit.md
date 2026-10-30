# Blind Spot agreement: the rate in its column, the renter's signature on every version, the deposit received, the fuel

Reported from the desk on a 31-day rental (October 30, 2026). No migration.

## What was wrong, and why

- **Box 35 showed the whole rental charge, not the daily rate.** The rate column was filled only when one rate times
  the count made the charge exactly. A 31-day rental at the monthly rate is counted by the day (monthly rate / 30 x 31),
  so the rate was left out and the row read "DAYS 31 @ (blank) $3,097.35" (`web/src/features/blindspot/layout.ts`, the
  rate rows).
- **No renter signature on the form the desk prints.** The signed copy stamps the renter's signature, but every later
  version (as picked up, as returned, corrected) was rendered again from the blank form with only "Signed on the
  original" written small in the boxes (`web/src/server/agreements/versions.ts`, `runVersionJob`). After check-out the
  booking's current Blind Spot PDF is the "as picked up" version, so it carried no signature. No copy showed the day
  signed.
- **No deposit received.** It was filled only on a copy made after the deposit was taken, it took the amount from the
  booking with no date, it did not count a deposit paid as a payment, and it printed a second "$" after the form's own.
- **"8 8 8 8 8" in FUEL OUT and FUEL IN.** Those are the form's printed gauge circles: the FUEL OUT and FUEL IN circles
  touch and read as eights, with or without a reading.
- **Box 50 was not 13% of box 49 on the closing copy:** it carried the HST of damages, fuel and the post adjustment too,
  which the form adds after the tax (boxes 52 to 54).

## What changed

- **Rate rows (33 to 38): COUNT @ RATE = AMOUNT.** Weeks (36) or months (37) when the weekly or monthly rate makes the
  charge exactly; else days (35) at the daily (or 3+ day) rate when it makes the charge; else days at the rental charge
  divided by the days, rounded to the cent, and box 14 says how the charge was made, for example "Box 35: the monthly
  rate $2,997.43 / 30 x 31 days = $3,097.35, $99.91 a day rounded." (daily and weekend days, the weekly rate counted by
  the day and a charge agreed by hand are worded the same way). Kilometres (33), hours late (34) and extra days (38, at
  the daily rate or the average) are rows of the same kind. **Box 39 is the sum of the amounts of these rows.**
- **Signatures.** `formSignatures` (`web/src/server/portal/blindspot.ts`) reads what the renter signed the Blind Spot
  agreement with: the signature record's drawn image (else the signing session's drawing, else the typed name in the
  script hand), the day signed, each additional driver's drawing and the initials. The signed copy and every version not
  signed again now carry them: the renter in boxes 16, 17 and 20, "SIGNED ON" and the day (Toronto) beside box 20, the
  drivers in box 10, the initials; the representative stays in box 21. A version the renter signs again gets its own
  signature and day on its signed copy. The note "Signed on the original" is kept only when the signature cannot be
  read, and nothing is stamped on a booking signed before the form was in use.
- **Deposit received (59).** The deposit taken (a card hold held, captured or settled, a charge, cash or e-Transfer
  recorded, or a deposit payment) after the printed "$", with the month and day it was taken in 59. Before it is taken:
  "500.00 due at pickup" in the same place. Add deposit stays blank (there is no second deposit). Total deposits (56)
  unchanged.
- **Fuel.** The printed gauges are covered (the pink and white rows, and the rule under them drawn again) and the level
  of the check-out report (fuel out) and check-in report (fuel in) is written in words: "Full (100%)", "3/4 (75%)",
  "About 5/8 (60%)". Blank with no reading.
- **Totals.** 48 (pre adjustment) holds the charges before the rental with no box of their own (delivery, add-ons,
  drivers' fees, a discount, prepaid fuel); the Protection Plan stays on the CDW line. 49 is every charge before tax but
  damages, fuel and the post adjustment; 50 is its HST (13% of 49); 52, 53 and 54 include their own HST (box 14 says
  so); 49 + 50 + 52 + 53 + 54 = 55.

## Tests

`web/src/features/blindspot/fill.test.ts`: a 31-day rental (rate rows, box 14's note, the money boxes adding up, the
deposit received and due, the fuel), the weeks and months rows, daily and weekend days and a charge agreed by hand, the
signature and day on the signed copy and on a version drawn from the template. `web/src/features/agreement/accuracy.test.ts`
updated (deposit after the printed $, fuel in words, 49 and 50 and 53 and 54 on the closing copy). Checked on Blind
Spot's real form locally (never committed).

## Guides
- `admin/settings`: the Blind Spot section says how the rate rows, HST, deposit received, fuel and the signature with
  its day are filled.
