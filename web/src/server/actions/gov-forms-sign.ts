'use server';
import { revalidatePath } from 'next/cache';
import { DbError, rpc } from '@/lib/db/repo';
import type { Json } from '@/lib/db/types';
import type { PackageInput, PackageResult } from '@/features/signing/PackageSignForm';
import { requestMeta } from '@/server/request';
import { requireOwnerUser } from '@/server/owner/data';

// The owner signs each government form on screen (r35, 1000). The signing session (the reading, the consents, the drawn
// signature, each step with its time, IP address and device) is the one of every signature on the site; the database
// checks every form against it (the form's SHA-256) and records one signature per form, beside the form and never on it.
const SR = { role: 'service_role' as const };
const msg = (e: unknown) => (e instanceof DbError || e instanceof Error ? e.message.replace(/^.*?ERROR:\s*/, '') : 'Something went wrong. Try again or call us.');

export async function signGovernmentForms(vehicleId: string, forms: Array<{ fill: string; sha: string; title: string }>, input: PackageInput): Promise<PackageResult> {
  try {
    const user = await requireOwnerUser(`/owner/sign/forms/${vehicleId}`);
    if (!forms.length) return { ok: false, code: 'refused', message: 'Nothing to sign.' };
    const e = input.esign;
    const drawn = e?.session && e.method === 'drawn' && e.drawnPath ? e.drawnPath : null;
    const typed = e?.session && e.method === 'typed' && e.typedName?.trim() ? e.typedName.trim() : null;
    if (!drawn && !typed) return { ok: false, code: 'invalid', message: 'Check the highlighted part.', fieldErrors: { signature: 'Finish the signing steps: the reading, the consents and your signature.' } };
    const meta = await requestMeta();
    const titles = forms.map((f) => f.title);
    const r = (await rpc('owner_gov_forms_sign', { p_by: user.id, p: {
      forms: forms.map((f) => ({ fill: f.fill, sha256: f.sha })), drawn_signature: drawn, typed_name: typed, ip: meta.ip ?? null, user_agent: meta.userAgent,
      consent_text: `I have checked each government form and I sign each one electronically: ${titles.join('; ')}. My signature is a record of my agreement to the values on the form; it is not put on the official form, and I sign the printed form in ink at the registry.`
    } as unknown as Json }, SR)) as unknown as { signed: number };
    for (const p of ['/owner', '/owner/documents', `/owner/sign/forms/${vehicleId}`, `/owner/vehicles/${vehicleId}`]) revalidatePath(p);
    return { ok: true, data: { signed: r.signed, next: '/owner/documents#ow-forms', message: `Signed ${r.signed > 1 ? `all ${r.signed} forms` : 'the form'}. Your signature is recorded with the date and time. Print the forms and sign them in ink at the registry visit.` } };
  } catch (x) { return { ok: false, code: 'refused', message: msg(x) }; }
}
