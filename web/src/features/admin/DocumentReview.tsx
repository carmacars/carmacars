'use client';
import { useId, useRef, useState, useTransition } from 'react';
import { useRouter } from 'next/navigation';
import { docReviewLoad, guidedAct } from '@/server/actions/guided';
import type { DocReview, DocUpload } from '@/features/admin/todo/types';

// Renter documents of one booking (migration 0078), on one screen (0151): every licence image, selfie, proof of coverage
// and the Protection Plan side by side, what to check said once, then one "Approve all" (each item through the function
// that decides it; one the database refuses is reported and the rest approved) or a reason to reject one item, which the
// renter sees. An Admin or customer service, with no review task. The images come through one-minute private links,
// loaded when the pop-up opens (each opening is logged). Sales (0169) see the licence front, back and selfie only: no coverage.
const KIND: Record<string, string> = { licence_front: 'Licence, front', licence_back: 'Licence, back', selfie: 'Selfie' };
const CHECKS = ['The name and date of birth match the booking', 'Class G2 or G (escalate a licence from outside Ontario), valid past the return date, no sign of alteration',
  'The selfie’s face matches the licence photo'];
const COVERAGE_CHECK = 'The coverage is active to the return date and covers this car and every driver';
const day = (iso: string | null | undefined) => (iso ? new Intl.DateTimeFormat('en-CA', { timeZone: 'America/Toronto', month: 'short', day: 'numeric', year: 'numeric' }).format(new Date(iso.length === 10 ? `${iso}T12:00:00Z` : iso)) : '');

function Reject({ testId, pending, onReject }: { testId: string; pending: boolean; onReject: (reason: string) => void }) {
  const [reason, setReason] = useState('');
  const id = useId().replace(/[^\w-]/g, '');
  return (
    <details className="ad-reject">
      <summary className="small" data-testid={`${testId}-reject-open`}>Reject this one</summary>
      <div className="stack">
        <label className="label" htmlFor={`rj-${id}`}>The reason the renter sees</label>
        <input className="input" id={`rj-${id}`} value={reason} onChange={(e) => setReason(e.target.value)} placeholder="Photo unreadable, expired, name does not match" data-testid={`${testId}-reason`} />
        <button className="btn btn--ghost btn--sm" type="button" disabled={pending || reason.trim().length < 5} onClick={() => onReject(reason.trim())} data-testid={`${testId}-reject`}>Reject</button>
      </div>
    </details>
  );
}

function Upload({ u, pending, reject }: { u: DocUpload; pending: boolean; reject: (reason: string) => void }) {
  return (
    <div className="gd-doc" data-testid={`doc-${u.kind}`}>
      <p className="pt-kicker">{KIND[u.kind] ?? u.kind.replace(/_/g, ' ')} <span className={`badge ${u.status === 'submitted' ? '' : 'badge--outline'}`}>{u.status === 'submitted' ? 'waiting' : u.status}</span></p>
      {u.status === 'submitted' && u.url ? (u.mime_type === 'application/pdf'
        ? <p><a className="link" href={u.url} target="_blank" rel="noreferrer">Open the PDF (link valid one minute)</a></p>
        // eslint-disable-next-line @next/next/no-img-element -- a one-minute signed private image, never cached
        : <img className="ad-idimg" src={u.url} alt={KIND[u.kind] ?? u.kind} referrerPolicy="no-referrer" />) : null}
      {u.status === 'rejected' && u.reject_reason && <p className="small muted">Rejected: {u.reject_reason}</p>}
      {u.status === 'submitted' && <Reject testId={`doc-${u.kind}`} pending={pending} onReject={reject} />}
    </div>
  );
}

export function DocumentReview({ booking, label = 'Review documents', variant = 'primary', refresh = [] }: { booking: string; label?: string; variant?: 'primary' | 'ghost'; refresh?: string[] }) {
  const router = useRouter();
  const dlg = useRef<HTMLDialogElement>(null);
  const idp = useId().replace(/[^\w-]/g, '');
  const [d, setD] = useState<DocReview | null>(null);
  const [msg, setMsg] = useState<{ ok: boolean; text: string } | null>(null);
  const [pending, start] = useTransition();
  const changed = useRef(false);
  const reload = async () => { const again = await docReviewLoad(booking); if (again.ok) setD(again.data); };
  const load = () => start(async () => { const r = await docReviewLoad(booking); if (r.ok) { setD(r.data); setMsg(null); } else setMsg({ ok: false, text: r.message }); });
  const act = (action: 'doc_review_upload' | 'doc_review_coverage' | 'doc_review_plan', p: Record<string, unknown>, done: string) => start(async () => {
    const r = await guidedAct(action, p, refresh);
    if (!r.ok) { setMsg({ ok: false, text: r.message }); return; }
    await reload();
    setMsg({ ok: true, text: done });
    changed.current = true;
  });
  const approveAll = () => start(async () => {
    const r = await guidedAct<{ approved: number; refused: Array<{ item: string; message: string }> }>('doc_review_approve_all', { booking }, refresh);
    if (!r.ok) { setMsg({ ok: false, text: r.message }); return; }
    await reload();
    const n = r.data.approved;
    setMsg(r.data.refused.length
      ? { ok: false, text: `${n} approved. Not approved: ${r.data.refused.map((x) => `${x.item} (${x.message.replace(/^.*?ERROR:\s*/, '')})`).join('; ')}.` }
      : { ok: true, text: `${n} approved.` });
    changed.current = true;
  });
  const cov = d?.coverage ?? null;
  const cp = cov?.proof ?? null;
  const covWaiting = Boolean(cp && cp.status === 'submitted' && (cov?.option === 1 || cov?.option === 2));
  const planWaiting = Boolean(cov && cov.option === 3 && !cov.confirmed && cov.protection_plan_line);
  const waiting = (d?.uploads.filter((u) => u.status === 'submitted').length ?? 0) + (covWaiting ? 1 : 0) + (planWaiting ? 1 : 0);
  const done = d && waiting <= 0;
  const licenceOnly = Boolean(d?.licence_only);
  return (
    <>
      <button className={`btn btn--sm ${variant === 'primary' ? 'btn--primary' : 'btn--ghost'}`} type="button" aria-haspopup="dialog" data-testid="doc-review-open"
        onClick={() => { setD(null); setMsg(null); dlg.current?.showModal(); load(); }}>{label}</button>
      <dialog ref={dlg} className="ad-dialog gd-dialog--wide" aria-labelledby={`${idp}-t`} data-testid="doc-review-dialog" onClose={() => { if (changed.current) { changed.current = false; router.refresh(); } }}>
        <div className="gd-dialog__head">
          <h2 className="d4" id={`${idp}-t`}>Renter documents, booking {booking}</h2>
          <button className="btn btn--quiet btn--sm" type="button" onClick={() => dlg.current?.close()}>Close</button>
        </div>
        {!d && !msg && <p className="small muted" role="status">Loading</p>}
        {d && (
          <div className="stack">
            <p className="small">{d.renter_name}, {d.vehicle_name}. Pickup {day(d.pickup_at)}, return {day(d.return_at)}.
              Identity {d.readiness.all_drivers_verified ? 'verified' : 'not verified yet'}{licenceOnly ? '.' : `; coverage ${d.readiness.coverage_confirmed ? 'confirmed' : 'not confirmed yet'}.`}</p>
            {done && <p className="alert alert--ok" role="status" data-testid="doc-review-done"><span>Nothing waiting for review.</span></p>}
            {!done && (
              <div className="ad-approve-all stack" data-testid="doc-review-checks">
                <p className="pt-kicker">Look at each item below, then approve them together</p>
                <ul className="small">{(licenceOnly ? CHECKS : [...CHECKS, COVERAGE_CHECK]).map((c) => <li key={c}>{c}</li>)}</ul>
                <div className="row"><button className="btn btn--primary" type="button" disabled={pending} onClick={approveAll} data-testid="doc-review-approve-all">{pending ? 'Working' : `Approve all (${waiting})`}</button>
                  <span className="small muted">One wrong? Reject that one first, with the reason.</span></div>
              </div>)}
            {msg && <p className={`alert ${msg.ok ? 'alert--ok' : 'alert--error'}`} role={msg.ok ? 'status' : 'alert'} data-testid="doc-review-msg"><span>{msg.text}</span></p>}
            {d.drivers.map((dr) => {
              const ups = d.uploads.filter((u) => u.driver_id === dr.driver_id);
              return (
                <section key={dr.driver_id} className="gd-driver" aria-label={dr.full_name}>
                  <h3 className="pt-kicker">{dr.full_name} ({dr.role.replace(/_/g, ' ')}){dr.verified_on ? ', verified' : ''}</h3>
                  <p className="small muted">Born {dr.date_of_birth ?? 'not given'} · licence {dr.licence_number ?? 'not given'} {dr.licence_class ?? ''} · expires {dr.licence_expiry ?? 'not given'}</p>
                  {ups.length ? <div className="gd-docs">{ups.map((u) => <Upload key={u.id} u={u} pending={pending} reject={(reason) => act('doc_review_upload', { upload: u.id, approve: false, reason }, `${KIND[u.kind] ?? 'Document'} rejected. The renter is told why.`)} />)}</div>
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
                {covWaiting && cp && <Reject testId="coverage" pending={pending} onReject={(reason) => act('doc_review_coverage', { proof: cp.id, approve: false, reason }, 'Proof of coverage rejected. The renter is told why.')} />}
                {cp && cp.status === 'rejected' && <p className="small muted">Rejected: {cp.rejection_reason}. The renter sends a new one.</p>}
                {!cp && cov.option !== 3 && <p className="small muted">No proof sent yet.</p>}
                {planWaiting && <p className="small" data-testid="plan-waiting">The Protection Plan is on the booking and waits to be confirmed active (included in Approve all).</p>}
              </section>)}
          </div>)}
      </dialog>
    </>
  );
}
