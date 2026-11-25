import { NextResponse } from 'next/server';
import { siteUrl } from '@/lib/site';
import { readFileLink } from '@/server/connector-files';

// r50 (3870): a file a connector read gave (a call recording, ID images, a signed agreement, a photo). The link is signed with
// LINK_SIGNING_KEY for ten minutes and names the exact file (src/server/connector-files.ts); the database decided who may have
// it (an Admin's key, admin:read) and logged the access. Answered with a one-minute storage link, never cached.
export const dynamic = 'force-dynamic';
const H = { 'cache-control': 'no-store', 'referrer-policy': 'no-referrer' };

export async function GET(req: Request) {
  const f = await readFileLink(new URL(req.url).searchParams.get('t'));
  if (!f) return NextResponse.json({ error: 'This link is not valid or has expired: ask the connector again' }, { status: 403, headers: H });
  const { storage } = await import('@/integrations/storage');
  const url = await (await storage()).signedDownloadUrl(f.bucket, f.key, 60, f.name);
  return NextResponse.redirect(url.startsWith('/') ? siteUrl() + url : url, { status: 302, headers: H });
}
