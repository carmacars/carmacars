import { sha256Hex, type HelcimTransaction } from './helcim-api.ts';

// r50: a faked Helcim for tests and local work: the fetch Helcim's API answers (checkout sessions, purchase, preauth,
// capture, refund, reverse, card transactions, customers, idempotency keys), and what the HelcimPay.js modal does in the
// browser (fakeHelcim().pay: a card typed in the modal, approved or declined, with the hash HelcimPay.js sends).
// Card numbers: 4000000000000002 and 4000000000009995 are declined, any other approved (Helcim's test cards approve).

interface Session { checkoutToken: string; secretToken: string; paymentType: string; amount: number; customerCode?: string; used: boolean }
export interface FakeHelcimState {
  seq: number;
  sessions: Map<string, Session>;
  txs: Map<number, HelcimTransaction & { captured?: number; refunded?: number; reversed?: boolean }>;
  keys: Map<string, unknown>;
  customers: Set<string>;
  /** the next calls answer this error (a test of Helcim being down or refusing) */
  failNext: Array<{ path: RegExp; status: number; errors: string[] }>;
  calls: Array<{ method: string; path: string; body: unknown; key: string | null }>;
}

const DECLINE = new Set(['4000000000000002', '4000000000009995']);
const g = globalThis as unknown as { __ccFakeHelcim?: FakeHelcimState };

export function fakeHelcimState(fresh = false): FakeHelcimState {
  if (fresh || !g.__ccFakeHelcim) g.__ccFakeHelcim = { seq: 25_000_000, sessions: new Map(), txs: new Map(), keys: new Map(), customers: new Set(), failNext: [], calls: [] };
  return g.__ccFakeHelcim;
}

const json = (body: unknown, status = 200) => new Response(JSON.stringify(body), { status, headers: { 'content-type': 'application/json' } });
const err = (status: number, ...errors: string[]) => json({ errors }, status);
const brandOf = (n: string) => (n.startsWith('4') ? 'VI' : n.startsWith('5') ? 'MC' : n.startsWith('3') ? 'AX' : 'DI');

export function fakeHelcim(state: FakeHelcimState = fakeHelcimState()) {
  const tx = (t: Omit<HelcimTransaction, 'transactionId' | 'dateCreated' | 'currency'>): HelcimTransaction => {
    const x: HelcimTransaction = { transactionId: ++state.seq, dateCreated: new Date().toISOString().replace('T', ' ').slice(0, 19), currency: 'CAD', ...t };
    state.txs.set(x.transactionId, { ...x });
    return x;
  };
  const fetch = (async (url: string | URL | Request, init?: RequestInit) => {
    const u = new URL(String(url));
    const path = u.pathname.replace(/^\/v2/, '');
    const method = init?.method ?? 'GET';
    const headers = (init?.headers ?? {}) as Record<string, string>;
    const body = init?.body ? JSON.parse(String(init.body)) as Record<string, unknown> : null;
    const key = headers['idempotency-key'] ?? null;
    state.calls.push({ method, path, body, key });
    if (!headers['api-token']) return err(401, 'Unauthorized');
    const f = state.failNext.findIndex((x) => x.path.test(path));
    if (f >= 0) { const x = state.failNext.splice(f, 1)[0]!; return err(x.status, ...x.errors); }
    if (method === 'POST' && path.startsWith('/payment/')) {
      if (!key || !/^[A-Za-z0-9_-]{25,36}$/.test(key)) return err(400, 'idempotency-key: 25 to 36 alphanumeric characters');
      if (state.keys.has(key)) return json(state.keys.get(key));
    }
    const keep = (r: unknown) => { if (key) state.keys.set(key, r); return json(r); };
    if (method === 'GET' && path === '/connection-test') return json({ message: 'Connection successful' });
    if (method === 'POST' && path === '/helcim-pay/initialize') {
      if (!['purchase', 'preauth', 'verify'].includes(String(body?.paymentType))) return err(400, 'paymentType is invalid');
      if (body?.customerCode && !state.customers.has(String(body.customerCode))) return err(400, 'customerCode does not exist');
      const s: Session = { checkoutToken: `ct_${++state.seq}`, secretToken: `st_${state.seq}_${Math.random().toString(36).slice(2, 10)}`, paymentType: String(body!.paymentType),
        amount: Number(body!.amount), customerCode: body?.customerCode ? String(body.customerCode) : undefined, used: false };
      state.sessions.set(s.checkoutToken, s);
      return json({ checkoutToken: s.checkoutToken, secretToken: s.secretToken });
    }
    if (method === 'POST' && path === '/customers') {
      const code = String(body?.customerCode ?? `CST${++state.seq}`);
      if (state.customers.has(code)) return err(400, 'customerCode already exists');
      state.customers.add(code);
      return json({ id: state.seq, customerCode: code, contactName: body?.contactName ?? '' });
    }
    if (method === 'POST' && (path === '/payment/purchase' || path === '/payment/preauth')) {
      const card = (body?.cardData ?? {}) as { cardToken?: string };
      const known = [...state.txs.values()].find((t) => t.cardToken && t.cardToken === card.cardToken);
      if (!known) return err(400, 'cardToken is invalid');
      const declined = /decline/.test(String(card.cardToken));
      return keep(tx({ status: declined ? 'DECLINED' : 'APPROVED', type: path.endsWith('preauth') ? 'preauth' : 'purchase', amount: Number(body!.amount), cardToken: card.cardToken,
        cardNumber: known.cardNumber, cardType: known.cardType, cardHolderName: known.cardHolderName, customerCode: String(body?.customerCode ?? ''), approvalCode: declined ? '' : 'T12345' }));
    }
    if (method === 'POST' && path === '/payment/capture') {
      const p = state.txs.get(Number(body?.preAuthTransactionId));
      if (!p || p.type !== 'preauth' || p.status !== 'APPROVED' || p.reversed) return err(400, 'Preauth can no longer be captured');
      const amount = Number(body?.amount);
      if ((p.captured ?? 0) + amount > p.amount + 1e-9) return err(400, 'Preauth can no longer be captured');
      p.captured = (p.captured ?? 0) + amount;
      return keep(tx({ status: 'APPROVED', type: 'capture', amount, cardToken: p.cardToken, cardNumber: p.cardNumber, cardType: p.cardType, customerCode: p.customerCode }));
    }
    if (method === 'POST' && path === '/payment/refund') {
      const o = state.txs.get(Number(body?.originalTransactionId));
      if (!o || !['purchase', 'capture'].includes(o.type) || o.reversed) return err(400, 'originalTransactionId is invalid');
      const amount = Number(body?.amount);
      if ((o.refunded ?? 0) + amount > o.amount + 1e-9) return err(400, 'amount exceeds the original transaction');
      o.refunded = (o.refunded ?? 0) + amount;
      return keep(tx({ status: 'APPROVED', type: 'refund', amount, cardToken: o.cardToken, cardNumber: o.cardNumber, cardType: o.cardType }));
    }
    if (method === 'POST' && path === '/payment/reverse') {
      const o = state.txs.get(Number(body?.cardTransactionId));
      if (!o || o.reversed || (o.refunded ?? 0) > 0) return err(400, 'cardTransactionId cannot be reversed');
      o.reversed = true;
      return keep(tx({ status: 'APPROVED', type: 'reverse', amount: o.amount, cardToken: o.cardToken }));
    }
    const m = /^\/card-transactions\/(\d+)$/.exec(path);
    if (method === 'GET' && m) {
      const t = state.txs.get(Number(m[1]));
      if (!t) return err(404, 'Not found');
      const { captured: _c, refunded: _r, reversed: _v, ...pub } = t;
      void _c; void _r; void _v;
      return json(pub);
    }
    if (method === 'GET' && path === '/card-transactions') {
      return json([...state.txs.values()].filter((t) => !u.searchParams.get('customerCode') || t.customerCode === u.searchParams.get('customerCode'))
        .map(({ captured: _c, refunded: _r, reversed: _v, ...pub }) => { void _c; void _r; void _v; return pub; }).reverse());
    }
    return err(404, `No such endpoint ${method} ${path}`);
  }) as typeof globalThis.fetch;

  /** What the HelcimPay.js modal does: the card is typed, Helcim answers, and the modal posts {data, hash}. */
  async function pay(checkoutToken: string, card: { number: string; name?: string }): Promise<{ eventStatus: 'SUCCESS' | 'ABORTED'; eventMessage: string }> {
    const s = state.sessions.get(checkoutToken);
    if (!s || s.used) return { eventStatus: 'ABORTED', eventMessage: 'The checkout session expired' };
    const number = card.number.replace(/\D/g, '');
    s.used = true;
    if (DECLINE.has(number)) {
      tx({ status: 'DECLINED', type: s.paymentType, amount: s.amount, cardNumber: `${number.slice(0, 6)}******${number.slice(-4)}`, cardType: brandOf(number), customerCode: s.customerCode });
      return { eventStatus: 'ABORTED', eventMessage: 'Transaction declined' };
    }
    const t = tx({ status: 'APPROVED', type: s.paymentType, amount: s.amount, approvalCode: 'T12345', cardToken: `tok_${number.slice(-4)}_${state.seq}`,
      cardNumber: `${number.slice(0, 6)}******${number.slice(-4)}`, cardHolderName: card.name ?? 'Test Renter', cardType: brandOf(number), customerCode: s.customerCode ?? '' });
    const data = { transactionId: String(t.transactionId), dateCreated: t.dateCreated, cardBatchId: '1', status: t.status, type: t.type, amount: String(t.amount), currency: 'CAD',
      avsResponse: 'X', cvvResponse: 'M', approvalCode: t.approvalCode, cardToken: t.cardToken, cardNumber: t.cardNumber, cardHolderName: t.cardHolderName,
      customerCode: t.customerCode, invoiceNumber: '', warning: '' };
    const hash = await sha256Hex(JSON.stringify(data) + s.secretToken);
    return { eventStatus: 'SUCCESS', eventMessage: JSON.stringify({ data, hash }) };
  }
  return { fetch, pay, state };
}
