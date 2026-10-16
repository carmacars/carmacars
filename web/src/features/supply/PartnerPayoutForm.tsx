'use client';
import { useState, useTransition } from 'react';
import { useRouter } from 'next/navigation';
import { savePartnerPayout } from '@/server/actions/supply';

// A partner's payout account, entered by an Admin (stored like an owner's: the account number encrypted, only the
// last four digits shown; verified by a call before a payout uses it).
export function PartnerPayoutForm({ partnerId, holder }: { partnerId: string; holder: string }) {
  const router = useRouter();
  const [method, setMethod] = useState('bank_transfer');
  const [msg, setMsg] = useState<{ ok: boolean; text: string } | null>(null);
  const [pending, start] = useTransition();
  return (
    <details><summary className="link">Add or change the payout account</summary>
      <form className="ad-form" noValidate data-testid="partner-payout-form" action={(fd) => start(async () => {
        fd.set('partner_id', partnerId);
        const r = await savePartnerPayout(fd);
        setMsg(r.ok ? { ok: true, text: 'Saved. Verify it by phone before the next payout.' } : { ok: false, text: r.message });
        if (r.ok) router.refresh();
      })}>
        <div className="ad-fields">
          <div className="field ad-field"><label className="label" htmlFor="pp-method">Paid by</label>
            <select className="select" id="pp-method" name="method" value={method} onChange={(e) => setMethod(e.target.value)}><option value="bank_transfer">Bank transfer</option><option value="e_transfer">e-Transfer</option></select></div>
          <div className="field ad-field"><label className="label" htmlFor="pp-holder">Account holder</label><input className="input" id="pp-holder" name="account_holder" defaultValue={holder} /></div>
          {method === 'e_transfer'
            ? <div className="field ad-field"><label className="label" htmlFor="pp-email">e-Transfer email</label><input className="input" id="pp-email" name="e_transfer_email" type="email" /></div>
            : <>
              <div className="field ad-field"><label className="label" htmlFor="pp-inst">Institution number (3 digits)</label><input className="input" id="pp-inst" name="institution_no" inputMode="numeric" /></div>
              <div className="field ad-field"><label className="label" htmlFor="pp-transit">Transit number (5 digits)</label><input className="input" id="pp-transit" name="transit_no" inputMode="numeric" /></div>
              <div className="field ad-field"><label className="label" htmlFor="pp-acct">Account number</label><input className="input" id="pp-acct" name="account_no" inputMode="numeric" autoComplete="off" /></div>
            </>}
        </div>
        {msg && <p className={`alert ${msg.ok ? 'alert--ok' : 'alert--error'}`} role={msg.ok ? 'status' : 'alert'}><span>{msg.text}</span></p>}
        <div className="row"><button className="btn btn--primary btn--sm" type="submit" disabled={pending}>{pending ? 'Saving' : 'Save the payout account'}</button></div>
      </form>
    </details>
  );
}
