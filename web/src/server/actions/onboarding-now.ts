'use server';
import { revalidatePath } from 'next/cache';
import { currentUser } from '@/server/portal/data';
import { door, rolesOf, sessionAal } from '@/server/door';
import { viewAs } from '@/server/view-as';
import { signHref } from '@/features/academy/gate';

// R51 (5304, REQ-135): Sign now on Welcome. The person asks for their staff agreement: the database clears the
// agreements job's wait for them, the agreement is made and sent at once, and the page opens it to sign. If it still
// waits for something only CarmaCars sets, the Admins get an urgent alert and the page says what is missing.
export type SignNow = { ok: true; href: string } | { ok: false; message: string; missing?: string[] };

export async function agreementSignNow(): Promise<SignNow> {
  try {
    const user = await currentUser();
    if (!user) return { ok: false, message: 'Sign in first.' };
    if (await viewAs().catch(() => null)) return { ok: false, message: 'Read only while viewing as someone.' };
    const [roles, aal] = await Promise.all([rolesOf(user.id), sessionAal()]);
    const href = signHref(roles.va ? 'va' : 'field');
    const st = await door<{ state: string; missing?: string[]; error?: string | null }>(user.id, 'ops_do', 'staff_agreement_now', {}, aal);
    if (st.state === 'sent') return { ok: true, href };
    if (st.state === 'signed' || st.state === 'waived') return { ok: true, href: '/staff/welcome' };
    const { sendStaffAgreementNow } = await import('@/server/staff-agreement-auto');
    const r = await sendStaffAgreementNow(user.id).catch(() => 'failed' as const);
    revalidatePath('/staff/welcome');
    if (r === 'sent') return { ok: true, href };
    await door(user.id, 'ops_do', 'staff_agreement_help', {}, aal).catch(() => null);
    const again = await door<{ steps: Array<{ key: string; missing?: string[] }> }>(user.id, 'ops_read', 'staff_welcome', {}, aal).catch(() => null);
    const missing = again?.steps.find((s) => s.key === 'agreement')?.missing ?? st.missing ?? [];
    return { ok: false, missing,
      message: missing.length ? `Your agreement still needs: ${missing.join(', ')}. CarmaCars has been told and will set it; you can also call us.`
        : 'Your agreement could not be made just now. CarmaCars has been told and will send it to you here.' };
  } catch (e) {
    return { ok: false, message: (e instanceof Error ? e.message : String(e)).replace(/^.*?ERROR:\s*/, '').slice(0, 200) };
  }
}
