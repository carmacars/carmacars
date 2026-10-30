'use client';
import { useEffect, useState, useTransition } from 'react';
import { useRouter } from 'next/navigation';
import { money } from '@/lib/format';
import { allowOtherCard, cancelOnReader, lookupStripePayment, pollReader, recordCardPayment, startOnReader, type ReaderState } from '@/server/actions/card-tools';

// The card tools of a booking's money (Release 21): Record card payment (a card taken in the Stripe Dashboard or on a
// reader, 0201), Charge on reader and Hold deposit on reader (the Stripe Terminal S700, 0202), and the same-card rule of
// a card-coverage rental with an Admin's override (0203). The database refuses with the reason, shown as written.
export interface CardRule { required: boolean; overridden?: boolean; override_reason?: string | null; brand?: string | null; last4?: string | null }
export interface CardToolsProps {
  booking: string; parts: Array<{ covers: string; open_cents: number }>; deposit_cents: number; depositTaken: boolean;
  rule: CardRule | null; readers: Array<{ id: string; label: string }>; isAdmin: boolean; mayRecord: boolean; mayCollect: boolean;
}
const fmt = (c: number | null | undefined) => money(Number(c ?? 0), { cents: true });
const cents = (s: string) => { const t = s.replace(/[$,\s]/g, ''); return t ? Math.round(Number(t) * 100) : null; };
const today = () => new Intl.DateTimeFormat('en-CA', { timeZone: 'America/Toronto', year: 'numeric', month: '2-digit', day: '2-digit' }).format(new Date());
const cardWords = (r: CardRule | null) => (r?.last4 ? `${(r.brand ?? 'card').replace(/^\w/, (c) => c.toUpperCase())} ending ${r.last4}` : 'the coverage card');

export function CardTools(x: CardToolsProps) {
  const router = useRouter();
  const [open, setOpen] = useState<'' | 'card' | 'reader' | 'override'>('');
  const [msg, setMsg] = useState<{ ok: boolean; text: string } | null>(null);
  const [pending, run] = useTransition();
  const openRental = x.parts.filter((p) => p.covers !== 'later').reduce((t, p) => t + Math.max(p.open_cents, 0), 0);
  const [rec, setRec] = useState({ covers: openRental > 0 ? 'both' : 'later', amount: '', last4: '', brand: '', source: 'dashboard', stripe_id: '', received_on: today(), note: '', same_card: false });
  const [found, setFound] = useState<string | null>(null);
  const [rdr, setRdr] = useState({ kind: 'charge' as 'charge' | 'hold', covers: openRental > 0 ? 'balance' : 'later', amount: '', reason: '', reader: x.readers[0]?.id ?? '' });
  const [live, setLive] = useState<ReaderState | null>(null);
  const [why, setWhy] = useState('');
  const rule = x.rule?.required ? x.rule : null;
  const ruleApplies = (covers: string) => !!rule && !rule.overridden && ['rental', 'fees', 'both', 'balance'].includes(covers);
  const done = (ok: boolean, text: string) => { setMsg({ ok, text }); if (ok) { setOpen(''); router.refresh(); } };

  // the reader: asked again every 2 seconds until the card is read, refused or cancelled
  useEffect(() => {
    if (!live || live.state !== 'waiting') return;
    const t = setTimeout(async () => {
      const r = await pollReader({ id: live.id, booking: x.booking });
      if (!r.ok) { setMsg({ ok: false, text: r.message }); setLive(null); return; }
      setLive(r.data);
      if (r.data.state === 'done') done(true, r.data.kind === 'hold' ? `Deposit of ${fmt(r.data.amount_cents)} held on the card.` : `${fmt(r.data.amount_cents)} paid on the reader.`);
      if (r.data.state === 'failed') setMsg({ ok: false, text: r.data.message ?? 'Not paid.' });
    }, 2000);
    return () => clearTimeout(t);
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [live]);

  if (!x.mayRecord && !x.mayCollect && !rule) return null;
  return (
    <div className="stack" data-testid="card-tools">
      {rule && <p className={`alert ${rule.overridden ? 'alert--info' : 'alert--warn'}`} role="status" data-testid="card-rule"><span>
        {rule.overridden ? <>Another card or method is allowed for this rental: {rule.override_reason}</>
          : <>Credit card coverage: the whole rental is paid on {cardWords(rule)}. Another card or method is refused.</>}
        {x.isAdmin && !rule.overridden && <> <button className="btn btn--quiet btn--sm" type="button" onClick={() => setOpen(open === 'override' ? '' : 'override')} data-testid="card-rule-override">Allow another card</button></>}
      </span></p>}
      <div className="row">
        {x.mayRecord && <button className="btn btn--ghost btn--sm" type="button" aria-expanded={open === 'card'} onClick={() => setOpen(open === 'card' ? '' : 'card')} data-testid="ct-record-open">Record card payment</button>}
        {x.mayCollect && x.readers.length > 0 && <button className="btn btn--ghost btn--sm" type="button" aria-expanded={open === 'reader' && rdr.kind === 'charge'} onClick={() => { setRdr({ ...rdr, kind: 'charge' }); setOpen(open === 'reader' && rdr.kind === 'charge' ? '' : 'reader'); }} data-testid="ct-reader-charge-open">Charge on reader</button>}
        {x.mayCollect && x.readers.length > 0 && x.deposit_cents > 0 && !x.depositTaken && <button className="btn btn--ghost btn--sm" type="button" aria-expanded={open === 'reader' && rdr.kind === 'hold'} onClick={() => { setRdr({ ...rdr, kind: 'hold' }); setOpen(open === 'reader' && rdr.kind === 'hold' ? '' : 'reader'); }} data-testid="ct-reader-hold-open">Hold deposit on reader</button>}
      </div>

      {open === 'override' && (
        <form className="ad-form ad-form--narrow" aria-label="Allow another card" data-testid="ct-override" onSubmit={(e) => { e.preventDefault(); run(async () => { const r = await allowOtherCard({ booking: x.booking, reason: why }); done(r.ok, r.ok ? 'Another card or method is allowed for this rental.' : r.message); }); }}>
          <div className="field ad-field ad-field--wide"><label className="label" htmlFor="ct-why">Reason (10 characters or more, kept on the booking)</label><input className="input" id="ct-why" value={why} onChange={(e) => setWhy(e.target.value)} data-testid="ct-why" /></div>
          <button className="btn btn--primary btn--sm" type="submit" disabled={pending}>Allow</button>
        </form>)}

      {open === 'card' && (
        <form className="ad-form ad-form--narrow" aria-label="Record card payment" data-testid="ct-record" onSubmit={(e) => { e.preventDefault(); run(async () => {
          const r = await recordCardPayment({ booking: x.booking, covers: rec.covers, amount_cents: cents(rec.amount), last4: rec.last4, brand: rec.brand, source: rec.source,
            stripe_id: rec.stripe_id || null, received_on: rec.received_on, note: rec.note, same_card: rec.same_card });
          done(r.ok, r.ok ? (r.data.held ? 'Deposit hold recorded: it is held on the card.' : `Recorded.${r.data.confirmed ? ' The booking is confirmed.' : ''}`) : r.message);
        }); }}>
          <p className="small muted">A card taken in the Stripe Dashboard or on a card reader, outside this site. A deposit hold needs its Stripe payment id, so it can be captured or released from Settle the deposit.</p>
          <div className="ad-fields">
            <div className="field ad-field"><label className="label" htmlFor="ct-covers">For</label>
              <select className="select" id="ct-covers" value={rec.covers} onChange={(e) => setRec({ ...rec, covers: e.target.value })} data-testid="ct-covers">
                <option value="both">Rental and fees</option><option value="rental">Rental</option><option value="fees">Fees</option><option value="later">Later charges</option><option value="deposit">Deposit hold</option></select></div>
            <div className="field ad-field"><label className="label" htmlFor="ct-source">Taken</label>
              <select className="select" id="ct-source" value={rec.source} onChange={(e) => setRec({ ...rec, source: e.target.value })} data-testid="ct-source">
                <option value="dashboard">In the Stripe Dashboard</option><option value="reader">On a card reader</option></select></div>
            <div className="field ad-field"><label className="label" htmlFor="ct-last4">Last 4 digits</label><input className="input" id="ct-last4" inputMode="numeric" maxLength={4} value={rec.last4} onChange={(e) => setRec({ ...rec, last4: e.target.value.replace(/\D/g, '') })} data-testid="ct-last4" /></div>
            <div className="field ad-field"><label className="label" htmlFor="ct-amount">Amount ($)</label><input className="input" id="ct-amount" inputMode="decimal" value={rec.amount} onChange={(e) => setRec({ ...rec, amount: e.target.value })} placeholder={rec.covers === 'deposit' ? (x.deposit_cents / 100).toFixed(2) : ''} data-testid="ct-amount" /></div>
            <div className="field ad-field ad-field--wide"><label className="label" htmlFor="ct-sid">Stripe payment id (optional for a payment, pi_ or ch_)</label>
              <span className="row"><input className="input" id="ct-sid" value={rec.stripe_id} onChange={(e) => { setRec({ ...rec, stripe_id: e.target.value.trim() }); setFound(null); }} placeholder="pi_..." data-testid="ct-sid" />
                <button className="btn btn--quiet btn--sm" type="button" disabled={pending || !rec.stripe_id} data-testid="ct-lookup" onClick={() => run(async () => {
                  const r = await lookupStripePayment({ booking: x.booking, id: rec.stripe_id });
                  if (!r.ok) { setFound(null); setMsg({ ok: false, text: r.message }); return; }
                  const v = r.data;
                  setFound(`Stripe: ${v.status === 'requires_capture' ? `a hold of ${fmt(v.capturable_cents)}` : `${fmt(v.amount_cents)} ${v.status === 'succeeded' ? 'paid' : v.status.replace(/_/g, ' ')}`}${v.last4 ? ` on ${v.brand ?? 'card'} ending ${v.last4}` : ''}.`);
                  setRec((s) => ({ ...s, last4: s.last4 || (v.last4 ?? ''), brand: v.brand ?? s.brand, amount: s.amount || ((v.status === 'requires_capture' ? v.capturable_cents : v.amount_cents) / 100).toFixed(2) }));
                })}>Look up</button></span>
              {found && <span className="small" data-testid="ct-found">{found}</span>}</div>
            {rec.covers !== 'deposit' && <div className="field ad-field"><label className="label" htmlFor="ct-on">Paid on</label><input className="input" id="ct-on" type="date" value={rec.received_on} max={today()} onChange={(e) => setRec({ ...rec, received_on: e.target.value })} /></div>}
            <div className="field ad-field ad-field--wide"><label className="label" htmlFor="ct-note">Note (optional)</label><input className="input" id="ct-note" value={rec.note} onChange={(e) => setRec({ ...rec, note: e.target.value })} /></div>
          </div>
          {ruleApplies(rec.covers) && <label className="check" htmlFor="ct-same"><input type="checkbox" id="ct-same" checked={rec.same_card} onChange={(e) => setRec({ ...rec, same_card: e.target.checked })} data-testid="ct-same" /> <span>This is the same card as the coverage card ({cardWords(rule)})</span></label>}
          <button className="btn btn--primary btn--sm" type="submit" disabled={pending} data-testid="ct-record-save">{pending ? 'Saving' : 'Record it'}</button>
        </form>)}

      {open === 'reader' && !live && (
        <form className="ad-form ad-form--narrow" aria-label={rdr.kind === 'hold' ? 'Hold deposit on reader' : 'Charge on reader'} data-testid="ct-reader" onSubmit={(e) => { e.preventDefault(); setMsg(null); run(async () => {
          const r = await startOnReader({ booking: x.booking, kind: rdr.kind, covers: rdr.kind === 'hold' ? 'deposit' : rdr.covers, amount_cents: rdr.kind === 'hold' ? null : cents(rdr.amount), reason: rdr.reason, reader: rdr.reader || null });
          if (!r.ok) { setMsg({ ok: false, text: r.message }); return; }
          setLive(r.data);
        }); }}>
          <div className="ad-fields">
            {x.readers.length > 1 && <div className="field ad-field"><label className="label" htmlFor="ct-rdr">Reader</label>
              <select className="select" id="ct-rdr" value={rdr.reader} onChange={(e) => setRdr({ ...rdr, reader: e.target.value })}>{x.readers.map((r) => <option key={r.id} value={r.id}>{r.label}</option>)}</select></div>}
            {rdr.kind === 'charge' ? <>
              <div className="field ad-field"><label className="label" htmlFor="ct-rcovers">For</label>
                <select className="select" id="ct-rcovers" value={rdr.covers} onChange={(e) => setRdr({ ...rdr, covers: e.target.value })} data-testid="ct-rcovers">
                  <option value="balance">Everything open ({fmt(x.parts.reduce((t, p) => t + Math.max(p.open_cents, 0), 0))})</option><option value="rental">Rental</option><option value="fees">Fees</option><option value="later">A later charge</option></select></div>
              <div className="field ad-field"><label className="label" htmlFor="ct-ramount">Amount ($)</label><input className="input" id="ct-ramount" inputMode="decimal" value={rdr.amount} onChange={(e) => setRdr({ ...rdr, amount: e.target.value })} data-testid="ct-ramount" /></div>
              {rdr.covers === 'later' && <div className="field ad-field ad-field--wide"><label className="label" htmlFor="ct-rreason">Reason (on the renter&apos;s receipt)</label><input className="input" id="ct-rreason" value={rdr.reason} onChange={(e) => setRdr({ ...rdr, reason: e.target.value })} placeholder="Fuel, extra km, late return" /></div>}
            </> : <p className="small">The deposit of {fmt(x.deposit_cents)} is held on the card (not charged). A hold on a reader lapses after 2 days: settle it, or it is collected before it lapses once the car is out.</p>}
          </div>
          {rdr.kind === 'charge' && ruleApplies(rdr.covers) && <p className="small">The reader checks it is {cardWords(rule)} before the money is taken.</p>}
          <button className="btn btn--primary btn--sm" type="submit" disabled={pending} data-testid="ct-reader-go">{pending ? 'Sending to the reader' : 'Send to the reader'}</button>
        </form>)}

      {live && live.state === 'waiting' && <p className="alert alert--info" role="status" data-testid="ct-reader-waiting"><span>{fmt(live.amount_cents)} is on {live.reader_label ?? 'the reader'}: the renter taps, inserts or swipes the card.{' '}
        <button className="btn btn--quiet btn--sm" type="button" disabled={pending} onClick={() => run(async () => { const r = await cancelOnReader({ id: live.id, booking: x.booking }); setLive(null); setMsg({ ok: r.ok, text: r.ok ? 'Cancelled: nothing was charged.' : r.message }); })} data-testid="ct-reader-cancel">Cancel</button></span></p>}
      {live && live.state !== 'waiting' && <button className="btn btn--quiet btn--sm" type="button" onClick={() => setLive(null)}>Done</button>}
      {msg && <p className={`alert ${msg.ok ? 'alert--ok' : 'alert--error'}`} role={msg.ok ? 'status' : 'alert'} data-testid="ct-message"><span>{msg.text}</span></p>}
    </div>
  );
}
