import 'server-only';
import { rpc } from '@/lib/db/repo';
import { storage } from '@/integrations/storage';
import { agreementPdf } from '@/features/agreement/pdf';
import type { Block } from '@/features/agreement/model';
import { documentBlocks, OWNER_TEMPLATE_VERSION, packetKeys, TITLES, type OwnerAgreementFacts, type PacketKey } from '@/features/owner-agreement/model';
import { screenFormBlocks, SCREEN_FORMS_VERSION, SCREEN_FORM_TITLE, type ScreenFormFacts } from '@/features/owner-agreement/screen-forms';
import { FORM_C_SCREEN_VERSION, FORM_TITLE, screenFormCBlocks, type WitnessedFacts } from '@/features/owner-agreement/witnessed';
import { partnerAgreementBlocks, PARTNER_AGREEMENT_TITLE, PARTNER_AGREEMENT_VERSION, type PartnerFacts } from '@/features/partner/agreement';
import { sha256Hex } from '@/server/links';
import { contentKey, type PdfInput, type PrepTarget } from './content';

// Opening a document for signature without rendering it on the page (migration 0077). A sign page builds each
// document's text blocks (cheap) and its content key, and asks the database for the open request with that key. Only
// when there is none does the browser ask for the document to be prepared, one request per document (POST
// /api/sign/prepare): that request renders the PDF exactly as before (the same bytes, so the same SHA-256), stores it
// and opens it with the same database function, then records the content key on the document. So the page never
// renders a PDF, opening is idempotent, and one PDF at most is rendered per Worker request.
const SR = { role: 'service_role' as const };
export const UNSIGNED_DATE = new Date('2026-01-01T00:00:00Z'); // fixed, so the same document gives the same bytes

export type { PrepTarget } from './content';

export interface DocSpec {
  target: PrepTarget;
  title: string;
  blocks: Block[];
  pdf: PdfInput;
  key: string;                // content key
  path: (sha: string) => string;
  open: (sha: string, path: string) => Promise<{ id: string }>;
}
export interface OpenDoc { sha: string; id: string }

export { parseTarget, targetId } from './content';

// ---------------------------------------------------------------- the documents, from the records
export async function ownerAgreementFacts(ownerId: string, by: string): Promise<OwnerAgreementFacts> {
  return (await rpc('server_owner_agreement_facts', { p_owner: ownerId, p_by: by }, SR)) as unknown as OwnerAgreementFacts;
}
/** The agreements before approval (0181): the same facts with each car still in intake, its terms pending. Read only:
 *  never prepared or opened for signature (app.owner_open_agreements still needs the agreements an Admin's terms make). */
export async function ownerAgreementPreviewFacts(ownerId: string, by: string): Promise<OwnerAgreementFacts> {
  return (await rpc('server_owner_agreement_preview_facts', { p_owner: ownerId, p_by: by }, SR)) as unknown as OwnerAgreementFacts;
}
export const packetFooter = (f: OwnerAgreementFacts, key: PacketKey) =>
  `CarmaCars ${TITLES[key]} ${f.agreements.find((a) => a.kind === key)?.agreement_number ?? ''} for ${f.owner.legal_name}. ${OWNER_TEMPLATE_VERSION}`;

/** Every document of the owner's packet still to sign (none while the other Owners of the Title Schedule sign). */
export async function packetSpecs(facts: OwnerAgreementFacts, ownerId: string, by: string): Promise<DocSpec[]> {
  const keys = packetKeys(facts);
  if (!keys.length || facts.waiting_for_owners) return [];
  return Promise.all(keys.map(async (key) => {
    const blocks = documentBlocks(facts, key);
    const pdf: PdfInput = { title: `${TITLES[key]}, ${facts.owner.legal_name}`, createdAt: UNSIGNED_DATE, footer: packetFooter(facts, key) };
    return {
      target: { t: 'packet', key } as PrepTarget, title: TITLES[key], blocks, pdf, key: await contentKey(blocks, pdf),
      path: (sha: string) => `owners/${ownerId}/agreements/${key}-${sha.slice(0, 16)}.pdf`,
      open: async (sha: string, path: string) => {
        const r = (await rpc('owner_open_agreements', { p_owner: ownerId, p_by: by, p_docs: [{ key, template_version: OWNER_TEMPLATE_VERSION, sha256: sha, storage_path: path }] }, SR)) as unknown as { requests?: Array<{ key: string; signature_request_id: string }> };
        return { id: r.requests?.find((x) => x.key === key)?.signature_request_id ?? '' };
      }
    };
  }));
}

export async function formABFacts(userId: string, code: 'A' | 'B'): Promise<ScreenFormFacts> {
  return (await rpc('server_owner_form_ab_facts', { p_by: userId, p_code: code }, SR)) as unknown as ScreenFormFacts;
}
export async function formSpec(userId: string, code: 'A' | 'B', facts: ScreenFormFacts): Promise<DocSpec> {
  const blocks = screenFormBlocks(facts);
  const pdf: PdfInput = { title: `${SCREEN_FORM_TITLE[code]}, ${facts.owner.legal_name}`, createdAt: UNSIGNED_DATE, footer: `CarmaCars ${SCREEN_FORM_TITLE[code]} for ${facts.owner.legal_name}. ${SCREEN_FORMS_VERSION}` };
  return {
    target: { t: 'form', code }, title: SCREEN_FORM_TITLE[code], blocks, pdf, key: await contentKey(blocks, pdf),
    path: (sha) => `owners/${facts.owner_id}/forms/form-${code.toLowerCase()}-${sha.slice(0, 16)}.pdf`,
    open: async (sha, path) => ({ id: ((await rpc('owner_form_ab_open', { p_by: userId, p_code: code, p_sha256: sha, p_path: path, p_template_version: SCREEN_FORMS_VERSION }, SR)) as unknown as { id: string }).id })
  };
}

export async function partnerFacts(userId: string): Promise<PartnerFacts | null> {
  return (await rpc('partner_agreement_facts', { p_by: userId }, SR)) as unknown as PartnerFacts | null;
}
export async function partnerSpec(userId: string, facts: PartnerFacts): Promise<DocSpec> {
  const name = facts.partner.legal_name || facts.partner.business_name;
  const blocks = partnerAgreementBlocks(facts);
  const pdf: PdfInput = { title: `${PARTNER_AGREEMENT_TITLE}, ${name}`, createdAt: UNSIGNED_DATE, footer: `CarmaCars ${PARTNER_AGREEMENT_TITLE} for ${name}. ${PARTNER_AGREEMENT_VERSION}` };
  return {
    target: { t: 'partner' }, title: PARTNER_AGREEMENT_TITLE, blocks, pdf, key: await contentKey(blocks, pdf),
    path: (sha) => `owners/${facts.owner_id}/partner/partner-agreement-${sha.slice(0, 16)}.pdf`,
    open: async (sha, path) => ({ id: ((await rpc('partner_agreement_open', { p_by: userId, p_sha256: sha, p_path: path, p_template_version: PARTNER_AGREEMENT_VERSION }, SR)) as unknown as { id: string }).id })
  };
}

export async function formCFacts(userId: string, vehicleId: string): Promise<WitnessedFacts | null> {
  return (await rpc('server_witnessed_form_facts', { p_by: userId, p_code: 'C', p_vehicle: vehicleId }, SR).catch(() => null)) as unknown as WitnessedFacts | null;
}
export async function formCSpec(userId: string, ownerId: string, vehicleId: string, facts: WitnessedFacts): Promise<DocSpec> {
  const blocks = screenFormCBlocks(facts);
  const pdf: PdfInput = { title: `${FORM_TITLE.C}, ${facts.owner.legal_name}`, createdAt: UNSIGNED_DATE, footer: `CarmaCars ${FORM_TITLE.C} for ${facts.owner.legal_name}. ${FORM_C_SCREEN_VERSION}` };
  return {
    target: { t: 'form_c', vehicle: vehicleId }, title: FORM_TITLE.C, blocks, pdf, key: await contentKey(blocks, pdf),
    path: (sha) => `owners/${ownerId}/forms/form-c-${vehicleId.slice(0, 8)}-${sha.slice(0, 16)}.pdf`,
    open: async (sha, path) => ({ id: ((await rpc('owner_form_c_open', { p_by: userId, p_vehicle: vehicleId, p_sha256: sha, p_path: path, p_template_version: FORM_C_SCREEN_VERSION }, SR)) as unknown as { id: string }).id })
  };
}

// ---------------------------------------------------------------- open requests, without rendering
interface Found { content_key: string; sha256: string; signature_request_id: string; sign_request_id: string | null }

/** The open request of each document whose content is the same (by content key); a document not found is not open yet. */
export async function findOpen(userId: string, specs: DocSpec[]): Promise<Map<string, OpenDoc>> {
  const out = new Map<string, OpenDoc>();
  if (!specs.length) return out;
  const rows = (await rpc('server_open_by_content', { p_by: userId, p_keys: specs.map((s) => s.key) }, SR)) as unknown as Found[];
  for (const s of specs) {
    const r = rows.find((x) => x.content_key === s.key);
    if (r) out.set(s.key, { sha: r.sha256, id: s.target.t === 'packet' ? r.signature_request_id : (r.sign_request_id ?? '') });
  }
  return out;
}

/** Renders, stores and opens one document (one PDF in this request), unless it is open already. */
export async function prepareSpec(userId: string, spec: DocSpec): Promise<OpenDoc> {
  const found = (await findOpen(userId, [spec])).get(spec.key);
  if (found) return found;
  const bytes = await agreementPdf(spec.blocks, spec.pdf);
  const sha = await sha256Hex(bytes);
  const path = spec.path(sha);
  await (await storage()).put('agreements', path, bytes, 'application/pdf');
  const { id } = await spec.open(sha, path);
  await rpc('server_document_content_key', { p_by: userId, p_path: path, p_key: spec.key }, SR);
  return { sha, id };
}

/** The document a target names, built from the signed-in person's own records (never from what the browser sent). */
export async function specFor(userId: string, ownerId: string, t: PrepTarget): Promise<DocSpec | null> {
  if (t.t === 'packet') {
    const specs = await packetSpecs(await ownerAgreementFacts(ownerId, userId), ownerId, userId);
    return specs.find((s) => s.target.t === 'packet' && s.target.key === t.key) ?? null;
  }
  if (t.t === 'form') return formSpec(userId, t.code, await formABFacts(userId, t.code));
  if (t.t === 'partner') { const f = await partnerFacts(userId); return f ? partnerSpec(userId, f) : null; }
  const f = await formCFacts(userId, t.vehicle);
  return f ? formCSpec(userId, ownerId, t.vehicle, f) : null;
}

/** For callers that need the document open now (an Admin's action, a page that is not the sign page). */
export async function openNow(userId: string, spec: DocSpec): Promise<OpenDoc> {
  return prepareSpec(userId, spec);
}
