'use client';
import { useState, useTransition } from 'react';
import { useRouter } from 'next/navigation';
import { money } from '@/lib/format';
import { staffDo } from '@/server/actions/staff-tools';
import type { BookingAddon } from './model';
import { WhyDisabled } from '@/components/WhyDisabled';

// A rental's winter tire fee (migration 5142), insurer rentals too: the rate a day for this rental (0 removes the tires) and,
// if needed, its cap, with the reason. The database records who changed it and why, reprices the booking (and the insurer's
// share) and tells the renter of a rental they pay.
export function WinterTireCard({ booking, addons, insurer }: { booking: string; addons: BookingAddon[]; insurer: boolean }) {
  const router = useRouter();
  const now = addons.find((a) => a.code === 'winter_tire') ?? null;
  const [rate, setRate] = useState(now ? (now.unit_price_cents / 100).toFixed(2) : '');
  const [cap, setCap] = useState('');
  const [reason, setReason] = useState('');
  const [msg, setMsg] = useState<{ ok: boolean; text: string } | null>(null);
  const [pending, start] = useTransition();
  const cents = (s: string) => { const t = s.replace(/[$,\s]/g, ''); return t === '' ? 0 : /^\d+(\.\d{0,2})?$/.test(t) ? Math.round(Number(t) * 100) : null; };
  const r = cents(rate), c = cap.trim() ? cents(cap) : undefined;
  const why = r == null ? 'Type the rate a day in dollars and cents' : c === null ? 'Type the cap in dollars and cents' : !reason.trim() ? 'Say why the fee changes' : null;
  const save = () => start(async () => {
    setMsg(null);
    const res = await staffDo<{ before_cents: number | null; after_cents: number | null; total_cents: number }>('winter_tire_set', { booking, rate_cents: r, ...(c != null ? { cap_cents: c } : {}), reason: reason.trim() });
    if (!res.ok) { setMsg({ ok: false, text: res.message }); return; }
    const f = (x: number | null) => (x == null ? 'none' : money(x, { cents: true }));
    setMsg({ ok: true, text: `Saved. Winter tires ${f(res.data.before_cents)} to ${f(res.data.after_cents)} for the rental; the booking total is ${money(res.data.total_cents, { cents: true })}.` });
    setReason(''); router.refresh();
  });
  return (
    <div className="stack" data-testid="winter-tire-card">
      <p className="small">{now ? <>Winter tires on this rental: <b>{money(now.unit_price_cents, { cents: true })} a day</b>{now.amount_cents != null ? <>, {money(now.amount_cents, { cents: true })} for the rental</> : null}.</> : 'No winter tires on this rental.'}{insurer ? ' Billed to the insurer with the rental.' : ''}</p>
      <div className="ad-fields">
        <div className="field ad-field"><label className="label" htmlFor="wt-rate">Rate a day ($, 0 removes them)</label>
          <input className="input" id="wt-rate" inputMode="decimal" value={rate} onChange={(e) => setRate(e.target.value)} disabled={pending} data-testid="winter-rate" /></div>
        <div className="field ad-field"><label className="label" htmlFor="wt-cap">Cap for the rental ($, optional)</label>
          <input className="input" id="wt-cap" inputMode="decimal" value={cap} onChange={(e) => setCap(e.target.value)} disabled={pending} /></div>
        <div className="field ad-field ad-field--wide"><label className="label" htmlFor="wt-why">Why</label>
          <input className="input" id="wt-why" value={reason} onChange={(e) => setReason(e.target.value)} disabled={pending} data-testid="winter-reason" /></div>
      </div>
      <div className="row"><button className="btn btn--primary btn--sm" type="button" disabled={pending || !!why} onClick={save} aria-describedby="why-winter" data-testid="winter-save">{pending ? 'Saving' : 'Save the winter tire fee'}</button>
        <WhyDisabled id="why-winter" why={why} /></div>
      {msg && <p className={`alert ${msg.ok ? 'alert--ok' : 'alert--error'}`} role={msg.ok ? 'status' : 'alert'}><span>{msg.text}</span></p>}
    </div>
  );
}
