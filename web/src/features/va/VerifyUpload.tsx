'use client';
import { useEffect, useRef, useState, useTransition } from 'react';
import { useRouter } from 'next/navigation';
import { vaAct } from '@/server/actions/va';

// One identity or coverage document (05-va.md section 4.2): every check is ticked before it can be
// approved; a rejection needs a reason the renter can act on.
const CHECKS: Record<string, string[]> = {
  licence: ['The name matches the booking', 'The date of birth matches', 'Class G2 or G (escalate a licence from outside Ontario)', 'Valid past the return date', 'Shows no sign of alteration'],
  selfie: ['The face matches the licence photo'],
  coverage_proof: ['Active to the return date', 'Covers this car and every driver, or is the Card on File covering this class and length']
};

export function VerifyUpload({ id, kind, src, pdf }: { id: string; kind: string; src: string; pdf: boolean }) {
  const router = useRouter();
  const list = CHECKS[kind.startsWith('licence') ? 'licence' : kind] ?? [];
  const [ticks, setTicks] = useState<boolean[]>(() => list.map(() => false));
  const [reason, setReason] = useState('');
  const [msg, setMsg] = useState<string | null>(null);
  const [pending, start] = useTransition();
  // a row whose file is not in storage: say so (and let the VA reject it for a new upload) instead of a broken image
  const [missing, setMissing] = useState(false);
  const img = useRef<HTMLImageElement>(null);
  useEffect(() => { const el = img.current; if (el && el.complete && el.naturalWidth === 0) setMissing(true); }, [src]);
  const decide = (approve: boolean) => start(async () => {
    const r = await vaAct('verify_upload', { upload: id, approve, reason: approve ? null : reason });
    if (!r.ok) { setMsg(r.message); return; }
    router.refresh();
  });
  return (
    <div className="stack" data-testid={`upload-${kind}`}>
      {pdf ? <p><a className="link" href={src} target="_blank" rel="noreferrer">Open the PDF (link valid for one minute)</a></p>
        : missing ? <p className="alert alert--warn" role="status" data-testid={`file-missing-${kind}`}><span>File missing: this upload is on record but its file is not in storage. Reject it so the renter uploads it again.</span></p>
        // eslint-disable-next-line @next/next/no-img-element -- a one-minute signed private image, never cached
        : <img ref={img} className="ad-idimg" src={src} alt={kind.replace(/_/g, ' ')} referrerPolicy="no-referrer" onError={() => setMissing(true)} />}
      <fieldset className="ad-fields"><legend className="pt-kicker">Checks</legend>
        {list.map((c, i) => <label key={c} className="check"><input type="checkbox" checked={ticks[i]} onChange={(e) => setTicks((s) => s.map((x, j) => (j === i ? e.target.checked : x)))} /> <span>{c}</span></label>)}
      </fieldset>
      <div className="row">
        <button className="btn btn--primary btn--sm" type="button" disabled={pending || !ticks.every(Boolean)} onClick={() => decide(true)} data-testid={`approve-${kind}`}>Approve</button>
      </div>
      <div className="field"><label className="label" htmlFor={`rj-${id}`}>Reason shown to the renter</label><input className="input" id={`rj-${id}`} value={reason} onChange={(e) => setReason(e.target.value)} placeholder="Photo unreadable, expired, name does not match" /></div>
      <button className="btn btn--ghost btn--sm" type="button" disabled={pending || reason.trim().length < 5} onClick={() => decide(false)}>Reject</button>
      {msg && <p className="alert alert--error" role="alert"><span>{msg}</span></p>}
    </div>
  );
}
