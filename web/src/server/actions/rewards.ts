'use server';
import { revalidatePath } from 'next/cache';
import { DbError, rpc } from '@/lib/db/repo';
import type { ActionResult } from '@/features/forms/schemas';
import { requireUser } from '@/server/portal/data';

// The renter's CarmaCars Rewards actions (migration 0214). Each runs as the signed-in renter (role authenticated); the
// database finds their renter record and checks everything again. While an Admin views as a renter, nothing is changed
// (src/lib/db/repo.ts refuses the call).
type R<T = null> = ActionResult<T>;
const fail = (e: unknown): R<never> => ({ ok: false, code: 'refused', message: e instanceof DbError ? e.message : 'Something went wrong. Please try again or call us.' });
const as = async () => { const u = await requireUser('/account/rewards'); return { role: 'authenticated' as const, userId: u.id }; };

export async function redeemPoints(points: number): Promise<R<{ code: string; amount_cents: number; valid_until: string }>> {
  try {
    const data = (await rpc('rewards_mine_redeem', { p_points: Math.floor(points) }, await as())) as unknown as { code: string; amount_cents: number; valid_until: string };
    revalidatePath('/account/rewards');
    return { ok: true, data };
  } catch (e) { return fail(e); }
}

export async function cancelRewardCode(code: string): Promise<R<{ points: number }>> {
  try {
    const data = (await rpc('rewards_mine_code_cancel', { p_code: code }, await as())) as unknown as { points: number };
    revalidatePath('/account/rewards');
    return { ok: true, data };
  } catch (e) { return fail(e); }
}

export async function claimGoogleReview(number: string, name: string): Promise<R<{ points: number }>> {
  if (name.trim().length < 2) return { ok: false, code: 'invalid', message: 'Enter the name shown on your review.', fieldErrors: { name: 'The name shown on your review.' } };
  try {
    const data = (await rpc('rewards_mine_google_claim', { p_number: number, p_name: name.trim() }, await as())) as unknown as { points: number };
    revalidatePath('/account/rewards');
    return { ok: true, data };
  } catch (e) { return fail(e); }
}

/** r48 (3001): the renter's birthday for the Rewards birthday reward (month and day; the year optional; empty removes it). */
export async function saveBirthday(month: number | null, day: number | null, year: number | null): Promise<R<{ saved: boolean }>> {
  try {
    const data = (await rpc('rewards_mine_birthday', { p_month: month as number, p_day: day as number, ...(year ? { p_year: year } : {}) }, await as())) as unknown as { saved: boolean };
    revalidatePath('/account/rewards');
    revalidatePath('/account/profile');
    return { ok: true, data };
  } catch (e) { return fail(e); }
}
