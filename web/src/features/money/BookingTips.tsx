'use client';
import { useState, useTransition } from 'react';
import { useRouter } from 'next/navigation';
import { money } from '@/lib/format';
import { when } from '@/features/agreement/model';
import { offersDo } from '@/server/actions/offers';
import { DateInput } from '@/components/DateInput';
import { tipShareWords, type TipRow } from './tips';

export type { TipRow } from './tips';

// r48 part 2 (3053): the tips of a booking on its Money tab. Staff record a tip received in cash or by e-Transfer (the
// renter adds a card tip on their pay page, receipt or the after-trip link); each tip shows who gets what: half to the
// salesperson, half to the staff member at the handover, CarmaCars' half on a direct booking. An Admin gives one tip
// another split (all to one person, or back to the rule). A tip is never the rental: it is not in Rental due or Total paid.
const fmt = (c: number) => money(Number(c ?? 0), { cents: true });
const METHOD: Record<string, string> = { card: 'Card', cash: 'Cash', e_transfer: 'e-Transfer' };
const today = () => new Intl.DateTimeFormat('en-CA', { timeZone: 'America/Toronto', year: 'numeric', month: '2-digit', day: '2-digit' }).format(new Date());

export function BookingTips({ booking, tips, mayRecord, isAdmin, status }: { booking: string; tips: TipRow[]; mayRecord: boolean; isAdmin: boolean; status: string }) {
  const router = useRouter();
  const [pending, run] = useTransition();
  const [open, setOpen] = useState(false);
  const [f, setF] = useState({ method: 'cash', amount: '', reference: '', received_on: today() });
  const [msg, setMsg] = useState<{ ok: boolean; text: string } | null>(null);
  const paid = tips.filter((t) => t.status === 'paid');
  const total = paid.reduce((a, t) => a + t.amount_cents, 0);
  const canTip = ['pending_payment', 'confirmed', 'on_rent', 'returned', 'closed'].includes(status);
  const cents = (s: string) => { const t = s.replace(/[$,\s]/g, ''); return t ? Math.round(Number(t) * 100) : null; };
  const amount = cents(f.amount);
  const why = !amount || amount <= 0 ? 'Enter the amount of the tip first.' : f.method === 'e_transfer' && f.reference.trim().length < 3 ? 'Enter the e-Transfer reference first.' : '';
  const record = () => run(async () => {
    const r = await offersDo<{ shares?: Array<{ role: string; amount_cents: number }> }>('record_booking_payment', { booking, covers: 'tip', method: f.method, amount_cents: amount, reference: f.reference, received_on: f.received_on });
    setMsg({ ok: r.ok, text: r.ok ? `Tip of ${fmt(amount ?? 0)} recorded. Thank you to the team!` : r.message });
    if (r.ok) { setOpen(false); setF({ ...f, amount: '', reference: '' }); router.refresh(); }
  });
  const split = (tip: TipRow, staffId: string | null, name: string) => run(async () => {
    const r = await offersDo('tip_split_set', { tip: tip.id, reason: `All to ${name} (Admin)`, shares: [{ staff_id: staffId, amount_cents: tip.amount_cents }] });
    setMsg({ ok: r.ok, text: r.ok ? 'Split changed.' : r.message });
    if (r.ok) router.refresh();
  });
  const reset = (tip: TipRow) => run(async () => {
    const r = await offersDo('tip_split_set', { tip: tip.id, reset: true });
    setMsg({ ok: r.ok, text: r.ok ? 'Back to the usual split.' : r.message });
    if (r.ok) router.refresh();
  });
  return (
    <section className="pt-card ad-card stack" aria-labelledby="bm-tips-h" data-testid="bm-tips">
      <div className="pt-card__head"><h2 className="d4" id="bm-tips-h">Tips</h2><span className="small muted">{paid.length ? `${fmt(total)} in all` : 'None yet'}</span></div>
      <p className="small muted">A tip goes half to the salesperson and half to the staff member at the handover (CarmaCars keeps the half with no staff member; one person who did both gets it all). It is never part of the rental or the owner&apos;s share.</p>
      {tips.length > 0 && <ul className="stack" data-testid="bm-tips-list">{tips.map((t) => (
        <li key={t.id} className="small">
          <b>{fmt(t.amount_cents)}</b> by {METHOD[t.method] ?? t.method}{t.paid_at ? `, ${when(t.paid_at)}` : ''}{t.reference ? ` (${t.reference})` : ''}{t.status === 'voided' ? ': voided' : ''}
          {t.status === 'paid' && <>: {tipShareWords(t.shares ?? [], fmt)}{t.split_by_admin ? ' (split by an Admin)' : ''}</>}
          {isAdmin && t.status === 'paid' && <span className="ad-actions">
            {(t.shares ?? []).filter((s) => s.staff_id).map((s) => <button key={s.staff_id} className="btn btn--quiet btn--sm" type="button" disabled={pending} onClick={() => split(t, s.staff_id, s.name)}>All to {s.name}</button>)}
            <button className="btn btn--quiet btn--sm" type="button" disabled={pending} onClick={() => split(t, null, 'CarmaCars')}>All to CarmaCars</button>
            {t.split_by_admin && <button className="btn btn--quiet btn--sm" type="button" disabled={pending} onClick={() => reset(t)}>Back to the usual split</button>}
          </span>}
        </li>))}</ul>}
      {mayRecord && canTip && <div className="ad-actions"><button className="btn btn--ghost btn--sm" type="button" aria-expanded={open} onClick={() => setOpen(!open)} data-testid="bm-tip-open">Record a tip</button></div>}
      {open && (
        <form className="ad-form ad-form--narrow" aria-label="Record a tip" data-testid="bm-tip-form" onSubmit={(e) => { e.preventDefault(); if (!why) record(); }}>
          <div className="ad-fields">
            <div className="field ad-field"><label className="label" htmlFor="bm-tmethod">Paid by</label>
              <select className="select" id="bm-tmethod" value={f.method} onChange={(e) => setF({ ...f, method: e.target.value })} data-testid="bm-tmethod"><option value="cash">Cash</option><option value="e_transfer">e-Transfer</option></select></div>
            <div className="field ad-field"><label className="label" htmlFor="bm-tamount">Amount ($)</label><input className="input" id="bm-tamount" inputMode="decimal" value={f.amount} onChange={(e) => setF({ ...f, amount: e.target.value })} data-testid="bm-tamount" /></div>
            <div className="field ad-field"><label className="label" htmlFor="bm-tref">Reference{f.method === 'e_transfer' ? '' : ' (optional)'}</label><input className="input" id="bm-tref" value={f.reference} onChange={(e) => setF({ ...f, reference: e.target.value })} data-testid="bm-tref" /></div>
            <div className="field ad-field"><label className="label" htmlFor="bm-ton">Received on</label><DateInput className="input" id="bm-ton" type="date" value={f.received_on} max={today()} onChange={(e) => setF({ ...f, received_on: e.target.value })} /></div>
          </div>
          <button className="btn btn--primary btn--sm" type="submit" disabled={pending || !!why} aria-describedby={why ? 'bm-tip-why' : undefined} data-testid="bm-tip-go">{pending ? 'Working' : 'Record the tip'}</button>
          {why && <p className="hint" id="bm-tip-why" data-testid="bm-tip-why">{why}</p>}
        </form>)}
      {msg && <p className={`alert ${msg.ok ? 'alert--ok' : 'alert--error'}`} role={msg.ok ? 'status' : 'alert'} data-testid="bm-tip-msg"><span>{msg.text}</span></p>}
    </section>
  );
}
