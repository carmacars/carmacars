import 'server-only';
import { cache } from 'react';
import { cookies } from 'next/headers';
import { redirect } from 'next/navigation';
import { auth, type SessionUser } from '@/lib/auth';
import { DbError, rpc } from '@/lib/db/repo';
import { friendlyDbError } from '@/lib/db/friendly';
import type { Json } from '@/lib/db/types';
import { currentUser } from '@/server/portal/data';
import { viewAs, ViewAsReadOnly } from '@/server/view-as';

// The one door for staff and investors (migration 0031): every call carries the signed-in user and the
// assurance level of their session (aal2 after the second factor). The database makes them the acting
// user, refuses a staff session without the second factor while require_staff_two_step is on, and
// checks what each role may read and do.
const SR = { role: 'service_role' as const };
export type Call = 'roles' | 'admin_list' | 'admin_read' | 'admin_save' | 'admin_do' | 'va_list' | 'va_read' | 'va_do' | 'field_read' | 'field_do' | 'investor_read' | 'investor_do' | 'ops_read' | 'ops_do';
export interface Roles { admin: boolean; va: 'finance' | 'fleet' | 'cs' | 'sales' | null; va_functions?: Array<'finance' | 'fleet' | 'cs' | 'sales'>;
  /** every staff function held, field work included (0197) */ functions?: Array<'finance' | 'fleet' | 'cs' | 'sales' | 'field'>; sales_work_mode?: 'in_person' | 'remote' | null; field: boolean; owner: boolean; renter: boolean; investor: boolean; staff: boolean; two_step_required: boolean; name: string | null;
  /** the academy gate is on and this staff member has not passed their paths yet (0207) */ academy_locked?: boolean }

export async function sessionAal(): Promise<'aal1' | 'aal2' | null> {
  return (await auth()).assurance();
}

/** The function an assistant who covers several chose to work in (the switcher; migration 0033). The
 *  database accepts it only if it is one of theirs (app.va_active_fn). */
export const VA_FN_COOKIE = 'cc-va-fn';
async function chosenFunction(): Promise<string | null> {
  // viewing an assistant's portal as an Admin: the function chosen for the view
  const v = await viewAs();
  if (v) return v.fn;
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
  // viewing as this person: their reads only; any action for them is refused (src/server/view-as.ts)
  if (!READS.has(call)) { const v = await viewAs(); if (v && v.target.id === userId) throw new ViewAsReadOnly(); }
  const level = aal === undefined ? await sessionAal() : aal;
  let args = p;
  if (call.startsWith('va_') && !('_va' in p)) { const fn = await chosenFunction(); if (fn) args = { ...p, _va: fn }; }
  const a = { p_user: userId, p_aal: level ?? '', p_call: call, p_name: name ?? '', p: args as unknown as Json };
  try {
    if (READS.has(call)) return (await cachedRead(JSON.stringify(a))) as T;
    return (await rpc('door', a, SR)) as unknown as T;
  } catch (e) { throw friendly(e, call, name); }
}

// A raw database error (a constraint, a cast, a timeout) becomes a plain sentence with a reference; the original is
// logged with it (src/lib/db/friendly.ts, 0151). The database's own refusals pass through as written.
function friendly(e: unknown, call: Call, name: string | null): unknown {
  if (!(e instanceof Error)) return e;
  const f = friendlyDbError(e as Error & { code?: unknown }, { call, name });
  return f === e ? e : new DbError(f.message, 'friendly');
}

const myRoles = cache(async (userId: string) => (await rpc('my_roles', { p_user: userId }, SR)) as unknown as Roles);
export async function rolesOf(userId: string): Promise<Roles> {
  const r = { ...(await myRoles(userId)) };
  const fn = r.va ? await chosenFunction() : null;
  if (fn && r.va_functions?.includes(fn as Roles['va'] & string)) r.va = fn as Roles['va'];
  return r;
}

/** Staff pages: signed in, the role, and the second factor when the switch is on (or the person enrolled). */
export async function requireStaff(kind: 'va' | 'field', next: string): Promise<{ user: SessionUser; roles: Roles }> {
  const user = await currentUser();
  if (!user) redirect(`/sign-in?next=${encodeURIComponent(next)}`);
  const roles = await rolesOf(user.id);
  // one staff portal (0197): a person with field work only opens on their jobs; anyone else without the function is told so
  if (kind === 'va' ? !roles.va : !roles.field) redirect(kind === 'va' && roles.field && (next === '/staff' || next === '/va') ? '/staff/field' : '/staff/no-access');
  if (roles.two_step_required && (await sessionAal()) !== 'aal2') redirect(`/two-step?next=${encodeURIComponent(next)}`);
  // the academy gate (0207, off by default): until their paths are passed, the academy, the guide and the profile only
  if (roles.academy_locked && !ACADEMY_OPEN.test(next)) redirect('/staff/academy?locked=1');
  return { user, roles };
}
const ACADEMY_OPEN = /^\/staff\/(academy|guide|profile|field\/profile|no-access)(\/|\?|$)/;

export async function requireInvestor(next: string): Promise<{ user: SessionUser; roles: Roles }> {
  const user = await currentUser();
  if (!user) redirect(`/sign-in?next=${encodeURIComponent(next)}`);
  const roles = await rolesOf(user.id);
  if (!roles.investor) redirect('/investor/no-access');
  return { user, roles };
}
