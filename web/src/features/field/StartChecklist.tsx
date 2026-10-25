'use client';
import { useState, useTransition } from 'react';
import { useRouter } from 'next/navigation';
import { fieldAct } from '@/server/actions/field';
import { FdIcon } from './icons';

// "Check out (pickup)" and "Check in (return)" on a field job card (migration 0130): one tap acknowledges and starts
// the job when it is not started yet, then opens its checklist.
export function StartChecklist({ job, status, label, testId }: { job: string; status: string; label: string; testId?: string }) {
  const router = useRouter();
  const [pending, start] = useTransition();
  const [err, setErr] = useState<string | null>(null);
  const go = () => start(async () => {
    setErr(null);
    try {
      if (status === 'scheduled') { const a = await fieldAct('acknowledge', { job }); if (!a.ok) { setErr(a.message); return; } }
      if (status === 'scheduled' || status === 'acknowledged') { const s = await fieldAct('start', { job }); if (!s.ok) { setErr(s.message); return; } }
    } catch { setErr('No connection. Try again when you have signal.'); return; }
    router.push(`/field/jobs/${job}`);
  });
  return (
    <div className="fd-act">
      <button className="btn btn--primary fd-wide fd-cta" type="button" disabled={pending} onClick={go} data-testid={testId}><FdIcon name="key" /><span>{pending ? 'Opening' : label}</span></button>
      {err && <p className="error" role="alert">{err}</p>}
    </div>
  );
}
