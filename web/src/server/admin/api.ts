import 'server-only';
import { door } from '@/server/door';
import { requireAdmin } from './data';

// The admin portal's reads (migration 0030): one list reader over an allow-list of tables and views,
// and the named screen reads. Every call carries the Admin's id and the session's assurance level
// through the door of migration 0031; the database checks both again.

export type Row = Record<string, unknown> & { id?: string };
export interface ListQuery { eq?: Record<string, unknown>; not_null?: string[]; gte?: Record<string, unknown>; lt?: Record<string, unknown>; q?: string; order?: string; asc?: boolean; limit?: number; offset?: number }

export async function adminList<T = Row>(adminId: string, rel: string, q: ListQuery = {}): Promise<{ rows: T[]; count: number }> {
  const r = await door<{ rows: T[]; count: number }>(adminId, 'admin_list', rel, q as Record<string, unknown>);
  return r ?? { rows: [], count: 0 };
}

export async function adminRead<T = Row>(adminId: string, what: string, p: Record<string, unknown> = {}): Promise<T> {
  return door<T>(adminId, 'admin_read', what, p);
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
