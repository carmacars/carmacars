'use client';
import { useEffect, useRef, useState } from 'react';
import { useRouter } from 'next/navigation';
import { fakeConfirmAddonCard, finalizeAddonPayment, startAddonPayment, type StartedAddonPayment } from '@/server/actions/addon-pay';
import { money } from '@/lib/format';

// The add-on pay page's card form (migration 0079): Stripe's Payment Element in Stripe's own frame; locally the fake
// adapter stands in with Stripe's test card numbers. The card is charged at once for the add-ons due.
interface StripeJs {
  elements(o: { clientSecret: string; appearance?: unknown }): { create(type: 'payment', o?: unknown): { mount(el: HTMLElement): void } };
  confirmPayment(o: { elements: unknown; redirect: 'if_required'; confirmParams: Record<string, unknown> }): Promise<{ error?: { message?: string }; paymentIntent?: { id: string; status: string } }>;
}
function loadStripe(key: string): Promise<StripeJs> {
  const w = window as unknown as { Stripe?: (k: string) => StripeJs };
  return new Promise((resolve, reject) => {
    if (w.Stripe) return resolve(w.Stripe(key));
    const s = document.createElement('script');
    s.src = 'https://js.stripe.com/v3/';
    s.onload = () => (w.Stripe ? resolve(w.Stripe(key)) : reject(new Error('Stripe did not load')));
    s.onerror = () => reject(new Error('Stripe did not load'));
    document.head.appendChild(s);
  });
}

export function AddonPayForm({ number, amountCents }: { number: string; amountCents: number }) {
  const router = useRouter();
  const [p, setP] = useState<StartedAddonPayment | null>(null);
  const [fatal, setFatal] = useState<string | null>(null);
  const [name, setName] = useState('');
  const [card, setCard] = useState({ number: '', exp: '', cvc: '' });
  const [errors, setErrors] = useState<Record<string, string>>({});
  const [msg, setMsg] = useState<{ kind: 'error' | 'wait'; text: string } | null>(null);
  const [busy, setBusy] = useState(false);
  const stripe = useRef<{ js: StripeJs; elements: unknown } | null>(null);
  const mount = useRef<HTMLDivElement>(null);
  const back = `/account/bookings/${encodeURIComponent(number)}`;

  useEffect(() => {
    let live = true;
    startAddonPayment(number).then(async (r) => {
      if (!live) return;
      if (!r.ok) { setFatal(r.message); return; }
      setP(r.data);
      if (r.data.provider === 'stripe' && r.data.publishableKey && mount.current) {
        const js = await loadStripe(r.data.publishableKey);
        const elements = js.elements({ clientSecret: r.data.clientSecret, appearance: { theme: 'stripe', variables: { colorPrimary: '#D0111B', colorText: '#000000', borderRadius: '6px', fontFamily: 'Inter, Helvetica, Arial, sans-serif' } } });
        elements.create('payment', { layout: 'tabs', wallets: { applePay: 'never', googlePay: 'never' }, fields: { billingDetails: { name: 'never' } }, defaultValues: { billingDetails: { address: { country: 'CA' } } } }).mount(mount.current);
        stripe.current = { js, elements };
      }
    }).catch(() => live && setFatal('The payment form did not load. Reload the page.'));
    return () => { live = false; };
  }, [number]);

  const finish = async (intentId: string) => {
    setMsg({ kind: 'wait', text: 'Card approved. We are recording your payment.' });
    const r = await finalizeAddonPayment(number, intentId);
    if (r.ok && r.data.ok) { router.push(`${back}?addons_paid=1`); return; }
    setMsg({ kind: 'error', text: r.ok ? (r.data as { message: string }).message : r.message });
    setBusy(false);
  };

  const pay = async (e: React.FormEvent) => {
    e.preventDefault();
    if (!p) return;
    const fe: Record<string, string> = {};
    if (!name.trim()) fe.name = 'Enter the name on the card.';
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
        const c = await fakeConfirmAddonCard(number, p.intentId, { number: card.number, name, exp: card.exp });
        if (!c.ok) { setMsg({ kind: 'error', text: c.message }); setBusy(false); return; }
        if (c.data.status !== 'succeeded') { setMsg({ kind: 'error', text: c.data.error ?? 'Your card was declined.' }); setBusy(false); return; }
        await finish(p.intentId);
      } else if (stripe.current) {
        const r = await stripe.current.js.confirmPayment({ elements: stripe.current.elements, redirect: 'if_required', confirmParams: { payment_method_data: { billing_details: { name } }, return_url: `${location.origin}${back}/addons/pay` } });
        if (r.error) { setMsg({ kind: 'error', text: r.error.message ?? 'Your card was declined.' }); setBusy(false); return; }
        await finish(r.paymentIntent?.id ?? p.intentId);
      }
    } catch {
      setMsg({ kind: 'wait', text: 'Card approved. We are recording your payment. This page will update.' });
      setTimeout(() => router.refresh(), 4000);
    }
  };

  if (fatal) return (
    <div className="pt-card pt-card--next" role="alert" data-testid="addon-pay-fatal">
      <h2 className="d4">Nothing to pay</h2><p>{fatal}</p>
      <p><a className="btn btn--primary" href={back}>Back to the booking</a></p>
    </div>
  );
  const input = (k: 'number' | 'exp' | 'cvc', label: string, props: React.InputHTMLAttributes<HTMLInputElement>) => (
    <div className={`field${errors[k] ? ' has-error' : ''}`}>
      <label className="label" htmlFor={`ap-card-${k}`}>{label}</label>
      <input className="input" id={`ap-card-${k}`} value={card[k]} onChange={(e) => setCard({ ...card, [k]: e.target.value })} aria-invalid={!!errors[k] || undefined} aria-describedby={`ap-card-${k}-err`} {...props} />
      <p className="error" role="alert" id={`ap-card-${k}-err`}>{errors[k] ?? ''}</p>
    </div>
  );
  return (
    <form className="pt-pay" noValidate onSubmit={pay} aria-label="Pay for your add-ons" aria-busy={!p || busy} data-testid="addon-pay-form">
      <div className={`field${errors.name ? ' has-error' : ''}`}>
        <label className="label" htmlFor="ap-card-name">Name on the card</label>
        <input className="input" id="ap-card-name" value={name} onChange={(e) => setName(e.target.value)} autoComplete="cc-name" aria-invalid={!!errors.name || undefined} aria-describedby="ap-card-name-err" />
        <p className="error" role="alert" id="ap-card-name-err">{errors.name ?? ''}</p>
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
      {msg && <p className={`alert ${msg.kind === 'wait' ? 'alert--warn' : 'alert--error'}`} role={msg.kind === 'wait' ? 'status' : 'alert'} data-testid="addon-pay-message"><span>{msg.text}</span></p>}
      <button className="btn btn--primary btn--lg btn--block" type="submit" disabled={!p || busy} data-testid="addon-pay-submit">{busy ? 'Paying' : `Pay ${money(p?.amountCents ?? amountCents, { cents: true })}`}</button>
      <p className="pt-lock"><svg width="14" height="14" viewBox="0 0 16 16" aria-hidden="true"><path d="M4 7V5a4 4 0 0 1 8 0v2h1v8H3V7zm2 0h4V5a2 2 0 0 0-4 0z" fill="currentColor" /></svg>Charged now for the add-ons listed. This card is not kept for later charges.</p>
    </form>
  );
}
