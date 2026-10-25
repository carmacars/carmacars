// Unit tests of the search copy batch (migration 0133, docs/seo-batches.md): the queue items and the checks of the
// import, which are the website's own (copy.ts) plus service promises and uniqueness within the batch.
//   node --test --experimental-strip-types src/features/seo/batch.test.ts   (npm run test:unit)
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { buildQueue, checkBatch, checkItem, queueItem, refsOf, servicePromises, type RawItem } from './batch.ts';
import { carUserPrompt } from './copy.ts';
import { fakeCarCopy } from '../../integrations/llm/fake.ts';

const FACTS = {
  car: { year: 2022, make: 'Chevrolet', model: 'Malibu', trim: 'LS', colour: 'Black', body_style: 'Sedan', seats: 5, doors: 4, fuel: 'Gas', transmission: 'Automatic', drivetrain: 'Front-wheel drive', classes: ['Standard', 'Sedan'],
    equipment_known: ['Backup camera', 'Push-button start', 'Turbocharged engine', 'Automatic high beams', 'LED headlights', 'Bluetooth', 'Air conditioning'], equipment_maybe: ['Apple CarPlay and Android Auto', 'Heated front seats'] },
  prices: { daily: '$69', weekly: '$420', deposit: '$500', delivery_fee: '$60', tax: 'HST 13% added' },
  place: { area: 'Pickering', city: 'Toronto', region: 'Ontario', pickup: 'Collect it at our location at no charge, or have it delivered' },
  rules: { min_age: 18, licence: 'Ontario G or G2 licence', card: "A credit card in the renter's name", identity: 'Licence and identity checked before pickup', max_rental_days: 30 },
  included: ['Third-party liability coverage', 'Roadside assistance, 24 hours a day', '250 km a day', 'Handover in person with a walk-around of the car'],
  photos: ['front_left', 'rear', 'dashboard'],
  brand: 'CarmaCars'
};
const CAR: RawItem = { kind: 'car', id: '00000000-0000-0000-0000-0000000000c1', url: '/cars/2022-chevrolet-malibu', page_type: 'car', name: '2022 Chevrolet Malibu', facts: FACTS, locked: [], current: {}, source: 'template', others: [], all_intros: [] };
const carOut = () => ({ kind: 'car' as const, id: CAR.id, copy: fakeCarCopy(carUserPrompt(FACTS)) });

const PAGE: RawItem = { kind: 'page', id: 'mississauga', url: '/car-rental/mississauga', page_type: 'location', name: 'Mississauga', city: 'Toronto',
  facts: { highways: ['401', '403', 'QEW'], drive_minutes: '25 to 40' }, locked: [], current: { intro: 'Old {{city}} text.' }, others: [] };
const pageCopy = (intro = 'Mississauga sits west of Toronto along the 401 and the 403. '.repeat(6)) => ({
  seo_title: 'Car Rental in Mississauga | CarmaCars', meta_description: 'Rent a car in Mississauga with delivery to your address or Square One, or pick it up from us. Request with no payment up front.',
  h1: 'Car rental in Mississauga', intro,
  sections: [{ heading: 'Delivery', body: 'We bring the car to your door in Mississauga. '.repeat(8) }, { heading: 'Roads', body: 'The 401, the 403 and the QEW connect Mississauga to Toronto. '.repeat(5) }],
  faq: [{ question: 'Do you deliver?', answer: 'Yes.' }, { question: 'How long?', answer: 'About 25 to 40 minutes.' }, { question: 'Can I pay later?', answer: 'You pay after we confirm.' }] });

test('the queue: each item with its facts, what to write, the word target and the website writer\'s own instructions', () => {
  const q = buildQueue({ items: [PAGE, CAR, { kind: 'article', id: 'winter-driving', url: '/guides/winter-driving', page_type: 'article', name: 'Winter driving', brief: 'Tires in Ontario', current: { title: 'Winter driving', body_md: 'Deposit {{depMin}}.', faq: [] } }], banned: ['cheap'], similarity_max_bps: 5000, waiting: { pages: 1, cars: 1, articles: 1 } }, 500);
  assert.equal(q.count, 3);
  assert.deepEqual(q.items.map((i) => [i.kind, i.priority]), [['page', 1], ['car', 2], ['article', 3]]);
  const car = q.items[1]!;
  assert.deepEqual(car.write, ['intro', 'highlights', 'good_for', 'faq', 'alt_texts']);
  assert.match(car.instructions.prompt, /<facts>.*Malibu/);
  assert.match(car.instructions.system, /CarmaCars/);
  assert.match(q.items[2]!.instructions.system, /\{\{depMin\}\}/);
  assert.deepEqual(q.rules.banned, ['cheap']);
  assert.equal(buildQueue({ items: [PAGE, CAR] }, 1).count, 1);
  assert.equal(queueItem(PAGE, 7).priority, 7);
});

test('a car copy that passes the website\'s checks is published with the site\'s own fixed parts', () => {
  const r = checkItem(CAR, carOut(), { banned: [] });
  assert.equal(r.ok, true, r.ok ? '' : r.problems.join('; '));
  if (r.ok) {
    const c = r.publish.copy as Record<string, unknown>;
    assert.equal(c.h1, '2022 Chevrolet Malibu LS for rent in Toronto');
    assert.equal((c.highlights as string[]).length, 6);
    assert.equal(r.publish.kind, 'car');
  }
});

test('the copy rules: dashes, the brand, a numbered company, invented numbers and claims are refused, with the reasons', () => {
  const o = carOut();
  o.copy = { ...o.copy, intro: 'A quiet sedan for the 401 — from Carmacars, 18122211 Canada Inc. Good on gas, $49 on weekdays!' };
  const r = checkItem(CAR, o);
  assert.equal(r.ok, false);
  const p = r.ok ? '' : r.problems.join(' | ');
  assert.match(p, /em dash/);
  assert.match(p, /exactly as CarmaCars/);
  assert.match(p, /numbered or legal company/);
  assert.match(p, /fuel economy/);
  assert.match(p, /numbers are not in the facts: .*49/);
});

test('landing pages: prices never typed, promises refused, length checked', () => {
  assert.equal(checkItem(PAGE, { kind: 'page', id: 'mississauga', copy: pageCopy() }).ok, true);
  const bad = checkItem(PAGE, { kind: 'page', id: 'mississauga', copy: pageCopy('Cars from $49 a day. We guarantee same-day service and free towing. Short.') });
  const p = bad.ok ? '' : bad.problems.join(' | ');
  assert.match(p, /write no prices/);
  assert.match(p, /intro must be/);
  assert.match(p, /"guarantee"/);
  assert.match(p, /"free towing"/);
});

test('service promises only when the facts state them', () => {
  assert.deepEqual(servicePromises('Free pickup at your door.', {}), ['do not promise "Free pickup": the facts do not say CarmaCars offers it']);
  assert.deepEqual(servicePromises('Free pickup at your door.', { services: ['free pickup'] }), []);
});

test('uniqueness: a page repeating another page, or another item of the same batch, is refused; the same page twice is used once', () => {
  const other = { ...PAGE, others: [pageCopy().intro + ' ' + pageCopy().sections.map((s) => s.body).join(' ')] };
  const r = checkItem(other, { kind: 'page', id: 'mississauga', copy: pageCopy() });
  assert.match(r.ok ? '' : r.problems.join(' '), /repeats another landing page/);
  const brampton: RawItem = { ...PAGE, id: 'brampton', url: '/car-rental/brampton', name: 'Brampton' };
  const res = checkBatch([{ kind: 'page', id: 'mississauga', copy: pageCopy() }, { kind: 'page', id: 'brampton', copy: pageCopy() }, { kind: 'page', id: 'mississauga', copy: pageCopy() }], [PAGE, brampton, PAGE]);
  assert.deepEqual(res.map((x) => x.ok), [true, false, false]);
  assert.match(res[1]!.ok ? '' : (res[1] as { problems: string[] }).problems.join(' '), /repeats another landing page/);
  assert.match(res[2]!.ok ? '' : (res[2] as { problems: string[] }).problems.join(' '), /appears twice/);
});

test('an item for no page, or of the wrong kind, is refused; refs by id or by address', () => {
  assert.match((checkItem({ kind: 'page', id: '', url: null, page_type: '', name: '', missing: true }, { url: '/car-rental/nowhere', copy: {} }) as { problems: string[] }).problems[0]!, /no such page/);
  assert.match((checkItem(PAGE, { kind: 'car', id: 'mississauga', copy: pageCopy() }) as { problems: string[] }).problems[0]!, /kind is page/);
  assert.deepEqual(refsOf([{ kind: 'car', id: 'x' }, { url: '/cars/y' }]), [{ kind: 'car', id: 'x' }, { url: '/cars/y' }]);
});

test('a field a person locked keeps their text', () => {
  const locked = { ...PAGE, locked: ['h1'], current: { h1: 'Rent a car in Mississauga today' } };
  const r = checkItem(locked, { kind: 'page', id: 'mississauga', copy: pageCopy() });
  assert.equal(r.ok && (r.publish.copy as { h1: string }).h1, 'Rent a car in Mississauga today');
});

test('articles: tokens only those the article already uses, no typed prices, unlike the other guides', () => {
  const body = ['## Before you go', 'Winter tires are worth it in Ontario. '.repeat(40), '## The deposit', 'The deposit is {{depMin}}. '.repeat(30), '## On the road', 'Drive slowly on the 401 in snow. '.repeat(40), '## Returning', 'Bring the car back clean. '.repeat(30)].join('\n\n');
  const art: RawItem = { kind: 'article', id: 'winter', url: '/guides/winter', page_type: 'article', name: 'Winter', brief: 'Winter driving in Ontario', locked: [], current: { title: 'Winter', body_md: 'The deposit is {{depMin}} and 401.', faq: [] }, others: [] };
  const out = { kind: 'article' as const, id: 'winter', title: 'Winter driving around Toronto, step by step', description: 'How to rent a car for winter driving around Toronto: tires, the deposit, the roads and the return, in plain steps for renters.', body_md: body,
    faq: [{ question: 'Do I need winter tires?', answer: 'They help a lot in snow.' }, { question: 'Is there a deposit?', answer: 'Yes, {{depMin}}.' }, { question: 'Can I return it dirty?', answer: 'Please bring it back clean.' }] };
  const ok = checkItem(art, out);
  assert.equal(ok.ok, true, ok.ok ? '' : ok.problems.join('; '));
  const bad = checkItem(art, { ...out, body_md: body + '\nThe fee is $25 and {{newToken}}.' });
  const p = bad.ok ? '' : bad.problems.join(' | ');
  assert.match(p, /unknown tokens: newToken/);
  assert.match(p, /never as a typed amount/);
  assert.match((checkItem({ ...art, others: [body] }, out) as { problems: string[] }).problems.join(' '), /repeats another guide/);
});
