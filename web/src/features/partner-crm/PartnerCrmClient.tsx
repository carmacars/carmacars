'use client';
import { useId, useState, useTransition } from 'react';
import { useRouter } from 'next/navigation';
import { connectPartnerCrm, syncPartnerCrmNow, testPartnerCrmAction } from '@/server/actions/partner-crm';

// Admin > Settings > Partners > a partner (migration 0147): the connect form and the Test connection and Run sync now
// buttons. The token field is a password field, cleared after sending; the page never shows the token again (only its
// last four characters).
type Msg = { tone: 'ok' | 'error'; text: string } | null;

export function ConnectForm({ partnerId, connected, locationId, hint }: { partnerId: string; connected: boolean; locationId: string | null; hint: string | null }) {
  const router = useRouter();
  const idp = useId().replace(/:/g, '');
  const [token, setToken] = useState('');
  const [loc, setLoc] = useState(locationId ?? '');
  const [errs, setErrs] = useState<Record<string, string>>({});
  const [msg, setMsg] = useState<Msg>(null);
  const [pending, start] = useTransition();
  const submit = () => {
    setMsg(null); setErrs({});
    start(async () => {
      const r = await connectPartnerCrm(partnerId, token, loc);
      setToken('');
      if (!r.ok) { setErrs(r.fieldErrors ?? {}); setMsg({ tone: 'error', text: r.message }); return; }
      const d = r.data;
      const parts = [`Saved in the ${d.store === 'vault' ? 'vault' : 'database stand-in (local only)'}, ending ${d.token_hint}.`,
        d.test.ok ? 'Test connection passed.' : `Test connection failed: ${d.test.error ?? 'no answer'}.`,
        d.sync ? (d.sync.ok ? 'First sync done.' : `First sync: ${d.sync.error ?? 'failed'}.`) : null].filter(Boolean);
      setMsg({ tone: d.test.ok && (!d.sync || d.sync.ok) ? 'ok' : 'error', text: parts.join(' ') });
      router.refresh();
    });
  };
  return (
    <form className="ad-form" noValidate onSubmit={(e) => { e.preventDefault(); submit(); }} data-testid="crm-connect-form">
      <div className="ad-fields">
        <div className={`field ad-field ad-field--wide${errs.token ? ' has-error' : ''}`}>
          <label className="label" htmlFor={`${idp}-tok`}>{connected ? `New Private Integration token (replaces the one ending ${hint ?? '????'})` : 'Their Private Integration token'}</label>
          <input id={`${idp}-tok`} className="input" type="password" autoComplete="off" spellCheck={false} value={token} onChange={(e) => setToken(e.target.value)}
            placeholder="pit-..." aria-invalid={errs.token ? true : undefined} aria-describedby={`${idp}-tokh`} data-testid="crm-token" />
          <p className="hint" id={`${idp}-tokh`}>Kept in the vault. Never shown again, never emailed, never in the code.</p>
          {errs.token && <p className="error" role="alert">{errs.token}</p>}
        </div>
        <div className={`field ad-field${errs.location_id ? ' has-error' : ''}`}>
          <label className="label" htmlFor={`${idp}-loc`}>Their location ID</label>
          <input id={`${idp}-loc`} className="input" type="text" autoComplete="off" spellCheck={false} value={loc} onChange={(e) => setLoc(e.target.value)}
            aria-invalid={errs.location_id ? true : undefined} aria-describedby={`${idp}-loch`} data-testid="crm-location" />
          <p className="hint" id={`${idp}-loch`}>In their GoHighLevel address: app.gohighlevel.com/v2/location/THIS-PART/...</p>
          {errs.location_id && <p className="error" role="alert">{errs.location_id}</p>}
        </div>
      </div>
      {msg && <p className={`alert ${msg.tone === 'ok' ? 'alert--ok' : 'alert--error'}`} role={msg.tone === 'ok' ? 'status' : 'alert'} data-testid="crm-connect-result"><span>{msg.text}</span></p>}
      <div className="row"><button className="btn btn--primary btn--sm" type="submit" disabled={pending} data-testid="crm-connect">{pending ? 'Connecting' : connected ? 'Replace the token' : 'Connect'}</button></div>
    </form>
  );
}

export function RunButtons({ partnerId, connected }: { partnerId: string; connected: boolean }) {
  const router = useRouter();
  const [msg, setMsg] = useState<Msg>(null);
  const [pending, start] = useTransition();
  const go = (kind: 'test' | 'sync') => start(async () => {
    setMsg(null);
    const r = kind === 'test' ? await testPartnerCrmAction(partnerId) : await syncPartnerCrmNow(partnerId);
    if (!r.ok) { setMsg({ tone: 'error', text: r.message }); return; }
    const d = r.data as { ok: boolean; error: string | null; busy?: boolean; counts?: Record<string, unknown> };
    const c = d.counts ?? {};
    const sum = kind === 'sync' && d.ok ? ` ${Number(c.cars ?? 0)} cars shared (${Number(c.created ?? 0)} added, ${Number(c.updated ?? 0)} changed, ${Number(c.unchanged ?? 0)} unchanged, ${Number(c.removed ?? 0)} removed).` : '';
    setMsg(d.ok ? { tone: 'ok', text: kind === 'test' ? 'Test connection passed.' : `Sync done.${sum}` } : { tone: 'error', text: d.busy ? 'A sync is already running. Try again in a minute.' : d.error ?? 'Failed.' });
    router.refresh();
  });
  return (
    <div className="ad-inline">
      <div className="ad-actions">
        <button className="btn btn--ghost btn--sm" type="button" disabled={pending || !connected} onClick={() => go('test')} data-testid="crm-test">{pending ? 'Working' : 'Test connection'}</button>
        <button className="btn btn--primary btn--sm" type="button" disabled={pending || !connected} onClick={() => go('sync')} data-testid="crm-sync-now">{pending ? 'Working' : 'Run sync now'}</button>
      </div>
      {msg && <p className={`small ${msg.tone === 'error' ? 'ad-err' : ''}`} role={msg.tone === 'ok' ? 'status' : 'alert'} data-testid="crm-run-result">{msg.text}</p>}
    </div>
  );
}

export function CopyField({ label, value, testId }: { label: string; value: string; testId?: string }) {
  const idp = useId().replace(/:/g, '');
  const [copied, setCopied] = useState(false);
  return (
    <div className="field ad-field ad-field--wide">
      <label className="label" htmlFor={`${idp}-v`}>{label}</label>
      <div className="row">
        <input id={`${idp}-v`} className="input" readOnly value={value} onFocus={(e) => e.currentTarget.select()} data-testid={testId} />
        <button className="btn btn--ghost btn--sm" type="button" onClick={() => { void navigator.clipboard?.writeText(value).then(() => { setCopied(true); setTimeout(() => setCopied(false), 1500); }); }}>{copied ? 'Copied' : 'Copy'}</button>
      </div>
    </div>
  );
}
