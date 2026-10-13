import 'server-only';
import { rpc } from '@/lib/db/repo';
import type { Json } from '@/lib/db/types';
import { requireAdmin } from './data';

// The admin portal's reads (migration 0030): one list reader over an allow-list of tables and views,
// and the named screen reads. Every call carries the Admin's id; the database checks it again.
const SR = { role: 'service_role' as const };

export type Row = Record<string, unknown> & { id?: string };
export interface ListQuery { eq?: Record<string, unknown>; not_null?: string[]; gte?: Record<string, unknown>; lt?: Record<string, unknown>; q?: string; order?: string; asc?: boolean; limit?: number; offset?: number }

export async function adminList<T = Row>(adminId: string, rel: string, q: ListQuery = {}): Promise<{ rows: T[]; count: number }> {
  const r = (await rpc('admin_list', { p_admin: adminId, p_rel: rel, p: q as unknown as Json }, SR)) as unknown as { rows: T[]; count: number };
  return r ?? { rows: [], count: 0 };
}

export async function adminRead<T = Row>(adminId: string, what: string, p: Record<string, unknown> = {}): Promise<T> {
  return (await rpc('admin_read', { p_admin: adminId, p_what: what, p: p as unknown as Json }, SR)) as unknown as T;
}

/** For pages: the gate, then the read. */
export async function page(next: string) {
  const { user, gate } = await requireAdmin(next);
  return {
    user, gate,
    list: <T = Row>(rel: string, q: ListQuery = {}) => adminList<T>(user.id, rel, q),
    read: <T = Row>(what: string, p: Record<string, unknown> = {}) => adminRead<T>(user.id, what, p)
  };
}
