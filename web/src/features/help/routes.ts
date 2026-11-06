// The "Stuck?" help map (migration 0510): for every page of the site (web/src/app), the guide chapter that explains it and
// the Academy section that teaches it, by the route and, where a page has tabs, the tab. The unit test fails when a page has
// no entry, a chapter is not in docs/guides/content, or a section is not in the Academy. Pages outside the portals and the
// checkout, payment and signing steps are marked off: the prompt never shows there.
// Pure (no I/O): the unit tests run it in Node.

export type HelpPortal = 'admin' | 'va' | 'field' | 'owner' | 'renter' | 'investor';
export interface HelpEntry { portal: HelpPortal; guide: string; /** path/section of the Academy */ lesson?: string }
export type HelpRow = HelpEntry | { off: 'public' | 'payment' | 'signing' | 'guide' };
type Spec = string | [guide: string, lesson?: string, tabs?: Record<string, [string, string?]>];

export const GUIDE_PATH: Record<HelpPortal, string> = { renter: '/account/guide', owner: '/owner/guide', admin: '/admin/guide', va: '/staff/guide', field: '/staff/field/guide', investor: '/investor/guide' };

// ---------------------------------------------------------------- Admin (/admin), guide docs/guides/content/admin.json
const ADMIN: Record<string, Spec> = {
  '': ['getting-around-admin', 'admin/admin-team'],
  academy: ['academy', 'admin/admin-team'], alerts: ['text-alerts-email-text-or-both'], applications: ['owners-and-onboarding', 'admin/owner-recruitment'],
  audit: ['people-and-access', 'admin/admin-decisions'], bookings: ['requests-offers-and-bookings', 'admin/prices-and-deposits'], 'bookings/[number]/sign-now': 'signing',
  calendar: ['calendars', 'admin/trip-rules'], 'calendar-sync': ['calendar-sync-with-turo-and-other-platforms'], chat: ['live-visitors-and-live-chat'],
  chauffeur: ['chauffeur-service'], damages: ['tolls-and-tickets', 'admin/trip-rules'], debits: ['owner-money', 'admin/admin-decisions'], documents: ['requests-offers-and-bookings', 'cs/documents-and-signing'],
  expenses: ['owner-money'], guide: 'guide', hiring: ['hiring', 'admin/admin-team'], incidents: ['tolls-and-tickets', 'admin/trip-rules'],
  'insurer-invoices': ['insurance-replacements-rates-and-billing', 'admin/insurer-billed-rentals'], insurers: ['insurance-replacements-rates-and-billing', 'admin/insurer-billed-rentals'],
  investors: ['the-investor-deck'], invoices: ['owner-money'], leads: ['discount-games-and-leads', 'admin/owner-recruitment'], listings: ['fleet-and-listings', 'fleet/fleet-cars'],
  live: ['live-visitors-and-live-chat'], 'live-map': ['live-visitors-and-live-chat'], logs: ['email-backups-and-site-health'], maintenance: ['maintenance-and-service', 'fleet/fleet-cars'],
  marketing: ['advertising-and-owner-recruitment', 'admin/owner-recruitment'], 'marketing/marketplace': ['advertising-and-owner-recruitment', 'sales_remote/marketplace-with-claude'],
  messages: ['texts-and-calls-the-quo-phone-line'], money: ['owner-money', 'finance/finance-deposits-refunds', { refunds: ['owner-money', 'finance/finance-deposits-refunds'] }],
  'no-access': ['start-here'], offers: ['requests-offers-and-bookings', 'admin/prices-and-deposits'], overview: ['getting-around-admin'], 'owner-forms': ['owners-and-onboarding'],
  'owner-money': ['owner-money', 'finance/finance-tolls-owners'], owners: ['owners-and-onboarding', 'admin/owner-recruitment'], partners: ['partners-company-cars-and-rentals-added-by-hand'],
  payments: ['owner-money', 'finance/finance-deposits-refunds'], payouts: ['owner-money', 'finance/finance-tolls-owners'], portals: ['people-and-access'],
  reconciliation: ['owner-money', 'finance/finance-deposits-refunds'], 'referral-partners': ['referral-partners-and-rentalcoverage'], renters: ['requests-offers-and-bookings', 'cs/cs-requests'],
  reports: ['owner-money'], requests: ['requests-offers-and-bookings', 'cs/cs-requests'], reviews: ['requests-offers-and-bookings', 'cs/cs-requests'], search: ['getting-around-admin'],
  settings: ['settings', 'admin/admin-decisions'], 'settings/usage': ['usage-and-paid-usage'], 'settings/guides': ['settings'], 'similar-cars': ['fleet-and-listings', 'fleet/fleet-cars'],
  staff: ['people-and-access', 'admin/admin-team'], statements: ['owner-money', 'finance/finance-tolls-owners'], tasks: ['getting-around-admin'], tolls: ['tolls-and-tickets', 'finance/finance-tolls-owners'],
  vehicles: ['fleet-and-listings', 'fleet/fleet-cars'], visitors: ['live-visitors-and-live-chat', undefined, { history: ['live-visitors-and-live-chat'] }]
};

// ---------------------------------------------------------------- Staff (/staff), guide va.json; Field work (/staff/field), field.json
const STAFF: Record<string, Spec> = {
  '': ['your-workday', 'cs/cs-requests'], academy: ['academy'], addons: ['add-ons'], bookings: ['customer-service', 'cs/prices-and-deposits'], 'bookings/[number]/sign-now': 'signing',
  calendar: ['shared-tools', 'cs/trip-rules'], 'calendar-sync': ['fleet', 'fleet/fleet-cars'], 'card-coverage': ['customer-service', 'cs/coverage-and-drivers'], cars: ['shared-tools'],
  chat: ['live-visitors-and-live-chat'], chauffeur: ['chauffeur-requests'], checks: ['fleet', 'fleet/fleet-cars'], documents: ['customer-service', 'cs/documents-and-signing'],
  'field-hours': ['fleet', 'fleet/fleet-field-jobs'], fleet: ['fleet', 'fleet/fleet-field-jobs'], 'game-leads': ['discount-game-leads', 'sales_remote/sales-requests-and-quotes'], guide: 'guide',
  leads: ['sales', 'sales_remote/sales-requests-and-quotes'], listings: ['fleet', 'fleet/fleet-cars'], live: ['live-visitors-and-live-chat'], maintenance: ['car-maintenance', 'fleet/fleet-cars'],
  marketing: ['marketing-on-facebook-marketplace', 'sales_remote/marketplace-with-claude'], marketplace: ['marketing-on-facebook-marketplace', 'sales_remote/marketplace-with-claude'],
  messages: ['texts-and-calls'], money: ['finance', 'finance/finance-deposits-refunds'], 'my-sales': ['commissions', 'sales_remote/commission'], 'no-access': ['start-here'],
  offers: ['sales', 'sales_remote/sales-requests-and-quotes'], 'owner-forms': ['sales', 'sales_remote/owner-recruitment'], 'owner-money': ['finance', 'finance/finance-tolls-owners'],
  'owner-pipeline': ['sales', 'sales_remote/owner-recruitment'], owners: ['sales', 'sales_remote/owner-recruitment'], payments: ['finance', 'finance/finance-deposits-refunds'],
  profile: ['start-here'], quotes: ['sales', 'sales_remote/sales-requests-and-quotes'], reconciliation: ['finance', 'finance/finance-deposits-refunds'], renters: ['customer-service', 'cs/cs-requests'],
  requests: ['customer-service', 'cs/cs-requests'], review: ['customer-service', 'cs/documents-and-signing'],
  'review-requests': ['customer-service', 'cs/cs-requests'], reviews: ['fleet', 'fleet/fleet-cars'], scorecard: ['your-workday'], sign: 'signing', 'similar-cars': ['shared-tools'],
  switch: ['your-workday'], tasks: ['your-workday'], today: ['your-workday'], tolls: ['finance', 'finance/finance-tolls-owners'], turo: ['finance', 'finance/finance-deposits-refunds'],
  vehicles: ['fleet', 'fleet/fleet-cars'], verify: ['customer-service', 'cs/documents-and-signing'], visitors: ['live-visitors-and-live-chat']
};
const FIELD: Record<string, Spec> = {
  '': ['my-jobs', 'field/field-handover'], guide: 'guide', hours: ['my-hours-and-pay'], jobs: ['my-jobs', 'field/field-handover'], 'jobs/[id]/sign-now': 'signing',
  map: ['my-jobs', 'field/field-handover'], now: ['my-jobs', 'field/field-return-and-cash'], profile: ['report-rentals-referrals-and-profile'], referrals: ['report-rentals-referrals-and-profile'],
  'rentals/new': ['report-rentals-referrals-and-profile', 'field/trip-rules'], report: ['report-rentals-referrals-and-profile'], sales: ['report-rentals-referrals-and-profile'], sign: 'signing'
};

// ---------------------------------------------------------------- Owners, renters, investors (no Academy)
const OWNER: Record<string, Spec> = {
  '': ['home-and-your-vehicles'], account: ['notices-profile-and-leaving'], banking: ['fees-payments-and-payouts'], bookings: ['bookings-and-your-own-use'], documents: ['documents-and-forms'],
  guide: 'guide', invoices: ['fees-payments-and-payouts'], money: ['fees-payments-and-payouts'], 'not-an-owner': ['apply-and-get-your-car-listed'], notifications: ['notices-profile-and-leaving'],
  'partner-agreement': 'signing', payouts: ['fees-payments-and-payouts'], profile: ['notices-profile-and-leaving'], review: ['apply-and-get-your-car-listed'], sign: 'signing',
  statements: ['fees-payments-and-payouts'], vehicles: ['home-and-your-vehicles']
};
const RENTER: Record<string, Spec> = {
  '': ['start-here'], bookings: ['before-pickup'], 'bookings/[number]': ['before-pickup'], 'bookings/[number]/pay': 'payment', 'bookings/[number]/addons/pay': 'payment',
  'bookings/[number]/sign': 'signing', 'bookings/[number]/offer': 'payment', 'bookings/[number]/extend': 'payment', 'bookings/[number]/cancel': ['your-offer'],
  'bookings/[number]/change': ['your-offer'], 'bookings/[number]/verify': ['sign-and-pay'], 'bookings/[number]/walkthrough': ['during-your-trip'],
  'bookings/[number]/condition-report': ['during-your-trip'], 'bookings/[number]/returned': ['during-your-trip'], 'bookings/[number]/review': ['after-your-trip'], documents: ['after-your-trip'], guide: 'guide',
  notifications: ['start-here'], profile: ['start-here'], rewards: ['after-your-trip']
};
const INVESTOR: Record<string, Spec> = {
  '': ['your-investments'], deck: ['the-investor-deck'], documents: ['statements'], guide: 'guide', model: ['how-your-returns-work'], 'no-access': ['start-here'],
  profile: ['profile-and-notices'], sign: 'signing', statements: ['statements']
};

// ---------------------------------------------------------------- outside the portals: never
const PUBLIC = ['', 'about', 'body-shop', 'book', 'buy', 'cancellation-policy', 'car-rental', 'careers', 'cars', 'chauffeur', 'choose-portal', 'contact', 'create-account',
  'credit-card-rental-coverage', 'delivery', 'detailing', 'faq', 'guides', 'how-it-works', 'investors', 'link-expired', 'list-your-car', 'makes', 'my-request', 'partners',
  'place-data', 'places', 'privacy', 'read-only', 'rent', 'requirements', 'reset-password', 'returned', 'review', 'sign-in', 't', 'terms', 'two-step', 'unsubscribe', 'update-password', 'verify'];

type Row = { key: string[]; row: HelpRow & { tabs?: Record<string, HelpEntry> } };
const seg = (k: string) => (k ? k.split('/') : []);
function rows(base: string, portal: HelpPortal, m: Record<string, Spec>): Row[] {
  return Object.entries(m).map(([k, v]) => {
    const key = [...seg(base), ...seg(k)];
    if (typeof v === 'string') return { key, row: { off: v as 'payment' | 'signing' | 'guide' } };
    const [guide, lesson, tabs] = v;
    return { key, row: { portal, guide, ...(lesson ? { lesson } : {}), ...(tabs ? { tabs: Object.fromEntries(Object.entries(tabs).map(([t, [g, l]]) => [t, { portal, guide: g, ...(l ? { lesson: l } : {}) }])) } : {}) } };
  });
}
export const HELP_ROWS: Row[] = [
  ...rows('admin', 'admin', ADMIN), ...rows('staff', 'va', STAFF), ...rows('staff/field', 'field', FIELD), ...rows('owner', 'owner', OWNER),
  ...rows('account', 'renter', RENTER), ...rows('investor', 'investor', INVESTOR),
  // the Call button of a phone alert (0466): a hand-off to the dialer, signed in, nothing to get stuck on
  { key: ['alerts', 'call'], row: { off: 'public' } },
  { key: ['pay'], row: { off: 'payment' } }, { key: ['oauth', 'authorize'], row: { off: 'signing' } }, { key: ['sign'], row: { off: 'signing' } }, { key: ['sign-document'], row: { off: 'signing' } },
  ...PUBLIC.map((k) => ({ key: seg(k), row: { off: 'public' as const } }))
];

const dyn = (s: string) => /^\[.*\]$/.test(s);
/** The row of a path: the longest entry whose segments match (a [param] matches any segment); the bare "/" only matches itself. */
export function helpRow(pathname: string): { pattern: string; row: Row['row'] } | null {
  const p = seg(pathname.replace(/^\/+|\/+$/g, ''));
  let best: Row | null = null;
  for (const r of HELP_ROWS) {
    if (r.key.length > p.length || (r.key.length === 0 && p.length > 0)) continue;
    if (r.key.every((k, i) => k === p[i] || dyn(k))) if (!best || r.key.length > best.key.length) best = r;
  }
  if (!best) return null;
  // the route as a pattern: the matched entry's segments, then the rest of the path with ids replaced
  const rest = p.slice(best.key.length).map((x) => (/^[0-9a-f-]{20,}$|^\d+$|^[A-Z]{2,}-?[0-9A-Z]+$/.test(x) ? '[id]' : x));
  return { pattern: '/' + [...best.key, ...rest].join('/'), row: best.row };
}

/** The help for a page and tab, or null where the prompt never shows. */
export function helpFor(pathname: string, tab?: string | null): (HelpEntry & { pattern: string; guideHref: string; lessonHref: string | null }) | null {
  const r = helpRow(pathname);
  if (!r || 'off' in r.row) return null;
  const e = (tab && r.row.tabs?.[tab]) || r.row;
  const lessonHref = e.lesson ? (e.portal === 'admin' ? `/admin/academy/learn/${e.lesson}` : e.portal === 'va' || e.portal === 'field' ? `/staff/academy/${e.lesson}` : null) : null;
  return { portal: e.portal, guide: e.guide, ...(e.lesson ? { lesson: e.lesson } : {}), pattern: r.pattern, guideHref: `${GUIDE_PATH[e.portal]}#${e.guide}`, lessonHref };
}
