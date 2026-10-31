'use client';
import { useState, useTransition } from 'react';
import { confirmCall } from '@/server/actions/careers';

export function ConfirmCall({ token, seq }: { token: string; seq: number | null }) {
  const [pending, run] = useTransition();
  const [msg, setMsg] = useState<{ ok: boolean; text: string } | null>(null);
  if (msg?.ok) return <p className="alert alert--ok" role="status" data-testid="confirm-done"><span>{msg.text}</span></p>;
  return (
    <div className="stack">
      <p>Press the button to keep your call. A call that is not confirmed in time is cancelled, so another candidate can have the time.</p>
      <p><button className="btn btn--primary btn--lg" type="button" disabled={pending} data-testid="confirm-call" onClick={() => run(async () => {
        const r = await confirmCall(token, seq);
        setMsg(r.ok ? { ok: true, text: 'Thank you: your call is confirmed. Join the video call at the time from the link in our email.' } : { ok: false, text: r.message });
      })}>{pending ? 'Confirming' : 'Confirm my call'}</button></p>
      {msg && !msg.ok && <p className="alert alert--error" role="alert" data-testid="confirm-error"><span>{msg.text}</span></p>}
    </div>
  );
}
