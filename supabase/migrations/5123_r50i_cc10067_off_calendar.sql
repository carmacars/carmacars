-- 5123 (release 50 hotfix 2; REQ-015; docs/changes/2026-11-27-r50-insurance-replacements.md): the owner (Nov 27 07:07):
-- "Cybele A10 CC-10067 should not block the calendar and should not inform the owner". CC-10067 is an insurer
-- replacement rental (claim and adjuster on the booking, checked with the connector on Nov 27). It goes off the calendar
-- and owner notices through the booking's calendar switch (0016), the same switch Insurance replacements sets (5120):
-- an insurer-billed booking off the calendar is not its car owner's (2480: no owner email, not on statements).
-- Who: the Admin account (rent@carmacars.ca); the 0016 trigger needs who and why. Each case that changes nothing says
-- why in a notice (the booking is not there, already off, not billed to an insurer, or the Admin account is missing).
do $$
declare
  b bookings;
  v_admin uuid := (select u.id from users u where lower(u.email) = 'rent@carmacars.ca' order by u.created_at limit 1);
begin
  select * into b from bookings where booking_number = 'CC-10067';
  if b.id is null then raise notice '5123: no booking CC-10067 here: nothing changed'; return; end if;
  if not b.blocks_calendar then raise notice '5123: CC-10067 is already off the calendar'; return; end if;
  if b.bill_to not in ('insurer', 'split') then
    raise notice '5123: CC-10067 is billed to %, not an insurer: left on the calendar (an owner is told of a renter-paid rental)', b.bill_to; return;
  end if;
  if v_admin is null then raise notice '5123: the Admin account rent@carmacars.ca is missing: CC-10067 left on the calendar'; return; end if;
  update bookings set blocks_calendar = false, blocks_calendar_changed_by = v_admin,
         blocks_calendar_reason = 'Insurance replacement: off the calendar and owner notices (the owner, Nov 27)'
   where id = b.id;
  raise notice '5123: CC-10067 is off the calendar and owner notices';
end $$;
