'use server';
import { revalidatePath } from 'next/cache';
import { DbError } from '@/lib/db/repo';
import type { ActionResult } from '@/features/forms/schemas';
import type { FormCInput } from '@/features/owner/FormCSignForm';
import { requireOwnerUser } from '@/server/owner/data';
import { signDocument } from '@/server/sign-requests';

// Form C signed on screen (the legal review, migration 0053): the owner's signature and initials (the signing session of
// 0182: the database checks the signature against it), and the witness's typed name and statement, recorded together;
// the database checks every one again.
const msg = (e: unknown) => (e instanceof DbError || e instanceof Error ? e.message.replace(/^.*?ERROR:\s*/, '') : 'Something went wrong. Try again.');

export async function signFormC(id: string, sha: string, input: FormCInput): Promise<ActionResult<{ next: string }>> {
  try {
    const user = await requireOwnerUser();
    const e = input.esign;
    const drawnPath = e?.method === 'drawn' && e.drawnPath ? e.drawnPath : undefined;
    const typedName = e?.method === 'typed' && e.typedName?.trim() ? e.typedName.trim() : undefined;
    if (!e?.session || (!drawnPath && !typedName)) return { ok: false, code: 'invalid', message: 'Check the highlighted part.', fieldErrors: { signature: 'Finish the owner\'s signing steps: the code, the reading, the initials, the consents and the signature.' } };
    await signDocument(user.id, { id, sha, typedName, drawnPath,
      initials: /^[A-Za-z]{1,4}$/.test(input.initials.trim()) ? input.initials.trim() : 'X', consent: 'I sign Form C electronically, in the presence of my witness.',
      extra: { witness_name: input.witnessName, witness_statement: input.witnessStatement, acknowledgments: input.acknowledgments } });
    for (const p of ['/owner', '/owner/documents', '/owner/sign']) revalidatePath(p);
    return { ok: true, data: { next: '/owner/documents?signed=c' } };
  } catch (e) { return { ok: false, code: 'refused', message: msg(e) }; }
}
