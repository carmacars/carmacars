import { rpc } from '@/lib/db/repo';

// The files search engines ask for at the site's root (0061), rewritten here by next.config.ts: /<IndexNow key>.txt
// and the Google Search Console verification file. Each answers only for the value in Admin > Settings > Site.
export const revalidate = 300;
export async function GET(_req: Request, { params }: { params: Promise<{ name: string }> }) {
  const { name } = await params;
  const body = /^[a-z0-9]{6,60}\.(txt|html)$/i.test(name) ? ((await rpc('site_file', { p_name: name })) as unknown as string | null) : null;
  if (!body) return new Response('Not found', { status: 404, headers: { 'content-type': 'text/plain; charset=utf-8' } });
  return new Response(body, { headers: { 'content-type': `${name.endsWith('.html') ? 'text/html' : 'text/plain'}; charset=utf-8`, 'cache-control': 'public, max-age=300' } });
}
