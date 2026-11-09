'use client';
import { useState, useTransition } from 'react';
import { useRouter } from 'next/navigation';
import qrcode from 'qrcode-generator';
import Link from '@/components/Link';
import { money } from '@/lib/format';
import { startCardRequest } from '@/server/actions/offers';
import { startOnReader, pollReader } from '@/server/actions/card-tools';
import { helpFind } from '@/server/actions/field-work';
import { FdIcon } from '@/features/field/icons';
import type { BookingCan } from '@/features/shared-pages/viewer';
import { toCents } from './model';

// Renter help on the spot (r35 part X): a payment or the deposit hold by a pay link (text or email), a QR the renter scans with their
// own phone, the renter typing on this phone, or the card reader when one is with you. Field staff never type a card number;
// refunds and voids stay with Finance and Admin (bookingCan: field). The database checks each request (app.card_collect_allowed).
export interface HelpBooking { id: string; number: string; status: string; pickup_at: string; return_at: string; job: string | null; vehicle: string;
  renter: { name: string; mobile: string | null; email: string | null } | null; open_cents: number; deposit_cents: number; deposit: 'taken' | 'not_taken' | 'waived' | 'none';
  signed: boolean; identity: boolean; drivers: Array<{ name: string; role: string; verified: boolean }> }

function Collect({ b, kind, readers }: { b: HelpBooking; kind: 'charge' | 'hold'; readers: Array<{ id: string; label: string }> }) {
  const router = useRouter();
  const [amount, setAmount] = useState(((kind === 'hold' ? b.deposit_cents : b.open_cents) / 100).toFixed(2));
  const [qr, setQr] = useState<string | null>(null);
  const [msg, setMsg] = useState<{ ok: boolean; text: string } | null>(null);
  const [pending, start] = useTransition();
  const cents = kind === 'hold' ? b.deposit_cents : toCents(amount);
  const ask = (how: 'text' | 'email' | 'device' | 'qr' | 'reader') => start(async () => {
    setMsg(null); setQr(null);
    if (!cents) { setMsg({ ok: false, text: 'Enter the amount.' }); return; }
    if (how === 'reader') {
      const r = await startOnReader({ booking: b.number, kind, covers: kind === 'hold' ? undefined : 'balance', amount_cents: kind === 'hold' ? null : cents, reason: kind === 'hold' ? 'Deposit' : 'Rental', reader: readers[0]?.id ?? null });
      if (!r.ok) { setMsg({ ok: false, text: r.message }); return; }
      setMsg({ ok: true, text: `On the reader (${r.data.reader_label}): the renter taps or inserts the card.` });
      for (let i = 0; i < 60; i++) {
        await new Promise((x) => setTimeout(x, 2000));
        const p = await pollReader({ id: r.data.id, booking: b.number });
        if (p.ok && p.data.state !== 'waiting') { setMsg({ ok: p.data.state === 'done', text: p.data.state === 'done' ? 'Paid on the reader.' : `Not paid: ${p.data.message ?? p.data.state}` }); router.refresh(); return; }
      }
      return;
    }
    const r = await startCardRequest({ booking: b.number, kind, covers: kind === 'hold' ? undefined : 'balance', amount_cents: kind === 'hold' ? null : cents, reason: kind === 'hold' ? 'Deposit' : 'Rental',
      channel: how === 'qr' ? 'device' : how, back: `/staff/field/help/${b.number}` });
    if (!r.ok) { setMsg({ ok: false, text: r.message }); return; }
    if (how === 'device') { router.push(r.data.url); return; }
    if (how === 'qr') {
      const url = `${window.location.origin}${r.data.url.split('?')[0]}`;
      const q = qrcode(0, 'M'); q.addData(url); q.make(); setQr(q.createSvgTag({ cellSize: 6, margin: 2, scalable: true }));
      setMsg({ ok: true, text: 'The renter scans this with their phone camera and pays on their own phone.' }); return;
    }
    setMsg({ ok: !!r.data.sent?.ok, text: r.data.sent?.ok ? `Link sent${r.data.sent.to ? ` to ${r.data.sent.to}` : ''}. It works for 3 days.` : `Not sent: ${r.data.sent?.reason ?? 'no answer'}` });
  });
  return (
    <div className="fp-form">
      {kind === 'charge' && <div className="field"><label className="label" htmlFor={`amt-${kind}`}>Amount ($)</label><input id={`amt-${kind}`} className="input fd-num" inputMode="decimal" value={amount} onChange={(e) => setAmount(e.target.value)} /></div>}
      <button type="button" className="btn btn--primary fd-wide" disabled={pending} onClick={() => ask('qr')} data-testid={`${kind}-qr`}>Show a QR for their phone</button>
      <div className="fp-row2">
        <button type="button" className="btn btn--ghost" disabled={pending || !b.renter?.mobile} onClick={() => ask('text')} data-testid={`${kind}-text`}>Text the link</button>
        <button type="button" className="btn btn--ghost" disabled={pending || !b.renter?.email} onClick={() => ask('email')} data-testid={`${kind}-email`}>Email the link</button>
      </div>
      <button type="button" className="btn btn--ghost fd-wide" disabled={pending} onClick={() => ask('device')}>They type it on my phone</button>
      {readers.length > 0 && <button type="button" className="btn btn--ghost fd-wide" disabled={pending} onClick={() => ask('reader')} data-testid={`${kind}-reader`}>Use the card reader</button>}
      {qr && <div className="fp-qr" role="img" aria-label="QR code of the pay link" dangerouslySetInnerHTML={{ __html: qr }} />}
      {msg && <p className={msg.ok ? 'fp-done' : 'error'} role={msg.ok ? 'status' : 'alert'}>{msg.text}</p>}
      <p className="small">Never type a card number. Refunds stay with Finance.</p>
    </div>
  );
}

export function RenterHelp({ b, can, readers }: { b: HelpBooking; can: BookingCan; readers: Array<{ id: string; label: string }> }) {
  const [open, setOpen] = useState<'' | 'pay' | 'hold'>('');
  const depositOpen = b.deposit === 'not_taken' && b.deposit_cents > 0;
  return (
    <div className="fp-stack" data-testid="renter-help">
      <div className="fp-help-tiles">
        <div className={b.open_cents > 0 ? 'is-bad' : 'is-ok'}><span className="small">To pay</span><b>{b.open_cents > 0 ? money(b.open_cents, { cents: true }) : 'Paid'}</b></div>
        <div className={depositOpen ? 'is-bad' : 'is-ok'}><span className="small">Deposit</span><b>{b.deposit === 'taken' ? 'Taken' : b.deposit === 'waived' ? 'Waived' : b.deposit === 'none' ? 'None' : money(b.deposit_cents, { cents: true })}</b></div>
        <div className={b.identity ? 'is-ok' : 'is-bad'}><span className="small">Licence</span><b>{b.identity ? 'Checked' : 'To check'}</b></div>
        <div className={b.signed ? 'is-ok' : 'is-bad'}><span className="small">Agreement</span><b>{b.signed ? 'Signed' : 'To sign'}</b></div>
      </div>
      {can.money && b.open_cents > 0 && <section className="fp-card"><button type="button" className={`btn ${open === 'pay' ? 'btn--ghost' : 'btn--primary'} fd-wide`} onClick={() => setOpen(open === 'pay' ? '' : 'pay')} data-testid="help-pay">Take a payment</button>
        {open === 'pay' && <Collect b={b} kind="charge" readers={readers} />}</section>}
      {can.money && depositOpen && <section className="fp-card"><button type="button" className={`btn ${open === 'hold' ? 'btn--ghost' : 'btn--primary'} fd-wide`} onClick={() => setOpen(open === 'hold' ? '' : 'hold')} data-testid="help-hold">Take the deposit hold</button>
        {open === 'hold' && <Collect b={b} kind="hold" readers={readers} />}</section>}
      {can.verifyInPerson && !b.identity && <section className="fp-card" data-testid="help-id"><p className="fp-step__h">Check the licence in person</p>
        <ul className="fp-plan">{b.drivers.map((d) => <li key={d.name}>{d.name}: {d.verified ? 'checked' : 'to check'}</li>)}</ul>
        <p className="small">Take the licence photos with the licence reader, match the name and date of birth, and the person to the photo.</p>
        {b.job ? <Link prefetch={false} className="btn btn--primary fd-wide" href={`/staff/field/jobs/${b.job}`}>Check it on the pickup</Link>
          : <p className="small">This booking is not on your list: ask Fleet to give you its pickup, then check the licence there.</p>}</section>}
      {can.sign && !b.signed && <section className="fp-card" data-testid="help-sign"><p className="fp-step__h">Get the agreement signed</p>
        <Link prefetch={false} className="btn btn--primary fd-wide" href={`/staff/field/help/${b.number}/sign`}>They sign on my phone</Link>
        {b.renter?.mobile && <a className="btn btn--ghost fd-wide" href={`sms:${b.renter.mobile.replace(/[^\d+]/g, '')}?&body=${encodeURIComponent(`CarmaCars: please sign the rental agreement for booking ${b.number} on your booking page: ${typeof window !== 'undefined' ? window.location.origin : ''}/account/bookings/${b.number}`)}`}>Text them the signing link</a>}
        {can.paperSignatures && <p className="small">Paper only as the last resort, as the rules say: the office records it.</p>}</section>}
    </div>
  );
}

export function HelpSearch() {
  const [q, setQ] = useState('');
  const [rows, setRows] = useState<Awaited<ReturnType<typeof helpFind>> | null>(null);
  const [pending, start] = useTransition();
  return (
    <form className="fp-form" onSubmit={(e) => { e.preventDefault(); start(async () => setRows(await helpFind(q))); }} role="search">
      <div className="field"><label className="label" htmlFor="help-q">Booking number, renter&apos;s name or phone</label>
        <input id="help-q" className="input" value={q} onChange={(e) => setQ(e.target.value)} autoComplete="off" data-testid="help-q" /></div>
      <button type="submit" className="btn btn--primary fd-wide" disabled={pending || q.trim().length < 3}><FdIcon name="search" />{pending ? 'Looking' : 'Find the booking'}</button>
      {rows && !rows.ok && <p className="error" role="alert">{rows.message}</p>}
      {rows?.ok && (rows.data.length ? <ul className="fp-results" data-testid="help-results">{rows.data.map((r) => <li key={r.id}><Link prefetch={false} href={`/staff/field/help/${r.number}`}>
        <b>{r.number}: {r.renter ?? 'Renter'}</b><span className="small">{r.vehicle}, {r.status.replace(/_/g, ' ')}{r.mine ? ', on your list' : ''}</span></Link></li>)}</ul>
        : <p className="small">No booking found. Try the booking number.</p>)}
    </form>
  );
}
