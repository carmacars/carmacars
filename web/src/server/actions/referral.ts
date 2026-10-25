'use server';
import { verifyTurnstile } from '@/integrations/turnstile';
import { fieldErrors, partnerSignupSchema, type ActionResult } from '@/features/forms/schemas';
import { DbError, rpc } from '@/lib/db/repo';
import { requestMeta } from '@/server/request';

// A business joins the referral program (migration 0164): public.server_referral_partner_signup after Turnstile makes a pending
// partner and a task for the Admins. Nothing is active, and nothing is earned, until an Admin approves it.
export async function submitReferralPartner(_: unknown, fd: FormData): Promise<ActionResult<{ ok: true }>> {
  const parsed = partnerSignupSchema.safeParse(Object.fromEntries(fd));
  if (!parsed.success) return { ok: false, code: 'invalid', message: 'Check the highlighted fields.', fieldErrors: fieldErrors(parsed.error) };
  const v = parsed.data;
  const meta = await requestMeta();
  const token = fd.get('cf-turnstile-response');
  if (!(await verifyTurnstile(typeof token === 'string' ? token : null, meta.ip))) return { ok: false, code: 'turnstile', message: 'We could not confirm you are not a bot. Reload the page and try again.' };
  try {
    const r = (await rpc('server_referral_partner_signup', { p: { ...v }, p_ip: meta.ip ?? undefined }, { role: 'service_role', requestId: meta.requestId })) as unknown as { ok: boolean; error?: string };
    if (!r.ok) return { ok: false, code: r.error ?? 'refused', message: r.error === 'rate_limited' ? 'Too many requests from this connection. Please try again later or call us.' : 'We could not send that. Please try again.' };
    return { ok: true, data: { ok: true } };
  } catch (e) {
    return { ok: false, code: 'db', message: e instanceof DbError ? e.message : 'We could not send that. Please try again.' };
  }
}
