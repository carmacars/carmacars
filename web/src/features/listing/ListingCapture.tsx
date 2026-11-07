'use client';
import { useState, useTransition } from 'react';
import { useRouter } from 'next/navigation';
import { listingCapture, listingPhotoRemove, listingSubmit } from '@/server/actions/listing';
import { photoUrl } from '@/lib/photo';
import { PHOTO, shrinkImage } from '@/lib/image-shrink';

// The capture step (09-listing-pipeline.md section 4): the shot list in order, a photo for each (from the
// camera on a phone, or a file on a computer), a retake replaces the shot, then "Submit for listing".
// Each photo is resized in the browser to 2048 px on the long side and re-encoded as JPEG 80 before upload (lib/image-shrink).
// 0521: a photo filed under the wrong shot is taken off with Remove (kept privately), then the right one is taken.
export interface Capture {
  intake_id: string; vehicle_id: string; vehicle_name: string; state: string; submitted: boolean; reason: string | null; may_upload: boolean; may_remove?: boolean;
  missing: string[];
  /** 0700: the photos the database counts toward the minimum (public shots, not rejected, no mark on them), and the minimum */
  counted?: number; min_photos?: number;
  shots: Array<{ code: string; label: string; seq: number; required: boolean; max_count: number; guide: string | null; rebackground: boolean;
    photos: Array<{ id: string; status: string; background_status: string; original_path?: string | null; processed_path?: string | null }> }>;
}

async function prepare(file: File): Promise<{ blob: Blob; width: number; height: number }> {
  // a format the browser cannot draw is sent as it is (width 0): the server checks it
  const p = await shrinkImage(file, PHOTO);
  return { blob: p.blob, width: p.width, height: p.height };
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
  const [sure, setSure] = useState<string | null>(null);
  const remove = (photo: string) => start(async () => {
    const r = await listingPhotoRemove(photo, refresh);
    setSure(null);
    setMsg(r.ok ? { ok: true, text: 'Taken off. Take the right photo for that shot.' } : { ok: false, text: r.message });
    await reload();
    router.refresh();
  });
  const submit = () => start(async () => {
    const r = await listingSubmit(c.intake_id, refresh);
    setMsg(r.ok ? { ok: true, text: 'Submitted. The details and photos are being prepared; this takes a few minutes.' } : { ok: false, text: r.message });
    await reload();
    router.refresh();
  });
  // release 28 (0566): no shot is required; the listing needs 10 photos that can go on the site (not the odometer)
  // 0700: counted as the database counts (a photo with a mark on it does not count until replaced)
  const MIN = c.min_photos ?? 10;
  const done = c.counted ?? c.shots.filter((s) => s.code !== 'odometer').reduce((n, s) => n + s.photos.length, 0);
  const required = { length: MIN };
  const pct = Math.min(100, Math.round((100 * done) / MIN));
  // Add photos: many at once, one after another (each is sorted to its shot on the server: two at once could take the same shot)
  const [batch, setBatch] = useState<{ at: number; of: number } | null>(null);
  // r33 (0700): any number at once; "auto" sorts each to its shot, an extra shot ("exterior_more", "other") files them all there
  const addMany = async (files: FileList | null, shot = 'auto') => {
    const list = Array.from(files ?? []);
    if (!list.length) return;
    setMsg(null);
    let failedN = 0, flagged = 0;
    for (let i = 0; i < list.length; i++) {
      setBatch({ at: i + 1, of: list.length }); setBusy('auto');
      try {
        const { blob, width, height } = await prepare(list[i]!);
        const fd = new FormData();
        fd.set('intake', c.intake_id); fd.set('shot', shot); fd.set('file', blob, `photo-${i + 1}.jpg`);
        if (width) { fd.set('width', String(width)); fd.set('height', String(height)); }
        const r = await fetch('/api/listing/upload', { method: 'POST', body: fd }).catch(() => null);
        const j = (r ? await r.json().catch(() => ({ ok: false })) : { ok: false }) as { ok: boolean; similar?: number; watermark?: boolean };
        if (!j.ok) failedN++; else { if (j.similar) setSimilar(j.similar); if (j.watermark) flagged++; }
      } catch { failedN++; }
    }
    setBatch(null); setBusy(null);
    setMsg(failedN ? { ok: false, text: `${list.length - failedN} of ${list.length} photos added; ${failedN} did not upload. Add those again.` }
      : { ok: true, text: `${list.length} photo${list.length === 1 ? '' : 's'} added${shot === 'auto' ? ' and sorted to their shots' : shot === 'exterior_more' ? ' as extra outside photos (studio background)' : ' as extra inside and detail photos'}.${flagged ? ` ${flagged} with a watermark or text on it: kept off the site until replaced.` : ''}` });
    await reload();
    router.refresh();
  };
  return (
    <section className="pt-card ad-card lc" aria-labelledby="lc-h" data-testid="listing-capture">
      <h2 className="d4" id="lc-h">Photos</h2>
      <p className="small muted">{c.submitted ? 'Submitted. A retake replaces the photo and is processed again.' : `Daylight, landscape, the whole car in frame, no people, no other plates readable. ${done} of at least ${required.length} photos added; the shots below are a guide, not a rule.`}</p>
      {c.may_upload && (
        <div className="lc__drop" data-testid="listing-add-photos">
          <label className="btn btn--primary">
            <span>{batch ? `Adding ${batch.at} of ${batch.of}` : 'Add photos'}</span>
            <input className="vh" type="file" accept="image/jpeg,image/png,image/heic,image/heif" multiple disabled={!!busy}
              onChange={(e) => { void addMany(e.target.files); e.target.value = ''; }} data-testid="listing-add-photos-input" />
          </label>
          <span className="small muted">As many as you like from the camera roll, in any order. Each is sorted to its shot; outside photos get the studio background, inside and detail photos are touched up.</span>
        </div>)}
      {c.may_upload && (
        <div className="lc__drop lc__extras" data-testid="listing-add-extras">
          <span className="small"><b>Extra photos</b> that fit no shot, any number. They go after the standard shots on the car page; set their order in the review.</span>
          <span className="row">
            <label className="btn btn--ghost btn--sm">
              <span>Extra outside photos</span>
              <input className="vh" type="file" accept="image/jpeg,image/png,image/heic,image/heif" multiple disabled={!!busy}
                onChange={(e) => { void addMany(e.target.files, 'exterior_more'); e.target.value = ''; }} data-testid="listing-add-extra-outside" />
            </label>
            <label className="btn btn--ghost btn--sm">
              <span>Extra inside and detail photos</span>
              <input className="vh" type="file" accept="image/jpeg,image/png,image/heic,image/heif" multiple disabled={!!busy}
                onChange={(e) => { void addMany(e.target.files, 'other'); e.target.value = ''; }} data-testid="listing-add-extra-inside" />
            </label>
          </span>
        </div>)}
      <div className="lc__progress" role="progressbar" aria-valuemin={0} aria-valuemax={required.length} aria-valuenow={done} aria-label="Photos added" data-testid="capture-progress">
        <span style={{ width: `${pct}%` }} />
      </div>
      {similar > 0 && <p className="alert alert--warn small" role="status" data-testid="capture-similar"><span>This car looks like another car on file. Staff check it before it is published; keep going.</span></p>}
      <ol className="lc__grid">
        {c.shots.map((s) => {
          const has = s.photos.length > 0;
          const last = s.photos[s.photos.length - 1];
          return (
            <li key={s.code} className={`lc__shot${has ? ' is-done' : ''}`} data-shot={s.code}>
              <span className="lc__label"><b>{s.label}</b></span>
              {s.guide && <span className="small muted">{s.guide}</span>}
              <span className="small">{busy === s.code ? 'Uploading' : has ? `Added${last?.status === 'processed' ? ', processed' : last?.background_status === 'original_used' ? ', kept as taken' : ''}` : 'Missing'}</span>
              {has && c.may_remove !== false && <ul className="lc__photos">{s.photos.map((ph, n) => (
                <li key={ph.id} className="lc__photo">
                  {/* a shot kept private (the odometer, the VIN: never on the site) keeps its original in the private bucket, which has no public address */}
                  {/* eslint-disable-next-line @next/next/no-img-element -- the edited photo, pre-sized by the pipeline */}
                  {ph.processed_path && ph.processed_path !== ph.original_path ? <img src={photoUrl(ph.processed_path)} alt="" width={64} height={43} loading="lazy" /> : <span className="lc__ph" aria-hidden="true">{n + 1}</span>}
                  {sure === ph.id
                    ? <span className="row lc__sure"><span className="small">Wrong shot?</span>
                        <button className="btn btn--primary btn--sm" type="button" disabled={pending} onClick={() => remove(ph.id)} data-testid={`shot-remove-yes-${s.code}`}>Remove it</button>
                        <button className="btn btn--quiet btn--sm" type="button" onClick={() => setSure(null)}>Keep</button></span>
                    : <button className="btn btn--quiet btn--sm" type="button" disabled={pending || !!busy} onClick={() => setSure(ph.id)} data-testid={`shot-remove-${s.code}`}>Remove<span className="vh"> photo {n + 1} of {s.label}</span></button>}
                </li>))}</ul>}
              {c.may_upload && <span className="row lc__picks">
                <label className="btn btn--ghost btn--sm lc__pick">
                  <span>{has && s.max_count === 1 ? 'Retake' : 'Take photo'}<span className="vh"> for {s.label}</span></span>
                  <input className="vh" type="file" accept="image/jpeg,image/png" capture="environment" disabled={!!busy} data-testid={`shot-${s.code}`}
                    onChange={(e) => { void upload(s.code, e.target.files?.[0]); e.target.value = ''; }} />
                </label>
                <label className="btn btn--quiet btn--sm lc__pick">
                  <span>From photos<span className="vh"> for {s.label}</span></span>
                  <input className="vh" type="file" accept="image/jpeg,image/png" multiple={s.max_count > 1} disabled={!!busy} data-testid={`shot-pick-${s.code}`}
                    onChange={(e) => { const f = e.target.files; if (s.max_count > 1 && f && f.length > 1) void addMany(f, s.code); else void upload(s.code, f?.[0]); e.target.value = ''; }} />
                </label>
                {failed[s.code] && <button className="btn btn--primary btn--sm" type="button" disabled={!!busy} onClick={() => void upload(s.code, failed[s.code])} data-testid={`shot-retry-${s.code}`}>Send again</button>}
              </span>}
            </li>
          );
        })}
      </ol>
      {!c.submitted && c.may_upload && <p>
        <button className="btn btn--primary" type="button" disabled={pending || !!busy} onClick={submit} data-testid="listing-submit">{pending ? 'Submitting' : done === 0 ? 'Submit without photos (sample photos)' : 'Submit for listing'}</button>
        {c.missing.length > 0 && <span className="small muted"> {done > 0 ? 'Can be added later' : 'Still needed'}: {c.missing.join(', ')}.</span>}
      </p>}
      {msg && <p className={`alert ${msg.ok ? 'alert--ok' : 'alert--error'}`} role={msg.ok ? 'status' : 'alert'}><span>{msg.text}</span></p>}
    </section>
  );
}
