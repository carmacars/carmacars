// Release 36: the words of the new page families and the language templates, from their own data only.   npm run test:unit
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { eventCopy, eventWhen } from '../events/copy.ts';
import { airportCopy } from '../airports/copy.ts';
import { loanPayment, ownLines, type OwnInputs } from '../rent-vs-own/calc.ts';
import { CATALOG, protect, restore, translator, validTranslation } from '../i18n/catalog.ts';
import { negativeHits } from './copy-lint.ts';

const E = { name: 'Example Fest', venue: 'Example Park', venue_address: '1 Park Rd, Toronto', city: 'Toronto', usual_months: 'July', starts_on: null, ends_on: null, summary: 'A summer festival in the park.', source_name: 'Example', category: 'festival' };

test('events: "usually in <month>" until the organiser announces the dates, then the dates; never a guessed date', () => {
  assert.deepEqual(eventWhen(E, '2026-11-11'), { text: 'usually in July', announced: false });
  assert.equal(eventWhen({ ...E, starts_on: '2027-07-10', ends_on: '2027-07-12' }, '2026-11-11').text, 'July 10, 2027 to July 12, 2027');
  assert.equal(eventWhen({ ...E, starts_on: '2026-07-10', ends_on: '2026-07-12' }, '2026-11-11').announced, false, 'a past edition reads as usual months again');
  const c = eventCopy(E, 'CarmaCars', '2026-11-11');
  assert.match(c.lead[0]!, /usually in July \(check the organiser/);
  assert.equal(c.h1, 'Rent a car for Example Fest');
  for (const x of [c.title, c.description, ...c.lead, ...c.faq.flatMap((q) => [q.question, q.answer])]) { assert.equal(negativeHits(x).length, 0, x); assert.doesNotMatch(x, /[—–!]/); }
});

test('airports: delivered to the terminal at the standard price, nothing about other companies', () => {
  const c = airportCopy({ code: 'YYZ', name: 'Toronto Pearson International Airport', km: 25, delivery_from_cents: 7500 }, 'CarmaCars');
  assert.match(c.lead.join(' '), /meets you at the terminal/);
  assert.match(c.lead.join(' '), /starts at \$75, the standard delivery price/);
  assert.ok(c.title.length <= 70 && c.description.length <= 165);
  assert.doesNotMatch(JSON.stringify(c), /Routes|offer code|discount/i);
});

test('renting vs owning: each line from a source or a setting, a missing input leaves its line out', () => {
  assert.equal(loanPayment(3_000_000, 799, 60), 60_815);
  assert.equal(loanPayment(1_200_000, 0, 12), 100_000);
  const x: OwnInputs = { apr_bps: 799, term_months: 60, km_per_month: 1500, depreciation_bps: 1500, cleaning_monthly_cents: null, gas_cents: 150, premium_extra_cents: 20, kwh_cents: 15,
    costs: [{ component: 'registration', scope: '', monthly_cents: 0, note: 'No sticker fee.', source: 'Ontario.ca', source_url: 'https://example.test/r' }],
    specs: [{ field: 'msrp_cad', value: '40000', source: 'oem', source_url: 'https://example.test/m' }, { field: 'fuel_combined_l100', value: '8', source: 'fueleconomy_gov', source_url: 'https://example.test/f' }],
    catalog: null, rental: null, rental_any: 150000 };
  const r = ownLines(x, 2024, 2026);
  assert.deepEqual(r.lines.map((l) => l.key), ['financing', 'depreciation', 'fuel', 'registration']);
  assert.equal(r.lines.find((l) => l.key === 'fuel')!.monthly_cents, 18000);
  assert.match(r.lines[0]!.basis, /less 15% a year for 2 years/);
  assert.equal(ownLines({ ...x, specs: [] }, 2024, 2026).lines.some((l) => l.key === 'financing'), false, 'no MSRP, no financing line');
});

test('languages: placeholders are protected through translation and checked after', () => {
  const p = protect('From {price} a day, {count} cars');
  assert.equal(p.text, 'From [[0]] a day, [[1]] cars');
  assert.equal(restore('À partir de [[0]] par jour, [[ 1 ]] voitures', p.names), 'À partir de {price} par jour, {count} voitures');
  assert.ok(validTranslation('From {price} a day', 'À partir de {price} par jour'));
  assert.ok(!validTranslation('From {price} a day', 'À partir de par jour'));
  assert.ok(!validTranslation('From {price} a day', '<b>{price}</b>'));
  const { t, missing } = translator({ 'facts.from': 'À partir de' });
  assert.equal(t('facts.from'), 'À partir de');
  assert.equal(t('common.from_day', { price: '$49' }), 'From $49 a day');
  assert.deepEqual([...missing], ['common.from_day']);
  for (const v of Object.values(CATALOG)) { assert.equal(negativeHits(v).length, 0, v); assert.doesNotMatch(v, /[—–!]/); }
});
