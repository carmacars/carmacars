import { test } from 'node:test';
import assert from 'node:assert/strict';
import { buyLine, quoteLine, type LineCfg, type LineDb } from './staff-line-buy.ts';

// R51 review fix (5210): the purchase buys the quoted number, once, on the production host only. fetch is mocked: nothing is bought.
const cfg: LineCfg = { accountSid: 'AC' + 'a'.repeat(32), apiKey: 'SK' + 'b'.repeat(32), apiSecret: 'secret', base: 'https://carmacars.ca' };
const SID = 'PN' + 'c'.repeat(32);
const QUOTED = '+16475550772';
const OTHER = '+16475550999';

function mockFetch(opts: { price?: string; unit?: string; available?: string[]; buyStatus?: number } = {}) {
  const calls: Array<{ url: string; method: string; body: string }> = [];
  const f = (async (url: string | URL | Request, init?: RequestInit) => {
    const u = String(url);
    calls.push({ url: u, method: init?.method ?? 'GET', body: String(init?.body ?? '') });
    if (u.includes('pricing.twilio.com')) return Response.json({ price_unit: opts.unit ?? 'USD', phone_number_prices: [{ number_type: 'local', current_price: opts.price ?? '1.15' }] });
    if (u.includes('AvailablePhoneNumbers')) return Response.json({ available_phone_numbers: (opts.available ?? [OTHER]).map((phone_number) => ({ phone_number })) });
    if (u.includes('IncomingPhoneNumbers.json') && init?.method === 'POST') {
      const s = opts.buyStatus ?? 201;
      return Response.json(s < 300 ? { sid: SID, phone_number: new URLSearchParams(String(init.body)).get('PhoneNumber') } : { message: 'no' }, { status: s });
    }
    return Response.json({}, { status: 204 });
  }) as typeof fetch;
  return { f, calls };
}

function fakeDb(quote?: { number: string; monthly: string; currency: string }) {
  const st = { quote, buying: false, saved: [] as unknown[], ended: 0 };
  const db: LineDb = {
    check: async () => ({ extension: '7051', name: 'Pat', area_code: '647' }),
    quoted: async (q) => { st.quote = q; },
    claim: async (c) => {
      if (!st.quote) throw new Error('The quote is gone');
      if (st.buying) throw new Error('A purchase for this person is already in progress');
      if (st.quote.monthly !== c.confirm || st.quote.currency !== c.currency.toUpperCase()) throw new Error('The price you confirmed is not the one quoted');
      st.buying = true;
      return st.quote;
    },
    bought: async (b) => { st.saved.push(b); return { line: 'Ext 7051, number ending 0772' }; },
    end: async () => { st.ended++; st.buying = false; st.quote = undefined; },
  };
  return { db, st };
}
const purchases = (calls: Array<{ method: string; url: string; body: string }>) => calls.filter((c) => c.method === 'POST' && c.url.includes('IncomingPhoneNumbers.json'));

test('the quote keeps the full number for the Buy step and shows only its last 4 digits', async () => {
  const { f } = mockFetch({ available: [QUOTED] });
  const { db, st } = fakeDb();
  const q = await quoteLine(cfg, db, f);
  assert.deepEqual(q.ok && q.number, '•••-•••-0772');
  assert.ok(!JSON.stringify(q).includes('647555'));
  assert.deepEqual(st.quote, { number: QUOTED, monthly: '1.15', currency: 'USD' });
});

test('Buy buys exactly the quoted number, even when Twilio now offers another', async () => {
  const { f, calls } = mockFetch({ available: [OTHER] });
  const { db, st } = fakeDb({ number: QUOTED, monthly: '1.15', currency: 'USD' });
  const r = await buyLine(cfg, db, { monthly: '1.15', currency: 'USD' }, f);
  assert.equal(r.ok, true);
  const p = purchases(calls);
  assert.equal(p.length, 1);
  assert.equal(new URLSearchParams(p[0]!.body).get('PhoneNumber'), QUOTED);
  assert.ok(!calls.some((c) => c.url.includes('AvailablePhoneNumbers')), 'no new search at Buy');
  assert.equal(st.saved.length, 1);
});

test('a second Buy while one is in progress buys nothing', async () => {
  const { f, calls } = mockFetch();
  const { db, st } = fakeDb({ number: QUOTED, monthly: '1.15', currency: 'USD' });
  st.buying = true;
  const r = await buyLine(cfg, db, { monthly: '1.15', currency: 'USD' }, f);
  assert.deepEqual(r.ok, false);
  assert.match(!r.ok ? r.message : '', /in progress/);
  assert.equal(calls.length, 0);
});

test('two Buys at once buy one number', async () => {
  const { f, calls } = mockFetch();
  const { db } = fakeDb({ number: QUOTED, monthly: '1.15', currency: 'USD' });
  const [a, b] = await Promise.all([buyLine(cfg, db, { monthly: '1.15', currency: 'USD' }, f), buyLine(cfg, db, { monthly: '1.15', currency: 'USD' }, f)]);
  assert.equal([a, b].filter((x) => x.ok).length, 1);
  assert.equal(purchases(calls).length, 1);
});

test('a confirmed amount or currency that is not the quoted one buys nothing', async () => {
  for (const c of [{ monthly: '1.00', currency: 'USD' }, { monthly: '1.15', currency: 'CAD' }, { monthly: '', currency: '' }]) {
    const { f, calls } = mockFetch();
    const { db } = fakeDb({ number: QUOTED, monthly: '1.15', currency: 'USD' });
    const r = await buyLine(cfg, db, c, f);
    assert.equal(r.ok, false);
    assert.equal(purchases(calls).length, 0);
  }
});

test('Twilio now charging another amount or currency than quoted buys nothing, and the quote is spent', async () => {
  for (const o of [{ price: '1.40' }, { unit: 'CAD' }]) {
    const { f, calls } = mockFetch(o);
    const { db, st } = fakeDb({ number: QUOTED, monthly: '1.15', currency: 'USD' });
    const r = await buyLine(cfg, db, { monthly: '1.15', currency: 'USD' }, f);
    assert.equal(r.ok, false);
    assert.equal(purchases(calls).length, 0);
    assert.equal(st.ended, 1);
  }
});

test('only the production host buys', async () => {
  for (const base of ['https://carmacars.test', 'http://carmacars.ca', 'https://preview-abc.pages.dev', 'https://carmacars.ca.evil.example', 'http://localhost:3000']) {
    const { f, calls } = mockFetch();
    const { db } = fakeDb({ number: QUOTED, monthly: '1.15', currency: 'USD' });
    const r = await buyLine({ ...cfg, base }, db, { monthly: '1.15', currency: 'USD' }, f);
    assert.equal(r.ok, false, base);
    assert.equal(calls.length, 0, base);
  }
  const { f } = mockFetch();
  assert.equal((await buyLine({ ...cfg, base: 'https://www.carmacars.ca/' }, fakeDb({ number: QUOTED, monthly: '1.15', currency: 'USD' }).db, { monthly: '1.15', currency: 'USD' }, f)).ok, true);
});

test('a number Twilio will not sell leaves nothing bought and frees the quote', async () => {
  const { f } = mockFetch({ buyStatus: 400 });
  const { db, st } = fakeDb({ number: QUOTED, monthly: '1.15', currency: 'USD' });
  const r = await buyLine(cfg, db, { monthly: '1.15', currency: 'USD' }, f);
  assert.equal(r.ok, false);
  assert.equal(st.saved.length, 0);
  assert.equal(st.ended, 1);
});
