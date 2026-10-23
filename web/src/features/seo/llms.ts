// What AI answer engines read about CarmaCars (docs/changes/2026-10-23-ai-search.md): /llms.txt (the short map),
// /llms-full.txt (the facts in full), the /about facts page and the answer block at the top of the key pages. Pure: the
// facts come from the database (facts.ts, site settings, program settings, the real cars, the content blocks), never
// from copy typed here, so the answers change when the settings do. Sample cars never set a price.
import { money } from '../../lib/format.ts';

export interface FactLink { name: string; path: string; note?: string }
export interface EntityFacts {
  name: string; url: string; tagline: string | null;
  phone: string | null; phoneE164: string | null; whatsapp: string | null; email: string | null; roadside: string | null;
  address: string; city: string; region: string; serviceArea: string; hours: string | null; reply: string | null;
  /** the day the facts last changed (a real car, a landing page or a guide), YYYY-MM-DD; null when nothing is dated */
  updated: string | null;
  fleet: { realCars: number; classes: Array<{ label: string; count: number; fromDailyCents: number }>; fromDailyCents: number | null; fromWeeklyCents: number | null;
    fromMonthlyCents: number | null; deliveryFromCents: number | null };
  drivers: { minAge: number; licence: string; youngBands: string };
  policy: { maxDays: number; weekFrom: number; deposits: string; hst: string; cancellation: string; noticeHours: string; depositLead: string };
  airports: string[];
  chauffeurFromCents: number | null; chauffeurMinHours: number | null;
  services: FactLink[]; locations: FactLink[]; uses: FactLink[]; guides: FactLink[]; pages: FactLink[];
  faq: Array<{ question: string; answer: string }>;
  profiles: string[];
}

const abs = (f: EntityFacts, p: string) => (/^https?:/.test(p) ? p : f.url + (p === '/' ? '/' : p));
const md = (s: string) => s.replace(/<[^>]+>/g, ' ').replace(/\s+/g, ' ').trim();
const link = (f: EntityFacts, l: FactLink) => `- [${l.name}](${abs(f, l.path)})${l.note ? `: ${md(l.note)}` : ''}`;

/** One sentence that answers "what is CarmaCars": who, what, where, from what price, how to book. */
export function summary(f: EntityFacts): string {
  const from = f.fleet.fromDailyCents ? ` from ${money(f.fleet.fromDailyCents)} a day` : '';
  return `${f.name} is a car rental company in ${f.city} at ${f.address}, renting cars${from}, picked up or delivered across ${f.serviceArea}`
    + `${f.airports.length ? ` and to ${f.airports.join(' and ')}` : ''}. Book online at ${f.url.replace(/^https?:\/\//, '')} with no payment to request${f.phone ? `, or call ${f.phone}` : ''}.`;
}

/** The rows of the answer block and the facts page: label and value, only the ones with a real value. */
export function keyFacts(f: EntityFacts): Array<[string, string]> {
  const rows: Array<[string, string | null]> = [
    ['What', `Car rental${f.chauffeurFromCents ? ', chauffeur service' : ''}, delivery to your door or the airport, insurance replacement rentals, detailing and body work`],
    ['Where', `${f.address}. Serving ${f.serviceArea}.`],
    ['Price from', f.fleet.fromDailyCents ? `${money(f.fleet.fromDailyCents)} a day${f.fleet.fromWeeklyCents ? `, ${money(f.fleet.fromWeeklyCents)} a week` : ''}, before HST (${f.policy.hst}). Each car shows its own rates and deposit.` : 'Each car shows its own rates and deposit.'],
    ['How to book', 'Choose a car and send a request online. No payment to request; you pay once we confirm the car and the price.'],
    ['Drivers', `${f.drivers.minAge} and up, ${f.drivers.licence}`],
    ['Hours', f.hours],
    ['Phone', f.phone]
  ];
  return rows.filter((r): r is [string, string] => !!r[1]);
}

/** /llms.txt (llmstxt.org): the name, the summary, the key facts and the pages that answer the most common questions. */
export function llmsTxt(f: EntityFacts): string {
  const out: string[] = [`# ${f.name}`, '', `> ${summary(f)}`, ''];
  out.push(...keyFacts(f).map(([k, v]) => `- ${k}: ${v}`));
  if (f.email) out.push(`- Email: ${f.email}`);
  if (f.updated) out.push(`- Facts updated: ${f.updated}`);
  out.push('', `The full facts in one file: ${abs(f, '/llms-full.txt')}. The facts page people can read: ${abs(f, '/about')}.`, '');
  out.push('## Services', '', ...f.services.map((l) => link(f, l)), '');
  if (f.locations.length) out.push('## Locations served', '', ...f.locations.map((l) => link(f, l)), '');
  if (f.uses.length) out.push('## Ways to rent', '', ...f.uses.map((l) => link(f, l)), '');
  out.push('## Policies and help', '', ...f.pages.map((l) => link(f, l)), '');
  if (f.guides.length) out.push('## Optional', '', ...f.guides.map((l) => link(f, l)), '');
  return out.join('\n').replace(/\n{3,}/g, '\n\n').trim() + '\n';
}

/** /llms-full.txt: every fact in plain Markdown, the questions answered in full. */
export function llmsFullTxt(f: EntityFacts): string {
  const out: string[] = [`# ${f.name}: the facts`, '', `> ${summary(f)}`, ''];
  if (f.updated) out.push(`Facts updated ${f.updated}. Prices are in Canadian dollars, before HST (${f.policy.hst}).`, '');
  out.push('## Contact', '', `- Name: ${f.name}`, `- Address: ${f.address}`, `- Website: ${f.url}/`);
  if (f.phone) out.push(`- Phone: ${f.phone}`);
  if (f.whatsapp) out.push(`- WhatsApp: ${f.whatsapp}`);
  if (f.email) out.push(`- Email: ${f.email}`);
  if (f.roadside) out.push(`- 24-hour incident and roadside line (renters on a trip): ${f.roadside}`);
  if (f.hours) out.push(`- Hours: ${f.hours}`);
  if (f.reply) out.push(`- Replies: ${f.reply}`);
  out.push(`- Area served: ${f.serviceArea}`);
  if (f.profiles.length) out.push(`- Profiles: ${f.profiles.join(', ')}`);
  out.push('', '## Fleet and prices', '');
  if (f.fleet.realCars) {
    out.push(`- Cars listed: ${f.fleet.realCars}`);
    if (f.fleet.fromDailyCents) out.push(`- From ${money(f.fleet.fromDailyCents)} a day`);
    if (f.fleet.fromWeeklyCents) out.push(`- From ${money(f.fleet.fromWeeklyCents)} a week`);
    if (f.fleet.fromMonthlyCents) out.push(`- From ${money(f.fleet.fromMonthlyCents)} for ${f.policy.maxDays} days (the longest single booking; it renews)`);
    for (const c of f.fleet.classes) out.push(`- ${c.label}: ${c.count} ${c.count === 1 ? 'car' : 'cars'}, from ${money(c.fromDailyCents)} a day`);
  } else out.push('- The first cars are being listed; each car shows its own rates and deposit on its page.');
  if (f.fleet.deliveryFromCents !== null) out.push(`- Delivery from ${f.fleet.deliveryFromCents ? money(f.fleet.deliveryFromCents) : 'no charge'}${f.airports.length ? `, airports too (${f.airports.join(', ')})` : ''}`);
  if (f.chauffeurFromCents) out.push(`- Chauffeur service from ${money(f.chauffeurFromCents)} an hour${f.chauffeurMinHours ? `, ${f.chauffeurMinHours} hours minimum` : ''}`);
  out.push(`- Fleet and live rates: ${abs(f, '/cars')}`, '');
  out.push('## Renting', '', `- Drivers: ${f.drivers.minAge} and up, ${f.drivers.licence}${f.drivers.youngBands ? `; young driver fees for ${f.drivers.youngBands}` : ''}`,
    `- Booking length: 1 to ${f.policy.maxDays} days; ${f.policy.weekFrom} days or more use the weekly rate`,
    `- Deposits: ${f.policy.deposits}, shown on each car's page and taken${f.policy.depositLead ? ` about ${f.policy.depositLead}` : ''} before pickup, never at the request`,
    `- Notice: book at least ${f.policy.noticeHours} ahead`,
    `- Cancellation: ${f.policy.cancellation}`,
    '- How to book: choose a car, send a request (no payment), approve the confirmed offer, verify your licence, then pick up or have it delivered', '');
  out.push('## Services', '', ...f.services.map((l) => link(f, l)), '');
  if (f.locations.length) out.push('## Locations served', '', ...f.locations.map((l) => link(f, l)), '');
  if (f.uses.length) out.push('## Ways to rent', '', ...f.uses.map((l) => link(f, l)), '');
  if (f.faq.length) out.push('## Questions', '', ...f.faq.flatMap((q) => [`### ${md(q.question)}`, '', md(q.answer), '']));
  out.push('## Policies and help', '', ...f.pages.map((l) => link(f, l)), '');
  if (f.guides.length) out.push('## Guides', '', ...f.guides.map((l) => link(f, l)), '');
  return out.join('\n').replace(/\n{3,}/g, '\n\n').trim() + '\n';
}
