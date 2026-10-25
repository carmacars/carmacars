# Field staff pay, vehicle class rules, and a signed car's Management Mode, October 25, 2026

Three gaps found after release 9. Migration `supabase/migrations/0165_field_pay_class_rules_mode.sql`
(SCHEMA_MARKER `0165`). Every function it changes is wrapped (renamed `_pre0165`, then recreated); no applied
migration is edited. The functions it adds are reachable only through the door (`ops_read` / `ops_do`), as the other
money and settings screens are.

## 1. Field staff pay

CA$18.00 an hour, paid every two weeks, was only a line of the field staff agreement defaults (0057). Now it is built.

**Hours.** Table `field_shifts` (one open shift per person; a shift is never deleted, it is voided). On the field phone
portal, **My hours** (`/field/hours`, in the field menu) has two big buttons, **Clock in** and **Clock out**, an optional
note on each, a running clock, and the jobs done during the shift listed under it. Fleet (`/va/field-hours`) or an Admin
(`/admin/money/field-pay`, tab Hours) enter hours for someone who forgot, change a shift, or clock someone out. Every
change after the fact needs a reason and is written to `field_shift_edits` (what it was before and after, who, when).
The database refuses overlapping shifts of one person, a shift in the future, a shift longer than the setting (16 hours),
and any change in a pay period whose run is approved.

**The pay period** is two weeks from `program_settings.field_pay_anchor`. The anchor is a Program setting (Settings >
Program, Field jobs and handovers); the migration sets it to the most recent Sunday strictly before the day it runs, so
periods run Sunday to Saturday. A pay run keeps its own dates and settings, so changing the anchor later does not
move a run already made.

**The rate.** `staff_profiles.hourly_rate_cents` per person; empty means the default `field_default_hourly_cents`
(CA$18.00). An Admin sets a person's rate in Field pay > Hourly rates with a reason (logged). A run takes the rate when it
was started.

**The pay run** (Admin only, Money > Field pay):

- Start the run of a period (only once it has started; **Approve** only after it has ended): one line per person with
  hours or commissions, hours times rate, plus the staff commissions and referral fees approved by the end of the period
  and not yet paid (the existing `staff_commissions`; the old kickback payroll tables are not used). Commissions that
  net to nothing or less (a clawback larger than the commissions) are not paid that period and carry to the next.
  Deductions: none.
- Refresh while a draft; **Approve** freezes the figures, locks the period's shifts, numbers each statement (`PS-1001`...)
  and is refused while someone is still clocked in from the period. **Withdraw** a draft or an approved run that has no
  payment recorded.
- **Record payment** on each line: e-Transfer, bank transfer or cash, the reference (required except for cash) and the
  date. Its commissions are marked paid in the same step, through one `staff_commission_payouts` row of method
  `pay_statement`, so Staff commissions and the owner statements see them as paid. When every line is paid the run is paid.
  Nothing is paid or charged automatically.
- **Pay statement** per person: PDF kind `pay_statement` (`/files/pay_statement/<line id>`; the person, an Admin and
  Finance may open it): hours day by day, the amounts, the commissions in it, how it was paid. The person gets the email
  `staff_pay_statement` when the payment is recorded (Send again on the line repeats it). Field staff see their hours, the
  pay so far this period and their statements under My hours.
- **CSV** of the run for the accountant (`/admin/money/field-pay/csv?run=...`, Admin only).

**Settings (all in Program settings).** Overtime is off (`field_overtime_on`); when on, hours past `field_overtime_weekly_hours`
(44) in a seven-day week of the period are paid at `field_overtime_bps` (150%). Vacation pay is off
(`field_vacation_pay_bps` 0); when set (Ontario: 4%), that share of wages, overtime and commissions is added to each
statement.

**Ontario note for the accountant.** Vacation pay (4%) and the statutory deductions (income tax, CPP, EI, and the
employer's EHT and WSIB) are not computed. Vacation pay is a setting that is off; the deductions are not modelled at all and
the statement says so. Whether field staff are employees or contractors, and how vacation pay is to be paid, are for the
accountant to decide before the first pay run. Public holiday pay is not modelled either.

## 2. Vehicle class rules

The VIN-first entry (0082, see `2026-10-21-vin-first-entry.md`) decides a new car's class from `vehicle_class_rules`, which
had no screen. **Settings > Vehicle class rules** (`/admin/settings/class-rules`) lists the rules (rank, what the car
must be, the class, the older class and the age, the note, on or off), and adds, changes, switches off and deletes them.
The database validates every save: at least one condition (a rule with none would match every car), a rank from 1 to 999, a
class, years old and the older class together and different from the class, a note, and every pattern must compile
(the same engine matches it against a car). Each add, change and delete writes an audit entry with before and after. **Try a
car** (year, make, model, trim, body) shows the class the rules decide and why. A rule changes cars entered from then on; a car
already listed keeps its class. 0082 said a rule is turned off, never deleted: Delete exists and is audited; switching off
is the way to keep one.

## 3. Changing a signed car's Management Mode

On the car's row (Cars and terms, on the owner page and the car page), **Change mode** (Admin only; shareholder-owned
cars have fixed terms and are refused). It follows the 0135 owner terms flow and reuses `vehicle_term_changes`
(a new kind `mode_change`), `schedule_change_*` (the owner signs an updated Vehicle Schedule, in the portal or on paper),
`ct_car` and the History list, the notice PDF, and the cancel action.

- **Review** first (nothing written): the values before and after, whether the owner must sign, the earliest date.
  Managed to Self-Managed: no management fee. Anything to Turo-Only: no Fees and no management fee, and the car is taken
  off the fleet insurance policy (`on_fleet_policy`) when it applies; the review says to tell the insurer. From Turo-Only, the Insurance and Tracker Fees
  come from the standard grid unless typed; to Managed, the management fee does too.
- **The owner asked** (a box, with the reason) **and no amount goes up**: no signature and no notice period. It is
  dated; today means at once (the car moves, an updated schedule is issued with CarmaCars' signature, `owner_mode_change_notice`
  is emailed); a later date is noticed now and applied on its date by `app.job_mode_changes` (pg_cron, hourly; a no-op
  where the extension is absent). 
- **Against the owner** (CarmaCars starts it, or a fee or the share goes up): the owner is emailed
  `owner_mode_change_notice` with an updated Vehicle Schedule to sign, the date is at least `fee_change_notice_days` (30)
  ahead, and the car stays as it was until it is signed. Signed after its date: it applies the day it is signed (never
  back-dated). The owner's page shows it with the usual "Updated Vehicle Schedule to sign" link; the text signed says the
  mode and method.
- **Cancel** (History, with a reason) works for a change that has not started: noticed or awaiting signature. The
  owner is now emailed in every such case, for a Management Mode change and for a noticed fee change
  (`owner_fee_change_cancelled`: what was going to change and that their terms stay as they are). Before, a cancelled
  fee notice told the owner nothing.
- The car's mode is held on the vehicle row, the signed schedule and the fee history together (`mc_sync_vehicle`); the
  schedule's own checks (Self-Managed has no management fee, Turo-Only has no fees) hold on the new schedule.

## Emails and texts

Three new emails in the catalogue (`emails/src/emails/`, built into `emails/templates/`; 184 now): `owner_mode_change_notice`,
`owner_fee_change_cancelled` (owners; each also has a text, 118 texts now) and `staff_pay_statement` (field staff; email
only). Link path `field_hours`. `0165_gen_catalogue.mjs` generates the catalogue block of the migration.

## Tests

- `supabase/tests/99_field_pay_rules_mode.sql` (134 checks): settings and periods, clock in and out, the office's entries and
  edits with their reasons and log, overlap and limits, locked periods, rates, overtime and vacation pay on and off,
  commissions in the run and their payout, approve, payment, statement facts and who may open it, the email, the CSV,
  who may do what, the class rules (every validation, add, change, switch off, delete, audit, the test), and the mode change
  (at once, dated, against the owner, paper signature, the job, cancel, the emails and their recipients, fee notice cancel).
- `07_notifications.sql` (184 emails, 78 link paths, the three new codes built, promo expiry consent kept), `71_text_alerts.sql`
  (118 texts), `03_flows.sql` (the new tables are audited; the shift log is itself a log).
- Unit: `web/src/features/field-pay/model.test.ts` (hours, money, CSV, class rule checks).
- End to end: `web/tests/e2e/field-pay.spec.ts` (clock in and out on the phone, Fleet sees the hours, an Admin starts,
  approves and pays the run, the statement PDF, the CSV, the field staff member sees the statement).

## Not done

- Statutory deductions, vacation pay by default, public holiday pay and the employer's remittances (see the Ontario note).
- No direct deposit or payment through a processor: the payment is recorded by hand, as for commissions.
- GPS or location checks on clock in, and approval of a shift by a manager: not requested.
- The owner is not asked to sign a Management Mode change that they asked for, as with a lower fee (0135); a paper or
  electronic request from the owner is the Admin's reason.

## Guides

`docs/guides/src/guides/admin.py`, `field.py`, `va.py` and `docs/guides/content/admin.json`, `field.json`, `va.json` changed by
hand (export.py needs the screenshots manifest, which is not in this checkout; the PDFs are rebuilt by the guides run after the
deploy):

- `field/my-hours-and-pay`: new chapter: clock in and out, your pay and your pay statements.
- `field/my-jobs`: the menu lists My hours. `field/quick-reference`: My hours and "Start and end work".
- `admin/owner-money`: new task "Field pay" (pay run, hours, rates, the settings, what is not computed).
- `admin/owners-and-onboarding`: new task "Change a signed car's Management Mode".
- `admin/settings`: new task "Vehicle class rules", the tile list, and the Field pay values under Program settings.
- `admin/getting-around-admin`: Money menu lists Field pay.
- `va/fleet`: new task "Field hours" and the rail. `va/your-workday`, `va/quick-reference`: Field hours.

`0165_field_pay_class_rules_mode.sql` publishes the ten chapters (`supabase/seed/0165_gen_guides.mjs`, with the base set to the main branch)
where the live text is still ours and keeps them as suggestions where an Admin edited one.
