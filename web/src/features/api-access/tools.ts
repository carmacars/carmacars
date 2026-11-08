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
const listInput = (extra: Record<string, unknown> = {}) => ({
  type: 'object', additionalProperties: false,
  properties: { query: str('A booking number, the renter\'s name or email, or a plate'), limit: { type: 'integer', minimum: 1, maximum: 50, default: 20 }, ...extra }
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
  { name: 'get_owner', scope: 'owners:read', readOnly: true, title: 'Get an owner', description: 'One owner by id: contact details, addresses, status and their cars.',
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
const OPEN_FORMS = ['create_offer', 'revise_offer', 'change_booking'];
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
    { query: str('A plate, a car name or a VIN'), status: str('A vehicle status'), limit: { type: 'integer', minimum: 1, maximum: 50, default: 20 } }),
  read('get_car', 'Get a car', 'One car by vehicle_id: status, owner, rates, fee overrides.', { vehicle_id: id('The car') }, ['vehicle_id']),
  read('list_applicants', 'List candidates', 'Job applications, newest first, with the role, status and score. Filter by status (new, screened, invited, booked, interviewed, hired, ...) or search by name or email.',
    { query: str('A name or email'), status: str('An application status'), limit: { type: 'integer', minimum: 1, maximum: 50, default: 20 } }),
  read('get_hire_status', 'Onboarding of a hire', 'The onboarding steps of a candidate hired with one-step Hire: sign-in, agreement, pay details, academy, first-day To do\'s.',
    { application_id: id('The application') }, ['application_id']),
  read('list_staff', 'List staff', 'Staff and Admins with their roles, functions, start date and pay details (masked).', { query: str('A name or email') }),

  write('send_offer', 'Send an offer', 'Send the offer of a request (Admin > the booking > Send the offer), with an optional message and expiry.', ['booking'],
    { ...booking, message: str('A message to the renter'), expires_at: { type: 'string', format: 'date-time' }, book_now: { type: 'boolean', description: 'Book it now: the offer is approved at once as if the renter had approved it; the booking waits for the renter to sign and pay (the Sign and pay link is emailed) and holds the car. Use when the renter already agreed.' }, book_now_reason: str('Why it is booked without the renter\'s approval (kept in the booking\'s history)') }),
  write('create_offer', 'Make an offer', 'Make and send an offer for a renter and a car (the staff offer form): renter_id (or renter {full_name, email, mobile, date_of_birth}), vehicle_id, pickup_at, return_at, and optionally the price fields of the form, rental_pay_method, deposit_pay_method, message, notify, channels.',
    ['vehicle_id', 'pickup_at', 'return_at'], { renter_id: id('A renter on file'), renter: { type: 'object' }, vehicle_id: id('The car'), pickup_at: { type: 'string', format: 'date-time' },
      return_at: { type: 'string', format: 'date-time' }, source: str('phone, walk_in, email, ...'), rental_pay_method: str('card, cash, e_transfer, ...'), deposit_pay_method: str('card, cash, ...'),
      message: str('A message to the renter'), notify: { type: 'boolean' }, channels: { type: 'object' }, rental_charge_cents: cents('A rental charge agreed with the renter'),
      price_reason: str('Why a typed price'), price_tax: str('before_tax or after_tax'), sales_choice: str('for_carmacars or sourced'), book_now: { type: 'boolean', description: 'Book it now: the offer is approved at once as if the renter had approved it; the booking waits for the renter to sign and pay (the Sign and pay link is emailed) and holds the car. Use when the renter already agreed.' }, book_now_reason: str('Why it is booked without the renter\'s approval (kept in the booking\'s history)') }),
  write('book_offer_now', 'Book an offer now', 'Book it now for an offer that is already out (Admin > the booking > Book it now): it becomes the approved version without the renter\'s approval, the booking waits for payment and holds the car, and the renter gets the Sign and pay link. As an Admin it is done at once.', ['booking'],
    { ...booking, reason: str('Why: the renter agreed by phone, ...') }),
  write('revise_offer', 'Revise an offer', 'Send a revised offer for a booking already offered.', ['booking'],
    { ...booking, message: str('A message'), expires_at: { type: 'string', format: 'date-time' }, notify: { type: 'boolean' }, internal_note: str('Kept for staff') }),
  write('withdraw_offer', 'Withdraw an offer', 'Withdraw the open offer of a booking.', ['booking'], { ...booking, note: str('Why') }, true),
  write('change_booking', 'Change a booking', 'Change a booking as Admin > Edit booking does: changes (dates, places, car, kilometres, ...), price lines, the reason, and whether to tell the renter.',
    ['booking', 'reason'], { ...booking, changes: { type: 'object' }, lines: { type: 'array', items: { type: 'object' } }, reason: str('Why'), tell_renter: { type: 'boolean' } }),
  write('change_booking_fees', 'Change booking fees', 'Change the fee lines of a booking (add, change or remove a fee) with the reason.', ['booking', 'lines', 'reason'],
    { ...booking, lines: { type: 'array', items: { type: 'object' } }, reason: str('Why') }),
  write('record_payment', 'Record a payment', 'Record money received outside the site for a part of a booking (covers: rental, deposit, fees, balance).', ['booking', 'method', 'amount_cents'],
    { ...booking, covers: str('rental, deposit, fees or balance'), method: str('cash, e_transfer, card_terminal, cheque, bank_transfer, other'), amount_cents: cents('The amount received'),
      reference: str('A reference'), received_on: { type: 'string', format: 'date' }, note: str('A note') }),
  write('request_refund', 'Request a refund', 'Request a refund on a booking: it waits for approval like a refund requested on screen (Finance, or an Admin above the limit).', ['booking', 'amount_cents'],
    { ...booking, amount_cents: cents('The amount'), reason: str('A refund reason code, for example other'), note: str('Why'), payment: id('A payment, else the latest card charge') }),
  write('cancel_booking', 'Cancel a booking', 'Cancel a booking with the policy of the reason (renter_request, carmacars, no_show, ...).', ['booking', 'reason'],
    { ...booking, reason: str('renter_request, carmacars or another cancellation reason'), note: str('A note'), channel: str('email, phone, text') }, true),
  write('record_handover', 'Record a pickup or a return', 'Record a pickup or a return that happened (the Returned button and Record now): kind pickup or return, the time (not in the future), km and fuel if known.', ['booking', 'kind'],
    { ...booking, kind: { type: 'string', enum: ['pickup', 'return'] }, at: { type: 'string', format: 'date-time' }, odometer_km: { type: 'integer', minimum: 0 }, fuel_pct: { type: 'integer', minimum: 0, maximum: 100 }, reason: str('A note') }),
  write('set_car_rates', 'Set a car\'s rates', 'Set the rate card of a car: daily, weekend, weekly and monthly rates in cents.', ['vehicle'],
    { vehicle: id('The car'), daily: cents('Daily rate'), weekend: cents('Weekend rate'), weekly: cents('Weekly rate'), monthly: cents('Monthly rate'), km_mode: str('default or custom') }),
  write('set_car_fee', 'Set a fee for one car', 'Override one fee for one car (an amount, a percentage or a cap) from a date, with the reason.', ['vehicle', 'fee', 'reason'],
    { vehicle: id('The car'), fee: str('The fee type code'), amount_cents: cents('Amount'), percent_bps: { type: 'integer', minimum: 0, maximum: 10000 }, cap_cents: cents('Cap'), reason: str('Why'), effective_from: { type: 'string', format: 'date' } }),
  write('publish_car', 'Publish a car now', 'Put a car on the site now (Publish now); open warnings are listed in the answer.', ['vehicle_id'], { vehicle_id: id('The car') }),
  write('unlist_car', 'Take a car off the site', 'Unlist a car with the reason (its page redirects to another car or a list).', ['vehicle', 'reason'], { vehicle: id('The car'), reason: str('Why'), to_path: str('Where its page sends visitors') }, true),
  write('change_owner_terms', 'Change an owner\'s terms', 'Change the terms of an owner\'s car (revenue share, fees) from a date, as the Terms tab does.', ['vehicle_id', 'owner_id'],
    { owner_id: id('The owner'), vehicle_id: id('The car'), revenue_share_bps: { type: 'integer', minimum: 0, maximum: 10000 }, insurance_fee_cents: cents('Insurance fee'), tracker_fee_cents: cents('Tracker fee'),
      install_fee_cents: cents('Install fee'), first_last_cents: cents('First and last'), effective_from: { type: 'string', format: 'date' }, note: str('Why'), confirm_resign: { type: 'boolean' } }),
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
