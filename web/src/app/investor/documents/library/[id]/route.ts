import { door } from '@/server/door';
import { storage, type Bucket } from '@/integrations/storage';
import { currentUser } from '@/server/portal/data';
import { downloadName } from '@/features/investor/library';

// A business document of the investor library (r50, migration 4300): the database checks the signed-in investor (or an
// Admin previewing) and hands back the latest version's place in the private documents bucket; the server makes a
// 5-minute signed link. A deck given as a link goes to that link. Nothing changes on GET.
export const dynamic = 'force-dynamic';

export async function GET(req: Request, { params }: { params: Promise<{ id: string }> }) {
  const id = (await params).id;
  const user = await currentUser();
  if (!user) return Response.redirect(new URL(`/sign-in?next=${encodeURIComponent('/investor/documents?tab=library')}`, req.url), 302);
  if (!/^[0-9a-f-]{36}$/.test(id)) return new Response('Not found', { status: 404 });
  const f = await door<{ file_kind: string; bucket: string | null; path: string | null; link_url: string | null; title: string; version: number }>(user.id, 'investor_read', 'library_file', { item: id }).catch(() => null);
  if (!f) return new Response('Not found', { status: 404 });
  const headers = { 'cache-control': 'no-store', 'referrer-policy': 'no-referrer' };
  if (f.file_kind === 'link' && f.link_url?.startsWith('https://')) return new Response(null, { status: 302, headers: { ...headers, location: f.link_url } });
  if (!f.bucket || !f.path) return new Response('Not found', { status: 404 });
  const url = await (await storage()).signedDownloadUrl(f.bucket as Bucket, f.path, 300, downloadName(f.title, f.version));
  return new Response(null, { status: 302, headers: { ...headers, location: new URL(url, req.url).toString() } });
}
