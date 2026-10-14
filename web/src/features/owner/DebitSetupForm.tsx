'use client';
import { useState } from 'react';
import { useRouter } from 'next/navigation';
import { beginDebitSetup, completeDebitSetup, fakeConfirmDebitSetup } from '@/server/actions/owner';
import { mandateText } from './OwnerPayForm';
import type { DebitTerms } from './types';

// Banking > Set up pre-authorized debit (migration 0037): the owner gives a Canadian bank account and accepts the
// pre-authorized debit agreement in Stripe's own bank form (a SetupIntent), with no payment. The monthly fees are
// then debited on the debit day, with notice first. Locally the fake adapter stands in with Stripe's test numbers.
interface StripeJs {
  confirmAcssDebitSetup(secret: string, o: { payment_method: { billing_details: { name: string; email: string } } }): Promise<{ error?: { message?: string }; setupIntent?: { id: string; status: string } }>;
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

export function DebitSetupForm({ ownerType, terms, replace }: { ownerType: 'individual' | 'corporation'; terms: DebitTerms; replace: boolean }) {
  const router = useRouter();
  const [open, setOpen] = useState(false);
  const [fake, setFake] = useState<{ setupId: string } | null>(null);
  const [bank, setBank] = useState({ name: '', institution: '', transit: '', account: '' });
  const [agree, setAgree] = useState(false);
  const [busy, setBusy] = useState(false);
  const [msg, setMsg] = useState<{ kind: 'error' | 'ok'; text: string } | null>(null);
  const kind = ownerType === 'corporation' ? 'business' : 'personal';

  const finish = async (setupId: string) => {
    const r = await completeDebitSetup(setupId);
    if (!r.ok) { setMsg({ kind: 'error', text: r.message }); setBusy(false); return; }
    setMsg({ kind: 'ok', text: r.data.active ? 'Your pre-authorized debit is set up. We debit your fees on the debit day, with notice first.' : 'Saved. Stripe is confirming your account with two small deposits; follow the email from Stripe to finish.' });
    setBusy(false); setOpen(false); router.refresh();
  };

  const go = async (e: React.FormEvent) => {
    e.preventDefault();
    if (!agree) { setMsg({ kind: 'error', text: 'Tick the box to accept the pre-authorized debit agreement.' }); return; }
    setBusy(true); setMsg(null);
    try {
      if (fake) {
        const c = await fakeConfirmDebitSetup(fake.setupId, bank);
        if (!c.ok || c.data.error) { setMsg({ kind: 'error', text: c.ok ? c.data.error ?? 'Check the bank details.' : c.message }); setBusy(false); return; }
        return await finish(fake.setupId);
      }
      const s = await beginDebitSetup();
      if (!s.ok) { setMsg({ kind: 'error', text: s.message }); setBusy(false); return; }
      if (s.data.provider === 'fake') { setFake({ setupId: s.data.setupId }); setBusy(false); return; }
      if (!s.data.publishableKey) { setMsg({ kind: 'error', text: 'Bank debits are not available right now. Call us.' }); setBusy(false); return; }
      const js = await loadStripe(s.data.publishableKey);
      const r = await js.confirmAcssDebitSetup(s.data.clientSecret, { payment_method: { billing_details: { name: s.data.ownerName, email: s.data.ownerEmail } } });
      if (r.error) { setMsg({ kind: 'error', text: r.error.message ?? 'The bank setup did not finish.' }); setBusy(false); return; }
      await finish(r.setupIntent?.id ?? s.data.setupId);
    } catch {
      setMsg({ kind: 'error', text: 'The bank form did not load. Reload the page and try again.' }); setBusy(false);
    }
  };

  if (!open) return (
    <>
      {msg && <p className={`alert ${msg.kind === 'ok' ? 'alert--ok' : 'alert--error'}`} role="status"><span>{msg.text}</span></p>}
      <button type="button" className={`btn ${replace ? 'btn--ghost' : 'btn--primary'}`} onClick={() => { setOpen(true); setMsg(null); }} data-testid="debit-setup-open">
        {replace ? 'Use another bank account' : 'Set up pre-authorized debit'}
      </button>
    </>
  );
  const field = (k: keyof typeof bank, label: string, props: React.InputHTMLAttributes<HTMLInputElement> = {}) => (
    <div className="field"><label className="label" htmlFor={`ds-${k}`}>{label}</label>
      <input className="input" id={`ds-${k}`} value={bank[k]} onChange={(e) => setBank({ ...bank, [k]: e.target.value })} {...props} /></div>
  );
  return (
    <form className="stack" onSubmit={go} aria-label="Set up pre-authorized debit" aria-busy={busy} data-testid="debit-setup-form">
      {fake ? (
        <div className="pt-cardbox" data-testid="fake-debit-setup">
          <p className="small muted">Test mode: any 3-digit institution and 5-digit transit and a 7 to 12 digit account.</p>
          {field('name', 'Account holder', { autoComplete: 'name' })}
          <div className="field-row">{field('institution', 'Institution number', { inputMode: 'numeric', maxLength: 3 })}{field('transit', 'Transit number', { inputMode: 'numeric', maxLength: 5 })}</div>
          {field('account', 'Account number', { inputMode: 'numeric', autoComplete: 'off' })}
        </div>
      ) : <p className="small">When you continue, Stripe, our payment processor, asks for your bank and shows this agreement again to confirm. Your bank details go to Stripe, not to us.</p>}
      <section className="ow-mandate" aria-labelledby="ds-mandate-h" tabIndex={0}>
        <h3 id="ds-mandate-h">Pre-authorized debit agreement ({kind})</h3>
        {mandateText(kind, terms, false).map((t, i) => <p key={i}>{t}</p>)}
      </section>
      <label className="check"><input type="checkbox" checked={agree} onChange={(e) => setAgree(e.target.checked)} data-testid="debit-setup-agree" /><span>I accept the pre-authorized debit agreement above.</span></label>
      {msg && <p className={`alert ${msg.kind === 'ok' ? 'alert--ok' : 'alert--error'}`} role="alert"><span>{msg.text}</span></p>}
      <div className="row"><button className="btn btn--primary" type="submit" disabled={busy} data-testid="debit-setup-submit">{busy ? 'Sending' : fake ? 'Save the bank account' : 'Continue to my bank details'}</button>
        <button className="btn btn--ghost" type="button" onClick={() => { setOpen(false); setFake(null); }}>Cancel</button></div>
    </form>
  );
}
