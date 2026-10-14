// Unit tests for the owner-debit run (supabase/functions/owner-debit/run.ts) with a mocked database and Stripe:
// one PaymentIntent per claimed debit with its idempotency key, the answer recorded, a passing error left for the
// next run, a refusal recorded as failed, the poll and the run's close.
//   npm run test:unit
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { formEncode, intentFacts, runOwnerDebits, StripeCallError, type Sql } from '../../../../supabase/functions/owner-debit/run.ts';

function db(claims: unknown[][], poll: unknown[] = []) {
  const log: Array<{ q: string; v: unknown[] }> = [];
  const sql = (async (strings: TemplateStringsArray, ...v: unknown[]) => {
    const q = strings.join('?');
    log.push({ q, v });
    if (q.includes('owner_debit_claim')) return [{ claim: claims.shift() ?? [] }];
    if (q.includes('owner_debit_poll')) return [{ poll }];
    if (q.includes('owner_debit_result')) return [{ r: { status: 'succeeded' } }];
    if (q.includes('owner_debit_run_close')) return [{ run: { run: 'r1', open: false } }];
    return [{}];
  }) as unknown as Sql;
  return { sql, log };
}
const debit = (id: string) => ({ attempt_id: id, attempt_no: 1, idempotency_key: `owner-debit:${id}`, amount_cents: 53675, currency: 'cad', customer_id: 'cus_1',
  payment_method_id: 'pm_1', mandate_id: 'mandate_1', description: 'CarmaCars invoice INV-1', metadata: { purpose: 'owner_invoice', debit_attempt_id: id } });

test('each claimed debit is one off-session PaymentIntent with its idempotency key, and the answer is recorded', async () => {
  const { sql, log } = db([[debit('a1'), debit('a2')]]);
  const calls: Array<{ url: string; init: RequestInit }> = [];
  const f = (async (url: string | URL | Request, init?: RequestInit) => {
    calls.push({ url: String(url), init: init ?? {} });
    return new Response(JSON.stringify({ id: `pi_${calls.length}`, status: 'processing', latest_charge: { id: 'py_1', payment_method_details: { acss_debit: { bank_name: 'TD', last4: '6789', mandate: 'mandate_1' } } } }), { status: 200 });
  }) as typeof fetch;
  const r = await runOwnerDebits(sql, 'sk_test_x', { fetch: f });
  assert.equal(r.submitted, 2);
  assert.equal(calls.length, 2);
  const body = decodeURIComponent(String(calls[0]!.init.body));
  for (const re of [/payment_method_types\[\]=acss_debit/, /mandate=mandate_1/, /off_session=true/, /confirm=true/, /metadata\[debit_attempt_id\]=a1/, /amount=53675/]) assert.match(body, re);
  assert.equal((calls[0]!.init.headers as Record<string, string>)['idempotency-key'], 'owner-debit:a1');
  const submitted = log.filter((l) => l.q.includes('owner_debit_submitted'));
  assert.equal(submitted.length, 2);
  assert.equal(JSON.parse(String(submitted[0]!.v[1])).bank.last4, '6789');
  assert.ok(log.some((l) => l.q.includes('owner_debit_run_close')));
});

test('Stripe unreachable: the debit stays to be sent again (not failed), and the run stops asking', async () => {
  const { sql, log } = db([[debit('a1')], [debit('a1')]]);
  const f = (async () => new Response(JSON.stringify({ error: { message: 'down' } }), { status: 503 })) as unknown as typeof fetch;
  const r = await runOwnerDebits(sql, 'sk_test_x', { fetch: f });
  assert.equal(r.retry, 1);
  const err = log.find((l) => l.q.includes('owner_debit_submit_error'))!;
  assert.equal(err.v[3], false);
  assert.equal(log.filter((l) => l.q.includes('owner_debit_claim')).length, 1);
});

test('an inactive mandate is a permanent refusal, recorded as a failed debit', async () => {
  const { sql, log } = db([[debit('a1')]]);
  const f = (async () => new Response(JSON.stringify({ error: { message: 'The mandate is not active', code: 'payment_intent_mandate_invalid' } }), { status: 400 })) as unknown as typeof fetch;
  const r = await runOwnerDebits(sql, 'sk_test_x', { fetch: f });
  assert.equal(r.refused, 1);
  const err = log.find((l) => l.q.includes('owner_debit_submit_error'))!;
  assert.deepEqual([err.v[1], err.v[3]], ['payment_intent_mandate_invalid', true]);
});

test('a debit processing too long is asked again and settled', async () => {
  const { sql, log } = db([[]], [{ attempt_id: 'a1', intent_id: 'pi_9' }]);
  const f = (async (url: string | URL | Request) => {
    assert.match(String(url), /\/payment_intents\/pi_9\?expand/);
    return new Response(JSON.stringify({ id: 'pi_9', status: 'requires_payment_method', last_payment_error: { code: 'insufficient_funds', message: 'Insufficient funds' } }), { status: 200 });
  }) as typeof fetch;
  const r = await runOwnerDebits(sql, 'sk_test_x', { fetch: f });
  assert.equal(r.polled, 1);
  const res = log.find((l) => l.q.includes('owner_debit_result'))!;
  assert.deepEqual(JSON.parse(String(res.v[1])), { intent_id: 'pi_9', status: 'requires_payment_method', charge_id: null, mandate_id: null, bank: null, error_code: 'insufficient_funds', error_message: 'Insufficient funds' });
});

test('helpers: nested form encoding, the facts of a PaymentIntent, which errors are permanent', () => {
  assert.equal(decodeURIComponent(formEncode({ metadata: { a: '1' }, expand: ['x'] }).toString()), 'metadata[a]=1&expand[]=x');
  assert.equal(intentFacts({ id: 'pi_1', status: 'succeeded', latest_charge: 'py_1', mandate: 'm_1' }).charge_id, 'py_1');
  assert.equal(new StripeCallError('x', 400, 'resource_missing').permanent, true);
  assert.equal(new StripeCallError('x', 429, null).permanent, false);
  assert.equal(new StripeCallError('x', 409, 'idempotency_key_in_use').permanent, false);
  assert.equal(new StripeCallError('x', 0, null).permanent, false);
});
