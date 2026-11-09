# Field applicants' live calls, the townhall's day and attendance, and the booking celebration (Release 35, part K: 1068, 1079)

Branch `r35-k`. Migration `1068_r35k_field_calls_townhall_people.sql` and the guides of `1079_r35k_guides2.sql`. Wrapped, never
edited: `app.townhall_slides`, `app.townhall_view`, `app.job_townhall`, `app.job_hiring`, `app.door`; replaced: `app.townhall_next`,
`app.townhall_do` (a shout-out key `p_<user>`), `app.staff_access_facts`, `app.live_map_pre0470` (1064's hook, over 1080's parts).
Tests: `supabase/tests/99_r35k_rates_location.sql` (sections 4 to 6), `supabase/tests/99_r35k_staff_onboarding.sql` (8 slides),
`web/src/features/townhall/model.test.ts`, `web/src/features/live-map/model.test.ts`.

## A. Field applicants (coordinator item 15)

Every role has the AI interview (1060) and a Sales pass is hired at the mark (1060). A field applicant who passes is invited
(`app.hiring_field_to_call`, in the hiring job) to a 10-minute live call: `app.townhall_field_slots` opens an interview day each week
with six slots in the hour before the townhall, for the field roles, booked through the applicant's link with the usual reminders.
`field_call_slots` (Fleet and Admin) lists them: **Field applicant calls** on the Fleet home page and Hiring > Calls.

## B. The townhall (coordinator item 16)

| Item | What changed |
| --- | --- |
| The day | `app.townhall_pick_day`: the least busy weekday, Monday to Saturday, by pickups, returns and field jobs over the last 8 weeks and the next 2 (`app.townhall_busy_days`). Worked out every Sunday evening when `townhall_auto_day` is on; a new day starts 8 days later (`townhall_next_weekday`, `townhall_next_from`) and everyone is alerted (`townhall_moved`). The time stays `townhall_time` (11:30) |
| Invited and reminded | Every staff member: the alert an hour before goes to each person (`townhall_soon` to the people it names) |
| Attendance | `townhall_attendance`: **Join the call** goes through `/api/townhall-join` (recorded, then the call), or **Check in** from 15 minutes before (`townhall_attend`). When it ends, `townhall_meetings` keeps who missed it; Admins get `townhall_absent`; the staff list shows the misses of the last 8 weeks |
| The team slide | The deck's last slide (`app.townhall_people`): a tile per staff member with their role's numbers for the week; an Admin adds a shout-out per tile |

## C. The booking celebration (coordinator item 6)

The live map's figures layer carries the bookings confirmed in the last 15 minutes (`celebrations`). Each plays once per screen
(remembered in the browser): confetti and a pulse at the renter's pin (the map's middle when not placed) and a note with the car
and the Sales credit. With reduced motion: the note only.

## Guides

- `admin/hiring`: field applicants' live calls before the townhall.
- `admin/people-and-access`: the townhall's day, attendance and the team slide.
- `admin/live-visitors-and-live-chat`: a booking confirmed.
- `va/fleet`: field applicant calls.
- `va/your-workday`: the weekly townhall.
- `field/start-here`: the weekly townhall.
