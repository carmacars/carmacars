'use client';
import { useState, useTransition } from 'react';
import { useRouter } from 'next/navigation';
import { listingCapture, listingSubmit } from '@/server/actions/listing';

// The capture step (09-listing-pipeline.md section 4): the shot list in order, a photo for each (from the
// camera on a phone, or a file on a computer), a retake replaces the shot, then "Submit for listing".
// Each photo is resized in the browser to 3000 px on the long side and re-encoded as JPEG before upload.
export interface Capture {
  intake_id: string; vehicle_id: string; vehicle_name: string; state: string; submitted: boolean; reason: string | null; may_upload: boolean;
  missing: string[];
  shots: Array<{ code: string; label: string; seq: number; required: boolean; max_count: number; guide: string | null; rebackground: boolean;
    photos: Array<{ id: string; status: string; background_status: string }> }>;
}

async function prepare(file: File): Promise<{ blob: Blob; width: number; height: number }> {
  try {
    const bmp = await createImageBitmap(file, { imageOrientation: 'from-image' });
    const scale = Math.min(1, 3000 / Math.max(bmp.width, bmp.height));
    const w = Math.round(bmp.width * scale), h = Math.round(bmp.height * scale);
    const c = document.createElement('canvas');
    c.width = w; c.height = h;
    c.getContext('2d')!.drawImage(bmp, 0, 0, w, h);
    const blob = await new Promise<Blob | null>((ok) => c.toBlob(ok, 'image/jpeg', 0.9));
    if (blob) return { blob, width: w, height: h };
  } catch { /* a format the browser cannot draw: send it as it is, the server checks it */ }
  return { blob: file, width: 0, height: 0 };
}

export function ListingCapture({ initial, refresh = [] }: { initial: Capture; refresh?: string[] }) {
  const [c, setC] = useState(initial);
  const [busy, setBusy] = useState<string | null>(null);
  const [msg, setMsg] = useState<{ ok: boolean; text: string } | null>(null);
  const [failed, setFailed] = useState<Record<string, File>>({});
  const [similar, setSimilar] = useState(0);
  const [pending, start] = useTransition();
  const router = useRouter();
  const reload = async () => { const r = await listingCapture<Capture>(c.intake_id); if (r.ok) setC(r.data); };
  // one photo: resized in the browser, sent, recorded; a failed upload (a weak signal in a car park) can be sent again
  const upload = async (shot: string, file: File | undefined) => {
    if (!file) return;
    setBusy(shot); setMsg(null);
    try {
      const { blob, width, height } = await prepare(file);
      const fd = new FormData();
      fd.set('intake', c.intake_id); fd.set('shot', shot); fd.set('file', blob, `${shot}.jpg`);
      if (width) { fd.set('width', String(width)); fd.set('height', String(height)); }
      const r = await fetch('/api/listing/upload', { method: 'POST', body: fd }).catch(() => null);
      const j = (r ? await r.json().catch(() => ({ ok: false, message: 'The upload failed.' })) : { ok: false, message: 'No connection. Check your signal and send it again.' }) as { ok: boolean; message?: string; similar?: number };
      if (!j.ok) { setMsg({ ok: false, text: j.message ?? 'The upload failed.' }); setFailed((f) => ({ ...f, [shot]: file })); }
      else { setFailed((f) => { const n = { ...f }; delete n[shot]; return n; }); if (j.similar) setSimilar(j.similar); }
      await reload();
    } finally { setBusy(null); }
  };
  const submit = () => start(async () => {
    const r = await listingSubmit(c.intake_id, refresh);
    setMsg(r.ok ? { ok: true, text: 'Submitted. The details and photos are being prepared; this takes a few minutes.' } : { ok: false, text: r.message });
    await reload();
    router.refresh();
  });
  const required = c.shots.filter((s) => s.required);
  const done = required.filter((s) => s.photos.length > 0).length;
  const pct = required.length ? Math.round((100 * done) / required.length) : 100;
  return (
    <section className="pt-card ad-card lc" aria-labelledby="lc-h" data-testid="listing-capture">
      <h2 className="d4" id="lc-h">Photos</h2>
      <p className="small muted">{c.submitted ? 'Submitted. A retake replaces the photo and is processed again.' : `Daylight, landscape, the whole car in frame, no people, no other plates readable. ${done} of ${required.length} required photos added.`}</p>
      <div className="lc__progress" role="progressbar" aria-valuemin={0} aria-valuemax={required.length} aria-valuenow={done} aria-label="Required photos added" data-testid="capture-progress">
        <span style={{ width: `${pct}%` }} />
      </div>
      {similar > 0 && <p className="alert alert--warn small" role="status" data-testid="capture-similar"><span>This car looks like another car on file. Staff check it before it is published; keep going.</span></p>}
      <ol className="lc__grid">
        {c.shots.map((s) => {
          const has = s.photos.length > 0;
          const last = s.photos[s.photos.length - 1];
          return (
            <li key={s.code} className={`lc__shot${has ? ' is-done' : ''}`} data-shot={s.code}>
              <span className="lc__label"><b>{s.label}</b>{!s.required && <span className="muted"> (optional)</span>}</span>
              {s.guide && <span className="small muted">{s.guide}</span>}
              <span className="small">{busy === s.code ? 'Uploading' : has ? `Added${last?.status === 'processed' ? ', processed' : last?.background_status === 'original_used' ? ', kept as taken' : ''}` : 'Missing'}</span>
              {c.may_upload && <span className="row lc__picks">
                <label className="btn btn--ghost btn--sm lc__pick">
                  <span>{has && s.max_count === 1 ? 'Retake' : 'Take photo'}<span className="vh"> for {s.label}</span></span>
                  <input className="vh" type="file" accept="image/jpeg,image/png" capture="environment" disabled={!!busy} data-testid={`shot-${s.code}`}
                    onChange={(e) => { void upload(s.code, e.target.files?.[0]); e.target.value = ''; }} />
                </label>
                <label className="btn btn--quiet btn--sm lc__pick">
                  <span>From photos<span className="vh"> for {s.label}</span></span>
                  <input className="vh" type="file" accept="image/jpeg,image/png" disabled={!!busy} data-testid={`shot-pick-${s.code}`}
                    onChange={(e) => { void upload(s.code, e.target.files?.[0]); e.target.value = ''; }} />
                </label>
                {failed[s.code] && <button className="btn btn--primary btn--sm" type="button" disabled={!!busy} onClick={() => void upload(s.code, failed[s.code])} data-testid={`shot-retry-${s.code}`}>Send again</button>}
              </span>}
            </li>
          );
        })}
      </ol>
      {!c.submitted && c.may_upload && <p>
        <button className="btn btn--primary" type="button" disabled={pending || c.missing.length > 0 || !!busy} onClick={submit} data-testid="listing-submit">{pending ? 'Submitting' : 'Submit for listing'}</button>
        {c.missing.length > 0 && <span className="small muted"> Still needed: {c.missing.join(', ')}.</span>}
      </p>}
      {msg && <p className={`alert ${msg.ok ? 'alert--ok' : 'alert--error'}`} role={msg.ok ? 'status' : 'alert'}><span>{msg.text}</span></p>}
    </section>
  );
}
