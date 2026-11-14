# Field shifts are published by themselves (Release 45: 2864)

Migration `2864_r45b_field_slots_auto.sql`.

No shift slots were published, so field staff could not pick shifts and handovers and returns fell on days with no shifts.

- **The template** (Program settings, Field jobs and handovers): `field_slots_auto` (on), `field_slot_template` (by default the owner's choice: one shift of 10:00 to 17:00 for one person every second day, in the rhythm of the slots already published from Monday November 23, 2026), `field_slots_auto_days` (14 days ahead) and `field_slots_auto_from` (2026-11-23).
- **Every hour** (the field shift job, before the standing claims) the template is published only forward, after the latest slot already published (by hand or by itself, cancelled or not), and never for a day before `field_slots_auto_from`: no shifts open for November 14 to 22, the coming week, and a slot Fleet or an Admin cancelled is never published again.
- **A covering slot**: from `field_slots_auto_from` on, a confirmed booking whose handover, or a confirmed or on-trip booking whose return, falls at a time no slot covers gets a slot of its own (90 minutes before to 90 minutes after, one person), so every job has a shift to claim. Before November 23, 2026 nothing is added.
- The unclaimed slot alert (48 hours before, to Fleet and the Admins) is unchanged and covers these slots too.

## Guides

`va/fleet`, `admin/people-and-access`, `admin/fleet-and-listings`, `field/my-hours-and-pay` (migration 2865).
