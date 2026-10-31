# The owner pipeline (0217)

Abbas's request (Release 22, item 4): owner recruitment that follows up by itself. Migration
`supabase/migrations/0217_owner_pipeline.sql`. Code: `web/src/features/owner-pipeline/`,
`web/src/app/admin/marketing/owner-pipeline/page.tsx`, `web/src/app/staff/owner-pipeline/page.tsx`,
`web/src/server/actions/leads.ts`, `web/src/app/r/[code]/route.ts`. Tests: `supabase/tests/99_owner_pipeline.sql`,
`web/src/features/owner-pipeline/model.test.ts`, `web/tests/e2e/release-22.spec.ts`.

- One pipeline for every prospective owner: the website owner form, an owner's referral link, classified ads (Owner
  recruitment, 0167) and leads added by hand. Stages: new, contacted, call booked, agreement sent, signed, car onboarded,
  lost. Agreement sent, signed and car onboarded also follow the owner's records (every 15 minutes).
- Follow-ups on day 0, 2, 5 and 10 (`program_settings.owner_followup_days`, on by default), worded from the owner
  program guide (fleet insurance policy, rented out in Toronto, paid monthly, fees apply), through `owner_recruit_outreach`
  (marketing class 5: the sending hours, the unsubscribe link, the lowest priority under the cap). Only with consent: a
  website inquiry (6 months), a classified lead's consent log, one message for a staff-typed referral. Stops on a reply
  (a text or call from the lead, or They replied), any stage change, an unsubscribe and after the last step. The leads
  already on file are not followed up.
- Owner referrals: `/r/<owner code>?to=owner` opens the owner program page; the cookie credits the referring owner on the
  lead. The credit follows the referral kickback rule (0007): the Kickback Rate (20%) of the Rental Charge of the first
  completed rental of the new owner's car; Admin marks it paid with the payout. Every active owner now has a code.
- Admin > Marketing > Owner pipeline; staff working as Sales or Customer service: Owner pipeline in the staff portal (no
  referral credits).

## Guides

- `admin/advertising-and-owner-recruitment`: Owner pipeline, owner referral links.
- `va/sales`: Owner pipeline.
