'use client';
import { useEffect, useRef, useState } from 'react';
import { money } from '@/lib/format';
import { payLinkFakeConfirm, payLinkFinish, payLinkStart, type PayLinkStart } from '@/server/actions/paylink';

// The card form of a pay link (0129): Stripe's Payment Element in Stripe's own frame (locally, the fake adapter's test
// card form). The result is read again from Stripe on the server and recorded there.
// the portal's PayForm declares window.Stripe; Stripe.js has the setup confirmation too, typed here on its own
interface StripeLink {
  elements(o: { clientSecret: string; appearance?: unknown }): { create(type: 'payment', o?: unknown): { mount(el: HTMLElement): void } };
  confirmPayment(o: { elements: unknown; redirect: 'if_required'; confirmParams: Record<string, unknown> }): Promise<{ error?: { message?: string } }>;
  confirmSetup(o: { elements: unknown; redirect: 'if_required'; confirmParams: Record<string, unknown> }): Promise<{ error?: { message?: string } }>;
}
function loadStripe(key: string): Promise<StripeLink> {
  const w = window as unknown as { Stripe?: (k: string) => unknown };
  return new Promise((resolve, reject) => {
    if (w.Stripe) return resolve(w.Stripe(key) as StripeLink);
    const s = document.createElement('script');
    s.src = 'https://js.stripe.com/v3/';
    s.onload = () => (w.Stripe ? resolve(w.Stripe(key) as StripeLink) : reject(new Error('Stripe did not load')));
    s.onerror = () => reject(new Error('Stripe did not load'));
    document.head.appendChild(s);
  });
}

export function PayLinkForm({ token, kind, amountCents, legalName, backTo = null }: { token: string; kind: 'charge' | 'hold' | 'setup'; amountCents: number; legalName: string; backTo?: string | null }) {
  const [p, setP] = useState<PayLinkStart | null>(null);
  const [fatal, setFatal] = useState<string | null>(null);
  const [name, setName] = useState('');
  const [card, setCard] = useState({ number: '', exp: '', cvc: '' });
  const [msg, setMsg] = useState<string | null>(null);
  // 0213: a card refused (debit or prepaid) leaves the link open with a new authorization: the form loads again
  const [round, setRound] = useState(0);
  const [busy, setBusy] = useState(false);
  const [done, setDone] = useState(false);
  const stripe = useRef<{ js: StripeLink; elements: unknown } | null>(null);
  const mount = useRef<HTMLDivElement>(null);

  useEffect(() => {
    let live = true;
    payLinkStart(token).then(async (r) => {
      if (!live) return;
      if (!r.ok) { setFatal(r.message); return; }
      setP(r.data);
      if (r.data.provider === 'stripe' && r.data.publishableKey && mount.current) {
        const js = await loadStripe(r.data.publishableKey);
        const elements = js.elements({ clientSecret: r.data.clientSecret, appearance: { theme: 'stripe', variables: { colorPrimary: '#D0111B', borderRadius: '6px' } } });
        mount.current.replaceChildren();
        elements.create('payment', { layout: 'tabs', wallets: { applePay: 'auto', googlePay: 'auto' }, fields: { billingDetails: { name: 'never' } } }).mount(mount.current);
        stripe.current = { js, elements };
      }
    }).catch(() => live && setFatal('The card form did not load. Reload the page.'));
    return () => { live = false; };
  }, [token, round]);

  const submit = async (e: React.FormEvent) => {
    e.preventDefault();
    if (!p) return;
    if (!name.trim()) { setMsg('Enter the name on the card.'); return; }
    setBusy(true); setMsg(null);
    try {
      if (p.provider === 'fake') {
        const c = await payLinkFakeConfirm(token, { number: card.number, name, exp: card.exp });
        if (!c.ok) { setMsg(c.message); setBusy(false); return; }
        if (!['succeeded', 'requires_capture'].includes(c.data.status)) { setMsg(c.data.error ?? 'Your card was declined.'); setBusy(false); return; }
      } else if (stripe.current) {
        const params = { elements: stripe.current.elements, redirect: 'if_required' as const, confirmParams: { payment_method_data: { billing_details: { name } }, return_url: location.href } };
        const r = kind === 'setup' ? await stripe.current.js.confirmSetup(params) : await stripe.current.js.confirmPayment(params);
        if (r.error) { setMsg(r.error.message ?? 'Your card was declined.'); setBusy(false); return; }
      }
      const f = await payLinkFinish(token);
      if (f.ok && !f.data.ok && f.data.reason === 'card_not_credit') { setMsg(f.data.message ?? 'Please use a credit card.'); setBusy(false); setRound((x) => x + 1); return; }
      if (!f.ok || !f.data.ok) { setMsg(f.ok ? f.data.reason ?? 'The card was not accepted.' : f.message); setBusy(false); return; }
      setDone(true);
    } catch { setMsg('We could not finish. If your card was charged, we will see it: call us.'); setBusy(false); }
  };

  if (fatal) return <p className="alert alert--error" role="alert"><span>{fatal}</span></p>;
  if (done) return <p className="alert alert--ok" role="status" data-testid="paylink-done"><span className="alert__title">{kind === 'hold' ? 'Hold placed' : kind === 'setup' ? 'Card saved' : 'Paid'}</span><span>Thank you. {kind === 'charge' ? 'Your receipt is on its way by email.' : 'Nothing was charged now.'} You can hand the device back.</span>{backTo && <a className="btn btn--ghost btn--sm" href={backTo} data-testid="paylink-back">Back to the job</a>}</p>;
  return (
    <form className="pt-pay stack" noValidate onSubmit={submit} aria-label="Card" aria-busy={!p || busy}>
      <div className="field"><label className="label" htmlFor="pl-name">Name on the card</label>
        <input className="input" id="pl-name" value={name} onChange={(e) => setName(e.target.value)} autoComplete="cc-name" placeholder={legalName} aria-describedby="pl-name-h" />
        <p className="hint" id="pl-name-h">A credit card in the renter&apos;s name.</p></div>
      {p?.provider === 'fake' ? (
        <div className="pt-cardbox stack" data-testid="fake-card">
          <p className="small muted">Test mode: use a Stripe test card, for example 4242 4242 4242 4242.</p>
          <div className="field"><label className="label" htmlFor="pl-num">Card number</label><input className="input" id="pl-num" inputMode="numeric" autoComplete="cc-number" value={card.number} onChange={(e) => setCard({ ...card, number: e.target.value })} /></div>
          <div className="field-row">
            <div className="field"><label className="label" htmlFor="pl-exp">Expiry (MM / YY)</label><input className="input" id="pl-exp" inputMode="numeric" autoComplete="cc-exp" value={card.exp} onChange={(e) => setCard({ ...card, exp: e.target.value })} /></div>
            <div className="field"><label className="label" htmlFor="pl-cvc">Security code</label><input className="input" id="pl-cvc" inputMode="numeric" autoComplete="cc-csc" value={card.cvc} onChange={(e) => setCard({ ...card, cvc: e.target.value })} /></div>
          </div>
        </div>
      ) : <div className="pt-cardbox" ref={mount} aria-label="Card details">{!p && <div className="skeleton sk-line" aria-hidden="true" />}</div>}
      {msg && <p className="alert alert--error" role="alert" data-testid="paylink-message"><span>{msg}</span></p>}
      <button className="btn btn--primary btn--lg btn--block" type="submit" disabled={!p || busy} data-testid="paylink-submit">{busy ? 'Working' : kind === 'hold' ? `Place the hold of ${money(amountCents, { cents: true })}` : kind === 'setup' ? 'Save the card' : `Pay ${money(amountCents, { cents: true })}`}</button>
    </form>
  );
}
