# Agreement card: coverage details before a proof is uploaded (migration 0182)

- Staff can type the renter's coverage details (insurer, policy number, expiry, or card details) on the booking's
  Agreement card even when the renter has not uploaded proof yet. Before, saving failed with "There is no coverage proof
  on this booking yet", so no agreement could be prepared for a renter who showed a pink card in person.
- Saving creates the coverage record (submitted, no document); it still shows as not confirmed until a document is
  reviewed. The audit log records who entered it.

## Guides
No guide change: the Agreement card is unchanged; the save no longer stops for a missing proof.
