'use server';
import { revalidatePath } from 'next/cache';
import { DbError, rpc } from '@/lib/db/repo';
import { OWNER_SIGN_STATEMENT } from '@/features/owner-agreement/model';
import type { PackageInput, PackageResult } from '@/features/signing/PackageSignForm';
import { requestMeta } from '@/server/request';
import { queueOwnerSignedCopies, type SignedResult } from '@/server/owner/agreements';

// Another Owner named in the Title Schedule signs with their own link (the legal review, migration 0053): no account, the
// link's token names them. Their own signature record goes on each open document; the last Owner to sign completes the
// agreements (CarmaCars countersigns) and the signed copies are filed.
const SR = { role: 'service_role' as const };
const msg = (e: unknown) => (e instanceof DbError || e instanceof Error ? e.message.replace(/^.*?ERROR:\s*/, '') : 'Something went wrong. Try again or call us.');

interface CosignFacts {
  cosigner: { id: string; name: string; email: string; status: string; signed_at: string | null };
  owner: { id: string; legal_name: string; user_id: string | null };
  documents: Array<{ key: string; signature_request_id: string; sha256: string }>;
}

export async function signAsCosigner(token: string, input: PackageInput): Promise<PackageResult> {
  try {
    if (!/^[0-9a-f]{64}$/.test(token)) return { ok: false, code: 'refused', message: 'This link is not valid.' };
    const f = (await rpc('server_owner_cosigner_facts', { p_token: token }, SR)) as unknown as CosignFacts | null;
    if (!f) return { ok: false, code: 'refused', message: 'This link is not valid any more.' };
    const enrollment = f.documents.some((d) => d.key === 'enrollment');
    // the signature of the signing session (0193): the code to their email, the reading, the confirmations initialled,
    // the consents, the drawn signature; the database checks it against the session
    const e = input.esign;
    const drawnPath = e?.method === 'drawn' && e.drawnPath ? e.drawnPath : null;
    const typedName = e?.method === 'typed' && e.typedName?.trim() ? e.typedName.trim() : null;
    if (!e?.session || (!drawnPath && !typedName)) {
      return { ok: false, code: 'invalid', message: 'Check the highlighted part.', fieldErrors: { signature: 'Finish the signing steps: the code, the reading, the initials, the consents and your signature.' } };
    }
    const initials = /^[A-Z]{1,4}$/.test((input.initials ?? '').trim().toUpperCase()) ? (input.initials ?? '').trim().toUpperCase() : 'X';
    const meta = await requestMeta();
    const res = (await rpc('server_owner_cosigner_sign', { p_token: token, p: {
      typed_name: typedName, drawn_signature: drawnPath, ip: meta.ip, user_agent: meta.userAgent,
      consent_text: OWNER_SIGN_STATEMENT, initials: enrollment ? initials : null,
      documents: f.documents.map((d) => ({ signature_request_id: d.signature_request_id, sha256: d.sha256 })) } }, SR)) as unknown as SignedResult & { complete: boolean };
    if (res.complete && f.owner.user_id) {
      try { await queueOwnerSignedCopies(f.owner.id, f.owner.user_id, res); } catch (e) { console.error('owner signed copy job', e); }
    }
    for (const p of ['/owner', '/owner/sign', '/owner/documents']) revalidatePath(p);
    return { ok: true, data: { signed: res.signed?.length ?? f.documents.length,
      message: res.complete ? 'Signed. Every Owner has signed: the agreements are in effect and CarmaCars countersigned them. The signed copies go to the owner portal.'
        : 'Signed. The agreements take effect when every Owner has signed.' } };
  } catch (e) { return { ok: false, code: 'refused', message: msg(e) }; }
}
