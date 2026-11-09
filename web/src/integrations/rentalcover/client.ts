// The RentalCover (Cover Genius) partner API (migration 1202): a typed client with no imports, so the unit test runs it
// in Node with a fetch stub. Docs: https://partner-docs.covergenius.com/rentalcover/quick-start
//   Header X_API_KEY. POST /insurances/quote with FromDate and ToDate ("YYYY-MM-DD HH:MM:SS"), CustomerAge, Country,
//   DestinationCountry, FirstName, LastName, Email. The answer has Reference (kept: it is the AgentReference of later
//   calls), TotalAmount and Policy.Code (the PolicyCode of the purchase). Staging: https://api-staging.rentalcover.com;
//   the production URL is given by RentalCover (RENTALCOVER_API_BASE).
//   POST /insurances/purchase needs the renter's card (CardHolder, CardNumber, CardExpiry MMYY, CardSecurityCode) plus
//   Address1, City and PostalCode: card data never reaches this server (Stripe holds the card), so the purchase is a
//   stub here. TODO(rentalcover-purchase): agree with RentalCover how a sold policy is paid (an invoice to CarmaCars,
//   or their hosted payment page) before a purchase call is written.
// The key is read from the environment by the caller and only ever sent in the header; it is never logged.

export interface QuoteInput {
  fromDate: string; toDate: string; customerAge: number; firstName: string; lastName: string; email: string;
  country?: string; destinationCountry?: string;
}
export interface QuoteOk { ok: true; reference: string; totalCents: number; currency: string | null; policyCode: string | null; raw: Record<string, unknown> }
export interface QuoteFail { ok: false; error: string; status?: number }
export type QuoteResult = QuoteOk | QuoteFail;
export type FetchLike = (url: string, init: { method: string; headers: Record<string, string>; body: string; signal?: AbortSignal }) => Promise<{ ok: boolean; status: number; text: () => Promise<string> }>;

const DATE = /^\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}$/;

/** The request body of POST /insurances/quote, exactly as the docs name the fields. */
export function quoteBody(q: QuoteInput): Record<string, unknown> {
  if (!DATE.test(q.fromDate) || !DATE.test(q.toDate)) throw new Error('RentalCover dates are YYYY-MM-DD HH:MM:SS');
  if (!Number.isInteger(q.customerAge) || q.customerAge < 16 || q.customerAge > 120) throw new Error('RentalCover needs the renter\'s age');
  return { FromDate: q.fromDate, ToDate: q.toDate, CustomerAge: q.customerAge, DestinationCountry: q.destinationCountry ?? 'CA', Country: q.country ?? 'CA',
    FirstName: q.firstName.trim(), LastName: q.lastName.trim(), Email: q.email.trim() };
}

/** Dollars as RentalCover sends them (a number or a string, "43.21") to cents; anything else is null. */
export function toCents(v: unknown): number | null {
  const n = typeof v === 'number' ? v : typeof v === 'string' && /^\s*\d+(\.\d+)?\s*$/.test(v) ? Number(v) : NaN;
  return Number.isFinite(n) && n >= 0 ? Math.round(n * 100) : null;
}

/** Reads the quote answer: Reference and TotalAmount are required; Policy.Code and a currency when given. */
export function parseQuote(j: unknown): QuoteResult {
  const o = (j && typeof j === 'object' ? j : {}) as Record<string, unknown>;
  const reference = typeof o.Reference === 'string' ? o.Reference : null;
  const totalCents = toCents(o.TotalAmount);
  if (!reference || totalCents === null) return { ok: false, error: 'RentalCover answered without Reference or TotalAmount' };
  const policy = (o.Policy && typeof o.Policy === 'object' ? o.Policy : {}) as Record<string, unknown>;
  const currency = typeof o.Currency === 'string' ? o.Currency : typeof o.CurrencyCode === 'string' ? o.CurrencyCode : null;
  return { ok: true, reference, totalCents, currency, policyCode: typeof policy.Code === 'string' ? policy.Code : null, raw: o };
}

/** POST /insurances/quote. Never throws: a network error, a timeout or a refusal is a QuoteFail (the caller falls back). */
export async function requestQuote(base: string, apiKey: string, q: QuoteInput, fetcher: FetchLike, timeoutMs = 8000): Promise<QuoteResult> {
  let body: string;
  try { body = JSON.stringify(quoteBody(q)); } catch (e) { return { ok: false, error: (e as Error).message }; }
  try {
    const r = await fetcher(`${base.replace(/\/+$/, '')}/insurances/quote`, {
      method: 'POST', headers: { 'Content-Type': 'application/json', Accept: 'application/json', X_API_KEY: apiKey }, body,
      signal: typeof AbortSignal !== 'undefined' && 'timeout' in AbortSignal ? AbortSignal.timeout(timeoutMs) : undefined
    });
    const text = await r.text();
    if (!r.ok) return { ok: false, status: r.status, error: `HTTP ${r.status}` };
    let j: unknown;
    try { j = JSON.parse(text); } catch { return { ok: false, status: r.status, error: 'RentalCover answered with something that is not JSON' }; }
    return parseQuote(j);
  } catch (e) {
    return { ok: false, error: e instanceof Error && e.name === 'TimeoutError' ? 'RentalCover did not answer in time' : 'RentalCover could not be reached' };
  }
}

/** POST /insurances/purchase: not made by this platform (it needs the renter's card number). See the TODO above. */
export async function purchase(): Promise<never> {
  throw new Error('RentalCover purchase is not connected: it needs the card at RentalCover (TODO(rentalcover-purchase))');
}
