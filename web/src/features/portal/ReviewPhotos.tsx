'use client';
import { useState } from 'react';
import { toStandardImage } from '@/features/uploads/standard-image';
import { setReviewPhotos } from '@/server/actions/renter-extras';

// r35a (1305): photos with the review (up to 6). A review with at least one photo earns the photo reward points once per
// rental, on top of the review's own.
async function upload(number: string, f: File): Promise<string> {
  const fd = new FormData();
  fd.append('file', await toStandardImage(f), f.name || 'photo.jpg'); fd.append('number', number);
  const r = await fetch('/api/review-photo', { method: 'POST', body: fd });
  const j = (await r.json().catch(() => ({}))) as { ok?: boolean; path?: string; message?: string };
  if (!j.ok || !j.path) throw new Error(j.message || 'The photo could not be uploaded.');
  return j.path;
}

export function ReviewPhotos({ number, count, points }: { number: string; count: number; points: number | null }) {
  const [paths, setPaths] = useState<string[]>([]);
  const [busy, setBusy] = useState(false);
  const [msg, setMsg] = useState<{ ok: boolean; text: string } | null>(null);
  const pick = async (files: FileList | null) => {
    if (!files?.length || busy) return;
    setBusy(true); setMsg(null);
    try {
      const got: string[] = [];
      for (const f of Array.from(files).slice(0, 6 - paths.length)) got.push(await upload(number, f));
      const all = [...paths, ...got];
      const r = await setReviewPhotos(number, all);
      if (!r.ok) { setMsg({ ok: false, text: r.message }); return; }
      setPaths(all);
      setMsg({ ok: true, text: `${all.length} photo${all.length === 1 ? '' : 's'} added to your review.${r.data.points ? ` You earned ${r.data.points} reward points.` : ''}` });
    } catch (e) { setMsg({ ok: false, text: e instanceof Error ? e.message : 'The photo could not be uploaded.' }); } finally { setBusy(false); }
  };
  return (
    <div className="stack" data-testid="review-photos">
      <p className="small">{count > 0 ? `${count} photo${count === 1 ? '' : 's'} with your review.` : `Add a photo of your trip to your review${points ? ` and earn ${points} reward points` : ' and earn extra reward points'}.`}</p>
      <label className="btn btn--ghost btn--sm" htmlFor="rv-photo-file">{busy ? 'Uploading' : 'Add photos'}</label>
      <input className="vh" id="rv-photo-file" type="file" accept="image/*" multiple disabled={busy || paths.length >= 6} onChange={(e) => { void pick(e.target.files); e.target.value = ''; }} data-testid="review-photo-input" />
      {msg && <p className={`alert ${msg.ok ? 'alert--ok' : 'alert--warn'}`} role={msg.ok ? 'status' : 'alert'}><span>{msg.text}</span></p>}
    </div>
  );
}
