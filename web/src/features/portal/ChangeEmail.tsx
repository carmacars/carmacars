'use client';
import { useState, useTransition } from 'react';
import { useRouter, useSearchParams } from 'next/navigation';
import { changeAccountEmail } from '@/server/actions/phone-auth';
import { describedBy, Field } from '@/features/forms/Field';

// r33: change the sign-in email from the profile, for everyone (renter, owner, investor, staff, field staff). The new address gets a confirmation link,
// the old address is told, and the email on the account changes only once the link is opened (then every contact record follows it).
export function ChangeEmail({ current, className = 'stack' }: { current: string | null; className?: string }) {
  const router = useRouter();
  const sp = useSearchParams();
  const [open, setOpen] = useState(false);
  const [email, setEmail] = useState('');
  const [pending, start] = useTransition();
  const [msg, setMsg] = useState<{ ok: boolean; text: string } | null>(null);
  const back = sp.get('email');
  const send = () => start(async () => {
    setMsg(null);
    const r = await changeAccountEmail(email);
    if (!r.ok) { setMsg({ ok: false, text: r.fieldErrors?.email ?? r.message }); return; }
    setOpen(false); setEmail('');
    setMsg({ ok: true, text: `We emailed ${r.data.email} a link to confirm it, and told ${current ?? 'your old address'}. You keep signing in with ${current ?? 'your old address'} until the link is opened.` });
    router.refresh();
  });
  return (
    <div className={className} data-testid="change-email">
      {back === 'changed' && <p className="alert alert--ok" role="status" data-testid="change-email-done"><span>Your email is changed. Sign in with the new address from now on.</span></p>}
      {back === 'waiting' && <p className="alert alert--ok" role="status" data-testid="change-email-waiting"><span>One link is confirmed. Open the link sent to the other address too, and the change is made.</span></p>}
      {msg?.ok && <p className="alert alert--ok" role="status" data-testid="change-email-msg"><span>{msg.text}</span></p>}
      {!open
        ? <p><button type="button" className="btn btn--ghost btn--sm" onClick={() => { setOpen(true); setMsg(null); }} data-testid="change-email-open">Change my email</button></p>
        : <form className="stack" noValidate aria-label="Change my email" onSubmit={(e) => { e.preventDefault(); send(); }}>
          <Field id="ce-email" label="New email" hint="We send a link to confirm it to this address and tell your current one. Nothing changes until the link is opened." error={msg && !msg.ok ? msg.text : undefined}>
            <input className="input" id="ce-email" type="email" autoComplete="email" value={email} onChange={(e) => setEmail(e.target.value)} aria-describedby={describedBy('ce-email', msg && !msg.ok ? msg.text : undefined, true)} data-testid="change-email-input" />
          </Field>
          <p className="row"><button className="btn btn--primary btn--sm" type="submit" disabled={pending || !email.trim()} data-testid="change-email-send">{pending ? 'Sending' : 'Send the link'}</button>
            <button className="btn btn--ghost btn--sm" type="button" onClick={() => { setOpen(false); setMsg(null); }}>Cancel</button></p>
        </form>}
    </div>
  );
}
