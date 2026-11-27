import { rpc } from '@/lib/db/repo';
import { storage, type Bucket } from '@/integrations/storage';
import { currentUser } from '@/server/portal/data';
import { isGuidePortal } from '@/server/guides';
import { fileLocation, localRedirect } from '@/lib/http/local-redirect';

// The stored PDF of a guide (migration 0044), for the people of that portal and the Admins: the database says
// whether this person may have it and where it is, then a 5-minute signed link. Nothing is rendered here.
export const dynamic = 'force-dynamic';

export async function GET(req: Request, { params }: { params: Promise<{ portal: string }> }) {
  const { portal } = await params;
  if (!isGuidePortal(portal)) return new Response('Not found', { status: 404 });
  const user = await currentUser();
  if (!user) return localRedirect(`/sign-in?next=${encodeURIComponent(`/guide-pdf/${portal}`)}`, 302);
  const f = (await rpc('guide_pdf_file', { p_by: user.id, p_portal: portal }, { role: 'service_role' }).catch(() => null)) as unknown as { bucket: string; path: string; title: string; generated_at: string } | null;
  if (!f) return new Response('Not found', { status: 404 });
  const name = `CarmaCars ${f.title} ${f.generated_at.slice(0, 10)}.pdf`.replace(/[^\w.-]+/g, '-');
  const url = await (await storage()).signedDownloadUrl(f.bucket as Bucket, f.path, 300, name);
  return new Response(null, { status: 302, headers: { location: fileLocation(url), 'cache-control': 'no-store', 'referrer-policy': 'no-referrer' } });
}
