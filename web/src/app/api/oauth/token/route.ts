import { rpc } from '@/lib/db/repo';
import { newSecret, pkceChallenge, secretPrefix, sha256Hex } from '@/features/api-access/tools';

// The OAuth token endpoint of the MCP connector (release 28, B3; migration 0562): an authorization code (with its PKCE
// verifier) or a refresh token becomes a new access token (1 hour) and refresh token (30 days, rotated on each use).
// The database keeps only their hashes.
export const dynamic = 'force-dynamic';
const SR = { role: 'service_role' as const };
const H = { 'cache-control': 'no-store', pragma: 'no-cache' };
const err = (e: string, d?: string, status = 400) => Response.json({ error: e, ...(d ? { error_description: d } : {}) }, { status, headers: H });

export async function POST(req: Request) {
  const type = req.headers.get('content-type') ?? '';
  const f: Record<string, string> = {};
  // only text values are read: a JSON body may carry objects or arrays where a string is expected
  if (type.includes('application/json')) { const j = (await req.json().catch(() => null)) as unknown; if (j && typeof j === 'object' && !Array.isArray(j)) for (const [k, v] of Object.entries(j)) if (typeof v === 'string') f[k] = v.slice(0, 4096); }
  else for (const [k, v] of new URLSearchParams(await req.text())) f[k] = v;
  const grant = f.grant_type;
  if (grant !== 'authorization_code' && grant !== 'refresh_token') return err('unsupported_grant_type');
  if (!f.client_id) return err('invalid_client', 'client_id is required', 401);
  const access = newSecret('cca_'), refresh = newSecret('ccr_');
  const p: Record<string, string> = { grant_type: grant, client_id: f.client_id, access_hash: await sha256Hex(access), refresh_hash: await sha256Hex(refresh), prefix: secretPrefix(access) };
  if (grant === 'authorization_code') {
    if (!f.code || !f.code_verifier || !/^[A-Za-z0-9._~-]{43,128}$/.test(f.code_verifier)) return err('invalid_request', 'code and code_verifier are required');
    p.code_hash = await sha256Hex(f.code);
    p.redirect_uri = f.redirect_uri ?? '';
    p.challenge = await pkceChallenge(f.code_verifier);
  } else {
    if (!f.refresh_token) return err('invalid_request', 'refresh_token is required');
    p.old_refresh_hash = await sha256Hex(f.refresh_token);
  }
  const r = (await rpc('server_api_oauth_token', { p: p as never }, SR).catch(() => ({ error: 'server_error' }))) as unknown as { ok?: boolean; error?: string; error_description?: string; scopes?: string[]; expires_in?: number };
  if (!r.ok) return err(r.error ?? 'invalid_grant', r.error_description, r.error === 'invalid_client' ? 401 : 400);
  return Response.json({ access_token: access, token_type: 'Bearer', expires_in: r.expires_in ?? 3600, refresh_token: refresh, scope: (r.scopes ?? []).join(' ') }, { headers: H });
}
