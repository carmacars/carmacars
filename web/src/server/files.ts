import 'server-only';
import { rpc } from '@/lib/db/repo';
import { storage } from '@/integrations/storage';
import { renderDocument, DOC_KINDS, type DocKind } from '@/features/documents/pdf';
import { sha256Hex } from '@/server/links';

// Generated documents (migration 0032): a final record is rendered once, stored in the private documents
// bucket and linked to its record (app.file_record); anything still changing is rendered on each request
// and not stored. Access is decided by the caller: app.file_access for a signed-in person, the signed
// 7-day link for an email.
const SR = { role: 'service_role' as const };
export interface FileOut { bytes: Uint8Array; fileName: string; contentType: string }

export const isDocKind = (k: string): k is DocKind => (DOC_KINDS as readonly string[]).includes(k);
export const validKey = (k: string) => /^[0-9a-f-]{36}(:[0-9]{4})?$/.test(k);

export async function mayDownload(userId: string, kind: DocKind, key: string): Promise<boolean> {
  return (await rpc('server_file_access', { p_user: userId, p_kind: kind, p_key: key }, SR)) === true;
}

export async function generatedFile(kind: DocKind, key: string, userId: string | null = null): Promise<FileOut | null> {
  const s = await storage();
  const stored = (await rpc('server_file_stored', { p_kind: kind, p_key: key }, SR)) as unknown as { bucket: string; path: string; title: string | null } | null;
  if (stored?.path) {
    const bytes = await s.get(stored.bucket as 'documents', stored.path);
    if (bytes) return { bytes, fileName: stored.path.split('/').pop() ?? `${kind}.pdf`, contentType: 'application/pdf' };
  }
  const facts = (await rpc('server_pdf_facts', { p_kind: kind, p_key: key, p_user: userId ?? undefined }, SR)) as unknown as (Record<string, unknown> & { final: boolean; title: string; file_name: string }) | null;
  if (!facts) return null;
  // the logo from Admin > Settings > Site, when one is uploaded (PNG or JPEG; otherwise the wordmark)
  const logoKey = (facts as { company?: { logo_key?: string | null } }).company?.logo_key ?? null;
  const logo = logoKey && /\.(png|jpe?g)$/i.test(logoKey) ? await s.get('vehicle-public', logoKey).catch(() => null) : null;
  const bytes = await renderDocument(kind, facts, logo);
  // a final record is stored once; a company statement is stored under its version (the key) even as a draft, and
  // its current version (the key without one) is rendered each time and not stored
  if ((facts as { store?: boolean }).store ?? facts.final) {
    const sha = await sha256Hex(bytes);
    const path = `generated/${kind}/${key.replace(':', '-')}/${facts.file_name}`;
    await s.put('documents', path, bytes, 'application/pdf');
    await rpc('server_file_record', { p_kind: kind, p_key: key, p_bucket: 'documents', p_path: path, p_sha256: sha, p_title: facts.title }, SR);
  }
  return { bytes, fileName: facts.file_name, contentType: 'application/pdf' };
}

/** A stored file by its documents row (the email links to a signed agreement or a notice). */
export async function storedDocument(documentId: string): Promise<FileOut | null> {
  return (await findStoredDocument(documentId))?.file ?? null;
}

/** The documents row and its file: null when there is no such row, file null when the row's file is not in storage. */
export async function findStoredDocument(documentId: string): Promise<{ file: FileOut | null; title: string | null } | null> {
  const d = (await rpc('server_document_file', { p_document: documentId }, SR)) as unknown as { bucket: string; path: string; mime_type: string | null; title: string | null } | null;
  if (!d) return null;
  const bytes = d.path ? await (await storage()).get(d.bucket as 'documents', d.path).catch(() => null) : null;
  return { title: d.title, file: bytes ? { bytes, fileName: d.path.split('/').pop() ?? 'document', contentType: d.mime_type ?? 'application/octet-stream' } : null };
}

const esc = (s: string) => s.replace(/[&<>"']/g, (c) => `&#${c.charCodeAt(0)};`);
/** A documents row whose file is not in storage: a plain "File missing" page (still a 404, so checks and monitors see it)
 *  rather than a bare "Not found" that reads as a wrong link. */
export function fileMissingResponse(title: string | null): Response {
  const name = title ? esc(title) : 'This document';
  return new Response(`<!doctype html><html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1"><meta name="robots" content="noindex, nofollow"><title>File missing</title>`
    + `<style>body{font:16px/1.5 system-ui,sans-serif;margin:0;padding:48px 16px;background:#fff;color:#1a1a1a}main{max-width:36rem;margin:0 auto}@media (prefers-color-scheme:dark){body{background:#141414;color:#eee}}</style></head>`
    + `<body><main><h1>File missing</h1><p>${name} is on record, but its file is not in storage. Ask for it to be uploaded again.</p></main></body></html>`,
  { status: 404, headers: { 'content-type': 'text/html; charset=utf-8', 'cache-control': 'private, no-store', 'x-robots-tag': 'noindex, nofollow', 'x-content-type-options': 'nosniff' } });
}

export function fileResponse(f: FileOut, download = false): Response {
  const name = f.fileName.replace(/[^\w.-]+/g, '-');
  return new Response(f.bytes as unknown as BodyInit, { headers: {
    'content-type': f.contentType, 'content-disposition': `${download ? 'attachment' : 'inline'}; filename="${name}"`,
    'cache-control': 'private, no-store', 'x-robots-tag': 'noindex, nofollow', 'x-content-type-options': 'nosniff' } });
}
