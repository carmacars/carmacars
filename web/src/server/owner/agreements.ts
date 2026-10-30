import 'server-only';
import { companySignature } from '@/server/signature-lines';
import { rpc } from '@/lib/db/repo';
import { storage } from '@/integrations/storage';
import { agreementPdf } from '@/features/agreement/pdf';
import { when, type Block, type SignatureRow } from '@/features/agreement/model';
import { documentBlocks, OWNER_TEMPLATE_VERSION, TITLES, type OwnerAgreementFacts, type PacketKey } from '@/features/owner-agreement/model';
import { sha256Hex } from '@/server/links';
import { ownerAgreementFacts, packetFooter, packetSpecs, prepareSpec } from '@/server/signing/prepare';
import { enqueuePdfJobs } from '@/server/pdf-jobs';
import { withRequestCertificate } from '@/server/signing/certified';

// Built-in signing of the owner agreements, the same way as the rental agreement (0019, 0028): each document is
// rendered from the owner's records, stored in the private agreements bucket and opened with its SHA-256
// (public.owner_open_agreements; since 0077 one document per request, never on the sign page itself); the owner
// signs every open document at once (public.owner_sign_agreements); then the signed copies, with the signature
// images and the signature record, are rendered and attached by background jobs (pdf_jobs, 0077).
const SR = { role: 'service_role' as const };
export { ownerAgreementFacts } from '@/server/signing/prepare';

export interface PacketDoc { key: PacketKey; title: string; sha: string; blocks: Block[] }

/** Opens every document the owner still has to sign, rendering only those not open yet (one after another). For an
 *  action or a script; the sign page itself never renders (src/server/signing/prepare.ts, migration 0077). */
export async function openOwnerPacket(ownerId: string, by: string): Promise<{ facts: OwnerAgreementFacts; docs: PacketDoc[] }> {
  const facts = await ownerAgreementFacts(ownerId, by);
  const specs = await packetSpecs(facts, ownerId, by);
  const docs: PacketDoc[] = [];
  for (const s of specs) {
    const o = await prepareSpec(by, s);
    if (s.target.t === 'packet') docs.push({ key: s.target.key, title: s.title, sha: o.sha, blocks: s.blocks });
  }
  return { facts, docs };
}

interface SignedResult {
  signed: Array<{ key: PacketKey; agreement_number: string | null; signature_request_id: string;
    records: Array<{ signer_role: string; signer_name: string; signer_title: string | null; method: string; signed_at: string; ip_address: string | null; user_agent: string | null; provider_signature: string | null; typed_name: string | null; initials: Record<string, string> | null }> }>;
  vehicles_signed: number; signer_name: string;
  /** false while another Owner of the Title Schedule has not signed (0053): nothing is countersigned yet. */
  complete?: boolean; waiting_for?: string[];
}

/** After signing: one job per signed copy (migration 0077), made in its own request; the signature is already recorded. */
export async function queueOwnerSignedCopies(ownerId: string, by: string, result: SignedResult): Promise<void> {
  await enqueuePdfJobs(result.signed.map((doc) => ({ kind: 'owner_signed_copy' as const, ref: doc.signature_request_id, owner_id: ownerId, user_id: by, payload: { doc } })));
}

/** One signed copy with the signatures and the signature record, attached once (a pdf_jobs job). */
export async function attachOwnerSignedCopy(ownerId: string, by: string, doc: SignedResult['signed'][number]): Promise<void> {
  const facts = await ownerAgreementFacts(ownerId, by);
  const s = await storage();
  {
    const owner = doc.records.find((r) => r.signer_role !== 'carmacars' && r.signer_name === facts.owner.signer_name) ?? doc.records.find((r) => r.signer_role !== 'carmacars');
    const cc = doc.records.find((r) => r.signer_role === 'carmacars');
    const otherRecords = doc.records.filter((r) => r.signer_role !== 'carmacars' && r !== owner);
    const images = new Map<number, Uint8Array>();
    if (owner?.method === 'drawn' && owner.provider_signature) {
      const png = await s.get('agreements', owner.provider_signature).catch(() => null);
      if (png) images.set(0, png);
    }
    const company = await companySignature(doc.signature_request_id);
    const row = (party: string, r: typeof owner): SignatureRow => ({ party, name: r?.signer_name ?? '', signature: r ? (r.method === 'typed' ? `Typed: ${r.typed_name ?? r.signer_name}` : r.method === 'automatic' ? (company.text ?? 'Signed electronically for CarmaCars') : 'Drawn signature') : '', when: r ? when(r.signed_at) : '' });
    const initials = owner?.initials ? Object.values(owner.initials)[0] : undefined;
    // the facts after signing carry the agreement date; the schedules shown are the ones this document covered
    const blocks = documentBlocks(doc.key === 'additional' ? { ...facts, schedules: facts.schedules.map((x) => (x.signature_request_id === doc.signature_request_id ? { ...x, signed_at: null } : x)) } : facts,
      doc.key, { owner: row(facts.owner.owner_type === 'corporation' ? 'Owner (corporation)' : 'Owner (individual)', owner), carmacars: row('CarmaCars', cc), initials,
        others: otherRecords.map((r) => row('Owner', r)) });
    const lines: string[][] = [
      ['Document', `${TITLES[doc.key]} ${doc.agreement_number ?? ''}, text version ${OWNER_TEMPLATE_VERSION}`],
      ...doc.records.map((r) => [`${r.signer_role.replace(/_/g, ' ')}: ${r.signer_name}`, `${r.signed_at ? when(r.signed_at) : 'signed on paper'}; method ${r.method}${r.ip_address ? `; IP address ${r.ip_address}` : ''}${r.user_agent ? `; device ${r.user_agent}` : ''}${r.initials ? `; initials ${Object.values(r.initials).join(', ')}` : ''}`]),
      ...company.lines
    ];
    const signedPdf = await agreementPdf(blocks, { title: `${TITLES[doc.key]}, signed`, createdAt: new Date(cc?.signed_at ?? Date.now()), images, record: { heading: 'Signature record', lines }, footer: packetFooter(facts, doc.key) });
    // the certificate of completion (0193): each Owner's signing session and the SHA-256 of the document signed
    const pdf = await withRequestCertificate(signedPdf, doc.signature_request_id, `${TITLES[doc.key]}${doc.agreement_number ? ` ${doc.agreement_number}` : ''}`,
      cc ? { name: cc.signer_name, at: cc.signed_at, text: company.text ?? 'Countersigned automatically when the Owners signed.' } : null);
    const sha = await sha256Hex(pdf);
    const path = `owners/${ownerId}/agreements/${doc.key}-${doc.signature_request_id.slice(0, 8)}-signed.pdf`;
    await s.put('agreements', path, pdf, 'application/pdf');
    await rpc('server_attach_owner_signed_copy', { p_request: doc.signature_request_id, p_path: path, p_sha256: sha }, SR);
  }
}
export type { SignedResult };
