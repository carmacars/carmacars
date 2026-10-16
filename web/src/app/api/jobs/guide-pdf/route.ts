import { NextResponse } from 'next/server';
import { rpc } from '@/lib/db/repo';
import { jobAuthorized } from '@/server/job-auth';
import { isGuidePortal } from '@/server/guides';
import { sha256Hex } from '@/server/links';

// A guide's PDF from the printer (web/scripts/guides-pdf.mjs): the committed PDF at deploy (stored once, only where
// none is stored), or one printed from the published guide. Stored privately; the portal then offers it with its date.
export const dynamic = 'force-dynamic';
const MAX = 20_000_000;

export async function POST(req: Request) {
  if (!(await jobAuthorized(req))) return new NextResponse('Forbidden', { status: 403 });
  const q = new URL(req.url).searchParams;
  const portal = q.get('portal') ?? '';
  const source = q.get('source') ?? 'generated';
  if (!isGuidePortal(portal) || !['committed', 'generated'].includes(source)) return new NextResponse('Unknown guide or source', { status: 400 });
  const bytes = new Uint8Array(await req.arrayBuffer());
  if (!bytes.byteLength || bytes.byteLength > MAX || !(bytes[0] === 0x25 && bytes[1] === 0x50 && bytes[2] === 0x44 && bytes[3] === 0x46)) {
    return new NextResponse('Not a PDF', { status: 400 });
  }
  const sha = await sha256Hex(bytes);
  const key = `guides/${portal}/${source}-${new Date().toISOString().slice(0, 10)}-${sha.slice(0, 12)}.pdf`;
  const record = { portal, bucket: 'documents', path: key, sha256: sha, bytes: bytes.byteLength, pages: Number(q.get('pages') ?? '') || null, source,
    guide_version: Number(q.get('version') ?? '') || null, generated_at: q.get('generated_at') || null };
  if (source === 'committed') {
    // stored only where the guide has no PDF yet: ask first, so nothing is written for nothing
    const dry = (await rpc('server_guide_pdf_record', { p: { ...record, path: `guides/${portal}/probe.pdf`, dry_run: true } }, { role: 'service_role' }).catch(() => null)) as { skipped?: boolean } | null;
    if (dry?.skipped) return NextResponse.json({ ok: true, skipped: true });
  }
  const { storage } = await import('@/integrations/storage');
  await (await storage()).put('documents', key, bytes, 'application/pdf');
  const r = await rpc('server_guide_pdf_record', { p: record }, { role: 'service_role' });
  return NextResponse.json({ ok: true, ...(r as unknown as Record<string, unknown>), path: key });
}
