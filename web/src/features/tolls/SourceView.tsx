'use client';
import { useEffect, useRef, useState } from 'react';
import type { Box } from './parse';

// The notice beside its lines: a PDF page drawn in the browser (pdf.js), a photo or scan as it is, or the rows of a
// CSV. The line being checked is marked on its page when the reading knows where it was.
export function SourceView({ src, mime, name, mark }: { src: string; mime: string | null; name: string | null; mark: (Box & { line?: number }) | null }) {
  const isPdf = mime === 'application/pdf' || /\.pdf$/i.test(name ?? '');
  const isCsv = mime === 'text/csv' || /\.csv$/i.test(name ?? '');
  const canvas = useRef<HTMLCanvasElement>(null);
  const wrap = useRef<HTMLDivElement>(null);
  const doc = useRef<import('./pdf').PdfDoc | null>(null);
  const [pages, setPages] = useState(0);
  const [page, setPage] = useState(1);
  const [csv, setCsv] = useState<string[] | null>(null);
  const [err, setErr] = useState<string | null>(null);
  const [zoom, setZoom] = useState(false);

  useEffect(() => {
    let gone = false;
    (async () => {
      try {
        const r = await fetch(src);
        if (!r.ok) throw new Error('The file could not be opened.');
        if (isPdf) {
          const { openPdf } = await import('./pdf');
          doc.current = await openPdf(await r.arrayBuffer());
          if (!gone) setPages(doc.current.numPages);
        } else if (isCsv) {
          const t = await r.text();
          if (!gone) setCsv(t.split(/\r?\n/).filter((x) => x.trim()));
        }
      } catch (e) { if (!gone) setErr(e instanceof Error ? e.message : 'The file could not be opened.'); }
    })();
    return () => { gone = true; };
  }, [src, isPdf, isCsv]);

  // a new line chosen: show its page (state adjusted while rendering, as React advises for derived state)
  const [seen, setSeen] = useState(mark);
  if (mark !== seen) { setSeen(mark); if (mark?.page) setPage(mark.page); }

  useEffect(() => {
    if (!isPdf || !pages || !doc.current || !canvas.current) return;
    let gone = false;
    (async () => {
      const { drawPage } = await import('./pdf');
      const w = Math.min(1400, Math.max(320, (wrap.current?.clientWidth ?? 600) * (zoom ? 2 : 1)) * (window.devicePixelRatio > 1 ? 1.5 : 1));
      if (!gone && canvas.current) await drawPage(doc.current!, page, canvas.current, Math.round(w)).catch(() => setErr('This page could not be drawn.'));
    })();
    return () => { gone = true; };
  }, [isPdf, pages, page, zoom]);

  return (
    <section className="pt-card ad-card tr-source" aria-labelledby="tr-src" data-testid="toll-source">
      <div className="pt-card__head"><h2 className="d4" id="tr-src">The notice</h2>
        <span className="row">
          {isPdf && pages > 1 && <span className="small" aria-live="polite">Page {page} of {pages}</span>}
          {isPdf && pages > 1 && <><button type="button" className="btn btn--ghost btn--sm" disabled={page <= 1} onClick={() => setPage(page - 1)}>Previous page</button>
            <button type="button" className="btn btn--ghost btn--sm" disabled={page >= pages} onClick={() => setPage(page + 1)}>Next page</button></>}
          {!isCsv && <button type="button" className="btn btn--ghost btn--sm" aria-pressed={zoom} onClick={() => setZoom(!zoom)}>{zoom ? 'Fit' : 'Zoom'}</button>}
          <a className="link small" href={src} target="_blank" rel="noreferrer">Open the file</a>
        </span></div>
      <div className={`tr-source__frame${zoom ? ' is-zoom' : ''}`} ref={wrap} tabIndex={0} role="region" aria-label="The notice, as uploaded">
        {err ? <p className="small ad-err">{err}</p>
          : isPdf ? <div className="tr-source__page"><canvas ref={canvas} aria-label={`Page ${page} of the notice`} role="img" />
              {mark && mark.page === page && <span className="tr-source__mark" style={{ top: `${Math.max(0, mark.y * 100 - 0.5)}%`, height: `${Math.max(1.5, mark.h * 100 + 1)}%` }} aria-hidden="true" />}</div>
          : isCsv ? <ol className="tr-source__csv">{(csv ?? []).slice(0, 2000).map((l, i) => <li key={i} className={mark?.line === i ? 'is-mark' : undefined}>{l}</li>)}</ol>
          // eslint-disable-next-line @next/next/no-img-element -- the uploaded scan as it is, from a private link
          : <img src={src} alt="The notice as uploaded" className="tr-source__img" />}
      </div>
    </section>
  );
}
