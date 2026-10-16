'use client';
import { useEffect, useRef, useState } from 'react';
import { useRouter } from 'next/navigation';
import { money } from '@/lib/format';
import { fakeConfirmInvoiceCard, fakeConfirmInvoiceDebit, finalizeInvoicePayment, startInvoicePayment } from '@/server/actions/owner';
import type { StartedInvoicePayment } from '@/server/owner/payment';
import type { DebitTerms } from './types';
import { mandateText, payeeRows } from './mandate.ts';

export { mandateText, payeeRows };

// Paying an owner invoice: by card, or by Canadian pre-authorized debit. Card numbers and bank
// details go into Stripe's own forms (the Payment Element, and Stripe's bank and mandate form for
// the debit); locally the fake adapter stands in with Stripe's test numbers. The method used is
// saved for the monthly fees on the 15th.
interface Elements { create(type: 'payment', o?: unknown): { mount(el: HTMLElement): void; destroy(): void } }
interface StripeJs {
  elements(o: { clientSecret: string; appearance?: unknown }): Elements;
  confirmPayment(o: { elements: unknown; redirect: 'if_required'; confirmParams: Record<string, unknown> }): Promise<{ error?: { message?: string }; paymentIntent?: { id: string; status: string } }>;
  confirmAcssDebitPayment(secret: string, o: { payment_method: { billing_details: { name: string; email: string } } }): Promise<{ error?: { message?: string }; paymentIntent?: { id: string; status: string } }>;
}
function loadStripe(key: string): Promise<StripeJs> {
  return new Promise((resolve, reject) => {
    const w = window as unknown as { Stripe?: (k: string) => StripeJs };
    if (w.Stripe) return resolve(w.Stripe(key));
    const s = document.createElement('script');
    s.src = 'https://js.stripe.com/v3/';
    s.onload = () => (w.Stripe ? resolve(w.Stripe(key)) : reject(new Error('Stripe did not load')));
    s.onerror = () => reject(new Error('Stripe did not load'));
    document.head.appendChild(s);
  });
}

export function MandateBlock({ kind, terms, withInvoice, id }: { kind: 'personal' | 'business'; terms: DebitTerms; withInvoice: boolean; id: string }) {
  return (
    <section className="ow-mandate" aria-labelledby={id} tabIndex={0} data-testid="pad-agreement">
      <h3 id={id}>Pre-authorized debit agreement ({kind})</h3>
      {mandateText(kind, terms, withInvoice).map((t, i) => <p key={i}>{t}</p>)}
      <dl className="ow-payee" data-testid="pad-payee">{payeeRows(terms).map(([k, v]) => <div key={k}><dt>{k}</dt><dd>{v}</dd></div>)}</dl>
    </section>
  );
}

type Method = 'card' | 'acss_debit';

export function OwnerPayForm({ number, amountCents, ownerType, hasDebit, terms }: { number: string; amountCents: number; ownerType: 'individual' | 'corporation'; hasDebit: boolean; terms: DebitTerms }) {
  const router = useRouter();
  const [method, setMethod] = useState<Method | null>(null);
  const [p, setP] = useState<StartedInvoicePayment | null>(null);
  const [card, setCard] = useState({ name: '', number: '', exp: '', cvc: '' });
  const [bank, setBank] = useState({ name: '', institution: '', transit: '', account: '' });
  const [agree, setAgree] = useState(false);
  const [errors, setErrors] = useState<Record<string, string>>({});
  const [msg, setMsg] = useState<{ kind: 'error' | 'wait'; text: string } | null>(null);
  const [busy, setBusy] = useState(false);
  const stripe = useRef<{ js: StripeJs; elements: unknown } | null>(null);
  const mount = useRef<HTMLDivElement>(null);

  useEffect(() => {
    if (!method) return;
    let live = true;
    setP(null); setMsg(null); setErrors({});
    startInvoicePayment(number, method).then(async (r) => {
      if (!live) return;
      if (!r.ok) { setMsg({ kind: 'error', text: r.message }); if (r.code === 'paid' || r.code === 'pending') router.refresh(); return; }
      setP(r.data);
      if (r.data.provider === 'stripe' && r.data.publishableKey) {
        const js = await loadStripe(r.data.publishableKey);
        if (method === 'card' && mount.current) {
          const elements = js.elements({ clientSecret: r.data.clientSecret, appearance: { theme: 'stripe', variables: { colorPrimary: '#D0111B', colorText: '#000000', borderRadius: '6px', fontFamily: 'Inter, Helvetica, Arial, sans-serif' } } });
          elements.create('payment', { layout: 'tabs', wallets: { applePay: 'never', googlePay: 'never' }, defaultValues: { billingDetails: { address: { country: 'CA' } } } }).mount(mount.current);
          stripe.current = { js, elements };
        } else stripe.current = { js, elements: null };
      }
    }).catch(() => live && setMsg({ kind: 'error', text: 'The payment form did not load. Reload the page.' }));
    return () => { live = false; };
  }, [number, method, router]);

  const finish = async (intentId: string) => {
    setMsg({ kind: 'wait', text: method === 'acss_debit' ? 'Debit authorized. Recording it.' : 'Card approved. Recording your payment.' });
    const r = await finalizeInvoicePayment(number, intentId);
    if (r.ok && r.data.ok && r.data.status === 'succeeded') { router.push(`/owner/invoices/${encodeURIComponent(number)}?paid=1`); router.refresh(); return; }
    if (r.ok && r.data.ok && r.data.status === 'pending') { router.refresh(); return; }
    setMsg({ kind: 'error', text: r.ok ? (r.data.ok ? r.data.message ?? 'The payment did not go through.' : r.data.message) : r.message });
    setBusy(false);
  };

  const pay = async (e: React.FormEvent) => {
    e.preventDefault();
    if (!p || !method) return;
    const fe: Record<string, string> = {};
    if (method === 'card' && p.provider === 'fake') {
      if (!card.name.trim()) fe.cname = 'Enter the name on the card.';
      if (card.number.replace(/\D/g, '').length < 13) fe.cnumber = 'Enter the card number.';
      if (!/^\d{2}\s*\/\s*\d{2}$/.test(card.exp)) fe.cexp = 'Use MM / YY.';
      if (!/^\d{3,4}$/.test(card.cvc)) fe.ccvc = 'Enter the 3 or 4 digits.';
    }
    if (method === 'acss_debit') {
      if (!agree) fe.agree = 'Tick the box to accept the pre-authorized debit agreement.';
      if (p.provider === 'fake') {
        if (!bank.name.trim()) fe.bname = 'Enter the account holder\'s name.';
        if (!/^\d{3}$/.test(bank.institution.trim())) fe.binst = 'The institution number is 3 digits.';
        if (!/^\d{5}$/.test(bank.transit.trim())) fe.btransit = 'The transit number is 5 digits.';
        if (!/^\d{7,12}$/.test(bank.account.replace(/\s/g, ''))) fe.bacct = 'The account number is 7 to 12 digits.';
      }
    }
    setErrors(fe);
    if (Object.keys(fe).length) { requestAnimationFrame(() => document.querySelector<HTMLElement>('[aria-invalid="true"]')?.focus()); return; }
    setBusy(true); setMsg(null);
    try {
      if (p.provider === 'fake') {
        const c = method === 'card'
          ? await fakeConfirmInvoiceCard(number, p.intentId, { number: card.number, name: card.name, exp: card.exp })
          : await fakeConfirmInvoiceDebit(number, p.intentId, bank);
        if (!c.ok) { setMsg({ kind: 'error', text: c.message }); setBusy(false); return; }
        if (c.data.status !== 'succeeded' && c.data.status !== 'processing') { setMsg({ kind: 'error', text: c.data.error ?? 'The payment was declined.' }); setBusy(false); return; }
        await finish(p.intentId);
      } else if (stripe.current) {
        const r = method === 'card'
          ? await stripe.current.js.confirmPayment({ elements: stripe.current.elements, redirect: 'if_required', confirmParams: { return_url: `${location.origin}/owner/invoices/${encodeURIComponent(number)}` } })
          : await stripe.current.js.confirmAcssDebitPayment(p.clientSecret, { payment_method: { billing_details: { name: p.ownerName, email: p.ownerEmail } } });
        if (r.error) { setMsg({ kind: 'error', text: r.error.message ?? 'The payment did not go through.' }); setBusy(false); return; }
        await finish(r.paymentIntent?.id ?? p.intentId);
      }
    } catch {
      setMsg({ kind: 'wait', text: 'Your payment was sent. This page will update in a moment.' });
      setTimeout(() => router.refresh(), 4000);
    }
  };

  const input = (k: string, label: string, value: string, set: (v: string) => void, props: React.InputHTMLAttributes<HTMLInputElement> = {}) => (
    <div className={`field${errors[k] ? ' has-error' : ''}`}>
      <label className="label" htmlFor={`ow-${k}`}>{label}</label>
      <input className="input" id={`ow-${k}`} value={value} onChange={(e) => { set(e.target.value); setErrors((x) => ({ ...x, [k]: '' })); }} aria-invalid={!!errors[k] || undefined} aria-describedby={`ow-${k}-err`} {...props} />
      <p className="error" role="alert" id={`ow-${k}-err`}>{errors[k] ?? ''}</p>
    </div>
  );

  return (
    <form className="pt-pay" noValidate onSubmit={pay} aria-label={`Pay invoice ${number}`} aria-busy={busy}>
      <fieldset className="stack" style={{ border: 0, padding: 0, margin: 0 }}>
        <legend className="label">How would you like to pay?</legend>
        <div className="ow-methods">
          <label className="option"><input type="radio" name="method" value="card" checked={method === 'card'} onChange={() => setMethod('card')} /><span className="option__title">Card</span><span className="option__body">Visa, Mastercard or American Express. Paid at once.</span></label>
          <label className="option"><input type="radio" name="method" value="acss_debit" checked={method === 'acss_debit'} onChange={() => setMethod('acss_debit')} /><span className="option__title">Pre-authorized debit</span><span className="option__body">From a Canadian bank account. Clears in 3 to 5 business days{hasDebit ? '' : `, and sets up your fees by debit on the ${terms.debit_day_text}`}.</span></label>
        </div>
      </fieldset>
      {method && !p && !msg && <div className="skeleton sk-line" aria-hidden="true" />}
      {method === 'card' && p && (p.provider === 'fake' ? (
        <div className="pt-cardbox" data-testid="fake-card">
          <p className="small muted">Test mode: use a Stripe test card, for example 4242 4242 4242 4242.</p>
          {input('cname', 'Name on the card', card.name, (v) => setCard({ ...card, name: v }), { autoComplete: 'cc-name' })}
          {input('cnumber', 'Card number', card.number, (v) => setCard({ ...card, number: v }), { inputMode: 'numeric', autoComplete: 'cc-number', placeholder: '1234 1234 1234 1234' })}
          <div className="field-row">
            {input('cexp', 'Expiry (MM / YY)', card.exp, (v) => setCard({ ...card, exp: v }), { inputMode: 'numeric', autoComplete: 'cc-exp', placeholder: 'MM / YY' })}
            {input('ccvc', 'Security code', card.cvc, (v) => setCard({ ...card, cvc: v }), { inputMode: 'numeric', autoComplete: 'cc-csc', placeholder: '123' })}
          </div>
        </div>
      ) : <div className="pt-cardbox" ref={mount} aria-label="Card details" />)}
      {method === 'acss_debit' && p && (
        <>
          {p.provider === 'fake' ? (
            <div className="pt-cardbox" data-testid="fake-bank">
              <p className="small muted">Test mode: any 3-digit institution and 5-digit transit; an account ending 0000 is returned by the bank.</p>
              {input('bname', 'Account holder', bank.name, (v) => setBank({ ...bank, name: v }), { autoComplete: 'name' })}
              <div className="field-row">
                {input('binst', 'Institution number', bank.institution, (v) => setBank({ ...bank, institution: v }), { inputMode: 'numeric', placeholder: '004', maxLength: 3 })}
                {input('btransit', 'Transit number', bank.transit, (v) => setBank({ ...bank, transit: v }), { inputMode: 'numeric', placeholder: '12345', maxLength: 5 })}
              </div>
              {input('bacct', 'Account number', bank.account, (v) => setBank({ ...bank, account: v }), { inputMode: 'numeric', autoComplete: 'off' })}
            </div>
          ) : <p className="small">When you continue, Stripe, our payment processor, asks for your bank and shows this agreement again to confirm. Your bank details go to Stripe, not to us.</p>}
          <MandateBlock kind={ownerType === 'corporation' ? 'business' : 'personal'} terms={terms} withInvoice id="ow-mandate-h" />
          <div className={`field${errors.agree ? ' has-error' : ''}`}>
            <label className="check"><input type="checkbox" checked={agree} onChange={(e) => { setAgree(e.target.checked); setErrors((x) => ({ ...x, agree: '' })); }} aria-invalid={!!errors.agree || undefined} aria-describedby="ow-agree-err" /><span>I accept the pre-authorized debit agreement above.</span></label>
            <p className="error" role="alert" id="ow-agree-err">{errors.agree ?? ''}</p>
          </div>
        </>
      )}
      {msg && <p className={`alert ${msg.kind === 'wait' ? 'alert--warn' : 'alert--error'}`} role={msg.kind === 'wait' ? 'status' : 'alert'}><span>{msg.text}</span></p>}
      {method && <button className="btn btn--primary btn--lg btn--block" type="submit" disabled={!p || busy}>{busy ? 'Sending' : method === 'card' ? `Pay ${money(p?.amountCents ?? amountCents, { cents: true })}` : `Authorize debit of ${money(p?.amountCents ?? amountCents, { cents: true })}`}</button>}
      <p className="pt-lock"><svg width="14" height="14" viewBox="0 0 16 16" aria-hidden="true"><path d="M4 7V5a4 4 0 0 1 8 0v2h1v8H3V7zm2 0h4V5a2 2 0 0 0-4 0z" fill="currentColor" /></svg>Payments are processed by Stripe. We never see your full card or account number.</p>
    </form>
  );
}
