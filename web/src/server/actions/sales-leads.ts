'use server';
import { revalidatePath } from 'next/cache';
import { DbError } from '@/lib/db/repo';
import type { ActionResult } from '@/features/forms/schemas';
import { currentUser } from '@/server/portal/data';
import { door, sessionAal } from '@/server/door';

// The Sales lead list's actions (migration 0950), through the door's ops calls: the database checks the person (an Admin,
// Sales or customer service; reassign, release and the settings are Admins') and the claim rules; its refusal is shown as
// written.
const ACTIONS = new Set(['lead_claim', 'lead_unclaim', 'lead_contact', 'lead_outcome', 'lead_handled', 'lead_reassign', 'lead_return', 'lead_hold_release', 'lead_next', 'sales_lead_settings_save', 'renter_merge_undo', 'leads_bulk_assign']);

export async function leadAct<T = Record<string, unknown>>(action: string, p: Record<string, unknown> = {}): Promise<ActionResult<T>> {
  if (!ACTIONS.has(action)) return { ok: false, code: 'invalid', message: 'Unknown action.' };
  try {
    const user = await currentUser();
    if (!user) return { ok: false, code: 'auth', message: 'Sign in first.' };
    const data = await door<T>(user.id, 'ops_do', action, p, await sessionAal());
    for (const base of ['/admin/sales-leads', '/staff/sales-leads', '/staff/owner-leads', '/admin/owners', '/admin/renters', '/staff/game-leads', '/staff']) revalidatePath(base, 'layout');
    return { ok: true, data };
  } catch (e) {
    return { ok: false, code: 'refused', message: e instanceof DbError || e instanceof Error ? e.message.replace(/^.*?ERROR:\s*/, '') : 'Something went wrong.' };
  }
}

/** 2411: the whole person behind a lead (read lead_context), for the lead cards' Renter button; the database decides how much
 *  this person sees (an Admin everything; staff the full context only within the renter's window or when the lead is theirs). */
export async function leadContextRead<T = Record<string, unknown>>(lead: string): Promise<ActionResult<T>> {
  if (!/^[0-9a-f-]{36}$/i.test(lead)) return { ok: false, code: 'invalid', message: 'Unknown lead.' };
  try {
    const user = await currentUser();
    if (!user) return { ok: false, code: 'auth', message: 'Sign in first.' };
    return { ok: true, data: await door<T>(user.id, 'ops_read', 'lead_context', { lead }, await sessionAal()) };
  } catch (e) {
    return { ok: false, code: 'refused', message: e instanceof DbError || e instanceof Error ? e.message.replace(/^.*?ERROR:\s*/, '') : 'Something went wrong.' };
  }
}
