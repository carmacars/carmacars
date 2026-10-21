'use server';
import { revalidatePath } from 'next/cache';
import { DbError, rpc } from '@/lib/db/repo';
import { CONFIRMATIONS, OWNER_SIGN_STATEMENT } from '@/features/owner-agreement/model';
import type { PackageInput, PackageResult } from '@/features/signing/PackageSignForm';
import { requestMeta } from '@/server/request';
import { storeDrawnSignature } from '@/server/sign-requests';
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
    const fe: Record<string, string> = {};
    if (!input.statements.includes('statement')) fe.statements = 'Tick the statement to sign.';
    if (enrollment && !CONFIRMATIONS.every((c) => input.statements.includes(c.code))) fe.statements = 'Tick the statements (one tap on "All of these").';
    const initials = (input.initials ?? '').trim().toUpperCase();
    if (enrollment && !/^[A-Z]{1,4}$/.test(initials)) fe.initials = 'Your initials, letters only.';
    if (input.method === 'typed' && !(input.typedName ?? '').trim()) fe.signature = 'Use your name or draw your signature.';
    if (input.method === 'drawn' && !input.drawn) fe.signature = 'Draw your signature in the box.';
    if (Object.keys(fe).length) return { ok: false, code: 'invalid', message: 'Check the highlighted part.', fieldErrors: fe };
    const drawnPath = input.method === 'drawn' ? await storeDrawnSignature(`cosigner-${f.cosigner.id}`, input.drawn!) : null;
    const meta = await requestMeta();
    const res = (await rpc('server_owner_cosigner_sign', { p_token: token, p: {
      typed_name: input.method === 'typed' ? input.typedName!.trim() : null, drawn_signature: drawnPath, ip: meta.ip, user_agent: meta.userAgent,
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
