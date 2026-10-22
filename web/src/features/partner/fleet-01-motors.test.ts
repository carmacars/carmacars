import { test } from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { CARS, CHAUFFEUR, SHEET_CHAUFFEUR, SHEET_RENTALS, chauffeurCharge, chauffeurSplit, parseSheet, partnerSplit, rateCard, renterCents, rentalCharge } from './fleet-01-motors.ts';

const text = readFileSync(new URL('./fixtures/01-motors-price-sheet.txt', import.meta.url), 'utf8');

test('the price sheet parses to every row of both columns: 62 rental cars and 11 chauffeur vehicles', () => {
  const p = parseSheet(text);
  assert.equal(p.rentals.length, 62);
  // left column: 24 Mercedes then 13 BMW; right column: 25 more
  assert.equal(p.rentals.filter((r) => r.name.startsWith('Mercedes')).length, 24);
  assert.equal(p.rentals.filter((r) => r.name.startsWith('BMW')).length, 13);
  const sort = (a: { name: string }, b: { name: string }) => a.name.localeCompare(b.name);
  assert.deepEqual([...p.rentals].sort(sort), [...SHEET_RENTALS].sort(sort));
  assert.equal(p.chauffeur.length, 11);
  assert.deepEqual(p.chauffeur, SHEET_CHAUFFEUR);
  // names are unique, so the import is keyed by name
  assert.equal(new Set(p.rentals.map((r) => r.name)).size, 62);
});

test('every row is a car with make, model, trim and colour in proper case, no capitals', () => {
  assert.equal(CARS.length, 62);
  const c43 = CARS.find((c) => c.sheet === 'Mercedes C43 AMG Blue')!;
  assert.deepEqual([c43.make, c43.model, c43.trim, c43.colour], ['Mercedes-Benz', 'C-Class', 'C43 AMG', 'Blue']);
  for (const c of CARS) {
    for (const w of [c.make, c.model, c.trim ?? '', c.colour ?? '']) assert.ok(!/^[A-Z]{4,}$/.test(w), `${c.sheet}: ${w}`);
    assert.ok(c.year >= 2015 && c.year <= 2026, c.sheet);
  }
});

test('the 12 cars with insurance included and no credit card needed', () => {
  const flagged = CARS.filter((c) => c.included).map((c) => c.sheet).sort();
  assert.deepEqual(flagged, ['BMW M4 Comp Black', 'BMW M440i Gran Coupe', 'Bentley Bentayga', 'Cadillac Escalade ESV', 'Ferrari California T', 'Lamborghini Urus',
    'Mclaren 570s', 'Mercedes G63 AMG', 'Mercedes GLS600 Maybach', 'Mercedes S580', 'Mercedes S63 AMG', 'Range Rover Autobiography'].sort());
  // the rental S580, not the Maybach
  assert.equal(CARS.find((c) => c.sheet === 'Mercedes S580 Maybach')!.included, false);
});

test('renter price: the sheet rate plus 10%, to the nearest dollar', () => {
  assert.equal(renterCents(14000), 15400);
  assert.equal(renterCents(17500), 19300);   // 192.50 rounds up
  assert.equal(renterCents(22500), 24800);
  assert.equal(renterCents(200000), 220000);
  assert.equal(renterCents(10000, 1500), 11500);
});

test('tiers: 1-2 days at the base rate, 3-6 at the multi-day rate, 7+ at the long-term rate a day', () => {
  const r = SHEET_RENTALS.find((x) => x.name === 'Mercedes C43 AMG Blue')!;
  const c = rateCard(r);
  assert.deepEqual(c, { daily: 27500, weekend: 27500, multi: 24800, weekly: 22000 * 7, monthly: 22000 * 30 });
  assert.deepEqual(rentalCharge(1, c), { tier: 'daily', cents: 27500 });
  assert.deepEqual(rentalCharge(2, c), { tier: 'daily', cents: 55000 });
  assert.deepEqual(rentalCharge(3, c), { tier: 'multi_day', cents: 3 * 24800 });
  assert.deepEqual(rentalCharge(6, c), { tier: 'multi_day', cents: 6 * 24800 });
  assert.deepEqual(rentalCharge(7, c), { tier: 'weekly', cents: 7 * 22000 });
  assert.deepEqual(rentalCharge(12, c), { tier: 'weekly', cents: 12 * 22000 });
  assert.deepEqual(rentalCharge(30, c), { tier: 'monthly', cents: 30 * 22000 });
  // without the multi-day rate the 0003 rules are unchanged
  assert.deepEqual(rentalCharge(3, { daily: 10000, weekly: 60000, monthly: 200000 }), { tier: 'daily', cents: 30000 });
  // a 6-day rental never costs more than the week (the GLS600 Maybach: 6 x 1,320 is over 7 x 1,100)
  const gls = rateCard(SHEET_RENTALS.find((x) => x.name === 'Mercedes GLS600 Maybach')!);
  assert.deepEqual(rentalCharge(6, gls), { tier: 'multi_day', cents: 7 * 110000 });
});

test('commission and payout: the partner is owed 80% of the sheet; CarmaCars keeps the markup plus 20%', () => {
  const r = SHEET_RENTALS.find((x) => x.name === 'Mercedes C43 AMG Blue')!;
  const s = partnerSplit(3, r);
  assert.deepEqual(s, { tier: 'multi_day', renter: 74400, sheet: 67500, cut: 13500, payout: 54000, markup: 6900, keep: 20400 });
  assert.equal(s.payout + s.keep, s.renter);
  const w = partnerSplit(7, r, { cutBps: 1500 });
  assert.equal(w.sheet, 140000);
  assert.equal(w.payout, 119000);
});

test('chauffeur: 2 hours at the 2-hour rate, 3 or more at the 3+ rate, at least 2', () => {
  const s580 = CHAUFFEUR.find((c) => c.sheet === 'Mercedes S580')!;
  assert.equal(chauffeurCharge(2, s580), 40000);
  assert.equal(chauffeurCharge(4, s580), 70000);
  assert.throws(() => chauffeurCharge(1, s580));
  assert.deepEqual(chauffeurSplit(3, s580), { renter: 3 * 19300, sheet: 52500, cut: 10500, payout: 42000, keep: 57900 - 42000 });
  assert.deepEqual(CHAUFFEUR.find((c) => c.sheet === 'Range Rovers')!.rentals.length, 5);
  assert.deepEqual(CHAUFFEUR.find((c) => c.sheet === 'Mercedes S680')!.rentals, []);
  assert.equal(CHAUFFEUR.filter((c) => c.kind === 'chauffeur_only').length, 5);
});
