// The staff portal's one navigation (0197; the owner, October 30, 2026: "Instead of /va and /field it's just /staff"): the
// groups of every function the person holds, in one menu. A person with Sales and field work sees the Sales pages and their
// field jobs together. A page that two held functions share is listed once (its first group). The pages check the function
// themselves (vaPage, requireStaff); the menu only shows what the person can open.
export type StaffFn = 'cs' | 'fleet' | 'finance' | 'sales' | 'field';
export type OfficeFn = Exclude<StaffFn, 'field'>;
export interface NavLink { href: string; label: string; key?: string }
export interface NavGroup { key: string; label: string; links: NavLink[] }

export const OFFICE_FNS: OfficeFn[] = ['cs', 'fleet', 'finance', 'sales'];
export const STAFF_FN_LABEL: Record<StaffFn, string> = { cs: 'Customer service', fleet: 'Fleet', finance: 'Finance', sales: 'Sales', field: 'Field work' };

// every group, in menu order (each function's own pages; "My work" and "Rentals" for every office function)
export const STAFF_GROUPS: NavGroup[] = [
  { key: 'work', label: 'My work', links: [{ href: '/staff', label: 'To do', key: 't' }, { href: '/staff/today', label: 'Today at a glance' }, { href: '/staff/scorecard', label: 'My scorecard' }, { href: '/staff/my-sales', label: 'My sales' }] },
  { key: 'live', label: 'Live', links: [{ href: '/staff/chat', label: 'Live chat' }, { href: '/staff/live', label: 'Live visitors' }, { href: '/staff/game-leads', label: 'Game leads' }] },
  { key: 'cs', label: 'Customer service', links: [{ href: '/staff/requests', label: 'Requests', key: 'r' }, { href: '/staff/chauffeur', label: 'Chauffeur' }, { href: '/staff/offers/new', label: 'Send an offer' }, { href: '/staff/messages', label: 'Messages' }, { href: '/staff/renters', label: 'Find a renter' }, { href: '/staff/review-requests', label: 'Review requests' }, { href: '/staff/listings', label: 'Listings' }, { href: '/staff/similar-cars', label: 'Similar cars' }, { href: '/staff/leads', label: 'Owners and enquiries' }, { href: '/staff/owners/add-car', label: 'Add a car for an owner' }, { href: '/staff/owner-forms', label: 'Owner forms' }] },
  { key: 'sales', label: 'Sales', links: [{ href: '/staff/requests', label: 'Requests and offers', key: 'r' }, { href: '/staff/chauffeur', label: 'Chauffeur' }, { href: '/staff/offers/new', label: 'Send an offer' }, { href: '/staff/quotes/new', label: 'New quote' }, { href: '/staff/leads', label: 'Owner leads' }] },
  { key: 'fleet', label: 'Fleet', links: [{ href: '/staff/fleet', label: 'Field jobs' }, { href: '/staff/field-hours', label: 'Field hours' }, { href: '/staff/maintenance', label: 'Maintenance' }, { href: '/staff/checks', label: 'Daily checks' }, { href: '/staff/reviews', label: 'Photo reviews' }, { href: '/staff/listings', label: 'Listings' }, { href: '/staff/similar-cars', label: 'Similar cars' }, { href: '/staff/calendar-sync', label: 'Calendar sync' }, { href: '/staff/addons', label: 'Add-ons' }, { href: '/staff/owners/add-car', label: 'Add a car for an owner' }, { href: '/staff/renters', label: 'Find a renter' }] },
  { key: 'finance', label: 'Finance', links: [{ href: '/staff/payments', label: 'Payments by day' }, { href: '/staff/money', label: 'Payments, deposits and refunds' }, { href: '/staff/tolls', label: 'Tolls and tickets' }, { href: '/staff/reconciliation', label: 'Reconciliation' }, { href: '/staff/turo', label: 'Turo trips' }, { href: '/staff/maintenance', label: 'Maintenance bills' }, { href: '/staff/renters', label: 'Find a renter' }] },
  { key: 'rentals', label: 'Rentals', links: [{ href: '/staff/bookings/new', label: 'Add a rental' }, { href: '/staff/quotes/new', label: 'New quote' }, { href: '/staff/cars', label: 'Find a car' }, { href: '/staff/calendar', label: 'Calendar', key: 'c' }, { href: '/staff/card-coverage', label: 'Card coverage' }] },
  { key: 'field', label: 'Field work', links: [{ href: '/staff/field', label: 'My jobs' }, { href: '/staff/field/report', label: 'Report a problem' }, { href: '/staff/field/hours', label: 'My hours' }, { href: '/staff/field/rentals/new', label: 'Add a rental' }, { href: '/staff/field/sales', label: 'My sales' }, { href: '/staff/field/referrals', label: 'Referrals' }, { href: '/staff/field/profile', label: 'Profile' }] }
];

// which functions show each group
const SHOWN: Record<string, StaffFn[]> = {
  work: OFFICE_FNS, live: ['cs', 'sales'], cs: ['cs'], sales: ['sales'], fleet: ['fleet'], finance: ['finance'], rentals: OFFICE_FNS, field: ['field']
};
// field pages that the office pages already give a person who also holds an office function (Add a rental, My sales, Profile)
const FIELD_ALONE = new Set(['/staff/field/rentals/new', '/staff/field/sales', '/staff/field/profile']);

/** The functions in a stable order (office functions as held, field work last), unknown values dropped. */
export function heldFunctions(fns: readonly string[] | null | undefined): StaffFn[] {
  const known = new Set<string>([...OFFICE_FNS, 'field']);
  const out = [...new Set((fns ?? []).filter((f) => known.has(f)))] as StaffFn[];
  return [...out.filter((f) => f !== 'field'), ...out.filter((f) => f === 'field')];
}

/** The menu for a person holding these functions. */
export function staffNav(fns: readonly string[] | null | undefined): NavGroup[] {
  const held = heldFunctions(fns);
  const office = held.some((f) => f !== 'field');
  const seen = new Set<string>();
  const out: NavGroup[] = [];
  for (const g of STAFF_GROUPS) {
    if (!SHOWN[g.key]!.some((f) => held.includes(f))) continue;
    const links = g.links.filter((l) => !(office && FIELD_ALONE.has(l.href)) && !seen.has(l.href));
    for (const l of links) seen.add(l.href);
    if (links.length) out.push({ ...g, links });
  }
  return out;
}

/** Where the portal opens: the work queue with an office function, else the field jobs. */
export const staffHome = (fns: readonly string[] | null | undefined): string => (heldFunctions(fns).some((f) => f !== 'field') ? '/staff' : '/staff/field');

/** The functions on a staff profile row: its set (0197), else the older columns (a page reading an older row). */
export function profileFunctions(p: { functions?: unknown; va_function?: unknown; cover_functions?: unknown; field_function?: unknown }): StaffFn[] {
  if (Array.isArray(p.functions) && p.functions.length) return heldFunctions(p.functions as string[]);
  return heldFunctions([...(p.va_function ? [String(p.va_function)] : []), ...(Array.isArray(p.cover_functions) ? (p.cover_functions as string[]) : []), ...(p.field_function ? ['field'] : [])]);
}
