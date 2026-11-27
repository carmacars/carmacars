-- 5123 (release 50 hotfix 2; REQ-015; docs/changes/2026-11-27-r50-insurance-replacements.md): the owner (Nov 27 07:07):
-- "Cybele A10 CC-10067 should not block the calendar and should not inform the owner". CC-10067 is an insurer
-- replacement rental (claim and adjuster on the booking, checked with the connector on Nov 27). It goes off the calendar
-- and owner notices through the booking's calendar switch (0016), the same switch Insurance replacements sets (5120):
-- an insurer-billed booking off the calendar is not its car owner's (2480: no owner email, not on statements).
-- A no-op where the booking does not exist (test and local databases) or is already off.
-- Who: the Admin account (rent@carmacars.ca); the 0016 trigger needs who and why.
update bookings b
   set blocks_calendar = false,
       blocks_calendar_changed_by = a.id,
       blocks_calendar_reason = 'Insurance replacement: off the calendar and owner notices (the owner, Nov 27)'
  from (select u.id from users u where lower(u.email) = 'rent@carmacars.ca' order by u.created_at limit 1) a
 where b.booking_number = 'CC-10067' and b.blocks_calendar;
