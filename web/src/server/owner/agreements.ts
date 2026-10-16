import 'server-only';
import { companySignature } from '@/server/signature-lines';
import { rpc } from '@/lib/db/repo';
import { storage } from '@/integrations/storage';
import { agreementPdf } from '@/features/agreement/pdf';
import { when, type Block, type SignatureRow } from '@/features/agreement/model';
import { documentBlocks, OWNER_TEMPLATE_VERSION, packetKeys, TITLES, type OwnerAgreementFacts, type PacketKey } from '@/features/owner-agreement/model';
import { sha256Hex } from '@/server/links';

// Built-in signing of the owner agreements, the same way as the rental agreement (0019, 0028): the
// server renders each document from the owner's records, stores the PDF in the private agreements
// bucket and opens it with its SHA-256 (public.owner_open_agreements); the owner signs every open
// document at once (public.owner_sign_agreements); then the signed copies, with the signature images
// and the signature record, are rendered and attached.
const SR = { role: 'service_role' as const };
const UNSIGNED_DATE = new Date('2026-01-01T00:00:00Z'); // fixed, so the same document gives the same bytes

export async function ownerAgreementFacts(ownerId: string, by: string): Promise<OwnerAgreementFacts> {
  return (await rpc('server_owner_agreement_facts', { p_owner: ownerId, p_by: by }, SR)) as unknown as OwnerAgreementFacts;
}

const footer = (f: OwnerAgreementFacts, key: PacketKey) =>
  `CarmaCars ${TITLES[key]} ${f.agreements.find((a) => a.kind === key)?.agreement_number ?? ''} for ${f.owner.legal_name}. ${OWNER_TEMPLATE_VERSION}`;

export interface PacketDoc { key: PacketKey; title: string; sha: string; blocks: Block[] }

/** Renders, stores and opens every document the owner still has to sign. The same documents return the requests already open. */
export async function openOwnerPacket(ownerId: string, by: string): Promise<{ facts: OwnerAgreementFacts; docs: PacketDoc[] }> {
  const facts = await ownerAgreementFacts(ownerId, by);
  const keys = packetKeys(facts);
  // signed by the owner, waiting for the other Owners of the Title Schedule (0053): nothing is opened again
  if (!keys.length || facts.waiting_for_owners) return { facts, docs: [] };
  const s = await storage();
  const docs: PacketDoc[] = [];
  const open: Array<{ key: PacketKey; template_version: string; sha256: string; storage_path: string }> = [];
  for (const key of keys) {
    const blocks = documentBlocks(facts, key);
    const pdf = await agreementPdf(blocks, { title: `${TITLES[key]}, ${facts.owner.legal_name}`, createdAt: UNSIGNED_DATE, footer: footer(facts, key) });
    const sha = await sha256Hex(pdf);
    const path = `owners/${ownerId}/agreements/${key}-${sha.slice(0, 16)}.pdf`;
    await s.put('agreements', path, pdf, 'application/pdf');
    open.push({ key, template_version: OWNER_TEMPLATE_VERSION, sha256: sha, storage_path: path });
    docs.push({ key, title: TITLES[key], sha, blocks });
  }
  await rpc('owner_open_agreements', { p_owner: ownerId, p_by: by, p_docs: open }, SR);
  return { facts, docs };
}

interface SignedResult {
  signed: Array<{ key: PacketKey; agreement_number: string | null; signature_request_id: string;
    records: Array<{ signer_role: string; signer_name: string; signer_title: string | null; method: string; signed_at: string; ip_address: string | null; user_agent: string | null; provider_signature: string | null; typed_name: string | null; initials: Record<string, string> | null }> }>;
  vehicles_signed: number; signer_name: string;
  /** false while another Owner of the Title Schedule has not signed (0053): nothing is countersigned yet. */
  complete?: boolean; waiting_for?: string[];
}

/** After signing: each signed copy with the signatures and the signature record, attached once. */
export async function attachOwnerSignedCopies(ownerId: string, by: string, result: SignedResult): Promise<void> {
  const facts = await ownerAgreementFacts(ownerId, by);
  const s = await storage();
  for (const doc of result.signed) {
    const owner = doc.records.find((r) => r.signer_role !== 'carmacars' && r.signer_name === facts.owner.signer_name) ?? doc.records.find((r) => r.signer_role !== 'carmacars');
    const cc = doc.records.find((r) => r.signer_role === 'carmacars');
    const otherRecords = doc.records.filter((r) => r.signer_role !== 'carmacars' && r !== owner);
    const images = new Map<number, Uint8Array>();
    if (owner?.method === 'drawn' && owner.provider_signature) {
      const png = await s.get('agreements', owner.provider_signature).catch(() => null);
      if (png) images.set(0, png);
    }
    const row = (party: string, r: typeof owner): SignatureRow => ({ party, name: r?.signer_name ?? '', signature: r ? (r.method === 'typed' ? `Typed: ${r.typed_name ?? r.signer_name}` : r.method === 'automatic' ? 'Signed electronically for CarmaCars' : 'Drawn signature') : '', when: r ? when(r.signed_at) : '' });
    const initials = owner?.initials ? Object.values(owner.initials)[0] : undefined;
    // the facts after signing carry the agreement date; the schedules shown are the ones this document covered
    const blocks = documentBlocks(doc.key === 'additional' ? { ...facts, schedules: facts.schedules.map((x) => (x.signature_request_id === doc.signature_request_id ? { ...x, signed_at: null } : x)) } : facts,
      doc.key, { owner: row(facts.owner.owner_type === 'corporation' ? 'Owner (corporation)' : 'Owner (individual)', owner), carmacars: row('CarmaCars', cc), initials,
        others: otherRecords.map((r) => row('Owner', r)) });
    const company = await companySignature(doc.signature_request_id);
    const lines: string[][] = [
      ['Document', `${TITLES[doc.key]} ${doc.agreement_number ?? ''}, text version ${OWNER_TEMPLATE_VERSION}`],
      ...doc.records.map((r) => [`${r.signer_role.replace(/_/g, ' ')}: ${r.signer_name}`, `${r.signed_at ? when(r.signed_at) : 'signed on paper'}; method ${r.method}${r.ip_address ? `; IP address ${r.ip_address}` : ''}${r.user_agent ? `; device ${r.user_agent}` : ''}${r.initials ? `; initials ${Object.values(r.initials).join(', ')}` : ''}`]),
      ...company.lines
    ];
    const pdf = await agreementPdf(blocks, { title: `${TITLES[doc.key]}, signed`, createdAt: new Date(cc?.signed_at ?? Date.now()), images, record: { heading: 'Signature record', lines }, footer: footer(facts, doc.key) });
    const sha = await sha256Hex(pdf);
    const path = `owners/${ownerId}/agreements/${doc.key}-${doc.signature_request_id.slice(0, 8)}-signed.pdf`;
    await s.put('agreements', path, pdf, 'application/pdf');
    await rpc('server_attach_owner_signed_copy', { p_request: doc.signature_request_id, p_path: path, p_sha256: sha }, SR);
  }
}
export type { SignedResult };
