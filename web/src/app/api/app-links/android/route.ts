import { env } from '@/lib/env';
import { androidAssetLinks } from '@/lib/native/shell';

// /.well-known/assetlinks.json (next.config.ts rewrites it here; migration 0390): the Android app's verified app links
// and shared sign-in. Needs the SHA-256 fingerprints of the app's signing keys (APP_ANDROID_CERT_SHA256); until then, 404.
export const dynamic = 'force-dynamic';

export function GET() {
  const body = androidAssetLinks(env().APP_ANDROID_CERT_SHA256);
  if (!body) return new Response('Not found', { status: 404 });
  return new Response(JSON.stringify(body), { headers: { 'content-type': 'application/json', 'cache-control': 'public, max-age=3600' } });
}
