'use client';
import { useState, useTransition } from 'react';
import { useRouter } from 'next/navigation';
import { money } from '@/lib/format';
import { applyGiftCard, claimGiftCard, payWithGiftCards, removeGiftCard } from '@/server/actions/gift-cards';
import { playMoment } from '@/features/motion/moment';
import { PayForm } from '@/features/portal/PayForm';
import { BLOCKED_TEXT, applicable, giftLine, type BookingGiftState } from './model';
import './gift-cards.css';

// Sign and pay with gift cards (migration 3600): the balance is used before the card. The renter applies a card (all it
// can pay, or less), removes it, or adds a code first; the card form below then asks only for what is left, and when the
// gift cards pay all of it the booking is confirmed with one button (a saved card stays for the deposit at pickup).
export function GiftPay({ number, state, depositCents, coverageOption, debitOk }: { number: string; state: BookingGiftState | null; depositCents: number; coverageOption: number | null; debitOk: boolean }) {
  const router = useRouter();
  const [s, setS] = useState(state);
  const [msg, setMsg] = useState<{ kind: 'error' | 'ok'; text: string } | null>(null);
  const [code, setCode] = useState('');
  const [adding, setAdding] = useState(false);
  const [busy, setBusy] = useState<string | null>(null);
  const [, start] = useTransition();
  const fmt = (c: number) => money(c, { cents: true });

  const after = (r: { ok: true; data: BookingGiftState } | { ok: false; message: string }, ok?: string) => {
    setBusy(null);
    if (!r.ok) { setMsg({ kind: 'error', text: r.message }); return; }
    setS(r.data); setMsg(ok ? { kind: 'ok', text: ok } : null);
    start(() => router.refresh());
  };
  const apply = async (id: string) => { setBusy(id); setMsg(null); after(await applyGiftCard(number, id), 'Applied. Your card pays only what is left.'); };
  const remove = async (id: string) => { setBusy(id); setMsg(null); after(await removeGiftCard(number, id), 'Removed. The balance is back on your gift card.'); };
  const add = async (e: React.FormEvent) => {
    e.preventDefault();
    setBusy('add'); setMsg(null);
    const r = await claimGiftCard(code);
    if (!r.ok) { setBusy(null); setMsg({ kind: 'error', text: r.message }); return; }
    setCode(''); setAdding(false);
    after(await applyGiftCard(number, r.data.card.id), 'Added and applied.');
  };
  const payAll = async () => {
    setBusy('pay'); setMsg(null);
    const r = await payWithGiftCards(number);
    if (r.ok && r.data.ok) { playMoment('confirmed'); router.push(`/account/bookings/${encodeURIComponent(number)}?paid=1`); return; }
    setBusy(null);
    setMsg({ kind: 'error', text: r.ok ? r.data.message ?? 'Not confirmed. Please try again or call us.' : r.message });
  };

  const card = <PayForm key={s?.applied_cents ?? 0} number={number} amountCents={s?.card_due_cents ?? 0} depositCents={depositCents} coverageOption={coverageOption} debitOk={debitOk} />;
  if (!s) return card;
  const open = s.cards.filter((c) => !s.applications.some((a) => a.gift_card_id === c.id));
  const covered = s.applied_cents > 0 && s.card_due_cents <= 0;
  const showBox = !s.blocked || s.applications.length > 0 || s.cards.length > 0;

  return (
    <div className="stack">
      {showBox && (
        <section className="gc-pay" aria-labelledby="gc-pay-h" data-testid="gift-pay-box">
          <div className="gc-pay__head">
            <h4 className="gc-pay__title" id="gc-pay-h">Gift cards</h4>
            {s.applied_cents > 0 && <span className="gc-pay__applied num" data-testid="gift-applied">−{fmt(s.applied_cents)}</span>}
          </div>
          {s.blocked ? <p className="small muted" data-testid="gift-blocked">{BLOCKED_TEXT[s.blocked]}</p> : <>
            {s.applications.length > 0 && (
              <ul className="gc-pay__list" aria-label="Applied">
                {s.applications.map((a) => (
                  <li key={a.id} className="gc-pay__row" data-state="applied">
                    <span className="gc-pay__card">Card ending <b>{a.code_last4}</b></span>
                    <span className="gc-pay__amt num">−{fmt(a.amount_cents)}</span>
                    <button type="button" className="btn btn--quiet btn--sm" onClick={() => remove(a.id)} disabled={!!busy} aria-busy={busy === a.id} data-testid="gift-remove">{busy === a.id ? 'Removing' : 'Remove'}</button>
                  </li>))}
              </ul>)}
            {open.length > 0 && (
              <ul className="gc-pay__list" aria-label="Your gift cards">
                {open.map((c) => {
                  const can = applicable(s, c.balance_cents);
                  return (
                    <li key={c.id} className="gc-pay__row">
                      <span className="gc-pay__card">{c.kind_label} ending <b>{c.code_last4}</b><small>{fmt(c.balance_cents)} balance{c.rental_text ? `, ${c.rental_text}` : ''}</small></span>
                      <button type="button" className="btn btn--ghost btn--sm" onClick={() => apply(c.id)} disabled={!!busy || can <= 0} aria-busy={busy === c.id} title="Nothing is left to pay with this card" data-testid="gift-apply">
                        {busy === c.id ? 'Applying' : can > 0 ? `Use ${fmt(can)}` : 'Nothing left to pay'}</button>
                    </li>);
                })}
              </ul>)}
            {adding ? (
              <form className="gc-pay__add" onSubmit={add} noValidate>
                <div className="field"><label className="label" htmlFor="gc-code">Gift card code</label>
                  <input className="input gc-code-input" id="gc-code" value={code} onChange={(e) => setCode(e.target.value)} placeholder="CCGC-XXXX-XXXX-XXXX" autoComplete="off" autoCapitalize="characters" spellCheck={false} enterKeyHint="go" data-testid="gift-code" /></div>
                <button className="btn btn--primary btn--sm" type="submit" disabled={!code.trim() || !!busy} aria-busy={busy === 'add'} title="Type your gift card code first" data-testid="gift-code-add">{busy === 'add' ? 'Adding' : 'Add and use'}</button>
              </form>
            ) : <button type="button" className="link gc-pay__more" onClick={() => setAdding(true)} data-testid="gift-code-open">Have a gift card code?</button>}
            <p className="small" data-testid="gift-line">{giftLine(s, fmt) || 'The balance of a gift card is used before your card. It never pays the deposit.'}</p>
            {!s.has_saved_card && s.min_card_cents > 0 && open.length + s.applications.length > 0 && <p className="small muted">At least {fmt(s.min_card_cents)} is paid by card: that saves the card for the {money(depositCents)} deposit held at pickup.</p>}
          </>}
          {msg && <p className={`alert ${msg.kind === 'ok' ? 'alert--ok' : 'alert--error'}`} role={msg.kind === 'ok' ? 'status' : 'alert'} data-testid="gift-message"><span>{msg.text}</span></p>}
        </section>)}
      {covered ? (
        <div className="stack" data-testid="gift-covered">
          <p className="small">Your saved card is kept for the {money(depositCents)} refundable deposit, held on the day of pickup.</p>
          <button type="button" className="btn btn--primary btn--lg btn--block" onClick={payAll} disabled={!!busy} aria-busy={busy === 'pay'} data-testid="gift-pay-all">{busy === 'pay' ? 'Confirming' : `Confirm with gift cards, ${fmt(s.applied_cents)}`}</button>
        </div>
      ) : card}
    </div>
  );
}
