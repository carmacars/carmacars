'use server';
import { DbError, rpc } from '@/lib/db/repo';
import { currentUser } from '@/server/portal/data';
import { requestMeta } from '@/server/request';
import { viewAs } from '@/server/view-as';

// Accept an updated version (0721): who (the session), when (the database), the IP address and the device, the version
// and the SHA-256 of the text shown; the database checks the version binds this person and the text is the same.
export async function acceptTerms(versionId: string, sha: string, portal: string): Promise<{ ok: boolean; message?: string; pending?: number }> {
  try {
    const user = await currentUser();
    if (!user) return { ok: false, message: 'Sign in first.' };
    if (await viewAs()) return { ok: false, message: 'Read only while viewing as someone.' };
    if (!/^[0-9a-f-]{36}$/.test(versionId) || !/^[0-9a-f]{64}$/.test(sha)) return { ok: false, message: 'Reload the page and try again.' };
    const meta = await requestMeta();
    const r = (await rpc('server_terms_accept', { p_by: user.id, p: { version_id: versionId, body_sha256: sha, ip: meta.ip, user_agent: meta.userAgent, portal } }, { role: 'service_role' })) as unknown as { pending: number };
    return { ok: true, pending: r.pending };
  } catch (e) { return { ok: false, message: e instanceof DbError || e instanceof Error ? e.message.replace(/^.*?ERROR:\s*/, '') : 'Something went wrong. Try again.' }; }
}
