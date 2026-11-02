import { rpc } from '@/lib/db/repo';
import { storage, type Bucket } from '@/integrations/storage';
import { currentUser } from '@/server/portal/data';

// An investor's file (r27 portals, Documents > Your files): the documents row must pass row-level security for the
// signed-in investor (public.my_document runs as them; documents investor_read), then a 5-minute signed link. Nothing
// changes on GET.
export const dynamic = 'force-dynamic';

export async function GET(req: Request, { params }: { params: Promise<{ id: string }> }) {
  const id = (await params).id;
  const user = await currentUser();
  if (!user) return Response.redirect(new URL(`/sign-in?next=${encodeURIComponent('/investor/documents?tab=files')}`, req.url), 302);
  if (!/^[0-9a-f-]{36}$/.test(id)) return new Response('Not found', { status: 404 });
  const d = (await rpc('my_document', { p_document: id }, { role: 'authenticated', userId: user.id })) as unknown as { bucket: string; path: string | null; kind: string; title: string; purged: boolean } | null;
  if (!d || !d.path || d.purged) return new Response('Not found', { status: 404 });
  const ext = d.path.split('.').pop() ?? 'pdf';
  const url = await (await storage()).signedDownloadUrl(d.bucket as Bucket, d.path, 300, `${(d.title ?? d.kind ?? 'document').replace(/[^\w.-]+/g, '-')}.${ext}`);
  return new Response(null, { status: 302, headers: { location: new URL(url, req.url).toString(), 'cache-control': 'no-store', 'referrer-policy': 'no-referrer' } });
}
