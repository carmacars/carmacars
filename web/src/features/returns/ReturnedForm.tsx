'use client';
import { useState } from 'react';
import { DateInput } from '@/components/DateInput';
import { toStandardImage } from '@/features/uploads/standard-image';
import { FUEL_LEVELS, MAX_PHOTOS, claimPayload } from './claim';

// The renter's "I've returned the car" form (migration 0532): one button does it; photos (several at once from the camera
// roll), the odometer, the fuel level and the actual time are optional. Each photo is made a smaller JPEG in the browser and
// uploaded on its own, then the report lists them.
type Photo = { bucket: string; path: string; name: string };

function localNow(): string {
  const d = new Date(Date.now() - new Date().getTimezoneOffset() * 60_000);
  return d.toISOString().slice(0, 16);
}

export function ReturnedForm({ token }: { token: string }) {
  const [photos, setPhotos] = useState<Photo[]>([]);
  const [uploading, setUploading] = useState(0);
  const [at, setAt] = useState(localNow());
  const [km, setKm] = useState('');
  const [fuel, setFuel] = useState('');
  const [note, setNote] = useState('');
  const [busy, setBusy] = useState(false);
  const [err, setErr] = useState<string | null>(null);
  const [done, setDone] = useState(false);

  async function addPhotos(files: FileList | null) {
    if (!files?.length) return;
    setErr(null);
    const list = Array.from(files).slice(0, Math.max(0, MAX_PHOTOS - photos.length));
    setUploading((n) => n + list.length);
    await Promise.all(list.map(async (f) => {
      try {
        const blob = await toStandardImage(f);
        const fd = new FormData();
        fd.append('file', blob, 'photo.jpg');
        const r = await fetch(`/api/returned/${token}/photo`, { method: 'POST', body: fd });
        const j = (await r.json().catch(() => ({}))) as { ok?: boolean; bucket?: string; path?: string; message?: string };
        if (!j.ok || !j.path) throw new Error(j.message ?? 'The photo could not be uploaded.');
        setPhotos((p) => [...p, { bucket: j.bucket ?? 'condition-photos', path: j.path!, name: f.name }]);
      } catch (e) {
        setErr(e instanceof Error ? e.message : 'A photo could not be uploaded.');
      } finally {
        setUploading((n) => n - 1);
      }
    }));
  }

  async function send() {
    setErr(null);
    const v = claimPayload({ returned_at: at ? new Date(at).toISOString() : undefined, odometer_km: km, fuel_pct: fuel, note, photos: photos.map(({ bucket, path }) => ({ bucket, path })) });
    if (!v.ok) { setErr(v.message); return; }
    setBusy(true);
    try {
      const r = await fetch(`/api/returned/${token}`, { method: 'POST', headers: { 'content-type': 'application/json' }, body: JSON.stringify(v.payload) });
      const j = (await r.json().catch(() => ({}))) as { ok?: boolean; message?: string };
      if (!j.ok) throw new Error(j.message ?? 'The report could not be sent. Call us instead.');
      setDone(true);
    } catch (e) {
      setErr(e instanceof Error ? e.message : 'The report could not be sent. Call us instead.');
    } finally {
      setBusy(false);
    }
  }

  if (done) return (
    <div className="pt-ok" role="status" data-testid="returned-done">
      <h2 className="d4">Thank you, we have it</h2>
      <p>The late notices have stopped. We check the car and confirm the return; if anything is unclear we contact you.</p>
    </div>
  );

  return (
    <form className="stack" data-testid="returned-form" onSubmit={(e) => { e.preventDefault(); void send(); }}>
      <div className="field">
        <label className="label" htmlFor="ret-photos">Photos of the car where you left it (optional)</label>
        <input className="input" id="ret-photos" type="file" accept="image/*" multiple onChange={(e) => { void addPhotos(e.target.files); e.target.value = ''; }} data-testid="returned-photos" />
        <p className="small muted">Pick several at once from your camera roll: all sides, the odometer and fuel gauge, the keys.{photos.length ? ` ${photos.length} added.` : ''}{uploading ? ` Uploading ${uploading}.` : ''}</p>
      </div>
      <div className="field">
        <label className="label" htmlFor="ret-at">When you returned it</label>
        <DateInput className="input" id="ret-at" type="datetime-local" value={at} max={localNow()} onChange={(e) => setAt(e.target.value)} />
      </div>
      <div className="field-row">
        <div className="field">
          <label className="label" htmlFor="ret-km">Odometer (km, optional)</label>
          <input className="input" id="ret-km" inputMode="numeric" value={km} onChange={(e) => setKm(e.target.value)} placeholder="e.g. 48210" />
        </div>
        <div className="field">
          <label className="label" htmlFor="ret-fuel">Fuel level (optional)</label>
          <select className="input" id="ret-fuel" value={fuel} onChange={(e) => setFuel(e.target.value)}>
            <option value="">Not sure</option>
            {FUEL_LEVELS.map(([l, p]) => <option key={l} value={String(p)}>{l}</option>)}
          </select>
        </div>
      </div>
      <div className="field">
        <label className="label" htmlFor="ret-note">Where are the car and keys? (optional)</label>
        <textarea className="textarea" id="ret-note" maxLength={1000} value={note} onChange={(e) => setNote(e.target.value)} />
      </div>
      {err && <p className="alert alert--error" role="alert"><span>{err}</span></p>}
      <button className="btn btn--primary" type="submit" disabled={busy || uploading > 0} data-testid="returned-submit">{busy ? 'Sending' : uploading ? 'Uploading photos' : "I've returned the car"}</button>
    </form>
  );
}
