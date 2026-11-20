'use server';
import { revalidatePath } from 'next/cache';
import { rpc } from '@/lib/db/repo';
import type { Json } from '@/lib/db/types';
import { currentUser } from '@/server/portal/data';
import { viewAs } from '@/server/view-as';
import type { DataIssue } from '@/features/data-checks/model';

// r48 FE (3197): the pop-up's fixes, saved on the person's own record (never while an Admin views as someone), then the
// checks run again. A fix of the staff agreement's inputs makes and sends the agreement at once.
const SR = { role: 'service_role' as const, skipViewAs: true };
type Out = { ok: true; open: DataIssue[]; agreement?: string } | { ok: false; message: string };
const msg = (e: unknown) => (e instanceof Error ? e.message : String(e)).replace(/^.*?ERROR:\s*/, '');

async function me() {
  const user = await currentUser();
  if (!user) throw new Error('Sign in first.');
  if (await viewAs().catch(() => null)) throw new Error('Read only while viewing as someone.');
  return user;
}

export async function saveDataFix(kind: string, audience: string, values: Record<string, string | boolean>): Promise<Out> {
  try {
    const user = await me();
    const r = (await rpc('server_data_fix_save', { p_user: user.id, p: { ...values, kind, audience } as unknown as Json }, SR)) as unknown as { open: DataIssue[] };
    let agreement: string | undefined;
    if (kind === 'agreement' || kind === 'address') {
      const { sendStaffAgreementNow } = await import('@/server/staff-agreement-auto');
      agreement = await sendStaffAgreementNow(user.id).catch(() => 'failed');
    }
    revalidatePath('/', 'layout');
    const open = agreement ? ((await rpc('server_data_checks', { p_user: user.id }, SR)) as unknown as DataIssue[]) : r.open;
    return { ok: true, open, ...(agreement ? { agreement } : {}) };
  } catch (e) { return { ok: false, message: msg(e) }; }
}

export async function answerDataCheck(key: string, action: 'dismiss' | 'confirm', reason?: string): Promise<Out> {
  try {
    const user = await me();
    const r = (await rpc('server_data_check_answer', { p_user: user.id, p: { key, action, reason: reason ?? null } as unknown as Json }, SR)) as unknown as { open: DataIssue[] };
    return { ok: true, open: r.open };
  } catch (e) { return { ok: false, message: msg(e) }; }
}
