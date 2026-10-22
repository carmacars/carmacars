'use server';
import { cookies } from 'next/headers';
import { auth } from '@/lib/auth';
import { DbError, rpc } from '@/lib/db/repo';
import { torontoInstant, torontoMinutesNow, torontoToday } from '@/lib/dates';
import { getFacts, getFleet } from '@/lib/site';
import { consentTexts, rules } from '@/server/booking-data';
import { maps } from '@/integrations/maps';
import { verifyTurnstile } from '@/integrations/turnstile';
import { dobIso, migrateExtras, requestSchema, type RequestData } from '@/features/booking/schema';
import { addonsPayload } from '@/features/addons/model';
import type { ActionResult } from '@/features/forms/schemas';
import { requestMeta } from '@/server/request';
import { captureDone, pendingAddBooking } from '@/server/capture';

// Request to book (docs/blueprint/02-booking-and-renter.md section 3). The server validates with the
// same schema as the browser, checks Turnstile, measures any delivery distance itself, and calls
// public.submit_booking_request once as the server, with the idempotency key from the browser.
// No card and no payment at this step.

async function distance(placeId: string): Promise<number | null> {
  if (!placeId) return null;
  try {
    const origin = (await rpc('delivery_origin', {}, { role: 'service_role' })) as unknown as { lat: number; lng: number } | null;
    if (!origin) return null;
    const m = await maps();
    const p = await m.place(placeId, crypto.randomUUID());
    return p ? await m.distanceKm(origin, { lat: p.lat, lng: p.lng }) : null;
  } catch {
    return null;
  }
}

export interface SubmitInput { data: RequestData; requestKey: string; token: string | null; draftId?: string | null }
export type SubmitResult = ActionResult<{ bookingNumber: string; totalCents: number | null; depositCents: number | null; created: boolean }>;

export async function submitBookingRequest(input: SubmitInput): Promise<SubmitResult> {
  const meta = await requestMeta();
  if (!(await verifyTurnstile(input.token, meta.ip))) return { ok: false, code: 'turnstile', message: 'Our security check did not go through. Press Send again; if it keeps happening, try another browser. Your request is kept.' };
  if (!/^[A-Za-z0-9-]{8,100}$/.test(input.requestKey ?? '')) return { ok: false, code: 'invalid', message: 'Reload the page and try again.' };
  const [r, fleet, f, consent, signedIn] = await Promise.all([rules(), getFleet(), getFacts(), consentTexts(), (async () => (await auth()).currentUser())()]);
  // an account made by phone may send a request before it has an email (asked on the pay page; 0091)
  const emailOptional = !!signedIn && !signedIn.email;
  const parsed = requestSchema(r, { todayIso: torontoToday(), nowMinutes: torontoMinutesNow(), knownCar: (s) => fleet.some((c) => c.slug === s), emailOptional }).safeParse(input.data);
  if (!parsed.success) {
    const fe: Record<string, string> = {};
    for (const i of parsed.error.issues) { const k = i.path.join('.'); if (!(k in fe)) fe[k] = i.message; }
    return { ok: false, code: 'invalid', message: 'Check the highlighted fields.', fieldErrors: fe };
  }
  const v = parsed.data;
  const car = fleet.find((c) => c.slug === v.car)!;
  const airport = (code: string) => f.airports.find((a) => a.code === code);
  const returnAddress = v.returnAt === 'delivery' ? (v.returnAddress.label.trim() ? v.returnAddress : v.pickupAddress) : v.returnAddress;
  const loc = async (kind: string, addr: { label: string; placeId: string }, ap: string) => {
    if (kind === 'owner') return { kind: 'owner_location' };
    if (kind === 'airport') return { kind: 'airport', airport_code: ap };
    if (kind === 'delivery') return { kind: 'delivery', address: addr.label, distance_km: await distance(addr.placeId) };
    return { kind: 'our_location' };
  };
  const far = (k: string) => k === 'delivery' || k === 'airport';
  const lic = v.licClass === 'other' ? 'OTHER' : v.licClass;
  const user = signedIn;
  const cookieRef = (await cookies()).get('cc-ref')?.value?.toUpperCase() ?? null;

  const request = {
    request_key: input.requestKey,
    vehicle_id: car.vehicle_id,
    pickup_at: torontoInstant(v.from, v.tf),
    return_at: torontoInstant(v.to, v.tt),
    booking_type: v.bookingType,
    pickup_method: far(v.pickupAt) ? 'delivered' : 'collected',
    return_method: far(v.returnAt) ? 'picked_up' : 'returned',
    pickup_place: v.pickupAt === 'delivery' ? v.pickupAddress.label : v.pickupAt === 'airport' ? airport(v.pickupAirport)?.name : null,
    return_place: v.returnAt === 'delivery' ? returnAddress.label : v.returnAt === 'airport' ? airport(v.returnAirport)?.name : null,
    pickup_location: await loc(v.pickupAt, v.pickupAddress, v.pickupAirport),
    return_location: await loc(v.returnAt, returnAddress, v.returnAirport),
    note: v.notes.trim() || null,
    coverage_option: Number(v.coverage),
    // 0066: add-ons (an older draft's winter tires and baby seats included); the database checks notice and stock
    addons: addonsPayload(migrateExtras(v).addons),
    renter: { email: v.email, full_name: `${v.first} ${v.last}`, mobile: v.phone, date_of_birth: dobIso(v.dobY, v.dobM, v.dobD), licence_class: lic, licence_issuer: v.licClass === 'other' ? v.licIssuer : 'ON' },
    additional_drivers: v.drivers.map((d) => ({ full_name: `${d.first} ${d.last}`, date_of_birth: dobIso(d.dobY, d.dobM, d.dobD), email: d.email, licence_class: d.licClass || null })),
    consents: {
      terms: { accepted: v.agree, version: consent.terms.version, text: consent.agreeLine(r.minAge) },
      privacy: { accepted: v.agree, version: consent.privacy.version, text: consent.agreeLine(r.minAge) },
      marketing: { opted_in: v.marketing, version: consent.marketing.version, text: consent.marketing.text }
    },
    // a referral link (/r/<code>: a field staff member's or an owner's) kept for 30 days
    promo_code: v.promo ? v.promo.toUpperCase() : null,
    referred_by_code: (() => { const c = cookieRef; return c && /^[A-Z0-9]{4,12}$/.test(c) ? c : null; })(),
    details: { referrer_name: v.referrer || null, pickup_place_id: v.pickupAddress.placeId || null, return_place_id: returnAddress.placeId || null, source: 'web' }
  };

  const call = (pUser?: string) => rpc('submit_booking_request', { p_request: request, p_ip: meta.ip ?? undefined, p_user_agent: meta.userAgent, p_user: pUser }, { role: 'service_role', requestId: meta.requestId });
  try {
    let res: Record<string, unknown>;
    try {
      res = (await call(user?.id)) as unknown as Record<string, unknown>;
    } catch (e) {
      // a sign-in account without its users row yet: send the request as a visitor
      if (user && e instanceof DbError && /Unknown user/.test(e.message)) res = (await call()) as unknown as Record<string, unknown>;
      else throw e;
    }
    if (!res.ok) return { ok: false, code: String(res.error ?? 'refused'), message: String(res.message ?? 'We could not send the request. Please try again or call us.') };
    // 0096: how we reach the renter, chosen in the form (empty: the default)
    if (v.notifyChannel) await rpc('server_request_notify_channel', { p_booking_number: String(res.booking_number), p_channel: v.notifyChannel, p_user: user?.id }, { role: 'service_role' }).catch(() => undefined);
    if (input.draftId) await rpc('submit_form_draft', { p_draft: input.draftId, p_result: { booking_number: String(res.booking_number) } }, { role: 'service_role' }).catch(() => undefined);
    // contact capture (0090): the request is visible to this browser's unverified session (if it has one), and the
    // contact saved as it was typed is done
    if (!user) await pendingAddBooking(String(res.booking_number));
    await captureDone('booking_request');
    return { ok: true, data: { bookingNumber: String(res.booking_number), totalCents: (res.total_due_at_booking_cents as number) ?? null, depositCents: (res.deposit_cents as number) ?? null, created: res.created === true } };
  } catch (e) {
    return { ok: false, code: 'refused', message: e instanceof DbError ? e.message : 'We could not send the request. Please try again or call us.' };
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
 *  number and may have no email yet. */
export async function requestAccount(): Promise<ActionResult<{ signedIn: boolean; email: string | null; phone: string | null }>> {
  const user = await (await auth()).currentUser();
  if (!user) return { ok: true, data: { signedIn: false, email: null, phone: null } };
  const si = (await rpc('server_my_sign_in', { p_user: user.id }, { role: 'service_role' }).catch(() => null)) as unknown as { email: string | null; phone: string | null } | null;
  return { ok: true, data: { signedIn: true, email: si?.email ?? (user.email || null), phone: si?.phone ?? user.phone ?? null } };
}
