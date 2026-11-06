import { pageMeta } from '@/features/seo/meta';
import { requireAdmin } from '@/server/admin/data';
import { rpc } from '@/lib/db/repo';
import { SCOPES, SCOPE_LABEL, parseScopes } from '@/features/api-access/tools';
import { decideOAuth } from '@/server/actions/api-access';

// Connect Claude (release 28, B3; migration 0562): the OAuth consent page of the MCP connector. Claude sends the Admin
// here; they sign in (and pass the two-step check) as for the portal, see who is asking and what it may do, and allow
// or deny. Only Admins may connect.
export const dynamic = 'force-dynamic';
export const metadata = pageMeta({ title: 'Connect Claude to CarmaCars', path: '/oauth/authorize', noindex: true, description: 'Allow Claude to read and adjust bookings, requests and owners as you.' });
const SR = { role: 'service_role' as const };

export default async function Authorize({ searchParams }: { searchParams: Promise<Record<string, string | undefined>> }) {
  const sp = await searchParams;
  const qs = new URLSearchParams(Object.entries(sp).filter((e): e is [string, string] => typeof e[1] === 'string')).toString();
  await requireAdmin(`/oauth/authorize?${qs}`);
  const problem = (text: string) => (
    <div className="wrap section stack" style={{ maxWidth: '40rem' }}><h1 className="d2">Claude could not be connected</h1><p className="lead" data-testid="oauth-error">{text}</p></div>);
  if (sp.response_type !== 'code') return problem('The request is not an authorization code request. Start again from Claude.');
  if (!sp.code_challenge || !/^[A-Za-z0-9_-]{43}$/.test(sp.code_challenge) || sp.code_challenge_method !== 'S256') return problem('The request has no PKCE challenge (S256). Start again from Claude.');
  const client = sp.client_id ? (await rpc('server_api_oauth_client', { p_client_id: sp.client_id }, SR).catch(() => null)) as unknown as { client_name: string; redirect_uris: string[] } | null : null;
  if (!client) return problem('This connection is not registered. Remove the connector in Claude and add it again.');
  const redirect = sp.redirect_uri ?? client.redirect_uris[0] ?? '';
  const loop = (u: string) => u.replace(/^(http:\/\/(?:localhost|127\.0\.0\.1)):\d{1,5}\//, '$1/');
  if (!client.redirect_uris.includes(redirect) && !client.redirect_uris.some((u) => loop(u) === loop(redirect) && /^http:\/\/(localhost|127\.0\.0\.1)/.test(redirect))) return problem('The return address is not the one this connection registered.');
  const asked = parseScopes(sp.scope);
  const host = new URL(redirect).host;
  return (
    <div className="wrap section" style={{ maxWidth: '40rem' }}>
      <form action={decideOAuth} className="stack" data-testid="oauth-consent">
        <p className="eyebrow">Connect Claude</p>
        <h1 className="d2">Allow {client.client_name} to work in CarmaCars as you?</h1>
        <p className="lead">It returns to <b>{host}</b>. It can do only what you allow below, as you, and every call is logged with the values before and after (Admin &gt; Settings &gt; API access, where you can also disconnect it).</p>
        <fieldset className="field"><legend className="label">What it may do</legend>
          {SCOPES.map((s) => (
            <label key={s} className="check"><input type="checkbox" name={`scope:${s}`} defaultChecked={asked.includes(s)} /> <span>{SCOPE_LABEL[s]}</span></label>))}
        </fieldset>
        <p className="small muted">Prices, payments, status, offers and extensions stay in the portal: the connector changes only listed details.</p>
        {(['client_id', 'state', 'code_challenge'] as const).map((k) => <input key={k} type="hidden" name={k} value={sp[k] ?? ''} />)}
        <input type="hidden" name="redirect_uri" value={redirect} />
        <div className="row">
          <button className="btn btn--primary" type="submit" name="decision" value="allow" data-testid="oauth-allow">Allow</button>
          <button className="btn btn--ghost" type="submit" name="decision" value="deny" data-testid="oauth-deny">Deny</button>
        </div>
      </form>
    </div>
  );
}
