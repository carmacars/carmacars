'use server';
import { rpc } from '@/lib/db/repo';
import type { ActionResult } from '@/features/forms/schemas';

// The renter's review page (migration 0146): what they did there, by the page's token. "reviewed" ("I already left a
// review") stops the review requests; the others are counted for staff (opened, copied, Google opened, something wrong).
const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
const ACTS = new Set(['opened', 'copied', 'google', 'reviewed', 'unhappy']);

export async function reviewHelperAct(token: string, act: string): Promise<ActionResult<null>> {
  if (!UUID.test(String(token)) || !ACTS.has(String(act))) return { ok: false, code: 'invalid', message: 'This review link is not valid.' };
  try {
    await rpc('server_review_helper_act', { p_token: token, p_act: act }, { role: 'service_role', skipViewAs: true });
    return { ok: true, data: null };
  } catch {
    return { ok: false, code: 'refused', message: 'This review link is not valid.' };
  }
}
