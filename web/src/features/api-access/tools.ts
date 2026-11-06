// API access (release 28, B3; migration 0562): the tools the MCP connector and the API offer, with the scope each needs
// and its input, described for Claude. The database (app.api_call) is the one place that runs them and decides; this
// list only describes them. Pure, so the route and the unit tests share it (tools.test.ts).

export const SCOPES = ['bookings:read', 'bookings:write', 'owners:read', 'owners:write', 'requests:read', 'requests:write'] as const;
export type Scope = (typeof SCOPES)[number];
export const SCOPE_LABEL: Record<Scope, string> = {
  'bookings:read': 'Read bookings', 'bookings:write': 'Change booking details', 'owners:read': 'Read owners', 'owners:write': 'Change owner details',
  'requests:read': 'Read requests', 'requests:write': 'Change requests'
};

export interface Tool { name: string; scope: Scope | 'any'; title: string; description: string; inputSchema: Record<string, unknown>; readOnly: boolean }

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
