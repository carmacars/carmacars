import { env } from '@/lib/env';
import { appleAppSiteAssociation } from '@/lib/native/shell';

// /.well-known/apple-app-site-association (next.config.ts rewrites it here; migration 0390): the universal links of the
// iPhone app, so a link to carmacars.ca in an email or text opens the app when it is installed, and passwords saved for
// the site fill in the app. Needs the Apple Developer Team ID (APP_APPLE_TEAM_ID); until then, 404.
export const dynamic = 'force-dynamic';

export function GET() {
  const body = appleAppSiteAssociation(env().APP_APPLE_TEAM_ID);
  if (!body) return new Response('Not found', { status: 404 });
  return new Response(JSON.stringify(body), { headers: { 'content-type': 'application/json', 'cache-control': 'public, max-age=3600' } });
}
