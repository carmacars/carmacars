'use client';
import { useState, useTransition } from 'react';
import { useRouter } from 'next/navigation';
import { saveAccountEmail } from '@/server/actions/phone-auth';
import { describedBy, Field } from '@/features/forms/Field';

// The pay page of an account made by phone (migration 0091): an email for the receipts before the first payment.
export function ReceiptEmail({ path }: { path: string }) {
  const router = useRouter();
  const [email, setEmail] = useState('');
  const [err, setErr] = useState<string | null>(null);
  const [pending, start] = useTransition();
  return (
    <form className="stack" noValidate aria-label="Your email for receipts" data-testid="receipt-email"
      onSubmit={(e) => { e.preventDefault(); start(async () => { setErr(null); const r = await saveAccountEmail(email, path); if (!r.ok) { setErr(r.message); return; } router.refresh(); }); }}>
      <p>We send your receipt and the signed agreement by email. Add your email to pay.</p>
      <Field id="re-email" label="Email" error={err ?? undefined} hint="We also email you a link to confirm it; you can then sign in with it too.">
        <input className="input" id="re-email" type="email" autoComplete="email" value={email} onChange={(e) => setEmail(e.target.value)} aria-invalid={!!err || undefined} aria-describedby={describedBy('re-email', err ?? undefined, true)} />
      </Field>
      <p><button className="btn btn--primary" type="submit" disabled={pending}>{pending ? 'Saving' : 'Save and continue to payment'}</button></p>
    </form>
  );
}
