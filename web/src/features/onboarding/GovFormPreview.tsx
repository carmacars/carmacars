'use client';
import { useEffect, useState } from 'react';
import type { Spec } from '@/features/official-forms/fill';

// One government form shown to the owner before they sign it (r35, 1000): the official PDF exactly as the publisher issues
// it, with only its text boxes filled in this browser from the values on record (the same fill as the download), in a frame
// on the page. A form that is not in use as the official PDF shows its data sheet. Nothing is added to the PDF.
export function GovFormPreview({ fill, formCode, official, fieldValues, fieldMap, dataSheet, templateHref }: {
  fill: string; formCode: string; official: boolean; fieldValues: Record<string, string | null>; fieldMap: Record<string, Spec | string>;
  dataSheet: Array<{ label: string; value: string | null }>; templateHref?: string;
}) {
  const [open, setOpen] = useState(false);
  const [url, setUrl] = useState<string | null>(null);
  const [xfa, setXfa] = useState(false);
  const [err, setErr] = useState<string | null>(null);
  useEffect(() => {
    if (!open || !official || url) return;
    let live = true; let made: string | null = null;
    (async () => {
      try {
        const r = await fetch(templateHref ?? `/owner/documents/forms/${fill}/template`);
        if (!r.ok) throw new Error('The form could not be opened. Try again.');
        const { fillPdf } = await import('@/features/official-forms/fill');
        const out = await fillPdf(await r.arrayBuffer(), fieldValues, fieldMap);
        made = URL.createObjectURL(new Blob([out.bytes as unknown as BlobPart], { type: 'application/pdf' }));
        if (live) { setUrl(made); setXfa(out.xfaOnly); }
      } catch (e) { if (live) setErr(e instanceof Error ? e.message : 'The form could not be shown.'); }
    })();
    return () => { live = false; };
  }, [open, official, url, fill, fieldValues, fieldMap, templateHref]);
  useEffect(() => () => { if (url) URL.revokeObjectURL(url); }, [url]);
  return (
    <div className="stack" data-testid="gov-form-preview" data-code={formCode}>
      <div className="row"><button type="button" className="btn btn--ghost btn--sm" aria-expanded={open} onClick={() => setOpen((x) => !x)} data-testid="gov-form-show">{open ? 'Hide the form' : 'Show the form'}</button></div>
      {open && !official && (
        <div className="table-scroll ad-scroll" tabIndex={0} role="region" aria-label={`Values of ${formCode}`}>
          <table className="ad-table ad-table--dense gf-sign__values"><thead><tr><th scope="col">Field</th><th scope="col">Value</th></tr></thead>
            <tbody>{dataSheet.map((r) => <tr key={r.label}><th scope="row" className="small">{r.label}</th><td className="small">{r.value ?? <span className="muted">to fill in</span>}</td></tr>)}</tbody></table>
        </div>)}
      {open && official && !url && !err && <p className="small muted" role="status">Preparing the form</p>}
      {open && official && err && <p className="alert alert--error" role="alert"><span>{err}</span></p>}
      {open && official && url && (xfa
        ? <p className="small">This form is an Adobe form: <a className="link" href={url} target="_blank" rel="noreferrer">open it in Adobe Acrobat Reader</a> (free) to read it. Other PDF viewers show a blank page, as they do with the form from ServiceOntario.</p>
        : <iframe className="gf-sign__frame" title={`${formCode}, the official form filled in`} src={url} data-testid="gov-form-frame" />)}
    </div>
  );
}
