# Guide me: workflows per role

Every workflow is a step file in `web/src/features/guide-me/flows/` (data-guide targets, one instruction a step, the condition that completes it). `engine.test.ts` fails when a step names an element no code carries or a guide chapter that does not exist. Generated from the step files; keep it in step when adding one.

## Admin

- **Your academy** (`academy`, 2 steps): Lessons and a quiz per section of your path; pass them to claim shifts.
- **Approve an owner's car** (`approve-owner-car`, 11 steps): Read the application, set the four checks, then Approve and confirm the car's terms and first invoices.
- **Answer a booking request** (`booking-request`, 5 steps): The request waiting longest first: review the renter, dates and car, then send the offer.
- **Send an offer to a renter** (`create-offer`, 8 steps): Renter, dates, car, coverage, then send: the renter gets the link to approve, sign and pay.
- **Follow up a lead** (`leads-follow-up`, 3 steps): Open a lead, text or call them, and note what happened.
- **Car maintenance** (`maintenance-check`, 3 steps): What is overdue, each car's service and the odometer.
- **Marketing: your posts** (`marketing-day`, 4 steps): The cars to post, what is due and the social queue.
- **Payments by day** (`payments-day`, 3 steps): Filter by dates and methods, check the totals and export them.
- **Pickup handover** (`pickup-handover`, 9 steps): Check in: the ready check, the renter, odometer, fuel and keys, the photos, damage, then sign and hand over the keys.
- **Record an e-Transfer or another payment** (`record-payment`, 6 steps): On the booking's Money tab: Collect the rental, choose Cash, e-Transfer or another way, and record it.
- **Find a renter** (`renter-lookup`, 2 steps): Search a renter, see their rentals, notes and documents.
- **Return handover and deposit review** (`return-deposit`, 13 steps): Check out the car (odometer, fuel, photos, damage compared with pickup), then Fleet and Finance review the deposit.
- **Import toll and ticket notices** (`tolls-import`, 3 steps): Import the toll operator's file, then match each notice to its booking.

## Customer service

- **Your academy** (`academy`, 2 steps): Lessons and a quiz per section of your path; pass them to claim shifts.
- **Approve an owner's car** (`approve-owner-car`, 11 steps): Read the application, set the four checks, then Approve and confirm the car's terms and first invoices.
- **Answer a booking request** (`booking-request`, 5 steps): The request waiting longest first: review the renter, dates and car, then send the offer.
- **Send an offer to a renter** (`create-offer`, 8 steps): Renter, dates, car, coverage, then send: the renter gets the link to approve, sign and pay.
- **Follow up a lead** (`leads-follow-up`, 3 steps): Open a lead, text or call them, and note what happened.
- **Find a renter** (`renter-lookup`, 2 steps): Search a renter, see their rentals, notes and documents.
- **Your first days** (`staff-onboarding`, 4 steps): Your agreement, the WhatsApp groups, the academy, then your first shift.
- **Your pay details** (`staff-pay-details`, 2 steps): Choose how you are paid; an Admin confirms new details with you.
- **Your hours** (`timesheet`, 2 steps): The hours you clocked, by day and period.

## Sales (and Marketing)

- **Your academy** (`academy`, 2 steps): Lessons and a quiz per section of your path; pass them to claim shifts.
- **Answer a booking request** (`booking-request`, 5 steps): The request waiting longest first: review the renter, dates and car, then send the offer.
- **Send an offer to a renter** (`create-offer`, 8 steps): Renter, dates, car, coverage, then send: the renter gets the link to approve, sign and pay.
- **Follow up a lead** (`leads-follow-up`, 3 steps): Open a lead, text or call them, and note what happened.
- **Marketing: your posts** (`marketing-day`, 4 steps): The cars to post, what is due and the social queue.
- **Your first days** (`staff-onboarding`, 4 steps): Your agreement, the WhatsApp groups, the academy, then your first shift.
- **Your pay details** (`staff-pay-details`, 2 steps): Choose how you are paid; an Admin confirms new details with you.

## Fleet

- **Your academy** (`academy`, 2 steps): Lessons and a quiz per section of your path; pass them to claim shifts.
- **Approve an owner's car** (`approve-owner-car`, 11 steps): Read the application, set the four checks, then Approve and confirm the car's terms and first invoices.
- **Car maintenance** (`maintenance-check`, 3 steps): What is overdue, each car's service and the odometer.
- **Pickup handover** (`pickup-handover`, 9 steps): Check in: the ready check, the renter, odometer, fuel and keys, the photos, damage, then sign and hand over the keys.
- **Find a renter** (`renter-lookup`, 2 steps): Search a renter, see their rentals, notes and documents.
- **Return handover and deposit review** (`return-deposit`, 13 steps): Check out the car (odometer, fuel, photos, damage compared with pickup), then Fleet and Finance review the deposit.
- **Your first days** (`staff-onboarding`, 4 steps): Your agreement, the WhatsApp groups, the academy, then your first shift.
- **Your pay details** (`staff-pay-details`, 2 steps): Choose how you are paid; an Admin confirms new details with you.
- **Your hours** (`timesheet`, 2 steps): The hours you clocked, by day and period.

## Finance

- **Your academy** (`academy`, 2 steps): Lessons and a quiz per section of your path; pass them to claim shifts.
- **Approve field expenses** (`field-spending-review`, 2 steps): Each expense with its receipt and whose money paid: approve or decline with the reason.
- **Payments by day** (`payments-day`, 3 steps): Filter by dates and methods, check the totals and export them.
- **Run payroll** (`payroll-run`, 4 steps): Check the period's hours and pay, then prepare the run.
- **Record an e-Transfer or another payment** (`record-payment`, 6 steps): On the booking's Money tab: Collect the rental, choose Cash, e-Transfer or another way, and record it.
- **Find a renter** (`renter-lookup`, 2 steps): Search a renter, see their rentals, notes and documents.
- **Return handover and deposit review** (`return-deposit`, 13 steps): Check out the car (odometer, fuel, photos, damage compared with pickup), then Fleet and Finance review the deposit.
- **Your first days** (`staff-onboarding`, 4 steps): Your agreement, the WhatsApp groups, the academy, then your first shift.
- **Your pay details** (`staff-pay-details`, 2 steps): Choose how you are paid; an Admin confirms new details with you.
- **Your hours** (`timesheet`, 2 steps): The hours you clocked, by day and period.
- **Import toll and ticket notices** (`tolls-import`, 3 steps): Import the toll operator's file, then match each notice to its booking.
- **Import Turo trips** (`turo-trips`, 2 steps): Import the Turo earnings file so each trip is on the car's money.

## Field work

- **Your academy** (`academy`, 2 steps): Lessons and a quiz per section of your path; pass them to claim shifts.
- **Log a field expense** (`field-expense`, 7 steps): Add, Money spent: what for, the amount, whose money paid, the receipt photo, then Send to Finance.
- **My pay** (`field-pay`, 3 steps): Hours so far, your pay statements and how you are paid.
- **Claim and manage shifts** (`field-shifts`, 4 steps): Your week, open shifts to claim, and your availability.
- **Pickup handover** (`pickup-handover`, 9 steps): Check in: the ready check, the renter, odometer, fuel and keys, the photos, damage, then sign and hand over the keys.
- **Return handover and deposit review** (`return-deposit`, 13 steps): Check out the car (odometer, fuel, photos, damage compared with pickup), then Fleet and Finance review the deposit.
- **Your first days** (`staff-onboarding`, 4 steps): Your agreement, the WhatsApp groups, the academy, then your first shift.

## Owners

- **Add a car** (`owner-add-car`, 3 steps): Add another car: its VIN, then its photos and terms.
- **Apply to list your car** (`owner-apply`, 6 steps): Your name and contact, then the car's VIN; we check it and reply.
- **Your documents** (`owner-documents`, 3 steps): Your agreements, schedules and forms, signed copies to download.
- **Invoices** (`owner-invoices`, 2 steps): What you owe CarmaCars (insurance, fees), how it is paid and its status.
- **Statements and payouts** (`owner-money`, 3 steps): Each month's statement, what was paid out and when.
- **Complete your profile** (`owner-profile`, 3 steps): Your path to your first payout: the next step is always on top.
- **Sign your agreements** (`owner-sign`, 5 steps): Your agreement first, then each car's Schedule A, with one signature.

## Renters

- **Book a car** (`renter-book`, 6 steps): Dates and place, your details, licence and coverage, then send: instant booking or a request we answer.
- **Your deposit back** (`renter-deposit`, 3 steps): When the deposit is released, how much and when.
- **Pay by e-Transfer** (`renter-etransfer`, 5 steps): Send the e-Transfer with your booking number as the message, then upload the screenshot.
- **Extend a rental** (`renter-extend`, 3 steps): Choose the new return time, see the price, and pay for the extra days.
- **Add your driver's licence** (`renter-licence`, 4 steps): Your licence number and expiry, then the photos, so the car can be released at pickup.
- **Pickup day** (`renter-pickup`, 4 steps): Have your licence and card, check the car in with photos and the readings, and drive off.
- **Return the car** (`renter-return`, 2 steps): Bring it back on time with the fuel as you got it; see the return receipt for km and fuel.
- **Rewards** (`renter-rewards`, 4 steps): Your tier, your balance, your codes and how to earn more.
- **Sign and pay** (`renter-sign-pay`, 5 steps): Read and sign the rental agreement, then pay by card or e-Transfer.
- **Create your account** (`renter-signup`, 5 steps): Your name, email and a password; then confirm your email from the link we send.

## Investors

- **Your dashboard** (`investor-dashboard`, 2 steps): What you invested, the schedule and the live sheets.
- **Documents to sign** (`investor-documents`, 3 steps): Read and sign what is waiting, then find your files.
- **Your statements** (`investor-statements`, 2 steps): Each statement of your investment.

## Public site (anyone, not signed in)

- **Apply for a job** (`apply-job`, 3 steps): Answer the questions about the role and send the application.
- **Apply to list your car** (`owner-apply`, 6 steps): Your name and contact, then the car's VIN; we check it and reply.
- **Book a car** (`renter-book`, 6 steps): Dates and place, your details, licence and coverage, then send: instant booking or a request we answer.
- **Create your account** (`renter-signup`, 5 steps): Your name, email and a password; then confirm your email from the link we send.

## Follow-up

- Renters: the monthly check-in visit (branch `r51-checkins`) gets its step file once it is on `r50-int`.
