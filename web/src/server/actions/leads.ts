'use server';
import { verifyTurnstile } from '@/integrations/turnstile';
import { contactSchema, fieldErrors, ownerSchema, placeLeadSchema, vehicleLeadSchema, type ActionResult } from '@/features/forms/schemas';
import { consentTexts } from '@/server/booking-data';
import { DbError, rpc } from '@/lib/db/repo';
import { requestMeta } from '@/server/request';
import { captureDone } from '@/server/capture';
import { cookies } from 'next/headers';

// Public enquiries go to public.submit_lead (0022) as the server, after Turnstile. The function
// rate-limits by address, raises the right task and emits the owner program events.
const TOPICS: Record<string, string> = { car: 'A car or a price', booking: 'A booking I have made', dates: 'Dates or availability', owner: 'Listing my car', billing: 'A charge or a statement', other: 'Something else' };

async function submit(kind: 'contact' | 'owner_program' | 'buyer' | 'finance' | 'detailing' | 'bodyshop', p: Record<string, unknown>, token: FormDataEntryValue | null): Promise<ActionResult<{ leadId: string }>> {
  const meta = await requestMeta();
  if (!(await verifyTurnstile(typeof token === 'string' ? token : null, meta.ip))) return { ok: false, code: 'turnstile', message: 'We could not confirm you are not a bot. Reload the page and try again.' };
  try {
    const r = (await rpc('submit_lead', { p: { kind, source: 'web', source_url: meta.referer, ...p }, p_ip: meta.ip ?? undefined }, { role: 'service_role', requestId: meta.requestId })) as unknown as { ok: boolean; lead_id?: string; error?: string };
    if (!r.ok) return { ok: false, code: r.error ?? 'refused', message: r.error === 'rate_limited' ? 'Too many messages from this connection. Please try again later or call us.' : 'We could not send that. Please try again.' };
    // the form was sent: the contact saved as it was typed (0090) is done, its lead and follow-up close
    await captureDone(kind === 'contact' ? 'contact' : 'owner_lead');
    return { ok: true, data: { leadId: r.lead_id! } };
  } catch (e) {
    return { ok: false, code: 'db', message: e instanceof DbError ? e.message : 'We could not send that. Please try again.' };
  }
}

export async function submitContact(_: unknown, fd: FormData): Promise<ActionResult<{ leadId: string }>> {
  const parsed = contactSchema.safeParse(Object.fromEntries(fd));
  if (!parsed.success) return { ok: false, code: 'invalid', message: 'Check the highlighted fields.', fieldErrors: fieldErrors(parsed.error) };
  const v = parsed.data;
  return submit('contact', { name: v.name, email: v.email || null, phone: v.phone || null, message: v.message, payload: { topic: TOPICS[v.topic], booking_number: v.ref || null } }, fd.get('cf-turnstile-response'));
}

export async function submitOwnerApplication(_: unknown, fd: FormData): Promise<ActionResult<{ leadId: string }>> {
  const parsed = ownerSchema.safeParse(Object.fromEntries(fd));
  if (!parsed.success) return { ok: false, code: 'invalid', message: 'Check the highlighted fields.', fieldErrors: fieldErrors(parsed.error) };
  const v = parsed.data;
  return submit('owner_program', {
    name: v.name, email: v.email, phone: v.phone,
    message: `${v.year} ${v.make} ${v.model}, ${v.own.toLowerCase()}, registered to ${v.who === 'My corporation' ? 'a corporation' : 'the owner'}. Interested in: ${v.mode}.`,
    // an owner's link (/r/<code>?to=owner, 0215): the referring owner goes on the lead (the database ignores a code nobody holds)
    payload: { vehicle: `${v.year} ${v.make} ${v.model}`, year: v.year, make: v.make, model: v.model, ownership: v.own, registered_to: v.who, management_mode: v.mode, car_address: v.carAddress, car_place_id: fd.get('carAddressPlaceId') || null,
      referral_code: refCode((await cookies()).get('cc-ref')?.value) }
  }, fd.get('cf-turnstile-response'));
}

const refCode = (c: string | undefined) => (c && /^[A-Z0-9]{4,12}$/.test(c) ? c : null);

const TIMELINE: Record<string, string> = { now: 'Now', week: 'This week', month: 'Within a month', three: 'Within three months', later: 'Later' };
/** The vehicle pages' lead forms (0097): a lead for Sales with a To do line; the marketing wording recorded only when ticked. */
export async function submitVehicleLead(_: unknown, fd: FormData): Promise<ActionResult<{ leadId: string }>> {
  const parsed = vehicleLeadSchema.safeParse(Object.fromEntries(fd));
  if (!parsed.success) return { ok: false, code: 'invalid', message: 'Check the highlighted fields.', fieldErrors: fieldErrors(parsed.error) };
  const v = parsed.data;
  // 0123: mechanical work we arrange (auto_service) is a place request: its own task for the team, no marketing consent
  if (v.kind === 'auto_service') return submitAutoService(v, fd);
  const consent = v.marketing === 'on' ? (await consentTexts()).marketing : null;
  const what = v.kind === 'buyer' ? `Find me this car: ${v.vehicle}` : `${v.service || (v.kind === 'finance' ? 'Financing' : 'Service')}: ${v.vehicle}`;
  return submit(v.kind, {
    name: v.name, email: v.email || null, phone: v.phone || null,
    message: [`${what}.`, v.place ? `Where: ${v.place}.` : '', v.budget ? `Budget: ${v.budget}.` : '', `When: ${TIMELINE[v.timeline]}.`, v.note].filter(Boolean).join(' '),
    payload: { vehicle: v.vehicle, service: v.service || null, place: v.place || null, budget: v.budget || null, timeline: TIMELINE[v.timeline] },
    consent_marketing: !!consent, consent_text: consent?.text ?? null
  }, fd.get('cf-turnstile-response'));
}

async function submitAutoService(v: { name: string; email: string; phone: string; vehicle: string; service: string; place: string; timeline: string; note: string }, fd: FormData): Promise<ActionResult<{ leadId: string }>> {
  const meta = await requestMeta();
  const token = fd.get('cf-turnstile-response');
  if (!(await verifyTurnstile(typeof token === 'string' ? token : null, meta.ip))) return { ok: false, code: 'turnstile', message: 'We could not confirm you are not a bot. Reload the page and try again.' };
  try {
    const payload = Object.fromEntries(Object.entries({ vehicle: v.vehicle, service: v.service, place: v.place, date: TIMELINE[v.timeline] }).filter(([, x]) => x));
    const r = (await rpc('submit_place_lead', { p: { kind: 'auto_service', name: v.name, email: v.email || null, phone: v.phone || null, message: v.note || null, payload, source: 'web', source_url: meta.referer }, p_ip: meta.ip ?? undefined },
      { role: 'service_role', requestId: meta.requestId })) as unknown as { ok: boolean; lead_id?: string; error?: string };
    if (!r.ok) return { ok: false, code: r.error ?? 'refused', message: r.error === 'rate_limited' ? 'Too many messages from this connection. Please try again later or call us.' : 'We could not send that. Please try again.' };
    return { ok: true, data: { leadId: r.lead_id! } };
  } catch (e) {
    return { ok: false, code: 'db', message: e instanceof DbError ? e.message : 'We could not send that. Please try again.' };
  }
}

// A request from a place page or a service page (migration 0095): public.submit_place_lead after Turnstile, a lead of
// its kind with a task for the team (detailing and body shop requests show in Today).
export async function submitPlaceLead(_: unknown, fd: FormData): Promise<ActionResult<{ leadId: string }>> {
  const parsed = placeLeadSchema.safeParse(Object.fromEntries(fd));
  if (!parsed.success) return { ok: false, code: 'invalid', message: 'Check the highlighted fields.', fieldErrors: fieldErrors(parsed.error) };
  const v = parsed.data;
  const meta = await requestMeta();
  if (!(await verifyTurnstile(typeof fd.get('cf-turnstile-response') === 'string' ? String(fd.get('cf-turnstile-response')) : null, meta.ip))) {
    return { ok: false, code: 'turnstile', message: 'We could not confirm you are not a bot. Reload the page and try again.' };
  }
  try {
    const payload = Object.fromEntries(Object.entries({ vehicle: v.vehicle, service: v.service, damage: v.damage, place: v.place, date: v.date, where: v.where, insurance_claim: v.insurance_claim, term: v.term }).filter(([, x]) => x));
    const r = (await rpc('submit_place_lead', { p: { kind: v.kind, name: v.name, email: v.email, phone: v.phone || null, message: v.message || null, payload, source: 'web', source_url: meta.referer }, p_ip: meta.ip ?? undefined },
      { role: 'service_role', requestId: meta.requestId })) as unknown as { ok: boolean; lead_id?: string; error?: string };
    if (!r.ok) return { ok: false, code: r.error ?? 'refused', message: r.error === 'rate_limited' ? 'Too many messages from this connection. Please try again later or call us.' : 'We could not send that. Please try again.' };
    return { ok: true, data: { leadId: r.lead_id! } };
  } catch (e) {
    return { ok: false, code: 'db', message: e instanceof DbError ? e.message : 'We could not send that. Please try again.' };
  }
}
