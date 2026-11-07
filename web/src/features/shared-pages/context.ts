import 'server-only';
import { door } from '@/server/door';
import { page } from '@/server/admin/api';
import { vaPage, type Fn } from '@/server/va';
import type { ListQuery, Row } from '@/server/admin/api';
import { ADMIN, staffViewer, type Viewer } from './viewer';

// r31 "Simple": the one loader context of a shared Admin and staff page. It picks the access path from the viewer:
// an Admin reads through admin_read and admin_list, a staff member through va_read and va_list in the page's function
// (the database applies that function's limits). `ops` is the door both share (ops_read), with the function passed only
// where the staff copy passed it before, so every read answers exactly as it did on the two copies.
export interface PageCtx {
  viewer: Viewer;
  user: Awaited<ReturnType<typeof page>>['user'];
  aal: 'aal1' | 'aal2' | null | undefined;
  /** the viewer's own read: admin_read, or va_read in the page's function */
  read: <T = Row>(what: string, p?: Record<string, unknown>) => Promise<T>;
  list: <T = Row>(rel: string, q?: ListQuery) => Promise<{ rows: T[]; count: number }>;
  /** the viewer's own read without the function (the staff copies read the visits, calls and listing state so) */
  own: <T = Row>(what: string, p?: Record<string, unknown>) => Promise<T>;
  /** ops_read; `withFn` adds the staff function, as the staff copy did for that read */
  ops: <T = Row>(what: string, p?: Record<string, unknown>, withFn?: boolean) => Promise<T>;
}

export async function adminCtx(next: string): Promise<PageCtx> {
  const { user, read, list } = await page(next);
  return {
    viewer: ADMIN, user, aal: undefined, read, list,
    own: <T,>(what: string, p: Record<string, unknown> = {}) => door<T>(user.id, 'admin_read', what, p),
    ops: <T,>(what: string, p: Record<string, unknown> = {}) => door<T>(user.id, 'ops_read', what, p)
  };
}

export async function staffCtx(next: string, only?: Fn[]): Promise<PageCtx> {
  const { user, read, list, fn, aal } = await vaPage(next, only);
  return {
    viewer: staffViewer(fn), user, aal, read, list,
    own: <T,>(what: string, p: Record<string, unknown> = {}) => door<T>(user.id, 'va_read', what, p, aal),
    ops: <T,>(what: string, p: Record<string, unknown> = {}, withFn = false) => door<T>(user.id, 'ops_read', what, withFn ? { ...p, _va: fn } : p, aal)
  };
}
