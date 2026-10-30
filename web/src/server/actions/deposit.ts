'use server';
import { revalidatePath } from 'next/cache';
import { DbError } from '@/lib/db/repo';
import type { ActionResult } from '@/features/forms/schemas';
import { currentUser } from '@/server/portal/data';
import { door, sessionAal } from '@/server/door';
import { collectBalance, runSettlement } from '@/server/deposit-guard';

// The Settle screen of the deposit guard (migration 0155), through the door: the settlement (the database decides and
// refuses with the reason, shown as written), Keep the whole deposit (damage), a damage charge. The money steps the
// database decided run at Stripe at once (server/deposit-guard.ts); the deposit job retries what did not go through.
type R<T = unknown> = ActionResult<T>;
const fail = (e: unknown): R<never> => ({ ok: false, code: 'refused', message: e instanceof DbError || e instanceof Error ? e.message.replace(/^.*?ERROR:\s*/, '') : 'Something went wrong.' });

interface Settled { booking_id: string; status: string; applied_cents: number; held_back_cents: number; released_cents: number; charged_to_card_cents: number;
  server_actions?: Array<{ action: string; payment_id: string }>; balance_open_cents?: number; proposed?: unknown }
export interface SettleResult { status: string; applied_cents: number; held_back_cents: number; released_cents: number; charged_to_card_cents: number;
  money: Array<{ action: string; ok: boolean; error?: string }>; balance: { action: string; open_cents: number } | null }

async function me() {
  const user = await currentUser();
  if (!user) throw new Error('Sign in first.');
  return { user, aal: await sessionAal() };
}
const refresh = (paths: string[]) => { for (const x of [...paths, '/admin/bookings', '/staff/bookings']) revalidatePath(x); };

/** Settle the deposit: { booking, hold_back_cents, hold_back_reason, hold_back_until, release_now, override_reason } */
export async function settleDeposit(p: Record<string, unknown>, paths: string[] = []): Promise<R<SettleResult>> {
  try {
    const { user, aal } = await me();
    const s = await door<Settled>(user.id, 'ops_do', 'deposit_settle', p, aal);
    const run = s.status === 'settled' ? await runSettlement(s.booking_id, s.server_actions) : { results: [], balance: null };
    refresh(paths);
    return { ok: true, data: { status: s.status, applied_cents: s.applied_cents, held_back_cents: s.held_back_cents, released_cents: s.released_cents,
      charged_to_card_cents: s.charged_to_card_cents, money: run.results, balance: run.balance } };
  } catch (e) { return fail(e); }
}

interface Charged { line_item_id: string; booking_id: string; kept_cents?: number; charged?: { settlement?: Settled | null } | null }
async function damage(kind: 'deposit_keep_whole' | 'damage_charge_add', p: Record<string, unknown>, paths: string[]): Promise<R<{ kept_cents?: number; money: Array<{ action: string; ok: boolean; error?: string }> }>> {
  try {
    const { user, aal } = await me();
    const r = await door<Charged>(user.id, 'ops_do', kind, p, aal);
    const st = r.charged?.settlement;
    const run = st ? await runSettlement(st.booking_id, st.server_actions) : null;
    if (!st && r.booking_id) await collectBalance(r.booking_id).catch(() => undefined);
    refresh(paths);
    return { ok: true, data: { kept_cents: r.kept_cents, money: run?.results ?? [] } };
  } catch (e) { return fail(e); }
}

/** Keep the whole deposit (damage), an Admin: { booking, reason, photos } */
export async function keepWholeDeposit(p: Record<string, unknown>, paths: string[] = []) { return damage('deposit_keep_whole', p, paths); }

/** A damage charge, an Admin: { booking, amount_cents, reason, photos } */
export async function addDamageCharge(p: Record<string, unknown>, paths: string[] = []) { return damage('damage_charge_add', p, paths); }
