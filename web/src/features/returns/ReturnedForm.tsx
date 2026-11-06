'use client';
import { useState } from 'react';
import { DateInput } from '@/components/DateInput';
import { FUEL_LEVELS, MAX_PHOTOS, claimPayload } from './claim';
import { PhotoPicker } from '@/features/handover/PhotoPicker';
import type { PickedPhoto } from '@/features/handover/angles';

// The renter's "I've returned the car" form (migration 0532): one button does it; photos (several at once from the camera
// roll), the odometer, the fuel level and the actual time are optional. Each photo is made a smaller JPEG in the browser and
// uploaded on its own, then the report lists them.

function localNow(): string {
  const d = new Date(Date.now() - new Date().getTimezoneOffset() * 60_000);
  return d.toISOString().slice(0, 16);
}

export function ReturnedForm({ token }: { token: string }) {
  const [photos, setPhotos] = useState<PickedPhoto[]>([]);
  const [uploading, setUploading] = useState(0);
  const [at, setAt] = useState(localNow());
  const [km, setKm] = useState('');
  const [fuel, setFuel] = useState('');
  const [note, setNote] = useState('');
  const [busy, setBusy] = useState(false);
  const [err, setErr] = useState<string | null>(null);
  const [done, setDone] = useState(false);

  // the same picker as a check-out (0545): many at once, the suggested angles, smaller JPEGs made on the phone
  const upload = async (blob: Blob) => {
    const fd = new FormData();
    fd.append('file', blob, 'photo.jpg');
    const r = await fetch(`/api/returned/${token}/photo`, { method: 'POST', body: fd });
    const j = (await r.json().catch(() => ({}))) as { ok?: boolean; bucket?: string; path?: string; message?: string };
    if (!j.ok || !j.path) throw new Error(j.message ?? 'The photo could not be uploaded.');
    return { bucket: j.bucket ?? 'condition-photos', path: j.path };
  };

  async function send() {
    setErr(null);
    const v = claimPayload({ returned_at: at ? new Date(at).toISOString() : undefined, odometer_km: km, fuel_pct: fuel, note, photos: photos.map(({ bucket, path, angle }) => ({ bucket, path, angle })) });
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
      <p>Any late notices have stopped. If you gave the photos, the odometer and the fuel, your trip is completed; otherwise we check the car and confirm the return. If anything is unclear we contact you.</p>
    </div>
  );

  return (
    <form className="stack" data-testid="returned-form" onSubmit={(e) => { e.preventDefault(); void send(); }}>
      <PhotoPicker scope="return-claim" id={token} upload={upload} photos={photos} onChange={setPhotos} onBusy={setUploading} max={MAX_PHOTOS} label="Photos of the car where you left it (all sides, odometer, fuel, keys)" testId="returned-photos" />
      <p className="small muted">With the photos, the odometer and the fuel level, your return is completed at once. Without them, we check and confirm.</p>
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
