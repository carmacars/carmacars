'use client';
import { useState, useTransition } from 'react';
import { useRouter } from 'next/navigation';
import { acceptTerms } from '@/server/actions/terms';

/** Accept one updated version: recorded with the time, the IP address, the device and the version; then the next one, or the portal. */
export function TermsAccept({ id, sha, portal, title, last }: { id: string; sha: string; portal: string; title: string; last: boolean }) {
  const router = useRouter();
  const [read, setRead] = useState(false);
  const [err, setErr] = useState<string | null>(null);
  const [pending, start] = useTransition();
  return (
    <div className="tg__accept stack">
      <label className="check"><input type="checkbox" checked={read} onChange={(e) => setRead(e.target.checked)} data-testid="terms-read" /><span>I have read the updated {title} and I accept it.</span></label>
      {err && <p className="alert alert--error" role="alert"><span>{err}</span></p>}
      <button className="btn btn--primary btn--lg btn--block" type="button" disabled={!read || pending} data-testid="terms-accept"
        onClick={() => start(async () => { setErr(null); const r = await acceptTerms(id, sha, portal); if (!r.ok) { setErr(r.message ?? 'Not saved. Try again.'); return; } router.refresh(); })}>
        {pending ? 'Saving' : last ? 'Accept and continue' : 'Accept'}
      </button>
    </div>
  );
}
