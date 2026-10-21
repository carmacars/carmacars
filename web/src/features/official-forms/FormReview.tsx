'use client';
import { useCallback, useEffect, useRef, useState, useTransition } from 'react';
import { useRouter } from 'next/navigation';
import { staffDo, staffRead } from '@/server/actions/staff-tools';
import type { Spec } from './fill';

// "Review and check" for one official ServiceOntario form (migration 0079): a pop-up with the form filled for one
// real car, page by page, the fields filled and the ones the PDF does not have, then one press of "Checked: use for
// owners" with the mapping already saved. Opens by itself from a link to /admin/settings/forms#<form code> (the To do
// line of a form not checked yet). Until a form is checked, owners get the data sheet instead of the official PDF.
type Props = { code: string; templateId: string; fieldMap: Record<string, Spec | string>; vehicles: Array<{ id: string; name: string; owner: string }> };
type Shown = { pages: string[]; filled: number; missing: string[]; empty: string[] };

export function FormReview({ code, templateId, fieldMap, vehicles }: Props) {
  const router = useRouter();
  const dlg = useRef<HTMLDialogElement>(null);
  const [vehicle, setVehicle] = useState(vehicles[0]?.id ?? '');
  const [shown, setShown] = useState<Shown | null>(null);
  const [msg, setMsg] = useState<{ ok: boolean; text: string } | null>(null);
  const [loading, setLoading] = useState(false);
  const [pending, start] = useTransition();
  const tid = `form-review-${code}`;

  const load = useCallback(async (v: string) => {
    setLoading(true); setShown(null); setMsg(null);
    try {
      if (!v) throw new Error('Add a car first: the sample is the form filled for one of the cars.');
      const r = await staffRead<{ values: Record<string, string | null>; field_map: Record<string, Spec> }>('form_template_preview', { template: templateId, vehicle: v });
      if (!r.ok) throw new Error(r.message);
      const file = await fetch(`/api/staff/form-template/${templateId}`);
      if (!file.ok) throw new Error('The official PDF could not be opened.');
      const { fillPdf } = await import('./fill');
      const out = await fillPdf(await file.arrayBuffer(), r.data.values, r.data.field_map, { flatten: true });
      const { openPdf, pageJpeg } = await import('@/features/tolls/pdf');
      const doc = await openPdf(out.bytes);
      const pages: string[] = [];
      for (let n = 1; n <= Math.min(doc.numPages, 6); n++) pages.push(await pageJpeg(doc, n, 1400));
      const empty = Object.entries(r.data.values).filter(([, x]) => x === null || x === '').map(([k]) => k);
      setShown({ pages, filled: out.filled.length, missing: out.missing, empty });
    } catch (e) {
      setMsg({ ok: false, text: e instanceof Error ? e.message : 'The sample could not be made.' });
    } finally { setLoading(false); }
  }, [templateId]);

  const open = useCallback(() => { dlg.current?.showModal(); void load(vehicle); }, [load, vehicle]);

  // a link to this form (#<code>) opens the review at once
  useEffect(() => {
    const h = decodeURIComponent(window.location.hash.replace(/^#/, ''));
    if (h !== code && h !== `review-${code}`) return;
    document.getElementById(`form-card-${code}`)?.scrollIntoView({ block: 'start' });
    const t = window.setTimeout(open, 0);
    return () => window.clearTimeout(t);
    // only on arrival
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, []);

  const verify = () => start(async () => {
    const r = await staffDo<{ refilled: number }>('form_template_map', { template: templateId, field_map: fieldMap, verify: true }, ['/admin/settings/forms', '/admin']);
    if (!r.ok) { setMsg({ ok: false, text: r.message }); return; }
    setMsg({ ok: true, text: `Checked and in use: ${r.data.refilled} owner form(s) filled again from the official PDF.` });
    router.refresh();
  });

  return (
    <>
      <button className="btn btn--primary btn--sm" type="button" onClick={open} aria-haspopup="dialog" data-testid={tid}>Review and check</button>
      <dialog ref={dlg} className="ad-dialog ad-dialog--wide" aria-labelledby={`${tid}-t`} data-testid={`${tid}-dialog`}>
        <h2 className="d4" id={`${tid}-t`}>Check {code}, filled for a car</h2>
        <p className="small">Read each value against the form. If they are right, press {'"'}Checked: use for owners{'"'}: owners then sign the official form instead of the data sheet.</p>
        {vehicles.length > 1 && (
          <div className="row">
            <label className="label" htmlFor={`${tid}-car`}>Car</label>
            <select className="select" id={`${tid}-car`} value={vehicle} onChange={(e) => { setVehicle(e.target.value); void load(e.target.value); }}>
              {vehicles.map((v) => <option key={v.id} value={v.id}>{v.name} ({v.owner})</option>)}
            </select>
          </div>
        )}
        {loading && <p className="small" role="status">Filling the form</p>}
        {shown && (
          <div className="stack" data-testid={`${tid}-sample`}>
            <p className="small" role="status">{shown.filled} field(s) filled.{shown.empty.length ? ` Empty for this car: ${shown.empty.join(', ')}.` : ''}{shown.missing.length ? ` Not in the PDF: ${shown.missing.join(', ')}.` : ''}</p>
            <div className="ad-form-pages">{shown.pages.map((src, i) => /* a page drawn in the browser (a data URL) */ // eslint-disable-next-line @next/next/no-img-element
              <img key={i} src={src} alt={`${code}, page ${i + 1}, filled`} width={700} />)}</div>
          </div>
        )}
        {msg && <p className={`alert ${msg.ok ? 'alert--ok' : 'alert--error'}`} role={msg.ok ? 'status' : 'alert'}><span>{msg.text}</span></p>}
        <div className="row">
          {!msg?.ok && <button className="btn btn--primary btn--sm" type="button" disabled={pending || loading || !shown} onClick={verify} data-testid={`${tid}-verify`}>Checked: use for owners</button>}
          <button className="btn btn--ghost btn--sm" type="button" onClick={() => dlg.current?.close()}>{msg?.ok ? 'Close' : 'Not yet'}</button>
        </div>
      </dialog>
    </>
  );
}
