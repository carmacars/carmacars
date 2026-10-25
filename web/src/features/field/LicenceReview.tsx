'use client';
import { useId, useState, useTransition } from 'react';
import { useRouter } from 'next/navigation';
import { fieldAct } from '@/server/actions/field';
import { fieldLicenceLoad } from '@/server/actions/field-licence';
import type { DocUpload } from '@/features/admin/todo/types';
import type { LicenceReviewData } from './types';

// The renter's licence reviewed by field staff (0162): the licence front, back and the selfie of a booking on a job of their
// own, then "Approve all" or a reason to reject one image (the renter sees the reason and sends a new one). The same
// decision, audit trail and statuses as customer service's review; the history records the reviewer's role. The images come
// through one-minute private links, loaded when the panel opens (each opening is logged). Large touch targets.
const KIND: Record<string, string> = { licence_front: 'Licence, front', licence_back: 'Licence, back', selfie: 'Selfie with the licence' };
const CHECKS = ['The name and date of birth match the booking', 'Class G2 or G, valid past the return date, no sign of alteration', 'The selfie’s face matches the licence photo'];
const day = (iso: string | null | undefined) => (iso ? new Intl.DateTimeFormat('en-CA', { timeZone: 'America/Toronto', month: 'short', day: 'numeric', year: 'numeric' }).format(new Date(iso.length === 10 ? `${iso}T12:00:00Z` : iso)) : '');

function Reject({ kind, pending, onReject }: { kind: string; pending: boolean; onReject: (reason: string) => void }) {
  const [reason, setReason] = useState('');
  const id = useId().replace(/[^\w-]/g, '');
  return (
    <details className="fd-fix__more">
      <summary data-testid={`licence-${kind}-reject-open`}>Reject this one</summary>
      <div className="stack">
        <label className="label" htmlFor={`lr-${id}`}>The reason the renter sees</label>
        <input className="input" id={`lr-${id}`} value={reason} onChange={(e) => setReason(e.target.value)} placeholder="Photo unreadable, expired, name does not match" data-testid={`licence-${kind}-reason`} />
        <button className="btn btn--ghost fd-wide" type="button" disabled={pending || reason.trim().length < 5} onClick={() => onReject(reason.trim())} data-testid={`licence-${kind}-reject`}>Reject</button>
      </div>
    </details>
  );
}

function Shot({ u, pending, reject }: { u: DocUpload; pending: boolean; reject: (reason: string) => void }) {
  return (
    <div className="fd-lic__doc" data-testid={`licence-doc-${u.kind}`}>
      <p className="fd-lic__kind"><b>{KIND[u.kind] ?? u.kind.replace(/_/g, ' ')}</b> <span className={`fd-chip is-${u.status === 'approved' ? 'done' : u.status === 'rejected' ? 'blocked' : 'scheduled'}`}>{u.status === 'submitted' ? 'Waiting' : u.status === 'approved' ? 'Approved' : 'Rejected'}</span></p>
      {u.status === 'submitted' && u.url ? (u.mime_type === 'application/pdf'
        ? <p><a className="link" href={u.url} target="_blank" rel="noreferrer">Open the PDF (link valid one minute)</a></p>
        // eslint-disable-next-line @next/next/no-img-element -- a one-minute signed private image, never cached
        : <img className="fd-lic__img" src={u.url} alt={KIND[u.kind] ?? u.kind} referrerPolicy="no-referrer" />) : null}
      {u.status === 'rejected' && u.reject_reason && <p className="small muted">Rejected: {u.reject_reason}</p>}
      {u.status === 'submitted' && <Reject kind={u.kind} pending={pending} onReject={reject} />}
    </div>
  );
}

export function LicenceReview({ job, waiting, label = 'Review the licence' }: { job: string; waiting: number; label?: string }) {
  const router = useRouter();
  const uid = useId().replace(/[^\w-]/g, '');
  const [open, setOpen] = useState(false);
  const [d, setD] = useState<LicenceReviewData | null>(null);
  const [msg, setMsg] = useState<{ ok: boolean; text: string } | null>(null);
  const [pending, start] = useTransition();
  const [acted, setActed] = useState(false);
  const reload = async () => { const r = await fieldLicenceLoad(job); if (r.ok) setD(r.data); else setMsg({ ok: false, text: r.message }); };
  const toggle = () => {
    // the lists behind this panel are refreshed when it closes (a refresh while it is open would take the card, and this message, away)
    if (open) { setOpen(false); if (acted) { setActed(false); router.refresh(); } return; }
    setOpen(true); setD(null); setMsg(null);
    start(async () => { await reload(); });
  };
  const reject = (upload: string, kind: string, reason: string) => start(async () => {
    setMsg(null);
    const r = await fieldAct('licence_reject', { job, upload, reason });
    if (!r.ok) { setMsg({ ok: false, text: r.message }); return; }
    await reload();
    setActed(true);
    setMsg({ ok: true, text: `${KIND[kind] ?? 'Image'} rejected. The renter is told why and sends a new one.` });
  });
  const approveAll = () => start(async () => {
    setMsg(null);
    let r: Awaited<ReturnType<typeof fieldAct<{ approved: number; refused: Array<{ item: string; message: string }> }>>>;
    try { r = await fieldAct<{ approved: number; refused: Array<{ item: string; message: string }> }>('licence_approve_all', { job }); } catch { setMsg({ ok: false, text: 'No connection. Nothing was saved: try again when you have signal.' }); return; }
    if (!r.ok) { setMsg({ ok: false, text: r.message }); return; }
    await reload();
    setActed(true);
    const n = r.data.approved;
    setMsg(r.data.refused.length
      ? { ok: false, text: `${n} approved. Not approved: ${r.data.refused.map((x) => `${x.item} (${x.message.replace(/^.*?ERROR:\s*/, '')})`).join('; ')}.` }
      : { ok: true, text: `${n} approved.` });
  });
  const left = d ? d.uploads.filter((u) => u.status === 'submitted').length : waiting;
  return (
    <div className="fd-act fd-lic" data-testid="licence-review">
      <button className={`btn ${open ? 'btn--ghost' : 'btn--primary'} fd-wide`} type="button" aria-expanded={open} aria-controls={`${uid}-p`} onClick={toggle} data-testid="licence-review-open">{open ? 'Close' : label}</button>
      {open && (
        <div className="fd-sheet" id={`${uid}-p`} role="group" aria-label="Licence review" data-testid="licence-review-panel">
          {!d && !msg && <p className="small muted" role="status">Loading</p>}
          {d && (
            <>
              <p className="small">{d.renter_name}, {d.vehicle_name}. Pickup {day(d.pickup_at)}, return {day(d.return_at)}. Identity {d.readiness.all_drivers_verified ? 'verified' : 'not verified yet'}.</p>
              {left <= 0
                ? <p className="alert alert--ok small" role="status" data-testid="licence-review-done"><span>Nothing waiting for review.</span></p>
                : <div className="stack" data-testid="licence-review-checks">
                    <p className="fd-sheet__h">Look at each image, then approve them together</p>
                    <ul className="small">{CHECKS.map((c) => <li key={c}>{c}</li>)}</ul>
                    <button className="btn btn--primary fd-wide" type="button" disabled={pending} onClick={approveAll} data-testid="licence-approve-all">{pending ? 'Working' : `Approve all (${left})`}</button>
                    <p className="small muted">One wrong? Reject that one first, with the reason.</p>
                  </div>}
            </>
          )}
          {msg && <p className={`alert ${msg.ok ? 'alert--ok' : 'alert--error'} small`} role={msg.ok ? 'status' : 'alert'} data-testid="licence-review-msg"><span>{msg.text}</span></p>}
          {d?.drivers.map((dr) => {
            const ups = d.uploads.filter((u) => u.driver_id === dr.driver_id);
            return (
              <section key={dr.driver_id} className="fd-lic__driver stack" aria-label={dr.full_name}>
                <p><b>{dr.full_name}</b> <span className="small muted">{dr.role.replace(/_/g, ' ')}{dr.verified_on ? ', verified' : ''}</span></p>
                <p className="small muted">Born {dr.date_of_birth ?? 'not given'} · licence {dr.licence_number ?? 'not given'} {dr.licence_class ?? ''} · expires {dr.licence_expiry ?? 'not given'}</p>
                {ups.length ? ups.map((u) => <Shot key={u.id} u={u} pending={pending} reject={(reason) => reject(u.id, u.kind, reason)} />) : <p className="small muted">Nothing uploaded for this driver.</p>}
              </section>);
          })}
        </div>)}
    </div>
  );
}
