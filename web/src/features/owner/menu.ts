import type { MenuLink, PageTab } from '../portal-nav/tabs.ts';

// The owner portal's menu (r27 portals): five links, the same for a partner rental company (its Money has no
// invoices). Cars holds the cars and their bookings; Money the statements, payouts and invoices on one page; Account the
// profile, banking and notifications on one page. Pure: OwnerNav and the unit tests read it.
export const OWNER_MENU: MenuLink[] = [
  { href: '/owner', label: 'Home', icon: 'home', exact: true },
  { href: '/owner/vehicles', label: 'Cars', icon: 'car', also: ['/owner/bookings'] },
  { href: '/owner/money', label: 'Money', icon: 'card', also: ['/owner/statements', '/owner/payouts', '/owner/invoices'] },
  { href: '/owner/documents', label: 'Documents', icon: 'doc', also: ['/owner/sign', '/owner/review', '/owner/partner-agreement'] },
  { href: '/owner/account', label: 'Account', icon: 'user', count: 'unread', also: ['/owner/profile', '/owner/banking', '/owner/notifications'] }
];

export const OWNER_CARS_TABS: PageTab[] = [
  { key: 'cars', href: '/owner/vehicles', label: 'Your cars' },
  { key: 'bookings', href: '/owner/vehicles?tab=bookings', label: 'Bookings' }
];
/** Money: what you earned (statements), what we sent (payouts), what you owe (invoices; a partner pays no fees). */
export const OWNER_MONEY_TABS: PageTab[] = [
  { key: 'statements', href: '/owner/money', label: 'Statements' },
  { key: 'payouts', href: '/owner/money?tab=payouts', label: 'Payouts' },
  { key: 'invoices', href: '/owner/money?tab=invoices', label: 'Invoices', not: 'partner' }
];
export const OWNER_ACCOUNT_TABS: PageTab[] = [
  { key: 'profile', href: '/owner/account', label: 'Profile' },
  { key: 'banking', href: '/owner/account?tab=banking', label: 'Banking' },
  { key: 'notifications', href: '/owner/account?tab=notifications', label: 'Notifications' }
];

export const OWNER_MOVED: Record<string, [string, string | null]> = {
  '/owner/bookings': ['/owner/vehicles', 'bookings'],
  '/owner/statements': ['/owner/money', 'statements'],
  '/owner/payouts': ['/owner/money', 'payouts'],
  '/owner/invoices': ['/owner/money', 'invoices'],
  '/owner/profile': ['/owner/account', 'profile'],
  '/owner/banking': ['/owner/account', 'banking'],
  '/owner/notifications': ['/owner/account', 'notifications']
};
