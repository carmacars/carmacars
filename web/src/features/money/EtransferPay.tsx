'use client';
import { useId, useRef, useState, useTransition } from 'react';
import { useRouter } from 'next/navigation';
import { money } from '@/lib/format';
import { Icon } from '@/components/Icon';
import { IconSwap } from '@/portable/motion/react';
import { when } from '@/features/agreement/model';
import { renterReportEtransfer } from '@/server/actions/etransfer-renter';
import { coversWords } from './etransfer';
import { amountFor, coversFor, etransferParts, type RenterEtransfer } from './card-pay';
import './etransfer-pay.css';

// Hotfix 3650: the payment box when card payments are paused (Sign and pay, the booking page, a pay link). Always shows:
// 1. the e-Transfer to send (the company e-Transfer email, the booking number as the message, the exact amounts for the
// rental and the deposit, each copied with one tap), 2. the screenshot upload that goes to Finance, who confirm it in
// one tap. Cash at pickup stays where the booking takes cash. Phone first: nothing squeezes at 375px.
const fmt = (c: number) => money(Number(c ?? 0), { cents: true });

function Copy({ text, label }: { text: string; label: string }) {
  const [done, setDone] = useState(false);
  return (
    <button type="button" className="btn btn--quiet btn--sm etp-copy" aria-label={`Copy ${label}`} data-testid={`etp-copy-${label.replace(/\W+/g, '-').toLowerCase()}`}
      onClick={() => { navigator.clipboard?.writeText(text).then(() => { setDone(true); setTimeout(() => setDone(false), 1600); }).catch(() => undefined); }}>
      <IconSwap on={done} first={<Icon name="copy" />} second={<Icon name="check" />} />{done ? 'Copied' : 'Copy'}
    </button>
  );
}

export function EtransferPay({ s, title = 'Pay by e-Transfer', upload = true, signInHref }: { s: RenterEtransfer; title?: string;
  /** false on a pay link opened without signing in: the screenshot is uploaded from the booking instead */ upload?: boolean; signInHref?: string }) {
  const router = useRouter();
  const ids = useId();
  const id = (k: string) => `${ids}-${k}`;
  const parts = etransferParts(s);
  const both = parts.rental > 0 && parts.deposit > 0;
  const [choice, setChoice] = useState<'all' | 'rental' | 'deposit'>('all');
  const [amount, setAmount] = useState(() => (amountFor(parts, 'all') / 100).toFixed(2));
  const [sender, setSender] = useState('');
  const [file, setFile] = useState<File | null>(null);
  const fileRef = useRef<HTMLInputElement>(null);
  const [msg, setMsg] = useState<{ ok: boolean; text: string } | null>(null);
  const [pending, run] = useTransition();
  const email = s.e_transfer_email ?? '';
  const pick = (c: 'all' | 'rental' | 'deposit') => { setChoice(c); setAmount((amountFor(parts, c) / 100).toFixed(2)); };
  const why = !file ? 'Add the screenshot of your e-Transfer' : !(Number(amount) > 0) ? 'Enter the amount you sent' : null;

  const send = () => run(async () => {
    setMsg(null);
    const form = new FormData();
    form.set('booking_number', s.booking_number); form.set('amount', amount); form.set('covers', coversFor(parts, choice)); form.set('sender_name', sender);
    if (file) form.set('proof', file);
    const r = await renterReportEtransfer(form);
    if (!r.ok) { setMsg({ ok: false, text: r.fieldErrors ? Object.values(r.fieldErrors).join(' ') : r.message }); return; }
    setMsg({ ok: true, text: `Thank you. We have your screenshot (${r.data.report_number}) and confirm it as soon as it is in the bank. You will get an email.` });
    setFile(null); if (fileRef.current) fileRef.current.value = '';
    router.refresh();
  });

  if (parts.total <= 0 && parts.cashRental <= 0 && parts.cashDeposit <= 0 && !s.open) return null;
  return (
    <section className="pt-card stack etp" aria-labelledby={id('h')} data-testid="etransfer-pay" data-guide="etransfer-pay">
      <div className="etp__head"><h3 className="d4" id={id('h')}>{title}</h3><span className="etp__chip">Interac e-Transfer</span></div>
      {s.card && !s.card.on && <p className="small muted" data-testid="etp-paused">Card payments are paused for a short while. Paying by e-Transfer confirms your booking the same way.</p>}

      {s.open ? (
        <p className="alert alert--ok" role="status" data-testid="etp-waiting" data-guide="etp-waiting"><span><b>We have your screenshot ({s.open.report_number}).</b> {fmt(s.open.amount_cents)} for {coversWords(s.open.covers)}, sent {when(s.open.reported_at)}. We confirm it as soon as it is in the bank and email you.</span></p>
      ) : (
        <>
          {s.declined && <p className="alert alert--warn" role="alert" data-testid="etp-declined"><span><b>We could not find your e-Transfer of {fmt(s.declined.amount_cents)} yet.</b> {s.declined.reason}. Send it again, or upload a clearer screenshot below.</span></p>}
          {parts.total > 0 && <>
            <ol className="etp__steps">
              <li><b>Send an Interac e-Transfer</b> from your bank&apos;s app.</li>
              <li><b>Upload the screenshot</b> of the confirmation below.</li>
            </ol>
            <dl className="pt-dl etp__dl" data-testid="etp-facts">
              <div><dt>Send to</dt><dd><span className="etp__val" data-testid="etp-email">{email || 'Call us for the e-Transfer email'}</span>{email && <Copy text={email} label="email" />}</dd></div>
              <div><dt>Message</dt><dd><span className="etp__val" data-testid="etp-message">{s.booking_number}</span><Copy text={s.booking_number} label="booking number" /></dd></div>
              {parts.rental > 0 && <div><dt>Rental</dt><dd><span className="etp__val num" data-testid="etp-rental">{fmt(parts.rental)}</span><Copy text={(parts.rental / 100).toFixed(2)} label="rental amount" /></dd></div>}
              {parts.deposit > 0 && <div><dt>Deposit</dt><dd><span className="etp__val num" data-testid="etp-deposit">{fmt(parts.deposit)}</span><Copy text={(parts.deposit / 100).toFixed(2)} label="deposit amount" /></dd></div>}
              {both && <div className="etp__total"><dt>Total</dt><dd><b className="etp__val num" data-testid="etp-total">{fmt(parts.total)}</b><Copy text={(parts.total / 100).toFixed(2)} label="total" /></dd></div>}
            </dl>
            {parts.deposit > 0 && <p className="small" data-testid="etp-deposit-note">The deposit is refundable: we send it back to you by e-Transfer after the trip, less anything owed.{s.deposit_card_cents > 0 && parts.deposit !== s.deposit_card_cents ? ` By e-Transfer it is ${fmt(parts.deposit)} (the card hold would be ${fmt(s.deposit_card_cents)}).` : ''} You can also pay it in cash at pickup instead.</p>}
          </>}
          {parts.cashRental > 0 && <p className="small" data-testid="etp-cash-rental">The rental of {fmt(parts.cashRental)} is paid in cash, as agreed with our team.</p>}
          {parts.cashDeposit > 0 && <p className="small" data-testid="etp-cash-deposit">The refundable deposit of {fmt(parts.cashDeposit)} is paid in cash at pickup and given back in cash.</p>}

          {parts.total > 0 && s.may_report && (upload ? (
            <form className="stack etp__form" noValidate aria-labelledby={id('up')} onSubmit={(e) => { e.preventDefault(); if (!why) send(); }} data-testid="etp-form" data-guide="etp-form">
              <h4 className="etp__sub" id={id('up')}>Sent it? Upload the screenshot</h4>
              {both && (
                <fieldset className="etp__choice">
                  <legend className="label">What you sent</legend>
                  {([['all', `Both, ${fmt(parts.total)}`], ['rental', `The rental, ${fmt(parts.rental)}`], ['deposit', `The deposit, ${fmt(parts.deposit)}`]] as const).map(([v, l]) => (
                    <label key={v} className="radio" htmlFor={id(`c-${v}`)}><input type="radio" id={id(`c-${v}`)} name={id('c')} checked={choice === v} onChange={() => pick(v)} data-testid={`etp-choice-${v}`} /> <span>{l}</span></label>))}
                </fieldset>)}
              <div className="etp__row">
                <div className="field"><label className="label" htmlFor={id('amt')}>Amount sent ($)</label>
                  <input className="input num" id={id('amt')} inputMode="decimal" value={amount} onChange={(e) => setAmount(e.target.value)} data-testid="etp-amount" data-guide="etp-amount" /></div>
                <div className="field"><label className="label" htmlFor={id('who')}>Sent from (optional)</label>
                  <input className="input" id={id('who')} value={sender} onChange={(e) => setSender(e.target.value)} autoComplete="name" placeholder="The name on your bank account" data-testid="etp-sender" /></div>
              </div>
              <div className="field"><label className="label" htmlFor={id('file')}>Screenshot of the e-Transfer</label>
                <input ref={fileRef} className="input etp__file" id={id('file')} type="file" accept="image/jpeg,image/png,application/pdf" onChange={(e) => setFile(e.target.files?.[0] ?? null)} data-testid="etp-file" data-guide="etp-file" />
                <p className="hint">A photo or screenshot of the confirmation (JPG, PNG or PDF, up to 10 MB).</p></div>
              <button className="btn btn--primary btn--lg btn--block etp__go" type="submit" disabled={pending || !!why} aria-busy={pending} title={why ?? undefined} data-testid="etp-send" data-guide="etp-send">{pending ? 'Sending' : 'Send the screenshot'}</button>
              {why && !pending && <p className="small muted" aria-live="polite">{why}.</p>}
            </form>
          ) : (
            <p className="small" data-testid="etp-upload-elsewhere">Sent it? <a className="link" href={signInHref ?? `/account/bookings/${encodeURIComponent(s.booking_number)}/checkout`}>Upload the screenshot on your booking</a>, or reply to our message with it.</p>
          ))}
        </>
      )}
      {msg && <p className={`alert ${msg.ok ? 'alert--ok' : 'alert--error'}`} role={msg.ok ? 'status' : 'alert'} data-testid="etp-message-box"><span>{msg.text}</span></p>}
    </section>
  );
}
