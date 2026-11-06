'use server';
import { redirect } from 'next/navigation';
import { revalidatePath } from 'next/cache';
import { rpc } from '@/lib/db/repo';
import { assertAdmin } from '@/server/admin/data';
import { viewAs } from '@/server/view-as';
import { SCOPES, newSecret, secretPrefix, sha256Hex, type Scope } from '@/features/api-access/tools';
import type { ActionResult } from '@/features/forms/schemas';

// API access (release 28, B3; migration 0562): Admin creates and revokes keys; an Admin approves the Claude connector.
// The secret of a new key is returned once and never stored (only its SHA-256).
const SR = { role: 'service_role' as const };
const msg = (e: unknown) => (e instanceof Error ? e.message.replace(/^.*?ERROR:\s*/, '') : 'Something went wrong.');
async function adminNotViewing() {
  if (await viewAs()) throw new Error('Stop viewing as someone first.');
  return assertAdmin();
}

export async function createApiKey(form: FormData): Promise<ActionResult<{ secret: string; name: string }>> {
  try {
    const admin = await adminNotViewing();
    const name = String(form.get('name') ?? '').trim().slice(0, 80);
    const userId = String(form.get('user_id') ?? '');
    const scopes = SCOPES.filter((s) => form.get(`scope:${s}`) === 'on');
    if (!name) return { ok: false, code: 'invalid', message: 'Give the key a name (for example "Claude Code on Abbas\'s laptop").' };
    if (!scopes.length) return { ok: false, code: 'invalid', message: 'Choose at least one scope.' };
    const secret = newSecret('cc_live_');
    await rpc('server_api_key_create', { p_admin: admin.id, p_user: userId, p_name: name, p_scopes: scopes, p_hash: await sha256Hex(secret), p_prefix: secretPrefix(secret) }, SR);
    revalidatePath('/admin/settings/api');
    return { ok: true, data: { secret, name } };
  } catch (e) { return { ok: false, code: 'error', message: msg(e) }; }
}

export async function revokeApiKey(id: string): Promise<ActionResult<{ id: string }>> {
  try {
    const admin = await adminNotViewing();
    await rpc('server_api_key_revoke', { p_admin: admin.id, p_id: id }, SR);
    revalidatePath('/admin/settings/api');
    return { ok: true, data: { id } };
  } catch (e) { return { ok: false, code: 'error', message: msg(e) }; }
}

/** The consent page's Allow or Deny: a one-time code back to Claude, or access_denied. */
export async function decideOAuth(form: FormData): Promise<void> {
  const redirectUri = String(form.get('redirect_uri') ?? '');
  const state = String(form.get('state') ?? '');
  const back = (q: Record<string, string>) => {
    const u = new URL(redirectUri);
    for (const [k, v] of Object.entries(q)) u.searchParams.set(k, v);
    if (state) u.searchParams.set('state', state);
    return u.toString();
  };
  if (!/^(https:\/\/(claude\.ai|claude\.com)\/|http:\/\/(localhost|127\.0\.0\.1)(:\d{1,5})?\/)/.test(redirectUri)) throw new Error('Unknown return address.');
  if (form.get('decision') !== 'allow') redirect(back({ error: 'access_denied' }));
  const admin = await adminNotViewing();
  const scopes = SCOPES.filter((s) => form.get(`scope:${s}`) === 'on') as Scope[];
  if (!scopes.length) redirect(back({ error: 'invalid_scope', error_description: 'No scope was allowed' }));
  const code = newSecret('ccx_');
  await rpc('server_api_oauth_approve', { p_user: admin.id, p_client_id: String(form.get('client_id') ?? ''), p_redirect: redirectUri,
    p_challenge: String(form.get('code_challenge') ?? ''), p_scopes: scopes, p_code_hash: await sha256Hex(code) }, SR);
  redirect(back({ code }));
}
