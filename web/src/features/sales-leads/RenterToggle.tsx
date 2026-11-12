'use client';
import { useState, useTransition } from 'react';
import { leadContextRead } from '@/server/actions/sales-leads';
import { RenterContext } from './RenterContext';
import type { LeadContext } from './model';

/** A lead card's Renter button (2411): opens the whole person behind the lead under the card, read when first opened. */
export function RenterToggle({ lead, portal }: { lead: string; portal: '/admin' | '/staff' }) {
  const [open, setOpen] = useState(false);
  const [c, setC] = useState<LeadContext | null>(null);
  const [err, setErr] = useState<string | null>(null);
  const [pending, start] = useTransition();
  const toggle = () => {
    const next = !open;
    setOpen(next);
    if (next && !c) start(async () => {
      const r = await leadContextRead<LeadContext>(lead);
      if (r.ok) { setC(r.data); setErr(null); } else setErr(r.message);
    });
  };
  return (
    <div className="stack" style={{ gap: 'var(--s-2)' }}>
      <button type="button" className="btn btn--quiet btn--sm" aria-expanded={open} onClick={toggle} data-testid="lead-renter-toggle">{open ? 'Hide the person' : 'The person'}</button>
      {open && (pending && !c ? <p className="small muted" role="status">Loading everything we know…</p>
        : err ? <p className="small" role="alert">{err}</p>
        : c ? <RenterContext c={c} portal={portal} /> : null)}
    </div>
  );
}
