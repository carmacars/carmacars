'use server';
import { revalidatePath } from 'next/cache';
import { DbError } from '@/lib/db/repo';
import { env } from '@/lib/env';
import type { ActionResult } from '@/features/forms/schemas';
import { currentUser } from '@/server/portal/data';
import { door, rolesOf, sessionAal } from '@/server/door';
import { syncOne, type DueFeed, type Store } from '@/features/calendar/sync-run';

// Calendar sync (migration 0062) for Admins and Fleet: add, turn off and remove calendar links, rotate a car's
// CarmaCars link, and "Sync now", which reads one link here at once with the same reader as the Edge Function and
// hands the result to the database through the door (app.calendar_sync_do).
type R<T = unknown> = ActionResult<T>;
const fail = (e: unknown): R<never> => ({ ok: false, code: 'refused', message: e instanceof DbError || e instanceof Error ? e.message.replace(/^.*?ERROR:\s*/, '') : 'Something went wrong.' });
const PAGES = ['/admin/calendar-sync', '/va/calendar-sync'];

async function who() {
  const user = await currentUser();
  if (!user) throw new Error('Sign in first.');
  const roles = await rolesOf(user.id);
  const call = roles.admin ? 'admin_do' as const : roles.va === 'fleet' ? 'va_do' as const : null;
  if (!call) throw new Error('Calendar sync is for Admins and Fleet.');
  return { user, call, aal: await sessionAal() };
}

export async function calendarAct<T = Record<string, unknown>>(action: 'calendar_feed_add' | 'calendar_feed_save' | 'calendar_feed_remove' | 'calendar_export_rotate', p: Record<string, unknown>): Promise<R<T>> {
  try {
    const { user, call, aal } = await who();
    const data = await door<T>(user.id, call, action, p, aal);
    for (const x of PAGES) revalidatePath(x);
    return { ok: true, data };
  } catch (e) { return fail(e); }
}

export async function calendarSyncNow(feedId: string): Promise<R<{ ok: boolean; events?: number; error?: string; notModified?: boolean }>> {
  try {
    const { user, call, aal } = await who();
    const feed = await door<DueFeed>(user.id, call, 'calendar_feed_sync_start', { id: feedId }, aal);
    const store: Store = {
      async due() { return [feed]; },
      ok: (id, events, meta) => door(user.id, call, 'calendar_feed_result', { id, ok: true, events, meta }, aal),
      failed: (id, error) => door(user.id, call, 'calendar_feed_result', { id, ok: false, error }, aal)
    };
    // a link on this machine or a private network is read only on a developer's machine (the end-to-end tests)
    const r = await syncOne(feed, store, (u, init) => fetch(u, { ...init, cache: 'no-store' }), { allowPrivate: env().APP_ENV === 'local' });
    for (const x of PAGES) revalidatePath(x);
    return { ok: true, data: { ok: r.ok, events: r.events, error: r.error, notModified: r.notModified } };
  } catch (e) { return fail(e); }
}
