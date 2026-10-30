'use server';
import { revalidatePath } from 'next/cache';
import type { ActionResult } from '@/features/forms/schemas';
import { door } from '@/server/door';
import { assertAdmin } from '@/server/admin/data';
import { inviteAccount } from '@/server/actions/admin-portal';

// Hire a candidate (migration 0173): the existing staff invitation (inviteAccount: the sign-in and app.admin_invite_account) in the
// staff portal with the role's functions (field work, or the role's office function; both sales roles are the Sales function, with the role's work
// mode passed along), then app.hiring_hire records it on the application.
export async function hireApplicant(id: string): Promise<ActionResult<{ user_id: string; existed: boolean; email: string }>> {
  try {
    const admin = await assertAdmin();
    if (!/^[0-9a-f-]{36}$/i.test(id ?? '')) return { ok: false, code: 'invalid', message: 'Choose a candidate.' };
    const a = await door<{ application: { email: string | null; full_name: string; status: string }; role: { staff_kind: 'field' | 'va'; va_function: string | null; cover_functions: string[]; work_mode: 'in_person' | 'remote' | null } }>(admin.id, 'admin_read', 'hiring_application', { id });
    if (!a.application.email) return { ok: false, code: 'refused', message: 'This application has no email address.' };
    // one staff portal (0197): the role's functions (a field role is field work; an office role its function and the ones it covers)
    const functions = a.role.staff_kind === 'field' ? ['field'] : [a.role.va_function ?? 'cs', ...(a.role.cover_functions ?? [])];
    const inv = await inviteAccount({ email: a.application.email, full_name: a.application.full_name, role: 'staff', functions,
      ...(functions.includes('field') ? { field_function: 'driver_detailer' } : {}), work_mode: a.role.work_mode });
    if (!inv.ok) return inv;
    await door(admin.id, 'admin_do', 'hiring_hire', { id, user_id: inv.data.user_id });
    revalidatePath('/admin/hiring'); revalidatePath(`/admin/hiring/${id}`);
    return { ok: true, data: inv.data };
  } catch (e) {
    return { ok: false, code: 'refused', message: e instanceof Error ? e.message.replace(/^.*?ERROR:\s*/, '') : 'Something went wrong.' };
  }
}
