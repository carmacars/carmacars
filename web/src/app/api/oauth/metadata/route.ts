import { siteUrl } from '@/lib/site';
import { SCOPES } from '@/features/api-access/tools';

// OAuth authorization server metadata (RFC 8414) for the MCP connector (release 28, B3): served at
// /.well-known/oauth-authorization-server (next.config.ts rewrites). Public clients with PKCE S256 only; Claude
// registers itself (Dynamic Client Registration).
export const dynamic = 'force-dynamic';
export function GET() {
  const site = siteUrl();
  return Response.json({
    issuer: site, authorization_endpoint: `${site}/oauth/authorize`, token_endpoint: `${site}/api/oauth/token`, registration_endpoint: `${site}/api/oauth/register`,
    response_types_supported: ['code'], grant_types_supported: ['authorization_code', 'refresh_token'], code_challenge_methods_supported: ['S256'],
    token_endpoint_auth_methods_supported: ['none'], scopes_supported: SCOPES, service_documentation: `${site}/admin/settings/api`
  }, { headers: { 'cache-control': 'public, max-age=3600', 'access-control-allow-origin': '*' } });
}
