# Every alert opens the exact record (Release 48: 2960)

Migration `2960_r48_alert_targets.sql`.

The owner's report: most alerts "aren't leading anywhere". A sample of 80 Admin alerts opened bare pages: the Admin home (a renter's reply, the end of day digests), Staff (a job running late, a quiz passed), Academy, Live, Unanswered, Listings, Messages and Chat. The alert rules write one general page per rule; the notice names the record, but 2904 used it only when the page was the home page, and it knew only a few kinds of record. Notices from before release 30 still carried the old staff addresses (`/va/cs/...`), and the "latest alert" pop-up used the stored address as it was.

- `app.alert_target` gives the record's own page in the viewer's portal for every kind of record a staff notice is written for (`app.alert_entity_kind`): the booking in the right section (a message opens Messages & history), the conversation (Visitors > Chat, or Texts and calls), the visit (Admin) or the visitor on Visitors (staff), the field job on the board (`?job=`) or the job page (field staff), the shift (`?slot=`), the person's Academy page, their scorecard, the car, the owner, the application, the investor, the escalated alert's own page.
- A home page or a bare list gives way to the record whenever the notice names one. A list stays only when the alert is about a list (a digest, a job run, a payout run). End of day digests open the To do list of that role (`/admin/tasks?queue=cs`).
- The pages honour the address: the field jobs board marks and scrolls to `?job=` and `?slot=`; Visitors opens `?id=` on Live now as it did on Chat; the staff Fleet page passes them on to an Admin.
- The Alerts page, the latest alert pop-up and phone alerts use the same page. Unread alerts already written were repointed.
- Test: `supabase/tests/99_r48_alert_targets.sql` reads every (rule, record) pair the database's functions write and checks each kind with a record opens it, not a bare page.

## Guides

No guide change: alerts open where they say, nothing a person does changes.
