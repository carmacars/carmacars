// r50: the connector's Helcim reads, beside what the site recorded (mirrors stripe-inspect.ts). Read only: nothing here
// charges, captures or refunds. Only a card's brand and last four digits are returned, never a token, a full number or a
// secret. Pure apart from the reads given to it (unit tested with a faked Helcim: helcim-inspect.test.ts).
import type { HelcimTransaction } from '../../integrations/payments/helcim-api.ts';
import { cardOf } from '../../integrations/payments/helcim.ts';

export interface HelcimKnown { [tx: string]: { intent: string; status: string; booking_number: string | null; recorded: boolean } }

export interface HelcimPaymentView {
  transaction_id: number; type: string; status: string; amount_cents: number; currency: string; when: string | null; card: string | null;
  customer_code: string | null; intent: string | null; booking_number: string | null; recorded: boolean; untied: boolean;
}

/** Helcim's dates are Mountain Time, day only (dateFrom, dateTo): the window in those days, inclusive. */
export function mountainDay(d: Date): string {
  return new Intl.DateTimeFormat('en-CA', { timeZone: 'America/Edmonton', year: 'numeric', month: '2-digit', day: '2-digit' }).format(d);
}

/** helcim_find_payments: approved purchases, preauths and captures of the window (optionally one amount), newest first,
 *  each with whether the site recorded it. A payment no booking knows (taken in the Helcim dashboard or on its terminal)
 *  is flagged untied: helcim_record_paid links it. */
export async function findHelcimPayments(list: (dateFrom: string, dateTo: string) => Promise<HelcimTransaction[]>, q: { from: Date; to: Date; amount_cents: number | null },
  known: (ids: number[]) => Promise<HelcimKnown>): Promise<{ count: number; payments: HelcimPaymentView[]; untied: number }> {
  const all = await list(mountainDay(q.from), mountainDay(q.to));
  const inWindow = all.filter((t) => {
    if (String(t.status).toUpperCase() !== 'APPROVED' || !['purchase', 'preauth', 'capture'].includes(t.type)) return false;
    const when = t.dateCreated ? Date.parse(t.dateCreated.replace(' ', 'T') + (/[zZ+-]\d*$/.test(t.dateCreated) ? '' : '-07:00')) : NaN;
    if (Number.isFinite(when) && (when < q.from.getTime() - 86_400_000 || when > q.to.getTime() + 86_400_000)) return false;
    return q.amount_cents === null || Math.round(Number(t.amount) * 100) === q.amount_cents;
  });
  const k = inWindow.length ? await known(inWindow.map((t) => t.transactionId)) : {};
  const payments = inWindow.map((t): HelcimPaymentView => {
    const c = cardOf(t);
    const hit = k[String(t.transactionId)];
    return { transaction_id: t.transactionId, type: t.type, status: t.status, amount_cents: Math.round(Number(t.amount) * 100), currency: t.currency ?? 'CAD', when: t.dateCreated ?? null,
      card: c ? `${c.brand} ${c.last4}` : null, customer_code: t.customerCode || null, intent: hit?.intent ?? null, booking_number: hit?.booking_number ?? null,
      recorded: hit?.recorded ?? false, untied: !hit };
  }).sort((a, b) => b.transaction_id - a.transaction_id);
  return { count: payments.length, payments, untied: payments.filter((p) => p.untied).length };
}

/** helcim_account: whether the token works, the webhook is set, and the last day's approved card payments. */
export function accountView(ok: boolean, error: string | null, last: HelcimTransaction[], webhook: boolean, terminal: string | null) {
  const approved = last.filter((t) => String(t.status).toUpperCase() === 'APPROVED');
  const sum = (types: string[]) => approved.filter((t) => types.includes(t.type)).reduce((s, t) => s + Math.round(Number(t.amount) * 100), 0);
  return {
    processor: 'helcim', connected: ok, error, webhook_verifier_set: webhook, terminal_id: terminal,
    last_24_hours: { approved: approved.length, declined: last.length - approved.length, charged_cents: sum(['purchase', 'capture']), held_cents: sum(['preauth']), refunded_cents: sum(['refund']) },
    note: 'Helcim settles card batches to the bank account set in Helcim; payouts and fees are in the Helcim dashboard (Reporting).'
  };
}
