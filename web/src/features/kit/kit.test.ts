// The writing kit's quality gates (docs/changes/2026-10-24-writing-kit.md): every slot filled, the house style and the
// brand rules, honesty by page type, word counts, readability, near-duplicates across 10,000 addresses, and the CPU
// cost per page. Run: npm run test:unit (or node --test --experimental-strip-types src/features/kit/kit.test.ts).
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { AI_WORDS, styleProblems } from '../seo/copy.ts';
import { cond, fillVariant, hash, pick, shuffle } from './engine.ts';
import { PLACES, TERMS, TOKENS, VEHICLES, hubFixture, samplePages, vehicleFixture } from './fixtures.ts';
import { chooseText, LIBRARY, mergeFaq, writeKit, type KitText } from './index.ts';
import { hubKit, vehicleKit } from './pages.ts';
import { PLANS } from './plans.ts';
import type { KitPage } from './facts.ts';

const textOf = (k: KitText) => [...k.sections.flatMap((s) => [s.heading, ...s.paras]), ...k.faq.flatMap((q) => [q.question, q.answer])].join('\n');
const bodyOf = (k: KitText) => k.sections.flatMap((s) => s.paras).join(' ');
const words = (s: string) => (s.trim() ? s.trim().split(/\s+/).length : 0);
const N = Number(process.env.KIT_SAMPLE ?? 10_000);
const SAMPLE: KitPage[] = samplePages(N);
const TEXTS = new Map<string, KitText>();
// CPU time, not wall time (the test machine is shared): the first pass is cold, the second warm, as a Worker isolate is
const cpu = (f: () => void) => { const a = process.cpuUsage(); f(); const d = process.cpuUsage(a); return (d.user + d.system) / 1000; };
const cold: number[] = [];
for (const p of SAMPLE) cold.push(cpu(() => TEXTS.set(p.path, writeKit(p))));
const times: number[] = SAMPLE.map((p) => cpu(() => writeKit(p)));
const totalMs = times.reduce((a, b) => a + b, 0);

// ---------------------------------------------------------------- the engine
test('engine: conditions, optional parts, alternatives, missing facts skip the variant', () => {
  const tags = new Set(['a', 'b']);
  assert.equal(cond('a b')(tags), true); assert.equal(cond('a c')(tags), false); assert.equal(cond('c|b')(tags), true); assert.equal(cond('!c a')(tags), true); assert.equal(cond('!a')(tags), false);
  assert.equal(fillVariant('In {place}[, about {km} km away].', { place: 'Leslieville' }, {}, 's'), 'In Leslieville.');
  assert.equal(fillVariant('In {place}[, about {km} km away].', { place: 'Leslieville', km: 6 }, {}, 's'), 'In Leslieville, about 6 km away.');
  assert.equal(fillVariant('Up to {{maxDays}} days in {place}.', { place: 'X' }, {}, 's'), null, 'a missing token skips the variant');
  assert.equal(fillVariant('{place} has {cars} cars.', { place: 'X' }, {}, 's'), null, 'a missing fact skips the variant');
  const alt = new Set([0, 1, 2, 3, 4, 5, 6, 7].map((i) => fillVariant('<one|two|three> cars.', {}, {}, `seed${i}`)));
  assert.ok(alt.size >= 2, 'alternatives vary by seed');
  const c = { seed: '/x', facts: {}, tokens: {}, tags: new Set<string>(), used: new Set<string>() };
  assert.equal(pick(['#t First.'], 'k', c), 'First.');
  const second = pick(['#t Second.'], 'k2', c);
  assert.equal(second, null, 'a topic already on the page is not said again');
  assert.deepEqual(shuffle([1, 2, 3, 4], 's'), shuffle([1, 2, 3, 4], 's'));
  assert.notEqual(hash('/car-rental/a'), hash('/car-rental/b'));
});

test('library: every bank a plan names exists, every variant is well formed and names known facts and tokens', () => {
  const KNOWN = new Set(['place', 'placeFull', 'region', 'countryName', 'parentCity', 'km', 'reachKm', 'origin', 'deliveryFrom', 'airport', 'airportKm', 'airportCode', 'nearby1', 'nearby2', 'nearbyList',
    'landmark1', 'landmarkList', 'withinList', 'trip1', 'trip1Km', 'trip1What', 'trip2', 'trip2Km', 'trip2What', 'term', 'termLower', 'termNote', 'job', 'service', 'servicePrice', 'cars', 'fromDaily',
    'make', 'model', 'makeModel', 'year', 'trim', 'car', 'aCar', 'colour', 'colourCar', 'aColourCar', 'body', 'aBody', 'vclass', 'similar', 'seats', 'models', 'modelList', 'evModels', 'hybridModels',
    'firstYear', 'lastYear', 'yearsCount', 'bestYear', 'trimList', 'trimCount', 'trimRank', 'trimOf', 'powertrains', 'engine', 'drive', 'trans', 'aTrans', 'l100', 'litres300', 'l100City', 'l100Hwy',
    'kwh100', 'kwh300', 'range', 'rangeTrip', 'rangeTripKm', 'mpg', 'cost100', 'cost300', 'cost1000', 'cargoL', 'cargoPlain', 'battery', 'charge240', 'co2', 'fuelYearUsd', 'premiumPrice', 'lengthM',
    'lengthSize', 'lengthTip', 'energy', 'level', 'widthM', 'weightKg', 'recalls', 'complaints', 'complaintTop', 'forSale']);
  for (const [kind, plan] of Object.entries(PLANS)) {
    for (const s of plan.sections) for (const k of [s.h, ...s.paras.flat()]) assert.ok(LIBRARY[k], `${kind}: bank ${k}`);
    for (const k of plan.faq) assert.ok(LIBRARY[k], `${kind}: faq bank ${k}`);
  }
  for (const [k, bank] of Object.entries(LIBRARY)) {
    assert.ok(bank.length > 0, k);
    for (const v of bank) {
      const text = typeof v === 'string' ? v : v[1];
      assert.equal((text.match(/\[/g) ?? []).length, (text.match(/\]/g) ?? []).length, `${k}: brackets in ${text}`);
      assert.equal((text.match(/</g) ?? []).length, (text.match(/>/g) ?? []).length, `${k}: alternatives in ${text}`);
      for (const m of text.matchAll(/\{\{(\w+)\}\}|\{(\w+)\}/g)) {
        if (m[1]) assert.ok(m[1] in TOKENS, `${k}: token ${m[1]}`);
        else assert.ok(KNOWN.has(m[2]!), `${k}: fact ${m[2]}`);
      }
    }
  }
});

// ---------------------------------------------------------------- determinism
test('the same address always gets the same words; a neighbouring address different ones', () => {
  const p = SAMPLE[0]!;
  assert.deepEqual(writeKit(p), writeKit(p));
  const a = hubKit(hubFixture(PLACES[2]!, TERMS[1]!), 'Port Credit, Mississauga', TOKENS);
  const b = hubKit(hubFixture(PLACES[3]!, TERMS[1]!), 'Markham', TOKENS);
  assert.notEqual(textOf(writeKit(a)).replace(/Port Credit|Mississauga|Markham/g, ''), textOf(writeKit(b)).replace(/Port Credit|Mississauga|Markham/g, ''));
});

// ---------------------------------------------------------------- house style and brand rules on every sampled page
const DASH = /[‒–—―]/;
const EQUIPMENT = /\b(heated (front )?seats?|heated steering|sunroof|moonroof|panoramic roof|apple carplay|android auto|carplay|navigation system|built-in navigation|leather seats|backup camera|rear camera|blind[- ]spot (monitor|warning)|lane[- ]keep|adaptive cruise|remote start|wireless charging|third row|tow hitch|roof rack|bluetooth)\b/i;
const CONDITION = /\b(new car|brand new|low mileage|low kilometres|well[- ]maintained|immaculate|spotless|mint condition|like new)\b/i;
const PROMISE = /\b(free cancellation|no deposit|unlimited (km|kilometres|mileage)|no hidden fees|lowest price|cheapest|best price|price match|guarantee[ds]?|always available|available now|in stock|ready today)\b/i;
const PRAISE = /\b(\d(\.\d)? stars?|five[- ]star|award|top[- ]rated|best[- ]rated|number one|#1|most trusted|loved by|customers love|our customers say)\b/i;
test(`house style on ${N.toLocaleString('en-CA')} pages: no slot left, no dash, no banned word, no claim, the brand right`, () => {
  const problems: string[] = [];
  for (const [path, k] of TEXTS) {
    const t = textOf(k);
    const add = (why: string) => problems.length < 30 && problems.push(`${path}: ${why}`);
    if (/[{}[\]<>|]|#\w/.test(t)) add(`unfilled slot: ${/.{0,40}[{}[\]<>|#].{0,40}/.exec(t)?.[0]}`);
    if (DASH.test(t)) add('a dash');
    const sp = styleProblems(t);
    if (sp.length) add(sp.join('; '));
    for (const re of [EQUIPMENT, CONDITION, PROMISE, PRAISE]) { const m = re.exec(t); if (m) add(`claim "${m[0]}"`); }
    if (/18122211|canada inc\b/i.test(t)) add('numbered company');
    for (const s of t.split(/(?<=[.?])\s+/)) if (/Protection Plan/.test(s) && /insurance|insurer/i.test(s)) add(`Protection Plan beside insurance: ${s}`);
    if (/\bundefined\b|\bnull\b|NaN/.test(t)) add('a raw value');
    if (/\s[,.]/.test(t) || /\.\./.test(t)) add('spacing or punctuation');
  }
  assert.deepEqual(problems, []);
  assert.ok(AI_WORDS.length > 40);
});

// ---------------------------------------------------------------- honesty by page type
test('honesty: far places say we are in Toronto; arranged work is never ours and never mentions insurance; buying help never sells', () => {
  const problems: string[] = [];
  for (const p of SAMPLE) {
    const k = TEXTS.get(p.path)!;
    const t = textOf(k);
    const add = (why: string) => problems.length < 30 && problems.push(`${p.path}: ${why}`);
    if (p.kind.startsWith('hub-') && p.tags.has('far') && p.tags.has('local')) {
      if (!/Toronto/.test(t) || !/(no location|no branch|none in|not in |more than our delivery|not an area we serve|do not have a location|no CarmaCars (branch|location)|outside (the|our) area|rent from Toronto only|no office|outside (the|our)|beyond|past the|does not deliver|do not deliver|works? (only )?in the Toronto area|works from Toronto|does not operate|no presence|not somewhere|no CarmaCars office|will not find|CarmaCars is not in)/i.test(t)) add('far place without the honest line');
      if (new RegExp(`(we deliver to ${p.values.place}|delivered to your door in ${p.values.place}|brings? (the |rental )?cars? to ${p.values.place})`, 'i').test(t)) add('far place promised delivery');
    }
    if (p.kind === 'hub-auto' || p.kind === 'twin-auto') {
      if (/insurance|insurer|adjuster/i.test(t)) add('insurance on arranged work');
      if (!/(does not do (this|the) work|not do mechanical work|never by CarmaCars|not by CarmaCars|do not do the work)/i.test(t)) add('arranged work without "not our work"');
      if (/\b(our mechanics|we repair|we fix|our technicians|our shop)\b/i.test(t)) add('claims the work');
      if (k.faq.length) add('questions on arranged work');
    }
    if (p.kind === 'hub-sale' || (p.kind === 'twin-sale' && p.tags.has('notforsale'))) {
      if (!/(do not sell|does not sell|not a dealer|rents cars|rental company|is not where you buy|does not offer it|not have the .* for sale|no .* for sale|none for sale)/i.test(t)) add('buying help without "we do not sell"');
    }
    if (/(t-finance|t-lease)/.test([...p.tags].join(' ')) && p.kind.endsWith('sale') && !/(not a lender|not a leasing|do not lease|does not (finance|lease|lend)|do not (lend|arrange loans|check credit)|car loans; CarmaCars does not|offer leases; CarmaCars does not|does not sell, finance or lease|not a dealer, a lender|do not sell, finance or lease)/i.test(t)) add('financing or leasing without the plain no');
    if (!p.tags.has('price') && /\$\d+ a day/.test(t)) add('a daily price without a real rate');
  }
  assert.deepEqual(problems, []);
});

// ---------------------------------------------------------------- word counts and readability
function syllables(w: string): number {
  const x = w.toLowerCase().replace(/[^a-z]/g, '');
  if (!x) return 0;
  if (x.length <= 3) return 1;
  const m = x.replace(/(?:[^laeiouy]es|ed|[^laeiouy]e)$/, '').replace(/^y/, '').match(/[aeiouy]{1,2}/g);
  return Math.max(1, m ? m.length : 1);
}
export function flesch(text: string): number {
  const sentences = text.split(/(?<=[.?])\s+/).filter((s) => /[a-z]/i.test(s));
  const ws = text.split(/\s+/).filter((w) => /[a-z]/i.test(w));
  const syl = ws.reduce((n, w) => n + syllables(w), 0);
  return 206.835 - 1.015 * (ws.length / Math.max(1, sentences.length)) - 84.6 * (syl / Math.max(1, ws.length));
}
const STATS: Record<string, { n: number; words: number[]; fre: number[]; under: number; over: number }> = {};
for (const p of SAMPLE) {
  const k = TEXTS.get(p.path)!;
  const st = (STATS[p.kind] ??= { n: 0, words: [], fre: [], under: 0, over: 0 });
  st.n++; st.words.push(k.words); st.fre.push(flesch(bodyOf(k)));
  const [lo, hi] = PLANS[p.kind].words;
  if (k.words < lo) st.under++;
  if (k.words > hi) st.over++;
}
test('word counts: within each type\'s range (none over; at most 5% under, on pages with few facts)', () => {
  const rows: string[] = [];
  for (const [kind, st] of Object.entries(STATS)) {
    const sorted = [...st.words].sort((a, b) => a - b);
    rows.push(`${kind}: ${st.n} pages, words min ${sorted[0]} median ${sorted[Math.floor(sorted.length / 2)]} max ${sorted[sorted.length - 1]}, under ${st.under}, over ${st.over}`);
  }
  console.log(rows.join('\n'));
  for (const [kind, st] of Object.entries(STATS)) {
    assert.equal(st.over, 0, `${kind} over its range`);
    assert.ok(st.under / st.n <= 0.05, `${kind}: ${st.under} of ${st.n} under ${PLANS[kind as keyof typeof PLANS].words[0]} words`);
  }
});
test('readability: plain English (Flesch reading ease 50 or more on average) and no sentence over 40 words', () => {
  const rows: string[] = [];
  for (const [kind, st] of Object.entries(STATS)) {
    const avg = st.fre.reduce((a, b) => a + b, 0) / st.fre.length;
    rows.push(`${kind}: Flesch ${avg.toFixed(1)}`);
  }
  console.log(rows.join('\n'));
  for (const [kind, st] of Object.entries(STATS)) { const avg = st.fre.reduce((a, b) => a + b, 0) / st.fre.length; assert.ok(avg >= 50, `${kind}: Flesch ${avg.toFixed(1)}`); }
  for (const [path, k] of TEXTS) for (const s of bodyOf(k).split(/(?<=[.?])\s+/)) assert.ok(words(s) <= 40, `${path}: ${s}`);
});

// ---------------------------------------------------------------- near-duplicates (MinHash over five-word shingles)
const PERM = 128, BANDS = 32, ROWS = PERM / BANDS;
function shingles(text: string): Set<string> {
  const w = text.toLowerCase().replace(/[^a-z0-9$ ]+/g, ' ').split(/\s+/).filter(Boolean);
  const out = new Set<string>();
  for (let i = 0; i + 5 <= w.length; i++) out.add(w.slice(i, i + 5).join(' '));
  return out;
}
function minhash(sh: Set<string>): Uint32Array {
  const sig = new Uint32Array(PERM).fill(0xffffffff);
  for (const s of sh) {
    const h1 = hash(s), h2 = hash(`${s}#`) | 1;
    for (let i = 0; i < PERM; i++) { const v = (h1 + Math.imul(i, h2)) >>> 0; if (v < sig[i]!) sig[i] = v; }
  }
  return sig;
}
const est = (a: Uint32Array, b: Uint32Array) => { let k = 0; for (let i = 0; i < PERM; i++) if (a[i] === b[i]) k++; return k / PERM; };
test(`uniqueness: near-duplicate rate across ${N.toLocaleString('en-CA')} addresses below 1% (MinHash similarity 0.5 or more)`, () => {
  const sigs = SAMPLE.map((p) => minhash(shingles(bodyOf(TEXTS.get(p.path)!))));
  const buckets = new Map<string, number[]>();
  sigs.forEach((s, i) => { for (let b = 0; b < BANDS; b++) { const key = `${b}:${Array.from(s.slice(b * ROWS, (b + 1) * ROWS)).join(',')}`; (buckets.get(key) ?? buckets.set(key, []).get(key)!).push(i); } });
  const dup = new Set<number>(); let pairs = 0; let maxSim = 0; let example = '';
  const seen = new Set<string>();
  for (const list of buckets.values()) {
    if (list.length < 2 || list.length > 400) continue;
    for (let x = 0; x < list.length; x++) for (let y = x + 1; y < list.length; y++) {
      const i = list[x]!, j = list[y]!; const k = `${i},${j}`;
      if (seen.has(k)) continue; seen.add(k);
      const s = est(sigs[i]!, sigs[j]!);
      if (s > maxSim) { maxSim = s; example = `${SAMPLE[i]!.path} ~ ${SAMPLE[j]!.path}`; }
      if (s >= 0.5) { pairs++; dup.add(i); dup.add(j); }
    }
  }
  // the mean similarity of random pairs of the same type, and of neighbours (same term or car, another place)
  let rs = 0, rn = 0;
  for (let i = 0; i < 4000; i++) { const a = hash(`ra${i}`) % SAMPLE.length, b = hash(`rb${i}`) % SAMPLE.length; if (a !== b && SAMPLE[a]!.kind === SAMPLE[b]!.kind) { rs += est(sigs[a]!, sigs[b]!); rn++; } }
  const nb: number[] = [];
  for (let i = 0; i < 40; i++) {
    const t = TERMS[i % 10]!, p1 = PLACES[2 + (i % 4)]!, p2 = PLACES[3 + (i % 4)]!;
    const a = writeKit(hubKit(hubFixture(p1, t), p1.name, TOKENS)), b = writeKit(hubKit(hubFixture(p2, t), p2.name, TOKENS));
    nb.push(est(minhash(shingles(bodyOf(a))), minhash(shingles(bodyOf(b)))));
  }
  const rate = dup.size / SAMPLE.length;
  (globalThis as { KIT_UNIQ?: string }).KIT_UNIQ = `${rate}`;
  const byKind: Record<string, number> = {};
  for (const i of dup) byKind[SAMPLE[i]!.kind] = (byKind[SAMPLE[i]!.kind] ?? 0) + 1;
  console.log(`near-duplicates by type: ${Object.entries(byKind).map(([k, n]) => `${k} ${n}`).join(', ') || 'none'}`);
  console.log(`near-duplicates: ${dup.size} of ${SAMPLE.length} pages (${(rate * 100).toFixed(2)}%), ${pairs} pairs at 0.5 or more; highest ${maxSim.toFixed(2)} (${example}); random same-type pairs ${(rs / Math.max(1, rn)).toFixed(3)}; neighbours ${(nb.reduce((a, b) => a + b, 0) / nb.length).toFixed(3)}`);
  assert.ok(rate < 0.01, `near-duplicate rate ${(rate * 100).toFixed(2)}%`);
});

// ---------------------------------------------------------------- CPU
test('CPU: well under 5 ms a page (the Worker\'s budget), measured on the whole sample', () => {
  const sorted = [...times].sort((a, b) => a - b);
  const p50 = sorted[Math.floor(sorted.length * 0.5)]!, p99 = sorted[Math.floor(sorted.length * 0.99)]!;
  const coldMean = cold.reduce((a, b) => a + b, 0) / cold.length, coldMax = Math.max(...cold);
  console.log(`CPU: ${SAMPLE.length} pages, warm mean ${(totalMs / SAMPLE.length).toFixed(3)} ms, p50 ${p50.toFixed(3)} ms, p99 ${p99.toFixed(3)} ms; cold pass mean ${coldMean.toFixed(3)} ms, first-page worst ${coldMax.toFixed(2)} ms`);
  assert.ok(totalMs / SAMPLE.length < 1, 'mean under 1 ms');
  assert.ok(p99 < 5, 'p99 under 5 ms');
});

// ---------------------------------------------------------------- precedence and questions
test('precedence: written text wins over the kit; the kit fills when nothing is written; questions merge without repeats', () => {
  const k = writeKit(SAMPLE[0]!);
  assert.equal(chooseText(null, k).source, 'kit');
  assert.equal(chooseText({ sections: [] }, k).source, 'kit');
  const w = chooseText({ sections: [{ heading: 'Our take', body: 'One.\n\nTwo.' }], faq: [{ question: 'Q?', answer: 'A.' }] }, k);
  assert.equal(w.source, 'written'); assert.deepEqual(w.sections[0]!.paras, ['One.', 'Two.']);
  const m = mergeFaq([{ question: 'Do I pay when I send a request?', answer: 'No.' }], [{ question: 'Do I pay when I send a request?', answer: 'x' }, { question: 'Other?', answer: 'y' }]);
  assert.deepEqual(m.map((q) => q.question), ['Do I pay when I send a request?', 'Other?']);
});

test('fixtures: a page of each type writes text', () => {
  const v = VEHICLES[0]!;
  for (const lv of ['make', 'model', 'year', 'trim'] as const) assert.ok(writeKit(vehicleKit(vehicleFixture(v, { level: lv }), TOKENS)).sections.length >= 4, lv);
  const kinds = new Set(SAMPLE.map((p) => p.kind));
  for (const k of Object.keys(PLANS)) assert.ok(kinds.has(k as keyof typeof PLANS), `the sample has ${k}`);
});
