import type { Roles } from '@/server/door';

// The portals a person has, and where sign-in takes them. One list for the sign-in redirect, the "Choose a portal"
// page, the switcher in each portal's frame and the refusal pages.
export type PortalKey = 'admin' | 'va' | 'field' | 'investor' | 'owner' | 'account';
export interface PortalLink { key: PortalKey; label: string; href: string; fn?: string }

export const PORTAL_LABEL: Record<PortalKey, string> = {
  admin: 'Admin', va: 'Staff portal', field: 'Staff portal', investor: 'Investor portal', owner: 'Owner portal', account: 'My rentals'
};
export const FN_NAME: Record<string, string> = { finance: 'Finance', fleet: 'Fleet', cs: 'Customer service', sales: 'Sales' };
export const PORTAL_HOME: Record<PortalKey, string> = { admin: '/admin', va: '/staff', field: '/staff/field', investor: '/investor', owner: '/owner', account: '/account' };

/** Every portal the person has, in this order: Admin, staff (every function, field work included), investor, owner, rentals. */
export function portalsFor(r: Roles): PortalLink[] {
  const out: PortalLink[] = [];
  if (r.admin) out.push({ key: 'admin', label: PORTAL_LABEL.admin, href: '/admin' });
  // one staff portal (0197) for every kind of staff work: office functions and field work alike; it opens on the work
  // queue with an office function, else on the field jobs (its own switcher picks the function)
  if (r.va || r.field) out.push({ key: 'va', label: PORTAL_LABEL.va, href: r.va ? '/staff' : '/staff/field' });
  if (r.investor) out.push({ key: 'investor', label: PORTAL_LABEL.investor, href: '/investor' });
  if (r.owner) out.push({ key: 'owner', label: PORTAL_LABEL.owner, href: '/owner' });
  if (r.renter) out.push({ key: 'account', label: PORTAL_LABEL.account, href: '/account' });
  return out;
}

/** Where a person goes after signing in when no page was asked for: the one portal they have, or the "Choose a
 *  portal" page when they have two or more (renting counts only when there is nothing else). */
export function landingFor(r: Roles): string {
  const work = new Set(portalsFor(r).filter((p) => p.key !== 'account').map((p) => p.key));
  if (work.size >= 2) return '/choose-portal';
  if (work.size === 1) return PORTAL_HOME[[...work][0]!];
  return '/account';
}

/** A path on this site only (no scheme, no //host), for ?next=. */
export const safeNext = (n: unknown): string | null => (typeof n === 'string' && n.length < 300 && /^\/(?!\/)[\w\-/?=&.%]*$/.test(n) && !n.includes('\\') ? n : null);
