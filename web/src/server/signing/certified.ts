import 'server-only';
import { rpc } from '@/lib/db/repo';
import { env } from '@/lib/env';
import { storage } from '@/integrations/storage';
import { agreementPdf } from '@/features/agreement/pdf';
import { when, type Block, type SignatureRow } from '@/features/agreement/model';
import { appendCertificate, type CertSigner } from '@/features/signing/certificate';
import { sha256Hex } from '@/server/links';

// The certificate of completion on every signed document (migration 0193), as on the rental agreements (0154): the
// signers with their signing sessions (the code and where it went, the documents read, each initial and consent, the
// place, IP address and device, the audit trail) and the SHA-256 of the document signed. The signed file's own SHA-256 is
// recorded when it is filed, so /verify finds it.
const SR = { role: 'service_role' as const };
export const verifyUrl = () => `${env().NEXT_PUBLIC_APP_URL.replace(/\/$/, '')}/verify`;

/** The signed copy of a signature request (an owner agreement or schedule, a form, a partner, investment or staff
 *  agreement) with the certificate's pages added at the end. Without a signing session (signed on paper, or before
 *  0193) the copy is returned as it is. */
export async function withRequestCertificate(pdf: Uint8Array, signatureRequestId: string, title: string,
  countersign?: { name: string; at: string | null; text: string } | null): Promise<Uint8Array> {
  const c = (await rpc('server_esign_certificate_for_request', { p_request: signatureRequestId }, SR).catch(() => null)) as unknown as { sha256: string | null; signers: CertSigner[] } | null;
  if (!c?.signers?.length) return pdf;
  const last = c.signers.map((s) => s.signed_at).filter(Boolean).sort().pop() ?? new Date().toISOString();
  return appendCertificate(pdf, { document: title, hashes: c.sha256 ? [{ label: title, sha256: c.sha256 }] : [], signers: c.signers, countersign: countersign ?? null,
    verifyUrl: verifyUrl(), at: countersign?.at ?? last });
}

interface ChangeFacts {
  change_id: string; vehicle_name: string; owner_name: string; text: string; sha256: string; owner_id: string; schedule_number: string | null; document_id: string | null;
  signed_at: string | null; signed_name: string | null; countersignature: string | null; esign_session_id: string | null; signature_path: string | null; signature_method: string | null;
}

/** The signed copy of an updated Vehicle Schedule (0193; before, the signature was kept without a PDF): the text signed,
 *  the owner's signature and CarmaCars' countersignature, then the certificate of completion. Filed once. */
export async function fileScheduleChangeCopy(changeId: string): Promise<string | null> {
  const f = (await rpc('server_schedule_change_signed_facts', { p_change: changeId }, SR)) as unknown as ChangeFacts | null;
  if (!f || f.document_id) return f?.document_id ?? null;
  const s = await storage();
  const images = new Map<number, Uint8Array>();
  if (f.signature_method === 'drawn' && f.signature_path) { const png = await s.get('agreements', f.signature_path).catch(() => null); if (png) images.set(0, png); }
  const title = `Updated Vehicle Schedule${f.schedule_number ? ` ${f.schedule_number}` : ''}`;
  const rows: SignatureRow[] = [
    { party: 'Owner', name: f.signed_name ?? f.owner_name, signature: f.signature_method === 'typed' ? `Typed: ${f.signed_name ?? f.owner_name}` : 'Drawn signature', when: when(f.signed_at) },
    { party: 'CarmaCars', name: 'CarmaCars', signature: f.countersignature ?? 'Signed electronically for CarmaCars.', when: when(f.signed_at) }
  ];
  const blocks: Block[] = [{ t: 'title', text: title }, { t: 'p', text: f.vehicle_name }, ...f.text.split('\n').filter(Boolean).map((t) => ({ t: 'p' as const, text: t })),
    { t: 'signatures', rows }];
  const base = await agreementPdf(blocks, { title: `${title}, signed`, createdAt: new Date(f.signed_at ?? Date.now()), images,
    record: { heading: 'Signature record', lines: [['Document', title], ['SHA-256 of the text signed', f.sha256], ['Owner', `${f.signed_name ?? f.owner_name}; ${when(f.signed_at)}`]] },
    footer: `CarmaCars ${title}, signed.` });
  const certs = f.esign_session_id ? ((await rpc('server_esign_certificate_sessions', { p_sessions: [f.esign_session_id] }, SR)) as unknown as CertSigner[]) : [];
  const pdf = certs.length ? await appendCertificate(base, { document: `${title}, ${f.vehicle_name}`, hashes: [{ label: `${title} (the text)`, sha256: f.sha256 }], signers: certs,
    countersign: f.countersignature ? { name: 'CarmaCars', at: f.signed_at, text: f.countersignature } : null, verifyUrl: verifyUrl(), at: f.signed_at ?? new Date().toISOString() }) : base;
  const sha = await sha256Hex(pdf);
  const path = `owners/${f.owner_id}/schedules/schedule-change-${changeId.slice(0, 8)}-signed.pdf`;
  await s.put('agreements', path, pdf, 'application/pdf');
  return (await rpc('server_schedule_change_attach', { p_change: changeId, p_path: path, p_sha256: sha }, SR)) as unknown as string;
}
