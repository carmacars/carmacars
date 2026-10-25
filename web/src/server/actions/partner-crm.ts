'use server';
import { revalidatePath } from 'next/cache';
import { rpc, DbError } from '@/lib/db/repo';
import type { Json } from '@/lib/db/types';
import type { ActionResult } from '@/features/forms/schemas';
import { assertAdmin } from '@/server/admin/data';
import { door } from '@/server/door';
import { runPartnerCrm, testPartnerCrm } from '@/server/partner-crm';
import { isUuid } from '@/features/partner-crm/feed-key';

// Admin > Settings > Partners > a partner (migration 0147): connect (their Private Integration token and location ID,
// straight to the vault through public.server_partner_crm_token; the token is never stored elsewhere, logged or sent
// back), Test connection, Run sync now. The other settings go through the door (admin_do partner_crm_*).
type R<T = unknown> = ActionResult<T>;
const fail = (e: unknown): R<never> => ({ ok: false, code: 'refused', message: e instanceof DbError || e instanceof Error ? e.message.replace(/^.*?ERROR:\s*/, '').replace(/pit-[A-Za-z0-9-]+/g, 'pit-[token]') : 'Something went wrong.' });
const page = (id: string) => { revalidatePath(`/admin/settings/partners/${id}`); revalidatePath('/admin/settings/partners'); };

async function linkOf(adminId: string, partnerId: string): Promise<string> {
  const r = await door<{ link: { id: string } } | null>(adminId, 'admin_read', 'partner_crm', { partner_id: partnerId });
  if (!r?.link?.id) throw new Error('Partner not found');
  return r.link.id;
}

export interface ConnectResult { token_hint: string; location_id: string; store: string; test: { ok: boolean; error: string | null }; sync: { ok: boolean; error: string | null } | null }

/** Connect: the token to the vault, then Test connection, then the first sync when the test passed. */
export async function connectPartnerCrm(partnerId: string, token: string, locationId: string): Promise<R<ConnectResult>> {
  try {
    const admin = await assertAdmin();
    if (!isUuid(partnerId)) return { ok: false, code: 'invalid', message: 'Partner not found' };
    const t = String(token ?? '').trim();
    const loc = String(locationId ?? '').trim();
    if (!t) return { ok: false, code: 'invalid', message: 'Paste their Private Integration token.', fieldErrors: { token: 'Required.' } };
    if (!/^[A-Za-z0-9_-]{6,64}$/.test(loc)) return { ok: false, code: 'invalid', message: 'Give their location ID.', fieldErrors: { location_id: 'Letters and digits, from their GoHighLevel address after /location/.' } };
    const id = await linkOf(admin.id, partnerId);
    const saved = (await rpc('server_partner_crm_token', { p_admin: admin.id, p: { partner_id: partnerId, token: t, location_id: loc } as unknown as Json }, { role: 'service_role' })) as unknown as { token_hint: string; location_id: string; store: string };
    const test = await testPartnerCrm(id, admin.id);
    const sync = test.ok ? await runPartnerCrm(id, admin.id) : null;
    page(partnerId);
    return { ok: true, data: { ...saved, test: { ok: test.ok, error: test.error }, sync: sync ? { ok: sync.ok, error: sync.error } : null } };
  } catch (e) { return fail(e); }
}

export async function testPartnerCrmAction(partnerId: string): Promise<R<{ ok: boolean; error: string | null }>> {
  try {
    const admin = await assertAdmin();
    const r = await testPartnerCrm(await linkOf(admin.id, partnerId), admin.id);
    page(partnerId);
    return { ok: true, data: { ok: r.ok, error: r.error } };
  } catch (e) { return fail(e); }
}

export async function syncPartnerCrmNow(partnerId: string): Promise<R<{ ok: boolean; error: string | null; busy?: boolean; counts?: Record<string, unknown> }>> {
  try {
    const admin = await assertAdmin();
    await door(admin.id, 'admin_do', 'partner_crm_sync_now', { partner_id: partnerId });
    const r = await runPartnerCrm(await linkOf(admin.id, partnerId), admin.id);
    page(partnerId);
    return { ok: true, data: r };
  } catch (e) { return fail(e); }
}
