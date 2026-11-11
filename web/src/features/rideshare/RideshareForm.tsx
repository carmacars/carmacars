'use client';
import { useState } from 'react';
import { useRouter } from 'next/navigation';
import { useAct } from '@/features/portal/useAct';
import { requestRideshareDocs } from '@/server/actions/renter-extras';
import { RIDESHARE_PLATFORMS, rideshareProblem, type RidesharePlatform } from './model';

// r35a (1303): the renter picks the platforms; the documents are made at once (the page below shows them) and our team is told.
export function RideshareForm({ number }: { number: string }) {
  const [picked, setPicked] = useState<RidesharePlatform[]>([]);
  const [other, setOther] = useState('');
  const [problem, setProblem] = useState<string | null>(null);
  const a = useAct();
  const router = useRouter();
  const toggle = (k: RidesharePlatform) => setPicked((p) => (p.includes(k) ? p.filter((x) => x !== k) : [...p, k]));
  return (
    <form className="stack" data-testid="rideshare-form" onSubmit={(e) => {
      e.preventDefault(); if (a.pending) return;
      const p = rideshareProblem(picked, other); setProblem(p); if (p) return;
      a.run(() => requestRideshareDocs(number, picked, other), (r) => { if (r.ok) router.refresh(); });
    }}>
      <fieldset className="field" style={{ border: 0, padding: 0, margin: 0 }}><legend className="label">Which platforms?</legend>
        <div className="row" style={{ gap: 'var(--s-3)', flexWrap: 'wrap' }}>
          {RIDESHARE_PLATFORMS.map(([k, l]) => <label key={k} className="check" htmlFor={`rs-${k}`}><input id={`rs-${k}`} type="checkbox" checked={picked.includes(k)} onChange={() => toggle(k)} data-testid={`rideshare-${k}`} /> <span>{l}</span></label>)}
        </div></fieldset>
      {picked.includes('other') && <div className="field"><label className="label" htmlFor="rs-other">The other platform</label><input className="input" id="rs-other" maxLength={80} value={other} onChange={(e) => setOther(e.target.value)} data-testid="rideshare-other-name" /></div>}
      {(problem || (a.res && !a.res.ok)) && <p className="alert alert--warn" role="alert"><span>{problem ?? (a.res && !a.res.ok ? a.res.message : '')}</span></p>}
      {a.res?.ok && <p className="alert alert--ok" role="status" data-testid="rideshare-made"><span>Your documents are ready below. Print them or save them as a PDF.</span></p>}
      <p><button className="btn btn--primary btn--sm" type="submit" disabled={a.pending} data-testid="rideshare-make">{a.pending ? 'Making them' : 'Make my documents'}</button></p>
    </form>
  );
}
