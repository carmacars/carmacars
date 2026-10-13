import { assertAdmin } from '@/server/admin/data';
import { fileResponse, storedDocument } from '@/server/files';

// Any stored document for an Admin (a toll notice, a receipt, an agreement): /admin/documents/<id>.
export const dynamic = 'force-dynamic';

export async function GET(_req: Request, { params }: { params: Promise<{ id: string }> }) {
  const { id } = await params;
  if (!/^[0-9a-f-]{36}$/.test(id)) return new Response('Not found', { status: 404 });
  try { await assertAdmin(); } catch { return new Response('Not found', { status: 404 }); }
  const f = await storedDocument(id);
  return f ? fileResponse(f) : new Response('Not found', { status: 404 });
}
