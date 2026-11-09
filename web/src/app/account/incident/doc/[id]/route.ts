import { rpc } from '@/lib/db/repo';
import { storage, type Bucket } from '@/integrations/storage';
import { currentUser } from '@/server/portal/data';

// A document of the digital incident card (1150): the rental agreement or the coverage proof of a booking in progress, for
// its renter or a driver named on it (public.server_incident_document checks the person and the document). A short-lived
// signed link (5 minutes), as /account/documents. Nothing changes on GET.
export const dynamic = 'force-dynamic';

export async function GET(req: Request, { params }: { params: Promise<{ id: string }> }) {
  const id = (await params).id;
  const user = await currentUser();
  if (!user) return Response.redirect(new URL(`/sign-in?next=${encodeURIComponent('/account/incident')}`, req.url), 302);
  if (!/^[0-9a-f-]{36}$/.test(id)) return new Response('Not found', { status: 404 });
  const d = (await rpc('server_incident_document', { p_by: user.id, p_document: id }, { role: 'service_role' })) as unknown as { bucket: string; path: string; kind: string; title: string } | null;
  if (!d || !d.path) return new Response('Not found', { status: 404 });
  const ext = d.path.split('.').pop() ?? 'pdf';
  const url = await (await storage()).signedDownloadUrl(d.bucket as Bucket, d.path, 300, `${(d.title ?? d.kind ?? 'document').replace(/[^\w.-]+/g, '-')}.${ext}`);
  return new Response(null, { status: 302, headers: { location: new URL(url, req.url).toString(), 'cache-control': 'no-store', 'referrer-policy': 'no-referrer' } });
}
