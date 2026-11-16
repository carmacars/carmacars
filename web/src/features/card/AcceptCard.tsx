'use client';
import { useState, useTransition } from 'react';
import { useRouter } from 'next/navigation';
import { acceptCardName } from '@/server/actions/card-name';

import { WhyDisabled } from '@/components/WhyDisabled';
// "Accept this card" (release 48, migration 2912): shown to staff when the card's name differs from the renter's. The
// booking was not blocked; this records that a person checked it, with a short reason.
export function AcceptCard({ booking, cardholder, renter }: { booking: string; cardholder: string | null; renter: string }) {
  const router = useRouter();
  const [open, setOpen] = useState(false);
  const [reason, setReason] = useState('');
  const [msg, setMsg] = useState<{ ok: boolean; text: string } | null>(null);
  const [pending, start] = useTransition();
  const id = `ac-${booking}`;
  if (msg?.ok) return <p className="small" role="status" data-testid="card-accepted">{msg.text}</p>;
  return (
    <div className="stack" style={{ gap: 'var(--s-2)' }} data-testid="card-name-check">
      <p className="small">The name on the card ({cardholder ?? 'not given'}) is not quite the renter&apos;s ({renter}). The booking went ahead. Check the card and the licence, then accept it or contact the renter.</p>
      {!open ? <div><button className="btn btn--ghost btn--sm" type="button" onClick={() => setOpen(true)} data-testid="card-accept-open">Accept this card</button></div>
        : <div className="row" style={{ flexWrap: 'wrap', gap: 'var(--s-2)', alignItems: 'end' }}>
          <label className="field" style={{ margin: 0 }} htmlFor={id}><span className="label">Why this card is fine</span>
            <input className="input" id={id} maxLength={300} value={reason} onChange={(e) => setReason(e.target.value)} placeholder="Middle name on the card; licence seen" data-testid="card-accept-reason" /></label>
          <><button className="btn btn--primary btn--sm" type="button" disabled={pending || reason.trim().length < 4} data-testid="card-accept"
            onClick={() => start(async () => { const r = await acceptCardName(booking, reason.trim()); setMsg(r.ok ? { ok: true, text: 'Card accepted. The reason is in the booking history.' } : { ok: false, text: r.message }); if (r.ok) router.refresh(); })} aria-describedby="why-acceptcard-23">
            {pending ? 'Saving' : 'Accept this card'}</button><WhyDisabled id="why-acceptcard-23" why={((reason.trim().length < 4)) ? 'Write the reason first (4 characters or more)' : null} /></>
          <button className="btn btn--quiet btn--sm" type="button" onClick={() => setOpen(false)}>Cancel</button></div>}
      {msg && !msg.ok && <p className="alert alert--error" role="alert"><span>{msg.text}</span></p>}
    </div>
  );
}
