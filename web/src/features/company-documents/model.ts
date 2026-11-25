// Admin > Company documents (r50, migration 5060): CarmaCars's own corporate documents, Admins only. A version is a PDF or
// a document to sign (a Markdown body with {{placeholders}}, its fill-ins and its signers). What the pages, the server
// actions, the connector and the unit tests share. Pure. The body is never in the repository: it is given at run time.
import { markdown, type Block, type SignatureRow } from '../agreement/model.ts';

export interface CompanyDocSigner { user_id: string; name: string; email?: string | null; role_label: string; request_id: string | null; signed: boolean | null; signed_at: string | null; method: string | null }
export interface CompanyDocVersion {
  id: string; version: number; file_kind: 'pdf' | 'signable'; status: 'filed' | 'draft' | 'to_sign' | 'signed'; has_file: boolean; size_bytes: number | null;
  note: string | null; created_at: string; sent_at: string | null; signed_at: string | null; uploaded_by: string | null;
  signers?: CompanyDocSigner[]; placeholders?: string[]; missing?: string[]; frozen?: boolean;
}
export interface CompanyDoc { id: string; title: string; kind: string; notes: string | null; archived: boolean; version: number; updated_at: string; updated_on: string; current: CompanyDocVersion; history: CompanyDocVersion[] }
export interface CompanyDocKind { key: string; label: string; documents: CompanyDoc[] }
export interface CompanyDocAdmin { id: string; name: string; email: string }
export interface CompanyDocs { kinds: CompanyDocKind[]; admins: CompanyDocAdmin[] }
export interface CompanyDocPage {
  id: string; title: string; kind: string; kind_label: string; notes: string | null; archived: boolean;
  current: CompanyDocVersion & { body_md: string | null; fields: Record<string, string> };
  history: CompanyDocVersion[];
  me: { role_label: string; request_id: string | null; status: string | null; sha256: string | null; signer_name: string | null; title: string | null; signed_at: string | null } | null;
}
export interface SignFacts {
  document_id: string; version_id: string; title: string; version: number; status: string; kind_label: string; body_md: string; fields: Record<string, string>;
  missing: string[]; to_sign_sha256: string | null; has_signed_copy: boolean;
  signers: Array<{ user_id: string; name: string; role_label: string; request_id: string | null; status: string | null; signed_at: string | null; method: string | null;
    typed_name: string | null; drawn_path: string | null; ip_address: string | null; user_agent: string | null; document_sha256: string | null }>;
}

/** The Admin page's upload limit (a PDF), and the connector's (base64 travels in the request). */
export const COMPANY_DOC_MAX_BYTES = 20 * 1024 * 1024;
export const COMPANY_DOC_CONNECTOR_MAX_BYTES = 15 * 1024 * 1024;

/** The {{placeholders}} of a body, in order of first use: the pattern markdown() substitutes (and the database's). */
export function placeholders(body: string): string[] {
  const out: string[] = [];
  for (const m of body.matchAll(/\{\{([A-Za-z0-9_]+)\}\}/g)) if (!out.includes(m[1]!)) out.push(m[1]!);
  return out;
}

/** The placeholders still without a value. */
export const missingFields = (body: string, fields: Record<string, string>) => placeholders(body).filter((k) => !(fields[k] ?? '').trim());

/** A placeholder as a label: holdco_a_name becomes "Holdco a name". */
export const fieldLabel = (k: string) => { const s = k.replace(/_/g, ' ').trim(); return s.charAt(0).toUpperCase() + s.slice(1); };

/** The body as the agreement renderer's blocks (web/src/features/agreement/model.ts, as the person and owner agreements):
 *  "#" and "##" headings read as section headings; a fill-in still empty shows as a blank line to fill. */
export function bodyBlocks(body: string, fields: Record<string, string>): Block[] {
  const md = body.replace(/\r\n?/g, '\n').replace(/^#{1,2} /gm, '### ');
  const values: Record<string, string> = {};
  for (const k of placeholders(md)) values[k] = (fields[k] ?? '').trim() || '________';
  return markdown(md, values);
}

/** The whole document: its title and version, the body, and the fill-ins it was signed with (a table). */
export function documentBlocks(f: { title: string; version: number; body_md: string; fields: Record<string, string> }, signatures?: SignatureRow[]): Block[] {
  const keys = placeholders(f.body_md);
  const blocks: Block[] = [{ t: 'title', text: f.title }, { t: 'p', text: `Version ${f.version}` }, ...bodyBlocks(f.body_md, f.fields)];
  if (keys.length) blocks.push({ t: 'h2', text: 'Fill-ins' }, { t: 'table', head: ['Item', 'Value'], rows: keys.map((k) => [fieldLabel(k), (f.fields[k] ?? '').trim()]), kv: true });
  if (signatures?.length) blocks.push({ t: 'h2', text: 'Signatures' }, { t: 'signatures', rows: signatures });
  return blocks;
}

/** Where the files go: the PDF to sign and the signed copy, in the agreements bucket (as every signed agreement). */
export const toSignPath = (documentId: string, file: string) => `company-documents/${documentId}/${file}.pdf`;
export const signedCopyPath = (documentId: string, versionId: string) => `company-documents/${documentId}/${versionId}-signed.pdf`;

/** "Draft", "Waiting for signatures", "Signed", "Filed" */
export const statusLabel = (s: CompanyDocVersion['status']) => ({ filed: 'Filed', draft: 'Draft', to_sign: 'Waiting for signatures', signed: 'Signed' })[s] ?? s;

/** The words the signer agrees to, recorded with the signature. */
export const COMPANY_SIGN_STATEMENT = 'I have read this document to the end and had the chance to get legal advice, and I sign it electronically, with the same effect as signing on paper.';
