import { STAFF_HUBS, STAFF_SECTIONS, hubsFor, sectionLink, sectionsFor, type Hub, type Section } from '../admin/hubs.ts';

// The staff portal's one navigation (0197; the owner, October 30, 2026: "Instead of /va and /field it's just /staff"): the
// groups of every function the person holds, in one menu. A person with Sales and field work sees the Sales pages and their
// field jobs together. A page that two held functions share is listed once (its first group). The pages check the function
// themselves (vaPage, requireStaff); the menu only shows what the person can open.
export type StaffFn = 'cs' | 'fleet' | 'finance' | 'sales' | 'field';
export type OfficeFn = Exclude<StaffFn, 'field'>;
export interface NavLink { href: string; label: string; key?: string; /** a page group's other addresses (r27) */ also?: string[]; /** a section (r27): resolved per person */ sec?: string }
export interface NavGroup { key: string; label: string; links: NavLink[] }

export const OFFICE_FNS: OfficeFn[] = ['cs', 'fleet', 'finance', 'sales'];

/** A section's menu link, resolved for the person in staffNav (its first page they can open that is not already a link). */
const sec = (key: string, label?: string, k?: string): NavLink => ({ href: '', label: label ?? key, sec: key, ...(k ? { key: k } : {}) });

export const STAFF_FN_LABEL: Record<StaffFn, string> = { cs: 'Customer service', fleet: 'Fleet', finance: 'Finance', sales: 'Sales', field: 'Field work' };

// The menu of each role (r27 audit, the owner on November 1, 2026: "Lots of the tabs under admin and under each staff
// account are redundant and can be merged", then "i think u can reduce staff menu links even further"). The same few
// anchors for every office role: To do (the home; Today at a glance is its tab), the role's most frequent jobs, one
// "More ..." link for the rest of its work (a section, features/admin/hubs.ts STAFF_SECTIONS: a row of its pages on top),
// Bookings and Me. r27 consolidation (November 2, 2026): at most five links a role; actions (Send an offer, New quote, Add a
// rental, Report a problem) are buttons on their page (STAFF_ACTIONS); Live visitors and Live chat are one Visitors page;
// Fleet and Field work have their map; Sales has Marketing (the Marketplace from their own profile, 0510). A person holding several functions sees each role's
// group, a page once.
export const STAFF_GROUPS: NavGroup[] = [
  { key: 'today', label: 'To do', links: [sec('todo', 'To do', 't')] },
  { key: 'cs', label: 'Customer service', links: [{ href: '/staff/requests', label: 'Requests', key: 'r' }, { href: '/staff/visitors', label: 'Visitors', key: 'v' }, { href: '/staff/messages', label: 'Messages' }, sec('cs', 'More customer service')] },
  { key: 'sales', label: 'Sales', links: [{ href: '/staff/requests', label: 'Requests and offers', key: 'r' }, { href: '/staff/visitors', label: 'Visitors', key: 'v' }, { href: '/staff/marketing', label: 'Marketing', also: ['/staff/marketplace'] }, { href: '/staff/my-sales', label: 'My sales' }, sec('sales', 'More sales')] },
  { key: 'fleet', label: 'Fleet', links: [{ href: '/staff/fleet', label: 'Field jobs', also: ['/staff/field-hours'] }, { href: '/staff/fleet/map', label: 'Fleet map' }, { href: '/staff/checks', label: 'Checks', also: ['/staff/reviews'] }, { href: '/staff/maintenance', label: 'Maintenance' }, sec('fleet', 'More fleet')] },
  { key: 'finance', label: 'Finance', links: [{ href: '/staff/money', label: 'Money', also: ['/staff/payments', '/staff/reconciliation'] }, { href: '/staff/owner-money?tab=invoices', label: 'Owner money', also: ['/staff/owner-money'] }, { href: '/staff/tolls', label: 'Tolls and tickets' }, { href: '/staff/turo', label: 'Turo trips' }, sec('finance', 'More finance')] },
  { key: 'field', label: 'Field work', links: [{ href: '/staff/field', label: 'My jobs' }, { href: '/staff/field/now', label: 'Cars now' }, { href: '/staff/field/map', label: 'Map' }, { href: '/staff/field/hours', label: 'My hours' }] },
  { key: 'bookings', label: 'Bookings', links: [sec('bookings', 'Bookings', 'b')] },
  { key: 'me', label: 'Me', links: [sec('me', 'Me')] }
];

// which functions show each group
const SHOWN: Record<string, StaffFn[]> = {
  today: OFFICE_FNS, cs: ['cs'], sales: ['sales'], fleet: ['fleet'], finance: ['finance'], bookings: OFFICE_FNS, me: [...OFFICE_FNS, 'field'], field: ['field']
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

/** A person's sections: the pages of their functions, in the order their roles come. */
export function staffSections(fns: readonly string[] | null | undefined): Section[] {
  const held = heldFunctions(fns);
  const office = held.some((f) => f !== 'field');
  const order = ['todo', ...held, 'bookings', 'me'];
  return sectionsFor(STAFF_SECTIONS, staffHubs(held), held, (h) => office && FIELD_ALONE.has(h))
    .filter((x) => order.includes(x.key)).sort((a, b) => order.indexOf(a.key) - order.indexOf(b.key));
}

/** The menu for a person holding these functions. */
export function staffNav(fns: readonly string[] | null | undefined): NavGroup[] {
  const held = heldFunctions(fns);
  const office = held.some((f) => f !== 'field');
  const hubs = staffHubs(held);
  const sections = staffSections(held);
  const seen = new Set<string>();
  const out: NavGroup[] = [];
  for (const g of STAFF_GROUPS) {
    if (!SHOWN[g.key]!.some((f) => held.includes(f))) continue;
    const direct = g.links.filter((l) => !l.sec).map((l) => l.href);
    const links = g.links.map((l): NavLink | null => {
      if (!l.sec) return l;
      const x = sectionLink(sections, hubs, l.sec, l.label, direct);
      return x ? { ...x, ...(l.key ? { key: l.key } : {}) } : null;
    }).filter((l): l is NavLink => !!l && !(office && FIELD_ALONE.has(l.href)) && !seen.has(l.href));
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
