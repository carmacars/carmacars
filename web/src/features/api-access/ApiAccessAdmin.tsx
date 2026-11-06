'use client';
import { useState, useTransition } from 'react';
import { useRouter } from 'next/navigation';
import { createApiKey, revokeApiKey } from '@/server/actions/api-access';
import { SCOPES, SCOPE_LABEL } from './tools';

// Admin > Settings > API access (release 28, B3): a key for a person (shown once), and Revoke for a key or a Claude
// connection. The page around it lists the keys, the setup steps and the call log.
export interface KeyRow { id: string; kind: 'key' | 'oauth'; name: string; prefix: string; scopes: string[]; email: string; client: string | null; created_at: string; last_used_at: string | null; expires_at: string | null; revoked_at: string | null }

export function NewKey({ admins }: { admins: Array<{ user_id: string; email: string }> }) {
  const router = useRouter();
  const [pending, start] = useTransition();
  const [made, setMade] = useState<{ secret: string; name: string } | null>(null);
  const [err, setErr] = useState<string | null>(null);
  const [copied, setCopied] = useState(false);
  return (
    <div className="stack" data-testid="api-new-key">
      <form className="ad-form stack" onSubmit={(e) => { e.preventDefault(); const fd = new FormData(e.currentTarget); setErr(null); setMade(null);
        start(async () => { const r = await createApiKey(fd); if (r.ok) { setMade(r.data); router.refresh(); } else setErr(r.message); }); }}>
        <div className="ad-fields">
          <div className="field ad-field"><label className="label" htmlFor="ak-user">For</label>
            <select className="select" id="ak-user" name="user_id" required>{admins.map((a) => <option key={a.user_id} value={a.user_id}>{a.email}</option>)}</select></div>
          <div className="field ad-field"><label className="label" htmlFor="ak-name">Name</label>
            <input className="input" id="ak-name" name="name" maxLength={80} required placeholder="Claude Code on my laptop" /></div>
        </div>
        <fieldset className="field"><legend className="label">Scopes</legend>
          <div className="row">{SCOPES.map((s) => <label key={s} className="check"><input type="checkbox" name={`scope:${s}`} defaultChecked={s.endsWith(':read')} /> <span>{SCOPE_LABEL[s]}</span></label>)}</div>
        </fieldset>
        <div className="row"><button className="btn btn--primary btn--sm" type="submit" disabled={pending} data-testid="api-key-create">{pending ? 'Creating' : 'Create the key'}</button></div>
        {err && <p className="error" role="alert">{err}</p>}
      </form>
      {made && (
        <div className="alert alert--ok stack" role="status" data-testid="api-key-secret">
          <p><b>{made.name}</b>: copy the key now. It is shown only this once; CarmaCars keeps only a fingerprint of it.</p>
          <p><code className="pt-mono" style={{ overflowWrap: 'anywhere' }}>{made.secret}</code></p>
          <p><button type="button" className="btn btn--sm" onClick={() => { void navigator.clipboard?.writeText(made.secret).then(() => setCopied(true)); }}>{copied ? 'Copied' : 'Copy the key'}</button></p>
        </div>)}
    </div>
  );
}

export function RevokeKey({ id, label }: { id: string; label: string }) {
  const router = useRouter();
  const [pending, start] = useTransition();
  const [err, setErr] = useState<string | null>(null);
  return (<>
    <button type="button" className="btn btn--ghost btn--sm ad-btn--danger" disabled={pending} data-testid="api-key-revoke"
      onClick={() => { if (!window.confirm(`Revoke ${label}? It stops working at once.`)) return; start(async () => { const r = await revokeApiKey(id); if (r.ok) router.refresh(); else setErr(r.message); }); }}>
      {pending ? 'Revoking' : 'Revoke'}</button>
    {err && <span className="error" role="alert">{err}</span>}
  </>);
}
