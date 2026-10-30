import { test } from 'node:test';
import assert from 'node:assert/strict';
import { layout, SIG } from './layout.ts';
import { sampleFacts } from './sample.ts';
import { toBlindSpotFacts } from './facts.ts';
import { richFacts } from '../agreement/rich-fixture.ts';
import { BLANK, BOXES, SIGNED, boxOf } from './boxes.ts';

// Release 21b, item 8: every box of Blind Spot's form is filled (a value, or N/A when it does not apply) in some booking, or
// is on the list of boxes left blank on purpose; and layout.ts draws no box that is not on the form's list.
const MAILING = { line: '2967 Dundas St W, Unit 208B, Toronto, ON M6P 1Z2', street: '2967 Dundas St W', unit: 'Unit 208B', city: 'Toronto', province: 'ON', postal_code: 'M6P 1Z2' };
function drawn(): Set<string> {
  const out = new Set<string>();
  const add = (l: ReturnType<typeof layout>) => { for (const t of l.texts) out.add(t.box); };
  add(layout(sampleFacts({ mailing: MAILING, hst_number: '79878 1234 RT0001' })));
  add(layout(sampleFacts({ mailing: MAILING, hst_number: '79878 1234 RT0001' }, { insurer: true })));
  for (const st of ['open', 'pickup', 'return'] as const) { const { f, x, bs } = richFacts(st); add(layout(toBlindSpotFacts(f, bs as never, x))); }
  return out;
}
test('every box layout.ts draws is a box of the form', () => {
  const unknown = [...drawn()].map(boxOf).filter((b) => !(b in BOXES));
  assert.deepEqual([...new Set(unknown)], []);
});
test('no unmapped box: each is drawn in some booking or left blank on purpose, with the reason', () => {
  const got = new Set([...drawn()].map(boxOf));
  const unmapped = Object.keys(BOXES).filter((b) => !got.has(b) && !BLANK[b]);
  assert.deepEqual(unmapped, []);
  for (const b of Object.keys(BLANK)) assert.ok(b in BOXES, `${b}: a box of the form`);
});
test('every signature and initials box is accounted for', () => {
  const boxes = Object.values(SIG).map((s) => s.box);
  assert.deepEqual(boxes.filter((b) => !SIGNED[b]), []);
  assert.deepEqual(Object.keys(SIGNED).filter((b) => !boxes.includes(b)), []);
});
test('a box left blank on purpose is not drawn in the sample bookings (the reason stays true)', () => {
  const got = new Set([...drawn()].map(boxOf));
  assert.deepEqual(Object.keys(BLANK).filter((b) => got.has(b)), []);
});
