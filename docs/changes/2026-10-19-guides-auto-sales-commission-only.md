# Guides update themselves, staff home address, Sales commission only (October 19, 2026)

Migration `0059_guides_auto_sales_commission_only.sql`; tests `supabase/tests/38_guides_auto_home_sales.sql`; end to end
`web/tests/e2e/guides-auto-home-sales.spec.ts` (phone 375 and desktop 1440); unit tests in
`web/src/features/guides/upkeep.test.ts` and `web/src/features/person-agreements/model.test.ts`. No applied migration was
edited. The owner's four decisions of October 19.

## 1. The guides update themselves, with nothing to review

| What | Now |
| --- | --- |
| A rewrite that passes the checks | Published at once, always (`app.guide_auto_update`), including a section an Admin edited or has an unpublished draft in: the newest automatic version wins. The Admin's draft is saved in the section's history first; the replaced published text is kept for **Revert** (one click, published again as a new version) |
| A rewrite that fails the checks | Asked again, more strictly (`REWRITE_ATTEMPTS` = 3 in `web/src/features/guides/upkeep.ts`: the second attempt names the problems of the first; the third is "strict mode", only the missing button names and menu paths may change, temperature 0). If every attempt fails, the old text has only its button names replaced by the closest label that exists (`labelOnlyRewrite`), published when that passes the checks; otherwise the old text stays. The screenshots are already replaced by the run. Either way the section is logged for the next run (`guide_sections.auto_retry_at`, `auto_retry_note`, `auto_retry_count`; audit `guide_auto_kept`) and the next run takes it again. Never a suggestion, never a task |
| A release's chapters | `app.guide_release_section` and `app.guide_update_published_section` publish the new text whatever an Admin edited (their text in the history, Revert offered); 0059's own chapters use it |
| The upkeep run | `web/scripts/guide-upkeep.mjs` also takes the sections logged by the last run (`retry`) and the ones whose screenshot changed in a run that did not check the text (`pending`); the report has `rewritten` and `kept` (no "to review") |
| Admin > Settings > Guides | The "To review" column, the "Needs review" badge, the review panel (Suggest a text, Use this text as the draft, Dismiss the suggestion, Mark reviewed) and their server actions are gone; the reads (`guide_admin`, `guides_admin`) no longer carry the flags. The card says there is nothing to review; the runs list says how many sections are checked again next run |
| The doors | `guide_suggestion_record` and `guide_review_resolve` are refused ("The guides update themselves: there is nothing to review") |

**The queue, published.** Live on October 19 there were five suggestions and six screenshot flags:

| Section | What happens at the deploy |
| --- | --- |
| admin/owner-money, admin/settings, field/my-jobs | Their 0058 text (the suggestion) is published from the current guide sources, with this release's changes |
| admin/people-and-access | An automatic suggestion of October 17, older than 0058's text: this release publishes the chapter again from the guide sources, which clears it |
| admin/requests-offers-and-bookings | An automatic suggestion of October 19, older than the text published since (0058's): the published text stays, the suggestion is dropped and kept in the audit log (`guide_suggestion_dropped`) |
| va/shared-tools, va/finance, va/fleet, owner/notices-profile-and-leaving, investor/statements, investor/profile-and-notices | Screenshot flags: the note is cleared; the section stays internal to the upkeep (pending) so the next automatic run checks its text |

The guides block of 0059 (`supabase/seed/0059_gen_guides.mjs`, base commit `2cc8d8e`) publishes 10 chapters: admin
people-and-access, owner-money, settings; VA start-here, add-a-rental-by-hand, commissions; field start-here, my-jobs,
report-rentals-referrals-and-profile, quick-reference. The Admin, VA and field PDFs are rebuilt (`docs/guides/pdf`); the
stored PDFs are printed again by the guides run after the deploy and by guides-pdf.

## 2. Program settings, confirmed

The owner confirmed the 20% discount limit that flags a typed price, no price floor, and the commission rates and tiers
as set (10% outside Sales; Sales 10% under 50 rental days, 15% from 50, 20% from 100). No value changed. Recorded in the
audit log (`owner_confirmed_settings`, with the values) and on the columns' comments; the admin guide says so.

## 3. Staff enter their own home address

| What | How |
| --- | --- |
| Where | At the first sign-in to the VA or field portal: a card at the top of every page ("Welcome. First, your home address") until it is saved. In the staff agreement signing step (the Sign box waits for it). In the profile: the field portal's Profile, and a new VA Profile page (`/va/profile`, "Profile" at the top of the menu) |
| Saved by | The staff member (`va_do` / `field_do` `home_address_save`, `app.staff_home_address_save`): a full address with a number and a street, and a postal code; dated, by whom, audited. An Admin can still edit it on the staff member's Sales page ("Home address") |
| Required before | Adding a rental (VA and field; the page asks for the address instead of the form, and the door refuses), a quote or an offer marked "I sourced this client", and earning a commission: a commission of a staff member without an address waits as not earned yet, with the note "Earned once the home address is in the staff member's profile", and is brought in step as soon as the address is saved (trigger `staff_profiles_home_resync`) |
| Used for | The household check (0058) and the Field Staff Agreement, which now prints the address the staff member entered |
| The owner's to-do | The admin entry of home addresses is no longer on it |

Staff who were on the platform before this release see the card at their next sign-in. Until they save it, their
commissions wait (one already pending approval goes back to not earned yet when its booking next changes).

## 4. Sales is commission only

| What | Change |
| --- | --- |
| Program settings | `staff_agreement_defaults.va.by_function.sales`: pay `commission`, schedule `flexible`, no rate, days or hours (dated rows whose Sales values were still blank were set; the column default too). The form offers "Commission only" and "Flexible" |
| The generated VA agreement | Schedule A has a new **Pay** row: "The Rate below and the commission in section 3.4", or "Commission only, under section 3.4: no Rate, no set days or hours". Commission only removes the Schedule, Coverage Hours and Rate rows, and the send form does not ask for them. Template version `person-7571e78a38` |
| `docs/source/va_agreement.md` (for the lawyer) | 3.1: "If Schedule A says the Pay is commission only, there is no Rate and there are no Coverage Hours: you are paid only the commission in section 3.4, you choose when you work, and what this agreement says about the Rate and the Coverage Hours does not apply to you." 3.2: "The Rate (if any) and the commission". 7.4: CarmaCars pays for approved time "and the commissions earned under section 3.4" up to the end date. Schedule A: the Pay row. Section 3.4 (the commission) is unchanged |
| `docs/source/va_hiring_package.md` | Section 2 (Pay): Sales commission only with the rule; the role table (flexible hours); the Sales job post (commission only, flexible hours, no hourly rate asked); screening question 5 and the paid test for Sales; offboarding pays the commissions earned |

## 5. Tests

| Suite | Result |
| --- | --- |
| Database (`scripts/test.sh`) | 3773 passed, 0 failed. New suite 38 (36 assertions: (the auto-publish over a draft, Revert, the kept text and its log, a release over an edited chapter, the review steps refused, the settings confirmation, the address gates for rentals, quotes and offers, the address checks, the commission waiting for the address and earned once it is saved, the Admin's edit, Sales commission only); 31, 35, 36 and 37 updated for the new rules; the test helper gives staff a home address (as after their first sign-in) |
| Unit (`npm run test:unit`) | 121 passed (commission-only agreement, the field agreement's address, strict retries, the button-name fallback) |
| End to end, 375 and 1440 | `guides-auto-home-sales.spec.ts` 6 of 6 locally (a rewrite published over an Admin's draft; a rewrite failing three times keeps the old text and is logged; Admin > Settings > Guides with nothing to review; an assistant's first sign-in, Add a rental waiting for the address, the profile; the same for field staff). Staff fixtures in the other specs enter a home address |

## 6. Deploy and checks

| What | Run | Result |
| --- | --- | --- |
| Push CI (fast gates) | 39216776100 and the pushes after | Green |
| Deploy with the full suite | 39217352982, 39221370508 | Not deployed: four end-to-end specs failed on a fixture of this work (the home address put in the role row), then the crawl found 135px of overflow at 375 on /va/sign (the signing summary's columns); both fixed |
| Deploy with the full suite | 39226299215 | Fast and full green (205 end to end passed, 15 skipped by design; crawl, SEO, emails 0 problems); migration 0059 applied (history 59); deployed |
| The queue on the live database after the deploy | | 0 suggestions, 0 notes; the three 0058 chapters published; one stale suggestion dropped (audit log); 6 sections pending for the upkeep; Sales defaults commission only |
| Guides after the deploy (auto) | 39231065485 | Green: 9 screenshots replaced (the assistant's customer service screens), 8 sections rewritten and published (the 6 pending ones among them), 0 kept for the next run; PDFs of the VA, owner and investor guides |
| guides-pdf (admin, field, renter) | 39234247717 | Green: the stored PDFs of the guides 0059 changed |
| verify, full | 39235995894 | Green: every check passed |
| verify, full, before it | 39234437070 | Failed on the Admin sign-in and the owner sign-up while the Worker answered Error 1102 (12 requests in the run; 290 in 24 hours); no failure on a page this work changed |

**Error 1102 (separate).** Cloudflare's free plan CPU limit, as in the last releases. Workers Paid removes it.

**Working tree.** Another agent's unfinished 0060 commit (live chat) was in the shared local main; it was never pushed.
This release was pushed from a branch holding only 0059's work; 0060 lives on its own branch.

## 7. What still needs the owner

- **The lawyer**: VA agreement 3.1 (commission only), 3.2 and 7.4, and the new Pay row of Schedule A.
- Staff on the platform before this release enter their home address at their next sign-in; until then their
  commissions wait as not earned yet.
- Nothing to review in Admin > Settings > Guides, by design.
