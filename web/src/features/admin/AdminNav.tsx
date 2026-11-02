import { Suspense } from 'react';
import { GroupNav, type NavGroup, type NavLink } from './GroupNav';
import { ADMIN_HUBS, ADMIN_SECTIONS, hubLink, sectionLink } from './hubs';

// a page group's menu link (r27): its first tab, its name, its other addresses
const hub = (k: string, key?: string): NavLink => ({ ...hubLink(ADMIN_HUBS, k), ...(key ? { key } : {}) });
// a section's menu link (r27, second cut): one link for a whole area, its pages in a row on top
const sec = (k: string, key?: string): NavLink => ({ ...sectionLink(ADMIN_SECTIONS, ADMIN_HUBS, k)!, ...(key ? { key } : {}) });

// The admin portal's navigation (October 16, 2026: the owner found 31 links "super difficult to navigate"; October 23,
// 2026: six groups, the long ones in labelled parts; October 25, 2026: Marketing, migration 0167): seven groups with plain
// names, every page still two taps away. November 1, 2026 (r27, "We need less pages not more", then "reduce ... even
// further"): 78 links became 20. Cars, People, Marketing, Money and Settings are one link each: a row of their pages on
// top, and a second row of tabs where a page is a group (hubs.ts). Ctrl+K reaches every page and tab. Old addresses
// redirect to their tab, so links in emails and bookmarks work. Release 26 (the owner: "We need less pages not
// more"): Bookings opens on Now, Chauffeur is a tab of Requests and offers, and Send an offer and Add a rental are
// buttons on Bookings and Today. r27 consolidation (November 2, 2026): Live chat is a tab of Visitors (Live now, Chat,
// History); every area's row is at most five pages, actions are buttons on their page (hubs.ts).
export const GROUPS: NavGroup[] = [
  { key: 'today', label: 'Today', links: [
    { href: '/admin', label: 'To do', key: 't' }, { href: '/admin/overview', label: 'Overview' }, { href: '/admin/tasks', label: 'Staff tasks', key: 'k' }, { href: '/admin/visitors', label: 'Visitors', key: 'l', also: ['/admin/chat', '/admin/live'] }] },
  { key: 'bookings', label: 'Bookings', links: [
    { href: '/admin/bookings', label: 'Bookings', key: 'b', section: 'Trips' }, { href: '/admin/requests', label: 'Requests and offers', key: 'r' }, { href: '/admin/calendar', label: 'Calendar', key: 'c' },
    { href: '/admin/reviews', label: 'Reviews', section: 'Customers' },
    { ...hub('problems'), section: 'Problems' }] },
  { key: 'cars', label: 'Cars', links: [sec('cars', 'v')] },
  { key: 'people', label: 'People', links: [sec('people', 'o')] },
  { key: 'marketing', label: 'Marketing', links: [sec('marketing')] },
  { key: 'money', label: 'Money', links: [sec('money', 'm')] },
  { key: 'settings', label: 'Settings', links: [sec('settings', 's')] }
];

/** Every page the navigation reaches (kept for the crawl and the guide's quick reference). */
export const NAV: Array<[string, Array<[string, string, string?]>]> = GROUPS.map((g) => [g.label, g.links.map((l) => [l.href, l.label, l.key] as [string, string, string?])]);

export function AdminSearch() {
  return (
    <form className="gn-search" action="/admin/search" role="search" data-testid="admin-search">
      <label className="vh" htmlFor="gn-q">Search bookings, cars, owners, partners and renters</label>
      <input className="input" id="gn-q" name="q" type="search" placeholder="Search: booking, plate, VIN, name, email" data-shortcut="/" autoComplete="off" />
      <button className="btn btn--ghost btn--sm" type="submit">Search</button>
    </form>
  );
}

export function AdminNav({ counts }: { counts: Record<string, number> }) {
  return (
    <Suspense fallback={<nav className="gn" aria-label="Admin" />}>
      <GroupNav groups={GROUPS} counts={counts} label="Admin" testId="admin-nav" />
    </Suspense>
  );
}
