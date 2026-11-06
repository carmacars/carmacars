import { siteUrl } from '@/lib/site';
import { SCOPES } from '@/features/api-access/tools';

// OAuth protected resource metadata (RFC 9728) of the MCP connector (release 28, B3): served at
// /.well-known/oauth-protected-resource and /.well-known/oauth-protected-resource/api/mcp (next.config.ts rewrites).
export const dynamic = 'force-dynamic';
export function GET() {
  const site = siteUrl();
  return Response.json({ resource: `${site}/api/mcp`, authorization_servers: [site], scopes_supported: SCOPES, bearer_methods_supported: ['header'],
    resource_name: 'CarmaCars', resource_documentation: `${site}/admin/settings/api` }, { headers: { 'cache-control': 'public, max-age=3600', 'access-control-allow-origin': '*' } });
}
