import 'server-only';
import { rpc } from '@/lib/db/repo';
import { storage } from '@/integrations/storage';
import { agreementPdf } from '@/features/agreement/pdf';
import { when, type Block, type SignatureRow } from '@/features/agreement/model';
import { screenFormBlocks, SCREEN_FORMS_VERSION, SCREEN_FORM_TITLE, type ScreenFormFacts } from '@/features/owner-agreement/screen-forms';
import { requestMeta } from '@/server/request';
import { sha256Hex } from '@/server/links';
import { SIGN_STATEMENT } from '@/features/manual/constants';

// Documents one person signs in their portal (migration 0044): Forms A and B (rendered here from the owner's records),
// investment agreements and staff agreements (a PDF an Admin sent). The person signs by typing their name or drawing;
// the database records the signature and its effects; the signed record (a page with the signature and its details) is
// rendered and filed with the document.
const SR = { role: 'service_role' as const };
const FIXED = new Date('2026-01-01T00:00:00Z'); // the unsigned form's date, so the same facts give the same bytes


export async function formABFacts(userId: string, code: 'A' | 'B'): Promise<ScreenFormFacts> {
  return (await rpc('server_owner_form_ab_facts', { p_by: userId, p_code: code }, SR)) as unknown as ScreenFormFacts;
}

export async function openFormAB(userId: string, code: 'A' | 'B'): Promise<{ id: string; sha: string }> {
  const facts = await formABFacts(userId, code);
  const pdf = await agreementPdf(screenFormBlocks(facts), { title: `${SCREEN_FORM_TITLE[code]}, ${facts.owner.legal_name}`, createdAt: FIXED, footer: `CarmaCars ${SCREEN_FORM_TITLE[code]} for ${facts.owner.legal_name}. ${SCREEN_FORMS_VERSION}` });
  const sha = await sha256Hex(pdf);
  const path = `owners/${facts.owner_id}/forms/form-${code.toLowerCase()}-${sha.slice(0, 16)}.pdf`;
  await (await storage()).put('agreements', path, pdf, 'application/pdf');
  const r = (await rpc('owner_form_ab_open', { p_by: userId, p_code: code, p_sha256: sha, p_path: path, p_template_version: SCREEN_FORMS_VERSION }, SR)) as unknown as { id: string };
  return { id: r.id, sha };
}

function pngBytes(dataUrl: string): Uint8Array | null {
  const m = /^data:image\/png;base64,([A-Za-z0-9+/=]+)$/.exec(dataUrl ?? '');
  if (!m) return null;
  const bin = Uint8Array.from(atob(m[1]!), (c) => c.charCodeAt(0));
  const sig = [0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a];
  return bin.length > 200 && bin.length < 400_000 && sig.every((v, i) => bin[i] === v) ? bin : null;
}

interface SignedRequest {
  id: string; doc_type: 'form_a' | 'form_b' | 'investment_agreement' | 'staff_agreement'; title: string; owner_id: string | null; investor_id: string | null; staff_user_id: string | null;
  signer_name: string; signer_role: string; signed_at: string; method: string; document_sha256: string;
  record: { signer_role: string; signer_name: string; method: string; signed_at: string; ip_address: string | null; user_agent: string | null; provider_signature: string | null; typed_name: string | null; initials: Record<string, string> | null };
}

export async function signDocument(userId: string, input: { id: string; sha: string; typedName?: string; drawn?: string; legalAdvice?: string; adviser?: string; initials?: string; consent: string }): Promise<{ status: string }> {
  const s = await storage();
  let drawnPath: string | null = null;
  if (input.drawn) {
    const png = pngBytes(input.drawn);
    if (!png) throw new Error('Please sign your name in the box.');
    drawnPath = `signatures/${userId}/${crypto.randomUUID()}.png`;
    await s.put('agreements', drawnPath, png, 'image/png');
  } else if (!(input.typedName ?? '').trim()) throw new Error('Sign by drawing or by typing your full legal name.');
  const meta = await requestMeta();
  const r = (await rpc('sign_request_sign', { p_by: userId, p_id: input.id, p: {
    typed_name: input.typedName?.trim() || null, drawn_signature: drawnPath, ip: meta.ip, user_agent: meta.userAgent, consent_text: input.consent || SIGN_STATEMENT,
    document_sha256: input.sha, legal_advice_choice: input.legalAdvice || null, legal_adviser: input.adviser?.trim() || null, initials: input.initials?.trim() || null } }, SR)) as unknown as SignedRequest;
  // the signed record, filed with the document
  try { await attachSignedRecord(userId, r, drawnPath); } catch (e) { console.error('signed record', e); }
  return { status: 'signed' };
}

async function attachSignedRecord(userId: string, r: SignedRequest, drawnPath: string | null) {
  const s = await storage();
  const images = new Map<number, Uint8Array>();
  if (drawnPath) { const png = await s.get('agreements', drawnPath).catch(() => null); if (png) images.set(0, png); }
  const rec = r.record;
  const row: SignatureRow = { party: rec.signer_role === 'investor' ? 'Investor' : rec.signer_role === 'staff' ? 'Staff member' : 'Owner', name: rec.signer_name,
    signature: rec.method === 'typed' ? `Typed: ${rec.typed_name ?? rec.signer_name}` : 'Drawn signature', when: when(rec.signed_at) };
  let blocks: Block[];
  if (r.doc_type === 'form_a' || r.doc_type === 'form_b') {
    const code = r.doc_type === 'form_a' ? 'A' : 'B';
    const facts = await formABFacts(userId, code);
    blocks = screenFormBlocks(facts, { owner: row, carmacars: { party: code === 'B' ? 'Lessee (CarmaCars)' : 'CarmaCars', name: facts.company.legal_name || facts.company.brand, signature: 'Signed electronically for CarmaCars', when: when(rec.signed_at) } });
  } else {
    blocks = [{ t: 'title', text: `${r.title}: signature` }, { t: 'p', text: 'This page records the signature of the document named below. The document itself is filed beside it, unchanged.' },
      { t: 'table', head: ['Document', 'SHA-256 of the document signed'], rows: [[r.title, r.document_sha256]] }, { t: 'signatures', rows: [row] }];
  }
  const lines: string[][] = [
    ['Document', `${r.title}`],
    ['Document SHA-256', r.document_sha256],
    [`${rec.signer_role.replace(/_/g, ' ')}: ${rec.signer_name}`, `${when(rec.signed_at)}; method ${rec.method}${rec.ip_address ? `; IP address ${rec.ip_address}` : ''}${rec.user_agent ? `; device ${rec.user_agent}` : ''}${rec.initials ? `; initials ${Object.values(rec.initials).join(', ')}` : ''}`]
  ];
  const pdf = await agreementPdf(blocks, { title: `${r.title}, signed`, createdAt: new Date(rec.signed_at), images, record: { heading: 'Signature record', lines }, footer: `CarmaCars ${r.title}, signed.` });
  const sha = await sha256Hex(pdf);
  const base = r.owner_id ? `owners/${r.owner_id}/forms` : r.investor_id ? `investors/${r.investor_id}/signed` : `staff/${r.staff_user_id}/signed`;
  const path = `${base}/${r.doc_type}-${r.id.slice(0, 8)}-signed.pdf`;
  await s.put('agreements', path, pdf, 'application/pdf');
  await rpc('server_sign_request_attach', { p_id: r.id, p_path: path, p_sha256: sha }, SR);
}
