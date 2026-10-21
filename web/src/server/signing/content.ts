import type { Block } from '@/features/agreement/model';

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
