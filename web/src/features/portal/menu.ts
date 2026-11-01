import type { MenuLink, PageTab } from '../portal-nav/tabs.ts';

// The renter portal's menu (r27 portals): four links. Trips is the home (the trip that needs you now, first); Account
// holds the profile and the notifications (two links for one job before). Pure: PortalNav and the unit tests read it.
export const RENTER_MENU: MenuLink[] = [
  { href: '/account', label: 'Trips', icon: 'car', exact: true, also: ['/account/bookings'] },
  { href: '/account/documents', label: 'Documents', icon: 'doc' },
  { href: '/account/rewards', label: 'Rewards', icon: 'star' },
  { href: '/account/profile', label: 'Account', icon: 'user', count: 'unread', also: ['/account/notifications'] }
];

/** Account: the profile (details, sign-in, card, drivers) and the notifications (messages and email preferences). */
export const RENTER_ACCOUNT_TABS: PageTab[] = [
  { key: 'profile', href: '/account/profile', label: 'Profile' },
  { key: 'notifications', href: '/account/profile?tab=notifications', label: 'Notifications' }
];

/** The old addresses: where each now lives (the merged page and its tab). */
export const RENTER_MOVED: Record<string, [string, string | null]> = {
  '/account/notifications': ['/account/profile', 'notifications'],
  '/account/bookings': ['/account', null]
};
