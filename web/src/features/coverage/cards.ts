// The credit cards that include rental car damage coverage (migration 0131, docs/changes/2026-10-24-credit-card-coverage.md):
// the rows of card_rental_coverage as the site reads them (public.card_coverage_public), and the words and filters of
// /credit-card-rental-coverage and the staff quick reference. Facts only: the card's issuer decides every claim.

export type CoverageKind = 'primary' | 'secondary' | 'none' | 'ask';
export interface CardRow {
  id: string; country: 'CA' | 'US'; issuer: string; card: string; coverage: CoverageKind;
  max_msrp_cents: number | null; value_note: string | null; max_days: number | null;
  exclusions: string; conditions: string; car_sharing: string | null; note: string | null;
  guide_url: string | null; source_url: string | null; issuer_checked: boolean; last_checked: string; sort_order: number; is_active: boolean;
}
export interface CardList { cards: CardRow[]; checked: string | null; oldest: string | null }

export const COVERAGE_LABEL: Record<CoverageKind, string> = {
  primary: 'Primary', secondary: 'Secondary', none: 'No rental car coverage', ask: 'Not stated: ask the issuer'
};
export const COVERAGE_HINT: Record<CoverageKind, string> = {
  primary: 'Pays first, before any other insurance you have.',
  secondary: 'Pays only what your other insurance does not.',
  none: 'This card does not include rental car damage coverage.',
  ask: 'What we read does not say whether it pays first.'
};

const dollars = (cents: number) => `$${Math.round(cents / 100).toLocaleString('en-CA')}`;

/** The car value limit in words: "$65,000 MSRP", the document's own words, or that none is stated. */
export function valueLimit(c: Pick<CardRow, 'max_msrp_cents' | 'value_note' | 'coverage'>): string {
  if (c.coverage === 'none') return 'None';
  if (c.max_msrp_cents) return `${dollars(c.max_msrp_cents)} MSRP`;
  return c.value_note ? c.value_note : 'Not stated';
}
export const daysLimit = (c: Pick<CardRow, 'max_days' | 'coverage'>) => (c.coverage === 'none' ? 'None' : c.max_days ? `${c.max_days} days` : 'Not stated');

/** "October 23, 2026" from "2026-10-23" (no time zone shift). */
export function checkedOn(day: string | null | undefined): string {
  const m = /^(\d{4})-(\d{2})-(\d{2})/.exec(day ?? '');
  if (!m) return '';
  const months = ['January', 'February', 'March', 'April', 'May', 'June', 'July', 'August', 'September', 'October', 'November', 'December'];
  return `${months[Number(m[2]) - 1]} ${Number(m[3])}, ${m[1]}`;
}

export type ValueFilter = 'any' | '65000' | '85000' | '100000';
export interface CardFilter { q: string; country: 'all' | 'CA' | 'US'; value: ValueFilter; primary: boolean }
export const NO_FILTER: CardFilter = { q: '', country: 'all', value: 'any', primary: false };

/** The rows a filter keeps. A value filter keeps only cards whose stated MSRP limit reaches it (a card with no stated
 *  limit is left out: it cannot be shown to cover that much). */
export function filterCards(rows: CardRow[], f: CardFilter): CardRow[] {
  const words = f.q.trim().toLowerCase().split(/\s+/).filter(Boolean);
  const min = f.value === 'any' ? 0 : Number(f.value) * 100;
  return rows.filter((c) => {
    if (f.country !== 'all' && c.country !== f.country) return false;
    if (f.primary && c.coverage !== 'primary') return false;
    if (min && (c.coverage === 'none' || !c.max_msrp_cents || c.max_msrp_cents < min)) return false;
    if (!words.length) return true;
    const hay = `${c.issuer} ${c.card} ${c.exclusions} ${c.note ?? ''} ${c.value_note ?? ''}`.toLowerCase();
    return words.every((w) => hay.includes(w));
  });
}

/** The cards that state an MSRP limit of at least this many dollars (the page's "for a luxury car" summary). */
export const reaching = (rows: CardRow[], dollarsMin: number) => rows.filter((c) => c.coverage !== 'none' && (c.max_msrp_cents ?? 0) >= dollarsMin * 100);

/** The questions on the page, also its FAQPage structured data: real questions renters ask, answered from the list. */
export function cardFaq(rows: CardRow[]): Array<{ question: string; answer: string }> {
  const ca = rows.filter((c) => c.country === 'CA' && c.coverage !== 'none');
  const at = (n: number) => ca.filter((c) => c.max_msrp_cents === n * 100).length;
  const over = reaching(ca, 100000).map((c) => `${c.issuer} ${c.card}`);
  const cards = (n: number) => `${n} Canadian ${n === 1 ? 'card stops' : 'cards stop'}`;
  return [
    { question: 'Does my credit card cover a rental car from CarmaCars?',
      answer: 'It may. Your card must include rental car damage coverage, the car must be under the card\'s value limit and not an excluded type or make, the rental must be no longer than the card allows, and you must pay the whole rental with that card. Only your card issuer can confirm it. Call the number on the back of your card before you rent.' },
    { question: 'What car value do credit cards cover?',
      answer: `Most Canadian cards set a limit on the car's manufacturer's suggested retail price (MSRP) for its model year, before taxes. In our list, ${cards(at(65000))} at $65,000 and ${cards(at(85000))} at $85,000${over.length ? `; ${over.join(' and ')} ${over.length === 1 ? 'reaches' : 'reach'} $100,000` : ''}. Many luxury cars are priced above these limits. If the car you want is, choose OPCF 27 on your own auto policy or the CarmaCars Protection Plan.` },
    { question: 'Do I have to decline other damage waivers?',
      answer: 'Most card benefits apply only when you decline the rental company\'s collision or loss damage waiver. Follow your card\'s own terms: decline a waiver only if they say to.' },
    { question: 'How long can I rent and stay covered?',
      answer: 'Usually 31 or 48 consecutive days, depending on the card. Most certificates say that a rental longer than the limit is not covered at all, not even for its first days.' },
    { question: 'Who decides a claim on my card\'s coverage?',
      answer: 'Your card issuer and its insurer. CarmaCars does not decide claims and is not an insurer. If the car is damaged, you pay what your rental agreement says and claim it back from your card\'s coverage.' }
  ];
}
