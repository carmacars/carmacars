'use server';
import { revalidatePath } from 'next/cache';
import { DbError } from '@/lib/db/repo';
import type { ActionResult } from '@/features/forms/schemas';
import type { PackageInput, PackageResult } from '@/features/signing/PackageSignForm';
import { assertAdmin } from '@/server/admin/data';
import { door, sessionAal } from '@/server/door';
import { storage } from '@/integrations/storage';
import { sha256Hex } from '@/server/links';
import { isPdf } from '@/lib/file-sniff';
import { signDocument } from '@/server/sign-requests';
import { fileSignedCopy, sendForSigning } from '@/server/company-documents';
import { COMPANY_DOC_MAX_BYTES, COMPANY_SIGN_STATEMENT } from '@/features/company-documents/model';

// Admin > Company documents (r50, migration 5060). Admins only: every call checks the Admin here and again in the database.
//   save     a new document or a new version: a PDF (its first bytes checked, under 20 MB, stored privately under
//            company-documents/<document>/<file>.pdf in the documents bucket) or a text to sign (its signers; once every
//            fill-in is there it is rendered and sent for signing)
//   fields   the fill-ins, until the first signature; complete, the document is sent for signing
//   sign     the listed signer signs with the platform's signature (the signing session), after the tick; the last
//            signature files the signed copy and sends it to each signer
type R<T = unknown> = ActionResult<T>;
const fail = (e: unknown): R<never> => ({ ok: false, code: 'refused', message: e instanceof DbError || e instanceof Error ? e.message.replace(/^.*?ERROR:\s*/, '') : String(e) });
const UUID = /^[0-9a-f-]{36}$/;
const LIST = '/admin/company-documents';
function done(id?: string) { revalidatePath(LIST); if (id) revalidatePath(`${LIST}/${id}`); }

type Saved = { document: string; version: number; version_id: string; new: boolean; file_kind: 'pdf' | 'signable'; status: string; missing: string[]; ready: boolean };

export async function companyDocumentSave(form: FormData): Promise<R<Saved & { sent: boolean }>> {
  try {
    const user = await assertAdmin();
    const aal = await sessionAal();
    const document = String(form.get('document') ?? '');
    const p: Record<string, unknown> = {};
    if (document) { if (!UUID.test(document)) return fail('Unknown document.'); p.document = document; }
    const title = String(form.get('title') ?? '').trim().slice(0, 120);
    const kind = String(form.get('kind') ?? '').trim();
    const notes = String(form.get('notes') ?? '').trim().slice(0, 2000);
    const note = String(form.get('note') ?? '').trim().slice(0, 500);
    if (title) p.title = title;
    if (!document) {
      if (title.length < 3) return fail('Give the document a title.');
      p.kind = kind;
      if (notes) p.notes = notes;
    }
    if (note) p.note = note;
    if (String(form.get('mode') ?? 'pdf') === 'text') {
      const body = String(form.get('body_md') ?? '');
      if (!body.trim()) return fail('Paste the text of the document.');
      let signers: unknown;
      try { signers = JSON.parse(String(form.get('signers') ?? '[]')); } catch { return fail('Choose who signs it.'); }
      if (!Array.isArray(signers) || !signers.length) return fail('Choose who signs it: at least one Admin.');
      const r = await door<Saved>(user.id, 'admin_do', 'company_document_save', { ...p, body_md: body, signers, fields: {} }, aal);
      let sent = false;
      if (r.ready) { await sendForSigning(user.id, aal, r.version_id); sent = true; }
      done(r.document);
      return { ok: true, data: { ...r, sent } };
    }
    const file = form.get('file');
    if (!(file instanceof Blob) || file.size === 0) return fail('Choose the PDF.');
    if (file.size > COMPANY_DOC_MAX_BYTES) return fail('The PDF must be under 20 MB.');
    const bytes = new Uint8Array(await file.arrayBuffer());
    if (!isPdf(bytes)) return fail('Upload a PDF.');
    const key = `company-documents/${document || crypto.randomUUID()}/${crypto.randomUUID()}.pdf`;
    const s = await storage();
    await s.put('documents', key, bytes, 'application/pdf');
    try {
      const r = await door<Saved>(user.id, 'admin_do', 'company_document_save', { ...p, path: key, size_bytes: bytes.length, sha256: await sha256Hex(bytes) }, aal);
      done(r.document);
      return { ok: true, data: { ...r, sent: false } };
    } catch (e) { await s.remove('documents', key).catch(() => undefined); throw e; }
  } catch (e) { return fail(e); }
}

export async function companyDocumentFields(documentId: string, versionId: string, fields: Record<string, string>): Promise<R<{ ready: boolean; missing: string[]; sent: boolean }>> {
  try {
    if (!UUID.test(versionId) || !UUID.test(documentId)) return fail('Unknown document.');
    const user = await assertAdmin();
    const aal = await sessionAal();
    const clean: Record<string, string> = {};
    for (const [k, v] of Object.entries(fields ?? {})) if (/^[A-Za-z0-9_]{1,60}$/.test(k)) clean[k] = String(v ?? '').slice(0, 2000);
    const r = await door<{ ready: boolean; missing: string[] }>(user.id, 'admin_do', 'company_document_fields', { version: versionId, fields: clean }, aal);
    let sent = false;
    if (r.ready) { await sendForSigning(user.id, aal, versionId); sent = true; }
    done(documentId);
    return { ok: true, data: { ready: r.ready, missing: r.missing, sent } };
  } catch (e) { return fail(e); }
}

/** Send again (a send that failed after the fill-ins were saved) or file the signed copy again (a copy that failed). */
export async function companyDocumentRetry(documentId: string, versionId: string, what: 'send' | 'signed_copy'): Promise<R<{ done: boolean }>> {
  try {
    if (!UUID.test(versionId) || !UUID.test(documentId)) return fail('Unknown document.');
    const user = await assertAdmin();
    const aal = await sessionAal();
    if (what === 'send') await sendForSigning(user.id, aal, versionId); else await fileSignedCopy(user.id, aal, versionId);
    done(documentId);
    return { ok: true, data: { done: true } };
  } catch (e) { return fail(e); }
}

export async function companyDocumentSign(spec: { document: string; version: string; request: string; sha: string; acknowledged: boolean }, input: PackageInput): Promise<PackageResult> {
  try {
    if (!UUID.test(spec.request) || !UUID.test(spec.version) || !UUID.test(spec.document)) return { ok: false, code: 'refused', message: 'Unknown document.' };
    if (!spec.acknowledged) return { ok: false, code: 'invalid', message: 'Check the highlighted part.', fieldErrors: { ack: 'Tick that you have read it and had the chance to get legal advice.' } };
    const user = await assertAdmin();
    const e = input.esign;
    const drawnPath = e?.session && e.method === 'drawn' && e.drawnPath ? e.drawnPath : undefined;
    const typedName = e?.session && e.method === 'typed' && e.typedName?.trim() ? e.typedName.trim() : undefined;
    if (!drawnPath && !typedName) return { ok: false, code: 'invalid', message: 'Check the highlighted part.', fieldErrors: { signature: 'Finish the signing steps: the reading, the consents and your signature.' } };
    await signDocument(user.id, { id: spec.request, sha: spec.sha, drawnPath, typedName, consent: COMPANY_SIGN_STATEMENT, extra: { company_ack: true } });
    // the last signature: the signed copy, filed and sent to each signer (a failure here leaves the button on the page)
    let filed = false;
    try { filed = await fileSignedCopy(user.id, await sessionAal(), spec.version); } catch (x) { console.error('company document signed copy', x); }
    done(spec.document);
    return { ok: true, data: { signed: 1, message: filed ? 'Signed. Everyone has signed: the signed copy is filed below and sent to each signer.' : 'Signed. Your signature is recorded with the date and time.' } };
  } catch (x) { return fail(x); }
}
