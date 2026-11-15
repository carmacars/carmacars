# The academy teaches the guides and the renter's side (Release 48: 2990, 2991)

Migrations `2990_r48_academy_guides.sql` and `2991_r48_academy_guides_chapters.sql`.

Staff kept asking the owner things the guides already answer, and they help renters without knowing the renter portal. The academy now teaches both.

- Worked examples for every role: one section each for customer service, Sales (in person and remote), Fleet, Finance, field work and Admin, written from that role's guide chapters ("A renter texts X: here is what you do, where you click, what you say"), with the guide's screenshots and a quiz drawn from the examples. Each starts with **Ask the guide first**.
- A new shared path, **The renter's side** (`renter_side`), for every staff role and the Admin path: nine steps of the renter guide (request a car, the offer, Complete your details and signing, paying and the deposit hold, coverage proof with the pink slip and OPCF 27, pickup and check-in, extensions and changes, the return and the deposit back, common errors and what to tell the renter). Each step shows the renter's screen and opens that page of the renter guide.
- Content: `supabase/seed/academy/r48.mjs`, generated into 2990 by `supabase/seed/2990_gen_academy.mjs` (`--check` refuses a missing chapter, a screenshot that is not a guide image of a chapter the section names, fewer than 5 questions, options that repeat, an answer out of range, a long dash or a vendor name). 15 sections, 44 lessons, 85 questions.
- Required: `app.academy_paths_of` (wrapped as `academy_paths_of_pre2990`) gives The renter's side to everyone with a path, so one-step Hire enrolls new hires on it and the onboarding gate holds them until it is passed, as for every path. Staff already working who had passed everything have 7 days (their gated enrollments' `lock_from`); the academy page says **New sections to pass by** the date. Staff still training are held as before. Nothing is reset.
- A scene can show a guide screenshot: the picture `shot` (the chapter, the image, a line), drawn by the player and in the rendered videos, with **Open this page of the guide**. `app.academy_check_scenes` accepts it. The new lessons have no video yet: **Render videos** on Admin > Academy makes them.
- The renter guide inside the staff portal: `/staff/guide/renter` (office and field staff), so the links open the page the renter reads; Admins open `/admin/guide/renter`.
- **Ask the guide first**: the Assistant panel of every staff portal (Admin, staff, field) names the guide chapter of the page you are on, with its link (`askGuideFirst`, from the Stuck help map).
- Tests: `supabase/tests/99_r48_academy_guides.sql` (the steps in order, every role, quiz integrity, the counts, the screenshot scene, the path for every staff member, a hire held by it, the 7 days); `99_academy.sql` and `99_r34n_academy_gate.sql` follow the new path; unit: `web/src/features/academy/r48.test.ts`.

## Guides

- `va/academy`, `field/academy`: The renter's side and Ask the guide first, the 7 days and the renter guide in the staff portal.
- `admin/academy`: the new path, the worked examples, new hires and staff already working, the screenshot scene, and adding missing answers to the guide.
