'use server';
import { verifyTurnstile } from '@/integrations/turnstile';
import { contactSchema, fieldErrors, ownerSchema, type ActionResult } from '@/features/forms/schemas';
import { DbError, rpc } from '@/lib/db/repo';
import { requestMeta } from '@/server/request';

// Public enquiries go to public.submit_lead (0022) as the server, after Turnstile. The function
// rate-limits by address, raises the right task and emits the owner program events.
const TOPICS: Record<string, string> = { car: 'A car or a price', booking: 'A booking I have made', dates: 'Dates or availability', owner: 'Listing my car', billing: 'A charge or a statement', other: 'Something else' };

async function submit(kind: 'contact' | 'owner_program', p: Record<string, unknown>, token: FormDataEntryValue | null): Promise<ActionResult<{ leadId: string }>> {
  const meta = await requestMeta();
  if (!(await verifyTurnstile(typeof token === 'string' ? token : null, meta.ip))) return { ok: false, code: 'turnstile', message: 'We could not confirm you are not a bot. Reload the page and try again.' };
  try {
    const r = (await rpc('submit_lead', { p: { kind, source: 'web', source_url: meta.referer, ...p }, p_ip: meta.ip ?? undefined }, { role: 'service_role', requestId: meta.requestId })) as unknown as { ok: boolean; lead_id?: string; error?: string };
    if (!r.ok) return { ok: false, code: r.error ?? 'refused', message: r.error === 'rate_limited' ? 'Too many messages from this connection. Please try again later or call us.' : 'We could not send that. Please try again.' };
    return { ok: true, data: { leadId: r.lead_id! } };
  } catch (e) {
    return { ok: false, code: 'db', message: e instanceof DbError ? e.message : 'We could not send that. Please try again.' };
  }
}

export async function submitContact(_: unknown, fd: FormData): Promise<ActionResult<{ leadId: string }>> {
  const parsed = contactSchema.safeParse(Object.fromEntries(fd));
  if (!parsed.success) return { ok: false, code: 'invalid', message: 'Check the highlighted fields.', fieldErrors: fieldErrors(parsed.error) };
  const v = parsed.data;
  return submit('contact', { name: v.name, email: v.email, phone: v.phone || null, message: v.message, payload: { topic: TOPICS[v.topic], booking_number: v.ref || null } }, fd.get('cf-turnstile-response'));
}

export async function submitOwnerApplication(_: unknown, fd: FormData): Promise<ActionResult<{ leadId: string }>> {
  const parsed = ownerSchema.safeParse(Object.fromEntries(fd));
  if (!parsed.success) return { ok: false, code: 'invalid', message: 'Check the highlighted fields.', fieldErrors: fieldErrors(parsed.error) };
  const v = parsed.data;
  return submit('owner_program', {
    name: v.name, email: v.email, phone: v.phone,
    message: `${v.year} ${v.make} ${v.model}, ${v.own.toLowerCase()}, registered to ${v.who === 'My corporation' ? 'a corporation' : 'the owner'}. Interested in: ${v.mode}.`,
    payload: { vehicle: `${v.year} ${v.make} ${v.model}`, year: v.year, make: v.make, model: v.model, ownership: v.own, registered_to: v.who, management_mode: v.mode, car_address: v.carAddress, car_place_id: fd.get('carAddressPlaceId') || null }
  }, fd.get('cf-turnstile-response'));
}
