'use server';
import { revalidatePath } from 'next/cache';
import { DbError } from '@/lib/db/repo';
import type { ActionResult } from '@/features/forms/schemas';
import { currentUser } from '@/server/portal/data';
import { door } from '@/server/door';

// An investor's requests (07-investor.md section 2): each becomes a task for an Admin, who records it.
export async function investorRequest(action: 'election_change' | 'bank_change' | 'transfer_request', p: Record<string, unknown>): Promise<ActionResult<{ task_id: string }>> {
  try {
    if (!['election_change', 'bank_change', 'transfer_request'].includes(action)) return { ok: false, code: 'invalid', message: 'Unknown request.' };
    const user = await currentUser();
    if (!user) return { ok: false, code: 'auth', message: 'Sign in first.' };
    const data = await door<{ task_id: string }>(user.id, 'investor_do', action, p);
    revalidatePath('/investor');
    return { ok: true, data };
  } catch (e) {
    return { ok: false, code: 'refused', message: e instanceof DbError || e instanceof Error ? e.message.replace(/^.*?ERROR:\s*/, '') : 'Something went wrong.' };
  }
}
