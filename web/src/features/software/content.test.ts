import { test } from 'node:test';
import assert from 'node:assert/strict';
import { FAQ, FEATURES, PORTALS, SOFTWARE, llmsLines } from './content.ts';

const all = () => JSON.stringify({ SOFTWARE, PORTALS, FEATURES, FAQ });

test('r50 hotfix 2: the software page describes every portal and feature the owner named', () => {
  assert.deepEqual(PORTALS.map((p) => p.id), ['renter', 'owner', 'staff', 'admin']);
  for (const id of ['insurance', 'tolls', 'ai', 'calls', 'academy', 'seo']) assert.ok(FEATURES.some((f) => f.id === id), id);
  for (const p of PORTALS) assert.ok(p.points.length >= 4, `${p.id}: descriptive`);
  for (const role of ['Sales', 'Customer service', 'Operations', 'Finance', 'Field']) assert.ok(PORTALS.find((p) => p.id === 'staff')!.points.some((x) => x.startsWith(role)), role);
  assert.ok(SOFTWARE.title.length <= 70 && SOFTWARE.description.length <= 170, 'title and description fit a search result');
});

test('no price and nothing about how it is built; no dashes', () => {
  const s = all();
  assert.doesNotMatch(s, /\$\s?\d|\bCAD\b|per month|a month\b|\/mo\b|free trial/i, 'no pricing');
  assert.doesNotMatch(s, /next\.?js|react|postgres|supabase|cloudflare|vercel|openai|gemini|claude|anthropic|twilio|stripe|helcim|resend|amazon|aws|open source|database/i, 'how it is built stays vague');
  assert.doesNotMatch(s, /[–—]/);
  assert.match(FAQ.find((q) => /cost/.test(q.question))!.answer, /form on this page/);
  assert.equal(llmsLines('https://x.test').at(-2), '- Page: https://x.test/rental-software');
});
