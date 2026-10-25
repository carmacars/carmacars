'use client';
import { useState } from 'react';
import { verifySha } from '@/server/actions/agreements';

export function VerifyFile() {
  const [state, setState] = useState<{ sha: string; found: boolean; title?: string; at?: string } | null>(null);
  const [err, setErr] = useState<string | null>(null);
  const [busy, setBusy] = useState(false);
  const check = async (f: File | undefined) => {
    if (!f) return;
    setBusy(true); setErr(null); setState(null);
    try {
      const sha = [...new Uint8Array(await crypto.subtle.digest('SHA-256', await f.arrayBuffer()))].map((b) => b.toString(16).padStart(2, '0')).join('');
      const r = await verifySha(sha);
      if (!r.ok) setErr(r.message); else setState({ sha, found: r.data.found, title: r.data.title, at: r.data.recorded_at });
    } finally { setBusy(false); }
  };
  return (
    <div className="stack">
      <label className="field"><span className="label">The PDF to check</span>
        <input className="input" type="file" accept="application/pdf,.pdf" disabled={busy} onChange={(e) => check(e.target.files?.[0])} data-testid="verify-file" /></label>
      {busy && <p className="small" role="status">Checking…</p>}
      {state && (state.found
        ? <p className="alert alert--ok" role="status" data-testid="verify-found"><span className="alert__title">Recorded by CarmaCars</span><span>{state.title} recorded {state.at?.slice(0, 10)}. This file is exactly the one signed.</span></p>
        : <p className="alert alert--error" role="alert" data-testid="verify-not-found"><span className="alert__title">Not recorded</span><span>This file does not match any signed CarmaCars document. It may have been changed, or it is not a signed copy.</span></p>)}
      {state && <p className="xs muted">SHA-256: <code style={{ wordBreak: 'break-all' }}>{state.sha}</code></p>}
      {err && <p className="alert alert--error" role="alert"><span>{err}</span></p>}
    </div>
  );
}
