// Unit tests of the search copy checks and the search job (migration 0061), with the fake model.
//   node --test --experimental-strip-types src/features/seo/copy.test.ts   (npm run test:unit)
import { test } from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import {
  allowedNumbers, articleProblems, carCopyProblems, inventedNumbers, normalizeArticle, normalizeCarCopy, normalizePageCopy, numbersIn,
  pageCopyProblems, similarity, styleProblems, carUserPrompt, plainDraft, plainBlurb, carFixed, fillHighlights, LIMITS, type CarCopy
} from './copy.ts';
import { runSeoJob, type SeoClaim } from './worker.ts';
import { fakeCarCopy, fakeText } from '../../integrations/llm/fake.ts';
import type { TextGenerator } from '../../integrations/llm/types.ts';

export const FACTS = {
  car: { year: 2022, make: 'Chevrolet', model: 'Malibu', trim: 'LS', colour: 'Black', body_style: 'Sedan', seats: 5, doors: 4, fuel: 'Gas', transmission: 'Automatic', drivetrain: 'Front-wheel drive', classes: ['Standard', 'Sedan'],
    equipment_known: ['Backup camera', 'Push-button start', 'Turbocharged engine', 'Automatic high beams', 'LED headlights', 'Bluetooth', 'Air conditioning'], equipment_maybe: ['Apple CarPlay and Android Auto', 'Heated front seats'] },
  prices: { daily: '$69', weekend_day: '$79', weekly: '$420', monthly: '$1,450', monthly_days: 30, km_per_day: 250, extra_km: '$0.35', deposit: '$500', delivery_fee: '$60', return_pickup_fee: '$60', tax: 'HST 13% added' },
  place: { area: 'Pickering', city: 'Toronto', region: 'Ontario', delivery: "Delivered to any address for the car's delivery fee", airports: ['Toronto Pearson International Airport', 'Billy Bishop Toronto City Airport'], pickup: 'Collect it at our location at no charge, or have it delivered' },
  rules: { min_age: 18, young_driver_fee_ages: ['21 to 25'], drivers_18_to_20: false, licence: 'Ontario G or G2 licence', card: "A credit card in the renter's name", identity: 'Licence and identity checked before pickup', max_rental_days: 30, request: 'Request to book with no payment; pay after we confirm' },
  included: ['Third-party liability coverage', 'Roadside assistance, 24 hours a day', '250 km a day', 'Handover in person with a walk-around of the car'],
  photos: ['front_left', 'rear', 'dashboard'],
  brand: 'CarmaCars'
};
const good = (): CarCopy => normalizeCarCopy(fakeCarCopy(carUserPrompt(FACTS)))!;

test('numbers: amounts, thousands, decimals and spelled numbers are normalized', () => {
  assert.deepEqual(numbersIn('$1,450.00 for 30 days, $0.35 a km, five seats and 2.50'), ['1450', '30', '0.35', '2.5', '5']);
  const ok = allowedNumbers(FACTS);
  for (const n of ['2022', '69', '1450', '0.35', '250', '24', '13', '18', '21', '25', '30', '5', '4']) assert.ok(ok.has(n), n);
  assert.deepEqual(inventedNumbers('From $69 a day, or $59 on weekdays, with 7 seats', ok), ['59', '7']);
});

test('car copy: the fake answer built from the facts passes every check', () => {
  const c = good();
  assert.deepEqual(carCopyProblems(c, FACTS), []);
  assert.ok(c.seo_title.length <= LIMITS.seo_title[1] && c.meta_description.length <= LIMITS.meta_description[1]);
  assert.deepEqual(Object.keys(c.alt_texts).sort(), ['dashboard', 'front_left', 'rear']);
});

test('car copy: lengths, the brand, dashes, AI words and exclamation marks are refused', () => {
  const c = { ...good(), seo_title: 'Rent the 2022 Chevrolet Malibu LS in Toronto today at Carmacars for less', intro: good().intro + ' It is a seamless ride — you will love it!' };
  const p = carCopyProblems(c, FACTS).join(' | ');
  assert.match(p, /search title.*25 to 60/);
  assert.match(p, /em dash/);
  assert.match(p, /exclamation/);
  assert.match(p, /"seamless"/);
  assert.match(p, /exactly as CarmaCars/);
});

test('car copy: a number not in the facts, equipment, economy or condition not in the facts are refused', () => {
  const c = { ...good(), highlights: [...good().highlights.slice(0, 3), 'Heated seats and Apple CarPlay'], intro: good().intro + ' It costs $59 on weekdays, is good on gas and like new.' };
  const p = carCopyProblems(c, FACTS).join(' | ');
  assert.match(p, /numbers are not in the facts: 59/);
  assert.match(p, /equipment \("Heated seats"\)/);
  assert.match(p, /fuel economy/);
  assert.match(p, /condition/);
  // the same equipment is fine when the facts list it
  const withEq = { ...FACTS, car: { ...FACTS.car, equipment: ['Heated seats', 'Apple CarPlay'] } };
  assert.doesNotMatch(carCopyProblems({ ...good(), highlights: [...good().highlights.slice(0, 3), 'Heated seats and Apple CarPlay'] }, withEq).join(' | '), /do not claim equipment/);
});

test('car copy: the Protection Plan wording, the numbered company and private details are refused', () => {
  for (const bad of ['Add rental insurance through us at checkout.', 'Full coverage is included.', 'Owned by 18122211 Canada Inc.', 'The VIN is on the door.']) {
    const p = carCopyProblems({ ...good(), pickup_delivery: `${good().pickup_delivery} ${bad}` }, FACTS);
    assert.ok(p.length > 0, bad);
  }
  assert.deepEqual(styleProblems('Third-party liability coverage is included in the rate.'), []);
});

test('car copy: unique text: an intro that repeats another car of the same model is refused', () => {
  const c = good();
  assert.ok(similarity(c.intro, c.intro) > 0.99);
  assert.match(carCopyProblems(c, FACTS, { others: [c.intro] }).join(' '), /repeats another car's page/);
  assert.deepEqual(carCopyProblems(c, FACTS, { others: ['A white Toyota Corolla kept in Scarborough with a big trunk and easy parking for the city.'] }), []);
});

test('car copy: a field a person locked is not judged and is kept by the job', async () => {
  const c = { ...good(), h1: 'Our black Malibu — with a dash a person typed' };
  assert.match(carCopyProblems(c, FACTS).join(' '), /em dash/);
  assert.doesNotMatch(carCopyProblems(c, FACTS, { skip: ['h1'] }).join(' '), /em dash|heading/);
});

test('car copy: missing alt texts and a heading without the model are refused', () => {
  const p = carCopyProblems({ ...good(), h1: 'A black sedan rental in Toronto', alt_texts: { front_left: 'A car' } }, FACTS).join(' | ');
  assert.match(p, /alt_texts is missing these photos: rear, dashboard/);
  assert.match(p, /heading must name the model/);
});

test('landing page: prices are never typed, numbers come from the facts, sections and questions are counted', () => {
  const pg = { name: 'Mississauga', facts: { highways: ['401', '403', 'QEW'], drive_minutes: '25 to 40' } };
  const base = normalizePageCopy({ seo_title: 'Car Rental in Mississauga | CarmaCars', meta_description: 'Rent a car in Mississauga with delivery to your address or Square One, or pick it up from us. Request with no payment up front.',
    h1: 'Car rental in Mississauga', intro: 'Mississauga sits west of Toronto along the 401 and the 403. '.repeat(6), sections: [{ heading: 'Delivery', body: 'We bring the car to your door in Mississauga. '.repeat(8) }, { heading: 'Roads', body: 'The 401, the 403 and the QEW connect Mississauga to Toronto. '.repeat(5) }],
    faq: [{ question: 'Do you deliver?', answer: 'Yes.' }, { question: 'How long?', answer: 'About 25 to 40 minutes.' }, { question: 'Can I pay later?', answer: 'You pay after we confirm.' }] })!;
  assert.deepEqual(pageCopyProblems(base, pg), []);
  const p = pageCopyProblems({ ...base, intro: base.intro + ' Cars from $49 a day, 15 minutes away, unlimited kilometres.' }, pg).join(' | ');
  assert.match(p, /write no prices/);
  assert.match(p, /15/);
  assert.match(p, /unlimited kilometres/);
});

test('article: tokens must be known, fees are tokens, headings and length are checked', () => {
  const body = '## What you need\n\n' + 'You need a licence and a card. '.repeat(60) + '\n\n## Fees\n\nThe toll fee is {{tollFee}} for each notice.\n\n## Delivery\n\n' + 'We deliver anywhere. '.repeat(40) + '\n';
  const a = normalizeArticle({ title: 'Renting a car in Toronto as a young driver', description: 'What drivers aged 18 to 24 need to rent a car in Toronto: licence, age fees, deposit and the steps from request to pickup.', body_md: body, faq: [] })!;
  assert.deepEqual(articleProblems(a, { tokens: ['tollFee'] }), []);
  const p = articleProblems({ ...a, body_md: a.body_md + '\nThe fee is $15 and {{nope}} applies.\n' }, { tokens: ['tollFee'] }).join(' | ');
  assert.match(p, /unknown tokens: nope/);
  assert.match(p, /typed amount/);
});

test('plain draft (listing pipeline, no model) passes the listing lint ranges of 0061', () => {
  const d = plainDraft({ year: 2021, make: 'Kia', model: 'Rio', seats: 5, transmission: 'automatic', fuel: 'gasoline', body_style: 'Hatchback', colour: 'Red', home_area: 'Etobicoke' });
  assert.ok(d.headline.length >= 20 && d.headline.length <= 70);
  const w = d.description.split(/\s+/).length;
  assert.ok(w >= 8 && w <= 40, String(w));        // the sample cars' short blurb (0073)
  assert.match(d.headline, /^2021 Kia Rio for rent in Toronto$/);
  assert.doesNotMatch(d.description, /Etobicoke|kept in/);
  assert.ok(d.features.length >= 3 && d.faq.length >= 3);
});

test('car copy v2 (0073): the samples\' format: headline, short blurb, six offered features, nothing about where the car is kept', () => {
  const f = carFixed(FACTS);
  assert.equal(f.h1, '2022 Chevrolet Malibu LS for rent in Toronto');
  assert.ok(f.seo_title.length <= 60 && f.meta_description.length >= 90 && f.meta_description.length <= 155, f.meta_description);
  assert.doesNotMatch(f.pickup_delivery, /Pickering|kept/);
  assert.deepEqual(fillHighlights(['Apple CarPlay and Android Auto', 'Leather seats', 'backup camera'], FACTS),
    ['Apple CarPlay and Android Auto', 'Backup camera', 'Push-button start', 'Turbocharged engine', 'Automatic high beams', 'LED headlights']);
  const base = { ...good(), ...f, intro: 'Room for five and a proper trunk. Easy to park downtown and quiet on the highway.', highlights: fillHighlights([], FACTS) };
  assert.deepEqual(carCopyProblems(base, FACTS), []);
  assert.match(carCopyProblems({ ...base, intro: 'This car is a 2022 Chevrolet Malibu LS. It is black and kept in Pickering.' }, FACTS).join(' | '), /where the car is kept.*This car/);
  assert.match(carCopyProblems({ ...base, highlights: [...base.highlights.slice(0, 5), '5 seats'] }, FACTS).join(' | '), /word for word.*"5 seats"/);
  assert.match(carCopyProblems({ ...base, intro: base.intro + ' ' + base.intro + ' ' + base.intro }, FACTS).join(' | '), /intro must be 8 to 40 words/);
  const p = carUserPrompt(FACTS);
  assert.match(p, /Room for four adults and their bags/);
  assert.match(p, /standard on every 2022 Chevrolet Malibu LS sold in Canada/);
  assert.doesNotMatch(plainBlurb({ make: 'Chevrolet', model: 'Malibu', seats: 5, body_style: 'Sedan' }), /\b(kept|Pickering|This car)\b/);
});

// ---------------------------------------------------------------- the job
function claim(over: Partial<SeoClaim> = {}): SeoClaim {
  return { cars: [{ vehicle_id: 'v1', slug: 'chevrolet-malibu-ab12', facts: FACTS, locked: [], current: {}, others: [], all_intros: [] }], pages: [], articles: [], ai: true, max_attempts: 3,
    similarity_max_bps: 5000, banned: ['look no further'], indexnow: { enabled: true, key: 'a'.repeat(32), paths: ['/cars/chevrolet-malibu-ab12'] }, budget: {}, due: {}, ...over };
}

test('job: a valid answer is published; IndexNow gets the changed addresses', async () => {
  const reports: Array<Record<string, unknown>> = [];
  let sentTo: string[] = [];
  const s = await runSeoJob({ claim: async () => claim(), report: async (r) => { reports.push(r); }, text: fakeText(), tokens: async () => ({}),
    indexNow: async (_k, paths) => { sentTo = paths; return { status: 200 }; }, sent: async () => undefined });
  assert.equal(reports[0]!.ok, true);
  assert.equal(reports[0]!.prompt_version, 'car-copy-v2');
  assert.deepEqual(s.changed, ['/cars/chevrolet-malibu-ab12']);
  assert.deepEqual(sentTo, ['/cars/chevrolet-malibu-ab12']);
  assert.equal(s.indexnow, 1);
});

test('job: a failing answer is asked again with the problems named, the last time strictly; then reported failed with the problems', async () => {
  const prompts: string[] = []; const temps: number[] = [];
  const bad: TextGenerator = { name: 'fake', model: 'bad', async generate(req) { prompts.push(req.prompt); temps.push(req.temperature ?? -1); const c = fakeCarCopy(req.prompt); return { ok: true, data: { ...c, intro: `${String(c.intro)} Only $49 today!` } as never, model: 'bad', usage: { inputTokens: 1, outputTokens: 1, neurons: 7 } }; } };
  const reports: Array<Record<string, unknown>> = [];
  await runSeoJob({ claim: async () => claim({ indexnow: { enabled: false, key: '', paths: [] } }), report: async (r) => { reports.push(r); }, text: bad, tokens: async () => ({}) });
  assert.equal(prompts.length, 3);
  assert.match(prompts[1]!, /Fix every one:[\s\S]*49/);
  assert.match(prompts[1]!, /Fix every one:[\s\S]*exclamation/);
  assert.match(prompts[2]!, /Be strict/);
  assert.equal(temps[2], 0);
  assert.equal(reports[0]!.ok, false);
  assert.equal(reports[0]!.neurons, 21);
  assert.match(String((reports[0]!.problems as string[]).join(' ')), /49/);
});

test('job: the model out of neurons stops at once; nothing is published', async () => {
  let n = 0;
  const quota: TextGenerator = { name: 'workers-ai', model: 'm', async generate() { n++; return { ok: false, reason: 'quota', message: '4006 daily allocation' }; } };
  const reports: Array<Record<string, unknown>> = [];
  await runSeoJob({ claim: async () => claim({ indexnow: { enabled: false, key: '', paths: [] } }), report: async (r) => { reports.push(r); }, text: quota, tokens: async () => ({}) });
  assert.equal(n, 1);
  assert.equal(reports[0]!.ok, false);
  assert.match(String(reports[0]!.error), /quota/);
});

test('job: locked fields come back exactly as the person wrote them', async () => {
  const reports: Array<Record<string, unknown>> = [];
  const mine = 'Our black Malibu for city errands and highway runs';
  await runSeoJob({ claim: async () => claim({ cars: [{ vehicle_id: 'v1', facts: FACTS, locked: ['h1'], current: { h1: mine }, others: [], all_intros: [] }], indexnow: { enabled: false, key: '', paths: [] } }),
    report: async (r) => { reports.push(r); }, text: fakeText(), tokens: async () => ({}) });
  assert.equal((reports[0]!.copy as CarCopy).h1, mine);
});

// ---------------------------------------------------------------- the seeded pages and articles pass the same checks
test('seed: every landing page and article written for launch passes the checks', () => {
  const file = path.join(path.dirname(fileURLToPath(import.meta.url)), '../../../scripts/content/seo-content.json');
  const seed = JSON.parse(fs.readFileSync(file, 'utf8')) as { pages: Array<{ slug: string; name: string; kind: string; facts: Record<string, unknown>; copy: unknown }>; articles: Array<{ slug: string; title: string; description: string; body_md: string; faq: unknown }>; tokens: string[] };
  assert.ok(seed.pages.length >= 24, `${seed.pages.length} pages`);
  assert.ok(seed.articles.length >= 8, `${seed.articles.length} articles`);
  const intros: string[] = [];
  for (const p of seed.pages) {
    const c = normalizePageCopy(p.copy);
    assert.ok(c, p.slug);
    assert.deepEqual(pageCopyProblems(c!, p, { others: intros, tokens: seed.tokens }), [], p.slug);
    intros.push(c!.intro + ' ' + c!.sections.map((s) => s.body).join(' '));
  }
  for (const a of seed.articles) {
    const n = normalizeArticle(a);
    assert.ok(n, a.slug);
    assert.deepEqual(articleProblems(n!, { tokens: seed.tokens }), [], a.slug);
  }
});
