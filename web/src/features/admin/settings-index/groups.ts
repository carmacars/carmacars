// The Settings page in sections (r27, the owner on November 1, 2026: "There's way too many tabs"): the menu had 20 settings
// links and the page had 34 cards in one list. Now the menu has one Settings link and the page has six sections with an
// anchor each and a search box. Every settings page is in exactly one section (groups.test.ts).
export interface SettingsGroup { id: string; title: string; about: string; keys: string[]; extra?: Array<{ href: string; title: string; about: string }> }

export const SETTINGS_GROUPS: SettingsGroup[] = [
  { id: 'website', title: 'Website', about: 'What visitors see and the extras that bring them back',
    keys: ['site', 'content', 'vehicle-pages', 'sample-photos', 'search', 'phone-gate', 'discount-games', 'rewards', 'guides'] },
  { id: 'rentals', title: 'Rentals and rules', about: 'Timings, fees, classes, delivery and the extras renters buy',
    keys: ['program', 'fees', 'deposits', 'km', 'classes', 'class-rules', 'airports', 'coverage', 'addons', 'promo-codes', 'forms'] },
  { id: 'payments', title: 'Payments and coverage', about: 'The card reader, credit card coverage and insurers',
    keys: ['card-reader', 'card-coverage', 'coverage-affiliate', 'insurers'] },
  { id: 'messages', title: 'Messages and reviews', about: 'Emails, texts, phone contacts, review requests and social posts',
    keys: ['email', 'text-alerts', 'quick-replies', 'quo-contacts', 'reviews', 'meta-publishing'] },
  { id: 'cars', title: 'Cars and partners', about: 'Service intervals and the partner companies we share cars with',
    keys: ['maintenance', 'partners'] },
  { id: 'team', title: 'Team and records', about: 'Staff, your own alerts, what the plans use, and the logs',
    keys: ['staff', 'profile', 'usage'],
    extra: [{ href: '/admin/alerts', title: 'Alerts', about: 'Every alert for you, phone alerts, quiet hours, focus mode and which alerts staff get' },
      { href: '/admin/logs', title: 'Logs', about: 'Emails sent, blocked addresses, every change and every look at personal data' }] }
];

export interface SettingsCard { href: string; title: string; about: string }

/** The six sections with their cards, from the settings pages' names and descriptions (app/admin/settings/sections.ts). */
export function settingsSections(sections: Array<[string, string, string]>): Array<{ id: string; title: string; about: string; cards: SettingsCard[] }> {
  const by = new Map(sections.map(([k, title, about]) => [k, { href: `/admin/settings/${k}`, title, about }]));
  return SETTINGS_GROUPS.map((g) => ({ id: g.id, title: g.title, about: g.about,
    cards: [...g.keys.flatMap((k) => (by.has(k) ? [by.get(k)!] : [])), ...(g.extra ?? [])] }));
}

/** Does a card match what was typed (every word, in its name or description, any case)? */
export function cardMatches(c: SettingsCard, q: string): boolean {
  const words = q.toLowerCase().split(/\s+/).filter(Boolean);
  const text = `${c.title} ${c.about}`.toLowerCase();
  return words.every((w) => text.includes(w));
}
