'use client';
import { useState, useTransition } from 'react';
import { useRouter } from 'next/navigation';
import { money } from '@/lib/format';
import { when } from '@/features/agreement/model';
import { chargeSavedCard, holdAction, offersDo, startCardRequest } from '@/server/actions/offers';
import { Table } from '@/features/admin/ui';

// The money of a booking by part (migration 0129): what is open for the rental, the fees and later charges; the deposit
// and how it was taken; the card on file. Record a payment received another way (e-Transfer, cash, cheque, bank
// transfer, platform payout, the insurer) against the part it covers; collect a card through Stripe (on this device
// handed to the renter, or by a link texted or emailed); place or settle a deposit hold; charge the saved card; give
// back a deposit taken in cash or by e-Transfer; confirm a booking paid another way. The database decides who may do each.
export interface Money {
  booking_id: string; booking_number: string; status: string; rental_pay_method: string; deposit_pay_method: string; agreement_on_paper: boolean;
  parts: Array<{ covers: 'rental' | 'fees' | 'later'; open_cents: number }>; due_cents: number; deposit_cents: number;
  deposit: { method: string; paid_method: string | null; status: string; amount_cents: number; captured_cents: number; released_cents: number; hold_expires_at: string | null; hold_days_left: number | null } | null;
  card: { brand: string; last4: string; exp_month: number; exp_year: number } | null;
  payments: Array<{ id: string; created_at: string; processed_at: string | null; purpose: string; kind: string; method: string; amount_cents: number; status: string; card_last4: string | null; card_brand: string | null;
    covers: string | null; reference: string | null; note: string | null; manual_id: string | null; voided: boolean; by: string | null }>;
  requests: Array<{ id: string; kind: string; covers: string; amount_cents: number; channel: string; status: string; created_at: string; expires_at: string; last_error: string | null }>;
  e_transfer_email: string | null; moto: boolean;
  may: { record: boolean; collect: boolean; charge: boolean; hold: boolean; confirm: boolean; return_deposit: boolean };
  can_confirm: boolean;
}
const fmt = (c: number | null | undefined) => money(Number(c ?? 0), { cents: true });
const PART: Record<string, string> = { rental: 'Rental', fees: 'Fees', later: 'Later charges', deposit: 'Deposit', card: 'Card on file', balance: 'Everything open' };
// what each payment was for and where it stands, in words (sim item 7: no raw codes)
const PURPOSE: Record<string, string> = { booking_total: 'Rental and fees', deposit: 'Deposit', extension: 'Extension', change: 'Booking change', later_charge: 'Later charge', damage: 'Damage', addon: 'Add-on', balance: 'Balance' };
const STATUS: Record<string, string> = { succeeded: 'Received', pending: 'Pending', failed: 'Failed', refunded: 'Refunded', partially_refunded: 'Partly refunded', cancelled: 'Cancelled', requires_action: 'Waiting for the renter', processing: 'Processing', disputed: 'Disputed' };
const KIND: Record<string, string> = { refund: 'given back', hold: 'hold', capture: 'captured from the hold', release: 'hold released' };
const words = (m: Record<string, string>, v: unknown) => m[String(v ?? '')] ?? String(v ?? '').replace(/_/g, ' ');
const METHOD: Record<string, string> = { card: 'Card', e_transfer: 'e-Transfer', cash: 'Cash', cheque: 'Cheque', bank_transfer: 'Bank transfer', platform_payout: 'Platform payout', insurer: 'Insurer', other: 'Another way', none: 'None' };
const cents = (s: string) => { const t = s.replace(/[$,\s]/g, ''); return t ? Math.round(Number(t) * 100) : null; };
const today = () => new Intl.DateTimeFormat('en-CA', { timeZone: 'America/Toronto', year: 'numeric', month: '2-digit', day: '2-digit' }).format(new Date());

export function BookingMoney({ m }: { m: Money }) {
  const router = useRouter();
  const [open, setOpen] = useState<'' | 'record' | 'collect' | 'charge' | 'capture' | 'release'>('');
  const [msg, setMsg] = useState<{ ok: boolean; text: string } | null>(null);
  const [pending, run] = useTransition();
  const [rec, setRec] = useState({ covers: (m.parts.some((p) => p.covers !== 'later' && p.open_cents > 0) ? 'both' : m.parts.find((p) => p.open_cents > 0)?.covers ?? (m.deposit ? 'later' : 'deposit')) as string, method: m.rental_pay_method !== 'card' ? m.rental_pay_method : 'e_transfer', amount: '', reference: '', received_on: today(), note: '' });
  // a card payment covers everything open by default (sim item 7: a link for the rental alone left the fees open)
  const [col, setCol] = useState({ kind: 'charge' as 'charge' | 'hold' | 'setup', covers: (m.parts.filter((p) => p.covers !== 'later' && p.open_cents > 0).length ? 'balance' : 'later') as string, amount: '', reason: '', channel: 'device' as 'device' | 'text' | 'email' });
  const [chg, setChg] = useState({ amount: '', reason: '', covers: 'later' as 'later' | 'deposit' });
  const [cap, setCap] = useState({ amount: '', reason: '' });
  const [rel, setRel] = useState('');
  const [ret, setRet] = useState<Record<string, string>>({});
  const done = (ok: boolean, text: string) => { setMsg({ ok, text }); if (ok) { setOpen(''); router.refresh(); } };
  const offlineReturns = m.payments.filter((p) => p.purpose === 'deposit' && p.kind === 'refund' && p.status === 'pending' && ['cash', 'e_transfer'].includes(p.method));
  const openPart = (c: string) => (c === 'balance' ? m.parts.reduce((t, p) => t + Math.max(p.open_cents, 0), 0) : m.parts.find((p) => p.covers === c)?.open_cents ?? 0);
  const dep = m.deposit;
  const depWords = !dep || ['pending', 'failed'].includes(dep.status) ? (m.deposit_cents > 0 ? `${fmt(m.deposit_cents)} to take (${(METHOD[m.deposit_pay_method] ?? m.deposit_pay_method).toLowerCase()})` : 'No deposit')
    : dep.method === 'card_hold' && dep.status === 'held' ? `${fmt(dep.amount_cents)} held on the card${dep.hold_days_left !== null ? `, about ${dep.hold_days_left} day${dep.hold_days_left === 1 ? '' : 's'} left (collected by itself before it lapses once the car is out)` : ''}`
    : dep.method === 'offline' ? `${fmt(dep.amount_cents)} taken by ${(METHOD[dep.paid_method ?? ''] ?? '').toLowerCase()}, ${dep.status}`
    : `${fmt(dep.amount_cents)}, ${dep.status.replace(/_/g, ' ')}`;

  const print = (p: Money['payments'][number]) => {
    const w = window.open('', '_blank', 'width=480,height=640');
    if (!w) return;
    const esc = (s: string) => s.replace(/[&<>"]/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;' }[c]!));
    w.document.write(`<!doctype html><meta charset="utf-8"><title>Receipt ${esc(m.booking_number)}</title><body style="font:14px/1.5 system-ui;padding:24px"><h1 style="font-size:18px">CarmaCars receipt</h1>
      <p>Booking ${esc(m.booking_number)}<br>${esc(new Date(p.processed_at ?? p.created_at).toLocaleString('en-CA', { timeZone: 'America/Toronto' }))}</p>
      <p><b>${p.kind === 'refund' ? 'Given back' : 'Received'}: ${esc(fmt(p.amount_cents))}</b><br>For: ${esc(PART[p.covers ?? ''] ?? p.purpose)}<br>By: ${esc(METHOD[p.method] ?? p.method)}${p.reference ? `<br>Reference: ${esc(p.reference)}` : ''}${p.by ? `<br>Recorded by: ${esc(p.by)}` : ''}</p>
      <p>Receipt R-${esc(p.id.slice(0, 8).toUpperCase())}</p><p style="margin-top:48px">Signature: ____________________</p><script>print()</script></body>`);
    w.document.close();
  };

  return (
    <section className="pt-card ad-card stack" aria-labelledby="bm-h" data-testid="booking-money">
      <div className="pt-card__head"><h2 className="d4" id="bm-h">Money by part</h2>
        <span className="small muted">Rental paid by {(METHOD[m.rental_pay_method] ?? m.rental_pay_method).toLowerCase()} · deposit by {(METHOD[m.deposit_pay_method] ?? m.deposit_pay_method).toLowerCase()}</span></div>
      <dl className="pt-dl pt-dl--money" data-testid="bm-parts">
        {m.parts.map((p) => <div key={p.covers}><dt>{PART[p.covers]} still open</dt><dd>{fmt(p.open_cents)}</dd></div>)}
        <div><dt>Deposit</dt><dd data-testid="bm-deposit">{depWords}</dd></div>
        <div><dt>Card on file</dt><dd>{m.card ? `${m.card.brand} ending ${m.card.last4}` : 'None'}</dd></div>
      </dl>
      {m.can_confirm && m.may.confirm && <p className="alert alert--warn" role="status"><span>Approved by the renter, paid by {(METHOD[m.rental_pay_method] ?? '').toLowerCase()}. Record the payment, then confirm. {' '}
        <button className="btn btn--primary btn--sm" type="button" disabled={pending} data-testid="bm-confirm" onClick={() => run(async () => { const r = await offersDo('confirm_offline_booking', { booking: m.booking_number }); done(r.ok, r.ok ? 'Confirmed and on the calendar.' : r.message); })}>Confirm the booking</button></span></p>}
      {m.rental_pay_method === 'e_transfer' && m.e_transfer_email && ['offered', 'pending_payment'].includes(m.status) && <p className="small">The renter sends the e-Transfer to <b>{m.e_transfer_email}</b> with the booking number as the message.</p>}

      <div className="ad-actions">
        {m.may.record && <button className="btn btn--ghost btn--sm" type="button" aria-expanded={open === 'record'} onClick={() => setOpen(open === 'record' ? '' : 'record')} data-testid="bm-record-open">Record a payment</button>}
        {m.may.collect && <button className="btn btn--ghost btn--sm" type="button" aria-expanded={open === 'collect'} onClick={() => setOpen(open === 'collect' ? '' : 'collect')} data-testid="bm-collect-open">Collect a card</button>}
        {m.may.charge && m.card && <button className="btn btn--ghost btn--sm" type="button" aria-expanded={open === 'charge'} onClick={() => setOpen(open === 'charge' ? '' : 'charge')} data-testid="bm-charge-open">Charge the saved card</button>}
        {m.may.hold && dep?.method === 'card_hold' && dep.status === 'held' && <>
          <button className="btn btn--ghost btn--sm" type="button" aria-expanded={open === 'capture'} onClick={() => setOpen(open === 'capture' ? '' : 'capture')} data-testid="bm-capture-open">Capture the hold</button>
          <button className="btn btn--ghost btn--sm" type="button" aria-expanded={open === 'release'} data-testid="bm-release" onClick={() => setOpen(open === 'release' ? '' : 'release')}>Release the hold</button></>}
      </div>

      {open === 'record' && (
        <form className="ad-form ad-form--narrow" aria-label="Record a payment" data-testid="bm-record" onSubmit={(e) => { e.preventDefault(); run(async () => {
          // 0132: one payment for the rental and the fees together: the rental first, the rest for the fees (two records)
          const both = rec.covers === 'both';
          const typed = cents(rec.amount);
          if (rec.covers !== 'deposit' && rec.covers !== 'later' && typed === null && (both ? openPart('rental') + openPart('fees') : openPart(rec.covers)) <= 0) { done(false, 'Nothing is open for that part: type the amount, or choose A later charge.'); return; }
          const amount = cents(rec.amount) ?? (both ? openPart('rental') + openPart('fees') : null);
          const first = both ? Math.min(amount ?? 0, openPart('rental')) : amount;
          const firstCovers = both ? (openPart('rental') > 0 ? 'rental' : 'fees') : rec.covers;
          let r = await offersDo<{ confirmed?: boolean; confirm?: { reason?: string } }>('record_booking_payment', { booking: m.booking_number, covers: firstCovers, method: rec.method, amount_cents: both && firstCovers === 'fees' ? amount : first, reference: rec.reference, received_on: rec.received_on, note: rec.note });
          if (r.ok && both && firstCovers === 'rental' && amount !== null && first !== null && amount > first) {
            r = await offersDo('record_booking_payment', { booking: m.booking_number, covers: 'fees', method: rec.method, amount_cents: amount - first, reference: rec.reference ? `${rec.reference} (part 2)` : '', received_on: rec.received_on, note: rec.note || 'The rest of the same payment, for the fees' });
          }
          done(r.ok, r.ok ? `Recorded.${r.data.confirmed ? ' The booking is confirmed.' : r.data.confirm?.reason ? ` Not confirmed yet: ${r.data.confirm.reason}.` : ''}` : r.message);
        }); }}>
          <div className="ad-fields">
            <div className="field ad-field"><label className="label" htmlFor="bm-covers">For</label>
              <select className="select" id="bm-covers" value={rec.covers} onChange={(e) => setRec({ ...rec, covers: e.target.value as typeof rec.covers, method: e.target.value === 'deposit' && !['cash', 'e_transfer'].includes(rec.method) ? 'cash' : rec.method })} data-testid="bm-covers">
                <option value="both">The rental and fees ({fmt(openPart('rental') + openPart('fees'))} open)</option>
                <option value="rental">The rental only ({fmt(openPart('rental'))} open)</option><option value="fees">Fees only ({fmt(openPart('fees'))} open)</option>
                <option value="deposit">The deposit ({fmt(m.deposit_cents)})</option><option value="later">A later charge ({fmt(openPart('later'))} open)</option></select></div>
            <div className="field ad-field"><label className="label" htmlFor="bm-method">Paid by</label>
              <select className="select" id="bm-method" value={rec.method} onChange={(e) => setRec({ ...rec, method: e.target.value })} data-testid="bm-method">
                {(rec.covers === 'deposit' ? ['cash', 'e_transfer'] : ['e_transfer', 'cash', 'cheque', 'bank_transfer', 'platform_payout', 'insurer', 'other']).map((x) => <option key={x} value={x}>{METHOD[x]}</option>)}</select></div>
            <div className="field ad-field"><label className="label" htmlFor="bm-amount">Amount ($)</label>
              <input className="input" id="bm-amount" inputMode="decimal" value={rec.amount} onChange={(e) => setRec({ ...rec, amount: e.target.value })} placeholder={(((rec.covers === 'deposit' ? m.deposit_cents : rec.covers === 'both' ? openPart('rental') + openPart('fees') : openPart(rec.covers)) ?? 0) / 100).toFixed(2)} aria-describedby="bm-amount-h" data-testid="bm-amount" />
              <p className="hint" id="bm-amount-h">Empty: what is open for it</p></div>
            <div className="field ad-field"><label className="label" htmlFor="bm-ref">Reference{['e_transfer', 'cheque', 'bank_transfer'].includes(rec.method) ? '' : ' (optional)'}</label>
              <input className="input" id="bm-ref" value={rec.reference} onChange={(e) => setRec({ ...rec, reference: e.target.value })} data-testid="bm-ref" /></div>
            <div className="field ad-field"><label className="label" htmlFor="bm-on">Received on</label><input className="input" id="bm-on" type="date" value={rec.received_on} max={today()} onChange={(e) => setRec({ ...rec, received_on: e.target.value })} /></div>
            <div className="field ad-field"><label className="label" htmlFor="bm-note">Note{rec.method === 'other' ? '' : ' (optional)'}</label><input className="input" id="bm-note" value={rec.note} onChange={(e) => setRec({ ...rec, note: e.target.value })} /></div>
          </div>
          <button className="btn btn--primary btn--sm" type="submit" disabled={pending} data-testid="bm-record-save">{pending ? 'Saving' : 'Record it'}</button>
        </form>)}

      {open === 'collect' && (
        <form className="ad-form ad-form--narrow" aria-label="Collect a card" data-testid="bm-collect" onSubmit={(e) => { e.preventDefault(); run(async () => {
          const r = await startCardRequest({ booking: m.booking_number, kind: col.kind, covers: col.kind === 'charge' ? col.covers : undefined, amount_cents: col.kind === 'charge' ? cents(col.amount) : null, reason: col.reason, channel: col.channel });
          if (!r.ok) { done(false, r.message); return; }
          if (col.channel === 'device') { router.push(r.data.url); return; }
          done(!!r.data.sent?.ok, r.data.sent?.ok ? `Link sent${r.data.sent.to ? ` to ${r.data.sent.to}` : ''}. It works for 3 days.` : `Not sent: ${r.data.sent?.reason ?? 'no answer'}`);
        }); }}>
          <div className="ad-fields">
            <div className="field ad-field"><label className="label" htmlFor="bm-kind">What</label>
              <select className="select" id="bm-kind" value={col.kind} onChange={(e) => setCol({ ...col, kind: e.target.value as typeof col.kind })} data-testid="bm-kind">
                <option value="charge">A payment</option><option value="hold">The deposit hold ({fmt(m.deposit_cents)})</option><option value="setup">Save the card (no charge)</option></select></div>
            {col.kind === 'charge' && <>
              <div className="field ad-field"><label className="label" htmlFor="bm-ccovers">For</label>
                <select className="select" id="bm-ccovers" value={col.covers} onChange={(e) => setCol({ ...col, covers: e.target.value as typeof col.covers })}>
                  {openPart('balance') > 0 && <option value="balance">Everything open ({fmt(openPart('balance'))})</option>}
                  {openPart('rental') > 0 && <option value="rental">The rental only ({fmt(openPart('rental'))})</option>}{openPart('fees') > 0 && <option value="fees">Fees only ({fmt(openPart('fees'))})</option>}<option value="later">A later charge</option></select></div>
              <div className="field ad-field"><label className="label" htmlFor="bm-camount">Amount ($)</label><input className="input" id="bm-camount" inputMode="decimal" value={col.amount} onChange={(e) => setCol({ ...col, amount: e.target.value })} placeholder={(openPart(col.covers) / 100).toFixed(2)} data-testid="bm-camount" /></div>
              <div className="field ad-field"><label className="label" htmlFor="bm-creason">Reason{col.covers === 'later' ? '' : ' (optional)'}</label><input className="input" id="bm-creason" value={col.reason} onChange={(e) => setCol({ ...col, reason: e.target.value })} placeholder="Fuel, extra km, late return" data-testid="bm-creason" /></div>
            </>}
            <div className="field ad-field ad-field--wide"><span className="label">The renter enters the card</span>
              {([['device', 'On this device: hand it to the renter'], ['text', 'By a link texted to their mobile'], ['email', 'By a link emailed to them']] as const).map(([v, x]) => (
                <label key={v} className="check" htmlFor={`bm-ch-${v}`}><input type="radio" id={`bm-ch-${v}`} name="bm-ch" checked={col.channel === v} onChange={() => setCol({ ...col, channel: v })} data-testid={`bm-ch-${v}`} /> <span>{x}</span></label>))}
              <p className="hint">{m.moto ? 'Typing a card the renter reads out (phone order) is on for this account: use On this device.' : 'Staff never type a card number: the renter types it in Stripe\'s form. (Phone orders need Stripe MOTO: Program settings.)'}</p></div>
          </div>
          <button className="btn btn--primary btn--sm" type="submit" disabled={pending} data-testid="bm-collect-go">{pending ? 'Working' : col.channel === 'device' ? 'Open the card form' : 'Send the link'}</button>
        </form>)}

      {open === 'charge' && (
        <form className="ad-form ad-form--narrow" aria-label="Charge the saved card" data-testid="bm-charge" onSubmit={(e) => { e.preventDefault(); run(async () => {
          const r = await chargeSavedCard({ booking: m.booking_number, amount_cents: cents(chg.amount), reason: chg.reason, covers: chg.covers });
          done(r.ok && r.data.ok, r.ok ? (r.data.ok ? 'Charged. The renter has the receipt by email.' : `Declined: ${r.data.message}`) : r.message);
        }); }}>
          <div className="ad-fields">
            <div className="field ad-field"><label className="label" htmlFor="bm-gcovers">For</label><select className="select" id="bm-gcovers" value={chg.covers} onChange={(e) => setChg({ ...chg, covers: e.target.value as typeof chg.covers })}>
              <option value="later">A later charge</option><option value="deposit">The deposit ({fmt(m.deposit_cents)}, charged and refunded after the return)</option></select></div>
            {chg.covers === 'later' && <div className="field ad-field"><label className="label" htmlFor="bm-gamount">Amount ($)</label><input className="input" id="bm-gamount" inputMode="decimal" value={chg.amount} onChange={(e) => setChg({ ...chg, amount: e.target.value })} data-testid="bm-gamount" /></div>}
            <div className="field ad-field ad-field--wide"><label className="label" htmlFor="bm-greason">Reason (on the renter&apos;s receipt)</label><input className="input" id="bm-greason" value={chg.reason} onChange={(e) => setChg({ ...chg, reason: e.target.value })} placeholder="Extra km, fuel, damage, late return" data-testid="bm-greason" /></div>
          </div>
          <p className="hint">The renter agreed to these charges in the rental agreement. The card on file: {m.card ? `${m.card.brand} ending ${m.card.last4}` : 'none'}.</p>
          <button className="btn btn--primary btn--sm" type="submit" disabled={pending} data-testid="bm-charge-go">{pending ? 'Charging' : 'Charge it'}</button>
        </form>)}

      {open === 'capture' && dep && (
        <form className="ad-form ad-form--narrow" aria-label="Capture the hold" data-testid="bm-capture" onSubmit={(e) => { e.preventDefault(); run(async () => {
          const r = await holdAction({ booking: m.booking_number, action: 'capture', amount_cents: cents(cap.amount), reason: cap.reason });
          done(r.ok && r.data.ok, r.ok ? (r.data.ok ? (cents(cap.amount) !== null && cents(cap.amount)! < dep.amount_cents ? 'Captured; the rest of the hold is released.' : 'Captured.') : r.data.message ?? 'Not captured.') : r.message);
        }); }}>
          <div className="ad-fields">
            <div className="field ad-field"><label className="label" htmlFor="bm-kamount">Amount ($, up to {fmt(dep.amount_cents)})</label><input className="input" id="bm-kamount" inputMode="decimal" value={cap.amount} onChange={(e) => setCap({ ...cap, amount: e.target.value })} placeholder={(dep.amount_cents / 100).toFixed(2)} /></div>
            <div className="field ad-field"><label className="label" htmlFor="bm-kreason">Reason</label><input className="input" id="bm-kreason" value={cap.reason} onChange={(e) => setCap({ ...cap, reason: e.target.value })} /></div>
          </div>
          <button className="btn btn--primary btn--sm" type="submit" disabled={pending}>Capture</button>
        </form>)}

      {open === 'release' && dep && (
        <form className="ad-form ad-form--narrow" aria-label="Release the hold" data-testid="bm-release-form" onSubmit={(e) => { e.preventDefault(); run(async () => {
          const r = await holdAction({ booking: m.booking_number, action: 'release', reason: rel });
          done(r.ok && r.data.ok, r.ok ? (r.data.ok ? 'Hold released.' : r.data.message ?? 'Not released.') : r.message);
        }); }}>
          <p className="small muted">The deposit stays held while the car is out, until tolls and tickets have had time to come in, and while anything is still open. Settle the deposit after the return instead; an Admin may release it now with the reason.</p>
          <div className="field ad-field ad-field--wide"><label className="label" htmlFor="bm-rreason">Reason (an Admin, 10 characters or more)</label><input className="input" id="bm-rreason" value={rel} onChange={(e) => setRel(e.target.value)} /></div>
          <button className="btn btn--primary btn--sm" type="submit" disabled={pending} data-testid="bm-release-go">Release</button>
        </form>)}

      {offlineReturns.length > 0 && m.may.return_deposit && <div className="stack" data-testid="bm-returns">
        {offlineReturns.map((p) => (
          <form key={p.id} className="row" onSubmit={(e) => { e.preventDefault(); run(async () => { const r = await offersDo('deposit_return_offline', { payment: p.id, reference: ret[p.id] ?? '' }); done(r.ok, r.ok ? 'Recorded as given back.' : r.message); }); }}>
            <span className="small"><b>Give back {fmt(p.amount_cents)} by {(METHOD[p.method] ?? '').toLowerCase()}</b></span>
            <label className="sr-only" htmlFor={`bm-ret-${p.id}`}>Reference</label>
            <input className="input" id={`bm-ret-${p.id}`} placeholder={p.method === 'e_transfer' ? 'e-Transfer reference' : 'Receipt number (optional)'} value={ret[p.id] ?? ''} onChange={(e) => setRet({ ...ret, [p.id]: e.target.value })} />
            <button className="btn btn--primary btn--sm" type="submit" disabled={pending} data-testid="bm-returned">Returned</button>
          </form>))}
      </div>}

      {msg && <p className={`alert ${msg.ok ? 'alert--ok' : 'alert--error'}`} role={msg.ok ? 'status' : 'alert'} data-testid="bm-message"><span>{msg.text}</span></p>}

      <Table testId="bm-payments" caption="Payments by part" empty="No payments yet." rows={m.payments as unknown as Array<Record<string, unknown>>} cols={[
        { key: 'when', label: 'When', render: (r) => when(String(r.processed_at ?? r.created_at)) },
        { key: 'covers', label: 'For', render: (r) => `${PART[String(r.covers ?? '')] ?? words(PURPOSE, r.purpose)}${r.kind !== 'charge' ? ` (${words(KIND, r.kind)})` : ''}` },
        { key: 'method', label: 'By', render: (r) => `${METHOD[String(r.method)] ?? String(r.method)}${r.card_last4 ? ` ${String(r.card_last4)}` : ''}` },
        { key: 'amount_cents', label: 'Amount', num: true, render: (r) => fmt(Number(r.amount_cents)) },
        { key: 'status', label: 'Status', render: (r) => (r.voided ? 'Voided' : words(STATUS, r.status)) },
        { key: 'reference', label: 'Reference', render: (r) => String(r.reference ?? '') },
        { key: 'receipt', label: 'Receipt', render: (r) => (r.method !== 'card' && r.status === 'succeeded' ? <button className="btn btn--quiet btn--sm" type="button" onClick={() => print(r as unknown as Money['payments'][number])}>Print</button> : null) }]} />
      {m.requests.filter((q) => q.status === 'open').map((q) => (
        <p key={q.id} className="small" data-testid="bm-request">Card {q.kind === 'hold' ? 'hold' : q.kind === 'setup' ? 'save' : 'payment'} of {fmt(q.amount_cents)} waiting ({q.channel === 'device' ? 'on a device' : `sent by ${q.channel}`}, until {when(q.expires_at)}).{' '}
          <button className="btn btn--quiet btn--sm" type="button" disabled={pending} onClick={() => run(async () => { const r = await offersDo('payreq_cancel', { id: q.id }); done(r.ok, r.ok ? 'Cancelled.' : r.message); })}>Cancel</button></p>))}
    </section>
  );
}
