'use client';
import { useState, useTransition } from 'react';
import { useRouter } from 'next/navigation';
import { money } from '@/lib/format';
import { when } from '@/features/agreement/model';
import type { ReactNode } from 'react';
import { chargeSavedCard, holdAction, holdSavedCard, offersDo, reauthorizeHold, startCardRequest } from '@/server/actions/offers';
import { Table } from '@/features/admin/ui';
import { CardTools, type CardRule } from './CardTools';
import { depositAutoText, type DepositAuto } from './deposit-auto-text';
import { DateInput } from '@/components/DateInput';
import { depositNext, depositWord, isDeposit, paidTotals, rentalDue } from './money-panels';

// The money of a booking (migration 0129; r29 C0: two panels, Rental charges and Security deposit, side by side on a
// wide screen and stacked on a phone, with a strip of Rental due, Deposit status and Total paid; collecting one never
// touches the other): what is open for the rental, the fees and later charges; the deposit and how it was taken; the
// card on file. Record a payment received another way (e-Transfer, cash, cheque, bank
// transfer, platform payout, the insurer) against the part it covers; collect a card through Stripe (on this device
// handed to the renter, or by a link texted or emailed); place or settle a deposit hold; charge the saved card; give
// back a deposit taken in cash or by e-Transfer; confirm a booking paid another way. The database decides who may do each.
export interface Money {
  booking_id: string; booking_number: string; status: string; rental_pay_method: string; deposit_pay_method: string; agreement_on_paper: boolean;
  parts: Array<{ covers: 'rental' | 'fees' | 'later'; open_cents: number }>; due_cents: number; deposit_cents: number;
  deposit: { method: string; paid_method: string | null; status: string; amount_cents: number; captured_cents: number; released_cents: number; hold_expires_at: string | null; hold_days_left: number | null } | null;
  card: { brand: string; last4: string; exp_month: number; exp_year: number } | null;
  payments: Array<{ id: string; created_at: string; processed_at: string | null; purpose: string; kind: string; method: string; amount_cents: number; status: string; card_last4: string | null; card_brand: string | null;
    covers: string | null; reference: string | null; note: string | null; manual_id: string | null; voided: boolean; by: string | null;
    /** 0680: one card charge for the rental and the fees, split (the rental first) */ parts?: { rental?: number; fees?: number } | null }>;
  requests: Array<{ id: string; kind: string; covers: string; amount_cents: number; channel: string; status: string; created_at: string; expires_at: string; last_error: string | null }>;
  /** 0213: the latest deposit hold link sent to the renter (texted by the job before pickup, or by staff) */
  /** 2026-11-01: Collect a card sends by text first when the renter has a mobile number */
  renter_has_mobile?: boolean;
  deposit_link?: { id: string; status: string; texted_at: string | null; opened_at: string | null; error: string | null; auto: boolean; channel: string } | null;
  /** 0261: the deposit hold placed automatically on the pickup day */
  deposit_auto?: DepositAuto | null;
  /** 0262: the deposit with a debit or prepaid card (the multiplier, or the amount staff set) */
  debit_deposit?: { cents: number; multiplier: number; set_by_staff: boolean; takes: boolean } | null;
  /** 0230: the cards used on the booking and their type (debit and prepaid are accepted; card coverage needs the credit card) */
  cards?: Array<{ brand: string | null; last4: string | null; funding: 'credit' | 'debit' | 'prepaid' | 'unknown'; payments: number; last_at: string }>;
  debit?: { allowed_at: string | null; reason: string | null; by: string | null; takes: boolean; coverage: boolean; site: 'credit' | 'any' };
  e_transfer_email: string | null; moto: boolean;
  may: { record: boolean; collect: boolean; charge: boolean; hold: boolean; confirm: boolean; return_deposit: boolean };
  can_confirm: boolean;
  /** Release 21 (0203): the same-card rule of a card-coverage rental, the paired card readers, an Admin. */
  card_rule?: CardRule | null; readers?: Array<{ id: string; label: string }>; is_admin?: boolean;
}
const fmt = (c: number | null | undefined) => money(Number(c ?? 0), { cents: true });
// 0680: the split of one charge of the rental and the fees, in words
const splitWords = (x?: { rental?: number; fees?: number } | null) => (x && (x.rental || x.fees) ? ` (${[x.rental ? `rental ${fmt(x.rental)}` : '', x.fees ? `fees ${fmt(x.fees)}` : ''].filter(Boolean).join(', ')})` : '');
const PART: Record<string, string> = { rental: 'Rental', fees: 'Fees', later: 'Later charges', deposit: 'Security deposit', card: 'Card on file', balance: 'Rental and fees' };
// what each payment was for and where it stands, in words (sim item 7: no raw codes)
const PURPOSE: Record<string, string> = { booking_total: 'Rental and fees', deposit: 'Security deposit', extension: 'Extension', change: 'Booking change', later_charge: 'Later charge', damage: 'Damage', addon: 'Add-on', balance: 'Balance' };
const STATUS: Record<string, string> = { succeeded: 'Received', pending: 'Pending', failed: 'Failed', refunded: 'Refunded', partially_refunded: 'Partly refunded', cancelled: 'Cancelled', requires_action: 'Waiting for the renter', processing: 'Processing', disputed: 'Disputed' };
const KIND: Record<string, string> = { refund: 'given back', hold: 'hold', capture: 'captured from the hold', release: 'hold released' };
const words = (m: Record<string, string>, v: unknown) => m[String(v ?? '')] ?? String(v ?? '').replace(/_/g, ' ');
const METHOD: Record<string, string> = { card: 'Card', e_transfer: 'e-Transfer', cash: 'Cash', cheque: 'Cheque', bank_transfer: 'Bank transfer', platform_payout: 'Platform payout', insurer: 'Insurer', other: 'Another way', none: 'None' };
const cents = (s: string) => { const t = s.replace(/[$,\s]/g, ''); return t ? Math.round(Number(t) * 100) : null; };
const today = () => new Intl.DateTimeFormat('en-CA', { timeZone: 'America/Toronto', year: 'numeric', month: '2-digit', day: '2-digit' }).format(new Date());

export interface PanelLine { id: string; description: string | null; charge_type: string; stage?: string | null; amount_cents: number }
const WORD_CLASS: Record<string, string> = { 'Not collected': 'ad-b--amber', Held: 'ad-b--light', Charged: 'ad-b--light', Released: 'ad-b--light', 'Partly kept': 'ad-b--amber', Waived: 'ad-b--light', 'No deposit': 'ad-b--light' };

export function BookingMoney({ m, lines = [], totalCents, waived = false, rentalExtras, depositExtras, depositSettle }: {
  m: Money; lines?: PanelLine[]; totalCents?: number | null; waived?: boolean;
  /** server-rendered pieces of each panel (fees, refunds, payments received another way; waive, debit cards, the settlement) */
  rentalExtras?: ReactNode; depositExtras?: ReactNode; depositSettle?: ReactNode;
}) {
  const router = useRouter();
  type Open = '' | 'rcollect' | 'later' | 'dcollect' | 'capture' | 'release';
  const [open, setOpen] = useState<Open>('');
  const [msg, setMsg] = useState<{ ok: boolean; text: string; at: 'rental' | 'deposit' } | null>(null);
  const [pending, run] = useTransition();
  const { due_cents: due, later_cents: later } = rentalDue(m.parts);
  const paid = paidTotals(m.payments);
  const dep = m.deposit;
  const word = depositWord(dep, m.deposit_cents, waived);
  const next = depositNext(word, m.status);
  const depAmount = dep && !['pending', 'failed'].includes(dep.status) ? dep.amount_cents : (m.debit_deposit?.takes && m.debit_deposit.cents ? m.debit_deposit.cents : m.deposit_cents);
  const openPart = (c: string) => (c === 'balance' ? due : m.parts.find((p) => p.covers === c)?.open_cents ?? 0);
  // Collect $X rental: how, and for what part (rental and fees by default)
  const [rc, setRc] = useState({ how: (m.card && m.may.charge ? 'saved' : m.renter_has_mobile ? 'text' : 'device') as 'saved' | 'text' | 'email' | 'device' | 'record',
    covers: 'balance' as 'balance' | 'rental' | 'fees', method: m.rental_pay_method !== 'card' ? m.rental_pay_method : 'e_transfer', amount: '', reference: '', received_on: today(), note: '' });
  // a later charge (fuel, km, late return): the saved card or a payment received another way
  const [lt, setLt] = useState({ how: (m.card && m.may.charge ? 'saved' : 'record') as 'saved' | 'record' | 'link' | 'device', amount: '', reason: '', method: 'e_transfer', reference: '' });
  // Collect $X deposit: a hold on the card on file, a hold link, a charge, or cash or e-Transfer
  const [dc, setDc] = useState({ how: (m.card && m.may.hold ? 'hold_saved' : m.renter_has_mobile ? 'hold_text' : 'hold_device') as 'hold_saved' | 'hold_text' | 'hold_email' | 'hold_device' | 'charge_saved' | 'record',
    method: 'cash', reference: '', received_on: today() });
  const [cap, setCap] = useState({ amount: '', reason: '' });
  const [rel, setRel] = useState('');
  const [ret, setRet] = useState<Record<string, string>>({});
  const done = (at: 'rental' | 'deposit', ok: boolean, text: string) => { setMsg({ ok, text, at }); if (ok) { setOpen(''); router.refresh(); } };
  const offlineReturns = m.payments.filter((p) => p.purpose === 'deposit' && p.kind === 'refund' && p.status === 'pending' && ['cash', 'e_transfer'].includes(p.method));
  const toggle = (o: Open) => setOpen(open === o ? '' : o);
  const rentalRows = m.payments.filter((p) => !isDeposit(p));
  const depositRows = m.payments.filter((p) => isDeposit(p));
  const depMethod = !dep || ['pending', 'failed'].includes(dep.status)
    ? (m.deposit_pay_method === 'card' ? (m.debit_deposit?.takes ? `Card hold (a debit or prepaid card: ${Number(m.debit_deposit.multiplier)}x, ${fmt(m.debit_deposit.cents)})` : 'Credit card hold') : (METHOD[m.deposit_pay_method] ?? m.deposit_pay_method))
    : dep.method === 'card_hold' ? 'Held on the card' : dep.method === 'charged' ? 'Charged to the card' : dep.method === 'offline' ? (METHOD[dep.paid_method ?? ''] ?? 'Cash or e-Transfer') : dep.method.replace(/_/g, ' ');

  const print = (p: Money['payments'][number]) => {
    const w = window.open('', '_blank', 'width=480,height=640');
    if (!w) return;
    const esc = (s: string) => s.replace(/[&<>"]/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;' }[c]!));
    const what = isDeposit(p) ? 'Security deposit' : PART[p.covers ?? ''] ?? words(PURPOSE, p.purpose);
    w.document.write(`<!doctype html><meta charset="utf-8"><title>Receipt ${esc(m.booking_number)}</title><body style="font:14px/1.5 system-ui;padding:24px"><h1 style="font-size:18px">CarmaCars receipt: ${esc(what)}</h1>
      <p>Booking ${esc(m.booking_number)}<br>${esc(new Date(p.processed_at ?? p.created_at).toLocaleString('en-CA', { timeZone: 'America/Toronto' }))}</p>
      <p><b>${p.kind === 'refund' ? 'Given back' : 'Received'}: ${esc(fmt(p.amount_cents))}</b><br>For: ${esc(what)}${isDeposit(p) ? ' (not a payment for the rental)' : ''}<br>By: ${esc(METHOD[p.method] ?? p.method)}${p.reference ? `<br>Reference: ${esc(p.reference)}` : ''}${p.by ? `<br>Recorded by: ${esc(p.by)}` : ''}</p>
      <p>Receipt R-${esc(p.id.slice(0, 8).toUpperCase())}</p><p style="margin-top:48px">Signature: ____________________</p><script>print()</script></body>`);
    w.document.close();
  };
  const history = (rows: Money['payments'], id: string, caption: string, empty: string) => (
    <Table testId={id} caption={caption} empty={empty} rows={rows as unknown as Array<Record<string, unknown>>} cols={[
      { key: 'when', label: 'When', render: (r) => when(String(r.processed_at ?? r.created_at)) },
      { key: 'covers', label: 'For', render: (r) => `${PART[String(r.covers ?? '')] ?? words(PURPOSE, r.purpose)}${splitWords(r.parts as Money['payments'][number]['parts'])}${r.kind !== 'charge' ? ` (${words(KIND, r.kind)})` : ''}` },
      { key: 'method', label: 'By', render: (r) => `${METHOD[String(r.method)] ?? String(r.method)}${r.card_last4 ? ` ${String(r.card_last4)}` : ''}` },
      { key: 'amount_cents', label: 'Amount', num: true, render: (r) => fmt(Number(r.amount_cents)) },
      { key: 'status', label: 'Status', render: (r) => (r.voided ? 'Voided' : words(STATUS, r.status)) },
      { key: 'reference', label: 'Reference', render: (r) => String(r.reference ?? '') },
      { key: 'receipt', label: 'Receipt', render: (r) => (r.method !== 'card' && r.status === 'succeeded' ? <button className="btn btn--quiet btn--sm" type="button" onClick={() => print(r as unknown as Money['payments'][number])}>Print</button> : null) }]} />);
  const note = (at: 'rental' | 'deposit') => msg && msg.at === at ? <p className={`alert ${msg.ok ? 'alert--ok' : 'alert--error'}`} role={msg.ok ? 'status' : 'alert'} data-testid={`bm-message-${at}`}><span>{msg.text}</span></p> : null;
  const channelFields = (name: string, value: string, set: (v: string) => void, opts: Array<[string, string]>) => (
    <div className="field ad-field ad-field--wide"><span className="label">How</span>
      {opts.map(([v, x]) => <label key={v} className="check" htmlFor={`${name}-${v}`}><input type="radio" id={`${name}-${v}`} name={name} checked={value === v} onChange={() => set(v)} data-testid={`${name}-${v}`} /> <span>{x}</span></label>)}</div>);

  // the rental: the card on file, a link, this device, or a payment received another way (never the deposit)
  const collectRental = () => run(async () => {
    const amount = cents(rc.amount);
    if (rc.how === 'record') {
      const r = await offersDo<{ confirmed?: boolean; confirm?: { reason?: string; awaiting_signature?: boolean } }>('record_booking_payment', { booking: m.booking_number, covers: rc.covers === 'balance' ? 'both' : rc.covers, method: rc.method, amount_cents: amount, reference: rc.reference, received_on: rc.received_on, note: rc.note });
      done('rental', r.ok, r.ok ? `Rental payment recorded.${r.data.confirmed ? (r.data.confirm?.awaiting_signature ? ' The booking is confirmed. CarmaCars countersigns the rental agreement when the renter signs.' : ' The booking is confirmed.') : r.data.confirm?.reason ? ` Not confirmed yet: ${r.data.confirm.reason}.` : ''}` : r.message);
      return;
    }
    if (rc.how === 'saved') {
      // r32 (0680): the card on file is charged once for what is open (the rental and fees: one Stripe charge, one
      // receipt listing both); the database splits it across the rental and the fees, the rental first
      if (openPart(rc.covers) <= 0) { done('rental', false, 'Nothing is open for the rental.'); return; }
      const r = await chargeSavedCard({ booking: m.booking_number, covers: rc.covers, amount_cents: amount, reason: rc.covers === 'rental' ? 'Rental' : rc.covers === 'fees' ? 'Fees' : 'Rental and fees' });
      if (!r.ok || !r.data.ok) { done('rental', false, r.ok ? `Declined: ${r.data.message}` : r.message); return; }
      done('rental', true, 'Rental charged to the card on file. The renter has the receipt by email.');
      return;
    }
    const r = await startCardRequest({ booking: m.booking_number, kind: 'charge', covers: rc.covers, amount_cents: amount, reason: 'Rental', channel: rc.how });
    if (!r.ok) { done('rental', false, r.message); return; }
    if (rc.how === 'device') { router.push(r.data.url); return; }
    done('rental', !!r.data.sent?.ok, r.data.sent?.ok ? `Rental payment link sent${r.data.sent.to ? ` to ${r.data.sent.to}` : ''}. It works for 3 days.` : `Not sent: ${r.data.sent?.reason ?? 'no answer'}`);
  });
  const chargeLater = () => run(async () => {
    const amount = cents(lt.amount);
    if (lt.how === 'saved') { const r = await chargeSavedCard({ booking: m.booking_number, amount_cents: amount, reason: lt.reason, covers: 'later' }); done('rental', r.ok && r.data.ok, r.ok ? (r.data.ok ? 'Charged. The renter has the receipt by email.' : `Declined: ${r.data.message}`) : r.message); return; }
    if (lt.how === 'link' || lt.how === 'device') {
      const r = await startCardRequest({ booking: m.booking_number, kind: 'charge', covers: 'later', amount_cents: amount, reason: lt.reason, channel: lt.how === 'device' ? 'device' : m.renter_has_mobile ? 'text' : 'email' });
      if (r.ok && lt.how === 'device') { router.push(r.data.url); return; }
      done('rental', r.ok && !!r.data.sent?.ok, r.ok ? (r.data.sent?.ok ? 'Payment link sent.' : `Not sent: ${r.data.sent?.reason ?? 'no answer'}`) : r.message); return;
    }
    const r = await offersDo('record_booking_payment', { booking: m.booking_number, covers: 'later', method: lt.method, amount_cents: amount, reference: lt.reference, received_on: today(), note: lt.reason });
    done('rental', r.ok, r.ok ? 'Recorded.' : r.message);
  });
  // the deposit: a hold on the card on file, a hold link, a charge as the deposit, or cash or e-Transfer (never the rental)
  const collectDeposit = () => run(async () => {
    if (dc.how === 'hold_saved') { const r = await holdSavedCard({ booking: m.booking_number }); done('deposit', r.ok && r.data.ok, r.ok ? (r.data.ok ? `Deposit of ${fmt(r.data.amount_cents)} held on the card on file.` : r.data.message ?? 'Not held.') : r.message); return; }
    if (dc.how === 'charge_saved') { const r = await chargeSavedCard({ booking: m.booking_number, covers: 'deposit', reason: 'Security deposit (refunded after the return, less what is owed)' }); done('deposit', r.ok && r.data.ok, r.ok ? (r.data.ok ? 'Deposit charged to the card on file.' : `Declined: ${r.data.message}`) : r.message); return; }
    if (dc.how === 'record') { const r = await offersDo('record_booking_payment', { booking: m.booking_number, covers: 'deposit', method: dc.method, amount_cents: null, reference: dc.reference, received_on: dc.received_on, note: '' }); done('deposit', r.ok, r.ok ? 'Deposit recorded.' : r.message); return; }
    const channel = dc.how === 'hold_text' ? 'text' : dc.how === 'hold_email' ? 'email' : 'device';
    const r = await startCardRequest({ booking: m.booking_number, kind: 'hold', reason: 'Security deposit', channel });
    if (!r.ok) { done('deposit', false, r.message); return; }
    if (channel === 'device') { router.push(r.data.url); return; }
    done('deposit', !!r.data.sent?.ok, r.data.sent?.ok ? `Deposit link sent${r.data.sent.to ? ` to ${r.data.sent.to}` : ''}: it holds ${fmt(depAmount)} and charges nothing for the rental.` : `Not sent: ${r.data.sent?.reason ?? 'no answer'}`);
  });

  return (
    <section className="stack" aria-label="Money" data-testid="booking-money">
      <div className="bm-strip" data-testid="bm-strip">
        <div><span className="bm-strip__k">Rental due</span><b className="bm-strip__v" data-testid="bm-strip-rental">{fmt(due)}</b>{later > 0 && <span className="small muted"> + {fmt(later)} later charges</span>}</div>
        <div><span className="bm-strip__k">Deposit</span><b className="bm-strip__v" data-testid="bm-strip-deposit">{word}</b>{word !== 'No deposit' && <span className="small muted"> {fmt(depAmount)}</span>}</div>
        <div><span className="bm-strip__k">Total paid</span><b className="bm-strip__v" data-testid="bm-strip-paid">{fmt(paid.total_cents)}</b></div>
      </div>
      {m.can_confirm && m.may.confirm && <p className="alert alert--warn" role="status"><span>Approved by the renter, paid by {(METHOD[m.rental_pay_method] ?? '').toLowerCase()}. Record the payment, then confirm. {' '}
        <button className="btn btn--primary btn--sm" type="button" disabled={pending} data-testid="bm-confirm" onClick={() => run(async () => { const r = await offersDo('confirm_offline_booking', { booking: m.booking_number }); done('rental', r.ok, r.ok ? 'Confirmed and on the calendar.' : r.message); })}>Confirm the booking</button></span></p>}
      {m.rental_pay_method === 'e_transfer' && m.e_transfer_email && ['offered', 'pending_payment'].includes(m.status) && <p className="small">The renter sends the e-Transfer to <b>{m.e_transfer_email}</b> with the booking number as the message.</p>}

      <div className="bm-panels">
        {/* ================================================================ Rental charges */}
        <section className="pt-card ad-card stack bm-panel" aria-labelledby="bm-rental-h" data-testid="bm-rental">
          <div className="pt-card__head"><h2 className="d4" id="bm-rental-h">Rental charges</h2><span className="small muted">by {(METHOD[m.rental_pay_method] ?? m.rental_pay_method).toLowerCase()}</span></div>
          <dl className="pt-dl pt-dl--money" data-testid="bm-lines">
            {lines.map((l) => <div key={l.id}><dt>{l.description || l.charge_type.replace(/_/g, ' ')}{l.stage ? <span className="muted small"> {l.stage}</span> : null}</dt><dd>{fmt(l.amount_cents)}</dd></div>)}
            {totalCents != null && <div><dt><b>Total</b></dt><dd><b>{fmt(totalCents)}</b></dd></div>}
            <div><dt>Paid</dt><dd data-testid="bm-rental-paid">{fmt(paid.rental_cents)}</dd></div>
            <div><dt><b>Balance due</b></dt><dd><b data-testid="bm-rental-due">{fmt(due)}</b></dd></div>
            {later > 0 && <div><dt>Later charges open</dt><dd>{fmt(later)}</dd></div>}
          </dl>
          <div className="ad-actions">
            {due > 0 && (m.may.record || m.may.collect || m.may.charge) && <button className="btn btn--primary btn--sm" type="button" aria-expanded={open === 'rcollect'} onClick={() => toggle('rcollect')} data-testid="bm-rental-collect">Collect {fmt(due)} rental</button>}
            {(m.may.charge || m.may.record) && <button className="btn btn--ghost btn--sm" type="button" aria-expanded={open === 'later'} onClick={() => toggle('later')} data-testid="bm-later-open">A later charge</button>}
            {m.may.collect && <button className="btn btn--quiet btn--sm" type="button" disabled={pending} data-testid="bm-save-card" onClick={() => run(async () => {
              const r = await startCardRequest({ booking: m.booking_number, kind: 'setup', reason: 'Card on file', channel: 'device' }); if (r.ok) router.push(r.data.url); else done('rental', false, r.message); })}>Save a card</button>}
          </div>
          <p className="small muted">Card on file: {m.card ? `${m.card.brand} ending ${m.card.last4}` : 'none'}.</p>
          {open === 'rcollect' && (
            <form className="ad-form ad-form--narrow" aria-label="Collect the rental" data-testid="bm-rcollect" onSubmit={(e) => { e.preventDefault(); collectRental(); }}>
              <div className="ad-fields">
                {channelFields('bm-rhow', rc.how, (v) => setRc({ ...rc, how: v as typeof rc.how }), [
                  ...(m.card && m.may.charge ? [['saved', `The card on file (${m.card.brand} ending ${m.card.last4})`] as [string, string]] : []),
                  ...(m.may.collect ? [['text', 'A payment link by text'], ['email', 'A payment link by email'], ['device', 'On this device: hand it to the renter']] as Array<[string, string]> : []),
                  ...(m.may.record ? [['record', 'Cash, e-Transfer or another way (record it)'] as [string, string]] : [])])}
                <div className="field ad-field"><label className="label" htmlFor="bm-rcovers">For</label>
                  <select className="select" id="bm-rcovers" value={rc.covers} onChange={(e) => setRc({ ...rc, covers: e.target.value as typeof rc.covers })} data-testid="bm-rcovers">
                    <option value="balance">The rental and fees ({fmt(due)})</option>{openPart('rental') > 0 && <option value="rental">The rental only ({fmt(openPart('rental'))})</option>}{openPart('fees') > 0 && <option value="fees">Fees only ({fmt(openPart('fees'))})</option>}</select></div>
                <div className="field ad-field"><label className="label" htmlFor="bm-ramount">Amount ($)</label><input className="input" id="bm-ramount" inputMode="decimal" value={rc.amount} onChange={(e) => setRc({ ...rc, amount: e.target.value })} placeholder={(openPart(rc.covers) / 100).toFixed(2)} data-testid="bm-ramount" /></div>
                {rc.how === 'record' && <>
                  <div className="field ad-field"><label className="label" htmlFor="bm-rmethod">Paid by</label>
                    <select className="select" id="bm-rmethod" value={rc.method} onChange={(e) => setRc({ ...rc, method: e.target.value })} data-testid="bm-rmethod">
                      {['e_transfer', 'cash', 'cheque', 'bank_transfer', 'platform_payout', 'insurer', 'other'].map((x) => <option key={x} value={x}>{METHOD[x]}</option>)}</select></div>
                  <div className="field ad-field"><label className="label" htmlFor="bm-rref">Reference{['e_transfer', 'cheque', 'bank_transfer'].includes(rc.method) ? '' : ' (optional)'}</label><input className="input" id="bm-rref" value={rc.reference} onChange={(e) => setRc({ ...rc, reference: e.target.value })} data-testid="bm-rref" /></div>
                  <div className="field ad-field"><label className="label" htmlFor="bm-ron">Received on</label><DateInput className="input" id="bm-ron" type="date" value={rc.received_on} max={today()} onChange={(e) => setRc({ ...rc, received_on: e.target.value })} /></div>
                  <div className="field ad-field"><label className="label" htmlFor="bm-rnote">Note{rc.method === 'other' ? '' : ' (optional)'}</label><input className="input" id="bm-rnote" value={rc.note} onChange={(e) => setRc({ ...rc, note: e.target.value })} /></div></>}
              </div>
              {['text'].includes(rc.how) && m.renter_has_mobile === false && <p className="small ad-flag" role="note">No mobile number for this renter: send the link by email or open it on this device.</p>}
              <p className="hint">{m.moto ? 'Typing a card the renter reads out (phone order) is on: use On this device.' : 'Staff never type a card number: the renter types it in Stripe\'s form.'} The deposit is not touched.</p>
              <button className="btn btn--primary btn--sm" type="submit" disabled={pending} data-testid="bm-rcollect-go">{pending ? 'Working' : rc.how === 'saved' ? 'Charge the rental' : rc.how === 'record' ? 'Record the rental payment' : rc.how === 'device' ? 'Open the card form' : 'Send the rental link'}</button>
            </form>)}
          {open === 'later' && (
            <form className="ad-form ad-form--narrow" aria-label="A later charge" data-testid="bm-later" onSubmit={(e) => { e.preventDefault(); chargeLater(); }}>
              <div className="ad-fields">
                {channelFields('bm-lhow', lt.how, (v) => setLt({ ...lt, how: v as typeof lt.how }), [
                  ...(m.card && m.may.charge ? [['saved', 'Charge the card on file'] as [string, string]] : []), ...(m.may.collect ? [['link', 'Send a payment link'], ['device', 'On this device: hand it to the renter']] as Array<[string, string]> : []), ...(m.may.record ? [['record', 'Received another way (record it)'] as [string, string]] : [])])}
                <div className="field ad-field"><label className="label" htmlFor="bm-lamount">Amount ($)</label><input className="input" id="bm-lamount" inputMode="decimal" value={lt.amount} onChange={(e) => setLt({ ...lt, amount: e.target.value })} placeholder={(later / 100).toFixed(2)} data-testid="bm-lamount" /></div>
                <div className="field ad-field ad-field--wide"><label className="label" htmlFor="bm-lreason">Reason (on the renter&apos;s receipt)</label><input className="input" id="bm-lreason" value={lt.reason} onChange={(e) => setLt({ ...lt, reason: e.target.value })} placeholder="Extra km, fuel, damage, late return" data-testid="bm-lreason" /></div>
                {lt.how === 'record' && <><div className="field ad-field"><label className="label" htmlFor="bm-lmethod">Paid by</label><select className="select" id="bm-lmethod" value={lt.method} onChange={(e) => setLt({ ...lt, method: e.target.value })}>{['e_transfer', 'cash', 'cheque', 'bank_transfer', 'insurer', 'other'].map((x) => <option key={x} value={x}>{METHOD[x]}</option>)}</select></div>
                  <div className="field ad-field"><label className="label" htmlFor="bm-lref">Reference</label><input className="input" id="bm-lref" value={lt.reference} onChange={(e) => setLt({ ...lt, reference: e.target.value })} /></div></>}
              </div>
              <button className="btn btn--primary btn--sm" type="submit" disabled={pending} data-testid="bm-later-go">{pending ? 'Working' : 'Save the later charge'}</button>
            </form>)}
          <CardTools only="rental" booking={m.booking_number} parts={m.parts} deposit_cents={m.deposit_cents} depositTaken={!!dep && !['pending', 'failed'].includes(dep.status)}
            rule={m.card_rule ?? null} readers={m.readers ?? []} isAdmin={!!m.is_admin} mayRecord={m.may.record} mayCollect={m.may.collect} />
          {note('rental')}
          {m.requests.filter((q) => q.status === 'open' && q.covers !== 'deposit' && q.kind !== 'hold').map((q) => (
            <p key={q.id} className="small" data-testid="bm-request">Card {q.kind === 'setup' ? 'save' : 'payment'} of {fmt(q.amount_cents)} waiting ({q.channel === 'device' ? 'on a device' : `sent by ${q.channel}`}, until {when(q.expires_at)}).{' '}
              <button className="btn btn--quiet btn--sm" type="button" disabled={pending} onClick={() => run(async () => { const r = await offersDo('payreq_cancel', { id: q.id }); done('rental', r.ok, r.ok ? 'Cancelled.' : r.message); })}>Cancel</button></p>))}
          {rentalExtras}
          {history(rentalRows, 'bm-rental-history', 'Rental payment history', 'No rental payment yet.')}
          {!!m.cards?.length && <p className="small" data-testid="bm-cards">Cards used: {m.cards.map((c) => `${(c.brand ?? 'card').toUpperCase()} ending ${c.last4 ?? ''} (${c.funding === 'credit' ? 'credit' : c.funding === 'debit' ? 'debit' : c.funding === 'prepaid' ? 'prepaid' : 'type unknown'})`).join(', ')}.</p>}
        </section>

        {/* ================================================================ Security deposit */}
        <section className="pt-card ad-card stack bm-panel" aria-labelledby="bm-deposit-h" data-testid="bm-deposit-panel">
          <div className="pt-card__head"><h2 className="d4" id="bm-deposit-h">Security deposit</h2><span className={`ad-b ${WORD_CLASS[word] ?? ''}`} data-testid="bm-deposit-word">{word}</span></div>
          <dl className="pt-dl pt-dl--money">
            <div><dt>Amount</dt><dd data-testid="bm-deposit">{fmt(depAmount)}</dd></div>
            <div><dt>Method</dt><dd>{depMethod}</dd></div>
            {dep?.method === 'card_hold' && dep.status === 'held' && dep.hold_expires_at && <div><dt>Hold expires</dt><dd>{when(dep.hold_expires_at)}{dep.hold_days_left !== null ? ` (${dep.hold_days_left} day${dep.hold_days_left === 1 ? '' : 's'} left)` : ''}</dd></div>}
            {!!dep?.captured_cents && <div><dt>Kept</dt><dd>{fmt(dep.captured_cents)}</dd></div>}
            {!!dep?.released_cents && <div><dt>Released</dt><dd>{fmt(dep.released_cents)}</dd></div>}
          </dl>
          <div className="ad-actions">
            {next === 'collect' && (m.may.collect || m.may.hold || m.may.record) && <button className="btn btn--primary btn--sm" type="button" aria-expanded={open === 'dcollect'} onClick={() => toggle('dcollect')} data-testid="bm-deposit-collect">Collect {fmt(depAmount)} deposit</button>}
            {next === 'held' && m.may.hold && <>
              <button className="btn btn--primary btn--sm" type="button" aria-expanded={open === 'release'} onClick={() => toggle('release')} data-testid="bm-release">Release</button>
              <button className="btn btn--ghost btn--sm" type="button" aria-expanded={open === 'capture'} onClick={() => toggle('capture')} data-testid="bm-capture-open">Keep part (damage/fees)</button>
              {m.card && <button className="btn btn--quiet btn--sm" type="button" disabled={pending} data-testid="bm-reauth" onClick={() => run(async () => {
                const r = await reauthorizeHold({ booking: m.booking_number });
                done('deposit', r.ok && r.data.ok, r.ok ? (r.data.ok ? `Re-authorized on the saved card${r.data.hold_expires_at ? `: held until ${when(r.data.hold_expires_at)}` : ''}. The old hold is released.` : r.data.message ?? 'Not re-authorized.') : r.message);
              })}>Re-authorize the hold</button>}</>}
            {(next === 'settle' || (['returned', 'closed'].includes(m.status) && !['Released', 'Partly kept', 'Waived', 'No deposit'].includes(word))) && depositSettle}
          </div>
          {open === 'dcollect' && (
            <form className="ad-form ad-form--narrow" aria-label="Collect the deposit" data-testid="bm-dcollect" onSubmit={(e) => { e.preventDefault(); collectDeposit(); }}>
              <div className="ad-fields">
                {channelFields('bm-dhow', dc.how, (v) => setDc({ ...dc, how: v as typeof dc.how }), [
                  ...(m.card && m.may.hold ? [['hold_saved', `Hold on the card on file (${m.card.brand} ending ${m.card.last4})`] as [string, string]] : []),
                  ...(m.may.collect ? [['hold_text', 'A deposit hold link by text'], ['hold_email', 'A deposit hold link by email'], ['hold_device', 'A hold on this device: hand it to the renter']] as Array<[string, string]> : []),
                  ...(m.card && m.may.charge ? [['charge_saved', 'Charge the card on file as the deposit (only when no hold can be placed)'] as [string, string]] : []),
                  ...(m.may.record ? [['record', 'Cash or e-Transfer (record it)'] as [string, string]] : [])])}
                {dc.how === 'record' && <>
                  <div className="field ad-field"><label className="label" htmlFor="bm-dmethod">Paid by</label><select className="select" id="bm-dmethod" value={dc.method} onChange={(e) => setDc({ ...dc, method: e.target.value })} data-testid="bm-dmethod"><option value="cash">Cash</option><option value="e_transfer">e-Transfer</option></select></div>
                  <div className="field ad-field"><label className="label" htmlFor="bm-dref">Reference (optional)</label><input className="input" id="bm-dref" value={dc.reference} onChange={(e) => setDc({ ...dc, reference: e.target.value })} /></div>
                  <div className="field ad-field"><label className="label" htmlFor="bm-don">Received on</label><DateInput className="input" id="bm-don" type="date" value={dc.received_on} max={today()} onChange={(e) => setDc({ ...dc, received_on: e.target.value })} /></div></>}
              </div>
              <p className="hint">The deposit only: the rental balance is not touched.</p>
              <button className="btn btn--primary btn--sm" type="submit" disabled={pending} data-testid="bm-dcollect-go">{pending ? 'Working' : dc.how === 'record' ? 'Record the deposit' : dc.how === 'hold_saved' ? 'Hold the deposit' : dc.how === 'charge_saved' ? 'Charge the deposit' : dc.how === 'hold_device' ? 'Open the card form' : 'Send the deposit link'}</button>
            </form>)}
          {open === 'capture' && dep && (
            <form className="ad-form ad-form--narrow" aria-label="Keep part of the deposit" data-testid="bm-capture" onSubmit={(e) => { e.preventDefault(); run(async () => {
              const r = await holdAction({ booking: m.booking_number, action: 'capture', amount_cents: cents(cap.amount), reason: cap.reason });
              done('deposit', r.ok && r.data.ok, r.ok ? (r.data.ok ? (cents(cap.amount) !== null && cents(cap.amount)! < dep.amount_cents ? 'Kept; the rest of the hold is released.' : 'Kept.') : r.data.message ?? 'Not kept.') : r.message);
            }); }}>
              <div className="ad-fields">
                <div className="field ad-field"><label className="label" htmlFor="bm-kamount">Amount to keep ($, up to {fmt(dep.amount_cents)})</label><input className="input" id="bm-kamount" inputMode="decimal" value={cap.amount} onChange={(e) => setCap({ ...cap, amount: e.target.value })} placeholder={(dep.amount_cents / 100).toFixed(2)} /></div>
                <div className="field ad-field"><label className="label" htmlFor="bm-kreason">Reason (damage, tolls, fees)</label><input className="input" id="bm-kreason" value={cap.reason} onChange={(e) => setCap({ ...cap, reason: e.target.value })} /></div>
              </div>
              <button className="btn btn--primary btn--sm" type="submit" disabled={pending}>Keep it</button>
            </form>)}
          {open === 'release' && dep && (
            <form className="ad-form ad-form--narrow" aria-label="Release the hold" data-testid="bm-release-form" onSubmit={(e) => { e.preventDefault(); run(async () => {
              const r = await holdAction({ booking: m.booking_number, action: 'release', reason: rel });
              done('deposit', r.ok && r.data.ok, r.ok ? (r.data.ok ? 'Hold released.' : r.data.message ?? 'Not released.') : r.message);
            }); }}>
              <p className="small muted">The deposit stays held while the car is out, until tolls and tickets have had time to come in, and while anything is still open. After the return, settle it instead; an Admin may release it now with the reason.</p>
              <div className="field ad-field ad-field--wide"><label className="label" htmlFor="bm-rreason">Reason (an Admin, 10 characters or more)</label><input className="input" id="bm-rreason" value={rel} onChange={(e) => setRel(e.target.value)} /></div>
              <button className="btn btn--primary btn--sm" type="submit" disabled={pending} data-testid="bm-release-go">Release</button>
            </form>)}
          <CardTools only="deposit" booking={m.booking_number} parts={m.parts} deposit_cents={m.deposit_cents} depositTaken={!!dep && !['pending', 'failed'].includes(dep.status)}
            rule={m.card_rule ?? null} readers={m.readers ?? []} isAdmin={!!m.is_admin} mayRecord={m.may.record} mayCollect={m.may.collect} />
          {offlineReturns.length > 0 && m.may.return_deposit && <div className="stack" data-testid="bm-returns">
            {offlineReturns.map((p) => (
              <form key={p.id} className="row" onSubmit={(e) => { e.preventDefault(); run(async () => { const r = await offersDo('deposit_return_offline', { payment: p.id, reference: ret[p.id] ?? '' }); done('deposit', r.ok, r.ok ? 'Recorded as given back.' : r.message); }); }}>
                <span className="small"><b>Give back {fmt(p.amount_cents)} by {(METHOD[p.method] ?? '').toLowerCase()}</b></span>
                <label className="sr-only" htmlFor={`bm-ret-${p.id}`}>Reference</label>
                <input className="input" id={`bm-ret-${p.id}`} placeholder={p.method === 'e_transfer' ? 'e-Transfer reference' : 'Receipt number (optional)'} value={ret[p.id] ?? ''} onChange={(e) => setRet({ ...ret, [p.id]: e.target.value })} />
                <button className="btn btn--primary btn--sm" type="submit" disabled={pending} data-testid="bm-returned">Returned</button>
              </form>))}
          </div>}
          {note('deposit')}
          {m.requests.filter((q) => q.status === 'open' && (q.covers === 'deposit' || q.kind === 'hold')).map((q) => (
            <p key={q.id} className="small" data-testid="bm-deposit-request">Deposit hold of {fmt(q.amount_cents)} waiting ({q.channel === 'device' ? 'on a device' : `sent by ${q.channel}`}, until {when(q.expires_at)}).{' '}
              <button className="btn btn--quiet btn--sm" type="button" disabled={pending} onClick={() => run(async () => { const r = await offersDo('payreq_cancel', { id: q.id }); done('deposit', r.ok, r.ok ? 'Cancelled.' : r.message); })}>Cancel</button></p>))}
          {depositAutoText(m.deposit_auto, when, fmt) && <p className={`small${m.deposit_auto?.status === 'failed' ? ' alert alert--warn' : ''}`} data-testid="bm-deposit-auto">{depositAutoText(m.deposit_auto, when, fmt)}</p>}
          {m.deposit_link && (m.deposit_link.texted_at || m.deposit_link.error) && (
            <p className="small" data-testid="bm-deposit-link">{m.deposit_link.texted_at ? `Deposit link texted ${when(m.deposit_link.texted_at)}` : `Deposit link not sent: ${m.deposit_link.error}`}
              {m.deposit_link.opened_at ? `, opened ${when(m.deposit_link.opened_at)}` : m.deposit_link.texted_at ? ', not opened yet' : ''}{m.deposit_link.status === 'paid' ? ': the hold is placed.' : '.'}</p>)}
          {m.debit && <p className="small" data-testid="bm-debit">{m.debit.coverage ? 'Card coverage: paid on the credit card that carries the coverage (no debit or prepaid card).'
            : m.debit.allowed_at ? `Debit and prepaid cards allowed for this booking${m.debit.by ? ` by ${m.debit.by}` : ''} on ${when(m.debit.allowed_at)}: ${m.debit.reason ?? ''}`
            : m.debit.takes ? 'This booking takes a debit or prepaid card (the car or the site-wide setting).' : 'A credit card is required (no debit or prepaid card).'}</p>}
          {m.debit_deposit && m.debit_deposit.takes && <p className="small" data-testid="bm-debit-deposit">Debit deposit: {m.debit_deposit.set_by_staff ? `${fmt(m.debit_deposit.cents)} (set for this booking)` : `${Number(m.debit_deposit.multiplier)}x (${fmt(m.debit_deposit.cents)})`}.</p>}
          {depositExtras}
          {history(depositRows, 'bm-deposit-history', 'Deposit history', 'No deposit taken yet.')}
          <p className="small muted">The deposit is never released by itself: Finance or an Admin settles it after the return.</p>
        </section>
      </div>
    </section>
  );
}
