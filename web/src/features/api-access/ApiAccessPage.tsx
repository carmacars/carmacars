import { rpc } from '@/lib/db/repo';
import { siteUrl } from '@/lib/site';
import { CONNECTOR_URL, TOOLS, WRITABLE } from './tools';
import { NewKey, RevokeKey, type KeyRow } from './ApiAccessAdmin';

// Admin > Settings > API access (release 28, B3; migration 0562): how to connect Claude, the keys and connections, and
// every call with the values before and after.
const SR = { role: 'service_role' as const };
interface Call { id: number; at: string; email: string | null; key: string | null; tool: string; target: string | null; ok: boolean; error: string | null; before: Record<string, unknown> | null; after: Record<string, unknown> | null }
interface View { enabled: boolean; per_minute: number; admins: Array<{ user_id: string; email: string }>; keys: KeyRow[]; calls: Call[] }
const when = (s: string | null) => (s ? new Date(s).toLocaleString('en-CA', { timeZone: 'America/Toronto', dateStyle: 'medium', timeStyle: 'short' }) : 'never');

export async function ApiAccessPage({ adminId }: { adminId: string }) {
  const v = (await rpc('server_api_access_view', { p_admin: adminId }, SR)) as unknown as View;
  const mcp = `${siteUrl()}/api/mcp`;
  const live = v.keys.filter((k) => !k.revoked_at);
  return (
    <div className="stack-lg" data-testid="api-access">
      {!v.enabled && <p className="alert alert--warn" role="status">API access is off (Settings &gt; Program, api_access_enabled): every key and connection is refused.</p>}
      <section className="pt-card ad-card stack" aria-labelledby="api-h-setup">
        <div className="pt-card__head"><h2 className="d4" id="api-h-setup">Connect Claude</h2></div>
        <p className="alert alert--info" role="note" data-testid="api-connect-claude"><b>Connect from Claude:</b> in Claude, Settings &gt; Connectors &gt; Add custom connector, paste <code className="pt-mono">{CONNECTOR_URL}</code>, press Connect and sign in here as an Admin.</p>
        <p>Claude can then run CarmaCars for you, as you: bookings, offers, payments, refunds, returns, cars, rates, listings, owners, invoices, staff and hiring. Every change is previewed first and done only when confirmed. Only Admins can connect. Every call is logged below with the values before and after; at most {v.per_minute} calls a minute per connection.</p>
        <ol className="stack">
          <li><b>Claude (claude.ai, Desktop or the phone app):</b> Settings &gt; Connectors &gt; Add custom connector. Name it CarmaCars and paste the address <code className="pt-mono">{mcp}</code>. Press Connect: Claude opens CarmaCars, you sign in (with your second step), choose what it may do and press Allow. It stays connected for 30 days of use; disconnect it here or in Claude.</li>
          <li><b>Claude Code:</b> run <code className="pt-mono">claude mcp add --transport http carmacars {mcp}</code>, then <code className="pt-mono">/mcp</code> in Claude Code to sign in the same way. Or, with a key made below: <code className="pt-mono">claude mcp add --transport http carmacars {mcp} --header &quot;Authorization: Bearer cc_live_...&quot;</code>.</li>
          <li><b>Scripts:</b> POST JSON-RPC 2.0 (MCP) to the same address with the header <code className="pt-mono">Authorization: Bearer &lt;key&gt;</code>.</li>
        </ol>
        <details><summary className="link">The tools, and what each may change</summary>
          <ul className="ad-list">{TOOLS.map((t) => <li key={t.name}><span><code className="pt-mono">{t.name}</code> ({t.scope === 'any' ? 'any key' : t.scope})</span><span className="ad-sub">{t.description}</span></li>)}</ul>
          <p className="small muted">Writable fields: bookings {WRITABLE.update_booking.join(', ')}; requests (not yet offered) {WRITABLE.update_request.join(', ')}; owners {WRITABLE.update_owner.join(', ')}.</p>
        </details>
      </section>

      <section className="pt-card ad-card stack" aria-labelledby="api-h-new">
        <div className="pt-card__head"><h2 className="d4" id="api-h-new">Make a key</h2></div>
        <p className="small muted">For Claude Code or a script. A key belongs to one Admin and acts as them; it stops when revoked or when the person stops being an Admin. At most 5 keys a person.</p>
        <NewKey admins={v.admins} />
      </section>

      <section className="pt-card ad-card stack" aria-labelledby="api-h-keys">
        <div className="pt-card__head"><h2 className="d4" id="api-h-keys">Keys and connections ({live.length} working)</h2></div>
        {v.keys.length ? (
          <div className="ad-table-wrap"><table className="ad-table" data-testid="api-keys">
            <thead><tr><th scope="col">Name</th><th scope="col">Person</th><th scope="col">Scopes</th><th scope="col">Last used</th><th scope="col">State</th><th scope="col"><span className="vh">Revoke</span></th></tr></thead>
            <tbody>{v.keys.map((k) => (
              <tr key={k.id}><td>{k.name} <span className="ad-sub pt-mono">{k.prefix}…</span></td><td>{k.email}</td><td className="small">{k.scopes.join(', ')}</td><td>{when(k.last_used_at)}</td>
                <td>{k.revoked_at ? `Revoked ${when(k.revoked_at)}` : k.kind === 'oauth' ? `Connected, renews until ${when(k.expires_at)}` : 'Working'}</td>
                <td>{!k.revoked_at && <RevokeKey id={k.id} label={k.name} />}</td></tr>))}</tbody>
          </table></div>) : <p className="ad-empty">No keys or connections yet.</p>}
      </section>

      <section className="pt-card ad-card stack" aria-labelledby="api-h-log">
        <div className="pt-card__head"><h2 className="d4" id="api-h-log">Call log (last 100)</h2></div>
        {v.calls.length ? (
          <div className="ad-table-wrap"><table className="ad-table" data-testid="api-calls">
            <thead><tr><th scope="col">When</th><th scope="col">Who</th><th scope="col">Tool</th><th scope="col">Record</th><th scope="col">Change</th><th scope="col">Result</th></tr></thead>
            <tbody>{v.calls.map((c) => (
              <tr key={c.id}><td>{when(c.at)}</td><td>{c.email ?? 'removed'}<span className="ad-sub">{c.key}</span></td><td><code className="pt-mono">{c.tool}</code></td><td>{c.target ?? ''}</td>
                <td className="small">{c.after ? Object.keys(c.after).map((f) => <div key={f}><b>{f}</b>: {JSON.stringify(c.before?.[f] ?? null)} to {JSON.stringify(c.after?.[f] ?? null)}</div>) : ''}</td>
                <td>{c.ok ? 'Done' : <span className="error">{c.error}</span>}</td></tr>))}</tbody>
          </table></div>) : <p className="ad-empty">No calls yet.</p>}
      </section>
    </div>
  );
}
