'use server';
import { revalidatePath } from 'next/cache';
import { DbError } from '@/lib/db/repo';
import type { ActionResult } from '@/features/forms/schemas';
import { currentUser } from '@/server/portal/data';
import { door, rolesOf } from '@/server/door';
import type { FeedScope, FeedState } from '@/features/shift-feed/links';

// r50 (5050): create, regenerate or turn off the signed-in person's own shift calendar link. The database decides who
// may have which feed (app.shift_feed_scopes) and shows its refusal as written.
const PAGES = ['/admin/field-jobs', '/staff/fleet', '/staff/profile', '/staff/field/shifts', '/staff/field/profile'];

export async function setShiftFeed(scope: FeedScope, action: 'create' | 'regenerate' | 'revoke'): Promise<ActionResult<FeedState>> {
  try {
    const user = await currentUser();
    if (!user) return { ok: false, code: 'auth', message: 'Sign in first.' };
    if (!['all', 'mine'].includes(scope) || !['create', 'regenerate', 'revoke'].includes(action)) return { ok: false, code: 'invalid', message: 'That is not one of the options.' };
    const roles = await rolesOf(user.id);
    const call = roles.admin ? 'admin_do' : roles.va ? 'ops_do' : 'field_do';
    const data = await door<FeedState>(user.id, call, 'shift_feed_set', { scope, action });
    for (const p of PAGES) revalidatePath(p);
    return { ok: true, data };
  } catch (e) {
    return { ok: false, code: 'refused', message: e instanceof DbError || e instanceof Error ? e.message.replace(/^.*?ERROR:\s*/, '') : 'Not saved. Please try again.' };
  }
}
