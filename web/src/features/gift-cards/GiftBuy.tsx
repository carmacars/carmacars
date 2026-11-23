'use client';
import { useEffect, useRef, useState } from 'react';
import { useRouter } from 'next/navigation';
import Link from '@/components/Link';
import { money } from '@/lib/format';
import { loadStripe, mountCard, type StripeJs } from '@/lib/stripe-js';
import { reloadIfStale } from '@/lib/client-error/recover';
import { playMoment } from '@/features/motion/moment';
import { fakeConfirmGift, finishGiftPurchase, giftRentalPrice, startGiftPurchase, type StartedGift } from '@/server/actions/gift-cards';
import { amountProblem, emailOk, parseDollars, sendDateProblem, type GiftFacts } from './model';
import { GiftCardFace } from './GiftCardFace';
import './gift-cards.css';

// The gift card form of /gift-cards (migration 3600): a gift card (an amount) or a gifted rental (a car and days, priced
// with the site's own quote), who it is for, a message and the day it is emailed; then the card in Stripe's own frame,
// charged at once. Signed in only: a visitor fills the form, signs in and comes back to it (kept in this tab).
type Kind = 'purchased' | 'gifted_rental';
interface Draft { kind: Kind; choice: string; typed: string; car: string; days: string; name: string; email: string; message: string; sendOn: string; from: string }
const KEY = 'cc-gift-draft';

export function GiftBuy({ facts, signedIn, buyerName, today }: { facts: GiftFacts; signedIn: boolean; buyerName: string; today: string }) {
  const [d, setD] = useState<Draft>({ kind: 'purchased', choice: String(facts.presets_cents[1] ?? facts.presets_cents[0] ?? 10000), typed: '', car: facts.cars[0]?.vehicle_id ?? '', days: '3', name: '', email: '', message: '', sendOn: '', from: buyerName });
  const router = useRouter();
  const [price, setPrice] = useState<{ key: string; cents: number | null }>({ key: '', cents: null });
  const [errors, setErrors] = useState<Record<string, string>>({});
  const [msg, setMsg] = useState<{ kind: 'error' | 'wait'; text: string } | null>(null);
  const [busy, setBusy] = useState(false);
  const [pay, setPay] = useState<StartedGift | null>(null);
  const [done, setDone] = useState<{ token?: string } | null>(null);
  const [cardName, setCardName] = useState('');
  const [card, setCard] = useState({ number: '', exp: '', cvc: '' });
  const stripe = useRef<{ js: StripeJs; elements: unknown } | null>(null);
  const mount = useRef<HTMLDivElement>(null);
  const set = <K extends keyof Draft>(k: K, v: Draft[K]) => setD((x) => ({ ...x, [k]: v }));

  // the form a visitor filled before signing in comes back
  useEffect(() => {
    let saved: Partial<Draft> | null = null;
    try { saved = JSON.parse(sessionStorage.getItem(KEY) ?? 'null') as Partial<Draft> | null; } catch { /* storage off */ }
    if (saved) void Promise.resolve().then(() => setD((x) => ({ ...x, ...saved, from: saved.from || x.from })));
  }, []);
  useEffect(() => { try { sessionStorage.setItem(KEY, JSON.stringify(d)); } catch { /* storage off */ } }, [d]);

  // the gifted rental's price, for the car and days chosen
  const priceKey = d.kind === 'gifted_rental' && d.car ? `${d.car}:${d.days}` : '';
  useEffect(() => {
    if (!priceKey) return;
    let live = true;
    const [car, days] = priceKey.split(':');
    giftRentalPrice(car!, Number(days)).then((r) => { if (live) setPrice({ key: priceKey, cents: r.ok ? r.data?.amount_cents ?? null : null }); }).catch(() => live && setPrice({ key: priceKey, cents: null }));
    return () => { live = false; };
  }, [priceKey]);
  const pricing = !!priceKey && price.key !== priceKey;

  const amount = d.kind === 'gifted_rental' ? (pricing ? null : price.cents) : d.choice === 'custom' ? parseDollars(d.typed) : Number(d.choice);
  const carName = facts.cars.find((c) => c.vehicle_id === d.car)?.name ?? '';
  const rentalText = d.kind === 'gifted_rental' && carName ? `${d.days} ${d.days === '1' ? 'day' : 'days'} in the ${carName}` : null;

  const check = (): Record<string, string> => {
    const fe: Record<string, string> = {};
    if (d.kind === 'purchased') { const a = amountProblem(amount ?? null, facts.min_cents, facts.max_cents); if (a) fe.amount = a; }
    else if (!amount) fe.vehicle = 'This car cannot be priced for those days. Pick another, or choose an amount.';
    else if (amount > facts.max_cents) fe.vehicle = `A gifted rental is ${money(facts.max_cents)} at most online. Choose fewer days.`;
    if (!d.name.trim()) fe.name = 'Enter the recipient\'s name.';
    if (!emailOk(d.email)) fe.email = 'Enter the recipient\'s email.';
    const w = sendDateProblem(d.sendOn, today); if (w) fe.sendOn = w;
    return fe;
  };

  const next = async (e: React.FormEvent) => {
    e.preventDefault();
    const fe = check();
    setErrors(fe);
    if (Object.keys(fe).length) { requestAnimationFrame(() => document.querySelector<HTMLElement>('.gc-buy [aria-invalid="true"]')?.focus()); return; }
    if (!signedIn) { router.push(`/sign-in?next=${encodeURIComponent('/gift-cards#buy')}`); return; }
    setBusy(true); setMsg(null);
    try {
      const r = await startGiftPurchase({ kind: d.kind, amount_cents: d.kind === 'purchased' ? amount : null, vehicle_id: d.kind === 'gifted_rental' ? d.car : null, days: d.kind === 'gifted_rental' ? Number(d.days) : null,
        recipient_name: d.name, recipient_email: d.email, message: d.message, send_on: d.sendOn, buyer_name: d.from });
      if (!r.ok) { setErrors(r.fieldErrors ? { ...r.fieldErrors, ...(r.fieldErrors.recipient_name ? { name: r.fieldErrors.recipient_name } : {}), ...(r.fieldErrors.recipient_email ? { email: r.fieldErrors.recipient_email } : {}) } : {}); setMsg({ kind: 'error', text: r.message }); setBusy(false); return; }
      setPay(r.data);
      setBusy(false);
    } catch (err) { if (!reloadIfStale(err)) { setMsg({ kind: 'error', text: 'Something went wrong. Please try again.' }); setBusy(false); } }
  };

  // the card form, once the order exists
  useEffect(() => {
    if (!pay || pay.provider !== 'stripe' || !pay.publishableKey || !mount.current) return;
    let live = true;
    loadStripe(pay.publishableKey).then((js) => { if (live && mount.current) stripe.current = { js, elements: mountCard(js, pay.clientSecret, mount.current) }; })
      .catch(() => live && setMsg({ kind: 'error', text: 'The card form did not load. Reload the page.' }));
    return () => { live = false; };
  }, [pay]);

  const finish = async (intentId: string) => {
    if (!pay) return;
    setMsg({ kind: 'wait', text: 'Card approved. We are sending your gift card.' });
    const r = await finishGiftPurchase(pay.id, intentId);
    if (r.ok && r.data.ok) {
      try { sessionStorage.removeItem(KEY); } catch { /* storage off */ }
      setDone({ token: r.data.view_token }); setMsg(null); playMoment('offer');
      requestAnimationFrame(() => document.getElementById('gc-done-h')?.focus());
      return;
    }
    setMsg({ kind: 'error', text: r.ok ? (r.data as { message: string }).message : r.message });
    setBusy(false);
  };

  const charge = async (e: React.FormEvent) => {
    e.preventDefault();
    if (!pay) return;
    const fe: Record<string, string> = {};
    if (!cardName.trim()) fe.cardName = 'Enter the name on the card.';
    if (pay.provider === 'fake') {
      if (card.number.replace(/\D/g, '').length < 13) fe.number = 'Enter the card number.';
      if (!/^\d{2}\s*\/\s*\d{2}$/.test(card.exp)) fe.exp = 'Use MM / YY.';
      if (!/^\d{3,4}$/.test(card.cvc)) fe.cvc = 'Enter the 3 or 4 digits.';
    }
    setErrors(fe);
    if (Object.keys(fe).length) return;
    setBusy(true); setMsg(null);
    try {
      if (pay.provider === 'fake') {
        const c = await fakeConfirmGift(pay.id, pay.intentId, { number: card.number, name: cardName, exp: card.exp });
        if (!c.ok) { setMsg({ kind: 'error', text: c.message }); setBusy(false); return; }
        if (c.data.status !== 'succeeded') { setMsg({ kind: 'error', text: c.data.error ?? 'Your card was declined.' }); setBusy(false); return; }
        await finish(pay.intentId);
      } else if (stripe.current) {
        const r = await stripe.current.js.confirmPayment({ elements: stripe.current.elements, redirect: 'if_required', confirmParams: { payment_method_data: { billing_details: { name: cardName } }, return_url: `${location.origin}/gift-cards?paid=${pay.id}` } });
        if (r.error) { setMsg({ kind: 'error', text: r.error.message ?? 'Your card was declined.' }); setBusy(false); return; }
        await finish(r.paymentIntent?.id ?? pay.intentId);
      }
    } catch {
      setMsg({ kind: 'wait', text: 'Card approved. Your receipt is on its way by email.' });
    }
  };

  const err = (k: string) => errors[k];
  const field = (k: keyof Draft, label: string, props: React.InputHTMLAttributes<HTMLInputElement>, hint?: string) => (
    <div className={`field${err(k) ? ' has-error' : ''}`}>
      <label className="label" htmlFor={`gc-${k}`}>{label}</label>
      <input className="input" id={`gc-${k}`} value={String(d[k])} onChange={(e) => set(k, e.target.value as never)} aria-invalid={!!err(k) || undefined} aria-describedby={`gc-${k}-err${hint ? ` gc-${k}-hint` : ''}`} {...props} />
      {hint && <p className="hint" id={`gc-${k}-hint`}>{hint}</p>}
      <p className="error" role="alert" id={`gc-${k}-err`}>{err(k) ?? ''}</p>
    </div>
  );
  const cardField = (k: 'number' | 'exp' | 'cvc', label: string, props: React.InputHTMLAttributes<HTMLInputElement>) => (
    <div className={`field${err(k) ? ' has-error' : ''}`}>
      <label className="label" htmlFor={`gc-card-${k}`}>{label}</label>
      <input className="input" id={`gc-card-${k}`} value={card[k]} onChange={(e) => setCard({ ...card, [k]: e.target.value })} aria-invalid={!!err(k) || undefined} aria-describedby={`gc-card-${k}-err`} {...props} />
      <p className="error" role="alert" id={`gc-card-${k}-err`}>{err(k) ?? ''}</p>
    </div>
  );

  const face = <GiftCardFace amountCents={amount ?? null} to={d.name || 'Your recipient'} kindLabel={d.kind === 'gifted_rental' ? 'Gifted rental' : 'Gift card'} code={null} />;
  if (done) return (
    <section className="pt-card gc-done" aria-labelledby="gc-done-h" data-testid="gift-done">
      {face}
      <h2 className="d3" id="gc-done-h" tabIndex={-1}>Your gift is paid</h2>
      <p>{d.sendOn && d.sendOn > today ? `We email it to ${d.name} on the day you chose.` : `We emailed it to ${d.name} just now.`} Your receipt is on its way to you.</p>
      <div className="row">
        {done.token && <Link prefetch={false} className="btn btn--ghost" href={`/gift-cards/card/${done.token}`} data-testid="gift-print">Print the card</Link>}
        <Link prefetch={false} className="btn btn--primary" href="/account/gift-cards">See my gift cards</Link>
      </div>
    </section>
  );

  return (
    <div className="gc-buy" id="buy">
      {!pay ? (
        <form className="gc-buy__form pt-card" noValidate onSubmit={next} aria-label="Gift card details" data-testid="gift-form">
          <fieldset className="gc-kinds" aria-label="What to give">
            <label className="option"><input type="radio" name="gc-kind" checked={d.kind === 'purchased'} onChange={() => set('kind', 'purchased')} data-testid="gift-kind-card" />
              <span className="option__title">A gift card</span><span className="option__body">An amount for any rental. It never expires.</span></label>
            <label className="option"><input type="radio" name="gc-kind" checked={d.kind === 'gifted_rental'} onChange={() => set('kind', 'gifted_rental')} disabled={!facts.cars.length} data-testid="gift-kind-rental" />
              <span className="option__title">A gifted rental</span><span className="option__body">A car for a number of days, as a credit in their account.</span></label>
          </fieldset>
          {d.kind === 'purchased' ? (
            <fieldset className={`field${err('amount') ? ' has-error' : ''}`} aria-describedby="gc-amount-err">
              <legend className="label">Amount</legend>
              <div className="gc-amounts">
                {facts.presets_cents.map((c) => <label key={c}><input type="radio" name="gc-amt" checked={d.choice === String(c)} onChange={() => set('choice', String(c))} data-testid={`gift-amount-${c}`} />{money(c)}</label>)}
                <label><input type="radio" name="gc-amt" checked={d.choice === 'custom'} onChange={() => set('choice', 'custom')} data-testid="gift-amount-custom" />Other</label>
              </div>
              {d.choice === 'custom' && <div className="field"><label className="label" htmlFor="gc-typed">Your amount ($)</label>
                <input className="input" id="gc-typed" inputMode="decimal" value={d.typed} onChange={(e) => set('typed', e.target.value)} placeholder={`${facts.min_cents / 100} to ${facts.max_cents / 100}`} aria-invalid={!!err('amount') || undefined} data-testid="gift-amount-typed" /></div>}
              <p className="error" role="alert" id="gc-amount-err">{err('amount') ?? ''}</p>
            </fieldset>
          ) : (
            <div className="field-row">
              <div className={`field${err('vehicle') ? ' has-error' : ''}`}>
                <label className="label" htmlFor="gc-car">Car</label>
                <select className="select" id="gc-car" value={d.car} onChange={(e) => set('car', e.target.value)} aria-invalid={!!err('vehicle') || undefined} aria-describedby="gc-car-err" data-testid="gift-car">
                  {facts.cars.map((c) => <option key={c.vehicle_id} value={c.vehicle_id}>{c.name}</option>)}
                </select>
                <p className="error" role="alert" id="gc-car-err">{err('vehicle') ?? ''}</p>
              </div>
              <div className="field">
                <label className="label" htmlFor="gc-days">Days</label>
                <select className="select" id="gc-days" value={d.days} onChange={(e) => set('days', e.target.value)} data-testid="gift-days">
                  {Array.from({ length: facts.rental_max_days }, (_, i) => String(i + 1)).map((n) => <option key={n} value={n}>{n} {n === '1' ? 'day' : 'days'}</option>)}
                </select>
              </div>
            </div>
          )}
          {field('name', 'Their name', { autoComplete: 'off', maxLength: 120, 'data-testid': 'gift-to-name' } as React.InputHTMLAttributes<HTMLInputElement>)}
          {field('email', 'Their email', { type: 'email', inputMode: 'email', autoComplete: 'off', maxLength: 200, 'data-testid': 'gift-to-email' } as React.InputHTMLAttributes<HTMLInputElement>, d.kind === 'gifted_rental' ? 'A gifted rental can be used only by the account with this email.' : 'We email the gift card here.')}
          <div className={`field${err('message') ? ' has-error' : ''}`}>
            <label className="label" htmlFor="gc-message">Message (optional)</label>
            <textarea className="textarea" id="gc-message" rows={3} maxLength={500} value={d.message} onChange={(e) => set('message', e.target.value)} data-testid="gift-message" aria-describedby="gc-message-count" />
            <span className="gc-counter" id="gc-message-count" aria-live="polite">{d.message.length} / 500</span>
          </div>
          <div className="field-row">
            {field('sendOn', 'Send it on (optional)', { type: 'date', min: today, 'data-testid': 'gift-send-on' } as React.InputHTMLAttributes<HTMLInputElement>, 'Empty: we email it as soon as it is paid.')}
            {field('from', 'From', { autoComplete: 'name', maxLength: 120, 'data-testid': 'gift-from' } as React.InputHTMLAttributes<HTMLInputElement>, 'The name they see on the gift.')}
          </div>
          {msg && <p className={`alert ${msg.kind === 'wait' ? 'alert--warn' : 'alert--error'}`} role="alert" data-testid="gift-form-message"><span>{msg.text}</span></p>}
          <button className="btn btn--primary btn--lg btn--block" type="submit" disabled={busy || (d.kind === 'gifted_rental' && pricing)} aria-busy={busy} data-testid="gift-continue">
            {busy ? 'Getting the card form' : signedIn ? `Continue to pay ${amount ? money(amount, { cents: true }) : ''}`.trim() : 'Sign in to continue'}</button>
          {!signedIn && <p className="small muted">You sign in or create your account first, then come back here: what you typed is kept.</p>}
        </form>
      ) : (
        <form className="gc-buy__form pt-card gc-cardform" noValidate onSubmit={charge} aria-label="Pay for the gift card" aria-busy={busy} data-testid="gift-pay-form" translate="no">
          <h2 className="d4">Pay {money(pay.amountCents, { cents: true })}</h2>
          <div className={`field${err('cardName') ? ' has-error' : ''}`}>
            <label className="label" htmlFor="gc-card-name">Name on the card</label>
            <input className="input" id="gc-card-name" value={cardName} onChange={(e) => setCardName(e.target.value)} autoComplete="cc-name" aria-invalid={!!err('cardName') || undefined} aria-describedby="gc-card-name-err" />
            <p className="error" role="alert" id="gc-card-name-err">{err('cardName') ?? ''}</p>
          </div>
          {pay.provider === 'fake' ? (
            <div className="gc-stripe" data-testid="fake-card">
              <p className="small muted">Test mode: use a Stripe test card, for example 4242 4242 4242 4242.</p>
              {cardField('number', 'Card number', { inputMode: 'numeric', autoComplete: 'cc-number', placeholder: '1234 1234 1234 1234' })}
              <div className="field-row">
                {cardField('exp', 'Expiry (MM / YY)', { inputMode: 'numeric', autoComplete: 'cc-exp', placeholder: 'MM / YY' })}
                {cardField('cvc', 'Security code', { inputMode: 'numeric', autoComplete: 'cc-csc', placeholder: '123' })}
              </div>
            </div>
          ) : <div className="gc-stripe" ref={mount} role="group" aria-label="Card details"><div className="skeleton sk-line" aria-hidden="true" /></div>}
          {msg && <p className={`alert ${msg.kind === 'wait' ? 'alert--warn' : 'alert--error'}`} role={msg.kind === 'wait' ? 'status' : 'alert'} data-testid="gift-pay-message"><span>{msg.text}</span></p>}
          <button className="btn btn--primary btn--lg btn--block" type="submit" disabled={busy} aria-busy={busy} data-testid="gift-pay">{busy ? 'Paying' : `Pay ${money(pay.amountCents, { cents: true })}`}</button>
          <button className="btn btn--quiet btn--block" type="button" onClick={() => { setPay(null); setMsg(null); }} disabled={busy}>Change the gift</button>
          <p className="small muted">Charged now. No HST on a gift card: HST is in the rental it pays for.</p>
        </form>
      )}
      <aside className="gc-buy__aside" aria-label="Your gift">
        {face}
        <dl className="gc-facts">
          {rentalText && <div><dt>Rental</dt><dd>{rentalText}</dd></div>}
          <div><dt>Delivery</dt><dd>{d.sendOn && d.sendOn > today ? new Date(`${d.sendOn}T12:00:00Z`).toLocaleDateString('en-CA', { weekday: 'short', month: 'short', day: 'numeric', timeZone: 'UTC' }) : 'By email, when paid'}</dd></div>
        </dl>
        <div className="gc-total"><span>Total</span><b data-testid="gift-total">{amount ? money(amount, { cents: true }) : d.kind === 'gifted_rental' && pricing ? 'Pricing' : '$0.00'}</b></div>
      </aside>
    </div>
  );
}
