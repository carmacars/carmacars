import { rpc } from '@/lib/db/repo';
import { storage, type Bucket } from '@/integrations/storage';
import { currentUser } from '@/server/portal/data';

// A document from a person's signing page (migration 0044): one sent to them to sign, its signed copy, or their own
// agreement. public.my_sign_document returns the storage key only for those; then a 5-minute signed link.
export const dynamic = 'force-dynamic';

export async function GET(req: Request, { params }: { params: Promise<{ id: string }> }) {
  const id = (await params).id;
  const user = await currentUser();
  if (!user) return Response.redirect(new URL('/sign-in', req.url), 302);
  if (!/^[0-9a-f-]{36}$/.test(id)) return new Response('Not found', { status: 404 });
  const d = (await rpc('my_sign_document', { p_by: user.id, p_document: id }, { role: 'service_role' }).catch(() => null)) as unknown as { bucket: string; path: string; title: string | null } | null;
  if (!d) return new Response('Not found', { status: 404 });
  const ext = d.path.split('.').pop() ?? 'pdf';
  const url = await (await storage()).signedDownloadUrl(d.bucket as Bucket, d.path, 300, `${(d.title ?? 'document').replace(/[^\w.-]+/g, '-')}.${ext}`);
  return new Response(null, { status: 302, headers: { location: new URL(url, req.url).toString(), 'cache-control': 'no-store', 'referrer-policy': 'no-referrer' } });
}
