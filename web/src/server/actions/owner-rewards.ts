'use server';
import { revalidatePath } from 'next/cache';
import { DbError, rpc } from '@/lib/db/repo';
import type { ActionResult } from '@/features/forms/schemas';
import { currentUser } from '@/server/portal/data';
import type { Json } from '@/lib/db/types';
import type { OwnerRewards } from '@/features/owner-rewards/model';

// The owner's Rewards buttons (release 48, migration 3262): redeem a merch kit (the address they confirm), ask for a free
// upgrade while their car is repaired, cancel that request. The database answers only for an active owner account
// (app.portal_owner_id) and checks every rule; its refusal is shown as written.
const SR = { role: 'service_role' as const };
type R = ActionResult<OwnerRewards>;
const text = (v: unknown, max: number) => (typeof v === 'string' ? v.trim().slice(0, max) : '');

export async function ownerRewardDo(action: 'redeem_kit' | 'upgrade_ask' | 'upgrade_cancel', input: Record<string, unknown>): Promise<R> {
  try {
    const user = await currentUser();
    if (!user) return { ok: false, code: 'auth', message: 'Sign in first.' };
    let p: Record<string, unknown>;
    if (action === 'redeem_kit') {
      if (input.kind !== 'merch_kit' && input.kind !== 'merch_kit_premium') return { ok: false, code: 'invalid', message: 'Choose a kit.' };
      p = { kind: input.kind, name: text(input.name, 120), line1: text(input.line1, 160), line2: text(input.line2, 160), city: text(input.city, 80), province: text(input.province, 40),
        postal_code: text(input.postal_code, 12), phone: text(input.phone, 30), size: text(input.size, 4) };
    } else if (action === 'upgrade_ask') {
      const vehicle = text(input.vehicle, 36);
      if (!/^[0-9a-f-]{36}$/.test(vehicle)) return { ok: false, code: 'invalid', message: 'Choose which of your cars is being repaired.', fieldErrors: { vehicle: 'Choose a car.' } };
      p = { vehicle, note: text(input.note, 600) };
    } else if (action === 'upgrade_cancel') {
      p = { id: text(input.id, 36) };
    } else return { ok: false, code: 'invalid', message: 'Unknown action.' };
    const data = (await rpc('owner_portal_reward_do' as never, { p_by: user.id, p_action: action, p: p as unknown as Json } as never, SR)) as unknown as OwnerRewards;
    revalidatePath('/owner/rewards');
    return { ok: true, data };
  } catch (e) {
    return { ok: false, code: 'refused', message: e instanceof DbError ? e.message : 'Not done. Please try again or call us.' };
  }
}
