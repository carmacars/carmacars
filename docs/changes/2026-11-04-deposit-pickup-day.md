# The deposit hold on the morning of the pickup day

The owner: "deposits should be taken day of, not right on the spot". Migration 0261.

- Program settings, Deposit timing: On the morning of pickup day (the default) or At handover (old). Deposit hold: hour
  on the pickup day (8:00 am).
- On the pickup day at that hour (Toronto time), the deposit hold is placed automatically on the card on file
  (off-session, a manual-capture authorization, as every hold: captured before it lapses on a rental on the road, never
  released by itself). At once when the booking is confirmed later that day; from midnight when the pickup is before the
  hour. One try per booking: never two holds.
- The card rules hold: a credit card unless the booking takes debit or prepaid; the coverage card on a card-coverage
  rental. Not for a deposit in cash or by e-Transfer, a waived deposit, a long rental (its deposit is charged), or a
  booking with no saved card.
- A try that fails (declined, the bank wants the renter, no usable card): a task "Deposit not taken" on the booking, and
  the deposit link goes to the renter at once, by text (by email when there is no mobile or the text cannot go). The
  Money tab and the handover ready check say where the hold is; the handover says "No deposit yet: take it now".
- The deposit link texted 24 hours before pickup (Release 21b) is the fallback only: not sent while the automatic hold
  will run on the day; its setting stays.
- Renter wording: "deposit hold on the day of pickup" on the offer, booking, pay, sign, cancel and verify pages, the
  emails and the listings. The rental agreement stated the timing ("taken at pickup") and now says "taken on the day of
  pickup" (docs/source/v2_rental.md section 5.2 and the Schedule; web/src/features/agreement/model.ts and extra.ts): the
  agreement version is now rental-v3-ac530f3e8c. Signed agreements keep their wording.

## Guides

No guide change: field staff see the hold's state on the handover screen and take it there when it is missing, as before.
