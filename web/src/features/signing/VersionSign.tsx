'use client';
import { useState } from 'react';
import type { Clause } from '@/features/agreement/extra';
import { signVersion } from '@/server/actions/agreements';
import { EsignFlow } from './EsignFlow';
import type { EsignReady } from './types';

// Signing a new version of the rental agreement (migration 0154), by the signer's own link or on a staff device.
export function VersionSign({ token, inPerson, ccSha, bsSha, terms, two }: { token: string; inPerson: boolean; ccSha: string; bsSha: string | null; terms: Clause[]; two: boolean }) {
  const [sig, setSig] = useState<EsignReady | null>(null);
  const [pending, setPending] = useState(false);
  const [msg, setMsg] = useState<{ ok: boolean; text: string } | null>(null);
  if (msg?.ok) return <p className="alert alert--ok" role="status" data-testid="version-signed"><span className="alert__title">Signed</span><span>{msg.text}</span></p>;
  return (
    <div className="stack-lg">
      <EsignFlow ctx={{ kind: 'version', token, inPerson }} terms={terms} onReady={setSig} docsLabel={two ? 'what changed and both agreements' : 'what changed and the agreement'} />
      {msg && !msg.ok && <p className="alert alert--error" role="alert"><span>{msg.text}</span></p>}
      <button className="btn btn--primary btn--lg btn--block" type="button" disabled={!sig || pending} data-testid="version-sign"
        onClick={async () => { setPending(true); const r = await signVersion(token, { ...sig!, carmacarsSha: ccSha, blindspotSha: bsSha }); setPending(false); setMsg(r.ok ? { ok: true, text: r.data.version_signed ? 'Every signature is in. Your signed copy is on its way by email and in your booking.' : 'Thank you. Your copy comes by email once everyone has signed.' } : { ok: false, text: r.message }); }}>
        {pending ? 'Signing' : 'Sign this version'}</button>
      <p className="xs muted">The one signature signs {two ? 'both agreements' : 'the agreement'} of this version.</p>
    </div>
  );
}
