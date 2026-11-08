// The investor pitch deck, 2026 (release 35; docs/changes/2026-11-08-r35-investor-deck.md): the owner's slides, word for
// word, and the terms every investor-facing page states (the portal home, Live sheets and its downloads, the deck page).
// One source: change a term here and every page follows. Investor material never states the fleet's size, its
// utilization, the insurance premium or internal costs, and names only 18122211 Canada Inc. as the legal entity
// (pitch.test.ts checks both). Pure: the pages, the sheets and the unit tests share it.

export const LEGAL_ENTITY = '18122211 Canada Inc.';

/** The raise and its two options, as the deck states them. */
export const RAISE = {
  amount: 500_000,
  funds: [
    { label: 'Fleet expansion', amount: 400_000 },
    { label: 'Reserve for the funded cars', amount: 50_000 },
    { label: 'Operating cushion', amount: 50_000 }
  ],
  option1: { lowPct: 10, highPct: 15 },
  option2: { lowPct: 20, highPct: 25 }
} as const;

const dollars = (n: number) => `$${Math.round(n).toLocaleString('en-CA')}`;
/** Simple interest, paid monthly: the amount x the yearly percentage / 12. */
export const monthlyInterest = (amount: number, pct: number) => (amount * pct) / 100 / 12;

/** The terms in plain words, the same on every page (label, text). */
export const TERMS: ReadonlyArray<readonly [string, string]> = [
  ['The raise', `${dollars(RAISE.amount)}: ${RAISE.funds.map((f) => `${dollars(f.amount)} ${f.label.toLowerCase()}`).join(', ')}.`],
  ['Option 1: interest', `${RAISE.option1.lowPct} to ${RAISE.option1.highPct}% a year, paid monthly, simple interest (${dollars(monthlyInterest(RAISE.amount, RAISE.option1.lowPct))} to ${dollars(monthlyInterest(RAISE.amount, RAISE.option1.highPct))} a month on ${dollars(RAISE.amount)}).`],
  ['Option 2: profit share', `${RAISE.option2.lowPct} to ${RAISE.option2.highPct}% profit share from the cars this money puts on the road.`],
  ['Who may invest', 'Offered only to eligible investors under a prospectus exemption.'],
  ['Your agreement', 'Final terms are set in the signed agreement.'],
  ['Who you invest with', LEGAL_ENTITY]
];

/** The examples of Option 1 (simple interest, paid monthly) at the low and high end. */
export const EXAMPLE_AMOUNTS = [50_000, 100_000, 250_000, 500_000] as const;
export function optionOneRow(amount: number) {
  const lo = monthlyInterest(amount, RAISE.option1.lowPct), hi = monthlyInterest(amount, RAISE.option1.highPct);
  return { amount, monthlyLow: lo, monthlyHigh: hi, yearlyLow: lo * 12, yearlyHigh: hi * 12 };
}

/** The per-car figures of the deck (October actual; 25 days is an illustration). */
export const PER_CAR = { perRentedDay: 112, exampleDays: 25, multiplier: 3.2 } as const;
export const perCarRevenue = (days: number = PER_CAR.exampleDays) => PER_CAR.perRentedDay * days;

export const FOOTNOTES = {
  illustration: `${PER_CAR.exampleDays} rented days is an illustration, not a forecast.`,
  internal: 'The figures are internal and unaudited.',
  offer: `Offered only to eligible investors under a prospectus exemption. Final terms are set in the signed agreement with ${LEGAL_ENTITY}`
} as const;

export interface PitchSlide { id: string; title: string; kicker: string; tone?: 'dark' | 'red' | 'grey' }

/** The slides, in order (PitchDeck lays each out). */
export const SLIDES: PitchSlide[] = [
  { id: 'cover', title: 'Investor presentation 2026', kicker: 'CarmaCars', tone: 'dark' },
  { id: 'model', title: 'Three ways to put cars on the road', kicker: 'The model' },
  { id: 'competitors', title: 'Big chains, peer-to-peer, and CarmaCars', kicker: 'Competitors', tone: 'grey' },
  { id: 'difference', title: 'What makes us different', kicker: 'The difference' },
  { id: 'demand', title: 'The demand is already here', kicker: 'Demand', tone: 'dark' },
  { id: 'per-car', title: 'What one car earns', kicker: 'Per car' },
  { id: 'ask', title: `The ask: ${dollars(RAISE.amount)}`, kicker: 'The ask', tone: 'red' },
  { id: 'about', title: 'About us', kicker: 'About' }
];

export const COVER = { kicker: 'Investor presentation 2026', title: 'Car rental, rebuilt for Ontario.', line: 'What goes around, drives around.' } as const;

export const MODEL = {
  supply: ['Owner program', 'Leased fleets', 'Partner fleets'],
  lead: 'Every rental earns more than the daily rate.',
  extras: ['Delivery', 'Young driver fees', 'Protection plans', 'Add-ons', 'Insurer-billed replacement rentals', 'After-trip charges']
} as const;

/** Big chains and peer-to-peer by what they are; what CarmaCars offers, point by point. */
export const COMPETITORS = {
  others: [{ title: 'Big chains', text: 'Rental counters and desks' }, { title: 'Peer-to-peer', text: 'Cars listed by individual hosts' }],
  carmacars: ['18+ on most cars', 'Delivered anywhere in Ontario', 'Your own policy, your card\u2019s coverage, or ours', 'Real staff, 24/7', 'Weekly and monthly plans', 'Billed straight to the insurer']
} as const;

export const DIFFERENCE = ['Capital-light supply', 'One fleet insurance policy', 'Our own platform, with no per-booking fee', 'Search and AI visibility'] as const;

export const DEMAND = [
  { big: '8 to 11', text: 'rental requests a day from organic traffic alone' },
  { big: 'About 15%', text: 'of requests filled today' },
  { big: '$0', text: 'spent on marketing' },
  { big: '$45k+', text: 'collected since opening mid-October' },
  { big: '25', text: 'commission-only sales staff being onboarded' }
] as const;

export const ABOUT = {
  people: [{ name: 'Abbas', role: 'Co-founder and director' }, { name: 'Mahad', role: 'Co-founder and director' }],
  text: 'Abbas and Mahad run the business side by side.'
} as const;

export { dollars };
