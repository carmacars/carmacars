import { currentUser } from '@/server/portal/data';
import { door, sessionAal } from '@/server/door';
import { storage } from '@/integrations/storage';
import { fileResponse } from '@/server/files';

// The notice behind a read, for the review screen (Finance and Admins; the database checks).
export const dynamic = 'force-dynamic';
export async function GET(_req: Request, { params }: { params: Promise<{ id: string }> }) {
  const { id } = await params;
  if (!/^[0-9a-f-]{36}$/.test(id)) return new Response('Not found', { status: 404 });
  const user = await currentUser();
  if (!user) return new Response('Not found', { status: 404 });
  const f = await door<{ bucket: string; path: string; mime_type: string | null } | null>(user.id, 'ops_read', 'toll_read_file', { id }, await sessionAal()).catch(() => null);
  if (!f?.path) return new Response('Not found', { status: 404 });
  const bytes = await (await storage()).get(f.bucket as 'documents', f.path);
  return bytes ? fileResponse({ bytes, fileName: f.path.split('/').pop() ?? 'notice', contentType: f.mime_type ?? 'application/octet-stream' }) : new Response('Not found', { status: 404 });
}
