'use client';
import { useState } from 'react';
import { useRouter } from 'next/navigation';
import { agreementSignNow } from '@/server/actions/onboarding-now';

// R51 (5304, REQ-135): the agreement step's one button. It makes the agreement when there is none yet and opens it to sign.
export function SignNow({ label, primary = true, testId = 'welcome-sign-now' }: { label: string; primary?: boolean; testId?: string }) {
  const router = useRouter();
  const [busy, setBusy] = useState(false);
  const [msg, setMsg] = useState('');
  const go = async () => {
    setBusy(true); setMsg('');
    const r = await agreementSignNow();
    setBusy(false);
    if (r.ok) { router.push(r.href); return; }
    setMsg(r.message);
    router.refresh();
  };
  return (
    <div className="stack">
      <button type="button" className={`btn btn--lg btn--block ${primary ? 'btn--primary' : 'btn--ghost'}`} aria-busy={busy} disabled={busy} onClick={() => void go()} data-testid={testId}>{busy ? 'Getting your agreement' : label}</button>
      {msg && <p className="alert alert--warn" role="status" data-testid={`${testId}-msg`}><span>{msg}</span></p>}
    </div>
  );
}
