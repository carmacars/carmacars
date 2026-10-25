import { rpc } from '@/lib/db/repo';
import { storage } from '@/integrations/storage';

// A version of the rental agreement waiting for a signature (migration 0143): its two PDFs, for the signer holding the
// link (an unguessable token, valid while the version waits). Private, never cached.
export const dynamic = 'force-dynamic';

export async function GET(_req: Request, { params }: { params: Promise<{ token: string; which: string }> }) {
  const { token, which } = await params;
  if (!/^[0-9a-f-]{36}$/.test(token) || !['carmacars', 'blindspot'].includes(which)) return new Response('Not found', { status: 404 });
  const link = (await rpc('server_agreement_version_link', { p_token: token }, { role: 'service_role' }).catch(() => null)) as unknown as
    { status: string; documents: Record<string, { bucket: string; path: string; title: string } | null> } | null;
  const d = link?.documents?.[which];
  if (!link || !d) return new Response('Not found', { status: 404 });
  const bytes = await (await storage()).get(d.bucket as 'agreements', d.path);
  if (!bytes) return new Response('Not found', { status: 404 });
  return new Response(bytes as unknown as BodyInit, { headers: { 'content-type': 'application/pdf', 'content-disposition': `inline; filename="${d.title.replace(/[^\w ,.()-]/g, '')}.pdf"`, 'cache-control': 'private, no-store', 'x-robots-tag': 'noindex' } });
}
