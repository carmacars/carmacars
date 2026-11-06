'use client';
import { useState } from 'react';
import { toStandardImage } from '@/features/uploads/standard-image';
import { ANGLES, anglesDone, type PickedPhoto, type PhotoScope } from './angles';

// Many photos at once, from the camera roll or the camera (migration 0545): each is made a smaller JPEG on the device
// first (storage limits), uploaded on its own, and can be tagged with an angle. The suggested angles are a checklist
// beside them, ticked as photos are tagged or by hand: guidance, never one upload per angle.
export function PhotoPicker({ scope, id, upload, photos, onChange, max = 40, label = 'Photos of the car', testId = 'photo-picker' }: {
  scope: PhotoScope; id: string; photos: PickedPhoto[]; onChange: (p: PickedPhoto[]) => void; max?: number; label?: string; testId?: string;
  /** where the photo goes; defaults to the shared upload route */
  upload?: (blob: Blob) => Promise<{ bucket: string; path: string }>;
}) {
  const [busy, setBusy] = useState(0);
  const [err, setErr] = useState<string | null>(null);
  const [ticked, setTicked] = useState<Set<string>>(new Set());
  const done = anglesDone(photos, ticked);
  const send = upload ?? (async (blob: Blob) => {
    const fd = new FormData();
    fd.append('file', blob, 'photo.jpg'); fd.append('scope', scope); fd.append('id', id);
    const r = await fetch('/api/handover-photo', { method: 'POST', body: fd });
    const j = (await r.json().catch(() => ({}))) as { ok?: boolean; bucket?: string; path?: string; message?: string };
    if (!j.ok || !j.path) throw new Error(j.message ?? 'The photo could not be uploaded.');
    return { bucket: j.bucket ?? 'condition-photos', path: j.path };
  });
  async function add(files: FileList | null) {
    if (!files?.length) return;
    setErr(null);
    const list = Array.from(files).slice(0, Math.max(0, max - photos.length));
    setBusy((n) => n + list.length);
    const got: PickedPhoto[] = [];
    await Promise.all(list.map(async (f) => {
      try { const at = await send(await toStandardImage(f)); got.push({ ...at, angle: null, name: f.name }); }
      catch (e) { setErr(e instanceof Error ? e.message : 'A photo could not be uploaded.'); }
      finally { setBusy((n) => n - 1); }
    }));
    onChange([...photos, ...got]);
  }
  return (
    <div className="stack" data-testid={testId}>
      <div className="field">
        <label className="label" htmlFor={`${testId}-in`}>{label}</label>
        <input className="input" id={`${testId}-in`} type="file" accept="image/*" multiple onChange={(e) => { void add(e.target.files); e.target.value = ''; }} data-testid={`${testId}-input`} />
        <p className="small muted">Pick many at once from the camera roll, or take them now. {photos.length ? `${photos.length} added.` : ''}{busy ? ` Uploading ${busy}.` : ''}</p>
      </div>
      {photos.length > 0 && <ul className="ho-photos" data-testid={`${testId}-list`}>{photos.map((p, i) => (
        <li key={p.path}><span className="small">{p.name || `Photo ${i + 1}`}</span>
          <select className="select" aria-label={`Angle of ${p.name || `photo ${i + 1}`}`} value={p.angle ?? ''} onChange={(e) => onChange(photos.map((x) => (x.path === p.path ? { ...x, angle: e.target.value || null } : x)))}>
            <option value="">Angle (optional)</option>{ANGLES.map(([k, l]) => <option key={k} value={k}>{l}</option>)}</select>
          <button className="btn btn--quiet btn--sm" type="button" onClick={() => onChange(photos.filter((x) => x.path !== p.path))}>Remove</button></li>))}</ul>}
      <fieldset className="ho-angles"><legend className="small"><b>Suggested angles</b> ({done.size} of {ANGLES.length})</legend>
        {ANGLES.map(([k, l]) => <label key={k} className="check small"><input type="checkbox" checked={done.has(k)} onChange={(e) => setTicked((s) => { const n = new Set(s); if (e.target.checked) n.add(k); else n.delete(k); return n; })} /> <span>{l}</span></label>)}
      </fieldset>
      {err && <p className="alert alert--error" role="alert"><span>{err}</span></p>}
    </div>
  );
}
