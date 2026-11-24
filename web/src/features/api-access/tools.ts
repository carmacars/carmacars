// API access (release 28, B3; migration 0562): the tools the MCP connector and the API offer, with the scope each needs
// and its input, described for Claude. The database (app.api_call) is the one place that runs them and decides; this
// list only describes them. Pure, so the route and the unit tests share it (tools.test.ts).

export const SCOPES = ['bookings:read', 'bookings:write', 'owners:read', 'owners:write', 'requests:read', 'requests:write', 'admin:read', 'admin:write'] as const;
export type Scope = (typeof SCOPES)[number];
/** The address Abbas and Mahad paste in Claude (Settings > Connectors > Add custom connector). */
export const CONNECTOR_URL = 'https://carmacars.ca/api/mcp';
export const SCOPE_LABEL: Record<Scope, string> = {
  'bookings:read': 'Read bookings', 'bookings:write': 'Change booking details', 'owners:read': 'Read owners', 'owners:write': 'Change owner details',
  'requests:read': 'Read requests', 'requests:write': 'Change requests',
  'admin:read': 'Read settings, cars, staff and hiring', 'admin:write': 'Act as the Admin (each change previewed, then confirmed)'
};

export interface Tool { name: string; scope: Scope | 'any'; title: string; description: string; inputSchema: Record<string, unknown>; readOnly: boolean; destructive?: boolean }

const BOOKING_FIELDS = ['notes', 'pickup_place', 'return_place', 'insurer_claim_number', 'insurer_adjuster_name', 'insurer_adjuster_email', 'insurer_adjuster_phone',
  'marketing_source', 'marketing_source_note', 'do_not_email', 'heard_about'] as const;
const REQUEST_FIELDS = ['request_note', 'notes', 'pickup_at', 'return_at', 'pickup_place', 'return_place'] as const;
const OWNER_FIELDS = ['first_name', 'middle_name', 'last_name', 'legal_name', 'corporation_name', 'email', 'phone', 'hst_number', 'address_line1', 'address_line2', 'city',
  'province', 'postal_code', 'mailing_address_line1', 'mailing_address_line2', 'mailing_city', 'mailing_province', 'mailing_postal_code', 'notify_channel',
  'signing_officer_name', 'signing_officer_title'] as const;
export const WRITABLE = { update_booking: BOOKING_FIELDS, update_request: REQUEST_FIELDS, update_owner: OWNER_FIELDS } as const;

const str = (description: string) => ({ type: 'string', description });
const changes = (fields: readonly string[], what: string) => ({
  type: 'object', additionalProperties: false, minProperties: 1,
  description: `The ${what} fields to set, and only those. Anything else (prices, payments, status) is changed in the portal.`,
  properties: Object.fromEntries(fields.map((f) => [f, f === 'do_not_email' ? { type: 'boolean' } : f.endsWith('_at') ? { type: 'string', format: 'date-time' } : { type: ['string', 'null'] }]))
});
// 1156: every list pages past 50 rows with a cursor and hides test records unless asked
const PAGE = {
  limit: { type: 'integer', minimum: 1, maximum: 200, default: 20, description: 'Rows a page (up to 200)' },
  cursor: { type: 'string', description: 'The next_cursor of the page before, for the next page' },
  include_test: { type: 'boolean', description: 'Include test records (verify and test accounts, sample cars); hidden by default' }
};
const listInput = (extra: Record<string, unknown> = {}) => ({
  type: 'object', additionalProperties: false,
  properties: { query: str('A booking number, the renter\'s name or email, or a plate'), ...PAGE, ...extra }
});

export const TOOLS: Tool[] = [
  { name: 'whoami', scope: 'any', readOnly: true, title: 'Who am I', description: 'The CarmaCars account this connection acts as, its scopes, and the fields each update tool may change.',
    inputSchema: { type: 'object', additionalProperties: false, properties: {} } },
  { name: 'list_bookings', scope: 'bookings:read', readOnly: true, title: 'List bookings',
    description: 'Bookings, newest pickup first. Filter by status (requested, offered, tentative, pending_payment, confirmed, on_rent, returned, closed, cancelled, no_show, expired, declined), by dates (from and to, ISO 8601: the rental overlaps them) and by a search query.',
    inputSchema: listInput({ status: str('One booking status'), from: { type: 'string', format: 'date-time' }, to: { type: 'string', format: 'date-time' } }) },
  { name: 'get_booking', scope: 'bookings:read', readOnly: true, title: 'Get a booking', description: 'One booking by its number (for example CC-10482): the car, the renter, the dates and places, the notes and the insurer details.',
    inputSchema: { type: 'object', additionalProperties: false, required: ['booking_number'], properties: { booking_number: str('The booking number, for example CC-10482') } } },
  { name: 'update_booking', scope: 'bookings:write', readOnly: false, title: 'Change booking details',
    description: `Change details of a booking: ${BOOKING_FIELDS.join(', ')}. Every change is logged with the values before and after. Dates, prices and status are changed in the portal (offers and extensions).`,
    inputSchema: { type: 'object', additionalProperties: false, required: ['booking_number', 'changes'], properties: { booking_number: str('The booking number'), changes: changes(BOOKING_FIELDS, 'booking') } } },
  { name: 'list_requests', scope: 'requests:read', readOnly: true, title: 'List requests', description: 'Booking requests and offers not yet booked (requested, offered, tentative), newest first, with the renter\'s note.',
    inputSchema: listInput() },
  { name: 'update_request', scope: 'requests:write', readOnly: false, title: 'Change a request',
    description: `Change a request that has no offer yet (status requested): ${REQUEST_FIELDS.join(', ')}. Logged with before and after.`,
    inputSchema: { type: 'object', additionalProperties: false, required: ['booking_number', 'changes'], properties: { booking_number: str('The request\'s booking number'), changes: changes(REQUEST_FIELDS, 'request') } } },
  { name: 'list_owners', scope: 'owners:read', readOnly: true, title: 'List owners', description: 'Owners in the program by name, email or phone, with how many cars each has.',
    inputSchema: listInput() },
  { name: 'get_owner', scope: 'owners:read', readOnly: true, title: 'Get an owner', description: 'One owner by id: contact details, addresses, status, their owner referral links, and their cars, each with its terms (management fee revenue_share_bps, insurance_fee_cents and tracker_fee_cents a month, since when, every period, a correction waiting for the owner\'s signature).',
    inputSchema: { type: 'object', additionalProperties: false, required: ['owner_id'], properties: { owner_id: { type: 'string', format: 'uuid' } } } },
  { name: 'update_owner', scope: 'owners:write', readOnly: false, title: 'Change owner details',
    description: `Change an owner's details: ${OWNER_FIELDS.join(', ')}. Logged with before and after. Money, payouts and agreements are changed in the portal.`,
    inputSchema: { type: 'object', additionalProperties: false, required: ['owner_id', 'changes'], properties: { owner_id: { type: 'string', format: 'uuid' }, changes: changes(OWNER_FIELDS, 'owner') } } }
];


// ---------------------------------------------------------------- release 33 (0732): the Admin's actions, previewed then confirmed
// Each write runs the same database action as the Admin screen (app.door as the key's Admin). Called without confirm it is a
// preview: run and rolled back, answering what would change and a preview_id. Called again with the same arguments plus
// confirm: true and that preview_id, it is done. The database refuses a confirm without its preview, with other arguments,
// older than 10 minutes or used before.
const id = (description: string) => ({ type: 'string', format: 'uuid', description });
const cents = (description: string) => ({ type: 'integer', minimum: 0, description });
const confirmProps = {
  confirm: { type: 'boolean', description: 'Leave out (or false) for the preview. true, with the preview_id, to do it.' },
  preview_id: { type: 'string', format: 'uuid', description: 'The preview_id the preview returned (only with confirm: true).' }
};
// the offer and booking forms take more fields than are listed (the same names as the screen's form): extra ones pass to the database, which checks them
const OPEN_FORMS = ['create_offer', 'revise_offer', 'change_booking', 'record_past_trip'];
const write = (name: string, title: string, description: string, required: string[], properties: Record<string, unknown>, destructive = false): Tool => ({
  name, scope: 'admin:write', readOnly: false, destructive, title,
  description: `${description} Two steps: call without confirm for a preview of what will change (nothing is changed), then again with the same arguments plus confirm: true and the preview_id.`,
  inputSchema: { type: 'object', additionalProperties: OPEN_FORMS.includes(name), required, properties: { ...properties, ...confirmProps } }
});
const read = (name: string, title: string, description: string, properties: Record<string, unknown> = {}, required: string[] = []): Tool => ({
  name, scope: 'admin:read', readOnly: true, title, description, inputSchema: { type: 'object', additionalProperties: false, required, properties }
});
const booking = { booking: str('The booking number, for example CC-10482') };
const FNS = ['cs', 'fleet', 'finance', 'sales_in_person', 'sales_remote', 'field'];

export const ADMIN_TOOLS: Tool[] = [
  read('get_settings', 'Settings', 'Settings as Admin > Settings shows them. Without section: the Program settings (prices, policies, switches) and the site settings, with the names of the other parts; with section (fee_defaults, fee_types, deposit_tiers, classes, coverage, promo_codes, ...): that part. Read only.',
    { section: str('One part, for example program, site, fee_defaults, deposit_tiers, staff') }),
  read('list_cars', 'List cars', 'Cars in the fleet with their status, owner, current rates and fee overrides. Filter by status or search by plate, name or VIN.',
    { query: str('A plate, a car name or a VIN'), status: str('A vehicle status'), ...PAGE }),
  read('get_car', 'Get a car', 'One car by vehicle_id: status, owner, rates, fee overrides, and its owner terms (terms: revenue_share_bps, insurance_fee_cents, tracker_fee_cents, effective_from, periods with from and to, shareholder, fees_paid_from, awaiting_signature).', { vehicle_id: id('The car') }, ['vehicle_id']),
  read('list_applicants', 'List candidates', 'Job applications, newest first, with the role, status and score. Filter by status (new, screened, invited, booked, interviewed, hired, ...) or search by name or email.',
    { query: str('A name or email'), status: str('An application status'), ...PAGE }),
  read('get_hire_status', 'Onboarding of a hire', 'The onboarding steps of a candidate hired with one-step Hire: sign-in, agreement, pay details, academy, first-day To do\'s.',
    { application_id: id('The application') }, ['application_id']),
  read('list_staff', 'List staff', 'Staff and Admins with their roles, functions, start date and pay details (masked).', { query: str('A name or email'), ...PAGE }),

  write('send_offer', 'Send an offer', 'Send the offer of a request (Admin > the booking > Send the offer), with an optional message and expiry.', ['booking'],
    { ...booking, message: str('A message to the renter'), expires_at: { type: 'string', format: 'date-time' }, book_now: { type: 'boolean', description: 'Book it now: the offer is approved at once as if the renter had approved it; the booking waits for the renter to sign and pay (the Sign and pay link is emailed) and holds the car. Use when the renter already agreed.' }, book_now_reason: str('Why it is booked without the renter\'s approval (kept in the booking\'s history)') }),
  write('create_offer', 'Make an offer', 'Make and send an offer for a renter and a car (the staff offer form): renter_id (or renter {full_name, email, mobile, date_of_birth}), vehicle_id, pickup_at, return_at, and optionally the price fields of the form, rental_pay_method, deposit_pay_method, message, notify, channels.',
    ['vehicle_id', 'pickup_at', 'return_at'], { renter_id: id('A renter on file'), renter: { type: 'object' }, vehicle_id: id('The car'), pickup_at: { type: 'string', format: 'date-time' },
      return_at: { type: 'string', format: 'date-time' }, source: str('phone, walk_in, email, ...'), rental_pay_method: str('card, cash, e_transfer, ...'), deposit_pay_method: str('card, cash, ...'),
      message: str('A message to the renter'), notify: { type: 'boolean' }, channels: { type: 'object' }, rental_charge_cents: cents('A rental charge agreed with the renter'),
      price_reason: str('Why a typed price'), price_tax: str('plus (HST is added on top of the typed charge, the default) or included (the typed amount already holds HST)'), sales_choice: str('for_carmacars or sourced'), book_now: { type: 'boolean', description: 'Book it now: the offer is approved at once as if the renter had approved it; the booking waits for the renter to sign and pay (the Sign and pay link is emailed) and holds the car. Use when the renter already agreed.' }, book_now_reason: str('Why it is booked without the renter\'s approval (kept in the booking\'s history)') }),
  write('book_offer_now', 'Book an offer now', 'Book it now for an offer that is already out (Admin > the booking > Book it now): it becomes the approved version without the renter\'s approval, the booking waits for payment and holds the car, and the renter gets the Sign and pay link. As an Admin it is done at once.', ['booking'],
    { ...booking, reason: str('Why: the renter agreed by phone, ...') }),
  write('revise_offer', 'Revise an offer', 'Send a revised offer for a booking already offered.', ['booking'],
    { ...booking, message: str('A message'), expires_at: { type: 'string', format: 'date-time' }, notify: { type: 'boolean' }, internal_note: str('Kept for staff') }),
  write('withdraw_offer', 'Withdraw an offer', 'Withdraw the open offer of a booking.', ['booking'], { ...booking, note: str('Why') }, true),
  write('change_booking', 'Change a booking', 'Change a booking as Admin > Edit booking does: changes (dates, places, car, kilometres, ...), price lines, the reason, and whether to tell the renter. changes.rolling_weekly true makes it a long-term rental paid weekly (the car stays out on the calendar until the renter gives notice; each weekly payment recorded moves the return 7 days), false turns that off; changes.rolling_end_on (a date, YYYY-MM-DD; empty for until notice) sets its last day. A booking waiting for payment that already has a payment (the first payment of a payment plan, say) changes here too: the car, the dates, the places; its payments stay recorded.',
    ['booking', 'reason'], { ...booking, changes: { type: 'object' }, lines: { type: 'array', items: { type: 'object' } }, reason: str('Why'), tell_renter: { type: 'boolean' } }),
  write('change_booking_fees', 'Change booking fees', 'Change the fee lines of a booking with the reason. Two shapes of lines. (1) Add a named fee, also to a booking on the road or returned: '
    + 'lines is a list of {"op": "add", "fee": "<name>", "amount_cents": <cents before HST>, "note": "<what it is for, the renter sees it>"}, for example '
    + '[{"op": "add", "fee": "smoking", "amount_cents": 30000, "note": "Returned smelling of smoke"}]. Names: smoking, cleaning, cleaning_heavy, pet_cleaning, late, km, fuel, ticket, toll, damage '
    + '(damage also needs photos, a list of photo ids, or document). "action" may stand for "op", and "fee_code", "kind" or "code" for "fee"; amount_cents left out takes the standard amount. '
    + 'HST is added. After the return the fee is billed from the deposit first (at once when the Check-out statement is out, else on it). '
    + '(2) Change or remove fees already on the booking: lines is an object {"<line key>": cents, or null to remove}, as Admin > Edit booking does.', ['booking', 'lines', 'reason'],
    { ...booking, lines: { type: ['array', 'object'], items: { type: 'object', properties: { op: { type: 'string', enum: ['add'] }, fee: str('smoking, cleaning, cleaning_heavy, pet_cleaning, late, km, fuel, ticket, toll or damage'),
      amount_cents: cents('Amount before HST'), note: str('What it is for (the renter sees it)') } }, description: 'A list of named fees to add, or an object {line key: cents or null}' }, reason: str('Why') }),
  write('record_payment', 'Record a payment', 'Record money received outside the site for a part of a booking (covers: rental, deposit, fees, balance, tip). A payment of the rental or the fees pays the other part too once its own part is paid, and a booking waiting for payment is confirmed when nothing is open. A deposit by e-Transfer or cash is the deposit times the Program setting (2x by default): with no amount it takes what is still owed (a top-up); more than the deposit is held and returned with it. A tip (cash or e-Transfer) is split between the salesperson and the handover staff member. On a long-term rental paid weekly with nothing of the rental open, a payment of the rental is the next week: the amount is the week\'s price and the return moves 7 days.', ['booking', 'method', 'amount_cents'],
    { ...booking, covers: str('rental, deposit, fees, balance or tip'), method: str('cash, e_transfer, card_terminal, cheque, bank_transfer, other'), amount_cents: cents('The amount received (a deposit: empty takes what is still owed)'),
      reference: str('A reference'), received_on: { type: 'string', format: 'date' }, note: str('A note') }),
  write('request_refund', 'Request a refund', 'Request a refund on a booking: it waits for approval like a refund requested on screen (Finance, or an Admin above the limit).', ['booking', 'amount_cents'],
    { ...booking, amount_cents: cents('The amount'), reason: str('A refund reason code, for example other'), note: str('Why'), payment: id('A payment, else the latest card charge') }),
  write('cancel_booking', 'Cancel a booking', 'Cancel a booking with the policy of the reason (renter_request, carmacars, no_show, ...).', ['booking', 'reason'],
    { ...booking, reason: str('renter_request, carmacars or another cancellation reason'), note: str('A note'), channel: str('email, phone, text') }, true),
  write('record_handover', 'Record a pickup or a return', 'Record a pickup or a return that happened (the Returned button and Record now): kind pickup or return, the time (not in the future), km and fuel if known. A pickup with the deposit not taken yet: deposit_pending true and deposit_pending_reason (the car goes with the deposit owed; the renter is asked for it each morning, an Admin To do after 48 hours).', ['booking', 'kind'],
    { ...booking, kind: { type: 'string', enum: ['pickup', 'return'] }, at: { type: 'string', format: 'date-time' }, odometer_km: { type: 'integer', minimum: 0 }, fuel_pct: { type: 'integer', minimum: 0, maximum: 100 }, reason: str('A note'),
      deposit_pending: { type: 'boolean', description: 'A pickup only: true records it with the deposit still owed (needs deposit_pending_reason, else the reason)' },
      deposit_pending_reason: str('Why the car goes before the deposit is taken (5 characters or more)'),
      signature_override_reason: str('A pickup only, an Admin: why it is recorded without the renter\'s signature on the check-in report') }),
  write('set_car_rates', 'Set a car\'s rates', 'Set the rate card of a car: daily, weekend, weekly and monthly rates in cents.', ['vehicle'],
    { vehicle: id('The car'), daily: cents('Daily rate'), weekend: cents('Weekend rate'), weekly: cents('Weekly rate'), monthly: cents('Monthly rate'), km_mode: str('default or custom') }),
  write('set_car_fee', 'Set a fee for one car', 'Override one fee for one car (an amount, a percentage or a cap) from a date, with the reason.', ['vehicle', 'fee', 'reason'],
    { vehicle: id('The car'), fee: str('The fee type code'), amount_cents: cents('Amount'), percent_bps: { type: 'integer', minimum: 0, maximum: 10000 }, cap_cents: cents('Cap'), reason: str('Why'), effective_from: { type: 'string', format: 'date' } }),
  write('publish_car', 'Publish a car now', 'Put a car on the site now (Publish now); open warnings are listed in the answer.', ['vehicle_id'], { vehicle_id: id('The car') }),
  write('unlist_car', 'Take a car off the site', 'Unlist a car with the reason (its page redirects to another car or a list).', ['vehicle', 'reason'], { vehicle: id('The car'), reason: str('Why'), to_path: str('Where its page sends visitors') }, true),
  write('change_owner_terms', 'Change an owner\'s terms', 'Change the terms of an owner\'s car (revenue share, fees) from a date, as the Terms tab does. With correction: true it corrects terms recorded wrong, '
    + 'from any date since the car\'s start (effective_from; empty: the start), even before a later term: the periods from that date take the corrected values, the values replaced are kept with the reason '
    + '(note, 10 characters or more), bookings not yet on an approved statement are worked out again, and the owner signs an updated Vehicle Schedule only when the correction gives them less. '
    + 'recompute_statements: true also recomputes the owner\'s approved statements not paid out.', ['vehicle_id', 'owner_id'],
    { owner_id: id('The owner'), vehicle_id: id('The car'), revenue_share_bps: { type: 'integer', minimum: 0, maximum: 10000 }, insurance_fee_cents: cents('Insurance fee'), tracker_fee_cents: cents('Tracker fee'),
      install_fee_cents: cents('Install fee'), first_last_cents: cents('First and last'), effective_from: { type: 'string', format: 'date' }, note: str('Why'), confirm_resign: { type: 'boolean' },
      correction: { type: 'boolean', description: 'Correct the terms from effective_from (a versioned correction), not a change from now on' },
      recompute_statements: { type: 'boolean', description: 'With correction: recompute the owner\'s approved statements not paid out' } }),
  write('issue_owner_invoice', 'Issue an owner invoice', 'Issue a draft owner invoice.', ['id'], { id: id('The invoice') }),
  write('void_owner_invoice', 'Void an owner invoice', 'Void an owner invoice with the reason.', ['id', 'reason'], { id: id('The invoice'), reason: str('Why') }, true),
  write('resend_owner_invoice', 'Resend an owner invoice', 'Email an owner invoice and its pay link again.', ['id'], { id: id('The invoice') }),
  write('hire_applicant', 'Hire a candidate', 'One-step Hire: creates the staff sign-in and invitation, sends the staff agreement to sign, asks for their pay details, enrolls the academy with the gate on, schedules the first-day To do\'s, marks them hired and closes their interview items. The pay defaults to the role\'s standard.',
    ['application_id'], { application_id: id('The application (list_applicants)'), function: { type: 'string', enum: FNS }, start_on: { type: 'string', format: 'date' },
      pay_cents: cents('The pay a month (assistants) or an hour (field), in cents; leave out for the role\'s standard. Sales is commission only.'), pay_currency: { type: 'string', enum: ['USD', 'CAD'] } }),
  write('set_staff_functions', 'Set a person\'s functions', 'Set the staff functions of a person (cs, fleet, finance, sales, field), the sales work mode and the field function.', ['user_id', 'functions'],
    { user_id: id('The person'), functions: { type: 'array', items: { type: 'string', enum: ['cs', 'fleet', 'finance', 'sales', 'field'] } }, sales_work_mode: { type: 'string', enum: ['in_person', 'remote'] }, field_function: str('driver_detailer, ...') }),
  write('end_staff_access', 'End a person\'s access', 'End a staff member\'s access (they can no longer sign in to the staff portal).', ['user'], { user: id('The person') }, true),
  write('verify_staff_pay_details', 'Verify pay details', 'Mark a staff member\'s new pay details verified, saying how they were checked.', ['id', 'method'], { id: id('The pay details (from get_hire_status or list_staff)'), method: str('How they were checked') })
];
TOOLS.push(...ADMIN_TOOLS);

// ---------------------------------------------------------------- release 35 (1156): the Admin's daily operations without a browser
// Reads (admin:read): lists page with a cursor and hide test records; writes (admin:write) are previewed then confirmed like
// the ones above. Money out (refunds, deposit releases, payouts, charges) is only prepared, as an Admin To do: never done here.
const list = (name: string, title: string, description: string, extra: Record<string, unknown> = {}): Tool =>
  read(name, title, `${description} Newest first; pages with cursor (next_cursor), test records hidden unless include_test.`, { ...extra, ...PAGE });
const date = (description: string) => ({ type: 'string', format: 'date', description });
const when = (description: string) => ({ type: 'string', format: 'date-time', description });
export const OPS_TOOLS: Tool[] = [
  list('list_booking_photos', 'Booking photos', 'The photos of a booking\'s pickup, return and damage condition reports.', booking),
  read('get_agreement', 'A booking\'s agreements', 'The rental agreements of a booking: each one\'s status, who must sign, who signed and when, and when the link was last sent.', booking, ['booking']),
  list('list_claims', 'List claims', 'Damage and insurance claims with their status, amounts and booking.', { status: str('A claim status'), query: str('A claim number or insurer reference') }),
  read('get_claim', 'Get a claim', 'One claim by number or id, with its damages.', { claim: str('The claim number or id') }, ['claim']),
  list('list_expenses', 'List expenses', 'Company expenses (not voided).', { from: date('From'), to: date('To'), category: str('An expense category code') }),
  list('list_owner_statements', 'Owner statements', 'Owner statements with their period (cut off on the 7th), payout date, status, payout and whether it was paid.', { owner_id: id('One owner'), status: str('draft, approved, ...') }),
  read('get_owner_statement', 'Get an owner statement', 'One owner statement with its lines (a rental across the cutoff shows the days of this period).', { id: id('The statement') }, ['id']),
  list('list_owner_invoices', 'Owner invoices', 'Owner invoices: how each is paid (bank debit or deducted from payouts), deduct_from_payout_on, paid and balance.', { owner_id: id('One owner'), status: str('An invoice status'), unpaid: { type: 'boolean' } }),
  list('list_payouts', 'Payouts', 'Payouts to owners, staff and partners, paid or not.', { payee_type: str('owner, staff, ...'), status: str('A payout status'), unpaid: { type: 'boolean' } }),
  list('list_commissions', 'Staff commissions', 'Staff commissions with their status and whether paid.', { staff_id: id('One person'), status: str('A commission status'), unpaid: { type: 'boolean' } }),
  list('list_insurer_invoices', 'Insurer invoices', 'Invoices to insurers with paid, balance and write-offs.', { status: str('An invoice status'), unpaid: { type: 'boolean' } }),
  list('list_tolls', 'Tolls and tickets', 'Tolls and parking or traffic tickets, matched to a booking or not.', { status: str('A status'), unmatched: { type: 'boolean' }, query: str('A notice number or plate') }),
  list('list_leads', 'Leads', 'Leads with who holds each (assigned or claimed), the marketing source and the message.', { status: str('A lead status'), assigned_to: id('A salesperson'), source: str('A source or UTM source'), from: when('From'), to: when('To'), query: str('A name, email or phone') }),
  list('list_chats', 'Live chats', 'Website chats with the last messages.', { status: str('A chat status') }),
  list('list_visitor_leads', 'Visitor leads', 'Website visitors who left contact details or turned hot, with their source.', { from: when('Seen since') }),
  read('rep_summary', 'Leads and bookings per rep', 'Each salesperson\'s leads claimed, held now and brought, and bookings credited, between from and to.', { from: when('From (default 30 days ago)'), to: when('To (default now)'), include_test: { type: 'boolean' } }),
  list('list_todos', 'To do queues', 'Open To do\'s (or a status), by queue and person.', { queue: str('admin, cs, fleet, finance, sales, ...'), status: str('open, in_progress, waiting, done, ...'), assigned_to: id('One person') }),
  read('car_calendar', 'A car\'s calendar', 'The bookings of a car between from and to.', { vehicle_id: id('The car'), from: when('From'), to: when('To') }, ['vehicle_id']),
  list('list_field_jobs', 'Field jobs', 'Deliveries, pickups and other field jobs with who is assigned.', { status: str('A job status'), from: when('From'), to: when('To') }),
  read('staff_onboarding_status', 'Staff onboarding', 'Where each staff member is in onboarding (academy, agreement, WhatsApp, approval) and who waits for approval.'),
  list('list_deposit_reviews', 'Deposit reviews', 'Returned trips whose deposit review is not finished (all: true for every one).', { all: { type: 'boolean' } }),

  write('upload_booking_photo', 'Upload a booking photo', 'Add a photo to a booking\'s pickup or return condition report, or to a damage on it: image_base64 (JPEG or PNG, under 8 MB).', ['booking', 'stage', 'image_base64'],
    { ...booking, stage: { type: 'string', enum: ['pickup', 'return', 'damage'] }, shot: str('front, rear, left, interior, ... (pickup or return); the guided cleanliness evidence of a return: clean_ash, clean_seats, clean_headliner, clean_cupholders, clean_floor, clean_other'), damage_id: id('The damage (stage damage)'), image_base64: str('The photo, base64') }),
  write('resend_agreement', 'Resend an agreement', 'Send the booking\'s agreement signing link again to whoever has not signed.', ['booking'], booking),
  write('update_claim', 'Update a claim', 'Set a claim\'s status, as the claim page does.', ['id', 'status'], { id: id('The claim'), status: str('The new status'), note: str('A note') }),
  write('add_expense', 'Add an expense', 'Add a company expense (Admin > Expenses).', ['category', 'amount_cents', 'description'],
    { expense_on: date('The day'), category: str('An expense category code'), amount_cents: cents('Amount before HST'), hst_cents: cents('HST'), description: str('What it was'), vehicle_id: id('The car, if any') }),
  write('set_invoice_collect_by', 'How an owner invoice is paid', 'Bank debit on the 15th, or deducted from the owner\'s payouts.', ['id', 'collect_by'], { id: id('The invoice'), collect_by: { type: 'string', enum: ['bank_debit', 'payout'] } }),
  write('set_invoice_deduct_from', 'Deduct from payouts starting', 'The first payout date an owner invoice is deducted from (empty: the next payout).', ['id'], { id: str('The invoice id or number'), date: date('The first payout date') }),
  write('match_toll', 'Match a toll or ticket', 'Match a toll or ticket to a booking (or to the owner, staff or CarmaCars), as the tolls page does.', ['id', 'to'], { id: id('The toll or ticket'), to: str('A booking number, or owner, staff, company'), note: str('Why') }),
  write('complete_todo', 'Complete a To do', 'Mark a To do done with a note.', ['id'], { id: id('The To do'), note: str('What was done') }),
  write('assign_field_job', 'Assign a field job', 'Give a field job to a field staff member on a shift that day (or an Admin).', ['id', 'to'], { id: id('The job'), to: id('The person') }),
  write('approve_onboarding', 'Approve onboarding', 'Approve a staff member waiting at onboarding step 4: their portal opens.', ['user'], { user: id('The person') }),
  write('reject_onboarding', 'Reject onboarding', 'Reject a staff member at onboarding step 4 with the reason they see on Welcome.', ['user', 'reason'], { user: id('The person'), reason: str('What to fix') }),
  write('restore_staff_access', 'Restore staff access', 'Give back staff portal access ended before.', ['user'], { user: id('The person') }),
  write('record_past_trip', 'Record a past trip', 'Record a trip that happened without being recorded (the past-trip form): the pickup and return times, km and fuel, and an Admin\'s deposit waiver reason if no deposit was taken.', ['booking'],
    { ...booking, pickup_at: when('When it was picked up'), return_at: when('When it came back'), odometer_out_km: { type: 'integer', minimum: 0 }, odometer_in_km: { type: 'integer', minimum: 0 },
      fuel_out_pct: { type: 'integer', minimum: 0, maximum: 100 }, fuel_in_pct: { type: 'integer', minimum: 0, maximum: 100 }, reason: str('Why it was not recorded'), deposit_waiver_reason: str('Admin: why no deposit') }),
  write('prepare_money_action', 'Prepare a refund, release, payout or charge', 'Prepare money out for an Admin to do in the portal: kind refund, deposit_release, payout or charge, with the amount and the reason. It becomes an Admin To do with its link; no money moves.', ['kind', 'amount_cents', 'reason'],
    { kind: { type: 'string', enum: ['refund', 'deposit_release', 'payout', 'charge'] }, ...booking, payout_id: id('The payout (kind payout)'), amount_cents: cents('The amount'), reason: str('Why') })
];
TOOLS.push(...OPS_TOOLS);

// ---------------------------------------------------------------- the gaps (1873): files on a claim
// A photo or a repair estimate attached to a claim, previewed then confirmed like every Admin write. The database (app.api_call) checks the
// role (an Admin, Finance or Fleet), the claim (not closed or withdrawn) and the preview; the bytes are held by the web layer only.
export const MAX_CLAIM_FILE_BYTES = 8 * 1024 * 1024;
export const CLAIM_TOOLS: Tool[] = [
  write('attach_claim_photo', 'Attach a photo to a claim', 'Attach a photo (JPEG or PNG, under 8 MB) to a claim by its number (CL-...) or id: it is kept with the claim\'s documents.', ['claim', 'file_base64'],
    { claim: str('The claim number (CL-...) or id'), file_base64: str('The photo, base64 (JPEG or PNG, under 8 MB)'), caption: str('A short caption') }),
  write('attach_claim_estimate', 'Add a repair estimate to a claim', 'Add a repair estimate to a claim by its number (CL-...) or id, as Finance does on the claim page: the amount in cents as quoted, the shop, whether it is an approved shop, and optionally the estimate itself as a file (PDF, JPEG or PNG, under 8 MB). It counts in the claim\'s damage cost like the one entered on screen.', ['claim', 'amount_cents', 'shop_name', 'approved_shop'],
    { claim: str('The claim number (CL-...) or id'), amount_cents: { type: 'integer', minimum: 1, description: 'The estimate in cents, as invoiced (HST included when it shows on it)' }, hst_cents: cents('The HST shown on the estimate'),
      shop_name: str('The shop that made the estimate'), approved_shop: { type: 'boolean', description: 'Whether it is an approved shop' }, description: str('What it covers'), file_base64: str('The estimate as a file, base64 (PDF, JPEG or PNG, under 8 MB)') })
];
TOOLS.push(...CLAIM_TOOLS);

/** The kind of a file by its first bytes: what the connector accepts on a claim. */
export function claimFileKind(bytes: Uint8Array): { ext: 'jpg' | 'png' | 'pdf'; mime: string } | null {
  if (bytes[0] === 0xff && bytes[1] === 0xd8 && bytes[2] === 0xff) return { ext: 'jpg', mime: 'image/jpeg' };
  if (bytes[0] === 0x89 && bytes[1] === 0x50 && bytes[2] === 0x4e && bytes[3] === 0x47) return { ext: 'png', mime: 'image/png' };
  if (bytes[0] === 0x25 && bytes[1] === 0x50 && bytes[2] === 0x44 && bytes[3] === 0x46) return { ext: 'pdf', mime: 'application/pdf' };
  return null;
}

/** The tools a set of scopes may call (whoami always). */
export const toolsFor = (scopes: readonly string[]) => TOOLS.filter((t) => t.scope === 'any' || scopes.includes(t.scope));

/** A requested scope string ("bookings:read owners:read") as the known scopes; all of them when none is asked. */
export function parseScopes(s: string | null | undefined): Scope[] {
  const asked = (s ?? '').split(/[\s,]+/).filter(Boolean);
  const known = asked.filter((x): x is Scope => (SCOPES as readonly string[]).includes(x));
  return asked.length ? [...new Set(known)] : [...SCOPES];
}

// ---------------------------------------------------------------- secrets (Web Crypto: the Worker and Node alike)
const b64url = (b: Uint8Array) => btoa(String.fromCharCode(...b)).replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/, '');
/** A new secret: the prefix and 32 random bytes, base64url. */
export function newSecret(prefix: 'cc_live_' | 'cca_' | 'ccr_' | 'ccx_' | 'ccc_'): string {
  return prefix + b64url(crypto.getRandomValues(new Uint8Array(32)));
}
export async function sha256Hex(s: string): Promise<string> {
  const d = new Uint8Array(await crypto.subtle.digest('SHA-256', new TextEncoder().encode(s)));
  return [...d].map((x) => x.toString(16).padStart(2, '0')).join('');
}
/** PKCE S256: base64url(SHA-256(verifier)). */
export async function pkceChallenge(verifier: string): Promise<string> {
  return b64url(new Uint8Array(await crypto.subtle.digest('SHA-256', new TextEncoder().encode(verifier))));
}
/** What Admin shows of a secret: its first characters. */
export const secretPrefix = (s: string) => s.slice(0, s.startsWith('cc_live_') ? 12 : 8);
/** The bearer secret of an Authorization header, or null. */
export function bearer(h: string | null): string | null {
  const m = /^Bearer\s+([A-Za-z0-9_-]{20,200})\s*$/i.exec(h ?? '');
  return m ? m[1]! : null;
}

// Release 37 (2340): bug reports from staff, so Claude works from them directly (never posted to GitHub: the repository is
// public and the pictures may show personal data). The pictures come back as links that expire in ten minutes.
export const BUG_TOOLS: Tool[] = [
  read('bug_reports_list', 'List bug reports', 'Bug reports sent by staff and Admins with "Report a bug", newest first: number, status, severity (blocks_work, annoying, cosmetic), page, reporter and the start of the description. status: open (new and triaged, the default), new, triaged, fixed, wont_fix; since: an ISO date and time.',
    { status: { type: 'string', enum: ['open', 'new', 'triaged', 'fixed', 'wont_fix'], description: 'Which reports (open by default)' }, since: str('Only reports sent at or after this ISO date and time'), limit: { type: 'integer', minimum: 1, maximum: 200, description: 'At most this many (100 by default)' } }),
  read('bug_report_get', 'Get a bug report', 'One bug report by its number (BR-...) or id, as text: what happened, what was expected, the steps, the page, the browser, the build, the reporter\'s role, the browser\'s last 50 errors and failed calls (redacted), the server\'s errors for that person and page around that time, the notes, and links to its pictures that expire in ten minutes.',
    { id: str('The report number (BR-...) or its id') }, ['id']),
  write('bug_report_update', 'Update a bug report', 'Triage a bug report by its number (BR-...) or id: its status (new, triaged, fixed, wont_fix), a note (added with the date) and the release that fixed it (fixed_in, for example r38). The reporter sees the status in My bug reports.', ['id'],
    { id: str('The report number (BR-...) or its id'), status: { type: 'string', enum: ['new', 'triaged', 'fixed', 'wont_fix'], description: 'The new status' }, note: str('A note to add'), fixed_in: str('The release that fixed it') })
];
TOOLS.push(...BUG_TOOLS);

// Release 47 (2896): the listing photo standard (r45) per car and for the fleet, with Gemini's use today. Read only.
export const PHOTO_TOOLS: Tool[] = [
  read('photo_standard', 'Photo standard', 'The listing photo standard (r45) per car: photos, public (on the site now), at the standard, flagged (kept off the site, each with the check\'s why and reasons), queued, AI angles (generated views) and the standard angles still missing, the first photo\'s shot type, and whether the public cover is a real photo, a sample photo or none. Also the fleet totals and Gemini today: image calls used, the daily limit, the reserve for new uploads, what is left and the photos waiting. Without vehicle: every car the standard applies to, newest listed first. Read only.',
    { vehicle: str('One car: its vehicle id, fleet number or plate'), limit: { type: 'integer', minimum: 1, maximum: 500, description: 'At most this many cars (200 by default)' } })
];
TOOLS.push(...PHOTO_TOOLS);

// Release 47 (2896): Stripe, read live beside what the site recorded (stripe-inspect.ts). Never moves money: the reads
// only GET; stripe_record_paid only records a payment Stripe already shows succeeded, as the webhook would.
export const STRIPE_TOOLS: Tool[] = [
  read('stripe_booking', 'Stripe for a booking', 'Live from Stripe for one booking: every PaymentIntent, charge and SetupIntent the booking references or that Stripe finds by its metadata, each with its status, amount, amount received and capturable, capture method, when, the last error, refunds, disputes and the card brand and last 4 only; beside what the site recorded (payments, holds, pay links), and a one-line verdict ("paid and recorded", "paid at Stripe but not recorded (pi_...)", "hold authorized until ...", "not paid"). Read only.',
    { booking: str('The booking number, for example CC-10482') }, ['booking']),
  read('stripe_account', 'Stripe account', 'Live from Stripe: the balance (available and pending per currency), whether charges and payouts are enabled, the payout schedule, the next and the last payout, and the account\'s open requirements (currently_due, past_due, eventually_due, current_deadline, disabled_reason), so a verification Stripe asks for is visible. Read only.'),
  read('stripe_find_payments', 'Find Stripe payments', 'Live from Stripe: the PaymentIntents created in a time window (the last 24 hours by default; hours up to 720, or from and to; 30 days at most) that succeeded or hold a card (requires_capture), newest first, optionally only one amount (amount_cents). Each with its id, amount, status, when, the card brand and last 4 only, the method (card, card_present for a tap or a reader) and wallet, the booking in its Stripe metadata if any, and whether the site recorded it (and on which booking). Payments with no booking in Stripe (a card taken in the Stripe Dashboard app, Tap to Pay) and not recorded are flagged: stripe_record_paid with the booking links them. Read only.',
    { hours: { type: 'number', minimum: 1, maximum: 720, description: 'The window, in hours back from to (24 by default, 720 at most)' }, from: { type: 'string', format: 'date-time', description: 'The start of the window (instead of hours)' },
      to: { type: 'string', format: 'date-time', description: 'The end of the window (now by default)' }, amount_cents: { type: 'integer', minimum: 1, description: 'Only payments of exactly this amount, in cents (CA$5,000.00 is 500000)' } }),
  write('stripe_record_paid', 'Record a Stripe payment', 'Record on its booking a PaymentIntent that Stripe shows succeeded but the site never recorded, and never charge, capture or refund. Made for the booking (stripe_booking says "paid at Stripe but not recorded"): recorded exactly as Stripe\'s webhook would. Untied, with no booking in Stripe (a card taken in the Stripe Dashboard app, Tap to Pay; stripe_find_payments flags them): linked when its amount is exactly what is open on the booking (the rental and fees, the deposit, or both), the preview says how; on confirm the booking is written into its Stripe metadata and it is recorded as Link a Stripe payment does, audited. Refused when it is not succeeded, for another booking, already recorded anywhere, or of another amount.', ['booking', 'payment_intent'],
    { booking: str('The booking number'), payment_intent: str('The PaymentIntent id (pi_...)') })
];
TOOLS.push(...STRIPE_TOOLS);

// Release 48 (2923): one open pay link cancelled by its PaymentIntent id, and that intent cancelled at Stripe (never
// captured: no money moves). An Admin only; a paid link is refused (giving money back is a refund).
export const PAY_LINK_TOOLS: Tool[] = [
  write('cancel_pay_link', 'Cancel a pay link', 'Cancel one open pay link (a link texted or emailed to a renter, for the rental, the fees, the balance, a later charge or a deposit hold) by its PaymentIntent id (pi_..., as stripe_booking lists it), and cancel that PaymentIntent at Stripe. No money moves: an open link was never paid. A paid link is refused (that is a refund), and so is one already cancelled or expired. An Admin only.',
    ['payment_intent'], { payment_intent: str('The PaymentIntent id (pi_...) of the pay link') }, true)
];
TOOLS.push(...PAY_LINK_TOOLS);

// Release 48 (3013): the Admin's "Let it go" for a main driver with a licence from outside Ontario (an international or
// another province's licence), on one booking. Previewed, then confirmed; logged in the booking history and api_calls.
export const LICENCE_TOOLS: Tool[] = [
  write('licence_let_go', 'Accept a licence from outside Ontario', 'Let the main driver of one booking keep a licence from outside Ontario (international or another province), as the Admin\'s Let it go on the booking page does: the driver moved to additional driver because of that licence is the main driver again for this booking only, and pickup is no longer blocked by it. An Admin only, with the reason. Refused when the booking has no main driver waiting on an Ontario licence.',
    ['booking', 'reason'], { ...booking, reason: str('Why this driver may keep the licence (5 characters or more)') })
];
TOOLS.push(...LICENCE_TOOLS);

// Release 48 FE (3193): the return charges of the rental agreement (10.6 to 10.8, 11.6) and the evidence every fee needs (3190).
const cost = { type: 'object', properties: { label: str('What it was: Tow, Impound, Storage, Lockout, Tire, ...'), amount_cents: cents('The actual cost, before HST'), document_id: id('The receipt or invoice (a document of the booking)') } };
export const EVIDENCE_TOOLS: Tool[] = [
  write('add_return_charge', 'Add a return charge', 'Add a charge of the rental agreement after a rental: non_return ($1,000 by default, not back by the final late notice deadline: 10.6), improper_return ($250: wrong_place, keys_not_returned, unlocked, unsecured or unagreed_drop as reason: 10.7), theft_recovery ($1,500: 10.8), tire or roadside (the actual cost plus the $50 administration fee: 11.6; refused for a mechanical fault that is not the renter\'s). Actual costs go in costs as lines at cost with their receipt. HST is added to the charge; it is company revenue. Every line\'s evidence is checked by itself: what is missing makes it "needs evidence" (a To do says what to capture) and it is not charged until attached or overridden by an Admin. An Admin, Finance or Fleet.',
    ['booking', 'kind', 'note'], { ...booking, kind: { type: 'string', enum: ['non_return', 'improper_return', 'theft_recovery', 'tire', 'roadside'] }, reason: str('improper_return: wrong_place, keys_not_returned, unlocked, unsecured or unagreed_drop'),
      note: str('What happened (the renter sees it)'), costs: { type: 'array', items: cost, description: 'The actual costs, each with its receipt' }, mechanical_fault: { type: 'boolean', description: 'tire or roadside: a mechanical fault that is not the renter\'s (then nothing is charged)' },
      police_report: str('theft_recovery: the police report number') }),
  read('fee_evidence', 'Fee evidence', 'Each fee line of a booking with its evidence: what the registry requires (blocks the charge) and gathers (for the dispute pack), what was found by itself (the return time, Tracker readings, notices, photos, receipts) and what is missing, with the line_item_id to attach evidence to.', booking, ['booking']),
  write('attach_fee_evidence', 'Attach fee evidence', 'Attach evidence to a fee line (line: its line_item_id from fee_evidence): kind receipt, invoice, photo, notice, description, note, police_report or damage_closeup, with document_id (a document of the booking), photo_ids or a note. The evidence is checked again; a fee complete after the Check-out statement goes to Finance to bill.',
    ['line', 'kind'], { line: id('The fee line'), kind: str('receipt, invoice, photo, notice, description, note, police_report or damage_closeup'), document_id: id('A document of the booking'), photo_ids: { type: 'array', items: { type: 'string' } }, note: str('A description or note') }),
  write('override_fee_evidence', 'Charge without evidence', 'An Admin charges a fee that waits for evidence without it, with the reason (10 characters or more), kept on the line and in the booking history.',
    ['line', 'reason'], { line: id('The fee line'), reason: str('Why it is charged without its evidence') })
];
TOOLS.push(...EVIDENCE_TOOLS);

// Release 49 (3610): Check e-Transfer. A Sales rep reported that a renter sent an e-Transfer (with a screenshot); Finance or
// an Admin confirms it (recorded as record_payment does, method e_transfer) or sends it back with the reason. Previewed,
// then confirmed; the database (app.api_call, app.etransfer_decide) checks the role and every rule of the payment.
export const ETRANSFER_TOOLS: Tool[] = [
  write('etransfer_check', 'Check an e-Transfer a rep reported', 'Decide a "Check e-Transfer" report (a Sales rep said the renter of a booking waiting for payment sent an e-Transfer, with a screenshot; list_todos queue finance lists them, task etransfer_check): by its number (report, ET-...) or the booking with the open report. decision received records the reported amount by e-Transfer as record_payment does (the rental and fees, the deposit, or both: the deposit part is what is still owed by e-Transfer unless deposit_cents says otherwise), confirms a booking waiting for payment with nothing open, keeps the screenshot as the payment\'s proof and tells the rep. decision not_received sends it back to the rep with the reason; nothing is recorded. reference: the bank\'s e-Transfer reference (empty: the report number). Finance or an Admin, never the rep who reported it. The preview says what would be recorded, or why it cannot be.',
    ['decision'], { report: str('The report number (ET-...) or id'), ...booking, decision: { type: 'string', enum: ['received', 'not_received'] },
      reason: str('not_received: why (5 characters or more; the rep sees it)'), reference: str('The bank\'s e-Transfer reference (optional)'),
      received_on: { type: 'string', format: 'date', description: 'The day it reached the bank (default today)' },
      deposit_cents: cents('A report covering both: the deposit part (default: the deposit still owed by e-Transfer)') })
];
TOOLS.push(...ETRANSFER_TOOLS);

// Release 50 (3800, 3810): sign first. owner_agreements reads each owner's master agreement, title agreement, cars on
// Schedule A and what is missing, with the link to sign; send_owner_agreement_reminder emails (and notifies in-app and by
// push) what waits on the owner; set_onboarding_method corrects a car's method before its Vehicle Schedule is signed.
// The database (app.api_call) decides; the writes are previewed, then confirmed.
export const OWNER_SIGN_TOOLS: Tool[] = [
  read('owner_agreements', 'Owner agreements', 'Each owner\'s master agreement (the Fleet Supplier Lease Agreement or the Vehicle Enrollment Agreement) and Title-Holding and Lease Agreement, with their numbers and status (draft, sent, signed), each car on Schedule A (signed or not, approved, delivered, and why it cannot move yet), what is missing and who it waits on, when a reminder was last sent, and the links (the owner\'s signing page and the Admin owner page). By default the owners with something missing; owner_id for one, query to search by name or email, all for every owner. An Admin.',
    { owner_id: id('One owner'), query: str('A name, corporation or email'), all: { type: 'boolean', description: 'Every owner, not only those with something missing' }, limit: { type: 'integer', minimum: 1, maximum: 200, default: 20 }, include_test: { type: 'boolean' } }),
  write('send_owner_agreement_reminder', 'Remind an owner to sign', 'Send the owner a reminder (email, in-app notice and push) of what still waits for their signature before their cars can be approved, delivered or rented: the master agreement, the Title-Holding and Lease Agreement, a Schedule A confirmation, or the profile values the agreement needs. Refused when nothing waits on the owner, when they have no sign-in yet, or within 10 minutes of the last one. An Admin, customer service or Fleet.',
    ['owner_id'], { owner_id: id('The owner (owner_agreements lists them)') }),
  write('set_onboarding_method', 'Change a car\'s Onboarding Method', 'Correct a car\'s Onboarding Method (transfer, co_registrant, lease_existing_corporation or lease_new_owner_corporation) after its terms are set and before its Vehicle Schedule is signed, with the reason: the schedule entry, the onboarding plan and the government forms follow, and the agreements and Forms A and B are made again when the owner opens them. Refused once the schedule is signed (that needs a new signed schedule) or for a method the car cannot use. An Admin.',
    ['vehicle_id', 'method', 'reason'], { vehicle_id: id('The car'), method: { type: 'string', enum: ['transfer', 'co_registrant', 'lease_existing_corporation', 'lease_new_owner_corporation'] }, reason: str('Why it changes (5 characters or more)') }),
  read('owner_documents_check', 'Owner document check', 'Everything still inconsistent on the owners\' documents, read from the records they are made of, each with what fixes it: a signing officer title that is a name (title_is_name), a profile the agreement misses values of (profile_missing), no corporation number, an Onboarding Method that does not fit how the car is held (method_mismatch), a Co-Registrant schedule to confirm, a first and last month off the rule of two months of the Insurance Fee (first_last_rule), a value the Vehicle Schedule prints empty (schedule_empty), a signed copy being filed again with the CarmaCars countersignature, HST on an Insurance Fee invoice. With counts by issue and by owner; owner_id for one owner. An Admin.',
    { owner_id: id('One owner') })
];
TOOLS.push(...OWNER_SIGN_TOOLS);

/** price_tax: the server takes 'plus' | 'included'. The first wording of the tool said before_tax / after_tax, so those still work. */
const PRICE_TAX_ALIAS: Record<string, string> = { before_tax: 'plus', after_tax: 'included' };
export function normalizeToolArgs(args: unknown): unknown {
  if (!args || typeof args !== 'object' || Array.isArray(args)) return args;
  const a = args as Record<string, unknown>;
  const t = typeof a.price_tax === 'string' ? PRICE_TAX_ALIAS[a.price_tax.trim().toLowerCase()] : undefined;
  return t ? { ...a, price_tax: t } : args;
}
