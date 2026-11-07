import 'server-only';
import { revalidatePath } from 'next/cache';
import { auth } from '@/lib/auth';
import { rpc } from '@/lib/db/repo';
import type { ActionResult } from '@/features/forms/schemas';
import type { InviteInput } from '@/server/actions/admin-portal';

type R<T = unknown> = ActionResult<T>;

/** Invite a person into a role as this Admin (the screens' inviteAccount after its Admin check, and one-step Hire, also from
 *  the Claude connector: release 33). The sign-in account is made first and emailed a link to choose a password; then the
 *  database gives it the role (app.admin_invite_account, 0036, which checks the Admin again). Someone who already signs in
 *  just gets the role: no email. */
export async function inviteAs(adminId: string, i: InviteInput): Promise<R<{ user_id: string; existed: boolean; email: string }>> {
  const email = (i.email ?? '').trim().toLowerCase();
  const fe: Record<string, string> = {};
  if (!/^[^@\s]+@[^@\s]+\.[^@\s]+$/.test(email)) fe.email = 'Enter an email address.';
  if (!['admin', 'staff', 'va', 'field', 'owner', 'investor'].includes(i.role)) fe.role = 'Choose the role.';
  if (['admin', 'staff', 'va', 'field'].includes(i.role) && (i.full_name ?? '').trim().length < 2) fe.full_name = 'Enter the name.';
  if (i.role === 'staff' && !(i.functions ?? []).filter(Boolean).length) fe.functions = 'Choose at least one.';
  if (i.role === 'va' && !i.va_function) fe.va_function = 'Choose one.';
  if (i.role === 'field' && !i.field_function) fe.field_function = 'Choose one.';
  if (i.role === 'owner' && !i.owner_id) fe.owner_id = 'Choose the owner on file.';
  if (i.role === 'investor' && !i.investor_id) fe.investor_id = 'Choose the investor on file.';
  if (Object.keys(fe).length) return { ok: false, code: 'invalid', message: 'Check the highlighted fields.', fieldErrors: fe };
  const a = await auth();
  const { passwordLinkTarget } = await import('@/server/auth-links');
  const name = (i.full_name ?? '').trim();
  if (!a.invite || !a.createForRecord) return { ok: false, code: 'refused', message: 'Invitations are not available.' };
  let userId = (await rpc('server_user_by_email', { p_email: email }, { role: 'service_role' })) as unknown as string | null;
  let existed = false;
  if (userId) {
    // already on file (a renter, a booking request, an earlier invitation): a sign-in for that record, unless it has one
    const made = await a.createForRecord(userId, email, name, passwordLinkTarget());
    if (!made.ok && made.code === 'exists') existed = true;
    else if (!made.ok) return { ok: false, code: 'refused', message: made.message };
  } else {
    const invited = await a.invite(email, name, passwordLinkTarget());
    if (!invited.ok) return { ok: false, code: 'refused', message: invited.code === 'exists'
      ? 'This address has a sign-in that is not linked to a CarmaCars record. Ask them to use Forgot password, then invite them again.' : invited.message };
    userId = invited.user.id;
  }
  await rpc('admin_invite_account', { p_admin: adminId, p: { user_id: userId, email, full_name: name || null, role: i.role, va_function: i.va_function || null,
    cover_functions: (i.cover_functions ?? []).filter(Boolean), ...(i.role === 'staff' ? { functions: (i.functions ?? []).filter(Boolean) } : {}), field_function: i.field_function || null, owner_id: i.owner_id || null, investor_id: i.investor_id || null,
    ...(i.work_mode ? { work_mode: i.work_mode } : {}) } }, { role: 'service_role' });
  try { revalidatePath('/admin/settings/staff'); revalidatePath('/admin/portals'); revalidatePath('/admin/owners'); revalidatePath('/admin/investors'); } catch { /* outside a render (the connector) */ }
  return { ok: true, data: { user_id: userId, existed, email } };
}
