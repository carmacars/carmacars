'use server';
import { after } from 'next/server';
import { revalidatePath } from 'next/cache';
import { DbError } from '@/lib/db/repo';
import type { ActionResult } from '@/features/forms/schemas';
import { currentUser } from '@/server/portal/data';
import { door, sessionAal } from '@/server/door';
import { styleProblems, LIMITS } from '@/features/seo/copy';

// Admin > Settings > Search and the car copy on a listing (migration 0061): edit a field (it is locked and every
// rewrite keeps it), unlock it, ask for the copy to be written again, edit a landing page or an article, tick a
// business listing. The database checks who may (an Admin; Fleet and customer service for the car copy). A rewrite
// asked for here runs right after the response, not at the next five-minute tick.
type R<T = unknown> = ActionResult<T>;
const fail = (e: unknown): R<never> => ({ ok: false, code: 'refused', message: e instanceof DbError || e instanceof Error ? e.message.replace(/^.*?ERROR:\s*/, '') : 'Something went wrong.' });

async function me() {
  const user = await currentUser();
  if (!user) throw new Error('Sign in first.');
  return { user, aal: await sessionAal() };
}

const LEN: Record<string, number> = { seo_title: LIMITS.seo_title[1], meta_description: LIMITS.meta_description[1], h1: LIMITS.h1[1] };
/** A person's text still keeps the house style (no long dash, the brand, no numbered company) and the lengths. */
function check(field: string, value: unknown): string | null {
  const text = typeof value === 'string' ? value : JSON.stringify(value ?? '');
  if (!text.trim() || text === '[]' || text === '{}') return 'Write something, or unlock the field to have it written again.';
  if (LEN[field] && typeof value === 'string' && value.length > LEN[field]) return `At most ${LEN[field]} characters (it is ${value.length}).`;
  const p = styleProblems(text).filter((x) => /dash|CarmaCars|numbered|Protection Plan/.test(x));
  return p.length ? p.join('; ') : null;
}

function kick() {
  try {
    after(async () => { const { runSeoJobNow } = await import('@/server/seo-job'); await runSeoJobNow({ limit: 2, deadlineMs: 25_000 }).catch(() => undefined); });
  } catch { /* outside a request: the five-minute tick takes it */ }
}

export async function seoAct<T = Record<string, unknown>>(action: 'car_copy_edit' | 'car_copy_regenerate' | 'seo_page_save' | 'article_save' | 'business_listing_tick',
  p: Record<string, unknown>, paths: string[] = []): Promise<R<T>> {
  try {
    if (action === 'car_copy_edit' && !p.unlock) { const bad = check(String(p.field), p.value); if (bad) return { ok: false, code: 'refused', message: bad }; }
    if (action === 'seo_page_save' && p.copy && typeof p.copy === 'object') {
      for (const [k, v] of Object.entries(p.copy as Record<string, unknown>)) { const bad = check(k, v); if (bad) return { ok: false, code: 'refused', message: `${k}: ${bad}` }; }
    }
    if (action === 'article_save' && !p.regenerate) {
      const bad = check('body_md', [p.title, p.description, p.body_md].filter(Boolean).join('\n'));
      if (bad && !/Write something/.test(bad)) return { ok: false, code: 'refused', message: bad };
    }
    const { user, aal } = await me();
    const data = await door<T>(user.id, 'ops_do', action, p, aal);
    for (const x of paths) { try { revalidatePath(x); } catch { /* ignore */ } }
    if (action === 'business_listing_tick') revalidatePath('/admin/settings/site');
    revalidatePath('/admin/settings/search');
    if (action === 'car_copy_regenerate' || p.unlock || p.regenerate) kick();
    return { ok: true, data };
  } catch (e) { return fail(e); }
}
