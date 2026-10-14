import 'server-only';
import { cache } from 'react';
import { cookies } from 'next/headers';
import { redirect } from 'next/navigation';
import { auth, type SessionUser } from '@/lib/auth';
import { rpc } from '@/lib/db/repo';
import type { Json } from '@/lib/db/types';
import { currentUser } from '@/server/portal/data';

// The one door for staff and investors (migration 0031): every call carries the signed-in user and the
// assurance level of their session (aal2 after the second factor). The database makes them the acting
// user, refuses a staff session without the second factor while require_staff_two_step is on, and
// checks what each role may read and do.
const SR = { role: 'service_role' as const };
export type Call = 'roles' | 'admin_list' | 'admin_read' | 'admin_save' | 'admin_do' | 'va_list' | 'va_read' | 'va_do' | 'field_read' | 'field_do' | 'investor_read' | 'investor_do' | 'ops_read' | 'ops_do';
export interface Roles { admin: boolean; va: 'finance' | 'fleet' | 'cs' | 'sales' | null; va_functions?: Array<'finance' | 'fleet' | 'cs' | 'sales'>; field: boolean; owner: boolean; renter: boolean; investor: boolean; staff: boolean; two_step_required: boolean; name: string | null }

export async function sessionAal(): Promise<'aal1' | 'aal2' | null> {
  return (await auth()).assurance();
}

/** The function an assistant who covers several chose to work in (the switcher; migration 0033). The
 *  database accepts it only if it is one of theirs (app.va_active_fn). */
export const VA_FN_COOKIE = 'cc-va-fn';
async function chosenFunction(): Promise<string | null> {
  try { return (await cookies()).get(VA_FN_COOKIE)?.value ?? null; } catch { return null; }
}

// A read asked twice in one render (the frame's counts and the page, both reading the dashboard) goes to the
// database once: React's cache() for the request, keyed by the call as text. Writes are never cached.
const READS = new Set<Call>(['roles', 'admin_list', 'admin_read', 'va_list', 'va_read', 'field_read', 'investor_read', 'ops_read']);
const cachedRead = cache(async (key: string): Promise<unknown> => {
  const a = JSON.parse(key) as { p_user: string; p_aal: string; p_call: string; p_name: string; p: Json };
  return rpc('door', a, SR);
});

export async function door<T = Record<string, unknown>>(userId: string, call: Call, name: string | null, p: Record<string, unknown> = {}, aal?: 'aal1' | 'aal2' | null): Promise<T> {
  const level = aal === undefined ? await sessionAal() : aal;
  let args = p;
  if (call.startsWith('va_') && !('_va' in p)) { const fn = await chosenFunction(); if (fn) args = { ...p, _va: fn }; }
  const a = { p_user: userId, p_aal: level ?? '', p_call: call, p_name: name ?? '', p: args as unknown as Json };
  if (READS.has(call)) return (await cachedRead(JSON.stringify(a))) as T;
  return (await rpc('door', a, SR)) as unknown as T;
}

const myRoles = cache(async (userId: string) => (await rpc('my_roles', { p_user: userId }, SR)) as unknown as Roles);
export async function rolesOf(userId: string): Promise<Roles> {
  const r = { ...(await myRoles(userId)) };
  const fn = r.va ? await chosenFunction() : null;
  if (fn && r.va_functions?.includes(fn as Roles['va'] & string)) r.va = fn as Roles['va'];
  return r;
}

/** Where a signed-in user goes when no page was asked for. */
export function homeFor(r: Roles): string {
  if (r.admin) return '/admin';
  if (r.va) return '/va';
  if (r.field) return '/field';
  if (r.investor) return '/investor';
  if (r.owner) return '/owner';
  return '/account';
}

/** Staff pages: signed in, the role, and the second factor when the switch is on (or the person enrolled). */
export async function requireStaff(kind: 'va' | 'field', next: string): Promise<{ user: SessionUser; roles: Roles }> {
  const user = await currentUser();
  if (!user) redirect(`/sign-in?next=${encodeURIComponent(next)}`);
  const roles = await rolesOf(user.id);
  if (kind === 'va' ? !roles.va : !roles.field) redirect(`/${kind}/no-access`);
  if (roles.two_step_required && (await sessionAal()) !== 'aal2') redirect(`/two-step?next=${encodeURIComponent(next)}`);
  return { user, roles };
}

export async function requireInvestor(next: string): Promise<{ user: SessionUser; roles: Roles }> {
  const user = await currentUser();
  if (!user) redirect(`/sign-in?next=${encodeURIComponent(next)}`);
  const roles = await rolesOf(user.id);
  if (!roles.investor) redirect('/investor/no-access');
  return { user, roles };
}
