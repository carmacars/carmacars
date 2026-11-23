'use server';
import { revalidatePath } from 'next/cache';
import { refusalMessage } from '@/lib/db/refusal';
import type { ActionResult } from '@/features/forms/schemas';
import { currentUser } from '@/server/portal/data';
import { door, rolesOf, sessionAal } from '@/server/door';
import type { BankProvider } from '@/integrations/bank/types';

// Release 49 (3480): pull a live bank feed (Program setting bank_data_provider). Admins and Finance only; the database
// checks it again (app.bank_import: app.user_runs_finance).
export async function financeFeedSync(): Promise<ActionResult<{ accounts: number; lines_new: number; lines_matched: number }>> {
  try {
    const user = await currentUser();
    if (!user) throw new Error('Sign in first.');
    const roles = await rolesOf(user.id);
    const finance = roles.va_functions?.includes('finance') || roles.va === 'finance';
    if (!roles.admin && !finance) throw new Error('Finance or an Admin pulls the bank feed.');
    const aal = await sessionAal();
    if (!roles.admin && roles.two_step_required && aal !== 'aal2') throw new Error('Two-step sign-in is required.');
    const call = roles.admin ? 'admin_do' : 'va_do';
    const v = await door<{ provider: BankProvider }>(user.id, roles.admin ? 'admin_read' : 'va_read', 'bank_lines', { limit: 1 }, aal);
    const { syncBankFeed } = await import('@/server/finance');
    const data = await syncBankFeed(user.id, call, v.provider, aal);
    for (const p of ['/admin/finance', '/staff/finance']) revalidatePath(p);
    return { ok: true, data };
  } catch (e) { return { ok: false, code: 'refused', message: refusalMessage(e) }; }
}
