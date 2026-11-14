# An Admin shows a lead's phone to a salesperson (Release 46: 2870 to 2872)

Migrations `2870_r46_lead_phone_unlock.sql`, `2871_r46_guides.sql` and `2872_r46_academy.sql`.

Since 0970 a person working as Sales is shown customer numbers masked and calls through the business line (the browser call of 2790). An Admin can now unlock the full number of one lead for one salesperson.

- **Show the phone to** (Admin, on the lead's page and on its card in the lead list): shows the lead's full number to its salesperson (assigned, else the person holding its claim). On the lead's page the Admin can choose another Sales person and type a reason. Each unlock is a row of `lead_phone_unlocks` and an `audit_log` row (`lead_phone_unlock`: who, when, for whom, the reason).
- **The one rule**: `app.phone_unlocked_for(user, number)` (an unlock still on, for a lead whose phone is still that number). The masking of 0970 (`app.mask_phone_text`, used by every read through the door and by the Sales alerts) and the caller names of 2790 (`server_voice_ring`, `server_twilio_browser_call_start`) skip such a number. So the salesperson sees it in full on that lead's page, its card in the lists, the lead's whole person, the call pop-ups and anything read from that lead, with a call link and **Copy**. Every other lead stays masked; another salesperson still sees it masked.
- **The salesperson is told**: a bell alert (staff alert `lead_phone_shown`, to that person only, deep link to the lead, no number in it); their ask To do closes.
- **Every Admin lead view**: the lead page, the lead cards (Sales leads, Owners > Leads, Renters > Leads) and the Expired offers rows of Renters > Leads (read `lead_phone_state`, Admin only).
- **Same number, same person**: the rule is by number, so the same number on that person's other records (their renter record, another lead with that phone) shows in full to that salesperson too; the guides say so.
- **Hide it again** (Admin): hides it again, audited (`lead_phone_hide`).
- **Reassignment**: when the lead's `assigned_to` changes, or another salesperson claims it, every other person's unlock is hidden by itself (`hidden_why = reassigned`, audited). The new salesperson sees it masked until an Admin shows it to them. A new phone on the lead is masked again too.
- **Ask an Admin to show the number** (Sales, on a masked lead): one Admin To do per lead (`lead_phone_ask`, opens the lead). On Admin > Today it has **Show the phone**, which shows it to the one who asked; showing the number closes the To do.
- **Masking on every read**: the masking now runs once on the outermost door. Reads added by wrappers after 0970 (the lead's whole person of 2411 among them) returned numbers to Sales unmasked; they are masked like every other read.
- **Academy**: one question in "Calls in the browser" on getting a lead's whole number.

## Guides

`va/sales`, `admin/leads-and-sales-claims` (migration 2871).
