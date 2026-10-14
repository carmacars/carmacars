'use server';
import { revalidatePath } from 'next/cache';
import { DbError } from '@/lib/db/repo';
import type { ActionResult } from '@/features/forms/schemas';
import { currentUser } from '@/server/portal/data';
import { door, rolesOf, sessionAal } from '@/server/door';
import { driverLinkUrl } from '@/server/portal/driver-links';

// Staff actions of migration 0040 that need the server between two database calls: a new signing link for an
// additional driver is made in the database (the version goes up), signed here with LINK_SIGNING_KEY, then emailed.
type R<T = unknown> = ActionResult<T>;
const fail = (e: unknown): R<never> => ({ ok: false, code: 'refused', message: e instanceof DbError || e instanceof Error ? e.message.replace(/^.*?ERROR:\s*/, '') : 'Something went wrong.' });

export async function staffResendDriverLink(signerId: string, refresh: string[] = []): Promise<R<{ url: string; emailed: string | null }>> {
  try {
    const user = await currentUser();
    if (!user) throw new Error('Sign in first.');
    const roles = await rolesOf(user.id);
    const call = roles.admin ? 'admin_do' : roles.va ? 'va_do' : null;
    if (!call) throw new Error('Not permitted.');
    const aal = await sessionAal();
    const n = await door<{ version: number; expires_at: string; email: string | null }>(user.id, call, 'driver_link_renew', { signer: signerId }, aal);
    const url = await driverLinkUrl(signerId, n.version, n.expires_at);
    let emailed: string | null = null;
    if (n.email) { await door(user.id, call, 'driver_link_send', { signer: signerId, version: n.version, url }, aal); emailed = n.email; }
    for (const x of refresh) revalidatePath(x);
    return { ok: true, data: { url, emailed } };
  } catch (e) { return fail(e); }
}
