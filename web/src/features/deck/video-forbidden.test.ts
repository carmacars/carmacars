// The investor video never shows or says the fleet size, utilization, the insurance premium or internal costs (r27,
// web/scripts/investor-video/forbidden.mjs, checked by build.mjs on the narration and every slide).
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
// @ts-expect-error a plain .mjs module of the video scripts, no types
import { FORBIDDEN_TOKEN, forbidden } from '../../../scripts/investor-video/forbidden.mjs';

const f = forbidden as (t: string, w: string) => string[];

test('each of the four is caught', () => {
  assert.match(f('We now run 42 cars across the GTA.', 'x').join(), /fleet size or car count/);
  assert.match(f('Our fleet size doubled.', 'x').join(), /fleet size/);
  assert.match(f('Utilization was 71% in October.', 'x').join(), /utilization/);
  assert.match(f('The insurance premium is $9,000 a year.', 'x').join(), /insurance premium/);
  assert.match(f('Our costs per month are low and margins high.', 'x').join(), /internal costs/);
});
test("the deck's own words pass: owner fee tiers, Premium as a car class, the fees owners pay", () => {
  assert.deepEqual(f('Each owner car pays $370 to $475 a month together, by tier: 1 to 2 cars, 3 or more cars. Premium and luxury cars.', 'x'), []);
  assert.deepEqual(f('Investors earn a fixed yearly percentage under a written agreement.', 'x'), []);
});
test('a script token named for one of them is refused', () => {
  for (const k of ['fleetSize', 'carCount', 'utilization', 'insurancePremium', 'monthlyCost']) assert.ok((FORBIDDEN_TOKEN as RegExp).test(k), k);
  for (const k of ['mult', 'yearly', 'feeRange', 'shareRange']) assert.ok(!(FORBIDDEN_TOKEN as RegExp).test(k), k);
});
test('the current script and storyboard say none of them', () => {
  for (const p of ['../../../../docs/investor-video/script.md', '../../../../docs/investor-video/storyboard.md']) {
    const text = readFileSync(new URL(p, import.meta.url), 'utf8').split('\n').filter((l) => !/^(-|Tokens:|The owner|This file|Updated|  )/.test(l)).join(' ');
    assert.deepEqual(f(text.replace(/\{\{\w+\}\}/g, 'X'), p), []);
  }
});
