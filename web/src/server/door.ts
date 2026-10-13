import 'server-only';
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
export interface Roles { admin: boolean; va: 'finance' | 'fleet' | 'cs' | 'sales' | null; field: boolean; owner: boolean; renter: boolean; investor: boolean; staff: boolean; two_step_required: boolean; name: string | null }

export async function sessionAal(): Promise<'aal1' | 'aal2' | null> {
  return (await auth()).assurance();
}

export async function door<T = Record<string, unknown>>(userId: string, call: Call, name: string | null, p: Record<string, unknown> = {}, aal?: 'aal1' | 'aal2' | null): Promise<T> {
  const level = aal === undefined ? await sessionAal() : aal;
  return (await rpc('door', { p_user: userId, p_aal: level ?? '', p_call: call, p_name: name ?? '', p: p as unknown as Json }, SR)) as unknown as T;
}

export async function rolesOf(userId: string): Promise<Roles> {
  return (await rpc('my_roles', { p_user: userId }, SR)) as unknown as Roles;
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
