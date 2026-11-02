// The pages in the revamped look (r27, the owner on November 1, 2026: "a lot of other admin portal stuff [needs a revamp].
// And this should edit the staff's corresponding versions of these portals too"): the Now view's design language
// (bookings-now, migration 0330) on every page of Money, Settings, Problems, Cars, People, Marketing and Customers, and on
// their staff versions. One list for both portals, so admin and staff stay in sync. The pages other branches own this week
// (Bookings, Requests, Calendar, Visitors, To do, Overview, Staff tasks, Live chat, My sales) are not in it.
export const REVAMP_ADMIN: string[] = [
  '/admin/money', '/admin/owner-money', '/admin/invoices', '/admin/statements', '/admin/payouts', '/admin/debits', '/admin/payments', '/admin/reconciliation',
  '/admin/insurers', '/admin/insurer-invoices', '/admin/reports', '/admin/expenses', '/admin/tolls',
  '/admin/damages', '/admin/incidents', '/admin/logs', '/admin/messages', '/admin/audit', '/admin/alerts', '/admin/settings',
  '/admin/vehicles', '/admin/listings', '/admin/maintenance', '/admin/calendar-sync', '/admin/similar-cars',
  '/admin/applications', '/admin/owners', '/admin/owner-forms', '/admin/partners', '/admin/referral-partners', '/admin/renters', '/admin/leads',
  '/admin/academy', '/admin/hiring', '/admin/portals', '/admin/investors', '/admin/marketing', '/admin/reviews'
];
export const REVAMP_STAFF: string[] = [
  '/staff/money', '/staff/payments', '/staff/reconciliation', '/staff/tolls', '/staff/turo', '/staff/maintenance',
  '/staff/fleet', '/staff/field-hours', '/staff/checks', '/staff/reviews', '/staff/listings', '/staff/similar-cars', '/staff/calendar-sync', '/staff/addons', '/staff/cars', '/staff/card-coverage',
  '/staff/owners', '/staff/owner-forms', '/staff/owner-pipeline', '/staff/leads', '/staff/renters', '/staff/messages', '/staff/review-requests', '/staff/game-leads',
  '/staff/academy', '/staff/scorecard', '/staff/profile', '/staff/documents', '/staff/field'
];

/** Is this page in the revamped look (the address or a page under it)? */
export function revamped(list: string[], path: string): boolean {
  return list.some((p) => path === p || path.startsWith(`${p}/`));
}
