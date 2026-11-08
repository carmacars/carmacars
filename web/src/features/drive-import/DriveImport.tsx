'use client';
import { useCallback, useEffect, useMemo, useRef, useState, useTransition } from 'react';
import { useRouter } from 'next/navigation';
import { driveImportCancel, driveImportCars, driveImportConfirm, driveImportGet, driveImportList, driveImportRetry, driveImportStart } from '@/server/actions/drive-import';
import { parseDriveLink } from './drive-folder';
import { summaryLines } from './summary';
import type { CarOption, FolderRow, ImportView, RunRow } from './types';

// Import photos from a Google Drive link (release 33, migration 0760). One component for the two places it lives:
//   * on a car's listing page (`vehicle` given): paste the link, the folder's photos go to that car;
//   * on Cars > Import photos from Drive (no `vehicle`): paste the top folder's link, each folder with photos is matched to a
//     car on the platform, the table is confirmed or changed here, then the photos are imported.
// The page follows the run by itself (every few seconds while it works) and ends with a summary: imported, skipped, failed and why.
const ACTIVE = new Set(['scanning', 'importing']);
const STATUS: Record<string, string> = { scanning: 'Reading the folders', review: 'Confirm the cars', importing: 'Importing the photos', done: 'Done', failed: 'Stopped', cancelled: 'Cancelled' };

export function DriveImport({ vehicle, runs: initialRuns = [], refresh = [] }: { vehicle?: { id: string; label: string }; runs?: RunRow[]; refresh?: string[] }) {
  const router = useRouter();
  const [link, setLink] = useState('');
  const [submit, setSubmit] = useState(true);
  const [view, setView] = useState<ImportView | null>(null);
  const [runs, setRuns] = useState(initialRuns);
  const [msg, setMsg] = useState<{ ok: boolean; text: string } | null>(null);
  const [pending, start] = useTransition();
  const [cars, setCars] = useState<CarOption[] | null>(null);
  const [choice, setChoice] = useState<Record<string, { vehicle: string; include: boolean }>>({});
  const id = view?.import.id ?? null;
  const status = view?.import.status ?? null;
  const loaded = useRef<string | null>(null);

  const prev = useRef<string | null>(null);
  const reloadRuns = useCallback(async () => { const r = await driveImportList(vehicle?.id ?? null); if (r.ok) setRuns(r.data); }, [vehicle?.id]);
  const load = useCallback(async (runId: string) => {
    const r = await driveImportGet(runId);
    if (!r.ok) { setMsg({ ok: false, text: r.message }); return null; }
    const d = r.data;
    setView(d);
    // the table of a bulk run: the proposals, and the cars to choose from
    if (d.import.status === 'review' && loaded.current !== d.import.id) {
      loaded.current = d.import.id;
      setChoice(Object.fromEntries(d.folders.filter((f) => f.images > 0).map((f) => [f.id, { vehicle: f.vehicle_id ?? '', include: f.include }])));
      void driveImportCars().then((c) => { if (c.ok) setCars(c.data); });
    }
    // the run ended while the page followed it: the lists on the page are read again
    if (prev.current && ACTIVE.has(prev.current) && ['done', 'failed', 'cancelled'].includes(d.import.status)) { void reloadRuns(); router.refresh(); }
    prev.current = d.import.status;
    return d;
  }, [reloadRuns, router]);

  // follow a run that works
  useEffect(() => {
    if (!id || !status || !ACTIVE.has(status)) return;
    const t = setInterval(() => { void load(id); }, 4000);
    return () => clearInterval(t);
  }, [id, status, load]);
  const parsed = parseDriveLink(link);
  const begin = () => start(async () => {
    setMsg(null);
    const r = await driveImportStart(link, vehicle?.id ?? null, submit);
    if (!r.ok) { setMsg({ ok: false, text: r.message }); return; }
    setLink('');
    loaded.current = null;
    await load(r.data.id);
  });
  const open = (runId: string) => start(async () => { setMsg(null); loaded.current = null; await load(runId); });
  const confirm = () => start(async () => {
    if (!id) return;
    const rows = Object.entries(choice).map(([folder, c]) => ({ folder, vehicle: c.vehicle || null, include: c.include && !!c.vehicle }));
    const r = await driveImportConfirm(id, rows, submit);
    if (!r.ok) { setMsg({ ok: false, text: r.message }); return; }
    setMsg({ ok: true, text: `Importing ${r.data.photos} photos from ${r.data.folders} folders. This page follows it.` });
    await load(id);
  });
  const cancel = () => start(async () => { if (!id) return; const r = await driveImportCancel(id); if (!r.ok) setMsg({ ok: false, text: r.message }); await load(id); });
  const retry = () => start(async () => { if (!id) return; const r = await driveImportRetry(id, refresh); if (!r.ok) setMsg({ ok: false, text: r.message }); else setMsg({ ok: true, text: 'Trying the failed photos again.' }); await load(id); });

  const chosen = Object.values(choice).filter((c) => c.include && c.vehicle).length;
  const photos = view ? view.folders.filter((f) => choice[f.id]?.include && choice[f.id]?.vehicle).reduce((n, f) => n + f.images, 0) : 0;
  const active = !!view && !['done', 'failed', 'cancelled'].includes(view.import.status);

  return (
    <div className="stack" data-testid="drive-import">
      {!active && (
        <form className="pt-card ad-card ad-form" onSubmit={(e) => { e.preventDefault(); if (parsed?.kind === 'folder') begin(); }} data-testid="drive-import-form">
          <h2 className="d5">{vehicle ? 'Import photos from a Google Drive link' : 'Import the photos of many cars from a Google Drive folder'}</h2>
          <p className="small muted">
            {vehicle
              ? `Paste the link of a Drive folder shared with "Anyone with the link". Every photo in it, and in the folders inside it, goes to ${vehicle.label} as if you had added it with Add photos.`
              : 'Paste the link of the top folder (for example one folder per make, then one per car), shared with "Anyone with the link". Each folder with photos is matched to a car on the platform by the year, make, model, colour and plate in its name; you confirm or change the table before anything is imported.'}
            {' '}Photos only (JPG, PNG, HEIC, WebP, up to 15 MB each); repeating a link never adds a photo twice.
          </p>
          <div className="ad-fields">
            <div className="field ad-field"><label className="label" htmlFor="di-link">Google Drive folder link</label>
              <input className="input" id="di-link" type="text" inputMode="url" autoComplete="off" placeholder="https://drive.google.com/drive/folders/..." value={link} onChange={(e) => setLink(e.target.value)} data-testid="drive-import-link" /></div>
          </div>
          <label className="check small"><input type="checkbox" checked={submit} onChange={(e) => setSubmit(e.target.checked)} data-testid="drive-import-submit" /> Submit the listing for processing when its photos are in</label>
          {link.trim() && !parsed && <p className="small" role="alert">That is not a Google Drive link.</p>}
          {parsed?.kind === 'file' && <p className="small" role="alert">That is the link of one file. Paste the link of the folder.</p>}
          <div className="row"><button className="btn btn--primary btn--sm" type="submit" disabled={pending || parsed?.kind !== 'folder'} data-testid="drive-import-start">{vehicle ? 'Import the photos' : 'Read the folder'}</button></div>
        </form>
      )}
      {msg && <p className={`alert${msg.ok ? '' : ' alert--error'}`} role={msg.ok ? 'status' : 'alert'}><span>{msg.text}</span></p>}

      {view && (
        <section className="pt-card ad-card" aria-labelledby="di-run" data-testid="drive-import-run" data-status={view.import.status}>
          <h2 className="d5" id="di-run">{STATUS[view.import.status]}{view.import.vehicle ? `: ${view.import.vehicle}` : ''}</h2>
          <RunBody view={view} choice={choice} setChoice={setChoice} cars={cars} />
          {view.import.status === 'review' && (
            <div className="row">
              <button className="btn btn--primary btn--sm" type="button" disabled={pending || chosen === 0} onClick={confirm} data-testid="drive-import-confirm">Import {photos} photos from {chosen} folders</button>
              <button className="btn btn--ghost btn--sm" type="button" disabled={pending} onClick={cancel}>Cancel</button>
            </div>
          )}
          {ACTIVE.has(view.import.status) && <div className="row"><button className="btn btn--ghost btn--sm" type="button" disabled={pending} onClick={cancel} data-testid="drive-import-cancel">Cancel the import</button></div>}
          {['done', 'failed', 'cancelled'].includes(view.import.status) && (
            <div className="row">
              {(view.import.totals.failed ?? 0) > 0 && view.import.scanned && <button className="btn btn--ghost btn--sm" type="button" disabled={pending} onClick={retry} data-testid="drive-import-retry">Try the failed photos again</button>}
              <button className="btn btn--ghost btn--sm" type="button" onClick={() => { setView(null); setMsg(null); }}>Import another folder</button>
            </div>
          )}
        </section>
      )}

      {!!runs.length && (
        <section className="pt-card ad-card" aria-labelledby="di-runs" data-testid="drive-import-runs">
          <h2 className="d5" id="di-runs">Earlier imports</h2>
          <ul className="stack small">
            {runs.map((r) => (
              <li key={r.id}><button type="button" className="link" onClick={() => open(r.id)}>{new Date(r.created_at).toLocaleString('en-CA', { dateStyle: 'medium', timeStyle: 'short' })}</button>
                {' '}{STATUS[r.status] ?? r.status}{r.vehicle ? `, ${r.vehicle}` : r.kind === 'bulk' ? ', many cars' : ''}{r.started_by ? `, by ${r.started_by}` : ''}
                {' '}<span className="muted">{summaryLines(r.totals).join(', ')}</span></li>))}
          </ul>
        </section>
      )}
    </div>
  );
}

function RunBody({ view, choice, setChoice, cars }: { view: ImportView; choice: Record<string, { vehicle: string; include: boolean }>; setChoice: (f: (c: Record<string, { vehicle: string; include: boolean }>) => Record<string, { vehicle: string; include: boolean }>) => void; cars: CarOption[] | null }) {
  const { import: im, folders } = view;
  const t = im.totals;
  const done = (t.imported ?? 0) + (t.skipped ?? 0) + (t.failed ?? 0);
  const found = t.found ?? 0;
  const pct = found ? Math.min(100, Math.round((100 * done) / found)) : 0;
  if (im.status === 'scanning') {
    const read = folders.filter((f) => f.state !== 'pending').length;
    return (<p className="small" role="status">Reading the folders: {read} of {folders.length} read, {found} photos found so far. This page updates by itself; you can leave it and come back.</p>);
  }
  if (im.status === 'review') return <ReviewTable folders={folders} choice={choice} setChoice={setChoice} cars={cars} />;
  return (
    <>
      {(im.status === 'importing' || found > 0) && (
        <>
          <div className="lc__progress" role="progressbar" aria-valuemin={0} aria-valuemax={found} aria-valuenow={done} aria-label="Photos imported" data-testid="drive-import-progress"><span style={{ width: `${pct}%` }} /></div>
          <p className="small" role="status">{im.status === 'importing' ? `Importing: ${done} of ${found} photos done.` : `${done} of ${found} photos.`} {summaryLines(t).join(', ')}.</p>
        </>
      )}
      {im.error && <p className="alert alert--error" role="alert"><span>{im.error}</span></p>}
      {im.status === 'done' && (t.submitted ?? 0) > 0 && <p className="small">{t.submitted} {t.submitted === 1 ? 'listing was' : 'listings were'} submitted: the photos are being framed on the studio background and checked for plates.</p>}
      {im.status === 'done' && (t.not_submitted ?? []).length > 0 && (
        <p className="small">Not submitted yet: {t.not_submitted!.map((n) => `${n.vehicle} (${n.reason})`).join('; ')}. Add what is missing, then press Submit for listing on the listing page.</p>)}
      {im.status === 'done' && (t.submitted ?? 0) === 0 && (t.not_submitted ?? []).length === 0 && (t.imported ?? 0) > 0 && <p className="small">The photos are in the listing{(t.cars ?? 0) > 1 ? 's' : ''}; press Submit for listing on the listing page when the car has what it needs.</p>}
      <Problems view={view} />
    </>
  );
}

function Problems({ view }: { view: ImportView }) {
  const bad = view.problems;
  const notes = view.folders.filter((f) => f.error || f.note);
  if (!bad.length && !notes.length) return null;
  return (
    <details className="small" data-testid="drive-import-problems" open={bad.some((b) => b.state === 'failed')}>
      <summary>{bad.filter((b) => b.state === 'failed').length} failed, {bad.filter((b) => b.state === 'skipped').length} skipped: why</summary>
      <ul className="stack">
        {notes.map((f) => <li key={f.id}><b>{f.path || 'The link'}</b>: {f.error ?? f.note}</li>)}
        {bad.map((b, i) => <li key={i}><b>{b.state === 'failed' ? 'Failed' : 'Skipped'}</b> {b.path ? `${b.path.replace(/^\//, '')}/` : ''}{b.name}: {b.reason}</li>)}
      </ul>
    </details>
  );
}

function ReviewTable({ folders, choice, setChoice, cars }: { folders: FolderRow[]; choice: Record<string, { vehicle: string; include: boolean }>; setChoice: (f: (c: Record<string, { vehicle: string; include: boolean }>) => Record<string, { vehicle: string; include: boolean }>) => void; cars: CarOption[] | null }) {
  const withPhotos = folders.filter((f) => f.images > 0);
  const byId = useMemo(() => new Map((cars ?? []).map((c) => [c.id, c])), [cars]);
  if (!withPhotos.length) return <p className="small">No folder holds photos.</p>;
  const set = (id: string, patch: Partial<{ vehicle: string; include: boolean }>) => setChoice((c) => ({ ...c, [id]: { ...(c[id] ?? { vehicle: '', include: false }), ...patch } }));
  return (
    <div className="table-scroll ad-scroll" role="region" aria-label="Folders and the car each is for" tabIndex={0}>
      <table className="ad-table ad-table--dense" data-testid="drive-import-table">
        <thead><tr><th scope="col">Import</th><th scope="col">Folder</th><th scope="col" className="num">Photos</th><th scope="col">Car</th><th scope="col">Why</th></tr></thead>
        <tbody>
          {withPhotos.map((f) => {
            const c = choice[f.id] ?? { vehicle: '', include: false };
            const likely = f.candidates.map((x) => byId.get(x.vehicle_id)).filter((x): x is CarOption => !!x);
            const likelyIds = new Set(likely.map((x) => x.id));
            const currentMissing = c.vehicle && !byId.has(c.vehicle) ? f.vehicle ?? c.vehicle : null;
            return (
              <tr key={f.id} data-testid="drive-import-row">
                <td><input type="checkbox" checked={c.include && !!c.vehicle} disabled={!c.vehicle} aria-label={`Import ${f.name}`} onChange={(e) => set(f.id, { include: e.target.checked })} /></td>
                <td><span title={f.path}>{f.path.replace(/^\//, '') || f.name}</span></td>
                <td className="num">{f.images}{f.other ? <span className="muted"> (+{f.other} other files)</span> : null}</td>
                <td>
                  <select className="select" aria-label={`Car for ${f.name}`} value={c.vehicle} onChange={(e) => set(f.id, { vehicle: e.target.value, include: !!e.target.value })}>
                    <option value="">Do not import this folder</option>
                    {currentMissing && <option value={c.vehicle}>{currentMissing}</option>}
                    {likely.length > 0 && <optgroup label="Likely">{likely.map((x) => <option key={x.id} value={x.id}>{x.label}{x.partner ? ` · ${x.partner}` : ''}</option>)}</optgroup>}
                    <optgroup label="All cars">{(cars ?? []).filter((x) => !likelyIds.has(x.id)).map((x) => <option key={x.id} value={x.id}>{x.label}{x.partner ? ` · ${x.partner}` : ''}</option>)}</optgroup>
                  </select>
                </td>
                <td className="small">{f.ambiguous && <b>Check this one. </b>}{f.match_note ?? ''}{f.note ? ` ${f.note}` : ''}</td>
              </tr>);
          })}
        </tbody>
      </table>
    </div>
  );
}
