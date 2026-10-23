import { Suspense } from 'react';
import { GroupNav, type NavGroup } from './GroupNav';

// The admin portal's navigation (October 16, 2026: the owner found 31 links "super difficult to navigate"; October 23,
// 2026: six groups, the long ones in labelled parts): six groups with plain names, every page still two taps away. The
// pages keep their addresses, so links in emails and bookmarks work.
export const GROUPS: NavGroup[] = [
  { key: 'today', label: 'Today', links: [
    { href: '/admin', label: 'To do', key: 't' }, { href: '/admin/overview', label: 'Overview' }, { href: '/admin/tasks', label: 'Staff tasks', key: 'k' }, { href: '/admin/live', label: 'Live visitors' }] },
  { key: 'bookings', label: 'Bookings', links: [
    { href: '/admin/requests', label: 'Requests', key: 'r', section: 'Trips' }, { href: '/admin/bookings', label: 'Bookings', key: 'b' }, { href: '/admin/calendar', label: 'Calendar', key: 'c' },
    { href: '/admin/bookings/new', label: 'Add a rental' }, { href: '/admin/chauffeur', label: 'Chauffeur' },
    { href: '/admin/chat', label: 'Live chat', section: 'Customers' }, { href: '/admin/leads', label: 'Renter leads' }, { href: '/admin/reviews', label: 'Reviews' },
    { href: '/admin/damages', label: 'Damage', section: 'Problems' }, { href: '/admin/incidents', label: 'Incidents and claims' }] },
  { key: 'cars', label: 'Cars', links: [
    { href: '/admin/vehicles', label: 'Vehicles', key: 'v' }, { href: '/admin/listings', label: 'Listings', key: 'l' }, { href: '/admin/maintenance', label: 'Maintenance' },
    { href: '/admin/vehicles/bulk-rates', label: 'Rates for many cars' }, { href: '/admin/calendar-sync', label: 'Calendar sync' }, { href: '/admin/similar-cars', label: 'Similar cars' },
    { href: '/admin/vehicles/samples', label: 'Retire or delete' }] },
  { key: 'people', label: 'People', links: [
    { href: '/admin/applications', label: 'Applications', key: 'a', section: 'Owners and partners' }, { href: '/admin/owners', label: 'Owners', key: 'o' }, { href: '/admin/owners/add-car', label: 'Add a car for an owner' },
    { href: '/admin/partners', label: 'Partners' }, { href: '/admin/owner-forms', label: 'Owner forms' }, { href: '/admin/owners?view=checklist', label: 'Paid and signed' },
    { href: '/admin/renters', label: 'Renters', section: 'Renters, staff and investors' }, { href: '/admin/settings/staff', label: 'Staff' }, { href: '/admin/investors', label: 'Investors' },
    { href: '/admin/portals', label: 'Portals and view as' }] },
  { key: 'money', label: 'Money', links: [
    { href: '/admin/invoices', label: 'Owner invoices', section: 'Owners' }, { href: '/admin/debits', label: 'Owner debits' }, { href: '/admin/statements', label: 'Owner statements' }, { href: '/admin/payouts', label: 'Payouts' },
    { href: '/admin/money', label: 'Payments and refunds', key: 'm', section: 'Renters' }, { href: '/admin/tolls', label: 'Tolls and tickets' },
    { href: '/admin/reports', label: 'Company statements', section: 'Company' }, { href: '/admin/reconciliation', label: 'Reconciliation' }, { href: '/admin/expenses', label: 'Expenses' },
    { href: '/admin/insurer-invoices', label: 'Insurer invoices' }, { href: '/admin/money/commissions', label: 'Staff commissions' }] },
  { key: 'settings', label: 'Settings', links: [
    { href: '/admin/settings', label: 'All settings', key: 's' },
    { href: '/admin/settings/site', label: 'Site', section: 'Website' }, { href: '/admin/settings/vehicle-pages', label: 'Vehicle pages' }, { href: '/admin/settings/sample-photos', label: 'Sample photos' },
    { href: '/admin/settings/addons', label: 'Add-ons' }, { href: '/admin/settings/discount-games', label: 'Discount games' }, { href: '/admin/settings/guides', label: 'Guides' },
    { href: '/admin/settings/program', label: 'Program', section: 'Rules' }, { href: '/admin/settings/forms', label: 'Forms' }, { href: '/admin/settings/maintenance', label: 'Maintenance' }, { href: '/admin/settings/email', label: 'Emails' },
    { href: '/admin/messages', label: 'Email log', section: 'Records' }, { href: '/admin/audit', label: 'Audit log' }] }
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
