// The search copy written by Workers AI (migration 0061): the car pages, the landing pages and the articles. One fixed
// structure per kind, the house style in the prompt, and the checks every answer passes before it is published:
// lengths, the brand, no long dashes, no AI-sounding words, the Protection Plan wording, no claim the facts do not
// support and no number that is not in the facts. A car's copy must also read differently from every other car's.
// Pure functions: no server imports, so the unit tests run them directly (copy.test.ts).

export const CAR_PROMPT_VERSION = 'car-copy-v2';
export const PAGE_PROMPT_VERSION = 'landing-v1';
export const ARTICLE_PROMPT_VERSION = 'article-v1';

export type Faq = { question: string; answer: string };
export interface CarCopy {
  seo_title: string; meta_description: string; h1: string; intro: string;
  highlights: string[]; good_for: string[]; included: string[]; pickup_delivery: string; requirements: string[];
  faq: Faq[]; alt_texts: Record<string, string>;
}
export const CAR_FIELDS = ['seo_title', 'meta_description', 'h1', 'intro', 'highlights', 'good_for', 'included', 'pickup_delivery', 'requirements', 'faq', 'alt_texts'] as const;
export type CarField = (typeof CAR_FIELDS)[number];
export const CAR_FIELD_LABEL: Record<CarField, string> = {
  seo_title: 'Search title', meta_description: 'Search description', h1: 'Heading', intro: 'Introduction', highlights: 'Highlights',
  good_for: 'Good for', included: "What's included", pickup_delivery: 'Pickup and delivery', requirements: 'Requirements', faq: 'Questions', alt_texts: 'Photo descriptions'
};

/** The limits of every field (characters, words, items). */
export const LIMITS = {
  // car-copy-v2 (0073): the intro is the short blurb of the sample cars, the highlights are six selling features
  seo_title: [25, 60], meta_description: [90, 155], h1: [20, 70], intro_words: [8, 40], highlights: [4, 6], highlight_chars: 70,
  good_for: [2, 4], included: [3, 5], item_chars: 90, pickup: [60, 420], requirements: [3, 5], faq: [3, 6], question_chars: 110, answer_chars: 360, alt_chars: 125,
  page_intro_words: [50, 160], page_sections: [2, 4], section_words: [40, 220], page_faq: [3, 6],
  article_words: [500, 2200], article_title: [20, 100], article_description: [90, 160]
} as const;

/** Words and phrases that read as machine-written or as sales talk. The database adds the Admin's own list. */
export const AI_WORDS = [
  'look no further', 'elevate', 'seamless', 'whether you are', "whether you're", 'unparalleled', 'best in class', 'unleash', 'nestled', 'boasts', 'delve',
  'testament', 'embark', 'game changer', 'game-changer', 'unforgettable', 'effortless', "in today's", 'top-notch', 'second to none', 'hidden gem',
  'must-have', 'dream car', 'thrill', 'exhilarating', 'world-class', 'cutting-edge', 'state-of-the-art', 'breathtaking', 'turn heads', 'head-turning',
  'hit the road', 'open road awaits', 'adventure awaits', 'unlock', 'experience the', 'look and feel', 'the perfect', 'perfect for', 'ultimate',
  'amazing', 'stunning', 'incredible', 'unbeatable', 'hassle-free', 'peace of mind', 'in style', 'like a pro', 'tailored', 'curated', 'bespoke',
  'robust', 'leverage', 'furthermore', 'moreover', 'in conclusion', 'rest assured', 'navigate the', 'treat yourself', 'it is worth noting', 'dive into'
];

const DASH = /[‒–—―]/;
const COMPANY = /18122211|canada inc|numbered company/i;
// "Carmacars", "Carma Cars", "CARMACARS": the brand is written CarmaCars only
const brandWrong = (t: string) => [...t.matchAll(/\bcarma ?cars\b/gi)].some((m) => m[0] !== 'CarmaCars');
// the renter's protection is called the Protection Plan, never insurance; no provider named. Built from parts so that
// this file passes the same string search as the copy (web/src/features/legal-review.test.ts).
const PROTECTION = new RegExp(['(coverage|insurance) you (buy|add|get) with your booking', '(coverage|insurance)[^.\\n"]{0,30}(bou' + 'ght|so' + 'ld|purchased|offered) (through|by|from) (CarmaCars|us)',
  '(buy|purchase|add) (rental )?(coverage|insurance) (thr' + 'ough|from) (CarmaCars|us|you)', 'coverage op' + 'tion 3', 'coverage so' + 'ld through', 'rental insurance', '\\bour insurance',
  'insurance (is )?included', 'full coverage', 'fully insured'].join('|'), 'i');
// claims the facts must support before the copy may make them
const CLAIMS: Array<{ re: RegExp; needs: RegExp; label: string }> = [
  { re: /\b(mpg|l\/100 ?km|fuel economy|fuel[- ]efficien\w*|miles per gallon|fuel[- ]sipping|good on gas)\b/i, needs: /consumption|l\/100|mpg/i, label: 'fuel economy' },
  { re: /\b(safety rating|five-star|5-star|iihs|nhtsa|top safety pick|crash test)\b/i, needs: /safety_rating/i, label: 'a safety rating' },
  { re: /\b(range of|km of range|electric range|on a (single|full) charge)\b/i, needs: /"range"/i, label: 'an electric range' },
  { re: /\b(horsepower|hp\b|torque|0 to 100|0-100|zero to)\b/i, needs: /horsepower|"hp"|torque/i, label: 'engine output' },
  { re: /\b(heated (front )?seats?|heated steering|sunroof|moonroof|panoramic roof|apple carplay|android auto|carplay|navigation system|built-in navigation|leather|backup camera|rear camera|blind[- ]spot|lane[- ]keep|adaptive cruise|remote start|wireless charging|third row|tow hitch|roof rack|bluetooth)\b/i,
    needs: /$^/, label: 'equipment' },
  { re: /\b(new car|brand new|low mileage|low kilometres|well[- ]maintained|immaculate|spotless|mint condition|like new)\b/i, needs: /$^/, label: 'the condition of the car' },
  { re: /\b(free cancellation|no deposit|unlimited (km|kilometres|mileage)|no hidden fees|lowest price|cheapest|best price|price match)\b/i, needs: /$^/, label: 'a price promise' }
];
const SPELLED: Record<string, string> = { two: '2', three: '3', four: '4', five: '5', six: '6', seven: '7', eight: '8', nine: '9', ten: '10', eleven: '11', twelve: '12' };

const words = (s: string) => (s.trim() ? s.trim().split(/\s+/).length : 0);
const inRange = (n: number, [lo, hi]: readonly [number, number]) => n >= lo && n <= hi;
const str = (v: unknown) => (typeof v === 'string' ? v.replace(/[ \t]+/g, ' ').replace(/ *\n */g, '\n').trim() : '');
const strs = (v: unknown) => (Array.isArray(v) ? v.map(str).filter(Boolean) : []);
const faqs = (v: unknown): Faq[] => (Array.isArray(v) ? v.flatMap((q) => { const e = (q ?? {}) as Record<string, unknown>; return str(e.question) && str(e.answer) ? [{ question: str(e.question), answer: str(e.answer) }] : []; }) : []);

// ---------------------------------------------------------------- numbers
/** Every number in a text, normalized: "$1,250.00" -> "1250", "2.5" -> "2.5", "two" -> "2". */
export function numbersIn(text: string, spelled = true): string[] {
  const out: string[] = [];
  for (const m of text.matchAll(/\d[\d,]*(?:\.\d+)?/g)) {
    let n = m[0].replace(/,(?=\d{3}\b)/g, '').replace(/,$/, '');
    if (/\.\d+$/.test(n)) n = n.replace(/\.0+$/, '').replace(/(\.\d*?)0+$/, '$1');
    out.push(n);
  }
  if (spelled) for (const m of text.toLowerCase().matchAll(/\b(two|three|four|five|six|seven|eight|nine|ten|eleven|twelve)\b/g)) out.push(SPELLED[m[1]!]!);
  return out;
}
function collect(v: unknown, into: string[]) {
  if (v === null || v === undefined) return;
  if (typeof v === 'number') into.push(String(v));
  else if (typeof v === 'string') into.push(v);
  else if (Array.isArray(v)) v.forEach((x) => collect(x, into));
  else if (typeof v === 'object') Object.values(v as Record<string, unknown>).forEach((x) => collect(x, into));
}
/** The numbers the facts allow (each number found in any value). */
export function allowedNumbers(facts: unknown, extra: string[] = []): Set<string> {
  const texts: string[] = [];
  collect(facts, texts);
  return new Set([...texts, ...extra].flatMap((t) => numbersIn(t, false)));
}
/** Numbers in the text the facts do not have. */
export function inventedNumbers(text: string, allowed: Set<string>): string[] {
  return [...new Set(numbersIn(text).filter((n) => !allowed.has(n)))];
}

// ---------------------------------------------------------------- similarity
const shingles = (s: string, n = 5) => {
  const w = s.toLowerCase().replace(/[^a-z0-9$ ]+/g, ' ').split(/\s+/).filter(Boolean);
  const out = new Set<string>();
  for (let i = 0; i + n <= w.length; i++) out.add(w.slice(i, i + n).join(' '));
  return out;
};
/** The share of the first text's five-word sequences that also appear in the second (0 to 1). */
export function similarity(a: string, b: string): number {
  const A = shingles(a); const B = shingles(b);
  if (!A.size || !B.size) return 0;
  let k = 0;
  for (const x of A) if (B.has(x)) k++;
  return k / A.size;
}

// ---------------------------------------------------------------- shared text checks
export interface StyleOpts { banned?: string[] }
/** The house style, for any text. */
export function styleProblems(text: string, o: StyleOpts = {}): string[] {
  const p: string[] = [];
  if (DASH.test(text)) p.push('remove every em dash and en dash (use a comma, a colon or a full stop)');
  if (/!/.test(text)) p.push('remove the exclamation marks');
  if (COMPANY.test(text)) p.push('never name a numbered or legal company: say CarmaCars');
  if (brandWrong(text)) p.push('write the brand exactly as CarmaCars');
  if (PROTECTION.test(text)) p.push('never present insurance as something renters get from CarmaCars: say nothing about it, or name "the Protection Plan"');
  const low = text.toLowerCase();
  const hits = [...new Set([...AI_WORDS, ...(o.banned ?? [])].filter((b) => b && new RegExp(`(^|[^a-z])${b.toLowerCase().replace(/[.*+?^${}()|[\]\\]/g, '\\$&')}([^a-z]|$)`).test(low)))];
  if (hits.length) p.push(`do not use these words: ${hits.map((h) => `"${h}"`).join(', ')}`);
  return p;
}

// ---------------------------------------------------------------- car copy
export const CAR_COPY_SCHEMA = {
  type: 'object',
  properties: {
    seo_title: { type: 'string' }, meta_description: { type: 'string' }, h1: { type: 'string' }, intro: { type: 'string' },
    highlights: { type: 'array', items: { type: 'string' } }, good_for: { type: 'array', items: { type: 'string' } },
    included: { type: 'array', items: { type: 'string' } }, pickup_delivery: { type: 'string' }, requirements: { type: 'array', items: { type: 'string' } },
    faq: { type: 'array', items: { type: 'object', properties: { question: { type: 'string' }, answer: { type: 'string' } }, required: ['question', 'answer'] } },
    alt_texts: { type: 'object', additionalProperties: { type: 'string' } }
  },
  required: ['seo_title', 'meta_description', 'h1', 'intro', 'highlights', 'good_for', 'included', 'pickup_delivery', 'requirements', 'faq', 'alt_texts']
} as const;

const STYLE_RULES = [
  'Write in plain Canadian English, like a helpful person at a local rental counter: short sentences, everyday words, the second person ("you").',
  'No superlatives, no hype, no exclamation marks, no emoji. Never use an em dash or an en dash: use commas, colons or full stops.',
  'Write the company name exactly as CarmaCars. Never name any other company except the car maker.',
  'Never mention the VIN, the licence plate, the odometer, the owner, damage or the car\'s history.',
  'Never mention insurance or coverage that can be bought. The only coverage you may mention is the third-party liability coverage listed under included.',
  `Avoid these words and phrases: ${AI_WORDS.slice(0, 40).join(', ')}.`
];

/** The voice of the car pages: the blurbs of the sample cars (supabase/seed/sample_cars_gen.mjs, prototype/tools/src/data.mjs). */
export const VOICE_EXAMPLES = [
  'Room for four adults and their bags, and the quiet cabin Toyota is known for.',
  'A roomy trunk and a soft ride. The commuter that does not mind a road trip.',
  'Cheap to rent, cheap to fuel, and it starts every morning.',
  'A big boot, a high seat and all-wheel drive for whatever February brings.',
  'Seven seats and doors that open themselves. The airport run with everybody in one car.',
  'The small Mercedes. Easy to park downtown, all-wheel drive for the 401 in November.'
];

export function carSystemPrompt(): string {
  return [
    'You write the car pages of CarmaCars, a car rental company in Toronto, Ontario. Every page has the same structure as the example cars of the site and is written only from the facts given.',
    ...STYLE_RULES,
    'Use only the facts. Every number you write (years, prices, seats, kilometres, ages, hours) must appear in the facts exactly as given. Do not add, multiply or round numbers.',
    'Do not claim equipment, fuel economy, range, power, safety ratings or condition that the facts do not state.',
    'Answer with one JSON object that follows the schema exactly, and nothing else.'
  ].join('\n');
}

export function carUserPrompt(facts: Record<string, unknown>, o: { locked?: string[]; avoid?: string[]; problems?: string[]; strict?: boolean } = {}): string {
  const car = (facts.car ?? {}) as Record<string, unknown>;
  const name = [car.year, car.make, car.model].filter(Boolean).join(' ');
  const full = [name, car.trim].filter(Boolean).join(' ');
  const photos = Array.isArray(facts.photos) ? (facts.photos as string[]) : [];
  const { known, maybe } = offeredEquipment(facts);
  const L = LIMITS;
  return [
    `<facts>${JSON.stringify(facts)}</facts>`,
    `Write the page for this car, a ${full}:`,
    `- intro: 1 or 2 short sentences, ${L.intro_words[0] + 2} to 30 words, in exactly the voice of these examples from other cars of the site:\n${VOICE_EXAMPLES.map((x) => `  "${x}"`).join('\n')}\n  Say what this car is good for and what it is like to live with, from its body, seats, drivetrain, fuel and equipment. Do not start with "This car" or "This vehicle", do not name the year, the trim, the colour or where the car is kept, and do not list specifications.`,
    `- highlights: exactly ${L.highlights[1]} selling features, each copied word for word from these lists. Known to be on this car: ${JSON.stringify(known)}. Possibly on it: ${JSON.stringify(maybe)}. Take an item from the second list only if you are sure it is standard on every ${full} sold in Canada; if you are not sure, leave it out. The features renters care most about first.`,
    `- good_for: ${L.good_for[0]} to ${L.good_for[1]} short phrases naming the trips or people this car suits (for example "Airport runs with luggage"), based on its body, seats and fuel.`,
    `- faq: ${L.faq[0]} to ${L.faq[0] + 1} questions a renter asks about this model (passengers, luggage, winter driving, charging or fuel), each answered in one or two sentences from the facts. Do not ask about delivery, kilometres, prices or payment: the page answers those. If the facts do not answer a question, do not ask it.`,
    photos.length ? `- alt_texts: an object with exactly these keys: ${photos.join(', ')}. Each value describes that photo in under ${L.alt_chars} characters, like "${name} in ${String(car.colour ?? 'grey').toLowerCase()}, front left view".` : '- alt_texts: an empty object.',
    '- seo_title, meta_description, h1, pickup_delivery, included, requirements: filled in by the site. Return empty strings and empty lists for them.',
    o.locked?.length ? `These fields were written by a person and are kept: ${o.locked.join(', ')}. Still return them, unchanged.` : '',
    o.avoid?.length ? `Other cars of the same model already use these introductions. Write yours differently, with different sentences:\n${o.avoid.slice(0, 3).map((a) => `"${a.slice(0, 400)}"`).join('\n')}` : '',
    o.problems?.length ? `Your last answer had these problems. Fix every one:\n- ${o.problems.join('\n- ')}` : '',
    o.strict ? 'Be strict: keep every sentence short and plain, copy the features word for word, and use no number that is not in the facts.' : ''
  ].filter(Boolean).join('\n');
}

// ---------------------------------------------------------------- the fixed parts of a car page (car-copy-v2, 0073)
const NUM_WORDS = ['zero', 'one', 'two', 'three', 'four', 'five', 'six', 'seven', 'eight', 'nine'];
const strList = (v: unknown) => (Array.isArray(v) ? v.filter((x): x is string => typeof x === 'string' && x.trim() !== '').map((x) => x.trim()) : []);
/** The equipment a car's features may name: known (VIN decode, the listing, safe for its year) and possibly (the model decides). */
export function offeredEquipment(facts: Record<string, unknown>): { known: string[]; maybe: string[] } {
  const car = (facts.car ?? {}) as Record<string, unknown>;
  const known = [...new Set([...strList(car.equipment), ...strList(car.equipment_known)])];
  const maybe = strList(car.equipment_maybe).filter((x) => !known.some((k) => k.toLowerCase() === x.toLowerCase()));
  return { known, maybe };
}
/** The six features of the page: the model's picks that are on offer, then the known equipment in its order. */
export function fillHighlights(picked: string[], facts: Record<string, unknown>, n: number = LIMITS.highlights[1]): string[] {
  const { known, maybe } = offeredEquipment(facts);
  const offered = new Map([...known, ...maybe].map((x) => [x.toLowerCase(), x]));
  const out: string[] = [];
  const add = (x: string) => { const k = offered.get(x.trim().toLowerCase()); if (k && !out.includes(k) && out.length < n) out.push(k); };
  picked.forEach(add);
  known.forEach(add);
  return out;
}
/** The headline of every car page, as the sample cars have it: "2022 Chevrolet Malibu LS for rent in Toronto". */
export function carHeadline(car: Record<string, unknown>, city = 'Toronto'): string {
  const name = [car.year, car.make, car.model].filter(Boolean).join(' ');
  const full = [name, car.trim].filter(Boolean).join(' ');
  return `${full} for rent in ${city}`.length <= LIMITS.h1[1] ? `${full} for rent in ${city}` : `${name} for rent in ${city}`;
}
/** The parts of a car page the site writes itself (never the model): headline, search text, pickup, included, requirements. */
export function carFixed(facts: Record<string, unknown>): Pick<CarCopy, 'h1' | 'seo_title' | 'meta_description' | 'pickup_delivery' | 'included' | 'requirements'> {
  const car = (facts.car ?? {}) as Record<string, unknown>;
  const pr = (facts.prices ?? {}) as Record<string, unknown>;
  const pl = (facts.place ?? {}) as Record<string, unknown>;
  const ru = (facts.rules ?? {}) as Record<string, unknown>;
  const city = String(pl.city ?? 'Toronto');
  const name = [car.year, car.make, car.model].filter(Boolean).join(' ');
  const full = [name, car.trim].filter(Boolean).join(' ');
  const brand = String(facts.brand ?? 'CarmaCars');
  const titles = [`${name} for rent in ${city} | ${brand}`, `${name} for rent in ${city}`, `${name} rental ${city}`.slice(0, 60)];
  const seo_title = titles.find((t) => t.length <= LIMITS.seo_title[1])!;
  const seats = typeof car.seats === 'number' ? `${car.seats} seats` : '';
  const tr = typeof car.transmission === 'string' ? car.transmission.toLowerCase() : '';
  const metas = [
    `Rent the ${full} in ${city}${pr.daily ? ` from ${pr.daily} a day` : ''}. ${[seats, tr].filter(Boolean).join(', ')}${seats || tr ? '. ' : ''}Pickup or delivery, and a request with no payment up front.`,
    `Rent the ${name} in ${city}${pr.daily ? ` from ${pr.daily} a day` : ''}. Pickup or delivery, and a request with no payment up front.`,
    `Rent the ${name} in ${city}. Collect it from us or have it delivered, and send a request with no payment up front.`];
  const meta_description = metas.find((m) => m.length >= LIMITS.meta_description[0] && m.length <= LIMITS.meta_description[1]) ?? metas[metas.length - 1]!;
  const inc = strList(facts.included);
  return {
    h1: carHeadline(car, city), seo_title, meta_description,
    pickup_delivery: `Collect it at our location at no charge, or we deliver it to your address${pr.delivery_fee ? ` for ${pr.delivery_fee}` : ''}. We hand it over in person and walk around the car with you.`,
    included: (inc.length >= 3 ? inc : [...inc, 'Third-party liability coverage', 'Roadside assistance, 24 hours a day', 'Handover in person with a walk-around of the car']).slice(0, LIMITS.included[1]),
    requirements: [ru.min_age ? `Drivers ${ru.min_age} or older` : '', String(ru.licence ?? ''), String(ru.card ?? ''), String(ru.identity ?? '')].filter(Boolean).slice(0, LIMITS.requirements[1])
  };
}
/** The seats of a car in words, for the plain blurbs ("room for five"). */
export const seatsWord = (n: unknown) => (typeof n === 'number' && n >= 0 && n < NUM_WORDS.length ? NUM_WORDS[n]! : String(n ?? ''));

export function normalizeCarCopy(x: unknown): CarCopy | null {
  if (!x || typeof x !== 'object') return null;
  const o = x as Record<string, unknown>;
  const alt: Record<string, string> = {};
  if (o.alt_texts && typeof o.alt_texts === 'object' && !Array.isArray(o.alt_texts)) for (const [k, v] of Object.entries(o.alt_texts as Record<string, unknown>)) if (str(v)) alt[k] = str(v);
  const c: CarCopy = {
    seo_title: str(o.seo_title), meta_description: str(o.meta_description), h1: str(o.h1),
    intro: typeof o.intro === 'string' ? o.intro.replace(/[ \t]+/g, ' ').replace(/\n{3,}/g, '\n\n').trim() : '',
    highlights: strs(o.highlights), good_for: strs(o.good_for), included: strs(o.included), pickup_delivery: str(o.pickup_delivery),
    requirements: strs(o.requirements), faq: faqs(o.faq), alt_texts: alt
  };
  return c.h1 || c.intro ? c : null;
}

/** Every text of a car copy, joined (for the style and number checks). */
export const carText = (c: CarCopy) => [c.seo_title, c.meta_description, c.h1, c.intro, ...c.highlights, ...c.good_for, ...c.included, c.pickup_delivery, ...c.requirements,
  ...c.faq.flatMap((q) => [q.question, q.answer]), ...Object.values(c.alt_texts)].join('\n');

export interface CarCheckOpts extends StyleOpts { others?: string[]; maxSimilarity?: number; skip?: string[] }
/** What is wrong with a car copy, in words the model (or a person) can act on. Empty: publish it. */
export function carCopyProblems(c: CarCopy, facts: Record<string, unknown>, o: CarCheckOpts = {}): string[] {
  const p: string[] = [];
  const skip = new Set(o.skip ?? []);
  const L = LIMITS;
  const len = (k: 'seo_title' | 'meta_description' | 'h1', label: string) => {
    if (skip.has(k)) return;
    const n = c[k].length;
    if (!inRange(n, L[k] as readonly [number, number])) p.push(`the ${label} (${k}) must be ${L[k][0]} to ${L[k][1]} characters (it is ${n})`);
  };
  len('seo_title', 'search title'); len('meta_description', 'search description'); len('h1', 'heading');
  if (!skip.has('intro')) {
    const w = words(c.intro);
    if (!inRange(w, L.intro_words)) p.push(`the intro must be ${L.intro_words[0]} to ${L.intro_words[1]} words (it is ${w})`);
  }
  const count = (k: 'highlights' | 'good_for' | 'included' | 'requirements', r: readonly [number, number]) => {
    if (skip.has(k)) return;
    if (!inRange(c[k].length, r)) p.push(`give ${r[0]} to ${r[1]} ${k.replace('_', ' ')} (there are ${c[k].length})`);
    const long = c[k].filter((x) => x.length > (k === 'highlights' ? L.highlight_chars : L.item_chars));
    if (long.length) p.push(`shorten these ${k.replace('_', ' ')}: ${long.map((x) => `"${x.slice(0, 40)}..."`).join(', ')}`);
  };
  count('highlights', L.highlights); count('good_for', L.good_for); count('included', L.included); count('requirements', L.requirements);
  if (!skip.has('pickup_delivery') && !inRange(c.pickup_delivery.length, L.pickup)) p.push(`pickup_delivery must be ${L.pickup[0]} to ${L.pickup[1]} characters (it is ${c.pickup_delivery.length})`);
  if (!skip.has('faq')) {
    if (!inRange(c.faq.length, L.faq)) p.push(`give ${L.faq[0]} to ${L.faq[1]} questions (there are ${c.faq.length})`);
    if (c.faq.some((q) => q.question.length > L.question_chars || q.answer.length > L.answer_chars)) p.push(`keep each question under ${L.question_chars} characters and each answer under ${L.answer_chars}`);
    if (c.faq.some((q) => !q.question.endsWith('?'))) p.push('end every question with a question mark');
  }
  if (!skip.has('alt_texts')) {
    const photos = Array.isArray(facts.photos) ? (facts.photos as string[]) : [];
    const missing = photos.filter((k) => !c.alt_texts[k]);
    if (missing.length) p.push(`alt_texts is missing these photos: ${missing.join(', ')}`);
    const car = (facts.car ?? {}) as Record<string, unknown>;
    const bad = Object.entries(c.alt_texts).filter(([, v]) => v.length > L.alt_chars || !v.toLowerCase().includes(String(car.model ?? '').toLowerCase()));
    if (bad.length) p.push(`each alt text names the model and stays under ${L.alt_chars} characters (fix: ${bad.map(([k]) => k).join(', ')})`);
  }
  const car = (facts.car ?? {}) as Record<string, unknown>;
  if (!skip.has('h1') && car.model && !c.h1.toLowerCase().includes(String(car.model).toLowerCase())) p.push('the heading must name the model');
  if (!skip.has('seo_title') && car.model && !c.seo_title.toLowerCase().includes(String(car.model).toLowerCase())) p.push('the search title must name the model');
  // the checks on the whole text (the fields a person locked are theirs and are not judged)
  const text = carText({ ...c, ...Object.fromEntries([...skip].map((k) => [k, Array.isArray((c as unknown as Record<string, unknown>)[k]) ? [] : k === 'faq' ? [] : k === 'alt_texts' ? {} : ''])) } as CarCopy);
  p.push(...styleProblems(text, o));
  if (/\b(vin|licence plate|license plate|odometer|the owner of this car|owned by)\b/i.test(text)) p.push('never mention the VIN, the plate, the odometer or the owner');
  const factText = JSON.stringify(facts).toLowerCase();
  for (const cl of CLAIMS) {
    // every mention is checked (the features now name equipment the facts have, so the first one is often fine)
    const m = [...text.matchAll(new RegExp(cl.re.source, 'gi'))].find((x) => (cl.label === 'equipment' ? !factText.includes(x[0].toLowerCase()) : !cl.needs.test(factText)));
    // equipment is allowed only when the facts name that very item
    if (m) p.push(`do not claim ${cl.label} ("${m[0]}"): it is not in the facts`);
  }
  const bad = inventedNumbers(text, allowedNumbers(facts));
  if (bad.length) p.push(`these numbers are not in the facts: ${bad.join(', ')}. Use only numbers from the facts`);
  // car-copy-v2: the features are the offered equipment only, and the intro reads like the sample cars' blurbs
  const offer = offeredEquipment(facts);
  if (!skip.has('highlights') && offer.known.length + offer.maybe.length > 0) {
    const ok = new Set([...offer.known, ...offer.maybe].map((x) => x.toLowerCase()));
    const off = c.highlights.filter((x) => !ok.has(x.toLowerCase()));
    if (off.length) p.push(`the highlights must be copied word for word from the equipment lists (not: ${off.map((x) => `"${x}"`).join(', ')})`);
  }
  if (!skip.has('intro')) {
    const area = String(((facts.place ?? {}) as Record<string, unknown>).area ?? '');
    if (/\b(kept|parked|based|located|lives) (in|at)\b/i.test(c.intro) || (area && area !== String(((facts.place ?? {}) as Record<string, unknown>).city ?? '') && c.intro.toLowerCase().includes(area.toLowerCase())))
      p.push('do not say where the car is kept');
    if (/^\s*(this|the) (car|vehicle)\b/i.test(c.intro)) p.push('do not start the intro with "This car": say what it is like, as in the examples');
  }
  if (!skip.has('intro') && o.others?.length) {
    const max = o.maxSimilarity ?? 0.5;
    const worst = Math.max(...o.others.map((x) => similarity(c.intro, x)));
    if (worst > max) p.push(`the intro repeats another car's page (${Math.round(worst * 100)}% the same): write it in your own words`);
  }
  return p;
}

// ---------------------------------------------------------------- landing pages
export interface PageCopy { seo_title: string; meta_description: string; h1: string; intro: string; sections: Array<{ heading: string; body: string }>; faq: Faq[] }
export const PAGE_COPY_SCHEMA = {
  type: 'object',
  properties: {
    seo_title: { type: 'string' }, meta_description: { type: 'string' }, h1: { type: 'string' }, intro: { type: 'string' },
    sections: { type: 'array', items: { type: 'object', properties: { heading: { type: 'string' }, body: { type: 'string' } }, required: ['heading', 'body'] } },
    faq: { type: 'array', items: { type: 'object', properties: { question: { type: 'string' }, answer: { type: 'string' } }, required: ['question', 'answer'] } }
  },
  required: ['seo_title', 'meta_description', 'h1', 'intro', 'sections', 'faq']
} as const;

export function normalizePageCopy(x: unknown): PageCopy | null {
  if (!x || typeof x !== 'object') return null;
  const o = x as Record<string, unknown>;
  const sections = Array.isArray(o.sections) ? o.sections.flatMap((s) => { const e = (s ?? {}) as Record<string, unknown>; return str(e.heading) && str(e.body) ? [{ heading: str(e.heading), body: typeof e.body === 'string' ? e.body.replace(/[ \t]+/g, ' ').replace(/\n{3,}/g, '\n\n').trim() : '' }] : []; }) : [];
  const c: PageCopy = { seo_title: str(o.seo_title), meta_description: str(o.meta_description), h1: str(o.h1), intro: typeof o.intro === 'string' ? o.intro.replace(/[ \t]+/g, ' ').trim() : '', sections, faq: faqs(o.faq) };
  return c.h1 && c.intro ? c : null;
}
export const pageText = (c: PageCopy) => [c.seo_title, c.meta_description, c.h1, c.intro, ...c.sections.flatMap((s) => [s.heading, s.body]), ...c.faq.flatMap((q) => [q.question, q.answer])].join('\n');

/** The checks of a landing page: lengths, style, and numbers only from the page's facts (prices are shown by the page from live data, never written). */
export function pageCopyProblems(c: PageCopy, page: { name: string; facts: Record<string, unknown> }, o: StyleOpts & { skip?: string[]; others?: string[]; tokens?: string[] } = {}): string[] {
  const p: string[] = [];
  // {{tokens}} are settings filled in when the page is built (a fee, the minimum age): known ones only, and they
  // count as no words and no numbers here
  const all = pageText(c);
  if (o.tokens) {
    const unknown = [...new Set([...all.matchAll(/\{\{(\w+)\}\}/g)].map((m) => m[1]!).filter((t) => !o.tokens!.includes(t)))];
    if (unknown.length) p.push(`unknown tokens: ${unknown.join(', ')}`);
  }
  const strip = (s: string) => s.replace(/\{\{\w+\}\}/g, 'x');
  c = { ...c, seo_title: strip(c.seo_title), meta_description: strip(c.meta_description), h1: strip(c.h1), intro: strip(c.intro),
    sections: c.sections.map((s) => ({ heading: strip(s.heading), body: strip(s.body) })), faq: c.faq.map((q) => ({ question: strip(q.question), answer: strip(q.answer) })) };
  const L = LIMITS;
  const skip = new Set(o.skip ?? []);
  if (!skip.has('seo_title') && !inRange(c.seo_title.length, L.seo_title)) p.push(`the search title must be ${L.seo_title[0]} to ${L.seo_title[1]} characters (it is ${c.seo_title.length})`);
  if (!skip.has('meta_description') && !inRange(c.meta_description.length, L.meta_description)) p.push(`the search description must be ${L.meta_description[0]} to ${L.meta_description[1]} characters (it is ${c.meta_description.length})`);
  if (!skip.has('h1') && !inRange(c.h1.length, L.h1)) p.push(`the heading must be ${L.h1[0]} to ${L.h1[1]} characters (it is ${c.h1.length})`);
  if (!skip.has('intro') && !inRange(words(c.intro), L.page_intro_words)) p.push(`the intro must be ${L.page_intro_words[0]} to ${L.page_intro_words[1]} words (it is ${words(c.intro)})`);
  if (!skip.has('sections')) {
    if (!inRange(c.sections.length, L.page_sections)) p.push(`give ${L.page_sections[0]} to ${L.page_sections[1]} sections (there are ${c.sections.length})`);
    const off = c.sections.filter((s) => !inRange(words(s.body), L.section_words));
    if (off.length) p.push(`each section has ${L.section_words[0]} to ${L.section_words[1]} words (fix: ${off.map((s) => `"${s.heading}"`).join(', ')})`);
  }
  if (!skip.has('faq') && !inRange(c.faq.length, L.page_faq)) p.push(`give ${L.page_faq[0]} to ${L.page_faq[1]} questions (there are ${c.faq.length})`);
  const text = pageText(c);
  p.push(...styleProblems(text, o));
  if (/\$\s?\d/.test(text)) p.push('write no prices: the page shows the live prices itself');
  const bad = inventedNumbers(text, allowedNumbers({ name: page.name, facts: page.facts }));
  if (bad.length) p.push(`these numbers are not in the facts: ${bad.join(', ')}`);
  for (const cl of CLAIMS.filter((x) => x.label === 'a price promise')) { const m = cl.re.exec(text); if (m) p.push(`do not promise "${m[0]}"`); }
  if (o.others?.length && !skip.has('intro')) {
    const worst = Math.max(...o.others.map((x) => similarity(c.intro + ' ' + c.sections.map((s) => s.body).join(' '), x)));
    if (worst > 0.35) p.push(`the page repeats another landing page (${Math.round(worst * 100)}% the same): write it for this place or use only`);
  }
  return p;
}

export function pageSystemPrompt(): string {
  return ['You write the landing pages of CarmaCars, a car rental company in Toronto, Ontario. Each page is about one place or one way of renting, and lists the live cars itself.',
    ...STYLE_RULES,
    'Use only the facts given about the place or the use. Write no prices and no fees: the page shows the live prices. Every other number must appear in the facts.',
    'Be specific and useful to a renter: where to meet, how delivery works there, roads and transit, parking, what to plan for. No filler about the area.',
    'Answer with one JSON object that follows the schema exactly, and nothing else.'].join('\n');
}
export function pageUserPrompt(page: { slug: string; kind: string; name: string; facts: Record<string, unknown>; city?: string }, o: { locked?: string[]; current?: Partial<PageCopy>; problems?: string[] } = {}): string {
  const L = LIMITS;
  return [`<page>${JSON.stringify({ name: page.name, kind: page.kind, city: page.city ?? 'Toronto', facts: page.facts })}</page>`,
    `Write the ${page.kind === 'location' ? 'location' : 'use'} page "${page.name}":`,
    `- seo_title: ${L.seo_title[0]} to ${L.seo_title[1]} characters, the main search phrase first (for example "Car Rental in ${page.name} | CarmaCars").`,
    `- meta_description: ${L.meta_description[0]} to ${L.meta_description[1]} characters.`,
    `- h1: ${L.h1[0]} to ${L.h1[1]} characters.`,
    `- intro: ${L.page_intro_words[0] + 10} to ${L.page_intro_words[1] - 30} words.`,
    `- sections: ${L.page_sections[0] + 1} to ${L.page_sections[1]} sections with a short heading and ${L.section_words[0] + 20} to ${L.section_words[1] - 40} words each, from the facts.`,
    `- faq: ${L.page_faq[0] + 1} to ${L.page_faq[1]} questions renters ask about this, answered from the facts.`,
    o.locked?.length ? `Keep these fields exactly as they are (a person wrote them): ${o.locked.join(', ')}.` : '',
    o.current?.intro ? `The current text, for reference (rewrite it, keep the facts): ${JSON.stringify(o.current).slice(0, 3000)}` : '',
    o.problems?.length ? `Your last answer had these problems. Fix every one:\n- ${o.problems.join('\n- ')}` : ''].filter(Boolean).join('\n');
}

// ---------------------------------------------------------------- articles
export interface ArticleDraft { title: string; description: string; body_md: string; faq: Faq[] }
export const ARTICLE_SCHEMA = {
  type: 'object',
  properties: { title: { type: 'string' }, description: { type: 'string' }, body_md: { type: 'string' },
    faq: { type: 'array', items: { type: 'object', properties: { question: { type: 'string' }, answer: { type: 'string' } }, required: ['question', 'answer'] } } },
  required: ['title', 'description', 'body_md', 'faq']
} as const;
export function normalizeArticle(x: unknown): ArticleDraft | null {
  if (!x || typeof x !== 'object') return null;
  const o = x as Record<string, unknown>;
  const a = { title: str(o.title), description: str(o.description), body_md: typeof o.body_md === 'string' ? o.body_md.replace(/\r/g, '').replace(/\n{3,}/g, '\n\n').trim() + '\n' : '', faq: faqs(o.faq) };
  return a.body_md.trim() ? a : null;
}
/** An article's checks: lengths, headings, style, every {{token}} known, and fees only as tokens (so they follow the settings). */
export function articleProblems(a: ArticleDraft, o: StyleOpts & { tokens: string[]; numbers?: Set<string> }): string[] {
  const p: string[] = [];
  const L = LIMITS;
  if (!inRange(a.title.length, L.article_title)) p.push(`the title must be ${L.article_title[0]} to ${L.article_title[1]} characters (it is ${a.title.length})`);
  if (!inRange(a.description.length, L.article_description)) p.push(`the description must be ${L.article_description[0]} to ${L.article_description[1]} characters (it is ${a.description.length})`);
  const w = words(a.body_md.replace(/\{\{\w+\}\}/g, 'x'));
  if (!inRange(w, L.article_words)) p.push(`the article must be ${L.article_words[0]} to ${L.article_words[1]} words (it is ${w})`);
  if ((a.body_md.match(/^## /gm) ?? []).length < 3) p.push('give the article at least 3 sections with "## " headings');
  if (/^# /m.test(a.body_md)) p.push('do not start a line with "# ": the page has its own title');
  const unknown = [...new Set([...a.body_md.matchAll(/\{\{(\w+)\}\}/g)].map((m) => m[1]!).filter((t) => !o.tokens.includes(t)))];
  if (unknown.length) p.push(`unknown tokens: ${unknown.join(', ')}`);
  const text = [a.title, a.description, a.body_md, ...a.faq.flatMap((q) => [q.question, q.answer])].join('\n').replace(/\{\{\w+\}\}/g, '');
  p.push(...styleProblems(text, o));
  if (/\$\s?\d/.test(text)) p.push('write every CarmaCars fee or price as its {{token}}, never as a typed amount');
  if (o.numbers) { const bad = inventedNumbers(text, o.numbers); if (bad.length) p.push(`these numbers are not in the brief or the current article: ${bad.join(', ')}`); }
  return p;
}
export function articleSystemPrompt(tokens: Record<string, string>): string {
  return ['You write and update the guides of CarmaCars, a car rental company in Toronto, Ontario: practical articles for people renting a car in the Toronto area.',
    ...STYLE_RULES,
    'Write Markdown: "## " for section headings, "- " for bullets, short paragraphs. No "# " title (the page has one) and no links to other websites.',
    'Every CarmaCars fee, price or rule number must be written as its {{token}} from this list, never typed: ' + Object.entries(tokens).map(([k, v]) => `{{${k}}} = ${v}`).join('; ') + '.',
    'Facts about Ontario (roads, laws, tolls) only when the brief or the current article states them. Do not invent prices of other companies.',
    'Answer with one JSON object that follows the schema exactly, and nothing else.'].join('\n');
}
export function articleUserPrompt(a: { title: string; description: string; brief: string | null; body_md: string; faq: Faq[]; locked?: string[] }, problems: string[] = []): string {
  return [`<brief>${a.brief ?? 'Keep the subject and the facts of the current article, and make it clearer and more useful.'}</brief>`,
    `<current>${JSON.stringify({ title: a.title, description: a.description, body_md: a.body_md, faq: a.faq })}</current>`,
    `Write the article again: title ${LIMITS.article_title[0]} to ${LIMITS.article_title[1]} characters, description ${LIMITS.article_description[0]} to ${LIMITS.article_description[1]} characters, body ${LIMITS.article_words[0] + 200} to ${LIMITS.article_words[1] - 400} words with at least 4 "## " sections, and 3 to 5 questions.`,
    a.locked?.length ? `Keep these fields exactly as they are: ${a.locked.join(', ')}.` : '',
    problems.length ? `Your last answer had these problems. Fix every one:\n- ${problems.join('\n- ')}` : ''].filter(Boolean).join('\n');
}

// ---------------------------------------------------------------- the plain copy (no model)
/** The same plain copy the database writes (app.car_copy_template), for the listing pipeline's draft step, which no
 *  longer calls the model: the search job writes the real copy. */
/** The plain blurb of a car with no written copy yet, in the samples' voice and from its body alone (the same words as
 *  app.car_copy_blurb of migration 0073): nothing about where it is kept, nothing the facts do not say. */
export function plainBlurb(f: { make?: string; model?: string; seats?: number | null; body_style?: string | null; fuel?: string | null; drivetrain?: string | null }): string {
  const b = (f.body_style ?? '').toLowerCase();
  const make = f.make ?? '';
  const seats = f.seats ? seatsWord(f.seats) : '';
  const awd = /all|four|4wd|awd|4x4/i.test(f.drivetrain ?? '');
  if (/electric/i.test(f.fuel ?? '')) return `Electric, so no gas stations. Charge it up, return it with the charge you left with, and that is the whole fuel policy.`;
  if (/van|mpv/.test(b)) return `Room for ${seats || 'everyone'} and their bags. The airport run or the cottage weekend with everybody in one car.`;
  if (/pick.?up|truck/.test(b)) return `A ${make} pickup with an open box. Moving day, a hardware run or a load of firewood.`;
  if (/convertible|cabriolet|roadster/.test(b)) return `Roof down along the lakeshore. The ${make} for the days when the drive is the point.`;
  if (/coupe/.test(b)) return `A ${make} for the days when the drive is the point, with a low seat and a bit of life in the steering.`;
  if (/suv|sport utility|crossover/.test(b)) return `A high seat, a big boot and room for ${seats || 'the family'}${awd ? ', with all-wheel drive for whatever February brings' : ''}. Good for weekends out of the city.`;
  if (/hatch|wagon|liftback/.test(b)) return `Easy to park downtown, with a wide opening at the back for bags, groceries and a stroller.`;
  return `A comfortable ${make} sedan with room for ${seats || 'four adults'} and a proper trunk. Easy to park in the city and quiet on the highway.`;
}

/** The same plain copy the database writes (app.car_copy_template), for the listing pipeline's draft step, which no
 *  longer calls the model: the search job writes the real copy. */
export function plainDraft(f: { year?: number; make?: string; model?: string; trim?: string; colour?: string; seats?: number; transmission?: string; fuel?: string; drivetrain?: string; body_style?: string; home_area?: string; equipment_known?: string[] }) {
  const name = [f.year, f.make, f.model].filter(Boolean).join(' ');
  const headline = carHeadline(f as Record<string, unknown>);
  const description = plainBlurb(f);
  const features = (f.equipment_known ?? []).slice(0, LIMITS.highlights[1]);
  for (const x of ['Bluetooth', 'Air conditioning', 'Cruise control']) if (features.length < 3 && !features.includes(x)) features.push(x);
  return {
    headline, description, features,
    faq: [
      { question: `How many people fit in the ${f.model ?? 'car'}?`, answer: f.seats ? `It has ${f.seats} seats.` : 'Ask us before you book.', check: false },
      { question: `Where do I pick up the ${f.model ?? 'car'}?`, answer: 'At our location at no charge, or we deliver it to your address.', check: false },
      { question: 'Do I pay when I send a request?', answer: 'No. We confirm the car and the price first, and you pay only when you approve.', check: false }
    ],
    seo_title: `${name} for rent in Toronto`.slice(0, 60),
    seo_description: `Rent this ${name} in Toronto. Pickup or delivery, request with no payment up front.`.slice(0, 155),
    classes: [] as string[]
  };
}
