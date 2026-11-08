# Field jobs go only to trained staff on a shift, taken from a published schedule (Release 35, part T: 0880)

Branch `r35-t`. Migrations `0880_r35t_field_assign_gate.sql` (guides inside it) `0881_r35t_clock_location.sql` and `0882_r35t_admin_only.sql`. No applied migration is edited. Test:
`supabase/tests/99_r35t_field_assign_gate.sql` and `99_r35t_clock_location.sql` and `99_r35t_admin_only.sql`.

The owner's complaint: automatic assignment gave check-ins and handovers to field staff hired the same day, who had not passed
the academy and had no shifts. The production setting `field_jobs_auto_assign` is `none` meanwhile; the default in code stays
`least_busy`.

| Item | What changed |
| --- | --- |
| Shifts are taken | Fleet and Admin publish open shift slots (a day, a start, an end, how many people, the same hours for up to 14 days). A field person who passed the academy takes a slot on their portal under "Your shifts" and can give it up; Fleet and Admin can also put a person on a slot or take them off. Tables `field_shift_slots` and `field_shift_plans` (audited, row-level security like `field_shifts`) |
| Who the automatic assignment picks | Only a field person the academy gate does not hold, with a taken shift that day, least busy first. Nobody qualifies: the job stays unassigned and the "nobody is assigned" alert handles it |
| Work lands on days with shifts | Work due on a day with no shifts, known in advance, is planned for the nearest earlier day with shifts; work that comes in on the day goes to the next day with shifts. The job keeps its real time and shows its planned work day; customer-facing times never change. Every booking whose handover or return falls on a day without shifts shows a warning to Fleet and Admin |
| Manual assignment | A person the academy holds is refused ("<name> has not passed the academy yet"), also when a job is made with that person. The picker lists only eligible field staff and always the Admins; each name shows the next shift. A job can be taken off ("Unassign"); nobody is told unless "Tell them" is ticked |
| Admin | The Admin account can be given a job, opens the assigned jobs on the field portal, and opens the board at Cars > Field jobs (`/admin/field-jobs`) with every action Fleet has. One board component serves both (`/staff/fleet` for Fleet) |
| Board | Each field person's academy state and next shift, the next seven days with the days nobody works, the open and taken slots. The jobs table no longer squeezes the car name or clips the action buttons at 1440px |
| Clock in and out location | The field phone asks for its location once at clock in and once at clock out (never in between) and keeps latitude, longitude, accuracy and time on the shift. Over 500 m from the company location (Settings > Program), or location refused: the shift still starts or ends, with a reason the person writes; Fleet and Admin see the flag, a map link and the distance on the field hours. Read by the person, Fleet, Admin and Finance only |
| An Admin is only an Admin | The office and field roles and the staff profile given to Admin accounts as a stopgap are taken off (audited, the renter role stays); none can be added to an Admin again (the Portals invite form and Staff and roles are refused: "An Admin already has every staff page"). `/staff/fleet` sends an Admin to the field jobs board, which has every action |

## Guides

- `admin/people-and-access`, `admin/fleet-and-listings`, `va/fleet` and `field/my-jobs`: shifts, who gets a job, taking a job off.
