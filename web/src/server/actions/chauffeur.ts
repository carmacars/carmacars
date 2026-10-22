'use server';
import { verifyTurnstile } from '@/integrations/turnstile';
import { fieldErrors, type ActionResult } from '@/features/forms/schemas';
import { chauffeurSchema } from '@/features/chauffeur/schema';
import { DbError, rpc } from '@/lib/db/repo';
import { requestMeta } from '@/server/request';

// The public chauffeur request (migration 0093): after the bot check, public.submit_chauffeur_request as the server.
// It limits requests per address, keeps the lead (kind chauffeur) with its quote and raises customer service's task.
export async function submitChauffeur(_: unknown, fd: FormData): Promise<ActionResult<{ reference: string }>> {
  const parsed = chauffeurSchema.safeParse(Object.fromEntries(fd));
  if (!parsed.success) return { ok: false, code: 'invalid', message: 'Check the highlighted fields.', fieldErrors: fieldErrors(parsed.error) };
  const meta = await requestMeta();
  if (!(await verifyTurnstile(fd.get('cf-turnstile-response') as string | null, meta.ip))) return { ok: false, code: 'turnstile', message: 'We could not confirm you are not a bot. Reload the page and try again.' };
  const v = parsed.data;
  try {
    const r = (await rpc('submit_chauffeur_request', {
      p: { ...v, request_key: String(fd.get('request_key') ?? '') || null, source_url: meta.referer ?? null },
      p_ip: meta.ip ?? undefined
    }, { role: 'service_role', requestId: meta.requestId })) as unknown as { ok: boolean; reference?: string; error?: string; fields?: Record<string, string> };
    if (!r.ok) {
      if (r.error === 'rate_limited') return { ok: false, code: 'rate_limited', message: 'Too many requests from this connection. Please try again later or call us.' };
      return { ok: false, code: 'invalid', message: 'Check the highlighted fields.', fieldErrors: r.fields ?? {} };
    }
    return { ok: true, data: { reference: r.reference! } };
  } catch (e) {
    return { ok: false, code: 'db', message: e instanceof DbError ? e.message : 'We could not send that. Please try again.' };
  }
}
