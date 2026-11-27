# R50 hotfix 2: no "VA" for in-person staff, the townhall for everyone, fixtures that do not expire (5180, 5181)

Migrations `5180_r50h2_no_va_for_in_person.sql` and `5181_r50h2_labels_guides.sql` (5182 to 5184 unused).

## What the owner asked

- In-person staff (field staff, in-person sales) still showed the role "VA". "VA" is only for a remote virtual assistant.
- The townhall: Join did not work for anyone and the deck could not be seen during the meeting (it ran on WhatsApp).
- Test fixtures with hard-coded dates now in the past broke CI.

## Changes

- **Labels (5180, 5181).** The fourth onboarding step is approved by "an Admin or a Fleet team member" (not "a Fleet VA") in the waiting list
  (`app.staff_waiting_on`), the academy questions and lessons, the alert rule hint, the notification catalogue's trigger texts, the
  guides (Admin and Staff chapters) and the web pages (welcome, gate, onboarding list). The five email trigger texts that said
  "customer service VA", "sales VA", "the VA equivalent", "the VA limit" and "a VA escalated" now say staff member
  (`emails/src/emails`, rebuilt catalogue).
- **Admin > Settings > Staff, column Roles.** It printed the raw sign-in role (`va`, `field`). It now says Staff, Admin, Owner or
  Renter (`signInRoleWords`); the Functions column beside it names the job (Sales (in person), Field work).
- **Tests.** `src/features/staff/no-va-label.test.ts` (no page, email source or guide of in-person staff says VA);
  `tests/e2e/in-person-no-va.spec.ts` (a field staff member and an in-person salesperson: portal, profile, guide, townhall page,
  the deck, the Admin's staff list).

- **Townhall (web only).** The deck no longer depends on the call: the lobby of the call page has "Read the slides without the call"
  (`DeckList`), and the page that said "The call in the site is not available here" (media server off or an Admin on the outside
  link) now lists the deck under it, so a failed join never leaves people without the slides. The portal home's townhall card keeps
  "Join the call again" once a person is checked in (before, a dropped connection left no Join button). A person still in
  onboarding (agreement, academy, WhatsApp, approval) can open the townhall page and call (`townhall` is in the gate's open lists),
  because two missed townhalls lock an account.
- **Townhall e2e.** `tests/e2e/townhall-everyone.spec.ts`: two staff (office, field) and an Admin press Join from their portals, join
  the call in the site, see the same slide, the Admin advances and both follow; browsing alone and "Back to the presenter"; a late
  joiner lands on the presenter's slide; attendance is recorded; the deck is on every portal's townhall page.
- **Fixtures with dates.** `test.fut(text)` (supabase/tests/helpers.sql) moves a fixture date by whole weeks so it is never in the
  past (weekday, hour and gaps stay). Applied to the future-status bookings whose pickup is on or after 2026-11-27 (23 files);
  `44_sample_cars_back.sql` builds its request dates from `test.base(3)`. `assistant-usage.spec.ts` asks for dates two weeks ahead.
  Left alone on purpose: dates read by an injected clock (`test.og_at`, `test.tp_at`, `test.he_at`, `test.pw_at`, the 99_r49_notices
  and 99_r48_rewards_notices literals) and the 2027 bookings of `03_flows.sql` (tentative; they expire in February 2027).

## Not changed

- "VA" stays for remote roles: the hiring roles (`Customer service (VA)`), the VA contractor agreement and the Admin hiring guide.
- The internal key `va` (portal and role names in code and the database) stays; it is never shown.

## Guides

- `admin/people-and-access` and `va/your-workday`: the approval by "an Admin or a Fleet team member".
