import 'server-only';
import { notFound } from 'next/navigation';
import { door, requireStaff, sessionAal, type Roles } from '@/server/door';
import type { ListQuery, Row } from '@/server/admin/api';

// The assistants' pages (docs/blueprint/05-va.md): the gate (an active assistant, two-step sign-in when
// the switch is on), then the reads through the door of migration 0031 with the assistant's function.
export type Fn = NonNullable<Roles['va']>;
export const FN_LABEL: Record<Fn, string> = { finance: 'Finance and billing', fleet: 'Fleet operations', cs: 'Customer service and growth', sales: 'Sales' };

export async function vaPage(next: string, only?: Fn[]) {
  const { user, roles } = await requireStaff('va', next);
  const fn = roles.va as Fn;
  if (only && !only.includes(fn)) notFound();
  const aal = await sessionAal();
  return {
    user, roles, fn, aal,
    list: async <T = Row>(rel: string, q: ListQuery = {}) => (await door<{ rows: T[]; count: number }>(user.id, 'va_list', rel, q as Record<string, unknown>, aal)) ?? { rows: [], count: 0 },
    read: <T = Row>(what: string, p: Record<string, unknown> = {}) => door<T>(user.id, 'va_read', what, p, aal)
  };
}
