# The staff To do without stale and duplicate tasks; view as shows the person's own portal (0325)

Seen live in a Sales assistant's portal (Darren) on November 1, 2026.

## 1. The staff To do

- **Causes (sure, from the code):**
  - Each visit of a known visitor raises its own follow-up (one per visitor signal, 0060), so a person who started the
    same booking request twice had "Call or message Yunu: started a booking request for the 2021 Kia Forte and stopped"
    twice.
  - "Booking CC-10024: the offer expires soon" (chase_offer) closed only when the booking expired or was declined, never
    when the renter accepted and paid.
  - "Licences to check" listed every booking with a licence image waiting, expired and cancelled ones included, and the
    licence review tasks stayed open on bookings that were over.
  - Follow-ups of visitors never closed by themselves.
  - Waits were shown twice: "Waiting 9672 minutes" (the screen reader words, which some views show) beside the clock
    "6d 17h".
- **Now:**
  - One task for the same work: a task raised while an open task of the same kind, for the same person, car and booking,
    with the same title, waits in the same queue is closed at once as "Merged: the same task is already open"; the
    duplicates open now were merged (the oldest stays). `app.task_merge_new`, `app.tasks_merge_duplicates`.
  - "The offer expires soon" closes as soon as the booking is no longer an offer (accepted, paid, confirmed, expired,
    declined); the licence and coverage review tasks close as soon as the booking is no longer live (requested, offered,
    waiting for payment, confirmed, on rent). At once (a trigger on the booking's status) and every hour (the task
    hygiene job). `app.tasks_close_stale`.
  - Follow-ups of visitors close after 7 days, the same window as the unfinished forms' (Program settings
    `capture_followup_days`); the visitor stays on Live visitors and Leads.
  - "Licences to check" lists live bookings only.
  - Waits read one way everywhere, shown and spoken: "6 days", "1 day", "3 h", "12 min"
    (src/components/portal-ui/time.ts `waitWords`, used by the staff timers, Admin's live waits and lists).

## 2. View as

- **Differences found** between an Admin viewing a staff member's portal and that person's own sign-in: the function
  switcher was hidden, the assistant button was hidden, the home address card was hidden while the person's address was
  missing, and the frame's Sign out was replaced by "Exit view". Data was already the person's (every read goes through
  the door with their id, the function chosen for the view, and their own token for row-level reads).
- **Now** the frame is the person's exactly: the switcher on the function viewed, the assistant, the address card, and
  Sign out (inert while viewing). The only additions are the red banner and its Exit. Writes stay refused (the Worker
  refuses every POST outside Admin), so pressing the switcher or the assistant changes nothing.
- Left as it is: phone alert invitations, which depend on the device in hand (the Admin's browser is not the person's).

## Tests

- DB: `supabase/tests/99_owner_todo_usage_noise.sql` section 11 (the same follow-up twice is one task; an accepted offer
  closes "expires soon" and keeps the licence task; a cancelled booking closes the licence task at once; the hourly
  hygiene closes a follow-up past 7 days; live statuses).
- Unit: `web/src/components/portal-ui/time.test.ts` (the wait words).
- E2E: `signin.spec.ts` "view as matches the person's own sign-in" (one Sales assistant and one customer service
  assistant with Fleet cover: the frame and menu, the sections and the pieces of /staff and /staff/tasks are the same as
  their own sign-in), and the view-as walk-through (Sign out shown and inert, the switcher shown).

## Guides

No guide change: no step changes; the queues hold fewer tasks, the waits read in one format, and view as shows what the
person sees.
