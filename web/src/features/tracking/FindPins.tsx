'use client';
import { useState, useTransition } from 'react';
import { useRouter } from 'next/navigation';
import { findPoundPins } from '@/server/actions/pound';

// Pound lots (migration 3320): finds the pin of every lot that has none from its address (the site's address lookup),
// so a car parked there can be flagged. Lots whose address is not found keep "No pin yet": an Admin types the pin.
export function FindPins({ count, refresh }: { count: number; refresh: string[] }) {
  const [pending, start] = useTransition();
  const [msg, setMsg] = useState<{ ok: boolean; text: string } | null>(null);
  const router = useRouter();
  const run = () => start(async () => {
    const r = await findPoundPins(refresh);
    setMsg(r.ok ? { ok: true, text: r.data.found ? `Found ${r.data.found} of ${r.data.asked}. ${r.data.asked - r.data.found ? 'Type the pin of the others (Edit).' : 'Every lot has its pin.'}` : 'No address was found by the lookup. Type each pin (Edit): the latitude and longitude from a map.' }
      : { ok: false, text: r.message });
    if (r.ok) router.refresh();
  });
  return (
    <div className="te-pins" data-testid="find-pins">
      <p className="small"><b>{count} lot{count === 1 ? ' has' : 's have'} no pin yet</b>, so a car parked there is not flagged.</p>
      <button type="button" className="btn btn--ghost btn--sm" onClick={run} disabled={pending} aria-busy={pending} data-testid="find-pins-run">{pending ? 'Finding the pins' : 'Find the pins from the addresses'}</button>
      {msg && <p className={`alert ${msg.ok ? 'alert--ok' : 'alert--error'}`} role={msg.ok ? 'status' : 'alert'}><span>{msg.text}</span></p>}
    </div>
  );
}
