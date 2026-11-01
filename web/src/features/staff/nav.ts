import { STAFF_HUBS, hubsFor, type Hub } from '../admin/hubs.ts';

// The staff portal's one navigation (0197; the owner, October 30, 2026: "Instead of /va and /field it's just /staff"): the
// groups of every function the person holds, in one menu. A person with Sales and field work sees the Sales pages and their
// field jobs together. A page that two held functions share is listed once (its first group). The pages check the function
// themselves (vaPage, requireStaff); the menu only shows what the person can open.
export type StaffFn = 'cs' | 'fleet' | 'finance' | 'sales' | 'field';
export type OfficeFn = Exclude<StaffFn, 'field'>;
export interface NavLink { href: string; label: string; key?: string; /** a page group's other addresses (r27) */ also?: string[]; /** a page group (r27): resolved per person */ hub?: string }
export interface NavGroup { key: string; label: string; links: NavLink[] }

export const OFFICE_FNS: OfficeFn[] = ['cs', 'fleet', 'finance', 'sales'];

/** A page group's menu link, resolved for the person in staffNav. */
const hub = (key: string): NavLink => ({ href: '', label: key, hub: key });

export const STAFF_FN_LABEL: Record<StaffFn, string> = { cs: 'Customer service', fleet: 'Fleet', finance: 'Finance', sales: 'Sales', field: 'Field work' };

// The menu of each role (r27 audit, the owner on November 1, 2026: "Lots of the tabs under admin and under each staff
// account are redundant and can be merged to avoid confusion and to have a smoother workflow"). Each role's own group comes
// first, its links in the order of how often the role uses them; pages that show the same records are one link with a row of
// tabs (hub('key'), features/admin/hubs.ts STAFF_HUBS). Today (To do and Today at a glance) stays the home; Rentals and Me
// close the menu. A person holding several functions sees each of their groups, a page once.
export const STAFF_GROUPS: NavGroup[] = [
  { key: 'today', label: 'Today', links: [{ href: '/staff', label: 'To do', key: 't' }, { href: '/staff/today', label: 'Today at a glance' }] },
  { key: 'cs', label: 'Customer service', links: [{ href: '/staff/requests', label: 'Requests', key: 'r' }, { href: '/staff/chat', label: 'Live chat' }, { href: '/staff/live', label: 'Live visitors' }, { href: '/staff/offers/new', label: 'Send an offer' }, hub('renters'), { href: '/staff/chauffeur', label: 'Chauffeur' }, hub('owners'), hub('listings')] },
  { key: 'sales', label: 'Sales', links: [{ href: '/staff/requests', label: 'Requests and offers', key: 'r' }, { href: '/staff/offers/new', label: 'Send an offer' }, { href: '/staff/quotes/new', label: 'New quote' }, { href: '/staff/chat', label: 'Live chat' }, { href: '/staff/live', label: 'Live visitors' }, hub('renters'), hub('owners'), { href: '/staff/chauffeur', label: 'Chauffeur' }] },
  { key: 'fleet', label: 'Fleet', links: [hub('field-jobs'), hub('checks'), { href: '/staff/maintenance', label: 'Maintenance' }, hub('listings'), { href: '/staff/addons', label: 'Add-ons' }, hub('owners'), hub('renters')] },
  { key: 'finance', label: 'Finance', links: [hub('money'), { href: '/staff/tolls', label: 'Tolls and tickets' }, { href: '/staff/turo', label: 'Turo trips' }, { href: '/staff/maintenance', label: 'Maintenance bills' }, hub('renters')] },
  { key: 'rentals', label: 'Rentals', links: [{ href: '/staff/bookings', label: 'Bookings', key: 'b' }, { href: '/staff/calendar', label: 'Calendar', key: 'c' }, { href: '/staff/cars', label: 'Find a car' }, { href: '/staff/bookings/new', label: 'Add a rental' }, { href: '/staff/quotes/new', label: 'New quote' }, { href: '/staff/card-coverage', label: 'Card coverage' }] },
  { key: 'me', label: 'Me', links: [hub('numbers'), { href: '/staff/academy', label: 'Academy' }] },
  { key: 'field', label: 'Field work', links: [{ href: '/staff/field', label: 'My jobs' }, { href: '/staff/field/report', label: 'Report a problem' }, { href: '/staff/field/rentals/new', label: 'Add a rental' }, hub('field-pay'), { href: '/staff/field/profile', label: 'Profile' }, { href: '/staff/academy', label: 'Academy' }] }
];

// which functions show each group
const SHOWN: Record<string, StaffFn[]> = {
  today: OFFICE_FNS, cs: ['cs'], sales: ['sales'], fleet: ['fleet'], finance: ['finance'], rentals: OFFICE_FNS, me: OFFICE_FNS, field: ['field']
};
// field pages that the office pages already give a person who also holds an office function (Add a rental, My sales, Profile)
const FIELD_ALONE = new Set(['/staff/field/rentals/new', '/staff/field/sales', '/staff/field/profile']);

/** The functions in a stable order (office functions as held, field work last), unknown values dropped. */
export function heldFunctions(fns: readonly string[] | null | undefined): StaffFn[] {
  const known = new Set<string>([...OFFICE_FNS, 'field']);
  const out = [...new Set((fns ?? []).filter((f) => known.has(f)))] as StaffFn[];
  return [...out.filter((f) => f !== 'field'), ...out.filter((f) => f === 'field')];
}

/** A person's page groups: the tabs of their functions (an office holder's field tabs without the pages the office gives). */
export function staffHubs(fns: readonly string[] | null | undefined): Hub[] {
  const held = heldFunctions(fns);
  const office = held.some((f) => f !== 'field');
  return hubsFor(STAFF_HUBS, held).map((h) => ({ ...h, tabs: h.tabs.filter((t) => !(office && FIELD_ALONE.has(t.href))) })).filter((h) => h.tabs.length > 0);
}

/** The menu for a person holding these functions. A page group shows as one link: the group's name, or the page's own name
 *  when the person can open only one of its pages. */
export function staffNav(fns: readonly string[] | null | undefined): NavGroup[] {
  const held = heldFunctions(fns);
  const office = held.some((f) => f !== 'field');
  const hubs = new Map(staffHubs(held).map((h) => [h.key, h]));
  const resolve = (l: NavLink): NavLink | null => {
    if (!l.hub) return l;
    const h = hubs.get(l.hub);
    if (!h) return null;
    const tabs = h.tabs;
    return tabs.length === 1 ? { href: tabs[0]!.href, label: ONE[tabs[0]!.href] ?? tabs[0]!.label } : { href: tabs[0]!.href, label: h.label, also: [...new Set(tabs.map((t) => t.href.split('?')[0]!))] };
  };
  const seen = new Set<string>();
  const out: NavGroup[] = [];
  for (const g of STAFF_GROUPS) {
    if (!SHOWN[g.key]!.some((f) => held.includes(f))) continue;
    const links = g.links.map(resolve).filter((l): l is NavLink => !!l && !(office && FIELD_ALONE.has(l.href)) && !seen.has(l.href));
    for (const l of links) seen.add(l.href);
    if (links.length) out.push({ ...g, links: links.map(({ hub: _h, ...l }) => (void _h, l)) });
  }
  return out;
}
// the name of a group's page when it is the only page of the group a person can open
const ONE: Record<string, string> = { '/staff/owners/add-car': 'Add a car for an owner', '/staff/renters': 'Find a renter', '/staff/game-leads': 'Game leads', '/staff/leads': 'Owner leads' };

/** Where the portal opens: the work queue with an office function, else the field jobs. */
export const staffHome = (fns: readonly string[] | null | undefined): string => (heldFunctions(fns).some((f) => f !== 'field') ? '/staff' : '/staff/field');

/** The functions on a staff profile row: its set (0197), else the older columns (a page reading an older row). */
export function profileFunctions(p: { functions?: unknown; va_function?: unknown; cover_functions?: unknown; field_function?: unknown }): StaffFn[] {
  if (Array.isArray(p.functions) && p.functions.length) return heldFunctions(p.functions as string[]);
  return heldFunctions([...(p.va_function ? [String(p.va_function)] : []), ...(Array.isArray(p.cover_functions) ? (p.cover_functions as string[]) : []), ...(p.field_function ? ['field'] : [])]);
}
