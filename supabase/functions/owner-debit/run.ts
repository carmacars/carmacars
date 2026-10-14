// The owner debit run (docs/changes/2026-10-14-owner-debit.md), shared by the Edge Function (index.ts, Deno) and
// the local end-to-end check (web/scripts/owner-debit-e2e.mjs, Node). The database decides everything: what is due
// (app.owner_debit_claim), what a result means (app.owner_debit_submitted, app.owner_debit_result,
// app.owner_debit_submit_error). This file only talks to Stripe: one off-session PaymentIntent per invoice and
// attempt, confirmed against the owner's pre-authorized debit mandate, with the attempt's idempotency key, so a
// request sent twice is one debit.
export type Sql = (strings: TemplateStringsArray, ...values: unknown[]) => Promise<Array<Record<string, unknown>>>;
type Obj = Record<string, unknown>;
const API = 'https://api.stripe.com/v1';
const VERSION = '2025-09-30.clover';

export interface DebitRequest {
  attempt_id: string; attempt_no: number; idempotency_key: string; amount_cents: number; currency: string;
  customer_id: string; payment_method_id: string; mandate_id: string; description: string; metadata: Record<string, string>;
}
export interface RunSummary { claimed: number; submitted: number; refused: number; retry: number; polled: number; settled: number; errors: string[]; run: unknown }

export function formEncode(p: Obj, prefix = '', out = new URLSearchParams()): URLSearchParams {
  for (const [k, v] of Object.entries(p)) {
    if (v === undefined || v === null) continue;
    const key = prefix ? `${prefix}[${k}]` : k;
    if (Array.isArray(v)) v.forEach((x) => out.append(`${key}[]`, String(x)));
    else if (typeof v === 'object') formEncode(v as Obj, key, out);
    else out.append(key, String(v));
  }
  return out;
}

export class StripeCallError extends Error {
  readonly status: number;
  readonly code: string | null;
  constructor(message: string, status: number, code: string | null) { super(message); this.status = status; this.code = code; }
  /** A refusal that will not change on a retry (the request itself is wrong, or the mandate or method is gone). */
  get permanent(): boolean {
    if (this.status === 0 || this.status === 429 || this.status >= 500) return false;
    if (this.code && ['idempotency_key_in_use', 'lock_timeout', 'rate_limit'].includes(this.code)) return false;
    return this.status === 400 || this.status === 402 || this.status === 404;
  }
}

export function stripeClient(key: string, f: typeof fetch = fetch) {
  return async function call(method: 'GET' | 'POST', path: string, params: Obj = {}, idempotencyKey?: string): Promise<Obj> {
    const body = formEncode(params).toString();
    const headers: Record<string, string> = { authorization: `Bearer ${key}`, 'stripe-version': VERSION };
    if (method === 'POST') headers['content-type'] = 'application/x-www-form-urlencoded';
    if (idempotencyKey) headers['idempotency-key'] = idempotencyKey;
    let res: Response | null = null;
    let lastErr: unknown = null;
    for (let i = 0; i < 3; i++) {
      try {
        res = await f(method === 'GET' && body ? `${API}${path}?${body}` : `${API}${path}`, { method, headers, body: method === 'POST' ? body : undefined });
        if (res.status !== 429 && res.status < 500) break;
      } catch (e) { lastErr = e; res = null; }
    }
    if (!res) throw new StripeCallError(`Stripe could not be reached: ${lastErr instanceof Error ? lastErr.message : 'network error'}`, 0, null);
    const json = (await res.json()) as Obj;
    if (!res.ok) {
      const e = (json.error ?? {}) as Obj;
      throw new StripeCallError(String(e.message ?? `Stripe error ${res.status}`), res.status, (e.code as string) ?? (e.decline_code as string) ?? null);
    }
    return json;
  };
}

/** What the database records about a PaymentIntent. */
export function intentFacts(pi: Obj): Obj {
  const charge = (typeof pi.latest_charge === 'object' && pi.latest_charge) ? pi.latest_charge as Obj : null;
  const acss = ((charge?.payment_method_details as Obj | undefined)?.acss_debit ?? null) as Obj | null;
  const err = (pi.last_payment_error ?? null) as Obj | null;
  return {
    intent_id: pi.id, status: pi.status, charge_id: typeof pi.latest_charge === 'string' ? pi.latest_charge : charge?.id ?? null,
    mandate_id: (typeof pi.mandate === 'string' ? pi.mandate : null) ?? acss?.mandate ?? null,
    bank: acss ? { name: acss.bank_name ?? null, last4: acss.last4 ?? null } : null,
    error_code: err?.code ?? err?.decline_code ?? charge?.failure_code ?? null,
    error_message: err?.message ?? charge?.failure_message ?? null
  };
}

const one = <T>(rows: Array<Record<string, unknown>>, key: string): T | undefined => rows[0]?.[key] as T | undefined;

export async function runOwnerDebits(sql: Sql, stripeKey: string, opts: { limit?: number; fetch?: typeof fetch } = {}): Promise<RunSummary> {
  const stripe = stripeClient(stripeKey, opts.fetch);
  const limit = opts.limit ?? 25;
  const out: RunSummary = { claimed: 0, submitted: 0, refused: 0, retry: 0, polled: 0, settled: 0, errors: [], run: null };
  // 1. the debits due now, in batches until none is left
  for (let batch = 0; batch < 20; batch++) {
    const claim = one<DebitRequest[]>(await sql`select app.owner_debit_claim(now(), ${limit}::int) as claim`, 'claim');
    if (!claim?.length) break;
    out.claimed += claim.length;
    let progressed = 0;
    for (const d of claim) {
      try {
        const pi = await stripe('POST', '/payment_intents', {
          amount: d.amount_cents, currency: d.currency, customer: d.customer_id, payment_method: d.payment_method_id,
          payment_method_types: ['acss_debit'], mandate: d.mandate_id, confirm: true, off_session: true,
          description: d.description, metadata: d.metadata, expand: ['latest_charge']
        }, d.idempotency_key);
        await sql`select app.owner_debit_submitted(${d.attempt_id}::uuid, ${JSON.stringify(intentFacts(pi))}::jsonb)`;
        out.submitted++; progressed++;
      } catch (e) {
        const err = e instanceof StripeCallError ? e : new StripeCallError(e instanceof Error ? e.message : String(e), 0, null);
        await sql`select app.owner_debit_submit_error(${d.attempt_id}::uuid, ${err.code ?? 'error'}, ${err.message.slice(0, 500)}, ${err.permanent})`;
        if (err.permanent) { out.refused++; progressed++; } else out.retry++;
        out.errors.push(`${d.attempt_id}: ${err.message.slice(0, 200)}`);
      }
    }
    if (!progressed) break;   // Stripe unreachable: the next run sends them again with the same keys
  }
  // 2. debits still processing past the poll hours (a missed webhook)
  const poll = one<Array<{ attempt_id: string; intent_id: string }>>(await sql`select app.owner_debit_poll(now(), ${limit}::int) as poll`, 'poll');
  for (const p of poll ?? []) {
    try {
      const pi = await stripe('GET', `/payment_intents/${encodeURIComponent(p.intent_id)}`, { expand: ['latest_charge'] });
      const r = one<{ status: string }>(await sql`select app.owner_debit_result(${p.intent_id}, ${JSON.stringify(intentFacts(pi))}::jsonb) as r`, 'r');
      out.polled++;
      if (r?.status && r.status !== 'processing') out.settled++;
    } catch (e) {
      out.errors.push(`poll ${p.intent_id}: ${e instanceof Error ? e.message.slice(0, 200) : 'failed'}`);
    }
  }
  // 3. the day's run closes; the Admins get one summary
  out.run = one<unknown>(await sql`select app.owner_debit_run_close(now()) as run`, 'run') ?? null;
  return out;
}
