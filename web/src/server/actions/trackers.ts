'use server';
import { verifyTurnstile } from '@/integrations/turnstile';
import { fieldErrors, trackerWaitlistSchema, type ActionResult } from '@/features/forms/schemas';
import { DbError, rpc } from '@/lib/db/repo';
import { requestMeta } from '@/server/request';
import { leadSourceFields, storeSource } from '@/server/source';

// The GPS tracker waitlist and pre-order form of /trackers (release 48, migration 3231): public.submit_tracker_waitlist
// after Turnstile. It makes a lead for Sales (with the usual To do and staff alert) and queues the person's confirmation
// email. Nothing is charged: trackers are not in hand yet.
export async function submitTrackerWaitlist(_: unknown, fd: FormData): Promise<ActionResult<{ cars: number; monthlyCents: number }>> {
  const parsed = trackerWaitlistSchema.safeParse(Object.fromEntries(fd));
  if (!parsed.success) return { ok: false, code: 'invalid', message: 'Check the highlighted fields.', fieldErrors: fieldErrors(parsed.error) };
  const v = parsed.data;
  const meta = await requestMeta();
  const token = fd.get('cf-turnstile-response');
  if (!(await verifyTurnstile(typeof token === 'string' ? token : null, meta.ip))) return { ok: false, code: 'turnstile', message: 'We could not confirm you are not a bot. Reload the page and try again.' };
  try {
    const r = (await rpc('submit_tracker_waitlist', { p: { ...v, phone: v.phone || null, name: v.name || null, source_url: meta.referer, ...(await leadSourceFields()) }, p_ip: meta.ip ?? undefined },
      { role: 'service_role', requestId: meta.requestId })) as unknown as { ok: boolean; lead_id?: string; error?: string; cars?: number; monthly_cents?: number };
    if (!r.ok) return { ok: false, code: r.error ?? 'refused', message: r.error === 'rate_limited' ? 'Too many sign-ups from this connection. Please try again later or call us.' : 'We could not save that. Please try again.' };
    await storeSource({ lead: r.lead_id });
    return { ok: true, data: { cars: r.cars ?? Number(v.cars), monthlyCents: r.monthly_cents ?? 0 } };
  } catch (e) {
    return { ok: false, code: 'db', message: e instanceof DbError ? e.message : 'We could not save that. Please try again.' };
  }
}
