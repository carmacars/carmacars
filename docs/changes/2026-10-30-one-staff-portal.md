# One staff portal (migration 0197)

The owner: "Instead of /va and /field it's just /staff, so I can give people access to different kinds of staff work
altogether. An in-person sales employee is definitely not a VA."

## What changes for the owner and the staff

- **One portal at /staff** for every kind of staff work. Its menu has a group for each function the person holds:
  Customer service, Sales, Fleet, Finance and Field work (plus My work, Live and Rentals for the office functions). A page
  two functions share is listed once.
- **Any combination of functions.** A person can hold customer service, fleet, finance, sales (in person or remote) and
  field work (driver, detailer, or both) at the same time. Example: a Sales employee who also does handovers sees
  Requests, Send an offer, New quote and My sales, and their field jobs and handovers, in the same portal, with one
  sign-in.
- **Working as.** Someone with two or more functions still has the switcher at the top of the menu. It lists every
  function they hold, Field work included (which opens their jobs). The function chosen there decides the rules that
  depend on the function worked in (Fleet does not see a renter's contact details in a conversation, Sales works on
  requests and offers). A page for one function only (for example Daily checks for Fleet) opens in that function
  whichever is chosen.
- **Admin > Settings > Staff and roles:** each person has **Functions** with a checkbox per function, the Sales work
  (in person or remote) and the field role. The list shows each person's functions; "View as" is offered for each.
  Invitations are for **Staff** with the same checkboxes. Hiring ("Hire") gives the role's functions.
- **Old addresses keep working.** /va/... opens the same page under /staff/... (for example /va/bookings/CC-1 opens
  /staff/bookings/CC-1), and /field/... opens /staff/field/... (for example /field/jobs/... opens /staff/field/jobs/...).
  The links in staff emails and notifications now point to /staff. A phone that added the field portal to its home
  screen opens the staff portal's field jobs.
- The word "VA" is gone from the staff screens: the menu, the switcher and the guide's name say Staff and the function.

## Rules kept

Every function keeps its own permissions (what Sales may open, Fleet's contact stripping, the finance limits, the money
single limit, the task queues). A permission now comes from the functions held: holding Sales is enough for the Sales
checks even while working as customer service.

## Data

- `staff_profiles.functions`: the functions held, in order (any of `cs`, `fleet`, `finance`, `sales`, `field`; at least
  one). Existing rows moved: the main function, then the functions covered; field staff hold `field`.
- The older columns follow it (a trigger): `staff_type` ('va' with an office function, else 'field'), `va_function` (the
  first office function), `cover_functions` (the other office functions), `field_function` (set exactly when field work
  is held; a field referral code needs field work). The roles `va` and `field` follow the functions.
- `app.user_va_has(user, fns)` is true when the person holds any of fns; `app.user_is_field` when they hold field work;
  `app.va_active_fn` is the office function chosen on screen when held, else the first one held.
- `app.staff_set_functions` (Admin, door `admin_do` `staff_functions`); `app.admin_invite_account` takes role `staff`
  with `functions` (and still `va` or `field`).
- `my_roles` and `person_portals` add `functions` (and `sales_work_mode`).
- The notification links and the links the database writes (deposit reminders, document signing, maintenance digest)
  point to /staff.

## Guides

- `va/start-here`: the staff portal, one menu for every function held, field work in the same menu.
- `field/start-here`: field jobs are under Field work in the staff portal.
- The guides' sign-in addresses are /staff and /staff/field; the assistants' guide is the Staff Portal Guide.
