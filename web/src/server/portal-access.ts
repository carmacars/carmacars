import 'server-only';
import { headers } from 'next/headers';
import { notFound, redirect } from 'next/navigation';
import { movedTo } from '@/features/admin/hubs';
import { movedTo as movedToTab } from '@/features/portal-nav/tabs';
import { OWNER_MOVED } from '@/features/owner/menu';
import { PATH_HEADER } from '@/lib/edge/portal-gate';
import { door, requireInvestor, requireStaff, rolesOf } from '@/server/door';
import { currentUser } from '@/server/portal/data';
import { pageFunction, type Fn } from '@/server/va';

// R48: the portal checks above the loading boundary. A segment loading.tsx (release 48 speed) wraps every page below it
// in Suspense, so a page's own redirect() or notFound() streams as HTTP 200 (a client redirect, a soft 404). The portal
// layouts sit above those boundaries: they run the same check as the page here, with the path the fronts pass
// (PATH_HEADER, set by the Worker, the VPS front and serve.mjs, never the client's), so the answer is a real 307 or 404
// before anything streams. Each page keeps its own check (a client navigation does not render the layout again; next dev
// has no front, so no header and only the page's check).

/** The portal page's path (no query) from the front, or null (next dev, a request the front did not mark). */
export async function requestPath(): Promise<string | null> {
  return (await requestUrl())?.path ?? null;
}

/** The portal page's path and its query as searchParams, from the front, or null. */
export async function requestUrl(): Promise<{ path: string; sp: Record<string, string | string[]> } | null> {
  let v: string | null = null;
  try { v = (await headers()).get(PATH_HEADER); } catch { return null; }
  if (!v || !v.startsWith('/')) return null;
  const i = v.indexOf('?');
  const sp: Record<string, string | string[]> = {};
  for (const [k, x] of new URLSearchParams(i < 0 ? '' : v.slice(i + 1))) { const o = sp[k]; sp[k] = o === undefined ? x : Array.isArray(o) ? [...o, x] : [o, x]; }
  let path = i < 0 ? v : v.slice(0, i);
  try { path = decodeURI(path); } catch { /* kept as sent */ }
  return { path, sp };
}

// ---------------------------------------------------------------- moved pages
// r27: an old address that is a tab of a merged page now. The page redirects (the query kept); the layout does the
// same first, so the 307 is real. [to, tab, old tab names to new ones]
export const ADMIN_MOVED: Record<string, [string, string, Record<string, string>?]> = {
  '/admin/debits': ['/admin/owner-money', 'debits'],
  '/admin/invoices': ['/admin/owner-money', 'invoices'],
  '/admin/incidents': ['/admin/damages', 'incidents', { claims: 'claims' }],
  '/admin/reconciliation': ['/admin/money', 'reconciliation'],
  '/admin/audit': ['/admin/logs', 'changes', { changes: 'changes', access: 'access' }],
  '/admin/leads': ['/admin/renters', 'leads'],
  '/admin/messages': ['/admin/logs', 'emails', { outbox: 'emails', suppressions: 'blocked' }],
  '/admin/payments': ['/admin/money', 'day'],
  '/admin/payouts': ['/admin/owner-money', 'payouts'],
  '/admin/statements': ['/admin/owner-money', 'statements'],
  '/admin/insurer-invoices': ['/admin/insurers', 'invoices'],
};
// the staff pages: Finance only, as before
export const STAFF_MOVED: Record<string, [string, string]> = {
  '/staff/reconciliation': ['/staff/money', 'reconciliation'],
  '/staff/payments': ['/staff/money', 'day'],
};

export interface StaffRule { kind: 'va' | 'field'; only?: readonly Fn[] }

/** The functions a shared staff page is for: the page passes the same list to staffCtx, so both checks are one rule. */
export const STAFF_ONLY = {
  vehicle: ['fleet', 'cs', 'finance'],
  listing: ['cs', 'fleet'],
  requests: ['cs', 'sales'],
  renters: ['cs', 'finance', 'fleet'],
  addCar: ['cs', 'fleet', 'sales'],
  finance: ['finance'],
  // r50 hotfix 2 (5120): Insurance replacements, for Finance and customer service (never Field)
  insurance: ['finance', 'cs'],
} as const satisfies Record<string, readonly Fn[]>;

// the staff pages whose check the layout runs first (the homes and the shared Admin and staff pages)
const STAFF_RULES: Array<[RegExp, StaffRule]> = [
  [/^\/staff\/?$/, { kind: 'va' }],
  [/^\/staff\/field\/?$/, { kind: 'field' }],
  [/^\/staff\/bookings(\/[^/]+)?\/?$/, { kind: 'va' }],
  [/^\/staff\/vehicles\/[^/]+\/?$/, { kind: 'va', only: STAFF_ONLY.vehicle }],
  [/^\/staff\/listings\/[^/]+\/?$/, { kind: 'va', only: STAFF_ONLY.listing }],
  [/^\/staff\/requests\/?$/, { kind: 'va', only: STAFF_ONLY.requests }],
  [/^\/staff\/renters\/?$/, { kind: 'va', only: STAFF_ONLY.renters }],
  [/^\/staff\/owners\/add-car\/?$/, { kind: 'va', only: STAFF_ONLY.addCar }],
  // r49 (3480): the Finance dashboard and bank lines, Finance only (app/staff/finance/page.tsx passes the same list)
  [/^\/staff\/finance\/?$/, { kind: 'va', only: STAFF_ONLY.finance }],
  [/^\/staff\/insurance-replacements(\/[^/]+)?\/?$/, { kind: 'va', only: STAFF_ONLY.insurance }],
];

export function staffRule(path: string): StaffRule | null {
  if (STAFF_MOVED[path]) return { kind: 'va', only: ['finance'] };
  for (const [re, rule] of STAFF_RULES) if (re.test(path)) return rule;
  return null;
}

/** The staff page's own gate (requireStaff, then vaPage's function check), run from the staff layout. */
export async function staffGate(path: string, sp: Record<string, string | string[]> = {}): Promise<void> {
  const rule = staffRule(path);
  if (!rule) return;
  const moved = STAFF_MOVED[path];
  const { roles } = await requireStaff(rule.kind, moved ? `${moved[0]}?tab=${moved[1]}` : path.replace(/\/$/, '') || '/staff');
  if (rule.kind === 'va' && rule.only && !pageFunction(roles.va as Fn, roles.va_functions?.length ? roles.va_functions : [roles.va as Fn], rule.only)) notFound();
  if (moved) redirect(movedTo(moved[0], moved[1], sp));
}

/** An Admin's moved page, after the Admin gate (the layout runs requireAdmin first). */
export function adminMoved(path: string, sp: Record<string, string | string[]>): void {
  const m = ADMIN_MOVED[path];
  if (m) redirect(movedTo(m[0], m[1], sp, m[2]));
}

/** An owner's moved page (features/owner/menu.ts OWNER_MOVED; the page checks nothing before it redirects either). */
export function ownerMoved(path: string, sp: Record<string, string | string[]>): void {
  const m = OWNER_MOVED[path];
  if (m) redirect(movedToTab(m[0], m[1], sp));
}

// R49: the investor portal has a segment loading.tsx (the investor skeleton), so its pages' requireInvestor() and the
// statement's notFound() stream as 200 too. The investor layout runs the same checks first, as the owner and staff ones do.
const INVESTOR_OPEN = /^\/investor\/no-access\/?$/;
// the deck and the updates: investors and Admins (the Admin preview); every other investor page: investors only
const INVESTOR_OR_ADMIN = /^\/investor\/(deck|updates)\/?$/;
const INVESTOR_STATEMENT = /^\/investor\/statements\/([^/]+)\/?$/;

/** The investor page's own gate (requireInvestor, the deck's and updates' investor-or-Admin check, a statement of
 * their own or 404), run from the investor layout. */
export async function investorGate(path: string): Promise<void> {
  if (!/^\/investor(\/|$)/.test(path) || INVESTOR_OPEN.test(path)) return;
  if (INVESTOR_OR_ADMIN.test(path)) {
    const user = await currentUser();
    if (!user) redirect(`/sign-in?next=${encodeURIComponent(path.replace(/\/$/, ''))}`);
    const roles = await rolesOf(user.id);
    if (!roles.investor && !roles.admin) redirect('/investor/no-access');
    return;
  }
  const st = INVESTOR_STATEMENT.exec(path);
  if (st && !/^[0-9a-f-]{36}$/.test(st[1]!)) notFound();
  const { user } = await requireInvestor(path.replace(/\/$/, '') || '/investor');
  // another investor's statement reads as not found (the page checks the same)
  if (st && !(await door<unknown>(user.id, 'investor_read', 'statement', { id: st[1] }).catch(() => null))) notFound();
}
