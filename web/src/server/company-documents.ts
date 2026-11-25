import 'server-only';
import { door } from '@/server/door';
import { storage } from '@/integrations/storage';
import { agreementPdf } from '@/features/agreement/pdf';
import { when, type SignatureRow } from '@/features/agreement/model';
import { sha256Hex } from '@/server/links';
import { documentBlocks, signedCopyPath, toSignPath, type SignFacts } from '@/features/company-documents/model';

// Admin > Company documents (r50, migration 5060): the two files a document to sign gets, rendered here with the agreement
// renderer every signed agreement uses (features/agreement/pdf.ts) and stored in the agreements bucket:
//   the PDF to sign    when every fill-in is there: the body with its fill-ins; its SHA-256 is what each signer signs
//                      (app.company_document_send opens one sign request per signer and tells each one)
//   the signed copy    when everyone signed: the same document, then each signature block (the drawn image or the typed
//                      name, the role, the date) and the record (time, method, IP address, device, the document's
//                      SHA-256); app.company_document_attach_signed files it as the version's PDF and sends it to each signer
// Both run as the Admin who acted (the page) or whose key it is (the connector); the database checks the Admin again.
type Aal = 'aal1' | 'aal2' | null;

/** Render the version and open it for signatures. Returns the database's answer (status to_sign, the signers told). */
export async function sendForSigning(userId: string, aal: Aal, versionId: string): Promise<{ document: string; version: number; status: string; signers: number }> {
  const f = await door<SignFacts>(userId, 'admin_read', 'company_document_sign_facts', { version: versionId }, aal);
  if (f.missing.length) throw new Error(`Fill in first: ${f.missing.join(', ')}.`);
  const pdf = await agreementPdf(documentBlocks(f), { title: `${f.title}, version ${f.version}`, createdAt: new Date(), footer: `CarmaCars ${f.title}, version ${f.version}. To sign.` });
  const sha = await sha256Hex(pdf);
  const path = toSignPath(f.document_id, crypto.randomUUID());
  const s = await storage();
  await s.put('agreements', path, pdf, 'application/pdf');
  try {
    return await door(userId, 'admin_do', 'company_document_send', { version: versionId, path, sha256: sha }, aal);
  } catch (e) { await s.remove('agreements', path).catch(() => undefined); throw e; }
}

/** When everyone signed and no signed copy is filed yet: render it, store it and file it (each signer gets it). */
export async function fileSignedCopy(userId: string, aal: Aal, versionId: string): Promise<boolean> {
  const f = await door<SignFacts>(userId, 'admin_read', 'company_document_sign_facts', { version: versionId }, aal);
  if (f.status !== 'signed' || f.has_signed_copy) return false;
  const s = await storage();
  const images = new Map<number, Uint8Array>();
  const rows: SignatureRow[] = [];
  for (const [i, x] of f.signers.entries()) {
    if (x.method === 'drawn' && x.drawn_path) { const png = await s.get('agreements', x.drawn_path).catch(() => null); if (png) images.set(i, png); }
    rows.push({ party: x.role_label, name: x.name, signature: x.method === 'drawn' ? 'Drawn signature' : `Typed: ${x.typed_name ?? x.name}`, when: x.signed_at ? when(x.signed_at) : '' });
  }
  const lines: string[][] = [['Document', `${f.title}, version ${f.version}`], ['Document SHA-256', f.to_sign_sha256 ?? '']];
  for (const x of f.signers) {
    lines.push([`${x.role_label}: ${x.name}`, `${x.signed_at ? when(x.signed_at) : ''}; method ${x.method ?? ''}${x.ip_address ? `; IP address ${x.ip_address}` : ''}${x.user_agent ? `; device ${x.user_agent}` : ''}${x.document_sha256 ? `; SHA-256 ${x.document_sha256}` : ''}`]);
  }
  const last = f.signers.map((x) => x.signed_at ?? '').sort().pop();
  const pdf = await agreementPdf(documentBlocks(f, rows), { title: `${f.title}, version ${f.version}, signed`, createdAt: last ? new Date(last) : new Date(), images,
    record: { heading: 'Signature record', lines }, footer: `CarmaCars ${f.title}, version ${f.version}, signed.` });
  const path = signedCopyPath(f.document_id, f.version_id);
  await s.put('agreements', path, pdf, 'application/pdf');
  await door(userId, 'admin_do', 'company_document_attach_signed', { version: versionId, path, sha256: await sha256Hex(pdf), size_bytes: pdf.length }, aal);
  return true;
}
