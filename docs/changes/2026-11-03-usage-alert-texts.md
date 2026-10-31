# Usage alerts by text, and the banner on Today (0221)

The owner did not know the Worker's CPU time was 36 times its allowance: the usage alerts of 0080 were emails to the
company address only, behind the day's email cap.

- When a figure of Settings > Usage reaches 80% of its included allowance, and again at 100%, every Admin with a verified
  phone gets a text from the CarmaCars Quo number (phone_outbox, the five-minute phone job). Once per figure and level a
  calendar month (a higher level covers a lower one), outside the site check's quiet hours. The Worker's CPU time warns at
  70% (the owner's choice), with its own 70% level. On by default: Program settings, usage_alert_texts. The alerts of
  this month not texted yet go once at the next run.
- Admin > Today: a banner at the top for every figure at its warning level or past it (red past 100%, amber before), not
  dismissible: it goes when the figure resets or the allowance is raised (ops_read usage_banner).
- Tests: `supabase/tests/99_release_23.sql` section 2.

## Guides

- `admin/usage-and-paid-usage`: Alerts by text and the banner.
