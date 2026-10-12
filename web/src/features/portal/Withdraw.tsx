'use client';
import { useState } from 'react';
import { useRouter } from 'next/navigation';
import { withdrawRequest } from '@/server/actions/portal';
import { useAct } from './useAct';

export function Withdraw({ number }: { number: string }) {
  const router = useRouter();
  const [sure, setSure] = useState(false);
  const a = useAct();
  if (!sure) return <button type="button" className="btn btn--quiet btn--sm" onClick={() => setSure(true)}>Withdraw request</button>;
  return (
    <div className="pt-sheet">
      <p>Withdraw this request? No money has moved, so nothing is refunded or charged.</p>
      {a.res && !a.res.ok && <p className="error" role="alert">{a.res.message}</p>}
      <div className="row">
        <button type="button" className="btn btn--primary btn--sm" disabled={a.pending} onClick={() => a.run(() => withdrawRequest(number), (r) => { if (r.ok) router.refresh(); })}>{a.pending ? 'Withdrawing' : 'Yes, withdraw'}</button>
        <button type="button" className="btn btn--ghost btn--sm" onClick={() => setSure(false)}>Keep it</button>
      </div>
    </div>
  );
}
