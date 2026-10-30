'use server';
import { revalidatePath } from 'next/cache';
import { DbError, rpc } from '@/lib/db/repo';
import type { Json } from '@/lib/db/types';
import type { ActionResult } from '@/features/forms/schemas';
import { currentUser } from '@/server/portal/data';
import { door, rolesOf, sessionAal } from '@/server/door';
import { requestMeta } from '@/server/request';
import { kickPdfJobs } from '@/server/pdf-jobs';
import { SIGN_STATEMENT } from '@/features/agreement/model';

// The Agreement card of a booking (migration 0154): fill what the agreements are missing, an Admin's override of the
// check-out check, resend the links of a version waiting, make the agreements again, the dispute evidence pack; and the
// signer's signature on a new version (their link). The database checks who may do each.
type R<T = null> = ActionResult<T>;
const SR = { role: 'service_role' as const };
const fail = (e: unknown): R<never> => ({ ok: false, code: 'refused', message: e instanceof DbError || e instanceof Error ? e.message.replace(/^.*?ERROR:\s*/, '') : 'Something went wrong.' });

async function staff() {
  const user = await currentUser();
  if (!user) throw new Error('Sign in first.');
  const roles = await rolesOf(user.id);
  if (!roles.admin && !roles.va && !roles.field) throw new Error('Staff only.');
  const aal = await sessionAal();
  if (roles.two_step_required && aal !== 'aal2') throw new Error('Two-step sign-in is required.');
  return { user, aal };
}
const again = (refresh?: string[]) => { for (const p of refresh ?? []) revalidatePath(p); kickPdfJobs(); };

export async function agreementFill(booking: string, p: Record<string, unknown>, refresh?: string[]): Promise<R<{ missing: unknown[] }>> {
  try { const { user, aal } = await staff(); const r = await door<{ missing: unknown[] }>(user.id, 'ops_do', 'agreement_fill', { ...p, booking }, aal); again(refresh); return { ok: true, data: r }; } catch (e) { return fail(e); }
}
/** 0198: an Admin rewords a clause of CarmaCars' agreement for this booking (edit, add, remove, restore), with a reason. */
export async function agreementWordingSave(booking: string, p: { code: string; action: 'edit' | 'add' | 'remove' | 'restore'; text?: string; reason: string }, refresh?: string[]): Promise<R<{ agreement: string | null }>> {
  try { const { user, aal } = await staff(); const r = await door<{ agreement: string | null }>(user.id, 'ops_do', 'agreement_wording_save', { ...p, booking }, aal); again(refresh); return { ok: true, data: r }; } catch (e) { return fail(e); }
}
export async function agreementOverride(booking: string, reason: string, refresh?: string[]): Promise<R> {
  try { const { user, aal } = await staff(); await door(user.id, 'ops_do', 'agreement_override', { booking, reason }, aal); for (const p of refresh ?? []) revalidatePath(p); return { ok: true, data: null }; } catch (e) { return fail(e); }
}
export async function agreementResend(booking: string, refresh?: string[]): Promise<R<{ sent: number }>> {
  try { const { user, aal } = await staff(); const r = await door<{ sent: number }>(user.id, 'ops_do', 'agreement_resend', { booking }, aal); for (const p of refresh ?? []) revalidatePath(p); return { ok: true, data: r }; } catch (e) { return fail(e); }
}
export async function agreementRegenerate(booking: string, refresh?: string[]): Promise<R> {
  try { const { user, aal } = await staff(); await door(user.id, 'ops_do', 'agreement_regenerate', { booking }, aal); again(refresh); return { ok: true, data: null }; } catch (e) { return fail(e); }
}
export async function disputePackBuild(booking: string, refresh?: string[]): Promise<R<{ id: string }>> {
  try { const { user, aal } = await staff(); const r = await door<{ id: string }>(user.id, 'ops_do', 'dispute_pack_build', { booking }, aal); again(refresh); return { ok: true, data: r }; } catch (e) { return fail(e); }
}
export async function disputePackSubmit(booking: string, pack: string, refresh?: string[]): Promise<R> {
  try {
    const { user, aal } = await staff();
    await door(user.id, 'ops_do', 'dispute_pack_get', { booking, pack }, aal); // an Admin or Finance, this booking's pack
    const { submitDisputePack } = await import('@/server/agreements/dispute-pack');
    await submitDisputePack(pack, user.id);
    for (const p of refresh ?? []) revalidatePath(p);
    return { ok: true, data: null };
  } catch (e) { return fail(e); }
}

/** The signer of a new version signs (their link, or on a staff device): the session made the signature. */
export async function signVersion(token: string, input: { session: string; method: 'drawn' | 'typed'; drawnPath?: string; typedName?: string; carmacarsSha: string; blindspotSha: string | null }): Promise<R<{ version_signed: boolean }>> {
  try {
    if (!/^[0-9a-f-]{36}$/.test(token)) throw new Error('This link is not valid');
    const meta = await requestMeta();
    const r = (await rpc('server_agreement_version_sign', { p_token: token, p: { carmacars_sha256: input.carmacarsSha, blindspot_sha256: input.blindspotSha, consent_text: SIGN_STATEMENT,
      typed_name: input.typedName ?? null, drawn: input.drawnPath ?? null, ip: meta.ip ?? null, user_agent: meta.userAgent } as unknown as Json }, SR)) as unknown as { version_signed: boolean };
    if (r.version_signed) kickPdfJobs();
    return { ok: true, data: r };
  } catch (e) { return fail(e); }
}

/** Anyone holding a signed file checks it: the browser hashes it, the record answers found or not (no personal data). */
export async function verifySha(sha: string): Promise<R<{ found: boolean; title?: string; recorded_at?: string }>> {
  try {
    if (!/^[0-9a-f]{64}$/.test(sha)) throw new Error('Not a SHA-256');
    return { ok: true, data: (await rpc('server_verify_sha', { p_sha: sha }, SR)) as unknown as { found: boolean; title?: string; recorded_at?: string } };
  } catch (e) { return fail(e); }
}
