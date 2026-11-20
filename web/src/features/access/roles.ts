// One portal, many roles (r48 ops; the owner, Nov 20: "multiple portal accesses: combine them into one portal"). A person
// with more than one role (Sales and Field, an owner who is also staff, an Admin who owns a car) no longer gets separate
// portals to choose between: every frame carries one role switcher with all their roles, and the pages of the roles they
// are not in right now one tap away (the merged navigation). Sign-in opens the role used last instead of a chooser.
// Permissions are exactly as before: this file only lists links; every page still checks the role and the second factor
// itself, and the database decides. Pure, for the unit tests.
export type RoleKey = 'admin' | 'cs' | 'sales' | 'fleet' | 'finance' | 'field' | 'investor' | 'owner' | 'account';
export type PortalOf = 'admin' | 'va' | 'investor' | 'owner' | 'account';
export interface RoleInfo { admin: boolean; va: string | null; va_functions?: string[]; functions?: string[]; field: boolean; owner: boolean; renter: boolean; investor: boolean }
export interface RoleLink { key: RoleKey; label: string; href: string; portal: PortalOf;
  /** an office function is chosen by the staff portal's own action (it sets the working function), not by a plain link */
  fn?: 'cs' | 'sales' | 'fleet' | 'finance' }
export interface NavLinkLite { href: string; label: string }

export const LAST_PORTAL_COOKIE = 'cc_last_portal';
export const ROLE_LABEL: Record<RoleKey, string> = { admin: 'Admin', cs: 'Customer service', sales: 'Sales', fleet: 'Fleet', finance: 'Finance', field: 'Field work', investor: 'Investor', owner: 'Owner', account: 'My rentals' };
const OFFICE = ['cs', 'sales', 'fleet', 'finance'] as const;

/** Every role the person has, in one order: Admin, the office functions as held, field work, investor, owner, renting
 *  (never for an Admin: 0720). The same roles as server/portals.ts portalsFor gives portals for, one entry a role. */
export function rolesFor(r: RoleInfo): RoleLink[] {
  const out: RoleLink[] = [];
  if (r.admin) out.push({ key: 'admin', label: ROLE_LABEL.admin, href: '/admin', portal: 'admin' });
  const held = r.functions?.length ? r.functions : [...(r.va_functions ?? (r.va ? [r.va] : [])), ...(r.field ? ['field'] : [])];
  for (const f of OFFICE) if (held.includes(f)) out.push({ key: f, label: ROLE_LABEL[f], href: `/staff/switch?fn=${f}`, portal: 'va', fn: f });
  if (r.field || held.includes('field')) out.push({ key: 'field', label: ROLE_LABEL.field, href: '/staff/field', portal: 'va' });
  if (r.investor) out.push({ key: 'investor', label: ROLE_LABEL.investor, href: '/investor', portal: 'investor' });
  if (r.owner) out.push({ key: 'owner', label: ROLE_LABEL.owner, href: '/owner', portal: 'owner' });
  if (r.renter && !r.admin) out.push({ key: 'account', label: ROLE_LABEL.account, href: '/account', portal: 'account' });
  return out;
}

/** The role the person is in on this page: by the address, and inside the staff portal by the function they work in
 *  (field pages are field work whatever the function). Null on a page that belongs to no role. */
export function currentRole(path: string, activeFn: string | null | undefined, roles: RoleLink[]): RoleKey | null {
  const under = (p: string) => path === p || path.startsWith(`${p}/`);
  const has = (k: RoleKey) => roles.some((r) => r.key === k);
  if (under('/admin')) return has('admin') ? 'admin' : null;
  if (under('/staff/field')) return has('field') ? 'field' : null;
  if (under('/staff')) {
    if (activeFn && has(activeFn as RoleKey)) return activeFn as RoleKey;
    return roles.find((r) => r.portal === 'va')?.key ?? null;
  }
  if (under('/investor')) return has('investor') ? 'investor' : null;
  if (under('/owner')) return has('owner') ? 'owner' : null;
  if (under('/account')) return has('account') ? 'account' : null;
  return null;
}

/** The most used pages of each role, for the merged navigation: what a person in another role can jump straight to. The
 *  first is the role's home. A short list on purpose (the role's own menu has the rest once they are in it). */
export const ROLE_NAV: Record<RoleKey, NavLinkLite[]> = {
  admin: [{ href: '/admin', label: 'To do' }, { href: '/admin/bookings', label: 'Bookings' }, { href: '/admin/calendar', label: 'Calendar' }, { href: '/admin/vehicles', label: 'Cars' }],
  cs: [{ href: '/staff', label: 'To do' }, { href: '/staff/requests', label: 'Requests' }, { href: '/staff/messages', label: 'Messages' }, { href: '/staff/bookings', label: 'Bookings' }],
  sales: [{ href: '/staff', label: 'To do' }, { href: '/staff/requests', label: 'Requests and offers' }, { href: '/staff/bookings', label: 'Bookings' }, { href: '/staff/calendar', label: 'Calendar' }],
  fleet: [{ href: '/staff', label: 'To do' }, { href: '/staff/fleet', label: 'Field jobs' }, { href: '/staff/checks', label: 'Checks' }, { href: '/staff/calendar', label: 'Calendar' }],
  finance: [{ href: '/staff', label: 'To do' }, { href: '/staff/money', label: 'Money' }, { href: '/staff/owner-money?tab=invoices', label: 'Owner money' }, { href: '/staff/bookings', label: 'Bookings' }],
  field: [{ href: '/staff/field', label: 'Today' }, { href: '/staff/field/shifts', label: 'My shifts' }, { href: '/staff/field/pay', label: 'My pay' }],
  investor: [{ href: '/investor', label: 'Home' }, { href: '/investor/documents', label: 'Documents' }, { href: '/investor/updates', label: 'Updates' }],
  owner: [{ href: '/owner', label: 'Home' }, { href: '/owner/vehicles', label: 'Cars' }, { href: '/owner/vehicles?tab=bookings', label: 'Bookings' }, { href: '/owner/money', label: 'Money' }],
  account: [{ href: '/account', label: 'Trips' }, { href: '/account/documents', label: 'Documents' }, { href: '/account/profile', label: 'Account' }]
};
/** The merged navigation of a page: each OTHER role of the person with its pages. An office function's pages open in that
 *  function (the link switches to it first), so what opens is never refused for being in another function. */
export function mergedNav(roles: RoleLink[], current: RoleKey | null): Array<{ role: RoleLink; links: NavLinkLite[] }> {
  return roles.filter((r) => r.key !== current).map((r) => ({ role: r,
    links: ROLE_NAV[r.key].map((l) => (r.fn ? { ...l, href: `/staff/switch?fn=${r.fn}&to=${encodeURIComponent(l.href)}` } : l)) }));
}

/** Where sign-in lands with no page asked for: the one role, or with several the role used last on this device when the
 *  person still has it, else their first (Admin, then staff, investor, owner). Renting counts only when there is nothing else. */
export function landingRole(roles: RoleLink[], last: string | null | undefined): string {
  const work = roles.filter((r) => r.key !== 'account');
  if (!work.length) return '/account';
  const mine = last ? work.find((r) => r.key === last) ?? work.find((r) => r.portal === last) : undefined;
  const to = mine ?? work[0]!;
  if (!to.fn) return to.href;
  // an office function: the one the cookie names is switched to; otherwise the staff portal as it was last left
  return mine && mine.key === last ? to.href : '/staff';
}
