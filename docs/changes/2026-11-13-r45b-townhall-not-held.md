# A townhall that did not happen counts nobody absent (Release 45: 2863)

Migration `2863_r45b_townhall_not_held.sql`.

The townhall job recorded every active staff member absent for each weekly townhall once its time was over, held or not, so Settings > Staff showed "Missed 1 townhall (8 weeks)" for everyone.

- **Not held**: a townhall with no attendance at all is recorded as not held (`townhall_meetings.not_held`) and counts nobody absent. Two misses in a row lock an account only for meetings that were held.
- **This townhall did not happen**: on the Townhall page (Meetings, the last eight and the next four), an Admin marks a past one not held: its absences are cleared, its absence alerts closed and a lockout it caused lifted.
- **Cancel this townhall**: an Admin cancels an upcoming one with a reason (`townhall_cancellations`): no reminders are sent for it and it is recorded as not held once over. **Put it back on** undoes it.
- **Once**: every past meeting with no attendance at all was marked not held and its absences cleared (the migration reports the counts).

## Guides

`admin/owner-money`, `admin/people-and-access`, `va/your-workday` (migration 2865).
