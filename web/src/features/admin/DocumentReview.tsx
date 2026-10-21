'use client';
import { useId, useRef, useState, useTransition } from 'react';
import { useRouter } from 'next/navigation';
import { docReviewLoad, guidedAct } from '@/server/actions/guided';
import type { DocReview, DocUpload } from '@/features/admin/todo/types';

// Renter documents of one booking (migration 0078): the licence images and selfie of each driver, the proof of coverage
// (OPCF 27 or the credit card's rental coverage) and the Protection Plan, approved or rejected with a reason the renter
// sees. An Admin or customer service, with no review task. The images come through one-minute private links, loaded
// when the pop-up opens (each opening is logged).
const CHECKS: Record<string, string[]> = {
  licence: ['The name matches the booking', 'The date of birth matches', 'Class G2 or G (escalate a licence from outside Ontario)', 'Valid past the return date', 'Shows no sign of alteration'],
  selfie: ['The face matches the licence photo']
};
const KIND: Record<string, string> = { licence_front: 'Licence, front', licence_back: 'Licence, back', selfie: 'Selfie' };
const day = (iso: string | null | undefined) => (iso ? new Intl.DateTimeFormat('en-CA', { timeZone: 'America/Toronto', month: 'short', day: 'numeric', year: 'numeric' }).format(new Date(iso.length === 10 ? `${iso}T12:00:00Z` : iso)) : '');

function Decide({ onDecide, checks, pending, testId }: { onDecide: (approve: boolean, reason: string | null) => void; checks: string[]; pending: boolean; testId: string }) {
  const [ticks, setTicks] = useState<boolean[]>(() => checks.map(() => false));
  const [reason, setReason] = useState('');
  const id = useId().replace(/[^\w-]/g, '');
  return (
    <div className="stack">
      {checks.length > 0 && <fieldset className="gd-checks"><legend className="pt-kicker">Check</legend>
        {checks.map((c, i) => <label key={c} className="check"><input type="checkbox" checked={ticks[i]} onChange={(e) => setTicks((s) => s.map((x, j) => (j === i ? e.target.checked : x)))} /> <span>{c}</span></label>)}</fieldset>}
      <div className="row">
        <button className="btn btn--primary btn--sm" type="button" disabled={pending || !ticks.every(Boolean)} onClick={() => onDecide(true, null)} data-testid={`${testId}-approve`}>Approve</button>
      </div>
      <div className="field"><label className="label" htmlFor={`rj-${id}`}>Or reject, with the reason the renter sees</label>
        <input className="input" id={`rj-${id}`} value={reason} onChange={(e) => setReason(e.target.value)} placeholder="Photo unreadable, expired, name does not match" data-testid={`${testId}-reason`} /></div>
      <div className="row"><button className="btn btn--ghost btn--sm" type="button" disabled={pending || reason.trim().length < 5} onClick={() => onDecide(false, reason.trim())} data-testid={`${testId}-reject`}>Reject</button></div>
    </div>
  );
}

function Upload({ u, pending, decide }: { u: DocUpload; pending: boolean; decide: (approve: boolean, reason: string | null) => void }) {
  return (
    <div className="gd-doc" data-testid={`doc-${u.kind}`}>
      <p className="pt-kicker">{KIND[u.kind] ?? u.kind.replace(/_/g, ' ')} <span className={`badge ${u.status === 'submitted' ? '' : 'badge--outline'}`}>{u.status === 'submitted' ? 'waiting' : u.status}</span></p>
      {u.status === 'submitted' && u.url ? (u.mime_type === 'application/pdf'
        ? <p><a className="link" href={u.url} target="_blank" rel="noreferrer">Open the PDF (link valid one minute)</a></p>
        // eslint-disable-next-line @next/next/no-img-element -- a one-minute signed private image, never cached
        : <img className="ad-idimg" src={u.url} alt={KIND[u.kind] ?? u.kind} referrerPolicy="no-referrer" />) : null}
      {u.status === 'rejected' && u.reject_reason && <p className="small muted">Rejected: {u.reject_reason}</p>}
      {u.status === 'submitted' && <Decide checks={CHECKS[u.kind.startsWith('licence') ? 'licence' : u.kind] ?? []} pending={pending} onDecide={decide} testId={`doc-${u.kind}`} />}
    </div>
  );
}

export function DocumentReview({ booking, label = 'Review documents', variant = 'primary', refresh = [] }: { booking: string; label?: string; variant?: 'primary' | 'ghost'; refresh?: string[] }) {
  const router = useRouter();
  const dlg = useRef<HTMLDialogElement>(null);
  const idp = useId().replace(/[^\w-]/g, '');
  const [d, setD] = useState<DocReview | null>(null);
  const [msg, setMsg] = useState<string | null>(null);
  const [pending, start] = useTransition();
  const load = () => start(async () => { const r = await docReviewLoad(booking); if (r.ok) { setD(r.data); setMsg(null); } else setMsg(r.message); });
  const act = (action: 'doc_review_upload' | 'doc_review_coverage' | 'doc_review_plan', p: Record<string, unknown>) => start(async () => {
    const r = await guidedAct(action, p, refresh);
    if (!r.ok) { setMsg(r.message); return; }
    const again = await docReviewLoad(booking);
    if (again.ok) setD(again.data);
    setMsg(null);
    router.refresh();
  });
  const cov = d?.coverage ?? null;
  const cp = cov?.proof ?? null;
  const done = d && d.waiting === 0 && !(cp && cp.status === 'submitted') && !(cov?.option === 3 && !cov.confirmed && cov.protection_plan_line);
  return (
    <>
      <button className={`btn btn--sm ${variant === 'primary' ? 'btn--primary' : 'btn--ghost'}`} type="button" aria-haspopup="dialog" data-testid="doc-review-open"
        onClick={() => { setD(null); dlg.current?.showModal(); load(); }}>{label}</button>
      <dialog ref={dlg} className="ad-dialog gd-dialog--wide" aria-labelledby={`${idp}-t`} data-testid="doc-review-dialog">
        <div className="gd-dialog__head">
          <h2 className="d4" id={`${idp}-t`}>Renter documents, booking {booking}</h2>
          <button className="btn btn--quiet btn--sm" type="button" onClick={() => dlg.current?.close()}>Close</button>
        </div>
        {!d && !msg && <p className="small muted" role="status">Loading</p>}
        {msg && <p className="alert alert--error" role="alert"><span>{msg}</span></p>}
        {d && (
          <div className="stack">
            <p className="small">{d.renter_name}, {d.vehicle_name}. Pickup {day(d.pickup_at)}, return {day(d.return_at)}.
              Identity {d.readiness.all_drivers_verified ? 'verified' : 'not verified yet'}; coverage {d.readiness.coverage_confirmed ? 'confirmed' : 'not confirmed yet'}.</p>
            {done && <p className="alert alert--ok" role="status" data-testid="doc-review-done"><span>Nothing waiting for review.</span></p>}
            {d.drivers.map((dr) => {
              const ups = d.uploads.filter((u) => u.driver_id === dr.driver_id);
              return (
                <section key={dr.driver_id} className="gd-driver" aria-label={dr.full_name}>
                  <h3 className="pt-kicker">{dr.full_name} ({dr.role.replace(/_/g, ' ')}){dr.verified_on ? ', verified' : ''}</h3>
                  <p className="small muted">Born {dr.date_of_birth ?? 'not given'} · licence {dr.licence_number ?? 'not given'} {dr.licence_class ?? ''} · expires {dr.licence_expiry ?? 'not given'}</p>
                  {ups.length ? <div className="gd-docs">{ups.map((u) => <Upload key={u.id} u={u} pending={pending} decide={(approve, reason) => act('doc_review_upload', { upload: u.id, approve, reason })} />)}</div>
                    : <p className="small muted">Nothing uploaded for this driver.</p>}
                </section>);
            })}
            {cov && (
              <section className="gd-driver" aria-label="Coverage" data-testid="doc-review-coverage">
                <h3 className="pt-kicker">Coverage: {cov.option_label}{cov.confirmed ? ', confirmed' : ''}</h3>
                {cov.option === 1 && cp && <p className="small">{cp.insurer_name}, policy {cp.policy_number}, valid to {cp.policy_expiry}{cp.policy_valid ? ' (after the return: fine)' : ' (NOT after the return date)'}</p>}
                {cov.option === 2 && <p className="small">{cov.card.brand ? `${cov.card.brand.toUpperCase()} ending ${cov.card.last4 ?? ''}, ${cov.card.funding ?? 'unknown'}` : 'Not paid yet'}; cardholder {cov.card.cardholder_name ?? ''}{cov.card.name_matches ? ' (matches the renter)' : ' (does NOT match the renter)'}.
                  {cov.card.eligible ? ' A credit card in the renter’s name.' : ` ${cov.card.message ?? ''}`} {cp?.renter_confirmed_at ? `The renter confirmed the card covers this rental: ${cp.confirmation_text ?? ''}` : 'The renter has not confirmed the card covers it yet.'}</p>}
                {cp && cp.pages.length > 0 && <ul className="small">{cp.pages.map((pg, i) => <li key={pg.id}>Page {i + 1}: {pg.url ? <a className="link" href={pg.url} target="_blank" rel="noreferrer">{pg.mime_type === 'application/pdf' ? 'open the PDF' : 'open the photo'}</a> : 'no file'} ({pg.status})</li>)}</ul>}
                {cp && cp.status === 'submitted' && (cov.option === 1 || cov.option === 2) && (
                  <Decide checks={['Active to the return date', cov.option === 1 ? 'Covers this car and every driver (OPCF 27)' : 'The card covers this class and this length']} pending={pending} testId="coverage"
                    onDecide={(approve, reason) => act('doc_review_coverage', { proof: cp.id, approve, reason })} />)}
                {cp && cp.status === 'rejected' && <p className="small muted">Rejected: {cp.rejection_reason}. The renter sends a new one.</p>}
                {!cp && cov.option !== 3 && <p className="small muted">No proof sent yet.</p>}
                {cov.option === 3 && !cov.confirmed && cov.protection_plan_line && (
                  <button className="btn btn--primary btn--sm" type="button" disabled={pending} data-testid="plan-confirm" onClick={() => act('doc_review_plan', { booking })}>Confirm the Protection Plan is active</button>)}
              </section>)}
          </div>)}
      </dialog>
    </>
  );
}
