import { test } from 'node:test';
import assert from 'node:assert/strict';
import { parseQuote, purchase, quoteBody, requestQuote, toCents, type FetchLike } from './client.ts';

const q = { fromDate: '2027-03-01 10:00:00', toDate: '2027-03-04 10:00:00', customerAge: 34, firstName: 'Pat', lastName: 'Example', email: 'pat@example.test' };

test('the quote body names the fields as the docs do, Canada by default', () => {
  assert.deepEqual(quoteBody(q), { FromDate: '2027-03-01 10:00:00', ToDate: '2027-03-04 10:00:00', CustomerAge: 34, DestinationCountry: 'CA', Country: 'CA', FirstName: 'Pat', LastName: 'Example', Email: 'pat@example.test' });
  assert.throws(() => quoteBody({ ...q, fromDate: '2027-03-01' }), /YYYY-MM-DD HH:MM:SS/);
  assert.throws(() => quoteBody({ ...q, customerAge: 0 }), /age/);
});

test('amounts in dollars become cents; the answer needs Reference and TotalAmount', () => {
  assert.equal(toCents(43.21), 4321);
  assert.equal(toCents('43.2'), 4320);
  assert.equal(toCents('n/a'), null);
  assert.deepEqual(parseQuote({ Reference: 'AB23-456C-INS', TotalAmount: 43.21, Policy: { Code: 'EXAMPLE' }, Currency: 'CAD' }),
    { ok: true, reference: 'AB23-456C-INS', totalCents: 4321, currency: 'CAD', policyCode: 'EXAMPLE', raw: { Reference: 'AB23-456C-INS', TotalAmount: 43.21, Policy: { Code: 'EXAMPLE' }, Currency: 'CAD' } });
  assert.equal(parseQuote({ TotalAmount: 10 }).ok, false);
  assert.equal(parseQuote(null).ok, false);
});

test('the request: POST to /insurances/quote with the key in X_API_KEY; failures never throw', async () => {
  const seen: Array<{ url: string; headers: Record<string, string>; body: string }> = [];
  const ok: FetchLike = async (url, init) => { seen.push({ url, headers: init.headers, body: init.body }); return { ok: true, status: 200, text: async () => JSON.stringify({ Reference: 'R-1', TotalAmount: '12.50' }) }; };
  const r = await requestQuote('https://api-staging.rentalcover.com/', 'test-key', q, ok);
  assert.deepEqual(r.ok && [r.reference, r.totalCents], ['R-1', 1250]);
  assert.equal(seen[0]!.url, 'https://api-staging.rentalcover.com/insurances/quote');
  assert.equal(seen[0]!.headers.X_API_KEY, 'test-key');
  assert.equal(JSON.parse(seen[0]!.body).CustomerAge, 34);
  const refused: FetchLike = async () => ({ ok: false, status: 401, text: async () => 'Unauthorized' });
  assert.deepEqual(await requestQuote('https://x.example.test', 'k', q, refused), { ok: false, status: 401, error: 'HTTP 401' });
  const down: FetchLike = async () => { throw new TypeError('fetch failed'); };
  assert.deepEqual(await requestQuote('https://x.example.test', 'k', q, down), { ok: false, error: 'RentalCover could not be reached' });
  const notJson: FetchLike = async () => ({ ok: true, status: 200, text: async () => '<html>' });
  assert.equal((await requestQuote('https://x.example.test', 'k', q, notJson)).ok, false);
});

test('the purchase is a stub until RentalCover says how a policy is paid (it needs the card)', async () => {
  await assert.rejects(purchase(), /not connected/);
});
