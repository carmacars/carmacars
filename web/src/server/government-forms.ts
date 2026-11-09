import 'server-only';
import { notFound } from 'next/navigation';
import { agreementPdf } from '@/features/agreement/pdf';
import type { Block } from '@/features/agreement/model';
import type { Spec } from '@/features/official-forms/fill';
import { currentUser } from '@/server/portal/data';
import { door, rolesOf, sessionAal } from '@/server/door';
import { storage } from '@/integrations/storage';
import { fileResponse } from '@/server/files';

// One government form for an Admin, customer service or fleet (r34, 0822): the data sheet as a PDF, the blank official
// PDF the browser fills, and the page that fills it. The database decides who may read it (app.government_form_fill_read).
export interface StaffFill { id: string; form_code: string; title: string | null; vehicle_id: string; vehicle_name: string; owner_id: string; owner_name: string; status: string; mode: string;
  missing: string[]; data_sheet: Array<{ label: string; value: string | null }>; generated_at: string; current: boolean; official: boolean; file_key: string | null;
  field_values: Record<string, string | null>; field_map: Record<string, Spec | string>; signed_document_id: string | null;
  /** r35 (0870): this version's number, every version, the boxes that may be changed and the changes made by hand */
  version?: number; can_edit?: boolean; versions?: GovVersion[]; fields?: GovField[]; edits?: GovEdit[];
  /** r35 (1000): the owner's on-screen signature, kept beside the form (never on it) */
  sign_state?: 'unsigned' | 'signed' | 'changed' | 'ink'; values_sha?: string; signature?: GovSignature | null; signatures?: GovSignatureRow[] }
export interface GovSignature { id: string; signer_name: string; method: 'drawn' | 'typed'; typed_name: string | null; signature_path: string | null; signed_at: string; ip: string | null; user_agent: string | null;
  form_version: number | null; current_version: number; session: string | null; same_values: boolean; changed: string[] }
export interface GovSignatureRow { id: string; signer_name: string; method: 'drawn' | 'typed'; signed_at: string; form_version: number | null; ip: string | null }
export interface GovVersion { id: string; version: number; generated_at: string; status: string; current: boolean; edits: number; official: boolean; by: string }
export interface GovField { target: 'pdf' | 'sheet'; name: string; label: string; page?: number | null; max_length?: number | null; value: string | null; records?: string | null; edited: boolean }
export interface GovEdit { id: string; target: 'pdf' | 'sheet'; field: string; label: string; value: string | null; reason: string; at: string; by: string | null; ended_at: string | null; end_reason: string | null }

export async function staffFill(id: string): Promise<StaffFill | null> {
  if (!/^[0-9a-f-]{36}$/.test(id)) return null;
  const user = await currentUser();
  if (!user) return null;
  const roles = await rolesOf(user.id);
  if (!roles.admin && !roles.va) return null;
  return door<StaffFill | null>(user.id, roles.admin ? 'ops_read' : 'va_read', 'government_form_fill', { fill: id }, await sessionAal()).catch(() => null);
}

export async function staffFillOr404(id: string): Promise<StaffFill> {
  const f = await staffFill(id);
  if (!f) notFound();
  return f;
}

const nf = () => new Response('Not found', { status: 404, headers: { 'x-robots-tag': 'noindex' } });

export async function sheetGET(_req: Request, { params }: { params: Promise<{ id: string }> }): Promise<Response> {
  const f = await staffFill((await params).id);
  if (!f) return nf();
  const blocks: Block[] = [
    { t: 'title', text: `${f.form_code}${f.title ? `: ${f.title}` : ''}` },
    { t: 'p', text: `Data sheet for ${f.vehicle_name} (${f.owner_name}). Copy each value onto the official form, in this order.` },
    ...(f.missing.length ? [{ t: 'p', text: `**Still missing:** ${f.missing.join(', ')}.` } as Block] : []),
    { t: 'table', head: ['Field', 'Value'], rows: f.data_sheet.map((r) => [r.label, r.value ?? 'To fill in']), kv: true }
  ];
  const pdf = await agreementPdf(blocks, { title: `${f.form_code} data sheet`, createdAt: new Date(f.generated_at), footer: `CarmaCars data sheet ${f.form_code} for ${f.vehicle_name}` });
  return new Response(pdf as unknown as BodyInit, { headers: { 'content-type': 'application/pdf', 'content-disposition': `inline; filename="${f.form_code}-data-sheet.pdf"`, 'cache-control': 'no-store' } });
}

export async function templateGET(_req: Request, { params }: { params: Promise<{ id: string }> }): Promise<Response> {
  const f = await staffFill((await params).id);
  if (!f?.file_key) return nf();
  const bytes = await (await storage()).get('documents', f.file_key);
  return bytes ? fileResponse({ bytes, fileName: `${f.form_code}.pdf`, contentType: 'application/pdf' }) : nf();
}

/** The owner's drawn signature of this form, for staff, to show beside the form (r35, 1000). It is never on the official PDF
 *  or in the print-ready form: only this image route and the page read it. */
export async function signatureGET(_req: Request, { params }: { params: Promise<{ id: string }> }): Promise<Response> {
  const f = await staffFill((await params).id);
  const path = f?.signature?.method === 'drawn' ? f.signature.signature_path : null;
  if (!path || !/^(esign|signatures)\/[\w./-]+\.png$/.test(path) || path.includes('..')) return nf();
  const bytes = await (await storage()).get('agreements', path).catch(() => null);
  return bytes ? new Response(bytes as unknown as BodyInit, { headers: { 'content-type': 'image/png', 'cache-control': 'private, no-store', 'x-robots-tag': 'noindex' } }) : nf();
}
