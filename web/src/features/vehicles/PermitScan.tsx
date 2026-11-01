'use client';
import { useId, useRef, useState } from 'react';
import { toStandardImage } from '@/features/uploads/standard-image';
import { sourceProblem } from '@/features/uploads/formats';
import { permitScore, type PermitRead } from './permit-read';

// Read the ownership permit from a photo (migration 0290), on Add a car for an owner, the car's registration and the
// owner's own application. The photo is made a standard JPEG in the browser, read by the vision model, checked
// (permit-read.ts) and handed to the form, which fills its fields; the person reviews each one before saving. The
// panel lists what was read, with what to check first.
const LABEL: Array<[keyof PermitRead['checks'], string]> = [['plate', 'Plate'], ['vin', 'VIN'], ['year', 'Year'], ['make', 'Make'], ['model', 'Model code'],
  ['body', 'Body'], ['colour', 'Colour'], ['permit_number', 'Permit number'], ['sticker_expires_on', 'Plate sticker expires']];
const asDataUrl = (b: Blob) => new Promise<string>((ok, no) => { const r = new FileReader(); r.onload = () => ok(String(r.result)); r.onerror = () => no(r.error); r.readAsDataURL(b); });
const fmtDate = (iso: string) => new Date(`${iso}T12:00:00Z`).toLocaleDateString('en-CA', { year: 'numeric', month: 'short', day: 'numeric', timeZone: 'UTC' });

function shown(r: PermitRead, k: keyof PermitRead['checks']): string | null {
  switch (k) {
    case 'colour': return r.colour ? `${r.colour}${r.colour_printed && r.colour_printed.toLowerCase() !== r.colour.toLowerCase() ? ` (${r.colour_printed})` : ''}` : r.colour_printed;
    case 'body': return r.body ? `${r.body}${r.body_words ? `, ${r.body_words}` : ''}` : null;
    case 'sticker_expires_on': return r.sticker_expires_on ? fmtDate(r.sticker_expires_on) : null;
    case 'year': return r.year ? String(r.year) : null;
    default: return (r[k] as string | null) ?? null;
  }
}

export function PermitScan({ onRead, prefix = 'permit', note }: {
  /** the checked details and the photo (a standard JPEG), for the form to fill and attach */
  onRead: (r: PermitRead, photo: File) => void; prefix?: string; note?: string;
}) {
  const uid = useId().replace(/[^\w-]/g, '');
  const cam = useRef<HTMLInputElement>(null);
  const pick = useRef<HTMLInputElement>(null);
  const [busy, setBusy] = useState(false);
  const [err, setErr] = useState<string | null>(null);
  const [read, setRead] = useState<PermitRead | null>(null);
  const [preview, setPreview] = useState<string | null>(null);

  const go = async (file: File | undefined) => {
    if (!file) return;
    setErr(null);
    const bad = sourceProblem(file);
    if (bad) { setErr(bad); return; }
    setBusy(true);
    try {
      const jpeg = await toStandardImage(file);
      const image = await asDataUrl(jpeg);
      setPreview(image);
      const res = await fetch('/api/permit/read', { method: 'POST', headers: { 'content-type': 'application/json' }, body: JSON.stringify({ image }) });
      const j = (await res.json().catch(() => null)) as { ok: boolean; message?: string; read?: PermitRead } | null;
      if (!j?.ok || !j.read) { setErr(j?.message ?? 'The permit could not be read. Type the details from the permit.'); return; }
      setRead(j.read);
      onRead(j.read, new File([jpeg], 'ownership-permit.jpg', { type: 'image/jpeg' }));
    } catch (e) {
      setErr(e instanceof Error && e.message && !/fetch/i.test(e.message) ? e.message : 'No connection. Try again, or type the details from the permit.');
    } finally {
      setBusy(false);
      if (cam.current) cam.current.value = '';
      if (pick.current) pick.current.value = '';
    }
  };

  const score = read ? permitScore(read) : null;
  return (
    <div className={`pscan${read ? ' is-read' : ''}${busy ? ' is-busy' : ''}`} data-testid={`${prefix}-scan`} aria-busy={busy || undefined}>
      <div className="pscan__head">
        <span className="pscan__icon" aria-hidden="true">
          <svg viewBox="0 0 24 24" width="22" height="22" fill="none" stroke="currentColor" strokeWidth="1.6" strokeLinecap="round" strokeLinejoin="round"><rect x="3" y="5" width="18" height="14" rx="2" /><path d="M7 9h6M7 12h10M7 15h4" /><circle cx="17" cy="9.5" r="1.5" /></svg>
        </span>
        <div className="pscan__text">
          <p className="pscan__title" id={`${uid}-t`}>{read ? 'Read from the permit' : 'Fill this from the ownership permit'}</p>
          <p className="pscan__sub">{busy ? 'Reading the permit. This takes a few seconds.'
            : read ? `${score!.ok} of ${score!.of} details read and checked. Check each one against the permit before saving.`
            : note ?? 'Take a photo of the vehicle portion of the Ontario permit, flat and in good light. The plate, VIN, year, make, model, colour, body, permit number and sticker expiry fill in for you to check.'}</p>
        </div>
      </div>
      <div className="pscan__actions">
        <button type="button" className="btn btn--primary btn--sm" disabled={busy} onClick={() => cam.current?.click()} data-testid={`${prefix}-scan-camera`}>{busy ? 'Reading' : read ? 'Take another photo' : 'Take a photo'}</button>
        <button type="button" className="btn btn--ghost btn--sm" disabled={busy} onClick={() => pick.current?.click()} data-testid={`${prefix}-scan-choose`}>Choose a photo</button>
        <input ref={cam} className="vh" type="file" accept="image/*" capture="environment" tabIndex={-1} aria-hidden="true" onChange={(e) => void go(e.target.files?.[0])} />
        <input ref={pick} className="vh" type="file" accept="image/*,.heic,.heif" tabIndex={-1} aria-labelledby={`${uid}-t`} onChange={(e) => void go(e.target.files?.[0])} data-testid={`${prefix}-scan-file`} />
      </div>
      {busy && <div className="pscan__bar" aria-hidden="true"><span /></div>}
      {err && <p className="pscan__err" role="alert" data-testid={`${prefix}-scan-error`}>{err}</p>}
      {read && (
        <div className="pscan__result" data-testid={`${prefix}-scan-result`}>
          {/* a data: address of the photo just taken, shown small: not a page image to optimize */}
          {/* eslint-disable-next-line @next/next/no-img-element */}
          {preview && <img className="pscan__photo" src={preview} alt="The permit photo read" />}
          <dl className="pscan__list">
            {LABEL.map(([k, l]) => {
              const v = shown(read, k);
              const st = read.checks[k];
              return (
                <div key={k} className={`pscan__row is-${st}`} data-testid={`${prefix}-scan-${k}`}>
                  <dt>{l}</dt>
                  <dd><span className="pscan__val">{v ?? 'Not read'}</span><span className="pscan__state">{st === 'ok' ? 'Checked' : st === 'check' ? 'Check this' : 'Type it'}</span></dd>
                </div>);
            })}
          </dl>
          {read.problems.length > 0 && <ul className="pscan__problems" data-testid={`${prefix}-scan-problems`}>{read.problems.map((p) => <li key={p}>{p}</li>)}</ul>}
        </div>
      )}
    </div>
  );
}
