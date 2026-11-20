# Staff rewards, owner rewards, the content calendar, notification preferences and owner tracker alerts (Release 48 RW: 3260 to 3265, 3269)

Migrations `3260_r48rw_notify_prefs.sql`, `3261_r48rw_staff_rewards.sql`, `3262_r48rw_owner_rewards.sql`,
`3263_r48rw_content_calendar.sql`, `3264_r48rw_owner_tracker_alerts.sql`, `3265_r48rw_doors.sql` and
`3269_r48rw_guides.sql` (generated blocks: `supabase/seed/3269_gen.mjs`).

The owner (Nov 20): staff should get something for the work (12:04, 12:06); owners should get rewards, and merch only when
they press a button (12:54, 12:57); a content calendar staff approve (11:35); owners alerted by the tracker (13:02); and
everyone chooses their own notifications (13:03).

## Changes

### Notification preferences (3260)

- **Everyone chooses**: renter and owner (Account > Notifications), staff, Field, investor and Admin (Profile), partner (the
  portal link) and the app (`me.notifyPrefs`, `me.notifyPrefsSave`). One switch per kind and channel (push, email, text),
  quiet hours, and instant, a daily summary or a weekly summary (`notify_types`, `notify_prefs`, `notify_profiles`).
- **Always sent** (locked, the switch is not offered and the database ignores a stored choice): security and sign-in codes,
  legal and agreement notices, charges and fees, receipts, statements and payouts, booking confirmations and changes,
  pickup and return reminders, safety and incident messages; for staff the jobs and shifts assigned to them and
  onboarding, access and suspension notices.
- **Where it is enforced**: in the database, on the three queues (`notification_outbox`, `push_outbox`, `phone_outbox`), so
  every sender obeys it. An optional email under a summary cadence is held (`notify_digest_items`) and sent as
  `notify_summary`. Optional push and texts wait for the end of quiet hours.
- **A text that cannot go still falls back to email** (3113), whatever was chosen for email.
- **Today's defaults stay**: each kind starts as it was sent before this release. Migrated: `users.staff_notices_off`
  (Dwight Laird) is **Turn every optional notification off**; the emails muted under 0018 and the push topics turned off
  are per-kind choices. Owners are still not told about new bookings: the three owner booking emails are back in the
  catalogue behind the kind **New bookings on your cars**, off unless the owner turns it on.
- **Admin > Settings > Notification preferences**: what each kind starts as, the locked kinds, each person's choices
  (changes logged), and the places watched for tracker alerts.

### Staff rewards (3261)

- **My rewards** card on the staff and Field first pages, with a page each (`/staff/rewards`, `/staff/field/rewards`).
- 15% off own rentals once the academy and the agreement are done; 1 free day per 100 rental days booked (Sales) and per
  100 handovers (Field); Silver at 50 booked days in a month (20%), Gold at 100 (25% and 1 bonus day); the month's top
  seller gets a free weekend.
- **Only in-person staff in Canada.** VAs, international and remote staff get no rental perks; the card says so. An Admin
  can switch one person on or off with the reason.
- The rules are checked where every promo code is checked (`app.promo_code_problem`): the staff member is the primary
  driver; no exotic or partner cars; pickup within 48 hours of booking and never over a paying renter's request or
  booking; free days end after 6 months; a suspended account's perks are frozen.
- Free days go on company and shareholder cars first. On a co-host owner's car the owner is paid as at the full rate
  (the code is company funded). Each perk used is posted as a **Staff benefit** expense (account 5300, `reward_postings`).
- Counting starts on `staff_perk_count_from` (2026-11-01). Handovers are field jobs of kind handover and delivery.
- **Admin > People > Team > Staff rewards**: everyone's state, switch perks, add free days.

### Owner rewards (3262)

- **Rewards** tab on the owner portal (`/owner/rewards`): 20% off another fleet car while the owner's car is on rent, in
  service or in a claim; **Ask for a free upgrade** when CarmaCars caused the repair (an Admin approves); a friends and
  family code, link and QR code (10% off the friend's first rental; the owner earns the existing 20% kickback); $100
  credit for referring an owner once the new car has been live 30 days; a $25 birthday rental credit; priority support
  and early access.
- **Merch kits** at 6 and 12 months are never sent by themselves: the owner presses **Redeem**, confirms the address, an
  Admin To do says to ship it, and the owner sees **Shipped** with the tracking number.
- Credits are `owner_credits` of kind `reward_credit` (a statement line) and are posted to account 5310.
- The owner-referral kickback of 0217 is unchanged; the $100 credit is in addition to it.
- **Admin > People > Owners > Owner rewards**: kits to ship, upgrades to answer, add a credit.

### Content calendar (3263)

- Extends `social_drafts` (0167) and `social_queue` (2220). Each month a calendar is written (`social_calendars`): content
  pillars, a mix of reels, carousels, photos and stories, an opening line, caption, hashtags, the best time per channel
  and a music suggestion. `web/src/features/social/calendar.ts` writes it; the ads job stores it.
- **Nothing is published without approval.** Marketing staff (Sales, customer service, Fleet) and Admins approve, edit,
  reject or regenerate each post (`/staff/marketing/calendar`, `/admin/marketing/calendar`, a month grid from tablet
  width). The queue refuses a calendar post that is not approved and raises an alert if one is found.
- Approved posts go to `social_queue` at their best time: Facebook Page and Instagram by themselves when Meta is
  connected; TikTok, stories and carousels are a download and a checklist (`by_hand`), with an alert when due.
- Comments and direct messages follow the existing AI reply rules (no new rules).
- Performance comes back per post (`social_post_stats`: Meta insights for posts Meta published, **Add results** for posts
  made by hand) and steers the next month's pillars, formats and hours.
- While the calendar is on, the weekly social drafts are not written.

### Owner tracker alerts (3264)

- Wait for `trackers_available`; until then the owner sees each alert as "starts when your tracker is installed" and the
  choice is kept.
- Real time: at an impound lot, auto shop or shipping port (`tracker_places`, added by an Admin; none are seeded), possible
  theft, tracker disconnected or tampered with, crash or impact, vehicle health, over 180 km/h. Weekly: driving behaviour
  and kilometres against the allowance (`owner_tracker_weeklies`).
- Every one is a switch in the owner's notification preferences. The alert names the car and what happened, never the
  renter or the booking.
- The ingest accepts `event` on a point (`docs/tracker-ingest.md`).

### Emails

`notify_summary`, `staff_reward_update`, `owner_reward_update`, `owner_tracker_alert`, `owner_tracker_weekly`.

## Owner steps

1. Program settings > **Staff rewards**, **Owner rewards**, **Content calendar**: read the values and change any.
2. Admin > People > Team > **Staff rewards**: check who is marked in person in Canada.
3. Admin > Settings > **Notification preferences** > **Places watched**: add the impound lots, auto shops and ports (used
   once trackers are live).
4. Connect Meta (Marketing > Ads) for Facebook and Instagram to post by themselves; until then every approved post is a
   download and a checklist.

## Guides

- `renter/after-your-trip`
- `owner/rewards`
- `owner/notices-profile-and-leaving`
- `investor/profile-and-notices`
- `va/shared-tools`
- `va/content-calendar`
- `field/report-rentals-referrals-and-profile`
- `admin/people-and-access`
- `admin/owners-and-onboarding`
- `admin/advertising-and-owner-recruitment`
- `admin/settings`

Published by 3269 (generated by `supabase/seed/3269_gen.mjs`).
