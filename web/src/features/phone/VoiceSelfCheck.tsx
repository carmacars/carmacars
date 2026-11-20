'use client';
import { useState } from 'react';
import type { CheckStep } from './twilio';
import { testCall, type TestStep } from './voice';

// r48 CM: Settings > Calls, Test call. The server checks every part of a browser call (the keys, the Twilio account and
// balance, the TwiML App and where it sends calls, the caller ID, the setting, our webhook, your token) and names the
// first step that fails with what to press; then a real test call from this browser plays a short message.
type Answer = { ok: boolean; steps: CheckStep[]; test?: { token: string; t: string }; error?: string };

export function VoiceSelfCheck() {
  const [busy, setBusy] = useState(false);
  const [check, setCheck] = useState<Answer | null>(null);
  const [live, setLive] = useState<TestStep[]>([]);

  const run = async () => {
    setBusy(true); setCheck(null); setLive([]);
    try {
      const r = await fetch('/api/staff/phone?what=voice_selfcheck', { cache: 'no-store', credentials: 'same-origin', signal: AbortSignal.timeout(60_000) });
      const j = (await r.json().catch(() => null)) as Answer | null;
      const a: Answer = j && Array.isArray(j.steps) ? j : { ok: false, steps: [], error: j?.error ?? `The server answered ${r.status}` };
      setCheck(a);
      if (a.test) await testCall(a.test.token, a.test.t, (s) => setLive((x) => [...x, s]));
    } catch {
      setCheck({ ok: false, steps: [], error: 'The server did not answer in a minute.' });
    } finally { setBusy(false); }
  };

  const rows: Array<CheckStep | TestStep> = [...(check?.steps ?? []), ...live];
  const firstBad = rows.find((s) => !s.ok);
  return (
    <section className="card" data-testid="voice-selfcheck">
      <h2>Test call</h2>
      <p className="muted">Checks every step of a call from the browser, then places a test call from this page that plays a short message (allow the microphone). Nobody is dialled.</p>
      <button type="button" className="btn" disabled={busy} onClick={() => void run()} data-testid="voice-selfcheck-run">{busy ? 'Testing...' : 'Run test call'}</button>
      {check?.error && <p className="alert alert--error" role="alert">{check.error}</p>}
      {rows.length > 0 && (
        <ol className="selfcheck" data-testid="voice-selfcheck-steps">
          {rows.map((s, i) => (
            <li key={i} data-ok={s.ok ? 'yes' : 'no'}>
              <strong>{s.ok ? 'OK' : 'Failed'}: {s.step}</strong> <span>{s.detail}</span>
              {'fix' in s && s.fix && !s.ok && <div className="muted">What to do: {s.fix}</div>}
            </li>
          ))}
        </ol>
      )}
      {!busy && rows.length > 0 && (firstBad
        ? <p className="alert alert--warn" role="status" data-testid="voice-selfcheck-result">The failing step: {firstBad.step}.</p>
        : <p className="alert alert--ok" role="status" data-testid="voice-selfcheck-result">Every step works.</p>)}
    </section>
  );
}
