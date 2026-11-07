import { GROUPS } from './AdminNav';
import { ADMIN_HUBS, ADMIN_SECTIONS, pagesOf } from './hubs';
import { VISITOR_TABS } from '@/features/visitors/tabs';
import { SECTIONS } from '@/app/admin/settings/sections';

// Ctrl+K reaches every page of the menu, every tab of a page group and every settings page (the menu lists none of them)
// r27 consolidation: the groups' actions (Add a car, Rates for many cars...) and the Visitors page's tabs too
export const JUMP = [...GROUPS, ...ADMIN_HUBS.map((h) => ({ key: `hub-${h.key}`, label: h.label, links: pagesOf(h).map((t) => ({ href: t.href, label: `${h.label}: ${t.label}` })) })),
  { key: 'visitors', label: 'Visitors', links: VISITOR_TABS.admin.map((t) => ({ href: t.href, label: `Visitors: ${t.label}` })) },
  { key: 'actions', label: 'Actions', links: [{ href: '/admin/offers/new', label: 'Send an offer' }, { href: '/admin/bookings/new', label: 'Add a rental' }] },
  // the sections' own pages (Maintenance, Applications, Investors, Tolls and tickets, Settings)
  ...ADMIN_SECTIONS.map((x) => ({ key: `sec-${x.key}`, label: x.label, links: x.items.flatMap((i) => (typeof i === 'string' ? [] : [{ href: i.href, label: i.label }])) })),
  { key: 'settings-all', label: 'Settings', links: SECTIONS.map(([k, title]) => ({ href: `/admin/settings/${k}`, label: title })) }];
