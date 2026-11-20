// The mobile API's contract (release 48): every route of /api/m/v1, what it takes and what it gives. One file for both
// sides: the website's route (src/app/api/m/v1) answers from this table, and the native app (apps/carmacars-native)
// builds its typed client from it. Relative imports only, no packages: the app's bundler and both unit test runs read it
// as it is.
//
// The API adds no rule of its own. Each route runs an existing server action or database function as the signed-in
// person (the same accounts as the website), so what a person may read or do is decided where it always was: in the
// database. A new route is added here first; the route file will not compile until it has a handler.
import { arr, bag, bool, num, obj, oneOf, opt, str, type Shape } from './shape.ts';

export const API_PREFIX = '/api/m/v1';
/** Sent by the app with every call ("<app version> <ios|android>"), so the server can tell an app too old to work. */
export const APP_HEADER = 'x-carmacars-app';

// ---------------------------------------------------------------- the envelope
export type ApiOk<T> = { ok: true; data: T };
export type ApiFail = { ok: false; code: string; message: string; fieldErrors?: Record<string, string> };
export type ApiResult<T> = ApiOk<T> | ApiFail;

// ---------------------------------------------------------------- shared values
const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
const DAY = /^\d{4}-\d{2}-\d{2}$/;
const TIME = /^([01]\d|2[0-3]):[0-5]\d$/;
const uuid = (what = 'id') => str({ re: UUID, what });
const b64u = (what: string, max = 8000) => str({ min: 1, max, re: /^[A-Za-z0-9_-]+$/, what });

export const TOPICS = ['requests', 'bookings', 'payments', 'handovers', 'messages', 'alerts', 'documents', 'leads', 'visitors'] as const;
export const PORTALS = ['renter', 'owner', 'investor', 'staff', 'field', 'admin'] as const;
export const UPLOAD_KINDS = ['licence_front', 'licence_back', 'selfie', 'coverage_proof'] as const;
/** The field steps the app takes (the website's own list, src/server/actions/field.ts, checks the name again). */
export const FIELD_ACTIONS = ['acknowledge', 'start', 'save_report', 'complete_handover', 'complete_return', 'block_handover', 'move_start', 'move_end', 'late_damage',
  'checklist_save', 'complete_job', 'identity_in_person', 'deposit_offline', 'shift_take', 'shift_drop', 'shift_cancel', 'offer_claim', 'job_take', 'addon_tick'] as const;
export const LEAD_ACTIONS = ['lead_claim', 'lead_unclaim', 'lead_contact', 'lead_outcome', 'lead_handled', 'lead_next', 'lead_phone_ask'] as const;
export const OFFER_READS = ['offer_form', 'offer_preview', 'find_customers'] as const;
export const OFFER_ACTIONS = ['offer_create', 'offer_revise'] as const;

/** What a passkey prompt answers (WebAuthn's JSON form, as the phone's own passkey sheet returns it). */
const passkeyCreated = obj({ id: b64u('the passkey', 1400), response: obj({ clientDataJSON: b64u('the passkey'), attestationObject: b64u('the passkey', 20000) }) });
const passkeyAsserted = obj({ id: b64u('the passkey', 1400), response: obj({ clientDataJSON: b64u('the passkey'), authenticatorData: b64u('the passkey'), signature: b64u('the passkey') }) });

const esignStep = obj({
  kind: oneOf('viewed', 'document_opened', 'initial', 'initial_clear', 'consent', 'geolocation', 'signature'),
  title: opt(str({ max: 160 })), code: opt(str({ max: 60 })), png: opt(str({ max: 600_000, trim: false })), typed: opt(str({ max: 120 })),
  lat: opt(num({ min: -90, max: 90 })), lng: opt(num({ min: -180, max: 180 })), accuracy: opt(num({ min: 0, max: 100_000 }))
});
const photoRef = obj({ bucket: str({ max: 60 }), path: str({ max: 300 }), angle: opt(str({ max: 40 })) });
const location = obj({ lat: num({ min: -90, max: 90 }), lng: num({ min: -180, max: 180 }), accuracy: num({ min: 0, max: 100_000 }), located_at: str({ max: 40 }) });

// ---------------------------------------------------------------- the routes
export type Method = 'GET' | 'POST' | 'PUT' | 'DELETE';
export interface RouteDef<B = undefined> {
  method: Method;
  /** Under API_PREFIX; ":name" is a path parameter. */
  path: string;
  /** public: no session needed. user: a signed-in account (the database then decides what it may do). */
  auth: 'public' | 'user';
  body?: Shape<B>;
  /** The body is a form with one file (a photo), not JSON. */
  multipart?: boolean;
}
const get = (path: string, auth: RouteDef['auth'] = 'user'): RouteDef => ({ method: 'GET', path, auth });
const send = <B = undefined>(method: Exclude<Method, 'GET'>, path: string, body?: Shape<B>, auth: RouteDef['auth'] = 'user'): RouteDef<B> => ({ method, path, auth, body });
/** A write that takes no body. */
const bare = (method: Exclude<Method, 'GET'>, path: string, auth: RouteDef['auth'] = 'user'): RouteDef => ({ method, path, auth });
const photo = (path: string): RouteDef => ({ method: 'POST', path, auth: 'user', multipart: true });

export const ROUTES = {
  // ---- anyone
  config: get('/config', 'public'),
  cars: get('/cars', 'public'),
  'cars.available': send('POST', '/cars/available', obj({ from: str({ re: DAY, what: 'the pickup date' }), to: str({ re: DAY, what: 'the return date' }), tf: opt(str({ re: TIME })), tt: opt(str({ re: TIME })) }), 'public'),
  car: get('/cars/:slug', 'public'),
  'car.quote': send('POST', '/cars/:slug/quote', obj({ from: str({ re: DAY, what: 'the pickup date' }), to: str({ re: DAY, what: 'the return date' }), tf: opt(str({ re: TIME })), tt: opt(str({ re: TIME })), options: opt(bag({ maxBytes: 4000 })) }), 'public'),
  // ---- sign-in
  'auth.signIn': send('POST', '/auth/sign-in', obj({ email: str({ min: 3, max: 200, what: 'Your email' }), password: str({ min: 1, max: 200, trim: false, what: 'Your password' }) }), 'public'),
  'auth.refresh': send('POST', '/auth/refresh', obj({ refresh_token: str({ min: 10, max: 6000, trim: false }) }), 'public'),
  'auth.phoneStart': send('POST', '/auth/phone/start', obj({ phone: str({ min: 7, max: 30, what: 'Your mobile number' }), turnstile: opt(str({ max: 4000 })) }), 'public'),
  'auth.phoneVerify': send('POST', '/auth/phone/verify', obj({ phone: str({ min: 7, max: 30 }), code: str({ min: 4, max: 12, what: 'The code' }), name: opt(str({ max: 120 })) }), 'public'),
  'auth.passkeyOptions': bare('POST', '/auth/passkey/options', 'public'),
  'auth.passkeyVerify': send('POST', '/auth/passkey/verify', obj({ challenge_id: uuid('the passkey step'), credential: passkeyAsserted }), 'public'),
  'auth.twoStep': send('POST', '/auth/two-step', obj({ code: str({ min: 6, max: 10, what: 'The code' }) })),
  'auth.signOut': bare('POST', '/auth/sign-out'),
  // ---- the account
  me: get('/me'),
  'me.name': send('POST', '/me/name', obj({ name: str({ min: 2, max: 120, what: 'Your name' }) })),
  'me.passkeys': get('/me/passkeys'),
  'me.passkeyOptions': bare('POST', '/me/passkeys/options'),
  'me.passkeyAdd': send('POST', '/me/passkeys', obj({ challenge_id: uuid('the passkey step'), credential: passkeyCreated, device: opt(str({ max: 60 })) })),
  'me.passkeyRemove': bare('DELETE', '/me/passkeys/:id'),
  'me.deletionAsk': send('POST', '/me/deletion', obj({ reason: opt(str({ max: 500 })) })),
  'me.deletionWithdraw': bare('DELETE', '/me/deletion'),
  'me.pushOn': send('POST', '/me/push', obj({ token: str({ min: 20, max: 4096, trim: false }), platform: oneOf('ios', 'android'), portal: opt(oneOf(...PORTALS)), device: opt(str({ max: 60 })) })),
  'me.pushOff': send('POST', '/me/push/off', obj({ token: str({ min: 20, max: 4096, trim: false }) })),
  'me.pushTest': bare('POST', '/me/push/test'),
  'me.pushTopics': send('PUT', '/me/push/topics', obj({ topics: arr(oneOf(...TOPICS), { max: 20 }) })),
  // r48 (3260): each kind of notification by channel, quiet hours, instant or a summary (?portal= one of the person's portals)
  'me.notifyPrefs': get('/me/notification-preferences'),
  'me.notifyPrefsSave': send('PUT', '/me/notification-preferences', obj({ portal: opt(oneOf('renter', 'owner', 'investor', 'staff', 'admin')),
    type: opt(str({ re: /^[a-z][a-z0-9_]{2,40}$/, what: 'the kind of notification' })), channel: opt(oneOf('push', 'email', 'text')), on: opt(bool),
    quiet_on: opt(bool), quiet_from: opt(num({ int: true, min: 0, max: 1439 })), quiet_until: opt(num({ int: true, min: 0, max: 1439 })),
    cadence: opt(oneOf('instant', 'daily', 'weekly')), all_off: opt(bool) })),
  // r48 (3261, 3262): the staff member's My rewards and the owner's Rewards, as the portals show them
  'staff.rewards': get('/staff/rewards'),
  'owner.rewards': get('/owner/rewards'),
  notices: get('/notices'),
  'notices.read': send('POST', '/notices/read', obj({ ids: opt(arr(uuid(), { max: 200 })) })),
  // ---- renter
  trips: get('/trips'),
  trip: get('/trips/:number'),
  'trip.message': send('POST', '/trips/:number/messages', obj({ body: str({ min: 2, max: 4000, what: 'Your message' }) })),
  'request.account': get('/requests/account'),
  'request.submit': send('POST', '/requests', obj({ data: bag({ maxBytes: 60_000 }), requestKey: str({ re: /^[A-Za-z0-9-]{8,100}$/ }), turnstile: opt(str({ max: 4000 })), bookNow: opt(bool) })),
  'trip.offer': send('POST', '/trips/:number/offer', obj({ action: oneOf('approve', 'decline', 'change'), version: opt(num({ int: true, min: 1 })), note: opt(str({ max: 2000 })) })),
  'trip.agreement': get('/trips/:number/agreement'),
  'trip.esign': send('POST', '/trips/:number/esign', obj({ op: oneOf('start', 'send_code', 'check_code', 'step', 'use_saved'), session: opt(uuid('the signing')), channel: opt(oneOf('sms', 'email')),
    code: opt(str({ max: 12 })), step: opt(esignStep), part: opt(oneOf('initials', 'signature')) })),
  'trip.sign': send('POST', '/trips/:number/sign', obj({ typedName: opt(str({ max: 120 })), drawn: opt(str({ max: 600_000, trim: false })), consents: arr(str({ max: 60 }), { max: 10 }),
    sha: str({ re: /^[0-9a-f]{64}$/i, what: 'the agreement' }), companionSha: opt(str({ re: /^[0-9a-f]{64}$/i })), session: opt(uuid('the signing')), drawnPath: opt(str({ max: 200 })) })),
  'trip.payStart': bare('POST', '/trips/:number/payment'),
  'trip.payFinish': send('POST', '/trips/:number/payment/finish', obj({ intentId: str({ min: 3, max: 200 }) })),
  'trip.upload': send('POST', '/trips/:number/uploads', obj({ kind: oneOf(...UPLOAD_KINDS), driverId: opt(uuid('the driver')), contentType: oneOf('image/jpeg', 'image/png', 'application/pdf'), size: num({ int: true, min: 1, max: 20_000_000 }) })),
  'upload.confirm': send('POST', '/uploads/confirm', obj({ ticket: str({ min: 10, max: 4000, trim: false }), details: opt(bag({ maxBytes: 4000 })) })),
  'trip.licence': send('POST', '/trips/:number/licence', obj({ licence_number: str({ min: 3, max: 40, what: 'The licence number' }), licence_class: str({ min: 1, max: 20 }), licence_issuer: str({ min: 2, max: 100 }), licence_expiry: str({ re: DAY, what: 'The expiry date' }) })),
  'trip.checkinPhoto': photo('/trips/:number/checkin/photos'),
  'trip.checkin': send('POST', '/trips/:number/checkin', obj({ at: opt(str({ max: 40 })), odometer_km: opt(str({ max: 12 })), fuel_pct: opt(str({ max: 6 })), note: opt(str({ max: 2000 })),
    photos: arr(photoRef, { max: 40 }), reading: opt(bag({ maxBytes: 8000 })) })),
  'trip.returnPhoto': photo('/trips/:number/return/photos'),
  'trip.return': send('POST', '/trips/:number/return', obj({ returned_at: opt(str({ max: 40 })), odometer_km: opt(str({ max: 12 })), fuel_pct: opt(str({ max: 6 })), note: opt(str({ max: 1000 })),
    photos: arr(photoRef, { max: 30 }), reading: opt(bag({ maxBytes: 8000 })) })),
  'trip.extendPreview': send('POST', '/trips/:number/extension/preview', obj({ newReturn: str({ min: 10, max: 40, what: 'The new return time' }) })),
  'trip.extend': send('POST', '/trips/:number/extension', obj({ newReturn: str({ min: 10, max: 40, what: 'The new return time' }), note: opt(str({ max: 1000 })) })),
  'trip.extendPay': bare('POST', '/trips/:number/extension/:id/pay'),
  'trip.cancelPreview': get('/trips/:number/cancellation'),
  'trip.cancel': send('POST', '/trips/:number/cancellation', obj({ typed: str({ min: 1, max: 40 }) })),
  // ---- field staff
  'field.today': get('/field/today'),
  'field.jobs': get('/field/jobs'),
  'field.job': get('/field/jobs/:id'),
  'field.shifts': get('/field/shifts'),
  'field.act': send('POST', '/field/act', obj({ action: oneOf(...FIELD_ACTIONS), p: bag() })),
  'field.clock': send('POST', '/field/clock', obj({ what: oneOf('in', 'out'), note: opt(str({ max: 500 })), loc: opt(location), reason: opt(str({ max: 300 })), openReasons: opt(bag({ maxBytes: 4000 })) })),
  'field.photo': photo('/field/jobs/:id/photos'),
  // ---- sales
  'sales.leads': get('/sales/leads'),
  'sales.lead': get('/sales/leads/:id'),
  'sales.leadAct': send('POST', '/sales/leads/act', obj({ action: oneOf(...LEAD_ACTIONS), p: bag({ maxBytes: 8000 }) })),
  'sales.phoneButtons': get('/sales/phone'),
  'sales.phone': send('POST', '/sales/phone', obj({ action: oneOf('phone_call', 'phone_compose'), number: str({ min: 5, max: 40, what: 'The number' }), body: opt(str({ max: 1600 })),
    booking_number: opt(str({ max: 20 })), name: opt(str({ max: 120 })), key: opt(str({ max: 64 })) })),
  'sales.offerRead': send('POST', '/sales/offers/read', obj({ what: oneOf(...OFFER_READS), p: bag({ maxBytes: 20_000 }) })),
  'sales.offer': send('POST', '/sales/offers', obj({ action: oneOf(...OFFER_ACTIONS), p: bag({ maxBytes: 60_000 }) })),
  // ---- owner
  'owner.home': get('/owner'),
  'owner.bookings': get('/owner/bookings'),
  'owner.statement': get('/owner/statements/:id')
} as const satisfies Record<string, RouteDef<never> | RouteDef<unknown>>;

export type RouteId = keyof typeof ROUTES;
export type BodyOf<I extends RouteId> = (typeof ROUTES)[I] extends RouteDef<infer B> ? B : undefined;
export const ROUTE_IDS = Object.keys(ROUTES) as RouteId[];

/** The route's address with its parameters filled in ("/trips/CC-1042"). */
export function routePath(id: RouteId, params: Record<string, string> = {}): string {
  return (ROUTES[id] as RouteDef).path.replace(/:([a-z]+)/g, (_, k: string) => {
    const v = params[k];
    if (!v) throw new Error(`Missing ${k} for ${id}`);
    return encodeURIComponent(v);
  });
}

/** Which route a request is for. Path segments after /api/m/v1, already decoded. Null: no such route. */
export function matchRoute(method: string, segments: readonly string[]): { id: RouteId; params: Record<string, string> } | null {
  const m = method.toUpperCase();
  for (const id of ROUTE_IDS) {
    const def = ROUTES[id] as RouteDef;
    if (def.method !== m) continue;
    const want = def.path.split('/').filter(Boolean);
    if (want.length !== segments.length) continue;
    const params: Record<string, string> = {};
    let ok = true;
    for (let i = 0; i < want.length; i++) {
      const w = want[i]!; const s = segments[i]!;
      if (w.startsWith(':')) { if (!s || s.length > 200) { ok = false; break; } params[w.slice(1)] = s; }
      else if (w !== s) { ok = false; break; }
    }
    if (ok) return { id, params };
  }
  return null;
}

/** "Bearer <token>" from the Authorization header, or null. */
export function bearerOf(header: string | null | undefined): string | null {
  const m = /^Bearer\s+([A-Za-z0-9._~+/=-]{20,6000})$/i.exec((header ?? '').trim());
  return m ? m[1]! : null;
}

// ---------------------------------------------------------------- what comes back
export interface MobileUser { id: string; email: string; phone: string | null }
export interface MobileSession { access_token: string; refresh_token: string; expires_at: number; user: MobileUser }
export type Portal = (typeof PORTALS)[number];
export interface Roles { admin: boolean; va: 'finance' | 'fleet' | 'cs' | 'sales' | null; va_functions?: string[]; field: boolean; owner: boolean; renter: boolean; investor: boolean; staff: boolean;
  two_step_required: boolean; name: string | null; greeting?: string | null; onboarding_locked?: boolean; academy_locked?: boolean; agreement_locked?: boolean; inactive_locked?: boolean }
export interface Deletion { allowed: boolean; request: { status: 'open' | 'done' | 'withdrawn'; requested_at: string; closed_at: string | null } | null }
export interface PushState { enabled: boolean; role: Portal; topics: string[]; defaults: string[]; chosen: boolean; this_device: boolean | null; devices: Array<{ id: string; device: string; created_at: string; this: boolean }> }
export interface Me { user: MobileUser; aal: 'aal1' | 'aal2'; roles: Roles; needs_two_step: boolean; deletion: Deletion | null; push: PushState | null; push_available: boolean }
export interface AppConfig {
  site_url: string; brand: string; phone: string | null; email: string | null;
  stripe_publishable_key: string | null; payments: 'stripe' | 'fake';
  phone_sign_in: { enabled: boolean; us_allowed: boolean; code_length: number };
  passkeys: { rp_id: string }; push: boolean; turnstile: 'cloudflare' | 'fake' | 'off';
  /** The oldest app build that still works with this server; an older app shows "Update the app". */
  min_app_version: string;
  rules: { min_age: number; max_days: number; notice_minutes: number; licence_classes: string[] };
  airports: Array<{ code: string; name: string }>;
}
export interface Photo { url: string; alt?: string | null; width?: number | null; height?: number | null }
export interface CarCard {
  vehicle_id: string; slug: string; year: number | null; make: string; model: string; trim?: string | null; classes: string[]; seats: number | null; transmission: string | null; fuel: string | null;
  colour?: string | null; daily_rate_cents: number; cover: Photo | null; insurance_included?: boolean;
}
export interface Available { vehicle_id: string; slug: string; daily_rate_cents: number; billable_days: number; rental_charge_cents: number; subtotal_cents: number; hst_cents: number; total_cents: number; deposit_cents: number }
export interface Fleet { cars: CarCard[]; classes: Array<{ code: string; label: string }> }
export interface CarPage { car: Record<string, unknown> & { vehicle_id: string; slug: string; make: string; model: string; year?: number | null }; photos: Photo[]; places: { owner_location: boolean; area: string | null } | null;
  unavailable: Array<{ unavailable_from: string; unavailable_to: string }>; addons: unknown }
export interface PasskeyOptions { challenge_id: string; challenge: string; rp_id: string; rp_name: string; user?: { id: string; name: string; display_name: string }; exclude?: string[] }
export interface PasskeyRow { id: string; device: string | null; created_at: string; last_used_at: string | null }
export interface StartedPayment { provider: 'stripe' | 'fake'; intentId: string; clientSecret: string; amountCents: number; publishableKey: string | null; legalName: string; coverageNetwork: { brand: string; label: string } | null }
export interface UploadSlot { url: string; headers: Record<string, string>; ticket: string }
export interface EsignView {
  id: string; signer_name: string; channels: Array<{ channel: 'sms' | 'email'; to: string }>; code_sent_to: string | null; verified: boolean; viewed: boolean; code_required: boolean;
  required_initials: string[]; required_consents: string[]; initials: string[]; consents: string[]; signature: 'drawn' | 'typed' | null; typed_fallback_allowed: boolean; signed: boolean; ready: boolean;
  default_channel?: 'sms' | 'email' | null; devCode?: string; path?: string;
}
export type AgreementBlock = { t: 'title' | 'h2' | 'h3' | 'p' | 'ul' | 'ol' | 'table' | 'signatures' | 'initials'; text?: string; items?: string[]; head?: string[]; rows?: unknown[]; kv?: boolean };
export interface AgreementView { sha: string; companionSha: string | null; status: string; blocks: AgreementBlock[]; consents: Array<{ code: string; title: string; text: string }>;
  esignConsents: Record<string, string>; statement: string; legalName: string; documentId: string;
  /** the key terms the signer initials, by the code the signing session asks for */
  terms: Array<{ code: string; title: string; text: string }> }

/** What each route answers with; a route not listed answers with whatever its server action returns. */
export interface Responses {
  config: AppConfig; cars: Fleet; 'cars.available': Available[]; car: CarPage;
  'auth.signIn': MobileSession; 'auth.refresh': MobileSession; 'auth.phoneStart': { phone: string; display: string }; 'auth.phoneVerify': MobileSession & { needs_name?: boolean };
  'auth.passkeyOptions': PasskeyOptions; 'auth.passkeyVerify': MobileSession; 'auth.twoStep': MobileSession;
  me: Me; 'me.passkeys': PasskeyRow[]; 'me.passkeyOptions': PasskeyOptions; 'me.passkeyAdd': PasskeyRow[]; 'me.passkeyRemove': PasskeyRow[];
  'me.deletionAsk': Deletion; 'me.deletionWithdraw': Deletion; 'me.pushOn': PushState; 'me.pushOff': PushState; 'me.pushTopics': PushState; 'me.pushTest': { queued: number };
  'trip.payStart': StartedPayment; 'trip.upload': UploadSlot; 'trip.agreement': AgreementView; 'trip.esign': EsignView;
  'trip.checkinPhoto': { bucket: string; path: string }; 'trip.returnPhoto': { bucket: string; path: string }; 'trip.checkin': { status: string; reason?: string }; 'trip.return': { status: string }; 'field.photo': { key: string; problems?: string[] };
}
export type ResponseOf<I extends RouteId> = I extends keyof Responses ? Responses[I] : unknown;

/** Compares "1.4.0" style versions: negative when a is older than b. */
export function compareVersions(a: string, b: string): number {
  const [x, y] = [a, b].map((v) => v.split('.').map((n) => parseInt(n, 10) || 0));
  for (let i = 0; i < 3; i++) { const d = (x![i] ?? 0) - (y![i] ?? 0); if (d) return d; }
  return 0;
}
