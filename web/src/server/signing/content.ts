import type { Block } from '@/features/agreement/model';
import type { PacketKey } from '@/features/owner-agreement/model';

// The content key of an unsigned document (migration 0075): the SHA-256 of everything its PDF is made from. The PDF
// renderer is deterministic (the same blocks, title, footer and date give the same bytes), so documents with the same
// content key have the same PDF and the same SHA-256. RENDERER changes whenever src/features/agreement/pdf.ts would
// make different bytes, so a new renderer never reuses an older file.
export const RENDERER = 'agreement-pdf-1';
export interface PdfInput { title: string; createdAt: Date; footer: string }

export function contentText(blocks: Block[], x: PdfInput): string {
  return JSON.stringify({ r: RENDERER, title: x.title, footer: x.footer, at: x.createdAt.toISOString(), blocks });
}

export async function contentKey(blocks: Block[], x: PdfInput): Promise<string> {
  const h = new Uint8Array(await crypto.subtle.digest('SHA-256', new TextEncoder().encode(contentText(blocks, x))));
  return Array.from(h, (b) => b.toString(16).padStart(2, '0')).join('');
}

/** A document to prepare, as the browser names it (the server builds it from the person's own records). */
export type PrepTarget = { t: 'packet'; key: PacketKey } | { t: 'form'; code: 'A' | 'B' } | { t: 'partner' } | { t: 'form_c'; vehicle: string };
export const targetId = (t: PrepTarget) => (t.t === 'packet' ? `packet-${t.key}` : t.t === 'form' ? `form-${t.code}` : t.t === 'form_c' ? `form_c-${t.vehicle}` : 'partner');

export function parseTarget(x: unknown): PrepTarget | null {
  const o = (x ?? {}) as Record<string, unknown>;
  if (o.t === 'packet' && (o.key === 'enrollment' || o.key === 'title_holding' || o.key === 'additional')) return { t: 'packet', key: o.key };
  if (o.t === 'form' && (o.code === 'A' || o.code === 'B')) return { t: 'form', code: o.code };
  if (o.t === 'partner') return { t: 'partner' };
  if (o.t === 'form_c' && typeof o.vehicle === 'string' && /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/.test(o.vehicle)) return { t: 'form_c', vehicle: o.vehicle };
  return null;
}
