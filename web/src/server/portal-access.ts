import 'server-only';
import { headers } from 'next/headers';
import { notFound } from 'next/navigation';
import { PATH_HEADER } from '@/lib/edge/portal-gate';
import { requireStaff } from '@/server/door';
import { pageFunction, type Fn } from '@/server/va';

// R48: the portal checks above the loading boundary. A segment loading.tsx (release 48 speed) wraps every page below it
// in Suspense, so a page's own redirect() or notFound() streams as HTTP 200 (a client redirect, a soft 404). The portal
// layouts sit above those boundaries: they run the same check as the page here, with the path the fronts pass
// (PATH_HEADER, set by the Worker, the VPS front and serve.mjs, never the client's), so the answer is a real 307 or 404
// before anything streams. Each page keeps its own check (a client navigation does not render the layout again; next dev
// has no front, so no header and only the page's check).

/** The portal page's path from the front, or null (next dev, a request the front did not mark). */
export async function requestPath(): Promise<string | null> {
  try {
    const p = (await headers()).get(PATH_HEADER);
    return p && p.startsWith('/') ? p : null;
  } catch { return null; }
}

export interface StaffRule { kind: 'va' | 'field'; only?: readonly Fn[] }

/** The functions a shared staff page is for: the page passes the same list to staffCtx, so both checks are one rule. */
export const STAFF_ONLY = {
  vehicle: ['fleet', 'cs', 'finance'],
  listing: ['cs', 'fleet'],
  requests: ['cs', 'sales'],
  renters: ['cs', 'finance', 'fleet'],
  addCar: ['cs', 'fleet', 'sales'],
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
];

export function staffRule(path: string): StaffRule | null {
  for (const [re, rule] of STAFF_RULES) if (re.test(path)) return rule;
  return null;
}

/** The staff page's own gate (requireStaff, then vaPage's function check), run from the staff layout. */
export async function staffGate(path: string): Promise<void> {
  const rule = staffRule(path);
  if (!rule) return;
  const { roles } = await requireStaff(rule.kind, path.replace(/\/$/, '') || '/staff');
  if (rule.kind === 'va' && rule.only && !pageFunction(roles.va as Fn, roles.va_functions?.length ? roles.va_functions : [roles.va as Fn], rule.only)) notFound();
}
