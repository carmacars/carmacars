// Page groups (r27, the owner on November 1, 2026: "There's way too many tabs at the moment and information is spread out
// too much", "We need less pages not more"). A group is one menu link and one row of tabs on top of each of its pages.
// A tab is either `?tab=<key>` on one address (pages that showed the same records from different angles, merged into one
// page; the old addresses redirect there) or a page of its own (separate tools on one subject, grouped; each keeps its
// address). The first tab is where the menu link goes.
export interface HubTab { href: string; label: string; /** staff portal: the functions that may open the page, space separated (the tab row shows a person only theirs) */ fns?: string }
export interface Hub { key: string; label: string; tabs: HubTab[] }

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
  { key: 'numbers', label: 'My numbers', tabs: [{ href: '/staff/scorecard', label: 'Scorecard', fns: 'cs fleet finance sales' }, { href: '/staff/my-sales', label: 'My sales', fns: 'cs fleet finance sales' }] },
  { key: 'field-pay', label: 'My pay', tabs: [{ href: '/staff/field/hours', label: 'My hours', fns: 'field' }, { href: '/staff/field/sales', label: 'My sales', fns: 'field' }, { href: '/staff/field/referrals', label: 'Referrals', fns: 'field' }] }
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
