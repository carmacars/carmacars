'use client';
import { useState } from 'react';
import { toStandardImage } from '@/features/uploads/standard-image';
import type { PhotoScope } from './angles';
import { FUEL_EIGHTHS, confirmQuestion, selfieLive, type ReadingState } from './reading';

// The odometer and fuel of a check-out or check-in (release 35, migration 0910). Two required photos beside the others:
//   1. the dashboard, from the camera roll or the camera: read by the vision model, then "Odometer 45,210 km, fuel 3/4:
//      correct?"; when it cannot be read, or the answer is no, the odometer is typed and the fuel picked in eighths;
//   2. a selfie in front of the car, taken live with the device's front camera (no gallery): its capture time, and the
//      place when the device gives it, go with the reading; one without a fresh capture time is noted for staff only.
type Up = (blob: Blob) => Promise<{ bucket: string; path: string }>;

function defaultUpload(scope: PhotoScope, id: string): Up {
  return async (blob) => {
    const fd = new FormData();
    fd.append('file', blob, 'photo.jpg'); fd.append('scope', scope); fd.append('id', id);
    const r = await fetch('/api/handover-photo', { method: 'POST', body: fd });
    const j = (await r.json().catch(() => ({}))) as { ok?: boolean; bucket?: string; path?: string; message?: string };
    if (!j.ok || !j.path) throw new Error(j.message ?? 'The photo could not be uploaded.');
    return { bucket: j.bucket ?? 'condition-photos', path: j.path };
  };
}

const dataUrl = (b: Blob) => new Promise<string>((ok, no) => { const r = new FileReader(); r.onload = () => ok(String(r.result)); r.onerror = () => no(r.error); r.readAsDataURL(b); });
const where = () => new Promise<{ latitude: number; longitude: number } | null>((ok) => {
  if (typeof navigator === 'undefined' || !navigator.geolocation) { ok(null); return; }
  navigator.geolocation.getCurrentPosition((p) => ok({ latitude: Number(p.coords.latitude.toFixed(6)), longitude: Number(p.coords.longitude.toFixed(6)) }), () => ok(null), { timeout: 5000, maximumAge: 60_000 });
});

export function DashReading({ scope, id, read, value, onChange, onBusy, upload, testId = 'reading' }: {
  scope: PhotoScope; id: string; value: ReadingState; onChange: (s: ReadingState) => void;
  /** who asks the reader: the booking (signed in) or the return link's token */
  read: { booking: string } | { token: string };
  onBusy?: (busy: boolean) => void; upload?: Up; testId?: string;
}) {
  const send = upload ?? defaultUpload(scope, id);
  const [state, setState] = useState<'idle' | 'reading' | 'read' | 'unread'>(value.ai ? 'read' : value.dash ? 'unread' : 'idle');
  const [err, setErr] = useState<string | null>(null);
  const [selfieBusy, setSelfieBusy] = useState(false);
  const set = (patch: Partial<ReadingState>) => onChange({ ...value, ...patch });

  async function pickDash(f: File | undefined) {
    if (!f) return;
    setErr(null); setState('reading'); onBusy?.(true);
    try {
      const blob = await toStandardImage(f);
      const [at, image] = await Promise.all([send(blob), dataUrl(blob)]);
      const r = await fetch('/api/handover/dash-read', { method: 'POST', headers: { 'content-type': 'application/json' }, body: JSON.stringify({ ...read, image }) })
        .then((x) => x.json()).catch(() => ({ ok: false })) as { ok: boolean; odometer_km?: number; fuel_eighths?: number; model?: string | null };
      const ai = r.ok && typeof r.odometer_km === 'number' && typeof r.fuel_eighths === 'number' ? { odometer_km: r.odometer_km, fuel_eighths: r.fuel_eighths, model: r.model ?? null } : null;
      onChange({ ...value, dash: at, ai, confirmed: false });
      setState(ai ? 'read' : 'unread');
    } catch (e) {
      setErr(e instanceof Error ? e.message : 'The photo could not be uploaded.'); setState('idle');
    } finally { onBusy?.(false); }
  }

  async function pickSelfie(f: File | undefined) {
    if (!f) return;
    setErr(null); setSelfieBusy(true); onBusy?.(true);
    try {
      const live = selfieLive(f.lastModified);
      const [at, pos] = await Promise.all([toStandardImage(f).then(send), where()]);
      set({ selfie: { ...at, taken_at: new Date(f.lastModified || Date.now()).toISOString(), live, latitude: pos?.latitude ?? null, longitude: pos?.longitude ?? null } });
    } catch (e) {
      setErr(e instanceof Error ? e.message : 'The selfie could not be uploaded.');
    } finally { setSelfieBusy(false); onBusy?.(false); }
  }

  const typing = !!value.dash && !value.confirmed && state === 'unread';
  return (
    <fieldset className="stack ho-reading" data-testid={testId}>
      <legend className="label">Odometer and fuel (required)</legend>
      <div className="field">
        <label className="label" htmlFor={`${testId}-dash`}>1. Photo of the dashboard: odometer and fuel gauge</label>
        <input className="input" id={`${testId}-dash`} type="file" accept="image/*" onChange={(e) => { void pickDash(e.target.files?.[0]); e.target.value = ''; }} data-testid={`${testId}-dash`} />
        <p className="small muted">{state === 'reading' ? 'Reading the dashboard' : value.dash ? 'Dashboard photo added.' : 'From the camera roll or take it now.'}</p>
      </div>
      {state === 'read' && value.ai && !value.confirmed && (
        <div className="stack" role="group" aria-label="Check the reading" data-testid={`${testId}-ask`}>
          <p><b>{confirmQuestion(value.ai.odometer_km ?? 0, value.ai.fuel_eighths ?? 0)}</b></p>
          <div className="row" style={{ gap: 'var(--s-2)' }}>
            <button className="btn btn--primary btn--sm" type="button" onClick={() => set({ confirmed: true })} data-testid={`${testId}-yes`}>Yes, correct</button>
            <button className="btn btn--ghost btn--sm" type="button" onClick={() => { setState('unread'); set({ confirmed: false }); }} data-testid={`${testId}-no`}>No, I will type it</button>
          </div>
        </div>
      )}
      {value.confirmed && value.ai && <p className="small" data-testid={`${testId}-confirmed`}>Odometer {value.ai.odometer_km?.toLocaleString('en-CA')} km, fuel confirmed. <button className="link small" type="button" onClick={() => { setState('unread'); set({ confirmed: false }); }}>Change</button></p>}
      {typing && (
        <div className="field-row">
          <div className="field"><label className="label" htmlFor={`${testId}-km`}>Odometer (km)</label>
            <input className="input" id={`${testId}-km`} inputMode="numeric" required value={value.km} onChange={(e) => set({ km: e.target.value })} data-testid={`${testId}-km`} /></div>
          <div className="field"><label className="label" htmlFor={`${testId}-fuel`}>Fuel</label>
            <select className="input" id={`${testId}-fuel`} required value={value.fuel} onChange={(e) => set({ fuel: e.target.value })} data-testid={`${testId}-fuel`}>
              <option value="">Pick the level</option>{FUEL_EIGHTHS.map(([l, p]) => <option key={l} value={String(p)}>{l}</option>)}</select></div>
        </div>
      )}
      <div className="field">
        <label className="label" htmlFor={`${testId}-selfie`}>2. Selfie in front of the car (taken now with the camera)</label>
        <input className="input" id={`${testId}-selfie`} type="file" accept="image/*" capture="user" onChange={(e) => { void pickSelfie(e.target.files?.[0]); e.target.value = ''; }} data-testid={`${testId}-selfie`} />
        <p className="small muted">{selfieBusy ? 'Uploading the selfie' : value.selfie ? 'Selfie added.' : 'Stand in front of the car so it shows behind you.'}</p>
      </div>
      {err && <p className="alert alert--error" role="alert"><span>{err}</span></p>}
    </fieldset>
  );
}
