import { Suspense } from 'react';
import { GroupNav, type NavGroup, type NavLink } from './GroupNav';
import { ADMIN_HUBS, hubLink } from './hubs';

// a page group's menu link (r27): its first tab, its name, its other addresses
const hub = (k: string, key?: string): NavLink => ({ ...hubLink(ADMIN_HUBS, k), ...(key ? { key } : {}) });

// The admin portal's navigation (October 16, 2026: the owner found 31 links "super difficult to navigate"; October 23,
// 2026: six groups, the long ones in labelled parts; October 25, 2026: Marketing, migration 0167): seven groups with plain
// names, every page still two taps away. November 1, 2026 (r27, "We need less pages not more"): 78 links became 34; pages
// on one subject are one link and one row of tabs (hubs.ts), and the Settings menu is the Settings page. Old addresses
// redirect to their tab, so links in emails and bookmarks work.
export const GROUPS: NavGroup[] = [
  { key: 'today', label: 'Today', links: [
    { href: '/admin', label: 'To do', key: 't' }, { href: '/admin/overview', label: 'Overview' }, { href: '/admin/tasks', label: 'Staff tasks', key: 'k' }, { href: '/admin/live', label: 'Live visitors' }, { href: '/admin/live-map', label: 'Live map' }, { href: '/admin/live/history', label: 'Visitor history' }] },
  { key: 'bookings', label: 'Bookings', links: [
    { href: '/admin/requests', label: 'Requests', key: 'r', section: 'Trips' }, { href: '/admin/bookings', label: 'Bookings', key: 'b' }, { href: '/admin/calendar', label: 'Calendar', key: 'c' },
    { href: '/admin/offers/new', label: 'Send an offer' }, { href: '/admin/bookings/new', label: 'Add a rental' }, { href: '/admin/chauffeur', label: 'Chauffeur' },
    { href: '/admin/chat', label: 'Live chat', section: 'Customers' }, { href: '/admin/reviews', label: 'Reviews' },
    { ...hub('problems'), section: 'Problems' }] },
  { key: 'cars', label: 'Cars', links: [hub('vehicles', 'v'), hub('listings', 'l'), { href: '/admin/maintenance', label: 'Maintenance' }] },
  { key: 'people', label: 'People', links: [
    { href: '/admin/applications', label: 'Applications', key: 'a' }, hub('owners', 'o'), hub('partners'), hub('renters'), hub('team'), { href: '/admin/investors', label: 'Investors' }] },
  { key: 'marketing', label: 'Marketing', links: [hub('ads'), hub('recruit')] },
  { key: 'money', label: 'Money', links: [
    hub('payments', 'm'), hub('owner-money'), { href: '/admin/tolls', label: 'Tolls and tickets' }, hub('company'), hub('insurers'), hub('staff-pay')] },
  { key: 'settings', label: 'Settings', links: [{ href: '/admin/settings', label: 'Settings', key: 's' }, hub('logs')] }
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
