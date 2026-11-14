'use server';
import { cookies } from 'next/headers';
import { bookNowAgreement } from '@/server/book-now';
import { auth } from '@/lib/auth';
import { DbError, rpc } from '@/lib/db/repo';
import type { Json } from '@/lib/db/types';
import { torontoInstant, torontoMinutesNow, torontoToday, validIso, validTime } from '@/lib/dates';
import { getFacts, getFleet } from '@/lib/site';
import { consentTexts, rules } from '@/server/booking-data';
import { maps } from '@/integrations/maps';
import { verifyTurnstile } from '@/integrations/turnstile';
import { dobIso, migrateExtras, requestSchema, type RequestData } from '@/features/booking/schema';
import type { RenterProfile } from '@/features/booking/profile-fill';
import { typedReferralCode } from '@/features/referral/model';
import { addonsPayload } from '@/features/addons/model';
import type { ActionResult } from '@/features/forms/schemas';
import { addonsNote, refusalResult, transient, uniqueDrivers, type Refusal } from '@/features/booking/refusal';
import { requestMeta } from '@/server/request';
import { captureDone, pendingAddBooking, visitorCookie } from '@/server/capture';
import { PARTNER_COOKIE } from '@/features/partner-crm/feed-key';

// Request to book (docs/blueprint/02-booking-and-renter.md section 3). The server validates with the
// same schema as the browser, checks Turnstile, measures any delivery distance itself, and calls
// public.submit_booking_request once as the server, with the idempotency key from the browser.
// No card and no payment at this step.

const TOKEN = /^[A-Za-z0-9_-]{8,64}$/;
// the road distance and the place itself (1403: without a road distance the database prices the straight line from the
// company's location to the place times the road factor)
interface Measured { km: number | null; lat: number | null; lng: number | null }
async function distance(placeId: string, session?: string): Promise<Measured> {
  const none: Measured = { km: null, lat: null, lng: null };
  if (!placeId) return none;
  try {
    const m = await maps();
    const p = await m.place(placeId, session && TOKEN.test(session) ? session : crypto.randomUUID());
    if (!p) return none;
    const origin = (await rpc('delivery_origin', {}, { role: 'service_role' })) as unknown as { lat: number; lng: number } | null;
    const km = origin ? await m.distanceKm(origin, { lat: p.lat, lng: p.lng }).catch(() => null) : null;
    return { km, lat: p.lat, lng: p.lng };
  } catch {
    return none;
  }
}

export interface SubmitInput { data: RequestData; requestKey: string; token: string | null; draftId?: string | null;
  /** r40 (2430): the renter pressed Book now (only offered to a renter who may book at once): pay the website price. Without it every request stays a request. */ bookNow?: boolean }
export type SubmitResult = ActionResult<{ bookingNumber: string; totalCents: number | null; depositCents: number | null; created: boolean;
  /** r35a (1304): booked at once (a verified repeat renter): the renter goes to Sign and pay */ instant?: boolean }>;

/** A request that was refused or failed (2670): the database gives the code, the field and the plain message, keeps who
 *  asked with the car, the dates and the reason (once per person, car and day) and raises one Sales To-do. */
async function failed(p: { code?: string; message?: string; request?: unknown; data: RequestData; ip: string | null; user?: string | null; vehicleId?: string | null }): Promise<Extract<SubmitResult, { ok: false }>> {
  let body: Record<string, unknown> = { code: p.code ?? null, message: p.message ?? null, ip: p.ip, user: p.user ?? null };
  try {
    const d = p.data ?? ({} as RequestData);
    const str = (v: unknown, n: number) => (typeof v === 'string' ? v.trim().slice(0, n) : '');
    const at = (iso: unknown, t: unknown) => (validIso(iso as string) && validTime(t as string) ? torontoInstant(iso as string, t as string) : null);
    body = { ...body, request: p.request ?? null, vehicle_id: p.vehicleId ?? null, pickup_at: at(d.from, d.tf), return_at: at(d.to, d.tt),
      contact: { email: str(d.email, 200), phone: str(d.phone, 30), name: `${str(d.first, 60)} ${str(d.last, 60)}`.trim() } };
  } catch { /* what the browser sent could not be read: the reason is still returned */ }
  const r = (await rpc('server_booking_request_failed', { p: body as unknown as Json }, { role: 'service_role' }).catch(() => null)) as unknown as Refusal | null;
  return refusalResult(r);
}

export async function submitBookingRequest(input: SubmitInput): Promise<SubmitResult> {
  const meta = await requestMeta();
  let signedIn: Awaited<ReturnType<Awaited<ReturnType<typeof auth>>['currentUser']>> = null;
  let request: Record<string, unknown> | null = null;
  let vehicleId: string | null = null;
  const fail = (code?: string, message?: string) => failed({ code, message, request, data: input.data, ip: meta.ip, user: signedIn?.id, vehicleId });
  try {
    if (!(await verifyTurnstile(input.token, meta.ip))) return { ...(await fail('security_check')), code: 'turnstile' };
    if (!/^[A-Za-z0-9-]{8,100}$/.test(input.requestKey ?? '')) return { ok: false, code: 'reload', message: 'Reload the page and press Send request again. Your answers are saved.' };
    const [r, fleet, f, consent, me] = await Promise.all([rules(), getFleet(), getFacts(), consentTexts(), (async () => (await auth()).currentUser())()]);
    signedIn = me;
    // an account made by phone may send a request before it has an email (asked on the pay page; 0091)
    const emailOptional = !!signedIn && !signedIn.email;
    const parsed = requestSchema(r, { todayIso: torontoToday(), nowMinutes: torontoMinutesNow(), knownCar: (s) => fleet.some((c) => c.slug === s), emailOptional,
      insuranceIncluded: (s) => fleet.some((c) => c.slug === s && !!c.insurance_included) }).safeParse(input.data);
    if (!parsed.success) {
      const fe: Record<string, string> = {};
      for (const i of parsed.error.issues) { const k = i.path.join('.'); if (!(k in fe)) fe[k] = i.message; }
      const first = Object.values(fe)[0] ?? 'Check the highlighted fields.';
      vehicleId = fleet.find((c) => c.slug === input.data?.car)?.vehicle_id ?? null;
      // kept for staff too (a pickup time that passed while the form was open, an older browser tab)
      await fail('invalid', first);
      return { ok: false, code: 'invalid', message: Object.keys(fe).length === 1 ? first : 'Check the highlighted fields: each one says what to change.', fieldErrors: fe };
    }
    const v = parsed.data;
    const car = fleet.find((c) => c.slug === v.car)!;
    vehicleId = car.vehicle_id;
    const airport = (code: string) => f.airports.find((a) => a.code === code);
    const returnAddress = v.returnAt === 'delivery' ? (v.returnAddress.label.trim() ? v.returnAddress : v.pickupAddress) : v.returnAddress;
    // a delivery and a return to the same place ask Google once (each lookup counts against the daily cap, 0113)
    const distances = new Map<string, Promise<Measured>>();
    const distanceOnce = (addr: { placeId: string; session?: string }) => {
      if (!distances.has(addr.placeId)) distances.set(addr.placeId, distance(addr.placeId, addr.session));
      return distances.get(addr.placeId)!;
    };
    const loc = async (kind: string, addr: { label: string; placeId: string; session?: string }, ap: string) => {
      if (kind === 'owner') return { kind: 'owner_location' };
      if (kind === 'airport') return { kind: 'airport', airport_code: ap };
      if (kind === 'delivery') { const d = await distanceOnce(addr); return { kind: 'delivery', address: addr.label, distance_km: d.km, lat: d.lat, lng: d.lng }; }
      return { kind: 'our_location' };
    };
    const far = (k: string) => k === 'delivery' || k === 'airport';
    const lic = v.licClass === 'other' ? 'OTHER' : v.licClass;
    const user = signedIn;
    const cookieRef = (await cookies()).get('cc-ref')?.value?.toUpperCase() ?? null;
    const renter = { email: v.email, full_name: `${v.first} ${v.last}`, mobile: v.phone, date_of_birth: dobIso(v.dobY, v.dobM, v.dobD), licence_class: lic, licence_issuer: v.licClass === 'other' ? v.licIssuer : 'ON' };

    request = {
      request_key: input.requestKey,
      vehicle_id: car.vehicle_id,
      pickup_at: torontoInstant(v.from, v.tf),
      return_at: torontoInstant(v.to, v.tt),
      booking_type: v.bookingType,
      pickup_method: far(v.pickupAt) ? 'delivered' : 'collected',
      return_method: far(v.returnAt) ? 'picked_up' : 'returned',
      // 2670: an airport our list no longer names keeps its code, so the request is not refused for "no address"
      pickup_place: v.pickupAt === 'delivery' ? v.pickupAddress.label : v.pickupAt === 'airport' ? (airport(v.pickupAirport)?.name ?? v.pickupAirport) : null,
      return_place: v.returnAt === 'delivery' ? returnAddress.label : v.returnAt === 'airport' ? (airport(v.returnAirport)?.name ?? v.returnAirport) : null,
      pickup_location: await loc(v.pickupAt, v.pickupAddress, v.pickupAirport),
      return_location: await loc(v.returnAt, returnAddress, v.returnAirport),
      note: v.notes.trim() || null,
      coverage_option: Number(v.coverage),
      // 2541: the card picked from the list and the acknowledgements; the database refuses a website request without them
      coverage_choice: { card: v.coverage === '2' && /^[0-9a-f-]{36}$/i.test(v.coverageCard) ? v.coverageCard : null, card_ack: v.coverage === '2' && v.coverageCardAck, opcf27_ack: v.coverage === '1' && v.opcfAck },
      // 0066: add-ons (an older draft's winter tires and baby seats included); the database checks notice and stock
      addons: addonsPayload(migrateExtras(v).addons),
      renter,
      // 2670: the renter or the same driver listed twice is sent once (the database refuses the whole request for a copy)
      additional_drivers: uniqueDrivers(renter, v.drivers.map((d) => ({ full_name: `${d.first} ${d.last}`, date_of_birth: dobIso(d.dobY, d.dobM, d.dobD), email: d.email, licence_class: d.licClass || null }))),
      consents: {
        terms: { accepted: v.agree, version: consent.terms.version, text: consent.agreeLine(r.minAge) },
        privacy: { accepted: v.agree, version: consent.privacy.version, text: consent.agreeLine(r.minAge) },
        marketing: { opted_in: v.marketing, version: consent.marketing.version, text: consent.marketing.text }
      },
      // a referral link (/r/<code>: a field staff member's or an owner's) kept for 30 days
      promo_code: v.promo ? v.promo.toUpperCase() : null,
      // a code typed in the form (a partner's code from a flyer) wins over the link's cookie when it is written like a code
      // (capitals or digits); a plain word such as a first name is only a code when there is no cookie. The database ignores a code nobody holds.
      referred_by_code: (() => {
        const c = cookieRef && /^[A-Z0-9]{4,12}$/.test(cookieRef) ? cookieRef : null;
        const typed = typedReferralCode(v.referrer);
        const codeLike = typed !== null && (/\d/.test(typed) || v.referrer.trim() === typed);
        return codeLike ? typed : (c ?? typed);
      })(),
      details: { referrer_name: v.referrer || null, pickup_place_id: v.pickupAddress.placeId || null, return_place_id: returnAddress.placeId || null, source: 'web' }
    };

    const call = (pUser?: string) => rpc('submit_booking_request', { p_request: request as unknown as Json, p_ip: meta.ip ?? undefined, p_user_agent: meta.userAgent, p_user: pUser }, { role: 'service_role', requestId: meta.requestId });
    // a sign-in account without its users row yet: send the request as a visitor
    const once = async () => {
      try { return (await call(user?.id)) as unknown as Record<string, unknown>; } catch (e) {
        if (user && e instanceof DbError && /Unknown user/.test(e.message)) return (await call()) as unknown as Record<string, unknown>;
        throw e;
      }
    };
    let res: Record<string, unknown>;
    try {
      // 2670: a busy database or no answer is tried once more (the request key makes a second send safe)
      try { res = await once(); } catch (e) { if (!transient(e)) throw e; res = await once(); }
    } catch (e) {
      const why = await fail(undefined, e instanceof Error ? e.message : String(e));
      // 2670: an add-on that cannot be added online never stops the request: it is sent without the add-ons, which are
      // named in the note for staff to confirm in the offer
      const asked = request.addons as Array<{ code: string; quantity: number; hours?: number | null }>;
      if (!(why.fieldErrors?.addons && asked.length)) return why;
      request = { ...request, addons: [], note: addonsNote(request.note as string | null, asked, r.noteMax) };
      try { res = await once(); } catch (e2) { return await fail(undefined, e2 instanceof Error ? e2.message : String(e2)); }
    }
    if (!res.ok) return await fail(String(res.error ?? 'refused'), String(res.message ?? ''));
    const data = { bookingNumber: String(res.booking_number), totalCents: (res.total_due_at_booking_cents as number) ?? null, depositCents: (res.deposit_cents as number) ?? null, created: res.created === true, instant: false };
    // the request is in: nothing below may turn it into a failure
    try {
      // 1202: the Protection Plan priced from a RentalCover quote for this renter and these dates (none: its table price)
      if (Number(v.coverage) === 3) await (await import('@/server/rentalcover')).rentalcoverForRequest(String(res.booking_number)).catch(() => undefined);
      // 0096: how we reach the renter, chosen in the form (empty: the default)
      if (v.notifyChannel) await rpc('server_request_notify_channel', { p_booking_number: String(res.booking_number), p_channel: v.notifyChannel, p_user: user?.id }, { role: 'service_role' }).catch(() => undefined);
      // 0410: "How did you hear about us?" (empty: not answered)
      if (v.heardAbout) await rpc('server_booking_heard_about', { p_booking_number: String(res.booking_number), p_value: v.heardAbout }, { role: 'service_role' }).catch(() => undefined);
      // 0147: a partner's booking link sent this visitor (/p/<code>/<car>): the partner gets the lead when leads are on
      const partnerRef = (await cookies()).get(PARTNER_COOKIE)?.value ?? null;
      if (partnerRef && /^[a-z0-9]+(-[a-z0-9]+)*$/.test(partnerRef) && partnerRef.length <= 30) await rpc('server_partner_referral', { p: { booking_number: String(res.booking_number), code: partnerRef } }, { role: 'service_role' }).catch(() => undefined);
      if (input.draftId) await rpc('submit_form_draft', { p_draft: input.draftId, p_result: { booking_number: String(res.booking_number) } }, { role: 'service_role' }).catch(() => undefined);
      // contact capture (0090): the request is visible to this browser's unverified session (if it has one), and the
      // contact saved as it was typed is done
      if (!user) await pendingAddBooking(String(res.booking_number));
      await captureDone('booking_request');
      // 0280: the request counts for the phone number box report (from a visitor who saw the box, or not); no personal data
      if (res.created !== false) await rpc('server_phone_gate_request', { p: { visitor_id: await visitorCookie() } as unknown as Json }, { role: 'service_role' }).catch(() => undefined);
      // r35a (1304), r40 (2430): a renter who may book at once (a verified repeat renter, or Gold) chooses: Send request leaves
      // a request, as for a first booking; Book now (bookNow) asks the database to book at once (eligible, the car free, the licence
      // on file), makes the agreement as for Book it now and goes straight to Sign and pay. If the database refuses, it stays a request.
      if (user && input.bookNow === true && res.created !== false) {
        const ib = (await rpc('server_instant_book', { p_number: String(res.booking_number), p_user: user.id }, { role: 'service_role' }).catch(() => null)) as unknown as { instant?: boolean; status?: string; booking_id?: string; renter_user_id?: string } | null;
        if (ib?.instant) { data.instant = true; await bookNowAgreement(ib).catch(() => undefined); }
      }
    } catch { /* the request is in; the extras above are done again by staff or the next visit */ }
    return { ok: true, data };
  } catch (e) {
    // nothing planned for: kept for staff with the error's own words; the person is told we will contact them
    return await fail(undefined, e instanceof Error ? e.message : String(e));
  }
}

// ---------------------------------------------------------------- drafts (form_drafts, 0022)
export async function saveRequestDraft(input: { data: RequestData; step: number; token: string | null }): Promise<ActionResult<{ token: string | null; draftId: string; savedAt: string }>> {
  try {
    const user = await (await auth()).currentUser();
    const call = (token: string | null) => rpc('save_form_draft', { p_form_code: 'booking_request', p_data: input.data, p_step: String(input.step), p_schema_version: 1, p_user: user ? user.id : undefined, p_token: user ? undefined : token ?? undefined, p_device_label: 'web' }, { role: 'service_role' });
    let r: Record<string, unknown>;
    try { r = (await call(input.token)) as unknown as Record<string, unknown>; } catch (e) {
      if (input.token && e instanceof DbError && e.code === 'P0002') r = (await call(null)) as unknown as Record<string, unknown>; else throw e;
    }
    return { ok: true, data: { token: (r.token as string | null) ?? input.token, draftId: String(r.draft_id), savedAt: String(r.saved_at) } };
  } catch (e) {
    return { ok: false, code: 'draft', message: e instanceof Error ? e.message : 'Not saved' };
  }
}

export async function loadRequestDraft(token: string | null): Promise<ActionResult<{ data: RequestData; step: number; draftId: string } | null>> {
  try {
    const user = await (await auth()).currentUser();
    if (!user && !token) return { ok: true, data: null };
    const r = (await rpc('load_form_draft', { p_form_code: 'booking_request', p_user: user?.id, p_token: user ? undefined : token ?? undefined }, { role: 'service_role' })) as unknown as { draft_id: string; data: RequestData; step: string | null } | null;
    return { ok: true, data: r ? { data: r.data, step: Number(r.step ?? 1) || 1, draftId: r.draft_id } : null };
  } catch {
    return { ok: true, data: null };
  }
}

/** The signed-in person's contact details for the request form (0091): an account made by phone has a verified
 *  number and may have no email yet. r40 (2423): with the discount codes they can use now, for "Use a saved discount". */
export type SavedCode = { code: string; what: string; days_left: number | null };
export async function requestAccount(): Promise<ActionResult<{ signedIn: boolean; email: string | null; phone: string | null; discounts: SavedCode[]; canBookNow: boolean; profile: RenterProfile | null }>> {
  const user = await (await auth()).currentUser();
  // nobody signed in: nothing private reaches the browser
  if (!user) return { ok: true, data: { signedIn: false, email: null, phone: null, discounts: [], canBookNow: false, profile: null } };
  const [si, profile, saved, bookNow] = await Promise.all([
    rpc('server_my_sign_in', { p_user: user.id }, { role: 'service_role' }).catch(() => null) as Promise<unknown>,
    // r45 (2860): the renter's own profile fills the request (the licence number only as its last 4)
    rpc('server_request_profile', { p_user: user.id }, { role: 'service_role' }).catch(() => null) as Promise<unknown>,
    rpc('server_my_discounts' as never, { p_user: user.id } as never, { role: 'service_role' }).catch(() => []) as Promise<unknown>,
    // r40 (2430): may this renter book at once (a verified repeat renter, or Gold)? Then the form offers Book now beside Send request
    rpc('server_instant_book_available' as never, { p_user: user.id } as never, { role: 'service_role' }).catch(() => false) as Promise<unknown>]);
  const c = si as { email: string | null; phone: string | null } | null;
  const { usableDiscounts } = await import('@/features/rewards/discounts');
  return { ok: true, data: { signedIn: true, email: c?.email ?? (user.email || null), phone: c?.phone ?? user.phone ?? null, discounts: usableDiscounts(saved as never).slice(0, 6), canBookNow: bookNow === true, profile: (profile as RenterProfile | null) ?? null } };
}

// ---------------------------------------------------------------- 2541: the card checker in the request form
export interface CoverageCardCheck { result: 'covered' | 'not_covered' | 'review'; card_id: string | null; card_label?: string; message: string; problem: string | null }
/** The cards on our list (for the form's picker) and, with a card, whether it covers this car for these dates. */
export async function coverageCards(): Promise<Array<{ id: string; label: string }>> {
  const list = (await rpc('card_coverage_public', {}).catch(() => null)) as unknown as { cards?: Array<{ id: string; issuer: string; card: string; is_active: boolean; coverage: string }> } | null;
  return (list?.cards ?? []).filter((c) => c.is_active && c.coverage !== 'none').map((c) => ({ id: c.id, label: `${c.issuer} ${c.card}` }));
}
export async function coverageCardCheck(p: { car: string; from: string; to: string; card: string; ack: boolean }): Promise<CoverageCardCheck | null> {
  try {
    const car = (await getFleet()).find((c) => c.slug === p.car);
    if (!car || !/^[0-9a-f-]{36}$/i.test(p.card) || !p.from || !p.to) return null;
    return (await rpc('server_coverage_choice_check' as never, { p: { vehicle_id: car.vehicle_id, option: 2, card: p.card, card_ack: p.ack,
      pickup_at: torontoInstant(p.from, '10:00'), return_at: torontoInstant(p.to, '10:00') } } as never, { role: 'service_role' })) as unknown as CoverageCardCheck;
  } catch { return null; }
}
