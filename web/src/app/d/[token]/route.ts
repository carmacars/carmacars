import { readToken } from '@/server/links';
import { fileResponse, generatedFile, isDocKind, storedDocument, validKey } from '@/server/files';

// The signed file links in emails (7 days; signed by the send-outbox Edge Function with LINK_SIGNING_KEY,
// purpose "doc"): /d/<token>. A link opens exactly the record it was made for; an expired or altered link
// says so and points to the portal, where the same document is behind sign-in.
export const dynamic = 'force-dynamic';

function expired(): Response {
  const html = `<!doctype html><html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><meta name="robots" content="noindex"><title>Link expired | CarmaCars</title>
<style>body{font-family:system-ui,sans-serif;max-width:32rem;margin:4rem auto;padding:0 1rem;line-height:1.5;color:#111}a{color:#111}</style></head>
<body><h1>This link has expired</h1><p>Links in our emails work for 7 days. Sign in to find the same document in your account.</p><p><a href="/sign-in">Sign in</a></p></body></html>`;
  return new Response(html, { status: 410, headers: { 'content-type': 'text/html; charset=utf-8', 'cache-control': 'no-store', 'x-robots-tag': 'noindex, nofollow' } });
}

export async function GET(_req: Request, { params }: { params: Promise<{ token: string }> }) {
  const { token } = await params;
  const t = await readToken<{ k: string; key: string }>('doc', token);
  if (!t || typeof t.k !== 'string' || typeof t.key !== 'string' || !validKey(t.key)) return expired();
  const f = t.k === 'document' ? await storedDocument(t.key) : isDocKind(t.k) ? await generatedFile(t.k, t.key) : null;
  if (!f) return new Response('Not found', { status: 404, headers: { 'x-robots-tag': 'noindex' } });
  return fileResponse(f);
}
