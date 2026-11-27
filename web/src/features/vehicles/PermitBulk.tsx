'use client';
import { useState, useTransition } from 'react';
import { useRouter } from 'next/navigation';
import { filePermit } from '@/server/actions/ops-uploads';
import { staffDo } from '@/server/actions/staff-tools';
import { PHOTO_ACCEPT } from '@/features/uploads/formats';
import type { PermitRead } from './permit-read';
import { WhyDisabled } from '@/components/WhyDisabled';

// Ownership documents in bulk (migration 5144): choose many permit photos or PDFs at once; each is read for its VIN and plate
// (the permit reader of 0290), stored, and filed on its car by the database (by the VIN, else the plate); the owner sees it in
// their portal. A file that matched no car waits below for a quick pick, or is set aside with the reason.
export type Waiting = { id: string; file_name: string | null; vin: string | null; plate: string | null; note: string | null; document_id: string | null; created_at: string };
export type Filed = { id: string; file_name: string | null; vin: string | null; plate: string | null; vehicle_name: string | null; matched_by: string | null; note: string | null; document_id: string | null; filed_at: string };
export type PermitCar = { id: string; name: string; plate: string | null; vin: string | null; owner_name: string | null };
type Row = { key: string; name: string; state: 'reading' | 'filing' | 'filed' | 'waiting' | 'failed'; text: string };
const HOW: Record<string, string> = { vin: 'by its VIN', plate: 'by its plate', hand: 'picked by hand' };

export function PermitBulk({ waiting, filed, cars, base }: { waiting: Waiting[]; filed: Filed[]; cars: PermitCar[]; base: '/admin' | '/staff' }) {
  const router = useRouter();
  const [rows, setRows] = useState<Row[]>([]);
  const [busy, setBusy] = useState(false);
  const [pick, setPick] = useState<Record<string, string>>({});
  const [why, setWhy] = useState<Record<string, string>>({});
  const [err, setErr] = useState<Record<string, string>>({});
  const [pending, start] = useTransition();
  const put = (key: string, r: Partial<Row>) => setRows((x) => x.map((y) => (y.key === key ? { ...y, ...r } : y)));

  async function run(files: FileList | null) {
    if (!files?.length) return;
    setBusy(true);
    const list = Array.from(files).slice(0, 100).map((f) => ({ f, key: crypto.randomUUID() }));
    setRows((x) => [...list.map(({ f, key }) => ({ key, name: f.name, state: 'reading' as const, text: 'Reading the VIN and plate' })), ...x]);
    const { toStandardImage } = await import('@/features/uploads/standard-image');
    const { imageJpeg } = await import('@/features/tolls/pdf');
    for (const { f, key } of list) {
      let read: PermitRead | null = null; let upload: Blob = f;
      try {
        const std = await toStandardImage(f);
        // a PDF, JPEG or PNG is kept as it came; any other photo (HEIC, WEBP) as its standard JPEG
        if (!/^(application\/pdf|image\/jpeg|image\/png)$/.test(f.type) && !/\.(pdf|jpe?g|png)$/i.test(f.name)) upload = std;
        const img = await imageJpeg(std, 1600);
        const res = await fetch('/api/permit/read', { method: 'POST', headers: { 'content-type': 'application/json' }, body: JSON.stringify({ image: img.dataUrl }) });
        const j = (await res.json().catch(() => null)) as { ok: boolean; read?: PermitRead } | null;
        if (j?.ok && j.read) read = j.read;
      } catch { /* not readable: filed for a pick */ }
      put(key, { state: 'filing', text: read?.vin || read?.plate ? `Read ${[read.vin && `VIN ${read.vin}`, read.plate && `plate ${read.plate}`].filter(Boolean).join(', ')}: filing` : 'Nothing read: filing it for a pick' });
      const fd = new FormData();
      fd.set('file', upload instanceof File ? upload : new File([upload], f.name.replace(/\.[^.]+$/, '') + '.jpg', { type: 'image/jpeg' }));
      if (read?.vin) fd.set('vin', read.vin);
      if (read?.plate) fd.set('plate', read.plate);
      fd.set('read', JSON.stringify(read ? { vin: read.vin, plate: read.plate, year: read.year, make: read.make, model: read.model, confidence: read.confidence, problems: read.problems } : {}));
      const r = await filePermit(fd);
      if (!r.ok) put(key, { state: 'failed', text: r.message });
      else if (r.data.status === 'filed') put(key, { state: 'filed', text: `Filed on the ${r.data.vehicle_name}, ${HOW[r.data.matched_by ?? ''] ?? ''}${r.data.note ? `. ${r.data.note}` : ''}` });
      else put(key, { state: 'waiting', text: 'No car matched: pick it below' });
    }
    setBusy(false);
    router.refresh();
  }

  const act = (id: string, what: 'permit_assign' | 'permit_discard') => start(async () => {
    const r = await staffDo(what, what === 'permit_assign' ? { upload: id, vehicle_id: pick[id] } : { upload: id, reason: why[id] ?? '' }, [`${base}/ownership-documents`]);
    setErr((x) => ({ ...x, [id]: r.ok ? '' : r.message }));
    if (r.ok) router.refresh();
  });

  return (
    <div className="stack" data-testid="permit-bulk">
      <section className="pt-card ad-card stack" aria-labelledby="pb-h">
        <div className="pt-card__head"><h2 className="d4" id="pb-h">Upload ownership documents</h2></div>
        <p className="small muted">Choose as many permit photos or PDFs as you have. Each is read for its VIN and plate and filed on its car; the owner sees it in their portal. One that matches no car waits below for you to pick the car.</p>
        <label className="btn btn--primary" data-testid="permit-pick-label">{busy ? 'Working' : 'Choose the files'}
          <input className="vh" type="file" accept={PHOTO_ACCEPT} multiple disabled={busy} data-testid="permit-files" onChange={(e) => { void run(e.target.files); e.target.value = ''; }} /></label>
        {rows.length > 0 && <ol className="pb-rows" aria-live="polite" data-testid="permit-rows">{rows.map((r) => (
          <li key={r.key} data-state={r.state}><b className="pb-name">{r.name}</b> <span className="small">{r.text}</span></li>))}</ol>}
      </section>

      <section className="pt-card ad-card stack" aria-labelledby="pb-w">
        <div className="pt-card__head"><h2 className="d4" id="pb-w">Waiting for a car</h2><span className={`ad-b ${waiting.length ? 'ad-b--amber' : 'ad-b--light'}`}>{waiting.length}</span></div>
        {waiting.length === 0 ? <p className="small muted">Every uploaded permit is on its car.</p> : <ul className="pb-wait" data-testid="permit-waiting">{waiting.map((w) => (
          <li key={w.id} className="stack" data-testid={`permit-wait-${w.id}`}>
            <p className="small"><b>{w.file_name ?? 'Permit'}</b>{w.vin ? ` · VIN ${w.vin}` : ''}{w.plate ? ` · plate ${w.plate}` : ''}{w.document_id ? <> · <a className="link" href={`${base}/documents/${w.document_id}`} target="_blank" rel="noopener">Open the file</a></> : null}</p>
            {w.note && <p className="small muted">{w.note}</p>}
            <div className="ad-fields">
              <div className="field ad-field"><label className="label" htmlFor={`pb-car-${w.id}`}>Car</label>
                <select className="select" id={`pb-car-${w.id}`} value={pick[w.id] ?? ''} onChange={(e) => setPick((x) => ({ ...x, [w.id]: e.target.value }))} data-testid="permit-wait-car">
                  <option value="">Choose the car</option>{cars.map((c) => <option key={c.id} value={c.id}>{[c.name, c.plate, c.owner_name].filter(Boolean).join(', ')}</option>)}</select></div>
              <div className="field ad-field"><label className="label" htmlFor={`pb-why-${w.id}`}>Or set it aside: why</label>
                <input className="input" id={`pb-why-${w.id}`} value={why[w.id] ?? ''} onChange={(e) => setWhy((x) => ({ ...x, [w.id]: e.target.value }))} /></div>
            </div>
            <div className="row">
              <button className="btn btn--primary btn--sm" type="button" disabled={pending || !pick[w.id]} onClick={() => act(w.id, 'permit_assign')} aria-describedby={`why-pb-${w.id}`} data-testid="permit-wait-file">File it on this car</button>
              <WhyDisabled id={`why-pb-${w.id}`} why={!pick[w.id] ? 'Choose the car first' : null} />
              <button className="btn btn--ghost btn--sm" type="button" disabled={pending || !(why[w.id] ?? '').trim()} onClick={() => act(w.id, 'permit_discard')}>Set aside</button>
            </div>
            {err[w.id] && <p className="small ad-err" role="alert">{err[w.id]}</p>}
          </li>))}</ul>}
      </section>

      <section className="pt-card ad-card stack" aria-labelledby="pb-f">
        <div className="pt-card__head"><h2 className="d4" id="pb-f">Filed lately</h2></div>
        {filed.length === 0 ? <p className="small muted">The permits you file show here with their car.</p> : <ul className="pb-rows" data-testid="permit-filed">{filed.map((x) => (
          <li key={x.id} data-state="filed"><b className="pb-name">{x.vehicle_name}</b> <span className="small">{[x.file_name, x.matched_by ? HOW[x.matched_by] : null].filter(Boolean).join(', ')}{x.note ? `. ${x.note}` : ''}</span>
            {x.document_id && <> <a className="link small" href={`${base}/documents/${x.document_id}`} target="_blank" rel="noopener">Open</a></>}</li>))}</ul>}
      </section>
    </div>
  );
}
