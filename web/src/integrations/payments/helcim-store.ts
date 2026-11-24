import 'server-only';
import { rpc } from '@/lib/db/repo';
import type { HelcimIntentRow, HelcimStore } from './helcim';

// r50: the Helcim adapter's payments in our database (helcim_intents and helcim_calls, migration 3710), through server-only
// functions: the service role alone reads or writes them (the secret token of a checkout session never leaves the server).
const SR = { role: 'service_role' as const };
const call = async <T>(fn: string, args: Record<string, unknown>): Promise<T> => (await rpc(fn as never, args as never, SR)) as unknown as T;
const row = (x: unknown): HelcimIntentRow | null => (x && typeof x === 'object' ? (x as HelcimIntentRow) : null);

export function dbHelcimStore(): HelcimStore {
  return {
    get: async (id) => row(await call('server_helcim_intent_get', { p_id: id })),
    byKey: async (key) => row(await call('server_helcim_intent_find', { p: { key } })),
    byTransaction: async (tx) => row(await call('server_helcim_intent_find', { p: { transaction_id: tx } })),
    byCheckoutToken: async (token) => row(await call('server_helcim_intent_find', { p: { checkout_token: token } })),
    openFor: async (code, amount, since) => ((await call<unknown[]>('server_helcim_intent_open', { p_customer: code, p_amount: amount, p_since: new Date(since).toISOString() })) ?? [])
      .map(row).filter((x): x is HelcimIntentRow => !!x),
    put: async (r) => { await call('server_helcim_intent_put', { p: r }); },
    callGet: async (key) => (await call<{ result?: unknown } | null>('server_helcim_call_get', { p_key: key }))?.result ?? null,
    callPut: async (key, result) => { await call('server_helcim_call_put', { p_key: key, p_result: result }); },
    holdPlan: async (booking, days) => ((await call<string>('server_helcim_hold_plan', { p_booking: booking, p_window_days: days })) === 'charge' ? 'charge' : 'hold')
  };
}
