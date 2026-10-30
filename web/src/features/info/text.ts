// The words behind each "i" (Release 21b, item 7): short, plain, from the guides (docs/guides/content) and the policy in the
// database (site_facts, program_settings). A form field named like a key gets its "i" by itself (Act, SaveForm, the settings
// screens); any other place passes `k` to <InfoTip>. text.test.ts keeps every entry short, plain and free of long dashes.
export const INFO: Record<string, string> = {
  // money on a booking
  deposit: 'A refundable hold on the renter\'s card, taken about an hour before pickup (or cash or e-Transfer at the handover). The balance comes back within 7 business days of the return; an open toll, ticket or claim can be held back up to 30 days.',
  deposit_cents: 'The refundable deposit for this car or booking. It is held, not charged, and settled after the return: tolls, fuel, kilometres over and damage up to the deductible come off it first.',
  deposit_class: 'Which deposit tier the car uses ($500, $1,000, $2,500 or $5,000). Higher-value cars use a higher tier.',
  deposit_waiver_reason: 'Why the car goes out without a deposit. Every waiver is logged with your name and shows on the booking for an Admin.',
  deductible: 'The most a renter pays for damage to the car under our fleet policy: $2,500, plus a $75 administration fee for a claim. Damage under it is billed from the deposit first, then the card on file.',
  young_driver: 'A daily fee for younger drivers: $35 a day aged 18 to 20, $20 a day aged 21 to 25. Some cars set their own. From 26 there is no fee.',
  additional_driver: 'Each extra driver adds 25% of the daily rate and signs the agreement with their own link.',
  late_return: 'After a 30 minute grace period, a late return is $25 an hour. A renter running late should ask to extend before the return time.',
  mileage_overage: 'Kilometres over the allowance cost $0.35 a km, read from the odometer at pickup and return.',
  fuel: 'Return the car with the fuel it had at pickup. Less is charged at the pump price plus 25%, and a $25 service fee. A prepaid full tank means no fuel charge.',
  tolls_tickets: 'Tolls and tickets are the renter\'s. When one reaches us we pay it and charge the amount plus our fee ($15 a toll, $40 a ticket) to the card on file.',
  cancellation: 'Standard bookings: 95% back within 24 hours of booking (48 hours or more before pickup), 75% from 48 hours before, 50% from 24 to 48 hours, nothing under 24 hours. Non-refundable bookings get nothing back.',
  non_refundable: 'Non-refundable: 10% off the rental charge, but no refund if the renter cancels.',
  hst: 'Ontario HST, 13%, on each line that carries it. Tolls and tickets at cost carry none.',
  // coverage
  coverage: 'How damage to the car is covered: Option 1, OPCF 27 on the renter\'s own auto policy; Option 2, the rental coverage of the credit card they pay with; Option 3, the CarmaCars Protection Plan. It can change any time before pickup.',
  opcf27: 'OPCF 27 is an Ontario endorsement on the renter\'s own auto policy that covers a car they rent. Proof: the insurer, the policy number, an expiry after the return date and the page that shows OPCF 27.',
  card_coverage: 'The renter pays with a credit card in their own name that includes rental car coverage (debit and prepaid cards are refused). Many cards stop at a car worth $65,000 or $85,000; the card\'s issuer decides a claim.',
  protection_plan: 'The CarmaCars Protection Plan: a daily charge that covers damage to the car on our fleet policy. The renter still owes the deductible on a claim.',
  insurer_name: 'The company that insures the renter\'s own car (Option 1), as on their policy.',
  policy_number: 'The policy number as printed on the renter\'s insurance slip or policy.',
  policy_expiry: 'When the renter\'s policy ends. It must be after the return date.',
  // insurer-billed rentals
  bill_to: 'Who pays the rental. Renter: the renter pays everything. An insurer: the insurer pays the rental (or everything) at the daily rate the adjuster authorized, and the renter owes only what it does not cover.',
  payer: 'Who pays this bill: the renter, the owner, the insurer, or CarmaCars.',
  claim_id: 'The insurer\'s claim number for this loss. It goes on every insurer invoice and email.',
  claim_number: 'The insurer\'s claim number for this loss. It goes on every insurer invoice and email.',
  adjuster: 'The adjuster handling the claim at the insurer. Email the adjuster writes from Blind Spot Car Rental to this address.',
  authorized_daily_rate: 'The daily rate the adjuster authorized. A rate different from the insurer\'s rate on file needs a reason.',
  vlf_daily_cents: 'VLF (vehicle licence fee): a daily charge billed to the insurer on insurer-billed rentals, as its own line on the invoice. 0 is off.',
  insurer_pays: 'Everything: the insurer pays the whole invoice. Rental only: the insurer pays the days at the authorized rate and the renter pays the rest (fees, add-ons, deposit).',
  // owners
  revenue_share: 'Revenue Share (the management fee): the share of each rental\'s revenue CarmaCars keeps. The owner gets the rest on the monthly statement. A higher share applies only once the owner signs an updated Vehicle Schedule.',
  commission_bps: 'The share of the rental charge kept as commission. Empty uses the default in Program settings.',
  pay_model: 'How the owner is paid for a car: Revenue share (a share of each rental, less the insurance and tracker fees) or Flat monthly (a fixed amount each month, no fees, no revenue share). Flat-rate owners sign the Flat-Rate Enrollment Agreement.',
  insurance_fee: 'The owner\'s monthly insurance fee for this car, due every month whether it rents or not. Debited on the 15th after a notice.',
  tracker_fee: 'The monthly tracker fee for this car, from the day its tracker is installed.',
  fees_paid_from: 'Where the owner\'s monthly fees come from: their payout (taken off the statement) or a debit from their bank on the 15th.',
  above_terms: 'Above the signed terms: only an Admin, with a reason. The owner sees it on the booking and on the statement.',
  first_last_month: 'Paid before a car goes live: usually two months of the insurance fee, or the exact amount agreed.',
  // partners and referrals
  markup_bps: 'Added on top of the partner\'s price before the renter sees it.',
  cut_bps: 'The partner\'s share of each rental of this car.',
  rate_kind: 'Flat: a fixed amount for each completed rental ($50 by default). Percent: a share of the rental charge after discounts (10% by default), never of add-ons, fees or taxes.',
  // staff and pay
  functions: 'What the person works on: Customer service, Fleet, Finance, Sales, Field work. Each adds its menu group in the staff portal and its training path; a person can hold several and switch with Working as.',
  sales_work_mode: 'In person: the standard Sales tiers. Remote: the remote tiers, an activity minimum of touches each month and peak hours to cover.',
  commission: 'Commission is a share of the rental charge of the rentals you close. Sales in person: 10%, 15% from 50 rental days in the month, 20% from 100. Remote Sales: 5%, 10%, 15%. Other staff: 10%. Admin can change the rates.',
  request_claim: 'Opening a request to answer it holds it for you (20 minutes, renewed while you work). A new request goes to Admins, customer service and fleet first; Sales may take it after 15 minutes.',
  staff_commission_bps: 'Commission for customer service, finance, fleet and field staff on the rentals they close, as a share of the rental charge.',
  sales_tier_low_bps: 'Sales commission on the month\'s rentals below the middle tier\'s rental days.',
  sales_tier_mid_bps: 'Sales commission once the month reaches the middle tier\'s rental days.',
  sales_tier_high_bps: 'Sales commission once the month reaches the top tier\'s rental days (the month\'s target).',
  request_claim_minutes: 'Opening a request to answer it holds it for this long, renewed while the person works. After that anyone can take it.',
  request_sales_after_minutes: 'A new request goes to Admins, customer service and fleet first. After this many minutes Sales may take it too.',
  staff_may_edit_fees: 'On: customer service and sales may change a fee on one booking (young driver, Protection Plan, delivery, add-ons). A price far under the rate sheet is flagged for an Admin.',
  single_limit_cents: 'The largest refund or charge this person may make on their own. Above it an Admin approves.',
  // discounts
  discount_scope: 'What the discount comes off: the rental charge only, never add-ons, fees, the deposit or taxes. A percentage code is capped (for example $75).',
  // settings
  academy_gate: 'Off (the default): the academy only tracks progress. On: a staff member must pass their path before the parts of the portal it covers open.',
  deposit_release_reminder_days: 'With no check-in recorded, a deposit is due back this many business days after the return, and Finance gets a reminder.',
  take_deposit_lead_minutes: 'How long before pickup the deposit hold is taken on the card on file.',
  offer_expiry_hours: 'How long an offer stays open. An offer does not hold the car: the first to pay gets it.',
  owner_lower_share_without_signature: 'On: a lower management fee applies from the notice date without the owner signing. Off: they sign an updated Vehicle Schedule first.',
  // investors
  deck_return_bps: 'The yearly return shown in the investor deck\'s example. Each investor\'s own Yearly Percentage is in their agreement.',
  returns_mode: 'Paid monthly: each month\'s return goes to your bank account on the 15th. Reinvested: it is added to your Invested Amount and earns a return from then on.',
  lockup_end: 'No return is earned during the lockup period. Your first Return Month starts on the Lockup End Date.',
  invested_amount: 'What is earning a return: your principal, plus returns reinvested, less amounts redeemed.',
  yearly_percentage: 'The return your agreement sets for a year, paid month by month on the amount at the start of each month.'
};

/** The text of a key, or undefined. */
export const infoText = (k: string): string | undefined => INFO[k];
