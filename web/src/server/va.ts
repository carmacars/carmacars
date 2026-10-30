import 'server-only';
import { notFound } from 'next/navigation';
import { door, requireStaff, sessionAal, type Roles } from '@/server/door';
import type { ListQuery, Row } from '@/server/admin/api';

// The staff portal's office pages (docs/blueprint/05-va.md): the gate (an active staff member with an office function,
// two-step sign-in when the switch is on), then the reads through the door of migration 0031 in the page's function.
// Since 0197 a person may hold several functions at once and the menu lists them all: a page for some functions only
// works in the one chosen on screen when it is one of them, else in the first of them the person holds.
export type Fn = NonNullable<Roles['va']>;
export const FN_LABEL: Record<Fn, string> = { finance: 'Finance and billing', fleet: 'Fleet operations', cs: 'Customer service and growth', sales: 'Sales' };

/** The function a page works in: the chosen one when the page is for it, else the first held one the page is for. */
export function pageFunction(chosen: Fn, held: readonly Fn[], only?: readonly Fn[]): Fn | null {
  if (!only || only.includes(chosen)) return chosen;
  return held.find((f) => only.includes(f)) ?? null;
}

export async function vaPage(next: string, only?: Fn[]) {
  const { user, roles } = await requireStaff('va', next);
  const fn = pageFunction(roles.va as Fn, roles.va_functions?.length ? roles.va_functions : [roles.va as Fn], only);
  if (!fn) notFound();
  const aal = await sessionAal();
  // the page's function goes with every read, so the database applies that function's rules (app.va_active_fn)
  const withFn = (p: Record<string, unknown>) => ({ ...p, _va: fn });
  return {
    user, roles, fn, aal,
    list: async <T = Row>(rel: string, q: ListQuery = {}) => (await door<{ rows: T[]; count: number }>(user.id, 'va_list', rel, withFn(q as Record<string, unknown>), aal)) ?? { rows: [], count: 0 },
    read: <T = Row>(what: string, p: Record<string, unknown> = {}) => door<T>(user.id, 'va_read', what, withFn(p), aal)
  };
}
