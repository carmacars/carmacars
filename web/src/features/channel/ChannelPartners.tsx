'use client';
import { useState, useTransition } from 'react';
import { useRouter } from 'next/navigation';
import { adminAct } from '@/server/actions/admin-portal';

// Admin > Settings > Channel partners (release 37, migration 2304): rental distribution partners (VIPCars,
// EconomyBookings, Rentalcars.com / Booking.com Cars, CarTrawler, Kayak through connectors), their markup and limits,
// their keys (shown once, revoked at once) and every call. Admins only. Separate from Settings > API access (0562).
export interface ChannelState {
  enabled: boolean;
  partners: Array<{ id: string; name: string; status: string; markup_bps: number; commission_bps: number; allowed_classes: string[]; calls_per_minute: number; calls_today: number;
    keys: Array<{ id: string; prefix: string; scopes: string[]; created_at: string; last_used_at: string | null; revoked_at: string | null }> }>;
  calls: Array<{ at: string; partner: string | null; key: string | null; call: string; ok: boolean; code: string | null }>;
}
const SCOPES: Array<[string, string, boolean]> = [['availability:read', 'Locations and cars', true], ['rates:read', 'Availability and prices', true],
  ['bookings:create', 'Send booking requests', false], ['bookings:cancel', 'Cancel their own requests', false]];
const when = (s: string | null) => (s ? new Date(s).toLocaleString('en-CA', { timeZone: 'America/Toronto', dateStyle: 'medium', timeStyle: 'short' }) : 'never');
const pct = (bps: number) => `${(bps / 100).toFixed(2).replace(/\.?0+$/, '')}%`;

export function ChannelPartners({ s }: { s: ChannelState }) {
  const router = useRouter();
  const [pending, start] = useTransition();
  const [msg, setMsg] = useState<{ ok: boolean; text: string } | null>(null);
  const [key, setKey] = useState<{ partner: string; key: string } | null>(null);
  const run = (action: string, p: Record<string, unknown>, ok: string, after?: (d: Record<string, unknown>) => void) => start(async () => {
    setMsg(null);
    const r = await adminAct<Record<string, unknown>>(action, p, ['/admin/settings/channel-partners']);
    if (r.ok) { setMsg({ ok: true, text: ok }); after?.(r.data); router.refresh(); } else setMsg({ ok: false, text: r.message });
  });
  return (
    <div className="stack-lg" data-testid="channel-partners">
      {!s.enabled && <p className="alert alert--warn" role="status">The channel API is off (Settings &gt; Program, channel_api_enabled): every partner key is refused.</p>}
      <p className="small muted">Partners see only public car details and public prices with their markup: never a renter, an owner, a plate, a VIN, a cost or another partner. A booking they send is an ordinary request: the renter verifies their licence before it is confirmed. What to send a partner: docs/channel-api.md.</p>
      {msg && <p className={`alert ${msg.ok ? 'alert--ok' : 'alert--error'}`} role={msg.ok ? 'status' : 'alert'}><span>{msg.text}</span></p>}
      {key && <div className="alert alert--info" role="status" data-testid="channel-new-key"><span className="alert__title">The key for {key.partner}: copy it now, it is shown once</span><code className="pt-mono" style={{ wordBreak: 'break-all' }}>{key.key}</code></div>}

      <section className="pt-card ad-card stack" aria-labelledby="ch-h-new">
        <h2 className="d4" id="ch-h-new">Add a partner</h2>
        <form className="ad-form stack" onSubmit={(e) => { e.preventDefault(); const fd = new FormData(e.currentTarget);
          run('channel_partner_save', { name: fd.get('name'), markup_bps: Math.round(Number(fd.get('markup') || 0) * 100), commission_bps: Math.round(Number(fd.get('commission') || 0) * 100),
            calls_per_minute: Number(fd.get('rpm') || 60), allowed_classes: String(fd.get('classes') || '').split(',').map((x) => x.trim()).filter(Boolean) }, 'Partner saved.'); }}>
          <div className="ad-fields">
            <div className="field ad-field"><label className="label" htmlFor="ch-name">Name</label><input className="input" id="ch-name" name="name" required maxLength={80} placeholder="VIPCars" /></div>
            <div className="field ad-field"><label className="label" htmlFor="ch-markup">Markup on our price (%)</label><input className="input" id="ch-markup" name="markup" type="number" min={0} max={100} step="0.01" defaultValue={0} /></div>
            <div className="field ad-field"><label className="label" htmlFor="ch-comm">Their commission (%)</label><input className="input" id="ch-comm" name="commission" type="number" min={0} max={100} step="0.01" defaultValue={0} /></div>
            <div className="field ad-field"><label className="label" htmlFor="ch-rpm">Calls a minute</label><input className="input" id="ch-rpm" name="rpm" type="number" min={1} max={600} defaultValue={60} /></div>
            <div className="field ad-field"><label className="label" htmlFor="ch-classes">Classes they may sell (comma separated; empty: all)</label><input className="input" id="ch-classes" name="classes" placeholder="economy, suv" /></div>
          </div>
          <div className="row"><button className="btn btn--primary btn--sm" type="submit" disabled={pending} data-testid="channel-partner-save">Save the partner</button></div>
        </form>
      </section>

      {s.partners.map((p) => (
        <section key={p.id} className="pt-card ad-card stack" aria-labelledby={`ch-${p.id}`} data-testid="channel-partner">
          <div className="pt-card__head"><h2 className="d4" id={`ch-${p.id}`}>{p.name} <span className="ad-sub">{p.status === 'active' ? 'Active' : 'Paused'}</span></h2>
            <button className="btn btn--ghost btn--sm" type="button" disabled={pending} onClick={() => run('channel_partner_save', { ...p, status: p.status === 'active' ? 'paused' : 'active' }, p.status === 'active' ? 'Paused: its keys are refused.' : 'Active again.')}>{p.status === 'active' ? 'Pause' : 'Resume'}</button></div>
          <p className="small">Markup {pct(p.markup_bps)} · commission {pct(p.commission_bps)} · {p.calls_per_minute} calls a minute · classes: {p.allowed_classes.length ? p.allowed_classes.join(', ') : 'all'} · {p.calls_today} calls in the last day</p>
          <form className="row" style={{ flexWrap: 'wrap', gap: '0.75rem' }} onSubmit={(e) => { e.preventDefault(); const fd = new FormData(e.currentTarget);
            run('channel_key_create', { partner: p.id, scopes: SCOPES.map(([x]) => x).filter((x) => fd.get(x)) }, 'Key made.', (d) => setKey({ partner: p.name, key: String(d.new_key ?? '') })); }}>
            {SCOPES.map(([x, label, on]) => <label key={x} className="check"><input type="checkbox" name={x} defaultChecked={on} /> <span>{label}</span></label>)}
            <button className="btn btn--primary btn--sm" type="submit" disabled={pending} data-testid="channel-key-create">Make a key</button>
          </form>
          {p.keys.length > 0 && <ul className="ad-list">{p.keys.map((k) => (
            <li key={k.id}><span className="pt-mono">{k.prefix}…</span> <span className="small">{k.scopes.join(', ')} · made {when(k.created_at)} · used {when(k.last_used_at)}{k.revoked_at ? ` · revoked ${when(k.revoked_at)}` : ''}</span>
              {!k.revoked_at && <button className="btn btn--danger btn--sm" type="button" disabled={pending} onClick={() => { if (confirm('Revoke this key? The partner is refused at once.')) run('channel_key_revoke', { id: k.id }, 'Key revoked.'); }} data-testid="channel-key-revoke">Revoke</button>}</li>))}</ul>}
        </section>))}

      <section className="pt-card ad-card stack" aria-labelledby="ch-h-log">
        <h2 className="d4" id="ch-h-log">Call log (last 100)</h2>
        {s.calls.length ? <div className="ad-table-wrap"><table className="ad-table" data-testid="channel-calls"><thead><tr><th scope="col">When</th><th scope="col">Partner</th><th scope="col">Call</th><th scope="col">Result</th></tr></thead>
          <tbody>{s.calls.map((c, i) => <tr key={i}><td>{when(c.at)}</td><td>{c.partner ?? 'unknown key'}<span className="ad-sub pt-mono">{c.key ?? ''}</span></td><td><code className="pt-mono">{c.call}</code></td><td>{c.ok ? 'Answered' : `Refused (${c.code})`}</td></tr>)}</tbody></table></div>
          : <p className="ad-empty">No calls yet.</p>}
      </section>
    </div>
  );
}
