# Release 27 final merge (migration 0502)

Merge of `hotfix-photos`, `r27-extend-clean`, `r27-alerts`, `r27-cons`, `r27-mkt` and `r27-left` into `r27`. SCHEMA_MARKER 0529.

## Owner bugs fixed while merging (0502)

- Reopen on an expired offer now sends a new offer: the request goes back to requested (the old offer stays expired and a
  "reopened" event is logged), the booking is re-priced as of now and a new version is sent with a fresh expiry
  (`offer_expiry_hours`). When the pickup has passed or the car is no longer free it stays a request for staff to edit.
- Staff can change the return of a trip after its return time while the guest still has the car (`app.booking_still_out`,
  the renter's extension rule) through Propose a change; the pickup and the car of a trip under way stay fixed.
- A date the renter picks for an extension is priced at the lower of the added days at the tier less 5% and the whole
  booking repriced less what was charged (the six offers keep their tier price).
- Tests: `99_reopen_offer_and_change_while_out`; `08_booking_app` and `99_extend_offers` follow the pricing rule;
  `99_alert_prompts` and `99_live_map` no longer disturb other suites.

## Guides

No guide change: the Reopen and change-while-out wording is covered by the r27 guides and Academy accuracy pass.
