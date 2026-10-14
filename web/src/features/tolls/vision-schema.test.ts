import { test } from 'node:test';
import assert from 'node:assert/strict';
import { createHash } from 'node:crypto';
import { readFileSync } from 'node:fs';
import { normalizePlateBoxes, normalizeTollVision } from './vision-schema.ts';
import { jsonFrom } from '../../integrations/vision/workers-ai.ts';

test('a vision answer for a parking notice becomes one checked line', () => {
  const v = normalizeTollVision({ issuer: 'City of Toronto', kind: 'parking', notice_number: 'PN 1', due_date: 'Nov 1, 2026', total: '50.00',
    lines: [{ notice_number: 'PN 1', plate: 'tx-yz 789', date: '2026-10-02', time: '2:32 PM', location: '100 Queen St W', amount: 50, fees: null, confidence: 0.92 }] }, { page: 1, plates: ['TXYZ789'] });
  assert.equal(v.kind, 'parking');
  assert.equal(v.due_on, '2026-11-01');
  assert.equal(v.total_cents, 5000);
  assert.deepEqual([v.lines[0]!.plate, v.lines[0]!.occurred_at, v.lines[0]!.amount_cents, v.lines[0]!.time_unknown, v.lines[0]!.page], ['TXYZ789', '2026-10-02T14:32:00', 5000, false, 1]);
  assert.ok(v.lines[0]!.confidence >= 80 && v.lines[0]!.confidence <= 92);
});

test('a vision answer never gets more confidence than its checks allow; empty lines are dropped', () => {
  const v = normalizeTollVision({ issuer: '407 ETR', lines: [{ plate: null, date: 'unknown', amount: 'n/a', confidence: 100 }, { plate: 'ABCD123', date: '2026-09-14', amount: 12.34, confidence: 99 }] }, { page: 2, plates: [] });
  assert.equal(v.kind, 'toll_invoice');
  assert.equal(v.lines.length, 1);
  assert.ok(v.lines[0]!.confidence < 80, `plate not in the fleet and no time: ${v.lines[0]!.confidence}`);
  assert.equal(normalizeTollVision('not json', { page: 1, plates: [] }).problems.length, 1);
});

test('plate boxes: fractions, pixels and a 0 to 1000 grid; a box not shaped like a plate is dropped; a margin is added', () => {
  const img = { width: 1024, height: 683 };
  const a = normalizePlateBoxes({ plates: [{ x: 0.42, y: 0.66, w: 0.16, h: 0.06, confidence: 80 }] }, img);
  assert.equal(a.length, 1);
  assert.ok(a[0]!.x < 0.42 && a[0]!.w > 0.16);
  assert.equal(normalizePlateBoxes({ plates: [{ bbox: [430, 450, 594, 491] }] }, img).length, 1);
  assert.equal(normalizePlateBoxes({ boxes: [{ x1: 420, y1: 660, x2: 580, y2: 720 }] }, { width: 3000, height: 2000 }).length, 1);
  assert.equal(normalizePlateBoxes({ plates: [{ x: 0.1, y: 0.1, w: 0.1, h: 0.5 }] }, img).length, 0, 'taller than wide is not a plate');
  assert.equal(normalizePlateBoxes({ plates: [] }, img).length, 0);
});

test('the JSON inside a model answer is found', () => {
  assert.deepEqual(jsonFrom('Here it is:\n```json\n{"plates": []}\n```'), { plates: [] });
  assert.deepEqual(jsonFrom('Sure. {"a": 1} Done.'), { a: 1 });
  assert.equal(jsonFrom('no json'), null);
});

test('the pdf.js worker served from /vendor is the one of the installed pdfjs-dist', () => {
  const h = (p: string) => createHash('sha256').update(readFileSync(new URL(p, import.meta.url))).digest('hex');
  assert.equal(h('../../../public/vendor/pdfjs/pdf.worker.min.mjs'), h('../../../node_modules/pdfjs-dist/build/pdf.worker.min.mjs'), 'copy node_modules/pdfjs-dist/build/pdf.worker.min.mjs to public/vendor/pdfjs/');
});
