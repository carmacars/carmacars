// Page groups (r27, the owner on November 1, 2026: "There's way too many tabs at the moment and information is spread out
// too much", "We need less pages not more"). A group is one menu link and one row of tabs on top of each of its pages.
// A tab is either `?tab=<key>` on one address (pages that showed the same records from different angles, merged into one
// page; the old addresses redirect there) or a page of its own (separate tools on one subject, grouped; each keeps its
// address). The first tab is where the menu link goes.
export interface HubTab { href: string; label: string; /** staff portal: the functions that may open the page, space separated (the tab row shows a person only theirs) */ fns?: string }
export interface Hub { key: string; label: string; tabs: HubTab[] }
/** A section (r27, second cut, the owner: "i think u can reduce staff menu links even further, along with admin"): one menu
 *  link for a whole area (Cars, People, Money...). Its items are page groups (by key) or single pages; on its pages a first
 *  row shows the items and, when the item is a group, a second row its tabs. */
export interface Section { key: string; label: string; items: Array<string | HubTab> }

export const ADMIN_HUBS: Hub[] = [
  { key: 'payments', label: 'Payments', tabs: [
    { href: '/admin/money?tab=day', label: 'By day' }, { href: '/admin/money?tab=payments', label: 'All payments' }, { href: '/admin/money?tab=refunds', label: 'Refunds' },
    { href: '/admin/money?tab=deposits', label: 'Deposits' }, { href: '/admin/money?tab=disputes', label: 'Disputes' }, { href: '/admin/money?tab=reconciliation', label: 'Reconciliation' }] },
  { key: 'owner-money', label: 'Owner money', tabs: [
    { href: '/admin/owner-money?tab=invoices', label: 'Invoices' }, { href: '/admin/owner-money?tab=debits', label: 'Debits' },
    { href: '/admin/owner-money?tab=statements', label: 'Statements' }, { href: '/admin/owner-money?tab=payouts', label: 'Payouts' }] },
  { key: 'insurers', label: 'Insurers', tabs: [{ href: '/admin/insurers?tab=rates', label: 'Rates' }, { href: '/admin/insurers?tab=invoices', label: 'Invoices' }] },
  { key: 'company', label: 'Company accounts', tabs: [{ href: '/admin/reports', label: 'Monthly statements' }, { href: '/admin/expenses', label: 'Expenses' }] },
  { key: 'staff-pay', label: 'Staff pay', tabs: [{ href: '/admin/money/commissions', label: 'Commissions' }, { href: '/admin/money/field-pay', label: 'Field pay' }] },
  { key: 'problems', label: 'Damage and claims', tabs: [
    { href: '/admin/damages?tab=damage', label: 'Damage' }, { href: '/admin/damages?tab=incidents', label: 'Incidents' }, { href: '/admin/damages?tab=claims', label: 'Claims' }] },
  { key: 'logs', label: 'Logs', tabs: [
    { href: '/admin/logs?tab=emails', label: 'Emails' }, { href: '/admin/logs?tab=blocked', label: 'Blocked addresses' },
    { href: '/admin/logs?tab=changes', label: 'Changes' }, { href: '/admin/logs?tab=access', label: 'Data access' }] },
  { key: 'renters', label: 'Renters', tabs: [{ href: '/admin/renters?tab=renters', label: 'Renters' }, { href: '/admin/renters?tab=leads', label: 'Leads' }] },
  { key: 'vehicles', label: 'Vehicles', tabs: [
    { href: '/admin/vehicles', label: 'All cars' }, { href: '/admin/vehicles/bulk-rates', label: 'Rates for many cars' },
    { href: '/admin/calendar-sync', label: 'Calendar sync' }, { href: '/admin/vehicles/samples', label: 'Retire or delete' }] },
  { key: 'listings', label: 'Listings', tabs: [{ href: '/admin/listings', label: 'Listings' }, { href: '/admin/similar-cars', label: 'Similar cars' }] },
  { key: 'owners', label: 'Owners', tabs: [
    { href: '/admin/owners', label: 'Owners' }, { href: '/admin/owners?view=checklist', label: 'Paid and signed' },
    { href: '/admin/owner-forms', label: 'Owner forms' }, { href: '/admin/owners/add-car', label: 'Add a car' }] },
  { key: 'partners', label: 'Partners', tabs: [{ href: '/admin/partners', label: 'Rental partners' }, { href: '/admin/referral-partners', label: 'Referral partners' }] },
  { key: 'team', label: 'Staff', tabs: [
    { href: '/admin/settings/staff', label: 'Staff and roles' }, { href: '/admin/academy', label: 'Academy' },
    { href: '/admin/hiring', label: 'Hiring' }, { href: '/admin/portals', label: 'Portals and view as' }] },
  { key: 'ads', label: 'Ads', tabs: [
    { href: '/admin/marketing/listings', label: 'Ad listings' }, { href: '/admin/marketing/ads', label: 'Posted ads' }, { href: '/admin/marketing/social', label: 'Social drafts' },
    { href: '/admin/marketing/channels', label: 'Listing channels' }, { href: '/admin/marketing/report', label: 'Bookings by channel' }] },
  { key: 'recruit', label: 'Owner recruitment', tabs: [{ href: '/admin/marketing/recruit', label: 'Recruitment' }, { href: '/admin/marketing/owner-pipeline', label: 'Owner pipeline' }] }
];

// The staff portal's page groups (r27 audit, the owner: "Lots of the tabs under admin and under each staff account are
// redundant and can be merged"). Each tab names the functions whose pages they are (as the menu showed them before), so a
// person sees only the tabs they can open; each page keeps its address and its own check.
export const STAFF_HUBS: Hub[] = [
  { key: 'money', label: 'Money', tabs: [{ href: '/staff/money', label: 'To handle', fns: 'finance' }, { href: '/staff/payments', label: 'By day', fns: 'finance' }, { href: '/staff/reconciliation', label: 'Reconciliation', fns: 'finance' }] },
  { key: 'renters', label: 'Renters', tabs: [{ href: '/staff/messages', label: 'Messages', fns: 'cs' }, { href: '/staff/renters', label: 'Find a renter', fns: 'cs fleet finance' },
    { href: '/staff/review-requests', label: 'Review requests', fns: 'cs' }, { href: '/staff/game-leads', label: 'Leads', fns: 'cs sales' }] },
  { key: 'owners', label: 'Owners', tabs: [{ href: '/staff/leads', label: 'Owner leads', fns: 'cs sales' }, { href: '/staff/owner-pipeline', label: 'Owner pipeline', fns: 'cs sales' },
    { href: '/staff/owner-forms', label: 'Owner forms', fns: 'cs' }, { href: '/staff/owners/add-car', label: 'Add a car', fns: 'cs fleet' }] },
  { key: 'listings', label: 'Listings', tabs: [{ href: '/staff/listings', label: 'Listings', fns: 'cs fleet' }, { href: '/staff/similar-cars', label: 'Similar cars', fns: 'cs fleet' }, { href: '/staff/calendar-sync', label: 'Calendar sync', fns: 'fleet' }] },
  { key: 'field-jobs', label: 'Field jobs', tabs: [{ href: '/staff/fleet', label: 'Jobs', fns: 'fleet' }, { href: '/staff/field-hours', label: 'Field hours', fns: 'fleet' }] },
  { key: 'checks', label: 'Checks', tabs: [{ href: '/staff/checks', label: 'Daily checks', fns: 'fleet' }, { href: '/staff/reviews', label: 'Photo reviews', fns: 'fleet' }] },
  { key: 'numbers', label: 'My numbers', tabs: [{ href: '/staff/scorecard', label: 'Scorecard', fns: 'cs fleet finance sales' }, { href: '/staff/my-sales', label: 'My sales', fns: 'cs fleet finance sales' }] }
];

/** A person's page groups: only the tabs of the functions they hold, and only groups left with a tab. */
export function hubsFor(hubs: Hub[], fns: readonly string[]): Hub[] {
  return hubs.map((h) => ({ ...h, tabs: h.tabs.filter((t) => !t.fns || t.fns.split(' ').some((f) => fns.includes(f))) })).filter((h) => h.tabs.length > 0);
}

const split = (href: string): [string, URLSearchParams] => { const [p = href, q = ''] = href.split('?'); return [p, new URLSearchParams(q)]; };

/** The group and tab of the page shown, or null. A tab with a query matches when the page has every one of its values; a
 *  page with no tab value shows its group's first tab of that address (the default tab). Detail pages show no tab row. */
export function hubOf(hubs: Hub[], path: string, query: string): { hub: Hub; tab: HubTab } | null {
  const here = new URLSearchParams(query);
  for (const hub of hubs) {
    const same = hub.tabs.filter((t) => split(t.href)[0] === path);
    if (!same.length) continue;
    let best: HubTab | null = null; let n = -1;
    for (const t of same) {
      const q = split(t.href)[1];
      const keys = [...q.keys()];
      if (keys.every((k) => here.get(k) === q.get(k)) && keys.length > n) { best = t; n = keys.length; }
    }
    // no tab value matched (none, or one the page does not have): the address's default tab, its first
    return { hub, tab: best ?? same[0]! };
  }
  return null;
}

/** The menu link of a group: its first tab, the group's name, and every address of the group (so the menu shows where you are). */
export function hubLink(hubs: Hub[], key: string): { href: string; label: string; also: string[] } {
  const h = hubs.find((x) => x.key === key);
  if (!h) throw new Error(`no page group ${key}`);
  return { href: h.tabs[0]!.href, label: h.label, also: [...new Set(h.tabs.map((t) => split(t.href)[0]!))] };
}

/** The tab key a merged page shows: the `tab` value when it is one of the page's tabs, else the first. */
export function tabOf<K extends string>(keys: readonly K[], v: string | string[] | undefined): K {
  const s = Array.isArray(v) ? v[0] : v;
  return (keys as readonly string[]).includes(s ?? '') ? (s as K) : keys[0]!;
}

/** Where an old address now lives: the new address with the tab, the old query kept (an old `tab` value mapped by `tabs`). */
export function movedTo(path: string, tab: string, sp: Record<string, string | string[] | undefined>, tabs: Record<string, string> = {}): string {
  const q = new URLSearchParams();
  const old = typeof sp.tab === 'string' ? sp.tab : undefined;
  q.set('tab', (old && tabs[old]) || tab);
  for (const [k, v] of Object.entries(sp)) {
    if (k === 'tab' || v === undefined) continue;
    for (const x of Array.isArray(v) ? v : [v]) q.append(k, x);
  }
  return `${path}?${q.toString()}`;
}


// ---------------------------------------------------------------- sections (r27, second cut)
export const ADMIN_SECTIONS: Section[] = [
  { key: 'cars', label: 'Cars', items: ['vehicles', 'listings', { href: '/admin/maintenance', label: 'Maintenance' }] },
  { key: 'people', label: 'People', items: ['owners', { href: '/admin/applications', label: 'Applications' }, 'partners', 'renters', 'team', { href: '/admin/investors', label: 'Investors' }] },
  { key: 'marketing', label: 'Marketing', items: ['ads', 'recruit'] },
  { key: 'money', label: 'Money', items: ['payments', 'owner-money', { href: '/admin/tolls', label: 'Tolls and tickets' }, 'company', 'insurers', 'staff-pay'] },
  { key: 'settings', label: 'Settings', items: [{ href: '/admin/settings', label: 'Settings' }, 'logs'] }
];

// The staff portal's sections: what each role does less often ("More ..."), Bookings and Me. Single pages name their
// functions like tabs do; a person sees only their items.
const OFFICE = 'cs fleet finance sales';
export const STAFF_SECTIONS: Section[] = [
  { key: 'todo', label: 'To do', items: [{ href: '/staff', label: 'To do', fns: OFFICE }, { href: '/staff/today', label: 'Today at a glance', fns: OFFICE }] },
  { key: 'cs', label: 'Customer service', items: ['renters', { href: '/staff/chauffeur', label: 'Chauffeur', fns: 'cs' }, 'owners', 'listings'] },
  { key: 'sales', label: 'Sales', items: [{ href: '/staff/live', label: 'Live visitors', fns: 'sales' }, 'renters', 'owners', { href: '/staff/chauffeur', label: 'Chauffeur', fns: 'sales' }] },
  { key: 'fleet', label: 'Fleet', items: ['field-jobs', 'checks', { href: '/staff/maintenance', label: 'Maintenance', fns: 'fleet' }, 'listings', { href: '/staff/addons', label: 'Add-ons', fns: 'fleet' }, 'owners', 'renters'] },
  { key: 'finance', label: 'Finance', items: ['money', { href: '/staff/tolls', label: 'Tolls and tickets', fns: 'finance' }, { href: '/staff/turo', label: 'Turo trips', fns: 'finance' }, { href: '/staff/maintenance', label: 'Maintenance bills', fns: 'finance' }, 'renters'] },
  { key: 'bookings', label: 'Bookings', items: [{ href: '/staff/bookings', label: 'Bookings', fns: OFFICE }, { href: '/staff/calendar', label: 'Calendar', fns: OFFICE }, { href: '/staff/cars', label: 'Find a car', fns: OFFICE },
    { href: '/staff/bookings/new', label: 'Add a rental', fns: OFFICE }, { href: '/staff/quotes/new', label: 'New quote', fns: OFFICE }, { href: '/staff/card-coverage', label: 'Card coverage', fns: OFFICE }] },
  { key: 'me', label: 'Me', items: ['numbers', { href: '/staff/field/referrals', label: 'Referrals', fns: 'field' }, { href: '/staff/field/profile', label: 'Profile', fns: 'field' }, { href: '/staff/academy', label: 'Academy', fns: `${OFFICE} field` }] }
];

const holds = (fns: string | undefined, held: readonly string[]) => !fns || fns.split(' ').some((f) => held.includes(f));

/** A person's sections: their single pages and their (already filtered) page groups; sections left empty go. */
export function sectionsFor(sections: Section[], hubs: Hub[], held: readonly string[], drop: (href: string) => boolean = () => false): Section[] {
  const keys = new Set(hubs.map((h) => h.key));
  return sections.map((s) => ({ ...s, items: s.items.filter((i) => (typeof i === 'string' ? keys.has(i) : holds(i.fns, held) && !drop(i.href))) })).filter((s) => s.items.length > 0);
}

export interface SectionItem { key: string; label: string; href: string; paths: string[]; hub: Hub | null }
/** A section's items with their first page and every address under them. A group with one page shows that page's name. */
export function sectionItems(s: Section, hubs: Hub[]): SectionItem[] {
  return s.items.flatMap((i) => {
    if (typeof i !== 'string') return [{ key: i.href, label: i.label, href: i.href, paths: [split(i.href)[0]!], hub: null }];
    const h = hubs.find((x) => x.key === i);
    if (!h || !h.tabs.length) return [];
    return [{ key: h.key, label: h.tabs.length === 1 ? h.tabs[0]!.label : h.label, href: h.tabs[0]!.href, paths: [...new Set(h.tabs.map((t) => split(t.href)[0]!))], hub: h.tabs.length > 1 ? h : null }];
  });
}

/** The menu link of a section: its first item (or the first not already a link of its own), its name, every address in it. */
export function sectionLink(sections: Section[], hubs: Hub[], key: string, label?: string, skip: string[] = []): { href: string; label: string; also: string[] } | null {
  const s = sections.find((x) => x.key === key);
  if (!s) return null;
  const items = sectionItems(s, hubs);
  if (!items.length) return null;
  // the first page of the section that is not a link of its own (a group's next tab when its first one is)
  const pages = s.items.flatMap((i) => (typeof i === 'string' ? (hubs.find((h) => h.key === i)?.tabs ?? []).map((t) => t.href) : [i.href]));
  const href = pages.find((h) => !skip.includes(h)) ?? items[0]!.href;
  return { href, label: label ?? s.label, also: [...new Set(items.flatMap((i) => i.paths))] };
}

/** Where the page shown sits: its section (the first that holds it) with the current item, and its page group and tab. */
export function placeOf(sections: Section[], hubs: Hub[], path: string, query: string): { section: { label: string; items: SectionItem[]; current: SectionItem } | null; hub: { hub: Hub; tab: HubTab } | null } {
  const at = hubOf(hubs, path, query);
  for (const s of sections) {
    const items = sectionItems(s, hubs);
    const current = (at ? items.find((i) => i.key === at.hub.key) : undefined) ?? items.find((i) => i.paths.includes(path));
    if (current) return { section: items.length > 1 ? { label: s.label, items, current } : null, hub: at };
  }
  return { section: null, hub: at };
}
