import { door, sessionAal } from '@/server/door';
import { storage, type Bucket } from '@/integrations/storage';
import { currentUser } from '@/server/portal/data';
import { downloadName } from '@/features/investor/library';

// One version of an investor library document, for Admins (r50, migration 4300): the history in Admin > Investors >
// Documents opens any earlier version through a 5-minute signed link. The database checks the Admin.
export const dynamic = 'force-dynamic';

export async function GET(req: Request, { params }: { params: Promise<{ version: string }> }) {
  const version = (await params).version;
  const user = await currentUser();
  if (!user) return Response.redirect(new URL(`/sign-in?next=${encodeURIComponent('/admin/investors/documents')}`, req.url), 302);
  if (!/^[0-9a-f-]{36}$/.test(version)) return new Response('Not found', { status: 404 });
  const f = await door<{ file_kind: string; bucket: string | null; path: string | null; link_url: string | null; title: string; version: number }>(user.id, 'admin_read', 'investor_library_file', { version }, await sessionAal()).catch(() => null);
  if (!f) return new Response('Not found', { status: 404 });
  const headers = { 'cache-control': 'no-store', 'referrer-policy': 'no-referrer' };
  if (f.file_kind === 'link' && f.link_url?.startsWith('https://')) return new Response(null, { status: 302, headers: { ...headers, location: f.link_url } });
  if (!f.bucket || !f.path) return new Response('Not found', { status: 404 });
  const url = await (await storage()).signedDownloadUrl(f.bucket as Bucket, f.path, 300, downloadName(f.title, f.version));
  return new Response(null, { status: 302, headers: { ...headers, location: new URL(url, req.url).toString() } });
}
