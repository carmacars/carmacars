'use client';
import { useEffect, useRef, useState } from 'react';
import { useRouter } from 'next/navigation';
import { fakeConfirmCard, finalizePayment, startPayment, type StartedPayment } from '@/server/actions/portal';
import { money } from '@/lib/format';

// The pay step (02 section 6). The card form is Stripe's Payment Element in Stripe's own frame (the card
// number never touches our pages); locally the fake adapter stands in with Stripe's test card numbers.
// The card is authorized here; the server confirms the booking and only then captures.
interface StripeJs {
  elements(o: { clientSecret: string; appearance?: unknown }): { create(type: 'payment', o?: unknown): { mount(el: HTMLElement): void; destroy(): void } };
  confirmPayment(o: { elements: unknown; redirect: 'if_required'; confirmParams: Record<string, unknown> }): Promise<{ error?: { message?: string }; paymentIntent?: { id: string; status: string } }>;
}
declare global { interface Window { Stripe?: (key: string) => StripeJs } }
function loadStripe(key: string): Promise<StripeJs> {
  return new Promise((resolve, reject) => {
    if (window.Stripe) return resolve(window.Stripe(key));
    const s = document.createElement('script');
    s.src = 'https://js.stripe.com/v3/';
    s.onload = () => (window.Stripe ? resolve(window.Stripe(key)) : reject(new Error('Stripe did not load')));
    s.onerror = () => reject(new Error('Stripe did not load'));
    document.head.appendChild(s);
  });
}
const same = (a: string, b: string) => a.replace(/\s+/g, '').toLowerCase() === b.replace(/\s+/g, '').toLowerCase();

export function PayForm({ number, amountCents, depositCents, coverageOption = null }: { number: string; amountCents: number; depositCents: number; coverageOption?: number | null }) {
  const router = useRouter();
  const [p, setP] = useState<StartedPayment | null>(null);
  const [fatal, setFatal] = useState<{ code: string; message: string } | null>(null);
  const [name, setName] = useState('');
  const [card, setCard] = useState({ number: '', exp: '', cvc: '' });
  const [errors, setErrors] = useState<Record<string, string>>({});
  const [msg, setMsg] = useState<{ kind: 'error' | 'wait' | 'pushed'; text: string; coverage?: boolean } | null>(null);
  const [busy, setBusy] = useState(false);
  const stripe = useRef<{ js: StripeJs; elements: unknown } | null>(null);
  const mount = useRef<HTMLDivElement>(null);

  useEffect(() => {
    let live = true;
    startPayment(number).then(async (r) => {
      if (!live) return;
      if (!r.ok) { setFatal({ code: r.code, message: r.message }); return; }
      setP(r.data);
      if (r.data.provider === 'stripe' && r.data.publishableKey && mount.current) {
        const js = await loadStripe(r.data.publishableKey);
        const elements = js.elements({ clientSecret: r.data.clientSecret, appearance: { theme: 'stripe', variables: { colorPrimary: '#D0111B', colorText: '#000000', borderRadius: '6px', fontFamily: 'Inter, Helvetica, Arial, sans-serif' } } });
        elements.create('payment', { layout: 'tabs', wallets: { applePay: 'never', googlePay: 'never' }, fields: { billingDetails: { name: 'never' } }, defaultValues: { billingDetails: { address: { country: 'CA' } } } }).mount(mount.current);
        stripe.current = { js, elements };
      }
    }).catch(() => live && setFatal({ code: 'error', message: 'The payment form did not load. Reload the page.' }));
    return () => { live = false; };
  }, [number]);

  const finish = async (intentId: string) => {
    setMsg({ kind: 'wait', text: 'Card approved. We are finalizing your booking.' });
    const r = await finalizePayment(number, intentId);
    if (r.ok && r.data.ok) { router.push(`/account/bookings/${encodeURIComponent(number)}?paid=1`); return; }
    const text = r.ok ? (r.data as { message: string }).message : r.message;
    const reason = r.ok && !r.data.ok ? r.data.reason : '';
    setMsg({ kind: ['vehicle_taken', 'not_awaiting_payment', 'vehicle_not_bookable', 'offer_changed'].includes(reason) ? 'pushed' : 'error', text, coverage: reason === 'card_not_credit_coverage' });
    setBusy(false);
  };

  const pay = async (e: React.FormEvent) => {
    e.preventDefault();
    if (!p) return;
    const fe: Record<string, string> = {};
    if (!name.trim()) fe.name = 'Enter the name on the card.';
    else if (!same(name, p.legalName)) fe.name = 'The card must be in the renter\'s name.';
    if (p.provider === 'fake') {
      if (card.number.replace(/\D/g, '').length < 13) fe.number = 'Enter the card number.';
      if (!/^\d{2}\s*\/\s*\d{2}$/.test(card.exp)) fe.exp = 'Use MM / YY.';
      if (!/^\d{3,4}$/.test(card.cvc)) fe.cvc = 'Enter the 3 or 4 digits.';
    }
    setErrors(fe);
    if (Object.keys(fe).length) { requestAnimationFrame(() => document.querySelector<HTMLElement>('[aria-invalid="true"]')?.focus()); return; }
    setBusy(true); setMsg(null);
    try {
      if (p.provider === 'fake') {
        const c = await fakeConfirmCard(number, p.intentId, { number: card.number, name, exp: card.exp });
        if (!c.ok) { setMsg({ kind: 'error', text: c.message }); setBusy(false); return; }
        if (c.data.status !== 'requires_capture') { setMsg({ kind: 'error', text: c.data.error ?? 'Your card was declined.' }); setBusy(false); return; }
        await finish(p.intentId);
      } else if (stripe.current) {
        const r = await stripe.current.js.confirmPayment({ elements: stripe.current.elements, redirect: 'if_required', confirmParams: { payment_method_data: { billing_details: { name } }, return_url: `${location.origin}/account/bookings/${encodeURIComponent(number)}/pay` } });
        if (r.error) { setMsg({ kind: 'error', text: r.error.message ?? 'Your card was declined.' }); setBusy(false); return; }
        await finish(r.paymentIntent?.id ?? p.intentId);
      }
    } catch {
      setMsg({ kind: 'wait', text: 'Card approved. We are finalizing your booking. This page will update.' });
      setTimeout(() => router.refresh(), 4000);
    }
  };

  if (fatal) return (
    <div className="pt-card pt-card--next" role="alert">
      <h2 className="d4">{fatal.code === 'pushed_back' ? 'This car was just taken' : fatal.code === 'confirmed' ? 'Already confirmed' : 'Payment not available'}</h2>
      <p>{fatal.message}</p>
      <p><a className="btn btn--primary" href={`/account/bookings/${encodeURIComponent(number)}`}>Back to the booking</a></p>
    </div>
  );
  if (msg?.kind === 'pushed') return (
    <div className="pt-card pt-card--next" role="alert" data-testid="pay-pushed-back">
      <h2 className="d4">Your card was not charged</h2>
      <p>{msg.text}</p>
      <p><a className="btn btn--primary" href={`/account/bookings/${encodeURIComponent(number)}`}>Back to the booking</a></p>
    </div>
  );
  const err = (k: string) => errors[k];
  const input = (k: 'number' | 'exp' | 'cvc', label: string, props: React.InputHTMLAttributes<HTMLInputElement>) => (
    <div className={`field${err(k) ? ' has-error' : ''}`}>
      <label className="label" htmlFor={`pt-card-${k}`}>{label}</label>
      <input className="input" id={`pt-card-${k}`} value={card[k]} onChange={(e) => setCard({ ...card, [k]: e.target.value })} aria-invalid={!!err(k) || undefined} aria-describedby={`pt-card-${k}-err`} {...props} />
      <p className="error" role="alert" id={`pt-card-${k}-err`}>{err(k) ?? ''}</p>
    </div>
  );
  return (
    <form className="pt-pay" noValidate onSubmit={pay} aria-label="Pay for your booking" aria-busy={!p || busy}>
      <div className={`field${err('name') ? ' has-error' : ''}`}>
        <label className="label" htmlFor="pt-card-name">Name on the card</label>
        <input className="input" id="pt-card-name" value={name} onChange={(e) => setName(e.target.value)} autoComplete="cc-name" aria-invalid={!!err('name') || undefined} aria-describedby="pt-card-name-hint pt-card-name-err" />
        <p className="hint" id="pt-card-name-hint">{coverageOption === 2
          ? 'You chose the rental coverage on your credit card: pay with that credit card, in the renter\'s name. Debit and prepaid cards do not qualify.'
          : 'The card must be a credit card in the renter\'s name.'}</p>
        <p className="error" role="alert" id="pt-card-name-err">{err('name') ?? ''}</p>
      </div>
      {p?.provider === 'fake' ? (
        <div className="pt-cardbox" data-testid="fake-card">
          <p className="small muted">Test mode: use a Stripe test card, for example 4242 4242 4242 4242.</p>
          {input('number', 'Card number', { inputMode: 'numeric', autoComplete: 'cc-number', placeholder: '1234 1234 1234 1234' })}
          <div className="field-row">
            {input('exp', 'Expiry (MM / YY)', { inputMode: 'numeric', autoComplete: 'cc-exp', placeholder: 'MM / YY' })}
            {input('cvc', 'Security code', { inputMode: 'numeric', autoComplete: 'cc-csc', placeholder: '123' })}
          </div>
        </div>
      ) : <div className="pt-cardbox" ref={mount} aria-label="Card details">{!p && <div className="skeleton sk-line" aria-hidden="true" />}</div>}
      <p className="small">This card becomes your Card on File for the {money(depositCents)} deposit at pickup and any later charges, as you authorized when signing.</p>
      {msg && <p className={`alert ${msg.kind === 'wait' ? 'alert--warn' : 'alert--error'}`} role={msg.kind === 'wait' ? 'status' : 'alert'} data-testid="pay-message"><span>{msg.text}
        {msg.coverage && <> <a className="link" href={`/account/bookings/${encodeURIComponent(number)}/verify#pt-cov`}>Change how the car is covered</a></>}</span></p>}
      <button className="btn btn--primary btn--lg btn--block" type="submit" disabled={!p || busy}>{busy ? 'Confirming' : `Pay ${money(p?.amountCents ?? amountCents, { cents: true })}`}</button>
      <p className="pt-lock"><svg width="14" height="14" viewBox="0 0 16 16" aria-hidden="true"><path d="M4 7V5a4 4 0 0 1 8 0v2h1v8H3V7zm2 0h4V5a2 2 0 0 0-4 0z" fill="currentColor" /></svg>Your card is authorized now and charged only once your booking is confirmed.</p>
    </form>
  );
}
