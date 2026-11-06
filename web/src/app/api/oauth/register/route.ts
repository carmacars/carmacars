import { rpc } from '@/lib/db/repo';
import { newSecret } from '@/features/api-access/tools';

// Dynamic Client Registration (RFC 7591) for the MCP connector (release 28, B3): Claude registers itself as a public
// client. Only Claude's callback (https://claude.ai/api/mcp/auth_callback) and loopback addresses (Claude Code) are
// accepted, at most 30 registrations an hour (migration 0562). A client alone can do nothing: an Admin still signs in
// and approves on /oauth/authorize.
export const dynamic = 'force-dynamic';
const SR = { role: 'service_role' as const };
const err = (e: string, d: string, status = 400) => Response.json({ error: e, error_description: d }, { status, headers: { 'cache-control': 'no-store' } });

export async function POST(req: Request) {
  const b = (await req.json().catch(() => null)) as { client_name?: unknown; redirect_uris?: unknown } | null;
  const uris = Array.isArray(b?.redirect_uris) ? b!.redirect_uris.filter((u): u is string => typeof u === 'string').slice(0, 5) : [];
  if (!uris.length) return err('invalid_redirect_uri', 'redirect_uris is required');
  const clientId = newSecret('ccc_').slice(0, 40);
  try {
    await rpc('server_api_oauth_register', { p_client_id: clientId, p_name: typeof b?.client_name === 'string' ? b.client_name.slice(0, 120) : 'Claude', p_redirects: uris }, SR);
  } catch (e) {
    const m = e instanceof Error ? e.message.replace(/^.*?ERROR:\s*/, '') : 'Not accepted';
    return err(/redirect/i.test(m) ? 'invalid_redirect_uri' : 'invalid_client_metadata', m, /too many/i.test(m) ? 429 : 400);
  }
  return Response.json({ client_id: clientId, client_id_issued_at: Math.floor(Date.now() / 1000), client_name: typeof b?.client_name === 'string' ? b.client_name.slice(0, 120) : 'Claude',
    redirect_uris: uris, token_endpoint_auth_method: 'none', grant_types: ['authorization_code', 'refresh_token'], response_types: ['code'] },
  { status: 201, headers: { 'cache-control': 'no-store' } });
}
