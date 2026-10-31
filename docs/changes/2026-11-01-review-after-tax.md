# The review screen with "After tax" saved on the device (no migration)

Production, October 30, 2026: on a device with **Amounts I type: After tax** saved, the review and offer screen
(`web/src/features/admin/BookingReview.tsx`) sent every fee and the coverage about 11.5% low. The boxes start with the
amounts before tax; the device's mode was read after the page loaded and switched the screen to after tax without
converting the boxes, so the amounts already before tax had HST taken off again and counted as changes.

- The boxes keep the mode they are in (`boxMode`, before tax at first). One effect converts the coverage, fee and rental
  charge boxes when the mode changes (the device's saved mode or the toggle), each line with its own HST, and sets the
  price's tax mode; the toggle only sets the mode. What is sent and the "changed" marks follow the boxes' mode.
  `convertBoxes` in `web/src/features/sales/taxIncluded.ts` (unit test: before, after and back is exact to the cent at 13%).
- The offer composer and Add a rental start with empty boxes, so the device's mode never reinterprets them; a restored
  draft now always takes the draft's own mode (its boxes were typed in it), also when the draft has no mode saved.
- e2e: `web/tests/e2e/release-21b.spec.ts` (After tax saved: the review changes nothing, the total is the booking's, and the
  offer keeps every fee and the coverage).

## Guides

No guide change: the screen works as the guide says; only the amounts sent are corrected.
