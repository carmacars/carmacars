'use client';
import { useEffect, useId, useRef, useState } from 'react';
import { toStandardImage } from '@/features/uploads/standard-image';
import { sourceProblem } from '@/features/uploads/formats';
import { backCamera, barcodeReader } from './barcode';
import { bestVin, readMessage, type VinRead } from './vin-read';

// VIN by photo or camera (release 28), one reader for every VIN field: Add a car (Admin, staff, for an owner), the
// owner's application, the earnings calculator, the car page's VIN, and Start a listing. Two ways in:
//   Scan the barcode  the back camera, live; the barcode on the driver's door jamb or under the windshield is read in
//                     the browser (barcode.ts: BarcodeDetector, or zxing-wasm), nothing is sent anywhere
//   Photo of the VIN  a photo taken or chosen: its barcode first (in the browser), else the vision model reads the
//                     printed VIN (/api/vin/read, within the day's free AI allowance)
// Either way the VIN is checked (vin-read.ts: I, O and Q corrected, one look-alike when the check digit says so) and
// handed to the field, which decodes the year, make and model as when it is typed. The person checks it before saving.
const asDataUrl = (b: Blob) => new Promise<string>((ok, no) => { const r = new FileReader(); r.onload = () => ok(String(r.result)); r.onerror = () => no(r.error); r.readAsDataURL(b); });

export function VinScan({ onVin, prefix = 'vin', compact = false }: {
  /** the VIN read and the sentence to show under the field */
  onVin: (vin: string, note: string) => void; prefix?: string; compact?: boolean;
}) {
  const uid = useId().replace(/[^\w-]/g, '');
  const dlg = useRef<HTMLDialogElement>(null);
  const video = useRef<HTMLVideoElement>(null);
  const stream = useRef<MediaStream | null>(null);
  const timer = useRef<number | null>(null);
  const photoIn = useRef<HTMLInputElement>(null);
  const [scanning, setScanning] = useState(false);
  const [busy, setBusy] = useState(false);
  const [msg, setMsg] = useState<{ ok: boolean; text: string } | null>(null);
  const [camErr, setCamErr] = useState<string | null>(null);

  const stop = () => {
    if (timer.current) { window.clearTimeout(timer.current); timer.current = null; }
    stream.current?.getTracks().forEach((t) => t.stop());
    stream.current = null;
    setScanning(false);
  };
  useEffect(() => stop, []);

  const done = (r: VinRead, how: 'barcode' | 'photo') => {
    const note = readMessage(r, how);
    setMsg({ ok: r.checkOk, text: `${r.vin}: ${note}` });
    onVin(r.vin, note);
  };

  const startScan = async () => {
    setMsg(null); setCamErr(null);
    dlg.current?.showModal();
    setScanning(true);
    try {
      const [reader, s] = await Promise.all([barcodeReader(), backCamera()]);
      stream.current = s;
      const v = video.current;
      if (!v) { stop(); return; }
      v.srcObject = s;
      await v.play().catch(() => undefined);
      const tick = async () => {
        if (!stream.current) return;
        try {
          if (v.readyState >= 2) {
            const texts = await reader.read(v);
            for (const t of texts) {
              const r = bestVin(t);
              if (r) { stop(); dlg.current?.close(); done(r, 'barcode'); return; }
            }
          }
        } catch { /* a frame the reader refused: the next one */ }
        timer.current = window.setTimeout(() => void tick(), 250);
      };
      void tick();
    } catch (e) {
      stop();
      const name = e instanceof Error ? e.name : '';
      setCamErr(name === 'NotAllowedError' ? 'The camera was not allowed. Allow it in the browser, or take a photo instead.'
        : name === 'NotFoundError' ? 'No camera was found on this device. Take or choose a photo instead.'
        : e instanceof Error && e.message ? e.message : 'The camera did not open. Take a photo instead.');
    }
  };

  const closeScan = () => { stop(); dlg.current?.close(); };

  const fromPhoto = async (file: File | undefined) => {
    if (!file) return;
    if (dlg.current?.open) closeScan();
    setMsg(null);
    const bad = sourceProblem(file);
    if (bad) { setMsg({ ok: false, text: bad }); return; }
    setBusy(true);
    try {
      // the barcode in the photo first: free, in the browser
      try {
        const reader = await barcodeReader();
        const bmp = await createImageBitmap(file);
        const texts = await reader.read(bmp);
        bmp.close();
        for (const t of texts) { const r = bestVin(t); if (r) { done(r, 'barcode'); return; } }
      } catch { /* no barcode reader or no barcode: the vision model */ }
      const image = await asDataUrl(await toStandardImage(file));
      const res = await fetch('/api/vin/read', { method: 'POST', headers: { 'content-type': 'application/json' }, body: JSON.stringify({ image }) });
      const j = (await res.json().catch(() => null)) as { ok: boolean; message?: string; vins?: VinRead[] } | null;
      const r = j?.ok ? j.vins?.[0] : null;
      if (!r) { setMsg({ ok: false, text: j?.message ?? 'No VIN could be read from this photo. Try a sharper photo, closer and in good light, or type it.' }); return; }
      done(r, 'photo');
    } catch {
      setMsg({ ok: false, text: 'The photo could not be read just now. Try again, or type the VIN.' });
    } finally {
      setBusy(false);
      if (photoIn.current) photoIn.current.value = '';
    }
  };

  return (
    <div className={`vscan${compact ? ' vscan--compact' : ''}`} data-testid={`${prefix}-scan`}>
      <div className="vscan__actions">
        <button type="button" className="btn btn--ghost btn--sm vscan__btn" onClick={() => void startScan()} disabled={busy} data-testid={`${prefix}-scan-camera`}>
          <svg viewBox="0 0 24 24" width="18" height="18" aria-hidden="true" fill="none" stroke="currentColor" strokeWidth="1.8" strokeLinecap="round"><path d="M3 7V5a2 2 0 0 1 2-2h2M17 3h2a2 2 0 0 1 2 2v2M21 17v2a2 2 0 0 1-2 2h-2M7 21H5a2 2 0 0 1-2-2v-2M7 8v8M10 8v8M13 8v8M16 8v8" /></svg>
          Scan the barcode
        </button>
        <button type="button" className="btn btn--ghost btn--sm vscan__btn" onClick={() => photoIn.current?.click()} disabled={busy} data-testid={`${prefix}-scan-photo`}>
          <svg viewBox="0 0 24 24" width="18" height="18" aria-hidden="true" fill="none" stroke="currentColor" strokeWidth="1.8" strokeLinecap="round" strokeLinejoin="round"><path d="M4 8h3l2-3h6l2 3h3v11H4z" /><circle cx="12" cy="13" r="3.5" /></svg>
          {busy ? 'Reading the photo' : 'Photo of the VIN'}
        </button>
        <input ref={photoIn} className="vh" type="file" accept="image/*,.heic,.heif" tabIndex={-1} aria-label="Photo of the VIN" onChange={(e) => void fromPhoto(e.target.files?.[0])} data-testid={`${prefix}-scan-file`} />
      </div>
      {msg && <p className={`small vscan__msg${msg.ok ? '' : ' vscan__msg--warn'}`} role="status" data-testid={`${prefix}-scan-msg`}>{msg.text}</p>}
      <dialog ref={dlg} className="vscan__dlg" aria-labelledby={`${uid}-t`} onCancel={(e) => { e.preventDefault(); closeScan(); }}>
        <div className="vscan__dlg-in">
          <p className="vscan__title" id={`${uid}-t`}>Scan the VIN barcode</p>
          <div className="vscan__view">
            <video ref={video} muted playsInline aria-label="Camera view" />
            <span className="vscan__frame" aria-hidden="true" />
          </div>
          <p className="small" role="status">{camErr ?? (scanning ? 'Point the camera at the barcode in the driver\'s door frame or at the bottom of the windshield. It reads by itself.' : '')}</p>
          <div className="row">
            <button type="button" className="btn btn--primary btn--sm" onClick={() => photoIn.current?.click()}>Take or choose a photo instead</button>
            <button type="button" className="btn btn--quiet btn--sm" onClick={closeScan} data-testid={`${prefix}-scan-close`}>Close</button>
          </div>
        </div>
      </dialog>
    </div>
  );
}
