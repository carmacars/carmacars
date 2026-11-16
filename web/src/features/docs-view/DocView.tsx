'use client';
import { useState, useTransition } from 'react';
import { docViewOpen } from '@/server/actions/doc-view';
import { removedOn } from './types';

// r48 (3071): the View button of a reviewed renter document (Admin, customer service, Sales, field staff; never owners).
// Each press asks the server for a one-minute private link (the view is written to the audit log) and shows the image
// inline, or a link for a PDF. After the 90-day purge the line reads "Removed on <date>" and there is nothing to open.
export function DocView({ upload, label, purgedAt, call = 'ops_read', testId }: { upload: string; label: string; purgedAt?: string | null; call?: 'ops_read' | 'va_read' | 'field_read'; testId?: string }) {
  const [shown, setShown] = useState<{ url: string; pdf: boolean } | null>(null);
  const [removed, setRemoved] = useState<string | null>(purgedAt ?? null);
  const [err, setErr] = useState<string | null>(null);
  const [pending, start] = useTransition();
  const tid = testId ?? `doc-view-${upload}`;
  if (removed) return <p className="small muted" data-testid={`${tid}-removed`}>{removedOn(removed)}</p>;
  const open = () => start(async () => {
    setErr(null);
    const r = await docViewOpen(upload, call);
    if (!r.ok) { setErr(r.message); return; }
    if (r.data.removed_on) { setRemoved(r.data.removed_on); return; }
    if (r.data.url) setShown({ url: r.data.url, pdf: r.data.mime_type === 'application/pdf' });
  });
  return (
    <div className="stack" data-testid={tid}>
      {!shown && <button className="btn btn--ghost btn--sm" type="button" disabled={pending} onClick={open} aria-label={`View ${label}`} data-testid={`${tid}-open`}>{pending ? 'Opening' : 'View'}</button>}
      {shown && (shown.pdf
        ? <p><a className="link" href={shown.url} target="_blank" rel="noreferrer" data-testid={`${tid}-link`}>Open the PDF (link valid one minute)</a></p>
        // eslint-disable-next-line @next/next/no-img-element -- a one-minute signed private image, never cached
        : <img className="ad-idimg" src={shown.url} alt={label} referrerPolicy="no-referrer" data-testid={`${tid}-img`} />)}
      {shown && <button className="btn btn--quiet btn--sm" type="button" onClick={() => setShown(null)}>Hide</button>}
      {err && <p className="small alert alert--error" role="alert"><span>{err}</span></p>}
    </div>
  );
}
