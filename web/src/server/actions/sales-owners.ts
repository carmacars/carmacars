'use server';
import { revalidatePath } from 'next/cache';
import { env } from '@/lib/env';
import { DbError, rpc } from '@/lib/db/repo';
import type { ActionResult } from '@/features/forms/schemas';
import { currentUser } from '@/server/portal/data';
import { door, rolesOf, sessionAal } from '@/server/door';
import { signToken } from '@/server/links';

// Sales bring in car owners (migration 0340): the invitation a salesperson sends (the lead first, then the signed link by
// email) and their commission request for an owner. The database checks that the person works in Sales and that the
// owner is theirs; the signed link carries who invited, so the application is credited to them.
type R<T = unknown> = ActionResult<T>;
const SR = { role: 'service_role' as const };
const INVITE_DAYS = 30;
const fail = (e: unknown): R<never> => ({ ok: false, code: 'refused', message: e instanceof DbError || e instanceof Error ? e.message.replace(/^.*?ERROR:\s*/, '') : 'Something went wrong.' });

async function assertSales() {
  const user = await currentUser();
  if (!user) throw new Error('Sign in first.');
  const roles = await rolesOf(user.id);
  if (!roles.va_functions?.includes('sales') && roles.va !== 'sales') throw new Error('Sales staff only.');
  const aal = await sessionAal();
  if (roles.two_step_required && aal !== 'aal2') throw new Error('Two-step sign-in is required.');
  return { user, aal };
}

/** The invitation: the owner's name, email and phone; "asked" says the owner asked for it. */
export async function salesInviteOwner(p: { name: string; email: string; phone: string; asked: boolean }): Promise<R<{ email: string }>> {
  const fe: Record<string, string> = {};
  if (!p.name?.trim()) fe.name = 'Enter the owner\'s name.';
  if (!/^[^@\s]+@[^@\s]+\.[^@\s]+$/.test(p.email?.trim() ?? '')) fe.email = 'Enter the owner\'s email address, for example name@example.com.';
  if (!p.asked) fe.asked = 'Send it only to an owner who asked you for it.';
  if (Object.keys(fe).length) return { ok: false, code: 'invalid', message: 'Check the highlighted fields.', fieldErrors: fe };
  try {
    const { user, aal } = await assertSales();
    const lead = await door<{ lead_id: string; name: string; email: string }>(user.id, 'va_do', 'sales_owner_invite',
      { name: p.name.trim(), email: p.email.trim().toLowerCase(), phone: p.phone?.trim() || null, asked: true, _va: 'sales' }, aal);
    const base = env().NEXT_PUBLIC_APP_URL.replace(/\/$/, '');
    const url = `${base}/list-your-car/apply?invite=${await signToken('owner-invite', { e: lead.email, n: lead.name, l: lead.lead_id, s: user.id }, INVITE_DAYS * 86400)}`;
    await rpc('server_send_link_email', { p_email: lead.email, p_name: lead.name, p_url: url, p_expiry: `${INVITE_DAYS} days`, p_key: `sales-invite:${lead.lead_id}:${Date.now()}` }, SR);
    revalidatePath('/staff/my-sales');
    return { ok: true, data: { email: lead.email } };
  } catch (e) { return fail(e); }
}

/** The commission a salesperson asks for an owner they brought in: a flat amount, or a percent of a base for a time. */
export async function salesAskCommission(p: { owner_id: string; kind: 'flat' | 'percent'; amount_cents?: number; rate_bps?: number; base?: string; duration?: 'months' | 'while'; months?: number; note?: string }): Promise<R<{ asked: string }>> {
  try {
    const { user, aal } = await assertSales();
    const r = await door<{ asked: string }>(user.id, 'va_do', 'sales_owner_commission_request', { ...p, _va: 'sales' }, aal);
    revalidatePath('/staff/my-sales');
    return { ok: true, data: r };
  } catch (e) { return fail(e); }
}
