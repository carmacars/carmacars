'use client';
import { useState, useTransition } from 'react';
import { useRouter } from 'next/navigation';
import { acceptTerms, declineTerms } from '@/server/actions/terms';

import { WhyDisabled } from '@/components/WhyDisabled';
/** Accept one updated version: recorded with the time, the IP address, the device and the version; then the next one, or the portal. */
export function TermsAccept({ id, sha, portal, title, last }: { id: string; sha: string; portal: string; title: string; last: boolean }) {
  const router = useRouter();
  const [read, setRead] = useState(false);
  const [err, setErr] = useState<string | null>(null);
  const [pending, start] = useTransition();
  const [declined, setDeclined] = useState<{ email: string | null; phone: string | null } | null>(null);
  return (
    <div className="tg__accept stack">
      <label className="check"><input type="checkbox" checked={read} onChange={(e) => setRead(e.target.checked)} data-testid="terms-read" /><span>I have read the updated {title} and I accept it.</span></label>
      {err && <p className="alert alert--error" role="alert"><span>{err}</span></p>}
      <><button className="btn btn--primary btn--lg btn--block" type="button" disabled={!read || pending} data-testid="terms-accept"
        onClick={() => start(async () => { setErr(null); const r = await acceptTerms(id, sha, portal); if (!r.ok) { setErr(r.message ?? 'Not saved. Try again.'); return; } router.refresh(); })} aria-describedby="why-termsaccept-16">
        {pending ? 'Saving' : last ? 'Accept and continue' : 'Accept'}
      </button><WhyDisabled id="why-termsaccept-16" why={((!read)) ? 'Read the document first' : null} /></>
      {/* r48 FE (3198): declining keeps the portal closed and says how to reach us */}
      {declined ? <p className="alert alert--warn" role="status" data-testid="terms-declined"><span className="alert__title">Your portal stays closed until you accept</span>
          <span>Questions about the change? Contact us{declined.email ? <> at <a className="link" href={`mailto:${declined.email}`}>{declined.email}</a></> : null}{declined.phone ? <> or call {declined.phone}</> : null}. You can accept above at any time.</span></p>
        : <button className="btn btn--ghost btn--sm" type="button" disabled={pending} data-testid="terms-decline"
            onClick={() => start(async () => { setErr(null); const r = await declineTerms(id, ''); if (!r.ok) { setErr(r.message ?? 'Not saved.'); return; } setDeclined(r.contact ?? { email: null, phone: null }); })}>I do not accept</button>}
    </div>
  );
}
